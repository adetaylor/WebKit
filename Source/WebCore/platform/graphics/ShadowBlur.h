/*
 * Copyright (C) 2011-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2010 Sencha, Inc.
 * Copyright (C) 2010 Igalia S.L.
 * All rights reserved.
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

#pragma once

#include "Color.h"
#include "FloatRect.h"
#include "FloatRoundedRect.h"
#include "GraphicsStyle.h"
#include "ShadowBlurSwiftBridge.h"
#include <wtf/Noncopyable.h>

namespace WebCore {

class AffineTransform;
class GraphicsContext;
struct DropShadow;
class ImageBuffer;

// The Swift (ShadowBlurGeometry.swift, ShadowBlurDrawing.swift) plans and draws the shadow.
class WEBCORE_EXPORT ShadowBlur {
    WTF_MAKE_NONCOPYABLE(ShadowBlur);
public:
    enum ShadowType {
        NoShadow,
        SolidShadow,
        BlurShadow
    };

    ShadowBlur(const FloatSize& radius, const FloatSize& offset, const Color&, bool shadowsIgnoreTransforms = false);
    ShadowBlur(const GraphicsDropShadow&, bool shadowsIgnoreTransforms = false);

    void drawRectShadow(GraphicsContext&, const FloatRoundedRect&);
    void drawInsetShadow(GraphicsContext&, const FloatRect&, const FloatRoundedRect& holeRect);

    using DrawBufferCallback = ShadowBlurDestination::DrawBufferCallback;
    using DrawImageCallback = ShadowBlurDestination::DrawImageCallback;
    using FillRectCallback = ShadowBlurDestination::FillRectCallback;
    using FillRectWithHoleCallback = ShadowBlurDestination::FillRectWithHoleCallback;
    using DrawShadowCallback = ShadowBlurDestination::DrawShadowCallback;

    // DrawBufferCallback is for drawing shadow without tiling.
    // DrawImageCallback and FillRectCallback is for drawing shadow with tiling.
    void drawRectShadow(const AffineTransform&, const IntRect& clipBounds, const FloatRoundedRect& shadowedRect, NOESCAPE const DrawBufferCallback&, NOESCAPE const DrawImageCallback&, NOESCAPE const FillRectCallback&);
    void drawInsetShadow(const AffineTransform&, const IntRect& clipBounds, const FloatRect& fullRect, const FloatRoundedRect& holeRect, NOESCAPE const DrawBufferCallback&, NOESCAPE const DrawImageCallback&, NOESCAPE const FillRectWithHoleCallback&);
    void drawShadowLayer(const AffineTransform&, const IntRect& clipBounds, const FloatRect& layerArea, NOESCAPE const DrawShadowCallback&, NOESCAPE const DrawBufferCallback&);

    void blurLayerImage(std::span<uint8_t>, const IntSize&, int stride);

    ShadowType type() const;

private:
    Color m_color;
    ShadowBlurState m_state;
};

} // namespace WebCore
