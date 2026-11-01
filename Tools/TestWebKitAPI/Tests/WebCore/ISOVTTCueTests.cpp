/*
 * Copyright (C) 2018-2026 Apple Inc. All rights reserved.
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

#include "config.h"

#include <WebCore/ISOVTTCue.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomString.h>

namespace TestWebKitAPI {
using namespace WebCore;

static void appendUInt32(Vector<uint8_t>& bytes, uint32_t value)
{
    bytes.appendList({ static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16), static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value) });
}

static Vector<uint8_t> box(ASCIILiteral type, std::span<const uint8_t> payload, std::optional<uint32_t> size = std::nullopt)
{
    Vector<uint8_t> bytes;
    appendUInt32(bytes, size.value_or(8 + payload.size()));
    bytes.append(byteCast<uint8_t>(type.span8()));
    bytes.append(payload);
    return bytes;
}

static Vector<uint8_t> box(ASCIILiteral type, ASCIILiteral text, std::optional<uint32_t> size = std::nullopt)
{
    return box(type, byteCast<uint8_t>(text.span8()), size);
}

static Vector<uint8_t> concatenate(std::initializer_list<Vector<uint8_t>> parts)
{
    Vector<uint8_t> bytes;
    for (auto& part : parts)
        bytes.append(part.span());
    return bytes;
}

static void expectAllNull(const ISOWebVTTCue& cue)
{
    EXPECT_TRUE(cue.sourceID().isNull());
    EXPECT_TRUE(cue.id().isNull());
    EXPECT_TRUE(cue.originalStartTime().isNull());
    EXPECT_TRUE(cue.settings().isNull());
    EXPECT_TRUE(cue.cueText().isNull());
}

// Swift traps on an empty span with no base address passed back to C++, so the shell is fed one.
TEST(ISOVTTCue, EmptyInput)
{
    Vector<uint8_t> emptyVector;
    static constexpr uint8_t oneByte[] = { 0 };
    for (auto input : { std::span<const uint8_t> { }, emptyVector.span(), std::span { oneByte }.first(0) }) {
        ISOWebVTTCue cue;
        EXPECT_FALSE(cue.read(input));
        unsigned offset = 0;
        EXPECT_FALSE(cue.parse(input, offset));
        EXPECT_EQ(0u, offset);
        offset = 5;
        EXPECT_FALSE(cue.parse(input, offset));
        EXPECT_EQ(5u, offset);
        expectAllNull(cue);
    }
}

TEST(ISOVTTCue, AllStringBoxes)
{
    static constexpr Latin1Character sourceID[] = { 0, 0, 0, 7 };
    auto bytes = box("vttc"_s, concatenate({ box("vsid"_s, byteCast<uint8_t>(std::span { sourceID })), box("iden"_s, "cue-1"_s), box("ctim"_s, "00:00:01.000"_s), box("sttg"_s, "align:center"_s), box("payl"_s, "Hello, world!"_s) }));

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_EQ(String(std::span { sourceID }), cue.sourceID());
    EXPECT_EQ(4u, cue.sourceID().length());
    EXPECT_EQ("cue-1"_s, cue.id());
    EXPECT_EQ("00:00:01.000"_s, cue.originalStartTime());
    EXPECT_EQ("align:center"_s, cue.settings());
    EXPECT_EQ("Hello, world!"_s, cue.cueText());
}

TEST(ISOVTTCue, EmptyAndMissingStringBoxes)
{
    auto bytes = box("vttc"_s, concatenate({ box("iden"_s, ""_s), box("payl"_s, ""_s) }));

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_TRUE(cue.id().isEmpty());
    EXPECT_FALSE(cue.id().isNull());
    EXPECT_TRUE(cue.cueText().isEmpty());
    EXPECT_FALSE(cue.cueText().isNull());
    EXPECT_TRUE(cue.sourceID().isNull());
    EXPECT_TRUE(cue.originalStartTime().isNull());
    EXPECT_TRUE(cue.settings().isNull());

    ISOWebVTTCue noStrings;
    auto empty = box("vttc"_s, ""_s);
    EXPECT_TRUE(noStrings.read(empty.span()));
    expectAllNull(noStrings);
}

TEST(ISOVTTCue, InvalidUTF8IsNull)
{
    static constexpr uint8_t invalid[] = { 0xFF, 0xFE };
    static constexpr uint8_t accented[] = { 0xC3, 0xA9, 't', 0xC3, 0xA9 };
    auto bytes = box("vttc"_s, concatenate({ box("payl"_s, std::span { invalid }), box("iden"_s, std::span { accented }) }));

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_TRUE(cue.cueText().isNull());
    EXPECT_EQ(String::fromUTF8("\xC3\xA9t\xC3\xA9"), cue.id());
}

TEST(ISOVTTCue, LastBoxOfATypeWinsAndUnknownBoxesAreSkipped)
{
    auto bytes = box("vttc"_s, concatenate({ box("payl"_s, "first"_s), box("zzzz"_s, "skipped"_s), box("payl"_s, "second"_s), box("vtta"_s, ""_s) }));

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_EQ("second"_s, cue.cueText());
    EXPECT_TRUE(cue.settings().isNull());
}

TEST(ISOVTTCue, MissingStringBoxesKeepTheirFields)
{
    auto bytes = box("vttc"_s, box("payl"_s, "text"_s));

    ISOWebVTTCue cue { MediaTime::zeroTime(), MediaTime::zeroTime(), "id"_s, "old text"_s, "settings"_s, "source"_s, "start"_s };
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_EQ("text"_s, cue.cueText());
    EXPECT_EQ("id"_s, cue.id());
    EXPECT_EQ("settings"_s, cue.settings());
    EXPECT_EQ("source"_s, cue.sourceID());
    EXPECT_EQ("start"_s, cue.originalStartTime());
}

TEST(ISOVTTCue, IdentifierIsAtomized)
{
    auto bytes = box("vttc"_s, box("iden"_s, "atomized"_s));

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    ASSERT_TRUE(cue.id().impl());
    EXPECT_TRUE(cue.id().impl()->isAtom());
}

TEST(ISOVTTCue, ParseAtOffset)
{
    auto first = box("vttc"_s, box("payl"_s, "one"_s));
    auto second = box("vttc"_s, box("payl"_s, "two"_s));
    auto bytes = concatenate({ first, second });

    ISOWebVTTCue cue;
    unsigned offset = first.size();
    EXPECT_TRUE(cue.parse(bytes.span(), offset));
    EXPECT_EQ(bytes.size(), offset);
    EXPECT_EQ("two"_s, cue.cueText());

    // A failed header read leaves the offset where reading stopped: after the size field here.
    ISOWebVTTCue truncated;
    offset = first.size();
    EXPECT_FALSE(truncated.parse(bytes.span().first(first.size() + 6), offset));
    EXPECT_EQ(first.size() + 4, offset);
    expectAllNull(truncated);

    ISOWebVTTCue pastTheEnd;
    offset = bytes.size() + 1;
    EXPECT_FALSE(pastTheEnd.parse(bytes.span(), offset));
    EXPECT_EQ(bytes.size() + 1, offset);
}

TEST(ISOVTTCue, StringBoxSmallerThanItsHeaderEndsTheCue)
{
    auto bytes = box("vttc"_s, concatenate({ box("iden"_s, "cue-1"_s), box("payl"_s, "abcd"_s, 4) }));

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_EQ("cue-1"_s, cue.id());
    EXPECT_TRUE(cue.cueText().isNull());

    unsigned offset = 0;
    ISOWebVTTCue parsed;
    EXPECT_TRUE(parsed.parse(bytes.span(), offset));
    EXPECT_EQ(8u + 13u, offset);
}

TEST(ISOVTTCue, LargeSizeAndUUIDHeaders)
{
    auto payload = box("payl"_s, "large"_s);
    Vector<uint8_t> largeSize;
    appendUInt32(largeSize, 1);
    largeSize.append(byteCast<uint8_t>("vttc"_s.span8()));
    appendUInt32(largeSize, 0);
    appendUInt32(largeSize, 16 + payload.size());
    largeSize.append(payload.span());

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(largeSize.span()));
    EXPECT_EQ("large"_s, cue.cueText());

    // The cue doesn't check its own box type; a 'uuid' header has 16 more bytes.
    Vector<uint8_t> uuidPayload;
    uuidPayload.fill(0xAB, 16);
    uuidPayload.append(box("payl"_s, "uuid"_s).span());
    auto uuid = box("uuid"_s, uuidPayload.span());
    ISOWebVTTCue uuidCue;
    EXPECT_TRUE(uuidCue.read(uuid.span()));
    EXPECT_EQ("uuid"_s, uuidCue.cueText());
}

// A cue's string boxes end with the cue.
TEST(ISOVTTCue, StringBoxesEndWithTheCue)
{
    auto bytes = concatenate({ box("vttc"_s, box("payl"_s, "inside"_s)), box("payl"_s, "outside"_s), box("vttc"_s, box("iden"_s, "next"_s)) });

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_EQ("inside"_s, cue.cueText());
    EXPECT_TRUE(cue.id().isNull());

    unsigned offset = 0;
    ISOWebVTTCue parsed;
    EXPECT_TRUE(parsed.parse(bytes.span(), offset));
    EXPECT_EQ(8u + 14u, offset);
}

// A string box is clamped to the end of its cue, not of the buffer.
TEST(ISOVTTCue, StringBoxClampedToTheCue)
{
    auto bytes = concatenate({ box("vttc"_s, box("payl"_s, "abc"_s, 0)), Vector<uint8_t> { 'd', 'e', 'f' } });

    ISOWebVTTCue cue;
    EXPECT_TRUE(cue.read(bytes.span()));
    EXPECT_EQ("abc"_s, cue.cueText());
}

// A cue whose size is smaller than its header has no string boxes.
TEST(ISOVTTCue, CueSmallerThanItsHeader)
{
    auto bytes = concatenate({ box("vttc"_s, ""_s, 4), box("payl"_s, "after"_s) });

    ISOWebVTTCue cue;
    EXPECT_FALSE(cue.read(bytes.span()));
    expectAllNull(cue);

    unsigned offset = 0;
    ISOWebVTTCue parsed;
    EXPECT_TRUE(parsed.parse(bytes.span(), offset));
    EXPECT_EQ(8u, offset);
    expectAllNull(parsed);
}

} // namespace TestWebKitAPI
