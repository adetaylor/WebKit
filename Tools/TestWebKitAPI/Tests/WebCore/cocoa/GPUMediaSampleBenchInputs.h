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

// The inputs of GPUMediaSampleBench: the track infos and sample blocks the web process sends the GPU process, built
// from fixed bytes and a fixed-seed generator, so every run sees the same ones. Nothing here calls the code the
// benchmark measures. Anything else that wants the benchmark's inputs includes this file instead of copying them.

#if USE(AVFOUNDATION)

#include <WebCore/AudioSampleFormat.h>
#include <WebCore/FourCC.h>
#include <WebCore/MediaSample.h>
#include <WebCore/MediaSamplesBlock.h>
#include <WebCore/PlatformMediaCapabilitiesHdrMetadataType.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/TrackInfo.h>
#include <WebCore/VideoPixelFormat.h>
#include <wtf/MediaTime.h>
#include <wtf/Vector.h>

namespace TestWebKitAPI::GPUMediaSampleBenchInputs {

using WebCore::AudioInfo;
using WebCore::AudioSampleFormat;
using WebCore::EncryptionBoxType;
using WebCore::EncryptionDataCollection;
using WebCore::FloatSize;
using WebCore::FourCC;
using WebCore::MediaSample;
using WebCore::MediaSamplesBlock;
using WebCore::PlatformMediaCapabilitiesHdrMetadataType;
using WebCore::PlatformVideoColorPrimaries;
using WebCore::PlatformVideoMatrixCoefficients;
using WebCore::PlatformVideoTransferCharacteristics;
using WebCore::SharedBuffer;
using WebCore::TrackInfo;
using WebCore::TrackInfoEncryptionInitData;
using WebCore::VideoInfo;
using WebCore::VideoPixelFormat;

// A linear congruential generator, as the other benchmarks' inputs use.
class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    uint32_t below(uint32_t n)
    {
        m_state = m_state * 1664525u + 1013904223u;
        return (m_state >> 8) % n;
    }

    uint8_t byte() { return static_cast<uint8_t>(below(256)); }

    Vector<uint8_t> bytes(size_t size)
    {
        Vector<uint8_t> result(size);
        for (auto& value : result.mutableSpan())
            value = byte();
        return result;
    }

private:
    uint32_t m_state;
};

inline Ref<SharedBuffer> buffer(Vector<uint8_t>&& bytes)
{
    return SharedBuffer::create(WTF::move(bytes));
}

inline Ref<SharedBuffer> randomBuffer(Generator& generator, size_t size)
{
    return buffer(generator.bytes(size));
}

// H.264 640x480 Main profile level 3.0, from WebCoreDecompressionSessionTests.mm.
inline constexpr std::array<uint8_t, 24> h264SPS { 0x67, 0x4D, 0x40, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0xC0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xC0, 0x3C, 0x58, 0xBA, 0x80 };
inline constexpr std::array<uint8_t, 5> h264PPS { 0x68, 0xEF, 0x0F, 0x2C, 0x80 };

// The avcC record of the parameter sets above, with 4-byte NAL lengths.
inline Vector<uint8_t> h264AvcC()
{
    std::array<uint8_t, 8> beforeSPS { 1, h264SPS[1], h264SPS[2], h264SPS[3], 0xFF, 0xE1, 0, static_cast<uint8_t>(h264SPS.size()) };
    std::array<uint8_t, 3> beforePPS { 1, 0, static_cast<uint8_t>(h264PPS.size()) };
    Vector<uint8_t> record;
    record.append(std::span<const uint8_t> { beforeSPS });
    record.append(std::span<const uint8_t> { h264SPS });
    record.append(std::span<const uint8_t> { beforePPS });
    record.append(std::span<const uint8_t> { h264PPS });
    return record;
}

inline Ref<VideoInfo> h264VideoInfo(std::optional<EncryptionDataCollection>&& encryption = std::nullopt)
{
    Vector<TrackInfo::AtomData> atoms;
    atoms.append(TrackInfo::AtomData { FourCC { "avcC" }, buffer(h264AvcC()) });
    return VideoInfo::create({
        {
            .codecName = FourCC { "avc1" },
            .codecString = "avc1.4D401E"_s,
            .trackID = 1,
#if ENABLE(ENCRYPTED_MEDIA)
            .encryptionData = WTF::move(encryption)
#endif
        }, {
            .size = FloatSize { 640, 480 },
            .displaySize = FloatSize { 640, 480 },
            .bitDepth = 8,
            .colorSpace = { .primaries = PlatformVideoColorPrimaries::Bt709, .transfer = PlatformVideoTransferCharacteristics::Bt709, .matrix = PlatformVideoMatrixCoefficients::Bt709, .fullRange = false },
            .extensionAtoms = WTF::move(atoms)
        }
    });
}

// VP9 profile 2, 10 bit, 3840x2160, BT.2020 with the PQ transfer function, the vpcC record and the two HDR atoms
// (mdcv: mastering display colour volume; clli: content light level) a WebM or MP4 file carries.
inline Ref<VideoInfo> vp9HDRVideoInfo()
{
    Generator generator(0x7a9d);
    Vector<TrackInfo::AtomData> atoms;
    std::array<uint8_t, 12> vpcC { 1, 0, 0, 0, 2, 0x33, 0xA2, 9, 16, 9, 0, 0 };
    atoms.append(TrackInfo::AtomData { FourCC { "vpcC" }, buffer(Vector<uint8_t>(std::span<const uint8_t> { vpcC })) });
    atoms.append(TrackInfo::AtomData { FourCC { "mdcv" }, randomBuffer(generator, 24) });
    atoms.append(TrackInfo::AtomData { FourCC { "clli" }, randomBuffer(generator, 4) });
    return VideoInfo::create({
        {
            .codecName = FourCC { "vp09" },
            .codecString = "vp09.02.51.10.01.09.16.09.00"_s,
            .trackID = 1
        }, {
            .size = FloatSize { 3840, 2160 },
            .displaySize = FloatSize { 3840, 2160 },
            .bitDepth = 10,
            .colorSpace = { .primaries = PlatformVideoColorPrimaries::Bt2020, .transfer = PlatformVideoTransferCharacteristics::SmpteSt2084, .matrix = PlatformVideoMatrixCoefficients::Bt2020NonconstantLuminance, .fullRange = false },
            .extensionAtoms = WTF::move(atoms)
        }
    });
}

// Opus, 48 kHz stereo, with the OpusHead cookie (version 1, 2 channels, pre-skip 312, input rate 48000, no gain,
// channel mapping family 0).
inline Ref<AudioInfo> opusAudioInfo()
{
    std::array<uint8_t, 19> head { 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0 };
    Vector<uint8_t> cookie(std::span<const uint8_t> { head });
    return AudioInfo::create({
        {
            .codecName = FourCC { "opus" },
            .codecString = "opus"_s,
            .trackID = 2
        }, {
            .rate = 48000,
            .channels = 2,
            .framesPerPacket = 960,
            .bitDepth = 16,
            .cookieData = buffer(WTF::move(cookie))
        }
    });
}

inline constexpr uint32_t decodedAudioRate = 48000;
inline constexpr uint32_t decodedAudioChannels = 2;
inline constexpr uint32_t decodedAudioFramesPerItem = 1024;

inline Ref<AudioInfo> decodedAudioInfo()
{
    return AudioInfo::create({
        {
            .codecName = FourCC { "lpcm" },
            .trackID = 2
        }, {
            .rate = decodedAudioRate,
            .channels = decodedAudioChannels,
            .framesPerPacket = 1,
            .bitDepth = 32,
            .sampleFormat = AudioSampleFormat::F32
        }
    });
}

inline constexpr size_t decodedVideoWidth = 1920;
inline constexpr size_t decodedVideoHeight = 1080;
inline constexpr size_t decodedVideoI420Size = decodedVideoWidth * decodedVideoHeight * 3 / 2;

inline Ref<VideoInfo> decodedVideoInfo()
{
    return VideoInfo::create({
        {
            .codecName = FourCC { "I420" },
            .trackID = 1
        }, {
            .size = FloatSize { decodedVideoWidth, decodedVideoHeight },
            .displaySize = FloatSize { decodedVideoWidth, decodedVideoHeight },
            .bitDepth = 8,
            .colorSpace = { .primaries = PlatformVideoColorPrimaries::Bt709, .transfer = PlatformVideoTransferCharacteristics::Bt709, .matrix = PlatformVideoMatrixCoefficients::Bt709, .fullRange = false },
            .pixelFormat = VideoPixelFormat::I420
        }
    });
}

// One compressed video item: a 4-byte length and then bytes no decoder is ever given, the size of a typical
// inter frame; the builders only wrap it.
inline constexpr size_t compressedVideoItemSize = 32 * 1024;

inline MediaSamplesBlock::MediaSampleItem compressedVideoItem(Generator& generator, unsigned index, uint32_t flags)
{
    auto bytes = generator.bytes(compressedVideoItemSize);
    uint32_t length = compressedVideoItemSize - 4;
    bytes[0] = length >> 24;
    bytes[1] = length >> 16;
    bytes[2] = length >> 8;
    bytes[3] = length;
    return {
        .presentationTime = MediaTime(2 * index + 2, 60),
        .decodeTime = MediaTime(index, 60),
        .duration = MediaTime(1, 30),
        .data = buffer(WTF::move(bytes)),
        .flags = flags
    };
}

// A compressed H.264 block of itemCount frames: the first a sync frame, the rest not.
inline MediaSamplesBlock compressedVideoBlock(unsigned itemCount)
{
    Generator generator(0x1001 + itemCount);
    MediaSamplesBlock::SamplesVector items;
    for (unsigned index = 0; index < itemCount; ++index)
        items.append(compressedVideoItem(generator, index, index ? 0 : MediaSample::IsSync));
    Ref info = h264VideoInfo();
    return MediaSamplesBlock { info.ptr(), WTF::move(items) };
}

// Eight frames the way a WebM file with an alpha channel and HDR10+ metadata gives them: every item with alpha data,
// two with HDR10+ metadata, one not displayed, only the first a sync frame.
inline MediaSamplesBlock compressedVideoWithAlphaBlock()
{
    Generator generator(0x2002);
    MediaSamplesBlock::SamplesVector items;
    for (unsigned index = 0; index < 8; ++index) {
        uint32_t flags = index ? 0 : MediaSample::IsSync;
        if (index == 3)
            flags |= MediaSample::IsNonDisplaying;
        auto item = compressedVideoItem(generator, index, flags);
        item.alphaData = randomBuffer(generator, 4096);
        if (index == 2 || index == 5) {
            item.hdrMetadata = randomBuffer(generator, 64);
            item.hdrMetadataType = PlatformMediaCapabilitiesHdrMetadataType::SmpteSt209440;
        }
        items.append(WTF::move(item));
    }
    Ref info = vp9HDRVideoInfo();
    return MediaSamplesBlock { info.ptr(), WTF::move(items) };
}

#if ENABLE(ENCRYPTED_MEDIA)
// An encrypted H.264 block of four frames: the track's encryption box and original format, one init data atom, and for
// each item its clear byte count, initialization vector and subsample map.
inline MediaSamplesBlock encryptedVideoBlock()
{
    Generator generator(0x3003);
    Vector<TrackInfoEncryptionInitData> initDatas;
    initDatas.append(TrackInfoEncryptionInitData { FourCC { "pssh" }, randomBuffer(generator, 48) });
    EncryptionDataCollection collection {
        { EncryptionBoxType::CommonEncryptionTrackEncryptionBox, randomBuffer(generator, 32) },
        FourCC { "avc1" },
        WTF::move(initDatas)
    };
    Ref info = h264VideoInfo(WTF::move(collection));
    MediaSamplesBlock::SamplesVector items;
    for (unsigned index = 0; index < 4; ++index) {
        auto item = compressedVideoItem(generator, index, index ? 0 : MediaSample::IsSync);
        item.bytesOfClearDataCount = 32 + index;
        item.cryptorIV = randomBuffer(generator, 16);
        item.cryptorSubsampleAuxiliaryData = randomBuffer(generator, 14);
        items.append(WTF::move(item));
    }
    return MediaSamplesBlock { info.ptr(), WTF::move(items) };
}
#endif

// Decoded stereo audio as the decoders in the web process hand it over: eight items of 1024 interleaved F32 frames,
// each a series of small steps (a waveform, not noise), after a discontinuity.
inline MediaSamplesBlock decodedAudioBlock()
{
    Generator generator(0x4004);
    MediaSamplesBlock::SamplesVector items;
    MediaTime presentationTime = MediaTime(5, 1);
    float level = 0;
    for (unsigned index = 0; index < 8; ++index) {
        Vector<float> samples(decodedAudioFramesPerItem * decodedAudioChannels);
        for (auto& sample : samples.mutableSpan()) {
            level += (static_cast<int>(generator.below(2001)) - 1000) / 40000.0f;
            level = std::max(-1.0f, std::min(1.0f, level));
            sample = level;
        }
        Vector<uint8_t> bytes(samples.size() * sizeof(float));
        memcpySpan(bytes.mutableSpan(), asByteSpan(samples.span()));
        MediaTime duration(decodedAudioFramesPerItem, decodedAudioRate);
        items.append({
            .presentationTime = presentationTime,
            .duration = duration,
            .data = buffer(WTF::move(bytes)),
            .flags = MediaSample::IsSync
        });
        presentationTime += duration;
    }
    Ref info = decodedAudioInfo();
    MediaSamplesBlock block { info.ptr(), WTF::move(items) };
    block.setDiscontinuity(true);
    return block;
}

// Thirty-two Opus packets of 20 ms, the first trimmed by the pre-skip and the last at its end, after a discontinuity.
inline MediaSamplesBlock opusBlock()
{
    Generator generator(0x5005);
    MediaSamplesBlock::SamplesVector items;
    for (unsigned index = 0; index < 32; ++index) {
        MediaSamplesBlock::MediaSampleItem item {
            .presentationTime = MediaTime(960 * index, 48000),
            .decodeTime = MediaTime(960 * index, 48000),
            .duration = MediaTime(960, 48000),
            .data = randomBuffer(generator, 80 + generator.below(120)),
            .flags = MediaSample::IsSync
        };
        if (!index)
            item.trimInterval.first = MediaTime(312, 48000);
        if (index == 31)
            item.trimInterval.second = MediaTime(100, 48000);
        items.append(WTF::move(item));
    }
    Ref info = opusAudioInfo();
    MediaSamplesBlock block { info.ptr(), WTF::move(items) };
    block.setDiscontinuity(true);
    return block;
}

// One decoded 1080p I420 frame: a gradient with a little noise in each plane, so it is not all one value.
inline MediaSamplesBlock decodedI420Block()
{
    Generator generator(0x6006);
    Vector<uint8_t> bytes(decodedVideoI420Size);
    size_t lumaSize = decodedVideoWidth * decodedVideoHeight;
    auto span = bytes.mutableSpan();
    for (size_t y = 0; y < decodedVideoHeight; ++y) {
        for (size_t x = 0; x < decodedVideoWidth; ++x)
            span[y * decodedVideoWidth + x] = 16 + ((x + y) * 219 / (decodedVideoWidth + decodedVideoHeight)) + generator.below(4);
    }
    for (size_t index = lumaSize; index < span.size(); ++index)
        span[index] = 112 + generator.below(32);
    MediaSamplesBlock::SamplesVector items;
    items.append({
        .presentationTime = MediaTime(1, 30),
        .decodeTime = MediaTime(1, 30),
        .duration = MediaTime(1, 30),
        .data = buffer(WTF::move(bytes)),
        .flags = MediaSample::IsSync
    });
    Ref info = decodedVideoInfo();
    return MediaSamplesBlock { info.ptr(), WTF::move(items) };
}

} // namespace TestWebKitAPI::GPUMediaSampleBenchInputs

#endif // USE(AVFOUNDATION)
