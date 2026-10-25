// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
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

private func utf16(units: [UInt16]) -> SourceText {
    SourceText(utf16: ContiguousArray(units))
}

private func string(_ table: SymbolTable, _ symbol: Symbol) -> String {
    String(decoding: table.codeUnits(of: symbol), as: UTF16.self)
}

private func intern(_ table: inout SymbolTable, _ text: String) -> Symbol {
    let source = utf16(text)
    return table.intern(source, 0..<source.count)
}

private func spellings(_ table: inout SymbolTable, _ names: [ReservedName]) -> [String] {
    var result: [String] = []
    for name in names {
        let symbol = table.intern(name)
        result.append(string(table, symbol))
    }
    return result
}

private func spelling(_ table: inout SymbolTable, _ name: MangledName) -> String {
    let symbol = table.intern(name)
    return string(table, symbol)
}

private func fnv1a(_ units: [UInt16]) -> UInt64 {
    var state: UInt64 = 14_695_981_039_346_656_037
    for unit in units {
        state = (state ^ UInt64(unit)) &* 1_099_511_628_211
    }
    return state
}

// Distinct identifiers whose 64-bit FNV-1a hashes have their low 17 bits clear: "q" and four letters, a letter that
// clears bit 16 of the state, then the code unit that clears bits 0-15.
private func fnvLowBitCollisions(_ count: Int) -> [[UInt16]] {
    let letters = Array("abcdefghijklmnopqrstuvwxyz".utf16)
    var identifiers: [[UInt16]] = []
    var serial = 0
    while identifiers.count < count {
        var identifier = [UInt16(UInt8(ascii: "q"))]
        var digits = serial
        for _ in 0..<4 {
            identifier.append(letters[digits % letters.count])
            digits /= letters.count
        }
        serial += 1
        let state = fnv1a(identifier)
        guard let letter = letters.first(where: { ((state ^ UInt64($0)) &* 1_099_511_628_211) & 0x1_0000 == 0 }) else {
            continue
        }
        identifier.append(letter)
        identifier.append(UInt16(truncatingIfNeeded: fnv1a(identifier)))
        identifiers.append(identifier)
    }
    return identifiers
}

private func isDigits(_ text: Substring) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
}

// [a-z]+[0-9]+
private func isLettersThenDigits(_ text: String) -> Bool {
    guard let firstDigit = text.firstIndex(where: { $0.isASCII && $0.isNumber }) else {
        return false
    }
    let letters = text[..<firstDigit]
    return !letters.isEmpty && letters.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
        && isDigits(text[firstDigit...])
}

// (type|local|global|parameter|function|field)[0-9]+, the spellings of MangledName.toString().
private func isMangledShape(_ text: String) -> Bool {
    ["type", "local", "global", "parameter", "function", "field"]
        .contains { prefix in
            text.hasPrefix(prefix) && isDigits(text.dropFirst(prefix.count))
        }
}

private let builtinDeclarationCount = 182
private let primitiveStructFieldNames = ["fract", "exp", "whole", "old_value", "exchanged"]
private let typeAliasNames = [
    "vec2f", "vec2h", "vec2i", "vec2u", "mat2x2f", "mat2x2h", "mat2x3f", "mat2x3h", "mat2x4f", "mat2x4h",
    "vec3f", "vec3h", "vec3i", "vec3u", "mat3x2f", "mat3x2h", "mat3x3f", "mat3x3h", "mat3x4f", "mat3x4h",
    "vec4f", "vec4h", "vec4i", "vec4u", "mat4x2f", "mat4x2h", "mat4x3f", "mat4x3h", "mat4x4f", "mat4x4h",
]

// Every `__` spelling of the C++ (Source/WebGPU/WGSL at the reference commit, generator/ excluded): the literals that
// start with "__" (grep '"__'), the names the writer's EMIT_HELPER/NOOP_HELPER macros make, and the `__` words of the
// MSL the writer prints (helper bodies included). C++ macro parameters (`__name`, `__VA_ARGS__`, …), compiler builtins
// and attributes of the C++ itself are not MSL and are left out.
private let cxxFixedSpellings: [(String, String)] = [
    ("__frexp_result", "TypeStore.cpp:262"),
    ("__modf_result", "TypeStore.cpp:277"),
    ("__atomic_compare_exchange_result", "TypeStore.cpp:290"),
    ("__wgslMin", "BoundsCheck.cpp:108"),
    ("__pack", "GlobalVariableRewriter.cpp:496"),
    ("__unpack", "GlobalVariableRewriter.cpp:496"),
    ("__PackedArray", "GlobalVariableRewriter.cpp:1001"),
    ("__dynamicOffset", "GlobalVariableRewriter.cpp:2502"),
    ("__localInvocationIndex", "GlobalVariableRewriter.cpp:2629"),
    ("__wgslZeroWorkgroupVar", "GlobalVariableRewriter.cpp:2665"),
    ("__DynamicOffsets", "GlobalVariableRewriter.cpp:2903"),
    ("__type", "EntryPointRewriter.cpp:169"),
    ("__value", "EntryPointRewriter.cpp:174"),
    ("__wgslEnsureForwardProgress", "MetalFunctionWriter.cpp:49"),
    ("__wgslEnsureSwitchClauseScope", "MetalFunctionWriter.cpp:53"),
    ("__wgslAcos", "MetalFunctionWriter.cpp:120"),
    ("__wgslAsin", "MetalFunctionWriter.cpp:121"),
    ("__wgslAcosh", "MetalFunctionWriter.cpp:122"),
    ("__wgslAtanh", "MetalFunctionWriter.cpp:123"),
    ("__wgslInverseSqrt", "MetalFunctionWriter.cpp:124"),
    ("__wgslLog", "MetalFunctionWriter.cpp:125"),
    ("__wgslLog2", "MetalFunctionWriter.cpp:126"),
    ("__wgslSqrt", "MetalFunctionWriter.cpp:127"),
    ("__wgslPackFloatToSnorm2x16", "MetalFunctionWriter.cpp:128"),
    ("__wgslPackFloatToUnorm2x16", "MetalFunctionWriter.cpp:129"),
    ("__wgslPackFloatToSnorm4x8", "MetalFunctionWriter.cpp:130"),
    ("__wgslPackFloatToUnorm4x8", "MetalFunctionWriter.cpp:131"),
    ("__wgslMetalAppleGPUFamily", "MetalFunctionWriter.cpp:84"),
    ("__wgslTextureSampleBaseClampToEdge", "MetalFunctionWriter.cpp:136"),
    ("__wgslTextureSampleBiasWithOffset", "MetalFunctionWriter.cpp:190"),
    ("__texture", "MetalFunctionWriter.cpp:136"),
    ("__sampler", "MetalFunctionWriter.cpp:136"),
    ("__coords", "MetalFunctionWriter.cpp:136"),
    ("__bounds", "MetalFunctionWriter.cpp:138"),
    ("__inputCoords", "MetalFunctionWriter.cpp:169"),
    ("__reconstructionSampler", "MetalFunctionWriter.cpp:171"),
    ("__firstPlaneSize", "MetalFunctionWriter.cpp:172"),
    ("__secondPlaneSize", "MetalFunctionWriter.cpp:173"),
    ("__lumaBounds", "MetalFunctionWriter.cpp:174"),
    ("__chromaBounds", "MetalFunctionWriter.cpp:175"),
    ("__secondCoords", "MetalFunctionWriter.cpp:177"),
    ("__y", "MetalFunctionWriter.cpp:178"),
    ("__second", "MetalFunctionWriter.cpp:179"),
    ("__rgb", "MetalFunctionWriter.cpp:182"),
    ("__x", "MetalFunctionWriter.cpp:189"),
    ("__bias", "MetalFunctionWriter.cpp:190"),
    ("__size", "MetalFunctionWriter.cpp:193"),
    ("__levels", "MetalFunctionWriter.cpp:195"),
    ("__lod", "MetalFunctionWriter.cpp:196"),
    ("__low", "MetalFunctionWriter.cpp:197"),
    ("__high", "MetalFunctionWriter.cpp:198"),
    ("__lowSize", "MetalFunctionWriter.cpp:199"),
    ("__highSize", "MetalFunctionWriter.cpp:200"),
    ("__offset", "MetalFunctionWriter.cpp:202"),
    ("__arrayIndex", "MetalFunctionWriter.cpp:213"),
    ("__z", "MetalFunctionWriter.cpp:235"),
    ("__PackedType", "MetalFunctionWriter.cpp:458"),
    ("__PackedTypeImpl", "MetalFunctionWriter.cpp:454"),
    ("__UnpackedType", "MetalFunctionWriter.cpp:456"),
    ("__UnpackedTypeImpl", "MetalFunctionWriter.cpp:452"),
    ("__padding", "MetalFunctionWriter.cpp:471"),
    ("__wgslAtomicCompareExchangeWeak", "MetalFunctionWriter.cpp:815"),
    ("__wgslDot", "MetalFunctionWriter.cpp:829"),
    ("__wgslDot4I8Packed", "MetalFunctionWriter.cpp:842"),
    ("__wgslDot4U8Packed", "MetalFunctionWriter.cpp:854"),
    ("__wgslFirstLeadingBit", "MetalFunctionWriter.cpp:867"),
    ("__wgslFirstTrailingBit", "MetalFunctionWriter.cpp:881"),
    ("__wgslSign", "MetalFunctionWriter.cpp:892"),
    ("__wgslExtractBits", "MetalFunctionWriter.cpp:903"),
    ("__wgslInsertBits", "MetalFunctionWriter.cpp:940"),
    ("__wgslFrexp", "MetalFunctionWriter.cpp:774"),
    ("__wgslModf", "MetalFunctionWriter.cpp:795"),
    ("__attribute__", "MetalFunctionWriter.cpp:1006"),
    ("__xAdjustment", "MetalFunctionWriter.cpp:2146"),
    ("__yAdjustment", "MetalFunctionWriter.cpp:2152"),
    ("__ycbcr", "MetalFunctionWriter.cpp:2165"),
    ("__workgroup_uniform_load", "MetalFunctionWriter.cpp:2528"),
    ("__wgslAtomicLoadResult", "MetalFunctionWriter.cpp:2581"),
    ("__wgslFtoi", "MetalFunctionWriter.cpp:2951"),
    ("__wgslDiv", "MetalFunctionWriter.cpp:3017"),
    ("__wgslMod", "MetalFunctionWriter.cpp:3019"),
    ("__asm", "MetalFunctionWriter.cpp:3314"),
    ("__wgslFragmentReturnResult", "MetalFunctionWriter.cpp:3371"),
    ("__continuing", "MetalFunctionWriter.cpp:3530"),
]

// The C++ literals that start a spelling built at run time (makeString(literal, …)).
private let cxxPrefixSpellings: [(String, String)] = [
    ("__", "GlobalVariableRewriter.cpp:237"),
    ("__", "GlobalVariableRewriter.cpp:1081"),
    ("__ArgumentBufferPlaceholder_", "GlobalVariableRewriter.cpp:2384"),
    ("__", "GlobalVariableRewriter.cpp:2487"),
    ("__i", "GlobalVariableRewriter.cpp:2685"),
    ("__ArgumentBuffer_", "GlobalVariableRewriter.cpp:2893"),
    ("__ArgumentBufferT_", "GlobalVariableRewriter.cpp:2898"),
    ("__", "EntryPointRewriter.cpp:90"),
    ("__", "EntryPointRewriter.cpp:135"),
    ("__builtin", "EntryPointRewriter.cpp:322"),
    ("__evalOrder", "EvaluationOrderRewriter.cpp:225"),
    ("__wgslConst", "MetalFunctionWriter.cpp:1900"),
    ("__padding", "MetalFunctionWriter.cpp:1056"),
]

@Suite
struct WGSLSymbolTableTests {
    @Test
    func latin1AndUTF16SpellingsAreTheSameSymbol() {
        var table = SymbolTable.predeclared
        let narrow = latin1("let caf\u{E9}_\u{FF} = 1;")
        let wide = utf16("let caf\u{E9}_\u{FF} = 1;")
        let fromNarrow = table.intern(narrow, 4..<10)
        let count = table.count
        let fromWide = table.intern(wide, 4..<10)
        #expect(fromNarrow == fromWide)
        #expect(table.count == count)
        #expect(table.intern(ContiguousArray("caf\u{E9}_\u{FF}".utf16)) == fromNarrow)
        #expect(string(table, fromNarrow) == "caf\u{E9}_\u{FF}")
        #expect(table.length(of: fromNarrow) == 6)
        #expect(table.codeUnit(of: fromNarrow, at: 5) == 0x00FF)
        #expect(table.provenance(of: fromNarrow) == .source)

        let keyword = table.intern(narrow, 0..<3)
        #expect(keyword == table.intern("let"))
        #expect(keyword != fromNarrow)

        // No normalisation, and Latin-1 0xFF is U+00FF.
        #expect(intern(&table, "cafe\u{301}_\u{FF}") != fromNarrow)
        #expect(intern(&table, "caf\u{E9}_\u{FF00}") != fromNarrow)
        #expect(intern(&table, "caf\u{E9}_") != fromNarrow)
        #expect(intern(&table, "Caf\u{E9}_\u{FF}") != fromNarrow)
    }

    @Test
    func loneSurrogatesRoundTrip() {
        var table = SymbolTable.predeclared
        let high: [UInt16] = [0x61, 0xD800, 0x62]
        let low: [UInt16] = [0x61, 0xDC00, 0x62]
        let pair: [UInt16] = [0x61, 0xD83D, 0xDE00, 0x62]
        let highSymbol = table.intern(utf16(units: high), 0..<3)
        let lowSymbol = table.intern(utf16(units: low), 0..<3)
        let pairSymbol = table.intern(utf16(units: pair), 0..<4)
        #expect(Array(table.codeUnits(of: highSymbol)) == high)
        #expect(Array(table.codeUnits(of: lowSymbol)) == low)
        #expect(Array(table.codeUnits(of: pairSymbol)) == pair)
        #expect(table.codeUnits(of: pairSymbol)[1] == 0xD83D)
        #expect(Array(table.text(of: highSymbol).codeUnits) == high)
        #expect(Array(table.name(of: lowSymbol).utf16) == low)
        var appended: ContiguousArray<UInt16> = [0x2A]
        table.appendCodeUnits(of: highSymbol, to: &appended)
        #expect(Array(appended) == [0x2A] + high)
        #expect(highSymbol != lowSymbol)
        #expect(highSymbol != pairSymbol)
        #expect(highSymbol != table.intern(ContiguousArray([0x61, 0xFFFD, 0x62])))
        #expect(table.intern(utf16(units: [0x20] + high + [0x20]), 1..<4) == highSymbol)
        #expect(table.intern(ContiguousArray(pair)) == pairSymbol)
    }

    @Test
    func predeclaredSymbolsAreFixed() {
        let predeclared = SymbolTable.predeclared
        #expect(predeclared.count == builtinDeclarationCount + 3 + typeAliasNames.count)
        #expect(typeAliasNames.count == 30)

        var seen = Set<String>()
        for index in 0..<predeclared.count {
            guard let symbol = Symbol(predeclaredIndex: index) else {
                Issue.record("no predeclared symbol \(index)")
                continue
            }
            let text = string(predeclared, symbol)
            #expect(symbol.predeclaredIndex == index)
            #expect(symbol.builtinDeclarationIndex == (index < builtinDeclarationCount ? index : nil))
            #expect(predeclared.provenance(of: symbol) == .builtin)
            #expect(seen.insert(text).inserted, "\(text)")
            #expect(!text.hasPrefix("__"), "\(text)")
            #expect(!isMangledShape(text), "\(text)")
        }
        #expect(Symbol(predeclaredIndex: predeclared.count) == nil)
        #expect(Symbol(predeclaredIndex: -1) == nil)

        // The same symbols in every module, whatever the module interned before.
        var first = SymbolTable.predeclared
        var second = SymbolTable.predeclared
        _ = intern(&second, "userFunction")
        _ = intern(&second, "vec4fx")
        let expected: [(String, Int?, Int?)] = [
            ("!", 0, 0),
            ("||", 1, 1),
            ("bool", 20, 20),
            ("arrayLength", 40, 40),
            ("exp", 67, 67),
            ("fract", 75, 75),
            ("min", 84, 84),
            ("workgroupBarrier", 155, 155),
            ("quadSwapY", 181, 181),
            ("whole", 182, nil),
            ("old_value", 183, nil),
            ("exchanged", 184, nil),
            ("vec2f", 185, nil),
            ("mat4x4h", 214, nil),
            ("userFunction", nil, nil),
        ]
        for (name, predeclaredIndex, builtinIndex) in expected {
            let symbol = intern(&first, name)
            #expect(intern(&second, name) == symbol, "\(name)")
            #expect(latin1(name).count == name.utf16.count)
            #expect(first.intern(latin1(name), 0..<name.utf16.count) == symbol, "\(name)")
            #expect(symbol.predeclaredIndex == predeclaredIndex, "\(name)")
            #expect(symbol.builtinDeclarationIndex == builtinIndex, "\(name)")
        }
        for name in primitiveStructFieldNames + typeAliasNames {
            let symbol = intern(&first, name)
            #expect(symbol.predeclaredIndex != nil, "\(name)")
            #expect(first.provenance(of: symbol) == .builtin, "\(name)")
        }
        for (offset, name) in typeAliasNames.enumerated() {
            #expect(intern(&first, name).predeclaredIndex == builtinDeclarationCount + 3 + offset, "\(name)")
        }
        #expect(SymbolTable.predeclared.count == predeclared.count)
    }

    @Test
    func tableGrowthKeepsEverySymbol() {
        var table = SymbolTable.predeclared
        let base = table.count
        var symbols: [Symbol] = []
        for index in 0..<5000 {
            symbols.append(intern(&table, "name\(index)"))
        }
        #expect(table.count == base + 5000)
        for index in 0..<5000 {
            #expect(intern(&table, "name\(index)") == symbols[index])
            #expect(string(table, symbols[index]) == "name\(index)")
        }
        #expect(intern(&table, "quadSwapY").predeclaredIndex == 181)
        #expect(table.count == base + 5000)
        #expect(SymbolTable.predeclared.count == base)
    }

    // The Lexer interns every identifier token, so identifiers that share the low bits of an unkeyed hash must not form
    // one probe cluster (quadratic interning).
    @Test
    func craftedHashCollisionsDoNotCluster() {
        let identifiers = fnvLowBitCollisions(50_000)
        #expect(identifiers.allSatisfy { fnv1a($0) & 0x1_FFFF == 0 })
        var units: [UInt16] = []
        var ranges: [Range<Int>] = []
        for identifier in identifiers {
            let start = units.count
            units.append(contentsOf: identifier)
            ranges.append(start..<units.count)
            units.append(0x20)
        }
        let source = utf16(units: units)
        var table = SymbolTable.predeclared
        let base = table.count
        var symbols: [Symbol] = []
        for range in ranges {
            symbols.append(table.intern(source, range))
        }
        #expect(table.count == base + identifiers.count)
        #expect(table.longestProbeRun() < 1000)
        for index in stride(from: 0, to: identifiers.count, by: 997) {
            #expect(table.intern(ContiguousArray(identifiers[index])) == symbols[index])
            #expect(Array(table.codeUnits(of: symbols[index])) == identifiers[index])
        }
        #expect(SymbolTable.predeclared.longestProbeRun() < 100)
    }

    @Test
    func provenanceMinting() {
        var table = SymbolTable.predeclared
        var mangler = Mangler.makeForTesting()

        let original = intern(&table, "position")
        #expect(table.provenance(of: original) == .source)
        let void = table.intern("void")
        #expect(table.provenance(of: void) == .source)
        let typeString = table.intern(ContiguousArray("array<f32, 4>".utf16))
        #expect(table.provenance(of: typeString) == .source)

        // .mangled: user text spelled like a mangled name is upgraded, never the reverse.
        let spoof = intern(&table, "local1")
        #expect(table.provenance(of: spoof) == .source)
        let local0 = mangler.makeMangledName(original, .local)
        let local1 = mangler.makeMangledName(original, .local)
        let global0 = mangler.makeMangledName(original, .global)
        #expect(local0.originalName == original)
        #expect(local0.kind == .local && local0.index == 0)
        #expect(local1.index == 1 && global0.index == 0)
        let local0Symbol = table.intern(local0)
        #expect(string(table, local0Symbol) == "local0")
        #expect(table.provenance(of: local0Symbol) == .mangled)
        #expect(table.intern(local1) == spoof)
        #expect(table.provenance(of: spoof) == .mangled)
        let spoofAgain = intern(&table, "local1")
        #expect(spoofAgain == spoof)
        #expect(table.provenance(of: spoofAgain) == .mangled)
        #expect(table.provenance(of: original) == .source)

        // .reserved, unless the name embeds .source text.
        let wgslMin = table.intern(.fixed(.wgslMin))
        #expect(string(table, wgslMin) == "__wgslMin")
        #expect(table.provenance(of: wgslMin) == .reserved)
        #expect(intern(&table, "__wgslMin") == wgslMin)
        #expect(table.provenance(of: wgslMin) == .reserved)
        let globalSymbol = table.intern(global0)
        let arrayLength = table.intern(.arrayLength(of: globalSymbol))
        #expect(string(table, arrayLength) == "__global0_ArrayLength")
        #expect(table.provenance(of: arrayLength) == .reserved)
        let unmangled = table.intern(.arrayLength(of: original))
        #expect(string(table, unmangled) == "__position_ArrayLength")
        #expect(table.provenance(of: unmangled) == .source)
        let packed = table.intern(.packedStruct(of: wgslMin))
        #expect(table.provenance(of: packed) == .reserved)
        let external = table.intern(.externalTexture(of: Symbol(predeclaredIndex: 20) ?? original))
        #expect(string(table, external) == "__bool")
        #expect(table.provenance(of: external) == .reserved)

        // The type checker's predeclared values are .builtin, also when the source spelled them first.
        let workgroup = intern(&table, "workgroup")
        #expect(table.provenance(of: workgroup) == .source)
        #expect(table.intern(predeclaredValue: "workgroup") == workgroup)
        #expect(table.provenance(of: workgroup) == .builtin)
        #expect(intern(&table, "workgroup") == workgroup)
        #expect(table.provenance(of: workgroup) == .builtin)

        // .builtin is never downgraded or replaced.
        let vec4f = intern(&table, "vec4f")
        #expect(table.provenance(of: vec4f) == .builtin)
        #expect(table.intern("vec4f") == vec4f)
        #expect(table.provenance(of: vec4f) == .builtin)

        // .swizzle, through the type checker's proof only.
        let xyz = intern(&table, "xyz")
        #expect(table.provenance(of: xyz) == .source)
        guard case .success(let proof) = Swizzle.validate(xyz, table, vectorSize: 3) else {
            Issue.record("xyz is a valid swizzle of a vec3")
            return
        }
        #expect(proof.symbol == xyz)
        table.markSwizzle(xyz, proof)
        #expect(table.provenance(of: xyz) == .swizzle)
    }

    @Test
    func swizzleValidationFollowsTypeCheck() {
        var table = SymbolTable.predeclared
        func validate(_ text: String, _ vectorSize: UInt8) -> Result<[Int], Swizzle.Failure> {
            let symbol = intern(&table, text)
            return Swizzle.validate(symbol, table, vectorSize: vectorSize)
                .map { swizzle in
                    (0..<swizzle.count).map { swizzle.componentIndex(at: $0) }
                }
        }
        #expect(validate("x", 2) == .success([0]))
        #expect(validate("wzyx", 4) == .success([3, 2, 1, 0]))
        #expect(validate("rgba", 4) == .success([0, 1, 2, 3]))
        #expect(validate("bgr", 3) == .success([2, 1, 0]))
        #expect(validate("yy", 2) == .success([1, 1]))
        #expect(validate("z", 2) == .failure(.member))
        #expect(validate("w", 3) == .failure(.member))
        #expect(validate("a", 3) == .failure(.member))
        #expect(validate("xg", 4) == .failure(.member))
        #expect(validate("xq", 4) == .failure(.character))
        #expect(validate("X", 4) == .failure(.character))
        #expect(validate("xyzwx", 4) == .failure(.size))
        #expect(validate("rgbar", 4) == .failure(.size))
        // C++ order: every character first, then the member checks, then the size.
        #expect(validate("xrxyzq", 2) == .failure(.character))
        #expect(validate("xyzwxr", 2) == .failure(.member))
        // TypeCheck.cpp tests each code unit truncated to a char: U+0178 passes as 'x', U+0167 as 'g'.
        #expect(validate("\u{178}", 2) == .success([0]))
        #expect(validate("\u{167}\u{172}", 2) == .success([1, 0]))
        #expect(validate("\u{178}r", 2) == .failure(.member))
    }

    @Test
    func mangledNamesNumberEachKindFromZero() {
        var table = SymbolTable.predeclared
        var mangler = Mangler.makeForTesting()
        let name = intern(&table, "S")
        var rendered: [String] = []
        for kind in MangledName.Kind.allCases {
            rendered.append(spelling(&table, mangler.makeMangledName(name, kind)))
        }
        #expect(rendered == ["type0", "local0", "global0", "parameter0", "function0", "field0"])
        for _ in 0..<9 {
            _ = mangler.makeMangledName(name, .field)
        }
        let field10 = mangler.makeMangledName(name, .field)
        #expect(field10.index == 10)
        #expect(spelling(&table, field10) == "field10")
        #expect(spelling(&table, mangler.makeMangledName(name, .type)) == "type1")
        for kind in MangledName.Kind.allCases {
            #expect(isMangledShape(spelling(&table, mangler.makeMangledName(name, kind))))
        }
    }

    // A mangled name interned while no hashed text spells one is recorded by its kind and index: every lookup by text finds
    // that symbol, and a name that source text spelled first is that text's symbol.
    @Test
    func mangledNamesWithoutAHashAreFoundByText() {
        var table = SymbolTable.predeclared
        var mangler = Mangler.makeForTesting()
        let user = intern(&table, "user")
        let type0Name = mangler.makeMangledName(user, .type)
        let type0 = table.intern(type0Name)
        #expect(table.intern(type0Name) == type0)
        let field0 = table.intern(mangler.makeMangledName(user, .field))
        let field1 = table.intern(mangler.makeMangledName(user, .field))
        #expect(string(table, type0) == "type0")
        #expect(string(table, field1) == "field1")
        let count = table.count

        #expect(intern(&table, "type0") == type0)
        let latin1Field0 = latin1("field0")
        #expect(table.intern(latin1Field0, 0..<latin1Field0.count) == field0)
        #expect(table.intern("field1") == field1)
        #expect(table.intern(ContiguousArray("type0".utf16)) == type0)
        #expect(table.intern(predeclaredValue: "field0") == field0)
        #expect(table.provenance(of: field0) == .mangled)
        #expect(table.count == count)

        let leadingZero = intern(&table, "field01")
        #expect(leadingZero != field1)
        #expect(table.provenance(of: leadingZero) == .source)
        let field2Text = intern(&table, "field2")
        #expect(table.provenance(of: field2Text) == .source)
        #expect(table.intern(mangler.makeMangledName(user, .field)) == field2Text)
        #expect(table.provenance(of: field2Text) == .mangled)
        let field3 = table.intern(mangler.makeMangledName(user, .field))
        #expect(string(table, field3) == "field3")
        #expect(intern(&table, "field3") == field3)
        #expect(intern(&table, "type0") == type0)
        #expect(table.count == count + 3)

        // Names interned out of their index order take the hashed path, and every path still finds one symbol per text.
        var other = SymbolTable.predeclared
        var numbering = Mangler.makeForTesting()
        let names = (0..<4).map { _ in numbering.makeMangledName(user, .local) }
        let local3 = other.intern(names[3])
        let local0 = other.intern(names[0])
        let local1 = other.intern(names[1])
        #expect(string(other, local3) == "local3" && string(other, local0) == "local0" && string(other, local1) == "local1")
        #expect(other.intern(names[3]) == local3 && other.intern(names[0]) == local0)
        #expect(other.intern(ContiguousArray("local3".utf16)) == local3)
        #expect(intern(&other, "local1") == local1)
        #expect(other.provenance(of: local1) == .mangled)
    }

    // L-MSL-3: every `__` spelling of the C++ has a ReservedName case, and no ReservedName spelling collides with a
    // mangled name or a predeclared symbol.
    @Test
    func reservedNamesCoverEveryCxxSpelling() {
        var table = SymbolTable.predeclared
        var mangler = Mangler.makeForTesting()
        let user = intern(&table, "user")
        let global = table.intern(mangler.makeMangledName(user, .global))
        let function = table.intern(mangler.makeMangledName(user, .function))
        let type = table.intern(mangler.makeMangledName(user, .type))

        let fixed = ReservedName.Fixed.allCases.map { "\($0.spelling)" }
        #expect(Set(fixed).count == fixed.count)
        let cxxFixed = cxxFixedSpellings.map(\.0)
        #expect(Set(cxxFixed).count == cxxFixed.count)
        for (spelling, site) in cxxFixedSpellings {
            #expect(fixed.contains(spelling), "\(spelling) (\(site)) has no ReservedName.Fixed case")
        }
        for spelling in fixed {
            #expect(cxxFixed.contains(spelling), "ReservedName.Fixed \(spelling) is not a C++ spelling")
        }
        #expect(spellings(&table, ReservedName.Fixed.allCases.map { .fixed($0) }) == fixed)

        let parameterised: [ReservedName] = [
            .arrayLength(of: global),
            .packedStruct(of: type),
            .argumentBufferPlaceholder(4_294_967_295),
            .externalTexture(of: global),
            .loopIndex(depth: 0),
            .argumentBufferParameter(group: 3),
            .argumentBufferStruct(entryPoint: 12, group: 3),
            .entryPointInputStruct(of: function),
            .entryPointInputParameter(of: function),
            .stageOutputStruct(of: type, .fragment),
            .stageOutputStruct(of: function, .vertex),
            .builtinParameter(7),
            .evaluationOrderTemporary(0),
            .outlinedConstant(42),
        ]
        let rendered = spellings(&table, parameterised)
        #expect(
            rendered == [
                "__global0_ArrayLength",
                "__type0_Packed",
                "__ArgumentBufferPlaceholder_4294967295",
                "__global0",
                "__i0",
                "__ArgumentBuffer_3",
                "__ArgumentBufferT_12_3",
                "__function0_inT",
                "__function0_in",
                "__type0_FragmentOutput",
                "__function0_VertexOutput",
                "__builtin7",
                "__evalOrder0",
                "__wgslConst42",
            ]
        )
        for (prefix, site) in cxxPrefixSpellings {
            #expect(
                rendered.contains { $0.hasPrefix(prefix) && $0 != prefix } || fixed.contains(prefix),
                "\(prefix) (\(site)) has no ReservedName case"
            )
        }

        let all = fixed + rendered
        #expect(Set(all).count == all.count)
        for spelling in all {
            #expect(spelling.hasPrefix("__"), "\(spelling)")
            #expect(!isLettersThenDigits(spelling), "\(spelling)")
            #expect(!isMangledShape(spelling), "\(spelling)")
            let symbol = intern(&table, spelling)
            #expect(symbol.predeclaredIndex == nil, "\(spelling)")
            #expect(table.provenance(of: symbol) == .reserved, "\(spelling)")
        }
    }

    @Test
    func identifierMakers() {
        var table = SymbolTable.predeclared
        let symbol = intern(&table, "f")
        let span = SourceSpan(line: 2, lineOffset: 3, offset: 10, length: 1)
        #expect(Identifier.make(symbol) == Identifier(span: .empty, symbol: symbol))
        #expect(Identifier.makeWithSpan(span, symbol).span == span)
        #expect(Identifier.makeWithSpan(span, symbol).symbol == symbol)
    }
}
