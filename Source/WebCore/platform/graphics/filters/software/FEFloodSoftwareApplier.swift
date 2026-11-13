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

#if ENABLE_WEBCORE_SWIFT

import WebCore_Private.Core.FEFloodParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect

// FEFloodSoftwareApplier::apply(): the result filled with the flood color, its alpha multiplied by the flood opacity.
func feFloodApplySoftware(_ parameters: borrowing WebCore.FEFloodParameters, _ result: inout FilterImageImpl) -> Bool {
    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    let rect = WebCore.FloatRect(WebCore.FloatPoint(), WebCore.FloatSize(result.absoluteImageRect.size()))
    let color = parameters.floodColor.colorWithAlphaMultipliedBy(parameters.floodOpacity)
    let drawing = WebCore.ImageBufferDrawing(resultImage)
    drawing.context().fillRect(rect, color)
    return true
}

#endif // ENABLE_WEBCORE_SWIFT
