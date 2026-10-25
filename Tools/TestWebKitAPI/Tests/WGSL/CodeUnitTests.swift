// swift-format-ignore-file: AlwaysUseLowerCamelCase
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

import Testing
@_spi(Testing) import WGSL

private func latin1(_ text: String) -> SourceText {
    SourceText(latin1: ContiguousArray(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
}

private func utf16(_ text: String) -> SourceText {
    SourceText(utf16: ContiguousArray(text.utf16))
}

private func codeUnits(_ text: String) -> ContiguousArray<UInt16> {
    ContiguousArray(text.utf16)
}

private func decimal(_ append: (inout ByteSink) -> Void) -> String {
    var sink = ByteSink()
    append(&sink)
    return String(decoding: sink.bytes, as: UTF8.self)
}

private func text(_ message: MessageText) -> String {
    String(decoding: message.codeUnits, as: UTF16.self)
}

@Suite
struct WGSLCodeUnitTests {
    @Test
    func latin1AndUTF16SpellingsAreEqual() {
        let narrow = latin1("x\u{E9}y\u{FF}z")
        let wide = utf16("x\u{E9}y\u{FF}z")
        #expect(narrow.isLatin1)
        #expect(!wide.isLatin1)
        #expect(narrow.count == wide.count)
        for index in 0..<narrow.count {
            #expect(narrow.codeUnit(at: index) == wide.codeUnit(at: index))
        }
        #expect(narrow.codeUnit(at: 3) == 0x00FF)
        #expect(narrow.codeUnitsEqual(0..<5, wide, 0..<5))
        #expect(wide.codeUnitsEqual(0..<5, narrow, 0..<5))
        #expect(narrow.codeUnitsEqual(0..<5, narrow, 0..<5))
        #expect(wide.codeUnitsEqual(0..<5, wide, 0..<5))
        #expect(narrow.codeUnitsEqual(1..<3, wide, 1..<3))
        #expect(narrow.codeUnitsEqual(0..<5, codeUnits("x\u{E9}y\u{FF}z"), 0..<5))
        #expect(wide.codeUnitsEqual(0..<5, codeUnits("x\u{E9}y\u{FF}z"), 0..<5))
        #expect(MessageText(narrow, 0..<5) == MessageText(wide, 0..<5))
        #expect(MessageText(narrow, 0..<5).codeUnits == codeUnits("x\u{E9}y\u{FF}z"))

        // No normalisation, and Latin-1 0xFF is U+00FF, not U+FF00 or U+FFFF.
        #expect(!narrow.codeUnitsEqual(0..<5, utf16("x\u{E9}y\u{FF00}z"), 0..<5))
        #expect(!narrow.codeUnitsEqual(0..<5, utf16("xe\u{301}y\u{FF}"), 0..<5))
        #expect(!utf16("\u{E9}").codeUnitsEqual(0..<1, utf16("e\u{301}"), 0..<1))
        #expect(!narrow.codeUnitsEqual(0..<5, wide, 0..<4))
        #expect(!narrow.codeUnitsEqual(0..<2, wide, 1..<3))
        #expect(narrow.codeUnitsEqual(2..<2, wide, 4..<4))
    }

    @Test
    func loneSurrogatesArePreserved() {
        let lone: ContiguousArray<UInt16> = [0x78, 0xD800, 0x79, 0xDC00, 0xD83D, 0xDE00, 0xDFFF]
        let source = SourceText(utf16: lone)
        #expect(source.count == 7)
        #expect(source.codeUnit(at: 1) == 0xD800)
        #expect(source.codeUnit(at: 3) == 0xDC00)
        #expect(source.codeUnit(at: 6) == 0xDFFF)
        #expect(source.codeUnitsEqual(0..<7, lone, 0..<7))
        #expect(!source.codeUnitsEqual(0..<7, codeUnits("x\u{FFFD}y\u{FFFD}\u{1F600}\u{FFFD}"), 0..<7))

        let quoted = MessageText(source, 0..<7)
        #expect(quoted.codeUnits == lone)
        let message: MessageText = "unresolved identifier '\(quoted)'"
        #expect(message.codeUnits == codeUnits("unresolved identifier '") + lone + codeUnits("'"))

        let span = SourceSpan(line: 1, lineOffset: 4, offset: 4, length: 7)
        let error = CompilationMessage(text: message, span: span)
        #expect(error.utf16 == message.codeUnits)
        #expect(error.span == span)
        #expect(error.message == "unresolved identifier 'x\u{FFFD}y\u{FFFD}\u{1F600}\u{FFFD}'")
        var dump: MessageText = ""
        error.dump(&dump)
        #expect(dump.codeUnits == codeUnits("1:4: ") + message.codeUnits)
    }

    @Test
    func decimalFormattingOfEveryIntegerWidth() {
        #expect(text("\(Int8.min) \(Int8.max) \(Int8(0)) \(Int8(-1))") == "-128 127 0 -1")
        #expect(text("\(Int16.min) \(Int16.max)") == "-32768 32767")
        #expect(text("\(Int32.min) \(Int32.max) \(Int32(-10))") == "-2147483648 2147483647 -10")
        #expect(text("\(Int64.min) \(Int64.max)") == "-9223372036854775808 9223372036854775807")
        #expect(text("\(Int.min) \(Int.max) \(0)") == "-9223372036854775808 9223372036854775807 0")
        #expect(text("\(UInt8.max) \(UInt8(0))") == "255 0")
        #expect(text("\(UInt16.max)") == "65535")
        #expect(text("\(UInt32.max) \(UInt32(4_000_000_000))") == "4294967295 4000000000")
        #expect(text("\(UInt64.max) \(UInt64(10_000_000_000_000_000_000))") == "18446744073709551615 10000000000000000000")
        #expect(text("\(UInt.max)") == "18446744073709551615")

        #expect(decimal { $0.appendDecimal(Int8.min) } == "-128")
        #expect(decimal { $0.appendDecimal(Int16.min) } == "-32768")
        #expect(decimal { $0.appendDecimal(Int32.min) } == "-2147483648")
        #expect(decimal { $0.appendDecimal(Int64.min) } == "-9223372036854775808")
        #expect(decimal { $0.appendDecimal(Int.min) } == "-9223372036854775808")
        #expect(decimal { $0.appendDecimal(Int64.max) } == "9223372036854775807")
        #expect(decimal { $0.appendDecimal(UInt8.max) } == "255")
        #expect(decimal { $0.appendDecimal(UInt16.max) } == "65535")
        #expect(decimal { $0.appendDecimal(UInt32.max) } == "4294967295")
        #expect(decimal { $0.appendDecimal(UInt64.max) } == "18446744073709551615")
        #expect(decimal { $0.appendDecimal(UInt.max) } == "18446744073709551615")
        #expect(decimal { $0.appendDecimal(UInt32(0)) } == "0")

        // Every power of ten and its neighbours, through both sinks, after existing content.
        var power: UInt64 = 1
        for _ in 0..<20 {
            for value in [power &- 1, power, power &+ 1] {
                #expect(
                    decimal {
                        $0.append("x")
                        $0.appendDecimal(value)
                    } == "x" + String(value)
                )
                #expect(text("x\(value)") == "x" + String(value))
                let signed = Int64(truncatingIfNeeded: value)
                #expect(decimal { $0.appendDecimal(signed) } == String(signed))
                #expect(text("\(signed)") == String(signed))
            }
            power = power &* 10
        }

        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<20_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let shift = state % 64
            let value = state >> shift
            let signed = Int64(bitPattern: state) >> shift
            #expect(decimal { $0.appendDecimal(value) } == String(value))
            #expect(decimal { $0.appendDecimal(signed) } == String(signed))
            #expect(decimal { $0.appendDecimal(Int32(truncatingIfNeeded: signed)) } == String(Int32(truncatingIfNeeded: signed)))
            #expect(text("\(value) \(signed)") == String(value) + " " + String(signed))
        }
    }

    @Test
    func byteSinkLiteralAppend() {
        var sink = ByteSink(reservingCapacity: 256)
        #expect(sink.bytes.isEmpty)
        sink.append("")
        #expect(sink.bytes.isEmpty)
        sink.append("(")
        sink.append("local")
        sink.append("fifteen bytes!!")
        sink.append("sixteen bytes!!!")
        sink.append("    if (local_invocation_index == 0u) {\n")
        let expected = "(" + "local" + "fifteen bytes!!" + "sixteen bytes!!!" + "    if (local_invocation_index == 0u) {\n"
        #expect(String(decoding: sink.bytes, as: UTF8.self) == expected)
        #expect(sink.bytes == ContiguousArray(expected.utf8))

        var other = ByteSink()
        other.append("caf\u{E9} \u{2192} \u{1F600}")
        #expect(other.bytes == ContiguousArray("caf\u{E9} \u{2192} \u{1F600}".utf8))
        sink.append(contentsOf: other)
        other.appendDecimal(Int32(-7))
        #expect(sink.bytes == ContiguousArray((expected + "caf\u{E9} \u{2192} \u{1F600}").utf8))
        #expect(other.bytes == ContiguousArray("caf\u{E9} \u{2192} \u{1F600}-7".utf8))
    }

    @Test
    func byteSinkFormattersAndClear() {
        let double: Double = 0.1
        let float: Float = 2.5
        let half = Half(1.5)
        var sink = ByteSink()
        var expected: ContiguousArray<UInt8> = []
        WTFNumberFormat.appendWithTrailingPoint(1.0, to: &sink)
        WTFNumberFormat.appendWithTrailingPoint(1.0, to: &expected)
        sink.append(" ")
        expected.append(0x20)
        WTFNumberFormat.appendNumber(double, to: &sink)
        WTFNumberFormat.appendNumber(double, to: &expected)
        sink.append(" ")
        expected.append(0x20)
        WTFNumberFormat.appendNumber(float, to: &sink)
        WTFNumberFormat.appendNumber(float, to: &expected)
        sink.append(" ")
        expected.append(0x20)
        WTFNumberFormat.appendNumber(half, to: &sink)
        WTFNumberFormat.appendNumber(half, to: &expected)
        sink.append(" ")
        expected.append(0x20)
        WTFNumberFormat.appendPrintfF(0.5, to: &sink)
        WTFNumberFormat.appendPrintfF(0.5, to: &expected)
        #expect(sink.bytes == expected)
        #expect(String(decoding: sink.bytes, as: UTF8.self) == "1. 0.1 2.5 1.5 0.500000")
        sink.clear()
        #expect(sink.bytes.isEmpty)
        sink.append("x")
        #expect(sink.bytes == ContiguousArray("x".utf8))
    }

    @Test
    func messageTextInterpolation() {
        let kind: StaticString = "uniform"
        let name = MessageText(utf16("\u{3B1}\u{3B2}"), 0..<2)
        let message: MessageText = "cannot use '\(name)' in address space \(kind) at index \(UInt32(3))"
        #expect(text(message) == "cannot use '\u{3B1}\u{3B2}' in address space uniform at index 3")
        let literal: MessageText = "plain"
        #expect(literal.codeUnits == codeUnits("plain"))
        #expect(MessageText(codeUnits: codeUnits("plain")) == literal)
        var appended: MessageText = ""
        #expect(appended.isEmpty)
        appended.append(literal)
        appended.append(" \u{E9}")
        #expect(text(appended) == "plain \u{E9}")
        #expect(Set([literal, MessageText(codeUnits: codeUnits("plain"))]).count == 1)
    }

    @Test
    func numberInterpolationUsesTheWTFFormatters() {
        #expect(
            text("\(number: 0.1) \(number: 1e39) \(number: Double.infinity) \(number: -0.0) \(number: Double.nan)")
                == "0.1 1e+39 Infinity 0 NaN"
        )
        #expect(text("\(number: Float(2.5)) \(number: Float(0.1))") == "2.5 0.1")
        #expect(text("\(number: Half(1.5))") == "1.5")
        for value in [1.0 / 3.0, 123_456_789.125, Double.leastNonzeroMagnitude, -1.75e300] {
            #expect(text("\(number: value)") == String(decoding: WTFNumberFormat.number(value), as: UTF8.self))
        }
    }

    @Test
    func compilationMessageDump() {
        let message = CompilationMessage(text: "unresolved type 'T'", span: SourceSpan(line: 3, lineOffset: 7, offset: 30, length: 1))
        var out: MessageText = "> "
        message.dump(&out)
        #expect(text(out) == "> 3:7: unresolved type 'T'")
        #expect(message.dumpDescription == "3:7: unresolved type 'T'")
        #expect(CompilationMessage("x", span: .empty) == CompilationMessage(text: "x", span: .empty))
    }
}
