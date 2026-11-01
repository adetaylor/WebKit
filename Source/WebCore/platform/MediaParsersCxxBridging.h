/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <algorithm>
#include <cstdint>
#include <optional>
#include <span>
#include <wtf/StdLibExtras.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

// Swift traps when it passes C++ an empty Span with a null base, which is what empty StringViews,
// Vectors and SharedBuffers give. The views lend empty spans of these instead.
inline constexpr uint8_t mediaParserEmptyBytes[1] { };
inline constexpr char16_t mediaParserEmptyUTF16[1] { };
inline uint8_t mediaParserEmptyMutableBytes[1] { };

// Borrowed for one call from C++ into Swift; Swift reads span() as a lifetime-checked Span. The accessors and helpers
// are ALWAYS_INLINE because Swift's optimizer leaves imported C++ functions out of line otherwise (Release builds).
struct SWIFT_VIEW MediaParserBytes {
    std::span<const uint8_t> bytes;
    ALWAYS_INLINE std::span<const uint8_t> span() const LIFETIME_BOUND { return bytes.empty() ? std::span { mediaParserEmptyBytes }.first<0>() : bytes; }
};

struct SWIFT_VIEW MediaParserLatin1 {
    std::span<const Latin1Character> characters;
    ALWAYS_INLINE std::span<const uint8_t> span() const LIFETIME_BOUND { return characters.empty() ? std::span { mediaParserEmptyBytes }.first<0>() : byteCast<uint8_t>(characters); }
};

struct SWIFT_VIEW MediaParserUTF16 {
    std::span<const char16_t> characters;
    ALWAYS_INLINE std::span<const char16_t> span() const LIFETIME_BOUND { return characters.empty() ? std::span { mediaParserEmptyUTF16 }.first<0>() : characters; }
};

// A string of either width, borrowed for one call from C++ into Swift, which reads span8() if is8Bit and span16()
// otherwise.
struct SWIFT_VIEW MediaParserText {
    std::span<const Latin1Character> characters8;
    std::span<const char16_t> characters16;
    bool is8Bit { true };
    ALWAYS_INLINE std::span<const uint8_t> span8() const LIFETIME_BOUND { return characters8.empty() ? std::span { mediaParserEmptyBytes }.first<0>() : byteCast<uint8_t>(characters8); }
    ALWAYS_INLINE std::span<const char16_t> span16() const LIFETIME_BOUND { return characters16.empty() ? std::span { mediaParserEmptyUTF16 }.first<0>() : characters16; }
};

inline MediaParserText mediaParserText(const StringView& string LIFETIME_BOUND)
{
    if (string.is8Bit())
        return { string.span8(), { }, true };
    return { { }, string.span16(), false };
}

// Up to 48 Latin-1 characters by value, in memory order in its words: a codec string that Swift builds.
struct MediaParserShortString {
    static constexpr size_t capacity = 48;
    uint64_t words[6] { };
    uint8_t length { 0 };
};

// A name of up to 16 Latin-1 characters by value, in memory order in its words, for Swift to compare with the ones it
// knows, such as init data types, key systems and key types.
struct MediaParserShortName {
    static constexpr size_t capacity = 16;
    uint64_t words[2] { };
    uint8_t length { 0 };
};

// A name too long to be one that Swift knows is empty, which matches none. Characters beyond Latin-1 become 0xFF, which
// no such name has, even lowercased.
inline MediaParserShortName mediaParserShortName(StringView string)
{
    MediaParserShortName result;
    if (string.length() > MediaParserShortName::capacity)
        return result;
    auto bytes = asWritableBytes(std::span { result.words });
    if (string.is8Bit())
        memcpySpan(bytes, asBytes(string.span8()));
    else {
        auto characters = string.span16();
        for (size_t i = 0; i < characters.size(); ++i)
            bytes[i] = characters[i] <= 0xFF ? characters[i] : 0xFF;
    }
    result.length = static_cast<uint8_t>(string.length());
    return result;
}

inline String makeStringFromShortString(const MediaParserShortString& string)
{
    std::span<Latin1Character> characters;
    auto result = String::createUninitialized(std::min<size_t>(string.length, MediaParserShortString::capacity), characters);
    memcpySpan(asWritableBytes(characters), asBytes(std::span { string.words }).first(characters.size()));
    return result;
}

// A new Latin-1 String of a known length for Swift to fill in place (makeLatin1String() in WTFCompatParsing.swift):
// mutableSpan() lends its characters, zeroed, and takeString() hands it over.
// The span always points into m_string's own buffer (a copy holds a reference to the same one), and is empty once the
// String has been taken.
class SWIFT_SELF_CONTAINED MediaParserLatin1StringBuffer {
public:
    explicit MediaParserLatin1StringBuffer(unsigned length)
    {
        if (!length) {
            m_string = emptyString();
            return;
        }
        std::span<Latin1Character> characters;
        m_string = String::createUninitialized(length, characters);
        zeroSpan(characters);
        m_characters = byteCast<uint8_t>(characters);
    }

    ALWAYS_INLINE std::span<uint8_t> mutableSpan() LIFETIME_BOUND { return m_characters; }

    String takeString()
    {
        m_characters = std::span { mediaParserEmptyMutableBytes }.first<0>();
        return std::exchange(m_string, { });
    }

private:
    String m_string;
    std::span<uint8_t> m_characters { std::span { mediaParserEmptyMutableBytes }.first<0>() };
};

using MediaParserByteVector = Vector<uint8_t>;
using MediaParserUInt32Vector = Vector<uint32_t>;

inline String makeStringFromLatin1(std::span<const uint8_t> latin1 NOESCAPE) { return byteCast<Latin1Character>(latin1); }

// Swift only gets the Span overload of appendBytes() while the vector is spelled with its typedef. The shells lend Swift
// a vector of their own, which no view Swift reads points into, so an append that reallocates it invalidates nothing.
ALWAYS_INLINE void appendBytes(MediaParserByteVector& vector, std::span<const uint8_t> bytes NOESCAPE) { vector.append(bytes); }

}
