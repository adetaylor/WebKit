/*
 * Copyright (C) 2019-2026 Apple Inc. All rights reserved.
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

#include <WebCore/ISOProtectionSystemSpecificHeaderBox.h>

namespace WebCore {

class ISOFairPlayStreamingInfoBox final : public ISOFullBox {
public:
    ISOFairPlayStreamingInfoBox()
        : ISOFullBox(boxTypeName(), 0, 0)
    {
    }

    static FourCC boxTypeName() { return std::span { "fpsi" }; }

    void setScheme(FourCC scheme) { m_scheme = scheme; }
    FourCC scheme() const { return m_scheme; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOFullBox::pack(view, offset))
            return false;

        return checkedWrite<uint32_t>(m_scheme.value, view, offset, BigEndian);
    }

private:
    friend class ISOFairPlayStreamingInitDataBox;

    uint64_t partialSize() const final { return ISOFullBox::partialSize() + sizeof(uint32_t); }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields);
        return result;
    }

    ISOFairPlayStreamingInfoBoxFields fields() const { return { fullBoxFields(), m_scheme.value }; }

    void setFields(const ISOFairPlayStreamingInfoBoxFields& fields)
    {
        setFullBoxFields(fields.fullBox);
        m_scheme = fields.scheme;
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingInfoBoxFields&);

    FourCC m_scheme;
};

class ISOFairPlayStreamingKeyRequestInfoBox final : public ISOFullBox {
public:
    ISOFairPlayStreamingKeyRequestInfoBox()
        : ISOFullBox(boxTypeName(), 0, 0)
    {
        // The key ID is a fixed-width field, so a default-constructed box has to start out with one:
        // parse() requires capacity() bytes to be present, and a box written without them would not
        // be readable back. Match the length parse() expects rather than hard-coding it here.
        m_keyID.fill(0, m_keyID.capacity());
    }

    static FourCC boxTypeName() { return std::span { "fkri" }; }

    using KeyID = Vector<uint8_t, 16>;
    void setKeyID(KeyID keyID) { m_keyID = keyID; }
    const KeyID& keyID() const LIFETIME_BOUND { return m_keyID; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOFullBox::pack(view, offset))
            return false;

        return checkedWriteSequence<uint8_t>(m_keyID, view, offset, BigEndian);
    }

private:
    friend class ISOFairPlayStreamingKeyRequestBox;

    uint64_t partialSize() const final { return ISOFullBox::partialSize() + m_keyID.size(); }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    ISOFairPlayStreamingKeyRequestInfoBoxFields fields() const
    {
        ISOFairPlayStreamingKeyRequestInfoBoxFields fields;
        fields.fullBox = fullBoxFields();
        fields.keyIDCapacity = m_keyID.capacity();
        return fields;
    }

    void setFields(const ISOFairPlayStreamingKeyRequestInfoBoxFields& fields, const ByteView& view)
    {
        setFullBoxFields(fields.fullBox);
        if (fields.keyIDWasRead)
            m_keyID = view.subspan(fields.keyID.offset, fields.keyID.size);
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingKeyRequestInfoBoxFields&);

    KeyID m_keyID;
};

class ISOFairPlayStreamingKeyAssetIdBox final : public ISOBox {
public:
    ISOFairPlayStreamingKeyAssetIdBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "fkai" }; }
    const Vector<uint8_t>& data() const LIFETIME_BOUND { return m_data; }
    Vector<uint8_t>& data() LIFETIME_BOUND { return m_data; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        return checkedWriteSequence<uint8_t>(m_data, view, offset, BigEndian);
    }

private:
    friend class ISOFairPlayStreamingKeyRequestBox;

    uint64_t partialSize() const final { return ISOBox::partialSize() + m_data.size(); }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        ISOFairPlayStreamingKeyDataBoxFields fields;
        fields.box = boxFields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    void setFields(const ISOFairPlayStreamingKeyDataBoxFields& fields, const ByteView& view)
    {
        setBoxFields(fields.box);
        if (fields.dataWasRead)
            m_data = bytes(view, fields.data);
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingKeyDataBoxFields&);

    Vector<uint8_t> m_data;
};

class ISOFairPlayStreamingKeyContextBox final : public ISOBox {
public:
    ISOFairPlayStreamingKeyContextBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "fkcx" }; }
    const Vector<uint8_t>& data() const LIFETIME_BOUND { return m_data; }
    Vector<uint8_t>& data() LIFETIME_BOUND { return m_data; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        return checkedWriteSequence<uint8_t>(m_data, view, offset, BigEndian);
    }

private:
    friend class ISOFairPlayStreamingKeyRequestBox;

    uint64_t partialSize() const final { return ISOBox::partialSize() + m_data.size(); }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        ISOFairPlayStreamingKeyDataBoxFields fields;
        fields.box = boxFields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    void setFields(const ISOFairPlayStreamingKeyDataBoxFields& fields, const ByteView& view)
    {
        setBoxFields(fields.box);
        if (fields.dataWasRead)
            m_data = bytes(view, fields.data);
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingKeyDataBoxFields&);

    Vector<uint8_t> m_data;
};

class ISOFairPlayStreamingKeyVersionListBox final : public ISOBox {
public:
    ISOFairPlayStreamingKeyVersionListBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "fkvl" }; }
    const Vector<uint32_t>& versions() const LIFETIME_BOUND { return m_versions; }
    Vector<uint32_t>& versions() LIFETIME_BOUND { return m_versions; }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        return checkedWriteSequence<uint32_t>(m_versions, view, offset, BigEndian);
    }

private:
    friend class ISOFairPlayStreamingKeyRequestBox;

    uint64_t partialSize() const final { return ISOBox::partialSize() + m_versions.size() * sizeof(uint32_t); }

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        ISOFairPlayStreamingKeyVersionListBoxFields fields;
        fields.box = boxFields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    // The versions a parse appended stay even if it then failed.
    void setFields(const ISOFairPlayStreamingKeyVersionListBoxFields& fields, const ByteView& view)
    {
        setBoxFields(fields.box);
        auto versions = view.subspan(fields.appendedVersions.offset, fields.appendedVersions.size);
        for (size_t versionOffset = 0; versionOffset < versions.size(); versionOffset += sizeof(uint32_t)) {
            uint32_t version;
            memcpySpan(asMutableByteSpan(version), versions.subspan(versionOffset, sizeof(uint32_t)));
            m_versions.append(flipBytesIfLittleEndian(version, false));
        }
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingKeyVersionListBoxFields&);

    Vector<uint32_t> m_versions;
};

class ISOFairPlayStreamingKeyRequestBox final : public ISOBox {
public:
    ISOFairPlayStreamingKeyRequestBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "fpsk" }; }

    const ISOFairPlayStreamingKeyRequestInfoBox& requestInfo() const LIFETIME_BOUND { return m_requestInfo; }
    ISOFairPlayStreamingKeyRequestInfoBox& requestInfo() LIFETIME_BOUND { return m_requestInfo; }

    const std::optional<ISOFairPlayStreamingKeyAssetIdBox>& assetID() const LIFETIME_BOUND { return m_assetID; }
    void setAssetID(std::optional<ISOFairPlayStreamingKeyAssetIdBox>&& assetID) { m_assetID = WTF::move(assetID); }

    const std::optional<ISOFairPlayStreamingKeyContextBox>& content() const LIFETIME_BOUND { return m_context; }
    void setContent(std::optional<ISOFairPlayStreamingKeyContextBox>&& content)  { m_context = WTF::move(content); }

    const std::optional<ISOFairPlayStreamingKeyVersionListBox>& versionList() const LIFETIME_BOUND { return m_versionList; }
    void setVersionList(std::optional<ISOFairPlayStreamingKeyVersionListBox>&& versionList)  { m_versionList = WTF::move(versionList); }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        if (!m_requestInfo.write(view, offset))
            return false;

        if (m_assetID && !m_assetID->write(view, offset))
            return false;

        if (m_context && !m_context->write(view, offset))
            return false;

        if (m_versionList && !m_versionList->write(view, offset))
            return false;

        return true;
    }

    void updateSize() final
    {
        m_requestInfo.updateSize();
        if (m_assetID)
            m_assetID->updateSize();
        if (m_context)
            m_context->updateSize();
        if (m_versionList)
            m_versionList->updateSize();
        ISOBox::updateSize();
    }

    uint64_t partialSize() const final
    {
        auto size = ISOBox::partialSize();
        size += m_requestInfo.requiredSize();
        if (m_assetID)
            size += m_assetID->requiredSize();
        if (m_context)
            size += m_context->requiredSize();
        if (m_versionList)
            size += m_versionList->requiredSize();
        return size;
    }

private:
    friend class ISOFairPlayStreamingInitDataBox;

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        bool result = parseFields(view, offset, mode, fields);
        setFields(fields, view);
        return result;
    }

    // Swift needs to know which children the box already has, since a second one fails the parse.
    ISOFairPlayStreamingKeyRequestBoxFields fields() const
    {
        ISOFairPlayStreamingKeyRequestBoxFields fields;
        fields.box = boxFields();
        fields.requestInfo = m_requestInfo.fields();
        fields.hasAssetID = !!m_assetID;
        fields.hasContext = !!m_context;
        fields.hasVersionList = !!m_versionList;
        return fields;
    }

    void setFields(const ISOFairPlayStreamingKeyRequestBoxFields& fields, const ByteView& view)
    {
        setBoxFields(fields.box);
        m_requestInfo.setFields(fields.requestInfo, view);
        if (!m_assetID && fields.hasAssetID) {
            ISOFairPlayStreamingKeyAssetIdBox assetID;
            assetID.setFields(fields.assetID, view);
            m_assetID = WTF::move(assetID);
        }
        if (!m_context && fields.hasContext) {
            ISOFairPlayStreamingKeyContextBox context;
            context.setFields(fields.context, view);
            m_context = WTF::move(context);
        }
        if (!m_versionList && fields.hasVersionList) {
            ISOFairPlayStreamingKeyVersionListBox versionList;
            versionList.setFields(fields.versionList, view);
            m_versionList = WTF::move(versionList);
        }
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingKeyRequestBoxFields&);

    ISOFairPlayStreamingKeyRequestInfoBox m_requestInfo;
    std::optional<ISOFairPlayStreamingKeyAssetIdBox> m_assetID;
    std::optional<ISOFairPlayStreamingKeyContextBox> m_context;
    std::optional<ISOFairPlayStreamingKeyVersionListBox> m_versionList;
};

class ISOFairPlayStreamingInitDataBox final : public ISOBox {
public:
    ISOFairPlayStreamingInitDataBox()
        : ISOBox(boxTypeName())
    {
    }

    static FourCC boxTypeName() { return std::span { "fpsd" }; }

    const ISOFairPlayStreamingInfoBox& info() const LIFETIME_BOUND { return m_info; }
    ISOFairPlayStreamingInfoBox& info() LIFETIME_BOUND { return m_info; }

    const Vector<ISOFairPlayStreamingKeyRequestBox>& requests() const LIFETIME_BOUND { return m_requests; }
    void setRequests(Vector<ISOFairPlayStreamingKeyRequestBox>&& requests) { m_requests = WTF::move(requests); }

    using ISOBox::parse;

    bool pack(MutableByteView& view, unsigned& offset) const final
    {
        if (!ISOBox::pack(view, offset))
            return false;

        if (!m_info.write(view, offset))
            return false;

        for (auto& request : m_requests) {
            if (!request.write(view, offset))
                return false;
        }

        return true;
    }

    void updateSize() final
    {
        m_info.updateSize();
        for (auto& request : m_requests)
            request.updateSize();
        ISOBox::updateSize();
    }

    uint64_t partialSize() const final
    {
        auto size = ISOBox::partialSize();
        size += m_info.requiredSize();
        for (auto& request : m_requests)
            size += request.requiredSize();
        return size;
    }

private:
    friend class ISOFairPlayStreamingPsshBox;

    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        auto fields = this->fields();
        ISOFairPlayStreamingKeyRequestBoxFieldsVector appendedRequests;
        bool result = parseFields(view, offset, mode, fields, appendedRequests);
        setFields(fields, appendedRequests, view);
        return result;
    }

    ISOFairPlayStreamingInitDataBoxFields fields() const { return { boxFields(), m_info.fields() }; }

    // The requests a parse appended stay even if it then failed.
    void setFields(const ISOFairPlayStreamingInitDataBoxFields& fields, const ISOFairPlayStreamingKeyRequestBoxFieldsVector& appendedRequests, const ByteView& view)
    {
        setBoxFields(fields.box);
        m_info.setFields(fields.info);
        for (auto& requestFields : appendedRequests) {
            ISOFairPlayStreamingKeyRequestBox request;
            request.setFields(requestFields, view);
            m_requests.append(WTF::move(request));
        }
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingInitDataBoxFields&, ISOFairPlayStreamingKeyRequestBoxFieldsVector& appendedRequests);

    ISOFairPlayStreamingInfoBox m_info;
    Vector<ISOFairPlayStreamingKeyRequestBox> m_requests;
};

class ISOFairPlayStreamingPsshBox final : public ISOProtectionSystemSpecificHeaderBox {
public:
    ISOFairPlayStreamingPsshBox()
        : ISOProtectionSystemSpecificHeaderBox(fairPlaySystemID())
    {
    }

    NODELETE static const SystemID& fairPlaySystemID()
    {
        static constexpr SystemID systemID { 0x94, 0xCE, 0x86, 0xFB, 0x07, 0xFF, 0x4F, 0x43, 0xAD, 0xB8, 0x93, 0xD2, 0xFA, 0x96, 0x8C, 0xA2 };
        return systemID;
    }

    const ISOFairPlayStreamingInitDataBox& initDataBox() const LIFETIME_BOUND { return m_initDataBox; }
    ISOFairPlayStreamingInitDataBox& initDataBox() LIFETIME_BOUND { return m_initDataBox; }

    uint64_t dataSize() const final { return m_initDataBox.size(); }
    bool writeData(MutableByteView& view, unsigned& offset) const final { return m_initDataBox.write(view, offset); }

    void updateSize() final
    {
        m_initDataBox.updateSize();
        ISOBox::updateSize();
    }

    uint64_t partialSize() const final
    {
        // ISOProtectionSystemSpecificHeaderBox::partialSize() adds its base size
        // to the size of m_data. However, as our Data is m_initDataBox, it should
        // be the case that m_data is empty. Assert so, and just in case, subtract out
        // its size from our super classes' partial size.
        ASSERT(!m_data.size());
        return ISOProtectionSystemSpecificHeaderBox::partialSize()
            - m_data.size()
            + m_initDataBox.requiredSize();
    }

private:
    // The pssh's Data is an fpsd, which is parsed into the box's own.
    bool parseUsingSwift(const ByteView& view, unsigned& offset, ISOBoxParseMode mode) final
    {
        ISOFairPlayStreamingPsshBoxFields fields { psshFields(), m_initDataBox.fields() };
        ISOFairPlayStreamingKeyRequestBoxFieldsVector appendedRequests;
        bool result = parseFields(view, offset, mode, fields, appendedRequests);
        setPsshFields(fields.pssh, view);
        m_initDataBox.setFields(fields.initData, appendedRequests, view);
        return result;
    }

    WEBCORE_EXPORT static bool parseFields(const ByteView&, unsigned& offset, ISOBoxParseMode, ISOFairPlayStreamingPsshBoxFields&, ISOFairPlayStreamingKeyRequestBoxFieldsVector& appendedRequests);

    ISOFairPlayStreamingInitDataBox m_initDataBox;
};

}

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::ISOFairPlayStreamingPsshBox) \
static bool isType(const WebCore::ISOProtectionSystemSpecificHeaderBox& psshBox) { return psshBox.systemID() == WebCore::ISOFairPlayStreamingPsshBox::fairPlaySystemID(); }
SPECIALIZE_TYPE_TRAITS_END()
