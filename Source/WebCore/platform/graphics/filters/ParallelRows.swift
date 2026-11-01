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

#if ENABLE_WEBCORE_SWIFT

#if ENABLE_THREADING_LIBDISPATCH
import WebCore_Internal.ParallelRowsDispatch
#else
import Dispatch
#endif
import Synchronization

// Runs the jobs where WTF::ParallelJobs runs them: with libdispatch, on the default-priority global queue (concurrentPerform
// would use the caller's QoS). Neither dispatchParallelRowJobs's block nor concurrentPerform (@preconcurrency) makes
// Sendable capture errors hard errors; this @Sendable parameter does, for every caller.
private func concurrentJobs(_ count: Int, _ body: @Sendable (Int) -> Void) {
    #if ENABLE_THREADING_LIBDISPATCH
    WebCore.dispatchParallelRowJobs(count, body)
    #else
    DispatchQueue.concurrentPerform(iterations: count, execute: body)
    #endif
}

// Computes the rows 0 ..< height of `destination`, rowBytes bytes each from its first byte, with `body` on `jobs`
// disjoint blocks of rows; as in WTF::ParallelJobs, the first height % jobs blocks get one row more. Each call of `body`
// gets its block's rows and an `output` of exactly their bytes, and must write all of them (their initial contents are
// unspecified); it reads its inputs through the spans it captures. With more than one job the blocks run concurrently,
// each into its own buffer, and the buffers are then copied into `destination` on the calling thread; with one job
// `body` writes `destination` directly. Returns false, without running anything, when height * rowBytes overflows or
// doesn't fit in `destination`.
func parallelRows(
    height: Int,
    jobs: Int,
    rowBytes: Int,
    into destination: inout MutableSpan<UInt8>,
    body: @Sendable (_ rows: Range<Int>, _ output: inout MutableSpan<UInt8>) -> Void
) -> Bool {
    guard height >= 0, rowBytes >= 0, let byteCount = height.checkedMultiplied(by: rowBytes),
        byteCount <= destination.count
    else {
        return false
    }
    if byteCount == 0 {
        return true
    }

    let jobCount = max(1, min(jobs, height))
    if jobCount == 1 {
        withMutableSubspan(of: &destination, 0..<byteCount) { body(0..<height, &$0) }
        return true
    }

    let blockHeight = height / jobCount
    let remainder = height % jobCount
    let outputs = Mutex<[ContiguousArray<UInt8>]>(Array(repeating: [], count: jobCount))
    concurrentJobs(jobCount) { job in
        let start = job * blockHeight + min(job, remainder)
        let rows = start..<start + blockHeight + (job < remainder ? 1 : 0)
        var buffer = ContiguousArray<UInt8>(repeating: 0, count: rows.count * rowBytes)
        do {
            var output = buffer.mutableSpan
            body(rows, &output)
        }
        outputs.withLock { $0[job] = buffer }
    }

    var offset = 0
    outputs.withLock { outputs in
        for output in outputs {
            copyBytes(from: output.span, at: 0, to: &destination, at: offset, count: output.count)
            offset += output.count
        }
    }
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
