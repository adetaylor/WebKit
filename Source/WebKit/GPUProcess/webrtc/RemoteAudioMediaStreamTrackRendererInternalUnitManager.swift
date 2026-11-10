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
    private weak var manager: RemoteAudioMediaStreamTrackRendererInternalUnitManager?
    private let playout = TrackPlayout()
    private let localUnit: TrackRendererUnit
    private let canUseCaptureUnit: Bool
    private(set) var format: AudioStreamBasicDescription?
    private(set) var frameChunkSize: UInt64 = 0
    private var isPlaying = false
    private var shouldRegisterAsSpeakerSamplesProducer = false
    private var canReset = true

    init(identifier: UInt64, manager: RemoteAudioMediaStreamTrackRendererInternalUnitManager, deviceID: String) {
        self.identifier = identifier
        self.manager = manager
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

    private func computeShouldRegisterAsSpeakerSamplesProducer() -> Bool {
        canUseCaptureUnit && (manager?.isLastToCaptureAudio ?? false) && AudioCaptureSpeaker.shouldCaptureUnitRenderAudio
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
        let ring = unsafe SharedMemoryMapping(port: storageHandle.memory.port, size: storageHandle.memory.size, writable: false)
            .flatMap {
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
            let shouldNotStartLocalUnit =
                AudioCaptureSpeaker.shouldCaptureUnitRenderAudio || WebKit.GPUConnectionToWebProcess.isAudioSessionInterrupted()
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
        if shouldRegisterAsSpeakerSamplesProducer
            && (AudioCaptureSpeaker.isCaptureUnitRunning || AudioCaptureSpeaker.isCaptureUnitSuspended)
        {
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

// Receives the MediaStream track renderer unit messages of one web process's connection to the GPU process, which owns it
// (GPUConnectionState), and owns the units, which play out the rings the web process writes.
@_expose(Cxx)
final class RemoteAudioMediaStreamTrackRendererInternalUnitManager {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteAudioMediaStreamTrackRendererInternalUnitManagerMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    private var connection: WebKit.GPUConnectionToWebProcess?
    private var units: [UInt64: RemoteAudioTrackUnit] = [:]
    // Whether the connection's web process is the one that most recently started capturing audio.
    @_expose(!Cxx)
    private(set) var isLastToCaptureAudio = false

    @_expose(!Cxx)
    init(connection: WebKit.GPUConnectionToWebProcess) {
        self.connection = connection
        self.messageForwarder = WebKit.RemoteAudioMediaStreamTrackRendererInternalUnitManagerMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteAudioMediaStreamTrackRendererInternalUnitManagerMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        // The connection dispatches the receiver's messages on the main thread, which alone changes `connection`.
        MainActor.preconditionIsolated()
        guard let connection else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return connection.sharedPreferencesForWebProcess()
    }

    // Asks the web process to reset the unit, whose timeline jumped.
    @MainActor
    fileprivate func resetUnit(_ identifier: UInt64) {
        connection?.resetAudioMediaStreamTrackRendererInternalUnit(identifier)
    }

    // The units stop rendering, before they go with the connection.
    @_expose(!Cxx)
    @MainActor
    func invalidate() {
        for unit in units.values {
            unit.invalidate()
        }
        units.removeAll()
    }

    @_expose(!Cxx)
    @MainActor
    func setIsLastToCaptureAudio(_ isLastToCaptureAudio: Bool) {
        self.isLastToCaptureAudio = isLastToCaptureAudio
        for unit in units.values {
            unit.updateShouldRegisterAsSpeakerSamplesProducer()
        }
    }

    @_expose(!Cxx)
    @MainActor
    func beginAudioSessionInterruption() {
        for unit in units.values {
            unit.beginAudioSessionInterruption()
        }
    }

    @_expose(!Cxx)
    @MainActor
    func endAudioSessionInterruption() {
        for unit in units.values {
            unit.endAudioSessionInterruption()
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
        let unit = RemoteAudioTrackUnit(identifier: identifier.rawValue, manager: self, deviceID: deviceID ?? "")
        assert(units[identifier.rawValue] == nil)
        if units[identifier.rawValue] == nil {
            units[identifier.rawValue] = unit
        }
        guard let format = unit.format else {
            trackUnitLog.log("RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit unable to get format description")
            return (nil, 0)
        }
        return (IPCTypes.CAAudioStreamDescription(streamDescription: IPCTypes.AudioStreamBasicDescription(format)), unit.frameChunkSize)
    }

    @MainActor
    func deleteUnit(connection: IPC.Connection, identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier) {
        guard let unit = units.removeValue(forKey: identifier.rawValue) else {
            return
        }
        unit.invalidate()
        if units.isEmpty {
            self.connection?.tryExitIfUnusedAndUnderMemoryPressure()
        }
    }

    @MainActor
    func startUnit(
        connection: IPC.Connection,
        identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier,
        storageHandle: borrowing IPCTypes.ConsumerSharedCARingBufferHandle,
        renderSemaphore: consuming IPCTypes.Semaphore
    ) {
        units[identifier.rawValue]?.start(storageHandle, renderSemaphore)
    }

    @MainActor
    func stopUnit(connection: IPC.Connection, identifier: IPCTypes.AudioMediaStreamTrackRendererInternalUnitIdentifier) {
        units[identifier.rawValue]?.stop()
    }
}

extension RemoteAudioMediaStreamTrackRendererInternalUnitManager: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        units.isEmpty
    }

    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        connection = nil
        isLastToCaptureAudio = false
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
