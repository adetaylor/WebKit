/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
#include "RemoteCompositorIntegration.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "Logging.h"
#include "RemoteCompositorIntegrationMessages.h"
#include "RemoteGPU.h"
#include "StreamServerConnection.h"
#include "WebGPUObjectHeap.h"
#include "WebKit-Swift.h"
#include <WebCore/ColorSpace.h>
#include <WebCore/IOSurface.h>
#include <WebCore/NativeImage.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <wtf/TZoneMallocInlines.h>

#define MESSAGE_CHECK_COMPLETION(assertion, completion) MESSAGE_CHECK_COMPLETION_BASE(assertion, m_streamConnection, completion)

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteCompositorIntegration);

RemoteCompositorIntegration::RemoteCompositorIntegration(WebGPU::ObjectHeap& objectHeap, Ref<IPC::StreamServerConnection>&& streamConnection, RemoteGPU& gpu, WebGPUIdentifier identifier)
    : m_objectHeap(objectHeap)
    , m_streamConnection(WTF::move(streamConnection))
    , m_gpu(gpu)
    , m_identifier(identifier)
{
    protect(m_streamConnection)->startReceivingMessages(*this, Messages::RemoteCompositorIntegration::messageReceiverName(), m_identifier.toUInt64());
}

RemoteCompositorIntegration::~RemoteCompositorIntegration() = default;

void RemoteCompositorIntegration::setCanvas(WebGPUCompositorCanvas&& canvas)
{
    ASSERT(!m_canvas);
    m_canvas = makeUniqueWithoutFastMallocCheck<WebGPUCompositorCanvas>(WTF::move(canvas));
}

void RemoteCompositorIntegration::destruct()
{
    protect(m_objectHeap)->removeObject(m_identifier);
}

void RemoteCompositorIntegration::withDisplayBufferAsNativeImage(uint32_t bufferIndex, NOESCAPE const Function<void(WebCore::NativeImage*)>& completion)
{
    if (!m_renderBuffers.size() || bufferIndex >= m_renderBuffers.size() || !m_hasDevice)
        return completion(nullptr);

    RefPtr<WebCore::NativeImage> displayImage;
    bool isIOSurfaceSupportedFormat = false;
    if (m_canvas)
        displayImage = WebCore::NativeImage::create(adoptCF(m_canvas->textureAsNativeImage(bufferIndex, isIOSurfaceSupportedFormat)));

    if (displayImage) {
        CGImageSetCachingFlags(displayImage->platformImage().get(), kCGImageCachingTransient);
        return completion(displayImage.get());
    }

    if (!isIOSurfaceSupportedFormat)
        return completion(nullptr);

    // A premultiplied canvas must keep its alpha channel so transparent pixels
    // composite over the page; an opaque canvas forces the alpha to be ignored.
    // This matters for RGBA16F, whose IOSurface format cannot itself encode opacity.
    auto shouldForceOpaque = m_alphaMode == WebCore::AlphaPremultiplication::Premultiplied ? WebCore::IOSurface::ShouldForceOpaque::No : WebCore::IOSurface::ShouldForceOpaque::Yes;
    m_renderBuffers[bufferIndex]->withNativeImage(shouldForceOpaque, [&](WebCore::NativeImage* image) {
        if (image)
            CGImageSetCachingFlags(image->platformImage().get(), kCGImageCachingTransient);
        completion(image);
    });
}

void RemoteCompositorIntegration::paintCompositedResultsToCanvas(WebCore::RenderingResourceIdentifier imageBufferIdentifier, uint32_t bufferIndex, CompletionHandler<void()>&& completionHandler)
{
    withDisplayBufferAsNativeImage(bufferIndex, [&](WebCore::NativeImage* image) {
        if (RefPtr gpu = m_gpu.ptr(); image && gpu)
            gpu->paintNativeImageToImageBuffer(*image, imageBufferIdentifier);
    });
    completionHandler();
}

void RemoteCompositorIntegration::stopListeningForIPC()
{
    protect(m_streamConnection)->stopReceivingMessages(Messages::RemoteCompositorIntegration::messageReceiverName(), m_identifier.toUInt64());
}

#if PLATFORM(COCOA)
void RemoteCompositorIntegration::recreateRenderBuffers(int width, int height, WebCore::ColorSpace&& destinationColorSpace, WebCore::AlphaPremultiplication alphaMode, ::WebGPU::TextureFormat textureFormat, unsigned bufferCount, WebKit::WebGPUIdentifier deviceIdentifier, CompletionHandler<void(Vector<MachSendRight>&&)>&& callback)
{
    MESSAGE_CHECK_COMPLETION(protect(m_objectHeap)->hasDevice(deviceIdentifier), callback({ }));

    m_renderBuffers.clear();
    m_hasDevice = true;
    m_alphaMode = alphaMode;

    if (m_canvas)
        m_canvas->unconfigure();

    constexpr int max2DTextureSize = 16384;
    width = std::max(1, std::min(max2DTextureSize, width));
    height = std::max(1, std::min(max2DTextureSize, height));
    WebCore::IOSurface::Format colorFormat;
    switch (textureFormat) {
    case ::WebGPU::TextureFormat::Rgba8unorm:
    case ::WebGPU::TextureFormat::Rgba8unormSRGB:
        colorFormat = alphaMode == WebCore::AlphaPremultiplication::Unpremultiplied ? WebCore::IOSurface::Format::RGBX : WebCore::IOSurface::Format::RGBA;
        break;
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case ::WebGPU::TextureFormat::Rgba16float:
        colorFormat = WebCore::IOSurface::Format::RGBA16F;
        break;
#endif
    default:
        colorFormat = alphaMode == WebCore::AlphaPremultiplication::Unpremultiplied ? WebCore::IOSurface::Format::BGRX : WebCore::IOSurface::Format::BGRA;
        break;
    }

    for (unsigned bufferIndex = 0; bufferIndex < std::min<unsigned>(3u, bufferCount); ++bufferIndex) {
        if (auto buffer = WebCore::IOSurface::create(nullptr, WebCore::IntSize(width, height), destinationColorSpace, WebCore::IOSurface::Name::WebGPU, colorFormat))
            m_renderBuffers.append(makeUniqueRefFromNonNullUniquePtr(WTF::move(buffer)));
    }

    if (m_canvas) {
        m_canvas->renderBuffersWereRecreated();
        for (auto& renderBuffer : m_renderBuffers)
            m_canvas->addRenderBuffer(renderBuffer->surface());
    }

    callback(m_renderBuffers.map([](const auto& renderBuffer) {
        return renderBuffer->createSendRight();
    }));
}
#endif

void RemoteCompositorIntegration::prepareForDisplay(uint32_t frameIndex, CompletionHandler<void(Seconds, Seconds)>&& completionHandler)
{
    if (!m_canvas) {
        completionHandler(0_s, 0_s);
        return;
    }
    m_canvas->present(frameIndex);
    Ref completion = WebGPUSwiftCompletion::create([completionHandler = WTF::move(completionHandler), protectedThis = Ref { *this }]() mutable {
        completionHandler(Seconds { protectedThis->m_canvas->lastFrameGPUCost() }, Seconds { protectedThis->m_canvas->lastFramePresentStall() });
    });
    m_canvas->onSubmittedWorkScheduled(completion.ptr());
}

void RemoteCompositorIntegration::updateContentsHeadroom(float headroom)
{
#if HAVE(SUPPORT_HDR_DISPLAY)
    for (auto& ioSurface : m_renderBuffers)
        ioSurface->setContentEDRHeadroom(headroom);
#else
    UNUSED_PARAM(headroom);
#endif
}

} // namespace WebKit

#undef MESSAGE_CHECK_COMPLETION

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
