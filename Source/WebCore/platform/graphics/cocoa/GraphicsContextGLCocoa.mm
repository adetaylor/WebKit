/*
 * Copyright (C) 2009-2021 Apple Inc. All rights reserved.
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

#if ENABLE(WEBGL)
#import "GraphicsContextGLCocoa.h"

#import "ANGLEHeaders.h"
#import "ANGLEUtilities.h"
#import "ANGLEUtilitiesCocoa.h"
#import "CVUtilities.h"
#import "GraphicsLayerContentsDisplayDelegate.h"
#import "Logging.h"
#import "PixelBuffer.h"
#import "ProcessIdentity.h"
#import "WebCoreWebGL.h"
#import <CoreGraphics/CGBitmapContext.h>
#import <Metal/Metal.h>
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/cocoa/MetalSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/HashMap.h>
#import <wtf/Lock.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RuntimeApplicationChecks.h>
#import <wtf/StdLibExtras.h>
#import <wtf/text/CString.h>

#if PLATFORM(IOS_FAMILY)
#import "WebCoreThread.h"
#endif

#if ENABLE(VIDEO)
#import "MediaPlayerPrivate.h"
#import "PixelBufferConformerCV.h"
#import "VideoFrameCV.h"
#endif

#import "CoreVideoSoftLink.h"

namespace WebCore {

using GL = GraphicsContextGL;

static_assert(std::to_underlying(GraphicsContextGL::SurfaceBuffer::DrawingBuffer) == 0, "CocoaGLSurfaceBuffer");
static_assert(std::to_underlying(GraphicsContextGL::SurfaceBuffer::DisplayBuffer) == 1, "CocoaGLSurfaceBuffer");
static_assert(std::to_underlying(GraphicsContextGLPowerPreference::Default) == 0 && std::to_underlying(GraphicsContextGLPowerPreference::LowPower) == 1 && std::to_underlying(GraphicsContextGLPowerPreference::HighPerformance) == 2, "ANGLECocoa::getMetalDisplay");

WTF_MAKE_TZONE_ALLOCATED_IMPL(GraphicsContextGLCocoa);

#if ENABLE(VIDEO)
CVPixelBufferRef GLContextCallbacks::convertPixelBufferTo420f(CVPixelBufferRef pixelBuffer)
{
    auto conformer = makeUnique<PixelBufferConformerCV>((__bridge CFDictionaryRef)@{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) });
    return conformer->convert(pixelBuffer).leakRef();
}
#endif

IOSurfaceRef GLContextCallbacks::createDrawingBufferSurface(uint64_t contextID, int32_t width, int32_t height)
{
    // Only a GraphicsContextGLCocoa makes the Cocoa platform, which is what calls this.
    auto* context = static_cast<GraphicsContextGLCocoa*>(GraphicsContextGLANGLE::contextForCallback(contextID));
    if (!context)
        return nullptr;
    return context->createDrawingBufferSurface({ width, height }).leakRef();
}

RefPtr<GraphicsContextGLCocoa> GraphicsContextGLCocoa::create(GraphicsContextGLAttributes&& attributes, ProcessIdentity&& resourceOwner)
{
    auto context = adoptRef(*new GraphicsContextGLCocoa(WTF::move(attributes), WTF::move(resourceOwner)));
    if (!context->initialize())
        return nullptr;
    return context;
}

GraphicsContextGLCocoa::GraphicsContextGLCocoa(GraphicsContextGLAttributes&& creationAttributes, ProcessIdentity&& resourceOwner)
    : GraphicsContextGLANGLE(WTF::move(creationAttributes))
    , m_resourceOwner(WTF::move(resourceOwner))
    , m_drawingBufferColorSpace(ColorSpace::SRGB())
{
}

GraphicsContextGLCocoa::~GraphicsContextGLCocoa()
{
    auto island = islandCalls();
    if (island.hasContext())
        island.willDestroyPlatform();
    else if (island.hasPlatform())
        island.destroyPlatformWithoutContext();
}

IOSurface* GraphicsContextGLCocoa::displayBufferSurface()
{
    auto island = islandCalls();
    if (!island.hasPlatform())
        return nullptr;
    auto surface = adoptCF(island.displayBufferSurface());
    if (!surface)
        return nullptr;
    auto& surfaces = m_displayBufferSurfaces;
    for (auto& displayBufferSurface : surfaces) {
        if (displayBufferSurface && displayBufferSurface->surface() == surface.get())
            return displayBufferSurface.get();
    }
    auto& displayBufferSurface = surfaces[m_nextDisplayBufferSurface++ % surfaces.size()];
    displayBufferSurface = IOSurface::createFromSurface(surface.get(), std::nullopt);
    return displayBufferSurface.get();
}

bool GraphicsContextGLCocoa::platformInitializeContext()
{
    GraphicsContextGLAttributes attributes = contextAttributes();
    m_isForWebGL2 = attributes.isWebGL2;
#if PLATFORM(MAC)
    uint64_t windowGPUID = attributes.windowGPUID;
#else
    uint64_t windowGPUID = 0;
#endif
#if ENABLE(WEBXR)
    bool xrCompatible = attributes.xrCompatible;
#else
    bool xrCompatible = false;
#endif
#if HAVE(TASK_IDENTITY_TOKEN)
    uint32_t ownershipIdentity = m_resourceOwner ? m_resourceOwner.taskIdToken() : 0;
#else
    uint32_t ownershipIdentity = 0;
#endif
    auto maximumSurfaceSize = IOSurface::maximumSize();
    auto island = islandCalls();
    if (!island.createCocoaPlatform(contextID(), attributes.isWebGL2, attributes.alpha, std::to_underlying(attributes.powerPreference), windowGPUID, xrCompatible, ownershipIdentity, maximumSurfaceSize.width(), maximumSurfaceSize.height())) {
        LOG(WebGL, "EGLContext Initialization failed.");
        return false;
    }
    m_displayObj = ANGLEHandles::unwrap(island.platformDisplay());
    m_configObj = ANGLEHandles::unwrap(island.platformConfig());
    m_contextObj = ANGLEHandles::unwrap(island.platformContext());
    lazyInitialize(m_finishedMetalSharedEventListener, adoptNS([[MTLSharedEventListener alloc] init]));
    if (!m_finishedMetalSharedEventListener) {
        ASSERT_NOT_REACHED();
        return false;
    }
    lazyInitialize(m_finishedMetalSharedEvent, newSharedEvent(m_displayObj));
    if (!m_finishedMetalSharedEvent) {
        ASSERT_NOT_REACHED();
        return false;
    }
    return true;
}

void GraphicsContextGLCocoa::createIslandContext()
{
    islandCalls().createCocoaContext(contextID(), contextAttributes().supportWebGLDraftExtensions);
}

bool GraphicsContextGLCocoa::isDisplayInitializedForTesting(GCGLDisplay display)
{
    return GLIslandCalls::isDisplayInitializedForTesting(ANGLEHandles::wrap<ANGLEDisplayTag>(display));
}

bool GraphicsContextGLCocoa::reshapeDrawingBuffer()
{
    // The island's Cocoa platform reshapes the drawing buffers.
    ASSERT_NOT_REACHED();
    return false;
}

RetainPtr<IOSurfaceRef> GraphicsContextGLCocoa::copySurfaceBuffer(SurfaceBuffer bufferType)
{
    return adoptCF(islandCalls().copySurfaceBuffer(std::to_underlying(bufferType)));
}

void GraphicsContextGLCocoa::setDrawingBufferColorSpace(const ColorSpace& colorSpace)
{
    if (!makeContextCurrent())
        return;
    if (m_drawingBufferColorSpace == colorSpace)
        return;
    m_drawingBufferColorSpace = colorSpace;
    islandCalls().drawingBufferColorSpaceDidChange();
}

RetainPtr<IOSurfaceRef> GraphicsContextGLCocoa::createDrawingBufferSurface(IntSize size)
{
    IOSurface::IOSurfaceOptions options;
#if HAVE(IOSURFACE_ALPHA_CHANNEL_MODE)
    if (contextAttributes().alpha)
        options.alphaPremultiplication = contextAttributes().premultipliedAlpha ? AlphaPremultiplication::Premultiplied : AlphaPremultiplication::Unpremultiplied;
#endif
    auto surface = IOSurface::create(nullptr, size, m_drawingBufferColorSpace, IOSurface::Name::GraphicsContextGL, IOSurface::Format::BGRA, UseLosslessCompression::No, options);
    if (!surface)
        return nullptr;
    if (m_resourceOwner)
        surface->setOwnershipIdentity(m_resourceOwner);
    return surface->surface();
}

bool GraphicsContextGLCocoa::hasSpareDrawingBuffersInUse() const
{
    return islandCalls().hasSpareDrawingBuffersInUse();
}

void GraphicsContextGLCocoa::releaseIdleSpareDrawingBuffers()
{
    islandCalls().releaseIdleSpareDrawingBuffers();
}

size_t GraphicsContextGLCocoa::spareDrawingBufferCountForTesting() const
{
    return islandCalls().spareDrawingBufferCountForTesting();
}

size_t GraphicsContextGLCocoa::volatileSpareDrawingBufferCountForTesting() const
{
    return islandCalls().volatileSpareDrawingBufferCountForTesting();
}

void* GraphicsContextGLCocoa::createPbufferAndAttachIOSurface(GCGLenum target, PbufferAttachmentUsage usage, GCGLenum internalFormat, GCGLsizei width, GCGLsizei height, GCGLenum type, IOSurfaceRef surface, GCGLuint plane)
{
    if (target != GraphicsContextGL::TEXTURE_2D) {
        LOG(WebGL, "Unknown texture target %d.", static_cast<int>(target));
        return nullptr;
    }

    auto usageHint = [&] () -> EGLint {
        if (usage == PbufferAttachmentUsage::Read)
            return EGL_IOSURFACE_READ_HINT_ANGLE;
        if (usage == PbufferAttachmentUsage::Write)
            return EGL_IOSURFACE_WRITE_HINT_ANGLE;
        return EGL_IOSURFACE_READ_HINT_ANGLE | EGL_IOSURFACE_WRITE_HINT_ANGLE;
    }();

    return WebCore::createPbufferAndAttachIOSurface(m_displayObj, m_configObj, target, usageHint, internalFormat, width, height, type, surface, plane);
}

void GraphicsContextGLCocoa::destroyPbufferAndDetachIOSurface(void* handle)
{
    WebCore::destroyPbufferAndDetachIOSurface(m_displayObj, handle);
}

#if ENABLE(WEBXR)
GCGLExternalImage GraphicsContextGLCocoa::createExternalImage(ExternalImageSource&& source, GCGLenum internalFormat, GCGLint layer)
{
    EGLDeviceEXT eglDevice = EGL_NO_DEVICE_EXT;
    if (!EGL_QueryDisplayAttribEXT(platformDisplay(), EGL_DEVICE_EXT, reinterpret_cast<EGLAttrib*>(&eglDevice))) {
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }

    id<MTLDevice> rawMtlDevice = nil;
    if (!EGL_QueryDeviceAttribEXT(eglDevice, EGL_METAL_DEVICE_ANGLE, reinterpret_cast<EGLAttrib*>(&rawMtlDevice))) {
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }
    RetainPtr<id<MTLDevice>> mtlDevice = rawMtlDevice;

    RetainPtr<id<MTLTexture>> texture = WTF::switchOn(WTF::move(source),
    [&](EGLImageSourceIOSurfaceHandle&& ioSurface) -> RetainPtr<id> {
        auto surface = IOSurface::createFromSendRight(WTF::move(ioSurface.handle));
        if (!surface)
            return nullptr;

        auto size = surface->size();
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:size.width() height:size.height() mipmapped:NO];
        [desc setUsage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget];

        RetainPtr tex = adoptNS([mtlDevice newTextureWithDescriptor:desc iosurface:retainPtr(surface->surface()).get() plane:0]);
        return tex;
    },
    [&](EGLImageSourceMTLSharedTextureHandle&& sharedTexture) -> RetainPtr<id> {
        auto handle = adoptNS([[MTLSharedTextureHandle alloc] initWithMachPort:sharedTexture.handle.sendRight()]);
        if (!handle)
            return nullptr;

        if (mtlDevice != [handle device]) {
            LOG(WebGL, "MTLSharedTextureHandle does not have the same Metal device as platformDisplay.");
            return nullptr;
        }

        // Create a MTLTexture out of the MTLSharedTextureHandle.
        RetainPtr<id> texture = adoptNS([mtlDevice newSharedTextureWithHandle:handle.get()]);
        return texture;
        // FIXME: Does the texture have the correct usage mode?
    });

    if (!texture) {
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }

    // Create an EGLImage out of the MTLTexture
    Vector<EGLint, 6> attributes;
    attributes.appendList({ EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE, layer });
    if (internalFormat)
        attributes.appendList({ EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, static_cast<EGLint>(internalFormat) });
    attributes.appendList({ EGL_NONE, EGL_NONE });
    auto eglImage = EGL_CreateImageKHR(platformDisplay(), EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, reinterpret_cast<EGLClientBuffer>(texture.get()), attributes.span().data());
    if (!eglImage) {
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }
    return addExternalImage(eglImage);
}

void GraphicsContextGLCocoa::bindExternalImage(GCGLenum target, GCGLExternalImage image)
{
    islandCalls().bindExternalImage(target, image);
}

bool GraphicsContextGLCocoa::addFoveation(IntSize physicalSizeLeft, IntSize physicalSizeRight, IntSize screenSize, std::span<const GCGLfloat> horizontalSamplesLeft, std::span<const GCGLfloat> verticalSamplesLeft, std::span<const GCGLfloat> horizontalSamplesRight)
{
    m_rasterizationRateMap[PlatformXR::Layout::Shared] = newRasterizationRateMap(m_displayObj, physicalSizeLeft, physicalSizeRight, screenSize, horizontalSamplesLeft, verticalSamplesLeft, horizontalSamplesRight);
    return !!m_rasterizationRateMap[PlatformXR::Layout::Shared];
}

void GraphicsContextGLCocoa::enableFoveation(PlatformGLObject rbo)
{
#if !PLATFORM(IOS_FAMILY_SIMULATOR)
    if (!makeContextCurrent())
        return;
    GL_BindMetalRasterizationRateMapANGLE(rbo, m_rasterizationRateMap[PlatformXR::Layout::Shared].get());
    GL_Enable(GL::VARIABLE_RASTERIZATION_RATE_ANGLE);
#else
    UNUSED_PARAM(rbo);
#endif
}

void GraphicsContextGLCocoa::disableFoveation()
{
#if !PLATFORM(IOS_FAMILY_SIMULATOR)
    if (!makeContextCurrent())
        return;
    GL_Disable(GL::VARIABLE_RASTERIZATION_RATE_ANGLE);
    GL_BindMetalRasterizationRateMapANGLE(0, nullptr);
#endif
}

#if ENABLE(WEBXR)
void GraphicsContextGLCocoa::framebufferResolveRenderbuffer(GCGLenum target, GCGLenum attachment, GCGLenum renderbuffertarget, PlatformGLObject renderbuffer)
{
    if (!makeContextCurrent())
        return;
    GL_FramebufferResolveRenderbufferWEBKIT(target, attachment, renderbuffertarget, renderbuffer);
}
#endif

RetainPtr<id> GraphicsContextGLCocoa::newSharedEventWithMachPort(mach_port_t sharedEventSendRight)
{
    return WebCore::newSharedEventWithMachPort(m_displayObj, sharedEventSendRight);
}

GCGLExternalSync GraphicsContextGLCocoa::createExternalSync(ExternalSyncSource&& syncEvent)
{
    auto [syncEventHandle, signalValue] = WTF::move(syncEvent);
    auto sharedEvent = newSharedEventWithMachPort(syncEventHandle.sendRight());
    if (!sharedEvent) {
        LOG(WebGL, "Unable to create a MTLSharedEvent from the syncEvent.");
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }
    auto* eglSync = createMetalSharedEventEGLSync(sharedEvent.get(), signalValue);
    if (!eglSync) {
        addError(GCGLErrorCode::InvalidOperation);
        return { };
    }
    return addExternalSync(eglSync);

}

bool GraphicsContextGLCocoa::enableRequiredWebXRExtensions()
{
    return islandCalls().enableRequiredWebXRExtensions();
}

#endif

void* GraphicsContextGLCocoa::createMetalSharedEventEGLSync(id sharedEvent, uint64_t signalValue)
{
    static_assert(sizeof(EGLAttrib) == sizeof(void*), "EGLAttrib not pointer-sized!");
    auto signalValueLo = static_cast<EGLAttrib>(signalValue);
    auto signalValueHi = static_cast<EGLAttrib>(signalValue >> 32);

    // FIXME: How do we check for available extensions?
    auto display = platformDisplay();
    const EGLAttrib syncAttributes[] = {
        EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE, reinterpret_cast<EGLAttrib>(sharedEvent),
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, signalValueLo,
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, signalValueHi,
        EGL_NONE
    };
    return EGL_CreateSync(display, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, syncAttributes);
}

void GraphicsContextGLCocoa::waitUntilWorkScheduled()
{
    islandCalls().waitUntilWorkScheduled();
}

void GraphicsContextGLCocoa::prepareForDisplay()
{
    prepareForDisplayWithFinishedSignal([] { });
}

void GraphicsContextGLCocoa::prepareForDisplayWithFinishedSignal(Function<void()> finishedSignal)
{
    auto context = islandCalls();
    if (!context.willPrepareForDisplay()) {
        finishedSignal();
        return;
    }
    // The fence inserted by this will be scheduled because next BindTexImage will wait until scheduled.
    insertFinishedSignalOrInvoke(WTF::move(finishedSignal));
    context.didPrepareForDisplay();
}

void GraphicsContextGLCocoa::insertFinishedSignalOrInvoke(Function<void()> signal)
{
    static std::atomic<uint64_t> nextSignalValue;
    uint64_t signalValue = ++nextSignalValue;
    RetainPtr<id<MTLSharedEvent>> event = m_finishedMetalSharedEvent.get();
    // The block below has to be a real compiler generated block instead of BlockPtr due to a Metal bug. rdar://108035473
    __block Function<void()> blockSignal = WTF::move(signal);
    [event notifyListener:m_finishedMetalSharedEventListener.get() atValue:signalValue block:^(id<MTLSharedEvent>, uint64_t) {
        blockSignal();
    }];
    auto* eglSync = createMetalSharedEventEGLSync(event.get(), signalValue);
    if (!eglSync) [[unlikely]] {
        event.get().signaledValue = signalValue;
        ASSERT_NOT_REACHED();
        return;
    }
    bool result = EGL_DestroySync(platformDisplay(), eglSync);
    ASSERT_UNUSED(result, result);
}

RefPtr<PixelBuffer> GraphicsContextGLCocoa::readCompositedResults()
{
    auto pixelBuffer = createPixelBufferForPaintResults();
    if (!pixelBuffer)
        return nullptr;
    if (!islandCalls().readCompositedResults(GLLender<uint8_t> { pixelBuffer->bytes() }.view(), pixelBuffer->size().width(), pixelBuffer->size().height()))
        return nullptr;
    return pixelBuffer;
}

#if ENABLE(MEDIA_STREAM) || ENABLE(WEB_CODECS)

RefPtr<VideoFrame> GraphicsContextGLCocoa::surfaceBufferToVideoFrame(SurfaceBuffer buffer)
{
    if (!makeContextCurrent())
        return nullptr;
    if (buffer == SurfaceBuffer::DrawingBuffer)
        prepareTexture();
    RetainPtr copy = copySurfaceBuffer(buffer);
    if (!copy)
        return nullptr;
    // The flip is this context's own work, so the encoder reading the copy needs it scheduled.
    waitUntilWorkScheduled();
    auto mediaSamplePixelBuffer = createCVPixelBuffer(copy.get());
    if (!mediaSamplePixelBuffer)
        return nullptr;
    // The surface describes the color space, but a pixel buffer consumer looks for the attachment.
    RetainPtr colorSpace = m_drawingBufferColorSpace.platformColorSpace();
    CVBufferSetAttachment(mediaSamplePixelBuffer->get(), kCVImageBufferCGColorSpaceKey, colorSpace.get(), kCVAttachmentMode_ShouldPropagate);
    return VideoFrameCV::create({ }, false, VideoFrame::Rotation::None, WTF::move(*mediaSamplePixelBuffer));
}
#endif

RefPtr<GraphicsLayerContentsDisplayDelegate> GraphicsContextGLCocoa::layerContentsDisplayDelegate()
{
    return nullptr;
}

// Says how the alpha of the contents of the surface buffers is to be interpreted.
static CGImageAlphaInfo LEGACY_NODELETE alphaInfoForSurfaceBufferContents(const GraphicsContextGLAttributes& attributes)
{
    if (!attributes.alpha)
        return kCGImageAlphaNoneSkipFirst;
    if (attributes.premultipliedAlpha)
        return kCGImageAlphaPremultipliedFirst;
    return kCGImageAlphaFirst;
}

RefPtr<NativeImage> GraphicsContextGLCocoa::copyNativeImage(SurfaceBuffer buffer)
{
    if (!makeContextCurrent())
        return nullptr;
    if (buffer == SurfaceBuffer::DrawingBuffer)
        prepareTexture();
    RetainPtr copy = copySurfaceBuffer(buffer);
    if (!copy)
        return nullptr;
    // The flip is this context's own work, so the image reading the copy needs it scheduled.
    waitUntilWorkScheduled();
    auto copyPixelBuffer = createCVPixelBuffer(copy.get());
    if (!copyPixelBuffer)
        return nullptr;
    RefPtr image = NativeImage::create(WTF::move(*copyPixelBuffer), alphaInfoForSurfaceBufferContents(contextAttributes()), m_drawingBufferColorSpace.platformColorSpace());
    if (!image)
        return nullptr;
    CGImageSetCachingFlags(image->platformImage().get(), kCGImageCachingTransient);
    return image;
}

#if ENABLE(VIDEO)
static_assert(std::to_underlying(GraphicsContextGLVideoUploadOutcome::Direct) == 0 && std::to_underlying(GraphicsContextGLVideoUploadOutcome::PbufferFailed) == 10, "GLVideoUploadOutcome");
static_assert(std::to_underlying(ImageOrientation::Orientation::OriginTopRight) == 2 && std::to_underlying(ImageOrientation::Orientation::OriginLeftBottom) == 8, "GLVideoUpload orientations");

bool GraphicsContextGLCocoa::copyTextureFromVideoFrame(VideoFrame& videoFrame, PlatformGLObject texture, GCGLenum target, GCGLint level, GCGLenum internalFormat, GCGLenum type, bool unpackFlipY, bool unpackPremultiplyAlpha)
{
    RefPtr videoFrameCV = videoFrame.asVideoFrameCV();
    if (!videoFrameCV) {
        ASSERT_NOT_REACHED(); // Programming error.
        recordVideoUploadForTesting(VideoUploadOutcome::Unsupported, 0);
        return false;
    }
    auto island = islandCalls();
    if (!island.hasContext()) {
        recordVideoUploadForTesting(VideoUploadOutcome::ContextLost, videoFrameCV->pixelFormat());
        return false;
    }
    auto outcome = static_cast<VideoUploadOutcome>(island.copyVideoFrameToTexture(videoFrameCV->pixelBuffer(), std::to_underlying(videoFrameCV->orientation().orientation()), texture, target, level, internalFormat, type, unpackFlipY, unpackPremultiplyAlpha));
    recordVideoUploadForTesting(outcome, videoFrameCV->pixelFormat());
    return isSuccessfulVideoUpload(outcome);
}
#endif

}

#endif // ENABLE(WEBGL)
