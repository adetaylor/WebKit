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

/// What one decode call's output handler collects.
///
/// That is the frames and their count, whether the call is settled and with which error, and the tag collections and
/// image description it decodes with. A synchronous decode collects its image buffers in outputs instead.
///
/// The frames, count, settled state and error are reached on VideoToolbox's output thread for each output, and on the
/// session's queue when a decode is rejected and when alpha frames are joined and composited. The tag collections and
/// the image description are set on the session's queue when the decode starts, and read and set on VideoToolbox's
/// output thread. The outputs are appended on VideoToolbox's output thread and taken on decodeSampleSync's thread.
final class SampleHandoff: @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private var frames: [CMSampleBuffer?] = []
    private var outputs: [CVBuffer] = []
    private var received = 0
    private var settled = false
    private var rejection: OSStatus?
    private var tagCollections: [__CMTagCollection]?
    private var currentImageDescription: CMFormatDescription?

    struct Locked: ~Copyable, ~Sendable {
        private let state: SampleHandoff

        fileprivate static func withLock<Result: Sendable>(_ state: SampleHandoff, _ body: (borrowing Locked) -> Result) -> Result {
            state.lock.withLock { _ in body(Locked(state: state)) }
        }

        var isSettled: Bool { state.settled }
        var rejection: OSStatus? { state.rejection }
        var tagCollections: [__CMTagCollection]? {
            get { state.tagCollections }
            nonmutating set { state.tagCollections = newValue }
        }
        var currentImageDescription: CMFormatDescription? {
            get { state.currentImageDescription }
            nonmutating set { state.currentImageDescription = newValue }
        }

        func reserve(_ count: Int) {
            state.frames.reserveCapacity(count)
        }
        /// Returns the number of frames received so far.
        func append(_ frame: CMSampleBuffer?) -> Int {
            state.frames.append(frame)
            state.received += 1
            return state.received
        }
        func settle(rejecting status: OSStatus? = nil) {
            state.settled = true
            state.rejection = status
        }
        func appendOutput(_ imageBuffer: CVBuffer?) {
            if let imageBuffer {
                state.outputs.append(imageBuffer)
            }
        }
        func takeOutputs() -> [CVBuffer] {
            exchange(&state.outputs, with: [])
        }
        func takeFrames() -> [CMSampleBuffer?] {
            exchange(&state.frames, with: [])
        }
    }

    func withLock<Result: Sendable>(_ body: (borrowing Locked) -> Result) -> Result {
        Locked.withLock(self, body)
    }
}

// Reflection would read the state without the lock.
extension SampleHandoff: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

#endif // ENABLE_WEBCORE_SWIFT
