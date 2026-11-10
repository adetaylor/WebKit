/*
 * Copyright (C) 2011-2026 Apple Inc. All rights reserved.
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

#include <CoreMedia/CMTime.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {

class MediaPlayerPrivateAVFoundationObjC;

// What the Swift player core (MediaPlayerAVFoundationCore.swift) reaches of the C++ MediaPlayerPrivateAVFoundationObjC
// that owns it: the media player's callbacks, the readiness state machine, the event loop, the pitch algorithm, the
// tracks and the logger. Refers to the C++ player weakly. On the main thread, apart from the logging.

enum class MediaPlayerAVFoundationLogLevel : uint8_t {
    Always,
    Error,
    Info,
    Debug,
};

struct MediaPlayerAVFoundationTimeRange {
    CMTime start;
    CMTime end;
};

// The playback time since the core last read the item's time, if it was playing then.
struct MediaPlayerAVFoundationTimeSample {
    double elapsed;
    bool extrapolate;
};

class MediaPlayerAVFoundationHost final : public ThreadSafeRefCounted<MediaPlayerAVFoundationHost> {
public:
    static Ref<MediaPlayerAVFoundationHost> create(MediaPlayerPrivateAVFoundationObjC&);
    ~MediaPlayerAVFoundationHost();

    // Any thread.
    bool willLog(MediaPlayerAVFoundationLogLevel) const;
    void log(MediaPlayerAVFoundationLogLevel, WTF::SpanUInt8 message NOESCAPE) const;

    // Runs the core's change `identifier` from the media player's event loop.
    void queueChange(uint64_t identifier) const;

    void updateStates() const;
    void tracksChanged() const;
    void sizeChanged() const;
    void rateChanged() const;
    void durationDidChange(CMTime) const;
    void loadedTimeRangesDidChange() const;
    void seekableTimeRangesDidChange() const;
    void seekCompleted(bool finished) const;
    void didEnd(double currentTime) const;
    void updateIsAudible() const;
    void applyAudioTimePitchAlgorithm() const;
    void currentTimeDidChange(CMTime) const;
    bool seeking() const;
    bool isCurrentPlaybackTargetWireless() const;
    void playbackStateChanged() const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { ThreadSafeRefCounted<MediaPlayerAVFoundationHost>::ref(); }
    void deref() const { ThreadSafeRefCounted<MediaPlayerAVFoundationHost>::deref(); }
#endif

private:
    explicit MediaPlayerAVFoundationHost(MediaPlayerPrivateAVFoundationObjC&);

    ThreadSafeWeakPtr<MediaPlayerPrivateAVFoundationObjC> m_player;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebCore
