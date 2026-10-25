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

/// The C++ `half` (`__fp16`): IEEE binary16 storage with no arithmetic or comparison of its own.
///
/// As in C++, every operation promotes to `Float` and rounds back only where the C++ stores to `half`.
/// Conversions to `Half` round once to nearest even and quiet NaNs keeping their top payload bits, as
/// AArch64 FCVT and compiler-rt do. `Float(Half)` and `Double(Half)` are exact and keep a NaN's payload;
/// `Double(Half)` quiets a signaling NaN, and so does `Float(Half)` except on x86_64. Swift's `Float16`
/// is unavailable on x86_64 macOS.
@_spi(Testing)
public struct Half: Sendable, BitwiseCopyable {
    @_spi(Testing)
    public let bitPattern: UInt16

    @_spi(Testing)
    public init(bitPattern: UInt16) {
        self.bitPattern = bitPattern
    }

    @_spi(Testing)
    public init(_ value: Float) {
        bitPattern = roundedToHalf(UInt64(value.bitPattern), exponentBits: 8, fractionBits: 23)
    }

    @_spi(Testing)
    public init(_ value: Double) {
        bitPattern = roundedToHalf(value.bitPattern, exponentBits: 11, fractionBits: 52)
    }
}

extension Float {
    @_spi(Testing)
    public init(_ value: Half) {
        #if arch(x86_64)
        // DEV-11: x86_64 C++ `half` is a struct whose operator float() (compiler-rt __extendhfsf2) keeps a signaling NaN.
        self.init(bitPattern: widenedToFloat(value.bitPattern, quietingNaN: false))
        #else
        self.init(bitPattern: widenedToFloat(value.bitPattern, quietingNaN: true))
        #endif
    }
}

extension Double {
    @_spi(Testing)
    public init(_ value: Half) {
        // FCVT on arm64, and cvtss2sd after operator float() on x86_64, both quiet a signaling NaN.
        self.init(Float(bitPattern: widenedToFloat(value.bitPattern, quietingNaN: true)))
    }
}

private func roundedToHalf(_ bits: UInt64, exponentBits: UInt64, fractionBits: UInt64) -> UInt16 {
    let sign = UInt16(truncatingIfNeeded: bits &>> (exponentBits + fractionBits)) &<< 15
    let exponentMask = (1 &<< exponentBits) - 1
    let exponent = (bits &>> fractionBits) & exponentMask
    let fraction = bits & ((1 &<< fractionBits) - 1)

    if exponent == exponentMask {
        guard fraction != 0 else {
            return sign | 0x7C00
        }
        return sign | 0x7E00 | UInt16(truncatingIfNeeded: fraction &>> (fractionBits - 10))
    }
    // Zeros, and subnormals of the source format, which are far below half the smallest half subnormal (2^-25).
    guard exponent != 0 else {
        return sign
    }

    // The value is significand * 2^(e - fractionBits), with e in [1 - bias, bias].
    let bias = exponentMask &>> 1
    let e = Int(exponent) - Int(bias)
    let significand = fraction | (1 &<< fractionBits)
    // Keep 11 significand bits, or fewer for a half subnormal (e < -14).
    var shift = Int(fractionBits) - 10
    if e < -14 {
        shift += -14 - e
    }
    guard shift <= Int(fractionBits) + 1 else {
        return sign
    }
    let kept = significand &>> UInt64(shift)
    let remainder = significand & ((1 &<< UInt64(shift)) - 1)
    let halfway = UInt64(1) &<< UInt64(shift - 1)
    var rounded = kept
    if remainder > halfway || (remainder == halfway && kept & 1 == 1) {
        rounded += 1
    }
    if e < -14 {
        // A carry into bit 10 gives the smallest normal, which the bit layout already encodes.
        return sign | UInt16(truncatingIfNeeded: rounded)
    }
    var halfExponent = e + 15
    if rounded == 1 &<< 11 {
        rounded &>>= 1
        halfExponent += 1
    }
    guard halfExponent < 31 else {
        return sign | 0x7C00
    }
    return sign | UInt16(halfExponent) &<< 10 | UInt16(truncatingIfNeeded: rounded & 0x3FF)
}

private func widenedToFloat(_ bits: UInt16, quietingNaN: Bool) -> UInt32 {
    let sign = UInt32(bits & 0x8000) &<< 16
    let exponent = UInt32(bits &>> 10) & 0x1F
    let fraction = UInt32(bits & 0x3FF)

    if exponent == 0x1F {
        guard fraction != 0 else {
            return sign | 0x7F80_0000
        }
        return sign | (quietingNaN ? 0x7FC0_0000 : 0x7F80_0000) | fraction &<< 13
    }
    if exponent != 0 {
        return sign | (exponent + 112) &<< 23 | fraction &<< 13
    }
    guard fraction != 0 else {
        return sign
    }
    // Subnormal: fraction * 2^-24, normal as a Float.
    let top = UInt32(31 - fraction.leadingZeroBitCount)
    return sign | (top + 103) &<< 23 | (fraction &<< (23 - top)) & 0x7F_FFFF
}
