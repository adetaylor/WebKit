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
#include "WebGPUSwiftSupport.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteBufferProxy.h"
#include "RemoteGPU.h"
#include "RemoteXRBinding.h"
#include "StreamServerConnection.h"
#include "WebGPUObjectHeap.h"
#include "WebKit-Swift.h"
#include <WebCore/ImageBuffer.h>
#include <WebCore/WebGPU.h>
#include <WebCore/WebGPUImageCopyExternalImage.h>
#include <WebCore/WebGPUImageCopyTextureTagged.h>
#include <wtf/CheckedArithmetic.h>

#if PLATFORM(COCOA) && ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeapHandle.h"
#include "SharedVideoFrame.h"
#include <WebCore/MediaPlayer.h>
#include <WebCore/VideoFrame.h>
#endif

namespace WebKit {

WebGPUSwiftReceiverContext::WebGPUSwiftReceiverContext(WebGPU::ObjectHeap& objectHeap, RemoteGPU& gpu, WebGPUIdentifier identifier)
    : m_objectHeap(objectHeap)
    , m_gpu(gpu)
    , m_identifier(identifier)
{
}

void WebGPUSwiftReceiverContext::removeFromObjectHeap() const
{
    if (RefPtr objectHeap = m_objectHeap.get())
        objectHeap->removeObject(m_identifier);
}

std::optional<SharedPreferencesForWebProcess> WebGPUSwiftReceiverContext::sharedPreferencesForWebProcess() const
{
    if (RefPtr gpu = m_gpu.get())
        return gpu->sharedPreferencesForWebProcess();
    return std::nullopt;
}

WebGPUSwiftRegistryHost::WebGPUSwiftRegistryHost(WebGPU::ObjectHeap& objectHeap, RemoteGPU& gpu)
    : m_objectHeap(objectHeap)
    , m_gpu(gpu)
{
}

std::optional<SharedPreferencesForWebProcess> WebGPUSwiftRegistryHost::sharedPreferencesForWebProcess() const
{
    if (RefPtr gpu = m_gpu.get())
        return gpu->sharedPreferencesForWebProcess();
    return std::nullopt;
}

RefPtr<IPC::StreamServerConnection> WebGPUSwiftRegistryHost::streamConnection() const
{
    RefPtr gpu = m_gpu.get();
    return gpu ? gpu->m_streamConnection : nullptr;
}

bool WebGPUSwiftRegistryHost::addXRBinding(::WebGPU::Device& device, uint64_t identifier) const
{
    RefPtr binding = device.createXRBinding();
    if (!binding)
        return false;
    RefPtr objectHeap = m_objectHeap.get();
    RefPtr gpu = m_gpu.get();
    RefPtr streamConnection = this->streamConnection();
    RefPtr connection = gpu ? gpu->gpuConnectionToWebProcess() : nullptr;
    if (!objectHeap || !streamConnection || !connection)
        return true;
    WebGPUIdentifier bindingIdentifier { identifier };
    auto remoteBinding = RemoteXRBinding::create(*connection, *binding, *objectHeap, *gpu, streamConnection.releaseNonNull(), bindingIdentifier);
    objectHeap->addObject(bindingIdentifier, remoteBinding);
    return true;
}

void WebGPUSwiftRegistryHost::trackDevice(::WebGPU::Device& device) const
{
    if (RefPtr objectHeap = m_objectHeap.get())
        objectHeap->trackDevice(device);
}

bool WebGPUSwiftRegistryHost::writeSharedMemoryToTexture(::WebGPU::Queue& queue, IPC::CxxDecodedArgument<WebGPU::ImageCopyTexture>& destinationArgument, IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>& dataArgument, IPC::CxxDecodedArgument<WebGPU::ImageDataLayout>& dataLayoutArgument, IPC::CxxDecodedArgument<WebGPU::Extent3D>& sizeArgument) const
{
    auto destination = destinationArgument.take();
    auto dataHandle = dataArgument.take();
    auto dataLayout = dataLayoutArgument.take();
    auto size = sizeArgument.take();
    RefPtr objectHeap = m_objectHeap.get();
    if (!destination || !dataHandle || !dataLayout || !size || !objectHeap)
        return false;

    auto data = *dataHandle ? WebCore::SharedMemory::map(WTF::move(**dataHandle), WebCore::SharedMemory::Protection::ReadOnly) : nullptr;
    auto convertedDestination = objectHeap->convertFromBacking(*destination);
    ASSERT(convertedDestination);
    if (!convertedDestination || !data || data->size() <= WebGPU::maxCrossProcessResourceCopySize)
        return false;

    queue.writeTexture(*convertedDestination, ::WebGPU::ByteOwner::create(data.releaseNonNull()), *dataLayout, *size);
    return true;
}

void WebGPUSwiftRegistryHost::copyExternalImageToTexture(::WebGPU::Queue& queue, IPC::CxxDecodedArgument<WebGPU::ImageCopyExternalImage>& sourceArgument, IPC::CxxDecodedArgument<WebGPU::ImageCopyTextureTagged>& destinationArgument, IPC::CxxDecodedArgument<WebGPU::Extent3D>& copySizeArgument) const
{
    auto source = sourceArgument.take();
    auto destination = destinationArgument.take();
    auto copySize = copySizeArgument.take();
    RefPtr objectHeap = m_objectHeap.get();
    RefPtr gpu = m_gpu.get();
    if (!source || !destination || !copySize || !objectHeap || !gpu)
        return;

    auto convertedSource = objectHeap->convertFromBacking(*source);
    ASSERT(convertedSource);
    auto convertedDestination = objectHeap->convertFromBacking(*destination);
    ASSERT(convertedDestination);
    if (!convertedSource || !convertedDestination)
        return;

    // ConvertFromBackingContext cannot resolve the source, because only RemoteGPU can reach the
    // RemoteRenderingBackend which owns the ImageBuffer.
    if (source->imageBufferIdentifier) {
        RefPtr sourceImageBuffer = gpu->imageBuffer(*source->imageBufferIdentifier);
        if (!sourceImageBuffer)
            return;
        convertedSource->imageBuffer = WTF::move(sourceImageBuffer);
    }

    if (RefPtr integration = gpu->backing())
        integration->copyExternalImageToTexture(queue, *convertedSource, *convertedDestination, *copySize);
}

std::optional<RemoteRenderPassEncoderBacking> WebGPUSwiftRegistryHost::beginRenderPass(::WebGPU::CommandEncoder& commandEncoder, IPC::CxxDecodedArgument<WebGPU::RenderPassDescriptor>& descriptorArgument, bool& isInvalid) const
{
    isInvalid = false;
    auto descriptor = descriptorArgument.take();
    RefPtr objectHeap = m_objectHeap.get();
    if (!descriptor || !objectHeap) {
        isInvalid = !descriptor;
        return std::nullopt;
    }

    Vector<std::optional<::WebGPU::RenderPassColorAttachment>> colorAttachments;
    auto convertedDescriptor = objectHeap->convertFromBacking(*descriptor, colorAttachments);
    if (!convertedDescriptor) {
        isInvalid = true;
        return std::nullopt;
    }

    RefPtr renderPassEncoder = commandEncoder.beginRenderPass(*convertedDescriptor);
    if (!renderPassEncoder) {
        isInvalid = true;
        return std::nullopt;
    }
    return RemoteRenderPassEncoderBacking { *renderPassEncoder };
}

std::optional<RemoteComputePassEncoderBacking> WebGPUSwiftRegistryHost::beginComputePass(::WebGPU::CommandEncoder& commandEncoder, IPC::CxxDecodedArgument<std::optional<WebGPU::ComputePassDescriptor>>& descriptorArgument, bool& isInvalid) const
{
    isInvalid = false;
    auto descriptor = descriptorArgument.take();
    RefPtr objectHeap = m_objectHeap.get();
    if (!descriptor || !objectHeap) {
        isInvalid = !descriptor;
        return std::nullopt;
    }

    std::optional<::WebGPU::ComputePassDescriptor> convertedDescriptor;
    if (*descriptor) {
        auto resultDescriptor = objectHeap->convertFromBacking(**descriptor);
        if (!resultDescriptor) {
            isInvalid = true;
            return std::nullopt;
        }
        convertedDescriptor = WTF::move(resultDescriptor);
    }

    RefPtr computePassEncoder = commandEncoder.beginComputePass(convertedDescriptor);
    if (!computePassEncoder) {
        isInvalid = true;
        return std::nullopt;
    }
    return RemoteComputePassEncoderBacking { *computePassEncoder };
}

WebGPUSwiftReceiverRegistration::WebGPUSwiftReceiverRegistration(IPC::StreamServerConnection& streamConnection, IPC::StreamMessageReceiver& receiver, IPC::ReceiverName receiverName, uint64_t identifier)
    : m_streamConnection(streamConnection)
    , m_receiverName(receiverName)
    , m_identifier(identifier)
{
    streamConnection.startReceivingMessages(receiver, receiverName, identifier);
}

WebGPUSwiftReceiverRegistration::~WebGPUSwiftReceiverRegistration()
{
    m_streamConnection->stopReceivingMessages(m_receiverName, m_identifier);
}

bool copySharedMemoryToBuffer(::WebGPU::Buffer& buffer, IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>& argument, uint64_t offset)
{
    auto dataHandle = argument.take();
    if (!dataHandle)
        return false;
    auto sharedData = *dataHandle ? WebCore::SharedMemory::map(WTF::move(**dataHandle), WebCore::SharedMemory::Protection::ReadOnly) : nullptr;
    auto data = sharedData ? sharedData->span() : std::span<const uint8_t> { };
    if (data.size() <= WebGPU::maxCrossProcessResourceCopySize)
        return false;

#if !ENABLE(WEBGPU_SWIFT)
    auto contents = buffer.getBufferContents();
    if (contents.empty())
        return false;

    auto endOffset = checkedSum<size_t>(offset, data.size());
    if (endOffset.hasOverflowed() || endOffset.value() > contents.size())
        return false;

    memcpySpan(contents.subspan(offset), data);
#else
    buffer.copyFrom(data, offset);
#endif
    return true;
}

bool writeSharedMemoryToBuffer(::WebGPU::Queue& queue, ::WebGPU::Buffer& buffer, IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>& argument, uint64_t bufferOffset)
{
    auto dataHandle = argument.take();
    auto data = dataHandle && *dataHandle ? WebCore::SharedMemory::map(WTF::move(**dataHandle), WebCore::SharedMemory::Protection::ReadOnly) : nullptr;
    if (!data || data->size() <= WebGPU::maxCrossProcessResourceCopySize)
        return false;

    // A large write reads the mapping in place, and keeps it alive until the GPU has.
    queue.writeBuffer(buffer, bufferOffset, ::WebGPU::ByteOwner::create(data.releaseNonNull()));
    return true;
}

#if PLATFORM(COCOA) && ENABLE(VIDEO)
WebGPUSwiftVideoFrames* WebGPUSwiftVideoFrames::create(const WebGPUSwiftRegistryHost& host)
{
    RefPtr gpu = host.m_gpu.get();
    RefPtr connection = gpu ? gpu->gpuConnectionToWebProcess() : nullptr;
    if (!connection)
        return nullptr;
    // As for RemoteDevice: a frame shared across is usually a reference into the video frame object heap, and the web
    // process's identity attributes any buffer read out of shared memory.
    auto reader = makeUnique<SharedVideoFrameReader>(RefPtr<RemoteVideoFrameObjectHeapHandle> { &connection->videoFrameObjectHeap() }, connection->webProcessIdentity());
    return &adoptRef(*new WebGPUSwiftVideoFrames(host, WTF::move(reader))).leakRef();
}

WebGPUSwiftVideoFrames::WebGPUSwiftVideoFrames(const WebGPUSwiftRegistryHost& host, std::unique_ptr<SharedVideoFrameReader>&& sharedVideoFrameReader)
    : m_host(host)
    , m_sharedVideoFrameReader(WTF::move(sharedVideoFrameReader))
{
}

WebGPUSwiftVideoFrames::~WebGPUSwiftVideoFrames() = default;

void WebGPUSwiftVideoFrames::setSemaphore(IPC::CxxDecodedArgument<IPC::Semaphore>& argument)
{
    if (auto semaphore = argument.take())
        m_sharedVideoFrameReader->setSemaphore(WTF::move(*semaphore));
}

void WebGPUSwiftVideoFrames::setSharedMemory(IPC::CxxDecodedArgument<WebCore::SharedMemory::Handle>& argument)
{
    if (auto handle = argument.take())
        m_sharedVideoFrameReader->setSharedMemory(WTF::move(*handle));
}

OptionalRemoteExternalTextureBacking WebGPUSwiftVideoFrames::importExternalTexture(::WebGPU::Device& device, IPC::CxxDecodedArgument<WebGPU::ExternalTextureDescriptor>& argument, bool& isInvalid)
{
    isInvalid = false;
    auto descriptor = argument.take();
    if (!descriptor) {
        isInvalid = true;
        return std::nullopt;
    }

    RefPtr gpu = m_host.m_gpu.get();
    RefPtr objectHeap = m_host.m_objectHeap.get();
    if (!gpu || !objectHeap)
        return std::nullopt;

    std::optional<WebKit::SharedVideoFrame> sharedVideoFrame = WTF::move(descriptor->sharedFrame);
    RetainPtr<CVPixelBufferRef> pixelBuffer { nullptr };
    if (sharedVideoFrame) {
        if (auto videoFrame = m_sharedVideoFrameReader->read(WTF::move(*sharedVideoFrame)))
            pixelBuffer = videoFrame->pixelBuffer();
    } else if (descriptor->mediaIdentifier) {
        if (RefPtr connection = gpu->gpuConnectionToWebProcess()) {
            connection->performWithMediaPlayerOnMainThread(*descriptor->mediaIdentifier, [&] (auto& player) mutable {
                auto videoFrame = player.videoFrameForCurrentTime();
                pixelBuffer = videoFrame ? videoFrame->pixelBuffer() : nullptr;
            });
        }
    }

    auto convertedDescriptor = objectHeap->convertFromBacking(*descriptor, pixelBuffer);
    if (!convertedDescriptor) {
        isInvalid = true;
        return std::nullopt;
    }

    RefPtr integration = gpu->backing();
    if (!integration)
        return std::nullopt;
    auto externalTexture = integration->importExternalTexture(device, *convertedDescriptor);
    if (!externalTexture) {
        isInvalid = true;
        return std::nullopt;
    }
    return RemoteExternalTextureBacking { *externalTexture };
}

void WebGPUSwiftVideoFrames::updateExternalTexture(::WebGPU::ExternalTexture& externalTexture, uint64_t mediaPlayerIdentifier)
{
    externalTexture.destroy();
    RefPtr gpu = m_host.m_gpu.get();
    RefPtr connection = gpu ? gpu->gpuConnectionToWebProcess() : nullptr;
    if (!connection)
        return;
    RetainPtr<CVPixelBufferRef> pixelBuffer { nullptr };
    connection->performWithMediaPlayerOnMainThread(WebCore::MediaPlayerIdentifier { mediaPlayerIdentifier }, [&pixelBuffer] (auto& player) mutable {
        auto videoFrame = player.videoFrameForCurrentTime();
        pixelBuffer = videoFrame ? videoFrame->pixelBuffer() : nullptr;
    });
    externalTexture.updateExternalTexture(pixelBuffer.get());
}

void WebGPUSwiftVideoFrames::copyExternalImageFromVideoFrameToTexture(::WebGPU::Queue& queue, IPC::CxxDecodedArgument<WebGPU::ImageCopyExternalImageVideoSource>& sourceArgument, IPC::CxxDecodedArgument<WebGPU::ImageCopyTextureTagged>& destinationArgument, IPC::CxxDecodedArgument<WebGPU::Extent3D>& copySizeArgument)
{
    auto source = sourceArgument.take();
    auto destination = destinationArgument.take();
    auto copySize = copySizeArgument.take();
    RefPtr objectHeap = m_host.m_objectHeap.get();
    RefPtr gpu = m_host.m_gpu.get();
    if (!source || !destination || !copySize || !objectHeap || !gpu)
        return;

    // Resolved the same way RemoteDevice resolves an external texture's frame: a shared frame is read
    // out of the shared video frame memory, and a media player identifier is asked for the frame it is
    // showing right now.
    RetainPtr<CVPixelBufferRef> pixelBuffer;
    // A frame's pixels are stored as decoded, so the transform that presents them travels separately.
    // A media player has already applied its asset's transform to the buffer it hands over, but a
    // WebCodecs frame carries one of its own.
    auto rotation = WebCore::VideoFrameRotation::None;
    bool isMirrored = false;
    auto takeFrame = [&](WebCore::VideoFrame& videoFrame) {
        pixelBuffer = videoFrame.pixelBuffer();
        rotation = videoFrame.rotation();
        isMirrored = videoFrame.isMirrored();
    };
    if (source->sharedFrame) {
        if (auto videoFrame = m_sharedVideoFrameReader->read(WTF::move(*source->sharedFrame)))
            takeFrame(*videoFrame);
    } else if (source->mediaIdentifier) {
        if (RefPtr connection = gpu->gpuConnectionToWebProcess()) {
            connection->performWithMediaPlayerOnMainThread(*source->mediaIdentifier, [&](auto& player) mutable {
                if (auto videoFrame = player.videoFrameForCurrentTime())
                    takeFrame(*videoFrame);
            });
        }
    }

    // A frame which could not be resolved leaves the destination texture alone, exactly as a video
    // with nothing decoded yet did on the readback path.
    if (!pixelBuffer)
        return;

    auto convertedSource = objectHeap->convertFromBacking(*source, WTF::move(pixelBuffer), rotation, isMirrored);
    ASSERT(convertedSource);
    auto convertedDestination = objectHeap->convertFromBacking(*destination);
    ASSERT(convertedDestination);
    if (!convertedSource || !convertedDestination)
        return;

    if (RefPtr integration = gpu->backing())
        integration->copyExternalImageToTexture(queue, *convertedSource, *convertedDestination, *copySize);
}
#endif // PLATFORM(COCOA) && ENABLE(VIDEO)

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
