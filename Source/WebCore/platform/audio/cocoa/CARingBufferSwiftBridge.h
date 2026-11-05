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

#pragma once

#include <CoreAudio/CoreAudioTypes.h>
#include <cstdint>
#include <span>
#include <wtf/Compiler.h>
#include <wtf/SequenceLocked.h>
#include <wtf/StdLibExtras.h>
#include <wtf/SwiftBridging.h>

// The types through which CARingBuffer hands its state and memory to its Swift (CARingBuffer.swift). The views are
// non-copyable and non-escapable and only C++ can make one, so Swift can use them, and the spans it takes from them,
// only for the call they are passed to; they are SWIFT_SAFE on that basis. The views over an AudioBufferList trust its
// buffer count, pointers and sizes, as the C++ that reads an AudioBufferList does.

namespace WebCore {

// The frames a ring holds, [startFrame, endFrame).
struct CARingBufferBounds {
    uint64_t startFrame { 0 };
    uint64_t endFrame { 0 };
    uint64_t writeAhead { 0 };

    friend bool operator==(const CARingBufferBounds&, const CARingBufferBounds&) = default;
};
static_assert(sizeof(CARingBufferBounds) == 24);

// A ring's layout: channelCount channels of capacityBytes each, frameCount frames of bytesPerFrame.
struct CARingBufferGeometry {
    uint64_t bytesPerFrame { 0 };
    uint64_t capacityBytes { 0 };
    uint32_t channelCount { 0 };
    uint32_t frameCount { 0 };
};
static_assert(sizeof(CARingBufferGeometry) == 24);

// The size of a ring's storage for a requested frame count, rounded up to a power of two. Not valid if it overflows.
struct CARingBufferStorageSize {
    uint64_t frameCount { 0 };
    uint64_t byteCount { 0 };
    bool isValid { false };
};
static_assert(sizeof(CARingBufferStorageSize) == 24);

// What a track renderer's render quantum did: whether it fetched, and how many chunks to ask the writer for.
struct CARingBufferTrackRenderResult {
    uint64_t signalCount { 0 };
    bool fetched { false };
};
static_assert(sizeof(CARingBufferTrackRenderResult) == 16);

// The floating-point mixes of a fetch and of AudioSampleBufferList, as their C++ did them: through VectorMath::add(), so
// vDSP decides which NaN a sum of two NaNs gives. The sampleCount float (or, if isDouble, double) samples of source from
// sourceOffset are added to those of destination from destinationOffset; this traps unless both ranges are inside their
// spans.
void mixFloatingPointSamples(std::span<uint8_t> destination NOESCAPE, size_t destinationOffset, std::span<const uint8_t> source NOESCAPE, size_t sourceOffset, size_t sampleCount, bool isDouble);

// A ring, for a fetch: its geometry, the bounds the C++ read from it and its channels.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE CARingBufferReadView {
public:
#if !defined(__swift__)
    CARingBufferReadView(const CARingBufferGeometry& geometry, const CARingBufferBounds& storedBounds, std::span<const uint8_t> channels)
        : m_geometry(geometry)
        , m_storedBounds(storedBounds)
        , m_channels(channels)
    {
    }
#endif
    CARingBufferReadView(const CARingBufferReadView&) = delete;
    CARingBufferReadView(CARingBufferReadView&&) = default;

    ALWAYS_INLINE CARingBufferGeometry geometry() const { return m_geometry; }
    ALWAYS_INLINE CARingBufferBounds storedBounds() const { return m_storedBounds; }
    ALWAYS_INLINE std::span<const uint8_t> channels() const LIFETIME_BOUND { return m_channels; }

private:
    CARingBufferGeometry m_geometry;
    CARingBufferBounds m_storedBounds;
    std::span<const uint8_t> m_channels;
};

// A ring, for a store: its geometry, its bounds and its channels.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE CARingBufferWriteView {
public:
#if !defined(__swift__)
    CARingBufferWriteView(const CARingBufferGeometry& geometry, SequenceLocked<CARingBufferBounds>& bounds, std::span<uint8_t> channels)
        : m_geometry(geometry)
        , m_bounds(&bounds)
        , m_channels(channels)
    {
    }
#endif
    CARingBufferWriteView(const CARingBufferWriteView&) = delete;
    CARingBufferWriteView(CARingBufferWriteView&&) = default;

    ALWAYS_INLINE CARingBufferGeometry geometry() const { return m_geometry; }
    ALWAYS_INLINE void storeBounds(const CARingBufferBounds& bounds) { m_bounds->store(bounds); }
    ALWAYS_INLINE std::span<uint8_t> mutableChannels() LIFETIME_BOUND { return m_channels; }

private:
    CARingBufferGeometry m_geometry;
    SequenceLocked<CARingBufferBounds>* m_bounds;
    std::span<uint8_t> m_channels;
};

// An AudioBufferList that Swift writes. Swift reads its buffer count and sizes when it uses them.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE AudioBufferListView {
public:
#if !defined(__swift__)
    explicit AudioBufferListView(::AudioBufferList* list)
        : m_list(list)
    {
    }
#endif
    AudioBufferListView(const AudioBufferListView&) = delete;
    AudioBufferListView(AudioBufferListView&&) = default;

    ALWAYS_INLINE uint32_t bufferCount() const { return m_list->mNumberBuffers; }
    ALWAYS_INLINE std::span<uint8_t> mutableBytes(uint32_t index) LIFETIME_BOUND
    {
        auto& buffer = buffers()[index];
        return unsafeMakeSpan(static_cast<uint8_t*>(buffer.mData), buffer.mDataByteSize);
    }
    ALWAYS_INLINE void setDataByteSize(uint32_t index, uint32_t size) { buffers()[index].mDataByteSize = size; }

private:
    ALWAYS_INLINE std::span<::AudioBuffer> buffers() const { return unsafeMakeSpan(m_list->mBuffers, m_list->mNumberBuffers); }

    ::AudioBufferList* m_list;
};

// An AudioBufferList that Swift reads.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE ConstAudioBufferListView {
public:
#if !defined(__swift__)
    explicit ConstAudioBufferListView(const ::AudioBufferList* list)
        : m_list(list)
    {
    }
#endif
    ConstAudioBufferListView(const ConstAudioBufferListView&) = delete;
    ConstAudioBufferListView(ConstAudioBufferListView&&) = default;

    ALWAYS_INLINE uint32_t bufferCount() const { return m_list->mNumberBuffers; }
    ALWAYS_INLINE std::span<const uint8_t> bytes(uint32_t index) const LIFETIME_BOUND
    {
        auto& buffer = unsafeMakeSpan(m_list->mBuffers, m_list->mNumberBuffers)[index];
        return unsafeMakeSpan(static_cast<const uint8_t*>(buffer.mData), buffer.mDataByteSize);
    }

private:
    const ::AudioBufferList* m_list;
};

// Floats Swift writes, such as an audio destination's last rendered samples.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE FloatSamplesView {
public:
#if !defined(__swift__)
    explicit FloatSamplesView(std::span<float> samples)
        : m_samples(samples)
    {
    }
#endif
    FloatSamplesView(const FloatSamplesView&) = delete;
    FloatSamplesView(FloatSamplesView&&) = default;

    ALWAYS_INLINE std::span<float> mutableSamples() LIFETIME_BOUND { return m_samples; }

private:
    std::span<float> m_samples;
};

} // namespace WebCore
