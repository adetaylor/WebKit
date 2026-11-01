// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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

// Big-endian reads at a 32-bit offset, the shells' `unsigned& offset`: a read needs its bytes in the view counting from
// the offset, computed in 64 bits so it never wraps. A failed read leaves the offset alone. Views of more than
// UInt32.max bytes can't be walked; parsers check isWalkable first.
struct ByteCursor: ~Escapable {
    let bytes: Span<UInt8>
    var offset: UInt32

    @_lifetime(copy bytes)
    init(_ bytes: Span<UInt8>, offset: UInt32 = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isWalkable: Bool {
        UInt64(bytes.count) <= UInt64(UInt32.max)
    }

    // view.size() - offset, or nil when the offset is past the end (WTF::safeSub). Compared as UInt64, since an offset
    // above Int32.max doesn't fit an arm64_32 Int.
    var remaining: Int? {
        UInt64(offset) <= UInt64(bytes.count) ? bytes.count - Int(offset) : nil
    }

    func canRead(_ count: Int) -> Bool {
        count >= 0 && UInt64(offset) + UInt64(count) <= UInt64(bytes.count)
    }

    mutating func readUInt8() -> UInt8? {
        guard canRead(1) else {
            return nil
        }
        let value = bytes[Int(offset)]
        advance(by: 1)
        return value
    }

    mutating func readInt8() -> Int8? {
        readUInt8().map { Int8(bitPattern: $0) }
    }

    mutating func readUInt16() -> UInt16? {
        readBigEndian(UInt16.self)
    }

    mutating func readUInt32() -> UInt32? {
        readBigEndian(UInt32.self)
    }

    mutating func readInt32() -> Int32? {
        readUInt32().map { Int32(bitPattern: $0) }
    }

    mutating func readUInt64() -> UInt64? {
        readBigEndian(UInt64.self)
    }

    // The next `count` bytes, all or nothing. Reading no bytes succeeds even when the offset is past the end.
    @_lifetime(copy self)
    mutating func readBytes(_ count: Int) -> Span<UInt8>? {
        if count == 0 {
            return bytes.extracting(0..<0)
        }
        guard canRead(count) else {
            return nil
        }
        let start = Int(offset)
        advance(by: UInt64(count))
        return bytes.extracting(start..<(start + count))
    }

    // Moves the offset with no bounds check, wrapping.
    mutating func advance(by count: UInt64) {
        offset = UInt32(truncatingIfNeeded: UInt64(offset) &+ count)
    }

    private mutating func readBigEndian<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> T? {
        // An offset above Int32.max, which an arm64_32 Int can't hold, is past the end of any view there.
        guard let value = bigEndianValue(T.self, at: Int(truncatingIfNeeded: offset)) else {
            return nil
        }
        advance(by: UInt64(MemoryLayout<T>.size))
        return value
    }

    // JSC::DataView::get<T>(offset, littleEndian = false): a big-endian value at an absolute offset, if it fits.
    func uint8(at offset: Int) -> UInt8? {
        bigEndianValue(UInt8.self, at: offset)
    }

    func uint16(at offset: Int) -> UInt16? {
        bigEndianValue(UInt16.self, at: offset)
    }

    func uint32(at offset: Int) -> UInt32? {
        bigEndianValue(UInt32.self, at: offset)
    }

    func uint64(at offset: Int) -> UInt64? {
        bigEndianValue(UInt64.self, at: offset)
    }

    private func bigEndianValue<T: FixedWidthInteger & UnsignedInteger>(_: T.Type, at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0 && offset <= bytes.count && bytes.count - offset >= size else {
            return nil
        }
        var value: T = 0
        for index in offset..<(offset + size) {
            value = value << 8 | T(bytes[index])
        }
        return value
    }
}

#endif // ENABLE_WEBCORE_SWIFT
