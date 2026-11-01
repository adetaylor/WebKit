// Copyright (C) 2022 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

// What the bit readers share with the C++ BitReader (BitReader.cpp): the reads that return nil past the end, and
// the reads with a sticky error, which return 0/false once any of them has failed (check ok afterwards). Bit counts
// are size_t in C++; a negative count here behaves like the huge size_t it would wrap to.
protocol BitReading: ~Escapable {
    // The next bit, most significant first; nil at the end.
    mutating func readBit() -> Bool?

    var ok: Bool { get }
    mutating func invalidate()
}

extension BitReading where Self: ~Escapable {
    // Reads `bits` bits (at most 64). read(0) consumes the rest of the data and returns nil, and the value is
    // accumulated in a UInt, so it keeps only the low 32 bits on 32-bit platforms.
    mutating func read(_ bits: Int) -> UInt64? {
        var remaining = UInt(bitPattern: bits)
        var value: UInt = 0
        repeat {
            guard let bit = readBit() else {
                return nil
            }
            value = value << 1 | (bit ? 1 : 0)
            remaining &-= 1
        } while remaining != 0
        return UInt64(value)
    }

    // read<T>(): sizeof(T) bytes' worth of bits, truncated to T.
    mutating func read<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> T? {
        read(MemoryLayout<T>.size * 8).map { T(truncatingIfNeeded: $0) }
    }

    // At most 32 bits.
    mutating func readBits(_ bits: Int) -> UInt32 {
        if !ok {
            return 0
        }
        guard let value = read(bits) else {
            invalidate()
            return 0
        }
        return UInt32(truncatingIfNeeded: value)
    }

    mutating func readFlag() -> Bool {
        if !ok {
            return false
        }
        guard let bit = readBit() else {
            invalidate()
            return false
        }
        return bit
    }

    mutating func consumeBits(_ bits: Int) {
        if !ok {
            return
        }
        var remaining = UInt(bitPattern: bits)
        while remaining != 0 {
            let chunk = min(remaining, 32)
            if read(Int(chunk)) == nil {
                invalidate()
                return
            }
            remaining -= chunk
        }
    }

    // ue(v). Codes with more than 31 leading zeros are invalid, so the largest value is 0xFFFFFFFE.
    mutating func readExpGolomb() -> UInt32 {
        if !ok {
            return 0
        }

        var leadingZeroBits = 0
        while true {
            guard let bit = readBit() else {
                invalidate()
                return 0
            }
            if bit {
                break
            }
            leadingZeroBits += 1
            if leadingZeroBits > 31 {
                invalidate()
                return 0
            }
        }

        if leadingZeroBits == 0 {
            return 0
        }

        guard let value = read(leadingZeroBits) else {
            invalidate()
            return 0
        }
        return (UInt32(1) << leadingZeroBits) - 1 + UInt32(truncatingIfNeeded: value)
    }

    // se(v), mapped from ue(v) as in H.264 table 9-3 and H.265 table 9-4.
    mutating func readSignedExpGolomb() -> Int32 {
        let codeNumber = readExpGolomb()
        if !ok {
            return 0
        }
        if codeNumber & 1 != 0 {
            return Int32(truncatingIfNeeded: (codeNumber &+ 1) / 2)
        }
        return -Int32(truncatingIfNeeded: codeNumber / 2)
    }

    // A size encoded as in MPEG-4 systems (ISO 14496-1, 8.3.3): 1 to 4 bytes of 7 bits, most significant first, the
    // high bit of each meaning another byte follows.
    mutating func readExpandableSize() -> UInt32 {
        if !ok {
            return 0
        }

        var size: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = read(8) else {
                invalidate()
                return 0
            }
            size = size << 7 | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 {
                return size
            }
        }

        invalidate()
        return 0
    }
}

// The C++ BitReader (BitReader.{h,cpp}), which stays for the parsers that are still C++. A Swift type named
// BitReader would clash with it: WebCoreSwift-Generated.h declares every Swift type of the module in namespace WebCore.
struct SpanBitReader: BitReading, ~Escapable {
    private let data: Span<UInt8>
    private var index = 0
    private var currentByte: UInt8 = 0
    private var remainingBits = 0
    private var isInvalid = false

    @_lifetime(copy data)
    init(_ data: Span<UInt8>) {
        self.data = data
    }

    var ok: Bool {
        !isInvalid
    }

    mutating func invalidate() {
        isInvalid = true
    }

    mutating func readBit() -> Bool? {
        if remainingBits == 0 {
            guard index < data.count else {
                return nil
            }
            currentByte = data[index]
            index += 1
            remainingBits = 8
        }

        let value = currentByte & 0x80 != 0
        remainingBits -= 1
        currentByte <<= 1
        return value
    }

    var byteOffset: Int {
        index
    }

    var bitOffset: Int {
        (remainingBits != 0 ? 8 - remainingBits : 0) + index * 8
    }

    // Moves `bytes` bytes on from the current byte position; false if that passes the end, or reaches the end in the
    // middle of a byte. Unlike readSpan(), it doesn't need byte alignment: mid-byte, the bits left in the current byte
    // are then taken from the byte it lands on, which is read again in full afterwards.
    mutating func skipBytes(_ bytes: Int) -> Bool {
        let newIndex = UInt(bitPattern: index) &+ UInt(bitPattern: bytes)
        guard newIndex < UInt(data.count) else {
            let isOver = newIndex > UInt(data.count) || remainingBits != 0
            index = data.count
            remainingBits = 0
            return !isOver
        }
        index = Int(newIndex)
        currentByte = data[index]
        return true
    }

    // The next `bytes` bytes, which must start on a byte boundary; nil, and a sticky failure, otherwise.
    @_lifetime(copy self)
    mutating func readSpan(_ bytes: Int) -> Span<UInt8>? {
        if isInvalid {
            return nil
        }
        guard remainingBits == 0, bytes >= 0, bytes <= data.count - index else {
            isInvalid = true
            return nil
        }
        let span = data.extracting(index..<(index + bytes))
        index += bytes
        return span
    }
}

// Reads the RBSP of a NAL unit, removing its emulation prevention bytes as it goes, so that it gives the same bits
// as a SpanBitReader over parseRbsp()'s copy without making one. Byte offsets count RBSP bytes.
struct RbspBitReader: BitReading, ~Escapable {
    private var bytes: RbspByteIterator
    private var rbspIndex = 0
    private var currentByte: UInt8 = 0
    private var remainingBits = 0
    private var isInvalid = false

    @_lifetime(copy nalUnit)
    init(_ nalUnit: Span<UInt8>) {
        bytes = RbspByteIterator(nalUnit)
    }

    var ok: Bool {
        !isInvalid
    }

    mutating func invalidate() {
        isInvalid = true
    }

    mutating func readBit() -> Bool? {
        if remainingBits == 0 {
            guard let byte = bytes.next() else {
                return nil
            }
            currentByte = byte
            rbspIndex += 1
            remainingBits = 8
        }

        let value = currentByte & 0x80 != 0
        remainingBits -= 1
        currentByte <<= 1
        return value
    }

    var byteOffset: Int {
        rbspIndex
    }

    var bitOffset: Int {
        (remainingBits != 0 ? 8 - remainingBits : 0) + rbspIndex * 8
    }

    // Whether the whole RBSP (parseRbsp(nalUnit).size()) is at least `count` bytes long. Only scans that far.
    func hasRbspSize(atLeast count: Int) -> Bool {
        var remainingBytes = bytes
        var available = rbspIndex
        while available < count {
            guard remainingBytes.next() != nil else {
                return false
            }
            available += 1
        }
        return true
    }
}

// The bytes parseRbsp() (AnnexBUtilities.cpp) copies: wherever 00 00 03 starts at or before count - 3, the 03 is
// dropped and the scan resumes after it.
struct RbspByteIterator: ~Escapable {
    private let data: Span<UInt8>
    private var index = 0
    private var inEmulationPreventionSequence = false

    @_lifetime(copy data)
    init(_ data: Span<UInt8>) {
        self.data = data
    }

    mutating func next() -> UInt8? {
        if inEmulationPreventionSequence {
            // The second 00; skip it and the 03.
            inEmulationPreventionSequence = false
            index += 2
            return 0
        }
        guard index < data.count else {
            return nil
        }
        let byte = data[index]
        if byte == 0 && data.count - index >= 3 && data[index + 1] == 0 && data[index + 2] == 3 {
            inEmulationPreventionSequence = true
        }
        index += 1
        return byte
    }
}

#endif // ENABLE_WEBCORE_SWIFT
