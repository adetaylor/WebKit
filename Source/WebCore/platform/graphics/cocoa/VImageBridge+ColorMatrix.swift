// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

// FEColorMatrixSoftwareApplier::applyPlatformAccelerated()'s vImageMatrixMultiply_ARGB8888(): multiplies each pixel of
// the width x height image packed in `pixels` by `matrix` (4 x 4, column by column) divided by `divisor`, in place. As
// in C++, the vImage result is ignored. An image vImage can't take (empty, or more pixels than `pixels` holds) is left
// as it is.
func vImageColorMatrixMultiply(_ pixels: inout MutableSpan<UInt8>, width: Int, height: Int, matrix: SIMD16<Int16>, divisor: Int32) {
    guard let rowBytes = width.checkedMultiplied(by: 4),
        let geometry = VImageGeometry(width: width, height: height, rowBytes: rowBytes, bytesPerPixel: 4, byteCount: pixels.count)
    else {
        return
    }
    var matrix = matrix
    _ = unsafe withVImageBuffers(source: nil, geometry, destination: &pixels, geometry) { source, destination in
        withUnsafeBytes(of: &matrix) { matrixBytes in
            unsafe vImageMatrixMultiply_ARGB8888(
                &source,
                &destination,
                matrixBytes.assumingMemoryBound(to: Int16.self).baseAddress.unsafelyUnwrapped,
                divisor,
                nil,
                nil,
                vImage_Flags(kvImageNoFlags)
            )
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT && USE_ACCELERATE
