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

// A reply that a decoder or an encoder owes, which a Swift Array can hold, taken out of it once.
private final class PendingReply<Reply: ~Copyable> {
    var reply: Reply?

    init(_ reply: consuming Reply) {
        self.reply = consume reply
    }
}

// The flags of the dispatches to the codecs queue: DispatchQueue.async's default, an array literal, makes every call
// look up the array's generic metadata and run an unspecialized SetAlgebra initializer.
private let codecsQueueDispatchFlags = DispatchWorkItemFlags(rawValue: 0)

// The replies to DecodeFrame or EncodeFrame that a decoder or an encoder owes, in the order it reports their results.
// Each decoder and encoder has its own, so that the results of one that the web process released don't answer another's.
private final class PendingReplies<Reply: ~Copyable> {
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

    func sendAll(_ send: (consuming Reply) -> Void) {
        for pending in replies {
            if let reply = pending.reply.take() {
                send(reply)
            }
        }
        replies = []
    }
}

// A decoder or an encoder, with its replies and the generation that names them, which outlive it until the results
// already dispatched to the codecs queue have been sent.
private final class Decoder {
    let platform: LibWebRTCCodecsDecoder
    let generation: UInt64
    let pendingReplies = PendingReplies<LibWebRTCCodecsProxyDecodeFrameReply>()

    init(platform: LibWebRTCCodecsDecoder, generation: UInt64) {
        self.platform = platform
        self.generation = generation
    }
}

private final class Encoder {
    let platform: LibWebRTCCodecsEncoder
    let generation: UInt64
    let pendingReplies = PendingReplies<LibWebRTCCodecsProxyEncodeFrameReply>()
    let codecType: IPCTypes.VideoCodecType
    let useLowLatency: Bool
    var isInvalid = false

    init(platform: LibWebRTCCodecsEncoder, generation: UInt64, codecType: IPCTypes.VideoCodecType, useLowLatency: Bool) {
        self.platform = platform
        self.generation = generation
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

// The receiver of a web process's video decoder and encoder messages, which the connection's Swift state owns
// (GPUConnectionState), and its decoders and encoders, with the replies they owe. Its executor is the GPU process's codecs
// queue, which its forwarder is registered with and which the decoders' and encoders' results are dispatched to.
actor LibWebRTCCodecsProxy: GPUConnectionReceiver {
    nonisolated let codecsQueue: DispatchSerialQueue
    private let videoFrameObjectHeap: WebKit.RemoteVideoFrameObjectHeap
    private let resourceOwner: WebCore.ProcessIdentity?
    private var decoders: [IPCTypes.VideoDecoderIdentifier: Decoder] = [:]
    private var encoders: [IPCTypes.VideoEncoderIdentifier: Encoder] = [:]
    // By generation, from when the decoder or encoder is created until it is released.
    private var decodeFrameReplies: [UInt64: PendingReplies<LibWebRTCCodecsProxyDecodeFrameReply>] = [:]
    private var encodeFrameReplies: [UInt64: PendingReplies<LibWebRTCCodecsProxyEncodeFrameReply>] = [:]
    private var lastGeneration: UInt64 = 0
    // What runs once the codecs queue has run what was dispatched to it before, in order.
    private var queuedWork: [() -> Void] = []
    private let pixelBufferConverter = LibWebRTCCodecsPixelBufferConverter()
    private nonisolated let hasEncodersOrDecoders = Atomic<Bool>(false)

    init(videoFrameObjectHeap: WebKit.RemoteVideoFrameObjectHeap, resourceOwner: WebCore.ProcessIdentity?, codecsQueue: DispatchSerialQueue) {
        self.videoFrameObjectHeap = videoFrameObjectHeap
        self.resourceOwner = resourceOwner
        self.codecsQueue = codecsQueue
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        // Safety: the codecs queue is serial and outlives this, which keeps it.
        unsafe codecsQueue.asUnownedSerialExecutor()
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the connection it is registered with does.
    nonisolated func getMessageReceiver() -> RefLibWebRTCCodecsProxyMessageForwarder {
        WebKit.LibWebRTCCodecsProxyMessageForwarder.create(target: self)
    }

    nonisolated var allowsExitUnderMemoryPressure: Bool {
        !hasEncodersOrDecoders.load(ordering: .relaxed)
    }

    // The connection has stopped dispatching to the codecs queue, so what is pending fails once the messages already
    // there have been handled.
    nonisolated func connectionDidClose() {
        codecsQueue.async(flags: codecsQueueDispatchFlags) { [self] in
            assumeIsolated { $0.failPendingReplies() }
        }
    }

    private func failPendingReplies() {
        let decoders = self.decoders
        self.decoders = [:]
        for decoder in decoders.values {
            decodeFrameReplies.removeValue(forKey: decoder.generation)?.sendAll { $0.send(false) }
        }
        let encoders = self.encoders
        self.encoders = [:]
        for encoder in encoders.values {
            encodeFrameReplies.removeValue(forKey: encoder.generation)?.sendAll { $0.send(false) }
        }
        updateHasEncodersOrDecoders()
    }

    private func updateHasEncodersOrDecoders() {
        hasEncodersOrDecoders.store(!encoders.isEmpty || !decoders.isEmpty, ordering: .relaxed)
    }

    private func nextGeneration() -> UInt64 {
        lastGeneration += 1
        return lastGeneration
    }

    // Runs work after what is already dispatched to the codecs queue, such as the results of a flushed session.
    private func afterQueuedWork(_ work: @escaping () -> Void) {
        queuedWork.append(work)
        codecsQueue.async(flags: codecsQueueDispatchFlags) { [self] in
            assumeIsolated { $0.queuedWork.removeFirst()() }
        }
    }

    private func didDecodeFrame(generation: UInt64, _ result: Bool) {
        decodeFrameReplies[generation]?.sendNext { $0.send(result) }
    }

    private func didEncodeFrame(generation: UInt64, _ result: Bool) {
        encodeFrameReplies[generation]?.sendNext { $0.send(result) }
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
        guard decoders[id] == nil else {
            reply.send(false)
            try messageCheck { false }
            return
        }

        guard areLibWebRTCCodecFrameworksAvailable, WebKit.isValidDecoderCodecString(codecType.cxxValue, codecString) else {
            reply.send(false)
            return
        }

        let codecsQueue = self.codecsQueue
        let generation = nextGeneration()
        let output = LibWebRTCCodecsDecoderOutput(
            identifier: id,
            connection: connection,
            heap: useRemoteFrames ? videoFrameObjectHeap : nil,
            resourceOwner: resourceOwner,
            rotation: rotation,
            isMirrored: isMirrored,
            logsGeneratedFrames: enableAdditionalLogging
        ) { [weak self] result in
            guard let proxy = self else {
                return
            }
            codecsQueue.async(flags: codecsQueueDispatchFlags) {
                proxy.assumeIsolated { $0.didDecodeFrame(generation: generation, result) }
            }
        }
        let decoder = LibWebRTCCodecsDecoder(identifier: id, output: output, colorSpaceOverride: colorSpaceOverride, logsReceivedFrames: enableAdditionalLogging)
        let entry = Decoder(platform: decoder, generation: generation)
        decoders[id] = entry
        decodeFrameReplies[generation] = entry.pendingReplies
        updateHasEncodersOrDecoders()
        reply.send(true)
    }

    func releaseDecoder(connection: IPC.Connection, id: IPCTypes.VideoDecoderIdentifier) {
        guard let decoder = decoders.removeValue(forKey: id) else {
            return
        }
        afterQueuedWork { [self] in
            decodeFrameReplies.removeValue(forKey: decoder.generation)?.sendAll { $0.send(true) }
        }
        updateHasEncodersOrDecoders()
    }

    func flushDecoder(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        reply: consuming LibWebRTCCodecsProxyFlushDecoderReply
    ) {
        guard let decoder = decoders[id] else {
            return
        }
        decoder.platform.flush()
        let pending = PendingReply(reply)
        afterQueuedWork {
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
        decoders[id]?.platform.setFormat(videoInfo: videoInfo)
    }

    func setDecoderColorSpaceOverride(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        colorSpaceOverride: IPCTypes.PlatformVideoColorSpace?
    ) {
        decoders[id]?.platform.setColorSpaceOverride(colorSpaceOverride)
    }

    func decodeFrame(
        connection: IPC.Connection,
        id: IPCTypes.VideoDecoderIdentifier,
        timeStamp: Int64,
        data: IPC.LentBytes,
        videoInfo: WebCore.VideoInfo?,
        reply: consuming LibWebRTCCodecsProxyDecodeFrameReply
    ) {
        guard let decoder = decoders[id] else {
            return
        }
        switch decoder.platform.decodeFrame(timeStamp: timeStamp, data: data, videoInfo: videoInfo) {
        case .decoding:
            decoder.pendingReplies.append(reply)
        case .noFormat:
            reply.send(true)
        case .failed:
            Self.LibWebRTCCodecsMessages.failedDecoding(on: connection, to: 0, identifier: id)
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
        guard encoders[id] == nil else {
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

        let codecsQueue = self.codecsQueue
        let generation = nextGeneration()
        let output = LibWebRTCCodecsEncoderOutput(
            identifier: id,
            connection: connection,
            codecType: codecType,
            useAnnexB: useAnnexB,
            usesTwoTemporalLayers: codecType == .h264 && scalabilityMode == .l1T2
        ) { [weak self] result in
            guard let proxy = self else {
                return
            }
            codecsQueue.async(flags: codecsQueueDispatchFlags) {
                proxy.assumeIsolated { $0.didEncodeFrame(generation: generation, result) }
            }
        }
        let frameSource = SharedVideoFrameSource(
            heap: videoFrameObjectHeap,
            resourceOwner: resourceOwner ?? WebCore.ProcessIdentity(),
            hasResourceOwner: resourceOwner != nil,
            useIOSurfaceBufferPool: true
        )
        guard
            let encoder = LibWebRTCCodecsEncoder(
                codecType: codecType,
                parameters: parameters,
                isLowLatencyEnabled: useLowLatency,
                scalabilityMode: scalabilityMode,
                output: output,
                frameSource: frameSource,
                pixelBufferConverter: pixelBufferConverter
            )
        else {
            reply.send(false)
            return
        }

        let entry = Encoder(platform: encoder, generation: generation, codecType: codecType, useLowLatency: useLowLatency)
        encoders[id] = entry
        encodeFrameReplies[generation] = entry.pendingReplies
        updateHasEncodersOrDecoders()
        reply.send(true)
    }

    func releaseEncoder(connection: IPC.Connection, id: IPCTypes.VideoEncoderIdentifier) {
        guard let encoder = encoders.removeValue(forKey: id) else {
            return
        }
        afterQueuedWork { [self] in
            encodeFrameReplies.removeValue(forKey: encoder.generation)?.sendAll { $0.send(true) }
        }
        updateHasEncodersOrDecoders()
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
        guard let encoder = encoders[id] else {
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
        guard let encoder = encoders[id], !encoder.isInvalid else {
            // Reads a frame lent by the heap, so that the heap releases it.
            if case .remoteVideoFrameReadReference(let read) = buffer.buffer {
                _ = videoFrameObjectHeap.readPixelBuffer(identifier: read.reference.identifier.rawValue, version: read.reference.version)
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
        encoders[id]?.platform.flush()
        let pending = PendingReply(reply)
        afterQueuedWork {
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
        encoders[id]?.platform.setRates(bitRateKbps: bitRate, frameRate: frameRate)
        reply.send()
    }

    func setSharedVideoFrameSemaphore(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        semaphore: borrowing IPCTypes.Semaphore
    ) {
        encoders[id]?.platform.frameSource.setSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(
        connection: IPC.Connection,
        id: IPCTypes.VideoEncoderIdentifier,
        storageHandle: borrowing IPCTypes.SharedMemoryHandle
    ) {
        _ = encoders[id]?.platform.frameSource.setSharedMemory(storageHandle.port, storageHandle.size)
    }

    func setRTCLoggingLevel(connection: IPC.Connection, level: IPCTypes.WTFLogLevel) {
        WebKit.setLibWebRTCLoggingLevel(level.rawValue)
    }
}

#endif
