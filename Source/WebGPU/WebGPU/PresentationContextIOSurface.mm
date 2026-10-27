/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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
#import "PresentationContextIOSurface.h"

#import "APIConversions.h"
#import "Texture.h"
#import "TextureView.h"
#import <wtf/FastMalloc.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cocoa/IOTypesSPI.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct PresentationContextIOSurfaceImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(PresentationContextIOSurfaceImplBox);
    WebGPU::PresentationContextIOSurfaceImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(PresentationContextIOSurfaceImplBox);

WTF_MAKE_TZONE_ALLOCATED_IMPL(PresentationContextIOSurface);

// The Impl copies the web process identity's send right while the Instance's is alive.
static std::unique_ptr<PresentationContextIOSurfaceImplBox> makeImplBox(const Instance& instance)
{
#if HAVE(IOSURFACE_SET_OWNERSHIP_IDENTITY) && HAVE(TASK_IDENTITY_TOKEN)
    if (const auto& webProcessID = instance.webProcessID())
        return makeUnique<PresentationContextIOSurfaceImplBox>(PresentationContextIOSurfaceImplBox { .impl = makePresentationContextIOSurfaceImpl(webProcessID->sendRight()) });
#else
    UNUSED_PARAM(instance);
#endif
    return makeUnique<PresentationContextIOSurfaceImplBox>(PresentationContextIOSurfaceImplBox { .impl = makePresentationContextIOSurfaceImpl(MACH_PORT_NULL) });
}

Ref<PresentationContextIOSurface> PresentationContextIOSurface::create(const WebGPU::PresentationContextDescriptor& descriptor, const Instance& instance)
{
    Ref presentationContextIOSurface = adoptRef(*new PresentationContextIOSurface(makeImplBox(instance)));
    if (!descriptor.registerCompositorIntegration)
        return presentationContextIOSurface;

    descriptor.registerCompositorIntegration([presentationContext = presentationContextIOSurface.copyRef()](std::span<const IOSurfaceRef> ioSurfaces) {
        presentationContext->renderBuffersWereRecreated(ioSurfaces);
    }, [presentationContext = presentationContextIOSurface.copyRef()](CompletionHandler<void()>&& completionHandler) {
        presentationContext->onSubmittedWorkScheduled([completionHandler = WTF::move(completionHandler)] mutable {
            completionHandler();
        });
    });

    return presentationContextIOSurface;
}

PresentationContextIOSurface::PresentationContextIOSurface(std::unique_ptr<PresentationContextIOSurfaceImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

PresentationContextIOSurface::~PresentationContextIOSurface() = default;

void PresentationContextIOSurface::renderBuffersWereRecreated(std::span<const IOSurfaceRef> ioSurfaces)
{
    m_impl->impl.renderBuffersWereRecreated();
    for (IOSurfaceRef surface : ioSurfaces) {
        // appendIOSurface takes a non-optional IOSurfaceRef: a null one (failed allocation) must not reach Swift.
        if (surface)
            m_impl->impl.appendIOSurface(surface);
    }
}

void PresentationContextIOSurface::onSubmittedWorkScheduled(Function<void()>&& completionHandler)
{
    if (m_impl->impl.hasDevice())
        borrowSwiftRetained(m_impl->impl.device()).getQueue()->onSubmittedWorkScheduled(WTF::move(completionHandler));
    else
        completionHandler();
}

RetainPtr<CGImageRef> PresentationContextIOSurface::getTextureAsNativeImage(uint32_t bufferIndex, bool& isIOSurfaceSupportedFormat)
{
    return adoptCF(m_impl->impl.textureAsNativeImage(bufferIndex, isIOSurfaceSupportedFormat));
}

void PresentationContextIOSurface::configure(const WebGPU::CanvasConfiguration& configuration)
{
    Ref device = metal(configuration.device.get());
    m_impl->impl.configure(configuration, device.ptr(), device->swiftImpl());
}

void PresentationContextIOSurface::unconfigure()
{
    m_impl->impl.unconfigure();
}

void PresentationContextIOSurface::present(uint32_t currentIndex)
{
    m_impl->impl.present(currentIndex);
}

Texture* PresentationContextIOSurface::currentTexture(uint32_t currentIndex)
{
    if (!m_impl->impl.validateCurrentTextureIndex(currentIndex))
        return m_impl->impl.hasInvalidTexture() ? &borrowSwiftRetained(m_impl->impl.invalidTexture()) : nullptr;

    return &borrowSwiftRetained(m_impl->impl.currentFrameTexture(currentIndex));
}

Seconds PresentationContextIOSurface::lastFrameGPUCost() const
{
    return Seconds { m_impl->impl.lastDrainedFrameGPUCostSeconds() };
}

Seconds PresentationContextIOSurface::lastFramePresentStall() const
{
    return Seconds { m_impl->impl.lastFramePresentStallSeconds() };
}

static WebGPU::TextureDescriptor canvasTextureDescriptor(const WebGPU::CanvasConfiguration& configuration, WebGPU::TextureFormat format, const std::array<WebGPU::TextureFormat, 1>& effectiveViewFormats, uint32_t width, uint32_t height)
{
    return WebGPU::TextureDescriptor {
        .label = { },
        .usage = configuration.usage,
        .dimension = WebGPU::TextureDimension::_2d,
        .size = {
            .width = width,
            .height = height,
            .depthOrArrayLayers = 1,
        },
        .format = format,
        .mipLevelCount = 1,
        .sampleCount = 1,
        // Without view formats in the configuration, the validation takes the format of the textures as
        // their only view format.
        .viewFormats = configuration.viewFormats.empty() ? std::span<const WebGPU::TextureFormat> { effectiveViewFormats } : configuration.viewFormats,
    };
}

NSString *errorValidatingCanvasTextureCreation(Device& device, const WebGPU::CanvasConfiguration& configuration, WebGPU::TextureFormat effectiveFormat, uint32_t width, uint32_t height)
{
    std::array effectiveViewFormats { effectiveFormat };
    return device.errorValidatingTextureCreation(canvasTextureDescriptor(configuration, effectiveFormat, effectiveViewFormats, width, height));
}

Ref<Texture> createCanvasTexture(id<MTLTexture> texture, const WebGPU::CanvasConfiguration& configuration, WebGPU::TextureFormat format, WebGPU::TextureFormat effectiveFormat, uint32_t width, uint32_t height, Device& device)
{
    std::array effectiveViewFormats { effectiveFormat };
    // The textures allow views only in the formats that the configuration lists.
    return Texture::create(texture, canvasTextureDescriptor(configuration, format, effectiveViewFormats, width, height), Vector<WebGPU::TextureFormat> { configuration.viewFormats }, device);
}

id<MTLLibrary> compileLibraryWithFastMath(id<MTLDevice> device, NSString *source)
{
    NSError *error = nil;
    MTLCompileOptions* options = [MTLCompileOptions new];
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    options.fastMathEnabled = YES;
    ALLOW_DEPRECATED_DECLARATIONS_END
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    if (error) {
        WTFLogAlways("%@", error); // NOLINT
        return nil;
    }
    return library;
}

CGImageRef createImageWithTextureBytes(id<MTLTexture> texture, size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow, CGColorSpaceRef colorSpace, CGBitmapInfo bitmapInfo)
{
    size_t imageBytesSize = bytesPerRow * height;
    void* imageBytes = FastMalloc::tryMalloc(imageBytesSize);
    if (!imageBytes)
        return nullptr;
    [texture getBytes:imageBytes bytesPerRow:bytesPerRow fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
    auto freeImageBytes = [](void* imageBytes, const void*, size_t) {
        FastMalloc::free(imageBytes);
    };
    RetainPtr dataProvider = adoptCF(CGDataProviderCreateWithData(imageBytes, imageBytes, imageBytesSize, freeImageBytes));
    return CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, colorSpace, bitmapInfo, dataProvider.get(), nullptr, false, kCGRenderingIntentDefault);
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs
