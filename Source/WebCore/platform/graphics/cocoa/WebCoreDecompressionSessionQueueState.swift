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

internal import CoreMedia
internal import CoreVideo
internal import Synchronization

/// A decompression session's MV-HEVC tag collections and WebM alpha merge state, which only its queue uses.
///
/// Every member is reached on the session's queue only: reset by ensureDecoder there, the tag collections
/// stored by the output handler's hop and copied when a decode starts, and the merge state used to composite alpha onto
/// the color frames.
final class QueueState: @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private var tagCollections: [__CMTagCollection]?
    private var mergedPixelBufferPool: CVPixelBufferPool?
    private var mergedFormatDescription: CMFormatDescription?
    private var mergedSourceFormatDescription: CMFormatDescription?

    struct Locked: ~Copyable, ~Sendable {
        private let state: QueueState

        fileprivate static func withLock<Result: Sendable>(_ state: QueueState, _ body: (borrowing Locked) -> Result) -> Result {
            state.lock.withLock { _ in body(Locked(state: state)) }
        }

        var tagCollections: [__CMTagCollection]? {
            get { state.tagCollections }
            nonmutating set { state.tagCollections = newValue }
        }
        var mergedPixelBufferPool: CVPixelBufferPool? {
            get { state.mergedPixelBufferPool }
            nonmutating set { state.mergedPixelBufferPool = newValue }
        }
        var mergedFormatDescription: CMFormatDescription? {
            get { state.mergedFormatDescription }
            nonmutating set { state.mergedFormatDescription = newValue }
        }
        var mergedSourceFormatDescription: CMFormatDescription? {
            get { state.mergedSourceFormatDescription }
            nonmutating set { state.mergedSourceFormatDescription = newValue }
        }
    }

    func withLock<Result: Sendable>(_ body: (borrowing Locked) -> Result) -> Result {
        Locked.withLock(self, body)
    }
}

// Reflection would read the state without the lock.
extension QueueState: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

#endif // ENABLE_WEBCORE_SWIFT
