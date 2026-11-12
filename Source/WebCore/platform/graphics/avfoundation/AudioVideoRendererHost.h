/*
 * Copyright (C) 2023-2024 Apple Inc. All rights reserved.
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
#include <dispatch/dispatch.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;
OBJC_CLASS NSObject;

namespace WebCore {

class AudioVideoRendererAVFObjC;

// What the Swift audio and video renderer cores (AudioVideoRendererAVFObjC.swift, VideoMediaSampleRenderer.swift) reach
// of the C++ AudioVideoRendererAVFObjC that owns them: the AVFoundation renderers it makes, the clients' callbacks and
// promises, the shared timebase, the video renderer's queue, timebase timer and decompression session, the resource
// owner and the logger. Refers to the C++ renderer weakly. Each group says which thread calls it.

enum class AudioVideoRendererLogLevel : uint8_t {
    Always,
    Error,
    Debug,
    Performance,
};

// The renderers that the C++ renderer makes.
enum class AudioVideoRendererObject : uint8_t {
    DisplayLayer,
    VideoRendererForTarget,
    AudioRenderer,
};

// Blocked samples that the C++ renderer holds until their keys are usable.
enum class AudioVideoRendererBlockedSamples : uint8_t {
    All,
    Video,
    Audio,
    Track,
};

// A sample's properties, as the C++ MediaSample has them.
struct AudioVideoRendererSampleInfo {
    CMTime presentationTime;
    CMTime presentationEndTime;
    CMTime minimumUpcomingTime;
    float presentationWidth;
    float presentationHeight;
    bool hasMinimumUpcomingTime;
    bool hasPresentationSize;
    bool isProtected;
    bool isNonDisplaying;
    bool isSync;
    // Whether the sample is already decoded.
    bool hasImageBuffer;
    // False when an attachment of the sample says no other sample depends on it.
    bool isDependedOnByOthers;
};

// VideoDecodeWindow's, which PacedMediaSamplesDecoder shares, and whether there is a shared timebase to publish to.
struct AudioVideoRendererConfiguration {
    CMTime lowWaterMark;
    CMTime highWaterMark;
    size_t sampleQueueHighWaterMark;
    size_t sampleQueueLowWaterMark;
    bool hasSharedTimebase;
};

struct AudioVideoRendererVideoMetrics {
    uint32_t totalVideoFrames;
    uint32_t droppedVideoFrames;
    uint32_t corruptedVideoFrames;
    uint32_t presentedVideoFrames;
    uint32_t droppedVideoFramesOffset;
    double totalFrameDelay;
    uint8_t rendererObject;
    bool hasVideoRenderer;
    bool hasRenderer;
    bool managesDecodedFrames;
    bool usingDecompressionSession;
    bool decompressionSessionBlocked;
};

// The C++ renderer's VideoPlaybackQualityMetrics, if it has any.
struct AudioVideoRendererPlaybackQualityMetrics {
    uint32_t totalVideoFrames;
    uint32_t droppedVideoFrames;
    uint32_t corruptedVideoFrames;
    double totalFrameDelay;
    uint32_t displayCompositedVideoFrames;
    bool hasMetrics;
};

class AudioVideoRendererHost final : public ThreadSafeRefCounted<AudioVideoRendererHost> {
public:
    static Ref<AudioVideoRendererHost> create(AudioVideoRendererAVFObjC&);
    ~AudioVideoRendererHost();

    // Any thread.
    dispatch_queue_t dispatchQueue() const;
    bool willLog(AudioVideoRendererLogLevel) const;
    void log(AudioVideoRendererLogLevel, WTF::SpanUInt8 message NOESCAPE) const;
    void storeSharedTimebaseSnapshot(CMTime currentTime, double playbackRate) const;

    // The video renderer's queue.
    bool hasTimebase() const;
    CMTime timebaseTime() const;
    double timebaseRate() const;
    void setPurgeTimerFireTime(CMTime) const;
    void decodeSample(CMSampleBufferRef, uint8_t decodingFlags, uint64_t rendererIdentifier, int32_t flushId) const;
    void invalidateDecompressionSession(uint64_t rendererIdentifier) const;
    bool isDecompressionSessionHardwareAccelerated() const;
    double frameRateMonitorUpdate() const;
    void assignResourceOwner(CMSampleBufferRef) const;

    // The main thread: the renderers.
    NSObject *renderingObject(AudioVideoRendererObject, uint64_t trackIdentifier) const;
    bool createRenderingObject(AudioVideoRendererObject, uint64_t trackIdentifier) const;
    void destroyRenderingObject(AudioVideoRendererObject, uint64_t trackIdentifier) const;
    void expireVideoRendererForTarget() const;
    void destroyExpiringVideoRenderers() const;
    bool addToSynchronizer(AudioVideoRendererObject, uint64_t trackIdentifier) const;
    void removeFromSynchronizer(AudioVideoRendererObject, uint64_t trackIdentifier) const;
    void setVideoRendererTimebase(bool, uint64_t rendererIdentifier) const;
    void initializeDecompressionSession(uint64_t rendererIdentifier, uint8_t rendererObject) const;
    void flushDecompressionSession() const;
    void shutDownDecompressionSession() const;
    bool vp9HardwareDecoderAvailable() const;
    void expectMinimumUpcomingPresentationTime(AudioVideoRendererObject, CMTime) const;
    void updateSpatialTrackingLabel() const;
    void updateLastPixelBuffer() const;
    void purgeLastPixelBuffer() const;
    void setNeedsPlaceholderImage(bool) const;
    void setSharedTimerActive(bool) const;
    void removeBlockedSamples(AudioVideoRendererBlockedSamples, uint64_t trackIdentifier) const;
    uint32_t rendererDroppedVideoFrames(AudioVideoRendererObject) const;
    AudioVideoRendererPlaybackQualityMetrics videoPlaybackQualityMetrics() const;

    // The main thread: what the clients hear.
    void notifyError(uint8_t platformMediaError) const;
    void firstFrameAvailable() const;
    void hasAvailableVideoFrame(CMTime presentationTime, double displayTime) const;
    void requiresFlushToResume() const;
    void renderingModeChanged() const;
    void sizeChanged(CMTime, float width, float height) const;
    void effectiveRateChanged(double) const;
    void mediaDataRequestSettled(bool isVideo, uint64_t trackIdentifier, bool resolved) const;
    void seekSettled(bool resolved) const;
    void timeReached(CMTime boundary) const;
    void performTask(CMTime now) const;
    void timeObserverFired(CMTime) const;
    void audioRendererWasFlushed(uint64_t trackIdentifier, CMTime) const;
    void hdcpStatusChanged(bool obscured) const;
    void videoTargetSettled(bool resolved) const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<AudioVideoRendererHost>::ref(); }
    void deref() const { ThreadSafeRefCounted<AudioVideoRendererHost>::deref(); }
#endif

private:
    explicit AudioVideoRendererHost(AudioVideoRendererAVFObjC&);

    ThreadSafeWeakPtr<AudioVideoRendererAVFObjC> m_renderer;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
