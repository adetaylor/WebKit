// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2010 Igalia, S.L.
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

#if ENABLE_WEBCORE_SWIFT && USE_ACCELERATE

import Accelerate

// FEGaussianBlurSoftwareApplier::boxBlurAccelerated(): three box convolutions of kernelSize pixels (made odd, as vImage
// requires) in both directions, extending the image's edges, from `image` to `temporary` and back and again, then the
// result copied into `image`. If vImage fails, `image` keeps what it had.
func vImageBoxBlur(_ image: inout MutableSpan<UInt8>, _ temporary: inout MutableSpan<UInt8>, kernelSize: Int, width: Int, height: Int) {
    guard let rowBytes = width.checkedMultiplied(by: 4),
        let geometry = VImageGeometry(
            width: width,
            height: height,
            rowBytes: rowBytes,
            bytesPerPixel: 4,
            byteCount: min(image.count, temporary.count)
        )
    else {
        assertionFailure()
        return
    }
    guard let size = UInt32(exactly: kernelSize % 2 == 1 ? kernelSize : kernelSize + 1) else {
        return
    }
    let flags = vImage_Flags(kvImageEdgeExtend)

    // vImage returns the size of the buffer it needs, or an error (which is negative).
    let bufferSize = unsafe withVImageBuffers(source: image.span, geometry, destination: &temporary, geometry) { source, destination in
        unsafe vImageBoxConvolve_ARGB8888(&source, &destination, nil, 0, 0, size, size, nil, flags | vImage_Flags(kvImageGetTempBufferSize))
    }
    if bufferSize <= 0 {
        return
    }
    // vImage's scratch memory, which only vImage reads (after writing it). It is about 5 MB for a 1024 x 1024 image;
    // zeroing it would add about 10% to the blur.
    let temporaryBuffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    defer {
        unsafe temporaryBuffer.deallocate()
    }

    func boxConvolve(source: Span<UInt8>, destination: inout MutableSpan<UInt8>) -> Bool {
        let error = unsafe withVImageBuffers(source: source, geometry, destination: &destination, geometry) { source, destination in
            unsafe vImageBoxConvolve_ARGB8888(&source, &destination, temporaryBuffer, 0, 0, size, size, nil, flags)
        }
        return error == kvImageNoError
    }

    let succeeded =
        boxConvolve(source: image.span, destination: &temporary)
        && boxConvolve(source: temporary.span, destination: &image)
        && boxConvolve(source: image.span, destination: &temporary)
    guard succeeded else {
        return
    }

    let byteCount = image.count
    copyBytes(from: temporary.span, at: 0, to: &image, at: 0, count: byteCount)
}

#endif // ENABLE_WEBCORE_SWIFT && USE_ACCELERATE
