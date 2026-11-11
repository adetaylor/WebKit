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
#include <WebCore/CARingBufferSwiftBridge.h>
#include <cstdint>
#include <wtf/SwiftBridging.h>

// A microphone capture unit, as AudioCaptureController.swift implements it: CoreAudioCaptureUnit holds one by identifier,
// calls it with plain values, and does what only C++ can do, for its clients and the callbacks C++ gave it, through the
// functions at the end of this file. Main thread only.

namespace WebCore {

struct AudioCaptureControllerState {
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

    // What the microphone does with each quantum: the sinks of the clients, and whether the producing ones get the samples
    // with the volume applied, and through the C++ observers.
    void attachSink(uint64_t sinkIdentifier, bool) const;
    void setMicrophoneOptions(float gain, bool appliesGain, bool deliversToCxx, bool armFirstQuantum) const;

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
bool coreAudioCaptureUnitHasClients(uint64_t controller);
// The buffers for the microphone's new format, of bufferSize bytes.
AudioCaptureMicrophoneBufferSizes coreAudioCaptureUnitAllocateMicrophoneBuffer(uint64_t controller, AudioStreamBasicDescription, uint64_t bufferSize);

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
