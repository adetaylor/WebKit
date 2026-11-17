// Copyright (C) 2021-2023 Apple Inc. All rights reserved.
// Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT

import Synchronization
@_spi(WebKitGPU) import WebGPUSwift
internal import WebGPU_Private
import WebKit_Internal

// Runs the work the WebGPU instance schedules on RemoteGPU's work queue, from any thread: the owner's work queue runs it
// when asked to, in the order it was scheduled. A stopping work queue runs nothing it is asked to, so the work scheduled
// meanwhile waits for the receiver's stop to run it; the work scheduled once the receiver has stopped is dropped without
// running.
final class RemoteGPUWorkScheduler: Sendable {
    private struct State {
        var waitingWork: [@Sendable () -> Void] = []
        var askedToRun = false
        var stopped = false
    }

    private let state = Mutex(State())
    private let owner: IPC.SwiftReceiverOwner

    init(_ owner: IPC.SwiftReceiverOwner) {
        self.owner = owner
    }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        let askToRun = state.withLock { state in
            if state.stopped {
                return false
            }
            state.waitingWork.append(work)
            if state.askedToRun {
                return false
            }
            state.askedToRun = true
            return true
        }
        if askToRun {
            owner.scheduleWork()
        }
    }

    // On the work queue: runs the waiting work, including the work it schedules, and then, if `stopped`, drops the work
    // scheduled later.
    func runWaitingWork(thenStopped stopped: Bool = false) {
        while true {
            let work = state.withLock { state in
                let work = state.waitingWork
                state.waitingWork = []
                if work.isEmpty {
                    state.askedToRun = false
                    state.stopped = state.stopped || stopped
                }
                return work
            }
            if work.isEmpty {
                return
            }
            for item in work {
                item()
            }
        }
    }
}

// For GPUConnectionToWebProcess.swift: starts the receiver of a web process's WebGPU messages to its GPU with that identifier
// on the owner, which keeps it until it stops; it draws to and reads the rendering backend's image buffers, and reads the
// video frames the web process shares.
extension RemoteGPU {
    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    @_expose(!Cxx)
    static func create(
        _ owner: IPC.SwiftReceiverOwner,
        _ renderingBackend: WebKit.RemoteRenderingBackend,
        _ identifier: UInt64,
        _ webProcessResourceOwner: consuming WTF.MachSendRight,
        _ videoFrameHeap: WebKit.RemoteVideoFrameObjectHeap,
        _ webProcessIdentity: WebCore.ProcessIdentity?
    ) {
        let videoFrameSources = GPUVideoFrameSources(heap: videoFrameHeap, webProcessIdentity: webProcessIdentity)
        start(owner, renderingBackend, videoFrameSources, identifier, webProcessResourceOwner)
    }
    #else
    @_expose(!Cxx)
    static func create(
        _ owner: IPC.SwiftReceiverOwner,
        _ renderingBackend: WebKit.RemoteRenderingBackend,
        _ identifier: UInt64,
        _ webProcessResourceOwner: consuming WTF.MachSendRight
    ) {
        start(owner, renderingBackend, GPUVideoFrameSources(), identifier, webProcessResourceOwner)
    }
    #endif
}

// The receiver of a web process's WebGPU messages to its GPU, on its owner's work queue, and the owner of the registry of
// the WebGPU objects, from its start until it stops. Its owner keeps it from its start until the work queue stops.
@_expose(Cxx)
final class RemoteGPU {
    private let owner: IPC.SwiftReceiverOwner
    private let identifier: UInt64
    private let scheduler: RemoteGPUWorkScheduler
    // Only used on the work queue once the receiver has started.
    private var registry: WebGPUImplTable?

    @_expose(!Cxx)
    private init(_ owner: IPC.SwiftReceiverOwner, _ identifier: UInt64, _ scheduler: RemoteGPUWorkScheduler) {
        self.owner = owner
        self.identifier = identifier
        self.scheduler = scheduler
    }

    // Makes the receiver, with the WebGPU instance whose work runs on the owner's work queue, and starts it.
    @_expose(!Cxx)
    fileprivate static func start(
        _ owner: IPC.SwiftReceiverOwner,
        _ renderingBackend: WebKit.RemoteRenderingBackend,
        _ videoFrameSources: GPUVideoFrameSources,
        _ identifier: UInt64,
        _ webProcessResourceOwner: consuming WTF.MachSendRight
    ) {
        let scheduler = RemoteGPUWorkScheduler(owner)
        // Safety: the instance's API thread is the work queue's thread, which receives every message that calls into the
        // instance and its objects, and which isWorkQueueCurrent() identifies; the scheduler runs work there later, one item
        // at a time, and drops it only once the receiver has stopped, after the registry is gone (didStopWorkQueue()).
        let instance = unsafe InstanceReference(
            scheduleWork: { work in
                scheduler.schedule(work)
            },
            isAPIThread: {
                owner.isWorkQueueCurrent()
            },
            webProcessResourceOwner: webProcessResourceOwner
        )
        let gpu = RemoteGPU(owner, identifier, scheduler)
        gpu.registry = WebGPUImplTable(owner: owner, renderingBackend: renderingBackend, videoFrameSources: videoFrameSources, instance: instance)
        gpu.startReceiving(on: owner)
        scheduler.schedule { [owner] in
            RemoteGPUProxyMessages.wasCreated(on: owner, to: identifier, didSucceed: true)
        }
    }

    // Only asked for if the forwarder has no shared preferences, which startReceiving(on:) gives it.
    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        owner.sharedPreferencesForWebProcess()
    }

    func runScheduledWork() {
        scheduler.runWaitingWork()
    }

    // Once the work queue stops, nothing can run the work that would call the callbacks pending on the devices' queues,
    // so the registry destroys the devices, which calls them now.
    func didStopReceiving() {
        scheduler.runWaitingWork()
        uninitialize()
    }

    func didStopWorkQueue() {
        scheduler.runWaitingWork()
        // The work can create objects, such as asynchronously created pipelines.
        uninitialize()
        // Only now, after the objects are gone from this thread, may the scheduler drop work elsewhere.
        scheduler.runWaitingWork(thenStopped: true)
    }

    // Destroys the devices that are still alive, so that their pending callbacks are called, empties the registry, and
    // releases it.
    private func uninitialize() {
        guard let registry else {
            return
        }
        self.registry = nil
        registry.destroyDevices()
        registry.removeAll()
    }

    // Only reached by messages, which come between the start and the stop.
    private var table: WebGPUImplTable {
        guard let registry else {
            preconditionFailure("RemoteGPU has no registry")
        }
        return registry
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpu-requestadapter: nil if there's no adapter.
    func requestAdapter(
        options: IPCTypes.RequestAdapterOptions,
        identifier: IPCTypes.WebGPUIdentifier
    ) -> IPCTypes.RemoteGPURequestAdapterResponse? {
        #if arch(x86_64)
        let powerPreference: WebGPU.PowerPreference? = .HighPerformance
        #else
        let powerPreference: WebGPU.PowerPreference? = options.powerPreference.map { $0 == .highPerformance ? .HighPerformance : .LowPower }
        #endif
        return table.requestAdapter(powerPreference, options.forceFallbackAdapter, options.xrCompatible, identifier.rawValue)
    }

    func createPresentationContext(
        descriptor: IPCTypes.PresentationContextDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        let table = self.table
        try messageCheck {
            table.addPresentationContext(identifier.rawValue, descriptor.compositorIntegration.rawValue)
        }
    }

    func createCompositorIntegration(identifier: IPCTypes.WebGPUIdentifier) {
        table.addCompositorIntegration(identifier.rawValue)
    }

    func isValid(identifier: IPCTypes.WebGPUIdentifier) -> (Bool, Bool) {
        let state = table.objectState(identifier.rawValue)
        return (state.valid, state.exists)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
