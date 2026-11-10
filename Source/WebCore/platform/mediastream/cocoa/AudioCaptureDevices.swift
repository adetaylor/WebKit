// Copyright (C) 2017-2023 Apple Inc. All rights reserved.
// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM && os(macOS)

import CoreAudio
import CoreFoundation
import Dispatch
import Foundation
import WebCore_Private.Core.AudioCaptureControllerHandle
import WebCore_Private.Core.CaptureDevice
import os
import pal.spi.cf.CoreAudioSPI

// The microphones and speakers of the HAL (CoreAudioCaptureDevice and CoreAudioCaptureDeviceManager): their list, which the
// HAL's listeners refresh, and which CoreAudioCaptureDeviceManager reads by index. CoreAudio is linked, so it's called
// directly. Strings stay CFStrings, compared code unit by code unit as WTF::String compares them. Main thread only.

private let logger = Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

private struct AudioCaptureDeviceRecord {
    let deviceID: AudioObjectID
    let isMicrophone: Bool
    let persistentID: CFString
    let label: CFString
    var groupID: CFString
    var isEnabled = false
    var isDefault = false

    // CaptureDevice::label().
    var effectiveLabel: CFString {
        cfStringContains(label, "AirPods" as CFString) ? "AirPods" as CFString : label
    }

    // CaptureDevice::groupId().
    var effectiveGroupID: CFString {
        CFStringGetLength(groupID) == 0 ? persistentID : groupID
    }
}

private func cfStringContains(_ string: CFString, _ substring: CFString) -> Bool {
    CFStringFind(string, substring, []).location != kCFNotFound
}

private func cfStringEqual(_ a: CFString, _ b: CFString) -> Bool {
    CFStringCompare(a, b, []) == .compareEqualTo
}

private func fourCharacters(_ status: OSStatus) -> Swift.String {
    var characters = ""
    for shift: UInt32 in [0, 8, 16, 24] {
        let byte = UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> shift)
        if byte == 0 {
            break
        }
        characters.unicodeScalars.append(Unicode.Scalar(byte))
    }
    return characters
}

private func propertyAddress(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

// A CFString property, which the HAL returns retained.
private func stringProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> (OSStatus, CFString?) {
    var address = address
    var value: Unmanaged<CFString>?
    var size = unsafe UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = unsafe AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return (status, unsafe value?.takeRetainedValue())
}

private func uint32Property(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> (OSStatus, UInt32) {
    var address = address
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = unsafe AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    return (status, value)
}

// getDeviceInfo(): the device's unique ID, and its data source's name or else its name.
private func deviceInfo(_ deviceID: AudioObjectID, isMicrophone: Bool) -> (persistentID: CFString, label: CFString)? {
    let (uniqueIDStatus, uniqueID) = stringProperty(deviceID, propertyAddress(kAudioDevicePropertyDeviceUID, kAudioDevicePropertyScopeInput))
    if uniqueIDStatus != noErr {
        logger.error(
            "CoreAudioCaptureDevice::getDeviceInfo failed to get device unique id with error \(uniqueIDStatus) (\(fourCharacters(uniqueIDStatus), privacy: .public))"
        )
        return nil
    }
    guard let uniqueID else {
        return nil
    }

    let scope = isMicrophone ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    var localizedName: CFString?
    var (status, _) = uint32Property(deviceID, propertyAddress(kAudioDevicePropertyDataSource, scope))
    if status == noErr {
        // As the C++ did, the translation's input is the device's ID.
        var inputDeviceID = deviceID
        var name: Unmanaged<CFString>?
        var address = propertyAddress(kAudioDevicePropertyDataSourceNameForIDCFString, scope)
        status = withUnsafeMutablePointer(to: &inputDeviceID) { input in
            withUnsafeMutablePointer(to: &name) { output in
                var translation = unsafe AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(input),
                    mInputDataSize: UInt32(MemoryLayout<AudioObjectID>.size),
                    mOutputData: UnsafeMutableRawPointer(output),
                    mOutputDataSize: unsafe UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = unsafe UInt32(MemoryLayout<AudioValueTranslation>.size)
                return unsafe AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &translation)
            }
        }
        localizedName = unsafe name?.takeRetainedValue()
    }

    if status != noErr || localizedName.map({ CFStringGetLength($0) == 0 }) ?? true {
        (status, localizedName) = stringProperty(deviceID, propertyAddress(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal))
    }

    if status != noErr {
        logger.error("CoreAudioCaptureDevice::getDeviceInfo failed to get device name with error \(status) (\(fourCharacters(status), privacy: .public))")
        return nil
    }
    return (uniqueID, localizedName ?? ("" as CFString))
}

// CoreAudioCaptureDevice::create(): a device whose group is its own unless one is given, enabled while it's alive.
private func makeDevice(_ deviceID: AudioObjectID, isMicrophone: Bool, groupID: CFString?) -> AudioCaptureDeviceRecord? {
    guard let info = deviceInfo(deviceID, isMicrophone: isMicrophone) else {
        return nil
    }
    var device = AudioCaptureDeviceRecord(
        deviceID: deviceID,
        isMicrophone: isMicrophone,
        persistentID: info.persistentID,
        label: info.label,
        groupID: groupID ?? info.persistentID
    )

    let (aliveStatus, isAlive) = uint32Property(deviceID, propertyAddress(kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal))
    if aliveStatus != noErr {
        logger.error(
            "CoreAudioCaptureDevice::CoreAudioCaptureDevice(\(deviceID)) failed to get \"is alive\" with error \(aliveStatus) (\(fourCharacters(aliveStatus), privacy: .public))"
        )
    }
    device.isEnabled = aliveStatus == noErr && isAlive != 0

    let defaultSelector = isMicrophone ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    let (defaultStatus, defaultID) = uint32Property(
        AudioObjectID(kAudioObjectSystemObject),
        propertyAddress(defaultSelector, kAudioObjectPropertyScopeGlobal)
    )
    if defaultStatus != noErr {
        logger.error(
            "CoreAudioCaptureDevice::CoreAudioCaptureDevice(\(deviceID)) failed to get \"is default\" with error \(defaultStatus) (\(fourCharacters(defaultStatus), privacy: .public))"
        )
    }
    device.isDefault = defaultStatus == noErr && defaultID == deviceID
    return device
}

private func relatedAudioDeviceIDs(_ deviceID: AudioObjectID) -> [AudioObjectID] {
    var address = propertyAddress(kAudioDevicePropertyRelatedDevices, kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    var error = unsafe AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    if error != noErr || size == 0 {
        return []
    }
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    error = devices.withUnsafeMutableBytes { bytes in
        guard let data = bytes.baseAddress else {
            return kAudio_ParamError
        }
        return unsafe AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, data)
    }
    if error != noErr {
        return []
    }
    return devices
}

private func deviceHasStreams(_ deviceID: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    var error = unsafe AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    if error != noErr || size == 0 {
        return false
    }
    let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer {
        unsafe bufferList.deallocate()
    }
    unsafe bufferList.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
    error = unsafe AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList)
    return error == noErr && (unsafe bufferList.load(as: UInt32.self)) != 0
}

private func isVirtualDeviceFromLabel(_ label: CFString) -> Bool {
    cfStringContains(label, "WebexMediaAudioDevice" as CFString) || cfStringContains(label, "Microsoft Teams Audio" as CFString)
}

private func isValidMicrophoneDevice(_ device: AudioCaptureDeviceRecord, filterTapEnabledDevices: Bool) -> Bool {
    if filterTapEnabledDevices {
        // Ignore output devices that have input only for echo cancellation.
#if HAVE_AUDIO_DEVICE_PROPERTY_REFERENCE_STREAM_ENABLED
        var address = propertyAddress(kAudioDevicePropertyReferenceStreamEnabled, kAudioDevicePropertyScopeOutput)
#else
        var address = propertyAddress(kAudioDevicePropertyTapEnabled, kAudioDevicePropertyScopeOutput)
#endif
        if unsafe AudioObjectHasProperty(device.deviceID, &address) {
            logger.log("Ignoring output device that have input only for echo cancellation")
            return false
        }
    }

    // Ignore non-aggregable devices.
    let (_, creator) = stringProperty(device.deviceID, propertyAddress(kAudioObjectPropertyCreator, kAudioObjectPropertyScopeGlobal))
    let isNonAggregable = creator.map { !CFStringHasPrefix($0, "com.apple.audio.CoreAudio" as CFString) } ?? true
    if isNonAggregable {
        logger.log("Ignoring output device that is non aggregable")
        return false
    }

    // Ignore unnamed devices and aggregate devices created by VPIO.
    let label = device.effectiveLabel
    if CFStringGetLength(label) == 0 {
        logger.log("Ignoring output device that is unnamed")
        return false
    }

    if CFStringHasPrefix(label, "VPAUAggregateAudioDevice" as CFString) {
        logger.log("Ignoring output VPAUAggregateAudioDevice device")
        return false
    }

    // FIXME: We might want to use properties like whether a device can be selected as default once we move device enumeration to GPUProcess.
    if isVirtualDeviceFromLabel(label) {
        logger.log("Ignoring virtual microphone device '\(label as Swift.String)'")
        return false
    }

    return true
}

private func isValidSpeakerDevice(_ device: AudioCaptureDeviceRecord) -> Bool {
    if isVirtualDeviceFromLabel(device.effectiveLabel) {
        logger.log("Ignoring virtual speaker device")
        return false
    }
    return true
}

private func hasDevice(_ devices: [AudioCaptureDeviceRecord], _ deviceID: AudioObjectID, isMicrophone: Bool) -> Bool {
    devices.contains { $0.deviceID == deviceID && $0.isMicrophone == isMicrophone }
}

private func computeAudioDeviceList(filterTapEnabledDevices: Bool) -> [AudioCaptureDeviceRecord] {
    var address = propertyAddress(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
    var size: UInt32 = 0
    var error = unsafe AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    if error != noErr {
        logger.log("computeAudioDeviceList failed to get size of device list \(error) (\(fourCharacters(error), privacy: .public))")
        return []
    }
    var deviceIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    error = deviceIDs.withUnsafeMutableBytes { bytes in
        guard let data = bytes.baseAddress else {
            return noErr
        }
        return unsafe AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, data)
    }
    if error != noErr {
        logger.log("computeAudioDeviceList failed to get device list \(error) (\(fourCharacters(error), privacy: .public))")
        return []
    }

    var audioDevices: [AudioCaptureDeviceRecord] = []

    // Microphones
    for deviceID in deviceIDs {
        if !deviceHasStreams(deviceID, kAudioDevicePropertyScopeInput) || hasDevice(audioDevices, deviceID, isMicrophone: true) {
            continue
        }
        if let device = makeDevice(deviceID, isMicrophone: true, groupID: nil),
            isValidMicrophoneDevice(device, filterTapEnabledDevices: filterTapEnabledDevices)
        {
            audioDevices.append(device)
        }
    }

    // Speakers
    for deviceID in deviceIDs {
        if !deviceHasStreams(deviceID, kAudioDevicePropertyScopeOutput) || hasDevice(audioDevices, deviceID, isMicrophone: false) {
            continue
        }

        var groupID: CFString?
        for relatedDeviceID in relatedAudioDeviceIDs(deviceID) {
            for device in audioDevices where device.deviceID == relatedDeviceID && device.isMicrophone {
                groupID = device.persistentID
                break
            }
        }

        guard var device = makeDevice(deviceID, isMicrophone: false, groupID: groupID) else {
            continue
        }
        // If there is no groupID, relate devices if the label is matching.
        if groupID == nil {
            for existingDevice in audioDevices where existingDevice.isMicrophone && cfStringEqual(existingDevice.effectiveLabel, device.effectiveLabel) {
                device.groupID = existingDevice.persistentID
                break
            }
        }
        if isValidSpeakerDevice(device) {
            audioDevices.append(device)
        }
    }
    return audioDevices
}

private func haveDeviceChanges(_ oldDevices: [AudioCaptureDeviceRecord], _ newDevices: [AudioCaptureDeviceRecord]) -> Bool {
    if oldDevices.count != newDevices.count {
        return true
    }
    for (oldDevice, newDevice) in zip(oldDevices, newDevices) {
        if newDevice.isMicrophone != oldDevice.isMicrophone || newDevice.deviceID != oldDevice.deviceID || newDevice.isDefault != oldDevice.isDefault
            || newDevice.isEnabled != oldDevice.isEnabled || !cfStringEqual(newDevice.effectiveLabel, oldDevice.effectiveLabel)
            || !cfStringEqual(newDevice.effectiveGroupID, oldDevice.effectiveGroupID)
        {
            return true
        }
    }
    return false
}

// The list, used on the main thread only: each method checks it is on the main thread, and the HAL calls the listeners on
// the main queue.
private final class AudioCaptureDevices: @unchecked Sendable {
    private var isInitialized = false
    private var devices: [AudioCaptureDeviceRecord] = []
    private var microphones: [AudioCaptureDeviceRecord] = []
    private var speakers: [AudioCaptureDeviceRecord] = []
    private var generation: UInt64 = 0
    private var wasRefreshScheduled = false
    private var filterTapEnabledDevices = false

    func initializeIfNeeded() {
        precondition(WTF.isMainThread())
        if isInitialized {
            return
        }
        isInitialized = true
        refresh(notify: false)

        let listener: AudioObjectPropertyListenerBlock = { count, rawProperties in
            let properties = unsafe UnsafeBufferPointer(start: rawProperties, count: Int(count))
            var notify = false
            for unsafe property in unsafe properties {
                notify = notify || property.mSelector == kAudioHardwarePropertyDevices
                    || property.mSelector == kAudioHardwarePropertyDefaultInputDevice
                    || property.mSelector == kAudioHardwarePropertyDefaultOutputDevice
            }
            if notify {
                audioCaptureDevices.scheduleUpdate()
            }
        }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = propertyAddress(selector, kAudioObjectPropertyScopeGlobal)
            let error = unsafe AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
            if error != noErr {
                logger.debug(
                    "CoreAudioCaptureDeviceManager::devices AudioObjectAddPropertyListener for \(selector) returned error \(error) (\(fourCharacters(error), privacy: .public))"
                )
            }
        }
    }

    private func scheduleUpdate() {
        precondition(WTF.isMainThread())
        if wasRefreshScheduled {
            return
        }
        wasRefreshScheduled = true
        DispatchQueue.main.async {
            audioCaptureDevices.refresh(notify: true)
            audioCaptureDevices.wasRefreshScheduled = false
        }
    }

    private func refresh(notify: Bool) {
        precondition(WTF.isMainThread())
        var newDevices = computeAudioDeviceList(filterTapEnabledDevices: filterTapEnabledDevices)
        if !haveDeviceChanges(devices, newDevices) {
            return
        }
        // Default devices first, in the HAL's order otherwise.
        newDevices = newDevices.filter(\.isDefault) + newDevices.filter { !$0.isDefault }
        devices = newDevices
        microphones = devices.filter(\.isMicrophone)
        speakers = devices.filter { !$0.isMicrophone }
        generation &+= 1
        if notify {
            WebCore.coreAudioCaptureDevicesDidChange()
        }
    }

    func currentGeneration() -> UInt64 {
        precondition(WTF.isMainThread())
        return generation
    }

    func list(speakers: Bool) -> [AudioCaptureDeviceRecord] {
        precondition(WTF.isMainThread())
        return speakers ? self.speakers : microphones
    }

    // CoreAudioCaptureDeviceManager::coreAudioDeviceWithUID(): the first enabled microphone or speaker with the ID.
    func deviceID(withUID uid: CFString) -> AudioObjectID? {
        initializeIfNeeded()
        return devices.first { $0.isEnabled && cfStringEqual($0.persistentID, uid) }?.deviceID
    }

    func setFilterTapEnabledDevices(_ value: Bool) {
        precondition(WTF.isMainThread())
        filterTapEnabledDevices = value
    }
}

private let audioCaptureDevices = AudioCaptureDevices()

// MARK: The C++ API

// The list's version, which changes when the list does, after reading it a first time if initialize.
@_expose(Cxx)
func audioCaptureDevicesGeneration(_ initialize: Bool) -> UInt64 {
    if initialize {
        audioCaptureDevices.initializeIfNeeded()
    }
    return audioCaptureDevices.currentGeneration()
}

@_expose(Cxx)
func audioCaptureDeviceCount(_ speakers: Bool) -> UInt32 {
    UInt32(audioCaptureDevices.list(speakers: speakers).count)
}

// The microphone or speaker at index, as a CaptureDevice.
@_expose(Cxx)
func audioCaptureDevice(_ speakers: Bool, _ index: UInt32) -> WebCore.CaptureDevice {
    let list = audioCaptureDevices.list(speakers: speakers)
    precondition(Int(index) < list.count)
    let device = list[Int(index)]
    return WebCore.CaptureDevice(
        WTF.String(device.persistentID),
        device.isMicrophone ? .Microphone : .Speaker,
        WTF.String(device.label),
        WTF.String(device.groupID),
        device.isEnabled,
        device.isDefault,
        false,
        false
    )
}

// The HAL ID of the enabled microphone or speaker with the given persistent ID, if there's one.
@_expose(Cxx)
func audioCaptureDeviceIDWithUID(_ uid: borrowing CFString?) -> WebCore.AudioCaptureDeviceLookup {
    var lookup = WebCore.AudioCaptureDeviceLookup()
    if let uid = copy uid, let deviceID = audioCaptureDevices.deviceID(withUID: uid) {
        lookup.deviceID = deviceID
        lookup.found = true
    }
    return lookup
}

// Whether output devices that have input only for echo cancellation are left out of the next refresh.
@_expose(Cxx)
func audioCaptureSetFilterTapEnabledDevices(_ value: Bool) {
    audioCaptureDevices.setFilterTapEnabledDevices(value)
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM && os(macOS)
