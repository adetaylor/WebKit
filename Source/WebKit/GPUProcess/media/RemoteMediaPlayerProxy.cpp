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

#include "config.h"
#include "RemoteMediaPlayerProxy.h"

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)

#include "ArgumentCoders.h"
#include "GPUConnectionToWebProcess.h"
#include "LayerHostingContext.h"
#include "Logging.h"
#include "MediaPlayerPrivateRemote.h"
#include "MediaPlayerPrivateRemoteMessages.h"
#include "RemoteAudioSourceProviderProxy.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include "RemoteMediaPlayerProxyConfiguration.h"
#include "RemoteMediaResource.h"
#include "RemoteMediaResourceIdentifier.h"
#include "RemoteMediaResourceLoader.h"
#include "RemoteMediaSwiftSupport.h"
#include "RemoteVideoFrameObjectHeap.h"
#include "TextTrackPrivateRemoteConfiguration.h"
#include "TrackPrivateRemoteConfiguration.h"
#include <JavaScriptCore/Uint8Array.h>
#include <WebCore/LayoutRect.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/MediaPlayerPrivate.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SecurityOrigin.h>
#include <wtf/Borrow.h>
#include <wtf/MemoryFootprint.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/UniqueRef.h>

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
#include "MediaPlaybackTargetContextSerialized.h"
#endif

#if PLATFORM(COCOA)
#include "LayerHostingContextManager.h"
#include <WebCore/AudioSourceProviderAVFObjC.h>
#include <WebCore/VideoFrameCV.h>
#endif

#if ENABLE(LINEAR_MEDIA_PLAYER)
#include "VideoReceiverEndpointManager.h"
#endif

#if PLATFORM(IOS_FAMILY)
#include <WebCore/MediaSessionHelperIOS.h>
#endif

#include <wtf/NativePromise.h>

#define MESSAGE_CHECK(assertion, message) MESSAGE_CHECK_WITH_MESSAGE_BASE(assertion, m_webProcessConnection.get(), message)

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteMediaPlayerProxy);

Ref<RemoteMediaPlayerProxy> RemoteMediaPlayerProxy::create(RemoteMediaPlayerManagerProxy& manager, MediaPlayerIdentifier identifier, MediaPlayerClientIdentifier clientIdentifier, Ref<IPC::Connection>&& connection, MediaPlayerEnums::MediaEngineIdentifier engineIdentifier, RemoteMediaPlayerProxyConfiguration&& configuration, RemoteVideoFrameObjectHeap& videoFrameObjectHeap, const WebCore::ProcessIdentity& resourceOwner)
{
    return adoptRef(*new RemoteMediaPlayerProxy(manager, identifier, clientIdentifier, WTF::move(connection), engineIdentifier, WTF::move(configuration), videoFrameObjectHeap, resourceOwner));
}

RemoteMediaPlayerProxy::RemoteMediaPlayerProxy(RemoteMediaPlayerManagerProxy& manager, MediaPlayerIdentifier identifier, MediaPlayerClientIdentifier clientIdentifier, Ref<IPC::Connection>&& connection, MediaPlayerEnums::MediaEngineIdentifier engineIdentifier, RemoteMediaPlayerProxyConfiguration&& configuration, RemoteVideoFrameObjectHeap& videoFrameObjectHeap, const WebCore::ProcessIdentity& resourceOwner)
    : m_id(identifier)
    , m_clientIdentifier(clientIdentifier)
    , m_webProcessConnection(WTF::move(connection))
    , m_manager(manager)
    , m_engineIdentifier(engineIdentifier)
    , m_updateCachedStateMessageTimer(RunLoop::mainSingleton(), "RemoteMediaPlayerProxy::UpdateCachedStateMessageTimer"_s, this, &RemoteMediaPlayerProxy::timerFired)
    , m_configuration(configuration)
    , m_renderingResourcesRequest(ScopedRenderingResourcesRequest::acquire())
    , m_videoFrameObjectHeap(videoFrameObjectHeap)
#if !RELEASE_LOG_DISABLED
    , m_logger(manager.logger())
#endif
#if PLATFORM(COCOA)
    , m_layerHostingContextManager(makeUniqueRef<LayerHostingContextManager>())
#endif
{
    m_typesRequiringHardwareSupport = m_configuration.mediaContentTypesRequiringHardwareSupport;
    m_renderingCanBeAccelerated = m_configuration.renderingCanBeAccelerated;
    m_playerContentBoxRect = m_configuration.playerContentBoxRect;
    lazyInitialize(m_player, MediaPlayer::create(*this, m_engineIdentifier));

    m_player->setResourceOwner(resourceOwner);
    m_player->setPresentationSize(m_configuration.presentationSize);
#if PLATFORM(COCOA)
    if (!m_configuration.videoLayerSize.isEmpty())
        m_layerHostingContextManager->setInitialVideoLayerSize(m_configuration.videoLayerSize);
#endif
#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    m_player->setPrefersSpatialAudioExperience(m_configuration.prefersSpatialAudioExperience);
#endif
}

RemoteMediaPlayerProxy::~RemoteMediaPlayerProxy()
{
    if (m_performTaskAtTimeCompletionHandler)
        m_performTaskAtTimeCompletionHandler(std::nullopt);
    setShouldEnableAudioSourceProvider(false);
    destroySwiftTracks(std::exchange(m_swiftTracks, 0));
}

void RemoteMediaPlayerProxy::invalidate()
{
    m_updateCachedStateMessageTimer.stop();
    m_player->invalidate();
    if (RefPtr sandboxExtension = m_sandboxExtension) {
        sandboxExtension->revoke();
        m_sandboxExtension = nullptr;
    }
    m_renderingResourcesRequest = { };
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    m_invalidated = true;
#endif
#if USE(AVFOUNDATION)
    m_videoFrameForCurrentTime = nullptr;
#endif
}

Ref<MediaPromise> RemoteMediaPlayerProxy::commitAllTransactions()
{
    RefPtr manager = m_manager.get();
    if (!manager || !manager->gpuConnectionToWebProcess())
        return MediaPromise::createAndReject(PlatformMediaError::ClientDisconnected);

    return protect(m_webProcessConnection)->sendWithPromisedReply<MediaPromiseConverter>(Messages::MediaPlayerPrivateRemote::CommitAllTransactions { }, m_id);
}

void RemoteMediaPlayerProxy::observeCurrentTimeChanges()
{
    m_observingTimeChanges = m_player->setCurrentTimeDidChangeCallback([weakThis = WeakPtr { *this }] (auto currentTime) mutable {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->currentTimeChanged(currentTime);
    });
}

void RemoteMediaPlayerProxy::load(URL&& url, std::optional<SandboxExtension::Handle>&& sandboxExtensionHandle, const MediaPlayer::LoadOptions& options, CompletionHandler<void(RemoteMediaPlayerConfiguration&&)>&& completionHandler)
{
    if (sandboxExtensionHandle) {
        m_sandboxExtension = SandboxExtension::create(WTF::move(sandboxExtensionHandle.value()));
        if (RefPtr sandboxExtension = m_sandboxExtension)
            sandboxExtension->consume();
        else
            WTFLogAlways("Unable to create sandbox extension for media url.\n");
    }

    m_player->load(url, options);
    auto configuration = this->configuration();
    observeCurrentTimeChanges();
    completionHandler(WTF::move(configuration));
}

#if ENABLE(VIDEO_PRESENTATION_MODE)
#endif

// MediaPlayerClient
#if ENABLE(VIDEO_PRESENTATION_MODE)
#endif

#if PLATFORM(IOS_FAMILY)
void RemoteMediaPlayerProxy::accessLog(CompletionHandler<void(String)>&& completionHandler)
{
    completionHandler(m_player->accessLog());
}

void RemoteMediaPlayerProxy::errorLog(CompletionHandler<void(String)>&& completionHandler)
{
    completionHandler(m_player->errorLog());
}

void RemoteMediaPlayerProxy::setSceneIdentifier(String&& identifier)
{
    m_player->setSceneIdentifier(identifier);
}
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) || ENABLE(ENCRYPTED_MEDIA)
String RemoteMediaPlayerProxy::mediaPlayerMediaKeysStorageDirectory() const
{
    RefPtr connection = gpuConnectionToWebProcess();
    return connection ? connection->mediaKeysStorageDirectory() : emptyString();
}
#endif

#if PLATFORM(IOS_FAMILY)
String RemoteMediaPlayerProxy::mediaPlayerNetworkInterfaceName() const
{
    return m_configuration.networkInterfaceName;
}

void RemoteMediaPlayerProxy::mediaPlayerGetRawCookies(const URL& url, WebCore::MediaPlayerClient::GetRawCookiesCallback&& completionHandler) const
{
    protect(m_webProcessConnection)->sendWithAsyncReply(Messages::MediaPlayerPrivateRemote::GetRawCookies(url), WTF::move(completionHandler), m_id);
}
#endif

String RemoteMediaPlayerProxy::mediaPlayerMediaCacheDirectory() const
{
    RefPtr connection = gpuConnectionToWebProcess();
    return connection ? connection->mediaCacheDirectory() : emptyString();
}

#if !PLATFORM(COCOA)
void RemoteMediaPlayerProxy::mediaPlayerRenderingModeChanged()
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::RenderingModeChanged(), m_id);
}

void RemoteMediaPlayerProxy::requestHostingContext(CompletionHandler<void(WebCore::HostingContext)>&& completionHandler)
{
    completionHandler({ });
}
#endif

RefPtr<GPUConnectionToWebProcess> RemoteMediaPlayerProxy::gpuConnectionToWebProcess() const
{
    RefPtr manager = m_manager.get();
    ASSERT(manager && manager->gpuConnectionToWebProcess());
    return manager ? manager->gpuConnectionToWebProcess() : nullptr;
}

bool RemoteMediaPlayerProxy::prepareTrackForProxy(WebCore::TrackPrivateBase& track)
{
    if (!gpuConnectionToWebProcess())
        return false;

#if !RELEASE_LOG_DISABLED
    track.setLogger(protect(m_logger), mediaPlayerLogIdentifier());
#endif
    return true;
}

void RemoteMediaPlayerProxy::mediaPlayerDidAddAudioTrack(WebCore::AudioTrackPrivate& track)
{
    if (!prepareTrackForProxy(track))
        return;
    addRemoteAudioTrackProxy(track);
}

void RemoteMediaPlayerProxy::mediaPlayerDidAddVideoTrack(WebCore::VideoTrackPrivate& track)
{
    if (!prepareTrackForProxy(track))
        return;
    addRemoteVideoTrackProxy(track);
}

void RemoteMediaPlayerProxy::mediaPlayerDidAddTextTrack(WebCore::InbandTextTrackPrivate& track)
{
    if (!prepareTrackForProxy(track))
        return;
    addRemoteTextTrackProxy(track);
}

void RemoteMediaPlayerProxy::mediaPlayerDidRemoveAudioTrack(WebCore::AudioTrackPrivate& track)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::RemoveRemoteAudioTrack(track.id()), m_id);
    removeAudioTrackProxy(track.id());
}

void RemoteMediaPlayerProxy::mediaPlayerDidRemoveVideoTrack(WebCore::VideoTrackPrivate& track)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::RemoveRemoteVideoTrack(track.id()), m_id);
    removeVideoTrackProxy(track.id());
}

void RemoteMediaPlayerProxy::mediaPlayerDidRemoveTextTrack(WebCore::InbandTextTrackPrivate& track)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::RemoveRemoteTextTrack(track.id()), m_id);
    removeTextTrackProxy(track.id());
}

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
RefPtr<ArrayBuffer> RemoteMediaPlayerProxy::mediaPlayerCachedKeyForKeyId(const String& keyId) const
{
    RefPtr manager = m_manager.get();
    ASSERT(manager && manager->gpuConnectionToWebProcess());
    if (!manager || !manager->gpuConnectionToWebProcess())
        return nullptr;

    if (!m_legacySession)
        return nullptr;

    if (RefPtr cdmSession = manager->gpuConnectionToWebProcess()->legacyCDMSession(m_legacySession->toUInt64())) {
        if (RefPtr session = cdmSession->session())
            return session->cachedKeyForKeyID(keyId);
    }
    return nullptr;
}

void RemoteMediaPlayerProxy::mediaPlayerKeyNeeded(const SharedBuffer& message)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::MediaPlayerKeyNeeded(message.span()), m_id);
}
#endif

#if ENABLE(ENCRYPTED_MEDIA)
void RemoteMediaPlayerProxy::mediaPlayerInitializationDataEncountered(const String& initDataType, RefPtr<ArrayBuffer>&& initData)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::InitializationDataEncountered(initDataType, initData->mutableSpan()), m_id);
}

#endif

#if ENABLE(WIRELESS_PLAYBACK_TARGET)

void RemoteMediaPlayerProxy::setWirelessPlaybackTarget(MediaPlaybackTargetContextSerialized&& targetContext)
{
    m_player->setWirelessPlaybackTarget(targetContext.playbackTarget());
}

MediaPlaybackTargetType RemoteMediaPlayerProxy::playbackTargetType() const
{
#if PLATFORM(IOS_FAMILY)
    if (RefPtr playbackTarget = protect(MediaSessionHelper::sharedHelper())->playbackTarget())
        return playbackTarget->type();
#endif
    return MediaPlaybackTargetType::None;
}
#endif // ENABLE(WIRELESS_PLAYBACK_TARGET)

Ref<PlatformMediaResourceLoader> RemoteMediaPlayerProxy::mediaPlayerCreateResourceLoader()
{
    auto loader = RemoteMediaResourceLoader::create(*this, protect(m_webProcessConnection));
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::CreateResourceLoader(loader->identifier()), m_id);
    return loader;
}

#if PLATFORM(COCOA)
Vector<Ref<PlatformTextTrack>> RemoteMediaPlayerProxy::outOfBandTrackSources()
{
    return WTF::map(m_configuration.outOfBandTrackData, [](auto& data) {
        return PlatformTextTrack::create(WTF::move(data));
    });
}

#endif


WebCore::PlatformVideoTarget RemoteMediaPlayerProxy::mediaPlayerVideoTarget() const
{
#if ENABLE(LINEAR_MEDIA_PLAYER)
    if (m_manager) {
        if (RefPtr gpuConnectionToWebProcess = m_manager->gpuConnectionToWebProcess())
            return gpuConnectionToWebProcess->videoReceiverEndpointManager().takeVideoTargetForMediaElementIdentifier(m_clientIdentifier, m_id);
    }
#endif
    return nullptr;
}

void RemoteMediaPlayerProxy::videoFrameForCurrentTimeIfChanged(RemoteVideoFrameReference reference, CompletionHandler<void(std::optional<RemoteVideoFrameProxy::Properties>&&, bool)>&& completionHandler)
{
    std::optional<RemoteVideoFrameProxy::Properties> result;
    bool changed = false;
    RefPtr<WebCore::VideoFrame> videoFrame;
    if (m_player)
        videoFrame = m_player->videoFrameForCurrentTime();
    if (m_videoFrameForCurrentTime != videoFrame) {
        m_videoFrameForCurrentTime = videoFrame;
        changed = true;
        if (videoFrame) {
            result = RemoteVideoFrameProxy::properties(*videoFrame);
            protect(m_videoFrameObjectHeap)->add(reference, videoFrame.releaseNonNull());
        }
    }
    completionHandler(WTF::move(result), changed);
}

void RemoteMediaPlayerProxy::bitmapImageForCurrentTime(CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&& completionHandler)
{
    if (!m_player) {
        completionHandler({ });
        return;
    }

    m_player->bitmapImageForCurrentTime()->whenSettled(RunLoop::mainSingleton(), [completionHandler = WTF::move(completionHandler)](auto&& result) mutable {
        if (!result) {
            completionHandler({ });
            return;
        }
        completionHandler(protect(*result)->createHandle());
    });
}


#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
void RemoteMediaPlayerProxy::setLegacyCDMSession(std::optional<RemoteLegacyCDMSessionIdentifier>&& instanceId)
{
    RefPtr manager = m_manager.get();
    ASSERT(manager && manager->gpuConnectionToWebProcess());
    if (!manager || !manager->gpuConnectionToWebProcess())
        return;

    if (m_legacySession == instanceId)
        return;

    if (m_legacySession) {
        if (RefPtr cdmSession = manager->gpuConnectionToWebProcess()->legacyCDMSession(m_legacySession->toUInt64()))
            m_player->setCDMSession(nullptr);
    }

    m_legacySession = instanceId;

    if (m_legacySession) {
        if (RefPtr cdmSession = manager->gpuConnectionToWebProcess()->legacyCDMSession(m_legacySession->toUInt64()))
            m_player->setCDMSession(protect(cdmSession->session()).get());
    }
}

#endif

#if ENABLE(ENCRYPTED_MEDIA)
void RemoteMediaPlayerProxy::cdmInstanceAttached(RemoteCDMInstanceIdentifier&& instanceId)
{
    RefPtr manager = m_manager.get();
    ASSERT(manager && manager->gpuConnectionToWebProcess());
    if (!manager || !manager->gpuConnectionToWebProcess())
        return;

    if (RefPtr instance = manager->gpuConnectionToWebProcess()->cdmInstance(instanceId.toUInt64()))
        m_player->cdmInstanceAttached(*instance);
}

void RemoteMediaPlayerProxy::cdmInstanceDetached(RemoteCDMInstanceIdentifier&& instanceId)
{
    RefPtr manager = m_manager.get();
    ASSERT(manager && manager->gpuConnectionToWebProcess());
    if (!manager || !manager->gpuConnectionToWebProcess())
        return;

    if (RefPtr instance = manager->gpuConnectionToWebProcess()->cdmInstance(instanceId.toUInt64()))
        m_player->cdmInstanceDetached(*instance);
}

void RemoteMediaPlayerProxy::attemptToDecryptWithInstance(RemoteCDMInstanceIdentifier&& instanceId)
{
    RefPtr manager = m_manager.get();
    ASSERT(manager && manager->gpuConnectionToWebProcess());
    if (!manager || !manager->gpuConnectionToWebProcess())
        return;

    if (RefPtr instance = manager->gpuConnectionToWebProcess()->cdmInstance(instanceId.toUInt64()))
        m_player->attemptToDecryptWithInstance(*instance);
}
#endif


#if ENABLE(LEGACY_ENCRYPTED_MEDIA) && ENABLE(ENCRYPTED_MEDIA)
#endif

void RemoteMediaPlayerProxy::performTaskAtTime(const MediaTime& taskTime, PerformTaskAtTimeCompletionHandler&& completionHandler)
{
    if (m_performTaskAtTimeCompletionHandler) {
        // A media player is only expected to track one pending task-at-time at once (e.g. see
        // MediaPlayerPrivateAVFoundationObjC::performTaskAtMediaTime), so cancel the existing
        // CompletionHandler.
        auto handler = WTF::move(m_performTaskAtTimeCompletionHandler);
        handler(std::nullopt);
    }

    auto currentTime = m_player->currentTime();
    if (taskTime <= currentTime) {
        completionHandler(currentTime);
        return;
    }

    m_performTaskAtTimeCompletionHandler = WTF::move(completionHandler);
    m_player->performTaskAtTime([weakThis = WeakPtr { *this }](const MediaTime& time) mutable {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis || !protectedThis->m_performTaskAtTimeCompletionHandler)
            return;

        auto completionHandler = std::exchange(protectedThis->m_performTaskAtTimeCompletionHandler, nullptr);
        completionHandler(time);
    }, taskTime);
}

void RemoteMediaPlayerProxy::createAudioSourceProvider()
{
#if ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
    MESSAGE_CHECK(!m_remoteAudioSourceProvider, "RemoteAudioSourceProvider already created.");

    if (!m_player)
        return;

    RefPtr provider = dynamicDowncast<AudioSourceProviderAVFObjC>(m_player->audioSourceProvider());
    if (!provider)
        return;

    Ref proxy = RemoteAudioSourceProviderProxy::create(m_id, m_webProcessConnection.copyRef(), *provider);
    proxy->setPlaybackRate(m_player->effectiveRate());
    proxy->setPreservesPitch(m_player->preservesPitch());
    lazyInitialize(m_remoteAudioSourceProvider, WTF::move(proxy));
#endif
}

void RemoteMediaPlayerProxy::setShouldEnableAudioSourceProvider(bool shouldEnable)
{
#if ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
    if (auto* provider = m_player->audioSourceProvider())
        provider->setClient(shouldEnable ? m_remoteAudioSourceProvider.get() : nullptr);
#endif
}

#if HAVE(SPATIAL_TRACKING_LABEL)

#endif

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
#endif

#if !RELEASE_LOG_DISABLED
WTFLogChannel& RemoteMediaPlayerProxy::logChannel() const
{
    return JOIN_LOG_CHANNEL_WITH_PREFIX(LOG_CHANNEL_PREFIX, Media);
}
#endif

std::optional<SharedPreferencesForWebProcess> RemoteMediaPlayerProxy::sharedPreferencesForWebProcess() const
{
    RefPtr manager = m_manager.get();
    if (!m_manager)
        return std::nullopt;

    RefPtr<GPUConnectionToWebProcess> gpuProcessConnectionToWebProcess = manager->gpuConnectionToWebProcess();
    if (!gpuProcessConnectionToWebProcess)
        return std::nullopt;

    return gpuProcessConnectionToWebProcess->sharedPreferencesForWebProcess();
}

void RemoteMediaPlayerProxy::setHasMessageClientForTesting(bool hasClient)
{
    m_player->setMessageClientForTesting(hasClient ? this : nullptr);
}

void RemoteMediaPlayerProxy::sendInternalMessage(const WebCore::MessageForTesting& message)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::SendInternalMessage { message }, m_id);
}

#if PLATFORM(MAC)
#endif

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
void RemoteMediaPlayerProxy::cacheBufferedRanges()
{
    m_cachedState.bufferedRanges = m_player->buffered();
}

#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
void RemoteMediaPlayerProxy::setPreferredSpeakerID()
{
    RefPtr manager = m_manager.get();
    RefPtr connection = manager->gpuConnectionToWebProcess();
    connection->setAudioSessionPreferredSpeakerID(m_configuration.audioOutputDeviceId);
}
#endif

bool RemoteMediaPlayerProxy::willLogAlways() const
{
#if !RELEASE_LOG_DISABLED
    return m_logger->enabled();
#else
    return false;
#endif
}

void RemoteMediaPlayerProxy::logAlways(const String& message) const
{
#if !RELEASE_LOG_DISABLED
    m_logger->logAlways(logChannel(), message);
#else
    UNUSED_PARAM(message);
#endif
}
#endif

} // namespace WebKit

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
template struct WTF::NativePromiseSettler<WebCore::MediaTimePromise>;
template struct WTF::NativePromiseSettler<WebCore::MediaPlayer::VideoPlaybackQualityMetricsPromise>;
#endif

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
