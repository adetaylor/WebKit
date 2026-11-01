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

#include <WebCore/ISOTrackEncryptionBox.h>

namespace WebCore {

class ISOSchemeInformationBox final : public ISOBox {
public:
    ISOSchemeInformationBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "schi" }; }

    const ISOBox* schemeSpecificData() const LIFETIME_BOUND { return m_schemeSpecificData.get(); }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        if (m_schemeSpecificData)
            return m_schemeSpecificData->write(view, offset);

        return true;
    }

    void updateSize() final
    {
        if (m_schemeSpecificData)
            m_schemeSpecificData->updateSize();
        ISOBox::updateSize();
    }

    uint64_t partialSize() const final
    {
        auto size = ISOBox::partialSize();
        if (m_schemeSpecificData)
            size += m_schemeSpecificData->requiredSize();
        return size;
    }

private:
    friend class ISOProtectionSchemeInfoBox;

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    ISOSchemeInformationBoxFields fields() const
    {
        ISOSchemeInformationBoxFields fields;
        fields.box = boxFields();
        return fields;
    }

    void setFields(const ISOSchemeInformationBoxFields& fields, const ByteView& view)
    {
        setBoxFields(fields.box);
        if (fields.trackEncryptionWasRead) {
            auto trackEncryptionBox = makeUnique<ISOTrackEncryptionBox>();
            trackEncryptionBox->setFields(fields.trackEncryption, view);
            m_schemeSpecificData = WTF::move(trackEncryptionBox);
        }
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOSchemeInformationBoxFields&);

    std::unique_ptr<ISOBox> m_schemeSpecificData;
};

}

SPECIALIZE_TYPE_TRAITS_ISOBOX(ISOSchemeInformationBox)
