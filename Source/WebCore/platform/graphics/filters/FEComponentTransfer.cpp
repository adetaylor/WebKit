/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
 * Copyright (C) Research In Motion Limited 2010. All rights reserved.
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
#include "FEComponentTransfer.h"

#include "Filter.h"
#include <wtf/text/TextStream.h>

namespace WebCore {

Ref<FEComponentTransfer> FEComponentTransfer::create(const ComponentTransferFunction& redFunction, const ComponentTransferFunction& greenFunction, const ComponentTransferFunction& blueFunction, const ComponentTransferFunction& alphaFunction, ColorSpace colorSpace)
{
    return adoptRef(*new FEComponentTransfer(redFunction, greenFunction, blueFunction, alphaFunction, colorSpace));
}

Ref<FEComponentTransfer> FEComponentTransfer::create(ComponentTransferFunctions&& functions)
{
    return adoptRef(*new FEComponentTransfer(WTF::move(functions)));
}

FEComponentTransfer::FEComponentTransfer(const ComponentTransferFunction& redFunction, const ComponentTransferFunction& greenFunction, const ComponentTransferFunction& blueFunction, const ComponentTransferFunction& alphaFunction, ColorSpace colorSpace)
    : FilterEffect(FilterEffect::Type::FEComponentTransfer, colorSpace)
    , m_parameters { redFunction, greenFunction, blueFunction, alphaFunction }
{
}

FEComponentTransfer::FEComponentTransfer(ComponentTransferFunctions&& functions)
    : FilterEffect(FilterEffect::Type::FEComponentTransfer)
    , m_parameters {
        WTF::move(functions[ComponentTransferChannel::Red]),
        WTF::move(functions[ComponentTransferChannel::Green]),
        WTF::move(functions[ComponentTransferChannel::Blue]),
        WTF::move(functions[ComponentTransferChannel::Alpha])
    }
{
}

bool FEComponentTransfer::operator==(const FEComponentTransfer& other) const
{
    return FilterEffect::operator==(other) && m_parameters == other.m_parameters;
}

ComponentTransferFunction& FEComponentTransfer::function(ComponentTransferChannel channel)
{
    switch (channel) {
    case ComponentTransferChannel::Red:
        return m_parameters.red;
    case ComponentTransferChannel::Green:
        return m_parameters.green;
    case ComponentTransferChannel::Blue:
        return m_parameters.blue;
    case ComponentTransferChannel::Alpha:
        return m_parameters.alpha;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

OptionSet<FilterRenderingMode> FEComponentTransfer::supportedFilterRenderingModes(OptionSet<FilterRenderingMode> preferredFilterRenderingModes) const
{
    OptionSet<FilterRenderingMode> modes = FilterRenderingMode::Software;
#if USE(SKIA)
    modes.add(FilterRenderingMode::Accelerated);
#endif
#if USE(CORE_IMAGE)
    modes.add(FilterRenderingMode::Accelerated);
#endif
    return modes & preferredFilterRenderingModes;
}

bool FEComponentTransfer::setType(ComponentTransferChannel channel, ComponentTransferType type)
{
    if (function(channel).type == type)
        return false;

    function(channel).type = type;
    return true;
}

bool FEComponentTransfer::setSlope(ComponentTransferChannel channel, float value)
{
    if (function(channel).slope == value)
        return false;

    function(channel).slope = value;
    return true;
}

bool FEComponentTransfer::setIntercept(ComponentTransferChannel channel, float value)
{
    if (function(channel).intercept == value)
        return false;

    function(channel).intercept = value;
    return true;
}

bool FEComponentTransfer::setAmplitude(ComponentTransferChannel channel, float value)
{
    if (function(channel).amplitude == value)
        return false;

    function(channel).amplitude = value;
    return true;
}

bool FEComponentTransfer::setExponent(ComponentTransferChannel channel, float value)
{
    if (function(channel).exponent == value)
        return false;

    function(channel).exponent = value;
    return true;
}

bool FEComponentTransfer::setOffset(ComponentTransferChannel channel, float value)
{
    if (function(channel).offset == value)
        return false;

    function(channel).offset = value;
    return true;
}

bool FEComponentTransfer::setTableValues(ComponentTransferChannel channel, Vector<float>&& values)
{
    if (function(channel).tableValues == values)
        return false;

    function(channel).tableValues = WTF::move(values);
    return true;
}

static TextStream& operator<<(TextStream& ts, ComponentTransferType type)
{
    switch (type) {
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_UNKNOWN:
        ts << "UNKNOWN"_s;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_IDENTITY:
        ts << "IDENTITY"_s;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_TABLE:
        ts << "TABLE"_s;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_DISCRETE:
        ts << "DISCRETE"_s;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_LINEAR:
        ts << "LINEAR"_s;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_GAMMA:
        ts << "GAMMA"_s;
        break;
    }
    return ts;
}

static TextStream& operator<<(TextStream& ts, const ComponentTransferFunction& function)
{
    ts << "type=\""_s << function.type;

    switch (function.type) {
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_UNKNOWN:
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_IDENTITY:
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_TABLE:
        ts << ' ' << function.tableValues;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_DISCRETE:
        ts << ' ' << function.tableValues;
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_LINEAR:
        ts << "\" slope=\""_s << function.slope << "\" intercept=\""_s << function.intercept << '"';
        break;
    case ComponentTransferType::FECOMPONENTTRANSFER_TYPE_GAMMA:
        ts << "\" amplitude=\""_s << function.amplitude << "\" exponent=\""_s << function.exponent << "\" offset=\""_s << function.offset << '"';
        break;
    }

    return ts;
}

TextStream& FEComponentTransfer::externalRepresentation(TextStream& ts, FilterRepresentation representation) const
{
    ts << indent << "[feComponentTransfer"_s;
    FilterEffect::externalRepresentation(ts, representation);
    ts << '\n';

    {
        TextStream::IndentScope indentScope(ts, 2);
        ts << indent << "{red: "_s << m_parameters.red << "}\n"_s;
        ts << indent << "{green: "_s << m_parameters.green << "}\n"_s;
        ts << indent << "{blue: "_s << m_parameters.blue << "}\n"_s;
        ts << indent << "{alpha: "_s << m_parameters.alpha << '}';
    }

    ts << "]\n"_s;
    return ts;
}

} // namespace WebCore
