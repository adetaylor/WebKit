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
#include "IPCUtilities.h"
#include "Logging.h"
#include "ObjectIdentifierDomains.h"
#include "RemoteVideoFrameObjectHeapMessages.h"
#include "RemoteVideoFrameObjectHeapProxyProcessorMessages.h"
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WorkQueue.h>

#if PLATFORM(COCOA)
#include <WebCore/CVUtilities.h>
#include <WebCore/ColorSpaceCG.h>
#include <WebCore/ImageRotationSessionVT.h>
#include <WebCore/PixelBufferConformerCV.h>
#include <WebCore/VideoFrameCV.h>
#include "WebKit-Swift.h"
#include <pal/cf/CoreMediaSoftLink.h>
#include <WebCore/CoreVideoSoftLink.h>
#endif

namespace WebKit {

using namespace WebCore;

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

#if PLATFORM(COCOA)
    m_sharedVideoFrameWriter.disable();
#endif

    swiftRemoveAll();
}

RemoteVideoFrameReference RemoteVideoFrameObjectHeap::add(Ref<VideoFrame>&& frame)
{
    auto reference = RemoteVideoFrameReference::generateForAdd();
    add(reference, WTF::move(frame));
    return reference;
}

void RemoteVideoFrameObjectHeap::add(RemoteVideoFrameReference reference, Ref<VideoFrame>&& frame)
{
#if PLATFORM(COCOA)
    swiftAdd(reference.identifier().toUInt64(), frame->pixelBuffer(), static_cast<uint16_t>(frame->rotation()), frame->isMirrored());
#else
#if ASSERT_ENABLED
    frame->markAsPublished();
#endif
    swiftAdd(reference.identifier().toUInt64(), frame.ptr());
#endif
}

#if PLATFORM(COCOA)
auto RemoteVideoFrameObjectHeap::get(RemoteVideoFrameReadReference&& read) -> std::optional<LentFrame>
{
    RemoteVideoFrameTransform transform;
    RetainPtr pixelBuffer = adoptCF(readRemoteVideoFrame(this, read.identifier().toUInt64(), read.version(), transform));
    if (!pixelBuffer)
        return std::nullopt;
    return LentFrame { WTF::move(pixelBuffer), static_cast<VideoFrameRotation>(transform.rotation), transform.isMirrored };
}
#endif

#if PLATFORM(COCOA)
void RemoteVideoFrameObjectHeap::getVideoFrameBuffer(RemoteVideoFrameReadReference&& read)
{
    auto identifier = read.identifier();
    auto videoFrame = get(WTF::move(read));

    std::optional<SharedVideoFrame::Buffer> buffer;
    Ref connection = m_connection;

    if (videoFrame) {
        buffer = m_sharedVideoFrameWriter.writeBuffer(videoFrame->pixelBuffer.get(),
            [&](auto& semaphore) { connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::SetSharedVideoFrameSemaphore { semaphore }, 0); },
            [&](SharedMemory::Handle&& handle) { connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::SetSharedVideoFrameMemory { WTF::move(handle) }, 0); },
            false);
        // FIXME: We should ASSERT(result) once we support enough pixel buffer types.
    }
    connection->send(Messages::RemoteVideoFrameObjectHeapProxyProcessor::NewVideoFrameBuffer { identifier, WTF::move(buffer) }, 0);
}

void RemoteVideoFrameObjectHeap::convertFrameBuffer(SharedVideoFrame&& sharedVideoFrame, bool shouldApplyRotation, CompletionHandler<void(WebCore::ColorSpace)>&& completionHandler)
{
    std::optional<LentFrame> frameFromHeap;
    if (auto* reference = std::get_if<RemoteVideoFrameReadReference>(&sharedVideoFrame.buffer))
        frameFromHeap = get(RemoteVideoFrameReadReference { *reference });
    completionHandler(sendConvertedFrameBuffer(WTF::move(sharedVideoFrame), WTF::move(frameFromHeap), shouldApplyRotation));
}

WebCore::ColorSpace RemoteVideoFrameObjectHeap::sendConvertedFrameBuffer(SharedVideoFrame&& sharedVideoFrame, std::optional<LentFrame>&& frameFromHeap, bool shouldApplyRotation)
{
    ColorSpace destinationColorSpace { ColorSpace::SRGB().platformColorSpace() };

    RefPtr<VideoFrame> frame;
    Ref connection = m_connection;

    if (std::holds_alternative<RemoteVideoFrameReadReference>(sharedVideoFrame.buffer)) {
        if (frameFromHeap)
            frame = VideoFrameCV::create(sharedVideoFrame.time, frameFromHeap->isMirrored, frameFromHeap->rotation, WTF::move(frameFromHeap->pixelBuffer));
    } else
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

void RemoteVideoFrameObjectHeap::setSharedVideoFrameSemaphore(mach_port_t semaphore)
{
    m_sharedVideoFrameReader.setSemaphore(IPC::Semaphore { MachSendRight::create(semaphore) });
}

void RemoteVideoFrameObjectHeap::setSharedVideoFrameMemory(mach_port_t memory, uint64_t size)
{
    m_sharedVideoFrameReader.setSharedMemory({ MachSendRight::create(memory), size });
}

#endif

void RemoteVideoFrameObjectHeap::lowMemoryHandler()
{
#if PLATFORM(COCOA)
    Locker locker { m_pixelBufferConformerLock };
    m_pixelBufferConformer = nullptr;
    m_imageRotationSession = nullptr;
#endif
}

}

#endif
