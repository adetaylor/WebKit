/*
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2018 Metrological Group B.V.
 * Copyright (C) 2018 Igalia S.L
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

class ISOProtectionSystemSpecificHeaderBox : public ISOFullBox {
public:
    using KeyID = std::array<uint8_t, 16>;
    using SystemID = std::array<uint8_t, 16>;

    NODELETE static const SystemID& commonSystemID()
    {
        static constexpr SystemID systemID { 0x10, 0x77, 0xef, 0xec, 0xc0, 0xb2, 0x4d, 0x02, 0xac, 0xe3, 0x3c, 0x1e, 0x52, 0xe2, 0xfb, 0x4b };
        return systemID;
    }

    ISOProtectionSystemSpecificHeaderBox()
        : ISOFullBox(boxTypeName(), 0, 0)
        , m_systemID { }
    {
    }

    ISOProtectionSystemSpecificHeaderBox(SystemID systemID)
        : ISOFullBox(boxTypeName(), 0, 0)
        , m_systemID { systemID }
    {
    }

    static FourCC boxTypeName() { return std::span { "pssh" }; }

    const SystemID& systemID() const LIFETIME_BOUND { return m_systemID; }
    const Vector<KeyID>& keyIDs() const LIFETIME_BOUND { return m_keyIDs; }
    const Vector<uint8_t>& data() const LIFETIME_BOUND { return m_data; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const override
    {
        if (!ISOFullBox::pack(view, offset))
            return false;

        if (!checkedWriteSequence<uint8_t>(m_systemID, view, offset, BigEndian))
            return false;

        if (m_version) {
            if (!checkedWrite<uint32_t>(m_keyIDs.size(), view, offset, BigEndian))
                return false;
            for (auto& keyID : m_keyIDs) {
                if (!checkedWriteSequence<uint8_t>(keyID, view, offset, BigEndian))
                    return false;
            }
        }

        if (!checkedWrite<uint32_t>(dataSize(), view, offset, BigEndian))
            return false;

        return writeData(view, offset);
    }

protected:
    virtual uint64_t dataSize() const { return m_data.size(); }

    virtual bool writeData(MutableByteView& view, unsigned& offset) const
    {
        return checkedWriteSequence<uint8_t>(m_data, view, offset, BigEndian);
    }

    uint64_t partialSize() const override
    {
        uint64_t size = ISOFullBox::partialSize();

        // unsigned int(8)[16] SystemID;
        size += 16;

        if (version() > 0) {
            // unsigned int(32) KID_count;
            size += 4;
            // {
            // unsigned int(8)[16] KID;
            // } [KID_count];
            size += 16 * m_keyIDs.size();
        }

        // unsigned int(32) DataSize;
        size += 4;
        // unsigned int(8)[DataSize] Data;
        size += m_data.size();

        return size;
    }

    ISOProtectionSystemSpecificHeaderBoxFields psshFields() const
    {
        ISOProtectionSystemSpecificHeaderBoxFields fields;
        fields.fullBox = fullBoxFields();
        fields.systemID = inlineBytes16(m_systemID);
        return fields;
    }

    void setPsshFields(const ISOProtectionSystemSpecificHeaderBoxFields& fields, const ByteView& view)
    {
        setFullBoxFields(fields.fullBox);
        m_systemID = fields.systemID.bytes();
        if (fields.keyIDsWereRead) {
            auto keyIDs = view.subspan(fields.keyIDs.offset, fields.keyIDs.size);
            m_keyIDs.clear();
            for (size_t keyIDOffset = 0; keyIDOffset < keyIDs.size(); keyIDOffset += sizeof(KeyID)) {
                KeyID keyID;
                memcpySpan(std::span { keyID }, keyIDs.subspan(keyIDOffset, sizeof(KeyID)));
                m_keyIDs.append(keyID);
            }
        }
        if (fields.dataWasRead)
            m_data = bytes(view, fields.data);
    }

    SystemID m_systemID;
    Vector<KeyID> m_keyIDs;
    Vector<uint8_t> m_data;

private:
    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) override
    {
        auto fields = psshFields();
        bool result = parseFields(view, offset, mode, fields);
        setPsshFields(fields, view);
        return result;
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOProtectionSystemSpecificHeaderBoxFields&);
};

}

SPECIALIZE_TYPE_TRAITS_ISOBOX(ISOProtectionSystemSpecificHeaderBox)
