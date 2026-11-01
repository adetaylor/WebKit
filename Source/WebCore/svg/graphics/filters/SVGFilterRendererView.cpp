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
#include "SVGFilterRendererView.h"

#include "SVGFilterRenderer.h"

namespace WebCore {

SVGFilterRendererView::SVGFilterRendererView(const SVGFilterRenderer& renderer)
    : m_renderer(renderer)
{
    ASSERT(!renderer.expression().isEmpty());
    ASSERT(renderer.filterRenderingModes().contains(FilterRenderingMode::Software));
    ASSERT(SVGFilterRenderer::isValidSVGFilterExpression(renderer.expression(), renderer.effects()));
}

SVGFilterRendererView::SVGFilterRendererView(const SVGFilterRendererView&) = default;

SVGFilterRendererView::~SVGFilterRendererView() = default;

uintptr_t SVGFilterRendererView::identifier() const
{
    return reinterpret_cast<uintptr_t>(static_cast<const Filter*>(m_renderer.ptr()));
}

FilterRendererParameters SVGFilterRendererView::parameters() const
{
    return filterRendererParameters(m_renderer.get());
}

FilterEffectView SVGFilterRendererView::effect(unsigned index) const
{
    return FilterEffectView { m_renderer->effects()[index] };
}

unsigned SVGFilterRendererView::termCount() const
{
    return m_renderer->expression().size();
}

unsigned SVGFilterRendererView::termEffectIndex(unsigned term) const
{
    return m_renderer->expression()[term].index;
}

FilterEffectGeometryValues SVGFilterRendererView::termGeometry(unsigned term) const
{
    return filterEffectGeometryValues(m_renderer->expression()[term].geometry);
}

} // namespace WebCore
