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
#include "RemoteCDMFactoryProxy.h"

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "RemoteCDMConfiguration.h"
#include "RemoteCDMFactoryProxyMessages.h"
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

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMFactoryProxy);
WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMPrivateHandle);

// The CDMInstanceClient of a C++ CDM's instance.
class RemoteCDMInstanceClient final : public CDMInstanceClient, public RefCounted<RemoteCDMInstanceClient> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMInstanceClient);
public:
    USING_CAN_MAKE_WEAKPTR(CDMInstanceClient);

    static Ref<RemoteCDMInstanceClient> create(RemoteCDMFactoryProxy& factory, RemoteCDMPrivateHandle& cdm, CDMInstance& instance, RemoteCDMInstanceIdentifier identifier)
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
    RemoteCDMInstanceClient(RemoteCDMFactoryProxy& factory, RemoteCDMPrivateHandle& cdm, CDMInstance& instance, RemoteCDMInstanceIdentifier identifier)
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

    WeakPtr<RemoteCDMFactoryProxy> m_factory;
    WeakPtr<RemoteCDMPrivateHandle> m_cdm;
    const Ref<CDMInstance> m_instance;
    RemoteCDMInstanceIdentifier m_identifier;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
#endif
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMInstanceClient);

Ref<RemoteCDMFactoryProxy> RemoteCDMFactoryProxy::create(GPUConnectionToWebProcess& connection)
{
    Ref factory = adoptRef(*new RemoteCDMFactoryProxy(connection));
    factory->m_swiftState = factory->createSwiftState();
    return factory;
}

RemoteCDMFactoryProxy::RemoteCDMFactoryProxy(GPUConnectionToWebProcess& connection)
    : m_gpuConnectionToWebProcess(connection)
{
}

RemoteCDMFactoryProxy::~RemoteCDMFactoryProxy()
{
    destroySwiftState(m_swiftState);
}

RefPtr<CDMInstance> RemoteCDMFactoryProxy::cdmInstance(const RemoteCDMInstanceIdentifier& identifier) const
{
    return m_cdmInstances.get(identifier);
}

uint64_t RemoteCDMFactoryProxy::generateCDMIdentifier()
{
    return RemoteCDMIdentifier::generate().toUInt64();
}

uint64_t RemoteCDMFactoryProxy::generateInstanceIdentifier()
{
    return RemoteCDMInstanceIdentifier::generate().toUInt64();
}

uint64_t RemoteCDMFactoryProxy::generateSessionIdentifier()
{
    return RemoteCDMInstanceSessionIdentifier::generate().toUInt64();
}

void RemoteCDMFactoryProxy::removeInstance(uint64_t identifier)
{
    RemoteCDMInstanceIdentifier instanceIdentifier { identifier };
    m_instanceClients.remove(instanceIdentifier);
    m_cdmInstances.remove(instanceIdentifier);
    RefPtr connection = m_gpuConnectionToWebProcess.get();
    if (connection && allowsExitUnderMemoryPressure())
        connection->gpuProcess().tryExitIfUnusedAndUnderMemoryPressure();
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

bool RemoteCDMFactoryProxy::supportsKeySystem(const String& keySystem) const
{
    return factoryForKeySystem(keySystem);
}

RemoteCDMPrivateHandle* RemoteCDMFactoryProxy::createCDM(const String& keySystem, const String& mediaKeysHashSalt, RemoteCDMConfiguration& configuration)
{
    RefPtr factory = factoryForKeySystem(keySystem);
    if (!factory)
        return nullptr;

    auto privateCDM = factory->createCDM(keySystem, mediaKeysHashSalt, *this);
    if (!privateCDM)
        return nullptr;

    Ref cdm = RemoteCDMPrivateHandle::create(*this, makeUniqueRefFromNonNullUniquePtr(WTF::move(privateCDM)));
    configuration = cdm->configuration();
    return &cdm.leakRef();
}

void RemoteCDMFactoryProxy::registerCxxInstance(uint64_t identifier, RemoteCDMPrivateHandle& cdm, CDMInstance& instance)
{
    RemoteCDMInstanceIdentifier instanceIdentifier { identifier };
    m_instanceClients.set(instanceIdentifier, RemoteCDMInstanceClient::create(*this, cdm, instance, instanceIdentifier));
    m_cdmInstances.set(instanceIdentifier, instance);
}

RefPtr<GPUConnectionToWebProcess> RemoteCDMFactoryProxy::gpuConnectionToWebProcess() const
{
    return m_gpuConnectionToWebProcess.get();
}

String RemoteCDMFactoryProxy::mediaKeysStorageDirectory() const
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        return connection->mediaKeysStorageDirectory();
    return emptyString();
}

std::optional<SharedPreferencesForWebProcess> RemoteCDMFactoryProxy::sharedPreferencesForWebProcess() const
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        return connection->sharedPreferencesForWebProcess();
    return std::nullopt;
}

#if !RELEASE_LOG_DISABLED
const Logger& RemoteCDMFactoryProxy::logger() const
{
    if (!m_logger) {
        m_logger = Logger::create(this);
        RefPtr connection = m_gpuConnectionToWebProcess.get();
        m_logger->setEnabled(this, connection && connection->isAlwaysOnLoggingAllowed());
    }
    return *m_logger;
}
#endif

Ref<RemoteCDMPrivateHandle> RemoteCDMPrivateHandle::create(RemoteCDMFactoryProxy& factory, UniqueRef<CDMPrivate>&& cdm)
{
    return adoptRef(*new RemoteCDMPrivateHandle(factory, WTF::move(cdm)));
}

RemoteCDMPrivateHandle::RemoteCDMPrivateHandle(RemoteCDMFactoryProxy& factory, UniqueRef<CDMPrivate>&& cdm)
    : m_factory(factory)
    , m_private(WTF::move(cdm))
#if !RELEASE_LOG_DISABLED
    , m_logger(factory.logger())
#endif
{
}

RemoteCDMPrivateHandle::~RemoteCDMPrivateHandle() = default;

RemoteCDMConfiguration RemoteCDMPrivateHandle::configuration() const
{
    return {
        m_private->supportedInitDataTypes(),
        m_private->supportedRobustnesses(),
        m_private->supportsServerCertificates(),
        m_private->supportsSessions()
    };
}

void RemoteCDMPrivateHandle::getSupportedConfiguration(CDMKeySystemConfiguration&& configuration, CDMPrivate::LocalStorageAccess access, CompletionHandler<void(std::optional<CDMKeySystemConfiguration>)>&& callback)
{
    m_private->getSupportedConfiguration(WTF::move(configuration), access, WTF::move(callback));
}

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

bool RemoteCDMPrivateHandle::supportsInitData(const String& type, const SharedBuffer& data) const
{
    return m_private->supportsInitData(type, data);
}

RefPtr<SharedBuffer> RemoteCDMPrivateHandle::sanitizeResponse(const SharedBuffer& response) const
{
    return m_private->sanitizeResponse(response);
}

std::optional<String> RemoteCDMPrivateHandle::sanitizeSessionId(const String& sessionId) const
{
    return m_private->sanitizeSessionId(sessionId);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
