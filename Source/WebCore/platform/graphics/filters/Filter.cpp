/*
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "Filter.h"

#include "FilterEffect.h"
#include "FilterStyle.h"
#include "FilterSwiftBridge.h"
#include "ImageBuffer.h"

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

Filter::Filter(Filter::Type filterType, std::optional<RenderingResourceIdentifier> renderingResourceIdentifier)
    : FilterFunction(filterType, renderingResourceIdentifier)
{
}

Filter::Filter(Filter::Type filterType, const FilterGeometry& geometry, OptionSet<FilterRenderingOption> renderingOptions, std::optional<RenderingResourceIdentifier> renderingResourceIdentifier)
    : FilterFunction(filterType, renderingResourceIdentifier)
    , m_geometry(geometry)
#if USE(CORE_IMAGE)
    , m_enclosingFilterRegion(geometry.filterRegion)
#endif
    , m_renderingOptions(renderingOptions)
{
}

FloatRect Filter::scaledByFilterScale(const FloatRect& rect) const
{
    auto scaledRect = rect;
    scaledRect.scale(m_geometry.scale);
    return scaledRect;
}

bool Filter::clampFilterRegionIfNeeded()
{
    auto scaledFilterRegion = scaledByFilterScale(m_geometry.filterRegion);

    FloatSize clampingScale(1, 1);
    if (!ImageBuffer::sizeNeedsClamping(scaledFilterRegion.size(), clampingScale))
        return false;

    m_geometry.scale = m_geometry.scale * clampingScale;
    return true;
}

RenderingMode Filter::renderingMode() const
{
    if (m_filterRenderingModes.contains(FilterRenderingMode::Accelerated))
        return RenderingMode::Accelerated;
    
    ASSERT(m_filterRenderingModes.contains(FilterRenderingMode::Software));
    return RenderingMode::Unaccelerated;
}

void Filter::setFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes)
{
    auto modes = supportedFilterRenderingModes(preferredFilterRenderingModes);
    m_filterRenderingModes = OptionSet<FilterRenderingMode>::fromRaw(filterRenderingModesIncludingSoftware(modes.toRaw()));
}

FilterStyleVector Filter::createFilterStyles(GraphicsContext& context, const FloatRect& sourceImageRect) const
{
    auto input = FilterStyle { std::nullopt, m_geometry.filterRegion, sourceImageRect };
    auto result = createFilterStyles(context, input);
    if (result.isEmpty())
        return { };

    result.reverse();
    result.shrinkToFit();
    return result;
}

FilterRendererParameters filterRendererParameters(const Filter& filter)
{
    auto renderingOptions = filter.renderingOptions();
    return {
        .filterScale = filter.filterScale(),
        .filterRegion = filter.filterRegion(),
        .referenceBox = filter.referenceBox(),
#if USE(CORE_IMAGE)
        .enclosingFilterRegion = filter.enclosingFilterRegion(),
#else
        .enclosingFilterRegion = filter.filterRegion(),
#endif
        .renderingMode = filter.renderingMode(),
        .primitiveUnitsAreObjectBoundingBox = filter.primitiveUnitsAreObjectBoundingBox(),
        .accelerated = filter.filterRenderingModes().contains(FilterRenderingMode::Accelerated),
        .fastAndLowQuality = renderingOptions.contains(FilterRenderingOption::FastAndLowQuality),
        .showDebugOverlay = renderingOptions.contains(FilterRenderingOption::ShowDebugOverlay),
    };
}

} // namespace WebCore
