/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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
#include "Utilities.h"
#include <Accelerate/Accelerate.h>
#include <WebCore/AudioOutputUnit.h>
#include <WebCore/CAAudioStreamDescription.h>
#include <WebCore/CARingBuffer.h>
#include <mach/mach.h>
#include <random>
#include <wtf/FixedVector.h>
#include <wtf/MainThread.h>
#include <wtf/Threading.h>
#include <wtf/Vector.h>

using namespace WebCore;

namespace TestWebKitAPI {

// Deinterleaved Float32 buffers, one per channel, each of its own byte size.
class TestBufferList {
public:
    explicit TestBufferList(const Vector<uint32_t>& byteSizes)
        : m_storage(byteSizes.size())
        , m_list(static_cast<AudioBufferList*>(::operator new(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * std::max<size_t>(1, byteSizes.size()))))
    {
        m_list->mNumberBuffers = byteSizes.size();
        for (size_t i = 0; i < byteSizes.size(); ++i) {
            m_storage[i] = Vector<uint8_t>(FillWith { }, static_cast<size_t>(byteSizes[i]) + 16, static_cast<uint8_t>(0xA5));
            m_list->mBuffers[i] = { 1, byteSizes[i], m_storage[i].mutableSpan().data() };
        }
    }
    ~TestBufferList() { ::operator delete(m_list); }

    AudioBufferList& list() { return *m_list; }
    std::span<const uint8_t> bytes(size_t index) const { return m_storage[index].span(); }
    float sample(size_t channel, size_t frame) const
    {
        float value;
        memcpy(&value, m_storage[channel].span().subspan(frame * sizeof(float)).data(), sizeof(float));
        return value;
    }

private:
    Vector<Vector<uint8_t>> m_storage;
    AudioBufferList* m_list;
};

class AudioOutputUnitTest : public testing::Test {
public:
    void SetUp() final
    {
        WTF::initializeMainThread();
        semaphore_create(mach_task_self(), &m_semaphore, SYNC_POLICY_FIFO, 0);
    }

    void TearDown() final
    {
        semaphore_destroy(mach_task_self(), m_semaphore);
    }

    std::unique_ptr<InProcessCARingBuffer> makeRing(uint32_t channels, size_t frameCount)
    {
        return InProcessCARingBuffer::allocate(CAAudioStreamDescription(44100, channels, CAAudioStreamDescription::PCMFormat::Float32, CAAudioStreamDescription::IsInterleaved::No), frameCount);
    }

    // How many times the unit signaled the semaphore since the last call.
    unsigned takeSignals()
    {
        unsigned count = 0;
        while (semaphore_timedwait(m_semaphore, { 0, 0 }) == KERN_SUCCESS)
            ++count;
        return count;
    }

    semaphore_t semaphore() const { return m_semaphore; }

private:
    semaphore_t m_semaphore { SEMAPHORE_NULL };
};

static void runOffMainThread(Function<void()>&& function)
{
    Thread::create("AudioOutputUnitTest"_s, WTF::move(function))->waitForCompletion();
}

static void storeRamp(CARingBuffer& ring, uint32_t channels, uint64_t startFrame, uint32_t frameCount)
{
    Vector<uint32_t> sizes(FillWith { }, static_cast<size_t>(channels), static_cast<uint32_t>(frameCount * sizeof(float)));
    TestBufferList source { sizes };
    for (uint32_t channel = 0; channel < channels; ++channel) {
        for (uint32_t frame = 0; frame < frameCount; ++frame) {
            float value = (channel + 1) * 1000.f + startFrame + frame;
            static_cast<float*>(source.list().mBuffers[channel].mData)[frame] = value;
        }
    }
    ring.store(&source.list(), frameCount, startFrame);
}

TEST_F(AudioOutputUnitTest, RemoteDestinationPlaysOutTheRingThroughAGenericOutputUnit)
{
    constexpr uint32_t channels = 2;
    auto ring = makeRing(channels, 1024);
    AudioOutputUnit unit { AudioOutputUnit::Kind::GenericOutputForTesting, 44100, channels };
    alignas(4) std::array<uint8_t, 4> counter { };
    unit.attachRing(ring.get(), counter, semaphore());

    runOffMainThread([&] {
        storeRamp(*ring, channels, 0, 512);
        for (uint32_t quantum = 0; quantum < 4; ++quantum) {
            TestBufferList output { { 128 * sizeof(float), 128 * sizeof(float) } };
            EXPECT_EQ(unit.renderForTesting(output.list(), 128, quantum * 128., true), noErr);
            for (uint32_t channel = 0; channel < channels; ++channel) {
                for (uint32_t frame = 0; frame < 128; ++frame)
                    EXPECT_EQ(output.sample(channel, frame), (channel + 1) * 1000.f + quantum * 128 + frame);
            }
        }
    });
    uint32_t frames;
    memcpy(&frames, counter.data(), sizeof(frames));
    EXPECT_EQ(frames, 512u);
    EXPECT_EQ(takeSignals(), 4u);
}

TEST_F(AudioOutputUnitTest, RemoteDestinationFadesOutOnAnUnderrun)
{
    constexpr uint32_t channels = 1;
    auto ring = makeRing(channels, 256);
    AudioOutputUnit unit { AudioOutputUnit::Kind::GenericOutputForTesting, 44100, channels };
    unit.attachRing(ring.get(), { }, semaphore());

    runOffMainThread([&] {
        storeRamp(*ring, channels, 0, 64);
        TestBufferList first { { 64 * sizeof(float) } };
        EXPECT_EQ(unit.renderForTesting(first.list(), 64, 0, false), noErr);
        float last = first.sample(0, 63);
        EXPECT_EQ(last, 1063.f);

        TestBufferList underrun { { 64 * sizeof(float) } };
        EXPECT_EQ(unit.renderForTesting(underrun.list(), 64, 64, false), -1);
        float step = last / 64;
        float value = last;
        for (uint32_t frame = 0; frame < 64; ++frame) {
            value -= step;
            EXPECT_EQ(underrun.sample(0, frame), value);
        }

        TestBufferList silent { { 64 * sizeof(float) } };
        EXPECT_EQ(unit.renderForTesting(silent.list(), 64, 128, false), -1);
        for (uint32_t frame = 0; frame < 64; ++frame)
            EXPECT_EQ(silent.sample(0, frame), 0.f);
    });
    EXPECT_EQ(takeSignals(), 3u);
}

TEST_F(AudioOutputUnitTest, RemoteDestinationWithoutARingRendersNothing)
{
    AudioOutputUnit unit { AudioOutputUnit::Kind::GenericOutputForTesting, 44100, 1 };
    alignas(4) std::array<uint8_t, 4> counter { };
    unit.attachRing(nullptr, counter, semaphore());
    runOffMainThread([&] {
        TestBufferList output { { 64 * sizeof(float) } };
        EXPECT_EQ(unit.renderForTesting(output.list(), 64, 0, false), -1);
        EXPECT_EQ(output.bytes(0)[0], 0xA5);
    });
    uint32_t frames;
    memcpy(&frames, counter.data(), sizeof(frames));
    EXPECT_EQ(frames, 0u);
    EXPECT_EQ(takeSignals(), 0u);
}

TEST_F(AudioOutputUnitTest, StartAndStopInProcessDestination)
{
    AudioOutputUnit unit { AudioOutputUnit::Kind::InProcessDestination, 44100, 2 };
    unit.attachRenderCallback([](void*, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32, AudioBufferList*) -> OSStatus {
        return noErr;
    }, nullptr);
    EXPECT_EQ(unit.stop(), noErr);
    EXPECT_GE(unit.outputLatency(), 0u);
}

// The C++ that rendered a GPU-process audio destination's quantum before it moved to Swift (RemoteAudioDestination::render()
// and its helpers), over the same ring API, as the oracle for the Swift render callback.
class ReferenceDestination {
public:
    ReferenceDestination(CARingBuffer& ring, uint32_t channels)
        : m_ringBuffer(&ring)
        , m_lastRenderedSamples(channels)
    {
        m_lastRenderedSamples.fill(0.f);
    }

    OSStatus render(UInt32 numberOfFrames, AudioBufferList* ioData)
    {
        OSStatus status = -1;
        if (!m_ringBuffer)
            return status;

        if (m_ringBuffer->fetchIfHasEnoughData(ioData, numberOfFrames, m_startFrame)) {
            m_startFrame += numberOfFrames;
            rememberLastRenderedSamples(ioData, numberOfFrames);
            status = noErr;
        } else
            fadeOutToSilence(ioData, numberOfFrames);

        m_frameCount += numberOfFrames;
        ++m_signals;
        return status;
    }

    uint32_t frameCount() const { return m_frameCount; }
    unsigned signals() const { return m_signals; }

private:
    void rememberLastRenderedSamples(AudioBufferList* ioData, UInt32 numberOfFrames)
    {
        if (!numberOfFrames)
            return;

        auto buffers = unsafeMakeSpan(ioData->mBuffers, ioData->mNumberBuffers);
        for (size_t channel = 0; channel < m_lastRenderedSamples.size(); ++channel) {
            if (channel >= buffers.size())
                break;
            auto samples = unsafeMakeSpan(static_cast<float*>(buffers[channel].mData), buffers[channel].mDataByteSize / sizeof(float));
            auto frameCount = std::min<size_t>(numberOfFrames, samples.size());
            m_lastRenderedSamples[channel] = frameCount ? samples[frameCount - 1] : 0.f;
        }
    }

    void fadeOutToSilence(AudioBufferList* ioData, UInt32 numberOfFrames)
    {
        auto buffers = unsafeMakeSpan(ioData->mBuffers, ioData->mNumberBuffers);
        for (size_t channel = 0; channel < buffers.size(); ++channel) {
            auto samples = unsafeMakeSpan(static_cast<float*>(buffers[channel].mData), buffers[channel].mDataByteSize / sizeof(float));
            auto frameCount = std::min<size_t>(numberOfFrames, samples.size());
            float startSample = channel < m_lastRenderedSamples.size() ? m_lastRenderedSamples[channel] : 0.f;
            size_t frame = 0;
            if (startSample && frameCount) {
                float step = startSample / frameCount;
                float value = startSample;
                for (; frame < frameCount; ++frame) {
                    value -= step;
                    samples[frame] = value;
                }
            }
            std::fill(samples.begin() + frame, samples.end(), 0.f);
        }
        m_lastRenderedSamples.fill(0.f);
    }

    CARingBuffer* m_ringBuffer;
    uint64_t m_startFrame { 0 };
    FixedVector<float> m_lastRenderedSamples;
    uint32_t m_frameCount { 0 };
    unsigned m_signals { 0 };
};

TEST_F(AudioOutputUnitTest, RemoteDestinationRendersAsTheCxxDid)
{
    unsigned caseCount = 300;
    if (auto* cases = getenv("AUDIO_OUTPUT_UNIT_CASES"))
        caseCount = atoi(cases);
    for (unsigned seed = 1; seed <= caseCount; ++seed) {
        std::mt19937_64 random(seed);
        auto pick = [&](uint64_t bound) { return bound ? random() % bound : 0; };
        uint32_t channels = 1 + pick(3);
        size_t ringFrames = size_t { 16 } << pick(5);
        auto ring = makeRing(channels, ringFrames);
        AudioOutputUnit unit { AudioOutputUnit::Kind::GenericOutputForTesting, 44100, channels };
        alignas(4) std::array<uint8_t, 4> counter { };
        unit.attachRing(ring.get(), counter, semaphore());
        ReferenceDestination reference { *ring, channels };

        runOffMainThread([&] {
            uint64_t writeFrame = pick(4) ? 0 : pick(64);
            for (unsigned step = 0; step < 40; ++step) {
                if (pick(3)) {
                    uint32_t frames = 1 + pick(ringFrames + 8);
                    Vector<uint32_t> sizes(FillWith { }, static_cast<size_t>(channels), static_cast<uint32_t>(frames * sizeof(float)));
                    TestBufferList source { sizes };
                    for (uint32_t channel = 0; channel < channels; ++channel) {
                        auto* samples = static_cast<uint32_t*>(source.list().mBuffers[channel].mData);
                        for (uint32_t frame = 0; frame < frames; ++frame)
                            samples[frame] = pick(10) ? std::bit_cast<uint32_t>(static_cast<float>(pick(2001)) - 1000.f) : static_cast<uint32_t>(random());
                    }
                    ring->store(&source.list(), frames, writeFrame);
                    writeFrame += frames + (pick(6) ? 0 : pick(40));
                    if (!pick(20))
                        writeFrame = pick(writeFrame + 1);
                }
                uint32_t frames = pick(8) ? pick(300) : 0;
                Vector<uint32_t> sizes;
                for (uint32_t channel = 0; channel < channels; ++channel)
                    sizes.append(pick(4) ? frames * sizeof(float) : pick(frames * sizeof(float) + 9));
                TestBufferList expected { sizes };
                TestBufferList actual { sizes };
                auto expectedStatus = reference.render(frames, &expected.list());
                auto actualStatus = unit.renderForTesting(actual.list(), frames, 0, false);
                EXPECT_EQ(actualStatus, expectedStatus) << "seed " << seed << " step " << step;
                for (uint32_t channel = 0; channel < channels; ++channel) {
                    EXPECT_EQ(actual.list().mBuffers[channel].mDataByteSize, expected.list().mBuffers[channel].mDataByteSize) << "seed " << seed << " step " << step;
                    EXPECT_TRUE(std::ranges::equal(actual.bytes(channel), expected.bytes(channel))) << "seed " << seed << " step " << step << " channel " << channel;
                }
                if (::testing::Test::HasFailure())
                    return;
            }
        });
        uint32_t frames;
        memcpy(&frames, counter.data(), sizeof(frames));
        EXPECT_EQ(frames, reference.frameCount()) << "seed " << seed;
        EXPECT_EQ(takeSignals(), reference.signals()) << "seed " << seed;
        if (::testing::Test::HasFailure())
            return;
    }
}

// The C++ that rendered a GPU-process track renderer's quantum before it moved to Swift: the timeline check of
// LocalAudioMediaStreamTrackRendererInternalUnit::render(), RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit::render()
// over the same ring API, and the clipping of Float32 samples.
class ReferenceTrack {
public:
    ReferenceTrack(CARingBuffer& ring, uint64_t frameChunkSize, uint64_t bytesPerFrame)
        : m_ringBuffer(ring)
        , m_frameChunkSize(frameChunkSize)
        , m_bytesPerFrame(bytesPerFrame)
    {
    }

    OSStatus render(UInt32 sampleCount, AudioBufferList& list, double sampleTime, AudioUnitRenderActionFlags& flags, bool checkTimelineAndClip)
    {
        if (checkTimelineAndClip) {
            if (m_sampleTime && (m_sampleTime + 2 * sampleCount < sampleTime || sampleTime <= m_sampleTime))
                ++m_resets;
            m_sampleTime = sampleTime < std::numeric_limits<Float64>::max() - sampleCount ? sampleTime : 0;
        }

        bool fetched = m_ringBuffer.fetchIfHasEnoughData(&list, sampleCount, m_readOffset);
        if (fetched)
            m_readOffset += sampleCount;
        uint64_t requestedSampleCount = m_generateOffset;
        while (requestedSampleCount < sampleCount) {
            requestedSampleCount += m_frameChunkSize;
            ++m_signals;
        }
        m_generateOffset = requestedSampleCount - sampleCount;
        if (!fetched) {
            for (auto& buffer : unsafeMakeSpan(list.mBuffers, list.mNumberBuffers))
                memset(buffer.mData, 0, static_cast<size_t>(sampleCount * m_bytesPerFrame));
            flags = kAudioUnitRenderAction_OutputIsSilence;
        }

        if (checkTimelineAndClip) {
            for (auto& buffer : unsafeMakeSpan(list.mBuffers, list.mNumberBuffers)) {
                float minimum = -1;
                float maximum = 1;
                vDSP_vclip(static_cast<float*>(buffer.mData), 1, &minimum, &maximum, static_cast<float*>(buffer.mData), 1, buffer.mDataByteSize / sizeof(float));
            }
        }
        return fetched ? noErr : -1;
    }

    unsigned signals() const { return m_signals; }
    unsigned resets() const { return m_resets; }

private:
    CARingBuffer& m_ringBuffer;
    uint64_t m_frameChunkSize;
    uint64_t m_bytesPerFrame;
    uint64_t m_readOffset { 0 };
    uint64_t m_generateOffset { 0 };
    uint64_t m_sampleTime { 0 };
    unsigned m_signals { 0 };
    unsigned m_resets { 0 };
};

static AudioStreamBasicDescription float32Format(uint32_t channels)
{
    return CAAudioStreamDescription(44100, channels, CAAudioStreamDescription::PCMFormat::Float32, CAAudioStreamDescription::IsInterleaved::No).streamDescription();
}

TEST_F(AudioOutputUnitTest, TrackRendererRendersAsTheCxxDid)
{
    unsigned caseCount = 200;
    if (auto* cases = getenv("AUDIO_OUTPUT_UNIT_CASES"))
        caseCount = atoi(cases);
    for (unsigned seed = 1; seed <= caseCount; ++seed) {
        std::mt19937_64 random(seed);
        auto pick = [&](uint64_t bound) { return bound ? random() % bound : 0; };
        uint32_t channels = 1 + pick(2);
        size_t ringFrames = size_t { 64 } << pick(4);
        auto ring = makeRing(channels, ringFrames);
        uint64_t frameChunkSize = 128 + pick(400);
        auto renderer = AudioOutputUnit::createTrackRenderer(0, 44100, float32Format(channels), true);
        ASSERT_TRUE(!!renderer.unit) << "step " << renderer.failedStep << " status " << renderer.status;
        AudioTrackPlayout track;
        track.attachRing(ring.get(), semaphore(), frameChunkSize, sizeof(float));
        renderer.unit->attachTrackPlayout(track);
        ReferenceTrack reference { *ring, frameChunkSize, sizeof(float) };
        bool useSpeakerPath = !pick(4);
        // The capture unit's speaker plays out the track once the main thread has told the track's producer.
        auto capture = AudioCaptureUnitHandle::create(AudioCaptureUnitHandle::Kind::MockWithEchoCancellation);
        ASSERT_TRUE(!!capture.unit);
        capture.unit->configureSpeaker(44100, float32Format(channels));
        capture.unit->attach(nullptr, &track);
        capture.unit->setSwitch(AudioCaptureUnitHandle::Switch::SpeakerStartAcknowledged, true);

        runOffMainThread([&] {
            uint64_t writeFrame = 0;
            double sampleTime = 1 + pick(1000);
            for (unsigned step = 0; step < 40; ++step) {
                if (pick(3)) {
                    uint32_t frames = 1 + pick(ringFrames);
                    Vector<uint32_t> sizes(FillWith { }, static_cast<size_t>(channels), static_cast<uint32_t>(frames * sizeof(float)));
                    TestBufferList source { sizes };
                    for (uint32_t channel = 0; channel < channels; ++channel) {
                        auto* samples = static_cast<uint32_t*>(source.list().mBuffers[channel].mData);
                        for (uint32_t frame = 0; frame < frames; ++frame)
                            samples[frame] = pick(10) ? std::bit_cast<uint32_t>((static_cast<float>(pick(4001)) - 2000.f) / 1000.f) : static_cast<uint32_t>(random());
                    }
                    ring->store(&source.list(), frames, writeFrame);
                    writeFrame += frames;
                }
                uint32_t frames = 1 + pick(256);
                Vector<uint32_t> sizes(FillWith { }, static_cast<size_t>(channels), static_cast<uint32_t>(frames * sizeof(float) + 4 * pick(3)));
                TestBufferList expected { sizes };
                TestBufferList actual { sizes };
                AudioUnitRenderActionFlags expectedFlags = 0;
                AudioUnitRenderActionFlags actualFlags = 0;
                auto expectedStatus = reference.render(frames, expected.list(), sampleTime, expectedFlags, !useSpeakerPath);
                auto actualStatus = useSpeakerPath ? capture.unit->renderSpeakerForTesting(actual.list(), frames, sampleTime, &actualFlags) : renderer.unit->renderForTesting(actual.list(), frames, sampleTime, false, &actualFlags);
                EXPECT_EQ(actualStatus, expectedStatus) << "seed " << seed << " step " << step;
                EXPECT_EQ(actualFlags, expectedFlags) << "seed " << seed << " step " << step;
                for (uint32_t channel = 0; channel < channels; ++channel) {
                    EXPECT_EQ(actual.list().mBuffers[channel].mDataByteSize, expected.list().mBuffers[channel].mDataByteSize) << "seed " << seed << " step " << step;
                    EXPECT_TRUE(std::ranges::equal(actual.bytes(channel), expected.bytes(channel))) << "seed " << seed << " step " << step << " channel " << channel;
                }
                if (::testing::Test::HasFailure())
                    return;
                sampleTime += pick(12) ? frames : pick(4 * frames);
            }
        });
        EXPECT_EQ(takeSignals(), reference.signals()) << "seed " << seed;
        if (::testing::Test::HasFailure())
            return;
    }
}

TEST_F(AudioOutputUnitTest, TrackRendererResetsOnTheMainThreadWhenItsTimelineJumps)
{
    auto ring = makeRing(1, 1024);
    auto renderer = AudioOutputUnit::createTrackRenderer(0, 44100, float32Format(1), true);
    ASSERT_TRUE(!!renderer.unit);
    AudioTrackPlayout track;
    track.attachRing(ring.get(), semaphore(), 441, sizeof(float));
    renderer.unit->attachTrackPlayout(track);
    unsigned resets = 0;
    renderer.unit->setEventHandler([&](OptionSet<AudioOutputUnit::Event> events) {
        EXPECT_TRUE(isMainThread());
        if (events.contains(AudioOutputUnit::Event::TimelineDiscontinuity))
            ++resets;
    });

    auto render = [&](double sampleTime) {
        runOffMainThread([&] {
            TestBufferList output { { 128 * sizeof(float) } };
            renderer.unit->renderForTesting(output.list(), 128, sampleTime, false);
        });
    };
    render(128);
    render(256);
    render(384);
    Util::runFor(0.1_s);
    EXPECT_EQ(resets, 0u);

    render(4096);
    for (unsigned i = 0; i < 500 && resets < 1; ++i)
        Util::runFor(10_ms);
    EXPECT_EQ(resets, 1u);

    render(4096 + 128);
    render(1000);
    for (unsigned i = 0; i < 500 && resets < 2; ++i)
        Util::runFor(10_ms);
    EXPECT_EQ(resets, 2u);
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)
