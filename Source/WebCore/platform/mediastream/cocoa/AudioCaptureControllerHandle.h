/*
 * Copyright (C) 2017-2022 Apple Inc. All rights reserved.
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <wtf/Platform.h>
#if ENABLE(MEDIA_STREAM)

#include <CoreAudio/CoreAudioTypes.h>
#include <CoreFoundation/CFString.h>
#include <WebCore/CaptureSourceDecisions.h>
#include <WebCore/CARingBufferSwiftBridge.h>
#include <cstdint>
#include <wtf/SwiftBridging.h>
#include <wtf/text/WTFString.h>

// A microphone capture unit, as AudioCaptureController.swift implements it: CoreAudioCaptureUnit holds one by identifier,
// calls it with plain values, and does what only C++ can do, for its clients and the callbacks C++ gave it, through the
// functions at the end of this file. Main thread only.

namespace WebCore {

struct AudioCaptureControllerState {
    double volume { 1 };
    int32_t sampleRate { 0 };
    // The speaker's producer's sample rate while one is registered, otherwise sampleRate.
    int32_t actualSampleRate { 0 };
    bool enableEchoCancellation { false };
    // Whether the unit is, or its next one will be, a voice processing unit.
    bool usesVoiceProcessing { false };
    bool isSuspended { false };
    bool isRunning { false };
    bool canRenderAudio { false };
    bool isRenderingAudio { false };
    bool hasAudioUnit { false };
};

// What CoreAudioCaptureUnit tells the controller's Swift clients about capture devices.
enum class AudioCaptureDeviceEvent : uint8_t {
    // The voice processing unit is about to capture from the device with this persistent ID.
    VPIOUnitWillChangeCaptureDevice,
    // The default microphone that the unit captures from is now this one.
    NewCurrentMicrophoneDevice,
};

enum class AudioCaptureDeviceChange : uint8_t {
    // The device is the same one.
    Set,
    // The device is about to change.
    WillChange,
    // The device changed to this one.
    Changed,
};

class SWIFT_PRIVATE_FILEID("WebCore/AudioCaptureController.swift") AudioCaptureControllerHandle {
public:
    AudioCaptureControllerHandle() = default;
    explicit AudioCaptureControllerHandle(uint64_t identifier)
        : m_identifier(identifier)
    {
    }

    // The default unit is the one that can cancel echo.
    static uint64_t create(bool canEnableEchoCancellation);
    void destroy();
    uint64_t identifier() const { return m_identifier; }

    AudioCaptureControllerState state() const;

    // Whether the unit's next AudioUnit is a mock (MockAudioCaptureUnit), and the sample rate the unit then takes instead of
    // AudioSession's (0: AudioSession's).
    void configureMock(bool usesMockUnit, int32_t sampleRateOverride) const;
    // The mocks' quanta fake a microphone buffer that is too small, until a buffer is big enough.
    static void setMockIncreaseBufferSize(bool);

    void clientWasRemoved() const;
    void startProducingData() const;
    void stopProducingData() const;
    void prepareForNewCapture() const;
    void changeCaptureDevice(AudioCaptureDeviceChange, uint32_t deviceID) const;
    void setEnableEchoCancellation(bool) const;
    void setSampleRate(int32_t) const;
    void reconfigure() const;
    void suspend() const;
    void resume() const;
    void delaySamples(double seconds) const;
    void validateOutputDevice() const;
    void captureFailed() const;

    void setHasVoiceActivityListener(bool) const;
    static void setHasMuteStatusListener(bool);
    void prewarmAudioUnitCreation() const;

    // What the microphone does with each quantum for the C++ clients: their sinks, whether they get the samples through
    // their C++ observers, and whether one is waiting for its first quantum. The controller's Swift clients have theirs too.
    void attachSink(uint64_t sinkIdentifier, bool) const;
    void setCxxMicrophoneOptions(bool deliversToCxx, bool needsFirstQuantum) const;
    // The volume, which the microphone's samples are multiplied by, for every client.
    void setVolume(double) const;

    // For the controller's Swift clients.
    void captureDeviceDidChange(AudioCaptureDeviceEvent, CFStringRef WTF_NONNULL persistentID, CFStringRef WTF_NONNULL label) const;

    // CoreAudioCaptureSource's settings, and its capabilities with this echo cancellation (a
    // RealtimeMediaSourceCapabilities::EchoCancellation) and sample rate range.
    static CaptureSettingsValues microphoneSettings(double volume, int32_t sampleRate, bool echoCancellation);
    static CaptureCapabilityValues microphoneCapabilities(uint32_t settingsSupportedConstraints, uint8_t echoCancellation, int32_t sampleRateMin, int32_t sampleRateMax);

private:
    uint64_t m_identifier { 0 };
};

enum class AudioCaptureControllerEvent : uint8_t {
    UnitWillStart,
    CaptureFailed,
    Suspended,
    Resumed,
    EchoCancellationChanged,
    // The unit has a new AudioUnit, which needs the clients' sinks and options.
    MicrophoneConfigurationNeeded,
    // The microphone has a new format: the sinks of other formats need it.
    MicrophoneFormatChanged,
    FirstMicrophoneQuantum,
    SinkStarted,
    AudioUnitReleased,
    UnitStopped,
    VoiceActivityDetected,
    // value: whether the microphone is muted.
    MuteStatusChanged,
};

void coreAudioCaptureUnitDidChange(uint64_t controller, AudioCaptureControllerEvent, bool value);
// The C++ clients only.
bool coreAudioCaptureUnitHasClients(uint64_t controller);
// The buffers for the microphone's new format, of bufferSize bytes.
AudioCaptureMicrophoneBufferSizes coreAudioCaptureUnitAllocateMicrophoneBuffer(uint64_t controller, AudioStreamBasicDescription, uint64_t bufferSize);

// The units of the controllers that Swift clients capture with (implemented by CoreAudioCaptureUnit.cpp). The default unit
// lives as long as the process; a unit without echo cancellation, until it is released.
SWIFT_MAIN_ACTOR uint64_t coreAudioCaptureDefaultController();
#if PLATFORM(MAC)
SWIFT_MAIN_ACTOR uint64_t coreAudioCaptureCreateControllerWithoutEchoCancellation();
SWIFT_MAIN_ACTOR void coreAudioCaptureReleaseController(uint64_t controller);
#endif
struct AudioCaptureSampleRateRange {
    int32_t minimum { 0 };
    int32_t maximum { 0 };
};
// The sample rates the unit's clients can ask for.
SWIFT_MAIN_ACTOR AudioCaptureSampleRateRange coreAudioCaptureUnitSampleRateRange(uint64_t controller);
#if PLATFORM(IOS_FAMILY)
// Whether AVAudioSession has the microphone, or it is the default one (CoreAudioCaptureSource::create()).
SWIFT_MAIN_ACTOR bool audioCaptureSessionHasMicrophone(const String& persistentID, bool isDefault);
#endif
// CoreAudioCaptureUnit::setCaptureDevice(), for a Swift client.
SWIFT_MAIN_ACTOR void coreAudioCaptureUnitSetCaptureDevice(uint64_t controller, const String& persistentID, uint32_t deviceID, bool isDefault);
#if PLATFORM(IOS_FAMILY)
SWIFT_MAIN_ACTOR void coreAudioCaptureUnitSetIsInBackground(uint64_t controller, bool);
#endif

double audioCaptureSessionSampleRate();
uint64_t audioCaptureSessionBufferSize();
// Whether AudioSession's category lets the unit start.
bool audioCaptureSessionCanStartCapture();
// The default sample rate of the mock microphone with the given device ID, or 0.
double audioCaptureMockMicrophoneSampleRate(uint32_t deviceID);

#if PLATFORM(MAC)
// A capture device by persistent ID (AudioCaptureDevices.swift).
struct AudioCaptureDeviceLookup {
    uint32_t deviceID { 0 };
    bool found { false };
};

void coreAudioCaptureDevicesDidChange();
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
