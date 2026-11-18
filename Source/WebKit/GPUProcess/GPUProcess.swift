// Copyright (C) 2019-2025 Apple Inc. All rights reserved.
// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
// Copyright (C) 2019-2023 Apple Inc. All rights reserved.
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
#if ENABLE_GPU_PROCESS_CORE_SWIFT
import Darwin
import Foundation
import QuartzCore
import Synchronization
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

#if ENABLE_GPU_PROCESS_CORE_SWIFT
    var preferences = Preferences()
    var haveEnabledVP9Decoder = false
    var haveEnabledSWVP9Decoder = false
    // The media directories of each session, by PAL::SessionID.
    var sessions: [UInt64: (mediaCacheDirectory: WTF.String, mediaKeysStorageDirectory: WTF.String)] = [:]
#if ENABLE_MEDIA_STREAM
    // The page whose getUserMedia prompt shows the capture preview, the layer its camera shows in, while it does, and
    // the camera whose rotation the UI process monitors for it, with its page.
    var capturePreviewPage: WebCore.PageIdentifier?
    var capturePreviewLayer: WebKit.SampleBufferDisplayLayerHost?
    var capturePreviewVideoDeviceID = ""
    var capturePreviewVideoPage: WebCore.PageIdentifier?
    var lastCaptureEnvironment: (process: WebCore.ProcessIdentifier, page: WebCore.PageIdentifier)?
#endif
#endif

    fileprivate nonisolated init() {
    }
}

#if ENABLE_GPU_PROCESS_CORE_SWIFT
// GPUProcessPreferences, as the process last applied them.
struct Preferences {
    var mediaResourceLoadTimeoutForTesting: UInt32?
    var vp9DecoderEnabled: Bool?
    var swVPDecodersAlwaysEnabled = false
}
#endif

extension WebKit.GPUProcess {
    @cxx
    @implementation
    func createSwiftState() -> UInt {
        #if ENABLE_GPU_PROCESS_CORE_SWIFT
        WebKit.LogChannel.Process().releaseLog.log("GPUProcess::GPUProcess:")
        #endif
        return UInt(bitPattern: unsafe Unmanaged.passRetained(GPUProcessState()).toOpaque())
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
            #if ENABLE_GPU_PROCESS_CORE_SWIFT
            WebKit.GPUProcess.sendToUIProcess { connection in
                WebKit.GPUProcess.GPUProcessProxyMessages.nowPlayingOwnerDidChange(
                    on: connection,
                    to: 0,
                    ownerPage: eligibleOwner.flatMap { owner in
                        IPCTypes.PageIdentifier(rawValue: owner.page).flatMap { page in
                            IPCTypes.ProcessIdentifier(rawValue: owner.process).map { IPCTypes.QualifiedPageIdentifier(object: page, processIdentifier: $0) }
                        }
                    }
                )
            }
            #else
            WebKit.GPUProcess.nowPlayingOwnerDidChange(eligibleOwner != nil, eligibleOwner?.page ?? 0, eligibleOwner?.process ?? 0)
            #endif
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
        if Self.underMemoryPressure {
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
        if lifetime < minimumLifetimeBeforeIdleExit && !Self.simulatingMemoryPressure {
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
        #if ENABLE_GPU_PROCESS_CORE_SWIFT
        Self.sendToUIProcess { WebKit.GPUProcess.GPUProcessProxyMessages.processIsReadyToExit(on: $0, to: 0) }
        #else
        sendProcessIsReadyToExit()
        #endif
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

        #if ENABLE_GPU_PROCESS_CORE_SWIFT
        WebCore.releaseGraphicsMemory(critical, synchronous)
        if critical == .Yes {
            WebCore.IOSurface.releaseCGIOSurfaceContextResources()
        }
        #else
        Self.releaseMemory(critical, synchronous)
        #endif
    }

    private static var underMemoryPressure: Bool {
        #if ENABLE_GPU_PROCESS_CORE_SWIFT
        WTF.MemoryPressureHandler.singleton().isUnderMemoryPressure()
        #else
        isUnderMemoryPressure()
        #endif
    }

    private static var simulatingMemoryPressure: Bool {
        #if ENABLE_GPU_PROCESS_CORE_SWIFT
        WTF.MemoryPressureHandler.singleton().isSimulatingMemoryPressure()
        #else
        isSimulatingMemoryPressure()
        #endif
    }
}


#if ENABLE_GPU_PROCESS_CORE_SWIFT
// The process's own messages and lifecycle (GPUProcess.h); C++ keeps only what Swift can't take.
extension WebKit.GPUProcess {
    // Overwrites a variable of the process's environment.
    private func setEnvironmentVariable(_ name: StaticString, _ value: StaticString) {
        // Safety: a StaticString's storage is a NUL-terminated literal that lives for the whole process.
        unsafe setenv(name.utf8Start, value.utf8Start, 1)
    }

    // Sends a message to the UI process, if the process still has its connection.
    static func sendToUIProcess(_ send: (IPC.Connection) -> Void) {
        if let connection = singleton().uiProcessConnection() {
            send(connection)
        }
    }

    // Unsafe: C++ lends the parameters for the call, which only reads values from them.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func swiftInitializeGPUProcess(_ parameters: borrowing WebKit.GPUProcessCreationParameters) {
        WebKit.LogChannel.Process().releaseLog.log("GPUProcess::initializeGPUProcess:")
        WTF.Thread.setCurrentThreadIsUserInitiated(0)
        WebCore.initializeCommonAtomStrings()
        #if WTF_PLATFORM_IOS_FAMILY || ENABLE_ROUTING_ARBITRATION
        WebCore.DeprecatedGlobalSettings.setShouldManageAudioSessionCategory(true)
        #endif
        #if ENABLE_MEDIA_STREAM
        WebCore.MockRealtimeMediaSourceCenter.setMockRealtimeMediaSourceCenterEnabled(parameters.useMockCaptureDevices)
        #endif
        // Match the QoS of the UIProcess since the GPU process is doing rendering on its behalf.
        WTF.Thread.setCurrentThreadIsUserInteractive(0)
        if !parameters.overrideLanguages.isEmpty() {
            WTF.overrideUserPreferredLanguages(parameters.overrideLanguages)
        }
        if parameters.enableMetalDebugDeviceForTesting {
            WebKit.LogChannel.Process().releaseLog.log("GPUProcess::platformInitializeGPUProcess: enabling Metal debug device")
            setEnvironmentVariable("MTL_DEBUG_LAYER", "1")
        }
        if parameters.enableMetalShaderValidationForTesting {
            WebKit.LogChannel.Process().releaseLog.log("GPUProcess::platformInitializeGPUProcess: enabling Metal shader validation")
            setEnvironmentVariable("MTL_SHADER_VALIDATION", "1")
            setEnvironmentVariable("MTL_SHADER_VALIDATION_ABORT_ON_FAULT", "1")
            setEnvironmentVariable("MTL_SHADER_VALIDATION_REPORT_TO_STDERR", "1")
            setEnvironmentVariable("MTL_SHADER_VALIDATION_GPUOPT_ENABLE_RUNTIME_STACKTRACE", "0")
        }
        #if ENABLE_VP9
        if let available = Optional(fromCxx: parameters.hasVP9HardwareDecoder) {
            WebCore.setVP9HardwareDecoderAvailableInProcess(available)
        }
        #endif
        #if ENABLE_AV1
        if let available = Optional(fromCxx: parameters.hasAV1HardwareDecoder) {
            WebCore.setAV1HardwareDecoderAvailable(available)
        }
        #endif
    }

    @cxx
    @implementation
    @MainActor
    func didAddWebProcessConnection(_ connection: WebKit.GPUConnectionToWebProcess) {
        connection.swiftDidAddToGPUProcess()
    }

    @cxx
    @implementation
    @MainActor
    func didRemoveWebProcessConnection(_ connection: WebKit.GPUConnectionToWebProcess) {
        let process = connection.webProcessIdentifier()
        WebKit.LogChannel.Process().releaseLog.log("GPUProcess::removeGPUConnectionToWebProcess: processIdentifier=\(process.toUInt64())")
        transferredImageBuffers.removeAll(ownedBy: process.toUInt64())
        Self.swiftAbandonSnapshotFramesOwnedBy(process)
        Self.swiftRemoveSnapshotsForProcess(process)
        connection.swiftDidRemoveFromGPUProcess()
        tryExitIfUnusedAndUnderMemoryPressure()
    }

    @cxx
    @implementation
    @MainActor
    func sharedPreferencesForWebProcessDidChange(
        _ identifier: WebCore.ProcessIdentifier,
        _ sharedPreferences: WebKit.SharedPreferencesForWebProcess,
        _ completionHandler: WebKit.GPUProcessVoidReply
    ) {
        webProcessConnections[identifier.toUInt64()]?.updateSharedPreferencesForWebProcess(sharedPreferences)
        completionHandler.pointee()
    }

    @cxx
    @implementation
    @MainActor
    func updateGPUProcessPreferences(_ preferences: WebKit.GPUProcessPreferences) {
        let state = state
        let timeout = Optional(fromCxx: preferences.mediaResourceLoadTimeoutForTesting)
        if timeout != state.preferences.mediaResourceLoadTimeoutForTesting {
            state.preferences.mediaResourceLoadTimeoutForTesting = timeout
            WebCore.DeprecatedGlobalSettings.setMediaResourceLoadTimeoutForTesting(timeout ?? 0)
        }
        #if ENABLE_VP9
        if updatePreference(&state.preferences.vp9DecoderEnabled, Optional(fromCxx: preferences.vp9DecoderEnabled)) {
            let enabled = state.preferences.vp9DecoderEnabled ?? false
            WebCore.VP9TestingOverrides.singleton().setShouldEnableVP9Decoder(enabled)
            if !state.haveEnabledVP9Decoder && enabled {
                state.haveEnabledVP9Decoder = true
                WebCore.registerSupplementalVP9Decoder()
            }
        }
        if preferences.swVPDecodersAlwaysEnabled != state.preferences.swVPDecodersAlwaysEnabled {
            state.preferences.swVPDecodersAlwaysEnabled = preferences.swVPDecodersAlwaysEnabled
            WebCore.VP9TestingOverrides.singleton().setSWVPDecodersAlwaysEnabled(preferences.swVPDecodersAlwaysEnabled)
        }
        if !state.haveEnabledSWVP9Decoder && WebCore.shouldEnableSWVP9Decoder() {
            WebCore.registerWebKitVP9Decoder()
            state.haveEnabledSWVP9Decoder = true
        }
        #endif
    }

    // Takes a preference the UI process sent, which leaves the current one if it sent none, and makes an unset one
    // false. Whether that changed it.
    private func updatePreference(_ preference: inout Bool?, _ newPreference: Bool?) -> Bool {
        if let newPreference, preference != newPreference {
            preference = newPreference
            return true
        }
        if preference == nil {
            preference = false
            return true
        }
        return false
    }

    @cxx
    @implementation
    @MainActor
    func prepareToSuspend(_ isSuspensionImminent: Bool, _ estimatedSuspendTime: WTF.MonotonicTime, _ completionHandler: WebKit.GPUProcessVoidReply) {
        WebKit.LogChannel.ProcessSuspension().releaseLog.log("GPUProcess::prepareToSuspend(), isSuspensionImminent: \(isSuspensionImminent ? 1 : 0)")
        lowMemoryHandler(.Yes, .Yes)
        completionHandler.pointee()
    }

    @cxx
    @implementation
    @MainActor
    func processDidResume() {
        WebKit.LogChannel.ProcessSuspension().releaseLog.log("GPUProcess::processDidResume()")
    }

    @cxx
    @implementation
    @MainActor
    func swiftAddSession(_ sessionID: PAL.SessionID, _ mediaCacheDirectory: WTF.String, _ mediaKeysStorageDirectory: WTF.String) {
        // As HashMap::add(), the first session with an identifier stays.
        assert(state.sessions[sessionID.toUInt64()] == nil)
        if state.sessions[sessionID.toUInt64()] == nil {
            state.sessions[sessionID.toUInt64()] = (mediaCacheDirectory, mediaKeysStorageDirectory)
        }
    }

    @cxx
    @implementation
    @MainActor
    func removeSession(_ sessionID: PAL.SessionID) {
        guard state.sessions.removeValue(forKey: sessionID.toUInt64()) != nil else {
            assertionFailure("Invalid SessionID")
            return
        }
    }

    @cxx
    @implementation
    @MainActor
    func mediaCacheDirectory(_ sessionID: PAL.SessionID) -> WTF.String {
        guard let session = state.sessions[sessionID.toUInt64()] else {
            assertionFailure("Invalid SessionID")
            return WTF.String()
        }
        return session.mediaCacheDirectory
    }

    #if ENABLE_LEGACY_ENCRYPTED_MEDIA || ENABLE_ENCRYPTED_MEDIA
    @cxx
    @implementation
    @MainActor
    func mediaKeysStorageDirectory(_ sessionID: PAL.SessionID) -> WTF.String {
        guard let session = state.sessions[sessionID.toUInt64()] else {
            assertionFailure("Invalid SessionID")
            return WTF.String()
        }
        return session.mediaKeysStorageDirectory
    }
    #endif

    @cxx
    @implementation
    func createSnapshot(
        _ identifier: WebKit.RemoteSnapshotIdentifier,
        _ rootFrameIdentifier: WebCore.FrameIdentifier,
        _ size: WebCore.FloatSize,
        _ rootProcessIdentifier: WebCore.ProcessIdentifier
    ) {
        Self.swiftCreateSnapshot(WebKit.snapshotKey(identifier), rootFrameIdentifier, size, rootProcessIdentifier)
    }

    @cxx
    @implementation
    func failSnapshot(_ identifier: WebKit.RemoteSnapshotIdentifier) {
        Self.swiftFailSnapshot(WebKit.snapshotKey(identifier))
    }

    @cxx
    @implementation
    func abandonSnapshotFrame(_ identifier: WebKit.RemoteSnapshotIdentifier, _ frameIdentifier: WebCore.FrameIdentifier) {
        Self.swiftAbandonSnapshotFrame(WebKit.snapshotKey(identifier), frameIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func releaseSnapshot(_ identifier: WebKit.RemoteSnapshotIdentifier) {
        Self.swiftReleaseSnapshot(WebKit.snapshotKey(identifier))
    }

    @cxx
    @implementation
    @MainActor
    func snapshotFrameWillBeDrawnByProcess(
        _ identifier: WebKit.RemoteSnapshotIdentifier,
        _ frameIdentifier: WebCore.FrameIdentifier,
        _ processIdentifier: WebCore.ProcessIdentifier
    ) {
        Self.swiftSnapshotFrameWillBeDrawnByProcess(WebKit.snapshotKey(identifier), frameIdentifier, processIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func abandonSnapshotFramesOwnedBy(_ processIdentifier: WebCore.ProcessIdentifier) {
        Self.swiftAbandonSnapshotFramesOwnedBy(processIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func webProcessConnectionCountForTesting(_ completionHandler: WebKit.GPUProcessCountReply) {
        completionHandler.pointee(WebKit.GPUConnectionToWebProcess.objectCountForTesting())
    }

    @cxx
    @implementation
    @MainActor
    func printProcessDrawingCountsForTesting(_ completionHandler: WebKit.GPUProcessDrawingCountsReply) {
        completionHandler.pointee(
            WebKit.RemoteSnapshotPDFDrawingTask.drawnInPrintProcessCountForTesting(),
            WebKit.RemoteSnapshotPDFDrawingTask.drawnAfterPrintProcessFailedCountForTesting()
        )
    }

    #if HAVE_AUDIT_TOKEN
    @cxx
    @implementation
    @MainActor
    func setPresentingApplicationAuditToken(
        _ processIdentifier: WebCore.ProcessIdentifier,
        _ pageIdentifier: WebCore.PageIdentifier,
        _ auditToken: WebKit.OptionalCoreIPCAuditToken
    ) {
        webProcessConnections[processIdentifier.toUInt64()]?.setPresentingApplicationAuditToken(pageIdentifier, auditToken)
    }
    #endif

    @cxx
    @implementation
    @MainActor
    func postWillTakeSnapshotNotification(_ completionHandler: WebKit.GPUProcessVoidReply) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NotificationCenter.default.post(name: Notification.Name("CoreMediaPleaseHideTheDRMFallbackForAWhile"), object: nil)
        CATransaction.commit()
        completionHandler.pointee()
    }

    @cxx
    @implementation
    func depositTransferredImageBuffer(_ owner: WebCore.ProcessIdentifier, _ imageBuffer: WebCore.ImageBuffer) -> WTF.UUID {
        transferredImageBuffers.deposit(imageBuffer, owner: owner.toUInt64())
    }

    @cxx
    @implementation
    func takeTransferredImageBuffer(_ identifier: WTF.UUID) -> WebKit.RefPtrTransferredImageBuffer {
        WebKit.RefPtrTransferredImageBuffer(transferredImageBuffers.take(TransferredImageBufferKey(identifier)))
    }

    @cxx
    @implementation
    func releaseTransferredImageBuffer(_ identifier: WTF.UUID) {
        transferredImageBuffers.release(TransferredImageBufferKey(identifier))
    }

    @cxx
    @implementation
    func handOverTransferredImageBuffer(_ identifier: WTF.UUID, _ destinationProcess: WebCore.ProcessIdentifier) {
        transferredImageBuffers.handOver(TransferredImageBufferKey(identifier), to: destinationProcess.toUInt64())
    }
}

// A transferred image buffer's identifier, an unguessable UUID that the GPU process minted.
struct TransferredImageBufferKey: Hashable {
    let high: UInt64
    let low: UInt64

    init(_ identifier: WTF.UUID) {
        high = identifier.high()
        low = identifier.low()
    }
}

// The image buffers deposited for another web process to claim (GPUProcess::depositTransferredImageBuffer()), which the
// rendering backends reach from their work queues. FIXME: This is a sign that we lack local id exchange protocol. The
// outcome is that the protocols are insecure and prone to id guessing and content stuffing. Do not add more globally
// shared resources.
final class TransferredImageBuffers: Sendable {
    // Unchecked: an ImageBuffer's reference count is thread-safe, and a buffer here is only drawn by the one process that
    // claims it, on its rendering backend's queue, as when C++ kept them.
    private struct Entry: @unchecked Sendable {
        var owner: UInt64
        let imageBuffer: WebCore.ImageBuffer
    }

    private let entries = Mutex<[TransferredImageBufferKey: Entry]>([:])

    fileprivate init() {
    }

    func deposit(_ imageBuffer: WebCore.ImageBuffer, owner: UInt64) -> WTF.UUID {
        let identifier = WTF.UUID.createVersion4()
        let entry = Entry(owner: owner, imageBuffer: imageBuffer)
        entries.withLock { entries in
            let key = TransferredImageBufferKey(identifier)
            precondition(entries[key] == nil)
            entries[key] = entry
        }
        return identifier
    }

    func take(_ key: TransferredImageBufferKey) -> WebCore.ImageBuffer? {
        let entry = entries.withLock { $0.removeValue(forKey: key) }
        return entry?.imageBuffer
    }

    func release(_ key: TransferredImageBufferKey) {
        // Released outside the lock, as the last reference to the buffer may be this.
        let released = entries.withLock { $0.removeValue(forKey: key) }
        _ = consume released
    }

    // Not waited for, so the destination may already have claimed it.
    func handOver(_ key: TransferredImageBufferKey, to destination: UInt64) {
        entries.withLock { $0[key]?.owner = destination }
    }

    // Keyed on the owner: once ownership has moved on, the depositing process going away must not take the buffer from
    // the process it was handed to.
    func removeAll(ownedBy owner: UInt64) {
        let released = entries.withLock { entries in
            let owned = entries.filter { $0.value.owner == owner }
            entries = entries.filter { $0.value.owner != owner }
            return owned
        }
        _ = consume released
    }
}

let transferredImageBuffers = TransferredImageBuffers()

#if !HAVE_SYSTEM_STATUS && ENABLE_MEDIA_STREAM
extension WebKit.GPUProcess {
    @cxx
    @implementation
    func setCaptureAttributionString(_ origin: WebCore.SecurityOriginData) -> Bool {
        true
    }
}
#endif
#endif // ENABLE_GPU_PROCESS_CORE_SWIFT


#if ENABLE_GPU_PROCESS_CORE_SWIFT && ENABLE_MEDIA_STREAM
// Capture: the mock devices, the capture origin and environment, and the capture preview of a getUserMedia prompt.
extension WebKit.GPUProcess {
    @cxx
    @implementation
    @MainActor
    func setMockCaptureDevicesEnabled(_ isEnabled: Bool) {
        WebCore.MockRealtimeMediaSourceCenter.setMockRealtimeMediaSourceCenterEnabled(isEnabled)
    }

    @cxx
    @implementation
    @MainActor
    func addMockMediaDevice(_ device: WebCore.MockMediaDevice) {
        WebCore.MockRealtimeMediaSourceCenter.addDevice(device)
    }

    @cxx
    @implementation
    @MainActor
    func removeMockMediaDevice(_ persistentId: WTF.String) {
        WebCore.MockRealtimeMediaSourceCenter.removeDevice(persistentId)
    }

    @cxx
    @implementation
    @MainActor
    func setMockMediaDeviceIsEphemeral(_ persistentId: WTF.String, _ isEphemeral: Bool) {
        WebCore.MockRealtimeMediaSourceCenter.setDeviceIsEphemeral(persistentId, isEphemeral)
    }

    @cxx
    @implementation
    @MainActor
    func resetMockMediaDevices() {
        WebCore.MockRealtimeMediaSourceCenter.resetDevices()
    }

    @cxx
    @implementation
    @MainActor
    func setMockCaptureDevicesInterrupted(_ isCameraInterrupted: Bool, _ isMicrophoneInterrupted: Bool) {
        WebCore.MockRealtimeMediaSourceCenter.setMockCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted)
    }

    @cxx
    @implementation
    @MainActor
    func updateCaptureOrigin(_ origin: WebCore.SecurityOriginData, _ processIdentifier: WebCore.ProcessIdentifier) {
        webProcessConnections[processIdentifier.toUInt64()]?.updateCaptureOrigin(origin)
    }

    @cxx
    @implementation
    @MainActor
    func didApplyCaptureEnvironment(_ processIdentifier: WebCore.ProcessIdentifier, _ pageIdentifier: WebCore.PageIdentifier) {
        state.lastCaptureEnvironment = (processIdentifier, pageIdentifier)
    }

    @cxx
    @implementation
    @MainActor
    func processIsStartingToCaptureAudio(_ process: WebKit.GPUConnectionToWebProcess) {
        for connection in webProcessConnections.all.values {
            connection.processIsStartingToCaptureAudio(process)
        }
    }

    // FIXME: The manager is per process while requests are per page, so for now fail a second page's prompt while another
    // is up until we figure out a better solution.
    @cxx
    @implementation
    @MainActor
    func swiftCanStartCapturePreview(_ pageIdentifier: WebCore.PageIdentifier) -> Bool {
        if let page = state.capturePreviewPage, page.toUInt64() != pageIdentifier.toUInt64() {
            WebKit.LogChannel.WebRTC().releaseLog.error("GPUProcess::startCapturePreview: a preview is already running for another page")
            return false
        }
        state.capturePreviewPage = pageIdentifier
        return true
    }

    // After C++ has consumed the preview's sandbox extensions.
    @cxx
    @implementation
    @MainActor
    func swiftPrepareCapturePreview(
        _ pageIdentifier: WebCore.PageIdentifier,
        _ hasCamera: Bool,
        _ applicationBundleIdentifier: WTF.String,
        _ origin: WebCore.SecurityOriginData
    ) -> Bool {
        ensureAVCaptureServerConnection()

        #if ENABLE_APP_PRIVACY_REPORT && !WTF_PLATFORM_MACCATALYST
        // Fail immediately if we don't have a capture identity as -[AVCaptureSession init] will throw.
        if !hasCaptureIdentity(applicationBundleIdentifier) && hasCamera {
            WebKit.LogChannel.WebRTC().releaseLog.error("GPUProcess::startCapturePreview: no capture identity, refusing to preview")
            stopCapturePreviewManager()
            return false
        }
        #endif

        guard setUpCapturePreviewEnvironment(pageIdentifier, origin, hasCamera: hasCamera) else {
            stopCapturePreviewManager()
            return false
        }
        return true
    }

    // With the layer C++ made for the camera, if there is one.
    @cxx
    @implementation
    @MainActor
    func swiftStartCapturePreviewForPage(
        _ pageIdentifier: WebCore.PageIdentifier,
        _ layer: WebKit.SampleBufferDisplayLayerHost?,
        _ videoDeviceID: WTF.String,
        _ videoDeviceLabel: WTF.String,
        _ videoDeviceIsDefault: Bool,
        _ audioDeviceID: WTF.String,
        _ audioDeviceLabel: WTF.String,
        _ audioDeviceIsDefault: Bool,
        _ previewSize: WebCore.IntSize,
        _ orientation: Int32
    ) -> WebCore.HostingContext {
        let state = state
        let result = CapturePreviewStart(rawValue: swiftStartCapturePreview(
            pageIdentifier.toUInt64(),
            videoDeviceID,
            videoDeviceLabel,
            videoDeviceIsDefault,
            audioDeviceID,
            audioDeviceLabel,
            audioDeviceIsDefault,
            previewSize.width(),
            previewSize.height(),
            orientation,
            layer
        ))
        if result == CapturePreviewStart.started {
            state.capturePreviewLayer = layer
        } else if result != CapturePreviewStart.unchanged {
            state.capturePreviewLayer = nil
        }
        if !swiftHasCapturePreview() {
            state.capturePreviewLayer = nil
        }
        if result != CapturePreviewStart.unchanged {
            setCapturePreviewVideoDevice(state.capturePreviewLayer != nil ? videoDeviceID : WTF.String(), pageIdentifier)
        }
        return state.capturePreviewLayer?.hostingContext() ?? WebCore.HostingContext()
    }

    @MainActor
    private func setUpCapturePreviewEnvironment(_ pageIdentifier: WebCore.PageIdentifier, _ origin: WebCore.SecurityOriginData, hasCamera: Bool) -> Bool {
        guard setCaptureAttributionString(origin) else {
            WebKit.LogChannel.WebRTC().releaseLog.error("GPUProcess::startCapturePreview: unable to set capture attribution, refusing to preview")
            return false
        }
        #if WTF_PLATFORM_IOS_FAMILY
        return platformSetUpCapturePreviewEnvironment(pageIdentifier, hasCamera)
        #else
        return true
        #endif
    }

    @cxx
    @implementation
    @MainActor
    func stopCapturePreview(_ pageIdentifier: WebCore.PageIdentifier, _ completionHandler: WebKit.GPUProcessVoidReply) {
        let state = state
        if let page = state.capturePreviewPage, page.toUInt64() != pageIdentifier.toUInt64() {
            completionHandler.pointee()
            return
        }
        state.capturePreviewPage = nil
        stopCapturePreviewManager()
        if let (process, page) = state.lastCaptureEnvironment {
            webProcessConnections[process.toUInt64()]?.reapplyCaptureEnvironment(page)
        }
        revokeCapturePreviewSandboxExtensions()
        completionHandler.pointee()
    }

    @MainActor
    private func stopCapturePreviewManager() {
        swiftStopCapturePreview()
        state.capturePreviewLayer = nil
        setCapturePreviewVideoDevice(WTF.String(), nil)
    }

    // The camera whose rotation the UI process monitors for the preview, and its page.
    @MainActor
    private func setCapturePreviewVideoDevice(_ persistentID: WTF.String, _ pageIdentifier: WebCore.PageIdentifier?) {
        let state = state
        let connection = uiProcessConnection()
        if let connection, !state.capturePreviewVideoDeviceID.isEmpty, let page = state.capturePreviewVideoPage.flatMap({ IPCTypes.PageIdentifier(rawValue: $0.toUInt64()) }) {
            WebKit.GPUProcess.GPUProcessProxyMessages.stopMonitoringCaptureDeviceRotation(on: connection, to: 0, pageID: page, devicePersistentId: state.capturePreviewVideoDeviceID, reason: .capturePreview)
        }
        state.capturePreviewVideoDeviceID = pageIdentifier != nil ? IPCCoding.WTFString.swiftString(persistentID) ?? "" : ""
        state.capturePreviewVideoPage = pageIdentifier
        if let connection, !state.capturePreviewVideoDeviceID.isEmpty, let page = pageIdentifier.flatMap({ IPCTypes.PageIdentifier(rawValue: $0.toUInt64()) }) {
            WebKit.GPUProcess.GPUProcessProxyMessages.startMonitoringCaptureDeviceRotation(on: connection, to: 0, pageID: page, devicePersistentId: state.capturePreviewVideoDeviceID, reason: .capturePreview)
        }
    }

    @cxx
    @implementation
    static func capturePreviewNeedsAudioSession() -> Bool {
        #if (WTF_PLATFORM_IOS_FAMILY || ENABLE_ROUTING_ARBITRATION) && USE_AUDIO_SESSION
        true
        #else
        false
        #endif
    }

    @cxx
    @implementation
    @MainActor
    static func capturePreviewAudioLevelChanged(_ pageIdentifier: UInt64, _ level: Float) {
        guard let page = IPCTypes.PageIdentifier(rawValue: pageIdentifier) else {
            return
        }
        sendToUIProcess { WebKit.GPUProcess.GPUProcessProxyMessages.capturePreviewAudioLevelChanged(on: $0, to: 0, pageIdentifier: page, level: level) }
    }
}
#endif // ENABLE_GPU_PROCESS_CORE_SWIFT && ENABLE_MEDIA_STREAM

#endif // ENABLE_GPU_PROCESS
