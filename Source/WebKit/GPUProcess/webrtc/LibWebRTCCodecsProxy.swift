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
import Synchronization
import WebCore_Private
import WebKit_Internal

// A reply waiting for its decoder or encoder, which a Swift Array can hold.
private final class PendingReply<Reply: ~Copyable> {
    var reply: Reply?

    init(_ reply: consuming Reply) {
        self.reply = consume reply
    }
}

private final class Decoder {
    let platform: WebKit.LibWebRTCCodecsProxyDecoder
    // The replies to DecodeFrame, in the order the decoder reports their results.
    var pendingReplies: [PendingReply<LibWebRTCCodecsProxyDecodeFrameReply>] = []

    init(platform: WebKit.LibWebRTCCodecsProxyDecoder) {
        self.platform = platform
    }
}

private final class Encoder {
    let platform: WebKit.LibWebRTCCodecsProxyEncoder
    let codecType: IPCTypes.VideoCodecType
    let useLowLatency: Bool
    var isInvalid = false
    // The replies to EncodeFrame, in the order the encoder reports their results.
    var pendingReplies: [PendingReply<LibWebRTCCodecsProxyEncodeFrameReply>] = []

    init(platform: WebKit.LibWebRTCCodecsProxyEncoder, codecType: IPCTypes.VideoCodecType, useLowLatency: Bool) {
        self.platform = platform
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
// the main thread reads.
private final class LibWebRTCCodecsProxyState {
    var decoders: [IPCTypes.VideoDecoderIdentifier: Decoder] = [:]
    var encoders: [IPCTypes.VideoEncoderIdentifier: Encoder] = [:]
    // Read on the main thread.
    let hasEncodersOrDecoders = Atomic<Bool>(false)

    func updateHasEncodersOrDecoders() {
        hasEncodersOrDecoders.store(!encoders.isEmpty || !decoders.isEmpty, ordering: .relaxed)
    }

    func notifyDecoderResult(_ id: IPCTypes.VideoDecoderIdentifier, _ result: Bool) {
        guard let decoder = decoders[id] else {
            return
        }
        decoder.pendingReplies.removeFirst().reply.take()?.send(result)
    }

    func notifyEncoderResult(_ id: IPCTypes.VideoEncoderIdentifier, _ result: Bool) {
        guard let encoder = encoders[id] else {
            return
        }
        encoder.pendingReplies.removeFirst().reply.take()?.send(result)
    }
}

// The handlers of the web process's video decoder and encoder messages (LibWebRTCCodecsProxy.h), on the codecs queue, and
// the members of the C++ receiver that reach its Swift state, which m_swiftState holds retained, by address, from the
// receiver's constructor to its destructor.
extension WebKit.LibWebRTCCodecsProxy {
    @cxx
    @implementation
    static func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(LibWebRTCCodecsProxyState()).toOpaque())
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
            for pending in decoder.pendingReplies {
                pending.reply.take()?.send(false)
            }
        }
        let encoders = state.encoders
        state.encoders = [:]
        for encoder in encoders.values {
            for pending in encoder.pendingReplies {
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
        colorSpaceOverride: CxxDecodedArguments.LibWebRTCCodecsProxy.CreateDecoderColorSpaceOverride,
        rotation: CxxDecodedArguments.LibWebRTCCodecsProxy.CreateDecoderRotation,
        isMirrored: Bool,
        reply: consuming LibWebRTCCodecsProxyCreateDecoderReply
    ) throws(InvalidMessage) {
        guard state.decoders[id] == nil else {
            reply.send(false)
            try messageCheck { false }
            return
        }

        guard
            let decoder = WebKit.LibWebRTCCodecsProxyDecoder
                .create(
                    self,
                    id.rawValue,
                    codecType.cxxValue,
                    codecString,
                    useRemoteFrames,
                    enableAdditionalLogging,
                    colorSpaceOverride,
                    rotation,
                    isMirrored,
                    { [weak state] result in state?.notifyDecoderResult(id, result) }
                )
                .get()
        else {
            reply.send(false)
            return
        }

        state.decoders[id] = Decoder(platform: decoder)
        state.updateHasEncodersOrDecoders()
        reply.send(true)
    }

    func releaseDecoder(connection: IPC.Connection, id: IPCTypes.VideoDecoderIdentifier) {
        guard let decoder = state.decoders.removeValue(forKey: id) else {
            return
        }
        let pendingReplies = decoder.pendingReplies
        dispatch {
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
        guard let decoder = state.decoders[id] else {
            return
        }
        decoder.platform.flush()
        let pending = PendingReply(reply)
        dispatch {
            pending.reply.take()?.send()
        }
    }

    func setDecoderFormatDescription(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        description: [UInt8],
        videoInfo: CxxDecodedArguments.LibWebRTCCodecsProxy.SetDecoderFormatDescriptionVideoInfo,
        width: UInt16,
        height: UInt16
    ) {
        guard let decoder = state.decoders[id] else {
            return
        }
        let description = sliceForCxx(description)
        decoder.platform.setFormat(description.span, videoInfo, width, height)
    }

    func setDecoderColorSpaceOverride(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        colorSpaceOverride: CxxDecodedArguments.LibWebRTCCodecsProxy.SetDecoderColorSpaceOverrideColorSpaceOverride
    ) {
        state.decoders[id]?.platform.setColorSpaceOverride(colorSpaceOverride)
    }

    func decodeFrame(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        timeStamp: Int64,
        data: [UInt8],
        videoInfo: CxxDecodedArguments.LibWebRTCCodecsProxy.DecodeFrameVideoInfo,
        reply: consuming LibWebRTCCodecsProxyDecodeFrameReply
    ) {
        guard let decoder = state.decoders[id] else {
            return
        }
        let data = sliceForCxx(data)
        guard decoder.platform.decodeFrame(timeStamp, data.span, videoInfo) else {
            reply.send(false)
            return
        }
        decoder.pendingReplies.append(PendingReply(reply))
    }

    func setFrameSize(connection: IPC.Connection, id: IPCTypes.VideoDecoderIdentifier, width: UInt16, height: UInt16) {
        state.decoders[id]?.platform.setFrameSize(width, height)
    }

    func createEncoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        codecType: IPCTypes.VideoCodecType,
        codecString: CxxDecodedArguments.LibWebRTCCodecsProxy.CreateEncoderCodecString,
        parameters: CxxDecodedArguments.LibWebRTCCodecsProxy.CreateEncoderParameters,
        useLowLatency: Bool,
        useAnnexB: Bool,
        scalabilityMode: IPCTypes.VideoEncoderScalabilityMode,
        reply: consuming LibWebRTCCodecsProxyCreateEncoderReply
    ) throws(InvalidMessage) {
        guard state.encoders[id] == nil else {
            reply.send(false)
            try messageCheck { false }
            return
        }

        guard codecType == .h264 || codecType == .h265 else {
            reply.send(false)
            return
        }

        guard
            let encoder = WebKit.LibWebRTCCodecsProxyEncoder
                .create(
                    self,
                    id.rawValue,
                    codecType.cxxValue,
                    codecString,
                    parameters,
                    useLowLatency,
                    useAnnexB,
                    scalabilityMode.cxxValue,
                    { [weak state] result in state?.notifyEncoderResult(id, result) }
                )
                .get()
        else {
            reply.send(false)
            return
        }

        state.encoders[id] = Encoder(platform: encoder, codecType: codecType, useLowLatency: useLowLatency)
        state.updateHasEncodersOrDecoders()
        reply.send(true)
    }

    func releaseEncoder(connection: IPC.Connection, id: IPCTypes.VideoEncoderIdentifier) {
        guard let encoder = state.encoders.removeValue(forKey: id) else {
            return
        }
        let pendingReplies = encoder.pendingReplies
        dispatch {
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
        encoder.platform.initialize(width, height, startBitrate, maxBitrate, minBitrate, maxFramerate)
    }

    func encodeFrame(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        buffer: CxxDecodedArguments.LibWebRTCCodecsProxy.EncodeFrameBuffer,
        timeStamp: Int64,
        duration: UInt64?,
        shouldEncodeAsKeyFrame: Bool,
        reply: consuming LibWebRTCCodecsProxyEncodeFrameReply
    ) {
        guard let encoder = state.encoders[id], !encoder.isInvalid else {
            releaseVideoFrame(buffer)
            reply.send(false)
            return
        }
        guard encoder.platform.encodeFrame(buffer, timeStamp, duration != nil, duration ?? 0, shouldEncodeAsKeyFrame) else {
            reply.send(false)
            return
        }
        encoder.pendingReplies.append(PendingReply(reply))
    }

    func flushEncoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        reply: consuming LibWebRTCCodecsProxyFlushEncoderReply
    ) {
        state.encoders[id]?.platform.flush()
        let pending = PendingReply(reply)
        dispatch {
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
        state.encoders[id]?.platform.setRates(bitRate, frameRate)
        reply.send()
    }

    func setSharedVideoFrameSemaphore(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        semaphore: borrowing IPCTypes.Semaphore
    ) {
        state.encoders[id]?.platform.setSharedVideoFrameSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        storageHandle: borrowing IPCTypes.SharedMemoryHandle
    ) {
        state.encoders[id]?.platform.setSharedVideoFrameMemory(storageHandle.port, storageHandle.size)
    }

    func setRTCLoggingLevel(connection: IPC.Connection, level: IPCTypes.WTFLogLevel) {
        WebKit.LibWebRTCCodecsProxy.setRTCLoggingLevel(level.rawValue)
    }
}

// A Span with a null base traps on its way to C++, so an empty one is a slice of this.
private let emptyBytes: [UInt8] = [0]

private func sliceForCxx(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
    bytes.isEmpty ? emptyBytes[0..<0] : bytes[...]
}

#endif
