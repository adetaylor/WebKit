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

#include "config.h"
#include "GPUVideoFrameSource.h"

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)

#include "GPUConnectionToWebProcess.h"
#include "IPCSemaphore.h"
#include "RemoteVideoFrameObjectHeap.h"
#include "SharedVideoFrame.h"
#include <WebCore/MediaPlayer.h>
#include <WebCore/VideoFrame.h>

namespace WebKit {

Ref<GPUVideoFrameSource> GPUVideoFrameSource::create(GPUConnectionToWebProcess& connection)
{
    // A frame shared across is usually a reference into the video frame object heap, and the web process's identity
    // attributes any buffer read out of shared memory.
    auto reader = makeUnique<SharedVideoFrameReader>(RefPtr<RemoteVideoFrameObjectHeap> { &connection.videoFrameObjectHeap() }, connection.webProcessIdentity());
    return adoptRef(*new GPUVideoFrameSource(connection, WTF::move(reader)));
}

GPUVideoFrameSource::GPUVideoFrameSource(GPUConnectionToWebProcess& connection, std::unique_ptr<SharedVideoFrameReader>&& reader)
    : m_connection(connection)
    , m_reader(WTF::move(reader))
{
}

GPUVideoFrameSource::~GPUVideoFrameSource() = default;

void GPUVideoFrameSource::setSemaphore(mach_port_t semaphore)
{
    m_reader->setSemaphore(IPC::Semaphore { MachSendRight::create(semaphore) });
}

void GPUVideoFrameSource::setSharedMemory(mach_port_t memory, uint64_t size)
{
    m_reader->setSharedMemory({ MachSendRight::create(memory), size });
}

static CVBufferRef takeFrame(RefPtr<WebCore::VideoFrame>&& videoFrame, GPUVideoFrameReadResult& result)
{
    if (!videoFrame)
        return nullptr;
    result.rotation = static_cast<uint16_t>(videoFrame->rotation());
    result.isMirrored = videoFrame->isMirrored();
    return RetainPtr { videoFrame->pixelBuffer() }.leakRef();
}

CVBufferRef readSharedVideoFrame(GPUVideoFrameSource& source, IPC::CxxDecodedArgument<std::optional<SharedVideoFrame>>& argument, GPUVideoFrameReadResult& result)
{
    result = { };
    auto sharedFrame = argument.take();
    if (!sharedFrame) {
        result.isInvalid = true;
        return nullptr;
    }
    if (!*sharedFrame)
        return nullptr;
    result.hadFrame = true;
    return takeFrame(source.m_reader->read(WTF::move(**sharedFrame)), result);
}

CVBufferRef copyMediaPlayerFrame(GPUVideoFrameSource& source, uint64_t mediaPlayerIdentifier, GPUVideoFrameReadResult& result)
{
    result = { };
    RefPtr connection = source.m_connection.get();
    if (!connection)
        return nullptr;
    result.hadFrame = true;
    CVBufferRef pixelBuffer = nullptr;
    connection->performWithMediaPlayerOnMainThread(WebCore::MediaPlayerIdentifier { mediaPlayerIdentifier }, [&](auto& player) mutable {
        pixelBuffer = takeFrame(player.videoFrameForCurrentTime(), result);
    });
    return pixelBuffer;
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)
