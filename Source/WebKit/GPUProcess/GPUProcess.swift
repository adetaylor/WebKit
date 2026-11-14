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
#if canImport(os)
import os
#endif

// The Swift state of the GPU process (GPUProcess.h), which GPUProcess::m_swiftState holds.
@MainActor
final class GPUProcessState {
#if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
    // The capture preview of a getUserMedia prompt, while there is one (CapturePreviewManager.swift).
    var capturePreview: CapturePreviewManager?
#endif

    // When the process started, on the clock that stops while the system sleeps, as MonotonicTime.
    let creationTime = SuspendingClock.now
    // The check again for an idle exit, once the process has lived long enough.
    var idleExitCheck: Task<Void, Never>?

    fileprivate nonisolated init() {
    }
}

extension WebKit.GPUProcess {
    @cxx
    @implementation
    func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(GPUProcessState()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        unsafe Unmanaged<GPUProcessState>.fromOpaque(stateAddress(swiftState)).release()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The GPU process has no Swift state")
        }
        return unsafe address
    }

    var state: GPUProcessState {
        // Safety: m_swiftState is a retained GPUProcessState from the constructor to the destructor, and nothing else
        // changes it.
        unsafe Unmanaged<GPUProcessState>.fromOpaque(Self.stateAddress(swiftState())).takeUnretainedValue()
    }
}

// The GPU process's connections to the web processes, as GPUProcess::m_webProcessConnections, by process identifier.
@MainActor
final class WebProcessConnections {
    private(set) var all: [UInt64: WebKit.GPUConnectionToWebProcess] = [:]

    fileprivate nonisolated init() {
    }

    subscript(process: UInt64) -> WebKit.GPUConnectionToWebProcess? {
        all[process]
    }

    func add(_ connection: WebKit.GPUConnectionToWebProcess, process: UInt64) {
        all[process] = connection
    }

    func remove(_ connection: WebKit.GPUConnectionToWebProcess, process: UInt64) {
        if let current = all[process], current.state === connection.state {
            all[process] = nil
        }
    }
}

let webProcessConnections = WebProcessConnections()

// The Now Playing election across the pages of every web process: the page whose candidate session is preferred owns the
// Now Playing panel and gets the remote commands; without one, the UI process's fallback session, if its process has a
// connection, gets the remote commands alone. One connection at a time is the NowPlayingManager's client.
@MainActor
final class NowPlayingArbiter {
    struct Owner: Equatable {
        let process: UInt64
        let page: UInt64
        let session: UInt64
    }

    // A media session of a web process, as WebCore::QualifiedMediaSessionIdentifier.
    struct QualifiedSession: Equatable {
        let session: UInt64
        let process: UInt64
    }

    private enum SeatRole {
        case eligibleOwner
        case commandOnly
    }

    private struct Seat: Equatable {
        let process: UInt64
        let role: SeatRole
    }

    private struct OwnerPage: Equatable {
        let page: UInt64
        let process: UInt64
    }

    private(set) var activeOwner: Owner?
    var fallbackSession: QualifiedSession?
    private(set) var remoteCommandTarget: QualifiedSession?

    fileprivate nonisolated init() {
    }

    func isActive(process: UInt64, page: UInt64) -> Bool {
        activeOwner.map { $0.process == process && $0.page == page } ?? false
    }

    func isActive(process: UInt64, session: UInt64) -> Bool {
        activeOwner.map { $0.process == process && $0.session == session } ?? false
    }

    func isRemoteCommandTarget(process: UInt64, session: UInt64) -> Bool {
        remoteCommandTarget == QualifiedSession(session: session, process: process)
    }

    // The session that the remote commands go to, which the caller, the NowPlayingManager's client, can only name in its
    // own process.
    func remoteCommandTargetSession(in process: UInt64) -> UInt64? {
        guard let remoteCommandTarget else {
            return nil
        }
        guard remoteCommandTarget.process == process else {
            assertionFailure()
            WebKit.LogChannel.Media().releaseLog.error("GPUProcess::remoteCommandTargetSessionInProcess: command target belongs to another process; delivering nothing rather than a cross-process identifier")
            return nil
        }
        return remoteCommandTarget.session
    }

    func setFallbackSession(_ session: QualifiedSession?) {
        fallbackSession = session
        // The fallback is only consulted when the election has no eligible owner, and every change to the candidates
        // recomputes on its own, so an owner means this cannot change the outcome.
        if activeOwner == nil {
            recompute()
        }
    }

    func clientDidClose(process: UInt64) {
        if fallbackSession?.process == process {
            fallbackSession = nil
        }
        if remoteCommandTarget?.process == process {
            remoteCommandTarget = nil
        }
        recompute()
    }

    func recompute() {
        var winner: (connection: WebKit.GPUConnectionToWebProcess, process: UInt64, page: UInt64, state: IPCTypes.NowPlayingCandidateState)?

        // Seed with the current owner so that equal candidates keep the incumbent, since the candidates are in
        // dictionaries whose iteration order is not stable.
        if let activeOwner, let connection = webProcessConnections[activeOwner.process], let state = connection.state.nowPlayingCandidates[activeOwner.page] {
            winner = (connection, activeOwner.process, activeOwner.page, state)
        }

        for (process, connection) in webProcessConnections.all {
            for (page, state) in connection.state.nowPlayingCandidates {
                if let current = winner, !isPreferred(state, over: current.state) {
                    continue
                }
                winner = (connection, process, page, state)
            }
        }

        var seated: (connection: WebKit.GPUConnectionToWebProcess, process: UInt64)?
        var eligibleOwner: Owner?
        var commandTarget: QualifiedSession?
        if let winner {
            seated = (winner.connection, winner.process)
            eligibleOwner = Owner(process: winner.process, page: winner.page, session: winner.state.sessionIdentifier.rawValue)
            commandTarget = QualifiedSession(session: winner.state.sessionIdentifier.rawValue, process: winner.process)
        } else if let fallbackSession, let connection = webProcessConnections[fallbackSession.process] {
            seated = (connection, fallbackSession.process)
            commandTarget = fallbackSession
        }

        // A single connection is the NowPlayingManager client at a time: the elected owner (which also drives the
        // NowPlaying panel and audio session) or, when no session is eligible, a command-only fallback that receives
        // remote commands but shows no panel. Track the seated process and role so an unrelated recompute does not
        // churn a fallback client's remote-command listener.
        let previousSeat = remoteCommandTarget.map { Seat(process: $0.process, role: activeOwner != nil ? .eligibleOwner : .commandOnly) }
        let newSeat = seated.map { Seat(process: $0.process, role: eligibleOwner != nil ? .eligibleOwner : .commandOnly) }

        if let eligibleOwner, let seated {
            // Add the new owner as the client before resigning the previous one so the panel never blanks between
            // owners (NowPlayingManager::removeClient no-ops once m_client has been replaced). This also refreshes the
            // owner's NowPlayingInfo, so it runs even when the seat is unchanged.
            seated.connection.becomeNowPlayingOwner(eligibleOwner.page)
            if let previousSeat, previousSeat.process != seated.process {
                webProcessConnections[previousSeat.process]?.resignNowPlayingManagerClient()
            }
        } else if newSeat != previousSeat {
            // No eligible session. Resign the previous client first so an owner->fallback transition drops the stale
            // panel, then seat the UI process's current session (if any) as a command-only client. Skipped entirely
            // when it is already the command-only client, so its remote-command listener is not destroyed and recreated.
            if let previousSeat {
                webProcessConnections[previousSeat.process]?.resignNowPlayingManagerClient()
            }
            seated?.connection.becomeRemoteCommandFallbackTarget()
        }

        let ownerChanged = eligibleOwner.map { OwnerPage(page: $0.page, process: $0.process) } != activeOwner.map { OwnerPage(page: $0.page, process: $0.process) }
        activeOwner = eligibleOwner
        remoteCommandTarget = commandTarget

        // The UI process owns the per-page "is the NowPlaying session" state, so it hears the election result
        // directly rather than through the content processes, none of which can see the whole picture.
        if ownerChanged {
            WebKit.GPUProcess.nowPlayingOwnerDidChange(eligibleOwner != nil, eligibleOwner?.page ?? 0, eligibleOwner?.process ?? 0)
        }
    }
}

// Mirrors the logic in PlatformMediaSessionManager::bestEligibleSessionForRemoteControls +
// HTMLMediaElement::selectBestMediaSession.
private func isPreferred(_ candidate: IPCTypes.NowPlayingCandidateState, over incumbent: IPCTypes.NowPlayingCandidateState) -> Bool {
    let candidateIsAudioVideo = candidate.presentationType != .webAudio
    let incumbentIsAudioVideo = incumbent.presentationType != .webAudio
    if candidateIsAudioVideo != incumbentIsAudioVideo {
        return candidateIsAudioVideo
    }

    if candidateIsAudioVideo {
        if candidate.isLargeEnoughForMainContent != incumbent.isLargeEnoughForMainContent {
            return candidate.isLargeEnoughForMainContent
        }
        return (candidate.mostRecentUserInteractionTime ?? 0) > (incumbent.mostRecentUserInteractionTime ?? 0)
    }

    return candidate.isPlaying && !incumbent.isPlaying
}

let nowPlayingArbiter = NowPlayingArbiter()

extension WebKit.GPUProcess {
    @cxx
    @implementation
    @MainActor
    func swiftInitializeNowPlayingFallbackSession(_ sessionIdentifier: UInt64, _ processIdentifier: UInt64) {
        nowPlayingArbiter.fallbackSession = NowPlayingArbiter.QualifiedSession(session: sessionIdentifier, process: processIdentifier)
    }

    @MainActor
    func setNowPlayingFallbackSession(connection: IPC.Connection, session: IPCTypes.QualifiedMediaSessionIdentifier?) {
        nowPlayingArbiter.setFallbackSession(session.map { NowPlayingArbiter.QualifiedSession(session: $0.object.rawValue, process: $0.processIdentifier.rawValue) })
    }

    // Sent by the UI process when a page commits a new main-frame load. The page re-enters the election on its next
    // candidate push if it still has an eligible session.
    @MainActor
    func withdrawNowPlayingCandidate(connection: IPC.Connection, page: IPCTypes.QualifiedPageIdentifier) {
        webProcessConnections[page.processIdentifier.rawValue]?.clearNowPlayingCandidates(page: page.object.rawValue)
    }
}

#if ENABLE_MEDIA_STREAM
// What the UI process allowed a web process to capture, which only grows.
struct CaptureAccess {
    var audio = false
    var video = false
    var display = false

    mutating func formUnion(_ other: CaptureAccess) {
        audio = audio || other.audio
        video = video || other.video
        display = display || other.display
    }
}

// The capture environment of the GPU process that outlives its connections: the orientation of the device for capture,
// and the access the UI process gave web processes whose connections the GPU process doesn't have yet.
@MainActor
final class CaptureEnvironment {
    var orientation: Int32 = 0
    private var pendingAccess: [UInt64: (access: CaptureAccess, willUseEchoCancellation: Bool)] = [:]

    fileprivate nonisolated init() {
    }

    fileprivate func addPendingAccess(_ access: CaptureAccess, willUseEchoCancellation: Bool, process: UInt64) {
        var pending = pendingAccess[process] ?? (CaptureAccess(), false)
        pending.access.formUnion(access)
        pending.willUseEchoCancellation = willUseEchoCancellation
        pendingAccess[process] = pending
    }

    func takePendingAccess(process: UInt64) -> (access: CaptureAccess, willUseEchoCancellation: Bool) {
        pendingAccess.removeValue(forKey: process) ?? (CaptureAccess(), false)
    }
}

let captureEnvironment = CaptureEnvironment()

extension WebKit.GPUProcess {
    @MainActor
    func setOrientationForMediaCapture(connection: IPC.Connection, orientation: Int32) {
        captureEnvironment.orientation = orientation
        #if WTF_PLATFORM_COCOA
        state.capturePreview?.setOrientation(orientation)
        for gpuConnection in webProcessConnections.all.values {
            gpuConnection.state.captureManager?.setOrientation(orientation)
        }
        #endif
    }

    @MainActor
    func rotationAngleForCaptureDeviceChanged(connection: IPC.Connection, persistentId: String?, rotation: IPCTypes.VideoFrameRotation) {
        #if WTF_PLATFORM_COCOA
        let persistentID = persistentId ?? ""
        state.capturePreview?.rotationAngleForCaptureDeviceChanged(persistentID, rotation.rawValue)
        for gpuConnection in webProcessConnections.all.values {
            gpuConnection.state.captureManager?.rotationAngleForCaptureDeviceChanged(persistentID, rotation.rawValue)
        }
        #endif
    }

    @MainActor
    func updateCaptureAccess(
        connection: IPC.Connection,
        allowAudioCapture: Bool,
        allowVideoCapture: Bool,
        allowDisplayCapture: Bool,
        willUseEchoCancellation: Bool,
        processID: IPCTypes.ProcessIdentifier
    ) {
        WebKit.LogChannel.WebRTC().releaseLog.log(
            "GPUProcess::updateCaptureAccess: Entering (audio=\(allowAudioCapture ? 1 : 0), video=\(allowVideoCapture ? 1 : 0), display=\(allowDisplayCapture ? 1 : 0), echoCancellation=\(willUseEchoCancellation ? 1 : 0))"
        )
        #if WTF_PLATFORM_COCOA
        ensureAVCaptureServerConnection()
        #endif
        let access = CaptureAccess(audio: allowAudioCapture, video: allowVideoCapture, display: allowDisplayCapture)
        if let gpuConnection = webProcessConnections[processID.rawValue] {
            gpuConnection.state.allowCapture(access, willUseEchoCancellation: willUseEchoCancellation)
            return
        }
        captureEnvironment.addPendingAccess(access, willUseEchoCancellation: willUseEchoCancellation, process: processID.rawValue)
    }
}
#endif

// We wouldn't want the GPUProcess to repeatedly exit then relaunch when under memory pressure. In particular, we need to make sure the
// WebProcess has a change to schedule work after the GPUProcess get launched. For this reason, we make sure that the GPUProcess never
// idle-exits less than 5 seconds after getting launched. This amount of time should be sufficient for the WebProcess to schedule work
// work in the GPUProcess.
private let minimumLifetimeBeforeIdleExit: Duration = .seconds(5)

extension WebKit.GPUProcess {
    @cxx
    @implementation
    @MainActor
    func canExitUnderMemoryPressure() -> Bool {
        MainActor.preconditionIsolated()
        #if ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
        if state.capturePreview != nil {
            return false
        }
        #endif
        return webProcessConnections.all.values.allSatisfy {
            $0.state.allowsExitUnderMemoryPressure && $0.allowsExitUnderMemoryPressure()
        }
    }

    @cxx
    @implementation
    @MainActor
    func tryExitIfUnusedAndUnderMemoryPressure() {
        MainActor.assertIsolated()
        if Self.isUnderMemoryPressure() {
            tryExitIfUnused()
        }
    }

    @cxx
    @implementation
    @MainActor
    func tryExitIfUnused() {
        MainActor.preconditionIsolated()
        let state = state
        guard canExitUnderMemoryPressure() else {
            state.idleExitCheck?.cancel()
            state.idleExitCheck = nil
            return
        }

        // To avoid exiting the GPUProcess too aggressively while under memory pressure and make sure the WebProcess gets a
        // change to schedule work, we don't exit if we've been running for less than |minimumLifetimeBeforeIdleExit|.
        // In case of simulated memory pressure, we ignore this rule to avoid flakiness in our benchmarks and tests.
        let lifetime = state.creationTime.duration(to: .now)
        if lifetime < minimumLifetimeBeforeIdleExit && !Self.isSimulatingMemoryPressure() {
            WebKit.LogChannel.Process().releaseLog.log("GPUProcess::tryExitIfUnused: GPUProcess is idle and under memory pressure but it is not exiting because it has just launched")
            // Check again after the process have lived long enough (minimumLifetimeBeforeIdleExit) to see if the GPUProcess
            // can idle-exit then.
            if state.idleExitCheck == nil {
                state.idleExitCheck = Task { @MainActor [self] in
                    try? await Task.sleep(for: minimumLifetimeBeforeIdleExit - lifetime, clock: .suspending)
                    guard !Task.isCancelled else {
                        return
                    }
                    self.state.idleExitCheck = nil
                    self.tryExitIfUnused()
                }
            }
            return
        }
        state.idleExitCheck?.cancel()
        state.idleExitCheck = nil

        WebKit.LogChannel.Process().releaseLog.log("GPUProcess::tryExitIfUnused: GPUProcess is exiting because we are under memory pressure and the process is no longer useful.")
        sendProcessIsReadyToExit()
    }

    @cxx
    @implementation
    @MainActor
    func lowMemoryHandler(_ critical: WTF.Critical, _ synchronous: WTF.Synchronous) {
        WebKit.LogChannel.Process().releaseLog.log("GPUProcess::lowMemoryHandler: critical=\(critical == .Yes ? 1 : 0), synchronous=\(synchronous == .Yes ? 1 : 0)")
        tryExitIfUnused()

        for connection in webProcessConnections.all.values {
            connection.lowMemoryHandler(critical, synchronous)
        }

        Self.releaseMemory(critical, synchronous)
    }
}

#endif // ENABLE_GPU_PROCESS
