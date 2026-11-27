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
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeWeakPtr.h>

OBJC_CLASS AVSampleBufferRenderSynchronizer;
OBJC_CLASS NSObject;
OBJC_PROTOCOL(WebSampleBufferVideoRendering);
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer *CVPixelBufferRef;
typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;

namespace WebCore {

class AudioVideoRendererHost;
class CDMInstanceFairPlayStreamingAVFObjC;
class CDMSessionAVContentKeySession;
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
    , private LoggerHelper {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(AudioVideoRendererAVFObjC, WEBCORE_EXPORT);
public:
    WEBCORE_EXPORT static Ref<AudioVideoRendererAVFObjC> create(const Logger&, uint64_t logIdentifier);
    WEBCORE_EXPORT static Ref<AudioVideoRendererAVFObjC> create(const Logger&, uint64_t logIdentifier, UniqueRef<SharedTimebase>&&);
    ~AudioVideoRendererAVFObjC();

    // Swift cannot spell an unspecialised template: the specialisations the Swift implementations of the overrides use.
    using OptionalMonotonicTime = std::optional<MonotonicTime>;
    using VideoRendererPreferenceSet = OptionSet<VideoRendererPreference>;
    using OptionalPitchCorrectionAlgorithm = std::optional<PitchCorrectionAlgorithm>;

    // WTF_ABSTRACT_THREAD_SAFE_REF_COUNTED_AND_CAN_MAKE_WEAK_PTR_IMPL, with ref() and deref() unsafe in Swift.
    SWIFT_UNSAFE void ref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::ref(); }
    SWIFT_UNSAFE void deref() const final { ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::deref(); }
    ThreadSafeWeakPtrControlBlock& controlBlock() const final { return ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::controlBlock(); }
    uint32_t weakRefCount() const final { return ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr::weakRefCount(); }

    // The token that finds the Swift core (AudioVideoRendererCore.renderer(forToken:)), for the GPU process's renderer
    // receiver, which becomes its client.
    uint64_t swiftToken() const { return m_swiftToken; }

    WEBCORE_EXPORT void shutdown() final;

    WEBCORE_EXPORT void setPreferences(VideoRendererPreferences) final;
    void setHasProtectedVideoContent(bool) final;

#if HAVE(SPATIAL_TRACKING_LABEL)
    WEBCORE_EXPORT void setSpatialTrackingInfo(bool prefersSpatialAudioExperience, SoundStageSize, const String& sceneIdentifier, const String& defaultLabel, const String& label) final;
#else
    void setSpatialTrackingInfo(bool, SoundStageSize, const String&, const String&, const String&) final { }
#endif

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
    WEBCORE_EXPORT void play(std::optional<MonotonicTime>) final;
    WEBCORE_EXPORT void pause(std::optional<MonotonicTime>) final;
    // For Swift, which can't make a MonotonicTime.
    void playAtHostTime(double seconds) { play(MonotonicTime::fromRawSeconds(seconds)); }
    void pauseAtHostTime(double seconds) { pause(MonotonicTime::fromRawSeconds(seconds)); }
    bool paused() const final;
    void setRate(double) final;
    double effectiveRate() const final;
    void stall() final;
    Ref<MediaTimePromise> prepareToSeek(const MediaTime&) final;
    Ref<GenericPromise> finishSeek(const MediaTime&) final;
    void notifyEffectiveRateChanged(Function<void(double)>&&) final;
    bool seeking() const final;
    WEBCORE_EXPORT void setScreenReserved(bool) final;
    SharedTimebase* sharedTimebase() final { return m_sharedTimebase.get(); }

    void updateSpatialTrackingLabel();
    RefPtr<WebCoreDecompressionSession> decompressionSessionFor(uint64_t identifier) const;
    void decodeSample(CMSampleBufferRef, uint8_t decodingFlags, uint64_t rendererIdentifier, int32_t flushId);

    // AudioInterface
    void setVolume(float) final;
    void setMuted(bool) final;
    void setPreservesPitchAndCorrectionAlgorithm(bool, std::optional<PitchCorrectionAlgorithm>) final;
#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    WEBCORE_EXPORT void setOutputDeviceId(const String&) final;
#endif

    // VideoInterface
    WEBCORE_EXPORT void setIsVisible(bool);
    WEBCORE_EXPORT void setPresentationSize(const IntSize&) final;
    WEBCORE_EXPORT void setShouldMaintainAspectRatio(bool) final;
    WEBCORE_EXPORT void renderingCanBeAcceleratedChanged(bool) final;
    WEBCORE_EXPORT void contentBoxRectChanged(const LayoutRect&) final;
    void notifyFirstFrameAvailable(Function<void()>&&) final;
    void notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&&) final;
    WEBCORE_EXPORT void notifyWhenRequiresFlushToResume(Function<void()>&&) final;
    void notifyRenderingModeChanged(Function<void()>&&) final;
    void expectMinimumUpcomingPresentationTime(const MediaTime&) final;
    void notifySizeChanged(Function<void(const MediaTime&, FloatSize)>&&) final;
    WEBCORE_EXPORT void setShouldDisableHDR(bool) final;
    void flushAndRemoveImage() final { }
    WEBCORE_EXPORT void setPlatformDynamicRangeLimit(const PlatformDynamicRangeLimit&) final;
    WEBCORE_EXPORT void setResourceOwner(const ProcessIdentity&) final;
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
    WEBCORE_EXPORT void setVideoFullscreenFrame(const FloatRect&) final;
    void setTextTrackRepresentation(TextTrackRepresentation*) final;
    WEBCORE_EXPORT void syncTextTrackBounds() final;
    Ref<GenericPromise> setVideoTarget(const PlatformVideoTarget&) final;
    WEBCORE_EXPORT void isInFullscreenOrPictureInPictureChanged(bool) final;

private:
    friend class AudioVideoRendererHost;

    WEBCORE_EXPORT AudioVideoRendererAVFObjC(const Logger&, uint64_t, std::unique_ptr<SharedTimebase>&&);

    // What the client hears: notifyError() from the core, reportError() for the C++ renderer's own errors.
    void notifyError(PlatformMediaError);
    void reportError(PlatformMediaError);
    String toString(TrackIdentifier) const;
    std::optional<TrackType> typeOf(TrackIdentifier) const;
    // The core's, autoreleased.
    NSObject *renderingObject(AudioVideoRendererObject, uint64_t trackIdentifier) const;

    // What AudioVideoRendererHost calls.
    SWIFT_UNSAFE void renderingObjectChanged(AudioVideoRendererObject, NSObject *, bool created);
    void initializeDecompressionSession(uint64_t rendererIdentifier, uint8_t rendererObject);
    RefPtr<WebCoreDecompressionSession> decompressionSession() const;
    void invalidateDecompressionSession(std::optional<uint64_t> rendererIdentifier);
    void expectMinimumUpcomingPresentationTime(AudioVideoRendererObject, CMTime);
    void removeBlockedSamples(AudioVideoRendererBlockedSamples, uint64_t trackIdentifier);
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
    WEBCORE_EXPORT void attemptToDecrypt() final;
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
    // The core is made in the constructor, after the state its init reads; its init must not call the host.
    std::unique_ptr<Core> m_core;
    const uint64_t m_swiftToken;

public:
    bool m_isShutdown { false };
private:

    Function<void(PlatformMediaError)> m_errorCallback;
    Function<void()> m_firstFrameAvailableCallback;
    Function<void(const MediaTime&, double)> m_hasAvailableVideoFrameCallback;
    Function<void()> m_notifyWhenRequiresFlushToResume;
    Function<void()> m_renderingModeChangedCallback;
    Function<void(const MediaTime&, FloatSize)> m_sizeChangedCallback;
    Function<void(double)> m_effectiveRateChangedCallback;
    Function<void(const MediaTime&)> m_performTask;
    Function<void(const MediaTime&)> m_timeObserverCallback;
    uint64_t m_timeObserverGeneration { 0 };
    HashMap<uint64_t, Function<void(TrackIdentifier, const MediaTime&)>> m_reenqueueCallbacks;

    std::optional<MediaTimePromise::Producer> m_stallProducer;
    MediaTime m_stallBoundary;
    std::optional<GenericPromise::AutoRejectProducer> m_seekPromise;
public:
    MediaTime m_lastSeekTargetTime;
private:
    std::optional<RequestPromise::AutoRejectProducer> m_requestVideoPromise;
    HashMap<uint64_t, std::unique_ptr<RequestPromise::AutoRejectProducer>> m_requestAudioPromises;
#if ENABLE(LINEAR_MEDIA_PLAYER)
    std::optional<GenericPromise::AutoRejectProducer> m_videoTargetPromise;
#endif

public:
    bool m_visible { false };
private:
    IntSize m_presentationSize;
    PlatformDynamicRangeLimit m_dynamicRangeLimit { PlatformDynamicRangeLimit::initialValueForVideos() };
    ProcessIdentity m_resourceOwner;

    // The video renderer's decompression session.
    mutable Lock m_videoRendererLock;
    RefPtr<WebCoreDecompressionSession> m_decompressionSession WTF_GUARDED_BY_LOCK(m_videoRendererLock);
    uint64_t m_decompressionSessionIdentifier WTF_GUARDED_BY_LOCK(m_videoRendererLock) { 0 };

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
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
