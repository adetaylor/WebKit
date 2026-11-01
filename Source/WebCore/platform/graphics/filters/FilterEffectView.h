/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/ColorSpace.h>
#include <WebCore/FEBlendParameters.h>
#include <WebCore/FEColorMatrixParameters.h>
#include <WebCore/FEComponentTransferParameters.h>
#include <WebCore/FECompositeParameters.h>
#include <WebCore/FEConvolveMatrixParameters.h>
#include <WebCore/FEDisplacementMapParameters.h>
#include <WebCore/FEDropShadowParameters.h>
#include <WebCore/FEFloodParameters.h>
#include <WebCore/FEGaussianBlurParameters.h>
#include <WebCore/FEImageParameters.h>
#include <WebCore/FELightingParameters.h>
#include <WebCore/FEMorphologyParameters.h>
#include <WebCore/FEOffsetParameters.h>
#include <WebCore/FETurbulenceParameters.h>
#include <WebCore/FilterSwiftBridge.h>
#include <WebCore/LightSourceParameters.h>
#include <cstdint>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

class FilterEffect;

// FilterFunction::Type's effect types, which FilterEffectView.cpp checks against it.
enum class FilterEffectType : uint8_t {
    FEBlend,
    FEColorMatrix,
    FEComponentTransfer,
    FEComposite,
    FEConvolveMatrix,
    FEDiffuseLighting,
    FEDisplacementMap,
    FEDropShadow,
    FEFlood,
    FEGaussianBlur,
    FEImage,
    FEMerge,
    FEMorphology,
    FEOffset,
    FESpecularLighting,
    FETile,
    FETurbulence,
    SourceAlpha,
    SourceGraphic
};

// A FilterEffect lent to WebCore's Swift for one apply: what Swift needs to apply it. Swift can't keep it. A parameter
// member crashes for an effect of another type.
class SWIFT_VIEW SWIFT_SAFE FilterEffectView {
public:
#if !defined(__swift__)
    explicit FilterEffectView(const FilterEffect&);
#endif
    FilterEffectView(const FilterEffectView&);
    ~FilterEffectView();

    FilterEffectType type() const;
    unsigned numberOfImageInputs() const;
    ColorSpace operatingColorSpace() const;
    bool operatingColorSpaceIsSRGB() const;

    FEBlendParameters blendParameters() const;
    FEColorMatrixParametersView colorMatrixParameters() const LIFETIME_BOUND;
    FEComponentTransferParametersView componentTransferParameters() const LIFETIME_BOUND;
    FECompositeParameters compositeParameters() const;
    FEConvolveMatrixParametersView convolveMatrixParameters() const LIFETIME_BOUND;
    FEDisplacementMapParameters displacementMapParameters() const;
    FEDropShadowParameters dropShadowParameters() const;
    // The shadow color with its opacity, in the operating color space.
    FilterColorComponents dropShadowColor() const;
    FEFloodParameters floodParameters() const;
    // The flood color with its opacity, in the operating color space.
    FilterColorComponents floodColor() const;
    FEGaussianBlurParameters gaussianBlurParameters() const;
    FEImageParameters imageParameters() const;
    FEImageSource imageSource() const LIFETIME_BOUND;
    // FEDiffuseLighting and FESpecularLighting.
    FELightingParameters lightingParameters() const;
    // The light source, its positions in primitive units.
    LightSourceParameters lightSource() const;
    // The lighting color in the operating color space.
    FilterColorComponents lightingColor() const;
    FEMorphologyParameters morphologyParameters() const;
    FEOffsetParameters offsetParameters() const;
    FETurbulenceParameters turbulenceParameters() const;

private:
    const Ref<const FilterEffect> m_effect;
};

} // namespace WebCore
