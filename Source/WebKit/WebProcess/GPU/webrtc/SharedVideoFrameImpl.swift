// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && WTF_PLATFORM_COCOA && ENABLE_VIDEO

import CoreVideo
// The safe Span overloads Swift synthesizes for the span accessors call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import Synchronization
import WebCore_Private
import WebKit_Internal
import os
import wtf

// RELEASE_LOG_ERROR(WebRTC, ...).
private var releaseLog: os.Logger {
    os.Logger(WTF.osLog(WebKit.LogChannel.WebRTC()))
}

// The protocol state of a SharedVideoFrameWriter: whether the reader has its semaphore yet, whether a write must signal it
// on failure, and whether writing is disabled.
@_expose(Cxx)
final class SharedVideoFrameWriterImpl {
    private var isSemaphoreInUse = false
    private var shouldSignalInCaseOfError = false
    // disable() sets it from another thread without taking any lock, so that a writer blocked waiting for the semaphore while
    // holding a lock (LibWebRTCCodecs' m_encodersConnectionLock) can be unblocked without deadlock.
    private let isDisabledFlag = Atomic<Bool>(false)

    @_expose(Cxx)
    init() {
    }

    @_expose(Cxx)
    func disable() {
        isDisabledFlag.store(true, ordering: .relaxed)
    }

    @_expose(Cxx)
    func isDisabled() -> Bool {
        isDisabledFlag.load(ordering: .relaxed)
    }

    @_expose(Cxx)
    func writePixelBuffer(_ pixelBuffer: CVPixelBuffer, _ context: inout WebKit.SharedVideoFrameWriterContext) -> Bool {
        let written = write(pixelBuffer, &context)
        if !written {
            signalInCaseOfError(&context)
        }
        return written
    }

    @_expose(Cxx)
    func prepareWriting(
        _ info: borrowing WebCore.SharedVideoFrameInfo,
        _ context: inout WebKit.SharedVideoFrameWriterContext
    ) -> Bool {
        guard info.isReadWriteSupported() else {
            releaseLog.error("SharedVideoFrameWriter::prepareWriting not supported")
            return false
        }

        guard wait(&context) else {
            releaseLog.error("SharedVideoFrameReader::writeBuffer wait failed")
            return false
        }
        shouldSignalInCaseOfError = true

        // size_t imports as Int; compare the sizes unsigned, as C++ does.
        let size = info.storageSize()
        if !context.hasStorage() || UInt(bitPattern: context.storageSize()) < UInt(bitPattern: size) {
            guard context.allocateStorage(size) else {
                releaseLog.error("SharedVideoFrameReader::writeBuffer allocation failed")
                return false
            }
        }
        return true
    }

    @_expose(Cxx)
    func signalInCaseOfError(_ context: inout WebKit.SharedVideoFrameWriterContext) {
        guard shouldSignalInCaseOfError else {
            return
        }
        shouldSignalInCaseOfError = false
        context.signalSemaphore()
    }

    private func write(_ pixelBuffer: CVPixelBuffer, _ context: inout WebKit.SharedVideoFrameWriterContext) -> Bool {
        var pixelBufferToWrite = pixelBuffer
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange {
            guard let converted = context.convertCompressedPixelBuffer(pixelBuffer) else {
                releaseLog.error("SharedVideoFrameWriter::writeBuffer cannot convert pixel buffer")
                return false
            }
            pixelBufferToWrite = converted
        }

        var info = WebCore.SharedVideoFrameInfo.fromCVPixelBuffer(pixelBufferToWrite)
        guard prepareWriting(info, &context) else {
            return false
        }

        var storage: MutableSpan<UInt8> = context.storageBytes()
        return info.writePixelBuffer(pixelBufferToWrite, &storage)
    }

    private func wait(_ context: inout WebKit.SharedVideoFrameWriterContext) -> Bool {
        if !isSemaphoreInUse {
            isSemaphoreInUse = true
            context.sendSemaphore()
            return true
        }
        return !isDisabled() && context.waitForSemaphore()
    }
}

// Reads the frames a SharedVideoFrameWriter put in shared memory, keeping a pixel buffer pool for the last frame format.
@_expose(Cxx)
final class SharedVideoFrameReaderImpl {
    private let shouldUseIOSurfaceBufferPool: Bool
    private var bufferPool: CVPixelBufferPool?
    private var bufferPoolType: OSType = 0
    private var bufferPoolWidth: UInt32 = 0
    private var bufferPoolHeight: UInt32 = 0

    @_expose(Cxx)
    init(useIOSurfaceBufferPool: Bool) {
        shouldUseIOSurfaceBufferPool = useIOSurfaceBufferPool
    }

    @_expose(Cxx)
    func usesIOSurfaceBufferPool() -> Bool {
        shouldUseIOSurfaceBufferPool
    }

    @_expose(Cxx)
    func readBufferFromSharedMemory(_ context: borrowing WebKit.SharedVideoFrameReaderContext) -> CVPixelBuffer? {
        guard context.hasStorage() else {
            releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory no storage")
            return nil
        }

        defer {
            context.signalSemaphore()
        }

        let data: Span<UInt8> = context.storageBytes()
        guard var info = WebCore.SharedVideoFrameInfo.decode(data).value else {
            releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory decoding failed")
            return nil
        }

        guard info.isReadWriteSupported() else {
            releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory not supported")
            return nil
        }

        // The header is the web process's: its storage size can exceed Int.max, so compare unsigned, as C++ does.
        guard UInt(data.count) >= UInt(bitPattern: info.storageSize()) else {
            releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory storage size mismatch")
            return nil
        }

        let pool = pixelBufferPool(info)
        let planes = data.extracting(droppingFirst: WebCore.SharedVideoFrameInfoEncodingLength)
        let result = WebKit.createSharedVideoFramePixelBuffer(&info, planes, pool)
        if let result, shouldUseIOSurfaceBufferPool {
            context.setOwnershipIdentity(result)
        }
        return result
    }

    private func pixelBufferPool(_ info: borrowing WebCore.SharedVideoFrameInfo) -> CVPixelBufferPool? {
        guard shouldUseIOSurfaceBufferPool else {
            return nil
        }

        let type = info.bufferType()
        let width = info.width()
        let height = info.height()
        if bufferPool == nil || bufferPoolType != type || bufferPoolWidth != width || bufferPoolHeight != height {
            bufferPoolType = type
            bufferPoolWidth = width
            bufferPoolHeight = height
            bufferPool = WebKit.createSharedVideoFrameBufferPool(info)
        }
        return bufferPool
    }
}

#endif // ENABLE_GPU_PROCESS && WTF_PLATFORM_COCOA && ENABLE_VIDEO
