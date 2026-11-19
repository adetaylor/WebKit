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


#if ENABLE_WEBCORE_SWIFT && ENABLE_VIDEO

import Dispatch
import WebCore_Private.Core.AudioTrackPrivate
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.InbandTextTrackPrivate
import WebCore_Private.Core.MediaPlayer
import WebCore_Private.Core.SharedBuffer
import WebCore_Private.Core.VideoTrackPrivate

// What a Swift MediaPlayerClient implements: the MediaPlayerClient members that SwiftMediaPlayerClientAdapter doesn't
// answer from its fields. The callbacks without a result default to doing nothing, as in MediaPlayerClient.
@_spi(WebKitGPU) public protocol MediaPlayerClientDelegate: AnyObject {
    func mediaPlayerNetworkStateChanged()
    func mediaPlayerReadyStateChanged()
    func mediaPlayerVolumeChanged()
    func mediaPlayerMuteChanged()
    func mediaPlayerTimeChanged()
    func mediaPlayerDurationChanged()
    func mediaPlayerRateChanged()
    func mediaPlayerPlaybackStateChanged()
    func mediaPlayerResourceNotSupported()
    func mediaPlayerSizeChanged()
    func mediaPlayerFirstVideoFrameAvailable()
    func mediaPlayerCharacteristicChanged()
    func mediaPlayerRenderingModeChanged()
    func mediaPlayerEngineFailedToLoad()
    func mediaPlayerBufferedTimeRangesChanged()
    func mediaPlayerSeekableTimeRangesChanged()

    func mediaPlayerVideoLayerSize() -> WebCore.FloatSize

    func mediaPlayerReferrer() -> WTF.String
    func mediaPlayerUserAgent() -> WTF.String
    func mediaPlayerSourceApplicationIdentifier() -> WTF.String
    func audioOutputDeviceId() -> WTF.String
    // Nil for the empty string, as MediaPlayerClient's default.
    func mediaPlayerMediaCacheDirectory() -> WTF.String?

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA || ENABLE_ENCRYPTED_MEDIA
    // Nil for the empty string, as MediaPlayerClient's default.
    func mediaPlayerMediaKeysStorageDirectory() -> WTF.String?
    #endif

    @MainActor func mediaPlayerDidAddAudioTrack(_ track: WebCore.AudioTrackPrivate)
    @MainActor func mediaPlayerDidRemoveAudioTrack(_ track: WebCore.AudioTrackPrivate)
    @MainActor func mediaPlayerDidAddVideoTrack(_ track: WebCore.VideoTrackPrivate)
    @MainActor func mediaPlayerDidRemoveVideoTrack(_ track: WebCore.VideoTrackPrivate)
    @MainActor func mediaPlayerDidAddTextTrack(_ track: WebCore.InbandTextTrackPrivate)
    @MainActor func mediaPlayerDidRemoveTextTrack(_ track: WebCore.InbandTextTrackPrivate)

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    func mediaPlayerKeyNeeded(_ message: WebCore.SharedBuffer)
    #endif

    #if ENABLE_ENCRYPTED_MEDIA
    func mediaPlayerWaitingForKeyChanged()
    #endif

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    func mediaPlayerCurrentPlaybackTargetIsWirelessChanged(_ isCurrentPlaybackTargetWireless: Bool)
    func playbackTargetType() -> WebCore.MediaPlaybackTargetType
    #endif
}

@_spi(WebKitGPU) extension MediaPlayerClientDelegate {
    public func mediaPlayerNetworkStateChanged() {}
    public func mediaPlayerReadyStateChanged() {}
    public func mediaPlayerVolumeChanged() {}
    public func mediaPlayerMuteChanged() {}
    public func mediaPlayerTimeChanged() {}
    public func mediaPlayerDurationChanged() {}
    public func mediaPlayerRateChanged() {}
    public func mediaPlayerPlaybackStateChanged() {}
    public func mediaPlayerResourceNotSupported() {}
    public func mediaPlayerSizeChanged() {}
    public func mediaPlayerFirstVideoFrameAvailable() {}
    public func mediaPlayerCharacteristicChanged() {}
    public func mediaPlayerRenderingModeChanged() {}
    public func mediaPlayerEngineFailedToLoad() {}
    public func mediaPlayerBufferedTimeRangesChanged() {}
    public func mediaPlayerSeekableTimeRangesChanged() {}

    public func mediaPlayerVideoLayerSize() -> WebCore.FloatSize {
        WebCore.FloatSize()
    }

    public func mediaPlayerReferrer() -> WTF.String {
        WTF.String()
    }

    public func mediaPlayerUserAgent() -> WTF.String {
        WTF.String()
    }

    public func mediaPlayerSourceApplicationIdentifier() -> WTF.String {
        WTF.String()
    }

    public func audioOutputDeviceId() -> WTF.String {
        WTF.String()
    }

    public func mediaPlayerMediaCacheDirectory() -> WTF.String? {
        nil
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA || ENABLE_ENCRYPTED_MEDIA
    public func mediaPlayerMediaKeysStorageDirectory() -> WTF.String? {
        nil
    }
    #endif

    @MainActor public func mediaPlayerDidAddAudioTrack(_ track: WebCore.AudioTrackPrivate) {}
    @MainActor public func mediaPlayerDidRemoveAudioTrack(_ track: WebCore.AudioTrackPrivate) {}
    @MainActor public func mediaPlayerDidAddVideoTrack(_ track: WebCore.VideoTrackPrivate) {}
    @MainActor public func mediaPlayerDidRemoveVideoTrack(_ track: WebCore.VideoTrackPrivate) {}
    @MainActor public func mediaPlayerDidAddTextTrack(_ track: WebCore.InbandTextTrackPrivate) {}
    @MainActor public func mediaPlayerDidRemoveTextTrack(_ track: WebCore.InbandTextTrackPrivate) {}

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    public func mediaPlayerKeyNeeded(_ message: WebCore.SharedBuffer) {}
    #endif

    #if ENABLE_ENCRYPTED_MEDIA
    public func mediaPlayerWaitingForKeyChanged() {}
    #endif

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    public func mediaPlayerCurrentPlaybackTargetIsWirelessChanged(_ isCurrentPlaybackTargetWireless: Bool) {}

    public func playbackTargetType() -> WebCore.MediaPlaybackTargetType {
        .None
    }
    #endif
}

// MediaPlayerClient's default media cache and key storage directory.
private var emptyString: WTF.String {
    // Safety: WTF::emptyString() is a static String that lives as long as the process.
    unsafe WTF.emptyString().pointee
}

private typealias MediaPlayerClientDelegateBox = SwiftDelegateBox<any MediaPlayerClientDelegate>

// A box for SwiftMediaPlayerClientAdapter.create(), holding the delegate strongly: the adapter's owner owns the adapter,
// so a delegate that holds the owner weakly makes no cycle.
@_spi(WebKitGPU) public func makeSwiftMediaPlayerClientDelegateBox(_ delegate: any MediaPlayerClientDelegate) -> UInt {
    MediaPlayerClientDelegateBox.retained { delegate }
}

extension WebCore.SwiftMediaPlayerClientAdapter {
    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        // Safety: the box is the one makeSwiftMediaPlayerClientDelegateBox() retained for this adapter, which releases it once.
        unsafe MediaPlayerClientDelegateBox.release(box)
    }

    @_spi(WebKitGPU) public var mediaPlayerClientDelegate: (any MediaPlayerClientDelegate)? {
        delegate
    }

    // MediaPlayer calls its client on the main thread only.
    private var delegate: (any MediaPlayerClientDelegate)? {
        dispatchPrecondition(condition: .onQueue(.main))
        // Safety: m_delegateBox is the adapter's box from its constructor to its destructor.
        return unsafe MediaPlayerClientDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    func mediaPlayerNetworkStateChanged() {
        delegate?.mediaPlayerNetworkStateChanged()
    }

    @cxx
    @implementation
    func mediaPlayerReadyStateChanged() {
        delegate?.mediaPlayerReadyStateChanged()
    }

    @cxx
    @implementation
    func mediaPlayerVolumeChanged() {
        delegate?.mediaPlayerVolumeChanged()
    }

    @cxx
    @implementation
    func mediaPlayerMuteChanged() {
        delegate?.mediaPlayerMuteChanged()
    }

    @cxx
    @implementation
    func mediaPlayerTimeChanged() {
        delegate?.mediaPlayerTimeChanged()
    }

    @cxx
    @implementation
    func mediaPlayerDurationChanged() {
        delegate?.mediaPlayerDurationChanged()
    }

    @cxx
    @implementation
    func mediaPlayerRateChanged() {
        delegate?.mediaPlayerRateChanged()
    }

    @cxx
    @implementation
    func mediaPlayerPlaybackStateChanged() {
        delegate?.mediaPlayerPlaybackStateChanged()
    }

    @cxx
    @implementation
    func mediaPlayerResourceNotSupported() {
        delegate?.mediaPlayerResourceNotSupported()
    }

    @cxx
    @implementation
    func mediaPlayerSizeChanged() {
        delegate?.mediaPlayerSizeChanged()
    }

    @cxx
    @implementation
    func mediaPlayerFirstVideoFrameAvailable() {
        delegate?.mediaPlayerFirstVideoFrameAvailable()
    }

    @cxx
    @implementation
    func mediaPlayerCharacteristicChanged() {
        delegate?.mediaPlayerCharacteristicChanged()
    }

    @cxx
    @implementation
    func mediaPlayerRenderingModeChanged() {
        delegate?.mediaPlayerRenderingModeChanged()
    }

    @cxx
    @implementation
    func mediaPlayerEngineFailedToLoad() {
        delegate?.mediaPlayerEngineFailedToLoad()
    }

    @cxx
    @implementation
    func mediaPlayerBufferedTimeRangesChanged() {
        delegate?.mediaPlayerBufferedTimeRangesChanged()
    }

    @cxx
    @implementation
    func mediaPlayerSeekableTimeRangesChanged() {
        delegate?.mediaPlayerSeekableTimeRangesChanged()
    }

    @cxx
    @implementation
    func mediaPlayerVideoLayerSize() -> WebCore.FloatSize {
        delegate?.mediaPlayerVideoLayerSize() ?? WebCore.FloatSize()
    }

    @cxx
    @implementation
    func mediaPlayerReferrer() -> WTF.String {
        delegate?.mediaPlayerReferrer() ?? WTF.String()
    }

    @cxx
    @implementation
    func mediaPlayerUserAgent() -> WTF.String {
        delegate?.mediaPlayerUserAgent() ?? WTF.String()
    }

    @cxx
    @implementation
    func mediaPlayerSourceApplicationIdentifier() -> WTF.String {
        delegate?.mediaPlayerSourceApplicationIdentifier() ?? WTF.String()
    }

    @cxx
    @implementation
    func audioOutputDeviceId() -> WTF.String {
        delegate?.audioOutputDeviceId() ?? WTF.String()
    }

    @cxx
    @implementation
    func mediaPlayerMediaCacheDirectory() -> WTF.String {
        delegate?.mediaPlayerMediaCacheDirectory() ?? emptyString
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA || ENABLE_ENCRYPTED_MEDIA
    @cxx
    @implementation
    func mediaPlayerMediaKeysStorageDirectory() -> WTF.String {
        delegate?.mediaPlayerMediaKeysStorageDirectory() ?? emptyString
    }
    #endif

    @cxx
    @implementation
    @MainActor
    func mediaPlayerDidAddAudioTrack(_ track: WebCore.AudioTrackPrivate) {
        delegate?.mediaPlayerDidAddAudioTrack(track)
    }

    @cxx
    @implementation
    @MainActor
    func mediaPlayerDidRemoveAudioTrack(_ track: WebCore.AudioTrackPrivate) {
        delegate?.mediaPlayerDidRemoveAudioTrack(track)
    }

    @cxx
    @implementation
    @MainActor
    func mediaPlayerDidAddVideoTrack(_ track: WebCore.VideoTrackPrivate) {
        delegate?.mediaPlayerDidAddVideoTrack(track)
    }

    @cxx
    @implementation
    @MainActor
    func mediaPlayerDidRemoveVideoTrack(_ track: WebCore.VideoTrackPrivate) {
        delegate?.mediaPlayerDidRemoveVideoTrack(track)
    }

    @cxx
    @implementation
    @MainActor
    func mediaPlayerDidAddTextTrack(_ track: WebCore.InbandTextTrackPrivate) {
        delegate?.mediaPlayerDidAddTextTrack(track)
    }

    @cxx
    @implementation
    @MainActor
    func mediaPlayerDidRemoveTextTrack(_ track: WebCore.InbandTextTrackPrivate) {
        delegate?.mediaPlayerDidRemoveTextTrack(track)
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA
    @cxx
    @implementation
    func mediaPlayerKeyNeeded(_ message: borrowing WebCore.SharedBuffer) {
        delegate?.mediaPlayerKeyNeeded(copy message)
    }
    #endif

    #if ENABLE_ENCRYPTED_MEDIA
    @cxx
    @implementation
    func mediaPlayerWaitingForKeyChanged() {
        delegate?.mediaPlayerWaitingForKeyChanged()
    }
    #endif

    #if ENABLE_WIRELESS_PLAYBACK_TARGET
    @cxx
    @implementation
    func mediaPlayerCurrentPlaybackTargetIsWirelessChanged(_ isCurrentPlaybackTargetWireless: Bool) {
        delegate?.mediaPlayerCurrentPlaybackTargetIsWirelessChanged(isCurrentPlaybackTargetWireless)
    }

    @cxx
    @implementation
    func playbackTargetType() -> WebCore.MediaPlaybackTargetType {
        delegate?.playbackTargetType() ?? .None
    }
    #endif
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_VIDEO
