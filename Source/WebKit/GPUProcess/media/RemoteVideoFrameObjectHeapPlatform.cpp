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
#include "RemoteVideoFrameObjectHeapPlatform.h"

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
#include "Connection.h"
#include "IPCUtilities.h"
#include "Logging.h"
#include "ObjectIdentifierDomains.h"
#include "RemoteVideoFrameObjectHeapMessages.h"
#include "RemoteVideoFrameObjectHeapProxyProcessorMessages.h"
#include <wtf/MainThread.h>

#if PLATFORM(COCOA)
#include <WebCore/CVUtilities.h>
#include <WebCore/ColorSpaceCG.h>
#include <WebCore/ImageRotationSessionVT.h>
#include <WebCore/PixelBufferConformerCV.h>
#include <WebCore/VideoFrameCV.h>
#include <pal/cf/CoreMediaSoftLink.h>
#include <WebCore/CoreVideoSoftLink.h>
#endif

namespace WebKit {

using namespace WebCore;

Ref<RemoteVideoFrameObjectHeapPlatform> RemoteVideoFrameObjectHeapPlatform::create(Ref<IPC::Connection>&& connection)
{
    return adoptRef(*new RemoteVideoFrameObjectHeapPlatform(WTF::move(connection)));
}

RemoteVideoFrameObjectHeapPlatform::RemoteVideoFrameObjectHeapPlatform(Ref<IPC::Connection>&& connection)
    : m_connection(WTF::move(connection))
{
}

RemoteVideoFrameObjectHeapPlatform::~RemoteVideoFrameObjectHeapPlatform() = default;

void RemoteVideoFrameObjectHeapPlatform::close()
{
    assertIsMainThread();

    protect(m_connection)->removeWorkQueueMessageReceiver(Messages::RemoteVideoFrameObjectHeap::messageReceiverName());

#if PLATFORM(COCOA)
    m_sharedVideoFrameWriter.disable();
#endif
}

#if PLATFORM(COCOA)
void RemoteVideoFrameObjectHeapPlatform::sendVideoFrameBuffer(RemoteVideoFrameIdentifier identifier, VideoFrame* videoFrame)
{
    std::optional<SharedVideoFrame::Buffer> buffer;
    Ref connection = m_connection;

    if (videoFrame) {
        buffer = m_sharedVideoFrameWriter.writeBuffer(protect(videoFrame->pixelBuffer()).get(),
            [&](auto& semaphore) { connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::SetSharedVideoFrameSemaphore { semaphore }, 0); },
            [&](SharedMemory::Handle&& handle) { connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::SetSharedVideoFrameMemory { WTF::move(handle) }, 0); },
            false);
        // FIXME: We should ASSERT(result) once we support enough pixel buffer types.
    }
    connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::NewVideoFrameBuffer { identifier, WTF::move(buffer) }, 0);
}

WebCore::ColorSpace RemoteVideoFrameObjectHeapPlatform::convertFrameBuffer(SharedVideoFrame&& sharedVideoFrame, VideoFrame* frameFromHeap, bool shouldApplyRotation)
{
    ColorSpace destinationColorSpace { ColorSpace::SRGB().platformColorSpace() };

    RefPtr<VideoFrame> frame;
    Ref connection = m_connection;

    if (std::holds_alternative<RemoteVideoFrameReadReference>(sharedVideoFrame.buffer))
        frame = frameFromHeap;
    else
        frame = m_sharedVideoFrameReader.read(WTF::move(sharedVideoFrame));

    if (!frame) {
        connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::NewConvertedVideoFrameBuffer { { } }, 0);
        return destinationColorSpace;
    }

    // When requested, the native image is oriented and callers must not apply the rotation and mirroring of the frame again.
    if (shouldApplyRotation && !frame->hasNoTransformation()) {
        Locker locker { m_pixelBufferConformerLock };
        if (!m_imageRotationSession)
            m_imageRotationSession = makeUnique<WebCore::ImageRotationSessionVT>();

        frame = m_imageRotationSession->applyRotation(*frame);
        if (!frame) {
            RELEASE_LOG_ERROR(WebRTC, "RemoteVideoFrameObjectHeap::convertFrameBuffer rotation failed");
            connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::NewConvertedVideoFrameBuffer { { } }, 0);
            return destinationColorSpace;
        }
    }

    RetainPtr<CVPixelBufferRef> buffer = frame->pixelBuffer();
    destinationColorSpace = ColorSpace(createCGColorSpaceForCVPixelBuffer(buffer.get()));

    if (CVPixelBufferGetPixelFormatType(buffer.get()) != kCVPixelFormatType_32BGRA) {
        Locker locker { m_pixelBufferConformerLock };
        if (!m_pixelBufferConformer)
            m_pixelBufferConformer = makeUnique<WebCore::PixelBufferConformerCV>(kCVPixelFormatType_32BGRA);

        auto convertedBuffer = m_pixelBufferConformer->convert(buffer.get());
        if (!convertedBuffer) {
            RELEASE_LOG_ERROR(WebRTC, "RemoteVideoFrameObjectHeap::convertFrameBuffer conformer failed");
            connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::NewConvertedVideoFrameBuffer { { } }, 0);
            return destinationColorSpace;
        }
        buffer = WTF::move(convertedBuffer);
    }

    bool canSendIOSurface = false;
    auto result = m_sharedVideoFrameWriter.writeBuffer(buffer.get(),
        [&](auto& semaphore) { connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::SetSharedVideoFrameSemaphore { semaphore }, 0); },
        [&](auto&& handle) { connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::SetSharedVideoFrameMemory { WTF::move(handle) }, 0); },
        canSendIOSurface);
    connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::NewConvertedVideoFrameBuffer { WTF::move(result) }, 0);
    return destinationColorSpace;
}

void RemoteVideoFrameObjectHeapPlatform::setSharedVideoFrameSemaphore(mach_port_t semaphore)
{
    m_sharedVideoFrameReader.setSemaphore(IPC::Semaphore { MachSendRight::create(semaphore) });
}

void RemoteVideoFrameObjectHeapPlatform::setSharedVideoFrameMemory(mach_port_t memory, uint64_t size)
{
    m_sharedVideoFrameReader.setSharedMemory({ MachSendRight::create(memory), size });
}

OptionalRemoteVideoFrameReadReference sharedVideoFrameReadReference(const SharedVideoFrame& sharedVideoFrame)
{
    if (auto* reference = std::get_if<RemoteVideoFrameReadReference>(&sharedVideoFrame.buffer))
        return *reference;
    return std::nullopt;
}
#endif

void RemoteVideoFrameObjectHeapPlatform::lowMemoryHandler()
{
#if PLATFORM(COCOA)
    Locker locker { m_pixelBufferConformerLock };
    m_pixelBufferConformer = nullptr;
    m_imageRotationSession = nullptr;
#endif
}

}

#endif
