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

#include <WebCore/ImageBuffer.h>
#include <WebCore/IntRect.h>
#include <WebCore/PixelBuffer.h>
#include <WebCore/PixelBufferFormat.h>
#include <cstdint>
#include <span>
#include <wtf/Compiler.h>
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {

enum class ColorMatrixType : uint8_t {
    FECOLORMATRIX_TYPE_UNKNOWN          = 0,
    FECOLORMATRIX_TYPE_MATRIX           = 1,
    FECOLORMATRIX_TYPE_SATURATE         = 2,
    FECOLORMATRIX_TYPE_HUEROTATE        = 3,
    FECOLORMATRIX_TYPE_LUMINANCETOALPHA = 4
};

// FEColorMatrix's parameters, which FEColorMatrix stores (its getters and setters are the IPC model) and lends to its
// Swift functions through FEColorMatrixParametersView.
struct FEColorMatrixParameters {
    ColorMatrixType type;
    Vector<float> values;

    bool operator==(const FEColorMatrixParameters&) const = default;
};

// FEColorMatrixParameters lent to Swift for one call: Swift reads the values without copying them, and can't keep them.
class SWIFT_VIEW SWIFT_SAFE FEColorMatrixParametersView {
public:
    explicit FEColorMatrixParametersView(const FEColorMatrixParameters& parameters LIFETIME_BOUND)
        : m_parameters(parameters)
    {
    }

    ColorMatrixType type() const { return m_parameters.type; }
    std::span<const float> valueSpan() const LIFETIME_BOUND { return m_parameters.values.span(); }

private:
    const FEColorMatrixParameters& m_parameters;
};

namespace FEColorMatrixBridge {

// ImageBuffer::getPixelBuffer() with the default allocator, which the software applier reads the result's pixels with:
// the pixel buffer lives only for the apply, unlike the FilterResults allocator's.
inline RefPtr<PixelBuffer> getPixelBuffer(const ImageBuffer& imageBuffer, const PixelBufferFormat& format, const IntRect& sourceRect)
{
    return imageBuffer.getPixelBuffer(format, sourceRect);
}

} // namespace FEColorMatrixBridge

} // namespace WebCore
