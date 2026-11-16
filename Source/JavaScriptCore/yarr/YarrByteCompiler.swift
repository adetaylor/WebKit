// Copyright (C) 2009-2026 Apple Inc. All rights reserved.
// Copyright (C) 2010 Peter Varga (pvarga@inf.u-szeged.hu), University of Szeged
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

internal import CxxStdlib
internal import JSCSwiftBoundary
import Synchronization

// The regular expression bytecode compiler: it reads the YarrPattern that YarrInterpreter.cpp writes as words
// (PatternWriter), compiles it to byte terms, and writes them as the bytecode that the interpreter in
// YarrInterpreterMatcher.swift runs. The constants below are pinned to the C++ enums' values by static_asserts in
// YarrInterpreter.cpp.

// MARK: - Constants

let yarrOffsetNoMatch: UInt32 = .max
let yarrQuantifyInfinite: UInt32 = .max

enum YarrFlag {
    static let hasIndices: UInt32 = 1 << 0
    static let global: UInt32 = 1 << 1
    static let ignoreCase: UInt32 = 1 << 2
    static let multiline: UInt32 = 1 << 3
    static let dotAll: UInt32 = 1 << 4
    static let unicode: UInt32 = 1 << 5
    static let unicodeSets: UInt32 = 1 << 6
    static let sticky: UInt32 = 1 << 7
}

enum YarrErrorCode {
    static let noError: UInt32 = 0
    static let offsetTooLarge: UInt32 = 26
    static let tooManyDisjunctions: UInt32 = 34
}

enum QuantifierType: UInt8 {
    case fixedCount = 0
    case greedy = 1
    case nonGreedy = 2
}

// MatchDirection: Forward is 0 and Backward is 1, and the interpreter indexes capture pairs by it.
let yarrForward: UInt8 = 0
let yarrBackward: UInt8 = 1

enum CompileMode {
    case legacy
    case unicode
    case unicodeSets

    init(flags: UInt32) {
        if flags & YarrFlag.unicode != 0 {
            self = .unicode
        } else if flags & YarrFlag.unicodeSets != 0 {
            self = .unicodeSets
        } else {
            self = .legacy
        }
    }

    var eitherUnicode: Bool { self != .legacy }
}

// The frame slots each kind of term's backtracking state takes (Yarr.h).
enum YarrStackSpace {
    static let parenthesesOnce: UInt32 = 2
    static let parenthesesTerminal: UInt32 = 2
    static let parentheticalAssertion: UInt32 = 1
}

// MARK: - The pattern, as PatternWriter writes it

enum PatternTermType: UInt32 {
    case assertionBOL = 0
    case assertionEOL
    case assertionBOI
    case assertionEOI
    case assertionWordBoundary
    case patternCharacter
    case characterClass
    case numberedBackReference
    case namedBackReference
    case numberedForwardReference
    case namedForwardReference
    case parenthesesSubpattern
    case parentheticalAssertion
    case dotStarEnclosure
}

struct PatternTerm {
    var type: PatternTermType
    var flags: UInt32
    var capture: Bool
    var invert: Bool
    var withOptionalLineTerminator: Bool
    var matchDirection: UInt8
    var quantityType: QuantifierType
    var quantityMinCount: UInt32
    var quantityMaxCount: UInt32
    var inputPosition: UInt32
    var frameLocation: UInt32
    // The union member the type uses: the character, the class's index, the back reference's subpattern, the
    // parentheses' disjunction index, or the anchors.
    var value: UInt32
    var subpatternId: UInt32
    var lastSubpatternId: UInt32
    var parenthesesBits: UInt32

    var isCopy: Bool { parenthesesBits & 1 != 0 }
    var isTerminal: Bool { parenthesesBits & 2 != 0 }
    var bolAnchor: Bool { value & 1 != 0 }
    var eolAnchor: Bool { value & 2 != 0 }
}

struct PatternAlternative {
    var minimumSize: UInt32
    var onceThrough: Bool
    var terms: [PatternTerm]
}

struct PatternDisjunction {
    var minimumSize: UInt32
    var callFrameSize: UInt32
    var alternatives: [PatternAlternative]
}

struct PatternCharacterClass {
    var anyCharacter: Bool
    var widths: UInt32
    // Whether the class has a table of all of its BMP characters (m_table), or of its Latin-1 ones (m_latin1Table).
    var hasTable: Bool
    var hasLatin1Table: Bool
    // Where its lists are in the pattern's words, which the compile reads in place.
    var matches8: Range<Int>
    var ranges8: Range<Int>
    var matches32: Range<Int>
    var ranges32: Range<Int>
    var dumpText: [UInt8]
}

struct YarrPatternModel {
    var flags: UInt32 = 0
    var numSubpatterns: UInt32 = 0
    var numDuplicateNamedCaptureGroups: UInt32 = 0
    var endAnchoredFixedSize: UInt32 = 0
    var newlineClass: UInt32 = 0
    var wordcharClass: UInt32 = 0
    var wordUnicodeIgnoreCaseClass: UInt32 = 0
    var duplicateNamedGroupForSubpatternId: [UInt32] = []
    var disjunctions: [PatternDisjunction] = []
    var classes: [PatternCharacterClass] = []

    var compileMode: CompileMode { CompileMode(flags: flags) }
    var hasDuplicateNamedCaptureGroups: Bool { numDuplicateNamedCaptureGroups != 0 }
    var offsetVectorBaseForNamedCaptures: UInt32 { (numSubpatterns + 1) * 2 }
    var offsetsSize: UInt32 { offsetVectorBaseForNamedCaptures + numDuplicateNamedCaptureGroups }
}

private struct WordReader: ~Copyable, ~Escapable {
    let words: Span<UInt32>
    var position = 0

    @_lifetime(copy words)
    init(_ words: Span<UInt32>) {
        self.words = words
    }

    mutating func next() -> UInt32 {
        let word = words[position]
        position += 1
        return word
    }
}

// The pattern model a compile reads its pattern into, kept between compiles with its arrays' storage, so that a
// compile allocates nothing for it once a pattern of its size has been compiled. A model holding more than
// `spareModelLimit` bytes of storage is not kept.
private let spareModel = Mutex<YarrPatternModel>(YarrPatternModel())
private let spareModelLimit = 64 * 1024

extension YarrPatternModel {
    // The bytes of storage the model's arrays hold, nested ones included.
    var storageSize: Int {
        var size = duplicateNamedGroupForSubpatternId.capacity * 4
        size += disjunctions.capacity * MemoryLayout<PatternDisjunction>.stride
        for disjunction in disjunctions {
            size += disjunction.alternatives.capacity * MemoryLayout<PatternAlternative>.stride
            for alternative in disjunction.alternatives {
                size += alternative.terms.capacity * MemoryLayout<PatternTerm>.stride
            }
        }
        size += classes.capacity * MemoryLayout<PatternCharacterClass>.stride
        for characterClass in classes {
            size += characterClass.dumpText.capacity
        }
        return size
    }
}

extension WordReader {
    // The positions of the next `count` words, which it moves past.
    mutating func skip(_ count: UInt32) -> Range<Int> {
        let start = position
        position += Int(count)
        precondition(position <= words.count)
        return start..<position
    }

    // Replaces `array`'s elements with the next `count` words, in the storage it has.
    mutating func read(_ count: UInt32, into array: inout [UInt32]) {
        array.removeAll(keepingCapacity: true)
        array.reserveCapacity(Int(count))
        for _ in 0..<count {
            array.append(next())
        }
    }
}

// Reads the pattern into `pattern`, whose arrays (and their elements' arrays) keep their storage where they can.
private func readPattern(_ words: Span<UInt32>, into pattern: inout YarrPatternModel) {
    var reader = WordReader(words)
    pattern.flags = reader.next()
    pattern.numSubpatterns = reader.next()
    pattern.numDuplicateNamedCaptureGroups = reader.next()
    pattern.endAnchoredFixedSize = reader.next()
    pattern.newlineClass = reader.next()
    pattern.wordcharClass = reader.next()
    pattern.wordUnicodeIgnoreCaseClass = reader.next()
    reader.read(reader.next(), into: &pattern.duplicateNamedGroupForSubpatternId)

    // The body first; every disjunction a term names has an index below the count read so far plus the terms' own.
    var disjunctionCount = 1
    var index = 0
    while index < disjunctionCount {
        if index == pattern.disjunctions.count {
            pattern.disjunctions.append(PatternDisjunction(minimumSize: 0, callFrameSize: 0, alternatives: []))
        }
        pattern.disjunctions[index].minimumSize = reader.next()
        pattern.disjunctions[index].callFrameSize = reader.next()
        let alternativeCount = Int(reader.next())
        if pattern.disjunctions[index].alternatives.count > alternativeCount {
            pattern.disjunctions[index].alternatives.removeSubrange(alternativeCount...)
        }
        for alternativeIndex in 0..<alternativeCount {
            if alternativeIndex == pattern.disjunctions[index].alternatives.count {
                pattern.disjunctions[index].alternatives.append(PatternAlternative(minimumSize: 0, onceThrough: false, terms: []))
            }
            pattern.disjunctions[index].alternatives[alternativeIndex].minimumSize = reader.next()
            pattern.disjunctions[index].alternatives[alternativeIndex].onceThrough = reader.next() != 0
            let termCount = reader.next()
            pattern.disjunctions[index].alternatives[alternativeIndex].terms.removeAll(keepingCapacity: true)
            pattern.disjunctions[index].alternatives[alternativeIndex].terms.reserveCapacity(Int(termCount))
            for _ in 0..<termCount {
                let type = PatternTermType(rawValue: reader.next())!
                let flags = reader.next()
                let bits = reader.next()
                let quantityType = QuantifierType(rawValue: UInt8(reader.next()))!
                let term = PatternTerm(
                    type: type,
                    flags: flags,
                    capture: bits & 1 != 0,
                    invert: bits & 2 != 0,
                    withOptionalLineTerminator: bits & 4 != 0,
                    matchDirection: UInt8((bits >> 3) & 1),
                    quantityType: quantityType,
                    quantityMinCount: reader.next(),
                    quantityMaxCount: reader.next(),
                    inputPosition: reader.next(),
                    frameLocation: reader.next(),
                    value: reader.next(),
                    subpatternId: reader.next(),
                    lastSubpatternId: reader.next(),
                    parenthesesBits: reader.next()
                )
                if type == .parenthesesSubpattern || type == .parentheticalAssertion {
                    disjunctionCount = max(disjunctionCount, Int(term.value) + 1)
                }
                pattern.disjunctions[index].alternatives[alternativeIndex].terms.append(term)
            }
        }
        index += 1
    }
    if pattern.disjunctions.count > disjunctionCount {
        pattern.disjunctions.removeSubrange(disjunctionCount...)
    }

    let classCount = Int(reader.next())
    if pattern.classes.count > classCount {
        pattern.classes.removeSubrange(classCount...)
    }
    pattern.classes.reserveCapacity(classCount)
    for classIndex in 0..<classCount {
        if classIndex == pattern.classes.count {
            pattern.classes.append(
                PatternCharacterClass(
                    anyCharacter: false, widths: 0, hasTable: false, hasLatin1Table: false, matches8: 0..<0, ranges8: 0..<0,
                    matches32: 0..<0, ranges32: 0..<0, dumpText: []))
        }
        let header = reader.next()
        let matches8Count = reader.next()
        let ranges8Count = reader.next()
        let matches32Count = reader.next()
        let ranges32Count = reader.next()
        pattern.classes[classIndex].anyCharacter = header & 1 != 0
        pattern.classes[classIndex].widths = (header >> 1) & 3
        pattern.classes[classIndex].hasTable = header & 8 != 0
        pattern.classes[classIndex].hasLatin1Table = header & 16 != 0
        pattern.classes[classIndex].matches8 = reader.skip(matches8Count)
        pattern.classes[classIndex].ranges8 = reader.skip(ranges8Count * 2)
        pattern.classes[classIndex].matches32 = reader.skip(matches32Count)
        pattern.classes[classIndex].ranges32 = reader.skip(ranges32Count * 2)
        let dumpLength = reader.next()
        pattern.classes[classIndex].dumpText.removeAll(keepingCapacity: true)
        var word: UInt32 = 0
        for i in 0..<dumpLength {
            if i % 4 == 0 {
                word = reader.next()
            }
            pattern.classes[classIndex].dumpText.append(UInt8(truncatingIfNeeded: word >> (8 * (i % 4))))
        }
    }
}

// MARK: - Byte terms

enum ByteTermType: UInt8 {
    case bodyAlternativeBegin = 0
    case bodyAlternativeDisjunction
    case bodyAlternativeEnd
    case alternativeBegin
    case alternativeDisjunction
    case alternativeEnd
    case subpatternBegin
    case subpatternEnd
    case assertionBOL
    case assertionEOL
    case assertionBOI // beginning of input (\A)
    case assertionEOI // end of input (\z, \Z)
    case assertionWordBoundary
    case patternCharacterOnce
    case patternCharacterFixed
    case patternCharacterGreedy
    case patternCharacterNonGreedy
    case patternCharacterOnceBackward
    case patternCharacterFixedBackward
    case patternCharacterGreedyBackward
    case patternCharacterNonGreedyBackward
    case patternCasedCharacterOnce
    case patternCasedCharacterFixed
    case patternCasedCharacterGreedy
    case patternCasedCharacterNonGreedy
    case patternCasedCharacterOnceBackward
    case patternCasedCharacterFixedBackward
    case patternCasedCharacterGreedyBackward
    case patternCasedCharacterNonGreedyBackward
    case characterClass
    case characterClassBackward
    case backReference
    case backReferenceBackward
    case parenthesesSubpattern
    case parenthesesSubpatternOnceBegin
    case parenthesesSubpatternOnceEnd
    case parenthesesSubpatternTerminalBegin
    case parenthesesSubpatternTerminalEnd
    case parentheticalAssertionBegin
    case parentheticalAssertionEnd
    case checkInput
    case dotStarEnclosure

    static func directed(_ forward: ByteTermType, _ backward: ByteTermType, _ direction: UInt8) -> ByteTermType {
        direction == yarrForward ? forward : backward
    }
}

// A byte term. `a`, `b` and `c` are the words of the term's operands, which overlap by kind of term as follows:
// - `a`: the pattern character or the cased character's lower form; the class; the subpattern id or an assertion's
//   first subpattern id; an alternative's offset to the next alternative; the input count to check; the anchors;
// - `b`: the cased character's upper form; the duplicate named group id or an assertion's last subpattern id; an
//   alternative's offset to the end;
// - `c`: the parentheses' disjunction or their width in terms; whether a body alternative is matched once through.
struct ByteTerm {
    var type: ByteTermType
    var flags: UInt32
    var capture = false
    var invert = false
    var withOptionalLineTerminator = false
    var matchDirection: UInt8 = yarrForward
    var parentMatchDirection: UInt8 = yarrForward
    var inputPosition: UInt32 = 0
    var frameLocation: UInt32 = 0
    var quantityType: QuantifierType = .fixedCount
    var quantityMinCount: UInt32 = 1
    var quantityMaxCount: UInt32 = 1
    var a: UInt32 = 0
    var b: UInt32 = 0
    var c: UInt32 = 0

    init(type: ByteTermType, flags: UInt32, invert: Bool = false, matchDirection: UInt8 = yarrForward) {
        self.type = type
        self.flags = flags
        self.invert = invert
        self.matchDirection = matchDirection
    }

    static func character(
        _ ch: UInt32,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityCount: UInt32,
        _ quantityType: QuantifierType,
        _ flags: UInt32
    ) -> ByteTerm {
        var term = ByteTerm(type: .patternCharacterOnce, flags: flags, matchDirection: matchDirection)
        term.frameLocation = frameLocation
        term.inputPosition = inputPosition
        term.a = ch
        term.quantityType = quantityType
        term.quantityMinCount = quantityCount
        term.quantityMaxCount = quantityCount
        switch quantityType {
        case .fixedCount:
            term.type =
                quantityCount == 1
                ? .directed(.patternCharacterOnce, .patternCharacterOnceBackward, matchDirection)
                : .directed(.patternCharacterFixed, .patternCharacterFixedBackward, matchDirection)
        case .greedy:
            term.quantityMinCount = 0
            term.type = .directed(.patternCharacterGreedy, .patternCharacterGreedyBackward, matchDirection)
        case .nonGreedy:
            term.quantityMinCount = 0
            term.type = .directed(.patternCharacterNonGreedy, .patternCharacterNonGreedyBackward, matchDirection)
        }
        return term
    }

    static func casedCharacter(
        _ lo: UInt32,
        _ hi: UInt32,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityCount: UInt32,
        _ quantityType: QuantifierType,
        _ flags: UInt32
    ) -> ByteTerm {
        var term = ByteTerm(type: .patternCasedCharacterOnce, flags: flags, matchDirection: matchDirection)
        term.frameLocation = frameLocation
        term.inputPosition = inputPosition
        switch quantityType {
        case .fixedCount:
            term.type =
                quantityCount == 1
                ? .directed(.patternCasedCharacterOnce, .patternCasedCharacterOnceBackward, matchDirection)
                : .directed(.patternCasedCharacterFixed, .patternCasedCharacterFixedBackward, matchDirection)
            term.quantityMinCount = quantityCount
        case .greedy:
            term.type = .directed(.patternCasedCharacterGreedy, .patternCasedCharacterGreedyBackward, matchDirection)
            term.quantityMinCount = 0
        case .nonGreedy:
            term.type = .directed(.patternCasedCharacterNonGreedy, .patternCasedCharacterNonGreedyBackward, matchDirection)
            term.quantityMinCount = 0
        }
        term.a = lo
        term.b = hi
        term.quantityType = quantityType
        term.quantityMaxCount = quantityCount
        return term
    }

    static func characterClass(
        _ characterClass: UInt32,
        _ invert: Bool,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ flags: UInt32
    ) -> ByteTerm {
        var term = ByteTerm(
            type: .directed(.characterClass, .characterClassBackward, matchDirection),
            flags: flags,
            invert: invert,
            matchDirection: matchDirection
        )
        term.inputPosition = inputPosition
        term.a = characterClass
        return term
    }

    // A group's term: its subpattern id, and for ParenthesesSubpattern its disjunction.
    static func group(
        _ type: ByteTermType,
        _ subpatternId: UInt32,
        capture: Bool,
        invert: Bool = false,
        matchDirection: UInt8 = yarrForward,
        disjunction: UInt32 = 0,
        _ inputPosition: UInt32,
        _ flags: UInt32
    ) -> ByteTerm {
        var term = ByteTerm(type: type, flags: flags, invert: invert, matchDirection: matchDirection)
        term.capture = capture
        term.inputPosition = inputPosition
        term.a = subpatternId
        term.b = 0
        term.c = disjunction
        return term
    }

    static func assertion(
        _ type: ByteTermType,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ flags: UInt32,
        invert: Bool = false
    ) -> ByteTerm {
        var term = ByteTerm(type: type, flags: flags, invert: invert, matchDirection: matchDirection)
        term.inputPosition = inputPosition
        return term
    }

    static func checkInput(_ matchDirection: UInt8, _ count: UInt32) -> ByteTerm {
        var term = ByteTerm(type: .checkInput, flags: 0, matchDirection: matchDirection)
        term.a = count
        return term
    }

    static func alternative(_ type: ByteTermType, onceThrough: Bool = false, _ flags: UInt32) -> ByteTerm {
        var term = ByteTerm(type: type, flags: flags)
        term.a = 0
        term.b = 0
        term.c = onceThrough ? 1 : 0
        return term
    }

    // Accessors, by kind of term.
    var patternCharacter: UInt32 { a }
    var subpatternId: UInt32 { a }
    var alternativeNext: Int32 {
        get { Int32(bitPattern: a) }
        set { a = UInt32(bitPattern: newValue) }
    }
    mutating func setAlternativeEnd(_ offset: Int32) { b = UInt32(bitPattern: offset) }
    var onceThrough: Bool { c != 0 }
    mutating func setParenthesesWidth(_ width: UInt32) { c = width }
    var checkInputCount: UInt32 { a }
}

struct ByteDisjunction {
    var numSubpatterns: UInt32
    var frameSize: UInt32
    var terms: [ByteTerm] = []
}

// MARK: - The compiler

// A CheckedUint32 with RecordOverflow: an overflow is recorded, and reading the value after one traps.
private struct CheckedCount {
    private var storage: UInt32
    private(set) var hasOverflowed = false

    init(_ value: UInt32) {
        storage = value
    }

    var value: UInt32 {
        precondition(!hasOverflowed)
        return storage
    }

    static func + (lhs: CheckedCount, rhs: UInt32) -> CheckedCount {
        var result = lhs
        let (sum, overflow) = lhs.storage.addingReportingOverflow(rhs)
        result.storage = sum
        result.hasOverflowed = lhs.hasOverflowed || overflow
        return result
    }

    static func - (lhs: CheckedCount, rhs: UInt32) -> CheckedCount {
        var result = lhs
        let (difference, overflow) = lhs.storage.subtractingReportingOverflow(rhs)
        result.storage = difference
        result.hasOverflowed = lhs.hasOverflowed || overflow
        return result
    }
}

// The storage of the body's term list, kept between compiles, so that a compile does not allocate and free its
// largest transient array each time: at most `spareTermStorageCapacity` terms (16 KB) are kept.
private let spareTermStorage = Mutex<[ByteTerm]>([])
private let spareTermStorageCapacity = 16 * 1024 / MemoryLayout<ByteTerm>.stride

private struct ByteCompiler {
    private struct ParenthesesStackEntry {
        var beginTerm: Int
        var savedAlternativeIndex: Int
    }

    let pattern: YarrPatternModel
    let stackLimit = JSC.Yarr.yarrStackLimit()
    var body = ByteDisjunction(numSubpatterns: 0, frameSize: 0)
    var currentAlternativeIndex = 0
    private var parenthesesStack: [ParenthesesStackEntry] = []
    var allParenthesesInfo: [ByteDisjunction] = []
    let currentFlags: UInt32

    init(_ pattern: YarrPatternModel) {
        self.pattern = pattern
        currentFlags = pattern.flags
        spareTermStorage.withLock { swap(&$0, &body.terms) }
    }

    // Gives the body's term storage back for the next compile, once nothing reads the terms.
    mutating func returnTermStorage() {
        var terms: [ByteTerm] = []
        swap(&terms, &body.terms)
        if terms.capacity > spareTermStorageCapacity {
            return
        }
        terms.removeAll(keepingCapacity: true)
        spareTermStorage.withLock {
            if $0.capacity < terms.capacity {
                swap(&$0, &terms)
            }
        }
    }

    private func isSafeToRecurse() -> Bool {
        JSC.Yarr.yarrIsSafeToRecurse(stackLimit)
    }

    // Returns the ErrorCode, or noError when `body` and `allParenthesesInfo` hold the bytecode.
    mutating func compile() -> UInt32 {
        if !isSafeToRecurse() {
            return YarrErrorCode.tooManyDisjunctions
        }
        let bodyDisjunction = pattern.disjunctions[0]
        regexBegin(pattern.numSubpatterns, bodyDisjunction.callFrameSize, bodyDisjunction.alternatives[0].onceThrough)
        if let error = emitDisjunction(0, CheckedCount(0), 0) {
            return error
        }
        regexEnd()
        return YarrErrorCode.noError
    }

    private mutating func append(_ term: ByteTerm) {
        body.terms.append(term)
    }

    private mutating func atomPatternCharacter(
        _ ch: UInt32,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityMaxCount: UInt32,
        _ quantityType: QuantifierType,
        _ flags: UInt32
    ) {
        // For case-insesitive compares, non-ascii characters that have different
        // upper & lower case representations are converted to a character class.
        if flags & YarrFlag.ignoreCase != 0 && isASCIIAlpha(ch) {
            let lo = ch | 0x20
            let hi = ch & ~0x20
            if lo != hi {
                append(.casedCharacter(lo, hi, matchDirection, inputPosition, frameLocation, quantityMaxCount, quantityType, flags))
                return
            }
        }
        append(.character(ch, matchDirection, inputPosition, frameLocation, quantityMaxCount, quantityType, flags))
    }

    private mutating func atomCharacterClass(
        _ characterClass: UInt32,
        _ invert: Bool,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityMaxCount: UInt32,
        _ quantityType: QuantifierType,
        _ flags: UInt32
    ) {
        var term = ByteTerm.characterClass(characterClass, invert, matchDirection, inputPosition, flags)
        if quantityType != .fixedCount {
            term.quantityMinCount = 0
        }
        term.quantityMaxCount = quantityMaxCount
        term.quantityType = quantityType
        term.frameLocation = frameLocation
        append(term)
    }

    private mutating func atomBackReference(
        _ isNamed: Bool,
        _ subpatternId: UInt32,
        _ matchDirection: UInt8,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityMaxCount: UInt32,
        _ quantityType: QuantifierType,
        _ flags: UInt32
    ) {
        var term = ByteTerm.group(
            .directed(.backReference, .backReferenceBackward, matchDirection),
            subpatternId,
            capture: false,
            matchDirection: matchDirection,
            inputPosition,
            flags
        )
        if isNamed && pattern.hasDuplicateNamedCaptureGroups {
            let duplicateNamedGroupId = pattern.duplicateNamedGroupForSubpatternId[Int(subpatternId)]
            if duplicateNamedGroupId != 0 {
                term.b = duplicateNamedGroupId
            }
        }
        term.quantityMaxCount = quantityMaxCount
        term.quantityType = quantityType
        term.frameLocation = frameLocation
        append(term)
    }

    // ParenthesesSubpattern starts as a ParenthesesSubpatternOnceBegin, and atomParenthesesSubpatternEnd moves its
    // terms to a disjunction of their own.
    private mutating func atomParenthesesBegin(
        _ type: ByteTermType,
        _ subpatternId: UInt32,
        _ matchDirection: UInt8,
        _ capture: Bool,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ alternativeFrameLocation: UInt32
    ) {
        let beginTerm = body.terms.count
        var term = ByteTerm.group(type, subpatternId, capture: capture, matchDirection: matchDirection, inputPosition, currentFlags)
        term.frameLocation = frameLocation
        append(term)
        var alternative = ByteTerm.alternative(.alternativeBegin, currentFlags)
        alternative.frameLocation = alternativeFrameLocation
        append(alternative)
        parenthesesStack.append(ParenthesesStackEntry(beginTerm: beginTerm, savedAlternativeIndex: currentAlternativeIndex))
        currentAlternativeIndex = beginTerm + 1
    }

    private mutating func atomParentheticalAssertionBegin(
        _ subpatternId: UInt32,
        _ invert: Bool,
        _ matchDirection: UInt8,
        _ parentMatchDirection: UInt8,
        _ uncheckAmount: UInt32,
        _ frameLocation: UInt32,
        _ alternativeFrameLocation: UInt32
    ) {
        let beginTerm = body.terms.count
        var term = ByteTerm(type: .parentheticalAssertionBegin, flags: currentFlags, invert: invert, matchDirection: matchDirection)
        term.a = subpatternId
        term.parentMatchDirection = parentMatchDirection
        term.inputPosition = uncheckAmount
        term.frameLocation = frameLocation
        append(term)
        var alternative = ByteTerm.alternative(.alternativeBegin, currentFlags)
        alternative.frameLocation = alternativeFrameLocation
        append(alternative)
        parenthesesStack.append(ParenthesesStackEntry(beginTerm: beginTerm, savedAlternativeIndex: currentAlternativeIndex))
        currentAlternativeIndex = beginTerm + 1
    }

    private mutating func atomParentheticalAssertionEnd(
        _ lastSubpatternId: UInt32,
        _ frameLocation: UInt32,
        _ quantityMaxCount: UInt32,
        _ quantityType: QuantifierType
    ) {
        let beginTerm = popParenthesesStack()
        closeAlternative(beginTerm + 1)
        let endTerm = body.terms.count

        let invert = body.terms[beginTerm].invert
        let matchDirection = body.terms[beginTerm].matchDirection
        let subpatternId = body.terms[beginTerm].subpatternId

        var end = ByteTerm(type: .parentheticalAssertionEnd, flags: currentFlags, invert: invert, matchDirection: matchDirection)
        end.a = subpatternId
        end.b = lastSubpatternId
        append(end)
        body.terms[beginTerm].setParenthesesWidth(UInt32(endTerm - beginTerm))
        body.terms[endTerm].setParenthesesWidth(UInt32(endTerm - beginTerm))
        body.terms[endTerm].frameLocation = frameLocation

        body.terms[beginTerm].quantityMaxCount = quantityMaxCount
        body.terms[beginTerm].quantityType = quantityType
        body.terms[endTerm].quantityMaxCount = quantityMaxCount
        body.terms[endTerm].quantityType = quantityType
    }

    private mutating func popParenthesesStack() -> Int {
        let entry = parenthesesStack.removeLast()
        currentAlternativeIndex = entry.savedAlternativeIndex
        return entry.beginTerm
    }

    private mutating func closeAlternative(_ beginTermIn: Int) {
        var beginTerm = beginTermIn
        let origBeginTerm = beginTerm
        let endIndex = body.terms.count
        let frameLocation = body.terms[beginTerm].frameLocation

        if body.terms[beginTerm].alternativeNext == 0 {
            body.terms.remove(at: beginTerm)
        } else {
            while body.terms[beginTerm].alternativeNext != 0 {
                beginTerm += Int(body.terms[beginTerm].alternativeNext)
                body.terms[beginTerm].setAlternativeEnd(Int32(truncatingIfNeeded: endIndex - beginTerm))
                body.terms[beginTerm].frameLocation = frameLocation
            }
            body.terms[beginTerm].alternativeNext = Int32(truncatingIfNeeded: origBeginTerm - beginTerm)
            append(.alternative(.alternativeEnd, currentFlags))
            body.terms[endIndex].frameLocation = frameLocation
        }
    }

    private mutating func closeBodyAlternative() {
        var beginTerm = 0
        let origBeginTerm = 0
        let endIndex = body.terms.count
        let frameLocation = body.terms[beginTerm].frameLocation

        while body.terms[beginTerm].alternativeNext != 0 {
            beginTerm += Int(body.terms[beginTerm].alternativeNext)
            body.terms[beginTerm].setAlternativeEnd(Int32(truncatingIfNeeded: endIndex - beginTerm))
            body.terms[beginTerm].frameLocation = frameLocation
        }
        body.terms[beginTerm].alternativeNext = Int32(truncatingIfNeeded: origBeginTerm - beginTerm)
        append(.alternative(.bodyAlternativeEnd, currentFlags))
        body.terms[endIndex].frameLocation = frameLocation
    }

    private mutating func atomParenthesesSubpatternEnd(
        _ lastSubpatternId: UInt32,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityMinCount: UInt32,
        _ quantityMaxCount: UInt32,
        _ quantityType: QuantifierType,
        _ callFrameSize: UInt32
    ) {
        let beginTerm = popParenthesesStack()
        closeAlternative(beginTerm + 1)
        let endTerm = body.terms.count

        let parenthesesMatchDirection = body.terms[beginTerm].matchDirection
        let capture = body.terms[beginTerm].capture
        let subpatternId = body.terms[beginTerm].subpatternId

        let numSubpatterns = lastSubpatternId &- subpatternId &+ 1
        var parenthesesDisjunction = ByteDisjunction(numSubpatterns: numSubpatterns, frameSize: callFrameSize)
        let firstTermInParentheses = beginTerm + 1
        parenthesesDisjunction.terms.reserveCapacity(endTerm - firstTermInParentheses + 2)
        parenthesesDisjunction.terms.append(ByteTerm(type: .subpatternBegin, flags: currentFlags))
        parenthesesDisjunction.terms.append(contentsOf: body.terms[firstTermInParentheses..<endTerm])
        parenthesesDisjunction.terms.append(ByteTerm(type: .subpatternEnd, flags: currentFlags))

        body.terms.removeSubrange(beginTerm...)

        var term = ByteTerm.group(
            .parenthesesSubpattern,
            subpatternId,
            capture: capture,
            disjunction: UInt32(allParenthesesInfo.count),
            inputPosition,
            currentFlags
        )
        term.matchDirection = parenthesesMatchDirection
        append(term)
        allParenthesesInfo.append(parenthesesDisjunction)

        if pattern.hasDuplicateNamedCaptureGroups && capture {
            let duplicateNamedGroupId = pattern.duplicateNamedGroupForSubpatternId[Int(subpatternId)]
            if duplicateNamedGroupId != 0 {
                body.terms[beginTerm].b = duplicateNamedGroupId
            }
        }

        body.terms[beginTerm].quantityMinCount = quantityMinCount
        body.terms[beginTerm].quantityMaxCount = quantityMaxCount
        body.terms[beginTerm].quantityType = quantityType
        body.terms[beginTerm].frameLocation = frameLocation
    }

    // ParenthesesSubpatternOnceEnd or ParenthesesSubpatternTerminalEnd.
    private mutating func atomParenthesesEnd(
        _ type: ByteTermType,
        _ inputPosition: UInt32,
        _ frameLocation: UInt32,
        _ quantityMinCount: UInt32,
        _ quantityMaxCount: UInt32,
        _ quantityType: QuantifierType
    ) {
        let beginTerm = popParenthesesStack()
        closeAlternative(beginTerm + 1)
        let endTerm = body.terms.count

        let capture = body.terms[beginTerm].capture
        let subpatternId = body.terms[beginTerm].subpatternId

        append(.group(type, subpatternId, capture: capture, inputPosition, currentFlags))

        if pattern.hasDuplicateNamedCaptureGroups && body.terms[beginTerm].capture {
            let duplicateNamedGroupId = pattern.duplicateNamedGroupForSubpatternId[Int(subpatternId)]
            if duplicateNamedGroupId != 0 {
                body.terms[endTerm].b = duplicateNamedGroupId
                body.terms[beginTerm].b = duplicateNamedGroupId
            }
        }

        body.terms[beginTerm].setParenthesesWidth(UInt32(endTerm - beginTerm))
        body.terms[endTerm].setParenthesesWidth(UInt32(endTerm - beginTerm))
        body.terms[endTerm].frameLocation = frameLocation
        if type == .parenthesesSubpatternOnceEnd {
            body.terms[endTerm].matchDirection = body.terms[beginTerm].matchDirection
        }

        body.terms[beginTerm].quantityMinCount = quantityMinCount
        body.terms[beginTerm].quantityMaxCount = quantityMaxCount
        body.terms[beginTerm].quantityType = quantityType
        body.terms[endTerm].quantityMinCount = quantityMinCount
        body.terms[endTerm].quantityMaxCount = quantityMaxCount
        body.terms[endTerm].quantityType = quantityType
    }

    private mutating func regexBegin(_ numSubpatterns: UInt32, _ callFrameSize: UInt32, _ onceThrough: Bool) {
        // The terms keep the storage init() took.
        body.numSubpatterns = numSubpatterns
        body.frameSize = callFrameSize
        append(.alternative(.bodyAlternativeBegin, onceThrough: onceThrough, currentFlags))
        body.terms[0].frameLocation = 0
        currentAlternativeIndex = 0
    }

    private mutating func regexEnd() {
        closeBodyAlternative()
    }

    private mutating func alternativeDisjunction(_ type: ByteTermType, onceThrough: Bool = false) {
        let newAlternativeIndex = body.terms.count
        body.terms[currentAlternativeIndex].alternativeNext = Int32(truncatingIfNeeded: newAlternativeIndex - currentAlternativeIndex)
        append(.alternative(type, onceThrough: onceThrough, currentFlags))
        currentAlternativeIndex = newAlternativeIndex
    }

    private mutating func emitDisjunction(
        _ disjunctionIndex: UInt32,
        _ inputCountAlreadyChecked: CheckedCount,
        _ parenthesesInputCountAlreadyChecked: UInt32,
        _ matchDirection: UInt8 = yarrForward
    ) -> UInt32? {
        if !isSafeToRecurse() {
            return YarrErrorCode.tooManyDisjunctions
        }

        let disjunction = pattern.disjunctions[Int(disjunctionIndex)]
        for (alt, alternative) in disjunction.alternatives.enumerated() {
            var currentCountAlreadyChecked = inputCountAlreadyChecked

            if alt != 0 {
                if disjunctionIndex == 0 {
                    alternativeDisjunction(.bodyAlternativeDisjunction, onceThrough: alternative.onceThrough)
                } else {
                    alternativeDisjunction(.alternativeDisjunction)
                }
            }

            let countToCheck = alternative.minimumSize &- parenthesesInputCountAlreadyChecked
            if countToCheck != 0 {
                append(.checkInput(matchDirection, countToCheck))
                currentCountAlreadyChecked = currentCountAlreadyChecked + countToCheck
                if currentCountAlreadyChecked.hasOverflowed {
                    return YarrErrorCode.offsetTooLarge
                }
            }

            for term in alternative.terms {
                switch term.type {
                case .assertionBOL, .assertionEOL, .assertionBOI, .assertionEOI, .assertionWordBoundary:
                    let currentInputPosition = currentCountAlreadyChecked - term.inputPosition
                    if currentInputPosition.hasOverflowed {
                        return YarrErrorCode.offsetTooLarge
                    }
                    switch term.type {
                    case .assertionBOL:
                        append(.assertion(.assertionBOL, matchDirection, currentInputPosition.value, term.flags))
                    case .assertionEOL:
                        append(.assertion(.assertionEOL, matchDirection, currentInputPosition.value, term.flags))
                    case .assertionBOI:
                        append(.assertion(.assertionBOI, matchDirection, currentInputPosition.value, term.flags))
                    case .assertionEOI:
                        var eoi = ByteTerm.assertion(.assertionEOI, matchDirection, currentInputPosition.value, term.flags)
                        eoi.withOptionalLineTerminator = term.withOptionalLineTerminator
                        append(eoi)
                    default:
                        append(
                            .assertion(.assertionWordBoundary, matchDirection, currentInputPosition.value, term.flags, invert: term.invert)
                        )
                    }

                case .patternCharacter:
                    let currentInputPosition = currentCountAlreadyChecked - term.inputPosition
                    if currentInputPosition.hasOverflowed {
                        return YarrErrorCode.offsetTooLarge
                    }
                    atomPatternCharacter(
                        term.value,
                        matchDirection,
                        currentInputPosition.value,
                        term.frameLocation,
                        term.quantityMaxCount,
                        term.quantityType,
                        term.flags
                    )

                case .characterClass:
                    let currentInputPosition = currentCountAlreadyChecked - term.inputPosition
                    if currentInputPosition.hasOverflowed {
                        return YarrErrorCode.offsetTooLarge
                    }
                    atomCharacterClass(
                        term.value,
                        term.invert,
                        matchDirection,
                        currentInputPosition.value,
                        term.frameLocation,
                        term.quantityMaxCount,
                        term.quantityType,
                        term.flags
                    )

                case .numberedBackReference, .namedBackReference:
                    let currentInputPosition = currentCountAlreadyChecked - term.inputPosition
                    if currentInputPosition.hasOverflowed {
                        return YarrErrorCode.offsetTooLarge
                    }
                    atomBackReference(
                        term.type == .namedBackReference,
                        term.value,
                        matchDirection,
                        currentInputPosition.value,
                        term.frameLocation,
                        term.quantityMaxCount,
                        term.quantityType,
                        term.flags
                    )

                case .numberedForwardReference, .namedForwardReference:
                    break

                case .parenthesesSubpattern:
                    let nested = pattern.disjunctions[Int(term.value)]
                    var disjunctionAlreadyCheckedCount: UInt32 = 0
                    if term.quantityMaxCount == 1 && !term.isCopy {
                        var alternativeFrameLocation = term.frameLocation
                        // For QuantifierType::FixedCount we pre-check the minimum size; for greedy/non-greedy we reserve a slot in the frame.
                        if term.quantityType == .fixedCount {
                            disjunctionAlreadyCheckedCount = nested.minimumSize
                        } else {
                            alternativeFrameLocation &+= YarrStackSpace.parenthesesOnce
                        }
                        let delegateEndInputOffset = currentCountAlreadyChecked - term.inputPosition
                        if delegateEndInputOffset.hasOverflowed {
                            return YarrErrorCode.offsetTooLarge
                        }
                        atomParenthesesBegin(
                            .parenthesesSubpatternOnceBegin,
                            term.subpatternId,
                            matchDirection,
                            term.capture,
                            disjunctionAlreadyCheckedCount + delegateEndInputOffset.value,
                            term.frameLocation,
                            alternativeFrameLocation
                        )
                        if let error = emitDisjunction(
                            term.value,
                            currentCountAlreadyChecked,
                            disjunctionAlreadyCheckedCount,
                            matchDirection
                        ) {
                            return error
                        }
                        atomParenthesesEnd(
                            .parenthesesSubpatternOnceEnd,
                            delegateEndInputOffset.value,
                            term.frameLocation,
                            term.quantityMinCount,
                            term.quantityMaxCount,
                            term.quantityType
                        )
                    } else if term.isTerminal {
                        let delegateEndInputOffset = currentCountAlreadyChecked - term.inputPosition
                        if delegateEndInputOffset.hasOverflowed {
                            return YarrErrorCode.offsetTooLarge
                        }
                        atomParenthesesBegin(
                            .parenthesesSubpatternTerminalBegin,
                            term.subpatternId,
                            matchDirection,
                            term.capture,
                            disjunctionAlreadyCheckedCount + delegateEndInputOffset.value,
                            term.frameLocation,
                            term.frameLocation &+ YarrStackSpace.parenthesesTerminal
                        )
                        if let error = emitDisjunction(
                            term.value,
                            currentCountAlreadyChecked,
                            disjunctionAlreadyCheckedCount,
                            matchDirection
                        ) {
                            return error
                        }
                        atomParenthesesEnd(
                            .parenthesesSubpatternTerminalEnd,
                            delegateEndInputOffset.value,
                            term.frameLocation,
                            term.quantityMinCount,
                            term.quantityMaxCount,
                            term.quantityType
                        )
                    } else {
                        let delegateEndInputOffset = currentCountAlreadyChecked - term.inputPosition
                        if delegateEndInputOffset.hasOverflowed {
                            return YarrErrorCode.offsetTooLarge
                        }
                        atomParenthesesBegin(
                            .parenthesesSubpatternOnceBegin,
                            term.subpatternId,
                            matchDirection,
                            term.capture,
                            disjunctionAlreadyCheckedCount + delegateEndInputOffset.value,
                            term.frameLocation,
                            0
                        )
                        if let error = emitDisjunction(term.value, currentCountAlreadyChecked, 0, matchDirection) {
                            return error
                        }
                        atomParenthesesSubpatternEnd(
                            term.lastSubpatternId,
                            delegateEndInputOffset.value,
                            term.frameLocation,
                            term.quantityMinCount,
                            term.quantityMaxCount,
                            term.quantityType,
                            nested.callFrameSize
                        )
                    }

                case .parentheticalAssertion:
                    let alternativeFrameLocation = term.frameLocation &+ YarrStackSpace.parentheticalAssertion
                    let positiveInputOffset = currentCountAlreadyChecked - term.inputPosition
                    if positiveInputOffset.hasOverflowed {
                        return YarrErrorCode.offsetTooLarge
                    }

                    let sameDirection = term.matchDirection == matchDirection
                    let nested = pattern.disjunctions[Int(term.value)]
                    let origin: UInt32 = (term.matchDirection == yarrForward && matchDirection == yarrForward) ? term.inputPosition : 0

                    let alreadyChecked = min(sameDirection ? positiveInputOffset.value : term.inputPosition, nested.minimumSize)
                    let uncheckAmount =
                        sameDirection ? positiveInputOffset.value &- alreadyChecked : positiveInputOffset.value &+ alreadyChecked
                    atomParentheticalAssertionBegin(
                        term.subpatternId,
                        term.invert,
                        term.matchDirection,
                        matchDirection,
                        uncheckAmount,
                        term.frameLocation,
                        alternativeFrameLocation
                    )
                    if let error = emitDisjunction(term.value, CheckedCount(origin &+ alreadyChecked), alreadyChecked, term.matchDirection)
                    {
                        return error
                    }
                    atomParentheticalAssertionEnd(term.lastSubpatternId, term.frameLocation, term.quantityMaxCount, term.quantityType)

                case .dotStarEnclosure:
                    var enclosure = ByteTerm(type: .dotStarEnclosure, flags: currentFlags)
                    enclosure.a = (term.bolAnchor ? 1 : 0) | (term.eolAnchor ? 2 : 0)
                    append(enclosure)
                }
            }
        }
        return nil
    }
}

func isASCIIAlpha(_ ch: UInt32) -> Bool {
    (ch | 0x20) >= UInt32(UInt8(ascii: "a")) && (ch | 0x20) <= UInt32(UInt8(ascii: "z"))
}

// MARK: - The dump (Options::dumpCompiledRegExpPatterns)

private struct ByteTermDumper {
    let pattern: YarrPatternModel
    let allParenthesesInfo: [ByteDisjunction]
    var out: [UInt8] = []
    var nesting: UInt32 = 0
    var lineIndent: UInt32 = 0
    var recursiveDump = false

    var eitherUnicode: Bool { pattern.compileMode.eitherUnicode }

    mutating func print(_ text: Swift.String) {
        out.append(contentsOf: text.utf8)
    }

    mutating func printNumber(_ value: UInt32) {
        print(Swift.String(value))
    }

    mutating func outputTermIndexAndNest(_ index: Int, _ termNestingIn: UInt32) {
        var termNesting = termNestingIn
        if !recursiveDump {
            termNesting = 1
        }
        for _ in 0..<lineIndent {
            print(" ")
        }
        let digits = Swift.String(index)
        // printf("%4zu").
        for _ in digits.utf8.count..<max(4, digits.utf8.count) {
            print(" ")
        }
        print(digits)
        for _ in 0..<termNesting {
            print("  ")
        }
    }

    mutating func dumpQuantity(_ term: ByteTerm) {
        if term.quantityType == .fixedCount {
            if term.quantityMaxCount > 1 {
                print(" {")
                printNumber(term.quantityMaxCount)
                print("}")
            }
            return
        }
        print(" {")
        printNumber(term.quantityMinCount)
        if term.quantityMaxCount == UInt32.max {
            print(",inf")
        } else {
            print(",")
            printNumber(term.quantityMaxCount)
        }
        print("}")
        if term.quantityType == .greedy {
            print(" greedy")
        } else if term.quantityType == .nonGreedy {
            print(" non-greedy")
        }
    }

    mutating func dumpCaptured(_ term: ByteTerm) {
        if term.capture {
            print(" captured (#")
            printNumber(term.subpatternId)
            print(")")
        }
    }

    mutating func dumpInverted(_ term: ByteTerm) {
        if term.invert {
            print(" inverted")
        }
    }

    mutating func dumpMatchDirection(_ term: ByteTerm) {
        if term.matchDirection == yarrBackward {
            if term.type == .parentheticalAssertionBegin || term.type == .parentheticalAssertionEnd {
                print(" lookbehind")
            } else {
                print(" backward")
            }
        }
    }

    mutating func dumpInputPosition(_ term: ByteTerm) {
        print(" inputPosition ")
        printNumber(term.inputPosition)
    }

    mutating func dumpFrameLocation(_ term: ByteTerm) {
        print(" frameLocation ")
        printNumber(term.frameLocation)
    }

    // dumpChar32() in YarrPattern.cpp: the character itself from ' ' to 0xff, else "0x%04x".
    mutating func dumpCharacter(_ term: ByteTerm) {
        print(" ")
        let c = term.patternCharacter
        if c >= 0x20 && c <= 0xff {
            out.append(UInt8(ascii: "'"))
            out.append(UInt8(c))
            out.append(UInt8(ascii: "'"))
        } else {
            let digits = Swift.String(c, radix: 16)
            print("0x")
            for _ in digits.utf8.count..<max(4, digits.utf8.count) {
                print("0")
            }
            print(digits)
        }
    }

    mutating func dumpCharClass(_ term: ByteTerm) {
        print(" ")
        out.append(contentsOf: pattern.classes[Int(term.a)].dumpText)
    }

    mutating func dumpTerm(_ idx: Int, _ term: ByteTerm) {
        switch term.type {
        case .bodyAlternativeBegin:
            outputTermIndexAndNest(idx, nesting)
            nesting += 1
            print("BodyAlternativeBegin")
            if term.onceThrough {
                print(" onceThrough")
            }
        case .bodyAlternativeDisjunction:
            outputTermIndexAndNest(idx, nesting &- 1)
            print("BodyAlternativeDisjunction")
        case .bodyAlternativeEnd:
            nesting &-= 1
            outputTermIndexAndNest(idx, nesting)
            print("BodyAlternativeEnd")
        case .alternativeBegin:
            outputTermIndexAndNest(idx, nesting)
            nesting += 1
            print("AlternativeBegin")
            dumpFrameLocation(term)
        case .alternativeDisjunction:
            outputTermIndexAndNest(idx, nesting &- 1)
            print("AlternativeDisjunction")
            dumpFrameLocation(term)
        case .alternativeEnd:
            nesting &-= 1
            outputTermIndexAndNest(idx, nesting)
            print("AlternativeEnd")
            dumpFrameLocation(term)
        case .subpatternBegin:
            outputTermIndexAndNest(idx, nesting)
            nesting += 1
            print("SubpatternBegin")
            dumpMatchDirection(term)
        case .subpatternEnd:
            nesting &-= 1
            outputTermIndexAndNest(idx, nesting)
            print("SubpatternEnd")
            dumpMatchDirection(term)
        case .assertionBOL:
            outputTermIndexAndNest(idx, nesting)
            print("AssertionBOL")
            dumpMatchDirection(term)
            dumpInputPosition(term)
        case .assertionEOL:
            outputTermIndexAndNest(idx, nesting)
            print("AssertionEOL")
            dumpMatchDirection(term)
            dumpInputPosition(term)
        case .assertionBOI:
            outputTermIndexAndNest(idx, nesting)
            print("AssertionBOI")
            dumpMatchDirection(term)
            dumpInputPosition(term)
        case .assertionEOI:
            outputTermIndexAndNest(idx, nesting)
            print("AssertionEOI ")
            print(term.withOptionalLineTerminator ? "(\\Z)" : "(\\z)")
            dumpMatchDirection(term)
            dumpInputPosition(term)
        case .assertionWordBoundary:
            outputTermIndexAndNest(idx, nesting)
            print("AssertionWordBoundary")
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
        case .patternCharacterOnce, .patternCharacterOnceBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCharacterOnce")
            dumpInverted(term)
            dumpInputPosition(term)
            dumpCharacter(term)
            dumpQuantity(term)
            dumpMatchDirection(term)
        case .patternCharacterFixed, .patternCharacterFixedBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCharacterFixed")
            dumpInverted(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
            dumpCharacter(term)
            print(" {")
            printNumber(term.quantityMinCount)
            print("}")
            dumpMatchDirection(term)
        case .patternCharacterGreedy, .patternCharacterGreedyBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCharacterGreedy")
            dumpInverted(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
            dumpCharacter(term)
            dumpQuantity(term)
            dumpMatchDirection(term)
        case .patternCharacterNonGreedy, .patternCharacterNonGreedyBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCharacterNonGreedy")
            dumpInverted(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
            dumpCharacter(term)
            dumpQuantity(term)
            dumpMatchDirection(term)
        case .patternCasedCharacterOnce, .patternCasedCharacterOnceBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCasedCharacterOnce")
            dumpMatchDirection(term)
        case .patternCasedCharacterFixed, .patternCasedCharacterFixedBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCasedCharacterFixed")
            dumpMatchDirection(term)
        case .patternCasedCharacterGreedy, .patternCasedCharacterGreedyBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCasedCharacterGreedy")
            dumpMatchDirection(term)
        case .patternCasedCharacterNonGreedy, .patternCasedCharacterNonGreedyBackward:
            outputTermIndexAndNest(idx, nesting)
            print("PatternCasedCharacterNonGreedy")
            dumpMatchDirection(term)
        case .characterClass, .characterClassBackward:
            outputTermIndexAndNest(idx, nesting)
            print("CharacterClass")
            dumpInverted(term)
            dumpInputPosition(term)
            if term.quantityType != .fixedCount || eitherUnicode {
                dumpFrameLocation(term)
            }
            dumpCharClass(term)
            dumpQuantity(term)
            dumpMatchDirection(term)
        case .backReference, .backReferenceBackward:
            outputTermIndexAndNest(idx, nesting)
            print("BackReference #")
            printNumber(term.subpatternId)
            dumpInputPosition(term)
            dumpQuantity(term)
        case .parenthesesSubpattern:
            outputTermIndexAndNest(idx, nesting)
            print("ParenthesesSubpattern")
            dumpCaptured(term)
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
            dumpQuantity(term)
            if recursiveDump {
                print("\n")
                dumpDisjunction(allParenthesesInfo[Int(term.c)], nesting)
            }
        case .parenthesesSubpatternOnceBegin:
            outputTermIndexAndNest(idx, nesting)
            nesting += 1
            print("ParenthesesSubpatternOnceBegin")
            dumpCaptured(term)
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
        case .parenthesesSubpatternOnceEnd:
            nesting &-= 1
            outputTermIndexAndNest(idx, nesting)
            print("ParenthesesSubpatternOnceEnd")
            dumpCaptured(term)
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
        case .parenthesesSubpatternTerminalBegin:
            outputTermIndexAndNest(idx, nesting)
            nesting += 1
            print("ParenthesesSubpatternTerminalBegin")
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
        case .parenthesesSubpatternTerminalEnd:
            nesting &-= 1
            outputTermIndexAndNest(idx, nesting)
            print("ParenthesesSubpatternTerminalEnd")
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
        case .parentheticalAssertionBegin:
            outputTermIndexAndNest(idx, nesting)
            nesting += 1
            print("ParentheticalAssertionBegin")
            dumpInverted(term)
            dumpMatchDirection(term)
            print(" uncheck ")
            printNumber(term.inputPosition)
            print(term.parentMatchDirection == yarrBackward ? " backward" : "")
            dumpFrameLocation(term)
        case .parentheticalAssertionEnd:
            nesting &-= 1
            outputTermIndexAndNest(idx, nesting)
            print("ParentheticalAssertionEnd")
            dumpInverted(term)
            dumpMatchDirection(term)
            dumpInputPosition(term)
            dumpFrameLocation(term)
        case .checkInput:
            outputTermIndexAndNest(idx, nesting)
            print("CheckInput ")
            printNumber(term.checkInputCount)
            dumpMatchDirection(term)
        case .dotStarEnclosure:
            outputTermIndexAndNest(idx, nesting)
            print("DotStarEnclosure")
        }
    }

    mutating func dumpDisjunction(_ disjunction: ByteDisjunction, _ nestingIn: UInt32 = 0) {
        let savedLineIndent = lineIndent
        if nestingIn == 0 {
            // A disjunction has no address of its own here: the dump prints 0x0 where a pointer would be.
            print("ByteDisjunction(0x0):\n")
            recursiveDump = true
            nesting = 1
        } else {
            lineIndent = nestingIn - 1
        }
        for (idx, term) in disjunction.terms.enumerated() {
            dumpTerm(idx, term)
            if term.type != .parenthesesSubpattern {
                print("\n")
            }
        }
        lineIndent = savedLineIndent
    }
}

// MARK: - The bytecode

// Layout of the words interpret() reads (YarrInterpreterMatcher.swift):
// - header: flags, numSubpatterns, offsetVectorBaseForNamedCaptures, offsetsSize, numDuplicateNamedCaptureGroups,
//   endAnchoredFixedSize, the newline, wordchar and word-boundary classes' offsets, the body's offset, the offset
//   of duplicateNamedGroupForSubpatternId (its count, then its entries), and the body's prefilter;
// - each disjunction: numSubpatterns, frameSize, its term count, then its terms, `ByteCode.termStride` words each;
// - each class: anyCharacter, widths and whether it has a BMP table, the four counts, a bitmap of the Latin-1
//   characters' answers, then matches8, ranges8, matches32, ranges32.
enum ByteCode {
    static let flags = 0
    static let numSubpatterns = 1
    static let offsetVectorBaseForNamedCaptures = 2
    static let offsetsSize = 3
    static let numDuplicateNamedCaptureGroups = 4
    static let endAnchoredFixedSize = 5
    static let newlineClass = 6
    static let wordcharClass = 7
    static let ignoreCaseWordcharClass = 8
    static let body = 9
    static let duplicateNamedGroupForSubpatternId = 10
    // The body's prefilter term's offset plus one, or zero, and its distance from the start of a match (Matcher).
    static let prefilterTerm = 11
    static let prefilterDistance = 12
    static let headerSize = 13

    static let disjunctionNumSubpatterns = 0
    static let disjunctionFrameSize = 1
    static let disjunctionTermCount = 2
    static let disjunctionHeaderSize = 3

    // A term: its info word (type, flags, capture, invert, withOptionalLineTerminator, matchDirection,
    // parentMatchDirection, quantityType), then inputPosition, frameLocation, quantityMinCount, quantityMaxCount, a,
    // b and c. For a class term `a` is the class's offset, for ParenthesesSubpattern `c` is its disjunction's.
    static let termStride = 8
    static let termInfo = 0
    static let termInputPosition = 1
    static let termFrameLocation = 2
    static let termQuantityMinCount = 3
    static let termQuantityMaxCount = 4
    static let termA = 5
    static let termB = 6
    static let termC = 7

    static let infoFlagsShift: UInt32 = 8
    static let infoCapture: UInt32 = 1 << 16
    static let infoInvert: UInt32 = 1 << 17
    static let infoWithOptionalLineTerminator: UInt32 = 1 << 18
    static let infoMatchDirectionShift: UInt32 = 19
    static let infoParentMatchDirectionShift: UInt32 = 20
    static let infoQuantityTypeShift: UInt32 = 21

    static let classHeader = 0
    static let classMatches8Count = 1
    static let classRanges8Count = 2
    static let classMatches32Count = 3
    static let classRanges32Count = 4
    static let classLatin1Bitmap = 5
    static let classData = 13
}

// The answers the class gives for the Latin-1 characters, found as a match finds them: from a table when it has one
// (each table holds the class's matches and ranges), else by searching its matches and ranges, linearly up to six
// entries and by binary search beyond.
private func latin1Bitmap(_ characterClass: PatternCharacterClass, _ patternWords: Span<UInt32>) -> InlineArray<8, UInt32> {
    var bitmap = InlineArray<8, UInt32>(repeating: 0)
    let matches = patternWords.extracting(characterClass.matches8)
    let ranges = patternWords.extracting(characterClass.ranges8)
    if characterClass.anyCharacter {
        for i in bitmap.indices {
            bitmap[i] = ~0
        }
        return bitmap
    }
    // The searches below answer exactly whether a character is in the lists when the lists are sorted, as the
    // pattern's are: then the bits are set from the lists themselves. Otherwise each character is searched as the
    // matcher would.
    if characterClass.hasTable || characterClass.hasLatin1Table || isSorted(matches, ranges) {
        for i in matches.indices where matches[i] <= 0xFF {
            bitmap[Int(matches[i] >> 5)] |= 1 << (matches[i] & 31)
        }
        var i = 0
        while i + 1 < ranges.count {
            if ranges[i] <= 0xFF && ranges[i] <= ranges[i + 1] {
                for ch in ranges[i]...min(ranges[i + 1], 0xFF) {
                    bitmap[Int(ch >> 5)] |= 1 << (ch & 31)
                }
            }
            i += 2
        }
        return bitmap
    }
    for ch in UInt32(0)...0xFF where searchCharacterClass(matches, ranges, ch) {
        bitmap[Int(ch >> 5)] |= 1 << (ch & 31)
    }
    return bitmap
}

// Whether the matches ascend and the ranges are ordered, each ending below the next one's start.
private func isSorted(_ matches: Span<UInt32>, _ ranges: Span<UInt32>) -> Bool {
    var i = 1
    while i < matches.count {
        if matches[i - 1] > matches[i] {
            return false
        }
        i += 1
    }
    i = 0
    while i + 1 < ranges.count {
        if ranges[i] > ranges[i + 1] || (i + 2 < ranges.count && ranges[i + 1] >= ranges[i + 2]) {
            return false
        }
        i += 2
    }
    return true
}

func characterClassRangesContain(_ ranges: Span<UInt32>, _ ch: UInt32) -> Bool {
    var i = 0
    while i < ranges.count {
        if ch >= ranges[i] && ch <= ranges[i + 1] {
            return true
        }
        i += 2
    }
    return false
}

// testCharacterClass's search of a class's matches and ranges (pairs of begin and end).
func searchCharacterClass(_ matches: Span<UInt32>, _ ranges: Span<UInt32>, _ ch: UInt32) -> Bool {
    let thresholdForBinarySearch = 6
    if !matches.isEmpty {
        if matches.count > thresholdForBinarySearch {
            var low = 0
            var high = matches.count - 1
            while low <= high {
                let mid = low + (high - low) / 2
                let diff = Int32(bitPattern: ch &- matches[mid])
                if diff == 0 {
                    return true
                }
                if diff < 0 {
                    if mid == low {
                        break
                    }
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }
        } else {
            for i in matches.indices where matches[i] == ch {
                return true
            }
        }
    }
    let rangeCount = ranges.count / 2
    if rangeCount != 0 {
        if rangeCount > thresholdForBinarySearch {
            var low = 0
            var high = rangeCount - 1
            while low <= high {
                let mid = low + (high - low) / 2
                let rangeBeginDiff = Int32(bitPattern: ch &- ranges[2 * mid])
                if rangeBeginDiff >= 0 && ch <= ranges[2 * mid + 1] {
                    return true
                }
                if rangeBeginDiff < 0 {
                    if mid == low {
                        return false
                    }
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }
        } else if characterClassRangesContain(ranges, ch) {
            return true
        }
    }
    return false
}

// When the body is one alternative that begins by checking its input and then reads one character or class, matched
// once and forward: that term's index and where it reads from the start of a match. A start where the term does not
// match fails there, before anything else runs, so the matcher skips to the next start where it does.
private func bodyPrefilter(_ pattern: YarrPatternModel, _ body: ByteDisjunction) -> (term: Int, distance: UInt32)? {
    if body.terms.count < 3 || pattern.flags & YarrFlag.sticky != 0 {
        return nil
    }
    let begin = body.terms[0]
    let check = body.terms[1]
    // One alternative, not matched once through, then CheckInput, then the term, forward.
    if begin.type != .bodyAlternativeBegin || begin.alternativeNext != 0 || begin.onceThrough || check.type != .checkInput
        || check.checkInputCount == 0 || check.matchDirection != yarrForward
    {
        return nil
    }
    // Word boundaries and lookbehinds before the term change neither the position nor anything a later start reads:
    // a start the term rejects fails whatever they answer. A lookbehind qualifies when its terms capture nothing, call
    // no nested disjunction and take no frame capacity.
    var index = 2
    while index < body.terms.count {
        let term = body.terms[index]
        if term.type == .assertionWordBoundary {
            index += 1
            continue
        }
        if term.type == .parentheticalAssertionBegin && term.matchDirection == yarrBackward {
            let end = index + Int(term.c)
            if end < body.terms.count && body.terms[(index + 1)..<end].allSatisfy({ isSimpleLookbehindTerm($0.type) }) {
                index = end + 1
                continue
            }
        }
        break
    }
    if index >= body.terms.count {
        return nil
    }
    let first = body.terms[index]
    if first.matchDirection != yarrForward || first.inputPosition > check.checkInputCount {
        return nil
    }
    let eitherUnicode = pattern.compileMode.eitherUnicode
    switch first.type {
    case .patternCharacterOnce:
        let ch = first.patternCharacter
        if eitherUnicode && (ch > 0xFFFF || (ch >= 0xD800 && ch <= 0xDFFF)) {
            return nil
        }
    case .patternCasedCharacterOnce:
        if eitherUnicode {
            return nil
        }
    case .characterClass:
        if eitherUnicode || first.quantityType != .fixedCount || first.quantityMaxCount != 1 {
            return nil
        }
    default:
        return nil
    }
    return (index, check.checkInputCount - first.inputPosition)
}

private func isSimpleLookbehindTerm(_ type: ByteTermType) -> Bool {
    switch type {
    case .checkInput, .alternativeBegin, .alternativeDisjunction, .alternativeEnd, .assertionBOL, .assertionEOL,
        .assertionBOI, .assertionEOI, .assertionWordBoundary, .patternCharacterOnceBackward, .patternCharacterFixedBackward,
        .patternCharacterGreedyBackward, .patternCharacterNonGreedyBackward, .patternCasedCharacterOnceBackward,
        .patternCasedCharacterFixedBackward, .patternCasedCharacterGreedyBackward, .patternCasedCharacterNonGreedyBackward,
        .characterClassBackward:
        return true
    default:
        return false
    }
}

private func writeBytecode(
    _ pattern: YarrPatternModel,
    _ body: ByteDisjunction,
    _ allParenthesesInfo: [ByteDisjunction],
    _ patternWords: Span<UInt32>,
    into words: inout JSC.Yarr.YarrCompiledWords
) {
    let base = words.size()
    func put(_ word: UInt32) { words.push_back(word) }

    // Offsets are relative to the bytecode's start: lay the disjunctions and classes out first.
    var disjunctionOffsets: [UInt32] = []
    var offset = ByteCode.headerSize + 1 + pattern.duplicateNamedGroupForSubpatternId.count
    let bodyOffset = offset
    offset += ByteCode.disjunctionHeaderSize + body.terms.count * ByteCode.termStride
    for disjunction in allParenthesesInfo {
        disjunctionOffsets.append(UInt32(offset))
        offset += ByteCode.disjunctionHeaderSize + disjunction.terms.count * ByteCode.termStride
    }
    var classOffsets: [UInt32] = []
    for characterClass in pattern.classes {
        classOffsets.append(UInt32(offset))
        offset +=
            ByteCode.classData + characterClass.matches8.count + characterClass.ranges8.count + characterClass.matches32.count
            + characterClass.ranges32.count
    }

    let ignoreCaseWordcharClass = pattern.compileMode.eitherUnicode ? pattern.wordUnicodeIgnoreCaseClass : pattern.wordcharClass
    words.reserve(.init(Int(base) + offset))
    put(pattern.flags)
    put(body.numSubpatterns)
    put(pattern.offsetVectorBaseForNamedCaptures)
    put(pattern.offsetsSize)
    put(pattern.numDuplicateNamedCaptureGroups)
    put(pattern.endAnchoredFixedSize)
    put(classOffsets[Int(pattern.newlineClass)])
    put(classOffsets[Int(pattern.wordcharClass)])
    put(classOffsets[Int(ignoreCaseWordcharClass)])
    put(UInt32(bodyOffset))
    put(UInt32(ByteCode.headerSize))
    let prefilter = bodyPrefilter(pattern, body)
    put(prefilter.map { UInt32(bodyOffset + ByteCode.disjunctionHeaderSize + $0.term * ByteCode.termStride) + 1 } ?? 0)
    put(prefilter?.distance ?? 0)
    put(UInt32(pattern.duplicateNamedGroupForSubpatternId.count))
    for entry in pattern.duplicateNamedGroupForSubpatternId {
        put(entry)
    }

    func putDisjunction(_ disjunction: ByteDisjunction) {
        put(disjunction.numSubpatterns)
        put(disjunction.frameSize)
        put(UInt32(disjunction.terms.count))
        for term in disjunction.terms {
            var info = UInt32(term.type.rawValue) | (term.flags << ByteCode.infoFlagsShift)
            if term.capture {
                info |= ByteCode.infoCapture
            }
            if term.invert {
                info |= ByteCode.infoInvert
            }
            if term.withOptionalLineTerminator {
                info |= ByteCode.infoWithOptionalLineTerminator
            }
            info |= UInt32(term.matchDirection) << ByteCode.infoMatchDirectionShift
            info |= UInt32(term.parentMatchDirection) << ByteCode.infoParentMatchDirectionShift
            info |= UInt32(term.quantityType.rawValue) << ByteCode.infoQuantityTypeShift
            put(info)
            put(term.inputPosition)
            put(term.frameLocation)
            put(term.quantityMinCount)
            put(term.quantityMaxCount)
            switch term.type {
            case .characterClass, .characterClassBackward:
                put(classOffsets[Int(term.a)])
            default:
                put(term.a)
            }
            put(term.b)
            put(term.type == .parenthesesSubpattern ? disjunctionOffsets[Int(term.c)] : term.c)
        }
    }

    putDisjunction(body)
    for disjunction in allParenthesesInfo {
        putDisjunction(disjunction)
    }
    for characterClass in pattern.classes {
        put((characterClass.anyCharacter ? 1 : 0) | (characterClass.widths << 1) | (characterClass.hasTable ? 8 : 0))
        put(UInt32(characterClass.matches8.count))
        put(UInt32(characterClass.ranges8.count / 2))
        put(UInt32(characterClass.matches32.count))
        put(UInt32(characterClass.ranges32.count / 2))
        let bitmap = latin1Bitmap(characterClass, patternWords)
        for i in bitmap.indices {
            put(bitmap[i])
        }
        for i in characterClass.matches8 {
            put(patternWords[i])
        }
        for i in characterClass.ranges8 {
            put(patternWords[i])
        }
        for i in characterClass.matches32 {
            put(patternWords[i])
        }
        for i in characterClass.ranges32 {
            put(patternWords[i])
        }
    }
    precondition(words.size() - base == offset)
}

/// Frees the storage the bytecode compiler and the interpreter keep between calls: the pattern model, the term list
/// and the spare frame storage. The next compile or match that needs storage allocates it again.
@_expose(Cxx)
func yarrReleaseSpareStorage() {
    spareModel.withLock { $0 = YarrPatternModel() }
    spareTermStorage.withLock { $0 = [] }
    releaseSpareFrameStorage()
}

/// Compiles a YarrPattern to bytecode.
///
/// `pattern` is the words of PatternWriter in YarrInterpreter.cpp, a Vector on byteCompile()'s stack that it owns
/// and that nothing writes while this runs; its elements are integers. Returns an ErrorCode, the dump's byte count and
/// bytes (four to a word; none unless `dump`), then the bytecode.
// FIXME: Take a Span parameter once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func yarrByteCompile(_ pattern: JSC.Yarr.YarrPatternWords, _ dump: Bool) -> JSC.Yarr.YarrCompiledWords {
    let words = unsafe Span<UInt32>(_unsafeCxxSpan: pattern)
    var model = YarrPatternModel()
    spareModel.withLock { swap(&$0, &model) }
    readPattern(words, into: &model)
    var compiler = ByteCompiler(model)
    let error = compiler.compile()

    var result = JSC.Yarr.YarrCompiledWords()
    result.push_back(error)
    if error != YarrErrorCode.noError {
        result.push_back(0)
        return result
    }

    if dump {
        var dumper = ByteTermDumper(pattern: model, allParenthesesInfo: compiler.allParenthesesInfo)
        dumper.dumpDisjunction(compiler.body)
        result.push_back(UInt32(dumper.out.count))
        var word: UInt32 = 0
        for (i, byte) in dumper.out.enumerated() {
            word |= UInt32(byte) << (8 * UInt32(i % 4))
            if i % 4 == 3 {
                result.push_back(word)
                word = 0
            }
        }
        if dumper.out.count % 4 != 0 {
            result.push_back(word)
        }
    } else {
        result.push_back(0)
    }

    writeBytecode(model, compiler.body, compiler.allParenthesesInfo, words, into: &result)
    compiler.returnTermStorage()
    _ = consume compiler
    if model.storageSize <= spareModelLimit {
        spareModel.withLock { swap(&$0, &model) }
    }
    return result
}
