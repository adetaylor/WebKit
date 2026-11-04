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

// Receives the RemoteCGRenderer messages of an image buffer's context, on its stream connection's work queue, and draws
// them with the context's Swift CG renderer, as RemoteGraphicsContext and GraphicsContextCG would. The context lends each
// handler its renderer, stored in place, as the handler's state; a draw the renderer declines goes back to the context,
// through RemoteImageBufferGraphicsContext, once the renderer is no longer lent.
@_expose(Cxx)
final class RemoteCGRenderer {
    typealias State = CGRendererCore

    private let shellState: CGRendererShellState

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(shellState: borrowing CGRendererShellState) {
        self.shellState = copy shellState
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @used
    func getMessageReceiver() -> RefRemoteCGRendererMessageForwarder {
        WebKit.RemoteCGRendererMessageForwarder.create(target: self)
    }

    func save(state: inout CGRendererCore) {
        state.receiveSave(shellState)
    }

    func restore(state: inout CGRendererCore) {
        state.receiveRestore(shellState)
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
        state.receiveSetFillPackedColor(color, shellState)
    }

    func setStrokePackedColor(state: inout CGRendererCore, color: UInt32) {
        state.receiveSetStrokePackedColor(color, shellState)
    }

    func setStrokePackedColorAndThickness(state: inout CGRendererCore, color: UInt32, thickness: Float) {
        state.receiveSetStrokePackedColor(color, shellState)
        state.receiveSetStrokeThickness(thickness, shellState)
    }

    func setFillRule(state: inout CGRendererCore, rule: WebCore.WindRule) {
        state.receiveSetFillRule(rule, shellState)
    }

    func setStrokeThickness(state: inout CGRendererCore, thickness: Float) {
        state.receiveSetStrokeThickness(thickness, shellState)
    }

    func setStrokeStyle(state: inout CGRendererCore, style: WebCore.StrokeStyle) {
        state.receiveSetStrokeStyle(style, shellState)
    }

    func setCompositeMode(state: inout CGRendererCore, mode: WebCore.CompositeMode) {
        state.receiveSetCompositeMode(mode.operation, mode.blendMode, shellState)
    }

    func setAlpha(state: inout CGRendererCore, alpha: Float) {
        state.receiveSetAlpha(alpha, shellState)
    }

    func setImageInterpolationQuality(state: inout CGRendererCore, quality: WebCore.InterpolationQuality) {
        state.receiveSetImageInterpolationQuality(quality, shellState)
    }

    func setShouldAntialias(state: inout CGRendererCore, shouldAntialias: Bool) {
        state.receiveSetShouldAntialias(shouldAntialias, shellState)
    }

    func setShouldSmoothFonts(state: inout CGRendererCore, shouldSmooth: Bool) {
        state.receiveSetShouldSmoothFonts(shouldSmooth, shellState)
    }

    func setShouldSubpixelQuantizeFonts(state: inout CGRendererCore, shouldQuantize: Bool) {
        state.receiveSetShouldSubpixelQuantizeFonts(shouldQuantize, shellState)
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
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
