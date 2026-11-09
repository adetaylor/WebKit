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
#include "RemoteGPU.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "Logging.h"
#include "ModelObjectHeap.h"
#include "RemoteGPUMessages.h"
#include "RemoteGPUProxyMessages.h"
#include "RemoteRenderingBackend.h"
#include "StreamServerConnection.h"
#include "WebGPUSwiftSupport.h"
#include <WebCore/GraphicsContext.h>
#include <WebCore/IOSurface.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/NativeImage.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <WebCore/WebGPUCppAPI.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <wtf/threads/BinarySemaphore.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteGPU);

RemoteGPU::RemoteGPU(WebGPUIdentifier identifier, GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteRenderingBackend& renderingBackend, Ref<IPC::StreamServerConnection>&& streamConnection)
    : m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_sharedPreferencesForWebProcess(gpuConnectionToWebProcess.sharedPreferencesForWebProcessValue())
    , m_workQueue(IPC::StreamConnectionWorkQueue::create("WebGPU work queue"_s))
    , m_streamConnection(WTF::move(streamConnection))
    , m_modelObjectHeap(ModelObjectHeap::create())
    , m_identifier(identifier)
    , m_renderingBackend(renderingBackend)
{
    weakPtrFactory().prepareForUseOnlyOnNonMainThread();
}

RemoteGPU::~RemoteGPU()
{
    if (m_swiftState)
        destroySwiftState(m_swiftState);
}

void RemoteGPU::initialize()
{
    assertIsMainRunLoop();
    // BEWARE: This is a retain cycle.
    // this owns the registry, but the registry has a strong reference to this. The retain cycle is broken in
    // workQueueUninitialize(). The work the instance schedules must run even if this is disowned (because the work
    // handles resource cleanup, etc.), which the scheduler sees to without a reference to this.
    RefPtr gpuProcessConnection = m_gpuConnectionToWebProcess.get();
#if HAVE(TASK_IDENTITY_TOKEN)
    swiftInitialize(gpuProcessConnection ? MachSendRight { gpuProcessConnection->webProcessIdentity().taskId() } : MachSendRight { });
#else
    UNUSED_VARIABLE(gpuProcessConnection);
    swiftInitialize(MachSendRight { });
#endif
    m_workQueue->dispatch([protectedThis = protect(*this)]() mutable {
        protectedThis->workQueueInitialize();
    });
}

void RemoteGPU::stopListeningForIPC()
{
    assertIsMainRunLoop();
    swiftBeginStopping();
    m_workQueue->dispatch([protectedThis = protect(*this)]() {
        protectedThis->workQueueUninitialize();
    });
    m_workQueue->stopAndWaitForCompletion([this] {
        assertIsCurrent(workQueue());
        swiftRunScheduledWork(true);
        // The work can create objects, such as asynchronously created pipelines. Releasing the registry also releases
        // its reference to this, if workQueueUninitialize() didn't run.
        swiftUninitialize();
        m_modelObjectHeap->clear();
    });
}

void RemoteGPU::workQueueInitialize()
{
    assertIsCurrent(workQueue());
    Ref workQueue = m_workQueue;
    RefPtr streamConnection = m_streamConnection;
    streamConnection->open(*this, workQueue);
    streamConnection->startReceivingMessages(*this, Messages::RemoteGPU::messageReceiverName(), m_identifier.toUInt64());
    send(Messages::RemoteGPUProxy::WasCreated(true));
}

void RemoteGPU::workQueueUninitialize()
{
    assertIsCurrent(workQueue());
    RefPtr streamConnection = m_streamConnection;
    streamConnection->stopReceivingMessages(Messages::RemoteGPU::messageReceiverName(), m_identifier.toUInt64());
    streamConnection->invalidate();
    m_streamConnection = nullptr;
    swiftRunScheduledWork(false);
    // Once the work queue stops, nothing can run the work that would call the callbacks pending on the
    // devices' queues, so the registry destroys the devices, which calls them now.
    swiftUninitialize();
    m_modelObjectHeap->clear();
}

void RemoteGPU::didReceiveInvalidMessage(IPC::StreamServerConnection&, IPC::MessageName messageName, const Vector<uint32_t>&)
{
    RefPtr gpuConnectionToWebProcess = m_gpuConnectionToWebProcess.get();
    uint64_t webProcessID = gpuConnectionToWebProcess ? gpuConnectionToWebProcess->webProcessIdentifier().toUInt64() : 0;
    RELEASE_LOG_FAULT_WITH_PAYLOAD(IPC, "Received an invalid message %s from WebContent process %" PRIu64 ", requesting for it to be terminated.", description(messageName), webProcessID);
    callOnMainRunLoop([weakGPUConnectionToWebProcess = m_gpuConnectionToWebProcess, messageName] {
        if (RefPtr gpuConnectionToWebProcess = weakGPUConnectionToWebProcess.get())
            gpuConnectionToWebProcess->terminateWebProcess(messageName);
    });
}


RefPtr<GPUConnectionToWebProcess> RemoteGPU::gpuConnectionToWebProcess() const
{
    return m_gpuConnectionToWebProcess.get();
}

static void paintToCanvas(WebCore::NativeImage& image, const WebCore::IntSize& canvasSize, WebCore::GraphicsContext& context)
{
    auto imageSize = image.size();
    WebCore::FloatRect canvasRect(WebCore::FloatPoint(), canvasSize);
    WebCore::GraphicsContextStateSaver stateSaver(context);
    context.setImageInterpolationQuality(WebCore::InterpolationQuality::DoNotInterpolate);
    context.drawNativeImage(image, canvasRect, WebCore::FloatRect(WebCore::FloatPoint(), imageSize), { WebCore::CompositeOperator::Copy });
}

void RemoteGPU::paintNativeImageToImageBuffer(WebCore::NativeImage& nativeImage, WebCore::RenderingResourceIdentifier imageBufferIdentifier)
{
    assertIsCurrent(workQueue());
    BinarySemaphore semaphore;

    Ref renderingBackend = m_renderingBackend;
    Ref protectedNativeImage = nativeImage;
    renderingBackend->dispatch([&]() mutable {
        if (auto imageBuffer = renderingBackend->imageBuffer(imageBufferIdentifier)) {
            paintToCanvas(protectedNativeImage, imageBuffer->backendSize(), imageBuffer->context());
            imageBuffer->flushDrawingContext();
        }
        semaphore.signal();
    });
    semaphore.wait();
}

void RemoteGPU::paintToImageBuffer(CGImageRef image, IOSurfaceRef surface, bool forceOpaque, uint64_t imageBufferIdentifier)
{
    WebCore::RenderingResourceIdentifier identifier { imageBufferIdentifier };
    if (image) {
        if (RefPtr nativeImage = WebCore::NativeImage::create(RetainPtr { image })) {
            CGImageSetCachingFlags(nativeImage->platformImage().get(), kCGImageCachingTransient);
            paintNativeImageToImageBuffer(*nativeImage, identifier);
        }
        return;
    }

    auto ioSurface = WebCore::IOSurface::createFromSurface(surface, std::nullopt);
    if (!ioSurface)
        return;
    // A surface made with an opaque format (BGRX, RGBX) reads back as its alpha format's, so the alpha channel to ignore
    // is chosen here, as the opaque format's bitmap configuration and IOSurface::withNativeImage() would.
    std::optional<CGImageAlphaInfo> alphaInfo;
    if (forceOpaque) {
        switch (ioSurface->pixelFormat().value_or(WebCore::IOSurface::Format::BGRA)) {
        case WebCore::IOSurface::Format::BGRA:
        case WebCore::IOSurface::Format::RGBA:
            alphaInfo = kCGImageAlphaNoneSkipFirst;
            break;
#if ENABLE(PIXEL_FORMAT_RGBA16F)
        case WebCore::IOSurface::Format::RGBA16F:
            alphaInfo = kCGImageAlphaNoneSkipLast;
            break;
#endif
        default:
            break;
        }
    }
    RetainPtr context = ioSurface->createPlatformContext(0, alphaInfo);
    if (!context)
        return;
    RefPtr nativeImage = WebCore::NativeImage::create(ioSurface->createImage(context.get()));
    if (!nativeImage)
        return;
    CGImageSetCachingFlags(nativeImage->platformImage().get(), kCGImageCachingTransient);
    paintNativeImageToImageBuffer(*nativeImage, identifier);
}

RefPtr<WebCore::ImageBuffer> RemoteGPU::imageBuffer(WebCore::RenderingResourceIdentifier imageBufferIdentifier)
{
    assertIsCurrent(workQueue());
    BinarySemaphore semaphore;

    RefPtr<WebCore::ImageBuffer> result;
    Ref renderingBackend = m_renderingBackend;
    renderingBackend->dispatch([&]() mutable {
        if (RefPtr imageBuffer = renderingBackend->imageBuffer(imageBufferIdentifier)) {
            imageBuffer->flushDrawingContext();
            result = WTF::move(imageBuffer);
        }
        semaphore.signal();
    });
    semaphore.wait();

    return result;
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
