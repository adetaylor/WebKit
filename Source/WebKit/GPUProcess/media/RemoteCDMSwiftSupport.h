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
#include "MessageReceiver.h"
#include "RemoteCDMConfiguration.h"
#include "RemoteCDMFactoryProxy.h"
#include "SwiftCoding.h"
#include "SwiftReceiverRegistration.h"
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMInstanceSession.h>
#include <WebCore/CDMKeySystemConfiguration.h>
#include <WebCore/CDMMediaCapability.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/AtomString.h>

namespace WebKit {

// What the Swift EME message receivers use of RemoteCDMFactoryProxy and of the C++ CDMs that Swift cannot reach
// directly: Swift cannot call a C++ virtual function's overriders' callbacks.

using RemoteCDMStrings = Vector<String>;

inline size_t remoteCDMStringCount(const RemoteCDMStrings& strings)
{
    return strings.size();
}

inline String remoteCDMString(const RemoteCDMStrings& strings, size_t index)
{
    return index < strings.size() ? strings[index] : String();
}

// The bytes of a buffer from IPC, and a buffer for a reply.
using RemoteCDMBytes = Vector<uint8_t>;

inline RemoteCDMBytes remoteCDMBufferBytes(const WebCore::SharedBuffer& buffer)
{
    return RemoteCDMBytes { buffer.span() };
}

WebCore::SharedBuffer* WTF_NONNULL makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE) SWIFT_RETURNS_RETAINED;

// A C++ CDM's instance, registered with the factory under identifier, with its key system, and the token of its Swift
// FairPlay Streaming instance (FairPlayInstance.instance(forToken:)), 0 if it has none. Null if the CDM makes none.
WebCore::CDMInstance* WTF_NULLABLE createRemoteCDMInstance(RemoteCDMFactoryProxy&, RemoteCDMPrivateHandle&, uint64_t identifier, String& keySystem, uint64_t& fairPlayInstanceToken) SWIFT_RETURNS_RETAINED;

// The CDMKeySystemConfiguration of a message, which C++ decodes for the C++ CDM that a Swift receiver hands it to.
using RemoteCDMConfigurationArgument = IPC::CxxDecodedArgument<WebCore::CDMKeySystemConfiguration>;

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

void getSupportedRemoteCDMConfiguration(RemoteCDMPrivateHandle&, RemoteCDMConfigurationArgument&, bool localStorageAccessAllowed, RemoteCDMSupportedConfigurationCompletionHandler&&);

using RemoteCDMInstanceSuccessCompletionHandler = CompletionHandler<void(WebCore::CDMInstanceSuccessValue)>;

void initializeRemoteCDMInstance(WebCore::CDMInstance&, RemoteCDMConfigurationArgument&, bool distinctiveIdentifiersAllowed, bool persistentStateAllowed, RemoteCDMInstanceSuccessCompletionHandler&&);
void setRemoteCDMInstanceStorageDirectory(WebCore::CDMInstance&, const String&);

// The CDMPrivate checks of the session's messages.
bool remoteCDMSupportsInitData(RemoteCDMPrivateHandle&, const String& initDataType, const WebCore::SharedBuffer& initData);
WebCore::SharedBuffer* WTF_NULLABLE sanitizeRemoteCDMResponse(RemoteCDMPrivateHandle&, const WebCore::SharedBuffer& response) SWIFT_RETURNS_RETAINED;
bool sanitizeRemoteCDMSessionId(RemoteCDMPrivateHandle&, const String& sessionId, String& sanitizedSessionId);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)
