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
        ring = unsafe SharedMemoryMapping(port: handle.memory.port, size: handle.memory.size, writable: false).flatMap {
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

// The Swift state of a RemoteAudioDestinationManager (RemoteAudioDestinationManager.h): its destinations by identifier.
@MainActor
final class RemoteAudioDestinationManagerState {
    fileprivate var destinations: [UInt64: RemoteAudioDestination] = [:]

    fileprivate nonisolated init() {
    }

    fileprivate var allowsExitUnderMemoryPressure: Bool {
        !destinations.values.contains { $0.isPlaying }
    }
}

extension WebKit.RemoteAudioDestinationManager {
    @cxx
    @implementation
    func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteAudioDestinationManagerState()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        let state = unsafe Unmanaged<RemoteAudioDestinationManagerState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
        MainActor.assumeIsolated {
            // The destinations stop rendering here, on the main thread.
            state.destinations.removeAll()
        }
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The manager has no Swift state")
        }
        return unsafe address
    }

    private var state: RemoteAudioDestinationManagerState {
        // Safety: m_swiftState is a retained RemoteAudioDestinationManagerState from the constructor to the destructor, and
        // nothing else changes it.
        unsafe Unmanaged<RemoteAudioDestinationManagerState>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }

    @cxx
    @implementation
    func allowsExitUnderMemoryPressure() -> Bool {
        let state = state
        return MainActor.assumeIsolated {
            state.allowsExitUnderMemoryPressure
        }
    }

    @cxx
    @implementation
    func spatialTarget(_ destinationIdentifier: UInt64) -> WebKit.RemoteAudioDestinationSpatialTarget {
        let state = state
        return MainActor.assumeIsolated {
            var target = WebKit.RemoteAudioDestinationSpatialTarget()
            if let destination = state.destinations[destinationIdentifier] {
                target.outputUnitIdentifier = destination.outputUnitIdentifier
                target.prefersSpatialAudioExperience = destination.prefersSpatialAudioExperience
            }
            return target
        }
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
            !isLockdownModeEnabled()
        }
        let state = state
        try messageCheck("AudioDestination already cached.") {
            state.destinations[identifier.rawValue] == nil
        }
        let destination = RemoteAudioDestination(
            identifier: identifier.rawValue,
            channelCount: numberOfOutputChannels,
            hardwareSampleRate: hardwareSampleRate,
            renderSemaphore: renderSemaphore,
            frameCount: frameCount,
            prefersSpatialAudioExperience: prefersSpatialAudioExperience()
        )
        state.destinations[identifier.rawValue] = destination
        return destination.latency
    }

    @MainActor
    func deleteAudioDestination(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioDestinationIdentifier) throws(InvalidMessage) {
        try messageCheck("Received a deleteAudioDestination() message from a webpage in Lockdown mode.") {
            !isLockdownModeEnabled()
        }
        let state = state
        state.destinations.removeValue(forKey: identifier.rawValue)
        destinationWasDeleted(identifier.rawValue)
        if state.allowsExitUnderMemoryPressure {
            tryExitIfUnusedAndUnderMemoryPressure()
        }
    }

    @MainActor
    func startAudioDestination(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteAudioDestinationIdentifier
    ) throws(InvalidMessage) -> (isPlaying: Bool, audioUnitLatency: UInt64) {
        try messageCheck { !isLockdownModeEnabled() }
        guard let destination = state.destinations[identifier.rawValue] else {
            return (false, 0)
        }
        destination.start()
        return (destination.isPlaying, destination.latency)
    }

    @MainActor
    func stopAudioDestination(connection: IPC.Connection, identifier: IPCTypes.RemoteAudioDestinationIdentifier) throws(InvalidMessage) -> Bool {
        try messageCheck { !isLockdownModeEnabled() }
        guard let destination = state.destinations[identifier.rawValue] else {
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
        state.destinations[identifier.rawValue]?.storageChanged(storageHandle)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
