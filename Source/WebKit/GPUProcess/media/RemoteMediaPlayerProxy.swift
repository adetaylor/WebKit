// Copyright (C) 2019-2025 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebCore_Private.Core.MediaPlayer
import WebKit_Internal

private let lessFrequentTimeupdateEventInterval = 2.0
private let moreFrequentTimeupdateEventInterval = 0.25

private let metricsAdvanceUpdate = 0.25

extension WebKit.RemoteMediaPlayerProxy.MediaTimeResult: CxxExpected {}
extension WebKit.RemoteMediaPlayerProxy.VideoPlaybackQualityMetricsResult: CxxExpected {}

// This is safe because all conformances to the protocol are safe as long as they don't implement any of the
// requirements themselves.
extension WebKit.RemoteMediaPlayerProxy.MediaTimePromiseHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebKit.RemoteMediaPlayerProxy.MediaTimeResult
}

// As above.
extension WebKit.RemoteMediaPlayerProxy.VideoPlaybackQualityMetricsPromiseHandler: @unsafe CxxCompletionHandler {
    typealias Argument = WebKit.RemoteMediaPlayerProxy.VideoPlaybackQualityMetricsResult
}

extension WebKit.RemoteMediaPlayerProxy {
    // MARK: Loading and playback

    @cxx
    @implementation
    func prepareForPlayback(
        _ privateMode: Bool,
        _ preload: WebCore.MediaPlayerPreload,
        _ preservesPitch: Bool,
        _ pitchCorrectionAlgorithm: WebCore.MediaPlayerPitchCorrectionAlgorithm,
        _ prepareToPlay: Bool,
        _ prepareForRendering: Bool,
        _ presentationSize: WebCore.IntSize,
        _ videoContentScale: Float,
        _ isFullscreen: Bool,
        _ preferredDynamicRangeMode: WebCore.DynamicRangeMode,
        _ platformDynamicRangeLimit: WebCore.PlatformDynamicRangeLimit
    ) {
        let player = player()
        player.setPrivateBrowsingMode(privateMode)
        player.setPreload(preload)
        player.setPreservesPitch(preservesPitch)
        player.setPitchCorrectionAlgorithm(pitchCorrectionAlgorithm)
        player.setPreferredDynamicRangeMode(preferredDynamicRangeMode)
        player.setPlatformDynamicRangeLimit(platformDynamicRangeLimit)
        player.setPresentationSize(presentationSize)
        player.setInFullscreenOrPictureInPicture(isFullscreen)
        if prepareToPlay {
            player.prepareToPlay()
        }
        if prepareForRendering {
            player.prepareForRendering()
        }
        clientAdapter.setContentsScale(videoContentScale)
    }

    @cxx
    @implementation
    func configuration() -> WebKit.RemoteMediaPlayerConfiguration {
        let player = player()
        var configuration = WebKit.RemoteMediaPlayerConfiguration()
        configuration.engineDescription = player.engineDescription()
        configuration.supportsScanning = player.supportsScanning()
        configuration.supportsFullscreen = player.supportsFullscreen()
        configuration.supportsPictureInPicture = player.supportsPictureInPicture()
        configuration.supportsAcceleratedRendering = player.supportsAcceleratedRendering()
        configuration.supportsPlayAtHostTime = player.supportsPlayAtHostTime()
        configuration.supportsPauseAtHostTime = player.supportsPauseAtHostTime()
        #if ENABLE_WIRELESS_PLAYBACK_TARGET
        configuration.supportedPlaybackTargetTypes = player.supportedPlaybackTargetTypes()
        #endif
        configuration.shouldIgnoreIntrinsicSize = player.shouldIgnoreIntrinsicSize()
        return configuration
    }

    @cxx
    @implementation
    func seekToTarget(_ target: WebCore.SeekTarget, _ completionHandler: WebKit.RemoteMediaPlayerProxy.SeekCompletionHandler) {
        alwaysLog("seekToTarget", "\(target.time.toDouble())")
        let weakThis = weakPtrForSwift()
        WebKit.RemoteMediaPlayerProxy.MediaTimePromiseSettler.whenSettled(
            player().seekToTarget(target),
            consuming: .init { result in
                let reply: WebKit.RemoteMediaPlayerProxy.SeekResult
                do throws(CxxUnexpected<WebCore.PlatformMediaError>) {
                    let time = try result.value
                    if let proxy = weakThis.get(), !proxy.m_invalidated {
                        reply = WTF.makeExpected(proxy.timeUpdateData(proxy.player(), time))
                    } else {
                        reply = WTF.makeUnexpected(WebCore.PlatformMediaError.Cancelled)
                    }
                } catch {
                    reply = WTF.makeUnexpected(error.error)
                }
                completionHandler.pointee(reply)
            }
        )
    }

    @MainActor
    func didLoadingProgress(connection _: IPC.Connection) async -> Bool {
        let player = player()
        Messages.MediaPlayerPrivateRemote.sendReportGPUMemoryFootprint(webProcessConnection, destinationID, UInt64(WTF.memoryFootprint()))
        return await withCheckedContinuation { continuation in
            player.didLoadingProgress(consuming: .init(continuation))
        }
    }

    @cxx
    @implementation
    func isCrossOrigin(_ originData: WebCore.SecurityOriginData, _ completionHandler: WebKit.RemoteMediaPlayerProxy.IsCrossOriginCompletionHandler) {
        completionHandler.pointee(.init(player().isCrossOrigin(originData.securityOrigin().get())))
    }

    @cxx
    @implementation
    func colorSpace(_ completionHandler: WebKit.RemoteMediaPlayerProxy.ColorSpaceCompletionHandler) {
        completionHandler.pointee(player().colorSpace())
    }

    func prepareToPlay(connection _: IPC.Connection) {
        alwaysLog("prepareToPlay")
        player().prepareToPlay()
    }

    func prepareForRendering(connection _: IPC.Connection) {
        alwaysLog("prepareForRendering")
        player().prepareForRendering()
    }

    func cancelLoad(connection _: IPC.Connection) {
        stopUpdateCachedStateMessageTimer()
        player().cancelLoad()
    }

    func play(connection _: IPC.Connection) {
        let player = player()
        if player.movieLoadType() != .LiveStream {
            startUpdateCachedStateMessageTimer()
        }
        player.play()
        sendCachedState()
    }

    func pause(connection _: IPC.Connection) {
        stopUpdateCachedStateMessageTimer()
        updateCachedVideoMetrics()
        player().pause()
        sendCachedState()
    }

    func setRate(connection _: IPC.Connection, rate: Double) {
        player().setRate(rate)
    }

    @cxx
    @implementation
    func playAtHostTime(_ time: WTF.MonotonicTime) {
        _ = player().playAtHostTime(time)
    }

    @cxx
    @implementation
    func pauseAtHostTime(_ time: WTF.MonotonicTime) {
        _ = player().pauseAtHostTime(time)
    }

    func setBufferingPolicy(connection _: IPC.Connection, policy ipcValue: IPCTypes.MediaPlayerBufferingPolicy) {
        guard let policy = WebCore.MediaPlayerBufferingPolicy(rawValue: ipcValue.rawValue) else {
            return
        }
        player().setBufferingPolicy(policy)
    }

    func setPreload(connection _: IPC.Connection, preload ipcValue: IPCTypes.MediaPlayerPreload) {
        guard let preload = WebCore.MediaPlayerPreload(rawValue: ipcValue.rawValue) else {
            return
        }
        player().setPreload(preload)
    }

    func setPrivateBrowsingMode(connection _: IPC.Connection, privateMode: Bool) {
        player().setPrivateBrowsingMode(privateMode)
    }

    func applicationWillResignActive(connection _: IPC.Connection) {
        player().applicationWillResignActive()
    }

    func applicationDidBecomeActive(connection _: IPC.Connection) {
        player().applicationDidBecomeActive()
    }

    // MARK: Audio

    func setVolume(connection _: IPC.Connection, volume: Double) {
        player().setVolume(volume)
        #if ENABLE_WEB_AUDIO
        m_remoteAudioSourceProvider.get()?.setVolume(volume)
        #endif
    }

    func setPreservesPitch(connection _: IPC.Connection, preservesPitch: Bool) {
        player().setPreservesPitch(preservesPitch)
        #if ENABLE_WEB_AUDIO
        m_remoteAudioSourceProvider.get()?.setPreservesPitch(preservesPitch)
        #endif
    }

    func setVolumeLocked(connection _: IPC.Connection, volumeLocked: Bool) {
        player().setVolumeLocked(volumeLocked)
    }

    func setMuted(connection _: IPC.Connection, muted: Bool) {
        player().setMuted(muted)
    }

    func setPitchCorrectionAlgorithm(connection _: IPC.Connection, algorithm ipcValue: IPCTypes.MediaPlayerPitchCorrectionAlgorithm) {
        guard let algorithm = WebCore.MediaPlayerPitchCorrectionAlgorithm(rawValue: ipcValue.rawValue) else {
            return
        }
        player().setPitchCorrectionAlgorithm(algorithm)
    }

    func audioOutputDeviceChanged(connection _: IPC.Connection, deviceId: String?) {
        m_configuration.audioOutputDeviceId = WTF.String(deviceId)
        player().audioOutputDeviceChanged()

        #if WTF_PLATFORM_IOS_FAMILY && USE_AUDIO_SESSION
        setPreferredSpeakerID()
        #endif
    }

    func setSoundStageSize(connection _: IPC.Connection, value ipcValue: IPCTypes.MediaPlayerSoundStageSize) {
        guard let size = WebCore.MediaPlayerSoundStageSize(rawValue: ipcValue.rawValue) else {
            return
        }
        if clientAdapter.mediaPlayerSoundStageSize() == size {
            return
        }
        clientAdapter.setSoundStageSize(size)

        player().soundStageSizeDidChange()
    }

    #if HAVE_SPATIAL_TRACKING_LABEL
    func setDefaultSpatialTrackingLabel(connection _: IPC.Connection, defaultSpatialTrackingLabel: String?) {
        player().setDefaultSpatialTrackingLabel(WTF.String(defaultSpatialTrackingLabel))
    }

    func setSpatialTrackingLabel(connection _: IPC.Connection, spatialTrackingLabel: String?) {
        player().setSpatialTrackingLabel(WTF.String(spatialTrackingLabel))
    }
    #endif

    #if HAVE_SPATIAL_AUDIO_EXPERIENCE
    func setPrefersSpatialAudioExperience(connection _: IPC.Connection, value: Bool) {
        player().setPrefersSpatialAudioExperience(value)
    }
    #endif

    // MARK: Presentation

    func setPresentationSize(connection _: IPC.Connection, size ipcSize: IPCTypes.IntSize) {
        if ipcSize.width == m_configuration.presentationSize.width() && ipcSize.height == m_configuration.presentationSize.height() {
            return
        }

        let size = WebCore.IntSize(ipcSize.width, ipcSize.height)
        m_configuration.presentationSize = size
        player().setPresentationSize(size)
    }

    func setPageIsVisible(connection _: IPC.Connection, visible: Bool) {
        alwaysLog("setPageIsVisible", "\(visible)")
        player().setPageIsVisible(visible)
    }

    func setViewportVisibility(connection _: IPC.Connection, visibility ipcValue: IPCTypes.MediaPlayerViewportVisibility) {
        guard let visibility = WebCore.MediaPlayerViewportVisibility(rawValue: ipcValue.rawValue) else {
            return
        }
        alwaysLog("setViewportVisibility", "\(visibility.rawValue)")
        player().setViewportVisibility(visibility)
    }

    func acceleratedRenderingStateChanged(connection _: IPC.Connection, canBeAccelerated renderingCanBeAccelerated: Bool) {
        alwaysLog("acceleratedRenderingStateChanged", "\(renderingCanBeAccelerated)")
        clientAdapter.setRenderingCanBeAccelerated(renderingCanBeAccelerated)
        player().acceleratedRenderingStateChanged()
    }

    @cxx
    @implementation
    func playerContentBoxRectChanged(_ contentRect: WebCore.LayoutRect) {
        if clientAdapter.mediaPlayerContentBoxRect() == contentRect {
            return
        }

        clientAdapter.setContentBoxRect(contentRect)

        player().playerContentBoxRectChanged(contentRect)
    }

    func setShouldMaintainAspectRatio(connection _: IPC.Connection, maintainAspectRatio maintainRatio: Bool) {
        player().setShouldMaintainAspectRatio(maintainRatio)
    }

    func setShouldDisableSleep(connection _: IPC.Connection, disable: Bool) {
        player().setShouldDisableSleep(disable)
    }

    func setShouldDisableHDR(connection _: IPC.Connection, shouldDisable: Bool) {
        if m_configuration.shouldDisableHDR == shouldDisable {
            return
        }

        m_configuration.shouldDisableHDR = shouldDisable
        clientAdapter.setShouldDisableHDR(shouldDisable)
        player().setShouldDisableHDR(shouldDisable)
    }

    func setPreferredDynamicRangeMode(connection _: IPC.Connection, mode ipcValue: IPCTypes.DynamicRangeMode) {
        guard let mode = WebCore.DynamicRangeMode(rawValue: ipcValue.rawValue) else {
            return
        }
        player().setPreferredDynamicRangeMode(mode)
    }

    @cxx
    @implementation
    func setPlatformDynamicRangeLimit(_ platformDynamicRangeLimit: WebCore.PlatformDynamicRangeLimit) {
        player().setPlatformDynamicRangeLimit(platformDynamicRangeLimit)
    }

    func setShouldCheckHardwareSupport(connection _: IPC.Connection, value: Bool) {
        player().setShouldCheckHardwareSupport(value)
        clientAdapter.setShouldCheckHardwareSupport(value)
    }

    func isInFullscreenOrPictureInPictureChanged(connection _: IPC.Connection, value isInFullscreenOrPictureInPicture: Bool) {
        player().setInFullscreenOrPictureInPicture(isInFullscreenOrPictureInPicture)
    }

    func startVideoFrameMetadataGathering(connection _: IPC.Connection) {
        player().startVideoFrameMetadataGathering()
    }

    func stopVideoFrameMetadataGathering(connection _: IPC.Connection) {
        player().stopVideoFrameMetadataGathering()
    }

    #if WTF_PLATFORM_MAC
    func screenReservedChanged(connection _: IPC.Connection, value reserved: Bool) {
        player().setScreenReserved(reserved)
    }
    #endif

    #if ENABLE_VIDEO_PRESENTATION_MODE
    func updateVideoFullscreenInlineImage(connection _: IPC.Connection) {
        player().updateVideoFullscreenInlineImage()
    }

    func setVideoFullscreenMode(connection _: IPC.Connection, mode: UInt32) {
        clientAdapter.setFullscreenMode(mode)
        player().setVideoFullscreenMode(mode)
    }

    func videoFullscreenStandbyChanged(connection _: IPC.Connection, standby: Bool) {
        clientAdapter.setIsVideoFullscreenStandby(standby)
        player().videoFullscreenStandbyChanged()
    }

    func setVideoFullscreenGravity(connection _: IPC.Connection, gravity ipcValue: IPCTypes.MediaPlayerVideoGravity) {
        guard let gravity = WebCore.MediaPlayerVideoGravity(rawValue: ipcValue.rawValue) else {
            return
        }
        player().setVideoFullscreenGravity(gravity)
    }
    #endif

    // MARK: Tracks

    func notifyTrackModeChanged(connection _: IPC.Connection) {
        player().notifyTrackModeChanged()
    }

    func tracksChanged(connection _: IPC.Connection) {
        player().tracksChanged()
    }

    // MARK: Wireless playback

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    func setWirelessVideoPlaybackDisabled(connection _: IPC.Connection, disabled: Bool) {
        let player = player()
        player.setWirelessVideoPlaybackDisabled(disabled)
        m_cachedState.wirelessVideoPlaybackDisabled = player.wirelessVideoPlaybackDisabled()
        sendCachedState()
    }

    func setShouldPlayToPlaybackTarget(connection _: IPC.Connection, shouldPlay: Bool) {
        player().setShouldPlayToPlaybackTarget(shouldPlay)
    }
    #endif

    // MARK: Keys

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    func keyAdded(connection _: IPC.Connection) {
        player().keyAdded()
    }

    @MainActor
    func setLegacyCDMSession(connection _: IPC.Connection, instanceId: IPCTypes.RemoteLegacyCDMSessionIdentifier?) {
        guard let connection = m_manager.get()?.swiftGPUConnection() else {
            assertionFailure("The media player outlived its connection")
            return
        }
        let identifier = instanceId?.rawValue ?? 0
        if m_legacySessionIdentifier == identifier {
            return
        }

        let sessions = connection.state.legacyCDMFactory
        if m_legacySessionIdentifier != 0, sessions?.session(m_legacySessionIdentifier) != nil {
            setPlayerLegacyCDMSession(nil)
        }

        m_legacySessionIdentifier = identifier

        if identifier != 0, let client = sessions?.session(identifier) {
            setPlayerLegacyCDMSession(client)
        }
    }
    #endif

    #if ENABLE_ENCRYPTED_MEDIA
    @MainActor
    func cdmInstanceAttached(connection _: IPC.Connection, instanceId: IPCTypes.RemoteCDMInstanceIdentifier) {
        if let instance = cdmInstance(instanceId) {
            player().cdmInstanceAttached(instance)
        }
    }

    @MainActor
    func cdmInstanceDetached(connection _: IPC.Connection, instanceId: IPCTypes.RemoteCDMInstanceIdentifier) {
        if let instance = cdmInstance(instanceId) {
            player().cdmInstanceDetached(instance)
        }
    }

    @MainActor
    func attemptToDecryptWithInstance(connection _: IPC.Connection, instanceId: IPCTypes.RemoteCDMInstanceIdentifier) {
        if let instance = cdmInstance(instanceId) {
            player().attemptToDecryptWithInstance(instance)
        }
    }

    // The C++ instance of one of the web process's CDM instances: none for the Swift ClearKey instances, or once the web
    // process has gone.
    @MainActor
    private func cdmInstance(_ identifier: IPCTypes.RemoteCDMInstanceIdentifier) -> WebCore.CDMInstance? {
        guard let connection = m_manager.get()?.swiftGPUConnection() else {
            assertionFailure("The media player outlived its connection")
            return nil
        }
        return connection.state.cdmFactory?.cxxInstance(identifier.rawValue)
    }
    #endif

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA && ENABLE_ENCRYPTED_MEDIA
    func setShouldContinueAfterKeyNeeded(connection _: IPC.Connection, should: Bool) {
        player().setShouldContinueAfterKeyNeeded(should)
    }
    #endif

    // MARK: Cached state

    func startUpdateCachedStateMessageTimer() {
        if isUpdateCachedStateMessageTimerActive() {
            return
        }

        startRepeatingUpdateCachedStateMessageTimer(m_observingTimeChanges ? lessFrequentTimeupdateEventInterval : moreFrequentTimeupdateEventInterval)
    }

    @cxx
    @implementation
    func timerFired() {
        sendCachedState()
    }

    func updateCachedState(_ forceCurrentTimeUpdate: Bool) {
        let player = player()
        if !m_observingTimeChanges || forceCurrentTimeUpdate {
            currentTimeChanged(player.currentTime())
        }

        m_cachedState.paused = player.paused()
        maybeUpdateCachedVideoMetrics()
        if m_bufferedChanged {
            m_bufferedChanged = false
            cacheBufferedRanges()
        }
    }

    func sendCachedState() {
        updateCachedState(false)
        Messages.MediaPlayerPrivateRemote.sendUpdateCachedState(webProcessConnection, destinationID, m_cachedState)
        m_cachedState.bufferedRanges = nil
    }

    func updateCachedMediaCharacteristics() {
        let player = player()
        m_cachedState.hasAudio = player.hasAudio()
        m_cachedState.hasVideo = player.hasVideo()
        m_cachedState.videoFrameHasAlpha = player.videoFrameHasAlpha()
        m_cachedState.hasClosedCaptions = player.hasClosedCaptions()
        m_cachedState.languageOfPrimaryAudioTrack = player.languageOfPrimaryAudioTrack()
    }

    // MARK: Video playback quality metrics

    func setVideoPlaybackMetricsUpdateInterval(connection _: IPC.Connection, interval: Double) {
        alwaysLog("setVideoPlaybackMetricsUpdateInterval", "\(interval)")

        updateCachedVideoMetrics()
        m_videoPlaybackMetricsUpdateInterval = interval
        m_nextPlaybackQualityMetricsUpdateTime = ProcessInfo.processInfo.systemUptime + interval - metricsAdvanceUpdate
    }

    func maybeUpdateCachedVideoMetrics() {
        if m_cachedState.paused || m_videoPlaybackMetricsUpdateInterval == 0 || ProcessInfo.processInfo.systemUptime < m_nextPlaybackQualityMetricsUpdateTime || m_hasPlaybackMetricsUpdatePending {
            return
        }

        updateCachedVideoMetrics()
    }

    func updateCachedVideoMetrics() {
        alwaysLog("updateCachedVideoMetrics")
        m_nextPlaybackQualityMetricsUpdateTime = ProcessInfo.processInfo.systemUptime + m_videoPlaybackMetricsUpdateInterval
        if m_hasPlaybackMetricsUpdatePending {
            return
        }
        m_hasPlaybackMetricsUpdatePending = true
        let weakThis = weakPtrForSwift()
        WebKit.RemoteMediaPlayerProxy.VideoPlaybackQualityMetricsPromiseSettler.whenSettled(
            player().asyncVideoPlaybackQualityMetrics(),
            consuming: .init { result in
                guard let proxy = weakThis.get(), !proxy.m_invalidated else {
                    return
                }
                do {
                    let metrics = try result.value
                    proxy.m_cachedState.videoMetrics = .init(metrics)
                    Messages.MediaPlayerPrivateRemote.sendUpdatePlaybackQualityMetrics(proxy.webProcessConnection, proxy.destinationID, metrics)
                } catch {
                    proxy.m_cachedState.videoMetrics = nil
                }
                proxy.m_hasPlaybackMetricsUpdatePending = false
            }
        )
    }

    // MARK: MediaPlayerClient

    func mediaPlayerNetworkStateChanged() {
        updateCachedState(true)
        m_cachedState.networkState = player().networkState()
        Messages.MediaPlayerPrivateRemote.sendNetworkStateChanged(webProcessConnection, destinationID, m_cachedState)
    }

    func mediaPlayerReadyStateChanged() {
        let player = player()
        let newReadyState = player.readyState()
        alwaysLog("mediaPlayerReadyStateChanged", "\(newReadyState.rawValue)")
        updateCachedVideoMetrics()
        updateCachedState(true)
        updateCachedMediaCharacteristics()
        m_cachedState.networkState = player.networkState()
        m_cachedState.duration = player.duration()

        m_cachedState.movieLoadType = player.movieLoadType()
        m_cachedState.minTimeSeekable = player.minTimeSeekable()
        m_cachedState.maxTimeSeekable = player.maxTimeSeekable()
        m_cachedState.startDate = player.getStartDate()
        m_cachedState.startTime = player.startTime()
        m_cachedState.naturalSize = player.naturalSize()
        m_cachedState.maxFastForwardRate = player.maxFastForwardRate()
        m_cachedState.minFastReverseRate = player.minFastReverseRate()
        m_cachedState.seekableTimeRangesLastModifiedTime = player.seekableTimeRangesLastModifiedTime()
        m_cachedState.liveUpdateInterval = player.liveUpdateInterval()
        m_cachedState.hasAvailableVideoFrame = player.hasAvailableVideoFrame()
        m_cachedState.videoFrameHasAlpha = player.videoFrameHasAlpha()
        #if ENABLE_WIRELESS_PLAYBACK_TARGET
        m_cachedState.wirelessVideoPlaybackDisabled = player.wirelessVideoPlaybackDisabled()
        #endif
        m_cachedState.canSaveMediaData = player.canSaveMediaData()
        m_cachedState.didPassCORSAccessCheck = player.didPassCORSAccessCheck()
        m_cachedState.documentIsCrossOrigin = .init(player.isCrossOrigin(m_configuration.documentSecurityOrigin.securityOrigin().get()))

        Messages.MediaPlayerPrivateRemote.sendReadyStateChanged(webProcessConnection, destinationID, m_cachedState, newReadyState)
    }

    func mediaPlayerVolumeChanged() {
        Messages.MediaPlayerPrivateRemote.sendVolumeChanged(webProcessConnection, destinationID, player().volume())
    }

    func mediaPlayerMuteChanged() {
        Messages.MediaPlayerPrivateRemote.sendMuteChanged(webProcessConnection, destinationID, player().muted())
    }

    func mediaPlayerTimeChanged() {
        updateCachedState(true)

        let player = player()
        m_cachedState.duration = player.duration()
        Messages.MediaPlayerPrivateRemote.sendTimeChanged(webProcessConnection, destinationID, m_cachedState, timeUpdateData(player, player.currentTime()))
    }

    func mediaPlayerDurationChanged() {
        updateCachedState(true)
        m_cachedState.duration = player().duration()
        Messages.MediaPlayerPrivateRemote.sendDurationChanged(webProcessConnection, destinationID, m_cachedState)
    }

    func mediaPlayerPlaybackStateChanged() {
        let player = player()
        m_cachedState.paused = player.paused()
        Messages.MediaPlayerPrivateRemote.sendPlaybackStateChanged(webProcessConnection, destinationID, m_cachedState.paused, timeUpdateData(player, player.currentTime()))
    }

    func mediaPlayerRateChanged() {
        updateCachedVideoMetrics()
        sendCachedState()

        let player = player()
        let effectiveRate = player.effectiveRate()

        #if ENABLE_WEB_AUDIO
        m_remoteAudioSourceProvider.get()?.setPlaybackRate(effectiveRate)
        #endif

        Messages.MediaPlayerPrivateRemote.sendRateChanged(webProcessConnection, destinationID, effectiveRate, timeUpdateData(player, player.currentTime()))
    }

    @cxx
    @implementation
    func currentTimeChanged(_ mediaTime: WTF.MediaTime) {
        Messages.MediaPlayerPrivateRemote.sendCurrentTimeChanged(webProcessConnection, destinationID, timeUpdateData(player(), mediaTime))
    }

    @cxx
    @implementation
    func destroyResourceLoader(_ loaderIdentifier: WebKit.RemoteMediaResourceLoaderIdentifier) {
        Messages.MediaPlayerPrivateRemote.sendDestroyResourceLoader(webProcessConnection, destinationID, loaderIdentifier)
    }

    func mediaPlayerEngineFailedToLoad() {
        Messages.MediaPlayerPrivateRemote.sendEngineFailedToLoad(webProcessConnection, destinationID, Int64(player().platformErrorCode()))
    }

    func mediaPlayerResourceNotSupported() {
        Messages.MediaPlayerPrivateRemote.sendResourceNotSupported(webProcessConnection, destinationID)
    }

    func mediaPlayerSizeChanged() {
        m_cachedState.naturalSize = player().naturalSize()
        Messages.MediaPlayerPrivateRemote.sendSizeChanged(webProcessConnection, destinationID, m_cachedState.naturalSize)
    }

    func mediaPlayerCharacteristicChanged() {
        updateCachedVideoMetrics()
        updateCachedState(false)
        updateCachedMediaCharacteristics()

        Messages.MediaPlayerPrivateRemote.sendCharacteristicChanged(webProcessConnection, destinationID, m_cachedState)
    }

    func mediaPlayerBufferedTimeRangesChanged() {
        m_bufferedChanged = true
    }

    func mediaPlayerSeekableTimeRangesChanged() {
        let player = player()
        m_cachedState.minTimeSeekable = player.minTimeSeekable()
        m_cachedState.maxTimeSeekable = player.maxTimeSeekable()
        m_cachedState.seekableTimeRangesLastModifiedTime = player.seekableTimeRangesLastModifiedTime()
        m_cachedState.liveUpdateInterval = player.liveUpdateInterval()

        if !isUpdateCachedStateMessageTimerActive() {
            sendCachedState()
        }
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    fileprivate func mediaPlayerKeyNeeded(_ message: WebCore.SharedBuffer) {
        WebKit.sendMediaPlayerKeyNeeded(webProcessConnection, destinationID, message)
    }
    #endif

    #if ENABLE_ENCRYPTED_MEDIA
    func mediaPlayerWaitingForKeyChanged() {
        Messages.MediaPlayerPrivateRemote.sendWaitingForKeyChanged(webProcessConnection, destinationID, player().waitingForKey())
    }
    #endif

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    func mediaPlayerCurrentPlaybackTargetIsWirelessChanged(_ isCurrentPlaybackTargetWireless: Bool) {
        let player = player()
        m_cachedState.wirelessPlaybackTargetName = player.wirelessPlaybackTargetName()
        m_cachedState.wirelessPlaybackRouteName = player.wirelessPlaybackRouteName()
        m_cachedState.wirelessPlaybackTargetType = player.wirelessPlaybackTargetType()
        sendCachedState()
        Messages.MediaPlayerPrivateRemote.sendCurrentPlaybackTargetIsWirelessChanged(webProcessConnection, destinationID, isCurrentPlaybackTargetWireless)
    }
    #endif

    // MARK: MediaPlayerClient values

    @cxx
    @implementation
    static func makeMediaPlayerClientDelegateBox() -> UInt {
        makeSwiftMediaPlayerClientDelegateBox(RemoteMediaPlayerClient())
    }

    @cxx
    @implementation
    func connectMediaPlayerClientDelegate() {
        guard let delegate = clientAdapter.mediaPlayerClientDelegate as? RemoteMediaPlayerClient else {
            preconditionFailure("The media player client adapter has no RemoteMediaPlayerClient")
        }
        delegate.proxy = weakPtrForSwift()

        let adapter = clientAdapter
        adapter.setRenderingCanBeAccelerated(m_configuration.renderingCanBeAccelerated)
        adapter.setContentBoxRect(m_configuration.playerContentBoxRect)
        adapter.setIsVideo(m_configuration.isVideo)
        adapter.setShouldUsePersistentCache(m_configuration.shouldUsePersistentCache)
        adapter.setShouldDisableHDR(m_configuration.shouldDisableHDR)
    }

    private var clientAdapter: WebCore.SwiftMediaPlayerClientAdapter {
        m_clientAdapter.get()
    }

    // MARK: For RemoteMediaPlayerClient, which can't reach the proxy's private members

    fileprivate var referrer: WTF.String {
        m_configuration.referrer
    }

    fileprivate var userAgent: WTF.String {
        m_configuration.userAgent
    }

    fileprivate var sourceApplicationIdentifier: WTF.String {
        m_configuration.sourceApplicationIdentifier
    }

    fileprivate var audioOutputDeviceId: WTF.String {
        m_configuration.audioOutputDeviceId
    }

    fileprivate var gpuConnection: WebKit.GPUConnectionToWebProcess? {
        m_manager.get()?.swiftGPUConnection()
    }

    // MARK: Sends

    private var webProcessConnection: IPC.Connection {
        m_webProcessConnection.get()
    }

    private var destinationID: UInt64 {
        m_id.toUInt64()
    }

    private func timeUpdateData(_ player: WebCore.MediaPlayer, _ time: WTF.MediaTime) -> WebCore.MediaTimeUpdateData {
        WebCore.MediaTimeUpdateData(
            currentTime: time,
            effectiveRate: player.timeIsProgressing() ? player.effectiveRate() : 0,
            wallTime: WTF.MonotonicTime.now()
        )
    }

    // MARK: Logging

    private func alwaysLog(_ function: StaticString, _ values: @autoclosure () -> Swift.String = "") {
        guard willLogAlways() else {
            return
        }
        let identifier = Swift.String(m_configuration.logIdentifier, radix: 16, uppercase: true)
        let suffix = values()
        let message = "RemoteMediaPlayerProxy::\(function)(\(identifier))" + (suffix.isEmpty ? "" : " \(suffix)")
        logAlways(WTF.String(message))
    }
}

// MARK: Track proxies

@MainActor
private protocol RemoteTrackProxy: AnyObject {
    var id: WebCore.TrackID { get }
}

extension RemoteAudioTrackProxy: RemoteTrackProxy {}
extension RemoteVideoTrackProxy: RemoteTrackProxy {}
extension RemoteTextTrackProxy: RemoteTrackProxy {}

// The proxies of a player's tracks, by kind, in the order that the player added them.
@MainActor
private final class RemoteMediaPlayerTracks {
    private var audioTracks: [RemoteAudioTrackProxy] = []
    private var videoTracks: [RemoteVideoTrackProxy] = []
    private var textTracks: [RemoteTextTrackProxy] = []

    func addAudioTrack(_ track: WebCore.AudioTrackPrivate, connection: IPC.Connection, mediaPlayerIdentifier: UInt64) {
        Self.add(to: &audioTracks, identifier: track.id(), isTrack: { $0.isTrack(track) }) {
            RemoteAudioTrackProxy(track: track, connection: connection, mediaPlayerIdentifier: mediaPlayerIdentifier)
        }
    }

    func addVideoTrack(_ track: WebCore.VideoTrackPrivate, connection: IPC.Connection, mediaPlayerIdentifier: UInt64) {
        Self.add(to: &videoTracks, identifier: track.id(), isTrack: { $0.isTrack(track) }) {
            RemoteVideoTrackProxy(track: track, connection: connection, mediaPlayerIdentifier: mediaPlayerIdentifier)
        }
    }

    func addTextTrack(_ track: WebCore.InbandTextTrackPrivate, connection: IPC.Connection, mediaPlayerIdentifier: UInt64) {
        Self.add(to: &textTracks, identifier: track.id(), isTrack: { $0.isTrack(track) }) {
            RemoteTextTrackProxy(track: track, connection: connection, mediaPlayerIdentifier: mediaPlayerIdentifier)
        }
    }

    func removeAudioTrack(_ identifier: WebCore.TrackID) {
        if let index = audioTracks.firstIndex(where: { $0.id == identifier }) {
            audioTracks.remove(at: index)
        }
    }

    func removeVideoTrack(_ identifier: WebCore.TrackID) {
        if let index = videoTracks.firstIndex(where: { $0.id == identifier }) {
            videoTracks.remove(at: index)
        }
    }

    func removeTextTrack(_ identifier: WebCore.TrackID) {
        if let index = textTracks.firstIndex(where: { $0.id == identifier }) {
            textTracks.remove(at: index)
        }
    }

    func setAudioTrackEnabled(_ identifier: WebCore.TrackID, _ enabled: Bool) {
        audioTracks.first { $0.id == identifier }?.setEnabled(enabled)
    }

    func setVideoTrackSelected(_ identifier: WebCore.TrackID, _ selected: Bool) {
        videoTracks.first { $0.id == identifier }?.setSelected(selected)
    }

    func setTextTrackMode(_ identifier: WebCore.TrackID, _ mode: WebCore.InbandTextTrackPrivateMode) {
        textTracks.first { $0.id == identifier }?.setMode(mode)
    }

    // Nothing if the track already has a proxy, a new proxy in place of the one with the track's identifier if there is
    // one, otherwise a new proxy at the end.
    private static func add<Proxy: RemoteTrackProxy>(
        to proxies: inout [Proxy],
        identifier: WebCore.TrackID,
        isTrack: (Proxy) -> Bool,
        makeProxy: () -> Proxy
    ) {
        for index in proxies.indices {
            if isTrack(proxies[index]) {
                return
            }
            if proxies[index].id == identifier {
                proxies[index] = makeProxy()
                return
            }
        }
        proxies.append(makeProxy())
    }
}

// A player's Swift state: its tracks' proxies, and the reply to its pending PerformTaskAtTime. A media player tracks one
// pending task at a time (see MediaPlayerPrivateAVFoundationObjC::performTaskAtMediaTime), so a new one cancels the
// previous one, and the state cancels the last one when the proxy goes.
private final class RemoteMediaPlayerSwiftState {
    let tracks: RemoteMediaPlayerTracks
    private var taskAtTimeReply: CheckedContinuation<IPCTypes.MediaTime?, Never>?

    init(tracks: RemoteMediaPlayerTracks) {
        self.tracks = tracks
    }

    deinit {
        replyToTaskAtTime(nil)
    }

    func waitForTaskAtTime(_ reply: CheckedContinuation<IPCTypes.MediaTime?, Never>) {
        taskAtTimeReply = reply
    }

    func replyToTaskAtTime(_ time: IPCTypes.MediaTime?) {
        guard let reply = taskAtTimeReply else {
            return
        }
        taskAtTimeReply = nil
        reply.resume(returning: time)
    }
}

extension IPCTypes.MediaTime {
    fileprivate init(_ time: WTF.MediaTime) {
        self.init(timeValue: time.timeValue(), timeScale: time.timeScale(), timeFlags: time.timeFlags())
    }
}

extension WebKit.RemoteMediaPlayerProxy {
    @cxx
    @implementation
    static func createSwiftTracks() -> UInt {
        let tracks = MainActor.assumeIsolated {
            RemoteMediaPlayerTracks()
        }
        return UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteMediaPlayerSwiftState(tracks: tracks)).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftTracks(_ swiftTracks: UInt) {
        // Safety: the destructor passes the state that createSwiftTracks() made, once.
        unsafe Unmanaged<RemoteMediaPlayerSwiftState>.fromOpaque(tracksAddress(swiftTracks)).release()
    }

    private static func tracksAddress(_ swiftTracks: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftTracks) else {
            preconditionFailure("The player has no tracks")
        }
        return unsafe address
    }

    private var swiftState: RemoteMediaPlayerSwiftState {
        // Safety: m_swiftTracks is a retained RemoteMediaPlayerSwiftState from the constructor to the destructor, and
        // nothing else changes it.
        unsafe Unmanaged<RemoteMediaPlayerSwiftState>.fromOpaque(Self.tracksAddress(swiftTracks())).takeUnretainedValue()
    }

    private var tracks: RemoteMediaPlayerTracks {
        swiftState.tracks
    }

    @cxx
    @implementation
    func cancelPendingTaskAtTime() {
        swiftState.replyToTaskAtTime(nil)
    }

    @MainActor
    func performTaskAtTime(connection _: IPC.Connection, mediaTime: IPCTypes.MediaTime) async -> IPCTypes.MediaTime? {
        let state = swiftState
        state.replyToTaskAtTime(nil)

        let player = player()
        let taskTime = WTF.MediaTime(mediaTime.timeValue, mediaTime.timeScale, mediaTime.timeFlags)
        let currentTime = player.currentTime()
        if WebKit.mediaTimeIsLessThanOrEqual(taskTime, currentTime) {
            return IPCTypes.MediaTime(currentTime)
        }

        let weakThis = weakPtrForSwift()
        return await withCheckedContinuation { (reply: CheckedContinuation<IPCTypes.MediaTime?, Never>) in
            state.waitForTaskAtTime(reply)
            _ = WebKit.performMediaPlayerTaskAtTime(player, consuming: WebKit.MediaPlayerTimeTask { (time: WTF.MediaTime) in
                weakThis.get()?.swiftState.replyToTaskAtTime(IPCTypes.MediaTime(time))
            }, taskTime)
        }
    }

    @MainActor
    fileprivate func mediaPlayerDidAddAudioTrack(_ track: WebCore.AudioTrackPrivate) {
        if prepareTrackForProxy(track) {
            tracks.addAudioTrack(track, connection: webProcessConnection, mediaPlayerIdentifier: destinationID)
        }
    }

    @MainActor
    fileprivate func mediaPlayerDidAddVideoTrack(_ track: WebCore.VideoTrackPrivate) {
        if prepareTrackForProxy(track) {
            tracks.addVideoTrack(track, connection: webProcessConnection, mediaPlayerIdentifier: destinationID)
        }
    }

    @MainActor
    fileprivate func mediaPlayerDidAddTextTrack(_ track: WebCore.InbandTextTrackPrivate) {
        if prepareTrackForProxy(track) {
            tracks.addTextTrack(track, connection: webProcessConnection, mediaPlayerIdentifier: destinationID)
        }
    }

    @MainActor
    fileprivate func mediaPlayerDidRemoveAudioTrack(_ track: WebCore.AudioTrackPrivate) {
        Messages.MediaPlayerPrivateRemote.sendRemoveRemoteAudioTrack(webProcessConnection, destinationID, track.id())
        tracks.removeAudioTrack(track.id())
    }

    @MainActor
    fileprivate func mediaPlayerDidRemoveVideoTrack(_ track: WebCore.VideoTrackPrivate) {
        Messages.MediaPlayerPrivateRemote.sendRemoveRemoteVideoTrack(webProcessConnection, destinationID, track.id())
        tracks.removeVideoTrack(track.id())
    }

    @MainActor
    fileprivate func mediaPlayerDidRemoveTextTrack(_ track: WebCore.InbandTextTrackPrivate) {
        Messages.MediaPlayerPrivateRemote.sendRemoveRemoteTextTrack(webProcessConnection, destinationID, track.id())
        tracks.removeTextTrack(track.id())
    }

    @MainActor
    func audioTrackSetEnabled(connection _: IPC.Connection, trackId: UInt64, enabled: Bool) {
        tracks.setAudioTrackEnabled(trackId, enabled)
    }

    @MainActor
    func videoTrackSetSelected(connection _: IPC.Connection, trackId: UInt64, selected: Bool) {
        tracks.setVideoTrackSelected(trackId, selected)
    }

    @MainActor
    func textTrackSetMode(connection _: IPC.Connection, trackId: UInt64, mode ipcValue: IPCTypes.InbandTextTrackPrivateMode) {
        guard let mode = WebCore.InbandTextTrackPrivateMode(rawValue: ipcValue.rawValue) else {
            return
        }
        tracks.setTextTrackMode(trackId, mode)
    }
}

// The proxy's media player's client: its callbacks, for the proxy while it lives. The proxy's
// SwiftMediaPlayerClientAdapter owns it, and it holds the proxy weakly.
final class RemoteMediaPlayerClient: MediaPlayerClientDelegate {
    // Set as soon as the proxy is adopted, before it receives any message.
    fileprivate var proxy = WebKit.RemoteMediaPlayerProxy.WeakRemoteMediaPlayerProxy()

    func mediaPlayerNetworkStateChanged() {
        proxy.get()?.mediaPlayerNetworkStateChanged()
    }

    func mediaPlayerReadyStateChanged() {
        proxy.get()?.mediaPlayerReadyStateChanged()
    }

    func mediaPlayerVolumeChanged() {
        proxy.get()?.mediaPlayerVolumeChanged()
    }

    func mediaPlayerMuteChanged() {
        proxy.get()?.mediaPlayerMuteChanged()
    }

    func mediaPlayerTimeChanged() {
        proxy.get()?.mediaPlayerTimeChanged()
    }

    func mediaPlayerDurationChanged() {
        proxy.get()?.mediaPlayerDurationChanged()
    }

    func mediaPlayerRateChanged() {
        proxy.get()?.mediaPlayerRateChanged()
    }

    func mediaPlayerPlaybackStateChanged() {
        proxy.get()?.mediaPlayerPlaybackStateChanged()
    }

    func mediaPlayerResourceNotSupported() {
        proxy.get()?.mediaPlayerResourceNotSupported()
    }

    func mediaPlayerSizeChanged() {
        proxy.get()?.mediaPlayerSizeChanged()
    }

    func mediaPlayerFirstVideoFrameAvailable() {
        proxy.get()?.mediaPlayerFirstVideoFrameAvailable()
    }

    func mediaPlayerCharacteristicChanged() {
        proxy.get()?.mediaPlayerCharacteristicChanged()
    }

    func mediaPlayerRenderingModeChanged() {
        proxy.get()?.mediaPlayerRenderingModeChanged()
    }

    func mediaPlayerEngineFailedToLoad() {
        proxy.get()?.mediaPlayerEngineFailedToLoad()
    }

    func mediaPlayerBufferedTimeRangesChanged() {
        proxy.get()?.mediaPlayerBufferedTimeRangesChanged()
    }

    func mediaPlayerSeekableTimeRangesChanged() {
        proxy.get()?.mediaPlayerSeekableTimeRangesChanged()
    }

    func mediaPlayerVideoLayerSize() -> WebCore.FloatSize {
        proxy.get()?.mediaPlayerVideoLayerSize() ?? WebCore.FloatSize()
    }

    func mediaPlayerReferrer() -> WTF.String {
        proxy.get()?.referrer ?? WTF.String()
    }

    func mediaPlayerUserAgent() -> WTF.String {
        proxy.get()?.userAgent ?? WTF.String()
    }

    func mediaPlayerSourceApplicationIdentifier() -> WTF.String {
        proxy.get()?.sourceApplicationIdentifier ?? WTF.String()
    }

    func audioOutputDeviceId() -> WTF.String {
        proxy.get()?.audioOutputDeviceId ?? WTF.String()
    }

    func mediaPlayerMediaCacheDirectory() -> WTF.String? {
        proxy.get()?.gpuConnection?.mediaCacheDirectory()
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA || ENABLE_ENCRYPTED_MEDIA
    func mediaPlayerMediaKeysStorageDirectory() -> WTF.String? {
        proxy.get()?.gpuConnection?.mediaKeysStorageDirectory()
    }
    #endif

    @MainActor
    func mediaPlayerDidAddAudioTrack(_ track: WebCore.AudioTrackPrivate) {
        proxy.get()?.mediaPlayerDidAddAudioTrack(track)
    }

    @MainActor
    func mediaPlayerDidRemoveAudioTrack(_ track: WebCore.AudioTrackPrivate) {
        proxy.get()?.mediaPlayerDidRemoveAudioTrack(track)
    }

    @MainActor
    func mediaPlayerDidAddVideoTrack(_ track: WebCore.VideoTrackPrivate) {
        proxy.get()?.mediaPlayerDidAddVideoTrack(track)
    }

    @MainActor
    func mediaPlayerDidRemoveVideoTrack(_ track: WebCore.VideoTrackPrivate) {
        proxy.get()?.mediaPlayerDidRemoveVideoTrack(track)
    }

    @MainActor
    func mediaPlayerDidAddTextTrack(_ track: WebCore.InbandTextTrackPrivate) {
        proxy.get()?.mediaPlayerDidAddTextTrack(track)
    }

    @MainActor
    func mediaPlayerDidRemoveTextTrack(_ track: WebCore.InbandTextTrackPrivate) {
        proxy.get()?.mediaPlayerDidRemoveTextTrack(track)
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    func mediaPlayerKeyNeeded(_ message: WebCore.SharedBuffer) {
        proxy.get()?.mediaPlayerKeyNeeded(message)
    }
    #endif

    #if ENABLE_ENCRYPTED_MEDIA
    func mediaPlayerWaitingForKeyChanged() {
        proxy.get()?.mediaPlayerWaitingForKeyChanged()
    }
    #endif

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    func mediaPlayerCurrentPlaybackTargetIsWirelessChanged(_ isCurrentPlaybackTargetWireless: Bool) {
        proxy.get()?.mediaPlayerCurrentPlaybackTargetIsWirelessChanged(isCurrentPlaybackTargetWireless)
    }

    func playbackTargetType() -> WebCore.MediaPlaybackTargetType {
        #if WTF_PLATFORM_IOS_FAMILY
        proxy.get()?.playbackTargetType() ?? .None
        #else
        .None
        #endif
    }
    #endif
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT
