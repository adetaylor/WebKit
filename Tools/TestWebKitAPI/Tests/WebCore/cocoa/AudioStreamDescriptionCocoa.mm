/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#if PLATFORM(COCOA)
#import "Helpers/Test.h"
#import <WebCore/CAAudioStreamDescription.h>
#import <WebCore/WebAudioBufferList.h>
#import <limits>

namespace {

template<typename T> inline constexpr AudioFormatFlags formatFlag = 0;
template<> inline constexpr AudioFormatFlags formatFlag<float> = kAudioFormatFlagIsFloat;
template<> inline constexpr AudioFormatFlags formatFlag<double> = kAudioFormatFlagIsFloat;
template<> inline constexpr AudioFormatFlags formatFlag<int32_t> = kAudioFormatFlagIsSignedInteger;
template<> inline constexpr AudioFormatFlags formatFlag<int16_t> = kAudioFormatFlagIsSignedInteger;

template<typename T> inline constexpr WebCore::AudioStreamDescription::PCMFormat pcmFormat = WebCore::AudioStreamDescription::None;
template<> inline constexpr WebCore::AudioStreamDescription::PCMFormat pcmFormat<float> = WebCore::AudioStreamDescription::Float32;
template<> inline constexpr WebCore::AudioStreamDescription::PCMFormat pcmFormat<double> = WebCore::AudioStreamDescription::Float64;
template<> inline constexpr WebCore::AudioStreamDescription::PCMFormat pcmFormat<int16_t> = WebCore::AudioStreamDescription::Int16;
template<> inline constexpr WebCore::AudioStreamDescription::PCMFormat pcmFormat<int32_t> = WebCore::AudioStreamDescription::Int32;

template<typename T> AudioStreamBasicDescription createASBD(uint32_t numChannels = 1)
{
    AudioStreamBasicDescription asbd { };
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mSampleRate = 44000;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = numChannels;
    asbd.mBitsPerChannel = 8 * sizeof(T);
    asbd.mBytesPerFrame = sizeof(T) * asbd.mChannelsPerFrame;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    asbd.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeEndian) | static_cast<AudioFormatFlags>(kAudioFormatFlagIsPacked) | formatFlag<T>;
    asbd.mReserved = 0;
    return asbd;
}


template <typename T>
class EachSampleTypeTest : public testing::Test {

};

static constexpr uint32_t failPropertyIncrements[] = {
    1, static_cast<uint32_t>(-1), 8, static_cast<uint32_t>(-8), 16, static_cast<uint32_t>(-16), 32, static_cast<uint32_t>(-32), 60, 5000
};

}


TYPED_TEST_SUITE_P(EachSampleTypeTest);

TYPED_TEST_P(EachSampleTypeTest, CreateWorks)
{
    WebCore::CAAudioStreamDescription d = createASBD<TypeParam>();
    EXPECT_EQ(d.format(), pcmFormat<TypeParam>);
}

TYPED_TEST_P(EachSampleTypeTest, FormatFailsBytesPerFrame)
{
    for (auto increment : failPropertyIncrements) {
        auto asbd = createASBD<TypeParam>();
        asbd.mBytesPerFrame += increment;
        WebCore::CAAudioStreamDescription d = asbd;
        EXPECT_EQ(d.format(), WebCore::AudioStreamDescription::None) << increment;
    }
}

TYPED_TEST_P(EachSampleTypeTest, FormatFailsBitsPerChannel)
{
    for (auto increment : failPropertyIncrements) {
        auto asbd = createASBD<TypeParam>();
        asbd.mBitsPerChannel += increment;
        WebCore::CAAudioStreamDescription d = asbd;
        EXPECT_EQ(d.format(), WebCore::AudioStreamDescription::None) << increment;
    }
}

TYPED_TEST_P(EachSampleTypeTest, FormatFailsChannelsPerFrame)
{
    for (auto increment : failPropertyIncrements) {
        auto asbd = createASBD<TypeParam>();
        asbd.mChannelsPerFrame += increment;
        WebCore::CAAudioStreamDescription d = asbd;
        EXPECT_EQ(d.format(), WebCore::AudioStreamDescription::None) << increment;
    }
}


using SampleTypes = ::testing::Types<float, double, int16_t, int32_t>;

REGISTER_TYPED_TEST_SUITE_P(EachSampleTypeTest,
    CreateWorks, FormatFailsBytesPerFrame, FormatFailsBitsPerChannel, FormatFailsChannelsPerFrame);

INSTANTIATE_TYPED_TEST_SUITE_P(AudioStreamDescriptionCocoa, EachSampleTypeTest, SampleTypes);

TEST(AudioStreamDescriptionCocoa, MakesPackedLinearPCMDescriptions)
{
    using WebCore::AudioStreamDescription;
    using WebCore::CAAudioStreamDescription;
    AudioFormatFlags packed = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeEndian) | static_cast<AudioFormatFlags>(kAudioFormatFlagIsPacked);
    struct Expected {
        AudioStreamDescription::PCMFormat format;
        uint32_t channels;
        CAAudioStreamDescription::IsInterleaved interleaved;
        AudioFormatFlags flags;
        uint32_t bytesPerFrame;
        uint32_t bitsPerChannel;
    };
    const Expected cases[] = {
        { AudioStreamDescription::Uint8, 2, CAAudioStreamDescription::IsInterleaved::Yes, packed, 2, 8 },
        { AudioStreamDescription::Int16, 2, CAAudioStreamDescription::IsInterleaved::Yes, packed | kAudioFormatFlagIsSignedInteger, 4, 16 },
        { AudioStreamDescription::Int24, 1, CAAudioStreamDescription::IsInterleaved::No, packed | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved, 3, 24 },
        { AudioStreamDescription::Int32, 6, CAAudioStreamDescription::IsInterleaved::Yes, packed | kAudioFormatFlagIsSignedInteger, 24, 32 },
        { AudioStreamDescription::Float32, 2, CAAudioStreamDescription::IsInterleaved::No, packed | kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved, 4, 32 },
        { AudioStreamDescription::Float64, 3, CAAudioStreamDescription::IsInterleaved::Yes, packed | kAudioFormatFlagIsFloat, 24, 64 },
    };
    for (auto& expected : cases) {
        CAAudioStreamDescription description(44100, expected.channels, expected.format, expected.interleaved);
        auto& asbd = description.streamDescription();
        EXPECT_EQ(asbd.mSampleRate, 44100);
        EXPECT_EQ(asbd.mFormatID, kAudioFormatLinearPCM);
        EXPECT_EQ(asbd.mFormatFlags, expected.flags);
        EXPECT_EQ(asbd.mFramesPerPacket, 1u);
        EXPECT_EQ(asbd.mChannelsPerFrame, expected.channels);
        EXPECT_EQ(asbd.mBytesPerFrame, expected.bytesPerFrame);
        EXPECT_EQ(asbd.mBytesPerPacket, expected.bytesPerFrame);
        EXPECT_EQ(asbd.mBitsPerChannel, expected.bitsPerChannel);
        EXPECT_EQ(asbd.mReserved, 0u);
        EXPECT_EQ(description.format(), expected.format);
    }
}

TEST(AudioStreamDescriptionCocoa, FormatOfUint8AndInt24)
{
    auto uint8 = createASBD<uint8_t>(2);
    EXPECT_EQ(WebCore::CAAudioStreamDescription(uint8).format(), WebCore::AudioStreamDescription::Uint8);

    auto int24 = createASBD<int32_t>(2);
    int24.mBitsPerChannel = 24;
    int24.mBytesPerFrame = int24.mBytesPerPacket = 6;
    EXPECT_EQ(WebCore::CAAudioStreamDescription(int24).format(), WebCore::AudioStreamDescription::Int24);

    auto float24 = createASBD<float>(2);
    float24.mBitsPerChannel = 24;
    float24.mBytesPerFrame = float24.mBytesPerPacket = 6;
    EXPECT_EQ(WebCore::CAAudioStreamDescription(float24).format(), WebCore::AudioStreamDescription::None);

    auto bigEndian = createASBD<int16_t>(1);
    bigEndian.mFormatFlags |= kAudioFormatFlagIsBigEndian;
    EXPECT_EQ(WebCore::CAAudioStreamDescription(bigEndian).format(), WebCore::AudioStreamDescription::None);
}

TEST(AudioStreamDescriptionCocoa, BufferListSizesOverflow)
{
    WebCore::CAAudioStreamDescription interleaved(48000, 2, WebCore::AudioStreamDescription::Float32, WebCore::CAAudioStreamDescription::IsInterleaved::Yes);
    EXPECT_TRUE(WebCore::WebAudioBufferList::isSupportedDescription(interleaved, 4096));
    EXPECT_FALSE(WebCore::WebAudioBufferList::isSupportedDescription(interleaved, std::numeric_limits<size_t>::max() / 2 + 1));
    EXPECT_FALSE(WebCore::WebAudioBufferList::isSupportedDescription(interleaved, std::numeric_limits<size_t>::max() / 8 + 1));

    // Each of the two buffers fits, but not both.
    WebCore::CAAudioStreamDescription planar(48000, 2, WebCore::AudioStreamDescription::Float32, WebCore::CAAudioStreamDescription::IsInterleaved::No);
    EXPECT_TRUE(WebCore::WebAudioBufferList::isSupportedDescription(planar, std::numeric_limits<size_t>::max() / 8));
    EXPECT_FALSE(WebCore::WebAudioBufferList::isSupportedDescription(planar, std::numeric_limits<size_t>::max() / 8 + 1));

    WebCore::WebAudioBufferList list(planar, 480);
    EXPECT_EQ(list.list()->mNumberBuffers, 2u);
    EXPECT_EQ(list.bufferAsSpan(0).size(), 480u * 4);
    EXPECT_EQ(list.bufferAsSpan(1).size(), 480u * 4);
}

#endif
