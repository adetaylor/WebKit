/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)

#include <WebCore/LegacyCDMSession.h>
#include <wtf/CheckedPtr.h>
#include <wtf/Forward.h>
#include <wtf/Function.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/text/WTFString.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebCore {

class LegacyCDM;
class CDMPrivateInterface;
class MediaPlayer;
class SharedBuffer;

using CreateCDM = Function<const std::unique_ptr<CDMPrivateInterface>(LegacyCDM&)>;
using CDMSupportsKeySystem = Function<bool(const String&)>;
using CDMSupportsKeySystemAndMimeType = Function<bool(const String&, const String&)>;

class LegacyCDMClient : public CanMakeCheckedPtr<LegacyCDMClient> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(LegacyCDMClient);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(LegacyCDMClient);
public:
    virtual ~LegacyCDMClient() = default;

    virtual RefPtr<MediaPlayer> cdmMediaPlayer(const LegacyCDM* WTF_NULLABLE) const = 0;
};

class WEBCORE_EXPORT LegacyCDM final : public RefCountedAndCanMakeWeakPtr<LegacyCDM> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(LegacyCDM, WEBCORE_EXPORT);
public:
    enum CDMErrorCode { NoError, UnknownError, ClientError, ServiceError, OutputError, HardwareChangeError, DomainError };
    static bool supportsKeySystem(const String&);
    static bool keySystemSupportsMimeType(const String& keySystem, const String& mimeType);
    static RefPtr<LegacyCDM> create(const String& keySystem);
    static void registerCDMFactory(CreateCDM&&, CDMSupportsKeySystem&&, CDMSupportsKeySystemAndMimeType&&);
    ~LegacyCDM();

    static void resetFactories();
    static void clearFactories();

    bool supportsMIMEType(const String&) const;
    RefPtr<LegacyCDMSession> createSession(LegacyCDMSessionClient&);

    const String& keySystem() const LIFETIME_BOUND { return m_keySystem; }

    LegacyCDMClient* WTF_NULLABLE client() const { return m_client.get(); }
    void setClient(LegacyCDMClient* WTF_NULLABLE client) { m_client = client; }

    RefPtr<MediaPlayer> mediaPlayer() const;
    CDMPrivateInterface* WTF_NULLABLE cdmPrivate() const { return m_private.get(); }

private:
    explicit LegacyCDM(const String& keySystem);

    String m_keySystem;
    CheckedPtr<LegacyCDMClient> m_client;
    const std::unique_ptr<CDMPrivateInterface> m_private;
};

#if PLATFORM(COCOA)

using RefPtrLegacyCDMMediaPlayer = RefPtr<MediaPlayer>;

// A legacy CDM whose client is a Swift LegacyCDMClientDelegate, which CDMSupportedConfiguration.swift gives it. Each
// call is on the main thread.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/CDMSupportedConfiguration.swift") LegacyCDMClientSwiftAdapter final : public RefCounted<LegacyCDMClientSwiftAdapter>, public LegacyCDMClient {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(LegacyCDMClientSwiftAdapter);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(LegacyCDMClientSwiftAdapter);
public:
    // Null if no legacy CDM supports the key system. Takes over `delegateBox`, a retained Swift delegate box, either way.
    SWIFT_UNSAFE static LegacyCDMClientSwiftAdapter* WTF_NULLABLE create(const String& keySystem, uintptr_t delegateBox) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT ~LegacyCDMClientSwiftAdapter();
    void ref() const { RefCounted::ref(); }
    void deref() const { RefCounted::deref(); }

    LegacyCDM& cdm() const { return m_cdm; }
    bool supportsMIMEType(const String& mimeType) const { return m_cdm->supportsMIMEType(mimeType); }

private:
    LegacyCDMClientSwiftAdapter(Ref<LegacyCDM>&&, uintptr_t delegateBox);

    RefPtr<MediaPlayer> cdmMediaPlayer(const LegacyCDM* WTF_NULLABLE) const final;

    SWIFT_MAIN_ACTOR RefPtrLegacyCDMMediaPlayer delegateMediaPlayer() const;
    SWIFT_UNSAFE static void releaseDelegateBox(uintptr_t);

    const Ref<LegacyCDM> m_cdm;
    const uintptr_t m_delegateBox;
};

// A legacy CDM session whose client is a Swift LegacyCDMSessionClientDelegate, which CDMSupportedConfiguration.swift
// gives it. Its operations take and give buffers in place of the session's JavaScriptCore typed arrays. Each call is on
// the main thread.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/CDMSupportedConfiguration.swift") LegacyCDMSessionClientSwiftAdapter final : public LegacyCDMSessionClient, public RefCounted<LegacyCDMSessionClientSwiftAdapter> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(LegacyCDMSessionClientSwiftAdapter, WEBCORE_EXPORT);
public:
    // Takes over `delegateBox`, a retained Swift delegate box.
    SWIFT_UNSAFE static LegacyCDMSessionClientSwiftAdapter* WTF_NONNULL create(LegacyCDMClientSwiftAdapter&, const Logger&, uint64_t logIdentifier, uintptr_t delegateBox) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT ~LegacyCDMSessionClientSwiftAdapter();
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    // Null if the CDM made none.
    LegacyCDMSession* WTF_NULLABLE session() const { return m_session.get(); }

    WEBCORE_EXPORT SharedBuffer* WTF_NULLABLE generateKeyRequest(const String& mimeType, SharedBuffer* WTF_NULLABLE initData, const String& mediaKeysHashSalt, String& destinationURL, uint16_t& errorCode, uint32_t& systemCode) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT void releaseKeys();
    WEBCORE_EXPORT SharedBuffer* WTF_NULLABLE update(SharedBuffer* WTF_NULLABLE, bool& succeeded, uint16_t& errorCode, uint32_t& systemCode) SWIFT_RETURNS_RETAINED;
    WEBCORE_EXPORT SharedBuffer* WTF_NULLABLE cachedKeyForKeyID(const String&) const SWIFT_RETURNS_RETAINED;

private:
    LegacyCDMSessionClientSwiftAdapter(LegacyCDM&, const Logger&, uint64_t logIdentifier, uintptr_t delegateBox);

    void sendMessage(Uint8Array* WTF_NULLABLE, String destinationURL) final;
    void sendError(MediaKeyErrorCode errorCode, uint32_t systemCode) final { delegateSendError(errorCode, systemCode); }
    String mediaKeysStorageDirectory() const final { return delegateMediaKeysStorageDirectory(); }
    String mediaKeysHashSalt() const final { return m_mediaKeysHashSalt; }
#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
#endif

    SWIFT_MAIN_ACTOR void delegateSendMessage(SharedBuffer* WTF_NULLABLE, String destinationURL);
    SWIFT_MAIN_ACTOR void delegateSendError(uint16_t errorCode, uint32_t systemCode);
    SWIFT_MAIN_ACTOR String delegateMediaKeysStorageDirectory() const;
    SWIFT_UNSAFE static void releaseDelegateBox(uintptr_t);

    const uintptr_t m_delegateBox;
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
    const RefPtr<LegacyCDMSession> m_session;
    String m_mediaKeysHashSalt;
};

#endif // PLATFORM(COCOA)

}

IGNORE_CLANG_WARNINGS_END

#endif // ENABLE(LEGACY_ENCRYPTED_MEDIA)
