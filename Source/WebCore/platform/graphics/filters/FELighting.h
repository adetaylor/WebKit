/*
 * Copyright (C) 2010 University of Szeged
 * Copyright (C) 2010 Zoltan Herczeg
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

#pragma once

#include <WebCore/Color.h>
#include <WebCore/DistantLightSource.h>
#include <WebCore/FELightingParameters.h>
#include <WebCore/FilterEffect.h>
#include <WebCore/PointLightSource.h>
#include <WebCore/SpotLightSource.h>

namespace WebCore {

class FELighting : public FilterEffect {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(FELighting);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(FELighting);
public:
    bool operator==(const FELighting&) const;

    const Color& lightingColor() const LIFETIME_BOUND { return m_lightingColor; }
    bool setLightingColor(const Color&);

    float surfaceScale() const { return m_parameters.surfaceScale; }
    bool LEGACY_NODELETE setSurfaceScale(float);

    float diffuseConstant() const { return m_parameters.diffuseConstant; }
    float specularConstant() const { return m_parameters.specularConstant; }
    float specularExponent() const { return m_parameters.specularExponent; }

    float kernelUnitLengthX() const { return m_parameters.kernelUnitLengthX; }
    bool LEGACY_NODELETE setKernelUnitLengthX(float);

    float kernelUnitLengthY() const { return m_parameters.kernelUnitLengthY; }
    bool LEGACY_NODELETE setKernelUnitLengthY(float);

    LightSource& lightSource() const { return m_lightSource; }

    const FELightingParameters& parameters() const LIFETIME_BOUND { return m_parameters; }

protected:
    FELighting(Type, const Color& lightingColor, float surfaceScale, float diffuseConstant, float specularConstant, float specularExponent, float kernelUnitLengthX, float kernelUnitLengthY, Ref<LightSource>&&, ColorSpace);

    using FilterEffect::operator==;

    OptionSet<FilterRenderingMode> supportedFilterRenderingModes(OptionSet<FilterRenderingMode>) const override;

    // m_parameters first: it fits in FilterEffect's tail padding, which keeps FELighting from growing into a larger
    // size class.
    FELightingParameters m_parameters;
    Color m_lightingColor;
    const Ref<LightSource> m_lightSource;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::FELighting)
    static bool isType(const WebCore::FilterFunction& function) { return function.filterType() == WebCore::FilterFunction::Type::FEDiffuseLighting || function.filterType() == WebCore::FilterFunction::Type::FESpecularLighting; }
SPECIALIZE_TYPE_TRAITS_END()
