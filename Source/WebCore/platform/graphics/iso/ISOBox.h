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

#include <WebCore/FourCC.h>
#include <WebCore/ISOParseResults.h>
#include <WebCore/SharedBuffer.h>
#include <algorithm>
#include <wtf/CheckedArithmetic.h>
#include <wtf/FlipBytes.h>
#include <wtf/Forward.h>
#include <wtf/StdIntExtras.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/TypeCasts.h>

namespace WebCore {

// The ISO box classes are shells over the Swift parsers (ISOBoxes.swift, ISOFairPlayStreamingPssh.swift), kept for the
// code that still uses them, such as the API tests. Each parse goes to Swift through the class's exported
// parseFields(), which hands back the fields as the parse left them, also when it fails. Everything else is inline, so
// WebCore only has the parseFields() functions.
class ISOBox {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(ISOBox, WEBCORE_EXPORT);
public:
    ISOBox() = default;
    ISOBox(FourCC boxType)
        : m_boxType { boxType }
    {
    }
    ISOBox(const ISOBox&) = default;
    ISOBox(ISOBox&&) = default;
    virtual ~ISOBox() = default;

    ISOBox& operator=(const ISOBox&) = default;
    ISOBox& operator=(ISOBox&&) = default;

    using ByteView = std::span<const uint8_t>;
    using MutableByteView = std::span<uint8_t>;

    bool read(const ByteView& view)
    {
        unsigned offset = 0;
        return parseUsingSwift(view, offset, ISOBoxParseMode::ReadWhole);
    }

    bool write(MutableByteView& view, unsigned& offset) const
    {
        if (!isInBounds<unsigned>(view.size()))
            return false;

        unsigned localOffset = offset;
        if (!pack(view, localOffset))
            return false;

        unsigned consumed;
        if (!WTF::safeSub(localOffset, offset, consumed) || consumed > m_size)
            return false;

        offset += m_size;
        return true;
    }

    Ref<SharedBuffer> serialize() const
    {
        auto buffer = Vector<uint8_t>(m_size);
        MutableByteView view = buffer.mutableSpan();
        unsigned offset = 0;
        if (!write(view, offset))
            return SharedBuffer::create();

        return SharedBuffer::create(WTF::move(buffer));
    }

    uint64_t size() const { return m_size; }
    FourCC boxType() const { return m_boxType; }
    using ExtendedType = std::array<uint8_t, 16>;
    const std::optional<ExtendedType>& extendedType() const LIFETIME_BOUND { return m_extendedType; }

    virtual void updateSize() { m_size = requiredSize(); }

    virtual uint64_t partialSize() const
    {
        uint64_t size = 8;
        if (m_boxType == std::span { "uuid" })
            size += 16;
        return size;
    }

    virtual uint64_t requiredSize() const
    {
        auto partialSize = this->partialSize();
        if (partialSize > std::numeric_limits<uint32_t>::max())
            partialSize += 4;
        return partialSize;
    }

protected:
    bool parse(const ByteView& view, unsigned& offset) { return parseUsingSwift(view, offset, ISOBoxParseMode::Parse); }

    // A box of any type, of which only the header is read.
    virtual bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode)
    {
        auto fields = boxFields();
        bool result = parseFields(view, offset, mode, fields);
        setBoxFields(fields);
        return result;
    }

    virtual bool pack(MutableByteView& view, unsigned& offset) const
    {
        uint32_t firstSize = 1u;
        if (m_size <= std::numeric_limits<uint32_t>::max())
            firstSize = m_size;

        if (!checkedWrite<uint32_t>(firstSize, view, offset, BigEndian))
            return false;

        if (!checkedWrite<uint32_t>(m_boxType.value, view, offset, BigEndian))
            return false;

        if (firstSize == 1 && !checkedWrite<uint64_t>(m_size, view, offset, BigEndian))
            return false;

        if (m_boxType == std::span { "uuid" }) {
            ASSERT(m_extendedType);
            if (!m_extendedType)
                return false;

            if (!checkedWriteSequence<uint8_t>(*m_extendedType, view, offset, BigEndian))
                return false;
        }

        return true;
    }

    enum Endianness { BigEndian, LittleEndian };

    template<typename T, typename R>
    static bool checkedWrite(const R& value, MutableByteView& view, unsigned& offset, Endianness endianness)
    {
        if (offset + sizeof(T) > view.size())
            return false;

        T flipped = flipBytesIfLittleEndian(static_cast<T>(value), endianness == LittleEndian);
        memcpySpan(view.subspan(offset, sizeof(T)), asByteSpan(flipped));
        offset += sizeof(T);
        RELEASE_ASSERT(isInBounds<uint32_t>(offset));
        return true;
    }

    template<typename T, typename S>
    static bool checkedWriteSequence(const S& sequence, MutableByteView& view, unsigned& offset, Endianness endianness)
    {
        unsigned actualOffset = offset;
        for (auto& value : sequence) {
            if (!checkedWrite<T>(value, view, actualOffset, endianness))
                return false;
        }
        offset = actualOffset;
        return true;
    }

    // The Swift parsers keep 16-byte values in two big-endian words.
    static InlineBytes16 inlineBytes16(std::span<const uint8_t, 16> bytes)
    {
        InlineBytes16 result;
        for (size_t index = 0; index < 8; ++index) {
            result.high = result.high << 8 | bytes[index];
            result.low = result.low << 8 | bytes[index + 8];
        }
        return result;
    }

    // The bytes of a range Swift returned, which is always within the view it parsed.
    static Vector<uint8_t> bytes(const ByteView& view, const ISOByteRange& range) { return view.subspan(range.offset, range.size); }

    // The class keeps the uuid extended type byte-reversed, as one big-endian 16-byte value; Swift's fields hold it in
    // box order.
    ISOBoxFields boxFields() const
    {
        ISOBoxFields fields { m_size, m_boxType.value, !!m_extendedType, { } };
        if (m_extendedType) {
            auto extendedType = *m_extendedType;
            std::ranges::reverse(extendedType);
            fields.extendedType = inlineBytes16(extendedType);
        }
        return fields;
    }

    void setBoxFields(const ISOBoxFields& fields)
    {
        m_size = fields.size;
        m_boxType = fields.type;
        if (fields.hasExtendedType) {
            auto extendedType = fields.extendedType.bytes();
            std::ranges::reverse(extendedType);
            m_extendedType = extendedType;
        }
    }

    uint64_t m_size { 0 };
    FourCC m_boxType;
    std::optional<ExtendedType> m_extendedType;

private:
    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOBoxFields&);
};

class ISOFullBox : public ISOBox {
public:
    uint8_t version() const { return m_version; }
    uint32_t flags() const { return m_flags; }

protected:
    ISOFullBox(FourCC boxType, uint8_t version, uint32_t flags)
        : ISOBox(boxType)
        , m_version { version }
        , m_flags { flags }
    {
    }
    ISOFullBox(const ISOFullBox&) = default;
    ISOFullBox(ISOFullBox&&) = default;

    uint64_t partialSize() const override { return ISOBox::partialSize() + 4; }

    bool pack(MutableByteView& view, unsigned& offset) const override
    {
        if (!ISOBox::pack(view, offset))
            return false;

        uint32_t versionAndFlags = (m_version << 24) + m_flags;
        if (!checkedWrite<uint32_t>(versionAndFlags, view, offset, BigEndian))
            return false;

        return true;
    }

    ISOFullBoxFields fullBoxFields() const { return { boxFields(), m_version, m_flags }; }

    void setFullBoxFields(const ISOFullBoxFields& fields)
    {
        setBoxFields(fields.box);
        m_version = fields.version;
        m_flags = fields.flags;
    }

    uint8_t m_version { 0 };
    uint32_t m_flags { 0 };
};

}

#define SPECIALIZE_TYPE_TRAITS_ISOBOX(ISOBoxType) \
SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::ISOBoxType) \
static bool isType(const WebCore::ISOBox& box) { return box.boxType() == WebCore::ISOBoxType::boxTypeName(); } \
SPECIALIZE_TYPE_TRAITS_END()
