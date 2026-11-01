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
#include <span>
#include <wtf/Compiler.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {

enum class ComponentTransferType : uint8_t {
    FECOMPONENTTRANSFER_TYPE_UNKNOWN  = 0,
    FECOMPONENTTRANSFER_TYPE_IDENTITY = 1,
    FECOMPONENTTRANSFER_TYPE_TABLE    = 2,
    FECOMPONENTTRANSFER_TYPE_DISCRETE = 3,
    FECOMPONENTTRANSFER_TYPE_LINEAR   = 4,
    FECOMPONENTTRANSFER_TYPE_GAMMA    = 5
};

struct ComponentTransferFunction {
    ComponentTransferType type { ComponentTransferType::FECOMPONENTTRANSFER_TYPE_UNKNOWN };

    // For linear
    float slope { 1 };
    float intercept { 0 };

    // For gamma
    float amplitude { 1 };
    float exponent { 1 };
    float offset { 0 };

    Vector<float> tableValues;

    bool operator==(const ComponentTransferFunction&) const = default;
};

// A ComponentTransferFunction lent to Swift for one call: Swift reads the table without copying it, and can't keep it.
class SWIFT_VIEW SWIFT_SAFE ComponentTransferFunctionView {
public:
    explicit ComponentTransferFunctionView(const ComponentTransferFunction& function LIFETIME_BOUND)
        : m_function(function)
    {
    }

    ComponentTransferType type() const { return m_function.type; }
    float slope() const { return m_function.slope; }
    float intercept() const { return m_function.intercept; }
    float amplitude() const { return m_function.amplitude; }
    float exponent() const { return m_function.exponent; }
    float offset() const { return m_function.offset; }
    std::span<const float> tableValuesSpan() const LIFETIME_BOUND { return m_function.tableValues.span(); }

private:
    const ComponentTransferFunction& m_function;
};

enum class ComponentTransferChannel : uint8_t { Red, Green, Blue, Alpha };

// FEComponentTransfer's parameters, which FEComponentTransfer stores (its getters and setters are the IPC model) and
// lends to its Swift functions through FEComponentTransferParametersView.
struct FEComponentTransferParameters {
    ComponentTransferFunction red;
    ComponentTransferFunction green;
    ComponentTransferFunction blue;
    ComponentTransferFunction alpha;

    bool operator==(const FEComponentTransferParameters&) const = default;
};

// FEComponentTransferParameters lent to Swift for one call, as one view per channel's function.
class SWIFT_VIEW SWIFT_SAFE FEComponentTransferParametersView {
public:
    explicit FEComponentTransferParametersView(const FEComponentTransferParameters& parameters LIFETIME_BOUND)
        : m_parameters(parameters)
    {
    }

    ComponentTransferFunctionView red() const LIFETIME_BOUND { return ComponentTransferFunctionView { m_parameters.red }; }
    ComponentTransferFunctionView green() const LIFETIME_BOUND { return ComponentTransferFunctionView { m_parameters.green }; }
    ComponentTransferFunctionView blue() const LIFETIME_BOUND { return ComponentTransferFunctionView { m_parameters.blue }; }
    ComponentTransferFunctionView alpha() const LIFETIME_BOUND { return ComponentTransferFunctionView { m_parameters.alpha }; }

private:
    const FEComponentTransferParameters& m_parameters;
};

} // namespace WebCore
