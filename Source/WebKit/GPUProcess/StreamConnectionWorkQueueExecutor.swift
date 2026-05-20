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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS_SWIFT

// C bridges into IPC::StreamConnectionWorkQueue (StreamConnectionWorkQueue.cpp).
@_silgen_name("webKitStreamConnectionWorkQueueDispatch")
private func _streamQueueDispatch(
    _ queue: OpaquePointer,
    _ callback: @convention(c) @escaping (UnsafeMutableRawPointer?) -> Void,
    _ context: UnsafeMutableRawPointer?)

@_silgen_name("webKitStreamConnectionWorkQueueCheckIsolation")
private func _streamQueueCheckIsolation(_ queue: OpaquePointer)

// ---------------------------------------------------------------------------
// StreamConnectionWorkQueueExecutor
//
// Custom Swift SerialExecutor that runs enqueued jobs on the C++
// IPC::StreamConnectionWorkQueue thread.  Stream-receiver actor types use this
// as their unownedExecutor so that the Swift type system enforces the invariant
// "stream IPC handlers run on the stream-queue thread."
//
// End-state note: once IPC::StreamConnectionWorkQueue is converted to Swift
// (a separate, later undertaking), this executor will be replaced by a
// DispatchSerialQueue backed by the native dispatch_queue_t the Swift
// implementation will carry.  The executor is small enough that discarding it
// then is acceptable.
//
// Safety: the executor holds an *unowned* pointer to the queue.  The receiver
// actor that owns this executor is always torn down (via
// StreamServerConnection::stopReceivingMessages) before the connection (which
// owns the queue) is invalidated, so the pointer is valid for the executor's
// lifetime.
final class StreamConnectionWorkQueueExecutor: SerialExecutor, @unchecked Sendable {
    let queue: OpaquePointer

    init(queue: OpaquePointer) {
        self.queue = queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        // Box the move-only job and the target executor together so both can
        // travel through the C callback boundary as a single opaque pointer.
        let box = JobBox(UnownedJob(job), on: asUnownedSerialExecutor())
        let ptr = Unmanaged.passRetained(box).toOpaque()
        _streamQueueDispatch(queue, jobRunnerCallback, ptr)
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    nonisolated func checkIsolated() {
        _streamQueueCheckIsolation(queue)
    }
}

// Heap-allocated container that carries an UnownedJob and its target executor
// across the C callback boundary.
private final class JobBox: @unchecked Sendable {
    let job: UnownedJob
    let executor: UnownedSerialExecutor

    init(_ job: UnownedJob, on executor: UnownedSerialExecutor) {
        self.job = job
        self.executor = executor
    }
}

// Top-level C-compatible callback: no captures allowed, references only global
// types.  Called on the StreamConnectionWorkQueue thread.
private let jobRunnerCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { rawPtr in
    let box = Unmanaged<JobBox>.fromOpaque(rawPtr!).takeRetainedValue()
    box.job.runSynchronously(on: box.executor)
}

#endif // ENABLE_GPU_PROCESS_SWIFT
