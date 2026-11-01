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

#pragma once

#include <memory>
#include <optional>
#include <span>
#include <wtf/Forward.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

struct HVCCParameterSets;
struct NaluIndex;

// Type values 0-40 are defined in Table 7-1, 48-49 in RFC 7798 sections 4.4.2/4.4.3.
enum class HEVCNaluType : uint8_t {
    TrailN = 0,
    TrailR = 1,
    TsaN = 2,
    TsaR = 3,
    StsaN = 4,
    StsaR = 5,
    RadlN = 6,
    RadlR = 7,
    BlaWLp = 16,
    BlaWRadl = 17,
    BlaNLp = 18,
    IdrWRadl = 19,
    IdrNLp = 20,
    Cra = 21,
    RsvIrapVcl23 = 23,
    RsvVcl31 = 31,
    Vps = 32,
    Sps = 33,
    Pps = 34,
    Aud = 35,
    PrefixSei = 39,
    SuffixSei = 40,
    Ap = 48,
    Fu = 49,
    Paci = 50
};

// Scans a parsed "hvcC" box for a VPS NAL unit to return its vps_max_num_reorder_pics or std::nullopt if no VPS or error.
WEBCORE_EXPORT std::optional<uint8_t> findHVCCMaxNumReorderPics(const HVCCParameterSets&);

// Stateful H.265 Annex B bitstream parser used to recover the QP of the most recently parsed slice.
class WEBCORE_EXPORT HEVCBitstreamParser {
    WTF_MAKE_TZONE_ALLOCATED(HEVCBitstreamParser);
public:
    HEVCBitstreamParser();
    ~HEVCBitstreamParser();

    void parseBitstream(std::span<const uint8_t>);
    std::optional<int> lastSliceQP() const;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

}
