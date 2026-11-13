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

#include "MessageReceiver.h"
#include "RemoteAudioSessionConfiguration.h"
#include <WebCore/AudioSession.h>
#include <WebCore/ProcessIdentifier.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WeakPtr.h>
#include <wtf/WeakRef.h>

namespace IPC {
class Connection;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteAudioSessionProxyManager;
struct SharedPreferencesForWebProcess;

// Receives the audio session messages of one web process's connection to the GPU process. Its state (category, mode,
// route sharing policy, preferred buffer size, sound stage size, activity, interruption) is Swift's
// (RemoteAudioSessionProxyManager.swift), keyed by identifier(), which handles the messages that change it; C++ handles the
// ones that need the audio session's promises or a String.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteAudioSessionProxy.swift") RemoteAudioSessionProxy
    : public RefCounted<RemoteAudioSessionProxy>, public IPC::MessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteAudioSessionProxy);
    friend class RemoteAudioSessionProxyManager;
public:
    static Ref<RemoteAudioSessionProxy> create(GPUConnectionToWebProcess& gpuConnection)
    {
        return adoptRef(*new RemoteAudioSessionProxy(gpuConnection));
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    virtual ~RemoteAudioSessionProxy();

    uint64_t identifier() const { return m_identifier; }
    WebCore::ProcessIdentifier processIdentifier();
    RemoteAudioSessionConfiguration configuration();

    // Implemented in Swift.
    bool isActive() const;

    void configurationChanged();
    void beginInterruption();
    void endInterruption(WebCore::AudioSession::MayResume);

    const String& sceneIdentifier() const LIFETIME_BOUND { return m_sceneIdentifier; }

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() const;
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

#if PLATFORM(IOS_FAMILY)
    void setPreferredSpeakerID(const String&);
#endif

private:
    explicit RemoteAudioSessionProxy(GPUConnectionToWebProcess&);

    // Messages handled in C++.
    using SetActiveCompletion = CompletionHandler<void(bool)>;
    void tryToSetActive(bool, SetActiveCompletion&&);
    void tryToSetActiveSync(bool, SetActiveCompletion&&);
    void systemCategoryForTesting(CompletionHandler<void(WebCore::AudioSessionCategory)>&&);
    void systemActivationCountForTesting(CompletionHandler<void(uint64_t)>&&);
    void triggerBeginInterruptionForTesting();
    void triggerEndInterruptionForTesting();
    void beginInterruptionRemote();
    void endInterruptionRemote(WebCore::AudioSession::MayResume);
    void setSceneIdentifier(const String&);

    // Implemented in Swift: the sound stage size, and, once the session's activity changed as asked, whether that changed the
    // proxy's.
    WebCore::AudioSession::SoundStageSize soundStageSize() const;
    bool didSetActive(bool active);

    RemoteAudioSessionProxyManager& audioSessionManager();
    IPC::Connection& connection() const;

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnection;
    const uint64_t m_identifier;
    String m_sceneIdentifier;
#if PLATFORM(IOS_FAMILY)
    String m_speakerID;
#endif
};

}

#endif
