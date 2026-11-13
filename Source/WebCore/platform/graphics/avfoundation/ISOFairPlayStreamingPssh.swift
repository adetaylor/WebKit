// Copyright (C) 2019-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

// The safe Span overload Swift synthesizes for MediaParserBytes.span() calls a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.ISOParseResults
import WebCore_Private.Core.MediaParsersCxxBridging

// The FairPlay Streaming init data a 'pssh' box carries, for the ISOFairPlayStreaming*Box shells
// (ISOFairPlayStreamingPsshBox.h): as in ISOBoxes.swift, each box holds its C++ shell's fields and parses in place, no
// parser checks the type of the box it is given, and variable payloads are ranges of positions in the bytes that were
// parsed. Children aren't bounded by their parent: a parent's parse can end past its own size, and its read then fails.

// ISOFairPlayStreamingInfoBox ('fpsi').
struct FairPlayStreamingInfoBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x6670_7369 // 'fpsi'

    var fields: WebCore.ISOFairPlayStreamingInfoBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.fullBox.box)
    }

    var scheme: UInt32 {
        fields.scheme
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOFairPlayStreamingInfoBoxFields, _ cursor: inout ByteCursor) -> Bool {
        guard fields.fullBox.parseInPlace(&cursor), let scheme = cursor.readUInt32() else {
            return false
        }
        fields.scheme = scheme
        return true
    }
}

extension FairPlayStreamingInfoBox {
    init() {
        self.init(fields: WebCore.ISOFairPlayStreamingInfoBoxFields(fullBox: WebCore.ISOFullBoxFields(type: Self.boxType), scheme: 0))
    }
}

// ISOFairPlayStreamingKeyRequestInfoBox ('fkri'): the key ID, which must fit in the box. A parse reads as many bytes as
// the key ID Vector's capacity, which is 16 unless a longer key ID was set, and never less.
struct FairPlayStreamingKeyRequestInfoBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x666B_7269 // 'fkri'

    var fields: WebCore.ISOFairPlayStreamingKeyRequestInfoBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.fullBox.box)
    }

    // Positions in the parsed bytes, once read.
    var keyIDPositions: Range<Int>? {
        fields.keyIDWasRead ? fields.keyID.range : nil
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOFairPlayStreamingKeyRequestInfoBoxFields, _ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var boxCursor = cursor
        guard fields.fullBox.parseInPlace(&boxCursor) else {
            return false
        }
        let consumed = UInt64(boxCursor.offset &- start)
        let size = fields.fullBox.box.size
        let capacity = fields.keyIDCapacity
        guard capacity >= 16, consumed <= size, size - consumed >= UInt64(capacity), boxCursor.canRead(capacity) else {
            return false
        }
        fields.keyIDWasRead = true
        fields.keyID = WebCore.ISOByteRange(offset: Int(boxCursor.offset), size: capacity)
        boxCursor.advance(by: UInt64(capacity))
        cursor.offset = boxCursor.offset
        return true
    }
}

extension FairPlayStreamingKeyRequestInfoBox {
    init() {
        var fields = WebCore.ISOFairPlayStreamingKeyRequestInfoBoxFields()
        fields.fullBox = WebCore.ISOFullBoxFields(type: Self.boxType)
        self.init(fields: fields)
    }
}

// ISOFairPlayStreamingKeyAssetIdBox ('fkai') and ISOFairPlayStreamingKeyContextBox ('fkcx'): the header, then data up
// to the box's size, which (clamped to the view like every size) must be at least the header.
struct FairPlayStreamingKeyDataBox: ISOBoxInPlaceParsing {
    static let assetIDType: UInt32 = 0x666B_6169 // 'fkai'
    static let contextType: UInt32 = 0x666B_6378 // 'fkcx'

    var fields: WebCore.ISOFairPlayStreamingKeyDataBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    // The cursor only moves on success.
    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOFairPlayStreamingKeyDataBoxFields, _ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var boxCursor = cursor
        guard fields.box.parseInPlace(&boxCursor) else {
            return false
        }
        let consumed = UInt64(boxCursor.offset &- start)
        let size = fields.box.size
        let dataStart = Int(boxCursor.offset)
        if consumed != size {
            guard consumed < size, let remainingInView = boxCursor.remaining, UInt64(remainingInView) >= size - consumed else {
                return false
            }
            boxCursor.advance(by: size - consumed)
        }
        fields.dataWasRead = true
        fields.data = WebCore.ISOByteRange(offset: dataStart, size: Int(boxCursor.offset) - dataStart)
        cursor.offset = boxCursor.offset
        return true
    }
}

extension FairPlayStreamingKeyDataBox {
    // Neither box checks its type, so this is either one.
    init() {
        self.init(type: Self.assetIDType)
    }

    init(type: UInt32) {
        var fields = WebCore.ISOFairPlayStreamingKeyDataBoxFields()
        fields.box = WebCore.ISOBoxFields(type: type)
        self.init(fields: fields)
    }
}

// ISOFairPlayStreamingKeyVersionListBox ('fkvl'): 32-bit versions up to the box's size, which must hold a whole number
// of them.
struct FairPlayStreamingKeyVersionListBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x666B_766C // 'fkvl'

    var fields: WebCore.ISOFairPlayStreamingKeyVersionListBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    // The versions this parse appended stay appended if it then fails. The cursor only moves on success.
    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOFairPlayStreamingKeyVersionListBoxFields, _ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var boxCursor = cursor
        guard fields.box.parseInPlace(&boxCursor) else {
            return false
        }
        let size = fields.box.size
        fields.appendedVersions = WebCore.ISOByteRange(offset: Int(boxCursor.offset), size: 0)
        while UInt64(boxCursor.offset &- start) != size {
            let consumed = UInt64(boxCursor.offset &- start)
            guard consumed <= size, size - consumed >= 4, boxCursor.readUInt32() != nil else {
                return false
            }
            fields.appendedVersions.size += 4
        }
        cursor.offset = boxCursor.offset
        return true
    }
}

extension FairPlayStreamingKeyVersionListBox {
    init() {
        self.init(
            fields: WebCore.ISOFairPlayStreamingKeyVersionListBoxFields(
                box: WebCore.ISOBoxFields(type: Self.boxType),
                appendedVersions: WebCore.ISOByteRange()
            )
        )
    }
}

// ISOFairPlayStreamingKeyRequestBox ('fpsk'): an fkri, whatever its type, then at most one each of fkai, fkcx and
// fkvl, in any order, until the box's size is reached. Any other child fails, and so does a child the box already has
// (a C++ box may have one from an earlier parse). The cursor only moves on success.
struct FairPlayStreamingKeyRequestBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x6670_736B // 'fpsk'

    var fields: WebCore.ISOFairPlayStreamingKeyRequestBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    var requestInfo: FairPlayStreamingKeyRequestInfoBox {
        FairPlayStreamingKeyRequestInfoBox(fields: fields.requestInfo)
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOFairPlayStreamingKeyRequestBoxFields, _ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var boxCursor = cursor
        guard fields.box.parseInPlace(&boxCursor) else {
            return false
        }
        let size = fields.box.size
        var offset = boxCursor.offset
        var requestInfo = FairPlayStreamingKeyRequestInfoBox(fields: fields.requestInfo)
        let requestInfoIsRead = requestInfo.readInPlace(cursor.bytes, at: &offset)
        fields.requestInfo = requestInfo.fields
        guard requestInfoIsRead else {
            return false
        }
        while UInt64(offset &- start) < size {
            guard let child = ISOBoxHeader.peek(cursor.bytes, at: offset) else {
                return false
            }
            switch child.type {
            case FairPlayStreamingKeyDataBox.assetIDType:
                guard !fields.hasAssetID, let assetID = FairPlayStreamingKeyDataBox.read(cursor.bytes, at: &offset) else {
                    return false
                }
                fields.hasAssetID = true
                fields.assetID = assetID.fields
            case FairPlayStreamingKeyDataBox.contextType:
                guard !fields.hasContext, let context = FairPlayStreamingKeyDataBox.read(cursor.bytes, at: &offset) else {
                    return false
                }
                fields.hasContext = true
                fields.context = context.fields
            case FairPlayStreamingKeyVersionListBox.boxType:
                guard !fields.hasVersionList, let versionList = FairPlayStreamingKeyVersionListBox.read(cursor.bytes, at: &offset) else {
                    return false
                }
                fields.hasVersionList = true
                fields.versionList = versionList.fields
            default:
                return false
            }
        }
        cursor.offset = offset
        return true
    }
}

extension FairPlayStreamingKeyRequestBox {
    init() {
        var fields = WebCore.ISOFairPlayStreamingKeyRequestBoxFields()
        fields.box = WebCore.ISOBoxFields(type: Self.boxType)
        fields.requestInfo = FairPlayStreamingKeyRequestInfoBox().fields
        self.init(fields: fields)
    }
}

// ISOFairPlayStreamingInitDataBox ('fpsd'): an fpsi, then fpsk boxes until the box's size is reached. Neither child's
// type is checked. The cursor only moves on success.
struct FairPlayStreamingInitDataBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x6670_7364 // 'fpsd'

    var fields: WebCore.ISOFairPlayStreamingInitDataBoxFields
    // The requests this parse appended, which stay appended if it then fails.
    var requests: [FairPlayStreamingKeyRequestBox] = []

    init(fields: WebCore.ISOFairPlayStreamingInitDataBoxFields) {
        self.fields = fields
    }

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    var info: FairPlayStreamingInfoBox {
        get {
            FairPlayStreamingInfoBox(fields: fields.info)
        }
        set {
            fields.info = newValue.fields
        }
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var boxCursor = cursor
        guard fields.box.parseInPlace(&boxCursor) else {
            return false
        }
        let size = fields.box.size
        var offset = boxCursor.offset
        guard info.readInPlace(cursor.bytes, at: &offset) else {
            return false
        }
        while UInt64(offset &- start) < size {
            guard let request = FairPlayStreamingKeyRequestBox.read(cursor.bytes, at: &offset) else {
                return false
            }
            // One allocation for the usual handful of requests, rather than growing from one.
            if requests.isEmpty {
                requests.reserveCapacity(4)
            }
            requests.append(request)
        }
        cursor.offset = offset
        return true
    }

    func appendRequests(to vector: inout WebCore.ISOFairPlayStreamingKeyRequestBoxFieldsVector) {
        for request in requests {
            vector.append(consuming: request.fields)
        }
    }
}

extension FairPlayStreamingInitDataBox {
    init() {
        self.init(
            fields: WebCore.ISOFairPlayStreamingInitDataBoxFields(
                box: WebCore.ISOBoxFields(type: Self.boxType),
                info: FairPlayStreamingInfoBox().fields
            )
        )
    }
}

// ISOFairPlayStreamingPsshBox: a 'pssh' whose Data is an fpsd.
struct FairPlayStreamingPsshBox: ISOBoxInPlaceParsing {
    static let fairPlaySystemID = WebCore.InlineBytes16(high: 0x94CE_86FB_07FF_4F43, low: 0xADB8_93D2_FA96_8CA2)

    // The generic pssh fields up to DataSize; its data is never read. The parse doesn't check that the system ID is
    // fairPlaySystemID.
    var pssh: PsshBox
    var initData: FairPlayStreamingInitDataBox

    init(fields: WebCore.ISOFairPlayStreamingPsshBoxFields) {
        pssh = PsshBox(fields: fields.pssh)
        initData = FairPlayStreamingInitDataBox(fields: fields.initData)
    }

    var fields: WebCore.ISOFairPlayStreamingPsshBoxFields {
        WebCore.ISOFairPlayStreamingPsshBoxFields(pssh: pssh.fields, initData: initData.fields)
    }

    var header: ISOBoxHeader {
        pssh.header
    }

    // The generic pssh fields up to DataSize, then the fpsd read from the first byte of Data (parseData). The fpsd's
    // size, not DataSize, says where the parse ends; the two may differ.
    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        guard pssh.parseThroughDataSize(&cursor) != nil else {
            return false
        }
        var offset = cursor.offset
        guard initData.readInPlace(cursor.bytes, at: &offset) else {
            return false
        }
        cursor.offset = offset
        return true
    }
}

extension FairPlayStreamingPsshBox {
    init() {
        pssh = PsshBox(systemID: Self.fairPlaySystemID)
        initData = FairPlayStreamingInitDataBox()
    }
}

// The C++ shells' parse(view, offset) and read(view), as in ISOBoxes.swift.

@_expose(Cxx)
func parseISOFairPlayStreamingInfoBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingInfoBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = FairPlayStreamingInfoBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.fullBox.box.size)
}

@_expose(Cxx)
func parseISOFairPlayStreamingKeyRequestInfoBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingKeyRequestInfoBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = FairPlayStreamingKeyRequestInfoBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.fullBox.box.size)
}

// fkai and fkcx.
@_expose(Cxx)
func parseISOFairPlayStreamingKeyDataBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingKeyDataBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = FairPlayStreamingKeyDataBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.box.size)
}

@_expose(Cxx)
func parseISOFairPlayStreamingKeyVersionListBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingKeyVersionListBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = FairPlayStreamingKeyVersionListBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.box.size)
}

@_expose(Cxx)
func parseISOFairPlayStreamingKeyRequestBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingKeyRequestBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = FairPlayStreamingKeyRequestBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.box.size)
}

// These two also hand back the requests the parse appended.

@_expose(Cxx)
func parseISOFairPlayStreamingInitDataBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingInitDataBoxFields,
    _ appendedRequests: inout WebCore.ISOFairPlayStreamingKeyRequestBoxFieldsVector
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var box = FairPlayStreamingInitDataBox(fields: fields)
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let result = shellResult(box.parseInPlace(&cursor), end: cursor.offset, offset: &offset, mode: mode, size: box.header.size)
    fields = box.fields
    box.appendRequests(to: &appendedRequests)
    return result
}

@_expose(Cxx)
func parseISOFairPlayStreamingPsshBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOFairPlayStreamingPsshBoxFields,
    _ appendedRequests: inout WebCore.ISOFairPlayStreamingKeyRequestBoxFieldsVector
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var box = FairPlayStreamingPsshBox(fields: fields)
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let result = shellResult(box.parseInPlace(&cursor), end: cursor.offset, offset: &offset, mode: mode, size: box.header.size)
    fields = box.fields
    box.initData.appendRequests(to: &appendedRequests)
    return result
}

#endif // ENABLE_WEBCORE_SWIFT
