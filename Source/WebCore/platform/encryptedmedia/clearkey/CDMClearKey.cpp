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

#include <wtf/text/TextStream.h>

#if ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)

#include "CDMKeySystemConfiguration.h"
#include "CDMRestrictions.h"
#include "CDMSessionType.h"
#include "CDMUtilities.h"
#include "InitDataRegistry.h"
#include "Logging.h"
#include "SharedBuffer.h"
#include "WebCore-Swift.h"
#include <algorithm>
#include <ranges>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/Base64.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMFactoryClearKey);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMPrivateClearKey);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMInstanceClearKey);

// The parsing and the decisions are in CDMClearKeyParsing.swift. The JSON stays here.

static ClearKeyInitDataType initDataTypeFromName(const String& name)
{
    return clearKeyInitDataTypeImpl(mediaParserShortName(name));
}

static bool isOctKeyType(const String& keyType)
{
    return clearKeyIsOctKeyTypeImpl(mediaParserShortName(keyType));
}

static std::optional<Vector<uint8_t>> decodeBase64URL(const String& string)
{
    Vector<uint8_t> bytes;
    auto options = OptionSet { Base64DecodeOption::URL }.toRaw();
    bool decoded = string.is8Bit() ? base64DecodeLatin1Impl({ string.span8() }, options, bytes) : base64DecodeUTF16Impl({ string.span16() }, options, bytes);
    if (!decoded)
        return std::nullopt;
    return bytes;
}

static String encodeBase64URL(std::span<const uint8_t> bytes)
{
    return base64EncodeToStringImpl({ bytes }, OptionSet { Base64EncodeOption::URL, Base64EncodeOption::OmitPadding }.toRaw());
}

// The 'license request' and 'license release' formats: {"kids":["<base64url key ID>",...]}.
static Ref<SharedBuffer> keyIDsMessage(Ref<JSON::Array>&& keyIDs)
{
    auto object = JSON::Object::create();
    object->setArray("kids"_s, WTF::move(keyIDs));
    return SharedBuffer::create(object->toJSONString().utf8().span());
}

static Ref<SharedBuffer> licenseRequestMessage(const ClearKeyLicenseRequest& request, std::span<const uint8_t> initData)
{
    if (!request.keyIDCount)
        return SharedBuffer::create();

    auto keyIDs = JSON::Array::create();
    auto keyIDBytes = initData.subspan(request.firstKeyIDOffset);
    for (uint32_t i = 0; i < request.keyIDCount; ++i) {
        keyIDs->pushString(encodeBase64URL(keyIDBytes.first(request.keyIDSize)));
        keyIDBytes = keyIDBytes.subspan(request.keyIDSize);
    }
    return keyIDsMessage(WTF::move(keyIDs));
}

// The 'license' format is a "keys" array of JSON Web Keys, the 'license release acknowledgement' format a "kids" array.
static ClearKeyUpdateKind classifyUpdate(const JSON::Object& root, Vector<Ref<KeyHandle>>& licenseKeys)
{
    auto keys = root.getArray("keys"_s);
    bool keysAreValid = keys && std::all_of(keys->begin(), keys->end(), [&licenseKeys](const auto& value) {
        auto keyObject = value->asObject();
        if (!keyObject)
            return false;

        auto keyType = keyObject->getString("kty"_s);
        auto keyID = keyObject->getString("kid"_s);
        auto keyValue = keyObject->getString("k"_s);
        if (!keyType || !keyID || !keyValue || !isOctKeyType(keyType))
            return false;

        auto keyIDData = decodeBase64URL(keyID);
        auto keyHandleValueData = decodeBase64URL(keyValue);
        if (!keyIDData || !keyHandleValueData)
            return false;

        licenseKeys.append(KeyHandle::create(CDMInstanceSession::KeyStatus::Usable, WTF::move(*keyIDData), WTF::move(*keyHandleValueData)));
        return true;
    });
    // FIXME: Return the key IDs of a release acknowledgement and validate them.
    return clearKeyClassifyUpdateImpl(!!keys, keysAreValid, !!root.getArray("kids"_s));
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

static bool LEGACY_NODELETE containsPersistentLicenseType(const Vector<CDMSessionType>& types)
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
    // Only empty `robustness` string is supported.
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
    return adoptRef(new CDMInstanceClearKey);
}

void CDMPrivateClearKey::loadAndInitialize()
{
    // No-op.
}

bool CDMPrivateClearKey::supportsServerCertificates() const
{
    // Server certificates are not supported.
    return false;
}

bool CDMPrivateClearKey::supportsSessions() const
{
    // Sessions are supported.
    return true;
}

bool CDMPrivateClearKey::supportsInitData(const String& initDataType, const SharedBuffer& initData) const
{
    auto support = clearKeySupportsInitDataImpl(mediaParserShortName(initDataType), { initData.span() });
    if (support.type == ClearKeyInitDataType::KeyIDs)
        return !!CDMUtilities::parseJSONObject(initData);
    return support.supported;
}

RefPtr<SharedBuffer> CDMPrivateClearKey::sanitizeResponse(const SharedBuffer& response) const
{
    // Validate the response buffer as an JSON object.
    if (!CDMUtilities::parseJSONObject(response))
        return nullptr;

    return response.makeContiguous();
}

std::optional<String> CDMPrivateClearKey::sanitizeSessionId(const String& sessionId) const
{
    if (!(sessionId.is8Bit() ? clearKeyIsValidSessionIDLatin1Impl({ sessionId.span8() }) : clearKeyIsValidSessionIDUTF16Impl({ sessionId.span16() })))
        return std::nullopt;
    return sessionId;
}

CDMInstanceClearKey::CDMInstanceClearKey() : CDMInstanceProxy("org.w3.clearkey"_s) { };
CDMInstanceClearKey::~CDMInstanceClearKey() = default;

void CDMInstanceClearKey::initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers distinctiveIdentifiers, AllowPersistentState persistentState, SuccessCallback&& callback)
{
    SuccessValue succeeded = clearKeyInitializationSucceedsImpl(distinctiveIdentifiers == AllowDistinctiveIdentifiers::Yes, persistentState == AllowPersistentState::Yes) ? CDMInstanceSuccessValue::Succeeded : CDMInstanceSuccessValue::Failed;
    callback(succeeded);
}

void CDMInstanceClearKey::setServerCertificate(Ref<SharedBuffer>&&, SuccessCallback&& callback)
{
    // Reject setting any server certificate.
    callback(CDMInstanceSuccessValue::Failed);
}

void CDMInstanceClearKey::setStorageDirectory(const String&)
{
}

const String& CDMInstanceClearKey::keySystem() const
{
    static const NeverDestroyed<String> s_keySystem { MAKE_STATIC_STRING_IMPL("org.w3.clearkey") };

    return s_keySystem;
}

RefPtr<CDMInstanceSession> CDMInstanceClearKey::createSession()
{
    return adoptRef(new CDMInstanceSessionClearKey(*this));
}

void CDMInstanceSessionClearKey::requestLicense(LicenseType, KeyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&& callback)
{
    if (RefPtr parentInstance = this->parentInstance())
        m_sessionID = String::number(parentInstance->getNextSessionIdValue());
    else
        m_sessionID = emptyString();

    auto request = clearKeyLicenseRequestImpl(initDataTypeFromName(initDataType), { initData->span() });
    if (!request.initDataIsRequest)
        initData = licenseRequestMessage(request, initData->span());

    callOnMainThread(
        [sessionID = m_sessionID, callback = WTF::move(callback), initData = WTF::move(initData)]() mutable {
            callback(WTF::move(initData), sessionID, false, Succeeded);
        });
}

void CDMInstanceSessionClearKey::updateLicense(const String& sessionId, LicenseType, Ref<SharedBuffer>&& response, LicenseUpdateCallback&& callback)
{
#if LOG_DISABLED
    // We only use the sesion ID for debug logging. The verbose preprocessor checks are because
    // the Mac port has -Werror -Wunused-parameter.
    UNUSED_PARAM(sessionId);
#endif
    auto dispatchCallback =
        [weakThis = WeakPtr { *this }, &callback](bool sessionWasClosed, std::optional<KeyStatusVector>&& changedKeys, SuccessValue succeeded) {
            callOnMainThread(
                [weakThis = WeakPtr { *weakThis }, callback = WTF::move(callback), sessionWasClosed, changedKeys = WTF::move(changedKeys), succeeded] () mutable {
                    if (!weakThis)
                        return;

                    callback(sessionWasClosed, WTF::move(changedKeys), std::nullopt, std::nullopt, succeeded);
                });
        };

    RefPtr<JSON::Object> root = CDMUtilities::parseJSONObject(response);
    if (!root) {
        LOG_WITH_STREAM(EME, stream << "EME - ClearKey - session "_s << sessionId << " update payload was not valid JSON"_s);
        dispatchCallback(false, std::nullopt, SuccessValue::Failed);
        return;
    }

    RefPtr parentInstance = this->parentInstance();
    if (!parentInstance) {
        LOG_WITH_STREAM(EME, stream << "EME - ClearKey - session "_s << sessionId << " is in an invalid state"_s);
        dispatchCallback(false, std::nullopt, SuccessValue::Failed);
        return;
    }


    LOG_WITH_STREAM(EME, stream << "EME - ClearKey - updating license for session "_s << sessionId << " which currently contains "_s << m_keyStore.numKeys() << " keys"_s);

    Vector<Ref<KeyHandle>> decodedKeys;
    switch (classifyUpdate(*root, decodedKeys)) {
    case ClearKeyUpdateKind::License: {
        bool keysChanged = m_keyStore.addKeys(WTF::move(decodedKeys));

        LOG_WITH_STREAM(EME, stream << "EME - ClearKey - session "_s << sessionId << " has "_s << m_keyStore.numKeys() << " keys after update()"_s);

        std::optional<KeyStatusVector> changedKeys;
        if (keysChanged) {
            LOG_WITH_STREAM(EME, stream << "EME - ClearKey - session "_s << sessionId << " has changed keys"_s);
            parentInstance->mergeKeysFrom(m_keyStore);
            changedKeys = m_keyStore.convertToJSKeyStatusVector();
        }

        dispatchCallback(false, WTF::move(changedKeys), SuccessValue::Succeeded);
        return;
    }
    case ClearKeyUpdateKind::ReleaseAcknowledgement:
        LOG_WITH_STREAM(EME, stream << "EME - ClearKey - session "_s << sessionId << " release acknowledged, clearing all known keys"_s);
        parentInstance->unrefAllKeysFrom(m_keyStore);
        m_keyStore.clear();
        dispatchCallback(true, std::nullopt, SuccessValue::Succeeded);
        return;
    case ClearKeyUpdateKind::Invalid:
        break;
    }

    LOG_WITH_STREAM(EME, stream << "EME - ClearKey - session "_s << sessionId << " update payload was an unrecognized format"_s);
    dispatchCallback(false, std::nullopt, SuccessValue::Failed);
}

void CDMInstanceSessionClearKey::loadSession(LicenseType, const String& sessionId, const String&, LoadSessionCallback&& callback)
{
    ASSERT_UNUSED(sessionId, sessionId == m_sessionID);
    KeyStatusVector keyStatusVector = m_keyStore.convertToJSKeyStatusVector();
    callOnMainThread([weakThis = WeakPtr { *this }, callback = WTF::move(callback), keyStatusVector = WTF::move(keyStatusVector)]() mutable {
        if (!weakThis)
            return;

        callback(WTF::move(keyStatusVector), std::nullopt, std::nullopt, Succeeded, SessionLoadFailure::None);
    });
}

void CDMInstanceSessionClearKey::closeSession(const String&, CloseSessionCallback&& callback)
{
    callOnMainThread(
        [weakThis = WeakPtr { *this }, callback = WTF::move(callback)] () mutable {
            if (!weakThis)
                return;

            callback();
        });
}

void CDMInstanceSessionClearKey::removeSessionData(const String& sessionId, LicenseType, RemoveSessionDataCallback&& callback)
{
    ASSERT_UNUSED(sessionId, sessionId == m_sessionID);

    auto dispatchCallback =
        [weakThis = WeakPtr { *this }, &callback](KeyStatusVector&& keyStatusVector, RefPtr<SharedBuffer>&& message, SuccessValue success) {
            callOnMainThread(
                [weakThis = WeakPtr { *weakThis }, callback = WTF::move(callback), keyStatusVector = WTF::move(keyStatusVector), message = WTF::move(message), success]() mutable {
                    if (!weakThis)
                        return;

                    callback(WTF::move(keyStatusVector), WTF::move(message), success);
                });
        };

    // Construct the KeyStatusVector object, representing released keys, and the message in the
    // 'license release' format.
    KeyStatusVector keyStatusVector = m_keyStore.allKeysAs(CDMInstanceSession::KeyStatus::Released);
    // The key IDs of all keys that were associated with this session, in key store order.
    auto keyIDs = JSON::Array::create();
    for (const auto& key : m_keyStore.values()) {
        ASSERT(key->id().size() <= std::numeric_limits<unsigned>::max());
        keyIDs->pushString(encodeBase64URL(key->id().span()));
    }
    RefPtr<SharedBuffer> message = keyIDsMessage(WTF::move(keyIDs));

    m_keyStore.clear();
    dispatchCallback(WTF::move(keyStatusVector), WTF::move(message), SuccessValue::Succeeded);
}

void CDMInstanceSessionClearKey::storeRecordOfKeyUsage(const String&)
{
}

CDMInstanceClearKey* CDMInstanceSessionClearKey::parentInstance() const
{
    return dynamicDowncast<CDMInstanceClearKey>(cdmInstanceProxy().get());
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)
