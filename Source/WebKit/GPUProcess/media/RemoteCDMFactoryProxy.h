/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "MessageReceiver.h"
#include "RemoteCDMInstanceIdentifier.h"
#include <WebCore/CDMPrivate.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashMap.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/UniqueRef.h>
#include <wtf/WeakPtr.h>

namespace IPC {
class Connection;
class Decoder;
class Encoder;
enum class ReceiverName : uint8_t;
}

namespace WebCore {
class CDMInstance;
class SharedBuffer;
struct CDMKeySystemConfiguration;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteCDMInstanceClient;
class RemoteCDMPrivateHandle;
struct SharedPreferencesForWebProcess;

// Receives the EME factory messages of one web process's connection to the GPU process, and gives the media players the
// C++ CDM instances. Its Swift state (RemoteCDMFactoryProxy.swift), which m_swiftState holds, handles the messages and
// owns the other receivers, each of which registers its own messages with the connection.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteCDMFactoryProxy.swift") RemoteCDMFactoryProxy final : public RefCounted<RemoteCDMFactoryProxy>, public IPC::MessageReceiver, private WebCore::CDMPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMFactoryProxy);
public:
    static Ref<RemoteCDMFactoryProxy> create(GPUConnectionToWebProcess&);
    ~RemoteCDMFactoryProxy();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    void didReceiveMessageFromWebProcess(IPC::Connection& connection, IPC::Decoder& decoder) { didReceiveMessage(connection, decoder); }
    void didReceiveSyncMessageFromWebProcess(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder) { didReceiveSyncMessage(connection, decoder, encoder); }

    // Implemented in Swift. clear() is for when the web process's connection closes: the CDMs no longer reach the factory,
    // and no receiver's messages are routed. The Swift state and the factory keep each other alive until then.
    void clear();
    bool allowsExitUnderMemoryPressure() const;
    // Whether the identifier is an instance's at all: the Swift ClearKey instances have no C++ instance.
    bool hasInstance(uint64_t identifier) const;

    RefPtr<WebCore::CDMInstance> cdmInstance(const RemoteCDMInstanceIdentifier&) const;

    // For the Swift receivers.
    static uint64_t generateCDMIdentifier();
    static uint64_t generateInstanceIdentifier();
    static uint64_t generateSessionIdentifier();
    void removeInstance(uint64_t identifier);
    // For IPC::registerSwiftReceiver(): routes the web process's messages to identifier to receiver until
    // removeSwiftReceiver(). False if the web process's connection has gone.
    bool addSwiftReceiver(IPC::ReceiverName, uint64_t identifier, IPC::MessageReceiver&);
    void removeSwiftReceiver(IPC::ReceiverName, uint64_t identifier);

    // A C++ CDM for a key system, for the configuration algorithm and the instances that the players use.
    RemoteCDMPrivateHandle* WTF_NULLABLE createCDM(const String& keySystem, const String& mediaKeysHashSalt) SWIFT_RETURNS_RETAINED;
    // A C++ CDM's instance and session (RemoteCDMSwiftSupport.h): the players can find the instance, and both send their
    // notifications.
    void registerCxxInstance(uint64_t identifier, RemoteCDMPrivateHandle&, WebCore::CDMInstance&);

    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() const;
    String mediaKeysStorageDirectory() const;
    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final;
#endif

private:
    explicit RemoteCDMFactoryProxy(GPUConnectionToWebProcess&);

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&) final;

    // Implemented in Swift.
    uintptr_t createSwiftState();
    static void destroySwiftState(uintptr_t);

    // m_swiftState, for Swift, which can only read it.
    uintptr_t swiftState() const { return m_swiftState; }

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    HashMap<RemoteCDMInstanceIdentifier, Ref<WebCore::CDMInstance>> m_cdmInstances;
    HashMap<RemoteCDMInstanceIdentifier, Ref<RemoteCDMInstanceClient>> m_instanceClients;

#if !RELEASE_LOG_DISABLED
    mutable RefPtr<Logger> m_logger;
#endif
    // A retained reference to the Swift state, as an address, from create() to the destructor.
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A C++ CDM, which its instances and sessions also use.
class RemoteCDMPrivateHandle final : public RefCounted<RemoteCDMPrivateHandle>, public CanMakeWeakPtr<RemoteCDMPrivateHandle> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMPrivateHandle);
public:
    static Ref<RemoteCDMPrivateHandle> create(RemoteCDMFactoryProxy&, UniqueRef<WebCore::CDMPrivate>&&);
    ~RemoteCDMPrivateHandle();

    RefPtr<WebCore::CDMInstance> createInstance();
    void loadAndInitialize();
    void setLogIdentifier(uint64_t);

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const { return m_logger; }
    uint64_t logIdentifier() const { return m_logIdentifier; }
#else
    uint64_t logIdentifier() const { return 0; }
#endif

private:
    RemoteCDMPrivateHandle(RemoteCDMFactoryProxy&, UniqueRef<WebCore::CDMPrivate>&&);

    WeakPtr<RemoteCDMFactoryProxy> m_factory;
    const UniqueRef<WebCore::CDMPrivate> m_private;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
