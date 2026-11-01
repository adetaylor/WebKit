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

#include <WebCore/FEOffsetParameters.h>
#include <WebCore/FilterEffect.h>

namespace WebCore {

class FEOffset final : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FEOffset);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FEOffset);
public:
    WEBCORE_EXPORT static Ref<FEOffset> create(float dx, float dy, ColorSpace = ColorSpace::SRGB());

    bool operator==(const FEOffset&) const;

    float dx() const { return m_parameters.dx; }
    bool LEGACY_NODELETE setDx(float);

    float dy() const { return m_parameters.dy; }
    bool LEGACY_NODELETE setDy(float);

    static IntOutsets calculateOutsets(const FloatSize& offset);

    const FEOffsetParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

private:
    FEOffset(float dx, float dy, ColorSpace);

    bool operator==(const FilterEffect& other) const override { return areEqual<FEOffset>(*this, other); }

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const override;

    WTF::TextStream& externalRepresentation(WTF::TextStream&, FilterRepresentation) const override;

    FEOffsetParameters m_parameters;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_FILTER_FUNCTION(FEOffset)
