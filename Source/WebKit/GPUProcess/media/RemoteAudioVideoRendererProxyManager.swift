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

#if ENABLE_GPU_PROCESS && ENABLE_VIDEO && WTF_PLATFORM_COCOA

@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal

private typealias RendererMessages = WebKit.RemoteAudioVideoRendererProxyManager.AudioVideoRendererRemoteMessageReceiverMessages
// A NotifyTimeReachedAndStall's or a PrepareToSeek's reply.
typealias RemoteAudioVideoRendererTimeResult = Result<IPCTypes.MediaTime, IPCUnexpected<IPCTypes.PlatformMediaError>>

// How often the renderer's time observer checks whether the video playback quality metrics are due, and how long
// before they are due they are sent.
private let metricsAdvanceUpdate = 0.25

extension IPCTypes.MediaTime {
    fileprivate init(_ time: AudioVideoRendererTime) {
        self.init(timeValue: time.value, timeScale: time.scale, timeFlags: time.flags)
    }

    fileprivate var rendererTime: AudioVideoRendererTime {
        AudioVideoRendererTime(value: timeValue, scale: timeScale, flags: timeFlags)
    }
}

// A renderer of the web process, whose Swift core it is the client of: what the C++ manager's callbacks and the C++
// renderer's promises kept, and the cadence of its video playback quality metrics.
@MainActor
private final class RemoteAudioVideoRenderer: AudioVideoRendererClient {
    let identifier: UInt64
    let core: AudioVideoRendererMainActorCore
    private weak var state: RemoteAudioVideoRendererProxyManagerState?

    // As the C++ renderer's own, after which it does nothing and refuses what it would have to settle later.
    var isShutdown = false
    // The pending NotifyTimeReachedAndStall's boundary and reply.
    private var pendingStall: (boundary: IPCTypes.MediaTime, reply: CheckedContinuation<RemoteAudioVideoRendererTimeResult, Never>)?
    // The pending FinishSeek's reply: whether the seek completed.
    private var pendingSeek: CheckedContinuation<Bool, Never>?
    // The time of the last PerformTaskAtTime, until its task runs.
    var taskTime: IPCTypes.MediaTime?
    var isGatheringVideoFrameMetadata = false
    var metricsUpdateInterval: Double = 0
    var nextMetricsUpdateTime: Double = 0

    init(identifier: UInt64, core: AudioVideoRendererMainActorCore, state: RemoteAudioVideoRendererProxyManagerState) {
        self.identifier = identifier
        self.core = core
        self.state = state
    }

    var rendererState: IPCTypes.RemoteAudioVideoRendererState {
        IPCTypes.RemoteAudioVideoRendererState(paused: core.paused())
    }

    // MARK: Replies

    func stall(at boundary: IPCTypes.MediaTime) async -> RemoteAudioVideoRendererTimeResult {
        cancelTimeReachedAction()
        // Pending before the core is asked, as the core may settle it at once.
        return await withCheckedContinuation { reply in
            pendingStall = (boundary, reply)
            if core.notifyTimeReachedAndStall(boundary.rendererTime) {
                pendingStall.take()?.reply.resume(returning: .success(boundary))
            }
        }
    }

    func cancelTimeReachedAction() {
        core.cancelTimeReachedAction()
        rejectPendingStall()
    }

    func rejectPendingStall() {
        pendingStall.take()?.reply.resume(returning: .failure(IPCUnexpected(.cancelled)))
    }

    // Whether the seek completed.
    func finishSeek(at seekTime: IPCTypes.MediaTime) async -> Bool {
        rejectPendingSeek()
        // Pending before the core is asked, as the core may complete the seek at once.
        return await withCheckedContinuation { reply in
            pendingSeek = reply
            if !core.finishSeek(seekTime.rendererTime) {
                rejectPendingSeek()
            }
        }
    }

    func rejectPendingSeek() {
        pendingSeek.take()?.resume(returning: false)
    }

    // MARK: Video playback quality metrics

    private var videoPlaybackQualityMetrics: IPCTypes.VideoPlaybackQualityMetrics? {
        core.videoPlaybackQualityMetrics().map {
            IPCTypes.VideoPlaybackQualityMetrics(
                totalVideoFrames: $0.totalVideoFrames,
                droppedVideoFrames: $0.droppedVideoFrames,
                corruptedVideoFrames: $0.corruptedVideoFrames,
                totalFrameDelay: $0.totalFrameDelay,
                displayCompositedVideoFrames: $0.displayCompositedVideoFrames
            )
        }
    }

    func updateCachedVideoMetrics() {
        nextMetricsUpdateTime = ProcessInfo.processInfo.systemUptime + metricsUpdateInterval
        guard let metrics = videoPlaybackQualityMetrics else {
            return
        }
        send { RendererMessages.updatePlaybackQualityMetrics(on: $0, to: identifier, metrics: metrics) }
    }

    private func maybeUpdateCachedVideoMetrics() {
        // While requestVideoFrameCallback gathers metadata, HasAvailableVideoFrame carries each frame's metrics, so
        // this cadence would only duplicate them.
        if isGatheringVideoFrameMetadata {
            return
        }
        if core.paused() || metricsUpdateInterval == 0 || ProcessInfo.processInfo.systemUptime < nextMetricsUpdateTime {
            return
        }
        updateCachedVideoMetrics()
    }

    // MARK: AudioVideoRendererClient

    private func send(_ body: (IPC.Connection) -> Void) {
        guard let connection = state?.connection else {
            return
        }
        body(connection)
    }

    nonisolated func rendererErrorOccurred(_ error: UInt8) {
        MainActor.assumeIsolated {
            guard let error = IPCTypes.PlatformMediaError(rawValue: error) else {
                return
            }
            send { RendererMessages.errorOccurred(on: $0, to: identifier, error: error) }
        }
    }

    nonisolated func rendererHasAvailableVideoFrame(_ presentationTime: AudioVideoRendererTime, _ displayTime: Double) {
        MainActor.assumeIsolated {
            // Per-frame consumers, like requestVideoFrameCallback, need the metrics of this exact frame.
            let metrics = videoPlaybackQualityMetrics
            send { RendererMessages.hasAvailableVideoFrame(on: $0, to: identifier, time: IPCTypes.MediaTime(presentationTime), clockTime: displayTime, state: rendererState, metrics: metrics) }
        }
    }

    nonisolated func rendererRequiresFlushToResume() {
        MainActor.assumeIsolated {
            send { RendererMessages.requiresFlushToResume(on: $0, to: identifier, state: rendererState) }
        }
    }

    nonisolated func rendererSizeChanged(_ time: AudioVideoRendererTime, width: Float, height: Float) {
        MainActor.assumeIsolated {
            send { RendererMessages.sizeChanged(on: $0, to: identifier, time: IPCTypes.MediaTime(time), size: IPCTypes.FloatSize(width: width, height: height), state: rendererState) }
        }
    }

    nonisolated func rendererEffectiveRateChanged(_ rate: Double) {
        MainActor.assumeIsolated {
            send { RendererMessages.effectiveRateChanged(on: $0, to: identifier, state: rendererState) }
        }
    }

    nonisolated func rendererMediaDataRequestSettled(trackId: UInt64, resolved: Bool) {
        MainActor.assumeIsolated {
            guard resolved, let track = IPCTypes.SamplesRendererTrackIdentifier(rawValue: trackId) else {
                return
            }
            send { RendererMessages.readyForMoreMediaData(on: $0, to: identifier, identifier: track) }
        }
    }

    nonisolated func rendererSeekSettled(_ resolved: Bool) {
        MainActor.assumeIsolated {
            pendingSeek.take()?.resume(returning: resolved)
        }
    }

    nonisolated func rendererTimeReached() {
        MainActor.assumeIsolated {
            guard let stall = pendingStall.take() else {
                return
            }
            stall.reply.resume(returning: .success(stall.boundary))
        }
    }

    nonisolated func rendererPerformTask() {
        MainActor.assumeIsolated {
            guard let time = taskTime.take() else {
                return
            }
            send { RendererMessages.taskTimeReached(on: $0, to: identifier, time: time, state: rendererState) }
        }
    }

    nonisolated func rendererTimeObserverFired() {
        MainActor.assumeIsolated {
            maybeUpdateCachedVideoMetrics()
        }
    }

    nonisolated func rendererAudioRendererWasFlushed(trackId: UInt64, time: AudioVideoRendererTime) {
        MainActor.assumeIsolated {
            guard let track = IPCTypes.SamplesRendererTrackIdentifier(rawValue: trackId) else {
                return
            }
            send { RendererMessages.trackNeedsReenqueuing(on: $0, to: identifier, identifier: track, time: IPCTypes.MediaTime(time), state: rendererState) }
        }
    }
}

// The Swift state of a RemoteAudioVideoRendererProxyManager (RemoteAudioVideoRendererProxyManager.h): its renderers by
// identifier, and the connection their notifications go on.
@MainActor
final class RemoteAudioVideoRendererProxyManagerState {
    let connection: IPC.Connection
    fileprivate var renderers: [UInt64: RemoteAudioVideoRenderer] = [:]

    fileprivate nonisolated init(connection: sending IPC.Connection) {
        self.connection = connection
    }

    // Each pending reply settles as the C++ renderer's promises did when it went away.
    fileprivate func removeAll() {
        let renderers = renderers
        self.renderers.removeAll()
        for renderer in renderers.values {
            renderer.rejectPendingStall()
            renderer.rejectPendingSeek()
        }
    }
}

extension WebKit.RemoteAudioVideoRendererProxyManager {
    @cxx
    @implementation
    func createSwiftState(_ connection: sending IPC.Connection) -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteAudioVideoRendererProxyManagerState(connection: connection)).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        let state = unsafe Unmanaged<RemoteAudioVideoRendererProxyManagerState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
        MainActor.assumeIsolated {
            state.removeAll()
        }
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The manager has no Swift state")
        }
        return unsafe address
    }

    private var state: RemoteAudioVideoRendererProxyManagerState {
        // Safety: m_swiftState is a retained RemoteAudioVideoRendererProxyManagerState from create() to the destructor,
        // and nothing else changes it.
        unsafe Unmanaged<RemoteAudioVideoRendererProxyManagerState>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }

    @cxx
    @implementation
    func addRenderer(_ identifier: UInt64, _ token: UInt64) {
        let state = state
        MainActor.assumeIsolated {
            guard let core = AudioVideoRendererMainActorCore.renderer(forToken: token) else {
                preconditionFailure("The renderer has no Swift core")
            }
            let renderer = RemoteAudioVideoRenderer(identifier: identifier, core: core, state: state)
            core.setClient(renderer)
            state.renderers[identifier] = renderer
        }
    }

    @cxx
    @implementation
    func clear() {
        let state = state
        MainActor.assumeIsolated {
            state.removeAll()
        }
    }

    @MainActor
    private func renderer(_ identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, function: StaticString = #function) throws(InvalidMessage) -> RemoteAudioVideoRenderer {
        let renderer = state.renderers[identifier.rawValue]
        try messageCheck("No renderer for the identifier", function: function) {
            renderer != nil
        }
        guard let renderer else {
            preconditionFailure("The message check let a missing renderer through")
        }
        return renderer
    }

    // MARK: Messages

    @MainActor
    func shutdown(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if renderer.isShutdown {
            return
        }
        renderer.rejectPendingStall()
        shutDownRenderer(identifier.rawValue)
        renderer.isShutdown = true
    }

    @MainActor
    func destroy(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        renderer.rejectPendingStall()
        destroyRenderer(identifier.rawValue)
        renderer.isShutdown = true
        renderer.rejectPendingSeek()
        state.renderers.removeValue(forKey: identifier.rawValue)
    }

    @MainActor
    func setHasProtectedVideoContent(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, isProtected: Bool) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.setHasProtectedVideoContent(isProtected)
        }
    }

    @MainActor
    func removeTrack(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, trackIdentifier: IPCTypes.SamplesRendererTrackIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.removeTrack(trackIdentifier.rawValue)
        }
    }

    @MainActor
    func requestMediaDataWhenReady(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, trackIdentifier: IPCTypes.SamplesRendererTrackIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if renderer.isShutdown {
            return
        }
        // 0: ready now; 1: the renderer tells its client when it settles.
        if renderer.core.requestMediaDataWhenReady(trackIdentifier.rawValue) == 0 {
            RendererMessages.readyForMoreMediaData(on: state.connection, to: identifier.rawValue, identifier: trackIdentifier)
        }
    }

    @MainActor
    func notifyTimeReachedAndStall(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, time: IPCTypes.MediaTime) async throws(InvalidMessage) -> RemoteAudioVideoRendererTimeResult {
        let renderer = try renderer(identifier)
        if renderer.isShutdown {
            return .failure(IPCUnexpected(.shutdown))
        }
        return await renderer.stall(at: time)
    }

    @MainActor
    func cancelTimeReachedAction(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier) throws(InvalidMessage) {
        try renderer(identifier).cancelTimeReachedAction()
    }

    @MainActor
    func performTaskAtTime(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, time: IPCTypes.MediaTime) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if renderer.isShutdown {
            return
        }
        renderer.taskTime = time
        renderer.core.performTaskAtTime(time.rendererTime)
    }

    @MainActor
    func flush(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.flush()
        }
    }

    @MainActor
    func flushTrack(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, trackIdentifier: IPCTypes.SamplesRendererTrackIdentifier) throws(InvalidMessage) -> Bool {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.flushTrack(trackIdentifier.rawValue)
        }
        return renderer.core.isReadyForMoreSamples(trackIdentifier.rawValue)
    }

    @MainActor
    func applicationWillResignActive(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.applicationWillResignActive()
        }
    }

    @MainActor
    func stall(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.stall()
        }
    }

    @MainActor
    func setRate(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, rate: Double) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.setRate(rate)
        }
    }

    @MainActor
    func setVolume(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, volume: Float) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.setVolume(volume)
        }
    }

    @MainActor
    func setMuted(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, muted: Bool) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.setMuted(muted)
        }
    }

    @MainActor
    func setPreservesPitchAndCorrectionAlgorithm(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteAudioVideoRendererIdentifier,
        preservePitch: Bool,
        pitchAlgorithm: IPCTypes.MediaPlayerPitchCorrectionAlgorithm?
    ) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.setPreservesPitchAndCorrectionAlgorithm(preservePitch, pitchAlgorithm?.rawValue)
        }
    }

    @MainActor
    func prepareToSeek(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, seekTime: IPCTypes.MediaTime) throws(InvalidMessage) -> RemoteAudioVideoRendererTimeResult {
        let renderer = try renderer(identifier)
        let result: RemoteAudioVideoRendererTimeResult
        if renderer.isShutdown {
            result = .failure(IPCUnexpected(.shutdown))
        } else if renderer.core.prepareToSeek(seekTime.rendererTime) {
            result = .success(seekTime)
        } else {
            result = .success(IPCTypes.MediaTime(AudioVideoRendererTime.indefiniteTime))
        }
        RendererMessages.stateUpdate(on: state.connection, to: identifier.rawValue, state: renderer.rendererState)
        return result
    }

    @MainActor
    func finishSeek(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, seekTime: IPCTypes.MediaTime) async throws(InvalidMessage) -> Bool {
        let renderer = try renderer(identifier)
        let completed = renderer.isShutdown ? false : await renderer.finishSeek(at: seekTime)
        RendererMessages.stateUpdate(on: state.connection, to: identifier.rawValue, state: renderer.rendererState)
        return completed
    }

    @MainActor
    func renderingCanBeAcceleratedChanged(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, accelerated: Bool) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.renderingCanBeAcceleratedChanged(accelerated)
        }
    }

    @MainActor
    func notifyWhenHasAvailableVideoFrame(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, notify: Bool) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        renderer.isGatheringVideoFrameMetadata = notify
        if !renderer.isShutdown {
            renderer.core.setHasAvailableVideoFrameCallback(notify)
        }
    }

    @MainActor
    func expectMinimumUpcomingPresentationTime(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, expected: IPCTypes.MediaTime) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        if !renderer.isShutdown {
            renderer.core.expectMinimumUpcomingPresentationTime(expected.rendererTime)
        }
    }

    @MainActor
    func setVideoPlaybackMetricsUpdateInterval(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioVideoRendererIdentifier, interval: Double) throws(InvalidMessage) {
        let renderer = try renderer(identifier)
        renderer.updateCachedVideoMetrics()
        renderer.metricsUpdateInterval = interval
        renderer.nextMetricsUpdateTime = ProcessInfo.processInfo.systemUptime + interval - metricsAdvanceUpdate
        // The metrics are the only reason for the time observer, so it runs only while they have an interval.
        if !renderer.isShutdown {
            renderer.core.setTimeObserver(interval: metricsAdvanceUpdate, enabled: interval > 0)
        }
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && WTF_PLATFORM_COCOA
