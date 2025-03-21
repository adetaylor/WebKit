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

#if PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#include "Connection.h"
#include "SharedCARingBuffer.h"
#include "WebProcess.h"
#include "WorkQueueMessageReceiver.h"
#include <WebCore/CAAudioStreamDescription.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/SharedMemory.h>
#include <WebCore/WebAudioBufferList.h>
#include <wtf/TZoneMalloc.h>

namespace WebKit {

class RemoteAudioSourceProvider;

class RemoteAudioSourceProviderManager : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {
public:
    static Ref<RemoteAudioSourceProviderManager> create() { return adoptRef(*new RemoteAudioSourceProviderManager()); }
    ~RemoteAudioSourceProviderManager();
    void stopListeningForIPC();

    void addProvider(Ref<RemoteAudioSourceProvider>&&);
    void removeProvider(WebCore::MediaPlayerIdentifier);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);

private:
    RemoteAudioSourceProviderManager();

    // Messages
    void audioStorageChanged(WebCore::MediaPlayerIdentifier, ConsumerSharedCARingBuffer::Handle&&, const WebCore::CAAudioStreamDescription&);
    void audioSamplesAvailable(WebCore::MediaPlayerIdentifier, uint64_t startFrame, uint64_t numberOfFrames, bool needsFlush);

    void setConnection(RefPtr<IPC::Connection>&&);

    class RemoteAudio {
        WTF_MAKE_TZONE_ALLOCATED(RemoteAudio);
    public:
        explicit RemoteAudio(Ref<RemoteAudioSourceProvider>&&);

        void setStorage(ConsumerSharedCARingBuffer::Handle&&, const WebCore::CAAudioStreamDescription&);
        void audioSamplesAvailable(uint64_t startFrame, uint64_t numberOfFrames, bool needsFlush);

    private:
        const Ref<RemoteAudioSourceProvider> m_provider;
        std::optional<WebCore::CAAudioStreamDescription> m_description;
        std::unique_ptr<ConsumerSharedCARingBuffer> m_ringBuffer;
        std::unique_ptr<WebCore::WebAudioBufferList> m_buffer;
    };

    const Ref<WorkQueue> m_queue;
    RefPtr<IPC::Connection> m_connection;

    // background thread member
    HashMap<WebCore::MediaPlayerIdentifier, std::unique_ptr<RemoteAudio>> m_providers;
};

} // namespace WebKit

#endif // PLATFORM(COCOA) && ENABLE(GPU_PROCESS)
