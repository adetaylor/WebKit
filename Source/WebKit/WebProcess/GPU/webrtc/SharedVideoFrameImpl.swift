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
@_spi(WebKitGPU) internal import WebCore
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

// Reads the frames that a SharedVideoFrameWriter shares: from the shared memory it writes them into, keeping a pixel buffer
// pool for the last frame format; from the GPU process's video frame heap; from an IOSurface; or as a black frame.
@_expose(Cxx)
final class SharedVideoFrameSource {
    private let heap: WebKit.RemoteVideoFrameObjectHeap?
    // The process that the pixel buffers read out of shared memory are attributed to, if it isn't this one.
    private let resourceOwner: WebCore.ProcessIdentity?
    private let shouldUseIOSurfaceBufferPool: Bool
    private var semaphore: IPCTypes.Semaphore?
    private var storage: IPCTypes.ReadOnlySharedMemory?
    private var bufferPool: CVPixelBufferPool?
    private var bufferPoolFormat: (pixelFormat: OSType, width: UInt32, height: UInt32) = (0, 0, 0)
    private var blackFrame: CVPixelBuffer?
    private var blackFrameSize: (width: Int32, height: Int32) = (0, 0)

    @_expose(Cxx)
    init(
        heap: borrowing WebKit.RemoteVideoFrameObjectHeap?,
        resourceOwner: borrowing WebCore.ProcessIdentity,
        hasResourceOwner: Bool,
        useIOSurfaceBufferPool: Bool
    ) {
        self.heap = copy heap
        self.resourceOwner = hasResourceOwner ? copy resourceOwner : nil
        shouldUseIOSurfaceBufferPool = useIOSurfaceBufferPool
    }

    // Each takes a right of its own to the port that the caller's IPC::Semaphore or SharedMemory::Handle owns.
    @_expose(Cxx)
    func setSemaphore(_ port: mach_port_t) {
        semaphore = IPCTypes.Semaphore(copying: port)
    }

    @_expose(Cxx)
    func setSharedMemory(_ port: mach_port_t, _ size: UInt64) -> Bool {
        storage = IPCTypes.SharedMemoryHandle(copying: port, size: size).mapReadOnly()
        return storage != nil
    }

    // Returned +1.
    @_expose(Cxx)
    func readBuffer(_ buffer: WebKit.SharedVideoFrameBufferTag) -> CVPixelBuffer? {
        switch buffer.kind {
        case .SharedMemory:
            return readBufferFromSharedMemory()
        case .HeapReference:
            return readBufferFromHeap(identifier: buffer.identifier, version: buffer.version)
        case .IOSurface:
            return WebKit.createSharedVideoFramePixelBuffer(buffer.port)
        case .BlackFrame:
            return blackPixelBuffer(width: buffer.width, height: buffer.height)
        @unknown default:
            return nil
        }
    }

    private func readBufferFromHeap(identifier: UInt64, version: UInt64) -> CVPixelBuffer? {
        guard let heap else {
            assertionFailure()
            releaseLog.error("SharedVideoFrameReader::readBuffer no object heap")
            return nil
        }
        guard let pixelBuffer = heap.readPixelBuffer(identifier: identifier, version: version) else {
            releaseLog.error("SharedVideoFrameReader::readBuffer no sample")
            return nil
        }
        return pixelBuffer
    }

    private func readBufferFromSharedMemory() -> CVPixelBuffer? {
        guard let storage else {
            releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory no storage")
            return nil
        }

        defer {
            semaphore?.signal()
        }

        let headerSize = WebCore.SharedVideoFrameInfoEncodingLength
        return storage.withBytes { bytes -> CVPixelBuffer? in
            guard let header = SharedVideoFrameHeader(decoding: bytes, headerSize: headerSize) else {
                releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory decoding failed")
                return nil
            }

            guard header.isReadWriteSupported else {
                releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory not supported")
                return nil
            }

            // The header is the web process's: its storage size can exceed Int.max, so compare unsigned, as C++ does.
            guard UInt(bytes.byteCount) >= header.storageSize(headerSize: headerSize) else {
                releaseLog.error("SharedVideoFrameReader::readBufferFromSharedMemory storage size mismatch")
                return nil
            }

            let result = header.createPixelBuffer(bytes, headerSize: headerSize, pool: pixelBufferPool(header))
            if let result, shouldUseIOSurfaceBufferPool {
                setOwnershipIdentity(result)
            }
            return result
        }
    }

    private func pixelBufferPool(_ header: SharedVideoFrameHeader) -> CVPixelBufferPool? {
        guard shouldUseIOSurfaceBufferPool else {
            return nil
        }

        let format = (pixelFormat: header.pixelFormat, width: header.width, height: header.height)
        if bufferPool == nil || bufferPoolFormat != format {
            bufferPoolFormat = format
            bufferPool = WebKit.createSharedVideoFrameBufferPool(format.width, format.height, format.pixelFormat)
        }
        return bufferPool
    }

    private func blackPixelBuffer(width: Int32, height: Int32) -> CVPixelBuffer? {
        if blackFrameSize != (width, height) {
            blackFrameSize = (width, height)
            blackFrame = WebKit.createSharedVideoFrameBlackPixelBuffer(width, height, shouldUseIOSurfaceBufferPool)
            if let blackFrame, shouldUseIOSurfaceBufferPool {
                setOwnershipIdentity(blackFrame)
            }
        }
        return blackFrame
    }

    private func setOwnershipIdentity(_ pixelBuffer: CVPixelBuffer) {
        if let resourceOwner {
            WebCore.setOwnershipIdentityForCVPixelBuffer(pixelBuffer, resourceOwner)
        }
    }
}

#endif // ENABLE_GPU_PROCESS && WTF_PLATFORM_COCOA && ENABLE_VIDEO
