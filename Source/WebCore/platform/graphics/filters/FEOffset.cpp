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
#include "FEOffset.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Ref<FEOffset> FEOffset::create(float dx, float dy, ColorSpace colorSpace)
{
    return adoptRef(*new FEOffset(dx, dy, colorSpace));
}

FEOffset::FEOffset(float dx, float dy, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEOffset, colorSpace)
    , m_parameters { dx, dy }
{
}

bool FEOffset::operator==(const FEOffset& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

bool FEOffset::setDx(float dx)
{
    if (m_parameters.dx == dx)
        return false;
    m_parameters.dx = dx;
    return true;
}

bool FEOffset::setDy(float dy)
{
    if (m_parameters.dy == dy)
        return false;
    m_parameters.dy = dy;
    return true;
}

IntOutsets FEOffset::calculateOutsets(const FloatSize& offset)
{
    return feOffsetOutsets(offset).intOutsets();
}

OptionSet<FilterRenderingMode> FEOffset::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

TextStream& FEOffset::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feOffset"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " dx=\""_s << dx() << "\" dy=\""_s << dy() << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
