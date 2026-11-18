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

#pragma once

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)

#include <CoreVideo/CVBuffer.h>
#include <WebCore/PlatformMediaCapabilitiesDecodingInfo.h>
#include <WebCore/PlatformMediaCapabilitiesEncodingInfo.h>
#include <WebCore/PlatformMediaDecodingConfiguration.h>
#include <WebCore/PlatformMediaEncodingConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WeakPtr.h>

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#include <WebCore/CDMInstance.h>
#include <WebCore/CDMPrivate.h>
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
#include <WebCore/LegacyCDM.h>
#include <WebCore/LegacyCDMSession.h>
#endif
#if HAVE(AVASSETREADER)
#include "SharedBufferReference.h"
#include "SwiftCoding.h"
#include <WebCore/ImageDecoderAVFObjC.h>
#include <WebCore/ShareableBitmap.h>
#endif

namespace WebCore {
class MediaPlayer;
class VideoFrame;
}

namespace WebKit {

class GPUConnectionToWebProcess;

// What the GPU process's Swift media receivers need of WebCore's C++ media objects that Swift can't do itself: implement
// WebCore's C++ client interfaces, use JavaScriptCore typed arrays, and make C++ values that have no Swift form.

using RemoteCDMBytes = Vector<uint8_t>;

inline RemoteCDMBytes remoteCDMBufferBytes(const WebCore::SharedBuffer& buffer)
{
    return RemoteCDMBytes { buffer.span() };
}

WebCore::SharedBuffer* WTF_NONNULL makeRemoteCDMBuffer(WTF::SpanUInt8 bytes NOESCAPE) SWIFT_RETURNS_RETAINED;

#if ENABLE(GPU_PROCESS_CDM_SWIFT)

class RemoteCDMPrivateHandle;

// A C++ CDM's instance, which the media players use, as its client, which sends its unrequested initialization data to
// the web process's RemoteCDMInstance.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT RemoteCDMInstanceClient final : public WebCore::CDMInstanceClient, public RefCounted<RemoteCDMInstanceClient> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMInstanceClient);
public:
    RemoteCDMInstanceClient(GPUConnectionToWebProcess&, RemoteCDMPrivateHandle&, Ref<WebCore::CDMInstance>&&, uint64_t identifier);
    ~RemoteCDMInstanceClient();
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    WebCore::CDMInstance& instance() const { return m_instance; }
    String keySystem() const { return m_instance->keySystem(); }

private:
    void unrequestedInitializationDataReceived(const String&, Ref<WebCore::SharedBuffer>&&) final;
#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
#endif

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    WeakPtr<RemoteCDMPrivateHandle> m_cdm;
    const Ref<WebCore::CDMInstance> m_instance;
    const uint64_t m_identifier;
#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
#endif
};

// A C++ CDM, for the instances the media players use.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT RemoteCDMPrivateHandle final : public RefCounted<RemoteCDMPrivateHandle>, public CanMakeWeakPtr<RemoteCDMPrivateHandle>, private WebCore::CDMPrivateClient {
    WTF_MAKE_TZONE_ALLOCATED(RemoteCDMPrivateHandle);
public:
    // Null if no C++ CDM supports the key system.
    static RemoteCDMPrivateHandle* WTF_NULLABLE create(GPUConnectionToWebProcess&, const String& keySystem, const String& mediaKeysHashSalt) SWIFT_RETURNS_RETAINED;
    ~RemoteCDMPrivateHandle();
    void ref() const { RefCounted::ref(); }
    void deref() const { RefCounted::deref(); }

    // Null if the CDM makes none.
    RemoteCDMInstanceClient* WTF_NULLABLE createInstance(uint64_t identifier) SWIFT_RETURNS_RETAINED;
    void loadAndInitialize() { m_private->loadAndInitialize(); }
    void setLogIdentifier(uint64_t);
    uint64_t logIdentifier() const { return m_logIdentifier; }
#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger; }
#endif

private:
    RemoteCDMPrivateHandle(GPUConnectionToWebProcess&, const Logger&);

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    const Ref<const Logger> m_logger;
    std::unique_ptr<WebCore::CDMPrivate> m_private;
    uint64_t m_logIdentifier { 0 };
};

#endif // ENABLE(GPU_PROCESS_CDM_SWIFT)

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)

// A legacy CDM, as its client, which finds the media player that the web process's RemoteLegacyCDM names.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT RemoteLegacyCDMClient final : public RefCounted<RemoteLegacyCDMClient>, public WebCore::LegacyCDMClient {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(RemoteLegacyCDMClient);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RemoteLegacyCDMClient);
public:
    // Null if no legacy CDM supports the key system.
    static RemoteLegacyCDMClient* WTF_NULLABLE create(GPUConnectionToWebProcess&, const String& keySystem) SWIFT_RETURNS_RETAINED;
    ~RemoteLegacyCDMClient();
    void ref() const { RefCounted::ref(); }
    void deref() const { RefCounted::deref(); }

    WebCore::LegacyCDM& cdm() const { return m_cdm; }
    bool supportsMIMEType(const String& mimeType) const { return m_cdm->supportsMIMEType(mimeType); }
    // 0 for none.
    void setPlayerIdentifier(uint64_t identifier) { m_playerIdentifier = identifier; }

private:
    RemoteLegacyCDMClient(GPUConnectionToWebProcess&, Ref<WebCore::LegacyCDM>&&);
    RefPtr<WebCore::MediaPlayer> cdmMediaPlayer(const WebCore::LegacyCDM*) const final;

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    const Ref<WebCore::LegacyCDM> m_cdm;
    uint64_t m_playerIdentifier { 0 };
};

// A legacy CDM's session, as its client, which sends its messages and errors to the web process's RemoteLegacyCDMSession.
// Its operations take and give buffers in place of the session's JavaScriptCore typed arrays.
class SWIFT_SHARED_REFERENCE(.ref, .deref) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT RemoteLegacyCDMSessionClient final : public WebCore::LegacyCDMSessionClient, public RefCounted<RemoteLegacyCDMSessionClient> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteLegacyCDMSessionClient);
public:
    static RemoteLegacyCDMSessionClient* WTF_NONNULL create(GPUConnectionToWebProcess&, RemoteLegacyCDMClient&, uint64_t identifier, uint64_t logIdentifier) SWIFT_RETURNS_RETAINED;
    ~RemoteLegacyCDMSessionClient();
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    // For the media players.
    WebCore::LegacyCDMSession* WTF_NULLABLE session() const { return m_session.get(); }
    // The session no longer reaches the web process.
    void invalidate() { m_connection = nullptr; }

    WebCore::SharedBuffer* WTF_NULLABLE generateKeyRequest(const String& mimeType, WebCore::SharedBuffer* WTF_NULLABLE initData, const String& mediaKeysHashSalt, String& destinationURL, uint16_t& errorCode, uint32_t& systemCode) SWIFT_RETURNS_RETAINED;
    void releaseKeys();
    WebCore::SharedBuffer* WTF_NULLABLE update(WebCore::SharedBuffer* WTF_NULLABLE, bool& succeeded, uint16_t& errorCode, uint32_t& systemCode) SWIFT_RETURNS_RETAINED;
    WebCore::SharedBuffer* WTF_NULLABLE cachedKeyForKeyID(const String&) const SWIFT_RETURNS_RETAINED;

private:
    RemoteLegacyCDMSessionClient(GPUConnectionToWebProcess&, WebCore::LegacyCDM&, uint64_t identifier, uint64_t logIdentifier);

    void sendMessage(Uint8Array*, String destinationURL) final;
    void sendError(MediaKeyErrorCode, uint32_t systemCode) final;
    String mediaKeysStorageDirectory() const final;
    String mediaKeysHashSalt() const final { return m_mediaKeysHashSalt; }
#if !RELEASE_LOG_DISABLED
    const Logger& logger() const final { return m_logger; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
#endif

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    const uint64_t m_identifier;
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
    const RefPtr<WebCore::LegacyCDMSession> m_session;
    String m_mediaKeysHashSalt;
};

#endif // ENABLE(LEGACY_ENCRYPTED_MEDIA)

#if HAVE(AVASSETREADER)

using ImageDecoderAVFStatusCallback = Function<void(WebCore::EncodedDataStatus)>;

// Null if the decoder can't be made.
WebCore::ImageDecoderAVFObjC* WTF_NULLABLE createImageDecoderAVF(IPC::CxxDecodedArgument<IPC::SharedBufferReference>&, const String& mimeType, const GPUConnectionToWebProcess&) SWIFT_RETURNS_RETAINED;
void setImageDecoderAVFData(WebCore::ImageDecoderAVFObjC&, const IPC::SharedBufferReference&, bool allDataReceived);
// The frames' infos, if it has frames.
std::optional<Vector<WebCore::ImageDecoderFrameInfo>> imageDecoderAVFFrameInfos(WebCore::ImageDecoderAVFObjC&);
// A bitmap the frame is drawn into, if it decodes.
std::optional<WebCore::ShareableBitmapHandle> createImageDecoderAVFFrameBitmap(WebCore::ImageDecoderAVFObjC&, uint64_t index);

#endif // HAVE(AVASSETREADER)

#if ENABLE(VIDEO)
using MediaPlayerCallback = Function<void(WebCore::MediaPlayer&)>;
CVBufferRef WTF_NULLABLE videoFramePixelBuffer(const WebCore::VideoFrame&) CF_RETURNS_NOT_RETAINED;
#endif

// Cocoa's media engine configuration factories answer synchronously.
WebCore::PlatformMediaCapabilitiesDecodingInfo createMediaDecodingConfiguration(const WebCore::PlatformMediaDecodingConfiguration&);
WebCore::PlatformMediaCapabilitiesEncodingInfo createMediaEncodingConfiguration(const WebCore::PlatformMediaEncodingConfiguration&);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
