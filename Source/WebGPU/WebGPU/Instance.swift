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

/// The embedder's scheduleWork: runs a work item on the Instance's API thread.
///
/// Metal threads call it concurrently with the API thread.
@_spi(WebKitGPU)
public typealias InstanceScheduleWork = @Sendable (@escaping @Sendable () -> Void) -> Void

/// Whether the calling thread is the Instance's API thread: the serial context that scheduleWork runs work items on.
@_spi(WebKitGPU)
public typealias InstanceIsAPIThread = @Sendable () -> Bool

// Where the Instance's objects send their work items, to the embedder's scheduleWork, from any thread, and how they check
// that they are on the API thread. Owned by the Instance, by the handles of its objects and by the asynchronous pipeline
// compiles in flight; it doesn't own the Instance. Sendable: Metal threads schedule work.
final class InstanceScheduler: Sendable {
    private let embedder: InstanceScheduleWork
    private let apiThreadCheck: InstanceIsAPIThread

    fileprivate init(embedder: @escaping InstanceScheduleWork, isAPIThread: @escaping InstanceIsAPIThread) {
        self.embedder = embedder
        apiThreadCheck = isAPIThread
    }

    func scheduleWork(_ workItem: @escaping InstanceWorkItem) {
        embedder(workItem)
    }

    func isAPIThread() -> Bool {
        apiThreadCheck()
    }
}

// What Queue and the device observer schedule their work items through from Metal and observer threads, so that no
// such thread holds, or releases, a reference to the Instance. It holds the scheduler, so work is dropped only by the
// embedder, which drops it only once its API thread has stopped (InstanceImpl.init).
final class InstanceSchedulerHandle: Sendable {
    let scheduler: InstanceScheduler

    fileprivate init(_ scheduler: InstanceScheduler) {
        self.scheduler = scheduler
    }

    func scheduleWork(_ workItem: @escaping InstanceWorkItem) {
        scheduler.scheduleWork(workItem)
    }

    func isAPIThread() -> Bool {
        scheduler.isAPIThread()
    }

    func liveScheduler() -> InstanceScheduler? {
        scheduler
    }
}

/// The part of a Metal handler that runs on the Instance's API thread, carried there from the Metal thread.
///
/// Unchecked Sendable: the body and what it captures belong to the API thread. The box is made there and the body runs
/// there, which both trap anywhere else; the Metal thread only hands the box to a work item. A body that never runs is
/// released on the API thread too (releaseOnAPIThread()).
final class APIThreadWork<Argument: Sendable>: @unchecked Sendable {
    private let scheduler: InstanceScheduler
    private var body: ((Argument) -> Void)?

    // On the API thread.
    init(on scheduler: InstanceSchedulerHandle, _ body: @escaping (Argument) -> Void) {
        precondition(scheduler.isAPIThread(), "API thread work made off the API thread")
        self.scheduler = scheduler.scheduler
        self.body = body
    }

    deinit {
        guard let body = body.take() else {
            return
        }
        releaseOnAPIThread(consume body, scheduler)
    }

    // On any thread, as often as wanted: only the first run calls the body.
    func schedule(_ argument: Argument) {
        scheduler.scheduleWork {
            self.run(argument)
        }
    }

    private func run(_ argument: Argument) {
        precondition(scheduler.isAPIThread(), "API thread work run off the API thread")
        if let body = body.take() {
            body(argument)
        }
    }
}

/// Releases what a box held for the API thread, which never ran there: at once on the API thread; anywhere else, by a
/// work item, which the embedder runs on the API thread. The body moves into the work item's holder, so no other
/// reference to it is left here, and the work item drops it explicitly. If the embedder drops the work item instead,
/// which it does only once the API thread has stopped, the holder hands the body to one serial queue that drops it.
func releaseOnAPIThread<Body>(_ body: consuming Body, _ scheduler: InstanceScheduler) {
    if scheduler.isAPIThread() {
        return
    }
    let holder = APIThreadRelease(consume body)
    scheduler.scheduleWork {
        holder.drop()
    }
}

// Releases the bodies of work items that their embedder dropped, after its API thread stopped, one at a time.
private let droppedBodyReleaseQueue = DispatchQueue(label: "com.apple.WebKit.WebGPU.DroppedWorkRelease")

// The only owner of a body on its way to be released. Unchecked Sendable: nothing reads the body, which goes only on the
// API thread, in drop(), or on droppedBodyReleaseQueue.
private final class APIThreadRelease<Body>: @unchecked Sendable {
    private var body: Body?

    init(_ body: consuming Body) {
        self.body = .some(body)
    }

    // On the API thread.
    func drop() {
        body = nil
    }

    deinit {
        guard let body = body.take() else {
            return
        }
        let dropped = DroppedBody(consume body)
        droppedBodyReleaseQueue.async {
            dropped.drop()
        }
    }
}

// A body that droppedBodyReleaseQueue drops. Unchecked Sendable: nothing reads it, and only that queue drops it.
private final class DroppedBody<Body>: @unchecked Sendable {
    private var body: Body?

    init(_ body: consuming Body) {
        self.body = .some(body)
    }

    func drop() {
        body = nil
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
    // Devices.
    private let scheduler: InstanceScheduler
    let schedulerHandle: InstanceSchedulerHandle
    private let backingWebProcessID: WTF.MachSendRight
    private var retainedCommandBuffers: [RetainedCommandBuffer] = []
    // Keyed by the identity of the device, which the entry keeps alive, so the key cannot be reused while the entry
    // exists.
    private var retainedDevices: [ObjectIdentifier: RetainedDevice] = [:]

    /// An Instance whose work items scheduleWork runs on its API thread, which isAPIThread identifies.
    ///
    /// The caller promises that:
    /// - every other call into the Instance and the objects it makes comes from the API thread;
    /// - isAPIThread returns true on the API thread, and only there;
    /// - scheduleWork runs each work item later, on the API thread, one at a time, or, once nothing can call into the
    ///   Instance or its objects any more, drops it without running it, on any thread: what a work item holds for the
    ///   API thread then goes to one serial queue (releaseOnAPIThread()).
    ///
    /// The resource owner is the task that owns the resources the Instance allocates, or an empty right.
    @unsafe
    public init(
        scheduleWork: @escaping InstanceScheduleWork,
        isAPIThread: @escaping InstanceIsAPIThread,
        webProcessResourceOwner: WTF.MachSendRight
    ) {
        scheduler = InstanceScheduler(embedder: scheduleWork, isAPIThread: isAPIThread)
        schedulerHandle = makeInstanceSchedulerHandle(scheduler)
        backingWebProcessID = webProcessResourceOwner
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

    /// https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: nil when no device supports WebGPU.
    ///
    /// nil for a fallback adapter too, which there isn't.
    public func requestAdapter(
        powerPreference: WebGPU.PowerPreference?,
        forceFallbackAdapter: Bool,
        xrCompatible: Bool
    ) -> AdapterReference? {
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
