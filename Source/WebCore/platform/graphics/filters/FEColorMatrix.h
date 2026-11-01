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

#include <WebCore/FEColorMatrixParameters.h>
#include <WebCore/FilterEffect.h>
#include <wtf/Vector.h>

namespace WebCore {

template<size_t, size_t> class ColorMatrix;

class FEColorMatrix final : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FEColorMatrix);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FEColorMatrix);
public:
    WEBCORE_EXPORT static Ref<FEColorMatrix> create(ColorMatrixType, Vector<float>&&, ColorSpace = ColorSpace::SRGB());
    static Ref<FEColorMatrix> create(ColorMatrixType, const ColorMatrix<5, 4>&, ColorSpace = ColorSpace::SRGB());

    bool operator==(const FEColorMatrix&) const;

    ColorMatrixType type() const { return m_parameters.type; }
    NODELETE bool setType(ColorMatrixType);

    const Vector<float>& values() const LIFETIME_BOUND { return m_parameters.values; }
    bool setValues(const Vector<float>&);

    NODELETE WEBCORE_EXPORT static bool areValuesValidForType(ColorMatrixType, const Vector<float>& values);

    const FEColorMatrixParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

private:
    FEColorMatrix(ColorMatrixType, Vector<float>&&, ColorSpace);

    bool operator==(const FilterEffect& other) const override { return areEqual<FEColorMatrix>(*this, other); }

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const override;

    std::optional<GraphicsStyle> createGraphicsStyle(GraphicsContext&, const Filter&) const override;

    WTF::TextStream& externalRepresentation(WTF::TextStream&, FilterRepresentation) const override;

    FEColorMatrixParameters m_parameters;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_FILTER_FUNCTION(FEColorMatrix)
