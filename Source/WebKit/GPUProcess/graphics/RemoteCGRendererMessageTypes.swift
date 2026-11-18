// Copyright (C) 2026 Apple Inc. All rights reserved.
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

// The arguments of RemoteCGRenderer's messages that the GPU process decodes in Swift and hands to the CG renderer as its plain
// values: line strokes and segments, shadows, styles, and glyph runs.

// The line strokes of StrokeLinesWithColorAndThickness, the line segments of DrawLinesForText, and the glyphs and advances of
// DrawGlyphs, which go as spans of them. Each is made of floats and integers alone, so every bit pattern of it is a value.
extension WebCore.PathDataLineColorThickness: IPCTrivialSpanElement {
    @unsafe static var everyBitPatternIsAValue: Void { () }
}
extension WebCore.FloatSegment: IPCTrivialSpanElement {
    @unsafe static var everyBitPatternIsAValue: Void { () }
}
extension CGGlyph: IPCTrivialSpanElement {
    @unsafe static var everyBitPatternIsAValue: Void { () }
}
extension CGSize: IPCTrivialSpanElement {
    @unsafe static var everyBitPatternIsAValue: Void { () }
}

extension IPCTypes.CGRendererShadowValues {
    var cgRendererShadowValues: CGRendererShadowValues {
        CGRendererShadowValues(
            width: width,
            height: height,
            radius: radius,
            opacity: opacity,
            packedColor: packedColor,
            isValid: isValid,
            isVisible: isVisible,
            legacyRadius: legacyRadius
        )
    }
}

extension IPCTypes.CGRendererColorData {
    var cgRendererColorData: CGRendererColorData {
        CGRendererColorData(
            c1: c1,
            c2: c2,
            c3: c3,
            alpha: alpha,
            packedColor: packedColor,
            colorSpace: colorSpace,
            form: form,
            isSemantic: isSemantic,
            usesFunctionSerialization: usesFunctionSerialization
        )
    }
}

extension IPCTypes {
    /// The glyph run of RemoteCGRenderer's DrawGlyphs, an IPC::ArrayReferenceTuple<GlyphBufferGlyph, GlyphBufferAdvance>: its
    /// count, then its glyphs and its advances, each as a std::span. Swift copies them out of the message, which the web process
    /// can still write while it is handled, with the advances at the precision they have in RemoteGraphicsContext's DrawGlyphs,
    /// into storage: a live dispatch's is the renderer's own, which it reuses for every run ('SwiftDecodeContext='), and a
    /// recorder's is the run's own, which the recording keeps with the font that the recorder finds for it.
    struct GlyphRun: IPCCoder, Sendable {
        /// The glyphs and advances of runs, as many as a run's count, and a recorded run's font.
        ///
        /// Unchecked Sendable, as RemoteCGRendererRecordedGlyphs's run was thread-safe ref-counted: a live dispatch's storage is
        /// the renderer's, which only its stream's work queue decodes into and reads, one message at a time; a recorded run's is
        /// written once, as it is decoded and then by setRecordedFont() on the recorder's queue, before any replay reads it.
        final class Storage: @unchecked Sendable {
            fileprivate(set) var glyphs: ContiguousArray<CGGlyph>
            fileprivate(set) var advances: ContiguousArray<CGSize>
            /// Whether this is a recorded run's, whose font the recorder gives it (setRecordedFont()).
            let isRecorded: Bool
            private(set) var recordedFont: CTFont?
            private(set) var recordedFacts = CGRendererGlyphFontFacts()
            private var hasRecordedFont = false

            /// The storage that a live dispatch decodes each run into, which grows to the longest.
            init() {
                glyphs = []
                advances = []
                isRecorded = false
            }

            fileprivate init(recordedCount count: Int) {
                glyphs = ContiguousArray(repeating: 0, count: count)
                advances = ContiguousArray(repeating: .zero, count: count)
                isRecorded = true
            }

            /// Gives a recorded run the CTFont of the font that the recorder found for it, and the font's facts for the run,
            /// once, before anything replays it.
            func setRecordedFont(_ font: CTFont?, facts: CGRendererGlyphFontFacts) {
                precondition(isRecorded && !hasRecordedFont, "A recorded run gets its font once")
                hasRecordedFont = true
                recordedFont = font
                recordedFacts = facts
            }

            fileprivate func makeRoom(for count: Int) {
                if glyphs.count < count {
                    glyphs = ContiguousArray(repeating: 0, count: count)
                    advances = ContiguousArray(repeating: .zero, count: count)
                }
            }
        }

        let storage: Storage
        /// How many of the storage's glyphs and advances are the run's.
        let count: Int

        static func decode(from decoder: inout IPC.SwiftDecoder, context storage: Storage) throws(IPCDecodingError) -> GlyphRun {
            let count = try decodeCount(from: &decoder)
            storage.makeRoom(for: count)
            try decodeGlyphsAndAdvances(from: &decoder, count: count, glyphs: &storage.glyphs, advances: &storage.advances)
            return GlyphRun(storage: storage, count: count)
        }

        static func decodeFailed(context: Storage) {
        }

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> GlyphRun {
            let count = try decodeCount(from: &decoder)
            let storage = Storage(recordedCount: count)
            try decodeGlyphsAndAdvances(from: &decoder, count: count, glyphs: &storage.glyphs, advances: &storage.advances)
            return GlyphRun(storage: storage, count: count)
        }

        static func encode(_ value: GlyphRun, to encoder: IPC.SwiftReplyEncoder) {
            encoder.encode(UInt64(value.count))
            if value.count == 0 {
                return
            }
            encoder.encodeElements(value.storage.glyphs, count: value.count)
            encoder.encodeElements(value.storage.advances, count: value.count)
        }

        private static func decodeCount(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Int {
            guard let count = Int(exactly: try UInt64.decode(from: &decoder)) else {
                throw IPCDecodingError()
            }
            // Each glyph of the run takes its glyph's and its advance's bytes of what is left of the message, so a count beyond
            // that is malformed, and mustn't be allocated.
            guard count <= decoder.remainingByteCount() / (MemoryLayout<CGGlyph>.size + MemoryLayout<CGSize>.size) else {
                decoder.markInvalid()
                throw IPCDecodingError()
            }
            return count
        }

        private static func decodeGlyphsAndAdvances(
            from decoder: inout IPC.SwiftDecoder,
            count: Int,
            glyphs: inout ContiguousArray<CGGlyph>,
            advances: inout ContiguousArray<CGSize>
        ) throws(IPCDecodingError) {
            // C++ decodes an empty run without aligning the decoder.
            if count == 0 {
                return
            }
            guard decoder.decodeElements(into: &glyphs, count: count), decoder.decodeElements(into: &advances, count: count) else {
                throw IPCDecodingError()
            }
            for index in 0..<count {
                let advance = advances[index]
                advances[index] = CGSize(width: CGFloat(Float(advance.width)), height: CGFloat(Float(advance.height)))
            }
        }
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
