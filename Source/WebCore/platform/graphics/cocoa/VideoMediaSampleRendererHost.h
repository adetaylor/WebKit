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

#pragma once

#include <CoreMedia/CMTime.h>
#include <dispatch/dispatch.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;

namespace WebCore {

class VideoMediaSampleRenderer;

// What the Swift video sample renderer (VideoMediaSampleRenderer.swift) reaches of the C++ VideoMediaSampleRenderer
// that owns it: the renderer's queue, the timebase and its purge timer, the decompression session, the clients'
// callbacks, the resource owner and the logger. Refers to the C++ renderer weakly. Each function says which thread
// calls it: the main thread or the renderer's queue.

enum class VideoMediaSampleRendererLogLevel : uint8_t {
    Always,
    Error,
    Debug,
    Performance,
};

// A sample's properties, as the C++ MediaSample has them.
struct VideoMediaSampleRendererSampleInfo {
    CMTime presentationTime;
    CMTime presentationEndTime;
    bool isProtected;
    bool isNonDisplaying;
    bool isSync;
    // Whether the sample is already decoded.
    bool hasImageBuffer;
    // False when an attachment of the sample says no other sample depends on it.
    bool isDependedOnByOthers;
};

// VideoDecodeWindow's, which PacedMediaSamplesDecoder shares.
struct VideoMediaSampleRendererDecodeWindow {
    CMTime lowWaterMark;
    CMTime highWaterMark;
    size_t sampleQueueHighWaterMark;
    size_t sampleQueueLowWaterMark;
};

struct VideoMediaSampleRendererMetrics {
    uint32_t totalVideoFrames;
    uint32_t droppedVideoFrames;
    uint32_t corruptedVideoFrames;
    uint32_t presentedVideoFrames;
    uint32_t droppedVideoFramesOffset;
    double totalFrameDelay;
    bool decompressionSessionBlocked;
};

class VideoMediaSampleRendererHost final : public ThreadSafeRefCounted<VideoMediaSampleRendererHost> {
public:
    static Ref<VideoMediaSampleRendererHost> create(VideoMediaSampleRenderer&);
    ~VideoMediaSampleRendererHost();

    // Any thread.
    dispatch_queue_t dispatchQueue() const;
    bool hasTimebase() const;
    CMTime timebaseTime() const;
    double timebaseRate() const;
    bool willLog(VideoMediaSampleRendererLogLevel) const;
    void log(VideoMediaSampleRendererLogLevel, WTF::SpanUInt8 message NOESCAPE) const;

    // The queue.
    void setPurgeTimerFireTime(CMTime) const;
    void decodeSample(CMSampleBufferRef, uint8_t decodingFlags, int32_t flushId) const;
    void invalidateDecompressionSession() const;
    bool isDecompressionSessionHardwareAccelerated() const;
    double frameRateMonitorUpdate() const;
    void assignResourceOwner(CMSampleBufferRef) const;

    // The main thread.
    void initializeDecompressionSession() const;
    bool vp9HardwareDecoderAvailable() const;
    uint32_t rendererDroppedVideoFrames() const;
    void requestMediaDataResolved() const;
    void firstFrameAvailable(CMTime presentationTime, double displayTime) const;
    void hasAvailableVideoFrame(CMTime presentationTime, double displayTime) const;
    void decodingErrorOccurred(int32_t status) const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<VideoMediaSampleRendererHost>::ref(); }
    void deref() const { ThreadSafeRefCounted<VideoMediaSampleRendererHost>::deref(); }
#endif

private:
    explicit VideoMediaSampleRendererHost(VideoMediaSampleRenderer&);

    ThreadSafeWeakPtr<VideoMediaSampleRenderer> m_renderer;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
