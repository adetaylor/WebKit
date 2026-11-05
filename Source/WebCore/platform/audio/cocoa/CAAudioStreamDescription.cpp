/*
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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
#include "CAAudioStreamDescription.h"

#include <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CAAudioStreamDescription);

CAAudioStreamDescription::~CAAudioStreamDescription() = default;

CAAudioStreamDescription::CAAudioStreamDescription(const AudioStreamBasicDescription &desc)
    : m_streamDescription(desc)
    , m_format(static_cast<PCMFormat>(caAudioStreamDescriptionFormat(m_streamDescription)))
{
}

CAAudioStreamDescription::CAAudioStreamDescription(double sampleRate, uint32_t numChannels, PCMFormat format, IsInterleaved isInterleaved)
    : m_streamDescription(caAudioStreamDescriptionMake(sampleRate, numChannels, format, isInterleaved == IsInterleaved::Yes))
    , m_format(static_cast<PCMFormat>(caAudioStreamDescriptionFormat(m_streamDescription)))
{
}

const PlatformDescription& CAAudioStreamDescription::platformDescription() const
{
    m_platformDescription = { PlatformDescription::CAAudioStreamBasicType, &m_streamDescription };
    return m_platformDescription;
}

bool operator==(const AudioStreamBasicDescription& a, const AudioStreamBasicDescription& b)
{
    return a.mSampleRate == b.mSampleRate
        && a.mFormatID == b.mFormatID
        && a.mFormatFlags == b.mFormatFlags
        && a.mBytesPerPacket == b.mBytesPerPacket
        && a.mFramesPerPacket == b.mFramesPerPacket
        && a.mBytesPerFrame == b.mBytesPerFrame
        && a.mChannelsPerFrame == b.mChannelsPerFrame
        && a.mBitsPerChannel == b.mBitsPerChannel;
}

double CAAudioStreamDescription::sampleRate() const
{
    return m_streamDescription.mSampleRate;
}

bool CAAudioStreamDescription::isPCM() const
{
    return m_streamDescription.mFormatID == kAudioFormatLinearPCM;
}

bool CAAudioStreamDescription::isInterleaved() const
{
    return !(m_streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved);
}

bool CAAudioStreamDescription::isSignedInteger() const
{
    return isPCM() && (m_streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger);
}

bool CAAudioStreamDescription::isFloat() const
{
    return isPCM() && (m_streamDescription.mFormatFlags & kAudioFormatFlagIsFloat);
}

bool CAAudioStreamDescription::isNativeEndian() const
{
    return isPCM() && (m_streamDescription.mFormatFlags & kAudioFormatFlagIsBigEndian) == kAudioFormatFlagsNativeEndian;
}

uint32_t CAAudioStreamDescription::numberOfInterleavedChannels() const
{
    return isInterleaved() ? m_streamDescription.mChannelsPerFrame : 1;
}

uint32_t CAAudioStreamDescription::numberOfChannelStreams() const
{
    return isInterleaved() ? 1 : m_streamDescription.mChannelsPerFrame;
}

uint32_t CAAudioStreamDescription::numberOfChannels() const
{
    return m_streamDescription.mChannelsPerFrame;
}

uint32_t CAAudioStreamDescription::sampleWordSize() const
{
    return (m_streamDescription.mBytesPerFrame > 0 && numberOfInterleavedChannels()) ? m_streamDescription.mBytesPerFrame / numberOfInterleavedChannels() :  0;
}

uint32_t CAAudioStreamDescription::bytesPerFrame() const
{
    return m_streamDescription.mBytesPerFrame;
}

uint32_t CAAudioStreamDescription::bytesPerPacket() const
{
    return m_streamDescription.mBytesPerPacket;
}

uint32_t CAAudioStreamDescription::formatFlags() const
{
    return m_streamDescription.mFormatFlags;
}

bool CAAudioStreamDescription::operator==(const AudioStreamBasicDescription& other) const
{
    return m_streamDescription == other;
}

bool CAAudioStreamDescription::operator==(const AudioStreamDescription& other) const
{
    if (other.platformDescription().type != PlatformDescription::CAAudioStreamBasicType)
        return false;

    return operator==(*std::get<const AudioStreamBasicDescription*>(other.platformDescription().description));
}

const AudioStreamBasicDescription& CAAudioStreamDescription::streamDescription() const
{
    return m_streamDescription;
}

}
