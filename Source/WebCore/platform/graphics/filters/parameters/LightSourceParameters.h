/*
 * Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2014 Google Inc. All rights reserved.
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

#include <WebCore/FloatPoint3D.h>
#include <cstdint>

namespace WebCore {

enum class LightType : uint8_t {
    Distant,
    Point,
    Spot
};

// A light source's parameters, which LightSource stores (the getters and setters of its subclasses are the IPC model).
// WebCore's Swift resolves their positions for the filter (resolvedLightSourceParameters(), LightingModel.swift).
struct LightSourceParameters {
    LightType type;
    // DistantLightSource, in degrees.
    float azimuth { 0 };
    float elevation { 0 };
    // PointLightSource and SpotLightSource, in user space coordinates.
    FloatPoint3D position;
    // SpotLightSource.
    FloatPoint3D pointsAt;
    float specularExponent { 1 };
    float limitingConeAngle { 0 };

    bool operator==(const LightSourceParameters&) const = default;
};

} // namespace WebCore
