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
#include <VideoToolbox/VTDecompressionSession.h>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/ProcessIdentity.h>
#include <atomic>
#include <wtf/BlockPtr.h>
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
typedef struct __CVBuffer* CVBufferRef;
typedef CVBufferRef CVImageBufferRef;
typedef CVImageBufferRef CVPixelBufferRef;
typedef UInt32 VTDecodeInfoFlags;

namespace WebCore {

class VideoDecoder;
struct PlatformVideoColorSpace;

// Outside the class, which as an imported shared reference has no type descriptor for nested types to name.
enum class DecompressionSessionSoftwareDecoder : uint8_t { Invalidated, Present, Absent };
enum class DecompressionSessionSoftwareStart : uint8_t { Present, Started, Rejected };

class WebCoreDecompressionSession : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<WebCoreDecompressionSession> {
public:
    NODELETE WEBCORE_EXPORT static Ref<WebCoreDecompressionSession> createOpenGL(WorkQueue* = nullptr);
    WEBCORE_EXPORT static Ref<WebCoreDecompressionSession> createRGB(WorkQueue* = nullptr);
    static Ref<WebCoreDecompressionSession> create(NSDictionary *pixelBufferAttributes, WorkQueue* dispatcher = nullptr) { return adoptRef(*new WebCoreDecompressionSession(pixelBufferAttributes, dispatcher)); }

    WEBCORE_EXPORT ~WebCoreDecompressionSession();
    WEBCORE_EXPORT void invalidate();

    WEBCORE_EXPORT RetainPtr<CVPixelBufferRef> decodeSampleSync(CMSampleBufferRef);

    enum class DecodingFlag : uint8_t {
        NonDisplaying = 1 << 0,
        RealTime = 1 << 1,
        EnableStereo = 1 << 2,
        // Fail instead of decoding in software formats the content process can decode.
        HardwareOnly = 1 << 3,
    };
    using DecodingFlags = OptionSet<DecodingFlag>;

    typedef void (^DecodeCompletion)(NSArray *, OSStatus) NS_SWIFT_SENDABLE;
    WEBCORE_EXPORT void decodeSample(CMSampleBufferRef, uint8_t flags, DecodeCompletion);
    WEBCORE_EXPORT void flush();

    void setResourceOwner(const ProcessIdentity& resourceOwner) { m_resourceOwner = resourceOwner; }
    bool isHardwareAccelerated() const;
    SWIFT_UNSAFE static void destroySwiftCore(uint64_t);
    SWIFT_UNSAFE static void markInvalidatedSwift(uint64_t);
    SWIFT_UNSAFE static bool isInvalidatedSwift(uint64_t);
    [[nodiscard]] SWIFT_UNSAFE static bool decodedFormatIsFullRange(CMFormatDescriptionRef);
    static bool canDecodeInContentProcess(CMFormatDescriptionRef);
    SWIFT_UNSAFE void decodeOnQueueSwift(CMSampleBufferRef, uint8_t flags);
    [[nodiscard]] SWIFT_UNSAFE CF_RETURNS_NOT_RETAINED CFArrayRef decodeSampleSyncSwift(CMSampleBufferRef);
    DecompressionSessionSoftwareDecoder checkSoftwareDecoder(bool formatChanged);
    bool hasDecoder() const { Locker lock { m_lock }; return !!m_videoDecoder; }
    DecompressionSessionSoftwareStart startSoftwareDecoder(CMSampleBufferRef, uint8_t flags, DecodeCompletion);
    SWIFT_UNSAFE void decode(CMSampleBufferRef, uint8_t flags, DecodeCompletion);
    // Returns the completion decodeOnQueue() holds for its call into Swift.
    SWIFT_UNSAFE DecodeCompletion resetDecodeResults(size_t numberOfSamples)
    {
        assertIsCurrent(m_dispatcher.get());
        m_lastDecodingError = noErr;
        m_lastDecodedSamples = { };
        m_lastDecodedSamples.reserveInitialCapacity(numberOfSamples);
        return m_decodeCompletion.get();
    }
    [[nodiscard]] SWIFT_UNSAFE bool decodeAlphaSample(CMSampleBufferRef, CMSampleBufferRef alphaSample, uint8_t flags, bool resetAlpha, DecodeCompletion);
    void flushAlpha();
    void bumpFlushId() { m_flushId++; }
    uint64_t swiftToken() const { return m_swiftToken; }
    bool isDispatcherCurrent() const { return m_dispatcher->isCurrent(); }

private:
    enum class IsAlphaDecoder : uint8_t { No, VideoRange, FullRange };
    WEBCORE_EXPORT WebCoreDecompressionSession(NSDictionary *, WorkQueue*, IsAlphaDecoder = IsAlphaDecoder::No);

    // On m_dispatcher.
    void decodeOnQueue(CMSampleBufferRef sample, uint8_t flags, DecodeCompletion completion) { m_decodeCompletion = makeBlockPtr(completion); decodeOnQueueSwift(sample, flags); m_decodeCompletion = nullptr; }

    void assignResourceOwner(CVImageBufferRef);

    Ref<MediaPromise> initializeVideoDecoder(FourCharCode, std::span<const uint8_t>, const std::optional<PlatformVideoColorSpace>&);
    bool isInvalidated() const { return isInvalidatedSwift(m_swiftToken); }

    static WorkQueue& queueSingleton();
    const Ref<WorkQueue> m_dispatcher;
    const uint64_t m_swiftToken;

    mutable Lock m_lock;

    std::atomic<uint32_t> m_flushId { 0 };
    BlockPtr<void(NSArray *, OSStatus)> m_decodeCompletion; // Set and cleared on m_dispatcher around decodeOnQueue()'s one call into Swift.
    RefPtr<VideoDecoder> m_videoDecoder WTF_GUARDED_BY_LOCK(m_lock);
    struct PendingDecodeData {
        DecodingFlags flags;
    };
    std::optional<PendingDecodeData> m_pendingDecodeData WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());
    Vector<RetainPtr<CMSampleBufferRef>> m_lastDecodedSamples WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get());
    OSStatus m_lastDecodingError WTF_GUARDED_BY_CAPABILITY(m_dispatcher.get()) { noErr };

    // WebM alpha compositing.
    RefPtr<WebCoreDecompressionSession> m_alphaDecompressionSession WTF_GUARDED_BY_LOCK(m_lock);
    RetainPtr<CMFormatDescriptionRef> m_alphaSourceFormatDescription WTF_GUARDED_BY_LOCK(m_lock);
    bool m_alphaDecoderIsFullRange WTF_GUARDED_BY_LOCK(m_lock) { false };

    ProcessIdentity m_resourceOwner;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

}
