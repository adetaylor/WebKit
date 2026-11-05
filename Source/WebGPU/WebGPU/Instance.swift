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

import Dispatch
import Metal
import Synchronization
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
import WebGPU_Private.WebGPUCpp

// A work item waiting for processEvents(). Sendable because the item is moved into a Mutex of its own, which the
// region checker accepts only for a value no other code can reach (`sending`). The draining thread runs it under that
// lock, which nothing else takes, and the item is destroyed with the PendingWork.
private final class PendingWork: Sendable {
    private let item: Mutex<CxxBridging.InstanceWorkItem>

    init(_ item: consuming sending CxxBridging.InstanceWorkItem) {
        self.item = Mutex(item)
    }

    func run() {
        item.withLock { $0() }
    }
}

private struct EventQueueState {
    var pendingWork: [PendingWork] = []
    var nextFuture: UInt64 = 1
    var completedFutures: Set<UInt64> = []
    // The condition variable: each blocked waitForAnyFuture() registers a semaphore, which notifyAll() signals once.
    var waiters: [DispatchSemaphore] = []

    mutating func notifyAll() {
        for waiter in waiters {
            waiter.signal()
        }
        waiters.removeAll()
    }

    func anyFutureCompleted(_ futures: Span<UInt64>) -> Bool {
        for index in futures.indices where completedFutures.contains(futures[index]) {
            return true
        }
        return false
    }
}

private enum WaitStep {
    case completed
    case runPendingWork
    case wait(DispatchSemaphore)
}

// The work items of an Instance without an embedder scheduleWork (the C API's), which wait for processEvents(), and
// the futures of the C API. Sendable: Metal threads append work, and any thread may wait.
final class InstanceEventQueue: Sendable {
    private let state = Mutex(EventQueueState())

    fileprivate init() {
    }

    fileprivate func append(_ item: consuming sending CxxBridging.InstanceWorkItem) {
        let work = PendingWork(item)
        state.withLock { state in
            state.pendingWork.append(work)
            state.notifyAll()
        }
    }

    func createFuture() -> UInt64 {
        state.withLock { state in
            let future = state.nextFuture
            state.nextFuture &+= 1
            return future
        }
    }

    func completeFuture(_ future: UInt64) {
        state.withLock { state in
            state.completedFutures.insert(future)
            state.notifyAll()
        }
    }

    // Runs the work items in the order they were scheduled, including those they schedule. Each batch taken from the
    // queue is destroyed, in order, after all of its items have run.
    func processEvents() {
        while true {
            let batch = state.withLock { state in
                let batch = state.pendingWork
                state.pendingWork = []
                return batch
            }
            if batch.isEmpty {
                return
            }
            for work in batch {
                work.run()
            }
        }
    }

    // An infinite timeout never passes. When the timeout passes, the futures and the queue are checked once more.
    func waitForAnyFuture(
        _ futureIDs: borrowing CxxBridging.FutureIDsView,
        _ timeoutSeconds: Double,
        _ didComplete: borrowing CxxBridging.FutureCompletedHandler
    ) -> Bool {
        let futures: Span<UInt64> = futureIDs.span()
        let deadline: DispatchTime = timeoutSeconds == .infinity ? .distantFuture : .now() + timeoutSeconds
        while true {
            processEvents()
            let step = state.withLock { state -> WaitStep in
                if state.anyFutureCompleted(futures) {
                    for index in futures.indices where state.completedFutures.remove(futures[index]) != nil {
                        didComplete(UInt(index))
                    }
                    return .completed
                }
                if !state.pendingWork.isEmpty {
                    return .runPendingWork
                }
                let waiter = DispatchSemaphore(value: 0)
                state.waiters.append(waiter)
                return .wait(waiter)
            }
            switch step {
            case .completed:
                return true
            case .runPendingWork:
                continue
            case .wait(let waiter):
                if waiter.wait(timeout: deadline) == .success {
                    continue
                }
                let satisfied = state.withLock { state in
                    state.waiters.removeAll { $0 === waiter }
                    return !state.pendingWork.isEmpty || state.anyFutureCompleted(futures)
                }
                if !satisfied {
                    return false
                }
            }
        }
    }
}

// The embedder's scheduleWork. Unchecked Sendable: Metal threads call it concurrently with the API thread; whether the
// closure allows that is the embedder's contract, which no Swift check can see.
private struct EmbedderScheduleWork: ~Copyable, @unchecked Sendable {
    let function: CxxBridging.InstanceScheduleWork
}

// Where Instance::scheduleWork() sends a work item: to the embedder's scheduleWork, without taking any lock, or
// else to the event queue. Owned by the Instance and by the asynchronous pipeline compiles in flight. Sendable: Metal
// threads schedule work.
final class InstanceScheduler: Sendable {
    private let embedder: EmbedderScheduleWork?
    private let events: InstanceEventQueue

    fileprivate init(embedder: consuming EmbedderScheduleWork?, events: InstanceEventQueue) {
        self.embedder = embedder
        self.events = events
    }

    // Takes the work item, leaving `workItem` empty.
    func scheduleWork(_ workItem: inout sending CxxBridging.InstanceWorkItem) {
        let item = workItem
        workItem = CxxBridging.InstanceWorkItem()
        switch embedder {
        case .some(let embedder):
            embedder.function(consuming: item)
        case .none:
            events.append(item)
        }
    }
}

// What Queue and the device observer schedule their work items through from Metal and observer threads, so that no
// such thread holds, or releases, a reference to the Instance. Once the Instance is gone, work items are dropped.
final class InstanceSchedulerHandle: Sendable {
    private weak let scheduler: InstanceScheduler?

    fileprivate init(_ scheduler: InstanceScheduler) {
        self.scheduler = scheduler
    }

    // Takes the work item, leaving `workItem` empty.
    func scheduleWork(_ workItem: inout sending CxxBridging.InstanceWorkItem) {
        guard let scheduler else {
            workItem = CxxBridging.InstanceWorkItem()
            return
        }
        scheduler.scheduleWork(&workItem)
    }

    func liveScheduler() -> InstanceScheduler? {
        scheduler
    }
}

/// The part of a Metal handler that runs on the Instance's API thread, carried there from the Metal thread.
///
/// Unchecked Sendable: the body and what it captures belong to the API thread. The Metal thread only hands the box to a
/// work item, and the scheduler's hop orders that before the API thread runs the body, which goes as it runs. So the
/// body's references are released on the API thread, unless the Instance is gone and the work item is dropped.
final class APIThreadWork<Argument: Sendable>: @unchecked Sendable {
    private var body: ((Argument) -> Void)?

    init(_ body: @escaping (Argument) -> Void) {
        self.body = body
    }

    // On the Metal thread.
    func schedule(_ argument: Argument, on scheduler: InstanceSchedulerHandle?) {
        var workItem = CxxBridging.InstanceWorkItem {
            self.run(argument)
        }
        scheduler?.scheduleWork(&workItem)
    }

    private func run(_ argument: Argument) {
        if let body = body.take() {
            body(argument)
        }
    }
}

func makeInstanceEventQueue() -> InstanceEventQueue {
    InstanceEventQueue()
}

// Takes the embedder's scheduleWork, leaving `scheduleWork` empty.
func makeInstanceScheduler(_ scheduleWork: inout CxxBridging.InstanceScheduleWork, _ events: InstanceEventQueue) -> InstanceScheduler {
    let function = scheduleWork
    scheduleWork = CxxBridging.InstanceScheduleWork()
    return InstanceScheduler(embedder: EmbedderScheduleWork(function: function), events: events)
}

func makeInstanceSchedulerWithoutEmbedder(_ events: InstanceEventQueue) -> InstanceScheduler {
    InstanceScheduler(embedder: nil, events: events)
}

func makeInstanceSchedulerHandle(_ scheduler: InstanceScheduler) -> InstanceSchedulerHandle {
    InstanceSchedulerHandle(scheduler)
}

private struct WeakCommandBuffer {
    weak var commandBuffer: (any MTLCommandBuffer)?

    var isGone: Bool {
        commandBuffer == nil
    }

    func waitIfCommitted() {
        guard let commandBuffer, commandBuffer.status.rawValue >= MTLCommandBufferStatus.committed.rawValue else {
            return
        }
        commandBuffer.waitUntilCompleted()
    }
}

private struct RetainedDevice {
    let device: DeviceImpl
    var commandBuffers: [WeakCommandBuffer] = []
}

private struct RetainedCommandBuffer {
    let commandBuffer: CommandBufferImpl
    let mtlCommandBuffer: WeakCommandBuffer
}

@_spi(WebKitGPU)
public typealias InstanceReference = InstanceImpl

// https://gpuweb.github.io/gpuweb/#gpu
// The scheduler, which any thread may use through its handle, and the web process ID and the containers that keep
// Devices and CommandBuffers alive until their MTLCommandBuffers are deallocated, which only the API thread uses. No
// Metal or observer thread holds the Instance (they schedule work through InstanceSchedulerHandle), so deinit runs on
// the thread that releases it.
@_spi(WebKitGPU)
public final class InstanceImpl {
    // Declared in release order: the embedder's scheduleWork, then the web process ID, the CommandBuffers and the
    // Devices, and the work items still waiting for processEvents() last.
    private let scheduler: InstanceScheduler
    let schedulerHandle: InstanceSchedulerHandle
    private let backingWebProcessID: WTF.MachSendRight
    private var retainedCommandBuffers: [RetainedCommandBuffer] = []
    // Keyed by the identity of the device, which the entry keeps alive, so the key cannot be reused while the entry
    // exists.
    private var retainedDevices: [ObjectIdentifier: RetainedDevice] = [:]
    private let events: InstanceEventQueue

    // Takes the descriptor's scheduleWork and resource owner.
    public init(_ descriptor: inout WebGPU.InstanceDescriptor) {
        let events = InstanceEventQueue()
        if WebGPU.Metal.hasScheduleWork(descriptor) {
            var scheduleWork = WebGPU.Metal.takeScheduleWork(&descriptor)
            scheduler = makeInstanceScheduler(&scheduleWork, events)
        } else {
            scheduler = makeInstanceSchedulerWithoutEmbedder(events)
        }
        schedulerHandle = makeInstanceSchedulerHandle(scheduler)
        backingWebProcessID = WebGPU.Metal.takeWebProcessResourceOwner(&descriptor)
        self.events = events
    }

    // The task that owns the resources the Instance allocates, copied out; an empty right without one.
    func webProcessIdentity() -> WTF.MachSendRight {
        backingWebProcessID
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: nil when no device supports WebGPU, and for a fallback
    // adapter, which there isn't.
    public func requestAdapter(_ options: WebGPU.RequestAdapterOptions) -> AdapterReference? {
        var capabilities = WebGPU.Metal.HardwareCapabilities()
        guard let device = WebGPU.Metal.requestAdapterDevice(options, &capabilities) else {
            return nil
        }
        let adapter = makeAdapterImpl(device, options.xrCompatible, capabilities)
        adapter.setInstance(self)
        return adapter
    }

    // A canvas context for a compositor's render buffers, which the compositor gives it through
    // renderBuffersWereRecreated() and addRenderBuffer(_:).
    public func createPresentationContext() -> PresentationContextReference {
        let webProcessID = webProcessIdentity()
        return withExtendedLifetime(webProcessID) {
            makePresentationContextIOSurfaceImpl(WebGPU.Metal.webProcessIdentityPort(webProcessID))
        }
    }
    func retainDevice(_ device: DeviceImpl, _ commandBuffer: (any MTLCommandBuffer)?) {
        retainedDevices[ObjectIdentifier(device), default: RetainedDevice(device: device)].commandBuffers
            .append(WeakCommandBuffer(commandBuffer: commandBuffer))
        releaseCompletedCommandBuffers()
    }

    func retainCommandBuffer(_ commandBuffer: CommandBufferImpl, _ mtlCommandBuffer: (any MTLCommandBuffer)?) {
        releaseCompletedCommandBuffers()
        retainedCommandBuffers.append(
            RetainedCommandBuffer(commandBuffer: commandBuffer, mtlCommandBuffer: WeakCommandBuffer(commandBuffer: mtlCommandBuffer))
        )
    }

    // The removed entries die when `previous*` go out of scope, outside any access to the stored
    // properties, so a destructor that re-enters this object cannot trip exclusivity enforcement.
    func releaseCompletedCommandBuffers() {
        let previousCommandBuffers = retainedCommandBuffers
        retainedCommandBuffers = previousCommandBuffers.filter { !$0.mtlCommandBuffer.isGone }

        let previousDevices = retainedDevices
        var survivingDevices: [ObjectIdentifier: RetainedDevice] = [:]
        for (key, var entry) in previousDevices {
            entry.commandBuffers.removeAll { $0.isGone }
            if !entry.commandBuffers.isEmpty {
                survivingDevices[key] = entry
            }
        }
        retainedDevices = survivingDevices
    }

    func waitForCommandBufferCompletions() {
        let commandBuffers = retainedCommandBuffers
        let devices = retainedDevices
        retainedCommandBuffers = []
        retainedDevices = [:]
        // Keep the command buffers and devices alive until both waits are done.
        withExtendedLifetime((commandBuffers, devices)) {
            for entry in commandBuffers {
                entry.mtlCommandBuffer.waitIfCommitted()
            }
            for entry in devices.values {
                for commandBuffer in entry.commandBuffers {
                    commandBuffer.waitIfCommitted()
                }
            }
        }
    }
}
