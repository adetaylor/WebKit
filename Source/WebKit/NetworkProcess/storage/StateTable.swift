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

import Synchronization

/// The Swift state of each live object of one C++ class, keyed by the object's `swiftKey()`.
struct StateTable<State>: ~Copyable, Sendable {
    private let states = Mutex<[UInt64: State]>([:])

    func insert(for key: UInt64, _ makeState: () -> sending State) {
        states.withLock { $0[key] = makeState() }
    }

    /// Removes the state stored for `key` and returns it, so that it is released after the lock.
    func take(for key: UInt64) -> State? where State: Sendable {
        states.withLock { $0.removeValue(forKey: key) }
    }

    /// Removes the state stored for `key`, releasing it inside the lock, for a state that isn't Sendable.
    func remove(for key: UInt64) {
        states.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Calls `body` with the state stored for `key`, in place, while the lock is held.
    func withState<Result: Sendable>(for key: UInt64, _ body: (inout State) -> Result) -> Result
    where State: Sendable {
        states.withLock { states in
            // swift-format-ignore: NeverForceUnwrap
            body(&states[key]!)
        }
    }

    /// Calls `body` with the state stored for `key`, in place, while the lock is held, for a state that isn't Sendable.
    func withState<Result>(for key: UInt64, _ body: (inout sending State) -> sending Result) -> sending Result {
        states.withLock { states in
            // swift-format-ignore: NeverForceUnwrap
            body(&states[key]!)
        }
    }
}
