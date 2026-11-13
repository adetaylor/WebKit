// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
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

#if ENABLE_WEBCORE_SWIFT

import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect

// FEMergeSoftwareApplier::apply(), which FEMerge runs input by input: feMergeBeginSoftware() fails if the result has no
// image buffer, then feMergeAddSoftwareInput() draws each input that has one over the result.
func feMergeBeginSoftware(_ result: inout FilterImageImpl) -> Bool {
    result.imageBuffer().get() != nil
}

func feMergeAddSoftwareInput(_ input: inout FilterImageImpl, _ result: inout FilterImageImpl) {
    guard let resultImage = result.imageBuffer().get(), let inputImage = input.imageBuffer().get() else {
        return
    }
    filterDrawImageBuffer(resultImage, inputImage, input.absoluteImageRect(relativeTo: result))
}

#endif // ENABLE_WEBCORE_SWIFT
