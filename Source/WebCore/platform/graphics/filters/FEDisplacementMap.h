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

#include <WebCore/FEDisplacementMapParameters.h>
#include <WebCore/FilterEffect.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class FEDisplacementMap final : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FEDisplacementMap);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FEDisplacementMap);
public:
    WEBCORE_EXPORT static Ref<FEDisplacementMap> create(ChannelSelectorType xChannelSelector, ChannelSelectorType yChannelSelector, float scale, ColorSpace = ColorSpace::SRGB(), bool in2IsTainted = false);

    bool operator==(const FEDisplacementMap&) const;

    ChannelSelectorType xChannelSelector() const { return m_parameters.xChannelSelector; }
    bool LEGACY_NODELETE setXChannelSelector(const ChannelSelectorType);

    ChannelSelectorType yChannelSelector() const { return m_parameters.yChannelSelector; }
    bool LEGACY_NODELETE setYChannelSelector(const ChannelSelectorType);

    float scale() const { return m_parameters.scale; }
    bool LEGACY_NODELETE setScale(float);

    // §16.4: when in2 is tainted, this primitive becomes a pass-through of in.
    bool in2IsTainted() const { return m_parameters.in2IsTainted; }
    void setIn2IsTainted(bool tainted) { m_parameters.in2IsTainted = tainted; }

    static IntOutsets calculateOutsets(const FloatSize& maxDisplacement);

    const FEDisplacementMapParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

private:
    FEDisplacementMap(ChannelSelectorType xChannelSelector, ChannelSelectorType yChannelSelector, float, ColorSpace);

    bool operator==(const FilterEffect& other) const override { return areEqual<FEDisplacementMap>(*this, other); }

    unsigned numberOfEffectInputs() const override { return 2; }

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode>) const override;

    WTF::TextStream& externalRepresentation(WTF::TextStream&, FilterRepresentation) const override;

    FEDisplacementMapParameters m_parameters;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_FILTER_FUNCTION(FEDisplacementMap)
