/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <wtf/Platform.h>

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)

#include <WebCore/SharedVideoFrameInfo.h>
#include <mach/mach_types.h>
#include <span>
#include <wtf/Compiler.h>
#include <wtf/Function.h>
#include <wtf/SwiftBridging.h>

namespace IPC {
class Semaphore;
}

namespace WebCore {
class SharedMemoryHandle;
}

namespace WebKit {

class SharedVideoFrameWriter;

// What SharedVideoFrameWriterImpl can do with its SharedVideoFrameWriter's semaphore, storage, pixel buffer conformer and
// callbacks, for the duration of one call.
class SWIFT_VIEW SWIFT_SAFE SharedVideoFrameWriterContext {
public:
    SharedVideoFrameWriterContext(SharedVideoFrameWriter& writer LIFETIME_BOUND, const Function<void(IPC::Semaphore&)>& newSemaphoreCallback LIFETIME_BOUND, const Function<void(WebCore::SharedMemoryHandle&&)>& newMemoryCallback LIFETIME_BOUND);

    void sendSemaphore() const;
    bool waitForSemaphore() const;
    void signalSemaphore() const;

    bool hasStorage() const;
    size_t storageSize() const;
    // Replaces the storage and sends the reader a handle to it. The writer keeps the storage it replaces until the call
    // into Swift returns, so storageBytes() views of it stay valid.
    bool allocateStorage(size_t);
    std::span<uint8_t> storageBytes() LIFETIME_BOUND;

    CVPixelBufferRef convertCompressedPixelBuffer(CVPixelBufferRef) const CF_RETURNS_RETAINED;

private:
    SharedVideoFrameWriter& m_writer;
    const Function<void(IPC::Semaphore&)>& m_newSemaphoreCallback;
    const Function<void(WebCore::SharedMemoryHandle&&)>& m_newMemoryCallback;
};

enum class SharedVideoFrameBufferKind : uint8_t {
    SharedMemory,
    HeapReference,
    IOSurface,
    BlackFrame,
};

// A SharedVideoFrame::Buffer, for SharedVideoFrameSource: the identifier and version of a heap reference, the port of an
// IOSurface send right that the caller keeps until the read returns, or the size of a black frame.
struct SharedVideoFrameBufferTag {
    SharedVideoFrameBufferKind kind { SharedVideoFrameBufferKind::SharedMemory };
    uint64_t identifier { 0 };
    uint64_t version { 0 };
    mach_port_t port { MACH_PORT_NULL };
    int32_t width { 0 };
    int32_t height { 0 };
};

// The CVUtilities pixel buffers that SharedVideoFrameSource reads frames into.
CVPixelBufferPoolRef createSharedVideoFrameBufferPool(uint32_t width, uint32_t height, OSType pixelFormat) CF_RETURNS_RETAINED;
// The pixel buffer of the IOSurface that `port` names.
CVPixelBufferRef createSharedVideoFramePixelBuffer(mach_port_t) CF_RETURNS_RETAINED;
CVPixelBufferRef createSharedVideoFrameBlackPixelBuffer(int32_t width, int32_t height, bool shouldUseIOSurface) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)
