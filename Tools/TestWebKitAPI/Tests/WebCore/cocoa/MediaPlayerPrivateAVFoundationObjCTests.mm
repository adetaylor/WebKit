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

#include "Helpers/PlatformUtilities.h"
#include "Helpers/cocoa/TestNSBundleExtras.h"
#include <WebCore/MediaPlayerPrivateAVFoundationObjC.h>
#include <WebCoreTestSupport/WebCoreTestSupport.h>
#include <wtf/Identified.h>
#include <wtf/text/StringBuilder.h>

namespace TestWebKitAPI {

class MediaPlayerPrivateAVFoundationObjCTest
    : public testing::Test
    , public WebCore::MediaPlayerClient
    , public Identified<WebCore::MediaPlayerClientIdentifier> {
public:
    // Pretend to be reference counted:
    void ref() const final { }
    void deref() const final { }

    // MediaPlayerPrivateInterface:
    WebCore::MediaPlayerClientIdentifier mediaPlayerClientIdentifier() const { return identifier(); }

    // testing::Test:
    void SetUp() final
    {
        mediaPlayer = WebCore::MediaPlayer::create(*this, WebCore::MediaPlayerMediaEngineIdentifier::AVFoundation);
    }

    void TearDown() final
    {
        mediaPlayer = nullptr;
    }

    // Utility methods:
    RefPtr<WebCore::MediaPlayerPrivateAVFoundationObjC> playerPrivate() const
    {
        if (mediaPlayer)
            return dynamicDowncast<WebCore::MediaPlayerPrivateAVFoundationObjC>(mediaPlayer->playerPrivate());
        return nullptr;
    }

    URL videoWithAudioURL() const
    {
        return [NSBundle.test_resourcesBundle URLForResource:@"video-with-audio" withExtension:@"mp4"];
    }

    URL videoWithoutAudioURL() const
    {
        return [NSBundle.test_resourcesBundle URLForResource:@"video-without-audio" withExtension:@"mp4"];
    }

    void waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState readyState)
    {
        Util::waitFor([&] { return mediaPlayer->readyState() > readyState; });
        EXPECT_GE(mediaPlayer->readyState(), readyState);
    }

    void waitForCurrentTimeGreaterThan(MediaTime time)
    {
        Util::waitFor([&] { return mediaPlayer->currentTime() > time; });
        EXPECT_GE(mediaPlayer->currentTime(), time);
    }

    void waitForEffectiveRateGreaterThan(double rate)
    {
        Util::waitFor([&] { return mediaPlayer->effectiveRate() > rate; });
        EXPECT_GE(mediaPlayer->effectiveRate(), rate);
    }

    void waitForEffectiveRateEqualTo(double rate)
    {
        Util::waitFor([&] { return mediaPlayer->effectiveRate() == rate; });
        EXPECT_EQ(mediaPlayer->effectiveRate(), rate);
    }

    RefPtr<WebCore::MediaPlayer> mediaPlayer;
};

TEST_F(MediaPlayerPrivateAVFoundationObjCTest, Basic)
{
    mediaPlayer->load(videoWithAudioURL(), { });
    waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState::HaveCurrentData);
}

TEST_F(MediaPlayerPrivateAVFoundationObjCTest, IsAudible)
{
    mediaPlayer->load(videoWithAudioURL(), { });
    waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState::HaveNothing);

    RefPtr playerPrivate = this->playerPrivate();
    ASSERT_NE(playerPrivate.get(), nullptr);

    mediaPlayer->setMuted(false);
    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    mediaPlayer->setMuted(true);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setMuted(false);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    mediaPlayer->setVolume(0);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    mediaPlayer->setMuted(true);
    mediaPlayer->setVolume(0);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setMuted(false);
    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    mediaPlayer->setVolume(0);
    mediaPlayer->setMuted(true);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setVolume(1);
    mediaPlayer->setMuted(false);
    EXPECT_EQ(playerPrivate->isAudible(), true);
}

TEST_F(MediaPlayerPrivateAVFoundationObjCTest, IsAudibleSilentVideo)
{
    mediaPlayer->load(videoWithoutAudioURL(), { });
    waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState::HaveNothing);

    RefPtr playerPrivate = this->playerPrivate();
    ASSERT_NE(playerPrivate.get(), nullptr);

    mediaPlayer->setMuted(false);
    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setMuted(true);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setMuted(false);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setVolume(0);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), false);
}

TEST_F(MediaPlayerPrivateAVFoundationObjCTest, IsAudibleWhilePlaying)
{
    mediaPlayer->load(videoWithAudioURL(), { });
    waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState::HaveNothing);

    RefPtr playerPrivate = this->playerPrivate();
    ASSERT_NE(playerPrivate.get(), nullptr);

    // Reduce the possibility of this test flaking when the underlying
    // media reaches the end by reducing the playback rate to 1/10000.
    // Calling setPreservesPitch(false) also has the effect of shifting
    // all generated frequencies to nearly inaudible ranges.
    mediaPlayer->setRate(0.0001);
    mediaPlayer->setPreservesPitch(false);
    mediaPlayer->setMuted(false);
    mediaPlayer->setVolume(1);

    mediaPlayer->play();
    waitForEffectiveRateGreaterThan(0);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    // isAudible() should not become false during playback
    mediaPlayer->setMuted(true);
    EXPECT_EQ(playerPrivate->isAudible(), true);
    mediaPlayer->setVolume(0);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    // isAudible() should subsequently become false once playback stops
    mediaPlayer->pause();
    waitForEffectiveRateEqualTo(0);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->play();
    waitForEffectiveRateGreaterThan(0);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    // isAudible() should become true during playback
    mediaPlayer->setMuted(false);
    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), true);
}


// Drives MediaPlayerPrivateAVFoundationObjC through loading, exact and tolerant seeks, rate changes, play, pause and
// playing to the end, and prints each checkpoint's state and the MediaPlayerClient callbacks since the previous one. The
// expected checkpoints were recorded from the C++ implementation, so any implementation of the player's state, time,
// seek and rate handling is held to them.
class MediaPlayerPrivateAVFoundationObjCReplay
    : public testing::Test
    , public WebCore::MediaPlayerClient
    , public Identified<WebCore::MediaPlayerClientIdentifier> {
public:
    void ref() const final { }
    void deref() const final { }

    WebCore::MediaPlayerClientIdentifier mediaPlayerClientIdentifier() const { return identifier(); }

    void SetUp() final
    {
        mediaPlayer = WebCore::MediaPlayer::create(*this, WebCore::MediaPlayerMediaEngineIdentifier::AVFoundation);
    }

    void TearDown() final
    {
        mediaPlayer = nullptr;
    }

    void mediaPlayerNetworkStateChanged() final { m_events.add("network"_s); }
    void mediaPlayerReadyStateChanged() final { m_events.add("ready"_s); }
    void mediaPlayerTimeChanged() final { m_events.add("time"_s); }
    void mediaPlayerDurationChanged() final { m_events.add("duration"_s); }
    void mediaPlayerRateChanged() final { m_events.add("rate"_s); }
    void mediaPlayerPlaybackStateChanged() final { m_events.add("playbackState"_s); }
    void mediaPlayerResourceNotSupported() final { m_events.add("notSupported"_s); }
    void mediaPlayerSizeChanged() final { m_events.add("size"_s); }
    void mediaPlayerFirstVideoFrameAvailable() final { m_events.add("firstFrame"_s); }
    void mediaPlayerCharacteristicChanged() final { m_events.add("characteristic"_s); }
    void mediaPlayerBufferedTimeRangesChanged() final { m_events.add("buffered"_s); }
    void mediaPlayerSeekableTimeRangesChanged() final { m_events.add("seekable"_s); }

    URL videoWithAudioURL() const
    {
        return [NSBundle.test_resourcesBundle URLForResource:@"video-with-audio" withExtension:@"mp4"];
    }

    static String timeString(const MediaTime& time)
    {
        if (!time.isValid())
            return "invalid"_s;
        if (time.isPositiveInfinite())
            return "+inf"_s;
        return String::number(std::round(time.toDouble() * 1000) / 1000);
    }

    static String rangesString(const WebCore::PlatformTimeRanges& ranges)
    {
        StringBuilder builder;
        builder.append('[');
        for (unsigned i = 0; i < ranges.length(); ++i)
            builder.append(i ? " "_s : ""_s, timeString(ranges.start(i)), '-', timeString(ranges.end(i)));
        builder.append(']');
        return builder.toString();
    }

    // The current time only when it can't depend on how long playback ran; otherwise whether it passed `after`.
    void checkpoint(ASCIILiteral label, std::optional<MediaTime> after = std::nullopt)
    {
        StringBuilder builder;
        builder.append(label, ": ready="_s, static_cast<unsigned>(mediaPlayer->readyState()), " network="_s, static_cast<unsigned>(mediaPlayer->networkState()),
            " paused="_s, mediaPlayer->paused(), " rate="_s, mediaPlayer->rate(), " effectiveRate="_s, mediaPlayer->effectiveRate());
        if (after)
            builder.append(" time>"_s, timeString(*after), '=', mediaPlayer->currentTime() > *after);
        else
            builder.append(" time="_s, timeString(mediaPlayer->currentTime()));
        auto size = mediaPlayer->naturalSize();
        builder.append(" duration="_s, timeString(mediaPlayer->duration()), " size="_s, size.width(), 'x', size.height(), " video="_s, mediaPlayer->hasVideo(), " audio="_s, mediaPlayer->hasAudio(),
            " buffered="_s, rangesString(mediaPlayer->buffered()), " seekable="_s, rangesString(mediaPlayer->seekable()), " events={"_s);
        Vector<String> events = copyToVector(m_events);
        std::sort(events.begin(), events.end(), codePointCompareLessThan);
        for (size_t i = 0; i < events.size(); ++i)
            builder.append(i ? ","_s : ""_s, events[i]);
        builder.append('}');
        m_events.clear();
        auto line = builder.toString();
        WTFLogAlways("AV4-REPLAY %s", Util::toSTD(line).c_str());
        m_checkpoints.append(WTF::move(line));
    }

    String seek(const WebCore::SeekTarget& target)
    {
        bool done = false;
        String result;
        mediaPlayer->seekToTarget(target)->whenSettled(RunLoop::mainSingleton(), [&](auto&& settled) {
            result = settled ? makeString("seeked to "_s, timeString(*settled)) : "seek rejected"_s;
            done = true;
        });
        Util::run(&done);
        return result;
    }

    void expectCheckpoints(std::initializer_list<ASCIILiteral> expected)
    {
        ASSERT_EQ(m_checkpoints.size(), expected.size());
        size_t index = 0;
        for (auto& line : expected)
            EXPECT_STREQ(Util::toSTD(m_checkpoints[index++]).c_str(), line.characters());
    }

    RefPtr<WebCore::MediaPlayer> mediaPlayer;
    HashSet<String> m_events;
    Vector<String> m_checkpoints;
};

TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, StateTimeSeekAndRate)
{
    mediaPlayer->load(videoWithAudioURL(), { });
    Util::waitFor([&] {
        return mediaPlayer->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData && mediaPlayer->buffered().length() && mediaPlayer->buffered().maximumBufferedTime() >= mediaPlayer->duration();
    });
    checkpoint("loaded"_s);

    auto exactSeek = seek(WebCore::SeekTarget { MediaTime(2, 1) });
    checkpoint("exact seek"_s);

    mediaPlayer->setRate(2);
    checkpoint("rate 2 while paused"_s);

    mediaPlayer->play();
    Util::waitFor([&] { return mediaPlayer->effectiveRate() == 2; });
    checkpoint("playing"_s, MediaTime(2, 1));

    mediaPlayer->pause();
    Util::waitFor([&] { return !mediaPlayer->effectiveRate(); });
    checkpoint("paused"_s, MediaTime(2, 1));

    mediaPlayer->setRate(1);
    auto tolerantSeek = seek(WebCore::SeekTarget { MediaTime(5, 1), MediaTime(1, 2), MediaTime(1, 2) });
    checkpoint("tolerant seek"_s);

    auto nearEndSeek = seek(WebCore::SeekTarget { MediaTime(98, 10) });
    mediaPlayer->play();
    Util::waitFor([&] { return mediaPlayer->currentTime() >= mediaPlayer->duration() && !mediaPlayer->effectiveRate(); });
    checkpoint("played to the end"_s);

    WTFLogAlways("AV4-REPLAY seeks: %s; %s; %s", Util::toSTD(exactSeek).c_str(), Util::toSTD(tolerantSeek).c_str(), Util::toSTD(nearEndSeek).c_str());
    EXPECT_STREQ(Util::toSTD(exactSeek).c_str(), "seeked to 2");
    EXPECT_STREQ(Util::toSTD(tolerantSeek).c_str(), "seeked to 5");
    EXPECT_STREQ(Util::toSTD(nearEndSeek).c_str(), "seeked to 9.8");
    expectCheckpoints({
        "loaded: ready=4 network=3 paused=1 rate=1 effectiveRate=0 time=0 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={buffered,characteristic,network,ready,seekable,size}"_s,
        "exact seek: ready=4 network=3 paused=1 rate=1 effectiveRate=0 time=2 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={}"_s,
        "rate 2 while paused: ready=4 network=3 paused=1 rate=2 effectiveRate=0 time=2 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={}"_s,
        "playing: ready=4 network=3 paused=0 rate=2 effectiveRate=2 time>2=1 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={buffered,rate,seekable}"_s,
        "paused: ready=4 network=3 paused=1 rate=2 effectiveRate=0 time>2=0 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={rate}"_s,
        "tolerant seek: ready=4 network=3 paused=1 rate=1 effectiveRate=0 time=5 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={}"_s,
        "played to the end: ready=4 network=3 paused=1 rate=1 effectiveRate=0 time=10 duration=10 size=320x240 video=1 audio=1 buffered=[0-10] seekable=[0-10] events={buffered,rate,seekable,time}"_s,
    });
}


// Prints the cost of the calls that the media element makes most often, paused and playing, and of exact seeks, to
// compare builds.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, PerCallCost)
{
    mediaPlayer->load(videoWithAudioURL(), { });
    Util::waitFor([&] {
        return mediaPlayer->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData;
    });

    constexpr unsigned iterations = 200000;
    double sink = 0;
    auto measure = [&](auto&& body) {
        auto start = MonotonicTime::now();
        for (unsigned i = 0; i < iterations; ++i)
            body();
        return (MonotonicTime::now() - start).nanoseconds() / iterations;
    };

    auto pausedCurrentTime = measure([&] { sink += mediaPlayer->currentTime().toDouble(); });
    auto pausedRates = measure([&] { sink += mediaPlayer->effectiveRate() + mediaPlayer->rate() + mediaPlayer->paused(); });

    mediaPlayer->setMuted(true);
    mediaPlayer->setRate(0.0001);
    mediaPlayer->play();
    Util::waitFor([&] { return mediaPlayer->effectiveRate() > 0; });
    auto playingCurrentTime = measure([&] { sink += mediaPlayer->currentTime().toDouble(); });
    mediaPlayer->pause();
    Util::waitFor([&] { return !mediaPlayer->effectiveRate(); });

    constexpr unsigned seeks = 20;
    auto seekStart = MonotonicTime::now();
    for (unsigned i = 0; i < seeks; ++i)
        seek(WebCore::SeekTarget { MediaTime(i % 2 ? 3 : 1, 1) });
    auto seekMilliseconds = (MonotonicTime::now() - seekStart).milliseconds() / seeks;

    WTFLogAlways("AV4-BENCH currentTime paused %.1f ns/call, rate+effectiveRate+paused %.1f ns/call, currentTime playing %.1f ns/call, exact seek %.2f ms (%g)", pausedCurrentTime, pausedRates, playingCurrentTime, seekMilliseconds, sink);
}

}
