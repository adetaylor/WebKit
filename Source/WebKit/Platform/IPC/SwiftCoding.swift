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
#if canImport(Darwin)
import Darwin
#endif
#if canImport(os)
import os
#endif
#if canImport(IOSurface)
import IOSurface
#endif

/// A malformed message argument, which makes C++ mark the message invalid.
struct IPCDecodingError: Error {}

/// The error of a std::expected, as a Swift Result's failure.
struct IPCUnexpected<Failure: Sendable>: Error {
    let error: Failure

    init(_ error: Failure) {
        self.error = error
    }
}

/// The Swift counterpart of the C++ IPC::ArgumentCoder of a type.
///
/// A coder is separate from the type it decodes because one Swift type can stand for C++ types with
/// different encodings: `String?` is both a WTF::String and a std::optional<String>.
protocol IPCCoder {
    associatedtype Value: Sendable

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Value
    static func encode(_ value: Value, to encoder: IPC.SwiftReplyEncoder)

    /// The elements of a Vector<T>, after its count.
    static func decodeArray(count: Int, from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> [Value]
}

extension IPCCoder {
    /// Decoding one element at a time reads the same bytes as the block C++ sends for arithmetic types.
    static func decodeArray(count: Int, from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> [Value] {
        var result: [Value] = []
        // As in C++, reserve at most 1MB for an untrusted count, because large reservations can crash the
        // allocator.
        let maximumReservation = 1024 * 1024 / MemoryLayout<Value>.stride
        result.reserveCapacity(min(count, decoder.remainingByteCount(), maximumReservation))
        for _ in 0..<count {
            result.append(try decode(from: &decoder))
        }
        return result
    }
}

/// A trivially copyable primitive, a Vector of which C++ encodes as one block that Swift decodes in one call.
protocol IPCBlockPrimitive: IPCCoder, AdditiveArithmetic, Sendable where Value == Self {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Self>, from decoder: inout IPC.SwiftDecoder) -> Bool
}

extension IPCBlockPrimitive {
    static func decodeArray(count: Int, from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> [Self] {
        // FIXME: Remove this fallback once the minimum deployment target is 26. https://bugs.webkit.org/show_bug.cgi?id=NNNNNN
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else {
            var result: [Self] = []
            result.reserveCapacity(min(count, decoder.remainingByteCount(), 1024 * 1024 / MemoryLayout<Self>.stride))
            for _ in 0..<count {
                result.append(try decode(from: &decoder))
            }
            return result
        }
        // A count beyond what is left of the message is malformed, and mustn't be allocated.
        guard count <= decoder.remainingByteCount() / MemoryLayout<Self>.size else {
            decoder.markInvalid()
            throw IPCDecodingError()
        }
        var result = [Self](repeating: .zero, count: count)
        var span = result.mutableSpan
        guard decodeBlock(&span, from: &decoder) else {
            throw IPCDecodingError()
        }
        return result
    }
}

extension UInt8: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<UInt8>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeUInt8s(&values)
    }
}

extension UInt16: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<UInt16>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeUInt16s(&values)
    }
}

extension UInt32: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<UInt32>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeUInt32s(&values)
    }
}

extension UInt64: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<UInt64>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeUInt64s(&values)
    }
}

extension Int8: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Int8>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeInt8s(&values)
    }
}

extension Int16: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Int16>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeInt16s(&values)
    }
}

extension Int32: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Int32>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeInt32s(&values)
    }
}

extension Int64: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Int64>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeInt64s(&values)
    }
}

extension Float: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Float>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeFloats(&values)
    }
}

extension Double: IPCBlockPrimitive {
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    static func decodeBlock(_ values: inout MutableSpan<Double>, from decoder: inout IPC.SwiftDecoder) -> Bool {
        decoder.decodeDoubles(&values)
    }
}

/// Swift types generated from .serialization.in types marked [Swift].
enum IPCTypes {}

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

    /// std::expected<Value, Error>: whether it has a value, then the value or the error.
    enum Expected<Value: IPCCoder, Failure: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Result<Value.Value, IPCUnexpected<Failure.Value>> {
            if try Bool.decode(from: &decoder) {
                return .success(try Value.decode(from: &decoder))
            }
            return .failure(IPCUnexpected(try Failure.decode(from: &decoder)))
        }

        static func encode(_ value: Result<Value.Value, IPCUnexpected<Failure.Value>>, to encoder: IPC.SwiftReplyEncoder) {
            switch value {
            case .success(let value):
                encoder.encode(true)
                Value.encode(value, to: encoder)
            case .failure(let unexpected):
                encoder.encode(false)
                Failure.encode(unexpected.error, to: encoder)
            }
        }
    }

    /// std::expected<void, Error>: whether it has a value, then the error if it hasn't.
    enum ExpectedVoid<Failure: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Result<Void, IPCUnexpected<Failure.Value>> {
            if try Bool.decode(from: &decoder) {
                return .success(())
            }
            return .failure(IPCUnexpected(try Failure.decode(from: &decoder)))
        }

        static func encode(_ value: Result<Void, IPCUnexpected<Failure.Value>>, to encoder: IPC.SwiftReplyEncoder) {
            switch value {
            case .success:
                encoder.encode(true)
            case .failure(let unexpected):
                encoder.encode(false)
                Failure.encode(unexpected.error, to: encoder)
            }
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
    enum Vector<Element: IPCCoder>: IPCCoder {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> [Element.Value] {
            guard let count = Int(exactly: try UInt64.decode(from: &decoder)) else {
                throw IPCDecodingError()
            }
            return try Element.decodeArray(count: count, from: &decoder)
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
            if #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
                return try is8Bit ? decodeLatin1(count, from: &decoder) : decodeUTF16(count, from: &decoder)
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
            return String(decoding: try UInt16.decodeArray(count: count, from: &decoder), as: Unicode.UTF16.self)
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

        /// The longest 16-bit string whose UTF-8 is made on the stack.
        private static let inlineUTF16Capacity = 32

        @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
        private static func decodeUTF16(_ count: Int, from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> String {
            // Each code unit takes two bytes of the message, so a count beyond what is left is malformed.
            guard count <= decoder.remainingByteCount() / 2 else {
                decoder.markInvalid()
                throw IPCDecodingError()
            }
            var length = 0
            if count <= inlineUTF16Capacity {
                var utf8 = InlineArray<96, UInt8>(repeating: 0)
                var utf8Span = utf8.mutableSpan
                guard decoder.decodeUTF16Characters(count, &utf8Span, &length) else {
                    throw IPCDecodingError()
                }
                return try string(fromUTF8: utf8.span.extracting(0..<length))
            }
            var utf8 = [UInt8](repeating: 0, count: 3 * count)
            var utf8Span = utf8.mutableSpan
            guard decoder.decodeUTF16Characters(count, &utf8Span, &length) else {
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
                encoder.encode(UInt32(value.utf8.count))
                encoder.encode(true)
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

// The bytes of a std::span<const uint8_t> message argument, lent to its handler during dispatch. A handler reaches them
// only as a copy, in memory of its own.
extension IPC.LentBytes {
    /// A copy of the bytes.
    func copied() -> [UInt8] {
        var bytes: [UInt8] = []
        copyBytes(into: &bytes)
        return bytes
    }

    /// Replaces the contents of `storage` with a copy of the bytes, keeping its capacity, so that a handler can copy each
    /// message's bytes into the same storage.
    func copyBytes(into storage: inout [UInt8]) {
        let count = size()
        if storage.count > count {
            storage.removeLast(storage.count - count)
        } else if storage.count < count {
            storage.append(contentsOf: repeatElement(0, count: count - storage.count))
        }
        guard #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else {
            for index in 0..<count {
                storage[index] = byteAt(index)
            }
            return
        }
        var destination = storage.mutableSpan
        copyTo(&destination)
    }
}

#if canImport(Darwin)
/// The Swift form of an IPC type that owns what a message carries, such as a send right.
///
/// It is ~Copyable, so one value owns the resource at a time, and gives it back once: when it is destroyed, or when it
/// is encoded into a reply. Swift can't copy it, use it once it has encoded it, or give it back twice.
protocol IPCOwnedCoder: ~Copyable, Sendable {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Self
    static func encode(_ value: consuming Self, to encoder: IPC.SwiftReplyEncoder)
}

extension IPCTypes {
    /// A send right, as WTF::MachSendRight: deallocated when this is destroyed, unless it is encoded into a reply.
    struct MachSendRight: ~Copyable, IPCOwnedCoder {
        /// The name of the right's port, for calls that use the right without taking it over, or MACH_PORT_NULL if the
        /// sender sent no right.
        let port: mach_port_t

        // Only this file adopts a port name, so each right has one owner: the value that decoded it.
        fileprivate init(adopting port: mach_port_t) {
            self.port = port
        }

        /// No right.
        init() {
            self.init(adopting: mach_port_t(MACH_PORT_NULL))
        }

        var isNull: Bool {
            port == mach_port_t(MACH_PORT_NULL)
        }

        // Gives the right up, undeallocated, to whatever this file hands it to.
        fileprivate consuming func leakSendRight() -> mach_port_t {
            let port = self.port
            discard self
            return port
        }

        deinit {
            // Safety: the value owns the right, and only this deinit, or the encoding that leaks it, gives it up.
            unsafe WTF.deallocateSendRightSafely(port)
        }

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Self {
            // Safety: takeSendRight() gives the caller the right, which the new value then owns.
            let right = unsafe Self(adopting: decoder.takeSendRight())
            guard decoder.isValid() else {
                throw IPCDecodingError()
            }
            return right
        }

        static func encode(_ value: consuming Self, to encoder: IPC.SwiftReplyEncoder) {
            // Safety: the right is the consumed value's own, so the encoder is its only owner.
            unsafe encoder.encodeSendRight(value.leakSendRight())
        }
    }

    /// A Vector<MachSendRight>, which owns its rights until it is destroyed or encoded into a reply.
    ///
    /// A Swift Array can't hold MachSendRights, which are ~Copyable.
    struct MachSendRightVector: ~Copyable, IPCOwnedCoder {
        private var ports: [mach_port_t] = []

        init() {
        }

        var count: Int {
            ports.count
        }

        mutating func append(_ right: consuming MachSendRight) {
            ports.append(right.leakSendRight())
        }

        deinit {
            for port in ports {
                // Safety: append() took each right over from the value that owned it.
                unsafe WTF.deallocateSendRightSafely(port)
            }
        }

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Self {
            let count = try UInt64.decode(from: &decoder)
            var rights = Self()
            // Each right is an attachment, so decoding stops at the first missing one.
            for _ in 0..<count {
                rights.append(try MachSendRight.decode(from: &decoder))
            }
            return rights
        }

        static func encode(_ value: consuming Self, to encoder: IPC.SwiftReplyEncoder) {
            let ports = value.ports
            value.ports = []
            encoder.encode(UInt64(ports.count))
            for port in ports {
                // Safety: the rights were the consumed value's own, and it no longer holds them.
                unsafe encoder.encodeSendRight(port)
            }
        }
    }

    /// A semaphore that another process waits on, as IPC::Semaphore: a send right to a Mach semaphore.
    struct Semaphore: ~Copyable, IPCOwnedCoder {
        private let sendRight: MachSendRight

        /// The name of the semaphore's port, for C++ that takes a right of its own to it (MachSendRight::create()).
        var port: mach_port_t {
            sendRight.port
        }

        func signal() {
            semaphore_signal(sendRight.port)
        }

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Self {
            Self(sendRight: try MachSendRight.decode(from: &decoder))
        }

        static func encode(_ value: consuming Self, to encoder: IPC.SwiftReplyEncoder) {
            MachSendRight.encode(value.sendRight, to: encoder)
        }
    }

    /// A handle to memory that another process shares, as WebCore::SharedMemory::Handle: a send right to a memory entry,
    /// and the memory's size.
    struct SharedMemoryHandle: ~Copyable, IPCOwnedCoder {
        private let sendRight: MachSendRight
        let size: UInt64

        /// The name of the memory entry's port, for C++ that takes a right of its own to it (MachSendRight::create()).
        var port: mach_port_t {
            sendRight.port
        }

        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Self {
            let sendRight = try MachSendRight.decode(from: &decoder)
            // As SharedMemoryHandle's validator: a handle always has a right.
            guard !sendRight.isNull else {
                decoder.markInvalid()
                throw IPCDecodingError()
            }
            return Self(sendRight: sendRight, size: try UInt64.decode(from: &decoder))
        }

        static func encode(_ value: consuming Self, to encoder: IPC.SwiftReplyEncoder) {
            let size = value.size
            MachSendRight.encode(value.sendRight, to: encoder)
            encoder.encode(size)
        }

        /// The memory, mapped read-only, as WebCore::SharedMemory::map(handle, Protection::ReadOnly) maps it. nil if it
        /// can't be mapped.
        consuming func mapReadOnly() -> ReadOnlySharedMemory? {
            ReadOnlySharedMemory(self)
        }
    }

    /// Memory that another process shares, mapped read-only into this one until this goes.
    ///
    /// Its bytes stay at the same address, and this process can't change them; the other process can.
    final class ReadOnlySharedMemory: Sendable {
        private let task: mach_port_t
        private let address: mach_vm_address_t
        let size: UInt64

        fileprivate init?(_ handle: borrowing SharedMemoryHandle) {
            var mappedAddress: mach_vm_address_t = 0
            // Safety: mach_task_self_ is set before any Swift code runs, and never changes.
            let task = unsafe mach_task_self_
            // Safety: mach_vm_map() writes the address before it returns.
            let result = unsafe mach_vm_map(
                task,
                &mappedAddress,
                handle.size,
                0,
                VM_FLAGS_ANYWHERE | VM_FLAGS_RETURN_DATA_ADDR,
                handle.port,
                0,
                0,
                VM_PROT_READ,
                VM_PROT_READ,
                VM_INHERIT_NONE
            )
            guard result == KERN_SUCCESS else {
                #if canImport(os)
                WebKit.LogChannel.VirtualMemory().releaseLog.error("SharedMemory::map: Failed to map shared memory. (\(result))")
                #endif
                return nil
            }
            self.task = task
            address = mappedAddress
            size = handle.size
        }

        deinit {
            let result = mach_vm_deallocate(task, address, size)
            if result != KERN_SUCCESS {
                #if canImport(os)
                WebKit.LogChannel.VirtualMemory().releaseLog
                    .error("SharedMemory::~SharedMemory: Failed to deallocate shared memory. (\(result))")
                #endif
                assertionFailure()
            }
        }

        /// The `size` bytes of the mapping.
        func withBytes<R>(_ body: (RawSpan) -> R) -> R {
            guard let byteCount = Int(exactly: size), byteCount > 0 else {
                return body(RawSpan())
            }
            // Safety: mach_vm_map() mapped `size` readable bytes at `address`, which stay mapped until the deinit.
            let bytes = unsafe RawSpan(
                _unsafeStart: UnsafeRawPointer(bitPattern: UInt(address)) ?? mappingAtAddressZero(),
                byteCount: byteCount
            )
            return body(bytes)
        }
    }
}

#if canImport(IOSurface)
extension IPCTypes.MachSendRight {
    /// A right to an IOSurface, which another process looks the surface up with, as WebCore::IOSurface::createSendRight().
    init(surface: IOSurfaceRef) {
        self.init(adopting: IOSurfaceCreateMachPort(surface))
    }
}
#endif

extension IPCCoding {
    /// std::optional<T> of an owned type.
    enum OwnedOptional<Wrapped: IPCOwnedCoder & ~Copyable> {
        static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> Wrapped? {
            guard try Bool.decode(from: &decoder) else {
                return nil
            }
            return try Wrapped.decode(from: &decoder)
        }

        static func encode(_ value: consuming Wrapped?, to encoder: IPC.SwiftReplyEncoder) {
            switch consume value {
            case .some(let wrapped):
                encoder.encode(true)
                Wrapped.encode(wrapped, to: encoder)
            case .none:
                encoder.encode(false)
            }
        }
    }
}

private func mappingAtAddressZero<T>() -> T {
    preconditionFailure("a mapping at address 0")
}
#endif

extension IPC.StreamConnectionWorkQueue {
    /// Runs `work` on the queue's thread, from any thread.
    func dispatch(_ work: @escaping @Sendable () -> Void) {
        // Safety: the work is Sendable, so running it on the queue's thread can't race with what it captures.
        unsafe dispatch(consuming: WorkItem(work))
    }
}

#endif // ENABLE_SWIFT_IPC_RECEIVERS
