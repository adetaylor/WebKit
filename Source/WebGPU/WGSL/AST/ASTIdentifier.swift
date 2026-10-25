// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

/// C++ `AST::Identifier` (a by-value node): a span and the interned identifier text.
///
/// One arena slot per owning node field, so an `IdentifierID` is the analogue of C++ `&node.name()`.
@_spi(Testing)
public struct Identifier: BitwiseCopyable, Equatable, Sendable {
    @_spi(Testing)
    public var span: SourceSpan
    @_spi(Testing)
    public var symbol: Symbol

    @_spi(Testing)
    public init(span: SourceSpan, symbol: Symbol) {
        self.span = span
        self.symbol = symbol
    }

    @_spi(Testing)
    public static func make(_ symbol: Symbol) -> Identifier {
        Identifier(span: .empty, symbol: symbol)
    }

    @_spi(Testing)
    public static func makeWithSpan(_ span: SourceSpan, _ symbol: Symbol) -> Identifier {
        Identifier(span: span, symbol: symbol)
    }
}

/// Interned identifier text: the C++ `String` of an `AST::Identifier`.
///
/// Equality is code-unit equality. Latin-1 source text is zero-extended, so an 8-bit and a 16-bit spelling of the same
/// text are the same symbol (`WTF::equal` across representations); there is no normalisation. Only `SymbolTable` mints
/// symbols, and indices are never observable: they are never printed and never iterated.
@_spi(Testing)
public struct Symbol: Hashable, BitwiseCopyable, Sendable {
    fileprivate let raw: UInt32

    fileprivate init(raw: UInt32) {
        self.raw = raw
    }

    /// The predeclared symbol `builtin` names, the same in every module's table.
    init(_ builtin: BuiltinSymbols) {
        raw = builtin.rawValue
    }

    static func == (lhs: Symbol, rhs: BuiltinSymbols) -> Bool {
        lhs.raw == rhs.rawValue
    }

    static func != (lhs: Symbol, rhs: BuiltinSymbols) -> Bool {
        lhs.raw != rhs.rawValue
    }

    /// The predeclared symbol at `predeclaredIndex`, the same in every module's table, or nil past the predeclared ones.
    @_spi(Testing)
    public init?(predeclaredIndex: Int) {
        guard predeclaredIndex >= 0 && predeclaredIndex < predeclaredSymbolNames.count else {
            return nil
        }
        raw = UInt32(predeclaredIndex)
    }

    /// The index in `predeclaredSymbolNames` (the generated `BuiltinSymbols` raw value), or nil for a module's own symbol.
    @_spi(Testing)
    public var predeclaredIndex: Int? {
        Int(raw) < predeclaredSymbolNames.count ? Int(raw) : nil
    }

    /// The builtin declaration this symbol names, as an index into the generated table, or nil (the C++ lookup of the
    /// identifier in the TypeChecker's builtin HashMap).
    @_spi(Testing)
    public var builtinDeclarationIndex: Int? {
        raw < BuiltinSymbols.builtinDeclarationCount ? Int(raw) : nil
    }

    /// The interning order in the module's table, dense from 0 (ContextProvider's per-symbol binding stacks).
    var index: Int { Int(raw) }
}

/// Where a symbol's text comes from.
///
/// Only text minted as mangled, reserved, builtin or swizzle may reach MSL as an identifier; the writer's identifier sink
/// refuses `.source`. Two symbols with equal text are the same symbol, so a mint upgrades `.source` text and never
/// downgrades.
@_spi(Testing)
public enum SymbolProvenance: UInt8, BitwiseCopyable, Sendable {
    /// User text, and compiler-made names that never reach MSL as identifiers.
    case source
    /// Set only by `SymbolTable.intern(_: MangledName)`.
    case mangled
    /// Set only by `SymbolTable.intern(_: ReservedName)`.
    case reserved
    /// The predeclared symbols.
    case builtin
    /// Set only by `SymbolTable.markSwizzle(_:_:)`.
    case swizzle
}

/// The per-module identifier interner over UTF-16 code units.
///
/// The lookup tables are private open-addressing tables over a keyed hash of the code units (`KeyedHasher`, seeded per
/// process, so crafted identifiers cannot flood one probe sequence), rehashed at 50% load; they are never iterated, and
/// a symbol's index is its interning order, so the seed is never observable. Every table starts as a copy of
/// `predeclared`, so predeclared symbol i is `BuiltinSymbols(rawValue: i)` in every module: the predeclared symbols are a
/// level that every module shares and none mutates, and a module's own symbols follow them in a level of its own. A
/// mangled name, while no hashed text is the spelling of one, is found by its kind and index instead of its text, and every
/// lookup by text checks those too. Append-only: a CompilationScope rollback keeps every symbol (interning is idempotent).
@_spi(Testing)
public struct SymbolTable: Sendable {
    private struct SymbolRecord: Sendable {
        // The end of the symbol's text in its level's codeUnits; the text starts at the previous symbol's end.
        let end: UInt32
        // So a rehash hashes nothing.
        let hash: UInt32
        var provenance: SymbolProvenance
        // False for a mangled name found by its kind and index instead (`UnhashedMangledNames`).
        let isHashed: Bool
    }

    private struct Level: Sendable {
        var codeUnits: ContiguousArray<UInt16> = []
        var records: ContiguousArray<SymbolRecord> = []
        // 0 = empty, else the hash in the high half and the level index + 1 in the low half: a probe compares text only on
        // a full hash match, and reads no record before one.
        var buckets: ContiguousArray<UInt64> = []
        // Whether a hashed symbol's text is the spelling of a mangled name (`MangledName.kindAndIndex`): never in the
        // predeclared level, and in a module's own level only for source text such as `type0`, so a mangled name's
        // intern usually probes neither.
        var holdsMangledSpelling = false
        var hashedCount = 0

        var count: Int { records.count }

        func range(of index: Int) -> Range<Int> {
            Int(index == 0 ? 0 : records[index - 1].end)..<Int(records[index].end)
        }

        // The level index of `units[range]`, else the bucket where it goes (only meaningful when `buckets` is not empty).
        func find(_ hash: Int, _ units: borrowing ContiguousArray<UInt16>, _ range: Range<Int>) -> (index: Int?, slot: Int) {
            guard !buckets.isEmpty else {
                return (nil, 0)
            }
            let mask = buckets.count - 1
            let hashBits = UInt64(UInt32(truncatingIfNeeded: hash)) &<< 32
            var slot = hash & mask
            while buckets[slot] != 0 {
                let bucket = buckets[slot]
                if bucket & 0xFFFF_FFFF_0000_0000 == hashBits {
                    let candidate = Int(truncatingIfNeeded: bucket & 0xFFFF_FFFF) - 1
                    if equals(candidate, units, range) {
                        return (candidate, slot)
                    }
                }
                slot = (slot + 1) & mask
            }
            return (nil, slot)
        }

        func find(_ hash: Int, _ source: borrowing SourceText, _ range: Range<Int>) -> (index: Int?, slot: Int) {
            guard !buckets.isEmpty else {
                return (nil, 0)
            }
            let mask = buckets.count - 1
            let hashBits = UInt64(UInt32(truncatingIfNeeded: hash)) &<< 32
            var slot = hash & mask
            while buckets[slot] != 0 {
                let bucket = buckets[slot]
                if bucket & 0xFFFF_FFFF_0000_0000 == hashBits {
                    let candidate = Int(truncatingIfNeeded: bucket & 0xFFFF_FFFF) - 1
                    if source.codeUnitsEqual(range, codeUnits, self.range(of: candidate)) {
                        return (candidate, slot)
                    }
                }
                slot = (slot + 1) & mask
            }
            return (nil, slot)
        }

        private func equals(_ index: Int, _ units: borrowing ContiguousArray<UInt16>, _ unitsRange: Range<Int>) -> Bool {
            let range = range(of: index)
            guard range.count == unitsRange.count else {
                return false
            }
            var offset = 0
            while offset < range.count {
                guard codeUnits[range.lowerBound + offset] == units[unitsRange.lowerBound + offset] else {
                    return false
                }
                offset += 1
            }
            return true
        }

        // The text is already appended to codeUnits; `slot` is the empty bucket `find` returned.
        mutating func append(at slot: Int, _ hash: Int, _ provenance: SymbolProvenance) -> Int {
            let index = count
            if records.capacity == 0 {
                records.reserveCapacity(Self.initialSymbolCapacity)
            }
            records.append(
                SymbolRecord(end: UInt32(codeUnits.count), hash: UInt32(truncatingIfNeeded: hash), provenance: provenance, isHashed: true)
            )
            hashedCount += 1
            if !holdsMangledSpelling && MangledName.kindAndIndex(codeUnits, range(of: index)) != nil {
                holdsMangledSpelling = true
            }
            if buckets.isEmpty || 2 * hashedCount > buckets.count {
                rehash(buckets.isEmpty ? 2 * Self.initialSymbolCapacity : 2 * buckets.count)
            } else {
                buckets[slot] = Self.bucket(UInt32(truncatingIfNeeded: hash), index)
            }
            return index
        }

        // The text is already appended to codeUnits; the symbol is not hashed.
        mutating func appendUnhashed(_ provenance: SymbolProvenance) -> Int {
            let index = count
            if records.capacity == 0 {
                records.reserveCapacity(Self.initialSymbolCapacity)
            }
            records.append(SymbolRecord(end: UInt32(codeUnits.count), hash: 0, provenance: provenance, isHashed: false))
            return index
        }

        var hasUnhashed: Bool { hashedCount != records.count }

        // Every module interns about seventy builtin names that are not predeclared (TypeChecker.declareBuiltins).
        private static var initialSymbolCapacity: Int { 128 }

        mutating func reserveCodeUnits(_ count: Int) {
            if codeUnits.count + count > codeUnits.capacity {
                codeUnits.reserveCapacity(Swift.max(codeUnits.count + count, 2 * codeUnits.capacity, 8 * Self.initialSymbolCapacity))
            }
        }

        private static func bucket(_ hash: UInt32, _ index: Int) -> UInt64 {
            UInt64(hash) &<< 32 | UInt64(index + 1)
        }

        private mutating func rehash(_ bucketCount: Int) {
            var newBuckets = ContiguousArray(repeatElement(UInt64(0), count: bucketCount))
            let mask = bucketCount - 1
            var index = 0
            while index < count {
                guard records[index].isHashed else {
                    index += 1
                    continue
                }
                let hash = records[index].hash
                var slot = Int(truncatingIfNeeded: hash) & mask
                while newBuckets[slot] != 0 {
                    slot = (slot + 1) & mask
                }
                newBuckets[slot] = Self.bucket(hash, index)
                index += 1
            }
            buckets = newBuckets
        }

        func longestProbeRun() -> Int {
            var longest = 0
            var run = 0
            var index = 0
            while index < 2 * buckets.count {
                if buckets[index & (buckets.count - 1)] == 0 {
                    run = 0
                } else {
                    run += 1
                    if run > longest {
                        longest = run
                    }
                }
                index += 1
            }
            return longest
        }
    }

    // The predeclared symbols, shared by every module's table: a module's first intern copies nothing.
    private let base: Level
    // This table's own symbols, from index `base.count`.
    private var own = Level()
    // The names cachedName(of:) made; a symbol's text never changes.
    private var names = SymbolMap<Name>()
    // The symbol of each ReservedName interned so far: GlobalVariableRewriter interns the same names in every prepare.
    private var reservedNames = SmallKeyMap<ReservedName.MemoKey, Symbol>()
    // The mangled names interned without a hash.
    private var unhashedMangledNames = UnhashedMangledNames()

    private init(base: Level) {
        self.base = base
    }

    /// The generated `predeclaredSymbolNames` (the builtin declaration names in table order, then the primitive-struct
    /// field names and the type-alias names that are not builtin declaration names), interned once per process.
    @_spi(Testing)
    public static let predeclared: SymbolTable = {
        var table = SymbolTable(base: Level())
        var index = 0
        while index < predeclaredSymbolNames.count {
            let symbol = table.intern(ContiguousArray(predeclaredSymbolNames[index].description.utf16), .builtin)
            guard Int(symbol.raw) == index else {
                wgslFatal("duplicate predeclared symbol name", cppSite: "TypeCheck.cpp:487")
            }
            index += 1
        }
        return SymbolTable(base: table.own)
    }()

    @_spi(Testing)
    public var count: Int { base.count + own.count }

    // MARK: - Interning

    /// An identifier of the source (the Lexer), Latin-1 or UTF-16: `.source` unless the same text was minted.
    @_spi(Testing)
    public mutating func intern(_ source: borrowing SourceText, _ range: Range<Int>) -> Symbol {
        let hash = source.symbolHash(range)
        if let index = base.find(hash, source, range).index {
            return Symbol(raw: UInt32(index))
        }
        let (index, slot) = own.find(hash, source, range)
        if let index {
            return Symbol(raw: UInt32(base.count + index))
        }
        if own.hasUnhashed {
            var text = ContiguousArray<UInt16>()
            source.appendCodeUnits(range, to: &text)
            if let symbol = unhashedMangledSymbol(text, 0..<text.count) {
                return symbol
            }
        }
        own.reserveCodeUnits(range.count)
        source.appendCodeUnits(range, to: &own.codeUnits)
        return Symbol(raw: UInt32(base.count + own.append(at: slot, hash, .source)))
    }

    /// A compiler-made ASCII name (C++ `AST::Identifier::make("…"_s)`): `.source` unless the same text was minted.
    ///
    /// A `"__…"` spelling is a `ReservedName`: interning one here is fatal.
    @_spi(Testing)
    public mutating func intern(_ text: StaticString) -> Symbol {
        let start = own.codeUnits.count
        own.reserveCodeUnits(text.utf8CodeUnitCount)
        own.codeUnits.append(contentsOf: text.description.utf16)
        let underscore = UInt16(UInt8(ascii: "_"))
        guard !(own.codeUnits.count - start >= 2 && own.codeUnits[start] == underscore && own.codeUnits[start + 1] == underscore)
        else {
            wgslFatal("a \"__\" spelling is a ReservedName", cppSite: "ASTIdentifier.h:38")
        }
        return internAppendedText(from: start, .source)
    }

    /// A predeclared value of the type checker's closed table (C++ `introduceValue(AST::Identifier::make("…"_s), …)`: the
    /// access modes, texel formats and address spaces), `.builtin` like the generated predeclared symbols: C++ prints such
    /// a name unchanged where the source uses it as a value, which only a phony assignment allows (`_ = workgroup;` is
    /// `(void)(workgroup);`, which Metal rejects).
    @_spi(Testing)
    public mutating func intern(predeclaredValue text: StaticString) -> Symbol {
        let start = own.codeUnits.count
        own.reserveCodeUnits(text.utf8CodeUnitCount)
        own.codeUnits.append(contentsOf: text.description.utf16)
        return internAppendedText(from: start, .builtin)
    }

    /// Text built at run time (C++ `AST::Identifier::make(type->toString())`): `.source` unless the same text was minted.
    @_spi(Testing)
    public mutating func intern(_ text: ContiguousArray<UInt16>) -> Symbol {
        intern(text, .source)
    }

    /// The only way to give text `.reserved` provenance.
    ///
    /// A name built from a `.source` symbol stays `.source`.
    @_spi(Testing)
    public mutating func intern(_ name: ReservedName) -> Symbol {
        // Interning is idempotent, and so is the provenance upgrade of a symbol that was made with this name's provenance.
        let memoKey = name.memoKey
        if let memoKey, let symbol = reservedNames.find(memoKey) {
            return symbol
        }
        let start = own.codeUnits.count
        var provenance = SymbolProvenance.reserved
        switch name.parts {
        case .fixed(let spelling):
            appendOwn(spelling)
        case .embedding(let prefix, let symbol, let suffix):
            provenance = appendOwn(prefix, symbol, suffix)
        case .numbered(let prefix, let number):
            appendOwn(prefix)
            appendOwnDecimal(number)
        case .twoNumbers(let prefix, let first, let separator, let second):
            appendOwn(prefix)
            appendOwnDecimal(first)
            appendOwn(separator)
            appendOwnDecimal(second)
        }
        let symbol = internAppendedText(from: start, provenance)
        if let memoKey {
            reservedNames.add(memoKey, symbol)
        }
        return symbol
    }

    /// The only way to give text `.mangled` provenance; `MangledName` is minted only by `Mangler`.
    @_spi(Testing)
    public mutating func intern(_ name: MangledName) -> Symbol {
        let unhashedCount = unhashedMangledNames.count(of: name.kind)
        if name.index < unhashedCount {
            return unhashedMangledSymbol(name.kind, name.index)
        }
        let start = own.codeUnits.count
        own.reserveCodeUnits(16)
        name.appendText(to: &own.codeUnits)
        if name.index > unhashedCount || base.holdsMangledSpelling || own.holdsMangledSpelling {
            return internAppendedText(from: start, .mangled)
        }
        // The kind's next index while no hashed text is the spelling of a mangled name, so this text is new: the symbol is
        // found by its kind and index, which is all a mangled name's spelling holds, instead of a hash of its text.
        let symbol = Symbol(raw: UInt32(base.count + own.appendUnhashed(.mangled)))
        unhashedMangledNames.append(name.kind, symbol)
        return symbol
    }

    /// Records that the type checker validated `symbol` as a vector swizzle.
    ///
    /// The proof must be for this symbol and spell its text.
    @_spi(Testing)
    public mutating func markSwizzle(_ symbol: Symbol, _ proof: Swizzle) {
        guard proof.symbol == symbol && proof.spells(symbol, self) else {
            wgslFatal("swizzle proof for another symbol", cppSite: "TypeCheck.cpp:2133")
        }
        upgrade(symbol.raw, .swizzle)
    }

    // MARK: - Readers

    @_spi(Testing)
    public func provenance(of symbol: Symbol) -> SymbolProvenance {
        let index = Int(symbol.raw)
        return index < base.count ? base.records[index].provenance : own.records[index - base.count].provenance
    }

    /// Whether the text of `symbol` is `source[range]`.
    func spells(_ symbol: Symbol, _ source: borrowing SourceText, _ range: Range<Int>) -> Bool {
        let index = Int(symbol.raw)
        if index < base.count {
            return source.codeUnitsEqual(range, base.codeUnits, base.range(of: index))
        }
        return source.codeUnitsEqual(range, own.codeUnits, own.range(of: index - base.count))
    }

    @_spi(Testing)
    public func length(of symbol: Symbol) -> Int {
        let index = Int(symbol.raw)
        return index < base.count ? base.range(of: index).count : own.range(of: index - base.count).count
    }

    @_spi(Testing)
    public func codeUnit(of symbol: Symbol, at index: Int) -> UInt16 {
        let symbolIndex = Int(symbol.raw)
        let isBase = symbolIndex < base.count
        let range = isBase ? base.range(of: symbolIndex) : own.range(of: symbolIndex - base.count)
        guard index >= 0 && index < range.count else {
            wgslFatal("code unit index out of range", cppSite: "StringImpl.h:1206")
        }
        return isBase ? base.codeUnits[range.lowerBound + index] : own.codeUnits[range.lowerBound + index]
    }

    /// A copy of the text, indexed from 0.
    @_spi(Testing)
    public func codeUnits(of symbol: Symbol) -> ContiguousArray<UInt16> {
        var units = ContiguousArray<UInt16>()
        appendCodeUnits(of: symbol, to: &units)
        return units
    }

    @_spi(Testing)
    public func appendCodeUnits(of symbol: Symbol, to units: inout ContiguousArray<UInt16>) {
        let index = Int(symbol.raw)
        if index < base.count {
            units.append(contentsOf: base.codeUnits[base.range(of: index)])
        } else {
            units.append(contentsOf: own.codeUnits[own.range(of: index - base.count)])
        }
    }

    /// Appends the text of `symbol` to `bytes`, one byte per code unit, looking its range up once (the writer's identifier sink);
    /// false at the first code unit that is not ASCII.
    func appendASCII(of symbol: Symbol, to bytes: inout ContiguousArray<UInt8>) -> Bool {
        let index = Int(symbol.raw)
        if index < base.count {
            return Self.appendASCII(base.codeUnits, base.range(of: index), to: &bytes)
        }
        return Self.appendASCII(own.codeUnits, own.range(of: index - base.count), to: &bytes)
    }

    private static func appendASCII(
        _ codeUnits: borrowing ContiguousArray<UInt16>,
        _ range: Range<Int>,
        to bytes: inout ContiguousArray<UInt8>
    ) -> Bool {
        var position = range.lowerBound
        while position < range.upperBound {
            let codeUnit = codeUnits[position]
            guard codeUnit < 0x80 else {
                return false
            }
            bytes.append(UInt8(truncatingIfNeeded: codeUnit))
            position &+= 1
        }
        return true
    }

    /// Stages the text of `symbol` in `sink` eight bytes at a time when it is ASCII; false, with nothing staged, otherwise.
    func stageASCII(of symbol: Symbol, into sink: inout ByteSink) -> Bool {
        let index = Int(symbol.raw)
        if index < base.count {
            return Self.stageASCII(base.codeUnits, base.range(of: index), into: &sink)
        }
        return Self.stageASCII(own.codeUnits, own.range(of: index - base.count), into: &sink)
    }

    private static func stageASCII(
        _ codeUnits: borrowing ContiguousArray<UInt16>,
        _ range: Range<Int>,
        into sink: inout ByteSink
    ) -> Bool {
        // Up to sixteen code units (nearly every mangled name; longer ones, up to nineteen as in parameter4294967295, take
        // the general path below) are checked and packed in one pass, and staged once they are known to be ASCII.
        if range.count <= 16 {
            var low: UInt64 = 0
            var high: UInt64 = 0
            var allBits: UInt16 = 0
            var position = range.lowerBound
            var shift: UInt64 = 0
            let lowEnd = range.count < 8 ? range.upperBound : range.lowerBound &+ 8
            while position < lowEnd {
                let codeUnit = codeUnits[position]
                allBits |= codeUnit
                low |= UInt64(codeUnit) &<< shift
                shift &+= 8
                position &+= 1
            }
            shift = 0
            while position < range.upperBound {
                let codeUnit = codeUnits[position]
                allBits |= codeUnit
                high |= UInt64(codeUnit) &<< shift
                shift &+= 8
                position &+= 1
            }
            guard allBits < 0x80 else {
                return false
            }
            if range.count > 8 {
                sink.stage(low, 8)
                sink.stage(high, range.count &- 8)
            } else if range.count > 0 {
                sink.stage(low, range.count)
            }
            return true
        }
        var position = range.lowerBound
        var allBits: UInt16 = 0
        while position < range.upperBound {
            allBits |= codeUnits[position]
            position &+= 1
        }
        guard allBits < 0x80 else {
            return false
        }
        position = range.lowerBound
        while position < range.upperBound {
            let count = range.upperBound &- position < 8 ? range.upperBound &- position : 8
            var packed: UInt64 = 0
            var shift: UInt64 = 0
            var remaining = count
            while remaining > 0 {
                packed |= UInt64(codeUnits[position]) &<< shift
                shift &+= 8
                position &+= 1
                remaining &-= 1
            }
            sink.stage(packed, count)
        }
        return true
    }

    /// The text for a message: lossless, lone surrogates included.
    @_spi(Testing)
    public func text(of symbol: Symbol) -> MessageText {
        MessageText(codeUnits: codeUnits(of: symbol))
    }

    /// The text as an API name (entry points, override keys).
    @_spi(Testing)
    public func name(of symbol: Symbol) -> Name {
        Name(utf16: codeUnits(of: symbol))
    }

    /// The text as a String.
    ///
    /// ASCII text, which mangled and reserved names are, is decoded from its bytes in `scratch`, a buffer the caller keeps: much
    /// faster than decoding UTF-16.
    @_spi(Testing)
    public func string(of symbol: Symbol, scratch: inout ContiguousArray<UInt8>) -> String {
        if !scratch.isEmpty {
            scratch.removeAll(keepingCapacity: true)
        }
        if appendASCII(of: symbol, to: &scratch) {
            return String(decoding: scratch, as: UTF8.self)
        }
        return String(decoding: codeUnits(of: symbol), as: UTF16.self)
    }

    /// The text in place, for comparing it with the spellings of a closed set; the view shares the table's storage, so it must
    /// not live across an intern.
    @_spi(Testing)
    public func codeUnitsView(of symbol: Symbol) -> ArraySlice<UInt16> {
        let index = Int(symbol.raw)
        if index < base.count {
            return base.codeUnits[base.range(of: index)]
        }
        return own.codeUnits[own.range(of: index - base.count)]
    }

    /// `name(of:)`, made once per symbol: the override values are looked up by name for every override and identifier.
    @_spi(Testing)
    public mutating func cachedName(of symbol: Symbol) -> Name {
        if let name = names.find(symbol) {
            return name
        }
        let name = self.name(of: symbol)
        names.set(symbol, name)
        return name
    }

    // MARK: - Table

    private static func hash(_ units: ContiguousArray<UInt16>, _ range: Range<Int>) -> Int {
        symbolHash(units, range)
    }

    private mutating func intern(_ text: ContiguousArray<UInt16>, _ provenance: SymbolProvenance) -> Symbol {
        let hash = Self.hash(text, 0..<text.count)
        if let index = base.find(hash, text, 0..<text.count).index {
            upgrade(UInt32(index), provenance)
            return Symbol(raw: UInt32(index))
        }
        let (index, slot) = own.find(hash, text, 0..<text.count)
        if let index {
            upgrade(UInt32(base.count + index), provenance)
            return Symbol(raw: UInt32(base.count + index))
        }
        if own.hasUnhashed, let symbol = unhashedMangledSymbol(text, 0..<text.count) {
            upgrade(symbol.raw, provenance)
            return symbol
        }
        own.reserveCodeUnits(text.count)
        own.codeUnits.append(contentsOf: text)
        return Symbol(raw: UInt32(base.count + own.append(at: slot, hash, provenance)))
    }

    // Interns the text just appended to `own.codeUnits` from `start`, built in place because it is usually new; the
    // appended copy is dropped when the text was already interned.
    private mutating func internAppendedText(from start: Int, _ provenance: SymbolProvenance) -> Symbol {
        let range = start..<own.codeUnits.count
        let hash = Self.hash(own.codeUnits, range)
        let found: Int
        if let index = base.find(hash, own.codeUnits, range).index {
            found = index
        } else {
            let (index, slot) = own.find(hash, own.codeUnits, range)
            if let index {
                found = base.count + index
            } else if own.hasUnhashed, let symbol = unhashedMangledSymbol(own.codeUnits, range) {
                found = Int(symbol.raw)
            } else {
                return Symbol(raw: UInt32(base.count + own.append(at: slot, hash, provenance)))
            }
        }
        own.codeUnits.removeSubrange(start...)
        upgrade(UInt32(found), provenance)
        return Symbol(raw: UInt32(found))
    }

    // The symbol of `units[range]` when it is the spelling of a mangled name interned without a hash.
    private mutating func unhashedMangledSymbol(_ units: borrowing ContiguousArray<UInt16>, _ range: Range<Int>) -> Symbol? {
        guard let (kind, index) = MangledName.kindAndIndex(units, range), index < unhashedMangledNames.count(of: kind) else {
            return nil
        }
        return unhashedMangledSymbol(kind, index)
    }

    // The symbol of the mangled name interned without a hash with `kind` and `index`; the map from kind and index to symbol
    // is made from the records on the first lookup.
    private mutating func unhashedMangledSymbol(_ kind: MangledName.Kind, _ index: UInt32) -> Symbol {
        if !unhashedMangledNames.isMapped {
            var position = 0
            while position < own.count {
                if !own.records[position].isHashed {
                    guard let (recordKind, _) = MangledName.kindAndIndex(own.codeUnits, own.range(of: position)) else {
                        wgslFatal("a symbol interned without a hash is not a mangled name", cppSite: "MangleNames.cpp invariant")
                    }
                    unhashedMangledNames.map(recordKind, Symbol(raw: UInt32(base.count + position)))
                }
                position += 1
            }
            unhashedMangledNames.isMapped = true
        }
        return unhashedMangledNames.symbol(kind, index)
    }

    private mutating func appendOwn(_ text: StaticString) {
        own.codeUnits.append(contentsOf: text.description.utf16)
    }

    private mutating func appendOwn(_ text: String) {
        own.codeUnits.append(contentsOf: text.utf16)
    }

    // StringBuilder's decimal of an unsigned integer.
    private mutating func appendOwnDecimal(_ value: UInt32) {
        var divisor: UInt32 = 1
        while value / divisor >= 10 {
            divisor &*= 10
        }
        repeat {
            own.codeUnits.append(UInt16(UInt8(ascii: "0")) &+ UInt16(truncatingIfNeeded: value / divisor % 10))
            divisor /= 10
        } while divisor != 0
    }

    // `prefix`, the text of `symbol` and `suffix`; `.source` when `symbol` is.
    private mutating func appendOwn(_ prefix: String, _ symbol: Symbol, _ suffix: String) -> SymbolProvenance {
        let provenance: SymbolProvenance = self.provenance(of: symbol) == .source ? .source : .reserved
        let index = Int(symbol.raw)
        let isBase = index < base.count
        let range = isBase ? base.range(of: index) : own.range(of: index - base.count)
        own.reserveCodeUnits(prefix.utf16.count + range.count + suffix.utf16.count)
        own.codeUnits.append(contentsOf: prefix.utf16)
        if isBase {
            own.codeUnits.append(contentsOf: base.codeUnits[range])
        } else {
            var position = range.lowerBound
            while position < range.upperBound {
                let codeUnit = own.codeUnits[position]
                own.codeUnits.append(codeUnit)
                position += 1
            }
        }
        own.codeUnits.append(contentsOf: suffix.utf16)
        return provenance
    }

    // The predeclared symbols are `.builtin`, so only a table's own symbols can be upgraded.
    private mutating func upgrade(_ symbol: UInt32, _ provenance: SymbolProvenance) {
        let index = Int(symbol)
        guard index >= base.count else {
            assert(base.records[index].provenance != .source)
            return
        }
        if own.records[index - base.count].provenance == .source {
            own.records[index - base.count].provenance = provenance
        }
    }

    /// The longest run of occupied buckets, which bounds the probes of any lookup.
    @_spi(Testing)
    public func longestProbeRun() -> Int {
        let baseRun = base.longestProbeRun()
        let ownRun = own.longestProbeRun()
        return baseRun > ownRun ? baseRun : ownRun
    }
}

// The mangled names a table interned without a hash. Only a kind's next index takes that path, and the Mangler numbers each
// kind from 0, so those of a kind are the indices below its count. The map to their symbols is made only when a lookup by
// text or a repeated intern first needs it: most modules never look one up.
private struct UnhashedMangledNames: Sendable {
    private var counts: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0)
    // By kind, the raw values of the symbols in index order, once `isMapped`.
    private var symbols: [ContiguousArray<UInt32>] = []
    var isMapped = false

    func count(of kind: MangledName.Kind) -> UInt32 {
        switch kind {
        case .type: counts.0
        case .local: counts.1
        case .global: counts.2
        case .parameter: counts.3
        case .function: counts.4
        case .field: counts.5
        }
    }

    mutating func append(_ kind: MangledName.Kind, _ symbol: Symbol) {
        switch kind {
        case .type: counts.0 += 1
        case .local: counts.1 += 1
        case .global: counts.2 += 1
        case .parameter: counts.3 += 1
        case .function: counts.4 += 1
        case .field: counts.5 += 1
        }
        if isMapped {
            map(kind, symbol)
        }
    }

    // Appends `symbol` to its kind's symbols, which it follows in index order.
    mutating func map(_ kind: MangledName.Kind, _ symbol: Symbol) {
        if symbols.isEmpty {
            symbols = Array(repeatElement([], count: MangledName.numberOfKinds))
        }
        symbols[Int(kind.rawValue)].append(symbol.raw)
    }

    func symbol(_ kind: MangledName.Kind, _ index: UInt32) -> Symbol {
        Symbol(raw: symbols[Int(kind.rawValue)][Int(index)])
    }
}

// KeyedHasher over the code units packed four to a word, so crafted identifiers cannot flood one probe sequence. A Latin-1
// spelling (zero-extended) and a UTF-16 spelling of the same text hash alike.
private func symbolHash(_ units: borrowing ContiguousArray<UInt8>, _ range: Range<Int>) -> Int {
    var hasher = KeyedHasher()
    var index = range.lowerBound
    let wordsEnd = range.upperBound &- range.count % 4
    while index < wordsEnd {
        hasher.combine(
            UInt64(units[index]) | UInt64(units[index &+ 1]) &<< 16 | UInt64(units[index &+ 2]) &<< 32
                | UInt64(units[index &+ 3]) &<< 48
        )
        index &+= 4
    }
    var tail: UInt64 = 0
    var shift: UInt64 = 0
    while index < range.upperBound {
        tail |= UInt64(units[index]) &<< shift
        shift &+= 16
        index &+= 1
    }
    return hasher.finalize(tail: tail, count: range.count)
}

private func symbolHash(_ units: borrowing ContiguousArray<UInt16>, _ range: Range<Int>) -> Int {
    var hasher = KeyedHasher()
    var index = range.lowerBound
    let wordsEnd = range.upperBound &- range.count % 4
    while index < wordsEnd {
        hasher.combine(
            UInt64(units[index]) | UInt64(units[index &+ 1]) &<< 16 | UInt64(units[index &+ 2]) &<< 32
                | UInt64(units[index &+ 3]) &<< 48
        )
        index &+= 4
    }
    var tail: UInt64 = 0
    var shift: UInt64 = 0
    while index < range.upperBound {
        tail |= UInt64(units[index]) &<< shift
        shift &+= 16
        index &+= 1
    }
    return hasher.finalize(tail: tail, count: range.count)
}

extension SourceText {
    fileprivate func symbolHash(_ range: Range<Int>) -> Int {
        switch storage {
        case .latin1(let codeUnits): WGSL.symbolHash(codeUnits, range)
        case .utf16(let codeUnits): WGSL.symbolHash(codeUnits, range)
        }
    }
}

/// Every compiler-synthesised `"__…"` spelling, a closed set.
///
/// It covers the identifiers the passes make and the `__` words of the MSL the writer prints. User identifiers cannot
/// start with "__" (Lexer.cpp:515), so a reserved name never equals user text, and lint L-MSL-3 rejects a module literal
/// starting with a `__` word that is not spelled here.
@_spi(Testing)
public enum ReservedName: Hashable, Sendable {
    case fixed(Fixed)
    /// "__" + name + "_ArrayLength" (GlobalVariableRewriter.cpp:237, :274, :293, :727, :893).
    case arrayLength(of: Symbol)
    /// "__" + structure + "_Packed" (GlobalVariableRewriter.cpp:1081).
    case packedStruct(of: Symbol)
    /// "__ArgumentBufferPlaceholder_" + index (GlobalVariableRewriter.cpp:2384, :2401).
    case argumentBufferPlaceholder(UInt32)
    /// "__" + name, a texture_external field of an argument buffer (GlobalVariableRewriter.cpp:2487).
    case externalTexture(of: Symbol)
    /// "__i" + depth (GlobalVariableRewriter.cpp:2685).
    case loopIndex(depth: UInt32)
    /// "__ArgumentBuffer_" + group (GlobalVariableRewriter.cpp:2893).
    case argumentBufferParameter(group: UInt32)
    /// "__ArgumentBufferT_" + entry point + "_" + group (GlobalVariableRewriter.cpp:2898).
    case argumentBufferStruct(entryPoint: UInt32, group: UInt32)
    /// "__" + function + "_inT" (EntryPointRewriter.cpp:90).
    case entryPointInputStruct(of: Symbol)
    /// "__" + function + "_in" (EntryPointRewriter.cpp:91).
    case entryPointInputParameter(of: Symbol)
    /// "__" + structure or function + "_FragmentOutput" / "_VertexOutput" (EntryPointRewriter.cpp:135, :166).
    case stageOutputStruct(of: Symbol, OutputStage)
    /// "__builtin" + N (EntryPointRewriter.cpp:322).
    case builtinParameter(UInt32)
    /// "__evalOrder" + N (EvaluationOrderRewriter.cpp:225).
    case evaluationOrderTemporary(UInt32)
    /// "__wgslConst" + N (MetalFunctionWriter.cpp:1900).
    case outlinedConstant(UInt32)

    @_spi(Testing)
    public enum OutputStage: UInt8, CaseIterable, Sendable {
        case fragment
        case vertex
    }

    /// The spellings without a parameter, in C++ source order (passes, then the writer's MSL).
    @_spi(Testing)
    public enum Fixed: UInt8, CaseIterable, Sendable {
        case frexpResult
        case modfResult
        case atomicCompareExchangeResult
        case wgslMin
        case pack
        case unpack
        case packedArray
        case dynamicOffset
        case localInvocationIndex
        case wgslZeroWorkgroupVar
        case dynamicOffsets
        case type
        case value
        case wgslEnsureForwardProgress
        case wgslEnsureSwitchClauseScope
        case wgslAcos
        case wgslAsin
        case wgslAcosh
        case wgslAtanh
        case wgslInverseSqrt
        case wgslLog
        case wgslLog2
        case wgslSqrt
        case wgslPackFloatToSnorm2x16
        case wgslPackFloatToUnorm2x16
        case wgslPackFloatToSnorm4x8
        case wgslPackFloatToUnorm4x8
        case wgslMetalAppleGPUFamily
        case wgslTextureSampleBaseClampToEdge
        case wgslTextureSampleBiasWithOffset
        case texture
        case sampler
        case coords
        case bounds
        case inputCoords
        case reconstructionSampler
        case firstPlaneSize
        case secondPlaneSize
        case lumaBounds
        case chromaBounds
        case secondCoords
        case y
        case second
        case rgb
        case x
        case bias
        case size
        case levels
        case lod
        case low
        case high
        case lowSize
        case highSize
        case offset
        case arrayIndex
        case z
        case packedType
        case packedTypeImpl
        case unpackedType
        case unpackedTypeImpl
        case padding
        case wgslAtomicCompareExchangeWeak
        case wgslDot
        case wgslDot4I8Packed
        case wgslDot4U8Packed
        case wgslFirstLeadingBit
        case wgslFirstTrailingBit
        case wgslSign
        case wgslExtractBits
        case wgslInsertBits
        case wgslFrexp
        case wgslModf
        case attribute
        case xAdjustment
        case yAdjustment
        case ycbcr
        case workgroupUniformLoad
        case wgslAtomicLoadResult
        case wgslFtoi
        case wgslDiv
        case wgslMod
        case asm
        case wgslFragmentReturnResult
        case continuing

        @_spi(Testing)
        public var spelling: StaticString {
            switch self {
            case .frexpResult: "__frexp_result"
            case .modfResult: "__modf_result"
            case .atomicCompareExchangeResult: "__atomic_compare_exchange_result"
            case .wgslMin: "__wgslMin"
            case .pack: "__pack"
            case .unpack: "__unpack"
            case .packedArray: "__PackedArray"
            case .dynamicOffset: "__dynamicOffset"
            case .localInvocationIndex: "__localInvocationIndex"
            case .wgslZeroWorkgroupVar: "__wgslZeroWorkgroupVar"
            case .dynamicOffsets: "__DynamicOffsets"
            case .type: "__type"
            case .value: "__value"
            case .wgslEnsureForwardProgress: "__wgslEnsureForwardProgress"
            case .wgslEnsureSwitchClauseScope: "__wgslEnsureSwitchClauseScope"
            case .wgslAcos: "__wgslAcos"
            case .wgslAsin: "__wgslAsin"
            case .wgslAcosh: "__wgslAcosh"
            case .wgslAtanh: "__wgslAtanh"
            case .wgslInverseSqrt: "__wgslInverseSqrt"
            case .wgslLog: "__wgslLog"
            case .wgslLog2: "__wgslLog2"
            case .wgslSqrt: "__wgslSqrt"
            case .wgslPackFloatToSnorm2x16: "__wgslPackFloatToSnorm2x16"
            case .wgslPackFloatToUnorm2x16: "__wgslPackFloatToUnorm2x16"
            case .wgslPackFloatToSnorm4x8: "__wgslPackFloatToSnorm4x8"
            case .wgslPackFloatToUnorm4x8: "__wgslPackFloatToUnorm4x8"
            case .wgslMetalAppleGPUFamily: "__wgslMetalAppleGPUFamily"
            case .wgslTextureSampleBaseClampToEdge: "__wgslTextureSampleBaseClampToEdge"
            case .wgslTextureSampleBiasWithOffset: "__wgslTextureSampleBiasWithOffset"
            case .texture: "__texture"
            case .sampler: "__sampler"
            case .coords: "__coords"
            case .bounds: "__bounds"
            case .inputCoords: "__inputCoords"
            case .reconstructionSampler: "__reconstructionSampler"
            case .firstPlaneSize: "__firstPlaneSize"
            case .secondPlaneSize: "__secondPlaneSize"
            case .lumaBounds: "__lumaBounds"
            case .chromaBounds: "__chromaBounds"
            case .secondCoords: "__secondCoords"
            case .y: "__y"
            case .second: "__second"
            case .rgb: "__rgb"
            case .x: "__x"
            case .bias: "__bias"
            case .size: "__size"
            case .levels: "__levels"
            case .lod: "__lod"
            case .low: "__low"
            case .high: "__high"
            case .lowSize: "__lowSize"
            case .highSize: "__highSize"
            case .offset: "__offset"
            case .arrayIndex: "__arrayIndex"
            case .z: "__z"
            case .packedType: "__PackedType"
            case .packedTypeImpl: "__PackedTypeImpl"
            case .unpackedType: "__UnpackedType"
            case .unpackedTypeImpl: "__UnpackedTypeImpl"
            case .padding: "__padding"
            case .wgslAtomicCompareExchangeWeak: "__wgslAtomicCompareExchangeWeak"
            case .wgslDot: "__wgslDot"
            case .wgslDot4I8Packed: "__wgslDot4I8Packed"
            case .wgslDot4U8Packed: "__wgslDot4U8Packed"
            case .wgslFirstLeadingBit: "__wgslFirstLeadingBit"
            case .wgslFirstTrailingBit: "__wgslFirstTrailingBit"
            case .wgslSign: "__wgslSign"
            case .wgslExtractBits: "__wgslExtractBits"
            case .wgslInsertBits: "__wgslInsertBits"
            case .wgslFrexp: "__wgslFrexp"
            case .wgslModf: "__wgslModf"
            case .attribute: "__attribute__"
            case .xAdjustment: "__xAdjustment"
            case .yAdjustment: "__yAdjustment"
            case .ycbcr: "__ycbcr"
            case .workgroupUniformLoad: "__workgroup_uniform_load"
            case .wgslAtomicLoadResult: "__wgslAtomicLoadResult"
            case .wgslFtoi: "__wgslFtoi"
            case .wgslDiv: "__wgslDiv"
            case .wgslMod: "__wgslMod"
            case .asm: "__asm"
            case .wgslFragmentReturnResult: "__wgslFragmentReturnResult"
            case .continuing: "__continuing"
            }
        }
    }
}

extension ReservedName {
    // The pieces of the spelling, which SymbolTable appends in place.
    fileprivate enum Parts {
        case fixed(StaticString)
        case embedding(String, Symbol, String)
        case numbered(String, UInt32)
        case twoNumbers(String, UInt32, String, UInt32)
    }

    // The case and its payload in 64 bits; nil for the one case whose payload does not fit.
    fileprivate struct MemoKey: SmallKey {
        let smallKeyBits: UInt64

        init(_ tag: UInt64, _ payload: UInt32, _ extra: UInt8 = 0) {
            smallKeyBits = tag &<< 40 | UInt64(extra) &<< 32 | UInt64(payload)
        }
    }

    fileprivate var memoKey: MemoKey? {
        switch self {
        case .fixed(let name): MemoKey(0, UInt32(name.rawValue))
        case .arrayLength(let name): MemoKey(1, name.raw)
        case .packedStruct(let name): MemoKey(2, name.raw)
        case .argumentBufferPlaceholder(let index): MemoKey(3, index)
        case .externalTexture(let name): MemoKey(4, name.raw)
        case .loopIndex(let depth): MemoKey(5, depth)
        case .argumentBufferParameter(let group): MemoKey(6, group)
        case .argumentBufferStruct: nil
        case .entryPointInputStruct(let function): MemoKey(7, function.raw)
        case .entryPointInputParameter(let function): MemoKey(8, function.raw)
        case .stageOutputStruct(let name, let stage): MemoKey(9, name.raw, stage.rawValue)
        case .builtinParameter(let index): MemoKey(10, index)
        case .evaluationOrderTemporary(let index): MemoKey(11, index)
        case .outlinedConstant(let index): MemoKey(12, index)
        }
    }

    fileprivate var parts: Parts {
        switch self {
        case .fixed(let name): .fixed(name.spelling)
        case .arrayLength(let name): .embedding("__", name, "_ArrayLength")
        case .packedStruct(let name): .embedding("__", name, "_Packed")
        case .argumentBufferPlaceholder(let index): .numbered("__ArgumentBufferPlaceholder_", index)
        case .externalTexture(let name): .embedding("__", name, "")
        case .loopIndex(let depth): .numbered("__i", depth)
        case .argumentBufferParameter(let group): .numbered("__ArgumentBuffer_", group)
        case .argumentBufferStruct(let entryPoint, let group): .twoNumbers("__ArgumentBufferT_", entryPoint, "_", group)
        case .entryPointInputStruct(let function): .embedding("__", function, "_inT")
        case .entryPointInputParameter(let function): .embedding("__", function, "_in")
        case .stageOutputStruct(let name, .fragment): .embedding("__", name, "_FragmentOutput")
        case .stageOutputStruct(let name, .vertex): .embedding("__", name, "_VertexOutput")
        case .builtinParameter(let index): .numbered("__builtin", index)
        case .evaluationOrderTemporary(let index): .numbered("__evalOrder", index)
        case .outlinedConstant(let index): .numbered("__wgslConst", index)
        }
    }
}

/// A vector swizzle the type checker accepted: the proof `markSwizzle` needs.
///
/// Minted only by `validate`, which applies the checks of TypeCheck.cpp:2133-2218 (vectorFieldAccess) in the C++ order;
/// like the C++, it tests each code unit truncated to a `char`.
@_spi(Testing)
public struct Swizzle: BitwiseCopyable, Sendable {
    @_spi(Testing)
    public enum Failure: Error, BitwiseCopyable, Sendable {
        /// "invalid vector swizzle character"
        case character
        /// "invalid vector swizzle member"
        case member
        /// "invalid vector swizzle size"
        case size
    }

    @_spi(Testing)
    public let symbol: Symbol
    @_spi(Testing)
    public let count: Int
    private let components: UInt32
    private let codeUnits: UInt64

    fileprivate init(symbol: Symbol, count: Int, components: UInt32, codeUnits: UInt64) {
        self.symbol = symbol
        self.count = count
        self.components = components
        self.codeUnits = codeUnits
    }

    @_spi(Testing)
    public static func validate(_ symbol: Symbol, _ symbols: borrowing SymbolTable, vectorSize: UInt8) -> Result<Swizzle, Failure> {
        let length = symbols.length(of: symbol)
        var isValid = true
        var hasXYZW = false
        var hasRGBA = false
        var components: UInt32 = 0
        var codeUnits: UInt64 = 0
        var index = 0
        while index < length {
            let codeUnit = symbols.codeUnit(of: symbol, at: index)
            let c = UInt8(truncatingIfNeeded: codeUnit)
            if let component = xyzwComponent(c, vectorSize, &isValid) {
                hasXYZW = true
                components |= component << (2 * UInt32(index & 3))
            } else if let component = rgbaComponent(c, vectorSize, &isValid) {
                hasRGBA = true
                components |= component << (2 * UInt32(index & 3))
            } else {
                return .failure(.character)
            }
            codeUnits |= UInt64(codeUnit) &<< (16 * UInt64(index & 3))
            index += 1
        }

        if !isValid || (hasRGBA && hasXYZW) {
            return .failure(.member)
        }

        guard length >= 1 && length <= 4 else {
            return .failure(.size)
        }
        return .success(Swizzle(symbol: symbol, count: length, components: components, codeUnits: codeUnits))
    }

    /// The vector element the component at `index` selects (TypeCheck.cpp constAccess): r/x 0, g/y 1, b/z 2, a/w 3.
    @_spi(Testing)
    public func componentIndex(at index: Int) -> Int {
        guard index >= 0 && index < count else {
            wgslFatal("swizzle component out of range", cppSite: "TypeCheck.cpp:2201")
        }
        return Int((components >> (2 * UInt32(index))) & 3)
    }

    // Whether `symbol`'s text is the validated text, so a proof cannot vouch for other text at the same index.
    fileprivate func spells(_ symbol: Symbol, _ symbols: borrowing SymbolTable) -> Bool {
        guard symbols.length(of: symbol) == count else {
            return false
        }
        var index = 0
        while index < count {
            guard symbols.codeUnit(of: symbol, at: index) == UInt16(truncatingIfNeeded: codeUnits &>> (16 * UInt64(index))) else {
                return false
            }
            index += 1
        }
        return true
    }

    private static func xyzwComponent(_ c: UInt8, _ vectorSize: UInt8, _ isValid: inout Bool) -> UInt32? {
        if c == UInt8(ascii: "x") {
            return 0
        }
        if c == UInt8(ascii: "y") {
            return 1
        }
        if c == UInt8(ascii: "z") {
            isValid = isValid && vectorSize >= 3
            return 2
        }
        if c == UInt8(ascii: "w") {
            isValid = isValid && vectorSize == 4
            return 3
        }
        return nil
    }

    private static func rgbaComponent(_ c: UInt8, _ vectorSize: UInt8, _ isValid: inout Bool) -> UInt32? {
        if c == UInt8(ascii: "r") {
            return 0
        }
        if c == UInt8(ascii: "g") {
            return 1
        }
        if c == UInt8(ascii: "b") {
            isValid = isValid && vectorSize >= 3
            return 2
        }
        if c == UInt8(ascii: "a") {
            isValid = isValid && vectorSize == 4
            return 3
        }
        return nil
    }
}
