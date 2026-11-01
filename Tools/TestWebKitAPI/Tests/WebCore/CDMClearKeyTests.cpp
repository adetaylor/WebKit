/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if ENABLE(ENCRYPTED_MEDIA)

#include "Helpers/Utilities.h"
#include <WebCore/CDMFactory.h>
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/CDMKeyGroupingStrategy.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/CDMPrivate.h>
#include <WebCore/CDMRestrictions.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/HexNumber.h>
#include <wtf/Logger.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/StringBuilder.h>

namespace TestWebKitAPI {
using namespace WebCore;

class ClearKeyTestClient final : public CDMPrivateClient {
public:
    ClearKeyTestClient()
        : m_logger(Logger::create(this))
    {
    }

#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger.get(); }
#endif

private:
    Ref<Logger> m_logger;
};

static CDMFactory* clearKeyFactory()
{
    for (auto& factory : CDMFactory::registeredFactories()) {
        if (factory->supportsKeySystem("org.w3.clearkey"_s))
            return factory.ptr();
    }
    return nullptr;
}

static std::unique_ptr<CDMPrivate> createClearKeyCDM()
{
    static NeverDestroyed<ClearKeyTestClient> client;
    auto* factory = clearKeyFactory();
    if (!factory)
        return nullptr;
    return factory->createCDM("org.w3.clearkey"_s, emptyString(), client.get());
}

static Ref<SharedBuffer> buffer(std::span<const uint8_t> bytes)
{
    return SharedBuffer::create(bytes);
}

static Ref<SharedBuffer> buffer(ASCIILiteral text)
{
    return SharedBuffer::create(text.span8());
}

static String utf16(ASCIILiteral literal)
{
    Vector<char16_t> characters;
    for (auto character : literal.span8())
        characters.append(character);
    String string { characters.span() };
    EXPECT_FALSE(string.is8Bit());
    return string;
}

static String text(const SharedBuffer& buffer)
{
    return String { byteCast<Latin1Character>(buffer.span()) };
}

// The cenc init data from https://www.w3.org/TR/eme-initdata-cenc/#common-system: one ClearKey pssh box with the key IDs
// "0123456789012345" and "ABCDEFGHIJKLMNOP".
static constexpr uint8_t clearKeyPssh[] = {
    0x00, 0x00, 0x00, 0x4c, 0x70, 0x73, 0x73, 0x68, 0x01, 0x00, 0x00, 0x00,
    0x10, 0x77, 0xef, 0xec, 0xc0, 0xb2, 0x4d, 0x02, 0xac, 0xe3, 0x3c, 0x1e, 0x52, 0xe2, 0xfb, 0x4b,
    0x00, 0x00, 0x00, 0x02,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
    0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50,
    0x00, 0x00, 0x00, 0x00,
};

static constexpr uint8_t emptyBytes[1] { };

// Swift traps on an empty span with no base address passed back to C++, so the shells get empty inputs of every kind.
static Vector<Ref<SharedBuffer>> emptyBuffers()
{
    Vector<Ref<SharedBuffer>> buffers;
    buffers.append(SharedBuffer::create());
    buffers.append(SharedBuffer::create(Vector<uint8_t> { }));
    buffers.append(buffer(std::span { emptyBytes }.first(0)));
    return buffers;
}

TEST(CDMClearKey, SupportsKeySystem)
{
    auto* factory = clearKeyFactory();
    ASSERT_TRUE(factory);
    EXPECT_TRUE(factory->supportsKeySystem("org.w3.clearkey"_s));
    EXPECT_TRUE(factory->supportsKeySystem("ORG.W3.ClearKey"_s));
    EXPECT_TRUE(factory->supportsKeySystem(utf16("org.w3.clearkey"_s)));
    EXPECT_FALSE(factory->supportsKeySystem("org.w3.clearkey2"_s));
    EXPECT_FALSE(factory->supportsKeySystem("org.w3.clearke"_s));
    EXPECT_FALSE(factory->supportsKeySystem(emptyString()));
    EXPECT_FALSE(factory->supportsKeySystem(String { }));
}

TEST(CDMClearKey, SupportsInitData)
{
    auto cdm = createClearKeyCDM();
    ASSERT_TRUE(cdm);

    EXPECT_TRUE(cdm->supportsInitData("keyids"_s, buffer("{\"kids\":[\"AAECAwQFBgcICQoLDA0ODw\"]}"_s)));
    EXPECT_TRUE(cdm->supportsInitData("KeyIDs"_s, buffer("{}"_s)));
    EXPECT_FALSE(cdm->supportsInitData("keyids"_s, buffer("[]"_s)));
    EXPECT_FALSE(cdm->supportsInitData("keyids"_s, buffer("{"_s)));

    EXPECT_TRUE(cdm->supportsInitData("cenc"_s, buffer(std::span { clearKeyPssh })));
    EXPECT_TRUE(cdm->supportsInitData(utf16("CENC"_s), buffer(std::span { clearKeyPssh })));
    EXPECT_FALSE(cdm->supportsInitData("webm-cenc"_s, buffer(std::span { clearKeyPssh })));

    // The key IDs may not reach the end of the buffer, and there must be at least one.
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(std::span { clearKeyPssh }.first(sizeof(clearKeyPssh) - 4))));
    Vector<uint8_t> noKeyIDs { std::span { clearKeyPssh } };
    noKeyIDs[31] = 0;
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(noKeyIDs.span())));
    Vector<uint8_t> otherSystem { std::span { clearKeyPssh } };
    otherSystem[12] = 0xed;
    EXPECT_FALSE(cdm->supportsInitData("cenc"_s, buffer(otherSystem.span())));

    // A box that isn't ClearKey's is skipped by its size.
    Vector<uint8_t> twoBoxes { std::span { otherSystem }.first(otherSystem.size() - 4) };
    twoBoxes[3] = otherSystem.size() - 4;
    twoBoxes.append(std::span { clearKeyPssh });
    EXPECT_TRUE(cdm->supportsInitData("cenc"_s, buffer(twoBoxes.span())));

    static constexpr uint8_t keyID[] = { 0x01 };
    EXPECT_TRUE(cdm->supportsInitData("webm"_s, buffer(std::span { keyID })));
    EXPECT_FALSE(cdm->supportsInitData("sinf"_s, buffer(std::span { keyID })));
    EXPECT_FALSE(cdm->supportsInitData(emptyString(), buffer(std::span { keyID })));
    EXPECT_FALSE(cdm->supportsInitData(String { }, buffer(std::span { keyID })));

    for (auto& empty : emptyBuffers()) {
        EXPECT_FALSE(cdm->supportsInitData("keyids"_s, empty));
        EXPECT_FALSE(cdm->supportsInitData("cenc"_s, empty));
        EXPECT_FALSE(cdm->supportsInitData("webm"_s, empty));
    }
}

TEST(CDMClearKey, SanitizeSessionId)
{
    auto cdm = createClearKeyCDM();
    ASSERT_TRUE(cdm);

    EXPECT_EQ(cdm->sanitizeSessionId("0"_s), "0"_s);
    EXPECT_EQ(cdm->sanitizeSessionId("4294967295"_s), "4294967295"_s);
    EXPECT_EQ(cdm->sanitizeSessionId(" +12\n"_s), " +12\n"_s);
    EXPECT_EQ(cdm->sanitizeSessionId("007"_s), "007"_s);
    EXPECT_EQ(cdm->sanitizeSessionId(utf16("42"_s)), "42"_s);
    EXPECT_FALSE(cdm->sanitizeSessionId("4294967296"_s));
    EXPECT_FALSE(cdm->sanitizeSessionId("-1"_s));
    EXPECT_FALSE(cdm->sanitizeSessionId("1a"_s));
    EXPECT_FALSE(cdm->sanitizeSessionId(" "_s));
    EXPECT_FALSE(cdm->sanitizeSessionId(utf16("4x"_s)));
    EXPECT_FALSE(cdm->sanitizeSessionId(emptyString()));
    EXPECT_FALSE(cdm->sanitizeSessionId(String { }));
}

TEST(CDMClearKey, SanitizeResponse)
{
    auto cdm = createClearKeyCDM();
    ASSERT_TRUE(cdm);

    auto response = cdm->sanitizeResponse(buffer("{\"kids\":[]}"_s));
    ASSERT_TRUE(response);
    EXPECT_EQ(text(*response), "{\"kids\":[]}"_s);
    EXPECT_FALSE(cdm->sanitizeResponse(buffer("[]"_s)));
    for (auto& empty : emptyBuffers())
        EXPECT_FALSE(cdm->sanitizeResponse(empty));
}

TEST(CDMClearKey, Configuration)
{
    auto cdm = createClearKeyCDM();
    ASSERT_TRUE(cdm);

    CDMKeySystemConfiguration configuration;
    CDMRestrictions restrictions;
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));

    configuration.distinctiveIdentifier = CDMRequirement::Required;
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.distinctiveIdentifier = CDMRequirement::Optional;
    restrictions.distinctiveIdentifierDenied = true;
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.distinctiveIdentifier = CDMRequirement::NotAllowed;
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));

    configuration.persistentState = CDMRequirement::Required;
    EXPECT_FALSE(cdm->supportsConfiguration(configuration));
    configuration.sessionTypes = { CDMSessionType::Temporary, CDMSessionType::PersistentLicense };
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
    EXPECT_TRUE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));
    configuration.persistentState = CDMRequirement::Optional;
    restrictions.persistentStateDenied = true;
    EXPECT_TRUE(cdm->supportsConfiguration(configuration));
    EXPECT_FALSE(cdm->supportsConfigurationWithRestrictions(configuration, restrictions));

    CDMKeySystemConfiguration defaultConfiguration;
    EXPECT_TRUE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::Temporary, defaultConfiguration));
    EXPECT_TRUE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::PersistentLicense, defaultConfiguration));
    EXPECT_FALSE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::PersistentUsageRecord, defaultConfiguration));
    defaultConfiguration.distinctiveIdentifier = CDMRequirement::Required;
    EXPECT_FALSE(cdm->supportsSessionTypeWithConfiguration(CDMSessionType::Temporary, defaultConfiguration));

    EXPECT_EQ(cdm->distinctiveIdentifiersRequirement(configuration, { }), CDMRequirement::Optional);
    EXPECT_EQ(cdm->distinctiveIdentifiersRequirement(configuration, restrictions), CDMRequirement::NotAllowed);
    EXPECT_EQ(cdm->persistentStateRequirement(configuration, { }), CDMRequirement::Optional);
    EXPECT_EQ(cdm->persistentStateRequirement(configuration, restrictions), CDMRequirement::NotAllowed);
}

TEST(CDMClearKey, InitializeWithConfiguration)
{
    auto cdm = createClearKeyCDM();
    ASSERT_TRUE(cdm);
    auto instance = cdm->createInstance();
    ASSERT_TRUE(instance);

    auto initialize = [&](CDMInstance::AllowDistinctiveIdentifiers distinctiveIdentifiers, CDMInstance::AllowPersistentState persistentState) {
        std::optional<CDMInstance::SuccessValue> result;
        instance->initializeWithConfiguration({ }, distinctiveIdentifiers, persistentState, [&](auto succeeded) {
            result = succeeded;
        });
        return result;
    };
    EXPECT_TRUE(initialize(CDMInstance::AllowDistinctiveIdentifiers::No, CDMInstance::AllowPersistentState::No) == CDMInstanceSuccessValue::Succeeded);
    EXPECT_TRUE(initialize(CDMInstance::AllowDistinctiveIdentifiers::Yes, CDMInstance::AllowPersistentState::No) == CDMInstanceSuccessValue::Failed);
    EXPECT_TRUE(initialize(CDMInstance::AllowDistinctiveIdentifiers::No, CDMInstance::AllowPersistentState::Yes) == CDMInstanceSuccessValue::Failed);
    EXPECT_TRUE(initialize(CDMInstance::AllowDistinctiveIdentifiers::Yes, CDMInstance::AllowPersistentState::Yes) == CDMInstanceSuccessValue::Failed);
}

struct ClearKeySession {
    std::unique_ptr<CDMPrivate> cdm;
    RefPtr<CDMInstance> instance;
    RefPtr<CDMInstanceSession> session;
};

static ClearKeySession createClearKeySession()
{
    ClearKeySession result;
    result.cdm = createClearKeyCDM();
    if (result.cdm)
        result.instance = result.cdm->createInstance();
    if (result.instance)
        result.session = result.instance->createSession();
    return result;
}

struct LicenseRequest {
    String message;
    String sessionId;
};

static LicenseRequest requestLicense(CDMInstanceSession& session, const String& initDataType, Ref<SharedBuffer>&& initData)
{
    LicenseRequest result;
    bool done = false;
    session.requestLicense(CDMSessionType::Temporary, CDMKeyGroupingStrategy::Platform, initDataType, WTF::move(initData), [&](Ref<SharedBuffer>&& message, const String& sessionId, bool, CDMInstanceSession::SuccessValue succeeded) {
        EXPECT_EQ(succeeded, CDMInstanceSession::Succeeded);
        result = { text(message), sessionId };
        done = true;
    });
    Util::run(&done);
    return result;
}

TEST(CDMClearKey, RequestLicense)
{
    auto [cdm, instance, session] = createClearKeySession();
    ASSERT_TRUE(session);

    auto request = requestLicense(*session, "cenc"_s, buffer(std::span { clearKeyPssh }));
    EXPECT_EQ(request.message, "{\"kids\":[\"MDEyMzQ1Njc4OTAxMjM0NQ\",\"QUJDREVGR0hJSktMTU5PUA\"]}"_s);
    EXPECT_EQ(request.sessionId, "0"_s);
    EXPECT_TRUE(requestLicense(*session, "cenc"_s, buffer(std::span { clearKeyPssh }.first(40))).message.isEmpty());

    static constexpr uint8_t keyID[] = { 0x01, 0x02, 0x03 };
    request = requestLicense(*session, "WebM"_s, buffer(std::span { keyID }));
    EXPECT_EQ(request.message, "{\"kids\":[\"AQID\"]}"_s);
    EXPECT_EQ(request.sessionId, "2"_s);

    EXPECT_EQ(requestLicense(*session, "keyids"_s, buffer("{\"kids\":[\"AQID\"]}"_s)).message, "{\"kids\":[\"AQID\"]}"_s);
    EXPECT_EQ(requestLicense(*session, "sinf"_s, buffer(std::span { keyID })).message, "\x01\x02\x03"_s);

    for (auto& empty : emptyBuffers()) {
        EXPECT_TRUE(requestLicense(*session, "cenc"_s, empty.copyRef()).message.isEmpty());
        EXPECT_TRUE(requestLicense(*session, "webm"_s, empty.copyRef()).message.isEmpty());
        EXPECT_TRUE(requestLicense(*session, "keyids"_s, empty.copyRef()).message.isEmpty());
    }
}

struct LicenseUpdate {
    bool sessionWasClosed { false };
    std::optional<Vector<String>> changedKeys;
    bool succeeded { false };
};

static String hexString(const SharedBuffer& buffer)
{
    StringBuilder builder;
    for (auto byte : buffer.span())
        builder.append(hex(byte, 2, Lowercase));
    return builder.toString();
}

static LicenseUpdate updateLicense(CDMInstanceSession& session, const String& sessionId, Ref<SharedBuffer>&& response)
{
    LicenseUpdate result;
    bool done = false;
    session.updateLicense(sessionId, CDMSessionType::Temporary, WTF::move(response), [&](bool sessionWasClosed, std::optional<CDMInstanceSession::KeyStatusVector>&& changedKeys, std::optional<double>&&, std::optional<CDMInstanceSession::Message>&&, CDMInstanceSession::SuccessValue succeeded) {
        result.sessionWasClosed = sessionWasClosed;
        if (changedKeys) {
            result.changedKeys = Vector<String> { };
            for (auto& [keyID, status] : *changedKeys) {
                EXPECT_EQ(status, CDMKeyStatus::Usable);
                result.changedKeys->append(hexString(keyID));
            }
        }
        result.succeeded = succeeded == CDMInstanceSession::Succeeded;
        done = true;
    });
    Util::run(&done);
    return result;
}

static String releaseMessage(CDMInstanceSession& session, const String& sessionId)
{
    String result;
    bool done = false;
    session.removeSessionData(sessionId, CDMSessionType::Temporary, [&](CDMInstanceSession::KeyStatusVector&& keyStatuses, RefPtr<SharedBuffer>&& message, CDMInstanceSession::SuccessValue succeeded) {
        EXPECT_EQ(succeeded, CDMInstanceSession::Succeeded);
        for (auto& keyStatus : keyStatuses)
            EXPECT_EQ(keyStatus.second, CDMKeyStatus::Released);
        result = message ? text(*message) : String { };
        done = true;
    });
    Util::run(&done);
    return result;
}

TEST(CDMClearKey, UpdateLicense)
{
    auto [cdm, instance, session] = createClearKeySession();
    ASSERT_TRUE(session);
    auto sessionId = requestLicense(*session, "keyids"_s, buffer("{}"_s)).sessionId;

    auto update = updateLicense(*session, sessionId, buffer("{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AAECAwQFBgcICQoLDA0ODw\",\"k\":\"EBESExQVFhcYGRobHB0eHw\"}]}"_s));
    EXPECT_TRUE(update.succeeded);
    EXPECT_FALSE(update.sessionWasClosed);
    ASSERT_TRUE(update.changedKeys);
    EXPECT_EQ(*update.changedKeys, Vector<String> { "000102030405060708090a0b0c0d0e0f"_s });
    EXPECT_EQ(releaseMessage(*session, sessionId), "{\"kids\":[\"AAECAwQFBgcICQoLDA0ODw\"]}"_s);
    EXPECT_EQ(releaseMessage(*session, sessionId), "{\"kids\":[]}"_s);

    // The key type is compared ignoring ASCII case, and an empty key value decodes to no bytes.
    update = updateLicense(*session, sessionId, buffer("{\"keys\":[{\"kty\":\"OcT\",\"kid\":\"AQID\",\"k\":\"\"}],\"kids\":[]}"_s));
    EXPECT_TRUE(update.succeeded);
    EXPECT_FALSE(update.sessionWasClosed);
    ASSERT_TRUE(update.changedKeys);
    EXPECT_EQ(*update.changedKeys, Vector<String> { "010203"_s });

    update = updateLicense(*session, sessionId, buffer("{\"keys\":[]}"_s));
    EXPECT_TRUE(update.succeeded);
    EXPECT_FALSE(update.changedKeys);

    // Invalid keys make the whole license invalid; then a "kids" array makes it a release acknowledgement.
    update = updateLicense(*session, sessionId, buffer("{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AQID\",\"k\":\"AQID\"},{\"kty\":\"oct\",\"kid\":\"AQID\"}],\"kids\":[]}"_s));
    EXPECT_TRUE(update.succeeded);
    EXPECT_TRUE(update.sessionWasClosed);
    EXPECT_EQ(releaseMessage(*session, sessionId), "{\"kids\":[]}"_s);

    for (auto response : {
        "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AQID\",\"k\":\"A\"}]}"_s,
        "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"\",\"k\":\"!\"}]}"_s,
        "{\"keys\":[{\"kty\":\"\",\"kid\":\"\",\"k\":\"\"}]}"_s,
        "{\"keys\":[{\"kty\":\"rsa\",\"kid\":\"AQID\",\"k\":\"AQID\"}]}"_s,
        "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AQID\",\"k\":\"\\u0100\"}]}"_s,
        "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"AQID\",\"k\":1}]}"_s,
        "{\"keys\":[[]]}"_s,
        "{\"keys\":{},\"kids\":{}}"_s,
        "{}"_s,
        "[]"_s,
    }) {
        update = updateLicense(*session, sessionId, buffer(response));
        EXPECT_FALSE(update.succeeded) << response.characters();
        EXPECT_FALSE(update.sessionWasClosed);
        EXPECT_FALSE(update.changedKeys);
    }
    for (auto& empty : emptyBuffers())
        EXPECT_FALSE(updateLicense(*session, sessionId, empty.copyRef()).succeeded);
}

} // namespace TestWebKitAPI

#endif // ENABLE(ENCRYPTED_MEDIA)
