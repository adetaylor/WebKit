/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) Research In Motion Limited 2010. All rights reserved.
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
#include "FEDisplacementMap.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Ref<FEDisplacementMap> FEDisplacementMap::create(ChannelSelectorType xChannelSelector, ChannelSelectorType yChannelSelector, float scale, ColorSpace colorSpace, bool in2IsTainted)
{
    Ref<FEDisplacementMap> effect = adoptRef(*new FEDisplacementMap(xChannelSelector, yChannelSelector, scale, colorSpace));
    effect->m_parameters.in2IsTainted = in2IsTainted;
    return effect;
}

FEDisplacementMap::FEDisplacementMap(ChannelSelectorType xChannelSelector, ChannelSelectorType yChannelSelector, float scale, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEDisplacementMap, colorSpace)
    , m_parameters { xChannelSelector, yChannelSelector, scale, false }
{
}

bool FEDisplacementMap::operator==(const FEDisplacementMap& other) const
{
    return FilterEffect::operator==(other)
        && m_parameters == other.m_parameters;
}

bool FEDisplacementMap::setXChannelSelector(const ChannelSelectorType xChannelSelector)
{
    if (m_parameters.xChannelSelector == xChannelSelector)
        return false;
    m_parameters.xChannelSelector = xChannelSelector;
    return true;
}

bool FEDisplacementMap::setYChannelSelector(const ChannelSelectorType yChannelSelector)
{
    if (m_parameters.yChannelSelector == yChannelSelector)
        return false;
    m_parameters.yChannelSelector = yChannelSelector;
    return true;
}

bool FEDisplacementMap::setScale(float scale)
{
    if (m_parameters.scale == scale)
        return false;
    m_parameters.scale = scale;
    return true;
}

IntOutsets FEDisplacementMap::calculateOutsets(const FloatSize& maxDisplacement)
{
    return feDisplacementMapOutsets(maxDisplacement).intOutsets();
}

OptionSet<FilterRenderingMode> FEDisplacementMap::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

static TextStream& operator<<(TextStream& ts, const ChannelSelectorType& type)
{
    switch (type) {
    case ChannelSelectorType::CHANNEL_UNKNOWN:
        ts << "UNKNOWN"_s;
        break;
    case ChannelSelectorType::CHANNEL_R:
        ts << "RED"_s;
        break;
    case ChannelSelectorType::CHANNEL_G:
        ts << "GREEN"_s;
        break;
    case ChannelSelectorType::CHANNEL_B:
        ts << "BLUE"_s;
        break;
    case ChannelSelectorType::CHANNEL_A:
        ts << "ALPHA"_s;
        break;
    }
    return ts;
}

TextStream& FEDisplacementMap::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feDisplacementMap"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " scale=\"" << m_parameters.scale << '"';
    ts << " xChannelSelector=\"" << m_parameters.xChannelSelector << '"';
    ts << " yChannelSelector=\"" << m_parameters.yChannelSelector << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
