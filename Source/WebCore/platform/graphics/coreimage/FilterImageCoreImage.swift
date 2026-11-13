// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
import IOSurface
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.FilterCoreImageSwiftBridge
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.RenderingMode

// The image buffer of a filter image with a Core Image result: the first call renders the result into a new accelerated
// image buffer, which becomes the image's image buffer. Null if that fails. Without a Core Image result, the image
// buffer. `absoluteFilterRegion` is the filter's absolute enclosing filter region, which the result's extent is
// relative to.
func renderedFilterResultImageBuffer(
    _ image: inout FilterImageImpl,
    absoluteFilterRegion: WebCore.FloatRect,
    showDebugOverlay: Bool
) -> WebCore.RefPtrImageBuffer {
    guard let ciImage = image.ciImage else {
        return image.imageBuffer()
    }
    let existingImageBuffer = image.existingImageBuffer()
    if existingImageBuffer.get() != nil {
        return existingImageBuffer
    }
    let absoluteImageRect = image.absoluteImageRect
    let colorSpace = image.colorSpace
    let renderedImageBuffer = image.createImageBuffer(
        size: WebCore.FloatSize(absoluteImageRect.size()),
        colorSpace: colorSpace,
        renderingMode: .Accelerated
    )
    guard let imageBuffer = renderedImageBuffer.get(), let surface = WebCore.FilterCoreImageSwiftBridge.ioSurface(imageBuffer) else {
        return WebCore.RefPtrImageBuffer()
    }
    image.setImageBuffer(imageBuffer)

    let context = filterResultContext(linearSRGB: colorSpace == WebCore.FilterCoreImageSwiftBridge.linearSRGBColorSpace())

    // startTask(toRender:from:to:at:) takes the rect that the extents of the earlier images are relative to (in flipped
    // coordinates). render(_:to:) would use the size of the IOSurface, which is only the output size of the last filter
    // operation.
    let destination = CIRenderDestination(ioSurface: surface as IOSurface)
    destination.colorSpace = WebCore.FilterCoreImageSwiftBridge.platformColorSpace(colorSpace)

    var outputImage = ciImage
    if showDebugOverlay, let stripes = debugOverlayStripes() {
        outputImage = stripes.composited(over: outputImage)
    }

    let sourceRect = CGRect(x: 0, y: 0, width: CGFloat(absoluteFilterRegion.width()), height: CGFloat(absoluteFilterRegion.height()))
    let locationX = Float(absoluteImageRect.x()) - absoluteFilterRegion.x()
    let locationY = absoluteFilterRegion.maxY() - Float(absoluteImageRect.maxY())
    let point = CGPoint(x: CGFloat(-locationX), y: CGFloat(-locationY))
    if let task = try? context.startTask(toRender: outputImage, from: sourceRect, to: destination, at: point) {
        _ = try? task.waitUntilCompleted()
    }

    WebCore.FilterCoreImageSwiftBridge.logFilterResultImageBuffer(absoluteImageRect, imageBuffer)
    return renderedImageBuffer
}

extension FilterImageImpl {
    // The float converts to size_t saturating, as on arm64: an infinite extent is out of range.
    static func memoryCost(of image: CIImage) -> UInt {
        let size = WebCore.FloatSize(image.extent.size)
        return UInt(arm64Truncating: size.area() * 4)
    }
}

// Rotated yellow stripes, drawn over filter results rendered with FilterRenderingOption::ShowDebugOverlay.
private func debugOverlayStripes() -> CIImage? {
    let stripes = CIFilter.stripesGenerator()
    stripes.width = 30
    stripes.color0 = CIColor.clear
    stripes.color1 = CIColor(red: 1, green: CGFloat(Float(0.95)), blue: 0, alpha: 0.35)
    stripes.sharpness = 0.9
    // deg2rad(45.f), in float as in C++.
    let angle = Float(45) * (Float(Double.pi) / 180)
    return stripes.outputImage?.transformed(by: CGAffineTransform(rotationAngle: CGFloat(angle)))
}

// The Core Image contexts that render filter results, one per working color space, each created on first use, unless
// a test has provided its own.
private let linearSRGBFilterResultContext = filterResultContext(
    workingColorSpace: WebCore.FilterCoreImageSwiftBridge.linearSRGBColorSpace()
)
private let sRGBFilterResultContext = filterResultContext(workingColorSpace: WebCore.FilterCoreImageSwiftBridge.sRGBColorSpace())

private func filterResultContext(workingColorSpace: borrowing WebCore.ColorSpace) -> CIContext {
    CIContext(options: [.workingColorSpace: WebCore.FilterCoreImageSwiftBridge.platformColorSpace(workingColorSpace) as Any])
}

private func filterResultContext(linearSRGB: Bool) -> CIContext {
    linearSRGB ? linearSRGBFilterResultContext : sRGBFilterResultContext
}

#endif // USE_CORE_IMAGE
#endif // ENABLE_WEBCORE_SWIFT
