// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA

@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal
import os

private let destinationLog = os.Logger(subsystem: "com.apple.WebKit", category: "Media")

// A GPU-process audio destination: an output unit that plays out the ring the web process writes, adds each quantum's
// frames to the counter they share and signals the semaphore the web process waits on, all of which it owns.
@MainActor
private final class RemoteAudioDestination {
    private let identifier: UInt64
    private let output: RemoteDestinationOutputUnit
    private let channelCount: UInt32
    private let frameCounter: SharedMemoryMapping?
    private let renderSemaphore: AudioSemaphoreRight?
    private var ring: SharedAudioRing?
    let prefersSpatialAudioExperience: Bool
    private(set) var isPlaying = false

    init(
        identifier: UInt64,
        channelCount: UInt32,
        hardwareSampleRate: Float,
        renderSemaphore: borrowing IPCTypes.Semaphore,
        frameCount: borrowing IPCTypes.SharedMemoryHandle,
        prefersSpatialAudioExperience: Bool
    ) {
        self.identifier = identifier
        output = RemoteDestinationOutputUnit(sampleRate: hardwareSampleRate, channelCount: channelCount)
        self.channelCount = channelCount
        // Safety: the port is the right that the message's handle carries and owns.
        frameCounter = unsafe SharedMemoryMapping(port: frameCount.port, size: frameCount.size, writable: true)
        self.renderSemaphore = AudioSemaphoreRight(port: renderSemaphore.port)
        self.prefersSpatialAudioExperience = prefersSpatialAudioExperience
        destinationLog.log("RemoteAudioDestination::RemoteAudioDestination(\(identifier))")
        attachRing()
    }

    var outputUnitIdentifier: UInt64 {
        output.identifier
    }

    var latency: UInt64 {
        output.latency
    }

    func start() {
        let error = output.start()
        if error != 0 {
            destinationLog.error("RemoteAudioDestination::start(\(self.identifier)) Failed to start AudioOutputUnit")
            return
        }
        destinationLog.log("RemoteAudioDestination::start(\(self.identifier))")
        isPlaying = true
    }

    func stop() {
        let error = output.stop()
        if error != 0 {
            destinationLog.error("RemoteAudioDestination::stop(\(self.identifier)) Failed to stop AudioOutputUnit")
            return
        }
        destinationLog.log("RemoteAudioDestination::stop(\(self.identifier))")
        isPlaying = false
    }

    // The unit is stopped whenever the ring changes, and restarts if it was playing and there is a new ring.
    func storageChanged(_ handle: borrowing IPCTypes.ConsumerSharedCARingBufferHandle) {
        let wasPlaying = isPlaying
        if isPlaying {
            stop()
            assert(!isPlaying)
            if isPlaying {
                return
            }
        }
        // Safety: the port is the right that the message's handle carries and owns.
        ring = unsafe SharedMemoryMapping(port: handle.memory.port, size: handle.memory.size, writable: false)
            .flatMap {
                SharedAudioRing(memory: $0, bytesPerFrame: 4, channelStreamCount: channelCount, frameCount: handle.frameCount)
            }
        attachRing()
        if ring == nil {
            return
        }
        if wasPlaying {
            start()
            assert(isPlaying)
        }
    }

    private func attachRing() {
        output.attach(ring: ring, frameCounter: frameCounter, semaphore: renderSemaphore)
    }
}

// Receives the audio destination messages of one web process's connection to the GPU process, which owns it
// (GPUConnectionState), and owns the destinations, which play out the rings the web process writes. iOS's scene identifier,
// whose spatial experience only C++ can make, goes to the connection itself (GPUConnectionToWebProcess.messages.in).
@_expose(Cxx)
final class RemoteAudioDestinationManager {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteAudioDestinationManagerMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    private var connection: WebKit.GPUConnectionToWebProcess?
    private let isLockdownModeEnabled: Bool
    private var destinations: [UInt64: RemoteAudioDestination] = [:]

    @_expose(!Cxx)
    init(connection: WebKit.GPUConnectionToWebProcess, isLockdownModeEnabled: Bool) {
        self.connection = connection
        self.isLockdownModeEnabled = isLockdownModeEnabled
        self.messageForwarder = WebKit.RemoteAudioDestinationManagerMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteAudioDestinationManagerMessageForwarder {
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

    private var prefersSpatialAudioExperience: Bool {
        #if HAVE_SPATIAL_AUDIO_EXPERIENCE
        sharedPreferencesForWebProcess().value?.preferSpatialAudioExperience ?? false
        #else
        false
        #endif
    }

    // The destinations stop rendering, before they go with the connection.
    @_expose(!Cxx)
    @MainActor
    func invalidate() {
        destinations.removeAll()
    }

    // The output unit of the destination that iOS's spatial experience is set on, if there is one, and whether its web
    // process preferred a spatial experience when it made it.
    @_expose(!Cxx)
    @MainActor
    func spatialTarget(_ destinationIdentifier: UInt64) -> (outputUnitIdentifier: UInt64, prefersSpatialAudioExperience: Bool)? {
        destinations[destinationIdentifier].map { ($0.outputUnitIdentifier, $0.prefersSpatialAudioExperience) }
    }

    @MainActor
    func createAudioDestination(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteAudioDestinationIdentifier,
        inputDeviceId: String?,
        numberOfInputChannels: UInt32,
        numberOfOutputChannels: UInt32,
        sampleRate: Float,
        hardwareSampleRate: Float,
        renderSemaphore: consuming IPCTypes.Semaphore,
        frameCount: consuming IPCTypes.SharedMemoryHandle
    ) throws(InvalidMessage) -> UInt64 {
        try messageCheck("Received a createAudioDestination() message from a webpage in Lockdown mode.") {
            !isLockdownModeEnabled
        }
        try messageCheck("AudioDestination already cached.") {
            destinations[identifier.rawValue] == nil
        }
        let destination = RemoteAudioDestination(
            identifier: identifier.rawValue,
            channelCount: numberOfOutputChannels,
            hardwareSampleRate: hardwareSampleRate,
            renderSemaphore: renderSemaphore,
            frameCount: frameCount,
            prefersSpatialAudioExperience: prefersSpatialAudioExperience
        )
        destinations[identifier.rawValue] = destination
        return destination.latency
    }

    @MainActor
    func deleteAudioDestination(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioDestinationIdentifier) throws(InvalidMessage) {
        try messageCheck("Received a deleteAudioDestination() message from a webpage in Lockdown mode.") {
            !isLockdownModeEnabled
        }
        destinations.removeValue(forKey: identifier.rawValue)
        #if WTF_PLATFORM_IOS_FAMILY
        self.connection?.audioDestinationWasDeleted(identifier.rawValue)
        #endif
        if allowsExitUnderMemoryPressure {
            self.connection?.tryExitIfUnusedAndUnderMemoryPressure()
        }
    }

    @MainActor
    func startAudioDestination(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteAudioDestinationIdentifier
    ) throws(InvalidMessage) -> (isPlaying: Bool, audioUnitLatency: UInt64) {
        try messageCheck { !isLockdownModeEnabled }
        guard let destination = destinations[identifier.rawValue] else {
            return (false, 0)
        }
        destination.start()
        return (destination.isPlaying, destination.latency)
    }

    @MainActor
    func stopAudioDestination(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteAudioDestinationIdentifier
    ) throws(InvalidMessage) -> Bool {
        try messageCheck { !isLockdownModeEnabled }
        guard let destination = destinations[identifier.rawValue] else {
            return false
        }
        destination.stop()
        return destination.isPlaying
    }

    @MainActor
    func audioSamplesStorageChanged(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteAudioDestinationIdentifier,
        storageHandle: borrowing IPCTypes.ConsumerSharedCARingBufferHandle
    ) {
        destinations[identifier.rawValue]?.storageChanged(storageHandle)
    }
}

extension RemoteAudioDestinationManager: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        !destinations.values.contains { $0.isPlaying }
    }

    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        connection = nil
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
