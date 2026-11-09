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
#include <wtf/Assertions.h>
#include <wtf/Compiler.h>
#include <wtf/MainThread.h>
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

// The 32 bytes before a ring's channels: a sequence count, then the bounds' three words. Only AudioUnitIsland.swift reads
// and writes them, as a sequence lock, with atomic loads and stores.
struct alignas(8) CARingBufferBoundsStorage {
    uint64_t words[4] { };
};
static_assert(sizeof(CARingBufferBoundsStorage) == 32);

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

// The buffers of a WebAudioBufferList: bytesPerBuffer each, in one flat buffer of flatBufferSize bytes. Not valid if a
// size overflows.
struct WebAudioBufferListSizes {
    uint64_t bytesPerBuffer { 0 };
    uint64_t flatBufferSize { 0 };
    bool isValid { false };
};
static_assert(sizeof(WebAudioBufferListSizes) == 24);

// What a unit renders from or delivers to on its IO threads (AudioUnitIsland.swift's audioUnitAttachRing()):
// - an audio destination of the GPU process: a ring's geometry, bounds and channels, the shared counter it adds each
//   quantum's frames to, and the semaphore it signals after each quantum;
// - a track playout: a ring, the semaphore it signals for each chunk of frameChunkSize frames of bytesPerFrame bytes it
//   asks for;
// - a track renderer: the track playout it plays out;
// - a capture unit: the context it hands each microphone quantum to (deliverToCxxObservers()) and the track playout its
//   speaker plays out;
// - a capture producer sink: the ring it writes and the semaphore it signals for each chunk of frameChunkSize frames.
// Whoever attaches it keeps its memory and the semaphore alive until it attaches another or destroys the unit. Without a
// header, there is no ring.
struct AudioOutputUnitRingAttachment {
    CARingBufferGeometry geometry;
    const CARingBufferBoundsStorage* header { nullptr };
    const uint8_t* channels { nullptr };
    uint64_t channelsByteCount { 0 };
    uint32_t* frameCounter { nullptr };
    uint64_t frameCounterByteCount { 0 };
    uint32_t semaphore { 0 };
    uint64_t frameChunkSize { 0 };
    uint64_t bytesPerFrame { 0 };
    uint64_t trackPlayoutIdentifier { 0 };
    void* cxxDeliveryContext { nullptr };
};

// What creating a track renderer's unit did: its identifier, or 0 and the status of the step that failed (1: finding the
// component, 2: making the unit, 3: enabling output, 4: setting the device, 5: setting the render callback, 6: getting the
// stream format, 7: setting it, 8: initializing), and its stream format.
struct AudioOutputUnitTrackRendererCreation {
    uint64_t identifier { 0 };
    AudioStreamBasicDescription format { };
    int32_t status { 0 };
    uint32_t failedStep { 0 };
};
static_assert(!(sizeof(AudioOutputUnitTrackRendererCreation) % 8));

// What creating a capture unit did: its identifier and whether it is the stored voice processing unit, or 0 and the status
// of the step that failed (-1: finding the component).
struct AudioCaptureUnitCreation {
    uint64_t identifier { 0 };
    int32_t status { 0 };
    bool reusedStoredUnit { false };
};

struct AudioCaptureUnitPropertyValue {
    int32_t status { 0 };
    uint32_t value { 0 };
};

// A format a capture unit set, or the status of the step that failed.
struct AudioCaptureUnitFormat {
    AudioStreamBasicDescription format { };
    int32_t status { 0 };
    uint32_t failedStep { 0 };
};

// The microphone buffers of a capture unit: bufferCount buffers of bytesPerBuffer bytes, as CoreAudioCaptureUnit's
// AudioSampleBufferList has, in the microphone's format; and how the microphone times its quanta: at sampleRate, with host
// times scaled by dtsConversionRatio.
struct AudioCaptureMicrophoneBuffers {
    AudioStreamBasicDescription format { };
    uint32_t bufferCount { 0 };
    uint32_t channelsPerBuffer { 0 };
    uint64_t bytesPerBuffer { 0 };
    double sampleRate { 0 };
    double dtsConversionRatio { 0 };
};

// A capture producer sink's first stored frame's MediaTime (startTimeValue / startTimeScale), once there's one, and the
// quanta it dropped because their format wasn't its.
struct AudioCaptureSinkStatus {
    int64_t startTimeValue { 0 };
    uint32_t startTimeScale { 0 };
    bool hasStartTime { false };
    uint64_t droppedQuantumCount { 0 };
};

struct AudioCaptureUnitCounters {
    uint64_t microphoneProcCount { 0 };
    uint32_t failedRenderFrameCount { 0 };
    bool hasFailedRenderFrameCount { false };
};

// The times of a microphone quantum, as CoreAudioCaptureUnit::processMicrophoneSamples() computed them: its sample time;
// its MediaTime (mediaTimeValue / mediaTimeScale); the host time scaled to seconds; and the times its
// AudioSampleBufferList records (setTimes()).
struct AudioCaptureTimes {
    double sampleTime { 0 };
    int64_t mediaTimeValue { 0 };
    uint32_t mediaTimeScale { 0 };
    double adjustedHostTime { 0 };
    uint64_t bufferTimestamp { 0 };
    double bufferHostTime { 0 };
};

// Called on any thread once audio units have events for the main thread (AudioOutputUnit.cpp).
void audioUnitEventsArrived();

// On any thread: a capture unit heard speech while its output was muted (CoreAudioCaptureUnit.cpp).
void audioCaptureVoiceActivityDetected();

// On a capture unit's IO thread: copies a microphone quantum into the CoreAudioCaptureUnit's buffer, applies its volume and
// delivers it to its observers (CoreAudioCaptureUnit.cpp). The context is the one the unit was attached.
void deliverToCxxObservers(void* context, const AudioBufferList*, uint32_t frameCount, const AudioCaptureTimes&);

// The floating-point mixes of a fetch and of AudioSampleBufferList, as their C++ did them: through VectorMath::add(), so
// vDSP decides which NaN a sum of two NaNs gives. The sampleCount float (or, if isDouble, double) samples of source from
// sourceOffset are added to those of destination from destinationOffset; this traps unless both ranges are inside their
// spans.
void mixFloatingPointSamples(std::span<uint8_t> destination NOESCAPE, size_t destinationOffset, std::span<const uint8_t> source NOESCAPE, size_t sourceOffset, size_t sampleCount, bool isDouble);

#if !defined(__swift__)
// C++ makes the views below only off the main thread (rdar://191664699).
ALWAYS_INLINE void assertMakingAudioViewOffMainThread()
{
    RELEASE_ASSERT(!isMainThread());
}
#endif

// A ring, for a fetch: its geometry, its bounds' storage and its channels.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE CARingBufferReadView {
public:
#if !defined(__swift__)
    CARingBufferReadView(const CARingBufferGeometry& geometry, const CARingBufferBoundsStorage& bounds, std::span<const uint8_t> channels)
        : m_geometry(geometry)
        , m_bounds(asByteSpan(bounds))
        , m_channels(channels)
    {
        assertMakingAudioViewOffMainThread();
    }
#endif
    CARingBufferReadView(const CARingBufferReadView&) = delete;
    CARingBufferReadView(CARingBufferReadView&&) = default;

    ALWAYS_INLINE CARingBufferGeometry geometry() const { return m_geometry; }
    ALWAYS_INLINE std::span<const uint8_t> header() const LIFETIME_BOUND { return m_bounds; }
    ALWAYS_INLINE std::span<const uint8_t> channels() const LIFETIME_BOUND { return m_channels; }

private:
    CARingBufferGeometry m_geometry;
    std::span<const uint8_t> m_bounds;
    std::span<const uint8_t> m_channels;
};

// A ring, for a store: its geometry, its bounds and its channels.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE CARingBufferWriteView {
public:
#if !defined(__swift__)
    CARingBufferWriteView(const CARingBufferGeometry& geometry, CARingBufferBoundsStorage& bounds, std::span<uint8_t> channels)
        : m_geometry(geometry)
        , m_bounds(asMutableByteSpan(bounds))
        , m_channels(channels)
    {
        assertMakingAudioViewOffMainThread();
    }
#endif
    CARingBufferWriteView(const CARingBufferWriteView&) = delete;
    CARingBufferWriteView(CARingBufferWriteView&&) = default;

    ALWAYS_INLINE CARingBufferGeometry geometry() const { return m_geometry; }
    ALWAYS_INLINE std::span<uint8_t> mutableHeader() LIFETIME_BOUND { return m_bounds; }
    ALWAYS_INLINE std::span<uint8_t> mutableChannels() LIFETIME_BOUND { return m_channels; }

private:
    CARingBufferGeometry m_geometry;
    std::span<uint8_t> m_bounds;
    std::span<uint8_t> m_channels;
};

// An AudioBufferList that Swift writes. Swift reads its buffer count and sizes when it uses them.
class SWIFT_NONCOPYABLE SWIFT_NONESCAPABLE SWIFT_SAFE AudioBufferListView {
public:
#if !defined(__swift__)
    explicit AudioBufferListView(::AudioBufferList* list)
        : m_list(list)
    {
        assertMakingAudioViewOffMainThread();
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
        assertMakingAudioViewOffMainThread();
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

} // namespace WebCore
