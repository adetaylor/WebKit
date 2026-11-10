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

#include "config.h"
#include "RemoteCDMPrivateFactory.h"

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteCDMIdentifier.h"
#include "RemoteCDMInstanceMessages.h"
#include "RemoteCDMInstanceSessionIdentifier.h"
#include <WebCore/CDMFactory.h>
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMPrivateFactory);
WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMPrivateHandle);

// The CDMInstanceClient of a C++ CDM's instance.
class RemoteCDMInstanceClient final : public CDMInstanceClient, public RefCounted<RemoteCDMInstanceClient> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMInstanceClient);
public:
    USING_CAN_MAKE_WEAKPTR(CDMInstanceClient);

    static Ref<RemoteCDMInstanceClient> create(RemoteCDMPrivateFactory& factory, RemoteCDMPrivateHandle& cdm, CDMInstance& instance, RemoteCDMInstanceIdentifier identifier)
    {
        return adoptRef(*new RemoteCDMInstanceClient(factory, cdm, instance, identifier));
    }

    ~RemoteCDMInstanceClient()
    {
        m_instance->clearClient();
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    RemoteCDMInstanceClient(RemoteCDMPrivateFactory& factory, RemoteCDMPrivateHandle& cdm, CDMInstance& instance, RemoteCDMInstanceIdentifier identifier)
        : m_factory(factory)
        , m_cdm(cdm)
        , m_instance(instance)
        , m_identifier(identifier)
#if !RELEASE_LOG_DISABLED
        , m_logger(cdm.logger())
        , m_logIdentifier(cdm.logIdentifier())
#endif
    {
        m_instance->setClient(*this);
    }

    void unrequestedInitializationDataReceived(const String& type, Ref<SharedBuffer>&& initData) final
    {
        if (!m_cdm)
            return;

        RefPtr factory = m_factory.get();
        if (!factory)
            return;

        RefPtr gpuConnectionToWebProcess = factory->gpuConnectionToWebProcess();
        if (!gpuConnectionToWebProcess)
            return;

        gpuConnectionToWebProcess->connection().send(Messages::RemoteCDMInstance::UnrequestedInitializationDataReceived(type, WTF::move(initData)), m_identifier);
    }

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
#endif

    WeakPtr<RemoteCDMPrivateFactory> m_factory;
    WeakPtr<RemoteCDMPrivateHandle> m_cdm;
    const Ref<CDMInstance> m_instance;
    RemoteCDMInstanceIdentifier m_identifier;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
#endif
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMInstanceClient);

Ref<RemoteCDMPrivateFactory> RemoteCDMPrivateFactory::create(GPUConnectionToWebProcess& connection)
{
    return adoptRef(*new RemoteCDMPrivateFactory(connection));
}

RemoteCDMPrivateFactory::RemoteCDMPrivateFactory(GPUConnectionToWebProcess& connection)
    : m_gpuConnectionToWebProcess(connection)
{
}

RemoteCDMPrivateFactory::~RemoteCDMPrivateFactory() = default;

RefPtr<CDMInstance> RemoteCDMPrivateFactory::cdmInstance(const RemoteCDMInstanceIdentifier& identifier) const
{
    return m_cdmInstances.get(identifier);
}

uint64_t RemoteCDMPrivateFactory::generateCDMIdentifier()
{
    return RemoteCDMIdentifier::generate().toUInt64();
}

uint64_t RemoteCDMPrivateFactory::generateInstanceIdentifier()
{
    return RemoteCDMInstanceIdentifier::generate().toUInt64();
}

uint64_t RemoteCDMPrivateFactory::generateSessionIdentifier()
{
    return RemoteCDMInstanceSessionIdentifier::generate().toUInt64();
}

void RemoteCDMPrivateFactory::removeInstance(uint64_t identifier)
{
    RemoteCDMInstanceIdentifier instanceIdentifier { identifier };
    m_instanceClients.remove(instanceIdentifier);
    m_cdmInstances.remove(instanceIdentifier);
}

static CDMFactory* factoryForKeySystem(const String& keySystem)
{
    auto& factories = CDMFactory::registeredFactories();
    auto foundIndex = factories.findIf([&](auto& factory) {
        return factory->supportsKeySystem(keySystem);
    });
    if (foundIndex == notFound)
        return nullptr;
    return factories[foundIndex].ptr();
}

RefPtr<RemoteCDMPrivateHandle> RemoteCDMPrivateFactory::createCDM(const String& keySystem, const String& mediaKeysHashSalt)
{
    RefPtr factory = factoryForKeySystem(keySystem);
    if (!factory)
        return nullptr;

    auto privateCDM = factory->createCDM(keySystem, mediaKeysHashSalt, *this);
    if (!privateCDM)
        return nullptr;

    return RemoteCDMPrivateHandle::create(*this, makeUniqueRefFromNonNullUniquePtr(WTF::move(privateCDM)));
}

void RemoteCDMPrivateFactory::registerCxxInstance(uint64_t identifier, RemoteCDMPrivateHandle& cdm, CDMInstance& instance)
{
    RemoteCDMInstanceIdentifier instanceIdentifier { identifier };
    m_instanceClients.set(instanceIdentifier, RemoteCDMInstanceClient::create(*this, cdm, instance, instanceIdentifier));
    m_cdmInstances.set(instanceIdentifier, instance);
}

RefPtr<GPUConnectionToWebProcess> RemoteCDMPrivateFactory::gpuConnectionToWebProcess() const
{
    return m_gpuConnectionToWebProcess.get();
}

#if !RELEASE_LOG_DISABLED
const Logger& RemoteCDMPrivateFactory::logger() const
{
    if (!m_logger) {
        m_logger = Logger::create(this);
        RefPtr connection = m_gpuConnectionToWebProcess.get();
        m_logger->setEnabled(this, connection && connection->isAlwaysOnLoggingAllowed());
    }
    return *m_logger;
}
#endif

Ref<RemoteCDMPrivateHandle> RemoteCDMPrivateHandle::create(RemoteCDMPrivateFactory& factory, UniqueRef<CDMPrivate>&& cdm)
{
    return adoptRef(*new RemoteCDMPrivateHandle(factory, WTF::move(cdm)));
}

RemoteCDMPrivateHandle::RemoteCDMPrivateHandle(RemoteCDMPrivateFactory& factory, UniqueRef<CDMPrivate>&& cdm)
    : m_factory(factory)
    , m_private(WTF::move(cdm))
#if !RELEASE_LOG_DISABLED
    , m_logger(factory.logger())
#endif
{
}

RemoteCDMPrivateHandle::~RemoteCDMPrivateHandle() = default;

RefPtr<CDMInstance> RemoteCDMPrivateHandle::createInstance()
{
    return m_private->createInstance();
}

void RemoteCDMPrivateHandle::loadAndInitialize()
{
    m_private->loadAndInitialize();
}

void RemoteCDMPrivateHandle::setLogIdentifier(uint64_t logIdentifier)
{
#if !RELEASE_LOG_DISABLED
    m_logIdentifier = logIdentifier;
    if (m_factory)
        m_private->setLogIdentifier(m_logIdentifier);
#else
    UNUSED_PARAM(logIdentifier);
#endif
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
