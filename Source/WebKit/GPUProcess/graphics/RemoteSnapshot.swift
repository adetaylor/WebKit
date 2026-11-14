// Copyright (C) 2019-2025 Apple Inc. All rights reserved.
// Copyright (C) 2025 Apple Inc. All rights reserved.
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

import Synchronization
import WebCore_Private
import WebKit_Internal

// A snapshot's identifier (RemoteSnapshotIdentifier), as the registry keys snapshots by.
struct RemoteSnapshotRegistryKey: Hashable, Sendable {
    let high: UInt64
    let low: UInt64
    let process: UInt64

    init(_ key: WebKit.RemoteSnapshotKey) {
        high = key.high
        low = key.low
        process = key.process
    }

    var cxxKey: WebKit.RemoteSnapshotKey {
        var key = WebKit.RemoteSnapshotKey()
        key.high = high
        key.low = low
        key.process = process
        return key
    }
}

// Long enough for any frame whose process is responsive. One whose process is not, or went away before connecting here, draws
// nothing rather than holding up whoever is waiting for the snapshot.
private let snapshotDeadline: Duration = .seconds(10)

private struct RemoteSnapshotFrame {
    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    var recording: RemoteSnapshotFrameRecording?
    var isRecorded: Bool { recording != nil }
    #else
    // The display list is the C++'s (GPUProcess::snapshotDisplayLists()).
    var isRecorded = false
    #endif
    var isAbandoned = false

    var isResolved: Bool { isRecorded || isAbandoned }
}

// What waits for a snapshot to complete, with the sink's Swift state if it takes the snapshot. @unchecked Sendable: the sink
// is thread-safe reference counted, and is only completed once, under the snapshot's lock.
private struct RemoteSnapshotWaiter: @unchecked Sendable {
    let sink: WebKit.RemoteSnapshotSink
    let sinkState: RemoteSnapshotSinkState?
}

private struct RemoteSnapshotState {
    var width: Float = 0
    var height: Float = 0
    // A frame is added unresolved when it is referenced, and resolved when its recording comes in or it is abandoned. A frame
    // can also come in before it is referenced.
    var frames: [UInt64: RemoteSnapshotFrame] = [:]
    var frameOwners: [UInt64: UInt64] = [:]
    var unresolvedFrames = 0
    var hasFailed = false
    var waiters: [RemoteSnapshotWaiter] = []

    var isComplete: Bool { hasFailed || unresolvedFrames == 0 }
}

// RemoteSnapshot represents a web page rendering. Solves the problem of generating the rendering from various different
// WebContent processes that should not have any access to data of each other. Each frame's recording draws its subframes'
// recordings by their frames (DrawSnapshotFrame), which the snapshot references once they are recorded. The snapshot is
// complete once every referenced frame has been resolved, either with a recording or by the frame being abandoned, in which
// case it draws nothing. The root is unresolved from the start, and a frame's references are recorded before its own recording
// is sunk, so nothing left unresolved means nothing is still to come. The rendering backends' work queues record frames into
// it, and the main thread completes and draws it.
final class RemoteSnapshot: Sendable {
    let key: RemoteSnapshotRegistryKey
    // Nil for a recorder whose snapshot no longer exists, which records into nothing.
    let rootFrame: UInt64?
    // On the ports that record frames as WebCore display lists, the token of the C++ display lists that its recorders record
    // into (GPUProcess::createSnapshotDisplayLists()), and 0 otherwise.
    let displayListsToken: UInt64
    private let state: Mutex<RemoteSnapshotState>

    init(key: RemoteSnapshotRegistryKey, rootFrame: UInt64?, displayListsToken: UInt64 = 0) {
        self.key = key
        self.rootFrame = rootFrame
        self.displayListsToken = displayListsToken
        var state = RemoteSnapshotState()
        if let rootFrame {
            state.frames[rootFrame] = RemoteSnapshotFrame()
            state.unresolvedFrames = 1
        }
        self.state = Mutex(state)
    }

    // The size the root was recorded at, which is what the snapshot is drawn at.
    func setSize(width: Float, height: Float) {
        state.withLock { state in
            state.width = width
            state.height = height
        }
    }

    func addFrameReference(_ frame: UInt64) {
        state.withLock { state in
            // A frame painted more than once is referenced more than once, and is still only recorded once. It is ok for
            // setFrame or abandonFrame to win the race.
            if state.frames.index(forKey: frame) == nil {
                state.frames[frame] = RemoteSnapshotFrame()
                state.unresolvedFrames += 1
            }
        }
    }

    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    // A frame recorded in Swift (RemoteRenderingBackend.swift).
    func setFrame(_ frame: UInt64, _ recording: RemoteSnapshotFrameRecording) {
        state.withLock { state in
            guard let index = state.frames.index(forKey: frame) else {
                // Came in before it was referenced, so it was never counted as unresolved.
                state.frames[frame] = RemoteSnapshotFrame(recording: recording)
                return
            }
            // Abandoned because the process recording it went away after recording it. Either outcome is fine. It is ok for
            // addFrameReference to win the race. A frame is only asked to record once, so another recording is dropped rather
            // than replacing the first.
            guard !state.frames.values[index].isResolved else {
                return
            }
            state.frames.values[index].recording = recording
            resolveFrame(&state)
        }
    }
    #else
    // A frame whose display list the C++ has (GPUProcess::snapshotDisplayLists()).
    func frameWasRecorded(_ frame: UInt64) {
        state.withLock { state in
            guard let index = state.frames.index(forKey: frame) else {
                // Came in before it was referenced, so it was never counted as unresolved.
                state.frames[frame] = RemoteSnapshotFrame(isRecorded: true)
                return
            }
            guard !state.frames.values[index].isResolved else {
                return
            }
            state.frames.values[index].isRecorded = true
            resolveFrame(&state)
        }
    }
    #endif

    // Resolves a frame that will not be recorded, so that the snapshot does not wait for it.
    func abandonFrame(_ frame: UInt64) {
        state.withLock { state in
            guard let index = state.frames.index(forKey: frame) else {
                state.frames[frame] = RemoteSnapshotFrame(isAbandoned: true)
                abandonDisplayList(frame)
                return
            }
            guard !state.frames.values[index].isResolved else {
                return
            }
            state.frames.values[index].isAbandoned = true
            abandonDisplayList(frame)
            resolveFrame(&state)
        }
    }

    private func abandonDisplayList(_ frame: UInt64) {
        #if !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
        WebKit.GPUProcess.abandonSnapshotDisplayList(key.cxxKey, frame)
        #endif
    }

    // Notes which process was asked to record a frame, so that the frame can be abandoned if that process goes away.
    func setFrameOwner(_ frame: UInt64, process: UInt64) {
        state.withLock { $0.frameOwners[frame] = process }
    }

    func abandonFramesOwnedBy(_ process: UInt64) {
        let frames = state.withLock { state in
            let frames = state.frameOwners.filter { $0.value == process }.map(\.key)
            for frame in frames {
                state.frameOwners[frame] = nil
            }
            return frames
        }
        for frame in frames {
            abandonFrame(frame)
        }
    }

    // Gives up on every frame still to come, so that the snapshot completes without them.
    func abandonUnresolvedFrames() {
        let frames = state.withLock { state in
            state.frames.filter { !$0.value.isResolved }.map(\.key)
        }
        for frame in frames {
            abandonFrame(frame)
        }
    }

    // Completes every waiter unsuccessfully, for a snapshot that has been released before it completed.
    func fail() {
        state.withLock { state in
            state.hasFailed = true
            dispatchWaitersIfComplete(&state)
        }
    }

    // Whether it completed without its root, which leaves nothing to draw.
    var hasFailed: Bool {
        state.withLock { failed($0) }
    }

    // Whether anything is waiting for it to complete.
    var isAwaited: Bool {
        state.withLock { !$0.waiters.isEmpty }
    }

    // The waiter's completion runs on the main thread, after those of the waiters added before it, once the snapshot is
    // complete or has failed.
    fileprivate func whenComplete(_ waiter: RemoteSnapshotWaiter) {
        state.withLock { state in
            state.waiters.append(waiter)
            dispatchWaitersIfComplete(&state)
        }
    }

    private func failed(_ state: borrowing RemoteSnapshotState) -> Bool {
        if state.hasFailed {
            return true
        }
        guard let rootFrame else {
            return false
        }
        return state.frames[rootFrame]?.isAbandoned ?? true
    }

    private func resolveFrame(_ state: inout RemoteSnapshotState) {
        precondition(state.unresolvedFrames > 0)
        state.unresolvedFrames -= 1
        dispatchWaitersIfComplete(&state)
    }

    // Frames are resolved on the rendering backends' work queues. The sinks dispatch their completions to the main thread even
    // from the main thread, under the lock, which keeps them in the order they were added.
    private func dispatchWaitersIfComplete(_ state: inout RemoteSnapshotState) {
        guard state.isComplete, !state.waiters.isEmpty else {
            return
        }
        var waiters: [RemoteSnapshotWaiter] = []
        swap(&waiters, &state.waiters)
        let success = !failed(state)
        for waiter in waiters {
            #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
            // Each sink's own, since a draw marks the frames it is drawing.
            if success, let sinkState = waiter.sinkState {
                sinkState.frames = completedFrames(state)
            }
            #endif
            waiter.sink.complete(success, WebCore.FloatSize(state.width, state.height), displayListsToken)
        }
    }

    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    private func completedFrames(_ state: borrowing RemoteSnapshotState) -> RemoteCGRendererSnapshotFrames {
        var recordings: [UInt64: RemoteSnapshotFrameRecording] = [:]
        var abandonedFrames: Set<UInt64> = []
        for (frame, value) in state.frames {
            if value.isAbandoned {
                abandonedFrames.insert(frame)
            } else if let recording = value.recording {
                recordings[frame] = recording
            }
        }
        return RemoteCGRendererSnapshotFrames(recordings: recordings, abandonedFrames: abandonedFrames)
    }
    #endif
}

// The Swift state of a sink that takes a snapshot (RemoteSnapshotSink.h): the snapshot and, once it completes with its root,
// its frames. @unchecked Sendable: the frames are set once, when the snapshot completes, before the sink's completion, which
// reads them, is dispatched to the main thread.
final class RemoteSnapshotSinkState: @unchecked Sendable {
    let snapshot: RemoteSnapshot
    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    var frames: RemoteCGRendererSnapshotFrames?
    #endif

    init(snapshot: RemoteSnapshot) {
        self.snapshot = snapshot
    }
}

// The GPU process's snapshots, by identifier, which the rendering backends' work queues reach as well as the main thread.
final class RemoteSnapshotRegistry: Sendable {
    private let snapshots = Mutex<[RemoteSnapshotRegistryKey: RemoteSnapshot]>([:])

    fileprivate init() {
    }

    func snapshot(_ key: RemoteSnapshotRegistryKey) -> RemoteSnapshot? {
        snapshots.withLock { $0[key] }
    }

    // A recorder's: the snapshot, or, if it was already released, one that the recorder fills and that is dropped with it.
    func snapshotForRecorder(_ key: RemoteSnapshotRegistryKey) -> RemoteSnapshot {
        snapshot(key) ?? RemoteSnapshot(key: key, rootFrame: nil)
    }

    func ensureSnapshot(_ key: RemoteSnapshotRegistryKey, rootFrame: UInt64?) -> RemoteSnapshot {
        let (snapshot, isNew) = snapshots.withLock { snapshots in
            if let snapshot = snapshots[key] {
                return (snapshot, false)
            }
            #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
            let snapshot = RemoteSnapshot(key: key, rootFrame: rootFrame)
            #else
            // Before any recorder can find the snapshot.
            let token = WebKit.GPUProcess.createSnapshotDisplayLists(key.cxxKey)
            let snapshot = RemoteSnapshot(key: key, rootFrame: rootFrame, displayListsToken: token)
            #endif
            snapshots[key] = snapshot
            return (snapshot, true)
        }
        // Only one frame can be the root.
        if snapshot.rootFrame != rootFrame {
            snapshot.fail()
        }
        if isNew {
            // Identifiers are never reused, so finding one when the deadline comes means it is this snapshot.
            Task { @MainActor in
                try? await Task.sleep(for: snapshotDeadline, clock: .suspending)
                remoteSnapshots.deadlineExpired(key)
            }
        }
        return snapshot
    }

    private func deadlineExpired(_ key: RemoteSnapshotRegistryKey) {
        guard let snapshot = snapshot(key) else {
            return
        }
        let isAwaited = snapshot.isAwaited
        snapshot.abandonUnresolvedFrames()
        // Whoever is waiting takes it now. Anything else is not coming for it, such as a root whose process went away after the
        // snapshot was released, or a GPU process that was relaunched under whoever asked for it.
        if !isAwaited || snapshot.hasFailed {
            releaseSnapshot(key)
        }
    }

    func releaseSnapshot(_ key: RemoteSnapshotRegistryKey) {
        // Currently it's not possible to know if a snapshot exists, hence no assertion.
        let snapshot = snapshots.withLock { snapshots in
            let snapshot = snapshots.removeValue(forKey: key)
            if snapshot != nil {
                forgetDisplayLists(key)
            }
            return snapshot
        }
        // Anything still waiting for it would otherwise wait for frames that will never be asked for.
        snapshot?.fail()
    }

    // A sink takes the snapshot it waited for, unless it was released and replaced meanwhile. Anything that waits for it
    // since, for a frame that a recorder referenced after it completed, would wait for a snapshot that nothing can reach.
    fileprivate func takeSnapshot(_ snapshot: RemoteSnapshot) {
        let isTaken = snapshots.withLock { snapshots in
            guard snapshots[snapshot.key] === snapshot else {
                return false
            }
            snapshots[snapshot.key] = nil
            forgetDisplayLists(snapshot.key)
            return true
        }
        if isTaken {
            snapshot.fail()
        }
    }

    func abandonFramesOwnedBy(_ process: UInt64) {
        let snapshots = snapshots.withLock { Array($0.values) }
        for snapshot in snapshots {
            snapshot.abandonFramesOwnedBy(process)
        }
    }

    // Only the minting process can ask for a snapshot to be drawn.
    func removeSnapshots(ofProcess process: UInt64) {
        let removed = snapshots.withLock { snapshots in
            let removed = snapshots.filter { $0.key.process == process }
            for key in removed.keys {
                snapshots[key] = nil
                forgetDisplayLists(key)
            }
            return Array(removed.values)
        }
        for snapshot in removed {
            snapshot.fail()
        }
    }

    private func forgetDisplayLists(_ key: RemoteSnapshotRegistryKey) {
        #if !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
        WebKit.GPUProcess.forgetSnapshotDisplayLists(key.cxxKey)
        #endif
    }
}

let remoteSnapshots = RemoteSnapshotRegistry()

extension WebKit.GPUProcess {
    @cxx
    @implementation
    static func swiftCreateSnapshot(
        _ snapshot: WebKit.RemoteSnapshotKey,
        _ rootFrameIdentifier: WebCore.FrameIdentifier,
        _ size: WebCore.FloatSize,
        _ rootProcessIdentifier: WebCore.ProcessIdentifier
    ) {
        // May already exist, if whoever draws it asked first.
        let rootFrame = rootFrameIdentifier.toUInt64()
        let snapshot = remoteSnapshots.ensureSnapshot(RemoteSnapshotRegistryKey(snapshot), rootFrame: rootFrame)
        snapshot.setSize(width: size.width(), height: size.height())
        snapshot.setFrameOwner(rootFrame, process: rootProcessIdentifier.toUInt64())
    }

    @cxx
    @implementation
    static func swiftFailSnapshot(_ snapshot: WebKit.RemoteSnapshotKey) {
        // Created failed if it does not exist yet, so that whoever asks to draw it afterwards does not wait for it.
        remoteSnapshots.ensureSnapshot(RemoteSnapshotRegistryKey(snapshot), rootFrame: nil).fail()
    }

    @cxx
    @implementation
    static func swiftAbandonSnapshotFrame(_ snapshot: WebKit.RemoteSnapshotKey, _ frameIdentifier: WebCore.FrameIdentifier) {
        remoteSnapshots.snapshot(RemoteSnapshotRegistryKey(snapshot))?.abandonFrame(frameIdentifier.toUInt64())
    }

    @cxx
    @implementation
    static func swiftReleaseSnapshot(_ snapshot: WebKit.RemoteSnapshotKey) {
        remoteSnapshots.releaseSnapshot(RemoteSnapshotRegistryKey(snapshot))
    }

    @cxx
    @implementation
    static func swiftSnapshotFrameWillBeDrawnByProcess(
        _ snapshot: WebKit.RemoteSnapshotKey,
        _ frameIdentifier: WebCore.FrameIdentifier,
        _ processIdentifier: WebCore.ProcessIdentifier
    ) {
        // A process that has not connected yet may still do so to record the frame, so only its going away abandons the frame.
        // The UI process says so if it has not connected by then.
        remoteSnapshots.snapshot(RemoteSnapshotRegistryKey(snapshot))?
            .setFrameOwner(frameIdentifier.toUInt64(), process: processIdentifier.toUInt64())
    }

    @cxx
    @implementation
    static func swiftAbandonSnapshotFramesOwnedBy(_ processIdentifier: WebCore.ProcessIdentifier) {
        remoteSnapshots.abandonFramesOwnedBy(processIdentifier.toUInt64())
    }

    @cxx
    @implementation
    static func swiftRemoveSnapshotsForProcess(_ processIdentifier: WebCore.ProcessIdentifier) {
        remoteSnapshots.removeSnapshots(ofProcess: processIdentifier.toUInt64())
    }

    #if !ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    @cxx
    @implementation
    static func swiftAddSnapshotFrameReference(
        _ snapshot: WebKit.RemoteSnapshotKey,
        _ frameIdentifier: WebCore.FrameIdentifier,
        _ displayListsToken: UInt64
    ) {
        // A recorder of a snapshot that didn't exist when it was made records into nothing.
        recordersSnapshot(snapshot, displayListsToken)?.addFrameReference(frameIdentifier.toUInt64())
    }

    @cxx
    @implementation
    static func swiftSnapshotFrameWasRecorded(
        _ snapshot: WebKit.RemoteSnapshotKey,
        _ frameIdentifier: WebCore.FrameIdentifier,
        _ displayListsToken: UInt64
    ) {
        recordersSnapshot(snapshot, displayListsToken)?.frameWasRecorded(frameIdentifier.toUInt64())
    }

    private static func recordersSnapshot(_ snapshot: WebKit.RemoteSnapshotKey, _ displayListsToken: UInt64) -> RemoteSnapshot? {
        guard let snapshot = remoteSnapshots.snapshot(RemoteSnapshotRegistryKey(snapshot)), snapshot.displayListsToken == displayListsToken
        else {
            return nil
        }
        return snapshot
    }
    #endif
}

extension WebKit.RemoteSnapshotSink {
    @cxx
    @implementation
    func swiftTakeSnapshotWhenComplete() {
        // May be asked for before its root has created it, since the UI process asks as soon as it has asked for the root.
        // Anything that went wrong since is reported as failure.
        let snapshot = remoteSnapshots.ensureSnapshot(
            RemoteSnapshotRegistryKey(snapshotKey()),
            rootFrame: hasRootFrame() ? rootFrameKey() : nil
        )
        let sinkState = RemoteSnapshotSinkState(snapshot: snapshot)
        // Safety: the state is new, and retained once, which only the sink's destructor releases (destroySwiftState()).
        unsafe setSwiftState(UInt(bitPattern: unsafe Unmanaged.passRetained(sinkState).toOpaque()))
        snapshot.whenComplete(RemoteSnapshotWaiter(sink: self, sinkState: sinkState))
    }

    @cxx
    @implementation
    func swiftWaitForSnapshot() -> Bool {
        guard let snapshot = remoteSnapshots.snapshot(RemoteSnapshotRegistryKey(snapshotKey())) else {
            return false
        }
        // After the sink waiting for it, so that its reply is sent first.
        snapshot.whenComplete(RemoteSnapshotWaiter(sink: self, sinkState: nil))
        return true
    }

    @cxx
    @implementation
    func swiftDidTakeSnapshot() {
        guard let sinkState else {
            return
        }
        remoteSnapshots.takeSnapshot(sinkState.snapshot)
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        // Safety: swiftTakeSnapshotWhenComplete() retained the state at this address, and only the destructor releases it.
        unsafe Unmanaged<RemoteSnapshotSinkState>.fromOpaque(stateAddress(swiftState)).release()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The sink has no Swift state")
        }
        return unsafe address
    }

    // The state of a sink that takes the snapshot.
    var sinkState: RemoteSnapshotSinkState? {
        let swiftState = swiftState()
        guard swiftState != 0 else {
            return nil
        }
        // Safety: m_swiftState is a retained RemoteSnapshotSinkState from swiftTakeSnapshotWhenComplete() to the destructor,
        // and nothing else changes it.
        return unsafe Unmanaged<RemoteSnapshotSinkState>.fromOpaque(Self.stateAddress(swiftState)).takeUnretainedValue()
    }

    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    var frames: RemoteCGRendererSnapshotFrames? {
        sinkState?.frames
    }
    #endif
}

#endif // ENABLE_GPU_PROCESS
