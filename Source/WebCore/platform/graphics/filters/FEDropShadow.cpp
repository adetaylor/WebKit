/*
 * Copyright (C) Research In Motion Limited 2011. All rights reserved.
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
#include "FEDropShadow.h"

#include "FEGaussianBlur.h"
#include "Filter.h"
#include "GraphicsContext.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Ref<FEDropShadow> FEDropShadow::create(float stdX, float stdY, float dx, float dy, const Color& shadowColor, float shadowOpacity, ColorSpace colorSpace)
{
    return adoptRef(*new FEDropShadow(stdX, stdY, dx, dy, shadowColor, shadowOpacity, colorSpace));
}

FEDropShadow::FEDropShadow(float stdX, float stdY, float dx, float dy, const Color& shadowColor, float shadowOpacity, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEDropShadow, colorSpace)
    , m_parameters { stdX, stdY, dx, dy, shadowColor, shadowOpacity }
{
}

bool FEDropShadow::operator==(const FEDropShadow& other) const
{
    return FilterEffect::operator==(other)
        && m_parameters == other.m_parameters;
}

bool FEDropShadow::setStdDeviationX(float stdX)
{
    if (m_parameters.stdDeviationX == stdX)
        return false;
    m_parameters.stdDeviationX = stdX;
    return true;
}

bool FEDropShadow::setStdDeviationY(float stdY)
{
    if (m_parameters.stdDeviationY == stdY)
        return false;
    m_parameters.stdDeviationY = stdY;
    return true;
}

bool FEDropShadow::setDx(float dx)
{
    if (m_parameters.dx == dx)
        return false;
    m_parameters.dx = dx;
    return true;
}

bool FEDropShadow::setDy(float dy)
{
    if (m_parameters.dy == dy)
        return false;
    m_parameters.dy = dy;
    return true;
}

bool FEDropShadow::setShadowColor(const Color& shadowColor)
{
    if (m_parameters.shadowColor == shadowColor)
        return false;
    m_parameters.shadowColor = shadowColor;
    return true;
}

bool FEDropShadow::setShadowOpacity(float shadowOpacity)
{
    if (m_parameters.shadowOpacity == shadowOpacity)
        return false;
    m_parameters.shadowOpacity = shadowOpacity;
    return true;
}

IntOutsets FEDropShadow::calculateOutsets(const FloatSize& offset, const FloatSize& stdDeviation)
{
    return feDropShadowOutsets(offset, stdDeviation).intOutsets();
}

OptionSet<FilterRenderingMode> FEDropShadow::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if (USE(CORE_IMAGE)) || (USE(SKIA))
    modes.add(FilterRenderingMode::Accelerated);
#endif
#if USE(CG) && HAVE(CGSTYLE_FIXES_DROP_SHADOW_BLUR)
    if (m_parameters.stdDeviationX == m_parameters.stdDeviationY)
        modes.add(FilterRenderingMode::GraphicsContext);
#endif
    return modes & preferredFilterRenderingModes;
}

std::optional<GraphicsStyle> FEDropShadow::createGraphicsStyle(GraphicsContext& context, const Filter& filter) const
{
    ASSERT(m_parameters.stdDeviationX == m_parameters.stdDeviationY);

    auto offset = filter.resolvedSize(context.platformShadowOffset({ m_parameters.dx, m_parameters.dy }));
    auto radius = FEGaussianBlur::calculateUnscaledKernelSize(filter.resolvedSize({ m_parameters.stdDeviationX, m_parameters.stdDeviationY }));

    return GraphicsDropShadow { offset, static_cast<float>(radius.width()), m_parameters.shadowColor, ShadowRadiusMode::Default, m_parameters.shadowOpacity };
}

TextStream& FEDropShadow::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feDropShadow"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " stdDeviation=\""_s << m_parameters.stdDeviationX << ", "_s << m_parameters.stdDeviationY << '"';
    ts << " dx=\""_s << m_parameters.dx << "\" dy=\"" << m_parameters.dy << '"';
    ts << " flood-color=\""_s << m_parameters.shadowColor << '"';
    ts << " flood-opacity=\""_s << m_parameters.shadowOpacity << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
