// Copyright (C) 2003-2026 Apple Inc. All rights reserved.
// Copyright (C) 2008 Eric Seidel <eric@webkit.org>
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
//
// Copyright (C) 2003-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && USE_CG

// The safe MutableSpan overload Swift synthesizes for CGRendererGlyphPositions's span accessor comes from Cxx. Xcode builds
// don't find it unless this file imports Cxx.
private import Cxx
// CGRendererCore's members for a Swift receiver use these.
public import CoreGraphics
import CoreText
import WebCore_Private.Core.AffineTransform
import WebCore_Private.Core.CGRendererSPI
public import WebCore_Private.Core.CGRendererSwiftBridge
import WebCore_Private.Core.Color
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
public import WebCore_Private.Core.GraphicsTypes
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.ShadowBlurSwiftBridge
public import WebCore_Private.Core.WindRule

// std::max's choice: the first argument unless it is less than the second, so -0 and NaN stay.
private func cxxMax(_ a: Float, _ b: Float) -> Float {
    a < b ? b : a
}

private func cxxMin(_ a: Float, _ b: Float) -> Float {
    b < a ? b : a
}

private func cxxMax(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    a < b ? b : a
}

private func cxxMin(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    b < a ? b : a
}

// WTF's clampTo<int>(float): NaN gives INT_MIN.
private func clampToInt(_ value: Float) -> Int32 {
    if value >= 2_147_483_648 {
        return .max
    }
    if !(value > -2_147_483_648) {
        return .min
    }
    return Int32(value)
}

// C++'s float to int conversion where it's undefined, as the processor does it: arm64 saturates and gives 0 for NaN, x86
// gives INT_MIN.
private func cxxIntConversion(_ value: Float) -> Int32 {
    if value.isNaN || value >= 2_147_483_648 || value < -2_147_483_648 {
        #if arch(arm64)
        return value.isNaN ? 0 : (value < 0 ? .min : .max)
        #else
        return .min
        #endif
    }
    return Int32(value)
}

// WebCore's own CGColor for the color, as the C++ used: CG strokes ellipses more slowly with one CGColorCreateSRGB() makes.
private func cgColor(packed: UInt32) -> CGColor {
    CGRendererCopyCachedColor(packed)
}

private func cgBlendMode(_ compositeOperator: WebCore.CompositeOperator, _ blendMode: WebCore.BlendMode) -> CGBlendMode {
    switch blendMode {
    case .Normal:
        switch compositeOperator {
        case .Clear: return .clear
        case .Copy: return .copy
        case .SourceOver: return .normal
        case .SourceIn: return .sourceIn
        case .SourceOut: return .sourceOut
        case .SourceAtop: return .sourceAtop
        case .DestinationOver: return .destinationOver
        case .DestinationIn: return .destinationIn
        case .DestinationOut: return .destinationOut
        case .DestinationAtop: return .destinationAtop
        case .XOR: return .xor
        case .PlusDarker: return .plusDarker
        case .PlusLighter: return .plusLighter
        case .Difference: return .difference
        @unknown default: return .normal
        }
    case .Multiply: return .multiply
    case .Screen: return .screen
    case .Overlay: return .overlay
    case .Darken: return .darken
    case .Lighten: return .lighten
    case .ColorDodge: return .colorDodge
    case .ColorBurn: return .colorBurn
    case .HardLight: return .hardLight
    case .SoftLight: return .softLight
    case .Difference: return .difference
    case .Exclusion: return .exclusion
    case .Hue: return .hue
    case .Saturation: return .saturation
    case .Color: return .color
    case .Luminosity: return .luminosity
    case .PlusDarker: return .plusDarker
    case .PlusLighter: return .plusLighter
    @unknown default: return .normal
    }
}

private func cgInterpolationQuality(_ quality: WebCore.InterpolationQuality) -> CGInterpolationQuality {
    switch quality {
    case .Default: .default
    case .DoNotInterpolate: .none
    case .Low: .low
    case .Medium: .medium
    case .High: .high
    @unknown default: .default
    }
}

private func cgTextDrawingMode(_ mode: UInt8) -> CGTextDrawingMode {
    let fill = mode & 1 != 0
    let stroke = mode & 2 != 0
    if fill && stroke {
        return .fillStroke
    }
    if fill {
        return .fill
    }
    return .stroke
}

// FloatRect's arithmetic, in Float as the C++ does it.
private struct CGRendererRect: Equatable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float

    var maxX: Float { x + width }
    var maxY: Float { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    var normalized: CGRendererRect {
        CGRendererRect(x: cxxMin(x, maxX), y: cxxMin(y, maxY), width: cxxMax(width, -width), height: cxxMax(height, -height))
    }

    func intersects(_ other: CGRendererRect) -> Bool {
        !isEmpty && !other.isEmpty && x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func contains(_ other: CGRendererRect) -> Bool {
        x <= other.x && maxX >= other.maxX && y <= other.y && maxY >= other.maxY
    }

    var cgRect: CGRect { CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) }

    // FloatRect::intersect(): an empty intersection is the zero rect.
    func intersection(_ other: CGRendererRect) -> CGRendererRect {
        var l = cxxMax(x, other.x)
        var t = cxxMax(y, other.y)
        var r = cxxMin(maxX, other.maxX)
        var b = cxxMin(maxY, other.maxY)
        if l >= r || t >= b {
            l = 0
            t = 0
            r = 0
            b = 0
        }
        return CGRendererRect(x: l, y: t, width: r - l, height: b - t)
    }
}

// IntRect, for enclosingIntRect().
private struct CGRendererIntRect {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    init(enclosing rect: CGRendererRect) {
        let locationX = Float(clampToInt(rect.x.rounded(.down)))
        let locationY = Float(clampToInt(rect.y.rounded(.down)))
        let maxX = Float(clampToInt(rect.maxX.rounded(.up)))
        let maxY = Float(clampToInt(rect.maxY.rounded(.up)))
        x = clampToInt(locationX)
        y = clampToInt(locationY)
        width = clampToInt(maxX - locationX)
        height = clampToInt(maxY - locationY)
    }

    var rect: CGRendererRect { CGRendererRect(x: Float(x), y: Float(y), width: Float(width), height: Float(height)) }
}

// ImageOrientation::Orientation; 0 is FromImage, which callers resolve before drawing.
private enum CGRendererOrientation {
    static let none: UInt8 = 1

    static func usesWidthAsHeight(_ orientation: UInt8) -> Bool {
        (5...8).contains(orientation)
    }
}

// AffineTransform's arithmetic, in Double as the C++ does it, for the transforms of image orientations.
private struct CGRendererTransform {
    var a: Double
    var b: Double
    var c: Double
    var d: Double
    var e: Double
    var f: Double

    // ImageOrientation::transformFromDefault(); FromImage is the identity.
    init(fromDefault orientation: UInt8, _ width: Float, _ height: Float) {
        let w = Double(width)
        let h = Double(height)
        switch orientation {
        case 2: (a, b, c, d, e, f) = (-1, 0, 0, 1, w, 0)
        case 3: (a, b, c, d, e, f) = (-1, 0, 0, -1, w, h)
        case 4: (a, b, c, d, e, f) = (1, 0, 0, -1, 0, h)
        case 5: (a, b, c, d, e, f) = (0, 1, 1, 0, 0, 0)
        case 6: (a, b, c, d, e, f) = (0, 1, -1, 0, w, 0)
        case 7: (a, b, c, d, e, f) = (0, -1, -1, 0, w, h)
        case 8: (a, b, c, d, e, f) = (0, -1, 1, 0, 0, h)
        default: (a, b, c, d, e, f) = (1, 0, 0, 1, 0, 0)
        }
    }

    private init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        (self.a, self.b, self.c, self.d, self.e, self.f) = (a, b, c, d, e, f)
    }

    var isIdentityOrTranslation: Bool { a == 1 && b == 0 && c == 0 && d == 1 }

    var cgAffineTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f) }

    func inverse() -> CGRendererTransform? {
        if isIdentityOrTranslation {
            return CGRendererTransform(1, 0, 0, 1, -e, -f)
        }
        let determinant = a * d - b * c
        if !determinant.isNormal {
            return nil
        }
        return CGRendererTransform(
            d / determinant,
            -b / determinant,
            -c / determinant,
            a / determinant,
            (c * f - d * e) / determinant,
            (b * e - a * f) / determinant
        )
    }

    func mapRect(_ rect: CGRendererRect) -> CGRendererRect {
        if isIdentityOrTranslation {
            return CGRendererRect(x: rect.x + Float(e), y: rect.y + Float(f), width: rect.width, height: rect.height)
        }
        let left = Double(rect.x)
        let top = Double(rect.y)
        let right = Double(rect.maxX)
        let bottom = Double(rect.maxY)
        let aLeft = a * left
        let aRight = a * right
        let bLeft = b * left
        let bRight = b * right
        let cTop = c * top
        let cBottom = c * bottom
        let dTop = d * top
        let dBottom = d * bottom
        let x1 = Float(aLeft + cTop + e)
        let y1 = Float(bLeft + dTop + f)
        let x2 = Float(aRight + cTop + e)
        let y2 = Float(bRight + dTop + f)
        let x3 = Float(aRight + cBottom + e)
        let y3 = Float(bRight + dBottom + f)
        let x4 = Float(aLeft + cBottom + e)
        let y4 = Float(bLeft + dBottom + f)
        let minX = cxxMin(cxxMin(x1, x2), cxxMin(x3, x4))
        let minY = cxxMin(cxxMin(y1, y2), cxxMin(y3, y4))
        let maxX = cxxMax(cxxMax(x1, x2), cxxMax(x3, x4))
        let maxY = cxxMax(cxxMax(y1, y2), cxxMax(y3, y4))
        return CGRendererRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private func safeFPDivision(_ u: Double, _ v: Double) -> Double {
    if v < 1 && u > v * Double.greatestFiniteMagnitude {
        return Double.greatestFiniteMagnitude
    }
    if v > 1 && u < v * Double.leastNormalMagnitude {
        return 0
    }
    return u / v
}

private func areEssentiallyEqual(_ u: Double, _ v: Double) -> Bool {
    if u == v {
        return true
    }
    let delta = abs(u - v)
    return safeFPDivision(delta, abs(u)) <= Double.ulpOfOne && safeFPDivision(delta, abs(v)) <= Double.ulpOfOne
}

// A plain value, so that saving the state is a copy. As in SourceBrush, the color is kept under a gradient or pattern.
private struct CGRendererBrush {
    var packedColor: UInt32 = 0x0000_00FF
    // 0 for packedColor, otherwise 1 + the index of a color that isn't sRGBA8 in CGRendererCore.platformColors.
    var platformColorSlot: UInt32 = 0
    // For a gradient or a pattern, 1 + the index of its CGRendererBrushSource in CGRendererCore.sources.
    var sourceSlot: UInt32 = 0
    // 0 for a color, 1 for a gradient, 2 for a pattern.
    var kind: UInt8 = 0
    var isColorVisible = true

    var hasPatternOrGradient: Bool { kind != 0 }
    var hasGradient: Bool { kind == 1 }
    var hasPattern: Bool { kind == 2 }

    // SourceBrush::isVisible().
    var isVisible: Bool { hasPatternOrGradient || isColorVisible }

    // A slot names the same object in both, as a level only adds slots after those of the levels below.
    func isSame(as other: CGRendererBrush) -> Bool {
        packedColor == other.packedColor && platformColorSlot == other.platformColorSlot && sourceSlot == other.sourceSlot
            && kind == other.kind && isColorVisible == other.isColorVisible
    }
}

// FontSmoothingMode.
private enum CGRendererFontSmoothing {
    static let none: UInt8 = 1
    static let antialiased: UInt8 = 2
}

// TextDrawingMode: fill alone.
private enum CGRendererTextDrawingMode {
    static let fill: UInt8 = 1
}

// AffineTransform::isIdentityOrTranslationOrFlipped().
private func isIdentityOrTranslationOrFlipped(_ t: CGAffineTransform) -> Bool {
    t.a == 1 && t.b == 0 && t.c == 0 && (t.d == 1 || t.d == -1)
}

// WTF::isIntegral(float).
private func isIntegral(_ value: Float) -> Bool {
    !value.isInfinite && value.rounded(.towardZero) == value
}

// What a ShadowBlur shadow the renderer draws for itself needs besides the state: the fill to set for the shadow's color (nil
// when the C++ state's fill is that color already, so GraphicsContextState::setFillColor() wouldn't touch CG).
private struct CGRendererShadowBlurDrawing {
    var fill: CGRendererBrush?
}

// ShadowBlur's pieces, drawn as GraphicsContext would draw them through a GraphicsContextView of the GraphicsContextCG: each in
// a save, with the shadow cleared and the shadow's color as the fill. The color ShadowBlur passes is the shadow's, which
// fillRectWithShadowBlur() turned into a fill already. Swift calls these, so they stay out of the C++ header.
extension CGRendererCore: ShadowDrawing {
    @_expose(!Cxx)
    mutating func drawShadowBuffer(
        _ layerImage: WebCore.ImageBuffer,
        _ layerOrigin: WebCore.FloatPoint,
        _ layerSize: WebCore.FloatSize,
        _ color: borrowing WebCore.Color
    ) {
        save(false)
        let bufferSize = layerImage.backendSize()
        let bufferWidth = Float(bufferSize.width())
        let bufferHeight = Float(bufferSize.height())
        let layerRect = CGRendererRect(x: layerOrigin.x(), y: layerOrigin.y(), width: layerSize.width(), height: layerSize.height())
        if bufferWidth != layerSize.width() || bufferHeight != layerSize.height() {
            // The rect passed to clipToNativeImage() has to be the size of the entire buffer, but we may not have cleared it
            // all, so clip to the filled part first.
            clip(layerRect.cgRect)
        }
        clipToImageBuffer(layerImage, CGRendererRect(x: layerOrigin.x(), y: layerOrigin.y(), width: bufferWidth, height: bufferHeight))
        setShadowBlurFill()
        clearDropShadow()
        _ = fillRect(layerRect.cgRect)
        restore()
    }

    @_expose(!Cxx)
    mutating func drawShadowLayerPieces(_ layerImage: WebCore.ImageBuffer, _ tiles: ShadowBlurTiles) {
        var imageHeadroom: Float = 1
        guard let image = CGRendererCopyImageBufferImage(layerImage, &imageHeadroom) else {
            return
        }
        let resolutionScale = layerImage.resolutionScale()
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.top)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.bottom)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.left)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.right)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.topLeft)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.topRight)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.bottomRight)
        drawShadowImage(image, imageHeadroom, resolutionScale, tiles.bottomLeft)
    }

    @_expose(!Cxx)
    mutating func fillShadowRect(_ rect: WebCore.FloatRect, _ color: borrowing WebCore.Color) {
        save(false)
        setShadowBlurFill()
        clearDropShadow()
        _ = fillRect(CGRendererRect(x: rect.x(), y: rect.y(), width: rect.width(), height: rect.height()).cgRect)
        restore()
    }

    @_expose(!Cxx)
    mutating func fillShadowRectWithHole(_ rect: WebCore.FloatRect, _ holeRect: WebCore.FloatRect, _ color: borrowing WebCore.Color) {
        let path = CGMutablePath()
        path.addRect(CGRendererRect(x: rect.x(), y: rect.y(), width: rect.width(), height: rect.height()).cgRect)
        path.addRect(CGRendererRect(x: holeRect.x(), y: holeRect.y(), width: holeRect.width(), height: holeRect.height()).cgRect)
        save(false)
        setFillRule(1)
        setShadowBlurFill()
        clearDropShadow()
        fillPath(path)
        restore()
    }

    private mutating func setShadowBlurFill() {
        guard let fill = shadowBlurDrawing?.fill else {
            return
        }
        state.fill = fill
        levelChanges |= CxxStateChange.fillBrush
        context.setFillColor(platformColor(fill))
    }

    // A clip to the image buffer's image: false for a buffer without an image, which clips nothing.
    @discardableResult
    fileprivate func clipToImageBuffer(_ imageBuffer: WebCore.ImageBuffer, _ rect: CGRendererRect) -> Bool {
        var headroom: Float = 1
        guard let image = CGRendererCopyImageBufferImage(imageBuffer, &headroom) else {
            return false
        }
        clipToImage(image, rect)
        return true
    }

    // GraphicsContextCG::clipToNativeImage().
    fileprivate func clipToImage(_ image: CGImage, _ rect: CGRendererRect) {
        let size = CGRect(x: 0, y: 0, width: CGFloat(rect.width), height: CGFloat(rect.height))
        context.translateBy(x: CGFloat(rect.x), y: CGFloat(rect.maxY))
        context.scaleBy(x: 1, y: -1)
        context.clip(to: size)
        context.clip(to: size, mask: image)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-rect.x), y: CGFloat(-rect.maxY))
    }

    // GraphicsContext::drawImageBuffer() of a piece, with default options but the composite operator, in a save without a
    // shadow.
    private mutating func drawShadowImage(_ image: CGImage, _ imageHeadroom: Float, _ resolutionScale: Float, _ tile: ShadowBlurTile) {
        let destination = tile.destination.floatRect
        let source = tile.source.floatRect
        save(false)
        clearDropShadow()
        _ = drawNativeImage(
            image,
            Float(image.width),
            Float(image.height),
            destination.x(),
            destination.y(),
            destination.width(),
            destination.height(),
            source.x() * resolutionScale,
            source.y() * resolutionScale,
            source.width() * resolutionScale,
            source.height() * resolutionScale,
            .SourceOver,
            .Normal,
            .Default,
            CGRendererOrientation.none,
            imageHeadroom,
            0
        )
        restore()
    }
}

// GradientSpreadMethod.
private enum CGRendererSpreadMethod {
    static let pad: UInt8 = 0
    static let reflect: UInt8 = 1
}

private enum CGRendererStrokeStyle {
    static let noStroke: UInt8 = 0
    static let dottedStroke: UInt8 = 2
    static let dashedStroke: UInt8 = 3
}

// A GraphicsDropShadow. Its color is as a brush's.
private struct CGRendererShadow {
    var width: Float
    var height: Float
    var radius: Float
    var opacity: Float
    var packedColor: UInt32
    var platformColorSlot: UInt32
    var isValid: Bool
    var isVisible: Bool
    var isLegacyRadius: Bool

    var isBlurred: Bool { isVisible && radius != 0 }

    // FloatSize::isZero().
    var hasZeroOffset: Bool { abs(width) < Float.ulpOfOne && abs(height) < Float.ulpOfOne }
}

private enum CGRendererStyle {
    case none
    case dropShadow(CGRendererShadow)
    case gaussianBlur(width: Float, height: Float)
    // 1 + the index of the matrix in CGRendererCore.sources.
    case colorMatrix(slot: UInt32)
}

private struct CGRendererState {
    var fill = CGRendererBrush()
    var stroke = CGRendererBrush()
    var fillRule: UInt8 = 0
    var strokeThickness: Float = 0
    var strokeStyle: UInt8 = 1
    var compositeOperator = WebCore.CompositeOperator.SourceOver
    var blendMode = WebCore.BlendMode.Normal
    var dropShadow: CGRendererShadow? = nil
    var style = CGRendererStyle.none
    var alpha: Float = 1
    var textDrawingMode: UInt8 = 1
    var imageInterpolationQuality: WebCore.InterpolationQuality
    var shouldAntialias = true
    var shouldSmoothFonts = true
    var shouldSubpixelQuantizeFonts = true
    var shadowsIgnoreTransforms = false

    init(imageInterpolationQuality: WebCore.InterpolationQuality) {
        self.imageInterpolationQuality = imageInterpolationQuality
    }

    // Of candidates, the GraphicsContextState::Change properties whose values differ from other's. Floats compare by bit
    // pattern, as -0 isn't 0 to CG; a shadow or a style counts as different unless neither state has one.
    func cxxChanges(to other: CGRendererState, among candidates: UInt32) -> UInt32 {
        func differs(_ property: UInt32, _ isDifferent: @autoclosure () -> Bool) -> UInt32 {
            candidates & property != 0 && isDifferent() ? property : 0
        }
        var noStyle = false
        if case .none = style, case .none = other.style {
            noStyle = true
        }
        return differs(CxxStateChange.fillBrush, !fill.isSame(as: other.fill))
            | differs(CxxStateChange.fillRule, fillRule != other.fillRule)
            | differs(CxxStateChange.strokeBrush, !stroke.isSame(as: other.stroke))
            | differs(CxxStateChange.strokeThickness, strokeThickness.bitPattern != other.strokeThickness.bitPattern)
            | differs(CxxStateChange.strokeStyle, strokeStyle != other.strokeStyle)
            | differs(CxxStateChange.compositeMode, compositeOperator != other.compositeOperator || blendMode != other.blendMode)
            | differs(CxxStateChange.dropShadow, dropShadow != nil || other.dropShadow != nil)
            | differs(CxxStateChange.style, !noStyle)
            | differs(CxxStateChange.alpha, alpha.bitPattern != other.alpha.bitPattern)
            | differs(CxxStateChange.textDrawingMode, textDrawingMode != other.textDrawingMode)
            | differs(CxxStateChange.imageInterpolationQuality, imageInterpolationQuality != other.imageInterpolationQuality)
            | differs(CxxStateChange.shouldAntialias, shouldAntialias != other.shouldAntialias)
            | differs(CxxStateChange.shouldSmoothFonts, shouldSmoothFonts != other.shouldSmoothFonts)
            | differs(CxxStateChange.shouldSubpixelQuantizeFonts, shouldSubpixelQuantizeFonts != other.shouldSubpixelQuantizeFonts)
            | differs(CxxStateChange.shadowsIgnoreTransforms, shadowsIgnoreTransforms != other.shadowsIgnoreTransforms)
    }

    // GraphicsContextState::repurpose(TransparencyLayer): CGContextBeginTransparencyLayer() resets these in CG.
    mutating func resetForTransparencyLayer() {
        alpha = 1
        style = .none
        dropShadow = nil
        compositeOperator = .SourceOver
        blendMode = .Normal
    }
}

private enum CGRendererPurpose {
    case saveRestore
    case transparencyLayer
}

private struct CGRendererSavedState {
    var state: CGRendererState
    var purpose: CGRendererPurpose
    // The side tables' sizes at the save: the restore drops what was added after it.
    var platformColorCount: UInt32 = 0
    var sourceCount: UInt32 = 0
    // Whether GraphicsContext's own stack has this level too: C++ saved it. A level a Swift receiver saved is the renderer's
    // alone.
    var hasCxxLevel = true
    // The level below's levelChanges and levelHasCxxBrushSource.
    var levelChanges: UInt32 = 0
    var levelHasCxxBrushSource = false
}

// A color that isn't sRGBA8, as CG draws it and as the C++ state has it.
private struct CGRendererPlatformColor {
    var cgColor: CGColor
    var data: CGRendererColorData
}

// What a state refers to by slot because it isn't a plain value: a gradient or pattern brush's C++ objects, or a color matrix
// style's matrix.
private enum CGRendererSource {
    case brush(CGRendererBrushSource)
    #if HAVE_CGSTYLE_COLORMATRIX_BLUR
    case colorMatrix(CGRendererColorMatrix)
    #endif
}

// How many entries a side table can gain since the last save before those the state no longer refers to go. A restore drops
// the entries added since its save.
private enum CGRendererSideTable {
    static let platformColorLimit = 8
    static let sourceLimit = 4
}

// The stroke color and thickness of the line before, for receiveStrokeLinesWithColorAndThickness().
private struct CGRendererLineStroke {
    var color: UInt32? = nil
    var thickness: Float? = nil
}

// The CGColors of the last few packed colors this renderer set. A context is used by one thread at a time.
private struct CGRendererColorCache {
    private var keys: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    private var colors: (CGColor?, CGColor?, CGColor?, CGColor?) = (nil, nil, nil, nil)
    private var next = 0

    mutating func color(_ packed: UInt32) -> CGColor {
        if keys.0 == packed, let color = colors.0 {
            return color
        }
        if keys.1 == packed, let color = colors.1 {
            return color
        }
        if keys.2 == packed, let color = colors.2 {
            return color
        }
        if keys.3 == packed, let color = colors.3 {
            return color
        }
        let color = cgColor(packed: packed)
        switch next {
        case 0:
            keys.0 = packed
            colors.0 = color
        case 1:
            keys.1 = packed
            colors.1 = color
        case 2:
            keys.2 = packed
            colors.2 = color
        default:
            keys.3 = packed
            colors.3 = color
        }
        next = (next + 1) & 3
        return color
    }
}

// GraphicsContextCG's drawing into its CGContext, with its own copy of the GraphicsContext state. GraphicsContextCG stores it
// in place, and forwards each state change, save, restore and draw. A draw returns false when this renderer doesn't do that case yet; GraphicsContextCG then draws it in C++, with the
// same state.
@_expose(Cxx)
@_spi(WebKitGPU) public struct CGRendererCore {
    private let context: CGContext
    private let isUnaccelerated: Bool
    private let isPDFContext: Bool
    private var state: CGRendererState
    private var stack: [CGRendererSavedState]
    private var depth = 0
    private var platformColors: [CGRendererPlatformColor] = []
    private var sources: [CGRendererSource] = []
    private var colorCache = CGRendererColorCache()
    private var clipOutRects = [CGRect.zero, CGRect.zero]
    // Reused, so that only a context's first use of them allocates.
    private var rectScratch: [CGRect] = []
    private var dashLengths: [CGFloat] = []
    private var lineDash: [CGFloat] = []
    private var lineSegment: [CGPoint] = []
    private var shadowBlurDrawing: CGRendererShadowBlurDrawing? = nil
    // GraphicsContextCG::setMaxEDRHeadroom(): a context's, not a state's.
    private var maxEDRHeadroom: Float? = nil
    // Whether anything since consumeHasDrawn() could have changed the CGContext's contents or state, as
    // GraphicsContextCG::contextForDraw() records it.
    private var hasDrawn = false
    // GraphicsContextCG::roundToDevicePixels()'s cache: true once it has seen an identity user-to-device transform, until
    // something here could change it.
    private var userToDeviceTransformKnownToBeIdentity = false
    // What a Swift receiver has changed since GraphicsContext's own copy of the state last caught up (takeStaleStateForCxx()):
    // the properties, as GraphicsContextState::Change's bits, and how many levels that GraphicsContext's stack has too it has
    // restored.
    private var cxxStaleProperties: UInt32 = 0
    // The properties changed since the top level was saved: GraphicsContext's state may still have them when the renderer
    // restores a level that only a receiver saved.
    private var levelChanges: UInt32 = 0
    private var pendingCxxRestores: UInt32 = 0
    // Whether C++ has given the top level, which only a Swift receiver saved, a gradient or pattern brush: GraphicsContext's
    // state then holds it too, which the receiver's restore would leave there until C++ next reads the state.
    private var levelHasCxxBrushSource = false

    // The C++ destructor of this struct reads its type metadata, whose accessor a Release build (-O -wmo) drops unless Swift
    // uses it (rdar://179098545).
    @used
    private static let cxxTypeMetadata: Any.Type = CGRendererCore.self

    // The context is borrowed.
    @_expose(Cxx)
    init(
        _ context: borrowing CGContext,
        _ isUnaccelerated: Bool,
        _ isPDFContext: Bool,
        _ imageInterpolationQuality: WebCore.InterpolationQuality
    ) {
        self.context = copy context
        self.isUnaccelerated = isUnaccelerated
        self.isPDFContext = isPDFContext
        self.state = CGRendererState(imageInterpolationQuality: imageInterpolationQuality)
        self.stack = Array(repeating: CGRendererSavedState(state: state, purpose: .saveRestore), count: 8)
    }

    private var canUseShadowBlur: Bool {
        isUnaccelerated && (state.dropShadow?.isBlurred ?? false) && !state.shadowsIgnoreTransforms
    }

    private mutating func platformColor(packed: UInt32, slot: UInt32) -> CGColor {
        slot == 0 ? colorCache.color(packed) : platformColors[Int(slot) - 1].cgColor
    }

    private mutating func platformColor(_ brush: CGRendererBrush) -> CGColor {
        platformColor(packed: brush.packedColor, slot: brush.platformColorSlot)
    }

    // fillColor() == strokeColor(), as far as the colors drawn go: C++ also compares flags this state doesn't have, which don't
    // change what CG draws.
    private func fillAndStrokeColorsAreEqual() -> Bool {
        let fill = state.fill
        let stroke = state.stroke
        if fill.platformColorSlot == 0 || stroke.platformColorSlot == 0 {
            return fill.platformColorSlot == stroke.platformColorSlot && fill.packedColor == stroke.packedColor
        }
        return colorDataAreEqual(platformColors[Int(fill.platformColorSlot) - 1].data, platformColors[Int(stroke.platformColorSlot) - 1].data)
    }

    // GraphicsContext's fillColor() == color.
    private func fillColorEquals(_ color: CGRendererColorValue) -> Bool {
        let fill = state.fill
        if color.isPacked {
            return fill.platformColorSlot == 0 && fill.packedColor == color.packedColor
        }
        return fill.platformColorSlot != 0 && colorDataAreEqual(platformColors[Int(fill.platformColorSlot) - 1].data, color.data)
    }

    // GraphicsDropShadow's ==, which compares the offset, the radius and the color, and so GraphicsContextState's setter,
    // which sets nothing for an equal shadow.
    private func shadowEquals(_ shadow: CGRendererShadow?, _ values: CGRendererShadowValues, _ color: CGRendererColorData, _ isPlatformColor: Bool) -> Bool {
        guard let shadow, shadow.width == values.width, shadow.height == values.height, shadow.radius == values.radius, shadow.isValid == values.isValid else {
            return false
        }
        if shadow.platformColorSlot == 0 || !isPlatformColor {
            return shadow.platformColorSlot == 0 && !isPlatformColor && shadow.packedColor == values.packedColor
        }
        return colorDataAreEqual(platformColors[Int(shadow.platformColorSlot) - 1].data, color)
    }

    private func colorDataAreEqual(_ a: CGRendererColorData, _ b: CGRendererColorData) -> Bool {
        a.c1 == b.c1 && a.c2 == b.c2 && a.c3 == b.c3 && a.alpha == b.alpha && a.packedColor == b.packedColor
            && a.colorSpace == b.colorSpace && a.form == b.form && a.isSemantic == b.isSemantic
            && a.usesFunctionSerialization == b.usesFunctionSerialization
    }

    private mutating func platformColorSlot(_ cgColor: CGColor, _ color: CGRendererColorData) -> UInt32 {
        let base = depth == 0 ? 0 : Int(stack[depth - 1].platformColorCount)
        if platformColors.count - base >= CGRendererSideTable.platformColorLimit {
            compactPlatformColors(from: base)
        }
        platformColors.append(CGRendererPlatformColor(cgColor: cgColor, data: color))
        return UInt32(platformColors.count)
    }

    // Only the current state and ShadowBlur's fill refer to the colors added since the last save.
    private mutating func compactPlatformColors(from base: Int) {
        var kept = base
        for index in base..<platformColors.count {
            let slot = UInt32(index + 1)
            let newSlot = UInt32(kept + 1)
            var isReferenced = false
            func move(_ reference: inout UInt32) {
                if reference == slot {
                    reference = newSlot
                    isReferenced = true
                }
            }
            move(&state.fill.platformColorSlot)
            move(&state.stroke.platformColorSlot)
            if var shadow = state.dropShadow {
                move(&shadow.platformColorSlot)
                state.dropShadow = shadow
            }
            if case .dropShadow(var shadow) = state.style {
                move(&shadow.platformColorSlot)
                state.style = .dropShadow(shadow)
            }
            if var drawing = shadowBlurDrawing, var fill = drawing.fill {
                move(&fill.platformColorSlot)
                drawing.fill = fill
                shadowBlurDrawing = drawing
            }
            if isReferenced {
                platformColors.swapAt(index, kept)
                kept += 1
            }
        }
        platformColors.removeLast(platformColors.count - kept)
    }

    private mutating func sourceSlot(_ source: CGRendererSource) -> UInt32 {
        let base = depth == 0 ? 0 : Int(stack[depth - 1].sourceCount)
        if sources.count - base >= CGRendererSideTable.sourceLimit {
            compactSources(from: base)
        }
        sources.append(source)
        return UInt32(sources.count)
    }

    private mutating func compactSources(from base: Int) {
        var kept = base
        for index in base..<sources.count {
            let slot = UInt32(index + 1)
            let newSlot = UInt32(kept + 1)
            var isReferenced = false
            func move(_ reference: inout UInt32) {
                if reference == slot {
                    reference = newSlot
                    isReferenced = true
                }
            }
            move(&state.fill.sourceSlot)
            move(&state.stroke.sourceSlot)
            if case .colorMatrix(var matrixSlot) = state.style {
                move(&matrixSlot)
                state.style = .colorMatrix(slot: matrixSlot)
            }
            if isReferenced {
                sources.swapAt(index, kept)
                kept += 1
            }
        }
        sources.removeLast(sources.count - kept)
    }

    // A pattern brush's CGPattern, made for each draw from the C++ Pattern: nil for any other brush, or when the pattern has
    // no image.
    private func brushPattern(_ brush: CGRendererBrush) -> CGPattern? {
        guard brush.hasPattern, brush.sourceSlot != 0, case .brush(let source) = sources[Int(brush.sourceSlot) - 1] else {
            return nil
        }
        return CGRendererCreateBrushPattern(source, context)
    }

    // MARK: State

    @_expose(Cxx)
    mutating func setFillPackedColor(_ packed: UInt32, _ brushKind: UInt8) {
        hasDrawn = true
        state.fill = CGRendererBrush(packedColor: packed, kind: brushKind, isColorVisible: packed & 0xFF != 0)
        levelChanges |= CxxStateChange.fillBrush
        if !state.fill.hasPatternOrGradient {
            context.setFillColor(colorCache.color(packed))
        }
    }

    @_expose(Cxx)
    mutating func setFillPlatformColor(
        _ cgColor: borrowing CGColor,
        _ color: CGRendererColorData,
        _ brushKind: UInt8,
        _ isColorVisible: Bool
    ) {
        hasDrawn = true
        let slot = platformColorSlot(copy cgColor, color)
        state.fill = CGRendererBrush(platformColorSlot: slot, kind: brushKind, isColorVisible: isColorVisible)
        levelChanges |= CxxStateChange.fillBrush
        if !state.fill.hasPatternOrGradient {
            context.setFillColor(cgColor)
        }
    }

    @_expose(Cxx)
    mutating func setStrokePackedColor(_ packed: UInt32, _ brushKind: UInt8) {
        hasDrawn = true
        state.stroke = CGRendererBrush(packedColor: packed, kind: brushKind, isColorVisible: packed & 0xFF != 0)
        levelChanges |= CxxStateChange.strokeBrush
        if !state.stroke.hasPatternOrGradient {
            context.setStrokeColor(colorCache.color(packed))
        }
    }

    @_expose(Cxx)
    mutating func setStrokePlatformColor(
        _ cgColor: borrowing CGColor,
        _ color: CGRendererColorData,
        _ brushKind: UInt8,
        _ isColorVisible: Bool
    ) {
        hasDrawn = true
        let slot = platformColorSlot(copy cgColor, color)
        state.stroke = CGRendererBrush(platformColorSlot: slot, kind: brushKind, isColorVisible: isColorVisible)
        levelChanges |= CxxStateChange.strokeBrush
        if !state.stroke.hasPatternOrGradient {
            context.setStrokeColor(cgColor)
        }
    }

    // A gradient (kind 1) or a pattern (kind 2), over the brush's color, as SourceBrush::setGradient() and setPattern() keep it.
    @_expose(Cxx)
    mutating func setFillSource(_ source: borrowing CGRendererBrushSource, _ brushKind: UInt8) {
        hasDrawn = true
        state.fill.kind = brushKind
        state.fill.sourceSlot = sourceSlot(.brush(copy source))
        levelChanges |= CxxStateChange.fillBrush
        noteCxxBrushSource()
    }

    @_expose(Cxx)
    mutating func setStrokeSource(_ source: borrowing CGRendererBrushSource, _ brushKind: UInt8) {
        hasDrawn = true
        state.stroke.kind = brushKind
        state.stroke.sourceSlot = sourceSlot(.brush(copy source))
        levelChanges |= CxxStateChange.strokeBrush
        noteCxxBrushSource()
    }

    private mutating func noteCxxBrushSource() {
        if depth > 0 && !stack[depth - 1].hasCxxLevel {
            levelHasCxxBrushSource = true
        }
    }

    @_expose(Cxx)
    mutating func setFillRule(_ fillRule: UInt8) {
        hasDrawn = true
        state.fillRule = fillRule
        levelChanges |= CxxStateChange.fillRule
    }

    @_expose(Cxx)
    mutating func setStrokeThickness(_ thickness: Float) {
        hasDrawn = true
        state.strokeThickness = thickness
        levelChanges |= CxxStateChange.strokeThickness
        context.setLineWidth(CGFloat(cxxMax(thickness, 0)))
    }

    @_expose(Cxx)
    mutating func setStrokeStyle(_ strokeStyle: UInt8) {
        hasDrawn = true
        state.strokeStyle = strokeStyle
        levelChanges |= CxxStateChange.strokeStyle
    }

    @_expose(Cxx)
    mutating func setCompositeMode(_ compositeOperator: WebCore.CompositeOperator, _ blendMode: WebCore.BlendMode) {
        hasDrawn = true
        state.compositeOperator = compositeOperator
        state.blendMode = blendMode
        levelChanges |= CxxStateChange.compositeMode
        context.setBlendMode(cgBlendMode(compositeOperator, blendMode))
    }

    @_expose(Cxx)
    mutating func clearDropShadow() {
        hasDrawn = true
        state.dropShadow = nil
        levelChanges |= CxxStateChange.dropShadow
        CGContextSetStyle(context, nil)
    }

    @_expose(Cxx)
    mutating func setDropShadow(_ values: CGRendererShadowValues) {
        hasDrawn = true
        let shadow = makeShadow(values, platformColorSlot: 0)
        state.dropShadow = shadow
        levelChanges |= CxxStateChange.dropShadow
        applyShadow(shadow)
    }

    @_expose(Cxx)
    mutating func setDropShadow(_ values: CGRendererShadowValues, _ cgColor: borrowing CGColor, _ color: CGRendererColorData) {
        hasDrawn = true
        let shadow = makeShadow(values, platformColorSlot: platformColorSlot(copy cgColor, color))
        state.dropShadow = shadow
        levelChanges |= CxxStateChange.dropShadow
        applyShadow(shadow)
    }

    @_expose(Cxx)
    mutating func setNoStyle() {
        hasDrawn = true
        state.style = .none
        levelChanges |= CxxStateChange.style
        CGContextSetStyle(context, nil)
    }

    @_expose(Cxx)
    mutating func setDropShadowStyle(_ values: CGRendererShadowValues) {
        hasDrawn = true
        let shadow = makeShadow(values, platformColorSlot: 0)
        state.style = .dropShadow(shadow)
        levelChanges |= CxxStateChange.style
        applyShadow(shadow)
    }

    @_expose(Cxx)
    mutating func setDropShadowStyle(
        _ values: CGRendererShadowValues,
        _ cgColor: borrowing CGColor,
        _ color: CGRendererColorData
    ) {
        hasDrawn = true
        let shadow = makeShadow(values, platformColorSlot: platformColorSlot(copy cgColor, color))
        state.style = .dropShadow(shadow)
        levelChanges |= CxxStateChange.style
        applyShadow(shadow)
    }

    #if HAVE_CGSTYLE_COLORMATRIX_BLUR
    @_expose(Cxx)
    // CG blurs by the width only; GraphicsGaussianBlur's two are the same.
    mutating func setGaussianBlurStyle(_ width: Float, _ height: Float) {
        hasDrawn = true
        state.style = .gaussianBlur(width: width, height: height)
        levelChanges |= CxxStateChange.style
        let blurRadius = scaledBlurRadius(CGFloat(width), userToBaseCTM)
        CGContextSetStyle(context, CGRendererCreateGaussianBlurStyle(blurRadius))
    }

    @_expose(Cxx)
    mutating func setColorMatrixStyle(_ matrix: CGRendererColorMatrix) {
        hasDrawn = true
        state.style = .colorMatrix(slot: sourceSlot(.colorMatrix(matrix)))
        levelChanges |= CxxStateChange.style
        CGContextSetStyle(context, CGRendererCreateColorMatrixStyle(matrix))
    }
    #endif

    private func makeShadow(_ values: CGRendererShadowValues, platformColorSlot: UInt32) -> CGRendererShadow {
        CGRendererShadow(
            width: values.width,
            height: values.height,
            radius: values.radius,
            opacity: values.opacity,
            packedColor: values.packedColor,
            platformColorSlot: platformColorSlot,
            isValid: values.isValid,
            isVisible: values.isVisible,
            isLegacyRadius: values.legacyRadius
        )
    }

    private var userToBaseCTM: CGAffineTransform {
        context.ctm.concatenating(CGContextGetBaseCTM(context).inverted())
    }

    // Extreme blur values can make text drawing crash or take very long, so they are clamped.
    private func scaledBlurRadius(_ blurRadius: CGFloat, _ userToBaseCTM: CGAffineTransform) -> CGFloat {
        var radius = blurRadius
        if !state.shadowsIgnoreTransforms {
            radius *= smallestSingularValue(userToBaseCTM)
        }
        return 1000 < radius ? 1000 : radius
    }

    private func smallestSingularValue(_ t: CGAffineTransform) -> CGFloat {
        let a = t.a * t.a + t.b * t.b
        let b = t.a * t.c + t.b * t.d
        let d = t.c * t.c + t.d * t.d
        let discriminant = -(4 * b * b + (a - d) * (a - d)).squareRoot()
        return (0.5 * ((a + d) + discriminant)).squareRoot()
    }

    // GraphicsContextCG::setCGDropShadow(), with the CTM at the time the shadow is set.
    private mutating func applyShadow(_ shadow: CGRendererShadow) {
        if !shadow.isValid || (shadow.hasZeroOffset && shadow.radius == 0) {
            CGContextSetStyle(context, nil)
            return
        }
        let userToBaseCTM = self.userToBaseCTM
        let width = CGFloat(shadow.width)
        let height = CGFloat(shadow.height)
        var offset = CGSize(width: width, height: height)
        if !state.shadowsIgnoreTransforms {
            // Not CGSize.applying(_:): the importer compiles CG's inline version with FMA contraction.
            offset = CGSize(
                width: userToBaseCTM.a * width + userToBaseCTM.c * height,
                height: userToBaseCTM.b * width + userToBaseCTM.d * height
            )
        }
        let blurRadius = scaledBlurRadius(CGFloat(shadow.radius), userToBaseCTM)
        // The opacity is the shadow color's: as the context alpha it would override the alpha of the drawing.
        let color: CGColor
        if shadow.platformColorSlot == 0 {
            // Color::colorWithAlphaMultipliedBy() of a packed color.
            let alpha = shadow.opacity * (Float(shadow.packedColor & 0xFF) / 255)
            let alphaByte = UInt32(min(max((alpha * 255).rounded(.toNearestOrAwayFromZero), 0), 255))
            color = colorCache.color((shadow.packedColor & 0xFFFF_FF00) | alphaByte)
        } else {
            let platformColor = platformColors[Int(shadow.platformColorSlot) - 1]
            color = platformColor.copy(alpha: CGFloat(Float(platformColor.alpha) * shadow.opacity)) ?? platformColor
        }
        CGContextSetStyle(context, CGStyleCreateShadow2(offset, blurRadius, color))
    }

    @_expose(Cxx)
    mutating func setAlpha(_ alpha: Float) {
        hasDrawn = true
        state.alpha = alpha
        levelChanges |= CxxStateChange.alpha
        context.setAlpha(CGFloat(alpha))
    }

    @_expose(Cxx)
    mutating func setTextDrawingMode(_ mode: UInt8) {
        hasDrawn = true
        state.textDrawingMode = mode
        levelChanges |= CxxStateChange.textDrawingMode
        context.setTextDrawingMode(cgTextDrawingMode(mode))
    }

    @_expose(Cxx)
    mutating func setImageInterpolationQuality(_ quality: WebCore.InterpolationQuality) {
        hasDrawn = true
        state.imageInterpolationQuality = quality
        levelChanges |= CxxStateChange.imageInterpolationQuality
        context.interpolationQuality = cgInterpolationQuality(quality)
    }

    @_expose(Cxx)
    mutating func setShouldAntialias(_ shouldAntialias: Bool) {
        hasDrawn = true
        state.shouldAntialias = shouldAntialias
        levelChanges |= CxxStateChange.shouldAntialias
        context.setShouldAntialias(shouldAntialias)
    }

    @_expose(Cxx)
    mutating func setShouldSmoothFonts(_ shouldSmoothFonts: Bool) {
        hasDrawn = true
        state.shouldSmoothFonts = shouldSmoothFonts
        levelChanges |= CxxStateChange.shouldSmoothFonts
        context.setShouldSmoothFonts(shouldSmoothFonts)
    }

    @_expose(Cxx)
    mutating func setShouldSubpixelQuantizeFonts(_ shouldSubpixelQuantizeFonts: Bool) {
        hasDrawn = true
        state.shouldSubpixelQuantizeFonts = shouldSubpixelQuantizeFonts
        levelChanges |= CxxStateChange.shouldSubpixelQuantizeFonts
    }

    @_expose(Cxx)
    mutating func setShadowsIgnoreTransforms(_ shadowsIgnoreTransforms: Bool) {
        hasDrawn = true
        state.shadowsIgnoreTransforms = shadowsIgnoreTransforms
        levelChanges |= CxxStateChange.shadowsIgnoreTransforms
    }

    @_expose(Cxx)
    mutating func consumeHasDrawn() -> Bool {
        let result = hasDrawn
        hasDrawn = false
        return result
    }

    // MARK: Snapshot

    // The state as plain values, for GraphicsContextCG to rebuild GraphicsContext's from after this renderer was used without
    // it. Colors that aren't sRGBA8, gradients, patterns and color matrices are by slot, for the functions below.
    @_expose(Cxx)
    func snapshotState(_ snapshot: inout CGRendererStateSnapshot) {
        snapshot.fill = brushSnapshot(state.fill)
        snapshot.stroke = brushSnapshot(state.stroke)
        snapshot.hasDropShadow = state.dropShadow != nil
        if let shadow = state.dropShadow {
            snapshot.dropShadow = shadowSnapshot(shadow)
        }
        switch state.style {
        case .none:
            snapshot.style = 0
        case .dropShadow(let shadow):
            snapshot.style = 1
            snapshot.styleDropShadow = shadowSnapshot(shadow)
        case .gaussianBlur(let width, let height):
            snapshot.style = 2
            snapshot.gaussianBlurWidth = width
            snapshot.gaussianBlurHeight = height
        case .colorMatrix(let slot):
            snapshot.style = 3
            snapshot.colorMatrixSlot = slot
        }
        snapshot.fillRule = state.fillRule
        snapshot.strokeThickness = state.strokeThickness
        snapshot.strokeStyle = state.strokeStyle
        snapshot.compositeOperator = state.compositeOperator.rawValue
        snapshot.blendMode = state.blendMode.rawValue
        snapshot.alpha = state.alpha
        snapshot.textDrawingMode = state.textDrawingMode
        snapshot.imageInterpolationQuality = state.imageInterpolationQuality.rawValue
        snapshot.shouldAntialias = state.shouldAntialias
        snapshot.shouldSmoothFonts = state.shouldSmoothFonts
        snapshot.shouldSubpixelQuantizeFonts = state.shouldSubpixelQuantizeFonts
        snapshot.shadowsIgnoreTransforms = state.shadowsIgnoreTransforms
        snapshot.hasMaxEDRHeadroom = maxEDRHeadroom != nil
        snapshot.maxEDRHeadroom = maxEDRHeadroom ?? 0
    }

    private func brushSnapshot(_ brush: CGRendererBrush) -> CGRendererBrushSnapshot {
        CGRendererBrushSnapshot(
            packedColor: brush.packedColor,
            platformColorSlot: brush.platformColorSlot,
            sourceSlot: brush.sourceSlot,
            kind: brush.kind
        )
    }

    private func shadowSnapshot(_ shadow: CGRendererShadow) -> CGRendererShadowSnapshot {
        CGRendererShadowSnapshot(
            values: CGRendererShadowValues(
                width: shadow.width,
                height: shadow.height,
                radius: shadow.radius,
                opacity: shadow.opacity,
                packedColor: shadow.packedColor,
                isValid: shadow.isValid,
                isVisible: shadow.isVisible,
                legacyRadius: shadow.isLegacyRadius
            ),
            platformColorSlot: shadow.platformColorSlot
        )
    }

    @_expose(Cxx)
    func copyPlatformColor(_ slot: UInt32, _ color: inout CGRendererColorData) {
        color = platformColors[Int(slot) - 1].data
    }

    @_expose(Cxx)
    func copyBrushSource(_ slot: UInt32, _ source: inout CGRendererBrushSource) {
        if case .brush(let brushSource) = sources[Int(slot) - 1] {
            source = brushSource
        }
    }

    #if HAVE_CGSTYLE_COLORMATRIX_BLUR
    @_expose(Cxx)
    func copyColorMatrix(_ slot: UInt32, _ matrix: inout CGRendererColorMatrix) {
        if case .colorMatrix(let colorMatrix) = sources[Int(slot) - 1] {
            matrix = colorMatrix
        }
    }
    #endif

    // BeginPage: the state goes back to its initial value; the stack is left alone.
    @_expose(Cxx)
    mutating func resetState(_ imageInterpolationQuality: WebCore.InterpolationQuality) {
        state = CGRendererState(imageInterpolationQuality: imageInterpolationQuality)
        levelChanges = CxxStateChange.all
        userToDeviceTransformKnownToBeIdentity = false
    }

    // MARK: Lines

    // The CGContext's line attributes, which the state doesn't keep.
    @_expose(Cxx)
    mutating func setLineCap(_ cap: WebCore.LineCap) {
        hasDrawn = true
        switch cap {
        case .Butt: context.setLineCap(.butt)
        case .Round: context.setLineCap(.round)
        case .Square: context.setLineCap(.square)
        @unknown default: break
        }
    }

    @_expose(Cxx)
    mutating func setLineJoin(_ join: WebCore.LineJoin) {
        hasDrawn = true
        switch join {
        case .Miter: context.setLineJoin(.miter)
        case .Round: context.setLineJoin(.round)
        case .Bevel: context.setLineJoin(.bevel)
        @unknown default: break
        }
    }

    @_expose(Cxx)
    mutating func setMiterLimit(_ limit: Float) {
        hasDrawn = true
        context.setMiterLimit(CGFloat(limit))
    }

    @_expose(!Cxx)
    mutating func setLineDash(_ dashes: [CGFloat], _ offset: Float) {
        lineDash = dashes
        applyLineDash(offset)
    }

    // C++ passes the dashes one at a time, then applies them with their offset.
    @_expose(Cxx)
    mutating func clearLineDash() {
        lineDash.removeAll(keepingCapacity: true)
    }

    @_expose(Cxx)
    mutating func appendLineDash(_ length: Double) {
        lineDash.append(CGFloat(length))
    }

    // A negative offset is moved into the first dash cycle.
    @_expose(Cxx)
    mutating func applyLineDash(_ offset: Float) {
        hasDrawn = true
        var offset = offset
        if offset < 0 {
            var length: Float = 0
            for dash in lineDash {
                length += Float(dash)
            }
            // CGContextSetLineDash() repeats odd-length arrays, so the cycle is twice the sum.
            if lineDash.count % 2 != 0 {
                length *= 2
            }
            if length != 0 {
                offset = offset.truncatingRemainder(dividingBy: length) + length
            }
        }
        context.setLineDash(phase: CGFloat(offset), lengths: lineDash)
    }

    // MARK: Stack

    @_expose(Cxx)
    mutating func save(_ isTransparencyLayer: Bool) {
        save(isTransparencyLayer, hasCxxLevel: true)
    }

    private mutating func save(_ isTransparencyLayer: Bool, hasCxxLevel: Bool) {
        let saved = CGRendererSavedState(
            state: state,
            purpose: isTransparencyLayer ? .transparencyLayer : .saveRestore,
            platformColorCount: UInt32(platformColors.count),
            sourceCount: UInt32(sources.count),
            hasCxxLevel: hasCxxLevel,
            levelChanges: levelChanges,
            levelHasCxxBrushSource: levelHasCxxBrushSource
        )
        if depth == stack.count {
            stack.append(saved)
        } else {
            stack[depth] = saved
        }
        depth += 1
        levelChanges = 0
        levelHasCxxBrushSource = false
        if isTransparencyLayer {
            state.resetForTransparencyLayer()
            levelChanges = CxxStateChange.alpha | CxxStateChange.style | CxxStateChange.dropShadow | CxxStateChange.compositeMode
        }
        context.saveGState()
    }

    @_expose(Cxx)
    // A restore pops only a save, and an end only a transparency layer (DEV-1): anything else is ignored, so this state's
    // stack and CG's can't disagree.
    mutating func restore() {
        guard depth > 0, stack[depth - 1].purpose == .saveRestore else {
            return
        }
        pop()
    }

    private mutating func pop() {
        depth -= 1
        // GraphicsContext's state has no level to restore for a level that only a Swift receiver saved, so it may still have
        // what changed in it, unless it changed back.
        if !stack[depth].hasCxxLevel && levelChanges != 0 {
            cxxStaleProperties |= state.cxxChanges(to: stack[depth].state, among: levelChanges)
        }
        levelChanges = stack[depth].levelChanges
        levelHasCxxBrushSource = stack[depth].levelHasCxxBrushSource
        state = stack[depth].state
        let platformColorCount = Int(stack[depth].platformColorCount)
        if platformColors.count > platformColorCount {
            platformColors.removeLast(platformColors.count - platformColorCount)
        }
        let sourceCount = Int(stack[depth].sourceCount)
        if sources.count > sourceCount {
            sources.removeLast(sources.count - sourceCount)
        }
        context.restoreGState()
        userToDeviceTransformKnownToBeIdentity = false
    }

    // The top saved level, for GraphicsContextCG, which may restore it: 0 none; 1 a save or 2 a transparency layer that
    // GraphicsContext's stack has too; 3 a save or 4 a transparency layer that only a Swift receiver made.
    @_expose(Cxx)
    func savedLevelKind() -> UInt8 {
        guard depth > 0 else {
            return 0
        }
        let level = stack[depth - 1]
        let kind: UInt8 = level.purpose == .transparencyLayer ? 2 : 1
        return level.hasCxxLevel ? kind : kind + 2
    }

    @_expose(Cxx)
    func savedLevelCount() -> UInt32 {
        UInt32(depth)
    }

    // Whether GraphicsContext's copy of the state is out of date: whether a Swift receiver has changed a property, or restored
    // a level C++ saved, since the last takeStaleStateForCxx().
    @_expose(Cxx)
    func hasStaleStateForCxx() -> Bool {
        cxxStaleProperties != 0 || pendingCxxRestores != 0
    }

    // The state, with what a Swift receiver has changed since the last call, for GraphicsContextCG to bring GraphicsContext's
    // copy up to date.
    @_expose(Cxx)
    mutating func takeStaleStateForCxx(_ snapshot: inout CGRendererStateSnapshot) {
        guard cxxStaleProperties != 0 || pendingCxxRestores != 0 else {
            snapshot.staleProperties = 0
            snapshot.pendingCxxRestores = 0
            return
        }
        snapshotState(&snapshot)
        snapshot.staleProperties = cxxStaleProperties
        snapshot.pendingCxxRestores = pendingCxxRestores
        cxxStaleProperties = 0
        pendingCxxRestores = 0
    }

    @_expose(Cxx)
    mutating func beginTransparencyLayer(_ opacity: Float) {
        hasDrawn = true
        save(true)
        context.setAlpha(CGFloat(opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        userToDeviceTransformKnownToBeIdentity = false
    }

    // BeginTransparencyLayerWithCompositeMode: CG keeps the current alpha and ignores the composite mode.
    @_expose(Cxx)
    mutating func beginTransparencyLayerWithCurrentAlpha() {
        beginTransparencyLayer(state.alpha)
    }

    @_expose(Cxx)
    mutating func endTransparencyLayer() {
        hasDrawn = true
        guard depth > 0, stack[depth - 1].purpose == .transparencyLayer else {
            return
        }
        context.endTransparencyLayer()
        pop()
    }

    // MARK: Transforms

    @_expose(Cxx)
    mutating func translate(_ x: Float, _ y: Float) {
        hasDrawn = true
        context.translateBy(x: CGFloat(x), y: CGFloat(y))
        userToDeviceTransformKnownToBeIdentity = false
    }

    @_expose(Cxx)
    mutating func scale(_ x: Float, _ y: Float) {
        hasDrawn = true
        context.scaleBy(x: CGFloat(x), y: CGFloat(y))
        userToDeviceTransformKnownToBeIdentity = false
    }

    @_expose(Cxx)
    mutating func rotate(_ angle: Float) {
        hasDrawn = true
        context.rotate(by: CGFloat(angle))
        userToDeviceTransformKnownToBeIdentity = false
    }

    @_expose(Cxx)
    mutating func concatCTM(_ transform: CGAffineTransform) {
        hasDrawn = true
        context.concatenate(transform)
        userToDeviceTransformKnownToBeIdentity = false
    }

    @_expose(Cxx)
    mutating func setCTM(_ transform: CGAffineTransform) {
        hasDrawn = true
        CGContextSetCTM(context, transform)
        userToDeviceTransformKnownToBeIdentity = false
    }

    @_expose(Cxx)
    func ctm(_ includeDeviceScale: Bool) -> CGAffineTransform {
        includeDeviceScale ? context.userSpaceToDeviceSpaceTransform : context.ctm
    }

    @_expose(Cxx)
    func isUserToDeviceTransformKnownToBeIdentity() -> Bool {
        userToDeviceTransformKnownToBeIdentity
    }

    @_expose(Cxx)
    mutating func setUserToDeviceTransformKnownToBeIdentity() {
        userToDeviceTransformKnownToBeIdentity = true
    }

    // MARK: Clips

    @_expose(Cxx)
    mutating func clip(_ rect: CGRect) {
        hasDrawn = true
        context.clip(to: rect)
    }

    @_expose(Cxx)
    mutating func clipOut(_ rect: CGRect) {
        hasDrawn = true
        // CGRectInfinite is much faster than the clip bounding box, but can't be used with an accelerated context whose
        // transform isn't just a translation or a scale (rdar://12584492), or with a printing context (rdar://14634453).
        let ctm = context.ctm
        let canUseCGRectInfinite = !isPDFContext && (isUnaccelerated || (ctm.b == 0 && ctm.c == 0))
        let outer = canUseCGRectInfinite ? CGRect.infinite : context.boundingBoxOfClipPath
        clipOutRects[0] = outer
        clipOutRects[1] = rect
        context.beginPath()
        context.addRects(clipOutRects)
        context.clip(using: .evenOdd)
    }

    @_expose(Cxx)
    mutating func resetClip() {
        hasDrawn = true
        context.resetClip()
    }

    @_expose(Cxx)
    func clipBoundingBox() -> CGRect {
        context.boundingBoxOfClipPath
    }

    // MARK: Drawing

    @_expose(Cxx)
    mutating func clearRect(_ rect: CGRect) {
        hasDrawn = true
        context.clear(rect)
    }

    @_expose(Cxx)
    mutating func fillRect(_ rect: CGRect) -> Bool {
        hasDrawn = true
        if state.fill.hasGradient || canUseShadowBlur {
            return false
        }
        applyPattern(fill: true)
        context.fill(rect)
        return true
    }

    // ApplyFillPattern and ApplyStrokePattern: the pattern brush's CGPattern, for the C++ that then draws with the CGContext.
    @_expose(Cxx)
    mutating func applyFillPattern() {
        if state.fill.hasPattern {
            hasDrawn = true
        }
        applyPattern(fill: true)
    }

    @_expose(Cxx)
    mutating func applyStrokePattern() {
        if state.stroke.hasPattern {
            hasDrawn = true
        }
        applyPattern(fill: false)
    }

    private func applyPattern(fill: Bool) {
        guard let pattern = brushPattern(fill ? state.fill : state.stroke), let patternSpace = CGColorSpace(patternBaseSpace: nil) else {
            return
        }
        if fill {
            context.setFillColorSpace(patternSpace)
            CGRendererSetFillPattern(context, pattern)
        } else {
            context.setStrokeColorSpace(patternSpace)
            CGRendererSetStrokePattern(context, pattern)
        }
    }

    // The caller compares the colors: C++ Color equality includes flags this state doesn't have.
    @_expose(Cxx)
    mutating func fillRect(_ rect: CGRect, packedColor: UInt32, _ changesFillColor: Bool) -> Bool {
        hasDrawn = true
        if canUseShadowBlur {
            return false
        }
        if changesFillColor {
            context.setFillColor(colorCache.color(packedColor))
        }
        context.fill(rect)
        if changesFillColor {
            context.setFillColor(platformColor(state.fill))
        }
        return true
    }

    // GraphicsContextCG::fillRect() with a blurred drop shadow on an unaccelerated context (canUseShadowBlur): ShadowBlur draws
    // the shadow through this renderer, then the rect is filled without one. The caller passes the shadow's Color, which
    // ShadowBlur takes, and whether setting the shadow's color as the fill changes the C++ state.
    @_expose(Cxx)
    mutating func fillRectWithShadowBlur(
        _ rect: CGRect,
        _ shadowColor: borrowing WebCore.Color,
        _ shadowColorChangesFill: Bool
    ) {
        assert(!state.fill.hasGradient && canUseShadowBlur)
        hasDrawn = true
        applyPattern(fill: true)
        context.saveGState()
        CGContextSetStyle(context, nil)
        drawRectShadowBlur(rect, shadowColor, shadowColorChangesFill)
        context.fill(rect)
        context.restoreGState()
    }

    @_expose(Cxx)
    mutating func fillRectWithShadowBlur(
        _ rect: CGRect,
        packedColor: UInt32,
        _ changesFillColor: Bool,
        _ shadowColor: borrowing WebCore.Color,
        _ shadowColorChangesFill: Bool
    ) {
        assert(canUseShadowBlur)
        hasDrawn = true
        if changesFillColor {
            context.setFillColor(colorCache.color(packedColor))
        }
        context.saveGState()
        CGContextSetStyle(context, nil)
        drawRectShadowBlur(rect, shadowColor, shadowColorChangesFill)
        context.fill(rect)
        context.restoreGState()
        if changesFillColor {
            context.setFillColor(platformColor(state.fill))
        }
    }

    // ShadowBlur(GraphicsDropShadow, shadowsIgnoreTransforms).drawRectShadow(context, FloatRoundedRect(rect)).
    private mutating func drawRectShadowBlur(
        _ rect: CGRect,
        _ shadowColor: borrowing WebCore.Color,
        _ shadowColorChangesFill: Bool
    ) {
        guard let shadow = state.dropShadow else {
            return
        }
        var shadowState = shadowBlurState(
            WebCore.ShadowBlurSize(width: shadow.radius, height: shadow.radius),
            WebCore.ShadowBlurSize(width: shadow.width, height: shadow.height),
            shadow.isVisible,
            state.shadowsIgnoreTransforms,
            shadow.isLegacyRadius
        )
        let ctm = context.ctm
        let transform = WebCore.AffineTransform(ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty)
        let clipBox = context.boundingBoxOfClipPath
        let clip = CGRendererIntRect(
            enclosing: CGRendererRect(x: Float(clipBox.origin.x), y: Float(clipBox.origin.y), width: Float(clipBox.size.width), height: Float(clipBox.size.height))
        )
        let shadowedRect = WebCore.ShadowBlurRect(x: Float(rect.origin.x), y: Float(rect.origin.y), width: Float(rect.size.width), height: Float(rect.size.height))
        let fill = CGRendererBrush(packedColor: shadow.packedColor, platformColorSlot: shadow.platformColorSlot, kind: 0, isColorVisible: shadow.isVisible)
        shadowBlurDrawing = CGRendererShadowBlurDrawing(fill: shadowColorChangesFill ? fill : nil)
        shadowBlurDrawRectShadow(
            &shadowState,
            transform,
            WebCore.IntRect(clip.x, clip.y, clip.width, clip.height),
            shadowedRect,
            WebCore.ShadowBlurCornerRadii(),
            shadowColor,
            into: &self
        )
        shadowBlurDrawing = nil
    }

    @_expose(Cxx)
    mutating func fillRect(_ rect: CGRect, platformColor color: borrowing CGColor, _ changesFillColor: Bool) -> Bool {
        hasDrawn = true
        if canUseShadowBlur {
            return false
        }
        if changesFillColor {
            context.setFillColor(copy color)
        }
        context.fill(rect)
        if changesFillColor {
            context.setFillColor(platformColor(state.fill))
        }
        return true
    }

    @_expose(Cxx)
    mutating func strokeRect(_ rect: CGRect, _ lineWidth: Float) -> Bool {
        hasDrawn = true
        if state.stroke.hasGradient {
            return false
        }
        applyPattern(fill: false)
        // CGContextStrokeRect() and CGContextStrokeRectWithWidth() fail to apply some attributes of the graphics state
        // in some cases (https://bugs.webkit.org/show_bug.cgi?id=132948).
        context.setLineWidth(CGFloat(cxxMax(lineWidth, 0)))
        context.addRect(rect)
        context.strokePath()
        context.setLineWidth(CGFloat(cxxMax(state.strokeThickness, 0)))
        return true
    }

    // A filled rect with a border of four filled rects in the stroke color.
    @_expose(Cxx)
    mutating func drawRect(_ rect: CGRect, _ borderThickness: Float, _ changesFillColor: Bool) {
        hasDrawn = true
        context.fill(rect)
        if state.strokeStyle == CGRendererStrokeStyle.noStroke {
            return
        }
        if changesFillColor {
            context.setFillColor(platformColor(state.stroke))
        }
        let x = Float(rect.origin.x)
        let y = Float(rect.origin.y)
        let width = Float(rect.size.width)
        let height = Float(rect.size.height)
        let sideHeight = height - 2 * borderThickness
        rectScratch.removeAll(keepingCapacity: true)
        rectScratch.append(CGRendererRect(x: x, y: y, width: width, height: borderThickness).cgRect)
        rectScratch.append(CGRendererRect(x: x, y: y + height - borderThickness, width: width, height: borderThickness).cgRect)
        rectScratch.append(CGRendererRect(x: x, y: y + borderThickness, width: borderThickness, height: sideHeight).cgRect)
        rectScratch.append(
            CGRendererRect(x: x + width - borderThickness, y: y + borderThickness, width: borderThickness, height: sideHeight).cgRect
        )
        context.fill(rectScratch)
        if changesFillColor {
            context.setFillColor(platformColor(state.fill))
        }
    }

    // A border line, from point 1 to point 2 one stroke thickness to its right (vertical) or straight across. Returns whether
    // it touched the context.
    @_expose(Cxx)
    mutating func drawLine(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        if state.strokeStyle == CGRendererStrokeStyle.noStroke {
            return
        }
        let thickness = state.strokeThickness
        let isVerticalLine = x1 + thickness == x2
        var strokeWidth = isVerticalLine ? y2 - y1 : x2 - x1
        if thickness == 0 || strokeWidth == 0 {
            return
        }
        hasDrawn = true

        let drawsDashedLine =
            state.strokeStyle == CGRendererStrokeStyle.dottedStroke || state.strokeStyle == CGRendererStrokeStyle.dashedStroke
        var cornerWidth: Float = 0
        if drawsDashedLine {
            context.saveGState()
            // The end points are filled, so corners are always painted.
            cornerWidth = dashedLineCornerWidth(strokeWidth)
            context.setFillColor(platformColor(state.stroke))
            if isVerticalLine {
                context.fill(CGRendererRect(x: x1, y: y1, width: thickness, height: cornerWidth).cgRect)
                context.fill(CGRendererRect(x: x1, y: y2 - cornerWidth, width: thickness, height: cornerWidth).cgRect)
            } else {
                context.fill(CGRendererRect(x: x1, y: y1, width: cornerWidth, height: thickness).cgRect)
                context.fill(CGRendererRect(x: x2 - cornerWidth, y: y1, width: cornerWidth, height: thickness).cgRect)
            }
            strokeWidth -= 2 * cornerWidth
            let patternWidth = dashedLinePatternWidth(strokeWidth)
            // The corners cover the line.
            if strokeWidth <= patternWidth + 1 {
                context.restoreGState()
                return
            }
            let patternOffset = dashedLinePatternOffset(patternWidth, strokeWidth)
            dashLengths.removeAll(keepingCapacity: true)
            dashLengths.append(CGFloat(patternWidth))
            dashLengths.append(CGFloat(patternWidth))
            context.setLineDash(phase: CGFloat(patternOffset), lengths: dashLengths)
        }

        // GraphicsContext::centerLineAndCutOffCorners().
        var start = (x: x1, y: y1)
        var end = (x: x2, y: y2)
        if isVerticalLine {
            let centerOffset = (x2 - x1) / 2
            start = (x: x1 + centerOffset, y: y1 + cornerWidth)
            end = (x: x2 - centerOffset, y: y2 - cornerWidth)
        } else {
            let centerOffset = (y2 - y1) / 2
            start = (x: x1 + cornerWidth, y: y1 + centerOffset)
            end = (x: x2 - cornerWidth, y: y2 - centerOffset)
        }

        if state.shouldAntialias {
            #if WTF_PLATFORM_IOS_FAMILY
            // Line patterns don't look good without antialiasing (rdar://5459772).
            context.setShouldAntialias(drawsDashedLine)
            #else
            context.setShouldAntialias(false)
            #endif
        }
        context.beginPath()
        context.move(to: CGPoint(x: CGFloat(start.x), y: CGFloat(start.y)))
        context.addLine(to: CGPoint(x: CGFloat(end.x), y: CGFloat(end.y)))
        context.strokePath()
        if state.shouldAntialias {
            context.setShouldAntialias(true)
        }
        if drawsDashedLine {
            context.restoreGState()
        }
    }

    // GraphicsContext::dashedLineCornerWidthForStrokeWidth().
    private func dashedLineCornerWidth(_ strokeWidth: Float) -> Float {
        let thickness = state.strokeThickness
        return state.strokeStyle == CGRendererStrokeStyle.dottedStroke
            ? thickness : cxxMin(2 * thickness, cxxMax(thickness, strokeWidth / 3))
    }

    // GraphicsContext::dashedLinePatternWidthForStrokeWidth().
    private func dashedLinePatternWidth(_ strokeWidth: Float) -> Float {
        let thickness = state.strokeThickness
        return state.strokeStyle == CGRendererStrokeStyle.dottedStroke
            ? thickness : cxxMin(3 * thickness, cxxMax(thickness, strokeWidth / 3))
    }

    // GraphicsContext::dashedLinePatternOffsetForPatternAndStrokeWidth(): the pattern starts with its empty phase after the
    // corner, and an even number of segments or a remainder moves it so that it's balanced between the corners.
    private func dashedLinePatternOffset(_ patternWidth: Float, _ strokeWidth: Float) -> Float {
        var patternOffset = patternWidth
        let numberOfSegments = cxxIntConversion((strokeWidth / patternWidth).rounded(.down))
        let oddNumberOfSegments = numberOfSegments % 2 != 0
        let remainder = strokeWidth - Float(numberOfSegments) * patternWidth
        if oddNumberOfSegments && remainder != 0 {
            patternOffset -= remainder / 2
        } else if !oddNumberOfSegments {
            if remainder != 0 {
                patternOffset += patternOffset - (patternWidth + remainder) / 2
            } else {
                patternOffset += patternWidth / 2
            }
        }
        return patternOffset
    }

    @_expose(Cxx)
    mutating func fillEllipse(_ rect: CGRect) -> Bool {
        if state.fill.hasPatternOrGradient {
            return false
        }
        hasDrawn = true
        context.fillEllipse(in: rect)
        return true
    }

    @_expose(Cxx)
    mutating func strokeEllipse(_ rect: CGRect) -> Bool {
        if state.stroke.hasPatternOrGradient {
            return false
        }
        hasDrawn = true
        context.strokeEllipse(in: rect)
        return true
    }

    // The rects of drawLinesForText(), in the color GraphicsContext computed for them.
    @_expose(Cxx)
    mutating func fillRectsInPackedColor(_ rects: CGRendererRects, _ packedColor: UInt32, _ changesFillColor: Bool) {
        hasDrawn = true
        if changesFillColor {
            context.setFillColor(colorCache.color(packedColor))
        }
        fillRects(rects)
        if changesFillColor {
            context.setFillColor(platformColor(state.fill))
        }
    }

    @_expose(Cxx)
    mutating func fillRectsInPlatformColor(_ rects: CGRendererRects, _ color: borrowing CGColor, _ changesFillColor: Bool) {
        hasDrawn = true
        if changesFillColor {
            context.setFillColor(color)
        }
        fillRects(rects)
        if changesFillColor {
            context.setFillColor(platformColor(state.fill))
        }
    }

    private mutating func fillRects(_ rects: CGRendererRects) {
        rectScratch.removeAll(keepingCapacity: true)
        for index in 0..<rects.size() {
            rectScratch.append(rects.at(index))
        }
        context.fill(rectScratch)
    }

    // MARK: Paths

    // A path is converted to a CGPath only to be drawn, so the caller asks first whether this renderer draws it: everything
    // but a gradient. Functions, not properties: a Release build (-O -wmo) drops the getters of properties only C++ uses.
    @_expose(Cxx)
    func fillsWithoutGradient() -> Bool {
        !state.fill.hasGradient
    }

    @_expose(Cxx)
    func strokesWithoutGradient() -> Bool {
        !state.stroke.hasGradient
    }

    @_expose(Cxx)
    mutating func fillPath(_ path: borrowing CGPath) {
        hasDrawn = true
        assert(fillsWithoutGradient())
        applyPattern(fill: true)
        CGRendererDrawPath(context, state.fillRule == 1 ? .eoFill : .fill, copy path)
    }

    @_expose(Cxx)
    mutating func strokePath(_ path: borrowing CGPath) {
        hasDrawn = true
        assert(strokesWithoutGradient())
        applyPattern(fill: false)
        CGRendererDrawPath(context, .stroke, copy path)
    }

    // A single-line path or a PathDataLine.
    @_expose(Cxx)
    mutating func strokeLineSegment(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        hasDrawn = true
        assert(strokesWithoutGradient())
        applyPattern(fill: false)
        lineSegment.removeAll(keepingCapacity: true)
        lineSegment.append(CGPoint(x: CGFloat(x1), y: CGFloat(y1)))
        lineSegment.append(CGPoint(x: CGFloat(x2), y: CGFloat(y2)))
        context.strokeLineSegments(between: lineSegment)
    }

    // Whether drawPath() draws anything, when neither brush is a gradient.
    @_expose(Cxx)
    func drawsPath() -> Bool {
        state.fill.isVisible || state.stroke.isVisible || state.strokeStyle != CGRendererStrokeStyle.noStroke
    }

    @_expose(Cxx)
    mutating func drawPath(_ path: borrowing CGPath) {
        hasDrawn = true
        assert(fillsWithoutGradient() && strokesWithoutGradient() && drawsPath())
        applyPattern(fill: true)
        applyPattern(fill: false)
        let evenOdd = state.fillRule == 1
        let mode: CGPathDrawingMode
        if state.fill.isVisible {
            let shouldStroke = state.stroke.isVisible || state.strokeStyle != CGRendererStrokeStyle.noStroke
            mode = shouldStroke ? (evenOdd ? .eoFillStroke : .fillStroke) : (evenOdd ? .eoFill : .fill)
        } else {
            mode = .stroke
        }
        CGRendererDrawPath(context, mode, copy path)
    }

    // FontCascade::drawGlyphs(): a run of glyphs in a font, from an anchor point, with the font smoothing it asks for, a shadow
    // with no blur drawn as glyphs in the shadow color, and synthetic bold as a second, offset run. The state it changes for
    // the glyphs goes back afterwards, as GraphicsContext::updatePlatformContextState() puts it back for the C++.
    @_expose(Cxx)
    mutating func drawGlyphs(
        _ font: borrowing CTFont,
        _ run: CGRendererGlyphRun,
        _ positions: CGRendererGlyphPositions,
        _ facts: CGRendererGlyphDrawFacts,
        _ shadowFillColor: CGColor?,
        _ x: Float,
        _ y: Float
    ) {
        hasDrawn = true
        let font = copy font
        var positions = positions
        let ctm = context.ctm
        var syntheticBoldOffset = facts.syntheticBoldOffset
        if syntheticBoldOffset != 0 && !isIdentityOrTranslationOrFlipped(ctm) {
            // AffineTransform::mapSize(FloatSize(1, 0)), so that a scaled down context doesn't widen the gap between the runs.
            let width = Float(1 * hypot(Double(ctm.a), Double(ctm.b)))
            let height = Float(0 * hypot(Double(ctm.c), Double(ctm.d)))
            let horizontalUnitLength = (width * width + height * height).squareRoot()
            if horizontalUnitLength != 0 {
                syntheticBoldOffset = cxxMin(syntheticBoldOffset, syntheticBoldOffset / horizontalUnitLength)
            }
        }

        var hasSimpleShadow = false
        if let shadow = state.dropShadow, state.textDrawingMode == CGRendererTextDrawingMode.fill, shadow.isValid, shadow.radius == 0,
            !facts.isColorBitmapFont, !state.shadowsIgnoreTransforms || isIdentityOrTranslationOrFlipped(ctm), !facts.isInTransparencyLayer
        {
            hasSimpleShadow = true
        }

        var restoresSmoothing = false
        #if !WTF_PLATFORM_IOS_FAMILY
        let shouldSmoothFonts = facts.smoothingMode != CGRendererFontSmoothing.antialiased && facts.smoothingMode != CGRendererFontSmoothing.none
        if shouldSmoothFonts != state.shouldSmoothFonts {
            restoresSmoothing = true
            context.setShouldSmoothFonts(shouldSmoothFonts)
        }
        #endif
        var restoresAntialiasing = false
        let shouldAntialias = facts.smoothingMode != CGRendererFontSmoothing.none
        if shouldAntialias != state.shouldAntialias {
            restoresAntialiasing = true
            context.setShouldAntialias(shouldAntialias)
        }

        context.textMatrix = facts.textMatrix
        context.setFontSize(CGFloat(facts.fontSize))
        CGContextSetShouldAntialiasFonts(context, true)
        context.setShouldSubpixelPositionFonts(true)

        let isTranslationOrIntegralScale = isIntegral(Float(ctm.a)) && isIntegral(Float(ctm.d)) && ctm.b == 0 && ctm.c == 0
        let isRotated = (ctm.b != 0 || ctm.c != 0) && (ctm.a != 0 || ctm.d != 0)
        context.setShouldSubpixelQuantizeFonts(isTranslationOrIntegralScale || (!isRotated && state.shouldSubpixelQuantizeFonts))

        if hasSimpleShadow, let shadow = state.dropShadow, let shadowFillColor {
            // Simple shadows are drawn here rather than by CG, which would lose subpixel antialiasing.
            let shadowX = x + shadow.width
            let shadowY = y + (state.shadowsIgnoreTransforms ? -shadow.height : shadow.height)
            let originalFillColor = CGContextGetFillColorAsColor(context)
            CGContextSetStyle(context, nil)
            context.setFillColor(shadowFillColor)
            showGlyphs(font, run, &positions, facts, shadowX, shadowY)
            if syntheticBoldOffset != 0 {
                showGlyphs(font, run, &positions, facts, shadowX + syntheticBoldOffset, shadowY)
            }
            if let originalFillColor {
                context.setFillColor(originalFillColor)
            }
        }

        showGlyphs(font, run, &positions, facts, x, y)
        if syntheticBoldOffset != 0 {
            showGlyphs(font, run, &positions, facts, x + syntheticBoldOffset, y)
        }

        // Platform drawing may assume an identity text matrix.
        context.textMatrix = .identity

        // The changes GraphicsContext::updatePlatformContextState() would apply, in GraphicsContextState::Change's order.
        if hasSimpleShadow, let shadow = state.dropShadow {
            applyShadow(shadow)
        }
        if restoresAntialiasing {
            context.setShouldAntialias(state.shouldAntialias)
        }
        if restoresSmoothing {
            context.setShouldSmoothFonts(state.shouldSmoothFonts)
        }
    }

    // RepeatedDrawGlyphs::showGlyphsWithAdvances(): the glyphs' positions in text space, from the anchor and the advances
    // (and, for vertical text, each glyph's translation), then CTFontDrawGlyphs().
    private func showGlyphs(
        _ font: CTFont,
        _ run: CGRendererGlyphRun,
        _ positions: inout CGRendererGlyphPositions,
        _ facts: CGRendererGlyphDrawFacts,
        _ x: Float,
        _ y: Float
    ) {
        let count = run.size()
        if count == 0 {
            return
        }
        let matrix = facts.textMatrix.inverted()
        // CGPointApplyAffineTransform() and CGSizeApplyAffineTransform(), in Swift's arithmetic.
        func apply(_ t: CGAffineTransform, _ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: t.a * px + t.c * py + t.tx, y: t.b * px + t.d * py + t.ty)
        }
        func applyToSize(_ t: CGAffineTransform, _ size: CGSize) -> CGSize {
            CGSize(width: t.a * size.width + t.c * size.height, height: t.b * size.width + t.d * size.height)
        }
        do {
            var output: MutableSpan<CGPoint> = positions.mutableSpan()
            if run.isVertical() {
                var positionX = CGFloat(x)
                var positionY = CGFloat(y + facts.ascentDelta)
                for index in 0..<count {
                    let translation = applyToSize(facts.verticalTranslationMatrix, run.translation(index))
                    output[index] = apply(matrix, positionX + translation.width, positionY + translation.height)
                    let advance = run.advance(index)
                    positionX += advance.width
                    positionY += advance.height
                }
            } else {
                output[0] = apply(matrix, CGFloat(x), CGFloat(y))
                for index in 1..<count {
                    let advance = applyToSize(matrix, run.advance(index - 1))
                    let previous = output[index - 1]
                    output[index] = CGPoint(x: previous.x + advance.width, y: previous.y + advance.height)
                }
            }
        }
        CGRendererDrawGlyphs(font, run, positions, context)
    }

    // MARK: Device scale, headroom and PDF

    // GraphicsContextCG::applyDeviceScaleFactor() after GraphicsContext's scale: the base CTM too, so that CG features that
    // draw in base space (focus rings) use the scale factor.
    @_expose(Cxx)
    mutating func applyDeviceScaleFactorToBaseCTM(_ deviceScaleFactor: Float) {
        hasDrawn = true
        CGContextSetBaseCTM(context, CGContextGetBaseCTM(context).scaledBy(x: CGFloat(deviceScaleFactor), y: CGFloat(deviceScaleFactor)))
    }

    @_expose(Cxx)
    mutating func setMaxEDRHeadroom(_ headroom: Float, _ hasHeadroom: Bool) {
        maxEDRHeadroom = hasHeadroom ? headroom : nil
    }

    // FloatRect(rect) intersected with the clip's bounding box, then mapped to device space, for PDF links and destinations.
    private func pdfDestinationRect(_ rect: CGRect) -> CGRect {
        let clip = context.boundingBoxOfClipPath
        let a = CGRendererRect(x: Float(rect.origin.x), y: Float(rect.origin.y), width: Float(rect.size.width), height: Float(rect.size.height))
        let b = CGRendererRect(x: Float(clip.origin.x), y: Float(clip.origin.y), width: Float(clip.size.width), height: Float(clip.size.height))
        return a.intersection(b).cgRect.applying(context.ctm)
    }

    @_expose(Cxx)
    mutating func setURLForRect(_ url: borrowing CFURL, _ rect: CGRect) {
        hasDrawn = true
        context.setURL(copy url, for: pdfDestinationRect(rect))
    }

    @_expose(Cxx)
    mutating func setDestinationForRect(_ name: borrowing CFString, _ rect: CGRect) {
        hasDrawn = true
        context.setDestination(copy name, for: pdfDestinationRect(rect))
    }

    @_expose(Cxx)
    mutating func addDestinationAtPoint(_ name: borrowing CFString, _ x: Float, _ y: Float) {
        hasDrawn = true
        // CGPointApplyAffineTransform() is inline: its arithmetic in Swift's, without contraction.
        let t = context.ctm
        let px = CGFloat(x)
        let py = CGFloat(y)
        context.addDestination(copy name, at: CGPoint(x: t.a * px + t.c * py + t.tx, y: t.b * px + t.d * py + t.ty))
    }

    // Whether this is a PDF context: beginPage() and endPage() only work in one.
    @_expose(Cxx)
    mutating func beginPDFPage(_ pageRect: CGRect) -> Bool {
        hasDrawn = true
        guard isPDFContext else {
            return false
        }
        CGRendererBeginPDFPage(context, pageRect)
        return true
    }

    @_expose(Cxx)
    mutating func endPDFPage() -> Bool {
        hasDrawn = true
        guard isPDFContext else {
            return false
        }
        context.endPDFPage()
        return true
    }

    // GraphicsContextCG::drawNativeImage() but for a dynamic range limit, which the C++ draws. The headrooms are the image's and
    // the options' (0, Headroom::FromImage, for the image's). Returns 0 if it didn't draw, 1 if it drew, 2 if there was nothing
    // to draw.
    @_expose(Cxx)
    mutating func drawNativeImage(
        _ image: borrowing CGImage,
        _ imageWidth: Float,
        _ imageHeight: Float,
        _ destinationX: Float,
        _ destinationY: Float,
        _ destinationWidth: Float,
        _ destinationHeight: Float,
        _ sourceX: Float,
        _ sourceY: Float,
        _ sourceWidth: Float,
        _ sourceHeight: Float,
        _ compositeOperator: WebCore.CompositeOperator,
        _ blendMode: WebCore.BlendMode,
        _ optionsInterpolationQuality: WebCore.InterpolationQuality,
        _ orientation: UInt8,
        _ imageHeadroom: Float,
        _ optionsHeadroom: Float
    ) -> UInt8 {
        var headroom = optionsHeadroom == 0 ? imageHeadroom : optionsHeadroom
        if let maxEDRHeadroom {
            headroom = cxxMin(headroom, maxEDRHeadroom)
        }
        let usesWidthAsHeight = CGRendererOrientation.usesWidthAsHeight(orientation)
        let logicalWidth = usesWidthAsHeight ? imageHeight : imageWidth
        let logicalHeight = usesWidthAsHeight ? imageWidth : imageHeight
        let imageRect = CGRendererRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
        let normalizedSourceRect = CGRendererRect(x: sourceX, y: sourceY, width: sourceWidth, height: sourceHeight).normalized
        let normalizedDestinationRect = CGRendererRect(x: destinationX, y: destinationY, width: destinationWidth, height: destinationHeight)
            .normalized
        if !imageRect.intersects(normalizedSourceRect) {
            return 2
        }

        let transform = context.ctm
        let oldInterpolationQuality = state.imageInterpolationQuality
        let interpolationQuality = optionsInterpolationQuality == .Default ? state.imageInterpolationQuality : optionsInterpolationQuality

        var subimage: CGImage? = copy image
        var adjustedDestinationRect = normalizedDestinationRect
        var clipsToDestination = false
        if normalizedSourceRect != imageRect {
            let scaleX = normalizedDestinationRect.width / normalizedSourceRect.width
            let scaleY = normalizedDestinationRect.height / normalizedSourceRect.height
            if shouldUseSubimage(interpolationQuality, normalizedDestinationRect, normalizedSourceRect, transform) {
                // A copy of only the source rect, so that high-quality interpolation doesn't bleed pixels from outside it into
                // the destination (rdar://6112909).
                let subimageRect = CGRendererIntRect(enclosing: normalizedSourceRect)
                subimage = self.subimage(copy image, logicalWidth, logicalHeight, subimageRect.rect, orientation)
                let paddingX = normalizedSourceRect.x - Float(subimageRect.x)
                let paddingY = normalizedSourceRect.y - Float(subimageRect.y)
                adjustedDestinationRect = CGRendererRect(
                    x: adjustedDestinationRect.x - paddingX * scaleX,
                    y: adjustedDestinationRect.y - paddingY * scaleY,
                    width: Float(subimageRect.width) * scaleX,
                    height: Float(subimageRect.height) * scaleY
                )
            } else {
                // The whole image, scaled, with a clip to the source rect's part of it.
                adjustedDestinationRect = CGRendererRect(
                    x: adjustedDestinationRect.x - normalizedSourceRect.x * scaleX,
                    y: adjustedDestinationRect.y - normalizedSourceRect.y * scaleY,
                    width: logicalWidth * scaleX,
                    height: logicalHeight * scaleY
                )
            }
            clipsToDestination = !normalizedDestinationRect.contains(adjustedDestinationRect)
        }

        // CGImageCreateWithImageInRect() found no image there: the C++ draws a null image, which CG ignores, and puts the
        // state back.
        guard let subimage else {
            hasDrawn = true
            return 1
        }

        if clipsToDestination {
            context.saveGState()
            context.clip(to: normalizedDestinationRect.cgRect)
        }

        let oldCompositeOperator = state.compositeOperator
        let oldBlendMode = state.blendMode
        context.setBlendMode(cgBlendMode(compositeOperator, blendMode))

        if interpolationQuality != oldInterpolationQuality {
            context.interpolationQuality = cgInterpolationQuality(interpolationQuality)
        }

        let oldHeadroom = CGContextGetEDRTargetHeadroom(context)
        if imageHeadroom > headroom {
            _ = context.setEDRTargetHeadroom(headroom)
        }

        context.translateBy(x: CGFloat(adjustedDestinationRect.x), y: CGFloat(adjustedDestinationRect.y))
        var drawWidth = adjustedDestinationRect.width
        var drawHeight = adjustedDestinationRect.height
        if orientation != CGRendererOrientation.none {
            context.concatenate(CGRendererTransform(fromDefault: orientation, drawWidth, drawHeight).cgAffineTransform)
            // The destination's width and height are the oriented image's, as layout needed them: back to the image's.
            if usesWidthAsHeight {
                swap(&drawWidth, &drawHeight)
            }
        }
        let drawRect = CGRect(x: 0, y: 0, width: CGFloat(drawWidth), height: CGFloat(drawHeight))

        context.translateBy(x: 0, y: drawRect.height)
        context.scaleBy(x: 1, y: -1)

        context.draw(subimage, in: drawRect)

        if clipsToDestination {
            context.restoreGState()
        } else {
            CGContextSetCTM(context, transform)
            context.setBlendMode(cgBlendMode(oldCompositeOperator, oldBlendMode))
            if interpolationQuality != oldInterpolationQuality {
                context.interpolationQuality = cgInterpolationQuality(oldInterpolationQuality)
            }
            _ = context.setEDRTargetHeadroom(oldHeadroom)
        }
        hasDrawn = true
        return 1
    }

    // GraphicsContextCG::drawPattern(): the image's tile, repeated across the destination by the pattern transform (only its
    // scale is used) from the phase, with spacing between tiles. The caller checked that the transform is invertible.
    @_expose(Cxx)
    mutating func drawPattern(
        _ image: borrowing CGImage,
        _ imageWidth: Float,
        _ imageHeight: Float,
        _ destinationX: Float,
        _ destinationY: Float,
        _ destinationWidth: Float,
        _ destinationHeight: Float,
        _ tileX: Float,
        _ tileY: Float,
        _ tileWidth: Float,
        _ tileHeight: Float,
        _ patternA: Double,
        _ patternD: Double,
        _ phaseX: Float,
        _ phaseY: Float,
        _ spacingWidth: Float,
        _ spacingHeight: Float,
        _ compositeOperator: WebCore.CompositeOperator,
        _ blendMode: WebCore.BlendMode,
        _ optionsInterpolationQuality: WebCore.InterpolationQuality
    ) {
        hasDrawn = true
        context.saveGState()
        defer {
            context.restoreGState()
        }
        context.clip(to: CGRendererRect(x: destinationX, y: destinationY, width: destinationWidth, height: destinationHeight).cgRect)
        context.setBlendMode(cgBlendMode(compositeOperator, blendMode))
        let interpolationQuality = optionsInterpolationQuality == .Default ? state.imageInterpolationQuality : optionsInterpolationQuality
        if interpolationQuality != state.imageInterpolationQuality {
            context.interpolationQuality = cgInterpolationQuality(interpolationQuality)
        }

        context.translateBy(x: CGFloat(destinationX), y: CGFloat(destinationY + destinationHeight))
        context.scaleBy(x: 1, y: -1)

        // In these coordinates the destination's bottom left corner is the origin.
        let a = Float(patternA)
        let d = Float(patternD)
        let scaledTileHeight = tileHeight * d
        let adjustedX = phaseX - destinationX + tileX * a
        let adjustedY = destinationHeight - (phaseY - destinationY + tileY * d + scaledTileHeight)

        let width = Float(image.width)
        let height = Float(image.height)
        // Sub-images are only used for border-image, which draws fully decoded images. A tile outside the image is null.
        let tile: CGImage?
        if tileWidth == imageWidth && tileHeight == imageHeight {
            tile = copy image
        } else {
            tile = image.cropping(to: CGRendererRect(x: tileX, y: tileY, width: tileWidth, height: tileHeight).cgRect)
        }

        let scaledTileWidth = tileWidth * a
        if width == imageWidth && height == imageHeight && spacingWidth == 0 && spacingHeight == 0 {
            // CG seems to snap the tiles to integral sizes (FIXME in GraphicsContextCG).
            CGRendererDrawTiledImage(
                context,
                CGRendererRect(x: adjustedX, y: adjustedY, width: scaledTileWidth, height: scaledTileHeight).cgRect,
                tile
            )
            return
        }

        // A partially decoded image or spacing between tiles: a CGPattern, which fills the clip even without a tile. The top of a
        // partially decoded image is drawn at the bottom of the tile, so it moves up.
        let matrix = CGAffineTransform(
            a: CGFloat(patternA),
            b: 0,
            c: 0,
            d: CGFloat(patternD),
            tx: CGFloat(adjustedX),
            ty: CGFloat(adjustedY)
        )
        .concatenating(context.ctm)
        .translatedBy(x: 0, y: CGFloat(imageHeight - height))
        let xStep = tileWidth + spacingWidth * (1 / a)
        let yStep = tileHeight + spacingHeight * (1 / d)
        let tileBounds = CGRect(x: 0, y: 0, width: CGFloat(tileWidth), height: CGFloat(tileHeight))
        guard let pattern = CGRendererCreateImagePattern(tile, tileBounds, matrix, CGFloat(xStep), CGFloat(yStep)),
            let patternSpace = CGColorSpace(patternBaseSpace: nil)
        else {
            return
        }
        let color = CGRendererCreatePatternColor(patternSpace, pattern)
        context.setFillColorSpace(patternSpace)
        CGContextSetBaseCTM(context, .identity)
        context.setPatternPhase(.zero)
        if let color {
            context.setFillColor(color)
        }
        context.fill(context.boundingBoxOfClipPath)
    }

    // Gradient::paint(): a gradient across the clip of `context`, which is this renderer's context or a layer's. The CGGradient
    // (the stops, converted and sampled into an output color space) comes from the C++ Gradient, which caches it.
    @_expose(Cxx)
    static func paintGradient(_ context: borrowing CGContext, _ gradient: borrowing CGGradient, _ geometry: CGRendererGradientGeometry) {
        let context = copy context
        let gradient = copy gradient
        let extendOptions: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch geometry.kind {
        case 0:
            if geometry.spreadMethod == CGRendererSpreadMethod.pad {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: CGFloat(geometry.x0), y: CGFloat(geometry.y0)),
                    end: CGPoint(x: CGFloat(geometry.x1), y: CGFloat(geometry.y1)),
                    options: extendOptions
                )
            } else {
                paintRepeatingLinearGradient(context, gradient, geometry)
            }
        case 1:
            let needsScaling = geometry.aspectRatio != 1
            if needsScaling {
                // Scaled from the center: only non-deprecated gradients, whose two points are the same, have an aspect ratio.
                context.saveGState()
                context.translateBy(x: CGFloat(geometry.x0), y: CGFloat(geometry.y0))
                context.scaleBy(x: 1, y: CGFloat(1 / geometry.aspectRatio))
                context.translateBy(x: CGFloat(-geometry.x0), y: CGFloat(-geometry.y0))
            }
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: CGFloat(geometry.x0), y: CGFloat(geometry.y0)),
                startRadius: CGFloat(geometry.startRadius),
                endCenter: CGPoint(x: CGFloat(geometry.x1), y: CGFloat(geometry.y1)),
                endRadius: CGFloat(geometry.endRadius),
                options: extendOptions
            )
            if needsScaling {
                context.restoreGState()
            }
        default:
            context.saveGState()
            context.translateBy(x: CGFloat(geometry.x0), y: CGFloat(geometry.y0))
            context.rotate(by: -CGFloat(Double.pi / 2))
            context.translateBy(x: CGFloat(-geometry.x0), y: CGFloat(-geometry.y0))
            CGContextDrawConicGradient(
                context,
                gradient,
                CGPoint(x: CGFloat(geometry.x0), y: CGFloat(geometry.y0)),
                CGFloat(geometry.angleRadians)
            )
            context.restoreGState()
        }
    }

    // A repeating or reflecting linear gradient: in coordinates rotated so that the gradient runs along x, copies of it side by
    // side, forwards and backwards from its start, across the clip's bounding box.
    private static func paintRepeatingLinearGradient(_ context: CGContext, _ gradient: CGGradient, _ geometry: CGRendererGradientGeometry) {
        context.saveGState()
        defer {
            context.restoreGState()
        }
        // FloatPoint::normalize().
        var normX = geometry.x1 - geometry.x0
        var normY = geometry.y1 - geometry.y0
        let length = hypot(normX, normY)
        if length != 0 {
            normX /= length
            normY /= length
        }
        let angle: CGFloat = normX == 0 && normY == 0 ? 0 : CGFloat(atan2(normY, normX))
        context.rotate(by: angle)

        let boundingBox = context.boundingBoxOfClipPath
        if boundingBox.isInfinite || boundingBox.isEmpty {
            return
        }

        // CGPointApplyAffineTransform(), in Swift's arithmetic, then narrowed to FloatPoint.
        let rotation = CGAffineTransform(rotationAngle: -angle)
        func rotatedX(_ x: Float, _ y: Float) -> Float {
            Float(rotation.a * CGFloat(x) + rotation.c * CGFloat(y) + rotation.tx)
        }
        let point0X = rotatedX(geometry.x0, geometry.y0)
        let point1X = rotatedX(geometry.x1, geometry.y1)
        var dx = CGFloat(point1X - point0X)

        let pixelSize = abs(context.convertToUserSpace(CGSize(width: 1, height: 1)).width)
        if abs(dx) < pixelSize {
            dx = dx < 0 ? -pixelSize : pixelSize
        }

        let reflects = geometry.spreadMethod == CGRendererSpreadMethod.reflect
        func draw(_ start: CGFloat, _ end: CGFloat, _ flip: Bool) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: flip ? end : start, y: 0),
                end: CGPoint(x: flip ? start : end, y: 0),
                options: []
            )
        }
        func isLeftOf(_ start: CGFloat, _ end: CGFloat) -> Bool {
            cxxMax(start, end) <= boundingBox.minX
        }
        func isRightOf(_ start: CGFloat, _ end: CGFloat) -> Bool {
            cxxMin(start, end) >= boundingBox.maxX
        }
        func isIntersecting(_ start: CGFloat, _ end: CGFloat) -> Bool {
            cxxMin(start, end) < boundingBox.maxX && boundingBox.minX < cxxMax(start, end)
        }

        var flip = false
        var start = CGFloat(point0X)
        // Forwards to the bounding box, then across it.
        if (dx > 0 && isLeftOf(start, start + dx)) || (dx < 0 && isRightOf(start, start + dx)) {
            while !isIntersecting(start, start + dx) {
                flip = !flip && reflects
                start += dx
            }
        }
        while isIntersecting(start, start + dx) {
            draw(start, start + dx, flip)
            flip = !flip && reflects
            start += dx
        }

        flip = reflects
        var end = CGFloat(point0X)
        // Backwards to the bounding box, then across it.
        if (dx < 0 && isLeftOf(end, end - dx)) || (dx > 0 && isRightOf(end, end - dx)) {
            while !isIntersecting(end, end - dx) {
                flip = !flip && reflects
                end -= dx
            }
        }
        while isIntersecting(end, end - dx) {
            draw(end - dx, end, flip)
            flip = !flip && reflects
            end -= dx
        }
    }

    // The sub-image for a rect in the oriented image's coordinates.
    private func subimage(
        _ image: CGImage,
        _ logicalWidth: Float,
        _ logicalHeight: Float,
        _ rect: CGRendererRect,
        _ orientation: UInt8
    )
        -> CGImage?
    {
        var physicalRect = rect
        if orientation != CGRendererOrientation.none,
            let transform = CGRendererTransform(fromDefault: orientation, logicalWidth, logicalHeight).inverse()
        {
            physicalRect = transform.mapRect(rect)
        }
        return CGRendererCopySubimage(image, physicalRect.cgRect)
    }

    private func shouldUseSubimage(
        _ interpolationQuality: WebCore.InterpolationQuality,
        _ destinationRect: CGRendererRect,
        _ sourceRect: CGRendererRect,
        _ transform: CGAffineTransform
    ) -> Bool {
        if interpolationQuality == .DoNotInterpolate {
            return false
        }
        if transform.b != 0 || transform.c != 0 {
            return true
        }
        let xScale = Double(destinationRect.width) * hypot(Double(transform.a), Double(transform.b)) / Double(sourceRect.width)
        let yScale = Double(destinationRect.height) * hypot(Double(transform.c), Double(transform.d)) / Double(sourceRect.height)
        return !areEssentiallyEqual(xScale, yScale) || xScale > 1
    }
}

// MARK: A Swift receiver's messages
// GraphicsContextState::Change's bits, for the properties a Swift receiver changes in the renderer alone.
private enum CxxStateChange {
    static let fillBrush: UInt32 = 1 << 0
    static let fillRule: UInt32 = 1 << 1
    static let strokeBrush: UInt32 = 1 << 2
    static let strokeThickness: UInt32 = 1 << 3
    static let strokeStyle: UInt32 = 1 << 4
    static let compositeMode: UInt32 = 1 << 5
    static let dropShadow: UInt32 = 1 << 6
    static let style: UInt32 = 1 << 7
    static let alpha: UInt32 = 1 << 8
    static let textDrawingMode: UInt32 = 1 << 9
    static let imageInterpolationQuality: UInt32 = 1 << 10
    static let shouldAntialias: UInt32 = 1 << 11
    static let shouldSmoothFonts: UInt32 = 1 << 12
    static let shouldSubpixelQuantizeFonts: UInt32 = 1 << 13
    static let shadowsIgnoreTransforms: UInt32 = 1 << 14
    static let all: UInt32 = (1 << 15) - 1
}

// For a receiver whose context lends it the renderer in place for each message (GraphicsContextCG::lendSwiftRenderer()).
// They change the renderer's state only: the context brings GraphicsContext's own copy up to date when C++ next reads it.
// A save is the renderer's alone; a restore of a level that C++ saved leaves the context to restore GraphicsContext's level
// too. A draw returns false where the renderer declines it, for the receiver to hand it back to the context, which draws it
// once the renderer is no longer lent.
extension CGRendererCore {
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSave() {
        save(false, hasCxxLevel: false)
    }

    // Declines the restore of a level in which C++ set a gradient or pattern brush, for GraphicsContextCG::restore(), which lets
    // GraphicsContext's copy of the brush go at once.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveRestore() -> Bool {
        guard depth > 0, stack[depth - 1].purpose == .saveRestore else {
            return true
        }
        if levelHasCxxBrushSource {
            return false
        }
        // GraphicsContext restores a level that C++ saved when it next brings its state up to date, after any C++ setter
        // that comes first has changed that level's copy: so it then takes all of the state.
        if stack[depth - 1].hasCxxLevel {
            pendingCxxRestores += 1
            cxxStaleProperties = CxxStateChange.all
        }
        pop()
        return true
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveTranslate(_ x: Float, _ y: Float) {
        translate(x, y)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveRotate(_ angle: Float) {
        rotate(angle)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveScale(_ x: Float, _ y: Float) {
        scale(x, y)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetCTM(_ transform: CGAffineTransform) {
        setCTM(transform)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveConcatCTM(_ transform: CGAffineTransform) {
        concatCTM(transform)
    }

    // A color brush replaces a gradient or a pattern.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetFillPackedColor(_ packed: UInt32) {
        cxxStaleProperties |= CxxStateChange.fillBrush
        setFillPackedColor(packed, 0)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetStrokePackedColor(_ packed: UInt32) {
        cxxStaleProperties |= CxxStateChange.strokeBrush
        setStrokePackedColor(packed, 0)
    }

    // A color that the receiver's C++ converted, with its CGColor unless it is packed.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetFillColor(_ color: CGRendererColorValue, _ cgColor: CGColor?) {
        cxxStaleProperties |= CxxStateChange.fillBrush
        if let cgColor {
            setFillPlatformColor(cgColor, color.data, 0, color.isVisible)
        } else {
            setFillPackedColor(color.packedColor, 0)
        }
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetStrokeColor(_ color: CGRendererColorValue, _ cgColor: CGColor?) {
        cxxStaleProperties |= CxxStateChange.strokeBrush
        if let cgColor {
            setStrokePlatformColor(cgColor, color.data, 0, color.isVisible)
        } else {
            setStrokePackedColor(color.packedColor, 0)
        }
    }

    // GraphicsContextCG::clipToNativeImage() of an image that the receiver found.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveClipToNativeImage(_ image: CGImage, _ rect: CGRect) {
        clipToImage(image, CGRendererRect(x: Float(rect.origin.x), y: Float(rect.origin.y), width: Float(rect.size.width), height: Float(rect.size.height)))
        hasDrawn = true
    }

    // GraphicsContextCG::fillRect(_:_:) of a color: false for a blurred shadow, which the context draws.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveFillRect(_ rect: CGRect, _ color: CGRendererColorValue, _ cgColor: CGColor?) -> Bool {
        let changesFillColor = !fillColorEquals(color)
        if let cgColor {
            return fillRect(rect, platformColor: cgColor, changesFillColor)
        }
        return fillRect(rect, packedColor: color.packedColor, changesFillColor)
    }

    // GraphicsContext::fillRect(_:_:_:_:): the fill in the composite mode, which is set back after it.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveFillRect(
        _ rect: CGRect,
        _ color: CGRendererColorValue,
        _ cgColor: CGColor?,
        _ compositeOperator: WebCore.CompositeOperator,
        _ blendMode: WebCore.BlendMode
    ) -> Bool {
        let previousOperator = state.compositeOperator
        let previousBlendMode = state.blendMode
        let changesCompositeMode = previousOperator != compositeOperator || previousBlendMode != blendMode
        guard changesCompositeMode else {
            return receiveFillRect(rect, color, cgColor)
        }
        // The composite mode is as it was after the fill, so C++'s copy of it is as current as it was.
        let cxxCompositeModeIsStale = cxxStaleProperties & CxxStateChange.compositeMode
        setCompositeMode(compositeOperator, blendMode)
        let drawn = receiveFillRect(rect, color, cgColor)
        setCompositeMode(previousOperator, previousBlendMode)
        cxxStaleProperties |= cxxCompositeModeIsStale
        return drawn
    }

    // A shadow that the receiver's C++ converted, with the CGColor of a valid color that isn't packed.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetDropShadow(_ values: CGRendererShadowValues, _ cgColor: CGColor?, _ color: CGRendererColorData) {
        guard !shadowEquals(state.dropShadow, values, color, cgColor != nil) else {
            return
        }
        cxxStaleProperties |= CxxStateChange.dropShadow
        if let cgColor {
            setDropShadow(values, cgColor, color)
        } else {
            setDropShadow(values)
        }
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveClearDropShadow() {
        guard state.dropShadow != nil else {
            return
        }
        cxxStaleProperties |= CxxStateChange.dropShadow
        clearDropShadow()
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetDropShadowStyle(_ values: CGRendererShadowValues, _ cgColor: CGColor?, _ color: CGRendererColorData) {
        if case .dropShadow(let shadow) = state.style, shadowEquals(shadow, values, color, cgColor != nil) {
            return
        }
        cxxStaleProperties |= CxxStateChange.style
        if let cgColor {
            setDropShadowStyle(values, cgColor, color)
        } else {
            setDropShadowStyle(values)
        }
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetNoStyle() {
        if case .none = state.style {
            return
        }
        cxxStaleProperties |= CxxStateChange.style
        setNoStyle()
    }

    #if HAVE_CGSTYLE_COLORMATRIX_BLUR
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetGaussianBlurStyle(_ width: Float, _ height: Float) {
        if case .gaussianBlur(let currentWidth, let currentHeight) = state.style, currentWidth == width, currentHeight == height {
            return
        }
        cxxStaleProperties |= CxxStateChange.style
        setGaussianBlurStyle(width, height)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetColorMatrixStyle(_ matrix: CGRendererColorMatrix) {
        if case .colorMatrix(let slot) = state.style {
            var current = CGRendererColorMatrix()
            copyColorMatrix(slot, &current)
            if CGRendererColorMatricesAreEqual(current, matrix) {
                return
            }
        }
        cxxStaleProperties |= CxxStateChange.style
        setColorMatrixStyle(matrix)
    }
    #endif

    // GraphicsContext's setter, after which GraphicsContextCG sets the shadow and the style again, as the flag changes them.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetShadowsIgnoreTransforms(_ shadowsIgnoreTransforms: Bool) {
        guard state.shadowsIgnoreTransforms != shadowsIgnoreTransforms else {
            return
        }
        cxxStaleProperties |= CxxStateChange.shadowsIgnoreTransforms
        setShadowsIgnoreTransforms(shadowsIgnoreTransforms)
        if let shadow = state.dropShadow {
            levelChanges |= CxxStateChange.dropShadow
            applyShadow(shadow)
        }
        switch state.style {
        case .none:
            break
        case .dropShadow(let shadow):
            levelChanges |= CxxStateChange.style
            applyShadow(shadow)
        case .gaussianBlur(let width, let height):
            #if HAVE_CGSTYLE_COLORMATRIX_BLUR
            setGaussianBlurStyle(width, height)
            #endif
        case .colorMatrix(let slot):
            #if HAVE_CGSTYLE_COLORMATRIX_BLUR
            var matrix = CGRendererColorMatrix()
            copyColorMatrix(slot, &matrix)
            setColorMatrixStyle(matrix)
            #endif
        }
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetTextDrawingMode(_ mode: UInt8) {
        guard state.textDrawingMode != mode else {
            return
        }
        cxxStaleProperties |= CxxStateChange.textDrawingMode
        setTextDrawingMode(mode)
    }

    // GraphicsContextCG::setLineDash().
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetLineDash(_ dashes: Span<Double>, _ offset: Float) {
        clearLineDash()
        for index in dashes.indices {
            appendLineDash(dashes[index])
        }
        applyLineDash(offset)
    }

    // GraphicsContextCG::applyDeviceScaleFactor(): GraphicsContext's scale, then the base CTM's.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveApplyDeviceScaleFactor(_ factor: Float) {
        receiveScale(factor, factor)
        applyDeviceScaleFactorToBaseCTM(factor)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetFillRule(_ fillRule: WebCore.WindRule) {
        cxxStaleProperties |= CxxStateChange.fillRule
        let rule: UInt8 = fillRule == .EvenOdd ? 1 : 0
        setFillRule(rule)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetStrokeThickness(_ thickness: Float) {
        // As GraphicsContext's setter, which leaves 0 for -0.
        guard state.strokeThickness != thickness else {
            return
        }
        cxxStaleProperties |= CxxStateChange.strokeThickness
        setStrokeThickness(thickness)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetStrokeStyle(_ strokeStyle: WebCore.StrokeStyle) {
        cxxStaleProperties |= CxxStateChange.strokeStyle
        setStrokeStyle(strokeStyle.rawValue)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetCompositeMode(_ compositeOperator: WebCore.CompositeOperator, _ blendMode: WebCore.BlendMode) {
        cxxStaleProperties |= CxxStateChange.compositeMode
        setCompositeMode(compositeOperator, blendMode)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetAlpha(_ alpha: Float) {
        guard state.alpha != alpha else {
            return
        }
        cxxStaleProperties |= CxxStateChange.alpha
        setAlpha(alpha)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetImageInterpolationQuality(_ quality: WebCore.InterpolationQuality) {
        cxxStaleProperties |= CxxStateChange.imageInterpolationQuality
        setImageInterpolationQuality(quality)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetShouldAntialias(_ shouldAntialias: Bool) {
        cxxStaleProperties |= CxxStateChange.shouldAntialias
        setShouldAntialias(shouldAntialias)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetShouldSmoothFonts(_ shouldSmoothFonts: Bool) {
        cxxStaleProperties |= CxxStateChange.shouldSmoothFonts
        setShouldSmoothFonts(shouldSmoothFonts)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetShouldSubpixelQuantizeFonts(_ shouldSubpixelQuantizeFonts: Bool) {
        cxxStaleProperties |= CxxStateChange.shouldSubpixelQuantizeFonts
        setShouldSubpixelQuantizeFonts(shouldSubpixelQuantizeFonts)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetLineCap(_ cap: WebCore.LineCap) {
        setLineCap(cap)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetLineJoin(_ join: WebCore.LineJoin) {
        setLineJoin(join)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveSetMiterLimit(_ limit: Float) {
        setMiterLimit(limit)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveClip(_ rect: CGRect) {
        clip(rect)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveClipOut(_ rect: CGRect) {
        clipOut(rect)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveResetClip() {
        resetClip()
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveFillRect(_ rect: CGRect) -> Bool {
        fillRect(rect)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveStrokeRect(_ rect: CGRect, _ lineWidth: Float) -> Bool {
        strokeRect(rect, lineWidth)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveClearRect(_ rect: CGRect) {
        clearRect(rect)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawLine(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        drawLine(x1, y1, x2, y2)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveFillEllipse(_ rect: CGRect) -> Bool {
        fillEllipse(rect)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveStrokeEllipse(_ rect: CGRect) -> Bool {
        strokeEllipse(rect)
    }

    // A path of one segment, which GraphicsContextCG::fillPath() fills through its CGPath.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveFillPathSegment(_ segment: CGRendererPathSegment) -> Bool {
        guard fillsWithoutGradient() else {
            return false
        }
        fillPath(CGRendererCreatePath(segment))
        return true
    }

    // GraphicsContextCG::strokePath() and strokeLine(), which stroke a line as a line segment.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveStrokePathSegment(_ segment: CGRendererPathSegment) -> Bool {
        guard strokesWithoutGradient() else {
            return false
        }
        if segment.kind == .DataLine {
            let v = segment.values
            strokeLineSegment(v.0, v.1, v.2, v.3)
        } else {
            strokePath(CGRendererCreatePath(segment))
        }
        return true
    }

    // GraphicsContextCG::drawPath(), which fills and strokes in one draw.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawPathSegment(_ segment: CGRendererPathSegment) -> Bool {
        guard fillsWithoutGradient() && strokesWithoutGradient() else {
            return false
        }
        hasDrawn = true
        if drawsPath() {
            drawPath(CGRendererCreatePath(segment))
        }
        return true
    }

    // GraphicsContextCG::drawEllipse(), which draws the path of the ellipse in the rect.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawEllipse(_ rect: CGRect) -> Bool {
        let values = (Float(rect.origin.x), Float(rect.origin.y), Float(rect.size.width), Float(rect.size.height), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
        return receiveDrawPathSegment(CGRendererPathSegment(values: values, kind: .EllipseInRect, flag: false))
    }

    // GraphicsContextCG::drawRect(), whose border takes the stroke color as the fill's unless the two are the same color.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawRect(_ rect: CGRect, _ borderThickness: Float) {
        drawRect(rect, borderThickness, !fillAndStrokeColorsAreEqual())
    }

    // A path's fill, stroke and draw, as GraphicsContextCG's: a gradient declines, for the context to paint it, before the
    // receiver makes the path's CGPath.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public func receiveFillsWithoutGradient() -> Bool {
        fillsWithoutGradient()
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public func receiveStrokesWithoutGradient() -> Bool {
        strokesWithoutGradient()
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveFillPath(_ path: CGPath) {
        fillPath(path)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveStrokePath(_ path: CGPath) {
        strokePath(path)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawPath(_ path: () -> CGPath) -> Bool {
        guard fillsWithoutGradient() && strokesWithoutGradient() else {
            return false
        }
        hasDrawn = true
        if drawsPath() {
            drawPath(path())
        }
        return true
    }

    // A clip to a path, or out of it, which the receiver's C++ applies to the context as GraphicsContextCG's clipPath() and
    // clipOut(const Path&) do.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveClip(_ clip: (CGContext) -> Void) {
        hasDrawn = true
        clip(context)
    }

    // GraphicsContextCG::drawNativeImage() of the image a receiver found: false where the C++ draws it. An image buffer's image
    // has its source rect scaled by the buffer's resolution scale, as GraphicsContext::drawImageBuffer() scales it.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawNativeImage(
        _ image: CGImage,
        _ facts: CGRendererImageFacts,
        _ destination: CGRect,
        _ source: CGRect,
        _ options: CGRendererImageOptions
    ) -> Bool {
        guard options.rendererDraws else {
            return false
        }
        let scale = facts.resolutionScale
        return drawNativeImage(
            image,
            facts.width,
            facts.height,
            Float(destination.origin.x),
            Float(destination.origin.y),
            Float(destination.size.width),
            Float(destination.size.height),
            Float(source.origin.x) * scale,
            Float(source.origin.y) * scale,
            Float(source.size.width) * scale,
            Float(source.size.height) * scale,
            options.compositeOperator,
            options.blendMode,
            options.interpolationQuality,
            options.orientation,
            facts.headroom,
            options.headroom
        ) != 0
    }

    // GraphicsContextCG::drawPattern() of the image a receiver found, whose tile rect is scaled as receiveDrawNativeImage()'s
    // source rect is.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveDrawPattern(
        _ image: CGImage,
        _ facts: CGRendererImageFacts,
        _ destination: CGRect,
        _ tile: CGRect,
        _ patternA: Double,
        _ patternD: Double,
        _ phase: CGPoint,
        _ spacing: CGSize,
        _ options: CGRendererImageOptions
    ) {
        let scale = facts.resolutionScale
        drawPattern(
            image,
            facts.width,
            facts.height,
            Float(destination.origin.x),
            Float(destination.origin.y),
            Float(destination.size.width),
            Float(destination.size.height),
            Float(tile.origin.x) * scale,
            Float(tile.origin.y) * scale,
            Float(tile.size.width) * scale,
            Float(tile.size.height) * scale,
            patternA,
            patternD,
            Float(phase.x),
            Float(phase.y),
            Float(spacing.width),
            Float(spacing.height),
            options.compositeOperator,
            options.blendMode,
            options.interpolationQuality
        )
    }

    // RemoteGraphicsContext::strokeLinesWithColorAndThickness(): each line in its stroke color and thickness, which are set
    // only where they differ from the line before's.
    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveStrokeLinesWithColorAndThickness(_ lines: Span<WebCore.PathDataLineColorThickness>) {
        var previous = CGRendererLineStroke()
        for index in lines.indices {
            let line = lines[index]
            let start = line.line.start()
            let end = line.line.endPoint()
            strokeLine(start.x(), start.y(), end.x(), end.y(), line.color.value, line.thickness, &previous)
        }
    }

    // A line of receiveStrokeLinesWithColorAndThickness(), after those whose color and thickness are previous.
    private mutating func strokeLine(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ color: UInt32, _ thickness: Float, _ previous: inout CGRendererLineStroke) {
        if previous.color != color {
            receiveSetStrokePackedColor(color)
            previous.color = color
        }
        if previous.thickness != thickness {
            receiveSetStrokeThickness(cxxMax(thickness, 0))
            previous.thickness = thickness
        }
        strokeLineSegment(x1, y1, x2, y2)
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveApplyFillPattern() {
        applyFillPattern()
    }

    @_expose(!Cxx)
    @_spi(WebKitGPU) public mutating func receiveApplyStrokePattern() {
        applyStrokePattern()
    }

    // Testing only: what RemoteCGRenderer's handler does for the message (GraphicsContextCG::applyReceiverMessageForTesting());
    // false where it declines it.
    @_expose(Cxx)
    mutating func applyReceiverMessageForTesting(_ message: CGRendererReceiverTestMessage, _ path: CGPath?, _ image: CGImage?) -> Bool {
        let v = message.values
        let i = message.integers
        let rect = CGRect(x: CGFloat(v.0), y: CGFloat(v.1), width: CGFloat(v.2), height: CGFloat(v.3))
        let transform = CGAffineTransform(a: CGFloat(v.0), b: CGFloat(v.1), c: CGFloat(v.2), d: CGFloat(v.3), tx: CGFloat(v.4), ty: CGFloat(v.5))
        switch message.message {
        case 0: receiveSave()
        case 1: return receiveRestore()
        case 2: receiveTranslate(v.0, v.1)
        case 3: receiveRotate(v.0)
        case 4: receiveScale(v.0, v.1)
        case 5: receiveSetCTM(transform)
        case 6: receiveConcatCTM(transform)
        case 7: receiveSetFillPackedColor(i.0)
        case 8: receiveSetStrokePackedColor(i.0)
        case 9:
            receiveSetStrokePackedColor(i.0)
            receiveSetStrokeThickness(v.0)
        case 10: receiveSetFillRule(i.0 != 0 ? .EvenOdd : .NonZero)
        case 11: receiveSetStrokeThickness(v.0)
        case 12: receiveSetStrokeStyle(WebCore.StrokeStyle(rawValue: UInt8(i.0)) ?? .SolidStroke)
        case 13: receiveSetCompositeMode(WebCore.CompositeOperator(rawValue: UInt8(i.0)) ?? .SourceOver, WebCore.BlendMode(rawValue: UInt8(i.1)) ?? .Normal)
        case 14: receiveSetAlpha(v.0)
        case 15: receiveSetImageInterpolationQuality(WebCore.InterpolationQuality(rawValue: UInt8(i.0)) ?? .Default)
        case 16: receiveSetShouldAntialias(i.0 != 0)
        case 17: receiveSetShouldSmoothFonts(i.0 != 0)
        case 18: receiveSetShouldSubpixelQuantizeFonts(i.0 != 0)
        case 19: receiveSetLineCap(WebCore.LineCap(rawValue: UInt8(i.0)) ?? .Butt)
        case 20: receiveSetLineJoin(WebCore.LineJoin(rawValue: UInt8(i.0)) ?? .Miter)
        case 21: receiveSetMiterLimit(v.0)
        case 22: receiveClip(rect)
        case 23: receiveClipOut(rect)
        case 24: receiveResetClip()
        case 25: receiveDrawLine(v.0, v.1, v.2, v.3)
        case 26: return receiveFillRect(rect)
        case 27: return receiveFillEllipse(rect)
        case 28: return receiveStrokeRect(rect, v.4)
        case 29: return receiveStrokeEllipse(rect)
        case 30: receiveClearRect(rect)
        case 31: receiveApplyStrokePattern()
        case 32: receiveApplyFillPattern()
        case 33: return receiveFillPathSegment(message.segment)
        case 34: return receiveStrokePathSegment(message.segment)
        case 35: return receiveDrawPathSegment(message.segment)
        case 36: receiveDrawRect(rect, v.4)
        case 37:
            // One or two lines (the segment's flag), each four values and a thickness, in the segment's values.
            let s = message.segment.values
            var previous = CGRendererLineStroke()
            strokeLine(s.0, s.1, s.2, s.3, i.0, s.4, &previous)
            if message.segment.flag {
                strokeLine(s.5, s.6, s.7, s.8, i.1, s.9, &previous)
            }
        case 38, 39:
            // A path of several segments' fill or stroke, whose CGPath the caller made.
            guard let path, message.message == 38 ? receiveFillsWithoutGradient() : receiveStrokesWithoutGradient() else {
                return false
            }
            if message.message == 38 {
                receiveFillPath(path)
            } else {
                receiveStrokePath(path)
            }
        case 40:
            guard let path else {
                return false
            }
            return receiveDrawPath { path }
        case 41, 42:
            // An image the caller found, as RemoteCGRenderer's image handlers find one; nil draws nothing.
            guard let image else {
                return true
            }
            let s = message.segment.values
            let destination = CGRect(x: CGFloat(s.0), y: CGFloat(s.1), width: CGFloat(s.2), height: CGFloat(s.3))
            let source = CGRect(x: CGFloat(s.4), y: CGFloat(s.5), width: CGFloat(s.6), height: CGFloat(s.7))
            if message.message == 41 {
                return receiveDrawNativeImage(image, message.imageFacts, destination, source, message.imageOptions)
            }
            receiveDrawPattern(
                image,
                message.imageFacts,
                destination,
                source,
                Double(s.8),
                Double(s.9),
                CGPoint(x: CGFloat(v.0), y: CGFloat(v.1)),
                CGSize(width: CGFloat(v.2), height: CGFloat(v.3)),
                message.imageOptions
            )
        default: break
        }
        return true
    }
}

#endif // ENABLE_WEBCORE_SWIFT && USE_CG
