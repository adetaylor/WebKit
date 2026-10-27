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

// The safe Span overloads Swift synthesizes for the views' span() call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Internal.IntSize
import WebCore_Internal.PixelBuffer
import WebCore_Internal.PixelBufferConversion

// The rows the conversion reads and writes have to be inside the buffer the view describes.
private func hasEnoughBytesForConversion(
    pixelFormat: WebCore.PixelFormat,
    bytesPerRow: UInt32,
    byteCount: Int,
    destinationSize: borrowing WebCore.IntSize
) -> Bool {
    let width = destinationSize.width()
    let height = destinationSize.height()
    if width <= 0 || height <= 0 {
        return true
    }

    let (rowsBytes, rowsOverflow) = UInt(height - 1).multipliedReportingOverflow(by: UInt(bytesPerRow))
    let bytesPerPixel = UInt(WebCore.PixelBuffer.bytesPerPixel(pixelFormat))
    let (lastRowBytes, lastRowOverflow) = UInt(width).multipliedReportingOverflow(by: bytesPerPixel)
    let (requiredBytes, sumOverflow) = rowsBytes.addingReportingOverflow(lastRowBytes)
    return !rowsOverflow && !lastRowOverflow && !sumOverflow && UInt(byteCount) >= requiredBytes
}

@_expose(Cxx)
func hasEnoughBytesForConversion(
    _ view: borrowing WebCore.ConstPixelBufferConversionView,
    _ destinationSize: borrowing WebCore.IntSize
) -> Bool {
    let rows: Span<UInt8> = view.span()
    return hasEnoughBytesForConversion(
        pixelFormat: view.format.pixelFormat,
        bytesPerRow: view.bytesPerRow,
        byteCount: rows.count,
        destinationSize: destinationSize
    )
}

@_expose(Cxx)
func hasEnoughBytesForConversion(
    _ view: borrowing WebCore.PixelBufferConversionView,
    _ destinationSize: borrowing WebCore.IntSize
) -> Bool {
    let rows: MutableSpan<UInt8> = view.span()
    return hasEnoughBytesForConversion(
        pixelFormat: view.format.pixelFormat,
        bytesPerRow: view.bytesPerRow,
        byteCount: rows.count,
        destinationSize: destinationSize
    )
}

#endif // ENABLE_WEBCORE_SWIFT
