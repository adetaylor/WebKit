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
#include <WebCore/AuthenticationExtensionsClientOutputs.h>
#include <WebCore/CBORBytes.h>
#include <limits>
#include <utility>

// Leveraging RFC 7049 examples from https://github.com/cbor/test-vectors/blob/master/appendix_a.json.
namespace TestWebKitAPI {

using namespace cbor;

// The reader returns the item in canonical form, so an input that is canonical comes back as itself: a successful read
// is checked as its bytes, which fixes the type and the value of every item in it.
static void expectReadsAsItself(const Vector<uint8_t>& input, int maxNestingLevel = kCBORMaxDepth)
{
    auto result = readCanonical(input.span(), maxNestingLevel);
    EXPECT_TRUE(result.error == DecoderError::CBORNoError);
    EXPECT_EQ(result.bytesConsumed, input.size());
    EXPECT_TRUE(result.canonical == input);
}

static void expectReadError(const Vector<uint8_t>& input, DecoderError expected, int maxNestingLevel = kCBORMaxDepth)
{
    auto result = readCanonical(input.span(), maxNestingLevel);
    EXPECT_TRUE(result.error == expected);
    EXPECT_TRUE(result.canonical.isEmpty());
}

TEST(CBORReaderTest, TestReadUint)
{
    static const Vector<uint8_t> kUintTestCases[] = {
        { 0x00 },
        { 0x01 },
        { 0x17 },
        { 0x18, 0x18 },
        { 0x18, 0xff },
        { 0x19, 0x01, 0x00 },
        { 0x19, 0xff, 0xff },
        { 0x1a, 0x00, 0x01, 0x00, 0x00 },
        { 0x1a, 0xff, 0xff, 0xff, 0xff },
        { 0x1b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 },
        { 0x1b, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    };

    for (const auto& cborData : kUintTestCases)
        expectReadsAsItself(cborData);
}

TEST(CBORReaderTest, TestUintEncodedWithNonMinimumByteLength)
{
    static const Vector<uint8_t> nonMinimalUintEncodings[] = {
        // Uint 23 encoded with 1 byte.
        { 0x18, 0x17 },
        // Uint 255 encoded with 2 bytes.
        { 0x19, 0x00, 0xff },
        // Uint 65535 encoded with 4 byte.
        { 0x1a, 0x00, 0x00, 0xff, 0xff },
        // Uint 4294967295 encoded with 8 byte.
        { 0x1b, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff },
        // When decoding byte has more than one syntax error, the first syntax
        // error encountered during deserialization is returned as the error code.
        {
            0xa2, // map with non-minimally encoded key
            0x17, // key 24
            0x61, 0x42, // value :"B"
            0x18, 0x17, // key 23 encoded with extra byte
            0x61, 0x45 // value "E"
        },
        {
            0xa2, // map with out of order and non-minimally encoded key
            0x18, 0x17, // key 23 encoded with extra byte
            0x61, 0x45, // value "E"
            0x17, // key 23
            0x61, 0x42 // value :"B"
        },
        {
            0xa2, // map with duplicate non-minimally encoded key
            0x18, 0x17, // key 23 encoded with extra byte
            0x61, 0x45, // value "E"
            0x18, 0x17, // key 23 encoded with extra byte
            0x61, 0x42 // value :"B"
        },
    };

    for (const auto& nonMinimalUint : nonMinimalUintEncodings)
        expectReadError(nonMinimalUint, DecoderError::NonMinimalCBOREncoding);
}

TEST(CBORReaderTest, TestReadNegativeInt)
{
    static const Vector<uint8_t> kNegativeIntTestCases[] = {
        { 0x20 },
        { 0x37 },
        { 0x38, 0x18 },
        { 0x38, 0xff },
        { 0x39, 0x03, 0xe7 },
        { 0x3a, 0x00, 0x0f, 0x42, 0x3f },
        { 0x3a, 0xff, 0xff, 0xff, 0xff },
        { 0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    };

    for (const auto& cborData : kNegativeIntTestCases)
        expectReadsAsItself(cborData);
}

TEST(CBORReaderTest, TestReadBytes)
{
    static const Vector<uint8_t> kByteStringTestCases[] = {
        { 0x40 },
        { 0x44, 0x01, 0x02, 0x03, 0x04 },
    };

    for (const auto& cborData : kByteStringTestCases)
        expectReadsAsItself(cborData);
}

TEST(CBORReaderTest, TestReadString)
{
    static const Vector<uint8_t> kStringTestCases[] = {
        { 0x60 },
        { 0x61, 0x61 },
        { 0x64, 0x49, 0x45, 0x54, 0x46 },
        { 0x62, 0x22, 0x5c },
        { 0x62, 0xc3, 0xbc },
        { 0x63, 0xe6, 0xb0, 0xb4 },
        { 0x64, 0xf0, 0x90, 0x85, 0x91 },
    };

    for (const auto& cborData : kStringTestCases)
        expectReadsAsItself(cborData);
}

TEST(CBORReaderTest, TestReadStringWithNUL)
{
    static const Vector<uint8_t> kStringTestCases[] = {
        // "string_without_nul"
        { 0x72, 0x73, 0x74, 0x72, 0x69, 0x6E, 0x67, 0x5F, 0x77, 0x69, 0x74, 0x68,
            0x6F, 0x75, 0x74, 0x5F, 0x6E, 0x75, 0x6C },
        // "nul_terminated_string" with a trailing NUL.
        { 0x76, 0x6E, 0x75, 0x6C, 0x5F, 0x74, 0x65, 0x72, 0x6D, 0x69, 0x6E, 0x61,
            0x74, 0x65, 0x64, 0x5F, 0x73, 0x74, 0x72, 0x69, 0x6E, 0x67, 0x00 },
        // "embedded" NUL "nul".
        { 0x6C, 0x65, 0x6D, 0x62, 0x65, 0x64, 0x64, 0x65, 0x64, 0x00, 0x6E, 0x75,
            0x6C },
        // "trailing_nuls" with two trailing NULs.
        { 0x6F, 0x74, 0x72, 0x61, 0x69, 0x6C, 0x69, 0x6E, 0x67, 0x5F, 0x6E, 0x75,
            0x6C, 0x73, 0x00, 0x00 },
    };

    for (const auto& cborData : kStringTestCases)
        expectReadsAsItself(cborData);
}

TEST(CBORReaderTest, TestReadStringWithInvalidByteSequenceAfterNUL)
{
    // UTF-8 validation should not stop at the first NUL character in the string.
    // That is, a string with an invalid byte sequence should fail UTF-8
    // validation even if the invalid character is located after one or more NUL
    // characters. Here, 0xA6 is an unexpected continuation byte.
    static const Vector<uint8_t> stringWithInvalidContinuationByte = {
        0x63, 0x00, 0x00, 0xA6
    };
    expectReadError(stringWithInvalidContinuationByte, DecoderError::InvalidUTF8);
}

TEST(CBORReaderTest, TestReadArray)
{
    static const Vector<uint8_t> kArrayTestCaseCBOR = {
        0x98, 0x19, // array of 25 elements
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x18, 0x18, 0x19,
    };

    expectReadsAsItself(kArrayTestCaseCBOR);
}

TEST(CBORReaderTest, TestReadMapWithMapValue)
{
    static const Vector<uint8_t> kMapTestCaseCBOR = {
        0xa4, // map with 4 key value pairs:
        0x18, 0x18, // 24
        0x63, 0x61, 0x62, 0x63, // "abc"

        0x60, // ""
        0x61, 0x2e, // "."

        0x61, 0x62, // "b"
        0x61, 0x42, // "B"

        0x62, 0x61, 0x61, // "aa"
        0x62, 0x41, 0x41, // "AA"
    };

    expectReadsAsItself(kMapTestCaseCBOR);

    // Each key finds its value.
    auto result = readCanonical(kMapTestCaseCBOR.span());
    auto lookup = [&](const CBORItem& key) {
        return cborMapLookup(result.canonical.span(), key.span());
    };
    auto abc = lookup(cborInteger(24));
    ASSERT_TRUE(abc.has_value());
    EXPECT_TRUE(std::ranges::equal(*abc, cborText("abc"_s).span()));
    auto dot = lookup(cborText(emptyString()));
    ASSERT_TRUE(dot.has_value());
    EXPECT_TRUE(std::ranges::equal(*dot, cborText("."_s).span()));
    auto b = lookup(cborText("b"_s));
    ASSERT_TRUE(b.has_value());
    EXPECT_TRUE(std::ranges::equal(*b, cborText("B"_s).span()));
    auto aa = lookup(cborText("aa"_s));
    ASSERT_TRUE(aa.has_value());
    EXPECT_TRUE(std::ranges::equal(*aa, cborText("AA"_s).span()));
}

TEST(CBORReaderTest, TestReadMapWithIntegerKeys)
{
    static const Vector<uint8_t> kMapWithIntegerKeyCBOR = {
        0xA4, // map with 4 key value pairs
        0x01, // key : 1
        0x61, 0x61, // value : "a"

        0x09, // key : 9
        0x61, 0x62, // value : "b"

        0x19, 0x03, 0xE7, // key : 999
        0x61, 0x63, // value "c"

        0x19, 0x04, 0x57, // key : 1111
        0x61, 0x64, // value : "d"
    };

    expectReadsAsItself(kMapWithIntegerKeyCBOR);
}

TEST(CBORReaderTest, TestReadMapWithArray)
{
    static const Vector<uint8_t> kMapArrayTestCaseCBOR = {
        0xa2, // map of 2 pairs
        0x61, 0x61, // "a"
        0x01,

        0x61, 0x62, // "b"
        0x82, // array with 2 elements
        0x02,
        0x03,
    };

    expectReadsAsItself(kMapArrayTestCaseCBOR);
}

TEST(CBORReaderTest, TestReadNestedMap)
{
    static const Vector<uint8_t> kNestedMapTestCase = {
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

    expectReadsAsItself(kNestedMapTestCase);
}

TEST(CBORReaderTest, TestIntegerRange)
{
    static const Vector<uint8_t> kMaxPositiveInt = {
        0x1b, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    };
    static const Vector<uint8_t> kMinNegativeInt = {
        0x3b, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    };

    expectReadsAsItself(kMaxPositiveInt);
    expectReadsAsItself(kMinNegativeInt);
}

TEST(CBORReaderTest, TestIntegerOutOfRangeError)
{
    static const Vector<uint8_t> kOutOfRangePositiveInt = {
        0x1b, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };

    static const Vector<uint8_t> kOutOfRangeNegativeInt = {
        0x3b, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };

    expectReadError(kOutOfRangePositiveInt, DecoderError::OutOfRangeIntegerValue);
    expectReadError(kOutOfRangeNegativeInt, DecoderError::OutOfRangeIntegerValue);
}

TEST(CBORReaderTest, TestReadSimpleValue)
{
    static const Vector<uint8_t> kSimpleValueTestCases[] = {
        { 0xf4 }, // false
        { 0xf5 }, // true
        { 0xf6 }, // null
        { 0xf7 }, // undefined
    };

    for (const auto& cborData : kSimpleValueTestCases)
        expectReadsAsItself(cborData);
}

TEST(CBORReaderTest, TestReadUnsupportedFloatingPointNumbers)
{
    static const Vector<uint8_t> floatingPointCbors[] = {
        // 16 bit floating point value.
        { 0xf9, 0x10, 0x00 },
        // 32 bit floating point value.
        { 0xfa, 0x10, 0x00, 0x00, 0x00 },
        // 64 bit floating point value.
        { 0xfb, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }
    };

    for (const auto& unsupportedFloatingPoint : floatingPointCbors)
        expectReadError(unsupportedFloatingPoint, DecoderError::UnsupportedFloatingPointValue);
}

TEST(CBORReaderTest, TestIncompleteCBORDataError)
{
    static const Vector<uint8_t> incompleteCborList[] = {
        // Additional info byte corresponds to unsigned int that corresponds
        // to 2 additional bytes. But actual data encoded  in one byte.
        { 0x19, 0x03 },
        // CBOR bytestring of length 3 encoded with additional info of length 4.
        { 0x44, 0x01, 0x02, 0x03 },
        // CBOR string data "IETF" of length 4 encoded with additional info of
        // length 5.
        { 0x65, 0x49, 0x45, 0x54, 0x46 },
        // CBOR array of length 1 encoded with additional info of length 2.
        { 0x82, 0x02 },
        // CBOR map with single key value pair encoded with additional info of
        // length 2.
        { 0xa2, 0x61, 0x61, 0x01 },
    };

    for (const auto& incompleteData : incompleteCborList)
        expectReadError(incompleteData, DecoderError::IncompleteCBORData);
}

// While RFC 7049 allows CBOR map keys with all types, current decoder only
// supports unsigned integer and string keys.
TEST(CBORReaderTest, TestUnsupportedMapKeyFormatError)
{
    static const Vector<uint8_t> kMapWithUintKey = {
        0xa2, // map of 2 pairs

        0x82, 0x01, 0x02, // invalid key : [1, 2]
        0x02, // value : 2

        0x61, 0x64, // key : "d"
        0x03, // value : 3
    };

    expectReadError(kMapWithUintKey, DecoderError::IncorrectMapKeyType);
}

TEST(CBORReaderTest, TestUnknownAdditionalInfoError)
{
    static const Vector<uint8_t> kUnknownAdditionalInfoList[] = {
        // "IETF" encoded with major type 3 and additional info of 28.
        { 0x7C, 0x49, 0x45, 0x54, 0x46 },
        // "\"\\" encoded with major type 3 and additional info of 29.
        { 0x7D, 0x22, 0x5c },
        // "\xc3\xbc" encoded with major type 3 and additional info of 30.
        { 0x7E, 0xc3, 0xbc },
        // "\xe6\xb0\xb4" encoded with major type 3 and additional info of 31.
        { 0x7F, 0xe6, 0xb0, 0xb4 },
        // Major type 7, additional information 28: unassigned.
        { 0xFC },
        // Major type 7, additional information 29: unassigned.
        { 0xFD },
        // Major type 7, additional information 30: unassigned.
        { 0xFE },
        // Major type 7, additional information 31: "break" stop code for
        // indefinite-length items.
        { 0xFF },
    };

    for (const auto& incorrectCbor : kUnknownAdditionalInfoList)
        expectReadError(incorrectCbor, DecoderError::UnknownAdditionalInfo);
}

TEST(CBORReaderTest, TestTooMuchNestingError)
{
    static const Vector<uint8_t> kZeroDepthCBORList[] = {
        // Unsigned int with value 100.
        { 0x18, 0x64 },
        // CBOR bytestring of length 4.
        { 0x44, 0x01, 0x02, 0x03, 0x04 },
        // CBOR string of corresponding to "IETF.
        { 0x64, 0x49, 0x45, 0x54, 0x46 },
        // Empty CBOR array.
        { 0x80 },
        // Empty CBOR Map
        { 0xa0 },
    };

    for (const auto& zeroDepthData : kZeroDepthCBORList)
        expectReadsAsItself(zeroDepthData, 0);

    // Corresponds to a CBOR structure with a nesting depth of 2:
    //      {"a": 1,
    //       "b": [2, 3]}
    static const Vector<uint8_t> kNestedCBORData = {
        0xa2, // map of 2 pairs
        0x61, 0x61, // "a"
        0x01,

        0x61, 0x62, // "b"
        0x82, // array with 2 elements
        0x02,
        0x03,
    };

    expectReadError(kNestedCBORData, DecoderError::TooMuchNesting, 1);
    expectReadsAsItself(kNestedCBORData, 2);
}

TEST(CBORReaderTest, TestOutOfOrderKeyError)
{
    static const Vector<uint8_t> kMapsWithUnsortedKeys[] = {
        {0xa2, // map with 2 keys with same major type and length
            0x61, 0x62, // key "b"
            0x61, 0x42, // value :"B"

            0x61, 0x61, // key "a" (out of order byte-wise lexically)
            0x61, 0x45, // value "E"
        },
        {0xa2, // map with 2 keys with different major type
            0x61, 0x62, // key "b"
            0x02, // value 2

            // key 1000 (out of order since lower major type sorts first)
            0x19, 0x03, 0xe8,
            0x61, 0x61, // value a
        },
        {0xa2, // map with 2 keys with same major type
            0x19, 0x03, 0xe8, // key 1000  (out of order due to longer length)
            0x61, 0x61, // value "a"

            0x0a, // key 10
            0x61, 0x62}, // value "b"
    };

    for (const auto& unsortedMap : kMapsWithUnsortedKeys)
        expectReadError(unsortedMap, DecoderError::OutOfOrderKey);
}

TEST(CBORReaderTest, TestDuplicateKeyError)
{
    static const Vector<uint8_t> kMapWithDuplicateKey = {
        0xa6, // map of 6 pairs:
        0x60, // ""
        0x61, 0x2e, // "."

        0x61, 0x62, // "b"
        0x61, 0x42, // "B"

        0x61, 0x62, // "b" (Duplicate key)
        0x61, 0x43, // "C"

        0x61, 0x64, // "d"
        0x61, 0x44, // "D"

        0x61, 0x65, // "e"
        0x61, 0x44, // "D"

        0x62, 0x61, 0x61, // "aa"
        0x62, 0x41, 0x41, // "AA"
    };

    expectReadError(kMapWithDuplicateKey, DecoderError::DuplicateKey);
}


// A key equal to an earlier, not adjacent, key is also out of order: the duplicate check comes first, for integer and
// text keys.
TEST(CBORReaderTest, TestDuplicateKeyBeforeOutOfOrderKey)
{
    static const Vector<uint8_t> kIntegerKeys = {
        0xa3, // map of 3 pairs:
        0x01, 0x60, // 1: ""
        0x02, 0x60, // 2: ""
        0x01, 0x60, // 1: "" (duplicate of the first key, and out of order)
    };
    static const Vector<uint8_t> kTextKeys = {
        0xa3, // map of 3 pairs:
        0x61, 0x61, 0x00, // "a": 0
        0x61, 0x62, 0x00, // "b": 0
        0x61, 0x61, 0x00, // "a": 0 (duplicate of the first key, and out of order)
    };
    static const Vector<uint8_t> kOutOfOrderOnly = {
        0xa3, // map of 3 pairs:
        0x61, 0x61, 0x00, // "a": 0
        0x61, 0x63, 0x00, // "c": 0
        0x61, 0x62, 0x00, // "b": 0 (out of order, not a duplicate)
    };

    expectReadError(kIntegerKeys, DecoderError::DuplicateKey);
    expectReadError(kTextKeys, DecoderError::DuplicateKey);
    expectReadError(kOutOfOrderOnly, DecoderError::OutOfOrderKey);
}

// Leveraging Markus Kuhn’s UTF-8 decoder stress test. See
// http://www.cl.cam.ac.uk/~mgk25/ucs/examples/UTF-8-test.txt for details.
TEST(CBORReaderTest, TestIncorrectStringEncodingError)
{
    static const Vector<uint8_t> utf8CharacterEncodings[] = {
        // Corresponds to utf8 encoding of "퟿" (section 2.3.1 of stress test).
        { 0x63, 0xED, 0x9F, 0xBF },
        // Corresponds to utf8 encoding of "" (section 2.3.2 of stress test).
        { 0x63, 0xEE, 0x80, 0x80 },
        // Corresponds to utf8 encoding of "�"  (section 2.3.3 of stress test).
        { 0x63, 0xEF, 0xBF, 0xBD },
    };

    for (const auto& correctlyEncoded : utf8CharacterEncodings)
        expectReadsAsItself(correctlyEncoded);

    // Incorrect UTF8 encoding referenced by section 3.5.3 of the stress test.
    expectReadError({ 0x64, 0xfe, 0xfe, 0xff, 0xff }, DecoderError::InvalidUTF8);
}

TEST(CBORReaderTest, TestExtraneousCBORDataError)
{
    static const Vector<uint8_t> zeroPaddedCborList[] = {
        // 1 extra byte after a 2-byte unsigned int.
        { 0x19, 0x03, 0x05, 0x00 },
        // 1 extra byte after a 4-byte cbor byte array.
        { 0x44, 0x01, 0x02, 0x03, 0x04, 0x00 },
        // 1 extra byte after a 4-byte string.
        { 0x64, 0x49, 0x45, 0x54, 0x46, 0x00 },
        // 1 extra byte after CBOR array of length 2.
        { 0x82, 0x01, 0x02, 0x00 },
        // 1 extra key value pair after CBOR map of size 2.
        { 0xa1, 0x61, 0x63, 0x02, 0x61, 0x64, 0x03 },
    };

    for (const auto& extraneousCborData : zeroPaddedCborList)
        expectReadError(extraneousCborData, DecoderError::ExtraneousData);
}

TEST(CBORReaderTest, TestUnsupportedSimplevalue)
{
    static const Vector<uint8_t> unsupportedSimpleValues[] = {
        // Simple value (0, unassigned)
        { 0xE0 },
        // Simple value (19, unassigned)
        { 0xF3 },
        // Simple value (24, reserved)
        { 0xF8, 0x18 },
        // Simple value (28, reserved)
        { 0xF8, 0x1C },
        // Simple value (29, reserved)
        { 0xF8, 0x1D },
        // Simple value (30, reserved)
        { 0xF8, 0x1E },
        // Simple value (31, reserved)
        { 0xF8, 0x1F },
        // Simple value (32, unassigned)
        { 0xF8, 0x20 },
        // Simple value (255, unassigned)
        { 0xF8, 0xFF },
    };

    for (const auto& unsupportedSimpleValue : unsupportedSimpleValues)
        expectReadError(unsupportedSimpleValue, DecoderError::UnsupportedSimpleValue);
}

TEST(CBORReaderTest, TestReadWithTrailingData)
{
    static const Vector<uint8_t> kItemAndTrailingByte = { 0x82, 0x01, 0x02, 0x00 };
    auto result = readCanonical(kItemAndTrailingByte.span(), kCBORMaxDepth, true);
    EXPECT_TRUE(result.error == DecoderError::CBORNoError);
    EXPECT_EQ(result.bytesConsumed, 3u);
    Vector<uint8_t> expected { 0x82, 0x01, 0x02 };
    EXPECT_TRUE(result.canonical == expected);
}

TEST(CBORReaderTest, AuthExtensionsFromCBOR_CredPropsWithoutRk)
{
    // CBOR encoding of {"credProps": {}} — credProps map present but no "rk" key.
    // a1                          -- map(1)
    //    69                       -- text(9)
    //       63726564 50726f7073   -- "credProps"
    //    a0                       -- map(0)
    Vector<uint8_t> cborData { 0xa1, 0x69, 0x63, 0x72, 0x65, 0x64, 0x50, 0x72, 0x6f, 0x70, 0x73, 0xa0 };
    auto result = WebCore::AuthenticationExtensionsClientOutputs::fromCBOR(cborData);
    ASSERT_TRUE(result.has_value());
    ASSERT_TRUE(result->credProps.has_value());
    EXPECT_FALSE(result->credProps->rk);
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
