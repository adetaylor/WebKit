// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS && ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA

import CoreAudioTypes
import Dispatch
@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal
import os

private let trackUnitLog = os.Logger(subsystem: "com.apple.WebKit", category: "WebRTC")

// WebCore::AudioUtilities::renderQuantumSize.
private let renderQuantumSize: UInt64 = 128

// A GPU-process MediaStream track renderer unit: a track playout of the ring the web process writes, which its own output
// unit plays out, or, when it renders to the default device and its web process is the last to capture audio, the default
// capture unit's speaker while that unit runs.
@MainActor
private final class RemoteAudioTrackUnit: AudioSpeakerSamplesProducer {
    private let identifier: UInt64
    private weak var state: RemoteAudioTrackUnitsState?
    private let playout = TrackPlayout()
    private let localUnit: TrackRendererUnit
    private let canUseCaptureUnit: Bool
    private(set) var format: AudioStreamBasicDescription?
    private(set) var frameChunkSize: UInt64 = 0
    private var isPlaying = false
    private var shouldRegisterAsSpeakerSamplesProducer = false
    private var canReset = true

    init(identifier: UInt64, state: RemoteAudioTrackUnitsState, deviceID: String) {
        self.identifier = identifier
        self.state = state
        localUnit = TrackRendererUnit(playing: playout)
        canUseCaptureUnit = TrackRendererUnit.isDefaultDevice(deviceID)
        localUnit.setDevice(persistentID: deviceID)
        localUnit.timelineDiscontinuityHandler = { [weak self] in
            MainActor.assumeIsolated {
                self?.reset()
            }
        }
        guard let format = localUnit.format else {
            return
        }
        let tenMilliseconds = format.mSampleRate * 10 / 1000
        let tenMillisecondFrames = tenMilliseconds.isFinite && tenMilliseconds >= 0 && tenMilliseconds < 1e18 ? UInt64(tenMilliseconds) : 0
        self.format = format
        frameChunkSize = max(renderQuantumSize, tenMillisecondFrames)
    }

    // Stops playing out the ring, which the units that still hold the track let go of, with its semaphore.
    func invalidate() {
        stop()
        playout.attach(ring: nil, semaphore: nil, frameChunkSize: 0, bytesPerFrame: 0)
    }

    private var manager: WebKit.RemoteAudioMediaStreamTrackRendererInternalUnitManager? {
        state?.manager
    }

    private func computeShouldRegisterAsSpeakerSamplesProducer() -> Bool {
        canUseCaptureUnit && (manager?.isLastToCaptureAudio() ?? false) && AudioCaptureSpeaker.shouldCaptureUnitRenderAudio
    }

    private func reset() {
        if !canReset {
            return
        }
        canReset = false
        manager?.resetUnit(identifier)
    }

    private func setShouldRegisterAsSpeakerSamplesProducer(_ value: Bool) {
        if shouldRegisterAsSpeakerSamplesProducer == value {
            return
        }
        assert(canUseCaptureUnit)
        shouldRegisterAsSpeakerSamplesProducer = value
        if !isPlaying {
            return
        }
        if shouldRegisterAsSpeakerSamplesProducer {
            localUnit.stop()
            AudioCaptureSpeaker.register(self)
        } else {
            AudioCaptureSpeaker.unregister(self)
            localUnit.start()
        }
    }

    func updateShouldRegisterAsSpeakerSamplesProducer() {
        setShouldRegisterAsSpeakerSamplesProducer(computeShouldRegisterAsSpeakerSamplesProducer())
    }

    func start(_ storageHandle: borrowing IPCTypes.ConsumerSharedCARingBufferHandle, _ renderSemaphore: borrowing IPCTypes.Semaphore) {
        if isPlaying {
            stop()
        }
        // The units that still hold the track stop reading the old ring and signalling the old semaphore.
        playout.attach(ring: nil, semaphore: nil, frameChunkSize: 0, bytesPerFrame: 0)
        guard let format else {
            return
        }
        // Safety: the port is the right that the message's handle carries and owns.
        let ring = unsafe SharedMemoryMapping(port: storageHandle.memory.port, size: storageHandle.memory.size, writable: false).flatMap {
            SharedAudioRing(memory: $0, format: format, frameCount: storageHandle.frameCount)
        }
        guard let ring else {
            return
        }
        isPlaying = true
        canReset = true
        playout.attach(
            ring: ring,
            semaphore: AudioSemaphoreRight(port: renderSemaphore.port),
            frameChunkSize: frameChunkSize,
            bytesPerFrame: UInt64(format.mBytesPerFrame)
        )
        shouldRegisterAsSpeakerSamplesProducer = computeShouldRegisterAsSpeakerSamplesProducer()

        if shouldRegisterAsSpeakerSamplesProducer {
            AudioCaptureSpeaker.register(self)
            let shouldNotStartLocalUnit = AudioCaptureSpeaker.shouldCaptureUnitRenderAudio || (manager?.isAudioSessionInterrupted() ?? false)
            if shouldNotStartLocalUnit {
                return
            }
        }

        localUnit.start()
    }

    func stop() {
        isPlaying = false
        AudioCaptureSpeaker.unregister(self)
        localUnit.stop()
    }

    func beginAudioSessionInterruption() {
        if isPlaying {
            localUnit.stop()
        }
    }

    func endAudioSessionInterruption() {
        if !isPlaying {
            return
        }
        if shouldRegisterAsSpeakerSamplesProducer && (AudioCaptureSpeaker.isCaptureUnitRunning || AudioCaptureSpeaker.isCaptureUnitSuspended) {
            return
        }
        localUnit.start()
    }

    // AudioSpeakerSamplesProducer

    var speakerTrackPlayout: TrackPlayout {
        playout
    }

    var speakerFormat: AudioStreamBasicDescription {
        format ?? AudioStreamBasicDescription()
    }

    // Audio will be rendered through the capture unit, not the local unit.
    func captureUnitIsStarting() {
        if isPlaying && AudioCaptureSpeaker.shouldCaptureUnitRenderAudio {
            localUnit.stop()
        }
    }

    // Audio will no longer be rendered through the capture unit, so the local unit renders it.
    func captureUnitHasStopped() {
        if isPlaying && !AudioCaptureSpeaker.isCaptureUnitSuspended {
            localUnit.start()
        }
    }

    func canRenderAudioChanged() {
        // After the capture unit has finished changing its own state.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else {
                    return
                }
                self.updateShouldRegisterAsSpeakerSamplesProducer()
            }
        }
    }
}

// The Swift state of a RemoteAudioMediaStreamTrackRendererInternalUnitManager
// (RemoteAudioMediaStreamTrackRendererInternalUnitManager.h): its units by identifier, and, once a unit starts, the
// manager, until the web process's connection closes: the manager and its state keep each other alive until then.
@MainActor
final class RemoteAudioTrackUnitsState {
    fileprivate var manager: WebKit.RemoteAudioMediaStreamTrackRendererInternalUnitManager?
    fileprivate var units: [UInt64: RemoteAudioTrackUnit] = [:]

    fileprivate nonisolated init() {
    }

    fileprivate func clear() {
        manager = nil
    }

    fileprivate func invalidate() {
        for unit in units.values {
            unit.invalidate()
        }
        units.removeAll()
    }
}

extension WebKit.RemoteAudioMediaStreamTrackRendererInternalUnitManager {
    @cxx
    @implementation
    func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteAudioTrackUnitsState()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        let state = unsafe Unmanaged<RemoteAudioTrackUnitsState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
        MainActor.assumeIsolated {
            state.invalidate()
        }
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The manager has no Swift state")
        }
        return unsafe address
    }

    private var state: RemoteAudioTrackUnitsState {
        // Safety: m_swiftState is a retained RemoteAudioTrackUnitsState from the constructor to the destructor, and nothing
        // else changes it.
        unsafe Unmanaged<RemoteAudioTrackUnitsState>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }

    @cxx
    @implementation
    func clear() {
        let state = state
        MainActor.assumeIsolated {
            state.clear()
        }
    }

    @cxx
    @implementation
    func hasUnits() -> Bool {
        let state = state
        return MainActor.assumeIsolated {
            !state.units.isEmpty
        }
    }

    @cxx
    @implementation
    func notifyLastToCaptureAudioChanged() {
        let state = state
        MainActor.assumeIsolated {
            for unit in state.units.values {
                unit.updateShouldRegisterAsSpeakerSamplesProducer()
            }
        }
    }

    @cxx
    @implementation
    func swiftBeginAudioSessionInterruption() {
        let state = state
        MainActor.assumeIsolated {
            for unit in state.units.values {
                unit.beginAudioSessionInterruption()
            }
        }
    }

    @cxx
    @implementation
    func swiftEndAudioSessionInterruption() {
        let state = state
        MainActor.assumeIsolated {
            for unit in state.units.values {
                unit.endAudioSessionInterruption()
            }
        }
    }

    // The unit for the identifier, on the device; the default capture unit's speaker may play out a unit for the default
    // device instead.
    @MainActor
    func createUnit(
        connection: IPC.Connection,
        identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier,
        deviceID: String?
    ) -> (description: IPCTypes.CAAudioStreamDescription?, frameChunkSize: UInt64) {
        let state = state
        let unit = RemoteAudioTrackUnit(identifier: identifier.rawValue, state: state, deviceID: deviceID ?? "")
        assert(state.units[identifier.rawValue] == nil)
        if state.units[identifier.rawValue] == nil {
            state.units[identifier.rawValue] = unit
        }
        guard let format = unit.format else {
            trackUnitLog.log("RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit unable to get format description")
            return (nil, 0)
        }
        return (IPCTypes.CAAudioStreamDescription(streamDescription: IPCTypes.AudioStreamBasicDescription(format)), unit.frameChunkSize)
    }

    @MainActor
    func deleteUnit(connection: IPC.Connection, identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier) {
        let state = state
        guard let unit = state.units.removeValue(forKey: identifier.rawValue) else {
            return
        }
        unit.invalidate()
        if state.units.isEmpty {
            tryExitIfUnusedAndUnderMemoryPressure()
        }
    }

    @MainActor
    func startUnit(
        connection: IPC.Connection,
        identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier,
        storageHandle: borrowing IPCTypes.ConsumerSharedCARingBufferHandle,
        renderSemaphore: consuming IPCTypes.Semaphore
    ) {
        let state = state
        guard let unit = state.units[identifier.rawValue] else {
            return
        }
        // What a playing unit asks its web process's connection, and the resets it sends.
        state.manager = self
        unit.start(storageHandle, renderSemaphore)
    }

    @MainActor
    func stopUnit(connection: IPC.Connection, identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier) {
        state.units[identifier.rawValue]?.stop()
    }
}

extension IPCTypes.AudioStreamBasicDescription {
    fileprivate init(_ format: AudioStreamBasicDescription) {
        self.init(
            mSampleRate: format.mSampleRate,
            mFormatID: format.mFormatID,
            mFormatFlags: format.mFormatFlags,
            mBytesPerPacket: format.mBytesPerPacket,
            mFramesPerPacket: format.mFramesPerPacket,
            mBytesPerFrame: format.mBytesPerFrame,
            mChannelsPerFrame: format.mChannelsPerFrame,
            mBitsPerChannel: format.mBitsPerChannel,
            mReserved: format.mReserved
        )
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
