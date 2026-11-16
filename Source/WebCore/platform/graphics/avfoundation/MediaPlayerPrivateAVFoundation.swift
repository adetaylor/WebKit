// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
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

// The AVFoundation player's readiness state machine: the network and ready states that the asset's and the player
// item's status give, page and viewport visibility, whether a seek is in flight, the media's characteristics and size,
// the step from metadata to playback, and what the media player is told of each; and what it asks of the asset and the
// player item: the asset's status from its loaded keys, whether its tracks are playable or some are disabled, whether
// it is a stream with variants, its start date, its size in bytes, and whether its media selection groups have loaded;
// and the AVPlayer's muting, audibility, sleep, tone mapping and external playback settings, given to it when it is
// made and when they change, and the kind of external playback it is in.
// MediaPlayerPrivateAVFoundation.cpp keeps the loads, the rendering set-up, the seek promise and the pending seek, the
// text tracks, the media player's callbacks, the cached times and the getters the media element calls most often;
// objc/MediaPlayerPrivateAVFoundationObjC.mm keeps the AVFoundation objects, the asset's cached status, the status of
// the asset's keys with their errors, the codec policy each track is held to, the volume, rate and pitch (which the
// audio source provider also takes), the dynamic range, the playback target and the keys.
//
// WebCore soft-links AVFoundation and CoreMedia: their classes and functions come from the generated accessors, and no
// AVFoundation class is used where its class object would be needed.
//
// Threads: the main thread.

internal import AVFoundation
internal import CoreMedia
internal import QuartzCore
import WebCore_Private.Core.MediaPlayerPrivateAVFoundation
import WebCore_Private.Core.MediaPlayerPrivateAVFoundationObjC

// MediaPlayerPrivateAVFoundation::AssetStatus and ItemStatus, whose values MediaPlayerPrivateAVFoundation.cpp checks.
private let assetStatusDoesNotExist: UInt8 = 0
private let assetStatusLoading: UInt8 = 2
private let assetStatusFailed: UInt8 = 3
private let assetStatusCancelled: UInt8 = 4
private let assetStatusNetworkError: UInt8 = 5
private let assetStatusLoaded: UInt8 = 6
private let assetStatusPlayable: UInt8 = 7
private let itemStatusUnknown: UInt8 = 1
private let itemStatusFailed: UInt8 = 2
private let itemStatusReadyToPlay: UInt8 = 3
private let itemStatusPlaybackBufferEmpty: UInt8 = 4
private let itemStatusPlaybackBufferFull: UInt8 = 5
private let itemStatusPlaybackLikelyToKeepUp: UInt8 = 6

// MediaTime::invalidTime() and zeroTime(), made as MediaTime.cpp makes them (the flags are MediaTime::Valid or none).
private var invalidMediaTime: WTF.MediaTime {
    WTF.MediaTime(-1, 1, 0)
}

private var zeroMediaTime: WTF.MediaTime {
    WTF.MediaTime(0, 1, 1)
}

private func isAtLeast(_ state: WebCore.MediaPlayerReadyState, _ other: WebCore.MediaPlayerReadyState) -> Bool {
    state.rawValue >= other.rawValue
}

private func name(of state: WebCore.MediaPlayerNetworkState) -> Swift.String {
    switch state {
    case .Empty: "Empty"
    case .Idle: "Idle"
    case .Loading: "Loading"
    case .Loaded: "Loaded"
    case .FormatError: "FormatError"
    case .NetworkError: "NetworkError"
    case .DecodeError: "DecodeError"
    @unknown default: "\(state.rawValue)"
    }
}

private func name(of state: WebCore.MediaPlayerReadyState) -> Swift.String {
    switch state {
    case .HaveNothing: "HaveNothing"
    case .HaveMetadata: "HaveMetadata"
    case .HaveCurrentData: "HaveCurrentData"
    case .HaveFutureData: "HaveFutureData"
    case .HaveEnoughData: "HaveEnoughData"
    @unknown default: "\(state.rawValue)"
    }
}

private func name(of visibility: WebCore.MediaPlayerViewportVisibility) -> Swift.String {
    switch visibility {
    case .NotVisible: "NotVisible"
    case .IntersectingViewport: "IntersectingViewport"
    case .VisibleInViewport: "VisibleInViewport"
    case .VisibleInFullscreen: "VisibleInFullscreen"
    case .VisibleInPictureInPicture: "VisibleInPictureInPicture"
    @unknown default: "\(visibility.rawValue)"
    }
}

// A number as WTF's logging prints it: no fraction when it is whole.
private func number<Value: BinaryFloatingPoint>(_ value: Value) -> Swift.String {
    let double = Double(value)
    if double.isFinite && double == double.rounded() && abs(double) < 1e15 {
        return "\(Int64(double))"
    }
    return "\(double)"
}

extension WebCore.MediaPlayerPrivateAVFoundation {
    fileprivate func logMessage(_ level: WebCore.MediaPlayerAVFoundationLogLevel, _ message: @autoclosure () -> Swift.String) {
        guard willLogFromSwift(level) else {
            return
        }
        let bytes = ContiguousArray(message().utf8)
        logFromSwift(level, bytes.span)
    }

    // hasAudio(), which the base class declares protected: a derived class's extension can't reach that declaration.
    fileprivate func hasAudioFromSwift() -> Bool {
        hasAudio()
    }

    // hasVideo() and readyState(), for the same reason.
    fileprivate func hasVideoFromSwift() -> Bool {
        hasVideo()
    }

    fileprivate func readyStateFromSwift() -> WebCore.MediaPlayerReadyState {
        readyState()
    }

    // MARK: Visibility and aspect ratio

    @cxx
    @implementation
    func setShouldMaintainAspectRatio(_ maintainAspectRatio: Bool) {
        if maintainAspectRatio == m_shouldMaintainAspectRatio {
            return
        }

        m_shouldMaintainAspectRatio = maintainAspectRatio
        updateVideoLayerGravity()
    }

    @cxx
    @implementation
    func setPageIsVisible(_ visible: Bool) {
        if m_pageIsVisible == visible {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundation::setPageIsVisible \(visible)")

        m_pageIsVisible = visible
        if visible {
            setUpVideoRendering()
        }

        platformPageIsVisibleChanged(visible)
    }

    @cxx
    @implementation
    func setViewportVisibility(_ visibility: WebCore.MediaPlayerViewportVisibility) {
        if m_viewportVisibility == visibility {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundation::setViewportVisibility \(name(of: visibility))")
        m_viewportVisibility = visibility
        platformViewportVisibilityChanged(visibility)
    }

    // MARK: Playback

    @cxx
    @implementation
    func playabilityKnown() {
        logMessage(.Info, "MediaPlayerPrivateAVFoundation::playabilityKnown metadata loaded = \(assetStatus().rawValue > assetStatusLoading)")

        if m_assetIsPlayable {
            return
        }

        // Nothing more to do if we already have all of the item's metadata.
        if assetStatus().rawValue > assetStatusLoading {
            return
        }

        // At this point we are supposed to load metadata. It is OK to ask the asset to load the same
        // information multiple times, because if it has already been loaded the completion handler
        // will just be called synchronously.
        m_loadingMetadata = true
        beginLoadingMetadata()
    }

    @cxx
    @implementation
    func play() {
        logMessage(.Always, "MediaPlayerPrivateAVFoundation::play")
        platformPlay()
    }

    @cxx
    @implementation
    func pause() {
        logMessage(.Always, "MediaPlayerPrivateAVFoundation::pause")
        platformPause()
    }

    @cxx
    @implementation
    func seekCompleted(_ finished: Bool) {
        logMessage(.Always, "MediaPlayerPrivateAVFoundation::seekCompleted finished = \(finished)")

        m_seeking = false

        if runPendingSeek() {
            return
        }

        if !finished {
            return
        }

        endSeekingCurrentTextTrack()

        updateStates()

        resolveSeekPromiseIfNeeded()
    }

    @cxx
    @implementation
    func didEnd(_ now: Double) {
        // Hang onto the current time and use it as duration from now on since we are definitely at
        // the end of the movie. Do this because the initial duration is sometimes an estimate.
        // Never do this for a live stream: its duration is unbounded (positive infinity), and
        // demoting it to a finite value here would make endedPlayback() treat reaching the live
        // edge as the end of the media and fire a spurious 'ended' event.
        let isLiveStream = isLiveStream()
        logMessage(.Always, "MediaPlayerPrivateAVFoundation::didEnd currentTime: \(number(now)), seeking: \(m_seeking), isLiveStream: \(isLiveStream)")
        if now > 0 && !m_seeking && !isLiveStream {
            logMessage(.Always, "MediaPlayerPrivateAVFoundation::didEnd Updating cached duration to \(number(now))")
            m_cachedDuration = WTF.MediaTime.createWithDouble(now)
        }

        updateStates()
        notifyMediaPlayer(.TimeChanged)
    }

    @cxx
    @implementation
    func rateChanged() {
        notifyMediaPlayer(.RateChanged)
    }

    // MARK: Times and ranges

    @cxx
    @implementation
    func invalidateCachedDuration() {
        m_cachedDuration = invalidMediaTime
    }

    @cxx
    @implementation
    func loadedTimeRangesChanged() {
        m_cachedMaxTimeLoaded = zeroMediaTime
        invalidateCachedDuration()
        notifyMediaPlayer(.BufferedTimeRangesChanged)
    }

    @cxx
    @implementation
    func seekableTimeRangesChanged() {
        m_cachedMaxTimeSeekable = zeroMediaTime
        m_cachedMinTimeSeekable = zeroMediaTime
        notifyMediaPlayer(.SeekableTimeRangesChanged)
    }

    // MARK: Characteristics and size

    @cxx
    @implementation
    func setNaturalSize(_ size: WebCore.FloatSize) {
        let oldWidth = m_cachedNaturalSize.width()
        let oldHeight = m_cachedNaturalSize.height()
        m_cachedNaturalSize = size
        if oldWidth != size.width() || oldHeight != size.height() {
            logMessage(.Info, "MediaPlayerPrivateAVFoundation::setNaturalSize was \(number(oldWidth)) x \(number(oldHeight)), is \(number(size.width())) x \(number(size.height()))")
            notifyMediaPlayer(.SizeChanged)
        }
    }

    @cxx
    @implementation
    func setHasVideo(_ hasVideo: Bool) {
        if m_cachedHasVideo == hasVideo {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundation::setHasVideo \(hasVideo)")
        m_cachedHasVideo = hasVideo
        characteristicsChanged()
        updateIsAudible()
    }

    @cxx
    @implementation
    func setHasAudio(_ hasAudio: Bool) {
        if m_cachedHasAudio == hasAudio {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundation::setHasAudio \(hasAudio)")
        m_cachedHasAudio = hasAudio
        characteristicsChanged()
        updateIsAudible()
    }

    @cxx
    @implementation
    func setHasClosedCaptions(_ hasClosedCaptions: Bool) {
        if m_cachedHasCaptions != hasClosedCaptions {
            m_cachedHasCaptions = hasClosedCaptions
            characteristicsChanged()
        }
    }

    @cxx
    @implementation
    func characteristicsChanged() {
        if m_delayCharacteristicsChangedNotification != 0 {
            m_characteristicsChanged = true
            return
        }

        m_characteristicsChanged = false
        notifyMediaPlayer(.CharacteristicChanged)
    }

    @cxx
    @implementation
    func setDelayCharacteristicsChangedNotification(_ delay: Bool) {
        if delay {
            m_delayCharacteristicsChangedNotification += 1
            return
        }

        assert(m_delayCharacteristicsChangedNotification > 0)
        m_delayCharacteristicsChangedNotification -= 1
        if m_delayCharacteristicsChangedNotification == 0 && m_characteristicsChanged {
            characteristicsChanged()
        }
    }

    @cxx
    @implementation
    func metadataLoaded() {
        m_loadingMetadata = false
        resolvedURLChanged()
        tracksChanged()
    }

    // MARK: Network and ready states

    @cxx
    @implementation
    func setNetworkState(_ state: WebCore.MediaPlayerNetworkState) {
        if state == m_networkState {
            return
        }

        m_networkState = state
        notifyMediaPlayer(.NetworkStateChanged)
    }

    @cxx
    @implementation
    func setReadyState(_ state: WebCore.MediaPlayerReadyState) {
        if state == m_readyState {
            return
        }

        let oldState = m_readyState
        m_readyState = state
        resolveSeekPromiseIfNeeded()
        notifyMediaPlayer(.ReadyStateChanged)

        updateIsAudible()

        if isAtLeast(oldState, .HaveMetadata) {
            return
        }

        // Many state methods in MediaPlayerPrivateAVFoundation will return defaults
        // if queried before reaching HaveMetadata. Re-fire their changed events after
        // the ready state moves beyond HaveMetadata so the correct values are reflected
        // upwards to clients.
        if !m_cachedNaturalSize.isEmpty() {
            notifyMediaPlayer(.SizeChanged)
        }
    }

    @cxx
    @implementation
    func updateReadiness() {
        var newNetworkState = m_networkState
        var newReadyState = m_readyState
        var firstVideoFrameBecomeAvailable = false

        if m_loadingMetadata {
            newNetworkState = .Loading
        } else {
            // -loadValuesAsynchronouslyForKeys:completionHandler: has invoked its handler; test status of keys and determine state.
            let assetStatus = self.assetStatus().rawValue
            let itemStatus = playerItemStatus().rawValue

            m_assetIsPlayable = assetStatus == assetStatusPlayable
            if !isAtLeast(m_readyState, .HaveMetadata) && assetStatus > assetStatusLoading {
                if m_assetIsPlayable {
                    if assetStatus >= assetStatusLoaded {
                        newReadyState = .HaveMetadata
                    }
                    if itemStatus <= itemStatusUnknown {
                        if assetStatus == assetStatusFailed || m_preload.rawValue > WebCore.MediaPlayerPreload.MetaData.rawValue || isLiveStream() {
                            // The asset is playable but doesn't support inspection prior to playback (eg. streaming files),
                            // or we are supposed to prepare for playback immediately, so create the player item now.
                            newNetworkState = .Loading
                            prepareToPlay()
                        } else {
                            newNetworkState = .Idle
                        }
                    }
                } else {
                    newNetworkState = assetStatus == assetStatusNetworkError ? .NetworkError : .FormatError
                }
            }

            if !hasAvailableVideoFrame() {
                m_haveReportedFirstVideoFrame = false
            } else if !m_haveReportedFirstVideoFrame && m_cachedHasVideo {
                m_haveReportedFirstVideoFrame = true
                firstVideoFrameBecomeAvailable = true
            }

            if assetStatus >= assetStatusLoaded && itemStatus > itemStatusUnknown {
                switch itemStatus {
                case itemStatusPlaybackLikelyToKeepUp, itemStatusPlaybackBufferFull:
                    // If the status becomes PlaybackBufferFull, loading stops and the status will not
                    // progress to LikelyToKeepUp. Set the readyState to HAVE_ENOUGH_DATA, on the
                    // presumption that if the playback buffer is full, playback will probably not stall.
                    newReadyState = .HaveEnoughData
                case itemStatusReadyToPlay:
                    if m_readyState != .HaveEnoughData && (!m_cachedHasVideo || m_haveReportedFirstVideoFrame) && hasLoadedBeyondCurrentTime() {
                        newReadyState = .HaveFutureData
                    }
                case itemStatusPlaybackBufferEmpty:
                    newReadyState = .HaveCurrentData
                default:
                    break
                }

                if itemStatus == itemStatusPlaybackBufferFull {
                    newNetworkState = .Idle
                } else if itemStatus == itemStatusFailed {
                    newNetworkState = .DecodeError
                } else if itemStatus >= itemStatusReadyToPlay {
                    newNetworkState = hasLoadedToDuration() ? .Loaded : .Loading
                }
            }
        }

        if firstVideoFrameBecomeAvailable {
            if !isAtLeast(m_readyState, .HaveCurrentData) {
                newReadyState = .HaveCurrentData
            }
            notifyMediaPlayer(.FirstVideoFrameAvailable)
        }

        if m_networkState != newNetworkState {
            logMessage(.Always, "MediaPlayerPrivateAVFoundation::updateStates entered with networkState \(name(of: m_networkState)), exiting with \(name(of: newNetworkState))")
        }
        if m_readyState != newReadyState {
            logMessage(.Always, "MediaPlayerPrivateAVFoundation::updateStates entered with readyState \(name(of: m_readyState)), exiting with \(name(of: newReadyState))")
        }

        setNetworkState(newNetworkState)
        setReadyState(newReadyState)

        if isReadyForVideoSetup() && currentRenderingMode() != preferredRenderingMode() {
            setUpVideoRendering()
        }
    }
}

// AVErrorServerIncorrectlyConfigured (static_assert in objc/MediaPlayerPrivateAVFoundationObjC.mm).
private let avErrorServerIncorrectlyConfigured = -11850

// The asset's and its tracks' synchronous accessors, which AVFoundation deprecates in favour of asynchronous loading.
// They don't block: the C++ player loads these keys first (beginLoadingMetadata()), and asks only once they have loaded.
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the readiness state machine asks once the asset's keys have loaded")
#endif
private func keyStatus(of asset: AVAsset, _ key: Swift.String, _ error: inout NSError?) -> KeyStatus {
    // AVFoundation writes the error, if any, through the autoreleasing pointer to the local it is given.
    switch unsafe asset.statusOfValue(forKey: key, error: &error) {
    case .loaded: .loaded
    case .failed: .failed
    case .cancelled: .cancelled
    default: .notLoaded
    }
}

// AVKeyValueStatus, as the asset status reads it.
private enum KeyStatus {
    case notLoaded
    case loaded
    case failed
    case cancelled
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the readiness state machine asks once the asset's keys have loaded")
#endif
func hasLoaded(_ asset: AVAsset, _ key: Swift.String) -> Bool {
    // A null error pointer: AVFoundation writes no error.
    unsafe asset.statusOfValue(forKey: key, error: nil) == .loaded
}

// A streaming track the item plays as one of the asset's media selection groups' options.
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the asset's media selection groups have loaded")
#endif
private func belongsToSelectionGroup(_ track: AVAssetTrack, of asset: AVAsset) -> Bool {
    for characteristic in [AVFoundationSoftLink.AVMediaCharacteristicAudible, AVFoundationSoftLink.AVMediaCharacteristicVisual, AVFoundationSoftLink.AVMediaCharacteristicLegible] {
        if track.hasMediaCharacteristic(characteristic), let _ = asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) {
            return true
        }
    }
    return false
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the readiness state machine asks once the asset's keys have loaded")
#endif
private func isEnabled(_ track: AVAssetTrack) -> Bool {
    track.isEnabled
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the readiness state machine asks once the asset's keys have loaded")
#endif
private func totalSampleDataLength(_ track: AVAssetTrack) -> Int64 {
    track.totalSampleDataLength
}

private func playerItemTracks(_ item: AVPlayerItem) -> NSArray {
    AVFoundationMember.tracks(of: item)?.tracks ?? NSArray()
}

private func assetTracks(_ asset: AVAsset) -> NSArray {
    AVFoundationMember.tracks(of: asset)?.tracks ?? NSArray()
}

private func assetTrack(of playerItemTrack: AVPlayerItemTrack) -> AVAssetTrack? {
    AVFoundationMember.assetTrack(of: playerItemTrack)?.assetTrack
}

extension WebCore.MediaPlayerPrivateAVFoundationObjC {
    private var core: MediaPlayerAVFoundationCore {
        MediaPlayerAVFoundationCore.registered(m_coreKey)
    }

    @cxx
    @implementation
    func attachAVObjectsToCore() {
        let core = core
        core.attachAsset(m_avAsset.get())
        if let player = m_avPlayer.get() {
            core.attachPlayer(player)
        }
        if let item = m_avPlayerItem.get() {
            core.attachItem(item)
        }
        core.attachVideoLayer(m_videoLayer.get())
    }

    @cxx
    @implementation
    func updateVideoLayerGravity(_ animated: Bool) {
        assert(WTF.isMainThread())
        guard let layer = m_videoLayer.get() else {
            return
        }

        var gravity = shouldMaintainAspectRatio() ? AVFoundationSoftLink.AVLayerVideoGravityResizeAspect : AVFoundationSoftLink.AVLayerVideoGravityResize
        if hasVideoFullscreenLayer() {
            // MediaPlayer::VideoGravity: Resize, ResizeAspect, ResizeAspectFill.
            switch m_videoFullscreenGravity.rawValue {
            case 0: gravity = AVFoundationSoftLink.AVLayerVideoGravityResize
            case 1: gravity = AVFoundationSoftLink.AVLayerVideoGravityResizeAspect
            default: gravity = AVFoundationSoftLink.AVLayerVideoGravityResizeAspectFill
            }
        }

        if layer.videoGravity == gravity {
            return
        }

        let disableActions = !animated
        logMessage(.Always, "MediaPlayerPrivateAVFoundationObjC::updateVideoLayerGravity Setting gravity to \"\(gravity.rawValue)\", animated: \(!disableActions)")

        CATransaction.begin()
        CATransaction.setDisableActions(disableActions)
        layer.videoGravity = gravity
        CATransaction.commit()

        syncTextTrackBounds()
    }

    @cxx
    @implementation
    func updateLayerAttachment() {
        assert(WTF.isMainThread())
        guard let layer = m_videoLayer.get(), let player = m_avPlayer.get() else {
            return
        }
        layer.player = shouldAttachLayerToPlayer() ? player : nil
    }

    @cxx
    @implementation
    func tracksDidChange() {
        let core = core
        var tracks: NSArray?
        if let reported = core.reportedTracks {
            let asset = m_avAsset.get()
            let assetTrackList = asset.map { assetTracks($0) } ?? NSArray()
            let groupsLoaded = hasLoadedMediaSelectionGroups()
            let kept = NSMutableArray()
            for element in reported {
                guard let playerItemTrack = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVPlayerItemTrack) else {
                    continue
                }
                let assetTrack = assetTrack(of: playerItemTrack)
                if let assetTrack, assetTrackList.contains(assetTrack) {
                    kept.add(playerItemTrack)
                    continue
                }
                if !groupsLoaded {
                    continue
                }
                if let assetTrack, let asset, belongsToSelectionGroup(assetTrack, of: asset) {
                    continue
                }
                kept.add(playerItemTrack)
            }
            tracks = kept
        }
        m_cachedTracks = .init(tracks as? [Any])
        core.observeEnabled(of: tracks)

        m_cachedTotalBytes = 0

        tracksChanged()
        updateStates()
    }

    @cxx
    @implementation
    func checkPlayability() {
        if m_haveCheckedPlayability {
            return
        }
        m_haveCheckedPlayability = true

        logMessage(.Info, "MediaPlayerPrivateAVFoundationObjC::checkPlayability")
        if let asset = m_avAsset.get() {
            core.loadPlayability(asset)
        }
    }

    @cxx
    @implementation
    override func beginLoadingMetadata() {
        logMessage(.Info, "MediaPlayerPrivateAVFoundationObjC::beginLoadingMetadata")
        core.loadMetadata()
    }

    @cxx
    @implementation
    func assetKeysStatus() -> WebCore.MediaPlayerPrivateAVFoundation.AssetStatus {
        guard let asset = m_avAsset.get() else {
            return .init(rawValue: assetStatusLoading)
        }
        var lastError: NSError?
        var status = assetStatusLoaded
        for key in assetMetadataKeys {
            var error: NSError?
            let keyStatus = keyStatus(of: asset, key, &error)
            if let error {
                logMessage(.Error, "MediaPlayerPrivateAVFoundationObjC::assetStatus failed for \(key), error = \(error)")
                lastError = error
            }
            if keyStatus == .notLoaded {
                // At least one key is not loaded yet.
                return .init(rawValue: assetStatusLoading)
            }
            if keyStatus == .failed {
                // At least one key could not be loaded.
                status = assetStatusFailed
                break
            }
            if keyStatus == .cancelled {
                // Loading of at least one key was cancelled.
                return .init(rawValue: assetStatusCancelled)
            }
        }
        if status == assetStatusFailed, let error = lastError,
            (error.domain == "AVFoundationErrorDomain" && error.code == avErrorServerIncorrectlyConfigured) || error.domain == "NSURLErrorDomain" {
            return .init(rawValue: assetStatusNetworkError)
        }
        return .init(rawValue: status)
    }

    // Answers assetStatus() until the asset's caches are all known, and fills them; Loaded once they are.
    @cxx
    @implementation
    func fillAssetStatusCaches() -> WebCore.MediaPlayerPrivateAVFoundation.AssetStatus {
        guard let asset = m_avAsset.get() else {
            return .init(rawValue: assetStatusDoesNotExist)
        }

        if !m_cachedAssetIsLoaded {
            let status = assetKeysStatus()
            if status.rawValue != assetStatusLoaded {
                return status
            }
            m_cachedAssetIsLoaded = true
        }

        // m_loadingMetadata will be false until all tracks' properties have finished loading.
        // See: beginLoadingMetadata().
        if loadingMetadata() {
            return .init(rawValue: assetStatusLoading)
        }

        if m_cachedTracksArePlayable == .Unknown {
            guard let tracksArePlayable = allTracksArePlayable() else {
                return .init(rawValue: assetStatusLoading)
            }
            m_cachedTracksArePlayable = tracksArePlayable ? .Yes : .No
        }

        if m_cachedAssetIsHLS == .Unknown {
            m_cachedAssetIsHLS = (AVFoundationMember.variants(of: asset)?.variants.count ?? 0) > 0 ? .Yes : .No
        }

        if m_cachedAssetIsPlayable == .Unknown {
            let playable = (asset.value(forKey: "playable") as? NSNumber)?.boolValue ?? false
            m_cachedAssetIsPlayable = playable || containsDisabledTracks() ? .Yes : .No
        }

        return .init(rawValue: assetStatusLoaded)
    }

    // nil until the asset's tracks have loaded, when there is no player item yet.
    private func allTracksArePlayable() -> Bool? {
        if let item = m_avPlayerItem.get() {
            for element in playerItemTracks(item) {
                guard let track = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVPlayerItemTrack) else {
                    return false
                }
                if !trackIsPlayable(assetTrack(of: track)) {
                    return false
                }
            }
            return true
        }

        guard let asset = m_avAsset.get(), hasLoaded(asset, "tracks") else {
            return nil
        }

        for element in assetTracks(asset) {
            guard let track = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVAssetTrack) else {
                return false
            }
            if isEnabled(track) && !trackIsPlayable(track) {
                return false
            }
        }
        return true
    }

    private func containsDisabledTracks() -> Bool {
        if let item = m_avPlayerItem.get() {
            for element in playerItemTracks(item) {
                if let track = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVPlayerItemTrack), !track.isEnabled {
                    return true
                }
            }
            return false
        }

        guard let asset = m_avAsset.get() else {
            return false
        }
        for element in assetTracks(asset) {
            if let track = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVAssetTrack), !isEnabled(track) {
                return true
            }
        }
        return false
    }

    @cxx
    @implementation
    func hasLoadedMediaSelectionGroups() -> Bool {
        guard let asset = m_avAsset.get() else {
            return false
        }
        return hasLoaded(asset, "availableMediaCharacteristicsWithMediaSelectionOptions")
    }

    @cxx
    @implementation
    func getStartDate() -> WTF.MediaTime {
        guard let item = m_avPlayerItem.get() else {
            return invalidMediaTime
        }

        // Date changes as the track's playback position changes. Must subtract currentTime (offset in seconds) from date offset to get date beginning
        let date = item.currentDate()?.timeIntervalSince1970 ?? 0

        // No live streams were made during the epoch (1970). AVFoundation returns 0 if the media file doesn't have a start date
        if date == 0 {
            return invalidMediaTime
        }

        let currentTime = CMTimeGetSeconds(item.currentTime())

        // Rounding due to second offset error when subtracting.
        return WTF.MediaTime.createWithDouble((date - currentTime).rounded())
    }

    @cxx
    @implementation
    override func totalBytes() -> UInt64 {
        if !metaDataAvailable() {
            return 0
        }

        if m_cachedTotalBytes != 0 {
            return UInt64(bitPattern: m_cachedTotalBytes)
        }

        if let tracks = m_cachedTracks.get() {
            for element in tracks {
                guard let track = AVFoundationClass.cast(element as AnyObject, to: AVFoundationClass.AVPlayerItemTrack), let assetTrack = assetTrack(of: track) else {
                    continue
                }
                m_cachedTotalBytes &+= totalSampleDataLength(assetTrack)
            }
        }

        return UInt64(bitPattern: m_cachedTotalBytes)
    }
}

// AVPlayerTimeControlStatus.playing, as the core caches it.
private let timeControlStatusPlaying = 2

// MediaPlayerWirelessPlaybackTargetType: None, AirPlay, TVOut.
private let wirelessPlaybackTargetTypeNone: UInt8 = 0
private let wirelessPlaybackTargetTypeAirPlay: UInt8 = 1
private let wirelessPlaybackTargetTypeTVOut: UInt8 = 2

// Sets a BOOL property that is SPI, and so not declared to WebCore's Swift (AVFoundationSPI.h, QuartzCoreSPI.h), if the
// object has its setter: key-value coding calls that setter unless the object also has a plain set<Key>:, which it
// would call first.
private func setPrivateBoolProperty(_ object: NSObject, _ key: Swift.String, setter: Swift.String, _ value: Bool) {
    let selector = NSSelectorFromString(setter)
    let plainSetter = NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
    guard object.responds(to: selector), plainSetter == selector || !object.responds(to: plainSetter) else {
        return
    }
    object.setValue(NSNumber(value: value), forKey: key)
}

private let toneMapToStandardDynamicRangeKey = "toneMapToStandardDynamicRange"
private let toneMapToStandardDynamicRangeSetter = "setToneMapToStandardDynamicRange:"

extension WebCore.MediaPlayerPrivateAVFoundationObjC {
    // MARK: Controls

    @cxx
    @implementation
    func configureAVPlayer(_ shouldDisableHDR: Bool, _ shouldDisableSleep: Bool) {
        guard let player = m_avPlayer.get() else {
            return
        }

        player.appliesMediaSelectionCriteriaAutomatically = false

        if let layer = m_videoLayer.get() {
            setPrivateBoolProperty(layer, toneMapToStandardDynamicRangeKey, setter: toneMapToStandardDynamicRangeSetter, shouldDisableHDR)
        }

#if ENABLE_WIRELESS_PLAYBACK_TARGET
        player.allowsExternalPlayback = m_allowsWirelessVideoPlayback
#endif

#if WTF_PLATFORM_IOS_FAMILY && !WTF_PLATFORM_IOS_FAMILY_SIMULATOR && !WTF_PLATFORM_MACCATALYST
        setPrivateBoolProperty(player, "preventsSleepDuringVideoPlayback", setter: "_setPreventsSleepDuringVideoPlayback:", shouldDisableSleep)
        setPrivateBoolProperty(player, "preventsAutomaticBackgroundingDuringVideoPlayback", setter: "setPreventsAutomaticBackgroundingDuringVideoPlayback:", false)
#endif

        player.volume = Float(m_volume)

        if m_muted {
            player.isMuted = true
        }

        applyAudibility(to: player)
    }

    @cxx
    @implementation
    func setMuted(_ muted: Bool) {
        if m_muted == muted {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundationObjC::setMuted \(muted)")

        m_muted = muted
        updateAudibility()

        m_avPlayer.get()?.isMuted = muted
    }

    @cxx
    @implementation
    override func updateIsAudible() {
        updateAudibility()
    }

    // updateIsAudible(), which Swift can't call as it implements it.
    private func updateAudibility() {
        // HLS can recreate its tracks while loading, briefly reporting that it
        // does not have audio. Suppressing audio rendering (or disconnecting from
        // system audio) in response perturbs AVFoundation's timebase, causing it
        // to seek into a still-unbuffered range. This leads to AVFoundation
        // restarting the loading process, recreating its tracks again and causing
        // a cycle. Break this cycle by waiting for HaveFutureData before
        // suppressing or disconnecting audio. This ensures that any timebase
        // perturbation in response to audio suppression occurs within a buffered
        // range.
        let hasAudio = hasAudioFromSwift()
        if !hasAudio && !isAtLeast(readyStateFromSwift(), .HaveFutureData) {
            return
        }

        let isAudible = hasAudio && !m_muted && m_volume != 0
        let isAudibleChanged = m_isAudible != isAudible

        let suppressesAudioRendering = !isAudible && (!hasAudio || hasVideoFromSwift())
        let suppressesAudioRenderingChanged = m_suppressesAudioRendering != suppressesAudioRendering

        if !isAudibleChanged && !suppressesAudioRenderingChanged {
            return
        }

        // Only change the state of suppressesAudioRendering and
        // disconnectedFromSystemAudio when playback is paused, to
        // avoid the reconfiguring of video playback that AVFoundation
        // performs when these properties are changed. However,
        // ignore this check if becoming audible to ensure audio
        // rendering starts immediately. This method will be called
        // again by timeControlStatusDidChange().
        if suppressesAudioRendering && core.timeControlStatus() == timeControlStatusPlaying {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundationObjC::updateIsAudible \(isAudible) suppressesAudioRendering = \(suppressesAudioRendering)")
        m_isAudible = isAudible
        m_suppressesAudioRendering = suppressesAudioRendering

        guard let player = m_avPlayer.get() else {
            return
        }

        if m_isVideoPlayer && suppressesAudioRenderingChanged {
            setPrivateBoolProperty(player, "suppressesAudioRendering", setter: "_setSuppressesAudioRendering:", m_suppressesAudioRendering)
        }

#if HAVE_AVPLAYER_DISCONNECTEDFROMSYSTEMAUDIO
        if isAudibleChanged {
            player.__setDisconnectedFromSystemAudio(!m_isAudible, completionHandler: nil)
        }
#endif
    }

    private func applyAudibility(to player: AVPlayer) {
        if m_isVideoPlayer {
            setPrivateBoolProperty(player, "suppressesAudioRendering", setter: "_setSuppressesAudioRendering:", m_suppressesAudioRendering)
        }

#if HAVE_AVPLAYER_DISCONNECTEDFROMSYSTEMAUDIO
        player.__setDisconnectedFromSystemAudio(!m_isAudible, completionHandler: nil)
#endif
    }

    @cxx
    @implementation
    func setShouldDisableSleep(_ flag: Bool) {
#if WTF_PLATFORM_IOS_FAMILY && !WTF_PLATFORM_IOS_FAMILY_SIMULATOR && !WTF_PLATFORM_MACCATALYST
        if let player = m_avPlayer.get() {
            setPrivateBoolProperty(player, "preventsSleepDuringVideoPlayback", setter: "_setPreventsSleepDuringVideoPlayback:", flag)
        }
#endif
    }

    @cxx
    @implementation
    func setShouldDisableHDR(_ shouldDisable: Bool) {
        assert(WTF.isMainThread())

        guard let layer = m_videoLayer.get(), layer.responds(to: NSSelectorFromString(toneMapToStandardDynamicRangeSetter)) else {
            return
        }

        logMessage(.Always, "MediaPlayerPrivateAVFoundationObjC::setShouldDisableHDR \(shouldDisable)")
        layer.setValue(NSNumber(value: shouldDisable), forKey: toneMapToStandardDynamicRangeKey)
    }

#if ENABLE_WIRELESS_PLAYBACK_TARGET
    @cxx
    @implementation
    func setWirelessVideoPlaybackDisabled(_ disabled: Bool) {
        logMessage(.Info, "MediaPlayerPrivateAVFoundationObjC::setWirelessVideoPlaybackDisabled \(disabled)")
        m_allowsWirelessVideoPlayback = !disabled
        m_avPlayer.get()?.allowsExternalPlayback = !disabled
    }

    @cxx
    @implementation
    func wirelessPlaybackTargetTypeValue() -> UInt8 {
#if WTF_PLATFORM_IOS_FAMILY
        guard let player = m_avPlayer.get(), player.responds(to: NSSelectorFromString("externalPlaybackType")) else {
            return wirelessPlaybackTargetTypeNone
        }

        // AVPlayer's externalPlaybackType, an AVPlayerExternalPlaybackType (None, AirPlay, TVOut), is SPI.
        switch (player.value(forKey: "externalPlaybackType") as? NSNumber)?.intValue {
        case 1:
            return wirelessPlaybackTargetTypeAirPlay
        case 2:
            return wirelessPlaybackTargetTypeTVOut
        default:
            return wirelessPlaybackTargetTypeNone
        }
#else
        guard let _ = m_avPlayer.get() else {
            return wirelessPlaybackTargetTypeNone
        }
        return wirelessPlaybackTargetTypeAirPlay
#endif
    }
#endif
}
