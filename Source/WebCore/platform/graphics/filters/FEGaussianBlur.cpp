/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) 2010 Igalia, S.L.
 * Copyright (C) Research In Motion Limited 2010. All rights reserved.
 * Copyright (C) 2015-2026 Apple, Inc. All rights reserved.
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
#include "FEGaussianBlur.h"

#include "Filter.h"
#include "GraphicsContext.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Ref<FEGaussianBlur> FEGaussianBlur::create(float x, float y, EdgeModeType edgeMode, ColorSpace colorSpace)
{
    return adoptRef(*new FEGaussianBlur(x, y, edgeMode, colorSpace));
}

FEGaussianBlur::FEGaussianBlur(float x, float y, EdgeModeType edgeMode, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEGaussianBlur, colorSpace)
    , m_parameters { x, y, edgeMode }
{
}

bool FEGaussianBlur::operator==(const FEGaussianBlur& other) const
{
    return FilterEffect::operator==(other)
        && m_parameters == other.m_parameters;
}

bool FEGaussianBlur::setStdDeviationX(float stdX)
{
    if (m_parameters.stdDeviationX == stdX)
        return false;
    m_parameters.stdDeviationX = stdX;
    return true;
}

bool FEGaussianBlur::setStdDeviationY(float stdY)
{
    if (m_parameters.stdDeviationY == stdY)
        return false;
    m_parameters.stdDeviationY = stdY;
    return true;
}

bool FEGaussianBlur::setEdgeMode(EdgeModeType edgeMode)
{
    if (m_parameters.edgeMode == edgeMode)
        return false;
    m_parameters.edgeMode = edgeMode;
    return true;
}

FloatSize FEGaussianBlur::effectiveStdDeviation(OptionSet<FilterRenderingOption> renderingOptions) const
{
    return feGaussianBlurEffectiveStdDeviation(m_parameters, renderingOptions.contains(FilterRenderingOption::FastAndLowQuality));
}

IntSize FEGaussianBlur::calculateUnscaledKernelSize(FloatSize stdDeviation)
{
    return feGaussianBlurUnscaledKernelSize(stdDeviation);
}

IntSize FEGaussianBlur::calculateOutsetSize(FloatSize stdDeviation)
{
    return feGaussianBlurOutsetSize(stdDeviation);
}

IntOutsets FEGaussianBlur::calculateOutsets(const FloatSize& stdDeviation)
{
    return feGaussianBlurOutsets(stdDeviation).intOutsets();
}

OptionSet<FilterRenderingMode> FEGaussianBlur::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#elif USE(SKIA)
    if (m_parameters.edgeMode == EdgeModeType::None)
        modes.add(FilterRenderingMode::Accelerated);
#endif
#if HAVE(CGSTYLE_COLORMATRIX_BLUR) && HAVE(CGSTYLE_FIXES_DROP_SHADOW_BLUR)
    if (m_parameters.stdDeviationX == m_parameters.stdDeviationY)
        modes.add(FilterRenderingMode::GraphicsContext);
#endif
    return modes & preferredFilterRenderingModes;
}

std::optional<GraphicsStyle> FEGaussianBlur::createGraphicsStyle(GraphicsContext&, const Filter& filter) const
{
    auto stdDeviation = effectiveStdDeviation(filter.renderingOptions());
    auto radius = calculateUnscaledKernelSize(filter.resolvedSize(stdDeviation));
    return GraphicsGaussianBlur { radius };
}

TextStream& FEGaussianBlur::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feGaussianBlur"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " stdDeviation=\""_s << m_parameters.stdDeviationX << ", "_s << m_parameters.stdDeviationY << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
