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
    /// can still write while it is handled, with the advances at the precision they have in RemoteGraphicsContext's DrawGlyphs:
    /// a live dispatch into the renderer's storage, which it reuses for every run ('SwiftDecodeContext='), and a recorder into
    /// one allocation of the run's own, which the recording keeps with the font that the recorder finds for it.
    struct GlyphRun: IPCCoder, Sendable {
        /// The glyphs and advances of a live dispatch's runs, as many as a run's count.
        ///
        /// Unchecked Sendable: only the renderer's stream's work queue decodes into it and reads it, one message at a time.
        final class Storage: @unchecked Sendable {
            fileprivate(set) var glyphs = ContiguousArray<CGGlyph>()
            fileprivate(set) var advances = ContiguousArray<CGSize>()

            /// The storage that a live dispatch decodes each run into, which grows to the longest.
            init() {
            }

            fileprivate func makeRoom(for count: Int) {
                if glyphs.count < count {
                    glyphs = ContiguousArray(repeating: 0, count: count)
                    advances = ContiguousArray(repeating: .zero, count: count)
                }
            }
        }

        /// Unchecked Sendable, for the storage it names. A live run's Storage is the renderer's, which only the renderer's stream's
        /// work queue decodes into and reads, one message at a time, during the message's dispatch. A recorded run's
        /// IPCRecordedGlyphRun is written as it is decoded and once more, by setRecordedFont(), from the recorder's record(), before
        /// record() appends the message that holds it to the recorder's messages; record() does both under the recorder's lock, or
        /// on its one queue for a recorder without one, and anything that replays the run reaches it only through the recording
        /// that takeRecording() or currentRecording() gives, under that lock or on that queue, after the append.
        enum Glyphs: @unchecked Sendable {
            /// A live dispatch's run, the first count of the storage's glyphs and advances.
            case live(Storage, count: Int)
            case recorded(IPCRecordedGlyphRun)
        }

        let glyphs: Glyphs

        static func decode(from decoder: inout IPC.SwiftDecoder, context storage: Storage) throws(IPCDecodingError) -> GlyphRun {
            let count = try decodeCount(from: &decoder)
            // C++ decodes an empty run without aligning the decoder.
            if count > 0 {
                storage.makeRoom(for: count)
                guard decoder.decodeGlyphRun(glyphs: &storage.glyphs, advances: &storage.advances, count: count) else {
                    throw IPCDecodingError()
                }
            }
            return GlyphRun(glyphs: .live(storage, count: count))
        }

        static func decodeFailed(context: Storage) {
        }

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> GlyphRun {
            let count = try decodeCount(from: &decoder)
            guard let run = IPCRecordedGlyphRun.decode(count: count, from: &decoder) else {
                throw IPCDecodingError()
            }
            return GlyphRun(glyphs: .recorded(run))
        }

        static func encode(_ value: GlyphRun, to encoder: IPC.SwiftReplyEncoder) {
            switch value.glyphs {
            case .live(let storage, let count):
                encoder.encode(UInt64(count))
                if count > 0 {
                    encoder.encodeGlyphRun(glyphs: storage.glyphs, advances: storage.advances, count: count)
                }
            case .recorded(let run):
                run.encode(to: encoder)
            }
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
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
