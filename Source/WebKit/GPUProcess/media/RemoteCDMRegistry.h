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

#pragma once

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "RemoteCDMIdentifier.h"
#include "RemoteCDMInstanceIdentifier.h"
#include "RemoteCDMInstanceSessionIdentifier.h"
#include <WebCore/CDMPrivate.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashMap.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/UniqueRef.h>
#include <wtf/WeakPtr.h>

namespace IPC {
class Connection;
class Decoder;
class Encoder;
class MessageReceiver;
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
struct RemoteCDMConfiguration;
struct SharedPreferencesForWebProcess;

// Routes the EME factory messages of one web process's connection to the GPU process to the Swift
// RemoteCDMFactoryProxy, which owns the other receivers (each registers its own messages with the connection), and gives
// the media players the C++ CDM instances among them.
class RemoteCDMRegistry final : public RefCounted<RemoteCDMRegistry>, public CanMakeWeakPtr<RemoteCDMRegistry>, private WebCore::CDMPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMRegistry);
public:
    static Ref<RemoteCDMRegistry> create(GPUConnectionToWebProcess&);
    ~RemoteCDMRegistry();

    void clear();

    void didReceiveFactoryMessage(IPC::Connection&, IPC::Decoder&);
    void didReceiveSyncFactoryMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);

    // The C++ CDM instance of an identifier, and whether the identifier is an instance's at all: the Swift ClearKey
    // instances have no C++ instance.
    RefPtr<WebCore::CDMInstance> cdmInstance(const RemoteCDMInstanceIdentifier&) const;
    bool hasInstance(const RemoteCDMInstanceIdentifier&) const;
    bool allowsExitUnderMemoryPressure() const;

    // For the Swift receivers.
    uint64_t generateCDMIdentifier();
    uint64_t generateInstanceIdentifier();
    uint64_t generateSessionIdentifier();
    void removeInstance(uint64_t identifier);

    // Whether a C++ CDM factory supports a key system, and a C++ CDM for it, with its configuration.
    bool supportsKeySystem(const String&) const;
    RemoteCDMPrivateHandle* WTF_NULLABLE createCDM(const String& keySystem, const String& mediaKeysHashSalt, RemoteCDMConfiguration&) SWIFT_RETURNS_RETAINED;
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
    explicit RemoteCDMRegistry(GPUConnectionToWebProcess&);

    void createFactory();

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    // The Swift factory receiver, which C++ holds through the generated header. Destroyed after the routes.
    struct SwiftFactory;
    std::unique_ptr<SwiftFactory> m_swiftFactory;
    RefPtr<IPC::MessageReceiver> m_factory;
    HashMap<RemoteCDMInstanceIdentifier, Ref<WebCore::CDMInstance>> m_cdmInstances;
    HashMap<RemoteCDMInstanceIdentifier, Ref<RemoteCDMInstanceClient>> m_instanceClients;

#if !RELEASE_LOG_DISABLED
    mutable RefPtr<Logger> m_logger;
#endif
};

// A C++ CDM, which its instances and sessions also use.
class RemoteCDMPrivateHandle final : public RefCounted<RemoteCDMPrivateHandle>, public CanMakeWeakPtr<RemoteCDMPrivateHandle> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMPrivateHandle);
public:
    static Ref<RemoteCDMPrivateHandle> create(RemoteCDMRegistry&, UniqueRef<WebCore::CDMPrivate>&&);
    ~RemoteCDMPrivateHandle();

    RemoteCDMConfiguration configuration() const;
    void getSupportedConfiguration(WebCore::CDMKeySystemConfiguration&&, WebCore::CDMPrivate::LocalStorageAccess, CompletionHandler<void(std::optional<WebCore::CDMKeySystemConfiguration>)>&&);
    RefPtr<WebCore::CDMInstance> createInstance();
    void loadAndInitialize();
    void setLogIdentifier(uint64_t);
    bool supportsInitData(const String&, const WebCore::SharedBuffer&) const;
    RefPtr<WebCore::SharedBuffer> sanitizeResponse(const WebCore::SharedBuffer&) const;
    std::optional<String> sanitizeSessionId(const String&) const;

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const { return m_logger; }
    uint64_t logIdentifier() const { return m_logIdentifier; }
#else
    uint64_t logIdentifier() const { return 0; }
#endif

private:
    RemoteCDMPrivateHandle(RemoteCDMRegistry&, UniqueRef<WebCore::CDMPrivate>&&);

    WeakPtr<RemoteCDMRegistry> m_registry;
    const UniqueRef<WebCore::CDMPrivate> m_private;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
