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

#pragma once

#include <optional>
#include <span>
#include <wtf/Forward.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>

namespace WebCore {

struct NaluIndex;

WEBCORE_EXPORT std::optional<uint8_t> findH264AnnexBMaxNumReorderFrames(std::span<const uint8_t>, const Vector<NaluIndex>&);
WEBCORE_EXPORT std::optional<uint8_t> findAVCCMaxNumReorderFrames(std::span<const uint8_t>);

// Stateful H.264 Annex B bitstream parser used to recover the QP of the most recently parsed slice.
class WEBCORE_EXPORT H264BitstreamParser {
    WTF_MAKE_TZONE_ALLOCATED(H264BitstreamParser);
public:
    H264BitstreamParser();
    ~H264BitstreamParser();

    void parseBitstream(std::span<const uint8_t>);
    std::optional<int> lastSliceQP() const;

    static std::optional<uint8_t> parseSpsMaxNumReorderFrames(std::span<const uint8_t>);

private:
    struct Impl;
    const UniqueRef<Impl> m_impl;
};

}
