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

private func cgRect(_ rect: IPCTypes.FloatRect) -> CGRect {
    CGRect(x: CGFloat(rect.location.x), y: CGFloat(rect.location.y), width: CGFloat(rect.size.width), height: CGFloat(rect.size.height))
}

extension IPCTypes.WebCoreColor {
    // Color::data() as the renderer takes a color's data (GraphicsContextCG.cpp's colorData()).
    var cgRendererColorData: CGRendererColorData {
        var values = CGRendererColorData()
        guard let data else {
            return values
        }
        values.isSemantic = data.isSemantic
        values.usesFunctionSerialization = data.usesFunctionSerialization
        switch data.components {
        case .packed(let packedColor):
            values.form = 1
            values.packedColor = packedColor
        case .outOfLine(let colorSpace, let c1, let c2, let c3, let alpha):
            values.form = 2
            values.colorSpace = colorSpace.rawValue
            values.c1 = c1
            values.c2 = c2
            values.c3 = c3
            values.alpha = alpha
        }
        return values
    }
}

#if WTF_PLATFORM_MAC
// PlatformControlMac::state() of the part, with its style, and the part's tick marks: nil for a part that ControlFactoryMac
// makes no PlatformControlMac of.
private func macControlState(_ part: IPCTypes.ControlPart, _ style: IPCTypes.ControlStyle) -> (WebCore.MacControlState, [Double])? {
    var state = WebCore.MacControlState()
    var tickRatios: [Double] = []
    switch part {
    case .buttonPart(let button):
        state.appearance = button.type
    case .colorWellPart:
        state.appearance = .ColorWell
    case .innerSpinButtonPart:
        state.appearance = .InnerSpinButton
    case .menuListButtonPart:
        state.appearance = .MenulistButton
    case .menuListPart:
        state.appearance = .Menulist
    case .meterPart(let meter):
        state.appearance = .Meter
        state.meterValue = meter.value
        state.meterMinimum = meter.minimum
        state.meterMaximum = meter.maximum
        state.meterGaugeRegion = meter.gaugeRegion.rawValue
    case .progressBarPart(let progressBar):
        state.appearance = .ProgressBar
        state.progressPosition = progressBar.position
        state.progressAnimationStartTime = progressBar.animationStartTime
    case .searchFieldPart:
        state.appearance = .SearchField
    case .searchFieldResultsPart(let results):
        state.appearance = results.type
    case .searchFieldCancelButtonPart:
        state.appearance = .SearchFieldCancelButton
    case .sliderThumbPart(let thumb):
        state.appearance = thumb.type
    case .sliderTrackPart(let track):
        state.appearance = track.type
        state.sliderThumbWidth = track.thumbSize.width
        state.sliderThumbHeight = track.thumbSize.height
        state.sliderTrackX = track.trackBounds.location.x
        state.sliderTrackY = track.trackBounds.location.y
        state.sliderTrackWidth = track.trackBounds.size.width
        state.sliderTrackHeight = track.trackBounds.size.height
        tickRatios = track.tickRatios
    case .switchPart(let switchPart):
        state.appearance = .Switch
        state.switchIsOn = switchPart.isOn
        state.switchProgress = switchPart.progress
    case .textAreaPart(let textArea):
        state.appearance = textArea.type
    case .textFieldPart:
        state.appearance = .TextField
    case .toggleButtonPart(let toggleButton):
        state.appearance = toggleButton.type
    #if ENABLE_APPLE_PAY
    case .applePayButtonPart:
        return nil
    #endif
    #if ENABLE_SERVICE_CONTROLS
    case .imageControlsButtonPart:
        state.appearance = .ImageControlsButton
    #endif
    }
    let states = style.states
    state.isPressed = states.contains(.pressed)
    state.isFocused = states.contains(.focused)
    state.isEnabled = states.contains(.enabled)
    state.isChecked = states.contains(.checked)
    state.isWindowActive = states.contains(.windowActive)
    state.isIndeterminate = states.contains(.indeterminate)
    state.isSpinUp = states.contains(.spinUp)
    state.isPresenting = states.contains(.presenting)
    state.isInFormSemanticContext = states.contains(.formSemanticContext)
    state.usesDarkAppearance = states.contains(.darkAppearance)
    state.isInlineFlipped = states.contains(.inlineFlippedWritingMode)
    state.usesLargeControls = states.contains(.largeControls)
    state.isReadOnly = states.contains(.readOnly)
    state.hasListButton = states.contains(.listButton)
    state.isListButtonPressed = states.contains(.listButtonPressed)
    state.isVertical = states.contains(.verticalWritingMode)
    state.fontSize = style.fontSize
    state.zoomFactor = style.zoomFactor
    state.borderTop = style.borderWidth.top
    state.borderRight = style.borderWidth.right
    state.borderBottom = style.borderWidth.bottom
    state.borderLeft = style.borderWidth.left
    return (state, tickRatios)
}
#endif

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


extension IPCTypes.WindRule {
    var windRule: WebCore.WindRule {
        self == .evenOdd ? .EvenOdd : .NonZero
    }
}

extension IPCTypes.AffineTransform {
    // AffineTransform's a, b, c, d, e and f, as CGAffineTransform's.
    var cgAffineTransform: CGAffineTransform {
        let v = span
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }
}

extension IPCTypes.CGRendererColorValue {
    var cgRendererColorValue: CGRendererColorValue {
        let d = data
        let colorData = CGRendererColorData(
            c1: d.c1,
            c2: d.c2,
            c3: d.c3,
            alpha: d.alpha,
            packedColor: d.packedColor,
            colorSpace: d.colorSpace,
            form: d.form,
            isSemantic: d.isSemantic,
            usesFunctionSerialization: d.usesFunctionSerialization
        )
        return CGRendererColorValue(data: colorData, packedColor: packedColor, isPacked: isPacked, isVisible: isVisible)
    }
}

// The reader of the video frames that the web process shares with a receiver or a recorder, made when it first needs one: none
// without sources, as for a replay or the print process, which have no frames.
struct RemoteCGRendererVideoFrames {
    private let sources: GPUVideoFrameSources?
    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    private var reader: SharedVideoFrameSource?
    #endif

    init(_ sources: GPUVideoFrameSources?) {
        self.sources = sources
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    mutating func source() -> SharedVideoFrameSource? {
        if reader == nil {
            reader = sources?.make()
        }
        return reader
    }

    mutating func setSemaphore(_ semaphore: consuming IPCTypes.Semaphore) {
        if let source = source() {
            source.setSemaphore(semaphore)
        }
    }

    mutating func setSharedMemory(_ handle: consuming IPCTypes.SharedMemoryHandle) {
        if let source = source() {
            source.setSharedMemory(handle)
        }
    }
    #endif
}

// Receives the RemoteCGRenderer messages of an image buffer's context, on its stream connection's work queue, and draws
// them with the context's Swift CG renderer, as RemoteGraphicsContext and GraphicsContextCG would. The context lends each
// handler its renderer, stored in place, as the handler's state. The same handlers replay recordings of the messages
// (RemoteCGRendererRecording), into an image buffer's context or another that lends its renderer for the replay.
@_expose(Cxx)
final class RemoteCGRenderer {
    typealias State = CGRendererCore

    private let resources: WebKit.RemoteCGRendererResources
    // The rendering backend's Swift resources, where an image buffer's receiver looks up the image buffers and native images
    // its draws name.
    private let backendResources: RemoteRenderingBackendResources?
    private let displayLists: RemoteCGRendererDisplayLists?
    private let snapshotFrames: RemoteCGRendererSnapshotFrames?
    private var videoFrames: RemoteCGRendererVideoFrames
    // The recordings being replayed, innermost last, and the transforms that their SetCTMs are relative to.
    private var replayedRecordings: [RemoteCGRendererRecording] = []
    private var replayBaseTransforms: [CGAffineTransform] = []
    // How many recordings replayedRecordings has, which a DrawDisplayList reads without an access to the array.
    private var replayDepth = 0
    // How many recordings are being replayed, including those that replayedRecordings leaves out.
    private var replayLevel = 0
    // The images of the recordings being replayed that keep native images or image buffers, innermost last, where a replay
    // looks them up.
    private var imageReplays: [RemoteCGRendererRecordedImages] = []
    // A live DrawGlyphs's glyphs and advances, copied out of the message.
    private var liveGlyphs: ContiguousArray<CGGlyph> = []
    // The descriptions of the effects of the filters it drew last (RemoteCGRendererFilters.swift).
    private let filterDescriptions = RemoteCGRendererFilterDescriptions()
    private var liveAdvances: ContiguousArray<CGSize> = []
    #if WTF_PLATFORM_MAC
    // The cells it draws Mac control parts with, as a control factory's, made when first used.
    private var macControlCells: MacControlPainterCells?
    #endif

    @_expose(!Cxx)
    private init(
        resources: WebKit.RemoteCGRendererResources,
        backendState: RemoteRenderingBackendState?,
        displayLists: RemoteCGRendererDisplayLists?,
        snapshotFrames: RemoteCGRendererSnapshotFrames?
    ) {
        self.resources = resources
        self.backendResources = backendState?.resources
        self.videoFrames = RemoteCGRendererVideoFrames(backendState?.videoFrameSources)
        self.displayLists = displayLists
        self.snapshotFrames = snapshotFrames
    }

    // A new receiver, and the forwarder of its messages, which keeps it, as the stream connection the C++ registers the
    // forwarder with keeps the forwarder. Only C++ calls it, so @used keeps it under -O -wmo (rdar://179098545).
    @used
    static func createMessageReceiver(
        resources: WebKit.RemoteCGRendererResources,
        backend: WebKit.RemoteRenderingBackend
    ) -> RefRemoteCGRendererMessageForwarder {
        let state = backend.state
        return WebKit.RemoteCGRendererMessageForwarder.create(
            target: RemoteCGRenderer(resources: resources, backendState: state, displayLists: state.displayLists, snapshotFrames: nil)
        )
    }

    // A receiver that only replays recordings, with the frames of the snapshot that it draws, if any.
    @_expose(!Cxx)
    static func makeReplayer(resources: WebKit.RemoteCGRendererResources, snapshotFrames: RemoteCGRendererSnapshotFrames?) -> RemoteCGRenderer {
        RemoteCGRenderer(resources: resources, backendState: nil, displayLists: nil, snapshotFrames: snapshotFrames)
    }

    // GraphicsContext::drawDisplayList(): the recording's messages, with its resources and display lists, and their transforms
    // relative to the context's when the replay starts.
    @_expose(!Cxx)
    func replay(_ recording: RemoteCGRendererRecording, state: inout CGRendererCore) {
        // Only a recording whose messages look up resources needs its resources to be the ones looked up.
        let needsResources = recording.replayNeedsResources
        if needsResources {
            resources.beginReplay(recording.resources)
        }
        replayLevel += 1
        let images = recording.images
        if let images {
            imageReplays.append(images)
        }
        if recording.replayNeedsContext {
            replayedRecordings.append(recording)
            replayBaseTransforms.append(state.receiverCTM())
            replayDepth += 1
            RemoteCGRenderer.replay(recording.messages, to: self, state: &state)
            replayDepth -= 1
            replayBaseTransforms.removeLast()
            replayedRecordings.removeLast()
        } else {
            RemoteCGRenderer.replay(recording.messages, to: self, state: &state)
        }
        if images != nil {
            imageReplays.removeLast()
        }
        replayLevel -= 1
        if needsResources {
            resources.endReplay()
        }
    }

    // The image buffer or native image that a draw names: one of the backend's, or, in a replay, one that the recording kept.
    private func imageBuffer(_ identifier: WebCore.RenderingResourceIdentifier) -> WebCore.ImageBuffer? {
        imageBuffer(key: identifier.toUInt64())
    }

    private func imageBuffer(key: UInt64) -> WebCore.ImageBuffer? {
        if replayLevel == 0 {
            return backendResources?.imageBuffer(key: key)
        }
        return imageReplays.last?.imageBuffers[RemoteIdentifierKey(value: key)]
    }

    private func nativeImage(_ identifier: WebCore.RenderingResourceIdentifier) -> RemoteCGRendererImage? {
        nativeImage(key: identifier.toUInt64())
    }

    private func nativeImage(key: UInt64) -> RemoteCGRendererImage? {
        if replayLevel == 0 {
            return backendResources?.nativeImage(key: key)
        }
        return imageReplays.last?.nativeImages[RemoteIdentifierKey(value: key)]
    }

    // GraphicsContextCG::drawNativeImage()'s facts of the image, with the color matrix that inverts it where the options do.
    @inline(__always)
    private func facts(_ image: RemoteCGRendererImage, _ sourceRect: WebCore.FloatRect, _ options: WebCore.RasterDrawingOptions) -> CGRendererImageFacts {
        var facts = CGRendererImageFacts()
        facts.width = image.width
        facts.height = image.height
        facts.headroom = image.headroom
        facts.resolutionScale = 1
        facts.found = true
        #if ENABLE_AX_CUSTOM_COLOR_MODE
        let invertContent = options.invertContent()
        if invertContent == .Yes || invertContent == .Forced {
            WebKit.setInvertColorMatrix(image.nativeImage, sourceRect, options, &facts)
        }
        #endif
        return facts
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
        guard let baseTransform = replayBaseTransforms.last else {
            state.receiveSetCTM(cgAffineTransform(ctm))
            return
        }
        state.receiveSetCTM(cgAffineTransform(ctm).concatenating(baseTransform))
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

    // RemoteGraphicsContext's path handlers, and GraphicsContextCG's draws of an empty path, which draw nothing. A missing cached
    // path is an invalid message.

    // What the path handlers use of a message's path: Path::fastBoundingRect() only for a fill with a gradient, from FillPath
    // or DrawPath.
    func fillPathDecodeContext(state: borrowing CGRendererCore) -> IPCTypes.Path.DecodeContext {
        IPCTypes.Path.DecodeContext(needsFastBoundingRect: !state.receiveFillsWithoutGradient())
    }

    func pathDecodeContextWithoutBounds(state: borrowing CGRendererCore) -> IPCTypes.Path.DecodeContext {
        IPCTypes.Path.DecodeContext(needsFastBoundingRect: false)
    }

    func fillPath(state: inout CGRendererCore, path: IPCTypes.Path) {
        fill(&state, path.rendererPath)
    }

    func strokePath(state: inout CGRendererCore, path: IPCTypes.Path) {
        stroke(&state, path.rendererPath)
    }

    // GraphicsContextCG::drawPath(): with a gradient, the fill and the stroke one after the other.
    func drawPath(state: inout CGRendererCore, path: IPCTypes.Path) {
        let path = path.rendererPath
        if path.isEmpty {
            return
        }
        if CGRendererPlatformPath.drawWithoutGradient(&state, { path.platformPath() }) {
            return
        }
        // A fill without a gradient draws the CGPath of the path, which C++ makes of the Path in place, so that the stroke's
        // clip then has the CGPath rather than the segments.
        if state.receiveFillsWithoutGradient() {
            let platformPath = path.platformPath()
            platformPath.fill(&state)
            platformPath.strokeWithGradient(&state)
            return
        }
        fill(&state, path)
        stroke(&state, path)
    }

    func clipPath(state: inout CGRendererCore, path: IPCTypes.Path, windRule: IPCTypes.WindRule) {
        let path = path.rendererPath
        let rule = windRule.windRule
        state.receiveClip { context in path.clip(context, rule) }
    }

    func clipOutToPath(state: inout CGRendererCore, path: IPCTypes.Path) {
        let path = path.rendererPath
        state.receiveClip { context in path.clipOut(context) }
    }

    // The cache's CGPath of a cached path, shared with the cache, which only CGRendererPlatformPath reaches.
    private func cachedPlatformPath(_ identifier: WebKit.RemotePathImplIdentifier) -> CGRendererPlatformPath? {
        unsafe WebKit.copyCachedPlatformPath(resources, identifier).map(CGRendererPlatformPath.init)
    }

    func fillCachedPath(state: inout CGRendererCore, identifier: WebKit.RemotePathImplIdentifier) throws(InvalidMessage) {
        let path = cachedPlatformPath(identifier)
        try messageCheck { path != nil }
        guard let path else {
            return
        }
        fill(&state, .platformPath(path))
    }

    func clipCachedPath(state: inout CGRendererCore, identifier: WebKit.RemotePathImplIdentifier, windRule: WebCore.WindRule) throws(InvalidMessage) {
        let path = cachedPlatformPath(identifier)
        try messageCheck { path != nil }
        guard let path else {
            return
        }
        state.receiveClip { context in CGRendererPath.platformPath(path).clip(context, windRule) }
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
        let cached = nativeImage(imageIdentifier)
        try messageCheck { cached != nil }
        guard let cached, let image = cached.image else {
            return
        }
        state.receiveDrawNativeImage(image, facts(cached, srcRect, options), cgRect(destRect), cgRect(srcRect), CGRendererImageOptionsFor(options))
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
        let image = WebKit.copyImageBufferImage(resources, imageBuffer(imageBufferIdentifier), srcRect, options, true, &facts)
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
        let cached = nativeImage(imageIdentifier)
        try messageCheck { cached != nil }
        guard let cached, let image = cached.image else {
            return
        }
        drawPattern(&state, image, facts(cached, tileRect, options), destRect, tileRect, transform, phase, spacing, options)
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
        let image = WebKit.copyImageBufferImage(resources, imageBuffer(imageIdentifier), tileRect, options, false, &facts)
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

    // RemoteGraphicsContext's clip handlers. ClipToNativeImage of an image that isn't cached is an invalid message, and of an
    // image this process can't read clips to the destination only, as GraphicsContextCG::clipToNativeImage() does.

    func clipRoundedRect(state: inout CGRendererCore, rect: WebCore.FloatRoundedRect) {
        state.receiveClipToRoundedRect(rect)
    }

    func clipOutRoundedRect(state: inout CGRendererCore, rect: WebCore.FloatRoundedRect) {
        state.receiveClipOutToRoundedRect(rect)
    }

    func clipToNativeImage(state: inout CGRendererCore, imageIdentifier: WebCore.RenderingResourceIdentifier, destinationRect: WebCore.FloatRect) throws(InvalidMessage) {
        let cached = nativeImage(imageIdentifier)
        try messageCheck { cached != nil }
        guard let image = cached?.image else {
            state.receiveClip(cgRect(destinationRect))
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
    private func fill(_ state: inout CGRendererCore, _ path: CGRendererPath) {
        if path.isEmpty {
            return
        }
        guard state.receiveFillsWithoutGradient() else {
            let bounds = path.fastBoundingRect
            state.receiveFillWithGradient({ bounds }) { context, rule in path.clip(context, rule) }
            return
        }
        #if HAVE_CGCONTEXT_STROKE_ARC
        if let wedge = path.pieWedgeArc {
            let v = wedge.values
            if state.receiveFillPieWedge(v.0, v.1, v.2, v.3, v.4, wedge.flag) {
                return
            }
        }
        #endif
        path.platformPath().fill(&state)
    }

    // GraphicsContextCG::strokePath(): a single line as a line segment, and a gradient in the clip of the stroked path.
    private func stroke(_ state: inout CGRendererCore, _ path: CGRendererPath) {
        if path.isEmpty {
            return
        }
        guard state.receiveStrokesWithoutGradient() else {
            path.platformPath().strokeWithGradient(&state)
            return
        }
        if let line = path.singleDataLine {
            state.receiveStrokePathSegment(line)
            return
        }
        path.platformPath().stroke(&state)
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
        let tileImage = nativeImage(nativeImageIdentifier)
        try messageCheck { tileImage != nil }
        guard let tileImage else {
            return
        }
        state.receiveSetFillSource(WebKit.nativeImagePatternBrush(tileImage.nativeImage, pattern), RemoteCGRendererBrushKind.pattern)
    }

    func setStrokePatternNativeImage(state: inout CGRendererCore, nativeImageIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        let tileImage = nativeImage(nativeImageIdentifier)
        try messageCheck { tileImage != nil }
        guard let tileImage else {
            return
        }
        state.receiveSetStrokeSource(WebKit.nativeImagePatternBrush(tileImage.nativeImage, pattern), RemoteCGRendererBrushKind.pattern)
    }

    func setFillPatternImageBuffer(state: inout CGRendererCore, imageBufferIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        var found = false
        var drawsIntoTarget = false
        let source = WebKit.imageBufferPatternBrush(resources, imageBuffer(imageBufferIdentifier), pattern, &found, &drawsIntoTarget)
        try messageCheck { found }
        try messageCheck { !drawsIntoTarget }
        state.receiveSetFillSource(source, RemoteCGRendererBrushKind.pattern)
    }

    func setStrokePatternImageBuffer(state: inout CGRendererCore, imageBufferIdentifier: WebCore.RenderingResourceIdentifier, pattern: WebCore.PatternParameters) throws(InvalidMessage) {
        var found = false
        var drawsIntoTarget = false
        let source = WebKit.imageBufferPatternBrush(resources, imageBuffer(imageBufferIdentifier), pattern, &found, &drawsIntoTarget)
        try messageCheck { found }
        try messageCheck { !drawsIntoTarget }
        state.receiveSetStrokeSource(source, RemoteCGRendererBrushKind.pattern)
    }

    // RemoteGraphicsContext's clips to a path in coordinates a transform maps it from.

    func clipTransformedPath(state: inout CGRendererCore, pathTransform: IPCTypes.AffineTransform, path: IPCTypes.Path, windRule: IPCTypes.WindRule) {
        let path = path.rendererPath
        let rule = windRule.windRule
        state.receiveClipTransformed(pathTransform.cgAffineTransform) { context in path.clip(context, rule) }
    }

    func clipTransformedCachedPath(
        state: inout CGRendererCore,
        pathTransform: WebCore.AffineTransform,
        identifier: WebKit.RemotePathImplIdentifier,
        windRule: WebCore.WindRule
    ) throws(InvalidMessage) {
        let path = cachedPlatformPath(identifier)
        try messageCheck { path != nil }
        guard let path else {
            return
        }
        state.receiveClipTransformed(cgAffineTransform(pathTransform)) { context in CGRendererPath.platformPath(path).clip(context, windRule) }
    }

    func drawFocusRingPath(state: inout CGRendererCore, path: IPCTypes.Path, outlineWidth: Float, color: IPCTypes.CGRendererColorValue, zoomFactor: Float) {
        let path = path.rendererPath
        if path.isEmpty {
            return
        }
        path.platformPath().drawFocusRing(&state, color.cgRendererColorValue, zoomFactor)
    }

    // RemoteGraphicsContext's page handlers, for a PDF.

    func beginPage(state: inout CGRendererCore, pageRect: WebCore.FloatRect) {
        state.receiveBeginPage(cgRect(pageRect))
    }

    func endPage(state: inout CGRendererCore) {
        state.receiveEndPage()
    }

    // RemoteGraphicsContext's draws of what C++ renders: a missing resource is an invalid message.

    // GraphicsContext::drawMeshGradient(): the image that C++ renders of the gradient, drawn as a native image.
    func drawMeshGradient(state: inout CGRendererCore, identifier: WebKit.RemoteMeshGradientIdentifier, destination: WebCore.FloatRect) throws(InvalidMessage) {
        var facts = CGRendererImageFacts()
        var options = CGRendererImageOptions()
        let destinationSize = CGSize(width: CGFloat(destination.width()), height: CGFloat(destination.height()))
        let image = WebKit.copyMeshGradientImage(
            resources,
            identifier,
            state.receiverDeviceCTM(),
            state.receiverDestinationColorSpace(),
            destinationSize,
            &facts,
            &options
        )
        try messageCheck { facts.found }
        guard let image else {
            return
        }
        state.receiveDrawNativeImage(image, facts, cgRect(destination), CGRect(x: 0, y: 0, width: CGFloat(facts.width), height: CGFloat(facts.height)), options)
    }

    // RemoteGraphicsContext::drawFilteredImageBuffer(): the filter, or the cached SVG filter it names with its effects merged
    // in, applied to the source, with its FEImage images looked up. A missing image or cached filter is an invalid message.
    func drawFilteredImageBuffer(
        state: inout CGRendererCore,
        sourceImageIdentifier: IPCTypes.RenderingResourceIdentifier?,
        sourceImageRect: IPCTypes.FloatRect,
        filter: IPCTypes.Filter
    ) throws(InvalidMessage) {
        var sourceImageBuffer: WebCore.ImageBuffer?
        if let sourceImageIdentifier {
            sourceImageBuffer = imageBuffer(key: sourceImageIdentifier.rawValue)
            try messageCheck { sourceImageBuffer != nil }
        }
        let describer = RemoteCGRendererFilterDescriber(descriptions: filterDescriptions) { [self] key in
            if let image = nativeImage(key: key) {
                return .nativeImage(image.nativeImage)
            }
            if let imageBuffer = imageBuffer(key: key) {
                return .imageBuffer(imageBuffer)
            }
            return nil
        }
        let rect = floatRect(sourceImageRect)
        var absoluteImageRect = WebCore.IntRect()
        let result: WebCore.ImageBuffer?
        let filterScale: WebCore.FloatSize
        switch filter {
        case .cssFilterRenderer(let cssFilter):
            guard let described = describer.describe(cssFilter) else {
                try messageCheck { false }
                return
            }
            filterScale = described.renderer.filterScale
            let allocator = WebKit.createFilterImageAllocator(resources, replayLevel > 0)
            var results = FilterResultsState()
            result = applyCSSFilter(described, sourceImageBuffer, rect, allocator, &results, true, &absoluteImageRect)
        case .svgFilterRenderer(let svgFilter):
            // A recording keeps a cached SVG filter's merged effects as a filter of its own (RemoteCGRendererRecording).
            if let identifier = svgFilter.renderingResourceIdentifierIfExists {
                // The draw's FEImage images are found before its effects are merged.
                var drawnEffects: [FilterEffectDescription]?
                if svgFilter.hasFEImage {
                    drawnEffects = describer.describeEffects(svgFilter.effects)
                    try messageCheck { drawnEffects != nil }
                }
                let cachedFilter = replayLevel == 0 ? backendResources?.filter(key: identifier.rawValue) : nil
                guard let cachedFilter, let merged = cachedFilter.merge(svgFilter),
                    let described = cachedFilter.describe(merged, describer, drawnEffects: drawnEffects)
                else {
                    try messageCheck { false }
                    return
                }
                filterScale = described.renderer.filterScale
                result = cachedFilter.apply(described, sourceImageBuffer, rect, resources, &absoluteImageRect)
            } else {
                guard let described = describer.describe(svgFilter, identifier: 0) else {
                    try messageCheck { false }
                    return
                }
                filterScale = described.renderer.filterScale
                let allocator = WebKit.createFilterImageAllocator(resources, replayLevel > 0)
                var results = FilterResultsState()
                result = applySVGFilter(described, sourceImageBuffer, rect, allocator, &results, true, &absoluteImageRect)
            }
        }
        guard let resultImageBuffer = result else {
            return
        }
        // GraphicsContext::drawFilteredImageBuffer(): the result's image at its absolute rect, in the space of the filter's
        // scale, drawn as GraphicsContext::drawImageBuffer() draws one, while the result lasts.
        let source = WebCore.FloatRect(WebCore.FloatPoint(), resultImageBuffer.logicalSize())
        let options = WebCore.RasterDrawingOptions()
        var facts = CGRendererImageFacts()
        guard let image = WebKit.copyImageBufferImage(resources, resultImageBuffer, source, options, false, &facts) else {
            return
        }
        withExtendedLifetime(resultImageBuffer) {
            state.receiveScale(1 / filterScale.width(), 1 / filterScale.height())
            state.receiveDrawNativeImage(image, facts, cgRect(WebCore.FloatRect(absoluteImageRect)), cgRect(source), CGRendererImageOptionsFor(options))
            state.receiveScale(filterScale.width(), filterScale.height())
        }
    }

    // GraphicsContext::drawControlPart(): the part's platform control's draw, which only Apple Pay buttons and, on the Mac, the
    // Mac controls have.
    func drawControlPart(
        state: inout CGRendererCore,
        part: IPCTypes.ControlPart,
        borderRect: IPCTypes.FloatRoundedRect,
        deviceScaleFactor: Float,
        style: IPCTypes.ControlStyle
    ) {
        #if ENABLE_APPLE_PAY
        if case .applePayButtonPart(let button) = part {
            // std::max() of the corners' FloatSize::maxDimension(): the first largest.
            let radii = borderRect.radii
            let maxDimensions = [radii.topLeft, radii.topRight, radii.bottomLeft, radii.bottomRight].map { corner in
                corner.width < corner.height ? corner.height : corner.width
            }
            var largestCornerRadius = maxDimensions[0]
            for maxDimension in maxDimensions.dropFirst() where largestCornerRadius < maxDimension {
                largestCornerRadius = maxDimension
            }
            state.receiveDrawApplePayButton(
                cgRect(borderRect.rect),
                largestCornerRadius,
                button.buttonType.rawValue,
                button.buttonStyle.rawValue,
                button.locale ?? ""
            )
            return
        }
        #endif
        #if WTF_PLATFORM_MAC
        guard let (controlState, tickRatios) = macControlState(part, style) else {
            return
        }
        if macControlCells == nil {
            macControlCells = MacControlPainterCells()
        }
        guard let cells = macControlCells else {
            return
        }
        state.receiveDrawMacControlPart(
            cells,
            cgRect(borderRect.rect),
            deviceScaleFactor,
            controlState,
            style.accentColor.cgRendererColorData,
            style.textColor.cgRendererColorData,
            tickRatios
        )
        #endif
    }

    // GraphicsContext::drawSystemImage(), as GraphicsContextCG draws each kind.
    func drawSystemImage(state: inout CGRendererCore, systemImage: IPCTypes.SystemImage, destinationRect: IPCTypes.FloatRect) {
        let rect = cgRect(destinationRect)
        switch systemImage {
        #if ENABLE_APPLE_PAY
        case .applePayLogoSystemImage(let logo):
            state.receiveDrawApplePayLogo(logo.applePayLogoStyle == .black, rect)
        #endif
        #if USE_APPKIT
        case .appKitControlSystemImage(let controlImage):
            state.receiveDrawScrollbarTrackCorner(rect, controlImage.useDarkAppearance, controlImage.tintColor.cgRendererColorData)
        #endif
        }
    }

    #if USE_SYSTEM_PREVIEW
    // ARKitBadgeSystemImage's draw, with the cached native image it names as its backdrop.
    func drawBadgeSystemImage(
        state: inout CGRendererCore,
        imageIdentifier: WebCore.OptionalRenderingResourceIdentifier,
        destinationRect: WebCore.FloatRect
    ) throws(InvalidMessage) {
        var image: CGImage? = nil
        if let identifier = imageIdentifier.value {
            let cached = nativeImage(identifier)
            try messageCheck { cached != nil }
            image = cached?.image
        }
        state.receiveDrawARKitBadge(image, cgRect(destinationRect))
    }
    #endif

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    // GraphicsContext::drawVideoFrame(): the frame's image, oriented by the options, copied rather than drawn over where its
    // alpha doesn't count, which is the same and cheaper.
    func drawVideoFrame(
        state: inout CGRendererCore,
        frame: WebKit.SharedVideoFrame,
        rect: WebCore.FloatRect,
        shouldDiscardAlpha: WebCore.ShouldDiscardAlpha,
        options: WebCore.RasterDrawingOptions
    ) {
        guard let pixelBuffer = videoFrames.source()?.readBuffer(frame.bufferTag()) else {
            return
        }
        var facts = CGRendererImageFacts()
        var hasAlpha = false
        guard let image = WebKit.copyVideoFrameImage(pixelBuffer, frame, &facts, &hasAlpha) else {
            return
        }
        var imageOptions = CGRendererImageOptionsFor(options)
        let usesWidthAsHeight = (5...8).contains(imageOptions.orientation)
        let width = usesWidthAsHeight ? facts.height : facts.width
        let height = usesWidthAsHeight ? facts.width : facts.height
        if imageOptions.compositeOperator == .SourceOver && (shouldDiscardAlpha == .Yes || !hasAlpha) {
            imageOptions.compositeOperator = .Copy
        }
        state.receiveDrawNativeImage(image, facts, cgRect(rect), CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), imageOptions)
    }

    func setSharedVideoFrameSemaphore(state: inout CGRendererCore, semaphore: consuming IPCTypes.Semaphore) {
        videoFrames.setSemaphore(semaphore)
    }

    func setSharedVideoFrameMemory(state: inout CGRendererCore, storageHandle: consuming IPCTypes.SharedMemoryHandle) {
        videoFrames.setSharedMemory(storageHandle)
    }
    #endif

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

    // RemoteGraphicsContext::drawGlyphs(): a missing font is an invalid message, as in C++. A recorded run has the font that the
    // recorder found for it; a live one's glyphs and advances are copied out of the message first.
    func drawGlyphs(
        state: inout CGRendererCore,
        fontIdentifier: WebCore.RenderingResourceIdentifier,
        glyphsAdvances: WebKit.RemoteCGRendererGlyphs,
        localAnchor: WebCore.FloatPoint,
        smoothingMode: WebCore.FontSmoothingMode
    ) throws(InvalidMessage) {
        if glyphsAdvances.isRecorded() {
            let facts = glyphsAdvances.recordedFacts()
            guard facts.draws else {
                return
            }
            state.receiveDrawGlyphs(glyphsAdvances.recordedRun(), facts, smoothingMode.rawValue, localAnchor.x(), localAnchor.y())
            return
        }
        let count = glyphsAdvances.size()
        if liveGlyphs.count < count {
            liveGlyphs = ContiguousArray(repeating: 0, count: count)
            liveAdvances = ContiguousArray(repeating: CGSize.zero, count: count)
        }
        var facts = CGRendererGlyphFontFacts()
        var found = false
        let font: CTFont?
        do {
            var glyphsCopy = liveGlyphs.mutableSpan
            var advancesCopy = liveAdvances.mutableSpan
            font = WebKit.copyGlyphsForDraw(resources, fontIdentifier, glyphsAdvances, &glyphsCopy, &advancesCopy, &facts, &found)
        }
        try messageCheck { found }
        guard let font else {
            return
        }
        let glyphStorage = liveGlyphs
        let advanceStorage = liveAdvances
        let run = CGRendererMakeGlyphRun(font, glyphStorage.span.extracting(0..<count), advanceStorage.span.extracting(0..<count))
        state.receiveDrawGlyphs(run, facts, smoothingMode.rawValue, localAnchor.x(), localAnchor.y())
    }

    // RemoteGraphicsContext::drawDisplayList(): a missing display list is an invalid message. A recording draws the display
    // lists that it named when it was recorded.
    func drawDisplayList(state: inout CGRendererCore, identifier: WebKit.RemoteDisplayListIdentifier) throws(InvalidMessage) {
        let recording =
            if replayDepth > 0, let replayed = replayedRecordings.last {
                replayed.displayLists[RemoteIdentifierKey(value: WebKit.displayListKey(identifier))]
            } else {
                displayLists?.recording(key: WebKit.displayListKey(identifier))
            }
        guard let recording else {
            try messageCheck { false }
            return
        }
        replay(recording, state: &state)
    }

    // A snapshot's frame, where a replay of the snapshot draws it (RemoteSnapshot::applyFrame()). An image buffer's receiver has
    // no frames to draw.
    func drawSnapshotFrame(state: inout CGRendererCore, frameIdentifier: WebCore.FrameIdentifier) throws(InvalidMessage) {
        guard let snapshotFrames else {
            try messageCheck { false }
            return
        }
        let isDrawn = snapshotFrames.draw(WebKit.frameKey(frameIdentifier), to: self, state: &state)
        assert(isDrawn, "A snapshot is complete only once its frames are")
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
