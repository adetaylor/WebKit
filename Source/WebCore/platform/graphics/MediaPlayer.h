/*
 * Copyright (C) 2007-2023 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <wtf/Platform.h>
#if ENABLE(VIDEO)

#include <JavaScriptCore/Forward.h>
#include <WebCore/ContentType.h>
#include <WebCore/Cookie.h>
#include <WebCore/FourCC.h>
#include <WebCore/GraphicsTypesGL.h>
#include <WebCore/LayoutRect.h>
#include <WebCore/MediaPlayerClientIdentifier.h>
#include <WebCore/MediaPlayerEnums.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/PlatformDynamicRangeLimit.h>
#include <WebCore/PlatformLayer.h>
#include <WebCore/PlatformMediaDecodingType.h>
#include <WebCore/PlatformTextTrack.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/Timer.h>
#include <WebCore/VideoPlaybackQualityMetrics.h>
#include <WebCore/VideoTarget.h>
#include <wtf/AbstractRefCountedAndCanMakeWeakPtr.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/HashSet.h>
#include <wtf/Logger.h>
#include <wtf/MediaTime.h>
#include <wtf/NativePromise.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/StringHash.h>

OBJC_CLASS AVPlayer;
OBJC_CLASS NSArray;

#if USE(AVFOUNDATION)
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;
#endif

namespace WTF {
struct MachSendRightAnnotated;
}

namespace WebCore {

using LayerHostingContextID = uint32_t;

enum class AudioSessionCategory : uint8_t;
enum class DynamicRangeMode : uint8_t;
enum class MediaPlaybackTargetType : uint8_t;

class AudioSourceProvider;
class AudioTrackPrivate;
class CDMInstance;
class CachedResourceLoader;
class ColorSpace;
class GraphicsContextGL;
class GraphicsContext;
class InbandTextTrackPrivate;
class MessageClientForTesting;
class LegacyCDM;
class LegacyCDMSession;
class LegacyCDMSessionClient;
class MediaPlaybackTarget;
class MediaPlayer;
class MediaPlayerFactory;
class MediaPlayerPrivateInterface;
class MediaSourcePrivateClient;
class MediaStreamPrivate;
class NativeImage;
class PlatformMediaResourceLoader;
class MediaResourceSniffer;
class PlatformTimeRanges;
class SecurityOriginData;
class ShareableBitmap;
class SharedBuffer;
class TextTrackRepresentation;
class VideoFrame;
class VideoTrackPrivate;

#if USE(GSTREAMER) && USE(COORDINATED_GRAPHICS)
class CoordinatedPlatformLayerBufferProxy;
#endif

struct GraphicsDeviceAdapter;
struct HostingContext;
struct VideoFrameMetadata;

struct MediaEngineSupportParameters {
    PlatformMediaDecodingType platformType { PlatformMediaDecodingType::FileOrHLS };
    ContentType type;
    URL url { };
    bool requiresRemotePlayback { false };
    bool supportsLimitedMatroska { false };
    Vector<ContentType> contentTypesRequiringHardwareSupport { };
    std::optional<Vector<String>> allowedMediaContainerTypes { };
    std::optional<Vector<String>> allowedMediaCodecTypes { };
    std::optional<Vector<FourCC>> allowedMediaVideoCodecIDs { };
    std::optional<Vector<FourCC>> allowedMediaAudioCodecIDs { };
    std::optional<Vector<FourCC>> allowedMediaCaptionFormatTypes { };
#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    MediaPlaybackTargetType playbackTargetType { MediaPlaybackTargetType::None };
#endif
};

struct MediaPlayerEngineSelection {
    std::optional<MediaPlayerEnums::MediaEngineIdentifier> identifier { };
    // When unset, resolves to Playback in the WebContent process and Supports in the GPU process.
    std::optional<MediaPlayerScope> scope { };
};

struct SeekTarget {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(SeekTarget);
    SeekTarget(const MediaTime& targetTime, const MediaTime& negativeThreshold, const MediaTime& positiveThreshold)
        : time(targetTime)
        , negativeThreshold(negativeThreshold)
        , positiveThreshold(positiveThreshold)
    {
    }
    explicit SeekTarget(const MediaTime& targetTime)
        : time(targetTime)
    {
    }
    SeekTarget() = default;
    static SeekTarget zero() { return { MediaTime::zeroTime(), MediaTime::zeroTime(), MediaTime::zeroTime() }; }

    MediaTime time { MediaTime::invalidTime() };
    MediaTime negativeThreshold { MediaTime::zeroTime() };
    MediaTime positiveThreshold { MediaTime::zeroTime() };

    WEBCORE_EXPORT String toString() const;
};

enum class MediaPlayerType {
    Null,
    Mock,
    MockMSE,
    MediaFoundation,
    AVFObjC,
    AVFObjCMSE,
    AVFObjCMediaStream,
    CocoaWebM,
    GStreamer,
    GStreamerMSE,
    HolePunch,
    WirelessPlayback,
    Remote
};

using TrackID = uint64_t;

struct MediaPlayerLoadOptions {
    ContentType contentType { };
    bool requiresRemotePlayback { false };
    bool supportsLimitedMatroska { false };
    bool disableTeardownOnVisibilityChange { false };
    std::optional<bool> supportsProgressMonitoringOverride { };
    VideoRendererPreferences videoRendererPreferences { };
};

class WEBCORE_EXPORT MediaPlayerClient : public AbstractRefCountedAndCanMakeWeakPtr<MediaPlayerClient> {
public:
    virtual ~MediaPlayerClient() = default;

    // the network state has changed
    virtual void mediaPlayerNetworkStateChanged() { }

    // the ready state has changed
    virtual void mediaPlayerReadyStateChanged() { }

    // the volume state has changed
    virtual void mediaPlayerVolumeChanged() { }

    // the mute state has changed
    virtual void mediaPlayerMuteChanged() { }

    // time has jumped, eg. not as a result of normal playback
    virtual void mediaPlayerTimeChanged() { }

    // the media file duration has changed, or is now known
    virtual void mediaPlayerDurationChanged() { }

    // the playback rate has changed
    virtual void mediaPlayerRateChanged() { }

    // the play/pause status changed
    virtual void mediaPlayerPlaybackStateChanged() { }

    // The MediaPlayer could not discover an engine which supports the requested resource.
    virtual void mediaPlayerResourceNotSupported() { }

    // Presentation-related methods
    // a new frame of video is available
    virtual void mediaPlayerRepaint() { }

    // the movie size has changed
    virtual void mediaPlayerSizeChanged() { }

    virtual void mediaPlayerEngineUpdated() { }

    // The first frame of video is available to render. A media engine need only make this callback if the
    // first frame is not available immediately when prepareForRendering is called.
    virtual void mediaPlayerFirstVideoFrameAvailable() { }

    // A characteristic of the media file, eg. video, audio, closed captions, etc, has changed.
    virtual void mediaPlayerCharacteristicChanged() { }

    // whether the rendering system can accelerate the display of this MediaPlayer.
    virtual bool mediaPlayerRenderingCanBeAccelerated() { return false; }

    // called when the media player's rendering mode changed, which indicates a change in the
    // availability of the platformLayer().
    virtual void mediaPlayerRenderingModeChanged() { }

    // whether accelerated compositing is enabled for video rendering
    virtual bool mediaPlayerAcceleratedCompositingEnabled() { return false; }

    virtual void mediaPlayerActiveSourceBuffersChanged() { }

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    virtual RefPtr<ArrayBuffer> mediaPlayerCachedKeyForKeyId(const String&) const { return nullptr; }
    virtual void mediaPlayerKeyNeeded(const SharedBuffer&) { }
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    virtual String mediaPlayerMediaKeysStorageDirectory() const { return emptyString(); }
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    virtual void mediaPlayerInitializationDataEncountered(const String&, RefPtr<ArrayBuffer>&&) { }
    virtual void mediaPlayerWaitingForKeyChanged() { }
#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    virtual void mediaPlayerCurrentPlaybackTargetIsWirelessChanged(bool) { };
#endif

    virtual void mediaPlayerWillInitializeMediaEngine() { }
    virtual void mediaPlayerDidInitializeMediaEngine() { }

    virtual String mediaPlayerReferrer() const { return String(); }
    virtual String mediaPlayerUserAgent() const { return String(); }
    virtual bool mediaPlayerIsFullscreen() const { return false; }
    virtual bool mediaPlayerIsFullscreenPermitted() const { return false; }
    virtual bool mediaPlayerIsVideo() const { return false; }
    virtual LayoutRect mediaPlayerContentBoxRect() const { return LayoutRect(); }
    virtual float mediaPlayerContentsScale() const { return 1; }
    virtual bool mediaPlayerPlatformVolumeConfigurationRequired() const { return false; }
    virtual bool mediaPlayerIsLooping() const { return false; }
    virtual CachedResourceLoader* mediaPlayerCachedResourceLoader() const { return nullptr; }
    virtual Ref<PlatformMediaResourceLoader> mediaPlayerCreateResourceLoader();
    virtual bool doesHaveAttribute(const AtomString&, AtomString* = nullptr) const { return false; }
    virtual bool mediaPlayerShouldUsePersistentCache() const { return true; }
    virtual String mediaPlayerMediaCacheDirectory() const { return emptyString(); }

    virtual void mediaPlayerDidAddAudioTrack(AudioTrackPrivate&) { }
    virtual void mediaPlayerDidAddTextTrack(InbandTextTrackPrivate&) { }
    virtual void mediaPlayerDidAddVideoTrack(VideoTrackPrivate&) { }
    virtual void mediaPlayerDidRemoveAudioTrack(AudioTrackPrivate&) { }
    virtual void mediaPlayerDidRemoveTextTrack(InbandTextTrackPrivate&) { }
    virtual void mediaPlayerDidRemoveVideoTrack(VideoTrackPrivate&) { }
    virtual void mediaPlayerDidReportGPUMemoryFootprint(size_t) { }

    virtual void mediaPlayerReloadAndResumePlaybackIfNeeded() { }

    virtual void textTrackRepresentationBoundsChanged(const IntRect&) { }

    virtual Vector<Ref<PlatformTextTrack>> outOfBandTrackSources() { return { }; }

#if PLATFORM(IOS_FAMILY)
    virtual String mediaPlayerNetworkInterfaceName() const { return String(); }

    using GetRawCookiesCallback = CompletionHandler<void(Vector<Cookie>&&)>;
    virtual void mediaPlayerGetRawCookies(const URL&, GetRawCookiesCallback&& completionHandler) const { completionHandler({ }); }
#endif

    virtual String mediaPlayerSourceApplicationIdentifier() const { return emptyString(); }

    virtual String mediaPlayerElementId() const { return emptyString(); }

    virtual void mediaPlayerEngineFailedToLoad() { }

    virtual double mediaPlayerRequestedPlaybackRate() const { return 0; }
    virtual MediaPlayerEnums::VideoFullscreenMode mediaPlayerFullscreenMode() const { return MediaPlayerEnums::VideoFullscreenModeNone; }
    virtual bool mediaPlayerIsVideoFullscreenStandby() const { return false; }
    virtual Vector<String> mediaPlayerPreferredAudioCharacteristics() const { return Vector<String>(); }

    virtual bool mediaPlayerShouldDisableSleep() const { return false; }
    virtual const Vector<ContentType>& mediaContentTypesRequiringHardwareSupport() const;
    virtual bool mediaPlayerShouldCheckHardwareSupport() const { return false; }

    virtual const std::optional<Vector<String>>& allowedMediaContainerTypes() const;
    virtual const std::optional<Vector<String>>& allowedMediaCodecTypes() const;
    virtual const std::optional<Vector<FourCC>>& allowedMediaVideoCodecIDs() const;
    virtual const std::optional<Vector<FourCC>>& allowedMediaAudioCodecIDs() const;
    virtual const std::optional<Vector<FourCC>>& allowedMediaCaptionFormatTypes() const;

    virtual void mediaPlayerBufferedTimeRangesChanged() { }
    virtual void mediaPlayerSeekableTimeRangesChanged() { }

    virtual SecurityOriginData documentSecurityOrigin() const { return { }; }

    virtual String audioOutputDeviceId() const { return { }; }
    virtual String audioOutputDeviceIdOverride() const { return { }; }

    virtual void mediaPlayerQueueTaskOnEventLoop(Function<void()>&& task) { callOnMainThread(WTF::move(task)); }

#if PLATFORM(COCOA)
    virtual void mediaPlayerOnNewVideoFrameMetadata(VideoFrameMetadata&&, RetainPtr<CVPixelBufferRef>&&) { }
#endif

    virtual bool mediaPlayerShouldDisableHDR() const { return false; }

    virtual FloatSize mediaPlayerVideoLayerSize() const { return { }; }
    virtual void mediaPlayerVideoLayerSizeDidChange(const FloatSize&) { }

    virtual bool isGStreamerHolePunchingEnabled() const { return false; }

    virtual PlatformVideoTarget mediaPlayerVideoTarget() const { return nullptr; }

    virtual MediaPlayerClientIdentifier mediaPlayerClientIdentifier() const = 0;

    virtual MediaPlayerSoundStageSize mediaPlayerSoundStageSize() const { return MediaPlayerSoundStageSize::Auto; }

#if !RELEASE_LOG_DISABLED
    virtual uint64_t mediaPlayerLogIdentifier() { return 0; }
    virtual const Logger& mediaPlayerLogger() { return emptyLogger(); }
#endif

#if PLATFORM(IOS_FAMILY)
    virtual bool canShowWhileLocked() const { return false; }
#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    virtual MediaPlaybackTargetType playbackTargetType() const { return MediaPlaybackTargetType::None; }
#endif
};

#if PLATFORM(COCOA)
// A MediaPlayerClient for a Swift object conforming to MediaPlayerClientDelegate (SwiftMediaPlayerClientAdapter.swift).
// The values the media engines query are fields here, read without leaving C++; the owner sets them. The members whose
// types Swift can't take are functions the owner sets. Everything else goes to the delegate, which the adapter keeps
// alive.
class WEBCORE_EXPORT SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/SwiftMediaPlayerClientAdapter.swift") SwiftMediaPlayerClientAdapter final
    : public MediaPlayerClient
    , public RefCounted<SwiftMediaPlayerClientAdapter> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(SwiftMediaPlayerClientAdapter, WEBCORE_EXPORT);
public:
    // The box must be a retained delegate box (makeSwiftMediaPlayerClientDelegateBox()), which the adapter releases.
    static Ref<SwiftMediaPlayerClientAdapter> create(MediaPlayerClientIdentifier clientIdentifier, uintptr_t delegateBox) { return adoptRef(*new SwiftMediaPlayerClientAdapter(clientIdentifier, delegateBox)); }
    ~SwiftMediaPlayerClientAdapter();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    void setRenderingCanBeAccelerated(bool value) { m_renderingCanBeAccelerated = value; }
    void setContentsScale(float value) { m_contentsScale = value; }
    void setContentBoxRect(LayoutRect value) { m_contentBoxRect = value; }
    void setIsVideo(bool value) { m_isVideo = value; }
    void setShouldUsePersistentCache(bool value) { m_shouldUsePersistentCache = value; }
    void setShouldDisableHDR(bool value) { m_shouldDisableHDR = value; }
    void setShouldCheckHardwareSupport(bool value) { m_shouldCheckHardwareSupport = value; }
    void setFullscreenMode(MediaPlayerEnums::VideoFullscreenMode value) { m_fullscreenMode = value; }
    void setIsVideoFullscreenStandby(bool value) { m_isVideoFullscreenStandby = value; }
    void setSoundStageSize(MediaPlayerSoundStageSize value) { m_soundStageSize = value; }
    void setPreferredAudioCharacteristics(const Vector<String>& value) { m_preferredAudioCharacteristics = value; }
    void setMediaContentTypesRequiringHardwareSupport(const Vector<ContentType>& value) { m_mediaContentTypesRequiringHardwareSupport = value; }
    void setAllowedMediaContainerTypes(const std::optional<Vector<String>>& value) { m_allowedMediaContainerTypes = value; }
    void setAllowedMediaCodecTypes(const std::optional<Vector<String>>& value) { m_allowedMediaCodecTypes = value; }
    void setAllowedMediaVideoCodecIDs(const std::optional<Vector<FourCC>>& value) { m_allowedMediaVideoCodecIDs = value; }
    void setAllowedMediaAudioCodecIDs(const std::optional<Vector<FourCC>>& value) { m_allowedMediaAudioCodecIDs = value; }
    void setAllowedMediaCaptionFormatTypes(const std::optional<Vector<FourCC>>& value) { m_allowedMediaCaptionFormatTypes = value; }
    void setOutOfBandTrackSources(Vector<Ref<PlatformTextTrack>>&& value) { m_outOfBandTrackSources = WTF::move(value); }
    void setResourceLoaderProvider(Function<RefPtr<PlatformMediaResourceLoader>()>&& provider) { m_resourceLoaderProvider = WTF::move(provider); }
    void setVideoFrameMetadataHandler(Function<void(VideoFrameMetadata&&, RetainPtr<CVPixelBufferRef>&&)>&& handler) { m_videoFrameMetadataHandler = WTF::move(handler); }
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    void setCachedKeyProvider(Function<RefPtr<ArrayBuffer>(const String&)>&& provider) { m_cachedKeyProvider = WTF::move(provider); }
#endif
#if ENABLE(ENCRYPTED_MEDIA)
    void setInitializationDataHandler(Function<void(const String&, RefPtr<ArrayBuffer>&&)>&& handler) { m_initializationDataHandler = WTF::move(handler); }
#endif
#if PLATFORM(IOS_FAMILY)
    void setNetworkInterfaceName(const String& value) { m_networkInterfaceName = value; }
    void setRawCookiesProvider(Function<void(const URL&, GetRawCookiesCallback&&)>&& provider) { m_rawCookiesProvider = WTF::move(provider); }
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    void setVideoTargetProvider(Function<PlatformVideoTarget()>&& provider) { m_videoTargetProvider = WTF::move(provider); }
#endif
#if !RELEASE_LOG_DISABLED
    void setLogger(const Logger& logger, uint64_t logIdentifier)
    {
        m_logger = &logger;
        m_logIdentifier = logIdentifier;
    }
#endif

    bool mediaPlayerRenderingCanBeAccelerated() final { return m_renderingCanBeAccelerated; }
    float mediaPlayerContentsScale() const final { return m_contentsScale; }
    LayoutRect mediaPlayerContentBoxRect() const final { return m_contentBoxRect; }
    bool mediaPlayerIsVideo() const final { return m_isVideo; }
    bool mediaPlayerShouldUsePersistentCache() const final { return m_shouldUsePersistentCache; }
    bool mediaPlayerShouldDisableHDR() const final { return m_shouldDisableHDR; }
    bool mediaPlayerShouldCheckHardwareSupport() const final { return m_shouldCheckHardwareSupport; }
    MediaPlayerEnums::VideoFullscreenMode mediaPlayerFullscreenMode() const final { return m_fullscreenMode; }
    bool mediaPlayerIsVideoFullscreenStandby() const final { return m_isVideoFullscreenStandby; }
    MediaPlayerSoundStageSize mediaPlayerSoundStageSize() const final { return m_soundStageSize; }
    MediaPlayerClientIdentifier mediaPlayerClientIdentifier() const final { return m_clientIdentifier; }

private:
    SwiftMediaPlayerClientAdapter(MediaPlayerClientIdentifier clientIdentifier, uintptr_t delegateBox)
        : m_delegateBox(delegateBox)
        , m_clientIdentifier(clientIdentifier)
    {
    }

    SWIFT_UNSAFE static void releaseDelegateBox(uintptr_t);

    String mediaPlayerReferrer() const final;
    String mediaPlayerUserAgent() const final;
    String mediaPlayerSourceApplicationIdentifier() const final;
    String audioOutputDeviceId() const final;
    String audioOutputDeviceIdOverride() const final { return audioOutputDeviceId(); }
    Vector<String> mediaPlayerPreferredAudioCharacteristics() const final { return m_preferredAudioCharacteristics; }
    const Vector<ContentType>& mediaContentTypesRequiringHardwareSupport() const final { return m_mediaContentTypesRequiringHardwareSupport; }
    const std::optional<Vector<String>>& allowedMediaContainerTypes() const final { return m_allowedMediaContainerTypes; }
    const std::optional<Vector<String>>& allowedMediaCodecTypes() const final { return m_allowedMediaCodecTypes; }
    const std::optional<Vector<FourCC>>& allowedMediaVideoCodecIDs() const final { return m_allowedMediaVideoCodecIDs; }
    const std::optional<Vector<FourCC>>& allowedMediaAudioCodecIDs() const final { return m_allowedMediaAudioCodecIDs; }
    const std::optional<Vector<FourCC>>& allowedMediaCaptionFormatTypes() const final { return m_allowedMediaCaptionFormatTypes; }
#if PLATFORM(IOS_FAMILY)
    String mediaPlayerNetworkInterfaceName() const final { return m_networkInterfaceName; }
#endif
#if !RELEASE_LOG_DISABLED
    uint64_t mediaPlayerLogIdentifier() final { return m_logIdentifier; }
    const Logger& mediaPlayerLogger() final { return m_logger ? *m_logger : MediaPlayerClient::mediaPlayerLogger(); }
#endif

    void mediaPlayerNetworkStateChanged() final;
    void mediaPlayerReadyStateChanged() final;
    void mediaPlayerVolumeChanged() final;
    void mediaPlayerMuteChanged() final;
    void mediaPlayerTimeChanged() final;
    void mediaPlayerDurationChanged() final;
    void mediaPlayerRateChanged() final;
    void mediaPlayerPlaybackStateChanged() final;
    void mediaPlayerResourceNotSupported() final;
    void mediaPlayerSizeChanged() final;
    void mediaPlayerFirstVideoFrameAvailable() final;
    void mediaPlayerCharacteristicChanged() final;
    void mediaPlayerRenderingModeChanged() final;
    void mediaPlayerEngineFailedToLoad() final;
    void mediaPlayerBufferedTimeRangesChanged() final;
    void mediaPlayerSeekableTimeRangesChanged() final;
    SWIFT_MAIN_ACTOR void mediaPlayerDidAddAudioTrack(AudioTrackPrivate&) final;
    SWIFT_MAIN_ACTOR void mediaPlayerDidRemoveAudioTrack(AudioTrackPrivate&) final;
    SWIFT_MAIN_ACTOR void mediaPlayerDidAddVideoTrack(VideoTrackPrivate&) final;
    SWIFT_MAIN_ACTOR void mediaPlayerDidRemoveVideoTrack(VideoTrackPrivate&) final;
    SWIFT_MAIN_ACTOR void mediaPlayerDidAddTextTrack(InbandTextTrackPrivate&) final;
    SWIFT_MAIN_ACTOR void mediaPlayerDidRemoveTextTrack(InbandTextTrackPrivate&) final;
    String mediaPlayerMediaCacheDirectory() const final;
    FloatSize mediaPlayerVideoLayerSize() const final;
    Vector<Ref<PlatformTextTrack>> outOfBandTrackSources() final { return m_outOfBandTrackSources; }
    Ref<PlatformMediaResourceLoader> mediaPlayerCreateResourceLoader() final;

    void mediaPlayerOnNewVideoFrameMetadata(VideoFrameMetadata&& metadata, RetainPtr<CVPixelBufferRef>&& pixelBuffer) final
    {
        if (m_videoFrameMetadataHandler)
            m_videoFrameMetadataHandler(WTF::move(metadata), WTF::move(pixelBuffer));
    }

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    RefPtr<ArrayBuffer> mediaPlayerCachedKeyForKeyId(const String& keyId) const final;
    void mediaPlayerKeyNeeded(const SharedBuffer&) final;
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
    String mediaPlayerMediaKeysStorageDirectory() const final;
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void mediaPlayerInitializationDataEncountered(const String& initDataType, RefPtr<ArrayBuffer>&& initData) final
    {
        if (m_initializationDataHandler)
            m_initializationDataHandler(initDataType, WTF::move(initData));
    }
    void mediaPlayerWaitingForKeyChanged() final;
#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    void mediaPlayerCurrentPlaybackTargetIsWirelessChanged(bool) final;
    MediaPlaybackTargetType playbackTargetType() const final;
#endif

#if PLATFORM(IOS_FAMILY)
    void mediaPlayerGetRawCookies(const URL&, GetRawCookiesCallback&&) const final;
#endif

#if ENABLE(LINEAR_MEDIA_PLAYER)
    PlatformVideoTarget mediaPlayerVideoTarget() const final { return m_videoTargetProvider ? m_videoTargetProvider() : nullptr; }
#endif

    const uintptr_t m_delegateBox;
    const MediaPlayerClientIdentifier m_clientIdentifier;
    bool m_renderingCanBeAccelerated { false };
    float m_contentsScale { 1 };
    LayoutRect m_contentBoxRect;
    bool m_isVideo { false };
    bool m_shouldUsePersistentCache { true };
    bool m_shouldDisableHDR { false };
    bool m_shouldCheckHardwareSupport { false };
    MediaPlayerEnums::VideoFullscreenMode m_fullscreenMode { MediaPlayerEnums::VideoFullscreenModeNone };
    bool m_isVideoFullscreenStandby { false };
    MediaPlayerSoundStageSize m_soundStageSize { MediaPlayerSoundStageSize::Auto };
    Vector<String> m_preferredAudioCharacteristics;
    Vector<ContentType> m_mediaContentTypesRequiringHardwareSupport;
    std::optional<Vector<String>> m_allowedMediaContainerTypes;
    std::optional<Vector<String>> m_allowedMediaCodecTypes;
    std::optional<Vector<FourCC>> m_allowedMediaVideoCodecIDs;
    std::optional<Vector<FourCC>> m_allowedMediaAudioCodecIDs;
    std::optional<Vector<FourCC>> m_allowedMediaCaptionFormatTypes;
    Vector<Ref<PlatformTextTrack>> m_outOfBandTrackSources;
    Function<RefPtr<PlatformMediaResourceLoader>()> m_resourceLoaderProvider;
    Function<void(VideoFrameMetadata&&, RetainPtr<CVPixelBufferRef>&&)> m_videoFrameMetadataHandler;
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    Function<RefPtr<ArrayBuffer>(const String&)> m_cachedKeyProvider;
#endif
#if ENABLE(ENCRYPTED_MEDIA)
    Function<void(const String&, RefPtr<ArrayBuffer>&&)> m_initializationDataHandler;
#endif
#if PLATFORM(IOS_FAMILY)
    String m_networkInterfaceName;
    Function<void(const URL&, GetRawCookiesCallback&&)> m_rawCookiesProvider;
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    Function<PlatformVideoTarget()> m_videoTargetProvider;
#endif
#if !RELEASE_LOG_DISABLED
    RefPtr<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
};

#endif // PLATFORM(COCOA)

class WEBCORE_EXPORT MediaPlayer : public MediaPlayerEnums, public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<MediaPlayer, WTF::DestructionThread::Main> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(MediaPlayer, WEBCORE_EXPORT);
    WTF_MAKE_NONCOPYABLE(MediaPlayer);
public:
    NODELETE static Ref<MediaPlayer> create(MediaPlayerClient&);
    NODELETE static Ref<MediaPlayer> create(MediaPlayerClient&, MediaPlayerEnums::MediaEngineIdentifier);
    ~MediaPlayer();

    void invalidate();

    // Media engine support.
    using MediaPlayerEnums::SupportsType;
    static const MediaPlayerFactory* mediaEngine(const MediaPlayerEngineSelection& = { });
    static SupportsType supportsType(const MediaEngineSupportParameters&, const MediaPlayerEngineSelection& = { });
    static void getSupportedTypes(HashSet<String>&);
    static bool isAvailable();
    static HashSet<SecurityOriginData> originsInMediaCache(const String& path);
    static void clearMediaCache(const String& path, WallTime modifiedSince);
    static void clearMediaCacheForOrigins(const String& path, const HashSet<SecurityOriginData>&);
    static bool supportsKeySystem(const String& keySystem, const String& mimeType);

    bool supportsPictureInPicture() const;
    bool supportsFullscreen() const;
    bool supportsScanning() const;
    bool canSaveMediaData() const;
    bool supportsProgressMonitoring() const;
    bool requiresImmediateCompositing() const;
    bool doesHaveAttribute(const AtomString&, AtomString* value = nullptr) const;
    PlatformLayer* platformLayer() const;

    void reloadAndResumePlaybackIfNeeded();

#if ENABLE(VIDEO_PRESENTATION_MODE)
    RetainPtr<PlatformLayer> createVideoFullscreenLayer();
    void setVideoFullscreenLayer(PlatformLayer*, Function<void()>&& completionHandler = [] { });
    void setVideoFullscreenFrame(const FloatRect&);
    void updateVideoFullscreenInlineImage();
    using MediaPlayerEnums::VideoGravity;
    void setVideoFullscreenGravity(VideoGravity);
    void setVideoFullscreenMode(VideoFullscreenMode);
    VideoFullscreenMode fullscreenMode() const;
    void videoFullscreenStandbyChanged();
    bool isVideoFullscreenStandby() const;
#endif

    using HostingContextPromise = NativePromise<HostingContext, void, WTF::PromiseOption::Default | WTF::PromiseOption::WithoutCrossThreadCopy>;
    Ref<HostingContextPromise> requestHostingContext();
    HostingContext hostingContext() const;
    FloatSize videoLayerSize() const;
    void videoLayerSizeDidChange(const FloatSize&);
    void setVideoLayerSizeFenced(const FloatSize&, WTF::MachSendRightAnnotated&&);

#if PLATFORM(IOS_FAMILY)
    NSArray *timedMetadata() const;
    String accessLog() const;
    String errorLog() const;
#endif

    FloatSize naturalSize();
    bool hasVideo() const;
    bool hasAudio() const;

    IntSize presentationSize() const { return m_presentationSize; }
    void setPresentationSize(const IntSize& size);

    using LoadOptions = MediaPlayerLoadOptions;
    bool load(const URL&, const LoadOptions&);
#if ENABLE(MEDIA_SOURCE)
    bool load(const URL&, const LoadOptions&, MediaSourcePrivateClient&);
#endif
#if ENABLE(MEDIA_STREAM)
    bool load(MediaStreamPrivate&);
#endif
    void cancelLoad();

    bool pageIsVisible() const { return m_pageIsVisible; }
    void setPageIsVisible(bool);
    void setVisibleForCanvas(bool);
    bool isVisibleForCanvas() const { return m_visibleForCanvas; }

    void setViewportVisibility(ViewportVisibility);
    ViewportVisibility viewportVisibility() const { return m_viewportVisibility; }

    void prepareToPlay();
    void play();
    void pause();

    using MediaPlayerEnums::BufferingPolicy;
    void setBufferingPolicy(BufferingPolicy);

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    // Represents synchronous exceptions that can be thrown from the Encrypted Media methods.
    // This is different from the asynchronous MediaKeyError.
    enum MediaKeyException { NoError, InvalidPlayerState, KeySystemNotSupported };

    RefPtr<LegacyCDMSession> createSession(const String& keySystem, LegacyCDMSessionClient&);
    void setCDM(LegacyCDM*);
    void setCDMSession(LegacyCDMSession*);
    void keyAdded();
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void cdmInstanceAttached(CDMInstance&);
    void cdmInstanceDetached(CDMInstance&);
    void attemptToDecryptWithInstance(CDMInstance&);
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) && ENABLE(ENCRYPTED_MEDIA)
    void setShouldContinueAfterKeyNeeded(bool);
    bool shouldContinueAfterKeyNeeded() const { return m_shouldContinueAfterKeyNeeded; }
#endif

    void queueTaskOnEventLoop(Function<void()>&&);

    bool paused() const;
    void willSeekToTarget(const MediaTime&);
    void seekWhenPossible(const MediaTime&);
    Ref<MediaTimePromise> seekToTarget(const SeekTarget&);

    static double invalidTime() { return -1.0; }
    MediaTime duration() const;
    MediaTime currentTime() const;

    using CurrentTimeDidChangeCallback = std::function<void(const MediaTime&)>;
    bool setCurrentTimeDidChangeCallback(CurrentTimeDidChangeCallback&&);
    bool timeIsProgressing() const;

    MediaTime startTime() const;
    MediaTime initialTime() const;

    MediaTime getStartDate() const;

    double rate() const;
    void setRate(double);
    double effectiveRate() const;

    double requestedRate() const;

    bool supportsPlayAtHostTime() const;
    bool supportsPauseAtHostTime() const;
    bool playAtHostTime(const MonotonicTime&);
    bool pauseAtHostTime(const MonotonicTime&);

    NODELETE bool preservesPitch() const;
    void setPreservesPitch(bool);

    void setPitchCorrectionAlgorithm(PitchCorrectionAlgorithm);
    PitchCorrectionAlgorithm pitchCorrectionAlgorithm() const { return m_pitchCorrectionAlgorithm; }

    const PlatformTimeRanges& buffered() const;
    const PlatformTimeRanges& seekable() const;
    void bufferedTimeRangesChanged();
    void seekableTimeRangesChanged();
    MediaTime minTimeSeekable() const;
    MediaTime maxTimeSeekable() const;

    double seekableTimeRangesLastModifiedTime();
    double liveUpdateInterval();

    using DidLoadingProgressCompletionHandler = CompletionHandler<void(bool)>;
    void didLoadingProgress(DidLoadingProgressCompletionHandler&&) const;

    void setVolumeLocked(bool);

    NODELETE double volume() const;
    void setVolume(double);
    bool platformVolumeConfigurationRequired() const { return protect(client())->mediaPlayerPlatformVolumeConfigurationRequired(); }

    NODELETE bool muted() const;
    void setMuted(bool);

    bool hasClosedCaptions() const;
    void setClosedCaptionsVisible(bool closedCaptionsVisible);

    void paint(GraphicsContext&, const FloatRect& destination);
    void paintCurrentFrameInContext(GraphicsContext&, const FloatRect& destination);

    RefPtr<VideoFrame> videoFrameForCurrentTime();
    RefPtr<NativeImage> nativeImageForCurrentTime();
    RefPtr<ShareableBitmap> bitmapImageForCurrentTimeSync();
    using BitmapImagePromise = NativePromise<Ref<ShareableBitmap>, void>;
    Ref<BitmapImagePromise> bitmapImageForCurrentTime();
    ColorSpace colorSpace();
    bool shouldGetNativeImageForCanvasDrawing() const;

    using MediaPlayerEnums::NetworkState;
    NetworkState networkState();

    using MediaPlayerEnums::ReadyState;
    ReadyState readyState() const;

    using MediaPlayerEnums::MovieLoadType;
    MovieLoadType movieLoadType() const;

    using MediaPlayerEnums::Preload;
    NODELETE Preload preload() const;
    void setPreload(Preload);

    void networkStateChanged();
    void readyStateChanged();
    void volumeChanged(double);
    void muteChanged(bool);
    void timeChanged();
    void sizeChanged();
    void rateChanged();
    void playbackStateChanged();
    void durationChanged();
    void firstVideoFrameAvailable();
    void characteristicChanged();

    void repaint();

    bool hasAvailableVideoFrame() const;
    bool videoFrameHasAlpha() const;
    void prepareForRendering();

    using MediaPlayerEnums::WirelessPlaybackTargetType;
#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    WirelessPlaybackTargetType wirelessPlaybackTargetType() const;

    String wirelessPlaybackTargetName() const;
    String wirelessPlaybackRouteName() const;

    bool wirelessVideoPlaybackDisabled() const;
    void setWirelessVideoPlaybackDisabled(bool);

    void currentPlaybackTargetIsWirelessChanged(bool);
    void playbackTargetAvailabilityChanged();

    bool isCurrentPlaybackTargetWireless() const;
    OptionSet<MediaPlaybackTargetType> supportedPlaybackTargetTypes() const;
    void setWirelessPlaybackTarget(Ref<MediaPlaybackTarget>&&);

    void setShouldPlayToPlaybackTarget(bool);
#endif

    double minFastReverseRate() const;
    double maxFastForwardRate() const;

    // whether accelerated rendering is supported by the media engine for the current media.
    bool supportsAcceleratedRendering() const;
    // called when the rendering system flips the into or out of accelerated rendering mode.
    void acceleratedRenderingStateChanged();

    void setShouldMaintainAspectRatio(bool);

    bool didPassCORSAccessCheck() const;
    bool isCrossOrigin(const SecurityOrigin&) const;

    MediaTime mediaTimeForTimeValue(const MediaTime&) const;

    unsigned decodedFrameCount() const;
    unsigned droppedFrameCount() const;
    unsigned audioDecodedByteCount() const;
    unsigned videoDecodedByteCount() const;

    void setPrivateBrowsingMode(bool);
    bool inPrivateBrowsingMode() const { return m_inPrivateBrowsingMode; }

#if ENABLE(WEB_AUDIO)
    AudioSourceProvider* audioSourceProvider();
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    RefPtr<ArrayBuffer> cachedKeyForKeyId(const String& keyId) const;
    void keyNeeded(const SharedBuffer& initData);
    String mediaKeysStorageDirectory() const;
#endif

#if ENABLE(ENCRYPTED_MEDIA)
    void initializationDataEncountered(const String&, RefPtr<ArrayBuffer>&&);
    void waitingForKeyChanged();
    bool waitingForKey() const;
#endif

    String referrer() const;
    String userAgent() const;

    String engineDescription() const;
    long platformErrorCode() const;

    String elementId() const;

    CachedResourceLoader* cachedResourceLoader() const;
    Ref<PlatformMediaResourceLoader> mediaResourceLoader();

    void addAudioTrack(AudioTrackPrivate&);
    void addTextTrack(InbandTextTrackPrivate&);
    void addVideoTrack(VideoTrackPrivate&);
    void removeAudioTrack(AudioTrackPrivate&);
    void removeTextTrack(InbandTextTrackPrivate&);
    void removeVideoTrack(VideoTrackPrivate&);

#if PLATFORM(COCOA)
    void onNewVideoFrameMetadata(VideoFrameMetadata&&, RetainPtr<CVPixelBufferRef>&&);
#endif

    void setTextTrackRepresentation(TextTrackRepresentation*);
    void syncTextTrackBounds();
    void tracksChanged();

    void notifyTrackModeChanged();
    Vector<Ref<PlatformTextTrack>> outOfBandTrackSources();

#if PLATFORM(IOS_FAMILY)
    String mediaPlayerNetworkInterfaceName() const;
    void getRawCookies(const URL&, MediaPlayerClient::GetRawCookiesCallback&&) const;
#endif

    static void resetMediaEngines();
    void reset();

#if USE(GSTREAMER)
    void simulateAudioInterruption();
    bool isGStreamerHolePunchingEnabled();
#if USE(COORDINATED_GRAPHICS)
    void setPlatformLayerBufferProxy(Ref<CoordinatedPlatformLayerBufferProxy>&&);
    RefPtr<CoordinatedPlatformLayerBufferProxy> platformLayerBufferProxy() const;
#endif
#endif

    String languageOfPrimaryAudioTrack() const;

    size_t extraMemoryCost() const;

    void reportGPUMemoryFootprint(uint64_t) const;

    unsigned long long fileSize() const;

    std::optional<VideoPlaybackQualityMetrics> videoPlaybackQualityMetrics();
    using VideoPlaybackQualityMetricsPromise = NativePromise<VideoPlaybackQualityMetrics, PlatformMediaError>;
    Ref<VideoPlaybackQualityMetricsPromise> asyncVideoPlaybackQualityMetrics();

    String sourceApplicationIdentifier() const;
    Vector<String> preferredAudioCharacteristics() const;

    bool ended() const;

    void setShouldDisableSleep(bool);
    bool shouldDisableSleep() const;

    const ContentType& contentType() const LIFETIME_BOUND { return m_loadOptions.contentType; }
    String contentMIMEType() const;
    String contentTypeCodecs() const;
    NODELETE bool contentMIMETypeWasInferredFromExtension() const;

    const Vector<ContentType>& mediaContentTypesRequiringHardwareSupport() const;
    void setShouldCheckHardwareSupport(bool);

    const std::optional<Vector<String>>& allowedMediaContainerTypes() const;
    const std::optional<Vector<String>>& allowedMediaCodecTypes() const;
    const std::optional<Vector<FourCC>>& allowedMediaVideoCodecIDs() const;
    const std::optional<Vector<FourCC>>& allowedMediaAudioCodecIDs() const;
    const std::optional<Vector<FourCC>>& allowedMediaCaptionFormatTypes() const;

#if !RELEASE_LOG_DISABLED
    const Logger& mediaPlayerLogger();
    uint64_t mediaPlayerLogIdentifier() { return protect(client())->mediaPlayerLogIdentifier(); }
#endif

    void applicationWillResignActive();
    void applicationDidBecomeActive();

#if USE(AVFOUNDATION)
    AVPlayer *objCAVFoundationAVPlayer() const;
#endif

    bool performTaskAtTime(Function<void(const MediaTime&)>&&, const MediaTime&);

    bool shouldIgnoreIntrinsicSize();

    bool renderingCanBeAccelerated() const { return protect(client())->mediaPlayerRenderingCanBeAccelerated(); }
    void renderingModeChanged() const  { protect(client())->mediaPlayerRenderingModeChanged(); }
    bool acceleratedCompositingEnabled() { return protect(client())->mediaPlayerAcceleratedCompositingEnabled(); }
    void activeSourceBuffersChanged() { protect(client())->mediaPlayerActiveSourceBuffersChanged(); }
    LayoutRect playerContentBoxRect() const { return protect(client())->mediaPlayerContentBoxRect(); }
    float playerContentsScale() const { return protect(client())->mediaPlayerContentsScale(); }
    bool shouldUsePersistentCache() const { return protect(client())->mediaPlayerShouldUsePersistentCache(); }
    String mediaCacheDirectory() const { return protect(client())->mediaPlayerMediaCacheDirectory(); }
    bool isVideoPlayer() const { return protect(client())->mediaPlayerIsVideo(); }
    void mediaEngineUpdated() { protect(client())->mediaPlayerEngineUpdated(); }
    void resourceNotSupported() { protect(client())->mediaPlayerResourceNotSupported(); }
    bool isLooping() const { return protect(client())->mediaPlayerIsLooping(); }
    void isLoopingChanged();

    void remoteEngineFailedToLoad();
    SecurityOriginData documentSecurityOrigin() const;

    NODELETE const MediaPlayerPrivateInterface* playerPrivate() const;
    NODELETE MediaPlayerPrivateInterface* playerPrivate();

    DynamicRangeMode preferredDynamicRangeMode() const { return m_preferredDynamicRangeMode; }
    void setPreferredDynamicRangeMode(DynamicRangeMode);
    PlatformDynamicRangeLimit platformDynamicRangeLimit() const { return m_platformDynamicRangeLimit; }
    void setPlatformDynamicRangeLimit(PlatformDynamicRangeLimit);

    String audioOutputDeviceId() const;
    String audioOutputDeviceIdOverride() const;
    void audioOutputDeviceChanged();

    std::optional<MediaPlayerIdentifier> identifier() const;
    bool isHostedInGPUProcess() const;
    bool hasMediaEngine() const;

    std::optional<VideoFrameMetadata> videoFrameMetadata();
    void startVideoFrameMetadataGathering();
    void stopVideoFrameMetadataGathering();
    bool isGatheringVideoFrameMetadata() const { return m_isGatheringVideoFrameMetadata; }

    void playerContentBoxRectChanged(const LayoutRect&);

    NODELETE String lastErrorMessage() const;

    void renderVideoWillBeDestroyed();

    void setShouldDisableHDR(bool);
    bool shouldDisableHDR() const { return protect(client())->mediaPlayerShouldDisableHDR(); }

    void setResourceOwner(const ProcessIdentity&);

    void setVideoTarget(const PlatformVideoTarget&);

#if HAVE(SPATIAL_TRACKING_LABEL)
    String defaultSpatialTrackingLabel() const;
    void setDefaultSpatialTrackingLabel(const String&);

    String spatialTrackingLabel() const;
    void setSpatialTrackingLabel(const String&);
#endif

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    void setPrefersSpatialAudioExperience(bool);
    bool prefersSpatialAudioExperience() const { return m_prefersSpatialAudioExperience; }
#endif

    SoundStageSize soundStageSize() const;
    void soundStageSizeDidChange();

    void setInFullscreenOrPictureInPicture(bool);
    NODELETE bool isInFullscreenOrPictureInPicture() const;

    PlatformVideoTarget videoTarget() const { return protect(client())->mediaPlayerVideoTarget(); }
    MediaPlayerClientIdentifier clientIdentifier() const { return protect(client())->mediaPlayerClientIdentifier(); }

#if ENABLE(LINEAR_MEDIA_PLAYER)
    bool supportsLinearMediaPlayer() const;
#endif

#if PLATFORM(IOS_FAMILY)
    bool canShowWhileLocked() const;
    void setSceneIdentifier(const String&);
    const String& sceneIdentifier() const LIFETIME_BOUND { return m_sceneIdentifier; }
#endif

    void setMessageClientForTesting(WeakPtr<MessageClientForTesting>);
    NODELETE MessageClientForTesting* messageClientForTesting() const;

    void elementIdChanged(const String&) const;

#if PLATFORM(MAC)
    void setScreenReserved(bool);
    bool screenReserved() { return m_screenReserved; }
#endif

private:
    MediaPlayer(MediaPlayerClient&);
    MediaPlayer(MediaPlayerClient&, MediaPlayerEnums::MediaEngineIdentifier);

    MediaPlayerClient& client() const { return *m_client; }


    CheckedPtr<const MediaPlayerFactory> nextBestMediaEngine(const MediaPlayerFactory*);
    void loadWithNextMediaEngine(const MediaPlayerFactory*);
    CheckedPtr<const MediaPlayerFactory> nextMediaEngine(const MediaPlayerFactory*);
    void reloadTimerFired();
    void setPlayerPrivate(RefPtr<MediaPlayerPrivateInterface>&&);

    // When the engine fallback chain is exhausted on FormatError/DecodeError and we haven't yet
    // sniffed the body, fetch a short prefix of the resource, determine the actual Content-Type
    // from magic bytes, and — if it differs from what we originally tried — re-run engine
    // selection with the sniffed type. Returns true if a sniff was started (in which case the
    // caller should defer reporting the failure up to the client until the sniff settles).
    bool attemptSniffAndReload();
    void cancelSniffer();

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    MediaPlaybackTargetType playbackTargetType() const;
#endif

    void seekToTime(const MediaTime&);

    WeakPtr<MediaPlayerClient> m_client;
    Timer m_reloadTimer;
    // Read on the audio render thread through audioSourceProvider(). Write it only through
    // setPlayerPrivate().
    RefPtr<MediaPlayerPrivateInterface> m_private;
    WeakPtr<const MediaPlayerFactory> m_currentMediaEngine;
    WeakHashSet<const MediaPlayerFactory> m_attemptedEngines;
    URL m_url;
    LoadOptions m_loadOptions;
    std::optional<MediaPlayerEnums::MediaEngineIdentifier> m_activeEngineIdentifier;
    std::optional<MediaTime> m_pendingSeekRequest;
    IntSize m_presentationSize;
    Preload m_preload { Preload::Auto };
    double m_volume { 1 };
    bool m_pageIsVisible { false };
    bool m_visibleForCanvas { false };
    bool m_muted { false };
    bool m_preservesPitch { true };
    bool m_inPrivateBrowsingMode { false };
    bool m_shouldPrepareToPlay { false };
    bool m_shouldPrepareToRender { false };
    bool m_initializingMediaEngine { false };
    DynamicRangeMode m_preferredDynamicRangeMode;
    PlatformDynamicRangeLimit m_platformDynamicRangeLimit { PlatformDynamicRangeLimit::initialValueForVideos() };
    PitchCorrectionAlgorithm m_pitchCorrectionAlgorithm { PitchCorrectionAlgorithm::BestAllAround };
    ViewportVisibility m_viewportVisibility { ViewportVisibility::NotVisible };
    const RefPtr<PlatformMediaResourceLoader> m_mediaResourceLoader;
    RefPtr<MediaResourceSniffer> m_sniffer;
    bool m_sniffAttempted { false };

#if ENABLE(MEDIA_SOURCE)
    ThreadSafeWeakPtr<MediaSourcePrivateClient> m_mediaSource;
#endif
#if ENABLE(MEDIA_STREAM)
    RefPtr<MediaStreamPrivate> m_mediaStream;
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA) && ENABLE(ENCRYPTED_MEDIA)
    bool m_shouldContinueAfterKeyNeeded { false };
#endif
    std::atomic<bool> m_isGatheringVideoFrameMetadata { false };

#if HAVE(SPATIAL_TRACKING_LABEL)
    String m_defaultSpatialTrackingLabel;
    String m_spatialTrackingLabel;
#endif

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    bool m_prefersSpatialAudioExperience { false };
#endif

    bool m_isInFullscreenOrPictureInPicture { false };

    String m_lastErrorMessage;
    ProcessIdentity m_processIdentity;

#if PLATFORM(IOS_FAMILY)
    String m_sceneIdentifier;
#endif

    WeakPtr<MessageClientForTesting> m_internalMessageClient;

#if PLATFORM(MAC)
    bool m_screenReserved { false };
#endif

public:
#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::ref(); }
    void deref() const { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::deref(); }
#endif
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

class MediaPlayerFactory : public CanMakeWeakPtr<MediaPlayerFactory>, public CanMakeCheckedPtr<MediaPlayerFactory> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(MediaPlayerFactory, WEBCORE_EXPORT);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(MediaPlayerFactory);
public:
    MediaPlayerFactory() = default;
    virtual ~MediaPlayerFactory() = default;

    virtual MediaPlayerEnums::MediaEngineIdentifier identifier() const  = 0;
    virtual Ref<MediaPlayerPrivateInterface> createMediaEnginePlayer(MediaPlayer&) const = 0;
    virtual void getSupportedTypes(HashSet<String>&) const = 0;
    virtual MediaPlayer::SupportsType supportsTypeAndCodecs(const MediaEngineSupportParameters&) const = 0;

    virtual HashSet<SecurityOriginData> originsInMediaCache(const String&) const { return { }; }
    virtual void clearMediaCache(const String&, WallTime) const { }
    virtual void clearMediaCacheForOrigins(const String&, const HashSet<SecurityOriginData>&) const { }
    virtual bool supportsKeySystem(const String& /* keySystem */, const String& /* mimeType */) const { return false; }

    // Describes how this factory may be used. Default is Playback; subclasses
    // override only if they need to answer differently for some contexts.
    virtual MediaPlayerScope supportedScope() const { return MediaPlayerScope::Playback; }
};

using MediaEngineRegistrar = void(std::unique_ptr<MediaPlayerFactory>&&);
using MediaEngineRegister = void(MediaEngineRegistrar);

class MediaPlayerFactorySupport {
public:
    WEBCORE_EXPORT static void callRegisterMediaEngine(MediaEngineRegister);
};

class RemoteMediaPlayerSupport {
public:
    using RegisterRemotePlayerCallback = Function<void(MediaEngineRegistrar, MediaPlayerEnums::MediaEngineIdentifier, PlatformMediaDecodingType)>;
    WEBCORE_EXPORT static void setRegisterRemotePlayerCallback(RegisterRemotePlayerCallback&&);

    // If a remote-player callback has been installed (i.e. this is the WebContent
    // process and a GPU process is available), register a remote proxy factory for
    // the given engine and return true. Otherwise return false and leave the
    // caller to register a local factory.
    WEBCORE_EXPORT static bool registerRemoteEngineIfAvailable(MediaEngineRegistrar, MediaPlayerEnums::MediaEngineIdentifier, PlatformMediaDecodingType);
};

inline String MediaPlayer::audioOutputDeviceId() const
{
    RefPtr client = m_client.get();
    return client ? client->audioOutputDeviceId() : String { };
}

inline String MediaPlayer::audioOutputDeviceIdOverride() const
{
    RefPtr client = m_client.get();
    return client ? client->audioOutputDeviceIdOverride() : String { };
}

inline bool MediaPlayer::hasMediaEngine() const
{
    return static_cast<bool>(m_currentMediaEngine);
}

} // namespace WebCore

using WebCore::TrackID;

namespace WTF {

template<typename> struct LogArgument;
template<> struct LogArgument<WebCore::SeekTarget> {
    static String toString(const WebCore::SeekTarget& target) { return target.toString(); }
};

} // namespace WTF

#endif // ENABLE(VIDEO)
