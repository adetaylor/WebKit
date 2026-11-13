/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
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

#include <cstdint>

namespace WebCore {

enum class ChannelSelectorType : uint8_t {
    CHANNEL_UNKNOWN = 0,
    CHANNEL_R = 1,
    CHANNEL_G = 2,
    CHANNEL_B = 3,
    CHANNEL_A = 4
};

// FEDisplacementMap's parameters, which FEDisplacementMap stores (its getters and setters are the IPC model) and passes
// to its Swift functions.
struct FEDisplacementMapParameters {
    ChannelSelectorType xChannelSelector;
    ChannelSelectorType yChannelSelector;
    float scale;
    // §16.4: when in2 is tainted, this primitive becomes a pass-through of in.
    bool in2IsTainted;

    bool operator==(const FEDisplacementMapParameters&) const = default;
};

} // namespace WebCore
