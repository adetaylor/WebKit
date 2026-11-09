/*
 * Copyright (C) 2023-2024 Apple Inc. All rights reserved.
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
#import "VideoMediaSampleRenderer.h"

#import "EffectiveRateChangedListener.h"
#import "IOSurface.h"
#import "Logging.h"
#import "MediaSampleAVFObjC.h"
#import "VP9UtilitiesCocoa.h"
#import "VideoDecodeWindow.h"
#import "VideoMediaSampleRendererHost.h"
#import "WebCore-Swift.h"
#import "WebCoreDecompressionSession.h"
#import "WebSampleBufferVideoRendering.h"
#import <AVFoundation/AVFoundation.h>
#import <pal/avfoundation/MediaTimeAVFoundation.h>
#import <pal/spi/cocoa/AVFoundationSPI.h>
#import <wtf/Locker.h>
#import <wtf/MonotonicTime.h>
#import <wtf/NativePromise.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cf/TypeCastsCF.h>
#import <wtf/darwin/DispatchExtras.h>
#import <wtf/text/MakeString.h>

#pragma mark - Soft Linking

#import "CoreVideoSoftLink.h"
#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

@interface AVSampleBufferDisplayLayer (WebCoreAVSampleBufferDisplayLayerQueueManagementPrivate)
- (void)expectMinimumUpcomingSampleBufferPresentationTime:(CMTime)minimumUpcomingPresentationTime;
@end

#if HAVE(RECOMMENDED_PIXEL_ATTRIBUTES_API)
@interface AVSampleBufferVideoRenderer (Staging_152246223)
@property (readonly, nonnull) NSDictionary<NSString*, NS_SWIFT_SENDABLE id> *recommendedPixelBufferAttributes;
@end
#endif

namespace WebCore {

struct VideoMediaSampleRenderer::Core {
    typedef VideoMediaSampleRenderer::Core VideoMediaSampleRendererCoreHolder;
    WTF_MAKE_TZONE_ALLOCATED_INLINE(VideoMediaSampleRendererCoreHolder);
public:
    VideoMediaSampleRendererCore swift;
};

// The core's EnqueueAction.
static constexpr uint8_t enqueueToRenderer = 1;

static RetainPtr<CVPixelBufferRef> imageForSample(CMSampleBufferRef sample)
{
    RetainPtr videoFormatDescription = PAL::CMSampleBufferGetFormatDescription(sample);
    if (PAL::CMFormatDescriptionGetMediaType(videoFormatDescription.get()) != kCMMediaType_TaggedBufferGroup)
        return PAL::CMSampleBufferGetImageBuffer(sample);

    RetainPtr group = PAL::CMSampleBufferGetTaggedBufferGroup(sample);
    if (RetainPtr heroEye = dynamic_cf_cast<CFStringRef>(PAL::CMFormatDescriptionGetExtension(videoFormatDescription.get(), PAL::kCMFormatDescriptionExtension_HeroEye))) {
        for (CFIndex index = 0; index < PAL::CMTaggedBufferGroupGetCount(group.get()); ++index) {
            RetainPtr tagCollection = PAL::CMTaggedBufferGroupGetTagCollectionAtIndex(group.get(), index);
            if (PAL::CMTagCollectionContainsTag(tagCollection.get(), heroEye.get() == PAL::kCMFormatDescriptionHeroEye_Left ? PAL::kCMTagStereoLeftEye : PAL::kCMTagStereoRightEye))
                return PAL::CMTaggedBufferGroupGetCVPixelBufferAtIndex(group.get(), index);
        }
    }

    // Hero eye not defined or not found, use the one with LayerID=0
    for (CFIndex index = 0; index < PAL::CMTaggedBufferGroupGetCount(group.get()); ++index) {
        RetainPtr tagCollection = PAL::CMTaggedBufferGroupGetTagCollectionAtIndex(group.get(), index);
        CMTag videoLayerIDTag = PAL::kCMTagInvalid;
        CMItemCount numberOfTagsCopied = 0;
        if (!PAL::CMTagCollectionGetTagsWithCategory(tagCollection.get(), kCMTagCategory_VideoLayerID, &videoLayerIDTag, 1, &numberOfTagsCopied) && numberOfTagsCopied == 1 && !PAL::CMTagGetSInt64Value(videoLayerIDTag))
            return PAL::CMTaggedBufferGroupGetCVPixelBufferAtIndex(group.get(), index);
    }

    // None found.
    return nullptr;
}

static bool isDependedOnByOthers(CMSampleBufferRef sample)
{
    RetainPtr attachments = PAL::CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!attachments)
        return true;

    for (CFIndex index = 0, count = CFArrayGetCount(attachments.get()); index < count; ++index) {
        RetainPtr attachmentDict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments.get(), index);
        if (CFDictionaryGetValue(attachmentDict.get(), PAL::kCMSampleAttachmentKey_IsDependedOnByOthers) == kCFBooleanFalse)
            return false;
    }

    return true;
}

static VideoMediaSampleRendererDecodeWindow decodeWindow()
{
    return {
        PAL::toCMTime(VideoDecodeWindow::lowWaterMark),
        PAL::toCMTime(VideoDecodeWindow::highWaterMark),
        VideoDecodeWindow::sampleQueueHighWaterMark,
        VideoDecodeWindow::sampleQueueLowWaterMark
    };
}

// MediaTime's indefinite time, which PAL::toCMTime() doesn't keep, means an unknown minimum upcoming time.
static CMTime toCMTimeKeepingIndefinite(const MediaTime& time)
{
    auto result = PAL::toCMTime(time);
    if (time.isIndefinite())
        result.flags |= kCMTimeFlags_Indefinite;
    return result;
}

WorkQueue& VideoMediaSampleRenderer::queueSingleton()
{
    static std::once_flag onceKey;
    static LazyNeverDestroyed<Ref<WorkQueue>> workQueue;
    std::call_once(onceKey, [] {
        workQueue.construct(WorkQueue::create("VideoMediaSampleRenderer Queue"_s, WorkQueue::QOS::UserInteractive));
    });
    return workQueue.get();
}

VideoMediaSampleRenderer::VideoMediaSampleRenderer(WebSampleBufferVideoRendering *renderer, const Logger& logger, uint64_t logIdentifier)
    : m_core(makeUnique<Core>(VideoMediaSampleRendererCore::init(VideoMediaSampleRendererHost::create(*this).ptr(), videoRendererFor(renderer), decodeWindow())))
    , m_displayLayer(dynamic_objc_cast<AVSampleBufferDisplayLayer>(renderer))
    , m_listener(WebAVSampleBufferListener::create(*this))
    , m_frameRateMonitor([](auto info) {
        RELEASE_LOG_ERROR(MediaPerformance, "VideoMediaSampleRenderer Frame decoding allowance exceeded:%f expected:%f", Seconds { info.lastFrameTime - info.frameTime }.value(), 1 / info.observedFrameRate);
    })
#if !RELEASE_LOG_DISABLED
    , m_logger(logger)
    , m_logIdentifier(logIdentifier)
#endif
{
    if (!renderer)
        return;

    m_listener->beginObservingVideoRenderer(renderer);

    m_mainRenderer = videoRendererFor(renderer);
    ASSERT(m_mainRenderer);

#if RELEASE_LOG_DISABLED
    UNUSED_PARAM(logger);
    UNUSED_PARAM(logIdentifier);
#endif
}

VideoMediaSampleRenderer::~VideoMediaSampleRenderer()
{
    ALWAYS_LOG(LOGIDENTIFIER);

    if (RetainPtr renderer = this->renderer())
        m_listener->stopObservingVideoRenderer(renderer.get());
    shutdown();
}

AVSampleBufferVideoRenderer *VideoMediaSampleRenderer::videoRendererFor(WebSampleBufferVideoRendering *renderer)
{
    if (!renderer)
        return nullptr;

    if (auto *displayLayer = dynamic_objc_cast<AVSampleBufferDisplayLayer>(renderer))
        return [displayLayer sampleBufferRenderer];
    return checked_objc_cast<AVSampleBufferVideoRenderer>(renderer);
}

Ref<GenericPromise> VideoMediaSampleRenderer::changeRenderer(WebSampleBufferVideoRendering *renderer)
{
    ALWAYS_LOG(LOGIDENTIFIER);

    assertIsMainThread();

    RetainPtr previousRenderer = this->renderer();

    RetainPtr videoRenderer = videoRendererFor(renderer);
    if (std::exchange(m_mainRenderer, videoRenderer) == videoRenderer)
        return GenericPromise::createAndResolve();

    if (previousRenderer)
        m_listener->stopObservingVideoRenderer(previousRenderer.get());
    if (renderer)
        m_listener->beginObservingVideoRenderer(renderer);

    m_displayLayer = dynamic_objc_cast<AVSampleBufferDisplayLayer>(renderer);

    if (!managesDecodedFrames()) {
        if (previousRenderer) {
            [previousRenderer flush];
            [previousRenderer stopRequestingMediaData];
        }
        if (renderer)
            resetReadyForMoreMediaData();
    }

    return invokeAsync(queueSingleton(), [weakThis = ThreadSafeWeakPtr { *this }, renderer = WTF::move(videoRenderer)] {
        if (RefPtr protectedThis = weakThis) {
            assertIsCurrent(queueSingleton());
            protectedThis->m_core->swift.changeRendererOnQueue(renderer.get());
        }
        return GenericPromise::createAndResolve();
    });
}

RefPtr<WebCoreDecompressionSession> VideoMediaSampleRenderer::decompressionSession() const
{
    Locker lock { m_lock };
    return m_decompressionSession;
}

bool VideoMediaSampleRenderer::isUsingDecompressionSession() const
{
    return m_core->swift.isUsingDecompressionSession();
}

bool VideoMediaSampleRenderer::managesDecodedFrames() const
{
    return m_core->swift.managesDecodedFrames();
}

bool VideoMediaSampleRenderer::isReceivingDecodedSamples() const
{
    return m_core->swift.isReceivingDecodedSamples();
}

bool VideoMediaSampleRenderer::isReadyForMoreMediaData() const
{
    assertIsMainThread();

    RetainPtr renderer = this->renderer();
    return m_core->swift.areSamplesQueuesReadyForMoreMediaData() && (!renderer || [renderer isReadyForMoreMediaData]);
}

void VideoMediaSampleRenderer::resolveRequestMediaDataIfNeeded()
{
    assertIsMainThread();

    if (auto producer = std::exchange(m_requestMediaDataProducer, std::nullopt))
        producer->resolve();
}

void VideoMediaSampleRenderer::stopRequestingMediaData()
{
    assertIsMainThread();

    m_requestMediaDataProducer.reset();

    if (managesDecodedFrames()) {
        m_core->swift.stopRequestingMediaData();
        return;
    }
    [protect(renderer()) stopRequestingMediaData];
}

bool VideoMediaSampleRenderer::prefersDecompressionSession() const
{
    assertIsMainThread();

    return m_core->swift.prefersDecompressionSession();
}

void VideoMediaSampleRenderer::setPreferences(Preferences preferences)
{
    assertIsMainThread();

    m_core->swift.setPreferences(preferences.toRaw());
}

void VideoMediaSampleRenderer::setTimebase(RetainPtr<CMTimebaseRef>&& timebase)
{
    if (!timebase)
        return;

    Locker locker { m_lock };

    ASSERT(!m_timebaseAndTimerSource.first);

    OSObjectPtr timerSource = adoptOSObject(dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, protect(queueSingleton().dispatchQueue())));
    dispatch_source_set_event_handler(timerSource.get(), [weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis)
            protectedThis->m_core->swift.purgeDecodedSampleQueue();
    });
    dispatch_activate(timerSource.get());
    PAL::CMTimebaseAddTimerDispatchSource(timebase.get(), timerSource.get());
    m_effectiveRateChangedListener = EffectiveRateChangedListener::create([weakThis = ThreadSafeWeakPtr { *this }](double rate) {
        queueSingleton().dispatch([weakThis, rate] {
            if (RefPtr protectedThis = weakThis; protectedThis && rate)
                protectedThis->m_core->swift.purgeDecodedSampleQueue();
        });
    }, timebase.get());
    m_timebaseAndTimerSource = { WTF::move(timebase), WTF::move(timerSource) };
}

void VideoMediaSampleRenderer::clearTimebase()
{
    Locker locker { m_lock };

    auto [timebase, timerSource] = std::exchange(m_timebaseAndTimerSource, { });
    if (!timebase)
        return;

    PAL::CMTimebaseRemoveTimerDispatchSource(timebase.get(), timerSource.get());
    dispatch_source_cancel(timerSource.get());
    m_effectiveRateChangedListener = nullptr;
}

VideoMediaSampleRenderer::TimebaseAndTimerSource VideoMediaSampleRenderer::timebaseAndTimerSource() const
{
    Locker locker { m_lock };

    return m_timebaseAndTimerSource;
}

RetainPtr<CMTimebaseRef> VideoMediaSampleRenderer::timebase() const
{
    Locker locker { m_lock };

    return m_timebaseAndTimerSource.first;
}

MediaTime VideoMediaSampleRenderer::currentTime() const
{
    if (RetainPtr timebase = this->timebase())
        return PAL::toMediaTime(PAL::CMTimebaseGetTime(timebase.get()));
    return MediaTime::invalidTime();
}

void VideoMediaSampleRenderer::setPurgeTimerFireTime(CMTime fireTime)
{
    auto [timebase, timerSource] = timebaseAndTimerSource();
    if (!timebase)
        return;

    PAL::CMTimebaseSetTimerDispatchSourceNextFireTime(timebase.get(), timerSource.get(), fireTime, 0);
}

void VideoMediaSampleRenderer::cancelTimer()
{
    setPurgeTimerFireTime(PAL::toCMTime(MediaTime::invalidTime()));
}

void VideoMediaSampleRenderer::enqueueSample(const MediaSample& sample, std::optional<MediaTime> minimumUpcomingTime)
{
    assertIsMainThread();
    DEBUG_LOG(LOGIDENTIFIER, "sample: ", sample, " minimumUpcomingTime: ", minimumUpcomingTime.value_or(MediaTime::invalidTime()));

    ASSERT(sample.type() == MediaSample::Type::CMSampleBuffer);
    if (sample.type() != MediaSample::Type::CMSampleBuffer)
        return;

    if (m_needsFlushing) {
        // The client resubmits samples once it has flushed.
        DEBUG_LOG(LOGIDENTIFIER, "Dropping sample, waiting for flush: ", sample);
        return;
    }
    RetainPtr cmSampleBuffer = sample.platformSample().cmSampleBuffer();
    RetainPtr renderer = this->renderer();

    VideoMediaSampleRendererSampleInfo info {
        PAL::toCMTime(sample.presentationTime()),
        PAL::toCMTime(sample.presentationEndTime()),
        sample.isProtected(),
        sample.isNonDisplaying(),
        sample.isSync(),
        !!PAL::CMSampleBufferGetImageBuffer(cmSampleBuffer.get()),
        isDependedOnByOthers(cmSampleBuffer.get())
    };
    auto action = m_core->swift.enqueueSample(cmSampleBuffer.get(), info, !!minimumUpcomingTime, minimumUpcomingTime ? toCMTimeKeepingIndefinite(*minimumUpcomingTime) : PAL::kCMTimeInvalid, !!renderer);
    if (action == enqueueToRenderer)
        [renderer enqueueSampleBuffer:cmSampleBuffer.get()];
}

void VideoMediaSampleRenderer::initializeDecompressionSession()
{
    ALWAYS_LOG(LOGIDENTIFIER);
    assertIsMainThread();

    Locker locker { m_lock };

    ASSERT(!m_decompressionSession);
    if (m_decompressionSession)
        return;

#if HAVE(RECOMMENDED_PIXEL_ATTRIBUTES_API)
    if (m_mainRenderer) {
        if ([m_mainRenderer respondsToSelector:@selector(recommendedPixelBufferAttributes)])
            m_decompressionSession = WebCoreDecompressionSession::create([m_mainRenderer recommendedPixelBufferAttributes], &queueSingleton());
    }
#endif
    if (!m_decompressionSession)
        m_decompressionSession = WebCoreDecompressionSession::createOpenGL(&queueSingleton());
}

void VideoMediaSampleRenderer::decodeSample(CMSampleBufferRef sample, uint8_t decodingFlags, int32_t flushId)
{
    assertIsCurrent(queueSingleton());

    RefPtr decompressionSession = this->decompressionSession();
    if (!decompressionSession) {
        queueSingleton().dispatch([weakThis = ThreadSafeWeakPtr { *this }, flushId] {
            if (RefPtr protectedThis = weakThis)
                protectedThis->m_core->swift.decodeCompleted(flushId, false, noErr, nil);
        });
        return;
    }

    decompressionSession->decodeSample(sample, WebCoreDecompressionSession::DecodingFlags::fromRaw(decodingFlags))->whenSettled(queueSingleton(), [weakThis = ThreadSafeWeakPtr { *this }, flushId](WebCoreDecompressionSession::DecodingPromise::Result&& result) {
        RefPtr protectedThis = weakThis;
        if (!protectedThis)
            return;

        assertIsCurrent(queueSingleton());

        if (!result) {
            protectedThis->m_core->swift.decodeCompleted(flushId, false, result.error(), nil);
            return;
        }
        RetainPtr frames = adoptNS([[NSMutableArray alloc] initWithCapacity:result->size()]);
        for (auto& decodedFrame : *result) {
            if (decodedFrame)
                [frames addObject:(__bridge id)decodedFrame.get()];
        }
        protectedThis->m_core->swift.decodeCompleted(flushId, true, noErr, frames.get());
    });
}

double VideoMediaSampleRenderer::updateFrameRateMonitor()
{
    m_frameRateMonitor.update();
    return m_frameRateMonitor.observedFrameRate();
}

void VideoMediaSampleRenderer::flush()
{
    assertIsMainThread();

    m_needsFlushing = false;

    [protect(renderer()) flush];

    if (!managesDecodedFrames()) {
        resetReadyForMoreMediaData();
        return;
    }

    cancelTimer();
    m_core->swift.flushCompressedSamples();

    if (RefPtr decompressionSession = this->decompressionSession())
        decompressionSession->flush();
    m_core->swift.flushDecodedSamples();
}

void VideoMediaSampleRenderer::shutdown()
{
    assertIsMainThread();

    m_requestMediaDataProducer.reset();
    clearTimebase();
    [protect(renderer()) flush];
    cancelTimer();
    m_core->swift.shutdown();
    RefPtr<WebCoreDecompressionSession> decompressionSession = [&] {
        Locker lock { m_lock };
        return std::exchange(m_decompressionSession, nullptr);
    }();
    if (decompressionSession)
        decompressionSession->invalidate();

    RetainPtr renderer = this->renderer();
    if (renderer) {
        [renderer flush];
        [renderer stopRequestingMediaData];
    }

    if (managesDecodedFrames()) {
        // stopRequestingMediaData may deadlock if used on the main thread while enqueuing on the workqueue
        queueSingleton().dispatch([videoRenderer = RetainPtr { videoRendererFor(renderer.get()) }] {
            [videoRenderer stopRequestingMediaData];
        });
    }
}

Ref<GenericPromise> VideoMediaSampleRenderer::requestMediaDataWhenReady()
{
    assertIsMainThread();

    m_requestMediaDataProducer.emplace();
    Ref promise = m_requestMediaDataProducer->promise();
    resetReadyForMoreMediaData();
    return promise;
}

void VideoMediaSampleRenderer::resetReadyForMoreMediaData()
{
    assertIsMainThread();

    RetainPtr renderer = this->renderer();
    if (!renderer || managesDecodedFrames()) {
        m_core->swift.checkReadyForMoreMediaData();
        return;
    }

    if (!m_requestMediaDataProducer)
        return;

    ThreadSafeWeakPtr weakThis { *this };
    WeakObjCPtr<WebSampleBufferVideoRendering> weakRenderer { renderer.get() };
    [renderer requestMediaDataWhenReadyOnQueue:mainDispatchQueueSingleton() usingBlock:^{
        assertIsMainThread();
        [protect(weakRenderer) stopRequestingMediaData];
        if (RefPtr protectedThis = weakThis)
            protectedThis->resolveRequestMediaDataIfNeeded();
    }];
}

void VideoMediaSampleRenderer::expectMinimumUpcomingSampleBufferPresentationTime(const MediaTime& time)
{
    assertIsMainThread();
    if (managesDecodedFrames() || ![PAL::getAVSampleBufferDisplayLayerClassSingleton() instancesRespondToSelector:@selector(expectMinimumUpcomingSampleBufferPresentationTime:)])
        return;

    [protect(renderer()) expectMinimumUpcomingSampleBufferPresentationTime:PAL::toCMTime(time)];
}

WebSampleBufferVideoRendering *VideoMediaSampleRenderer::renderer() const
{
    assertIsMainThread();

    if (m_displayLayer)
        return m_displayLayer.get();
    return m_mainRenderer.get();
}

template <>
AVSampleBufferVideoRenderer *VideoMediaSampleRenderer::as() const
{
    assertIsMainThread();

    return m_mainRenderer.get();
}

auto VideoMediaSampleRenderer::copyDisplayedPixelBuffer() -> DisplayedPixelBufferEntry
{
    assertIsMainThread();

    auto copyFromRenderer = [&] -> DisplayedPixelBufferEntry {
        RetainPtr buffer = adoptCF([renderer() copyDisplayedPixelBuffer]);
        if (RetainPtr surface = CVPixelBufferGetIOSurface(buffer.get()); surface && m_resourceOwner)
            IOSurface::setOwnershipIdentity(surface.get(), m_resourceOwner);
        return { WTF::move(buffer), MediaTime::invalidTime() };
    };

    if (!managesDecodedFrames())
        return copyFromRenderer();

    RetainPtr decodedSample = adoptCF(m_core->swift.copyDecodedSample());
    RetainPtr imageBuffer = decodedSample ? imageForSample(decodedSample.get()) : nullptr;
    if (!imageBuffer) {
        // Compressed samples enqueued after decoded ones are not in the decoded queue.
        if (!isUsingDecompressionSession())
            return copyFromRenderer();
        return { nullptr, MediaTime::invalidTime() };
    }

    ASSERT(CFGetTypeID(imageBuffer.get()) == CVPixelBufferGetTypeID());
    if (CFGetTypeID(imageBuffer.get()) != CVPixelBufferGetTypeID())
        return { nullptr, MediaTime::invalidTime() };
    return { WTF::move(imageBuffer), PAL::toMediaTime(m_core->swift.lastCopiedPresentationTime()) };
}

unsigned VideoMediaSampleRenderer::totalDisplayedFrames() const
{
    assertIsMainThread();

    return m_core->swift.totalDisplayedFrames();
}

std::optional<VideoPlaybackQualityMetrics> VideoMediaSampleRenderer::videoPlaybackQualityMetrics() const
{
    assertIsMainThread();

    auto metrics = m_core->swift.metrics();
    if (managesDecodedFrames() && !metrics.decompressionSessionBlocked) {
        return VideoPlaybackQualityMetrics {
            metrics.totalVideoFrames,
            metrics.droppedVideoFrames,
            metrics.corruptedVideoFrames,
            metrics.totalFrameDelay,
            metrics.presentedVideoFrames
        };
    }
#if PLATFORM(WATCHOS)
    return std::nullopt;
#else
    RetainPtr renderer = this->renderer();
    RetainPtr rendererMetrics = [renderer videoPerformanceMetrics];
    return VideoPlaybackQualityMetrics {
        static_cast<uint32_t>([rendererMetrics totalNumberOfVideoFrames]),
        static_cast<uint32_t>([rendererMetrics numberOfDroppedVideoFrames] + metrics.droppedVideoFramesOffset),
        static_cast<uint32_t>([rendererMetrics numberOfCorruptedVideoFrames] + metrics.corruptedVideoFrames),
        [rendererMetrics totalFrameDelay],
        totalDisplayedFrames()
    };
#endif
}

uint32_t VideoMediaSampleRenderer::rendererDroppedVideoFrames()
{
    assertIsMainThread();

#if PLATFORM(WATCHOS)
    return std::numeric_limits<uint32_t>::max();
#else
    return [protect(renderer()) videoPerformanceMetrics].numberOfDroppedVideoFrames;
#endif
}

void VideoMediaSampleRenderer::setResourceOwner(const ProcessIdentity& resourceOwner)
{
    m_resourceOwner = resourceOwner;
    m_core->swift.setHasResourceOwner(!!resourceOwner);
}

void VideoMediaSampleRenderer::invalidateDecompressionSession()
{
    RefPtr decompressionSession = [&] {
        Locker lock { m_lock };
        return std::exchange(m_decompressionSession, nullptr);
    }();

    if (decompressionSession)
        decompressionSession->invalidate();

    // Drops samples already queued for the invalidated session.
    m_core->swift.decompressionSessionInvalidated();

    ensureOnMainThread([weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis)
            protectedThis->notifyVideoRendererRequiresFlushToResumeDecoding();
    });
}

void VideoMediaSampleRenderer::assignResourceOwner(CMSampleBufferRef sample)
{
    if (!m_resourceOwner)
        return;

    auto assignImageBuffer = [&](CVPixelBufferRef imageBuffer) {
        if (!imageBuffer || CFGetTypeID(imageBuffer) != CVPixelBufferGetTypeID())
            return;

        if (RetainPtr surface = CVPixelBufferGetIOSurface(imageBuffer))
            IOSurface::setOwnershipIdentity(surface.get(), m_resourceOwner);
    };

    RetainPtr videoFormatDescription = PAL::CMSampleBufferGetFormatDescription(sample);
    if (PAL::CMFormatDescriptionGetMediaType(videoFormatDescription.get()) == kCMMediaType_TaggedBufferGroup) {
        RetainPtr group = PAL::CMSampleBufferGetTaggedBufferGroup(sample);

        for (CFIndex index = 0; index < PAL::CMTaggedBufferGroupGetCount(group.get()); ++index)
            assignImageBuffer(protect(PAL::CMTaggedBufferGroupGetCVPixelBufferAtIndex(group.get(), index)));
        return;
    }
    assignImageBuffer(protect(PAL::CMSampleBufferGetImageBuffer(sample)));
}

void VideoMediaSampleRenderer::notifyFirstFrameAvailable(Function<void(const MediaTime&, double)>&& callback)
{
    assertIsMainThread();

    m_hasFirstFrameAvailableCallback = WTF::move(callback);
}

void VideoMediaSampleRenderer::notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&& callback)
{
    assertIsMainThread();

    m_hasAvailableFrameCallback = WTF::move(callback);
    m_core->swift.setNotifyWhenHasAvailableVideoFrame(!!m_hasAvailableFrameCallback);
}

void VideoMediaSampleRenderer::notifyFirstFrameAvailable(CMTime presentationTime, double displayTime)
{
    assertIsMainThread();

    if (m_hasFirstFrameAvailableCallback)
        m_hasFirstFrameAvailableCallback(PAL::toMediaTime(presentationTime), displayTime);
}

void VideoMediaSampleRenderer::notifyHasAvailableVideoFrame(CMTime presentationTime, double displayTime)
{
    assertIsMainThread();

    if (m_hasAvailableFrameCallback)
        m_hasAvailableFrameCallback(PAL::toMediaTime(presentationTime), displayTime);
}

void VideoMediaSampleRenderer::notifyDecodingError(int32_t status)
{
    assertIsMainThread();

    RetainPtr error = [NSError errorWithDomain:@"com.apple.WebKit" code:status userInfo:nil];
    notifyErrorHasOccurred(error.get());
}

void VideoMediaSampleRenderer::notifyWhenDecodingErrorOccurred(Function<void(NSError *)>&& callback)
{
    assertIsMainThread();
    m_errorOccurredFunction = WTF::move(callback);
}

void VideoMediaSampleRenderer::notifyWhenVideoRendererRequiresFlushToResumeDecoding(Function<void()>&& callback)
{
    assertIsMainThread();
    m_rendererNeedsFlushFunction = WTF::move(callback);
}

void VideoMediaSampleRenderer::notifyErrorHasOccurred(NSError *error)
{
    ALWAYS_LOG(LOGIDENTIFIER, "error: ", [error description]);
    assertIsMainThread();

    if (m_errorOccurredFunction)
        m_errorOccurredFunction(error);
}

void VideoMediaSampleRenderer::notifyVideoRendererRequiresFlushToResumeDecoding()
{
    ALWAYS_LOG(LOGIDENTIFIER);
    assertIsMainThread();

    m_needsFlushing = true;
    if (m_rendererNeedsFlushFunction)
        m_rendererNeedsFlushFunction();
}

void VideoMediaSampleRenderer::videoRendererDidReceiveError(WebSampleBufferVideoRendering *renderer, NSError *error)
{
    assertIsMainThread();
    if (renderer != this->renderer())
        return;
#if PLATFORM(IOS_FAMILY)
    if ((renderer.status == AVQueuedSampleBufferRenderingStatusFailed || renderer.status == AVQueuedSampleBufferRenderingStatusUnknown) && [error.domain isEqualToString:@"AVFoundationErrorDomain"] && error.code == AVErrorOperationInterrupted) {
        notifyVideoRendererRequiresFlushToResumeDecoding();
        return;
    }
    ALWAYS_LOG(LOGIDENTIFIER, "status: ", renderer.status, " domain: ", [error.domain UTF8String], " errorCode: ", error.code);
#endif
    notifyErrorHasOccurred(error);
}

void VideoMediaSampleRenderer::videoRendererRequiresFlushToResumeDecodingChanged(WebSampleBufferVideoRendering *renderer, bool requiresFlush)
{
    ALWAYS_LOG(LOGIDENTIFIER, "requiresFlush:", requiresFlush);
    assertIsMainThread();
    if (renderer != this->renderer() || !requiresFlush)
        return;
    notifyVideoRendererRequiresFlushToResumeDecoding();
}

void VideoMediaSampleRenderer::videoRendererReadyForDisplayChanged(WebSampleBufferVideoRendering *renderer, bool isReadyForDisplay)
{
    ALWAYS_LOG(LOGIDENTIFIER, "isReadyForDisplay:", isReadyForDisplay);
    assertIsMainThread();
    if (renderer != this->renderer() || !isReadyForDisplay)
        return;
    if (!managesDecodedFrames() && m_hasFirstFrameAvailableCallback)
        m_hasFirstFrameAvailableCallback(currentTime(), m_core->swift.secondsSinceFirstSample());
}

void VideoMediaSampleRenderer::outputObscuredDueToInsufficientExternalProtectionChanged(bool obscured)
{
    RetainPtr error = [NSError errorWithDomain:@"com.apple.WebKit" code:'HDCP' userInfo:@{
        @"obscured": obscured ? @YES : @NO
    }];
    notifyErrorHasOccurred(error.get());
}

bool VideoMediaSampleRenderer::willLog(VideoMediaSampleRendererLogLevel level) const
{
    switch (level) {
    case VideoMediaSampleRendererLogLevel::Performance:
        return LOG_CHANNEL(MediaPerformance).level >= WTFLogLevel::Debug;
#if !RELEASE_LOG_DISABLED
    // The logger filters again, and tells its observers.
    case VideoMediaSampleRendererLogLevel::Always:
    case VideoMediaSampleRendererLogLevel::Error:
        return logger().enabled();
    case VideoMediaSampleRendererLogLevel::Debug:
        return logger().enabled() && logChannel().state != WTFLogChannelState::Off && WTFLogLevel::Debug <= logChannel().level;
#else
    case VideoMediaSampleRendererLogLevel::Always:
    case VideoMediaSampleRendererLogLevel::Error:
    case VideoMediaSampleRendererLogLevel::Debug:
        return false;
#endif
    }
    return false;
}

void VideoMediaSampleRenderer::log(VideoMediaSampleRendererLogLevel level, std::span<const uint8_t> message) const
{
    auto text = String::fromUTF8(message);
    switch (level) {
    case VideoMediaSampleRendererLogLevel::Performance:
        RELEASE_LOG_DEBUG(MediaPerformance, "%{public}s", safePrintfType(text.utf8()));
        return;
#if !RELEASE_LOG_DISABLED
    case VideoMediaSampleRendererLogLevel::Always:
        ALWAYS_LOG(LOGIDENTIFIER, text);
        return;
    case VideoMediaSampleRendererLogLevel::Error:
        ERROR_LOG(LOGIDENTIFIER, text);
        return;
    case VideoMediaSampleRendererLogLevel::Debug:
        DEBUG_LOG(LOGIDENTIFIER, text);
        return;
#else
    case VideoMediaSampleRendererLogLevel::Always:
    case VideoMediaSampleRendererLogLevel::Error:
    case VideoMediaSampleRendererLogLevel::Debug:
        return;
#endif
    }
}

#if !RELEASE_LOG_DISABLED
WTFLogChannel& VideoMediaSampleRenderer::logChannel() const
{
    return LogMedia;
}
#endif

// VideoMediaSampleRendererHost

Ref<VideoMediaSampleRendererHost> VideoMediaSampleRendererHost::create(VideoMediaSampleRenderer& renderer)
{
    return adoptRef(*new VideoMediaSampleRendererHost(renderer));
}

VideoMediaSampleRendererHost::VideoMediaSampleRendererHost(VideoMediaSampleRenderer& renderer)
    : m_renderer(renderer)
{
}

VideoMediaSampleRendererHost::~VideoMediaSampleRendererHost() = default;

dispatch_queue_t VideoMediaSampleRendererHost::dispatchQueue() const
{
    return VideoMediaSampleRenderer::queueSingleton().dispatchQueue();
}

bool VideoMediaSampleRendererHost::hasTimebase() const
{
    RefPtr renderer = m_renderer.get();
    return renderer && renderer->timebase();
}

CMTime VideoMediaSampleRendererHost::timebaseTime() const
{
    if (RefPtr renderer = m_renderer.get()) {
        if (RetainPtr timebase = renderer->timebase())
            return PAL::CMTimebaseGetTime(timebase.get());
    }
    return PAL::kCMTimeInvalid;
}

double VideoMediaSampleRendererHost::timebaseRate() const
{
    if (RefPtr renderer = m_renderer.get()) {
        if (RetainPtr timebase = renderer->timebase())
            return PAL::CMTimebaseGetRate(timebase.get());
    }
    return 0;
}

bool VideoMediaSampleRendererHost::willLog(VideoMediaSampleRendererLogLevel level) const
{
    RefPtr renderer = m_renderer.get();
    return renderer && renderer->willLog(level);
}

void VideoMediaSampleRendererHost::log(VideoMediaSampleRendererLogLevel level, WTF::SpanUInt8 message NOESCAPE) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->log(level, message);
}

void VideoMediaSampleRendererHost::setPurgeTimerFireTime(CMTime fireTime) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->setPurgeTimerFireTime(fireTime);
}

void VideoMediaSampleRendererHost::decodeSample(CMSampleBufferRef sample, uint8_t decodingFlags, int32_t flushId) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->decodeSample(sample, decodingFlags, flushId);
}

void VideoMediaSampleRendererHost::invalidateDecompressionSession() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->invalidateDecompressionSession();
}

bool VideoMediaSampleRendererHost::isDecompressionSessionHardwareAccelerated() const
{
    RefPtr renderer = m_renderer.get();
    RefPtr decompressionSession = renderer ? renderer->decompressionSession() : nullptr;
    return decompressionSession && decompressionSession->isHardwareAccelerated();
}

double VideoMediaSampleRendererHost::frameRateMonitorUpdate() const
{
    RefPtr renderer = m_renderer.get();
    return renderer ? renderer->updateFrameRateMonitor() : 0;
}

void VideoMediaSampleRendererHost::assignResourceOwner(CMSampleBufferRef sample) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->assignResourceOwner(sample);
}

void VideoMediaSampleRendererHost::initializeDecompressionSession() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->initializeDecompressionSession();
}

bool VideoMediaSampleRendererHost::vp9HardwareDecoderAvailable() const
{
#if ENABLE(VP9)
    return vp9HardwareDecoderAvailableInProcess();
#else
    return false;
#endif
}

uint32_t VideoMediaSampleRendererHost::rendererDroppedVideoFrames() const
{
    RefPtr renderer = m_renderer.get();
    return renderer ? renderer->rendererDroppedVideoFrames() : 0;
}

void VideoMediaSampleRendererHost::requestMediaDataResolved() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->resolveRequestMediaDataIfNeeded();
}

void VideoMediaSampleRendererHost::firstFrameAvailable(CMTime presentationTime, double displayTime) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->notifyFirstFrameAvailable(presentationTime, displayTime);
}

void VideoMediaSampleRendererHost::hasAvailableVideoFrame(CMTime presentationTime, double displayTime) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->notifyHasAvailableVideoFrame(presentationTime, displayTime);
}

void VideoMediaSampleRendererHost::decodingErrorOccurred(int32_t status) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->notifyDecodingError(status);
}

} // namespace WebCore
