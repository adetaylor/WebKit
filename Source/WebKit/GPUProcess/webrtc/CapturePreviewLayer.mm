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

#include "config.h"
#include "CapturePreviewLayer.h"

#if ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include "LayerHostingContext.h"
#include "Logging.h"
#include <WebCore/VideoFrame.h>

namespace WebKit {

RefPtr<CapturePreviewLayer> CapturePreviewLayer::create(WebCore::IntSize previewSize)
{
    Ref layer = adoptRef(*new CapturePreviewLayer);
    RefPtr displayLayer = WebCore::SampleBufferDisplayLayer::create(layer.get());
    if (!displayLayer) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager unable to create a display layer");
        return nullptr;
    }

    constexpr bool hideRootLayer = false;
    constexpr bool shouldMaintainAspectRatio = true;
    std::optional<bool> didInitialize;

    // LocalSampleBufferDisplayLayer::initialize() is synchronous, so capturing didInitialize by reference safe.
    displayLayer->initialize(hideRootLayer, previewSize, shouldMaintainAspectRatio, [&didInitialize](bool didSucceed) {
        didInitialize = didSucceed;
    });

    ASSERT(didInitialize.has_value());
    if (!didInitialize.value_or(false)) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager display layer failed to initialize");
        return nullptr;
    }

    LayerHostingContextOptions contextOptions;
#if PLATFORM(IOS_FAMILY) && USE(EXTENSIONKIT)
    contextOptions.useHostable = true;
#endif
    layer->m_layerHostingContext = LayerHostingContext::create(contextOptions);
    RetainPtr rootLayer = displayLayer->rootLayer();
    layer->m_layerHostingContext->setRootLayer(rootLayer);
    layer->m_hostingContext = layer->m_layerHostingContext->hostingContext();
    layer->m_displayLayer = WTF::move(displayLayer);
    return layer;
}

CapturePreviewLayer::CapturePreviewLayer() = default;

CapturePreviewLayer::~CapturePreviewLayer() = default;

void CapturePreviewLayer::enqueue(WebCore::VideoFrame& frame)
{
    Locker locker { m_enqueueLock };
    m_displayLayer->enqueueVideoFrame(frame);
}

void CapturePreviewLayer::sampleBufferDisplayLayerStatusDidFail()
{
    RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager display layer status failed");
}

} // namespace WebKit

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
