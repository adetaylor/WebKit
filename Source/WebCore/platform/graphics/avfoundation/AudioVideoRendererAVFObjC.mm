/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
#import "AudioVideoRendererAVFObjC.h"

#import "AudioMediaStreamTrackRenderer.h"
#import "AudioVideoRendererHost.h"
#import "CDMFairPlayStreaming.h"
#import "CDMInstanceFairPlayStreamingAVFObjC.h"
#import "CDMLogging.h"
#import "CDMSessionAVContentKeySession.h"
#import "FormatDescriptionUtilities.h"
#import "GraphicsContext.h"
#import "IOSurface.h"
#import "LayoutRect.h"
#import "Logging.h"
#import "MediaPlayerPrivate.h"
#import "MediaSampleAVFObjC.h"
#import "NativeImage.h"
#import "PixelBufferConformerCV.h"
#import "PlatformDynamicRangeLimitCocoa.h"
#import "SharedTimebase.h"
#import "SpatialAudioExperienceHelper.h"
#import "TextTrackRepresentation.h"
#import "VP9UtilitiesCocoa.h"
#import "VideoDecodeWindow.h"
#import "VideoFrameCV.h"
#import "VideoLayerManagerObjC.h"
#import "WebCore-Swift.h"
#import "WebCoreDecompressionSession.h"
#import "WebSampleBufferVideoRendering.h"

#import <AVFoundation/AVFoundation.h>
#import <pal/avfoundation/MediaTimeAVFoundation.h>
#import <pal/spi/cocoa/AVFoundationSPI.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/MainThread.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/SoftLinking.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/WorkQueue.h>
#import <wtf/cocoa/Entitlements.h>
#import <wtf/darwin/DispatchExtras.h>

#pragma mark - Soft Linking
#import "CoreVideoSoftLink.h"
#import "VideoToolboxSoftLink.h"
#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

#if USE(APPLE_INTERNAL_SDK) && __has_include(<WebKitAdditions/AVSampleBufferRenderSynchronizerAdditions.mm>)
#import <WebKitAdditions/AVSampleBufferRenderSynchronizerAdditions.mm>
#else
NODELETE static void setSynchronizerScreenReserved(AVSampleBufferRenderSynchronizer *, bool) { }
#endif

@interface AVSampleBufferDisplayLayer (WebCoreSampleBufferKeySession) <AVContentKeyRecipient>
@end

@interface AVSampleBufferAudioRenderer (WebCoreSampleBufferKeySession) <AVContentKeyRecipient>
@end

@interface AVSampleBufferDisplayLayer (WebCoreAVSampleBufferDisplayLayerQueueManagementPrivate)
- (void)expectMinimumUpcomingSampleBufferPresentationTime:(CMTime)minimumUpcomingPresentationTime;
@end

#if ENABLE(LINEAR_MEDIA_PLAYER)
@interface AVSampleBufferVideoRenderer (Staging_127455709)
- (void)removeAllVideoTargets;
@end
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AudioVideoRendererAVFObjC);

struct AudioVideoRendererAVFObjC::Core {
    typedef AudioVideoRendererAVFObjC::Core AudioVideoRendererCoreHolder;
    WTF_MAKE_TZONE_ALLOCATED_INLINE(AudioVideoRendererCoreHolder);
public:
    AudioVideoRendererCore swift;
};

// AudioVideoRendererAVFObjC.swift's PlatformMediaError values.
static_assert(static_cast<uint8_t>(PlatformMediaError::DecoderCreationError) == 9);
static_assert(static_cast<uint8_t>(PlatformMediaError::AudioDecodingError) == 13);
static_assert(static_cast<uint8_t>(PlatformMediaError::VideoDecodingError) == 14);
static_assert(static_cast<uint8_t>(PlatformMediaError::HardwareDecoderUnavailable) == 19);
// AudioVideoRendererAVFObjC.swift's TrackInfoTrackType values.
static_assert(static_cast<uint8_t>(TrackInfoTrackType::Audio) == 1);
static_assert(static_cast<uint8_t>(TrackInfoTrackType::Video) == 2);
// AudioVideoRendererAVFObjC.swift's MediaPlayerPitchCorrectionAlgorithm values.
static_assert(static_cast<uint8_t>(MediaPlayerPitchCorrectionAlgorithm::BestForSpeech) == 2);
// The VideoRendererPreference and WebCoreDecompressionSession::DecodingFlag bits that
// AudioVideoRendererAVFObjC.swift and VideoMediaSampleRenderer.swift test for a hardware decoder.
static_assert(static_cast<uint8_t>(VideoRendererPreference::RequiresHardwareDecoder) == 1 << 5);
static_assert(static_cast<uint8_t>(WebCoreDecompressionSession::DecodingFlag::HardwareOnly) == 1 << 3);

static WorkQueue& videoRendererQueueSingleton()
{
    static std::once_flag onceKey;
    static LazyNeverDestroyed<Ref<WorkQueue>> workQueue;
    std::call_once(onceKey, [] {
        workQueue.construct(WorkQueue::create("VideoMediaSampleRenderer Queue"_s, WorkQueue::QOS::UserInteractive));
    });
    return workQueue.get();
}

// MediaTime's indefinite time, which PAL::toCMTime() doesn't keep, means an unknown minimum upcoming time.
static CMTime toCMTimeKeepingIndefinite(const MediaTime& time)
{
    auto result = PAL::toCMTime(time);
    if (time.isIndefinite())
        result.flags |= kCMTimeFlags_Indefinite;
    return result;
}

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

CVBufferRef imageBufferForSample(CMSampleBufferRef sample) { return imageForSample(sample).leakRef(); }

CVBufferRef copyDisplayedPixelBuffer(NSObject *renderer) { return [(NSObject<WebSampleBufferVideoRendering> *)renderer copyDisplayedPixelBuffer]; }

static AVSampleBufferVideoRenderer *videoRendererFor(NSObject *renderer)
{
    if (auto *displayLayer = dynamic_objc_cast<AVSampleBufferDisplayLayer>(renderer))
        return [displayLayer sampleBufferRenderer];
    return dynamic_objc_cast<AVSampleBufferVideoRenderer>(renderer);
}

Ref<AudioVideoRendererAVFObjC> AudioVideoRendererAVFObjC::create(const Logger& logger, uint64_t logIdentifier)
{
    return adoptRef(*new AudioVideoRendererAVFObjC(logger, logIdentifier, nullptr));
}

Ref<AudioVideoRendererAVFObjC> AudioVideoRendererAVFObjC::create(const Logger& logger, uint64_t logIdentifier, UniqueRef<SharedTimebase>&& sharedTimebase)
{
    return adoptRef(*new AudioVideoRendererAVFObjC(logger, logIdentifier, sharedTimebase.moveToUniquePtr()));
}

AudioVideoRendererAVFObjC::AudioVideoRendererAVFObjC(const Logger& originalLogger, uint64_t logSiteIdentifier, std::unique_ptr<SharedTimebase>&& sharedTimebase)
    : m_logger(originalLogger)
    , m_logIdentifier(logSiteIdentifier)
    , m_videoLayerManager(makeUniqueRef<VideoLayerManagerObjC>(originalLogger, logSiteIdentifier))
    , m_synchronizer(adoptNS([PAL::allocAVSampleBufferRenderSynchronizerInstance() init]))
    , m_sharedTimebase(WTF::move(sharedTimebase))
    , m_core(makeUnique<Core>(AudioVideoRendererCore::init(AudioVideoRendererHost::create(*this).ptr(), m_synchronizer.get(), { PAL::toCMTime(VideoDecodeWindow::lowWaterMark), PAL::toCMTime(VideoDecodeWindow::highWaterMark), VideoDecodeWindow::sampleQueueHighWaterMark, VideoDecodeWindow::sampleQueueLowWaterMark, !!m_sharedTimebase })))
    , m_swiftToken(m_core->swift.token())
#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    , m_keyStatusesChangedObserver(Observer<void()>::create([weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->tryToEnqueueBlockedSamples();
    }))
#endif
{
    stall();
}

AudioVideoRendererAVFObjC::~AudioVideoRendererAVFObjC()
{
    m_seekPromise.reset();
    if (auto producer = std::exchange(m_stallProducer, std::nullopt))
        producer->reject(PlatformMediaError::Cancelled);
    m_core->swift.destroy();

#if ENABLE(LEGACY_ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    if (RefPtr session = m_session.get())
        session->removeRenderer(*this);
#endif
}

void AudioVideoRendererAVFObjC::shutdown()
{
    if (std::exchange(m_isShutdown, true))
        return;

    if (auto producer = std::exchange(m_stallProducer, std::nullopt))
        producer->reject(PlatformMediaError::Cancelled);
    m_core->swift.shutdown();
}

std::optional<TracksRendererManager::TrackIdentifier> AudioVideoRendererAVFObjC::addTrack(TrackType type)
{
    if (m_isShutdown)
        return { };
    auto identifier = TrackIdentifier::generate();
    if (!m_core->swift.addTrack(identifier.toUInt64(), static_cast<uint8_t>(type)))
        return std::nullopt;
    return identifier;
}

void AudioVideoRendererAVFObjC::removeTrack(TrackIdentifier trackId)
{
    if (m_isShutdown)
        return;
    m_reenqueueCallbacks.remove(trackId.toUInt64());
    m_core->swift.removeTrack(trackId.toUInt64());
}

std::optional<TracksRendererManager::TrackType> AudioVideoRendererAVFObjC::typeOf(TrackIdentifier trackId) const
{
    auto type = m_core->swift.trackType(trackId.toUInt64());
    if (type == 0xFF)
        return { };
    return static_cast<TrackType>(type);
}

void AudioVideoRendererAVFObjC::enqueueSample(TrackIdentifier trackId, Ref<MediaSample>&& sample, std::optional<MediaTime> minimumUpcomingTime)
{
    if (m_isShutdown)
        return;
    auto type = typeOf(trackId);
    if (!type)
        return;

#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    if (!canEnqueueSample(trackId, sample)) {
        DEBUG_LOG(LOGIDENTIFIER, "Can't enqueue sample: ", sample.get(), " for track: ", toString(trackId));
        m_blockedSamples.append({ trackId, sample });
        return;
    }
    attachContentKeyToSampleIfNeeded(sample);
#endif

    RetainPtr cmSampleBuffer = sample->platformSample().cmSampleBuffer();
    RetainPtr formatDescription = PAL::CMSampleBufferGetFormatDescription(cmSampleBuffer.get());
    ASSERT(formatDescription);
    if (!formatDescription) {
        ERROR_LOG(LOGIDENTIFIER, "Received sample with a null formatDescription. Bailing.");
        return;
    }
    auto mediaType = typeFromFormatDescription(formatDescription.get());
    if (mediaType != *type) {
        ASSERT_NOT_REACHED();
        ERROR_LOG(LOGIDENTIFIER, "Expected sample of type: ", *type, " got: '", mediaType, "'. Bailing.");
        return;
    }

    AudioVideoRendererSampleInfo info { };
    if (*type == TrackType::Video) {
        DEBUG_LOG(LOGIDENTIFIER, "sample: ", sample.get(), " minimumUpcomingTime: ", minimumUpcomingTime.value_or(MediaTime::invalidTime()));
        info.presentationTime = PAL::toCMTime(sample->presentationTime());
        info.presentationEndTime = PAL::toCMTime(sample->presentationEndTime());
        info.hasMinimumUpcomingTime = !!minimumUpcomingTime;
        info.minimumUpcomingTime = minimumUpcomingTime ? toCMTimeKeepingIndefinite(*minimumUpcomingTime) : PAL::kCMTimeInvalid;
        if (m_sizeChangedCallback) {
            FloatSize formatSize = presentationSizeFromFormatDescription(formatDescription.get());
            info.hasPresentationSize = true;
            info.presentationWidth = formatSize.width();
            info.presentationHeight = formatSize.height();
        }
        info.isProtected = sample->isProtected();
        info.isSync = sample->isSync();
        info.hasImageBuffer = !!PAL::CMSampleBufferGetImageBuffer(cmSampleBuffer.get());
    }
    info.isNonDisplaying = sample->isNonDisplaying();
    m_core->swift.enqueueSample(trackId.toUInt64(), cmSampleBuffer.get(), info);
}

Ref<AudioVideoRenderer::RequestPromise> AudioVideoRendererAVFObjC::requestMediaDataWhenReady(TrackIdentifier trackId)
{
    if (m_isShutdown)
        return RequestPromise::createAndReject(PlatformMediaError::Shutdown);
    auto type = typeOf(trackId);
    if (!type)
        return RequestPromise::createAndReject(PlatformMediaError::LogicError);

    switch (m_core->swift.requestMediaDataWhenReady(trackId.toUInt64())) {
    case 0:
        return RequestPromise::createAndResolve(trackId);
    case 1:
        if (*type == TrackType::Video) {
            m_requestVideoPromise.emplace(PlatformMediaError::Cancelled);
            return m_requestVideoPromise->promise();
        } else {
            auto producer = makeUnique<RequestPromise::AutoRejectProducer>(PlatformMediaError::Cancelled);
            Ref promise = producer->promise();
            m_requestAudioPromises.set(trackId.toUInt64(), WTF::move(producer));
            return promise;
        }
    default:
        ASSERT_NOT_REACHED();
        return RequestPromise::createAndReject(PlatformMediaError::LogicError);
    }
}

void AudioVideoRendererAVFObjC::mediaDataRequestSettled(bool isVideo, uint64_t trackIdentifier, bool resolved)
{
    if (isVideo) {
        if (!m_requestVideoPromise)
            return;
        if (resolved)
            std::exchange(m_requestVideoPromise, std::nullopt)->resolve(TrackIdentifier(trackIdentifier));
        else
            m_requestVideoPromise.reset();
        return;
    }
    auto producer = m_requestAudioPromises.take(trackIdentifier);
    if (producer && resolved)
        producer->resolve(TrackIdentifier(trackIdentifier));
}

void AudioVideoRendererAVFObjC::notifyTrackNeedsReenqueuing(TrackIdentifier trackId, Function<void(TrackIdentifier, const MediaTime&)>&& callback)
{
    if (m_isShutdown)
        return;
    if (typeOf(trackId) == TrackType::Audio)
        m_reenqueueCallbacks.set(trackId.toUInt64(), WTF::move(callback));
}

void AudioVideoRendererAVFObjC::audioRendererWasFlushed(uint64_t trackIdentifier, CMTime flushTime)
{
    auto iterator = m_reenqueueCallbacks.find(trackIdentifier);
    if (iterator == m_reenqueueCallbacks.end() || !iterator->value)
        return;
    iterator->value(TrackIdentifier(trackIdentifier), PAL::toMediaTime(flushTime));
}

void AudioVideoRendererAVFObjC::notifyWhenErrorOccurs(Function<void(PlatformMediaError)>&& callback)
{
    if (m_isShutdown) {
        callback(PlatformMediaError::Shutdown);
        return;
    }
    m_errorCallback = WTF::move(callback);
}

void AudioVideoRendererAVFObjC::notifyError(PlatformMediaError error)
{
    if (m_errorCallback)
        m_errorCallback(error);
}

void AudioVideoRendererAVFObjC::reportError(PlatformMediaError error)
{
    m_core->swift.reportError(static_cast<uint8_t>(error));
}

// Synchronizer interface
void AudioVideoRendererAVFObjC::storeSharedTimebaseSnapshot(CMTime currentTime, double playbackRate)
{
    if (!m_sharedTimebase)
        return;
    m_sharedTimebase->storeSnapshot({
        .currentTime = PAL::toMediaTime(currentTime),
        .playbackRate = playbackRate,
        .hostTime = MonotonicTime::now()
    });
}

Ref<MediaTimePromise> AudioVideoRendererAVFObjC::notifyTimeReachedAndStall(const MediaTime& timeBoundary)
{
    if (m_isShutdown)
        return MediaTimePromise::createAndReject(PlatformMediaError::Shutdown);
    cancelTimeReachedAction();

    auto roundedBoundary = timeBoundary.toTimeScale(1000, MediaTime::RoundingFlags::TowardNegativeInfinity);
    if (m_core->swift.notifyTimeReachedAndStall(PAL::toCMTime(timeBoundary), PAL::toCMTime(roundedBoundary)))
        return MediaTimePromise::createAndResolve(timeBoundary);

    ASSERT(!m_stallProducer);
    m_stallProducer.emplace();
    m_stallBoundary = timeBoundary;
    return m_stallProducer->promise();
}

void AudioVideoRendererAVFObjC::timeReached()
{
    if (auto producer = std::exchange(m_stallProducer, std::nullopt))
        producer->resolve(m_stallBoundary);
}

void AudioVideoRendererAVFObjC::cancelTimeReachedAction()
{
    m_core->swift.cancelTimeReachedAction();
    if (auto producer = std::exchange(m_stallProducer, std::nullopt))
        producer->reject(PlatformMediaError::Cancelled);
}

void AudioVideoRendererAVFObjC::performTaskAtTime(const MediaTime& time, Function<void(const MediaTime&)>&& task)
{
    if (m_isShutdown)
        return;
    m_performTask = WTF::move(task);
    m_core->swift.performTaskAtTime(PAL::toCMTime(time));
}

void AudioVideoRendererAVFObjC::performTask(CMTime now)
{
    if (auto task = std::exchange(m_performTask, nullptr))
        task(PAL::toMediaTime(now));
}

void AudioVideoRendererAVFObjC::setTimeObserver(Seconds interval, Function<void(const MediaTime&)>&& callback)
{
    if (m_isShutdown)
        return;
    ++m_timeObserverGeneration;
    m_timeObserverCallback = WTF::move(callback);
    m_core->swift.setTimeObserver(PAL::toCMTime(MediaTime::createWithSeconds(interval)), !!m_timeObserverCallback);
}

void AudioVideoRendererAVFObjC::timeObserverFired(CMTime time)
{
    // The callback may reinstall or cancel the observer, which would destroy it while it runs: it runs out of the member.
    auto callback = std::exchange(m_timeObserverCallback, nullptr);
    if (!callback)
        return;
    auto generation = m_timeObserverGeneration;
    callback(PAL::toMediaTime(time));
    if (generation == m_timeObserverGeneration)
        m_timeObserverCallback = WTF::move(callback);
}

void AudioVideoRendererAVFObjC::cancelTimeObserver()
{
    m_core->swift.cancelTimeObserver();
    ++m_timeObserverGeneration;
    m_timeObserverCallback = nullptr;
}

Ref<MediaTimePromise> AudioVideoRendererAVFObjC::prepareToSeek(const MediaTime& seekTime)
{
    if (m_isShutdown)
        return MediaTimePromise::createAndReject(PlatformMediaError::Shutdown);

    m_lastSeekTargetTime = seekTime;
    if (m_core->swift.prepareToSeek(PAL::toCMTime(seekTime)))
        return MediaTimePromise::createAndResolve(seekTime);
    return MediaTimePromise::createAndResolve(MediaTime::indefiniteTime());
}

Ref<GenericPromise> AudioVideoRendererAVFObjC::finishSeek(const MediaTime& seekTime)
{
    if (m_isShutdown)
        return GenericPromise::createAndReject();

    m_seekPromise.emplace();
    Ref promise = m_seekPromise->promise();
    if (!m_core->swift.finishSeek(PAL::toCMTime(seekTime))) {
        m_seekPromise.reset();
        return GenericPromise::createAndReject();
    }
    return promise;
}

void AudioVideoRendererAVFObjC::seekSettled(bool resolved)
{
    if (!m_seekPromise)
        return;
    if (resolved)
        std::exchange(m_seekPromise, std::nullopt)->resolve();
    else
        m_seekPromise.reset();
}

void AudioVideoRendererAVFObjC::notifyEffectiveRateChanged(Function<void(double)>&& callback)
{
    if (m_isShutdown)
        return;
    m_effectiveRateChangedCallback = WTF::move(callback);
    m_core->swift.observeEffectiveRate();
}

void AudioVideoRendererAVFObjC::setScreenReserved(bool reserved)
{
    if (m_isShutdown)
        return;
    setSynchronizerScreenReserved(m_synchronizer.get(), reserved);
}

#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
void AudioVideoRendererAVFObjC::setOutputDeviceId(const String& outputDeviceId)
{
    if (m_isShutdown)
        return;
    m_core->swift.setOutputDeviceID(outputDeviceId.isNull() ? nil : outputDeviceId.createNSString().get(), outputDeviceId.isEmpty() || outputDeviceId == AudioMediaStreamTrackRenderer::defaultDeviceID());
}
#endif

void AudioVideoRendererAVFObjC::setPresentationSize(const IntSize& newSize)
{
    if (m_isShutdown)
        return;
    m_presentationSize = newSize;
}

void AudioVideoRendererAVFObjC::contentBoxRectChanged(const LayoutRect& newRect)
{
    if (m_isShutdown)
        return;
    m_core->swift.videoSizeChanged(newRect.isEmpty());
}

void AudioVideoRendererAVFObjC::notifyFirstFrameAvailable(Function<void()>&& callback)
{
    if (m_isShutdown)
        return;
    m_firstFrameAvailableCallback = WTF::move(callback);
}

void AudioVideoRendererAVFObjC::notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&& callback)
{
    if (m_isShutdown)
        return;
    m_hasAvailableVideoFrameCallback = WTF::move(callback);
    m_core->swift.setHasAvailableVideoFrameCallback(!!m_hasAvailableVideoFrameCallback);
}

void AudioVideoRendererAVFObjC::notifyWhenRequiresFlushToResume(Function<void()>&& callback)
{
    if (m_isShutdown)
        return;
    m_notifyWhenRequiresFlushToResume = WTF::move(callback);
}

void AudioVideoRendererAVFObjC::notifyRenderingModeChanged(Function<void()>&& callback)
{
    if (m_isShutdown)
        return;
    m_renderingModeChangedCallback = WTF::move(callback);
}

void AudioVideoRendererAVFObjC::expectMinimumUpcomingPresentationTime(const MediaTime& presentationTime)
{
    if (m_isShutdown)
        return;
    m_core->swift.expectMinimumUpcomingPresentationTime(PAL::toCMTime(presentationTime));
}

void AudioVideoRendererAVFObjC::notifySizeChanged(Function<void(const MediaTime&, FloatSize)>&& callback)
{
    if (m_isShutdown)
        return;
    m_sizeChangedCallback = WTF::move(callback);
    m_core->swift.setHasSizeChangedCallback(!!m_sizeChangedCallback);
}

void AudioVideoRendererAVFObjC::setPlatformDynamicRangeLimit(const PlatformDynamicRangeLimit& platformDynamicRangeLimit)
{
    if (m_isShutdown)
        return;
    m_dynamicRangeLimit = platformDynamicRangeLimit;

    if (RetainPtr layer = (CALayer *)renderingObject(AudioVideoRendererObject::DisplayLayer, 0))
        setLayerDynamicRangeLimit(layer.get(), platformDynamicRangeLimit);
}

void AudioVideoRendererAVFObjC::setResourceOwner(const ProcessIdentity& resourceOwner)
{
    if (m_isShutdown)
        return;
    m_resourceOwner = resourceOwner;
#if HAVE(TASK_IDENTITY_TOKEN)
    m_core->swift.setResourceOwner(resourceOwner ? resourceOwner.taskIdToken() : MACH_PORT_NULL);
#else
    m_core->swift.setResourceOwner(MACH_PORT_NULL);
#endif
    if (RefPtr decompressionSession = this->decompressionSession())
        decompressionSession->setResourceOwner(resourceOwner);
}

RefPtr<VideoFrame> AudioVideoRendererAVFObjC::currentVideoFrame() const
{
    RetainPtr pixelBuffer = adoptCF(m_core->swift.copyDisplayedPixelBuffer());
    if (!pixelBuffer)
        return nullptr;

    return VideoFrameCV::create(PAL::toMediaTime(m_core->swift.displayedPixelBufferTime()), false, VideoFrame::Rotation::None, pixelBuffer.get());
}

void AudioVideoRendererAVFObjC::paintCurrentVideoFrameInContext(GraphicsContext& context, const FloatRect& outputRect)
{
    if (m_isShutdown || context.paintingDisabled())
        return;

    auto image = currentNativeImage();
    if (!image)
        return;

    GraphicsContextStateSaver stateSaver(context);
    FloatRect imageRect { FloatPoint::zero(), image->size() };
    context.drawNativeImage(*image, outputRect, imageRect);
}

std::optional<VideoPlaybackQualityMetrics> AudioVideoRendererAVFObjC::videoPlaybackQualityMetrics()
{
    auto metrics = m_core->swift.playbackQualityMetrics();
    if (!metrics.hasVideoRenderer)
        return std::nullopt;

    return VideoPlaybackQualityMetrics {
        metrics.totalVideoFrames,
        metrics.droppedVideoFrames,
        metrics.corruptedVideoFrames,
        metrics.totalFrameDelay,
        metrics.presentedVideoFrames
    };
}

PlatformLayer* AudioVideoRendererAVFObjC::platformVideoLayer() const
{
    if (!m_core->swift.videoMetrics().hasVideoRenderer)
        return nullptr;
    return m_videoLayerManager->videoInlineLayer();
}

void AudioVideoRendererAVFObjC::setVideoLayerSize(const FloatSize& newSize)
{
    if (m_isShutdown)
        return;
    m_core->swift.videoSizeChanged(newSize.isEmpty());
}

void AudioVideoRendererAVFObjC::setVideoLayerSizeFenced(const FloatSize& newSize, WTF::MachSendRightAnnotated&&)
{
    setVideoLayerSize(newSize);
}

void AudioVideoRendererAVFObjC::setVideoFullscreenLayer(PlatformLayer *videoFullscreenLayer, WTF::Function<void()>&& completionHandler)
{
    if (m_isShutdown) {
        completionHandler();
        return;
    }
    RefPtr currentImage = currentNativeImage();
    m_videoLayerManager->setVideoFullscreenLayer(videoFullscreenLayer, WTF::move(completionHandler), currentImage ? currentImage->platformImage() : nullptr);
}

void AudioVideoRendererAVFObjC::setVideoFullscreenFrame(const FloatRect& frame)
{
    if (m_isShutdown)
        return;
    m_videoLayerManager->setVideoFullscreenFrame(frame);
}

void AudioVideoRendererAVFObjC::setTextTrackRepresentation(TextTrackRepresentation* representation)
{
    if (m_isShutdown)
        return;
    RetainPtr representationLayer = representation ? representation->platformLayer() : nil;
    m_videoLayerManager->setTextTrackRepresentationLayer(representationLayer.get());
}

void AudioVideoRendererAVFObjC::syncTextTrackBounds()
{
    if (m_isShutdown)
        return;
    m_videoLayerManager->syncTextTrackBounds();
}

Ref<GenericPromise> AudioVideoRendererAVFObjC::setVideoTarget(const PlatformVideoTarget& videoTarget)
{
#if !ENABLE(LINEAR_MEDIA_PLAYER)
    UNUSED_PARAM(videoTarget);
    return GenericPromise::createAndReject();
#else
    if (m_isShutdown)
        return GenericPromise::createAndReject();
    m_videoTarget = videoTarget;
    m_videoTargetPromise.emplace();
    Ref promise = m_videoTargetPromise->promise();
    m_core->swift.setHasVideoTarget(!!m_videoTarget);
    return promise;
#endif
}

void AudioVideoRendererAVFObjC::videoTargetSettled(bool resolved)
{
#if ENABLE(LINEAR_MEDIA_PLAYER)
    if (!m_videoTargetPromise)
        return;
    if (resolved)
        std::exchange(m_videoTargetPromise, std::nullopt)->resolve();
    else
        m_videoTargetPromise.reset();
#else
    UNUSED_PARAM(resolved);
#endif
}

RefPtr<NativeImage> AudioVideoRendererAVFObjC::currentNativeImage() const
{
    if (RefPtr videoFrame = currentVideoFrame()) {
        if (!m_rgbConformer) {
            auto attributes = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
            m_rgbConformer = makeUnique<PixelBufferConformerCV>((__bridge CFDictionaryRef)attributes);
        }
        RetainPtr pixelBuffer = videoFrame->pixelBuffer();
        return m_rgbConformer->createImageFromPixelBuffer(pixelBuffer.get());
    }
    return nullptr;
}

Ref<AudioVideoRenderer::BitmapImagePromise> AudioVideoRendererAVFObjC::currentBitmapImage() const
{
    if (m_isShutdown)
        return BitmapImagePromise::createAndReject();
    RefPtr nativeImage = currentNativeImage();
    if (!nativeImage)
        return BitmapImagePromise::createAndReject();
    if (RefPtr bitmapImage = MediaPlayerPrivateInterface::bitmapFromImage(*nativeImage))
        return BitmapImagePromise::createAndResolve(bitmapImage.releaseNonNull());
    return BitmapImagePromise::createAndReject();
}

// The renderers.

NSObject *AudioVideoRendererAVFObjC::renderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    return adoptNS(m_core->swift.renderingObject(static_cast<uint8_t>(object), trackIdentifier)).autorelease();
}

void AudioVideoRendererAVFObjC::renderingObjectChanged(AudioVideoRendererObject object, NSObject *layerOrRenderer, bool created)
{
    switch (object) {
    case AudioVideoRendererObject::DisplayLayer:
        if (!created) {
            m_videoLayerManager->didDestroyVideoLayer();
            return;
        }
        setLayerDynamicRangeLimit((CALayer *)layerOrRenderer, m_dynamicRangeLimit);
        m_videoLayerManager->setVideoLayer((CALayer *)layerOrRenderer, m_presentationSize);
        return;
    case AudioVideoRendererObject::VideoRendererForTarget:
#if ENABLE(LINEAR_MEDIA_PLAYER)
        if (created)
            [(AVSampleBufferVideoRenderer *)layerOrRenderer addVideoTarget:m_videoTarget.get()];
        else if ([layerOrRenderer respondsToSelector:@selector(removeAllVideoTargets)])
            [(AVSampleBufferVideoRenderer *)layerOrRenderer removeAllVideoTargets];
#endif
        return;
    case AudioVideoRendererObject::AudioRenderer:
        return;
    }
}

void AudioVideoRendererAVFObjC::expectMinimumUpcomingPresentationTime(AudioVideoRendererObject object, CMTime time)
{
    if (![PAL::getAVSampleBufferDisplayLayerClassSingleton() instancesRespondToSelector:@selector(expectMinimumUpcomingSampleBufferPresentationTime:)])
        return;

    RetainPtr renderer = (WebSampleBufferVideoRendering *)renderingObject(object, 0);
    [renderer expectMinimumUpcomingSampleBufferPresentationTime:time];
}

void AudioVideoRendererAVFObjC::removeBlockedSamples(AudioVideoRendererBlockedSamples which, uint64_t trackIdentifier)
{
#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    switch (which) {
    case AudioVideoRendererBlockedSamples::All:
        m_blockedSamples.clear();
        return;
    case AudioVideoRendererBlockedSamples::Video:
    case AudioVideoRendererBlockedSamples::Audio: {
        auto type = which == AudioVideoRendererBlockedSamples::Video ? TrackType::Video : TrackType::Audio;
        m_blockedSamples.removeAllMatching([&](auto& blockedSample) {
            return typeOf(blockedSample.first) == type;
        });
        return;
    }
    case AudioVideoRendererBlockedSamples::Track:
        m_blockedSamples.removeAllMatching([&](auto& blockedSample) {
            return blockedSample.first.toUInt64() == trackIdentifier;
        });
        return;
    }
#else
    UNUSED_PARAM(which);
    UNUSED_PARAM(trackIdentifier);
#endif
}

void AudioVideoRendererAVFObjC::hdcpStatusChanged(bool obscured)
{
#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    if (RefPtr cdmInstance = m_cdmInstance)
        cdmInstance->setHDCPStatus(obscured ? CDMInstance::HDCPStatus::OutputRestricted : CDMInstance::HDCPStatus::Valid);
#else
    UNUSED_PARAM(obscured);
    reportError(PlatformMediaError::VideoDecodingError);
#endif
}

// The video renderer's decompression session.

RefPtr<WebCoreDecompressionSession> AudioVideoRendererAVFObjC::decompressionSession() const
{
    Locker locker { m_videoRendererLock };
    return m_decompressionSession;
}

RefPtr<WebCoreDecompressionSession> AudioVideoRendererAVFObjC::decompressionSessionFor(uint64_t identifier) const
{
    Locker locker { m_videoRendererLock };
    return m_decompressionSessionIdentifier == identifier ? m_decompressionSession : nullptr;
}

void AudioVideoRendererAVFObjC::initializeDecompressionSession(uint64_t rendererIdentifier, uint8_t rendererObject)
{
    ALWAYS_LOG(LOGIDENTIFIER);
    assertIsMainThread();

    RetainPtr mainRenderer = rendererObject == 0xFF ? nil : videoRendererFor(renderingObject(static_cast<AudioVideoRendererObject>(rendererObject), 0));

    Locker locker { m_videoRendererLock };

    ASSERT(!m_decompressionSession);
    if (m_decompressionSession)
        return;

#if HAVE(RECOMMENDED_PIXEL_ATTRIBUTES_API)
    if (mainRenderer) {
        if ([mainRenderer respondsToSelector:@selector(recommendedPixelBufferAttributes)])
            m_decompressionSession = WebCoreDecompressionSession::create([mainRenderer recommendedPixelBufferAttributes], &videoRendererQueueSingleton());
    }
#else
    UNUSED_VARIABLE(mainRenderer);
#endif
    if (!m_decompressionSession)
        m_decompressionSession = WebCoreDecompressionSession::createOpenGL(&videoRendererQueueSingleton());
    protect(m_decompressionSession)->setResourceOwner(m_resourceOwner);
    m_decompressionSessionIdentifier = rendererIdentifier;
}

void AudioVideoRendererAVFObjC::invalidateDecompressionSession(std::optional<uint64_t> rendererIdentifier)
{
    RefPtr decompressionSession = [&] -> RefPtr<WebCoreDecompressionSession> {
        Locker locker { m_videoRendererLock };
        if (rendererIdentifier && *rendererIdentifier != m_decompressionSessionIdentifier)
            return nullptr;
        return std::exchange(m_decompressionSession, nullptr);
    }();

    if (decompressionSession)
        decompressionSession->invalidate();
}

bool AudioVideoRendererAVFObjC::willLog(AudioVideoRendererLogLevel level) const
{
    switch (level) {
    case AudioVideoRendererLogLevel::Performance:
        return LOG_CHANNEL(MediaPerformance).level >= WTFLogLevel::Debug;
    // The logger filters again, and tells its observers.
    case AudioVideoRendererLogLevel::Always:
    case AudioVideoRendererLogLevel::Error:
        return logger().enabled();
    case AudioVideoRendererLogLevel::Debug:
        return logger().enabled() && logChannel().state != WTFLogChannelState::Off && WTFLogLevel::Debug <= logChannel().level;
    }
    return false;
}

void AudioVideoRendererAVFObjC::log(AudioVideoRendererLogLevel level, std::span<const uint8_t> message) const
{
    auto text = String::fromUTF8(message);
    switch (level) {
    case AudioVideoRendererLogLevel::Performance:
        RELEASE_LOG_DEBUG(MediaPerformance, "%{public}s", safePrintfType(text.utf8()));
        return;
    case AudioVideoRendererLogLevel::Always:
        ALWAYS_LOG(LOGIDENTIFIER, text);
        return;
    case AudioVideoRendererLogLevel::Error:
        ERROR_LOG(LOGIDENTIFIER, text);
        return;
    case AudioVideoRendererLogLevel::Debug:
        DEBUG_LOG(LOGIDENTIFIER, text);
        return;
    }
}

WTFLogChannel& AudioVideoRendererAVFObjC::logChannel() const
{
    return LogMedia;
}

String AudioVideoRendererAVFObjC::toString(TrackIdentifier trackId) const
{
    StringBuilder builder;

    builder.append('[');
    if (auto type = typeOf(trackId)) {
        switch (*type) {
        case TrackType::Video:
            builder.append("video:"_s);
            break;
        case TrackType::Audio:
            builder.append("audio:"_s);
            break;
        default:
            builder.append("unknown:"_s);
            break;
        }
    } else
        builder.append("NotFound:"_s);
    builder.append(trackId.loggingString());
    builder.append(']');
    return builder.toString();
}

#if HAVE(SPATIAL_TRACKING_LABEL)
void AudioVideoRendererAVFObjC::setSpatialTrackingInfo(bool prefersSpatialAudioExperience, SoundStageSize soundStage, const String& sceneIdentifier, const String& defaultLabel, const String& label)
{
    if (m_isShutdown)
        return;
    if (m_prefersSpatialAudioExperience == prefersSpatialAudioExperience
        && m_soundStage == soundStage
        && m_sceneIdentifier == sceneIdentifier
        && m_defaultSpatialTrackingLabel == defaultLabel
        && m_spatialTrackingLabel == label)
        return;

    m_prefersSpatialAudioExperience = prefersSpatialAudioExperience;
    m_soundStage = soundStage;
    m_sceneIdentifier = sceneIdentifier;
    m_defaultSpatialTrackingLabel = defaultLabel;
    m_spatialTrackingLabel = label;

    ALWAYS_LOG(LOGIDENTIFIER, "prefersSpatialAudioExperience(", prefersSpatialAudioExperience, "), soundStage(", soundStage, "), sceneIdentifier(", sceneIdentifier, "), defaultLabel(", defaultLabel, "), label(", label, ")");
    updateSpatialTrackingLabel();
}

void AudioVideoRendererAVFObjC::updateSpatialTrackingLabel()
{
    RetainPtr renderer = (AVSampleBufferVideoRenderer *)renderingObject(AudioVideoRendererObject::VideoRendererForTarget, 0) ?: [(AVSampleBufferDisplayLayer *)renderingObject(AudioVideoRendererObject::DisplayLayer, 0) sampleBufferRenderer];

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    if (m_prefersSpatialAudioExperience) {
        RetainPtr experience = createSpatialAudioExperienceWithOptions({
            .hasLayer = !!renderer,
            .hasTarget = !!m_videoTarget,
            .isVisible = m_visible,
            .soundStageSize = m_soundStage,
            .sceneIdentifier = m_sceneIdentifier,
#if HAVE(SPATIAL_TRACKING_LABEL)
            .spatialTrackingLabel = m_spatialTrackingLabel,
#endif
        });
        ALWAYS_LOG(LOGIDENTIFIER, "Setting spatialAudioExperience: ", spatialAudioExperienceDescription(experience.get()));
        [m_synchronizer setIntendedSpatialAudioExperience:experience.get()];
        return;
    }
#endif

    if (!m_spatialTrackingLabel.isNull()) {
        INFO_LOG(LOGIDENTIFIER, "Explicitly set STSLabel: ", m_spatialTrackingLabel);
        [renderer setSTSLabel:m_spatialTrackingLabel.createNSString().get()];
        return;
    }

    if (renderer && m_visible) {
        // Let AVSBRS manage setting the spatial tracking label in its video renderer itself.
        INFO_LOG(LOGIDENTIFIER, "Has visible renderer, set STSLabel: nil");
        [renderer setSTSLabel:nil];
        return;
    }

    RetainPtr audioRenderers = adoptNS(m_core->swift.audioRenderers());
    if (![audioRenderers count]) {
        // If there are no audio renderers, there's nothing to do.
        INFO_LOG(LOGIDENTIFIER, "No audio renderers - no-op");
        return;
    }

    // If there is no video renderer, use the default spatial tracking label if available, or
    // the session's spatial tracking label if not, and set the label directly on each audio
    // renderer.
    AVAudioSession *session = [PAL::getAVAudioSessionClassSingleton() sharedInstance];
    RetainPtr<NSString> defaultLabel;
    if (!m_defaultSpatialTrackingLabel.isNull()) {
        INFO_LOG(LOGIDENTIFIER, "Default STSLabel: ", m_defaultSpatialTrackingLabel);
        defaultLabel = m_defaultSpatialTrackingLabel.createNSString();
    } else {
        INFO_LOG(LOGIDENTIFIER, "AVAudioSession label: ", session.spatialTrackingLabel);
        defaultLabel = session.spatialTrackingLabel;
    }
    for (AVSampleBufferAudioRenderer *audioRenderer in audioRenderers.get())
        [audioRenderer setSTSLabel:defaultLabel.get()];
}
#else
void AudioVideoRendererAVFObjC::updateSpatialTrackingLabel()
{
}
#endif

#if HAVE(AVCONTENTKEYSESSION)
#if ENABLE(ENCRYPTED_MEDIA)
void AudioVideoRendererAVFObjC::setCDMInstance(CDMInstance* instance)
{
    if (m_isShutdown)
        return;
    RefPtr fpsInstance = dynamicDowncast<CDMInstanceFairPlayStreamingAVFObjC>(instance);
    if (fpsInstance == m_cdmInstance)
        return;

    ALWAYS_LOG(LOGIDENTIFIER);
    if (RefPtr cdmInstance = m_cdmInstance)
        cdmInstance->removeKeyStatusesChangedObserver(m_keyStatusesChangedObserver);

    m_cdmInstance = fpsInstance;
    if (fpsInstance)
        fpsInstance->addKeyStatusesChangedObserver(m_keyStatusesChangedObserver);

    attemptToDecrypt();
}

Ref<MediaPromise> AudioVideoRendererAVFObjC::setInitData(Ref<SharedBuffer> initData)
{
    if (m_isShutdown)
        return MediaPromise::createAndReject(PlatformMediaError::Shutdown);
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    m_initData = initData.copyRef();
    if (RefPtr session = m_session.get()) {
        session->setInitData(initData);
        return MediaPromise::createAndResolve();
    }
#endif
    auto keyIDs = CDMPrivateFairPlayStreaming::extractKeyIDsSinf(initData);
#if HAVE(FAIRPLAYSTREAMING_MTPS_INITDATA)
    if (!keyIDs)
        keyIDs = CDMPrivateFairPlayStreaming::extractKeyIDsMpts(initData);
#endif
    if (!keyIDs)
        return MediaPromise::createAndResolve();

    if (RefPtr cdmInstance = m_cdmInstance) {
        if (cdmInstance->hasSessionForKeyIDs(keyIDs.value()))
            return MediaPromise::createAndResolve();
    }

    m_keyIDs = WTF::move(keyIDs.value());
    return MediaPromise::createAndReject(PlatformMediaError::CDMInstanceKeyNeeded);
}

void AudioVideoRendererAVFObjC::attemptToDecrypt()
{
    if (m_isShutdown)
        return;
    if (m_blockedSamples.isEmpty())
        return;
    if (m_cdmInstance && m_keyIDs.isEmpty()) {
        ALWAYS_LOG(LOGIDENTIFIER, "CDMInstance set, but no keyIDs");
        return;
    }

    if (RefPtr cdmInstance = m_cdmInstance) {
        if (!cdmInstance->hasSessionForKeyIDs(m_keyIDs))
            return;
    } else if (!m_session.get())
        return;

    tryToEnqueueBlockedSamples();
}

void AudioVideoRendererAVFObjC::tryToEnqueueBlockedSamples()
{
    while (!m_blockedSamples.isEmpty()) {
        auto& firstPair = m_blockedSamples.first();

        // If we still can't enqueue the sample, bail.
        if (!canEnqueueSample(firstPair.first, firstPair.second))
            return;

        auto firstPairTaken = m_blockedSamples.takeFirst();
        enqueueSample(firstPairTaken.first, WTF::move(firstPairTaken.second), { });
    }
}

bool AudioVideoRendererAVFObjC::canEnqueueSample(TrackIdentifier trackId, const MediaSample& sample)
{
    // if sample is unencrytped: enqueue sample
    if (!sample.isProtected())
        return true;

    // if sample is encrypted, but we are not attached to a CDM: do not enqueue sample.
    if (!m_cdmInstance && !m_session.get())
        return false;

    if (typeOf(trackId) == TrackType::Video && !m_core->swift.isEnabledVideoTrack(trackId.toUInt64()))
        return false;

    Ref sampleAVFObjC = downcast<MediaSampleAVFObjC>(sample);

    // if sample is encrypted, and keyIDs match the current set of keyIDs: enqueue sample.
    if (auto findResult = m_currentTrackIds.find(trackId); findResult != m_currentTrackIds.end() && findResult->value == sampleAVFObjC->keyIDs())
        return true;

    // if sample's set of keyIDs does not match the current set of keyIDs, consult with the CDM
    // to determine if the keyIDs are usable; if so, update the current set of keyIDs and enqueue sample.
    if (RefPtr cdmInstance = m_cdmInstance; cdmInstance && cdmInstance->isAnyKeyUsable(sampleAVFObjC->keyIDs())) {
        m_currentTrackIds.add(trackId, sampleAVFObjC->keyIDs());
        return true;
    }

    if (RefPtr session = m_session.get(); session && session->isAnyKeyUsable(sampleAVFObjC->keyIDs())) {
        m_currentTrackIds.add(trackId, sampleAVFObjC->keyIDs());
        return true;
    }

    ALWAYS_LOG(LOGIDENTIFIER, "Can't enqueue sample: ", sample, ", no CDM with usable keyIDs: ", sampleAVFObjC->keyIDs());
    return false;
}

void AudioVideoRendererAVFObjC::attachContentKeyToSampleIfNeeded(const MediaSample& sample)
{
    if (RefPtr cdmInstance = m_cdmInstance)
        cdmInstance->attachContentKeyToSample(downcast<MediaSampleAVFObjC>(sample));
    else if (RefPtr session = m_session.get())
        session->attachContentKeyToSample(downcast<MediaSampleAVFObjC>(sample));
}
#endif

#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
void AudioVideoRendererAVFObjC::setCDMSession(LegacyCDMSession* session)
{
    if (m_isShutdown)
        return;
    RefPtr oldSession = m_session.get();
    if (session == oldSession)
        return;

    ALWAYS_LOG(LOGIDENTIFIER);

    if (RefPtr oldSession = m_session.get())
        oldSession->removeRenderer(*this);

    m_session = dynamicDowncast<CDMSessionAVContentKeySession>(session);

    if (RefPtr session = m_session.get()) {
        session->addRenderer(*this);
        if (RefPtr initData = m_initData)
            session->setInitData(*initData);
        attemptToDecrypt();
    }
}
#endif
#endif


// AudioVideoRendererHost

Ref<AudioVideoRendererHost> AudioVideoRendererHost::create(AudioVideoRendererAVFObjC& renderer)
{
    return adoptRef(*new AudioVideoRendererHost(renderer));
}

AudioVideoRendererHost::AudioVideoRendererHost(AudioVideoRendererAVFObjC& renderer)
    : m_renderer(renderer)
{
}

AudioVideoRendererHost::~AudioVideoRendererHost() = default;

dispatch_queue_t AudioVideoRendererHost::dispatchQueue() const
{
    return videoRendererQueueSingleton().dispatchQueue();
}

bool AudioVideoRendererHost::willLog(AudioVideoRendererLogLevel level) const
{
    RefPtr renderer = m_renderer.get();
    return renderer && renderer->willLog(level);
}

void AudioVideoRendererHost::log(AudioVideoRendererLogLevel level, WTF::SpanUInt8 message NOESCAPE) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->log(level, message);
}

void AudioVideoRendererHost::storeSharedTimebaseSnapshot(CMTime currentTime, double playbackRate) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->storeSharedTimebaseSnapshot(currentTime, playbackRate);
}

void AudioVideoRendererHost::decodeSample(CMSampleBufferRef sample, uint8_t decodingFlags, uint64_t rendererIdentifier, int32_t flushId) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->decodeSample(sample, decodingFlags, rendererIdentifier, flushId);
}

void AudioVideoRendererHost::invalidateDecompressionSession(uint64_t rendererIdentifier) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->invalidateDecompressionSession(rendererIdentifier);
}

bool AudioVideoRendererHost::isDecompressionSessionHardwareAccelerated() const
{
    RefPtr renderer = m_renderer.get();
    RefPtr decompressionSession = renderer ? renderer->decompressionSession() : nullptr;
    return decompressionSession && decompressionSession->isHardwareAccelerated();
}

void AudioVideoRendererHost::renderingObjectChanged(AudioVideoRendererObject object, NSObject *layerOrRenderer, bool created) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->renderingObjectChanged(object, layerOrRenderer, created);
}

void AudioVideoRendererHost::initializeDecompressionSession(uint64_t rendererIdentifier, uint8_t rendererObject) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->initializeDecompressionSession(rendererIdentifier, rendererObject);
}

void AudioVideoRendererHost::flushDecompressionSession() const
{
    RefPtr renderer = m_renderer.get();
    if (RefPtr decompressionSession = renderer ? renderer->decompressionSession() : nullptr)
        decompressionSession->flush();
}

void AudioVideoRendererHost::shutDownDecompressionSession() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->invalidateDecompressionSession(std::nullopt);
}

bool AudioVideoRendererHost::vp9HardwareDecoderAvailable() const
{
#if ENABLE(VP9)
    return vp9HardwareDecoderAvailableInProcess();
#else
    return false;
#endif
}

void AudioVideoRendererHost::expectMinimumUpcomingPresentationTime(AudioVideoRendererObject object, CMTime time) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->expectMinimumUpcomingPresentationTime(object, time);
}

void AudioVideoRendererHost::updateSpatialTrackingLabel() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->updateSpatialTrackingLabel();
}

void AudioVideoRendererHost::removeBlockedSamples(AudioVideoRendererBlockedSamples which, uint64_t trackIdentifier) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->removeBlockedSamples(which, trackIdentifier);
}


void AudioVideoRendererHost::notifyError(uint8_t error) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->notifyError(static_cast<PlatformMediaError>(error));
}

void AudioVideoRendererHost::firstFrameAvailable() const
{
    if (RefPtr renderer = m_renderer.get(); renderer && renderer->m_firstFrameAvailableCallback)
        renderer->m_firstFrameAvailableCallback();
}

void AudioVideoRendererHost::hasAvailableVideoFrame(CMTime presentationTime, double displayTime) const
{
    if (RefPtr renderer = m_renderer.get(); renderer && renderer->m_hasAvailableVideoFrameCallback)
        renderer->m_hasAvailableVideoFrameCallback(PAL::toMediaTime(presentationTime), displayTime);
}

void AudioVideoRendererHost::requiresFlushToResume() const
{
    if (RefPtr renderer = m_renderer.get(); renderer && renderer->m_notifyWhenRequiresFlushToResume)
        renderer->m_notifyWhenRequiresFlushToResume();
}

void AudioVideoRendererHost::renderingModeChanged() const
{
    if (RefPtr renderer = m_renderer.get(); renderer && renderer->m_renderingModeChangedCallback)
        renderer->m_renderingModeChangedCallback();
}

void AudioVideoRendererHost::sizeChanged(CMTime time, float width, float height) const
{
    if (RefPtr renderer = m_renderer.get(); renderer && renderer->m_sizeChangedCallback)
        renderer->m_sizeChangedCallback(PAL::toMediaTime(time), FloatSize { width, height });
}

void AudioVideoRendererHost::effectiveRateChanged(double rate) const
{
    if (RefPtr renderer = m_renderer.get(); renderer && renderer->m_effectiveRateChangedCallback)
        renderer->m_effectiveRateChangedCallback(rate);
}

void AudioVideoRendererHost::mediaDataRequestSettled(bool isVideo, uint64_t trackIdentifier, bool resolved) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->mediaDataRequestSettled(isVideo, trackIdentifier, resolved);
}

void AudioVideoRendererHost::seekSettled(bool resolved) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->seekSettled(resolved);
}

void AudioVideoRendererHost::timeReached(CMTime) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->timeReached();
}

void AudioVideoRendererHost::performTask(CMTime now) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->performTask(now);
}

void AudioVideoRendererHost::timeObserverFired(CMTime time) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->timeObserverFired(time);
}

void AudioVideoRendererHost::audioRendererWasFlushed(uint64_t trackIdentifier, CMTime flushTime) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->audioRendererWasFlushed(trackIdentifier, flushTime);
}

void AudioVideoRendererHost::hdcpStatusChanged(bool obscured) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->hdcpStatusChanged(obscured);
}

void AudioVideoRendererHost::videoTargetSettled(bool resolved) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->videoTargetSettled(resolved);
}

void addRendererToSynchronizer(AVSampleBufferRenderSynchronizer *synchronizer, NSObject *renderer)
{
    [synchronizer addRenderer:(id<AVQueuedSampleBufferRendering>)renderer];
}

void removeRendererFromSynchronizer(AVSampleBufferRenderSynchronizer *synchronizer, NSObject *renderer, CMTime time)
{
    [synchronizer removeRenderer:(id<AVQueuedSampleBufferRendering>)renderer atTime:time completionHandler:nil];
}

} // namespace WebCore
