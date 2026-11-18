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

#include "TextTrackPrivateRemoteConfiguration.h"
#include <WebCore/ISOVTTCue.h>
#include <WebCore/InbandTextTrackPrivate.h>
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

// On Cocoa, Swift (RemoteTextTrackProxy.swift) implements what the track's changes and WebVTT cues send to the web process;
// the generic and data cues stay C++, as Swift can't import GenericCueData or hold SerializedPlatformDataCueValue.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteTextTrackProxy.swift") RemoteTextTrackProxy final
    : public ThreadSafeRefCounted<RemoteTextTrackProxy, WTF::DestructionThread::Main>
    , private WebCore::InbandTextTrackPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED(RemoteTextTrackProxy);
public:
    static Ref<RemoteTextTrackProxy> create(GPUConnectionToWebProcess& connectionToWebProcess, WebCore::InbandTextTrackPrivate& trackPrivate, WebCore::MediaPlayerIdentifier mediaPlayerIdentifier)
    {
        Ref proxy = adoptRef(*new RemoteTextTrackProxy(connectionToWebProcess, trackPrivate, mediaPlayerIdentifier));
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
        proxy->addToWebProcess();
#endif
        return proxy;
    }

    virtual ~RemoteTextTrackProxy();

    // WebCore::InbandTextTrackPrivateClient.
    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    WebCore::TrackID id() const { return m_trackPrivate->id(); }
    void setMode(WebCore::InbandTextTrackPrivate::Mode mode) { m_trackPrivate->setMode(mode); }
    bool operator==(const WebCore::InbandTextTrackPrivate& track) const { return track == m_trackPrivate.get(); }

private:
    RemoteTextTrackProxy(GPUConnectionToWebProcess&, WebCore::InbandTextTrackPrivate&, WebCore::MediaPlayerIdentifier);

    // InbandTextTrackPrivateClient
    virtual void addDataCue(const MediaTime& start, const MediaTime& end, std::span<const uint8_t>);

#if ENABLE(DATACUE_VALUE)
    virtual void addDataCue(const MediaTime& start, const MediaTime& end, Ref<WebCore::SerializedPlatformDataCue>&&, const String&);
    virtual void updateDataCue(const MediaTime& start, const MediaTime& end, WebCore::SerializedPlatformDataCue&);
    virtual void removeDataCue(const MediaTime& start, const MediaTime& end, WebCore::SerializedPlatformDataCue&);
#endif

    virtual void addGenericCue(WebCore::InbandGenericCue&);
    virtual void updateGenericCue(WebCore::InbandGenericCue&);
    virtual void removeGenericCue(WebCore::InbandGenericCue&);

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    void parseWebVTTFileHeader(String&& header) final { swiftParseWebVTTFileHeader(WTF::move(header)); }
#else
    virtual void parseWebVTTFileHeader(String&&);
#endif
    virtual void parseWebVTTCueData(std::span<const uint8_t>);
#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    void parseWebVTTCueData(WebCore::ISOWebVTTCue&& cue) final { swiftParseWebVTTCueData(WTF::move(cue)); }
#else
    virtual void parseWebVTTCueData(WebCore::ISOWebVTTCue&&);
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
    // Implemented in Swift.
    void addToWebProcess();
    void swiftParseWebVTTFileHeader(String);
    void swiftParseWebVTTCueData(WebCore::ISOWebVTTCue);

    WebCore::InbandTextTrackPrivate& trackPrivate() const { return m_trackPrivate.get(); }
    IPC::Connection* WTF_NULLABLE webProcessConnection() const SWIFT_RETURNS_RETAINED;
#else
    TextTrackPrivateRemoteConfiguration& configuration();
#endif

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connectionToWebProcess;
    const Ref<WebCore::InbandTextTrackPrivate> m_trackPrivate;
    WebCore::TrackID m_id;
    WebCore::MediaPlayerIdentifier m_mediaPlayerIdentifier;
    size_t m_clientId { 0 };
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
