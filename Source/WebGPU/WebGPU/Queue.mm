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
#import "Queue.h"

#import "Buffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Texture.h"
#import <wtf/BlockPtr.h>
#import <wtf/Borrow.h>
#import <wtf/Box.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/darwin/DispatchExtras.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#endif

namespace WebGPU::Metal {

template<unsigned errorCode>
[[noreturn]] void crashGPUProcess(NSError* error, NSError* underlyingError)
{
    WTFLogAlways("Encountered fatal command buffer error %@, underlying error %@", error, underlyingError); // NOLINT
    RELEASE_ASSERT_NOT_REACHED();
}

[[noreturn]] static void crashGPUProcess(NSString *error)
{
    WTFLogAlways("Encountered fatal GPU error %@", error); // NOLINT
    RELEASE_ASSERT_NOT_REACHED();
}

// In C++ because crashGPUProcess<N>() gives every fatal error code a crash signature of its own.
void addCommitHandlers(id<MTLCommandBuffer> commandBuffer, void (^didSchedule)(void), void (^didComplete)(bool loseTheDevice))
{
    [commandBuffer addScheduledHandler:[didSchedule = makeBlockPtr(didSchedule)](id<MTLCommandBuffer>) {
        didSchedule();
    }];
    auto completed = Box<std::atomic<bool>>::create(false);
    [commandBuffer addCompletedHandler:[didComplete = makeBlockPtr(didComplete), completed](id<MTLCommandBuffer> mtlCommandBuffer) {
        completed->store(true, std::memory_order_relaxed);
        MTLCommandBufferStatus status = mtlCommandBuffer.status;
        bool loseTheDevice = false;
        if (NSError *error = mtlCommandBuffer.error; status != MTLCommandBufferStatusCompleted) {
            loseTheDevice = !error || error.code != MTLCommandBufferErrorNotPermitted;
            if (loseTheDevice) {
                NSError* underlyingError = error.userInfo[NSUnderlyingErrorKey];
                if (underlyingError.code == 0x10a || underlyingError.code == 0x5)
                    loseTheDevice = false;
                else {
#define makeCase(N) case N: crashGPUProcess<N>(error, underlyingError);
                    switch (underlyingError.code) {
                        makeCase(9); // kIOGPUCommandBufferCallbackErrorInvalidResource = 9,
                        makeCase(10); // kIOGPUCommandBufferCallbackErrorInvalidInput = 10,
                        makeCase(11); // kIOGPUCommandBufferCallbackErrorPageFault = 11,
                        makeCase(16); // kIOGPUCommandBufferCallbackErrorProtectionViolation = 16,
                        makeCase(17); // kIOGPUCommandBufferCallbackErrorStackOverflow = 17,
                        break;
                    default:
                        break;
                    }
#undef makeCase
                    WTFLogAlways("Encountered non-fatal command buffer error %@, underlying error %@", error, underlyingError); // NOLINT
                }
            }
        }

        didComplete(loseTheDevice);
    }];

    // QueueImpl commits the command buffer as soon as this returns.
    NSString *label = commandBuffer.label;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), globalDispatchQueueSingleton(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (!completed->load(std::memory_order_relaxed))
            crashGPUProcess([NSString stringWithFormat:@"WebGPU: command buffer %@ did not complete within 3s timeout", label]);
    });
}

id<MTLBuffer> newBufferAliasingOwner(id<MTLDevice> device, const WebGPU::ByteOwner& owner, uint64_t offset, uint64_t length)
{
    auto bytes = owner.span();
    if (offset > bytes.size() || length > bytes.size() - offset)
        return nil;
    bytes = bytes.subspan(static_cast<size_t>(offset), static_cast<size_t>(length));
    // Metal reads the bytes in place until it destroys the buffer, and only then releases the deallocator, which holds
    // their owner. The buffer is only ever a copy source, so nothing writes to them.
    auto keepOwnerAlive = makeBlockPtr([protectedOwner = Ref { owner }](void*, NSUInteger) { });
    return [device newBufferWithBytesNoCopy:spanConstCast<uint8_t>(bytes).data() length:bytes.size() options:MTLResourceStorageModeShared deallocator:keepOwnerAlive.get()];
}

#pragma mark External texture import (ExternalTextureImport.swift)

// ExternalTextureImport.swift spells HAVE(COREVIDEO_METAL_SUPPORT) out, because Swift cannot evaluate the CoreVideo
// macro it expands to.
#if HAVE(COREVIDEO_METAL_SUPPORT) != (HAVE(WEBGPU_IMPLEMENTATION) && (PLATFORM(MAC) || PLATFORM(IOS) || PLATFORM(VISION)))
#error "Update the HAVE(COREVIDEO_METAL_SUPPORT) conditions in ExternalTextureImport.swift"
#endif

void copyPixelBufferPlane(id<MTLTexture> texture, CVPixelBufferRef pixelBuffer, size_t plane, size_t bytesPerPixel)
{
    // Metal reads `height` rows of `width * bytesPerPixel` bytes, bytesPerRow apart: never more rows, or wider ones, than
    // the plane has. A plane whose rows are narrower than that is not copied, which is what Metal itself does on Apple GPUs.
    size_t width = std::min<size_t>(CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), texture.width);
    size_t height = std::min<size_t>(CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), texture.height);
    if (!width || !height || !bytesPerPixel)
        return;
    size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
    auto bytesReadPerRow = checkedProduct<size_t>(width, bytesPerPixel);
    if (bytesReadPerRow.hasOverflowed() || bytesReadPerRow.value() > bytesPerRow)
        return;
    void* imageBytes = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane);
    RELEASE_ASSERT(imageBytes);

    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:imageBytes bytesPerRow:bytesPerRow];
}

IOSurfaceRef pixelBufferIOSurface(CVPixelBufferRef pixelBuffer)
{
    return CVPixelBufferGetIOSurface(pixelBuffer);
}

#if HAVE(COREVIDEO_METAL_SUPPORT)
CVMetalTextureCacheRef createCoreVideoTextureCache(id<MTLDevice> device)
{
    // This is an out-parameter which is returned retained.
    SUPPRESS_UNRETAINED_LOCAL CVMetalTextureCacheRef cache = nullptr;
    CVReturn result = CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache);
    ASSERT_UNUSED(result, result == kCVReturnSuccess);
    return cache;
}

CVMetalTextureRef createCoreVideoPlaneTexture(CVMetalTextureCacheRef cache, CVPixelBufferRef pixelBuffer, MTLPixelFormat pixelFormat, size_t plane)
{
    // This is an out-parameter which is immediately adopted below.
    SUPPRESS_UNRETAINED_LOCAL CVMetalTextureRef texture = nullptr;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, pixelBuffer, nullptr, pixelFormat, CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture);
    RetainPtr adoptedTexture = adoptCF(texture);
    if (status != kCVReturnSuccess)
        return nullptr;
    return adoptedTexture.leakRef();
}

CleanTexCoords cleanTexCoords(CVMetalTextureRef texture)
{
    std::array<float, 2> lowerLeft { };
    std::array<float, 2> lowerRight { };
    std::array<float, 2> upperRight { };
    std::array<float, 2> upperLeft { };
    CVMetalTextureGetCleanTexCoords(texture, lowerLeft.data(), lowerRight.data(), upperRight.data(), upperLeft.data());
    return { .lowerLeftX = lowerLeft[0], .lowerRightY = lowerRight[1], .upperRightX = upperRight[0], .upperLeftY = upperLeft[1] };
}
#endif

} // namespace WebGPU::Metal
