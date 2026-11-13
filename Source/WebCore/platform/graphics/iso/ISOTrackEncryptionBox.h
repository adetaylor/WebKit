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
#include <span>

namespace WebCore {

class ISOTrackEncryptionBox final : public ISOFullBox {
public:
    ISOTrackEncryptionBox()
        : ISOFullBox(boxTypeName(), 0, 0)
    {
    }

    static FourCC boxTypeName() { return std::span { "tenc" }; }

    std::optional<int8_t> defaultCryptByteBlock() const { return m_defaultCryptByteBlock; }
    std::optional<int8_t> defaultSkipByteBlock() const { return m_defaultSkipByteBlock; }
    int8_t defaultIsProtected() const { return m_defaultIsProtected; }
    int8_t defaultPerSampleIVSize() const { return m_defaultPerSampleIVSize; }
    Vector<uint8_t> defaultKID() const { return m_defaultKID; }
    Vector<uint8_t> defaultConstantIV() const { return m_defaultConstantIV; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        // ISO/IEC 23001-7-2015 Section 8.2.2
        if (!ISOFullBox::pack(view, offset))
            return false;

        // unsigned int(8) reserved = 0;
        if (!checkedWrite<int8_t>(0, view, offset, BigEndian))
            return false;

        if (!m_version) {
            // unsigned int(8) reserved = 0;
            if (!checkedWrite<int8_t>(0, view, offset, BigEndian))
                return false;
        } else {
            int8_t cryptAndSkip = (m_defaultCryptByteBlock.value_or(0) << 4) | (m_defaultSkipByteBlock.value_or(0) & 0xF);
            if (!checkedWrite<int8_t>(cryptAndSkip, view, offset, BigEndian))
                return false;
        }

        if (!checkedWrite<int8_t>(m_defaultIsProtected, view, offset, BigEndian))
            return false;

        if (!checkedWrite<int8_t>(m_defaultPerSampleIVSize, view, offset, BigEndian))
            return false;

        if (m_defaultKID.size() != 16)
            return false;

        if (!checkedWriteSequence<uint8_t>(m_defaultKID, view, offset, BigEndian))
            return false;

        if (m_defaultIsProtected == 1 && !m_defaultPerSampleIVSize) {
            if (m_defaultConstantIV.size() > std::numeric_limits<int8_t>::max())
                return false;

            if (!checkedWrite<int8_t>(static_cast<int8_t>(m_defaultConstantIV.size()), view, offset, BigEndian))
                return false;

            if (!checkedWriteSequence<uint8_t>(m_defaultConstantIV, view, offset, BigEndian))
                return false;
        }

        return true;
    }

private:
    friend class ISOSchemeInformationBox;

    uint64_t partialSize() const final
    {
        // reserved(1) + reserved-or-crypt/skip(1) + isProtected(1) + perSampleIVSize(1) + KID(16)
        uint64_t size = ISOFullBox::partialSize() + 20;

        if (m_defaultIsProtected == 1 && !m_defaultPerSampleIVSize)
            size += 1 + m_defaultConstantIV.size();

        return size;
    }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    ISOTrackEncryptionBoxFields fields() const
    {
        ISOTrackEncryptionBoxFields fields;
        fields.fullBox = fullBoxFields();
        fields.hasDefaultCryptAndSkipByteBlocks = !!m_defaultCryptByteBlock;
        fields.defaultCryptByteBlock = m_defaultCryptByteBlock.value_or(0);
        fields.defaultSkipByteBlock = m_defaultSkipByteBlock.value_or(0);
        fields.defaultIsProtected = m_defaultIsProtected;
        fields.defaultPerSampleIVSize = m_defaultPerSampleIVSize;
        // The key ID is either unread or all 16 bytes.
        if (m_defaultKID.size() == 16) {
            fields.hasDefaultKID = true;
            fields.defaultKID = inlineBytes16(m_defaultKID.span().first<16>());
        }
        return fields;
    }

    void setFields(const ISOTrackEncryptionBoxFields& fields, const ByteView& view)
    {
        setFullBoxFields(fields.fullBox);
        if (fields.hasDefaultCryptAndSkipByteBlocks) {
            m_defaultCryptByteBlock = fields.defaultCryptByteBlock;
            m_defaultSkipByteBlock = fields.defaultSkipByteBlock;
        }
        m_defaultIsProtected = fields.defaultIsProtected;
        m_defaultPerSampleIVSize = fields.defaultPerSampleIVSize;
        if (fields.hasDefaultKID) {
            auto defaultKID = fields.defaultKID.bytes();
            m_defaultKID = std::span { defaultKID };
        }
        if (fields.defaultConstantIVWasRead)
            m_defaultConstantIV = bytes(view, fields.defaultConstantIV);
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOTrackEncryptionBoxFields&);

    std::optional<int8_t> m_defaultCryptByteBlock;
    std::optional<int8_t> m_defaultSkipByteBlock;
    int8_t m_defaultIsProtected { 0 };
    int8_t m_defaultPerSampleIVSize { 0 };
    Vector<uint8_t> m_defaultKID;
    Vector<uint8_t> m_defaultConstantIV;
};

}

SPECIALIZE_TYPE_TRAITS_ISOBOX(ISOTrackEncryptionBox)
