/*
 * Copyright (C) 2013-2024 Apple Inc. All rights reserved.
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

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)

#include "LegacyCDM.h"

#include "LegacyCDMPrivateClearKey.h"
#include "LegacyCDMPrivateMediaPlayer.h"
#include "LegacyCDMSession.h"
#include "Logging.h"
#include "MediaPlayer.h"
#include "SharedBuffer.h"
#include "WebKitMediaKeys.h"
#include <wtf/Borrow.h>
#include <JavaScriptCore/GenericTypedArrayViewInlines.h>
#include <JavaScriptCore/TypedArrayAdaptors.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/WTFString.h>

#if HAVE(AVCONTENTKEYSESSION) && ENABLE(MEDIA_SOURCE)
#include "LegacyCDMPrivateAVFObjC.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CDMPrivateInterface);

struct LegacyCDMFactory {
    CreateCDM constructor;
    CDMSupportsKeySystem supportsKeySystem;
    CDMSupportsKeySystemAndMimeType supportsKeySystemAndMimeType;
};

static void platformRegisterFactories(Vector<LegacyCDMFactory>& factories)
{
    factories.append({ [](LegacyCDM& cdm) { return makeUniqueWithoutRefCountedCheck<LegacyCDMPrivateClearKey>(cdm); }, LegacyCDMPrivateClearKey::supportsKeySystem, LegacyCDMPrivateClearKey::supportsKeySystemAndMimeType });
    // FIXME: initialize specific UA CDMs. http://webkit.org/b/109318, http://webkit.org/b/109320
    factories.append({ [](LegacyCDM& cdm) { return makeUniqueWithoutRefCountedCheck<CDMPrivateMediaPlayer>(cdm); }, CDMPrivateMediaPlayer::supportsKeySystem, CDMPrivateMediaPlayer::supportsKeySystemAndMimeType });
#if HAVE(AVCONTENTKEYSESSION) && ENABLE(MEDIA_SOURCE)
    factories.append({ [](LegacyCDM& cdm) { return makeUniqueWithoutRefCountedCheck<LegacyCDMPrivateAVFObjC>(cdm); }, LegacyCDMPrivateAVFObjC::supportsKeySystem, LegacyCDMPrivateAVFObjC::supportsKeySystemAndMimeType });
#endif
}

static Vector<LegacyCDMFactory>& installedCDMFactories()
{
    static NeverDestroyed<Vector<LegacyCDMFactory>> cdms;
    static std::once_flag registerDefaults;
    std::call_once(registerDefaults, [&] {
        platformRegisterFactories(cdms);
    });
    return cdms;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(LegacyCDM);

void LegacyCDM::resetFactories()
{
    clearFactories();
    platformRegisterFactories(installedCDMFactories());
}

void LegacyCDM::clearFactories()
{
    installedCDMFactories().clear();
}

void LegacyCDM::registerCDMFactory(CreateCDM&& constructor, CDMSupportsKeySystem&& supportsKeySystem, CDMSupportsKeySystemAndMimeType&& supportsKeySystemAndMimeType)
{
    installedCDMFactories().append({ WTF::move(constructor), WTF::move(supportsKeySystem), WTF::move(supportsKeySystemAndMimeType) });
}

static LegacyCDMFactory* CDMFactoryForKeySystem(const String& keySystem)
{
    auto& factories = installedCDMFactories();
    for (size_t i = 0; i < factories.size(); ++i) {
        if (borrow(factories)[i].supportsKeySystem(keySystem))
            return &factories[i];
    }
    return nullptr;
}

bool LegacyCDM::supportsKeySystem(const String& keySystem)
{
    return CDMFactoryForKeySystem(keySystem);
}

bool LegacyCDM::keySystemSupportsMimeType(const String& keySystem, const String& mimeType)
{
    if (LegacyCDMFactory* factory = CDMFactoryForKeySystem(keySystem))
        return factory->supportsKeySystemAndMimeType(keySystem, mimeType);
    return false;
}

RefPtr<LegacyCDM> LegacyCDM::create(const String& keySystem)
{
    if (!supportsKeySystem(keySystem))
        return nullptr;

    return adoptRef(*new LegacyCDM(keySystem));
}

LegacyCDM::LegacyCDM(const String& keySystem)
    : m_keySystem(keySystem)
    , m_private(CDMFactoryForKeySystem(keySystem)->constructor(*this))
{
}

LegacyCDM::~LegacyCDM() = default;

bool LegacyCDM::supportsMIMEType(const String& mimeType) const
{
    return protect(cdmPrivate())->supportsMIMEType(mimeType);
}

RefPtr<LegacyCDMSession> LegacyCDM::createSession(LegacyCDMSessionClient& client)
{
    RefPtr session = protect(cdmPrivate())->createSession(client);
    if (mediaPlayer())
        mediaPlayer()->setCDMSession(session.get());
    return session;
}

RefPtr<MediaPlayer> LegacyCDM::mediaPlayer() const
{
    if (CheckedPtr client = m_client)
        return client->cdmMediaPlayer(this);
    return nullptr;
}


#if PLATFORM(COCOA) && ENABLE(WEBCORE_SWIFT)

WTF_MAKE_TZONE_ALLOCATED_IMPL(LegacyCDMSessionClientSwiftAdapter);

static RefPtr<Uint8Array> convertToUint8Array(SharedBuffer* buffer)
{
    if (!buffer)
        return nullptr;
    auto arrayBuffer = buffer->tryCreateArrayBuffer();
    if (!arrayBuffer)
        return nullptr;
    return Uint8Array::create(arrayBuffer.releaseNonNull(), 0, buffer->size());
}

template<typename T>
static SharedBuffer* convertToSharedBuffer(const T& array)
{
    return array ? &SharedBuffer::create(array->span()).leakRef() : nullptr;
}

LegacyCDMClientSwiftAdapter* LegacyCDMClientSwiftAdapter::create(const String& keySystem, uintptr_t delegateBox)
{
    RefPtr cdm = LegacyCDM::create(keySystem);
    if (!cdm) {
        releaseDelegateBox(delegateBox);
        return nullptr;
    }
    return &adoptRef(*new LegacyCDMClientSwiftAdapter(cdm.releaseNonNull(), delegateBox)).leakRef();
}

LegacyCDMClientSwiftAdapter::LegacyCDMClientSwiftAdapter(Ref<LegacyCDM>&& cdm, uintptr_t delegateBox)
    : m_cdm(WTF::move(cdm))
    , m_delegateBox(delegateBox)
{
    m_cdm->setClient(this);
}

LegacyCDMClientSwiftAdapter::~LegacyCDMClientSwiftAdapter()
{
    m_cdm->setClient(nullptr);
    releaseDelegateBox(m_delegateBox);
}

RefPtr<MediaPlayer> LegacyCDMClientSwiftAdapter::cdmMediaPlayer(const LegacyCDM*) const
{
    return delegateMediaPlayer();
}

LegacyCDMSessionClientSwiftAdapter* LegacyCDMSessionClientSwiftAdapter::create(LegacyCDMClientSwiftAdapter& cdm, const Logger& logger, uint64_t logIdentifier, uintptr_t delegateBox)
{
    return &adoptRef(*new LegacyCDMSessionClientSwiftAdapter(cdm.cdm(), logger, logIdentifier, delegateBox)).leakRef();
}

LegacyCDMSessionClientSwiftAdapter::LegacyCDMSessionClientSwiftAdapter(LegacyCDM& cdm, const Logger& logger, uint64_t logIdentifier, uintptr_t delegateBox)
    : m_delegateBox(delegateBox)
    , m_logger(logger)
    , m_logIdentifier(logIdentifier)
    , m_session(cdm.createSession(*this))
{
#if !RELEASE_LOG_DISABLED
    if (!m_session)
        m_logger->error(LogEME, Logger::LogSiteIdentifier("LegacyCDMSessionClientSwiftAdapter"_s, __func__, m_logIdentifier), "could not create CDM session."_s);
#endif
}

LegacyCDMSessionClientSwiftAdapter::~LegacyCDMSessionClientSwiftAdapter()
{
    releaseDelegateBox(m_delegateBox);
}

SharedBuffer* LegacyCDMSessionClientSwiftAdapter::generateKeyRequest(const String& mimeType, SharedBuffer* initData, const String& mediaKeysHashSalt, String& destinationURL, uint16_t& errorCode, uint32_t& systemCode)
{
    destinationURL = emptyString();
    errorCode = 0;
    systemCode = 0;
    auto initDataArray = m_session ? convertToUint8Array(initData) : nullptr;
    if (!initDataArray)
        return nullptr;
    m_mediaKeysHashSalt = mediaKeysHashSalt;
    destinationURL = { };
    return convertToSharedBuffer(m_session->generateKeyRequest(mimeType, initDataArray.get(), destinationURL, errorCode, systemCode));
}

void LegacyCDMSessionClientSwiftAdapter::releaseKeys()
{
    if (RefPtr session = m_session)
        session->releaseKeys();
}

SharedBuffer* LegacyCDMSessionClientSwiftAdapter::update(SharedBuffer* update, bool& succeeded, uint16_t& errorCode, uint32_t& systemCode)
{
    succeeded = false;
    errorCode = 0;
    systemCode = 0;
    auto updateArray = m_session ? convertToUint8Array(update) : nullptr;
    if (!updateArray)
        return nullptr;
    RefPtr<Uint8Array> nextMessage;
    succeeded = m_session->update(updateArray.get(), nextMessage, errorCode, systemCode);
    return convertToSharedBuffer(nextMessage);
}

SharedBuffer* LegacyCDMSessionClientSwiftAdapter::cachedKeyForKeyID(const String& keyId) const
{
    RefPtr session = m_session;
    return session ? convertToSharedBuffer(session->cachedKeyForKeyID(keyId)) : nullptr;
}

void LegacyCDMSessionClientSwiftAdapter::sendMessage(Uint8Array* message, String destinationURL)
{
    RefPtr buffer = adoptRef(convertToSharedBuffer(message));
    delegateSendMessage(buffer.get(), WTF::move(destinationURL));
}

#endif // PLATFORM(COCOA) && ENABLE(WEBCORE_SWIFT)

}

#endif // ENABLE(LEGACY_ENCRYPTED_MEDIA)
