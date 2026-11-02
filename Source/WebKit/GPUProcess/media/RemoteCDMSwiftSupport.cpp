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
#include "RemoteCDMSwiftSupport.h"

#if ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)

#include "RemoteCDMInstanceConfiguration.h"
#include "RemoteCDMProxyMessages.h"
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/SharedBuffer.h>

namespace WebKit {

using namespace WebCore;

uint64_t createRemoteCDMInstance(const RemoteCDMRegistryWeakReference& registryReference, RemoteCDMPrivateHandle& cdm, RemoteCDMInstanceConfiguration& configuration)
{
    RefPtr instance = cdm.createInstance();
    RefPtr registry = adoptRef(registryReference.get());
    if (!instance || !registry)
        return 0;
    auto identifier = registry->createInstance(cdm, instance.releaseNonNull(), configuration);
    return identifier ? identifier->toUInt64() : 0;
}

uint64_t createRemoteCDMInstanceSession(const RemoteCDMRegistryWeakReference& registryReference, const RemoteCDMPrivateHandleWeakReference& cdmReference, CDMInstance& instance, uint64_t logIdentifier)
{
    RefPtr session = instance.createSession();
    RefPtr cdm = adoptRef(cdmReference.get());
    RefPtr registry = adoptRef(registryReference.get());
    if (!session || !cdm || !registry)
        return 0;

#if !RELEASE_LOG_DISABLED
    session->setLogIdentifier(logIdentifier);
#else
    UNUSED_PARAM(logIdentifier);
#endif

    auto identifier = registry->createSession(*cdm, session.releaseNonNull());
    return identifier ? identifier->toUInt64() : 0;
}

void initializeRemoteCDMInstance(CDMInstance& instance, RemoteCDMKeySystemConfigurationBuilder& builder, bool distinctiveIdentifiersAllowed, bool persistentStateAllowed, RemoteCDMInstanceSuccessCompletionHandler&& completionHandler)
{
    auto allowDistinctiveIdentifiers = distinctiveIdentifiersAllowed ? CDMInstance::AllowDistinctiveIdentifiers::Yes : CDMInstance::AllowDistinctiveIdentifiers::No;
    auto allowPersistentState = persistentStateAllowed ? CDMInstance::AllowPersistentState::Yes : CDMInstance::AllowPersistentState::No;
    instance.initializeWithConfiguration(builder.take(), allowDistinctiveIdentifiers, allowPersistentState, WTF::move(completionHandler));
}

void setRemoteCDMInstanceServerCertificate(CDMInstance& instance, SharedBuffer& certificate, RemoteCDMInstanceSuccessCompletionHandler&& completionHandler)
{
    instance.setServerCertificate(certificate, WTF::move(completionHandler));
}

void setRemoteCDMInstanceStorageDirectory(CDMInstance& instance, const String& directory)
{
    instance.setStorageDirectory(directory);
}

static std::unique_ptr<IPC::Decoder> decoderForConfiguration(const std::optional<CDMKeySystemConfiguration>& configuration)
{
    IPC::Encoder encoder(Messages::RemoteCDMProxy::GetSupportedConfiguration::asyncMessageReplyName(), 0);
    encoder << configuration;
    return IPC::Decoder::create(encoder.span(), { });
}

RemoteCDMEncodedConfiguration::RemoteCDMEncodedConfiguration(const std::optional<CDMKeySystemConfiguration>& configuration)
    : m_decoder(decoderForConfiguration(configuration))
{
}

RemoteCDMEncodedConfiguration::RemoteCDMEncodedConfiguration(RemoteCDMEncodedConfiguration&&) = default;

RemoteCDMEncodedConfiguration::~RemoteCDMEncodedConfiguration() = default;

void getSupportedRemoteCDMConfiguration(RemoteCDMPrivateHandle& cdm, RemoteCDMKeySystemConfigurationBuilder& builder, bool localStorageAccessAllowed, RemoteCDMSupportedConfigurationCompletionHandler&& completionHandler)
{
    auto access = localStorageAccessAllowed ? CDMPrivate::LocalStorageAccess::Allowed : CDMPrivate::LocalStorageAccess::NotAllowed;
    cdm.getSupportedConfiguration(builder.take(), access, [completionHandler = WTF::move(completionHandler)](std::optional<CDMKeySystemConfiguration> configuration) mutable {
        completionHandler(RemoteCDMEncodedConfiguration { configuration });
    });
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(ENCRYPTED_MEDIA)
