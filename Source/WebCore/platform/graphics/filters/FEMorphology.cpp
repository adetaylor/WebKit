/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) Research In Motion Limited 2010. All rights reserved.
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2015 Google Inc. All rights reserved.
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
#include "FEMorphology.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<FEMorphology> FEMorphology::create(MorphologyOperatorType type, float radiusX, float radiusY, ColorSpace colorSpace)
{
    return adoptRef(*new FEMorphology(type, radiusX, radiusY, colorSpace));
}

FEMorphology::FEMorphology(MorphologyOperatorType type, float radiusX, float radiusY, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEMorphology, colorSpace)
    , m_parameters { type, std::max(0.0f, radiusX), std::max(0.0f, radiusY) }
{
}

bool FEMorphology::operator==(const FEMorphology& other) const
{
    return FilterEffect::operator==(other)
        && m_parameters == other.m_parameters;
}

bool FEMorphology::setMorphologyOperator(MorphologyOperatorType type)
{
    if (m_parameters.type == type)
        return false;
    m_parameters.type = type;
    return true;
}

bool FEMorphology::setRadiusX(float radiusX)
{
    radiusX = std::max(0.0f, radiusX);
    if (m_parameters.radiusX == radiusX)
        return false;
    m_parameters.radiusX = radiusX;
    return true;
}

bool FEMorphology::setRadiusY(float radiusY)
{
    radiusY = std::max(0.0f, radiusY);
    if (m_parameters.radiusY == radiusY)
        return false;
    m_parameters.radiusY = radiusY;
    return true;
}

OptionSet<FilterRenderingMode> FEMorphology::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

static TextStream& operator<<(TextStream& ts, const MorphologyOperatorType& type)
{
    switch (type) {
    case MorphologyOperatorType::Unknown:
        ts << "UNKNOWN"_s;
        break;
    case MorphologyOperatorType::Erode:
        ts << "ERODE"_s;
        break;
    case MorphologyOperatorType::Dilate:
        ts << "DILATE"_s;
        break;
    }
    return ts;
}

TextStream& FEMorphology::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feMorphology"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " operator=\""_s << morphologyOperator() << '"';
    ts << " radius=\""_s << radiusX() << ", "_s << radiusY() << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
