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

#if ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)

#include "CARingBuffer.h"
#include "Logging.h"
#include "WebCore-Swift.h"

#if PLATFORM(IOS_FAMILY)
#include "AudioSession.h"
#endif

namespace WebCore {

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

OSStatus AudioOutputUnit::renderForTesting(AudioBufferList& list, uint32_t frameCount, double sampleTime, bool throughAudioUnit)
{
    return audioOutputUnitRenderForTesting(m_identifier, &list, frameCount, sampleTime, throughAudioUnit);
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)
