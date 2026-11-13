// Copyright (C) 2020-2025 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if USE_LIBWEBRTC && WTF_PLATFORM_COCOA && ENABLE_GPU_PROCESS

private import Cxx
import Dispatch
import Synchronization
import WebCore_Private
import WebKit_Internal

// A reply waiting for its decoder or encoder, which a Swift Array can hold. @unchecked Sendable: it is only used on the
// codecs queue, and the reply is taken out of it once.
private final class PendingReply<Reply: ~Copyable>: @unchecked Sendable {
    var reply: Reply?

    init(_ reply: consuming Reply) {
        self.reply = consume reply
    }
}

// The replies to DecodeFrame or EncodeFrame that a decoder or an encoder owes, in the order it reports their results.
// Each decoder and encoder has its own, so that the results of one that the web process released don't answer another's.
// @unchecked Sendable: it is only used on the codecs queue.
private final class PendingReplies<Reply: ~Copyable>: @unchecked Sendable {
    var replies: [PendingReply<Reply>] = []

    func append(_ reply: consuming Reply) {
        replies.append(PendingReply(reply))
    }

    func sendNext(_ send: (consuming Reply) -> Void) {
        guard !replies.isEmpty, let reply = replies.removeFirst().reply.take() else {
            return
        }
        send(reply)
    }
}

private final class Decoder {
    let platform: LibWebRTCCodecsDecoder
    let pendingReplies: PendingReplies<LibWebRTCCodecsProxyDecodeFrameReply>

    init(platform: LibWebRTCCodecsDecoder, pendingReplies: PendingReplies<LibWebRTCCodecsProxyDecodeFrameReply>) {
        self.platform = platform
        self.pendingReplies = pendingReplies
    }
}

private final class Encoder {
    let platform: LibWebRTCCodecsEncoder
    let codecType: IPCTypes.VideoCodecType
    let useLowLatency: Bool
    var isInvalid = false
    let pendingReplies: PendingReplies<LibWebRTCCodecsProxyEncodeFrameReply>

    init(platform: LibWebRTCCodecsEncoder, pendingReplies: PendingReplies<LibWebRTCCodecsProxyEncodeFrameReply>, codecType: IPCTypes.VideoCodecType, useLowLatency: Bool) {
        self.platform = platform
        self.pendingReplies = pendingReplies
        self.codecType = codecType
        self.useLowLatency = useLowLatency
    }
}

extension IPCTypes.VideoCodecType {
    fileprivate var cxxValue: WebCore.VideoCodecType {
        switch self {
        case .h264:
            .H264
        case .h265:
            .H265
        case .vp9:
            .VP9
        case .av1:
            .AV1
        }
    }
}

extension IPCTypes.VideoEncoderScalabilityMode {
    fileprivate var cxxValue: WebCore.VideoEncoderScalabilityMode {
        switch self {
        case .l1T1:
            .L1T1
        case .l1T2:
            .L1T2
        case .l1T3:
            .L1T3
        }
    }
}

private func isValidEncoderInitialization(codecType: IPCTypes.VideoCodecType, useLowLatency: Bool, width: UInt16, height: UInt16) -> Bool {
    switch codecType {
    case .h264:
        !useLowLatency || (width <= 7680 && height <= 4320)
    case .h265, .vp9, .av1:
        true
    }
}

// The decoders and encoders of a LibWebRTCCodecsProxy, with the replies they owe, on the codecs queue, apart from the flag
// the main thread reads and what the proxy gives them: its video frame heap, the web process's identity, and the codecs
// queue. @unchecked Sendable: the decoders, the encoders and their replies are only used on the codecs queue, where every
// handler runs and where the decoders' and encoders' results are dispatched to, and the flag is atomic.
private final class LibWebRTCCodecsProxyState: @unchecked Sendable {
    let videoFrameObjectHeap: WebKit.RemoteVideoFrameObjectHeap
    let resourceOwner: WebCore.ProcessIdentity?
    let codecsQueue: DispatchQueue
    var decoders: [IPCTypes.VideoDecoderIdentifier: Decoder] = [:]
    var encoders: [IPCTypes.VideoEncoderIdentifier: Encoder] = [:]
    // Read on the main thread.
    let hasEncodersOrDecoders = Atomic<Bool>(false)

    init(videoFrameObjectHeap: WebKit.RemoteVideoFrameObjectHeap, resourceOwner: WebCore.ProcessIdentity?, codecsQueue: DispatchQueue) {
        self.videoFrameObjectHeap = videoFrameObjectHeap
        self.resourceOwner = resourceOwner
        self.codecsQueue = codecsQueue
    }

    func updateHasEncodersOrDecoders() {
        hasEncodersOrDecoders.store(!encoders.isEmpty || !decoders.isEmpty, ordering: .relaxed)
    }
}

// The handlers of the web process's video decoder and encoder messages (LibWebRTCCodecsProxy.h), on the codecs queue, and
// the members of the C++ receiver that reach its Swift state, which m_swiftState holds retained, by address, from the
// receiver's constructor to its destructor.
extension WebKit.LibWebRTCCodecsProxy {
    @cxx
    @implementation
    static func createSwiftState(
        _ videoFrameObjectHeap: WebKit.RemoteVideoFrameObjectHeap,
        _ resourceOwner: WebCore.ProcessIdentity,
        _ hasResourceOwner: Bool,
        _ codecsQueue: UnsafeMutableRawPointer
    ) -> UInt {
        let state = LibWebRTCCodecsProxyState(
            videoFrameObjectHeap: videoFrameObjectHeap,
            resourceOwner: hasResourceOwner ? resourceOwner : nil,
            // Safety: the receiver passes the dispatch queue of its codecs WorkQueue, which the WorkQueue keeps for at
            // least the receiver's life, and this retains it.
            codecsQueue: unsafe Unmanaged<DispatchQueue>.fromOpaque(codecsQueue).takeUnretainedValue()
        )
        return UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<LibWebRTCCodecsProxyState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The proxy has no Swift state")
        }
        return unsafe address
    }

    private var state: LibWebRTCCodecsProxyState {
        // Safety: m_swiftState is a retained LibWebRTCCodecsProxyState from the constructor to the destructor, and
        // nothing changes it.
        unsafe Unmanaged<LibWebRTCCodecsProxyState>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    @cxx
    @implementation
    func allowsExitUnderMemoryPressure() -> Bool {
        !state.hasEncodersOrDecoders.load(ordering: .relaxed)
    }

    @cxx
    @implementation
    func failPendingReplies() {
        let state = state
        let decoders = state.decoders
        state.decoders = [:]
        for decoder in decoders.values {
            for pending in decoder.pendingReplies.replies {
                pending.reply.take()?.send(false)
            }
        }
        let encoders = state.encoders
        state.encoders = [:]
        for encoder in encoders.values {
            for pending in encoder.pendingReplies.replies {
                pending.reply.take()?.send(false)
            }
        }
    }

    func createDecoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        codecType: IPCTypes.VideoCodecType,
        codecString: CxxDecodedArguments.LibWebRTCCodecsProxy.CreateDecoderCodecString,
        useRemoteFrames: Bool,
        enableAdditionalLogging: Bool,
        colorSpaceOverride: IPCTypes.PlatformVideoColorSpace?,
        rotation: IPCTypes.VideoFrameRotation,
        isMirrored: Bool,
        reply: consuming LibWebRTCCodecsProxyCreateDecoderReply
    ) throws(InvalidMessage) {
        let state = state
        guard state.decoders[id] == nil else {
            reply.send(false)
            try messageCheck { false }
            return
        }

        guard areLibWebRTCCodecFrameworksAvailable, WebKit.isValidDecoderCodecString(codecType.cxxValue, codecString) else {
            reply.send(false)
            return
        }

        let codecsQueue = state.codecsQueue
        let pendingReplies = PendingReplies<LibWebRTCCodecsProxyDecodeFrameReply>()
        let output = LibWebRTCCodecsDecoderOutput(
            identifier: id,
            connection: connection,
            heap: useRemoteFrames ? state.videoFrameObjectHeap : nil,
            resourceOwner: state.resourceOwner,
            rotation: rotation,
            isMirrored: isMirrored,
            logsGeneratedFrames: enableAdditionalLogging
        ) { [weak pendingReplies] result in
            codecsQueue.async { [weak pendingReplies] in
                pendingReplies?.sendNext { $0.send(result) }
            }
        }
        let decoder = LibWebRTCCodecsDecoder(identifier: id, output: output, colorSpaceOverride: colorSpaceOverride, logsReceivedFrames: enableAdditionalLogging)
        state.decoders[id] = Decoder(platform: decoder, pendingReplies: pendingReplies)
        state.updateHasEncodersOrDecoders()
        reply.send(true)
    }

    func releaseDecoder(connection: IPC.Connection, id: IPCTypes.VideoDecoderIdentifier) {
        let state = state
        guard let decoder = state.decoders.removeValue(forKey: id) else {
            return
        }
        let pendingReplies = decoder.pendingReplies.replies
        state.codecsQueue.async {
            for pending in pendingReplies {
                pending.reply.take()?.send(true)
            }
        }
        state.updateHasEncodersOrDecoders()
    }

    func flushDecoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        reply: consuming LibWebRTCCodecsProxyFlushDecoderReply
    ) {
        let state = state
        guard let decoder = state.decoders[id] else {
            return
        }
        decoder.platform.flush()
        let pending = PendingReply(reply)
        state.codecsQueue.async {
            pending.reply.take()?.send()
        }
    }

    func setDecoderFormatDescription(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        description: IPC.LentBytes,
        videoInfo: WebCore.VideoInfo?,
        width: UInt16,
        height: UInt16
    ) {
        state.decoders[id]?.platform.setFormat(videoInfo: videoInfo)
    }

    func setDecoderColorSpaceOverride(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        colorSpaceOverride: IPCTypes.PlatformVideoColorSpace?
    ) {
        state.decoders[id]?.platform.setColorSpaceOverride(colorSpaceOverride)
    }

    func decodeFrame(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        timeStamp: Int64,
        data: IPC.LentBytes,
        videoInfo: WebCore.VideoInfo?,
        reply: consuming LibWebRTCCodecsProxyDecodeFrameReply
    ) {
        guard let decoder = state.decoders[id] else {
            return
        }
        switch decoder.platform.decodeFrame(timeStamp: timeStamp, data: data, videoInfo: videoInfo) {
        case .decoding:
            decoder.pendingReplies.append(reply)
        case .noFormat:
            reply.send(true)
        case .failed:
            WebKit.LibWebRTCCodecsProxy.LibWebRTCCodecsMessages.failedDecoding(on: connection, to: 0, identifier: id)
            reply.send(false)
        }
    }

    func setFrameSize(connection: IPC.Connection, id: IPCTypes.VideoDecoderIdentifier, width: UInt16, height: UInt16) {
    }

    func createEncoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        codecType: IPCTypes.VideoCodecType,
        codecString: CxxDecodedArguments.LibWebRTCCodecsProxy.CreateEncoderCodecString,
        parameters: [(String?, String?)],
        useLowLatency: Bool,
        useAnnexB: Bool,
        scalabilityMode: IPCTypes.VideoEncoderScalabilityMode,
        reply: consuming LibWebRTCCodecsProxyCreateEncoderReply
    ) throws(InvalidMessage) {
        let state = state
        guard state.encoders[id] == nil else {
            reply.send(false)
            try messageCheck { false }
            return
        }

        guard codecType == .h264 || codecType == .h265 else {
            reply.send(false)
            return
        }

        guard areLibWebRTCCodecFrameworksAvailable,
            WebKit.isValidEncoderConfiguration(codecType.cxxValue, codecString, useLowLatency, scalabilityMode.cxxValue)
        else {
            reply.send(false)
            return
        }

        let codecsQueue = state.codecsQueue
        let pendingReplies = PendingReplies<LibWebRTCCodecsProxyEncodeFrameReply>()
        let output = LibWebRTCCodecsEncoderOutput(
            identifier: id,
            connection: connection,
            codecType: codecType,
            useAnnexB: useAnnexB,
            usesTwoTemporalLayers: codecType == .h264 && scalabilityMode == .l1T2
        ) { [weak pendingReplies] result in
            codecsQueue.async { [weak pendingReplies] in
                pendingReplies?.sendNext { $0.send(result) }
            }
        }
        let frameSource = SharedVideoFrameSource(
            heap: state.videoFrameObjectHeap,
            resourceOwner: state.resourceOwner ?? WebCore.ProcessIdentity(),
            hasResourceOwner: state.resourceOwner != nil,
            useIOSurfaceBufferPool: true
        )
        guard
            let encoder = LibWebRTCCodecsEncoder(
                codecType: codecType,
                parameters: parameters,
                isLowLatencyEnabled: useLowLatency,
                scalabilityMode: scalabilityMode,
                output: output,
                frameSource: frameSource
            )
        else {
            reply.send(false)
            return
        }

        state.encoders[id] = Encoder(platform: encoder, pendingReplies: pendingReplies, codecType: codecType, useLowLatency: useLowLatency)
        state.updateHasEncodersOrDecoders()
        reply.send(true)
    }

    func releaseEncoder(connection: IPC.Connection, id: IPCTypes.VideoEncoderIdentifier) {
        let state = state
        guard let encoder = state.encoders.removeValue(forKey: id) else {
            return
        }
        let pendingReplies = encoder.pendingReplies.replies
        state.codecsQueue.async {
            for pending in pendingReplies {
                pending.reply.take()?.send(true)
            }
        }
        state.updateHasEncodersOrDecoders()
    }

    func initializeEncoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        width: UInt16,
        height: UInt16,
        startBitrate: UInt32,
        maxBitrate: UInt32,
        minBitrate: UInt32,
        maxFramerate: UInt32
    ) {
        guard let encoder = state.encoders[id] else {
            return
        }
        guard isValidEncoderInitialization(codecType: encoder.codecType, useLowLatency: encoder.useLowLatency, width: width, height: height)
        else {
            encoder.isInvalid = true
            return
        }
        encoder.platform.initialize(width: width, height: height, startBitrateKbps: startBitrate)
    }

    func encodeFrame(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        buffer: consuming IPCTypes.SharedVideoFrame,
        timeStamp: Int64,
        duration: UInt64?,
        shouldEncodeAsKeyFrame: Bool,
        reply: consuming LibWebRTCCodecsProxyEncodeFrameReply
    ) {
        let state = state
        guard let encoder = state.encoders[id], !encoder.isInvalid else {
            // Reads a frame lent by the heap, so that the heap releases it.
            if case .remoteVideoFrameReadReference(let read) = buffer.buffer {
                _ = state.videoFrameObjectHeap.readPixelBuffer(identifier: read.reference.identifier.rawValue, version: read.reference.version)
            }
            reply.send(false)
            return
        }
        guard encoder.platform.encodeFrame(buffer, timeStamp: timeStamp, duration: duration, isKeyframeRequired: shouldEncodeAsKeyFrame) else {
            reply.send(false)
            return
        }
        encoder.pendingReplies.append(reply)
    }

    func flushEncoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        reply: consuming LibWebRTCCodecsProxyFlushEncoderReply
    ) {
        let state = state
        state.encoders[id]?.platform.flush()
        let pending = PendingReply(reply)
        state.codecsQueue.async {
            pending.reply.take()?.send()
        }
    }

    func setEncodeRates(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        bitRate: UInt32,
        frameRate: UInt32,
        reply: consuming LibWebRTCCodecsProxySetEncodeRatesReply
    ) {
        state.encoders[id]?.platform.setRates(bitRateKbps: bitRate, frameRate: frameRate)
        reply.send()
    }

    func setSharedVideoFrameSemaphore(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        semaphore: borrowing IPCTypes.Semaphore
    ) {
        state.encoders[id]?.platform.frameSource.setSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        storageHandle: borrowing IPCTypes.SharedMemoryHandle
    ) {
        _ = state.encoders[id]?.platform.frameSource.setSharedMemory(storageHandle.port, storageHandle.size)
    }

    func setRTCLoggingLevel(connection: IPC.Connection, level: IPCTypes.WTFLogLevel) {
        WebKit.LibWebRTCCodecsProxy.setRTCLoggingLevel(level.rawValue)
    }
}

#endif
