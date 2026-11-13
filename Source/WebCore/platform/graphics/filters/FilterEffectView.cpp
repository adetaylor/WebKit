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

#include "config.h"
#include "FilterEffectView.h"

#include "FEBlend.h"
#include "FEColorMatrix.h"
#include "FEComponentTransfer.h"
#include "FEComposite.h"
#include "FEConvolveMatrix.h"
#include "FEDisplacementMap.h"
#include "FEDropShadow.h"
#include "FEFlood.h"
#include "FEGaussianBlur.h"
#include "FEImage.h"
#include "FELighting.h"
#include "FEMorphology.h"
#include "FEOffset.h"
#include "FETurbulence.h"
#include "LightSource.h"

namespace WebCore {

#define CHECK_FILTER_EFFECT_TYPE(name) \
    static_assert(static_cast<uint8_t>(FilterEffectType::name) == static_cast<uint8_t>(FilterFunction::Type::name) - static_cast<uint8_t>(FilterFunction::Type::FEBlend));
CHECK_FILTER_EFFECT_TYPE(FEBlend)
CHECK_FILTER_EFFECT_TYPE(FEColorMatrix)
CHECK_FILTER_EFFECT_TYPE(FEComponentTransfer)
CHECK_FILTER_EFFECT_TYPE(FEComposite)
CHECK_FILTER_EFFECT_TYPE(FEConvolveMatrix)
CHECK_FILTER_EFFECT_TYPE(FEDiffuseLighting)
CHECK_FILTER_EFFECT_TYPE(FEDisplacementMap)
CHECK_FILTER_EFFECT_TYPE(FEDropShadow)
CHECK_FILTER_EFFECT_TYPE(FEFlood)
CHECK_FILTER_EFFECT_TYPE(FEGaussianBlur)
CHECK_FILTER_EFFECT_TYPE(FEImage)
CHECK_FILTER_EFFECT_TYPE(FEMerge)
CHECK_FILTER_EFFECT_TYPE(FEMorphology)
CHECK_FILTER_EFFECT_TYPE(FEOffset)
CHECK_FILTER_EFFECT_TYPE(FESpecularLighting)
CHECK_FILTER_EFFECT_TYPE(FETile)
CHECK_FILTER_EFFECT_TYPE(FETurbulence)
CHECK_FILTER_EFFECT_TYPE(SourceAlpha)
CHECK_FILTER_EFFECT_TYPE(SourceGraphic)
#undef CHECK_FILTER_EFFECT_TYPE

FilterEffectView::FilterEffectView(const FilterEffect& effect)
    : m_effect(effect)
{
}

FilterEffectView::FilterEffectView(const FilterEffectView&) = default;

FilterEffectView::~FilterEffectView() = default;

FilterEffectType FilterEffectView::type() const
{
    return static_cast<FilterEffectType>(static_cast<uint8_t>(m_effect->filterType()) - static_cast<uint8_t>(FilterFunction::Type::FEBlend));
}

unsigned FilterEffectView::numberOfImageInputs() const
{
    return m_effect->numberOfImageInputs();
}

ColorSpace FilterEffectView::operatingColorSpace() const
{
    return m_effect->operatingColorSpace();
}

bool FilterEffectView::operatingColorSpaceIsSRGB() const
{
    return m_effect->operatingColorSpace() == ColorSpace::SRGB();
}

FEBlendParameters FilterEffectView::blendParameters() const
{
    return downcast<FEBlend>(m_effect).parameters();
}

FEColorMatrixParametersView FilterEffectView::colorMatrixParameters() const
{
    return FEColorMatrixParametersView { downcast<FEColorMatrix>(m_effect).parameters() };
}

FEComponentTransferParametersView FilterEffectView::componentTransferParameters() const
{
    return FEComponentTransferParametersView { downcast<FEComponentTransfer>(m_effect).parameters() };
}

FECompositeParameters FilterEffectView::compositeParameters() const
{
    return downcast<FEComposite>(m_effect).parameters();
}

FEConvolveMatrixParametersView FilterEffectView::convolveMatrixParameters() const
{
    return FEConvolveMatrixParametersView { downcast<FEConvolveMatrix>(m_effect).parameters() };
}

FEDisplacementMapParameters FilterEffectView::displacementMapParameters() const
{
    return downcast<FEDisplacementMap>(m_effect).parameters();
}

FEDropShadowParameters FilterEffectView::dropShadowParameters() const
{
    return downcast<FEDropShadow>(m_effect).parameters();
}

FilterColorComponents FilterEffectView::dropShadowColor() const
{
    auto& parameters = downcast<FEDropShadow>(m_effect).parameters();
    return filterColorComponents(parameters.shadowColor.colorWithAlphaMultipliedBy(parameters.shadowOpacity), m_effect->operatingColorSpace());
}

FEFloodParameters FilterEffectView::floodParameters() const
{
    return downcast<FEFlood>(m_effect).parameters();
}

FilterColorComponents FilterEffectView::floodColor() const
{
    auto& parameters = downcast<FEFlood>(m_effect).parameters();
    return filterColorComponents(parameters.floodColor.colorWithAlphaMultipliedBy(parameters.floodOpacity), m_effect->operatingColorSpace());
}

FEGaussianBlurParameters FilterEffectView::gaussianBlurParameters() const
{
    return downcast<FEGaussianBlur>(m_effect).parameters();
}

FEImageParameters FilterEffectView::imageParameters() const
{
    return downcast<FEImage>(m_effect).parameters();
}

FEImageSource FilterEffectView::imageSource() const
{
    return FEImageSource { downcast<FEImage>(m_effect).sourceImage() };
}

FELightingParameters FilterEffectView::lightingParameters() const
{
    return downcast<FELighting>(m_effect).parameters();
}

LightSourceParameters FilterEffectView::lightSource() const
{
    return downcast<FELighting>(m_effect).lightSource().parameters();
}

FilterColorComponents FilterEffectView::lightingColor() const
{
    return filterColorComponents(downcast<FELighting>(m_effect).lightingColor(), m_effect->operatingColorSpace());
}

FEMorphologyParameters FilterEffectView::morphologyParameters() const
{
    return downcast<FEMorphology>(m_effect).parameters();
}

FEOffsetParameters FilterEffectView::offsetParameters() const
{
    return downcast<FEOffset>(m_effect).parameters();
}

FETurbulenceParameters FilterEffectView::turbulenceParameters() const
{
    return downcast<FETurbulence>(m_effect).parameters();
}

} // namespace WebCore
