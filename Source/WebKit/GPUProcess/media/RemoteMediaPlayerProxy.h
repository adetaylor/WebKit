/*
 * Copyright (C) 2019-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)

#include "Connection.h"
#include "MediaPlayerPrivateRemote.h"
#include "MessageReceiver.h"
#include "RemoteLegacyCDMSessionIdentifier.h"
#include "RemoteMediaPlayerConfiguration.h"
#include "RemoteMediaPlayerProxyConfiguration.h"
#include "RemoteMediaPlayerState.h"
#include "RemoteMediaResourceIdentifier.h"
#include "RemoteMediaResourceLoaderIdentifier.h"
#include "RemoteVideoFrameProxy.h"
#include "SandboxExtension.h"
#include "ScopedRenderingResourcesRequest.h"
#include <WebCore/Cookie.h>
#include <WebCore/InbandTextTrackPrivate.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/MessageClientForTesting.h>
#include <WebCore/PlatformDynamicRangeLimit.h>
#include <WebCore/PlatformMediaResourceLoader.h>
#include <WebCore/ShareableBitmap.h>
#include <optional>
#include <wtf/LoggerHelper.h>
#include <wtf/NativePromiseSettler.h>
#include <wtf/RefCountable.h>
#include <wtf/RefPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

#if ENABLE(ENCRYPTED_MEDIA)
#include "RemoteCDMInstanceIdentifier.h"
#endif

#if PLATFORM(COCOA)
#include "SharedCARingBuffer.h"
#endif

#if USE(AVFOUNDATION)
#include <wtf/RetainPtr.h>
#endif

namespace WTF {
class MachSendRight;
}

namespace WebCore {
class AudioTrackPrivate;
struct MediaPlayerLoadOptions;
class SecurityOriginData;
class VideoTrackPrivate;

struct FourCC;

class VideoFrame;

#if PLATFORM(COCOA)
class VideoFrameCV;
#endif
}

#if USE(AVFOUNDATION)
typedef struct __CVBuffer* CVPixelBufferRef;
#endif

namespace WebKit {

using LayerHostingContextID = uint32_t;
class LayerHostingContext;
class LayerHostingContextManager;
#if ENABLE(WIRELESS_PLAYBACK_TARGET)
class MediaPlaybackTargetContextSerialized;
#endif
class GPUConnectionToWebProcess;
class RemoteAudioSourceProviderProxy;
class RemoteMediaPlayerManagerProxy;
class RemoteVideoFrameObjectHeap;

class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteMediaPlayerProxy.swift") RemoteMediaPlayerProxy final
    : public RefCounted<RemoteMediaPlayerProxy>
    , public WebCore::MediaPlayerClient
    , private WebCore::MessageClientForTesting
    , private IPC::MessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteMediaPlayerProxy);
public:
    USING_CAN_MAKE_WEAKPTR(WebCore::MediaPlayerClient);

    static Ref<RemoteMediaPlayerProxy> create(RemoteMediaPlayerManagerProxy&, WebCore::MediaPlayerIdentifier, WebCore::MediaPlayerClientIdentifier, Ref<IPC::Connection>&&, WebCore::MediaPlayerEnums::MediaEngineIdentifier, RemoteMediaPlayerProxyConfiguration&&, RemoteVideoFrameObjectHeap&, const WebCore::ProcessIdentity&);
    ~RemoteMediaPlayerProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    WebCore::MediaPlayerIdentifier identifier() const { return m_id; }
    void invalidate();

#if PLATFORM(COCOA)
    std::optional<WebCore::FloatRect> hostedVideoLayerBoundsForTesting(WebCore::MediaPlayerClientIdentifier) const;
#endif

    // Ensure that all previously queued messages to the content process have completed.
    Ref<WebCore::MediaPromise> commitAllTransactions();

#if ENABLE(VIDEO_PRESENTATION_MODE)
    void setVideoFullscreenMode(WebCore::MediaPlayer::VideoFullscreenMode);
#endif

    void setBufferingPolicy(WebCore::MediaPlayer::BufferingPolicy);

#if PLATFORM(IOS_FAMILY)
    void accessLog(CompletionHandler<void(String)>&&);
    void errorLog(CompletionHandler<void(String)>&&);
    void setSceneIdentifier(String&&);
#endif

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);

    RemoteMediaPlayerConfiguration configuration();

    void prepareForPlayback(bool privateMode, WebCore::MediaPlayerEnums::Preload, bool preservesPitch, WebCore::MediaPlayerEnums::PitchCorrectionAlgorithm, bool prepareToPlay, bool prepareForRendering, WebCore::IntSize presentationSize, float videoContentScale, bool isFullscreen, WebCore::DynamicRangeMode, WebCore::PlatformDynamicRangeLimit);

    void load(URL&&, std::optional<SandboxExtension::Handle>&&, const WebCore::MediaPlayerLoadOptions&, CompletionHandler<void(RemoteMediaPlayerConfiguration&&)>&&);

    using WeakRemoteMediaPlayerProxy = WeakPtr<RemoteMediaPlayerProxy>;
    WeakRemoteMediaPlayerProxy weakPtrForSwift() { return *this; }
    using MediaTimePromiseSettler = WTF::NativePromiseSettler<WebCore::MediaTimePromise>;
    using MediaTimePromiseHandler = MediaTimePromiseSettler::Handler;
    using MediaTimeResult = MediaTimePromiseSettler::Result;
    using VideoPlaybackQualityMetricsPromiseSettler = WTF::NativePromiseSettler<WebCore::MediaPlayer::VideoPlaybackQualityMetricsPromise>;
    using VideoPlaybackQualityMetricsPromiseHandler = VideoPlaybackQualityMetricsPromiseSettler::Handler;
    using VideoPlaybackQualityMetricsResult = VideoPlaybackQualityMetricsPromiseSettler::Result;
    using ColorSpaceCompletionHandler = WTF::RefCountable<CompletionHandler<void(WebCore::ColorSpace)>>;
    using SeekResult = std::expected<WebCore::MediaTimeUpdateData, WebCore::PlatformMediaError>;
    using SeekCompletionHandler = WTF::RefCountable<CompletionHandler<void(SeekResult)>>;
    void seekToTarget(WebCore::SeekTarget, SeekCompletionHandler* WTF_NONNULL);

    void setPreload(WebCore::MediaPlayerEnums::Preload);
    void setPitchCorrectionAlgorithm(WebCore::MediaPlayer::PitchCorrectionAlgorithm);

    using ViewportVisibility = WebCore::MediaPlayer::ViewportVisibility;
    void setViewportVisibility(ViewportVisibility);
#if ENABLE(VIDEO_PRESENTATION_MODE)
    void setVideoFullscreenGravity(WebCore::MediaPlayerEnums::VideoGravity);
#endif
    using DidLoadingProgressCompletionHandler = WTF::RefCountable<CompletionHandler<void(bool)>>;
    void didLoadingProgress(DidLoadingProgressCompletionHandler* WTF_NONNULL);

#if PLATFORM(COCOA)
    void setVideoLayerSizeFenced(const WebCore::FloatSize&, WTF::MachSendRightAnnotated&&);
#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    void setWirelessPlaybackTarget(MediaPlaybackTargetContextSerialized&&);
    void mediaPlayerCurrentPlaybackTargetIsWirelessChanged(bool) final;
    WebCore::MediaPlaybackTargetType playbackTargetType() const final;
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    void setLegacyCDMSession(std::optional<RemoteLegacyCDMSessionIdentifier>&& instanceId);
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void cdmInstanceAttached(RemoteCDMInstanceIdentifier&&);
    void cdmInstanceDetached(RemoteCDMInstanceIdentifier&&);
    void attemptToDecryptWithInstance(RemoteCDMInstanceIdentifier&&);
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) && ENABLE(ENCRYPTED_MEDIA)
#endif

    SWIFT_MAIN_ACTOR void audioTrackSetEnabled(WebCore::TrackID, bool);
    SWIFT_MAIN_ACTOR void videoTrackSetSelected(WebCore::TrackID, bool);
    SWIFT_MAIN_ACTOR void textTrackSetMode(WebCore::TrackID, WebCore::InbandTextTrackPrivate::Mode);

    using PerformTaskAtTimeCompletionHandler = CompletionHandler<void(std::optional<MediaTime>)>;
    void performTaskAtTime(const MediaTime&, PerformTaskAtTimeCompletionHandler&&);
    using IsCrossOriginCompletionHandler = WTF::RefCountable<CompletionHandler<void(std::optional<bool>)>>;
    void isCrossOrigin(WebCore::SecurityOriginData, IsCrossOriginCompletionHandler* WTF_NONNULL);

    void setPreferredDynamicRangeMode(WebCore::DynamicRangeMode);
    void setPlatformDynamicRangeLimit(WebCore::PlatformDynamicRangeLimit);

    RefPtr<WebCore::MediaPlayer> mediaPlayer() { return m_player; }

    SWIFT_MAIN_ACTOR void addRemoteAudioTrackProxy(WebCore::AudioTrackPrivate&);
    SWIFT_MAIN_ACTOR void addRemoteVideoTrackProxy(WebCore::VideoTrackPrivate&);
    SWIFT_MAIN_ACTOR void addRemoteTextTrackProxy(WebCore::InbandTextTrackPrivate&);

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    void destroyResourceLoader(RemoteMediaResourceLoaderIdentifier);

private:
    RemoteMediaPlayerProxy(RemoteMediaPlayerManagerProxy&, WebCore::MediaPlayerIdentifier, WebCore::MediaPlayerClientIdentifier, Ref<IPC::Connection>&&, WebCore::MediaPlayerEnums::MediaEngineIdentifier, RemoteMediaPlayerProxyConfiguration&&, RemoteVideoFrameObjectHeap&, const WebCore::ProcessIdentity&);

    // MediaPlayerClient
    void mediaPlayerCharacteristicChanged() final;
    void mediaPlayerRenderingModeChanged() final;
    void mediaPlayerNetworkStateChanged() final;
    void mediaPlayerReadyStateChanged() final;
    void mediaPlayerVolumeChanged() final;
    void mediaPlayerMuteChanged() final;
    void mediaPlayerTimeChanged() final;
    void mediaPlayerDurationChanged() final;
    void mediaPlayerSizeChanged() final;
    void mediaPlayerRateChanged() final;
    void mediaPlayerPlaybackStateChanged() final;
    void mediaPlayerResourceNotSupported() final;
    void mediaPlayerEngineFailedToLoad() final;
    void mediaPlayerBufferedTimeRangesChanged() final;
    void mediaPlayerSeekableTimeRangesChanged() final;
    bool mediaPlayerRenderingCanBeAccelerated() final { return m_renderingCanBeAccelerated; }

    void mediaPlayerDidAddAudioTrack(WebCore::AudioTrackPrivate&) final;
    void mediaPlayerDidRemoveAudioTrack(WebCore::AudioTrackPrivate&) final;
    void mediaPlayerDidAddVideoTrack(WebCore::VideoTrackPrivate&) final;
    void mediaPlayerDidRemoveVideoTrack(WebCore::VideoTrackPrivate&) final;
    void mediaPlayerDidAddTextTrack(WebCore::InbandTextTrackPrivate&) final;
    void mediaPlayerDidRemoveTextTrack(WebCore::InbandTextTrackPrivate&) final;
    String audioOutputDeviceId() const final { return m_configuration.audioOutputDeviceId; }
    String audioOutputDeviceIdOverride() const final { return m_configuration.audioOutputDeviceId; }

    // Not implemented
    void mediaPlayerFirstVideoFrameAvailable() final;

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    RefPtr<ArrayBuffer> mediaPlayerCachedKeyForKeyId(const String&) const final;
    void mediaPlayerKeyNeeded(const WebCore::SharedBuffer&) final;
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void mediaPlayerInitializationDataEncountered(const String&, RefPtr<ArrayBuffer>&&) final;
    void mediaPlayerWaitingForKeyChanged() final;
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    String mediaPlayerMediaKeysStorageDirectory() const final;
#endif

    String mediaPlayerReferrer() const final { return m_configuration.referrer; }
    String mediaPlayerUserAgent() const final { return m_configuration.userAgent; }
    bool mediaPlayerIsFullscreen() const final { return false; }
    bool mediaPlayerIsFullscreenPermitted() const final { return false; }
    bool mediaPlayerIsVideo() const final { return m_configuration.isVideo; }
    float mediaPlayerContentsScale() const final { return m_videoContentScale; }
    bool mediaPlayerPlatformVolumeConfigurationRequired() const final { return false; }
    WebCore::CachedResourceLoader* mediaPlayerCachedResourceLoader() const final { return nullptr; }
    Ref<WebCore::PlatformMediaResourceLoader> mediaPlayerCreateResourceLoader() final;
    bool doesHaveAttribute(const AtomString&, AtomString* = nullptr) const final { return false; }
    bool mediaPlayerShouldUsePersistentCache() const final { return m_configuration.shouldUsePersistentCache; }
    String mediaPlayerMediaCacheDirectory() const final;
    WebCore::LayoutRect mediaPlayerContentBoxRect() const final { return m_playerContentBoxRect; }

    void textTrackRepresentationBoundsChanged(const WebCore::IntRect&) final { }

#if PLATFORM(COCOA)
    Vector<Ref<WebCore::PlatformTextTrack>> outOfBandTrackSources() final;
#endif

#if PLATFORM(IOS_FAMILY)
    String mediaPlayerNetworkInterfaceName() const final;
    void mediaPlayerGetRawCookies(const URL&, WebCore::MediaPlayerClient::GetRawCookiesCallback&&) const final;
#endif

    String mediaPlayerSourceApplicationIdentifier() const final { return m_configuration.sourceApplicationIdentifier; }
    WebCore::MediaPlayerClientIdentifier mediaPlayerClientIdentifier() const final { return m_clientIdentifier; }

    double mediaPlayerRequestedPlaybackRate() const final { return 0; }
#if ENABLE(VIDEO_PRESENTATION_MODE)
    WebCore::MediaPlayerEnums::VideoFullscreenMode mediaPlayerFullscreenMode() const final { return m_fullscreenMode; }
    bool mediaPlayerIsVideoFullscreenStandby() const final { return m_videoFullscreenStandby; }
#endif
    Vector<String> mediaPlayerPreferredAudioCharacteristics() const final { return m_configuration.preferredAudioCharacteristics; }

    bool mediaPlayerShouldDisableSleep() const final { return false; }
    const Vector<WebCore::ContentType>& mediaContentTypesRequiringHardwareSupport() const final { return m_typesRequiringHardwareSupport; }
    bool mediaPlayerShouldCheckHardwareSupport() const final { return m_shouldCheckHardwareSupport; }

    const std::optional<Vector<String>>& allowedMediaContainerTypes() const final { return m_configuration.allowedMediaContainerTypes; };
    const std::optional<Vector<String>>& allowedMediaCodecTypes() const final { return m_configuration.allowedMediaCodecTypes; };
    const std::optional<Vector<WebCore::FourCC>>& allowedMediaVideoCodecIDs() const final { return m_configuration.allowedMediaVideoCodecIDs; };
    const std::optional<Vector<WebCore::FourCC>>& allowedMediaAudioCodecIDs() const final { return m_configuration.allowedMediaAudioCodecIDs; };
    const std::optional<Vector<WebCore::FourCC>>& allowedMediaCaptionFormatTypes() const final { return m_configuration.allowedMediaCaptionFormatTypes; };

    bool mediaPlayerShouldDisableHDR() const final { return m_configuration.shouldDisableHDR; }

    WebCore::PlatformVideoTarget mediaPlayerVideoTarget() const final;

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    WebCore::MediaPlayer& player() const { return *m_player; }
    void stopUpdateCachedStateMessageTimer() { m_updateCachedStateMessageTimer.stop(); }
    bool isUpdateCachedStateMessageTimerActive() const { return m_updateCachedStateMessageTimer.isActive(); }
    void startRepeatingUpdateCachedStateMessageTimer(double seconds) { m_updateCachedStateMessageTimer.startRepeating(Seconds(seconds)); }
    void cacheBufferedRanges();
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    void setPreferredSpeakerID();
#endif
    uint64_t logIdentifierForSwift() const { return m_configuration.logIdentifier; }
    bool willLogAlways() const;
    void logAlways(const String& message) const;
#endif

    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() const;
    bool prepareTrackForProxy(WebCore::TrackPrivateBase&);
    SWIFT_MAIN_ACTOR void removeAudioTrackProxy(WebCore::TrackID);
    SWIFT_MAIN_ACTOR void removeVideoTrackProxy(WebCore::TrackID);
    SWIFT_MAIN_ACTOR void removeTextTrackProxy(WebCore::TrackID);
    // m_swiftTracks holds the track proxies (RemoteMediaPlayerProxy.swift).
    static uintptr_t createSwiftTracks();
    // Unsafe: the tracks must be the ones createSwiftTracks() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftTracks(uintptr_t);
    uintptr_t swiftTracks() const { return m_swiftTracks; }

    void observeCurrentTimeChanges();
    void startUpdateCachedStateMessageTimer();
    void updateCachedState(bool = false);
    void sendCachedState();
    void timerFired();

    void maybeUpdateCachedVideoMetrics();
    void updateCachedVideoMetrics();

    void updateCachedMediaCharacteristics();

    void createAudioSourceProvider();
    void setShouldEnableAudioSourceProvider(bool);

    void playAtHostTime(MonotonicTime);
    void pauseAtHostTime(MonotonicTime);

#if PLATFORM(COCOA)
    void mediaPlayerOnNewVideoFrameMetadata(WebCore::VideoFrameMetadata&&, RetainPtr<CVPixelBufferRef>&&);
#endif

    void playerContentBoxRectChanged(WebCore::LayoutRect);

    void currentTimeChanged(MediaTime);

#if PLATFORM(COCOA)
    WebCore::FloatSize mediaPlayerVideoLayerSize() const final;
    void nativeImageForCurrentTime(CompletionHandler<void(std::optional<WTF::MachSendRight>&&, WebCore::ColorSpace)>&&);
    void colorSpace(ColorSpaceCompletionHandler* WTF_NONNULL);
#endif
    void videoFrameForCurrentTimeIfChanged(RemoteVideoFrameReference, CompletionHandler<void(std::optional<RemoteVideoFrameProxy::Properties>&&, bool)>&&);
    void bitmapImageForCurrentTime(CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&&);

    void requestHostingContext(CompletionHandler<void(WebCore::HostingContext)>&&);
#if HAVE(SPATIAL_TRACKING_LABEL)
    void setDefaultSpatialTrackingLabel(String);
    void setSpatialTrackingLabel(String);
#endif
#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
#endif

    void audioOutputDeviceChanged(String);
    using SoundStageSize = WebCore::MediaPlayer::SoundStageSize;
    void setSoundStageSize(SoundStageSize);
        SoundStageSize mediaPlayerSoundStageSize() const final { return m_soundStageSize; }

    void setHasMessageClientForTesting(bool);
    void sendInternalMessage(const WebCore::MessageForTesting&) final;

#if PLATFORM(MAC)
#endif

#if !RELEASE_LOG_DISABLED
    const Logger& mediaPlayerLogger() final { return m_logger; }
    uint64_t mediaPlayerLogIdentifier() { return m_configuration.logIdentifier; }
    const Logger& logger() { return mediaPlayerLogger(); }
    uint64_t logIdentifier() { return mediaPlayerLogIdentifier(); }
    ASCIILiteral logClassName() const { return "RemoteMediaPlayerProxy"_s; }
    NODELETE WTFLogChannel& logChannel() const;
#endif

    uintptr_t m_swiftTracks __attribute__((availability(swift, unavailable))) { createSwiftTracks() };

    WebCore::MediaPlayerIdentifier m_id;
    WebCore::MediaPlayerClientIdentifier m_clientIdentifier;
    RefPtr<SandboxExtension> m_sandboxExtension;
    const Ref<IPC::Connection> m_webProcessConnection;
    const RefPtr<WebCore::MediaPlayer> m_player;
    WeakPtr<RemoteMediaPlayerManagerProxy> m_manager;
    WebCore::MediaPlayerEnums::MediaEngineIdentifier m_engineIdentifier;
    Vector<WebCore::ContentType> m_typesRequiringHardwareSupport;
    RunLoop::Timer m_updateCachedStateMessageTimer;
    RemoteMediaPlayerState m_cachedState;
    RemoteMediaPlayerProxyConfiguration m_configuration;
    PerformTaskAtTimeCompletionHandler m_performTaskAtTimeCompletionHandler;

    double m_videoPlaybackMetricsUpdateInterval { 0 };
    double m_nextPlaybackQualityMetricsUpdateTime { 0 };
    bool m_hasPlaybackMetricsUpdatePending { false };

    float m_videoContentScale { 1.0 };
    WebCore::LayoutRect m_playerContentBoxRect;

    bool m_bufferedChanged { true };
    bool m_renderingCanBeAccelerated { false };
    WebCore::MediaPlayer::VideoFullscreenMode m_fullscreenMode { WebCore::MediaPlayer::VideoFullscreenModeNone };
    bool m_videoFullscreenStandby { false };

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) && ENABLE(ENCRYPTED_MEDIA)
    bool m_shouldContinueAfterKeyNeeded { false };
    std::optional<RemoteLegacyCDMSessionIdentifier> m_legacySession;
#endif

#if ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
    const RefPtr<RemoteAudioSourceProviderProxy> m_remoteAudioSourceProvider;
#endif
    ScopedRenderingResourcesRequest m_renderingResourcesRequest;

    bool m_observingTimeChanges { false };
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    bool m_invalidated { false };
#endif
    const Ref<RemoteVideoFrameObjectHeap> m_videoFrameObjectHeap;
    RefPtr<WebCore::VideoFrame> m_videoFrameForCurrentTime;
    bool m_shouldCheckHardwareSupport { false };
    SoundStageSize m_soundStageSize { SoundStageSize::Auto };
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
#endif
#if PLATFORM(COCOA)
    const UniqueRef<LayerHostingContextManager> m_layerHostingContextManager;
#endif
};

} // namespace WebKit

namespace IPC {

// default CompletionHandler value should the process crash.
template<> struct AsyncReplyError<WTF::MediaTime> {
    static WTF::MediaTime create() { return WTF::MediaTime::invalidTime(); };
};

} // namespace IPC

#endif // ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
