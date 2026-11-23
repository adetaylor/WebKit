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

#include <CoreMedia/CMFormatDescription.h>
#include <CoreMedia/CMTime.h>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/ProcessIdentity.h>
#include <atomic>
#include <wtf/Function.h>
#include <wtf/Lock.h>
#include <wtf/MediaTime.h>
#include <wtf/OSObjectPtr.h>
#include <wtf/OptionSet.h>
#include <wtf/Ref.h>
#include <wtf/RetainPtr.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/WorkQueue.h>

typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer *CVPixelBufferRef;
typedef struct __CVBuffer *CVImageBufferRef;
typedef struct __CVPixelBufferPool *CVPixelBufferPoolRef;
typedef struct OpaqueCMTaggedBufferGroup *CMTaggedBufferGroupRef;
typedef UInt32 VTDecodeInfoFlags;
typedef struct OpaqueVTDecompressionSession*  VTDecompressionSessionRef;

namespace WebCore {

class VideoDecoder;
class VideoDecoderVTBSession;
struct PlatformVideoColorSpace;

class SWIFT_PRIVATE_FILEID("WebCore/WebCoreDecompressionSession.swift") WebCoreDecompressionSession : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<WebCoreDecompressionSession> {
public:
    NODELETE WEBCORE_EXPORT static Ref<WebCoreDecompressionSession> createOpenGL(GuaranteedSerialFunctionDispatcher* = nullptr);
    WEBCORE_EXPORT static Ref<WebCoreDecompressionSession> createRGB(GuaranteedSerialFunctionDispatcher* = nullptr);
    static Ref<WebCoreDecompressionSession> create(NSDictionary *pixelBufferAttributes, GuaranteedSerialFunctionDispatcher* dispatcher = nullptr) { return adoptRef(*new WebCoreDecompressionSession(pixelBufferAttributes, dispatcher)); }

    WEBCORE_EXPORT ~WebCoreDecompressionSession();
    WEBCORE_EXPORT void invalidate();

    WEBCORE_EXPORT RetainPtr<CVPixelBufferRef> decodeSampleSync(CMSampleBufferRef);

    using DecodingPromise = NativePromise<Vector<RetainPtr<CMSampleBufferRef>>, OSStatus>;
    enum class DecodingFlag : uint8_t {
        NonDisplaying = 1 << 0,
        RealTime = 1 << 1,
        EnableStereo = 1 << 2,
        // Fail instead of decoding in software formats the content process can decode.
        HardwareOnly = 1 << 3,
    };
    using DecodingFlags = OptionSet<DecodingFlag>;

    WEBCORE_EXPORT Ref<DecodingPromise> decodeSample(CMSampleBufferRef, DecodingFlags);
    WEBCORE_EXPORT void flush();

    void setResourceOwner(const ProcessIdentity& resourceOwner) { m_resourceOwner = resourceOwner; }
    bool isHardwareAccelerated() const;

private:
    enum class IsAlphaDecoder : bool { No, Yes };
    WEBCORE_EXPORT WebCoreDecompressionSession(NSDictionary *, GuaranteedSerialFunctionDispatcher*, IsAlphaDecoder = IsAlphaDecoder::No);
    static NSDictionary *defaultPixelBufferAttributes();

    SWIFT_UNSAFE std::expected<RefPtr<VideoDecoderVTBSession>, OSStatus> ensureDecoderForSample(CMSampleBufferRef, DecodingFlags);

    SWIFT_UNSAFE Ref<DecodingPromise> decodeSampleInternal(CMSampleBufferRef, DecodingFlags);
    SWIFT_UNSAFE Ref<DecodingPromise> decodeSampleWithAlpha(CMSampleBufferRef, CFArrayRef alphaDatas, DecodingFlags);
    SWIFT_UNSAFE std::expected<Vector<RetainPtr<CMSampleBufferRef>>, OSStatus> compositeAlphaOntoColorFrames(Vector<RetainPtr<CMSampleBufferRef>>&&, const Vector<RetainPtr<CVPixelBufferRef>>& alphaPixelBuffers);
    SWIFT_UNSAFE void assignResourceOwner(CVImageBufferRef);

    SWIFT_UNSAFE Ref<MediaPromise> initializeVideoDecoder(FourCharCode, std::span<const uint8_t>, const std::optional<PlatformVideoColorSpace>&);
    bool isInvalidated() const { return m_invalidated; }

    SWIFT_UNSAFE const RetainPtr<NSDictionary> m_pixelBufferAttributes;
    SWIFT_UNSAFE const IsAlphaDecoder m_isAlphaDecoder;
    static WorkQueue& queueSingleton();
    SWIFT_UNSAFE const Ref<GuaranteedSerialFunctionDispatcher> m_dispatcher;

    SWIFT_UNSAFE mutable Lock m_lock;
    SWIFT_UNSAFE RefPtr<VideoDecoderVTBSession> m_videoDecoderVTB WTF_GUARDED_BY_LOCK(m_lock);
    mutable std::optional<bool> m_isHardwareAccelerated WTF_GUARDED_BY_LOCK(m_lock);

    std::atomic<uint32_t> m_flushId { 0 };
    SWIFT_UNSAFE RefPtr<VideoDecoder> m_videoDecoder WTF_GUARDED_BY_LOCK(m_lock);
    bool m_videoDecoderCreationFailed { false };
    struct PendingDecodeData {
        DecodingFlags flags;
    };
    std::optional<PendingDecodeData> m_pendingDecodeData WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());
    SWIFT_UNSAFE Vector<RetainPtr<CMSampleBufferRef>> m_lastDecodedSamples WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());
    SWIFT_UNSAFE RetainPtr<CMFormatDescriptionRef> m_lastFormatDescription WTF_GUARDED_BY_LOCK(m_lock);
    OSStatus m_lastDecodingError WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get()) { noErr };
    // Only ever accessed from a single thread per instance: either m_dispatcher
    // (MSE path, where flush() dispatches its write to serialize with
    // ensureDecoderForSample()), or the caller thread of decodeSampleSync()
    // (ImageDecoderAVFObjC path, which never calls flush()). Not annotated
    // with a capability guard because the owning thread differs per instance.
    bool m_waitingForKeyframe { true };
    SWIFT_UNSAFE RetainPtr<CMFormatDescriptionRef> m_currentImageDescription WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());

    // WebM alpha compositing.
    SWIFT_UNSAFE RefPtr<WebCoreDecompressionSession> m_alphaDecompressionSession WTF_GUARDED_BY_LOCK(m_lock);
    SWIFT_UNSAFE RetainPtr<CMFormatDescriptionRef> m_alphaSourceFormatDescription WTF_GUARDED_BY_LOCK(m_lock);
    bool m_alphaDecoderIsFullRange WTF_GUARDED_BY_LOCK(m_lock) { false };
    SWIFT_UNSAFE RetainPtr<CVPixelBufferPoolRef> m_mergedPixelBufferPool WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());
    SWIFT_UNSAFE RetainPtr<CMFormatDescriptionRef> m_mergedFormatDescription WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());
    SWIFT_UNSAFE RetainPtr<CMFormatDescriptionRef> m_mergedSourceFormatDescription WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());

    // Stereo playback support
    SWIFT_UNSAFE const bool m_stereoSupported { false };
    bool m_stereoConfigured WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get()) { false };
    SWIFT_UNSAFE RetainPtr<CFArrayRef> m_tagCollections WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());

    std::atomic<bool> m_invalidated { false };

    SWIFT_UNSAFE ProcessIdentity m_resourceOwner;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}
