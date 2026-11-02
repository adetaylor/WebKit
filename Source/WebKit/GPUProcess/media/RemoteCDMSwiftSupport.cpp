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

#include "GeneratedSerializers.h"
#include "RemoteCDMInstanceConfiguration.h"
#include "RemoteCDMInstanceSessionProxyMessages.h"
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

RemoteCDMEncodedReply::RemoteCDMEncodedReply(IPC::Encoder& encoder)
    : m_decoder(IPC::Decoder::create(encoder.span(), encoder.releaseAttachments()))
{
}

RemoteCDMEncodedReply::RemoteCDMEncodedReply(RemoteCDMEncodedReply&&) = default;

RemoteCDMEncodedReply::~RemoteCDMEncodedReply() = default;

bool remoteCDMSupportsInitData(const RemoteCDMPrivateHandleWeakReference& cdm, const String& initDataType, const SharedBuffer& initData)
{
    return adoptRef(cdm.get())->supportsInitData(initDataType, initData);
}

SharedBuffer* sanitizeRemoteCDMResponse(const RemoteCDMPrivateHandleWeakReference& cdm, const SharedBuffer& response)
{
    return adoptRef(cdm.get())->sanitizeResponse(response).leakRef();
}

bool sanitizeRemoteCDMSessionId(const RemoteCDMPrivateHandleWeakReference& cdm, const String& sessionId, String& sanitizedSessionId)
{
    auto sanitized = adoptRef(cdm.get())->sanitizeSessionId(sessionId);
    if (!sanitized)
        return false;
    sanitizedSessionId = WTF::move(*sanitized);
    return true;
}

void setRemoteCDMInstanceSessionLogIdentifier(CDMInstanceSession& session, uint64_t logIdentifier)
{
#if !RELEASE_LOG_DISABLED
    session.setLogIdentifier(logIdentifier);
#else
    UNUSED_PARAM(session);
    UNUSED_PARAM(logIdentifier);
#endif
}

void requestRemoteCDMLicense(CDMInstanceSession& session, uint8_t type, bool keyGroupingStrategy, const String& initDataType, SharedBuffer& initData, RemoteCDMEncodedReplyCompletionHandler&& completionHandler)
{
    session.requestLicense(static_cast<CDMSessionType>(type), static_cast<CDMKeyGroupingStrategy>(keyGroupingStrategy), initDataType, initData, [completionHandler = WTF::move(completionHandler)](Ref<SharedBuffer>&& message, const String& sessionId, bool needsIndividualization, CDMInstanceSession::SuccessValue succeeded) mutable {
        IPC::Encoder encoder(Messages::RemoteCDMInstanceSessionProxy::RequestLicense::asyncMessageReplyName(), 0);
        encoder << RefPtr { WTF::move(message) } << sessionId << needsIndividualization << (succeeded == CDMInstanceSession::Succeeded);
        completionHandler(RemoteCDMEncodedReply { encoder });
    });
}

void updateRemoteCDMLicense(CDMInstanceSession& session, const String& sessionId, uint8_t type, SharedBuffer& response, RemoteCDMEncodedReplyCompletionHandler&& completionHandler)
{
    session.updateLicense(sessionId, static_cast<CDMSessionType>(type), response, [completionHandler = WTF::move(completionHandler)](bool sessionWasClosed, std::optional<CDMInstanceSession::KeyStatusVector>&& changedKeys, std::optional<double>&& changedExpiration, std::optional<CDMInstanceSession::Message>&& message, CDMInstanceSession::SuccessValue succeeded) mutable {
        IPC::Encoder encoder(Messages::RemoteCDMInstanceSessionProxy::UpdateLicense::asyncMessageReplyName(), 0);
        encoder << sessionWasClosed << changedKeys << changedExpiration << message << (succeeded == CDMInstanceSession::Succeeded);
        completionHandler(RemoteCDMEncodedReply { encoder });
    });
}

void loadRemoteCDMSession(CDMInstanceSession& session, uint8_t type, const String& sessionId, const String& origin, RemoteCDMEncodedReplyCompletionHandler&& completionHandler)
{
    session.loadSession(static_cast<CDMSessionType>(type), sessionId, origin, [completionHandler = WTF::move(completionHandler)](std::optional<CDMInstanceSession::KeyStatusVector>&& changedKeys, std::optional<double>&& changedExpiration, std::optional<CDMInstanceSession::Message>&& message, CDMInstanceSession::SuccessValue succeeded, CDMInstanceSession::SessionLoadFailure loadFailure) mutable {
        IPC::Encoder encoder(Messages::RemoteCDMInstanceSessionProxy::LoadSession::asyncMessageReplyName(), 0);
        encoder << changedKeys << changedExpiration << message << (succeeded == CDMInstanceSession::Succeeded) << loadFailure;
        completionHandler(RemoteCDMEncodedReply { encoder });
    });
}

void closeRemoteCDMSession(CDMInstanceSession& session, const String& sessionId, WTF::VoidCompletionHandler&& completionHandler)
{
    session.closeSession(sessionId, WTF::move(completionHandler));
}

void removeRemoteCDMSessionData(CDMInstanceSession& session, const String& sessionId, uint8_t type, RemoteCDMEncodedReplyCompletionHandler&& completionHandler)
{
    session.removeSessionData(sessionId, static_cast<CDMSessionType>(type), [completionHandler = WTF::move(completionHandler)](CDMInstanceSession::KeyStatusVector&& changedKeys, RefPtr<SharedBuffer>&& message, CDMInstanceSession::SuccessValue succeeded) mutable {
        IPC::Encoder encoder(Messages::RemoteCDMInstanceSessionProxy::RemoveSessionData::asyncMessageReplyName(), 0);
        encoder << changedKeys << message << (succeeded == CDMInstanceSession::Succeeded);
        completionHandler(RemoteCDMEncodedReply { encoder });
    });
}

void storeRemoteCDMRecordOfKeyUsage(CDMInstanceSession& session, const String& sessionId)
{
    session.storeRecordOfKeyUsage(sessionId);
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
