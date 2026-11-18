// Copyright (C) 2020-2025 Apple Inc. All rights reserved.
// Copyright (C) 2020 Apple Inc. All rights reserved.
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

import CoreGraphics
import CoreVideo
import Dispatch
import Synchronization
import WebKit_Internal

// The receiver of the messages to each layer is the manager, which finds the layer by the message's destination.
typealias RemoteSampleBufferDisplayLayer = RemoteSampleBufferDisplayLayerManager

// What a layer's host sends the web process's SampleBufferDisplayLayer, from the main thread and the layer's queue.
// @unchecked Sendable: the connection is safe to use on any thread, and the identifier is never changed.
private final class SampleBufferDisplayLayerSender: @unchecked Sendable {
    private let connection: IPC.Connection
    private let identifier: UInt64

    init(connection: IPC.Connection, identifier: UInt64) {
        self.connection = connection
        self.identifier = identifier
    }

    func setDidFail(_ didFail: Bool) {
        RemoteSampleBufferDisplayLayer.SampleBufferDisplayLayerMessages.setDidFail(on: connection, to: identifier, value: didFail)
    }

    func updateVideoFrameCounters(_ totalFrameCount: UInt64, _ droppedFrameCount: UInt64) {
        RemoteSampleBufferDisplayLayer.SampleBufferDisplayLayerMessages.updateVideoFrameCounters(
            on: connection,
            to: identifier,
            totalVideoFrames: totalFrameCount,
            droppedVideoFrames: droppedFrameCount
        )
    }
}

// The reply to CreateLayer, which the main thread, which makes the layer, hands back to the queue.
private final class PendingCreateLayerReply: Sendable {
    private let reply: Mutex<RemoteSampleBufferDisplayLayerManagerCreateLayerReply?>

    init(_ reply: consuming sending RemoteSampleBufferDisplayLayerManagerCreateLayerReply) {
        self.reply = Mutex(.some(reply))
    }

    // Without a host, the reply is the default one, an empty hosting context.
    func send(_ host: WebKit.SampleBufferDisplayLayerHost?) {
        reply.withLock { reply in
            guard let reply = reply.take() else {
                return
            }
            guard let host else {
                return
            }
            reply.send { host.encodeHostingContext($0) }
        }
    }
}

// The receiver of a web process's sample buffer display layers, and of the messages to each, on the GPU process's video
// media stream track renderer queue, which is its executor and which its forwarders are registered with. The main thread
// makes the layers' hosts and updates their bounds, as Core Animation needs.
actor RemoteSampleBufferDisplayLayerManager: GPUConnectionReceiver {
    nonisolated let queue: DispatchSerialQueue
    private let frameSources: GPUVideoFrameSources
    // The readers of the frames each layer's web process shares.
    private var frameSourcesByLayer: [UInt64: SharedVideoFrameSource] = [:]
    // The layers' hosts, held while a host is used, from the queue or the main thread, which serializes the calls to them.
    private nonisolated let hosts = Mutex<[UInt64: WebKit.SampleBufferDisplayLayerHost]>([:])

    init(videoFrameHeap: VideoFrameHeap, webProcessIdentity: WebCore.ProcessIdentity?, queue: DispatchSerialQueue) {
        frameSources = GPUVideoFrameSources(heap: videoFrameHeap, webProcessIdentity: webProcessIdentity)
        self.queue = queue
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        // Safety: the queue is serial and outlives this, which keeps it.
        unsafe queue.asUnownedSerialExecutor()
    }

    // The forwarders keep this alive, so this mustn't keep them: the connection they are registered with does.
    nonisolated func getManagerMessageReceiver() -> RefRemoteSampleBufferDisplayLayerManagerMessageForwarder {
        WebKit.RemoteSampleBufferDisplayLayerManagerMessageForwarder.create(target: self)
    }

    nonisolated func getLayerMessageReceiver() -> RefRemoteSampleBufferDisplayLayerMessageForwarder {
        WebKit.RemoteSampleBufferDisplayLayerMessageForwarder.create(target: self)
    }

    nonisolated var allowsExitUnderMemoryPressure: Bool {
        hosts.withLock { $0.isEmpty }
    }

    // The layers stay until the connection goes, when its forwarders stop.
    nonisolated func connectionDidClose() {
    }

    // On the main thread.
    nonisolated func updateBoundsAndPosition(_ identifier: UInt64, _ bounds: CGRect, _ fence: WebKit.OptionalMachSendRightAnnotated) {
        hosts.withLock { hosts in
            hosts[identifier]?.updateBoundsAndPosition(bounds, fence)
        }
    }

    // MARK: Manager messages

    func createLayer(
        connection: IPC.Connection,
        id: IPCTypes.SampleBufferDisplayLayerIdentifier,
        hideRootLayer: Bool,
        size: IPCTypes.IntSize,
        shouldMaintainAspectRatio: Bool,
        canShowWhileLocked: Bool,
        reply: consuming sending RemoteSampleBufferDisplayLayerManagerCreateLayerReply
    ) {
        let pendingReply = PendingCreateLayerReply(reply)
        let identifier = id.rawValue
        let sender = SampleBufferDisplayLayerSender(connection: connection, identifier: identifier)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                let statusHandler = WebKit.SampleBufferDisplayLayerHostStatusHandler { didFail in
                    sender.setDidFail(didFail)
                }
                let countersHandler = WebKit.SampleBufferDisplayLayerHostCountersHandler { totalFrameCount, droppedFrameCount in
                    sender.updateVideoFrameCounters(totalFrameCount, droppedFrameCount)
                }
                guard
                    let host = WebKit.SampleBufferDisplayLayerHost.create(
                        WebCore.IntSize(size.width, size.height),
                        hideRootLayer,
                        shouldMaintainAspectRatio,
                        canShowWhileLocked,
                        consuming: statusHandler,
                        consuming: countersHandler
                    )
                else {
                    pendingReply.send(nil)
                    return
                }
                queue.async { [self] in
                    assumeIsolated { $0.addLayer(identifier, host, pendingReply) }
                }
            }
        }
    }

    private func addLayer(_ identifier: UInt64, _ host: WebKit.SampleBufferDisplayLayerHost, _ pendingReply: PendingCreateLayerReply) {
        assert(frameSourcesByLayer[identifier] == nil)
        if frameSourcesByLayer[identifier] == nil {
            frameSourcesByLayer[identifier] = frameSources.make()
            hosts.withLock { $0[identifier] = host }
        }
        pendingReply.send(host)
    }

    // After the layer is made: the main thread hands the release back to the queue after the layer it made.
    func releaseLayer(connection: IPC.Connection, id: IPCTypes.SampleBufferDisplayLayerIdentifier) {
        let identifier = id.rawValue
        DispatchQueue.main.async { [self] in
            queue.async { [self] in
                assumeIsolated { $0.removeLayer(identifier) }
            }
        }
    }

    private func removeLayer(_ identifier: UInt64) {
        let frameSource = frameSourcesByLayer.removeValue(forKey: identifier)
        assert(frameSource != nil)
        hosts.withLock { _ = $0.removeValue(forKey: identifier) }
    }

    // MARK: Layer messages

    private func checkDestination(_ destinationID: UInt64) throws(InvalidMessage) {
        try messageCheck { destinationID != 0 && destinationID != UInt64.max }
    }

    // Uses the host of the layer a message is for, if it hasn't been released.
    private func withHost(_ destinationID: UInt64, _ body: (WebKit.SampleBufferDisplayLayerHost) -> Void) throws(InvalidMessage) {
        try checkDestination(destinationID)
        hosts.withLock { hosts in
            if let host = hosts[destinationID] {
                body(host)
            }
        }
    }

    func setLogIdentifier(connection: IPC.Connection, destinationID: UInt64, logIdentifier: UInt64) throws(InvalidMessage) {
        try withHost(destinationID) { $0.setLogIdentifier(logIdentifier) }
    }

    func updateDisplayMode(connection: IPC.Connection, destinationID: UInt64, hideDisplayLayer: Bool, hideRootLayer: Bool) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().updateDisplayMode(hideDisplayLayer, hideRootLayer) }
    }

    func flush(connection: IPC.Connection, destinationID: UInt64) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().flush() }
    }

    func flushAndRemoveImage(connection: IPC.Connection, destinationID: UInt64) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().flushAndRemoveImage() }
    }

    func enqueueVideoFrame(connection: IPC.Connection, destinationID: UInt64, frame: consuming IPCTypes.SharedVideoFrame) throws(InvalidMessage) {
        try checkDestination(destinationID)
        guard let frameSource = frameSourcesByLayer[destinationID], let pixelBuffer = frameSource.readBuffer(frame.buffer) else {
            return
        }
        let frame = frame
        hosts.withLock { hosts in
            hosts[destinationID]?.enqueuePixelBuffer(
                pixelBuffer,
                frame.time.timeValue,
                frame.time.timeScale,
                frame.time.timeFlags,
                frame.rotation.rawValue,
                frame.mirrored,
                frame.colorSpace.colorSpaceValues,
                frame.shouldIgnoreAlpha
            )
        }
    }

    func clearVideoFrames(connection: IPC.Connection, destinationID: UInt64) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().clearVideoFrames() }
    }

    func play(connection: IPC.Connection, destinationID: UInt64) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().play() }
    }

    func pause(connection: IPC.Connection, destinationID: UInt64) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().pause() }
    }

    func setSharedVideoFrameSemaphore(connection: IPC.Connection, destinationID: UInt64, semaphore: borrowing IPCTypes.Semaphore) throws(InvalidMessage) {
        try checkDestination(destinationID)
        frameSourcesByLayer[destinationID]?.setSemaphore(semaphore.port)
    }

    func setSharedVideoFrameMemory(connection: IPC.Connection, destinationID: UInt64, storageHandle: borrowing IPCTypes.SharedMemoryHandle) throws(InvalidMessage) {
        try checkDestination(destinationID)
        _ = frameSourcesByLayer[destinationID]?.setSharedMemory(storageHandle.port, storageHandle.size)
    }

    func setShouldMaintainAspectRatio(connection: IPC.Connection, destinationID: UInt64, shouldMaintainAspectRatio: Bool) throws(InvalidMessage) {
        try withHost(destinationID) { $0.displayLayer().setShouldMaintainAspectRatio(shouldMaintainAspectRatio) }
    }
}


// The members of the connection that make its sample buffer display layer receiver and route to it.
extension WebKit.GPUConnectionToWebProcess {
    @cxx
    @implementation
    @MainActor
    func swiftCreateSampleBufferDisplayLayerManager(
        _ videoFrameHeap: WebKit.RemoteVideoFrameObjectHeap,
        _ webProcessIdentity: WebCore.ProcessIdentity,
        _ hasWebProcessIdentity: Bool,
        _ queue: UnsafeMutableRawPointer
    ) -> RefRemoteSampleBufferDisplayLayerManagerMessageForwarder {
        // Safety: the connection passes the dispatch queue of the GPU process's video media stream track renderer WorkQueue,
        // which keeps it for the process's life, and this retains it.
        let dispatchQueue = unsafe Unmanaged<DispatchQueue>.fromOpaque(queue).takeUnretainedValue()
        guard let serialQueue = dispatchQueue as? DispatchSerialQueue else {
            preconditionFailure("The sample buffer display layer queue is not serial")
        }
        precondition(state.sampleBufferDisplayLayerManager == nil, "The connection has a sample buffer display layer receiver")
        let manager = RemoteSampleBufferDisplayLayerManager(
            videoFrameHeap: videoFrameHeap.frames,
            webProcessIdentity: hasWebProcessIdentity ? webProcessIdentity : nil,
            queue: serialQueue
        )
        state.sampleBufferDisplayLayerManager = manager
        return manager.getManagerMessageReceiver()
    }

    @cxx
    @implementation
    @MainActor
    func swiftSampleBufferDisplayLayerForwarder() -> RefRemoteSampleBufferDisplayLayerMessageForwarder {
        guard let manager = state.sampleBufferDisplayLayerManager else {
            preconditionFailure("The connection has no sample buffer display layer receiver")
        }
        return manager.getLayerMessageReceiver()
    }

    @cxx
    @implementation
    @MainActor
    func swiftUpdateSampleBufferDisplayLayerBoundsAndPosition(_ identifier: UInt64, _ bounds: CGRect, _ fence: WebKit.OptionalMachSendRightAnnotated) {
        state.sampleBufferDisplayLayerManager?.updateBoundsAndPosition(identifier, bounds, fence)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_MEDIA_STREAM && WTF_PLATFORM_COCOA
