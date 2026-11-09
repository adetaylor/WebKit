/*
 * Copyright (C) 2017-2022 Apple Inc. All rights reserved.
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

#include <WebCore/AudioSampleDataSource.h>
#include <WebCore/BaseAudioCaptureUnit.h>
#include <WebCore/CAAudioStreamDescription.h>
#include <WebCore/CoreAudioCaptureSource.h>
#include <WebCore/Timer.h>
#include <wtf/HashSet.h>

OBJC_CLASS WebCoreAudioInputMuteChangeListener;

typedef UInt32 AudioUnitPropertyID;
typedef UInt32 AudioUnitScope;
typedef UInt32 AudioUnitElement;

struct AudioBufferList;

namespace WebCore {

#if PLATFORM(IOS_FAMILY)
class MediaCaptureStatusBarManager;
#endif

class AudioCaptureUnitHandle;
class CoreAudioSpeakerSamplesProducer;
struct AudioCaptureTimes;

class CoreAudioCaptureUnit final : public BaseAudioCaptureUnit {
public:
    // The default unit - the only one that may render audio when capturing
    WEBCORE_EXPORT static CoreAudioCaptureUnit& defaultSingleton();
    static Ref<CoreAudioCaptureUnit> createNonVPIOUnit();
    ~CoreAudioCaptureUnit();

    WEBCORE_EXPORT static void forEach(NOESCAPE const Function<void(CoreAudioCaptureUnit&)>&);
    static void forNewUnit(Function<void(CoreAudioCaptureUnit&)>&&);

    // Whether the unit's next AudioUnit is a mock that needs no hardware (MockAudioCaptureUnit).
    void setUsesMockUnit(bool usesMockUnit) { m_usesMockUnit = usesMockUnit; }
    using GetSampleRateCallback = Function<int()>;
    void setInternalUnitGetSampleRateCallback(GetSampleRateCallback&& callback) { m_getSampleRateCallback = WTF::move(callback); }

    void registerSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer&);
    void unregisterSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer&);
    bool isRunning() const { return m_ioUnitStarted; }
    void setSampleRateRange(LongCapabilityRange range) { m_sampleRateCapabilities = range; }

#if PLATFORM(IOS_FAMILY)
    void setIsInBackground(bool);
    void setStatusBarWasTappedCallback(Function<void(CompletionHandler<void()>&&)>&& callback) { m_statusBarWasTappedCallback = WTF::move(callback); }
#endif

    bool canRenderAudio() const { return m_canRenderAudio; }

    WEBCORE_EXPORT void enableMutedSpeechActivityEventListener(Function<void()>&&);
    WEBCORE_EXPORT void disableMutedSpeechActivityEventListener();

#if PLATFORM(MAC)
    WEBCORE_EXPORT void prewarmAudioUnitCreation(CompletionHandler<void()>&&) final;
#endif

    WEBCORE_EXPORT void setMuteStatusChangedCallback(Function<void(bool)>&&);
    void handleMuteStatusChangedNotification(bool);

    const std::optional<CAAudioStreamDescription>& microphoneProcFormat() const LIFETIME_BOUND { return m_microphoneProcFormat; }

    LongCapabilityRange sampleRateCapacities() const final { return m_sampleRateCapabilities; }
    int actualSampleRate() const final;

    void delaySamples(Seconds) final;

    // On the unit's microphone IO thread (deliverToCxxObservers()).
    void deliverMicrophoneSamples(const AudioBufferList&, uint32_t frameCount, const AudioCaptureTimes&);

    // What the microphone does with each quantum, from the clients: the sinks of those that produce data, the volume, and
    // whether any of those has C++ observers.
    void updateMicrophoneConfiguration();

private:
    explicit CoreAudioCaptureUnit(CanEnableEchoCancellation);

    friend class NeverDestroyed<CoreAudioCaptureUnit>;
    friend void audioCaptureVoiceActivityDetected();

    static size_t preferredIOBufferSize();


    bool hasAudioUnit() const final { return !!m_ioUnit; }
    void captureDeviceChanged() final;
    OSStatus reconfigureAudioUnit() final;

    OSStatus setupAudioUnit();
    void cleanupAudioUnit() final;

    OSStatus startInternal() final;
    void stopInternal() final;
    bool isProducingData() const final { return m_ioUnitStarted; }
    void isProducingMicrophoneSamplesChanged() final;
    void volumeChanged() final { updateMicrophoneConfiguration(); }
    void clientsChanged() final { updateMicrophoneConfiguration(); }
    void validateOutputDevice(uint32_t deviceID) final;
#if PLATFORM(MAC)
    bool migrateToNewDefaultDevice(const CaptureDevice&) final;
    void storedVPIOUnitWasKept();
    void deallocateStoredVPIOUnit();
#endif
    void resetSampleRate();

    void willChangeCaptureDeviceTo(const String&) final;

    OSStatus configureSpeakerProc(int sampleRate);
    OSStatus configureMicrophoneProc(int sampleRate);

    // What the AudioUnit (or its mock) did and does not need the AudioUnit for.
    OSStatus setUnitProperty(AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, uint32_t);
    OSStatus defaultInputDevice(uint32_t&);
    OSStatus defaultOutputDevice(uint32_t&);
    bool setUnitVoiceActivityDetection(bool);
    Seconds verifyCaptureInterval(bool isProducingSamples) const;
    void attachSpeakerSamplesProducer();
    // AudioOutputUnit::Event bits.
    void handleUnitEvents(uint32_t);
    void mockVoiceDetected();

    void unduck();

    void verifyIsCapturing();
    void updateMutedStateTimerFired();

    void updateVoiceActivityDetection(bool shouldDisableVoiceActivityDetection = false);
    NODELETE bool shouldEnableVoiceActivityDetection() const;
    RetainPtr<WebCoreAudioInputMuteChangeListener> createAudioInputMuteChangeListener();
    void setMutedState(bool isMuted);

    enum class SyncUpdate : bool { No, Yes };
    void updateMutedState(SyncUpdate = SyncUpdate::No);

    static bool isAnyUnitCapturingExceptFor(CoreAudioCaptureUnit*);
    static bool isAnyUnitCapturing();

    bool m_usesMockUnit { false };
    GetSampleRateCallback m_getSampleRateCallback;
    std::unique_ptr<AudioCaptureUnitHandle> m_ioUnit;
    HashSet<uint64_t> m_attachedSinkIdentifiers;

    // Only read/modified from the IO thread.
    Vector<Ref<AudioSampleDataSource>> m_activeSources;

    std::optional<CAAudioStreamDescription> m_microphoneProcFormat;
    RefPtr<AudioSampleBufferList> m_microphoneSampleBuffer;
    double m_latestMicTimeStamp { 0 };

    std::optional<CAAudioStreamDescription> m_speakerProcFormat;

    double m_DTSConversionRatio { 0 };

    bool m_ioUnitInitialized { false };
    bool m_ioUnitStarted { false };

    mutable std::unique_ptr<RealtimeMediaSourceCapabilities> m_capabilities;
    mutable std::optional<RealtimeMediaSourceSettings> m_currentSettings;

#if !LOG_DISABLED
    void checkTimestamps(double sampleTime, double hostTime);

#endif

    LongCapabilityRange m_sampleRateCapabilities;

    uint64_t m_microphoneProcsCalledLastTime { 0 };
    const std::unique_ptr<Timer> m_verifyCapturingTimer;

    const std::unique_ptr<Timer> m_updateMutedStateTimer;

    std::optional<size_t> m_minimumMicrophoneSampleFrames;
    bool m_isReconfiguring { false };
    mutable Lock m_speakerSamplesProducerLock;
    CoreAudioSpeakerSamplesProducer* m_speakerSamplesProducer WTF_GUARDED_BY_LOCK(m_speakerSamplesProducerLock) { nullptr };

#if PLATFORM(IOS_FAMILY)
    RefPtr<MediaCaptureStatusBarManager> m_statusBarManager;
    Function<void(CompletionHandler<void()>&&)> m_statusBarWasTappedCallback;
#endif

    bool m_shouldUseVPIO { true };
    bool m_canRenderAudio { true };
    bool m_voiceActivityDetectionEnabled { false };
    // A mock AudioUnit's: whether its output is muted, whether it detects voice activity, which it then fakes, and how long
    // it pauses its samples.
    bool m_mockOutputMuted { false };
    bool m_mockVoiceActivityDetectionEnabled { false };
    std::unique_ptr<Timer> m_mockVoiceDetectionTimer;
    std::unique_ptr<Timer> m_mockDelayTimer;
#if PLATFORM(MAC)
    bool m_hasStoredVPIOUnit { false };
    Timer m_storedVPIOUnitDeallocationTimer;
    RefPtr<GenericNonExclusivePromise> m_audioUnitCreationWarmupPromise;
#endif
#if HAVE(AVAUDIOAPPLICATION)
    RetainPtr<WebCoreAudioInputMuteChangeListener> m_inputMuteChangeListener;
#endif
    Function<void(bool)> m_muteStatusChangedCallback;
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
