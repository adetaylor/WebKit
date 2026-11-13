/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2010 Dirk Schulze <krit@webkit.org>
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
#include "FEImage.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<FEImage> FEImage::create(SourceImage&& sourceImage, const FloatRect& sourceImageRect)
{
    return adoptRef(*new FEImage(WTF::move(sourceImage), sourceImageRect));
}

FEImage::FEImage(SourceImage&& sourceImage, const FloatRect& sourceImageRect)
    : FilterEffect(Type::FEImage)
    , m_sourceImage(WTF::move(sourceImage))
    , m_parameters { sourceImageRect }
{
}

bool FEImage::operator==(const FEImage& other) const
{
    return FilterEffect::operator==(other)
        && m_sourceImage == other.m_sourceImage
        && m_parameters == other.m_parameters;
}

OptionSet<FilterRenderingMode> FEImage::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

TextStream& FEImage::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feImage"_s;
    FilterEffect::externalRepresentation(ts, representation);

    if (!m_parameters.sourceImageRect.isEmpty())
        ts << " image-size=\""_s << m_parameters.sourceImageRect.width() << 'x' << m_parameters.sourceImageRect.height() << '"';

    // FIXME: should this dump also object returned by FEImage::image() ?

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
