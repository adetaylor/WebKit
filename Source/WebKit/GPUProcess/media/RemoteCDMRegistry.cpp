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
#include "RemoteCDMRegistry.h"

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "RemoteCDMConfiguration.h"
#include "RemoteCDMFactoryProxyMessages.h"
#include "RemoteCDMInstanceMessages.h"
#include "RemoteCDMInstanceSessionMessages.h"
#include "WebKit-Swift.h"
#include <WebCore/CDMFactory.h>
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMRegistry);
WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMPrivateHandle);

// The CDMInstanceClient of a C++ CDM's instance.
class RemoteCDMInstanceClient final : public CDMInstanceClient, public RefCounted<RemoteCDMInstanceClient> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMInstanceClient);
public:
    USING_CAN_MAKE_WEAKPTR(CDMInstanceClient);

    static Ref<RemoteCDMInstanceClient> create(RemoteCDMRegistry& registry, RemoteCDMPrivateHandle& cdm, CDMInstance& instance, RemoteCDMInstanceIdentifier identifier)
    {
        return adoptRef(*new RemoteCDMInstanceClient(registry, cdm, instance, identifier));
    }

    ~RemoteCDMInstanceClient()
    {
        m_instance->clearClient();
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    RemoteCDMInstanceClient(RemoteCDMRegistry& registry, RemoteCDMPrivateHandle& cdm, CDMInstance& instance, RemoteCDMInstanceIdentifier identifier)
        : m_registry(registry)
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

        RefPtr registry = m_registry;
        if (!registry)
            return;

        RefPtr gpuConnectionToWebProcess = registry->gpuConnectionToWebProcess();
        if (!gpuConnectionToWebProcess)
            return;

        gpuConnectionToWebProcess->connection().send(Messages::RemoteCDMInstance::UnrequestedInitializationDataReceived(type, WTF::move(initData)), m_identifier);
    }

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
#endif

    WeakPtr<RemoteCDMRegistry> m_registry;
    WeakPtr<RemoteCDMPrivateHandle> m_cdm;
    const Ref<CDMInstance> m_instance;
    RemoteCDMInstanceIdentifier m_identifier;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
#endif
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMInstanceClient);

// The CDMInstanceSessionClient of a C++ CDM's session.
class RemoteCDMInstanceSessionClient final : public CDMInstanceSessionClient, public RefCounted<RemoteCDMInstanceSessionClient> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMInstanceSessionClient);
public:
    static Ref<RemoteCDMInstanceSessionClient> create(RemoteCDMRegistry& registry, RemoteCDMPrivateHandle& cdm, CDMInstanceSession& session, RemoteCDMInstanceSessionIdentifier identifier)
    {
        Ref client = adoptRef(*new RemoteCDMInstanceSessionClient(registry, cdm, identifier));
        session.setClient(WeakPtr<CDMInstanceSessionClient> { client.get() });
        return client;
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    RemoteCDMInstanceSessionClient(RemoteCDMRegistry& registry, RemoteCDMPrivateHandle& cdm, RemoteCDMInstanceSessionIdentifier identifier)
        : m_registry(registry)
        , m_cdm(cdm)
        , m_identifier(identifier)
    {
    }

    template<typename Message> void send(Message&& message)
    {
        if (!m_cdm)
            return;

        RefPtr registry = m_registry;
        if (!registry)
            return;

        RefPtr gpuConnectionToWebProcess = registry->gpuConnectionToWebProcess();
        if (!gpuConnectionToWebProcess)
            return;

        gpuConnectionToWebProcess->connection().send(std::forward<Message>(message), m_identifier);
    }

    void updateKeyStatuses(KeyStatusVector&& keyStatuses) final
    {
        send(Messages::RemoteCDMInstanceSession::UpdateKeyStatuses(WTF::move(keyStatuses)));
    }

    void sendMessage(CDMMessageType type, Ref<SharedBuffer>&& message) final
    {
        send(Messages::RemoteCDMInstanceSession::SendMessage(type, WTF::move(message)));
    }

    void sessionIdChanged(const String& sessionId) final
    {
        send(Messages::RemoteCDMInstanceSession::SessionIdChanged(sessionId));
    }

    PlatformDisplayID displayID() final { return m_displayID; }

    WeakPtr<RemoteCDMRegistry> m_registry;
    WeakPtr<RemoteCDMPrivateHandle> m_cdm;
    RemoteCDMInstanceSessionIdentifier m_identifier;
    PlatformDisplayID m_displayID { 0 };
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMInstanceSessionClient);

struct RemoteCDMRegistry::SwiftFactory {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(SwiftFactory);
    explicit SwiftFactory(RemoteCDMRegistry& registry)
        : factory(RemoteCDMFactoryProxy::init(&registry))
    {
    }

    RemoteCDMFactoryProxy factory;
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RemoteCDMRegistry::SwiftFactory);

Ref<RemoteCDMRegistry> RemoteCDMRegistry::create(GPUConnectionToWebProcess& connection)
{
    Ref registry = adoptRef(*new RemoteCDMRegistry(connection));
    registry->createFactory();
    return registry;
}

RemoteCDMRegistry::RemoteCDMRegistry(GPUConnectionToWebProcess& connection)
    : m_gpuConnectionToWebProcess(connection)
{
}

void RemoteCDMRegistry::createFactory()
{
    m_swiftFactory = makeUnique<SwiftFactory>(*this);
    m_factory = m_swiftFactory->factory.getMessageReceiver();
}

RemoteCDMRegistry::~RemoteCDMRegistry()
{
    clear();
}

void RemoteCDMRegistry::clear()
{
    if (m_swiftFactory)
        m_swiftFactory->factory.removeCDMsAndRegistrations();
}

void RemoteCDMRegistry::didReceiveFactoryMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    protect(m_factory)->didReceiveMessage(connection, decoder);
}

void RemoteCDMRegistry::didReceiveSyncFactoryMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder)
{
    protect(m_factory)->didReceiveSyncMessage(connection, decoder, encoder);
}

RefPtr<CDMInstance> RemoteCDMRegistry::cdmInstance(const RemoteCDMInstanceIdentifier& identifier) const
{
    return m_cdmInstances.get(identifier);
}

bool RemoteCDMRegistry::hasInstance(const RemoteCDMInstanceIdentifier& identifier) const
{
    return m_swiftFactory && m_swiftFactory->factory.hasInstance(identifier.toUInt64());
}

bool RemoteCDMRegistry::allowsExitUnderMemoryPressure() const
{
    return !m_swiftFactory || m_swiftFactory->factory.allowsExitUnderMemoryPressure();
}

uint64_t RemoteCDMRegistry::generateCDMIdentifier()
{
    return RemoteCDMIdentifier::generate().toUInt64();
}

uint64_t RemoteCDMRegistry::generateInstanceIdentifier()
{
    return RemoteCDMInstanceIdentifier::generate().toUInt64();
}

uint64_t RemoteCDMRegistry::generateSessionIdentifier()
{
    return RemoteCDMInstanceSessionIdentifier::generate().toUInt64();
}

void RemoteCDMRegistry::removeInstance(uint64_t identifier)
{
    RemoteCDMInstanceIdentifier instanceIdentifier { identifier };
    m_instanceClients.remove(instanceIdentifier);
    m_cdmInstances.remove(instanceIdentifier);
    RefPtr connection = m_gpuConnectionToWebProcess.get();
    if (connection && allowsExitUnderMemoryPressure())
        connection->gpuProcess().tryExitIfUnusedAndUnderMemoryPressure();
}

void RemoteCDMRegistry::removeSession(uint64_t identifier)
{
    m_sessionClients.remove(RemoteCDMInstanceSessionIdentifier { identifier });
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

bool RemoteCDMRegistry::supportsKeySystem(const String& keySystem) const
{
    return factoryForKeySystem(keySystem);
}

RemoteCDMPrivateHandle* RemoteCDMRegistry::createCDM(const String& keySystem, const String& mediaKeysHashSalt, RemoteCDMConfiguration& configuration)
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

void RemoteCDMRegistry::registerCxxInstance(uint64_t identifier, RemoteCDMPrivateHandle& cdm, CDMInstance& instance)
{
    RemoteCDMInstanceIdentifier instanceIdentifier { identifier };
    m_instanceClients.set(instanceIdentifier, RemoteCDMInstanceClient::create(*this, cdm, instance, instanceIdentifier));
    m_cdmInstances.set(instanceIdentifier, instance);
}

void RemoteCDMRegistry::registerCxxSession(uint64_t identifier, RemoteCDMPrivateHandle& cdm, CDMInstanceSession& session)
{
    RemoteCDMInstanceSessionIdentifier sessionIdentifier { identifier };
    m_sessionClients.set(sessionIdentifier, RemoteCDMInstanceSessionClient::create(*this, cdm, session, sessionIdentifier));
}

RefPtr<GPUConnectionToWebProcess> RemoteCDMRegistry::gpuConnectionToWebProcess() const
{
    return m_gpuConnectionToWebProcess.get();
}

String RemoteCDMRegistry::mediaKeysStorageDirectory() const
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        return connection->mediaKeysStorageDirectory();
    return emptyString();
}

std::optional<SharedPreferencesForWebProcess> RemoteCDMRegistry::sharedPreferencesForWebProcess() const
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        return connection->sharedPreferencesForWebProcess();
    return std::nullopt;
}

#if !RELEASE_LOG_DISABLED
const Logger& RemoteCDMRegistry::logger() const
{
    if (!m_logger) {
        m_logger = Logger::create(this);
        RefPtr connection = m_gpuConnectionToWebProcess.get();
        m_logger->setEnabled(this, connection && connection->isAlwaysOnLoggingAllowed());
    }
    return *m_logger;
}
#endif

Ref<RemoteCDMPrivateHandle> RemoteCDMPrivateHandle::create(RemoteCDMRegistry& registry, UniqueRef<CDMPrivate>&& cdm)
{
    return adoptRef(*new RemoteCDMPrivateHandle(registry, WTF::move(cdm)));
}

RemoteCDMPrivateHandle::RemoteCDMPrivateHandle(RemoteCDMRegistry& registry, UniqueRef<CDMPrivate>&& cdm)
    : m_registry(registry)
    , m_private(WTF::move(cdm))
#if !RELEASE_LOG_DISABLED
    , m_logger(registry.logger())
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
    if (m_registry)
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
