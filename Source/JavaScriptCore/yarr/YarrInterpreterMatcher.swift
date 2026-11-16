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

internal import JSCSwiftBoundary
import Synchronization

// The regular expression interpreter: a backtracking matcher over the bytecode of YarrByteCompiler.swift.

private let errorCodePoint: UInt32 = 0xFFFF_FFFF
// The limit on matchDisjunction calls, which keeps exponential backtracking from running for ever.
private let matchLimit: UInt32 = 100_000_000
// A frame slot that holds no input position.
private let notFound = UInt.max
private let endAnchoredFixedSizeNotSet = UInt32.max

private enum MatchResult {
    case match
    case noMatch
    case errorHitLimit
    case errorNoMemory
}

@inline(always)
private func isBMP(_ c: UInt32) -> Bool { c <= 0xFFFF }
@inline(always)
private func isLeadSurrogate(_ c: UInt32) -> Bool { c & 0xFFFF_FC00 == 0xD800 }
@inline(always)
private func isTrailSurrogate(_ c: UInt32) -> Bool { c & 0xFFFF_FC00 == 0xDC00 }
@inline(always)
private func supplementary(_ lead: UInt32, _ trail: UInt32) -> UInt32 {
    (lead << 10) &+ trail &- ((0xD800 << 10) &+ 0xDC00 &- 0x10000)
}
@inline(always)
private func isASCII(_ c: UInt32) -> Bool { c < 0x80 }
@inline(always)
private func toASCIIUpper(_ c: UInt32) -> UInt32 {
    c >= UInt32(UInt8(ascii: "a")) && c <= UInt32(UInt8(ascii: "z")) ? c & ~0x20 : c
}

// The capacity accounting of WTF's BumpPointerPool at Options::maxRegExpStackSize(), so that a match runs out of
// frame capacity, and fails with ErrorNoMemory, at the point where that allocator would: pools of at least a page,
// each a power of two that holds a pool header, chained until the capacity is spent, and unwound in order.
//
// Every context after the body's takes as many words of the store as it takes bytes of capacity, over 8 (the layouts
// below are padded to it), and a free drops a context with every one allocated after it, so where a context sits
// in its pool is a function of its index in the store: a pool in use records the store index at which its free bytes
// began, and the bytes used in the current pool follow from the store's word count. No context records where its
// capacity was taken.
private struct FrameCapacity: ~Copyable {
    private static let poolHeaderSize = 56
    private static let minimumPoolSize = 0x1000

    private struct Pool {
        var size: Int
        var remaining: Int
        // While the pool is in use, the store index at which its byte `startOffset` is; Int.max when it is not.
        var startWord: Int
        var startOffset: Int
    }

    // The first pool, then the ones chained after it, which most matches never need.
    private var head: Pool
    private var chained = UniqueArray<Pool>()
    private var current = 0
    private let pageSize: Int
    // The store index at which the current pool's free bytes began (for the head pool, where the body's context
    // ends), and the one at which it is full.
    private(set) var start = Int.max
    private(set) var limit = 0

    init(maxCapacity: Int, pageSize: Int) {
        self.pageSize = pageSize
        let headSize = Self.poolSize(for: 0, pageSize: pageSize)
        precondition(headSize <= maxCapacity)
        head = Pool(size: headSize, remaining: maxCapacity - headSize, startWord: Int.max, startOffset: 0)
    }

    private static func poolSize(for size: Int, pageSize: Int) -> Int {
        let minimumCapacity = size + poolHeaderSize
        var poolSize = max(minimumPoolSize, pageSize)
        while poolSize < minimumCapacity {
            poolSize <<= 1
        }
        return poolSize
    }

    private func pool(_ index: Int) -> Pool {
        index == 0 ? head : chained[index - 1]
    }

    private mutating func setStart(_ index: Int, word: Int, offset: Int) {
        if index == 0 {
            head.startWord = word
            head.startOffset = offset
        } else {
            chained[index - 1].startWord = word
            chained[index - 1].startOffset = offset
        }
    }

    private mutating func enterCurrent() {
        let pool = pool(current)
        start = pool.startWord
        limit = pool.startWord + (pool.size - Self.poolHeaderSize - pool.startOffset) / 8
    }

    // The body's context, the match's first allocation: `size` bytes, the store's words for the contexts after it
    // starting at index `nextWord`. False when the capacity is spent.
    @inline(always)
    mutating func allocateBody(_ size: Int, nextWord: Int) -> Bool {
        if size <= head.size - Self.poolHeaderSize {
            head.startWord = nextWord
            head.startOffset = size
            start = nextWord
            limit = nextWord + (head.size - Self.poolHeaderSize - size) / 8
            return true
        }
        return allocateBodySlowCase(size, nextWord: nextWord)
    }

    @inline(never)
    private mutating func allocateBodySlowCase(_ size: Int, nextWord: Int) -> Bool {
        let newSize = Self.poolSize(for: size, pageSize: pageSize)
        if newSize > head.remaining {
            return false
        }
        chained.append(Pool(size: newSize, remaining: head.remaining - newSize, startWord: Int.max, startOffset: 0))
        current = 1
        setStart(current, word: nextWord, offset: size)
        enterCurrent()
        return true
    }

    // Takes `count` words' bytes for a context at store index `at`, or returns false when the capacity is spent.
    mutating func allocate(at: Int, _ count: Int) -> Bool {
        if at + count <= limit {
            return true
        }
        let size = 8 * count
        var previous = current
        var index = current + 1
        while true {
            if index == chained.count + 1 {
                let newSize = Self.poolSize(for: size, pageSize: pageSize)
                let remaining = pool(previous).remaining
                if newSize > remaining {
                    return false
                }
                chained.append(Pool(size: newSize, remaining: remaining - newSize, startWord: Int.max, startOffset: 0))
                break
            }
            // A pool past the current one is empty.
            if size <= pool(index).size - Self.poolHeaderSize {
                break
            }
            previous = index
            index += 1
        }
        current = index
        setStart(current, word: at, offset: 0)
        enterCurrent()
        return true
    }

    // Frees every context from store index `word` on, which is before the current pool's start: the pools after
    // the one holding it are emptied.
    mutating func free(from word: Int) {
        while word < pool(current).startWord {
            setStart(current, word: Int.max, offset: 0)
            precondition(current > 0)
            current -= 1
        }
        enterCurrent()
    }
}

// The frame storage a finished match leaves for the next one whose frames outgrow its inline words: at most
// `spareFrameStorageCount` arrays of at most `spareFrameStorageWords` words, so a match that spills allocates only
// when none is spare, and what is kept between matches is bounded: 64 KB in all.
private let spareFrameStorage = Mutex<UniqueArray<UniqueArray<UInt>>>(UniqueArray())

// Frees the spare frame storage (yarrReleaseSpareStorage in YarrByteCompiler.swift).
func releaseSpareFrameStorage() {
    spareFrameStorage.withLock { $0.removeAll() }
}
private let spareFrameStorageCount = 2
private let spareFrameStorageWords = 4096

// Inlining. `@inline(always)` is inlined in every build, -Onone too, where each inlined copy keeps stack slots of its
// own: on the handlers matchDisjunction calls from many places it made that frame over half a megabyte in Debug, past
// the stack check's 64 KB reserved zone, so a deep pattern overflowed the stack before the check could fail it. Those
// handlers are `@inline(__always)`, which the optimizer inlines and -Onone does not; `@inline(always)` stays on the
// leaves and the handlers whose inlining the optimizer does not do by itself (measured: the character and class
// checks, the parenthetical assertions).

// Frame record layouts in the matcher's store, in words. Store indices are sums of a context's index and these small
// offsets or a term's frame location, all below the store's word count, so their arithmetic is unchecked (&+); a
// wrong index still traps in the store's bounds checks.
// A disjunction context: the term being matched, the match's begin and end, then the disjunction's frame: the
// backtracking state of each term, at its frameLocation. It takes 16 + 8 * frameSize bytes of capacity (the C++'s
// DisjunctionContext), one word fewer than its words.
private enum Context {
    static let term = 0
    static let matchBegin = 1
    static let matchEnd = 2
    static let frame = 3
}

// A parentheses context, one per iteration of a ParenthesesSubpattern: the previous iteration's context (its index
// plus one, or zero), the number of nested subpatterns and of their duplicate named groups, the output entries it
// saved, two to a 64-bit word (the subpatterns' begin and end, then the duplicate named groups' entries), then the
// context of the iteration's disjunction, then two unused words, so that its words are the capacity the C++'s
// ParenthesesDisjunctionContext takes (48 bytes and an unsigned per saved entry, rounded to 8) and its
// DisjunctionContext's, over 8.
private enum ParenthesesContext {
    static let next = 0
    static let numNestedSubpatterns = 1
    static let numDuplicateNamedGroups = 2
    static let backup = 3
    static let padding = 2
}

// The backtracking state of each kind of term, as frame slots from its frameLocation.
private enum Slot {
    static let begin = 0
    static let matchAmount = 1
    static let alternativeOffset = 0
    static let terminalEntryPosition = 1
    static let parenthesesLastContext = 2
}

// The checks that the quantified matches repeat.
private enum Check {
    case character
    case surrogatePair
    case casedCharacter
    case characterClass
    case characterClassDontAdvanceInputForNonBMP
}

// A byte term's words, as the matcher reads them: the info word at once, the others where a handler needs them.
private struct Term: ~Escapable {
    let words: Span<UInt32>
    let info: UInt32

    @_lifetime(copy words)
    @inline(always)
    init(_ words: Span<UInt32>) {
        self.words = words
        info = words[ByteCode.termInfo]
    }

    @inline(always)
    var inputPosition: UInt32 { words[ByteCode.termInputPosition] }
    @inline(always)
    var frameLocationWord: UInt32 { words[ByteCode.termFrameLocation] }
    @inline(always)
    var quantityMinCount: UInt32 { words[ByteCode.termQuantityMinCount] }
    @inline(always)
    var quantityMaxCount: UInt32 { words[ByteCode.termQuantityMaxCount] }
    @inline(always)
    var a: UInt32 { words[ByteCode.termA] }
    @inline(always)
    var b: UInt32 { words[ByteCode.termB] }
    @inline(always)
    var c: UInt32 { words[ByteCode.termC] }

    @inline(always)
    var frameLocation: Int { Int(frameLocationWord) }
    @inline(always)
    var type: ByteTermType { ByteTermType(rawValue: UInt8(truncatingIfNeeded: info))! }
    @inline(always)
    var quantityType: QuantifierType { QuantifierType(rawValue: UInt8(truncatingIfNeeded: info >> ByteCode.infoQuantityTypeShift) & 3)! }
    @inline(always)
    var matchDirection: UInt8 { UInt8(truncatingIfNeeded: info >> ByteCode.infoMatchDirectionShift) & 1 }
    @inline(always)
    var parentMatchDirection: UInt8 { UInt8(truncatingIfNeeded: info >> ByteCode.infoParentMatchDirectionShift) & 1 }
    @inline(always)
    var capture: Bool { info & ByteCode.infoCapture != 0 }
    @inline(always)
    var invert: Bool { info & ByteCode.infoInvert != 0 }
    @inline(always)
    var withOptionalLineTerminator: Bool { info & ByteCode.infoWithOptionalLineTerminator != 0 }
    @inline(always)
    var termFlags: UInt32 { (info >> ByteCode.infoFlagsShift) & 0xFF }
    @inline(always)
    var ignoreCase: Bool { termFlags & YarrFlag.ignoreCase != 0 }
    @inline(always)
    var multiline: Bool { termFlags & YarrFlag.multiline != 0 }
    @inline(always)
    var dotAll: Bool { termFlags & YarrFlag.dotAll != 0 }
    var patternCharacter: UInt32 { a }
    var subpatternId: UInt32 { a }
    var duplicateNamedGroupId: UInt32 { b }
    var lastSubpatternId: UInt32 { b }
    var parenthesesWidth: Int { Int(c) }
    var parenthesesDisjunction: Int { Int(c) }
    var characterClass: Int { Int(a) }
}

private struct Matcher<Unit: FixedWidthInteger & UnsignedInteger>: ~Copyable, ~Escapable {
    let code: Span<UInt32>
    let input: Span<Unit>
    var output: MutableSpan<UInt32>

    let compileMode: CompileMode
    let decodeSurrogatePairs: Bool
    let length: UInt32
    let startOffset: UInt32
    var pos: UInt32
    var remainingMatchCount = matchLimit
    let stackLimit = JSC.Yarr.yarrStackLimit()

    let flags: UInt32
    let newlineClass: Int
    let wordcharClass: Int
    let ignoreCaseWordcharClass: Int
    let offsetVectorBaseForNamedCaptures: UInt32
    let hasDuplicateNamedCaptureGroups: Bool
    let duplicateNamedGroupForSubpatternId: Int

    // The frames: their first words on the stack, the rest on the heap, which keeps its storage when frames are
    // dropped. Every accessor is mutating: a borrowed `self` would be copied, inline words and all.
    // The body's prefilter (bodyPrefilter() in YarrByteCompiler.swift): its term's offset, or -1, and where it reads
    // from the start of a match.
    let bodyDisjunction: Int
    let prefilterTerm: Int
    let prefilterDistance: UInt32

    var inlineWords = InlineArray<40, UInt>(repeating: 0)
    var heapWords = UniqueArray<UInt>()
    // The store's end: past the body's context, at least 40.
    var wordCount = 0
    // The end a context's words can reach without takeContextWordsSlowCase: the current pool's capacity or the heap
    // words', whichever is less.
    var fastLimit = 0
    var capacity: FrameCapacity

    @_lifetime(copy code, copy input, copy output)
    init(code: Span<UInt32>, input: Span<Unit>, start: UInt32, output: consuming MutableSpan<UInt32>, maxStackSize: Int, pageSize: Int) {
        self.code = code
        self.input = input
        self.output = output
        flags = code[ByteCode.flags]
        compileMode = CompileMode(flags: flags)
        decodeSurrogatePairs = compileMode.eitherUnicode
        length = UInt32(input.count)
        startOffset = start
        pos = start
        newlineClass = Int(code[ByteCode.newlineClass])
        wordcharClass = Int(code[ByteCode.wordcharClass])
        ignoreCaseWordcharClass = Int(code[ByteCode.ignoreCaseWordcharClass])
        offsetVectorBaseForNamedCaptures = code[ByteCode.offsetVectorBaseForNamedCaptures]
        hasDuplicateNamedCaptureGroups = code[ByteCode.numDuplicateNamedCaptureGroups] != 0
        duplicateNamedGroupForSubpatternId = Int(code[ByteCode.duplicateNamedGroupForSubpatternId])
        capacity = FrameCapacity(maxCapacity: maxStackSize, pageSize: pageSize)
        bodyDisjunction = Int(code[ByteCode.body])
        prefilterTerm = Int(code[ByteCode.prefilterTerm]) - 1
        prefilterDistance = code[ByteCode.prefilterDistance]
    }

    // MARK: Terms

    @inline(always)
    func termOffset(_ disjunction: Int, _ index: Int) -> Int {
        disjunction &+ ByteCode.disjunctionHeaderSize &+ index &* ByteCode.termStride
    }

    // A term's words, from its disjunction and index. The offset is computed in 32 bits, as the bytecode's offsets are,
    // so that its range needs no overflow check: the bytecode is far smaller than 2^32 words, so it cannot wrap.
    @inline(always)
    @_lifetime(copy self)
    func term(_ disjunction: Int, _ index: Int) -> Term {
        Self.term(code, disjunction, index)
    }

    // The same, over a span the caller holds: matchDisjunction keeps the bytecode span in a register, so the term's
    // bounds check compares it there rather than reloading the count from the matcher for each term.
    @inline(always)
    @_lifetime(copy code)
    static func term(_ code: Span<UInt32>, _ disjunction: Int, _ index: Int) -> Term {
        let offset = Int(
            UInt32(truncatingIfNeeded: disjunction) &+ UInt32(ByteCode.disjunctionHeaderSize)
                &+ UInt32(truncatingIfNeeded: index) &* UInt32(ByteCode.termStride))
        return Term(code.extracting(offset..<offset &+ ByteCode.termStride))
    }

    @inline(always)
    @_lifetime(copy self)
    func loadTerm(_ offset: Int) -> Term {
        Term(code.extracting(offset..<offset &+ ByteCode.termStride))
    }

    var isLegacyCompilation: Bool { compileMode == .legacy }
    var isEitherUnicodeCompilation: Bool { compileMode.eitherUnicode }
    var sticky: Bool { flags & YarrFlag.sticky != 0 }

    @inline(__always)
    func offsetForDuplicateNamedGroupId(_ duplicateNamedGroupId: UInt32) -> Int {
        Int(offsetVectorBaseForNamedCaptures &+ duplicateNamedGroupId &- 1)
    }

    // MARK: Skipping starts that cannot match

    // The first start from `start` on whose first character the prefilter term matches, or the input's end.
    func nextCandidate(_ start: UInt32) -> UInt32 {
        if prefilterTerm < 0 {
            return start
        }
        let first = loadTerm(prefilterTerm)
        let distance = prefilterDistance
        let last = length &- (code[termOffset(bodyDisjunction, 1) + ByteCode.termA])
        if length < code[termOffset(bodyDisjunction, 1) + ByteCode.termA] {
            return length
        }
        var candidate = start
        switch first.type {
        case .patternCharacterOnce:
            let ch = first.patternCharacter
            while candidate <= last {
                if unit(candidate &+ distance) == ch {
                    return candidate
                }
                candidate += 1
            }
        case .patternCasedCharacterOnce:
            while candidate <= last {
                let c = unit(candidate &+ distance)
                if c == first.a || c == first.b {
                    return candidate
                }
                candidate += 1
            }
        default:
            let cls = first.characterClass
            let invert = first.invert
            while candidate <= last {
                if testCharacterClass(cls, unit(candidate &+ distance)) != invert {
                    return candidate
                }
                candidate += 1
            }
        }
        return length
    }

    // MARK: The store

    // The store's words: the body's context in the inline words when it fits there, every other context in the heap
    // words, whose index 0 is the store's index 40.
    @inline(__always)
    mutating func word(_ index: Int) -> UInt {
        // An unsigned compare: below 40 is an inline word with no further check; a negative index goes to the heap
        // words, whose bounds check stops it.
        if UInt(bitPattern: index) < 40 {
            return inlineWords[index]
        }
        return heapWords[index &- 40]
    }

    @inline(__always)
    mutating func setWord(_ index: Int, _ value: UInt) {
        if UInt(bitPattern: index) < 40 {
            inlineWords[index] = value
        } else {
            heapWords[index &- 40] = value
        }
    }

    // A word of a parentheses context, or of its disjunction's: in the heap words (an index below 40 fails their
    // bounds check).
    @inline(__always)
    mutating func heapWord(_ index: Int) -> UInt { heapWords[index &- 40] }

    @inline(__always)
    mutating func setHeapWord(_ index: Int, _ value: UInt) { heapWords[index &- 40] = value }

    @inline(never)
    mutating func takeSpareFrameStorage() {
        // The spare storage keeps its words: past wordCount they are never read, and are written before they
        // are, so the next match reuses them rather than appending them again.
        if let spare = spareFrameStorage.withLock({ $0.isEmpty ? nil : $0.removeLast() }) {
            heapWords = spare
        } else {
            heapWords.reserveCapacity(256)
        }
    }

    mutating func returnSpareFrameStorage() {
        if heapWords.capacity == 0 || heapWords.capacity > spareFrameStorageWords {
            return
        }
        var words: UniqueArray<UInt>? = UniqueArray()
        swap(&words!, &heapWords)
        spareFrameStorage.withLock {
            if $0.count < spareFrameStorageCount {
                $0.append(words.take()!)
            }
        }
    }

    // Takes `count` words at the end of the store for a context, and their capacity: returns where they start, or nil
    // when the capacity is spent. Their values are whatever the store last held there: the caller writes the ones it
    // reads.
    @inline(__always)
    mutating func takeContextWords(_ count: Int) -> Int? {
        let start = wordCount
        if start &+ count > fastLimit {
            if !takeContextWordsSlowCase(count) {
                return nil
            }
        }
        wordCount = start &+ count
        return start
    }

    @inline(never)
    mutating func takeContextWordsSlowCase(_ count: Int) -> Bool {
        if !capacity.allocate(at: wordCount, count) {
            return false
        }
        let end = wordCount + count - 40
        if end > heapWords.count {
            if heapWords.isEmpty {
                takeSpareFrameStorage()
            }
            if end > heapWords.count {
                heapWords.append(copying: repeatElement(0, count: end - heapWords.count))
            }
        }
        fastLimit = min(capacity.limit, 40 + heapWords.count)
        return true
    }

    // MARK: Frames

    @inline(__always)
    mutating func frame(_ context: Int, _ t: Term, _ slot: Int) -> UInt {
        word(context &+ Context.frame &+ t.frameLocation &+ slot)
    }

    @inline(__always)
    mutating func setFrame(_ context: Int, _ t: Term, _ slot: Int, _ value: UInt) {
        setWord(context &+ Context.frame &+ t.frameLocation &+ slot, value)
    }

    @inline(__always)
    mutating func contextTerm(_ context: Int) -> Int { Int(bitPattern: word(context &+ Context.term)) }
    @inline(__always)
    mutating func setContextTerm(_ context: Int, _ term: Int) { setWord(context &+ Context.term, UInt(bitPattern: term)) }
    @inline(__always)
    mutating func matchBegin(_ context: Int) -> UInt32 { UInt32(truncatingIfNeeded: word(context &+ Context.matchBegin)) }
    @inline(__always)
    mutating func matchEnd(_ context: Int) -> UInt32 { UInt32(truncatingIfNeeded: word(context &+ Context.matchEnd)) }
    @inline(__always)
    mutating func setMatchBegin(_ context: Int, _ value: UInt32) { setWord(context &+ Context.matchBegin, UInt(value)) }
    @inline(__always)
    mutating func setMatchEnd(_ context: Int, _ value: UInt32) { setWord(context &+ Context.matchEnd, UInt(value)) }

    // The match's first context: in the inline words when it fits, which are still the zeros the matcher was made
    // with, else first in the heap words. It takes 16 + 8 * frameSize bytes of capacity.
    mutating func allocBodyContext(_ disjunction: Int) -> Int? {
        let frameSize = Int(code[disjunction + ByteCode.disjunctionFrameSize])
        let words = Context.frame + frameSize
        let inline = words <= 40
        let next = inline ? 40 : 40 + words
        if !capacity.allocateBody(16 + 8 * frameSize, nextWord: next) {
            return nil
        }
        wordCount = next
        if !inline {
            if heapWords.isEmpty {
                takeSpareFrameStorage()
            }
            if words > heapWords.count {
                heapWords.append(copying: repeatElement(0, count: words - heapWords.count))
            }
            heapWords[Context.term] = 0
        }
        fastLimit = min(capacity.limit, 40 + heapWords.count)
        return inline ? 0 : 40
    }

    // Frees a parentheses context and every context after it.
    @inline(__always)
    mutating func freeContext(_ context: Int) {
        precondition(context <= wordCount)
        wordCount = context
        if context < capacity.start {
            capacity.free(from: context)
            fastLimit = min(capacity.limit, 40 + heapWords.count)
        }
    }

    @inline(__always)
    mutating func parenthesesDisjunctionContext(_ context: Int) -> Int {
        // Without duplicate named groups, the count of their entries is not stored (allocParenthesesDisjunctionContext).
        let groups = hasDuplicateNamedCaptureGroups ? Int(heapWord(context &+ ParenthesesContext.numDuplicateNamedGroups)) : 0
        return context &+ ParenthesesContext.backup &+ Int(heapWord(context &+ ParenthesesContext.numNestedSubpatterns)) &+ (groups &+ 1) &>> 1
    }

    // A parentheses context: it takes the capacity a parentheses context takes in a BumpPointerPool (48 bytes and an
    // unsigned per saved entry, rounded to 8), and its disjunction context's, as that many words over 8.
    // Returns the parentheses context and its disjunction's context.
    mutating func allocParenthesesDisjunctionContext(_ disjunction: Int, _ t: Term) -> (context: Int, disjunctionContext: Int)? {
        let firstSubpatternId = t.subpatternId
        if hasDuplicateNamedCaptureGroups {
            guard let context = allocParenthesesDisjunctionContextWithDuplicateNamedGroups(disjunction, firstSubpatternId) else {
                return nil
            }
            return (context, parenthesesDisjunctionContext(context))
        }
        let first = Int(firstSubpatternId << 1)
        let numNestedSubpatterns = Int(code[disjunction + ByteCode.disjunctionNumSubpatterns])
        let frameSize = Int(code[disjunction + ByteCode.disjunctionFrameSize])
        let disjunctionContext = ParenthesesContext.backup &+ numNestedSubpatterns
        guard let context = takeContextWords(disjunctionContext &+ Context.frame &+ frameSize &+ ParenthesesContext.padding) else {
            return nil
        }
        var words = heapWords.mutableSpan
        let base = context &- 40
        words[base &+ ParenthesesContext.next] = 0
        words[base &+ ParenthesesContext.numNestedSubpatterns] = UInt(numNestedSubpatterns)
        var backup = words.extracting((base &+ ParenthesesContext.backup)..<(base &+ ParenthesesContext.backup &+ numNestedSubpatterns))
        var entries = output.extracting(first..<(first + 2 * numNestedSubpatterns))
        for i in 0..<numNestedSubpatterns {
            backup[i] = UInt(entries[2 &* i]) | UInt(entries[2 &* i &+ 1]) &<< 32
            entries[2 &* i] = yarrOffsetNoMatch
            entries[2 &* i &+ 1] = yarrOffsetNoMatch
        }
        words[base &+ disjunctionContext &+ Context.term] = 0
        return (context, context &+ disjunctionContext)
    }

    // The duplicate named group of a ParenthesesSubpattern's subpattern `index`, when no earlier subpattern of it has
    // that group: the groups whose entries its parentheses context saves after the subpatterns', in this order.
    func firstDuplicateNamedGroup(_ firstSubpatternId: UInt32, _ index: UInt32) -> UInt32? {
        let groups = duplicateNamedGroupForSubpatternId + 1 + Int(firstSubpatternId)
        let group = code[groups + Int(index)]
        if group == 0 {
            return nil
        }
        for earlier in 0..<Int(index) where code[groups + earlier] == group {
            return nil
        }
        return group
    }

    @inline(never)
    mutating func allocParenthesesDisjunctionContextWithDuplicateNamedGroups(_ disjunction: Int, _ firstSubpatternId: UInt32) -> Int? {
        let numNestedSubpatterns = code[disjunction + ByteCode.disjunctionNumSubpatterns]
        var numDuplicateNamedGroups = 0
        for i in 0..<numNestedSubpatterns where firstDuplicateNamedGroup(firstSubpatternId, i) != nil {
            numDuplicateNamedGroups += 1
        }
        let frameSize = Int(code[disjunction + ByteCode.disjunctionFrameSize])
        let disjunctionContext = ParenthesesContext.backup + Int(numNestedSubpatterns) + (numDuplicateNamedGroups + 1) / 2
        guard let context = takeContextWords(disjunctionContext + Context.frame + frameSize + ParenthesesContext.padding) else {
            return nil
        }
        setHeapWord(context + ParenthesesContext.next, 0)
        setHeapWord(context + ParenthesesContext.numNestedSubpatterns, UInt(numNestedSubpatterns))
        setHeapWord(context + ParenthesesContext.numDuplicateNamedGroups, UInt(numDuplicateNamedGroups))
        let first = Int(firstSubpatternId << 1)
        let backup = context + ParenthesesContext.backup
        for i in 0..<Int(numNestedSubpatterns) {
            setHeapWord(backup + i, UInt(output[first + 2 * i]) | UInt(output[first + 2 * i + 1]) << 32)
            output[first + 2 * i] = yarrOffsetNoMatch
            output[first + 2 * i + 1] = yarrOffsetNoMatch
        }
        let saved = backup + Int(numNestedSubpatterns)
        var k = 0
        for i in 0..<numNestedSubpatterns {
            guard let group = firstDuplicateNamedGroup(firstSubpatternId, i) else {
                continue
            }
            let entry = UInt(output[offsetForDuplicateNamedGroupId(group)])
            setHeapWord(saved + k / 2, k & 1 == 0 ? entry : heapWord(saved + k / 2) | entry << 32)
            output[offsetForDuplicateNamedGroupId(group)] = 0
            k += 1
        }
        setHeapWord(context + disjunctionContext + Context.term, 0)
        return context
    }

    mutating func restoreOutput(_ context: Int, _ firstSubpatternId: UInt32) {
        // In a scope of its own: the spans end before restoreDuplicateNamedGroups takes `self`.
        do {
            let first = Int(firstSubpatternId << 1)
            let base = context &- 40
            let words = heapWords.span
            let count = Int(words[base &+ ParenthesesContext.numNestedSubpatterns])
            let backup = words.extracting((base &+ ParenthesesContext.backup)..<(base &+ ParenthesesContext.backup &+ count))
            var entries = output.extracting(first..<(first &+ 2 &* count))
            for i in 0..<count {
                let saved = backup[i]
                entries[2 &* i] = UInt32(truncatingIfNeeded: saved)
                entries[2 &* i &+ 1] = UInt32(truncatingIfNeeded: saved &>> 32)
            }
        }
        if hasDuplicateNamedCaptureGroups {
            restoreDuplicateNamedGroups(context, firstSubpatternId)
        }
    }

    @inline(never)
    mutating func restoreDuplicateNamedGroups(_ context: Int, _ firstSubpatternId: UInt32) {
        let numNestedSubpatterns = UInt32(heapWord(context + ParenthesesContext.numNestedSubpatterns))
        let saved = context + ParenthesesContext.backup + Int(numNestedSubpatterns)
        var k = 0
        for i in 0..<numNestedSubpatterns {
            guard let group = firstDuplicateNamedGroup(firstSubpatternId, i) else {
                continue
            }
            output[offsetForDuplicateNamedGroupId(group)] = UInt32(truncatingIfNeeded: heapWord(saved + k / 2) >> (k & 1 == 0 ? 0 : 32))
            k += 1
        }
        precondition(k == Int(heapWord(context + ParenthesesContext.numDuplicateNamedGroups)))
    }

    // The contexts of a ParenthesesSubpattern's iterations, most recent first, at its frame's lastContext slot.
    @inline(__always)
    mutating func lastContext(_ context: Int, _ t: Term) -> Int {
        let value = frame(context, t, Slot.parenthesesLastContext)
        precondition(value != 0)
        return Int(value) - 1
    }

    @inline(__always)
    mutating func appendParenthesesDisjunctionContext(_ context: Int, _ t: Term, _ parenthesesContext: Int) {
        let slots = context &+ Context.frame &+ t.frameLocation
        setHeapWord(parenthesesContext &+ ParenthesesContext.next, word(slots &+ Slot.parenthesesLastContext))
        setWord(slots &+ Slot.parenthesesLastContext, UInt(parenthesesContext) &+ 1)
        setWord(slots &+ Slot.matchAmount, word(slots &+ Slot.matchAmount) &+ 1)
    }

    @inline(__always)
    mutating func popParenthesesDisjunctionContext(_ context: Int, _ t: Term) {
        let slots = context &+ Context.frame &+ t.frameLocation
        let matchAmount = word(slots &+ Slot.matchAmount)
        precondition(matchAmount != 0)
        let value = word(slots &+ Slot.parenthesesLastContext)
        precondition(value != 0)
        setWord(slots &+ Slot.parenthesesLastContext, heapWord(Int(value) &- 1 &+ ParenthesesContext.next))
        setWord(slots &+ Slot.matchAmount, matchAmount &- 1)
    }

    // MARK: Input

    @inline(always)
    func unit(_ index: UInt32) -> UInt32 { UInt32(truncatingIfNeeded: input[Int(index)]) }

    static func positionAt(_ direction: UInt8, _ position: UInt32, _ negativePositionOffset: UInt32) -> UInt32 {
        direction == yarrForward ? position &- negativePositionOffset : position &+ negativePositionOffset
    }

    @inline(always)
    func positionAt(_ direction: UInt8, _ negativePositionOffset: UInt32) -> UInt32 {
        if direction == yarrForward {
            precondition(pos >= negativePositionOffset)
        } else {
            precondition(negativePositionOffset <= length &- pos)
        }
        return Self.positionAt(direction, pos, negativePositionOffset)
    }

    // The index of the character a read at `negativePositionOffset` takes. positionAt()'s assertion is not repeated:
    // the offset is at most the input already checked, so the index is in bounds; a read out of bounds still traps.
    @inline(always)
    func characterIndex(_ direction: UInt8, _ negativePositionOffset: UInt32) -> UInt32 {
        let position = Self.positionAt(direction, pos, negativePositionOffset)
        if direction == yarrForward {
            return position
        }
        return position &- 1
    }

    @inline(always)
    func readCodePoint(_ direction: UInt8, _ index: UInt32) -> UInt32 {
        let result = unit(index)
        if !decodeSurrogatePairs {
            return result
        }
        let leadsPair = isLeadSurrogate(result) && index + 1 < length && isTrailSurrogate(unit(index + 1))
        let trailsPair = isTrailSurrogate(result) && index > 0 && isLeadSurrogate(unit(index - 1))
        if direction == yarrForward {
            if leadsPair {
                return supplementary(result, unit(index + 1))
            }
            if trailsPair {
                return errorCodePoint
            }
            return result
        }
        if trailsPair {
            return supplementary(unit(index - 1), result)
        }
        if leadsPair {
            return errorCodePoint
        }
        return result
    }

    @inline(__always)
    func readCheckedDontAdvance(_ direction: UInt8, _ negativePositionOffset: UInt32) -> UInt32 {
        readCodePoint(direction, characterIndex(direction, negativePositionOffset))
    }

    @inline(always)
    mutating func readChecked(_ direction: UInt8, _ negativePositionOffset: UInt32) -> UInt32 {
        let result = readCheckedDontAdvance(direction, negativePositionOffset)
        if result == errorCodePoint || isBMP(result) {
            return result
        }
        if !checkInput(direction, 1) {
            return errorCodePoint
        }
        return result
    }

    func readSurrogatePairChecked(_ direction: UInt8, _ negativePositionOffset: UInt32) -> UInt32 {
        let result = readCheckedDontAdvance(direction, negativePositionOffset)
        return isBMP(result) ? errorCodePoint : result
    }

    func reread(_ from: UInt32) -> UInt32 {
        readCodePoint(yarrForward, from)
    }

    var atEnd: Bool { pos == length }

    @inline(always)
    mutating func checkInput(_ direction: UInt8, _ count: UInt32) -> Bool {
        if direction == yarrForward {
            let newPos = pos &+ count
            if newPos <= length && newPos >= pos {
                pos = newPos
                return true
            }
            return false
        }
        if pos >= count {
            pos -= count
            return true
        }
        return false
    }

    @inline(always)
    mutating func uncheckInput(_ direction: UInt8, _ count: UInt32) {
        if direction == yarrForward {
            precondition(pos >= count)
            pos -= count
            return
        }
        precondition(count <= length &- pos)
        pos += count
    }

    @inline(__always)
    mutating func uncheckCodePoint(_ direction: UInt8, _ negativePositionOffset: UInt32) {
        uncheckInput(direction, 1)
        if !decodeSurrogatePairs {
            return
        }
        if !isBMP(readCodePoint(direction == yarrForward ? yarrBackward : yarrForward, characterIndex(direction, negativePositionOffset))) {
            uncheckInput(direction, 1)
        }
    }

    func isAvailableInput(_ offset: UInt32) -> Bool {
        let newPos = pos &+ offset
        return newPos <= length && newPos >= pos
    }

    // MARK: Character classes

    @inline(always)
    func testCharacterClass(_ characterClass: Int, _ ch: UInt32) -> Bool {
        if ch <= 0xFF {
            return (code[characterClass &+ ByteCode.classLatin1Bitmap &+ Int(ch >> 5)] >> (ch & 31)) & 1 != 0
        }
        return testCharacterClassBeyondLatin1(characterClass, ch)
    }

    @inline(never)
    func testCharacterClassBeyondLatin1(_ characterClass: Int, _ ch: UInt32) -> Bool {
        let header = code[characterClass + ByteCode.classHeader]
        if header & 1 != 0 {
            return true
        }

        let matches =
            characterClass + ByteCode.classData + Int(code[characterClass + ByteCode.classMatches8Count]) + 2
            * Int(code[characterClass + ByteCode.classRanges8Count])
        let matchesCount = Int(code[characterClass + ByteCode.classMatches32Count])
        let ranges = matches + matchesCount
        let rangesCount = Int(code[characterClass + ByteCode.classRanges32Count])

        // A class with a table answered every BMP character from it, and its table holds its matches and ranges.
        if header & 8 != 0 && ch <= 0xFFFF {
            return linearSearchMatches(matches, matchesCount, ch) || linearSearchRanges(ranges, rangesCount, ch)
        }

        let thresholdForBinarySearch = 6
        if matchesCount != 0 {
            if matchesCount > thresholdForBinarySearch {
                if binarySearchMatches(matches, matchesCount, ch) {
                    return true
                }
            } else if linearSearchMatches(matches, matchesCount, ch) {
                return true
            }
        }
        if rangesCount != 0 {
            if rangesCount > thresholdForBinarySearch {
                if binarySearchRanges(ranges, rangesCount, ch) {
                    return true
                }
            } else if linearSearchRanges(ranges, rangesCount, ch) {
                return true
            }
        }
        return false
    }

    func linearSearchMatches(_ matches: Int, _ count: Int, _ ch: UInt32) -> Bool {
        for i in 0..<count where ch == code[matches + i] {
            return true
        }
        return false
    }

    func binarySearchMatches(_ matches: Int, _ count: Int, _ ch: UInt32) -> Bool {
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let diff = Int32(bitPattern: ch &- code[matches + mid])
            if diff == 0 {
                return true
            }
            if diff < 0 {
                if mid == low {
                    return false
                }
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return false
    }

    func linearSearchRanges(_ ranges: Int, _ count: Int, _ ch: UInt32) -> Bool {
        for i in 0..<count where ch >= code[ranges + 2 * i] && ch <= code[ranges + 2 * i + 1] {
            return true
        }
        return false
    }

    func binarySearchRanges(_ ranges: Int, _ count: Int, _ ch: UInt32) -> Bool {
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let rangeBeginDiff = Int32(bitPattern: ch &- code[ranges + 2 * mid])
            if rangeBeginDiff >= 0 && ch <= code[ranges + 2 * mid + 1] {
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
        return false
    }

    func hasOnlyNonBMPCharacters(_ characterClass: Int) -> Bool {
        (code[characterClass + ByteCode.classHeader] >> 1) & 3 == 2
    }

    // MARK: Matching terms

    @inline(always)
    mutating func check(_ kind: Check, _ t: Term, _ direction: UInt8, _ negativeInputOffset: UInt32) -> Bool {
        switch kind {
        case .character:
            return t.patternCharacter == readChecked(direction, negativeInputOffset)
        case .surrogatePair:
            return t.patternCharacter == readSurrogatePairChecked(direction, negativeInputOffset)
        case .casedCharacter:
            let ch = readChecked(direction, negativeInputOffset)
            return t.a == ch || t.b == ch
        case .characterClass:
            let inputChar = readChecked(direction, negativeInputOffset)
            if inputChar == errorCodePoint {
                return false
            }
            let match = testCharacterClass(t.characterClass, inputChar)
            return t.invert ? !match : match
        case .characterClassDontAdvanceInputForNonBMP:
            let cls = t.characterClass
            let readCharacter =
                hasOnlyNonBMPCharacters(cls)
                ? readSurrogatePairChecked(direction, negativeInputOffset) : readChecked(direction, negativeInputOffset)
            if readCharacter == errorCodePoint {
                return false
            }
            return testCharacterClass(cls, readCharacter)
        }
    }

    // `stride` is how many characters' input positions each repetition moves the check.
    @inline(always)
    mutating func matchFixedCount(_ kind: Check, _ t: Term, _ direction: UInt8, stride: UInt32 = 1) -> Bool {
        let position = pos // May need to back out reading a surrogate pair.
        let inputPosition = t.inputPosition
        var matchAmount: UInt32 = 0
        while matchAmount < t.quantityMaxCount {
            if !check(kind, t, direction, inputPosition &- matchAmount &* stride) {
                pos = position
                return false
            }
            matchAmount += 1
        }
        return true
    }

    @inline(always)
    mutating func matchGreedy(_ kind: Check, _ t: Term, _ context: Int, _ direction: UInt8) {
        var position = pos // May need to back out reading a surrogate pair.
        var matchAmount: UInt32 = 0
        while matchAmount < t.quantityMaxCount && checkInput(direction, 1) {
            if !check(kind, t, direction, t.inputPosition &+ 1) {
                pos = position
                break
            }
            matchAmount += 1
            position = pos
        }
        setFrame(context, t, Slot.matchAmount, UInt(matchAmount))
    }

    @inline(always)
    mutating func backtrackNonGreedy(_ kind: Check, _ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        // The count, read once: below quantityMaxCount, a UInt32, so adding one cannot overflow.
        let matchAmount = frame(context, t, Slot.matchAmount)
        if matchAmount < UInt(t.quantityMaxCount) && checkInput(direction, 1) {
            setFrame(context, t, Slot.matchAmount, matchAmount &+ 1)
            if check(kind, t, direction, t.inputPosition &+ 1) {
                return true
            }
        }
        pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))
        return false
    }

    mutating func tryConsumeBackReference(_ matchBegin: UInt32, _ matchEnd: UInt32, _ t: Term, _ direction: UInt8) -> Bool {
        let matchSize = matchEnd &- matchBegin
        if !checkInput(direction, matchSize) {
            return false
        }

        var i: UInt32 = 0
        while i < matchSize {
            defer { i &+= 1 }
            let negativeInputOffset = t.inputPosition &+ matchSize &- i
            let oldCh = readCodePoint(direction, direction == yarrForward ? matchBegin &+ i : matchEnd &- 1 &- i)
            let ch: UInt32
            if !isBMP(oldCh) {
                ch = readSurrogatePairChecked(direction, negativeInputOffset)
                i &+= 1
            } else {
                ch = readCheckedDontAdvance(direction, negativeInputOffset)
            }

            if oldCh != errorCodePoint && ch != errorCodePoint {
                if oldCh == ch {
                    continue
                }
                if t.ignoreCase {
                    // See ES 6.0, 21.2.2.8.2 for the definition of Canonicalize(). For non-Unicode
                    // patterns, Unicode values are never allowed to match against ASCII ones.
                    // For Unicode, we need to check all canonical equivalents of a character.
                    if isLegacyCompilation && (isASCII(oldCh) || isASCII(ch)) {
                        if toASCIIUpper(oldCh) == toASCIIUpper(ch) {
                            continue
                        }
                    } else if JSC.Yarr.yarrAreCanonicallyEquivalent(oldCh, ch, isEitherUnicodeCompilation) {
                        continue
                    }
                }
            }

            uncheckInput(direction, matchSize)
            return false
        }
        return true
    }

    @inline(__always)
    func matchAssertionBOL(_ t: Term) -> Bool {
        let position = positionAt(t.matchDirection, t.inputPosition)
        return position == 0 || (t.multiline && testCharacterClass(newlineClass, readCodePoint(yarrBackward, position - 1)))
    }

    @inline(__always)
    func matchAssertionEOL(_ t: Term) -> Bool {
        let position = positionAt(t.matchDirection, t.inputPosition)
        return position == length || (t.multiline && testCharacterClass(newlineClass, readCodePoint(yarrForward, position)))
    }

    @inline(__always)
    func matchAssertionBOI(_ t: Term) -> Bool {
        positionAt(t.matchDirection, t.inputPosition) == 0
    }

    @inline(__always)
    func matchAssertionEOI(_ t: Term) -> Bool {
        let assertionPos = positionAt(t.matchDirection, t.inputPosition)
        let inputLength = length

        // \z: succeed at EOI
        if !t.withOptionalLineTerminator {
            return assertionPos == inputLength
        }

        // \Z: succeed at EOI, or at a line terminator immediately before EOI.
        if assertionPos == inputLength {
            return true
        }

        let ch = readCodePoint(yarrForward, assertionPos)
        if !testCharacterClass(newlineClass, ch) {
            return false
        }
        if ch != UInt32(UInt8(ascii: "\r")) {
            return assertionPos &+ 1 == inputLength
        }
        if assertionPos &+ 1 == inputLength {
            return true // \r alone at EOI
        }
        if assertionPos &+ 2 != inputLength {
            return false
        }
        // Check for \r\n: read the char at assertionPos + 1.
        return reread(assertionPos + 1) == UInt32(UInt8(ascii: "\n"))
    }

    @inline(__always)
    func matchAssertionWordBoundary(_ t: Term) -> Bool {
        let position = positionAt(t.matchDirection, t.inputPosition)
        let boundaryCharacterClass = t.ignoreCase ? ignoreCaseWordcharClass : wordcharClass

        let prevIsWordchar = position != 0 && testCharacterClass(boundaryCharacterClass, readCodePoint(yarrBackward, position - 1))
        let readIsWordchar = position != length && testCharacterClass(boundaryCharacterClass, readCodePoint(yarrForward, position))

        let wordBoundary = prevIsWordchar != readIsWordchar
        return t.invert ? !wordBoundary : wordBoundary
    }

    @inline(always)
    mutating func backtrackPatternCharacter(_ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        switch t.quantityType {
        case .fixedCount:
            break
        case .greedy:
            if frame(context, t, Slot.matchAmount) != 0 {
                setFrame(context, t, Slot.matchAmount, frame(context, t, Slot.matchAmount) - 1)
                uncheckInput(direction, isBMP(t.patternCharacter) ? 1 : 2)
                return true
            }
        case .nonGreedy:
            return backtrackNonGreedy(.character, t, context, direction)
        }
        return false
    }

    @inline(always)
    mutating func backtrackPatternCasedCharacter(_ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        switch t.quantityType {
        case .fixedCount:
            break
        case .greedy:
            if frame(context, t, Slot.matchAmount) != 0 {
                setFrame(context, t, Slot.matchAmount, frame(context, t, Slot.matchAmount) - 1)
                uncheckInput(direction, 1)
                return true
            }
        case .nonGreedy:
            return backtrackNonGreedy(.casedCharacter, t, context, direction)
        }
        return false
    }

    @inline(always)
    mutating func matchCharacterClass(_ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        switch t.quantityType {
        case .fixedCount:
            if !isEitherUnicodeCompilation {
                var matchAmount: UInt32 = 0
                while matchAmount < t.quantityMaxCount {
                    if !check(.characterClass, t, direction, t.inputPosition &- matchAmount) {
                        return false
                    }
                    matchAmount += 1
                }
                return true
            }
            setFrame(context, t, Slot.begin, UInt(pos))
            if t.invert {
                return matchFixedCount(.characterClass, t, direction)
            }
            let matchWidth: UInt32 = hasOnlyNonBMPCharacters(t.characterClass) ? 2 : 1
            return matchFixedCount(.characterClassDontAdvanceInputForNonBMP, t, direction, stride: matchWidth)
        case .greedy:
            matchGreedy(.characterClass, t, context, direction)
            return true
        case .nonGreedy:
            setFrame(context, t, Slot.begin, UInt(pos))
            setFrame(context, t, Slot.matchAmount, 0)
            return true
        }
    }

    @inline(always)
    mutating func backtrackCharacterClass(_ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        switch t.quantityType {
        case .fixedCount:
            if isEitherUnicodeCompilation {
                pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))
            }
        case .greedy:
            if frame(context, t, Slot.matchAmount) != 0 {
                setFrame(context, t, Slot.matchAmount, frame(context, t, Slot.matchAmount) - 1)
                uncheckCodePoint(direction, t.inputPosition)
                return true
            }
        case .nonGreedy:
            return backtrackNonGreedy(.characterClass, t, context, direction)
        }
        return false
    }

    // The subpattern a back reference refers to, or nil when it names a duplicate named group none of whose
    // subpatterns has matched.
    func backReferenceSubpatternId(_ t: Term) -> UInt32? {
        let duplicateNamedGroupId = t.duplicateNamedGroupId
        if duplicateNamedGroupId != 0 {
            let subpatternId = output[offsetForDuplicateNamedGroupId(duplicateNamedGroupId)]
            return subpatternId < 1 ? nil : subpatternId
        }
        return t.subpatternId
    }

    mutating func matchBackReference(_ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        // Initialize backtracking info first before we check for possible null matches.
        switch t.quantityType {
        case .nonGreedy:
            setFrame(context, t, Slot.matchAmount, 0)
            setFrame(context, t, Slot.begin, UInt(pos))
        case .fixedCount:
            setFrame(context, t, Slot.begin, UInt(pos))
        case .greedy:
            setFrame(context, t, Slot.matchAmount, 0)
        }

        guard let subpatternId = backReferenceSubpatternId(t) else {
            // If we don't have a subpattern that matched, then the string to match is empty.
            return true
        }

        let matchBegin = output[Int(subpatternId << 1)]
        let matchEnd = output[Int((subpatternId << 1) &+ 1)]

        // If the end position of the referenced match hasn't set yet then the backreference in the same parentheses where it references to that.
        // In this case the result of match is empty string like when it references to a parentheses with zero-width match.
        // Eg.: /(a\1)/
        if matchEnd == yarrOffsetNoMatch {
            return true
        }
        if matchBegin == yarrOffsetNoMatch {
            return true
        }
        if matchBegin == matchEnd {
            return true
        }

        switch t.quantityType {
        case .fixedCount:
            var matchAmount: UInt32 = 0
            while matchAmount < t.quantityMaxCount {
                if !tryConsumeBackReference(matchBegin, matchEnd, t, direction) {
                    pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))
                    return false
                }
                matchAmount += 1
            }
            return true
        case .greedy:
            var matchAmount: UInt32 = 0
            while matchAmount < t.quantityMaxCount && tryConsumeBackReference(matchBegin, matchEnd, t, direction) {
                matchAmount += 1
            }
            setFrame(context, t, Slot.matchAmount, UInt(matchAmount))
            return true
        case .nonGreedy:
            return true
        }
    }

    mutating func backtrackBackReference(_ t: Term, _ context: Int, _ direction: UInt8) -> Bool {
        guard let subpatternId = backReferenceSubpatternId(t) else {
            // If we don't have a subpattern that matched, then the string to match is empty.
            return false
        }

        let matchBegin = output[Int(subpatternId << 1)]
        let matchEnd = output[Int((subpatternId << 1) &+ 1)]
        if matchBegin == yarrOffsetNoMatch || matchEnd == yarrOffsetNoMatch {
            return false
        }
        if matchBegin == matchEnd {
            return false
        }

        switch t.quantityType {
        case .fixedCount:
            // for quantityMaxCount == 1, could rewind.
            pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))
        case .greedy:
            if frame(context, t, Slot.matchAmount) != 0 {
                setFrame(context, t, Slot.matchAmount, frame(context, t, Slot.matchAmount) - 1)
                uncheckInput(direction, matchEnd &- matchBegin)
                return true
            }
        case .nonGreedy:
            if frame(context, t, Slot.matchAmount) < UInt(t.quantityMaxCount) && tryConsumeBackReference(matchBegin, matchEnd, t, direction)
            {
                setFrame(context, t, Slot.matchAmount, frame(context, t, Slot.matchAmount) + 1)
                return true
            }
            pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))
        }
        return false
    }

    @inline(always)
    mutating func matchPatternCharacterFixed(_ t: Term, _ direction: UInt8) -> Bool {
        // One BMP character, or any character outside Unicode mode: one read and a compare. The read moves past a
        // surrogate pair it finds there, so a failed compare puts the position back.
        if t.quantityMaxCount == 1 && (!isEitherUnicodeCompilation || isBMP(t.patternCharacter)) {
            let position = pos
            if t.patternCharacter == readChecked(direction, t.inputPosition) {
                return true
            }
            pos = position
            return false
        }
        if isEitherUnicodeCompilation && !isBMP(t.patternCharacter) {
            return matchFixedCount(.surrogatePair, t, direction, stride: 2)
        }
        return matchFixedCount(.character, t, direction)
    }

    @inline(__always)
    mutating func recordParenthesesMatch(_ t: Term, _ parenthesesContext: Int) {
        if t.capture {
            let subpatternId = t.subpatternId
            let direction = t.matchDirection
            let disjunctionContext = parenthesesDisjunctionContext(parenthesesContext)
            // For Backward matches, the captured indexes are recorded end then start. Callers index the subject with
            // them unchecked, so each is checked to be a position in the input.
            let begin = Self.positionAt(direction, UInt32(truncatingIfNeeded: heapWord(disjunctionContext &+ Context.matchBegin)), t.inputPosition)
            let end = Self.positionAt(direction, UInt32(truncatingIfNeeded: heapWord(disjunctionContext &+ Context.matchEnd)), t.inputPosition)
            precondition(begin <= length && end <= length)
            output[Int((subpatternId << 1) &+ UInt32(direction))] = begin
            output[Int((subpatternId << 1) &+ 1 &- UInt32(direction))] = end
            let duplicateNamedGroupId = t.duplicateNamedGroupId
            if duplicateNamedGroupId != 0 {
                // Record which of the duplicate named subpatterns matched.
                output[offsetForDuplicateNamedGroupId(duplicateNamedGroupId)] = subpatternId
            }
        }
    }

    mutating func resetMatches(_ t: Term, _ parenthesesContext: Int) {
        restoreOutput(parenthesesContext, t.subpatternId)
    }

    mutating func parenthesesDoBacktrack(_ t: Term, _ context: Int) -> MatchResult {
        while frame(context, t, Slot.matchAmount) != 0 {
            let parenthesesContext = lastContext(context, t)
            let result = matchDisjunction(t.parenthesesDisjunction, parenthesesDisjunctionContext(parenthesesContext), true)
            if result == .match {
                return .match
            }
            resetMatches(t, parenthesesContext)
            popParenthesesDisjunctionContext(context, t)
            freeContext(parenthesesContext)
            if result != .noMatch {
                return result
            }
        }
        return .noMatch
    }

    @inline(__always)
    mutating func matchParenthesesOnceBegin(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        switch t.quantityType {
        case .greedy:
            // set this speculatively; if we get to the parens end this will be true.
            setFrame(context, t, Slot.begin, UInt(pos))
        case .nonGreedy:
            setFrame(context, t, Slot.begin, notFound)
            termIndex &+= t.parenthesesWidth
            return true
        case .fixedCount:
            break
        }

        if t.capture {
            let subpatternId = t.subpatternId
            // For Backward matches, the captured indexes are recorded end then start.
            output[Int((subpatternId << 1) &+ UInt32(t.matchDirection))] = positionAt(t.matchDirection, t.inputPosition)
        }
        return true
    }

    @inline(__always)
    mutating func matchParenthesesOnceEnd(_ t: Term, _ context: Int) -> Bool {
        if t.capture {
            let subpatternId = t.subpatternId
            // For Backward matches, the captured indexes are recorded end then start.
            output[Int((subpatternId << 1) &+ 1 &- UInt32(t.matchDirection))] = positionAt(t.matchDirection, t.inputPosition)
            let duplicateNamedGroupId = t.duplicateNamedGroupId
            if duplicateNamedGroupId != 0 {
                // Record which of the duplicate named subpatterns matched.
                output[offsetForDuplicateNamedGroupId(duplicateNamedGroupId)] = subpatternId
            }
        }
        if t.quantityType == .fixedCount {
            return true
        }
        return frame(context, t, Slot.begin) != UInt(pos)
    }

    @inline(__always)
    mutating func backtrackParenthesesOnceBegin(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        if t.capture {
            let subpatternId = t.subpatternId
            output[Int(subpatternId << 1)] = yarrOffsetNoMatch
            output[Int((subpatternId << 1) &+ 1)] = yarrOffsetNoMatch
            let duplicateNamedGroupId = t.duplicateNamedGroupId
            if duplicateNamedGroupId != 0 {
                // Clear matching subpatternId.
                output[offsetForDuplicateNamedGroupId(duplicateNamedGroupId)] = 0
            }
        }

        switch t.quantityType {
        case .greedy:
            // if we backtrack to this point, there is another chance - try matching nothing.
            setFrame(context, t, Slot.begin, notFound)
            termIndex &+= t.parenthesesWidth
            return true
        case .nonGreedy, .fixedCount:
            return false
        }
    }

    @inline(__always)
    mutating func backtrackParenthesesOnceEnd(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        let type = t.quantityType
        if type == .greedy && frame(context, t, Slot.begin) == notFound {
            termIndex &-= t.parenthesesWidth
            return false
        }
        if type != .fixedCount && frame(context, t, Slot.begin) == notFound {
            setFrame(context, t, Slot.begin, UInt(pos))
            if t.capture {
                // Technically this access to inputPosition should be accessing the begin term's
                // inputPosition, but for repeats other than fixed these values should be
                // the same anyway! (We don't pre-check for greedy or non-greedy matches.)
                let subpatternId = t.subpatternId
                // For Backward matches, the captured indexes are recorded end then start.
                output[Int((subpatternId << 1) &+ UInt32(t.matchDirection))] = positionAt(t.matchDirection, t.inputPosition)
            }
            termIndex &-= t.parenthesesWidth
            return true
        }
        return false
    }

    @inline(__always)
    mutating func matchParenthesesTerminalBegin(_ t: Term, _ context: Int) -> Bool {
        setFrame(context, t, Slot.begin, UInt(pos))
        setFrame(context, t, Slot.terminalEntryPosition, UInt(pos))
        return true
    }

    @inline(__always)
    mutating func matchParenthesesTerminalEnd(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        if frame(context, t, Slot.begin) == UInt(pos) {
            // An empty iteration cannot be repeated, so it is only ever acceptable as the single
            // iteration a minimum of one demands, and only before anything has been consumed.
            // Clearing entryPosition both records that the minimum is now met and rejects any
            // further empty iteration.
            if t.quantityMinCount == 0 || frame(context, t, Slot.terminalEntryPosition) != UInt(pos) {
                return false
            }
            setFrame(context, t, Slot.terminalEntryPosition, notFound)
        }

        setFrame(context, t, Slot.begin, UInt(pos))

        // Successful match! Okay, what's next? - loop around and try to match more!
        // Loop back to the body's first term rather than to ParenthesesSubpatternTerminalBegin,
        // whose stores initialize the whole group and must not run again per iteration.
        termIndex &-= t.parenthesesWidth
        return true
    }

    @inline(__always)
    mutating func backtrackParenthesesTerminalBegin(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        // If we backtrack to this point, we have failed to match this iteration of the parens.
        // Nothing follows a terminal group, so an already satisfied minimum makes that failure an
        // acceptable end of the match; an unsatisfied one fails the match.
        if t.quantityMinCount != 0 {
            if frame(context, t, Slot.terminalEntryPosition) == UInt(pos) {
                return false
            }
        }
        termIndex &+= t.parenthesesWidth
        return true
    }

    @inline(always)
    mutating func matchParentheticalAssertionBegin(_ t: Term, _ context: Int) -> Bool {
        setFrame(context, t, Slot.begin, UInt(pos))
        pos = positionAt(t.parentMatchDirection, t.inputPosition)
        return true
    }

    @inline(__always)
    mutating func clearAssertionCaptures(_ t: Term) {
        // containsAnyCaptures().
        if t.lastSubpatternId >= t.subpatternId {
            var subpattern = t.subpatternId
            while subpattern <= t.lastSubpatternId {
                output[Int(subpattern << 1)] = yarrOffsetNoMatch
                output[Int((subpattern << 1) &+ 1)] = yarrOffsetNoMatch
                subpattern += 1
            }
        }
    }

    @inline(always)
    mutating func matchParentheticalAssertionEnd(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))

        // We've reached the end of the parens; if they are inverted, this is failure.
        if t.invert {
            clearAssertionCaptures(t)
            termIndex &-= t.parenthesesWidth
            return false
        }
        return true
    }

    @inline(always)
    mutating func backtrackParentheticalAssertionBegin(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))

        // We've failed to match parens; if they are inverted, this is win!
        if t.invert {
            termIndex &+= t.parenthesesWidth
            return true
        }
        return false
    }

    @inline(always)
    mutating func backtrackParentheticalAssertionEnd(_ t: Term, _ context: Int, _ termIndex: inout Int) -> Bool {
        pos = UInt32(truncatingIfNeeded: frame(context, t, Slot.begin))
        clearAssertionCaptures(t)
        termIndex &-= t.parenthesesWidth
        return false
    }

    mutating func matchParentheses(_ t: Term, _ context: Int) -> MatchResult {
        let disjunctionBody = t.parenthesesDisjunction
        setFrame(context, t, Slot.begin, UInt(pos))
        setFrame(context, t, Slot.matchAmount, 0)
        setFrame(context, t, Slot.parenthesesLastContext, 0)

        let minimumMatchCount = t.quantityMinCount

        // Handle fixed matches and the minimum part of a variable length match.
        if minimumMatchCount != 0 {
            // Match the mandatory iterations, backtracking earlier ones as needed.
            let result = refillParenthesesContextsToMinCount(t, context, disjunctionBody)
            if result != .match {
                return result
            }
            recordParenthesesMatch(t, lastContext(context, t))
        }

        switch t.quantityType {
        case .fixedCount:
            return .match
        case .greedy:
            let result = extendParenthesesContextsToMaxCount(t, context, disjunctionBody)
            if result != .match {
                return result
            }
            if frame(context, t, Slot.matchAmount) != 0 {
                recordParenthesesMatch(t, lastContext(context, t))
            }
            return .match
        case .nonGreedy:
            return .match
        }
    }

    // Rules for backtracking differ depending on whether this is greedy or non-greedy.
    //
    // Greedy matches never should try just adding more - you should already have done
    // the 'more' cases.  Always backtrack, at least a leetle bit.  However cases where
    // you backtrack an item off the list needs checking, since we'll never have matched
    // the one less case.  Tracking forwards, still add as much as possible.
    //
    // Non-greedy, we've already done the one less case, so don't match on popping.
    // We haven't done the one more case, so always try to add that.
    //
    mutating func backtrackParentheses(_ t: Term, _ context: Int) -> MatchResult {
        let disjunctionBody = t.parenthesesDisjunction

        switch t.quantityType {
        case .fixedCount:
            var result = parenthesesDoBacktrack(t, context)
            if result != .match {
                return result
            }
            // For FixedCount min == max, so refilling to min refills to max; the
            // helper handles the inner content-backtrack-on-failure loop too.
            result = refillParenthesesContextsToMinCount(t, context, disjunctionBody)
            if result != .match {
                return result
            }
            recordParenthesesMatch(t, lastContext(context, t))
            return .match

        case .greedy:
            // The frame's slots, read once: the iteration's match below writes only its own context, which is past
            // this one in the store.
            let slots = context &+ Context.frame &+ t.frameLocation
            let matchAmount = word(slots &+ Slot.matchAmount)
            if matchAmount == 0 {
                return .noMatch
            }
            let last = word(slots &+ Slot.parenthesesLastContext)
            precondition(last != 0)
            let parenthesesContext = Int(last) - 1

            // Per RepeatMatcher, only iterations beyond the mandatory minimum must be
            // non-empty; a mandatory iteration (count <= min) may match zero-length, so
            // retry its content allowing an empty match in that case.
            var result =
                matchAmount <= UInt(t.quantityMinCount)
                ? matchDisjunction(disjunctionBody, parenthesesDisjunctionContext(parenthesesContext), true)
                : matchNonZeroDisjunction(disjunctionBody, parenthesesDisjunctionContext(parenthesesContext), true)
            if result == .match {
                result = extendParenthesesContextsToMaxCount(t, context, disjunctionBody)
                if result != .match {
                    return result
                }
            } else {
                resetMatches(t, parenthesesContext)
                // popParenthesesDisjunctionContext, with the slots read above.
                setWord(slots &+ Slot.parenthesesLastContext, heapWord(parenthesesContext &+ ParenthesesContext.next))
                setWord(slots &+ Slot.matchAmount, matchAmount &- 1)
                freeContext(parenthesesContext)

                if result != .noMatch {
                    return result
                }

                // When matchAmount falls below the minimum, do not give up immediately:
                // try parenthesesDoBacktrack on the remaining contexts to find an
                // alternative match distribution that allows us to reach min, then
                // refill back up to min.
                //
                // For example, /((a+){2,3}){2,3}$/  matched against  "aaaaaa",
                // `a+` will drain all input and this makes {2,3}'s `2` count failed.
                // But instead of immediately saying "this is failed", we should backtrack `a+`,
                // reducing drained count of `a`, and then the parentheses succeeds.
                if frame(context, t, Slot.matchAmount) < UInt(t.quantityMinCount) {
                    result = parenthesesDoBacktrack(t, context)
                    if result != .match {
                        return result
                    }
                    // Now content-backtracking succeeded. Refill back up to min-count.
                    result = refillParenthesesContextsToMinCount(t, context, disjunctionBody)
                    if result != .match {
                        return result
                    }
                    // And now we should expand the matching up to max count, then we can say Greedy is fully backtracked.
                    result = extendParenthesesContextsToMaxCount(t, context, disjunctionBody)
                    if result != .match {
                        return result
                    }
                }
            }

            if frame(context, t, Slot.matchAmount) != 0 {
                recordParenthesesMatch(t, lastContext(context, t))
            }
            return .match

        case .nonGreedy:
            // If we've not reached the limit, try to add one more match.
            if frame(context, t, Slot.matchAmount) < UInt(t.quantityMaxCount) {
                guard let (parenthesesContext, disjunctionContext) = allocParenthesesDisjunctionContext(disjunctionBody, t) else {
                    return .errorNoMemory
                }
                let result = matchNonZeroDisjunction(disjunctionBody, disjunctionContext, false)
                if result == .match {
                    appendParenthesesDisjunctionContext(context, t, parenthesesContext)
                    recordParenthesesMatch(t, parenthesesContext)
                    return .match
                }

                resetMatches(t, parenthesesContext)
                freeContext(parenthesesContext)

                if result != .noMatch {
                    return result
                }
            }

            // Nope - okay backtrack looking for an alternative.
            while frame(context, t, Slot.matchAmount) != 0 {
                let parenthesesContext = lastContext(context, t)
                // Mandatory iterations (count <= min) may match zero-length; only extra
                // iterations must be non-empty (RepeatMatcher).
                var result =
                    frame(context, t, Slot.matchAmount) <= UInt(t.quantityMinCount)
                    ? matchDisjunction(disjunctionBody, parenthesesDisjunctionContext(parenthesesContext), true)
                    : matchNonZeroDisjunction(disjunctionBody, parenthesesDisjunctionContext(parenthesesContext), true)
                if result == .match {
                    // A successful content backtrack may have left us below the mandatory
                    // minimum (we popped iterations above while searching for an alternative).
                    // NonGreedy still requires at least min iterations, so refill back up to
                    // min before accepting — mirroring the Greedy case. Without this the
                    // interpreter would return a match with fewer than quantityMinCount
                    // iterations (e.g. /(?:xy|x){2,3}?yxw/ wrongly matching "xyxw").
                    result = refillParenthesesContextsToMinCount(t, context, disjunctionBody)
                    if result != .match {
                        return result
                    }

                    // successful backtrack! we're back in the game!
                    if frame(context, t, Slot.matchAmount) != 0 {
                        recordParenthesesMatch(t, lastContext(context, t))
                    }
                    return .match
                }

                // pop a match off the stack
                resetMatches(t, parenthesesContext)
                popParenthesesDisjunctionContext(context, t)
                freeContext(parenthesesContext)

                if result != .noMatch {
                    return result
                }
            }
            return .noMatch
        }
    }

    mutating func refillParenthesesContextsToMinCount(_ t: Term, _ context: Int, _ disjunctionBody: Int) -> MatchResult {
        while frame(context, t, Slot.matchAmount) < UInt(t.quantityMinCount) {
            guard let (parenthesesContext, disjunctionContext) = allocParenthesesDisjunctionContext(disjunctionBody, t) else {
                return .errorNoMemory
            }
            var result = matchDisjunction(disjunctionBody, disjunctionContext, false)
            if result == .match {
                appendParenthesesDisjunctionContext(context, t, parenthesesContext)
                continue
            }
            resetMatches(t, parenthesesContext)
            freeContext(parenthesesContext)
            if result != .noMatch {
                return result
            }
            result = parenthesesDoBacktrack(t, context)
            if result != .match {
                return result
            }
        }
        return .match
    }

    // Greedy extension appends as many additional iterations as possible up
    // to quantityMaxCount, each required to match at least one character.
    mutating func extendParenthesesContextsToMaxCount(_ t: Term, _ context: Int, _ disjunctionBody: Int) -> MatchResult {
        let slots = context &+ Context.frame &+ t.frameLocation
        let maxCount = UInt(t.quantityMaxCount)
        // The count, kept here: the iterations' matches write only their own contexts, past this one.
        var matchAmount = word(slots &+ Slot.matchAmount)
        while matchAmount < maxCount {
            guard let (parenthesesContext, disjunctionContext) = allocParenthesesDisjunctionContext(disjunctionBody, t) else {
                return .errorNoMemory
            }
            // matchNonZeroDisjunction, inlined.
            var result = matchDisjunction(disjunctionBody, disjunctionContext, false)
            while result == .match && heapWord(disjunctionContext &+ Context.matchBegin) == heapWord(disjunctionContext &+ Context.matchEnd) {
                result = matchDisjunction(disjunctionBody, disjunctionContext, true)
            }
            if result == .match {
                // appendParenthesesDisjunctionContext, with the count kept above.
                setHeapWord(parenthesesContext &+ ParenthesesContext.next, word(slots &+ Slot.parenthesesLastContext))
                setWord(slots &+ Slot.parenthesesLastContext, UInt(parenthesesContext) &+ 1)
                matchAmount &+= 1
                setWord(slots &+ Slot.matchAmount, matchAmount)
                continue
            }
            resetMatches(t, parenthesesContext)
            freeContext(parenthesesContext)
            if result != .noMatch {
                return result
            }
            break
        }
        return .match
    }

    mutating func matchDotStarEnclosure(_ t: Term, _ context: Int) -> Bool {
        let bolAnchor = t.a & 1 != 0
        let eolAnchor = t.a & 2 != 0
        if t.dotAll {
            // In dotAll mode, .* can match line terminators. A non-multiline ^ matches only if the
            // search begins at the start of the input (offset 0). A multiline ^ needs to check
            // every line and is never optimized to a DotStarEnclosure.
            if startOffset != 0 && bolAnchor && !t.multiline {
                return false
            }
            setMatchBegin(context, startOffset)
            setMatchEnd(context, length)
            return true
        }

        var matchBegin = matchBegin(context)
        if matchBegin > startOffset {
            matchBegin -= 1
            while true {
                if testCharacterClass(newlineClass, reread(matchBegin)) {
                    matchBegin += 1
                    break
                }
                if matchBegin == startOffset {
                    break
                }
                matchBegin -= 1
            }
        }

        var matchEnd = pos
        while matchEnd != length && !testCharacterClass(newlineClass, reread(matchEnd)) {
            matchEnd += 1
        }

        if ((matchBegin != 0 && bolAnchor) || (matchEnd != length && eolAnchor)) && !t.multiline {
            return false
        }

        setMatchBegin(context, matchBegin)
        setMatchEnd(context, matchEnd)
        return true
    }

    // MARK: The match loop

    mutating func matchDisjunction(_ disjunction: Int, _ context: Int, _ btrack: Bool) -> MatchResult {
        if !JSC.Yarr.yarrIsSafeToRecurse(stackLimit) {
            return .errorNoMemory
        }

        remainingMatchCount &-= 1
        if remainingMatchCount == 0 {
            return .errorHitLimit
        }

        // The context's term, which the context keeps between calls for backtracking into it.
        var termIndex: Int
        var backtracking = btrack
        if backtracking {
            termIndex = contextTerm(context) &- 1
        } else {
            setMatchBegin(context, pos)
            termIndex = 0
        }
        defer { setContextTerm(context, termIndex) }

        let code = self.code
        while true {
            let t = Self.term(code, disjunction, termIndex)
            var matched: Bool
            if !backtracking {
                switch t.type {
                case .subpatternBegin, .bodyAlternativeBegin, .alternativeBegin:
                    matched = true
                case .subpatternEnd, .bodyAlternativeDisjunction, .bodyAlternativeEnd:
                    setMatchEnd(context, pos)
                    return .match

                case .alternativeDisjunction, .alternativeEnd:
                    let offset = Int32(bitPattern: t.b)
                    setFrame(context, t, Slot.alternativeOffset, UInt(bitPattern: Int(offset)))
                    termIndex &+= Int(offset)
                    matched = true

                case .assertionBOL:
                    matched = matchAssertionBOL(t)
                case .assertionEOL:
                    matched = matchAssertionEOL(t)
                case .assertionBOI:
                    matched = matchAssertionBOI(t)
                case .assertionEOI:
                    matched = matchAssertionEOI(t)
                case .assertionWordBoundary:
                    matched = matchAssertionWordBoundary(t)

                case .patternCharacterOnce, .patternCharacterFixed:
                    matched = matchPatternCharacterFixed(t, yarrForward)
                case .patternCharacterOnceBackward, .patternCharacterFixedBackward:
                    matched = matchPatternCharacterFixed(t, yarrBackward)
                case .patternCharacterGreedy:
                    matchGreedy(.character, t, context, yarrForward)
                    matched = true
                case .patternCharacterGreedyBackward:
                    matchGreedy(.character, t, context, yarrBackward)
                    matched = true

                case .patternCasedCharacterNonGreedy, .patternCasedCharacterNonGreedyBackward,
                    .patternCharacterNonGreedy, .patternCharacterNonGreedyBackward:
                    setFrame(context, t, Slot.begin, UInt(pos))
                    setFrame(context, t, Slot.matchAmount, 0)
                    matched = true

                case .patternCasedCharacterOnce, .patternCasedCharacterFixed:
                    matched = matchFixedCount(.casedCharacter, t, yarrForward)
                case .patternCasedCharacterOnceBackward, .patternCasedCharacterFixedBackward:
                    matched = matchFixedCount(.casedCharacter, t, yarrBackward)
                case .patternCasedCharacterGreedy:
                    matchGreedy(.casedCharacter, t, context, yarrForward)
                    matched = true
                case .patternCasedCharacterGreedyBackward:
                    matchGreedy(.casedCharacter, t, context, yarrBackward)
                    matched = true

                case .characterClass:
                    matched = matchCharacterClass(t, context, yarrForward)
                case .characterClassBackward:
                    matched = matchCharacterClass(t, context, yarrBackward)
                case .backReference:
                    matched = matchBackReference(t, context, yarrForward)
                case .backReferenceBackward:
                    matched = matchBackReference(t, context, yarrBackward)

                case .parenthesesSubpattern:
                    let result = matchParentheses(t, context)
                    if result != .match && result != .noMatch {
                        return result
                    }
                    matched = result == .match
                case .parenthesesSubpatternOnceBegin:
                    matched = matchParenthesesOnceBegin(t, context, &termIndex)
                case .parenthesesSubpatternOnceEnd:
                    matched = matchParenthesesOnceEnd(t, context)
                case .parenthesesSubpatternTerminalBegin:
                    matched = matchParenthesesTerminalBegin(t, context)
                case .parenthesesSubpatternTerminalEnd:
                    matched = matchParenthesesTerminalEnd(t, context, &termIndex)
                case .parentheticalAssertionBegin:
                    matched = matchParentheticalAssertionBegin(t, context)
                case .parentheticalAssertionEnd:
                    matched = matchParentheticalAssertionEnd(t, context, &termIndex)

                case .checkInput:
                    matched = checkInput(t.matchDirection, t.a)

                case .dotStarEnclosure:
                    if matchDotStarEnclosure(t, context) {
                        return .match
                    }
                    matched = false
                }
            } else {
                switch t.type {
                case .subpatternBegin:
                    return .noMatch
                case .subpatternEnd, .bodyAlternativeEnd, .dotStarEnclosure:
                    fatalError()

                case .bodyAlternativeBegin, .bodyAlternativeDisjunction:
                    let offset = Int32(bitPattern: t.a)
                    termIndex &+= Int(offset)
                    if offset > 0 {
                        matched = true
                        break
                    }
                    if atEnd || sticky {
                        return .noMatch
                    }
                    pos += 1
                    if disjunction == bodyDisjunction && termIndex == 0 {
                        pos = nextCandidate(pos)
                    }
                    setMatchBegin(context, pos)
                    while term(disjunction, termIndex).c != 0 {
                        let next = Int32(bitPattern: term(disjunction, termIndex).a)
                        if next <= 0 {
                            return .noMatch
                        }
                        termIndex &+= Int(next)
                    }
                    matched = true

                case .alternativeBegin, .alternativeDisjunction:
                    let offset = Int32(bitPattern: t.a)
                    termIndex &+= Int(offset)
                    matched = offset > 0
                case .alternativeEnd:
                    // We should never backtrack back into an alternative of the main body of the regex.
                    let offset = UInt32(truncatingIfNeeded: frame(context, t, Slot.alternativeOffset))
                    termIndex = Int(Int32(truncatingIfNeeded: UInt32(truncatingIfNeeded: termIndex) &- offset))
                    matched = false

                case .assertionBOL, .assertionEOL, .assertionBOI, .assertionEOI, .assertionWordBoundary:
                    matched = false

                case .patternCharacterOnce, .patternCharacterFixed, .patternCharacterGreedy, .patternCharacterNonGreedy:
                    matched = backtrackPatternCharacter(t, context, yarrForward)
                case .patternCharacterOnceBackward, .patternCharacterFixedBackward, .patternCharacterGreedyBackward,
                    .patternCharacterNonGreedyBackward:
                    matched = backtrackPatternCharacter(t, context, yarrBackward)
                case .patternCasedCharacterOnce, .patternCasedCharacterFixed, .patternCasedCharacterGreedy, .patternCasedCharacterNonGreedy:
                    matched = backtrackPatternCasedCharacter(t, context, yarrForward)
                case .patternCasedCharacterOnceBackward, .patternCasedCharacterFixedBackward, .patternCasedCharacterGreedyBackward,
                    .patternCasedCharacterNonGreedyBackward:
                    matched = backtrackPatternCasedCharacter(t, context, yarrBackward)
                case .characterClass:
                    matched = backtrackCharacterClass(t, context, yarrForward)
                case .characterClassBackward:
                    matched = backtrackCharacterClass(t, context, yarrBackward)
                case .backReference:
                    matched = backtrackBackReference(t, context, yarrForward)
                case .backReferenceBackward:
                    matched = backtrackBackReference(t, context, yarrBackward)

                case .parenthesesSubpattern:
                    let result = backtrackParentheses(t, context)
                    if result != .match && result != .noMatch {
                        return result
                    }
                    matched = result == .match
                case .parenthesesSubpatternOnceBegin:
                    matched = backtrackParenthesesOnceBegin(t, context, &termIndex)
                case .parenthesesSubpatternOnceEnd:
                    matched = backtrackParenthesesOnceEnd(t, context, &termIndex)
                case .parenthesesSubpatternTerminalBegin:
                    matched = backtrackParenthesesTerminalBegin(t, context, &termIndex)
                case .parenthesesSubpatternTerminalEnd:
                    // 'Terminal' parentheses are at the end of the regex, and as such a match past end
                    // should always be returned as a successful match - we should never backtrack to here.
                    fatalError()
                case .parentheticalAssertionBegin:
                    matched = backtrackParentheticalAssertionBegin(t, context, &termIndex)
                case .parentheticalAssertionEnd:
                    matched = backtrackParentheticalAssertionEnd(t, context, &termIndex)

                case .checkInput:
                    uncheckInput(t.matchDirection, t.a)
                    matched = false
                }
            }

            if matched {
                termIndex &+= 1
                backtracking = false
            } else {
                termIndex &-= 1
                backtracking = true
            }
        }
    }

    mutating func matchNonZeroDisjunction(_ disjunction: Int, _ context: Int, _ btrack: Bool) -> MatchResult {
        var result = matchDisjunction(disjunction, context, btrack)
        if result == .match {
            // A parentheses context's disjunction context, in the heap words.
            while heapWord(context &+ Context.matchBegin) == heapWord(context &+ Context.matchEnd) {
                result = matchDisjunction(disjunction, context, true)
                if result != .match {
                    return result
                }
            }
            return .match
        }
        return result
    }

    mutating func interpret() -> UInt32 {
        if !isAvailableInput(0) {
            return yarrOffsetNoMatch
        }

        let endAnchoredFixedSize = code[ByteCode.endAnchoredFixedSize]
        if endAnchoredFixedSize != endAnchoredFixedSizeNotSet && length >= endAnchoredFixedSize {
            pos = max(pos, length - endAnchoredFixedSize)
        }

        let numSubpatterns = Int(code[ByteCode.numSubpatterns])
        var starts = output.extracting(0..<(2 &* numSubpatterns &+ 1))
        for i in stride(from: 0, to: starts.count, by: 2) {
            starts[i] = yarrOffsetNoMatch
        }
        var named = output.extracting(Int(offsetVectorBaseForNamedCaptures)..<Int(code[ByteCode.offsetsSize]))
        for i in named.indices {
            named[i] = 0
        }

        let body = Int(code[ByteCode.body])
        guard let context = allocBodyContext(body) else {
            return yarrOffsetNoMatch
        }

        let result = matchDisjunction(body, context, false)
        if result == .match {
            output[0] = matchBegin(context)
            output[1] = matchEnd(context)
        }
        // The body's context is not freed: neither the store nor the capacity is read again.
        returnSpareFrameStorage()
        return output[0]
    }
}

/// Matches a pattern's bytecode against 8-bit characters from `start`, writing the match and its captures to
/// `output`, and returns the match's start or `offsetNoMatch`.
///
/// `bytecode` is the BytecodePattern's, which owns it and never changes it after byteCompile(). `input` is a
/// StringView's characters, which the caller's string keeps alive and unchanged for the call; they are bytes, so any
/// value is valid. `output` is the caller's `m_offsetsSize` entries (RegExp's offset vector or a Vector on the
/// caller's stack), which nothing else reads or writes during the call and which overlaps neither of the others.
/// Swift runs no other thread and holds none of them after it returns.
// FIXME: Take Span and MutableSpan parameters once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func yarrInterpret8(
    _ bytecode: JSC.Yarr.YarrBytecodeWords,
    _ input: JSC.Yarr.YarrSubject8,
    _ start: UInt32,
    _ output: JSC.Yarr.YarrOutput,
    _ maxStackSize: UInt32,
    _ pageSize: Int
) -> UInt32 {
    let code = unsafe Span<UInt32>(_unsafeCxxSpan: bytecode)
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    let offsets = unsafe MutableSpan<UInt32>(_unsafeCxxSpan: output)
    var matcher = Matcher(code: code, input: characters, start: start, output: offsets, maxStackSize: Int(maxStackSize), pageSize: pageSize)
    return matcher.interpret()
}

/// Matches a pattern's bytecode against UTF-16 code units, under the same conditions as `yarrInterpret8`. Every
/// `char16_t` is a valid value.
// FIXME: Take Span and MutableSpan parameters once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func yarrInterpret16(
    _ bytecode: JSC.Yarr.YarrBytecodeWords,
    _ input: JSC.Yarr.YarrSubject16,
    _ start: UInt32,
    _ output: JSC.Yarr.YarrOutput,
    _ maxStackSize: UInt32,
    _ pageSize: Int
) -> UInt32 {
    let code = unsafe Span<UInt32>(_unsafeCxxSpan: bytecode)
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    let offsets = unsafe MutableSpan<UInt32>(_unsafeCxxSpan: output)
    var matcher = Matcher(code: code, input: characters, start: start, output: offsets, maxStackSize: Int(maxStackSize), pageSize: pageSize)
    return matcher.interpret()
}
