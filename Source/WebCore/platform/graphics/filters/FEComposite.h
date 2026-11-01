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

#include <WebCore/FECompositeParameters.h>
#include <WebCore/FilterEffect.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class FEComposite final : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FEComposite);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FEComposite);
public:
    WEBCORE_EXPORT static Ref<FEComposite> create(const CompositeOperationType&, float k1, float k2, float k3, float k4, ColorSpace = ColorSpace::SRGB());

    bool operator==(const FEComposite&) const;

    CompositeOperationType operation() const { return m_parameters.operation; }
    bool LEGACY_NODELETE setOperation(CompositeOperationType);

    float k1() const { return m_parameters.k1; }
    bool LEGACY_NODELETE setK1(float);

    float k2() const { return m_parameters.k2; }
    bool LEGACY_NODELETE setK2(float);

    float k3() const { return m_parameters.k3; }
    bool LEGACY_NODELETE setK3(float);

    float k4() const { return m_parameters.k4; }
    bool LEGACY_NODELETE setK4(float);

    const FECompositeParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

private:
    FEComposite(const CompositeOperationType&, float k1, float k2, float k3, float k4, ColorSpace);

    bool operator==(const FilterEffect& other) const override { return areEqual<FEComposite>(*this, other); }

    unsigned numberOfEffectInputs() const override { return 2; }

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode>) const override;

    WTF::TextStream& externalRepresentation(WTF::TextStream&, FilterRepresentation) const override;

    FECompositeParameters m_parameters;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_FILTER_FUNCTION(FEComposite)
