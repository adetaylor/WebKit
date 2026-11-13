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

// A C++ floating-point to integer conversion as arm64 compiles it (FCVTZS/FCVTZU): round toward zero,
// saturate to the destination's range, and NaN becomes 0, where Swift's own conversions trap out of
// range. For a narrower C++ destination (int16_t, uint8_t), convert to Int32 as the arm64 code does and
// then use `truncatingIfNeeded`, which keeps the low bits as the store does. These are the results on
// every architecture, including x86_64.
//
// Float and Double have their own overloads, in which the in-range conversion is the type's own (one
// instruction): the generic Result(value) calls FixedWidthInteger's out-of-line _convert(from:), and
// Debug builds don't specialize generics at all.
@inline(__always)
private func arm64Truncate<Source: BinaryFloatingPoint, Result: FixedWidthInteger>(_ value: Source) -> Result {
    if value.isNaN {
        return 0
    }
    if value <= Source(Result.min) {
        return .min
    }
    if value >= Source(Result.max) {
        return .max
    }
    return Result(value)
}

extension Int32 {
    @inline(__always)
    init<Source: BinaryFloatingPoint>(arm64Truncating value: Source) {
        self = arm64Truncate(value)
    }

    @inline(__always)
    init(arm64Truncating value: Float) {
        if value.isNaN {
            self = 0
        } else if value <= Float(Int32.min) {
            self = .min
        } else if value >= Float(Int32.max) {
            self = .max
        } else {
            self = Int32(value)
        }
    }

    @inline(__always)
    init(arm64Truncating value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(Int32.min) {
            self = .min
        } else if value >= Double(Int32.max) {
            self = .max
        } else {
            self = Int32(value)
        }
    }
}

extension UInt32 {
    @inline(__always)
    init<Source: BinaryFloatingPoint>(arm64Truncating value: Source) {
        self = arm64Truncate(value)
    }

    @inline(__always)
    init(arm64Truncating value: Float) {
        if value.isNaN {
            self = 0
        } else if value <= Float(UInt32.min) {
            self = .min
        } else if value >= Float(UInt32.max) {
            self = .max
        } else {
            self = UInt32(value)
        }
    }

    @inline(__always)
    init(arm64Truncating value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(UInt32.min) {
            self = .min
        } else if value >= Double(UInt32.max) {
            self = .max
        } else {
            self = UInt32(value)
        }
    }
}

extension Int64 {
    @inline(__always)
    init<Source: BinaryFloatingPoint>(arm64Truncating value: Source) {
        self = arm64Truncate(value)
    }

    @inline(__always)
    init(arm64Truncating value: Float) {
        if value.isNaN {
            self = 0
        } else if value <= Float(Int64.min) {
            self = .min
        } else if value >= Float(Int64.max) {
            self = .max
        } else {
            self = Int64(value)
        }
    }

    @inline(__always)
    init(arm64Truncating value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(Int64.min) {
            self = .min
        } else if value >= Double(Int64.max) {
            self = .max
        } else {
            self = Int64(value)
        }
    }
}

extension UInt64 {
    @inline(__always)
    init<Source: BinaryFloatingPoint>(arm64Truncating value: Source) {
        self = arm64Truncate(value)
    }

    @inline(__always)
    init(arm64Truncating value: Float) {
        if value.isNaN {
            self = 0
        } else if value <= Float(UInt64.min) {
            self = .min
        } else if value >= Float(UInt64.max) {
            self = .max
        } else {
            self = UInt64(value)
        }
    }

    @inline(__always)
    init(arm64Truncating value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(UInt64.min) {
            self = .min
        } else if value >= Double(UInt64.max) {
            self = .max
        } else {
            self = UInt64(value)
        }
    }
}

// C++ long and size_t.
extension Int {
    @inline(__always)
    init<Source: BinaryFloatingPoint>(arm64Truncating value: Source) {
        self = arm64Truncate(value)
    }

    @inline(__always)
    init(arm64Truncating value: Float) {
        if value.isNaN {
            self = 0
        } else if value <= Float(Int.min) {
            self = .min
        } else if value >= Float(Int.max) {
            self = .max
        } else {
            self = Int(value)
        }
    }

    @inline(__always)
    init(arm64Truncating value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(Int.min) {
            self = .min
        } else if value >= Double(Int.max) {
            self = .max
        } else {
            self = Int(value)
        }
    }
}

extension UInt {
    @inline(__always)
    init<Source: BinaryFloatingPoint>(arm64Truncating value: Source) {
        self = arm64Truncate(value)
    }

    @inline(__always)
    init(arm64Truncating value: Float) {
        if value.isNaN {
            self = 0
        } else if value <= Float(UInt.min) {
            self = .min
        } else if value >= Float(UInt.max) {
            self = .max
        } else {
            self = UInt(value)
        }
    }

    @inline(__always)
    init(arm64Truncating value: Double) {
        if value.isNaN {
            self = 0
        } else if value <= Double(UInt.min) {
            self = .min
        } else if value >= Double(UInt.max) {
            self = .max
        } else {
            self = UInt(value)
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT
