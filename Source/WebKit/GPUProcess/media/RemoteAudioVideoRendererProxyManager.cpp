/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
#include "RemoteAudioVideoRendererProxyManager.h"

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO) && PLATFORM(COCOA)

#include "AudioVideoRendererRemoteMessageReceiverMessages.h"
#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "LayerHostingContext.h"
#include "Logging.h"
#include "RemoteAudioVideoRendererProxyManagerMessages.h"
#include "RemoteCDMFactoryProxy.h"
#include "RemoteLegacyCDMFactoryProxy.h"
#include "RemoteLegacyCDMSessionProxy.h"
#include "RemoteVideoFrameObjectHeap.h"
#if ENABLE(LINEAR_MEDIA_PLAYER)
#include "VideoReceiverEndpointManager.h"
#endif
#include <WebCore/AudioVideoRendererAVFObjC.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MediaSamplesBlock.h>
#include <WebCore/PlatformLayer.h>
#include <WebCore/SharedTimebase.h>

#include <wtf/LoggerHelper.h>
#include <wtf/MachSendRightAnnotated.h>
#include <wtf/Markable.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/UniqueRef.h>

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_gpuConnectionToWebProcess.get()->connection())
#define MESSAGE_CHECK_COMPLETION(assertion, completion) MESSAGE_CHECK_COMPLETION_BASE(assertion, m_gpuConnectionToWebProcess.get()->connection(), completion)

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteAudioVideoRendererProxyManager);

template<typename Message>
void RemoteAudioVideoRendererProxyManager::publishAndSend(RemoteAudioVideoRendererIdentifier identifier, Message&& message)
{
    auto iterator = m_renderers.find(identifier);
    if (iterator == m_renderers.end())
        return;
    m_gpuConnectionToWebProcess.get()->connection().send(std::forward<Message>(message), identifier);
}

Ref<RemoteAudioVideoRendererProxyManager> RemoteAudioVideoRendererProxyManager::create(GPUConnectionToWebProcess& connection)
{
    Ref manager = adoptRef(*new RemoteAudioVideoRendererProxyManager(connection));
    manager->m_swiftState = manager->createSwiftState(connection.connection());
    return manager;
}

RemoteAudioVideoRendererProxyManager::RemoteAudioVideoRendererProxyManager(GPUConnectionToWebProcess& connection)
    : m_videoFrameObjectHeap(connection.videoFrameObjectHeap())
    , m_gpuConnectionToWebProcess(connection)
#if !RELEASE_LOG_DISABLED
    , m_logIdentifier { LoggerHelper::uniqueLogIdentifier() }
    , m_logger { connection.logger() }
#endif
{
}

RemoteAudioVideoRendererProxyManager::~RemoteAudioVideoRendererProxyManager()
{
    ALWAYS_LOG(LOGIDENTIFIER);
    for (auto& keyValuePair : std::exchange(m_renderers, { })) {
        if (RefPtr renderer = keyValuePair.value.renderer)
            renderer->shutdown();
    }
    destroySwiftState(std::exchange(m_swiftState, 0));
}

void RemoteAudioVideoRendererProxyManager::connectionToWebProcessClosed()
{
    ALWAYS_LOG(LOGIDENTIFIER);
    clear();
    for (auto& keyValuePair : std::exchange(m_renderers, { })) {
        if (RefPtr renderer = keyValuePair.value.renderer)
            renderer->shutdown();
    }
}

std::optional<SharedPreferencesForWebProcess> RemoteAudioVideoRendererProxyManager::sharedPreferencesForWebProcess() const
{
    return m_gpuConnectionToWebProcess.get()->sharedPreferencesForWebProcess();
}

void RemoteAudioVideoRendererProxyManager::createManager(RemoteAudioVideoRendererIdentifier identifier, WebCore::HTMLMediaElementIdentifier mediaElementIdentifier, WebCore::MediaPlayerIdentifier playerIdentifier, CompletionHandler<void(std::optional<WebCore::SharedTimebaseHandle>)>&& completionHandler)
{
    MESSAGE_CHECK(!m_renderers.contains(identifier));

    auto sharedTimebase = SharedTimebase::create();
    if (!sharedTimebase) {
        completionHandler(std::nullopt);
        return;
    }
    auto handle = sharedTimebase->createHandle();
    if (!handle) {
        completionHandler(std::nullopt);
        return;
    }

    Ref rendererAVFObjC = AudioVideoRendererAVFObjC::create(Ref { m_gpuConnectionToWebProcess.get()->logger() }, LoggerHelper::uniqueLogIdentifier(), makeUniqueRefFromNonNullUniquePtr(WTF::move(sharedTimebase)));
    auto token = rendererAVFObjC->swiftToken();
    Ref<AudioVideoRenderer> renderer = WTF::move(rendererAVFObjC);

    renderer->notifyFirstFrameAvailable([weakThis = ThreadSafeWeakPtr { *this }, identifier] {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis || !protectedThis->m_renderers.contains(identifier))
            return;
        protectedThis->contextFor(identifier).layerHostingContextManager.setVideoLayerSizeIfPossible();
        protectedThis->publishAndSend(identifier, Messages::AudioVideoRendererRemoteMessageReceiver::FirstFrameAvailable(protectedThis->stateFor(identifier)));
    });

    renderer->notifyRenderingModeChanged([weakThis = ThreadSafeWeakPtr { *this }, identifier] {
        if (RefPtr protectedThis = weakThis.get(); protectedThis && protectedThis->m_renderers.contains(identifier))
            protectedThis->rendereringModeChanged(identifier);
    });

    // The Swift state hears the core's other notifications. These make the renderer listen to its synchronizer's rate and
    // read the size of the video samples it gets.
    renderer->notifyEffectiveRateChanged([](double) { });
    renderer->notifySizeChanged([](const MediaTime&, FloatSize) { });

#if ENABLE(LINEAR_MEDIA_PLAYER)
    RetainPtr videoTarget = m_gpuConnectionToWebProcess.get()->videoReceiverEndpointManager().takeVideoTargetForMediaElementIdentifier(mediaElementIdentifier, playerIdentifier);
    renderer->setVideoTarget(videoTarget.get());
#endif

    m_renderers.set(identifier, RendererContext {
        .renderer = WTF::move(renderer),
        .mediaElementIdentifier = mediaElementIdentifier,
        .playerIdentifier = playerIdentifier,
    });
    addRenderer(identifier.toUInt64(), token);

    publishAndSend(identifier, Messages::AudioVideoRendererRemoteMessageReceiver::StateUpdate(stateFor(identifier)));
    completionHandler(WTF::move(handle));
}

void RemoteAudioVideoRendererProxyManager::shutDownRenderer(uint64_t identifier)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier);
    if (auto iterator = m_renderers.find(RemoteAudioVideoRendererIdentifier(identifier)); iterator != m_renderers.end()) {
        if (RefPtr renderer = iterator->value.renderer)
            renderer->shutdown();
    }
}

void RemoteAudioVideoRendererProxyManager::destroyRenderer(uint64_t identifier)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier);
    if (auto iterator = m_renderers.find(RemoteAudioVideoRendererIdentifier(identifier)); iterator != m_renderers.end()) {
        if (RefPtr renderer = iterator->value.renderer)
            renderer->shutdown();
        m_renderers.remove(iterator);
    }
}

RefPtr<WebCore::AudioVideoRenderer> RemoteAudioVideoRendererProxyManager::rendererFor(RemoteAudioVideoRendererIdentifier identifier) const
{
    auto iterator = m_renderers.find(identifier);
    MESSAGE_CHECK_WITH_RETURN_VALUE_BASE(iterator != m_renderers.end(), m_gpuConnectionToWebProcess.get()->connection(), nullptr);
    return iterator->value.renderer.copyRef();
}

RefPtr<WebCore::AudioVideoRenderer> RemoteAudioVideoRendererProxyManager::rendererFor(std::optional<MediaPlayerIdentifier> playerIdentifier) const
{
    if (!playerIdentifier)
        return nullptr;

    for (auto& context : m_renderers.values()) {
        if (context.playerIdentifier == playerIdentifier)
            return context.renderer.copyRef();
    }
    return nullptr;
}

RemoteAudioVideoRendererProxyManager::RendererContext& RemoteAudioVideoRendererProxyManager::contextFor(RemoteAudioVideoRendererIdentifier identifier)
{
    auto iterator = m_renderers.find(identifier);
    ASSERT(iterator != m_renderers.end());
    return iterator->value;
}

void RemoteAudioVideoRendererProxyManager::setPreferences(RemoteAudioVideoRendererIdentifier identifier, WebCore::VideoRendererPreferences preferences)
{
    if (RefPtr renderer = rendererFor(identifier)) {
        renderer->setPreferences(preferences);
        contextFor(identifier).preferences = preferences;
    }
}

void RemoteAudioVideoRendererProxyManager::addTrack(RemoteAudioVideoRendererIdentifier identifier, WebCore::AudioVideoRenderer::TrackType type, CompletionHandler<void(std::expected<TrackIdentifier, PlatformMediaError>)>&& completionHandler)
{
    RefPtr renderer = rendererFor(identifier);
    if (!renderer) {
        completionHandler(makeUnexpected(PlatformMediaError::NotSupportedError));
        return;
    }
    // The Swift state hears when an audio track needs re-enqueuing.
    if (auto trackIdentifier = renderer->addTrack(type)) {
        completionHandler(*trackIdentifier);
        return;
    }
    completionHandler(makeUnexpected(PlatformMediaError::NotSupportedError));
}

MediaSampleConverter& RemoteAudioVideoRendererProxyManager::converterFor(RendererContext& context, TrackIdentifier trackIdentifier)
{
    return context.converters.ensure(trackIdentifier, [] {
        return WebCore::MediaSampleConverter { };
    }).iterator->value;
}

void RemoteAudioVideoRendererProxyManager::newTrackInfoForTrack(RemoteAudioVideoRendererIdentifier identifier, TrackIdentifier trackIdentifier, Ref<const WebCore::TrackInfo>&& info)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());

    MESSAGE_CHECK(m_renderers.contains(identifier));
    converterFor(contextFor(identifier), trackIdentifier).setTrackInfo(WTF::move(info));
}

void RemoteAudioVideoRendererProxyManager::enqueueSample(RemoteAudioVideoRendererIdentifier identifier, TrackIdentifier trackIdentifier, WebCore::MediaSamplesBlock&& samplesBlock, std::optional<MediaTime> minimumPresentationTime, CompletionHandler<void(bool)>&& completionHandler)
{
    auto iterator = m_renderers.find(identifier);
    MESSAGE_CHECK_COMPLETION(iterator != m_renderers.end(), completionHandler(false));

    auto& converter = converterFor(iterator->value, trackIdentifier);
    MESSAGE_CHECK_COMPLETION(!!converter.currentTrackInfo(), completionHandler(false));
    if (RefPtr mediaSample = converter.convert(WTF::move(samplesBlock))) {
        iterator->value.renderer->enqueueSample(trackIdentifier, mediaSample.releaseNonNull(), minimumPresentationTime);
        completionHandler(iterator->value.renderer->isReadyForMoreSamples(trackIdentifier));
        return;
    }
    completionHandler(false);
}

void RemoteAudioVideoRendererProxyManager::setSpatialTrackingInfo(RemoteAudioVideoRendererIdentifier identifier, bool prefersSpatialAudioExperience, WebCore::MediaPlayerSoundStageSize soundStage, const String& sceneIdentifier, const String& defaultLabel, const String& label)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setSpatialTrackingInfo(prefersSpatialAudioExperience, soundStage, sceneIdentifier, defaultLabel, label);
}

// SynchronizerInterface
void RemoteAudioVideoRendererProxyManager::play(RemoteAudioVideoRendererIdentifier identifier, std::optional<MonotonicTime> hostTime)
{
    auto iterator = m_renderers.find(identifier);
    MESSAGE_CHECK(iterator != m_renderers.end());
    if (iterator == m_renderers.end())
        return;
    auto& context = iterator->value;

    context.renderer->play(hostTime);
}

void RemoteAudioVideoRendererProxyManager::pause(RemoteAudioVideoRendererIdentifier identifier, std::optional<MonotonicTime> hostTime)
{
    auto iterator = m_renderers.find(identifier);
    MESSAGE_CHECK(iterator != m_renderers.end());
    if (iterator == m_renderers.end())
        return;
    auto& context = iterator->value;

    context.renderer->pause(hostTime);
}

void RemoteAudioVideoRendererProxyManager::setScreenReserved(RemoteAudioVideoRendererIdentifier identifier, bool reserved)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setScreenReserved(reserved);
}

#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
void RemoteAudioVideoRendererProxyManager::setOutputDeviceId(RemoteAudioVideoRendererIdentifier identifier, const String& deviceId)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setOutputDeviceId(deviceId);
}
#endif

void RemoteAudioVideoRendererProxyManager::setIsVisible(RemoteAudioVideoRendererIdentifier identifier, bool visible)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setIsVisible(visible);
}

void RemoteAudioVideoRendererProxyManager::setPresentationSize(RemoteAudioVideoRendererIdentifier identifier, const WebCore::IntSize& size)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setPresentationSize(size);
}

void RemoteAudioVideoRendererProxyManager::setShouldMaintainAspectRatio(RemoteAudioVideoRendererIdentifier identifier, bool maintain)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setShouldMaintainAspectRatio(maintain);
}

void RemoteAudioVideoRendererProxyManager::contentBoxRectChanged(RemoteAudioVideoRendererIdentifier identifier, const WebCore::LayoutRect& rect)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->contentBoxRectChanged(rect);
}

void RemoteAudioVideoRendererProxyManager::setShouldDisableHDR(RemoteAudioVideoRendererIdentifier identifier, bool disable)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setShouldDisableHDR(disable);
}

void RemoteAudioVideoRendererProxyManager::setPlatformDynamicRangeLimit(RemoteAudioVideoRendererIdentifier identifier, const WebCore::PlatformDynamicRangeLimit& limit)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setPlatformDynamicRangeLimit(limit);
}

void RemoteAudioVideoRendererProxyManager::setResourceOwner(RemoteAudioVideoRendererIdentifier identifier, const WebCore::ProcessIdentity& resourceOwner)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setResourceOwner(resourceOwner);
}

void RemoteAudioVideoRendererProxyManager::flushAndRemoveImage(RemoteAudioVideoRendererIdentifier identifier)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->flushAndRemoveImage();
}

void RemoteAudioVideoRendererProxyManager::currentVideoFrame(RemoteAudioVideoRendererIdentifier identifier, RemoteVideoFrameReference reference, CompletionHandler<void(std::optional<RemoteVideoFrameProxy::Properties>)>&& completionHandler) const
{
    RefPtr renderer = rendererFor(identifier);
    if (!renderer) {
        completionHandler(std::nullopt);
        return;
    }
    std::optional<RemoteVideoFrameProxy::Properties> result;
    if (RefPtr videoFrame = renderer->currentVideoFrame()) {
        result = RemoteVideoFrameProxy::properties(*videoFrame);
        m_videoFrameObjectHeap->add(reference, videoFrame.releaseNonNull());
    }
    completionHandler(WTF::move(result));
}

void RemoteAudioVideoRendererProxyManager::currentBitmapImage(RemoteAudioVideoRendererIdentifier identifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>&& completionHandler) const
{
    RefPtr renderer = rendererFor(identifier);
    if (!renderer) {
        completionHandler(std::nullopt);
        return;
    }
    renderer->currentBitmapImage()->whenSettled(RunLoop::mainSingleton(), [completionHandler = WTF::move(completionHandler)](auto&& result) mutable {
        if (!result) {
            completionHandler(std::nullopt);
            return;
        }
        completionHandler(protect(*result)->createHandle());
    });
}

#if ENABLE(VIDEO_PRESENTATION_MODE)
void RemoteAudioVideoRendererProxyManager::setVideoFullscreenFrame(RemoteAudioVideoRendererIdentifier identifier, const WebCore::FloatRect& frame)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setVideoFullscreenFrame(frame);
}

void RemoteAudioVideoRendererProxyManager::isInFullscreenOrPictureInPictureChanged(RemoteAudioVideoRendererIdentifier identifier, bool isInFullscreen)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->isInFullscreenOrPictureInPictureChanged(isInFullscreen);
}
#endif

void RemoteAudioVideoRendererProxyManager::syncTextTrackBounds(RemoteAudioVideoRendererIdentifier identifier)
{
    if (RefPtr renderer = rendererFor(identifier))
        renderer->syncTextTrackBounds();
}

RemoteAudioVideoRendererState RemoteAudioVideoRendererProxyManager::stateFor(RemoteAudioVideoRendererIdentifier identifier) const
{
    auto iterator = m_renderers.find(identifier);
    if (iterator == m_renderers.end())
        return { };
    return {
        .paused = iterator->value.renderer->paused(),
    };
}

std::optional<FloatRect> RemoteAudioVideoRendererProxyManager::hostedVideoLayerBoundsForTesting(HTMLMediaElementIdentifier mediaElementIdentifier) const
{
    for (auto& context : m_renderers.values()) {
        if (!context.mediaElementIdentifier || *context.mediaElementIdentifier != mediaElementIdentifier)
            continue;
        if (auto bounds = context.layerHostingContextManager.rootLayerBoundsForTesting())
            return bounds;
    }
    return std::nullopt;
}

void RemoteAudioVideoRendererProxyManager::rendereringModeChanged(RemoteAudioVideoRendererIdentifier identifier)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());

    MESSAGE_CHECK(m_renderers.contains(identifier));

    auto state = stateFor(identifier);

    auto& context = contextFor(identifier);

    bool canShowWhileLocked = false;
#if PLATFORM(IOS_FAMILY)
    canShowWhileLocked = context.preferences.contains(VideoRendererPreference::CanShowWhileLocked);
#endif

    // See webkit.org/b/299655
    SUPPRESS_FORWARD_DECL_ARG if (auto maybeHostingContext = context.layerHostingContextManager.createHostingContextIfNeeded(context.renderer->platformVideoLayer(), canShowWhileLocked))
        publishAndSend(identifier, Messages::AudioVideoRendererRemoteMessageReceiver::LayerHostingContextChanged(state, *maybeHostingContext, context.layerHostingContextManager.videoLayerSize()));
    publishAndSend(identifier, Messages::AudioVideoRendererRemoteMessageReceiver::RenderingModeChanged(state));
}

void RemoteAudioVideoRendererProxyManager::setVideoLayerSize(RemoteAudioVideoRendererIdentifier identifier, const WebCore::FloatSize& size)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString(), ", size: ", size.width(), "x", size.height());

    MESSAGE_CHECK(m_renderers.contains(identifier));

    auto& context = contextFor(identifier);
    context.layerHostingContextManager.setVideoLayerSize(size);
}

void RemoteAudioVideoRendererProxyManager::setVideoLayerSizeFenced(RemoteAudioVideoRendererIdentifier identifier, const WebCore::FloatSize& size, WTF::MachSendRightAnnotated&& sendRightAnnotated)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString(), size.width(), "x", size.height());

    MESSAGE_CHECK(m_renderers.contains(identifier));

    auto& context = contextFor(identifier);
    context.layerHostingContextManager.setVideoLayerSizeFenced(size, WTF::MachSendRightAnnotated { sendRightAnnotated }, [&] {
        context.renderer->setVideoLayerSizeFenced(size, WTF::move(sendRightAnnotated));
    });
}

void RemoteAudioVideoRendererProxyManager::requestHostingContext(RemoteAudioVideoRendererIdentifier identifier, LayerHostingContextCallback&& completionHandler)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());
    MESSAGE_CHECK_COMPLETION(m_renderers.contains(identifier), completionHandler({ }));
    contextFor(identifier).layerHostingContextManager.requestHostingContext()->whenSettled(RunLoop::mainSingleton(), [completionHandler = WTF::move(completionHandler)](auto&& result) mutable {
        if (!result) {
            completionHandler({ });
            return;
        }
        completionHandler(WTF::move(*result));
    });
}

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
void RemoteAudioVideoRendererProxyManager::setLegacyCDMSession(RemoteAudioVideoRendererIdentifier identifier, std::optional<RemoteLegacyCDMSessionIdentifier> instanceId)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());

    RefPtr renderer = rendererFor(identifier);
    if (!renderer)
        return;

    if (!instanceId) {
        renderer->setCDMSession(nullptr);
        return;
    }
    if (RefPtr cdmSession = m_gpuConnectionToWebProcess.get()->legacyCdmFactoryProxy().getSession(*instanceId))
        renderer->setCDMSession(protect(cdmSession->session()).get());
    else
        ALWAYS_LOG(LOGIDENTIFIER, "Unable to find LegacyCDMSession: ", instanceId->loggingString());
}
#endif

#if ENABLE(ENCRYPTED_MEDIA)
void RemoteAudioVideoRendererProxyManager::setCDMInstance(RemoteAudioVideoRendererIdentifier identifier, std::optional<RemoteCDMInstanceIdentifier> instanceId)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());

    RefPtr renderer = rendererFor(identifier);
    if (!renderer)
        return;

    if (!instanceId) {
        renderer->setCDMInstance(nullptr);
        return;
    }
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    Ref factory = m_gpuConnectionToWebProcess.get()->cdmFactoryProxy();
    if (RefPtr instance = factory->cdmInstance(*instanceId)) {
        renderer->setCDMInstance(instance.get());
        return;
    }
    // A ClearKey instance, which has no C++ instance: the renderers only decrypt with FairPlay Streaming's.
    if (factory->hasInstance(instanceId->toUInt64())) {
        renderer->setCDMInstance(nullptr);
        return;
    }
#endif
    ALWAYS_LOG(LOGIDENTIFIER, "Unable to find CDMInstance: ", instanceId->loggingString());
}

void RemoteAudioVideoRendererProxyManager::setInitData(RemoteAudioVideoRendererIdentifier identifier, Ref<WebCore::SharedBuffer> initData, CompletionHandler<void(std::expected<void, WebCore::PlatformMediaError>)>&& completionHandler)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());
    if (RefPtr renderer = rendererFor(identifier))
        renderer->setInitData(initData)->whenSettled(RunLoop::mainSingleton(), WTF::move(completionHandler));
}

void RemoteAudioVideoRendererProxyManager::attemptToDecrypt(RemoteAudioVideoRendererIdentifier identifier)
{
    ALWAYS_LOG(LOGIDENTIFIER, identifier.loggingString());
    if (RefPtr renderer = rendererFor(identifier))
        renderer->attemptToDecrypt();
}

#endif

#if !RELEASE_LOG_DISABLED
WTFLogChannel& RemoteAudioVideoRendererProxyManager::logChannel() const
{
    return WebKit2LogMedia;
}
#endif

} // namespace WebKit

#undef MESSAGE_CHECK
#undef MESSAGE_CHECK_COMPLETION

#endif
