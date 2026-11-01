/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
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

#include "config.h"
#include "FEConvolveMatrix.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Ref<FEConvolveMatrix> FEConvolveMatrix::create(const IntSize& kernelSize, float divisor, float bias, const IntPoint& targetOffset, EdgeModeType edgeMode, const FloatPoint& kernelUnitLength, bool preserveAlpha, const Vector<float>& kernelMatrix, ColorSpace colorSpace)
{
    return adoptRef(*new FEConvolveMatrix(kernelSize, divisor, bias, targetOffset, edgeMode, kernelUnitLength, preserveAlpha, kernelMatrix, colorSpace));
}

FEConvolveMatrix::FEConvolveMatrix(const IntSize& kernelSize, float divisor, float bias, const IntPoint& targetOffset, EdgeModeType edgeMode, const FloatPoint& kernelUnitLength, bool preserveAlpha, const Vector<float>& kernelMatrix, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEConvolveMatrix, colorSpace)
    , m_parameters { kernelSize, divisor, bias, targetOffset, edgeMode, kernelUnitLength, preserveAlpha, kernelMatrix }
{
    ASSERT(m_parameters.kernelSize.width() > 0);
    ASSERT(m_parameters.kernelSize.height() > 0);
    ASSERT(IntRect(IntPoint::zero(), kernelSize).contains(targetOffset));
}

bool FEConvolveMatrix::operator==(const FEConvolveMatrix& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

void FEConvolveMatrix::setKernelSize(const IntSize& kernelSize)
{
    ASSERT(kernelSize.width() > 0);
    ASSERT(kernelSize.height() > 0);
    m_parameters.kernelSize = kernelSize;
}

void FEConvolveMatrix::setKernel(const Vector<float>& kernel)
{
    m_parameters.kernel = kernel;
}

bool FEConvolveMatrix::setDivisor(float divisor)
{
    ASSERT(divisor);
    if (m_parameters.divisor == divisor)
        return false;
    m_parameters.divisor = divisor;
    return true;
}

bool FEConvolveMatrix::setBias(float bias)
{
    if (m_parameters.bias == bias)
        return false;
    m_parameters.bias = bias;
    return true;
}

bool FEConvolveMatrix::setTargetOffset(const IntPoint& targetOffset)
{
    if (m_parameters.targetOffset == targetOffset)
        return false;
    m_parameters.targetOffset = targetOffset;
    return true;
}

bool FEConvolveMatrix::setEdgeMode(EdgeModeType edgeMode)
{
    if (m_parameters.edgeMode == edgeMode)
        return false;
    m_parameters.edgeMode = edgeMode;
    return true;
}

bool FEConvolveMatrix::setKernelUnitLength(const FloatPoint& kernelUnitLength)
{
    ASSERT(kernelUnitLength.x() > 0);
    ASSERT(kernelUnitLength.y() > 0);
    if (m_parameters.kernelUnitLength == kernelUnitLength)
        return false;
    m_parameters.kernelUnitLength = kernelUnitLength;
    return true;
}

bool FEConvolveMatrix::setPreserveAlpha(bool preserveAlpha)
{
    if (m_parameters.preserveAlpha == preserveAlpha)
        return false;
    m_parameters.preserveAlpha = preserveAlpha;
    return true;
}

OptionSet<FilterRenderingMode> FEConvolveMatrix::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    if (feConvolveMatrixSupportsCoreImage(FEConvolveMatrixParametersView { m_parameters }))
        modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

static TextStream& operator<<(TextStream& ts, const EdgeModeType& type)
{
    switch (type) {
    case EdgeModeType::Unknown:
        ts << "UNKNOWN"_s;
        break;
    case EdgeModeType::Duplicate:
        ts << "DUPLICATE"_s;
        break;
    case EdgeModeType::Wrap:
        ts << "WRAP"_s;
        break;
    case EdgeModeType::None:
        ts << "NONE"_s;
        break;
    }
    return ts;
}

TextStream& FEConvolveMatrix::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feConvolveMatrix"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " order=\"" << m_parameters.kernelSize << '"';
    ts << " kernelMatrix=\"" << m_parameters.kernel << '"';
    ts << " divisor=\"" << m_parameters.divisor << '"';
    ts << " bias=\"" << m_parameters.bias << '"';
    ts << " target=\"" << m_parameters.targetOffset << '"';
    ts << " edgeMode=\"" << m_parameters.edgeMode << '"';
    ts << " kernelUnitLength=\"" << m_parameters.kernelUnitLength << '"';
    ts << " preserveAlpha=\"" << m_parameters.preserveAlpha << '"';

    ts << "]\n"_s;
    return ts;
}

}; // namespace WebCore
