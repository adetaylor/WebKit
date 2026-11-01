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

/// Linear interpolation `a + t(b − a)`, bit for bit equal to libc++'s `std::lerp(float, float, float)`
/// on arm64 built with `-ffp-contract=off`, with the same result on every architecture.
@inline(__always)
func filterLerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    // Both formulas are computed and the result selected without branching on the signs of a and b, which callers
    // such as turbulence can't predict. low <= 0 && high >= 0 is false if a or b is NaN.
    let low = a < b ? a : b
    let high = a < b ? b : a
    let weighted = t * b + (1 - t) * a
    let zeroResult = weighted == weighted ? weighted : lerpNaN(t)
    let x = a + t * (b - a)
    let sameSignResult = x == x && t != 1 ? x : b
    return low <= 0 && high >= 0 ? zeroResult : sameSignResult
}

/// The NaN that `t * b + (1 - t) * a` gives on arm64: `t` quieted if `t` is NaN, otherwise the default NaN.
@inline(__always)
private func lerpNaN(_ t: Float) -> Float {
    Float(bitPattern: t == t ? 0x7fc0_0000 : t.bitPattern | 0x0040_0000)
}

/// √(x² + y² + z²), bit for bit equal to libc++'s three-argument `std::hypot(float, float, float)`
/// on arm64 built with `-ffp-contract=off`.
@inline(__always)
func filterHypot(_ x: Float, _ y: Float, _ z: Float) -> Float {
    // A finite, normal sum of squares means 2⁻⁶⁴ ≤ max(|x|, |y|, |z|) < 2⁶⁴, where no scaling is needed.
    let sumOfSquares = (x * x + y * y) + z * z
    if sumOfSquares >= .leastNormalMagnitude && sumOfSquares <= .greatestFiniteMagnitude {
        return sumOfSquares.squareRoot()
    }
    return scaledHypot(x, y, z)
}

// Kept out of line so that callers inline only the fast path.
@inline(never)
private func scaledHypot(_ x: Float, _ y: Float, _ z: Float) -> Float {
    if x.isNaN || y.isNaN || z.isNaN {
        let nan = z.isNaN ? z : (x.isNaN ? x : y)
        return Float(bitPattern: nan.bitPattern | 0x0040_0000)
    }
    let largest = max(max(x.magnitude, y.magnitude), z.magnitude)
    let scale: Float = largest > 0x1p64 ? 0x1p-84 : (largest < 0x1p-64 ? 0x1p84 : 1)
    let xs = x * scale
    let ys = y * scale
    let zs = z * scale
    let sumOfSquares = (xs * xs + ys * ys) + zs * zs
    return sumOfSquares.squareRoot() / scale
}

#endif // ENABLE_WEBCORE_SWIFT
