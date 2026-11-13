/*
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

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include <WebCore/HostingContext.h>
#include <WebCore/IntSize.h>
#include <WebCore/SampleBufferDisplayLayer.h>
#include <wtf/Lock.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WebCore {
class VideoFrame;
}

namespace WebKit {

class LayerHostingContext;

// The layer that a getUserMedia prompt's capture preview (CapturePreviewManager.swift) shows its camera's frames in,
// and the context that hosts it in the UI process, until the display layer is Swift. Sendable: it doesn't change once
// made, its reference count is thread-safe, and enqueue() may be called on any thread.
class SWIFT_UNCHECKED_SENDABLE CapturePreviewLayer final : public ThreadSafeRefCounted<CapturePreviewLayer, WTF::DestructionThread::Main>, public WebCore::SampleBufferDisplayLayerClient {
public:
    // Null if the display layer can't be made.
    SWIFT_MAIN_ACTOR static RefPtr<CapturePreviewLayer> create(WebCore::IntSize);
    ~CapturePreviewLayer();

    WebCore::HostingContext hostingContext() const { return m_hostingContext; }

    // On any thread.
    void enqueue(WebCore::VideoFrame&);

    USING_CAN_MAKE_WEAKPTR(WebCore::SampleBufferDisplayLayerClient);

    SWIFT_UNSAFE void ref() const final { ThreadSafeRefCounted::ref(); }
    SWIFT_UNSAFE void deref() const final { ThreadSafeRefCounted::deref(); }

private:
    CapturePreviewLayer();

    // WebCore::SampleBufferDisplayLayerClient
    void sampleBufferDisplayLayerStatusDidFail() final;
    void updateVideoFrameCounters(uint64_t, uint64_t) final { }
#if PLATFORM(IOS_FAMILY)
    bool canShowWhileLocked() const final { return false; }
#endif

    RefPtr<WebCore::SampleBufferDisplayLayer> m_displayLayer;
    // Serializes enqueue(), which LocalSampleBufferDisplayLayer expects from one thread at a time.
    Lock m_enqueueLock;
    std::unique_ptr<LayerHostingContext> m_layerHostingContext;
    WebCore::HostingContext m_hostingContext;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
