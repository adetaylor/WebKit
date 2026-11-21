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

// The canonical encoding of a CBOR data item, behind `cbor::readCanonical` and `cbor::writeCanonical` (CBORBytes.h),
// which the unit tests and the benchmark call.

/// Reads the item given to `writeCanonical` and writes it as it reads.
///
/// It accepts map keys in any order and repeated (the first one kept), heads of any width, nested at most
/// `maxInputNestingLevel` deep; it writes the keys in CTAP2 order with the shortest heads.
private struct CBORCanonicalWriter {
    static var maxInputNestingLevel: Int { 64 }

    var position = 0
    var writer: CBORWriter

    /// A map entry read: its key, and where its value starts.
    struct Entry {
        var key: CBORItemHead
        var valueStart: Int
    }

    init(reservingCapacity capacity: Int) {
        writer = CBORWriter(reservingCapacity: capacity)
    }

    /// The head at `position`, and for a string its payload, leaving `position` after them; nil if they do not fit, or
    /// the item is not one the writer can write.
    mutating func readHead(_ data: Span<UInt8>) -> CBORItemHead? {
        guard position < data.count else {
            return nil
        }
        let start = position
        let initialByte = data[position]
        position += 1
        let additionalInfo = initialByte & cborAdditionalInformationMask
        var head = CBORItemHead(
            majorType: initialByte >> cborMajorTypeBitShift,
            additionalInfo: additionalInfo,
            argument: UInt64(additionalInfo),
            start: start,
            payloadStart: position
        )
        if additionalInfo >= cborAdditionalInformation1Byte {
            guard additionalInfo <= cborAdditionalInformation8Bytes else {
                return nil
            }
            let byteCount = 1 << Int(additionalInfo - cborAdditionalInformation1Byte)
            guard data.count - position >= byteCount else {
                return nil
            }
            var argument: UInt64 = 0
            for _ in 0..<byteCount {
                argument = argument << 8 | UInt64(data[position])
                position += 1
            }
            head.argument = argument
            head.payloadStart = position
            head.hasShortestArgument =
                argument >= UInt64(cborAdditionalInformation1Byte) && argument > (UInt64(1) << (8 * (byteCount >> 1))) - 1
        }
        let remaining = UInt64(data.count - position)
        switch head.majorType {
        case cborMajorUnsigned, cborMajorNegative:
            guard head.argument <= UInt64(Int64.max) else {
                return nil
            }
        case cborMajorByteString, cborMajorString:
            guard head.argument <= remaining else {
                return nil
            }
            position += Int(head.argument)
            if head.majorType == cborMajorString {
                head.describeText(data.extracting(head.payloadStart..<position))
            }
        case cborMajorArray, cborMajorMap:
            // Each item takes a byte or more.
            guard head.argument <= remaining else {
                return nil
            }
        case cborMajorSimpleValue:
            guard CBORSimpleValue(rawValue: additionalInfo) != nil else {
                return nil
            }
        default:
            return nil
        }
        return head
    }

    /// Reads the item at `position` without writing it; nil if it cannot be read (a map key that is not an integer or a
    /// text string included).
    mutating func skip(_ data: Span<UInt8>, _ readLevel: Int) -> CBORItemHead? {
        guard readLevel >= 0, let head = readHead(data) else {
            return nil
        }
        switch head.majorType {
        case cborMajorArray:
            for _ in 0..<head.argument {
                guard skip(data, readLevel - 1) != nil else {
                    return nil
                }
            }
        case cborMajorMap:
            for _ in 0..<head.argument {
                guard let key = skip(data, readLevel - 1), key.isMapKey, skip(data, readLevel - 1) != nil else {
                    return nil
                }
            }
        default:
            break
        }
        return head
    }

    /// Reads the item at `position` and writes it; false if it cannot be read, or nests deeper than `writeLevel`
    /// (arrays and maps count one level each).
    mutating func write(_ data: Span<UInt8>, _ readLevel: Int, _ writeLevel: Int32) -> Bool {
        guard readLevel >= 0, writeLevel >= 0, let head = readHead(data) else {
            return false
        }
        switch head.majorType {
        case cborMajorArray:
            writer.writeHead(cborMajorArray, head.argument)
            for _ in 0..<head.argument {
                guard write(data, readLevel - 1, writeLevel - 1) else {
                    return false
                }
            }
            return true
        case cborMajorMap:
            return writeMap(data, head, readLevel, writeLevel)
        default:
            writeScalar(head, data)
            return true
        }
    }

    /// The map `head` starts, its keys in `ctapLess` order, each once.
    mutating func writeMap(_ data: Span<UInt8>, _ head: CBORItemHead, _ readLevel: Int, _ writeLevel: Int32) -> Bool {
        var entries: [Entry] = []
        entries.reserveCapacity(Int(head.argument))
        for _ in 0..<head.argument {
            guard let key = skip(data, readLevel - 1), key.isMapKey else {
                return false
            }
            let valueStart = position
            guard skip(data, readLevel - 1) != nil else {
                return false
            }
            entries.append(Entry(key: key, valueStart: valueStart))
        }
        let end = position
        // Equivalent keys stay in the order read, so the first is the one kept.
        entries.sort { a, b in
            let order = ctapKeyOrder(a.key, in: data, b.key, in: data)
            return order != 0 ? order < 0 : a.key.start < b.key.start
        }
        var keptCount = 0
        for index in entries.indices
        where keptCount == 0 || ctapKeyOrder(entries[keptCount - 1].key, in: data, entries[index].key, in: data) != 0 {
            entries[keptCount] = entries[index]
            // At most entries.count: the sum cannot overflow.
            keptCount &+= 1
        }
        writer.writeHead(cborMajorMap, UInt64(keptCount))
        for index in 0..<keptCount {
            guard writeLevel > 0 else {
                return false
            }
            writeScalar(entries[index].key, data)
            position = entries[index].valueStart
            guard write(data, readLevel - 1, writeLevel - 1) else {
                return false
            }
        }
        position = end
        return true
    }

    /// An integer, a string or a simple value, in the shortest head.
    mutating func writeScalar(_ head: CBORItemHead, _ data: Span<UInt8>) {
        switch head.majorType {
        case cborMajorByteString:
            writer.writeByteString(data.extracting(head.payloadStart..<head.scalarEnd))
        case cborMajorString:
            if head.isValidUTF8 {
                writer.writeTextString(utf8: data.extracting(head.payloadStart..<head.scalarEnd))
            } else {
                writer.writeHead(cborMajorString, 0)
            }
        case cborMajorSimpleValue:
            writer.writeHead(cborMajorSimpleValue, UInt64(head.additionalInfo))
        default:
            writer.writeHead(head.majorType, head.argument)
        }
    }
}

extension cbor {
    /// The canonical encoding of the data item `item` holds exactly, nested at most `maxNestingLevel` deep, or none.
    @cxx
    @implementation
    public static func writeCanonical(_ item: cbor.Bytes, _ maxNestingLevel: Int) -> fido.OptionalByteVector {
        writeCanonicalBody(item, maxNestingLevel)
    }

    // The body takes the span: a span of an `@cxx @implementation` parameter does not compile (see WebAuthnApdu.swift).
    private static func writeCanonicalBody(_ item: cbor.Bytes, _ maxNestingLevel: Int) -> fido.OptionalByteVector {
        let data: Span<UInt8> = item.span()
        var canonicalWriter = CBORCanonicalWriter(reservingCapacity: data.count)
        guard canonicalWriter.write(data, CBORCanonicalWriter.maxInputNestingLevel, Int32(truncatingIfNeeded: maxNestingLevel)),
            canonicalWriter.position == data.count
        else {
            return fido.OptionalByteVector()
        }
        return fido.OptionalByteVector(canonicalWriter.writer.takeVector())
    }
}

/// The body of `cbor::readCanonical`, which forwards here; `result` is filled in place.
///
/// `input` is the caller's buffer: it stays allocated, at its length, for the call, nothing writes it while it is read
/// here, and its bytes have no invalid bit patterns. `result` is `cbor::readCanonical`'s local; Swift writes its
/// fields and touches nothing else of the caller's.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func readCanonicalCBOR(
    _ input: cbor.ByteSpan,
    _ maxNestingLevel: Int32,
    _ allowTrailingData: Bool,
    _ result: inout cbor.CanonicalReadResult
) {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: input)
    let (error, bytesConsumed) = CBORDecoder.read(data, maxNestingLevel: maxNestingLevel, allowTrailingData: allowTrailingData)
    result.error = error
    guard error == .CBORNoError else {
        return
    }
    result.bytesConsumed = bytesConsumed
    // The reader accepts only canonical items, so the item is written as its own bytes.
    result.canonical = makeByteVector(data.extracting(0..<bytesConsumed))
}

#endif // !WTF_PLATFORM_WATCHOS && !WTF_PLATFORM_MACCATALYST
