// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT
#if USE_CORE_IMAGE

import CoreGraphics
import CoreImage
import IOSurface
import WebCore_Internal.FilterCoreImageSwiftBridge
import WebCore_Internal.FilterSwiftBridge
import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.ImageBuffer
import WebCore_Internal.SourceGraphicParameters

// SourceGraphicCoreImageApplier::apply(): the input's Core Image result, or else its image buffer, moved to the
// result's place in the absolute enclosing filter region.
func sourceGraphicApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    var image = input.ciImage
    if image == nil {
        guard let sourceImage = input.imageBuffer().get() else {
            return false
        }

        if let surface = WebCore.FilterCoreImageSwiftBridge.ioSurface(sourceImage) {
            image = CIImage(ioSurface: surface)
        } else {
            image = WebCore.SourceGraphicBridge.copyPlatformImage(sourceImage).map { CIImage(cgImage: $0) }
        }

        let offset = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(result.absoluteImageRect).location()
        if !offset.isZero() {
            image = image?.transformed(by: CGAffineTransform(translationX: CGFloat(offset.x()), y: CGFloat(offset.y())))
        }
    }

    guard let image else {
        return false
    }
    result.setCIImage(image)
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
