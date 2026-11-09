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

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "GeneratedSerializers.h"
#include "RemoteCDMProxyMessages.h"
#include <WebCore/CDMInstance.h>
#if HAVE(AVCONTENTKEYSESSION)
#include <WebCore/CDMInstanceFairPlayStreamingHost.h>
#endif
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/SharedBuffer.h>

namespace WebKit {

using namespace WebCore;

SharedBuffer* makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE)
{
    return &SharedBuffer::create(bytes).leakRef();
}

CDMInstance* createRemoteCDMInstance(RemoteCDMFactoryProxy& factory, RemoteCDMPrivateHandle& cdm, uint64_t identifier, String& keySystem, uint64_t& fairPlayInstanceToken)
{
    RefPtr instance = cdm.createInstance();
    if (!instance)
        return nullptr;
    keySystem = instance->keySystem();
#if HAVE(AVCONTENTKEYSESSION)
    fairPlayInstanceToken = WebCore::fairPlayInstanceToken(*instance);
#else
    fairPlayInstanceToken = 0;
#endif
    factory.registerCxxInstance(identifier, cdm, *instance);
    return instance.leakRef();
}

void initializeRemoteCDMInstance(CDMInstance& instance, RemoteCDMConfigurationArgument& configuration, bool distinctiveIdentifiersAllowed, bool persistentStateAllowed, RemoteCDMInstanceSuccessCompletionHandler&& completionHandler)
{
    auto allowDistinctiveIdentifiers = distinctiveIdentifiersAllowed ? CDMInstance::AllowDistinctiveIdentifiers::Yes : CDMInstance::AllowDistinctiveIdentifiers::No;
    auto allowPersistentState = persistentStateAllowed ? CDMInstance::AllowPersistentState::Yes : CDMInstance::AllowPersistentState::No;
    auto value = configuration.take();
    RELEASE_ASSERT(value);
    instance.initializeWithConfiguration(WTF::move(*value), allowDistinctiveIdentifiers, allowPersistentState, WTF::move(completionHandler));
}

void setRemoteCDMInstanceStorageDirectory(CDMInstance& instance, const String& directory)
{
    instance.setStorageDirectory(directory);
}

bool remoteCDMSupportsInitData(RemoteCDMPrivateHandle& cdm, const String& initDataType, const SharedBuffer& initData)
{
    return cdm.supportsInitData(initDataType, initData);
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

void getSupportedRemoteCDMConfiguration(RemoteCDMPrivateHandle& cdm, RemoteCDMConfigurationArgument& candidateConfiguration, bool localStorageAccessAllowed, RemoteCDMSupportedConfigurationCompletionHandler&& completionHandler)
{
    auto access = localStorageAccessAllowed ? CDMPrivate::LocalStorageAccess::Allowed : CDMPrivate::LocalStorageAccess::NotAllowed;
    auto value = candidateConfiguration.take();
    RELEASE_ASSERT(value);
    cdm.getSupportedConfiguration(WTF::move(*value), access, [completionHandler = WTF::move(completionHandler)](std::optional<CDMKeySystemConfiguration> configuration) mutable {
        completionHandler(RemoteCDMEncodedConfiguration { configuration });
    });
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
