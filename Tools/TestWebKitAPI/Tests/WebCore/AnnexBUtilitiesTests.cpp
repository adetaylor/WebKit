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

#include "config.h"

#include <WebCore/AnnexBUtilities.h>
#include <wtf/Vector.h>

namespace TestWebKitAPI {
using namespace WebCore;

static Vector<size_t> flatten(const Vector<NaluIndex>& indices)
{
    Vector<size_t> result;
    for (auto& index : indices)
        result.appendList({ index.startOffset, index.payloadStartOffset, index.payloadSize });
    return result;
}

// Swift traps on an empty span with no base address passed back to C++, so each shell is fed one.
TEST(AnnexBUtilities, EmptyInput)
{
    Vector<uint8_t> emptyVector;
    static constexpr uint8_t oneByte[] = { 0 };
    for (auto input : { std::span<const uint8_t> { }, emptyVector.span(), std::span { oneByte }.first(0) }) {
        EXPECT_TRUE(findNaluIndices(input).isEmpty());
        EXPECT_TRUE(parseRbsp(input).isEmpty());
        EXPECT_TRUE(annexBToLengthPrefixed(input, { }).isEmpty());
    }

    Vector<NaluIndex> emptyIndices;
    static constexpr uint8_t stream[] = { 0x00, 0x00, 0x01, 0x09, 0x10 };
    EXPECT_TRUE(annexBToLengthPrefixed(std::span { stream }, emptyIndices.span()).isEmpty());
    EXPECT_TRUE(annexBToLengthPrefixed({ }, Vector<NaluIndex> { NaluIndex { 0, 0, 0 } }.span()).isEmpty());
}

TEST(AnnexBUtilities, FindNaluIndices)
{
    static constexpr uint8_t fourAndThreeByteStartCodes[] = { 0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, 0x00, 0x00, 0x01, 0x68, 0xBB, 0xCC };
    EXPECT_EQ(flatten(findNaluIndices(std::span { fourAndThreeByteStartCodes })), (Vector<size_t> { 0, 4, 2, 6, 9, 3 }));

    // A start code needs a byte after it.
    static constexpr uint8_t startCodeAtEnd[] = { 0xFF, 0x00, 0x00, 0x01 };
    EXPECT_TRUE(findNaluIndices(std::span { startCodeAtEnd }).isEmpty());
    static constexpr uint8_t oneBytePayload[] = { 0x00, 0x00, 0x01, 0x09 };
    EXPECT_EQ(flatten(findNaluIndices(std::span { oneBytePayload })), (Vector<size_t> { 0, 3, 1 }));

    static constexpr uint8_t emptyPayload[] = { 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x41 };
    EXPECT_EQ(flatten(findNaluIndices(std::span { emptyPayload })), (Vector<size_t> { 0, 3, 0, 3, 6, 1 }));

    // Bytes before the first start code are ignored, and a zero before a start code belongs to the start code.
    static constexpr uint8_t leadingBytes[] = { 0x12, 0x00, 0x00, 0x01, 0x65, 0x00, 0x00, 0x00, 0x01, 0x41, 0x42 };
    EXPECT_EQ(flatten(findNaluIndices(std::span { leadingBytes })), (Vector<size_t> { 1, 4, 1, 5, 9, 2 }));

    static constexpr uint8_t noStartCode[] = { 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00 };
    EXPECT_TRUE(findNaluIndices(std::span { noStartCode }).isEmpty());
}

TEST(AnnexBUtilities, ParseRbsp)
{
    auto rbsp = [](std::initializer_list<uint8_t> bytes) {
        Vector<uint8_t> data { bytes };
        return parseRbsp(data.span());
    };
    EXPECT_EQ(rbsp({ 0x00, 0x00, 0x03, 0x01 }), (Vector<uint8_t> { 0x00, 0x00, 0x01 }));
    EXPECT_EQ(rbsp({ 0x25, 0x00, 0x00, 0x03 }), (Vector<uint8_t> { 0x25, 0x00, 0x00 }));
    EXPECT_EQ(rbsp({ 0x00, 0x00, 0x00, 0x03 }), (Vector<uint8_t> { 0x00, 0x00, 0x00 }));
    EXPECT_EQ(rbsp({ 0x00, 0x00, 0x03, 0x00, 0x00, 0x03 }), (Vector<uint8_t> { 0x00, 0x00, 0x00, 0x00 }));
    EXPECT_EQ(rbsp({ 0x00, 0x00, 0x03, 0x03 }), (Vector<uint8_t> { 0x00, 0x00, 0x03 }));
    EXPECT_EQ(rbsp({ 0x03, 0x00, 0x03, 0x00, 0x00 }), (Vector<uint8_t> { 0x03, 0x00, 0x03, 0x00, 0x00 }));
    EXPECT_EQ(rbsp({ 0x00, 0x03 }), (Vector<uint8_t> { 0x00, 0x03 }));
}

TEST(AnnexBUtilities, AnnexBToLengthPrefixed)
{
    static constexpr uint8_t stream[] = { 0x00, 0x00, 0x00, 0x01, 0x67, 0xAA, 0x00, 0x00, 0x01, 0x68, 0xBB, 0xCC };
    auto indices = findNaluIndices(std::span { stream });
    EXPECT_EQ(annexBToLengthPrefixed(std::span { stream }, indices.span()), (Vector<uint8_t> { 0x00, 0x00, 0x00, 0x02, 0x67, 0xAA, 0x00, 0x00, 0x00, 0x03, 0x68, 0xBB, 0xCC }));
    EXPECT_EQ(annexBToLengthPrefixed(std::span { stream }, indices.subspan(1)), (Vector<uint8_t> { 0x00, 0x00, 0x00, 0x03, 0x68, 0xBB, 0xCC }));

    // Empty payloads are left out.
    static constexpr uint8_t emptyPayload[] = { 0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x41 };
    EXPECT_EQ(annexBToLengthPrefixed(std::span { emptyPayload }, findNaluIndices(std::span { emptyPayload }).span()), (Vector<uint8_t> { 0x00, 0x00, 0x00, 0x01, 0x41 }));

    Vector<uint8_t> longPayload(303, [](size_t index) -> uint8_t {
        return index < 2 ? 0x00 : index == 2 ? 0x01 : 0x11;
    });
    auto converted = annexBToLengthPrefixed(longPayload.span(), findNaluIndices(longPayload.span()).span());
    ASSERT_EQ(converted.size(), 304u);
    EXPECT_EQ(Vector<uint8_t>(converted.subspan(0, 5)), (Vector<uint8_t> { 0x00, 0x00, 0x01, 0x2C, 0x11 }));
}

} // namespace TestWebKitAPI
