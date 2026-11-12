/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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
#include "RemoteAudioSessionProxyManager.h"

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "GPUProcessConnectionMessages.h"
#include "Logging.h"
#include "RemoteAudioSessionProxy.h"
#include <WebCore/AudioSession.h>
#include <WebCore/CoreAudioCaptureSource.h>
#include <WebCore/PlatformMediaSessionManager.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(IOS_FAMILY)
#include <WebCore/MediaSessionHelperIOS.h>
#endif

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteAudioSessionProxyManager);

RemoteAudioSessionProxyManager::RemoteAudioSessionProxyManager(GPUProcess& gpuProcess)
    : m_gpuProcess(gpuProcess)
{
    AudioSession::addInterruptionObserver(*this);
    AudioSession::singleton().addConfigurationChangeObserver(*this);
}

RemoteAudioSessionProxyManager::~RemoteAudioSessionProxyManager()
{
    AudioSession::removeInterruptionObserver(*this);
    AudioSession::singleton().removeConfigurationChangeObserver(*this);
}

void RemoteAudioSessionProxyManager::addProxy(RemoteAudioSessionProxy& proxy, std::optional<audit_token_t> auditToken)
{
    ASSERT(!m_proxies.contains(proxy));
    m_proxies.add(proxy);
    addSwiftProxy(proxy.identifier(), proxy.processIdentifier().toUInt64());

    if (auditToken)
        AudioSession::singleton().setHostProcessAttribution(*auditToken);
}

void RemoteAudioSessionProxyManager::removeProxy(RemoteAudioSessionProxy& proxy)
{
    ASSERT(m_proxies.contains(proxy));
    m_proxies.remove(proxy);
    removeSwiftProxy(proxy.identifier());
}

RefPtr<RemoteAudioSessionProxy> RemoteAudioSessionProxyManager::proxy(uint64_t identifier)
{
    for (Ref proxy : m_proxies) {
        if (proxy->identifier() == identifier)
            return proxy;
    }
    return nullptr;
}

void RemoteAudioSessionProxyManager::setSessionCategory(AudioSessionCategory category, AudioSessionMode mode, RouteSharingPolicy policy)
{
    AudioSession::singleton().setCategory(category, mode, policy);
}

void RemoteAudioSessionProxyManager::setSessionPreferredBufferSize(uint64_t preferredBufferSize)
{
    AudioSession::singleton().setPreferredBufferSize(preferredBufferSize);
}

void RemoteAudioSessionProxyManager::setSessionIsPlayingToBluetoothOverride(bool hasValue, bool value)
{
    AudioSession::singleton().setIsPlayingToBluetoothOverride(hasValue ? std::optional<bool> { value } : std::nullopt);
}

void RemoteAudioSessionProxyManager::setSessionSpatialExperience(uint64_t proxyIdentifier, AudioSessionSoundStageSize soundStageSize)
{
    String sceneIdentifier;
    if (RefPtr proxy = proxyIdentifier ? protect(GPUProcess::singleton().audioSessionManager())->proxy(proxyIdentifier) : nullptr)
        sceneIdentifier = proxy->sceneIdentifier();
    AudioSession::singleton().setSceneIdentifier(sceneIdentifier);
    AudioSession::singleton().setSoundStageSize(soundStageSize);
}

void RemoteAudioSessionProxyManager::beginProxyInterruption(uint64_t proxyIdentifier)
{
    if (RefPtr proxy = protect(GPUProcess::singleton().audioSessionManager())->proxy(proxyIdentifier))
        proxy->beginInterruption();
}

void RemoteAudioSessionProxyManager::endProxyInterruption(uint64_t proxyIdentifier, bool mayResume)
{
    if (RefPtr proxy = protect(GPUProcess::singleton().audioSessionManager())->proxy(proxyIdentifier))
        proxy->endInterruption(mayResume ? AudioSession::MayResume::Yes : AudioSession::MayResume::No);
}

#if PLATFORM(IOS_FAMILY)
static void providePresentingApplicationPID(RemoteAudioSessionProxy& proxy)
{
    RefPtr webProcessConnection = proxy.gpuConnectionToWebProcess();
    if (!webProcessConnection)
        return;

#if ENABLE(EXTENSION_CAPABILITIES)
    if (webProcessConnection->sharedPreferencesForWebProcessValue().mediaCapabilityGrantsEnabled)
        return;
#endif

    ProcessID pid = protect(GPUProcess::singleton().parentProcessConnection())->remoteProcessID();

#if !PLATFORM(APPLETV)
    // Presenting application audit tokens are per-page, but AudioSessions are per-web-process,
    // and it's not straightforward to know in the GPU process which page is responsible for activating
    // the shared AVAudioSession. In reality, all pages in a given web process share a presenting
    // application, so it's sufficient to use the first page's audit token.
    auto& auditTokens = webProcessConnection->presentingApplicationAuditTokens();
    if (!auditTokens.isEmpty())
        pid = webProcessConnection->presentingApplicationPID(*auditTokens.keys().begin());
#ifndef NDEBUG
    for (auto& pageIdentifier : auditTokens.keys())
        ASSERT(pid == webProcessConnection->presentingApplicationPID(pageIdentifier));
#endif
#endif

    protect(MediaSessionHelper::sharedHelper())->providePresentingApplicationPID(pid);
}
#endif

Ref<AudioSession::SetActivePromise> RemoteAudioSessionProxyManager::tryToSetActiveForProcess(RemoteAudioSessionProxy& proxy, bool active)
{
    ASSERT(m_proxies.contains(proxy));

#if PLATFORM(IOS_FAMILY)
    if (active)
        providePresentingApplicationPID(proxy);
#endif

    switch (swiftActivation(proxy.identifier(), active)) {
    case RemoteAudioSessionActivation::None:
        return AudioSession::SetActivePromise::createAndResolve();
    case RemoteAudioSessionActivation::Activate:
        return AudioSession::singleton().tryToSetActive(true);
    case RemoteAudioSessionActivation::Deactivate:
        return AudioSession::singleton().tryToSetActive(false);
    }
    ASSERT_NOT_REACHED();
    return AudioSession::SetActivePromise::createAndResolve();
}

#if PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)
void RemoteAudioSessionProxyManager::beginCapturePreview(CompletionHandler<void()>&& completionHandler)
{
    if (isCapturePreviewActive()) {
        if (!m_capturePreviewActivationHandlers.isEmpty()) {
            m_capturePreviewActivationHandlers.append(WTF::move(completionHandler));
            return;
        }
        return completionHandler();
    }

    setCapturePreviewActive(true);

    m_capturePreviewActivationHandlers.append(WTF::move(completionHandler));
    unsigned activation = ++m_capturePreviewActivationCount;
    AudioSession::singleton().tryToSetActive(true)->whenSettled(RunLoop::mainSingleton(), [protectedThis = Ref { *this }, activation](auto&& result) {
        if (!result)
            RELEASE_LOG_ERROR(WebRTC, "RemoteAudioSessionProxyManager::beginCapturePreview unable to activate the audio session for a capture preview");

        if (activation != protectedThis->m_capturePreviewActivationCount)
            return;

        for (auto& handler : std::exchange(protectedThis->m_capturePreviewActivationHandlers, { }))
            handler();
    });
}

void RemoteAudioSessionProxyManager::endCapturePreview()
{
    if (!isCapturePreviewActive())
        return;

    // An activation still in flight must not run these later, so run them now.
    ++m_capturePreviewActivationCount;
    auto activationHandlers = std::exchange(m_capturePreviewActivationHandlers, { });

    setCapturePreviewActive(false);

    if (!hasActiveProxy())
        AudioSession::singleton().tryToSetActive(false)->whenSettled(RunLoop::mainSingleton(), [](auto&&) { });

    for (auto& handler : activationHandlers)
        handler();
}
#endif

void RemoteAudioSessionProxyManager::updatePresentingProcesses()
{
    Vector<audit_token_t> presentingProcesses;
    bool shouldAppendParentProcess = false;

    // AVAudioSession will take out an assertion on all the "presenting applications"
    // when it moves to a "playing" state. But it's possible that (e.g.) multiple
    // applications may be using SafariViewService simultaneously. So only include
    // tokens from those proxies whose sessions are currently "active". Only their
    // presenting applications will be kept from becoming "suspended" during playback.
    m_proxies.forEach([&](auto& proxy) {
        Ref gpuConnectionToWebProcess = *proxy.gpuConnectionToWebProcess();
#if ENABLE(EXTENSION_CAPABILITIES)
        if (gpuConnectionToWebProcess->sharedPreferencesForWebProcessValue().mediaCapabilityGrantsEnabled)
            return;
#endif
        shouldAppendParentProcess = true;
        if (!proxy.isActive())
            return;
        for (auto& token : gpuConnectionToWebProcess->presentingApplicationAuditTokens().values())
            presentingProcesses.append(token.auditToken());
    });

    if (auto token = protect(m_gpuProcess->parentProcessConnection())->getAuditToken(); token && shouldAppendParentProcess)
        presentingProcesses.append(*token);

    if (!presentingProcesses.isEmpty())
        AudioSession::singleton().setPresentingProcesses(WTF::move(presentingProcesses));
}

void RemoteAudioSessionProxyManager::beginInterruptionRemote()
{
    Ref session = this->session();
    // Temporarily remove as an observer to avoid a spurious IPC back to the web process.
    AudioSession::removeInterruptionObserver(*this);
    session->beginInterruption();
    AudioSession::addInterruptionObserver(*this);
}

void RemoteAudioSessionProxyManager::endInterruptionRemote(AudioSession::MayResume mayResume)
{
    Ref session = this->session();
    // Temporarily remove as an observer to avoid a spurious IPC back to the web process.
    AudioSession::removeInterruptionObserver(*this);
    session->endInterruption(mayResume);
    AudioSession::addInterruptionObserver(*this);
}

void RemoteAudioSessionProxyManager::beginAudioSessionInterruption()
{
    swiftBeginAudioSessionInterruption();
}

void RemoteAudioSessionProxyManager::endAudioSessionInterruption(AudioSession::MayResume mayResume)
{
    swiftEndAudioSessionInterruption(mayResume == AudioSession::MayResume::Yes);
}

void RemoteAudioSessionProxyManager::hardwareMutedStateDidChange(const AudioSession& session)
{
    configurationDidChange(session);
}

void RemoteAudioSessionProxyManager::bufferSizeDidChange(const AudioSession& session)
{
    configurationDidChange(session);
}

void RemoteAudioSessionProxyManager::sampleRateDidChange(const AudioSession& session)
{
    configurationDidChange(session);
}

void RemoteAudioSessionProxyManager::configurationDidChange(const WebCore::AudioSession&)
{
    m_proxies.forEach([](auto& proxy) {
        proxy.configurationChanged();
    });
}

}

#endif
