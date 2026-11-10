/*
 * Copyright (C) 2017-2023 Apple Inc. All rights reserved.
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


#include "config.h"
#include "CoreAudioCaptureUnit.h"

#if ENABLE(MEDIA_STREAM)

#include "AudioOutputUnit.h"
#include "AudioSampleBufferList.h"
#include "AudioSession.h"
#include "CoreAudioCaptureSource.h"
#include "DeprecatedGlobalSettings.h"
#include "Logging.h"
#include "MockAudioCaptureUnit.h"
#include <algorithm>
#include <wtf/HashMap.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/WeakHashSet.h>

#if PLATFORM(IOS_FAMILY)
#include "AVAudioSessionCaptureDeviceManager.h"
#include "MediaCaptureStatusBarManager.h"
#endif

#if PLATFORM(MAC)
#include "CoreAudioCaptureDeviceManager.h"
#endif

namespace WebCore {

#if ASSERT_ENABLED
static bool s_isBaseAudioCaptureUnitAllowedToStart = false;

void CoreAudioCaptureUnit::allowStarting()
{
    s_isBaseAudioCaptureUnitAllowedToStart = true;
}
#endif

NODELETE static WeakHashSet<CoreAudioCaptureUnit>& allCoreAudioCaptureUnits()
{
    ASSERT(isMainThread());

    static NeverDestroyed<WeakHashSet<CoreAudioCaptureUnit>> units;
    return units;
}

// The units by their controller's identifier, for the controller's calls.
NODELETE static HashMap<uint64_t, WeakPtr<CoreAudioCaptureUnit>>& unitsByController()
{
    ASSERT(isMainThread());

    static NeverDestroyed<HashMap<uint64_t, WeakPtr<CoreAudioCaptureUnit>>> units;
    return units;
}

static RefPtr<CoreAudioCaptureUnit> unitForController(uint64_t controller)
{
    return unitsByController().get(controller);
}

void coreAudioCaptureUnitDidChange(uint64_t controller, AudioCaptureControllerEvent event, bool value)
{
    if (RefPtr unit = unitForController(controller))
        unit->didChange(event, value);
}

bool coreAudioCaptureUnitHasClients(uint64_t controller)
{
    RefPtr unit = unitForController(controller);
    return unit && unit->hasClients();
}

AudioCaptureMicrophoneBufferSizes coreAudioCaptureUnitAllocateMicrophoneBuffer(uint64_t controller, AudioStreamBasicDescription format, uint64_t bufferSize)
{
    RefPtr unit = unitForController(controller);
    if (!unit)
        return { };
    return unit->allocateMicrophoneBuffer(format, bufferSize);
}

double audioCaptureSessionSampleRate()
{
    return AudioSession::singleton().sampleRate();
}

uint64_t audioCaptureSessionBufferSize()
{
    return AudioSession::singleton().bufferSize();
}

bool audioCaptureSessionCanStartCapture()
{
    ASSERT(!DeprecatedGlobalSettings::shouldManageAudioSessionCategory() || AudioSession::singleton().category() == AudioSession::CategoryType::PlayAndRecord);

#if PLATFORM(IOS_FAMILY)
    if (AudioSession::singleton().category() != AudioSession::CategoryType::PlayAndRecord) {
        RELEASE_LOG_ERROR(WebRTC, "BaseAudioCaptureUnit::startUnit cannot call startInternal if category is not set to PlayAndRecord");
        return false;
    }
#endif
    return true;
}

double audioCaptureMockMicrophoneSampleRate(uint32_t deviceID)
{
    return MockAudioCaptureUnit::defaultSampleRateForDevice(deviceID).value_or(0);
}

void deliverToCxxObservers(void* context, const AudioBufferList* list, uint32_t frameCount, const AudioCaptureTimes& times)
{
    static_cast<CoreAudioCaptureUnit*>(context)->deliverMicrophoneSamples(*list, frameCount, times);
}

CoreAudioCaptureUnit& CoreAudioCaptureUnit::defaultSingleton()
{
    static NeverDestroyed<Ref<CoreAudioCaptureUnit>> singleton(adoptRef(*new CoreAudioCaptureUnit(true)));
    return singleton.get();
}

Ref<CoreAudioCaptureUnit> CoreAudioCaptureUnit::createNonVPIOUnit()
{
    return adoptRef(*new CoreAudioCaptureUnit(false));
}

void CoreAudioCaptureUnit::forEach(NOESCAPE const Function<void(CoreAudioCaptureUnit&)>& callback)
{
    allCoreAudioCaptureUnits().forEach(callback);
}

NODELETE static Function<void(CoreAudioCaptureUnit&)>& coreAudioCaptureNewUnitCallback()
{
    ASSERT(isMainThread());

    static NeverDestroyed<Function<void(CoreAudioCaptureUnit&)>> callback;
    return callback.get();
}

void CoreAudioCaptureUnit::forNewUnit(Function<void(CoreAudioCaptureUnit&)>&& callback)
{
    coreAudioCaptureNewUnitCallback() = WTF::move(callback);
}

CoreAudioCaptureUnit::CoreAudioCaptureUnit(bool canEnableEchoCancellation)
    : m_controller(AudioCaptureControllerHandle::create(canEnableEchoCancellation))
{
    attachAudioCaptureDeliveryContext(m_controller.identifier(), this);
    unitsByController().add(m_controller.identifier(), *this);
    RealtimeMediaSourceCenter::singleton().addDevicesChangedObserver(*this);

    allCoreAudioCaptureUnits().add(*this);
    if (coreAudioCaptureNewUnitCallback())
        coreAudioCaptureNewUnitCallback()(*this);
}

CoreAudioCaptureUnit::~CoreAudioCaptureUnit()
{
    allCoreAudioCaptureUnits().remove(*this);
    unitsByController().remove(m_controller.identifier());

    m_controller.destroy();
    setMuteStatusChangedCallback({ });

    RealtimeMediaSourceCenter::singleton().removeDevicesChangedObserver(*this);
}

AudioCaptureControllerState CoreAudioCaptureUnit::state() const
{
    return m_controller.state();
}

int CoreAudioCaptureUnit::sampleRate() const
{
    return state().sampleRate;
}

bool CoreAudioCaptureUnit::enableEchoCancellation() const
{
    return state().enableEchoCancellation;
}

int CoreAudioCaptureUnit::actualSampleRate() const
{
    return state().actualSampleRate;
}

bool CoreAudioCaptureUnit::isRenderingAudio() const
{
    return state().isRenderingAudio;
}

bool CoreAudioCaptureUnit::isSuspended() const
{
    return state().isSuspended;
}

bool CoreAudioCaptureUnit::isRunning() const
{
    return state().isRunning;
}

bool CoreAudioCaptureUnit::canRenderAudio() const
{
    return state().canRenderAudio;
}

void CoreAudioCaptureUnit::configureMock()
{
    m_controller.configureMock(m_usesMockUnit, m_sampleRateOverride.value_or(0));
}

void CoreAudioCaptureUnit::setUsesMockUnit(bool usesMockUnit)
{
    m_usesMockUnit = usesMockUnit;
    configureMock();
}

void CoreAudioCaptureUnit::setSampleRateOverride(std::optional<int> sampleRate)
{
    m_sampleRateOverride = sampleRate;
    configureMock();
}

void CoreAudioCaptureUnit::addClient(CoreAudioCaptureSource& client)
{
    ASSERT(isMainThread());
    m_clients.add(client);
    {
        Locker locker { m_audioThreadClientsLock };
        m_audioThreadClients = m_clients.weakValues();
    }
    updateMicrophoneConfiguration();
}

void CoreAudioCaptureUnit::removeClient(CoreAudioCaptureSource& client)
{
    ASSERT(isMainThread());
    m_clients.remove(client);
    {
        Locker locker { m_audioThreadClientsLock };
        m_audioThreadClients = m_clients.weakValues();
    }
    updateMicrophoneConfiguration();
    m_controller.clientWasRemoved();
}

void CoreAudioCaptureUnit::clearClients()
{
    ASSERT(isMainThread());
    m_clients.clear();
    Locker locker { m_audioThreadClientsLock };
    m_audioThreadClients.clear();
}

void CoreAudioCaptureUnit::forEachClient(NOESCAPE const Function<void(CoreAudioCaptureSource&)>& apply) const
{
    ASSERT(isMainThread());
    m_clients.forEach(apply);
}

Vector<WeakPtr<AudioCaptureSink>> CoreAudioCaptureUnit::clientSinks() const
{
    Vector<WeakPtr<AudioCaptureSink>> sinks;
    forEachClient([&](auto& client) {
        sinks.appendVector(client.audioCaptureSinks());
    });
    return sinks;
}

void CoreAudioCaptureUnit::startProducingData()
{
    ASSERT(isMainThread());
    ASSERT(s_isBaseAudioCaptureUnitAllowedToStart);
    m_controller.startProducingData();
}

void CoreAudioCaptureUnit::stopProducingData()
{
    ASSERT(isMainThread());
    m_controller.stopProducingData();
}

void CoreAudioCaptureUnit::prepareForNewCapture()
{
    m_volume = 1;
    updateMicrophoneConfiguration();
    m_controller.prepareForNewCapture();
}

void CoreAudioCaptureUnit::setCaptureDevice(String&& persistentID, uint32_t captureDeviceID, bool isDefault)
{
    bool hasChanged = m_persistentID != persistentID || m_captureDeviceID != captureDeviceID || m_isCapturingWithDefaultMicrophone != isDefault;
    if (hasChanged) {
#if PLATFORM(MAC)
        if (state().usesVoiceProcessing) {
            forEachClient([&persistentID](auto& client) {
                client.vpioUnitWillChangeCaptureDeviceTo(persistentID);
            });
        }
#endif
        m_controller.changeCaptureDevice(AudioCaptureDeviceChange::WillChange, captureDeviceID);
    }

    m_persistentID = WTF::move(persistentID);
    m_captureDeviceID = captureDeviceID;
    m_isCapturingWithDefaultMicrophone = isDefault;

    if (!hasChanged) {
        m_controller.changeCaptureDevice(AudioCaptureDeviceChange::Set, captureDeviceID);
        return;
    }
#if !PLATFORM(MAC)
    AVAudioSessionCaptureDeviceManager::singleton().setPreferredMicrophoneID(m_isCapturingWithDefaultMicrophone ? String { } : m_persistentID);
#endif
    m_controller.changeCaptureDevice(AudioCaptureDeviceChange::Changed, captureDeviceID);
}

void CoreAudioCaptureUnit::reconfigure()
{
    ASSERT(isMainThread());
    m_controller.reconfigure();
}

void CoreAudioCaptureUnit::suspend()
{
    ASSERT(isMainThread());
    m_controller.suspend();
}

void CoreAudioCaptureUnit::resume()
{
    ASSERT(isMainThread());
    m_controller.resume();
}

void CoreAudioCaptureUnit::delaySamples(Seconds seconds)
{
    m_controller.delaySamples(seconds.value());
}

void CoreAudioCaptureUnit::setVolume(double volume)
{
    m_volume = volume;
    updateMicrophoneConfiguration();
}

void CoreAudioCaptureUnit::setSampleRate(int sampleRate)
{
    m_controller.setSampleRate(sampleRate);
}

#if !PLATFORM(MAC)
void CoreAudioCaptureUnit::setEnableEchoCancellation(bool enableEchoCancellation)
{
    m_controller.setEnableEchoCancellation(enableEchoCancellation);
}
#endif

void CoreAudioCaptureUnit::devicesChanged()
{
    Ref protectedThis { *this };

    if (!state().hasAudioUnit)
        return;

    auto devices = RealtimeMediaSourceCenter::singleton().audioCaptureFactory().audioCaptureDeviceManager().captureDevices();
    auto persistentID = m_persistentID;
    if (persistentID.isEmpty())
        return;

    if (std::ranges::any_of(devices, [&persistentID](auto& device) { return persistentID == device.persistentId(); })) {
        m_controller.validateOutputDevice();
        return;
    }

#if PLATFORM(MAC)
    if (devices.size() && m_isCapturingWithDefaultMicrophone && migrateToNewDefaultDevice(devices[0])) {
        RELEASE_LOG_ERROR(WebRTC, "BaseAudioCaptureUnit::devicesChanged - migrating to new default device");
        return;
    }
#endif

    RELEASE_LOG_ERROR(WebRTC, "BaseAudioCaptureUnit::devicesChanged - failing capture, capturing device is missing");
    m_controller.captureFailed();
}

#if PLATFORM(MAC)
bool CoreAudioCaptureUnit::migrateToNewDefaultDevice(const CaptureDevice& captureDevice)
{
    auto newDefaultDevicePersistentId = captureDevice.persistentId();
    auto deviceID = CoreAudioCaptureDeviceManager::singleton().coreAudioDeviceWithUID(newDefaultDevicePersistentId);
    if (!deviceID)
        return false;

    // We were capturing with the default device which disappeared, let's move capture to the new default device.
    setCaptureDevice(WTF::move(newDefaultDevicePersistentId), *deviceID, true);
    handleNewCurrentMicrophoneDevice(captureDevice);
    return true;
}

void CoreAudioCaptureUnit::prewarmAudioUnitCreation()
{
    m_controller.prewarmAudioUnitCreation();
}
#endif

void CoreAudioCaptureUnit::handleNewCurrentMicrophoneDevice(const CaptureDevice& device)
{
    forEachClient([&device](auto& client) {
        client.handleNewCurrentMicrophoneDevice(device);
    });
}

void CoreAudioCaptureUnit::updateMicrophoneConfiguration()
{
    ASSERT(isMainThread());
    if (!state().hasAudioUnit)
        return;

    bool deliversToCxx = false;
    bool needsFirstQuantum = false;
    HashSet<uint64_t> sinkIdentifiers;
    forEachClient([&](auto& client) {
        bool isProducing = client.isProducingData();
        if (isProducing && client.hasAudioSampleObservers())
            deliversToCxx = true;
        if (isProducing && !client.didStartProducingData())
            needsFirstQuantum = true;
        for (auto& weakSink : client.audioCaptureSinks()) {
            auto* sink = weakSink.get();
            if (!sink)
                continue;
            sink->setEnabled(isProducing);
            sinkIdentifiers.add(sink->identifier());
            if (!m_attachedSinkIdentifiers.contains(sink->identifier()))
                m_controller.attachSink(sink->identifier(), true);
        }
    });
    for (auto identifier : m_attachedSinkIdentifiers) {
        if (!sinkIdentifiers.contains(identifier))
            m_controller.attachSink(identifier, false);
    }
    m_attachedSinkIdentifiers = WTF::move(sinkIdentifiers);

    // Delivering the first sample tells the source's observers it started producing data.
    m_controller.setMicrophoneOptions(m_volume, m_volume != 1.0, deliversToCxx, needsFirstQuantum && !deliversToCxx);
}

AudioCaptureMicrophoneBufferSizes CoreAudioCaptureUnit::allocateMicrophoneBuffer(const AudioStreamBasicDescription& format, uint64_t bufferSize)
{
    ASSERT(isMainThread());
    m_microphoneSampleBuffer = AudioSampleBufferList::create(format, bufferSize);
    m_microphoneProcFormat = format;

    AudioCaptureMicrophoneBufferSizes sizes;
    auto buffers = span(*m_microphoneSampleBuffer->bufferList().list());
    sizes.bufferCount = buffers.size();
    if (!buffers.empty()) {
        sizes.channelsPerBuffer = buffers[0].mNumberChannels;
        sizes.bytesPerBuffer = buffers[0].mDataByteSize;
    }
    return sizes;
}

void CoreAudioCaptureUnit::didChange(AudioCaptureControllerEvent event, bool value)
{
    ASSERT(isMainThread());
    switch (event) {
    case AudioCaptureControllerEvent::UnitWillStart:
        forEachClient([](auto& client) {
            client.audioUnitWillStart();
        });
        return;
    case AudioCaptureControllerEvent::CaptureFailed:
        forEachClient([](auto& client) {
            client.captureFailed();
        });
        clearClients();
        return;
    case AudioCaptureControllerEvent::Suspended:
        forEachClient([](auto& client) {
            client.setCanResumeAfterInterruption(client.isProducingData());
            client.setMuted(true);
        });
        return;
    case AudioCaptureControllerEvent::Resumed:
        callOnMainThread([weakThis = WeakPtr { *this }] {
            RefPtr protectedThis = weakThis.get();
            if (!protectedThis || protectedThis->isSuspended())
                return;

            protectedThis->forEachClient([](auto& client) {
                if (client.canResumeAfterInterruption())
                    client.setMuted(false);
            });
        });
        return;
    case AudioCaptureControllerEvent::EchoCancellationChanged:
        forEachClient([](auto& client) {
            client.echoCancellationChanged();
        });
        return;
    case AudioCaptureControllerEvent::MicrophoneConfigurationNeeded:
        m_attachedSinkIdentifiers.clear();
        updateMicrophoneConfiguration();
        return;
    case AudioCaptureControllerEvent::MicrophoneFormatChanged:
        for (auto& weakSink : clientSinks()) {
            if (auto* sink = weakSink.get(); sink && !(*m_microphoneProcFormat == sink->format()))
                sink->notifyFormatChanged();
        }
        return;
    case AudioCaptureControllerEvent::FirstMicrophoneQuantum:
        forEachClient([](auto& client) {
            if (client.isProducingData())
                client.noteStartedProducingData();
        });
        return;
    case AudioCaptureControllerEvent::SinkStarted:
        for (auto& weakSink : clientSinks()) {
            if (auto* sink = weakSink.get())
                sink->notifyStartedIfNeeded();
        }
        return;
    case AudioCaptureControllerEvent::AudioUnitReleased:
        m_microphoneSampleBuffer = nullptr;
        return;
    case AudioCaptureControllerEvent::SpeakerStarting:
        if (m_speakerSamplesProducer)
            m_speakerSamplesProducer->captureUnitIsStarting();
        return;
    case AudioCaptureControllerEvent::SpeakerStopped:
        if (m_speakerSamplesProducer)
            m_speakerSamplesProducer->captureUnitHasStopped();
        return;
    case AudioCaptureControllerEvent::CanRenderAudioChanged:
        if (m_speakerSamplesProducer)
            m_speakerSamplesProducer->canRenderAudioChanged();
        return;
    case AudioCaptureControllerEvent::UnitStopped:
#if PLATFORM(IOS_FAMILY)
        setIsInBackground(false);
#endif
        return;
    case AudioCaptureControllerEvent::VoiceActivityDetected:
        if (m_voiceActivityCallback)
            m_voiceActivityCallback();
        return;
    case AudioCaptureControllerEvent::MuteStatusChanged:
        if (m_muteStatusChangedCallback)
            m_muteStatusChangedCallback(value);
        return;
    }
    ASSERT_NOT_REACHED();
}

#if !LOG_DISABLED
void CoreAudioCaptureUnit::checkTimestamps(double sampleTime, double hostTime)
{
    if (!sampleTime || sampleTime == m_latestMicTimeStamp || !hostTime)
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::checkTimestamps(%p): unusual timestamps, sample time = %f, previous sample time = %f, hostTime %f", this, sampleTime, m_latestMicTimeStamp, hostTime);
}
#endif

// What processMicrophoneSamples() did once the unit rendered the quantum into the Swift microphone callback's buffers.
void CoreAudioCaptureUnit::deliverMicrophoneSamples(const AudioBufferList& list, uint32_t frameCount, const AudioCaptureTimes& times)
{
    RefPtr microphoneSampleBuffer = m_microphoneSampleBuffer;
    microphoneSampleBuffer->reset();
    auto destinationBuffers = span(*microphoneSampleBuffer->bufferList().list());
    auto sourceBuffers = span(list);
    for (size_t index = 0; index < std::min(destinationBuffers.size(), sourceBuffers.size()); ++index) {
        auto& source = sourceBuffers[index];
        auto& destination = destinationBuffers[index];
        auto byteCount = std::min(source.mDataByteSize, destination.mDataByteSize);
        if (byteCount)
            memcpySpan(mutableSpan<uint8_t>(destination).first(byteCount), span<uint8_t>(source).first(byteCount));
        destination.mDataByteSize = byteCount;
        destination.mNumberChannels = source.mNumberChannels;
    }

#if !LOG_DISABLED
    checkTimestamps(times.sampleTime, times.adjustedHostTime);
#endif
    m_latestMicTimeStamp = times.sampleTime;
    microphoneSampleBuffer->setTimes(times.bufferTimestamp, times.bufferHostTime);

    // The Swift microphone callback applied the volume.
    MediaTime time(times.mediaTimeValue, times.mediaTimeScale);
    auto& data = microphoneSampleBuffer->bufferList();
    auto& description = *m_microphoneProcFormat;

    // We hold the lock here since adding/removing clients can only happen in main thread.
    Locker locker { m_audioThreadClientsLock };

    // For performance reasons, we forbid heap allocations while doing rendering on the capture audio thread.
    ForbidMallocUseForCurrentThreadScope forbidMallocUse;

    for (auto& weakClient : m_audioThreadClients) {
        RefPtr client = weakClient.get();
        if (!client)
            continue;
        if (client->isProducingData())
            client->audioSamplesAvailable(time, data, description, frameCount);
    }
}

void CoreAudioCaptureUnit::registerSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer& producer)
{
    ASSERT(isMainThread());

    auto* oldProducer = std::exchange(m_speakerSamplesProducer, &producer);
    if (oldProducer && oldProducer != &producer)
        oldProducer->captureUnitHasStopped();

    m_controller.setSpeakerSamplesProducer(producer.speakerTrackPlayout().identifier(), producer.format().streamDescription());
}

void CoreAudioCaptureUnit::unregisterSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer& producer)
{
    ASSERT(isMainThread());

    if (m_speakerSamplesProducer != &producer)
        return;
    m_speakerSamplesProducer = nullptr;

    m_controller.setSpeakerSamplesProducer(0, { });
}

void CoreAudioCaptureUnit::enableMutedSpeechActivityEventListener(Function<void()>&& callback)
{
    m_voiceActivityCallback = WTF::move(callback);
    m_controller.setHasVoiceActivityListener(!!m_voiceActivityCallback);
}

void CoreAudioCaptureUnit::disableMutedSpeechActivityEventListener()
{
    m_voiceActivityCallback = { };
    m_controller.setHasVoiceActivityListener(false);
}

void CoreAudioCaptureUnit::setMuteStatusChangedCallback(Function<void(bool)>&& callback)
{
    if (!m_muteStatusChangedCallback && !callback)
        return;

    ASSERT(!!m_muteStatusChangedCallback != !!callback);
    m_muteStatusChangedCallback = WTF::move(callback);
    AudioCaptureControllerHandle::setHasMuteStatusListener(!!m_muteStatusChangedCallback);
}

#if PLATFORM(IOS_FAMILY)
void CoreAudioCaptureUnit::setIsInBackground(bool isInBackground)
{
    if (!MediaCaptureStatusBarManager::hasSupport())
        return;

    if (!isInBackground) {
        if (m_statusBarManager) {
            protect(m_statusBarManager)->stop();
            m_statusBarManager = nullptr;
        }
        return;
    }

    if (m_statusBarManager)
        return;

    m_statusBarManager = MediaCaptureStatusBarManager::create([weakThis = WeakPtr { *this }](CompletionHandler<void()>&& completionHandler) {
        RefPtr protectedThis = weakThis.get();
        if (protectedThis && protectedThis->m_statusBarWasTappedCallback)
            protectedThis->m_statusBarWasTappedCallback(WTF::move(completionHandler));
    }, [weakThis = WeakPtr { *this }] {
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit status bar failed");
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        auto statusBarManager = std::exchange(protectedThis->m_statusBarManager, { });
        statusBarManager->stop();
        if (protectedThis->isRunning())
            protectedThis->m_controller.captureFailed();
    });
    protect(m_statusBarManager)->start();
}
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
