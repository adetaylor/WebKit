/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
#include "GPUConnectionToWebProcess.h"
#include "MessageReceiver.h"
#include "SandboxExtension.h"
#include <WebCore/HTMLMediaElementIdentifier.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/ShareableBitmap.h>
#include <WebCore/VideoTarget.h>
#include <wtf/HashMap.h>
#include <wtf/Logger.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WeakPtr.h>

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
#include "SwiftCoding.h"
#endif

namespace WebKit {

class RemoteMediaPlayerProxy;
struct RemoteMediaPlayerProxyConfiguration;
struct SharedPreferencesForWebProcess;

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
using RefPtrMediaPlayer = RefPtr<WebCore::MediaPlayer>;
using RefPtrRemoteMediaPlayerProxy = RefPtr<RemoteMediaPlayerProxy>;
using OptionalFloatRect = std::optional<WebCore::FloatRect>;
#endif

// On Cocoa, Swift (RemoteMediaPlayerManagerProxy.swift) keeps the players and handles the messages that create and delete them.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebKit/RemoteMediaPlayerManagerProxy.swift") RemoteMediaPlayerManagerProxy
    : public RefCounted<RemoteMediaPlayerManagerProxy>, public IPC::MessageReceiver
{
    WTF_MAKE_TZONE_ALLOCATED(RemoteMediaPlayerManagerProxy);
public:
    static Ref<RemoteMediaPlayerManagerProxy> create(GPUConnectionToWebProcess& gpuConnectionToWebProcess)
    {
        return adoptRef(*new RemoteMediaPlayerManagerProxy(gpuConnectionToWebProcess));
    }

    ~RemoteMediaPlayerManagerProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() { return m_gpuConnectionToWebProcess.get(); }
    void clear();

    void connectionToWebProcessClosed() { clear(); }

#if !RELEASE_LOG_DISABLED
    Logger& logger() { return m_logger; }
#endif

    void didReceiveMessageFromWebProcess(IPC::Connection& connection, IPC::Decoder& decoder) { didReceiveMessage(connection, decoder); }
    void didReceiveSyncMessageFromWebProcess(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder) { return didReceiveSyncMessage(connection, decoder, encoder); }
    void didReceivePlayerMessage(IPC::Connection&, IPC::Decoder&);
    void didReceiveSyncPlayerMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    RefPtr<WebCore::MediaPlayer> mediaPlayer(std::optional<WebCore::MediaPlayerIdentifier> identifier) { return identifier ? swiftMediaPlayer(identifier->toUInt64()) : nullptr; }
#else
    RefPtr<WebCore::MediaPlayer> mediaPlayer(std::optional<WebCore::MediaPlayerIdentifier>);
#endif

#if PLATFORM(COCOA)
    SWIFT_MAIN_ACTOR std::optional<WebCore::FloatRect> hostedVideoLayerBoundsForTesting(WebCore::MediaPlayerClientIdentifier) const;
#endif

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    // For Swift.
    uint64_t identifier() const { return m_identifier; }
    GPUConnectionToWebProcess* WTF_NULLABLE swiftGPUConnection() const SWIFT_RETURNS_RETAINED { return m_gpuConnectionToWebProcess.get().leakRef(); }
    // The engine is a valid MediaPlayerMediaEngineIdentifier, which Swift has decoded.
    static bool hasMediaEngine(uint8_t engineIdentifier, bool forPlayback);
    RemoteMediaPlayerProxy* WTF_NONNULL createPlayer(GPUConnectionToWebProcess&, uint64_t identifier, uint64_t clientIdentifier, uint8_t engineIdentifier, IPC::CxxDecodedArgument<RemoteMediaPlayerProxyConfiguration>&) SWIFT_RETURNS_RETAINED;
#endif

private:
    explicit RemoteMediaPlayerManagerProxy(GPUConnectionToWebProcess&);

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

#if !ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    void createMediaPlayer(WebCore::MediaPlayerIdentifier, WebCore::MediaPlayerClientIdentifier, WebCore::MediaPlayerEnums::MediaEngineIdentifier, RemoteMediaPlayerProxyConfiguration&&);
    void deleteMediaPlayer(WebCore::MediaPlayerIdentifier);
#endif

    // Media player factory
    void getSupportedTypes(WebCore::MediaPlayerEnums::MediaEngineIdentifier, CompletionHandler<void(Vector<String>&&)>&&);
    void supportsTypeAndCodecs(WebCore::MediaPlayerEnums::MediaEngineIdentifier, const WebCore::MediaEngineSupportParameters&&, CompletionHandler<void(WebCore::MediaPlayer::SupportsType)>&&);
    void supportsKeySystem(WebCore::MediaPlayerEnums::MediaEngineIdentifier, const String&&, const String&&, CompletionHandler<void(bool)>&&);

    static CheckedPtr<const WebCore::MediaPlayerFactory> playbackEngineForConnection(WebCore::MediaPlayerEnums::MediaEngineIdentifier);

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    // Implemented in Swift. Static where the destructor calls them, so that they don't retain the manager it destroys.
    SWIFT_MAIN_ACTOR RefPtrRemoteMediaPlayerProxy player(uint64_t identifier);
    SWIFT_MAIN_ACTOR RefPtrMediaPlayer swiftMediaPlayer(uint64_t identifier);
    static void swiftDestroy(uint64_t identifier);
#endif

#if !RELEASE_LOG_DISABLED
    ASCIILiteral logClassName() const { return "RemoteMediaPlayerManagerProxy"; }
    NODELETE WTFLogChannel& logChannel() const;
    uint64_t logIdentifier() const { return m_logIdentifier; }
#endif

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
    const uint64_t m_identifier;
#else
    HashMap<WebCore::MediaPlayerIdentifier, Ref<RemoteMediaPlayerProxy>> m_proxies;
#endif
    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
#if !RELEASE_LOG_DISABLED
    uint64_t m_logIdentifier { 0 };
    const Ref<Logger> m_logger;
#endif
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
