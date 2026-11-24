/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#include "config.h"
#include "ScrollingAccelerationCurve.h"

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)

#include "ArgumentCoders.h"
#include <wtf/text/TextStream.h>

namespace WebKit {

TextStream& operator<<(TextStream& ts, const ScrollingAccelerationCurve& curve)
{
    TextStream::GroupScope group(ts);

    ts << "ScrollingAccelerationCurve"_s;

    ts.dumpProperty("gainLinear"_s, curve.m_parameters.gainLinear);
    ts.dumpProperty("gainParabolic"_s, curve.m_parameters.gainParabolic);
    ts.dumpProperty("gainCubic"_s, curve.m_parameters.gainCubic);
    ts.dumpProperty("gainQuartic"_s, curve.m_parameters.gainQuartic);
    ts.dumpProperty("tangentSpeedLinear"_s, curve.m_parameters.tangentSpeedLinear);
    ts.dumpProperty("tangentSpeedParabolicRoot"_s, curve.m_parameters.tangentSpeedParabolicRoot);
    ts.dumpProperty("resolution"_s, curve.m_parameters.resolution);
    ts.dumpProperty("frameRate"_s, curve.m_parameters.frameRate);

    return ts;
}

#if !PLATFORM(MAC)

std::optional<ScrollingAccelerationCurve> ScrollingAccelerationCurve::fromNativeWheelEvent(const NativeWebWheelEvent&)
{
    return std::nullopt;
}

#endif

} // namespace WebKit

#endif // ENABLE(MOMENTUM_EVENT_DISPATCHER)
