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
#include <wtf/StdLibExtras.h>

OBJC_CLASS CASpatialAudioExperience;

namespace WebCore {

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
// A capture AudioUnit that AudioCaptureUnit.swift owns, with its Swift microphone and speaker callbacks. Main thread only.
class AudioCaptureUnitHandle {
    WTF_MAKE_NONCOPYABLE(AudioCaptureUnitHandle);
public:
    enum class Kind : uint8_t {
        VoiceProcessing,
        Plain,
        MockWithEchoCancellation,
        MockWithoutEchoCancellation,
    };
    enum class Switch : uint8_t {
        ProducingMicrophoneSamples,
        Reconfiguring,
        SpeakerStartAcknowledged,
    };

    // A unit, or the status of the step that failed (-1: finding the component). On macOS, a voice processing unit may be
    // the stored one.
    struct Creation {
        std::unique_ptr<AudioCaptureUnitHandle> unit;
        OSStatus status { noErr };
        bool reusedStoredUnit { false };
    };
    WEBCORE_EXPORT static Creation create(Kind);
    WEBCORE_EXPORT ~AudioCaptureUnitHandle();

    // Stops and disposes of the unit or, on macOS, keeps a voice processing unit for the next capture. Returns whether it
    // kept it.
    bool destroy();

#if PLATFORM(MAC)
    // On any thread: makes a voice processing unit for the next capture. Returns whether one is stored.
    static bool prewarmStoredUnit();
    static void deallocateStoredUnit();
#endif

    bool isMock() const { return m_kind == Kind::MockWithEchoCancellation || m_kind == Kind::MockWithoutEchoCancellation; }

    OSStatus setUInt32Property(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, uint32_t value) { return setSmallProperty(property, scope, element, value); }
    template<typename T> OSStatus setSmallProperty(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const T&);
    OSStatus getUInt32Property(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, uint32_t&);

    struct Format {
        std::optional<AudioStreamBasicDescription> format;
        OSStatus status { noErr };
        uint32_t failedStep { 0 };
    };
    Format configureMicrophone(double sampleRate);
    // Buffers of the sizes of the list's, which the microphone renders into.
    void allocateMicrophoneBuffers(const AudioBufferList& sizes, double sampleRate, double dtsConversionRatio);
    WEBCORE_EXPORT Format configureSpeaker(double sampleRate, const std::optional<AudioStreamBasicDescription>& producerFormat);

    OSStatus initialize();
    OSStatus uninitialize();
    OSStatus start();
    OSStatus stop();

    WEBCORE_EXPORT void setSwitch(Switch, bool);
#if HAVE(VOICEACTIVITYDETECTION) && !PLATFORM(MAC)
    OSStatus setMutedSpeechActivityListener(bool);
#endif

    // The context the microphone hands its quanta to (deliverToCxxObservers()), which stays the same for the unit's life,
    // and the track the speaker plays out (or none), which may change while the unit runs.
    WEBCORE_EXPORT void attach(void* deliveryContext, const AudioTrackPlayout*);

    // Tests only, off the main thread, while the main thread leaves the unit alone: renders one quantum into the list by
    // calling the unit's speaker callback directly.
    WEBCORE_EXPORT OSStatus renderSpeakerForTesting(AudioBufferList&, uint32_t frameCount, double sampleTime, AudioUnitRenderActionFlags*);

    struct Counters {
        uint64_t microphoneProcCount { 0 };
        std::optional<uint32_t> failedRenderFrameCount;
    };
    Counters counters() const;

    void setEventHandler(Function<void(OptionSet<AudioOutputUnit::Event>)>&&);

    // A mock's device sample rate (0: none) and the buffer size its quanta follow; pausing and resuming its quanta.
    void configureMock(double deviceSampleRate, size_t bufferSize);
    void setMockPaused(bool);
    static void setMockIncreaseBufferSize(bool);

private:
    AudioCaptureUnitHandle(uint64_t identifier, Kind);
    OSStatus setSmallPropertyBytes(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, uint64_t bytes, uint32_t size);

    const uint64_t m_identifier;
    const Kind m_kind;
    bool m_isDestroyed { false };
    Function<void(OptionSet<AudioOutputUnit::Event>)> m_eventHandler;
};

template<typename T> OSStatus AudioCaptureUnitHandle::setSmallProperty(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, const T& value)
{
    static_assert(sizeof(T) <= sizeof(uint64_t) && std::is_trivially_copyable_v<T>);
    uint64_t bytes = 0;
    memcpySpan(asMutableByteSpan(bytes).first(sizeof(T)), asByteSpan(value));
    return setSmallPropertyBytes(property, scope, element, bytes, sizeof(T));
}
#endif // ENABLE(MEDIA_STREAM)

} // namespace WebCore

#endif // (ENABLE(WEB_AUDIO) || ENABLE(MEDIA_STREAM)) && USE(MEDIATOOLBOX)
