/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
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

#include <WebCore/FEConvolveMatrixParameters.h>
#include <WebCore/FilterEffect.h>
#include <WebCore/FloatPoint.h>
#include <wtf/Vector.h>

namespace WebCore {

class FEConvolveMatrix final : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FEConvolveMatrix);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FEConvolveMatrix);
public:
    WEBCORE_EXPORT static Ref<FEConvolveMatrix> create(const IntSize& kernelSize, float divisor, float bias, const IntPoint& targetOffset, EdgeModeType, const FloatPoint& kernelUnitLength, bool preserveAlpha, const Vector<float>& kernelMatrix, ColorSpace = ColorSpace::SRGB());

    bool operator==(const FEConvolveMatrix&) const;

    IntSize kernelSize() const { return m_parameters.kernelSize; }
    NODELETE void setKernelSize(const IntSize&);

    const Vector<float>& kernel() const LIFETIME_BOUND { return m_parameters.kernel; }
    void setKernel(const Vector<float>&);

    float divisor() const { return m_parameters.divisor; }
    NODELETE bool setDivisor(float);

    float bias() const { return m_parameters.bias; }
    NODELETE bool setBias(float);

    IntPoint targetOffset() const { return m_parameters.targetOffset; }
    NODELETE bool setTargetOffset(const IntPoint&);

    EdgeModeType edgeMode() const { return m_parameters.edgeMode; }
    NODELETE bool setEdgeMode(EdgeModeType);

    FloatPoint kernelUnitLength() const { return m_parameters.kernelUnitLength; }
    NODELETE bool setKernelUnitLength(const FloatPoint&);

    bool preserveAlpha() const { return m_parameters.preserveAlpha; }
    NODELETE bool setPreserveAlpha(bool);

    const FEConvolveMatrixParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

private:
    FEConvolveMatrix(const IntSize& kernelSize, float divisor, float bias, const IntPoint& targetOffset, EdgeModeType, const FloatPoint& kernelUnitLength, bool preserveAlpha, const Vector<float>& kernelMatrix, ColorSpace);

    bool operator==(const FilterEffect& other) const override { return areEqual<FEConvolveMatrix>(*this, other); }

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode>) const override;

    WTF::TextStream& externalRepresentation(WTF::TextStream&, FilterRepresentation) const override;

    FEConvolveMatrixParameters m_parameters;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_FILTER_FUNCTION(FEConvolveMatrix)
