/*
 * Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) Research In Motion Limited 2010. All rights reserved.
 * Copyright (C) 2012 University of Szeged
 * Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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
#include "FilterEffect.h"

#include "Color.h"
#include "Filter.h"
#include "FilterEffectGeometry.h"
#include "FilterEffectView.h"
#include "FilterSwiftBridge.h"
#include <wtf/text/TextStream.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

FilterEffect::FilterEffect(Type type, ColorSpace colorSpace, std::optional<RenderingResourceIdentifier> renderingResourceIdentifier)
    : FilterFunction(type, renderingResourceIdentifier)
    , m_operatingColorSpace(colorSpace)
{
}

bool FilterEffect::operator==(const FilterEffect& other) const
{
    if (filterType() != other.filterType())
        return false;
    return m_operatingColorSpace == other.m_operatingColorSpace;
}

FilterStyleVector FilterEffect::createFilterStyles(GraphicsContext& context, const Filter& filter, const FilterStyle& input) const
{
    return { createFilterStyle(context, filter, input) };
}

FilterStyle FilterEffect::createFilterStyle(GraphicsContext& context, const Filter& filter, const FilterStyle& input, const std::optional<FilterEffectGeometry>& geometry) const
{
    ASSERT(filter.filterRenderingModes().contains(FilterRenderingMode::GraphicsContext));

    auto rects = filterEffectStyleRects(FilterEffectView { *this }, filterRendererParameters(filter), input.primitiveSubregion, input.imageRect, filterEffectGeometryValues(geometry));

    auto style = createGraphicsStyle(context, filter);
    return FilterStyle { style, rects.primitiveSubregion, rects.imageRect };
}

FilterColorComponents filterColorComponents(const Color& color, const ColorSpace& colorSpace)
{
    auto [red, green, blue, alpha] = color.toResolvedColorComponentsInColorSpace(colorSpace);
    return { red, green, blue, alpha };
}

FilterEffectGeometryValues filterEffectGeometryValues(const std::optional<FilterEffectGeometry>& geometry)
{
    if (!geometry)
        return { };
    return {
        .boundaries = { geometry->x().value_or(0), geometry->y().value_or(0), geometry->width().value_or(0), geometry->height().value_or(0) },
        .hasGeometry = true,
        .hasX = !!geometry->x(),
        .hasY = !!geometry->y(),
        .hasWidth = !!geometry->width(),
        .hasHeight = !!geometry->height(),
    };
}

TextStream& FilterEffect::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    // FIXME: We should dump the subRegions of the filter primitives here later. This isn't
    // possible at the moment, because we need more detailed informations from the target object.
    
    if (representation == FilterRepresentation::Debugging) {
        TextStream::IndentScope indentScope(ts);
        ts.dumpProperty("operating colorspace"_s, operatingColorSpace());
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, const FilterEffect& effect)
{
    // Use a new stream because we want multiline mode for logging filters.
    TextStream filterStream;
    effect.externalRepresentation(filterStream, FilterRepresentation::Debugging);
    
    return ts << filterStream.release();
}

} // namespace WebCore
