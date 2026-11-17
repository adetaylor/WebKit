//
// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1.  Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import WebKit_Internal

@_expose(Cxx)
final class TestWithStreamSwiftRecordableWeakRef {
    private let target: TestWithStreamSwiftRecordable
    init(target: TestWithStreamSwiftRecordable) {
        self.target = target
    }

    @used
    func dispatchReset(
        state: inout TestWithStreamSwiftRecordable.State
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.reset(
                    state: &state
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetSource(
        state: inout TestWithStreamSwiftRecordable.State,
        source: UInt64
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setSource(
                    state: &state,
                    source: source
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetValues(
        state: inout TestWithStreamSwiftRecordable.State,
        value: UInt32,
        scale: Float
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setValues(
                    state: &state,
                    value: value,
                    scale: scale
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchDrawRun(
        state: inout TestWithStreamSwiftRecordable.State,
        origin: WebCore.FloatPoint,
        run: WebKit.TestWithStreamSwiftRecordableRun
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.drawRun(
                    state: &state,
                    origin: origin,
                    run: run
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    #if WTF_PLATFORM_COCOA
    @used
    func dispatchDraw(
        state: inout TestWithStreamSwiftRecordable.State,
        rect: WebCore.FloatRect,
        clip: Bool
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.draw(
                    state: &state,
                    rect: rect,
                    clip: clip
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }
    #endif

    @used
    func dispatchSetLabel(
        state: inout TestWithStreamSwiftRecordable.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let label: String?
        let tag: UInt64?
        do {
            label = try IPCCoding.WTFString.decode(from: &decoder)
            tag = try IPCCoding.StdOptional<UInt64>.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setLabel(
                    state: &state,
                    label: label,
                    tag: tag
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetLabelSource(
        state: inout TestWithStreamSwiftRecordable.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let source: UInt64
        do {
            source = try UInt64.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setLabelSource(
                    state: &state,
                    source: source
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchFillPath(
        state: inout TestWithStreamSwiftRecordable.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let path: IPCTypes.Path
        let decodeContext = target.pathDecodeContext(state: state)
        do {
            path = try IPCTypes.Path.decode(from: &decoder, context: decodeContext)
        } catch {
            IPCTypes.Path.decodeFailed(context: decodeContext)
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.fillPath(
                    state: &state,
                    path: path
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetSemaphore(
        state: inout TestWithStreamSwiftRecordable.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let semaphore: IPCTypes.Semaphore
        let source: UInt64
        do {
            semaphore = try IPCTypes.Semaphore.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do {
            source = try UInt64.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setSemaphore(
                    state: &state,
                    semaphore: semaphore,
                    source: source
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchDrawGlyphs(
        state: inout TestWithStreamSwiftRecordable.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let glyphs: IPCTypes.GlyphRun
        let segments: [WebCore.FloatSegment]
        let decodeContext = target.glyphsDecodeContext(state: state)
        do {
            glyphs = try IPCTypes.GlyphRun.decode(from: &decoder, context: decodeContext)
            segments = try IPCCoding.TrivialSpan<WebCore.FloatSegment>.decode(from: &decoder)
        } catch {
            IPCTypes.GlyphRun.decodeFailed(context: decodeContext)
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.drawGlyphs(
                    state: &state,
                    glyphs: glyphs,
                    segments: segments
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetMatrix(
        state: inout TestWithStreamSwiftRecordable.State,
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let matrix: IPCCoding.StdArray20<Float>.Value
        let strokeStyle: WebCore.StrokeStyle
        do {
            matrix = try IPCCoding.StdArray20<Float>.decode(from: &decoder)
            strokeStyle = try IPCCoding.CxxEnum<WebCore.StrokeStyle>.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setMatrix(
                    state: &state,
                    matrix: matrix,
                    strokeStyle: strokeStyle
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }
}

extension WebKit.TestWithStreamSwiftRecordableMessageForwarder {
    static func create(target: TestWithStreamSwiftRecordable) -> RefTestWithStreamSwiftRecordableMessageForwarder {
        let weakRefContainer = TestWithStreamSwiftRecordableWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithStreamSwiftRecordableMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}

// The messages as values, which a recorder of them keeps: an argument with 'RecordedAs=' as the type that names.
extension TestWithStreamSwiftRecordable {
    enum RecordedMessage {
        case reset
        case setValues(value: UInt32, scale: Float)
        case drawRun(origin: WebCore.FloatPoint, run: WebKit.TestWithStreamSwiftRecordableRecordedRun)
        #if WTF_PLATFORM_COCOA
        case draw(rect: WebCore.FloatRect, clip: Bool)
        #endif
        case setLabel(label: String?, tag: UInt64?)
        case fillPath(path: IPCTypes.Path)
        case drawGlyphs(glyphs: IPCTypes.GlyphRun, segments: [WebCore.FloatSegment])
        case setMatrix(matrix: IPCCoding.StdArray20<Float>.Value, strokeStyle: WebCore.StrokeStyle)
    }

    // Calls the handler of each message in turn, as the forwarder does for a message it receives, with the state lent for
    // the whole replay. A handler that finds a message invalid only skips it: the recorder checked each message when it
    // recorded it.
    static func replay(_ messages: borrowing [RecordedMessage], to target: TestWithStreamSwiftRecordable, state: inout State) {
        for index in messages.indices {
            switch messages[index] {
            case .reset:
                _ = try? mayThrowInvalidMessage(
                    target.reset(
                        state: &state
                    )
                )
            case .setValues(let value, let scale):
                _ = try? mayThrowInvalidMessage(
                    target.setValues(
                        state: &state,
                        value: value,
                        scale: scale
                    )
                )
            case .drawRun(let origin, let run):
                _ = try? mayThrowInvalidMessage(
                    target.drawRun(
                        state: &state,
                        origin: origin,
                        run: run.argument()
                    )
                )
            #if WTF_PLATFORM_COCOA
            case .draw(let rect, let clip):
                _ = try? mayThrowInvalidMessage(
                    target.draw(
                        state: &state,
                        rect: rect,
                        clip: clip
                    )
                )
            #endif
            case .setLabel(let label, let tag):
                _ = try? mayThrowInvalidMessage(
                    target.setLabel(
                        state: &state,
                        label: label,
                        tag: tag
                    )
                )
            case .fillPath(let path):
                _ = try? mayThrowInvalidMessage(
                    target.fillPath(
                        state: &state,
                        path: path
                    )
                )
            case .drawGlyphs(let glyphs, let segments):
                _ = try? mayThrowInvalidMessage(
                    target.drawGlyphs(
                        state: &state,
                        glyphs: glyphs,
                        segments: segments
                    )
                )
            case .setMatrix(let matrix, let strokeStyle):
                _ = try? mayThrowInvalidMessage(
                    target.setMatrix(
                        state: &state,
                        matrix: matrix,
                        strokeStyle: strokeStyle
                    )
                )
            }
        }
    }

    // Encodes each message in turn as the stream sends it, for a recorder in another process to record again.
    static func encode(_ messages: borrowing [RecordedMessage], to encoder: inout WebKit.TestWithStreamSwiftRecordableRecordedMessageEncoder) {
        for index in messages.indices {
            switch messages[index] {
            case .reset:
                encoder.encodeReset()
            case .setValues(let value, let scale):
                encoder.encodeSetValues(value, scale)
            case .drawRun(let origin, let run):
                encoder.encodeDrawRun(origin, run.argument())
            #if WTF_PLATFORM_COCOA
            case .draw(let rect, let clip):
                encoder.encodeDraw(rect, clip)
            #endif
            case .setLabel(let label, let tag):
                let messageEncoder = encoder.encoderForSetLabel()
                IPCCoding.WTFString.encode(label, to: messageEncoder)
                IPCCoding.StdOptional<UInt64>.encode(tag, to: messageEncoder)
                encoder.appendEncodedMessage(messageEncoder)
            case .fillPath(let path):
                let messageEncoder = encoder.encoderForFillPath()
                IPCTypes.Path.encode(path, to: messageEncoder)
                encoder.appendEncodedMessage(messageEncoder)
            case .drawGlyphs(let glyphs, let segments):
                let messageEncoder = encoder.encoderForDrawGlyphs()
                IPCTypes.GlyphRun.encode(glyphs, to: messageEncoder)
                IPCCoding.TrivialSpan<WebCore.FloatSegment>.encode(segments, to: messageEncoder)
                encoder.appendEncodedMessage(messageEncoder)
            case .setMatrix(let matrix, let strokeStyle):
                let messageEncoder = encoder.encoderForSetMatrix()
                IPCCoding.StdArray20<Float>.encode(matrix, to: messageEncoder)
                IPCCoding.CxxEnum<WebCore.StrokeStyle>.encode(strokeStyle, to: messageEncoder)
                encoder.appendEncodedMessage(messageEncoder)
            }
        }
    }
}

// The dispatch of each message to a recorder, which C++ calls on the stream connection's work queue with the arguments it
// decoded. The forwarder keeps the recorder, which must not keep the forwarder.
@_expose(Cxx)
final class TestWithStreamSwiftRecordableRecorderWeakRef {
    private let target: TestWithStreamSwiftRecordableRecorder
    init(target: TestWithStreamSwiftRecordableRecorder) {
        self.target = target
    }

    @used
    func dispatchReset() -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try target.record(.reset)
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetSource(
        source: UInt64
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setSource(source: source)
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetValues(
        value: UInt32,
        scale: Float
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try target.record(
                .setValues(
                    value: value,
                    scale: scale
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchDrawRun(
        origin: WebCore.FloatPoint,
        run: WebKit.TestWithStreamSwiftRecordableRun
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try target.record(
                .drawRun(
                    origin: origin,
                    run: WebKit.TestWithStreamSwiftRecordableRecordedRun(run)
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    #if WTF_PLATFORM_COCOA
    @used
    func dispatchDraw(
        rect: WebCore.FloatRect,
        clip: Bool
    ) -> IPC.SwiftLentStateDispatch {
        do throws(InvalidMessage) {
            try target.record(
                .draw(
                    rect: rect,
                    clip: clip
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }
    #endif

    @used
    func dispatchSetLabel(
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let label: String?
        let tag: UInt64?
        do {
            label = try IPCCoding.WTFString.decode(from: &decoder)
            tag = try IPCCoding.StdOptional<UInt64>.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try target.record(
                .setLabel(
                    label: label,
                    tag: tag
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetLabelSource(
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let source: UInt64
        do {
            source = try UInt64.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setLabelSource(source: source)
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchFillPath(
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let path: IPCTypes.Path
        do {
            path = try IPCTypes.Path.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try target.record(
                .fillPath(
                    path: path
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetSemaphore(
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let semaphore: IPCTypes.Semaphore
        let source: UInt64
        do {
            semaphore = try IPCTypes.Semaphore.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do {
            source = try UInt64.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try mayThrowInvalidMessage(
                target.setSemaphore(semaphore: semaphore, source: source)
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchDrawGlyphs(
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let glyphs: IPCTypes.GlyphRun
        let segments: [WebCore.FloatSegment]
        do {
            glyphs = try IPCTypes.GlyphRun.decode(from: &decoder)
            segments = try IPCCoding.TrivialSpan<WebCore.FloatSegment>.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try target.record(
                .drawGlyphs(
                    glyphs: glyphs,
                    segments: segments
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }

    @used
    func dispatchSetMatrix(
        decoder: inout IPC.SwiftDecoder
    ) -> IPC.SwiftLentStateDispatch {
        let matrix: IPCCoding.StdArray20<Float>.Value
        let strokeStyle: WebCore.StrokeStyle
        do {
            matrix = try IPCCoding.StdArray20<Float>.decode(from: &decoder)
            strokeStyle = try IPCCoding.CxxEnum<WebCore.StrokeStyle>.decode(from: &decoder)
        } catch {
            return .Invalid
        }
        do throws(InvalidMessage) {
            try target.record(
                .setMatrix(
                    matrix: matrix,
                    strokeStyle: strokeStyle
                )
            )
        } catch {
            return .Invalid
        }
        return .Handled
    }
}

extension WebKit.TestWithStreamSwiftRecordableRecorderMessageForwarder {
    static func create(target: TestWithStreamSwiftRecordableRecorder) -> RefTestWithStreamSwiftRecordableRecorderMessageForwarder {
        let weakRefContainer = TestWithStreamSwiftRecordableRecorderWeakRef(target: target)
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        return unsafe WebKit.TestWithStreamSwiftRecordableRecorderMessageForwarder.createFromWeak(
            OpaquePointer(
                Unmanaged.passRetained(weakRefContainer).toOpaque()
            )
        )
    }
}
