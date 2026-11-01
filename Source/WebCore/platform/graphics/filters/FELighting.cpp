/*
 * Copyright (C) 2010 University of Szeged
 * Copyright (C) 2010 Zoltan Herczeg
 * Copyright (C) 2018-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2014 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY UNIVERSITY OF SZEGED ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL UNIVERSITY OF SZEGED OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"
#include "FELighting.h"

#include "Filter.h"

namespace WebCore {

FELighting::FELighting(Type type, const Color& lightingColor, float surfaceScale, float diffuseConstant, float specularConstant, float specularExponent, float kernelUnitLengthX, float kernelUnitLengthY, Ref<LightSource>&& lightSource, ColorSpace colorSpace)
    : FilterEffect(type, colorSpace)
    , m_parameters({ type == Type::FEDiffuseLighting ? LightingType::Diffuse : LightingType::Specular, surfaceScale, std::max(diffuseConstant, 0.0f), std::max(specularConstant, 0.0f), clampTo<float>(specularExponent, 1.0f, 128.0f), kernelUnitLengthX, kernelUnitLengthY })
    , m_lightingColor(lightingColor)
    , m_lightSource(WTF::move(lightSource))
{
}

bool FELighting::operator==(const FELighting& other) const
{
    return FilterEffect::operator==(other)
        && m_lightingColor == other.m_lightingColor
        && m_parameters == other.m_parameters
        && arePointingToEqualData(m_lightSource, other.m_lightSource);
}

bool FELighting::setSurfaceScale(float surfaceScale)
{
    if (m_parameters.surfaceScale == surfaceScale)
        return false;

    m_parameters.surfaceScale = surfaceScale;
    return true;
}

bool FELighting::setLightingColor(const Color& lightingColor)
{
    if (m_lightingColor == lightingColor)
        return false;

    m_lightingColor = lightingColor;
    return true;
}

bool FELighting::setKernelUnitLengthX(float kernelUnitLengthX)
{
    if (m_parameters.kernelUnitLengthX == kernelUnitLengthX)
        return false;

    m_parameters.kernelUnitLengthX = kernelUnitLengthX;
    return true;
}

bool FELighting::setKernelUnitLengthY(float kernelUnitLengthY)
{
    if (m_parameters.kernelUnitLengthY == kernelUnitLengthY)
        return false;

    m_parameters.kernelUnitLengthY = kernelUnitLengthY;
    return true;
}

OptionSet<FilterRenderingMode> FELighting::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

} // namespace WebCore
