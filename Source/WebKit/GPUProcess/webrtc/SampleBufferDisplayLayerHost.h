/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include <CoreGraphics/CGGeometry.h>
#include <WebCore/HostingContext.h>
#include <WebCore/IntSize.h>
#include <WebCore/LocalSampleBufferDisplayLayer.h>
#include <WebCore/CMUtilities.h>
#include <WebCore/SampleBufferDisplayLayer.h>
#include <optional>
#include <wtf/Function.h>
#include <wtf/MachSendRightAnnotated.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>

typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;

namespace IPC {
class SwiftReplyEncoder;
}

namespace WebCore {
class VideoFrame;
}

namespace WebKit {

class LayerHostingContext;

using SampleBufferDisplayLayerHostStatusHandler = Function<void(bool didFail)>;
using SampleBufferDisplayLayerHostCountersHandler = Function<void(uint64_t totalFrameCount, uint64_t droppedFrameCount)>;
using OptionalMachSendRightAnnotated = std::optional<WTF::MachSendRightAnnotated>;

// A LocalSampleBufferDisplayLayer in a context that the UI process hosts, and the layer's client, which calls the handlers
// it is made with, for the Swift display layers of the GPU process (RemoteSampleBufferDisplayLayerManager.swift) and the
// capture preview (CapturePreviewManager.swift), which can't be the client of a C++ layer. Sendable: it doesn't change once
// made, its reference count is thread-safe, and its users serialize their calls to its layer, as the C++ layers' did.
class SWIFT_UNCHECKED_SENDABLE SampleBufferDisplayLayerHost final : public ThreadSafeRefCounted<SampleBufferDisplayLayerHost, WTF::DestructionThread::Main>, public WebCore::SampleBufferDisplayLayerClient {
public:
    // On the main thread. Null if the layer can't be made or initialized.
    SWIFT_MAIN_ACTOR static SampleBufferDisplayLayerHost* WTF_NULLABLE create(WebCore::IntSize, bool hideRootLayer, bool shouldMaintainAspectRatio, bool canShowWhileLocked, SampleBufferDisplayLayerHostStatusHandler&&, SampleBufferDisplayLayerHostCountersHandler&&) SWIFT_RETURNS_RETAINED;
    SWIFT_MAIN_ACTOR static RefPtr<SampleBufferDisplayLayerHost> createForCapturePreview(WebCore::IntSize);
    ~SampleBufferDisplayLayerHost();

    WebCore::HostingContext hostingContext() const { return m_hostingContext; }
    // Encodes the hosting context as the reply to RemoteSampleBufferDisplayLayerManager's CreateLayer.
    void encodeHostingContext(IPC::SwiftReplyEncoder&) const;

    // The layer, which Swift calls directly.
    WebCore::LocalSampleBufferDisplayLayer* WTF_NONNULL displayLayer() const SWIFT_RETURNS_UNRETAINED { return m_displayLayer.get(); }
    void setLogIdentifier(uint64_t);
    // Enqueues a frame of the pixel buffer, as SharedVideoFrameReader::read() makes it of a SharedVideoFrame.
    void enqueuePixelBuffer(CVPixelBufferRef WTF_NONNULL, int64_t timeValue, uint32_t timeScale, uint8_t timeFlags, uint16_t rotation, bool isMirrored, WebCore::PlatformVideoColorSpaceValues, bool shouldIgnoreAlpha);
    // On the main thread.
    void updateBoundsAndPosition(CGRect, const OptionalMachSendRightAnnotated& fence);

    USING_CAN_MAKE_WEAKPTR(WebCore::SampleBufferDisplayLayerClient);

    SWIFT_UNSAFE void ref() const final { ThreadSafeRefCounted::ref(); }
    SWIFT_UNSAFE void deref() const final { ThreadSafeRefCounted::deref(); }

private:
    SampleBufferDisplayLayerHost(SampleBufferDisplayLayerHostStatusHandler&&, SampleBufferDisplayLayerHostCountersHandler&&);

    // WebCore::SampleBufferDisplayLayerClient
    void sampleBufferDisplayLayerStatusDidFail() final;
    void updateVideoFrameCounters(uint64_t, uint64_t) final;
#if PLATFORM(IOS_FAMILY)
    bool canShowWhileLocked() const final { return false; }
#endif

    const SampleBufferDisplayLayerHostStatusHandler m_statusHandler;
    const SampleBufferDisplayLayerHostCountersHandler m_countersHandler;
    RefPtr<WebCore::LocalSampleBufferDisplayLayer> m_displayLayer;
    std::unique_ptr<LayerHostingContext> m_layerHostingContext;
    WebCore::HostingContext m_hostingContext;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
