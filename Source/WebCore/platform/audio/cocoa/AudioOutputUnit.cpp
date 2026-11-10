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

#include "config.h"
#include "AudioOutputUnit.h"

#if (ENABLE(WEB_AUDIO) || ENABLE(MEDIA_STREAM)) && USE(MEDIATOOLBOX)

#include "CARingBuffer.h"
#include "Logging.h"
#include "WebCore-Swift.h"
#include <pal/cf/CoreAudioExtras.h>
#include <wtf/HashMap.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(IOS_FAMILY)
#include "AudioSession.h"
#endif

namespace WebCore {

// The event handlers of the output units that have one, by identifier, on the main thread.
static HashMap<uint64_t, Function<void(OptionSet<AudioOutputUnit::Event>)>*>& eventHandlers()
{
    static NeverDestroyed<HashMap<uint64_t, Function<void(OptionSet<AudioOutputUnit::Event>)>*>> handlers;
    return handlers;
}

void audioUnitEventsArrived()
{
    callOnMainThread([] {
        AudioOutputUnit::dispatchEvents();
    });
}

void AudioOutputUnit::dispatchEvents()
{
    ASSERT(isMainThread());
    for (auto identifier : copyToVector(eventHandlers().keys())) {
        auto* handler = eventHandlers().get(identifier);
        if (!handler)
            continue;
        if (auto events = audioOutputUnitTakeEvents(identifier))
            (*handler)(OptionSet<Event>::fromRaw(events));
    }
#if ENABLE(MEDIA_STREAM)
    audioCaptureControllersDispatchUnitEvents();
#endif
}

void AudioOutputUnit::setEventHandler(uint64_t identifier, Function<void(OptionSet<Event>)>* handler)
{
    ASSERT(isMainThread());
    if (handler && *handler)
        eventHandlers().set(identifier, handler);
    else
        eventHandlers().remove(identifier);
}

AudioOutputUnit::AudioOutputUnit(uint64_t identifier)
    : m_identifier(identifier)
{
}

auto AudioOutputUnit::createTrackRenderer(uint32_t deviceID, double sampleRate, const std::optional<AudioStreamBasicDescription>& format, bool playsOutTrack) -> TrackRenderer
{
    auto creation = audioOutputUnitCreateTrackRenderer(deviceID, sampleRate, format.value_or(AudioStreamBasicDescription { }), !!format, playsOutTrack);
    if (!creation.identifier)
        return { nullptr, { }, creation.status, creation.failedStep };
    return { std::unique_ptr<AudioOutputUnit>(new AudioOutputUnit(creation.identifier)), creation.format, noErr, 0 };
}

void AudioOutputUnit::attachTrackPlayout(const AudioTrackPlayout& track)
{
    AudioOutputUnitRingAttachment attachment;
    attachment.trackPlayoutIdentifier = track.identifier();
    audioUnitAttachRing(m_identifier, attachment);
}

void AudioOutputUnit::setEventHandler(Function<void(OptionSet<Event>)>&& handler)
{
    m_eventHandler = WTF::move(handler);
    setEventHandler(m_identifier, &m_eventHandler);
}

AudioOutputUnit::AudioOutputUnit(Kind kind, float hardwareSampleRate, unsigned numberOfOutputChannels)
    : m_identifier(audioOutputUnitCreate(static_cast<uint8_t>(kind), hardwareSampleRate, numberOfOutputChannels))
{
#if PLATFORM(IOS_FAMILY)
    if (kind != Kind::GenericOutputForTesting) {
        constexpr size_t preferredBufferSize = 256;
        AudioSession::singleton().setPreferredBufferSize(preferredBufferSize);
    }
#endif
}

AudioOutputUnit::~AudioOutputUnit()
{
    setEventHandler(m_identifier, nullptr);
    audioOutputUnitDestroy(m_identifier);
}

OSStatus AudioOutputUnit::start()
{
    auto result = audioOutputUnitStart(m_identifier);
    if (result != noErr)
        WTFLogAlways("ERROR: AudioOutputUnitStart() call failed with error code: %ld", static_cast<long>(result));
    return result;
}

OSStatus AudioOutputUnit::stop()
{
    return audioOutputUnitStop(m_identifier);
}

size_t AudioOutputUnit::outputLatency() const
{
    return audioOutputUnitLatency(m_identifier);
}

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
void AudioOutputUnit::setSpatialAudioExperience(CASpatialAudioExperience *experience)
{
    OSStatus result = audioOutputUnitSetObjectProperty(m_identifier, kAudioOutputUnitProperty_IntendedSpatialExperience, (void *)experience);
    if (result != noErr)
        RELEASE_LOG(Media, "ERROR: Failed to set kAudioOutputUnitProperty_IntendedSpatialExperience with error: %ld", static_cast<long>(result));
}
#endif

void AudioOutputUnit::attachRing(const CARingBuffer* ring, std::span<uint8_t> frameCounter, uint32_t semaphore)
{
    AudioOutputUnitRingAttachment attachment;
    if (ring) {
        attachment.geometry = ring->geometry();
        attachment.header = &ring->boundsStorage();
        attachment.channels = ring->channelData().data();
        attachment.channelsByteCount = ring->channelData().size();
    }
    attachment.frameCounter = spanReinterpretCast<uint32_t>(frameCounter).data();
    attachment.frameCounterByteCount = frameCounter.size();
    attachment.semaphore = semaphore;
    audioUnitAttachRing(m_identifier, attachment);
}

void AudioOutputUnit::attachRenderCallback(AURenderCallback callback, void* refCon)
{
    audioOutputUnitAttachCxxRenderCallback(m_identifier, reinterpret_cast<const void*>(callback), refCon);
}

OSStatus AudioOutputUnit::renderForTesting(AudioBufferList& list, uint32_t frameCount, double sampleTime, bool throughAudioUnit, AudioUnitRenderActionFlags* actionFlags)
{
    AudioUnitRenderActionFlags flags = 0;
    auto status = audioOutputUnitRenderForTesting(m_identifier, &list, frameCount, sampleTime, throughAudioUnit, &flags);
    if (actionFlags)
        *actionFlags = flags;
    return status;
}

AudioTrackPlayout::AudioTrackPlayout()
    : m_identifier(audioTrackPlayoutCreate())
{
}

AudioTrackPlayout::~AudioTrackPlayout()
{
    audioTrackPlayoutDestroy(m_identifier);
}

void AudioTrackPlayout::attachRing(const CARingBuffer* ring, uint32_t semaphore, uint64_t frameChunkSize, uint64_t bytesPerFrame)
{
    AudioOutputUnitRingAttachment attachment;
    if (ring) {
        attachment.geometry = ring->geometry();
        attachment.header = &ring->boundsStorage();
        attachment.channels = ring->channelData().data();
        attachment.channelsByteCount = ring->channelData().size();
    }
    attachment.semaphore = semaphore;
    attachment.frameChunkSize = frameChunkSize;
    attachment.bytesPerFrame = bytesPerFrame;
    audioUnitAttachRing(m_identifier, attachment);
}

#if ENABLE(MEDIA_STREAM)
void attachAudioCaptureDeliveryContext(uint64_t controllerIdentifier, void* context)
{
    AudioOutputUnitRingAttachment attachment;
    attachment.cxxDeliveryContext = context;
    audioUnitAttachRing(controllerIdentifier, attachment);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(AudioCaptureUnitForTesting);

AudioCaptureUnitForTesting::AudioCaptureUnitForTesting(uint64_t identifier)
    : m_identifier(identifier)
{
}

std::unique_ptr<AudioCaptureUnitForTesting> AudioCaptureUnitForTesting::createSpeaker(const AudioTrackPlayout& track, const AudioStreamBasicDescription& format)
{
    auto identifier = audioCaptureUnitCreateMockSpeakerForTesting(track.identifier(), format);
    if (!identifier)
        return nullptr;
    return std::unique_ptr<AudioCaptureUnitForTesting>(new AudioCaptureUnitForTesting(identifier));
}

std::unique_ptr<AudioCaptureUnitForTesting> AudioCaptureUnitForTesting::startMicrophone(const AudioCaptureSink& first, const AudioCaptureSink& second, float gain)
{
    auto identifier = audioCaptureUnitStartMockMicrophoneForTesting(gain, first.identifier(), second.identifier());
    if (!identifier)
        return nullptr;
    return std::unique_ptr<AudioCaptureUnitForTesting>(new AudioCaptureUnitForTesting(identifier));
}

AudioCaptureUnitForTesting::~AudioCaptureUnitForTesting()
{
    audioCaptureUnitDestroyForTesting(m_identifier);
}

OSStatus AudioCaptureUnitForTesting::renderSpeaker(AudioBufferList& list, uint32_t frameCount, double sampleTime, AudioUnitRenderActionFlags* actionFlags)
{
    AudioUnitRenderActionFlags flags = 0;
    auto status = audioOutputUnitRenderForTesting(m_identifier, &list, frameCount, sampleTime, false, &flags);
    if (actionFlags)
        *actionFlags = flags;
    return status;
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(AudioCaptureSink);

AudioCaptureSink::AudioCaptureSink(Kind kind, const AudioStreamBasicDescription& format)
    : m_kind(kind)
    , m_format(format)
    , m_identifier(audioCaptureSinkCreate(kind == Kind::Producer, format))
{
}

AudioCaptureSink::~AudioCaptureSink()
{
    audioCaptureSinkDestroy(m_identifier);
}

void AudioCaptureSink::attachRing(CARingBuffer& ring, uint32_t semaphore, uint64_t frameChunkSize)
{
    ASSERT(m_kind == Kind::Producer);
    AudioOutputUnitRingAttachment attachment;
    attachment.geometry = ring.geometry();
    attachment.header = &ring.boundsStorage();
    attachment.channels = ring.channelData().data();
    attachment.channelsByteCount = ring.channelData().size();
    attachment.semaphore = semaphore;
    attachment.frameChunkSize = frameChunkSize;
    audioUnitAttachRing(m_identifier, attachment);
}

std::optional<std::pair<int64_t, uint32_t>> AudioCaptureSink::startTime() const
{
    auto status = audioCaptureSinkStatus(m_identifier);
    if (!status.hasStartTime)
        return std::nullopt;
    return std::pair { status.startTimeValue, status.startTimeScale };
}

uint64_t AudioCaptureSink::droppedQuantumCount() const
{
    return audioCaptureSinkStatus(m_identifier).droppedQuantumCount;
}

float AudioCaptureSink::takePeak()
{
    return audioCaptureSinkTakePeak(m_identifier);
}

void AudioCaptureSink::setEnabled(bool value)
{
    audioCaptureSinkSetEnabled(m_identifier, value);
}

void AudioCaptureSink::setStartedHandler(Function<void(int64_t, uint32_t)>&& handler)
{
    m_startedHandler = WTF::move(handler);
}

void AudioCaptureSink::setFormatChangedHandler(Function<void()>&& handler)
{
    m_formatChangedHandler = WTF::move(handler);
}

void AudioCaptureSink::notifyStartedIfNeeded()
{
    if (m_hasNotifiedStart || m_kind != Kind::Producer)
        return;
    auto time = startTime();
    if (!time)
        return;
    m_hasNotifiedStart = true;
    if (m_startedHandler)
        m_startedHandler(time->first, time->second);
}

void AudioCaptureSink::notifyFormatChanged()
{
    if (m_formatChangedHandler)
        m_formatChangedHandler();
}
#else
// AudioCaptureUnit.swift's microphone callback, without capture units.
void deliverToCxxObservers(void*, const AudioBufferList*, uint32_t, const AudioCaptureTimes&)
{
    RELEASE_ASSERT_NOT_REACHED();
}
#endif // ENABLE(MEDIA_STREAM)

} // namespace WebCore

#endif // (ENABLE(WEB_AUDIO) || ENABLE(MEDIA_STREAM)) && USE(MEDIATOOLBOX)
