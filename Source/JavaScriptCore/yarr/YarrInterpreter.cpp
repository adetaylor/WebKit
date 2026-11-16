/*
 * Copyright (C) 2009-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2010 Peter Varga (pvarga@inf.u-szeged.hu), University of Szeged
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "YarrInterpreter.h"

#include "JSBigIntSwiftDigits.h"
#include "Options.h"
#include "YarrCanonicalize.h"
#include "YarrInterpreterSwiftTypes.h"
#include <wtf/DataLog.h>
#include <wtf/HashMap.h>
#include <wtf/StackBounds.h>
#include <wtf/StdLibExtras.h>
#include <wtf/StringPrintStream.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Threading.h>

#include "TemporalSwiftBoundary.h" // JSCSwift-Swift.h declares the whole module's Swift, Temporal's too.
#include "JSCSwift-Swift.h"

namespace JSC { namespace Yarr {

WTF_MAKE_TZONE_ALLOCATED_IMPL(BytecodePattern);

// The values YarrByteCompiler.swift and YarrInterpreterMatcher.swift use.
static_assert(static_cast<uint16_t>(Flags::HasIndices) == 1 << 0 && static_cast<uint16_t>(Flags::Global) == 1 << 1 && static_cast<uint16_t>(Flags::IgnoreCase) == 1 << 2 && static_cast<uint16_t>(Flags::Multiline) == 1 << 3);
static_assert(static_cast<uint16_t>(Flags::DotAll) == 1 << 4 && static_cast<uint16_t>(Flags::Unicode) == 1 << 5 && static_cast<uint16_t>(Flags::UnicodeSets) == 1 << 6 && static_cast<uint16_t>(Flags::Sticky) == 1 << 7);
static_assert(static_cast<unsigned>(ErrorCode::OffsetTooLarge) == 26 && static_cast<unsigned>(ErrorCode::TooManyDisjunctions) == 34);
static_assert(static_cast<unsigned>(PatternTerm::Type::AssertionBOL) == 0 && static_cast<unsigned>(PatternTerm::Type::DotStarEnclosure) == 13);
static_assert(static_cast<unsigned>(PatternTerm::Type::PatternCharacter) == 5 && static_cast<unsigned>(PatternTerm::Type::ParenthesesSubpattern) == 11);
static_assert(static_cast<unsigned>(QuantifierType::FixedCount) == 0 && static_cast<unsigned>(QuantifierType::Greedy) == 1 && static_cast<unsigned>(QuantifierType::NonGreedy) == 2);
static_assert(Forward == 0 && Backward == 1);
static_assert(static_cast<unsigned>(CharacterClassWidths::HasNonBMPChars) == 2);
static_assert(offsetNoMatch == std::numeric_limits<uint32_t>::max() && quantifyInfinite == std::numeric_limits<uint32_t>::max() && matchLimit == 100'000'000);
static_assert(YarrPattern::endAnchoredFixedSizeNotSet == std::numeric_limits<uint32_t>::max());
static_assert(YarrStackSpaceForBackTrackInfoParenthesesOnce == 2 && YarrStackSpaceForBackTrackInfoParenthesesTerminal == 2 && YarrStackSpaceForBackTrackInfoParentheticalAssertion == 1);

namespace {

// Writes a YarrPattern as the words YarrInterpreter.swift's PatternReader reads: a header, then each disjunction
// (the body first, then each one a term names, in the order they are first named), then each character class.
class PatternWriter {
public:
    PatternWriter(YarrPattern& pattern, bool dumping)
        : m_pattern(pattern)
        , m_dumping(dumping)
    {
    }

    Vector<uint32_t> write()
    {
        m_words.append(m_pattern.m_flags.toRaw());
        m_words.append(m_pattern.m_numSubpatterns);
        m_words.append(m_pattern.m_numDuplicateNamedCaptureGroups);
        m_words.append(m_pattern.m_endAnchoredFixedSize);
        m_words.append(classIndex(m_pattern.newlineCharacterClass()));
        m_words.append(classIndex(m_pattern.wordcharCharacterClass()));
        m_words.append(classIndex(m_pattern.wordUnicodeIgnoreCaseCharCharacterClass()));
        m_words.append(m_pattern.m_duplicateNamedGroupForSubpatternId.size());
        m_words.appendVector(m_pattern.m_duplicateNamedGroupForSubpatternId);

        disjunctionIndex(m_pattern.m_body);
        for (size_t i = 0; i < m_disjunctions.size(); ++i)
            writeDisjunction(*m_disjunctions[i]);

        m_words.append(m_classes.size());
        for (auto* characterClass : m_classes)
            writeClass(*characterClass);
        return WTF::move(m_words);
    }

private:
    unsigned disjunctionIndex(PatternDisjunction* disjunction)
    {
        return m_disjunctionIndices.ensure(disjunction, [&] {
            m_disjunctions.append(disjunction);
            return m_disjunctions.size() - 1;
        }).iterator->value;
    }

    unsigned classIndex(const CharacterClass* characterClass)
    {
        return m_classIndices.ensure(characterClass, [&] {
            m_classes.append(characterClass);
            return m_classes.size() - 1;
        }).iterator->value;
    }

    void writeDisjunction(PatternDisjunction& disjunction)
    {
        m_words.append(disjunction.m_minimumSize);
        m_words.append(disjunction.m_callFrameSize);
        m_words.append(disjunction.m_alternatives.size());
        for (auto& alternative : disjunction.m_alternatives) {
            m_words.append(alternative->m_minimumSize);
            m_words.append(alternative->onceThrough());
            m_words.append(alternative->m_terms.size());
            for (auto& term : alternative->m_terms)
                writeTerm(term);
        }
    }

    // YarrPattern gives a term a frame location only where it keeps backtracking state.
    bool hasFrameLocation(const PatternTerm& term) const
    {
        switch (term.type) {
        case PatternTerm::Type::PatternCharacter:
            return term.quantityType != QuantifierType::FixedCount;
        case PatternTerm::Type::CharacterClass:
            return term.quantityType != QuantifierType::FixedCount || m_pattern.eitherUnicode();
        case PatternTerm::Type::NumberedBackReference:
        case PatternTerm::Type::NamedBackReference:
        case PatternTerm::Type::ParenthesesSubpattern:
        case PatternTerm::Type::ParentheticalAssertion:
            return true;
        case PatternTerm::Type::AssertionBOL:
        case PatternTerm::Type::AssertionEOL:
        case PatternTerm::Type::AssertionBOI:
        case PatternTerm::Type::AssertionEOI:
        case PatternTerm::Type::AssertionWordBoundary:
        case PatternTerm::Type::NumberedForwardReference:
        case PatternTerm::Type::NamedForwardReference:
        case PatternTerm::Type::DotStarEnclosure:
            return false;
        }
        return false;
    }

    void writeTerm(PatternTerm& term)
    {
        m_words.append(static_cast<uint32_t>(term.type));
        m_words.append(term.m_currentFlags.toRaw());
        m_words.append(static_cast<uint32_t>(term.capture() | term.invert() << 1 | term.m_withOptionalLineTerminator << 2 | term.matchDirection() << 3));
        m_words.append(static_cast<uint32_t>(term.quantityType));
        m_words.append(term.quantityMinCount.value());
        m_words.append(term.quantityMaxCount.value());
        m_words.append(term.inputPosition);
        m_words.append(hasFrameLocation(term) ? term.frameLocation : 0);
        // The union's member that the term's type uses.
        switch (term.type) {
        case PatternTerm::Type::PatternCharacter:
            appendWords({ term.patternCharacter, 0, 0, 0 });
            break;
        case PatternTerm::Type::CharacterClass:
            appendWords({ classIndex(term.characterClass), 0, 0, 0 });
            break;
        case PatternTerm::Type::NumberedBackReference:
        case PatternTerm::Type::NamedBackReference:
            appendWords({ term.backReferenceSubpatternId, 0, 0, 0 });
            break;
        case PatternTerm::Type::ParenthesesSubpattern:
        case PatternTerm::Type::ParentheticalAssertion:
            appendWords({ disjunctionIndex(term.parentheses.disjunction), term.parentheses.subpatternId, term.parentheses.lastSubpatternId, static_cast<uint32_t>(term.parentheses.isCopy | term.parentheses.isTerminal << 1) });
            break;
        case PatternTerm::Type::DotStarEnclosure:
            appendWords({ static_cast<uint32_t>(term.anchors.bolAnchor | term.anchors.eolAnchor << 1), 0, 0, 0 });
            break;
        case PatternTerm::Type::AssertionBOL:
        case PatternTerm::Type::AssertionEOL:
        case PatternTerm::Type::AssertionBOI:
        case PatternTerm::Type::AssertionEOI:
        case PatternTerm::Type::AssertionWordBoundary:
        case PatternTerm::Type::NumberedForwardReference:
        case PatternTerm::Type::NamedForwardReference:
            appendWords({ 0, 0, 0, 0 });
            break;
        }
    }

    void appendWords(std::initializer_list<uint32_t> words)
    {
        for (auto word : words)
            m_words.append(word);
    }

    void writeClass(const CharacterClass& characterClass)
    {
        m_words.append(characterClass.m_anyCharacter | static_cast<uint32_t>(characterClass.m_characterWidths) << 1 | !!characterClass.m_table << 3 | !!characterClass.m_latin1Table << 4);
        appendWords({ static_cast<uint32_t>(characterClass.m_matches8.size()), static_cast<uint32_t>(characterClass.m_ranges8.size()), static_cast<uint32_t>(characterClass.m_matches32.size()), static_cast<uint32_t>(characterClass.m_ranges32.size()) });
        m_words.appendVector(characterClass.m_matches8);
        for (auto& range : characterClass.m_ranges8)
            appendWords({ range.begin, range.end });
        m_words.appendVector(characterClass.m_matches32);
        for (auto& range : characterClass.m_ranges32)
            appendWords({ range.begin, range.end });
        if (!m_dumping) {
            m_words.append(0);
            return;
        }
        StringPrintStream text;
        dumpCharacterClass(text, &m_pattern, &characterClass);
        auto bytes = text.toUTF8CString();
        m_words.append(bytes.length());
        for (size_t i = 0; i < bytes.length(); i += 4) {
            uint32_t word = 0;
            for (size_t j = 0; j < 4 && i + j < bytes.length(); ++j)
                word |= static_cast<uint32_t>(static_cast<uint8_t>(bytes.span()[i + j])) << (8 * j);
            m_words.append(word);
        }
    }

    YarrPattern& m_pattern;
    bool m_dumping;
    Vector<uint32_t> m_words;
    Vector<PatternDisjunction*> m_disjunctions;
    HashMap<PatternDisjunction*, unsigned> m_disjunctionIndices;
    Vector<const CharacterClass*> m_classes;
    HashMap<const CharacterClass*, unsigned> m_classIndices;
};

} // namespace

std::unique_ptr<BytecodePattern> byteCompile(YarrPattern& pattern, ErrorCode& errorCode)
{
    bool dumping = Options::dumpCompiledRegExpPatterns();
    auto patternWords = PatternWriter(pattern, dumping).write();
    auto compiled = JSCSwift::yarrByteCompile(patternWords.span(), dumping);
    std::span<const uint32_t> words(compiled.data(), compiled.size());

    auto error = static_cast<ErrorCode>(words[0]);
    size_t dumpLength = words[1];
    auto dumpWords = words.subspan(2, (dumpLength + 3) / 4);
    if (dumpLength) {
        auto dumpText = byteCast<char>(asBytes(dumpWords).first(dumpLength));
        RELEASE_ASSERT(dumpText.size() <= static_cast<size_t>(std::numeric_limits<int>::max()));
        WTF::dataFile().printf("%.*s", static_cast<int>(dumpText.size()), dumpText.data());
    }
    if (hasError(error)) {
        errorCode = error;
        return nullptr;
    }
    auto bytecode = words.subspan(2 + dumpWords.size());
    return makeUnique<BytecodePattern>(Vector<uint32_t>(bytecode), pattern.offsetsSize());
}

void releaseSpareStorage()
{
    JSCSwift::yarrReleaseSpareStorage();
}

unsigned interpret(BytecodePattern* bytecode, StringView input, unsigned start, unsigned* output)
{
    // The callers size the output vector with m_offsetsSize entries.
    auto outputSpan = unsafeMakeSpan(output, bytecode->m_offsetsSize);
    if (input.is8Bit())
        return JSCSwift::yarrInterpret8(bytecode->m_bytecode.span(), bytesOfLatin1Characters(input.span8()), start, outputSpan, Options::maxRegExpStackSize(), WTF::pageSize());
    return JSCSwift::yarrInterpret16(bytecode->m_bytecode.span(), input.span16(), start, outputSpan, Options::maxRegExpStackSize(), WTF::pageSize());
}

void* yarrFastMalloc(size_t size)
{
    return fastMalloc(size);
}

void yarrFastFree(void* pointer)
{
    fastFree(pointer);
}

uintptr_t yarrStackLimit()
{
    return std::bit_cast<uintptr_t>(Thread::currentSingleton().stack().recursionLimit(StackBounds::DefaultReservedZone));
}

bool yarrAreCanonicallyEquivalent(uint32_t a, uint32_t b, bool unicode)
{
    return areCanonicallyEquivalent(a, b, unicode ? CanonicalMode::Unicode : CanonicalMode::UCS2);
}

} } // namespace JSC::Yarr
