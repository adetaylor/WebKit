/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
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

#import "config.h"
#import "WebCoreDecompressionSession.h"

#import "CMUtilities.h"
#import "CVUtilities.h"
#import "FormatDescriptionUtilities.h"
#import "IOSurface.h"
#import "Logging.h"
#import "MediaSampleAVFObjC.h"
#import "MediaSamplesDecoder.h"
#import "PixelBufferConformerCV.h"
#import "SharedBuffer.h"
#import "VideoDecoder.h"
#import "VideoFrame.h"
#import "WebCore-Swift.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CMBufferQueue.h>
#import <CoreMedia/CMFormatDescription.h>
#import <pal/avfoundation/MediaTimeAVFoundation.h>
#import <wtf/BlockPtr.h>
#import <wtf/MainThread.h>
#import <wtf/MediaTime.h>
#import <wtf/NativePromise.h>
#import <wtf/RunLoop.h>
#import <wtf/StringPrintStream.h>
#import <wtf/Vector.h>
#import <wtf/WTFSemaphore.h>
#import <wtf/cf/TypeCastsCF.h>
#import <wtf/cf/VectorCF.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/cocoa/VectorCocoa.h>

#import "CoreVideoSoftLink.h"
#import "VideoToolboxSoftLink.h"
#import <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

Ref<WebCoreDecompressionSession> WebCoreDecompressionSession::createOpenGL(WorkQueue* dispatcher)
{
    return adoptRef(*new WebCoreDecompressionSession(nullptr, dispatcher));
}

Ref<WebCoreDecompressionSession> WebCoreDecompressionSession::createRGB(WorkQueue* dispatcher)
{
    return adoptRef(*new WebCoreDecompressionSession(@{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{ /* empty dictionary */ }
    }, dispatcher));
}

static RetainPtr<CFDataRef> vpcCFromFormatDescription(CMFormatDescriptionRef description)
{
    RetainPtr extensions = PAL::CMFormatDescriptionGetExtensions(description);
    if (!extensions)
        return nullptr;
    RetainPtr atoms = dynamic_cf_cast<CFDictionaryRef>(CFDictionaryGetValue(extensions, PAL::kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
    if (!atoms)
        return nullptr;
    return dynamic_cf_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("vpcC")));
}

WebCoreDecompressionSession::WebCoreDecompressionSession(NSDictionary *pixelBufferAttributes, WorkQueue* dispatcher, IsAlphaDecoder isAlphaDecoder)
    : m_dispatcher(dispatcher ? *dispatcher : queueSingleton())
    , m_swiftToken(createDecompressionSessionCore(pixelBufferAttributes, isAlphaDecoder != IsAlphaDecoder::No, isAlphaDecoder == IsAlphaDecoder::FullRange, VTIsStereoMVHEVCDecodeSupported(), m_dispatcher->dispatchQueue()))
{
}

WebCoreDecompressionSession::~WebCoreDecompressionSession()
{
    destroySwiftCore(m_swiftToken);
}

WorkQueue& WebCoreDecompressionSession::queueSingleton()
{
    static std::once_flag onceKey;
    static LazyNeverDestroyed<Ref<WorkQueue>> workQueue;
    std::call_once(onceKey, [] {
        workQueue.construct(WorkQueue::create("WebCoreDecompressionSession Decompression Queue"_s));
    });
    return workQueue.get();
}

void WebCoreDecompressionSession::invalidate()
{
    markInvalidatedSwift(m_swiftToken);
    RefPtr<WebCoreDecompressionSession> alphaSession;
    {
        Locker lock { m_lock };
        alphaSession = std::exchange(m_alphaDecompressionSession, nullptr);
        m_dispatcher->dispatch([decoder = WTF::move(m_videoDecoder)] {
            if (decoder)
                decoder->close();
        });
    }
    if (alphaSession)
        alphaSession->invalidate();
}

void WebCoreDecompressionSession::assignResourceOwner(CVImageBufferRef imageBuffer)
{
    if (!m_resourceOwner || !imageBuffer || CFGetTypeID(imageBuffer) != CVPixelBufferGetTypeID())
        return;
    if (RetainPtr surface = CVPixelBufferGetIOSurface((CVPixelBufferRef)imageBuffer))
        IOSurface::setOwnershipIdentity(surface.get(), m_resourceOwner);
}

bool WebCoreDecompressionSession::canDecodeInContentProcess(CMFormatDescriptionRef description)
{
    RefPtr info = createVideoInfoFromFormatDescription(description);
    return info && MediaSamplesDecoder::canDecode(*info, { MediaSamplesDecoder::Filter::InProcess, MediaSamplesDecoder::Filter::SoftwareAllowed, MediaSamplesDecoder::Filter::ForceSoftware });
}

DecompressionSessionSoftwareDecoder WebCoreDecompressionSession::checkSoftwareDecoder(bool formatChanged)
{
    Locker lock { m_lock };

    if (isInvalidated())
        return DecompressionSessionSoftwareDecoder::Invalidated;

    if (formatChanged && m_videoDecoder)
        std::exchange(m_videoDecoder, nullptr)->close();

    return m_videoDecoder ? DecompressionSessionSoftwareDecoder::Present : DecompressionSessionSoftwareDecoder::Absent;
}

#if PLATFORM(VISION)
static RetainPtr<CFDictionaryRef> cfDictionaryCreateCombined(CFDictionaryRef a, CFDictionaryRef b)
{
    ASSERT(a && b);
    RetainPtr result = adoptCF(CFDictionaryCreateMutable(NULL, CFDictionaryGetCount(a) + CFDictionaryGetCount(b), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

    auto copyKeyValue = [](CFTypeRef key, CFTypeRef value, void* context) {
        CFMutableDictionaryRef dict = static_cast<CFMutableDictionaryRef>(context);
        CFDictionarySetValue(dict, key, value);
    };
    CFDictionaryApplyFunction(a, copyKeyValue, result.get());
    CFDictionaryApplyFunction(b, copyKeyValue, result.get());

    return result;
}

NODELETE static RetainPtr<CMFormatDescriptionRef> copyDescriptionExtensionValuesIfNeeded(RetainPtr<CMFormatDescriptionRef>&& description, const CMVideoFormatDescriptionRef originalDescription, const CMTaggedBufferGroupRef group)
{
    RetainPtr metadata = extractImmersiveVideoMetadata(originalDescription);

    if (!metadata || !CFDictionaryGetCount(metadata.get()))
        return description;

    RetainPtr copyExtensions = metadata;
    if (RetainPtr extensions = PAL::CMFormatDescriptionGetExtensions(description.get()))
        copyExtensions = cfDictionaryCreateCombined(extensions.get(), metadata.get());

    if (group) {
        CMVideoFormatDescriptionRef newTaggedGroupDescription;
        if (auto status = PAL::CMTaggedBufferGroupFormatDescriptionCreateForTaggedBufferGroupWithExtensions(kCFAllocatorDefault, group, copyExtensions.get(), &newTaggedGroupDescription); status != noErr)
            return description;
        return adoptCF(newTaggedGroupDescription);
    }
    auto codecType = PAL::CMFormatDescriptionGetMediaSubType(description.get());
    auto dimensions = PAL::CMVideoFormatDescriptionGetDimensions(description.get());

    CMVideoFormatDescriptionRef newImageDescription;
    if (auto status = PAL::CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codecType, dimensions.width, dimensions.height, copyExtensions.get(), &newImageDescription); status != noErr)
        return description;
    return adoptCF(newImageDescription);
}
#endif

static std::expected<RetainPtr<CMSampleBufferRef>, OSStatus> handleDecompressionOutput(WebCoreDecompressionSession::DecodingFlags flags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration)
{
    if (flags.contains(WebCoreDecompressionSession::DecodingFlag::NonDisplaying) || !imageBuffer)
        return { };

    CMVideoFormatDescriptionRef rawImageBufferDescription = nullptr;
    if (auto status = PAL::CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &rawImageBufferDescription); status != noErr)
        return makeUnexpected(status);
#if PLATFORM(VISION)
    RetainPtr imageBufferDescription = copyDescriptionExtensionValuesIfNeeded(adoptCF(rawImageBufferDescription), nullptr, nullptr);
#else
    RetainPtr imageBufferDescription = adoptCF(rawImageBufferDescription);
#endif
    ASSERT(PAL::CMFormatDescriptionGetMediaType(imageBufferDescription.get()) == kCMMediaType_Video);
    CMSampleTimingInfo imageBufferTiming {
        presentationDuration,
        presentationTimeStamp,
        presentationTimeStamp,
    };

    CMSampleBufferRef rawImageSampleBuffer = nullptr;
    if (auto status = PAL::CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, imageBuffer, imageBufferDescription.get(), &imageBufferTiming, &rawImageSampleBuffer); status != noErr)
        return makeUnexpected(status);

    return adoptCF(rawImageSampleBuffer);
}

void WebCoreDecompressionSession::decodeSample(CMSampleBufferRef sample, uint8_t flags, DecodeCompletion completion)
{
    auto deliver = makeBlockPtr([dispatcher = m_dispatcher, completion = makeBlockPtr(completion)](NSArray *frames, OSStatus status) {
        RetainPtr delivered = adoptNS([frames mutableCopy]);
        [delivered removeObjectIdenticalTo:NSNull.null];
        dispatcher->dispatch([completion, frames = WTF::move(delivered), status] {
            completion(frames.get(), status);
        });
    });
    m_dispatcher->dispatch([protectedThis = RefPtr { this }, deliver, sample = RetainPtr { sample }, flags, flushId = m_flushId.load()] mutable {
        if (flushId != protectedThis->m_flushId) {
            deliver(nil, noErr);
            return;
        }
        protectedThis->decodeOnQueue(sample.get(), flags, deliver.get());
    });
}

auto WebCoreDecompressionSession::startSoftwareDecoder(CMSampleBufferRef sample, uint8_t flags, DecodeCompletion completion) -> DecompressionSessionSoftwareStart
{
    RefPtr<MediaPromise> initPromise;

    {
        Locker lock { m_lock };
        if (!m_videoDecoder) {
            if (isInvalidated())
                return DecompressionSessionSoftwareStart::Rejected;
            RetainPtr videoFormatDescription = PAL::CMSampleBufferGetFormatDescription(sample);
            auto fourCC = PAL::CMFormatDescriptionGetMediaSubType(videoFormatDescription.get());

            // We should only hit this code path for VP8 and SW VP9 decoder, look for the vpcC path.
            RetainPtr configurationRecord = vpcCFromFormatDescription(videoFormatDescription);
            if (!configurationRecord)
                return DecompressionSessionSoftwareStart::Rejected;

            auto colorSpace = colorSpaceFromFormatDescription(videoFormatDescription.get());

            initPromise = initializeVideoDecoder(fourCC, span(configurationRecord.get()), colorSpace);
        }
    }
    if (initPromise) {
        initPromise->whenSettled(m_dispatcher, [protectedThis = Ref { *this }, sample = RetainPtr { sample }, flags, completion = makeBlockPtr(completion)](auto&& result) {
            if (!result) {
                completion(nil, kVTVideoDecoderNotAvailableNowErr);
                return;
            }
            protectedThis->decode(sample.get(), flags, completion.get());
        });
        return DecompressionSessionSoftwareStart::Started;
    }
    return DecompressionSessionSoftwareStart::Present;
}

void WebCoreDecompressionSession::decode(CMSampleBufferRef cmSamples, uint8_t flags, DecodeCompletion completion)
{
    if (auto rejected = [&] -> std::optional<OSStatus> {
        Locker lock { m_lock };
        RefPtr videoDecoder = m_videoDecoder;
        if (!videoDecoder)
            return 0;

        assertIsCurrent(m_dispatcher.get());

        m_pendingDecodeData = { DecodingFlags::fromRaw(flags) };
        MediaTime totalDuration = PAL::toMediaTime(PAL::CMSampleBufferGetDuration(cmSamples));

        Vector<Ref<VideoDecoder::DecodePromise>> promises;
        for (Ref sample : MediaSampleAVFObjC::create(cmSamples, 0)->divide()) {
            RetainPtr cmSample = sample->platformSample().cmSampleBuffer();
            MediaTime presentationTimestamp = PAL::toMediaTime(PAL::CMSampleBufferGetPresentationTimeStamp(cmSample.get()));
            RetainPtr rawBuffer = PAL::CMSampleBufferGetDataBuffer(cmSample.get());
            ASSERT(rawBuffer);
            Ref data = sharedBufferFromCMBlockBuffer(rawBuffer.get());
            if (data->isEmpty())
                return kVTAllocationFailedErr;
            promises.append(videoDecoder->decode({ WTF::move(data), true, presentationTimestamp.toMicroseconds(), 0 }));
        }
        VideoDecoder::DecodePromise::all(promises)->whenSettled(m_dispatcher, [weakThis = ThreadSafeWeakPtr { *this }, totalDuration = PAL::toCMTime(totalDuration), completion = makeBlockPtr(completion)](auto&& result) {
            auto protectedThis = weakThis.get();
            if (!protectedThis || protectedThis->isInvalidated()) {
                completion(nil, 0);
                return;
            }
            assertIsCurrent(protectedThis->m_dispatcher.get());
            if (protectedThis->m_lastDecodingError)
                completion(nil, protectedThis->m_lastDecodingError);
            else if (!result)
                completion(nil, kVTVideoDecoderBadDataErr);
            else
                completion(createNSArray(std::exchange(protectedThis->m_lastDecodedSamples, { }), [](auto&& sample) -> id {
                    return sample ? (__bridge id)sample.get() : NSNull.null;
                }).get(), noErr);
            if (!protectedThis->m_pendingDecodeData)
                return;
            protectedThis->m_pendingDecodeData.reset();
        });
        return std::nullopt;
    }())
        completion(nil, *rejected);
}

bool WebCoreDecompressionSession::decodeAlphaSample(CMSampleBufferRef sample, CMSampleBufferRef alphaSample, uint8_t flags, bool resetAlpha, DecodeCompletion completion)
{
    RefPtr<WebCoreDecompressionSession> alphaSession;
    RefPtr<WebCoreDecompressionSession> staleAlphaSession;
    {
        Locker lock { m_lock };
        if (resetAlpha)
            m_alphaDecompressionSession = nullptr;
        if (!isInvalidated()) {
            RetainPtr formatDescription = PAL::CMSampleBufferGetFormatDescription(sample);
            if (!m_alphaSourceFormatDescription || !PAL::CMFormatDescriptionEqual(formatDescription, m_alphaSourceFormatDescription)) {
                bool isFullRange = decodedFormatIsFullRange(formatDescription.get());
                if (m_alphaDecompressionSession && isFullRange != m_alphaDecoderIsFullRange)
                    staleAlphaSession = std::exchange(m_alphaDecompressionSession, nullptr);
                m_alphaDecoderIsFullRange = isFullRange;
                m_alphaSourceFormatDescription = WTF::move(formatDescription);
            }
            if (!m_alphaDecompressionSession)
                m_alphaDecompressionSession = adoptRef(*new WebCoreDecompressionSession(nullptr, m_dispatcher.ptr(), m_alphaDecoderIsFullRange ? IsAlphaDecoder::FullRange : IsAlphaDecoder::VideoRange));
        }
        alphaSession = m_alphaDecompressionSession;
    }
    if (staleAlphaSession) {
        RELEASE_LOG_INFO(Media, "WebM alpha: stream range changed, recreating the alpha decoder");
        staleAlphaSession->invalidate();
    }
    if (!alphaSession)
        return false;

    ASSERT(!compressedAlphaData(alphaSample));

    alphaSession->decodeOnQueue(alphaSample, flags, completion);
    return true;
}

RetainPtr<CVPixelBufferRef> WebCoreDecompressionSession::decodeSampleSync(CMSampleBufferRef sample)
{
    RetainPtr<CVPixelBufferRef> pixelBuffer;
    @autoreleasepool {
        if (CFArrayRef outputs = decodeSampleSyncSwift(sample)) {
            for (CFIndex i = 0; i < CFArrayGetCount(outputs); ++i) {
                if (RetainPtr buffer = dynamic_cf_cast<CVPixelBufferRef>(CFArrayGetValueAtIndex(outputs, i))) {
                    assignResourceOwner(buffer.get());
                    pixelBuffer = WTF::move(buffer);
                }
            }
        }
    }
    return pixelBuffer;
}

void WebCoreDecompressionSession::flushAlpha()
{
    RefPtr<WebCoreDecompressionSession> alphaSession;
    {
        Locker lock { m_lock };
        alphaSession = m_alphaDecompressionSession;
    }
    if (alphaSession)
        alphaSession->flush();
}

Ref<MediaPromise> WebCoreDecompressionSession::initializeVideoDecoder(FourCharCode codec, std::span<const uint8_t> description, const std::optional<PlatformVideoColorSpace>& colorSpace)
{
    VideoDecoder::Config config {
        .description = description,
        .colorSpace = colorSpace,
        .decoding = VideoDecoder::HardwareAcceleration::Yes,
        .pixelBuffer = VideoDecoder::HardwareBuffer::Yes
    };
    MediaPromise::Producer producer;
    auto promise = producer.promise();

    VideoDecoder::create(VideoDecoder::fourCCToCodecString(codec), config, [weakThis = ThreadSafeWeakPtr { *this }, workQueue = Ref { m_dispatcher }] (auto&& result) {
        workQueue->dispatch([weakThis, result = WTF::move(result)] () {
            if (RefPtr protectedThis = weakThis.get()) {
                assertIsCurrent(protectedThis->m_dispatcher.get());
                if (protectedThis->isInvalidated() || !protectedThis->m_pendingDecodeData)
                    return;

                if (!result) {
                    protectedThis->m_lastDecodingError = -1;
                    return;
                }
                if (protectedThis->m_lastDecodingError)
                    return;

                auto presentationTime = PAL::toCMTime(MediaTime(result->timestamp, 1000000));
                auto presentationDuration = PAL::toCMTime(MediaTime(result->duration.value_or(0), 1000000));
                auto sampleResult = handleDecompressionOutput(protectedThis->m_pendingDecodeData->flags, protect(protect(result->frame)->pixelBuffer()), presentationTime, presentationDuration);
                if (!sampleResult)
                    protectedThis->m_lastDecodingError = sampleResult.error();
                else
                    protectedThis->m_lastDecodedSamples.append(WTF::move(*sampleResult));
            }
        });
    })->whenSettled(m_dispatcher, [protectedThis = Ref { *this }, this, producer = WTF::move(producer)] (auto&& result) mutable {
        assertIsCurrent(m_dispatcher.get());
        if (!result || isInvalidated()) {
            producer.reject(PlatformMediaError::DecoderCreationError);
            return;
        }
        Locker lock { m_lock };
        m_videoDecoder = WTF::move(*result);
        producer.resolve();
    });

    return promise;
}

} // namespace WebCore
