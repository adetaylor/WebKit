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

#if ENABLE_WEBCORE_SWIFT

import WebCore_Internal.FloatPoint
import WebCore_Internal.FloatRect
import WebCore_Internal.FloatSize
import WebCore_Internal.GraphicsContextSwiftBridge
import WebCore_Internal.ImageBuffer
import WebCore_Internal.IntRect

// SourceAlphaSoftwareApplier::apply(): the result filled with black, then kept only where the input, drawn at the origin,
// has alpha.
func sourceAlphaApplySoftware(_ input: inout FilterImageImpl, _ result: inout FilterImageImpl) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    guard let inputImage = input.imageBuffer().get() else {
        return false
    }
    let imageRect = WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(result.absoluteImageRect.size()))
    let drawing = WebCore.ImageBufferDrawing(resultImage)
    let context = drawing.context()
    context.fillRect(imageRect, WebCore.GraphicsContextSwiftBridge.blackColor())
    context.drawImageBuffer(inputImage, WebCore.FloatPoint(), .DestinationIn)
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
