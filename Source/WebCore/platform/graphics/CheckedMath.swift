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

// Size, stride and offset arithmetic for code that must fail as the C++ did (return false, zero-fill or
// do nothing) rather than trap: each result is nil on overflow.
extension FixedWidthInteger {
    func checkedAdding(_ other: Self) -> Self? {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? nil : result
    }

    func checkedSubtracting(_ other: Self) -> Self? {
        let (result, overflow) = subtractingReportingOverflow(other)
        return overflow ? nil : result
    }

    func checkedMultiplied(by other: Self) -> Self? {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? nil : result
    }
}

// The bytes that `rows` rows need when consecutive rows start `bytesPerRow` apart and each uses
// `rowBytes`: (rows - 1) * bytesPerRow + rowBytes, and 0 for no rows. Nil for negative inputs or on
// overflow.
func requiredByteCount(rows: Int, rowBytes: Int, bytesPerRow: Int) -> Int? {
    guard rows >= 0, rowBytes >= 0, bytesPerRow >= 0 else {
        return nil
    }
    if rows == 0 {
        return 0
    }
    return (rows - 1).checkedMultiplied(by: bytesPerRow)?.checkedAdding(rowBytes)
}

// The byte range of row `row`, for rows that start `bytesPerRow` apart and use `rowBytes` each. Nil for
// negative inputs or on overflow.
func rowByteRange(_ row: Int, rowBytes: Int, bytesPerRow: Int) -> Range<Int>? {
    guard row >= 0, rowBytes >= 0, bytesPerRow >= 0, let start = row.checkedMultiplied(by: bytesPerRow),
        let end = start.checkedAdding(rowBytes)
    else {
        return nil
    }
    return start..<end
}

#endif // ENABLE_WEBCORE_SWIFT
