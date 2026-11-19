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
#include "Logging.h"
#include "MediaPlayerPrivateRemote.h"
#include "MediaPlayerPrivateRemoteMessages.h"
#include "RemoteAudioSourceProviderProxy.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include "RemoteMediaResourceLoader.h"
#include "RemoteVideoFrameObjectHeap.h"
#include <JavaScriptCore/Uint8Array.h>
#include <WebCore/LegacyCDM.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/MediaPlayerPrivate.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/UniqueRef.h>

#if ENABLE(WIRELESS_PLAYBACK_TARGET)
#include "MediaPlaybackTargetContextSerialized.h"
#endif

#if PLATFORM(COCOA)
#include "LayerHostingContextManager.h"
#include <WebCore/AudioSourceProviderAVFObjC.h>
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
    Ref proxy = adoptRef(*new RemoteMediaPlayerProxy(manager, identifier, clientIdentifier, WTF::move(connection), engineIdentifier, WTF::move(configuration), videoFrameObjectHeap, resourceOwner));
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    proxy->connectMediaPlayerClientDelegate();
#endif
    return proxy;
}

RemoteMediaPlayerProxy::RemoteMediaPlayerProxy(RemoteMediaPlayerManagerProxy& manager, MediaPlayerIdentifier identifier, MediaPlayerClientIdentifier clientIdentifier, Ref<IPC::Connection>&& connection, MediaPlayerEnums::MediaEngineIdentifier engineIdentifier, RemoteMediaPlayerProxyConfiguration&& configuration, RemoteVideoFrameObjectHeap& videoFrameObjectHeap, const WebCore::ProcessIdentity& resourceOwner)
    : m_id(identifier)
    , m_clientIdentifier(clientIdentifier)
    , m_webProcessConnection(WTF::move(connection))
    , m_manager(manager)
    , m_engineIdentifier(engineIdentifier)
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    , m_clientAdapter(WebCore::SwiftMediaPlayerClientAdapter::create(clientIdentifier, makeMediaPlayerClientDelegateBox()))
#endif
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
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    initializeClientAdapter();
    lazyInitialize(m_player, MediaPlayer::create(m_clientAdapter.get(), m_engineIdentifier));
#endif

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

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
void RemoteMediaPlayerProxy::initializeClientAdapter()
{
    Ref adapter = m_clientAdapter;
    adapter->setPreferredAudioCharacteristics(m_configuration.preferredAudioCharacteristics);
    adapter->setMediaContentTypesRequiringHardwareSupport(m_configuration.mediaContentTypesRequiringHardwareSupport);
    adapter->setAllowedMediaContainerTypes(m_configuration.allowedMediaContainerTypes);
    adapter->setAllowedMediaCodecTypes(m_configuration.allowedMediaCodecTypes);
    adapter->setAllowedMediaVideoCodecIDs(m_configuration.allowedMediaVideoCodecIDs);
    adapter->setAllowedMediaAudioCodecIDs(m_configuration.allowedMediaAudioCodecIDs);
    adapter->setAllowedMediaCaptionFormatTypes(m_configuration.allowedMediaCaptionFormatTypes);
#if PLATFORM(IOS_FAMILY)
    adapter->setNetworkInterfaceName(m_configuration.networkInterfaceName);
#endif
#if ENABLE(ENCRYPTED_MEDIA)
    adapter->setInitializationDataHandler([weakThis = WeakPtr { *this }](const String& initDataType, RefPtr<ArrayBuffer>&& initData) {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->mediaPlayerInitializationDataEncountered(initDataType, WTF::move(initData));
    });
#endif
#if !RELEASE_LOG_DISABLED
    adapter->setLogger(m_logger, m_configuration.logIdentifier);
#endif
    adapter->setOutOfBandTrackSources(WTF::map(m_configuration.outOfBandTrackData, [](auto& data) {
        return PlatformTextTrack::create(WTF::move(data));
    }));
    adapter->setResourceLoaderProvider([weakThis = WeakPtr { *this }] -> RefPtr<PlatformMediaResourceLoader> {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return nullptr;
        Ref loader = RemoteMediaResourceLoader::create(*protectedThis, protectedThis->m_webProcessConnection.copyRef());
        protect(protectedThis->m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::CreateResourceLoader(loader->identifier()), protectedThis->m_id);
        return WTF::move(loader);
    });
#if PLATFORM(COCOA)
    adapter->setVideoFrameMetadataHandler([weakThis = WeakPtr { *this }](VideoFrameMetadata&& metadata, RetainPtr<CVPixelBufferRef>&& pixelBuffer) {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->mediaPlayerOnNewVideoFrameMetadata(WTF::move(metadata), WTF::move(pixelBuffer));
    });
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    adapter->setCachedKeyProvider([weakThis = WeakPtr { *this }](const String& keyId) -> RefPtr<ArrayBuffer> {
        RefPtr protectedThis = weakThis.get();
        return protectedThis ? protectedThis->mediaPlayerCachedKeyForKeyId(keyId) : nullptr;
    });
#endif
#if PLATFORM(IOS_FAMILY)
    adapter->setRawCookiesProvider([connection = m_webProcessConnection, identifier = m_id](const URL& url, MediaPlayerClient::GetRawCookiesCallback&& completionHandler) {
        connection->sendWithAsyncReply(Messages::MediaPlayerPrivateRemote::GetRawCookies(url), WTF::move(completionHandler), identifier);
    });
#endif
#if ENABLE(LINEAR_MEDIA_PLAYER)
    adapter->setVideoTargetProvider([weakThis = WeakPtr { *this }] -> PlatformVideoTarget {
        RefPtr protectedThis = weakThis.get();
        return protectedThis ? protectedThis->mediaPlayerVideoTarget() : nullptr;
    });
#endif
}
#endif

RemoteMediaPlayerProxy::~RemoteMediaPlayerProxy()
{
    setShouldEnableAudioSourceProvider(false);
    destroySwiftTracks(std::exchange(m_swiftTracks, 0));
}

void RemoteMediaPlayerProxy::invalidate()
{
    m_updateCachedStateMessageTimer.stop();
    m_player->invalidate();
    if (RefPtr sandboxExtension = std::exchange(m_sandboxExtension, nullptr))
        sandboxExtension->revoke();
    m_renderingResourcesRequest = { };
    cancelPendingTaskAtTime();
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    m_invalidated = true;
#endif
#if USE(AVFOUNDATION)
    m_videoFrameForCurrentTime = nullptr;
#endif
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
    m_observingTimeChanges = m_player->setCurrentTimeDidChangeCallback([weakThis = WeakPtr { *this }] (auto currentTime) mutable {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->currentTimeChanged(currentTime);
    });
    completionHandler(WTF::move(configuration));
}

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
    track.setLogger(protect(m_logger), logIdentifier());
#endif
    return true;
}

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
RefPtr<ArrayBuffer> RemoteMediaPlayerProxy::mediaPlayerCachedKeyForKeyId(const String& keyId) const
{
    RefPtr connection = gpuConnectionToWebProcess();
    if (!connection || !m_legacySessionIdentifier)
        return nullptr;

    if (RefPtr cdmSession = connection->legacyCDMSession(m_legacySessionIdentifier)) {
        if (RefPtr session = cdmSession->session())
            return session->cachedKeyForKeyID(keyId);
    }
    return nullptr;
}

void RemoteMediaPlayerProxy::setPlayerLegacyCDMSession(LegacyCDMSessionClientSwiftAdapter* client)
{
    m_player->setCDMSession(client ? protect(client->session()).get() : nullptr);
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

#if PLATFORM(IOS_FAMILY)
MediaPlaybackTargetType RemoteMediaPlayerProxy::playbackTargetType() const
{
#if PLATFORM(IOS_FAMILY)
    if (RefPtr playbackTarget = protect(MediaSessionHelper::sharedHelper())->playbackTarget())
        return playbackTarget->type();
#endif
    return MediaPlaybackTargetType::None;
}
#endif
#endif // ENABLE(WIRELESS_PLAYBACK_TARGET)

#if ENABLE(LINEAR_MEDIA_PLAYER)
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
#endif

void RemoteMediaPlayerProxy::videoFrameForCurrentTimeIfChanged(RemoteVideoFrameReference reference, CompletionHandler<void(std::optional<RemoteVideoFrameProxy::Properties>&&, bool)>&& completionHandler)
{
    std::optional<RemoteVideoFrameProxy::Properties> result;
    bool changed = false;
    RefPtr videoFrame = m_player->videoFrameForCurrentTime();
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
    m_player->bitmapImageForCurrentTime()->whenSettled(RunLoop::mainSingleton(), [completionHandler = WTF::move(completionHandler)](auto&& result) mutable {
        if (!result) {
            completionHandler({ });
            return;
        }
        completionHandler(protect(*result)->createHandle());
    });
}

void RemoteMediaPlayerProxy::createAudioSourceProvider()
{
#if ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
    MESSAGE_CHECK(!m_remoteAudioSourceProvider, "RemoteAudioSourceProvider already created.");

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

#if !RELEASE_LOG_DISABLED
WTFLogChannel& RemoteMediaPlayerProxy::logChannel() const
{
    return JOIN_LOG_CHANNEL_WITH_PREFIX(LOG_CHANNEL_PREFIX, Media);
}
#endif

std::optional<SharedPreferencesForWebProcess> RemoteMediaPlayerProxy::sharedPreferencesForWebProcess() const
{
    RefPtr manager = m_manager.get();
    return manager ? manager->sharedPreferencesForWebProcess() : std::nullopt;
}

void RemoteMediaPlayerProxy::setHasMessageClientForTesting(bool hasClient)
{
    m_player->setMessageClientForTesting(hasClient ? this : nullptr);
}

void RemoteMediaPlayerProxy::sendInternalMessage(const WebCore::MessageForTesting& message)
{
    protect(m_webProcessConnection)->send(Messages::MediaPlayerPrivateRemote::SendInternalMessage { message }, m_id);
}

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
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
