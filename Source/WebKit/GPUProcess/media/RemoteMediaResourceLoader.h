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

#include "RemoteMediaResourceIdentifier.h"
#include "RemoteMediaResourceLoaderIdentifier.h"
#include "WorkQueueMessageReceiver.h"
#include <WebCore/PlatformMediaResourceLoader.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/SharedMemory.h>
#include <wtf/Identified.h>
#include <wtf/Lock.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>
#include <wtf/WorkQueue.h>

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
#include "RemoteMediaResource.h"
#endif

namespace IPC {
class Connection;
class Decoder;
class SharedBufferReference;
}

namespace WebKit {

class RemoteMediaPlayerProxy;
class RemoteMediaResource;

// On Cocoa platforms, the resources that the loader hands its messages to are in its Swift state, which m_swiftState
// holds (RemoteMediaResourceLoader.swift), and which also handles the messages that take no reply.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteMediaResourceLoader.swift") RemoteMediaResourceLoader final
    : public WebCore::PlatformMediaResourceLoader
    , public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>
    , public Identified<RemoteMediaResourceLoaderIdentifier> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteMediaResourceLoader);
public:
    static Ref<RemoteMediaResourceLoader> create(RemoteMediaPlayerProxy&, Ref<IPC::Connection>&&);
    ~RemoteMediaResourceLoader();

    static Ref<WorkQueue> defaultQueue()
    {
        static NeverDestroyed<Ref<WorkQueue>> messageQueue = WorkQueue::create("PlatformMediaResourceLoader"_s);
        return messageQueue.get();
    }

    static bool isCurrentQueue() { return defaultQueue()->isCurrent(); }

    void addMediaResource(RemoteMediaResourceIdentifier identifier, RemoteMediaResource& resource) { swiftAddMediaResource(identifier.toUInt64(), resource); }
    void removeMediaResource(RemoteMediaResourceIdentifier);
    RefPtr<RemoteMediaResource> resourceForId(RemoteMediaResourceIdentifier identifier) { return swiftMediaResource(identifier.toUInt64()).get(); }

    // Disambiguate ref/deref:
    void ref() const final { return IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::ref(); }
    void deref() const final { return IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::deref(); }
    ThreadSafeWeakPtrControlBlock& controlBlock() const final { return IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::controlBlock(); }
    uint32_t weakRefCount() const final { return IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::weakRefCount(); }

    // IPC::Connection::WorkQueueMessageReceiver.
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

private:
    explicit RemoteMediaResourceLoader(RemoteMediaPlayerProxy&, Ref<IPC::Connection>&&);

    void initializeConnection();

    // PlatformMediaResourceLoader
    RefPtr<WebCore::PlatformMediaResource> requestResource(WebCore::ResourceRequest&&, LoadOptions) final;
    void sendH2Ping(const URL&, CompletionHandler<void(std::expected<WTF::Seconds, WebCore::ResourceError>&&)>&&) final;
    Ref<GuaranteedSerialFunctionDispatcher> targetDispatcher() final { return defaultQueue(); }

    // Messages
    void responseReceived(RemoteMediaResourceIdentifier, const WebCore::ResourceResponse&, bool, CompletionHandler<void(WebCore::ShouldContinuePolicyCheck)>&&);
    void redirectReceived(RemoteMediaResourceIdentifier, WebCore::ResourceRequest&&, const WebCore::ResourceResponse&, CompletionHandler<void(WebCore::ResourceRequest&&)>&&);
    void dataReceived(RemoteMediaResourceIdentifier, IPC::SharedBufferReference&&, CompletionHandler<void(std::optional<WebCore::SharedMemory::Handle>&&)>&&);
    // Implemented in RemoteMediaResourceLoader.swift, on the state that m_swiftState holds. Each is safe on any thread.
    static uintptr_t createSwiftState();
    static void destroySwiftState(uintptr_t);
    void swiftAddMediaResource(uint64_t identifier, RemoteMediaResourceWeakPtr);
    RemoteMediaResourceWeakPtr swiftMediaResource(uint64_t identifier);
    void swiftRemoveMediaResource(uint64_t identifier);

    WeakPtr<RemoteMediaPlayerProxy> m_remoteMediaPlayerProxy WTF_GUARDED_BY_CAPABILITY(mainRunLoop);
    const Ref<IPC::Connection> m_connection;

    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    const uintptr_t m_swiftState;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
