// Copyright (C) 2010 Google Inc. All rights reserved.
// Copyright (C) 2014 University of Washington. All rights reserved.
// Copyright (C) 2017-2023 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_ENCRYPTED_MEDIA

public import WebCoreSwiftSupport

/// A string as WTF::String holds one: UTF-16 code units, which may include unpaired surrogates.
public struct EMEJSONString: Hashable, Sendable {
    /// The code units, inline when short.
    public let storage: InlineCodeUnits

    /// The code units, copied into an array.
    public var codeUnits: ContiguousArray<UInt16> {
        storage.array
    }

    /// A string of these code units.
    public init(_ codeUnits: ContiguousArray<UInt16>) {
        storage = InlineCodeUnits(codeUnits)
    }

    init(storage: InlineCodeUnits) {
        self.storage = storage
    }

    /// An ASCII literal.
    public init(_ literal: StaticString) {
        storage = InlineCodeUnits(literal.description.utf16)
    }

    /// Whether the string is an ASCII literal, which compares without allocating when it is short.
    public func equals(_ literal: StaticString) -> Bool {
        let bytes = literal.description.utf8
        guard storage.count == bytes.count else {
            return false
        }
        for (codeUnit, byte) in zip(storage, bytes) where codeUnit != UInt16(byte) {
            return false
        }
        return true
    }

    /// WTF::equalLettersIgnoringASCIICase(string, lowercaseLiteral), which lowercases with toASCIILowerUnchecked().
    public func equalsIgnoringASCIICase(_ lowercaseLiteral: StaticString) -> Bool {
        let literal = lowercaseLiteral.description.utf16
        guard storage.count == literal.count else {
            return false
        }
        for (codeUnit, literalCodeUnit) in zip(storage, literal) where codeUnit | 0x20 != literalCodeUnit {
            return false
        }
        return true
    }
}

/// A JSON::Value as JSON::Value::parseJSON() makes one.
public enum EMEJSONValue: Sendable {
    /// `null`.
    case null
    /// `true` or `false`.
    case boolean(Bool)
    /// A number, which the parser gives as a double.
    case number(Double)
    /// A string.
    case string(EMEJSONString)
    /// An array.
    case array([EMEJSONValue])
    /// An object.
    case object(EMEJSONObject)

    /// JSON::Value::asObject().
    public var object: EMEJSONObject? {
        if case .object(let object) = self {
            return object
        }
        return nil
    }

    /// JSON::Value::asArray().
    public var array: [EMEJSONValue]? {
        if case .array(let array) = self {
            return array
        }
        return nil
    }

    /// JSON::Value::asString(), with nil for its null String.
    public var string: EMEJSONString? {
        if case .string(let string) = self {
            return string
        }
        return nil
    }

    /// JSON::Value::asInteger() of a parsed number: WTF::truncateDoubleToInt32().
    public var integer: Int32? {
        if case .number(let number) = self {
            return EMEJSON.truncateDoubleToInt32(number)
        }
        return nil
    }
}

/// A JSON::Object: a name that appears more than once keeps its first place and its last value.
public struct EMEJSONObject: Sendable {
    // In the order the names first appear.
    private var members: [(name: EMEJSONString, value: EMEJSONValue)] = []
    // The members' positions by name, once there are too many to search one by one.
    private var positions: [EMEJSONString: Int]?
    private static let linearSearchLimit = 16

    /// The member names, each once, in the order they first appear.
    public var names: [EMEJSONString] {
        members.map(\.name)
    }

    /// JSON::Object::getValue().
    public subscript(name: EMEJSONString) -> EMEJSONValue? {
        position(of: name).map { members[$0].value }
    }

    /// JSON::Object::getValue() of an ASCII literal name.
    public func value(_ name: StaticString) -> EMEJSONValue? {
        if positions != nil {
            return self[EMEJSONString(name)]
        }
        for member in members where member.name.equals(name) {
            return member.value
        }
        return nil
    }

    /// JSON::Object::getArray().
    public func array(_ name: StaticString) -> [EMEJSONValue]? {
        value(name)?.array
    }

    /// JSON::Object::getString(), with nil for its null String.
    public func string(_ name: StaticString) -> EMEJSONString? {
        value(name)?.string
    }

    /// JSON::Object::getInteger().
    public func integer(_ name: StaticString) -> Int32? {
        value(name)?.integer
    }

    private func position(of name: EMEJSONString) -> Int? {
        if let positions {
            return positions[name]
        }
        return members.firstIndex { $0.name == name }
    }

    fileprivate mutating func reserveCapacity(_ capacity: Int) {
        members.reserveCapacity(capacity)
    }

    fileprivate mutating func set(_ name: EMEJSONString, _ value: EMEJSONValue) {
        if let position = position(of: name) {
            members[position].value = value
            return
        }
        members.append((name, value))
        if positions != nil {
            positions?[name] = members.count - 1
        } else if members.count > Self.linearSearchLimit {
            var positions = [EMEJSONString: Int](minimumCapacity: 2 * members.count)
            for (position, member) in members.enumerated() {
                positions[member.name] = position
            }
            self.positions = positions
        }
    }
}

/// JSON as WTF's JSON::Value reads it (wtf/JSONValues.cpp, in its strict mode) and as its toJSONString() writes the
/// strings these messages hold.
public enum EMEJSON {
    /// JSON::Value::parseJSON() of these bytes as Latin-1 characters, as the CDMs parse every buffer.
    public static func parse(latin1 input: Span<UInt8>) -> EMEJSONValue? {
        guard let (value, end) = buildValue(input, from: 0, depth: 0) else {
            return nil
        }
        for index in end..<input.count where !isWhitespace(input[index]) {
            return nil
        }
        return value
    }

    /// toJSONString() of a JSON::Array of strings, each the base64 or base64url of some bytes, which need no escaping.
    public static func writeStringArray(_ base64Strings: [ContiguousArray<UInt8>], to output: inout ContiguousArray<UInt8>) {
        output.append(0x5B)
        for (index, string) in base64Strings.enumerated() {
            if index > 0 {
                output.append(0x2C)
            }
            writeString(string, to: &output)
        }
        output.append(0x5D)
    }

    /// A string member of an object being written, `"name":"<base64 of bytes>"`, without the comma.
    public static func writeBase64Member(_ name: StaticString, of bytes: Span<UInt8>, to output: inout ContiguousArray<UInt8>) {
        writeName(name, to: &output)
        output.append(0x22)
        WTFBase64.encode(bytes, appendingTo: &output)
        output.append(0x22)
    }

    /// `"name":`, for an ASCII name that needs no escaping.
    public static func writeName(_ name: StaticString, to output: inout ContiguousArray<UInt8>) {
        output.append(0x22)
        output.append(contentsOf: name.description.utf8)
        output.append(0x22)
        output.append(0x3A)
    }

    private static func writeString(_ base64String: ContiguousArray<UInt8>, to output: inout ContiguousArray<UInt8>) {
        output.append(0x22)
        for character in base64String {
            precondition(isBase64Character(character))
            output.append(character)
        }
        output.append(0x22)
    }

    private static func isBase64Character(_ character: UInt8) -> Bool {
        switch character {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2B, 0x2D, 0x2F, 0x3D, 0x5F:
            true
        default:
            false
        }
    }

    /// WTF::truncateDoubleToInt32().
    public static func truncateDoubleToInt32(_ number: Double) -> Int32 {
        if number > -2147483649.0 && number < 2147483648.0 {
            return Int32(number.rounded(.towardZero))
        }
        #if arch(x86_64)
        // cvttsd2si's integer indefinite.
        return Int32.min
        #else
        // fcvtzs saturates, and gives 0 for NaN.
        if number.isNaN {
            return 0
        }
        return number < 0 ? Int32.min : Int32.max
        #endif
    }

    // JSONValues.cpp's stackLimit: a value nested deeper fails.
    private static let stackLimit = 1000

    private enum Token {
        case objectBegin
        case objectEnd
        case arrayBegin
        case arrayEnd
        case string
        case number
        case boolTrue
        case boolFalse
        case null
        case listSeparator
        case objectPairSeparator
        case invalid
    }

    // isASCIIWhitespaceWithoutFF.
    private static func isWhitespace(_ character: UInt8) -> Bool {
        character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D
    }

    private static func isDigit(_ character: UInt8) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func hexValue(_ character: UInt8) -> UInt16? {
        switch character {
        case 0x30...0x39:
            UInt16(character - 0x30)
        case 0x41...0x46:
            UInt16(character - 0x41 + 10)
        case 0x61...0x66:
            UInt16(character - 0x61 + 10)
        default:
            nil
        }
    }

    // The token at or after start, skipping whitespace, and the range it takes.
    private static func parseToken(_ data: Span<UInt8>, from start: Int) -> (Token, start: Int, end: Int) {
        var position = start
        while position < data.count && isWhitespace(data[position]) {
            position += 1
        }
        guard position < data.count else {
            return (.invalid, position, position)
        }

        let tokenStart = position
        func constant(_ literal: StaticString, _ token: Token) -> (Token, start: Int, end: Int) {
            let bytes = literal.description.utf8
            guard data.count - tokenStart >= bytes.count else {
                return (.invalid, tokenStart, tokenStart)
            }
            for (index, byte) in bytes.enumerated() where data[tokenStart + index] != byte {
                return (.invalid, tokenStart, tokenStart)
            }
            return (token, tokenStart, tokenStart + bytes.count)
        }

        switch data[position] {
        case 0x6E:
            return constant("null", .null)
        case 0x74:
            return constant("true", .boolTrue)
        case 0x66:
            return constant("false", .boolFalse)
        case 0x5B:
            return (.arrayBegin, tokenStart, tokenStart + 1)
        case 0x5D:
            return (.arrayEnd, tokenStart, tokenStart + 1)
        case 0x2C:
            return (.listSeparator, tokenStart, tokenStart + 1)
        case 0x7B:
            return (.objectBegin, tokenStart, tokenStart + 1)
        case 0x7D:
            return (.objectEnd, tokenStart, tokenStart + 1)
        case 0x3A:
            return (.objectPairSeparator, tokenStart, tokenStart + 1)
        case 0x30...0x39, 0x2D:
            if let end = numberTokenEnd(data, from: tokenStart) {
                return (.number, tokenStart, end)
            }
        case 0x22:
            if let end = stringTokenEnd(data, from: tokenStart + 1) {
                return (.string, tokenStart, end)
            }
        default:
            break
        }
        return (.invalid, tokenStart, tokenStart)
    }

    // readInt(): at least one digit, and no leading zero unless leading zeros are allowed or it is the only digit.
    private static func intEnd(_ data: Span<UInt8>, from start: Int, canHaveLeadingZeros: Bool) -> Int? {
        var position = start
        while position < data.count && isDigit(data[position]) {
            position += 1
        }
        let length = position - start
        if length == 0 {
            return nil
        }
        if !canHaveLeadingZeros && length > 1 && data[start] == 0x30 {
            return nil
        }
        return position
    }

    // parseNumberToken(): [minus] int [frac] [exp].
    private static func numberTokenEnd(_ data: Span<UInt8>, from start: Int) -> Int? {
        var position = start
        if data[position] == 0x2D {
            position += 1
        }
        guard let intEnd = intEnd(data, from: position, canHaveLeadingZeros: false) else {
            return nil
        }
        position = intEnd
        if position == data.count {
            return position
        }

        if data[position] == 0x2E {
            guard let fractionEnd = self.intEnd(data, from: position + 1, canHaveLeadingZeros: true) else {
                return nil
            }
            position = fractionEnd
            if position == data.count {
                return position
            }
        }

        if data[position] == 0x65 || data[position] == 0x45 {
            position += 1
            guard position < data.count else {
                return nil
            }
            if data[position] == 0x2D || data[position] == 0x2B {
                position += 1
                guard position < data.count else {
                    return nil
                }
            }
            guard let exponentEnd = self.intEnd(data, from: position, canHaveLeadingZeros: true) else {
                return nil
            }
            position = exponentEnd
        }
        return position
    }

    // parseStringToken(), from just after the opening quote: the end is just after the closing one.
    private static func stringTokenEnd(_ data: Span<UInt8>, from start: Int) -> Int? {
        var position = start
        while position < data.count {
            let character = data[position]
            position += 1
            if character == 0x5C && position < data.count {
                let escaped = data[position]
                position += 1
                switch escaped {
                case 0x78:
                    guard hexDigits(data, at: position, count: 2) else {
                        return nil
                    }
                    position += 2
                case 0x75:
                    guard hexDigits(data, at: position, count: 4) else {
                        return nil
                    }
                    position += 4
                case 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x76, 0x22:
                    break
                default:
                    return nil
                }
            } else if character == 0x22 {
                return position
            }
        }
        return nil
    }

    private static func hexDigits(_ data: Span<UInt8>, at start: Int, count: Int) -> Bool {
        guard data.count - start >= count else {
            return false
        }
        for index in start..<start + count where hexValue(data[index]) == nil {
            return false
        }
        return true
    }

    // decodeString() of a string token's contents.
    private static func decodeString(_ data: Span<UInt8>, _ range: Range<Int>) -> EMEJSONString? {
        if !contains(data, range, 0x5C) {
            // No escapes: the characters are the code units.
            return EMEJSONString(storage: InlineCodeUnits(latin1: data, range))
        }
        var output = InlineCodeUnits()
        var position = range.lowerBound
        while position < range.upperBound {
            var character = UInt16(data[position])
            position += 1
            if character != 0x5C {
                output.append(character)
                continue
            }
            guard position < range.upperBound else {
                return nil
            }
            character = UInt16(data[position])
            position += 1
            switch character {
            case 0x22, 0x2F, 0x5C:
                break
            case 0x62:
                character = 0x08
            case 0x66:
                character = 0x0C
            case 0x6E:
                character = 0x0A
            case 0x72:
                character = 0x0D
            case 0x74:
                character = 0x09
            case 0x76:
                character = 0x0B
            case 0x78:
                guard range.upperBound - position >= 2, let high = hexValue(data[position]), let low = hexValue(data[position + 1]) else {
                    return nil
                }
                character = high << 4 | low
                position += 2
            case 0x75:
                guard range.upperBound - position >= 4,
                    let digit0 = hexValue(data[position]), let digit1 = hexValue(data[position + 1]),
                    let digit2 = hexValue(data[position + 2]), let digit3 = hexValue(data[position + 3])
                else {
                    return nil
                }
                character = (digit0 << 4 | digit1) << 8 | (digit2 << 4 | digit3)
                position += 4
            default:
                return nil
            }
            output.append(character)
        }
        return EMEJSONString(storage: output)
    }

    private static func contains(_ data: Span<UInt8>, _ range: Range<Int>, _ character: UInt8) -> Bool {
        for index in range where data[index] == character {
            return true
        }
        return false
    }

    // charactersToDouble() of a number token: correctly rounded, out-of-range values becoming infinities or zeros. An
    // integer of at most 15 digits is exact as a Double.
    private static func number(_ data: Span<UInt8>, _ range: Range<Int>) -> Double? {
        let negative = data[range.lowerBound] == 0x2D
        let digitsStart = negative ? range.lowerBound + 1 : range.lowerBound
        if range.upperBound - digitsStart <= 15 {
            var integer: Int64 = 0
            var isInteger = true
            for index in digitsStart..<range.upperBound {
                let character = data[index]
                guard isDigit(character) else {
                    isInteger = false
                    break
                }
                integer = integer * 10 + Int64(character - 0x30)
            }
            if isInteger {
                return negative ? -Double(integer) : Double(integer)
            }
        }
        var text = ""
        text.reserveCapacity(range.count)
        for index in range {
            text.unicodeScalars.append(Unicode.Scalar(data[index]))
        }
        return Double(text)
    }

    // buildValue(): the value at or after start, and where it ends.
    private static func buildValue(_ data: Span<UInt8>, from start: Int, depth: Int) -> (EMEJSONValue, end: Int)? {
        if depth > stackLimit {
            return nil
        }

        let (token, tokenStart, tokenEnd) = parseToken(data, from: start)
        switch token {
        case .invalid:
            return nil
        case .null:
            return (.null, tokenEnd)
        case .boolTrue:
            return (.boolean(true), tokenEnd)
        case .boolFalse:
            return (.boolean(false), tokenEnd)
        case .number:
            guard let value = number(data, tokenStart..<tokenEnd) else {
                return nil
            }
            return (.number(value), tokenEnd)
        case .string:
            guard tokenEnd - tokenStart >= 2, let value = decodeString(data, tokenStart + 1..<tokenEnd - 1) else {
                return nil
            }
            return (.string(value), tokenEnd)
        case .arrayBegin:
            var array: [EMEJSONValue] = []
            array.reserveCapacity(4)
            var position = tokenEnd
            var (next, _, nextEnd) = parseToken(data, from: position)
            while next != .arrayEnd {
                guard let (element, elementEnd) = buildValue(data, from: position, depth: depth + 1) else {
                    return nil
                }
                array.append(element)
                position = elementEnd
                (next, _, nextEnd) = parseToken(data, from: position)
                if next == .listSeparator {
                    position = nextEnd
                    (next, _, nextEnd) = parseToken(data, from: position)
                    if next == .arrayEnd {
                        return nil
                    }
                } else if next != .arrayEnd {
                    return nil
                }
            }
            return (.array(array), nextEnd)
        case .objectBegin:
            var object = EMEJSONObject()
            object.reserveCapacity(4)
            var (next, nextStart, nextEnd) = parseToken(data, from: tokenEnd)
            while next != .objectEnd {
                guard next == .string, nextEnd - nextStart >= 2, let name = decodeString(data, nextStart + 1..<nextEnd - 1) else {
                    return nil
                }
                (next, _, nextEnd) = parseToken(data, from: nextEnd)
                guard next == .objectPairSeparator else {
                    return nil
                }
                guard let (value, valueEnd) = buildValue(data, from: nextEnd, depth: depth + 1) else {
                    return nil
                }
                object.set(name, value)
                (next, _, nextEnd) = parseToken(data, from: valueEnd)
                if next == .listSeparator {
                    (next, nextStart, nextEnd) = parseToken(data, from: nextEnd)
                    if next == .objectEnd {
                        return nil
                    }
                } else if next != .objectEnd {
                    return nil
                }
            }
            return (.object(object), nextEnd)
        case .objectEnd, .arrayEnd, .listSeparator, .objectPairSeparator:
            return nil
        }
    }
}

#endif // ENABLE_ENCRYPTED_MEDIA
