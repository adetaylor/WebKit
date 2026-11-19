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

#include "Decoder.h"
#include "Encoder.h"
#include "SwiftCoding.h"
#include "Helpers/Test.h"
#include <limits>
#include <type_traits>
#include <wtf/StdLibExtras.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

using IPC::Decoder;
using IPC::SwiftDecoder;
using IPC::LentBytesPosition;

static constexpr uint8_t marker = 0x5A;
static constexpr size_t headerSize = 16;
static constexpr uint64_t hugeCounts[] = {
    1ull << 32,
    (1ull << 32) + 1,
    1ull << 61,
    (1ull << 61) + 1,
    1ull << 62,
    (1ull << 62) + 1,
    1ull << 63,
    (1ull << 63) + 1,
    std::numeric_limits<uint64_t>::max() / 8 + 1,
    std::numeric_limits<uint64_t>::max() / 4 + 1,
    std::numeric_limits<uint64_t>::max() / 2 + 1,
    std::numeric_limits<uint64_t>::max() - 1,
    std::numeric_limits<uint64_t>::max(),
};

template<typename Encode>
static Vector<uint8_t> encodedMessage(Encode&& encode)
{
    IPC::Encoder encoder(IPC::MessageName::IPCTester_EmptyMessage, 0);
    encode(encoder);
    return Vector<uint8_t>(encoder.span());
}

static std::unique_ptr<Decoder> decoderFor(std::span<const uint8_t> message)
{
    return Decoder::create(message, { });
}

static void encodePrefix(IPC::Encoder& encoder, size_t prefix)
{
    for (size_t index = 0; index < prefix; ++index)
        encoder << static_cast<uint8_t>(0xC0 + index);
}

template<typename Check>
static void forEachPrefix(Check&& check)
{
    for (size_t prefix = 0; prefix < 9; ++prefix) {
        SCOPED_TRACE(testing::Message() << "prefix of " << prefix << " bytes");
        check(prefix);
    }
}

template<typename Visitor>
static void forEachElementType(Visitor&& visit)
{
    visit(std::type_identity<uint8_t> { });
    visit(std::type_identity<uint16_t> { });
    visit(std::type_identity<uint32_t> { });
    visit(std::type_identity<uint64_t> { });
    visit(std::type_identity<int8_t> { });
    visit(std::type_identity<int16_t> { });
    visit(std::type_identity<int32_t> { });
    visit(std::type_identity<int64_t> { });
    visit(std::type_identity<float> { });
    visit(std::type_identity<double> { });
}

template<typename T>
static Vector<T> makeValues(size_t count)
{
    Vector<T> values;
    for (size_t index = 0; index < count; ++index)
        values.append(static_cast<T>((index + 1) * 37 % 113 + 1));
    return values;
}

static bool decodeOne(SwiftDecoder& decoder, uint8_t& value) { return decoder.decodeUInt8(value); }
static bool decodeOne(SwiftDecoder& decoder, uint16_t& value) { return decoder.decodeUInt16(value); }
static bool decodeOne(SwiftDecoder& decoder, uint32_t& value) { return decoder.decodeUInt32(value); }
static bool decodeOne(SwiftDecoder& decoder, uint64_t& value) { return decoder.decodeUInt64(value); }
static bool decodeOne(SwiftDecoder& decoder, int8_t& value) { return decoder.decodeInt8(value); }
static bool decodeOne(SwiftDecoder& decoder, int16_t& value) { return decoder.decodeInt16(value); }
static bool decodeOne(SwiftDecoder& decoder, int32_t& value) { return decoder.decodeInt32(value); }
static bool decodeOne(SwiftDecoder& decoder, int64_t& value) { return decoder.decodeInt64(value); }
static bool decodeOne(SwiftDecoder& decoder, float& value) { return decoder.decodeFloat(value); }
static bool decodeOne(SwiftDecoder& decoder, double& value) { return decoder.decodeDouble(value); }

static bool decodeMany(SwiftDecoder& decoder, std::span<uint8_t> values) { return decoder.decodeUInt8s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<uint16_t> values) { return decoder.decodeUInt16s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<uint32_t> values) { return decoder.decodeUInt32s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<uint64_t> values) { return decoder.decodeUInt64s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<int8_t> values) { return decoder.decodeInt8s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<int16_t> values) { return decoder.decodeInt16s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<int32_t> values) { return decoder.decodeInt32s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<int64_t> values) { return decoder.decodeInt64s(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<float> values) { return decoder.decodeFloats(values); }
static bool decodeMany(SwiftDecoder& decoder, std::span<double> values) { return decoder.decodeDoubles(values); }

enum class ArrayForm { OneBlock, ElementByElement };

// Decodes a Vector as generated Swift does: its count, a check of the count against what is left of the message, and then
// its elements, in one call or one at a time.
template<typename T>
static std::optional<Vector<T>> swiftDecodeVector(SwiftDecoder& decoder, ArrayForm form)
{
    uint64_t count = 0;
    if (!decoder.decodeUInt64(count))
        return std::nullopt;
    if (!count)
        return Vector<T> { };
    if (count > decoder.remainingByteCount() / sizeof(T)) {
        decoder.markInvalid();
        return std::nullopt;
    }
    Vector<T> values(count);
    if (form == ArrayForm::OneBlock) {
        if (!decodeMany(decoder, values.mutableSpan()))
            return std::nullopt;
        return values;
    }
    if (!decoder.beginArray(count, sizeof(T)))
        return std::nullopt;
    for (auto& value : values.mutableSpan()) {
        if (!decodeOne(decoder, value))
            return std::nullopt;
    }
    return values;
}

template<typename T>
using DecodedVector = std::optional<std::pair<Vector<T>, uint8_t>>;

template<typename T>
static DecodedVector<T> cxxDecodeVector(Decoder& decoder, size_t prefix)
{
    for (size_t index = 0; index < prefix; ++index) {
        if (!decoder.decode<uint8_t>())
            return std::nullopt;
    }
    auto values = decoder.decode<Vector<T>>();
    if (!values)
        return std::nullopt;
    auto tail = decoder.decode<uint8_t>();
    if (!tail)
        return std::nullopt;
    return std::make_pair(WTF::move(*values), *tail);
}

template<typename T>
static DecodedVector<T> swiftDecodeVectorWithTail(SwiftDecoder& decoder, size_t prefix, ArrayForm form)
{
    for (size_t index = 0; index < prefix; ++index) {
        uint8_t byte;
        if (!decoder.decodeUInt8(byte))
            return std::nullopt;
    }
    auto values = swiftDecodeVector<T>(decoder, form);
    if (!values)
        return std::nullopt;
    uint8_t tail;
    if (!decoder.decodeUInt8(tail))
        return std::nullopt;
    return std::make_pair(WTF::move(*values), tail);
}

// Swift and C++ must accept or reject the message alike, decode the same values if they accept it, and leave the decoder
// invalid if they reject it.
template<typename T>
static void expectSwiftDecodesVectorAsCxx(std::span<const uint8_t> message, size_t prefix)
{
    auto cxxDecoder = decoderFor(message);
    ASSERT_TRUE(cxxDecoder);
    auto cxx = cxxDecodeVector<T>(*cxxDecoder, prefix);
    EXPECT_EQ(!!cxx, cxxDecoder->isValid());

    for (auto form : { ArrayForm::OneBlock, ArrayForm::ElementByElement }) {
        auto swiftMessageDecoder = decoderFor(message);
        ASSERT_TRUE(swiftMessageDecoder);
        NonEscapableBorrowLender<SwiftDecoder> lender { *swiftMessageDecoder };
        auto swift = swiftDecodeVectorWithTail<T>(lender.view(), prefix, form);
        EXPECT_EQ(!!cxx, !!swift);
        EXPECT_EQ(!!swift, lender.view().isValid());
        if (cxx && swift) {
            EXPECT_EQ(cxx->first, swift->first);
            EXPECT_EQ(cxx->second, swift->second);
        }
    }
}

template<typename T>
static Vector<uint8_t> vectorMessage(size_t prefix, const Vector<T>& values)
{
    return encodedMessage([&](IPC::Encoder& encoder) {
        encodePrefix(encoder, prefix);
        encoder << values;
        encoder << marker;
    });
}

TEST(SwiftCodingEdgeCases, VectorsOfEveryLengthAndAlignmentDecodeAsInCxx)
{
    forEachElementType([&]<typename T>(std::type_identity<T>) {
        SCOPED_TRACE(testing::Message() << "element of " << sizeof(T) << " bytes");
        for (size_t count : { 0, 1, 2, 3, 5, 8, 17 }) {
            SCOPED_TRACE(testing::Message() << count << " elements");
            forEachPrefix([&](size_t prefix) {
                auto message = vectorMessage(prefix, makeValues<T>(count));
                auto cxxDecoder = decoderFor(message.span());
                ASSERT_TRUE(cxxDecoder);
                auto cxx = cxxDecodeVector<T>(*cxxDecoder, prefix);
                ASSERT_TRUE(cxx);
                EXPECT_EQ(cxx->first, makeValues<T>(count));
                expectSwiftDecodesVectorAsCxx<T>(message.span(), prefix);
            });
        }
    });
}

TEST(SwiftCodingEdgeCases, EmptyVectorsAddNoPaddingAsInCxx)
{
    forEachElementType([&]<typename T>(std::type_identity<T>) {
        SCOPED_TRACE(testing::Message() << "element of " << sizeof(T) << " bytes");
        forEachPrefix([&](size_t prefix) {
            auto withEmpty = vectorMessage(prefix, Vector<T> { });
            auto without = encodedMessage([&](IPC::Encoder& encoder) {
                encodePrefix(encoder, prefix);
                encoder << static_cast<uint64_t>(0);
                encoder << marker;
            });
            EXPECT_EQ(withEmpty, without);
        });
    });
}

TEST(SwiftCodingEdgeCases, TruncatedVectorsAreRejectedAsInCxx)
{
    forEachElementType([&]<typename T>(std::type_identity<T>) {
        SCOPED_TRACE(testing::Message() << "element of " << sizeof(T) << " bytes");
        for (size_t count : { 0, 1, 3, 6 }) {
            SCOPED_TRACE(testing::Message() << count << " elements");
            forEachPrefix([&](size_t prefix) {
                auto message = vectorMessage(prefix, makeValues<T>(count));
                for (size_t cut = 1; cut <= message.size() - headerSize; ++cut) {
                    SCOPED_TRACE(testing::Message() << "cut by " << cut << " bytes");
                    auto truncated = message.span().first(message.size() - cut);
                    expectSwiftDecodesVectorAsCxx<T>(truncated, prefix);
                    auto cxxDecoder = decoderFor(truncated);
                    ASSERT_TRUE(cxxDecoder);
                    EXPECT_FALSE(cxxDecodeVector<T>(*cxxDecoder, prefix));
                }
            });
        }
    });
}

TEST(SwiftCodingEdgeCases, VectorsClaimingMoreThanTheMessageHasAreRejectedAsInCxx)
{
    forEachElementType([&]<typename T>(std::type_identity<T>) {
        SCOPED_TRACE(testing::Message() << "element of " << sizeof(T) << " bytes");
        for (uint64_t count : { 1ull, 2ull, 3ull, 100ull, 1ull << 20 }) {
            SCOPED_TRACE(testing::Message() << "a claim of " << count << " elements");
            forEachPrefix([&](size_t prefix) {
                auto message = encodedMessage([&](IPC::Encoder& encoder) {
                    encodePrefix(encoder, prefix);
                    encoder << count;
                    encoder.encodeSpan(makeValues<T>(1).span());
                });
                auto cxxDecoder = decoderFor(message.span());
                ASSERT_TRUE(cxxDecoder);
                if (count > 1)
                    EXPECT_FALSE(cxxDecodeVector<T>(*cxxDecoder, prefix));
                expectSwiftDecodesVectorAsCxx<T>(message.span(), prefix);
            });
        }
    });
}

TEST(SwiftCodingEdgeCases, HugeVectorCountsAreRejectedAsInCxx)
{
    forEachElementType([&]<typename T>(std::type_identity<T>) {
        SCOPED_TRACE(testing::Message() << "element of " << sizeof(T) << " bytes");
        uint64_t wrapsToOneElement = std::numeric_limits<uint64_t>::max() / sizeof(T) + 2;
        auto counts = Vector<uint64_t>(std::span<const uint64_t> { hugeCounts });
        if (sizeof(T) > 1)
            counts.append(wrapsToOneElement);
        for (uint64_t count : counts) {
            SCOPED_TRACE(testing::Message() << "a claim of " << count << " elements");
            forEachPrefix([&](size_t prefix) {
                auto message = encodedMessage([&](IPC::Encoder& encoder) {
                    encodePrefix(encoder, prefix);
                    encoder << count;
                    encoder.encodeSpan(makeValues<T>(4).span());
                    encoder << marker;
                });
                auto cxxDecoder = decoderFor(message.span());
                ASSERT_TRUE(cxxDecoder);
                EXPECT_FALSE(cxxDecodeVector<T>(*cxxDecoder, prefix));
                expectSwiftDecodesVectorAsCxx<T>(message.span(), prefix);
            });
        }
    });
}

TEST(SwiftCodingEdgeCases, BeginArrayRejectsWhatCountTimesSizeOverflows)
{
    for (size_t elementSize : { 1, 2, 4, 8 }) {
        SCOPED_TRACE(testing::Message() << "element of " << elementSize << " bytes");
        auto counts = Vector<uint64_t>(std::span<const uint64_t> { hugeCounts });
        if (elementSize > 1)
            counts.append(std::numeric_limits<uint64_t>::max() / elementSize + 1);
        counts.append(std::numeric_limits<uint64_t>::max() / elementSize);
        for (uint64_t count : counts) {
            SCOPED_TRACE(testing::Message() << "a claim of " << count << " elements");
            auto message = encodedMessage([&](IPC::Encoder& encoder) {
                encoder << static_cast<uint64_t>(0) << static_cast<uint64_t>(0);
            });
            auto decoder = decoderFor(message.span());
            ASSERT_TRUE(decoder);
            NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
            EXPECT_FALSE(lender.view().beginArray(count, elementSize));
            EXPECT_FALSE(lender.view().isValid());
        }
    }
}

TEST(SwiftCodingEdgeCases, BeginArrayAlignsAsDecodeSpanDoes)
{
    for (size_t elementSize : { 1, 2, 4, 8 }) {
        SCOPED_TRACE(testing::Message() << "element of " << elementSize << " bytes");
        for (size_t count : { 0, 1, 2 }) {
            SCOPED_TRACE(testing::Message() << count << " elements");
            forEachPrefix([&](size_t prefix) {
                auto message = encodedMessage([&](IPC::Encoder& encoder) {
                    encodePrefix(encoder, prefix);
                    switch (elementSize) {
                    case 1:
                        encoder.encodeSpan(makeValues<uint8_t>(count).span());
                        break;
                    case 2:
                        encoder.encodeSpan(makeValues<uint16_t>(count).span());
                        break;
                    case 4:
                        encoder.encodeSpan(makeValues<uint32_t>(count).span());
                        break;
                    default:
                        encoder.encodeSpan(makeValues<uint64_t>(count).span());
                        break;
                    }
                    encoder << marker;
                });
                auto cxxDecoder = decoderFor(message.span());
                ASSERT_TRUE(cxxDecoder);
                for (size_t index = 0; index < prefix; ++index)
                    ASSERT_TRUE(cxxDecoder->decode<uint8_t>());
                switch (elementSize) {
                case 1:
                    ASSERT_TRUE(cxxDecoder->decodeSpan<uint8_t>(count).data());
                    break;
                case 2:
                    ASSERT_TRUE(cxxDecoder->decodeSpan<uint16_t>(count).data());
                    break;
                case 4:
                    ASSERT_TRUE(cxxDecoder->decodeSpan<uint32_t>(count).data());
                    break;
                default:
                    ASSERT_TRUE(cxxDecoder->decodeSpan<uint64_t>(count).data());
                    break;
                }
                auto cxxMarker = cxxDecoder->decode<uint8_t>();

                auto swiftMessageDecoder = decoderFor(message.span());
                ASSERT_TRUE(swiftMessageDecoder);
                NonEscapableBorrowLender<SwiftDecoder> lender { *swiftMessageDecoder };
                for (size_t index = 0; index < prefix; ++index) {
                    uint8_t byte;
                    ASSERT_TRUE(lender.view().decodeUInt8(byte));
                }
                ASSERT_TRUE(lender.view().beginArray(count, elementSize));
                for (size_t element = 0; element < count; ++element) {
                    uint64_t value;
                    switch (elementSize) {
                    case 1: {
                        uint8_t narrow;
                        ASSERT_TRUE(lender.view().decodeUInt8(narrow));
                        break;
                    }
                    case 2: {
                        uint16_t narrow;
                        ASSERT_TRUE(lender.view().decodeUInt16(narrow));
                        break;
                    }
                    case 4: {
                        uint32_t narrow;
                        ASSERT_TRUE(lender.view().decodeUInt32(narrow));
                        break;
                    }
                    default:
                        ASSERT_TRUE(lender.view().decodeUInt64(value));
                        break;
                    }
                }
                uint8_t swiftMarker;
                ASSERT_TRUE(lender.view().decodeUInt8(swiftMarker));
                ASSERT_TRUE(cxxMarker);
                EXPECT_EQ(*cxxMarker, swiftMarker);
                EXPECT_EQ(marker, swiftMarker);
            });
        }
    }
}

TEST(SwiftCodingEdgeCases, BeginArrayRejectsAnElementSizeThatIsNotAnIntegerSize)
{
    auto message = encodedMessage([&](IPC::Encoder& encoder) {
        encoder << static_cast<uint64_t>(0);
    });
    for (size_t elementSize : { 0, 3, 5, 6, 7, 16 }) {
        auto decoder = decoderFor(message.span());
        ASSERT_TRUE(decoder);
        NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
        EXPECT_FALSE(lender.view().beginArray(0, elementSize));
        EXPECT_FALSE(lender.view().isValid());
    }
}

TEST(SwiftCodingEdgeCases, DecodeBytesAsAnArrayOfElementsAsInCxx)
{
    for (size_t alignment : { 1, 2, 4, 8 }) {
        SCOPED_TRACE(testing::Message() << "alignment " << alignment);
        for (size_t elementCount : { 0, 1, 3, 7 }) {
            SCOPED_TRACE(testing::Message() << elementCount << " elements");
            forEachPrefix([&](size_t prefix) {
                size_t byteCount = elementCount * alignment;
                auto bytes = makeValues<uint8_t>(byteCount);
                auto message = encodedMessage([&](IPC::Encoder& encoder) {
                    encodePrefix(encoder, prefix);
                    switch (alignment) {
                    case 1:
                        encoder.encodeSpan(std::span<const uint8_t> { bytes.span() });
                        break;
                    case 2:
                        encoder.encodeSpan(std::span<const uint16_t> { makeValues<uint16_t>(elementCount).span() });
                        break;
                    case 4:
                        encoder.encodeSpan(std::span<const uint32_t> { makeValues<uint32_t>(elementCount).span() });
                        break;
                    default:
                        encoder.encodeSpan(std::span<const uint64_t> { makeValues<uint64_t>(elementCount).span() });
                        break;
                    }
                    encoder << marker;
                });

                Vector<uint8_t> expected;
                switch (alignment) {
                case 1:
                    expected = bytes;
                    break;
                case 2:
                    expected = Vector<uint8_t>(asByteSpan(makeValues<uint16_t>(elementCount).span()));
                    break;
                case 4:
                    expected = Vector<uint8_t>(asByteSpan(makeValues<uint32_t>(elementCount).span()));
                    break;
                default:
                    expected = Vector<uint8_t>(asByteSpan(makeValues<uint64_t>(elementCount).span()));
                    break;
                }

                auto decoder = decoderFor(message.span());
                ASSERT_TRUE(decoder);
                NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
                for (size_t index = 0; index < prefix; ++index) {
                    uint8_t byte;
                    ASSERT_TRUE(lender.view().decodeUInt8(byte));
                }
                Vector<uint8_t> decoded(byteCount);
                ASSERT_TRUE(lender.view().decodeBytes(decoded.mutableSpan(), alignment));
                EXPECT_EQ(decoded, expected);
                uint8_t tail;
                ASSERT_TRUE(lender.view().decodeUInt8(tail));
                EXPECT_EQ(marker, tail);
            });
        }
    }
}

TEST(SwiftCodingEdgeCases, DecodeBytesRejectsWhatItCannotDecodeAndInvalidatesTheMessage)
{
    auto message = encodedMessage([&](IPC::Encoder& encoder) {
        encoder << static_cast<uint64_t>(1) << static_cast<uint64_t>(2) << static_cast<uint64_t>(3);
    });
    auto expectRejected = [&](size_t byteCount, size_t alignment) {
        SCOPED_TRACE(testing::Message() << byteCount << " bytes of alignment " << alignment);
        auto decoder = decoderFor(message.span());
        ASSERT_TRUE(decoder);
        NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
        Vector<uint8_t> destination(byteCount);
        EXPECT_FALSE(lender.view().decodeBytes(destination.mutableSpan(), alignment));
        EXPECT_FALSE(lender.view().isValid());
    };
    expectRejected(25, 1);
    expectRejected(4, 8);
    expectRejected(3, 2);
    expectRejected(6, 4);
    expectRejected(8, 3);
    expectRejected(8, 0);
    expectRejected(16, 16);
    expectRejected(25, 8);
}

struct DecodedLentBytes {
    Vector<uint8_t> bytes;
    bool dataIsNull { false };
    std::optional<ptrdiff_t> offsetInMessage;
    std::optional<uint32_t> tail;
    size_t size { 0 };
};

static std::optional<DecodedLentBytes> cxxDecodeBytes(Decoder& decoder, size_t prefix, bool hasTail)
{
    for (size_t index = 0; index < prefix; ++index) {
        if (!decoder.decode<uint8_t>())
            return std::nullopt;
    }
    auto bytes = decoder.decode<std::span<const uint8_t>>();
    if (!bytes)
        return std::nullopt;
    DecodedLentBytes result;
    result.bytes = Vector<uint8_t>(*bytes);
    result.size = bytes->size();
    result.dataIsNull = !bytes->data();
    if (bytes->data())
        result.offsetInMessage = bytes->data() - decoder.span().data();
    if (hasTail) {
        auto tail = decoder.decode<uint32_t>();
        if (!tail)
            return std::nullopt;
        result.tail = *tail;
    }
    return result;
}

static std::optional<DecodedLentBytes> swiftDecodeBytes(SwiftDecoder& decoder, size_t prefix, bool hasTail, LentBytesPosition& position, Decoder& messageDecoder)
{
    for (size_t index = 0; index < prefix; ++index) {
        uint8_t byte;
        if (!decoder.decodeUInt8(byte))
            return std::nullopt;
    }
    if (!decoder.decodeLentBytesPosition(position))
        return std::nullopt;
    DecodedLentBytes result;
    if (hasTail) {
        uint32_t tail;
        if (!decoder.decodeUInt32(tail))
            return std::nullopt;
        result.tail = tail;
    }
    auto lent = decoder.lentBytes(position);
    auto span = lent.span();
    result.bytes = Vector<uint8_t>(span);
    result.size = lent.size();
    result.dataIsNull = !span.data();
    if (span.data())
        result.offsetInMessage = span.data() - messageDecoder.span().data();

    Vector<uint8_t> copy(lent.size());
    lent.copyTo(copy.mutableSpan());
    EXPECT_EQ(copy, result.bytes);
    for (size_t index = 0; index < lent.size(); ++index)
        EXPECT_EQ(lent.byteAt(index), result.bytes[index]);
    return result;
}

static void expectLentBytesDecodeAsInCxx(std::span<const uint8_t> message, size_t prefix, bool hasTail, LentBytesPosition& position)
{
    auto cxxDecoder = decoderFor(message);
    ASSERT_TRUE(cxxDecoder);
    auto cxx = cxxDecodeBytes(*cxxDecoder, prefix, hasTail);
    EXPECT_EQ(!!cxx, cxxDecoder->isValid());

    auto swiftMessageDecoder = decoderFor(message);
    ASSERT_TRUE(swiftMessageDecoder);
    auto& messageDecoder = *swiftMessageDecoder;
    NonEscapableBorrowLender<SwiftDecoder> lender { messageDecoder };
    auto swift = swiftDecodeBytes(lender.view(), prefix, hasTail, position, messageDecoder);
    EXPECT_EQ(!!cxx, !!swift);
    EXPECT_EQ(!!swift, lender.view().isValid());
    if (!cxx || !swift)
        return;
    EXPECT_EQ(cxx->bytes, swift->bytes);
    EXPECT_EQ(cxx->size, swift->size);
    EXPECT_EQ(cxx->dataIsNull, swift->dataIsNull);
    EXPECT_EQ(cxx->offsetInMessage, swift->offsetInMessage);
    EXPECT_EQ(cxx->tail, swift->tail);
}

static Vector<uint8_t> bytesMessage(size_t prefix, size_t byteCount, bool hasTail)
{
    return encodedMessage([&](IPC::Encoder& encoder) {
        encodePrefix(encoder, prefix);
        encoder << makeValues<uint8_t>(byteCount).span();
        if (hasTail)
            encoder << static_cast<uint32_t>(0x01020304);
    });
}

TEST(SwiftCodingEdgeCases, LentEmptyBytesHaveNoDataAsInCxx)
{
    for (bool hasTail : { false, true }) {
        forEachPrefix([&](size_t prefix) {
            auto message = bytesMessage(prefix, 0, hasTail);
            auto cxxDecoder = decoderFor(message.span());
            ASSERT_TRUE(cxxDecoder);
            auto cxx = cxxDecodeBytes(*cxxDecoder, prefix, hasTail);
            ASSERT_TRUE(cxx);
            EXPECT_TRUE(cxx->dataIsNull);
            EXPECT_EQ(0u, cxx->size);

            LentBytesPosition position;
            expectLentBytesDecodeAsInCxx(message.span(), prefix, hasTail, position);

            auto swiftMessageDecoder = decoderFor(message.span());
            ASSERT_TRUE(swiftMessageDecoder);
            NonEscapableBorrowLender<SwiftDecoder> lender { *swiftMessageDecoder };
            auto swift = swiftDecodeBytes(lender.view(), prefix, hasTail, position, *swiftMessageDecoder);
            ASSERT_TRUE(swift);
            EXPECT_TRUE(swift->dataIsNull);
            EXPECT_EQ(0u, swift->size);
        });
    }
}

TEST(SwiftCodingEdgeCases, LentBytesAreInTheMessageAsInCxx)
{
    for (bool hasTail : { false, true }) {
        for (size_t byteCount : { 1, 2, 7, 8, 9, 100 }) {
            SCOPED_TRACE(testing::Message() << byteCount << " bytes");
            forEachPrefix([&](size_t prefix) {
                auto message = bytesMessage(prefix, byteCount, hasTail);
                LentBytesPosition position;
                expectLentBytesDecodeAsInCxx(message.span(), prefix, hasTail, position);

                auto swiftMessageDecoder = decoderFor(message.span());
                ASSERT_TRUE(swiftMessageDecoder);
                NonEscapableBorrowLender<SwiftDecoder> lender { *swiftMessageDecoder };
                auto swift = swiftDecodeBytes(lender.view(), prefix, hasTail, position, *swiftMessageDecoder);
                ASSERT_TRUE(swift);
                EXPECT_FALSE(swift->dataIsNull);
                EXPECT_EQ(makeValues<uint8_t>(byteCount), swift->bytes);
            });
        }
    }
}

TEST(SwiftCodingEdgeCases, TruncatedLentBytesAreRejectedAsInCxx)
{
    for (bool hasTail : { false, true }) {
        for (size_t byteCount : { 0, 1, 5, 16 }) {
            SCOPED_TRACE(testing::Message() << byteCount << " bytes");
            forEachPrefix([&](size_t prefix) {
                auto message = bytesMessage(prefix, byteCount, hasTail);
                for (size_t cut = 1; cut <= message.size() - headerSize; ++cut) {
                    SCOPED_TRACE(testing::Message() << "cut by " << cut << " bytes");
                    LentBytesPosition position;
                    expectLentBytesDecodeAsInCxx(message.span().first(message.size() - cut), prefix, hasTail, position);
                    auto cxxDecoder = decoderFor(message.span().first(message.size() - cut));
                    ASSERT_TRUE(cxxDecoder);
                    EXPECT_FALSE(cxxDecodeBytes(*cxxDecoder, prefix, hasTail));
                }
            });
        }
    }
}

TEST(SwiftCodingEdgeCases, LentBytesOfHugeCountsAreRejectedAsInCxx)
{
    auto counts = Vector<uint64_t>(std::span<const uint64_t> { hugeCounts });
    counts.appendList({ 2, 1000 });
    for (uint64_t count : counts) {
        SCOPED_TRACE(testing::Message() << "a claim of " << count << " bytes");
        forEachPrefix([&](size_t prefix) {
            auto message = encodedMessage([&](IPC::Encoder& encoder) {
                encodePrefix(encoder, prefix);
                encoder << count;
                encoder.encodeSpan(makeValues<uint8_t>(1).span());
            });
            LentBytesPosition position;
            expectLentBytesDecodeAsInCxx(message.span(), prefix, false, position);
            auto cxxDecoder = decoderFor(message.span());
            ASSERT_TRUE(cxxDecoder);
            EXPECT_FALSE(cxxDecodeBytes(*cxxDecoder, prefix, false));
        });
    }
}

TEST(SwiftCodingEdgeCases, ReusedLentBytesPositionLeavesNoStaleBytes)
{
    LentBytesPosition position;
    Vector<uint8_t> storage;
    for (size_t byteCount : { 100, 0, 3, 64, 1, 0, 9 }) {
        SCOPED_TRACE(testing::Message() << byteCount << " bytes");
        auto message = bytesMessage(1, byteCount, true);
        auto decoder = decoderFor(message.span());
        ASSERT_TRUE(decoder);
        NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
        auto swift = swiftDecodeBytes(lender.view(), 1, true, position, *decoder);
        ASSERT_TRUE(swift);
        EXPECT_EQ(byteCount, swift->size);
        EXPECT_EQ(!byteCount, swift->dataIsNull);
        EXPECT_EQ(makeValues<uint8_t>(byteCount), swift->bytes);
        EXPECT_EQ(0x01020304u, swift->tail);

        auto lent = lender.view().lentBytes(position);
        storage.resize(lent.size());
        lent.copyTo(storage.mutableSpan());
        EXPECT_EQ(makeValues<uint8_t>(byteCount), storage);
    }
}

static std::string utf8Of(const String& string)
{
    auto utf8 = string.utf8();
    return std::string(reinterpret_cast<const char*>(utf8.span().data()), utf8.span().size());
}

static Vector<uint8_t> latin1Message(size_t prefix, std::span<const Latin1Character> characters)
{
    return encodedMessage([&](IPC::Encoder& encoder) {
        encodePrefix(encoder, prefix);
        encoder << static_cast<uint32_t>(characters.size()) << true;
        encoder.encodeSpan(characters);
        encoder << marker;
    });
}

static Vector<uint8_t> utf16Message(size_t prefix, std::span<const char16_t> characters)
{
    return encodedMessage([&](IPC::Encoder& encoder) {
        encodePrefix(encoder, prefix);
        encoder << static_cast<uint32_t>(characters.size()) << false;
        encoder.encodeSpan(characters);
        encoder << marker;
    });
}

// Decodes a String's text as generated Swift does into utf8, which a caller may reuse for each message: the whole span.
static std::optional<std::string> swiftDecodeStringText(SwiftDecoder& decoder, size_t prefix, std::span<uint8_t> utf8, uint8_t& tail)
{
    for (size_t index = 0; index < prefix; ++index) {
        uint8_t byte;
        if (!decoder.decodeUInt8(byte))
            return std::nullopt;
    }
    uint32_t length;
    bool is8Bit;
    if (!decoder.decodeUInt32(length) || !decoder.decodeBool(is8Bit))
        return std::nullopt;
    size_t utf8Length = 0;
    if (is8Bit ? !decoder.decodeLatin1Characters(length, utf8, utf8Length) : !decoder.decodeUTF16Characters(length, utf8, utf8Length))
        return std::nullopt;
    if (!decoder.decodeUInt8(tail))
        return std::nullopt;
    return std::string(reinterpret_cast<const char*>(utf8.data()), utf8Length);
}

TEST(SwiftCodingEdgeCases, StringTextDecodedIntoReusedStorageHasNoStaleBytes)
{
    Vector<Latin1Character> longLatin1;
    for (size_t index = 0; index < 40; ++index)
        longLatin1.append(static_cast<Latin1Character>(0x41 + index));
    Vector<Latin1Character> accentedLatin1 { static_cast<Latin1Character>(0xE9), static_cast<Latin1Character>('z'), static_cast<Latin1Character>(0xFF) };
    Vector<char16_t> longUTF16;
    for (size_t index = 0; index < 40; ++index)
        longUTF16.append(static_cast<char16_t>(0x4E00 + index));
    Vector<char16_t> shortUTF16 { 0x20AC, 0xD83D, 0xDE00, 'a' };

    Vector<uint8_t> storage(FillWith { }, 3 * 40, static_cast<uint8_t>(0xEE));
    forEachPrefix([&](size_t prefix) {
        for (auto& message : {
            latin1Message(prefix, longLatin1.span()),
            latin1Message(prefix, accentedLatin1.span()),
            latin1Message(prefix, { }),
            utf16Message(prefix, longUTF16.span()),
            utf16Message(prefix, shortUTF16.span()),
            utf16Message(prefix, { }),
            latin1Message(prefix, accentedLatin1.span().first(1)),
        }) {
            auto cxxDecoder = decoderFor(message.span());
            ASSERT_TRUE(cxxDecoder);
            for (size_t index = 0; index < prefix; ++index)
                ASSERT_TRUE(cxxDecoder->decode<uint8_t>());
            auto cxx = cxxDecoder->decode<String>();
            ASSERT_TRUE(cxx);

            auto decoder = decoderFor(message.span());
            ASSERT_TRUE(decoder);
            NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
            uint8_t tail = 0;
            auto swift = swiftDecodeStringText(lender.view(), prefix, storage.mutableSpan(), tail);
            ASSERT_TRUE(swift);
            EXPECT_EQ(utf8Of(*cxx), *swift);
            EXPECT_EQ(marker, tail);
        }
    });
}

TEST(SwiftCodingEdgeCases, StringTextOfAHugeLengthIsRejected)
{
    Vector<uint8_t> storage(FillWith { }, 64, static_cast<uint8_t>(0));
    for (bool is8Bit : { true, false }) {
        for (uint32_t length : { 33u, 1000u, 1u << 30, 0xFFFFFFFEu }) {
            SCOPED_TRACE(testing::Message() << length << " characters, 8 bit: " << is8Bit);
            forEachPrefix([&](size_t prefix) {
                auto message = encodedMessage([&](IPC::Encoder& encoder) {
                    encodePrefix(encoder, prefix);
                    encoder << length << is8Bit;
                    encoder << marker;
                });
                auto cxxDecoder = decoderFor(message.span());
                ASSERT_TRUE(cxxDecoder);
                for (size_t index = 0; index < prefix; ++index)
                    ASSERT_TRUE(cxxDecoder->decode<uint8_t>());
                EXPECT_FALSE(cxxDecoder->decode<String>());

                auto decoder = decoderFor(message.span());
                ASSERT_TRUE(decoder);
                NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
                uint8_t tail = 0;
                EXPECT_FALSE(swiftDecodeStringText(lender.view(), prefix, storage.mutableSpan(), tail));
                EXPECT_FALSE(lender.view().isValid());
            });
        }
    }
}

TEST(SwiftCodingEdgeCases, StringTextOfHugeCountsIsRejectedWithoutOverreadingOrOverflowing)
{
    Vector<uint8_t> storage(FillWith { }, 64, static_cast<uint8_t>(0));
    auto message = encodedMessage([&](IPC::Encoder& encoder) {
        encoder << static_cast<uint64_t>(0) << static_cast<uint64_t>(0);
    });
    for (uint64_t count : hugeCounts) {
        SCOPED_TRACE(testing::Message() << count << " characters");
        {
            auto decoder = decoderFor(message.span());
            ASSERT_TRUE(decoder);
            NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
            size_t utf8Length = 0;
            EXPECT_FALSE(lender.view().decodeLatin1Characters(count, storage.mutableSpan(), utf8Length));
            EXPECT_FALSE(lender.view().isValid());
        }
        {
            auto decoder = decoderFor(message.span());
            ASSERT_TRUE(decoder);
            NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
            size_t utf8Length = 0;
            EXPECT_FALSE(lender.view().decodeUTF16Characters(count, storage.mutableSpan(), utf8Length));
            EXPECT_FALSE(lender.view().isValid());
        }
    }
}

TEST(SwiftCodingEdgeCases, ArraysDecodedIntoReusedStorageTouchOnlyTheirCount)
{
    constexpr uint32_t sentinel = 0xDEADBEEF;
    Vector<uint32_t> storage(FillWith { }, 16, sentinel);
    for (size_t count : { 12, 3, 0, 7, 1, 16 }) {
        SCOPED_TRACE(testing::Message() << count << " elements");
        forEachPrefix([&](size_t prefix) {
            auto message = vectorMessage(prefix, makeValues<uint32_t>(count));
            auto decoder = decoderFor(message.span());
            ASSERT_TRUE(decoder);
            NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
            for (size_t index = 0; index < prefix; ++index) {
                uint8_t byte;
                ASSERT_TRUE(lender.view().decodeUInt8(byte));
            }
            uint64_t claimed;
            ASSERT_TRUE(lender.view().decodeUInt64(claimed));
            ASSERT_EQ(count, claimed);

            storage.fill(sentinel);
            ASSERT_TRUE(lender.view().decodeUInt32s(storage.mutableSpan().first(count)));
            auto expected = makeValues<uint32_t>(count);
            for (size_t index = 0; index < storage.size(); ++index)
                EXPECT_EQ(index < count ? expected[index] : sentinel, storage[index]) << "at " << index;
            uint8_t tail;
            ASSERT_TRUE(lender.view().decodeUInt8(tail));
            EXPECT_EQ(marker, tail);
        });
    }
}

TEST(SwiftCodingEdgeCases, ArraysThatFailToDecodeLeaveNoPartialValuesAfterTheCount)
{
    Vector<uint32_t> storage(FillWith { }, 8, static_cast<uint32_t>(0));
    auto message = vectorMessage(0, makeValues<uint32_t>(2));
    for (size_t cut = 1; cut <= 9; ++cut) {
        SCOPED_TRACE(testing::Message() << "cut by " << cut << " bytes");
        auto decoder = decoderFor(message.span().first(message.size() - cut));
        ASSERT_TRUE(decoder);
        NonEscapableBorrowLender<SwiftDecoder> lender { *decoder };
        uint64_t claimed;
        ASSERT_TRUE(lender.view().decodeUInt64(claimed));
        storage.fill(0);
        bool decoded = lender.view().decodeUInt32s(storage.mutableSpan().first(claimed));
        if (decoded) {
            uint8_t tail;
            EXPECT_FALSE(lender.view().decodeUInt8(tail));
        }
        EXPECT_FALSE(lender.view().isValid());
        for (size_t index = claimed; index < storage.size(); ++index)
            EXPECT_EQ(0u, storage[index]);
    }
}

} // namespace TestWebKitAPI
