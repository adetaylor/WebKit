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

#if ENABLE_WEBCORE_SWIFT && USE_CG

// The safe MutableSpan overload Swift synthesizes for CGRendererGlyphPositions's span accessor comes from Cxx. Xcode builds
// don't find it unless this file imports Cxx.
private import Cxx
import CoreGraphics
import CoreText
import WebCore_Internal.CGRendererSPI
import WebCore_Internal.CGRendererSwiftBridge
import WebCore_Internal.GraphicsTypes

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

private func cgColor(packed: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat(Float(UInt8(truncatingIfNeeded: packed >> 24)) / 255),
        green: CGFloat(Float(UInt8(truncatingIfNeeded: packed >> 16)) / 255),
        blue: CGFloat(Float(UInt8(truncatingIfNeeded: packed >> 8)) / 255),
        alpha: CGFloat(Float(UInt8(truncatingIfNeeded: packed)) / 255)
    )
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
    // 0 for packedColor, otherwise 1 + the index of a color that isn't sRGBA8 in CGRenderer.platformColors.
    var platformColorSlot: UInt32 = 0
    // 0 for a color, 1 for a gradient, 2 for a pattern.
    var kind: UInt8 = 0
    var isColorVisible = true

    var hasPatternOrGradient: Bool { kind != 0 }
    var hasGradient: Bool { kind == 1 }

    // SourceBrush::isVisible().
    var isVisible: Bool { hasPatternOrGradient || isColorVisible }
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

    var isBlurred: Bool { isVisible && radius != 0 }

    // FloatSize::isZero().
    var hasZeroOffset: Bool { abs(width) < Float.ulpOfOne && abs(height) < Float.ulpOfOne }
}

private enum CGRendererStyle {
    case none
    case dropShadow(CGRendererShadow)
    case gaussianBlur(radius: Float)
    case colorMatrix
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
// in place and forwards each state change, save, restore and draw. A draw returns false when this renderer doesn't do that
// case yet; GraphicsContextCG then draws it in C++, with the same state.
@_expose(Cxx)
struct CGRenderer {
    private let context: CGContext
    private let isUnaccelerated: Bool
    private let isPDFContext: Bool
    private var state: CGRendererState
    private var stack: [CGRendererSavedState]
    private var depth = 0
    private var platformColors: [CGColor] = []
    private var colorCache = CGRendererColorCache()
    private var clipOutRects = [CGRect.zero, CGRect.zero]
    // Reused, so that only a context's first use of them allocates.
    private var rectScratch: [CGRect] = []
    private var dashLengths: [CGFloat] = []
    private var lineSegment: [CGPoint] = []

    // The C++ destructor of this struct reads its type metadata, whose accessor a Release build (-O -wmo) drops unless Swift
    // uses it (rdar://179098545).
    @used
    private static let cxxTypeMetadata: Any.Type = CGRenderer.self

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
        slot == 0 ? colorCache.color(packed) : platformColors[Int(slot) - 1]
    }

    private mutating func platformColor(_ brush: CGRendererBrush) -> CGColor {
        platformColor(packed: brush.packedColor, slot: brush.platformColorSlot)
    }

    // When nothing is saved, only the current state refers to platformColors, so the others can go.
    private mutating func platformColorSlot(_ color: CGColor) -> UInt32 {
        if depth == 0 && !platformColors.isEmpty {
            var kept: [CGColor] = []
            func keep(_ slot: inout UInt32) {
                if slot != 0 {
                    kept.append(platformColors[Int(slot) - 1])
                    slot = UInt32(kept.count)
                }
            }
            keep(&state.fill.platformColorSlot)
            keep(&state.stroke.platformColorSlot)
            if var shadow = state.dropShadow {
                keep(&shadow.platformColorSlot)
                state.dropShadow = shadow
            }
            if case .dropShadow(var shadow) = state.style {
                keep(&shadow.platformColorSlot)
                state.style = .dropShadow(shadow)
            }
            platformColors = kept
        }
        platformColors.append(color)
        return UInt32(platformColors.count)
    }

    // MARK: State

    @_expose(Cxx)
    mutating func setFillPackedColor(_ packed: UInt32, _ brushKind: UInt8) {
        state.fill = CGRendererBrush(packedColor: packed, kind: brushKind, isColorVisible: packed & 0xFF != 0)
        if !state.fill.hasPatternOrGradient {
            context.setFillColor(colorCache.color(packed))
        }
    }

    @_expose(Cxx)
    mutating func setFillPlatformColor(_ color: borrowing CGColor, _ brushKind: UInt8, _ isColorVisible: Bool) {
        let slot = platformColorSlot(copy color)
        state.fill = CGRendererBrush(platformColorSlot: slot, kind: brushKind, isColorVisible: isColorVisible)
        if !state.fill.hasPatternOrGradient {
            context.setFillColor(color)
        }
    }

    @_expose(Cxx)
    mutating func setStrokePackedColor(_ packed: UInt32, _ brushKind: UInt8) {
        state.stroke = CGRendererBrush(packedColor: packed, kind: brushKind, isColorVisible: packed & 0xFF != 0)
        if !state.stroke.hasPatternOrGradient {
            context.setStrokeColor(colorCache.color(packed))
        }
    }

    @_expose(Cxx)
    mutating func setStrokePlatformColor(_ color: borrowing CGColor, _ brushKind: UInt8, _ isColorVisible: Bool) {
        let slot = platformColorSlot(copy color)
        state.stroke = CGRendererBrush(platformColorSlot: slot, kind: brushKind, isColorVisible: isColorVisible)
        if !state.stroke.hasPatternOrGradient {
            context.setStrokeColor(color)
        }
    }

    @_expose(Cxx)
    mutating func setFillRule(_ fillRule: UInt8) {
        state.fillRule = fillRule
    }

    @_expose(Cxx)
    mutating func setStrokeThickness(_ thickness: Float) {
        state.strokeThickness = thickness
        context.setLineWidth(CGFloat(cxxMax(thickness, 0)))
    }

    @_expose(Cxx)
    mutating func setStrokeStyle(_ strokeStyle: UInt8) {
        state.strokeStyle = strokeStyle
    }

    @_expose(Cxx)
    mutating func setCompositeMode(_ compositeOperator: WebCore.CompositeOperator, _ blendMode: WebCore.BlendMode) {
        state.compositeOperator = compositeOperator
        state.blendMode = blendMode
        context.setBlendMode(cgBlendMode(compositeOperator, blendMode))
    }

    @_expose(Cxx)
    mutating func clearDropShadow() {
        state.dropShadow = nil
        CGContextSetStyle(context, nil)
    }

    @_expose(Cxx)
    mutating func setDropShadow(_ values: CGRendererShadowValues) {
        let shadow = makeShadow(values, platformColorSlot: 0)
        state.dropShadow = shadow
        applyShadow(shadow)
    }

    @_expose(Cxx)
    mutating func setDropShadow(_ values: CGRendererShadowValues, _ color: borrowing CGColor) {
        let shadow = makeShadow(values, platformColorSlot: platformColorSlot(copy color))
        state.dropShadow = shadow
        applyShadow(shadow)
    }

    @_expose(Cxx)
    mutating func setNoStyle() {
        state.style = .none
        CGContextSetStyle(context, nil)
    }

    @_expose(Cxx)
    mutating func setDropShadowStyle(_ values: CGRendererShadowValues) {
        let shadow = makeShadow(values, platformColorSlot: 0)
        state.style = .dropShadow(shadow)
        applyShadow(shadow)
    }

    @_expose(Cxx)
    mutating func setDropShadowStyle(_ values: CGRendererShadowValues, _ color: borrowing CGColor) {
        let shadow = makeShadow(values, platformColorSlot: platformColorSlot(copy color))
        state.style = .dropShadow(shadow)
        applyShadow(shadow)
    }

    #if HAVE_CGSTYLE_COLORMATRIX_BLUR
    @_expose(Cxx)
    mutating func setGaussianBlurStyle(_ radius: Float) {
        state.style = .gaussianBlur(radius: radius)
        let blurRadius = scaledBlurRadius(CGFloat(radius), userToBaseCTM)
        CGContextSetStyle(context, CGRendererCreateGaussianBlurStyle(blurRadius))
    }

    @_expose(Cxx)
    mutating func setColorMatrixStyle(_ matrix: CGRendererColorMatrix) {
        state.style = .colorMatrix
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
            isVisible: values.isVisible
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
        context.setAlpha(CGFloat(shadow.opacity))
        let color = platformColor(packed: shadow.packedColor, slot: shadow.platformColorSlot)
        CGContextSetStyle(context, CGStyleCreateShadow2(offset, blurRadius, color))
    }

    @_expose(Cxx)
    mutating func setAlpha(_ alpha: Float) {
        state.alpha = alpha
        context.setAlpha(CGFloat(alpha))
    }

    @_expose(Cxx)
    mutating func setTextDrawingMode(_ mode: UInt8) {
        state.textDrawingMode = mode
        context.setTextDrawingMode(cgTextDrawingMode(mode))
    }

    @_expose(Cxx)
    mutating func setImageInterpolationQuality(_ quality: WebCore.InterpolationQuality) {
        state.imageInterpolationQuality = quality
        context.interpolationQuality = cgInterpolationQuality(quality)
    }

    @_expose(Cxx)
    mutating func setShouldAntialias(_ shouldAntialias: Bool) {
        state.shouldAntialias = shouldAntialias
        context.setShouldAntialias(shouldAntialias)
    }

    @_expose(Cxx)
    mutating func setShouldSmoothFonts(_ shouldSmoothFonts: Bool) {
        state.shouldSmoothFonts = shouldSmoothFonts
        context.setShouldSmoothFonts(shouldSmoothFonts)
    }

    @_expose(Cxx)
    mutating func setShouldSubpixelQuantizeFonts(_ shouldSubpixelQuantizeFonts: Bool) {
        state.shouldSubpixelQuantizeFonts = shouldSubpixelQuantizeFonts
    }

    @_expose(Cxx)
    mutating func setShadowsIgnoreTransforms(_ shadowsIgnoreTransforms: Bool) {
        state.shadowsIgnoreTransforms = shadowsIgnoreTransforms
    }

    // BeginPage: the state goes back to its initial value; the stack is left alone.
    @_expose(Cxx)
    mutating func resetState(_ imageInterpolationQuality: WebCore.InterpolationQuality) {
        state = CGRendererState(imageInterpolationQuality: imageInterpolationQuality)
    }

    // MARK: Stack

    @_expose(Cxx)
    mutating func save(_ isTransparencyLayer: Bool) {
        let saved = CGRendererSavedState(state: state, purpose: isTransparencyLayer ? .transparencyLayer : .saveRestore)
        if depth == stack.count {
            stack.append(saved)
        } else {
            stack[depth] = saved
        }
        depth += 1
        if isTransparencyLayer {
            state.resetForTransparencyLayer()
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
        state = stack[depth].state
        context.restoreGState()
    }

    @_expose(Cxx)
    mutating func beginTransparencyLayer(_ opacity: Float) {
        save(true)
        context.setAlpha(CGFloat(opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
    }

    // BeginTransparencyLayerWithCompositeMode: CG keeps the current alpha and ignores the composite mode.
    @_expose(Cxx)
    mutating func beginTransparencyLayerWithCurrentAlpha() {
        beginTransparencyLayer(state.alpha)
    }

    @_expose(Cxx)
    mutating func endTransparencyLayer() {
        guard depth > 0, stack[depth - 1].purpose == .transparencyLayer else {
            return
        }
        context.endTransparencyLayer()
        pop()
    }

    // MARK: Transforms

    @_expose(Cxx)
    func translate(_ x: Float, _ y: Float) {
        context.translateBy(x: CGFloat(x), y: CGFloat(y))
    }

    @_expose(Cxx)
    func scale(_ x: Float, _ y: Float) {
        context.scaleBy(x: CGFloat(x), y: CGFloat(y))
    }

    @_expose(Cxx)
    func rotate(_ angle: Float) {
        context.rotate(by: CGFloat(angle))
    }

    @_expose(Cxx)
    func concatCTM(_ transform: CGAffineTransform) {
        context.concatenate(transform)
    }

    @_expose(Cxx)
    func setCTM(_ transform: CGAffineTransform) {
        CGContextSetCTM(context, transform)
    }

    @_expose(Cxx)
    func ctm(_ includeDeviceScale: Bool) -> CGAffineTransform {
        includeDeviceScale ? context.userSpaceToDeviceSpaceTransform : context.ctm
    }

    // MARK: Clips

    @_expose(Cxx)
    func clip(_ rect: CGRect) {
        context.clip(to: rect)
    }

    @_expose(Cxx)
    mutating func clipOut(_ rect: CGRect) {
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
    func resetClip() {
        context.resetClip()
    }

    @_expose(Cxx)
    func clipBoundingBox() -> CGRect {
        context.boundingBoxOfClipPath
    }

    // MARK: Drawing

    @_expose(Cxx)
    func clearRect(_ rect: CGRect) {
        context.clear(rect)
    }

    // A pattern brush's CGPattern comes from the C++ Pattern for each draw, as GraphicsContextCG::applyFillPattern() makes it;
    // it is nil for any other brush, or when the pattern has no image.
    @_expose(Cxx)
    mutating func fillRect(_ rect: CGRect, _ fillPattern: CGPattern?) -> Bool {
        if state.fill.hasGradient || canUseShadowBlur {
            return false
        }
        applyPattern(fillPattern, fill: true)
        context.fill(rect)
        return true
    }

    private func applyPattern(_ pattern: CGPattern?, fill: Bool) {
        guard let pattern, let patternSpace = CGColorSpace(patternBaseSpace: nil) else {
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

    @_expose(Cxx)
    func strokeRect(_ rect: CGRect, _ lineWidth: Float, _ strokePattern: CGPattern?) -> Bool {
        if state.stroke.hasGradient {
            return false
        }
        applyPattern(strokePattern, fill: false)
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
    mutating func drawLine(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) -> Bool {
        if state.strokeStyle == CGRendererStrokeStyle.noStroke {
            return false
        }
        let thickness = state.strokeThickness
        let isVerticalLine = x1 + thickness == x2
        var strokeWidth = isVerticalLine ? y2 - y1 : x2 - x1
        if thickness == 0 || strokeWidth == 0 {
            return false
        }

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
                return true
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
        return true
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
    func fillEllipse(_ rect: CGRect) -> Bool {
        if state.fill.hasPatternOrGradient {
            return false
        }
        context.fillEllipse(in: rect)
        return true
    }

    @_expose(Cxx)
    func strokeEllipse(_ rect: CGRect) -> Bool {
        if state.stroke.hasPatternOrGradient {
            return false
        }
        context.strokeEllipse(in: rect)
        return true
    }

    // The rects of drawLinesForText(), in the color GraphicsContext computed for them.
    @_expose(Cxx)
    mutating func fillRectsInPackedColor(_ rects: CGRendererRects, _ packedColor: UInt32, _ changesFillColor: Bool) {
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
    func fillPath(_ path: borrowing CGPath, _ fillPattern: CGPattern?) {
        assert(fillsWithoutGradient())
        applyPattern(fillPattern, fill: true)
        CGRendererDrawPath(context, state.fillRule == 1 ? .eoFill : .fill, copy path)
    }

    @_expose(Cxx)
    func strokePath(_ path: borrowing CGPath, _ strokePattern: CGPattern?) {
        assert(strokesWithoutGradient())
        applyPattern(strokePattern, fill: false)
        CGRendererDrawPath(context, .stroke, copy path)
    }

    // A single-line path or a PathDataLine.
    @_expose(Cxx)
    mutating func strokeLineSegment(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ strokePattern: CGPattern?) {
        assert(strokesWithoutGradient())
        applyPattern(strokePattern, fill: false)
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
    func drawPath(_ path: borrowing CGPath, _ fillPattern: CGPattern?, _ strokePattern: CGPattern?) {
        assert(fillsWithoutGradient() && strokesWithoutGradient() && drawsPath())
        applyPattern(fillPattern, fill: true)
        applyPattern(strokePattern, fill: false)
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

    // GraphicsContextCG::drawNativeImage() but for a dynamic range limit, which the C++ draws. The caller resolved the options'
    // headroom and the image's. Returns 0 if it didn't draw, 1 if it drew, 2 if there was nothing to draw.
    @_expose(Cxx)
    func drawNativeImage(
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
        _ headroom: Float
    ) -> UInt8 {
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

#endif // ENABLE_WEBCORE_SWIFT && USE_CG
