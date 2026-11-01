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

#include "config.h"
#include "SharedVideoFrame.h"

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)

#include "Logging.h"
#include "RemoteVideoFrameObjectHeap.h"
#include "RemoteVideoFrameProxy.h"
#include "SharedVideoFrameImplBridge.h"
#include "WebKit-Swift.h"
#include <WebCore/CVUtilities.h>
#include <WebCore/IOSurface.h>
#include <WebCore/SharedVideoFrameInfo.h>
#include <WebCore/VideoFrameCV.h>
#include <WebCore/VideoFrameLibWebRTC.h>
#include <array>
#include <new>
#include <wtf/TZoneMallocInlines.h>

#if USE(LIBWEBRTC)

WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_BEGIN
#include <webrtc/webkit_sdk/WebKit/WebKitUtilities.h>
WTF_IGNORE_WARNINGS_IN_THIRD_PARTY_CODE_END

#endif

#include <pal/cf/CoreMediaSoftLink.h>
#include <WebCore/CoreVideoSoftLink.h>

namespace WebKit {
using namespace WebCore;

// The protocol state and decisions are in SharedVideoFrameImpl.swift.

static_assert(sizeof(SharedVideoFrameWriterImpl) == sizeof(void*) && alignof(SharedVideoFrameWriterImpl) == alignof(void*));
static_assert(sizeof(SharedVideoFrameReaderImpl) == sizeof(void*) && alignof(SharedVideoFrameReaderImpl) == alignof(void*));

// Swift traps when it passes a span with a null base back to C++, so empty storage is handed over with a valid one.
static std::span<const uint8_t> spanWithNonNullBase(std::span<const uint8_t> bytes)
{
    static constexpr std::array<uint8_t, 1> emptyBytes { };
    return bytes.data() ? bytes : std::span { emptyBytes }.first(0);
}

static std::span<uint8_t> spanWithNonNullBase(std::span<uint8_t> bytes)
{
    static std::array<uint8_t, 1> emptyBytes { };
    return bytes.data() ? bytes : std::span { emptyBytes }.first(0);
}

SharedVideoFrameWriterContext::SharedVideoFrameWriterContext(SharedVideoFrameWriter& writer, const Function<void(IPC::Semaphore&)>& newSemaphoreCallback, const Function<void(SharedMemory::Handle&&)>& newMemoryCallback)
    : m_writer(writer)
    , m_newSemaphoreCallback(newSemaphoreCallback)
    , m_newMemoryCallback(newMemoryCallback)
{
}

void SharedVideoFrameWriterContext::sendSemaphore() const
{
    m_newSemaphoreCallback(m_writer.m_semaphore.get());
}

bool SharedVideoFrameWriterContext::waitForSemaphore() const
{
    return m_writer.m_semaphore->waitFor(SharedVideoFrameWriter::defaultTimeout);
}

void SharedVideoFrameWriterContext::signalSemaphore() const
{
    m_writer.m_semaphore->signal();
}

bool SharedVideoFrameWriterContext::hasStorage() const
{
    return !!m_writer.m_storage;
}

size_t SharedVideoFrameWriterContext::storageSize() const
{
    RefPtr storage = m_writer.m_storage;
    return storage ? storage->size() : 0;
}

bool SharedVideoFrameWriterContext::allocateStorage(size_t size)
{
    RefPtr storage = SharedMemory::allocate(size);
    m_writer.m_storage = storage;
    if (!storage)
        return false;

    auto handle = storage->createHandle(SharedMemory::Protection::ReadOnly);
    if (!handle)
        return false;

    m_newMemoryCallback(WTF::move(*handle));
    return true;
}

std::span<uint8_t> SharedVideoFrameWriterContext::storageBytes()
{
    return spanWithNonNullBase(m_writer.m_storage->mutableSpan());
}

CVPixelBufferRef SharedVideoFrameWriterContext::convertCompressedPixelBuffer(CVPixelBufferRef pixelBuffer) const
{
    auto& conformer = m_writer.m_compressedPixelBufferConformer;
    if (!conformer)
        conformer = makeUnique<WebCore::PixelBufferConformerCV>(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    return conformer->convert(pixelBuffer).leakRef();
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(SharedVideoFrameWriter);

SharedVideoFrameWriter::SharedVideoFrameWriter()
    : m_semaphore(makeUniqueRef<IPC::Semaphore>())
{
    new (m_impl) SharedVideoFrameWriterImpl(SharedVideoFrameWriterImpl::init());
}

// Moving a Swift reference copies it, so the moved-from writer gets a new Impl rather than sharing the moved one.
SharedVideoFrameWriter::SharedVideoFrameWriter(SharedVideoFrameWriter&& other)
    : m_semaphore(WTF::move(other.m_semaphore))
    , m_storage(WTF::move(other.m_storage))
    , m_compressedPixelBufferConformer(WTF::move(other.m_compressedPixelBufferConformer))
{
    new (m_impl) SharedVideoFrameWriterImpl(other.swiftImpl());
    other.swiftImpl() = SharedVideoFrameWriterImpl::init();
}

SharedVideoFrameWriter& SharedVideoFrameWriter::operator=(SharedVideoFrameWriter&& other)
{
    if (this == &other)
        return *this;
    m_semaphore = WTF::move(other.m_semaphore);
    m_storage = WTF::move(other.m_storage);
    m_compressedPixelBufferConformer = WTF::move(other.m_compressedPixelBufferConformer);
    swiftImpl() = other.swiftImpl();
    other.swiftImpl() = SharedVideoFrameWriterImpl::init();
    return *this;
}

SharedVideoFrameWriter::~SharedVideoFrameWriter()
{
    std::destroy_at(&swiftImpl());
}

SharedVideoFrameWriterImpl& SharedVideoFrameWriter::swiftImpl()
{
    return *std::launder(reinterpret_cast<SharedVideoFrameWriterImpl*>(m_impl));
}

std::optional<SharedVideoFrame> SharedVideoFrameWriter::write(const VideoFrame& frame, NOESCAPE const Function<void(IPC::Semaphore&)>& newSemaphoreCallback, NOESCAPE const Function<void(SharedMemory::Handle&&)>& newMemoryCallback)
{
    auto buffer = writeBuffer(frame, newSemaphoreCallback, newMemoryCallback);
    if (!buffer)
        return { };
    return SharedVideoFrame { frame.presentationTime(), frame.isMirrored(), frame.rotation(), frame.colorSpace(), frame.shouldIgnoreAlpha(), WTF::move(*buffer) };
}

std::optional<SharedVideoFrame::Buffer> SharedVideoFrameWriter::writeBuffer(const VideoFrame& frame, NOESCAPE const Function<void(IPC::Semaphore&)>& newSemaphoreCallback, NOESCAPE const Function<void(SharedMemory::Handle&&)>& newMemoryCallback)
{
    if (auto* frameProxy = dynamicDowncast<RemoteVideoFrameProxy>(frame))
        return frameProxy->newReadReference();

#if USE(LIBWEBRTC)
    if (auto* webrtcFrame = dynamicDowncast<VideoFrameLibWebRTC>(frame))
        return writeBuffer(*webrtcFrame->buffer(), newSemaphoreCallback, newMemoryCallback);
#endif

    return writeBuffer(protect(frame.pixelBuffer()).get(), newSemaphoreCallback, newMemoryCallback);
}

std::optional<SharedVideoFrame::Buffer> SharedVideoFrameWriter::writeBuffer(CVPixelBufferRef pixelBuffer, NOESCAPE const Function<void(IPC::Semaphore&)>& newSemaphoreCallback, NOESCAPE const Function<void(SharedMemory::Handle&&)>& newMemoryCallback, bool canUseIOSurface)
{
    if (!pixelBuffer)
        return { };

    if (canUseIOSurface) {
        if (RetainPtr surface = CVPixelBufferGetIOSurface(pixelBuffer))
            return MachSendRight::adopt(IOSurfaceCreateMachPort(surface.get()));
    }

    SharedVideoFrameWriterContext context { *this, newSemaphoreCallback, newMemoryCallback };
    if (!swiftImpl().writePixelBuffer(pixelBuffer, context))
        return { };
    return nullptr;
}

#if USE(LIBWEBRTC)
std::optional<SharedVideoFrame::Buffer> SharedVideoFrameWriter::writeBuffer(const webrtc::VideoFrame& frame, NOESCAPE const Function<void(IPC::Semaphore&)>& newSemaphoreCallback, NOESCAPE const Function<void(SharedMemory::Handle&&)>& newMemoryCallback)
{
    if (auto* provider = webrtc::videoFrameBufferProvider(frame))
        return writeBuffer(*static_cast<VideoFrame*>(provider), newSemaphoreCallback, newMemoryCallback);

    if (auto pixelBuffer = adoptCF(webrtc::copyPixelBufferForFrame(frame)))
        return writeBuffer(pixelBuffer.get(), newSemaphoreCallback, newMemoryCallback);

    return writeBuffer(*frame.video_frame_buffer(), newSemaphoreCallback, newMemoryCallback);
}

std::optional<SharedVideoFrame::Buffer> SharedVideoFrameWriter::writeBuffer(webrtc::VideoFrameBuffer& frameBuffer, NOESCAPE const Function<void(IPC::Semaphore&)>& newSemaphoreCallback, NOESCAPE const Function<void(SharedMemory::Handle&&)>& newMemoryCallback)
{
    SharedVideoFrameWriterContext context { *this, newSemaphoreCallback, newMemoryCallback };
    auto info = SharedVideoFrameInfo::fromVideoFrameBuffer(frameBuffer);
    if (!swiftImpl().prepareWriting(info, context) || !info.writeVideoFrameBuffer(frameBuffer, m_storage->mutableSpan())) {
        swiftImpl().signalInCaseOfError(context);
        return { };
    }
    return nullptr;
}
#endif

void SharedVideoFrameWriter::disable()
{
    swiftImpl().disable();
    m_semaphore->signal();
}

bool SharedVideoFrameWriter::isDisabled()
{
    return swiftImpl().isDisabled();
}

SharedVideoFrameReaderContext::SharedVideoFrameReaderContext(SharedVideoFrameReader& reader)
    : m_reader(reader)
{
}

bool SharedVideoFrameReaderContext::hasStorage() const
{
    return !!m_reader.m_storage;
}

std::span<const uint8_t> SharedVideoFrameReaderContext::storageBytes() const
{
    return spanWithNonNullBase(m_reader.m_storage->span());
}

void SharedVideoFrameReaderContext::signalSemaphore() const
{
    if (m_reader.m_semaphore)
        m_reader.m_semaphore->signal();
}

void SharedVideoFrameReaderContext::setOwnershipIdentity(CVPixelBufferRef pixelBuffer) const
{
    if (m_reader.m_resourceOwner)
        setOwnershipIdentityForCVPixelBuffer(pixelBuffer, m_reader.m_resourceOwner);
}

CVPixelBufferPoolRef createSharedVideoFrameBufferPool(const SharedVideoFrameInfo& info)
{
    return info.createCompatibleBufferPool().leakRef();
}

CVPixelBufferRef createSharedVideoFramePixelBuffer(SharedVideoFrameInfo& info, NOESCAPE std::span<const uint8_t> planes, CVPixelBufferPoolRef pool)
{
    return info.createPixelBufferFromMemory(planes, pool).leakRef();
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(SharedVideoFrameReader);

SharedVideoFrameReader::SharedVideoFrameReader(RefPtr<RemoteVideoFrameObjectHeap>&& objectHeap, const ProcessIdentity& resourceOwner, UseIOSurfaceBufferPool useIOSurfaceBufferPool)
    : m_objectHeap(WTF::move(objectHeap))
    , m_resourceOwner(resourceOwner)
{
    new (m_impl) SharedVideoFrameReaderImpl(SharedVideoFrameReaderImpl::init(useIOSurfaceBufferPool == UseIOSurfaceBufferPool::Yes));
}

SharedVideoFrameReader::SharedVideoFrameReader()
    : SharedVideoFrameReader(nullptr, { }, UseIOSurfaceBufferPool::No)
{
}

SharedVideoFrameReader::~SharedVideoFrameReader()
{
    std::destroy_at(&swiftImpl());
}

SharedVideoFrameReaderImpl& SharedVideoFrameReader::swiftImpl()
{
    return *std::launder(reinterpret_cast<SharedVideoFrameReaderImpl*>(m_impl));
}

RetainPtr<CVPixelBufferRef> SharedVideoFrameReader::readBuffer(SharedVideoFrame::Buffer&& buffer)
{
    return switchOn(WTF::move(buffer),
    [this](RemoteVideoFrameReadReference&& reference) -> RetainPtr<CVPixelBufferRef> {
        ASSERT(m_objectHeap);
        if (!m_objectHeap) {
            RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameReader::readBuffer no object heap");
            return nullptr;
        }

        auto sample = m_objectHeap->get(WTF::move(reference));
        if (!sample) {
            RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameReader::readBuffer no sample");
            return nullptr;
        }

        ASSERT(sample->pixelBuffer());
        return sample->pixelBuffer();
    } , [](MachSendRight&& sendRight) -> RetainPtr<CVPixelBufferRef> {
        auto surface = WebCore::IOSurface::createFromSendRight(WTF::move(sendRight));
        if (!surface) {
            RELEASE_LOG_ERROR(WebRTC, "SharedVideoFrameReader::readBuffer no surface");
            return nullptr;
        }
        return WebCore::createCVPixelBuffer(protect(surface->surface()).get()).value_or(nullptr);
    }, [this](std::nullptr_t representation) -> RetainPtr<CVPixelBufferRef> {
        SharedVideoFrameReaderContext context { *this };
        return adoptCF(swiftImpl().readBufferFromSharedMemory(context));
    }, [this](IntSize size) -> RetainPtr<CVPixelBufferRef> {
        if (m_blackFrameSize != size) {
            m_blackFrameSize = size;
            bool useIOSurfaceBufferPool = swiftImpl().usesIOSurfaceBufferPool();
            m_blackFrame = WebCore::createBlackPixelBuffer(m_blackFrameSize.width(), m_blackFrameSize.height(), useIOSurfaceBufferPool);
            if (m_resourceOwner && useIOSurfaceBufferPool)
                setOwnershipIdentityForCVPixelBuffer(m_blackFrame.get(), m_resourceOwner);
        }
        return m_blackFrame.get();
    });
}

RefPtr<VideoFrame> SharedVideoFrameReader::read(SharedVideoFrame&& sharedVideoFrame)
{
    auto pixelBuffer = readBuffer(WTF::move(sharedVideoFrame.buffer));
    if (!pixelBuffer)
        return nullptr;

    return VideoFrameCV::create(sharedVideoFrame.time, sharedVideoFrame.mirrored, sharedVideoFrame.rotation, WTF::move(pixelBuffer), WTF::move(sharedVideoFrame.colorSpace), sharedVideoFrame.shouldIgnoreAlpha ? VideoFrameCV::ShouldIgnoreAlpha::Yes : VideoFrameCV::ShouldIgnoreAlpha::No);
}

bool SharedVideoFrameReader::setSharedMemory(SharedMemory::Handle&& handle)
{
    m_storage = SharedMemory::map(WTF::move(handle), SharedMemory::Protection::ReadOnly);
    return !!m_storage;
}

}

#endif
