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

#pragma once

#include <WebCore/ISOBox.h>

namespace WebCore {

class ISOSchemeTypeBox final : public ISOFullBox {
public:
    ISOSchemeTypeBox()
        : ISOFullBox(boxTypeName(), 0, 0)
    {
    }

    static FourCC boxTypeName() { return std::span { "schm" }; }

    FourCC schemeType() const { return m_schemeType; }
    uint32_t schemeVersion() const { return m_schemeVersion; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOFullBox::pack(view, offset))
            return false;

        if (!checkedWrite<uint32_t>(m_schemeType.value, view, offset, BigEndian))
            return false;

        return checkedWrite<uint32_t>(m_schemeVersion, view, offset, BigEndian);
    }

private:
    friend class ISOProtectionSchemeInfoBox;

    uint64_t partialSize() const final { return ISOFullBox::partialSize() + 8; }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields);
        return result;
    }

    ISOSchemeTypeBoxFields fields() const { return { fullBoxFields(), m_schemeType.value, m_schemeVersion }; }

    void setFields(const ISOSchemeTypeBoxFields& fields)
    {
        setFullBoxFields(fields.fullBox);
        m_schemeType = fields.schemeType;
        m_schemeVersion = fields.schemeVersion;
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOSchemeTypeBoxFields&);

    FourCC m_schemeType;
    uint32_t m_schemeVersion { 0 };
};

}

SPECIALIZE_TYPE_TRAITS_ISOBOX(ISOSchemeTypeBox)
