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

// A work item, which runs on the Instance's API thread.
typealias InstanceWorkItem = @Sendable () -> Void

// The embedder's scheduleWork: runs a work item on the thread the Instance calls back on. Metal threads call it
// concurrently with the API thread.
@_spi(WebKitGPU)
public typealias InstanceScheduleWork = @Sendable (@escaping @Sendable () -> Void) -> Void

private struct EventQueueState {
    var pendingWork: [InstanceWorkItem] = []
}

// The work items of an Instance without an embedder scheduleWork, which wait for processEvents(). Sendable: Metal
// threads append work.
final class InstanceEventQueue: Sendable {
    private let state = Mutex(EventQueueState())

    fileprivate init() {
    }

    fileprivate func append(_ item: @escaping InstanceWorkItem) {
        state.withLock { state in
            state.pendingWork.append(item)
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
                work()
            }
        }
    }
}

// Where Instance::scheduleWork() sends a work item: to the embedder's scheduleWork, without taking any lock, or
// else to the event queue. Owned by the Instance and by the asynchronous pipeline compiles in flight. Sendable: Metal
// threads schedule work.
final class InstanceScheduler: Sendable {
    private let embedder: InstanceScheduleWork?
    private let events: InstanceEventQueue

    fileprivate init(embedder: InstanceScheduleWork?, events: InstanceEventQueue) {
        self.embedder = embedder
        self.events = events
    }

    func scheduleWork(_ workItem: @escaping InstanceWorkItem) {
        if let embedder {
            embedder(workItem)
        } else {
            events.append(workItem)
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

    // Drops the work item once the Instance is gone.
    func scheduleWork(_ workItem: @escaping InstanceWorkItem) {
        scheduler?.scheduleWork(workItem)
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
        scheduler?.scheduleWork {
            self.run(argument)
        }
    }

    private func run(_ argument: Argument) {
        if let body = body.take() {
            body(argument)
        }
    }
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

    // Without scheduleWork, the work items wait for processEvents(). The resource owner is the task that owns the
    // resources the Instance allocates, or an empty right.
    public init(scheduleWork: InstanceScheduleWork?, webProcessResourceOwner: WTF.MachSendRight) {
        let events = InstanceEventQueue()
        scheduler = InstanceScheduler(embedder: scheduleWork, events: events)
        schedulerHandle = makeInstanceSchedulerHandle(scheduler)
        backingWebProcessID = webProcessResourceOwner
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
    public func requestAdapter(powerPreference: WebGPU.PowerPreference?, forceFallbackAdapter: Bool, xrCompatible: Bool) -> AdapterReference? {
        // FIXME: Deal with options.compatibleSurface.
        guard !forceFallbackAdapter, let device = sortedAdapterDevices(powerPreference).first,
            let capabilities = hardwareCapabilities(device)
        else {
            return nil
        }
        let adapter = makeAdapterImpl(device, xrCompatible, capabilities)
        adapter.setInstance(self)
        return adapter
    }

    // A canvas context for a compositor's render buffers, which the compositor gives it through
    // renderBuffersWereRecreated() and addRenderBuffer(_:).
    public func createPresentationContext() -> PresentationContextReference {
        let webProcessID = webProcessIdentity()
        return withExtendedLifetime(webProcessID) {
            #if HAVE_IOSURFACE_SET_OWNERSHIP_IDENTITY && HAVE_TASK_IDENTITY_TOKEN
            makePresentationContextIOSurfaceImpl(webProcessID.sendRight())
            #else
            makePresentationContextIOSurfaceImpl(mach_port_t(MACH_PORT_NULL))
            #endif
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

// The devices an adapter can be made of, the preferred first.
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "isLowPower still tells a Mac's integrated GPU from its discrete one")
#endif
private func sortedAdapterDevices(_ powerPreference: WebGPU.PowerPreference?) -> [any MTLDevice] {
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    let devices = MTLCopyAllDevices()
    guard let powerPreference else {
        return devices
    }
    let lowPowerFirst = powerPreference == .LowPower
    return devices.filter { $0.isLowPower == lowPowerFirst } + devices.filter { $0.isLowPower != lowPowerFirst }
    #else
    _ = powerPreference
    return MTLCreateSystemDefaultDevice().map { [$0] } ?? []
    #endif
}
