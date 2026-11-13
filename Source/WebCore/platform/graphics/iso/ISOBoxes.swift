// Copyright (C) 2017 Apple Inc. All rights reserved.
// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
// Copyright (C) 2018 Metrological Group B.V.
// Copyright (C) 2018 Igalia S.L
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

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.ISOParseResults
import WebCore_Private.Core.MediaParsersCxxBridging

// ISO BMFF boxes (ISO/IEC 14496-12), for the C++ ISOBox shells. A box holds exactly the fields of its C++ shell
// (ISOBox.h, the iso/ISO*Box.h files; ISOParseResults.h) and parses in place, setting each field as it is read, so that
// a failed parse leaves what it read before failing, which is what the shells hand back. A parser never checks the type
// of the box it is given: callers peek the type first. Payloads are ranges of positions in the bytes that were parsed.

// The header ISOBox::parse reads.
struct ISOBoxHeader {
    static let uuidType: UInt32 = 0x7575_6964 // 'uuid'

    var fields: WebCore.ISOBoxFields

    var type: UInt32 {
        fields.type
    }

    // The size field, or the largesize when it is 1, clamped to the bytes left in the view; 0 also means all of them.
    // Sizes smaller than the header are kept.
    var size: UInt64 {
        fields.size
    }

    // The 16 bytes after the header of a 'uuid' box, in their order in the box.
    var extendedType: WebCore.InlineBytes16? {
        fields.hasExtendedType ? fields.extendedType : nil
    }

    // ISOBox::peekBox: the type and clamped size of the box at offset. Doesn't read the uuid.
    static func peek(_ bytes: Span<UInt8>, at offset: UInt32) -> (type: UInt32, size: UInt64)? {
        var cursor = ByteCursor(bytes, offset: offset)
        var fields = WebCore.ISOBoxFields()
        guard fields.parseTypeAndSize(&cursor) else {
            return nil
        }
        return (fields.type, fields.size)
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        fields.parseInPlace(&cursor)
    }
}

extension WebCore.ISOBoxFields {
    init(type: UInt32) {
        self.init()
        self.type = type
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        guard parseTypeAndSize(&cursor) else {
            return false
        }
        if type == ISOBoxHeader.uuidType {
            guard let extendedType = cursor.readInlineBytes16() else {
                return false
            }
            hasExtendedType = true
            self.extendedType = extendedType
        }
        return true
    }

    fileprivate mutating func parseTypeAndSize(_ cursor: inout ByteCursor) -> Bool {
        // An offset past the end fails here, before the first read.
        guard cursor.isWalkable, let remaining = cursor.remaining else {
            return false
        }
        let maximumPossibleSize = UInt64(remaining)
        guard let size = cursor.readUInt32() else {
            return false
        }
        self.size = UInt64(size)
        guard let type = cursor.readUInt32() else {
            return false
        }
        self.type = type
        if size == 1 {
            guard let largeSize = cursor.readUInt64() else {
                return false
            }
            self.size = largeSize
        }
        if self.size > maximumPossibleSize || self.size == 0 {
            self.size = maximumPossibleSize
        }
        return true
    }
}

// ISOFullBox::parse: the box header, then the version and the 24-bit flags.
extension WebCore.ISOFullBoxFields {
    init(type: UInt32) {
        self.init()
        box.type = type
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        guard box.parseInPlace(&cursor), let versionAndFlags = cursor.readUInt32() else {
            return false
        }
        version = UInt8(versionAndFlags >> 24)
        flags = versionAndFlags & 0xFF_FFFF
        return true
    }
}

// A box with the C++ ISOBox's parse and read.
protocol ISOBoxParsing {
    var header: ISOBoxHeader { get }

    // ISOBox::parse: the box at the cursor. On success the cursor is where parsing stopped, which needn't be the end of
    // the box; on failure it is wherever the box's parse stopped, which the shells hand back. Prefer read().
    static func parse(_ cursor: inout ByteCursor) -> Self?
}

extension ISOBoxParsing {
    // ISOBox::read(view, offset): the box at offset, if parsing it didn't go past its size. On success the offset
    // moves past the box's size, whatever parsing consumed; on failure it doesn't move.
    static func read(_ bytes: Span<UInt8>, at offset: inout UInt32) -> Self? {
        var cursor = ByteCursor(bytes, offset: offset)
        guard cursor.isWalkable, let box = parse(&cursor), box.finishesRead(at: cursor.offset, from: offset) else {
            return nil
        }
        offset &+= UInt32(truncatingIfNeeded: box.header.size)
        return box
    }

    // Whether a parse that started at offset and stopped at end stayed within the box's size.
    func finishesRead(at end: UInt32, from offset: UInt32) -> Bool {
        end >= offset && UInt64(end - offset) <= header.size
    }
}

// A box as its C++ shell holds it: the shell's fields (a stored `fields`), parsed in place, each as it is read, so that
// a failed parse keeps what it read before failing.
protocol ISOBoxInPlaceParsing: ISOBoxParsing {
    // The box as the C++ class's default constructor makes it.
    init()

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool
}

extension ISOBoxInPlaceParsing {
    static func parse(_ cursor: inout ByteCursor) -> Self? {
        var box = Self()
        return box.parseInPlace(&cursor) ? box : nil
    }

    static func read(_ bytes: Span<UInt8>, at offset: inout UInt32) -> Self? {
        var box = Self()
        return box.readInPlace(bytes, at: &offset) ? box : nil
    }

    // ISOBox::read(view, offset) on this box.
    mutating func readInPlace(_ bytes: Span<UInt8>, at offset: inout UInt32) -> Bool {
        var cursor = ByteCursor(bytes, offset: offset)
        guard cursor.isWalkable, parseInPlace(&cursor), finishesRead(at: cursor.offset, from: offset) else {
            return false
        }
        offset &+= UInt32(truncatingIfNeeded: header.size)
        return true
    }
}

// Where an ISOBox shell's parse(view, offset), or with ReadWhole read(view), starts.
@_lifetime(copy bytes)
func shellCursor(_ bytes: Span<UInt8>, at offset: UInt32, mode: WebCore.ISOBoxParseMode) -> ByteCursor {
    ByteCursor(bytes, offset: mode == .ReadWhole ? 0 : offset)
}

// What it returns once parsing stopped at end, for a box of this size; parse(view, offset) also moves the offset there.
func shellResult(_ parsed: Bool, end: UInt32, offset: inout UInt32, mode: WebCore.ISOBoxParseMode, size: UInt64) -> Bool {
    if mode == .ReadWhole {
        return parsed && UInt64(end) <= size
    }
    offset = end
    return parsed
}

// A box of any type, read as the C++ ISOBox base class reads it: just the header.
extension ISOBoxHeader: ISOBoxInPlaceParsing {
    init() {
        self.init(fields: WebCore.ISOBoxFields())
    }

    var header: ISOBoxHeader {
        self
    }
}

// ISOOriginalFormatBox ('frma').
struct OriginalFormatBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x6672_6D61 // 'frma'

    var fields: WebCore.ISOOriginalFormatBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOOriginalFormatBoxFields, _ cursor: inout ByteCursor) -> Bool {
        guard fields.box.parseInPlace(&cursor), let dataFormat = cursor.readUInt32() else {
            return false
        }
        fields.dataFormat = dataFormat
        return true
    }
}

extension OriginalFormatBox {
    init() {
        self.init(fields: WebCore.ISOOriginalFormatBoxFields(box: WebCore.ISOBoxFields(type: Self.boxType), dataFormat: 0))
    }
}

// ISOSchemeTypeBox ('schm'). The scheme URI that flags bit 0 announces isn't read.
struct SchemeTypeBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x7363_686D // 'schm'

    var fields: WebCore.ISOSchemeTypeBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.fullBox.box)
    }

    var schemeType: UInt32 {
        fields.schemeType
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOSchemeTypeBoxFields, _ cursor: inout ByteCursor) -> Bool {
        guard fields.fullBox.parseInPlace(&cursor), let schemeType = cursor.readUInt32() else {
            return false
        }
        fields.schemeType = schemeType
        guard let schemeVersion = cursor.readUInt32() else {
            return false
        }
        fields.schemeVersion = schemeVersion
        return true
    }
}

extension SchemeTypeBox {
    init() {
        self.init(
            fields: WebCore.ISOSchemeTypeBoxFields(fullBox: WebCore.ISOFullBoxFields(type: Self.boxType), schemeType: 0, schemeVersion: 0)
        )
    }
}

// ISOTrackEncryptionBox ('tenc', ISO/IEC 23001-7 8.2.2).
struct TrackEncryptionBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x7465_6E63 // 'tenc'

    var fields: WebCore.ISOTrackEncryptionBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.fullBox.box)
    }

    var defaultKID: WebCore.InlineBytes16? {
        fields.hasDefaultKID ? fields.defaultKID : nil
    }

    // ISOTrackEncryptionBox::parse and parsePayload.
    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOTrackEncryptionBoxFields, _ cursor: inout ByteCursor) -> Bool {
        guard fields.fullBox.parseInPlace(&cursor) else {
            return false
        }
        // Steps over the reserved bytes without a bounds check; the next read catches it.
        cursor.advance(by: 1)
        if fields.fullBox.version == 0 {
            cursor.advance(by: 1)
        } else {
            guard let cryptAndSkip = cursor.readInt8() else {
                return false
            }
            fields.setDefaultCryptAndSkipByteBlocks(cryptAndSkip)
        }
        guard let defaultIsProtected = cursor.readInt8() else {
            return false
        }
        fields.defaultIsProtected = defaultIsProtected
        guard let defaultPerSampleIVSize = cursor.readInt8() else {
            return false
        }
        fields.defaultPerSampleIVSize = defaultPerSampleIVSize
        guard let remaining = cursor.remaining, remaining >= 16, let defaultKID = cursor.readInlineBytes16() else {
            return false
        }
        fields.hasDefaultKID = true
        fields.defaultKID = defaultKID
        if defaultIsProtected == 1 && defaultPerSampleIVSize == 0 {
            guard let size = cursor.readInt8(), size >= 0 else {
                return false
            }
            let start = Int(cursor.offset)
            guard cursor.canRead(Int(size)) else {
                // A short IV leaves the offset at the end of the view, as reading it a byte at a time would.
                cursor.advance(by: UInt64(cursor.bytes.count - start))
                return false
            }
            cursor.advance(by: UInt64(size))
            fields.defaultConstantIVWasRead = true
            fields.defaultConstantIV = WebCore.ISOByteRange(offset: start, size: Int(size))
        }
        return true
    }

    // ISOTrackEncryptionBox::parseWithoutTypeAndSize: a tenc from its version byte on, as AVStreamDataParser attaches
    // it to samples. Unlike parse(), the constant IV size byte is unsigned and the data may be larger than 4 GB. The
    // header isn't touched.
    static func parseWithoutTypeAndSize(_ data: Span<UInt8>) -> TrackEncryptionBox? {
        var reader = SpanBitReader(data)
        guard let version = reader.read(UInt8.self), let flags = reader.read(24), reader.skipBytes(1) else {
            return nil
        }
        var cryptAndSkip: Int8?
        if version == 0 {
            guard reader.skipBytes(1) else {
                return nil
            }
        } else {
            guard let byte = reader.read(UInt8.self).map({ Int8(bitPattern: $0) }) else {
                return nil
            }
            cryptAndSkip = byte
        }
        guard let defaultIsProtected = reader.read(UInt8.self).map({ Int8(bitPattern: $0) }),
            let defaultPerSampleIVSize = reader.read(UInt8.self).map({ Int8(bitPattern: $0) })
        else {
            return nil
        }
        let keyIDOffset = reader.byteOffset
        guard data.count - keyIDOffset >= 16, reader.skipBytes(16) else {
            return nil
        }
        var defaultConstantIV: WebCore.ISOByteRange?
        if defaultIsProtected == 1 && defaultPerSampleIVSize == 0 {
            guard let size = reader.read(UInt8.self) else {
                return nil
            }
            let start = reader.byteOffset
            guard data.count - start >= Int(size) else {
                return nil
            }
            defaultConstantIV = WebCore.ISOByteRange(offset: start, size: Int(size))
        }
        var box = TrackEncryptionBox()
        box.fields.fullBox.version = version
        box.fields.fullBox.flags = UInt32(truncatingIfNeeded: flags)
        if let cryptAndSkip {
            box.fields.setDefaultCryptAndSkipByteBlocks(cryptAndSkip)
        }
        box.fields.defaultIsProtected = defaultIsProtected
        box.fields.defaultPerSampleIVSize = defaultPerSampleIVSize
        box.fields.hasDefaultKID = true
        box.fields.defaultKID = inlineBytes16(data, at: keyIDOffset)
        if let defaultConstantIV {
            box.fields.defaultConstantIVWasRead = true
            box.fields.defaultConstantIV = defaultConstantIV
        }
        return box
    }
}

extension WebCore.ISOTrackEncryptionBoxFields {
    // The byte is split as a signed one: crypt is -8...7, skip 0...15.
    fileprivate mutating func setDefaultCryptAndSkipByteBlocks(_ cryptAndSkip: Int8) {
        hasDefaultCryptAndSkipByteBlocks = true
        defaultCryptByteBlock = cryptAndSkip >> 4
        defaultSkipByteBlock = cryptAndSkip & 0xF
    }
}

extension TrackEncryptionBox {
    init() {
        var fields = WebCore.ISOTrackEncryptionBoxFields()
        fields.fullBox = WebCore.ISOFullBoxFields(type: Self.boxType)
        self.init(fields: fields)
    }
}

// ISOSchemeInformationBox ('schi').
struct SchemeInformationBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x7363_6869 // 'schi'

    var fields: WebCore.ISOSchemeInformationBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    // The child box when it is a 'tenc' that reads; other children are skipped.
    var trackEncryption: TrackEncryptionBox? {
        fields.trackEncryptionWasRead ? TrackEncryptionBox(fields: fields.trackEncryption) : nil
    }

    // A schi needs a child header, even when it is empty. The child may run past the schi's own bytes as long as the
    // clamped size of the tenc doesn't. The cursor doesn't move, and read() accepts any successful parse.
    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    @inline(never)
    static func parseFields(_ fields: inout WebCore.ISOSchemeInformationBoxFields, _ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var headerCursor = cursor
        guard fields.box.parseInPlace(&headerCursor), let child = ISOBoxHeader.peek(cursor.bytes, at: headerCursor.offset) else {
            return false
        }
        if child.type == TrackEncryptionBox.boxType {
            guard UInt64(headerCursor.offset) + child.size <= UInt64(start) + fields.box.size else {
                return false
            }
            var childOffset = headerCursor.offset
            guard let trackEncryption = TrackEncryptionBox.read(cursor.bytes, at: &childOffset) else {
                return false
            }
            fields.trackEncryptionWasRead = true
            fields.trackEncryption = trackEncryption.fields
        }
        return true
    }
}

extension SchemeInformationBox {
    init() {
        var fields = WebCore.ISOSchemeInformationBoxFields()
        fields.box = WebCore.ISOBoxFields(type: Self.boxType)
        self.init(fields: fields)
    }
}

// ISOProtectionSchemeInfoBox ('sinf').
struct ProtectionSchemeInfoBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x7369_6E66 // 'sinf'

    var fields: WebCore.ISOProtectionSchemeInfoBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.box)
    }

    // The children are frma (the first child, whatever its type), then optionally schm, then optionally schi; a schm or
    // schi is a new box as soon as it is found, then read in place, so it may be only partly read. Parsing stops
    // successfully at the end of the sinf or at any other box, and fails if a schi doesn't end exactly at the end of
    // the sinf. Children aren't bounded by the sinf. The cursor only moves on success.
    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    static func parseFields(_ fields: inout WebCore.ISOProtectionSchemeInfoBoxFields, _ cursor: inout ByteCursor) -> Bool {
        let start = cursor.offset
        var headerCursor = cursor
        guard fields.box.parseInPlace(&headerCursor) else {
            return false
        }
        let size = fields.box.size
        var offset = headerCursor.offset
        var originalFormat = OriginalFormatBox(fields: fields.originalFormat)
        let originalFormatIsRead = originalFormat.readInPlace(cursor.bytes, at: &offset)
        fields.originalFormat = originalFormat.fields
        guard originalFormatIsRead else {
            return false
        }
        // `localOffset - offset == m_size`, in unsigned arithmetic.
        func consumedWholeBox() -> Bool {
            UInt64(offset &- start) == size
        }
        if consumedWholeBox() {
            cursor.offset = offset
            return true
        }
        guard var next = ISOBoxHeader.peek(cursor.bytes, at: offset) else {
            return false
        }
        if next.type == SchemeTypeBox.boxType {
            var schemeType = SchemeTypeBox()
            let schemeTypeIsRead = schemeType.readInPlace(cursor.bytes, at: &offset)
            fields.schemeTypeWasRead = true
            fields.schemeType = schemeType.fields
            guard schemeTypeIsRead else {
                return false
            }
            if consumedWholeBox() {
                cursor.offset = offset
                return true
            }
            guard let peeked = ISOBoxHeader.peek(cursor.bytes, at: offset) else {
                return false
            }
            next = peeked
        }
        if next.type == SchemeInformationBox.boxType {
            var schemeInformation = SchemeInformationBox()
            let schemeInformationIsRead = schemeInformation.readInPlace(cursor.bytes, at: &offset)
            fields.schemeInformationWasRead = true
            fields.schemeInformation = schemeInformation.fields
            guard schemeInformationIsRead, consumedWholeBox() else {
                return false
            }
        }
        cursor.offset = offset
        return true
    }
}

extension ProtectionSchemeInfoBox {
    init() {
        var fields = WebCore.ISOProtectionSchemeInfoBoxFields()
        fields.box = WebCore.ISOBoxFields(type: Self.boxType)
        fields.originalFormat = OriginalFormatBox().fields
        self.init(fields: fields)
    }
}

// ISOProtectionSystemSpecificHeaderBox ('pssh', ISO/IEC 23001-7 8.1.1).
struct PsshBox: ISOBoxInPlaceParsing {
    static let boxType: UInt32 = 0x7073_7368 // 'pssh'
    static let commonSystemID = WebCore.InlineBytes16(high: 0x1077_EFEC_C0B2_4D02, low: 0xACE3_3C1E_52E2_FB4B)

    var fields: WebCore.ISOProtectionSystemSpecificHeaderBoxFields

    var header: ISOBoxHeader {
        ISOBoxHeader(fields: fields.fullBox.box)
    }

    var systemID: WebCore.InlineBytes16 {
        fields.systemID
    }

    // The key IDs (version 1 and above), 16 bytes each, as positions in the parsed bytes; empty if none were read.
    var keyIDPositions: Range<Int> {
        fields.keyIDsWereRead ? fields.keyIDs.range : 0..<0
    }

    mutating func parseInPlace(_ cursor: inout ByteCursor) -> Bool {
        Self.parseFields(&fields, &cursor)
    }

    mutating func parseThroughDataSize(_ cursor: inout ByteCursor) -> UInt32? {
        Self.parseThroughDataSize(&fields, &cursor)
    }

    static func parseFields(_ fields: inout WebCore.ISOProtectionSystemSpecificHeaderBoxFields, _ cursor: inout ByteCursor) -> Bool {
        guard let dataSize = parseThroughDataSize(&fields, &cursor), let remainingInView = cursor.remaining,
            UInt64(remainingInView) >= UInt64(dataSize)
        else {
            return false
        }
        let start = Int(cursor.offset)
        cursor.advance(by: UInt64(dataSize))
        fields.dataWasRead = true
        fields.data = WebCore.ISOByteRange(offset: start, size: Int(dataSize))
        return true
    }

    // Everything up to and including DataSize, checked against the end of the box; the cursor is left at the first
    // byte of Data, which isn't read. ISOFairPlayStreamingPsshBox parses Data differently from there.
    @inline(never)
    static func parseThroughDataSize(
        _ fields: inout WebCore.ISOProtectionSystemSpecificHeaderBoxFields,
        _ cursor: inout ByteCursor
    ) -> UInt32? {
        let start = cursor.offset
        guard fields.fullBox.parseInPlace(&cursor) else {
            return nil
        }
        let end = UInt64(start) + fields.fullBox.box.size
        func remainingInBox(_ offset: UInt32) -> UInt64? {
            UInt64(offset) <= end ? end - UInt64(offset) : nil
        }
        guard remainingInBox(cursor.offset) != nil, cursor.readInlineBytes16(into: &fields.systemID) else {
            return nil
        }
        if fields.fullBox.version != 0 {
            guard let keyIDCount = cursor.readUInt32(), let remaining = remainingInBox(cursor.offset), UInt64(keyIDCount) <= remaining / 16
            else {
                return nil
            }
            // Each key ID is a checkedRead of 16 bytes: they all have to be in the view.
            let keyIDBytes = 16 * UInt64(keyIDCount)
            guard let remainingInView = cursor.remaining, UInt64(remainingInView) >= keyIDBytes else {
                return nil
            }
            fields.keyIDsWereRead = true
            fields.keyIDs = WebCore.ISOByteRange(offset: Int(cursor.offset), size: Int(keyIDBytes))
            cursor.advance(by: keyIDBytes)
        }
        guard let dataSize = cursor.readUInt32(), let remaining = remainingInBox(cursor.offset), remaining >= UInt64(dataSize) else {
            return nil
        }
        return dataSize
    }

    // ISOProtectionSystemSpecificHeaderBox::peekSystemID: the system ID of the pssh at offset, if a generic parse of
    // it succeeds.
    static func peekSystemID(_ bytes: Span<UInt8>, at offset: UInt32) -> WebCore.InlineBytes16? {
        guard let peeked = ISOBoxHeader.peek(bytes, at: offset), peeked.type == boxType else {
            return nil
        }
        var cursor = ByteCursor(bytes, offset: offset)
        return parse(&cursor)?.systemID
    }
}

extension PsshBox {
    init() {
        self.init(systemID: WebCore.InlineBytes16())
    }

    init(systemID: WebCore.InlineBytes16) {
        var fields = WebCore.ISOProtectionSystemSpecificHeaderBoxFields()
        fields.fullBox = WebCore.ISOFullBoxFields(type: Self.boxType)
        fields.systemID = systemID
        self.init(fields: fields)
    }
}

extension ByteCursor {
    // checkedReadSequence<uint8_t> of 16 bytes: all or nothing.
    mutating func readInlineBytes16() -> WebCore.InlineBytes16? {
        guard canRead(16), let high = readUInt64(), let low = readUInt64() else {
            return nil
        }
        return WebCore.InlineBytes16(high: high, low: low)
    }

    // checkedReadSequence<uint8_t> of 16 bytes into value, which also stores the bytes it reads before failing. The
    // offset only moves on success.
    mutating func readInlineBytes16(into value: inout WebCore.InlineBytes16) -> Bool {
        if let bytes16 = readInlineBytes16() {
            value = bytes16
            return true
        }
        guard let remaining else {
            return false
        }
        let start = Int(offset)
        for index in 0..<min(remaining, 16) {
            value.setByte(bytes[start + index], at: index)
        }
        return false
    }
}

extension WebCore.InlineBytes16 {
    // Appends the 16 bytes, in order.
    func append(to vector: inout WebCore.MediaParserByteVector) {
        for index in 0..<16 {
            let word = index < 8 ? high : low
            vector.append(consuming: UInt8(truncatingIfNeeded: word >> UInt64(56 - 8 * (index % 8))))
        }
    }

    mutating func setByte(_ byte: UInt8, at index: Int) {
        let shift = UInt64(56 - 8 * (index % 8))
        let mask = ~(UInt64(0xFF) << shift)
        if index < 8 {
            high = high & mask | UInt64(byte) << shift
        } else {
            low = low & mask | UInt64(byte) << shift
        }
    }
}

extension WebCore.ISOByteRange {
    var range: Range<Int> {
        offset..<(offset + size)
    }
}

// The 16 bytes at offset, which the caller has checked are there.
private func inlineBytes16(_ bytes: Span<UInt8>, at offset: Int) -> WebCore.InlineBytes16 {
    var high: UInt64 = 0
    var low: UInt64 = 0
    for index in 0..<8 {
        high = high << 8 | UInt64(bytes[offset + index])
        low = low << 8 | UInt64(bytes[offset + 8 + index])
    }
    return WebCore.InlineBytes16(high: high, low: low)
}

// For getKeyIDs (CMUtilities.mm), which reads the tenc that AVStreamDataParser attaches to each sample.
@_expose(Cxx)
func parseTrackEncryptionBoxWithoutTypeAndSizeImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ fields: inout WebCore.ISOTrackEncryptionFields
) -> Bool {
    let span: Span<UInt8> = data.span()
    guard let box = TrackEncryptionBox.parseWithoutTypeAndSize(span) else {
        return false
    }
    let tenc = box.fields
    fields.version = tenc.fullBox.version
    fields.flags = tenc.fullBox.flags
    fields.hasDefaultCryptAndSkipByteBlocks = tenc.hasDefaultCryptAndSkipByteBlocks
    fields.defaultCryptByteBlock = tenc.defaultCryptByteBlock
    fields.defaultSkipByteBlock = tenc.defaultSkipByteBlock
    fields.defaultIsProtected = tenc.defaultIsProtected
    fields.defaultPerSampleIVSize = tenc.defaultPerSampleIVSize
    fields.defaultKID = tenc.defaultKID
    fields.defaultConstantIV = tenc.defaultConstantIVWasRead ? tenc.defaultConstantIV : WebCore.ISOByteRange()
    return true
}

// The C++ shells' parse(view, offset) and read(view) (ISOBox.h): the box starts out as the shell's fields are, and they
// go back to the shell as the parse left them.

@_expose(Cxx)
func parseISOBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = fields.parseInPlace(&cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.size)
}

@_expose(Cxx)
func parseISOOriginalFormatBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOOriginalFormatBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = OriginalFormatBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.box.size)
}

@_expose(Cxx)
func parseISOSchemeTypeBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOSchemeTypeBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = SchemeTypeBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.fullBox.box.size)
}

@_expose(Cxx)
func parseISOTrackEncryptionBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOTrackEncryptionBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = TrackEncryptionBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.fullBox.box.size)
}

@_expose(Cxx)
func parseISOSchemeInformationBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOSchemeInformationBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = SchemeInformationBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.box.size)
}

@_expose(Cxx)
func parseISOProtectionSchemeInfoBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOProtectionSchemeInfoBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = ProtectionSchemeInfoBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.box.size)
}

@_expose(Cxx)
func parseISOProtectionSystemSpecificHeaderBoxImpl(
    _ view: borrowing WebCore.MediaParserBytes,
    _ offset: inout UInt32,
    _ mode: WebCore.ISOBoxParseMode,
    _ fields: inout WebCore.ISOProtectionSystemSpecificHeaderBoxFields
) -> Bool {
    let bytes: Span<UInt8> = view.span()
    var cursor = shellCursor(bytes, at: offset, mode: mode)
    let parsed = PsshBox.parseFields(&fields, &cursor)
    return shellResult(parsed, end: cursor.offset, offset: &offset, mode: mode, size: fields.fullBox.box.size)
}

#endif // ENABLE_WEBCORE_SWIFT
