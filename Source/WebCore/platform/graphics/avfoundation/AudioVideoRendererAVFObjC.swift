// Copyright (C) 2025 Apple Inc. All rights reserved.
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

// The audio and video renderer's core: the tracks, the synchronizer's rate and time, seeking, stalling at a time, the
// time observers, readiness for more samples, which renderer the video goes to, the audio renderers' state and the
// video sample renderer (VideoMediaSampleRenderer.swift). AudioVideoRendererAVFObjC.mm keeps the C++ renderer that
// implements AudioVideoRenderer: the clients' callbacks and promises, the shared timebase, the synchronizer, display
// layer and audio renderers it makes and configures, the layer manager, content keys, and the decompression session,
// which this reaches through AudioVideoRendererHost.
//
// WebCore soft-links AVFoundation and CoreMedia: their symbols come from the generated accessors. No AVFoundation class
// is used where its class object would be needed.
//
// Threads: the main thread's, apart from what says otherwise.

internal import AVFoundation
internal import CoreMedia
internal import Synchronization
import WebCore_Private.Core.AudioVideoRendererHost

// TrackInfoTrackType.
private enum TrackType: UInt8 {
    case unknown = 0
    case audio = 1
    case video = 2
    case text = 3
}

// PlatformMediaError; AudioVideoRendererAVFObjC.mm checks the values.
private enum PlatformMediaError: UInt8 {
    case decoderCreationError = 9
    case audioDecodingError = 13
    case videoDecodingError = 14
}

private enum SeekState {
    case seeking
    case waitingForAvailableFrame
    case completed

    var name: Swift.String {
        switch self {
        case .seeking: "Seeking"
        case .waitingForAvailableFrame: "WaitingForAvailableFame"
        case .completed: "SeekCompleted"
        }
    }
}

private enum DisplayLayerState {
    case addedToSynchronizer
    case pendingRemovalFromSynchronizer
    case removedFromSynchronizer
}

private enum AcceleratedVideoMode {
    case layer
    case videoRenderer
}

private struct AudioTrack {
    var hasAudibleSample = false
    var readyToRequestAudioData = true
    var requestPending = false
    var renderer: AudioRendererHandle?
}

private struct PublishState {
    var stallCap: RendererTime?
    var publishedTimeFloor = RendererTime.zero
}

// WebCore::VideoRendererPreference.
private let prefersDecompressionSession: UInt8 = 1 << 0
private let useDecompressionSessionForProtectedContent: UInt8 = 1 << 2

private func isNumeric(_ time: CMTime) -> Bool {
    time.flags.contains(timeValid) && time.flags.intersection(timeSpecial).isEmpty
}

private func utf8(_ string: Swift.String) -> ContiguousArray<UInt8> {
    ContiguousArray(string.utf8)
}

// What AudioVideoRendererAVFObjC.mm calls.
@_expose(Cxx)
final class AudioVideoRendererCore: @unchecked Sendable, VideoMediaSampleRendererClient, WebAVSampleBufferListenerClient {
    private let host: WebCore.AudioVideoRendererHost
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let configuration: WebCore.AudioVideoRendererConfiguration
    private var listener: WebAVSampleBufferListener?
    private let startupTime = ProcessInfo.processInfo.systemUptime

    // Any thread.
    private let publishState = Mutex<PublishState>(PublishState())
    // The video sample renderer, for the decompression session's and the purge timer's callbacks on its queue.
    private let videoRendererForQueue = Mutex<VideoMediaSampleRendererCore?>(nil)

    // Main.
    private var isShutdown = false
    private var trackTypes: [UInt64: TrackType] = [:]
    private var enabledVideoTrackId: UInt64?
    private var audioTracks: [UInt64: AudioTrack] = [:]
    private var videoRenderer: VideoMediaSampleRendererCore?
    private var lastVideoRendererIdentifier: UInt64 = 0
    private var hasDisplayLayer = false
    private var displayLayerState = DisplayLayerState.removedFromSynchronizer
    private var hasVideoRendererForTarget = false
    private var hasVideoTarget = false
    private var isPlaying = false
    private var rate: Double = 1
    private var lastSetSyncRate: Float = 0
    private var lastSeekTime = RendererTime.zero
    private var seekState = SeekState.completed
    private var seekPending = false
    private var isSynchronizerSeeking = false
    private var hasAvailableVideoFrame = false
    private var allRenderersHaveAvailableSamples = false
    private var videoRequestTrackId: UInt64?
    private var videoDataRequestInFlight = false
    private var readyToRequestVideoData = true
    private var hasEverSubmittedVideoSample = false
    private var preferences: UInt8 = 0
    private var hasProtectedVideoContent = false
    private var renderingCanBeAccelerated = false
    private var isRenderingCompressedVideo = false
    private var keyframeNeeded = true
    private var cachedSize: (width: Float, height: Float)?
    private var sizeChangeObservers: [AnyObject] = []
    private var hasSizeChangedCallback = false
    private var hasAvailableVideoFrameCallback = false
    private var hasResourceOwner = false
    private var timeJumpedObserver: AnyObject?
    private var currentTimeObserver: AnyObject?
    private var performTaskObserver: AnyObject?
    private var timeChangedObserver: AnyObject?
    private var startupGateObserver: AnyObject?
    private var videoFrameMetadataGatheringObserver: AnyObject?
    private var lastForwardedEffectiveRate: Double = 0
    private var registeredWithSharedTimer = false

    // The synchronizer is the C++ renderer's; it is borrowed.
    @_expose(Cxx)
    init(_ host: WebCore.AudioVideoRendererHost, _ synchronizer: borrowing NSObject?, _ configuration: WebCore.AudioVideoRendererConfiguration) {
        self.host = host
        guard let synchronizer = AVFoundationClass.cast(copy synchronizer, to: AVFoundationClass.AVSampleBufferRenderSynchronizer) else {
            preconditionFailure("AudioVideoRendererCore needs an AVSampleBufferRenderSynchronizer")
        }
        self.synchronizer = synchronizer
        self.configuration = configuration
        listener = WebAVSampleBufferListener(client: self)

        // addPeriodicTimeObserverForInterval: throws an exception if you pass a non-numeric CMTime, so just use
        // an arbitrarily large time value of once an hour:
        timeJumpedObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 3600, timescale: 1, flags: .valid, epoch: 0), queue: .main) { [weak self] time in
            guard let self else {
                return
            }
            let clampedTime = isNumeric(time) ? self.clampTimeToLastSeekTime(RendererTime(time: time)) : RendererTime.zero
            self.log(.Always, "AudioVideoRendererAVFObjC::timeJumped synchronizer fired: time clamped = \(clampedTime.logDescription), seeking = \(self.isSynchronizerSeeking)")
            self.isSynchronizerSeeking = false
            self.maybeCompleteSeek()
        } as AnyObject
    }

    // MARK: Logging

    private func log(_ level: WebCore.AudioVideoRendererLogLevel, _ message: @autoclosure () -> Swift.String) {
        guard host.willLog(level) else {
            return
        }
        let bytes = utf8(message())
        host.log(level, bytes.span)
    }

    private func assertOnMain() {
#if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
#endif
    }

    private func notifyError(_ error: PlatformMediaError) {
        host.notifyError(error.rawValue)
    }

    // MARK: Lifetime

    // As the C++ renderer's destructor did; the C++ renderer then lets the core go.
    @_expose(Cxx)
    func destroy() {
        assertOnMain()
        cancelStartupGateObserver()
        cancelSeekingPromiseIfNeeded()
        cancelTimeReachedAction()
        cancelTimeObserver()
        cancelPerformTaskAtTimeObserverIfNeeded()
        if let observer = timeJumpedObserver {
            synchronizer.removeTimeObserver(observer)
            timeJumpedObserver = nil
        }
        if let observer = videoFrameMetadataGatheringObserver {
            synchronizer.removeTimeObserver(observer)
            videoFrameMetadataGatheringObserver = nil
        }
        destroyVideoTrack()
        destroyAudioRenderers()
        listener?.invalidate()
        listener = nil
    }

    @_expose(Cxx)
    func shutdown() {
        assertOnMain()
        if isShutdown {
            return
        }
        isShutdown = true
        log(.Always, "AudioVideoRendererAVFObjC::shutdown")

        cancelSeekingPromiseIfNeeded()
        cancelTimeReachedAction()

        for (trackId, track) in audioTracks {
            guard let renderer = track.renderer else {
                continue
            }
            removeFromSynchronizerIfNeeded(.AudioRenderer, trackId)
            listener?.stopObservingAudioRenderer(renderer.object)
            renderer.queued.stopRequestingMediaData()
            host.destroyRenderingObject(.AudioRenderer, trackId)
        }
        audioTracks.removeAll()

        destroyVideoTrack()
    }

    @_expose(Cxx)
    func setPreferences(_ rawValue: UInt8) {
        preferences = rawValue
        videoRenderer?.setPreferences(rawValue)
    }

    @_expose(Cxx)
    func setHasProtectedVideoContent(_ protectedContent: Bool) {
        log(.Always, "AudioVideoRendererAVFObjC::setHasProtectedVideoContent protectedContent: \(protectedContent)")
        if hasProtectedVideoContent != protectedContent {
            hasProtectedVideoContent = protectedContent
            updateDisplayLayerIfNeeded(nil)
        }
    }

    // MARK: Tracks

    @_expose(Cxx)
    func addTrack(_ trackId: UInt64, _ type: UInt8) -> Bool {
        let trackType = TrackType(rawValue: type) ?? .unknown
        trackTypes[trackId] = trackType
        log(.Always, "AudioVideoRendererAVFObjC::addTrack \(trackDescription(trackId))")

        switch trackType {
        case .video:
            cancelVideoDataRequest()
            resetVideoRequest()
            videoRenderer?.flush()
            enabledVideoTrackId = trackId
            updateDisplayLayerIfNeeded(nil)
        case .audio:
            addAudioRenderer(trackId)
        default:
            return false
        }
        return true
    }

    @_expose(Cxx)
    func removeTrack(_ trackId: UInt64) {
        log(.Always, "AudioVideoRendererAVFObjC::removeTrack \(trackDescription(trackId))")
        guard let type = trackTypes[trackId] else {
            return
        }
        switch type {
        case .video:
            if isEnabledVideoTrack(trackId) {
                destroyVideoTrack()
            }
        case .audio:
            removeAudioRenderer(trackId)
        default:
            break
        }
        trackTypes.removeValue(forKey: trackId)
    }

    @_expose(Cxx)
    func trackType(_ trackId: UInt64) -> UInt8 {
        trackTypes[trackId]?.rawValue ?? 0xFF
    }

    @_expose(Cxx)
    func isEnabledVideoTrack(_ trackId: UInt64) -> Bool {
        enabledVideoTrackId == trackId
    }

    private var hasSelectedVideo: Bool { enabledVideoTrackId != nil }

    // After the C++ renderer checked the sample's type and keys.
    @_expose(Cxx)
    func enqueueSample(_ trackId: UInt64, _ sampleBuffer: CMSampleBuffer, _ info: WebCore.AudioVideoRendererSampleInfo) {
        guard let type = trackTypes[trackId] else {
            return
        }
        switch type {
        case .video:
            if hasSizeChangedCallback && info.hasPresentationSize {
                let size = (width: info.presentationWidth, height: info.presentationHeight)
                if cachedSize.map({ $0.width != size.width || $0.height != size.height }) ?? true {
                    log(.Debug, "AudioVideoRendererAVFObjC::enqueueSample size changed to: \(size.width)x\(size.height)")
                    let hadSize = cachedSize != nil
                    cachedSize = size
                    if !hadSize {
                        host.sizeChanged(info.presentationTime, size.width, size.height)
                    } else {
                        sizeWillChangeAtTime(RendererTime(time: info.presentationTime), size)
                    }
                }
            }

            if keyframeNeeded && !info.isSync {
                log(.Always, "AudioVideoRendererAVFObjC::enqueueSample Keyframe needed: but frame not keyframe")
                assertionFailure()
                return
            }
            keyframeNeeded = false
            if let videoRenderer, isEnabledVideoTrack(trackId) {
                videoRenderer.enqueueSample(sampleBuffer, info)
                if !hasEverSubmittedVideoSample {
                    hasEverSubmittedVideoSample = true
                    isRenderingCompressedVideo = !isUsingDecompressionSession && !isReceivingDecodedSamples
                }
            }
        case .audio:
            if let renderer = audioTracks[trackId]?.renderer {
                renderer.queued.enqueue(sampleBuffer)
                if !allRenderersHaveAvailableSamples && !info.isNonDisplaying {
                    setHasAvailableAudioSample(trackId, true)
                }
            }
        default:
            break
        }
    }

    @_expose(Cxx)
    func isReadyForMoreSamples(_ trackId: UInt64) -> Bool {
        guard let type = trackTypes[trackId] else {
            return false
        }
        switch type {
        case .video:
            return readyToRequestVideoData && isEnabledVideoTrack(trackId) && (videoRenderer?.isReadyForMoreMediaData() ?? false)
        case .audio:
            guard let track = audioTracks[trackId], let renderer = track.renderer else {
                return false
            }
            return track.readyToRequestAudioData && renderer.queued.isReadyForMoreMediaData
        default:
            return false
        }
    }

    // 0: ready now; 1: the C++ renderer hears mediaDataRequestSettled() later; 2: no such renderer.
    @_expose(Cxx)
    func requestMediaDataWhenReady(_ trackId: UInt64) -> UInt8 {
        guard let type = trackTypes[trackId] else {
            return 2
        }
        log(.Debug, "AudioVideoRendererAVFObjC::requestMediaDataWhenReady trackId: \(trackDescription(trackId)) isEnabledVideoTrackId: \(isEnabledVideoTrack(trackId))")

        switch type {
        case .video:
            guard videoRenderer != nil else {
                return 2
            }
            cancelVideoDataRequest()
            resetVideoRequest()
            if isReadyForMoreSamples(trackId) {
                return 0
            }
            videoRequestTrackId = trackId
            if readyToRequestVideoData {
                requestVideoDataWhenReady()
            }
            return 1
        case .audio:
            guard audioTracks[trackId]?.renderer != nil else {
                return 2
            }
            if audioTracks[trackId]?.requestPending == true {
                audioTracks[trackId]?.requestPending = false
                host.mediaDataRequestSettled(false, trackId, false)
            }
            if isReadyForMoreSamples(trackId) {
                return 0
            }
            audioTracks[trackId]?.requestPending = true
            if audioTracks[trackId]?.readyToRequestAudioData == true {
                requestAudioDataWhenReady(trackId)
            }
            return 1
        default:
            return 2
        }
    }

    private func requestVideoDataWhenReady() {
        guard let videoRenderer else {
            return
        }
        videoDataRequestInFlight = true
        videoRenderer.requestMediaDataWhenReady()
    }

    private func resetVideoRequest() {
        guard let trackId = videoRequestTrackId else {
            return
        }
        videoRequestTrackId = nil
        host.mediaDataRequestSettled(true, trackId, false)
    }

    private func cancelVideoDataRequest() {
        videoDataRequestInFlight = false
        videoRenderer?.stopRequestingMediaData()
    }

    private func clearReadyToRequestVideoData() {
        readyToRequestVideoData = false
        cancelVideoDataRequest()
    }

    private func requestAudioDataWhenReady(_ trackId: UInt64) {
        guard let renderer = audioTracks[trackId]?.renderer else {
            return
        }
        let weakRenderer = WeakQueuedSampleBufferRenderer(renderer)
        renderer.queued.requestMediaDataWhenReady(on: .main) { [weak self] in
            weakRenderer.stopRequestingMediaData()
            guard let self, let track = self.audioTracks[trackId], track.renderer != nil else {
                return
            }
            if !track.readyToRequestAudioData {
                self.log(.Debug, "AudioVideoRendererAVFObjC::requestAudioDataWhenReady Not ready to request audio data, deferring")
                return
            }
            if track.requestPending {
                self.audioTracks[trackId]?.requestPending = false
                self.host.mediaDataRequestSettled(false, trackId, true)
            }
        }
    }

    private func setReadyToRequestVideoData() {
        readyToRequestVideoData = true
        guard let requestTrackId = videoRequestTrackId, !videoDataRequestInFlight, let trackId = enabledVideoTrackId else {
            return
        }
        if isReadyForMoreSamples(trackId) {
            videoRequestTrackId = nil
            _ = requestTrackId
            host.mediaDataRequestSettled(true, trackId, true)
        } else {
            requestVideoDataWhenReady()
        }
    }

    private func setReadyToRequestAudioData(_ trackId: UInt64) {
        guard audioTracks[trackId] != nil else {
            preconditionFailure("No audio track \(trackId)")
        }
        audioTracks[trackId]?.readyToRequestAudioData = true
        guard audioTracks[trackId]?.requestPending == true else {
            return
        }
        if isReadyForMoreSamples(trackId) {
            audioTracks[trackId]?.requestPending = false
            host.mediaDataRequestSettled(false, trackId, true)
        } else {
            requestAudioDataWhenReady(trackId)
        }
    }

    @_expose(Cxx)
    func flush() {
        log(.Always, "AudioVideoRendererAVFObjC::flush")

        cancelSeekingPromiseIfNeeded()
        seekState = .completed
        isSynchronizerSeeking = false

        flushVideo()
        flushAudio()
    }

    @_expose(Cxx)
    func flushTrack(_ trackId: UInt64) {
        log(.Always, "AudioVideoRendererAVFObjC::flushTrack \(trackDescription(trackId))")
        guard let type = trackTypes[trackId] else {
            return
        }
        switch type {
        case .video:
            if isEnabledVideoTrack(trackId) {
                flushVideo()
            }
        case .audio:
            flushAudioTrack(trackId)
        default:
            break
        }
    }

    @_expose(Cxx)
    func applicationWillResignActive() {
        guard let videoRenderer, videoRenderer.isUsingDecompressionSession() else {
            return
        }
        if !paused() {
            log(.Always, "AudioVideoRendererAVFObjC::applicationWillResignActive Playing; not invalidating VideoMediaSampleRenderer Decompression Session")
            return
        }
        videoRenderer.invalidateDecompressionSession()
        log(.Always, "AudioVideoRendererAVFObjC::applicationWillResignActive Paused; invalidating VideoMediaSampleRenderer Decompression Session")
    }

    // MARK: Synchronizer

    @_expose(Cxx)
    func play(_ hasHostTime: Bool, _ hostTime: UInt64) {
        log(.Always, "AudioVideoRendererAVFObjC::play m_rate: \(rate) seeking: \(seeking())")
        isPlaying = true
        if !seeking() {
            setSynchronizerRate(Float(rate), hasHostTime ? hostTime : nil)
        }
    }

    @_expose(Cxx)
    func pause(_ hasHostTime: Bool, _ hostTime: UInt64) {
        log(.Always, "AudioVideoRendererAVFObjC::pause m_rate: \(rate)")
        isPlaying = false
        // Capture current time to prevent time going backwards after resume.
        // The AVSampleBufferRenderSynchronizer can briefly report earlier times
        // during playback resumption due to timing jitter.
        let pauseTime = RendererTime(time: CMTimebaseGetTime(synchronizer.timebase))
        if pauseTime.isFinite && pauseTime > lastSeekTime {
            setTimeFloor(pauseTime)
        }
        setSynchronizerRate(0, hasHostTime ? hostTime : nil)
    }

    @_expose(Cxx)
    func paused() -> Bool {
        !isPlaying
    }

    @_expose(Cxx)
    func timeIsProgressing() -> Bool {
        isPlaying && lastSetSyncRate != 0
    }

    @_expose(Cxx)
    func currentTime() -> CMTime {
        assertOnMain()
        if seeking() {
            return lastSeekTime.time
        }
        let synchronizerTime = clampTimeToLastSeekTime(RendererTime(time: CMTimebaseGetTime(synchronizer.timebase)))
        if synchronizerTime < .zero {
            return RendererTime.zero.time
        }

        // Clamp to the stall cap. The synchronizer can overshoot the registered boundary during the
        // observer's dispatch latency; without the clamp the overshoot leaks into snapshots and the
        // observer's eventual setRate:0 time:cap visibly walks ct backward.
        return publishState.withLock { state in
            if let stallCap = state.stallCap, synchronizerTime > stallCap {
                return stallCap.time
            }
            return synchronizerTime.time
        }
    }

    // Whether the rate changed.
    @_expose(Cxx)
    func setRate(_ newRate: Double) -> Bool {
        log(.Always, "AudioVideoRendererAVFObjC::setRate m_rate: \(newRate)")
        if rate == newRate {
            return false
        }
        rate = newRate
        if shouldBePlaying() {
            synchronizer.rate = Float(rate)
            lastSetSyncRate = Float(rate)
        }
        return true
    }

    @_expose(Cxx)
    func effectiveRate() -> Double {
        if startupGateObserver != nil {
            return 0
        }
        // currentTime() floors the reported time to m_lastSeekTime while the timebase is in pre-roll
        // (negative at startup, below the seek target right after a seek). While floored the published
        // time isn't advancing, so report 0 to keep the snapshot self-consistent — otherwise the reader
        // would extrapolate ahead of a frozen currentTime and the next honest snapshot would land below
        // its high-water-mark.
        let rawTime = RendererTime(time: CMTimebaseGetTime(synchronizer.timebase))
        if clampTimeToLastSeekTime(rawTime) != rawTime || rawTime < .zero {
            return 0
        }
        return CMTimebaseGetEffectiveRate(synchronizer.timebase)
    }

    private func updateSharedTimebase() {
        assertOnMain()
        if !configuration.hasSharedTimebase {
            return
        }
        publishSnapshot(RendererTime(time: currentTime()), effectiveRate())
    }

    // Any thread.
    private func publishSnapshot(_ time: RendererTime, _ playbackRate: Double) {
        if !configuration.hasSharedTimebase {
            return
        }
        publishState.withLock { state in
            var currentTime = time
            var rate = playbackRate
            // Floor: never publish below the high-water-mark. Catches AVF retroactive anchor changes
            // that lower CMTimebaseGetTime after rate changes, and is reset downward at seek sites.
            if state.publishedTimeFloor.isFinite && currentTime < state.publishedTimeFloor {
                currentTime = state.publishedTimeFloor
            }
            // Ceiling: stall cap from the boundary observer, masking the synchronizer's overshoot
            // during dispatch latency until the observer parks the timebase.
            if let stallCap = state.stallCap, currentTime > stallCap {
                currentTime = stallCap
                rate = 0
            }
            state.publishedTimeFloor = currentTime
            host.storeSharedTimebaseSnapshot(currentTime.time, rate)
        }
    }

    // On the shared timer's queue.
    @_expose(Cxx)
    func publishFromSharedTimer() {
        let timebase = synchronizer.timebase
        let rawTime = RendererTime.maximum(.zero, RendererTime(time: CMTimebaseGetTime(timebase)))
        publishSnapshot(rawTime, CMTimebaseGetEffectiveRate(timebase))
    }

    @_expose(Cxx)
    func stall() {
        log(.Always, "AudioVideoRendererAVFObjC::stall playing: \(isPlaying) rate: \(rate)")
        setSynchronizerRate(0, nil)
    }

    // Whether the boundary is already behind, and the renderer stalled; otherwise the C++ renderer hears timeReached().
    @_expose(Cxx)
    func notifyTimeReachedAndStall(_ boundary: CMTime, _ roundedBoundary: CMTime) -> Bool {
        let timeBoundary = RendererTime(time: boundary)
        let now = RendererTime(time: currentTime())
        if timeBoundary <= now {
            log(.Always, "AudioVideoRendererAVFObjC::notifyTimeReachedAndStall boundary \(timeBoundary.logDescription) is behind currentTime \(now.logDescription); stalling and resolving immediately")
            stall()
            return true
        }

        // Register the observer at a 1ms-aligned tick at-or-before the boundary so it fires reliably;
        // sample-unit values land between ticks and the observer never fires. The synchronizer is
        // still parked at, and the producer resolves with, the original boundary.
        publishState.withLock { $0.stallCap = timeBoundary }
        log(.Debug, "AudioVideoRendererAVFObjC::notifyTimeReachedAndStall \(timeBoundary.logDescription)")

        currentTimeObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: roundedBoundary)], queue: .main) { [weak self] in
            guard let self else {
                return
            }
            self.log(.Always, "AudioVideoRendererAVFObjC::notifyTimeReachedAndStall boundary time observer called, now: \(RendererTime(time: self.currentTime()).logDescription)")

            // Experimentation shows that between the time the boundary time observer is called, the time have progressed by a few milliseconds. Re-adjust time. This seek doesn't require re-enqueuing/flushing.
            self.synchronizer.setRate(0, time: boundary)
            self.lastSetSyncRate = 0

            self.updateSharedTimebase()
            self.host.timeReached(boundary)
        } as AnyObject
        return false
    }

    @_expose(Cxx)
    func cancelTimeReachedAction() {
        publishState.withLock { $0.stallCap = nil }
        if let observer = currentTimeObserver {
            currentTimeObserver = nil
            synchronizer.removeTimeObserver(observer)
        }
    }

    // Then the C++ renderer hears performTask() and runs its task.
    @_expose(Cxx)
    func performTaskAtTime(_ time: CMTime) {
        cancelPerformTaskAtTimeObserverIfNeeded()
        log(.Debug, "AudioVideoRendererAVFObjC::performTaskAtTime \(RendererTime(time: time).logDescription)")
        performTaskObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
            guard let self else {
                return
            }
            let now = self.currentTime()
            self.log(.Always, "AudioVideoRendererAVFObjC::performTaskAtTime boundary time observer called, now: \(RendererTime(time: now).logDescription)")
            self.updateSharedTimebase()
            self.host.performTask(now)
            self.cancelPerformTaskAtTimeObserverIfNeeded()
        } as AnyObject
    }

    private func cancelPerformTaskAtTimeObserverIfNeeded() {
        if let observer = performTaskObserver {
            performTaskObserver = nil
            synchronizer.removeTimeObserver(observer)
        }
    }

    @_expose(Cxx)
    func setTimeObserver(_ interval: CMTime, _ hasCallback: Bool) {
        cancelTimeObserver()
        if !hasCallback {
            return
        }
        timeChangedObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else {
                return
            }
            let clampedTime = isNumeric(time) ? self.clampTimeToLastSeekTime(RendererTime(time: time)) : RendererTime.zero
            self.updateSharedTimebase()
            self.host.timeObserverFired(clampedTime.time)
        } as AnyObject
    }

    @_expose(Cxx)
    func cancelTimeObserver() {
        if let observer = timeChangedObserver {
            timeChangedObserver = nil
            synchronizer.removeTimeObserver(observer)
        }
    }

    // Whether the seek completed at once; isFarFromSynchronizerTime is whether the synchronizer's time is more than
    // 1ms away from the seek time.
    @_expose(Cxx)
    func prepareToSeek(_ seekTime: CMTime, _ isFarFromSynchronizerTime: Bool) -> Bool {
        log(.Always, "AudioVideoRendererAVFObjC::prepareToSeek state: \(seekState.name)")

        cancelSeekingPromiseIfNeeded()
        seekState = .seeking

        let isSynchronizerSeeking = self.isSynchronizerSeeking || isFarFromSynchronizerTime

        if !isSynchronizerSeeking && allRenderersHaveAvailableSamples {
            // In cases where the destination seek time matches too closely the synchronizer's existing time
            // no time jumped notification will be issued. In this case, just notify the MediaPlayer that
            // the seek completed successfully.
            setTimeFloor(RendererTime(time: seekTime))
            seekState = .completed

            let shouldBePlaying = self.shouldBePlaying()
            log(.Always, "AudioVideoRendererAVFObjC::prepareToSeek Synchroniser doesn't require seeking seeking: \(RendererTime(time: seekTime).logDescription), shouldBePlaying: \(shouldBePlaying)")

            if shouldBePlaying {
                setSynchronizerRate(Float(rate), nil)
            } else {
                updateSharedTimebase()
            }
            return true
        }

        setHasAvailableVideoFrame(false)
        clearReadyToRequestVideoData()
        for trackId in audioTracks.keys {
            audioTracks[trackId]?.hasAudibleSample = false
            audioTracks[trackId]?.readyToRequestAudioData = false
        }
        host.removeBlockedSamples(.All, 0)

        setTimeFloor(RendererTime(time: seekTime))
        self.isSynchronizerSeeking = isSynchronizerSeeking
        synchronizer.setRate(0, time: seekTime)
        lastSetSyncRate = 0
        updateSharedTimebase()
        return false
    }

    // Whether the renderer is seeking; then the C++ renderer hears seekSettled().
    @_expose(Cxx)
    func finishSeek(_ seekTime: CMTime) -> Bool {
        log(.Always, "AudioVideoRendererAVFObjC::finishSeek \(RendererTime(time: seekTime).logDescription) state: \(seekState.name) m_isSynchronizerSeeking: \(isSynchronizerSeeking) hasAvailableVideoFrame: \(videoRenderer != nil && allRenderersHaveAvailableSamples)")
        if seekState != .seeking {
            return false
        }
        seekPending = true
        maybeCompleteSeek()
        return true
    }

    // On the thread that the effective rate listener calls.
    @_expose(Cxx)
    func effectiveRateChanged(_ rate: Double) {
        // On rate->0, publish synchronously on the listener thread before the main-thread hop.
        // The main-thread updateSharedTimebase that handleEffectiveRateChanged would do is too
        // late: the reader keeps extrapolating off the prior (rate=1) snapshot in the interim.
        // Rate->non-zero is left to the main-thread path, which applies clampTimeToLastSeekTime
        // and the startup gate.
        if rate == 0 && configuration.hasSharedTimebase {
            let time = RendererTime.maximum(.zero, RendererTime(time: CMTimebaseGetTime(synchronizer.timebase)))
            publishSnapshot(time, 0)
        }
        DispatchQueue.main.async { [weak self] in
            self?.handleEffectiveRateChanged(rate)
        }
    }

    private func handleEffectiveRateChanged(_ rate: Double) {
        assertOnMain()

        // -> 0, or non-zero -> non-zero (already moving): forward immediately.
        // The 0 -> non-zero edge is the only one that lies, so it's gated below.
        if rate == 0 || lastForwardedEffectiveRate != 0 {
            cancelStartupGateObserver()
            lastForwardedEffectiveRate = rate
            updateSharedTimebase()
            host.effectiveRateChanged(rate)
            return
        }

        // 0 -> non-zero with a gate already pending: leave it.
        if startupGateObserver != nil {
            return
        }

        // 0 -> non-zero. Hold the rate change until the timebase is actually live — i.e. until the
        // synchronizer time is valid (>= 0 and not below the last seek target), matching effectiveRate()'s
        // guard. Releasing merely because the timebase value changed forwards while the time is still in
        // pre-roll, publishing a rate-0 (frozen) snapshot that nothing subsequently advances past.
        startupGateObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 100, flags: .valid, epoch: 0), queue: .main) { [weak self] _ in
            guard let self, self.startupGateObserver != nil else {
                return
            }
            let now = RendererTime(time: CMTimebaseGetTime(self.synchronizer.timebase))
            if now >= .zero && self.clampTimeToLastSeekTime(now) == now {
                self.releaseStartupGateAndForwardRate()
            }
        } as AnyObject
    }

    private func releaseStartupGateAndForwardRate() {
        assertOnMain()
        cancelStartupGateObserver()
        let liveRate = CMTimebaseGetEffectiveRate(synchronizer.timebase)
        lastForwardedEffectiveRate = liveRate
        // The gate just lifted: effectiveRate() now returns the live rate; publish before notifying.
        updateSharedTimebase()
        host.effectiveRateChanged(liveRate)
    }

    private func cancelStartupGateObserver() {
        if let observer = startupGateObserver {
            startupGateObserver = nil
            synchronizer.removeTimeObserver(observer)
        }
    }

    @_expose(Cxx)
    func seeking() -> Bool {
        seekState != .completed
    }

    private func clampTimeToLastSeekTime(_ time: RendererTime) -> RendererTime {
        assertOnMain()
        if lastSeekTime.isFinite && time < lastSeekTime {
            return lastSeekTime
        }
        return time
    }

    private func setTimeFloor(_ time: RendererTime) {
        assertOnMain()
        lastSeekTime = time
        publishState.withLock { $0.publishedTimeFloor = time }
    }

    private func maybeCompleteSeek() {
        log(.Always, "AudioVideoRendererAVFObjC::maybeCompleteSeek state: \(seekState.name)")

        if seekState == .completed || !seekPending {
            return
        }

        if videoRenderer != nil && !allRenderersHaveAvailableSamples {
            log(.Always, "AudioVideoRendererAVFObjC::maybeCompleteSeek Waiting for all frames")
            seekState = .waitingForAvailableFrame
            return
        }
        if isSynchronizerSeeking {
            log(.Always, "AudioVideoRendererAVFObjC::maybeCompleteSeek Waiting on synchronizer to complete seeking")
            return
        }
        seekState = .completed
        if shouldBePlaying() {
            setSynchronizerRate(Float(rate), nil)
        } else {
            log(.Always, "AudioVideoRendererAVFObjC::maybeCompleteSeek Not resuming playback, shouldBePlaying:false")
            updateSharedTimebase()
        }

        if seekPending {
            seekPending = false
            host.seekSettled(true)
        }
        log(.Always, "AudioVideoRendererAVFObjC::maybeCompleteSeek seek completed")
    }

    private func cancelSeekingPromiseIfNeeded() {
        if seekPending {
            seekPending = false
            host.seekSettled(false)
        }
    }

    private func shouldBePlaying() -> Bool {
        isPlaying && !seeking() && allRenderersHaveAvailableSamples
    }

    private func setSynchronizerRate(_ newRate: Float, _ hostTime: UInt64?) {
        if let hostTime {
            let cmHostTime = CMClockMakeHostTimeFromSystemUnits(hostTime)
            log(.Always, "AudioVideoRendererAVFObjC::setSynchronizerRate setting rate to: \(rate) at host time: \(CMTimeGetSeconds(cmHostTime))")
            synchronizer.setRate(newRate, time: RendererTime.invalid.time, atHostTime: cmHostTime)
        } else {
            synchronizer.rate = newRate
        }
        lastSetSyncRate = newRate

        // If we are pausing the synchronizer, update the last image to ensure we have something
        // to display if and when the decoders are purged while in the background. And vice-versa,
        // purge our retained images and pixel buffers when playing the synchronizer, to release that
        // retained memory.
        if newRate == 0 {
            host.updateLastPixelBuffer()
        } else {
            host.purgeLastPixelBuffer()
        }

        // Rate (and possibly time) just changed; publish so the reader extrapolates from a fresh anchor.
        updateSharedTimebase()

        if !configuration.hasSharedTimebase {
            return
        }
        if newRate != 0 && !registeredWithSharedTimer {
            registeredWithSharedTimer = true
            host.setSharedTimerActive(true)
        } else if newRate == 0 && registeredWithSharedTimer {
            registeredWithSharedTimer = false
            host.setSharedTimerActive(false)
        }
    }

    // MARK: Availability

    private func setHasAvailableAudioSample(_ trackId: UInt64, _ flag: Bool) {
        if flag && allRenderersHaveAvailableSamples {
            return
        }
        guard let track = audioTracks[trackId], track.hasAudibleSample != flag else {
            return
        }
        log(.Always, "AudioVideoRendererAVFObjC::setHasAvailableAudioSample \(flag)")
        audioTracks[trackId]?.hasAudibleSample = flag
        updateAllRenderersHaveAvailableSamples()
    }

    private func updateAllRenderersHaveAvailableSamples() {
        var allHaveAvailableSamples = !(enabledVideoTrackId != nil && !hasAvailableVideoFrame)
        if allHaveAvailableSamples {
            for track in audioTracks.values where !track.hasAudibleSample {
                allHaveAvailableSamples = false
                break
            }
        }

        if allRenderersHaveAvailableSamples == allHaveAvailableSamples {
            return
        }

        log(.Debug, "AudioVideoRendererAVFObjC::updateAllRenderersHaveAvailableSamples \(allHaveAvailableSamples)")
        allRenderersHaveAvailableSamples = allHaveAvailableSamples

        if allHaveAvailableSamples {
            maybeCompleteSeek()
        }
        if shouldBePlaying() && lastSetSyncRate != Float(rate) {
            synchronizer.rate = Float(rate)
            lastSetSyncRate = Float(rate)
        } else if !shouldBePlaying() && lastSetSyncRate != 0 {
            stall()
        }
    }

    private func setHasAvailableVideoFrame(_ flag: Bool) {
        if hasAvailableVideoFrame == flag {
            return
        }
        hasAvailableVideoFrame = flag
        if flag {
            host.firstFrameAvailable()
            host.setNeedsPlaceholderImage(false)
        }
        updateAllRenderersHaveAvailableSamples()
    }

    // MARK: Audio renderers

    private func addAudioRenderer(_ trackId: UInt64) {
        if audioTracks[trackId] != nil {
            return
        }
        audioTracks[trackId] = AudioTrack()
        updateAllRenderersHaveAvailableSamples()

        guard host.createRenderingObject(.AudioRenderer, trackId), let renderer = AVFoundationClass.cast(host.renderingObject(.AudioRenderer, trackId), to: AVFoundationClass.AVSampleBufferAudioRenderer) else {
            return
        }
        audioTracks[trackId]?.renderer = AudioRendererHandle(renderer: renderer)
        listener?.beginObservingAudioRenderer(renderer)
    }

    private func removeAudioRenderer(_ trackId: UInt64) {
        guard let renderer = audioTracks[trackId]?.renderer else {
            return
        }
        destroyAudioRenderer(trackId, renderer)
        audioTracks.removeValue(forKey: trackId)
        updateAllRenderersHaveAvailableSamples()
    }

    private func destroyAudioRenderer(_ trackId: UInt64, _ renderer: AudioRendererHandle) {
        removeFromSynchronizerIfNeeded(.AudioRenderer, trackId)
        listener?.stopObservingAudioRenderer(renderer.object)
        renderer.queued.flush()
        renderer.queued.stopRequestingMediaData()
        host.destroyRenderingObject(.AudioRenderer, trackId)
    }

    private func destroyAudioRenderers() {
        for (trackId, track) in audioTracks {
            if let renderer = track.renderer {
                destroyAudioRenderer(trackId, renderer)
                audioTracks[trackId]?.renderer = nil
            }
        }
    }

    private func flushAudio() {
        for trackId in audioTracks.keys {
            audioTracks[trackId]?.hasAudibleSample = false
            setReadyToRequestAudioData(trackId)
        }
        updateAllRenderersHaveAvailableSamples()

        for track in audioTracks.values {
            track.renderer?.queued.flush()
        }
        host.removeBlockedSamples(.Audio, 0)
    }

    private func flushAudioTrack(_ trackId: UInt64) {
        log(.Always, "AudioVideoRendererAVFObjC::flushAudioTrack")
        guard let renderer = audioTracks[trackId]?.renderer else {
            return
        }
        setReadyToRequestAudioData(trackId)
        renderer.queued.flush()
        host.removeBlockedSamples(.Track, trackId)
        setHasAvailableAudioSample(trackId, false)
    }

    private func removeFromSynchronizerIfNeeded(_ object: WebCore.AudioVideoRendererObject, _ trackId: UInt64) {
        let isDisplayLayer = object == .DisplayLayer
        if isDisplayLayer && displayLayerState == .removedFromSynchronizer {
            return
        }
        host.removeFromSynchronizer(object, trackId)
        if isDisplayLayer {
            displayLayerState = .removedFromSynchronizer
        }
    }

    // MARK: Video renderer

    @_expose(Cxx)
    func renderingCanBeAcceleratedChanged(_ isAccelerated: Bool) {
        log(.Always, "AudioVideoRendererAVFObjC::renderingCanBeAcceleratedChanged \(isAccelerated)")
        renderingCanBeAccelerated = isAccelerated
        updateDisplayLayerIfNeeded(nil)
    }

    // For contentBoxRectChanged() and setVideoLayerSize().
    @_expose(Cxx)
    func videoSizeChanged(_ isEmpty: Bool) {
        if layerOrVideoRendererObject() == nil && !isEmpty {
            updateDisplayLayerIfNeeded(nil)
        }
    }

    @_expose(Cxx)
    func setHasAvailableVideoFrameCallback(_ hasCallback: Bool) {
        hasAvailableVideoFrameCallback = hasCallback
        configureHasAvailableVideoFrameCallbackIfNeeded()
    }

    @_expose(Cxx)
    func setHasSizeChangedCallback(_ hasCallback: Bool) {
        hasSizeChangedCallback = hasCallback
    }

    @_expose(Cxx)
    func setHasResourceOwner(_ hasOwner: Bool) {
        hasResourceOwner = hasOwner
    }

    @_expose(Cxx)
    func expectMinimumUpcomingPresentationTime(_ presentationTime: CMTime) {
        if enabledVideoTrackId == nil {
            return
        }
        videoRenderer?.expectMinimumUpcomingSampleBufferPresentationTime(presentationTime)
    }

    // Then the C++ renderer hears videoTargetSettled().
    @_expose(Cxx)
    func setHasVideoTarget(_ hasTarget: Bool) {
        hasVideoTarget = hasTarget
        updateDisplayLayerIfNeeded { [weak self] succeeded in
            self?.host.videoTargetSettled(succeeded)
        }
    }

    @_expose(Cxx)
    func copyDecodedSample() -> CMSampleBuffer? {
        videoRenderer?.copyDecodedSample()
    }

    @_expose(Cxx)
    func lastCopiedPresentationTime() -> CMTime {
        videoRenderer?.lastCopiedPresentationTime() ?? RendererTime.invalid.time
    }

    @_expose(Cxx)
    func videoMetrics() -> WebCore.AudioVideoRendererVideoMetrics {
        guard let videoRenderer else {
            return WebCore.AudioVideoRendererVideoMetrics(totalVideoFrames: 0, droppedVideoFrames: 0, corruptedVideoFrames: 0, presentedVideoFrames: 0, droppedVideoFramesOffset: 0, totalFrameDelay: 0, rendererObject: 0, hasVideoRenderer: false, hasRenderer: false, managesDecodedFrames: false, usingDecompressionSession: false, decompressionSessionBlocked: false)
        }
        return videoRenderer.metrics()
    }

    @_expose(Cxx)
    func totalDisplayedFrames() -> UInt32 {
        videoRenderer?.totalDisplayedFrames() ?? 0
    }

    // On the video renderer's queue, when the decompression session settles a decodeSample().
    @_expose(Cxx)
    func decodeCompleted(_ rendererIdentifier: UInt64, _ flushId: Int32, _ succeeded: Bool, _ status: Int32, _ frames: NSArray?) {
        guard let videoRenderer = videoRendererForQueue.withLock({ $0 }), videoRenderer.identifier == rendererIdentifier else {
            return
        }
        videoRenderer.decodeCompleted(flushId, succeeded, status, frames)
    }

    // On the video renderer's queue, when its purge timer fires or the effective rate becomes non-zero.
    @_expose(Cxx)
    func purgeDecodedSampleQueue(_ rendererIdentifier: UInt64) {
        guard let videoRenderer = videoRendererForQueue.withLock({ $0 }), videoRenderer.identifier == rendererIdentifier else {
            return
        }
        videoRenderer.purgeDecodedSampleQueue()
    }

    private var isUsingDecompressionSession: Bool { videoRenderer?.isUsingDecompressionSession() ?? false }
    private var isReceivingDecodedSamples: Bool { videoRenderer?.isReceivingDecodedSamples() ?? false }

    private var canUseDecompressionSession: Bool {
        if preferences & prefersDecompressionSession == 0 {
            return false
        }
        if preferences & useDecompressionSessionForProtectedContent != 0 {
            return true
        }
        return !hasProtectedVideoContent
    }

    private var willUseDecompressionSessionIfNeeded: Bool {
        if !canUseDecompressionSession {
            return false
        }
        return preferences & prefersDecompressionSession != 0 || hasAvailableVideoFrameCallback
    }

    private var acceleratedVideoMode: AcceleratedVideoMode { hasVideoTarget ? .videoRenderer : .layer }

    private func layerOrVideoRendererObject() -> WebCore.AudioVideoRendererObject? {
        switch acceleratedVideoMode {
        case .layer:
            return hasDisplayLayer ? .DisplayLayer : nil
        case .videoRenderer:
            return hasVideoRendererForTarget ? .VideoRendererForTarget : nil
        }
    }

    private func mainRenderer(_ object: WebCore.AudioVideoRendererObject?) -> VideoMediaSampleMainRenderer? {
        guard let object, let renderingObject = host.renderingObject(object, 0), let renderer = queuedSampleBufferRenderer(renderingObject) else {
            return nil
        }
        return VideoMediaSampleMainRenderer(kind: object, renderer: renderer, videoRenderer: videoRendererHandle(renderingObject))
    }

    private func updateDisplayLayerIfNeeded(_ completion: ((Bool) -> Void)?) {
        if enabledVideoTrackId == nil {
            completion?(true)
            return
        }

        if shouldEnsureLayerOrVideoRenderer {
            ensureLayerOrVideoRenderer(completion)
            return
        }

        // Using renderless video renderer.
        setVideoRenderer(nil, completion)
    }

    private var shouldEnsureLayerOrVideoRenderer: Bool {
        if !canUseDecompressionSession {
            return true
        }
        return renderingCanBeAccelerated
    }

    private func ensureLayerOrVideoRenderer(_ completion: ((Bool) -> Void)?) {
        switch acceleratedVideoMode {
        case .layer:
            ensureLayer()
        case .videoRenderer:
            ensureVideoRenderer()
        }

        guard let object = layerOrVideoRendererObject(), let renderingObject = host.renderingObject(object, 0) else {
            notifyError(.decoderCreationError)
            completion?(false)
            return
        }

        let needsRenderingModeChanged = videoRenderer.map { $0.mainRendererObject !== renderingObject } ?? true

        log(.Always, "AudioVideoRendererAVFObjC::ensureLayerOrVideoRenderer \(acceleratedVideoMode == .layer ? "Layer" : "VideoRenderer"), renderer=true")

        setVideoRenderer(object, completion)

        if needsRenderingModeChanged {
            host.renderingModeChanged()
        }
    }

    private func ensureLayer() {
        if hasDisplayLayer {
            if displayLayerState == .addedToSynchronizer {
                return
            }
            configureLayerOrVideoRenderer(.DisplayLayer)
            return
        }

        guard host.createRenderingObject(.DisplayLayer, 0) else {
            return
        }
        hasDisplayLayer = true
        configureLayerOrVideoRenderer(.DisplayLayer)
    }

    private func destroyLayer() {
        if !hasDisplayLayer {
            return
        }

        log(.Always, "AudioVideoRendererAVFObjC::destroyLayer")

        removeFromSynchronizerIfNeeded(.DisplayLayer, 0)
        host.destroyRenderingObject(.DisplayLayer, 0)
        hasDisplayLayer = false
    }

    private func ensureVideoRenderer() {
        host.destroyExpiringVideoRenderers()

        if hasVideoRendererForTarget {
            return
        }

        log(.Always, "AudioVideoRendererAVFObjC::ensureVideoRenderer")

        guard host.createRenderingObject(.VideoRendererForTarget, 0) else {
            return
        }
        hasVideoRendererForTarget = true
        configureLayerOrVideoRenderer(.VideoRendererForTarget)
    }

    private func destroyVideoRenderer() {
        if !hasVideoRendererForTarget {
            return
        }

        log(.Always, "AudioVideoRendererAVFObjC::destroyVideoRenderer")

        removeFromSynchronizerIfNeeded(.VideoRendererForTarget, 0)
        host.destroyRenderingObject(.VideoRendererForTarget, 0)
        hasVideoRendererForTarget = false
    }

    private func setVideoRenderer(_ object: WebCore.AudioVideoRendererObject?, _ completion: ((Bool) -> Void)?) {
        log(.Always, "AudioVideoRendererAVFObjC::setVideoRenderer !!renderer = \(object != nil)")

        if videoRenderer != nil {
            stageVideoRenderer(object, completion)
            return
        }

        if object == nil {
            destroyLayer()
            destroyVideoRenderer()
        }

        lastVideoRendererIdentifier += 1
        let newVideoRenderer = VideoMediaSampleRendererCore(host: host, configuration: configuration, identifier: lastVideoRendererIdentifier, client: self, mainRenderer: mainRenderer(object))
        videoRenderer = newVideoRenderer
        videoRendererForQueue.withLock { $0 = newVideoRenderer }

        newVideoRenderer.setPreferences(preferences)
        host.setVideoRendererTimebase(true, lastVideoRendererIdentifier)
        configureHasAvailableVideoFrameCallbackIfNeeded()
        newVideoRenderer.setHasResourceOwner(hasResourceOwner)

        completion?(true)
    }

    private func configureHasAvailableVideoFrameCallbackIfNeeded() {
        if let observer = videoFrameMetadataGatheringObserver {
            videoFrameMetadataGatheringObserver = nil
            synchronizer.removeTimeObserver(observer)
        }

        if !hasAvailableVideoFrameCallback {
            return
        }

        videoRenderer?.setNotifyWhenHasAvailableVideoFrame(true)
        if isUsingDecompressionSession {
            return
        }

        preferences |= prefersDecompressionSession
        videoRenderer?.setPreferences(preferences)

        if hasSelectedVideo {
            // Activating AvailableVideoFrame callback may force the use of decompression session.
            updateDisplayLayerIfNeeded(nil)
        }

        if willUseDecompressionSessionIfNeeded {
            return
        }

        let startupTime = startupTime
        videoFrameMetadataGatheringObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60, flags: .valid, epoch: 0), queue: .main) { [weak self] currentTime in
            onMainThread { [weak self] in
                guard let self, self.hasAvailableVideoFrameCallback else {
                    return
                }
                self.host.hasAvailableVideoFrame(currentTime, ProcessInfo.processInfo.systemUptime - startupTime)
            }
        } as AnyObject
    }

    private func configureLayerOrVideoRenderer(_ object: WebCore.AudioVideoRendererObject) {
        host.updateSpatialTrackingLabel()

        let isDisplayLayer = object == .DisplayLayer
        if isDisplayLayer && displayLayerState == .addedToSynchronizer {
            return
        }

        guard host.addToSynchronizer(object, 0) else {
            return
        }

        if isDisplayLayer {
            displayLayerState = .addedToSynchronizer
        }
    }

    private func stageVideoRenderer(_ object: WebCore.AudioVideoRendererObject?, _ completion: ((Bool) -> Void)?) {
        guard let videoRenderer else {
            completion?(false)
            return
        }

        let newIsRenderingCompressedVideo = object != nil && !willUseDecompressionSessionIfNeeded && !isReceivingDecodedSamples && hasEverSubmittedVideoSample
        let renderingObject = object.flatMap { host.renderingObject($0, 0) }
        if renderingObject === videoRenderer.mainRendererObject {
            let configurationChanged = isRenderingCompressedVideo != newIsRenderingCompressedVideo
            isRenderingCompressedVideo = newIsRenderingCompressedVideo
            if configurationChanged && object != nil {
                notifyRequiresFlushToResume()
            }
            completion?(true)
            return
        }

        var objectToExpire: (object: WebCore.AudioVideoRendererObject, trackId: UInt64)?
        if object != nil {
            switch acceleratedVideoMode {
            case .layer:
                if hasVideoRendererForTarget {
                    host.expireVideoRendererForTarget()
                    hasVideoRendererForTarget = false
                    // The expired renderer, which the C++ renderer still holds for this.
                    objectToExpire = (.VideoRendererForTarget, 1)
                }
            case .videoRenderer:
                // We only need to remove the AVSampleBufferDisplayLayer from the synchronizer.
                if hasDisplayLayer {
                    objectToExpire = (.DisplayLayer, 0)
                }
                displayLayerState = .pendingRemovalFromSynchronizer
            }
        } else {
            destroyLayer()
            destroyVideoRenderer()
        }

        let flushRequired = isRenderingCompressedVideo != newIsRenderingCompressedVideo && hasEverSubmittedVideoSample
        isRenderingCompressedVideo = newIsRenderingCompressedVideo
        if flushRequired {
            clearReadyToRequestVideoData()
        } else {
            readyToRequestVideoData = true
        }
        log(.Always, "AudioVideoRendererAVFObjC::stageVideoRenderer renderer: \(object != nil) flushRequired: \(flushRequired)")

        let expiring = ObjectToExpire(value: objectToExpire)
        let box = CompletionBox(completion: completion)
        videoRenderer.changeRenderer(mainRenderer(object)) { [weak self] in
            guard let self else {
                box.completion?(false)
                return
            }
            if let objectToExpire = expiring.value {
                self.removeFromSynchronizerIfNeeded(objectToExpire.object, objectToExpire.trackId)
            }
            if flushRequired {
                self.notifyRequiresFlushToResume()
            } else if self.readyToRequestVideoData {
                self.setReadyToRequestVideoData()
            }
            box.completion?(true)
        }
    }

    private func destroyVideoTrack() {
        cancelVideoDataRequest()
        resetVideoRequest()
        if let videoRenderer {
            self.videoRenderer = nil
            videoRendererForQueue.withLock { $0 = nil }
            videoRenderer.invalidate()
        }
        destroyLayer()
        destroyVideoRenderer()
        enabledVideoTrackId = nil
    }

    private func notifyRequiresFlushToResume() {
        log(.Always, "AudioVideoRendererAVFObjC::notifyRequiresFlushToResume")
        clearReadyToRequestVideoData()
        host.setNeedsPlaceholderImage(true)
        host.requiresFlushToResume()
    }

    private func flushVideo() {
        log(.Always, "AudioVideoRendererAVFObjC::flushVideo")

        setHasAvailableVideoFrame(false)
        hasEverSubmittedVideoSample = false
        // Flush may immediately call requestMediaDataWhenReady, so set m_readyToRequestVideoData before flushing the renderer.
        setReadyToRequestVideoData()
        videoRenderer?.flush()
        host.removeBlockedSamples(.Video, 0)
        flushPendingSizeChanges()
        keyframeNeeded = true
    }

    private func sizeWillChangeAtTime(_ time: RendererTime, _ size: (width: Float, height: Float)) {
        if !hasSizeChangedCallback {
            return
        }

        let observer = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: time.time)], queue: .main) { [weak self] in
            guard let self else {
                return
            }
            assert(!self.sizeChangeObservers.isEmpty)
            if !self.sizeChangeObservers.isEmpty {
                let observer = self.sizeChangeObservers.removeFirst()
                self.synchronizer.removeTimeObserver(observer)
            }
            if self.hasSizeChangedCallback {
                self.host.sizeChanged(time.time, size.width, size.height)
            }
        } as AnyObject
        sizeChangeObservers.append(observer)

        let now = RendererTime(time: currentTime())
        if now >= time && hasSizeChangedCallback {
            host.sizeChanged(now.time, size.width, size.height)
        }
    }

    private func flushPendingSizeChanges() {
        cachedSize = nil
        while !sizeChangeObservers.isEmpty {
            synchronizer.removeTimeObserver(sizeChangeObservers.removeFirst())
        }
    }

    private func trackDescription(_ trackId: UInt64) -> Swift.String {
        let kind = switch trackTypes[trackId] {
        case .video: "video:"
        case .audio: "audio:"
        case .none: "NotFound:"
        default: "unknown:"
        }
        return "[\(kind)\(trackId)]"
    }

    // MARK: VideoMediaSampleRendererClient

    @_expose(!Cxx)
    func videoRendererFirstFrameAvailable(_ presentationTime: RendererTime, _ displayTime: Double) {
        setHasAvailableVideoFrame(true)
    }

    @_expose(!Cxx)
    func videoRendererHasAvailableVideoFrame(_ presentationTime: RendererTime, _ displayTime: Double) {
        if hasAvailableVideoFrameCallback {
            host.hasAvailableVideoFrame(presentationTime.time, displayTime)
        }
    }

    @_expose(!Cxx)
    func videoRendererErrorOccurred(hdcpObscured: Bool?) {
        if let hdcpObscured {
            host.hdcpStatusChanged(hdcpObscured)
            return
        }
        notifyError(.videoDecodingError)
    }

    @_expose(!Cxx)
    func videoRendererRequiresFlushToResume() {
        notifyRequiresFlushToResume()
    }

    @_expose(!Cxx)
    func videoRendererReadyForMoreMediaData() {
        // As the C++ renderer heard its video renderer's promise settle: on a later turn of the main run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.videoDataRequestInFlight else {
                return
            }
            self.videoDataRequestInFlight = false
            guard let trackId = self.videoRequestTrackId else {
                return
            }
            self.videoRequestTrackId = nil
            self.host.mediaDataRequestSettled(true, trackId, true)
        }
    }

    // MARK: WebAVSampleBufferListenerClient

    @_expose(!Cxx)
    func videoRendererDidReceiveError(_ renderer: NSObject, _ error: NSError?) {
    }

    @_expose(!Cxx)
    func videoRendererRequiresFlushToResumeDecodingChanged(_ renderer: NSObject, _ requiresFlush: Bool) {
    }

    @_expose(!Cxx)
    func videoRendererReadyForDisplayChanged(_ renderer: NSObject, _ isReadyForDisplay: Bool) {
    }

    @_expose(!Cxx)
    func outputObscuredDueToInsufficientExternalProtectionChanged(_ obscured: Bool) {
    }

    @_expose(!Cxx)
    func audioRendererDidReceiveError(_ renderer: NSObject, _ error: NSError?) {
        notifyError(.audioDecodingError)
    }

    @_expose(!Cxx)
    func audioRendererWasAutomaticallyFlushed(_ renderer: NSObject, _ flushTime: CMTime) {
        guard let trackId = audioTracks.first(where: { $0.value.renderer?.object === renderer })?.key else {
            log(.Error, "AudioVideoRendererAVFObjC::audioRendererWasAutomaticallyFlushed Couldn't find track attached to Audio Renderer.")
            return
        }
        host.audioRendererWasFlushed(trackId, flushTime)
    }
}

private struct ObjectToExpire: @unchecked Sendable {
    let value: (object: WebCore.AudioVideoRendererObject, trackId: UInt64)?
}

private struct CompletionBox: @unchecked Sendable {
    let completion: ((Bool) -> Void)?
}
