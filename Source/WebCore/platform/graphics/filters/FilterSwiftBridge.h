/*
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) Research In Motion Limited 2010. All rights reserved.
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
 *
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

#include <WebCore/BoxExtents.h>
#include <WebCore/FloatRect.h>
#include <WebCore/FloatSize.h>
#include <WebCore/RenderingMode.h>
#include <optional>
#include <span>
#include <wtf/Compiler.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

// What the Swift code of an effect needs from the Filter that applies it, since Swift doesn't import Filter. Swift builds
// it from the filter's FilterRendererParameters, and the effect's Swift functions use the geometry functions of
// FilterGeometryMath.swift on it in place of the Filter's.
struct FilterApplyContext {
    FloatSize filterScale;
    FloatRect filterRegion;
    // Filter::resolvedSize({ 1, 1 }): the reference box size for objectBoundingBox primitive units, otherwise { 1, 1 }.
    FloatSize resolvedSizeScale;
    // The enclosing filter region scaled by the filter scale; empty without Core Image.
    FloatRect absoluteEnclosingFilterRegion;
    // The filter's rendering modes contain FilterRenderingMode::Accelerated.
    bool accelerated;
    // FilterRenderingOption::FastAndLowQuality and FilterRenderingOption::ShowDebugOverlay.
    bool fastAndLowQuality;
    bool showDebugOverlay;
};

// What a filter lends WebCore's Swift for applying its effects: what its FilterApplyContext is made of
// (filterApplyContextOf(), FilterGeometryMath.swift), its rendering mode, and what resolving objectBoundingBox primitive
// units takes (SVG filters).
struct FilterRendererParameters {
    FloatSize filterScale;
    FloatRect filterRegion;
    FloatRect referenceBox;
    // Filter::enclosingFilterRegion() with Core Image, the filter region otherwise.
    FloatRect enclosingFilterRegion;
    RenderingMode renderingMode;
    bool primitiveUnitsAreObjectBoundingBox;
    bool accelerated;
    bool fastAndLowQuality;
    bool showDebugOverlay;
};

// A color's components in an effect's operating color space (Color::toResolvedColorComponentsInColorSpace()), which C++
// resolves for Swift.
struct FilterColorComponents {
    float red;
    float green;
    float blue;
    float alpha;
};

// The x, y, width and height an SVG filter primitive sets (FilterEffectGeometry), as values for Swift.
struct FilterEffectGeometryValues {
    FloatRect boundaries;
    bool hasGeometry;
    bool hasX;
    bool hasY;
    bool hasWidth;
    bool hasHeight;
};

// The primitive subregion and image rect of a filter style (FilterStyle), which Swift computes for C++.
struct FilterStyleRects {
    FloatRect primitiveSubregion;
    FloatRect imageRect;
};

#if !defined(__swift__)
class Color;
class ColorSpace;
class Filter;
class FilterEffectGeometry;

FilterRendererParameters filterRendererParameters(const Filter&);
FilterColorComponents filterColorComponents(const Color&, const ColorSpace&);
FilterEffectGeometryValues filterEffectGeometryValues(const std::optional<FilterEffectGeometry>&);
#endif

// Rects lent to Swift for one call: the filter regions of a CSS filter's functions.
struct SWIFT_VIEW FilterImageRects {
    std::span<const FloatRect> rects;

    std::span<const FloatRect> span() const LIFETIME_BOUND { return rects; }
};

// IntOutsets (RectEdges<int>) as plain integers, for Swift to return to C++.
struct FilterOutsets {
    int top;
    int right;
    int bottom;
    int left;

#if !defined(__swift__)
    static FilterOutsets fromIntOutsets(const IntOutsets& outsets) { return { outsets.top(), outsets.right(), outsets.bottom(), outsets.left() }; }
    IntOutsets intOutsets() const { return { top, right, bottom, left }; }
#endif
};

// The outsets of a CSS filter's functions, lent to Swift for one call.
struct SWIFT_VIEW FilterOutsetsList {
    std::span<const FilterOutsets> values;

    std::span<const FilterOutsets> span() const LIFETIME_BOUND { return values; }
};

// An SVG filter primitive's outsets and its level (depth) in the filter's primitive graph.
struct FilterOutsetsAtLevel {
    FilterOutsets outsets;
    unsigned level;
};

// The outsets of an SVG filter's primitives in the order its primitive graph visits them, lent to Swift for one call.
struct SWIFT_VIEW FilterOutsetsAtLevels {
    std::span<const FilterOutsetsAtLevel> values;

    std::span<const FilterOutsetsAtLevel> span() const LIFETIME_BOUND { return values; }
};

} // namespace WebCore
