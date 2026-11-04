/*
 * Copyright (C) 2016 Metrological Group B.V.
 * Copyright (C) 2016 Igalia S.L.
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials provided
 *    with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CDMClearKey.h"

#if ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)

#include "CDMInstance.h"
#include "CDMInstanceSession.h"
#include "CDMKeySystemConfiguration.h"
#include "CDMRestrictions.h"
#include "CDMSessionType.h"
#include "InitDataRegistry.h"
#include "SharedBuffer.h"
#include "WebCore-Swift.h"
#include <algorithm>
#include <ranges>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WeakPtr.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMFactoryClearKey);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMPrivateClearKey);

class CDMInstanceClearKey final : public CDMInstance {
public:
    static Ref<CDMInstanceClearKey> create() { return adoptRef(*new CDMInstanceClearKey); }

    ImplementationType implementationType() const final { return ImplementationType::ClearKey; }
    void initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers, AllowPersistentState, SuccessCallback&&) final;
    void setServerCertificate(Ref<SharedBuffer>&&, SuccessCallback&&) final;
    void setStorageDirectory(const String&) final { }
    const String& keySystem() const final;
    RefPtr<CDMInstanceSession> createSession() final;

private:
    CDMInstanceClearKey() = default;

    ClearKeyInstanceBridge m_bridge { ClearKeyInstanceBridge::init() };
};

class CDMInstanceSessionClearKey final : public CDMInstanceSession, public CanMakeWeakPtr<CDMInstanceSessionClearKey> {
public:
    static Ref<CDMInstanceSessionClearKey> create(ClearKeySessionBridge&& bridge) { return adoptRef(*new CDMInstanceSessionClearKey(WTF::move(bridge))); }

    void requestLicense(LicenseType, KeyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&&) final;
    void updateLicense(const String&, LicenseType, Ref<SharedBuffer>&&, LicenseUpdateCallback&&) final;
    void loadSession(LicenseType, const String&, const String&, LoadSessionCallback&&) final;
    void closeSession(const String&, CloseSessionCallback&&) final;
    void removeSessionData(const String&, LicenseType, RemoveSessionDataCallback&&) final;
    void storeRecordOfKeyUsage(const String&) final { }

private:
    explicit CDMInstanceSessionClearKey(ClearKeySessionBridge&& bridge)
        : m_bridge(WTF::move(bridge))
    {
    }

    ClearKeySessionBridge m_bridge;
};

static CDMInstanceSession::KeyStatusVector keyStatuses(const MediaParserByteVector& keyIDs, const MediaParserUInt32Vector& keyIDSizes, CDMKeyStatus status)
{
    CDMInstanceSession::KeyStatusVector result;
    result.reserveInitialCapacity(keyIDSizes.size());
    auto bytes = keyIDs.span();
    for (auto size : keyIDSizes) {
        result.append({ SharedBuffer::create(bytes.first(size)), status });
        bytes = bytes.subspan(size);
    }
    return result;
}

CDMFactoryClearKey& CDMFactoryClearKey::singleton()
{
    static NeverDestroyed<CDMFactoryClearKey> s_factory;
    return s_factory;
}

CDMFactoryClearKey::CDMFactoryClearKey() = default;
CDMFactoryClearKey::~CDMFactoryClearKey() = default;

std::unique_ptr<CDMPrivate> CDMFactoryClearKey::createCDM(const String& keySystem, const String& mediaKeysHashSalt, const CDMPrivateClient&)
{
    ASSERT_UNUSED(keySystem, supportsKeySystem(keySystem));
    UNUSED_PARAM(mediaKeysHashSalt);
    return makeUnique<CDMPrivateClearKey>();
}

bool CDMFactoryClearKey::supportsKeySystem(const String& keySystem)
{
    return clearKeySupportsKeySystemImpl(mediaParserShortName(keySystem));
}

CDMPrivateClearKey::CDMPrivateClearKey() = default;
CDMPrivateClearKey::~CDMPrivateClearKey() = default;

Vector<String> CDMPrivateClearKey::supportedInitDataTypes() const
{
    return {
        InitDataRegistry::keyidsName(),
        InitDataRegistry::cencName(),
        InitDataRegistry::webmName(),
    };
}

NODELETE static bool containsPersistentLicenseType(const Vector<CDMSessionType>& types)
{
    return std::ranges::find(types, CDMSessionType::PersistentLicense) != types.end();
}

static ClearKeyConfiguration clearKeyConfiguration(const CDMKeySystemConfiguration& configuration, const CDMRestrictions& restrictions)
{
    return {
        .distinctiveIdentifier = configuration.distinctiveIdentifier,
        .persistentState = configuration.persistentState,
        .sessionTypesIncludePersistentLicense = containsPersistentLicenseType(configuration.sessionTypes),
        .distinctiveIdentifierDenied = restrictions.distinctiveIdentifierDenied,
        .persistentStateDenied = restrictions.persistentStateDenied,
    };
}

bool CDMPrivateClearKey::supportsConfiguration(const CDMKeySystemConfiguration& configuration) const
{
    return clearKeySupportsConfigurationImpl(clearKeyConfiguration(configuration, { }));
}

bool CDMPrivateClearKey::supportsConfigurationWithRestrictions(const CDMKeySystemConfiguration& configuration, const CDMRestrictions& restrictions) const
{
    return clearKeySupportsConfigurationImpl(clearKeyConfiguration(configuration, restrictions));
}

bool CDMPrivateClearKey::supportsSessionTypeWithConfiguration(const CDMSessionType& sessionType, const CDMKeySystemConfiguration& configuration) const
{
    return clearKeySupportsSessionTypeImpl(sessionType) && supportsConfiguration(configuration);
}

Vector<String> CDMPrivateClearKey::supportedRobustnesses() const
{
    return { emptyString() };
}

CDMRequirement CDMPrivateClearKey::distinctiveIdentifiersRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions& restrictions) const
{
    return clearKeyRequirementImpl(restrictions.distinctiveIdentifierDenied);
}

CDMRequirement CDMPrivateClearKey::persistentStateRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions& restrictions) const
{
    return clearKeyRequirementImpl(restrictions.persistentStateDenied);
}

bool CDMPrivateClearKey::distinctiveIdentifiersAreUniquePerOriginAndClearable(const CDMKeySystemConfiguration&) const
{
    return false;
}

RefPtr<CDMInstance> CDMPrivateClearKey::createInstance()
{
    return CDMInstanceClearKey::create();
}

void CDMPrivateClearKey::loadAndInitialize()
{
}

bool CDMPrivateClearKey::supportsServerCertificates() const
{
    return false;
}

bool CDMPrivateClearKey::supportsSessions() const
{
    return true;
}

bool CDMPrivateClearKey::supportsInitData(const String& initDataType, const SharedBuffer& initData) const
{
    return clearKeySupportsInitDataImpl(mediaParserText(initDataType), { initData.span() });
}

RefPtr<SharedBuffer> CDMPrivateClearKey::sanitizeResponse(const SharedBuffer& response) const
{
    if (!clearKeySanitizeResponseImpl({ response.span() }))
        return nullptr;
    return response.makeContiguous();
}

std::optional<String> CDMPrivateClearKey::sanitizeSessionId(const String& sessionId) const
{
    if (!clearKeyIsValidSessionIDImpl(mediaParserText(sessionId)))
        return std::nullopt;
    return sessionId;
}

void CDMInstanceClearKey::initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers distinctiveIdentifiers, AllowPersistentState persistentState, SuccessCallback&& callback)
{
    bool succeeds = clearKeyInitializationSucceedsImpl(distinctiveIdentifiers == AllowDistinctiveIdentifiers::Yes, persistentState == AllowPersistentState::Yes);
    callback(succeeds ? CDMInstanceSuccessValue::Succeeded : CDMInstanceSuccessValue::Failed);
}

void CDMInstanceClearKey::setServerCertificate(Ref<SharedBuffer>&&, SuccessCallback&& callback)
{
    callback(CDMInstanceSuccessValue::Failed);
}

const String& CDMInstanceClearKey::keySystem() const
{
    static const NeverDestroyed<String> s_keySystem { MAKE_STATIC_STRING_IMPL("org.w3.clearkey") };

    return s_keySystem;
}

RefPtr<CDMInstanceSession> CDMInstanceClearKey::createSession()
{
    return CDMInstanceSessionClearKey::create(m_bridge.makeSession());
}

void CDMInstanceSessionClearKey::requestLicense(LicenseType, KeyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&& callback)
{
    MediaParserByteVector message;
    String sessionID;
    if (!m_bridge.requestLicense(mediaParserText(initDataType), { initData->span() }, message, sessionID))
        initData = SharedBuffer::create(WTF::move(message));

    callOnMainThread([sessionID = WTF::move(sessionID), callback = WTF::move(callback), initData = WTF::move(initData)] mutable {
        callback(WTF::move(initData), sessionID, false, Succeeded);
    });
}

void CDMInstanceSessionClearKey::updateLicense(const String&, LicenseType, Ref<SharedBuffer>&& response, LicenseUpdateCallback&& callback)
{
    MediaParserByteVector keyIDs;
    MediaParserUInt32Vector keyIDSizes;
    auto update = m_bridge.updateLicense({ response->span() }, keyIDs, keyIDSizes);
    std::optional<KeyStatusVector> changedKeys;
    if (update.hasChangedKeys)
        changedKeys = keyStatuses(keyIDs, keyIDSizes, KeyStatus::Usable);

    callOnMainThread([weakThis = WeakPtr { *this }, callback = WTF::move(callback), sessionWasClosed = update.sessionWasClosed, changedKeys = WTF::move(changedKeys), succeeded = update.succeeded ? Succeeded : Failed] mutable {
        if (!weakThis)
            return;

        callback(sessionWasClosed, WTF::move(changedKeys), std::nullopt, std::nullopt, succeeded);
    });
}

void CDMInstanceSessionClearKey::loadSession(LicenseType, const String&, const String&, LoadSessionCallback&& callback)
{
    MediaParserByteVector keyIDs;
    MediaParserUInt32Vector keyIDSizes;
    m_bridge.loadSession(keyIDs, keyIDSizes);
    callOnMainThread([weakThis = WeakPtr { *this }, callback = WTF::move(callback), keyStatusVector = keyStatuses(keyIDs, keyIDSizes, KeyStatus::Usable)] mutable {
        if (!weakThis)
            return;

        callback(WTF::move(keyStatusVector), std::nullopt, std::nullopt, Succeeded, SessionLoadFailure::None);
    });
}

void CDMInstanceSessionClearKey::closeSession(const String&, CloseSessionCallback&& callback)
{
    callOnMainThread([weakThis = WeakPtr { *this }, callback = WTF::move(callback)] mutable {
        if (!weakThis)
            return;

        callback();
    });
}

void CDMInstanceSessionClearKey::removeSessionData(const String&, LicenseType, RemoveSessionDataCallback&& callback)
{
    MediaParserByteVector keyIDs;
    MediaParserUInt32Vector keyIDSizes;
    MediaParserByteVector message;
    m_bridge.removeSessionData(keyIDs, keyIDSizes, message);
    callOnMainThread([weakThis = WeakPtr { *this }, callback = WTF::move(callback), keyStatusVector = keyStatuses(keyIDs, keyIDSizes, KeyStatus::Released), message = SharedBuffer::create(WTF::move(message))] mutable {
        if (!weakThis)
            return;

        callback(WTF::move(keyStatusVector), WTF::move(message), Succeeded);
    });
}

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_CDM_INSTANCE(WebCore::CDMInstanceClearKey, WebCore::CDMInstance::ImplementationType::ClearKey);

#endif // ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)
