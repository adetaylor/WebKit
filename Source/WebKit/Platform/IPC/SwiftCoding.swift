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

#if ENABLE_SWIFT_IPC_RECEIVERS

import WebKit_Internal
import wtf

/// A malformed message argument, which makes C++ mark the message invalid.
struct IPCDecodingError: Error {}

/// The Swift counterpart of the C++ IPC::ArgumentCoder of a type.
///
/// A coder is separate from the type it decodes because one Swift type can stand for C++ types with
/// different encodings: `String?` is both a WTF::String and a std::optional<String>.
protocol IPCCoder {
    associatedtype Value: Sendable

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Value
    static func encode(_ value: Value, to encoder: IPC.SwiftReplyEncoder)
}

/// Swift types generated from .serialization.in types marked [Swift].
enum IPCTypes {}

// Safety: a SharedBuffer's contents never change, and its reference count is thread-safe.
@available(macOS 13.3, iOS 16.4, tvOS 16.4, watchOS 9.4, visionOS 1, *)
extension WebCore.SharedBuffer: @retroactive @unchecked Sendable {}

extension Bool: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Bool {
        var value = false
        guard decoder.decodeBool(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Bool, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension UInt8: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> UInt8 {
        var value: UInt8 = 0
        guard decoder.decodeUInt8(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: UInt8, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension UInt16: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> UInt16 {
        var value: UInt16 = 0
        guard decoder.decodeUInt16(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: UInt16, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension UInt32: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> UInt32 {
        var value: UInt32 = 0
        guard decoder.decodeUInt32(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: UInt32, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension UInt64: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> UInt64 {
        var value: UInt64 = 0
        guard decoder.decodeUInt64(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: UInt64, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension Int8: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Int8 {
        var value: Int8 = 0
        guard decoder.decodeInt8(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Int8, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension Int16: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Int16 {
        var value: Int16 = 0
        guard decoder.decodeInt16(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Int16, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension Int32: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Int32 {
        var value: Int32 = 0
        guard decoder.decodeInt32(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Int32, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension Int64: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Int64 {
        var value: Int64 = 0
        guard decoder.decodeInt64(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Int64, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension Float: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Float {
        var value: Float = 0
        guard decoder.decodeFloat(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Float, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

extension Double: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Double {
        var value: Double = 0
        guard decoder.decodeDouble(&value) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: Double, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value)
    }
}

/// A valid raw value of a WTF::ObjectIdentifier or WTF::AtomicObjectIdentifier, which is neither 0 nor
/// UInt64.max.
struct IPCObjectIdentifierValue: Sendable, Hashable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 && rawValue != UInt64.max else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// The Swift form of WTF::ObjectIdentifier and WTF::AtomicObjectIdentifier, which each identifier type in
/// IPCTypes is a struct conforming to.
protocol IPCObjectIdentifier: IPCCoder, Sendable, Hashable where Value == Self {
    var value: IPCObjectIdentifierValue { get }

    init(value: IPCObjectIdentifierValue)
}

extension IPCObjectIdentifier {
    var rawValue: UInt64 { value.rawValue }

    init?(rawValue: UInt64) {
        guard let value = IPCObjectIdentifierValue(rawValue: rawValue) else {
            return nil
        }
        self.init(value: value)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Self {
        guard let identifier = Self(rawValue: try UInt64.decode(from: &decoder)) else {
            throw IPCDecodingError()
        }
        return identifier
    }

    static func encode(_ value: Self, to encoder: IPC.SwiftReplyEncoder) {
        encoder.encode(value.rawValue)
    }
}

/// Coders for the C++ templates and WTF types that have Swift forms.
enum IPCCoding {
    /// std::optional<T>, and RefPtr<T>.
    enum StdOptional<Wrapped: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Wrapped.Value? {
            guard try Bool.decode(from: &decoder) else {
                return nil
            }
            return try Wrapped.decode(from: &decoder)
        }

        static func encode(_ value: Wrapped.Value?, to encoder: IPC.SwiftReplyEncoder) {
            encoder.encode(value != nil)
            if let value {
                Wrapped.encode(value, to: encoder)
            }
        }
    }

    /// std::pair<First, Second>: the first member, then the second.
    enum Pair<First: IPCCoder, Second: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> (First.Value, Second.Value) {
            let first = try First.decode(from: &decoder)
            return (first, try Second.decode(from: &decoder))
        }

        static func encode(_ value: (First.Value, Second.Value), to encoder: IPC.SwiftReplyEncoder) {
            First.encode(value.0, to: encoder)
            Second.encode(value.1, to: encoder)
        }
    }

    /// C++-decoded values: C++ objects that their own ArgumentCoder decodes and encodes, so that Swift accepts
    /// exactly what C++ does, and copies nothing.
    enum CxxDecoded {
        /// WebCore::SharedBuffer, whether it came inline or in shared memory.
        enum SharedBuffer: IPCCoder {
            static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> WebCore.SharedBuffer {
                guard let buffer = decoder.decodeSharedBuffer() else {
                    throw IPCDecodingError()
                }
                return buffer
            }

            static func encode(_ value: WebCore.SharedBuffer, to encoder: IPC.SwiftReplyEncoder) {
                encoder.encodeSharedBuffer(value)
            }
        }
    }

    /// Markable<T>, whose flag is set when the value is absent.
    enum Markable<Wrapped: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Wrapped.Value? {
            if try Bool.decode(from: &decoder) {
                return nil
            }
            return try Wrapped.decode(from: &decoder)
        }

        static func encode(_ value: Wrapped.Value?, to encoder: IPC.SwiftReplyEncoder) {
            encoder.encode(value == nil)
            if let value {
                Wrapped.encode(value, to: encoder)
            }
        }
    }

    /// Vector<T>.
    ///
    /// Decoding one element at a time reads the same bytes as the block C++ sends for arithmetic types.
    enum Vector<Element: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> [Element.Value] {
            let count = try UInt64.decode(from: &decoder)
            var result: [Element.Value] = []
            // As in C++, reserve at most 1MB for an untrusted count, because large reservations can crash the
            // allocator.
            let maximumReservation = UInt64(1024 * 1024 / MemoryLayout<Element.Value>.stride)
            result.reserveCapacity(Int(min(count, UInt64(decoder.remainingByteCount()), maximumReservation)))
            for _ in 0..<count {
                result.append(try Element.decode(from: &decoder))
            }
            return result
        }

        static func encode(_ value: [Element.Value], to encoder: IPC.SwiftReplyEncoder) {
            encoder.encode(UInt64(value.count))
            for element in value {
                Element.encode(element, to: encoder)
            }
        }
    }

    /// WTF::String, whose null string is nil.
    ///
    /// A Swift String cannot hold an unpaired UTF-16 surrogate, so one decodes as U+FFFD.
    /// We may in time choose to use our own Swift-side equivalent of WTF::String instead.
    enum WTFString: IPCCoder {
        private static let nullStringLength = UInt32.max

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> String? {
            let length = try UInt32.decode(from: &decoder)
            if length == nullStringLength {
                return nil
            }
            let is8Bit = try Bool.decode(from: &decoder)
            guard let count = Int(exactly: length) else {
                throw IPCDecodingError()
            }
            if is8Bit, #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
                return try decodeLatin1(count, from: &decoder)
            }
            guard decoder.beginArray(count, is8Bit ? 1 : 2) else {
                throw IPCDecodingError()
            }
            if is8Bit {
                var scalars = String.UnicodeScalarView()
                scalars.reserveCapacity(count)
                for _ in 0..<count {
                    scalars.append(Unicode.Scalar(try UInt8.decode(from: &decoder)))
                }
                return String(scalars)
            }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            for _ in 0..<count {
                units.append(try UInt16.decode(from: &decoder))
            }
            return String(decoding: units, as: Unicode.UTF16.self)
        }

        /// The longest 8-bit string whose UTF-8 is converted on the stack; most strings in messages are short.
        private static let inlineLatin1Capacity = 32

        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
        private static func decodeLatin1(_ count: Int, from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> String {
            // Each character takes at least a byte of the message, so a count beyond what is left is malformed.
            guard count <= decoder.remainingByteCount() else {
                decoder.markInvalid()
                throw IPCDecodingError()
            }
            var length = 0
            if count <= inlineLatin1Capacity {
                var utf8 = InlineArray<64, UInt8>(repeating: 0)
                var utf8Span = utf8.mutableSpan
                guard decoder.decodeLatin1Characters(count, &utf8Span, &length) else {
                    throw IPCDecodingError()
                }
                return try string(fromUTF8: utf8.span.extracting(0..<length))
            }
            var utf8 = [UInt8](repeating: 0, count: 2 * count)
            var utf8Span = utf8.mutableSpan
            guard decoder.decodeLatin1Characters(count, &utf8Span, &length) else {
                throw IPCDecodingError()
            }
            return String(decoding: utf8[..<length], as: Unicode.UTF8.self)
        }

        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
        private static func string(fromUTF8 utf8: Span<UInt8>) throws(IPCDecodingError) -> String {
            do {
                return String(copying: try UTF8Span(validating: utf8))
            } catch {
                throw IPCDecodingError()
            }
        }

        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
        private static func swiftLatin1String(_ value: borrowing WTF.String) -> String {
            let count = Int(value.length())
            if count <= inlineLatin1Capacity {
                var utf8 = InlineArray<64, UInt8>(repeating: 0)
                var utf8Span = utf8.mutableSpan
                let length = IPC.writeUTF8ForLatin1String(value, &utf8Span)
                return (try? string(fromUTF8: utf8.span.extracting(0..<length))) ?? ""
            }
            var utf8 = [UInt8](repeating: 0, count: 2 * count)
            var utf8Span = utf8.mutableSpan
            let length = IPC.writeUTF8ForLatin1String(value, &utf8Span)
            return String(decoding: utf8[..<length], as: Unicode.UTF8.self)
        }

        /// The WTF::String that C++ would have decoded where Swift decoded `value`, for handing it to C++.
        static func cxxString(_ value: String?) -> WTF.String {
            guard let value else {
                return WTF.String()
            }
            if value.utf8.allSatisfy({ $0 < 0x80 }), #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
                return IPC.stringForASCIICharacters(value.utf8Span.span)
            }
            var builder = IPC.SwiftStringBuilder()
            if value.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) {
                for scalar in value.unicodeScalars {
                    builder.appendLatin1(UInt8(scalar.value))
                }
            } else {
                for unit in value.utf16 {
                    builder.appendUTF16(unit)
                }
            }
            return builder.toString()
        }

        /// The Swift form of a WTF::String from C++, as if it had been decoded.
        static func swiftString(_ value: borrowing WTF.String) -> String? {
            if value.isNull() {
                return nil
            }
            if value.is8Bit(), #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
                return swiftLatin1String(value)
            }
            let length = value.length()
            if value.is8Bit() {
                var scalars = String.UnicodeScalarView()
                for index in 0..<length {
                    scalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: value.codeUnitAt(index))))
                }
                return String(scalars)
            }
            var units: [UInt16] = []
            units.reserveCapacity(Int(length))
            for index in 0..<length {
                units.append(value.codeUnitAt(index))
            }
            return String(decoding: units, as: Unicode.UTF16.self)
        }

        static func encode(_ value: String?, to encoder: IPC.SwiftReplyEncoder) {
            guard let value else {
                encoder.encode(nullStringLength)
                return
            }
            if value.utf8.allSatisfy({ $0 < 0x80 }), #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
                encoder.encodeUInt32(UInt32(value.utf8.count))
                encoder.encodeBool(true)
                encoder.encodeASCIICharacters(value.utf8Span.span)
                return
            }
            if value.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) {
                encoder.encode(UInt32(value.unicodeScalars.count))
                encoder.encode(true)
                for scalar in value.unicodeScalars {
                    encoder.encode(UInt8(scalar.value))
                }
                return
            }
            encoder.encode(UInt32(value.utf16.count))
            encoder.encode(false)
            for unit in value.utf16 {
                encoder.encode(unit)
            }
        }
    }
}

#endif // ENABLE_SWIFT_IPC_RECEIVERS
