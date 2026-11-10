// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Dispatch
import Metal
import Synchronization
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
#if hasAttribute(diagnose)
@diagnose(UnusedImportAccess, as: ignored, reason: "Needed for exposed SPI")
#endif
public import WebGPU_Private.WebGPUCpp

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
}

// The work items of an Instance without an embedder scheduleWork, which wait for processEvents(). Sendable: Metal
// threads append work.
final class InstanceEventQueue: Sendable {
    private let state = Mutex(EventQueueState())

    fileprivate init() {
    }

    fileprivate func append(_ item: consuming sending CxxBridging.InstanceWorkItem) {
        let work = PendingWork(item)
        state.withLock { state in
            state.pendingWork.append(work)
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
// such thread holds, or releases, a reference to the Instance. It holds the scheduler, which doesn't own the Instance,
// so work is dropped only by the embedder, which drops it only once its API thread has stopped (InstanceImpl.init).
final class InstanceSchedulerHandle: Sendable {
    let scheduler: InstanceScheduler

    fileprivate init(_ scheduler: InstanceScheduler) {
        self.scheduler = scheduler
    }

    // Takes the work item, leaving `workItem` empty.
    func scheduleWork(_ workItem: inout sending CxxBridging.InstanceWorkItem) {
        scheduler.scheduleWork(&workItem)
    }

    func liveScheduler() -> InstanceScheduler? {
        scheduler
    }
}

/// The part of a Metal handler that runs on the Instance's API thread, carried there from the Metal thread.
///
/// Unchecked Sendable: the body and what it captures belong to the API thread, where the box is made. The Metal thread
/// only hands the box to a work item, and the scheduler's hop orders that before the API thread runs the body, which
/// goes as it runs. A body that never runs is released in a work item too (releaseOnAPIThread()).
final class APIThreadWork<Argument: Sendable>: @unchecked Sendable {
    private let scheduler: InstanceScheduler
    private var body: ((Argument) -> Void)?

    // On the API thread.
    init(on scheduler: InstanceSchedulerHandle, _ body: @escaping (Argument) -> Void) {
        self.scheduler = scheduler.scheduler
        self.body = body
    }

    deinit {
        releaseOnAPIThread(body.take(), scheduler)
    }

    // On the Metal thread.
    func schedule(_ argument: Argument) {
        var workItem = CxxBridging.InstanceWorkItem {
            self.run(argument)
        }
        scheduler.scheduleWork(&workItem)
    }

    private func run(_ argument: Argument) {
        if let body = body.take() {
            body(argument)
        }
    }
}

/// Releases what a box held for the API thread, which never ran there, in a work item: the embedder runs it on the API
/// thread, or releases it on its serial queue once the API thread has stopped.
func releaseOnAPIThread<Body>(_ body: Body?, _ scheduler: InstanceScheduler) {
    guard let body else {
        return
    }
    let release = APIThreadRelease(body)
    var workItem = CxxBridging.InstanceWorkItem {
        withExtendedLifetime(release) {
        }
    }
    scheduler.scheduleWork(&workItem)
}

// A value on its way to be released. Unchecked Sendable: nothing reads the value, and the work item that holds it goes on
// the API thread, or after it has stopped, as releaseOnAPIThread() says.
private final class APIThreadRelease<Body>: @unchecked Sendable {
    private let body: Body

    init(_ body: Body) {
        self.body = body
    }
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
public final class InstanceImpl: LinkedImpl {
    private var linkSlot = ImplLinkSlot<InstanceImpl>()
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
    //
    // The caller promises that every other call into the Instance and the objects it makes comes from its API thread, and
    // that scheduleWork runs each work item later, on the API thread, one at a time, or, once nothing can call into the
    // Instance or its objects any more, releases it without running it, on one serial queue.
    @unsafe
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

    deinit {
        linkSlot.end()
    }

    var link: ImplLink<InstanceImpl> {
        linkSlot.link(for: self)
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
}
