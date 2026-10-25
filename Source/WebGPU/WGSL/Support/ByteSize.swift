// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
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

/// WTF `CheckedUint32` (`Checked<uint32_t, RecordOverflow>`): an overflow is recorded and sticky, and reading the value
/// while overflowed traps, as `Checked::value()` and `Checked::operator T()` crash (CheckedArithmetic.h:699-711).
@_spi(Testing)
public struct CheckedUInt32: Sendable {
    private var raw: UInt32
    @_spi(Testing)
    public private(set) var hasOverflowed: Bool

    @_spi(Testing)
    public init(_ value: UInt32) {
        raw = value
        hasOverflowed = false
    }

    /// `Checked(uint64_t)`: overflowed unless `value` fits in 32 bits.
    @_spi(Testing)
    public init(checking value: UInt64) {
        raw = UInt32(truncatingIfNeeded: value)
        hasOverflowed = value > UInt64(UInt32.max)
    }

    /// `Checked(int64_t)`, e.g. from `ConstantValue::integerValue()`: overflowed unless `value` is in `0...UINT32_MAX`.
    @_spi(Testing)
    public init(checking value: Int64) {
        raw = UInt32(truncatingIfNeeded: value)
        hasOverflowed = UInt32(exactly: value) == nil
    }

    private init(resultOverflowed: Void) {
        raw = 0
        hasOverflowed = true
    }

    @_spi(Testing)
    public var value: UInt32 {
        guard !hasOverflowed else {
            wgslFatal("Checked<uint32_t, RecordOverflow> read while overflowed", cppSite: "CheckedArithmetic.h:708")
        }
        return raw
    }

    // As safeAdd and safeMultiply, an operation that overflows leaves the stored value unchanged.
    @_spi(Testing)
    public static func += (lhs: inout CheckedUInt32, rhs: UInt32) {
        let (sum, overflow) = lhs.raw.addingReportingOverflow(rhs)
        if overflow {
            lhs.hasOverflowed = true
        } else {
            lhs.raw = sum
        }
    }

    @_spi(Testing)
    public static func += (lhs: inout CheckedUInt32, rhs: ByteSize) {
        lhs += rhs.bytes
    }

    @_spi(Testing)
    public static func *= (lhs: inout CheckedUInt32, rhs: UInt32) {
        let (product, overflow) = lhs.raw.multipliedReportingOverflow(by: rhs)
        if overflow {
            lhs.hasOverflowed = true
        } else {
            lhs.raw = product
        }
    }

    /// `unsigned - CheckedUint32` (CheckedArithmetic.h:840-848, 895-898): overflowed when `rhs` is, or when the
    /// difference is negative.
    @_spi(Testing)
    public static func - (lhs: UInt32, rhs: CheckedUInt32) -> CheckedUInt32 {
        if rhs.hasOverflowed {
            return CheckedUInt32(resultOverflowed: ())
        }
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs.raw)
        if overflow {
            return CheckedUInt32(resultOverflowed: ())
        }
        return CheckedUInt32(difference)
    }
}

/// `WTF::roundUpToMultipleOf` (MathExtras.h:759-771): `x` rounded up to a multiple of `divisor`, wrapping in the type of `x`.
@_spi(Testing)
public func wtfRoundUpToMultipleOf(_ divisor: UInt32, _ x: UInt32) -> UInt32 {
    assert(divisor != 0 && divisor & (divisor &- 1) == 0, "roundUpToMultipleOf divisor must be a power of two")
    let remainderMask = divisor &- 1
    return (x &+ remainderMask) & ~remainderMask
}

@_spi(Testing)
public func wtfRoundUpToMultipleOf(_ divisor: UInt32, _ x: UInt64) -> UInt64 {
    assert(divisor != 0 && divisor & (divisor &- 1) == 0, "roundUpToMultipleOf divisor must be a power of two")
    let remainderMask = UInt64(divisor) &- 1
    return (x &+ remainderMask) & ~remainderMask
}

/// A byte size as the C++ observes it, already saturated to UINT_MAX wherever the C++ saturates.
///
/// It has no arithmetic operators: every combination is a named operation that reproduces one C++ rule.
@_spi(Testing)
public struct ByteSize: Hashable, Comparable, Sendable {
    @_spi(Testing)
    public let bytes: UInt32

    @_spi(Testing)
    public static let saturated = ByteSize(bytes: .max)

    @_spi(Testing)
    public init(bytes: UInt32) {
        self.bytes = bytes
    }

    @_spi(Testing)
    public static func < (lhs: ByteSize, rhs: ByteSize) -> Bool {
        lhs.bytes < rhs.bytes
    }

    /// `Types::Array::stride()` (Types.cpp:43-46): the element size rounded up to the element alignment, wrapping.
    @_spi(Testing)
    public static func arrayStride(element: ByteSize, elementAlignment: ByteAlignment) -> ByteSize {
        ByteSize(bytes: wtfRoundUpToMultipleOf(elementAlignment.bytes, element.bytes))
    }

    /// `Type::maybeSize()` of a vector (Types.cpp:317-319).
    @_spi(Testing)
    public static func vectorSize(element: ByteSize, count: UInt8) -> ByteSize {
        ByteSize(bytes: element.bytes &* UInt32(count))
    }

    /// `Type::maybeSize()` of a matrix (Types.cpp:320-327).
    @_spi(Testing)
    public static func matrixSize(columns: UInt8, rows: UInt8, element: ByteSize, elementAlignment: ByteAlignment) -> ByteSize {
        // The size of the matrix is computed as: sizeof(array<vecR<T>, C>)
        // sizeof(vecR<T>)
        let rowSize = UInt32(rows) &* element.bytes
        // sizeof(array<vecR<T>, C>)
        let rowAlignment = (rows == 2 ? 2 : 4) &* elementAlignment.bytes
        return ByteSize(bytes: UInt32(columns) &* wtfRoundUpToMultipleOf(rowAlignment, rowSize))
    }

    /// `Type::maybeSize()` of an array (Types.cpp:328-345).
    ///
    /// `count` is the C++ `CheckedUint32 size`: 1 for a runtime-sized array and for an override count with no constant
    /// value, else the constant. A stride that wraps below the element size, or a size that overflows, is UINT_MAX.
    @_spi(Testing)
    public static func arraySize(count: CheckedUInt32, element: ByteSize, elementAlignment: ByteAlignment) -> ByteSize {
        var size = count
        let elementSize = element.bytes
        let stride = wtfRoundUpToMultipleOf(elementAlignment.bytes, elementSize)
        if stride < elementSize {
            return .saturated
        }
        size *= stride
        if size.hasOverflowed {
            return .saturated
        }
        return ByteSize(bytes: size.value)
    }

    /// One step of `Type::maybeSize()` of a primitive struct (Types.cpp:349-354): a plain `unsigned` sum, which wraps.
    @_spi(Testing)
    public func addingPrimitiveStructMember(_ member: ByteSize) -> ByteSize {
        ByteSize(bytes: bytes &+ member.bytes)
    }
}

/// An alignment in bytes.
///
/// A distinct type from `ByteSize`, so adding an alignment to a size is a compile error.
@_spi(Testing)
public struct ByteAlignment: Hashable, Sendable {
    @_spi(Testing)
    public let bytes: UInt32

    /// An alignment the C++ already treats as valid: a type's alignment, or a validated `@align`.
    ///
    /// As in `WTF::roundUpToMultipleOf`, a power of two is only asserted.
    @_spi(Testing)
    public init(_ bytes: UInt32) {
        assert(bytes != 0 && bytes & (bytes &- 1) == 0, "alignment must be a power of two")
        self.bytes = bytes
    }

    /// nil unless `value` is a power of two (`isPowerOfTwo`, AttributeValidator.cpp:543).
    @_spi(Testing)
    public init?(validating value: UInt32) {
        guard value != 0, value & (value &- 1) == 0 else {
            return nil
        }
        bytes = value
    }
}

/// The layout arithmetic of `AttributeValidator::visit(AST::Structure&)` (AttributeValidator.cpp:403-476), statement by
/// statement: `addMember` is one iteration of the member loop and `finish` is the code after it.
@_spi(Testing)
public struct StructureLayout: Sendable {
    private var previousSize = CheckedUInt32(0)
    private var alignment: UInt32 = 0
    private var size = CheckedUInt32(0)
    private var hasPreviousMember = false

    @_spi(Testing)
    public init() {}

    /// Returns the member's offset and, from the second member on, the previous member's padding
    /// (`offset - previousSize`, which traps when negative, as the C++ conversion of an overflowed `Checked` does).
    @_spi(Testing)
    public mutating func addMember(
        typeSize: ByteSize,
        fieldSize: ByteSize,
        fieldAlignment: ByteAlignment
    ) -> (offset: UInt32, previousMemberPadding: UInt32?) {
        let currentSize: UInt32 = size.hasOverflowed ? .max : size.value
        let offset: UInt32
        if size.hasOverflowed {
            offset = currentSize
        } else {
            let checkedOffset = CheckedUInt32(checking: wtfRoundUpToMultipleOf(fieldAlignment.bytes, UInt64(currentSize)))
            if checkedOffset.hasOverflowed {
                offset = .max
            } else {
                offset = checkedOffset.value
            }
        }

        alignment = alignment < fieldAlignment.bytes ? fieldAlignment.bytes : alignment
        size = CheckedUInt32(offset)
        size += fieldSize
        if size.hasOverflowed {
            size = CheckedUInt32(.max)
        }

        var previousMemberPadding: UInt32?
        if hasPreviousMember {
            previousMemberPadding = (offset - previousSize).value
        }
        hasPreviousMember = true

        previousSize = CheckedUInt32(offset)
        previousSize += typeSize
        if previousSize.hasOverflowed {
            previousSize = CheckedUInt32(currentSize)
        }
        return (offset, previousMemberPadding)
    }

    /// Returns the structure's size and alignment and the last member's padding (`finalSize - previousSize`).
    ///
    /// The padding is nil when no member was added, where the C++ writes through a null `previousMember`.
    @_spi(Testing)
    public func finish() -> (size: ByteSize, alignment: UInt32, lastMemberPadding: UInt32?) {
        let finalSize: UInt32
        if size.hasOverflowed {
            finalSize = .max
        } else {
            let checkedFinalSize = CheckedUInt32(checking: wtfRoundUpToMultipleOf(alignment, UInt64(size.value)))
            if checkedFinalSize.hasOverflowed {
                finalSize = .max
            } else {
                finalSize = checkedFinalSize.value
            }
        }
        let lastMemberPadding = (finalSize - previousSize).value
        return (ByteSize(bytes: finalSize), alignment, hasPreviousMember ? lastMemberPadding : nil)
    }
}

/// The runtime-sized array facts that both the `arrayLength` lowering and the minimum binding size depend on.
///
/// The lowering (GlobalVariableRewriter.cpp:705-778) emits `(__x_ArrayLength - offsetInBinding) / stride` and the clamp
/// subtracts 1 from it, which wraps unless the bound buffer holds at least `minimumBindingSize` bytes. The store size the
/// C++ writes back (GlobalVariableRewriter.cpp:2422-2423) counts the runtime array as one element (Types.cpp:330), so it
/// is at least that.
@_spi(Testing)
public struct RuntimeArrayLayout: Sendable {
    @_spi(Testing)
    public let offsetInBinding: UInt32
    @_spi(Testing)
    public let stride: UInt32

    /// `stride` is computed as GlobalVariableRewriter.cpp:739-740 does: the element size rounded up to the element
    /// alignment, wrapping (the same rule as `Types::Array::stride()`).
    @_spi(Testing)
    public init(offsetInBinding: UInt32, elementSize: ByteSize, elementAlignment: ByteAlignment) {
        self.offsetInBinding = offsetInBinding
        stride = ByteSize.arrayStride(element: elementSize, elementAlignment: elementAlignment).bytes
    }

    /// `offsetInBinding + stride`, saturated to UINT_MAX.
    @_spi(Testing)
    public var minimumBindingSize: ByteSize {
        var total = CheckedUInt32(offsetInBinding)
        total += stride
        if total.hasOverflowed {
            return .saturated
        }
        return ByteSize(bytes: total.value)
    }
}
