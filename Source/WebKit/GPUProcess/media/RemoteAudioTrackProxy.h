/*
* Copyright (C) 2020 Apple Inc. All rights reserved.
*
* Redistribution and use in source and binary forms, with or without
* modification, are permitted provided that the following conditions
* are met:
*
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

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)

#include "AudioTrackPrivateRemoteConfiguration.h"
#include <WebCore/AudioTrackPrivate.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/TrackBase.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace IPC {
class Connection;
}

namespace WebKit {

class GPUConnectionToWebProcess;

// On Cocoa, Swift (RemoteAudioTrackProxy.swift) implements what the track's changes send to the web process.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteAudioTrackProxy.swift") RemoteAudioTrackProxy final
    : public ThreadSafeRefCounted<RemoteAudioTrackProxy, WTF::DestructionThread::Main>
    , public WebCore::AudioTrackPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED(RemoteAudioTrackProxy);
public:
    static Ref<RemoteAudioTrackProxy> create(GPUConnectionToWebProcess& connectionToWebProcess, WebCore::AudioTrackPrivate& trackPrivate, WebCore::MediaPlayerIdentifier mediaPlayerIdentifier)
    {
        Ref proxy = adoptRef(*new RemoteAudioTrackProxy(connectionToWebProcess, trackPrivate, mediaPlayerIdentifier));
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
        proxy->addToWebProcess();
#endif
        return proxy;
    }

    virtual ~RemoteAudioTrackProxy();

    // WebCore::AudioTrackPrivateClient.
    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    WebCore::TrackID id() const { return m_trackPrivate->id(); };
    void setEnabled(bool enabled)
    {
        m_enabled = enabled;
        m_trackPrivate->setEnabled(enabled);
    }
    bool operator==(const WebCore::AudioTrackPrivate& track) const { return track == m_trackPrivate.get(); }

private:
    RemoteAudioTrackProxy(GPUConnectionToWebProcess&, WebCore::AudioTrackPrivate&, WebCore::MediaPlayerIdentifier);

    // AudioTrackPrivateClient
    void enabledChanged(bool) final;
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    void configurationChanged(const WebCore::PlatformAudioTrackConfiguration&) final { configurationChanged(); }
#else
    void configurationChanged(const WebCore::PlatformAudioTrackConfiguration&) final;
#endif

    // TrackPrivateBaseClient
    void idChanged(WebCore::TrackID) final;
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    void labelChanged(const String&) final { configurationChanged(); }
    void languageChanged(const String&) final { configurationChanged(); }
#else
    void labelChanged(const String&) final;
    void languageChanged(const String&) final;
#endif
    void willRemove() final;

    void configurationChanged();
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    void addToWebProcess();
    WebCore::AudioTrackPrivate& trackPrivate() const { return m_trackPrivate.get(); }
    // Swift doesn't import AudioTrackPrivate::configuration(), which returns a reference.
    WebCore::PlatformAudioTrackConfiguration trackConfiguration() const { return m_trackPrivate->configuration(); }
    IPC::Connection* WTF_NULLABLE webProcessConnection() const SWIFT_RETURNS_RETAINED;
#else
    AudioTrackPrivateRemoteConfiguration configuration();
#endif

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connectionToWebProcess;
    const Ref<WebCore::AudioTrackPrivate> m_trackPrivate;
    WebCore::TrackID m_id;
    WebCore::MediaPlayerIdentifier m_mediaPlayerIdentifier;
    bool m_enabled { false };
    size_t m_clientId { 0 };
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
