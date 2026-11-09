/*
 * Copyright (C) 2016-2025 Apple Inc. All rights reserved.
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


#import "config.h"
#import "MockAudioCaptureUnit.h"

#if ENABLE(MEDIA_STREAM)
#import "AudioOutputUnit.h"
#import "CoreAudioCaptureSource.h"
#import "MockRealtimeMediaSourceCenter.h"

namespace WebCore {

CaptureSourceOrError MockRealtimeAudioSource::create(String&& deviceID, AtomString&& name, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier)
{
    auto device = MockRealtimeMediaSourceCenter::mockDeviceWithPersistentID(deviceID);
    ASSERT(device);
    if (!device)
        return CaptureSourceOrError({ "No mock microphone device"_s , MediaAccessDenialReason::PermissionDenied });

    return CoreAudioCaptureSource::createForTesting(WTF::move(deviceID), std::get<MockMicrophoneProperties>(device->properties).deviceID, WTF::move(name), WTF::move(hashSalts), constraints, pageIdentifier, std::get<MockMicrophoneProperties>(device->properties).echoCancellation);
}

// The mock AudioUnit itself is AudioCaptureUnit.swift's MockCaptureBackend.
static void mockAudioUnit(CoreAudioCaptureUnit& unit)
{
    unit.setSampleRateRange({ 44100, 96000 });
    unit.setUsesMockUnit(true);
    unit.setInternalUnitGetSampleRateCallback([] { return 44100; });
}

static void unmockAudioUnit(CoreAudioCaptureUnit& unit)
{
    unit.setSampleRateRange({ 8000, 96000 });
    unit.setUsesMockUnit(false);
    unit.setInternalUnitGetSampleRateCallback({ });
    unit.setSampleRateRange({ 44100, 96000 });
}

void MockAudioCaptureUnit::enable()
{
    AudioCaptureUnitHandle::setMockIncreaseBufferSize(false);
    CoreAudioCaptureUnit::forEach([](auto& unit) {
        mockAudioUnit(unit);
    });
    CoreAudioCaptureUnit::forNewUnit([](auto& unit) {
        mockAudioUnit(unit);
    });
}

void MockAudioCaptureUnit::disable()
{
    CoreAudioCaptureUnit::forEach([](auto& unit) {
        unmockAudioUnit(unit);
    });
    CoreAudioCaptureUnit::forNewUnit({ });
}

void MockAudioCaptureUnit::increaseBufferSize()
{
    AudioCaptureUnitHandle::setMockIncreaseBufferSize(true);
}

std::optional<double> MockAudioCaptureUnit::defaultSampleRateForDevice(uint32_t deviceID)
{
    auto device = MockRealtimeMediaSourceCenter::mockMicrophoneFromDeviceID(deviceID);
    if (!device)
        return std::nullopt;
    return std::get<MockMicrophoneProperties>(device->properties).defaultSampleRate;
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
