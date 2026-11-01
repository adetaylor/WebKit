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

// The safe Span overloads Swift synthesizes for the views' span accessors call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Internal.PixelBufferFormat
import WebCore_Internal.PixelBufferSwiftBridge

// The Swift side of convertImagePixels() and copyRowsInternal() (PixelBufferConversion.cpp), which hand over views
// that don't overlap, except for the one view of an in-place conversion.

@_expose(Cxx)
func pixelConversionConvert(
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    _ sourceBytesPerRow: UInt32,
    _ source: borrowing WebCore.PixelBytes,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ destinationBytesPerRow: UInt32,
    _ destination: inout WebCore.MutablePixelBytes,
    _ width: Int32,
    _ height: Int32
) {
    let sourceBytes: Span<UInt8> = source.span()
    var destinationBytes: MutableSpan<UInt8> = destination.mutableSpan()
    PixelConversion.convert(
        source: sourceBytes,
        sourceFormat: sourceFormat,
        sourceBytesPerRow: Int(sourceBytesPerRow),
        destination: &destinationBytes,
        destinationFormat: destinationFormat,
        destinationBytesPerRow: Int(destinationBytesPerRow),
        width: Int(width),
        height: Int(height)
    )
}

@_expose(Cxx)
func pixelConversionConvertInPlace(
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ bytesPerRow: UInt32,
    _ bytes: inout WebCore.MutablePixelBytes,
    _ width: Int32,
    _ height: Int32
) {
    var span: MutableSpan<UInt8> = bytes.mutableSpan()
    PixelConversion.convertInPlace(
        &span,
        bytesPerRow: Int(bytesPerRow),
        from: sourceFormat,
        to: destinationFormat,
        width: Int(width),
        height: Int(height)
    )
}

@_expose(Cxx)
func pixelConversionCopyRows(
    _ sourceBytesPerRow: UInt32,
    _ source: borrowing WebCore.PixelBytes,
    _ destinationBytesPerRow: UInt32,
    _ destination: inout WebCore.MutablePixelBytes,
    _ rows: UInt32,
    _ copyBytesPerRow: UInt32
) {
    let sourceBytes: Span<UInt8> = source.span()
    var destinationBytes: MutableSpan<UInt8> = destination.mutableSpan()
    copyRowsAsCopyRowsInternal(
        source: sourceBytes,
        sourceBytesPerRow: Int(sourceBytesPerRow),
        destination: &destinationBytes,
        destinationBytesPerRow: Int(destinationBytesPerRow),
        rows: Int(rows),
        rowBytes: Int(copyBytesPerRow)
    )
}

#endif // ENABLE_WEBCORE_SWIFT
