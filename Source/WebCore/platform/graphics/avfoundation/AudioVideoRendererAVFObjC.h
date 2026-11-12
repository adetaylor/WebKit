/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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

#include <CoreMedia/CMTime.h>
#include <WebCore/AudioVideoRenderer.h>
#include <WebCore/PeriodicSharedTimer.h>
#include <WebCore/PlatformDynamicRangeLimit.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/TrackInfo.h>
#include <wtf/Deque.h>
#include <wtf/Forward.h>
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/LoggerHelper.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RetainPtr.h>
#include <wtf/StdUnorderedMap.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/darwin/DispatchOSObject.h>

OBJC_CLASS AVSampleBufferAudioRenderer;
OBJC_CLASS AVSampleBufferDisplayLayer;
OBJC_CLASS AVSampleBufferRenderSynchronizer;
OBJC_CLASS AVSampleBufferVideoRenderer;
OBJC_CLASS NSObject;
OBJC_PROTOCOL(WebSampleBufferVideoRendering);
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer *CVPixelBufferRef;
typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;

namespace WebCore {

class AudioVideoRendererHost;
class CDMInstanceFairPlayStreamingAVFObjC;
class CDMSessionAVContentKeySession;
class EffectiveRateChangedListener;
class FrameRateMonitor;
class MediaSample;
class NativeImage;
class PixelBufferConformerCV;
class SharedTimebase;
class VideoLayerManagerObjC;
class WebCoreDecompressionSession;
enum class AudioVideoRendererBlockedSamples : uint8_t;
enum class AudioVideoRendererLogLevel : uint8_t;
enum class AudioVideoRendererObject : uint8_t;

// The C++ side of the audio and video renderer: what AudioVideoRenderer's clients call. The tracks, the synchronizer's
// rate and time, seeking, readiness and the video sample renderer are AudioVideoRendererAVFObjC.swift's; this keeps the
// clients' callbacks and promises, the shared timebase, the synchronizer and the renderers it makes and configures,
// the layer manager, content keys, and the video renderer's decompression session and purge timer.
class AudioVideoRendererAVFObjC
    : public AudioVideoRenderer
    , public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<AudioVideoRendererAVFObjC, WTF::DestructionThread::Main>
    , private PeriodicSharedTimer::Client
    , private LoggerHelper {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(AudioVideoRendererAVFObjC, WEBCORE_EXPORT);
public:
    WEBCORE_EXPORT static Ref<AudioVideoRendererAVFObjC> create(const Logger&, uint64_t logIdentifier);
    WEBCORE_EXPORT static Ref<AudioVideoRendererAVFObjC> create(const Logger&, uint64_t logIdentifier, UniqueRef<SharedTimebase>&&);
    ~AudioVideoRendererAVFObjC();

    WTF_ABSTRACT_THREAD_SAFE_REF_COUNTED_AND_CAN_MAKE_WEAK_PTR_IMPL;

    // The token that finds the Swift core (AudioVideoRendererCore.renderer(forToken:)), for the GPU process's renderer
    // receiver, which becomes its client.
    WEBCORE_EXPORT uint64_t swiftToken() const;

    void shutdown() final;

    WEBCORE_EXPORT void setPreferences(VideoRendererPreferences) final;
    void setHasProtectedVideoContent(bool) final;

    // TracksRendererInterface
    WEBCORE_EXPORT std::optional<TrackIdentifier> addTrack(TrackType) final;
    void removeTrack(TrackIdentifier) final;

    void enqueueSample(TrackIdentifier, Ref<MediaSample>&&, std::optional<MediaTime>) final;
    bool isReadyForMoreSamples(TrackIdentifier) final;
    Ref<RequestPromise> requestMediaDataWhenReady(TrackIdentifier) final;
    void notifyTrackNeedsReenqueuing(TrackIdentifier, Function<void(TrackIdentifier, const MediaTime&)>&&) final;

    bool timeIsProgressing() const final;
    MediaTime currentTime() const final;
    Ref<MediaTimePromise> notifyTimeReachedAndStall(const MediaTime&) final;
    void cancelTimeReachedAction() final;
    void performTaskAtTime(const MediaTime&, Function<void(const MediaTime&)>&&) final;
    void setTimeObserver(Seconds, Function<void(const MediaTime&)>&&) final;
    void cancelTimeObserver();

    void flush() final;
    void flushTrack(TrackIdentifier) final;

    void applicationWillResignActive() final;

    void notifyWhenErrorOccurs(Function<void(PlatformMediaError)>&&) final;

    // SynchronizerInterface
    void play(std::optional<MonotonicTime>) final;
    void pause(std::optional<MonotonicTime>) final;
    bool paused() const final;
    void setRate(double) final;
    double effectiveRate() const final;
    void stall() final;
    Ref<MediaTimePromise> prepareToSeek(const MediaTime&) final;
    Ref<GenericPromise> finishSeek(const MediaTime&) final;
    void notifyEffectiveRateChanged(Function<void(double)>&&) final;
    bool seeking() const final;
    void setScreenReserved(bool) final;
    SharedTimebase* sharedTimebase() final { return m_sharedTimebase.get(); }

    // AudioInterface
    void setVolume(float) final;
    void setMuted(bool) final;
    void setPreservesPitchAndCorrectionAlgorithm(bool, std::optional<PitchCorrectionAlgorithm>) final;
#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    void setOutputDeviceId(const String&) final;
#endif

    // VideoInterface
    void setIsVisible(bool);
    void setPresentationSize(const IntSize&) final;
    void setShouldMaintainAspectRatio(bool) final;
    WEBCORE_EXPORT void renderingCanBeAcceleratedChanged(bool) final;
    void contentBoxRectChanged(const LayoutRect&) final;
    void notifyFirstFrameAvailable(Function<void()>&&) final;
    void notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&&) final;
    WEBCORE_EXPORT void notifyWhenRequiresFlushToResume(Function<void()>&&) final;
    void notifyRenderingModeChanged(Function<void()>&&) final;
    void expectMinimumUpcomingPresentationTime(const MediaTime&) final;
    void notifySizeChanged(Function<void(const MediaTime&, FloatSize)>&&) final;
    void setShouldDisableHDR(bool) final;
    void setPlatformDynamicRangeLimit(const PlatformDynamicRangeLimit&) final;
    void setResourceOwner(const ProcessIdentity&) final;
    RefPtr<VideoFrame> currentVideoFrame() const final;
    void paintCurrentVideoFrameInContext(GraphicsContext&, const FloatRect&) final;
    RefPtr<NativeImage> currentNativeImage() const final;
    Ref<BitmapImagePromise> currentBitmapImage() const final;
    std::optional<VideoPlaybackQualityMetrics> videoPlaybackQualityMetrics() final;
    PlatformLayer* platformVideoLayer() const final;
    void setVideoLayerSize(const FloatSize&) final;
    void setVideoLayerSizeFenced(const FloatSize&, WTF::MachSendRightAnnotated&&) final;

    // VideoFullscreenInterface
    void setVideoFullscreenLayer(PlatformLayer*, Function<void()>&&) final;
    void setVideoFullscreenFrame(const FloatRect&) final;
    void setTextTrackRepresentation(TextTrackRepresentation*) final;
    void syncTextTrackBounds() final;
    Ref<GenericPromise> setVideoTarget(const PlatformVideoTarget&) final;
    void isInFullscreenOrPictureInPictureChanged(bool) final;

private:
    friend class AudioVideoRendererHost;

    WEBCORE_EXPORT AudioVideoRendererAVFObjC(const Logger&, uint64_t, std::unique_ptr<SharedTimebase>&&);

    // What the client hears: notifyError() from the core, reportError() for the C++ renderer's own errors.
    void notifyError(PlatformMediaError);
    void reportError(PlatformMediaError);
    String toString(TrackIdentifier) const;
    std::optional<TrackType> typeOf(TrackIdentifier) const;
    void periodicSharedTimerFired() final;
#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    void setOutputDeviceIdOnRenderer(AVSampleBufferAudioRenderer *);
#endif
#if HAVE(SPATIAL_TRACKING_LABEL)
    void setSpatialTrackingInfo(bool prefersSpatialAudioExperience, SoundStageSize, const String& sceneIdentifier, const String& defaultLabel, const String& label) final;
#endif
    void updateSpatialTrackingLabel();

    struct DisplayedPixelBuffer {
        RetainPtr<CVPixelBufferRef> pixelBuffer;
        MediaTime presentationTimeStamp;
    };
    DisplayedPixelBuffer copyDisplayedPixelBuffer() const;
    void setNeedsPlaceholderImage(bool);

    // What AudioVideoRendererHost calls.
    NSObject *renderingObject(AudioVideoRendererObject, uint64_t trackIdentifier) const;
    bool createRenderingObject(AudioVideoRendererObject, uint64_t trackIdentifier);
    void destroyRenderingObject(AudioVideoRendererObject, uint64_t trackIdentifier);
    void expireVideoRendererForTarget();
    void destroyExpiringVideoRenderers();
    bool addToSynchronizer(AudioVideoRendererObject, uint64_t trackIdentifier);
    void removeFromSynchronizer(AudioVideoRendererObject, uint64_t trackIdentifier);
    void setVideoRendererTimebase(bool, uint64_t rendererIdentifier);
    bool hasVideoRendererTimebase() const;
    void setVideoRendererPurgeTimerFireTime(CMTime);
    void initializeDecompressionSession(uint64_t rendererIdentifier, uint8_t rendererObject);
    RefPtr<WebCoreDecompressionSession> decompressionSession() const;
    void decodeSample(CMSampleBufferRef, uint8_t decodingFlags, uint64_t rendererIdentifier, int32_t flushId);
    void invalidateDecompressionSession(std::optional<uint64_t> rendererIdentifier);
    double updateFrameRateMonitor();
    void assignResourceOwner(CMSampleBufferRef);
    uint32_t rendererDroppedVideoFrames(AudioVideoRendererObject) const;
    void expectMinimumUpcomingPresentationTime(AudioVideoRendererObject, CMTime);
    void removeBlockedSamples(AudioVideoRendererBlockedSamples, uint64_t trackIdentifier);
    void setSharedTimerActive(bool);
    void storeSharedTimebaseSnapshot(CMTime, double playbackRate);
    bool willLog(AudioVideoRendererLogLevel) const;
    void log(AudioVideoRendererLogLevel, std::span<const uint8_t>) const;

    void mediaDataRequestSettled(bool isVideo, uint64_t trackIdentifier, bool resolved);
    void seekSettled(bool resolved);
    void timeReached();
    void performTask(CMTime);
    void timeObserverFired(CMTime);
    void audioRendererWasFlushed(uint64_t trackIdentifier, CMTime);
    void hdcpStatusChanged(bool obscured);
    void videoTargetSettled(bool resolved);

#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
    void tryToEnqueueBlockedSamples();
    bool canEnqueueSample(TrackIdentifier, const MediaSample&);
    void attachContentKeyToSampleIfNeeded(const MediaSample&);
#endif

#if HAVE(AVCONTENTKEYSESSION)
#if ENABLE(ENCRYPTED_MEDIA)
    void setCDMInstance(CDMInstance*) final;
    Ref<MediaPromise> setInitData(Ref<SharedBuffer>) final;
    void attemptToDecrypt() final;
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    RefPtr<SharedBuffer> initData() const final { return m_initData; }
    void setCDMSession(LegacyCDMSession*) final;
#endif
#endif

    // Logger
    const Logger& logger() const final { return m_logger.get(); }
    ASCIILiteral logClassName() const final { return "AudioVideoRendererAVFObjC"_s; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
    WTFLogChannel& logChannel() const final;

    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
    const UniqueRef<VideoLayerManagerObjC> m_videoLayerManager;
    const RetainPtr<AVSampleBufferRenderSynchronizer> m_synchronizer;
    const std::unique_ptr<SharedTimebase> m_sharedTimebase;

    struct Core;
    std::unique_ptr<Core> m_core;

    bool m_isShutdown { false };

    Function<void(PlatformMediaError)> m_errorCallback;
    Function<void()> m_firstFrameAvailableCallback;
    Function<void(const MediaTime&, double)> m_hasAvailableVideoFrameCallback;
    Function<void()> m_notifyWhenRequiresFlushToResume;
    Function<void()> m_renderingModeChangedCallback;
    Function<void(const MediaTime&, FloatSize)> m_sizeChangedCallback;
    Function<void(double)> m_effectiveRateChangedCallback;
    Function<void(const MediaTime&)> m_performTask;
    Function<void(const MediaTime&)> m_timeObserverCallback;
    HashMap<uint64_t, Function<void(TrackIdentifier, const MediaTime&)>> m_reenqueueCallbacks;

    std::optional<MediaTimePromise::Producer> m_stallProducer;
    MediaTime m_stallBoundary;
    std::optional<GenericPromise::AutoRejectProducer> m_seekPromise;
    MediaTime m_lastSeekTargetTime;
    std::optional<RequestPromise::AutoRejectProducer> m_requestVideoPromise;
    HashMap<uint64_t, std::unique_ptr<RequestPromise::AutoRejectProducer>> m_requestAudioPromises;
#if ENABLE(LINEAR_MEDIA_PLAYER)
    std::optional<GenericPromise::AutoRejectProducer> m_videoTargetPromise;
#endif

#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    String m_audioOutputDeviceId;
#endif

    HashMap<uint64_t, RetainPtr<AVSampleBufferAudioRenderer>> m_audioRenderers;
    RetainPtr<AVSampleBufferDisplayLayer> m_sampleBufferDisplayLayer;
    RetainPtr<AVSampleBufferVideoRenderer> m_sampleBufferVideoRenderer;
    RetainPtr<AVSampleBufferVideoRenderer> m_expiredVideoRendererPendingRemoval;
    Vector<RetainPtr<AVSampleBufferVideoRenderer>> m_expiringSampleBufferVideoRenderers;
    RetainPtr<CVPixelBufferRef> m_lastPixelBuffer;
    bool m_needsPlaceholderImage { false };
    bool m_visible { false };
    IntSize m_presentationSize;
    bool m_shouldMaintainAspectRatio { true };
    bool m_shouldDisableHDR { false };
    PlatformDynamicRangeLimit m_dynamicRangeLimit { PlatformDynamicRangeLimit::initialValueForVideos() };
    ProcessIdentity m_resourceOwner;

    bool m_registeredWithSharedTimer { false };
    RefPtr<EffectiveRateChangedListener> m_effectiveRateChangedListener;

    // The video renderer's timebase timer, rate listener and decompression session.
    mutable Lock m_videoRendererLock;
    OSObjectPtr<dispatch_source_t> m_videoRendererTimerSource WTF_GUARDED_BY_LOCK(m_videoRendererLock);
    uint64_t m_videoRendererTimebaseIdentifier WTF_GUARDED_BY_LOCK(m_videoRendererLock) { 0 };
    RefPtr<EffectiveRateChangedListener> m_videoRendererRateListener;
    RefPtr<WebCoreDecompressionSession> m_decompressionSession WTF_GUARDED_BY_LOCK(m_videoRendererLock);
    uint64_t m_decompressionSessionIdentifier WTF_GUARDED_BY_LOCK(m_videoRendererLock) { 0 };
    const std::unique_ptr<FrameRateMonitor> m_frameRateMonitor;

    mutable std::unique_ptr<PixelBufferConformerCV> m_rgbConformer;

#if HAVE(SPATIAL_TRACKING_LABEL)
    bool m_prefersSpatialAudioExperience { false };
    SoundStageSize m_soundStage { SoundStageSize::Auto };
    String m_sceneIdentifier;
    String m_defaultSpatialTrackingLabel;
    String m_spatialTrackingLabel;
#endif

#if ENABLE(LINEAR_MEDIA_PLAYER)
    RetainPtr<FigVideoTargetRef> m_videoTarget;
#endif
#if HAVE(AVCONTENTKEYSESSION)
#if ENABLE(ENCRYPTED_MEDIA)
    RefPtr<CDMInstanceFairPlayStreamingAVFObjC> m_cdmInstance;
    const Ref<Observer<void()>> m_keyStatusesChangedObserver;
    using KeyIDs = Vector<Ref<SharedBuffer>>;
    KeyIDs m_keyIDs;
    using TrackKeyIdsMap = HashMap<TrackIdentifier, KeyIDs>;
    TrackKeyIdsMap m_currentTrackIds;
    Deque<std::pair<TrackIdentifier, Ref<MediaSample>>> m_blockedSamples;
#endif
#if ENABLE(LEGACY_ENCRYPTED_MEDIA)
    RefPtr<SharedBuffer> m_initData;
    ThreadSafeWeakPtr<CDMSessionAVContentKeySession> m_session;
#endif
#endif
};

} // namespace WebCore
