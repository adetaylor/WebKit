/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#pragma once

#include <WebCore/FEConvolveMatrixParameters.h>
#include <WebCore/IntSize.h>
#include <WebCore/PixelBuffer.h>
#include <wtf/RefPtr.h>

namespace WebCore {

// FEGaussianBlur's parameters, which FEGaussianBlur stores (its getters and setters are the IPC model) and passes to its
// Swift functions.
struct FEGaussianBlurParameters {
    float stdDeviationX;
    float stdDeviationY;
    EdgeModeType edgeMode;

    bool operator==(const FEGaussianBlurParameters&) const = default;
};

// What FEGaussianBlur's Swift needs from C++.
namespace FEGaussianBlurBridge {

// PixelBuffer::createScratchPixelBuffer() is pure virtual, which Swift can't call.
inline RefPtr<PixelBuffer> createScratchPixelBuffer(const PixelBuffer& pixelBuffer, const IntSize& size)
{
    return pixelBuffer.createScratchPixelBuffer(size);
}

} // namespace FEGaussianBlurBridge

} // namespace WebCore
