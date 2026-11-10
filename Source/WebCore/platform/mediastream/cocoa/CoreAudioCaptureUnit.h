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

#include <WebCore/AudioCaptureControllerHandle.h>
#include <WebCore/CAAudioStreamDescription.h>
#include <WebCore/RealtimeMediaSourceCapabilities.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/HashSet.h>
#include <wtf/Lock.h>
#include <wtf/ThreadSafeWeakHashSet.h>
#include <wtf/text/WTFString.h>

struct AudioBufferList;

namespace WebCore {

#if PLATFORM(IOS_FAMILY)
class MediaCaptureStatusBarManager;
#endif

class AudioCaptureSink;
class AudioSampleBufferList;
class CaptureDevice;
class CoreAudioCaptureSource;
class CoreAudioSpeakerSamplesProducer;
struct AudioCaptureTimes;

// A microphone capture unit, which AudioCaptureController.swift implements: this holds the unit's clients, its capture
// device's persistent ID, its volume, the callbacks of C++ callers and the delivery of the microphone's samples to the
// clients' C++ observers, and does for the controller what needs them (AudioCaptureControllerHandle.h).
class CoreAudioCaptureUnit final : public RefCounted<CoreAudioCaptureUnit>, public RealtimeMediaSourceCenterObserver {
public:
    // The default unit - the only one that may render audio when capturing
    WEBCORE_EXPORT static CoreAudioCaptureUnit& defaultSingleton();
    static Ref<CoreAudioCaptureUnit> createNonVPIOUnit();
    ~CoreAudioCaptureUnit();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    WEBCORE_EXPORT static void forEach(NOESCAPE const Function<void(CoreAudioCaptureUnit&)>&);
    static void forNewUnit(Function<void(CoreAudioCaptureUnit&)>&&);

#if ASSERT_ENABLED
    WEBCORE_EXPORT static void allowStarting();
#endif

    // Whether the unit's next AudioUnit is a mock that needs no hardware (MockAudioCaptureUnit), and the sample rate the unit
    // then takes instead of AudioSession's.
    void setUsesMockUnit(bool);
    void setSampleRateOverride(std::optional<int>);
    void setSampleRateRange(LongCapabilityRange range) { m_sampleRateCapabilities = range; }

    void addClient(CoreAudioCaptureSource&);
    void removeClient(CoreAudioCaptureSource&);
    bool hasClients() const { return !m_clients.isEmptyIgnoringNullReferences(); }

    void startProducingData();
    void stopProducingData();
    void prepareForNewCapture();
    void setCaptureDevice(String&&, uint32_t, bool isDefault);
    WEBCORE_EXPORT void reconfigure();
    void suspend();
    void resume();
    void delaySamples(Seconds);

    double volume() const { return m_volume; }
    void setVolume(double);
    int sampleRate() const;
    void setSampleRate(int);
    bool enableEchoCancellation() const;
#if !PLATFORM(MAC)
    void setEnableEchoCancellation(bool);
#endif
    int actualSampleRate() const;
    LongCapabilityRange sampleRateCapacities() const { return m_sampleRateCapabilities; }
    bool isRenderingAudio() const;
    WEBCORE_EXPORT bool isSuspended() const;
    WEBCORE_EXPORT bool isRunning() const;
    bool canRenderAudio() const;
    const std::optional<CAAudioStreamDescription>& microphoneProcFormat() const LIFETIME_BOUND { return m_microphoneProcFormat; }

    void registerSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer&);
    void unregisterSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer&);

#if PLATFORM(IOS_FAMILY)
    void setIsInBackground(bool);
    void setStatusBarWasTappedCallback(Function<void(CompletionHandler<void()>&&)>&& callback) { m_statusBarWasTappedCallback = WTF::move(callback); }
#endif

    WEBCORE_EXPORT void enableMutedSpeechActivityEventListener(Function<void()>&&);
    WEBCORE_EXPORT void disableMutedSpeechActivityEventListener();

#if PLATFORM(MAC)
    WEBCORE_EXPORT void prewarmAudioUnitCreation();
#endif

    WEBCORE_EXPORT void setMuteStatusChangedCallback(Function<void(bool)>&&);

    void handleNewCurrentMicrophoneDevice(const CaptureDevice&);

    // What the microphone does with each quantum, from the clients: the sinks of those that produce data, the volume, and
    // whether any of those has C++ observers.
    void updateMicrophoneConfiguration();

    // On the unit's microphone IO thread (deliverToCxxObservers()).
    void deliverMicrophoneSamples(const AudioBufferList&, uint32_t frameCount, const AudioCaptureTimes&);

    // What the controller tells the unit (AudioCaptureControllerHandle.h).
    void didChange(AudioCaptureControllerEvent, bool value);
    AudioCaptureMicrophoneBufferSizes allocateMicrophoneBuffer(const AudioStreamBasicDescription&, uint64_t bufferSize);

private:
    explicit CoreAudioCaptureUnit(bool canEnableEchoCancellation);

    AudioCaptureControllerState state() const;
    void forEachClient(NOESCAPE const Function<void(CoreAudioCaptureSource&)>&) const;
    Vector<WeakPtr<AudioCaptureSink>> clientSinks() const;
    void clearClients();
    void configureMock();
#if PLATFORM(MAC)
    bool migrateToNewDefaultDevice(const CaptureDevice&);
#endif
#if !LOG_DISABLED
    void checkTimestamps(double sampleTime, double hostTime);
#endif

    // RealtimeMediaSourceCenterObserver
    void devicesChanged() final;
    void deviceWillBeRemoved(const String&) final { }

    AudioCaptureControllerHandle m_controller;
    double m_volume { 1 };
    String m_persistentID;
    uint32_t m_captureDeviceID { 0 };
    bool m_isCapturingWithDefaultMicrophone { false };
    bool m_usesMockUnit { false };
    std::optional<int> m_sampleRateOverride;
    LongCapabilityRange m_sampleRateCapabilities { 8000, 96000 };

    ThreadSafeWeakHashSet<CoreAudioCaptureSource> m_clients;
    Vector<ThreadSafeWeakPtr<CoreAudioCaptureSource>> m_audioThreadClients WTF_GUARDED_BY_LOCK(m_audioThreadClientsLock);
    Lock m_audioThreadClientsLock;
    HashSet<uint64_t> m_attachedSinkIdentifiers;

    // Only modified while the unit is stopped, and read on its IO thread.
    std::optional<CAAudioStreamDescription> m_microphoneProcFormat;
    RefPtr<AudioSampleBufferList> m_microphoneSampleBuffer;
    double m_latestMicTimeStamp { 0 };

    CoreAudioSpeakerSamplesProducer* m_speakerSamplesProducer { nullptr };
    Function<void()> m_voiceActivityCallback;
    Function<void(bool)> m_muteStatusChangedCallback;
#if PLATFORM(IOS_FAMILY)
    RefPtr<MediaCaptureStatusBarManager> m_statusBarManager;
    Function<void(CompletionHandler<void()>&&)> m_statusBarWasTappedCallback;
#endif
};

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
