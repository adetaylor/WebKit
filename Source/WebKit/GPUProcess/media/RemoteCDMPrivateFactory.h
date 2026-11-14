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

#include "RemoteCDMInstanceIdentifier.h"
#include <WebCore/CDMPrivate.h>
#include <wtf/HashMap.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/UniqueRef.h>
#include <wtf/WeakPtr.h>

namespace WebCore {
class CDMInstance;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteCDMInstanceClient;
class RemoteCDMPrivateHandle;

// The C++ CDMs of one web process's connection to the GPU process, and their instances, which the media players use. The
// Swift receiver of the EME factory messages (RemoteCDMFactoryProxy.swift), which the connection's Swift state owns, makes
// them through the connection.
class RemoteCDMPrivateFactory final : public RefCounted<RemoteCDMPrivateFactory>, public CanMakeWeakPtr<RemoteCDMPrivateFactory>, private WebCore::CDMPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMPrivateFactory);
public:
    static Ref<RemoteCDMPrivateFactory> create(GPUConnectionToWebProcess&);
    ~RemoteCDMPrivateFactory();

    RefPtr<WebCore::CDMInstance> cdmInstance(const RemoteCDMInstanceIdentifier&) const;

    // For the Swift receivers.
    static uint64_t generateCDMIdentifier();
    static uint64_t generateInstanceIdentifier();
    static uint64_t generateSessionIdentifier();

    // A C++ CDM for a key system, for the configuration algorithm and the instances that the players use.
    RefPtr<RemoteCDMPrivateHandle> createCDM(const String& keySystem, const String& mediaKeysHashSalt);
    // A C++ CDM's instance and session (RemoteCDMSwiftSupport.h): the players can find the instance, and both send their
    // notifications.
    void registerCxxInstance(uint64_t identifier, RemoteCDMPrivateHandle&, WebCore::CDMInstance&);
    void removeInstance(uint64_t identifier);

    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() const;

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final;
#endif

private:
    explicit RemoteCDMPrivateFactory(GPUConnectionToWebProcess&);

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
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
    static Ref<RemoteCDMPrivateHandle> create(RemoteCDMPrivateFactory&, UniqueRef<WebCore::CDMPrivate>&&);
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
    RemoteCDMPrivateHandle(RemoteCDMPrivateFactory&, UniqueRef<WebCore::CDMPrivate>&&);

    WeakPtr<RemoteCDMPrivateFactory> m_factory;
    const UniqueRef<WebCore::CDMPrivate> m_private;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
