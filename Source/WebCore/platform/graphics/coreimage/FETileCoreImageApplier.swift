// Copyright (C) 2026 Apple Inc. All rights reserved.
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
import CoreImage.CIFilterBuiltins
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect

// FETileCoreImageApplier::apply(): the input's maximum effect rect, extended with transparent black where the input
// doesn't cover it, tiled and cropped to the result.
func feTileApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ input: borrowing FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let inputImage = input.ciImage else {
        return false
    }

    let scaledTileRect = context.scaledByFilterScale(context.maxEffectRect(input.primitiveSubregion))
    let tileRect = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(scaledTileRect)
    let tileCGRect = CGRect(
        x: CGFloat(tileRect.x()),
        y: CGFloat(tileRect.y()),
        width: CGFloat(tileRect.width()),
        height: CGFloat(tileRect.height())
    )

    let imageExtent = WebCore.FloatRect(inputImage.extent)
    let tileImage: CIImage
    if imageExtent.contains(tileRect) {
        tileImage = inputImage.cropped(to: tileCGRect)
    } else {
        let clearImage = CIImage(color: CIColor.clear).cropped(to: tileCGRect)
        tileImage = inputImage.composited(over: clearImage).cropped(to: tileCGRect)
    }

    let tileFilter = CIFilter.affineTile()
    tileFilter.inputImage = tileImage
    // The identity transform is necessary: the default one scales the tiles.
    tileFilter.transform = .identity

    result.setCIImage(tileFilter.outputImage?.cropped(to: context.coreImageRect(result.absoluteImageRect)))
    return true
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
