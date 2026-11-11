/*
 * Copyright (C) 2011-2017 Apple Inc. All rights reserved.
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
#include "ScrollingEffectsController.h"

#include "KeyboardScrollingAnimator.h"
#include "LayoutSize.h"
#include "Logging.h"
#include "PlatformWheelEvent.h"
#include "ScrollAnimationSmooth.h"
#include "ScrollExtents.h"
#include "ScrollPhysicsControllerHolder.h"
#include "ScrollPhysicsTypes.h"
#include "ScrollableArea.h"
#include "ScrollingEffectsClock.h"
#include <atomic>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

#if HAVE(RUBBER_BANDING)
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingEffectsControllerTimer);

static std::atomic<ScrollingEffectsClockFunction> scrollingEffectsClock;

MonotonicTime scrollingEffectsClockNow()
{
    if (auto clock = scrollingEffectsClock.load(std::memory_order_relaxed))
        return clock();
    return MonotonicTime::now();
}

void setScrollingEffectsClockForTesting(ScrollingEffectsClockFunction clock)
{
    scrollingEffectsClock.store(clock, std::memory_order_relaxed);
}

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollPhysicsControllerHolder);

// ScrollPhysicsController.swift converts to and from LayoutUnit's raw value, and treats these
// NodeIdentifier values as ones a HashSet rejects.
static_assert(kFixedPointDenominator == 64);
static_assert(!NodeIdentifier::isValidIdentifier(0) && !NodeIdentifier::isValidIdentifier(std::numeric_limits<uint64_t>::max()));

#if !PLATFORM(MAC)
// The "Momentum scroll" signpost interval, and AppKit's gesture rubber-band curve, are macOS's
// (mac/ScrollingEffectsController.mm).
void ScrollPhysicsClient::momentumScrollBegan()
{
}

void ScrollPhysicsClient::momentumScrollEnded()
{
}

float ScrollPhysicsClient::rubberBandHyperbolicCoefficient(const PlatformWheelEvent&)
{
    ASSERT_NOT_REACHED();
    return 0;
}

double ScrollPhysicsClient::hyperbolicReboundDeltaForElasticDelta(double, double, double)
{
    ASSERT_NOT_REACHED();
    return 0;
}

double ScrollPhysicsClient::hyperbolicElasticDeltaForReboundDelta(double, double, double)
{
    ASSERT_NOT_REACHED();
    return 0;
}
#endif

} // namespace WebCore
