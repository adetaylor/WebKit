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

// The Swift delegate of a WebCore adapter (a C++ class that implements one of WebCore's client interfaces, whose overrides
// Swift implements with @cxx @implementation): a box that the adapter holds, as an Unmanaged retained pointer, from its
// creation to its destruction. The box loads the delegate with the closure it was made with, which holds it weakly
// (`{ [weak delegate] in delegate }`, for a delegate that owns the adapter) or strongly (`{ delegate }`).
//
// Invariant: an adapter's factory and its @cxx implementations must name the same Box type, since loadDelegate() and
// release() take the pointer to be a box of their own type. Declare a typealias next to the factory and use it in both.
final class SwiftDelegateBox<Delegate> {
    private let delegate: () -> Delegate?

    private init(_ delegate: @escaping () -> Delegate?) {
        self.delegate = delegate
    }

    static func retained(_ delegate: @escaping () -> Delegate?) -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(SwiftDelegateBox(delegate)).toOpaque())
    }

    // Unsafe: the box must be one that retained() made, of this type, and not yet released.
    @unsafe
    static func loadDelegate(_ box: UInt) -> Delegate? {
        unsafe Unmanaged<SwiftDelegateBox>.fromOpaque(address(box)).takeUnretainedValue().delegate()
    }

    // Unsafe: the box must be one that retained() made, of this type, released once.
    @unsafe
    static func release(_ box: UInt) {
        unsafe Unmanaged<SwiftDelegateBox>.fromOpaque(address(box)).release()
    }

    private static func address(_ box: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: box) else {
            preconditionFailure("The adapter has no delegate box")
        }
        return unsafe address
    }
}
