// Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS

import WebKit_Internal

// A receiver of a web process's messages that the connection's Swift state owns and routes the messages to while the
// connection is in the GPU process.
protocol GPUConnectionReceiver: AnyObject {
    // Whether the GPU process may exit under memory pressure as far as this receiver is concerned.
    @MainActor
    var allowsExitUnderMemoryPressure: Bool { get }
    // The connection has closed and its messages no longer reach this receiver.
    @MainActor
    func connectionDidClose()
}

// The Swift state of a web process's connection to the GPU process (GPUConnectionToWebProcess.h), which
// GPUConnectionToWebProcess::m_swiftState holds.
@MainActor
final class GPUConnectionState {
    let processIdentifier: UInt64
    let isLockdownModeEnabled: Bool
    // The Now Playing candidate states of the connection's pages, by page identifier, which the election reads.
    var nowPlayingCandidates: [UInt64: IPCTypes.NowPlayingCandidateState] = [:]

    // The receivers the state owns, from when the connection is added to the GPU process; their registrations route their
    // messages to them until the connection is removed from it.
    #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
    private(set) var audioDestinationManager: RemoteAudioDestinationManager?
    #endif
    #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
    private(set) var audioMediaStreamTrackRendererInternalUnitManager: RemoteAudioMediaStreamTrackRendererInternalUnitManager?
    #endif
    private var registrations: [IPC.SwiftReceiverRegistration] = []

    fileprivate nonisolated init(processIdentifier: UInt64, isLockdownModeEnabled: Bool) {
        self.processIdentifier = processIdentifier
        self.isLockdownModeEnabled = isLockdownModeEnabled
    }

    var receivers: [any GPUConnectionReceiver] {
        var receivers: [any GPUConnectionReceiver] = []
        #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
        if let audioDestinationManager {
            receivers.append(audioDestinationManager)
        }
        #endif
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        if let audioMediaStreamTrackRendererInternalUnitManager {
            receivers.append(audioMediaStreamTrackRendererInternalUnitManager)
        }
        #endif
        return receivers
    }

    fileprivate func createReceivers(for connection: WebKit.GPUConnectionToWebProcess) {
        #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
        let audioDestinationManager = RemoteAudioDestinationManager(connection: connection, isLockdownModeEnabled: isLockdownModeEnabled)
        self.audioDestinationManager = audioDestinationManager
        register(IPC.registerSwiftReceiver(connection, audioDestinationManager.getMessageReceiver(), .RemoteAudioDestinationManager, 0))
        #endif
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        let audioMediaStreamTrackRendererInternalUnitManager = RemoteAudioMediaStreamTrackRendererInternalUnitManager(
            connection: connection
        )
        self.audioMediaStreamTrackRendererInternalUnitManager = audioMediaStreamTrackRendererInternalUnitManager
        register(
            IPC.registerSwiftReceiver(
                connection,
                audioMediaStreamTrackRendererInternalUnitManager.getMessageReceiver(),
                .RemoteAudioMediaStreamTrackRendererInternalUnitManager,
                0
            )
        )
        #endif
    }

    private func register(_ registration: IPC.SwiftReceiverRegistration?) {
        guard let registration else {
            preconditionFailure("The connection that adds its receivers has gone")
        }
        registrations.append(registration)
    }

    // The receivers' messages stop before they hear the connection has closed.
    fileprivate func connectionDidClose() {
        registrations.removeAll()
        for receiver in receivers {
            receiver.connectionDidClose()
        }
    }

    var allowsExitUnderMemoryPressure: Bool {
        receivers.allSatisfy { $0.allowsExitUnderMemoryPressure }
    }

    fileprivate func invalidateReceivers() {
        #if ENABLE_WEB_AUDIO && WTF_PLATFORM_COCOA
        audioDestinationManager?.invalidate()
        #endif
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        audioMediaStreamTrackRendererInternalUnitManager?.invalidate()
        #endif
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    func createSwiftState(_ webProcessIdentifier: UInt64, _ isLockdownModeEnabled: Bool) -> UInt {
        let state = GPUConnectionState(processIdentifier: webProcessIdentifier, isLockdownModeEnabled: isLockdownModeEnabled)
        return UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        let state = unsafe Unmanaged<GPUConnectionState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
        MainActor.assumeIsolated {
            // The receivers stop rendering here, on the main thread.
            state.invalidateReceivers()
        }
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The connection has no Swift state")
        }
        return unsafe address
    }

    var state: GPUConnectionState {
        // Safety: m_swiftState is a retained GPUConnectionState from the constructor to the destructor, and nothing else
        // changes it.
        unsafe Unmanaged<GPUConnectionState>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftDidAddToGPUProcess() {
        webProcessConnections.add(self, process: state.processIdentifier)
        state.createReceivers(for: self)
    }

    @cxx
    @implementation
    @MainActor
    func swiftDidRemoveFromGPUProcess() {
        state.connectionDidClose()
        webProcessConnections.remove(process: state.processIdentifier)
        nowPlayingArbiter.recompute()
    }

    @cxx
    @implementation
    @MainActor
    func swiftIsActiveNowPlayingPage(_ pageIdentifier: UInt64) -> Bool {
        nowPlayingArbiter.isActive(process: state.processIdentifier, page: pageIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func swiftRemoteCommandTargetSession() -> UInt64 {
        nowPlayingArbiter.remoteCommandTargetSession(in: state.processIdentifier) ?? 0
    }

    @cxx
    @implementation
    @MainActor
    func swiftNowPlayingClientDidClose() {
        state.nowPlayingCandidates.removeAll()
        nowPlayingArbiter.clientDidClose(process: state.processIdentifier)
    }

    #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
    @cxx
    @implementation
    @MainActor
    func swiftLastToCaptureAudioChanged(_ isLastToCaptureAudio: Bool) {
        MainActor.preconditionIsolated()
        state.audioMediaStreamTrackRendererInternalUnitManager?.setIsLastToCaptureAudio(isLastToCaptureAudio)
    }

    @cxx
    @implementation
    @MainActor
    func swiftBeginAudioSessionInterruption() {
        MainActor.preconditionIsolated()
        state.audioMediaStreamTrackRendererInternalUnitManager?.beginAudioSessionInterruption()
    }

    @cxx
    @implementation
    @MainActor
    func swiftEndAudioSessionInterruption() {
        MainActor.preconditionIsolated()
        state.audioMediaStreamTrackRendererInternalUnitManager?.endAudioSessionInterruption()
    }
    #endif

    #if ENABLE_WEB_AUDIO && WTF_PLATFORM_IOS_FAMILY
    @cxx
    @implementation
    @MainActor
    func swiftAudioDestinationSpatialTarget(_ destinationIdentifier: UInt64) -> WebKit.RemoteAudioDestinationSpatialTarget {
        MainActor.preconditionIsolated()
        var target = WebKit.RemoteAudioDestinationSpatialTarget()
        if let destination = state.audioDestinationManager?.spatialTarget(destinationIdentifier) {
            target.outputUnitIdentifier = destination.outputUnitIdentifier
            target.prefersSpatialAudioExperience = destination.prefersSpatialAudioExperience
        }
        return target
    }
    #endif

    // The candidate state and the Now Playing info of the page, or of all of the connection's pages, go.
    @MainActor
    func clearNowPlayingCandidates(page: UInt64?) {
        if let page {
            state.nowPlayingCandidates[page] = nil
        } else {
            state.nowPlayingCandidates.removeAll()
        }
        clearNowPlayingInfo(page == nil, page ?? 0)
        nowPlayingArbiter.recompute()
    }

    @MainActor
    func clearNowPlayingInfoForPage(connection: IPC.Connection, pageIdentifier: IPCTypes.PageIdentifier?) {
        clearNowPlayingCandidates(page: pageIdentifier?.rawValue)
    }

    @MainActor
    func setNowPlayingCandidateState(connection: IPC.Connection, candidate: IPCTypes.NowPlayingCandidateState) {
        guard let page = candidate.pageIdentifier else {
            return
        }
        state.nowPlayingCandidates[page.rawValue] = candidate
        nowPlayingArbiter.recompute()
    }

    @MainActor
    func isActiveNowPlayingSessionForTesting(connection: IPC.Connection, identifier: IPCTypes.MediaSessionIdentifier) -> Bool {
        nowPlayingArbiter.isActive(process: state.processIdentifier, session: identifier.rawValue)
    }

    // Unlike the remote command target session, safe to ask from any process: it compares rather than assuming the
    // caller owns the target.
    @MainActor
    func isRemoteCommandTargetSessionForTesting(connection: IPC.Connection, identifier: IPCTypes.MediaSessionIdentifier) -> Bool {
        nowPlayingArbiter.isRemoteCommandTarget(process: state.processIdentifier, session: identifier.rawValue)
    }
}

#endif // ENABLE_GPU_PROCESS
