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
#include "RemoteCDMRegistry.h"
#include "SwiftCoding.h"
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

// What the Swift EME message receivers use of RemoteCDMRegistry and of the C++ CDMs that Swift cannot reach
// directly: Swift cannot hold a WeakPtr, call a C++ virtual function's overriders' callbacks, or construct an
// ObjectIdentifier.

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

// Routes the web process's messages for a Swift receiver (its receiver name and identifier) to the receiver's message
// forwarder in the connection's MessageReceiverMap, as long as it lives.
class RemoteCDMReceiverRegistration final : public RefCounted<RemoteCDMReceiverRegistration> {
public:
    static Ref<RemoteCDMReceiverRegistration> create(GPUConnectionToWebProcess&, IPC::MessageReceiver&, IPC::ReceiverName, uint64_t identifier);
    ~RemoteCDMReceiverRegistration();

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<RemoteCDMReceiverRegistration>::ref(); }
    void deref() const { RefCounted<RemoteCDMReceiverRegistration>::deref(); }
#endif

private:
    RemoteCDMReceiverRegistration(GPUConnectionToWebProcess&, IPC::MessageReceiver&, IPC::ReceiverName, uint64_t identifier);

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    const IPC::ReceiverName m_receiverName;
    const uint64_t m_identifier;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

RemoteCDMReceiverRegistration* WTF_NULLABLE makeRemoteCDMReceiverRegistration(const RemoteCDMRegistry&, IPC::MessageReceiver&, IPC::ReceiverName, uint64_t identifier) SWIFT_RETURNS_RETAINED;

template<typename> struct IsRefOfRemoteCDMMessageReceiver : std::false_type { };
template<typename T> struct IsRefOfRemoteCDMMessageReceiver<Ref<T>> : std::bool_constant<std::derived_from<T, IPC::MessageReceiver>> { };

// Registers a Swift receiver's message forwarder. Null if the web process's connection has gone. A template so that
// Swift, which can't pass a forwarder as the MessageReceiver it is, can pass the Ref to it that it holds. The
// static_assert is used because the constraint isn't enforced for Swift callers.
template<typename ForwarderRef>
RemoteCDMReceiverRegistration* WTF_NULLABLE registerRemoteCDMReceiver(const RemoteCDMRegistry& registry, const ForwarderRef& forwarder, IPC::ReceiverName receiverName, uint64_t identifier) SWIFT_RETURNS_RETAINED
{
    static_assert(IsRefOfRemoteCDMMessageReceiver<ForwarderRef>::value);
    return makeRemoteCDMReceiverRegistration(registry, forwarder.get(), receiverName, identifier);
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

// The bytes of a buffer from IPC, and a buffer for a reply.
using RemoteCDMBytes = Vector<uint8_t>;

inline RemoteCDMBytes remoteCDMBufferBytes(const WebCore::SharedBuffer& buffer)
{
    return RemoteCDMBytes { buffer.span() };
}

WebCore::SharedBuffer* WTF_NONNULL makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE) SWIFT_RETURNS_RETAINED;

// A C++ CDM's instance, registered with the registry under identifier, with its key system, and the token of its Swift
// FairPlay Streaming instance (FairPlayInstance.instance(forToken:)), 0 if it has none. Null if the CDM makes none.
WebCore::CDMInstance* WTF_NULLABLE createRemoteCDMInstance(RemoteCDMRegistry&, RemoteCDMPrivateHandle&, uint64_t identifier, String& keySystem, uint64_t& fairPlayInstanceToken) SWIFT_RETURNS_RETAINED;

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
