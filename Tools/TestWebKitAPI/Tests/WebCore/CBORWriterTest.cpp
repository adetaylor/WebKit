// Copyright 2017 The Chromium Authors. All rights reserved.
// Copyright (C) 2018 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"

#if ENABLE(WEB_AUTHN)

#include "CBORTestUtilities.h"
#include <WebCore/CBORBytes.h>
#include <limits>
#include <wtf/StdLibExtras.h>

// Leveraging RFC 7049 examples from https://github.com/cbor/test-vectors/blob/master/appendix_a.json.
namespace TestWebKitAPI {

using namespace cbor;

bool eq(const Vector<uint8_t>& cbor, std::span<const uint8_t> expect)
{
    return equalSpans(cbor.span(), expect);
}

// Writes item (a map may list its keys in any order) and checks the bytes.
static void expectWritten(const CBORItem& item, std::span<const uint8_t> expected, size_t maxNestingLevel = kCBORDefaultMaxNestingDepth)
{
    auto cbor = writeCanonical(item, maxNestingLevel);
    ASSERT_TRUE(cbor.has_value());
    EXPECT_TRUE(eq(cbor.value(), expected));
}

static bool writes(const CBORItem& item, size_t maxNestingLevel)
{
    return writeCanonical(item, maxNestingLevel).has_value();
}

TEST(CBORWriterTest, TestWriteUint)
{
    typedef struct {
        const int64_t value;
        const Vector<uint8_t> cbor;
    } UintTestCase;

    static const UintTestCase kUintTestCases[] = {
        { 0, { 0x00 } },
        { 1, { 0x01 } },
        { 10, { 0x0a } },
        { 23, { 0x17 } },
        { 24, { 0x18, 0x18 } },
        { 25, { 0x18, 0x19 } },
        { 100, { 0x18, 0x64 } },
        { 1000, { 0x19, 0x03, 0xe8 } },
        { 1000000, { 0x1a, 0x00, 0x0f, 0x42, 0x40 } },
        { 0xFFFFFFFF, { 0x1a, 0xff, 0xff, 0xff, 0xff } },
        { 0x100000000,
            { 0x1b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 } },
        { std::numeric_limits<int64_t>::max(),
            { 0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } }
    };

    for (const UintTestCase& testCase : kUintTestCases)
        expectWritten(cborInteger(testCase.value), testCase.cbor.span());
}

TEST(CBORWriterTest, TestWriteNegativeInteger)
{
    static const struct {
        const int64_t negativeInt;
        const Vector<uint8_t> cbor;
    } kNegativeIntTestCases[] = {
        { -1LL, { 0x20 } },
        { -10LL, { 0x29 } },
        { -23LL, { 0x36 } },
        { -24LL, { 0x37 } },
        { -25LL, { 0x38, 0x18 } },
        { -100LL, { 0x38, 0x63 } },
        { -1000LL, { 0x39, 0x03, 0xe7 } },
        { -4294967296LL, { 0x3a, 0xff, 0xff, 0xff, 0xff } },
        { -4294967297LL,
            { 0x3b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 } },
        { std::numeric_limits<int64_t>::min(),
            { 0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },
    };

    for (const auto& testCase : kNegativeIntTestCases)
        expectWritten(cborInteger(testCase.negativeInt), testCase.cbor.span());
}

TEST(CBORWriterTest, TestWriteBytes)
{
    typedef struct {
        const Vector<uint8_t> bytes;
        const Vector<uint8_t> cbor;
    } BytesTestCase;

    static const BytesTestCase kBytesTestCases[] = {
        { { }, { 0x40 } },
        { { 0x01, 0x02, 0x03, 0x04 }, { 0x44, 0x01, 0x02, 0x03, 0x04 } },
    };

    for (const BytesTestCase& testCase : kBytesTestCases)
        expectWritten(cborBytes(testCase.bytes.span()), testCase.cbor.span());
}

TEST(CBORWriterTest, TestWriteString)
{
    typedef struct {
        const String string;
        const Vector<uint8_t> cbor;
    } StringTestCase;

    static const StringTestCase kStringTestCases[] = {
        { emptyString(), { 0x60 } },
        { "a"_s, { 0x61, 0x61 } },
        { "IETF"_s, { 0x64, 0x49, 0x45, 0x54, 0x46 } },
        { "\"\\"_s, { 0x62, 0x22, 0x5c } },
        { String::fromUTF8("\xc3\xbc"), { 0x62, 0xc3, 0xbc } },
        { String::fromUTF8("\xe6\xb0\xb4"), { 0x63, 0xe6, 0xb0, 0xb4 } },
        { String::fromUTF8("\xf0\x90\x85\x91"), { 0x64, 0xf0, 0x90, 0x85, 0x91 } }
    };

    for (const StringTestCase& testCase : kStringTestCases)
        expectWritten(cborText(testCase.string), testCase.cbor.span());
}

TEST(CBORWriterTest, TestWriteArray)
{
    static const uint8_t kArrayTestCaseCbor[] = {
        0x98, 0x19, // array of 25 elements
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x18, 0x18, 0x19,
    };
    CBORItem array;
    appendCBORHead(array, 4, 25);
    for (int64_t i = 1; i <= 25; i++)
        array.appendVector(cborInteger(i));
    expectWritten(array, std::span { kArrayTestCaseCbor });
}

TEST(CBORWriterTest, TestWriteMapWithMapValue)
{
    static const uint8_t kMapTestCaseCbor[] = {
        0xb6, // map of 8 pairs:
        0x00, // key 0
        0x61, 0x61, // value "a"

        0x17, // key 23
        0x61,  0x62, // value "b"

        0x18, 0x18, // key 24
        0x61, 0x63, // value "c"

        0x18, 0xFF, // key 255
        0x61,  0x64, // value "d"

        0x19, 0x01, 0x00, // key 256
        0x61, 0x65, // value "e"

        0x19, 0xFF, 0xFF, // key 65535
        0x61,  0x66, // value "f"

        0x1A, 0x00, 0x01, 0x00, 0x00, // key 65536
        0x61, 0x67, // value "g"

        0x1A, 0xFF, 0xFF, 0xFF, 0xFF, // key 4294967295
        0x61, 0x68, // value "h"

        // key 4294967296
        0x1B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x61, 0x69, //  value "i"

        // key INT64_MAX
        0x1b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x61, 0x6a, //  value "j"

        0x20, // key -1
        0x61, 0x6b, // value "k"

        0x37, // key -24
        0x61,  0x6c, // value "l"

        0x38, 0x18, // key -25
        0x61, 0x6d, // value "m"

        0x38, 0xFF, // key -256
        0x61, 0x6e, // value "n"

        0x39, 0x01, 0x00, // key -257
        0x61, 0x6f, // value "o"

        0x3A, 0x00, 0x01, 0x00, 0x00, // key -65537
        0x61, 0x70, // value "p"

        0x3A, 0xFF, 0xFF, 0xFF, 0xFF, // key -4294967296
        0x61, 0x71, // value "q"

        // key -4294967297
        0x3B, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x61, 0x72, //  value "r"

        // key INT64_MIN
        0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x61, 0x73, //  value "s"

        0x60, // key ""
        0x61, 0x2e, // value "."

        0x61, 0x65, // key "e"
        0x61, 0x45, // value "E"

        0x62, 0x61, 0x61, // key "aa"
        0x62, 0x41, 0x41, // value "AA"
    };
    // The keys are listed in no particular order: the writer sorts them.
    // Shorter strings sort first in CTAP, thus the “aa” value should be
    // serialised last in the map.
    // The empty string is shorter than all others, so should appear first among
    // the strings.
    // Map keys are sorted by major type, by byte length, and then by
    // byte-wise lexical order. So all integer type keys should appear before
    // key "" and all positive integer keys should appear before negative integer
    // keys.
    auto text = [](const char* string) {
        return cborText(String::fromUTF8(string));
    };
    auto map = cborMap({
        { text("aa"), text("AA") },
        { text("e"), text("E") },
        { text(""), text(".") },
        { cborInteger(-1), text("k") },
        { cborInteger(-24), text("l") },
        { cborInteger(-25), text("m") },
        { cborInteger(-256), text("n") },
        { cborInteger(-257), text("o") },
        { cborInteger(-65537), text("p") },
        { cborInteger(-4294967296), text("q") },
        { cborInteger(-4294967297), text("r") },
        { cborInteger(std::numeric_limits<int64_t>::min()), text("s") },
        { cborInteger(0), text("a") },
        { cborInteger(23), text("b") },
        { cborInteger(24), text("c") },
        { cborInteger(std::numeric_limits<uint8_t>::max()), text("d") },
        { cborInteger(256), text("e") },
        { cborInteger(std::numeric_limits<uint16_t>::max()), text("f") },
        { cborInteger(65536), text("g") },
        { cborInteger(std::numeric_limits<uint32_t>::max()), text("h") },
        { cborInteger(4294967296), text("i") },
        { cborInteger(std::numeric_limits<int64_t>::max()), text("j") },
    });
    expectWritten(map, std::span { kMapTestCaseCbor });
}

// A key written twice keeps the first of its values.
TEST(CBORWriterTest, TestWriteMapWithRepeatedKey)
{
    static const uint8_t kExpected[] = {
        0xa2, // map of 2 pairs
        0x01, 0x61, 0x61, // 1: "a"
        0x61, 0x6b, 0x02, // "k": 2
    };
    auto map = cborMap({
        { cborText("k"_s), cborInteger(2) },
        { cborInteger(1), cborText("a"_s) },
        { cborInteger(1), cborText("b"_s) },
        { cborText("k"_s), cborInteger(3) },
    });
    expectWritten(map, std::span { kExpected });
}

TEST(CBORWriterTest, TestWriteMapWithArray)
{
    static const uint8_t kMapArrayTestCaseCbor[] = {
        0xa2, // map of 2 pairs
        0x61, 0x61, // "a"
        0x01,

        0x61, 0x62, // "b"
        0x82, // array with 2 elements
        0x02,
        0x03,
    };
    auto map = cborMap({
        { cborText("b"_s), cborArray({ cborInteger(2), cborInteger(3) }) },
        { cborText("a"_s), cborInteger(1) },
    });
    expectWritten(map, std::span { kMapArrayTestCaseCbor });
}

TEST(CBORWriterTest, TestWriteNestedMap)
{
    static const uint8_t kNestedMapTestCase[] = {
        0xa2, // map of 2 pairs
        0x61, 0x61, // "a"
        0x01,

        0x61, 0x62, // "b"
        0xa2, // map of 2 pairs
        0x61, 0x63, // "c"
        0x02,

        0x61, 0x64, // "d"
        0x03,
    };
    auto nestedMap = cborMap({
        { cborText("d"_s), cborInteger(3) },
        { cborText("c"_s), cborInteger(2) },
    });
    auto map = cborMap({
        { cborText("b"_s), nestedMap },
        { cborText("a"_s), cborInteger(1) },
    });
    expectWritten(map, std::span { kNestedMapTestCase });
}

TEST(CBORWriterTest, TestWriteSimpleValue)
{
    static const struct {
        uint8_t simpleValue;
        const Vector<uint8_t> cbor;
    } kSimpleTestCase[] = {
        { 20, { 0xf4 } }, // false
        { 21, { 0xf5 } }, // true
        { 22, { 0xf6 } }, // null
        { 23, { 0xf7 } } // undefined
    };

    for (const auto& testCase : kSimpleTestCase)
        expectWritten(cborSimple(testCase.simpleValue), testCase.cbor.span());
}

// For major type 0, 2, 3, empty CBOR array, and empty CBOR map, the nesting
// depth is expected to be 0 since the CBOR decoder does not need to parse
// any nested CBOR value elements.
TEST(CBORWriterTest, TestWriteSingleLayer)
{
    const Vector<uint8_t> byteData = { 0x01, 0x02, 0x03, 0x04 };
    auto singleLayerCborMap = cborMap({ { cborText("b"_s), cborInteger(3) } });
    auto singleLayerCborArray = cborArray({ cborInteger(2) });

    EXPECT_TRUE(writes(cborInteger(1), 0));
    EXPECT_TRUE(writes(cborText("a"_s), 0));
    EXPECT_TRUE(writes(cborBytes(byteData.span()), 0));

    EXPECT_TRUE(writes(cborArray({ }), 0));
    EXPECT_TRUE(writes(cborMap({ }), 0));

    EXPECT_FALSE(writes(singleLayerCborArray, 0));
    EXPECT_TRUE(writes(singleLayerCborArray, 1));

    EXPECT_FALSE(writes(singleLayerCborMap, 0));
    EXPECT_TRUE(writes(singleLayerCborMap, 1));
}

// Major type 5 nested CBOR map value with following structure.
//     {"a": 1,
//      "b": {"c": 2,
//            "d": 3}}
TEST(CBORWriterTest, NestedMaps)
{
    auto nestedMap = cborMap({
        { cborText("c"_s), cborInteger(2) },
        { cborText("d"_s), cborInteger(3) },
    });
    auto cborMapItem = cborMap({
        { cborText("a"_s), cborInteger(1) },
        { cborText("b"_s), nestedMap },
    });
    EXPECT_TRUE(writes(cborMapItem, 2));
    EXPECT_FALSE(writes(cborMapItem, 1));
}

// Testing Write() function for following CBOR structure with depth of 3.
//     [1,
//      2,
//      3,
//      {"a": 1,
//       "b": {"c": 2,
//             "d": 3}}]
TEST(CBORWriterTest, UnbalancedNestedContainers)
{
    auto nestedMap = cborMap({
        { cborText("c"_s), cborInteger(2) },
        { cborText("d"_s), cborInteger(3) },
    });
    auto cborMapItem = cborMap({
        { cborText("a"_s), cborInteger(1) },
        { cborText("b"_s), nestedMap },
    });
    auto cborArrayItem = cborArray({ cborInteger(1), cborInteger(2), cborInteger(3), cborMapItem });

    EXPECT_TRUE(writes(cborArrayItem, 3));
    EXPECT_FALSE(writes(cborArrayItem, 2));
}

// Testing Write() function for following CBOR structure.
//     {"a": 1,
//      "b": {"c": 2,
//            "d": 3
//            "h": { "e": 4,
//                   "f": 5,
//                   "g": [6, 7, [8]]}}}
// Since above CBOR contains 5 nesting levels. Thus, Write() is expected to
// return empty optional object when maximum nesting layer size is set to 4.
TEST(CBORWriterTest, OverlyNestedCBOR)
{
    auto innerArray = cborArray({ cborInteger(6) });
    auto array = cborArray({ cborInteger(6), cborInteger(7), innerArray });
    auto innerNestedMap = cborMap({
        { cborText("e"_s), cborInteger(4) },
        { cborText("f"_s), cborInteger(5) },
        { cborText("g"_s), array },
    });
    auto nestedMap = cborMap({
        { cborText("c"_s), cborInteger(2) },
        { cborText("d"_s), cborInteger(3) },
        { cborText("h"_s), innerNestedMap },
    });
    auto map = cborMap({
        { cborText("a"_s), cborInteger(1) },
        { cborText("b"_s), nestedMap },
    });

    EXPECT_TRUE(writes(map, 5));
    EXPECT_FALSE(writes(map, 4));
}

// A map of `count` entries, key i (0 ... count - 1) to the negative integer -1 - i, and its encoding: the header,
// then each key and each value as a one-byte item (count <= 24). The entries are listed from the last key to the first.
static void checkIntegerMapWrite(size_t count)
{
    CBORItem item;
    appendCBORHead(item, 5, count);
    Vector<uint8_t> expected;
    expected.append(static_cast<uint8_t>(0xa0 | count));
    for (size_t i = 0; i < count; ++i) {
        expected.append(static_cast<uint8_t>(i));
        expected.append(static_cast<uint8_t>(0x20 | i));
    }
    for (size_t i = count; i--;) {
        item.appendVector(cborInteger(static_cast<int64_t>(i)));
        item.appendVector(cborInteger(-1 - static_cast<int64_t>(i)));
    }

    expectWritten(item, expected.span());

    // A map of integers nests one level: one level suffices, none does not.
    expectWritten(item, expected.span(), 1);
    EXPECT_FALSE(writes(item, 0));
}

// Maps around the 16-entry size are written correctly.
TEST(CBORWriterTest, WriteMapsAroundSixteenEntries)
{
    checkIntegerMapWrite(15);
    checkIntegerMapWrite(16);
    checkIntegerMapWrite(17);
    checkIntegerMapWrite(20);
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
