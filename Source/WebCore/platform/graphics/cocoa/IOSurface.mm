/*
 * Copyright (C) 2014-2018 Apple Inc. All rights reserved.
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
#import "IOSurface.h"

#import "ColorSpace.h"
#import "ColorSpaceCG.h"
#import "IOSurfacePool.h"
#import "ImageBufferBackend.h"
#import "Logging.h"
#import "NativeImage.h"
#import "PlatformScreen.h"
#import "ProcessCapabilities.h"
#import "ProcessIdentity.h"
#import "SharedMemory.h"
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/Assertions.h>
#import <wtf/MachSendRight.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/text/TextStream.h>

#import <pal/cg/CoreGraphicsSoftLink.h>
#import <pal/cocoa/QuartzCoreSoftLink.h>

#if USE(APPLE_INTERNAL_SDK) && __has_include(<WebKitAdditions/IOSurfaceAdditionsBefore.mm>)
#import <WebKitAdditions/IOSurfaceAdditionsBefore.mm>
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(IOSurface);

IOSurface::IOSurface(uintptr_t swiftState)
    : m_swiftState(swiftState)
{
    ASSERT(swiftState);
    auto description = describeSwiftState(swiftState);
    m_surface = swiftStateSurface(swiftState);
    m_size = { description.width, description.height };
    m_totalBytes = description.totalBytes;
    if (description.hasFormat)
        m_format = UsedFormat { description.format, description.useLosslessCompression };
}

IOSurface::IOSurface(IOSurface&& other)
    : m_surface(WTF::move(other.m_surface))
    , m_size(other.m_size)
    , m_totalBytes(other.m_totalBytes)
    , m_format(other.m_format)
    , m_swiftState(std::exchange(other.m_swiftState, 0))
{
}

IOSurface::~IOSurface()
{
    if (m_swiftState)
        destroySwiftState(m_swiftState);
}

std::unique_ptr<IOSurface> IOSurface::adoptSwiftState(uintptr_t swiftState)
{
    if (!swiftState)
        return nullptr;
    return std::unique_ptr<IOSurface>(new IOSurface(swiftState));
}

uintptr_t IOSurface::releaseSwiftState()
{
    return std::exchange(m_swiftState, 0);
}

std::unique_ptr<IOSurface> IOSurface::create(IOSurfacePool* pool, IntSize size, const ColorSpace& colorSpace, IOSurface::Name name, Format pixelFormat, UseLosslessCompression useLosslessCompression, IOSurfaceOptions options)
{
    ASSERT(ProcessCapabilities::canUseAcceleratedBuffers());

    bool hasAlphaPremultiplication = false;
    AlphaPremultiplication alphaPremultiplication = AlphaPremultiplication::Premultiplied;
#if HAVE(IOSURFACE_ALPHA_CHANNEL_MODE)
    if (options.alphaPremultiplication) {
        hasAlphaPremultiplication = true;
        alphaPremultiplication = *options.alphaPremultiplication;
    }
#else
    UNUSED_PARAM(options);
#endif
    return adoptSwiftState(createSwiftState(pool ? pool->m_swiftState : 0, size, protect(colorSpace.platformColorSpace()).get(), name, pixelFormat, useLosslessCompression, hasAlphaPremultiplication, alphaPremultiplication));
}

std::unique_ptr<IOSurface> IOSurface::createFromSendRight(const MachSendRight&& sendRight)
{
    ASSERT(ProcessCapabilities::canUseAcceleratedBuffers());

    return adoptSwiftState(createSwiftStateFromSendRight(sendRight.sendRight(), false));
}

std::unique_ptr<IOSurface> IOSurface::createFromUntrustedUncompressedWebKitSendRight(const MachSendRight&& sendRight)
{
    ASSERT(ProcessCapabilities::canUseAcceleratedBuffers());

    return adoptSwiftState(createSwiftStateFromSendRight(sendRight.sendRight(), true));
}

std::unique_ptr<IOSurface> IOSurface::createFromSurface(IOSurfaceRef surface, std::optional<ColorSpace>&& colorSpace)
{
    if (!surface)
        return nullptr;

    RetainPtr<CGColorSpaceRef> platformColorSpace;
    if (colorSpace)
        platformColorSpace = colorSpace->platformColorSpace();
    return adoptSwiftState(createSwiftStateFromSurface(surface, platformColorSpace.get()));
}

std::unique_ptr<IOSurface> IOSurface::createFromImage(IOSurfacePool* pool, CGImageRef image)
{
    if (!image)
        return nullptr;

    return adoptSwiftState(createSwiftStateFromImage(pool ? pool->m_swiftState : 0, image));
}

void IOSurface::moveToPool(std::unique_ptr<IOSurface>&& surface, IOSurfacePool* pool)
{
    if (pool)
        pool->addSurface(WTF::move(surface));
}

void IOSurface::setMaximumSize(IntSize size)
{
    ASSERT(!size.isEmpty());
    swiftSetMaximumSize(size);
}

IntSize IOSurface::maximumSize()
{
    return swiftMaximumSize();
}

size_t IOSurface::bytesPerRowAlignment()
{
    return swiftBytesPerRowAlignment();
}

void IOSurface::setBytesPerRowAlignment(size_t bytesPerRowAlignment)
{
    swiftSetBytesPerRowAlignment(bytesPerRowAlignment);
}

MachSendRight IOSurface::createSendRight() const
{
    return MachSendRight::adopt(IOSurfaceCreateMachPort(m_surface.get()));
}

RetainPtr<id> IOSurface::asCAIOSurfaceLayerContents() const
{
    // CAIOSurface keeps most of the server-side rendering ojects alive,
    // but doesn't mark the IOSurface as in-use. We can retain it for efficiency
    // without breaking use-counting.
    if (PAL::canLoad_QuartzCore_CAIOSurfaceCreate()) {
        auto result = adoptCF(CAIOSurfaceCreate(m_surface.get()));
#if HAVE(SUPPORT_HDR_DISPLAY)
        // Force CA to reload the headroom, since this doesn't happen automatically.
        auto headroom = contentEDRHeadroom();
        if (headroom && *headroom != 1 && PAL::canLoad_QuartzCore_CAIOSurfaceReloadColorAttributes())
            CAIOSurfaceReloadColorAttributes(result.get());
#endif
        return bridge_id_cast(WTF::move(result));
    }
    return asLayerContents();
}

RetainPtr<CGImageRef> IOSurface::createImage(CGContextRef context)
{
    ASSERT(ioSurfaceContextGetSurface(context) == m_surface);
    return adoptCF(ioSurfaceContextCreateImage(context));
}

RefPtr<NativeImage> IOSurface::createNativeImage(ShouldForceOpaque shouldForceOpaque)
{
    RetainPtr cgContext = adoptCF(swiftCreatePlatformContextForNativeImage(m_swiftState, shouldForceOpaque));
    if (!cgContext)
        return nullptr;

    return NativeImage::create(createImage(cgContext.get()));
}

void IOSurface::withNativeImage(ShouldForceOpaque shouldForceOpaque, NOESCAPE const Function<void(NativeImage*)>& function)
{
    RetainPtr cgContext = adoptCF(swiftCreatePlatformContextForNativeImage(m_swiftState, shouldForceOpaque));
    if (!cgContext)
        return function(nullptr);

    RefPtr image = NativeImage::create(createImage(cgContext.get()));
    function(image.get());
    image = nullptr;
}

RetainPtr<CGImageRef> IOSurface::sinkIntoImage(std::unique_ptr<IOSurface> surface, RetainPtr<CGContextRef> context)
{
    if (!context)
        context = surface->createPlatformContext();
    ASSERT(ioSurfaceContextGetSurface(context.get()) == surface->m_surface);
    return adoptCF(ioSurfaceContextCreateImageReference(context.get(), false));
}

RetainPtr<CGContextRef> IOSurface::createPlatformContext(PlatformDisplayID displayID, std::optional<CGImageAlphaInfo> overrideAlphaInfo, bool useWebKitBehavior)
{
    return adoptCF(swiftCreatePlatformContext(m_swiftState, displayID, !!overrideAlphaInfo, overrideAlphaInfo.value_or(kCGImageAlphaNone), useWebKitBehavior));
}

void IOSurface::releaseCGIOSurfaceContextResources()
{
    CABackingStoreCollectBlocking();
}

std::optional<IOSurface::LockAndContext> IOSurface::createBitmapPlatformContext()
{
    auto locker = lock<AccessMode::ReadWrite>();
    if (!locker)
        return std::nullopt;
    RetainPtr context = adoptCF(swiftCreateBitmapContextWhileLocked(m_swiftState));
    if (!context)
        return std::nullopt;
    return LockAndContext { WTF::move(*locker), WTF::move(context) };
}

SetNonVolatileResult IOSurface::state() const
{
    return swiftState(m_swiftState);
}

IOSurfaceSeed IOSurface::seed() const
{
    return IOSurfaceGetSeed(m_surface.get());
}

bool IOSurface::isVolatile() const
{
    return swiftIsVolatile(m_swiftState);
}

SetNonVolatileResult IOSurface::setVolatile(bool isVolatile)
{
    return swiftSetVolatile(m_swiftState, isVolatile);
}

ColorSpace IOSurface::colorSpace()
{
    return ColorSpace { adoptCF(swiftColorSpace(m_swiftState)) };
}

IOSurfaceID IOSurface::surfaceID() const
{
    return IOSurfaceGetID(m_surface.get());
}

size_t IOSurface::bytesPerRow() const
{
    return IOSurfaceGetBytesPerRow(m_surface.get());
}

bool IOSurface::isInUse() const
{
    return IOSurfaceIsInUse(m_surface.get());
}

IOSurface::Name IOSurface::name() const
{
    return swiftName(m_swiftState);
}

#if HAVE(IOSURFACE_ACCELERATOR)

// FIXME: Move to IOSurface.swift; only the UI process converts formats.
bool IOSurface::allowConversionFromFormatToFormat(Format sourceFormat, Format destFormat)
{
#if ENABLE(PIXEL_FORMAT_RGB10)
    if (sourceFormat == Format::RGB10 && destFormat == Format::YUV422)
        return false;
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    if (sourceFormat == Format::RGB10A8 && destFormat == Format::YUV422)
        return false;
#endif

    return true;
}

void IOSurface::convertToFormat(IOSurfacePool* pool, std::unique_ptr<IOSurface>&& inSurface, Name name, Format format, WTF::Function<void(std::unique_ptr<IOSurface>)>&& callback)
{
    static IOSurfaceAcceleratorRef accelerator;
    if (!accelerator) {
        IOSurfaceAcceleratorRef newAccelerator = nullptr;
        IOSurfaceAcceleratorCreate(nullptr, nullptr, &newAccelerator);

        if (!newAccelerator) {
            callback(nullptr);
            return;
        }

        // Without a run loop source, the accelerator can never deliver a completion, so
        // don't cache it; every subsequent transform would silently never complete.
        auto runLoopSource = IOSurfaceAcceleratorGetRunLoopSource(newAccelerator);
        if (!runLoopSource) {
            RELEASE_LOG_ERROR(IOSurface, "IOSurface::convertToFormat: failed to get a run loop source for the accelerator");
            CFRelease(newAccelerator);
            callback(nullptr);
            return;
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopDefaultMode);
        accelerator = newAccelerator;
    }

    if (inSurface->pixelFormat() == format) {
        callback(WTF::move(inSurface));
        return;
    }

    auto destinationSurface = IOSurface::create(pool, inSurface->size(), inSurface->colorSpace(), name, format);
    if (!destinationSurface) {
        callback(nullptr);
        return;
    }

    IOSurfaceRef destinationIOSurfaceRef = destinationSurface->surface();
    IOSurfaceAcceleratorCompletion completion;
    completion.completionRefCon = new WTF::Function<void(std::unique_ptr<IOSurface>)> (WTF::move(callback));
    completion.completionRefCon2 = destinationSurface.release();
    completion.completionCallback = [](void *completionRefCon, IOReturn result, void * completionRefCon2) {
        auto* callback = static_cast<WTF::Function<void(std::unique_ptr<IOSurface>)>*>(completionRefCon);
        auto destinationSurface = std::unique_ptr<IOSurface>(static_cast<IOSurface*>(completionRefCon2));

        (*callback)(result == kIOReturnSuccess ? WTF::move(destinationSurface) : nullptr);
        delete callback;
    };

    NSDictionary *options = @{ (id)kIOSurfaceAcceleratorUnwireSurfaceKey : @YES };

    IOReturn ret = IOSurfaceAcceleratorTransformSurface(accelerator, inSurface->surface(), destinationIOSurfaceRef, (CFDictionaryRef)options, nullptr, &completion, nullptr, nullptr);
    if (ret != kIOReturnSuccess) {
        RELEASE_LOG_ERROR(IOSurface, "IOSurface::convertToFormat: IOSurfaceAcceleratorTransformSurface failed for size (%d, %d), error %d", inSurface->size().width(), inSurface->size().height(), ret);
        completion.completionCallback(completion.completionRefCon, ret, completion.completionRefCon2);
        return;
    }
}

#endif // HAVE(IOSURFACE_ACCELERATOR)

#if HAVE(IOSURFACE_ALPHA_CHANNEL_MODE)
void IOSurface::setContentsAlphaPremultiplication(std::optional<AlphaPremultiplication> alphaPremultiplication)
{
    swiftSetContentsAlphaPremultiplication(m_swiftState, !!alphaPremultiplication, alphaPremultiplication.value_or(AlphaPremultiplication::Premultiplied));
}
#endif

static mach_port_t taskIdToken(const ProcessIdentity& resourceOwner)
{
#if HAVE(TASK_IDENTITY_TOKEN)
    if (resourceOwner)
        return resourceOwner.taskIdToken();
#else
    UNUSED_PARAM(resourceOwner);
#endif
    return MACH_PORT_NULL;
}

void IOSurface::setOwnershipIdentity(const ProcessIdentity& resourceOwner)
{
    ASSERT(resourceOwner);
    swiftSetOwnershipIdentity(m_swiftState, taskIdToken(resourceOwner));
}

void IOSurface::setOwnershipIdentity(IOSurfaceRef surface, const ProcessIdentity& resourceOwner)
{
#if ASSERT_ENABLED && HAVE(IOSURFACE_SET_OWNERSHIP_IDENTITY) && HAVE(TASK_IDENTITY_TOKEN)
    ASSERT(surface);
    if (!isMemoryAttributionDisabled())
        ASSERT(resourceOwner);
#endif
    swiftSetSurfaceOwnershipIdentity(surface, taskIdToken(resourceOwner));
}

#if HAVE(SUPPORT_HDR_DISPLAY)
void IOSurface::setContentEDRHeadroom(float headroom)
{
    swiftSetContentEDRHeadroom(m_swiftState, headroom);
}

std::optional<float> IOSurface::contentEDRHeadroom() const
{
    if (!swiftHasContentEDRHeadroom(m_swiftState))
        return std::nullopt;
    return swiftContentEDRHeadroom(m_swiftState);
}

void IOSurface::loadContentEDRHeadroom()
{
    swiftLoadContentEDRHeadroom(m_swiftState);
}
#endif

IOSurface::Name IOSurface::nameForRenderingPurpose(RenderingPurpose purpose)
{
    return swiftNameForRenderingPurpose(purpose);
}

TextStream& operator<<(TextStream& ts, IOSurface::Format format)
{
    switch (format) {
    case IOSurface::Format::BGRX:
        ts << "BGRX"_s;
        break;
    case IOSurface::Format::BGRA:
        ts << "BGRA"_s;
        break;
    case IOSurface::Format::YUV422:
        ts << "YUV422"_s;
        break;
    case IOSurface::Format::RGBX:
        ts << "RGBX"_s;
        break;
    case IOSurface::Format::RGBA:
        ts << "RGBA"_s;
        break;
#if ENABLE(PIXEL_FORMAT_RGB10)
    case IOSurface::Format::RGB10:
        ts << "RGB10"_s;
        break;
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    case IOSurface::Format::RGB10A8:
        ts << "RGB10A8"_s;
        break;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case IOSurface::Format::RGBA16F:
        ts << "RGBA16F"_s;
        break;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16)
    case IOSurface::Format::RGBA16:
        ts << "RGBA16"_s;
        break;
#endif
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, const IOSurface& surface)
{
    return ts << "IOSurface "_s << surface.surfaceID() << " name "_s << String { adoptCF(IOSurface::swiftNameString(surface.m_swiftState)).get() } << " size "_s << surface.size() << " format "_s << (surface.m_format ? surface.m_format->format : IOSurface::Format::BGRX)
        << " compressed " << (surface.m_format ? (surface.m_format->useLosslessCompression == UseLosslessCompression::Yes) : false) << " state "_s << surface.state();
}

// IOSurface.swift reaches the CGIOSurfaceContext functions through these.

CGContextRef ioSurfaceContextCreate(IOSurfaceRef surface, size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel, CGColorSpaceRef colorSpace, CGBitmapInfo bitmapInfo, bool useWebKitBehavior, PlatformDisplayID displayID, mach_port_t ownerTaskIdToken)
{
    RetainPtr<CFDictionaryRef> options;
    if (useWebKitBehavior) {
        const void* keys[] = { CFSTR("useWebKitBehavior") };
        const void* values[] = { kCFBooleanTrue };
        options = adoptCF(CFDictionaryCreate(kCFAllocatorDefault, keys, values, std::size(keys), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    }

    RetainPtr cgContext = adoptCF(CGIOSurfaceContextCreateWithOptions(surface, width, height, bitsPerComponent, bitsPerPixel, colorSpace, bitmapInfo, options.get()));

#if PLATFORM(MAC)
    if (auto displayMask = primaryOpenGLDisplayMask()) {
        if (displayID)
            displayMask = displayMaskForDisplay(displayID);
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
        CGIOSurfaceContextSetDisplayMask(cgContext.get(), displayMask); // NOLINT
ALLOW_DEPRECATED_DECLARATIONS_END
    }
#else
    UNUSED_PARAM(displayID);
#endif
#if HAVE(CG_CONTEXT_SET_OWNER_IDENTITY)
    if (ownerTaskIdToken != MACH_PORT_NULL && CGContextSetOwnerIdentity)
        CGContextSetOwnerIdentity(cgContext.get(), ownerTaskIdToken);
#else
    UNUSED_PARAM(ownerTaskIdToken);
#endif
    return cgContext.leakRef();
}

CGImageRef ioSurfaceContextCreateImage(CGContextRef context)
{
    return CGIOSurfaceContextCreateImage(context);
}

CGImageRef ioSurfaceContextCreateImageReference(CGContextRef context, bool isTransient)
{
    CGImageRef image = CGIOSurfaceContextCreateImageReference(context);
    if (isTransient)
        CGImageSetCachingFlags(image, kCGImageCachingTransient);
    return image;
}

IOSurfaceRef ioSurfaceContextGetSurface(CGContextRef context)
{
    return CGIOSurfaceContextGetSurface(context);
}

bool ioSurfaceContextInvalidateSurface(CGContextRef context)
{
    if (!PAL::canLoad_CoreGraphics_CGIOSurfaceContextInvalidateSurface())
        return false;
    PAL::softLink_CoreGraphics_CGIOSurfaceContextInvalidateSurface(context);
    return true;
}

bool ioSurfaceContextFlushQueue(CGContextRef context)
{
    if (!PAL::canLoad_CoreGraphics_CGIOSurfaceContextFlushQueue())
        return false;
    PAL::softLink_CoreGraphics_CGIOSurfaceContextFlushQueue(context);
    return true;
}

} // namespace WebCore

#if USE(APPLE_INTERNAL_SDK) && __has_include(<WebKitAdditions/IOSurfaceAdditionsAfter.mm>)
#import <WebKitAdditions/IOSurfaceAdditionsAfter.mm>
#endif
