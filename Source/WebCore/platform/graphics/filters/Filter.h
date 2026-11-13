/*
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) 2013 Google Inc. All rights reserved.
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

#include <WebCore/FilterEffectVector.h>
#include <WebCore/FilterFunction.h>
#include <WebCore/FloatPoint3D.h>
#include <WebCore/FloatRect.h>
#include <WebCore/GraphicsTypes.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/RenderingMode.h>

namespace WebCore {

class FilterEffect;
class FilterResults;

struct FilterGeometry {
    FloatRect referenceBox;
    FloatRect filterRegion;
    FloatSize scale;
};

// The result of applying a filter: its image buffer and its rect in user-space coordinates.
struct FilterResult {
    Ref<ImageBuffer> imageBuffer;
    IntRect absoluteImageRect;
};

// Which image buffer Filter::apply() returns. Rendered: with Core Image, the result rendered into a new image buffer.
// Existing: the result's own image buffer, which a Core Image result doesn't have.
enum class FilterResultBuffer : bool { Existing, Rendered };

enum class FilterRenderingOption : uint8_t {
    ShowDebugOverlay    = 1 << 0,
    FastAndLowQuality   = 1 << 1,
    ApplyToSVGRenderer  = 1 << 2,
};

class Filter : public FilterFunction {
    using FilterFunction::createFilterStyles;

public:
    NODELETE RenderingMode renderingMode() const;

    OptionSet<FilterRenderingMode> filterRenderingModes() const { return m_filterRenderingModes; }
    WEBCORE_EXPORT void setFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes);

    OptionSet<FilterRenderingOption> renderingOptions() const { return m_renderingOptions; }
    void setRenderingOptions(OptionSet<FilterRenderingOption> options) { m_renderingOptions = options; }

    const FilterGeometry& geometry() const LIFETIME_BOUND { return m_geometry; }

    FloatSize filterScale() const { return m_geometry.scale; }
    void setFilterScale(const FloatSize& filterScale) { m_geometry.scale = filterScale; }

    FloatRect filterRegion() const { return m_geometry.filterRegion; }
    void setFilterRegion(const FloatRect& filterRegion) { m_geometry.filterRegion = filterRegion; }

    FloatRect referenceBox() const { return m_geometry.referenceBox; }

    virtual FloatSize resolvedSize(const FloatSize& size) const { return size; }
    // An SVG filter whose primitive units are objectBoundingBox.
    virtual bool primitiveUnitsAreObjectBoundingBox() const { return false; }

    NODELETE FloatRect scaledByFilterScale(const FloatRect&) const;

#if USE(CORE_IMAGE)
    // When CSS filter has a mixture of CSS and SVG filters, we need to compute CI filter geometry
    // against a consistent enclosing rect, which we compute as the union of the filter regions
    // of all the filters in the chain.
    FloatRect enclosingFilterRegion() const { return m_enclosingFilterRegion; }
    void setEnclosingFilterRegion(const FloatRect& rect) { m_enclosingFilterRegion = rect; }
#endif

    virtual FilterEffectVector effectsOfType(FilterFunction::Type) const = 0;

    bool clampFilterRegionIfNeeded();

    // Applies the filter to the source image, in WebCore's Swift (FilterEngine.swift). Nullopt if the filter fails or its
    // result has no image buffer.
    virtual std::optional<FilterResult> apply(ImageBuffer* sourceImage, const FloatRect& sourceImageRect, FilterResults&, FilterResultBuffer) = 0;
    WEBCORE_EXPORT FilterStyleVector createFilterStyles(GraphicsContext&, const FloatRect& sourceImageRect) const;

protected:
    Filter(Filter::Type, std::optional<RenderingResourceIdentifier> = std::nullopt);
    Filter(Filter::Type, const FilterGeometry&, OptionSet<FilterRenderingOption> = { }, std::optional<RenderingResourceIdentifier> = std::nullopt);

    virtual FilterStyleVector createFilterStyles(GraphicsContext&, const FilterStyle& sourceStyle) const = 0;

private:
    FilterGeometry m_geometry;
#if USE(CORE_IMAGE)
    FloatRect m_enclosingFilterRegion;
#endif
    OptionSet<FilterRenderingMode> m_filterRenderingModes { FilterRenderingMode::Software };
    OptionSet<FilterRenderingOption> m_renderingOptions;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::Filter)
    static bool isType(const WebCore::RenderingResource& renderingResource) { return renderingResource.isFilter(); }
SPECIALIZE_TYPE_TRAITS_END()
