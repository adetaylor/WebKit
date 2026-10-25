// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

/// The only spelling of a user-declared entity that reaches MSL: a per-kind prefix and index.
///
/// Its initializer is fileprivate: only `Mangler` mints one, and `SymbolTable.intern(_: MangledName)` is the only way to
/// give a symbol `.mangled` provenance.
@_spi(Testing)
public struct MangledName: BitwiseCopyable, Equatable, Sendable {
    @_spi(Testing)
    public enum Kind: UInt8, CaseIterable, BitwiseCopyable, Sendable {
        case type
        case local
        case global
        case parameter
        case function
        case field
    }
    static let numberOfKinds = 6

    @_spi(Testing)
    public let kind: Kind
    @_spi(Testing)
    public let index: UInt32
    @_spi(Testing)
    public let originalName: Symbol

    fileprivate init(kind: Kind, index: UInt32, originalName: Symbol) {
        self.kind = kind
        self.index = index
        self.originalName = originalName
    }

    // C++ toString(), appended to `codeUnits` in one append.
    func appendText(to codeUnits: inout ContiguousArray<UInt16>) {
        codeUnits.append(contentsOf: MangledNameText(kind, index))
    }
}

// The prefix of a kind and the decimal digits of an index, as code units.
private struct MangledNameText: RandomAccessCollection {
    // The prefix's ASCII bytes, lowest first (C++ toString(MangledName::Kind)).
    private let prefixLow: UInt64
    private let prefixHigh: UInt64
    private let prefixCount: Int
    // The digits, the least significant in the lowest nibble.
    private let digits: UInt64
    let endIndex: Int

    init(_ kind: MangledName.Kind, _ index: UInt32) {
        switch kind {
        case .type:
            (prefixLow, prefixHigh, prefixCount) = (0x6570_7974, 0, 4)
        case .local:
            (prefixLow, prefixHigh, prefixCount) = (0x6C_6163_6F6C, 0, 5)
        case .global:
            (prefixLow, prefixHigh, prefixCount) = (0x6C61_626F_6C67, 0, 6)
        case .parameter:
            (prefixLow, prefixHigh, prefixCount) = (0x6574_656D_6172_6170, 0x72, 9)
        case .function:
            (prefixLow, prefixHigh, prefixCount) = (0x6E6F_6974_636E_7566, 0, 8)
        case .field:
            (prefixLow, prefixHigh, prefixCount) = (0x64_6C65_6966, 0, 5)
        }
        var digits: UInt64 = 0
        var digitCount = 0
        var remaining = index
        repeat {
            digits |= UInt64(remaining % 10) &<< UInt64(truncatingIfNeeded: 4 &* digitCount)
            remaining /= 10
            digitCount &+= 1
        } while remaining != 0
        self.digits = digits
        endIndex = prefixCount &+ digitCount
    }

    var startIndex: Int { 0 }

    @inline(__always)
    subscript(position: Int) -> UInt16 {
        if position < prefixCount {
            let word = position < 8 ? prefixLow : prefixHigh
            return UInt16(truncatingIfNeeded: word &>> UInt64(truncatingIfNeeded: (position & 7) &* 8)) & 0xFF
        }
        let shift = UInt64(truncatingIfNeeded: 4 &* (endIndex &- 1 &- position))
        return 0x30 &+ UInt16(truncatingIfNeeded: digits &>> shift) & 0xF
    }
}

extension MangledName {
    /// The kind and index whose spelling `units[range]` is, if any: a kind's prefix and the index in decimal, as
    /// `appendText(to:)` writes them.
    static func kindAndIndex(_ units: borrowing ContiguousArray<UInt16>, _ range: Range<Int>) -> (kind: Kind, index: UInt32)? {
        guard range.count >= 5 && isDecimalDigit(units[range.upperBound - 1]) else {
            return nil
        }
        let kind: Kind
        switch units[range.lowerBound] {
        case 0x74:
            kind = .type
        case 0x6C:
            kind = .local
        case 0x67:
            kind = .global
        case 0x70:
            kind = .parameter
        case 0x66:
            kind = units[range.lowerBound + 1] == 0x75 ? .function : .field
        default: // lint-exempt(L-ENUM-1): a code unit
            return nil
        }
        let prefix = mangledNamePrefixes[Int(kind.rawValue)]
        guard range.count > prefix.count else {
            return nil
        }
        var position = 0
        while position < prefix.count {
            guard units[range.lowerBound + position] == prefix[position] else {
                return nil
            }
            position += 1
        }
        let digitsStart = range.lowerBound + prefix.count
        if units[digitsStart] == 0x30 && range.upperBound - digitsStart > 1 {
            return nil
        }
        var value: UInt64 = 0
        position = digitsStart
        while position < range.upperBound {
            guard isDecimalDigit(units[position]) else {
                return nil
            }
            value = value * 10 + UInt64(units[position] - 0x30)
            guard value <= UInt64(UInt32.max) else {
                return nil
            }
            position += 1
        }
        return (kind, UInt32(value))
    }

    private static func isDecimalDigit(_ codeUnit: UInt16) -> Bool {
        codeUnit >= 0x30 && codeUnit <= 0x39
    }
}

private let mangledNamePrefixes: [ContiguousArray<UInt16>] = MangledName.Kind.allCases.map { kind in
    switch kind {
    case .type: ContiguousArray("type".utf16)
    case .local: ContiguousArray("local".utf16)
    case .global: ContiguousArray("global".utf16)
    case .parameter: ContiguousArray("parameter".utf16)
    case .function: ContiguousArray("function".utf16)
    case .field: ContiguousArray("field".utf16)
    }
}

/// The per-kind counters of one `mangleNames` run (C++ `NameManglerVisitor::m_indexPerType`), and the only mint of
/// `MangledName`.
///
/// `~Copyable`, so the numbering cannot be forked or replayed, and made only in this file (by the pass) or by
/// `makeForTesting()`, so no other code can start a second numbering.
@_spi(Testing)
public struct Mangler: ~Copyable {
    private var indexPerType: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0)

    fileprivate init() {}

    /// A fresh numbering for unit tests; the module's only `Mangler` is the one the mangleNames pass makes.
    @_spi(Testing)
    public static func makeForTesting() -> Mangler {
        Mangler()
    }

    @_spi(Testing)
    public mutating func makeMangledName(_ name: Symbol, _ kind: MangledName.Kind) -> MangledName {
        let index: UInt32
        switch kind {
        case .type:
            index = indexPerType.0
            indexPerType.0 = index &+ 1
        case .local:
            index = indexPerType.1
            indexPerType.1 = index &+ 1
        case .global:
            index = indexPerType.2
            indexPerType.2 = index &+ 1
        case .parameter:
            index = indexPerType.3
            indexPerType.3 = index &+ 1
        case .function:
            index = indexPerType.4
            indexPerType.4 = index &+ 1
        case .field:
            index = indexPerType.5
            indexPerType.5 = index &+ 1
        }
        return MangledName(kind: kind, index: index, originalName: name)
    }
}

// A MangledName and the symbol it was interned as. Interning is idempotent, so a reference reuses the symbol.
private struct MangledSymbol {
    let name: MangledName
    let symbol: Symbol
}

private struct NameManglerVisitor: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<MangledSymbol>()

    private typealias NameMap = SymbolMap<MangledSymbol>

    private var structFieldMapping = SideTable<StructureID, NameMap>()
    private var mangler = Mangler()

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func run() {
        visitShaderModule()
    }

    mutating func visit(_ function: FunctionID) {
        introduceVariable(shaderModule[function].name, .function)
        scopedVisit(function)
    }

    mutating func visit(_ parameter: ParameterID) {
        visit(shaderModule[parameter].typeName)
        introduceVariable(shaderModule[parameter].name, .parameter)
    }

    mutating func visit(_ structure: StructureID) {
        introduceVariable(shaderModule[structure].name, .type)

        var fieldMap = NameMap()
        var members = shaderModule.cursor(shaderModule[structure].members)
        while let member = shaderModule.next(&members) {
            visit(shaderModule[member].type)
            let name = shaderModule[member].name
            let mangledName = makeMangledName(shaderModule.symbol(of: name), .field)
            let mangledSymbol = shaderModule.symbols.intern(mangledName)
            fieldMap.add(shaderModule.symbol(of: name), MangledSymbol(name: mangledName, symbol: mangledSymbol))
            shaderModule.replace(name, keepingSpanWith: mangledSymbol)
        }
        let isNewEntry = structFieldMapping.add(structure, fieldMap)
        assert(isNewEntry)
    }

    mutating func visit(_ variable: VariableID) {
        visitVariableDeclaration(variable, .global)
    }

    mutating func visit(_ variable: VariableStatement, _ id: StatementID) {
        visitVariableDeclaration(variable.variable, .local)
    }

    private mutating func visitVariableDeclaration(_ variable: VariableID, _ kind: MangledName.Kind) {
        visitChildren(variable)

        introduceVariable(shaderModule[variable].name, kind)
    }

    mutating func visit(_ identifier: IdentifierExpression, _ id: ExpressionID) {
        readVariable(identifier.identifier)
    }

    mutating func visit(_ access: FieldAccessExpression, _ id: ExpressionID) {
        visitChildren(access, id)

        var baseType = shaderModule.inferredType(of: access.base)
        if let reference = shaderModule.types.getIf(Types.Reference.self, baseType) {
            baseType = reference.element
        }
        if let pointer = shaderModule.types.getIf(Types.Pointer.self, baseType) {
            baseType = pointer.element
        }
        guard let structType = shaderModule.types.getIf(Types.Struct.self, baseType) else {
            return
        }
        guard let structMap = structFieldMapping.find(structType.structure) else {
            wgslFatal("field access of a structure that NameManglerVisitor has not visited", cppSite: "MangleNames.cpp:172")
        }

        guard let field = structMap.find(shaderModule.symbol(of: access.fieldName)) else {
            // DEV-08: C++ asserts in Debug and reads the end iterator in release.
            wgslFatal("field access of a field that the structure does not declare", cppSite: "MangleNames.cpp:175")
        }
        shaderModule.replace(access.fieldName, keepingSpanWith: field.symbol)
    }

    private mutating func introduceVariable(_ name: IdentifierID, _ kind: MangledName.Kind) {
        let symbol = shaderModule.symbol(of: name)
        let mangledName = makeMangledName(symbol, kind)
        let mangledSymbol = MangledSymbol(name: mangledName, symbol: shaderModule.symbols.intern(mangledName))
        guard let mangled = context.introduceVariable(symbol, mangledSymbol) else {
            // DEV-08: C++ asserts in Debug and dereferences nullptr in release.
            wgslFatal("a redeclaration reached NameManglerVisitor", cppSite: "MangleNames.cpp:182")
        }
        shaderModule.replace(name, keepingSpanWith: mangled.symbol)
    }

    private mutating func makeMangledName(_ name: Symbol, _ kind: MangledName.Kind) -> MangledName {
        mangler.makeMangledName(name, kind)
    }

    private mutating func readVariable(_ name: IdentifierID) {
        if let mangled = context.readVariable(shaderModule.symbol(of: name)) {
            shaderModule.replace(name, keepingSpanWith: mangled.symbol)
        }
    }
}

@_spi(Testing)
public func mangleNames(_ shaderModule: inout ShaderModule) {
    var visitor = NameManglerVisitor(shaderModule: shaderModule)
    visitor.run()
    shaderModule = visitor.shaderModule
}
