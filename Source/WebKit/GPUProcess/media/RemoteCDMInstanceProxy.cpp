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
#include "RemoteCDMInstanceProxy.h"

#if ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA) && !ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteCDMInstanceMessages.h"
#include "RemoteCDMRegistry.h"
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>

namespace WebKit {

using namespace WebCore;

Ref<RemoteCDMInstanceProxy> RemoteCDMInstanceProxy::create(RemoteCDMRegistry& registry, RemoteCDMPrivateHandle& cdm, Ref<CDMInstance>&& priv, RemoteCDMInstanceIdentifier identifier)
{
    return adoptRef(*new RemoteCDMInstanceProxy(registry, cdm, WTF::move(priv), identifier));
}

RemoteCDMInstanceProxy::RemoteCDMInstanceProxy(RemoteCDMRegistry& registry, RemoteCDMPrivateHandle& cdm, Ref<CDMInstance>&& priv, RemoteCDMInstanceIdentifier identifier)
    : m_registry(registry)
    , m_cdm(cdm)
    , m_instance(WTF::move(priv))
    , m_identifier(identifier)
#if !RELEASE_LOG_DISABLED
    , m_logger(cdm.logger())
    , m_logIdentifier(cdm.logIdentifier())
#endif
{
    m_instance->setClient(*this);
}

RemoteCDMInstanceProxy::~RemoteCDMInstanceProxy()
{
    m_instance->clearClient();
}

void RemoteCDMInstanceProxy::unrequestedInitializationDataReceived(const String& type, Ref<SharedBuffer>&& initData)
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

void RemoteCDMInstanceProxy::initializeWithConfiguration(const WebCore::CDMKeySystemConfiguration& configuration, AllowDistinctiveIdentifiers allowDistinctiveIdentifiers, AllowPersistentState allowPersistentState, CompletionHandler<void(SuccessValue)>&& completion)
{
    m_instance->initializeWithConfiguration(configuration, allowDistinctiveIdentifiers, allowPersistentState, WTF::move(completion));
}

void RemoteCDMInstanceProxy::setServerCertificate(Ref<SharedBuffer>&& certificate, CompletionHandler<void(SuccessValue)>&& completion)
{
    m_instance->setServerCertificate(WTF::move(certificate), WTF::move(completion));
}

void RemoteCDMInstanceProxy::setStorageDirectory(const String& directory)
{
    if (!m_cdm)
        return;

    RefPtr registry = m_registry;
    if (!registry)
        return;

    auto mediaKeysStorageDirectory = registry->mediaKeysStorageDirectory();
    if (mediaKeysStorageDirectory.isEmpty())
        return;

    if (directory.startsWith(mediaKeysStorageDirectory))
        m_instance->setStorageDirectory(directory);
}

void RemoteCDMInstanceProxy::createSession(uint64_t, CompletionHandler<void(std::optional<RemoteCDMInstanceSessionIdentifier>)>&& completion)
{
    RefPtr privSession = m_instance->createSession();
    RefPtr cdm = m_cdm;
    RefPtr registry = m_registry;
    if (!privSession || !cdm || !registry) {
        completion(std::nullopt);
        return;
    }

#if !RELEASE_LOG_DISABLED
    privSession->setLogIdentifier(m_logIdentifier);
#endif

    completion(registry->createSession(*cdm, privSession.releaseNonNull()));
}

std::optional<SharedPreferencesForWebProcess> RemoteCDMInstanceProxy::sharedPreferencesForWebProcess() const
{
    if (!m_cdm)
        return std::nullopt;

    if (RefPtr registry = m_registry)
        return registry->sharedPreferencesForWebProcess();
    return std::nullopt;
}

}

#endif
