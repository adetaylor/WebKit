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

#import "config.h"
#import "SampleBufferDisplayLayerHost.h"

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#import "ArgumentCoders.h"
#import "GeneratedSerializers.h"
#import "LayerHostingContext.h"
#import "Logging.h"
#import "SwiftCoding.h"
#import <WebCore/VideoFrameCV.h>

#if USE(EXTENSIONKIT)
#import <BrowserEngineKit/BELayerHierarchy.h>
#import <BrowserEngineKit/BELayerHierarchyHostingTransactionCoordinator.h>
#endif

namespace WebKit {

using namespace WebCore;

SampleBufferDisplayLayerHost::SampleBufferDisplayLayerHost(SampleBufferDisplayLayerHostStatusHandler&& statusHandler, SampleBufferDisplayLayerHostCountersHandler&& countersHandler)
    : m_statusHandler(WTF::move(statusHandler))
    , m_countersHandler(WTF::move(countersHandler))
{
}

SampleBufferDisplayLayerHost::~SampleBufferDisplayLayerHost() = default;

SampleBufferDisplayLayerHost* SampleBufferDisplayLayerHost::create(IntSize size, bool hideRootLayer, bool shouldMaintainAspectRatio, bool canShowWhileLocked, SampleBufferDisplayLayerHostStatusHandler&& statusHandler, SampleBufferDisplayLayerHostCountersHandler&& countersHandler)
{
    Ref host = adoptRef(*new SampleBufferDisplayLayerHost(WTF::move(statusHandler), WTF::move(countersHandler)));
    RefPtr displayLayer = LocalSampleBufferDisplayLayer::create(host.get());
    if (!displayLayer)
        return nullptr;
    host->m_displayLayer = displayLayer;

    // LocalSampleBufferDisplayLayer::initialize() is synchronous, so capturing didInitialize by reference is safe.
    std::optional<bool> didInitialize;
    displayLayer->initialize(hideRootLayer, size, shouldMaintainAspectRatio, [&didInitialize](bool didSucceed) {
        didInitialize = didSucceed;
    });
    ASSERT(didInitialize.has_value());
    if (!didInitialize.value_or(false))
        return nullptr;

    LayerHostingContextOptions contextOptions;
#if PLATFORM(IOS_FAMILY)
    contextOptions.canShowWhileLocked = canShowWhileLocked;
#if USE(EXTENSIONKIT)
    contextOptions.useHostable = true;
#endif
#else
    UNUSED_PARAM(canShowWhileLocked);
#endif
    host->m_layerHostingContext = LayerHostingContext::create(contextOptions);
    host->m_layerHostingContext->setRootLayer(protect(displayLayer->rootLayer()).get());
    host->m_hostingContext = host->m_layerHostingContext->hostingContext();
    return &host.leakRef();
}

RefPtr<SampleBufferDisplayLayerHost> SampleBufferDisplayLayerHost::createForCapturePreview(IntSize previewSize)
{
    constexpr bool hideRootLayer = false;
    constexpr bool shouldMaintainAspectRatio = true;
    constexpr bool canShowWhileLocked = false;
    RefPtr host = adoptRef(create(previewSize, hideRootLayer, shouldMaintainAspectRatio, canShowWhileLocked, [](bool) {
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager display layer status failed");
    }, [](uint64_t, uint64_t) { }));
    if (!host)
        RELEASE_LOG_ERROR(WebRTC, "CapturePreviewManager unable to create or initialize a display layer");
    return host;
}

void SampleBufferDisplayLayerHost::encodeHostingContext(IPC::SwiftReplyEncoder& encoder) const
{
    encoder.encodeWithArgumentCoder(HostingContext { m_hostingContext });
}

void SampleBufferDisplayLayerHost::setLogIdentifier(uint64_t identifier)
{
#if !RELEASE_LOG_DISABLED
    protect(m_displayLayer)->setLogIdentifier(identifier);
#else
    UNUSED_PARAM(identifier);
#endif
}

void SampleBufferDisplayLayerHost::enqueuePixelBuffer(CVPixelBufferRef pixelBuffer, int64_t timeValue, uint32_t timeScale, uint8_t timeFlags, uint16_t rotation, bool isMirrored, PlatformVideoColorSpaceValues colorSpace, bool shouldIgnoreAlpha)
{
    Ref frame = VideoFrameCV::create(MediaTime { timeValue, timeScale, timeFlags }, isMirrored, static_cast<VideoFrame::Rotation>(rotation), RetainPtr { pixelBuffer }, platformVideoColorSpace(colorSpace), shouldIgnoreAlpha ? VideoFrameCV::ShouldIgnoreAlpha::Yes : VideoFrameCV::ShouldIgnoreAlpha::No);
    protect(m_displayLayer)->enqueueVideoFrame(frame.get());
}

void SampleBufferDisplayLayerHost::updateBoundsAndPosition(CGRect bounds, const OptionalMachSendRightAnnotated& fence)
{
    RefPtr displayLayer = m_displayLayer;
#if USE(EXTENSIONKIT)
    RetainPtr<BELayerHierarchyHostingTransactionCoordinator> hostingUpdateCoordinator;
    if (fence && fence->sendRight.sendRight()) {
#if ENABLE(MACH_PORT_LAYER_HOSTING)
        hostingUpdateCoordinator = LayerHostingContext::createHostingUpdateCoordinator(MachSendRightAnnotated { *fence });
#else
        hostingUpdateCoordinator = LayerHostingContext::createHostingUpdateCoordinator(fence->sendRight.sendRight());
#endif // ENABLE(MACH_PORT_LAYER_HOSTING)
        if (hostingUpdateCoordinator)
            [hostingUpdateCoordinator addLayerHierarchy:m_layerHostingContext->hostable().get()];
        else
            RELEASE_LOG_ERROR(Media, "Could not create hosting update coordinator");
    }
    displayLayer->updateBoundsAndPosition(bounds, { });
    if (hostingUpdateCoordinator)
        [hostingUpdateCoordinator commit];
#else
    if (fence && fence->sendRight.sendRight())
        m_layerHostingContext->setFencePort(fence->sendRight.sendRight());

    displayLayer->updateBoundsAndPosition(bounds, { });
#endif // USE(EXTENSIONKIT)
}

void SampleBufferDisplayLayerHost::sampleBufferDisplayLayerStatusDidFail()
{
    m_statusHandler(protect(m_displayLayer)->didFail());
}

void SampleBufferDisplayLayerHost::updateVideoFrameCounters(uint64_t totalFrameCount, uint64_t droppedFrameCount)
{
    m_countersHandler(totalFrameCount, droppedFrameCount);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
