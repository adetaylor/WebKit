// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

#if ENABLE_WEBCORE_SWIFT

// The safe Span overloads Swift synthesizes for PixelBufferAccess call Cxx's Span(_unsafeCxxSpan:). Xcode builds don't
// find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.FEDisplacementMapParameters
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferSwiftBridge

// FEDisplacementMap::calculateOutsets().
@_expose(Cxx)
func feDisplacementMapOutsets(_ maxDisplacement: WebCore.FloatSize) -> WebCore.FilterOutsets {
    let displacement = WebCore.expandedIntSize(maxDisplacement)
    return WebCore.FilterOutsets(
        top: displacement.height(),
        right: displacement.width(),
        bottom: displacement.height(),
        left: displacement.width()
    )
}

func feDisplacementMapApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDisplacementMapParameters,
    _ input: inout FilterImageImpl,
    _ displacementInput: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let xChannelSelector = parameters.xChannelSelector
    let yChannelSelector = parameters.yChannelSelector
    assert(xChannelSelector != .CHANNEL_UNKNOWN)
    assert(yChannelSelector != .CHANNEL_UNKNOWN)

    // §16.4: when in2 is tainted, act as a pass-through of in.
    if parameters.in2IsTainted {
        return drawDisplacementMapInput(&input, &result)
    }

    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }

    let inputPixelBuffer = input.getPixelBuffer(.Premultiplied, sourceRect: result.absoluteImageRect(relativeTo: input))
    // The calculations using the pixel values from ‘in2’ are performed using non-premultiplied color values.
    let displacementPixelBuffer = displacementInput.getPixelBuffer(
        .Unpremultiplied,
        sourceRect: result.absoluteImageRect(relativeTo: displacementInput)
    )
    return displace(context, parameters, inputPixelBuffer, displacementPixelBuffer, destination, result.absoluteImageRect.size())
}

// feDisplacementMapApplySoftware() with both inputs the same image, which can't be passed `inout` twice.
func feDisplacementMapApplySoftwareWithSameInputs(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDisplacementMapParameters,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let xChannelSelector = parameters.xChannelSelector
    let yChannelSelector = parameters.yChannelSelector
    assert(xChannelSelector != .CHANNEL_UNKNOWN)
    assert(yChannelSelector != .CHANNEL_UNKNOWN)

    if parameters.in2IsTainted {
        return drawDisplacementMapInput(&input, &result)
    }

    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }

    let sourceRect = result.absoluteImageRect(relativeTo: input)
    let inputPixelBuffer = input.getPixelBuffer(.Premultiplied, sourceRect: sourceRect)
    let displacementPixelBuffer = input.getPixelBuffer(.Unpremultiplied, sourceRect: sourceRect)
    return displace(context, parameters, inputPixelBuffer, displacementPixelBuffer, destination, result.absoluteImageRect.size())
}

private func drawDisplacementMapInput(_ input: inout FilterImageImpl, _ result: inout FilterImageImpl) -> Bool {
    let resultImage = result.imageBuffer()
    let inputImage = input.imageBuffer()
    guard let resultImageBuffer = resultImage.get(), let inputImageBuffer = inputImage.get() else {
        return false
    }
    filterDrawImageBuffer(resultImageBuffer, inputImageBuffer, input.absoluteImageRect(relativeTo: result))
    return true
}

private func displace(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEDisplacementMapParameters,
    _ inputPixelBuffer: borrowing WebCore.RefPtrPixelBuffer,
    _ displacementPixelBuffer: borrowing WebCore.RefPtrPixelBuffer,
    _ destination: WebCore.PixelBuffer,
    _ paintSize: WebCore.IntSize
) -> Bool {
    guard let source = inputPixelBuffer.get(), let displacement = displacementPixelBuffer.get() else {
        return false
    }

    let xChannelSelector = parameters.xChannelSelector
    let yChannelSelector = parameters.yChannelSelector
    let scale = context.scaledByFilterScale(context.resolvedSize(WebCore.FloatSize(parameters.scale, parameters.scale)))
    let displacementScale = DisplacementScale(
        colorX: Float(Double(scale.width()) / 255),
        colorY: Float(Double(scale.height()) / 255),
        offsetX: Float(0.5 - Double(scale.width()) * 0.5),
        offsetY: Float(0.5 - Double(scale.height()) * 0.5)
    )
    let width = paintSize.width()
    let height = paintSize.height()
    if width <= 0 || height <= 0 {
        return true
    }
    // Both selectors must name a channel.
    precondition(xChannelSelector != .CHANNEL_UNKNOWN && yChannelSelector != .CHANNEL_UNKNOWN)

    let sourceAccess = WebCore.PixelBufferAccess(source)
    let sourceBytes: Span<UInt8> = sourceAccess.span()
    let displacementAccess = WebCore.PixelBufferAccess(displacement)
    let displacementBytes: Span<UInt8> = displacementAccess.span()
    var destinationAccess = WebCore.PixelBufferAccess(destination)
    var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    displaceRows(
        sourceBytes.bytes,
        displacementBytes.bytes,
        into: &destinationBytes,
        width: width,
        height: height,
        xChannel: Int(xChannelSelector.rawValue) - 1,
        yChannel: Int(yChannelSelector.rawValue) - 1,
        scale: displacementScale
    )
    return true
}

// A displacement byte d moves a pixel by color * d + offset.
private struct DisplacementScale {
    var colorX: Float
    var colorY: Float
    var offsetX: Float
    var offsetY: Float
}

// Each pixel of `destination` (width x height, tightly packed, as are both sources) becomes the source pixel displaced by
// the channels xChannel and yChannel of the displacement pixel at its place, or transparent black outside the source.
private func displaceRows(
    _ source: RawSpan,
    _ displacement: RawSpan,
    into destination: inout MutableSpan<UInt8>,
    width: Int32,
    height: Int32,
    xChannel: Int,
    yChannel: Int,
    scale: DisplacementScale
) {
    // The offset of each value of a displacement byte, converted as C++ converted it for every pixel.
    var offsets = ContiguousArray<Int32>()
    offsets.reserveCapacity(512)
    for value in 0...255 {
        offsets.append(Int32(arm64Truncating: scale.colorX * Float(value) + scale.offsetX))
    }
    for value in 0...255 {
        offsets.append(Int32(arm64Truncating: scale.colorY * Float(value) + scale.offsetY))
    }
    let offsetSpan = offsets.span

    // The displacement channels, as shifts of a little-endian pixel.
    let xShift = UInt32(truncatingIfNeeded: xChannel * 8)
    let yShift = UInt32(truncatingIfNeeded: yChannel * 8)
    let rowBytes = Int(width) * 4
    var destinationBytes = destination.mutableBytes
    for y in 0..<height {
        let rowStart = Int(y) &* rowBytes
        let displacementRow = displacement.extracting(rowStart..<rowStart &+ rowBytes)
        withMutableSubspan(of: &destinationBytes, rowStart..<rowStart &+ rowBytes) { destinationRow in
            for x in 0..<width {
                let index = Int(x) &* 4
                let displacementPixel = UInt32(littleEndian: displacementRow.load(fromByteOffset: index, as: UInt32.self))
                // Wraps on overflow, for a huge scale.
                let sourceX = x &+ offsetSpan[Int((displacementPixel &>> xShift) & 0xFF)]
                let sourceY = y &+ offsetSpan[256 &+ Int((displacementPixel &>> yShift) & 0xFF)]
                var pixel: UInt32 = 0
                if sourceX >= 0 && sourceX < width && sourceY >= 0 && sourceY < height {
                    pixel = source.load(fromByteOffset: Int(sourceY) &* rowBytes &+ Int(sourceX) &* 4, as: UInt32.self)
                }
                destinationRow.storeBytes(of: pixel, toByteOffset: index, as: UInt32.self)
            }
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT
