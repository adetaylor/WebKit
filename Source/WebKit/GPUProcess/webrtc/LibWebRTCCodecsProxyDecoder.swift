// Copyright (C) 2017 Apple Inc. All rights reserved.
// Copyright (C) 2020-2025 Apple Inc. All rights reserved.
// Copyright (C) 2022 Apple Inc. All rights reserved.
// Copyright (C) 2025 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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
//
// Copyright (C) 2020 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if USE_LIBWEBRTC && WTF_PLATFORM_COCOA && ENABLE_GPU_PROCESS

#if os(macOS)
@_weakLinked import CoreMedia
@_weakLinked import VideoToolbox
#else
import CoreMedia
import VideoToolbox
#endif
import CoreVideo
private import Cxx
import Darwin
import Dispatch
import Foundation
import IOSurface
import Synchronization
import WebCore_Private
import WebKit_Internal
import os

// Whether the frameworks the decoders and encoders call are loaded. macOS links them weakly, as a system can lack them;
// the codecs call only their C functions, not their Swift overlays.
var areLibWebRTCCodecFrameworksAvailable: Bool {
    #if os(macOS)
    guard #_hasSymbol(VTDecompressionSessionInvalidate(_:)), #_hasSymbol(CMSampleBufferGetDataBuffer(_:)) else {
        return false
    }
    #endif
    return true
}

// Logs the frames that come later than three times the frame rate observed over the last two seconds leads to expect,
// as WebCore::FrameRateMonitor does for its other users.
struct LibWebRTCCodecsFrameRateMonitor {
    struct LateFrame {
        let frameTime: Double
        let lastFrameTime: Double
        let observedFrameRate: Double
        let frameCount: Int
    }

    private static let minimumAverageDuration = 1.0
    private static let maxQueueDuration = 2.0
    private static let maxFrameDelayCount = 3.0

    // The time stamps from observedFrameTimeStampsStart on, in increasing order.
    private var observedFrameTimeStamps: [Double] = []
    private var observedFrameTimeStampsStart = 0
    private var observedFrameRate = 0.0
    private var frameCount = 0

    // The seconds since boot, as WTF::MonotonicTime counts them.
    private static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    mutating func update() -> LateFrame? {
        frameCount += 1

        let frameTime = Self.now()
        let lastFrameTime = observedFrameTimeStampsStart < observedFrameTimeStamps.count ? observedFrameTimeStamps[observedFrameTimeStamps.count - 1] : frameTime

        var lateFrame: LateFrame?
        if observedFrameRate != 0 {
            let maxDelay = Self.maxFrameDelayCount / observedFrameRate
            if frameTime - lastFrameTime > maxDelay {
                lateFrame = LateFrame(frameTime: frameTime, lastFrameTime: lastFrameTime, observedFrameRate: observedFrameRate, frameCount: frameCount)
            }
        }
        observedFrameTimeStamps.append(frameTime)
        while observedFrameTimeStampsStart < observedFrameTimeStamps.count && observedFrameTimeStamps[observedFrameTimeStampsStart] <= frameTime - Self.maxQueueDuration {
            observedFrameTimeStampsStart += 1
        }
        if observedFrameTimeStampsStart > observedFrameTimeStamps.count / 2 {
            observedFrameTimeStamps.removeFirst(observedFrameTimeStampsStart)
            observedFrameTimeStampsStart = 0
        }

        let count = observedFrameTimeStamps.count - observedFrameTimeStampsStart
        if count > 0 {
            let queueDuration = observedFrameTimeStamps[observedFrameTimeStamps.count - 1] - observedFrameTimeStamps[observedFrameTimeStampsStart]
            if queueDuration > Self.minimumAverageDuration {
                observedFrameRate = Double(count) / queueDuration
            }
        }
        return lateFrame
    }
}

private enum DecoderFrameEvent {
    case generated
    case received
}

private func logLateFrame(_ lateFrame: LibWebRTCCodecsFrameRateMonitor.LateFrame, decoder: UInt64, event: DecoderFrameEvent) {
    let delay = (lateFrame.frameTime - lateFrame.lastFrameTime) * 1000
    switch event {
    case .generated:
        WebKit.LogChannel.WebRTC().releaseLog.log(
            "LibWebRTCCodecsProxy decoder \(decoder) generated a video frame at \(lateFrame.frameTime), previous frame was at \(lateFrame.lastFrameTime), observed frame rate is \(lateFrame.observedFrameRate), delay since last frame is \(delay) ms, frame count is \(lateFrame.frameCount)"
        )
    case .received:
        WebKit.LogChannel.WebRTC().releaseLog.log(
            "LibWebRTCCodecsProxy decoder \(decoder) received a compressed frame at \(lateFrame.frameTime), previous frame was at \(lateFrame.lastFrameTime), observed frame rate is \(lateFrame.observedFrameRate), delay since last frame is \(delay) ms, frame count is \(lateFrame.frameCount)"
        )
    }
}

// A decoded frame waiting in a reorder queue. @unchecked Sendable: the queue only holds the pixel buffer and hands it on,
// never touching its pixels, and its reference count is atomic.
private struct DecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timeStamp: Int64
}

// The frames waiting to be output in presentation order: a frame is output
// once more than `reorderSize` frames are waiting.
private struct DecodedFrameReorderQueue {
    private var frames: [DecodedFrame] = []
    var reorderSize: UInt8 = 0

    var isEmpty: Bool {
        frames.isEmpty
    }

    private var isAvailable: Bool {
        frames.count > Int(reorderSize)
    }

    // Keeps the frames in time stamp order, after the frames with the same time stamp.
    mutating func append(_ frame: DecodedFrame) {
        var index = frames.endIndex
        while index > frames.startIndex && frames[index - 1].timeStamp > frame.timeStamp {
            index -= 1
        }
        frames.insert(frame, at: index)
    }

    // The first frame, if it can be output, and whether the next one can be too.
    mutating func takeIfAvailable() -> (frame: DecodedFrame, moreFramesAvailable: Bool)? {
        guard isAvailable else {
            return nil
        }
        let frame = frames.removeFirst()
        return (frame, isAvailable)
    }

    mutating func takeFirst() -> DecodedFrame {
        frames.removeFirst()
    }
}

private struct DecoderOutputState {
    var reorderQueue = DecodedFrameReorderQueue()
    var generatedFrameRateMonitor: LibWebRTCCodecsFrameRateMonitor?
}

// What a decoder's VideoToolbox session decodes, on the threads it outputs frames on: each frame goes to the web process,
// lent through the video frame heap when the web process asked for remote frames, in presentation order when the
// stream reorders frames, and the result of each decoded frame goes to the codecs queue.
//
// @unchecked Sendable: the connection and the heap are safe to use on any thread, the process identity is never changed,
// and the mutex guards the rest.
final class LibWebRTCCodecsDecoderOutput: @unchecked Sendable {
    private let identifier: IPCTypes.VideoDecoderIdentifier
    private let connection: IPC.Connection
    private let heap: WebKit.RemoteVideoFrameObjectHeap?
    private let resourceOwner: WebCore.ProcessIdentity?
    private let rotation: IPCTypes.VideoFrameRotation
    private let isMirrored: Bool
    private let notifyResult: @Sendable (Bool) -> Void
    private let state: Mutex<DecoderOutputState>

    init(
        identifier: IPCTypes.VideoDecoderIdentifier,
        connection: IPC.Connection,
        heap: WebKit.RemoteVideoFrameObjectHeap?,
        resourceOwner: WebCore.ProcessIdentity?,
        rotation: IPCTypes.VideoFrameRotation,
        isMirrored: Bool,
        logsGeneratedFrames: Bool,
        notifyResult: @escaping @Sendable (Bool) -> Void
    ) {
        self.identifier = identifier
        self.connection = connection
        self.heap = heap
        self.resourceOwner = resourceOwner
        self.rotation = rotation
        self.isMirrored = isMirrored
        self.notifyResult = notifyResult
        state = Mutex(DecoderOutputState(generatedFrameRateMonitor: logsGeneratedFrames ? LibWebRTCCodecsFrameRateMonitor() : nil))
    }

    // A frame that the session decoded, or failed to, with the reorder queue's size when the frame was given to the
    // session. Without a reorder queue, frames go out in the order the session outputs them.
    func sessionDidOutput(_ pixelBuffer: CVPixelBuffer?, timeStamp: Int64, usesReorderQueue: Bool, reorderSize: UInt8) {
        let frame = pixelBuffer.map { DecodedFrame(pixelBuffer: $0, timeStamp: timeStamp) }
        state.withLock { state in
            guard let frame else {
                deliver(nil, isReordered: false, &state)
                return
            }
            guard usesReorderQueue else {
                deliver(frame, isReordered: false, &state)
                return
            }
            if reorderSize != state.reorderQueue.reorderSize {
                flush(&state)
                state.reorderQueue.reorderSize = reorderSize
            }
            guard reorderSize != 0 else {
                deliver(frame, isReordered: false, &state)
                return
            }

            state.reorderQueue.append(frame)
            var hasDelivered = false
            while let next = state.reorderQueue.takeIfAvailable() {
                hasDelivered = true
                deliver(next.frame, isReordered: next.moreFramesAvailable, &state)
            }
            if !hasDelivered {
                deliver(nil, isReordered: true, &state)
            }
        }
    }

    // Sends the frames waiting in the reorder queue.
    func flushReorderQueue() {
        state.withLock { state in
            flush(&state)
        }
    }

    private func flush(_ state: inout DecoderOutputState) {
        while !state.reorderQueue.isEmpty {
            deliver(state.reorderQueue.takeFirst(), isReordered: true, &state)
        }
    }

    // A frame that isn't the last of those a decoded frame lets out of the reorder queue is reordered: the decoded frame's
    // result goes out with the last one. A reordered failure means the decoded frame went into the queue.
    private func deliver(_ frame: DecodedFrame?, isReordered: Bool, _ state: inout DecoderOutputState) {
        defer {
            if frame == nil || !isReordered {
                notifyResult(frame != nil || isReordered)
            }
        }

        guard let frame else {
            if !isReordered {
                WebKit.LibWebRTCCodecsProxy.LibWebRTCCodecsMessages.failedDecoding(on: connection, to: 0, identifier: identifier)
            }
            return
        }

        if let lateFrame = state.generatedFrameRateMonitor?.update() {
            logLateFrame(lateFrame, decoder: identifier.rawValue, event: .generated)
        }

        let pixelBuffer = frame.pixelBuffer
        if let resourceOwner {
            WebCore.setOwnershipIdentityForCVPixelBuffer(pixelBuffer, resourceOwner)
        }

        guard let heap else {
            // Safety: CVPixelBufferGetIOSurface follows the Get rule, and the pixel buffer keeps its surface.
            let ioSurface = unsafe CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
            let surface = ioSurface.map { IPCTypes.MachSendRight(surface: $0) } ?? IPCTypes.MachSendRight()
            WebKit.LibWebRTCCodecsProxy.LibWebRTCCodecsMessages.completedDecodingCV(
                on: connection,
                to: 0,
                identifier: identifier,
                timeStamp: frame.timeStamp,
                timeStampNs: 0,
                pixelBuffer: consume surface
            )
            return
        }

        guard let frameIdentifier = IPCTypes.RemoteVideoFrameIdentifier(rawValue: heap.lend(pixelBuffer, rotation: rotation.rawValue, isMirrored: isMirrored))
        else {
            return
        }
        let properties = IPCTypes.RemoteVideoFrameProxyProperties(
            presentationTime: IPCTypes.MediaTime(timeValue: 0, timeScale: 1, timeFlags: 1),
            isMirrored: isMirrored,
            rotation: rotation,
            size: IPCTypes.IntSize(width: Int32(truncatingIfNeeded: CVPixelBufferGetWidth(pixelBuffer)), height: Int32(truncatingIfNeeded: CVPixelBufferGetHeight(pixelBuffer))),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            colorSpace: IPCTypes.PlatformVideoColorSpace(WebKit.colorSpaceOfPixelBuffer(pixelBuffer)),
            shouldIgnoreAlpha: false
        )
        WebKit.LibWebRTCCodecsProxy.LibWebRTCCodecsMessages.completedDecoding(
            on: connection,
            to: 0,
            identifier: identifier,
            timeStamp: frame.timeStamp,
            timeStampNs: 0,
            reference: IPCTypes.RemoteVideoFrameReference(identifier: frameIdentifier, version: 0),
            frame: properties
        )
    }
}

extension IPCTypes.PlatformVideoColorSpace {
    init(_ colorSpace: WebKit.LibWebRTCCodecsColorSpace) {
        self.init(
            primaries: colorSpace.hasPrimaries ? IPCTypes.PlatformVideoColorPrimaries(rawValue: colorSpace.primaries.rawValue) : nil,
            transfer: colorSpace.hasTransfer ? IPCTypes.PlatformVideoTransferCharacteristics(rawValue: colorSpace.transfer.rawValue) : nil,
            matrix: colorSpace.hasMatrix ? IPCTypes.PlatformVideoMatrixCoefficients(rawValue: colorSpace.matrix.rawValue) : nil,
            fullRange: colorSpace.hasFullRange ? colorSpace.fullRange : nil,
            chromaLocation: colorSpace.hasChromaLocation ? IPCTypes.PlatformVideoChromaLocation(rawValue: colorSpace.chromaLocation.rawValue) : nil
        )
    }

    var codecsColorSpace: WebKit.LibWebRTCCodecsColorSpace {
        var colorSpace = WebKit.LibWebRTCCodecsColorSpace()
        if let primaries, let value = WebCore.PlatformVideoColorPrimaries(rawValue: primaries.rawValue) {
            colorSpace.hasPrimaries = true
            colorSpace.primaries = value
        }
        if let transfer, let value = WebCore.PlatformVideoTransferCharacteristics(rawValue: transfer.rawValue) {
            colorSpace.hasTransfer = true
            colorSpace.transfer = value
        }
        if let matrix, let value = WebCore.PlatformVideoMatrixCoefficients(rawValue: matrix.rawValue) {
            colorSpace.hasMatrix = true
            colorSpace.matrix = value
        }
        if let fullRange {
            colorSpace.hasFullRange = true
            colorSpace.fullRange = fullRange
        }
        if let chromaLocation, let value = WebCore.PlatformVideoChromaLocation(rawValue: chromaLocation.rawValue) {
            colorSpace.hasChromaLocation = true
            colorSpace.chromaLocation = value
        }
        return colorSpace
    }
}

private func pixelBufferAttributes(_ format: CMFormatDescription) -> CFDictionary {
    let isFullRange = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool) ?? false
    let bitDepth = (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int32) ?? 8
    assert(bitDepth == 8 || bitDepth == 10)

    let pixelFormat: OSType =
        if bitDepth > 8 {
            isFullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            isFullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    #if os(macOS)
    let compatibilityKey = kCVPixelBufferOpenGLCompatibilityKey
    #else
    let compatibilityKey = kCVPixelBufferExtendedPixelsRightKey
    #endif
    let attributes: [CFString: Any] = [
        compatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        kCVPixelBufferPixelFormatTypeKey: Int64(pixelFormat),
    ]
    return attributes as CFDictionary
}

// A sample buffer holding a copy of the bytes.
private func makeSampleBuffer(_ data: IPC.LentBytes, format: CMFormatDescription) -> CMSampleBuffer? {
    let count = data.size()
    var blockBufferOut: CMBlockBuffer?
    let createStatus = unsafe CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: count,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBufferOut
    )
    guard createStatus == noErr, let blockBuffer = blockBufferOut else {
        WebKit.LogChannel.Media().releaseLog.error("CMBlockBufferCreateWithMemoryBlock failed with: \(createStatus)")
        return nil
    }

    var lengthAtOffset = 0
    var dataPointer: UnsafeMutablePointer<CChar>?
    let pointerStatus = unsafe CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
    guard pointerStatus == noErr, lengthAtOffset == count, let dataPointer = unsafe dataPointer else {
        WebKit.LogChannel.Media().releaseLog.error("CMBlockBufferReplaceDataBytes failed with: \(pointerStatus)")
        return nil
    }
    // Safety: kCMBlockBufferAssureMemoryNowFlag made the block buffer allocate `count` contiguous bytes, which it keeps
    // while this holds it, and nothing else uses them yet.
    let destination = unsafe UnsafeMutableRawBufferPointer(start: dataPointer, count: count).bindMemory(to: UInt8.self)
    if #available(macOS 26, iOS 26, visionOS 26, *) {
        var span = unsafe destination.mutableSpan
        data.copyBytes(into: &span)
    } else {
        for index in 0..<count {
            unsafe destination[index] = data.byteAt(index)
        }
    }

    var sampleBufferOut: CMSampleBuffer?
    let sampleStatus = unsafe CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleCount: 1,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBufferOut
    )
    guard sampleStatus == noErr, let sampleBuffer = sampleBufferOut else {
        WebKit.LogChannel.Media().releaseLog.error("CMSampleBufferCreate failed with: \(sampleStatus)")
        return nil
    }
    return sampleBuffer
}

// A decoder of LibWebRTCCodecsProxy.swift, over a VideoToolbox decompression session, on the codecs queue. It decodes
// with the format description of the last video info it was given, overridden by the colour space override.
final class LibWebRTCCodecsDecoder {
    let output: LibWebRTCCodecsDecoderOutput
    private let identifier: IPCTypes.VideoDecoderIdentifier
    private var receivedFrameRateMonitor: LibWebRTCCodecsFrameRateMonitor?
    private var colorSpaceOverride: IPCTypes.PlatformVideoColorSpace?
    private var videoInfo: WebCore.VideoInfo?
    private var format: CMFormatDescription?
    private var session: VTDecompressionSession?
    private var reorderSize: UInt8 = 0
    // Set once the stream has reordered frames, and never reset, so that the frames waiting in the queue go out.
    private var usesReorderQueue = false

    init(identifier: IPCTypes.VideoDecoderIdentifier, output: LibWebRTCCodecsDecoderOutput, colorSpaceOverride: IPCTypes.PlatformVideoColorSpace?, logsReceivedFrames: Bool) {
        self.identifier = identifier
        self.output = output
        self.colorSpaceOverride = colorSpaceOverride
        receivedFrameRateMonitor = logsReceivedFrames ? LibWebRTCCodecsFrameRateMonitor() : nil
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func flush() {
        if let session {
            _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        if usesReorderQueue {
            output.flushReorderQueue()
        }
    }

    func setFormat(videoInfo: WebCore.VideoInfo?) {
        if let videoInfo {
            setVideoInfo(videoInfo)
        }
    }

    func setColorSpaceOverride(_ colorSpaceOverride: IPCTypes.PlatformVideoColorSpace?) {
        self.colorSpaceOverride = colorSpaceOverride
        if let videoInfo {
            updateFormat(videoInfo)
        }
    }

    // Whether the frame was given to the session, whose result goes to the output, or was dropped because there is no
    // format yet, or couldn't be decoded.
    enum DecodeFrameResult {
        case decoding
        case noFormat
        case failed
    }

    func decodeFrame(timeStamp: Int64, data: IPC.LentBytes, videoInfo: WebCore.VideoInfo?) -> DecodeFrameResult {
        if let lateFrame = receivedFrameRateMonitor?.update() {
            logLateFrame(lateFrame, decoder: identifier.rawValue, event: .received)
        }

        if let videoInfo {
            setVideoInfo(videoInfo)
        }

        guard let format else {
            return .noFormat
        }

        guard let sampleBuffer = makeSampleBuffer(data, format: format) else {
            return .failed
        }

        guard let session = sessionAccepting(format) else {
            return .failed
        }

        _ = CMSampleBufferSetOutputPresentationTimeStamp(sampleBuffer, newValue: CMTimeMake(value: timeStamp, timescale: 1))
        let output = output
        let usesReorderQueue = usesReorderQueue
        let reorderSize = reorderSize
        let status = __VTDecompressionSessionDecodeFrameWithMultiImageCapableOutputHandler(
            session,
            sampleBuffer,
            ._EnableAsynchronousDecompression,
            nil
        ) { _, _, imageBuffer, _, presentationTimeStamp, _ in
            output.sessionDidOutput(imageBuffer.map(cvPixelBuffer), timeStamp: presentationTimeStamp.value, usesReorderQueue: usesReorderQueue, reorderSize: reorderSize)
        }
        if status != noErr {
            output.sessionDidOutput(nil, timeStamp: 0, usesReorderQueue: usesReorderQueue, reorderSize: reorderSize)
        }
        return .decoding
    }

    private func sessionAccepting(_ format: CMFormatDescription) -> VTDecompressionSession? {
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            return session
        }
        if let session {
            self.session = nil
            _ = VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }

        let decoderSpecification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        var sessionOut: VTDecompressionSession?
        let status = unsafe VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: pixelBufferAttributes(format),
            outputCallback: nil,
            decompressionSessionOut: &sessionOut
        )
        guard status == noErr else {
            return nil
        }
        session = sessionOut
        return sessionOut
    }

    private func setVideoInfo(_ videoInfo: WebCore.VideoInfo) {
        updateFormat(videoInfo)
        reorderSize = Optional(fromCxx: videoInfo.reorderQueueMaxSize()) ?? 0
        self.videoInfo = videoInfo
        if reorderSize != 0 {
            usesReorderQueue = true
        }
    }

    private func updateFormat(_ videoInfo: WebCore.VideoInfo) {
        format = WebKit.createDecoderFormatDescription(videoInfo, colorSpaceOverride?.codecsColorSpace ?? WebKit.LibWebRTCCodecsColorSpace())
    }
}

// Xcode builds import WebKit's CVPixelBuffer as a class of its own, distinct from VideoToolbox's CVImageBuffer.
private func cvPixelBuffer<Buffer: AnyObject>(_ buffer: Buffer) -> CVPixelBuffer {
    buffer as! CVPixelBuffer
}

#endif
