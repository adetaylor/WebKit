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

#if ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)

#include "Helpers/Test.h"
#include <WebCore/AudioSampleBufferList.h>
#include <array>
#include <limits>

using namespace WebCore;

namespace TestWebKitAPI {

namespace {

template<typename T, size_t BufferCount, size_t SampleCount>
struct TestBufferList {
    explicit TestBufferList(const std::array<std::array<T, SampleCount>, BufferCount>& initial)
        : samples(initial)
    {
        storage.list.mNumberBuffers = BufferCount;
        auto buffers = unsafeMakeSpan(storage.list.mBuffers, BufferCount);
        for (size_t i = 0; i < BufferCount; ++i) {
            buffers[i].mNumberChannels = 1;
            buffers[i].mDataByteSize = sizeof(T) * SampleCount;
            buffers[i].mData = samples[i].data();
        }
    }

    AudioBufferList& audioBufferList() { return storage.list; }

    std::array<std::array<T, SampleCount>, BufferCount> samples;
    union {
        AudioBufferList list;
        std::array<uint8_t, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * BufferCount> bytes;
    } storage;
};

}

TEST(AudioSampleBufferList, ApplyGainToInt16SamplesKeepsTheLowBitsOfTheSaturatedProduct)
{
    TestBufferList<int16_t, 2, 5> buffers({ { { 1000, -1000, 30000, -30000, 0 }, { 1, 2, 3, 4, 5 } } });
    AudioSampleBufferList::applyGain(buffers.audioBufferList(), 2, AudioStreamDescription::Int16);
    EXPECT_EQ(buffers.samples[0], (std::array<int16_t, 5> { 2000, -2000, -5536, 5536, 0 }));
    EXPECT_EQ(buffers.samples[1], (std::array<int16_t, 5> { 2, 4, 6, 8, 10 }));

    AudioSampleBufferList::applyGain(buffers.audioBufferList(), 1e30, AudioStreamDescription::Int16);
    EXPECT_EQ(buffers.samples[0], (std::array<int16_t, 5> { -1, 0, 0, -1, 0 }));
    AudioSampleBufferList::applyGain(buffers.audioBufferList(), std::numeric_limits<float>::quiet_NaN(), AudioStreamDescription::Int16);
    EXPECT_EQ(buffers.samples[1], (std::array<int16_t, 5> { 0, 0, 0, 0, 0 }));
}

TEST(AudioSampleBufferList, ApplyGainToInt32SamplesSaturates)
{
    TestBufferList<int32_t, 1, 4> buffers({ { { 2'000'000'000, -2'000'000'000, 7, 0 } } });
    AudioSampleBufferList::applyGain(buffers.audioBufferList(), 2, AudioStreamDescription::Int32);
    EXPECT_EQ(buffers.samples[0], (std::array<int32_t, 4> { std::numeric_limits<int32_t>::max(), std::numeric_limits<int32_t>::min(), 14, 0 }));
    AudioSampleBufferList::applyGain(buffers.audioBufferList(), std::numeric_limits<float>::quiet_NaN(), AudioStreamDescription::Int32);
    EXPECT_EQ(buffers.samples[0], (std::array<int32_t, 4> { 0, 0, 0, 0 }));
}

TEST(AudioSampleBufferList, ApplyGainToFloatSamples)
{
    TestBufferList<float, 2, 3> buffers({ { { 1, -0.5, 0.25 }, { 2, 4, 8 } } });
    AudioSampleBufferList::applyGain(buffers.audioBufferList(), 0.5, AudioStreamDescription::Float32);
    EXPECT_EQ(buffers.samples[0], (std::array<float, 3> { 0.5, -0.25, 0.125 }));
    EXPECT_EQ(buffers.samples[1], (std::array<float, 3> { 1, 2, 4 }));

    TestBufferList<double, 1, 2> doubles({ { { 3, -6 } } });
    AudioSampleBufferList::applyGain(doubles.audioBufferList(), 0.5, AudioStreamDescription::Float64);
    EXPECT_EQ(doubles.samples[0], (std::array<double, 2> { 1.5, -3 }));
}

TEST(AudioSampleBufferList, MixBuffersAddsAsManyBuffersAsBothListsHave)
{
    TestBufferList<int16_t, 2, 3> destination({ { { 30000, 1, 2 }, { 10, 20, 30 } } });
    TestBufferList<int16_t, 1, 3> source({ { { 30000, 1, 2 } } });
    AudioSampleBufferList::mixBuffers(destination.audioBufferList(), source.audioBufferList(), AudioStreamDescription::Int16, 2);
    EXPECT_EQ(destination.samples[0], (std::array<int16_t, 3> { -5536, 2, 2 }));
    EXPECT_EQ(destination.samples[1], (std::array<int16_t, 3> { 10, 20, 30 }));

    TestBufferList<float, 1, 2> floatDestination({ { { 1, 2 } } });
    TestBufferList<float, 1, 2> floatSource({ { { 0.5, 0.25 } } });
    AudioSampleBufferList::mixBuffers(floatDestination.audioBufferList(), floatSource.audioBufferList(), AudioStreamDescription::Float32, 2);
    EXPECT_EQ(floatDestination.samples[0], (std::array<float, 2> { 1.5, 2.25 }));
}

TEST(AudioSampleBufferList, ZeroABLZeroesTheStartOfEveryBuffer)
{
    TestBufferList<uint8_t, 3, 4> buffers({ { { 1, 2, 3, 4 }, { 5, 6, 7, 8 }, { 9, 10, 11, 12 } } });
    AudioSampleBufferList::zeroABL(buffers.audioBufferList(), 3);
    EXPECT_EQ(buffers.samples[0], (std::array<uint8_t, 4> { 0, 0, 0, 4 }));
    EXPECT_EQ(buffers.samples[1], (std::array<uint8_t, 4> { 0, 0, 0, 8 }));
    EXPECT_EQ(buffers.samples[2], (std::array<uint8_t, 4> { 0, 0, 0, 12 }));
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)
