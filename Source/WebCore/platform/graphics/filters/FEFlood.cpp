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
#include "FEFlood.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<FEFlood> FEFlood::create(const Color& floodColor, float floodOpacity, ColorSpace colorSpace)
{
#if USE(CG) || USE(SKIA)
    return adoptRef(*new FEFlood(floodColor, floodOpacity, colorSpace));
#else
    UNUSED_PARAM(colorSpace);
    return adoptRef(*new FEFlood(floodColor, floodOpacity));
#endif
}

FEFlood::FEFlood(const Color& floodColor, float floodOpacity, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEFlood, colorSpace)
    , m_parameters { floodColor, floodOpacity }
{
}

bool FEFlood::operator==(const FEFlood& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

bool FEFlood::setFloodColor(const Color& color)
{
    if (m_parameters.floodColor == color)
        return false;
    m_parameters.floodColor = color;
    return true;
}

bool FEFlood::setFloodOpacity(float floodOpacity)
{
    if (m_parameters.floodOpacity == floodOpacity)
        return false;
    m_parameters.floodOpacity = floodOpacity;
    return true;
}

OptionSet<FilterRenderingMode> FEFlood::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

TextStream& FEFlood::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feFlood"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " flood-color=\"" << floodColor() << '"';
    ts << " flood-opacity=\"" << floodOpacity() << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
