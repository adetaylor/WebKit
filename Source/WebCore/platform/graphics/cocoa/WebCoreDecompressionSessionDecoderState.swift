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
internal import Foundation
internal import Synchronization
internal import VideoToolbox

/// A decompression session's VideoToolbox session owner and the state beside it that this class's lock guards.
///
/// Two regions hold the lock: ensureDecoder's, on the session's queue or on decodeSampleSync's thread, and
/// isHardwareAccelerated's, on any thread. ensureDecoder compares the format descriptions, checks the software
/// decoder, asks the session whether it accepts the new description, waits for its asynchronous frames, takes the old
/// owner out, resets the cached hardware acceleration, stores the format description, creates the new session and
/// installs its owner, resets the queue's state when it runs on the session's queue, and releases the old owner last.
/// Decodes do not hold this lock: they hold the owner ensureDecoder returned.
///
/// - pixelBufferAttributes: copied at creation; read by ensureDecoder.
/// - owner: ensureDecoder; isHardwareAccelerated, through owner and isUsingHardwareAcceleratedDecoder;
///   and the thread that destroys the decompression session.
/// - lastFormatDescription: ensureDecoder.
/// - isHardwareAccelerated: reset by ensureDecoder and set by isHardwareAccelerated.
final class DecoderState: @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private let pixelBufferAttributes: NSDictionary
    private var owner: VideoToolboxSessionOwner?
    private var lastFormatDescription: CMFormatDescription?
    private var isHardwareAccelerated: Bool?

    init(pixelBufferAttributes: NSDictionary) {
        self.pixelBufferAttributes = NSDictionary(dictionary: pixelBufferAttributes)
    }

    struct Locked: ~Copyable, ~Sendable {
        private let state: DecoderState

        fileprivate static func withLock<Result: Sendable>(_ state: DecoderState, _ body: (borrowing Locked) -> Result) -> Result {
            state.lock.withLock { _ in body(Locked(state: state)) }
        }

        var pixelBufferAttributes: NSDictionary { state.pixelBufferAttributes }
        var lastFormatDescription: CMFormatDescription? {
            get { state.lastFormatDescription }
            nonmutating set { state.lastFormatDescription = newValue }
        }
        var isHardwareAccelerated: Bool? {
            get { state.isHardwareAccelerated }
            nonmutating set { state.isHardwareAccelerated = newValue }
        }
        var owner: VideoToolboxSessionOwner? { state.owner }

        func canAccept(_ description: CMFormatDescription?) -> Bool {
            guard let owner = state.owner else {
                return false
            }
            return owner.withLock { $0.canAccept(description) }
        }
        func waitForAsynchronousFrames() -> OSStatus {
            guard let owner = state.owner else {
                return noErr
            }
            return owner.withLock { $0.waitForAsynchronousFrames() }
        }
        func isUsingHardwareAcceleratedDecoder() -> Bool {
            guard let owner = state.owner else {
                return false
            }
            return owner.withLock { $0.isUsingHardwareAcceleratedDecoder() }
        }
        func takeOwner() -> VideoToolboxSessionOwner? {
            state.owner.take()
        }
        func install(created session: VTDecompressionSession) {
            state.owner = VideoToolboxSessionOwner(session)
        }
    }

    func withLock<Result: Sendable>(_ body: (borrowing Locked) -> Result) -> Result {
        Locked.withLock(self, body)
    }
}

// Reflection would read the state without the lock.
extension DecoderState: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

#endif // ENABLE_WEBCORE_SWIFT
