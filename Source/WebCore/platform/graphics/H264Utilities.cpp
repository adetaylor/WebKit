/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
#include "H264Utilities.h"

#if ENABLE(WEBCORE_SWIFT)

#include "AnnexBUtilities.h"
#include "Logging.h"
#include "WebCore-Swift.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

// The parsing is in H264Utilities.swift.
WTF_MAKE_TZONE_ALLOCATED_IMPL(H264BitstreamParser);

// The failures H264BitstreamParserState reports, with the raw values of H264ParserLogEvent in H264Utilities.swift.
enum class H264BitstreamParserLogEvent : uint8_t {
    None,
    UnsupportedNaluType,
    QPDeltaOutOfRange,
    MissingInfo,
    InvalidQP,
};

static void logBitstreamParserEvent(H264BitstreamParserLogEvent event)
{
    switch (event) {
    case H264BitstreamParserLogEvent::None:
        break;
    case H264BitstreamParserLogEvent::UnsupportedNaluType:
        RELEASE_LOG_ERROR(WebRTC, "H264BitstreamParser: unsupported nal unit type");
        break;
    case H264BitstreamParserLogEvent::QPDeltaOutOfRange:
        RELEASE_LOG_ERROR(WebRTC, "H264BitstreamParser: parsed QP delta out of range");
        break;
    case H264BitstreamParserLogEvent::MissingInfo:
        RELEASE_LOG_ERROR(WebRTC, "H264BitstreamParser: unable to get qp - missing info");
        break;
    case H264BitstreamParserLogEvent::InvalidQP:
        RELEASE_LOG_ERROR(WebRTC, "H264BitstreamParser: parsed invalid QP from bitstream");
        break;
    }
}

struct H264BitstreamParser::Impl {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(Impl);
public:
    H264BitstreamParserState state { H264BitstreamParserState::init() };
};

H264BitstreamParser::H264BitstreamParser()
    : m_impl(makeUniqueRef<Impl>())
{
}

H264BitstreamParser::~H264BitstreamParser() = default;

void H264BitstreamParser::parseBitstream(std::span<const uint8_t> bitstream)
{
    MediaParserByteVector logEvents;
    m_impl->state.parseBitstream({ bitstream }, logEvents);
    for (auto event : logEvents)
        logBitstreamParserEvent(static_cast<H264BitstreamParserLogEvent>(event));
}

std::optional<int> H264BitstreamParser::lastSliceQP() const
{
    auto result = m_impl->state.lastSliceQP();
    if (auto event = static_cast<H264BitstreamParserLogEvent>(result.status); event != H264BitstreamParserLogEvent::None) {
        logBitstreamParserEvent(event);
        return std::nullopt;
    }
    return result.qp;
}

std::optional<uint8_t> H264BitstreamParser::parseSpsMaxNumReorderFrames(std::span<const uint8_t> data)
{
    uint8_t maxNumReorderFrames = 0;
    if (!parseH264SpsMaxNumReorderFramesImpl({ data }, maxNumReorderFrames))
        return std::nullopt;
    return maxNumReorderFrames;
}

std::optional<uint8_t> findH264AnnexBMaxNumReorderFrames(std::span<const uint8_t> data, const Vector<NaluIndex>& naluIndices)
{
    uint8_t maxNumReorderFrames = 0;
    if (!findH264AnnexBMaxNumReorderFramesImpl({ data }, { naluIndices.span() }, maxNumReorderFrames))
        return std::nullopt;
    return maxNumReorderFrames;
}

std::optional<uint8_t> findAVCCMaxNumReorderFrames(std::span<const uint8_t> avcc)
{
    uint8_t maxNumReorderFrames = 0;
    if (!findAVCCMaxNumReorderFramesImpl({ avcc }, maxNumReorderFrames))
        return std::nullopt;
    return maxNumReorderFrames;
}

}

#endif // ENABLE(WEBCORE_SWIFT)
