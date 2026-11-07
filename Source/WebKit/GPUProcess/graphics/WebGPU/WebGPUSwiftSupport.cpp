/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
#include <WebCore/ColorSpace.h>
#include <WebCore/IOSurface.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/NativeImage.h>
#include <WebCore/WebGPUExternalTextureDescriptor.h>
#include <WebCore/WebGPUImageCopyExternalImage.h>
#include <WebCore/WebGPUImageCopyTextureTagged.h>
#include <WebCore/WebGPUPredefinedColorSpace.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>

#if PLATFORM(COCOA) && ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeapHandle.h"
#include "SharedVideoFrame.h"
#include <WebCore/MediaPlayer.h>
#include <WebCore/VideoFrame.h>
#endif

namespace WebKit {

// The WebGPU implementation's forms of a source and a descriptor that name WebCore objects. std::nullopt if the source
// has nothing to copy.
#if ENABLE(VIDEO)
static ::WebGPU::VideoFrameRotation LEGACY_NODELETE convertToAPI(WebCore::VideoFrameRotation rotation)
{
    switch (rotation) {
    case WebCore::VideoFrameRotation::None:
        return ::WebGPU::VideoFrameRotation::None;
    case WebCore::VideoFrameRotation::Right:
        return ::WebGPU::VideoFrameRotation::Right;
    case WebCore::VideoFrameRotation::UpsideDown:
        return ::WebGPU::VideoFrameRotation::UpsideDown;
    case WebCore::VideoFrameRotation::Left:
        return ::WebGPU::VideoFrameRotation::Left;
    }

    ASSERT_NOT_REACHED();
    return ::WebGPU::VideoFrameRotation::None;
}
#endif

// The IOSurface format an accelerated ImageBuffer of this pixel format is backed by, expressed as the
// equivalent texture format, plus whether its alpha channel holds meaningful data. std::nullopt for
// the formats GPUQueue::copyExternalImageToTexture keeps on the CPU readback path.
struct SourceTextureFormat {
    ::WebGPU::TextureFormat format;
    bool hasAlpha;
};

static std::optional<SourceTextureFormat> LEGACY_NODELETE sourceTextureFormat(WebCore::PixelFormat pixelFormat)
{
    switch (pixelFormat) {
    case WebCore::PixelFormat::RGBA8:
        return SourceTextureFormat { ::WebGPU::TextureFormat::Rgba8unorm, true };
    case WebCore::PixelFormat::BGRA8:
        return SourceTextureFormat { ::WebGPU::TextureFormat::Bgra8unorm, true };
    case WebCore::PixelFormat::BGRX8:
        // IOSurface::Format::BGRX uses the same IOSurface pixel format as BGRA, but CoreGraphics
        // renders into it with kCGImageAlphaNoneSkipFirst, so the alpha byte is undefined.
        return SourceTextureFormat { ::WebGPU::TextureFormat::Bgra8unorm, false };
    case WebCore::PixelFormat::RGBX8:
        return SourceTextureFormat { ::WebGPU::TextureFormat::Rgba8unorm, false };
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case WebCore::PixelFormat::RGBA16F:
        return SourceTextureFormat { ::WebGPU::TextureFormat::Rgba16float, true };
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16)
    case WebCore::PixelFormat::RGBA16:
        return SourceTextureFormat { ::WebGPU::TextureFormat::Rgba16unorm, true };
#endif
#if ENABLE(PIXEL_FORMAT_RGB10)
    case WebCore::PixelFormat::RGB10:
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    case WebCore::PixelFormat::RGB10A8:
#endif
#if ENABLE(PIXEL_FORMAT_RGB10) || ENABLE(PIXEL_FORMAT_RGB10A8)
        // Packed 10-bit surfaces have no single-plane MTLPixelFormat equivalent.
        return std::nullopt;
#endif
    }

    ASSERT_NOT_REACHED();
    return std::nullopt;
}

static std::optional<::WebGPU::ImageCopyExternalImage> backingImageCopyExternalImage(const WebCore::WebGPUExternalImageSource& source)
{
    ::WebGPU::ImageCopyExternalImage backingSource;
    backingSource.origin = source.origin.value_or(::WebGPU::Origin2D { });
    backingSource.flipY = source.flipY;
    backingSource.hasAlpha = false;
    // An ImageBitmap created with premultiplyAlpha: "none" was put into its buffer straight, so
    // the caller has to say; a buffer a 2D context composited is premultiplied.
    backingSource.premultipliedAlpha = source.premultipliedAlpha;

#if ENABLE(VIDEO)
    if (source.videoSource) {
        // The decoded frame the GPU process resolved for us. Its extent, its crop and its primaries
        // all travel with the frame, so the backing queue reads them off it rather than being told
        // here; and a decoded frame is opaque, so its alpha is replaced with 1 the way an external
        // texture's is.
        auto* pixelBuffer = std::get_if<RetainPtr<CVPixelBufferRef>>(&*source.videoSource);
        if (!pixelBuffer || !*pixelBuffer)
            return std::nullopt;

        backingSource.pixelBuffer = *pixelBuffer;
        // The display transform is the one thing about the frame its pixel buffer does not carry.
        backingSource.pixelBufferRotation = convertToAPI(source.videoSourceRotation);
        backingSource.pixelBufferIsMirrored = source.videoSourceIsMirrored;
        backingSource.premultipliedAlpha = true;
    } else
#endif
    {
        RefPtr sourceImageBuffer = source.imageBuffer;
        if (!sourceImageBuffer)
            return std::nullopt;

        // Only accelerated ImageBuffers have an IOSurface to wrap in an MTLTexture. GPUQueue rejects
        // unaccelerated sources before we get here, but the backing may have been dropped since.
        auto* surface = sourceImageBuffer->surface();
        if (!surface)
            return std::nullopt;

        auto sourceSize = sourceImageBuffer->truncatedLogicalSize();
        if (!sourceSize.width() || !sourceSize.height())
            return std::nullopt;

        auto sourceFormat = sourceTextureFormat(sourceImageBuffer->pixelFormat());
        if (!sourceFormat)
            return std::nullopt;

        backingSource.source = surface->surface();
        backingSource.sourceFormat = sourceFormat->format;
        backingSource.sourceSize = { static_cast<uint32_t>(sourceSize.width()), static_cast<uint32_t>(sourceSize.height()) };
        backingSource.hasAlpha = sourceFormat->hasAlpha;
        backingSource.colorSpace = sourceImageBuffer->colorSpace() == WebCore::ColorSpace::DisplayP3() ? ::WebGPU::PredefinedColorSpace::DisplayP3 : ::WebGPU::PredefinedColorSpace::SRGB;
    }

    return backingSource;
}

#if ENABLE(VIDEO)
static ::WebGPU::ExternalTextureDescriptor backingExternalTextureDescriptor(const WebCore::WebGPUExternalTextureDescriptor& descriptor)
{
    auto* pixelBuffer = std::get_if<RetainPtr<CVPixelBufferRef>>(&descriptor.videoBacking);
    return {
        .label = descriptor.label,
        .pixelBuffer = pixelBuffer ? *pixelBuffer : nullptr,
        .colorSpace = WebCore::convertToWebGPU(descriptor.colorSpace),
        .visibleSize = {
            .width = static_cast<uint32_t>(std::max(0, descriptor.visibleSize.width())),
            .height = static_cast<uint32_t>(std::max(0, descriptor.visibleSize.height())),
        },
    };
}
#endif

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

void WebGPUSwiftRegistryHost::addXRBinding(uint64_t deviceIdentifier, uint64_t identifier) const
{
    RefPtr objectHeap = m_objectHeap.get();
    RefPtr gpu = m_gpu.get();
    RefPtr streamConnection = this->streamConnection();
    RefPtr connection = gpu ? gpu->gpuConnectionToWebProcess() : nullptr;
    if (!objectHeap || !streamConnection || !connection)
        return;
    WebGPUIdentifier bindingIdentifier { identifier };
    auto remoteBinding = RemoteXRBinding::create(*connection, objectHeap->swiftImplTable().createXRBinding(deviceIdentifier), *objectHeap, *gpu, streamConnection.releaseNonNull(), bindingIdentifier);
    objectHeap->addObject(bindingIdentifier, remoteBinding);
}

#if PLATFORM(COCOA)
std::optional<::WebGPU::ImageCopyExternalImage> WebGPUSwiftRegistryHost::externalImage(uint64_t imageBufferIdentifier, ::WebGPU::Origin2D origin, bool flipY, bool premultipliedAlpha) const
{
    RefPtr gpu = m_gpu.get();
    if (!gpu)
        return std::nullopt;

    // ConvertFromBackingContext cannot resolve the source, because only RemoteGPU can reach the
    // RemoteRenderingBackend which owns the ImageBuffer.
    RefPtr imageBuffer = gpu->imageBuffer(WebCore::RenderingResourceIdentifier { imageBufferIdentifier });
    if (!imageBuffer)
        return std::nullopt;

    return backingImageCopyExternalImage({
        .origin = origin,
        .flipY = flipY,
        .imageBuffer = WTF::move(imageBuffer),
        .premultipliedAlpha = premultipliedAlpha,
    });
}
#endif

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

OptionalOwnedBytes mapSharedMemory(IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>& argument)
{
    auto dataHandle = argument.take();
    auto data = dataHandle && *dataHandle ? WebCore::SharedMemory::map(WTF::move(**dataHandle), WebCore::SharedMemory::Protection::ReadOnly) : nullptr;
    if (!data || data->size() <= WebGPU::maxCrossProcessResourceCopySize)
        return std::nullopt;
    return ::WebGPU::OwnedBytes { ::WebGPU::ByteOwner::create(data.releaseNonNull()) };
}

bool isValidWebGPUWriteWithCopySize(size_t size)
{
    return size <= WebGPU::maxCrossProcessResourceCopySize;
}

#if PLATFORM(COCOA)
WebGPUCompositorRenderBuffers* WebGPUCompositorRenderBuffers::create()
{
    return &adoptRef(*new WebGPUCompositorRenderBuffers).leakRef();
}

WebGPUCompositorRenderBuffers::WebGPUCompositorRenderBuffers() = default;

WebGPUCompositorRenderBuffers::~WebGPUCompositorRenderBuffers() = default;

void WebGPUCompositorRenderBuffers::clear()
{
    m_buffers.clear();
}

void WebGPUCompositorRenderBuffers::allocate(int32_t width, int32_t height, IPC::CxxDecodedArgument<WebCore::ColorSpace>& colorSpaceArgument, bool premultiplied, uint8_t textureFormat, uint32_t bufferCount)
{
    auto colorSpace = colorSpaceArgument.take();
    RELEASE_ASSERT(colorSpace);

    constexpr int max2DTextureSize = 16384;
    width = std::max(1, std::min(max2DTextureSize, width));
    height = std::max(1, std::min(max2DTextureSize, height));
    WebCore::IOSurface::Format colorFormat;
    switch (static_cast<::WebGPU::TextureFormat>(textureFormat)) {
    case ::WebGPU::TextureFormat::Rgba8unorm:
    case ::WebGPU::TextureFormat::Rgba8unormSRGB:
        colorFormat = premultiplied ? WebCore::IOSurface::Format::RGBA : WebCore::IOSurface::Format::RGBX;
        break;
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case ::WebGPU::TextureFormat::Rgba16float:
        colorFormat = WebCore::IOSurface::Format::RGBA16F;
        break;
#endif
    default:
        colorFormat = premultiplied ? WebCore::IOSurface::Format::BGRA : WebCore::IOSurface::Format::BGRX;
        break;
    }

    for (unsigned bufferIndex = 0; bufferIndex < std::min<unsigned>(3u, bufferCount); ++bufferIndex) {
        if (auto buffer = WebCore::IOSurface::create(nullptr, WebCore::IntSize(width, height), *colorSpace, WebCore::IOSurface::Name::WebGPU, colorFormat))
            m_buffers.append(makeUniqueRefFromNonNullUniquePtr(WTF::move(buffer)));
    }
}

IOSurfaceRef copyCompositorRenderBufferSurface(const WebGPUCompositorRenderBuffers& buffers, size_t index)
{
    return RetainPtr { buffers.m_buffers[index]->surface() }.leakRef();
}

void WebGPUCompositorRenderBuffers::encodeSendRights(IPC::SwiftReplyEncoder& encoder) const
{
    encoder.encodeWithArgumentCoder(m_buffers.map([](const auto& buffer) {
        return buffer->createSendRight();
    }));
}

void WebGPUCompositorRenderBuffers::setContentEDRHeadroom(float headroom)
{
#if HAVE(SUPPORT_HDR_DISPLAY)
    for (auto& buffer : m_buffers)
        buffer->setContentEDRHeadroom(headroom);
#else
    UNUSED_PARAM(headroom);
#endif
}

void WebGPUCompositorRenderBuffers::paint(const WebGPUSwiftRegistryHost& host, CGImageRef textureImage, uint32_t bufferIndex, bool premultiplied, uint64_t imageBufferIdentifier) const
{
    RefPtr gpu = host.m_gpu.get();
    if (!gpu)
        return;
    WebCore::RenderingResourceIdentifier identifier { imageBufferIdentifier };
    if (textureImage) {
        if (RefPtr image = WebCore::NativeImage::create(RetainPtr { textureImage })) {
            CGImageSetCachingFlags(image->platformImage().get(), kCGImageCachingTransient);
            gpu->paintNativeImageToImageBuffer(*image, identifier);
        }
        return;
    }

    // A premultiplied canvas must keep its alpha channel so transparent pixels
    // composite over the page; an opaque canvas forces the alpha to be ignored.
    // This matters for RGBA16F, whose IOSurface format cannot itself encode opacity.
    auto shouldForceOpaque = premultiplied ? WebCore::IOSurface::ShouldForceOpaque::No : WebCore::IOSurface::ShouldForceOpaque::Yes;
    m_buffers[bufferIndex]->withNativeImage(shouldForceOpaque, [&](WebCore::NativeImage* image) {
        if (!image)
            return;
        CGImageSetCachingFlags(image->platformImage().get(), kCGImageCachingTransient);
        gpu->paintNativeImageToImageBuffer(*image, identifier);
    });
}
#endif

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

std::optional<::WebGPU::ExternalTextureDescriptor> WebGPUSwiftVideoFrames::externalTextureDescriptor(IPC::CxxDecodedArgument<WebGPU::ExternalTextureDescriptor>& argument, bool& isInvalid)
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
    return backingExternalTextureDescriptor(*convertedDescriptor);
}

std::optional<::WebGPU::ExternalTextureDescriptor> WebGPUSwiftVideoFrames::mediaPlayerFrame(uint64_t mediaPlayerIdentifier)
{
    RefPtr gpu = m_host.m_gpu.get();
    RefPtr connection = gpu ? gpu->gpuConnectionToWebProcess() : nullptr;
    if (!connection)
        return std::nullopt;
    RetainPtr<CVPixelBufferRef> pixelBuffer { nullptr };
    connection->performWithMediaPlayerOnMainThread(WebCore::MediaPlayerIdentifier { mediaPlayerIdentifier }, [&pixelBuffer] (auto& player) mutable {
        auto videoFrame = player.videoFrameForCurrentTime();
        pixelBuffer = videoFrame ? videoFrame->pixelBuffer() : nullptr;
    });
    return ::WebGPU::ExternalTextureDescriptor { .pixelBuffer = WTF::move(pixelBuffer) };
}

std::optional<::WebGPU::ImageCopyExternalImage> WebGPUSwiftVideoFrames::externalImage(IPC::CxxDecodedArgument<WebGPU::ImageCopyExternalImageVideoSource>& sourceArgument)
{
    auto source = sourceArgument.take();
    RefPtr objectHeap = m_host.m_objectHeap.get();
    RefPtr gpu = m_host.m_gpu.get();
    if (!source || !objectHeap || !gpu)
        return std::nullopt;

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
        return std::nullopt;

    auto convertedSource = objectHeap->convertFromBacking(*source, WTF::move(pixelBuffer), rotation, isMirrored);
    ASSERT(convertedSource);
    if (!convertedSource)
        return std::nullopt;
    return backingImageCopyExternalImage(*convertedSource);
}
#endif // PLATFORM(COCOA) && ENABLE(VIDEO)

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
