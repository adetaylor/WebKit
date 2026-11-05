/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
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

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)

#include "RemoteVideoFrameIdentifier.h"
#include "RemoteVideoFrameProxy.h"
#include <memory>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace IPC {
class Connection;
}

namespace WebCore {
class VideoFrame;
}

namespace WebKit {

class RemoteVideoFrameObjectHeap;
class RemoteVideoFrameObjectHeapPlatform;

// The C++ face of RemoteVideoFrameObjectHeap.swift, for the GPU-process classes in C++ that lend video frames to the web
// process and that read the frames it refers to.
// FIXME: Remove it once they are in Swift.
class RemoteVideoFrameObjectHeapHandle final : public ThreadSafeRefCounted<RemoteVideoFrameObjectHeapHandle> {
public:
    static Ref<RemoteVideoFrameObjectHeapHandle> create(Ref<IPC::Connection>&&);
    ~RemoteVideoFrameObjectHeapHandle();

    void close();
    // Adds `frame` under a newly generated reference.
    RemoteVideoFrameReference add(Ref<WebCore::VideoFrame>&&);
    // Adds `frame` under `reference`.
    void add(RemoteVideoFrameReference, Ref<WebCore::VideoFrame>&&);
    RefPtr<WebCore::VideoFrame> get(RemoteVideoFrameReadReference&&);

    void stopListeningForIPC(Ref<RemoteVideoFrameObjectHeapHandle>&&) { close(); }
    void lowMemoryHandler();

private:
    explicit RemoteVideoFrameObjectHeapHandle(Ref<RemoteVideoFrameObjectHeapPlatform>&&);

    const Ref<RemoteVideoFrameObjectHeapPlatform> m_platform;
    const std::unique_ptr<RemoteVideoFrameObjectHeap> m_heap;
};

}

#endif
