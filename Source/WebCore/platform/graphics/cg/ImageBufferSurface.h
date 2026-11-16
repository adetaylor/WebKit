/*
 * Copyright (C) 2020-2023 Apple Inc. All rights reserved.
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

/*
 * Copyright (C) 2020-2024 Apple Inc. All rights reserved.
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

#if USE(CG)

#include <CoreGraphics/CoreGraphics.h>
#include <WebCore/ImageBufferBackend.h>
#include <wtf/RetainPtr.h>
#include <wtf/SwiftBridging.h>

#if HAVE(IOSURFACE)
#include <WebCore/IOSurface.h>
#endif

namespace WTF {
class MachSendRight;
}

namespace WebCore {

#if HAVE(IOSURFACE)
class IOSurfacePool;
#endif
class ShareableBitmap;

struct ImageBufferSurfaceCountsForTesting {
    uint64_t contextFlushes;
    uint64_t cachedImageInvalidations;
    uint64_t drawingCommandSubmissions;
    uint64_t imagesCreated;
    uint64_t imageReferencesCreated;
    uint64_t imagesSunk;
    uint64_t displayCopies;
};

// What the accelerated backends have done in this process.
WEBCORE_EXPORT ImageBufferSurfaceCountsForTesting imageBufferSurfaceCountsForTesting();

// A facade over ImageBufferSurfaceCore (ImageBufferSurface.swift), the surface of an ImageBufferCGBackend and its state,
// which owns a reference to the core. An empty one has no core.
class SWIFT_PRIVATE_FILEID("WebCore/ImageBufferSurface.swift") ImageBufferSurface final {
public:
    ImageBufferSurface() = default;
#if HAVE(IOSURFACE)
    // A core over the surface, with a context that draws into it, cleared if shouldClear; empty if no context can be made.
    // The format is the one the backend asks for, which its display copies use.
    WEBCORE_EXPORT static ImageBufferSurface create(IOSurface&, IOSurfacePool*, IOSurface::Format, UseLosslessCompression, PlatformDisplayID, bool useWebKitBehavior, bool shouldClear);
    // A core over a surface that the backend draws into through a bitmap context while it's locked.
    WEBCORE_EXPORT static ImageBufferSurface createForMappedBitmap(IOSurface&, IOSurfacePool*);
#endif
    // A core over a bitmap's memory; empty for a bitmap with a gain map, whose images C++ makes.
    WEBCORE_EXPORT static ImageBufferSurface create(ShareableBitmap&);
    // A core over a bitmap context, whose memory the data provider owns.
    WEBCORE_EXPORT static ImageBufferSurface create(CGContextRef, CGDataProviderRef, CGColorSpaceRef, IntSize, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow, CGBitmapInfo);

    WEBCORE_EXPORT ImageBufferSurface(ImageBufferSurface&&);
    WEBCORE_EXPORT ImageBufferSurface& operator=(ImageBufferSurface&&);
    ImageBufferSurface(const ImageBufferSurface&) = delete;
    ImageBufferSurface& operator=(const ImageBufferSurface&) = delete;
    WEBCORE_EXPORT ~ImageBufferSurface();

    explicit operator bool() const { return !!m_swiftState; }

    WEBCORE_EXPORT RetainPtr<CGContextRef> platformContext();
    WEBCORE_EXPORT RetainPtr<CGImageRef> createImage();
    WEBCORE_EXPORT RetainPtr<CGImageRef> createImageReference();

#if HAVE(IOSURFACE)
    // contextHasDrawn is the consumed drawn state of the GraphicsContext that draws through the platform context.
    WEBCORE_EXPORT bool flushContextDraws(bool contextHasDrawn);
    WEBCORE_EXPORT void prepareForExternalWrite(bool contextHasDrawn);
    WEBCORE_EXPORT bool mayHaveOutstandingBackingStoreReferences() const;
    WEBCORE_EXPORT void submitDrawingCommands();
    WEBCORE_EXPORT RetainPtr<CGImageRef> sinkIntoImage();
    WEBCORE_EXPORT void releasePlatformContext();
    WEBCORE_EXPORT bool setVolatile();
    WEBCORE_EXPORT SetNonVolatileResult setNonVolatile();
    WEBCORE_EXPORT VolatilityState volatilityState() const;
    WEBCORE_EXPORT void setVolatilityState(VolatilityState);
    WEBCORE_EXPORT void setSurfacePool(IOSurfacePool*);
    WEBCORE_EXPORT void moveSurfaceToPool();
    // A copy of the surface in a surface from the pool, its send right, and the context that drew it.
    WEBCORE_EXPORT RetainPtr<CGContextRef> createDisplayCopy(WTF::MachSendRight&);
#endif

    static ImageBufferSurfaceCountsForTesting countsForTesting();

private:
    explicit ImageBufferSurface(uintptr_t swiftState)
        : m_swiftState(swiftState)
    {
    }

    // The rest is implemented in ImageBufferSurface.swift. A swiftState is a +1 reference to an ImageBufferSurfaceCore,
    // or 0, and an IOSurface state and a pool state are those of the facades. The functions that return a Core
    // Foundation object return a +1 reference, which the caller adopts.
#if HAVE(IOSURFACE)
    static uintptr_t createIOSurfaceSwiftState(uintptr_t surfaceState, uintptr_t poolState, IOSurface::Format, UseLosslessCompression, PlatformDisplayID, bool useWebKitBehavior, bool shouldClear);
    static uintptr_t createMappedIOSurfaceBitmapSwiftState(uintptr_t surfaceState, uintptr_t poolState);
#endif
    static uintptr_t createShareableBitmapSwiftState(uintptr_t bitmapState);
    static uintptr_t createBitmapSwiftState(CGContextRef, CGDataProviderRef, CGColorSpaceRef, int width, int height, size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow, uint32_t bitmapInfo);
    static void destroySwiftState(uintptr_t);
    static CGContextRef swiftPlatformContext(uintptr_t);
    static CGImageRef swiftCreateImage(uintptr_t);
    static CGImageRef swiftCreateImageReference(uintptr_t);
#if HAVE(IOSURFACE)
    static bool swiftFlushContextDraws(uintptr_t, bool contextHasDrawn);
    static void swiftPrepareForExternalWrite(uintptr_t, bool contextHasDrawn);
    static bool swiftMayHaveOutstandingBackingStoreReferences(uintptr_t);
    static void swiftSubmitDrawingCommands(uintptr_t);
    static CGImageRef swiftSinkIntoImage(uintptr_t);
    static void swiftReleasePlatformContext(uintptr_t);
    static bool swiftSetVolatile(uintptr_t);
    static SetNonVolatileResult swiftSetNonVolatile(uintptr_t);
    static VolatilityState swiftVolatilityState(uintptr_t);
    static void swiftSetVolatilityState(uintptr_t, VolatilityState);
    static void swiftSetSurfacePool(uintptr_t, uintptr_t poolState);
    static void swiftMoveSurfaceToPool(uintptr_t);
    static CGContextRef swiftCreateDisplayCopy(uintptr_t);
    static mach_port_t swiftTakeDisplayCopySendRight(uintptr_t);
#endif
    static uint64_t swiftCountForTesting(unsigned index);

    uintptr_t m_swiftState { 0 };
};

} // namespace WebCore

#endif // USE(CG)
