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
#include <WebCore/VideoFrame.h>
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

TEST_F(MediaPlayerPrivateAVFoundationObjCTest, IsAudibleIgnoresAudioTrackLossWhileLoading)
{
    mediaPlayer->setPreload(WebCore::MediaPlayer::Preload::MetaData);
    mediaPlayer->load(videoWithAudioURL(), { });
    waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState::HaveNothing);

    RefPtr playerPrivate = this->playerPrivate();
    ASSERT_NE(playerPrivate.get(), nullptr);
    EXPECT_LT(mediaPlayer->readyState(), WebCore::MediaPlayerReadyState::HaveFutureData);

    mediaPlayer->setMuted(false);
    mediaPlayer->setVolume(1);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    playerPrivate->setHasAudioForTesting(false);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    playerPrivate->setHasAudioForTesting(true);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    mediaPlayer->setMuted(true);
    EXPECT_EQ(playerPrivate->isAudible(), false);

    mediaPlayer->setMuted(false);
    EXPECT_EQ(playerPrivate->isAudible(), true);

    mediaPlayer->prepareToPlay();
    waitForReadyStateGreaterThan(WebCore::MediaPlayerReadyState::HaveCurrentData);

    playerPrivate->setHasAudioForTesting(false);
    EXPECT_EQ(playerPrivate->isAudible(), false);
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
    void mediaPlayerRenderingModeChanged() final
    {
        if (m_recordsRenderingModeChanges)
            m_events.add("renderingMode"_s);
    }
    void mediaPlayerEngineFailedToLoad() final
    {
        if (m_recordsRenderingModeChanges)
            m_events.add("engineFailed"_s);
    }
    bool mediaPlayerIsVideo() const final { return m_isVideo; }
    bool mediaPlayerShouldDisableHDR() const final { return m_shouldDisableHDR; }

    URL videoWithAudioURL() const
    {
        return [NSBundle.test_resourcesBundle URLForResource:@"video-with-audio" withExtension:@"mp4"];
    }

    static URL resourceURL(NSString *name, NSString *extension)
    {
        return [NSBundle.test_resourcesBundle URLForResource:name withExtension:extension];
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

    // The engine's own readiness and asset answers, read from the engine that the load created even if the media player
    // later moves on to another engine.
    void engineCheckpoint(ASCIILiteral label, WebCore::MediaPlayerPrivateInterface& engine)
    {
        StringBuilder builder;
        auto size = engine.naturalSize();
        bool progressed = false;
        bool answered = false;
        engine.didLoadingProgressAsync([&](bool value) {
            progressed = value;
            answered = true;
        });
        Util::run(&answered);
        builder.append(label, ": ready="_s, static_cast<unsigned>(engine.readyState()), " network="_s, static_cast<unsigned>(engine.networkState()),
            " paused="_s, engine.paused(), " duration="_s, timeString(engine.duration()),
            " size="_s, size.width(), 'x', size.height(), " video="_s, engine.hasVideo(), " audio="_s, engine.hasAudio(),
            " captions="_s, engine.hasClosedCaptions(), " loadType="_s, static_cast<unsigned>(engine.movieLoadType()),
            " minSeekable="_s, timeString(engine.minTimeSeekable()), " maxSeekable="_s, timeString(engine.maxTimeSeekable()),
            " progressed="_s, progressed, " fileSize="_s, engine.fileSize(), " errorCode="_s, engine.platformErrorCode(),
            " startDate="_s, timeString(engine.getStartDate()), " layer="_s, !!engine.platformLayer(),
            " frame="_s, engine.hasAvailableVideoFrame(), " fullscreen="_s, engine.supportsFullscreen(), " events={"_s);
        Vector<String> events = copyToVector(m_events);
        std::sort(events.begin(), events.end(), codePointCompareLessThan);
        for (size_t i = 0; i < events.size(); ++i)
            builder.append(i ? ","_s : ""_s, events[i]);
        builder.append('}');
        m_events.clear();
        auto line = builder.toString();
        WTFLogAlways("AV4D-REPLAY %s", Util::toSTD(line).c_str());
        m_checkpoints.append(WTF::move(line));
    }

    RefPtr<WebCore::MediaPlayerPrivateInterface> loadAVFoundation(const URL& url)
    {
        mediaPlayer->load(url, { });
        return mediaPlayer->playerPrivate();
    }

    RefPtr<WebCore::MediaPlayer> mediaPlayer;
    HashSet<String> m_events;
    Vector<String> m_checkpoints;
    bool m_recordsRenderingModeChanges { false };
    bool m_isVideo { false };
    bool m_shouldDisableHDR { false };
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


// Drives the readiness state machine and the asset's status through preloading in steps, rendering to a layer and then
// to a context, page visibility, a seek issued while another is in flight, an audio-only file, a file that isn't media
// and a missing file, and prints the engine's answers at each step. Recorded from the C++ implementation.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, ReadinessAndAsset)
{
    m_recordsRenderingModeChanges = true;

    mediaPlayer->setPreload(WebCore::MediaPlayerPreload::None);
    RefPtr engine = loadAVFoundation(videoWithAudioURL());
    ASSERT_TRUE(engine);
    Util::runFor(0.3_s);
    engineCheckpoint("preload none"_s, *engine);

    mediaPlayer->setPreload(WebCore::MediaPlayerPreload::MetaData);
    Util::waitFor([&] { return engine->readyState() >= WebCore::MediaPlayerReadyState::HaveMetadata; });
    Util::runFor(0.3_s);
    engineCheckpoint("preload metadata"_s, *engine);

    mediaPlayer->setPageIsVisible(true);
    Util::runFor(0.1_s);
    engineCheckpoint("visible"_s, *engine);

    mediaPlayer->prepareToPlay();
    Util::waitFor([&] {
        return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData && engine->platformLayer()
            && mediaPlayer->buffered().length() && mediaPlayer->buffered().maximumBufferedTime() >= mediaPlayer->duration();
    });
    Util::runFor(0.3_s);
    engineCheckpoint("prepared"_s, *engine);

    RefPtr image = engine->nativeImageForCurrentTime();
    engine->acceleratedRenderingStateChanged();
    Util::runFor(0.3_s);
    engineCheckpoint(image ? "asked to paint, image"_s : "asked to paint, no image"_s, *engine);

    mediaPlayer->setPageIsVisible(false);
    Util::runFor(0.1_s);
    engineCheckpoint("hidden"_s, *engine);

    bool firstDone = false;
    bool secondDone = false;
    String firstSeek;
    String secondSeek;
    mediaPlayer->seekToTarget(WebCore::SeekTarget { MediaTime(2, 1) })->whenSettled(RunLoop::mainSingleton(), [&](auto&& settled) {
        firstSeek = settled ? makeString("seeked to "_s, timeString(*settled)) : "seek rejected"_s;
        firstDone = true;
    });
    mediaPlayer->seekToTarget(WebCore::SeekTarget { MediaTime(7, 1) })->whenSettled(RunLoop::mainSingleton(), [&](auto&& settled) {
        secondSeek = settled ? makeString("seeked to "_s, timeString(*settled)) : "seek rejected"_s;
        secondDone = true;
    });
    Util::run(&firstDone);
    Util::run(&secondDone);
    Util::runFor(0.2_s);
    engineCheckpoint("two seeks"_s, *engine);
    WTFLogAlways("AV4D-REPLAY seeks: %s; %s", Util::toSTD(firstSeek).c_str(), Util::toSTD(secondSeek).c_str());
    EXPECT_STREQ(Util::toSTD(firstSeek).c_str(), "seek rejected");
    EXPECT_STREQ(Util::toSTD(secondSeek).c_str(), "seeked to 7");

    engine = nullptr;
    mediaPlayer = WebCore::MediaPlayer::create(*this, WebCore::MediaPlayerMediaEngineIdentifier::AVFoundation);
    m_events.clear();
    engine = loadAVFoundation(resourceURL(@"half-a-second-48000", @"mp3"));
    ASSERT_TRUE(engine);
    Util::waitFor([&] { return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData; });
    Util::runFor(0.3_s);
    engineCheckpoint("audio only"_s, *engine);

    engine = nullptr;
    mediaPlayer = WebCore::MediaPlayer::create(*this, WebCore::MediaPlayerMediaEngineIdentifier::AVFoundation);
    m_events.clear();
    engine = loadAVFoundation(resourceURL(@"alert", @"html"));
    ASSERT_TRUE(engine);
    Util::waitFor([&] { return engine->networkState() >= WebCore::MediaPlayerNetworkState::FormatError; });
    Util::runFor(0.3_s);
    engineCheckpoint("not media"_s, *engine);

    engine = nullptr;
    mediaPlayer = WebCore::MediaPlayer::create(*this, WebCore::MediaPlayerMediaEngineIdentifier::AVFoundation);
    m_events.clear();
    engine = loadAVFoundation([NSBundle.test_resourcesBundle.resourceURL URLByAppendingPathComponent:@"no-such-file.mp4"]);
    ASSERT_TRUE(engine);
    // The C++ player stays loading: its metadata loads fail, and nothing updates its state after that.
    Util::runFor(1_s);
    engineCheckpoint("missing file"_s, *engine);
    engine = nullptr;

    expectCheckpoints({
        "preload none: ready=0 network=1 paused=1 duration=0 size=0x0 video=0 audio=0 captions=0 loadType=0 minSeekable=0 maxSeekable=0 progressed=0 fileSize=0 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={network}"_s,
        "preload metadata: ready=1 network=1 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=1 fileSize=0 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={characteristic,ready,size}"_s,
        "visible: ready=1 network=1 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=0 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={renderingMode}"_s,
        "prepared: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=1 fileSize=160121 errorCode=0 startDate=invalid layer=1 frame=0 fullscreen=1 events={buffered,characteristic,network,ready,renderingMode,seekable}"_s,
        "asked to paint, image: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=1 fullscreen=1 events={renderingMode}"_s,
        "hidden: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=1 fullscreen=1 events={}"_s,
        "two seeks: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=1 fullscreen=1 events={firstFrame}"_s,
        "audio only: ready=4 network=3 paused=1 duration=0.528 size=0x0 video=0 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=0.5 progressed=1 fileSize=0 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={buffered,characteristic,network,ready,seekable}"_s,
        "not media: ready=0 network=4 paused=1 duration=0 size=0x0 video=0 audio=0 captions=0 loadType=0 minSeekable=0 maxSeekable=0 progressed=0 fileSize=0 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={characteristic,engineFailed,network}"_s,
        "missing file: ready=0 network=2 paused=1 duration=0 size=0x0 video=0 audio=0 captions=0 loadType=0 minSeekable=0 maxSeekable=0 progressed=0 fileSize=0 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={network}"_s,
    });
}

// Drives the AVFoundation player's AVPlayer and AVPlayerItem through creation, cancelling the load, loading again,
// the buffering policies and wireless playback being disabled, and prints the engine's answers at each step. Recorded
// from the C++ implementation, so moving the AV objects' creation and observation is held to it.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, CreationCancelAndPolicies)
{
    m_recordsRenderingModeChanges = true;
    auto loadAndWait = [&](ASCIILiteral label) {
        RefPtr engine = loadAVFoundation(videoWithAudioURL());
        Util::waitFor([&] {
            return engine && engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData && mediaPlayer->buffered().length()
                && mediaPlayer->buffered().maximumBufferedTime() >= mediaPlayer->duration();
        });
        Util::runFor(0.3_s);
        if (engine)
            engineCheckpoint(label, *engine);
        return engine;
    };

    RefPtr engine = loadAndWait("loaded"_s);
    ASSERT_TRUE(engine);

    mediaPlayer->cancelLoad();
    Util::runFor(0.3_s);
    engineCheckpoint("cancelled"_s, *engine);

    engine = loadAndWait("loaded again"_s);
    ASSERT_TRUE(engine);

    for (auto [policy, label] : std::initializer_list<std::pair<WebCore::MediaPlayerBufferingPolicy, ASCIILiteral>> {
        { WebCore::MediaPlayerBufferingPolicy::LimitReadAhead, "limit read-ahead"_s },
        { WebCore::MediaPlayerBufferingPolicy::MakeResourcesPurgeable, "purgeable"_s },
        { WebCore::MediaPlayerBufferingPolicy::PurgeResources, "purge"_s },
        { WebCore::MediaPlayerBufferingPolicy::Default, "default policy"_s } }) {
        mediaPlayer->setBufferingPolicy(policy);
        Util::runFor(0.3_s);
        engineCheckpoint(label, *engine);
    }

    mediaPlayer->setWirelessVideoPlaybackDisabled(true);
    Util::runFor(0.2_s);
    WTFLogAlways("AV4E-REPLAY wireless disabled=%d wireless=%d", mediaPlayer->wirelessVideoPlaybackDisabled(), mediaPlayer->isCurrentPlaybackTargetWireless());
    EXPECT_TRUE(mediaPlayer->wirelessVideoPlaybackDisabled());
    EXPECT_FALSE(mediaPlayer->isCurrentPlaybackTargetWireless());

    mediaPlayer->play();
    Util::waitFor([&] { return mediaPlayer->effectiveRate() > 0; });
    mediaPlayer->pause();
    Util::waitFor([&] { return !mediaPlayer->effectiveRate(); });
    Util::runFor(0.2_s);
    engineCheckpoint("played and paused"_s, *engine);
    engine = nullptr;

    expectCheckpoints({
        "loaded: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=1 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={buffered,characteristic,network,ready,seekable,size}"_s,
        "cancelled: ready=4 network=3 paused=1 duration=0 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={}"_s,
        "loaded again: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={buffered,characteristic,duration,network,ready,seekable,size}"_s,
        "limit read-ahead: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={}"_s,
        "purgeable: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={}"_s,
        "purge: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={}"_s,
        "default policy: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={buffered,seekable}"_s,
        "played and paused: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=0 fullscreen=1 events={rate}"_s,
    });
}

static CALayer *findAVPlayerLayer(CALayer *layer)
{
    if ([layer isKindOfClass:NSClassFromString(@"AVPlayerLayer")])
        return layer;
    for (CALayer *sublayer in layer.sublayers) {
        if (auto *found = findAVPlayerLayer(sublayer))
            return found;
    }
    return nil;
}

// Drives the AVFoundation player's AVPlayerLayer through creation, aspect ratio, page and viewport visibility, and the
// switch to context rendering, and prints its gravity and whether the layer shows the player. Recorded from the C++
// implementation.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, VideoLayer)
{
    m_recordsRenderingModeChanges = true;
    mediaPlayer->setPageIsVisible(true);
    mediaPlayer->setViewportVisibility(WebCore::MediaPlayerViewportVisibility::VisibleInViewport);
    RefPtr engine = loadAVFoundation(videoWithAudioURL());
    ASSERT_TRUE(engine);
    Util::waitFor([&] { return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData && engine->platformLayer(); });
    Util::runFor(0.3_s);

    auto layerCheckpoint = [&](ASCIILiteral label) {
        RetainPtr playerLayer = findAVPlayerLayer(engine->platformLayer());
        String gravity = playerLayer ? String([playerLayer valueForKey:@"videoGravity"]) : "none"_s;
        bool showsPlayer = playerLayer && [playerLayer valueForKey:@"player"];
        auto line = makeString(label, ": layer="_s, !!playerLayer, " gravity="_s, gravity, " player="_s, showsPlayer);
        WTFLogAlways("AV4G-REPLAY %s", Util::toSTD(line).c_str());
        m_checkpoints.append(WTF::move(line));
    };

    layerCheckpoint("created"_s);
    engineCheckpoint("created engine"_s, *engine);

    mediaPlayer->setShouldMaintainAspectRatio(false);
    Util::runFor(0.1_s);
    layerCheckpoint("stretched"_s);

    mediaPlayer->setShouldMaintainAspectRatio(true);
    Util::runFor(0.1_s);
    layerCheckpoint("aspect"_s);

    mediaPlayer->setViewportVisibility(WebCore::MediaPlayerViewportVisibility::NotVisible);
    Util::runFor(0.1_s);
    layerCheckpoint("out of viewport"_s);

    mediaPlayer->setViewportVisibility(WebCore::MediaPlayerViewportVisibility::VisibleInViewport);
    Util::runFor(0.1_s);
    layerCheckpoint("back in viewport"_s);

    mediaPlayer->setPageIsVisible(false);
    Util::runFor(0.1_s);
    layerCheckpoint("page hidden"_s);

    mediaPlayer->setPageIsVisible(true);
    Util::runFor(0.1_s);
    layerCheckpoint("page shown"_s);

    RefPtr image = engine->nativeImageForCurrentTime();
    engine->acceleratedRenderingStateChanged();
    Util::runFor(0.3_s);
    engineCheckpoint(image ? "context, image"_s : "context, no image"_s, *engine);
    engine = nullptr;

    expectCheckpoints({
        "created: layer=1 gravity=AVLayerVideoGravityResizeAspect player=1"_s,
        "created engine: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=1 fileSize=160121 errorCode=0 startDate=invalid layer=1 frame=1 fullscreen=1 events={buffered,characteristic,firstFrame,network,ready,renderingMode,seekable,size}"_s,
        "stretched: layer=1 gravity=AVLayerVideoGravityResize player=1"_s,
        "aspect: layer=1 gravity=AVLayerVideoGravityResizeAspect player=1"_s,
        "out of viewport: layer=1 gravity=AVLayerVideoGravityResizeAspect player=0"_s,
        "back in viewport: layer=1 gravity=AVLayerVideoGravityResizeAspect player=1"_s,
        "page hidden: layer=1 gravity=AVLayerVideoGravityResizeAspect player=0"_s,
        "page shown: layer=1 gravity=AVLayerVideoGravityResizeAspect player=1"_s,
        "context, image: ready=4 network=3 paused=1 duration=10 size=320x240 video=1 audio=1 captions=0 loadType=1 minSeekable=0 maxSeekable=10 progressed=0 fileSize=160121 errorCode=0 startDate=invalid layer=0 frame=1 fullscreen=1 events={buffered,firstFrame,renderingMode,seekable}"_s,
    });
}

// Drives the AVFoundation player's muting, volume, audibility, tone mapping and external playback settings, given while
// it loads and once it has loaded, paused and playing, as a video and as an audio element's player, and prints what the
// AVPlayer and its layer hold. Recorded from the C++ implementation.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, Controls)
{
    // A BOOL property read through its getter, if the object has it; "-" otherwise.
    auto boolProperty = [](id object, NSString *key, NSString *getter) -> ASCIILiteral {
        if (!object || ![object respondsToSelector:NSSelectorFromString(getter)])
            return "-"_s;
        return [[object valueForKey:key] boolValue] ? "1"_s : "0"_s;
    };

    for (bool isVideo : { true, false }) {
        m_isVideo = isVideo;
        m_shouldDisableHDR = true;
        mediaPlayer = WebCore::MediaPlayer::create(*this, WebCore::MediaPlayerMediaEngineIdentifier::AVFoundation);
        mediaPlayer->setPageIsVisible(true);
        mediaPlayer->setViewportVisibility(WebCore::MediaPlayerViewportVisibility::VisibleInViewport);

        RefPtr engine = loadAVFoundation(videoWithAudioURL());
        ASSERT_TRUE(engine);
        RefPtr objcEngine = dynamicDowncast<WebCore::MediaPlayerPrivateAVFoundationObjC>(*engine);
        ASSERT_TRUE(objcEngine);

        auto controlsCheckpoint = [&](ASCIILiteral label) {
            id player = engine->objCAVFoundationAVPlayer();
            CALayer *platformLayer = engine->platformLayer();
            RetainPtr playerLayer = platformLayer ? findAVPlayerLayer(platformLayer) : nil;
            StringBuilder builder;
            builder.append(isVideo ? "video "_s : "audio "_s, label, ": player="_s, !!player, " audible="_s, objcEngine->isAudible());
            if (player) {
                builder.append(" volume="_s, [[player valueForKey:@"volume"] floatValue], " muted="_s, [[player valueForKey:@"muted"] boolValue],
                    " external="_s, [[player valueForKey:@"allowsExternalPlayback"] boolValue],
                    " selectionCriteria="_s, [[player valueForKey:@"appliesMediaSelectionCriteriaAutomatically"] boolValue]);
            }
            builder.append(" suppressed="_s, boolProperty(player, @"suppressesAudioRendering", @"_suppressesAudioRendering"),
                " wirelessDisabled="_s, mediaPlayer->wirelessVideoPlaybackDisabled(), " targetType="_s, static_cast<unsigned>(mediaPlayer->wirelessPlaybackTargetType()),
                " layer="_s, !!playerLayer, " toneMapped="_s, boolProperty(playerLayer.get(), @"toneMapToStandardDynamicRange", @"toneMapToStandardDynamicRange"), " events={"_s);
            Vector<String> events = copyToVector(m_events);
            std::sort(events.begin(), events.end(), codePointCompareLessThan);
            for (size_t i = 0; i < events.size(); ++i)
                builder.append(i ? ","_s : ""_s, events[i]);
            builder.append('}');
            m_events.clear();
            auto line = builder.toString();
            WTFLogAlways("AV4H-REPLAY %s", Util::toSTD(line).c_str());
            m_checkpoints.append(WTF::move(line));
        };

        mediaPlayer->setMuted(true);
        mediaPlayer->setVolume(0.5);
        mediaPlayer->setWirelessVideoPlaybackDisabled(true);
        controlsCheckpoint("set while loading"_s);

        Util::waitFor([&] { return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData; });
        Util::runFor(0.3_s);
        controlsCheckpoint("loaded"_s);

        mediaPlayer->setMuted(false);
        controlsCheckpoint("unmuted"_s);

        mediaPlayer->setVolume(0);
        controlsCheckpoint("volume 0"_s);

        mediaPlayer->setVolume(1);
        controlsCheckpoint("volume 1"_s);

        mediaPlayer->setShouldDisableHDR(false);
        controlsCheckpoint("HDR allowed"_s);

        mediaPlayer->setShouldDisableHDR(true);
        controlsCheckpoint("HDR disabled"_s);

        mediaPlayer->setWirelessVideoPlaybackDisabled(false);
        controlsCheckpoint("wireless allowed"_s);

        mediaPlayer->setShouldDisableSleep(true);
        mediaPlayer->setShouldDisableSleep(false);

        mediaPlayer->play();
        Util::waitFor([&] { return mediaPlayer->effectiveRate() > 0; });
        mediaPlayer->setMuted(true);
        controlsCheckpoint("muted while playing"_s);

        mediaPlayer->pause();
        Util::waitFor([&] { return !mediaPlayer->effectiveRate(); });
        Util::runFor(0.2_s);
        controlsCheckpoint("paused, muted"_s);

        mediaPlayer->setVolumeLocked(true);
        mediaPlayer->setVolume(0.25);
        mediaPlayer->setMuted(false);
        controlsCheckpoint("volume locked, unmuted"_s);

        engine = nullptr;
        objcEngine = nullptr;
        mediaPlayer = nullptr;
    }

    expectCheckpoints({
        "video set while loading: player=0 audible=0 suppressed=- wirelessDisabled=1 targetType=0 layer=0 toneMapped=- events={network}"_s,
        "video loaded: player=1 audible=0 volume=0.5 muted=1 external=0 selectionCriteria=0 suppressed=1 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={buffered,characteristic,firstFrame,network,ready,seekable,size}"_s,
        "video unmuted: player=1 audible=1 volume=0.5 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "video volume 0: player=1 audible=0 volume=0 muted=0 external=0 selectionCriteria=0 suppressed=1 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "video volume 1: player=1 audible=1 volume=1 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "video HDR allowed: player=1 audible=1 volume=1 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "video HDR disabled: player=1 audible=1 volume=1 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=1 events={}"_s,
        "video wireless allowed: player=1 audible=1 volume=1 muted=0 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={}"_s,
        "video muted while playing: player=1 audible=1 volume=1 muted=1 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={buffered,rate}"_s,
        "video paused, muted: player=1 audible=0 volume=1 muted=1 external=1 selectionCriteria=0 suppressed=1 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={buffered,rate}"_s,
        "video volume locked, unmuted: player=1 audible=1 volume=1 muted=0 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={}"_s,
        "audio set while loading: player=0 audible=0 suppressed=- wirelessDisabled=1 targetType=0 layer=0 toneMapped=- events={network}"_s,
        "audio loaded: player=1 audible=0 volume=0.5 muted=1 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={buffered,characteristic,firstFrame,network,ready,seekable,size}"_s,
        "audio unmuted: player=1 audible=1 volume=0.5 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "audio volume 0: player=1 audible=0 volume=0 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "audio volume 1: player=1 audible=1 volume=1 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "audio HDR allowed: player=1 audible=1 volume=1 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=0 events={}"_s,
        "audio HDR disabled: player=1 audible=1 volume=1 muted=0 external=0 selectionCriteria=0 suppressed=0 wirelessDisabled=1 targetType=1 layer=1 toneMapped=1 events={}"_s,
        "audio wireless allowed: player=1 audible=1 volume=1 muted=0 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={}"_s,
        "audio muted while playing: player=1 audible=1 volume=1 muted=1 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={rate}"_s,
        "audio paused, muted: player=1 audible=0 volume=1 muted=1 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={rate}"_s,
        "audio volume locked, unmuted: player=1 audible=1 volume=1 muted=0 external=1 selectionCriteria=0 suppressed=0 wirelessDisabled=0 targetType=1 layer=1 toneMapped=1 events={}"_s,
    });
}

// Prints the cost of the controls the media element sets, to compare builds.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, ControlsCallCost)
{
    RefPtr engine = loadAVFoundation(videoWithAudioURL());
    ASSERT_TRUE(engine);
    Util::waitFor([&] { return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData; });

    constexpr unsigned iterations = 2000;
    auto measure = [&](auto&& body) {
        auto start = MonotonicTime::now();
        for (unsigned i = 0; i < iterations; ++i)
            body(i);
        return (MonotonicTime::now() - start).nanoseconds() / iterations;
    };
    unsigned sink = 0;
    auto muted = measure([&](unsigned i) { engine->setMuted(i & 1); });
    auto volume = measure([&](unsigned i) { engine->setVolume(i & 1 ? 0.5 : 1); });
    auto targetType = measure([&](unsigned) { sink += static_cast<unsigned>(engine->wirelessPlaybackTargetType()); });
    auto hdr = measure([&](unsigned i) { engine->setShouldDisableHDR(i & 1); });

    WTFLogAlways("AV4H-BENCH setMuted %.1f ns/call, setVolume %.1f ns/call, wirelessPlaybackTargetType %.1f ns/call, setShouldDisableHDR %.1f ns/call (%u)", muted, volume, targetType, hdr, sink);
    engine = nullptr;
}

// Prints the cost of pulling the current frame from the video output, as an image and as a video frame, paused and
// playing, to compare builds.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, VideoOutputCost)
{
    RefPtr engine = loadAVFoundation(videoWithAudioURL());
    ASSERT_TRUE(engine);
    Util::waitFor([&] { return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData; });
    RefPtr warm = engine->nativeImageForCurrentTime();

    constexpr unsigned iterations = 2000;
    auto measure = [&](auto&& body) {
        auto start = MonotonicTime::now();
        for (unsigned i = 0; i < iterations; ++i)
            body();
        return (MonotonicTime::now() - start).nanoseconds() / iterations;
    };
    unsigned sink = 0;
    auto pausedImage = measure([&] { sink += !!engine->nativeImageForCurrentTime(); });
    auto pausedFrame = measure([&] { sink += !!engine->videoFrameForCurrentTime(); });

    mediaPlayer->setMuted(true);
    mediaPlayer->play();
    Util::waitFor([&] { return mediaPlayer->effectiveRate() > 0; });
    auto playingImage = measure([&] { sink += !!engine->nativeImageForCurrentTime(); });
    auto playingFrame = measure([&] { sink += !!engine->videoFrameForCurrentTime(); });
    mediaPlayer->pause();

    WTFLogAlways("AV4G-BENCH image paused %.1f ns/call, frame paused %.1f ns/call, image playing %.1f ns/call, frame playing %.1f ns/call (%u)", pausedImage, pausedFrame, playingImage, playingFrame, sink);
    engine = nullptr;
}

// Prints the cost of the readiness calls the media element makes, of re-deciding the rendering mode, and of page
// visibility changes, to compare builds.
TEST_F(MediaPlayerPrivateAVFoundationObjCReplay, ReadinessCallCost)
{
    mediaPlayer->setPageIsVisible(true);
    RefPtr engine = loadAVFoundation(videoWithAudioURL());
    ASSERT_TRUE(engine);
    Util::waitFor([&] {
        return engine->readyState() == WebCore::MediaPlayerReadyState::HaveEnoughData && engine->platformLayer();
    });

    constexpr unsigned iterations = 200000;
    double sink = 0;
    auto measure = [&](unsigned count, auto&& body) {
        auto start = MonotonicTime::now();
        for (unsigned i = 0; i < count; ++i)
            body();
        return (MonotonicTime::now() - start).nanoseconds() / count;
    };

    auto getters = measure(iterations, [&] {
        sink += engine->paused() + engine->naturalSize().width() + static_cast<unsigned>(engine->movieLoadType());
    });
    auto renderingMode = measure(iterations, [&] { engine->acceleratedRenderingStateChanged(); });
    auto visibility = measure(iterations / 10, [&] {
        engine->setPageIsVisible(false);
        engine->setPageIsVisible(true);
    });

    WTFLogAlways("AV4D-BENCH readiness getters %.1f ns/call, rendering mode %.1f ns/call, hide+show %.1f ns/pair (%g)", getters, renderingMode, visibility, sink);
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
