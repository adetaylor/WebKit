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
#import "EffectiveRateChangedListener.h"
#import "FormatDescriptionUtilities.h"
#import "FrameRateMonitor.h"
#import "GraphicsContext.h"
#import "IOSurface.h"
#import "LayoutRect.h"
#import "Logging.h"
#import "MediaPlayerPrivate.h"
#import "MediaSampleAVFObjC.h"
#import "MediaSessionManagerCocoa.h"
#import "NativeImage.h"
#import "PeriodicSharedTimer.h"
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

@interface AVSampleBufferDisplayLayer (Staging_100128644)
@property (assign, nonatomic) BOOL preventsAutomaticBackgroundingDuringVideoPlayback;
@end

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

#if HAVE(RECOMMENDED_PIXEL_ATTRIBUTES_API)
@interface AVSampleBufferVideoRenderer (Staging_152246223)
@property (readonly, nonnull) NSDictionary<NSString*, NS_SWIFT_SENDABLE id> *recommendedPixelBufferAttributes;
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
// And its TrackInfoTrackType values.
static_assert(static_cast<uint8_t>(TrackInfoTrackType::Audio) == 1);
static_assert(static_cast<uint8_t>(TrackInfoTrackType::Video) == 2);

static PeriodicSharedTimer& sharedTimebaseTimer()
{
    static NeverDestroyed<PeriodicSharedTimer> timer { 100_ms };
    return timer.get();
}

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
    , m_frameRateMonitor(makeUnique<FrameRateMonitor>([](auto info) {
        RELEASE_LOG_ERROR(MediaPerformance, "VideoMediaSampleRenderer Frame decoding allowance exceeded:%f expected:%f", Seconds { info.lastFrameTime - info.frameTime }.value(), 1 / info.observedFrameRate);
    }))
#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    , m_keyStatusesChangedObserver(Observer<void()>::create([weakThis = ThreadSafeWeakPtr { *this }] {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->tryToEnqueueBlockedSamples();
    }))
#endif
{
    AudioVideoRendererConfiguration configuration {
        PAL::toCMTime(VideoDecodeWindow::lowWaterMark),
        PAL::toCMTime(VideoDecodeWindow::highWaterMark),
        VideoDecodeWindow::sampleQueueHighWaterMark,
        VideoDecodeWindow::sampleQueueLowWaterMark,
        !!m_sharedTimebase
    };
    m_core = makeUnique<Core>(AudioVideoRendererCore::init(AudioVideoRendererHost::create(*this).ptr(), m_synchronizer.get(), configuration));
    stall();
}

AudioVideoRendererAVFObjC::~AudioVideoRendererAVFObjC()
{
    if (std::exchange(m_registeredWithSharedTimer, false))
        sharedTimebaseTimer().removeClient(*this);
    if (RefPtr rateChangeListener = std::exchange(m_effectiveRateChangedListener, { }))
        rateChangeListener->stop();
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

void AudioVideoRendererAVFObjC::setPreferences(VideoRendererPreferences preferences)
{
    if (m_isShutdown)
        return;
    m_core->swift.setPreferences(preferences.toRaw());
}

void AudioVideoRendererAVFObjC::setHasProtectedVideoContent(bool protectedContent)
{
    if (m_isShutdown)
        return;
    m_core->swift.setHasProtectedVideoContent(protectedContent);
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
        info.isDependedOnByOthers = isDependedOnByOthers(cmSampleBuffer.get());
    }
    info.isNonDisplaying = sample->isNonDisplaying();
    m_core->swift.enqueueSample(trackId.toUInt64(), cmSampleBuffer.get(), info);
}

bool AudioVideoRendererAVFObjC::isReadyForMoreSamples(TrackIdentifier trackId)
{
    return m_core->swift.isReadyForMoreSamples(trackId.toUInt64());
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

void AudioVideoRendererAVFObjC::flush()
{
    if (m_isShutdown)
        return;
    m_core->swift.flush();
}

void AudioVideoRendererAVFObjC::flushTrack(TrackIdentifier trackId)
{
    if (m_isShutdown)
        return;
    m_core->swift.flushTrack(trackId.toUInt64());
}

void AudioVideoRendererAVFObjC::applicationWillResignActive()
{
    if (m_isShutdown)
        return;
    m_core->swift.applicationWillResignActive();
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

uint64_t AudioVideoRendererAVFObjC::swiftToken() const
{
    return m_core->swift.token();
}

// Synchronizer interface
void AudioVideoRendererAVFObjC::play(std::optional<MonotonicTime> hostTime)
{
    if (m_isShutdown)
        return;
    m_core->swift.play(!!hostTime, hostTime ? hostTime->toMachAbsoluteTime() : 0);
}

void AudioVideoRendererAVFObjC::pause(std::optional<MonotonicTime> hostTime)
{
    if (m_isShutdown)
        return;
    m_core->swift.pause(!!hostTime, hostTime ? hostTime->toMachAbsoluteTime() : 0);
}

bool AudioVideoRendererAVFObjC::paused() const
{
    return m_core->swift.paused();
}

bool AudioVideoRendererAVFObjC::timeIsProgressing() const
{
    return m_core->swift.timeIsProgressing();
}

MediaTime AudioVideoRendererAVFObjC::currentTime() const
{
    ASSERT(isMainThread());
    if (m_core->swift.seeking())
        return m_lastSeekTargetTime;
    return PAL::toMediaTime(m_core->swift.currentTime());
}

void AudioVideoRendererAVFObjC::setRate(double rate)
{
    if (m_isShutdown)
        return;
    if (m_rate != rate) {
        m_rate = rate;
        for (auto& renderer : m_audioRenderers.values())
            applyAudioTimePitchAlgorithm(renderer.get());
    }
    m_core->swift.setRate(rate);
}

double AudioVideoRendererAVFObjC::effectiveRate() const
{
    return m_core->swift.effectiveRate();
}

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

void AudioVideoRendererAVFObjC::setSharedTimerActive(bool active)
{
    if (!m_sharedTimebase)
        return;
    if (active && !m_registeredWithSharedTimer) {
        m_registeredWithSharedTimer = true;
        sharedTimebaseTimer().addClient(*this);
    } else if (!active && m_registeredWithSharedTimer) {
        m_registeredWithSharedTimer = false;
        sharedTimebaseTimer().removeClient(*this);
    }
}

void AudioVideoRendererAVFObjC::periodicSharedTimerFired()
{
    ASSERT(m_sharedTimebase);
    m_core->swift.publishFromSharedTimer();
}

void AudioVideoRendererAVFObjC::stall()
{
    if (m_isShutdown)
        return;
    m_core->swift.stall();
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
    m_timeObserverCallback = WTF::move(callback);
    m_core->swift.setTimeObserver(PAL::toCMTime(MediaTime::createWithSeconds(interval)), !!m_timeObserverCallback);
}

void AudioVideoRendererAVFObjC::timeObserverFired(CMTime time)
{
    if (m_timeObserverCallback)
        m_timeObserverCallback(PAL::toMediaTime(time));
}

void AudioVideoRendererAVFObjC::cancelTimeObserver()
{
    m_core->swift.cancelTimeObserver();
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
    // False positive see webkit.org/b/298024
    SUPPRESS_UNRETAINED_ARG m_effectiveRateChangedListener = EffectiveRateChangedListener::create([weakThis = ThreadSafeWeakPtr { *this }](double rate) mutable {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->m_core->swift.effectiveRateChanged(rate);
    }, [m_synchronizer timebase]);
}

bool AudioVideoRendererAVFObjC::seeking() const
{
    return m_core->swift.seeking();
}

void AudioVideoRendererAVFObjC::setScreenReserved(bool reserved)
{
    if (m_isShutdown)
        return;
    setSynchronizerScreenReserved(m_synchronizer.get(), reserved);
}

void AudioVideoRendererAVFObjC::setVolume(float volume)
{
    if (m_isShutdown)
        return;
    m_volume = volume;
    for (auto& renderer : m_audioRenderers.values())
        [renderer setVolume:volume];
}

void AudioVideoRendererAVFObjC::setMuted(bool muted)
{
    if (m_isShutdown)
        return;
    m_muted = muted;
    for (auto& renderer : m_audioRenderers.values())
        [renderer setMuted:muted];
}

void AudioVideoRendererAVFObjC::setPreservesPitchAndCorrectionAlgorithm(bool preservesPitch, std::optional<PitchCorrectionAlgorithm> pitchCorrectionAlgorithm)
{
    if (m_isShutdown)
        return;
    m_preservesPitch = preservesPitch;
    m_pitchCorrectionAlgorithm = pitchCorrectionAlgorithm;
    for (auto& renderer : m_audioRenderers.values())
        applyAudioTimePitchAlgorithm(renderer.get());
}

void AudioVideoRendererAVFObjC::applyAudioTimePitchAlgorithm(AVSampleBufferAudioRenderer *audioRenderer) const
{
    RetainPtr algorithm = MediaSessionManagerCocoa::audioTimePitchAlgorithmForMediaPlayerPitchCorrectionAlgorithm(m_pitchCorrectionAlgorithm.value_or(PitchCorrectionAlgorithm::BestAllAround), m_preservesPitch, m_rate).createNSString();
    [audioRenderer setAudioTimePitchAlgorithm:algorithm.get()];
}

#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
void AudioVideoRendererAVFObjC::setOutputDeviceId(const String& outputDeviceId)
{
    if (m_isShutdown)
        return;
    m_audioOutputDeviceId = outputDeviceId;
    if (!outputDeviceId)
        return;
    for (auto& renderer : m_audioRenderers.values())
        setOutputDeviceIdOnRenderer(renderer.get());
}

void AudioVideoRendererAVFObjC::setOutputDeviceIdOnRenderer(AVSampleBufferAudioRenderer *renderer)
{
    if (m_audioOutputDeviceId.isEmpty() || m_audioOutputDeviceId == AudioMediaStreamTrackRenderer::defaultDeviceID()) {
        // FIXME(rdar://155986053): Remove the @try/@catch when this exception is resolved.
        @try {
            [renderer setAudioOutputDeviceUniqueID:nil];
        } @catch(NSException *exception) {
            ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferAudioRenderer setAudioOutputDeviceUniqueID:] threw an exception: ", exception.name, ", reason : ", exception.reason);
        }
    } else
        [renderer setAudioOutputDeviceUniqueID:m_audioOutputDeviceId.createNSString().get()];
}
#endif

void AudioVideoRendererAVFObjC::setIsVisible(bool visible)
{
    if (m_isShutdown)
        return;
    if (m_visible == visible)
        return;
    m_visible = visible;
    updateSpatialTrackingLabel();
}

void AudioVideoRendererAVFObjC::setPresentationSize(const IntSize& newSize)
{
    if (m_isShutdown)
        return;
    m_presentationSize = newSize;
}

void AudioVideoRendererAVFObjC::setShouldMaintainAspectRatio(bool shouldMaintainAspectRatio)
{
    if (m_isShutdown)
        return;
    if (m_shouldMaintainAspectRatio == shouldMaintainAspectRatio)
        return;

    m_shouldMaintainAspectRatio = shouldMaintainAspectRatio;
    if (!m_sampleBufferDisplayLayer)
        return;

    [CATransaction begin];
    [CATransaction setAnimationDuration:0];
    [CATransaction setDisableActions:YES];

    // False positive see webkit.org/b/298035
    SUPPRESS_UNRETAINED_ARG [m_sampleBufferDisplayLayer setVideoGravity: (m_shouldMaintainAspectRatio ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResize)];

    [CATransaction commit];
}

void AudioVideoRendererAVFObjC::renderingCanBeAcceleratedChanged(bool isAccelerated)
{
    if (m_isShutdown)
        return;
    m_core->swift.renderingCanBeAcceleratedChanged(isAccelerated);
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

void AudioVideoRendererAVFObjC::setShouldDisableHDR(bool shouldDisable)
{
    if (m_isShutdown)
        return;
    m_shouldDisableHDR = shouldDisable;
    if (![m_sampleBufferDisplayLayer respondsToSelector:@selector(setToneMapToStandardDynamicRange:)])
        return;

    ALWAYS_LOG(LOGIDENTIFIER, shouldDisable);
    [m_sampleBufferDisplayLayer setToneMapToStandardDynamicRange:shouldDisable];
}

void AudioVideoRendererAVFObjC::setPlatformDynamicRangeLimit(const PlatformDynamicRangeLimit& platformDynamicRangeLimit)
{
    if (m_isShutdown)
        return;
    m_dynamicRangeLimit = platformDynamicRangeLimit;

    if (!m_sampleBufferDisplayLayer)
        return;

    setLayerDynamicRangeLimit(m_sampleBufferDisplayLayer.get(), platformDynamicRangeLimit);
}

void AudioVideoRendererAVFObjC::setResourceOwner(const ProcessIdentity& resourceOwner)
{
    if (m_isShutdown)
        return;
    m_resourceOwner = resourceOwner;
    m_core->swift.setHasResourceOwner(!!resourceOwner);
}

auto AudioVideoRendererAVFObjC::copyDisplayedPixelBuffer() const -> DisplayedPixelBuffer
{
    assertIsMainThread();

    auto metrics = m_core->swift.videoMetrics();
    if (!metrics.hasVideoRenderer)
        return { };

    auto copyFromRenderer = [&] -> DisplayedPixelBuffer {
        if (!metrics.hasRenderer)
            return { };
        RetainPtr renderer = (WebSampleBufferVideoRendering *)renderingObject(static_cast<AudioVideoRendererObject>(metrics.rendererObject), 0);
        RetainPtr buffer = adoptCF([renderer copyDisplayedPixelBuffer]);
        if (RetainPtr surface = CVPixelBufferGetIOSurface(buffer.get()); surface && m_resourceOwner)
            IOSurface::setOwnershipIdentity(surface.get(), m_resourceOwner);
        return { WTF::move(buffer), MediaTime::invalidTime() };
    };

    if (!metrics.managesDecodedFrames)
        return copyFromRenderer();

    RetainPtr decodedSample = adoptCF(m_core->swift.copyDecodedSample());
    RetainPtr imageBuffer = decodedSample ? imageForSample(decodedSample.get()) : nullptr;
    if (!imageBuffer) {
        // Compressed samples enqueued after decoded ones are not in the decoded queue.
        if (!metrics.usingDecompressionSession)
            return copyFromRenderer();
        return { nullptr, MediaTime::invalidTime() };
    }

    ASSERT(CFGetTypeID(imageBuffer.get()) == CVPixelBufferGetTypeID());
    if (CFGetTypeID(imageBuffer.get()) != CVPixelBufferGetTypeID())
        return { nullptr, MediaTime::invalidTime() };
    return { WTF::move(imageBuffer), PAL::toMediaTime(m_core->swift.lastCopiedPresentationTime()) };
}

RefPtr<VideoFrame> AudioVideoRendererAVFObjC::currentVideoFrame() const
{
    auto entry = copyDisplayedPixelBuffer();
    if (!entry.pixelBuffer)
        return nullptr;

    return VideoFrameCV::create(entry.presentationTimeStamp, false, VideoFrame::Rotation::None, entry.pixelBuffer.get());
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
    auto metrics = m_core->swift.videoMetrics();
    if (!metrics.hasVideoRenderer)
        return std::nullopt;

    if (metrics.managesDecodedFrames && !metrics.decompressionSessionBlocked) {
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
    RetainPtr renderer = metrics.hasRenderer ? (WebSampleBufferVideoRendering *)renderingObject(static_cast<AudioVideoRendererObject>(metrics.rendererObject), 0) : nil;
    RetainPtr rendererMetrics = [renderer videoPerformanceMetrics];
    return VideoPlaybackQualityMetrics {
        static_cast<uint32_t>([rendererMetrics totalNumberOfVideoFrames]),
        static_cast<uint32_t>([rendererMetrics numberOfDroppedVideoFrames] + metrics.droppedVideoFramesOffset),
        static_cast<uint32_t>([rendererMetrics numberOfCorruptedVideoFrames] + metrics.corruptedVideoFrames),
        [rendererMetrics totalFrameDelay],
        m_core->swift.totalDisplayedFrames()
    };
#endif
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

void AudioVideoRendererAVFObjC::isInFullscreenOrPictureInPictureChanged(bool isInFullscreenOrPictureInPicture)
{
#if ENABLE(LINEAR_MEDIA_PLAYER)
    if (m_isShutdown)
        return;
    ALWAYS_LOG(LOGIDENTIFIER, isInFullscreenOrPictureInPicture);
    destroyExpiringVideoRenderers();
#else
    UNUSED_PARAM(isInFullscreenOrPictureInPicture);
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

void AudioVideoRendererAVFObjC::setNeedsPlaceholderImage(bool needsPlaceholder)
{
    if (m_needsPlaceholderImage == needsPlaceholder)
        return;
    m_needsPlaceholderImage = needsPlaceholder;

    if (m_needsPlaceholderImage)
        [m_sampleBufferDisplayLayer setContents:(id)m_lastPixelBuffer.get()];
    else
        [m_sampleBufferDisplayLayer setContents:nil];
}

// The renderers.

NSObject *AudioVideoRendererAVFObjC::renderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    switch (object) {
    case AudioVideoRendererObject::DisplayLayer:
        return m_sampleBufferDisplayLayer.get();
    case AudioVideoRendererObject::VideoRendererForTarget:
        return trackIdentifier ? m_expiredVideoRendererPendingRemoval.get() : m_sampleBufferVideoRenderer.get();
    case AudioVideoRendererObject::AudioRenderer:
        return m_audioRenderers.get(trackIdentifier);
    }
    return nil;
}

bool AudioVideoRendererAVFObjC::createRenderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier)
{
    switch (object) {
    case AudioVideoRendererObject::DisplayLayer: {
        m_sampleBufferDisplayLayer = adoptNS([PAL::allocAVSampleBufferDisplayLayerInstance() init]);
        if (!m_sampleBufferDisplayLayer) {
            ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferDisplayLayer init] returned nil! bailing!");
            ASSERT_NOT_REACHED();
            reportError(PlatformMediaError::VideoDecodingError);
            return false;
        }
        [m_sampleBufferDisplayLayer setName:@"AudioVideoRendererAVFObjC AVSampleBufferDisplayLayer"];
        // False positive see webkit.org/b/298035
        SUPPRESS_UNRETAINED_ARG [m_sampleBufferDisplayLayer setVideoGravity:(m_shouldMaintainAspectRatio ? AVLayerVideoGravityResizeAspect : AVLayerVideoGravityResize)];
        RetainPtr renderer = (WebSampleBufferVideoRendering *)m_sampleBufferDisplayLayer.get();
        [renderer setPreventsDisplaySleepDuringVideoPlayback:NO];
        if ([m_sampleBufferDisplayLayer respondsToSelector:@selector(setPreventsAutomaticBackgroundingDuringVideoPlayback:)])
            [m_sampleBufferDisplayLayer setPreventsAutomaticBackgroundingDuringVideoPlayback:NO];

        if ([m_sampleBufferDisplayLayer respondsToSelector:@selector(setToneMapToStandardDynamicRange:)])
            [m_sampleBufferDisplayLayer setToneMapToStandardDynamicRange:m_shouldDisableHDR];

        setLayerDynamicRangeLimit(m_sampleBufferDisplayLayer.get(), m_dynamicRangeLimit);

        m_videoLayerManager->setVideoLayer(m_sampleBufferDisplayLayer.get(), m_presentationSize);
        return true;
    }
    case AudioVideoRendererObject::VideoRendererForTarget:
#if ENABLE(LINEAR_MEDIA_PLAYER)
        m_sampleBufferVideoRenderer = adoptNS([PAL::allocAVSampleBufferVideoRendererInstance() init]);
        if (!m_sampleBufferVideoRenderer) {
            ERROR_LOG(LOGIDENTIFIER, "-[VSampleBufferVideoRenderer init] returned nil! bailing!");
            ASSERT_NOT_REACHED();
            reportError(PlatformMediaError::VideoDecodingError);
            return false;
        }

        [m_sampleBufferVideoRenderer addVideoTarget:m_videoTarget.get()];
        {
            RetainPtr renderer = (WebSampleBufferVideoRendering *)m_sampleBufferVideoRenderer.get();
            [renderer setPreventsDisplaySleepDuringVideoPlayback:NO];
            if ([renderer respondsToSelector:@selector(setPreventsAutomaticBackgroundingDuringVideoPlayback:)])
                [renderer setPreventsAutomaticBackgroundingDuringVideoPlayback:NO];
        }
        return true;
#else
        return false;
#endif
    case AudioVideoRendererObject::AudioRenderer: {
        RetainPtr renderer = adoptNS([PAL::allocAVSampleBufferAudioRendererInstance() init]);

        if (!renderer) {
            ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferAudioRenderer init] returned nil! bailing!");
            ASSERT_NOT_REACHED();

            reportError(PlatformMediaError::AudioDecodingError);
            return false;
        }

        [renderer setMuted:m_muted];
        [renderer setVolume:m_volume];
        applyAudioTimePitchAlgorithm(renderer.get());

#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
        if (!!m_audioOutputDeviceId)
            setOutputDeviceIdOnRenderer(renderer.get());
#endif

        @try {
            [m_synchronizer addRenderer:renderer.get()];
        } @catch(NSException *exception) {
            ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferRenderSynchronizer addRenderer:] threw an exception: ", exception.name, ", reason : ", exception.reason);
            ASSERT_NOT_REACHED();

            reportError(PlatformMediaError::AudioDecodingError);
            return false;
        }

        m_audioRenderers.set(trackIdentifier, WTF::move(renderer));
        return true;
    }
    }
    return false;
}

void AudioVideoRendererAVFObjC::destroyRenderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier)
{
    switch (object) {
    case AudioVideoRendererObject::DisplayLayer:
        m_videoLayerManager->didDestroyVideoLayer();
        m_sampleBufferDisplayLayer = nullptr;
        return;
    case AudioVideoRendererObject::VideoRendererForTarget:
#if ENABLE(LINEAR_MEDIA_PLAYER)
        if ([m_sampleBufferVideoRenderer respondsToSelector:@selector(removeAllVideoTargets)])
            [m_sampleBufferVideoRenderer removeAllVideoTargets];
#endif
        m_sampleBufferVideoRenderer = nullptr;
        return;
    case AudioVideoRendererObject::AudioRenderer:
        m_audioRenderers.remove(trackIdentifier);
        return;
    }
}

void AudioVideoRendererAVFObjC::expireVideoRendererForTarget()
{
    m_expiringSampleBufferVideoRenderers.append(m_sampleBufferVideoRenderer);
    m_expiredVideoRendererPendingRemoval = std::exchange(m_sampleBufferVideoRenderer, { });
}

void AudioVideoRendererAVFObjC::destroyExpiringVideoRenderers()
{
#if ENABLE(LINEAR_MEDIA_PLAYER)
    for (RetainPtr renderer : std::exchange(m_expiringSampleBufferVideoRenderers, { }))
        [renderer removeAllVideoTargets];
#endif
}

bool AudioVideoRendererAVFObjC::addToSynchronizer(AudioVideoRendererObject object, uint64_t trackIdentifier)
{
    RetainPtr renderer = (id<AVQueuedSampleBufferRendering>)renderingObject(object, trackIdentifier);
    @try {
        [m_synchronizer addRenderer:renderer.get()];
    } @catch(NSException *exception) {
        ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferRenderSynchronizer addRenderer:] threw an exception: ", exception.name, ", reason : ", exception.reason);
        ASSERT_NOT_REACHED();

        reportError(PlatformMediaError::DecoderCreationError);
        return false;
    }
    return true;
}

void AudioVideoRendererAVFObjC::removeFromSynchronizer(AudioVideoRendererObject object, uint64_t trackIdentifier)
{
    RetainPtr renderer = (id<AVQueuedSampleBufferRendering>)renderingObject(object, trackIdentifier);
    // False positive see webkit.org/b/298024
    SUPPRESS_UNRETAINED_ARG CMTime currentTime = PAL::CMTimebaseGetTime([m_synchronizer timebase]);
    [m_synchronizer removeRenderer:renderer.get() atTime:currentTime completionHandler:nil];
    if (object == AudioVideoRendererObject::VideoRendererForTarget && trackIdentifier)
        m_expiredVideoRendererPendingRemoval = nullptr;
}

uint32_t AudioVideoRendererAVFObjC::rendererDroppedVideoFrames(AudioVideoRendererObject object) const
{
#if PLATFORM(WATCHOS)
    UNUSED_PARAM(object);
    return std::numeric_limits<uint32_t>::max();
#else
    RetainPtr renderer = (WebSampleBufferVideoRendering *)renderingObject(object, 0);
    return [renderer videoPerformanceMetrics].numberOfDroppedVideoFrames;
#endif
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

// The video renderer's timebase timer and decompression session.

void AudioVideoRendererAVFObjC::setVideoRendererTimebase(bool hasTimebase, uint64_t rendererIdentifier)
{
    // False positive see webkit.org/b/298024
    SUPPRESS_UNRETAINED_ARG RetainPtr timebase = [m_synchronizer timebase];
    if (!hasTimebase) {
        OSObjectPtr<dispatch_source_t> timerSource;
        {
            Locker locker { m_videoRendererLock };
            if (m_videoRendererTimebaseIdentifier != rendererIdentifier)
                return;
            timerSource = std::exchange(m_videoRendererTimerSource, nullptr);
            m_videoRendererTimebaseIdentifier = 0;
        }
        if (timerSource) {
            PAL::CMTimebaseRemoveTimerDispatchSource(timebase.get(), timerSource.get());
            dispatch_source_cancel(timerSource.get());
        }
        if (RefPtr listener = std::exchange(m_videoRendererRateListener, nullptr))
            listener->stop();
        return;
    }

    OSObjectPtr timerSource = adoptOSObject(dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, protect(videoRendererQueueSingleton().dispatchQueue())));
    dispatch_source_set_event_handler(timerSource.get(), [weakThis = ThreadSafeWeakPtr { *this }, rendererIdentifier] {
        if (RefPtr protectedThis = weakThis)
            protectedThis->m_core->swift.purgeDecodedSampleQueue(rendererIdentifier);
    });
    dispatch_activate(timerSource.get());
    PAL::CMTimebaseAddTimerDispatchSource(timebase.get(), timerSource.get());
    m_videoRendererRateListener = EffectiveRateChangedListener::create([weakThis = ThreadSafeWeakPtr { *this }, rendererIdentifier](double rate) {
        videoRendererQueueSingleton().dispatch([weakThis, rate, rendererIdentifier] {
            if (RefPtr protectedThis = weakThis; protectedThis && rate)
                protectedThis->m_core->swift.purgeDecodedSampleQueue(rendererIdentifier);
        });
    }, timebase.get());

    Locker locker { m_videoRendererLock };
    m_videoRendererTimerSource = WTF::move(timerSource);
    m_videoRendererTimebaseIdentifier = rendererIdentifier;
}

bool AudioVideoRendererAVFObjC::hasVideoRendererTimebase() const
{
    Locker locker { m_videoRendererLock };
    return !!m_videoRendererTimerSource;
}

void AudioVideoRendererAVFObjC::setVideoRendererPurgeTimerFireTime(CMTime fireTime)
{
    OSObjectPtr<dispatch_source_t> timerSource;
    {
        Locker locker { m_videoRendererLock };
        timerSource = m_videoRendererTimerSource;
    }
    if (!timerSource)
        return;
    // False positive see webkit.org/b/298024
    SUPPRESS_UNRETAINED_ARG PAL::CMTimebaseSetTimerDispatchSourceNextFireTime([m_synchronizer timebase], timerSource.get(), fireTime, 0);
}

RefPtr<WebCoreDecompressionSession> AudioVideoRendererAVFObjC::decompressionSession() const
{
    Locker locker { m_videoRendererLock };
    return m_decompressionSession;
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
    m_decompressionSessionIdentifier = rendererIdentifier;
}

void AudioVideoRendererAVFObjC::decodeSample(CMSampleBufferRef sample, uint8_t decodingFlags, uint64_t rendererIdentifier, int32_t flushId)
{
    assertIsCurrent(videoRendererQueueSingleton());

    RefPtr<WebCoreDecompressionSession> decompressionSession;
    {
        Locker locker { m_videoRendererLock };
        if (m_decompressionSessionIdentifier == rendererIdentifier)
            decompressionSession = m_decompressionSession;
    }
    if (!decompressionSession) {
        videoRendererQueueSingleton().dispatch([weakThis = ThreadSafeWeakPtr { *this }, rendererIdentifier, flushId] {
            if (RefPtr protectedThis = weakThis)
                protectedThis->m_core->swift.decodeCompleted(rendererIdentifier, flushId, false, noErr, nil);
        });
        return;
    }

    decompressionSession->decodeSample(sample, WebCoreDecompressionSession::DecodingFlags::fromRaw(decodingFlags))->whenSettled(videoRendererQueueSingleton(), [weakThis = ThreadSafeWeakPtr { *this }, rendererIdentifier, flushId](WebCoreDecompressionSession::DecodingPromise::Result&& result) {
        RefPtr protectedThis = weakThis;
        if (!protectedThis)
            return;

        assertIsCurrent(videoRendererQueueSingleton());

        if (!result) {
            protectedThis->m_core->swift.decodeCompleted(rendererIdentifier, flushId, false, result.error(), nil);
            return;
        }
        RetainPtr frames = adoptNS([[NSMutableArray alloc] initWithCapacity:result->size()]);
        for (auto& decodedFrame : *result) {
            if (decodedFrame)
                [frames addObject:(__bridge id)decodedFrame.get()];
        }
        protectedThis->m_core->swift.decodeCompleted(rendererIdentifier, flushId, true, noErr, frames.get());
    });
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

double AudioVideoRendererAVFObjC::updateFrameRateMonitor()
{
    m_frameRateMonitor->update();
    return m_frameRateMonitor->observedFrameRate();
}

void AudioVideoRendererAVFObjC::assignResourceOwner(CMSampleBufferRef sample)
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
    RetainPtr renderer = m_sampleBufferVideoRenderer ? m_sampleBufferVideoRenderer.get() : [m_sampleBufferDisplayLayer sampleBufferRenderer];

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

    if (m_audioRenderers.isEmpty()) {
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
    for (auto& pair : m_audioRenderers)
        [(__bridge AVSampleBufferAudioRenderer *)pair.value.get() setSTSLabel:defaultLabel.get()];
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

bool AudioVideoRendererHost::hasTimebase() const
{
    RefPtr renderer = m_renderer.get();
    return renderer && renderer->hasVideoRendererTimebase();
}

CMTime AudioVideoRendererHost::timebaseTime() const
{
    if (RefPtr renderer = m_renderer.get())
        return PAL::CMTimebaseGetTime([renderer->m_synchronizer timebase]);
    return PAL::kCMTimeInvalid;
}

double AudioVideoRendererHost::timebaseRate() const
{
    if (RefPtr renderer = m_renderer.get())
        return PAL::CMTimebaseGetRate([renderer->m_synchronizer timebase]);
    return 0;
}

void AudioVideoRendererHost::setPurgeTimerFireTime(CMTime fireTime) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->setVideoRendererPurgeTimerFireTime(fireTime);
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

double AudioVideoRendererHost::frameRateMonitorUpdate() const
{
    RefPtr renderer = m_renderer.get();
    return renderer ? renderer->updateFrameRateMonitor() : 0;
}

void AudioVideoRendererHost::assignResourceOwner(CMSampleBufferRef sample) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->assignResourceOwner(sample);
}

NSObject *AudioVideoRendererHost::renderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    RefPtr renderer = m_renderer.get();
    return renderer ? renderer->renderingObject(object, trackIdentifier) : nil;
}

bool AudioVideoRendererHost::createRenderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    RefPtr renderer = m_renderer.get();
    return renderer && renderer->createRenderingObject(object, trackIdentifier);
}

void AudioVideoRendererHost::destroyRenderingObject(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->destroyRenderingObject(object, trackIdentifier);
}

void AudioVideoRendererHost::expireVideoRendererForTarget() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->expireVideoRendererForTarget();
}

void AudioVideoRendererHost::destroyExpiringVideoRenderers() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->destroyExpiringVideoRenderers();
}

bool AudioVideoRendererHost::addToSynchronizer(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    RefPtr renderer = m_renderer.get();
    return renderer && renderer->addToSynchronizer(object, trackIdentifier);
}

void AudioVideoRendererHost::removeFromSynchronizer(AudioVideoRendererObject object, uint64_t trackIdentifier) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->removeFromSynchronizer(object, trackIdentifier);
}

void AudioVideoRendererHost::setVideoRendererTimebase(bool hasTimebase, uint64_t rendererIdentifier) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->setVideoRendererTimebase(hasTimebase, rendererIdentifier);
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

void AudioVideoRendererHost::updateLastPixelBuffer() const
{
    RefPtr renderer = m_renderer.get();
    if (!renderer || !renderer->m_core)
        return;
    auto entry = renderer->copyDisplayedPixelBuffer();
    if (!entry.pixelBuffer)
        return;
    INFO_LOG_WITH_THIS(renderer, LOGIDENTIFIER_WITH_THIS(renderer), "displayed pixelbuffer copied for time: ", entry.presentationTimeStamp);
    renderer->m_lastPixelBuffer = WTF::move(entry.pixelBuffer);
}

void AudioVideoRendererHost::purgeLastPixelBuffer() const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->m_lastPixelBuffer = nullptr;
}

void AudioVideoRendererHost::setNeedsPlaceholderImage(bool needsPlaceholder) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->setNeedsPlaceholderImage(needsPlaceholder);
}

void AudioVideoRendererHost::setSharedTimerActive(bool active) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->setSharedTimerActive(active);
}

void AudioVideoRendererHost::removeBlockedSamples(AudioVideoRendererBlockedSamples which, uint64_t trackIdentifier) const
{
    if (RefPtr renderer = m_renderer.get())
        renderer->removeBlockedSamples(which, trackIdentifier);
}

uint32_t AudioVideoRendererHost::rendererDroppedVideoFrames(AudioVideoRendererObject object) const
{
    RefPtr renderer = m_renderer.get();
    return renderer ? renderer->rendererDroppedVideoFrames(object) : 0;
}

AudioVideoRendererPlaybackQualityMetrics AudioVideoRendererHost::videoPlaybackQualityMetrics() const
{
    RefPtr renderer = m_renderer.get();
    if (!renderer)
        return { };
    auto metrics = renderer->videoPlaybackQualityMetrics();
    if (!metrics)
        return { };
    return { metrics->totalVideoFrames, metrics->droppedVideoFrames, metrics->corruptedVideoFrames, metrics->totalFrameDelay, metrics->displayCompositedVideoFrames, true };
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

} // namespace WebCore
