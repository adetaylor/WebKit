/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)

#include <AudioToolbox/AudioToolbox.h>
#include <span>
#include <wtf/Noncopyable.h>

OBJC_CLASS CASpatialAudioExperience;

namespace WebCore {

class CARingBuffer;

// An output AudioUnit, the default output unit (RemoteIO on iOS), that AudioOutputUnit.swift owns. Use it on the main
// thread only.
class AudioOutputUnit {
    WTF_MAKE_NONCOPYABLE(AudioOutputUnit);
public:
    enum class Kind : uint8_t {
        // An audio destination of the GPU process, which plays out a ring the web process writes (attachRing()).
        RemoteDestination,
        // An in-process audio destination, which renders from a C++ callback (attachRenderCallback()).
        InProcessDestination,
        // A remote destination on a generic output unit, which needs no hardware (renderForTesting()).
        GenericOutputForTesting,
    };

    WEBCORE_EXPORT AudioOutputUnit(Kind, float hardwareSampleRate, unsigned numberOfOutputChannels);
    WEBCORE_EXPORT ~AudioOutputUnit();

    WEBCORE_EXPORT OSStatus start();
    WEBCORE_EXPORT OSStatus stop();
    WEBCORE_EXPORT size_t outputLatency() const;

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    WEBCORE_EXPORT void setSpatialAudioExperience(CASpatialAudioExperience *);
#endif

    // While stopped: the ring a remote destination plays out (or none), the shared counter it adds each quantum's frames
    // to, and the semaphore it signals after each quantum. The caller keeps them alive until it attaches others or
    // destroys the unit.
    WEBCORE_EXPORT void attachRing(const CARingBuffer*, std::span<uint8_t> frameCounter, uint32_t semaphore);

    // Before an in-process destination first starts: the callback that renders each quantum on the unit's IO thread.
    WEBCORE_EXPORT void attachRenderCallback(AURenderCallback, void* refCon);

    // Tests only, off the main thread, while stopped: renders one quantum into the list, through AudioUnitRender() on a
    // GenericOutputForTesting unit, or by calling a remote destination's render callback directly.
    WEBCORE_EXPORT OSStatus renderForTesting(AudioBufferList&, uint32_t frameCount, double sampleTime, bool throughAudioUnit);

private:
    const uint64_t m_identifier;
};

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO) && USE(MEDIATOOLBOX)
