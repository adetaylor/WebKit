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

import WebKit_Internal

private let lessFrequentTimeupdateEventInterval = 2.0
private let moreFrequentTimeupdateEventInterval = 0.25

private let metricsAdvanceUpdate = 0.25

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
        m_videoContentScale = videoContentScale
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
    func prepareToPlay() {
        alwaysLog("prepareToPlay")
        player().prepareToPlay()
    }

    @cxx
    @implementation
    func prepareForRendering() {
        alwaysLog("prepareForRendering")
        player().prepareForRendering()
    }

    @cxx
    @implementation
    func cancelLoad() {
        stopUpdateCachedStateMessageTimer()
        player().cancelLoad()
    }

    @cxx
    @implementation
    func play() {
        let player = player()
        if player.movieLoadType() != .LiveStream {
            startUpdateCachedStateMessageTimer()
        }
        player.play()
        sendCachedState()
    }

    @cxx
    @implementation
    func pause() {
        stopUpdateCachedStateMessageTimer()
        updateCachedVideoMetrics()
        player().pause()
        sendCachedState()
    }

    @cxx
    @implementation
    func setRate(_ rate: Double) {
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

    @cxx
    @implementation
    func setBufferingPolicy(_ policy: WebCore.MediaPlayerBufferingPolicy) {
        player().setBufferingPolicy(policy)
    }

    @cxx
    @implementation
    func setPreload(_ preload: WebCore.MediaPlayerPreload) {
        player().setPreload(preload)
    }

    @cxx
    @implementation
    func setPrivateBrowsingMode(_ privateMode: Bool) {
        player().setPrivateBrowsingMode(privateMode)
    }

    @cxx
    @implementation
    func applicationWillResignActive() {
        player().applicationWillResignActive()
    }

    @cxx
    @implementation
    func applicationDidBecomeActive() {
        player().applicationDidBecomeActive()
    }

    // MARK: Audio

    @cxx
    @implementation
    func setVolume(_ volume: Double) {
        player().setVolume(volume)
        #if ENABLE_WEB_AUDIO
        setAudioSourceProviderVolume(volume)
        #endif
    }

    @cxx
    @implementation
    func setPreservesPitch(_ preservesPitch: Bool) {
        player().setPreservesPitch(preservesPitch)
        #if ENABLE_WEB_AUDIO
        setAudioSourceProviderPreservesPitch(preservesPitch)
        #endif
    }

    @cxx
    @implementation
    func setVolumeLocked(_ volumeLocked: Bool) {
        player().setVolumeLocked(volumeLocked)
    }

    @cxx
    @implementation
    func setMuted(_ muted: Bool) {
        player().setMuted(muted)
    }

    @cxx
    @implementation
    func setPitchCorrectionAlgorithm(_ algorithm: WebCore.MediaPlayerPitchCorrectionAlgorithm) {
        player().setPitchCorrectionAlgorithm(algorithm)
    }

    @cxx
    @implementation
    func audioOutputDeviceChanged(_ deviceId: WTF.String) {
        m_configuration.audioOutputDeviceId = deviceId
        player().audioOutputDeviceChanged()

        #if WTF_PLATFORM_IOS_FAMILY && USE_AUDIO_SESSION
        setPreferredSpeakerID()
        #endif
    }

    @cxx
    @implementation
    func setSoundStageSize(_ size: WebCore.MediaPlayerSoundStageSize) {
        if m_soundStageSize == size {
            return
        }
        m_soundStageSize = size

        player().soundStageSizeDidChange()
    }

    #if HAVE_SPATIAL_TRACKING_LABEL
    @cxx
    @implementation
    func setDefaultSpatialTrackingLabel(_ defaultSpatialTrackingLabel: WTF.String) {
        player().setDefaultSpatialTrackingLabel(defaultSpatialTrackingLabel)
    }

    @cxx
    @implementation
    func setSpatialTrackingLabel(_ spatialTrackingLabel: WTF.String) {
        player().setSpatialTrackingLabel(spatialTrackingLabel)
    }
    #endif

    #if HAVE_SPATIAL_AUDIO_EXPERIENCE
    @cxx
    @implementation
    func setPrefersSpatialAudioExperience(_ value: Bool) {
        player().setPrefersSpatialAudioExperience(value)
    }
    #endif

    // MARK: Presentation

    @cxx
    @implementation
    func setPresentationSize(_ size: WebCore.IntSize) {
        if size.width() == m_configuration.presentationSize.width() && size.height() == m_configuration.presentationSize.height() {
            return
        }

        m_configuration.presentationSize = size
        player().setPresentationSize(size)
    }

    @cxx
    @implementation
    func setPageIsVisible(_ visible: Bool) {
        alwaysLog("setPageIsVisible", "\(visible)")
        player().setPageIsVisible(visible)
    }

    @cxx
    @implementation
    func setViewportVisibility(_ visibility: WebCore.MediaPlayerViewportVisibility) {
        alwaysLog("setViewportVisibility", "\(visibility.rawValue)")
        player().setViewportVisibility(visibility)
    }

    @cxx
    @implementation
    func acceleratedRenderingStateChanged(_ renderingCanBeAccelerated: Bool) {
        alwaysLog("acceleratedRenderingStateChanged", "\(renderingCanBeAccelerated)")
        m_renderingCanBeAccelerated = renderingCanBeAccelerated
        player().acceleratedRenderingStateChanged()
    }

    @cxx
    @implementation
    func playerContentBoxRectChanged(_ contentRect: WebCore.LayoutRect) {
        if m_playerContentBoxRect == contentRect {
            return
        }

        m_playerContentBoxRect = contentRect

        player().playerContentBoxRectChanged(contentRect)
    }

    @cxx
    @implementation
    func setShouldMaintainAspectRatio(_ maintainRatio: Bool) {
        player().setShouldMaintainAspectRatio(maintainRatio)
    }

    @cxx
    @implementation
    func setShouldDisableSleep(_ disable: Bool) {
        player().setShouldDisableSleep(disable)
    }

    @cxx
    @implementation
    func setShouldDisableHDR(_ shouldDisable: Bool) {
        if m_configuration.shouldDisableHDR == shouldDisable {
            return
        }

        m_configuration.shouldDisableHDR = shouldDisable
        player().setShouldDisableHDR(shouldDisable)
    }

    @cxx
    @implementation
    func setPreferredDynamicRangeMode(_ mode: WebCore.DynamicRangeMode) {
        player().setPreferredDynamicRangeMode(mode)
    }

    @cxx
    @implementation
    func setPlatformDynamicRangeLimit(_ platformDynamicRangeLimit: WebCore.PlatformDynamicRangeLimit) {
        player().setPlatformDynamicRangeLimit(platformDynamicRangeLimit)
    }

    @cxx
    @implementation
    func setShouldCheckHardwareSupport(_ value: Bool) {
        player().setShouldCheckHardwareSupport(value)
        m_shouldCheckHardwareSupport = value
    }

    @cxx
    @implementation
    func isInFullscreenOrPictureInPictureChanged(_ isInFullscreenOrPictureInPicture: Bool) {
        player().setInFullscreenOrPictureInPicture(isInFullscreenOrPictureInPicture)
    }

    @cxx
    @implementation
    func startVideoFrameMetadataGathering() {
        player().startVideoFrameMetadataGathering()
    }

    @cxx
    @implementation
    func stopVideoFrameMetadataGathering() {
        player().stopVideoFrameMetadataGathering()
    }

    #if WTF_PLATFORM_MAC
    @cxx
    @implementation
    func screenReservedChanged(_ reserved: Bool) {
        player().setScreenReserved(reserved)
    }
    #endif

    #if ENABLE_VIDEO_PRESENTATION_MODE
    @cxx
    @implementation
    func updateVideoFullscreenInlineImage() {
        player().updateVideoFullscreenInlineImage()
    }

    @cxx
    @implementation
    func setVideoFullscreenMode(_ mode: UInt32) {
        m_fullscreenMode = mode
        player().setVideoFullscreenMode(mode)
    }

    @cxx
    @implementation
    func videoFullscreenStandbyChanged(_ standby: Bool) {
        m_videoFullscreenStandby = standby
        player().videoFullscreenStandbyChanged()
    }

    @cxx
    @implementation
    func setVideoFullscreenGravity(_ gravity: WebCore.MediaPlayerVideoGravity) {
        player().setVideoFullscreenGravity(gravity)
    }
    #endif

    // MARK: Tracks

    @cxx
    @implementation
    func notifyTrackModeChanged() {
        player().notifyTrackModeChanged()
    }

    @cxx
    @implementation
    func tracksChanged() {
        player().tracksChanged()
    }

    // MARK: Wireless playback

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    @cxx
    @implementation
    func setWirelessVideoPlaybackDisabled(_ disabled: Bool) {
        let player = player()
        player.setWirelessVideoPlaybackDisabled(disabled)
        m_cachedState.wirelessVideoPlaybackDisabled = player.wirelessVideoPlaybackDisabled()
        sendCachedState()
    }

    @cxx
    @implementation
    func setShouldPlayToPlaybackTarget(_ shouldPlay: Bool) {
        player().setShouldPlayToPlaybackTarget(shouldPlay)
    }
    #endif

    // MARK: Keys

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    @cxx
    @implementation
    func keyAdded() {
        player().keyAdded()
    }
    #endif

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA && ENABLE_ENCRYPTED_MEDIA
    @cxx
    @implementation
    func setShouldContinueAfterKeyNeeded(_ should: Bool) {
        player().setShouldContinueAfterKeyNeeded(should)
    }
    #endif

    // MARK: Cached state

    @cxx
    @implementation
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

    @cxx
    @implementation
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

    @cxx
    @implementation
    func sendCachedState() {
        updateCachedState(false)
        Messages.MediaPlayerPrivateRemote.sendUpdateCachedState(webProcessConnection, destinationID, m_cachedState)
        clearCachedBufferedRanges()
    }

    @cxx
    @implementation
    func updateCachedMediaCharacteristics() {
        let player = player()
        m_cachedState.hasAudio = player.hasAudio()
        m_cachedState.hasVideo = player.hasVideo()
        m_cachedState.videoFrameHasAlpha = player.videoFrameHasAlpha()
        m_cachedState.hasClosedCaptions = player.hasClosedCaptions()
        m_cachedState.languageOfPrimaryAudioTrack = player.languageOfPrimaryAudioTrack()
    }

    // MARK: Video playback quality metrics

    @cxx
    @implementation
    func setVideoPlaybackMetricsUpdateInterval(_ interval: Double) {
        alwaysLog("setVideoPlaybackMetricsUpdateInterval", "\(interval)")

        updateCachedVideoMetrics()
        m_videoPlaybackMetricsUpdateInterval = interval
        m_nextPlaybackQualityMetricsUpdateTime = ProcessInfo.processInfo.systemUptime + interval - metricsAdvanceUpdate
    }

    @cxx
    @implementation
    func maybeUpdateCachedVideoMetrics() {
        if m_cachedState.paused || m_videoPlaybackMetricsUpdateInterval == 0 || ProcessInfo.processInfo.systemUptime < m_nextPlaybackQualityMetricsUpdateTime || m_hasPlaybackMetricsUpdatePending {
            return
        }

        updateCachedVideoMetrics()
    }

    @cxx
    @implementation
    func updateCachedVideoMetrics() {
        alwaysLog("updateCachedVideoMetrics")
        m_nextPlaybackQualityMetricsUpdateTime = ProcessInfo.processInfo.systemUptime + m_videoPlaybackMetricsUpdateInterval
        if m_hasPlaybackMetricsUpdatePending {
            return
        }
        m_hasPlaybackMetricsUpdatePending = true
        requestVideoPlaybackQualityMetrics()
    }

    // MARK: MediaPlayerClient

    @cxx
    @implementation
    func mediaPlayerNetworkStateChanged() {
        updateCachedState(true)
        m_cachedState.networkState = player().networkState()
        Messages.MediaPlayerPrivateRemote.sendNetworkStateChanged(webProcessConnection, destinationID, m_cachedState)
    }

    @cxx
    @implementation
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
        cacheDocumentIsCrossOrigin()

        Messages.MediaPlayerPrivateRemote.sendReadyStateChanged(webProcessConnection, destinationID, m_cachedState, newReadyState)
    }

    @cxx
    @implementation
    func mediaPlayerVolumeChanged() {
        Messages.MediaPlayerPrivateRemote.sendVolumeChanged(webProcessConnection, destinationID, player().volume())
    }

    @cxx
    @implementation
    func mediaPlayerMuteChanged() {
        Messages.MediaPlayerPrivateRemote.sendMuteChanged(webProcessConnection, destinationID, player().muted())
    }

    @cxx
    @implementation
    func mediaPlayerTimeChanged() {
        updateCachedState(true)

        let player = player()
        m_cachedState.duration = player.duration()
        Messages.MediaPlayerPrivateRemote.sendTimeChanged(webProcessConnection, destinationID, m_cachedState, timeUpdateData(player, player.currentTime()))
    }

    @cxx
    @implementation
    func mediaPlayerDurationChanged() {
        updateCachedState(true)
        m_cachedState.duration = player().duration()
        Messages.MediaPlayerPrivateRemote.sendDurationChanged(webProcessConnection, destinationID, m_cachedState)
    }

    @cxx
    @implementation
    func mediaPlayerPlaybackStateChanged() {
        let player = player()
        m_cachedState.paused = player.paused()
        Messages.MediaPlayerPrivateRemote.sendPlaybackStateChanged(webProcessConnection, destinationID, m_cachedState.paused, timeUpdateData(player, player.currentTime()))
    }

    @cxx
    @implementation
    func mediaPlayerRateChanged() {
        updateCachedVideoMetrics()
        sendCachedState()

        let player = player()
        let effectiveRate = player.effectiveRate()

        #if ENABLE_WEB_AUDIO
        setAudioSourceProviderPlaybackRate(effectiveRate)
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

    @cxx
    @implementation
    func mediaPlayerEngineFailedToLoad() {
        Messages.MediaPlayerPrivateRemote.sendEngineFailedToLoad(webProcessConnection, destinationID, Int64(player().platformErrorCode()))
    }

    @cxx
    @implementation
    func mediaPlayerResourceNotSupported() {
        Messages.MediaPlayerPrivateRemote.sendResourceNotSupported(webProcessConnection, destinationID)
    }

    @cxx
    @implementation
    func mediaPlayerSizeChanged() {
        m_cachedState.naturalSize = player().naturalSize()
        Messages.MediaPlayerPrivateRemote.sendSizeChanged(webProcessConnection, destinationID, m_cachedState.naturalSize)
    }

    @cxx
    @implementation
    func mediaPlayerCharacteristicChanged() {
        updateCachedVideoMetrics()
        updateCachedState(false)
        updateCachedMediaCharacteristics()

        Messages.MediaPlayerPrivateRemote.sendCharacteristicChanged(webProcessConnection, destinationID, m_cachedState)
    }

    @cxx
    @implementation
    func mediaPlayerBufferedTimeRangesChanged() {
        m_bufferedChanged = true
    }

    @cxx
    @implementation
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

    #if ENABLE_ENCRYPTED_MEDIA
    @cxx
    @implementation
    func mediaPlayerWaitingForKeyChanged() {
        Messages.MediaPlayerPrivateRemote.sendWaitingForKeyChanged(webProcessConnection, destinationID, player().waitingForKey())
    }
    #endif

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    @cxx
    @implementation
    func mediaPlayerCurrentPlaybackTargetIsWirelessChanged(_ isCurrentPlaybackTargetWireless: Bool) {
        let player = player()
        m_cachedState.wirelessPlaybackTargetName = player.wirelessPlaybackTargetName()
        m_cachedState.wirelessPlaybackRouteName = player.wirelessPlaybackRouteName()
        m_cachedState.wirelessPlaybackTargetType = player.wirelessPlaybackTargetType()
        sendCachedState()
        Messages.MediaPlayerPrivateRemote.sendCurrentPlaybackTargetIsWirelessChanged(webProcessConnection, destinationID, isCurrentPlaybackTargetWireless)
    }
    #endif

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
        let identifier = Swift.String(logIdentifierForSwift(), radix: 16, uppercase: true)
        let suffix = values()
        let message = "RemoteMediaPlayerProxy::\(function)(\(identifier))" + (suffix.isEmpty ? "" : " \(suffix)")
        logAlways(WTF.String(message))
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT
