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

private import Cxx
import Synchronization
import WebCore_Private.Core.CARingBufferSwiftBridge

// The audited `unsafe` of WebCore's CoreAudio glue: memory that C++ or CoreAudio hands over as pointers, and the atomics
// shared with other threads and processes. Everything else in the glue is safe Swift over what this file lends it.
//
// Code that can run on an audio IO thread is written so that it needs no Swift runtime even at -Onone: no generics,
// closures, globals, classes or Optional payloads of classes; while loops; and memmove, memset and atomics only.

// MARK: The bounds of a ring

// The bounds of a ring are in a 32-byte, 8-byte-aligned header (CARingBufferBoundsStorage): a sequence count, then the
// bounds' startFrame, endFrame and writeAhead. All four words are only ever accessed atomically, because the writer can be
// another process. The writer makes the count odd, stores the bounds and makes the count even again; a reader keeps a copy
// of the bounds that it read between two loads of the same even count.
//
// This is the sequence lock of H.-J. Boehm, "Can Seqlocks Get Along with Programming Language Memory Models?" (HP
// Laboratories, HPL-2012-68, 2012), with its fences:
// - the reader loads the count with acquire ordering, the bounds relaxed, then has an acquire fence before it loads the
//   count again, relaxed. If the reader saw any store of a later write, the fence makes the second load see that write's
//   odd count, or a later count;
// - the writer stores the odd count relaxed and has a release fence before it stores the bounds relaxed, then stores the
//   even count with release ordering, so a reader that sees the even count sees the bounds.
//
// A writer in another process can keep the count odd, or change it all the time, so a reader gives up after
// ringBoundsLoadAttempts attempts and takes the last copy it read. Its callers clamp what they read to the ring.

private var ringHeaderByteCount: Int { 32 }

private var ringBoundsLoadAttempts: Int { 64 }

@inline(__always)
private func ringHeaderWord(_ header: UnsafeRawPointer, _ index: Int) -> UnsafePointer<Atomic<UInt64>> {
    unsafe header.advanced(by: index &* 8).assumingMemoryBound(to: Atomic<UInt64>.self)
}

// The bounds a ring's writer stored, from a header at an address that C++ or the attachment of an audio unit vouches for.
func loadRingBounds(at header: UnsafeRawPointer) -> WebCore.CARingBufferBounds {
    var bounds = WebCore.CARingBufferBounds()
    var attempt = 0
    while attempt < ringBoundsLoadAttempts {
        let sequence = unsafe ringHeaderWord(header, 0).pointee.load(ordering: .acquiring)
        bounds.startFrame = unsafe ringHeaderWord(header, 1).pointee.load(ordering: .relaxed)
        bounds.endFrame = unsafe ringHeaderWord(header, 2).pointee.load(ordering: .relaxed)
        bounds.writeAhead = unsafe ringHeaderWord(header, 3).pointee.load(ordering: .relaxed)
        atomicMemoryFence(ordering: .acquiring)
        let sequenceAfter = unsafe ringHeaderWord(header, 0).pointee.load(ordering: .relaxed)
        if sequence == sequenceAfter && sequence & 1 == 0 {
            return bounds
        }
        attempt &+= 1
    }
    return bounds
}

private func storeRingBounds(at header: UnsafeMutableRawPointer, _ bounds: WebCore.CARingBufferBounds) {
    let sequence = unsafe ringHeaderWord(header, 0).pointee.load(ordering: .relaxed)
    unsafe ringHeaderWord(header, 0).pointee.store(sequence &+ 1, ordering: .relaxed)
    atomicMemoryFence(ordering: .releasing)
    unsafe ringHeaderWord(header, 1).pointee.store(bounds.startFrame, ordering: .relaxed)
    unsafe ringHeaderWord(header, 2).pointee.store(bounds.endFrame, ordering: .relaxed)
    unsafe ringHeaderWord(header, 3).pointee.store(bounds.writeAhead, ordering: .relaxed)
    unsafe ringHeaderWord(header, 0).pointee.store(sequence &+ 2, ordering: .releasing)
}

// Traps unless the header is whole and aligned for its atomics.
@inline(__always)
private func checkRingHeader(_ address: UnsafeRawPointer?, _ byteCount: Int) -> UnsafeRawPointer {
    precondition(byteCount >= ringHeaderByteCount)
    guard let address = unsafe address else {
        preconditionFailure()
    }
    precondition(Int(bitPattern: address) & 7 == 0)
    return unsafe address
}

// The bounds stored in the header of a ring that a C++ view lends.
func loadRingBounds(_ header: Span<UInt8>) -> WebCore.CARingBufferBounds {
    header.withUnsafeBytes { bytes in
        unsafe loadRingBounds(at: checkRingHeader(bytes.baseAddress, bytes.count))
    }
}

// Stores bounds in the header of a ring that a C++ view lends.
func storeRingBounds(_ header: inout MutableSpan<UInt8>, _ bounds: WebCore.CARingBufferBounds) {
    header.withUnsafeMutableBytes { bytes in
        let address = unsafe checkRingHeader(UnsafeRawPointer(bytes.baseAddress), bytes.count)
        unsafe storeRingBounds(at: UnsafeMutableRawPointer(mutating: address), bounds)
    }
}

// CARingBuffer::getFetchTimeBounds(), which may run on any thread, so it doesn't make a view.
@_expose(Cxx)
func caRingBufferFetchTimeBounds(
    _ geometry: WebCore.CARingBufferGeometry,
    _ header: UnsafePointer<WebCore.CARingBufferBoundsStorage>
) -> WebCore.CARingBufferBounds {
    let address = unsafe checkRingHeader(UnsafeRawPointer(header), ringHeaderByteCount)
    return caRingBufferFetchBounds(geometry, unsafe loadRingBounds(at: address))
}

#endif // ENABLE_WEBCORE_SWIFT
