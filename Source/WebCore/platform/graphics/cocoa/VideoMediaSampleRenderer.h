/*
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

#include "FrameRateMonitor.h"
#include "MediaPlayerEnums.h"
#include "ProcessIdentity.h"
#include "VideoPlaybackQualityMetrics.h"
#include "WebAVSampleBufferListener.h"
#include <CoreMedia/CMTime.h>
#include <wtf/Forward.h>
#include <wtf/Function.h>
#include <wtf/Lock.h>
#include <wtf/LoggerHelper.h>
#include <wtf/NativePromise.h>
#include <wtf/Ref.h>
#include <wtf/RetainPtr.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/darwin/DispatchOSObject.h>

OBJC_CLASS AVSampleBufferDisplayLayer;
OBJC_CLASS AVSampleBufferVideoRenderer;
OBJC_PROTOCOL(WebSampleBufferVideoRendering);
typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;
typedef struct OpaqueCMTimebase* CMTimebaseRef;
typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;

namespace WTF {
class WorkQueue;
}

namespace WebCore {

class EffectiveRateChangedListener;
class MediaSample;
class VideoMediaSampleRendererHost;
class WebCoreDecompressionSession;
enum class VideoMediaSampleRendererLogLevel : uint8_t;

// The C++ side of the video sample renderer, which AudioVideoRendererAVFObjC holds. The sample queues, the decoding
// decisions, the displayed frame and the statistics are VideoMediaSampleRenderer.swift's; this keeps the clients'
// callbacks and promises, the observation of the renderer, the main thread's renderer or display layer, the timebase
// and its purge timer, the decompression session and the logger.
class VideoMediaSampleRenderer final
    : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<VideoMediaSampleRenderer, WTF::DestructionThread::Main>
    , public WebAVSampleBufferListenerClient
#if !RELEASE_LOG_DISABLED
    , private LoggerHelper 
#endif
{
public:
    static Ref<VideoMediaSampleRenderer> create(WebSampleBufferVideoRendering *renderer, const Logger& logger, uint64_t logIdentifier) { return adoptRef(*new VideoMediaSampleRenderer(renderer, logger, logIdentifier)); }
    ~VideoMediaSampleRenderer();

    WTF_ABSTRACT_THREAD_SAFE_REF_COUNTED_AND_CAN_MAKE_WEAK_PTR_IMPL;

    using Preferences = VideoRendererPreferences;
    bool prefersDecompressionSession() const;
    void setPreferences(Preferences);
    bool isUsingDecompressionSession() const;
    bool managesDecodedFrames() const;
    bool isReceivingDecodedSamples() const;

    void setTimebase(RetainPtr<CMTimebaseRef>&&);
    RetainPtr<CMTimebaseRef> timebase() const;

    bool isReadyForMoreMediaData() const;
    Ref<GenericPromise> requestMediaDataWhenReady();
    void enqueueSample(const MediaSample&, std::optional<MediaTime> minimumUpcomingTime);
    void stopRequestingMediaData();

    void notifyFirstFrameAvailable(Function<void(const MediaTime&, double)>&&);
    void notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&&);
    void notifyWhenDecodingErrorOccurred(Function<void(NSError *)>&&);
    void notifyWhenVideoRendererRequiresFlushToResumeDecoding(Function<void()>&&);

#if HAVE(AVSAMPLEBUFFERVIDEORENDERER)
    Ref<GenericPromise> changeRenderer(WebSampleBufferVideoRendering *);
#endif

    void flush();
    void shutdown();

    void expectMinimumUpcomingSampleBufferPresentationTime(const MediaTime&);

    NODELETE WebSampleBufferVideoRendering *renderer() const;

    template <typename T> NODELETE T* as() const;
    template <> AVSampleBufferVideoRenderer* as() const;
    template <> AVSampleBufferDisplayLayer* as() const
    {
        assertIsMainThread();
        return m_displayLayer.get();
    }

    struct DisplayedPixelBufferEntry {
        RetainPtr<CVPixelBufferRef> pixelBuffer;
        MediaTime presentationTimeStamp;
    };
    DisplayedPixelBufferEntry copyDisplayedPixelBuffer();

    unsigned totalDisplayedFrames() const;
    std::optional<VideoPlaybackQualityMetrics> videoPlaybackQualityMetrics() const;

    void setResourceOwner(const ProcessIdentity&);

    static WorkQueue& queueSingleton();

    void invalidateDecompressionSession();

private:
    friend class VideoMediaSampleRendererHost;

    VideoMediaSampleRenderer(WebSampleBufferVideoRendering *, const Logger&, uint64_t);

    void clearTimebase();
    using TimebaseAndTimerSource = std::pair<RetainPtr<CMTimebaseRef>, OSObjectPtr<dispatch_source_t>>;
    TimebaseAndTimerSource timebaseAndTimerSource() const;
    MediaTime currentTime() const;

#if HAVE(AVSAMPLEBUFFERVIDEORENDERER)
    static AVSampleBufferVideoRenderer *videoRendererFor(WebSampleBufferVideoRendering *);
#endif

    void resetReadyForMoreMediaData();
    void resolveRequestMediaDataIfNeeded();
    void cancelTimer();
    void setPurgeTimerFireTime(CMTime);
    NODELETE RefPtr<WebCoreDecompressionSession> decompressionSession() const;

    // What VideoMediaSampleRendererHost calls.
    void initializeDecompressionSession();
    void decodeSample(CMSampleBufferRef, uint8_t decodingFlags, int32_t flushId);
    void assignResourceOwner(CMSampleBufferRef);
    uint32_t rendererDroppedVideoFrames();
    void notifyFirstFrameAvailable(CMTime presentationTime, double displayTime);
    void notifyHasAvailableVideoFrame(CMTime presentationTime, double displayTime);
    void notifyDecodingError(int32_t status);
    double updateFrameRateMonitor();
    bool willLog(VideoMediaSampleRendererLogLevel) const;
    void log(VideoMediaSampleRendererLogLevel, std::span<const uint8_t>) const;

    void notifyErrorHasOccurred(NSError *);
    void notifyVideoRendererRequiresFlushToResumeDecoding();

    // WebAVSampleBufferListenerClient
    void videoRendererDidReceiveError(WebSampleBufferVideoRendering *, NSError *) final;
    void videoRendererRequiresFlushToResumeDecodingChanged(WebSampleBufferVideoRendering *, bool) final;
    void videoRendererReadyForDisplayChanged(WebSampleBufferVideoRendering *, bool) final;
    void outputObscuredDueToInsufficientExternalProtectionChanged(bool) final;

#if !RELEASE_LOG_DISABLED
    // Logger
    const Logger& logger() const final { return m_logger.get(); }
    ASCIILiteral logClassName() const final { return "VideoMediaSampleRenderer"_s; }
    uint64_t logIdentifier() const final { return m_logIdentifier; }
    WTFLogChannel& logChannel() const final;
#endif

    struct Core;
    const std::unique_ptr<Core> m_core;

    RetainPtr<AVSampleBufferDisplayLayer> m_displayLayer WTF_GUARDED_BY_CAPABILITY(mainThread);
#if HAVE(AVSAMPLEBUFFERVIDEORENDERER)
    RetainPtr<AVSampleBufferVideoRenderer> m_mainRenderer WTF_GUARDED_BY_CAPABILITY(mainThread);
#endif
    mutable Lock m_lock;
    TimebaseAndTimerSource m_timebaseAndTimerSource WTF_GUARDED_BY_LOCK(m_lock);
    RefPtr<EffectiveRateChangedListener> m_effectiveRateChangedListener;
    RefPtr<WebCoreDecompressionSession> m_decompressionSession WTF_GUARDED_BY_LOCK(m_lock);

    std::optional<GenericPromise::AutoRejectProducer> m_requestMediaDataProducer WTF_GUARDED_BY_CAPABILITY(mainThread);
    bool m_needsFlushing WTF_GUARDED_BY_CAPABILITY(mainThread) { false };

    Function<void(const MediaTime&, double)> m_hasFirstFrameAvailableCallback WTF_GUARDED_BY_CAPABILITY(mainThread);
    Function<void(const MediaTime&, double)> m_hasAvailableFrameCallback WTF_GUARDED_BY_CAPABILITY(mainThread);
    Function<void(NSError *)> m_errorOccurredFunction WTF_GUARDED_BY_CAPABILITY(mainThread);
    Function<void()> m_rendererNeedsFlushFunction WTF_GUARDED_BY_CAPABILITY(mainThread);
    ProcessIdentity m_resourceOwner;
    const Ref<WebAVSampleBufferListener> m_listener;
    FrameRateMonitor m_frameRateMonitor;

#if !RELEASE_LOG_DISABLED
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
#endif
};

} // namespace WebCore
