/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
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

#include "config.h"
#include "FEColorMatrix.h"

#include "ColorMatrix.h"
#include "Filter.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Ref<FEColorMatrix> FEColorMatrix::create(ColorMatrixType type, Vector<float>&& values, ColorSpace colorSpace)
{
    ASSERT(areValuesValidForType(type, values));
    return adoptRef(*new FEColorMatrix(type, WTF::move(values), colorSpace));
}

Ref<FEColorMatrix> FEColorMatrix::create(ColorMatrixType type, const ColorMatrix<5, 4>& matrix, ColorSpace colorSpace)
{
    return create(type, matrix.data(), colorSpace);
}

FEColorMatrix::FEColorMatrix(ColorMatrixType type, Vector<float>&& values, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEColorMatrix, colorSpace)
    , m_parameters { type, WTF::move(values) }
{
}

bool FEColorMatrix::operator==(const FEColorMatrix& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

bool FEColorMatrix::setType(ColorMatrixType type)
{
    if (m_parameters.type == type)
        return false;
    m_parameters.type = type;
    return true;
}

bool FEColorMatrix::setValues(const Vector<float>& values)
{
    if (m_parameters.values == values)
        return false;
    m_parameters.values = values;
    return true;
}

bool FEColorMatrix::areValuesValidForType(ColorMatrixType type, const Vector<float>& values)
{
    switch (type) {
    case ColorMatrixType::FECOLORMATRIX_TYPE_MATRIX:
        return values.size() == 20;
    case ColorMatrixType::FECOLORMATRIX_TYPE_SATURATE:
    case ColorMatrixType::FECOLORMATRIX_TYPE_HUEROTATE:
        return values.size() == 1;
    case ColorMatrixType::FECOLORMATRIX_TYPE_LUMINANCETOALPHA:
        return true;
    case ColorMatrixType::FECOLORMATRIX_TYPE_UNKNOWN:
        return false;
    }

    ASSERT_NOT_REACHED();
    return false;
}

OptionSet<FilterRenderingMode> FEColorMatrix::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    if (feColorMatrixSupportsCoreImage(FEColorMatrixParametersView { m_parameters }))
        modes.add(FilterRenderingMode::Accelerated);
#endif
#if USE(SKIA)
    modes.add(FilterRenderingMode::Accelerated);
#endif
#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
    if (m_parameters.type == ColorMatrixType::FECOLORMATRIX_TYPE_MATRIX
        || m_parameters.type == ColorMatrixType::FECOLORMATRIX_TYPE_SATURATE
        || m_parameters.type == ColorMatrixType::FECOLORMATRIX_TYPE_HUEROTATE)
        modes.add(FilterRenderingMode::GraphicsContext);
#endif
    return modes & preferredFilterRenderingModes;
}

std::optional<GraphicsStyle> FEColorMatrix::createGraphicsStyle(GraphicsContext&, const Filter&) const
{
    auto& values = m_parameters.values;
    switch (m_parameters.type) {
    case ColorMatrixType::FECOLORMATRIX_TYPE_MATRIX: {
        RELEASE_ASSERT(values.size() == 20);
        GraphicsColorMatrix result;
        std::copy_n(values.begin(), std::min<size_t>(values.size(), 20), result.values.begin());
        return result;
    }
    case ColorMatrixType::FECOLORMATRIX_TYPE_SATURATE:
        return GraphicsColorMatrix { ColorMatrix<5, 4>(saturationColorMatrix(values[0])).data() };

    case ColorMatrixType::FECOLORMATRIX_TYPE_HUEROTATE:
        return GraphicsColorMatrix { ColorMatrix<5, 4>(hueRotateColorMatrix(values[0])).data() };

    default:
        ASSERT_NOT_REACHED();
        break;
    }

    return { };
}

static TextStream& operator<<(TextStream& ts, const ColorMatrixType& type)
{
    switch (type) {
    case ColorMatrixType::FECOLORMATRIX_TYPE_UNKNOWN:
        ts << "UNKNOWN"_s;
        break;
    case ColorMatrixType::FECOLORMATRIX_TYPE_MATRIX:
        ts << "MATRIX"_s;
        break;
    case ColorMatrixType::FECOLORMATRIX_TYPE_SATURATE:
        ts << "SATURATE"_s;
        break;
    case ColorMatrixType::FECOLORMATRIX_TYPE_HUEROTATE:
        ts << "HUEROTATE"_s;
        break;
    case ColorMatrixType::FECOLORMATRIX_TYPE_LUMINANCETOALPHA:
        ts << "LUMINANCETOALPHA"_s;
        break;
    }
    return ts;
}

TextStream& FEColorMatrix::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feColorMatrix"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " type=\"" << m_parameters.type << '"';
    if (!m_parameters.values.isEmpty()) {
        ts << " values=\""_s;
        bool isFirst = true;
        for (auto value : m_parameters.values) {
            if (isFirst)
                isFirst = false;
            else
                ts << ' ';
            ts << value;
        }
        ts << '"';
    }

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
