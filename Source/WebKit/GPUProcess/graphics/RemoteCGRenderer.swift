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

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(resources: WebKit.RemoteCGRendererResources) {
        self.resources = resources
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @used
    func getMessageReceiver() -> RefRemoteCGRendererMessageForwarder {
        WebKit.RemoteCGRendererMessageForwarder.create(target: self)
    }

    func save(state: inout CGRendererCore) {
        state.receiveSave()
    }

    func restore(state: inout CGRendererCore) -> Bool {
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
        state.receiveConcatCTM(cgAffineTransform(ctm))
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

    func fillRect(state: inout CGRendererCore, rect: WebCore.FloatRect, requiresClipToRect: WebCore.RequiresClipToRect) -> Bool {
        state.receiveFillRect(cgRect(rect))
    }

    func fillEllipse(state: inout CGRendererCore, rect: WebCore.FloatRect) -> Bool {
        state.receiveFillEllipse(cgRect(rect))
    }

    func strokeRect(state: inout CGRendererCore, rect: WebCore.FloatRect, lineWidth: Float) -> Bool {
        state.receiveStrokeRect(cgRect(rect), lineWidth)
    }

    func strokeEllipse(state: inout CGRendererCore, rect: WebCore.FloatRect) -> Bool {
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

    func drawEllipse(state: inout CGRendererCore, rect: WebCore.FloatRect) -> Bool {
        state.receiveDrawEllipse(cgRect(rect))
    }

    func fillLine(state: inout CGRendererCore, line: WebCore.PathDataLine) -> Bool {
        state.receiveFillPathSegment(lineSegment(line))
    }

    func fillArc(state: inout CGRendererCore, arc: WebCore.PathArc) -> Bool {
        state.receiveFillPathSegment(arcSegment(arc, .Arc))
    }

    func fillClosedArc(state: inout CGRendererCore, closedArc: WebCore.PathClosedArc) -> Bool {
        state.receiveFillPathSegment(arcSegment(closedArc.arc, .ClosedArc))
    }

    func fillQuadCurve(state: inout CGRendererCore, curve: WebCore.PathDataQuadCurve) -> Bool {
        state.receiveFillPathSegment(quadCurveSegment(curve))
    }

    func fillBezierCurve(state: inout CGRendererCore, curve: WebCore.PathDataBezierCurve) -> Bool {
        state.receiveFillPathSegment(bezierCurveSegment(curve))
    }

    func fillPathSegment(state: inout CGRendererCore, segment: WebKit.RemoteCGRendererPathSegment) -> Bool {
        state.receiveFillPathSegment(segment.values())
    }

    func strokeLine(state: inout CGRendererCore, line: WebCore.PathDataLine) -> Bool {
        state.receiveStrokePathSegment(lineSegment(line))
    }

    func strokeLinesWithColorAndThickness(state: inout CGRendererCore, lines: WebKit.RemoteCGRendererLineStrokes) {
        let span: Span<WebCore.PathDataLineColorThickness> = lines.span()
        state.receiveStrokeLinesWithColorAndThickness(span)
    }

    func strokeArc(state: inout CGRendererCore, arc: WebCore.PathArc) -> Bool {
        #if HAVE_CGCONTEXT_STROKE_ARC
        // GraphicsContextCG strokes it with CGContextStrokeArc(), which the renderer doesn't call yet.
        return false
        #else
        return state.receiveStrokePathSegment(arcSegment(arc, .Arc))
        #endif
    }

    func strokeClosedArc(state: inout CGRendererCore, closedArc: WebCore.PathClosedArc) -> Bool {
        state.receiveStrokePathSegment(arcSegment(closedArc.arc, .ClosedArc))
    }

    func strokeQuadCurve(state: inout CGRendererCore, curve: WebCore.PathDataQuadCurve) -> Bool {
        state.receiveStrokePathSegment(quadCurveSegment(curve))
    }

    func strokeBezierCurve(state: inout CGRendererCore, curve: WebCore.PathDataBezierCurve) -> Bool {
        state.receiveStrokePathSegment(bezierCurveSegment(curve))
    }

    func strokePathSegment(state: inout CGRendererCore, segment: WebKit.RemoteCGRendererPathSegment) -> Bool {
        state.receiveStrokePathSegment(segment.values())
    }

    // RemoteGraphicsContext's path handlers, and GraphicsContextCG's draws of an empty path, which draw nothing.

    func fillPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) -> Bool {
        fill(&state, path)
    }

    func strokePath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) -> Bool {
        if path.isEmpty() {
            return true
        }
        if path.isSingleDataLine() {
            return state.receiveStrokePathSegment(path.singleSegmentValues())
        }
        guard state.receiveStrokesWithoutGradient() else {
            return false
        }
        state.receiveStrokePath(path.platformPath())
        return true
    }

    func drawPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) -> Bool {
        if path.isEmpty() {
            return true
        }
        return state.receiveDrawPath { path.platformPath() }
    }

    func clipPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath, windRule: WebCore.WindRule) {
        state.receiveClip { context in path.clip(context, windRule) }
    }

    func clipOutToPath(state: inout CGRendererCore, path: WebKit.RemoteCGRendererPath) {
        state.receiveClip { context in path.clipOut(context) }
    }

    func fillCachedPath(state: inout CGRendererCore, identifier: WebKit.RemotePathImplIdentifier) throws(InvalidMessage) -> Bool {
        let path = resources.cachedPath(identifier)
        try messageCheck { path.isValid() }
        return fill(&state, path)
    }

    func clipCachedPath(state: inout CGRendererCore, identifier: WebKit.RemotePathImplIdentifier, windRule: WebCore.WindRule) throws(InvalidMessage) {
        let path = resources.cachedPath(identifier)
        try messageCheck { path.isValid() }
        state.receiveClip { context in path.clip(context, windRule) }
    }

    private func fill(_ state: inout CGRendererCore, _ path: borrowing WebKit.RemoteCGRendererPath) -> Bool {
        if path.isEmpty() {
            return true
        }
        guard state.receiveFillsWithoutGradient() else {
            return false
        }
        state.receiveFillPath(path.platformPath())
        return true
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
