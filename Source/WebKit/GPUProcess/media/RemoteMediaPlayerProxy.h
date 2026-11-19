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
#include "MessageReceiver.h"
#include "RemoteMediaPlayerConfiguration.h"
#include "RemoteMediaPlayerProxyConfiguration.h"
#include "RemoteMediaPlayerState.h"
#include "RemoteMediaResourceLoaderIdentifier.h"
#include "RemoteVideoFrameProxy.h"
#include "SandboxExtension.h"
#include "ScopedRenderingResourcesRequest.h"
#include <WebCore/InbandTextTrackPrivate.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/MessageClientForTesting.h>
#include <WebCore/PlatformDynamicRangeLimit.h>
#include <WebCore/ShareableBitmap.h>
#include <optional>
#include <wtf/LoggerHelper.h>
#include <wtf/NativePromiseSettler.h>
#include <wtf/RefCountable.h>
#include <wtf/RefPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

#if USE(AVFOUNDATION)
#include <wtf/RetainPtr.h>
#endif

namespace WTF {
class MachSendRight;
}

namespace WebCore {
class LegacyCDMSessionClientSwiftAdapter;
struct MediaPlayerLoadOptions;
class SecurityOriginData;
class VideoFrame;
}

#if USE(AVFOUNDATION)
typedef struct __CVBuffer* CVPixelBufferRef;
#endif

namespace WebKit {

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
    , public CanMakeWeakPtr<RemoteMediaPlayerProxy>
    , private WebCore::MessageClientForTesting
    , private IPC::MessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteMediaPlayerProxy);
public:
    USING_CAN_MAKE_WEAKPTR(CanMakeWeakPtr<RemoteMediaPlayerProxy>);

    static Ref<RemoteMediaPlayerProxy> create(RemoteMediaPlayerManagerProxy&, WebCore::MediaPlayerIdentifier, WebCore::MediaPlayerClientIdentifier, Ref<IPC::Connection>&&, WebCore::MediaPlayerEnums::MediaEngineIdentifier, RemoteMediaPlayerProxyConfiguration&&, RemoteVideoFrameObjectHeap&, const WebCore::ProcessIdentity&);
    ~RemoteMediaPlayerProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    WebCore::MediaPlayerIdentifier identifier() const { return m_id; }
    void invalidate();

#if PLATFORM(COCOA)
    std::optional<WebCore::FloatRect> hostedVideoLayerBoundsForTesting(WebCore::MediaPlayerClientIdentifier) const;
#endif

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


#if PLATFORM(COCOA)
    void setVideoLayerSizeFenced(const WebCore::FloatSize&, WTF::MachSendRightAnnotated&&);
#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
    void setWirelessPlaybackTarget(MediaPlaybackTargetContextSerialized&&);
#if PLATFORM(IOS_FAMILY)
    WebCore::MediaPlaybackTargetType playbackTargetType() const;
#endif
#endif

    using IsCrossOriginCompletionHandler = WTF::RefCountable<CompletionHandler<void(std::optional<bool>)>>;
    void isCrossOrigin(WebCore::SecurityOriginData, IsCrossOriginCompletionHandler* WTF_NONNULL);

    void setPlatformDynamicRangeLimit(WebCore::PlatformDynamicRangeLimit);

    RefPtr<WebCore::MediaPlayer> mediaPlayer() { return m_player; }

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    void destroyResourceLoader(RemoteMediaResourceLoaderIdentifier);

private:
    RemoteMediaPlayerProxy(RemoteMediaPlayerManagerProxy&, WebCore::MediaPlayerIdentifier, WebCore::MediaPlayerClientIdentifier, Ref<IPC::Connection>&&, WebCore::MediaPlayerEnums::MediaEngineIdentifier, RemoteMediaPlayerProxyConfiguration&&, RemoteVideoFrameObjectHeap&, const WebCore::ProcessIdentity&);

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
public:
    // What the Swift MediaPlayerClientDelegate asks of C++.
    void mediaPlayerFirstVideoFrameAvailable();
    void mediaPlayerRenderingModeChanged();
#if PLATFORM(COCOA)
    WebCore::FloatSize mediaPlayerVideoLayerSize() const;
#endif

private:
    // What the SwiftMediaPlayerClientAdapter's functions call.
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    RefPtr<ArrayBuffer> mediaPlayerCachedKeyForKeyId(const String&) const;
    void setPlayerLegacyCDMSession(WebCore::LegacyCDMSessionClientSwiftAdapter* WTF_NULLABLE);
#endif
#if ENABLE(ENCRYPTED_MEDIA)
    void mediaPlayerInitializationDataEncountered(const String&, RefPtr<ArrayBuffer>&&);
#endif
#if PLATFORM(COCOA)
    void mediaPlayerOnNewVideoFrameMetadata(WebCore::VideoFrameMetadata&&, RetainPtr<CVPixelBufferRef>&&);
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    WebCore::PlatformVideoTarget mediaPlayerVideoTarget() const;
#endif
    void initializeClientAdapter();
    static uintptr_t makeMediaPlayerClientDelegateBox();
    void connectMediaPlayerClientDelegate();
#endif

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    WebCore::MediaPlayer& player() const { return *m_player; }
    void stopUpdateCachedStateMessageTimer() { m_updateCachedStateMessageTimer.stop(); }
    bool isUpdateCachedStateMessageTimerActive() const { return m_updateCachedStateMessageTimer.isActive(); }
    void startRepeatingUpdateCachedStateMessageTimer(double seconds) { m_updateCachedStateMessageTimer.startRepeating(Seconds(seconds)); }
    void cacheBufferedRanges() { m_cachedState.bufferedRanges = m_player->buffered(); }
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    void setPreferredSpeakerID();
#endif
    bool willLogAlways() const;
    void logAlways(const String& message) const;
#endif

    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() const;
    bool prepareTrackForProxy(WebCore::TrackPrivateBase&);
    // m_swiftTracks holds the track proxies and the pending PerformTaskAtTime's reply (RemoteMediaPlayerProxy.swift).
    static uintptr_t createSwiftTracks();
    // Unsafe: the tracks must be the ones createSwiftTracks() made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftTracks(uintptr_t);
    uintptr_t swiftTracks() const { return m_swiftTracks; }
    // Replies to the pending PerformTaskAtTime, whose reply keeps the proxy alive.
    void cancelPendingTaskAtTime();

    void timerFired();

    void createAudioSourceProvider();
    void setShouldEnableAudioSourceProvider(bool);

    void playAtHostTime(MonotonicTime);
    void pauseAtHostTime(MonotonicTime);

    void playerContentBoxRectChanged(WebCore::LayoutRect);

    void currentTimeChanged(MediaTime);

#if PLATFORM(COCOA)
    void nativeImageForCurrentTime(CompletionHandler<void(std::optional<WTF::MachSendRight>&&, WebCore::ColorSpace)>&&);
    void colorSpace(ColorSpaceCompletionHandler* WTF_NONNULL);
#endif
    void videoFrameForCurrentTimeIfChanged(RemoteVideoFrameReference, CompletionHandler<void(std::optional<RemoteVideoFrameProxy::Properties>&&, bool)>&&);
    void bitmapImageForCurrentTime(CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&&);

    void requestHostingContext(CompletionHandler<void(WebCore::HostingContext)>&&);
    void setHasMessageClientForTesting(bool);
    void sendInternalMessage(const WebCore::MessageForTesting&) final;

#if !RELEASE_LOG_DISABLED
    const Logger& logger() { return m_logger; }
    uint64_t logIdentifier() { return m_configuration.logIdentifier; }
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
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    const Ref<WebCore::SwiftMediaPlayerClientAdapter> m_clientAdapter;
#endif
    RunLoop::Timer m_updateCachedStateMessageTimer;
    RemoteMediaPlayerState m_cachedState;
    RemoteMediaPlayerProxyConfiguration m_configuration;

    double m_videoPlaybackMetricsUpdateInterval { 0 };
    double m_nextPlaybackQualityMetricsUpdateTime { 0 };
    bool m_hasPlaybackMetricsUpdatePending { false };

    bool m_bufferedChanged { true };

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    uint64_t m_legacySessionIdentifier { 0 };
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
