/*
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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
#include "CoreAudioCaptureDeviceManager.h"

#if ENABLE(MEDIA_STREAM) && PLATFORM(MAC)

#include "AudioCaptureControllerHandle.h"
#include "WebCore-Swift.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RetainPtr.h>

namespace WebCore {

CoreAudioCaptureDeviceManager& CoreAudioCaptureDeviceManager::singleton()
{
    static NeverDestroyed<CoreAudioCaptureDeviceManager> manager;
    return manager;
}

CoreAudioCaptureDeviceManager::~CoreAudioCaptureDeviceManager() = default;

void coreAudioCaptureDevicesDidChange()
{
    CoreAudioCaptureDeviceManager::singleton().devicesDidChange();
}

// The lists, copied again from AudioCaptureDevices.swift when its list changed.
void CoreAudioCaptureDeviceManager::updateDevicesIfNeeded(bool initialize) const
{
    ASSERT(isMainThread());
    auto generation = audioCaptureDevicesGeneration(initialize);
    if (generation == m_generation)
        return;
    m_generation = generation;

    auto copyDevices = [](bool speakers) {
        auto count = audioCaptureDeviceCount(speakers);
        return Vector<CaptureDevice>(count, [speakers](size_t index) {
            return audioCaptureDevice(speakers, static_cast<uint32_t>(index));
        });
    };
    m_captureDevices = copyDevices(false);
    m_speakerDevices = copyDevices(true);
}

const Vector<CaptureDevice>& CoreAudioCaptureDeviceManager::captureDevices()
{
    updateDevicesIfNeeded(true);
    return m_captureDevices;
}

const Vector<CaptureDevice>& CoreAudioCaptureDeviceManager::speakerDevices() const
{
    updateDevicesIfNeeded(false);
    return m_speakerDevices;
}

std::optional<CaptureDevice> CoreAudioCaptureDeviceManager::captureDeviceWithPersistentID(CaptureDevice::DeviceType type, const String& deviceID)
{
    ASSERT_UNUSED(type, type == CaptureDevice::DeviceType::Microphone);
    for (auto& device : captureDevices()) {
        if (device.persistentId() == deviceID)
            return device;
    }
    return std::nullopt;
}

std::optional<uint32_t> CoreAudioCaptureDeviceManager::coreAudioDeviceWithUID(const String& deviceID)
{
    auto lookup = audioCaptureDeviceIDWithUID(deviceID.createCFString().get());
    if (!lookup.found)
        return std::nullopt;
    return lookup.deviceID;
}

void CoreAudioCaptureDeviceManager::setFilterTapEnabledDevices(bool doFiltering)
{
    audioCaptureSetFilterTapEnabledDevices(doFiltering);
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(MAC)
