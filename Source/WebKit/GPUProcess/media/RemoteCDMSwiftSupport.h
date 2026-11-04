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

#pragma once

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

#include "Decoder.h"
#include "RemoteCDMConfiguration.h"
#include "RemoteCDMInstanceConfiguration.h"
#include "RemoteCDMRegistry.h"
#include "SwiftCoding.h"
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/CDMMediaCapability.h>
#include <wtf/CompletionHandler.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/AtomString.h>

namespace WebKit {

// What the Swift EME message receivers use of RemoteCDMRegistry that Swift cannot reach directly: Swift
// cannot hold a WeakPtr, or construct an ObjectIdentifier.

class RemoteCDMRegistryWeakReference {
public:
    explicit RemoteCDMRegistryWeakReference(RemoteCDMRegistry& registry)
        : m_registry(registry)
    {
    }

    // A new reference, so that Swift keeps the registry alive for as long as it uses it.
    RemoteCDMRegistry* WTF_NULLABLE get() const SWIFT_RETURNS_RETAINED { return RefPtr { m_registry.get() }.leakRef(); }

private:
    WeakPtr<RemoteCDMRegistry> m_registry;
} SWIFT_SELF_CONTAINED;

// Returns 0 if no CDM was created.
inline uint64_t createRemoteCDM(RemoteCDMRegistry& registry, const String& keySystem, const String& mediaKeysHashSalt, RemoteCDMConfiguration& configuration)
{
    auto identifier = registry.createCDM(keySystem, mediaKeysHashSalt, configuration);
    return identifier ? identifier->toUInt64() : 0;
}

inline void removeRemoteCDMInstance(RemoteCDMRegistry& registry, uint64_t identifier)
{
    registry.removeInstance(RemoteCDMInstanceIdentifier(identifier));
}

inline void removeRemoteCDMInstanceSession(RemoteCDMRegistry& registry, uint64_t identifier)
{
    registry.removeSession(RemoteCDMInstanceSessionIdentifier(identifier));
}

using RemoteCDMStrings = Vector<String>;

inline size_t remoteCDMStringCount(const RemoteCDMStrings& strings)
{
    return strings.size();
}

inline String remoteCDMString(const RemoteCDMStrings& strings, size_t index)
{
    return index < strings.size() ? strings[index] : String();
}

// Returns 0 if no instance was created.
uint64_t createRemoteCDMInstance(const RemoteCDMRegistryWeakReference&, RemoteCDMPrivateHandle&, RemoteCDMInstanceConfiguration&);

// Builds the CDMKeySystemConfiguration that a Swift receiver hands to C++.
class RemoteCDMKeySystemConfigurationBuilder {
public:
    void setLabel(const String& label) { m_configuration.label = label; }
    void appendInitDataType(const String& type) { m_configuration.initDataTypes.append(AtomString { type }); }
    void appendCapability(bool isVideo, const String& contentType, const String& robustness, bool hasEncryptionScheme, bool encryptionScheme)
    {
        auto& capabilities = isVideo ? m_configuration.videoCapabilities : m_configuration.audioCapabilities;
        capabilities.append({ contentType, robustness, hasEncryptionScheme ? std::optional { static_cast<WebCore::CDMEncryptionScheme>(encryptionScheme) } : std::nullopt });
    }
    void setDistinctiveIdentifier(uint8_t requirement) { m_configuration.distinctiveIdentifier = static_cast<WebCore::CDMRequirement>(requirement); }
    void setPersistentState(uint8_t requirement) { m_configuration.persistentState = static_cast<WebCore::CDMRequirement>(requirement); }
    void appendSessionType(uint8_t type) { m_configuration.sessionTypes.append(static_cast<WebCore::CDMSessionType>(type)); }

    WebCore::CDMKeySystemConfiguration take() { return WTF::move(m_configuration); }

private:
    WebCore::CDMKeySystemConfiguration m_configuration;
} SWIFT_SELF_CONTAINED;

// A CDMKeySystemConfiguration from C++, encoded as IPC encodes it so that Swift can decode it with the
// coders of its messages.
class RemoteCDMEncodedConfiguration {
    WTF_MAKE_NONCOPYABLE(RemoteCDMEncodedConfiguration);
public:
    explicit RemoteCDMEncodedConfiguration(const std::optional<WebCore::CDMKeySystemConfiguration>&);
    RemoteCDMEncodedConfiguration(RemoteCDMEncodedConfiguration&&);
    ~RemoteCDMEncodedConfiguration();

    IPC::SwiftDecoder swiftDecoder() const LIFETIME_BOUND { return m_decoder.swiftDecoder(); }

private:
    IPC::SwiftOwnedDecoder m_decoder;
} SWIFT_SELF_CONTAINED;

inline IPC::SwiftDecoder swiftDecoder(const RemoteCDMEncodedConfiguration& configuration LIFETIME_BOUND)
{
    return configuration.swiftDecoder();
}

using RemoteCDMSupportedConfigurationCompletionHandler = CompletionHandler<void(RemoteCDMEncodedConfiguration&&)>;

void getSupportedRemoteCDMConfiguration(RemoteCDMPrivateHandle&, RemoteCDMKeySystemConfigurationBuilder&, bool localStorageAccessAllowed, RemoteCDMSupportedConfigurationCompletionHandler&&);

class RemoteCDMPrivateHandleWeakReference {
public:
    explicit RemoteCDMPrivateHandleWeakReference(RemoteCDMPrivateHandle& cdm)
        : m_cdm(cdm)
    {
    }

    // A new reference, so that Swift keeps the handle alive for as long as it uses it.
    RemoteCDMPrivateHandle* WTF_NULLABLE get() const SWIFT_RETURNS_RETAINED { return RefPtr { m_cdm.get() }.leakRef(); }

private:
    WeakPtr<RemoteCDMPrivateHandle> m_cdm;
} SWIFT_SELF_CONTAINED;

// Returns 0 if no session was created.
uint64_t createRemoteCDMInstanceSession(const RemoteCDMRegistryWeakReference&, const RemoteCDMPrivateHandleWeakReference&, WebCore::CDMInstance&, uint64_t logIdentifier);

using RemoteCDMInstanceSuccessCompletionHandler = CompletionHandler<void(WebCore::CDMInstanceSuccessValue)>;

void initializeRemoteCDMInstance(WebCore::CDMInstance&, RemoteCDMKeySystemConfigurationBuilder&, bool distinctiveIdentifiersAllowed, bool persistentStateAllowed, RemoteCDMInstanceSuccessCompletionHandler&&);
void setRemoteCDMInstanceServerCertificate(WebCore::CDMInstance&, WebCore::SharedBuffer&, RemoteCDMInstanceSuccessCompletionHandler&&);
void setRemoteCDMInstanceStorageDirectory(WebCore::CDMInstance&, const String&);

// A CDMInstanceSession's result, encoded as the reply of the session's message encodes it, so that Swift decodes
// it with the coders of its messages.
class RemoteCDMEncodedReply {
    WTF_MAKE_NONCOPYABLE(RemoteCDMEncodedReply);
public:
    explicit RemoteCDMEncodedReply(IPC::Encoder&);
    RemoteCDMEncodedReply(RemoteCDMEncodedReply&&);
    ~RemoteCDMEncodedReply();

    IPC::SwiftDecoder swiftDecoder() const LIFETIME_BOUND { return m_decoder.swiftDecoder(); }

private:
    IPC::SwiftOwnedDecoder m_decoder;
} SWIFT_SELF_CONTAINED;

inline IPC::SwiftDecoder swiftDecoder(const RemoteCDMEncodedReply& reply LIFETIME_BOUND)
{
    return reply.swiftDecoder();
}

using RemoteCDMEncodedReplyCompletionHandler = CompletionHandler<void(RemoteCDMEncodedReply&&)>;

// The CDMPrivate checks of the session's messages.
bool remoteCDMSupportsInitData(const RemoteCDMPrivateHandleWeakReference&, const String& initDataType, const WebCore::SharedBuffer& initData);
WebCore::SharedBuffer* WTF_NULLABLE sanitizeRemoteCDMResponse(const RemoteCDMPrivateHandleWeakReference&, const WebCore::SharedBuffer& response) SWIFT_RETURNS_RETAINED;
bool sanitizeRemoteCDMSessionId(const RemoteCDMPrivateHandleWeakReference&, const String& sessionId, String& sanitizedSessionId);

void setRemoteCDMInstanceSessionLogIdentifier(WebCore::CDMInstanceSession&, uint64_t logIdentifier);
void requestRemoteCDMLicense(WebCore::CDMInstanceSession&, uint8_t type, bool keyGroupingStrategy, const String& initDataType, WebCore::SharedBuffer& initData, RemoteCDMEncodedReplyCompletionHandler&&);
void updateRemoteCDMLicense(WebCore::CDMInstanceSession&, const String& sessionId, uint8_t type, WebCore::SharedBuffer& response, RemoteCDMEncodedReplyCompletionHandler&&);
void loadRemoteCDMSession(WebCore::CDMInstanceSession&, uint8_t type, const String& sessionId, const String& origin, RemoteCDMEncodedReplyCompletionHandler&&);
void closeRemoteCDMSession(WebCore::CDMInstanceSession&, const String& sessionId, WTF::VoidCompletionHandler&&);
void removeRemoteCDMSessionData(WebCore::CDMInstanceSession&, const String& sessionId, uint8_t type, RemoteCDMEncodedReplyCompletionHandler&&);
void storeRemoteCDMRecordOfKeyUsage(WebCore::CDMInstanceSession&, const String& sessionId);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
