/*
 * Copyright (C) 2013 Google Inc. All rights reserved.
 * Copyright (C) 2013-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
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
#include "MockRealtimeMediaSourceCenter.h"

#if ENABLE(MEDIA_STREAM)

#include "CaptureDevice.h"
#include "Logging.h"
#include "MediaConstraints.h"
#include "MockRealtimeAudioSource.h"
#include "MockRealtimeVideoSource.h"
#include "NotImplemented.h"
#include "RealtimeMediaSourceSettings.h"
#include <math.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/StringView.h>

#if PLATFORM(COCOA)
#include "CoreAudioCaptureSource.h"
#include "DisplayCaptureSourceCocoa.h"
#include "MockAudioCaptureUnit.h"
#include "MockRealtimeVideoSourceCocoa.h"
#endif

#if PLATFORM(IOS_FAMILY)
#include "CoreAudioCaptureSourceIOS.h"
#endif

#if USE(GSTREAMER)
#include "GStreamerMockDeviceProvider.h"
#include "MockDisplayCaptureSourceGStreamer.h"
#include "MockRealtimeVideoSourceGStreamer.h"
#endif

namespace WebCore {

static inline Vector<MockMediaDevice> defaultDevices()
{
    return Vector<MockMediaDevice> {
        MockMediaDevice { "239c24b0-2b15-11e3-8224-0800200c9a66"_s, "Mock audio device 1"_s, { }, true, MockMicrophoneProperties { 44100 , { }, 1 } },
        MockMediaDevice { "239c24b1-2b15-11e3-8224-0800200c9a66"_s, "Mock audio device 2"_s, { }, false, MockMicrophoneProperties { 48000, { false }, 2 } },
        MockMediaDevice { "239c24b1-3b15-11e3-8224-0800200c9a66"_s, "Mock audio device 3"_s, { }, false, MockMicrophoneProperties { 96000, { true }, 3 } },
        MockMediaDevice { "239c24b1-3b15-21e3-8224-0800200c9a66"_s, "Mock audio device 4"_s, { }, true, MockMicrophoneProperties { 44100 , { }, 4 } },

        MockMediaDevice { "239c24b0-2b15-11e3-8224-0800200c9a67"_s, "Mock speaker device 1"_s, { }, true, MockSpeakerProperties { "239c24b0-2b15-11e3-8224-0800200c9a66"_s, 44100 } },
        MockMediaDevice { "239c24b1-2b15-11e3-8224-0800200c9a67"_s, "Mock speaker device 2"_s, { }, false, MockSpeakerProperties { "239c24b1-2b15-11e3-8224-0800200c9a66"_s, 48000 } },
        MockMediaDevice { "239c24b2-2b15-11e3-8224-0800200c9a67"_s, "Mock speaker device 3"_s, { }, false, MockSpeakerProperties { String { }, 48000 } },

        MockMediaDevice { "239c24b2-2b15-11e3-8224-0800200c9a66"_s, "Mock video device 1"_s, { }, true,
            MockCameraProperties {
                30,
                VideoFacingMode::User, {
                    { { 2560, 1440 }, { { 10, 10 }, { 7.5, 7.5 }, { 5, 5 } }, 1, 1, true },
                    { { 1280, 720 }, { { 30, 30 }, { 27.5, 27.5 }, { 25, 25 }, { 22.5, 22.5 }, { 20, 20 }, { 17.5, 17.5 }, { 15, 15 }, { 12.5, 12.5 }, { 10, 10 }, { 7.5, 7.5 }, { 5, 5 } }, 1, 1, true },
                    { { 640, 480 },  { { 30, 30 }, { 27.5, 27.5 }, { 25, 25 }, { 22.5, 22.5 }, { 20, 20 }, { 17.5, 17.5 }, { 15, 15 }, { 12.5, 12.5 }, { 10, 10 }, { 7.5, 7.5 }, { 5, 5 } }, 1, 1, true },
                    { { 112, 112 },  { { 30, 30 }, { 27.5, 27.5 }, { 25, 25 }, { 22.5, 22.5 }, { 20, 20 }, { 17.5, 17.5 }, { 15, 15 }, { 12.5, 12.5 }, { 10, 10 }, { 7.5, 7.5 }, { 5, 5 } }, 1, 1, true },
                },
                Color::black,
                { }, // whiteBalanceModes
                false, // supportsTorch
                false, // background blur enabled
            } },

        MockMediaDevice { "239c24b3-2b15-11e3-8224-0800200c9a66"_s, "Mock video device 2"_s, { }, false,
            MockCameraProperties {
                15,
                VideoFacingMode::Environment, {
                    { { 3840, 2160 }, { { 2, 30 } }, 1, 4, false },
                    { { 1920, 1080 }, { { 2, 30 } }, 1, 4, true },
                    { { 1280, 720 },  { { 3, 120 } }, 1, 4, false },
                    { { 960, 540 },   { { 3, 60 } }, 1, 4, false },
                    { { 640, 480 },   { { 2, 30 } }, 1, 4, false },
                    { { 352, 288 },   { { 2, 30 } }, 1, 4, false },
                    { { 320, 240 },   { { 2, 30 } }, 1, 4, false },
                    { { 160, 120 },   { { 2, 30 } }, 1, 4, false },
                },
                Color::darkGray,
                { MeteringMode::Manual, MeteringMode::SingleShot, MeteringMode::Continuous },
                true,
                true, // background blur enabled
            } },

        MockMediaDevice { "SCREEN-1"_s, "Mock screen device 1"_s, { }, true, MockDisplayProperties { CaptureDevice::DeviceType::Screen, Color::lightGray, { 1920, 1080 } } },
        MockMediaDevice { "SCREEN-2"_s, "Mock screen device 2"_s, { }, false, MockDisplayProperties { CaptureDevice::DeviceType::Screen, Color::yellow, { 3840, 2160 } } },

        MockMediaDevice { "WINDOW-1"_s, "Mock window device 1"_s, { }, true, MockDisplayProperties { CaptureDevice::DeviceType::Window, SRGBA<uint8_t> { 255, 241, 181 }, { 640, 480 } } },
        MockMediaDevice { "WINDOW-2"_s, "Mock window device 2"_s, { }, false, MockDisplayProperties { CaptureDevice::DeviceType::Window, SRGBA<uint8_t> { 255, 208, 181 }, { 1280, 600 } } },
    };
}

class MockRealtimeVideoSourceFactory : public VideoCaptureFactory {
public:
    CaptureSourceOrError createVideoCaptureSource(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier) final
    {
        ASSERT(device.type() == CaptureDevice::DeviceType::Camera);
        if (!MockRealtimeMediaSourceCenter::captureDeviceWithPersistentID(CaptureDevice::DeviceType::Camera, device.persistentId()))
            return CaptureSourceOrError({ "Unable to find mock camera device with given persistentID"_s, MediaAccessDenialReason::PermissionDenied });

        auto mock = MockRealtimeMediaSourceCenter::mockDeviceWithPersistentID(device.persistentId());
        ASSERT(mock);
        if (mock->flags.contains(MockMediaDevice::Flag::Invalid))
            return CaptureSourceOrError({ "Invalid mock camera device"_s, MediaAccessDenialReason::PermissionDenied });

        return MockRealtimeVideoSource::create(String { device.persistentId() }, AtomString { device.label() }, WTF::move(hashSalts), constraints, pageIdentifier);
    }

private:
    CaptureDeviceManager& videoCaptureDeviceManager() final { return MockRealtimeMediaSourceCenter::singleton().videoCaptureDeviceManager(); }
};

#if PLATFORM(COCOA)
static const MockMediaDevice* mockDeviceForHandle(uint64_t);

static MockDisplayLookup mockDisplayLookup(const MockMediaDevice* device)
{
    if (!device || !device->isDisplay())
        return { };

    auto& properties = std::get<MockDisplayProperties>(device->properties);
    auto [red, green, blue, alpha] = properties.fillColor.toColorTypeLossy<SRGBA<uint8_t>>().resolved();
    auto kind = properties.type == CaptureDevice::DeviceType::Window ? MockVideoSourceKind::Window : MockVideoSourceKind::Screen;
    return { { { kind, red, green, blue, alpha }, properties.defaultSize.width(), properties.defaultSize.height() }, true };
}

MockDisplayLookup mockDisplay(uint64_t handle)
{
    return mockDisplayLookup(mockDeviceForHandle(handle));
}

static std::optional<MockDisplayDescription> mockDisplayDescription(const String& persistentID)
{
    auto lookup = mockDisplay(mockDeviceHandle(persistentID));
    ASSERT(lookup.found);
    if (!lookup.found)
        return std::nullopt;
    return lookup.display;
}

MockCameraDeviceValues mockCameraDeviceValues(uint64_t handle)
{
    MockCameraDeviceValues values;
    auto* device = mockDeviceForHandle(handle);
    if (!device || !device->isCamera())
        return values;

    auto& camera = std::get<MockCameraProperties>(device->properties);
    values.found = true;
    values.isInvalid = device->flags.contains(MockMediaDevice::Flag::Invalid);
    values.defaultFrameRate = camera.defaultFrameRate;
    values.presetCount = camera.presets.size();
    values.facingMode = static_cast<uint8_t>(camera.facingMode);
    for (auto mode : camera.whiteBalanceMode)
        values.whiteBalanceModes |= 1 << static_cast<uint8_t>(mode);
    auto [red, green, blue, alpha] = camera.fillColor.toColorTypeLossy<SRGBA<uint8_t>>().resolved();
    values.description = { MockVideoSourceKind::Camera, red, green, blue, alpha };
    values.hasTorch = camera.hasTorch;
    values.hasBackgroundBlur = camera.hasBackgroundBlur;
    return values;
}

static const VideoPresetData* mockCameraPresetData(uint64_t handle, uint32_t presetIndex)
{
    auto* device = mockDeviceForHandle(handle);
    if (!device || !device->isCamera())
        return nullptr;
    auto& presets = std::get<MockCameraProperties>(device->properties).presets;
    if (presetIndex >= presets.size())
        return nullptr;
    return &presets[presetIndex];
}

MockCameraPresetValues mockCameraPreset(uint64_t handle, uint32_t presetIndex)
{
    auto* preset = mockCameraPresetData(handle, presetIndex);
    if (!preset)
        return { };
    return { preset->minZoom, preset->maxZoom, preset->size.width(), preset->size.height(), static_cast<uint32_t>(preset->frameRateRanges.size()), preset->isEfficient };
}

MockCameraFrameRateRange mockCameraPresetFrameRateRange(uint64_t handle, uint32_t presetIndex, uint32_t rangeIndex)
{
    auto* preset = mockCameraPresetData(handle, presetIndex);
    if (!preset || rangeIndex >= preset->frameRateRanges.size())
        return { };
    return { preset->frameRateRanges[rangeIndex].minimum, preset->frameRateRanges[rangeIndex].maximum };
}
#endif // PLATFORM(COCOA)

class MockRealtimeDisplaySourceFactory : public DisplayCaptureFactory {
public:
    NODELETE static MockRealtimeDisplaySourceFactory& singleton();

    CaptureSourceOrError createDisplayCaptureSource(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier) final
    {
        if (!MockRealtimeMediaSourceCenter::captureDeviceWithPersistentID(device.type(), device.persistentId()))
            return CaptureSourceOrError({ "Unable to find mock display device with given persistentID"_s, MediaAccessDenialReason::PermissionDenied });

        switch (device.type()) {
        case CaptureDevice::DeviceType::Screen:
        case CaptureDevice::DeviceType::Window: {
#if PLATFORM(COCOA)
            auto display = mockDisplayDescription(device.persistentId());
            if (!display)
                return { };
            return DisplayCaptureSourceCocoa::createMock(*display, device, WTF::move(hashSalts), constraints, pageIdentifier);
#elif USE(GSTREAMER)
            return MockDisplayCaptureSourceGStreamer::create(device, WTF::move(hashSalts), constraints, pageIdentifier);
#else
            return MockRealtimeVideoSource::create(String { device.persistentId() }, AtomString { device.label() }, WTF::move(hashSalts), constraints, pageIdentifier);
#endif
            break;
        }
        case CaptureDevice::DeviceType::Microphone:
        case CaptureDevice::DeviceType::Speaker:
        case CaptureDevice::DeviceType::Camera:
        case CaptureDevice::DeviceType::Canvas:
        case CaptureDevice::DeviceType::SystemAudio:
        case CaptureDevice::DeviceType::Unknown:
            ASSERT_NOT_REACHED();
            break;
        }

        return { };
    }

private:
    DisplayCaptureManager& displayCaptureDeviceManager() final { return MockRealtimeMediaSourceCenter::singleton().displayCaptureDeviceManager(); }
};

class MockRealtimeAudioSourceFactory final
#if PLATFORM(COCOA)
    : public CoreAudioCaptureSourceFactory
#else
    : public AudioCaptureFactory, public RefCounted<MockRealtimeAudioSourceFactory>
#endif

{
public:
    static Ref<MockRealtimeAudioSourceFactory> create()
    {
        return adoptRef(*new MockRealtimeAudioSourceFactory);
    }

    CaptureSourceOrError createAudioCaptureSource(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints, std::optional<PageIdentifier> pageIdentifier) final
    {
        ASSERT(device.type() == CaptureDevice::DeviceType::Microphone);
        if (!MockRealtimeMediaSourceCenter::captureDeviceWithPersistentID(device.type(), device.persistentId()))
            return CaptureSourceOrError({ "Unable to find mock microphone device with given persistentID"_s, MediaAccessDenialReason::PermissionDenied });

        auto mock = MockRealtimeMediaSourceCenter::mockDeviceWithPersistentID(device.persistentId());
        ASSERT(mock);
        if (mock->flags.contains(MockMediaDevice::Flag::Invalid))
            return CaptureSourceOrError({ "Invalid mock microphone device"_s, MediaAccessDenialReason::PermissionDenied });

        return MockRealtimeAudioSource::create(String { device.persistentId() }, AtomString { device.label() }, WTF::move(hashSalts), constraints, pageIdentifier);
    }
private:
    MockRealtimeAudioSourceFactory() = default;

    CaptureDeviceManager& audioCaptureDeviceManager() final { return MockRealtimeMediaSourceCenter::singleton().audioCaptureDeviceManager(); }
    const Vector<CaptureDevice>& speakerDevices() const final { return MockRealtimeMediaSourceCenter::speakerDevices(); }
};

static Vector<MockMediaDevice>& devices()
{
    static NeverDestroyed devices = defaultDevices();
    return devices;
}

// Changes whenever the devices do, so that a handle from mockDeviceHandle() finds nothing once they have changed.
static uint32_t& devicesGeneration()
{
    static uint32_t generation { 1 };
    return generation;
}

static void devicesDidChange()
{
    ++devicesGeneration();
    if (!devicesGeneration())
        devicesGeneration() = 1;
}

#if PLATFORM(COCOA)
uint64_t mockDeviceHandle(const String& persistentID)
{
    ASSERT(isMainThread());
    auto& list = devices();
    for (size_t index = 0; index < list.size(); ++index) {
        if (list[index].persistentId == persistentID)
            return (static_cast<uint64_t>(devicesGeneration()) << 32) | static_cast<uint32_t>(index + 1);
    }
    return 0;
}

static const MockMediaDevice* mockDeviceForHandle(uint64_t handle)
{
    ASSERT(isMainThread());
    if (static_cast<uint32_t>(handle >> 32) != devicesGeneration())
        return nullptr;
    auto index = static_cast<uint32_t>(handle);
    auto& list = devices();
    if (!index || index > list.size())
        return nullptr;
    return &list[index - 1];
}
#endif

static HashMap<String, MockMediaDevice>& deviceMap()
{
    static NeverDestroyed map = [] {
        HashMap<String, MockMediaDevice> map;
        for (auto& device : devices())
            map.add(device.persistentId, device);
        return map;
    }();
    return map;
}

static inline Vector<CaptureDevice>& deviceListForDevice(const MockMediaDevice& device)
{
    if (device.isMicrophone())
        return MockRealtimeMediaSourceCenter::microphoneDevices();
    if (device.isSpeaker())
        return MockRealtimeMediaSourceCenter::speakerDevices();
    if (device.isCamera())
        return MockRealtimeMediaSourceCenter::videoDevices();

    ASSERT(device.isDisplay());
    return MockRealtimeMediaSourceCenter::displayDevices();
}

MockRealtimeMediaSourceCenter& MockRealtimeMediaSourceCenter::singleton()
{
    static NeverDestroyed<MockRealtimeMediaSourceCenter> center;
    return center;
}

void MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled(bool enabled)
{
    MockRealtimeMediaSourceCenter& mock = singleton();

    if (mock.m_isEnabled == enabled)
        return;

    mock.m_isEnabled = enabled;
    RealtimeMediaSourceCenter& center = RealtimeMediaSourceCenter::singleton();

    if (mock.m_isEnabled) {
        if (mock.m_isMockAudioCaptureEnabled) {
#if PLATFORM(COCOA)
            MockAudioCaptureUnit::enable();
#endif
            center.setAudioCaptureFactory(mock.audioCaptureFactory());
        }
        if (mock.m_isMockVideoCaptureEnabled)
            center.setVideoCaptureFactory(mock.videoCaptureFactory());
        if (mock.m_isMockDisplayCaptureEnabled)
            center.setDisplayCaptureFactory(mock.displayCaptureFactory());
        return;
    }

    if (mock.m_isMockAudioCaptureEnabled) {
#if PLATFORM(COCOA)
        MockAudioCaptureUnit::disable();
#endif
        center.unsetAudioCaptureFactory(mock.audioCaptureFactory());
    }
    if (mock.m_isMockVideoCaptureEnabled)
        center.unsetVideoCaptureFactory(mock.videoCaptureFactory());
    if (mock.m_isMockDisplayCaptureEnabled)
        center.unsetDisplayCaptureFactory(mock.displayCaptureFactory());
}

bool MockRealtimeMediaSourceCenter::mockRealtimeMediaSourceCenterEnabled()
{
    return singleton().m_isEnabled;
}

static CaptureDevice toCaptureDevice(const MockMediaDevice& device)
{
    auto captureDevice = device.captureDevice();
    captureDevice.setEnabled(true);
    captureDevice.setIsMockDevice(true);

    return captureDevice;
}

static void createMockDevice(const MockMediaDevice& device, bool isDefault)
{
    if (isDefault)
        deviceListForDevice(device).insert(0, toCaptureDevice(device));
    else
        deviceListForDevice(device).append(toCaptureDevice(device));
}

void MockRealtimeMediaSourceCenter::resetDevices()
{
    setDevices(defaultDevices());
    RealtimeMediaSourceCenter::singleton().captureDevicesChanged();
}

void MockRealtimeMediaSourceCenter::setMockCaptureDevicesInterrupted(bool isCameraInterrupted, bool isMicrophoneInterrupted)
{
    MockRealtimeVideoSource::setIsInterrupted(isCameraInterrupted);
#if PLATFORM(COCOA)
    MockVideoSourceHandle::setSwiftCamerasInterrupted(isCameraInterrupted);
#endif
    MockRealtimeAudioSource::setIsInterrupted(isMicrophoneInterrupted);
}

void MockRealtimeMediaSourceCenter::triggerMockCaptureConfigurationChange(bool forCamera, bool forMicrophone, bool forDisplay)
{
    if (forCamera) {
        MockRealtimeVideoSource::triggerCameraConfigurationChange();
#if PLATFORM(COCOA)
        MockVideoSourceHandle::triggerSwiftCameraConfigurationChange();
#endif
    }

#if PLATFORM(COCOA)
    if (forMicrophone) {
        auto devices = audioCaptureDeviceManager().captureDevices();
        if (devices.size() > 1) {
            MockAudioCaptureUnit::increaseBufferSize();
            CoreAudioCaptureUnit::forEach([&devices](auto& unit) {
                unit.handleNewCurrentMicrophoneDevice(devices[1]);
            });
        }
    }
    if (forDisplay) {
        auto screen = mockDisplayDescription("SCREEN-2"_s);
        auto window = mockDisplayDescription("WINDOW-2"_s);
        if (screen && window)
            DisplayCaptureSourceHandle::triggerMockConfigurationChange(*screen, *window);
    }
#elif USE(GSTREAMER)
    if (forMicrophone) {
        auto devices = audioCaptureDeviceManager().captureDevices();
        if (devices.size() > 1)
            webkitGstMockDeviceProviderSwitchDefaultDevice(devices[0], devices[1]);
    }
    UNUSED_PARAM(forDisplay);
#else
    UNUSED_PARAM(forMicrophone);
    UNUSED_PARAM(forDisplay);
#endif
}

void MockRealtimeMediaSourceCenter::setDevices(Vector<MockMediaDevice>&& newMockDevices)
{
    microphoneDevices().clear();
    speakerDevices().clear();
    videoDevices().clear();
    displayDevices().clear();

    auto& mockDevices = devices();
    for (auto& device : mockDevices) {
        auto& persistentId = device.persistentId;
        if (!newMockDevices.containsIf([&persistentId](auto& newDevice) -> bool {
            return newDevice.persistentId == persistentId;
        }))
            RealtimeMediaSourceCenter::singleton().captureDeviceWillBeRemoved(persistentId);
    }
    mockDevices = WTF::move(newMockDevices);
    devicesDidChange();

    auto& map = deviceMap();
    map.clear();

    for (const auto& device : mockDevices) {
        map.add(device.persistentId, device);
        createMockDevice(device, false);
    }
    RealtimeMediaSourceCenter::singleton().captureDevicesChanged();
}

static bool shouldBeDefaultDevice(const MockMediaDevice& device)
{
    auto* cameraProperties = device.cameraProperties();
    return cameraProperties && cameraProperties->facingMode == VideoFacingMode::Unknown;
}

void MockRealtimeMediaSourceCenter::addDevice(const MockMediaDevice& newDevice)
{
    auto device = newDevice;

    if (device.isMicrophone())
        std::get<MockMicrophoneProperties>(device.properties).deviceID = microphoneDevices().size() + 1;

    bool isDefault = device.isDefault || shouldBeDefaultDevice(device);

    if (isDefault)
        devices().insert(0, device);
    else
        devices().append(device);
    devicesDidChange();
    deviceMap().set(device.persistentId, device);
    createMockDevice(device, isDefault);
    RealtimeMediaSourceCenter::singleton().captureDevicesChanged();
}

void MockRealtimeMediaSourceCenter::removeDevice(const String& persistentId)
{
    auto& map = deviceMap();
    auto iterator = map.find(persistentId);
    if (iterator == map.end())
        return;

    RealtimeMediaSourceCenter::singleton().captureDeviceWillBeRemoved(persistentId);
    devices().removeFirstMatching([&persistentId](const auto& device) {
        return device.persistentId == persistentId;
    });
    devicesDidChange();

    deviceListForDevice(iterator->value).removeFirstMatching([&persistentId](const auto& device) {
        return device.persistentId() == persistentId;
    });

    map.remove(iterator);
    RealtimeMediaSourceCenter::singleton().captureDevicesChanged();
}

void MockRealtimeMediaSourceCenter::setDeviceIsEphemeral(const String& persistentId, bool isEphemeral)
{
    ASSERT(!persistentId.isEmpty());

    auto& map = deviceMap();
    auto iterator = map.find(persistentId);
    if (iterator == map.end())
        return;

    MockMediaDevice device = iterator->value;
    if (isEphemeral)
        device.flags.add(MockMediaDevice::Flag::Ephemeral);
    else
        device.flags.remove(MockMediaDevice::Flag::Ephemeral);

    removeDevice(persistentId);
    addDevice(device);
}

std::optional<MockMediaDevice> MockRealtimeMediaSourceCenter::mockDeviceWithPersistentID(const String& id)
{
    ASSERT(!id.isEmpty());

    auto& map = deviceMap();
    auto iterator = map.find(id);
    if (iterator == map.end())
        return std::nullopt;

    return iterator->value;
}

std::optional<MockMediaDevice> MockRealtimeMediaSourceCenter::mockMicrophoneFromDeviceID(uint32_t deviceID)
{
    for (auto& device : deviceMap().values()) {
        if (device.isMicrophone() && std::get<MockMicrophoneProperties>(device.properties).deviceID == deviceID)
            return device;
    }
    return { };
}

std::optional<CaptureDevice> MockRealtimeMediaSourceCenter::captureDeviceWithPersistentID(CaptureDevice::DeviceType type, const String& id)
{
    ASSERT(!id.isEmpty());

    auto& map = deviceMap();
    auto iterator = map.find(id);
    if (iterator == map.end() || iterator->value.type() != type)
        return std::nullopt;

    return toCaptureDevice(iterator->value);
}

Vector<CaptureDevice>& MockRealtimeMediaSourceCenter::microphoneDevices()
{
    static NeverDestroyed microphoneDevices = [] {
        Vector<CaptureDevice> microphoneDevices;
        for (const auto& device : devices()) {
            if (device.isMicrophone())
                microphoneDevices.append(toCaptureDevice(device));
        }
        return microphoneDevices;
    }();
    return microphoneDevices;
}

Vector<CaptureDevice>& MockRealtimeMediaSourceCenter::speakerDevices()
{
    static NeverDestroyed speakerDevices = [] {
        Vector<CaptureDevice> speakerDevices;
        for (const auto& device : devices()) {
            if (device.isSpeaker())
                speakerDevices.append(toCaptureDevice(device));
        }
        return speakerDevices;
    }();
    return speakerDevices;
}

Vector<CaptureDevice>& MockRealtimeMediaSourceCenter::videoDevices()
{
    static NeverDestroyed videoDevices = [] {
        Vector<CaptureDevice> videoDevices;
        for (const auto& device : devices()) {
            if (device.isCamera())
                videoDevices.append(toCaptureDevice(device));
        }
        return videoDevices;
    }();
    return videoDevices;
}

Vector<CaptureDevice>& MockRealtimeMediaSourceCenter::displayDevices()
{
    static NeverDestroyed displayDevices = [] {
        Vector<CaptureDevice> displayDevices;
        for (const auto& device : devices()) {
            if (device.isDisplay())
                displayDevices.append(toCaptureDevice(device));
        }
        return displayDevices;
    }();
    return displayDevices;
}

AudioCaptureFactory& MockRealtimeMediaSourceCenter::audioCaptureFactory()
{
    static NeverDestroyed<Ref<MockRealtimeAudioSourceFactory>> factory = MockRealtimeAudioSourceFactory::create();
    return factory.get();
}

VideoCaptureFactory& MockRealtimeMediaSourceCenter::videoCaptureFactory()
{
    static NeverDestroyed<MockRealtimeVideoSourceFactory> factory;
    return factory.get();
}

DisplayCaptureFactory& MockRealtimeMediaSourceCenter::displayCaptureFactory()
{
    return MockRealtimeDisplaySourceFactory::singleton();
}

MockRealtimeDisplaySourceFactory& MockRealtimeDisplaySourceFactory::singleton()
{
    static NeverDestroyed<MockRealtimeDisplaySourceFactory> factory;
    return factory.get();
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
