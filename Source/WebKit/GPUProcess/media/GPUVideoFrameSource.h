/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)

#include "SwiftCoding.h"
#include <CoreVideo/CVBuffer.h>
#include <memory>
#include <optional>
#include <wtf/Compiler.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebKit {

class GPUConnectionToWebProcess;
class SharedVideoFrameReader;
struct SharedVideoFrame;

// How a GPUVideoFrameSource read went, and the display transform of the frame it read, which the frame's pixel buffer
// doesn't carry: a horizontal mirror, then a clockwise rotation in degrees (WebCore::VideoFrameRotation).
struct GPUVideoFrameReadResult {
    // The argument didn't decode.
    bool isInvalid { false };
    // There was a frame to read: a shared frame in the argument, or a connection to ask the media player.
    bool hadFrame { false };
    uint16_t rotation { 0 };
    bool isMirrored { false };
};

// The video frames that a web process shares with a GPU process receiver written in Swift, read with a
// SharedVideoFrameReader over the connection's video frame heap with the web process's identity, and the frames that its
// media players show.
class GPUVideoFrameSource final : public RefCounted<GPUVideoFrameSource> {
public:
    static Ref<GPUVideoFrameSource> create(GPUConnectionToWebProcess&);

    ~GPUVideoFrameSource();

    // Each takes a right of its own to the port that the receiver's IPCTypes.Semaphore or SharedMemoryHandle owns.
    void setSemaphore(mach_port_t);
    void setSharedMemory(mach_port_t, uint64_t size);

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<GPUVideoFrameSource>::ref(); }
    void deref() const { RefCounted<GPUVideoFrameSource>::deref(); }
#endif

private:
    friend CVBufferRef WTF_NULLABLE readSharedVideoFrame(GPUVideoFrameSource&, IPC::CxxDecodedArgument<std::optional<SharedVideoFrame>>&, GPUVideoFrameReadResult&) CF_RETURNS_RETAINED;
    friend CVBufferRef WTF_NULLABLE copyMediaPlayerFrame(GPUVideoFrameSource&, uint64_t mediaPlayerIdentifier, GPUVideoFrameReadResult&) CF_RETURNS_RETAINED;

    GPUVideoFrameSource(GPUConnectionToWebProcess&, std::unique_ptr<SharedVideoFrameReader>&&);

    const ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_connection;
    const std::unique_ptr<SharedVideoFrameReader> m_reader;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// The pixel buffer of the shared frame the argument holds, if it has one and it can be read. Free functions, since Swift
// takes what a C++ method returns as unretained; CVBufferRef, which Swift takes as CoreVideo's type whatever typedef of
// CVPixelBufferRef a header has seen.
CVBufferRef WTF_NULLABLE readSharedVideoFrame(GPUVideoFrameSource&, IPC::CxxDecodedArgument<std::optional<SharedVideoFrame>>&, GPUVideoFrameReadResult&) CF_RETURNS_RETAINED;
// The pixel buffer of the frame the media player shows now, which the main thread reads.
CVBufferRef WTF_NULLABLE copyMediaPlayerFrame(GPUVideoFrameSource&, uint64_t mediaPlayerIdentifier, GPUVideoFrameReadResult&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)
