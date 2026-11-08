/*
 * Copyright (C) 2017-2025 Apple Inc. All rights reserved.
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

#include "CDMInstance.h"
#include "CDMInstanceSession.h"
#include "CDMKeyID.h"
#include <wtf/Observer.h>
#include <wtf/RetainPtr.h>
#include <wtf/WeakHashSet.h>

OBJC_CLASS AVContentKeySession;
OBJC_CLASS NSDictionary;

#if !RELEASE_LOG_DISABLED
namespace WTF {
class Logger;
}
#endif

namespace WebCore {

class CDMPrivateFairPlayStreaming;
class MediaSampleAVFObjC;
struct CDMMediaCapability;

// The FairPlay Streaming CDM's instance and sessions. Their state and their AVContentKeySessions are Swift's
// (CDMInstanceFairPlayStreamingAVF.swift); these keep what the players, the CDM interfaces and the clients reach.

class CDMInstanceFairPlayStreamingAVFObjC final : public CDMInstance, public CanMakeWeakPtr<CDMInstanceFairPlayStreamingAVFObjC> {
public:
    static Ref<CDMInstanceFairPlayStreamingAVFObjC> create(const CDMPrivateFairPlayStreaming&);
    virtual ~CDMInstanceFairPlayStreamingAVFObjC();

    static bool supportsPersistableState();
    NODELETE static bool supportsPersistentKeys();
    static bool supportsMediaCapability(const CDMMediaCapability&);

    ImplementationType implementationType() const final { return ImplementationType::FairPlayStreaming; }

    void initializeWithConfiguration(const CDMKeySystemConfiguration&, AllowDistinctiveIdentifiers, AllowPersistentState, SuccessCallback&&) final;
    void setServerCertificate(Ref<SharedBuffer>&&, SuccessCallback&&) final;
    void setStorageDirectory(const String&) final;
    RefPtr<CDMInstanceSession> createSession() final;
    void setClient(WeakPtr<CDMInstanceClient>&&) final;
    void clearClient() final;

    const String& keySystem() const final;

    bool hasSessionForKeyIDs(const CDMKeyIDs&) const;
    RetainPtr<AVContentKeySession> contentKeySessionForKeyIDs(const CDMKeyIDs&) const;
    bool isAnyKeyUsable(const CDMKeyIDs&) const;
    void outputObscuredDueToInsufficientExternalProtectionChanged(bool);

    using KeyStatusesChangedObserver = Observer<void()>;
    void addKeyStatusesChangedObserver(const KeyStatusesChangedObserver&);
    void removeKeyStatusesChangedObserver(const KeyStatusesChangedObserver&);

    void attachContentKeyToSample(const MediaSampleAVFObjC&);

#if !RELEASE_LOG_DISABLED
    void setLogIdentifier(uint64_t logIdentifier) final { m_logIdentifier = logIdentifier; }
    const Logger& logger() const { return m_logger; };
    uint64_t logIdentifier() const { return m_logIdentifier; }
    ASCIILiteral logClassName() const { return "CDMInstanceFairPlayStreamingAVFObjC"_s; }
#endif

private:
    friend class CDMInstanceSessionFairPlayStreamingAVFObjC;
    friend class FairPlayInstanceHost;
    friend uint64_t fairPlayInstanceToken(CDMInstance&);

    explicit CDMInstanceFairPlayStreamingAVFObjC(const CDMPrivateFairPlayStreaming&);

    struct SwiftInstance;

    WeakPtr<CDMInstanceClient> m_client;
    WeakHashSet<KeyStatusesChangedObserver> m_keyStatusChangedObservers;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
    const std::unique_ptr<SwiftInstance> m_swift;
};

class CDMInstanceSessionFairPlayStreamingAVFObjC final : public CDMInstanceSession, public CanMakeWeakPtr<CDMInstanceSessionFairPlayStreamingAVFObjC> {
public:
    static Ref<CDMInstanceSessionFairPlayStreamingAVFObjC> create(Ref<CDMInstanceFairPlayStreamingAVFObjC>&&);
    virtual ~CDMInstanceSessionFairPlayStreamingAVFObjC();

    void requestLicense(LicenseType, KeyGroupingStrategy, const String& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&&) final;
    void updateLicense(const String&, LicenseType, Ref<SharedBuffer>&&, LicenseUpdateCallback&&) final;
    void loadSession(LicenseType, const String&, const String&, LoadSessionCallback&&) final;
    void closeSession(const String&, CloseSessionCallback&&) final;
    void removeSessionData(const String&, LicenseType, RemoveSessionDataCallback&&) final;
    void storeRecordOfKeyUsage(const String&) final;
    void displayChanged(PlatformDisplayID) final;
    void setClient(WeakPtr<CDMInstanceSessionClient>&&) final;
    void clearClient() final;

    static RetainPtr<NSDictionary> optionsForKeyRequestWithHashSalt(const String&);

#if !RELEASE_LOG_DISABLED
    void setLogIdentifier(uint64_t logIdentifier) final { m_logIdentifier = logIdentifier; }
    const Logger& logger() const { return m_logger; };
    uint64_t logIdentifier() const { return m_logIdentifier; }
    ASCIILiteral logClassName() const { return "CDMInstanceSessionFairPlayStreamingAVFObjC"_s; }
#endif

private:
    friend class FairPlaySessionHost;

    explicit CDMInstanceSessionFairPlayStreamingAVFObjC(Ref<CDMInstanceFairPlayStreamingAVFObjC>&&);

    struct SwiftSession;

    const Ref<CDMInstanceFairPlayStreamingAVFObjC> m_instance;
    WeakPtr<CDMInstanceSessionClient> m_client;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
    std::unique_ptr<SwiftSession> m_swift;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_CDM_INSTANCE(WebCore::CDMInstanceFairPlayStreamingAVFObjC, WebCore::CDMInstance::ImplementationType::FairPlayStreaming)

#endif // ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
