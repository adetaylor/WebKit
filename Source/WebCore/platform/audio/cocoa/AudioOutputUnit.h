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

#pragma once

#if (ENABLE(WEB_AUDIO) || ENABLE(MEDIA_STREAM)) && USE(MEDIATOOLBOX)

#include <AudioToolbox/AudioToolbox.h>
#include <optional>
#include <span>
#include <wtf/Function.h>
#include <wtf/Noncopyable.h>
#include <wtf/OptionSet.h>
#include <wtf/CheckedPtr.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

OBJC_CLASS CASpatialAudioExperience;

namespace WebCore {

class AudioCaptureSink;
class AudioTrackPlayout;
class CARingBuffer;

// An output AudioUnit, the default output unit (RemoteIO on iOS), that AudioOutputUnit.swift owns. Use it on the main
// thread only.
class AudioOutputUnit {
    WTF_MAKE_NONCOPYABLE(AudioOutputUnit);
public:
    enum class Kind : uint8_t {
        // An audio destination of the GPU process, which plays out a ring the web process writes (attachRing()).
        RemoteDestination,
        // An in-process audio destination, which renders from a C++ callback (attachRenderCallback()).
        InProcessDestination,
        // A remote destination on a generic output unit, which needs no hardware (renderForTesting()).
        GenericOutputForTesting,
    };

    WEBCORE_EXPORT AudioOutputUnit(Kind, float hardwareSampleRate, unsigned numberOfOutputChannels);
    WEBCORE_EXPORT ~AudioOutputUnit();

    // A MediaStream track renderer on the given device (0: the default one), in the given format or the unit's own at
    // sampleRate. It plays out a track (attachTrackPlayout()) or renders from a C++ callback (attachRenderCallback()); it
    // checks its timeline and clips its output either way. Without a unit, failedStep says which step failed.
    struct TrackRenderer {
        std::unique_ptr<AudioOutputUnit> unit;
        AudioStreamBasicDescription format { };
        OSStatus status { noErr };
        uint32_t failedStep { 0 };
    };
    WEBCORE_EXPORT static TrackRenderer createTrackRenderer(uint32_t deviceID, double sampleRate, const std::optional<AudioStreamBasicDescription>&, bool playsOutTrack);

    // While stopped: the track a track renderer plays out, which the unit keeps alive.
    WEBCORE_EXPORT void attachTrackPlayout(const AudioTrackPlayout&);

    // Events of an output or capture unit's IO threads, which the handler gets on the main thread.
    enum class Event : uint32_t {
        TimelineDiscontinuity = 1 << 0,
        SpeakerStarting = 1 << 1,
        MicrophoneBufferTooSmall = 1 << 2,
        FirstMicrophoneQuantum = 1 << 3,
        SinkStarted = 1 << 4,
    };
    WEBCORE_EXPORT void setEventHandler(Function<void(OptionSet<Event>)>&&);

    WEBCORE_EXPORT OSStatus start();
    WEBCORE_EXPORT OSStatus stop();
    WEBCORE_EXPORT size_t outputLatency() const;

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    WEBCORE_EXPORT void setSpatialAudioExperience(CASpatialAudioExperience *);
#endif

    // While stopped: the ring a remote destination plays out (or none), the shared counter it adds each quantum's frames
    // to, and the semaphore it signals after each quantum. The caller keeps them alive until it attaches others or
    // destroys the unit.
    WEBCORE_EXPORT void attachRing(const CARingBuffer*, std::span<uint8_t> frameCounter, uint32_t semaphore);

    // Before an in-process destination first starts: the callback that renders each quantum on the unit's IO thread.
    WEBCORE_EXPORT void attachRenderCallback(AURenderCallback, void* refCon);

    // Tests only, off the main thread, while stopped: renders one quantum into the list, through AudioUnitRender() on a
    // GenericOutputForTesting unit, or by calling the unit's Swift render callback directly.
    WEBCORE_EXPORT OSStatus renderForTesting(AudioBufferList&, uint32_t frameCount, double sampleTime, bool throughAudioUnit, AudioUnitRenderActionFlags* = nullptr);

    static void dispatchEvents();
    static void setEventHandler(uint64_t identifier, Function<void(OptionSet<Event>)>*);

private:
    explicit AudioOutputUnit(uint64_t identifier);

    const uint64_t m_identifier;
    Function<void(OptionSet<Event>)> m_eventHandler;
};

// What a GPU-process track renderer and the capture unit's speaker play out (AudioUnitIsland.swift's TrackPlayout): the ring
// the web process writes and the semaphore it signals for each chunk of frames it asks for. The units that play it out
// keep it alive. Main thread only.
class AudioTrackPlayout {
    WTF_MAKE_NONCOPYABLE(AudioTrackPlayout);
public:
    WEBCORE_EXPORT AudioTrackPlayout();
    WEBCORE_EXPORT ~AudioTrackPlayout();

    // A ring (or none) read from its start, in chunks of frameChunkSize frames of bytesPerFrame bytes, and the semaphore
    // signalled for each. The caller keeps them alive until it attaches others or destroys the playout.
    WEBCORE_EXPORT void attachRing(const CARingBuffer*, uint32_t semaphore, uint64_t frameChunkSize, uint64_t bytesPerFrame);

    uint64_t identifier() const { return m_identifier; }

private:
    const uint64_t m_identifier;
};

#if ENABLE(MEDIA_STREAM)
// The C++ that the units of a capture controller (AudioCaptureController.swift) hand each microphone quantum to
// (deliverToCxxObservers()), which it keeps alive while the controller lives.
void attachAudioCaptureDeliveryContext(uint64_t controllerIdentifier, void* context);

// Tests only: a mock capture unit (AudioCaptureUnit.swift's MockCaptureBackend), either one whose speaker plays out a track in
// the given format, rendered on the calling thread, or a running one with echo cancellation at 44100 Hz that feeds the given
// sinks its samples times gain. It stops when destroyed.
class AudioCaptureUnitForTesting {
    WTF_MAKE_NONCOPYABLE(AudioCaptureUnitForTesting);
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(AudioCaptureUnitForTesting, WEBCORE_EXPORT);
public:
    WEBCORE_EXPORT static std::unique_ptr<AudioCaptureUnitForTesting> createSpeaker(const AudioTrackPlayout&, const AudioStreamBasicDescription&);
    WEBCORE_EXPORT static std::unique_ptr<AudioCaptureUnitForTesting> startMicrophone(const AudioCaptureSink&, const AudioCaptureSink&, float gain);
    WEBCORE_EXPORT ~AudioCaptureUnitForTesting();

    // While the main thread leaves the unit alone: renders one quantum into the list by calling the speaker callback.
    WEBCORE_EXPORT OSStatus renderSpeaker(AudioBufferList&, uint32_t frameCount, double sampleTime, AudioUnitRenderActionFlags*);

private:
    explicit AudioCaptureUnitForTesting(uint64_t identifier);

    const uint64_t m_identifier;
};

// What a GPU-process consumer of a capture source takes from each microphone quantum on the capture unit's IO thread,
// instead of an AudioSampleObserver (AudioUnitIsland.swift's CaptureSink): a producer stores the quanta of its format into a
// ring the web process reads and signals a semaphore for each chunk of frames; a peak keeps the largest sample magnitude.
// Main thread only.
class AudioCaptureSink : public CanMakeWeakPtr<AudioCaptureSink>, public CanMakeCheckedPtr<AudioCaptureSink> {
    WTF_MAKE_NONCOPYABLE(AudioCaptureSink);
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(AudioCaptureSink, WEBCORE_EXPORT);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(AudioCaptureSink);
public:
    enum class Kind : bool { Producer, Peak };
    WEBCORE_EXPORT AudioCaptureSink(Kind, const AudioStreamBasicDescription& format);
    // Waits for the IO thread to finish a write into the ring, so the ring and the semaphore can go once it returns.
    WEBCORE_EXPORT ~AudioCaptureSink();

    // A producer, before a source has it: the ring it writes from frame 0, and the semaphore it signals for each chunk of
    // frameChunkSize frames. The caller keeps them alive until it destroys the sink.
    WEBCORE_EXPORT void attachRing(CARingBuffer&, uint32_t semaphore, uint64_t frameChunkSize);

    Kind kind() const { return m_kind; }
    const AudioStreamBasicDescription& format() const LIFETIME_BOUND { return m_format; }
    uint64_t identifier() const { return m_identifier; }

    // A producer's first stored frame's MediaTime, once there's one (Event::SinkStarted), and the quanta it dropped because
    // their format wasn't its.
    WEBCORE_EXPORT std::optional<std::pair<int64_t, uint32_t>> startTime() const;
    WEBCORE_EXPORT uint64_t droppedQuantumCount() const;
    // A peak's largest sample magnitude since the last call.
    WEBCORE_EXPORT float takePeak();

    WEBCORE_EXPORT void setEnabled(bool);

    // Called by the capture source on the main thread: once the producer stored its first frame, and when the microphone's
    // format changes from the sink's.
    WEBCORE_EXPORT void setStartedHandler(Function<void(int64_t value, uint32_t scale)>&&);
    WEBCORE_EXPORT void setFormatChangedHandler(Function<void()>&&);
    void notifyStartedIfNeeded();
    void notifyFormatChanged();

private:
    const Kind m_kind;
    const AudioStreamBasicDescription m_format;
    const uint64_t m_identifier;
    bool m_hasNotifiedStart { false };
    Function<void(int64_t, uint32_t)> m_startedHandler;
    Function<void()> m_formatChangedHandler;
};
#endif // ENABLE(MEDIA_STREAM)

} // namespace WebCore

#endif // (ENABLE(WEB_AUDIO) || ENABLE(MEDIA_STREAM)) && USE(MEDIATOOLBOX)
