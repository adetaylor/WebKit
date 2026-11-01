/*
 * Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
 * Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
 * Copyright (C) 2005 Eric Seidel <eric@webkit.org>
 * Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
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

#include <WebCore/FloatPoint.h>
#include <WebCore/IntPoint.h>
#include <WebCore/IntSize.h>
#include <cstdint>
#include <span>
#include <wtf/Compiler.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WebCore {

enum class EdgeModeType : uint8_t {
    Unknown,
    Duplicate,
    Wrap,
    None
};

// FEConvolveMatrix's parameters, which FEConvolveMatrix stores (its getters and setters are the IPC model) and lends to
// its Swift functions through FEConvolveMatrixParametersView.
struct FEConvolveMatrixParameters {
    IntSize kernelSize;
    float divisor;
    float bias;
    IntPoint targetOffset;
    EdgeModeType edgeMode;
    FloatPoint kernelUnitLength;
    bool preserveAlpha;
    Vector<float> kernel;

    bool operator==(const FEConvolveMatrixParameters&) const = default;
};

// FEConvolveMatrixParameters lent to Swift for one call: Swift reads the kernel without copying it, and can't keep it.
class SWIFT_VIEW SWIFT_SAFE FEConvolveMatrixParametersView {
public:
    explicit FEConvolveMatrixParametersView(const FEConvolveMatrixParameters& parameters LIFETIME_BOUND)
        : m_parameters(parameters)
    {
    }

    IntSize kernelSize() const { return m_parameters.kernelSize; }
    float divisor() const { return m_parameters.divisor; }
    float bias() const { return m_parameters.bias; }
    IntPoint targetOffset() const { return m_parameters.targetOffset; }
    EdgeModeType edgeMode() const { return m_parameters.edgeMode; }
    bool preserveAlpha() const { return m_parameters.preserveAlpha; }
    std::span<const float> kernelValues() const LIFETIME_BOUND { return m_parameters.kernel.span(); }

private:
    const FEConvolveMatrixParameters& m_parameters;
};

} // namespace WebCore
