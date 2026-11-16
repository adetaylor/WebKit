/*
 * Copyright (C) 2014-2023 Apple Inc. All rights reserved.
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

#pragma once

#if HAVE(IOSURFACE)

#include <CoreGraphics/CoreGraphics.h>
#include <WebCore/AlphaPremultiplication.h>
#include <WebCore/ColorSpace.h>
#include <WebCore/IntSize.h>
#include <WebCore/PixelFormat.h>
#include <WebCore/ProcessIdentity.h>
#include <wtf/Forward.h>
#include <wtf/RetainPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/spi/cocoa/IOSurfaceSPI.h>

namespace WTF {
class MachSendRight;
class TextStream;
}

namespace WebCore {

class IOSurfacePool;
class NativeImage;

enum class RenderingPurpose : uint8_t;
enum class SetNonVolatileResult : uint8_t;

using IOSurfaceSeed = uint32_t;
using PlatformDisplayID = uint32_t;

struct IOSurfaceSwiftDescription;

// A facade over IOSurfaceCore (IOSurface.swift), which holds the surface's state and implements it, for callers in C++.
// The facade keeps the values that never change after creation, so that its inline accessors stay inline.
class SWIFT_PRIVATE_FILEID("WebCore/IOSurface.swift") IOSurface final {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(IOSurface, WEBCORE_EXPORT);
public:
    enum class Name : uint8_t {
        Default,
        DOM,
        Canvas,
        GraphicsContextGL,
        ImageBuffer,
        ImageBufferShareableMapped,
        LayerBacking,
        MediaPainting,
        Snapshot,
        ShareableSnapshot,
        ShareableLocalSnapshot,
        WebGPU,
    };

    enum class Format {
        BGRX,
        BGRA,
        YUV422,
        RGBA,
        RGBX,
#if ENABLE(PIXEL_FORMAT_RGB10)
        RGB10,
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
        RGB10A8,
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
        RGBA16F,
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16)
        RGBA16, // NOLINT
#endif
    };

    struct UsedFormat {
        Format format;
        UseLosslessCompression useLosslessCompression;
        bool operator==(const UsedFormat&) const = default;
    };

    // Optional properties of a newly created surface.
    struct IOSurfaceOptions {
#if HAVE(IOSURFACE_ALPHA_CHANNEL_MODE)
        std::optional<AlphaPremultiplication> alphaPremultiplication;
#endif
    };

    enum class AccessMode : uint32_t {
        ReadWrite = 0,
        ReadOnly = kIOSurfaceLockReadOnly
    };
    template <AccessMode Mode>
    class Locker {
    public:
        static Locker adopt(RetainPtr<IOSurfaceRef> surface)
        {
            return Locker { WTF::move(surface) };
        }

        Locker(Locker&& other)
            : m_surface(std::exchange(other.m_surface, nullptr))
        {
        }

        ~Locker()
        {
            if (!m_surface)
                return;
            IOSurfaceUnlock(m_surface.get(), static_cast<uint32_t>(Mode), nullptr);
        }

        Locker& operator=(Locker&& other)
        {
            m_surface = std::exchange(other.m_surface, nullptr);
            return *this;
        }

        void* surfaceBaseAddress() const
        {
            return IOSurfaceGetBaseAddress(m_surface.get());
        }

        std::span<uint8_t> surfaceSpan()
        {
            return unsafeMakeSpan(static_cast<uint8_t*>(IOSurfaceGetBaseAddress(m_surface.get())), IOSurfaceGetAllocSize(m_surface.get()));
        }

        std::span<const uint8_t> surfaceSpan() const
        {
            return unsafeMakeSpan(static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(m_surface.get())), IOSurfaceGetAllocSize(m_surface.get()));
        }

    private:
        explicit Locker(RetainPtr<IOSurfaceRef> surface)
            : m_surface(WTF::move(surface))
        {
        }

        RetainPtr<IOSurfaceRef> m_surface;
    };

    WEBCORE_EXPORT static std::unique_ptr<IOSurface> create(IOSurfacePool*, IntSize, const ColorSpace&, Name = Name::Default, Format = Format::BGRA, UseLosslessCompression = UseLosslessCompression::No, IOSurfaceOptions = { });
    WEBCORE_EXPORT static std::unique_ptr<IOSurface> createFromImage(IOSurfacePool*, CGImageRef);

    WEBCORE_EXPORT static std::unique_ptr<IOSurface> createFromSendRight(const WTF::MachSendRight&&);
    WEBCORE_EXPORT static std::unique_ptr<IOSurface> createFromUntrustedUncompressedWebKitSendRight(const WTF::MachSendRight&&);
    // If the colorSpace argument is non-null, it replaces any colorspace metadata on the surface.
    WEBCORE_EXPORT static std::unique_ptr<IOSurface> createFromSurface(IOSurfaceRef, std::optional<ColorSpace>&&);

    WEBCORE_EXPORT static void moveToPool(std::unique_ptr<IOSurface>&&, IOSurfacePool*);

    WEBCORE_EXPORT ~IOSurface();

    WEBCORE_EXPORT static IntSize maximumSize();
    NODELETE WEBCORE_EXPORT static void setMaximumSize(IntSize);

    WEBCORE_EXPORT static size_t bytesPerRowAlignment();
    NODELETE WEBCORE_EXPORT static void setBytesPerRowAlignment(size_t);

    WEBCORE_EXPORT WTF::MachSendRight createSendRight() const;

    // Controls how the alpha channel is interpreted when creating a native image.
    // Only meaningful for RGBA16F and RGBA16 surfaces, whose formats (unlike RGBA/RGBX
    // or BGRA/BGRX) cannot themselves encode whether the contents are opaque.
    enum class ShouldForceOpaque : bool { No, Yes };

    // Any images created from a surface need to be released before releasing
    // the context, or an expensive GPU readback can result.
    // Passed in context is the context through which the contents was drawn.
    WEBCORE_EXPORT RetainPtr<CGImageRef> createImage(CGContextRef);
    WEBCORE_EXPORT RefPtr<NativeImage> createNativeImage(ShouldForceOpaque = ShouldForceOpaque::Yes);
    WEBCORE_EXPORT void withNativeImage(ShouldForceOpaque, NOESCAPE const Function<void(NativeImage*)>&);
    // Passed in context is the context through which the contents was drawn.
    WEBCORE_EXPORT static RetainPtr<CGImageRef> sinkIntoImage(std::unique_ptr<IOSurface>, RetainPtr<CGContextRef> = nullptr);

    WEBCORE_EXPORT static Name nameForRenderingPurpose(RenderingPurpose);
    WEBCORE_EXPORT Name name() const;

#ifdef __OBJC__
    id asLayerContents() const { return (__bridge id)m_surface.get(); }
#endif
    WEBCORE_EXPORT RetainPtr<id> asCAIOSurfaceLayerContents() const;

    IOSurfaceRef surface() const { return m_surface.get(); }

    WEBCORE_EXPORT RetainPtr<CGContextRef> createPlatformContext(PlatformDisplayID = 0, std::optional<CGImageAlphaInfo> = std::nullopt, bool useWebKitBehavior = false);
    WEBCORE_EXPORT static void releaseCGIOSurfaceContextResources();

    struct LockAndContext {
        IOSurface::Locker<AccessMode::ReadWrite> lock;
        RetainPtr<CGContextRef> context;
    };
    WEBCORE_EXPORT std::optional<LockAndContext> createBitmapPlatformContext();
    template<AccessMode Mode> std::optional<Locker<Mode>> lock();

    // Querying volatility can be expensive, so in cases where the surface is
    // going to be used immediately, use the return value of setVolatile to
    // determine whether the data was purged, instead of first calling state() or isVolatile().
    SetNonVolatileResult state() const;
    WEBCORE_EXPORT bool isVolatile() const;

    WEBCORE_EXPORT SetNonVolatileResult setVolatile(bool);

    bool hasFormat(UsedFormat format) const { return m_format && *m_format == format; }
    std::optional<Format> pixelFormat() const
    {
        if (m_format)
            return m_format->format;
        return std::nullopt;
    }

    std::optional<UseLosslessCompression> usesLosslessCompression() const
    {
        if (m_format)
            return m_format->useLosslessCompression;
        return std::nullopt;
    }

    IntSize size() const { return m_size; }
    size_t totalBytes() const { return m_totalBytes; }

#if HAVE(SUPPORT_HDR_DISPLAY)
    WEBCORE_EXPORT void setContentEDRHeadroom(float);
    WEBCORE_EXPORT std::optional<float> contentEDRHeadroom() const;
    WEBCORE_EXPORT void loadContentEDRHeadroom();
#endif

    WEBCORE_EXPORT ColorSpace colorSpace();
    WEBCORE_EXPORT IOSurfaceID surfaceID() const;
    WEBCORE_EXPORT size_t bytesPerRow() const;

    WEBCORE_EXPORT IOSurfaceSeed seed() const;

    WEBCORE_EXPORT bool isInUse() const;

#if HAVE(IOSURFACE_ACCELERATOR)
    WEBCORE_EXPORT static bool allowConversionFromFormatToFormat(Format, Format);
    WEBCORE_EXPORT static void convertToFormat(IOSurfacePool*, std::unique_ptr<WebCore::IOSurface>&& inSurface, Name, Format, Function<void(std::unique_ptr<WebCore::IOSurface>)>&&);
#endif // HAVE(IOSURFACE_ACCELERATOR)

#if HAVE(IOSURFACE_ALPHA_CHANNEL_MODE)
    WEBCORE_EXPORT void setContentsAlphaPremultiplication(std::optional<AlphaPremultiplication>);
#endif

    WEBCORE_EXPORT void setOwnershipIdentity(const ProcessIdentity&);
    WEBCORE_EXPORT static void setOwnershipIdentity(IOSurfaceRef, const ProcessIdentity&);

    // For Swift's import of the class, which needs a copy or move constructor.
    IOSurface(IOSurface&&);
    IOSurface(const IOSurface&) = delete;
    IOSurface& operator=(const IOSurface&) = delete;

private:
    friend class GraphicsContextGLCocoa;
    friend class ImageBufferSurface;
    friend class IOSurfacePool;

    explicit IOSurface(uintptr_t swiftState);
    static std::unique_ptr<IOSurface> adoptSwiftState(uintptr_t swiftState);
    // Hands the caller the facade's reference to its IOSurfaceCore.
    uintptr_t releaseSwiftState();

    // The rest is implemented in IOSurface.swift. A swiftState is a +1 reference to an IOSurfaceCore, and a poolState to an
    // IOSurfacePoolCore, or 0. The functions that return a Core Foundation object other than swiftStateSurface() return a
    // +1 reference, which the caller adopts.
    static uintptr_t createSwiftState(uintptr_t poolState, IntSize, CGColorSpaceRef, Name, Format, UseLosslessCompression, bool hasAlphaPremultiplication, AlphaPremultiplication);
    static uintptr_t createSwiftStateFromImage(uintptr_t poolState, CGImageRef);
    static uintptr_t createSwiftStateFromSendRight(mach_port_t, bool untrustedUncompressed);
    static uintptr_t createSwiftStateFromSurface(IOSurfaceRef, CGColorSpaceRef);
    static void destroySwiftState(uintptr_t swiftState);
    static IOSurfaceSwiftDescription describeSwiftState(uintptr_t swiftState);
    static IOSurfaceRef swiftStateSurface(uintptr_t swiftState);
    static IntSize swiftMaximumSize();
    static void swiftSetMaximumSize(IntSize);
    static size_t swiftBytesPerRowAlignment();
    static void swiftSetBytesPerRowAlignment(size_t);
    static Name swiftNameForRenderingPurpose(RenderingPurpose);
    static Name swiftName(uintptr_t swiftState);
    static CFStringRef swiftNameString(uintptr_t swiftState);
    static CGContextRef swiftCreatePlatformContext(uintptr_t swiftState, PlatformDisplayID, bool hasAlphaInfo, CGImageAlphaInfo, bool useWebKitBehavior);
    static CGContextRef swiftCreatePlatformContextForNativeImage(uintptr_t swiftState, ShouldForceOpaque);
    static CGContextRef swiftCreateBitmapContextWhileLocked(uintptr_t swiftState);
    static SetNonVolatileResult swiftState(uintptr_t swiftState);
    static bool swiftIsVolatile(uintptr_t swiftState);
    static SetNonVolatileResult swiftSetVolatile(uintptr_t swiftState, bool);
    static CGColorSpaceRef swiftColorSpace(uintptr_t swiftState);
#if HAVE(SUPPORT_HDR_DISPLAY)
    static void swiftSetContentEDRHeadroom(uintptr_t swiftState, float);
    static bool swiftHasContentEDRHeadroom(uintptr_t swiftState);
    static float swiftContentEDRHeadroom(uintptr_t swiftState);
    static void swiftLoadContentEDRHeadroom(uintptr_t swiftState);
#endif
#if HAVE(IOSURFACE_ALPHA_CHANNEL_MODE)
    static void swiftSetContentsAlphaPremultiplication(uintptr_t swiftState, bool hasAlphaPremultiplication, AlphaPremultiplication);
#endif
    static void swiftSetOwnershipIdentity(uintptr_t swiftState, mach_port_t taskIdToken);
    static void swiftSetSurfaceOwnershipIdentity(IOSurfaceRef, mach_port_t taskIdToken);

    static uintptr_t createPoolSwiftState();
    static void destroyPoolSwiftState(uintptr_t poolState);
    static uintptr_t takePoolSurface(uintptr_t poolState, IntSize, CGColorSpaceRef, Format, UseLosslessCompression);
    static void addPoolSurface(uintptr_t poolState, uintptr_t swiftState);
    static void discardAllPoolSurfaces(uintptr_t poolState);
    static void setPoolSize(uintptr_t poolState, size_t);

    RetainPtr<IOSurfaceRef> m_surface;
    IntSize m_size;
    size_t m_totalBytes { 0 };
    std::optional<UsedFormat> m_format;
    uintptr_t m_swiftState { 0 };

    WEBCORE_EXPORT friend WTF::TextStream& operator<<(WTF::TextStream&, const WebCore::IOSurface&);
};

// The values of an IOSurfaceCore that never change, which the facade keeps.
struct IOSurfaceSwiftDescription {
    int width;
    int height;
    size_t totalBytes;
    bool hasFormat;
    IOSurface::Format format;
    UseLosslessCompression useLosslessCompression;
};

template<IOSurface::AccessMode Mode>
std::optional<IOSurface::Locker<Mode>> IOSurface::lock()
{
    if (IOSurfaceLock(m_surface.get(), static_cast<uint32_t>(Mode), nullptr) != kIOReturnSuccess)
        return std::nullopt;
    return IOSurface::Locker<Mode>::adopt(m_surface);
}

constexpr IOSurface::Format convertToIOSurfaceFormat(PixelFormat format)
{
    switch (format) {
    case PixelFormat::RGBX8:
        return IOSurface::Format::RGBX;
    case PixelFormat::RGBA8:
        return IOSurface::Format::RGBA;
    case PixelFormat::BGRX8:
        return IOSurface::Format::BGRX;
    case PixelFormat::BGRA8:
        return IOSurface::Format::BGRA;
#if ENABLE(PIXEL_FORMAT_RGB10)
    case PixelFormat::RGB10:
        return IOSurface::Format::RGB10;
#endif
#if ENABLE(PIXEL_FORMAT_RGB10A8)
    case PixelFormat::RGB10A8:
        return IOSurface::Format::RGB10A8;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    case PixelFormat::RGBA16F:
        return IOSurface::Format::RGBA16F;
#endif
#if ENABLE(PIXEL_FORMAT_RGBA16)
    case PixelFormat::RGBA16:
        return IOSurface::Format::RGBA16;
#endif
    default:
        RELEASE_ASSERT_NOT_REACHED();
        return IOSurface::Format::BGRA;
    }
}

WEBCORE_EXPORT WTF::TextStream& operator<<(WTF::TextStream&, WebCore::IOSurface::Format);

// The CGIOSurfaceContext functions, for IOSurface.swift. The size must be the surface's, with the bits of a format
// Core Graphics can draw it in, and the contexts ones that ioSurfaceContextCreate() made for the surface.
SWIFT_UNSAFE CGContextRef ioSurfaceContextCreate(IOSurfaceRef, size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel, CGColorSpaceRef, CGBitmapInfo, bool useWebKitBehavior, PlatformDisplayID, mach_port_t ownerTaskIdToken) CF_RETURNS_RETAINED;
SWIFT_UNSAFE CGImageRef ioSurfaceContextCreateImage(CGContextRef) CF_RETURNS_RETAINED;
// A transient image is one that is drawn once, which Core Graphics needn't cache.
SWIFT_UNSAFE CGImageRef ioSurfaceContextCreateImageReference(CGContextRef, bool isTransient) CF_RETURNS_RETAINED;
SWIFT_UNSAFE IOSurfaceRef ioSurfaceContextGetSurface(CGContextRef);
// False if Core Graphics can't invalidate the context's cached images of its surface, or flush its queue.
SWIFT_UNSAFE bool ioSurfaceContextInvalidateSurface(CGContextRef);
SWIFT_UNSAFE bool ioSurfaceContextFlushQueue(CGContextRef);

} // namespace WebCore

#endif // HAVE(IOSURFACE)

