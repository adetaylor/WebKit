/*
 * Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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
#include "CARingBuffer.h"

#if ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)

#include "CAAudioStreamDescription.h"
#include "Logging.h"
#include "VectorMath.h"
#include <wtf/MathExtras.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CARingBuffer);
WTF_MAKE_TZONE_ALLOCATED_IMPL(InProcessCARingBuffer);

CARingBuffer::CARingBuffer(size_t bytesPerFrame, size_t frameCount, uint32_t numChannelStreams)
    : m_geometry(caRingBufferMakeGeometry(bytesPerFrame, frameCount, numChannelStreams))
{
    ASSERT(isPowerOfTwo(frameCount));
}

CARingBuffer::~CARingBuffer() = default;

CARingBufferStorageSize CARingBuffer::sharedStorageSizeForAllocation(uint32_t bytesPerFrame, size_t frameCount, uint32_t numChannelStreams)
{
    return caRingBufferStorageSize(bytesPerFrame, frameCount, numChannelStreams, sizeof(TimeBoundsBuffer));
}

CARingBufferStorageSize CARingBuffer::sharedStorageSizeForMapping(uint32_t bytesPerFrame, uint64_t frameCount, uint32_t numChannelStreams)
{
    return caRingBufferMappedStorageSize(bytesPerFrame, frameCount, numChannelStreams, sizeof(TimeBoundsBuffer));
}

void CARingBuffer::initialize()
{
    m_channelData = span();
    m_timeBounds = &timeBoundsBuffer();
}

template<typename T>
static void mixSamples(std::span<uint8_t> destination, size_t destinationOffset, std::span<const uint8_t> source, size_t sourceOffset, size_t byteCount)
{
    size_t frameCount = byteCount / sizeof(T);
    auto sourceSamples = spanReinterpretCast<const T>(source.subspan(sourceOffset)).first(frameCount);
    auto destinationSamples = spanReinterpretCast<T>(destination.subspan(destinationOffset)).first(frameCount);
    VectorMath::add(destinationSamples, sourceSamples, destinationSamples);
}

void mixFloat32Samples(std::span<uint8_t> destination NOESCAPE, size_t destinationOffset, std::span<const uint8_t> source NOESCAPE, size_t sourceOffset, size_t byteCount)
{
    mixSamples<float>(destination, destinationOffset, source, sourceOffset, byteCount);
}

void mixFloat64Samples(std::span<uint8_t> destination NOESCAPE, size_t destinationOffset, std::span<const uint8_t> source NOESCAPE, size_t sourceOffset, size_t byteCount)
{
    mixSamples<double>(destination, destinationOffset, source, sourceOffset, byteCount);
}

// The writer can be another process, so don't wait for it to finish a write.
static constexpr unsigned maxBoundsLoadAttempts = 64;

CARingBuffer::TimeBounds CARingBuffer::loadBounds() const
{
    return m_timeBounds->loadWithRetryLimit(maxBoundsLoadAttempts);
}

CARingBuffer::TimeBounds CARingBuffer::getStoreTimeBounds()
{
    return m_storeBounds;
}

CARingBuffer::Error CARingBuffer::store(const AudioBufferList* list, size_t framesToWrite, uint64_t startFrame, uint64_t writeAhead)
{
    CARingBufferWriteView ring { m_geometry, *m_timeBounds, m_channelData };
    ConstAudioBufferListView source { list };
    return caRingBufferStore(ring, m_storeBounds, source, framesToWrite, startFrame, writeAhead) ? Ok : TooMuch;
}

CARingBuffer::TimeBounds CARingBuffer::getFetchTimeBounds()
{
    return caRingBufferFetchTimeBounds(m_geometry, loadBounds());
}

bool CARingBuffer::fetchIfHasEnoughData(AudioBufferList* list, size_t frameCount, uint64_t startRead, FetchMode mode)
{
    AudioBufferListView destination { list };
    return caRingBufferFetchIfHasEnoughData(CARingBufferReadView { m_geometry, loadBounds(), m_channelData }, destination, frameCount, startRead, static_cast<uint32_t>(mode));
}

void CARingBuffer::fetch(AudioBufferList* list, size_t frameCount, uint64_t startRead, FetchMode mode)
{
    AudioBufferListView destination { list };
    caRingBufferFetch(CARingBufferReadView { m_geometry, loadBounds(), m_channelData }, destination, frameCount, startRead, static_cast<uint32_t>(mode));
}

bool CARingBuffer::renderForAudioDestination(uint64_t& startFrame, AudioBufferList* output, std::span<float> lastRenderedSamples, uint32_t frameCount)
{
    AudioBufferListView destination { output };
    FloatSamplesView samples { lastRenderedSamples };
    return caRingBufferRenderForAudioDestination(CARingBufferReadView { m_geometry, loadBounds(), m_channelData }, startFrame, destination, samples, frameCount);
}

CARingBufferTrackRenderResult CARingBuffer::renderForTrackRenderer(uint64_t& readOffset, uint64_t& generateOffset, AudioBufferList& output, size_t sampleCount, uint64_t frameChunkSize)
{
    AudioBufferListView destination { &output };
    return caRingBufferRenderForTrackRenderer(CARingBufferReadView { m_geometry, loadBounds(), m_channelData }, readOffset, generateOffset, destination, sampleCount, frameChunkSize);
}

std::unique_ptr<InProcessCARingBuffer> InProcessCARingBuffer::allocate(const WebCore::CAAudioStreamDescription& format, size_t frameCount)
{
    auto bytesPerFrame = format.bytesPerFrame();
    auto numChannelStreams = format.numberOfChannelStreams();

    auto storageSize = caRingBufferStorageSize(bytesPerFrame, frameCount, numChannelStreams, 0);
    if (!storageSize.isValid) {
        RELEASE_LOG_FAULT(Media, "InProcessCARingBuffer::allocate: Overflowed when trying to compute the storage size");
        return nullptr;
    }
    size_t sizeForBuffers = storageSize.byteCount;
    Vector<uint8_t> buffer;
    if (!buffer.tryReserveCapacity(sizeForBuffers)) {
        RELEASE_LOG_FAULT(Media, "InProcessCARingBuffer::allocate: Failed to allocate buffer of the requested size: %lu", sizeForBuffers);
        return nullptr;
    }
    buffer.grow(sizeForBuffers);
    buffer.fill(0);
    std::unique_ptr<InProcessCARingBuffer> result { new InProcessCARingBuffer { bytesPerFrame, static_cast<size_t>(storageSize.frameCount), numChannelStreams, WTF::move(buffer) } };
    result->initialize();
    return result;
}

InProcessCARingBuffer::InProcessCARingBuffer(size_t bytesPerFrame, size_t frameCount, uint32_t numChannelStreams, Vector<uint8_t>&& buffer)
    : CARingBuffer(bytesPerFrame, frameCount, numChannelStreams)
    , m_buffer(WTF::move(buffer))
{
}

InProcessCARingBuffer::~InProcessCARingBuffer() = default;

}

#endif // ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)
