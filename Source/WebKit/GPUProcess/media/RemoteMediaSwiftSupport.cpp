/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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
#include "RemoteMediaSwiftSupport.h"

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)

#include "GPUConnectionToWebProcess.h"
#include "Logging.h"
#include "SharedBufferReference.h"
#include "SwiftCoding.h"
#include <WebCore/PlatformMediaEngineConfigurationFactory.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#include "RemoteCDMInstanceMessages.h"
#include <WebCore/CDMFactory.h>
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
#include "RemoteLegacyCDMSessionMessages.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include <JavaScriptCore/GenericTypedArrayViewInlines.h>
#include <JavaScriptCore/TypedArrayAdaptors.h>
#endif

#if ENABLE(VIDEO)
#include <WebCore/VideoFrame.h>
#endif

#if HAVE(AVASSETREADER)
#include <WebCore/GraphicsContext.h>
#include <WebCore/NativeImage.h>
#endif

namespace WebKit {

using namespace WebCore;

WebCore::SharedBuffer* makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE)
{
    return &SharedBuffer::create(bytes).leakRef();
}

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMInstanceClient);
WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCDMPrivateHandle);

RemoteCDMInstanceClient::RemoteCDMInstanceClient(GPUConnectionToWebProcess& connection, RemoteCDMPrivateHandle& cdm, Ref<CDMInstance>&& instance, uint64_t identifier)
    : m_connection(connection)
    , m_cdm(cdm)
    , m_instance(WTF::move(instance))
    , m_identifier(identifier)
#if !RELEASE_LOG_DISABLED
    , m_logger(cdm.logger())
    , m_logIdentifier(cdm.logIdentifier())
#endif
{
    m_instance->setClient(*this);
}

RemoteCDMInstanceClient::~RemoteCDMInstanceClient()
{
    m_instance->clearClient();
}

void RemoteCDMInstanceClient::unrequestedInitializationDataReceived(const String& type, Ref<SharedBuffer>&& initData)
{
    if (RefPtr connection = m_connection.get(); connection && m_cdm)
        connection->connection().send(Messages::RemoteCDMInstance::UnrequestedInitializationDataReceived(type, WTF::move(initData)), m_identifier);
}

RemoteCDMPrivateHandle* RemoteCDMPrivateHandle::create(GPUConnectionToWebProcess& connection, const String& keySystem, const String& mediaKeysHashSalt)
{
    auto& factories = CDMFactory::registeredFactories();
    auto index = factories.findIf([&](auto& factory) {
        return factory->supportsKeySystem(keySystem);
    });
    if (index == notFound)
        return nullptr;
    RefPtr factory = factories[index].ptr();
    Ref handle = adoptRef(*new RemoteCDMPrivateHandle(connection, connection.logger()));
    handle->m_private = factory->createCDM(keySystem, mediaKeysHashSalt, handle.get());
    if (!handle->m_private)
        return nullptr;
    return &handle.leakRef();
}

RemoteCDMPrivateHandle::RemoteCDMPrivateHandle(GPUConnectionToWebProcess& connection, const Logger& logger)
    : m_connection(connection)
    , m_logger(logger)
{
}

RemoteCDMPrivateHandle::~RemoteCDMPrivateHandle() = default;

RemoteCDMInstanceClient* RemoteCDMPrivateHandle::createInstance(uint64_t identifier)
{
    RefPtr connection = m_connection.get();
    RefPtr instance = m_private->createInstance();
    if (!connection || !instance)
        return nullptr;
    return &adoptRef(*new RemoteCDMInstanceClient(*connection, *this, instance.releaseNonNull(), identifier)).leakRef();
}

void RemoteCDMPrivateHandle::setLogIdentifier(uint64_t logIdentifier)
{
    m_logIdentifier = logIdentifier;
#if !RELEASE_LOG_DISABLED
    m_private->setLogIdentifier(logIdentifier);
#endif
}

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteLegacyCDMSessionClient);

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

RemoteLegacyCDMClient* RemoteLegacyCDMClient::create(GPUConnectionToWebProcess& connection, const String& keySystem)
{
    RefPtr cdm = LegacyCDM::create(keySystem);
    if (!cdm)
        return nullptr;
    return &adoptRef(*new RemoteLegacyCDMClient(connection, cdm.releaseNonNull())).leakRef();
}

RemoteLegacyCDMClient::RemoteLegacyCDMClient(GPUConnectionToWebProcess& connection, Ref<LegacyCDM>&& cdm)
    : m_connection(connection)
    , m_cdm(WTF::move(cdm))
{
    m_cdm->setClient(this);
}

RemoteLegacyCDMClient::~RemoteLegacyCDMClient()
{
    m_cdm->setClient(nullptr);
}

RefPtr<MediaPlayer> RemoteLegacyCDMClient::cdmMediaPlayer(const LegacyCDM*) const
{
    RefPtr connection = m_connection.get();
    if (!m_playerIdentifier || !connection)
        return nullptr;
    return protect(connection->remoteMediaPlayerManagerProxy())->mediaPlayer(MediaPlayerIdentifier { m_playerIdentifier });
}

RemoteLegacyCDMSessionClient* RemoteLegacyCDMSessionClient::create(GPUConnectionToWebProcess& connection, RemoteLegacyCDMClient& cdm, uint64_t identifier, uint64_t logIdentifier)
{
    return &adoptRef(*new RemoteLegacyCDMSessionClient(connection, cdm.cdm(), identifier, logIdentifier)).leakRef();
}

RemoteLegacyCDMSessionClient::RemoteLegacyCDMSessionClient(GPUConnectionToWebProcess& connection, LegacyCDM& cdm, uint64_t identifier, uint64_t logIdentifier)
    : m_connection(connection)
    , m_identifier(identifier)
    , m_logger(connection.logger())
    , m_logIdentifier(logIdentifier)
    , m_session(cdm.createSession(*this))
{
#if !RELEASE_LOG_DISABLED
    if (!m_session)
        m_logger->error(JOIN_LOG_CHANNEL_WITH_PREFIX(LOG_CHANNEL_PREFIX, EME), Logger::LogSiteIdentifier("RemoteLegacyCDMSessionProxy"_s, __func__, m_logIdentifier), "could not create CDM session."_s);
#endif
}

RemoteLegacyCDMSessionClient::~RemoteLegacyCDMSessionClient() = default;

SharedBuffer* RemoteLegacyCDMSessionClient::generateKeyRequest(const String& mimeType, SharedBuffer* initData, const String& mediaKeysHashSalt, String& destinationURL, uint16_t& errorCode, uint32_t& systemCode)
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

void RemoteLegacyCDMSessionClient::releaseKeys()
{
    if (m_session)
        m_session->releaseKeys();
}

SharedBuffer* RemoteLegacyCDMSessionClient::update(SharedBuffer* update, bool& succeeded, uint16_t& errorCode, uint32_t& systemCode)
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

SharedBuffer* RemoteLegacyCDMSessionClient::cachedKeyForKeyID(const String& keyId) const
{
    return m_session ? convertToSharedBuffer(m_session->cachedKeyForKeyID(keyId)) : nullptr;
}

void RemoteLegacyCDMSessionClient::sendMessage(Uint8Array* message, String destinationURL)
{
    if (RefPtr connection = m_connection.get())
        connection->connection().send(Messages::RemoteLegacyCDMSession::SendMessage(adoptRef(convertToSharedBuffer(message)), destinationURL), m_identifier);
}

void RemoteLegacyCDMSessionClient::sendError(MediaKeyErrorCode errorCode, uint32_t systemCode)
{
    if (RefPtr connection = m_connection.get())
        connection->connection().send(Messages::RemoteLegacyCDMSession::SendError(errorCode, systemCode), m_identifier);
}

String RemoteLegacyCDMSessionClient::mediaKeysStorageDirectory() const
{
    RefPtr connection = m_connection.get();
    return connection ? connection->mediaKeysStorageDirectory() : emptyString();
}

#endif // ENABLE(LEGACY_ENCRYPTED_MEDIA)

#if HAVE(AVASSETREADER)

static Ref<SharedBuffer> sharedBuffer(const IPC::SharedBufferReference& data)
{
    return data.isNull() ? SharedBuffer::create() : SharedBuffer::create(data.span());
}

ImageDecoderAVFObjC* createImageDecoderAVF(IPC::CxxDecodedArgument<IPC::SharedBufferReference>& data, const String& mimeType, const GPUConnectionToWebProcess& connection)
{
    return ImageDecoderAVFObjC::create(sharedBuffer(*data.take()), mimeType, AlphaOption::Premultiplied, GammaAndColorProfileOption::Ignored, connection.webProcessIdentity()).leakRef();
}

void setImageDecoderAVFData(ImageDecoderAVFObjC& decoder, const IPC::SharedBufferReference& data, bool allDataReceived)
{
    decoder.setData(sharedBuffer(data), allDataReceived);
}

std::optional<Vector<ImageDecoderFrameInfo>> imageDecoderAVFFrameInfos(ImageDecoderAVFObjC& decoder)
{
    if (!decoder.frameCount())
        return std::nullopt;
    return decoder.frameInfos();
}

std::optional<ShareableBitmapHandle> createImageDecoderAVFFrameBitmap(ImageDecoderAVFObjC& decoder, uint64_t index)
{
    RefPtr nativeImage = NativeImage::createTransient(decoder.createFrameImageAtIndex(index));
    if (!nativeImage)
        return std::nullopt;
    auto imageSize = nativeImage->size();
    RefPtr bitmap = ShareableBitmap::create({ imageSize, nativeImage->colorSpace(), unspecifiedPixelFormat, nativeImage->headroom(), false });
    if (!bitmap)
        return std::nullopt;
    auto context = bitmap->createGraphicsContext();
    if (!context)
        return std::nullopt;
    FloatRect imageRect { { }, imageSize };
    context->drawNativeImage(*nativeImage, imageRect, imageRect, { CompositeOperator::Copy });
    return bitmap->createHandle();
}

#endif // HAVE(AVASSETREADER)

#if ENABLE(VIDEO)
CVBufferRef videoFramePixelBuffer(const VideoFrame& frame)
{
    return frame.pixelBuffer();
}
#endif

PlatformMediaCapabilitiesDecodingInfo createMediaDecodingConfiguration(const PlatformMediaDecodingConfiguration& configuration)
{
    std::optional<PlatformMediaCapabilitiesDecodingInfo> result;
    PlatformMediaEngineConfigurationFactory::createDecodingConfiguration(PlatformMediaDecodingConfiguration { configuration }, [&result](auto&& info) {
        result = WTF::move(info);
    });
    RELEASE_ASSERT(result);
    return WTF::move(*result);
}

PlatformMediaCapabilitiesEncodingInfo createMediaEncodingConfiguration(const PlatformMediaEncodingConfiguration& configuration)
{
    std::optional<PlatformMediaCapabilitiesEncodingInfo> result;
    PlatformMediaEngineConfigurationFactory::createEncodingConfiguration(PlatformMediaEncodingConfiguration { configuration }, [&result](auto&& info) {
        result = WTF::move(info);
    });
    RELEASE_ASSERT(result);
    return WTF::move(*result);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
