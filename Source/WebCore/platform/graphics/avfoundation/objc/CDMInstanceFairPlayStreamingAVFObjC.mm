/*
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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

#import "config.h"
#import "CDMInstanceFairPlayStreamingAVFObjC.h"

#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)

#import "CDMFairPlayStreaming.h"
#import "CDMInstanceFairPlayStreamingHost.h"
#import "CDMKeyGroupingStrategy.h"
#import "CDMKeySystemConfiguration.h"
#import "CDMLogging.h"
#import "Logging.h"
#import "MediaParsersCxxBridging.h"
#import "MediaSampleAVFObjC.h"
#import "SharedBuffer.h"
#import "WebCore-Swift.h"
#import <AVFoundation/AVContentKeySession.h>
#import <wtf/LoggerHelper.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/CString.h>

#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

namespace WebCore {

#if !RELEASE_LOG_DISABLED
NODELETE static WTFLogChannel& logChannel() { return LogEME; }
#endif

struct CDMInstanceFairPlayStreamingAVFObjC::SwiftInstance {
    typedef CDMInstanceFairPlayStreamingAVFObjC::SwiftInstance CDMInstanceFairPlayStreamingAVFObjCSwiftInstance;
    WTF_MAKE_TZONE_ALLOCATED_INLINE(CDMInstanceFairPlayStreamingAVFObjCSwiftInstance);
public:
    FairPlayInstanceBridge bridge;
};

struct CDMInstanceSessionFairPlayStreamingAVFObjC::SwiftSession {
    typedef CDMInstanceSessionFairPlayStreamingAVFObjC::SwiftSession CDMInstanceSessionFairPlayStreamingAVFObjCSwiftSession;
    WTF_MAKE_TZONE_ALLOCATED_INLINE(CDMInstanceSessionFairPlayStreamingAVFObjCSwiftSession);
public:
    FairPlaySessionBridge bridge;
};

#if !RELEASE_LOG_DISABLED
static void log(const Logger& logger, ASCIILiteral className, uint64_t logIdentifier, FairPlayLogLevel level, std::span<const uint8_t> method, std::span<const uint8_t> message)
{
    CString methodName { byteCast<char>(method) };
    Logger::LogSiteIdentifier identifier { className, methodName.data(), logIdentifier };
    auto text = String::fromUTF8(message);
    switch (level) {
    case FairPlayLogLevel::Always:
        logger.logAlways(LogEME, identifier, text);
        return;
    case FairPlayLogLevel::Error:
        logger.error(LogEME, identifier, text);
        return;
    case FairPlayLogLevel::Info:
        logger.info(LogEME, identifier, text);
        return;
    }
}
#endif

static CDMInstanceSession::KeyStatusVector keyStatuses(std::span<const uint8_t> keyIDs, std::span<const uint32_t> keyIDSizes, std::span<const uint8_t> statuses)
{
    CDMInstanceSession::KeyStatusVector result;
    result.reserveInitialCapacity(std::min(keyIDSizes.size(), statuses.size()));
    for (size_t index = 0; index < keyIDSizes.size() && index < statuses.size(); ++index) {
        auto size = std::min<size_t>(keyIDSizes[index], keyIDs.size());
        result.append({ SharedBuffer::create(keyIDs.first(size)), static_cast<CDMKeyStatus>(statuses[index]) });
        keyIDs = keyIDs.subspan(size);
    }
    return result;
}

static CDMInstanceSession::KeyStatusVector releasedKeyStatuses(uint32_t count)
{
    CDMInstanceSession::KeyStatusVector result;
    result.reserveInitialCapacity(count);
    for (uint32_t index = 0; index < count; ++index) {
        // FIXME(rdar://problem/35934922): use key values stored in expired session report once available
        result.append({ SharedBuffer::create(), CDMKeyStatus::Released });
    }
    return result;
}

// Key IDs back to back, with their sizes, for the Swift instance.
struct FlattenedKeyIDs {
    explicit FlattenedKeyIDs(const CDMKeyIDs& keyIDs)
    {
        for (auto& keyID : keyIDs) {
            auto keyIDBytes = keyID->span();
            bytes.append(keyIDBytes);
            sizes.append(static_cast<uint32_t>(keyIDBytes.size()));
        }
    }

    MediaParserBytes view() const LIFETIME_BOUND { return { bytes.span() }; }
    FairPlayKeyIDSizes sizesView() const LIFETIME_BOUND { return { sizes.span() }; }

    Vector<uint8_t, 32> bytes;
    Vector<uint32_t, 2> sizes;
};

Ref<FairPlayInstanceHost> FairPlayInstanceHost::create(CDMInstanceFairPlayStreamingAVFObjC& instance)
{
    return adoptRef(*new FairPlayInstanceHost(instance));
}

FairPlayInstanceHost::FairPlayInstanceHost(CDMInstanceFairPlayStreamingAVFObjC& instance)
    : m_instance(instance)
{
}

FairPlayInstanceHost::~FairPlayInstanceHost() = default;

void FairPlayInstanceHost::unrequestedInitializationDataReceived(WTF::SpanUInt8 initDataType NOESCAPE, WTF::SpanUInt8 initData NOESCAPE) const
{
    RefPtr instance = m_instance.get();
    if (!instance)
        return;
    if (RefPtr client = instance->m_client.get())
        client->unrequestedInitializationDataReceived(String::fromUTF8(initDataType), SharedBuffer::create(initData));
}

void FairPlayInstanceHost::keyStatusesChanged() const
{
    RefPtr instance = m_instance.get();
    if (!instance)
        return;
    instance->m_keyStatusChangedObservers.forEach([] (auto& observer) {
        observer();
    });
}

void FairPlayInstanceHost::log(FairPlayLogLevel level, WTF::SpanUInt8 method NOESCAPE, WTF::SpanUInt8 message NOESCAPE) const
{
#if !RELEASE_LOG_DISABLED
    if (RefPtr instance = m_instance.get())
        WebCore::log(instance->logger(), instance->logClassName(), instance->logIdentifier(), level, method, message);
#else
    UNUSED_PARAM(level);
    UNUSED_PARAM(method);
    UNUSED_PARAM(message);
#endif
}

Ref<FairPlaySessionHost> FairPlaySessionHost::create(CDMInstanceSessionFairPlayStreamingAVFObjC& session)
{
    return adoptRef(*new FairPlaySessionHost(session));
}

FairPlaySessionHost::FairPlaySessionHost(CDMInstanceSessionFairPlayStreamingAVFObjC& session)
    : m_session(session)
{
}

FairPlaySessionHost::~FairPlaySessionHost() = default;

bool FairPlaySessionHost::hasClient() const
{
    RefPtr session = m_session.get();
    return session && session->m_client;
}

void FairPlaySessionHost::sendMessage(CDMMessageType type, WTF::SpanUInt8 message NOESCAPE) const
{
    RefPtr session = m_session.get();
    if (!session)
        return;
    if (RefPtr client = session->m_client.get())
        client->sendMessage(type, SharedBuffer::create(message));
}

void FairPlaySessionHost::sessionIdChanged(WTF::SpanUInt8 sessionId NOESCAPE) const
{
    RefPtr session = m_session.get();
    if (!session)
        return;
    if (RefPtr client = session->m_client.get())
        client->sessionIdChanged(sessionId.empty() ? emptyString() : String::fromUTF8(sessionId));
}

void FairPlaySessionHost::updateKeyStatuses(WTF::SpanUInt8 keyIDs NOESCAPE, FairPlayUInt32Span keyIDSizes NOESCAPE, WTF::SpanUInt8 statuses NOESCAPE) const
{
    RefPtr session = m_session.get();
    if (!session)
        return;
    if (RefPtr client = session->m_client.get())
        client->updateKeyStatuses(WebCore::keyStatuses(keyIDs, keyIDSizes, statuses));
}

void FairPlaySessionHost::log(FairPlayLogLevel level, WTF::SpanUInt8 method NOESCAPE, WTF::SpanUInt8 message NOESCAPE) const
{
#if !RELEASE_LOG_DISABLED
    if (RefPtr session = m_session.get())
        WebCore::log(session->logger(), session->logClassName(), session->logIdentifier(), level, method, message);
#else
    UNUSED_PARAM(level);
    UNUSED_PARAM(method);
    UNUSED_PARAM(message);
#endif
}

Ref<FairPlayLicenseCompletion> FairPlayLicenseCompletion::create(CDMInstanceSession::LicenseCallback&& callback)
{
    return adoptRef(*new FairPlayLicenseCompletion(WTF::move(callback)));
}

FairPlayLicenseCompletion::FairPlayLicenseCompletion(CDMInstanceSession::LicenseCallback&& callback)
    : m_callback(WTF::move(callback))
{
}

FairPlayLicenseCompletion::~FairPlayLicenseCompletion() = default;

void FairPlayLicenseCompletion::complete(WTF::SpanUInt8 message NOESCAPE, bool hasSessionId, WTF::SpanUInt8 sessionId NOESCAPE, bool succeeded)
{
    if (!m_callback)
        return;
    String sessionIdString;
    if (hasSessionId)
        sessionIdString = sessionId.empty() ? emptyString() : String::fromUTF8(sessionId);
    m_callback(SharedBuffer::create(message), sessionIdString, false, succeeded ? CDMInstanceSession::Succeeded : CDMInstanceSession::Failed);
}

Ref<FairPlayLicenseUpdateCompletion> FairPlayLicenseUpdateCompletion::create(CDMInstanceSession::LicenseUpdateCallback&& callback)
{
    return adoptRef(*new FairPlayLicenseUpdateCompletion(WTF::move(callback)));
}

FairPlayLicenseUpdateCompletion::FairPlayLicenseUpdateCompletion(CDMInstanceSession::LicenseUpdateCallback&& callback)
    : m_callback(WTF::move(callback))
{
}

FairPlayLicenseUpdateCompletion::~FairPlayLicenseUpdateCompletion() = default;

void FairPlayLicenseUpdateCompletion::fail(bool sessionWasClosed)
{
    if (m_callback)
        m_callback(sessionWasClosed, std::nullopt, std::nullopt, std::nullopt, CDMInstanceSession::Failed);
}

void FairPlayLicenseUpdateCompletion::succeed()
{
    if (m_callback)
        m_callback(false, std::nullopt, std::nullopt, std::nullopt, CDMInstanceSession::Succeeded);
}

void FairPlayLicenseUpdateCompletion::succeedWithKeyStatuses(WTF::SpanUInt8 keyIDs NOESCAPE, FairPlayUInt32Span keyIDSizes NOESCAPE, WTF::SpanUInt8 statuses NOESCAPE)
{
    if (m_callback)
        m_callback(false, keyStatuses(keyIDs, keyIDSizes, statuses), std::nullopt, std::nullopt, CDMInstanceSession::Succeeded);
}

void FairPlayLicenseUpdateCompletion::succeedWithMessage(CDMMessageType type, WTF::SpanUInt8 message NOESCAPE)
{
    if (m_callback)
        m_callback(false, std::nullopt, std::nullopt, CDMInstanceSession::Message(type, SharedBuffer::create(message)), CDMInstanceSession::Succeeded);
}

NSException *makeFairPlayStreamingContentKeyRequestData(AVContentKeyRequest *request, NSData *appIdentifier, NSData *contentIdentifier, NSDictionary *options, void (^completionHandler)(NSData *, NSError *))
{
    @try {
        [request makeStreamingContentKeyRequestDataForApp:appIdentifier contentIdentifier:contentIdentifier options:options completionHandler:completionHandler];
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

Ref<CDMInstanceFairPlayStreamingAVFObjC> CDMInstanceFairPlayStreamingAVFObjC::create(const CDMPrivateFairPlayStreaming& cdmPrivate)
{
    return adoptRef(*new CDMInstanceFairPlayStreamingAVFObjC(cdmPrivate));
}

CDMInstanceFairPlayStreamingAVFObjC::CDMInstanceFairPlayStreamingAVFObjC(const CDMPrivateFairPlayStreaming& cdmPrivate)
#if !RELEASE_LOG_DISABLED
    : m_logger { cdmPrivate.logger() }
    , m_swift { makeUnique<SwiftInstance>(FairPlayInstanceBridge::init(FairPlayInstanceHost::create(*this).ptr(), mediaParserText(cdmPrivate.mediaKeysHashSalt()))) }
#else
    : m_swift { makeUnique<SwiftInstance>(FairPlayInstanceBridge::init(FairPlayInstanceHost::create(*this).ptr(), mediaParserText(cdmPrivate.mediaKeysHashSalt()))) }
#endif
{
}

CDMInstanceFairPlayStreamingAVFObjC::~CDMInstanceFairPlayStreamingAVFObjC() = default;

void CDMInstanceFairPlayStreamingAVFObjC::initializeWithConfiguration(const CDMKeySystemConfiguration& configuration, AllowDistinctiveIdentifiers, AllowPersistentState persistentState, SuccessCallback&& callback)
{
    bool sessionTypesIncludePersistentLicense = configuration.sessionTypes.contains(CDMSessionType::PersistentLicense);
    bool succeeded = m_swift->bridge.initialize(
        configuration.distinctiveIdentifier == CDMRequirement::Required,
        configuration.persistentState == CDMRequirement::Required,
        configuration.sessionTypes.contains(CDMSessionType::PersistentUsageRecord) || sessionTypesIncludePersistentLicense,
        sessionTypesIncludePersistentLicense,
        persistentState == AllowPersistentState::Yes);
    callback(succeeded ? CDMInstanceSuccessValue::Succeeded : CDMInstanceSuccessValue::Failed);
}

void CDMInstanceFairPlayStreamingAVFObjC::setServerCertificate(Ref<SharedBuffer>&& serverCertificate, SuccessCallback&& callback)
{
    INFO_LOG(LOGIDENTIFIER);
    m_swift->bridge.setServerCertificate({ serverCertificate->makeContiguous()->span() });
    callback(CDMInstanceSuccessValue::Succeeded);
}

void CDMInstanceFairPlayStreamingAVFObjC::setStorageDirectory(const String& storageDirectory)
{
    INFO_LOG(LOGIDENTIFIER);
    m_swift->bridge.setStorageDirectory(mediaParserText(storageDirectory));
}

RefPtr<CDMInstanceSession> CDMInstanceFairPlayStreamingAVFObjC::createSession()
{
    return CDMInstanceSessionFairPlayStreamingAVFObjC::create(*this);
}

void CDMInstanceFairPlayStreamingAVFObjC::setClient(WeakPtr<CDMInstanceClient>&& client)
{
    m_client = WTF::move(client);
}

void CDMInstanceFairPlayStreamingAVFObjC::clearClient()
{
    m_client = nullptr;
}

const String& CDMInstanceFairPlayStreamingAVFObjC::keySystem() const
{
    static const NeverDestroyed<String> s_keySystem { MAKE_STATIC_STRING_IMPL("com.apple.fps") };
    return s_keySystem;
}

bool CDMInstanceFairPlayStreamingAVFObjC::hasSessionForKeyIDs(const CDMKeyIDs& keyIDs) const
{
    FlattenedKeyIDs flattened { keyIDs };
    return m_swift->bridge.hasSession(flattened.view(), flattened.sizesView());
}

RetainPtr<AVContentKeySession> CDMInstanceFairPlayStreamingAVFObjC::contentKeySessionForKeyIDs(const CDMKeyIDs& keyIDs) const
{
    FlattenedKeyIDs flattened { keyIDs };
    return adoptNS(static_cast<AVContentKeySession *>(m_swift->bridge.contentKeySession(flattened.view(), flattened.sizesView())));
}

bool CDMInstanceFairPlayStreamingAVFObjC::isAnyKeyUsable(const CDMKeyIDs& keyIDs) const
{
    FlattenedKeyIDs flattened { keyIDs };
    return m_swift->bridge.isAnyKeyUsable(flattened.view(), flattened.sizesView());
}

void CDMInstanceFairPlayStreamingAVFObjC::outputObscuredDueToInsufficientExternalProtectionChanged(bool obscured)
{
    m_swift->bridge.outputObscuredDueToInsufficientExternalProtectionChanged(obscured);
}

void CDMInstanceFairPlayStreamingAVFObjC::addKeyStatusesChangedObserver(const KeyStatusesChangedObserver& observer)
{
    ASSERT(!m_keyStatusChangedObservers.contains(observer));
    m_keyStatusChangedObservers.add(observer);
}

void CDMInstanceFairPlayStreamingAVFObjC::removeKeyStatusesChangedObserver(const KeyStatusesChangedObserver& observer)
{
    ASSERT(m_keyStatusChangedObservers.contains(observer));
    m_keyStatusChangedObservers.remove(observer);
}

void CDMInstanceFairPlayStreamingAVFObjC::attachContentKeyToSample(const MediaSampleAVFObjC& sample)
{
    FlattenedKeyIDs flattened { sample.keyIDs() };
    RetainPtr contentKey = adoptNS(static_cast<AVContentKey *>(m_swift->bridge.contentKey(flattened.view(), flattened.sizesView())));
    if (!contentKey)
        return;

    NSError *error = nil;
    if (!AVSampleBufferAttachContentKey(protect(sample.platformSample().cmSampleBuffer()), contentKey.get(), &error))
        ERROR_LOG(LOGIDENTIFIER, "Failed to attach content key with error: %{public}@", error);
}

uint64_t fairPlayInstanceToken(CDMInstance& instance)
{
    RefPtr fairPlayInstance = dynamicDowncast<CDMInstanceFairPlayStreamingAVFObjC>(instance);
    return fairPlayInstance ? fairPlayInstance->m_swift->bridge.token() : 0;
}

Ref<CDMInstanceSessionFairPlayStreamingAVFObjC> CDMInstanceSessionFairPlayStreamingAVFObjC::create(Ref<CDMInstanceFairPlayStreamingAVFObjC>&& instance)
{
    return adoptRef(*new CDMInstanceSessionFairPlayStreamingAVFObjC(WTF::move(instance)));
}

CDMInstanceSessionFairPlayStreamingAVFObjC::CDMInstanceSessionFairPlayStreamingAVFObjC(Ref<CDMInstanceFairPlayStreamingAVFObjC>&& instance)
    : m_instance(WTF::move(instance))
#if !RELEASE_LOG_DISABLED
    , m_logger(m_instance->logger())
#endif
    , m_swift { makeUnique<SwiftSession>(m_instance->m_swift->bridge.makeSession(FairPlaySessionHost::create(*this).ptr())) }
{
}

CDMInstanceSessionFairPlayStreamingAVFObjC::~CDMInstanceSessionFairPlayStreamingAVFObjC() = default;

void CDMInstanceSessionFairPlayStreamingAVFObjC::requestLicense(LicenseType licenseType, KeyGroupingStrategy keyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&& callback)
{
    m_swift->bridge.requestLicense(licenseType, keyGroupingStrategy == KeyGroupingStrategy::BuiltIn, mediaParserText(initDataType), { initData->makeContiguous()->span() }, FairPlayLicenseCompletion::create(WTF::move(callback)).ptr());
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::updateLicense(const String&, LicenseType, Ref<SharedBuffer>&& responseData, LicenseUpdateCallback&& callback)
{
    m_swift->bridge.updateLicense({ responseData->makeContiguous()->span() }, FairPlayLicenseUpdateCompletion::create(WTF::move(callback)).ptr());
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::loadSession(LicenseType licenseType, const String& sessionId, const String&, LoadSessionCallback&& callback)
{
    uint32_t releasedKeyCount = 0;
    switch (static_cast<FairPlayLoadSessionStatus>(m_swift->bridge.loadSession(licenseType, mediaParserText(sessionId), releasedKeyCount))) {
    case FairPlayLoadSessionStatus::NotHandled:
        return;
    case FairPlayLoadSessionStatus::Succeeded:
        callback(releasedKeyStatuses(releasedKeyCount), std::nullopt, std::nullopt, Succeeded, SessionLoadFailure::None);
        return;
    case FairPlayLoadSessionStatus::MismatchedSessionType:
        callback(std::nullopt, std::nullopt, std::nullopt, Failed, SessionLoadFailure::MismatchedSessionType);
        return;
    case FairPlayLoadSessionStatus::NoSessionData:
        callback(std::nullopt, std::nullopt, std::nullopt, Failed, SessionLoadFailure::NoSessionData);
        return;
    }
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::closeSession(const String&, CloseSessionCallback&& callback)
{
    m_swift->bridge.closeSession();
    callback();
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::removeSessionData(const String& sessionId, LicenseType licenseType, RemoveSessionDataCallback&& callback)
{
    uint32_t releasedKeyCount = 0;
    bool hasMessage = false;
    MediaParserByteVector message;
    bool succeeded = m_swift->bridge.removeSessionData(licenseType, mediaParserText(sessionId), releasedKeyCount, hasMessage, message);
    callback(releasedKeyStatuses(releasedKeyCount), hasMessage ? RefPtr { SharedBuffer::create(WTF::move(message)) } : nullptr, succeeded ? Succeeded : Failed);
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::storeRecordOfKeyUsage(const String&)
{
    // no-op; key usage data is stored automatically.
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::displayChanged(PlatformDisplayID)
{
    m_swift->bridge.displayChanged();
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::setClient(WeakPtr<CDMInstanceSessionClient>&& client)
{
    m_client = WTF::move(client);
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::clearClient()
{
    m_client = nullptr;
}

RetainPtr<NSDictionary> CDMInstanceSessionFairPlayStreamingAVFObjC::optionsForKeyRequestWithHashSalt(const String& mediaKeysHashSalt)
{
    return adoptNS(fairPlayKeyRequestOptionsImpl(mediaParserText(mediaKeysHashSalt)));
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
