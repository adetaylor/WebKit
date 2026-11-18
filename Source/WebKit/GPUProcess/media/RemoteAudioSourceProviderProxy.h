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

#if ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)

#include "Connection.h"
#include "RemoteAudioSourceProviderManagerMessages.h"
#include "SharedCARingBuffer.h"
#include <WebCore/AudioSourceProviderAVFObjC.h>
#include <WebCore/AudioSourceProviderClient.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WebKit {

// Tells the web process about a media player's audio source provider: the ring buffer its audio goes to, and its settings.
// The provider calls it on its audio thread, for each buffer, so it stays C++.
class RemoteAudioSourceProviderProxy : public ThreadSafeRefCounted<RemoteAudioSourceProviderProxy>, public WebCore::AudioSourceProviderClient {
public:
    static Ref<RemoteAudioSourceProviderProxy> create(WebCore::MediaPlayerIdentifier identifier, Ref<IPC::Connection>&& connection, WebCore::AudioSourceProviderAVFObjC& localProvider)
    {
        Ref remoteProvider = adoptRef(*new RemoteAudioSourceProviderProxy(identifier, WTF::move(connection)));
        localProvider.setConfigureAudioStorageCallback([remoteProvider](auto&&... args) {
            return remoteProvider->configureAudioStorage(args...);
        });
        localProvider.setAudioCallback([remoteProvider](auto, auto, bool needsFlush) {
            if (needsFlush)
                remoteProvider->send(Messages::RemoteAudioSourceProviderManager::SetNeedsFlush { remoteProvider->m_identifier });
        });
        return remoteProvider;
    }

    void setPlaybackRate(double playbackRate) { send(Messages::RemoteAudioSourceProviderManager::SetPlaybackRate { m_identifier, playbackRate }); }
    void setPreservesPitch(bool preservesPitch) { send(Messages::RemoteAudioSourceProviderManager::SetPreservesPitch { m_identifier, preservesPitch }); }
    void setVolume(double volume) { send(Messages::RemoteAudioSourceProviderManager::SetVolume { m_identifier, volume }); }

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

private:
    RemoteAudioSourceProviderProxy(WebCore::MediaPlayerIdentifier identifier, Ref<IPC::Connection>&& connection)
        : m_identifier(identifier)
        , m_connection(WTF::move(connection))
    {
    }

    // AudioSourceProviderClient
    void setFormat(size_t, float) final { }

    template<typename Message> void send(Message&& message) { m_connection->send(std::forward<Message>(message), 0); }

    std::unique_ptr<WebCore::CARingBuffer> configureAudioStorage(const WebCore::CAAudioStreamDescription& format, size_t frameCount)
    {
        auto result = ProducerSharedCARingBuffer::allocate(format, frameCount);
        RELEASE_ASSERT(result); // FIXME(https://bugs.webkit.org/show_bug.cgi?id=262690): Handle allocation failure.
        auto [ringBuffer, handle] = WTF::move(*result);
        send(Messages::RemoteAudioSourceProviderManager::AudioStorageChanged { m_identifier, WTF::move(handle), format });
        // Use a redundant variable to avoid move in return position and to obtain copy elision. Clang or libc++ does not allow returning covariant of Ts from std::unique_ptr<T>s in this position.
        std::unique_ptr<WebCore::CARingBuffer> caRingBuffer = WTF::move(ringBuffer); // NOLINT: see above.
        return caRingBuffer;
    }

    const WebCore::MediaPlayerIdentifier m_identifier;
    const Ref<IPC::Connection> m_connection;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
