/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) 2010 Renata Hodovan <reni@inf.u-szeged.hu>
 * Copyright (C) 2011 Gabor Loki <loki@webkit.org>
 * Copyright (C) 2017-2026 Apple Inc. All rights reserved.
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
#include "FETurbulence.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<FETurbulence> FETurbulence::create(TurbulenceType type, float baseFrequencyX, float baseFrequencyY, int numOctaves, float seed, bool stitchTiles, ColorSpace colorSpace)
{
    return adoptRef(*new FETurbulence(type, baseFrequencyX, baseFrequencyY, numOctaves, seed, stitchTiles, colorSpace));
}

FETurbulence::FETurbulence(TurbulenceType type, float baseFrequencyX, float baseFrequencyY, int numOctaves, float seed, bool stitchTiles, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FETurbulence, colorSpace)
    , m_parameters { type, baseFrequencyX, baseFrequencyY, numOctaves, seed, stitchTiles }
{
}

bool FETurbulence::operator==(const FETurbulence& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

bool FETurbulence::setType(TurbulenceType type)
{
    if (m_parameters.type == type)
        return false;
    m_parameters.type = type;
    return true;
}

bool FETurbulence::setBaseFrequencyY(float baseFrequencyY)
{
    if (m_parameters.baseFrequencyY == baseFrequencyY)
        return false;
    m_parameters.baseFrequencyY = baseFrequencyY;
    return true;
}

bool FETurbulence::setBaseFrequencyX(float baseFrequencyX)
{
    if (m_parameters.baseFrequencyX == baseFrequencyX)
        return false;
    m_parameters.baseFrequencyX = baseFrequencyX;
    return true;
}

bool FETurbulence::setSeed(float seed)
{
    if (m_parameters.seed == seed)
        return false;
    m_parameters.seed = seed;
    return true;
}

bool FETurbulence::setNumOctaves(int numOctaves)
{
    if (m_parameters.numOctaves == numOctaves)
        return false;
    m_parameters.numOctaves = numOctaves;
    return true;
}

bool FETurbulence::setStitchTiles(bool stitch)
{
    if (m_parameters.stitchTiles == stitch)
        return false;
    m_parameters.stitchTiles = stitch;
    return true;
}

OptionSet<FilterRenderingMode> FETurbulence::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

static TextStream& operator<<(TextStream& ts, TurbulenceType type)
{
    switch (type) {
    case TurbulenceType::Unknown:
        ts << "UNKNOWN"_s;
        break;
    case TurbulenceType::Turbulence:
        ts << "TURBULENCE"_s;
        break;
    case TurbulenceType::FractalNoise:
        ts << "NOISE"_s;
        break;
    }
    return ts;
}

TextStream& FETurbulence::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feTurbulence"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " type=\""_s << type() << '"';
    ts << " baseFrequency=\""_s << baseFrequencyX() << ", "_s << baseFrequencyY() << '"';
    ts << " seed=\""_s << seed() << '"';
    ts << " numOctaves=\""_s << numOctaves() << '"';
    ts << " stitchTiles=\""_s << stitchTiles() << '"';

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
