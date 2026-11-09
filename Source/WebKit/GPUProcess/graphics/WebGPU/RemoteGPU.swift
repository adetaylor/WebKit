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

// Runs the work the WebGPU instance schedules on RemoteGPU's work queue, from any thread. A stopping work queue drops the
// work dispatched to it, so the work scheduled meanwhile waits here to run before it stops.
final class RemoteGPUWorkScheduler: Sendable {
    private enum Stage {
        case running
        case stopping
        case stopped
    }

    private struct State {
        var stage = Stage.running
        var waitingWork: [@Sendable () -> Void] = []
    }

    private let state = Mutex(State())
    private let workQueue: IPC.StreamConnectionWorkQueue

    init(_ workQueue: IPC.StreamConnectionWorkQueue) {
        self.workQueue = workQueue
    }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        state.withLock { state in
            switch state.stage {
            case .running:
                workQueue.dispatch(consuming: IPC.StreamConnectionWorkQueue.WorkItem(work))
            case .stopping:
                state.waitingWork.append(work)
            case .stopped:
                break
            }
        }
    }

    func beginStopping() {
        state.withLock { $0.stage = .stopping }
    }

    // On the work queue: runs the work scheduled while stopping, including the work it schedules, and then stops, or
    // keeps stopping.
    func runWaitingWork(thenStopped stopped: Bool) {
        while true {
            let work = state.withLock { state in
                if state.waitingWork.isEmpty {
                    state.stage = stopped ? .stopped : .stopping
                }
                let work = state.waitingWork
                state.waitingWork = []
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

// What m_swiftState holds: the scheduler, and the registry of the WebGPU objects until the RemoteGPU stops.
final class RemoteGPUState {
    let scheduler: RemoteGPUWorkScheduler
    var registry: WebGPUImplTable?

    init(_ scheduler: RemoteGPUWorkScheduler) {
        self.scheduler = scheduler
    }
}

// RemoteGPU's WebGPU messages (RemoteGPU.h), on its work queue, and its Swift state, which m_swiftState holds retained,
// by address, from swiftInitialize() to the destructor.
extension WebKit.RemoteGPU {
    @cxx
    @implementation
    func swiftInitialize(_ webProcessResourceOwner: WTF.MachSendRight) {
        precondition(m_swiftState == 0)
        let scheduler = RemoteGPUWorkScheduler(workQueue())
        let instance = InstanceReference(
            scheduleWork: { work in
                scheduler.schedule(work)
            },
            webProcessResourceOwner: webProcessResourceOwner
        )
        let state = RemoteGPUState(scheduler)
        state.registry = WebGPUImplTable(host: self, instance: instance)
        m_swiftState = UInt(bitPattern: unsafe Unmanaged.passRetained(state).toOpaque())
    }

    // Static, so that the destructor never retains the RemoteGPU it destroys.
    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        // Safety: swiftInitialize() retained the state at this address, and only the destructor releases it.
        _ = unsafe Unmanaged<RemoteGPUState>
            .fromOpaque(UnsafeRawPointer(bitPattern: swiftState) ?? noSwiftState())
            .takeRetainedValue()
    }

    @cxx
    @implementation
    func swiftBeginStopping() {
        state.scheduler.beginStopping()
    }

    @cxx
    @implementation
    func swiftRunScheduledWork(_ thenStopped: Bool) {
        state.scheduler.runWaitingWork(thenStopped: thenStopped)
    }

    // Destroys the devices that are still alive, so that their pending callbacks are called, empties the registry, and
    // releases it, and with it the registry's reference to this.
    @cxx
    @implementation
    func swiftUninitialize() {
        let state = self.state
        guard let registry = state.registry else {
            return
        }
        state.registry = nil
        registry.destroyDevices()
        registry.removeAll()
    }

    private var state: RemoteGPUState {
        precondition(m_swiftState != 0, "RemoteGPU has no Swift state")
        // Safety: m_swiftState is a retained RemoteGPUState from swiftInitialize() to the destructor.
        return unsafe Unmanaged<RemoteGPUState>
            .fromOpaque(UnsafeRawPointer(bitPattern: m_swiftState) ?? noSwiftState())
            .takeUnretainedValue()
    }

    // Only reached by messages, which come between workQueueInitialize() and swiftUninitialize().
    private var table: WebGPUImplTable {
        guard let registry = state.registry else {
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

private func noSwiftState<T>() -> T {
    preconditionFailure("RemoteGPU has no Swift state")
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
