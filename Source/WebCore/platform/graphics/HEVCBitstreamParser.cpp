/*
 * Copyright (C) 2018-2026 Apple Inc. All rights reserved.
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
#include "HEVCBitstreamParser.h"

#if ENABLE(WEBCORE_SWIFT)

#include "HEVCUtilities.h"
#include "Logging.h"
#include "WebCore-Swift.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

// The parsing is in HEVCBitstreamParser.swift.

std::optional<uint8_t> findHVCCMaxNumReorderPics(const HVCCParameterSets& parameterSets)
{
    for (auto& parameterSet : parameterSets.paramSets) {
        if (parameterSet.type != HEVCNaluType::Vps)
            continue;
        uint8_t maxNumReorderPics = 0;
        if (!parseHEVCVpsMaxNumReorderPicsImpl({ parameterSet.data }, maxNumReorderPics))
            return std::nullopt;
        return maxNumReorderPics;
    }
    return std::nullopt;
}

struct HEVCBitstreamParser::Impl {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(Impl);
public:
    HEVCSliceQPParser parser { HEVCSliceQPParser::init() };
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(HEVCBitstreamParser);

HEVCBitstreamParser::HEVCBitstreamParser() = default;

HEVCBitstreamParser::~HEVCBitstreamParser() = default;

void HEVCBitstreamParser::parseBitstream(std::span<const uint8_t> bitstream)
{
    if (!m_impl)
        m_impl = makeUnique<Impl>();
    m_impl->parser.parseBitstream({ bitstream });
}

// HEVCSliceQPParser::lastSliceQP()'s results.
enum class HEVCLastSliceQPResult : uint8_t { Found, MissingInfo, MissingPps, InvalidQP };

std::optional<int> HEVCBitstreamParser::lastSliceQP() const
{
    auto sliceQP = m_impl ? m_impl->parser.lastSliceQP() : SliceQPResult { .qp = 0, .status = static_cast<uint8_t>(HEVCLastSliceQPResult::MissingInfo) };
    switch (static_cast<HEVCLastSliceQPResult>(sliceQP.status)) {
    case HEVCLastSliceQPResult::Found:
        return sliceQP.qp;
    case HEVCLastSliceQPResult::MissingInfo:
        RELEASE_LOG_ERROR(WebRTC, "Unable to get qp - missing info");
        break;
    case HEVCLastSliceQPResult::MissingPps:
        RELEASE_LOG_ERROR(WebRTC, "Unable to get qp - missing pps");
        break;
    case HEVCLastSliceQPResult::InvalidQP:
        RELEASE_LOG_ERROR(WebRTC, "Unable to get qp - invalid parsed qp");
        break;
    }
    return std::nullopt;
}

} // namespace WebCore

#endif // ENABLE(WEBCORE_SWIFT)
