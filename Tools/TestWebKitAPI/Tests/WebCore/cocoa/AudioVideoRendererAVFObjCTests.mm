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

#include "Helpers/PlatformUtilities.h"
#include "Helpers/Utilities.h"
#include "Helpers/cocoa/TestNSBundleExtras.h"
#include <AVFoundation/AVFoundation.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <WebCore/AudioVideoRendererAVFObjC.h>
#include <WebCore/ContentType.h>
#include <WebCore/MediaPlayerEnums.h>
#include <WebCore/MediaSampleAVFObjC.h>
#include <WebCore/MediaSourceConfiguration.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/SourceBufferParser.h>
#include <WebCore/TrackInfo.h>
#include <WebCore/VideoFrame.h>
#include <wtf/Logger.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RunLoop.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

#include <pal/cf/CoreMediaSoftLink.h>
#include <pal/cocoa/AVFoundationSoftLink.h>

using namespace WebCore;

namespace TestWebKitAPI {

static RetainPtr<CMSampleBufferRef> createVideoSampleBuffer()
{
    CVPixelBufferRef rawPixelBuffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nullptr, &rawPixelBuffer))
        return nullptr;
    RetainPtr pixelBuffer = adoptCF(rawPixelBuffer);

    CMVideoFormatDescriptionRef rawFormatDescription = nullptr;
    if (PAL::CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer.get(), &rawFormatDescription))
        return nullptr;
    RetainPtr formatDescription = adoptCF(rawFormatDescription);

    CMSampleTimingInfo timing = { PAL::kCMTimeInvalid, PAL::kCMTimeZero, PAL::kCMTimeInvalid };
    CMSampleBufferRef rawSampleBuffer = nullptr;
    if (PAL::CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer.get(), true, nullptr, nullptr, formatDescription.get(), &timing, &rawSampleBuffer))
        return nullptr;

    return adoptCF(rawSampleBuffer);
}

static RetainPtr<CMSampleBufferRef> createAudioSampleBuffer()
{
    constexpr int32_t sampleRate = 44100;
    constexpr size_t frameCount = 128;
    constexpr size_t dataLength = frameCount * sizeof(float);
    // Backs a non-owning block buffer, so it has to outlive every sample buffer handed out here.
    static std::array<float, frameCount> silence { };

    AudioStreamBasicDescription streamDescription { };
    streamDescription.mSampleRate = sampleRate;
    streamDescription.mFormatID = kAudioFormatLinearPCM;
    streamDescription.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    streamDescription.mChannelsPerFrame = 1;
    streamDescription.mFramesPerPacket = 1;
    streamDescription.mBytesPerFrame = sizeof(float);
    streamDescription.mBytesPerPacket = sizeof(float);
    streamDescription.mBitsPerChannel = 8 * sizeof(float);

    CMAudioFormatDescriptionRef rawFormatDescription = nullptr;
    if (PAL::CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &streamDescription, 0, nullptr, 0, nullptr, nullptr, &rawFormatDescription))
        return nullptr;
    RetainPtr formatDescription = adoptCF(rawFormatDescription);

    CMBlockBufferRef rawBlockBuffer = nullptr;
    if (PAL::CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, silence.data(), dataLength, kCFAllocatorNull, nullptr, 0, dataLength, 0, &rawBlockBuffer))
        return nullptr;
    RetainPtr blockBuffer = adoptCF(rawBlockBuffer);

    // The format description is constant bitrate, so no per-sample size array is needed.
    CMSampleTimingInfo timing = { PAL::CMTimeMake(1, sampleRate), PAL::kCMTimeZero, PAL::kCMTimeInvalid };
    CMSampleBufferRef rawSampleBuffer = nullptr;
    if (PAL::CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuffer.get(), formatDescription.get(), frameCount, 1, &timing, 0, nullptr, &rawSampleBuffer))
        return nullptr;

    return adoptCF(rawSampleBuffer);
}

class AudioVideoRendererAVFObjCTest : public testing::Test {
public:
    void SetUp() final
    {
        Ref logger = Logger::create(this);
        renderer = AudioVideoRendererAVFObjC::create(logger, 0);
        renderer->setPreferences({ });
        renderer->notifyWhenRequiresFlushToResume([this] {
            ++flushToResumeCount;
        });
        renderer->notifyWhenErrorOccurs([this](PlatformMediaError error) {
            ++errorCount;
        });
        videoTrackId = renderer->addTrack(TrackInfo::TrackType::Video);
    }

    void TearDown() final
    {
        renderer = nullptr;
    }

    void enqueueVideoSample()
    {
        RetainPtr sampleBuffer = createVideoSampleBuffer();
        ASSERT_TRUE(sampleBuffer);
        renderer->enqueueSample(*videoTrackId, MediaSampleAVFObjC::create(sampleBuffer.get(), 0), { });
    }

    RefPtr<AudioVideoRenderer> renderer;
    std::optional<AudioVideoRenderer::TrackIdentifier> videoTrackId;
    int flushToResumeCount { 0 };
    int errorCount { 0 };
};

TEST_F(AudioVideoRendererAVFObjCTest, NoFlushWithoutEnqueuedSamples)
{
    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    renderer->renderingCanBeAcceleratedChanged(false);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);
}

TEST_F(AudioVideoRendererAVFObjCTest, NoFlushOnRendererDestroy)
{
    ASSERT_TRUE(videoTrackId.has_value());

    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    enqueueVideoSample();

    renderer->renderingCanBeAcceleratedChanged(false);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);
    EXPECT_EQ(errorCount, 0);
}

TEST_F(AudioVideoRendererAVFObjCTest, NoFlushOnProtectedContentVisibilityCycle)
{
    ASSERT_TRUE(videoTrackId.has_value());

    renderer->setHasProtectedVideoContent(true);
    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    enqueueVideoSample();

    renderer->renderingCanBeAcceleratedChanged(false);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);
    EXPECT_EQ(errorCount, 0);
}

TEST_F(AudioVideoRendererAVFObjCTest, NoFlushWithDecompressionSessionForProtectedContent)
{
    ASSERT_TRUE(videoTrackId.has_value());

    renderer->setPreferences({ VideoRendererPreference::PrefersDecompressionSession, VideoRendererPreference::UseDecompressionSessionForProtectedContent });
    renderer->setHasProtectedVideoContent(true);
    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    enqueueVideoSample();

    renderer->renderingCanBeAcceleratedChanged(false);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);

    renderer->renderingCanBeAcceleratedChanged(true);
    Util::runFor(0.1_s);
    EXPECT_EQ(flushToResumeCount, 0);
    EXPECT_EQ(errorCount, 0);
}

// A sample holding an image buffer is already decoded: it bypasses the decompression session.
TEST_F(AudioVideoRendererAVFObjCTest, AlreadyDecodedVideoSampleIsDisplayedWithoutDecompressionSession)
{
    ASSERT_TRUE(videoTrackId.has_value());

    bool hasFirstFrame = false;
    renderer->notifyFirstFrameAvailable([&] {
        hasFirstFrame = true;
    });
    renderer->renderingCanBeAcceleratedChanged(true);

    enqueueVideoSample();
    Util::runFor(0.5_s);

    EXPECT_TRUE(hasFirstFrame);
    EXPECT_EQ(flushToResumeCount, 0);
    EXPECT_EQ(errorCount, 0);

    renderer->flushTrack(*videoTrackId);
    Util::runFor(0.1_s);
    EXPECT_EQ(errorCount, 0);
}

// prepareToSeek's fast path is taken when the destination is within 1ms of the synchronizer's
// current time: the synchronizer isn't moved and no time jumped notification is awaited. These
// tests use an audio-only renderer because that is the only way to make
// allRenderersHaveAvailableSamples() — which gates the fast path — true synchronously; a video
// track would have to wait on a first decoded frame.
class AudioVideoRendererAVFObjCSeekTest : public testing::Test {
public:
    void SetUp() final
    {
        Ref logger = Logger::create(this);
        renderer = AudioVideoRendererAVFObjC::create(logger, 0);
        renderer->setPreferences({ });
        audioTrackId = renderer->addTrack(TrackInfo::TrackType::Audio);
    }

    void TearDown() final
    {
        renderer = nullptr;
    }

    void enqueueAudioSample()
    {
        RetainPtr sampleBuffer = createAudioSampleBuffer();
        ASSERT_TRUE(sampleBuffer);
        renderer->enqueueSample(*audioTrackId, MediaSampleAVFObjC::create(sampleBuffer.get(), 0), { });
    }

    std::optional<MediaTime> seekAndWaitForReportedTime(const MediaTime& seekTime)
    {
        std::optional<MediaTime> reportedTime;
        bool done = false;
        renderer->prepareToSeek(seekTime)->whenSettled(RunLoop::currentSingleton(), [&](MediaTimePromise::Result result) {
            if (result)
                reportedTime = *result;
            done = true;
        });
        Util::run(&done);
        return reportedTime;
    }

    RefPtr<AudioVideoRenderer> renderer;
    std::optional<AudioVideoRenderer::TrackIdentifier> audioTrackId;
};

TEST_F(AudioVideoRendererAVFObjCSeekTest, ShortForwardSeekReportsRequestedTime)
{
    ASSERT_TRUE(audioTrackId.has_value());
    enqueueAudioSample();

    // 1ms past the synchronizer's time, which is the furthest the fast path reaches.
    auto seekTime = MediaTime(1, 1000);
    auto reportedTime = seekAndWaitForReportedTime(seekTime);

    // A completed seek with a finite time means the fast path ran; the slow path leaves the
    // renderer seeking and resolves with an indefinite time.
    ASSERT_FALSE(renderer->seeking());
    ASSERT_TRUE(reportedTime.has_value());
    ASSERT_TRUE(reportedTime->isFinite());

    // The requested time, not the synchronizer's pre-seek time. Reporting the latter leaves
    // currentTime short of a forward seek, and a page nudging forward into a buffered range
    // re-seeks to the same place forever.
    EXPECT_EQ(*reportedTime, seekTime);
    EXPECT_GE(renderer->currentTime(), seekTime);
}

TEST_F(AudioVideoRendererAVFObjCSeekTest, ShortBackwardSeekReportsRequestedTime)
{
    ASSERT_TRUE(audioTrackId.has_value());
    enqueueAudioSample();

    // Park the synchronizer away from zero so there is room to seek backwards. This is far
    // enough to take the slow path, which moves the synchronizer synchronously.
    auto parkTime = MediaTime(100, 1000);
    EXPECT_TRUE(seekAndWaitForReportedTime(parkTime).has_value());
    ASSERT_TRUE(renderer->seeking());

    // Clear the pending seek without moving the synchronizer back, then restore sample
    // availability, which flush() dropped.
    renderer->flush();
    ASSERT_FALSE(renderer->seeking());
    enqueueAudioSample();

    auto seekTime = parkTime - MediaTime(1, 2000);
    auto reportedTime = seekAndWaitForReportedTime(seekTime);

    ASSERT_FALSE(renderer->seeking());
    ASSERT_TRUE(reportedTime.has_value());
    ASSERT_TRUE(reportedTime->isFinite());

    // A backward seek has to report the requested time too, so clamping the reported time up to
    // the synchronizer's would be just as wrong as leaving a forward seek short. currentTime is
    // not checked: lowering the time floor below the timebase is a no-op, so it stays at
    // parkTime until the synchronizer itself moves.
    EXPECT_EQ(*reportedTime, seekTime);
}


// The renderer replay harness. Real H.264 samples from test.mp4, and decoded frames, drive the renderer through fixed
// scripts with its timebase paused. Each script's trace of callbacks, metrics and displayed frames must match the one
// recorded from the C++ VideoMediaSampleRenderer, so any implementation of the video sample renderer is held to it.

// The video samples of a resource, compressed, in decode order.
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

// A decoded 16x16 frame at index / 30 s.
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

static String timeString(const MediaTime& time)
{
    if (!time.isValid())
        return "invalid"_s;
    return String::numberToStringFixedPrecision(time.toDouble(), 4);
}

class AudioVideoRendererReplay {
public:
    enum class Mode : uint8_t { DecompressionSession, Renderer };

    explicit AudioVideoRendererReplay(Mode mode, bool logging = true)
        : m_mode(mode)
    {
        Ref logger = Logger::create(this);
        logger->setEnabled(this, logging);
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

    ~AudioVideoRendererReplay()
    {
        m_renderer->shutdown();
        m_renderer = nullptr;
    }

    AudioVideoRenderer& renderer() { return *m_renderer; }
    AudioVideoRenderer::TrackIdentifier trackId() const { return *m_trackId; }

    // Enqueues samples as a client does: while the renderer is ready, and otherwise once it asks for more. Returns how
    // many it took before it stopped asking.
    size_t enqueue(std::span<const RetainPtr<CMSampleBufferRef>> samples)
    {
        size_t index = 0;
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
            m_renderer->enqueueSample(*m_trackId, MediaSampleAVFObjC::create(samples[index].get(), 1), std::nullopt);
            ++index;
        }
        return index;
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

    // The checkpoint's events since the last one, then the metrics and the displayed frame.
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

TEST(AudioVideoRendererAVFObjCReplay, CompressedSamplesThroughDecompressionSession)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), 30u);

    AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::DecompressionSession);
    auto all = std::span { samples };
    auto accepted = replay.enqueue(all);
    auto first = replay.checkpoint("paused at 0"_s);

    replay.renderer().flushTrack(replay.trackId());
    auto restart = firstSyncSampleAtOrAfter(samples.size() / 2);
    ASSERT_LT(restart, samples.size());
    replay.enqueue(all.subspan(restart, std::min<size_t>(8, samples.size() - restart)));
    auto second = replay.checkpoint("after track flush"_s);

    replay.renderer().flush();
    replay.enqueue(all.first(4));
    auto third = replay.checkpoint("after flush"_s);

    WTFLogAlways("AV1-REPLAY decompression accepted %zu of %zu\n%s\n%s\n%s", accepted, samples.size(), Util::toSTD(first).c_str(), Util::toSTD(second).c_str(), Util::toSTD(third).c_str());
    // When the renderer stops asking for samples, with the decoded queue full at the paused time, depends on when the
    // decoder finishes.
    EXPECT_GE(accepted, 30u);
    EXPECT_LE(accepted, 36u);
    EXPECT_STREQ(Util::toSTD(first).c_str(), "paused at 0: [firstFrame, frame 0] total 7 dropped 0 corrupted 0 presented 1; 0 320x240");
    EXPECT_STREQ(Util::toSTD(second).c_str(), "after track flush: [firstFrame, frame 3.187] total 14 dropped 0 corrupted 0 presented 2; 3.187 320x240");
    EXPECT_STREQ(Util::toSTD(third).c_str(), "after flush: [firstFrame, frame 0] total 18 dropped 0 corrupted 0 presented 3; 0 320x240");
}

TEST(AudioVideoRendererAVFObjCReplay, DecodedSamples)
{
    Vector<RetainPtr<CMSampleBufferRef>> samples;
    for (unsigned index = 0; index < 20; ++index)
        samples.append(createDecodedVideoSample(index));

    AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::DecompressionSession);
    auto accepted = replay.enqueue(samples.span());
    auto first = replay.checkpoint("decoded, paused at 0"_s);

    replay.renderer().flushTrack(replay.trackId());
    replay.enqueue(samples.subspan(10, 5));
    auto second = replay.checkpoint("decoded, after track flush"_s);

    // Compressed samples after decoded ones follow them through the renderer's queue.
    auto& compressed = compressedVideoSamples();
    ASSERT_GT(compressed.size(), 30u);
    replay.renderer().flushTrack(replay.trackId());
    replay.enqueue(samples.span().first(3));
    replay.enqueue(std::span { compressed }.first(6));
    auto third = replay.checkpoint("decoded then compressed"_s);

    WTFLogAlways("AV1-REPLAY decoded accepted %zu\n%s\n%s\n%s", accepted, Util::toSTD(first).c_str(), Util::toSTD(second).c_str(), Util::toSTD(third).c_str());
    EXPECT_EQ(accepted, 20u);
    EXPECT_STREQ(Util::toSTD(first).c_str(), "decoded, paused at 0: [firstFrame, frame 0] total 20 dropped 0 corrupted 0 presented 1; 0 16x16");
    EXPECT_STREQ(Util::toSTD(second).c_str(), "decoded, after track flush: [firstFrame, frame 0.3333] total 25 dropped 0 corrupted 0 presented 2; 0.3333 16x16");
    EXPECT_STREQ(Util::toSTD(third).c_str(), "decoded then compressed: [firstFrame, frame 0] total 34 dropped 0 corrupted 0 presented 3; 0 16x16");
}

TEST(AudioVideoRendererAVFObjCReplay, CompressedSamplesThroughRenderer)
{
    auto& samples = compressedVideoSamples();
    ASSERT_GT(samples.size(), 30u);

    AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::Renderer);
    auto accepted = replay.enqueue(std::span { samples }.first(30));
    auto first = replay.checkpoint("renderer, paused at 0"_s);

    replay.renderer().flushTrack(replay.trackId());
    replay.enqueue(std::span { samples }.first(10));
    auto second = replay.checkpoint("renderer, after track flush"_s);

    WTFLogAlways("AV1-REPLAY renderer accepted %zu\n%s\n%s", accepted, Util::toSTD(first).c_str(), Util::toSTD(second).c_str());
    EXPECT_EQ(accepted, 30u);
    EXPECT_STREQ(Util::toSTD(first).c_str(), "renderer, paused at 0: [firstFrame] total 30 dropped 0 corrupted 0; no frame");
    EXPECT_STREQ(Util::toSTD(second).c_str(), "renderer, after track flush: [firstFrame] total 40 dropped 0 corrupted 0; no frame");
}

#if ENABLE(MEDIA_SOURCE)
// The video samples of test-vp8.webm, as the WebM parser gives them.
static Vector<RetainPtr<CMSampleBufferRef>> vp8VideoSamples()
{
    Vector<RetainPtr<CMSampleBufferRef>> samples;
    RetainPtr fileData = [NSData dataWithContentsOfURL:[NSBundle.test_resourcesBundle URLForResource:@"test-vp8" withExtension:@"webm"]];
    if (!fileData)
        return samples;
    RefPtr parser = SourceBufferParser::create(ContentType { "video/webm; codecs=vp8"_s }, MediaSourceConfiguration { });
    if (!parser)
        return samples;
    parser->setCallOnClientThreadCallback([](auto&& function) {
        function();
    });
    parser->setDidProvideMediaDataCallback([&](Ref<MediaSampleAVFObjC>&& sample, uint64_t, const String&) {
        RetainPtr sampleBuffer = sample->platformSample().cmSampleBuffer();
        RetainPtr formatDescription = PAL::CMSampleBufferGetFormatDescription(sampleBuffer.get());
        if (formatDescription && PAL::CMFormatDescriptionGetMediaType(formatDescription.get()) == kCMMediaType_Video)
            samples.append(WTF::move(sampleBuffer));
    });
    if (!parser->appendData(SharedBuffer::create(fileData.get())))
        return { };
    parser->flushPendingMediaData();
    return samples;
}

// VP8 has no hardware decoder: with a renderer, its samples still go through the decompression session.
TEST(AudioVideoRendererAVFObjCReplay, VP8SamplesThroughRenderer)
{
    auto samples = vp8VideoSamples();
    ASSERT_GT(samples.size(), 10u);

    AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::Renderer);
    auto accepted = replay.enqueue(samples.span().first(10));
    auto first = replay.checkpoint("vp8, paused at 0"_s);

    replay.renderer().flushTrack(replay.trackId());
    replay.enqueue(samples.span().first(4));
    auto second = replay.checkpoint("vp8, after track flush"_s);

    WTFLogAlways("AV1-REPLAY vp8 accepted %zu of %zu\n%s\n%s", accepted, samples.size(), Util::toSTD(first).c_str(), Util::toSTD(second).c_str());
    EXPECT_EQ(accepted, 10u);
    EXPECT_STREQ(Util::toSTD(first).c_str(), "vp8, paused at 0: [firstFrame] total 7 dropped 0 corrupted 0; 0 320x240");
    EXPECT_STREQ(Util::toSTD(second).c_str(), "vp8, after track flush: [firstFrame] total 11 dropped 0 corrupted 0; 0 320x240");
}
#endif

// Seeded scripts of enqueues, flushes and checkpoints, with the timebase paused. Prints one trace per seed, to compare
// two builds' traces (for example a WebCore with another implementation of the video sample renderer).
TEST(AudioVideoRendererAVFObjCReplay, ScriptedTraces)
{
    auto& compressed = compressedVideoSamples();
    ASSERT_GT(compressed.size(), 30u);
    Vector<size_t> syncIndices;
    for (size_t index = 0; index < compressed.size(); ++index) {
        if (MediaSampleAVFObjC::create(compressed[index].get(), 1)->isSync())
            syncIndices.append(index);
    }
    ASSERT_FALSE(syncIndices.isEmpty());

    unsigned seeds = 4;
    if (auto* value = getenv("AV1_TRACE_SEEDS"))
        seeds = std::max(1, atoi(value));
    for (unsigned seed = 1; seed <= seeds; ++seed) {
        uint32_t state = seed * 2654435761u;
        auto next = [&](uint32_t bound) {
            state = state * 1664525u + 1013904223u;
            return (state >> 8) % bound;
        };
        AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::DecompressionSession);
        size_t nextCompressed = syncIndices[0];
        unsigned nextDecoded = 0;
        StringBuilder trace;
        for (unsigned step = 0; step < 12; ++step) {
            switch (next(5)) {
            case 0: {
                auto count = std::min<size_t>(1 + next(8), compressed.size() - nextCompressed);
                replay.enqueue(std::span { compressed }.subspan(nextCompressed, count));
                nextCompressed += count;
                if (nextCompressed >= compressed.size())
                    nextCompressed = syncIndices[0];
                trace.append('c', count, ' ');
                break;
            }
            case 1:
                replay.renderer().flushTrack(replay.trackId());
                nextCompressed = syncIndices[next(syncIndices.size())];
                trace.append("ft "_s);
                break;
            case 2:
                replay.renderer().flush();
                nextCompressed = syncIndices[0];
                trace.append("f "_s);
                break;
            case 3: {
                auto count = 1 + next(5);
                Vector<RetainPtr<CMSampleBufferRef>> decoded;
                for (unsigned index = 0; index < count; ++index)
                    decoded.append(createDecodedVideoSample(nextDecoded++));
                replay.enqueue(decoded.span());
                trace.append('d', count, ' ');
                break;
            }
            default:
                trace.append("| "_s, replay.checkpoint("cp"_s), " | "_s);
                break;
            }
            replay.settle();
        }
        trace.append("| "_s, replay.checkpoint("end"_s));
        WTFLogAlways("AV1-TRACE seed %u: %s", seed, Util::toSTD(trace.toString()).c_str());
    }
}

// The main thread's cost per enqueued sample, and the time each sample takes to reach the renderer's queue and be
// processed there, as the median of five runs. Printed, not checked: compare the numbers across builds.
static double medianOf(Vector<double>&& values)
{
    std::sort(values.begin(), values.end());
    return values[values.size() / 2];
}

TEST(AudioVideoRendererAVFObjCReplay, PerSampleCost)
{
    Vector<RetainPtr<CMSampleBufferRef>> decoded;
    for (unsigned index = 0; index < 600; ++index)
        decoded.append(createDecodedVideoSample(index));
    auto& compressed = compressedVideoSamples();
    ASSERT_GT(compressed.size(), 30u);

    Vector<double> decodedEnqueue;
    Vector<double> decodedEndToEnd;
    Vector<double> compressedEnqueue;
    for (unsigned run = 0; run < 5; ++run) {
        {
            AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::DecompressionSession, false);
            Seconds inEnqueue;
            auto start = MonotonicTime::now();
            for (auto& sample : decoded) {
                Ref mediaSample = MediaSampleAVFObjC::create(sample.get(), 1);
                auto before = MonotonicTime::now();
                replay.renderer().enqueueSample(replay.trackId(), WTF::move(mediaSample), std::nullopt);
                inEnqueue += MonotonicTime::now() - before;
            }
            Util::waitFor([&] {
                Util::runFor(0.001_s);
                auto metrics = replay.renderer().videoPlaybackQualityMetrics();
                return metrics && metrics->totalVideoFrames >= decoded.size();
            }, 5000);
            decodedEndToEnd.append((MonotonicTime::now() - start).microseconds() * 1000 / decoded.size());
            decodedEnqueue.append(inEnqueue.microseconds() * 1000 / decoded.size());
        }
        {
            AudioVideoRendererReplay replay(AudioVideoRendererReplay::Mode::DecompressionSession, false);
            Seconds inEnqueue;
            size_t count = std::min<size_t>(compressed.size(), 24);
            for (size_t index = 0; index < count; ++index) {
                Ref mediaSample = MediaSampleAVFObjC::create(compressed[index].get(), 1);
                auto before = MonotonicTime::now();
                replay.renderer().enqueueSample(replay.trackId(), WTF::move(mediaSample), std::nullopt);
                inEnqueue += MonotonicTime::now() - before;
            }
            compressedEnqueue.append(inEnqueue.microseconds() * 1000 / count);
            replay.settle();
        }
    }
    WTFLogAlways("AV1-BENCH decoded enqueue %.0f ns/sample, decoded end-to-end %.0f ns/sample, compressed enqueue %.0f ns/sample", medianOf(WTF::move(decodedEnqueue)), medianOf(WTF::move(decodedEndToEnd)), medianOf(WTF::move(compressedEnqueue)));
}

} // namespace TestWebKitAPI

#endif // USE(AVFOUNDATION)
