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

import CoreGraphics
import WebCore_Internal.CGRendererSPI
import WebCore_Internal.GraphicsTypes

// std::max's choice: the first argument unless it is less than the second, so -0 and NaN stay.
private func cxxMax(_ a: Float, _ b: Float) -> Float {
    a < b ? b : a
}

private func cxxMin(_ a: Float, _ b: Float) -> Float {
    b < a ? b : a
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
    var hasPatternOrGradient = false
}

private struct CGRendererState {
    var fill = CGRendererBrush()
    var stroke = CGRendererBrush()
    var fillRule: UInt8 = 0
    var strokeThickness: Float = 0
    var strokeStyle: UInt8 = 1
    var compositeOperator = WebCore.CompositeOperator.SourceOver
    var blendMode = WebCore.BlendMode.Normal
    var hasBlurredDropShadow = false
    var hasStyle = false
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
        hasStyle = false
        hasBlurredDropShadow = false
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

    // The C++ destructor of this struct reads its type metadata, whose accessor a Release build (-O -wmo) drops unless Swift
    // uses it (rdar://179098545).
    @used
    private static let cxxTypeMetadata: Any.Type = CGRenderer.self

    // The context is borrowed.
    @_expose(Cxx)
    init(_ context: borrowing CGContext, _ isUnaccelerated: Bool, _ isPDFContext: Bool, _ imageInterpolationQuality: WebCore.InterpolationQuality) {
        self.context = copy context
        self.isUnaccelerated = isUnaccelerated
        self.isPDFContext = isPDFContext
        self.state = CGRendererState(imageInterpolationQuality: imageInterpolationQuality)
        self.stack = Array(repeating: CGRendererSavedState(state: state, purpose: .saveRestore), count: 8)
    }

    private var canUseShadowBlur: Bool {
        isUnaccelerated && state.hasBlurredDropShadow && !state.shadowsIgnoreTransforms
    }

    private mutating func platformColor(_ brush: CGRendererBrush) -> CGColor {
        brush.platformColorSlot == 0 ? colorCache.color(brush.packedColor) : platformColors[Int(brush.platformColorSlot) - 1]
    }

    // When nothing is saved, only the current brushes refer to platformColors, so the others can go.
    private mutating func platformColorSlot(_ color: CGColor) -> UInt32 {
        if depth == 0 && !platformColors.isEmpty {
            var kept: [CGColor] = []
            for slot in [state.fill.platformColorSlot, state.stroke.platformColorSlot] where slot != 0 {
                kept.append(platformColors[Int(slot) - 1])
            }
            if state.fill.platformColorSlot != 0 {
                state.fill.platformColorSlot = 1
            }
            if state.stroke.platformColorSlot != 0 {
                state.stroke.platformColorSlot = UInt32(kept.count)
            }
            platformColors = kept
        }
        platformColors.append(color)
        return UInt32(platformColors.count)
    }

    // MARK: State

    @_expose(Cxx)
    mutating func setFillPackedColor(_ packed: UInt32, _ hasPatternOrGradient: Bool) {
        state.fill = CGRendererBrush(packedColor: packed, hasPatternOrGradient: hasPatternOrGradient)
        if !hasPatternOrGradient {
            context.setFillColor(colorCache.color(packed))
        }
    }

    @_expose(Cxx)
    mutating func setFillPlatformColor(_ color: borrowing CGColor, _ hasPatternOrGradient: Bool) {
        let slot = platformColorSlot(copy color)
        state.fill = CGRendererBrush(platformColorSlot: slot, hasPatternOrGradient: hasPatternOrGradient)
        if !hasPatternOrGradient {
            context.setFillColor(color)
        }
    }

    @_expose(Cxx)
    mutating func setStrokePackedColor(_ packed: UInt32, _ hasPatternOrGradient: Bool) {
        state.stroke = CGRendererBrush(packedColor: packed, hasPatternOrGradient: hasPatternOrGradient)
        if !hasPatternOrGradient {
            context.setStrokeColor(colorCache.color(packed))
        }
    }

    @_expose(Cxx)
    mutating func setStrokePlatformColor(_ color: borrowing CGColor, _ hasPatternOrGradient: Bool) {
        let slot = platformColorSlot(copy color)
        state.stroke = CGRendererBrush(platformColorSlot: slot, hasPatternOrGradient: hasPatternOrGradient)
        if !hasPatternOrGradient {
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

    // The CG shadow and style are still set by GraphicsContextCG; the renderer only needs to know about them.
    @_expose(Cxx)
    mutating func setDropShadow(_ isBlurred: Bool) {
        state.hasBlurredDropShadow = isBlurred
    }

    @_expose(Cxx)
    mutating func setHasStyle(_ hasStyle: Bool) {
        state.hasStyle = hasStyle
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

    @_expose(Cxx)
    mutating func fillRect(_ rect: CGRect) -> Bool {
        if state.fill.hasPatternOrGradient || canUseShadowBlur {
            return false
        }
        context.fill(rect)
        return true
    }

    @_expose(Cxx)
    mutating func fillRect(_ rect: CGRect, packedColor: UInt32) -> Bool {
        if canUseShadowBlur {
            return false
        }
        let colorChanges = state.fill.platformColorSlot != 0 || state.fill.packedColor != packedColor
        if colorChanges {
            context.setFillColor(colorCache.color(packedColor))
        }
        context.fill(rect)
        if colorChanges {
            context.setFillColor(platformColor(state.fill))
        }
        return true
    }

    @_expose(Cxx)
    func strokeRect(_ rect: CGRect, _ lineWidth: Float) -> Bool {
        if state.stroke.hasPatternOrGradient {
            return false
        }
        // CGContextStrokeRect() and CGContextStrokeRectWithWidth() fail to apply some attributes of the graphics state
        // in some cases (https://bugs.webkit.org/show_bug.cgi?id=132948).
        context.setLineWidth(CGFloat(cxxMax(lineWidth, 0)))
        context.addRect(rect)
        context.strokePath()
        context.setLineWidth(CGFloat(cxxMax(state.strokeThickness, 0)))
        return true
    }

    // GraphicsContextCG::drawNativeImage() for an image drawn without a sub-image, with no orientation and no dynamic
    // range limit. The caller resolved the options' headroom and the image's. Returns 0 if it didn't draw, 1 if it drew,
    // 2 if there was nothing to draw.
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
        _ imageHeadroom: Float,
        _ headroom: Float
    ) -> UInt8 {
        let imageRect = CGRendererRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let normalizedSourceRect = CGRendererRect(x: sourceX, y: sourceY, width: sourceWidth, height: sourceHeight).normalized
        let normalizedDestinationRect = CGRendererRect(x: destinationX, y: destinationY, width: destinationWidth, height: destinationHeight).normalized
        if !imageRect.intersects(normalizedSourceRect) {
            return 2
        }

        let transform = context.ctm
        let oldInterpolationQuality = state.imageInterpolationQuality
        let interpolationQuality = optionsInterpolationQuality == .Default ? state.imageInterpolationQuality : optionsInterpolationQuality

        var adjustedDestinationRect = normalizedDestinationRect
        var clipsToDestination = false
        if normalizedSourceRect != imageRect {
            let scaleX = normalizedDestinationRect.width / normalizedSourceRect.width
            let scaleY = normalizedDestinationRect.height / normalizedSourceRect.height
            if shouldUseSubimage(interpolationQuality, normalizedDestinationRect, normalizedSourceRect, transform) {
                return 0
            }
            adjustedDestinationRect = CGRendererRect(
                x: adjustedDestinationRect.x - normalizedSourceRect.x * scaleX,
                y: adjustedDestinationRect.y - normalizedSourceRect.y * scaleY,
                width: imageWidth * scaleX,
                height: imageHeight * scaleY
            )
            clipsToDestination = !normalizedDestinationRect.contains(adjustedDestinationRect)
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
        let drawRect = CGRect(x: 0, y: 0, width: CGFloat(adjustedDestinationRect.width), height: CGFloat(adjustedDestinationRect.height))

        context.translateBy(x: 0, y: drawRect.height)
        context.scaleBy(x: 1, y: -1)

        context.draw(copy image, in: drawRect)

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
