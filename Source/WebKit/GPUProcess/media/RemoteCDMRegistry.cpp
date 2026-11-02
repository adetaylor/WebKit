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

#if ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "RemoteCDMConfiguration.h"
#include "RemoteCDMFactoryProxy.h"
#include "RemoteCDMInstanceConfiguration.h"
#include "RemoteCDMInstanceProxy.h"
#include "RemoteCDMInstanceSessionProxy.h"
#include "RemoteCDMProxy.h"
#include <WebCore/CDMFactory.h>
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#include "RemoteCDMInstanceMessages.h"
#include "RemoteCDMInstanceSessionMessages.h"
#include "WebKit-Swift.h"
#endif

namespace WebKit {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMRegistry);
WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMPrivateHandle);

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

// The CDMInstanceClient of a CDM instance whose RemoteCDMInstanceProxy is in Swift.
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

// The CDMInstanceSessionClient of a CDM instance session whose RemoteCDMInstanceSessionProxy is in Swift.
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

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)

struct RemoteCDMRegistry::SwiftReceivers {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(SwiftReceivers);
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    std::unique_ptr<RemoteCDMFactoryProxy> factory;
    HashMap<RemoteCDMIdentifier, std::unique_ptr<RemoteCDMProxy>> cdms;
    HashMap<RemoteCDMInstanceIdentifier, std::unique_ptr<RemoteCDMInstanceProxy>> instances;
    HashMap<RemoteCDMInstanceIdentifier, Ref<RemoteCDMInstanceClient>> instanceClients;
    HashMap<RemoteCDMInstanceSessionIdentifier, std::unique_ptr<RemoteCDMInstanceSessionProxy>> sessions;
    HashMap<RemoteCDMInstanceSessionIdentifier, Ref<RemoteCDMInstanceSessionClient>> sessionClients;
#endif
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RemoteCDMRegistry::SwiftReceivers);

Ref<RemoteCDMRegistry> RemoteCDMRegistry::create(GPUConnectionToWebProcess& connection)
{
    Ref registry = adoptRef(*new RemoteCDMRegistry(connection));
    registry->createFactory();
    return registry;
}

RemoteCDMRegistry::RemoteCDMRegistry(GPUConnectionToWebProcess& connection)
    : m_gpuConnectionToWebProcess(connection)
    , m_swiftReceivers(makeUnique<SwiftReceivers>())
{
}

void RemoteCDMRegistry::createFactory()
{
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    m_swiftReceivers->factory = makeUniqueWithoutFastMallocCheck<RemoteCDMFactoryProxy>(RemoteCDMFactoryProxy::init(this));
    m_factory = m_swiftReceivers->factory->getMessageReceiver();
#else
    m_factory = RemoteCDMFactoryProxy::create(*this);
#endif
}

RemoteCDMRegistry::~RemoteCDMRegistry()
{
    clear();
}

void RemoteCDMRegistry::clear()
{
    m_cdms.clear();
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    m_swiftReceivers->cdms.clear();
#endif
}

void RemoteCDMRegistry::didReceiveFactoryMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    protect(m_factory)->didReceiveMessage(connection, decoder);
}

void RemoteCDMRegistry::didReceiveSyncFactoryMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder)
{
    protect(m_factory)->didReceiveSyncMessage(connection, decoder, encoder);
}

void RemoteCDMRegistry::didReceiveCDMMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (RemoteCDMIdentifier::isValidIdentifier(decoder.destinationID())) {
        if (RefPtr cdm = m_cdms.get(RemoteCDMIdentifier(decoder.destinationID())))
            cdm->didReceiveMessage(connection, decoder);
    }
}

void RemoteCDMRegistry::didReceiveSyncCDMMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder)
{
    if (RemoteCDMIdentifier::isValidIdentifier(decoder.destinationID())) {
        if (RefPtr cdm = m_cdms.get(RemoteCDMIdentifier(decoder.destinationID())))
            cdm->didReceiveSyncMessage(connection, decoder, encoder);
    }
}

void RemoteCDMRegistry::didReceiveCDMInstanceMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (RemoteCDMInstanceIdentifier::isValidIdentifier(decoder.destinationID())) {
        if (RefPtr instance = m_instances.get(RemoteCDMInstanceIdentifier(decoder.destinationID())))
            instance->didReceiveMessage(connection, decoder);
    }
}

void RemoteCDMRegistry::didReceiveSyncCDMInstanceMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder)
{
    if (RemoteCDMInstanceIdentifier::isValidIdentifier(decoder.destinationID())) {
        if (RefPtr instance = m_instances.get(RemoteCDMInstanceIdentifier(decoder.destinationID())))
            instance->didReceiveSyncMessage(connection, decoder, encoder);
    }
}

void RemoteCDMRegistry::didReceiveCDMInstanceSessionMessage(IPC::Connection& connection, IPC::Decoder& decoder)
{
    if (RemoteCDMInstanceSessionIdentifier::isValidIdentifier(decoder.destinationID())) {
        if (RefPtr session = m_sessions.get(RemoteCDMInstanceSessionIdentifier(decoder.destinationID())))
            session->didReceiveMessage(connection, decoder);
    }
}

void RemoteCDMRegistry::didReceiveSyncCDMInstanceSessionMessage(IPC::Connection& connection, IPC::Decoder& decoder, UniqueRef<IPC::Encoder>& encoder)
{
    if (RemoteCDMInstanceSessionIdentifier::isValidIdentifier(decoder.destinationID())) {
        if (RefPtr session = m_sessions.get(RemoteCDMInstanceSessionIdentifier(decoder.destinationID())))
            session->didReceiveSyncMessage(connection, decoder, encoder);
    }
}

RefPtr<CDMInstance> RemoteCDMRegistry::cdmInstance(const RemoteCDMInstanceIdentifier& identifier) const
{
    return m_cdmInstances.get(identifier);
}

bool RemoteCDMRegistry::allowsExitUnderMemoryPressure() const
{
    return m_instances.isEmpty();
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

std::optional<RemoteCDMIdentifier> RemoteCDMRegistry::createCDM(const String& keySystem, const String& mediaKeysHashSalt, RemoteCDMConfiguration& configuration)
{
    RefPtr factory = factoryForKeySystem(keySystem);
    if (!factory)
        return std::nullopt;

    auto privateCDM = factory->createCDM(keySystem, mediaKeysHashSalt, *this);
    if (!privateCDM)
        return std::nullopt;

    Ref handle = RemoteCDMPrivateHandle::create(*this, makeUniqueRefFromNonNullUniquePtr(WTF::move(privateCDM)));
    configuration = handle->configuration();
    auto identifier = RemoteCDMIdentifier::generate();
    ASSERT(!m_cdms.contains(identifier));
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    auto cdm = makeUniqueWithoutFastMallocCheck<RemoteCDMProxy>(RemoteCDMProxy::init(this, handle.ptr()));
    m_cdms.set(identifier, cdm->getMessageReceiver());
    m_swiftReceivers->cdms.set(identifier, WTF::move(cdm));
#else
    m_cdms.set(identifier, RemoteCDMProxy::create(*this, WTF::move(handle)));
#endif
    return identifier;
}

std::optional<RemoteCDMInstanceIdentifier> RemoteCDMRegistry::createInstance(RemoteCDMPrivateHandle& cdm, Ref<CDMInstance>&& instance, RemoteCDMInstanceConfiguration& configuration)
{
    configuration = { instance->keySystem() };
    auto identifier = RemoteCDMInstanceIdentifier::generate();
    ASSERT(!m_instances.contains(identifier));
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#if !RELEASE_LOG_DISABLED
    auto logIdentifier = cdm.logIdentifier();
#else
    uint64_t logIdentifier = 0;
#endif
    auto instanceProxy = makeUniqueWithoutFastMallocCheck<RemoteCDMInstanceProxy>(RemoteCDMInstanceProxy::init(this, &cdm, instance.ptr(), logIdentifier));
    m_instances.set(identifier, instanceProxy->getMessageReceiver());
    m_swiftReceivers->instances.set(identifier, WTF::move(instanceProxy));
    m_swiftReceivers->instanceClients.set(identifier, RemoteCDMInstanceClient::create(*this, cdm, instance, identifier));
#else
    Ref instanceProxy = RemoteCDMInstanceProxy::create(*this, cdm, instance.copyRef(), identifier);
    m_instances.set(identifier, Ref<IPC::MessageReceiver> { instanceProxy.get() });
#endif
    m_cdmInstances.set(identifier, WTF::move(instance));
    return identifier;
}

std::optional<RemoteCDMInstanceSessionIdentifier> RemoteCDMRegistry::createSession(RemoteCDMPrivateHandle& cdm, Ref<CDMInstanceSession>&& session)
{
    auto identifier = RemoteCDMInstanceSessionIdentifier::generate();
    ASSERT(!m_sessions.contains(identifier));
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    auto sessionProxy = makeUniqueWithoutFastMallocCheck<RemoteCDMInstanceSessionProxy>(RemoteCDMInstanceSessionProxy::init(this, &cdm, session.ptr()));
    m_sessions.set(identifier, sessionProxy->getMessageReceiver());
    m_swiftReceivers->sessions.set(identifier, WTF::move(sessionProxy));
    m_swiftReceivers->sessionClients.set(identifier, RemoteCDMInstanceSessionClient::create(*this, cdm, session, identifier));
#else
    Ref sessionProxy = RemoteCDMInstanceSessionProxy::create(*this, cdm, WTF::move(session), identifier);
    m_sessions.set(identifier, Ref<IPC::MessageReceiver> { sessionProxy.get() });
#endif
    return identifier;
}

void RemoteCDMRegistry::removeInstance(const RemoteCDMInstanceIdentifier& identifier)
{
    ASSERT(m_instances.contains(identifier));
    m_instances.remove(identifier);
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    m_swiftReceivers->instanceClients.remove(identifier);
    m_swiftReceivers->instances.remove(identifier);
#endif
    m_cdmInstances.remove(identifier);
    RefPtr connection = m_gpuConnectionToWebProcess.get();
    if (connection && allowsExitUnderMemoryPressure())
        connection->gpuProcess().tryExitIfUnusedAndUnderMemoryPressure();
}

void RemoteCDMRegistry::removeSession(const RemoteCDMInstanceSessionIdentifier& identifier)
{
    ASSERT(m_sessions.contains(identifier));
    m_sessions.remove(identifier);
#if ENABLE(GPU_PROCESS_CDM_SWIFT)
    m_swiftReceivers->sessionClients.remove(identifier);
    m_swiftReceivers->sessions.remove(identifier);
#endif
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

#endif // ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)
