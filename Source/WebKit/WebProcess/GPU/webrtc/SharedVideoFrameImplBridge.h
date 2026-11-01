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

class SharedVideoFrameReader;
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
    // Replaces the storage and sends the reader a handle to it. Non-const, so that Swift can't keep a storageBytes() view
    // across it.
    bool allocateStorage(size_t);
    std::span<uint8_t> storageBytes() LIFETIME_BOUND;

    CVPixelBufferRef convertCompressedPixelBuffer(CVPixelBufferRef) const CF_RETURNS_RETAINED;

private:
    SharedVideoFrameWriter& m_writer;
    const Function<void(IPC::Semaphore&)>& m_newSemaphoreCallback;
    const Function<void(WebCore::SharedMemoryHandle&&)>& m_newMemoryCallback;
};

// What SharedVideoFrameReaderImpl can do with its SharedVideoFrameReader's semaphore, storage and resource owner, for the
// duration of one call.
class SWIFT_VIEW SWIFT_SAFE SharedVideoFrameReaderContext {
public:
    explicit SharedVideoFrameReaderContext(SharedVideoFrameReader& reader LIFETIME_BOUND);

    bool hasStorage() const;
    std::span<const uint8_t> storageBytes() const LIFETIME_BOUND;
    void signalSemaphore() const;
    void setOwnershipIdentity(CVPixelBufferRef) const;

private:
    SharedVideoFrameReader& m_reader;
};

// SharedVideoFrameInfo's RetainPtr results, which Swift can't take over.
CVPixelBufferPoolRef createSharedVideoFrameBufferPool(const WebCore::SharedVideoFrameInfo&) CF_RETURNS_RETAINED;
CVPixelBufferRef createSharedVideoFramePixelBuffer(WebCore::SharedVideoFrameInfo&, NOESCAPE std::span<const uint8_t> planes, CVPixelBufferPoolRef) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)
