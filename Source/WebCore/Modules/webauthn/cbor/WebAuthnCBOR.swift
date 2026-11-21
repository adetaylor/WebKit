// Copyright (C) 2026 Apple Inc. All rights reserved.
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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf
internal import WebCore_Private.Core.WebAuthnSwiftTypes

// The CBOR reader and writer (RFC 7049) for the CTAP2 messages.

// The CBOR encoding's numbers (RFC 7049 3).
let cborMajorTypeBitShift: UInt8 = 5
let cborAdditionalInformationMask: UInt8 = 0x1F
let cborAdditionalInformation1Byte: UInt8 = 24
let cborAdditionalInformation2Bytes: UInt8 = 25
let cborAdditionalInformation4Bytes: UInt8 = 26
let cborAdditionalInformation8Bytes: UInt8 = 27

// Major types (RFC 7049 2.1).
let cborMajorUnsigned: UInt8 = 0
let cborMajorNegative: UInt8 = 1
let cborMajorByteString: UInt8 = 2
let cborMajorString: UInt8 = 3
let cborMajorArray: UInt8 = 4
let cborMajorMap: UInt8 = 5
let cborMajorSimpleValue: UInt8 = 7

/// The simple values the encoding has (RFC 7049 2.3), by their additional information.
enum CBORSimpleValue: UInt8 {
    case falseValue = 20
    case trueValue = 21
    case nullValue = 22
    case undefined = 23
}

// MARK: - Reader

/// A data item's head: its major type, additional information and argument, where the item starts and where its payload
/// starts.
///
/// A text string also carries what `ctapLess` compares map keys by.
struct CBORItemHead {
    var majorType: UInt8
    var additionalInfo: UInt8
    var argument: UInt64
    var start: Int
    var payloadStart: Int
    /// Whether the argument is in the fewest bytes (always, in an item the reader accepted).
    var hasShortestArgument = true
    /// Whether a text string is UTF-8.
    ///
    /// Bytes that are not give the null string, which writes and sorts as the empty one (`String::fromUTF8`).
    var isValidUTF8 = true
    var isASCII = true
    /// A text string's `String::length()`: its UTF-16 code units (0 when not UTF-8).
    var utf16Length = 0

    var isMapKey: Bool {
        majorType == cborMajorUnsigned || majorType == cborMajorNegative || majorType == cborMajorString
    }

    /// The offset just past a scalar or a string.
    var scalarEnd: Int {
        // The payload lies within bytes in memory: the sum cannot overflow.
        majorType == cborMajorByteString || majorType == cborMajorString ? payloadStart &+ Int(argument) : payloadStart
    }

    /// Whether `ctapLess` orders this key as its encoded bytes: an integer, or ASCII text, in the shortest head.
    ///
    /// The head byte carries the major type and the length class, so for two such keys the order of their encodings is
    /// exactly `ctapLess` (unsigned ascending, negative descending, text by length, then by code unit).
    var comparesAsEncodedBytes: Bool {
        hasShortestArgument && (majorType != cborMajorString || (isValidUTF8 && isASCII))
    }

    /// Sets what `ctapLess` needs of a text string from its bytes.
    mutating func describeText(_ utf8: Span<UInt8>) {
        var combined: UInt8 = 0
        for index in utf8.indices {
            combined |= utf8[index]
        }
        if combined < 0x80 {
            utf16Length = utf8.count
            return
        }
        isASCII = false
        // String::fromUTF8 gives a null String for bytes that are not UTF-8, which hasValidUTF8Format rejects.
        guard (try? UTF8Span(validating: utf8)) != nil else {
            isValidUTF8 = false
            return
        }
        var length = 0
        for index in utf8.indices {
            let byte = utf8[index]
            // A character starts at each byte that is not a continuation byte; one of four bytes is a surrogate pair.
            // At most two per byte in memory: the sum cannot overflow.
            length &+= (byte & 0xC0 != 0x80 ? 1 : 0) &+ (byte >= 0xF0 ? 1 : 0)
        }
        utf16Length = length
    }
}

/// The head of the map key encoded as all of `encoded`, with what `ctapKeyOrder` needs of a text key.
private func describedKeyHead(_ encoded: Span<UInt8>) -> CBORItemHead {
    var head = cborHead(encoded, at: 0)
    if head.majorType == cborMajorString {
        head.describeText(encoded.extracting(head.payloadStart..<head.scalarEnd))
    }
    return head
}

/// The head of the item at `offset` in `data`, which the reader has checked.
private func cborHead(_ data: Span<UInt8>, at offset: Int) -> CBORItemHead {
    let initialByte = data[offset]
    let additionalInfo = initialByte & cborAdditionalInformationMask
    var head = CBORItemHead(
        majorType: initialByte >> cborMajorTypeBitShift,
        additionalInfo: additionalInfo,
        argument: UInt64(additionalInfo),
        start: offset,
        payloadStart: offset + 1
    )
    if additionalInfo >= cborAdditionalInformation1Byte {
        let byteCount = 1 << Int(additionalInfo - cborAdditionalInformation1Byte)
        var argument: UInt64 = 0
        for index in head.payloadStart..<(head.payloadStart + byteCount) {
            argument = argument << 8 | UInt64(data[index])
        }
        head.argument = argument
        head.payloadStart += byteCount
    }
    return head
}

/// The offset just past the item at `offset` in `data`, which the reader has checked.
private func cborItemEnd(_ data: Span<UInt8>, from offset: Int) -> Int {
    let head = cborHead(data, at: offset)
    switch head.majorType {
    case cborMajorArray, cborMajorMap:
        var end = head.payloadStart
        let itemCount = head.majorType == cborMajorMap ? 2 * head.argument : head.argument
        for _ in 0..<itemCount {
            end = cborItemEnd(data, from: end)
        }
        return end
    default:
        return head.scalarEnd
    }
}

/// -1, 0 or 1 as `x` sorts before, the same as, or after `y`, byte by byte (a prefix first).
private func compareBytes(_ x: Span<UInt8>, _ y: Span<UInt8>) -> Int {
    for index in 0..<min(x.count, y.count) where x[index] != y[index] {
        return x[index] < y[index] ? -1 : 1
    }
    return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
}

/// The UTF-16 code units of UTF-8 bytes, one at a time.
private struct UTF16CodeUnits: ~Escapable {
    private let utf8: Span<UInt8>
    private var offset = 0
    private var trailingSurrogate: UInt16 = 0

    @_lifetime(copy utf8)
    init(_ utf8: Span<UInt8>) {
        self.utf8 = utf8
    }

    mutating func next() -> UInt16? {
        if trailingSurrogate != 0 {
            defer { trailingSurrogate = 0 }
            return trailingSurrogate
        }
        guard offset < utf8.count else {
            return nil
        }
        let lead = UInt32(utf8[offset])
        let length = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
        var scalar = length == 1 ? lead : lead & (0x7F >> UInt32(length))
        for index in (offset + 1)..<(offset + length) {
            scalar = scalar << 6 | UInt32(utf8[index] & 0x3F)
        }
        offset += length
        if scalar < 0x10000 {
            return UInt16(scalar)
        }
        trailingSurrogate = UInt16(0xDC00 | scalar & 0x3FF)
        return UInt16(0xD800 | (scalar - 0x10000) >> 10)
    }
}

/// The CTAP2 canonical order of two map keys.
///
/// Compares `a`, in `aData`, with `b`, in `bData`: -1 if `a` sorts first, 0 if they are equivalent, 1 if `b` sorts
/// first. Major type first (unsigned, negative, then text), unsigned ascending, negative descending, and text by UTF-16
/// length, then by UTF-16 code unit (`codePointCompareLessThan` compares code units).
func ctapKeyOrder(_ a: CBORItemHead, in aData: Span<UInt8>, _ b: CBORItemHead, in bData: Span<UInt8>) -> Int {
    if a.comparesAsEncodedBytes && b.comparesAsEncodedBytes {
        return compareBytes(aData.extracting(a.start..<a.scalarEnd), bData.extracting(b.start..<b.scalarEnd))
    }
    if a.majorType != b.majorType {
        return a.majorType < b.majorType ? -1 : 1
    }
    if a.majorType != cborMajorString {
        // The argument orders unsigned integers ascending and negative ones (-1 - argument) descending.
        return a.argument == b.argument ? 0 : (a.argument < b.argument ? -1 : 1)
    }
    if a.utf16Length != b.utf16Length {
        return a.utf16Length < b.utf16Length ? -1 : 1
    }
    var aUnits = UTF16CodeUnits(a.isValidUTF8 ? aData.extracting(a.payloadStart..<a.scalarEnd) : aData.extracting(0..<0))
    var bUnits = UTF16CodeUnits(b.isValidUTF8 ? bData.extracting(b.payloadStart..<b.scalarEnd) : bData.extracting(0..<0))
    while let aUnit = aUnits.next(), let bUnit = bUnits.next() {
        if aUnit != bUnit {
            return aUnit < bUnit ? -1 : 1
        }
    }
    return 0
}

/// The reader's state: the position and the last error set.
///
/// When a check fails the position stays where it was: a map still reads the value after a failed key, from wherever
/// the key's reading stopped, and that value's error, if any, replaces the key's.
struct CBORDecoder {
    var position = 0
    var error = cbor.DecoderError.CBORNoError

    /// The error, and the length of the item at the start of `data` (0 on an error); trailing bytes are an error
    /// unless `allowTrailingData`.
    static func read(_ data: Span<UInt8>, maxNestingLevel: Int32, allowTrailingData: Bool) -> (error: cbor.DecoderError, bytesConsumed: Int)
    {
        var decoder = CBORDecoder()
        if decoder.decode(data, maxNestingLevel) != nil && !allowTrailingData && decoder.position != data.count {
            decoder.error = .ExtraneousData
        }
        return (decoder.error, decoder.error == .CBORNoError ? decoder.position : 0)
    }

    mutating func canConsume(_ data: Span<UInt8>, _ count: UInt64) -> Bool {
        if UInt64(data.count - position) >= count {
            return true
        }
        error = .IncompleteCBORData
        return false
    }

    mutating func decode(_ data: Span<UInt8>, _ maxNestingLevel: Int32) -> CBORItemHead? {
        if maxNestingLevel < 0 || maxNestingLevel > cbor.kCBORMaxDepth {
            error = .TooMuchNesting
            return nil
        }
        guard canConsume(data, 1) else {
            return nil
        }
        let start = position
        let initialByte = data[position]
        position += 1
        let additionalInfo = initialByte & cborAdditionalInformationMask
        guard let argument = readVariadicLengthInteger(data, additionalInfo) else {
            return nil
        }
        var head = CBORItemHead(
            majorType: initialByte >> cborMajorTypeBitShift,
            additionalInfo: additionalInfo,
            argument: argument,
            start: start,
            payloadStart: position
        )
        switch head.majorType {
        case cborMajorUnsigned, cborMajorNegative:
            if argument > UInt64(Int64.max) {
                error = .OutOfRangeIntegerValue
                return nil
            }
        case cborMajorByteString:
            guard canConsume(data, argument) else {
                return nil
            }
            // canConsume checked that the payload lies within the input: the sum cannot overflow.
            position &+= Int(argument)
        case cborMajorString:
            guard canConsume(data, argument) else {
                return nil
            }
            // canConsume checked that the payload lies within the input: the sum cannot overflow.
            position &+= Int(argument)
            head.describeText(data.extracting(head.payloadStart..<position))
            guard head.isValidUTF8 else {
                error = .InvalidUTF8
                return nil
            }
        case cborMajorArray:
            var remaining = argument
            while remaining > 0 {
                remaining -= 1
                guard decode(data, maxNestingLevel - 1) != nil else {
                    return nil
                }
            }
        case cborMajorMap:
            guard readMap(data, argument, maxNestingLevel) else {
                return nil
            }
        case cborMajorSimpleValue:
            guard readSimpleValue(additionalInfo, argument) else {
                return nil
            }
        default:
            error = .UnsupportedMajorType
            return nil
        }
        return head
    }

    mutating func readVariadicLengthInteger(_ data: Span<UInt8>, _ additionalInfo: UInt8) -> UInt64? {
        if additionalInfo < cborAdditionalInformation1Byte {
            return UInt64(additionalInfo)
        }
        let additionalBytes: Int
        switch additionalInfo {
        case cborAdditionalInformation1Byte: additionalBytes = 1
        case cborAdditionalInformation2Bytes: additionalBytes = 2
        case cborAdditionalInformation4Bytes: additionalBytes = 4
        case cborAdditionalInformation8Bytes: additionalBytes = 8
        default:
            error = .UnknownAdditionalInfo
            return nil
        }
        guard canConsume(data, UInt64(additionalBytes)) else {
            return nil
        }
        var intData: UInt64 = 0
        for _ in 0..<additionalBytes {
            intData = intData << 8 | UInt64(data[position])
            position += 1
        }
        // Arguments use the shortest encoding.
        if (additionalBytes == 1 && intData < UInt64(cborAdditionalInformation1Byte))
            || intData <= (UInt64(1) << (8 * (additionalBytes >> 1))) - 1
        {
            error = .NonMinimalCBOREncoding
            return nil
        }
        return intData
    }

    mutating func readMap(_ data: Span<UInt8>, _ length: UInt64, _ maxNestingLevel: Int32) -> Bool {
        let firstEntry = position
        var lastKey: CBORItemHead?
        var remaining = length
        while remaining > 0 {
            remaining -= 1
            let key = decode(data, maxNestingLevel - 1)
            let value = decode(data, maxNestingLevel - 1)
            guard let key, value != nil else {
                return false
            }
            guard key.isMapKey else {
                error = .IncorrectMapKeyType
                return false
            }
            // A duplicate key is reported before an out-of-order one; a key after the last one is neither.
            if let lastKey, ctapKeyOrder(lastKey, in: data, key, in: data) >= 0 {
                error = Self.entries(data, from: firstEntry, before: key.start, hasKey: key) ? .DuplicateKey : .OutOfOrderKey
                return false
            }
            lastKey = key
        }
        return true
    }

    /// Whether one of the map entries from `start` to `end` in `data` has the key `key`: the entries are canonical,
    /// so an equivalent key has the same bytes.
    static func entries(_ data: Span<UInt8>, from start: Int, before end: Int, hasKey key: CBORItemHead) -> Bool {
        let keyBytes = data.extracting(key.start..<key.scalarEnd)
        var offset = start
        while offset < end {
            let keyEnd = cborItemEnd(data, from: offset)
            if compareBytes(data.extracting(offset..<keyEnd), keyBytes) == 0 {
                return true
            }
            offset = cborItemEnd(data, from: keyEnd)
        }
        return false
    }

    mutating func readSimpleValue(_ additionalInfo: UInt8, _ value: UInt64) -> Bool {
        if additionalInfo > cborAdditionalInformation1Byte && additionalInfo <= cborAdditionalInformation8Bytes {
            error = .UnsupportedFloatingPointValue
            return false
        }
        if value <= UInt64(UInt8.max), CBORSimpleValue(rawValue: UInt8(value)) != nil {
            return true
        }
        error = .UnsupportedSimpleValue
        return false
    }
}

// MARK: - View

/// A data item the reader has accepted, read in place from its encoding: each value is decoded when asked for, and a
/// nested item is a view of the same bytes.
///
/// The item is canonical, so a map key equals another exactly when their encodings are the same bytes.
public struct CBORView: ~Escapable {
    /// The item's encoding, exactly.
    let encoded: Span<UInt8>

    @_lifetime(copy encoded)
    init(checked encoded: Span<UInt8>) {
        self.encoded = encoded
    }

    /// The item `data` holds exactly, or nil.
    @_lifetime(copy data)
    public init?(_ data: Span<UInt8>, maxNestingLevel: Int32 = cbor.kCBORMaxDepth) {
        let (error, bytesConsumed) = CBORDecoder.read(data, maxNestingLevel: maxNestingLevel, allowTrailingData: false)
        guard error == .CBORNoError else {
            return nil
        }
        self.init(checked: data.extracting(0..<bytesConsumed))
    }

    /// The item at the start of `data`, or nil. `encoded.count` is the number of bytes it takes.
    @_lifetime(copy data)
    init?(prefixOf data: Span<UInt8>, maxNestingLevel: Int32 = cbor.kCBORMaxDepth) {
        let (error, bytesConsumed) = CBORDecoder.read(data, maxNestingLevel: maxNestingLevel, allowTrailingData: true)
        guard error == .CBORNoError else {
            return nil
        }
        self.init(checked: data.extracting(0..<bytesConsumed))
    }

    private var head: CBORItemHead {
        cborHead(encoded, at: 0)
    }

    /// The value of an unsigned or negative integer (`getInteger()`), else nil.
    var integer: Int64? {
        let head = head
        switch head.majorType {
        case cborMajorUnsigned: return Int64(head.argument)
        case cborMajorNegative: return ~Int64(head.argument) // -argument - 1
        default: return nil
        }
    }

    /// The value of an unsigned integer (`getUnsigned()`), else nil.
    var unsigned: Int64? {
        let head = head
        return head.majorType == cborMajorUnsigned ? Int64(head.argument) : nil
    }

    /// A byte string's bytes, else nil.
    public var byteString: Span<UInt8>? {
        @_lifetime(copy self)
        get {
            payload(ofMajorType: cborMajorByteString)
        }
    }

    /// A text string's UTF-8, else nil.
    var textString: Span<UInt8>? {
        @_lifetime(copy self)
        get {
            payload(ofMajorType: cborMajorString)
        }
    }

    /// A simple value's number (20 false, 21 true, 22 null, 23 undefined), else nil.
    var simpleValue: UInt8? {
        let head = head
        return head.majorType == cborMajorSimpleValue ? head.additionalInfo : nil
    }

    /// `getBool()` of a value that `isBool()`, else nil.
    public var bool: Bool? {
        switch simpleValue {
        case CBORSimpleValue.trueValue.rawValue: true
        case CBORSimpleValue.falseValue.rawValue: false
        default: nil
        }
    }

    /// Whether the item is a map.
    public var isMap: Bool { head.majorType == cborMajorMap }
    var isText: Bool { head.majorType == cborMajorString }

    /// A text string's characters, else nil.
    ///
    /// The reader accepted only valid UTF-8.
    public var string: Swift.String? {
        guard let utf8 = textString else {
            return nil
        }
        if let characters = try? UTF8Span(validating: utf8) {
            return Swift.String(copying: characters)
        }
        return ""
    }

    /// Whether the item is a text string of exactly the UTF-8 of `string`.
    func textEquals(_ string: Swift.String) -> Bool {
        guard let utf8 = textString else {
            return false
        }
        let expected = string.utf8
        return compareBytes(utf8, expected.span) == 0
    }

    /// The number of an array's elements or a map's entries, else nil.
    public var count: Int? {
        let head = head
        return head.majorType == cborMajorArray || head.majorType == cborMajorMap ? Int(head.argument) : nil
    }

    @_lifetime(copy self)
    private func payload(ofMajorType majorType: UInt8) -> Span<UInt8>? {
        let head = head
        guard head.majorType == majorType else {
            return nil
        }
        return encoded.extracting(head.payloadStart..<encoded.count)
    }

    /// An array's elements in order, else nil.
    public var elements: Items? {
        @_lifetime(copy self)
        get {
            let head = head
            guard head.majorType == cborMajorArray else {
                return nil
            }
            return Items(encoded, from: head.payloadStart, count: head.argument)
        }
    }

    /// A map's entries in `ctapLess` order, else nil.
    var entries: Entries? {
        @_lifetime(copy self)
        get {
            let head = head
            guard head.majorType == cborMajorMap else {
                return nil
            }
            return Entries(items: Items(encoded, from: head.payloadStart, count: 2 * head.argument))
        }
    }

    /// The value of the map entry whose key is the text string `key`, else nil; nil also when the item is not a map.
    @_lifetime(copy self)
    public func value(forKey key: Swift.String) -> CBORView? {
        guard var entries else {
            return nil
        }
        while let entry = entries.next() {
            if entry.key.textEquals(key) {
                return entry.value
            }
        }
        return nil
    }

    /// The value of the map entry whose key is the integer `key`, else nil; nil also when the item is not a map.
    @_lifetime(copy self)
    public func value(forKey key: Int64) -> CBORView? {
        guard var entries else {
            return nil
        }
        while let entry = entries.next() {
            if entry.key.integer == key {
                return entry.value
            }
        }
        return nil
    }

    /// Items one after another in a checked encoding: an array's elements, or a map's keys and values.
    public struct Items: ~Escapable {
        private let encoding: Span<UInt8>
        private var offset: Int
        private var remaining: UInt64

        @_lifetime(copy encoding)
        fileprivate init(_ encoding: Span<UInt8>, from offset: Int, count: UInt64) {
            self.encoding = encoding
            self.offset = offset
            self.remaining = count
        }

        /// The next item, or nil at the end.
        @_lifetime(copy self)
        public mutating func next() -> CBORView? {
            guard remaining > 0 else {
                return nil
            }
            remaining -= 1
            let start = offset
            offset = cborItemEnd(encoding, from: start)
            return CBORView(checked: encoding.extracting(start..<offset))
        }
    }

    /// A map entry.
    struct Entry: ~Escapable {
        let key: CBORView
        let value: CBORView

        @_lifetime(copy key, copy value)
        fileprivate init(key: CBORView, value: CBORView) {
            self.key = key
            self.value = value
        }
    }

    /// A map's entries in order.
    struct Entries: ~Escapable {
        private var items: Items

        @_lifetime(copy items)
        fileprivate init(items: Items) {
            self.items = items
        }

        @_lifetime(copy self)
        mutating func next() -> Entry? {
            guard let key = items.next(), let value = items.next() else {
                return nil
            }
            return Entry(key: key, value: value)
        }
    }
}

// MARK: - Writer

/// The CBOR writer: items emitted in order into one buffer, each head in the fewest bytes.
///
/// A map's entries are written by the caller, in `ctapLess` order; assertions check the order.
public struct CBORWriter {
    private(set) var bytes: [UInt8] = []
    // Changed only inside assertions, so it stays empty when they are off.
    private var openContainers: [OpenContainer] = []

    /// An array or map whose items are not all written yet.
    private struct OpenContainer {
        var remainingItems: UInt64
        let checksKeyOrder: Bool
        var keyStart = 0
        var previousKey: Range<Int>?
    }

    init() {}

    /// An empty writer with room for `capacity` bytes.
    public init(reservingCapacity capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    /// The major type, and `argument` in the fewest bytes.
    ///
    /// A map's keys are checked unless `checksKeyOrder` is false.
    mutating func writeHead(_ majorType: UInt8, _ argument: UInt64, checksKeyOrder: Bool = true) {
        assert(noteItemStart(majorType: majorType, argument: argument, checksKeyOrder: checksKeyOrder), "map keys out of ctapLess order")
        let head = majorType << cborMajorTypeBitShift
        if argument < UInt64(cborAdditionalInformation1Byte) {
            bytes.append(head | UInt8(argument))
            return
        }
        let additionalInformation: UInt8
        let byteCount: Int
        if argument <= 0xFF {
            additionalInformation = cborAdditionalInformation1Byte
            byteCount = 1
        } else if argument <= 0xFFFF {
            additionalInformation = cborAdditionalInformation2Bytes
            byteCount = 2
        } else if argument <= 0xFFFF_FFFF {
            additionalInformation = cborAdditionalInformation4Bytes
            byteCount = 4
        } else {
            additionalInformation = cborAdditionalInformation8Bytes
            byteCount = 8
        }
        bytes.append(head | additionalInformation)
        var shift = byteCount - 1
        while shift >= 0 {
            bytes.append(UInt8(truncatingIfNeeded: argument >> UInt64(shift * 8)))
            shift -= 1
        }
    }

    /// An unsigned or negative integer.
    public mutating func writeInteger(_ value: Int64) {
        if value >= 0 {
            writeHead(cborMajorUnsigned, UInt64(value))
        } else {
            writeHead(cborMajorNegative, UInt64(bitPattern: ~value)) // -(value + 1)
        }
    }

    /// A byte string of `value`.
    public mutating func writeByteString(_ value: Span<UInt8>) {
        writeHead(cborMajorByteString, UInt64(value.count))
        appendBytes(value)
    }

    /// A text string of the UTF-8 `value`.
    mutating func writeTextString(utf8 value: Span<UInt8>) {
        writeHead(cborMajorString, UInt64(value.count))
        appendBytes(value)
    }

    /// A text string of the characters of `value`.
    public mutating func writeTextString(_ value: Swift.String) {
        let utf8 = value.utf8
        writeTextString(utf8: utf8.span)
    }

    /// The head of an array of `count` elements, which the caller writes in order.
    public mutating func beginArray(count: Int) {
        writeHead(cborMajorArray, UInt64(count))
    }

    /// The head of a map of `count` entries, which the caller writes in `ctapLess` order.
    public mutating func beginMap(count: Int) {
        writeHead(cborMajorMap, UInt64(count))
    }

    mutating func writeBool(_ value: Bool) {
        writeSimpleValue(value ? .trueValue : .falseValue)
    }

    fileprivate mutating func writeSimpleValue(_ value: CBORSimpleValue) {
        writeHead(cborMajorSimpleValue, UInt64(value.rawValue))
    }

    /// One byte that is not part of an item: a command's code before its parameters.
    public mutating func append(byte: UInt8) {
        bytes.append(byte)
    }

    /// An item encoded elsewhere (a COSE key, a user entity map, an attestation statement), as it is.
    public mutating func append(encodedItem: Span<UInt8>) {
        assert(noteItemStart(majorType: cborMajorUnsigned, argument: 0, checksKeyOrder: false), "map keys out of ctapLess order")
        appendBytes(encodedItem)
    }

    /// Notes an item that starts at the end of `bytes`.
    ///
    /// False when it is a map value whose key does not follow the one before in `ctapLess` order. Called only from
    /// assertions.
    private mutating func noteItemStart(majorType: UInt8, argument: UInt64, checksKeyOrder: Bool) -> Bool {
        while let last = openContainers.last, last.remainingItems == 0 {
            openContainers.removeLast()
        }
        let start = bytes.count
        var inOrder = true
        if var container = openContainers.popLast() {
            if container.checksKeyOrder {
                // A map's items alternate key, value: an even count left means a key starts.
                if container.remainingItems % 2 == 0 {
                    container.keyStart = start
                } else {
                    let key = container.keyStart..<start
                    if let previousKey = container.previousKey {
                        let data: Span<UInt8> = bytes.span
                        let previous = data.extracting(previousKey)
                        let current = data.extracting(key)
                        inOrder = ctapKeyOrder(describedKeyHead(previous), in: previous, describedKeyHead(current), in: current) < 0
                    }
                    container.previousKey = key
                }
            }
            container.remainingItems -= 1
            openContainers.append(container)
        }
        if majorType == cborMajorArray && argument > 0 {
            openContainers.append(OpenContainer(remainingItems: argument, checksKeyOrder: false))
        } else if majorType == cborMajorMap && argument > 0 {
            openContainers.append(OpenContainer(remainingItems: 2 * argument, checksKeyOrder: checksKeyOrder))
        }
        return inOrder
    }

    /// The map `map` with the entry for the text key `key` set to the item `value` encodes, or removed when `value` is
    /// nil: the other entries are copied in order, and the new one goes where `ctapLess` puts it.
    mutating func append(_ map: CBORView, settingTextKey key: Swift.String, toEncodedItem value: Span<UInt8>?) {
        guard var entries = map.entries else {
            return
        }
        var keyWriter = CBORWriter(reservingCapacity: key.utf8.count + 9)
        keyWriter.writeTextString(key)
        let encodedKey = keyWriter.takeBytes()
        let keySpan: Span<UInt8> = encodedKey.span
        let keyHead = describedKeyHead(keySpan)

        var kept = 0
        var counter = entries
        while let entry = counter.next() {
            if ctapKeyOrder(describedKeyHead(entry.key.encoded), in: entry.key.encoded, keyHead, in: keySpan) != 0 {
                kept += 1
            }
        }
        beginMap(count: kept + (value == nil ? 0 : 1))
        var written = false
        while let entry = entries.next() {
            let order = ctapKeyOrder(describedKeyHead(entry.key.encoded), in: entry.key.encoded, keyHead, in: keySpan)
            if !written && order >= 0 {
                written = true
                if let value {
                    append(encodedItem: keySpan)
                    append(encodedItem: value)
                }
            }
            if order != 0 {
                append(encodedItem: entry.key.encoded)
                append(encodedItem: entry.value.encoded)
            }
        }
        if !written, let value {
            append(encodedItem: keySpan)
            append(encodedItem: value)
        }
    }

    /// A map of the text keys and encoded items in `entries`, given in any order.
    ///
    /// Written in `ctapLess` order of the keys' UTF-16 (length, then code units, so two keys that differ only in an
    /// unpaired surrogate stay two entries), and of two entries with equal keys the later one. Each key is written as
    /// its UTF-8, each unpaired surrogate as U+FFFD.
    mutating func appendMap(sortingTextKeys entries: [(key: WTF.String, value: [UInt8])]) {
        var keyWriter = CBORWriter(reservingCapacity: 16 * entries.count)
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(entries.count)
        var units: [[UInt16]] = []
        units.reserveCapacity(entries.count)
        for entry in entries {
            let start = keyWriter.bytes.count
            keyWriter.writeTextString(utf8: utf8Bytes(of: entry.key).span)
            ranges.append(start..<keyWriter.bytes.count)
            units.append(utf16Units(of: entry.key))
        }
        let encodedKeys = keyWriter.takeBytes()
        func order(_ a: Int, _ b: Int) -> Int {
            let aUnits = units[a]
            let bUnits = units[b]
            if aUnits.count != bUnits.count {
                return aUnits.count < bUnits.count ? -1 : 1
            }
            for index in aUnits.indices where aUnits[index] != bUnits[index] {
                return aUnits[index] < bUnits[index] ? -1 : 1
            }
            return 0
        }
        var sorted = Array(entries.indices)
        sorted.sort { a, b in
            let result = order(a, b)
            return result != 0 ? result < 0 : a < b
        }
        var kept: [Int] = []
        kept.reserveCapacity(sorted.count)
        for position in sorted.indices {
            if position + 1 < sorted.count && order(sorted[position], sorted[position + 1]) == 0 {
                continue
            }
            kept.append(sorted[position])
        }
        // Keys sorted by UTF-16 but written as UTF-8 can be out of order as encoded, as in the C++.
        writeHead(cborMajorMap, UInt64(kept.count), checksKeyOrder: false)
        let data: Span<UInt8> = encodedKeys.span
        for index in kept {
            append(encodedItem: data.extracting(ranges[index]))
            let value = entries[index].value
            append(encodedItem: value.span)
        }
    }

    private mutating func appendBytes(_ source: Span<UInt8>) {
        bytes.append(addingCapacity: source.count) { output in
            for index in source.indices {
                output.append(source[index])
            }
        }
    }

    consuming func takeBytes() -> [UInt8] {
        bytes
    }
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
