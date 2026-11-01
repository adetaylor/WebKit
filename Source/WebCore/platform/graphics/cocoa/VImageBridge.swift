// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && USE_ACCELERATE

import Accelerate

// The rows of an image inside a span of at least `byteCount` bytes, validated once:
// byteCount = (height - 1) * rowBytes + width * bytesPerPixel, with every step checked. rowBytes may be less than
// width * bytesPerPixel (consecutive rows then overlap, as C++ callers allow); the rows still end inside `byteCount`.
// The VImageBridge files build each vImage_Buffer from one of these and a span of at least `byteCount` bytes, so no
// vImage call reaches outside that span.
struct VImageGeometry {
    let width: vImagePixelCount
    let height: vImagePixelCount
    let rowBytes: Int
    let byteCount: Int

    init?(width: Int, height: Int, rowBytes: Int, bytesPerPixel: Int, byteCount: Int) {
        guard width > 0, height > 0, bytesPerPixel > 0, rowBytes >= 0, let usedRowBytes = width.checkedMultiplied(by: bytesPerPixel),
            let requiredBytes = requiredByteCount(rows: height, rowBytes: usedRowBytes, bytesPerRow: rowBytes),
            requiredBytes <= byteCount
        else {
            return nil
        }
        self.width = vImagePixelCount(width)
        self.height = vImagePixelCount(height)
        self.rowBytes = rowBytes
        self.byteCount = requiredBytes
    }
}

// Calls `body` with vImage buffers over the source and destination images. A nil source means that the destination
// also holds the source, with the source geometry.
func withVImageBuffers<Result>(
    source: Span<UInt8>?,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationGeometry: VImageGeometry,
    _ body: (_ source: inout vImage_Buffer, _ destination: inout vImage_Buffer) -> Result
) -> Result {
    precondition(destinationGeometry.byteCount <= destination.count)
    precondition(sourceGeometry.byteCount <= (source?.count ?? destination.count))
    return destination.withUnsafeMutableBufferPointer { destinationPointer in
        var destinationBuffer = unsafe vImage_Buffer(
            data: destinationPointer.baseAddress,
            height: destinationGeometry.height,
            width: destinationGeometry.width,
            rowBytes: destinationGeometry.rowBytes
        )
        guard let source else {
            var sourceBuffer = unsafe vImage_Buffer(
                data: destinationPointer.baseAddress,
                height: sourceGeometry.height,
                width: sourceGeometry.width,
                rowBytes: sourceGeometry.rowBytes
            )
            return unsafe body(&sourceBuffer, &destinationBuffer)
        }
        return source.withUnsafeBufferPointer { sourcePointer in
            // vImage takes its sources through vImage_Buffer's mutable pointer but doesn't write to them.
            var sourceBuffer = unsafe vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: sourcePointer.baseAddress),
                height: sourceGeometry.height,
                width: sourceGeometry.width,
                rowBytes: sourceGeometry.rowBytes
            )
            return unsafe body(&sourceBuffer, &destinationBuffer)
        }
    }
}

// Calls `body` with a pointer to four bytes, for vImage's channel maps and fill colors. (Passing a Swift array instead
// retains and releases its storage on every call.)
@inline(__always)
func withVImageBytes<Result>(_ bytes: SIMD4<UInt8>, _ body: (UnsafePointer<UInt8>) -> Result) -> Result {
    var bytes = bytes
    return withUnsafeBytes(of: &bytes) { buffer in
        unsafe body(buffer.assumingMemoryBound(to: UInt8.self).baseAddress.unsafelyUnwrapped)
    }
}

#endif // ENABLE_WEBCORE_SWIFT && USE_ACCELERATE
