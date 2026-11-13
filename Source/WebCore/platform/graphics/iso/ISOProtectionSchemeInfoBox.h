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

#include <WebCore/ISOOriginalFormatBox.h>
#include <WebCore/ISOSchemeInformationBox.h>
#include <WebCore/ISOSchemeTypeBox.h>

namespace WebCore {

class ISOProtectionSchemeInfoBox final : public ISOBox {
public:
    ISOProtectionSchemeInfoBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "sinf" }; }

    const ISOOriginalFormatBox& originalFormatBox() const LIFETIME_BOUND { return m_originalFormatBox; }
    const ISOSchemeTypeBox* schemeTypeBox() const LIFETIME_BOUND { return m_schemeTypeBox.get(); }
    const ISOSchemeInformationBox* schemeInformationBox() const LIFETIME_BOUND { return m_schemeInformationBox.get(); }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        if (!m_originalFormatBox.write(view, offset))
            return false;

        if (m_schemeTypeBox && !m_schemeTypeBox->write(view, offset))
            return false;

        if (m_schemeInformationBox && !m_schemeInformationBox->write(view, offset))
            return false;

        return true;
    }

    void updateSize() final
    {
        m_originalFormatBox.updateSize();
        if (m_schemeTypeBox)
            m_schemeTypeBox->updateSize();
        if (m_schemeInformationBox)
            m_schemeInformationBox->updateSize();
        ISOBox::updateSize();
    }

    uint64_t partialSize() const final
    {
        auto size = ISOBox::partialSize();
        size += m_originalFormatBox.requiredSize();
        if (m_schemeTypeBox)
            size += m_schemeTypeBox->requiredSize();
        if (m_schemeInformationBox)
            size += m_schemeInformationBox->requiredSize();
        return size;
    }

private:
    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        ISOProtectionSchemeInfoBoxFields fields;
        fields.box = boxFields();
        fields.originalFormat = m_originalFormatBox.fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    // A schm or schi the parse found replaces the box's own, even if it then fails to read.
    void setFields(const ISOProtectionSchemeInfoBoxFields& fields, const ByteView& view)
    {
        setBoxFields(fields.box);
        m_originalFormatBox.setFields(fields.originalFormat);
        if (fields.schemeTypeWasRead) {
            m_schemeTypeBox = makeUnique<ISOSchemeTypeBox>();
            m_schemeTypeBox->setFields(fields.schemeType);
        }
        if (fields.schemeInformationWasRead) {
            m_schemeInformationBox = makeUnique<ISOSchemeInformationBox>();
            m_schemeInformationBox->setFields(fields.schemeInformation, view);
        }
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOProtectionSchemeInfoBoxFields&);

    ISOOriginalFormatBox m_originalFormatBox;
    std::unique_ptr<ISOSchemeTypeBox> m_schemeTypeBox;
    std::unique_ptr<ISOSchemeInformationBox> m_schemeInformationBox;
};

}

SPECIALIZE_TYPE_TRAITS_ISOBOX(ISOProtectionSchemeInfoBox)
