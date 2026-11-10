/*
 * Copyright (C) 2003-2019 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#import "config.h"
#import "GraphicsContext.h"

#import "CGRendererSPI.h"
#import "DisplayListRecorder.h"
#import "Font.h"
#import "GraphicsContextCG.h"
#import "GraphicsContextCGCapture.h"
#import "IOSurface.h"
#import "IntRect.h"
#import <CoreText/CoreText.h>
#import <numeric>
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/cocoa/FeatureFlagsSPI.h>
#import <pal/spi/mac/NSGraphicsSPI.h>
#import <wtf/SoftLinking.h>
#import <wtf/StdLibExtras.h>

#if USE(APPKIT)
#import <AppKit/AppKit.h>
#endif

#if PLATFORM(IOS_FAMILY)
#import "Color.h"
#import "WKGraphics.h"
#import <UIKit/UIKit.h>
#import <pal/ios/UIKitSoftLink.h>
#import <pal/spi/ios/UIKitSPI.h>
#endif

@class NSColor;

// FIXME: More of this should use CoreGraphics instead of AppKit.
// FIXME: More of this should move into GraphicsContextCG.cpp.

namespace WebCore {

#if ASSERT_ENABLED
#define CAPTURE(call) \
    GraphicsContextCGCapture::Scope captureScope(m_capture.get()); \
    if (auto* capture = captureScope.outermost()) \
        capture->call
#else
#define CAPTURE(call)
#endif

// NSColor, NSBezierPath, and NSGraphicsContext calls do not raise exceptions
// so we don't block exceptions.

void GraphicsContextCG::drawFocusRing(const Vector<FloatRect>& rects, float outlineWidth, const Color& color, float zoomFactor)
{
    CAPTURE(unsupported("drawFocusRing"_s));
    Path path;
    for (const auto& rect : rects)
        path.addRect(rect);
    drawFocusRing(path, outlineWidth, color, zoomFactor);
}

#undef CAPTURE

} // namespace WebCore

CGStyleRef CGRendererCreateFocusRingStyle(CGColorRef color, CGFloat radiusScale)
{
    CGFocusRingStyle focusRingStyle;
#if USE(APPKIT)
    NSInitializeCGFocusRingStyleForTime(NSFocusRingOnly, &focusRingStyle, std::numeric_limits<double>::max());
#else
    focusRingStyle.version = 0;
    focusRingStyle.tint = kCGFocusRingTintBlue;
    focusRingStyle.ordering = kCGFocusRingOrderingNone;
    focusRingStyle.alpha = [PAL::getUIFocusRingStyleClassSingleton() maxAlpha];
    focusRingStyle.radius = [PAL::getUIFocusRingStyleClassSingleton() borderThickness];
    focusRingStyle.threshold = [PAL::getUIFocusRingStyleClassSingleton() alphaThreshold];
    focusRingStyle.bounds = CGRectZero;
#endif

    // radiusScale covers CSS zoom / page zoom (Cmd+/-), and page scale (pinch-to-zoom), canvas transforms and so on.
    focusRingStyle.radius *= radiusScale;

    // We want to respect the CGContext clipping and also not overpaint any
    // existing focus ring. The way to do this is set accumulate to
    // -1. According to CoreGraphics, the reasoning for this behavior has been
    // lost in time.
    focusRingStyle.accumulate = -1;
    return CGStyleCreateFocusRingWithColor(&focusRingStyle, color);
}
