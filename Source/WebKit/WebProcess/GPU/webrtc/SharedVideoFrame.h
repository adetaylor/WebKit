/*
 * Copyright (C) 2022, 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)

#include "IPCSemaphore.h"
#include "RemoteVideoFrameIdentifier.h"
#include <WebCore/IntSize.h>
#include <WebCore/PixelBufferConformerCV.h>
#include <WebCore/PlatformVideoColorSpace.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/SharedMemory.h>
#include <cstddef>
#include <wtf/MediaTime.h>
#include <wtf/RefPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>

typedef struct CF_BRIDGED_TYPE(id) __CVBuffer* CVPixelBufferRef;

namespace IPC {
class Connection;
}

namespace WebCore {
class VideoFrame;
enum class VideoFrameRotation : uint16_t;
}

namespace webrtc {
class VideoFrame;
class VideoFrameBuffer;
}

namespace WebKit {

class RemoteVideoFrameObjectHeapHandle;
#if !defined(__swift__)
class SharedVideoFrameReaderImpl;
class SharedVideoFrameWriterImpl;
#endif

struct SharedVideoFrame {
    MediaTime time;
    bool mirrored { false };
    WebCore::VideoFrameRotation rotation { };
    WebCore::PlatformVideoColorSpace colorSpace;
    bool shouldIgnoreAlpha { false };
    using Buffer = Variant<std::nullptr_t, RemoteVideoFrameReadReference, MachSendRight, WebCore::IntSize>;
    Buffer buffer;
};

class SharedVideoFrameWriter {
    WTF_MAKE_TZONE_ALLOCATED(SharedVideoFrameWriter);
public:
    SharedVideoFrameWriter();
    SharedVideoFrameWriter(SharedVideoFrameWriter&&);
    SharedVideoFrameWriter& operator=(SharedVideoFrameWriter&&);
    ~SharedVideoFrameWriter();

    // The IPC::Connection is the GPU process connection that the result is sent on, directly or through a stream
    // created on it. Writing a RemoteVideoFrameProxy of another connection fails.
    std::optional<SharedVideoFrame> write(const WebCore::VideoFrame&, const IPC::Connection&, NOESCAPE const Function<void(IPC::Semaphore&)>&, NOESCAPE const Function<void(WebCore::SharedMemory::Handle&&)>&);
    std::optional<SharedVideoFrame::Buffer> writeBuffer(CVPixelBufferRef, NOESCAPE const Function<void(IPC::Semaphore&)>&, NOESCAPE const Function<void(WebCore::SharedMemory::Handle&&)>&, bool canSendIOSurface = true);
#if USE(LIBWEBRTC)
    std::optional<SharedVideoFrame::Buffer> writeBuffer(const webrtc::VideoFrame&, const IPC::Connection&, NOESCAPE const Function<void(IPC::Semaphore&)>&, NOESCAPE const Function<void(WebCore::SharedMemory::Handle&&)>&);
#endif
    std::optional<SharedVideoFrame::Buffer> writeBuffer(const WebCore::VideoFrame&, const IPC::Connection&, NOESCAPE const Function<void(IPC::Semaphore&)>&, NOESCAPE const Function<void(WebCore::SharedMemory::Handle&&)>&);

    // Can be called from another thread, to unblock a writer waiting for the reader without taking its locks.
    void disable();
    bool isDisabled();

private:
    friend class SharedVideoFrameWriterContext;

    static constexpr Seconds defaultTimeout = 3_s;

#if USE(LIBWEBRTC)
    std::optional<SharedVideoFrame::Buffer> writeBuffer(webrtc::VideoFrameBuffer&, NOESCAPE const Function<void(IPC::Semaphore&)>&, NOESCAPE const Function<void(WebCore::SharedMemory::Handle&&)>&);
#endif

#if !defined(__swift__)
    SharedVideoFrameWriterImpl& swiftImpl() LIFETIME_BOUND;
#endif

    UniqueRef<IPC::Semaphore> m_semaphore;
    RefPtr<WebCore::SharedMemory> m_storage;
    // The storage that allocateStorage() replaced during a call into SharedVideoFrameWriterImpl, kept until the call returns.
    Vector<Ref<WebCore::SharedMemory>> m_retiredStorage;
    std::unique_ptr<WebCore::PixelBufferConformerCV> m_compressedPixelBufferConformer;
    // Storage for the Swift SharedVideoFrameWriterImpl (one strong reference), built in place in SharedVideoFrame.cpp, where
    // the generated header is visible.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

class SharedVideoFrameReader {
    WTF_MAKE_TZONE_ALLOCATED(SharedVideoFrameReader);
    WTF_MAKE_NONCOPYABLE(SharedVideoFrameReader);
public:
    ~SharedVideoFrameReader();

    enum class UseIOSurfaceBufferPool : bool { No, Yes };
    explicit SharedVideoFrameReader(RefPtr<RemoteVideoFrameObjectHeapHandle>&&, const WebCore::ProcessIdentity& = { }, UseIOSurfaceBufferPool = UseIOSurfaceBufferPool::Yes);
    SharedVideoFrameReader();

    void setSemaphore(IPC::Semaphore&& semaphore) { m_semaphore = WTF::move(semaphore); }
    bool setSharedMemory(WebCore::SharedMemory::Handle&&);

    RefPtr<WebCore::VideoFrame> read(SharedVideoFrame&&);
    RetainPtr<CVPixelBufferRef> readBuffer(SharedVideoFrame::Buffer&&);

private:
    friend class SharedVideoFrameReaderContext;

#if !defined(__swift__)
    SharedVideoFrameReaderImpl& swiftImpl() LIFETIME_BOUND;
#endif

    const RefPtr<RemoteVideoFrameObjectHeapHandle> m_objectHeap;
    WebCore::ProcessIdentity m_resourceOwner;
    std::optional<IPC::Semaphore> m_semaphore;
    RefPtr<WebCore::SharedMemory> m_storage;
    WebCore::IntSize m_blackFrameSize;
    RetainPtr<CVPixelBufferRef> m_blackFrame;
    // Storage for the Swift SharedVideoFrameReaderImpl (one strong reference), built in place in SharedVideoFrame.cpp, where
    // the generated header is visible.
    alignas(void*) std::byte m_impl[sizeof(void*)];
};

}

#endif
