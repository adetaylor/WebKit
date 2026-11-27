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

#if USE(AVFOUNDATION)

#include "GPUMediaSampleBenchInputs.h"
#include "Helpers/PlatformUtilities.h"
#include "Helpers/Test.h"
#include "Helpers/Utilities.h"
#include "Helpers/cocoa/TestNSBundleExtras.h"
#include <AVFoundation/AVFoundation.h>
#include <WebCore/AudioVideoRendererAVFObjC.h>
#include <WebCore/CMUtilities.h>
#include <WebCore/MediaSampleAVFObjC.h>
#include <WebCore/MediaSamplesBlock.h>
#include <WebCore/TrackInfo.h>
#include <WebCore/VideoFrame.h>
#include <WebCore/WebCoreDecompressionSession.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <wtf/Logger.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

#include <pal/cf/CoreMediaSoftLink.h>
#include <pal/cocoa/AVFoundationSoftLink.h>

// The cost of the GPU process's media-sample path, one TEST per shape. The builder shapes call CMUtilities'
// createFormatDescriptionFromTrackInfo and toCMSampleBuffer on the blocks the web process sends (inputs in
// GPUMediaSampleBenchInputs.h); the others drive AudioVideoRendererAVFObjC and WebCoreDecompressionSession as the
// AudioVideoRendererAVFObjCTests.mm does (real H.264 samples from test.mp4 and decoded frames, the timebase paused),
// and decodeSampleSync as the image decoder does.
//
// Each test runs one pass over its input and compares a digest of everything the pass produced (a canonical walk of the
// format descriptions, sample buffers, attachments, pixel planes, callbacks and metrics) with the value recorded from
// the renderer's output before it was ported to Swift. With WEBKIT_RUN_BENCHMARKS=1 it then runs passes for about two seconds and prints
// "<Shape>: <ms> ms <n> MB/s checksum=<digest>", where MB/s counts the bytes of block data and sample data a pass
// handles (a fixed 64 bytes per call for the shapes that query state). The checksum is the first pass's. A shape whose
// recorded value is still zero prints the checksum and asserts only that it is not zero.

namespace TestWebKitAPI {

using namespace WebCore;
namespace Inputs = GPUMediaSampleBenchInputs;

// Recorded from the C++ implementation, before the Swift port; they cannot be regenerated from the current code.
static constexpr uint64_t expectedFormatDescriptionH264 = 0x325f9e1f2513afe9;
static constexpr uint64_t expectedFormatDescriptionVP9HDR = 0x8f9f30f79eede877;
static constexpr uint64_t expectedFormatDescriptionOpus = 0xca2a5a57eb81914d;
static constexpr uint64_t expectedToSampleBufferVideo1 = 0x948bd44dd2dbbe93;
static constexpr uint64_t expectedToSampleBufferVideo8 = 0xd69c1e9790431687;
static constexpr uint64_t expectedToSampleBufferVideo8Alpha = 0xc03565752c7385d4;
static constexpr uint64_t expectedToSampleBufferEncrypted = 0x53d04f1095b4daa4;
static constexpr uint64_t expectedToSampleBufferDecodedAudio = 0x5b74498cc4e26d90;
static constexpr uint64_t expectedToSampleBufferOpus32 = 0x462be86613cd6346;
static constexpr uint64_t expectedToSampleBufferDecodedI420 = 0x76f262633e69bb8a;
static constexpr uint64_t expectedDecodedEnqueue = 0x13fdf713f6dfc731;
static constexpr uint64_t expectedCompressedViaSession = 0x05b6346f4e092112;
static constexpr uint64_t expectedCompressedViaRenderer = 0x1934a42c0463b370;
static constexpr uint64_t expectedFlushReenqueue = 0xbf44ebdb6d706daf;
static constexpr uint64_t expectedMetricsQuery = 0x8381ec20cc72e024;
static constexpr uint64_t expectedCurrentVideoFrame = 0xa62ebc19aef11274;
static constexpr uint64_t expectedDecodeSampleSync = 0x06ca61b960cfb436;

namespace {

class Digest {
public:
    uint64_t value() const { return m_value; }

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte((word >> (8 * i)) & 0xff);
    }

    void add(std::span<const uint8_t> bytes)
    {
        add(bytes.size());
        for (auto byte : bytes)
            addByte(byte);
    }

    void add(StringView string)
    {
        if (string.isNull()) {
            add(~0ull);
            return;
        }
        add(string.length());
        for (unsigned i = 0; i < string.length(); ++i) {
            char16_t character = string[i];
            addByte(character & 0xff);
            addByte(character >> 8);
        }
    }

    void add(CMTime time)
    {
        add(static_cast<uint64_t>(time.value));
        add(static_cast<uint64_t>(time.timescale));
        add(static_cast<uint64_t>(time.flags));
        add(static_cast<uint64_t>(time.epoch));
    }

private:
    void addByte(uint8_t byte)
    {
        m_value ^= byte;
        m_value *= 1099511628211ull;
    }

    uint64_t m_value { 1469598103934665603ull };
};

}

static String stringFromCF(CFStringRef string)
{
    Vector<char16_t> characters(CFStringGetLength(string));
    CFStringGetCharacters(string, CFRangeMake(0, characters.size()), reinterpret_cast<UniChar*>(characters.mutableSpan().data()));
    return String(characters.span());
}

// A canonical walk of a property list: dictionaries by sorted key, arrays in order, numbers by kind and value.
static void digestCF(Digest& digest, CFTypeRef value)
{
    if (!value) {
        digest.add(~0ull);
        return;
    }
    auto typeID = CFGetTypeID(value);
    digest.add(1);
    if (typeID == CFStringGetTypeID()) {
        digest.add(2);
        digest.add(stringFromCF(static_cast<CFStringRef>(value)));
    } else if (typeID == CFNumberGetTypeID()) {
        auto number = static_cast<CFNumberRef>(value);
        if (CFNumberIsFloatType(number)) {
            double result = 0;
            CFNumberGetValue(number, kCFNumberFloat64Type, &result);
            digest.add(3);
            digest.add(std::bit_cast<uint64_t>(result));
        } else {
            int64_t result = 0;
            CFNumberGetValue(number, kCFNumberSInt64Type, &result);
            digest.add(4);
            digest.add(static_cast<uint64_t>(result));
        }
    } else if (typeID == CFBooleanGetTypeID()) {
        digest.add(5);
        digest.add(CFBooleanGetValue(static_cast<CFBooleanRef>(value)));
    } else if (typeID == CFDataGetTypeID()) {
        auto data = static_cast<CFDataRef>(value);
        digest.add(6);
        digest.add(std::span { CFDataGetBytePtr(data), static_cast<size_t>(CFDataGetLength(data)) });
    } else if (typeID == CFArrayGetTypeID()) {
        auto array = static_cast<CFArrayRef>(value);
        digest.add(7);
        digest.add(CFArrayGetCount(array));
        for (CFIndex i = 0; i < CFArrayGetCount(array); ++i)
            digestCF(digest, CFArrayGetValueAtIndex(array, i));
    } else if (typeID == CFDictionaryGetTypeID()) {
        auto dictionary = static_cast<CFDictionaryRef>(value);
        CFIndex count = CFDictionaryGetCount(dictionary);
        Vector<const void*> keys(count);
        Vector<const void*> values(count);
        CFDictionaryGetKeysAndValues(dictionary, keys.mutableSpan().data(), values.mutableSpan().data());
        Vector<std::pair<String, const void*>> entries;
        for (CFIndex i = 0; i < count; ++i) {
            auto key = static_cast<CFTypeRef>(keys[i]);
            RetainPtr description = CFGetTypeID(key) == CFStringGetTypeID() ? retainPtr(static_cast<CFStringRef>(key)) : adoptCF(CFCopyDescription(key));
            entries.append({ stringFromCF(description.get()), values[i] });
        }
        std::sort(entries.begin(), entries.end(), [](auto& a, auto& b) {
            return codePointCompareLessThan(a.first, b.first);
        });
        digest.add(8);
        digest.add(count);
        for (auto& [key, entryValue] : entries) {
            digest.add(key);
            digestCF(digest, static_cast<CFTypeRef>(entryValue));
        }
    } else {
        digest.add(9);
        digest.add(typeID);
    }
}

static void digestFormatDescription(Digest& digest, CMFormatDescriptionRef description)
{
    if (!description) {
        digest.add(~0ull);
        return;
    }
    auto mediaType = PAL::CMFormatDescriptionGetMediaType(description);
    digest.add(mediaType);
    digest.add(PAL::CMFormatDescriptionGetMediaSubType(description));
    digestCF(digest, PAL::CMFormatDescriptionGetExtensions(description));
    if (mediaType == kCMMediaType_Video) {
        auto dimensions = PAL::CMVideoFormatDescriptionGetDimensions(description);
        digest.add(dimensions.width);
        digest.add(dimensions.height);
    } else if (mediaType == kCMMediaType_Audio) {
        if (auto* basic = PAL::CMAudioFormatDescriptionGetStreamBasicDescription(description)) {
            digest.add(std::bit_cast<uint64_t>(basic->mSampleRate));
            digest.add(basic->mFormatID);
            digest.add(basic->mFormatFlags);
            digest.add(basic->mBytesPerPacket);
            digest.add(basic->mFramesPerPacket);
            digest.add(basic->mBytesPerFrame);
            digest.add(basic->mChannelsPerFrame);
            digest.add(basic->mBitsPerChannel);
        }
    }
}

static void digestPixelBuffer(Digest& digest, CVPixelBufferRef pixelBuffer)
{
    if (!pixelBuffer) {
        digest.add(~0ull);
        return;
    }
    digest.add(CVPixelBufferGetPixelFormatType(pixelBuffer));
    digest.add(CVPixelBufferGetWidth(pixelBuffer));
    digest.add(CVPixelBufferGetHeight(pixelBuffer));
    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        digest.add(~1ull);
        return;
    }
    size_t planes = CVPixelBufferGetPlaneCount(pixelBuffer);
    digest.add(planes);
    for (size_t plane = 0; plane < std::max<size_t>(planes, 1); ++plane) {
        size_t width = planes ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer);
        size_t height = planes ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer);
        size_t bytesPerRow = planes ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) : CVPixelBufferGetBytesPerRow(pixelBuffer);
        auto* base = static_cast<const uint8_t*>(planes ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) : CVPixelBufferGetBaseAddress(pixelBuffer));
        // The row's pixels only: the padding past them is not written.
        size_t rowBytes = planes ? width * (CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && plane ? 2 : 1) : width * 4;
        digest.add(width);
        digest.add(height);
        for (size_t row = 0; row < height && base; ++row)
            digest.add(std::span { base + row * bytesPerRow, std::min(rowBytes, bytesPerRow) });
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    digestCF(digest, adoptCF(CVBufferCopyAttachments(pixelBuffer, kCVAttachmentMode_ShouldPropagate)).get());
}

static void digestSampleBuffer(Digest& digest, CMSampleBufferRef sampleBuffer)
{
    digest.add(PAL::CMSampleBufferGetNumSamples(sampleBuffer));
    digestFormatDescription(digest, PAL::CMSampleBufferGetFormatDescription(sampleBuffer));

    CMItemCount timingCount = 0;
    auto status = PAL::CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, nullptr, &timingCount);
    digest.add(static_cast<uint64_t>(status));
    digest.add(timingCount);
    if (timingCount) {
        Vector<CMSampleTimingInfo> timings(timingCount);
        CMItemCount needed = 0;
        status = PAL::CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, timingCount, timings.mutableSpan().data(), &needed);
        digest.add(static_cast<uint64_t>(status));
        for (auto& timing : timings.span()) {
            digest.add(timing.duration);
            digest.add(timing.presentationTimeStamp);
            digest.add(timing.decodeTimeStamp);
        }
    }

    CMItemCount sizeCount = 0;
    status = PAL::CMSampleBufferGetSampleSizeArray(sampleBuffer, 0, nullptr, &sizeCount);
    digest.add(static_cast<uint64_t>(status));
    digest.add(sizeCount);
    if (sizeCount) {
        Vector<size_t> sizes(sizeCount);
        CMItemCount needed = 0;
        status = PAL::CMSampleBufferGetSampleSizeArray(sampleBuffer, sizeCount, sizes.mutableSpan().data(), &needed);
        digest.add(static_cast<uint64_t>(status));
        for (auto size : sizes.span())
            digest.add(size);
    }

    if (auto dataBuffer = PAL::CMSampleBufferGetDataBuffer(sampleBuffer)) {
        size_t length = PAL::CMBlockBufferGetDataLength(dataBuffer);
        Vector<uint8_t> bytes(length);
        digest.add(static_cast<uint64_t>(PAL::CMBlockBufferCopyDataBytes(dataBuffer, 0, length, bytes.mutableSpan().data())));
        digest.add(bytes.span());
    } else
        digest.add(~2ull);
    digestPixelBuffer(digest, PAL::CMSampleBufferGetImageBuffer(sampleBuffer));

    digestCF(digest, PAL::CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false));
    digestCF(digest, PAL::CMGetAttachment(sampleBuffer, PAL::kCMSampleBufferAttachmentKey_FillDiscontinuitiesWithSilence, nullptr));
    digestCF(digest, PAL::CMGetAttachment(sampleBuffer, PAL::kCMSampleBufferAttachmentKey_TrimDurationAtStart, nullptr));
    digestCF(digest, PAL::CMGetAttachment(sampleBuffer, PAL::kCMSampleBufferAttachmentKey_TrimDurationAtEnd, nullptr));
    digestCF(digest, PAL::CMGetAttachment(sampleBuffer, CFSTR("org.webkit.CompressedAlphaData"), nullptr));
}

// What a shape does once: with the digest wanted, returns the digest of its outputs; without, a cheap sum, so that the
// passes that are timed do not pay for the digest.
template<typename Pass>
static void runShape(ASCIILiteral name, uint64_t expected, size_t bytesPerPass, Pass&& pass)
{
    uint64_t checksum = pass(true);
    if (expected)
        EXPECT_EQ(checksum, expected) << name.characters();
    else {
        EXPECT_NE(checksum, 0u) << name.characters();
        SAFE_PRINTF("%s: checksum=%016llx (not yet recorded)\n", name, static_cast<unsigned long long>(checksum));
    }
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    // One timed pass of a fixed amount of work, so that builds are compared by the cycles they take for the same work.
    auto start = MonotonicTime::now();
    pass(false);
    Seconds elapsed = MonotonicTime::now() - start;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(), bytesPerPass / elapsed.seconds() / 1e6, static_cast<unsigned long long>(checksum));
}

static size_t blockBytes(const MediaSamplesBlock& block)
{
    size_t total = 0;
    for (auto& item : block) {
        total += item.data ? item.data->size() : 0;
        total += item.alphaData ? item.alphaData->size() : 0;
    }
    return total;
}

// Builds the sample buffer `calls` times from the block, as the GPU process does for each block it receives, and
// digests the first.
static void benchmarkToSampleBuffer(ASCIILiteral name, uint64_t expected, const MediaSamplesBlock& block, unsigned calls)
{
    runShape(name, expected, blockBytes(block) * calls, [&](bool withDigest) {
        Digest digest;
        uint64_t sum = 0;
        for (unsigned call = 0; call < calls; ++call) {
            auto result = toCMSampleBuffer(block);
            if (result) {
                sum += PAL::CMSampleBufferGetNumSamples(result->get());
                if (withDigest && !call) {
                    digest.add(1);
                    digestSampleBuffer(digest, result->get());
                }
            } else {
                sum += result.error().length();
                if (withDigest && !call) {
                    digest.add(0);
                    digest.add(StringView { result.error() });
                }
            }
        }
        return withDigest ? digest.value() : sum;
    });
}

static void benchmarkFormatDescription(ASCIILiteral name, uint64_t expected, const TrackInfo& info, unsigned calls)
{
    runShape(name, expected, calls * 64, [&](bool withDigest) {
        Digest digest;
        uint64_t sum = 0;
        for (unsigned call = 0; call < calls; ++call) {
            RetainPtr description = createFormatDescriptionFromTrackInfo(info);
            if (description) {
                sum += PAL::CMFormatDescriptionGetMediaSubType(description.get());
                if (withDigest && !call)
                    digestFormatDescription(digest, description.get());
            } else if (withDigest && !call)
                digest.add(~3ull);
        }
        return withDigest ? digest.value() : sum;
    });
}

TEST(GPUMediaSampleBench, StartUp)
{
}

TEST(GPUMediaSampleBench, FormatDescriptionH264)
{
    Ref info = Inputs::h264VideoInfo();
    benchmarkFormatDescription("FormatDescriptionH264"_s, expectedFormatDescriptionH264, info, 1000000);
}

TEST(GPUMediaSampleBench, FormatDescriptionVP9HDR)
{
    Ref info = Inputs::vp9HDRVideoInfo();
    benchmarkFormatDescription("FormatDescriptionVP9HDR"_s, expectedFormatDescriptionVP9HDR, info, 800000);
}

TEST(GPUMediaSampleBench, FormatDescriptionOpus)
{
    Ref info = Inputs::opusAudioInfo();
    benchmarkFormatDescription("FormatDescriptionOpus"_s, expectedFormatDescriptionOpus, info, 60000);
}

TEST(GPUMediaSampleBench, ToSampleBufferVideo1)
{
    auto block = Inputs::compressedVideoBlock(1);
    benchmarkToSampleBuffer("ToSampleBufferVideo1"_s, expectedToSampleBufferVideo1, block, 750000);
}

TEST(GPUMediaSampleBench, ToSampleBufferVideo8)
{
    auto block = Inputs::compressedVideoBlock(8);
    benchmarkToSampleBuffer("ToSampleBufferVideo8"_s, expectedToSampleBufferVideo8, block, 380000);
}

TEST(GPUMediaSampleBench, ToSampleBufferVideo8Alpha)
{
    auto block = Inputs::compressedVideoWithAlphaBlock();
    benchmarkToSampleBuffer("ToSampleBufferVideo8Alpha"_s, expectedToSampleBufferVideo8Alpha, block, 267000);
}

TEST(GPUMediaSampleBench, ToSampleBufferEncrypted)
{
#if ENABLE(ENCRYPTED_MEDIA)
    auto block = Inputs::encryptedVideoBlock();
    benchmarkToSampleBuffer("ToSampleBufferEncrypted"_s, expectedToSampleBufferEncrypted, block, 320000);
#else
    SAFE_PRINTF("ToSampleBufferEncrypted: skipped (no ENCRYPTED_MEDIA)\n");
#endif
}

TEST(GPUMediaSampleBench, ToSampleBufferDecodedAudio)
{
    auto block = Inputs::decodedAudioBlock();
    benchmarkToSampleBuffer("ToSampleBufferDecodedAudio"_s, expectedToSampleBufferDecodedAudio, block, 222000);
}

TEST(GPUMediaSampleBench, ToSampleBufferOpus32)
{
    auto block = Inputs::opusBlock();
    benchmarkToSampleBuffer("ToSampleBufferOpus32"_s, expectedToSampleBufferOpus32, block, 46000);
}

TEST(GPUMediaSampleBench, ToSampleBufferDecodedI420)
{
    auto block = Inputs::decodedI420Block();
    benchmarkToSampleBuffer("ToSampleBufferDecodedI420"_s, expectedToSampleBufferDecodedI420, block, 1800);
}

// The renderer and the decompression session.

// The video samples of test.mp4, compressed, in decode order.
static const Vector<RetainPtr<CMSampleBufferRef>>& compressedVideoSamples()
{
    static NeverDestroyed<Vector<RetainPtr<CMSampleBufferRef>>> samples = [] {
        Vector<RetainPtr<CMSampleBufferRef>> result;
        RetainPtr url = [NSBundle.test_resourcesBundle URLForResource:@"test" withExtension:@"mp4"];
        if (!url)
            return result;
        RetainPtr asset = adoptNS([PAL::allocAVURLAssetInstance() initWithURL:url.get() options:@{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES }]);
        ALLOW_DEPRECATED_DECLARATIONS_BEGIN
        RetainPtr<NSArray<AVAssetTrack *>> videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        ALLOW_DEPRECATED_DECLARATIONS_END
        if (![videoTracks count])
            return result;
        RetainPtr assetReader = adoptNS([PAL::allocAVAssetReaderInstance() initWithAsset:asset.get() error:nil]);
        RetainPtr trackOutput = adoptNS([PAL::allocAVAssetReaderTrackOutputInstance() initWithTrack:[videoTracks firstObject] outputSettings:nil]);
        if (!assetReader || !trackOutput || ![assetReader canAddOutput:trackOutput.get()])
            return result;
        [assetReader addOutput:trackOutput.get()];
        if (![assetReader startReading])
            return result;
        while (RetainPtr sampleBuffer = adoptCF([trackOutput copyNextSampleBuffer])) {
            if (PAL::CMSampleBufferGetDataBuffer(sampleBuffer.get()) && PAL::CMSampleBufferGetNumSamples(sampleBuffer.get()))
                result.append(WTF::move(sampleBuffer));
        }
        return result;
    }();
    return samples.get();
}

// A decoded 16x16 frame at index / 30 s, as the replay below makes them.
static RetainPtr<CMSampleBufferRef> createDecodedVideoSample(unsigned index)
{
    CVPixelBufferRef rawPixelBuffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nullptr, &rawPixelBuffer))
        return nullptr;
    RetainPtr pixelBuffer = adoptCF(rawPixelBuffer);

    CMVideoFormatDescriptionRef rawFormatDescription = nullptr;
    if (PAL::CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer.get(), &rawFormatDescription))
        return nullptr;
    RetainPtr formatDescription = adoptCF(rawFormatDescription);

    CMSampleTimingInfo timing = { PAL::CMTimeMake(1, 30), PAL::CMTimeMake(index, 30), PAL::kCMTimeInvalid };
    CMSampleBufferRef rawSampleBuffer = nullptr;
    if (PAL::CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer.get(), true, nullptr, nullptr, formatDescription.get(), &timing, &rawSampleBuffer))
        return nullptr;
    return adoptCF(rawSampleBuffer);
}

static size_t sampleBytes(CMSampleBufferRef sampleBuffer)
{
    if (auto dataBuffer = PAL::CMSampleBufferGetDataBuffer(sampleBuffer))
        return PAL::CMBlockBufferGetDataLength(dataBuffer);
    return 16 * 16 * 4;
}

static String timeString(const MediaTime& time)
{
    if (!time.isValid())
        return "invalid"_s;
    return String::numberToStringFixedPrecision(time.toDouble(), 4);
}

// The renderer under test, with its callbacks recorded. Its timebase stays paused.
class Replay {
public:
    enum class Mode : uint8_t { DecompressionSession, Renderer };

    explicit Replay(Mode mode)
        : m_mode(mode)
    {
        Ref logger = Logger::create(this);
        logger->setEnabled(this, false);
        m_renderer = AudioVideoRendererAVFObjC::create(logger, 0);
        m_renderer->setPreferences({ });
        m_renderer->notifyWhenErrorOccurs([this](PlatformMediaError) {
            m_events.append("error"_s);
        });
        m_renderer->notifyWhenRequiresFlushToResume([this] {
            m_events.append("flushToResume"_s);
        });
        m_renderer->notifyFirstFrameAvailable([this] {
            m_events.append("firstFrame"_s);
        });
        // Asking for every available frame makes the renderer manage decoded frames itself.
        if (mode == Mode::DecompressionSession) {
            m_renderer->notifyWhenHasAvailableVideoFrame([this](const MediaTime& presentationTime, double) {
                m_events.append(makeString("frame "_s, timeString(presentationTime)));
            });
        }
        m_trackId = m_renderer->addTrack(TrackInfo::TrackType::Video);
        if (mode == Mode::Renderer)
            m_renderer->renderingCanBeAcceleratedChanged(true);
        Util::runFor(0.05_s);
    }

    ~Replay()
    {
        m_renderer->shutdown();
        m_renderer = nullptr;
    }

    AudioVideoRenderer& renderer() { return *m_renderer; }
    AudioVideoRenderer::TrackIdentifier trackId() const { return *m_trackId; }

    // Enqueues samples as a client does: while the renderer is ready, and otherwise once it asks for more. Returns the
    // bytes of the samples it took before it stopped asking.
    size_t enqueue(std::span<const RetainPtr<CMSampleBufferRef>> samples)
    {
        size_t index = 0;
        size_t bytes = 0;
        while (index < samples.size()) {
            if (!m_renderer->isReadyForMoreSamples(*m_trackId)) {
                bool settled = false;
                bool ready = false;
                m_renderer->requestMediaDataWhenReady(*m_trackId)->whenSettled(RunLoop::mainSingleton(), [&](auto&& result) {
                    ready = !!result;
                    settled = true;
                });
                Util::runFor(&settled, 0.5_s);
                if (!ready)
                    break;
                continue;
            }
            bytes += sampleBytes(samples[index].get());
            m_renderer->enqueueSample(*m_trackId, MediaSampleAVFObjC::create(samples[index].get(), 1), std::nullopt);
            ++index;
        }
        return bytes;
    }

    // Runs until neither the events nor the metrics have changed for a while.
    void settle()
    {
        String last;
        unsigned stableRounds = 0;
        for (unsigned round = 0; round < 100 && stableRounds < 4; ++round) {
            Util::runFor(0.03_s);
            auto current = makeString(m_events.size(), ' ', metricsString());
            stableRounds = current == last ? stableRounds + 1 : 0;
            last = WTF::move(current);
        }
    }

    // Waits up to 10 s for the first decode to show, which settle() alone can end before.
    void waitFor(NOESCAPE const Function<bool()>& done)
    {
        for (unsigned round = 0; round < 200 && !done(); ++round)
            Util::runFor(0.05_s);
    }

    bool hasDecoded()
    {
        auto metrics = m_renderer->videoPlaybackQualityMetrics();
        return metrics && metrics->totalVideoFrames;
    }

    bool hasFrame()
    {
        return !!m_renderer->currentVideoFrame();
    }

    String metricsString()
    {
        auto metrics = m_renderer->videoPlaybackQualityMetrics();
        if (!metrics)
            return "no metrics"_s;
        // Without decoded frames to manage, each query counts as a displayed frame.
        if (m_mode == Mode::Renderer)
            return makeString("total "_s, metrics->totalVideoFrames, " dropped "_s, metrics->droppedVideoFrames, " corrupted "_s, metrics->corruptedVideoFrames);
        return makeString("total "_s, metrics->totalVideoFrames, " dropped "_s, metrics->droppedVideoFrames, " corrupted "_s, metrics->corruptedVideoFrames, " presented "_s, metrics->displayCompositedVideoFrames);
    }

    String currentFrameString()
    {
        RefPtr frame = m_renderer->currentVideoFrame();
        if (!frame)
            return "no frame"_s;
        return makeString(timeString(frame->presentationTime()), ' ', frame->presentationSize().width(), 'x', frame->presentationSize().height());
    }

    // The events since the last checkpoint, then the metrics and the displayed frame.
    String checkpoint(ASCIILiteral name)
    {
        settle();
        StringBuilder builder;
        builder.append(name, ": ["_s);
        for (size_t index = m_eventsReported; index < m_events.size(); ++index)
            builder.append(index == m_eventsReported ? ""_s : ", "_s, m_events[index]);
        m_eventsReported = m_events.size();
        builder.append("] "_s, metricsString(), "; "_s, currentFrameString());
        return builder.toString();
    }

private:
    Mode m_mode;
    RefPtr<AudioVideoRenderer> m_renderer;
    std::optional<AudioVideoRenderer::TrackIdentifier> m_trackId;
    Vector<String> m_events;
    size_t m_eventsReported { 0 };
};

static size_t firstSyncSampleAtOrAfter(size_t index)
{
    auto& samples = compressedVideoSamples();
    for (; index < samples.size(); ++index) {
        if (MediaSampleAVFObjC::create(samples[index].get(), 1)->isSync())
            return index;
    }
    return samples.size();
}

static constexpr size_t compressedSampleCount = 30;
static constexpr unsigned decodedSampleCount = 600;
static constexpr unsigned metricsQueryCount = 30000000;
static constexpr unsigned frameQueryCount = 640000;

// Runs a shape's passes with a fresh renderer each: the replay's lifecycle, timed whole.
template<typename Body>
static void benchmarkReplay(ASCIILiteral name, uint64_t expected, Replay::Mode mode, size_t bytesPerReplay, unsigned replays, Body&& body)
{
    runShape(name, expected, bytesPerReplay * replays, [&](bool) {
        Digest digest;
        for (unsigned index = 0; index < replays; ++index) {
            Replay replay(mode);
            Digest scratch;
            body(replay, index ? scratch : digest);
        }
        return digest.value();
    });
}

// Decoded samples enqueued as the main thread does, 600 at a time, and the frames they produce counted.
TEST(GPUMediaSampleBench, DecodedEnqueue)
{
    Vector<RetainPtr<CMSampleBufferRef>> decoded;
    for (unsigned index = 0; index < decodedSampleCount; ++index)
        decoded.append(createDecodedVideoSample(index));
    ASSERT_FALSE(decoded.contains(nullptr));
    benchmarkReplay("DecodedEnqueue"_s, expectedDecodedEnqueue, Replay::Mode::DecompressionSession, decodedSampleCount * 16 * 16 * 4, 19, [&](Replay& replay, Digest& digest) {
        for (auto& sample : decoded)
            replay.renderer().enqueueSample(replay.trackId(), MediaSampleAVFObjC::create(sample.get(), 1), std::nullopt);
        Util::waitFor([&] {
            Util::runFor(0.001_s);
            auto metrics = replay.renderer().videoPlaybackQualityMetrics();
            return metrics && metrics->totalVideoFrames >= decoded.size();
        }, 5000);
        auto metrics = replay.renderer().videoPlaybackQualityMetrics();
        digest.add(metrics ? metrics->totalVideoFrames : ~0u);
        digest.add(metrics ? metrics->droppedVideoFrames : ~0u);
        digest.add(metrics ? metrics->corruptedVideoFrames : ~0u);
    });
}

// The first 30 compressed samples through the renderer's decompression session, to the paused time.
TEST(GPUMediaSampleBench, CompressedViaSession)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), compressedSampleCount);
    size_t bytes = 0;
    for (size_t index = 0; index < compressedSampleCount; ++index)
        bytes += sampleBytes(samples[index].get());
    benchmarkReplay("CompressedViaSession"_s, expectedCompressedViaSession, Replay::Mode::DecompressionSession, bytes, 6, [&](Replay& replay, Digest& digest) {
        replay.enqueue(std::span { samples }.first(compressedSampleCount));
        digest.add(StringView { replay.checkpoint("session"_s) });
    });
}

// The same through the renderer, which decodes them itself.
TEST(GPUMediaSampleBench, CompressedViaRenderer)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), compressedSampleCount);
    size_t bytes = 0;
    for (size_t index = 0; index < compressedSampleCount; ++index)
        bytes += sampleBytes(samples[index].get());
    benchmarkReplay("CompressedViaRenderer"_s, expectedCompressedViaRenderer, Replay::Mode::Renderer, bytes, 6, [&](Replay& replay, Digest& digest) {
        replay.enqueue(std::span { samples }.first(compressedSampleCount));
        digest.add(StringView { replay.checkpoint("renderer"_s) });
    });
}

// A track flush and a re-enqueue from a sync sample, three times, then a flush of the renderer and a re-enqueue from
// the start, as a seek does.
TEST(GPUMediaSampleBench, FlushReenqueue)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), compressedSampleCount);
    size_t restart = firstSyncSampleAtOrAfter(samples.size() / 2);
    ASSERT_LT(restart, samples.size());
    size_t bytes = 0;
    for (size_t index = 0; index < compressedSampleCount; ++index)
        bytes += sampleBytes(samples[index].get());
    for (size_t index = restart; index < std::min(restart + 8, samples.size()); ++index)
        bytes += 3 * sampleBytes(samples[index].get());
    for (size_t index = 0; index < 4; ++index)
        bytes += sampleBytes(samples[index].get());
    benchmarkReplay("FlushReenqueue"_s, expectedFlushReenqueue, Replay::Mode::DecompressionSession, bytes, 3, [&](Replay& replay, Digest& digest) {
        auto all = std::span { samples };
        replay.enqueue(all.first(compressedSampleCount));
        digest.add(StringView { replay.checkpoint("paused at 0"_s) });
        for (unsigned round = 0; round < 3; ++round) {
            replay.renderer().flushTrack(replay.trackId());
            replay.enqueue(all.subspan(restart, std::min<size_t>(8, samples.size() - restart)));
        }
        digest.add(StringView { replay.checkpoint("after track flushes"_s) });
        replay.renderer().flush();
        replay.enqueue(all.first(4));
        digest.add(StringView { replay.checkpoint("after flush"_s) });
    });
}

// The playback quality metrics queried 30 million times from a renderer that has settled on 30 compressed samples.
TEST(GPUMediaSampleBench, MetricsQuery)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), compressedSampleCount);
    Replay replay(Replay::Mode::DecompressionSession);
    replay.enqueue(std::span { samples }.first(compressedSampleCount));
    replay.waitFor([&] {
        return replay.hasDecoded();
    });
    replay.settle();
    runShape("MetricsQuery"_s, expectedMetricsQuery, metricsQueryCount * 64, [&](bool withDigest) {
        Digest digest;
        uint64_t sum = 0;
        for (unsigned query = 0; query < metricsQueryCount; ++query) {
            auto metrics = replay.renderer().videoPlaybackQualityMetrics();
            if (metrics)
                sum += metrics->totalVideoFrames + metrics->droppedVideoFrames + metrics->corruptedVideoFrames;
            if (withDigest && !query) {
                digest.add(metrics.has_value());
                digest.add(metrics ? metrics->totalVideoFrames : ~0u);
                digest.add(metrics ? metrics->droppedVideoFrames : ~0u);
                digest.add(metrics ? metrics->corruptedVideoFrames : ~0u);
                digest.add(metrics ? metrics->displayCompositedVideoFrames : ~0u);
            }
        }
        return withDigest ? digest.value() : sum;
    });
}

// The displayed frame asked for 640000 times from a renderer holding 20 decoded frames at the paused time.
TEST(GPUMediaSampleBench, CurrentVideoFrame)
{
    Vector<RetainPtr<CMSampleBufferRef>> decoded;
    for (unsigned index = 0; index < 20; ++index)
        decoded.append(createDecodedVideoSample(index));
    ASSERT_FALSE(decoded.contains(nullptr));
    Replay replay(Replay::Mode::DecompressionSession);
    replay.enqueue(decoded.span());
    replay.waitFor([&] {
        return replay.hasFrame();
    });
    replay.settle();
    runShape("CurrentVideoFrame"_s, expectedCurrentVideoFrame, frameQueryCount * 64, [&](bool withDigest) {
        Digest digest;
        uint64_t sum = 0;
        for (unsigned query = 0; query < frameQueryCount; ++query) {
            RefPtr frame = replay.renderer().currentVideoFrame();
            if (frame)
                sum += frame->presentationSize().width();
            if (withDigest && !query)
                digest.add(StringView { replay.currentFrameString() });
        }
        return withDigest ? digest.value() : sum;
    });
}

// The image decoder's path: one sync sample of test.mp4 decoded 2500 times by a session of its own, with no queue.
TEST(GPUMediaSampleBench, DecodeSampleSync)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), 1u);
    ASSERT_TRUE(MediaSampleAVFObjC::create(samples[0].get(), 1)->isSync());
    constexpr unsigned decodeCount = 2500;
    Ref session = WebCoreDecompressionSession::createRGB(nullptr);
    runShape("DecodeSampleSync"_s, expectedDecodeSampleSync, decodeCount * sampleBytes(samples[0].get()), [&](bool withDigest) {
        Digest digest;
        uint64_t sum = 0;
        for (unsigned decode = 0; decode < decodeCount; ++decode) {
            RetainPtr pixelBuffer = session->decodeSampleSync(samples[0].get());
            if (pixelBuffer)
                sum += CVPixelBufferGetWidth(pixelBuffer.get());
            if (withDigest && !decode)
                digestPixelBuffer(digest, pixelBuffer.get());
        }
        return withDigest ? digest.value() : sum;
    });
    session->invalidate();
}

} // namespace TestWebKitAPI

#endif // USE(AVFOUNDATION)
