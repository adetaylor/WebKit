// Copyright (C) 2023-2024 Apple Inc. All rights reserved.
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

// The video sample renderer's core: the compressed and decoded sample queues, the decoding decisions, which frame is
// displayed and when the decoded queue is purged, readiness for more samples, and the playback statistics. It owns
// the AVSampleBufferVideoRenderer that the renderer's queue enqueues decoded frames into. VideoMediaSampleRenderer.mm
// keeps the C++ renderer that AudioVideoRendererAVFObjC holds: the clients' callbacks and promises, the observation of
// the renderer, the main thread's renderer or display layer, the timebase and its purge timer, the decompression
// session and the logger, which this reaches through VideoMediaSampleRendererHost.
//
// WebCore soft-links AVFoundation and CoreMedia: their symbols come from the generated accessors (platform/cocoa/
// SoftLinkAccessors.in). No AVFoundation class is used where its class object would be needed.
//
// Threads: state marked "queue" is the renderer queue's (host.dispatchQueue()); state marked "main" is the main
// thread's; the rest is atomic or under `lock`, as in the C++ renderer.

internal import AVFoundation
internal import CoreMedia
internal import Synchronization
import WebCore_Private.Core.VideoMediaSampleRendererHost

// MediaTime's semantics over CMTime, as PAL's toMediaTime() maps one to the other.

private enum TimeOrdering {
    case less
    case equivalent
    case greater
    case unordered
}

private let timeValid = CMTimeFlags.valid
private let timeSpecial: CMTimeFlags = [.positiveInfinity, .negativeInfinity, .indefinite]

private func mediaTimeFlags(_ time: CMTime) -> CMTimeFlags {
    guard time.flags.contains(timeValid) else {
        return []
    }
    return time.flags.intersection([.valid, .positiveInfinity, .negativeInfinity, .indefinite])
}

private func compareTimes(_ a: CMTime, _ b: CMTime) -> TimeOrdering {
    let aFlags = mediaTimeFlags(a)
    let bFlags = mediaTimeFlags(b)
    let andFlags = aFlags.intersection(bFlags)
    if !andFlags.intersection(timeSpecial).isEmpty {
        return .equivalent
    }
    let orFlags = aFlags.union(bFlags)
    if !orFlags.contains(timeValid) {
        return .equivalent
    }
    if !andFlags.contains(timeValid) {
        return .unordered
    }
    if orFlags.contains(.negativeInfinity) {
        return aFlags.contains(.negativeInfinity) ? .less : .greater
    }
    if orFlags.contains(.positiveInfinity) {
        return aFlags.contains(.positiveInfinity) ? .greater : .less
    }
    if orFlags.contains(.indefinite) {
        return aFlags.contains(.indefinite) ? .greater : .less
    }
    let result = CMTimeCompare(a, b)
    return result < 0 ? .less : (result > 0 ? .greater : .equivalent)
}

private struct RendererTime {
    var time: CMTime

    static let invalid = RendererTime(time: CMTime(value: 0, timescale: 0, flags: [], epoch: 0))
    static let zero = RendererTime(time: CMTime(value: 0, timescale: 1, flags: .valid, epoch: 0))
    static let positiveInfinite = RendererTime(time: CMTime(value: 0, timescale: 1, flags: [.valid, .positiveInfinity], epoch: 0))

    var isValid: Bool { time.flags.contains(timeValid) }
    var isInvalid: Bool { !isValid }
    var isPositiveInfinite: Bool { mediaTimeFlags(time).contains(.positiveInfinity) }
    var isFinite: Bool { isValid && mediaTimeFlags(time).intersection(timeSpecial).isEmpty }

    var seconds: Double {
        guard isValid else {
            return .nan
        }
        if isPositiveInfinite {
            return .infinity
        }
        if mediaTimeFlags(time).contains(.negativeInfinity) {
            return -.infinity
        }
        return CMTimeGetSeconds(time)
    }

    static func < (a: RendererTime, b: RendererTime) -> Bool { compareTimes(a.time, b.time) == .less }
    static func > (a: RendererTime, b: RendererTime) -> Bool { compareTimes(a.time, b.time) == .greater }
    static func <= (a: RendererTime, b: RendererTime) -> Bool {
        let ordering = compareTimes(a.time, b.time)
        return ordering == .less || ordering == .equivalent
    }
    static func >= (a: RendererTime, b: RendererTime) -> Bool {
        let ordering = compareTimes(a.time, b.time)
        return ordering == .greater || ordering == .equivalent
    }
    static func == (a: RendererTime, b: RendererTime) -> Bool { compareTimes(a.time, b.time) == .equivalent }
    static func != (a: RendererTime, b: RendererTime) -> Bool { !(a == b) }

    // MediaTime's operator+ for the flags; CoreMedia's addition for two finite times.
    static func + (a: RendererTime, b: RendererTime) -> RendererTime {
        let aFlags = mediaTimeFlags(a.time)
        let bFlags = mediaTimeFlags(b.time)
        if !aFlags.contains(timeValid) || !bFlags.contains(timeValid) {
            return .invalid
        }
        if aFlags.contains(.indefinite) || bFlags.contains(.indefinite) {
            return RendererTime(time: CMTime(value: 0, timescale: 1, flags: [.valid, .indefinite], epoch: 0))
        }
        if (aFlags.contains(.positiveInfinity) && bFlags.contains(.negativeInfinity)) || (aFlags.contains(.negativeInfinity) && bFlags.contains(.positiveInfinity)) {
            return .invalid
        }
        if aFlags.contains(.positiveInfinity) || bFlags.contains(.positiveInfinity) {
            return .positiveInfinite
        }
        if aFlags.contains(.negativeInfinity) || bFlags.contains(.negativeInfinity) {
            return RendererTime(time: CMTime(value: 0, timescale: 1, flags: [.valid, .negativeInfinity], epoch: 0))
        }
        return RendererTime(time: CMTimeAdd(a.time, b.time))
    }
}

private func maxTime(_ a: RendererTime, _ b: RendererTime) -> RendererTime { a < b ? b : a }
private func minTime(_ a: RendererTime, _ b: RendererTime) -> RendererTime { b < a ? b : a }

private func describe(_ time: RendererTime) -> Swift.String {
    if time.isInvalid {
        return "{invalid}"
    }
    if time.isPositiveInfinite {
        return "{+inf}"
    }
    return "{\(time.time.value)/\(time.time.timescale) = \(time.seconds)}"
}

private func utf8(_ string: Swift.String) -> ContiguousArray<UInt8> {
    ContiguousArray(string.utf8)
}

// A decoded frame, or a sample already decoded when it was enqueued.
private struct DecodedSample: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: RendererTime
}

private struct CompressedSample: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let info: WebCore.VideoMediaSampleRendererSampleInfo
    let minimumUpcomingTime: RendererTime?
    let flushId: Int32
    // Whether the decompression session was blocked when it was enqueued; or, for a sample already decoded, true.
    let decompressionSessionBlocked: Bool
}

private enum DecodedFrameResult {
    case tooEarly
    case tooLate
    case alreadyDisplayed
    case displayed
}

// WebCoreDecompressionSession::DecodingFlag.
private struct DecodingFlags: OptionSet {
    let rawValue: UInt8
    static let nonDisplaying = DecodingFlags(rawValue: 1 << 0)
    static let realTime = DecodingFlags(rawValue: 1 << 1)
    static let enableStereo = DecodingFlags(rawValue: 1 << 2)
}

// WebCore::VideoRendererPreference.
private struct RendererPreferences: OptionSet {
    let rawValue: UInt8
    static let prefersDecompressionSession = RendererPreferences(rawValue: 1 << 0)
    static let protectedFallbackDisabled = RendererPreferences(rawValue: 1 << 1)
    static let useDecompressionSessionForProtectedContent = RendererPreferences(rawValue: 1 << 2)
    static let useStereoDecoding = RendererPreferences(rawValue: 1 << 3)
}

// What VideoMediaSampleRendererCore.enqueueSample() leaves to the C++ renderer.
private enum EnqueueAction: UInt8 {
    case none = 0
    case enqueueToRenderer = 1
}

private func presentationTimeOfDecodedFrame(_ sampleBuffer: CMSampleBuffer) -> RendererTime {
    var time = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
    if !time.flags.contains(timeValid) {
        time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    }
    return RendererTime(time: time)
}

// What VideoMediaSampleRenderer.mm calls.
@_expose(Cxx)
final class VideoMediaSampleRendererCore: @unchecked Sendable {
    private let host: WebCore.VideoMediaSampleRendererHost
    private let queue: DispatchQueue
    private let lowWaterMark: RendererTime
    private let highWaterMark: RendererTime
    private let sampleQueueHighWaterMark: Int
    private let sampleQueueLowWaterMark: Int

    // Atomic, or under the lock: read on both threads.
    private let flushIdValue = Atomic<Int32>(0)
    private let compressedSamplesCountValue = Atomic<Int>(0)
    private let pendingSamplesCountValue = Atomic<Int>(0)
    private let isUsingDecompressionSessionValue = Atomic<Bool>(false)
    private let isReceivingDecodedSamplesValue = Atomic<Bool>(false)
    private let lastEnqueuedSampleWasDecodedValue = Atomic<Bool>(false)
    private let waitingForMoreMediaDataPendingValue = Atomic<Bool>(false)
    private let notifyWhenHasAvailableVideoFrameValue = Atomic<Bool>(false)
    private let gotDecodingErrorValue = Atomic<Bool>(false)
    private let hasResourceOwnerValue = Atomic<Bool>(false)
    // Set on the main thread, read on both; it doesn't change once the decompression session is in use.
    private let preferencesValue = Atomic<UInt8>(0)
    private let totalVideoFramesValue = Atomic<UInt32>(0)
    private let droppedVideoFramesValue = Atomic<UInt32>(0)
    private let corruptedVideoFramesValue = Atomic<UInt32>(0)
    private let presentedVideoFramesValue = Atomic<UInt32>(0)
    private let hasDecompressionSession = Mutex<Bool>(false)
    private let startupTime = Mutex<Double>(0)

    // Main.
    private var decompressionSessionBlocked = false
    private var droppedVideoFramesOffset: UInt32 = 0
    private var sampleCount: UInt32 = 0
    private var currentCodec: FourCharCode?
    private var copiedPresentationTime = RendererTime.invalid

    // Queue.
    private var renderer: (any SampleBufferRenderer)?
    private var compressedSampleQueue: [CompressedSample] = []
    private var decodedSampleQueue: [DecodedSample] = []
    private var decompressionSessionWasBlocked = false
    private var isDecodingSample = false
    private var isDisplayingSample = false
    private var forceLateSampleToBeDisplayed = false
    private var lastDisplayedTime: RendererTime?
    private var lastDisplayedSample: RendererTime?
    private var nextScheduledPurge: RendererTime?
    private var notifiedFirstFrameAvailable = false
    private var waitingForMoreMediaData = false
    private var lastMinimumUpcomingPresentationTime = RendererTime.invalid
    private var decoderIdledAtHighWaterMark = false
    private var hasReachedHighWatermark = false
    private var wasProtected = false
    private var timeSinceLastDecode: Double = 0
    // The sample being decoded: one at a time.
    private var decodeStartTime: Double = 0
    private var decodingFlags = DecodingFlags()
    private var decodingNumberOfSamples = 0

    // The renderer is the AVSampleBufferVideoRenderer of the C++ renderer's renderer or display layer, or nil. It is
    // borrowed.
    @_expose(Cxx)
    init(_ host: WebCore.VideoMediaSampleRendererHost, _ renderer: borrowing NSObject?, _ decodeWindow: WebCore.VideoMediaSampleRendererDecodeWindow) {
        self.host = host
        queue = host.dispatchQueue()
        lowWaterMark = RendererTime(time: decodeWindow.lowWaterMark)
        highWaterMark = RendererTime(time: decodeWindow.highWaterMark)
        sampleQueueHighWaterMark = decodeWindow.sampleQueueHighWaterMark
        sampleQueueLowWaterMark = decodeWindow.sampleQueueLowWaterMark
        self.renderer = rendererHandle(copy renderer)
    }

    // MARK: Logging

    private func log(_ level: WebCore.VideoMediaSampleRendererLogLevel, _ message: @autoclosure () -> Swift.String) {
        guard host.willLog(level) else {
            return
        }
        let bytes = utf8(message())
        host.log(level, bytes.span)
    }

    private func assertOnQueue() {
#if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
#endif
    }

    private func assertOnMain() {
#if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
#endif
    }

    private var flushId: Int32 { flushIdValue.load(ordering: .sequentiallyConsistent) }
    private var compressedSamplesCount: Int {
        compressedSamplesCountValue.load(ordering: .sequentiallyConsistent) + pendingSamplesCountValue.load(ordering: .sequentiallyConsistent)
    }
    private var decodedSamplesCount: Int { decodedSampleQueue.count }

    // MonotonicTime's clock, as the C++ renderer measured it: seconds since its first sample, or since boot before it.
    private func secondsSinceStartup() -> Double {
        ProcessInfo.processInfo.systemUptime - startupTime.withLock { $0 }
    }

    private func noteStartupIfNeeded() {
        startupTime.withLock { start in
            if start == 0 {
                start = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private func currentTime() -> RendererTime {
        host.hasTimebase() ? RendererTime(time: host.timebaseTime()) : .invalid
    }

    private func increment(_ counter: borrowing Atomic<UInt32>, by amount: UInt32 = 1) {
        counter.wrappingAdd(amount, ordering: .sequentiallyConsistent)
    }

    // MARK: State, for the C++ renderer (main thread)

    @_expose(Cxx)
    func setPreferences(_ rawValue: UInt8) {
        assertOnMain()
        if preferences.rawValue == rawValue || isUsingDecompressionSession() {
            return
        }
        preferencesValue.store(rawValue, ordering: .sequentiallyConsistent)
    }

    private var preferences: RendererPreferences {
        RendererPreferences(rawValue: preferencesValue.load(ordering: .sequentiallyConsistent))
    }

    @_expose(Cxx)
    func prefersDecompressionSession() -> Bool {
        preferences.contains(.prefersDecompressionSession)
    }

    private var useDecompressionSessionForProtectedContent: Bool { preferences.contains(.useDecompressionSessionForProtectedContent) }
    private var useDecompressionSessionForProtectedFallback: Bool { useDecompressionSessionForProtectedContent || preferences.contains(.protectedFallbackDisabled) }
    private var useStereoDecoding: Bool { preferences.contains(.useStereoDecoding) }

    @_expose(Cxx)
    func isUsingDecompressionSession() -> Bool {
        isUsingDecompressionSessionValue.load(ordering: .sequentiallyConsistent)
    }

    @_expose(Cxx)
    func isReceivingDecodedSamples() -> Bool {
        lastEnqueuedSampleWasDecodedValue.load(ordering: .sequentiallyConsistent)
    }

    @_expose(Cxx)
    func managesDecodedFrames() -> Bool {
        isUsingDecompressionSession() || isReceivingDecodedSamplesValue.load(ordering: .sequentiallyConsistent)
    }

    @_expose(Cxx)
    func areSamplesQueuesReadyForMoreMediaData() -> Bool {
        compressedSamplesCount <= sampleQueueHighWaterMark
    }

    @_expose(Cxx)
    func setHasResourceOwner(_ hasResourceOwner: Bool) {
        hasResourceOwnerValue.store(hasResourceOwner, ordering: .sequentiallyConsistent)
    }

    @_expose(Cxx)
    func setNotifyWhenHasAvailableVideoFrame(_ notify: Bool) {
        notifyWhenHasAvailableVideoFrameValue.store(notify, ordering: .sequentiallyConsistent)
    }

    @_expose(Cxx)
    func secondsSinceFirstSample() -> Double {
        secondsSinceStartup()
    }

    @_expose(Cxx)
    func totalDisplayedFrames() -> UInt32 {
        assertOnMain()
        if managesDecodedFrames() {
            return presentedVideoFramesValue.load(ordering: .sequentiallyConsistent)
        }
        sampleCount &+= 1
        return sampleCount
    }

    @_expose(Cxx)
    func metrics() -> WebCore.VideoMediaSampleRendererMetrics {
        WebCore.VideoMediaSampleRendererMetrics(
            totalVideoFrames: totalVideoFramesValue.load(ordering: .sequentiallyConsistent),
            droppedVideoFrames: droppedVideoFramesValue.load(ordering: .sequentiallyConsistent),
            corruptedVideoFrames: corruptedVideoFramesValue.load(ordering: .sequentiallyConsistent),
            presentedVideoFrames: presentedVideoFramesValue.load(ordering: .sequentiallyConsistent),
            droppedVideoFramesOffset: droppedVideoFramesOffset,
            totalFrameDelay: 0,
            decompressionSessionBlocked: decompressionSessionBlocked
        )
    }

    // MARK: Renderer

    // On the queue, for changeRenderer().
    @_expose(Cxx)
    func changeRendererOnQueue(_ newRenderer: NSObject?) {
        assertOnQueue()
        let videoRenderer = rendererHandle(newRenderer)
        if let previousRenderer = renderer {
            previousRenderer.flush()
            previousRenderer.stopRequestingMediaData()
        }
        renderer = videoRenderer
        if !managesDecodedFrames() {
            return
        }
        purgeDecodedSampleQueue(flushId)
        if let videoRenderer {
            for sample in decodedSampleQueue {
                videoRenderer.enqueue(sample.sampleBuffer)
            }
        }
        waitingForMoreMediaData = false
        maybeBecomeReadyForMoreMediaData()
    }

    // MARK: Readiness

    private func maybeBecomeReadyForMoreMediaData() {
        assertOnQueue()
        if let renderer, !renderer.isReadyForMoreMediaData {
            if waitingForMoreMediaData {
                return
            }
            waitingForMoreMediaData = true
            let weakRenderer = renderer.weakReference()
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                weakRenderer.stopRequestingMediaData()
                guard let self else {
                    return
                }
                self.assertOnQueue()
                self.waitingForMoreMediaData = false
                self.maybeBecomeReadyForMoreMediaData()
            }
            return
        }

        if compressedSamplesCount > sampleQueueLowWaterMark {
            return
        }

        if waitingForMoreMediaDataPendingValue.exchange(true, ordering: .sequentiallyConsistent) {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.waitingForMoreMediaDataPendingValue.store(false, ordering: .sequentiallyConsistent)
            self.host.requestMediaDataResolved()
        }
    }

    // For resetReadyForMoreMediaData(), when the queue decides.
    @_expose(Cxx)
    func checkReadyForMoreMediaData() {
        queue.async { [weak self] in
            self?.maybeBecomeReadyForMoreMediaData()
        }
    }

    @_expose(Cxx)
    func stopRequestingMediaData() {
        // stopRequestingMediaData may deadlock if used on the main thread while enqueuing on the queue.
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.waitingForMoreMediaData = false
            self.renderer?.stopRequestingMediaData()
        }
    }

    // MARK: Enqueuing (main thread)

    // Returns an EnqueueAction.
    @_expose(Cxx)
    func enqueueSample(_ sampleBuffer: CMSampleBuffer, _ info: WebCore.VideoMediaSampleRendererSampleInfo, _ hasMinimumUpcomingTime: Bool, _ minimumUpcomingTime: CMTime, _ hasRenderer: Bool) -> UInt8 {
        assertOnMain()
        let minimumUpcoming = hasMinimumUpcomingTime ? RendererTime(time: minimumUpcomingTime) : nil

        if info.hasImageBuffer {
            lastEnqueuedSampleWasDecodedValue.store(true, ordering: .sequentiallyConsistent)
            enqueueAlreadyDecodedSample(sampleBuffer, info)
            return EnqueueAction.none.rawValue
        }
        lastEnqueuedSampleWasDecodedValue.store(false, ordering: .sequentiallyConsistent)

        var needsDecompressionSession = false
#if ENABLE_VP9
        if !isUsingDecompressionSession() && currentCodec == nil {
            // Only use a decompression session for vp8 or vp9 when software decoded.
            let fourCC = CMSampleBufferGetFormatDescription(sampleBuffer).map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            needsDecompressionSession = fourCC == vp8FourCC || (fourCC == vp9FourCC && !host.vp9HardwareDecoderAvailable())
            currentCodec = fourCC
        }
#endif

        let hasSession = hasDecompressionSession.withLock { $0 }
        if !decompressionSessionBlocked && !hasSession && (!hasRenderer || ((prefersDecompressionSession() || needsDecompressionSession || isUsingDecompressionSession()) && (!info.isProtected || useDecompressionSessionForProtectedContent))) {
            initializeDecompressionSession()
        }

        if !isUsingDecompressionSession() {
            if !isReceivingDecodedSamplesValue.load(ordering: .sequentiallyConsistent) {
                return EnqueueAction.enqueueToRenderer.rawValue
            }

            // Decoded samples reach the renderer from the queue, so compressed samples follow the same path to stay behind them.
            pendingSamplesCountValue.wrappingAdd(1, ordering: .sequentiallyConsistent)
            let sampleFlushId = flushId
            let sample = DecodedSample(sampleBuffer: sampleBuffer, presentationTime: RendererTime(time: info.presentationTime))
            queue.async { [weak self] in
                guard let self else {
                    return
                }
                self.pendingSamplesCountValue.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                if sampleFlushId == self.flushId {
                    self.increment(self.totalVideoFramesValue)
                    self.increment(self.presentedVideoFramesValue)
                    self.renderer?.enqueue(sample.sampleBuffer)
                }
                self.maybeBecomeReadyForMoreMediaData()
            }
            return EnqueueAction.none.rawValue
        }

        if !useDecompressionSessionForProtectedFallback && !decompressionSessionBlocked && info.isProtected {
            decompressionSessionBlocked = true
            let numberOfDroppedVideoFrames = host.rendererDroppedVideoFrames()
            let dropped = droppedVideoFramesValue.load(ordering: .sequentiallyConsistent)
            if dropped >= numberOfDroppedVideoFrames {
                droppedVideoFramesOffset = dropped - numberOfDroppedVideoFrames
            }
        }
        pendingSamplesCountValue.wrappingAdd(1, ordering: .sequentiallyConsistent)
        let sample = CompressedSample(sampleBuffer: sampleBuffer, info: info, minimumUpcomingTime: minimumUpcoming, flushId: flushId, decompressionSessionBlocked: decompressionSessionBlocked)
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.pendingSamplesCountValue.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            if sample.flushId != self.flushId {
                self.compressedSamplesCountValue.store(0, ordering: .sequentiallyConsistent)
                self.compressedSampleQueue.removeAll()
                self.maybeBecomeReadyForMoreMediaData()
                return
            }
            self.compressedSampleQueue.append(sample)
            self.decodeNextSampleIfNeeded()
            self.compressedSamplesCountValue.store(self.compressedSampleQueue.count, ordering: .sequentiallyConsistent)
        }
        return EnqueueAction.none.rawValue
    }

    private func initializeDecompressionSession() {
        log(.Always, "VideoMediaSampleRenderer::initializeDecompressionSession")
        assertOnMain()
        if hasDecompressionSession.withLock({ $0 }) {
            return
        }
        host.initializeDecompressionSession()
        hasDecompressionSession.withLock { $0 = true }
        isUsingDecompressionSessionValue.store(true, ordering: .sequentiallyConsistent)
        noteStartupIfNeeded()
        resetReadyForMoreMediaDataFromCore()
    }

    // resetReadyForMoreMediaData() when the renderer manages decoded frames, which it then does.
    private func resetReadyForMoreMediaDataFromCore() {
        checkReadyForMoreMediaData()
    }

    private func enqueueAlreadyDecodedSample(_ sampleBuffer: CMSampleBuffer, _ info: WebCore.VideoMediaSampleRendererSampleInfo) {
        assertOnMain()
        if !isReceivingDecodedSamplesValue.exchange(true, ordering: .sequentiallyConsistent) {
            log(.Always, "VideoMediaSampleRenderer::enqueueAlreadyDecodedSample Receiving decoded samples")
            noteStartupIfNeeded()
            resetReadyForMoreMediaDataFromCore()
        }

        pendingSamplesCountValue.wrappingAdd(1, ordering: .sequentiallyConsistent)
        let sampleFlushId = flushId
        let decodedSample = DecodedSample(sampleBuffer: sampleBuffer, presentationTime: RendererTime(time: info.presentationTime))
        let compressedSample = CompressedSample(sampleBuffer: sampleBuffer, info: info, minimumUpcomingTime: nil, flushId: sampleFlushId, decompressionSessionBlocked: true)
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.pendingSamplesCountValue.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            if sampleFlushId != self.flushId {
                self.maybeBecomeReadyForMoreMediaData()
                return
            }
            self.increment(self.totalVideoFramesValue)
            if self.hasDecompressionSession.withLock({ $0 }) && (!self.compressedSampleQueue.isEmpty || self.isDecodingSample) {
                // Compressed samples are still waiting to be decoded; the decoded sample goes through the same queue to stay behind them.
                self.compressedSampleQueue.append(compressedSample)
                self.compressedSamplesCountValue.store(self.compressedSampleQueue.count, ordering: .sequentiallyConsistent)
                return
            }
            self.decodedFrameAvailable(decodedSample, sampleFlushId)
            self.maybeBecomeReadyForMoreMediaData()
        }
    }

    // MARK: Decoding (queue)

    private func decodeNextSampleIfNeeded() {
        assertOnQueue()

        if gotDecodingErrorValue.load(ordering: .sequentiallyConsistent) || !hasDecompressionSession.withLock({ $0 }) {
            return
        }

        let hasTimebase = host.hasTimebase()
        let currentTime = hasTimebase ? RendererTime(time: host.timebaseTime()) : RendererTime.invalid
        let playbackRate = hasTimebase ? host.timebaseRate() : 0
        let nextDecodedSampleTime = decodedSampleQueue.first?.presentationTime ?? .zero
        let lowWaterMarkTime = currentTime.isValid ? maxTime(currentTime, nextDecodedSampleTime) + lowWaterMark : RendererTime.invalid
        let highWaterMarkTime = currentTime.isValid ? maxTime(currentTime, nextDecodedSampleTime) + highWaterMark : RendererTime.invalid

        log(.Debug, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded currentTime: \(describe(currentTime)) rate: \(playbackRate) nextDecodedSampleTime: \(describe(nextDecodedSampleTime)) lowWaterMarkTime: \(describe(lowWaterMarkTime)) highWaterMarkTime: \(describe(highWaterMarkTime)) compressedSampleQueue: \(compressedSampleQueue.count) m_isDecodingSample:\(isDecodingSample)")

        while !compressedSampleQueue.isEmpty && !isDecodingSample {
            var decodingFlags = DecodingFlags()

            let endTime = decodedSampleQueue.last?.presentationTime ?? .invalid

            if currentTime.isValid && !wasProtected && !decompressionSessionWasBlocked {
                // Hysteresis: once we stopped at the high watermark, stay idle
                // until the decoded buffer drains below the low watermark.
                if decoderIdledAtHighWaterMark {
                    if endTime.isValid && endTime >= lowWaterMarkTime {
                        return
                    }
                    decoderIdledAtHighWaterMark = false
                }

                if endTime.isValid && endTime > highWaterMarkTime {
                    hasReachedHighWatermark = true
                    let first = compressedSampleQueue[0]
                    let samplePresentationTime = RendererTime(time: first.info.presentationTime)
                    // Tri-state on the minimum upcoming time:
                    //   nil         -> the caller did not supply a bound; use the sample's presentation time as an
                    //                  internal ceiling. Do not publish a floor to AVF: external floors are only
                    //                  promised when a caller has explicitly asserted a lookahead.
                    //   not finite  -> the caller marked it as unknown (indefinite); keep decoding unbounded.
                    //   finite      -> a caller-supplied lookahead bound; use it and publish the floor to AVF.
                    let explicitUnknown = first.minimumUpcomingTime.map { !$0.isFinite } ?? false
                    if !explicitUnknown {
                        let callerSuppliedBound = first.minimumUpcomingTime != nil
                        let upcomingMinimum = first.minimumUpcomingTime.map { minTime(samplePresentationTime, $0) } ?? samplePresentationTime
                        if endTime < upcomingMinimum {
                            if callerSuppliedBound && (lastMinimumUpcomingPresentationTime.isInvalid || upcomingMinimum != lastMinimumUpcomingPresentationTime) {
                                lastMinimumUpcomingPresentationTime = upcomingMinimum
                                log(.Performance, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded currentTime:\(formatSeconds(currentTime)) expectMinimumUpcomingSampleBufferPresentationTime:\(formatSeconds(lastMinimumUpcomingPresentationTime)) decoded queued:\(decodedSamplesCount) upcoming:\(compressedSamplesCount) high watermark reached")
                                renderer?.expectMinimumUpcomingSampleBufferPresentationTime(lastMinimumUpcomingPresentationTime.time)
                            }
                            decoderIdledAtHighWaterMark = true
                            return
                        }
                        if callerSuppliedBound {
                            log(.Debug, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded Out of order frames detected, forcing extra decode")
                        }
                    }
                }
            }

            let sample = compressedSampleQueue.removeFirst()
            compressedSamplesCountValue.store(compressedSampleQueue.count, ordering: .sequentiallyConsistent)

            maybeBecomeReadyForMoreMediaData()

            if sample.flushId != flushId {
                log(.Debug, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded Flush detected")
                continue
            }

            if !shouldDecodeSample(sample) {
                log(.Debug, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded shouldDecodeSample: false")
                increment(totalVideoFramesValue)
                increment(droppedVideoFramesValue)
                continue
            }

            if !useDecompressionSessionForProtectedFallback && wasProtected != sample.info.isProtected {
                log(.Always, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded Changing protection type (was: \(wasProtected)) content at:\(describe(RendererTime(time: sample.info.presentationTime)))")
                wasProtected = sample.info.isProtected
            }

            decompressionSessionWasBlocked = sample.decompressionSessionBlocked
            if sample.decompressionSessionBlocked {
                decodedFrameAvailable(DecodedSample(sampleBuffer: sample.sampleBuffer, presentationTime: RendererTime(time: sample.info.presentationTime)), sample.flushId)
                continue
            }

            if sample.info.isNonDisplaying {
                decodingFlags.insert(.nonDisplaying)
            }
            if useStereoDecoding {
                decodingFlags.insert(.enableStereo)
            }
            // Mirror AVF's RealTime policy. On iOS-family the flag is set
            // whenever we're in normal 1x playback and the sample is displaying.
            // On macOS it is additionally suppressed during the
            // kVMC2DecayingFromHighWaterLevel state: we have previously crossed
            // the high watermark at least once since the last flush, and the
            // decoded buffer has since drained below the low watermark.
#if os(macOS)
            let suppressRealTime = hasReachedHighWatermark && endTime.isValid && endTime < lowWaterMarkTime
#else
            let suppressRealTime = false
#endif
            if currentTime.isValid && !sample.info.isNonDisplaying && playbackRate > 0.9 && playbackRate < 1.1 && !suppressRealTime {
                log(.Performance, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded RealTime set currentTime:\(formatSeconds(currentTime)) endTime:\(formatSeconds(endTime)) low:\(formatSeconds(lowWaterMarkTime)) high:\(formatSeconds(highWaterMarkTime)) reachedHigh:\(hasReachedHighWatermark ? 1 : 0)")
                decodingFlags.insert(.realTime)
            }

            isDecodingSample = true
            self.decodingFlags = decodingFlags
            decodingNumberOfSamples = CMSampleBufferGetNumSamples(sample.sampleBuffer)
            decodeStartTime = ProcessInfo.processInfo.systemUptime
            host.decodeSample(sample.sampleBuffer, decodingFlags.rawValue, sample.flushId)
        }
    }

    // On the queue, when the decompression session settles a decodeSample(): its frames, or its error status.
    @_expose(Cxx)
    func decodeCompleted(_ sampleFlushId: Int32, _ succeeded: Bool, _ status: Int32, _ frames: NSArray?) {
        assertOnQueue()
        let decodingFlags = self.decodingFlags
        let numberOfSamples = decodingNumberOfSamples
        let startTime = decodeStartTime

        isDecodingSample = false

        if sampleFlushId != flushId || (!succeeded && status == noErr) {
            log(.Always, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded Decoder was flushed")
            decodeNextSampleIfNeeded()
            return
        }

        increment(totalVideoFramesValue, by: UInt32(truncatingIfNeeded: numberOfSamples))

        if !succeeded {
            // Invalidating a session while a sample is in flight is reported either as an
            // invalid session or as a decoder malfunction, depending on how far that sample
            // had got. Both mean the session is gone and a flush is what resumes decoding.
            if status == invalidSessionError || status == decoderMalfunctionError {
                log(.Always, "VideoMediaSampleRenderer::decodeNextSampleIfNeeded VTDecompressionSession got invalidated (\(status)), requesting flush")
                host.invalidateDecompressionSession()
                return
            }

            gotDecodingErrorValue.store(true, ordering: .sequentiallyConsistent)
            increment(corruptedVideoFramesValue)

            DispatchQueue.main.async { [self] in
                host.decodingErrorOccurred(status)
            }
            return
        }

        let decodedFrames: [CMSampleBuffer] = (frames as? [AnyObject] ?? []).map { $0 as! CMSampleBuffer }

        if host.willLog(.Performance) {
            let now = ProcessInfo.processInfo.systemUptime
            let observedFrameRate = host.frameRateMonitorUpdate()
            var format = "----"
            var presentationTime = RendererTime.invalid
            if let firstFrame = decodedFrames.first {
                if let formatDescription = CMSampleBufferGetFormatDescription(firstFrame) {
                    format = fourCCString(CMFormatDescriptionGetMediaSubType(formatDescription))
                }
                presentationTime = RendererTime(time: CMSampleBufferGetOutputPresentationTimeStamp(firstFrame))
            }
            let previous = timeSinceLastDecode
            timeSinceLastDecode = now
            let decodingRate = 1 / (now - previous)
            let decoderRate = 1 / (now - startTime)
            log(.Performance, "VideoMediaSampleRenderer pts:\(formatSeconds(presentationTime)) minimum upcoming:\(formatSeconds(lastMinimumUpcomingPresentationTime)) decoding rate:\(formatRate(decodingRate))Hz rolling:\(formatRate(observedFrameRate)) decoder rate:\(formatRate(decoderRate))Hz compressed queue:\(compressedSamplesCount) decoded queue:\(decodedSamplesCount) hw:\(host.isDecompressionSessionHardwareAccelerated() ? 1 : 0) format:\(format)")
        }

        if !decodingFlags.contains(.nonDisplaying) {
            for frame in decodedFrames {
                decodedFrameAvailable(DecodedSample(sampleBuffer: frame, presentationTime: presentationTimeOfDecodedFrame(frame)), sampleFlushId)
            }
        }

        decodeNextSampleIfNeeded()
    }

    private func shouldDecodeSample(_ sample: CompressedSample) -> Bool {
        if sample.info.isNonDisplaying {
            return true
        }
        let currentTime = currentTime()
        if currentTime.isInvalid {
            return true
        }
        if RendererTime(time: sample.info.presentationEndTime) >= currentTime {
            return true
        }
        return sample.info.isDependedOnByOthers
    }

    // MARK: Displaying (queue)

    private func decodedFrameAvailable(_ sample: DecodedSample, _ sampleFlushId: Int32) {
        assertOnQueue()

        if hasResourceOwnerValue.load(ordering: .sequentiallyConsistent) {
            host.assignResourceOwner(sample.sampleBuffer)
        }

        renderer?.enqueue(sample.sampleBuffer)

        if host.hasTimebase() {
            enqueueDecodedSample(sample)
            maybeReschedulePurge(sampleFlushId)
        } else {
            _ = maybeQueueFrameForDisplay(.invalid, sample, sampleFlushId)
        }
    }

    // Keeps the decoded queue in presentation order; a sample goes after those with the same time.
    private func enqueueDecodedSample(_ sample: DecodedSample) {
        var index = decodedSampleQueue.count
        while index > 0 && !(decodedSampleQueue[index - 1].presentationTime <= sample.presentationTime) {
            index -= 1
        }
        decodedSampleQueue.insert(sample, at: index)
    }

    private func nextDecodedSampleEndTime() -> RendererTime {
        if decodedSampleQueue.count <= 1 {
            return .positiveInfinite
        }
        return decodedSampleQueue[1].presentationTime
    }

    private func maybeQueueFrameForDisplay(_ currentTime: RendererTime, _ sample: DecodedSample, _ sampleFlushId: Int32) -> DecodedFrameResult {
        assertOnQueue()

        let presentationTime = sample.presentationTime

        if currentTime.isValid {
            // Always display the first video frame available if we aren't displaying any yet, regardless of its time as it's always either:
            // 1- The first frame of the video.
            // 2- The first visible frame after a seek.

            if let lastDisplayedSample {
                if presentationTime < lastDisplayedSample {
                    return .tooLate
                }
                if presentationTime == lastDisplayedSample {
                    return .alreadyDisplayed
                }
            }
            if !forceLateSampleToBeDisplayed && isDisplayingSample, let lastDisplayedTime, presentationTime < lastDisplayedTime {
                return .tooLate
            }

            if isDisplayingSample && presentationTime > currentTime {
                return .tooEarly
            }

            lastDisplayedTime = currentTime
            lastDisplayedSample = presentationTime
        }

        increment(presentedVideoFramesValue)
        isDisplayingSample = true
        forceLateSampleToBeDisplayed = false

        notifyHasAvailableVideoFrame(presentationTime, secondsSinceStartup(), sampleFlushId)

        return .displayed
    }

    private func notifyHasAvailableVideoFrame(_ presentationTime: RendererTime, _ displayTime: Double, _ sampleFlushId: Int32) {
        assertOnQueue()

        if !notifiedFirstFrameAvailable {
            log(.Debug, "VideoMediaSampleRenderer::notifyHasAvailableVideoFrame First Frame Available")
            DispatchQueue.main.async { [weak self] in
                guard let self, sampleFlushId == self.flushId else {
                    return
                }
                self.host.firstFrameAvailable(presentationTime.time, displayTime)
            }
            notifiedFirstFrameAvailable = true
        }
        if !notifyWhenHasAvailableVideoFrameValue.load(ordering: .sequentiallyConsistent) {
            return
        }
        log(.Debug, "VideoMediaSampleRenderer::notifyHasAvailableVideoFrame Has Available Video Frame")
        DispatchQueue.main.async { [weak self] in
            guard let self, sampleFlushId == self.flushId else {
                return
            }
            self.host.hasAvailableVideoFrame(presentationTime.time, displayTime)
        }
    }

    // MARK: Purging (queue)

    // On the queue, when the purge timer fires or the effective rate becomes non-zero.
    @_expose(Cxx)
    func purgeDecodedSampleQueue() {
        purgeDecodedSampleQueue(flushId)
    }

    private func purgeDecodedSampleQueue(_ sampleFlushId: Int32) {
        assertOnQueue()

        if !hasDecompressionSession.withLock({ $0 }) && !isReceivingDecodedSamplesValue.load(ordering: .sequentiallyConsistent) {
            return
        }

        if decodedSampleQueue.isEmpty {
            decodeNextSampleIfNeeded()
            return
        }

        var samplesPurged = false

        if host.hasTimebase() {
            let currentTime = RendererTime(time: host.timebaseTime())

            samplesPurged = purgeDecodedSampleQueueUntilTime(currentTime)
            if let nextSample = decodedSampleQueue.first {
                let result = maybeQueueFrameForDisplay(currentTime, nextSample, sampleFlushId)
                if host.willLog(.Debug) {
                    let resultLiteral = switch result {
                    case .tooEarly: "tooEarly"
                    case .tooLate: "tooLate"
                    case .alreadyDisplayed: "alreadyDisplayed"
                    case .displayed: "displayed"
                    }
                    log(.Debug, "VideoMediaSampleRenderer::purgeDecodedSampleQueue maybeQueueFrameForDisplay: currentTime:\(describe(currentTime)) start:\(describe(nextSample.presentationTime)) end:\(describe(nextDecodedSampleEndTime())) result:\(resultLiteral)")
                }
            }
        }
        if samplesPurged {
            maybeBecomeReadyForMoreMediaData()
        }
        if samplesPurged || decodedSampleQueue.count == 1 {
            decodeNextSampleIfNeeded()
        }
    }

    private func purgeDecodedSampleQueueUntilTime(_ currentTime: RendererTime) -> Bool {
        assertOnQueue()

        if decodedSampleQueue.isEmpty {
            return false
        }

        var nextPurgeTime = RendererTime.invalid
        var samplesPurged = false

        while let nextSample = decodedSampleQueue.first {
            let presentationTime = nextSample.presentationTime
            let presentationEndTime = nextDecodedSampleEndTime()

            if presentationEndTime >= currentTime {
                nextPurgeTime = presentationEndTime
                break
            }

            if let lastDisplayedSample, lastDisplayedSample < presentationTime {
                increment(droppedVideoFramesValue) // This frame was never displayed.
                log(.Debug, "VideoMediaSampleRenderer::purgeDecodedSampleQueueUntilTime currentTime:\(describe(currentTime)) start:\(describe(presentationTime)) end:\(describe(presentationEndTime)) result:tooLate scheduled:\(describe(nextScheduledPurge ?? .positiveInfinite)) (dropped:\(droppedVideoFramesValue.load(ordering: .sequentiallyConsistent)))")
            }

            decodedSampleQueue.removeFirst()
            samplesPurged = true
        }

        if nextPurgeTime.isInvalid {
            return samplesPurged
        }

        schedulePurgeAtTime(nextPurgeTime)

        return samplesPurged
    }

    private func schedulePurgeAtTime(_ nextPurgeTime: RendererTime) {
        if !host.hasTimebase() {
            return
        }

        host.setPurgeTimerFireTime(nextPurgeTime.time)

        if nextPurgeTime.isValid {
            assertOnQueue()
            nextScheduledPurge = nextPurgeTime
        }
    }

    private func maybeReschedulePurge(_ sampleFlushId: Int32) {
        assertOnQueue()

        if decodedSampleQueue.isEmpty {
            return
        }
        let presentationEndTime = nextDecodedSampleEndTime()
        if let nextScheduledPurge, nextScheduledPurge <= presentationEndTime {
            return
        }

        if (nextScheduledPurge?.isPositiveInfinite ?? false) || presentationEndTime.isPositiveInfinite {
            purgeDecodedSampleQueue(sampleFlushId)
            return
        }
        schedulePurgeAtTime(presentationEndTime)
    }

    // MARK: Flushing

    private func flushCompressedSampleQueue() {
        flushIdValue.wrappingAdd(1, ordering: .sequentiallyConsistent)
        compressedSamplesCountValue.store(0, ordering: .sequentiallyConsistent)
        gotDecodingErrorValue.store(false, ordering: .sequentiallyConsistent)
    }

    private func flushDecodedSampleQueue() {
        assertOnQueue()

        decodedSampleQueue.removeAll()
        nextScheduledPurge = nil
        lastDisplayedSample = nil
        lastDisplayedTime = nil
        isDisplayingSample = false
        lastMinimumUpcomingPresentationTime = .invalid
        decoderIdledAtHighWaterMark = false
        hasReachedHighWatermark = false
    }

    // flush() when the renderer manages decoded frames: after the C++ renderer flushed its renderer and cancelled the
    // purge timer, flushCompressedSamples(), then the decompression session's flush, then flushDecodedSamples().
    @_expose(Cxx)
    func flushCompressedSamples() {
        assertOnMain()
        flushCompressedSampleQueue()
    }

    @_expose(Cxx)
    func flushDecodedSamples() {
        assertOnMain()
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.flushDecodedSampleQueue()
            self.notifiedFirstFrameAvailable = false
            self.waitingForMoreMediaData = false
            self.maybeBecomeReadyForMoreMediaData()
        }
    }

    // shutdown(), after the C++ renderer cleared the timebase and flushed its renderer.
    @_expose(Cxx)
    func shutdown() {
        assertOnMain()
        flushCompressedSampleQueue()
        hasDecompressionSession.withLock { $0 = false }
    }

    // invalidateDecompressionSession(), after the C++ renderer invalidated the session: drops the samples already queued
    // for it.
    @_expose(Cxx)
    func decompressionSessionInvalidated() {
        hasDecompressionSession.withLock { $0 = false }
        flushIdValue.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }

    // MARK: Displayed frame (main thread)

    // The decoded sample to display at the current time, or nil; then lastCopiedPresentationTime() is its time.
    @_expose(Cxx)
    func copyDecodedSample() -> CMSampleBuffer? {
        assertOnMain()
        let (sample, presentationTime): (CMSampleBuffer?, RendererTime) = queue.sync {
            assertOnQueue()
            guard host.hasTimebase() else {
                return (nil, .invalid)
            }

            forceLateSampleToBeDisplayed = true
            purgeDecodedSampleQueue(flushId)

            guard let nextSample = decodedSampleQueue.first else {
                return (nil, .invalid)
            }
            let currentTime = RendererTime(time: host.timebaseTime())
            let presentationTime = nextSample.presentationTime

            if presentationTime > currentTime && (lastDisplayedSample.map { presentationTime > $0 } ?? true) {
                return (nil, .invalid)
            }

            return (nextSample.sampleBuffer, presentationTime)
        }
        copiedPresentationTime = sample != nil ? presentationTime : .invalid
        return sample
    }

    @_expose(Cxx)
    func lastCopiedPresentationTime() -> CMTime {
        copiedPresentationTime.time
    }
}

// AVSampleBufferVideoRenderer's queue management, which the SDK deprecates in favour of a render synchronizer's sample
// buffer receivers. The C++ renderer used these methods; the core calls them through this protocol, whose deprecated
// witnesses keep the deprecation warnings out of its callers.
private protocol SampleBufferRenderer: Sendable {
    var isReadyForMoreMediaData: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func stopRequestingMediaData()
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void)
    func expectMinimumUpcomingSampleBufferPresentationTime(_ time: CMTime)
    func weakReference() -> WeakVideoRendererHandle
}

private struct VideoRendererHandle: SampleBufferRenderer, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer

    @available(*, deprecated)
    var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }

    @available(*, deprecated)
    func enqueue(_ sampleBuffer: CMSampleBuffer) { renderer.enqueue(sampleBuffer) }

    @available(*, deprecated)
    func flush() { renderer.flush() }

    @available(*, deprecated)
    func stopRequestingMediaData() { renderer.stopRequestingMediaData() }

    @available(*, deprecated)
    func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        renderer.requestMediaDataWhenReady(on: queue, using: block)
    }

    func expectMinimumUpcomingSampleBufferPresentationTime(_ time: CMTime) {
#if !os(watchOS)
        renderer.__expectMinimumUpcomingSampleBufferPresentationTime(time)
#endif
    }

    func weakReference() -> WeakVideoRendererHandle {
        WeakVideoRendererHandle(renderer)
    }
}

// The AVSampleBufferVideoRenderer that the C++ renderer passes, if it is one. No generic code over the class: it would
// need the class object, which WebCore doesn't link.
private func rendererHandle(_ object: NSObject?) -> (any SampleBufferRenderer)? {
    if let renderer = AVFoundationClass.cast(object, to: AVFoundationClass.AVSampleBufferVideoRenderer) {
        return VideoRendererHandle(renderer: renderer)
    }
    return nil
}

// The renderer, weakly, for its own request callback.
private final class WeakVideoRendererHandle: @unchecked Sendable {
    weak var renderer: AVSampleBufferVideoRenderer?

    init(_ renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func stopRequestingMediaData() {
        guard let renderer else {
            return
        }
        let handle: any SampleBufferRenderer = VideoRendererHandle(renderer: renderer)
        handle.stopRequestingMediaData()
    }
}

private let vp8FourCC: FourCharCode = 0x7670_3038 // 'vp08'
private let vp9FourCC: FourCharCode = 0x7670_3039 // 'vp09'
private let invalidSessionError: Int32 = -12903 // kVTInvalidSessionErr
private let decoderMalfunctionError: Int32 = -12911 // kVTVideoDecoderMalfunctionErr

private func formatSeconds(_ time: RendererTime) -> Swift.String {
    let value = time.seconds
    guard value.isFinite else {
        return "\(value)"
    }
    let hundredths = (value * 100).rounded()
    let sign = hundredths < 0 ? "-" : ""
    let magnitude = Int64(abs(hundredths))
    let fraction = magnitude % 100
    return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
}

private func formatRate(_ rate: Double) -> Swift.String {
    guard rate.isFinite else {
        return "\(rate)"
    }
    let tenths = (rate * 10).rounded()
    let magnitude = Int64(abs(tenths))
    return "\(tenths < 0 ? "-" : "")\(magnitude / 10).\(magnitude % 10)"
}

private func fourCCString(_ code: FourCharCode) -> Swift.String {
    let bytes = [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16), UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
    return Swift.String(decoding: bytes, as: UTF8.self)
}
