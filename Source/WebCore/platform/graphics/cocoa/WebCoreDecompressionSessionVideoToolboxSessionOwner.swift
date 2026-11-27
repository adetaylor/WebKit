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

typealias MultiImageOutputHandler = @Sendable (OSStatus, UInt32, CVBuffer?, __CMTaggedBufferGroup?, CMTime, CMTime) -> Void
typealias SingleImageOutputHandler = @Sendable (OSStatus, UInt32, CVBuffer?, CMTime, CMTime) -> Void

/// A VideoToolbox decompression session, invalidated when the last reference to its owner goes.
///
/// Each VideoToolbox call on the session is one member of Locked, made holding the owner's lock and outside
/// DecoderState's. A decode holds a strong reference to the owner across its call, so the session is invalidated only
/// when no call can be running.
///
/// - session: set by init; every use is a member of Locked, and deinit.
///
/// The owner is created on the session's queue or on decodeSampleSync's thread. Its members are called as follows:
/// canAccept and waitForAsynchronousFrames by ensureDecoder, isUsingHardwareAcceleratedDecoder by isHardwareAccelerated
/// on any thread, setProperty and decodeMultiImageFrame by the session's queue, decodeFrame by decodeSampleSync's
/// thread. It is invalidated on the thread that drops the last reference.
final class VideoToolboxSessionOwner: @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private let session: VTDecompressionSession

    init(_ session: VTDecompressionSession) {
        self.session = session
    }

    deinit {
        lock.withLock { _ in VTDecompressionSessionInvalidate(session) }
    }

    struct Locked: ~Copyable, ~Sendable {
        private let owner: VideoToolboxSessionOwner

        fileprivate static func withLock<Result: Sendable>(
            _ owner: VideoToolboxSessionOwner,
            _ body: (borrowing Locked) -> Result
        ) -> Result {
            owner.lock.withLock { _ in body(Locked(owner: owner)) }
        }

        func canAccept(_ description: CMFormatDescription?) -> Bool {
            guard let description else {
                return false
            }
            return VTDecompressionSessionCanAcceptFormatDescription(owner.session, formatDescription: description)
        }
        func waitForAsynchronousFrames() -> OSStatus {
            VTDecompressionSessionWaitForAsynchronousFrames(owner.session)
        }
        func isUsingHardwareAcceleratedDecoder() -> Bool {
            WebCore.isUsingHardwareAcceleratedDecoder(owner.session)
        }
        func setProperty(_ key: CFString, _ value: CFTypeRef?) -> OSStatus {
            VTSessionSetProperty(owner.session, key: key, value: value)
        }
        func decodeMultiImageFrame(_ sample: CMSampleBuffer, _ flags: UInt32, _ handler: @escaping MultiImageOutputHandler) -> OSStatus {
            VTDecompressionSessionDecodeFrameWithMultiImageCapableOutputHandler(owner.session, sample, flags, nil, handler)
        }
        func decodeFrame(_ sample: CMSampleBuffer, _ flags: UInt32, _ handler: @escaping SingleImageOutputHandler) -> OSStatus {
            VTDecompressionSessionDecodeFrameWithOutputHandler(owner.session, sample, flags, nil, handler)
        }
    }

    func withLock<Result: Sendable>(_ body: (borrowing Locked) -> Result) -> Result {
        Locked.withLock(self, body)
    }
}

// Reflection would read the session without the lock.
extension VideoToolboxSessionOwner: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

#endif // ENABLE_WEBCORE_SWIFT
