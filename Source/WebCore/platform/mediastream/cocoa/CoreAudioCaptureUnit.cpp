/*
 * Copyright (C) 2017-2023 Apple Inc. All rights reserved.
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
#include "CARingBufferSwiftBridge.h"
#include "CoreAudioCaptureSource.h"
#include "Logging.h"
#include "MockAudioCaptureUnit.h"
#include <AudioToolbox/AudioConverter.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreMedia/CMSync.h>
#include <mach/mach_time.h>
#include <pal/avfoundation/MediaTimeAVFoundation.h>
#include <pal/cf/CoreAudioExtras.h>
#include <pal/spi/cf/CoreAudioSPI.h>
#include <sys/time.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/NativePromise.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WorkQueue.h>

#if PLATFORM(IOS_FAMILY)
#include "AVAudioSessionCaptureDeviceManager.h"
#include "MediaCaptureStatusBarManager.h"
#endif

#if PLATFORM(MAC)
#include "CoreAudioCaptureDevice.h"
#include "CoreAudioCaptureDeviceManager.h"
#endif

#include <pal/cf/AudioToolboxSoftLink.h>
#include <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

const UInt32 outputBus = 0;
const UInt32 inputBus = 1;

OSStatus CoreAudioCaptureUnit::defaultInputDevice(uint32_t& deviceID)
{
    if (m_ioUnit->isMock()) {
        deviceID = 1;
        return 0;
    }
#if PLATFORM(MAC)
    auto err = m_ioUnit->getUInt32Property(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, inputBus, deviceID);
    RELEASE_LOG_ERROR_IF(err, WebRTC, "CoreAudioCaptureInternalUnit unable to get default input device ID, error %d (%.4s)", (int)err, (char*)&err);
    return err;
#else
    UNUSED_PARAM(deviceID);
    return -1;
#endif
}

OSStatus CoreAudioCaptureUnit::defaultOutputDevice(uint32_t& deviceID)
{
    if (m_ioUnit->isMock()) {
        deviceID = 0;
        return 0;
    }
#if PLATFORM(MAC)
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectHasProperty(kAudioObjectSystemObject, &address)) {
        UInt32 propertySize = sizeof(AudioDeviceID);
        return AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &propertySize, &deviceID);
    }
#else
    UNUSED_PARAM(deviceID);
#endif
    return -1;
}

// A mock AudioUnit sets only its device, whose sample rate it takes, and its muted state; it ignores other properties.
OSStatus CoreAudioCaptureUnit::setUnitProperty(AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, uint32_t value)
{
    if (!m_ioUnit->isMock())
        return m_ioUnit->setUInt32Property(property, scope, element, value);

    if (property == kAudioOutputUnitProperty_CurrentDevice) {
        if (element == outputBus) {
            ASSERT(!value);
            return 0;
        }
        ASSERT(value);
        auto sampleRate = MockAudioCaptureUnit::defaultSampleRateForDevice(value);
        if (!sampleRate)
            return -1;
        m_ioUnit->configureMock(*sampleRate, preferredIOBufferSize());
        return 0;
    }
    if (property == kAUVoiceIOProperty_MuteOutput) {
        m_mockOutputMuted = !!(value & 0xff);
        setUnitVoiceActivityDetection(m_mockVoiceActivityDetectionEnabled);
    }
    return 0;
}

Seconds CoreAudioCaptureUnit::verifyCaptureInterval(bool isProducingSamples) const
{
    if (m_ioUnit && m_ioUnit->isMock())
        return 1_s;
    return isProducingSamples ? 20_s : 2_s;
}

void CoreAudioCaptureUnit::mockVoiceDetected()
{
    CoreAudioCaptureUnit::defaultSingleton().voiceActivityDetected();
    CoreAudioCaptureUnit::defaultSingleton().disableVoiceActivityThrottleTimerForTesting();
}

void audioCaptureVoiceActivityDetected()
{
    callOnMainThread([] {
        CoreAudioCaptureUnit::defaultSingleton().voiceActivityDetected();
    });
}

void deliverToCxxObservers(void* context, const AudioBufferList* list, uint32_t frameCount, const AudioCaptureTimes& times)
{
    static_cast<CoreAudioCaptureUnit*>(context)->deliverMicrophoneSamples(*list, frameCount, times);
}

CoreAudioCaptureUnit& CoreAudioCaptureUnit::defaultSingleton()
{
    static NeverDestroyed<Ref<CoreAudioCaptureUnit>> singleton(adoptRef(*new CoreAudioCaptureUnit(CanEnableEchoCancellation::Yes)));
    return singleton.get();
}

Ref<CoreAudioCaptureUnit> CoreAudioCaptureUnit::createNonVPIOUnit()
{
    return adoptRef(*new CoreAudioCaptureUnit(CanEnableEchoCancellation::No));
}

NODELETE static WeakHashSet<CoreAudioCaptureUnit>& allCoreAudioCaptureUnits()
{
    ASSERT(isMainThread());

    static NeverDestroyed<WeakHashSet<CoreAudioCaptureUnit>> units;
    return units;
}

bool CoreAudioCaptureUnit::isAnyUnitCapturingExceptFor(CoreAudioCaptureUnit* unitToNotTest)
{
    return std::ranges::any_of(allCoreAudioCaptureUnits(), [unitToNotTest = WeakPtr { unitToNotTest }](auto& unit) {
        return unit.isProducingMicrophoneSamples() && &unit != unitToNotTest.get();
    });
}

bool CoreAudioCaptureUnit::isAnyUnitCapturing()
{
    return isAnyUnitCapturingExceptFor(nullptr);
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

CoreAudioCaptureUnit::CoreAudioCaptureUnit(CanEnableEchoCancellation canEnableEchoCancellation)
    : BaseAudioCaptureUnit(canEnableEchoCancellation)
    , m_sampleRateCapabilities(8000, 96000)
#if PLATFORM(MAC)
    , m_storedVPIOUnitDeallocationTimer(*this, &CoreAudioCaptureUnit::deallocateStoredVPIOUnit)
#endif
{
    allCoreAudioCaptureUnits().add(*this);
    if (coreAudioCaptureNewUnitCallback())
        coreAudioCaptureNewUnitCallback()(*this);
}

CoreAudioCaptureUnit::~CoreAudioCaptureUnit()
{
    allCoreAudioCaptureUnits().remove(*this);

    updateVoiceActivityDetection();
    setMuteStatusChangedCallback({ });
}

#if PLATFORM(MAC)
void CoreAudioCaptureUnit::storedVPIOUnitWasKept()
{
    RELEASE_LOG(WebRTC, "CoreAudioCaptureUnit::setStoredVPIOUnit(%p)", this);

    static constexpr Seconds delayBeforeStoredVPIOUnitDeallocation = 3_s;
    m_hasStoredVPIOUnit = true;
    m_storedVPIOUnitDeallocationTimer.startOneShot(delayBeforeStoredVPIOUnitDeallocation);
}
#endif

void CoreAudioCaptureUnit::resetSampleRate()
{
    setSampleRate(m_getSampleRateCallback ? m_getSampleRateCallback() : AudioSession::singleton().sampleRate());
}

void CoreAudioCaptureUnit::captureDeviceChanged()
{
#if PLATFORM(MAC)
    reconfigureAudioUnit();
#else
    AVAudioSessionCaptureDeviceManager::singleton().setPreferredMicrophoneID(isCapturingWithDefaultMicrophone() ? String { } : persistentID());
#endif
    updateVoiceActivityDetection();
}

size_t CoreAudioCaptureUnit::preferredIOBufferSize()
{
    return AudioSession::singleton().bufferSize();
}

OSStatus CoreAudioCaptureUnit::setupAudioUnit()
{
    if (m_ioUnit)
        return 0;

    ASSERT(hasClients());

    mach_timebase_info_data_t timebaseInfo;
    mach_timebase_info(&timebaseInfo);
    m_DTSConversionRatio = 1e-9 * static_cast<double>(timebaseInfo.numer) / static_cast<double>(timebaseInfo.denom);

    bool isEchoCancellationChanging = m_shouldUseVPIO != enableEchoCancellation();
    m_shouldUseVPIO = enableEchoCancellation();
    using Kind = AudioCaptureUnitHandle::Kind;
    auto kind = m_usesMockUnit ? (m_shouldUseVPIO ? Kind::MockWithEchoCancellation : Kind::MockWithoutEchoCancellation) : (m_shouldUseVPIO ? Kind::VoiceProcessing : Kind::Plain);
#if PLATFORM(MAC)
    if (kind == Kind::VoiceProcessing)
        RELEASE_LOG(WebRTC, "CoreAudioCaptureUnit::takeStoredVPIOUnit(%p)", &defaultSingleton());
#endif
    auto creation = AudioCaptureUnitHandle::create(kind);
#if PLATFORM(MAC)
    if (kind == Kind::VoiceProcessing) {
        defaultSingleton().m_storedVPIOUnitDeallocationTimer.stop();
        defaultSingleton().m_hasStoredVPIOUnit = false;
    }
#endif
    if (!creation.unit) {
        if (creation.status == -1)
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureInternalUnit unable to find capture unit component");
        else
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureInternalUnit unable to open capture unit, error %d (%.4s)", (int)creation.status, (char*)&creation.status);
        return creation.status;
    }
    if (creation.reusedStoredUnit)
        RELEASE_LOG(WebRTC, "Creating a CoreAudioCaptureInternalUnit with a stored VPIO unit");
    else if (!creation.unit->isMock())
        RELEASE_LOG(WebRTC, "Successfully created a CoreAudioCaptureInternalUnit");

    m_ioUnit = WTF::move(creation.unit);
    m_ioUnit->setEventHandler([this](OptionSet<AudioOutputUnit::Event> events) {
        handleUnitEvents(events.toRaw());
    });
    m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::Reconfiguring, m_isReconfiguring);
    m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::ProducingMicrophoneSamples, isProducingMicrophoneSamples());
    attachSpeakerSamplesProducer();
    m_attachedSinkIdentifiers.clear();
    updateMicrophoneConfiguration();
    if (m_ioUnit->isMock())
        m_ioUnit->configureMock(0, preferredIOBufferSize());

    bool canRenderAudio = !m_ioUnit->isMock() && m_shouldUseVPIO;
    if (m_canRenderAudio != canRenderAudio) {
        m_canRenderAudio = canRenderAudio;
        {
            Locker locker { m_speakerSamplesProducerLock };
            if (m_speakerSamplesProducer)
                m_speakerSamplesProducer->canRenderAudioChanged();
        }
    }

    if (isEchoCancellationChanging) {
        forEachClient([](auto& client) {
            client.echoCancellationChanged();
        });
    }

#if HAVE(VPIO_DUCKING_LEVEL_API)
    if (m_shouldUseVPIO) {
        AUVoiceIOOtherAudioDuckingConfiguration configuration { true, kAUVoiceIOOtherAudioDuckingLevelMin };
        if (auto err = m_ioUnit->isMock() ? noErr : m_ioUnit->setSmallProperty(kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, inputBus, configuration)) {
            if (err != kAudioUnitErr_InvalidProperty) {
                RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) unable to set ducking level, error %d (%.4s)", this, (int)err, (char*)&err);
                return err;
            }
        }
    }
#endif // HAVE(VPIO_DUCKING_LEVEL_API)

#if PLATFORM(IOS_FAMILY)
    if (auto err = setUnitProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, 1)) {
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) unable to enable capture unit input, error %d (%.4s)", this, (int)err, (char*)&err);
        return err;
    }
#else
    if (!m_shouldUseVPIO) {
        if (auto err = setUnitProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, 1)) {
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) unable to enable capture unit input, error %d (%.4s)", this, (int)err, (char*)&err);
            return err;
        }
        if (auto err = setUnitProperty(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, 0)) {
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) unable to enable capture unit output, error %d (%.4s)", this, (int)err, (char*)&err);
            return err;
        }
    }

    auto deviceID = captureDeviceID();
    // FIXME: We probably want to make default input/output devices.
    if (!deviceID) {
        if (auto err = defaultInputDevice(deviceID))
            return err;
    }

    if (auto err = setUnitProperty(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, inputBus, deviceID)) {
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) unable to set capture unit capture device ID %d, error %d (%.4s)", this, (int)deviceID, (int)err, (char*)&err);
        return err;
    }

    if (m_shouldUseVPIO) {
        uint32_t defaultOutputDeviceID;
        auto err = defaultOutputDevice(defaultOutputDeviceID);
        if (!err) {
            err = setUnitProperty(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputBus, defaultOutputDeviceID);
            RELEASE_LOG_ERROR_IF(err, WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) unable to set capture unit output device ID %d, error %d (%.4s)", this, (int)defaultOutputDeviceID, (int)err, (char*)&err);
        }
        setOutputDeviceID(!err ? defaultOutputDeviceID : 0);
    } else {
        // With HALOutput, we cannot rely on sample rate conversions, we stick to hardware sample rate.
        static const AudioObjectPropertyAddress nominalSampleRateAddress = {
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };

        Float64 nominalSampleRate;
        UInt32 nominalSampleRateSize = sizeof(Float64);
        if (AudioObjectGetPropertyData(deviceID, &nominalSampleRateAddress, 0, 0, &nominalSampleRateSize, (void*)&nominalSampleRate) == noErr)
            setSampleRate(nominalSampleRate);
    }
#endif

    // FIXME: Add support for different speaker/microphone sample rates.
    int actualSampleRate = this->actualSampleRate();
    if (auto err = configureMicrophoneProc(actualSampleRate))
        return err;

    if (auto err = configureSpeakerProc(actualSampleRate))
        return err;

    if (auto err = m_ioUnit->initialize()) {
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::setupAudioUnit(%p) AudioUnitInitialize() failed, error %d (%.4s)", this, (int)err, (char*)&err);
        return err;
    }
    m_ioUnitInitialized = true;

    unduck();

    return 0;
}

void CoreAudioCaptureUnit::unduck()
{
    uint32_t outputDevice;
    if (m_ioUnit && !defaultOutputDevice(outputDevice))
        AudioDeviceDuck(outputDevice, 1.0, nullptr, 0);
}

int CoreAudioCaptureUnit::actualSampleRate() const
{
    Locker locker { m_speakerSamplesProducerLock };
    return m_speakerSamplesProducer ? m_speakerSamplesProducer->format().streamDescription().mSampleRate : sampleRate();
}

OSStatus CoreAudioCaptureUnit::configureMicrophoneProc(int sampleRate)
{
    ASSERT(isMainThread());

    auto result = m_ioUnit->configureMicrophone(sampleRate);
    if (!result.format) {
        auto err = result.status;
        if (result.failedStep == 1)
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::configureMicrophoneProc(%p) unable to set capture unit mic proc, error %d (%.4s)", this, (int)err, (char*)&err);
        else if (result.failedStep == 2)
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::configureMicrophoneProc(%p) unable to get output stream format, error %d (%.4s)", this, (int)err, (char*)&err);
        else
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::configureMicrophoneProc(%p) unable to set output stream format, error %d (%.4s)", this, (int)err, (char*)&err);
        return err;
    }
    auto microphoneProcFormat = *result.format;

    auto bufferSize = preferredIOBufferSize();
    if (m_minimumMicrophoneSampleFrames) {
        auto minBufferSize = *m_minimumMicrophoneSampleFrames * microphoneProcFormat.mBytesPerPacket;
        if (minBufferSize > bufferSize)
            bufferSize = minBufferSize;
        m_minimumMicrophoneSampleFrames = { };
    }
    m_microphoneSampleBuffer = AudioSampleBufferList::create(microphoneProcFormat, bufferSize * 2);
    m_microphoneProcFormat = microphoneProcFormat;
    m_ioUnit->allocateMicrophoneBuffers(microphoneProcFormat, *m_microphoneSampleBuffer->bufferList().list(), m_microphoneProcFormat->sampleRate(), m_DTSConversionRatio);

    // Sinks of another format would drop the quanta: their owners give them rings in this one, before the unit starts.
    Vector<WeakPtr<AudioCaptureSink>> sinks;
    forEachClient([&](auto& client) {
        sinks.appendVector(client.audioCaptureSinks());
    });
    for (auto& weakSink : sinks) {
        if (auto* sink = weakSink.get(); sink && !(sink->format() == microphoneProcFormat))
            sink->notifyFormatChanged();
    }

    return noErr;
}

OSStatus CoreAudioCaptureUnit::configureSpeakerProc(int sampleRate)
{
    ASSERT(isMainThread());

    std::optional<AudioStreamBasicDescription> producerFormat;
    {
        Locker locker { m_speakerSamplesProducerLock };
        if (m_speakerSamplesProducer) {
            producerFormat = m_speakerSamplesProducer->format().streamDescription();
            ASSERT(producerFormat->mSampleRate == sampleRate);
        }
    }
    auto result = m_ioUnit->configureSpeaker(sampleRate, producerFormat);
    if (!result.format) {
        auto err = result.status;
        if (result.failedStep == 1)
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::configureSpeakerProc(%p) unable to set capture unit speaker proc, error %d (%.4s)", this, (int)err, (char*)&err);
        else
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::configureSpeakerProc(%p) unable to get input stream format, error %d (%.4s)", this, (int)err, (char*)&err);
        return err;
    }

    m_speakerProcFormat = *result.format;

    return noErr;
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
    audioSamplesAvailable(MediaTime(times.mediaTimeValue, times.mediaTimeScale), microphoneSampleBuffer->bufferList(), *m_microphoneProcFormat, frameCount);
}

void CoreAudioCaptureUnit::handleUnitEvents(uint32_t rawEvents)
{
    ASSERT(isMainThread());
    using Event = AudioOutputUnit::Event;
    auto events = OptionSet<Event>::fromRaw(rawEvents);
    if (events.contains(Event::SpeakerStarting)) {
        {
            Locker locker { m_speakerSamplesProducerLock };
            if (m_speakerSamplesProducer)
                m_speakerSamplesProducer->captureUnitIsStarting();
        }
        if (m_ioUnit)
            m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::SpeakerStartAcknowledged, true);
    }
    if (events.contains(Event::FirstMicrophoneQuantum)) {
        forEachClient([](auto& client) {
            if (client.isProducingData())
                client.noteStartedProducingData();
        });
    }
    if (events.contains(Event::SinkStarted)) {
        Vector<WeakPtr<AudioCaptureSink>> sinks;
        forEachClient([&](auto& client) {
            sinks.appendVector(client.audioCaptureSinks());
        });
        for (auto& weakSink : sinks) {
            if (auto* sink = weakSink.get())
                sink->notifyStartedIfNeeded();
        }
    }
    if (events.contains(Event::MicrophoneBufferTooSmall) && m_ioUnit && !m_minimumMicrophoneSampleFrames) {
        if (auto frameCount = m_ioUnit->counters().failedRenderFrameCount) {
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::processMicrophoneSamples(%p) AudioUnitRender failed with error %d, inNumberFrames %d ", this, (int)kAudio_ParamError, (int)*frameCount);
            m_minimumMicrophoneSampleFrames = *frameCount;
            // Our buffer might be too small, the preferred buffer size or sample rate might have changed.
            callOnMainThread([weakThis = WeakPtr { *this }] {
                if (RefPtr protectedThis = weakThis.get())
                    protectedThis->reconfigure();
            });
        }
    }
}

void CoreAudioCaptureUnit::updateMicrophoneConfiguration()
{
    ASSERT(isMainThread());
    if (!m_ioUnit)
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
                m_ioUnit->attachSink(sink->identifier(), true);
        }
    });
    for (auto identifier : m_attachedSinkIdentifiers) {
        if (!sinkIdentifiers.contains(identifier))
            m_ioUnit->attachSink(identifier, false);
    }
    m_attachedSinkIdentifiers = WTF::move(sinkIdentifiers);

    m_ioUnit->setMicrophoneOptions(volume(), volume() != 1.0, deliversToCxx);
    // Delivering the first sample tells the source's observers it started producing data.
    if (needsFirstQuantum && !deliversToCxx)
        m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::FirstMicrophoneQuantumArmed, true);
}

void CoreAudioCaptureUnit::attachSpeakerSamplesProducer()
{
    if (!m_ioUnit)
        return;
    Locker locker { m_speakerSamplesProducerLock };
    m_ioUnit->attach(this, m_speakerSamplesProducer ? &m_speakerSamplesProducer->speakerTrackPlayout() : nullptr);
}

void CoreAudioCaptureUnit::cleanupAudioUnit()
{
    if (m_ioUnitInitialized) {
        ASSERT(m_ioUnit);
        if (auto err = m_ioUnit->uninitialize())
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::cleanupAudioUnit(%p) AudioUnitUninitialize failed with error %d (%.4s)", this, (int)err, (char*)&err);
        m_ioUnitInitialized = false;
    }

    updateVoiceActivityDetection();
    updateMutedState();

#if PLATFORM(MAC)
    if (m_ioUnit && m_ioUnit->destroy())
        defaultSingleton().storedVPIOUnitWasKept();
#endif
    m_ioUnit = nullptr;
    m_mockOutputMuted = false;
    m_mockVoiceActivityDetectionEnabled = false;
    if (m_mockVoiceDetectionTimer)
        m_mockVoiceDetectionTimer->stop();
    if (m_mockDelayTimer)
        m_mockDelayTimer->stop();

    m_microphoneSampleBuffer = nullptr;
}

// A mock pauses its samples for a while; a real unit doesn't.
void CoreAudioCaptureUnit::delaySamples(Seconds seconds)
{
    if (!m_ioUnit || !m_ioUnit->isMock())
        return;

    m_ioUnit->setMockPaused(true);
    if (!m_mockDelayTimer) {
        lazyInitialize(m_mockDelayTimer, makeUnique<Timer>([this] {
            if (m_ioUnit)
                m_ioUnit->setMockPaused(false);
        }));
    }
    m_mockDelayTimer->startOneShot(seconds);
}

OSStatus CoreAudioCaptureUnit::reconfigureAudioUnit()
{
    ASSERT(isMainThread());
    if (!hasAudioUnit())
        return 0;

    if (!hasClients()) {
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::reconfigureAudioUnit(%p) stopping since there are no clients", this);
        stopRunning();
        return 0;
    }

    m_isReconfiguring = true;
    m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::Reconfiguring, true);
    auto scope = makeScopeExit([this] {
        m_isReconfiguring = false;
        if (m_ioUnit)
            m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::Reconfiguring, false);
    });

    if (m_ioUnitStarted) {
        if (auto err = m_ioUnit->stop()) {
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::reconfigureAudioUnit(%p) AudioOutputUnitStop failed with error %d (%.4s)", this, (int)err, (char*)&err);
            return err;
        }
    }

    cleanupAudioUnit();
    if (auto err = setupAudioUnit())
        return err;

    if (m_ioUnitStarted) {
        if (auto err = m_ioUnit->start()) {
            RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::reconfigureAudioUnit(%p) AudioOutputUnitStart failed with error %d (%.4s)", this, (int)err, (char*)&err);
            return err;
        }
    }
    return noErr;
}

OSStatus CoreAudioCaptureUnit::startInternal()
{
    ASSERT(isMainThread());

    setIsProducingMicrophoneSamples(true);

    if (!m_ioUnit) {
        if (auto err = setupAudioUnit()) {
            cleanupAudioUnit();
            ASSERT(!m_ioUnit);
            return err;
        }
        ASSERT(m_ioUnit);
    }

    unduck();

    if (m_ioUnit->isMock())
        m_ioUnit->configureMock(0, preferredIOBufferSize());

    if (auto err = m_ioUnit->start()) {
        {
            Locker locker { m_speakerSamplesProducerLock };
            if (m_speakerSamplesProducer)
                m_speakerSamplesProducer->captureUnitHasStopped();
        }

        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::start(%p) AudioOutputUnitStart failed with error %d (%.4s)", this, (int)err, (char*)&err);
        cleanupAudioUnit();
        ASSERT(!m_ioUnit);
        return err;
    }

    m_ioUnitStarted = true;

    m_microphoneProcsCalledLastTime = 0;
    if (!m_verifyCapturingTimer)
        lazyInitialize(m_verifyCapturingTimer, makeUnique<Timer>(*this, &CoreAudioCaptureUnit::verifyIsCapturing));
    m_verifyCapturingTimer->startRepeating(verifyCaptureInterval(!m_microphoneProcsCalledLastTime || isProducingMicrophoneSamples()));

    updateVoiceActivityDetection();
    updateMutedState();

    return noErr;
}

void CoreAudioCaptureUnit::isProducingMicrophoneSamplesChanged()
{
    if (m_ioUnit)
        m_ioUnit->setSwitch(AudioCaptureUnitHandle::Switch::ProducingMicrophoneSamples, isProducingMicrophoneSamples());
    updateMutedState();
    updateVoiceActivityDetection();

    if (!isProducingData())
        return;

    if (!m_verifyCapturingTimer)
        lazyInitialize(m_verifyCapturingTimer, makeUnique<Timer>(*this, &CoreAudioCaptureUnit::verifyIsCapturing));
    m_verifyCapturingTimer->startRepeating(verifyCaptureInterval(!m_microphoneProcsCalledLastTime || isProducingMicrophoneSamples()));
}

void CoreAudioCaptureUnit::updateMutedState(SyncUpdate syncUpdate)
{
    UInt32 muteUplinkOutput = m_ioUnit && isProducingData() && !isProducingMicrophoneSamples();

    if (syncUpdate == SyncUpdate::No && muteUplinkOutput) {
        RELEASE_LOG_INFO(WebRTC, "CoreAudioCaptureUnit::updateMutedState(%p) delaying mute in case unit gets stopped or unmuted soon", this);
        // We leave some time for playback to stop or for capture to restart, but not too long if the user decided to stop capture.
        static constexpr Seconds mutedStateDelay = 500_ms;

        if (!m_updateMutedStateTimer)
            lazyInitialize(m_updateMutedStateTimer, makeUnique<Timer>(*this, &CoreAudioCaptureUnit::updateMutedStateTimerFired));
        m_updateMutedStateTimer->startOneShot(mutedStateDelay);
        return;
    }
    if (m_updateMutedStateTimer)
        m_updateMutedStateTimer->stop();

    if (m_ioUnit) {
        auto error = setUnitProperty(kAUVoiceIOProperty_MuteOutput, kAudioUnitScope_Global, outputBus, muteUplinkOutput);
        RELEASE_LOG_ERROR_IF(error, WebRTC, "CoreAudioCaptureUnit::updateMutedState(%p) unable to set kAUVoiceIOProperty_MuteOutput, error %d (%.4s)", this, (int)error, (char*)&error);
    }

    bool isAnyOtherUnitCapturing = isAnyUnitCapturingExceptFor(this);
    RELEASE_LOG_INFO(WebRTC, "CoreAudioCaptureUnit::updateMutedState muteUplinkOutput=%d isAnyOtherUnitCapturing=%d", muteUplinkOutput, isAnyOtherUnitCapturing);

    if (isAnyOtherUnitCapturing)
        return;

    setMutedState(muteUplinkOutput);
}

void CoreAudioCaptureUnit::updateMutedStateTimerFired()
{
    updateMutedState(SyncUpdate::Yes);
}

void CoreAudioCaptureUnit::validateOutputDevice(uint32_t currentOutputDeviceID)
{
#if PLATFORM(MAC)
    if (!m_shouldUseVPIO || !m_ioUnit)
        return;

    uint32_t currentDefaultOutputDeviceID = 0;
    if (defaultOutputDevice(currentDefaultOutputDeviceID))
        return;

    if (!currentDefaultOutputDeviceID || currentOutputDeviceID == currentDefaultOutputDeviceID)
        return;

    reconfigure();
#else
    UNUSED_PARAM(currentOutputDeviceID);
#endif
}

#if PLATFORM(MAC)
bool CoreAudioCaptureUnit::migrateToNewDefaultDevice(const CaptureDevice& captureDevice)
{
    auto newDefaultDevicePersistentId = captureDevice.persistentId();
    auto device = CoreAudioCaptureDeviceManager::singleton().coreAudioDeviceWithUID(newDefaultDevicePersistentId);
    if (!device)
        return false;

    // We were capturing with the default device which disappeared, let's move capture to the new default device.
    setCaptureDevice(WTF::move(newDefaultDevicePersistentId), device->deviceID(), true);
    handleNewCurrentMicrophoneDevice(WTF::move(*device));
    return true;
}

void CoreAudioCaptureUnit::prewarmAudioUnitCreation(CompletionHandler<void()>&& callback)
{
    if (RefPtr audioUnitCreationWarmupPromise = m_audioUnitCreationWarmupPromise) {
        audioUnitCreationWarmupPromise->whenSettled(RunLoop::mainSingleton(), WTF::move(callback));
        return;
    }

    if (!enableEchoCancellation()) {
        callback();
        return;
    }

    m_audioUnitCreationWarmupPromise = invokeAsync(WorkQueue::create("CoreAudioCaptureUnit AudioUnit creation"_s, WorkQueue::QOS::UserInitiated).get(), [] {
        return AudioCaptureUnitHandle::prewarmStoredUnit() ? GenericPromise::createAndResolve() : GenericPromise::createAndReject();
    })->whenSettled(RunLoop::mainSingleton(), [weakThis = WeakPtr { *this }, callback = WTF::move(callback)] (auto&& result) mutable {
        if (RefPtr protectedThis = weakThis; protectedThis && result)
            protectedThis->storedVPIOUnitWasKept();
        callback();
        return GenericNonExclusivePromise::createAndResolve();
    });
}

void CoreAudioCaptureUnit::deallocateStoredVPIOUnit()
{
    if (!m_hasStoredVPIOUnit)
        return;

    RELEASE_LOG(WebRTC, "CoreAudioCaptureUnit::deallocateStoredVPIOUnit");

    m_hasStoredVPIOUnit = false;
    AudioCaptureUnitHandle::deallocateStoredUnit();
    m_audioUnitCreationWarmupPromise = nullptr;
}
#endif

void CoreAudioCaptureUnit::verifyIsCapturing()
{
    forEachClient([](auto& client) {
        for (auto& weakSink : client.audioCaptureSinks()) {
            if (auto* sink = weakSink.get(); sink && sink->kind() == AudioCaptureSink::Kind::Producer) {
                if (auto dropped = sink->takeNewDroppedQuantumCount())
                    RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::verifyIsCapturing - a producer sink dropped %llu quanta of another format", dropped);
            }
        }
    });

    auto microphoneProcsCalled = m_ioUnit ? m_ioUnit->counters().microphoneProcCount : 0;
    if (m_microphoneProcsCalledLastTime != microphoneProcsCalled) {
        m_microphoneProcsCalledLastTime = microphoneProcsCalled;
        return;
    }

    RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::verifyIsCapturing - no audio received in %d seconds, failing", static_cast<int>(m_verifyCapturingTimer->repeatInterval().value()));
    captureFailed();
}

void CoreAudioCaptureUnit::stopInternal()
{
    ASSERT(isMainThread());

    if (m_verifyCapturingTimer)
        m_verifyCapturingTimer->stop();

    if (!m_ioUnit || !m_ioUnitStarted)
        return;

    if (auto err = m_ioUnit->stop()) {
        RELEASE_LOG_ERROR(WebRTC, "CoreAudioCaptureUnit::stop(%p) AudioOutputUnitStop failed with error %d (%.4s)", this, (int)err, (char*)&err);
        return;
    }
    {
        Locker locker { m_speakerSamplesProducerLock };
        if (m_speakerSamplesProducer)
            m_speakerSamplesProducer->captureUnitHasStopped();
    }

    m_ioUnitStarted = false;
#if PLATFORM(IOS_FAMILY)
    setIsInBackground(false);
#endif
    updateVoiceActivityDetection();
    updateMutedState();
}

void CoreAudioCaptureUnit::registerSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer& producer)
{
    ASSERT(isMainThread());

    setIsRenderingAudio(true);

    CoreAudioSpeakerSamplesProducer* oldProducer;
    {
        Locker locker { m_speakerSamplesProducerLock };
        oldProducer = m_speakerSamplesProducer;
        m_speakerSamplesProducer = &producer;
    }
    if (oldProducer && oldProducer != &producer)
        oldProducer->captureUnitHasStopped();

    attachSpeakerSamplesProducer();
    if (hasAudioUnit() && producer.format() != m_speakerProcFormat)
        reconfigure();
}

void CoreAudioCaptureUnit::unregisterSpeakerSamplesProducer(CoreAudioSpeakerSamplesProducer& producer)
{
    ASSERT(isMainThread());

    {
        Locker locker { m_speakerSamplesProducerLock };
        if (m_speakerSamplesProducer != &producer)
            return;
        m_speakerSamplesProducer = nullptr;
    }

    attachSpeakerSamplesProducer();
    setIsRenderingAudio(false);
}

bool CoreAudioCaptureUnit::shouldEnableVoiceActivityDetection() const
{
    return hasVoiceActivityListenerCallback()
#if PLATFORM(IOS_FAMILY)
        && !isProducingMicrophoneSamples()
#endif
        && m_ioUnitStarted;
}

void CoreAudioCaptureUnit::updateVoiceActivityDetection(bool shouldDisableVoiceActivityDetection)
{
    if (!m_ioUnit)
        return;

    if (m_voiceActivityDetectionEnabled) {
        if (shouldEnableVoiceActivityDetection() && !shouldDisableVoiceActivityDetection)
            return;
        if (setUnitVoiceActivityDetection(false))
            m_voiceActivityDetectionEnabled = false;
        return;
    }

    if (!shouldEnableVoiceActivityDetection())
        return;
    if (setUnitVoiceActivityDetection(true))
        m_voiceActivityDetectionEnabled = true;
}

void CoreAudioCaptureUnit::enableMutedSpeechActivityEventListener(Function<void()>&& callback)
{
    setVoiceActivityListenerCallback(WTF::move(callback));
    updateVoiceActivityDetection();
}

void CoreAudioCaptureUnit::disableMutedSpeechActivityEventListener()
{
    setVoiceActivityListenerCallback({ });
    updateVoiceActivityDetection();
}

void CoreAudioCaptureUnit::handleMuteStatusChangedNotification(bool isMuting)
{
    RELEASE_LOG_INFO(WebRTC, "CoreAudioCaptureUnit::handleMuteStatusChangedNotification isMuting=%d isAnyUnitCapturing=%d", isMuting, isAnyUnitCapturing());

    if (m_muteStatusChangedCallback && isMuting == isAnyUnitCapturing())
        m_muteStatusChangedCallback(isMuting);
}

void CoreAudioCaptureUnit::willChangeCaptureDeviceTo(const String& persistentId)
{
#if PLATFORM(MAC)
    if (m_shouldUseVPIO) {
        forEachClient([&persistentId](auto& client) {
            client.vpioUnitWillChangeCaptureDeviceTo(persistentId);
        });
    }
#else
    UNUSED_PARAM(persistentId);
#endif

    if (!m_voiceActivityDetectionEnabled)
        return;

    bool shouldDisableVoiceActivityDetection = true;
    updateVoiceActivityDetection(shouldDisableVoiceActivityDetection);
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
            protectedThis->captureFailed();
    });
    protect(m_statusBarManager)->start();
}
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
