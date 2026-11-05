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

#import "Texture.h"
#import <wtf/FastMalloc.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cocoa/IOTypesSPI.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#endif

namespace WebGPU::Metal {

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
