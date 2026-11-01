/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies)
 * Copyright (C) 2014 Adobe Systems Incorporated. All rights reserved.
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

#include "config.h"
#include "FEBlend.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<FEBlend> FEBlend::create(BlendMode mode, ColorSpace colorSpace)
{
    return adoptRef(*new FEBlend(mode, colorSpace));
}

FEBlend::FEBlend(BlendMode mode, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEBlend, colorSpace)
    , m_parameters { mode }
{
}

bool FEBlend::operator==(const FEBlend& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

bool FEBlend::setBlendMode(BlendMode mode)
{
    if (m_parameters.mode == mode)
        return false;
    m_parameters.mode = mode;
    return true;
}

OptionSet<FilterRenderingMode> FEBlend::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

TextStream& FEBlend::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feBlend"_s;
    FilterEffect::externalRepresentation(ts, representation);

    ts << " mode=\"" << (m_parameters.mode == BlendMode::Normal ? "normal"_s : compositeOperatorName(CompositeOperator::SourceOver, m_parameters.mode));

    ts << "\"]\n"_s;
    return ts;
}

} // namespace WebCore
