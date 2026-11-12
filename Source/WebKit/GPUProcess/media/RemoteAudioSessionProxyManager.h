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

#pragma once

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION)

#include <WebCore/AudioSession.h>
#include <WebCore/ProcessIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakHashSet.h>
#include <wtf/WeakRef.h>

namespace WebKit {

class GPUProcess;
class RemoteAudioSessionProxy;

// What a proxy's request to make the audio session active or inactive does to the session.
enum class RemoteAudioSessionActivation : uint8_t {
    None,
    Activate,
    Deactivate,
};

// Applies what every web process asked of the audio session to the GPU process's AudioSession. Swift
// (RemoteAudioSessionProxyManager.swift) holds the proxies' states and decides; C++ holds the proxies, observes the session
// and changes it.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteAudioSessionProxyManager.swift") RemoteAudioSessionProxyManager
    : public RefCounted<RemoteAudioSessionProxyManager>
    , public WebCore::AudioSessionInterruptionObserver
    , private WebCore::AudioSessionConfigurationChangeObserver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteAudioSessionProxyManager);
public:
    static Ref<RemoteAudioSessionProxyManager> create(GPUProcess& gpuProcess)
    {
        return adoptRef(*new RemoteAudioSessionProxyManager(gpuProcess));
    }

    ~RemoteAudioSessionProxyManager();

    // AudioSessionConfigurationChangeObserver.
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    void addProxy(RemoteAudioSessionProxy&, std::optional<audit_token_t>);
    void removeProxy(RemoteAudioSessionProxy&);

    // Implemented in Swift.
    void updateSpatialExperience();

#if PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)
    void beginCapturePreview(CompletionHandler<void()>&&);
    void endCapturePreview();
#endif

    Ref<WebCore::AudioSession::SetActivePromise> tryToSetActiveForProcess(RemoteAudioSessionProxy&, bool);

    void beginInterruptionRemote();
    void endInterruptionRemote(WebCore::AudioSession::MayResume);

    WebCore::AudioSession& session() { return WebCore::AudioSession::singleton(); }
    const WebCore::AudioSession& session() const { return WebCore::AudioSession::singleton(); }

    void updatePresentingProcesses();

    USING_CAN_MAKE_WEAKPTR(WebCore::AudioSessionInterruptionObserver);

    // For Swift: what it decided, applied to the session, and the interruptions it tells the proxies with these identifiers.
    static void setSessionCategory(WebCore::AudioSessionCategory, WebCore::AudioSessionMode, WebCore::RouteSharingPolicy);
    static void setSessionPreferredBufferSize(uint64_t);
    static void setSessionIsPlayingToBluetoothOverride(bool hasValue, bool value);
    // The scene identifier of the proxy (none for 0) and the sound stage size.
    static void setSessionSpatialExperience(uint64_t proxyIdentifier, WebCore::AudioSessionSoundStageSize);
    static void beginProxyInterruption(uint64_t proxyIdentifier);
    static void endProxyInterruption(uint64_t proxyIdentifier, bool mayResume);

private:
    RemoteAudioSessionProxyManager(GPUProcess&);

    void beginAudioSessionInterruption() final;
    void endAudioSessionInterruption(WebCore::AudioSession::MayResume) final;

    void hardwareMutedStateDidChange(const WebCore::AudioSession&) final;
    void bufferSizeDidChange(const WebCore::AudioSession&) final;
    void sampleRateDidChange(const WebCore::AudioSession&) final;
    void configurationDidChange(const WebCore::AudioSession&);

    RefPtr<RemoteAudioSessionProxy> proxy(uint64_t identifier);

    // Implemented in Swift.
    void addSwiftProxy(uint64_t identifier, uint64_t processIdentifier);
    void removeSwiftProxy(uint64_t identifier);
    RemoteAudioSessionActivation swiftActivation(uint64_t identifier, bool active);
    void swiftBeginAudioSessionInterruption();
    void swiftEndAudioSessionInterruption(bool mayResume);
#if PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)
    bool isCapturePreviewActive() const;
    void setCapturePreviewActive(bool);
    bool hasActiveProxy() const;
#endif

    WeakRef<GPUProcess> m_gpuProcess;
    WeakHashSet<RemoteAudioSessionProxy> m_proxies;
#if PLATFORM(IOS_FAMILY) || ENABLE(ROUTING_ARBITRATION)
    Vector<CompletionHandler<void()>> m_capturePreviewActivationHandlers;
    unsigned m_capturePreviewActivationCount { 0 };
#endif
};

}

#endif
