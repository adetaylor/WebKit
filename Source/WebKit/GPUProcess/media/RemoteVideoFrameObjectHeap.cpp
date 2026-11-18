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

#include "config.h"
#include "RemoteVideoFrameObjectHeap.h"

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
#include "Connection.h"
#include "RemoteVideoFrameObjectHeapMessages.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WorkQueue.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteVideoFrameObjectHeap);

static WorkQueue& remoteVideoFrameObjectHeapQueueSingleton()
{
    static NeverDestroyed queue = WorkQueue::create("org.webkit.RemoteVideoFrameObjectHeap"_s, WorkQueue::QOS::UserInteractive);
    return queue.get();
}

Ref<RemoteVideoFrameObjectHeap> RemoteVideoFrameObjectHeap::create(Ref<IPC::Connection>&& connection)
{
    Ref heap = adoptRef(*new RemoteVideoFrameObjectHeap(WTF::move(connection)));
    heap->m_connection->addWorkQueueMessageReceiver(Messages::RemoteVideoFrameObjectHeap::messageReceiverName(), remoteVideoFrameObjectHeapQueueSingleton(), heap.get());
    return heap;
}

RemoteVideoFrameObjectHeap::RemoteVideoFrameObjectHeap(Ref<IPC::Connection>&& connection)
    : m_connection(WTF::move(connection))
    , m_swiftState(createSwiftState())
{
}

RemoteVideoFrameObjectHeap::~RemoteVideoFrameObjectHeap()
{
    ASSERT(m_isClosed);
    destroySwiftState(m_swiftState);
}

void RemoteVideoFrameObjectHeap::close()
{
    assertIsMainThread();

    if (m_isClosed)
        return;
    m_isClosed = true;

    protect(m_connection)->removeWorkQueueMessageReceiver(Messages::RemoteVideoFrameObjectHeap::messageReceiverName());
    swiftRemoveAll();
}

}

#endif
