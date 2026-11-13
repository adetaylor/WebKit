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

#include "config.h"
#include "CDMFairPlayStreaming.h"

#if ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)

#include "CDM.h"
#include "CDMClearKey.h"
#include "CDMKeySystemConfiguration.h"
#include "CDMRestrictions.h"
#include "CDMSessionType.h"
#include "InitDataRegistry.h"
#include "Logging.h"
#include "NotImplemented.h"
#include "SharedBuffer.h"
#include "WebCore-Swift.h"
#include <algorithm>
#include <wtf/JSONValues.h>
#include <wtf/LoggerHelper.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

#if HAVE(AVCONTENTKEYSESSION)
#include "CDMInstanceFairPlayStreamingAVFObjC.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMFactoryFairPlayStreaming);
WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMPrivateFairPlayStreaming);

#if !RELEASE_LOG_DISABLED
NODELETE static WTFLogChannel& logChannel() { return LogEME; }
#endif

// The parsing and the decisions are in CDMFairPlayStreamingParsing.swift. The JSON stays here.

// The key IDs of 'sinf' init data are the default key IDs of 'tenc' boxes.
static constexpr size_t sinfKeyIDSize = 16;

const String& CDMPrivateFairPlayStreaming::sinfName()
{
    static NeverDestroyed<const String> staticSinfName(MAKE_STATIC_STRING_IMPL("sinf"));
    return staticSinfName;
}

const String& CDMPrivateFairPlayStreaming::skdName()
{
    static NeverDestroyed<const String> staticSkdName(MAKE_STATIC_STRING_IMPL("skd"));
    return staticSkdName;
}

static FairPlayInitDataType initDataTypeFromName(const String& name)
{
    return fairPlayInitDataTypeImpl(mediaParserShortName(name));
}

// The key IDs whose scheme is valid, back to back, or nullopt when no entry has both a scheme and a key ID.
static std::optional<Vector<uint8_t>> sinfKeyIDs(const SharedBuffer& buffer)
{
    // JSON of the format: "{ sinf: [ <base64-encoded-string> ] }"
    if (buffer.size() > std::numeric_limits<unsigned>::max())
        return std::nullopt;

    auto value = JSON::Value::parseJSON(byteCast<Latin1Character>(buffer.makeContiguous()->span()));
    if (!value)
        return std::nullopt;

    auto object = value->asObject();
    if (!object)
        return std::nullopt;

    auto sinfArray = object->getArray(CDMPrivateFairPlayStreaming::sinfName());
    if (!sinfArray)
        return std::nullopt;

    Vector<uint8_t> keyIDs;
    bool hasSchemeAndKeyID = false;
    for (auto& entry : *sinfArray) {
        auto sinf = entry->asString();
        if (!sinf)
            continue;

        if (sinf.is8Bit() ? fairPlaySinfKeyIDLatin1Impl({ sinf.span8() }, keyIDs) : fairPlaySinfKeyIDUTF16Impl({ sinf.span16() }, keyIDs))
            hasSchemeAndKeyID = true;
    }
    if (!hasSchemeAndKeyID)
        return std::nullopt;

    return keyIDs;
}

std::optional<Vector<Ref<SharedBuffer>>> CDMPrivateFairPlayStreaming::extractKeyIDsSinf(const SharedBuffer& buffer)
{
    auto keyIDBytes = sinfKeyIDs(buffer);
    if (!keyIDBytes)
        return std::nullopt;

    Vector<Ref<SharedBuffer>> keyIDs;
    for (auto bytes = keyIDBytes->span(); !bytes.empty(); bytes = bytes.subspan(sinfKeyIDSize))
        keyIDs.append(SharedBuffer::create(bytes.first(sinfKeyIDSize)));

    return keyIDs;
}

RefPtr<SharedBuffer> CDMPrivateFairPlayStreaming::sanitizeSinf(const SharedBuffer& buffer)
{
    // Common SINF Box Format
    UNUSED_PARAM(buffer);
    notImplemented();
    return buffer.makeContiguous();
}

RefPtr<SharedBuffer> CDMPrivateFairPlayStreaming::sanitizeSkd(const SharedBuffer& buffer)
{
    UNUSED_PARAM(buffer);
    notImplemented();
    return buffer.makeContiguous();
}

std::optional<Vector<Ref<SharedBuffer>>> CDMPrivateFairPlayStreaming::extractKeyIDsSkd(const SharedBuffer& buffer)
{
    // In the 'skd' scheme, the init data is the key ID.
    return Vector { buffer.makeContiguous() };
}

#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
const String& CDMPrivateFairPlayStreaming::mptsName()
{
    static NeverDestroyed<const String> staticMptsName(MAKE_STATIC_STRING_IMPL("mpts"));
    return staticMptsName;
}

std::optional<Vector<Ref<SharedBuffer>>> CDMPrivateFairPlayStreaming::extractKeyIDsMpts(const SharedBuffer& buffer)
{
    // JSON of the format: "{ "codc" : [integer],  "mtyp" : [integer],  "cont" : "mpts"} }"
    if (buffer.size() > std::numeric_limits<unsigned>::max())
        return { };

    auto value = JSON::Value::parseJSON(byteCast<Latin1Character>(buffer.makeContiguous()->span()));
    if (!value)
        return { };

    auto object = value->asObject();
    if (!object)
        return { };

    auto contValue = object->getString("cont"_s);
    if (contValue != "mpts"_s)
        return { };

    auto codcValue = object->getInteger("codc"_s);
    if (!codcValue)
        return { };

    auto mtypValue = object->getInteger("mtyp"_s);
    if (!mtypValue)
        return { };

    return mptsKeyIDs();
}

RefPtr<SharedBuffer> CDMPrivateFairPlayStreaming::sanitizeMpts(const SharedBuffer& buffer)
{
    UNUSED_PARAM(buffer);
    notImplemented();
    return buffer.makeContiguous();
}

const Vector<Ref<SharedBuffer>>& CDMPrivateFairPlayStreaming::mptsKeyIDs()
{
    static NeverDestroyed<Vector<Ref<SharedBuffer>>> mptsKeyID = [] {
        return Vector<Ref<SharedBuffer>> { FillWith { }, 1, SharedBuffer::create("TransportStreamIdentifier"_span) };
    }();
    return mptsKeyID;
}
#endif

void CDMFactory::platformRegisterFactories(Vector<WeakRef<CDMFactory>>& factories)
{
    factories.append(CDMFactoryClearKey::singleton());
    factories.append(CDMFactoryFairPlayStreaming::singleton());
}

CDMFactoryFairPlayStreaming& CDMFactoryFairPlayStreaming::singleton()
{
    static NeverDestroyed<CDMFactoryFairPlayStreaming> s_factory;
    return s_factory;
}

CDMFactoryFairPlayStreaming::CDMFactoryFairPlayStreaming() = default;
CDMFactoryFairPlayStreaming::~CDMFactoryFairPlayStreaming() = default;

std::unique_ptr<CDMPrivate> CDMFactoryFairPlayStreaming::createCDM(const String& keySystem, const String& mediaKeysHashSalt, const CDMPrivateClient& client)
{
    if (!supportsKeySystem(keySystem))
        return nullptr;

    return makeUnique<CDMPrivateFairPlayStreaming>(mediaKeysHashSalt, client);
}

bool CDMFactoryFairPlayStreaming::supportsKeySystem(const String& keySystem)
{
    // https://w3c.github.io/encrypted-media/#key-system
    // "Key System strings are compared using case-sensitive matching."
    return keySystem == "com.apple.fps"_s || keySystem.startsWith("com.apple.fps."_s);
}

CDMPrivateFairPlayStreaming::CDMPrivateFairPlayStreaming(const String& mediaKeysHashSalt, const CDMPrivateClient& client)
    : m_mediaKeysHashSalt { mediaKeysHashSalt }
#if !RELEASE_LOG_DISABLED
    , m_logger { client.logger() }
#endif
{
}

CDMPrivateFairPlayStreaming::~CDMPrivateFairPlayStreaming() = default;

Vector<String> CDMPrivateFairPlayStreaming::supportedInitDataTypes() const
{
    return {
        sinfName(),
        skdName(),
#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
        InitDataRegistry::cencName(),
#endif
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
        mptsName(),
#endif
    };
}

template<typename SessionTypes>
static FairPlaySessionTypes fairPlaySessionTypes(const SessionTypes& sessionTypes)
{
    return {
        .temporary = sessionTypes.contains(CDMSessionType::Temporary),
        .persistentUsageRecord = sessionTypes.contains(CDMSessionType::PersistentUsageRecord),
        .persistentLicense = sessionTypes.contains(CDMSessionType::PersistentLicense),
    };
}

static FairPlayConfiguration fairPlayConfiguration(const CDMKeySystemConfiguration& configuration)
{
    FairPlayConfiguration result {
        .hasSupportedInitDataType = std::ranges::any_of(configuration.initDataTypes, [](auto& initDataType) {
            return initDataTypeFromName(initDataType) != FairPlayInitDataType::Other;
        }),
        .distinctiveIdentifier = configuration.distinctiveIdentifier,
        .persistentState = configuration.persistentState,
        .sessionTypes = fairPlaySessionTypes(configuration.sessionTypes),
        .hasAudioCapabilities = !configuration.audioCapabilities.isEmpty(),
        .hasVideoCapabilities = !configuration.videoCapabilities.isEmpty(),
    };
#if HAVE(AVCONTENTKEYSESSION)
    result.hasSupportedAudioCapability = std::ranges::any_of(configuration.audioCapabilities, CDMInstanceFairPlayStreamingAVFObjC::supportsMediaCapability);
    result.hasSupportedVideoCapability = std::ranges::any_of(configuration.videoCapabilities, CDMInstanceFairPlayStreamingAVFObjC::supportsMediaCapability);
    result.supportsPersistableState = CDMInstanceFairPlayStreamingAVFObjC::supportsPersistableState();
    result.supportsPersistentKeys = CDMInstanceFairPlayStreamingAVFObjC::supportsPersistentKeys();
#endif
    return result;
}

bool CDMPrivateFairPlayStreaming::supportsConfiguration(const CDMKeySystemConfiguration& configuration) const
{
    switch (fairPlayConfigurationSupportImpl(fairPlayConfiguration(configuration))) {
    case FairPlayConfigurationSupport::Supported:
        INFO_LOG(LOGIDENTIFIER, "true, supported");
        return true;
    case FairPlayConfigurationSupport::NoSupportedInitDataType:
        INFO_LOG(LOGIDENTIFIER, " false, no initDataType supported");
        return false;
    case FairPlayConfigurationSupport::NoContentKeySession:
        return false;
    case FairPlayConfigurationSupport::DistinctiveIdentifierRequired:
        INFO_LOG(LOGIDENTIFIER, "false, requried distinctiveIdentifier not supported");
        return false;
    case FairPlayConfigurationSupport::PersistentStateUnsupported:
        INFO_LOG(LOGIDENTIFIER, "false, required persistentState not supported");
        return false;
    case FairPlayConfigurationSupport::PersistentLicenseUnsupported:
        INFO_LOG(LOGIDENTIFIER, "false, sessionType PersistentLicense not supported");
        return false;
    case FairPlayConfigurationSupport::NoSupportedAudioCapability:
        INFO_LOG(LOGIDENTIFIER, "false, no audio configuration supported");
        return false;
    case FairPlayConfigurationSupport::NoSupportedVideoCapability:
        INFO_LOG(LOGIDENTIFIER, "false, no video configuration supported");
        return false;
    }
    ASSERT_NOT_REACHED();
    return false;
}

bool CDMPrivateFairPlayStreaming::supportsConfigurationWithRestrictions(const CDMKeySystemConfiguration& configuration, const CDMRestrictions& restrictions) const
{
    if (!fairPlayAllowsRestrictionsImpl(configuration.persistentState, fairPlaySessionTypes(configuration.sessionTypes), restrictions.persistentStateDenied, fairPlaySessionTypes(restrictions.deniedSessionTypes)))
        return false;

    return supportsConfiguration(configuration);
}

bool CDMPrivateFairPlayStreaming::supportsSessionTypeWithConfiguration(const CDMSessionType& sessionType, const CDMKeySystemConfiguration& configuration) const
{
    return fairPlaySupportsSessionTypeImpl(sessionType, configuration.persistentState) && supportsConfiguration(configuration);
}

Vector<String> CDMPrivateFairPlayStreaming::supportedRobustnesses() const
{
    // FIXME: Determine an enumerated list of robustness values supported by FPS.
    return { emptyString() };
}

CDMRequirement CDMPrivateFairPlayStreaming::distinctiveIdentifiersRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions&) const
{
    // FIXME: verify that FairPlayStreaming does not (and cannot) expose a distinctive identifier to the client
    return CDMRequirement::NotAllowed;
}

CDMRequirement CDMPrivateFairPlayStreaming::persistentStateRequirement(const CDMKeySystemConfiguration&, const CDMRestrictions&) const
{
    return CDMRequirement::Optional;
}

bool CDMPrivateFairPlayStreaming::distinctiveIdentifiersAreUniquePerOriginAndClearable(const CDMKeySystemConfiguration&) const
{
    return true;
}

RefPtr<CDMInstance> CDMPrivateFairPlayStreaming::createInstance()
{
#if HAVE(AVCONTENTKEYSESSION)
    auto instance = CDMInstanceFairPlayStreamingAVFObjC::create(*this);
#if !RELEASE_LOG_DISABLED
    instance->setLogIdentifier(m_logIdentifier);
#endif
    return instance;
#else
    return nullptr;
#endif
}

void CDMPrivateFairPlayStreaming::loadAndInitialize()
{
}

bool CDMPrivateFairPlayStreaming::supportsServerCertificates() const
{
    return true;
}

bool CDMPrivateFairPlayStreaming::supportsSessions() const
{
    return true;
}

bool CDMPrivateFairPlayStreaming::supportsInitData(const String& initDataType, const SharedBuffer& initData) const
{
    switch (initDataTypeFromName(initDataType)) {
    case FairPlayInitDataType::Other:
        return false;
    case FairPlayInitDataType::Sinf: {
        auto keyIDs = sinfKeyIDs(initData);
        return keyIDs && !keyIDs->isEmpty();
    }
    case FairPlayInitDataType::Cenc: {
#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
        return cencHasFairPlayPsshImpl({ initData.span() });
#else
        return false;
#endif
    }
    case FairPlayInitDataType::Skd:
    case FairPlayInitDataType::Mpts:
        return true;
    }
    ASSERT_NOT_REACHED();
    return false;
}

RefPtr<SharedBuffer> CDMPrivateFairPlayStreaming::sanitizeResponse(const SharedBuffer& response) const
{
    return response.makeContiguous();
}

std::optional<String> CDMPrivateFairPlayStreaming::sanitizeSessionId(const String& sessionId) const
{
    return sessionId;
}

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && ENABLE(WEBCORE_SWIFT)
