/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) 2010 Renata Hodovan <reni@inf.u-szeged.hu>
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

#pragma once

#include <WebCore/ColorComponents.h>
#include <WebCore/FETurbulenceParameters.h>
#include <WebCore/FilterEffect.h>

namespace WebCore {

class FETurbulence final : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FETurbulence);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FETurbulence);
public:
    WEBCORE_EXPORT static Ref<FETurbulence> create(TurbulenceType, float baseFrequencyX, float baseFrequencyY, int numOctaves, float seed, bool stitchTiles, ColorSpace = ColorSpace::SRGB());

    bool operator==(const FETurbulence&) const;

    TurbulenceType type() const { return m_parameters.type; }
    bool LEGACY_NODELETE setType(TurbulenceType);

    float baseFrequencyX() const { return m_parameters.baseFrequencyX; }
    bool LEGACY_NODELETE setBaseFrequencyX(float);

    float baseFrequencyY() const { return m_parameters.baseFrequencyY; }
    bool LEGACY_NODELETE setBaseFrequencyY(float);

    float seed() const { return m_parameters.seed; }
    bool LEGACY_NODELETE setSeed(float);

    int numOctaves() const { return m_parameters.numOctaves; }
    bool LEGACY_NODELETE setNumOctaves(int);

    bool stitchTiles() const { return m_parameters.stitchTiles; }
    bool LEGACY_NODELETE setStitchTiles(bool);

    const FETurbulenceParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

private:
    FETurbulence(TurbulenceType, float baseFrequencyX, float baseFrequencyY, int numOctaves, float seed, bool stitchTiles, ColorSpace);

    bool operator==(const FilterEffect& other) const override { return areEqual<FETurbulence>(*this, other); }

    unsigned numberOfEffectInputs() const override { return 0; }

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode>) const override;

    WTF::TextStream& externalRepresentation(WTF::TextStream&, FilterRepresentation) const override;

    FETurbulenceParameters m_parameters;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_FILTER_FUNCTION(FETurbulence)
