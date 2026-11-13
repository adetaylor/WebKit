/*
 * Copyright (C) 2025-2026 Apple Inc. All rights reserved.
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

#import "config.h"

#import "Helpers/Utilities.h"
#import <CoreVideo/CoreVideo.h>
#import <WebCore/SharedVideoFrameInfo.h>
#include <algorithm>
#include <tuple>
#include <wtf/Vector.h>

#if USE(LIBWEBRTC)
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN
#include <webrtc/api/video/i010_buffer.h>
#include <webrtc/api/video/i420_buffer.h>
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END
#endif

namespace TestWebKitAPI {

TEST(SharedVideoFrame, PlaneAlphaSize)
{
    Vector<uint8_t> data(128);
    WebCore::SharedVideoFrameInfo info {
        'v0a8', 1, 2, 1, 1, 1, 1, 1
    };
    info.encode(data.mutableSpan());
    EXPECT_EQ(info.storageSize(), 45u);

    auto info2 = WebCore::SharedVideoFrameInfo::decode(data.span());
    EXPECT_TRUE(info2);
    EXPECT_EQ(info2->storageSize(), 45u);

    data[28] = 2;

    info2 = WebCore::SharedVideoFrameInfo::decode(data.span());
    EXPECT_TRUE(info2);
    EXPECT_EQ(info2->storageSize(), 47u);

    info2 = WebCore::SharedVideoFrameInfo::decode(data.span().subspan(0, 28));
    EXPECT_FALSE(info2);
}

static RetainPtr<CVPixelBufferRef> createPatternPixelBuffer(OSType format, size_t width, size_t height)
{
    CVPixelBufferRef rawBuffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nullptr, &rawBuffer) != kCVReturnSuccess)
        return nullptr;
    RetainPtr buffer = adoptCF(rawBuffer);
    CVPixelBufferLockBaseAddress(rawBuffer, 0);
    size_t planeCount = CVPixelBufferGetPlaneCount(rawBuffer);
    for (size_t plane = 0; plane < std::max<size_t>(planeCount, 1); ++plane) {
        auto* base = static_cast<uint8_t*>(planeCount ? CVPixelBufferGetBaseAddressOfPlane(rawBuffer, plane) : CVPixelBufferGetBaseAddress(rawBuffer));
        size_t bytesPerRow = planeCount ? CVPixelBufferGetBytesPerRowOfPlane(rawBuffer, plane) : CVPixelBufferGetBytesPerRow(rawBuffer);
        size_t rows = planeCount ? CVPixelBufferGetHeightOfPlane(rawBuffer, plane) : CVPixelBufferGetHeight(rawBuffer);
        auto bytes = unsafeMakeSpan(base, bytesPerRow * rows);
        for (size_t i = 0; i < bytes.size(); ++i)
            bytes[i] = static_cast<uint8_t>(plane * 37 + (i / bytesPerRow) * 7 + i % bytesPerRow);
    }
    CVPixelBufferUnlockBaseAddress(rawBuffer, 0);
    return buffer;
}

static void expectSamePlanes(CVPixelBufferRef expected, CVPixelBufferRef actual)
{
    EXPECT_EQ(CVPixelBufferGetPixelFormatType(expected), CVPixelBufferGetPixelFormatType(actual));
    size_t planeCount = CVPixelBufferGetPlaneCount(expected);
    EXPECT_EQ(planeCount, CVPixelBufferGetPlaneCount(actual));
    CVPixelBufferLockBaseAddress(expected, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(actual, kCVPixelBufferLock_ReadOnly);
    for (size_t plane = 0; plane < std::max<size_t>(planeCount, 1); ++plane) {
        auto planeSpan = [&](CVPixelBufferRef buffer) {
            auto* base = static_cast<const uint8_t*>(planeCount ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane) : CVPixelBufferGetBaseAddress(buffer));
            size_t bytesPerRow = planeCount ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) : CVPixelBufferGetBytesPerRow(buffer);
            size_t rows = planeCount ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer);
            return std::tuple { unsafeMakeSpan(base, bytesPerRow * rows), bytesPerRow, rows };
        };
        auto [expectedBytes, expectedBytesPerRow, expectedRows] = planeSpan(expected);
        auto [actualBytes, actualBytesPerRow, actualRows] = planeSpan(actual);
        EXPECT_EQ(expectedRows, actualRows);
        size_t rowBytes = std::min(expectedBytesPerRow, actualBytesPerRow);
        for (size_t row = 0; row < std::min(expectedRows, actualRows); ++row) {
            auto expectedRow = expectedBytes.subspan(row * expectedBytesPerRow, rowBytes);
            auto actualRow = actualBytes.subspan(row * actualBytesPerRow, rowBytes);
            EXPECT_TRUE(std::ranges::equal(expectedRow, actualRow)) << "plane " << plane << " row " << row;
        }
    }
    CVPixelBufferUnlockBaseAddress(actual, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(expected, kCVPixelBufferLock_ReadOnly);
}

// What SharedVideoFrameWriter writes into shared memory and SharedVideoFrameReader reads back.
static void testPixelBufferRoundTrip(OSType format, size_t width, size_t height)
{
    auto source = createPatternPixelBuffer(format, width, height);
    ASSERT_TRUE(source);
    auto info = WebCore::SharedVideoFrameInfo::fromCVPixelBuffer(source.get());
    EXPECT_TRUE(info.isReadWriteSupported());
    EXPECT_EQ(info.bufferType(), format);
    EXPECT_EQ(info.width(), width);
    EXPECT_EQ(info.height(), height);

    Vector<uint8_t> storage(info.storageSize());
    EXPECT_TRUE(info.writePixelBuffer(source.get(), storage.mutableSpan()));

    auto decoded = WebCore::SharedVideoFrameInfo::decode(storage.span());
    ASSERT_TRUE(decoded);
    EXPECT_EQ(decoded->storageSize(), info.storageSize());
    auto result = decoded->createPixelBufferFromMemory(storage.span().subspan(WebCore::SharedVideoFrameInfoEncodingLength));
    ASSERT_TRUE(result);
    EXPECT_EQ(CVPixelBufferGetWidth(result.get()), width);
    EXPECT_EQ(CVPixelBufferGetHeight(result.get()), height);
    expectSamePlanes(source.get(), result.get());
}

TEST(SharedVideoFrame, PixelBufferRoundTripBGRA)
{
    testPixelBufferRoundTrip(kCVPixelFormatType_32BGRA, 33, 17);
}

TEST(SharedVideoFrame, PixelBufferRoundTripARGB)
{
    testPixelBufferRoundTrip(kCVPixelFormatType_32ARGB, 33, 17);
}

TEST(SharedVideoFrame, PixelBufferRoundTripNV12)
{
    testPixelBufferRoundTrip(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 33, 17);
    testPixelBufferRoundTrip(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 640, 480);
}

TEST(SharedVideoFrame, PixelBufferRoundTrip10Bit)
{
    testPixelBufferRoundTrip(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 33, 17);
    testPixelBufferRoundTrip(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 34, 18);
}

TEST(SharedVideoFrame, PixelBufferRoundTripWithAlpha)
{
    testPixelBufferRoundTrip(kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar, 33, 17);
}

// The reader zero-fills destination row padding.
TEST(SharedVideoFrame, RowPaddingIsZeroed)
{
    Vector<uint8_t> storage(WebCore::SharedVideoFrameInfoEncodingLength + 16 * 2);
    storage.fill(0xAB);
    WebCore::SharedVideoFrameInfo { kCVPixelFormatType_32BGRA, 4, 2, 16 }.encode(storage.mutableSpan());
    auto info = WebCore::SharedVideoFrameInfo::decode(storage.span());
    ASSERT_TRUE(info);
    auto result = info->createPixelBufferFromMemory(storage.span().subspan(WebCore::SharedVideoFrameInfoEncodingLength));
    ASSERT_TRUE(result);
    CVPixelBufferLockBaseAddress(result.get(), kCVPixelBufferLock_ReadOnly);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(result.get());
    auto bytes = unsafeMakeSpan(static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(result.get())), bytesPerRow * 2);
    for (size_t i = 0; i < bytes.size(); ++i)
        EXPECT_EQ(bytes[i], i % bytesPerRow < 16 ? 0xAB : 0) << i;
    CVPixelBufferUnlockBaseAddress(result.get(), kCVPixelBufferLock_ReadOnly);
}

static RetainPtr<CVPixelBufferRef> createPixelBufferFromHeader(WebCore::SharedVideoFrameInfo header, size_t planeByteCount)
{
    Vector<uint8_t> storage(WebCore::SharedVideoFrameInfoEncodingLength + planeByteCount);
    header.encode(storage.mutableSpan());
    auto info = WebCore::SharedVideoFrameInfo::decode(storage.span());
    EXPECT_TRUE(info);
    if (!info)
        return nullptr;
    return info->createPixelBufferFromMemory(storage.span().subspan(WebCore::SharedVideoFrameInfoEncodingLength));
}

// The reader creates no pixel buffer for a frame whose encoded planes can't fill all of its pixels.
TEST(SharedVideoFrame, FramesTheStorageCannotFillAreRejected)
{
    constexpr uint32_t maximumDimension = 1 << 15;

    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, 4, 2, 15 }, 15 * 2));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, 4, 2, 16 }, 16 * 2 - 1));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, 1 << 20, 1 << 20, 0 }, 0));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, maximumDimension, maximumDimension, 0 }, 0));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, maximumDimension + 1, 1, (maximumDimension + 1) * 4 }, (maximumDimension + 1) * 4));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, 1, maximumDimension + 1, 4 }, (maximumDimension + 1) * 4));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 5, 5, 4, 3, 3, 6 }, 4 * 5 + 6 * 3));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 5, 5, 5, 3, 2, 6 }, 5 * 5 + 6 * 2));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 5, 5, 5, 3, 3, 5 }, 5 * 5 + 5 * 3));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 5, 5, 10, 3, 3, 11 }, 10 * 5 + 11 * 3));
    EXPECT_FALSE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar, 5, 5, 5, 3, 3, 6, 4 }, 5 * 5 + 6 * 3 + 4 * 5));

    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, 4, 2, 16 }, 16 * 2));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_32ARGB, maximumDimension, 1, maximumDimension * 4 }, maximumDimension * 4));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_32BGRA, 1, maximumDimension, 4 }, maximumDimension * 4));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 5, 5, 5, 3, 3, 6 }, 5 * 5 + 6 * 3));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 5, 5, 5, 3, 4, 6 }, 5 * 5 + 6 * 4));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 5, 5, 10, 3, 3, 12 }, 10 * 5 + 12 * 3));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 5, 5, 10, 3, 3, 12 }, 10 * 5 + 12 * 3));
    EXPECT_TRUE(createPixelBufferFromHeader({ kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar, 5, 5, 5, 3, 3, 6, 5 }, 5 * 5 + 6 * 3 + 5 * 5));
}

// Storage one byte too short fails both the write and the read.
TEST(SharedVideoFrame, ShortStorageFails)
{
    auto source = createPatternPixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 33, 17);
    ASSERT_TRUE(source);
    auto info = WebCore::SharedVideoFrameInfo::fromCVPixelBuffer(source.get());
    Vector<uint8_t> storage(info.storageSize() - 1);
    EXPECT_FALSE(info.writePixelBuffer(source.get(), storage.mutableSpan()));

    Vector<uint8_t> complete(info.storageSize());
    EXPECT_TRUE(info.writePixelBuffer(source.get(), complete.mutableSpan()));
    auto decoded = WebCore::SharedVideoFrameInfo::decode(complete.span());
    ASSERT_TRUE(decoded);
    EXPECT_FALSE(decoded->createPixelBufferFromMemory(complete.span().subspan(WebCore::SharedVideoFrameInfoEncodingLength, complete.size() - WebCore::SharedVideoFrameInfoEncodingLength - 1)));
}

#if USE(LIBWEBRTC)

template<typename SampleType, typename Buffer>
static void testSharedVideoFrameInfoRoundTrip(Buffer& buffer)
{
    static_assert(sizeof(SampleType) == 1 || sizeof(SampleType) == 2);

    const int width = buffer.width();
    const int height = buffer.height();
    const int chromaWidth = (width + 1) / 2;
    const int chromaHeight = (height + 1) / 2;

    // I420 stores 8-bit samples; I010 stores 10-bit samples in uint16_t.
    constexpr unsigned valueMask = sizeof(SampleType) == 1 ? 0xFFu : 0x3FFu;
    constexpr unsigned msbShift = sizeof(SampleType) == 1 ? 0u : 6u;

    auto fillPlane = [&](std::span<SampleType> plane, int stride, int planeWidth, int planeHeight, unsigned seed) {
        for (int y = 0; y < planeHeight; ++y) {
            auto row = plane.subspan(y * stride, planeWidth);
            for (int x = 0; x < planeWidth; ++x)
                row[x] = static_cast<SampleType>((seed + 31u * y + 7u * x) & valueMask);
        }
    };
    fillPlane(unsafeMakeSpan(buffer.MutableDataY(), buffer.StrideY() * height), buffer.StrideY(), width, height, 1);
    fillPlane(unsafeMakeSpan(buffer.MutableDataU(), buffer.StrideU() * chromaHeight), buffer.StrideU(), chromaWidth, chromaHeight, 101);
    fillPlane(unsafeMakeSpan(buffer.MutableDataV(), buffer.StrideV() * chromaHeight), buffer.StrideV(), chromaWidth, chromaHeight, 211);

    auto info = WebCore::SharedVideoFrameInfo::fromVideoFrameBuffer(buffer);
    EXPECT_GT(info.storageSize(), 0u);

    constexpr size_t guardSize = 64;
    constexpr uint8_t guardByte = 0xCD;

    Vector<uint8_t> storage(info.storageSize() + guardSize);
    auto allBytes = storage.mutableSpan();
    auto frameBytes = allBytes.subspan(0, info.storageSize());
    auto guardBytes = allBytes.subspan(info.storageSize());
    for (auto& b : guardBytes)
        b = guardByte;

    EXPECT_TRUE(info.writeVideoFrameBuffer(buffer, frameBytes));

    for (auto byte : guardBytes)
        EXPECT_EQ(byte, guardByte);

    auto payload = spanReinterpretCast<const SampleType>(frameBytes.subspan(sizeof(WebCore::SharedVideoFrameInfo)));
    const int outStrideY = width;
    const int outStrideUV = (width & 1) ? width + 1 : width;
    auto outY = payload.first(outStrideY * height);
    auto outUV = payload.subspan(outStrideY * height, outStrideUV * chromaHeight);

    auto srcY = unsafeMakeSpan(buffer.DataY(), buffer.StrideY() * height);
    auto srcU = unsafeMakeSpan(buffer.DataU(), buffer.StrideU() * chromaHeight);
    auto srcV = unsafeMakeSpan(buffer.DataV(), buffer.StrideV() * chromaHeight);

    for (int y = 0; y < height; ++y) {
        auto srcRow = srcY.subspan(y * buffer.StrideY(), width);
        auto outRow = outY.subspan(y * outStrideY, width);
        for (int x = 0; x < width; ++x) {
            auto expected = static_cast<SampleType>(static_cast<uint32_t>(srcRow[x]) << msbShift);
            EXPECT_EQ(outRow[x], expected) << "Y mismatch at (" << x << ", " << y << ")";
        }
    }

    for (int y = 0; y < chromaHeight; ++y) {
        auto srcURow = srcU.subspan(y * buffer.StrideU(), chromaWidth);
        auto srcVRow = srcV.subspan(y * buffer.StrideV(), chromaWidth);
        auto outRow = outUV.subspan(y * outStrideUV, 2 * chromaWidth);
        for (int x = 0; x < chromaWidth; ++x) {
            auto expectedU = static_cast<SampleType>(static_cast<uint32_t>(srcURow[x]) << msbShift);
            auto expectedV = static_cast<SampleType>(static_cast<uint32_t>(srcVRow[x]) << msbShift);
            EXPECT_EQ(outRow[2 * x], expectedU) << "U mismatch at (" << x << ", " << y << ")";
            EXPECT_EQ(outRow[2 * x + 1], expectedV) << "V mismatch at (" << x << ", " << y << ")";
        }
    }
}

TEST(SharedVideoFrame, OddWidthI420)
{
    auto buffer = webrtc::I420Buffer::Create(681, 1280);
    ASSERT_TRUE(buffer);
    testSharedVideoFrameInfoRoundTrip<uint8_t>(*buffer);
}

TEST(SharedVideoFrame, OddHeightI420)
{
    auto buffer = webrtc::I420Buffer::Create(680, 15);
    ASSERT_TRUE(buffer);
    testSharedVideoFrameInfoRoundTrip<uint8_t>(*buffer);
}

TEST(SharedVideoFrame, OddWidthAndHeightI420)
{
    auto buffer = webrtc::I420Buffer::Create(681, 15);
    ASSERT_TRUE(buffer);
    testSharedVideoFrameInfoRoundTrip<uint8_t>(*buffer);
}

TEST(SharedVideoFrame, OddWidthI010)
{
    auto buffer = webrtc::I010Buffer::Create(681, 1280);
    ASSERT_TRUE(buffer);
    testSharedVideoFrameInfoRoundTrip<uint16_t>(*buffer);
}

TEST(SharedVideoFrame, OddHeightI010)
{
    auto buffer = webrtc::I010Buffer::Create(680, 15);
    ASSERT_TRUE(buffer);
    testSharedVideoFrameInfoRoundTrip<uint16_t>(*buffer);
}

TEST(SharedVideoFrame, OddWidthAndHeightI010)
{
    auto buffer = webrtc::I010Buffer::Create(681, 15);
    ASSERT_TRUE(buffer);
    testSharedVideoFrameInfoRoundTrip<uint16_t>(*buffer);
}

#endif // USE(LIBWEBRTC)

}; // namespace TestWebKitAPI
