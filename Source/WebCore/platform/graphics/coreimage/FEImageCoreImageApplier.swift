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
import IOSurface
import WebCore_Private.Core.AffineTransform
import WebCore_Private.Core.FEImageParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.IntRect

// FEImageCoreImageApplier::apply(): the source image, mapped to its place in the absolute enclosing filter region.
func feImageApplyCoreImage(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEImageParameters,
    _ source: WebCore.FEImageSource,
    _ result: inout FilterImageImpl
) -> Bool {
    let sourceImageRect = parameters.sourceImageRect
    if sourceImageRect.isEmpty() {
        result.setCIImage(CIImage.empty())
        return true
    }

    var image: CIImage?
    switch source.kind {
    case .NativeImage:
        let imageRect = context.scaledByFilterScale(sourceImageRect)

        image = source.copyNativeImagePlatformImage().map { CIImage(cgImage: $0) }

        let sourceRect = WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(source.nativeImageSize()))
        let destinationRect = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(WebCore.roundedIntRect(imageRect))

        let transform = WebCore.makeMapBetweenRects(sourceRect, destinationRect)
        image = image?.transformed(by: cgAffineTransform(transform))
    case .ImageBuffer:
        guard let surface = source.imageBufferSurface() else {
            return false
        }

        // FIXME: This geometry computation needs fixing per webkit.org/b/304911.
        var sourceRect = sourceImageRect
        sourceRect.moveBy(result.primitiveSubregion.location())
        let scaledSourceRect = context.scaledByFilterScale(sourceRect)

        let absoluteSourceRect = context.flippedRectRelativeToAbsoluteEnclosingFilterRegion(scaledSourceRect)
        let translation = CGAffineTransform(translationX: CGFloat(absoluteSourceRect.x()), y: CGFloat(absoluteSourceRect.y()))
        image = CIImage(ioSurface: surface).transformed(by: translation).cropped(to: context.coreImageRect(result.absoluteImageRect))
    case .None:
        image = nil
    @unknown default:
        image = nil
    }

    guard let image else {
        return false
    }
    result.setCIImage(image)
    return true
}

// AffineTransform's CGAffineTransform conversion (TransformationMatrixCG.cpp).
private func cgAffineTransform(_ transform: WebCore.AffineTransform) -> CGAffineTransform {
    CGAffineTransform(a: transform.a(), b: transform.b(), c: transform.c(), d: transform.d(), tx: transform.e(), ty: transform.f())
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
