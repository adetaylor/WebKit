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

#pragma once

#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)

#include <WebCore/CDMInstanceSession.h>
#include <WebCore/CDMMessageType.h>
#include <span>
#include <wtf/EscapableByteSpan.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>

#ifdef __OBJC__
@class AVContentKeyRequest;
#endif

namespace WebCore {

class CDMInstanceFairPlayStreamingAVFObjC;
class CDMInstanceSessionFairPlayStreamingAVFObjC;

// What the Swift FairPlay Streaming instance and sessions (CDMInstanceFairPlayStreamingAVF.swift) reach of the C++
// CDMInstance and CDMInstanceSession that own them. Byte views are UTF-8 for text; a key status list is its key IDs
// back to back, their sizes, and one CDMKeyStatus per key ID.

using FairPlayUInt32Span = std::span<const uint32_t>;

inline constexpr uint32_t fairPlayEmptyKeyIDSizes[1] { };

// The sizes of key IDs passed to Swift back to back.
struct SWIFT_VIEW FairPlayKeyIDSizes {
    std::span<const uint32_t> sizes;
    ALWAYS_INLINE FairPlayUInt32Span span() const LIFETIME_BOUND { return sizes.empty() ? std::span { fairPlayEmptyKeyIDSizes }.first<0>() : sizes; }
};

enum class FairPlayLogLevel : uint8_t {
    Always,
    Error,
    Info,
};

enum class FairPlayLoadSessionStatus : uint8_t {
    NotHandled,
    Succeeded,
    MismatchedSessionType,
    NoSessionData,
};

// Refers to the C++ instance weakly: the C++ instance owns the Swift one.
class FairPlayInstanceHost final : public RefCounted<FairPlayInstanceHost> {
public:
    static Ref<FairPlayInstanceHost> create(CDMInstanceFairPlayStreamingAVFObjC&);
    ~FairPlayInstanceHost();

    void unrequestedInitializationDataReceived(WTF::SpanUInt8 initDataType NOESCAPE, WTF::SpanUInt8 initData NOESCAPE) const;
    void keyStatusesChanged() const;
    void log(FairPlayLogLevel, WTF::SpanUInt8 method NOESCAPE, WTF::SpanUInt8 message NOESCAPE) const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<FairPlayInstanceHost>::ref(); }
    void deref() const { RefCounted<FairPlayInstanceHost>::deref(); }
#endif

private:
    explicit FairPlayInstanceHost(CDMInstanceFairPlayStreamingAVFObjC&);

    WeakPtr<CDMInstanceFairPlayStreamingAVFObjC> m_instance;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// Refers to the C++ session weakly: the C++ session owns the Swift one.
class FairPlaySessionHost final : public RefCounted<FairPlaySessionHost> {
public:
    static Ref<FairPlaySessionHost> create(CDMInstanceSessionFairPlayStreamingAVFObjC&);
    ~FairPlaySessionHost();

    bool hasClient() const;
    void sendMessage(CDMMessageType, WTF::SpanUInt8 message NOESCAPE) const;
    void sessionIdChanged(WTF::SpanUInt8 sessionId NOESCAPE) const;
    void updateKeyStatuses(WTF::SpanUInt8 keyIDs NOESCAPE, FairPlayUInt32Span keyIDSizes NOESCAPE, WTF::SpanUInt8 statuses NOESCAPE) const;
    void log(FairPlayLogLevel, WTF::SpanUInt8 method NOESCAPE, WTF::SpanUInt8 message NOESCAPE) const;

#ifdef __swift__
    void ref() const { RefCounted<FairPlaySessionHost>::ref(); }
    void deref() const { RefCounted<FairPlaySessionHost>::deref(); }
#endif

private:
    explicit FairPlaySessionHost(CDMInstanceSessionFairPlayStreamingAVFObjC&);

    WeakPtr<CDMInstanceSessionFairPlayStreamingAVFObjC> m_session;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A CDMInstanceSession::LicenseCallback, which the Swift session calls at most once.
class FairPlayLicenseCompletion final : public RefCounted<FairPlayLicenseCompletion> {
public:
    static Ref<FairPlayLicenseCompletion> create(CDMInstanceSession::LicenseCallback&&);
    ~FairPlayLicenseCompletion();

    // The session identifier is null unless hasSessionId.
    void complete(WTF::SpanUInt8 message NOESCAPE, bool hasSessionId, WTF::SpanUInt8 sessionId NOESCAPE, bool succeeded);

#ifdef __swift__
    void ref() const { RefCounted<FairPlayLicenseCompletion>::ref(); }
    void deref() const { RefCounted<FairPlayLicenseCompletion>::deref(); }
#endif

private:
    explicit FairPlayLicenseCompletion(CDMInstanceSession::LicenseCallback&&);

    CDMInstanceSession::LicenseCallback m_callback;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A CDMInstanceSession::LicenseUpdateCallback, which the Swift session calls at most once.
class FairPlayLicenseUpdateCompletion final : public RefCounted<FairPlayLicenseUpdateCompletion> {
public:
    static Ref<FairPlayLicenseUpdateCompletion> create(CDMInstanceSession::LicenseUpdateCallback&&);
    ~FairPlayLicenseUpdateCompletion();

    void fail(bool sessionWasClosed);
    void succeed();
    void succeedWithKeyStatuses(WTF::SpanUInt8 keyIDs NOESCAPE, FairPlayUInt32Span keyIDSizes NOESCAPE, WTF::SpanUInt8 statuses NOESCAPE);
    void succeedWithMessage(CDMMessageType, WTF::SpanUInt8 message NOESCAPE);

#ifdef __swift__
    void ref() const { RefCounted<FairPlayLicenseUpdateCompletion>::ref(); }
    void deref() const { RefCounted<FairPlayLicenseUpdateCompletion>::deref(); }
#endif

private:
    explicit FairPlayLicenseUpdateCompletion(CDMInstanceSession::LicenseUpdateCallback&&);

    CDMInstanceSession::LicenseUpdateCallback m_callback;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#ifdef __OBJC__
// -[AVContentKeyRequest makeStreamingContentKeyRequestDataForApp:contentIdentifier:options:completionHandler:], or the
// exception it throws, which Swift can't catch.
NSException * _Nullable makeFairPlayStreamingContentKeyRequestData(AVContentKeyRequest * _Nonnull, NSData * _Nullable appIdentifier, NSData * _Nullable contentIdentifier, NSDictionary * _Nullable options, void (^ _Nonnull NS_SWIFT_SENDABLE completionHandler)(NSData * _Nullable, NSError * _Nullable));
#endif

} // namespace WebCore

#endif // ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
