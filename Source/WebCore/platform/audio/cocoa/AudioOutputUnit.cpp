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
#include <wtf/HashMap.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>

#if PLATFORM(IOS_FAMILY)
#include "AudioSession.h"
#endif

namespace WebCore {

// The units with an event handler, by identifier, on the main thread.
static HashMap<uint64_t, AudioOutputUnit*>& unitsWithEventHandlers()
{
    static NeverDestroyed<HashMap<uint64_t, AudioOutputUnit*>> units;
    return units;
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
    for (auto identifier : copyToVector(unitsWithEventHandlers().keys())) {
        auto* unit = unitsWithEventHandlers().get(identifier);
        if (!unit)
            continue;
        if (auto events = audioOutputUnitTakeEvents(identifier))
            unit->m_eventHandler(OptionSet<Event>::fromRaw(events));
    }
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

void AudioOutputUnit::attachTrackPlayout(AudioTrackPlayoutState& track)
{
    AudioOutputUnitRingAttachment attachment;
    attachment.track = &track;
    audioUnitAttachRing(m_identifier, attachment);
}

OSStatus AudioOutputUnit::renderTrackForSpeaker(AudioTrackPlayoutState& track, AudioBufferList& list, uint32_t frameCount, AudioUnitRenderActionFlags& flags)
{
    return audioTrackRenderForSpeaker(&track, &list, frameCount, &flags);
}

void AudioOutputUnit::setEventHandler(Function<void(OptionSet<Event>)>&& handler)
{
    ASSERT(isMainThread());
    m_eventHandler = WTF::move(handler);
    if (m_eventHandler)
        unitsWithEventHandlers().set(m_identifier, this);
    else
        unitsWithEventHandlers().remove(m_identifier);
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
    if (m_eventHandler)
        unitsWithEventHandlers().remove(m_identifier);
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

} // namespace WebCore

#endif // (ENABLE(WEB_AUDIO) || ENABLE(MEDIA_STREAM)) && USE(MEDIATOOLBOX)
