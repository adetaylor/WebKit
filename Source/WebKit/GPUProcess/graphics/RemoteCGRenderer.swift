// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
// Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebKit_Internal

private func cgRect(_ rect: WebCore.FloatRect) -> CGRect {
    CGRect(x: CGFloat(rect.x()), y: CGFloat(rect.y()), width: CGFloat(rect.width()), height: CGFloat(rect.height()))
}

private func cgAffineTransform(_ transform: WebCore.AffineTransform) -> CGAffineTransform {
    CGAffineTransform(a: transform.a(), b: transform.b(), c: transform.c(), d: transform.d(), tx: transform.e(), ty: transform.f())
}

// GraphicsContextCG's brush kinds for the renderer (swiftBrushKind()).
private enum RemoteCGRendererBrushKind {
    static let gradient: UInt8 = 1
    static let pattern: UInt8 = 2
}

// The segment of the Path that RemoteGraphicsContext's handler makes of the message's.
private func lineSegment(_ line: WebCore.PathDataLine) -> CGRendererPathSegment {
    let start = line.start()
    let end = line.endPoint()
    return CGRendererPathSegment(values: (start.x(), start.y(), end.x(), end.y(), 0, 0, 0, 0, 0, 0, 0, 0), kind: .DataLine, flag: false)
}

private func arcSegment(_ arc: WebCore.PathArc, _ kind: CGRendererPathSegmentKind) -> CGRendererPathSegment {
    let center = arc.center
    return CGRendererPathSegment(
        values: (center.x(), center.y(), arc.radius, arc.startAngle, arc.endAngle, 0, 0, 0, 0, 0, 0, 0),
        kind: kind,
        flag: arc.direction == .Counterclockwise
    )
}

private func quadCurveSegment(_ curve: WebCore.PathDataQuadCurve) -> CGRendererPathSegment {
    let start = curve.start
    let control = curve.controlPoint
    let end = curve.endPoint
    return CGRendererPathSegment(
        values: (start.x(), start.y(), control.x(), control.y(), end.x(), end.y(), 0, 0, 0, 0, 0, 0),
        kind: .DataQuadCurve,
        flag: false
    )
}

private func bezierCurveSegment(_ curve: WebCore.PathDataBezierCurve) -> CGRendererPathSegment {
    let start = curve.start
    let control1 = curve.controlPoint1
    let control2 = curve.controlPoint2
    let end = curve.endPoint
    return CGRendererPathSegment(
        values: (start.x(), start.y(), control1.x(), control1.y(), control2.x(), control2.y(), end.x(), end.y(), 0, 0, 0, 0),
        kind: .DataBezierCurve,
        flag: false
    )
}

// Receives the RemoteCGRenderer messages of an image buffer's context, on its stream connection's work queue, and draws
// them with the context's Swift CG renderer, as RemoteGraphicsContext and GraphicsContextCG would. The context lends each
// handler its renderer, stored in place, as the handler's state; a draw the renderer declines goes back to the context,
// through RemoteImageBufferGraphicsContext, once the renderer is no longer lent.
@_expose(Cxx)
final class RemoteCGRenderer {
    typealias State = CGRendererCore

    private let resources: WebKit.RemoteCGRendererResources

    @_expose(!Cxx)
    private init(resources: WebKit.RemoteCGRendererResources) {
        self.resources = resources
    }

    // A new receiver, and the forwarder of its messages, which keeps it, as the stream connection the C++ registers the
    // forwarder with keeps the forwarder. Only C++ calls it, so @used keeps it under -O -wmo (rdar://179098545).
    @used
    static func createMessageReceiver(resources: WebKit.RemoteCGRendererResources) -> RefRemoteCGRendererMessageForwarder {
        WebKit.RemoteCGRendererMessageForwarder.create(target: RemoteCGRenderer(resources: resources))
    }

    func save(state: inout CGRendererCore) {
        state.receiveSave()
    }

    func restore(state: inout CGRendererCore) {
        state.receiveRestore()
    }

    func translate(state: inout CGRendererCore, x: Float, y: Float) {
        state.receiveTranslate(x, y)
    }

    func rotate(state: inout CGRendererCore, angle: Float) {
        state.receiveRotate(angle)
    }

    func scale(state: inout CGRendererCore, scale: WebCore.FloatSize) {
        state.receiveScale(scale.width(), scale.height())
    }

    func setCTM(state: inout CGRendererCore, ctm: WebCore.AffineTransform) {
        state.receiveSetCTM(cgAffineTransform(ctm))
    }

    func concatCTM(state: inout CGRendererCore, ctm: WebCore.AffineTransform) {
        state.receiveConcatCTM(ctm)
    }

    func setFillPackedColor(state: inout CGRendererCore, color: UInt32) {
        state.receiveSetFillPackedColor(color)
    }

    func setStrokePackedColor(state: inout CGRendererCore, color: UInt32) {
        state.receiveSetStrokePackedColor(color)
    }

    func setStrokePackedColorAndThickness(state: inout CGRendererCore, color: UInt32, thickness: Float) {
        state.receiveSetStrokePackedColor(color)
        state.receiveSetStrokeThickness(thickness)
    }

    func setFillRule(state: inout CGRendererCore, rule: WebCore.WindRule) {
        state.receiveSetFillRule(rule)
    }

    func setStrokeThickness(state: inout CGRendererCore, thickness: Float) {
        state.receiveSetStrokeThickness(thickness)
    }

    func setStrokeStyle(state: inout CGRendererCore, style: WebCore.StrokeStyle) {
        state.receiveSetStrokeStyle(style)
    }

    func setCompositeMode(state: inout CGRendererCore, mode: WebCore.CompositeMode) {
        state.receiveSetCompositeMode(mode.operation, mode.blendMode)
    }

    func setAlpha(state: inout CGRendererCore, alpha: Float) {
        state.receiveSetAlpha(alpha)
    }

    func setImageInterpolationQuality(state: inout CGRendererCore, quality: WebCore.InterpolationQuality) {
        state.receiveSetImageInterpolationQuality(quality)
    }

    func setShouldAntialias(state: inout CGRendererCore, shouldAntialias: Bool) {
        state.receiveSetShouldAntialias(shouldAntialias)
    }

    func setShouldSmoothFonts(state: inout CGRendererCore, shouldSmooth: Bool) {
        state.receiveSetShouldSmoothFonts(shouldSmooth)
    }

    func setShouldSubpixelQuantizeFonts(state: inout CGRendererCore, shouldQuantize: Bool) {
        state.receiveSetShouldSubpixelQuantizeFonts(shouldQuantize)
    }

    func setLineCap(state: inout CGRendererCore, lineCap: WebCore.LineCap) {
        state.receiveSetLineCap(lineCap)
    }

    func setLineJoin(state: inout CGRendererCore, lineJoin: WebCore.LineJoin) {
        state.receiveSetLineJoin(lineJoin)
    }

    func setMiterLimit(state: inout CGRendererCore, limit: Float) {
        state.receiveSetMiterLimit(limit)
    }

    func clip(state: inout CGRendererCore, rect: WebCore.FloatRect) {
        state.receiveClip(cgRect(rect))
    }

    func clipOut(state: inout CGRendererCore, rect: WebCore.FloatRect) {
        state.receiveClipOut(cgRect(rect))
    }

    func resetClip(state: inout CGRendererCore) {
        state.receiveResetClip()
    }

    func drawLine(state: inout CGRendererCore, point1: WebCore.FloatPoint, point2: WebCore.FloatPoint) {
        state.receiveDrawLine(point1.x(), point1.y(), point2.x(), point2.y())
    }

    func fillRect(state: inout CGRendererCore, rect: WebCore.FloatRect, requiresClipToRect: WebCore.RequiresClipToRect) {
        state.receiveFillRect(cgRect(rect), requiresClipToRect == .Yes)
    }

    func fillEllipse(state: inout CGRendererCore, rect: WebCore.FloatRect) {
        state.receiveFillEllipse(cgRect(rect))
    }

    func strokeRect(state: inout CGRendererCore, rect: WebCore.FloatRect, lineWidth: Float) {
        state.receiveStrokeRect(cgRect(rect), lineWidth)
    }

    func strokeEllipse(state: inout CGRendererCore, rect: WebCore.FloatRect) {
        state.receiveStrokeEllipse(cgRect(rect))
    }

    func clearRect(state: inout CGRendererCore, rect: WebCore.FloatRect) {
        state.receiveClearRect(cgRect(rect))
    }

    func applyStrokePattern(state: inout CGRendererCore) {
        state.receiveApplyStrokePattern()
    }

    func applyFillPattern(state: inout CGRendererCore) {
        state.receiveApplyFillPattern()
    }

    func drawRect(state: inout CGRendererCore, rect: WebCore.FloatRect, borderThickness: Float) {
        state.receiveDrawRect(cgRect(rect), borderThickness)
    }

    func drawEllipse(state: inout CGRendererCore, rect: WebCore.FloatRect) {
        state.receiveDrawEllipse(cgRect(rect))
    }

    func fillLine(state: inout CGRendererCore, line: WebCore.PathDataLine) {
        state.receiveFillPathSegment(lineSegment(line))
    }

    func fillArc(state: inout CGRendererCore, arc: WebCore.PathArc) {
        state.receiveFillPathSegment(arcSegment(arc, .Arc))
    }

    func fillClosedArc(state: inout CGRendererCore, closedArc: WebCore.PathClosedArc) {
        state.receiveFillPathSegment(arcSegment(closedArc.arc, .ClosedArc))
    }

    func fillQuadCurve(state: inout CGRendererCore, curve: WebCore.PathDataQuadCurve) {
        state.receiveFillPathSegment(quadCurveSegment(curve))
    }

    func fillBezierCurve(state: inout CGRendererCore, curve: WebCore.PathDataBezierCurve) {
        state.receiveFillPathSegment(bezierCurveSegment(curve))
    }

    func fillPathSegment(state: inout CGRendererCore, segment: WebKit.RemoteCGRendererPathSegment) {
        state.receiveFillPathSegment(segment.values())
    }

    func strokeLine(state: inout CGRendererCore, line: WebCore.PathDataLine) {
        state.receiveStrokePathSegment(lineSegment(line))
    }

    func strokeLinesWithColorAndThickness(state: inout CGRendererCore, lines: WebKit.RemoteCGRendererLineStrokes) {
        let span: Span<WebCore.PathDataLineColorThickness> = lines.span()
        state.receiveStrokeLinesWithColorAndThickness(span)
    }

    func strokeArc(state: inout CGRendererCore, arc: WebCore.PathArc) {
        state.receiveStrokeArc(arcSegment(arc, .Arc))
    }

    func strokeClosedArc(state: inout CGRendererCore, closedArc: WebCore.PathClosedArc) {
        state.receiveStrokePathSegment(arcSegment(closedArc.arc, .ClosedArc))
    }

    func strokeQuadCurve(state: inout CGRendererCore, curve: WebCore.PathDataQuadCurve) {
        state.receiveStrokePathSegment(quadCurveSegment(curve))
    }

    func strokeBezierCurve(state: inout CGRendererCore, curve: WebCore.PathDataBezierCurve) {
        state.receiveStrokePathSegment(bezierCurveSegment(curve))
    }

    func strokePathSegment(state: inout CGRendererCore, segment: WebKit.RemoteCGRendererPathSegment) {
        state.receiveStrokePathSegment(segment.values())
    }

    // RemoteGraphicsContext's path handlers, and GraphicsContextCG's draws of an empty path, which draw nothing.

    func fillPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) {
        fill(&state, path)
    }

    func strokePath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) {
        if path.isEmpty() {
            return
        }
        stroke(&state, path)
    }

    // GraphicsContextCG::drawPath(): with a gradient, the fill and the stroke one after the other.
    func drawPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) {
        if path.isEmpty() {
            return
        }
        if state.receiveDrawPathWithoutGradient({ WebKit.copyPlatformPath(path) }) {
            return
        }
        // A fill without a gradient draws the CGPath of the path, which C++ makes of the Path in place, so that the stroke's
        // clip then has the CGPath rather than the segments.
        if state.receiveFillsWithoutGradient() {
            let platformPath = WebKit.copyPlatformPath(path)
            state.receiveFillPath(platformPath)
            state.receiveStrokeWithGradient({ context in strokedPlatformPathBounds(context, platformPath) }) { context, thickness in
                clipToStrokedPlatformPath(context, platformPath, thickness)
            }
            return
        }
        fill(&state, path)
        stroke(&state, path)
    }

    func clipPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath, windRule: WebCore.WindRule) {
        state.receiveClip { context in path.clip(context, windRule) }
    }

    func clipOutToPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) {
        state.receiveClip { context in path.clipOut(context) }
    }

    func fillCachedPath(state: inout CGRendererCore, identifier: WebKit.RemotePathImplIdentifier) throws(InvalidMessage) {
        let path = resources.cachedPath(identifier)
        try messageCheck { path.isValid() }
        fill(&state, path)
    }

    func clipCachedPath(state: inout CGRendererCore, identifier: WebKit.RemotePathImplIdentifier, windRule: WebCore.WindRule) throws(InvalidMessage) {
        let path = resources.cachedPath(identifier)
        try messageCheck { path.isValid() }
        state.receiveClip { context in path.clip(context, windRule) }
    }

    // RemoteGraphicsContext's image handlers. A missing image is an invalid message, and an image this process can't read draws
    // nothing.

    func drawNativeImage(
        state: inout CGRendererCore,
        imageIdentifier: WebCore.RenderingResourceIdentifier,
        destRect: WebCore.FloatRect,
        srcRect: WebCore.FloatRect,
        options: WebCore.RasterDrawingOptions
    ) throws(InvalidMessage) {
        var facts = CGRendererImageFacts()
        let image = WebKit.copyNativeImage(resources, imageIdentifier, srcRect, options, &facts)
        try messageCheck { facts.found }
        guard let image else {
            return
        }
        state.receiveDrawNativeImage(image, facts, cgRect(destRect), cgRect(srcRect), CGRendererImageOptionsFor(options))
    }

    // RemoteImageBufferGraphicsContext::drawImageBuffer(): an accelerated image buffer draws into itself from a copy of itself.
    func drawImageBuffer(
        state: inout CGRendererCore,
        imageBufferIdentifier: WebCore.RenderingResourceIdentifier,
        destinationRect: WebCore.FloatRect,
        srcRect: WebCore.FloatRect,
        options: WebCore.RasterDrawingOptions
    ) throws(InvalidMessage) {
        var facts = CGRendererImageFacts()
        let image = WebKit.copyImageBufferImage(resources, imageBufferIdentifier, srcRect, options, true, &facts)
        try messageCheck { facts.found }
        guard let image else {
            return
        }
        state.receiveDrawNativeImage(image, facts, cgRect(destinationRect), cgRect(srcRect), CGRendererImageOptionsFor(options))
        if facts.isSelfCopy {
            resources.releaseSelfCopy()
        }
    }

    func drawPatternNativeImage(
        state: inout CGRendererCore,
        imageIdentifier: WebCore.RenderingResourceIdentifier,
        destRect: WebCore.FloatRect,
        tileRect: WebCore.FloatRect,
        transform: WebCore.AffineTransform,
        phase: WebCore.FloatPoint,
        spacing: WebCore.FloatSize,
        options: WebCore.RasterDrawingOptions
    ) throws(InvalidMessage) {
        var facts = CGRendererImageFacts()
        let image = WebKit.copyNativeImage(resources, imageIdentifier, tileRect, options, &facts)
        try messageCheck { facts.found }
        drawPattern(&state, image, facts, destRect, tileRect, transform, phase, spacing, options)
    }

    // RemoteGraphicsContext's handler, which draws an image buffer's pattern into the buffer itself.
    func drawPatternImageBuffer(
        state: inout CGRendererCore,
        imageIdentifier: WebCore.RenderingResourceIdentifier,
        destRect: WebCore.FloatRect,
        tileRect: WebCore.FloatRect,
        transform: WebCore.AffineTransform,
        phase: WebCore.FloatPoint,
        spacing: WebCore.FloatSize,
        options: WebCore.RasterDrawingOptions
    ) throws(InvalidMessage) {
        var facts = CGRendererImageFacts()
        let image = WebKit.copyImageBufferImage(resources, imageIdentifier, tileRect, options, false, &facts)
        try messageCheck { facts.found }
        drawPattern(&state, image, facts, destRect, tileRect, transform, phase, spacing, options)
    }

    // GraphicsContextCG::drawPattern(), which draws nothing for a transform that isn't invertible.
    private func drawPattern(
        _ state: inout CGRendererCore,
        _ image: CGImage?,
        _ facts: CGRendererImageFacts,
        _ destination: WebCore.FloatRect,
        _ tile: WebCore.FloatRect,
        _ transform: WebCore.AffineTransform,
        _ phase: WebCore.FloatPoint,
        _ spacing: WebCore.FloatSize,
        _ options: WebCore.RasterDrawingOptions
    ) {
        guard transform.isInvertible(), let image else {
            return
        }
        state.receiveDrawPattern(
            image,
            facts,
            cgRect(destination),
            cgRect(tile),
            transform.a(),
            transform.d(),
            CGPoint(x: CGFloat(phase.x()), y: CGFloat(phase.y())),
            CGSize(width: CGFloat(spacing.width()), height: CGFloat(spacing.height())),
            CGRendererImageOptionsFor(options)
        )
    }

    // RemoteGraphicsContext's color, shadow, style and state handlers, with the colors converted for the context as
    // GraphicsContextCG converts its state's.

    func setFillColor(state: inout CGRendererCore, color: CGRendererColorValue) {
        state.receiveSetFillColor(color, nil)
    }

    func setStrokeColor(state: inout CGRendererCore, color: CGRendererColorValue) {
        state.receiveSetStrokeColor(color, nil)
    }

    func setDropShadow(state: inout CGRendererCore, dropShadow: WebKit.RemoteCGRendererShadow) {
        guard dropShadow.hasShadow else {
            state.receiveClearDropShadow()
            return
        }
        state.receiveSetDropShadow(dropShadow.values, dropShadow.color)
    }

    // CGStyle has the blur and the color matrix on every platform the receiver is for.
    func setStyle(state: inout CGRendererCore, style: WebKit.RemoteCGRendererStyle) {
        switch style.kind {
        case .None:
            state.receiveSetNoStyle()
        case .DropShadow:
            state.receiveSetDropShadowStyle(style.dropShadow.values, style.dropShadow.color)
        case .GaussianBlur:
            state.receiveSetGaussianBlurStyle(style.blurWidth, style.blurHeight)
        case .ColorMatrix:
            state.receiveSetColorMatrixStyle(WebKit.colorMatrix(style))
        @unknown default:
            state.receiveSetNoStyle()
        }
    }

    func setTextDrawingMode(state: inout CGRendererCore, mode: WebCore.TextDrawingModeFlags) {
        state.receiveSetTextDrawingMode(WebKit.textDrawingModeValue(mode))
    }

    func setShadowsIgnoreTransforms(state: inout CGRendererCore, shouldIgnore: Bool) {
        state.receiveSetShadowsIgnoreTransforms(shouldIgnore)
    }

    func setLineDash(state: inout CGRendererCore, dashArray: WebKit.RemoteCGRendererLineDash, dashOffset: Float) {
        let dashes: Span<Double> = dashArray.span()
        state.receiveSetLineDash(dashes, dashOffset)
    }

    func fillRectWithColor(state: inout CGRendererCore, rect: WebCore.FloatRect, color: CGRendererColorValue) {
        state.receiveFillRect(cgRect(rect), color, nil)
    }

    func fillCompositedRect(
        state: inout CGRendererCore,
        rect: WebCore.FloatRect,
        color: CGRendererColorValue,
        op: WebCore.CompositeOperator,
        blendMode: WebCore.BlendMode
    ) {
        state.receiveFillRect(cgRect(rect), color, nil, op, blendMode)
    }

    func fillRoundedRect(state: inout CGRendererCore, rect: WebCore.FloatRoundedRect, color: CGRendererColorValue, blendMode: WebCore.BlendMode) {
        state.receiveFillRoundedRect(rect, cgRect(WebKit.rectOfRoundedRect(rect)), color, nil, blendMode)
    }

    func fillRectWithRoundedHole(
        state: inout CGRendererCore,
        rect: WebCore.FloatRect,
        roundedHoleRect: WebCore.FloatRoundedRect,
        color: CGRendererColorValue
    ) {
        state.receiveFillRectWithRoundedHole(cgRect(rect), roundedHoleRect, color, nil)
    }

    func applyDeviceScaleFactor(state: inout CGRendererCore, scaleFactor: Float) {
        state.receiveApplyDeviceScaleFactor(scaleFactor)
    }

    // RemoteGraphicsContext's clip handlers. ClipToNativeImage of an image that isn't cached is an invalid message.

    func clipRoundedRect(state: inout CGRendererCore, rect: WebCore.FloatRoundedRect) {
        state.receiveClipToRoundedRect(rect)
    }

    func clipOutRoundedRect(state: inout CGRendererCore, rect: WebCore.FloatRoundedRect) {
        state.receiveClipOutToRoundedRect(rect)
    }

    func clipToNativeImage(state: inout CGRendererCore, imageIdentifier: WebCore.RenderingResourceIdentifier, destinationRect: WebCore.FloatRect) throws(InvalidMessage) {
        let image = WebKit.copyNativeImageForClip(resources, imageIdentifier)
        try messageCheck { image != nil }
        guard let image else {
            return
        }
        state.receiveClipToNativeImage(image, cgRect(destinationRect))
    }

    // RemoteGraphicsContext's transparency layer and link handlers.

    func beginTransparencyLayer(state: inout CGRendererCore, opacity: Float) {
        state.receiveBeginTransparencyLayer(opacity)
    }

    func beginTransparencyLayerWithCompositeMode(state: inout CGRendererCore, compositeMode: WebCore.CompositeMode) {
        state.receiveBeginTransparencyLayerWithCurrentAlpha()
    }

    func endTransparencyLayer(state: inout CGRendererCore) {
        state.receiveEndTransparencyLayer()
    }

    func setURLForRect(state: inout CGRendererCore, link: WTF.URL, destRect: WebCore.FloatRect) {
        guard let url = WebKit.copyURL(link) else {
            return
        }
        state.receiveSetURLForRect(url, cgRect(destRect))
    }

    // GraphicsContextCG::fillPath(): a gradient in the clip of the path's own segments, and a pie wedge as a stroked arc where
    // the context strokes arcs as it fills them.
    private func fill(_ state: inout CGRendererCore, _ path: borrowing WebKit.RemoteCGRendererPath) {
        if path.isEmpty() {
            return
        }
        guard state.receiveFillsWithoutGradient() else {
            let path = copy path
            let bounds = cgRect(path.fastBoundingRect())
            state.receiveFillWithGradient({ bounds }) { context, rule in path.clip(context, rule) }
            return
        }
        #if HAVE_CGCONTEXT_STROKE_ARC
        let wedge = path.pieWedgeArcValues()
        if wedge.kind == .Arc {
            let v = wedge.values
            if state.receiveFillPieWedge(v.0, v.1, v.2, v.3, v.4, wedge.flag) {
                return
            }
        }
        #endif
        state.receiveFillPath(WebKit.copyPlatformPath(path))
    }

    // GraphicsContextCG::strokePath(): a single line as a line segment, and a gradient in the clip of the stroked path.
    private func stroke(_ state: inout CGRendererCore, _ path: borrowing WebKit.RemoteCGRendererPath) {
        guard state.receiveStrokesWithoutGradient() else {
            let platformPath = WebKit.copyPlatformPath(path)
            state.receiveStrokeWithGradient({ context in strokedPlatformPathBounds(context, platformPath) }) { context, thickness in
                clipToStrokedPlatformPath(context, platformPath, thickness)
            }
            return
        }
        if path.isSingleDataLine() {
            state.receiveStrokePathSegment(path.singleSegmentValues())
            return
        }
        state.receiveStrokePath(WebKit.copyPlatformPath(path))
    }

    // RemoteGraphicsContext's gradient and pattern handlers, whose brushes keep their color, and its gradient fills. A missing
    // resource, or a pattern of the buffer the context draws into, is an invalid message, as in C++.

    func setFillCachedGradient(state: inout CGRendererCore, identifier: WebKit.RemoteGradientIdentifier, spaceTransform: WebCore.AffineTransform) throws(InvalidMessage) {
        var found = false
        let source = WebKit.cachedGradientBrush(resources, identifier, spaceTransform, &found)
        try messageCheck { found }
        state.receiveSetFillSource(source, RemoteCGRendererBrushKind.gradient)
    }

    func setStrokeCachedGradient(state: inout CGRendererCore, identifier: WebKit.RemoteGradientIdentifier, spaceTransform: WebCore.AffineTransform) throws(InvalidMessage) {
        var found = false
        let source = WebKit.cachedGradientBrush(resources, identifier, spaceTransform, &found)
        try messageCheck { found }
        state.receiveSetStrokeSource(source, RemoteCGRendererBrushKind.gradient)
    }

    func setFillPatternNativeImage(state: inout CGRendererCore, nativeImageIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        var found = false
        let source = WebKit.nativeImagePatternBrush(resources, nativeImageIdentifier, pattern, &found)
        try messageCheck { found }
        state.receiveSetFillSource(source, RemoteCGRendererBrushKind.pattern)
    }

    func setStrokePatternNativeImage(state: inout CGRendererCore, nativeImageIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        var found = false
        let source = WebKit.nativeImagePatternBrush(resources, nativeImageIdentifier, pattern, &found)
        try messageCheck { found }
        state.receiveSetStrokeSource(source, RemoteCGRendererBrushKind.pattern)
    }

    func setFillPatternImageBuffer(state: inout CGRendererCore, imageBufferIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        var found = false
        var drawsIntoTarget = false
        let source = WebKit.imageBufferPatternBrush(resources, imageBufferIdentifier, pattern, &found, &drawsIntoTarget)
        try messageCheck { found }
        try messageCheck { !drawsIntoTarget }
        state.receiveSetFillSource(source, RemoteCGRendererBrushKind.pattern)
    }

    func setStrokePatternImageBuffer(state: inout CGRendererCore, imageBufferIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        var found = false
        var drawsIntoTarget = false
        let source = WebKit.imageBufferPatternBrush(resources, imageBufferIdentifier, pattern, &found, &drawsIntoTarget)
        try messageCheck { found }
        try messageCheck { !drawsIntoTarget }
        state.receiveSetStrokeSource(source, RemoteCGRendererBrushKind.pattern)
    }

    // RemoteGraphicsContext's text decoration handlers.

    func drawLinesForText(
        state: inout CGRendererCore,
        point: WebCore.FloatPoint,
        thickness: Float,
        lineSegments: WebKit.RemoteCGRendererLineSegments,
        printing: Bool,
        doubleLines: Bool,
        strokeStyle: WebCore.StrokeStyle
    ) {
        let segments: Span<WebCore.FloatSegment> = lineSegments.span()
        state.receiveDrawLinesForText(segments, point.x(), point.y(), thickness, printing, doubleLines, strokeStyle)
    }

    // RemoteGraphicsContext::drawGlyphs(): a missing font is an invalid message, as in C++.
    func drawGlyphs(
        state: inout CGRendererCore,
        fontIdentifier: WebCore.RenderingResourceIdentifier,
        glyphsAdvances: WebKit.RemoteCGRendererGlyphs,
        localAnchor: WebCore.FloatPoint,
        smoothingMode: WebCore.FontSmoothingMode
    ) throws(InvalidMessage) {
        var draw = WebKit.makeRemoteCGRendererGlyphDraw()
        let glyphContext = state.receiveGlyphContext()
        let preparation = draw.prepare(glyphsAdvances, resources, fontIdentifier, smoothingMode, glyphContext)
        try messageCheck { preparation.found }
        guard preparation.draws else {
            return
        }
        let shadowFillColor = glyphContext.hasSimpleShadow ? WebKit.copyGlyphShadowFillColor(draw) : nil
        state.receiveDrawGlyphs(draw.run(), draw.positions(), draw.facts(), shadowFillColor, localAnchor.x(), localAnchor.y())
    }

    func drawDotsForDocumentMarker(state: inout CGRendererCore, rect: WebCore.FloatRect, mode: WebCore.DocumentMarkerLineStyleMode, color: CGRendererColorValue) {
        state.receiveDrawDotsForDocumentMarker(cgRect(rect), mode, color)
    }

    func fillRectWithCachedGradient(state: inout CGRendererCore, rect: WebCore.FloatRect, identifier: WebKit.RemoteGradientIdentifier) throws(InvalidMessage) {
        var found = false
        let source = WebKit.cachedGradientBrush(resources, identifier, WebCore.AffineTransform(), &found)
        try messageCheck { found }
        state.receiveClipAndPaintGradient(cgRect(rect), source)
    }

    func fillRectWithCachedGradientAndSpaceTransform(
        state: inout CGRendererCore,
        rect: WebCore.FloatRect,
        identifier: WebKit.RemoteGradientIdentifier,
        transform: WebCore.AffineTransform,
        requiresClipToRect: WebCore.RequiresClipToRect
    ) throws(InvalidMessage) {
        var found = false
        let source = WebKit.cachedGradientBrush(resources, identifier, transform, &found)
        try messageCheck { found }
        state.receiveFillRectWithGradient(cgRect(rect), source, requiresClipToRect == .Yes)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
