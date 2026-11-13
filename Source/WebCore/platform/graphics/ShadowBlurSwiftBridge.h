/*
 * Copyright (C) 2011-2026 Apple Inc. All rights reserved.
 * Copyright (C) 2010 Sencha, Inc. All rights reserved.
 * Copyright (C) 2010 Igalia S.L. All rights reserved.
 * Copyright (C) Research In Motion Limited 2011. All rights reserved.
 * Copyright (C) 2013 Digia Plc. and/or its subsidiary(-ies).
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

#include <wtf/Function.h>
#include <wtf/Platform.h>
#include <wtf/SwiftBridging.h>

// The values ShadowBlur's C++ (ShadowBlur.cpp) passes its Swift (ShadowBlurGeometry.swift, ShadowBlurDrawing.swift,
// ShadowBlurKernel.swift), which plans and draws the shadow. Sizes and rects are plain fields, which Swift reads directly.

namespace WebCore {

class Color;
class FloatPoint;
class FloatRect;
class FloatSize;
class GraphicsContext;
class GraphicsContextView;
class ImageBuffer;

// ShadowBlur::ShadowType's enumerators.
enum class ShadowBlurType : uint8_t {
    NoShadow,
    SolidShadow,
    BlurShadow
};

struct ShadowBlurSize {
    float width { 0 };
    float height { 0 };
};

struct ShadowBlurRect {
    float x { 0 };
    float y { 0 };
    float width { 0 };
    float height { 0 };
};

// A shadow's blur radius, offset and type, which ShadowBlur stores and its Swift sets and reads.
struct ShadowBlurState {
    ShadowBlurSize blurRadius;
    ShadowBlurSize offset;
    bool shadowsIgnoreTransforms { false };
    ShadowBlurType type { ShadowBlurType::NoShadow };
};

// The radii of a FloatRoundedRect's corners.
struct ShadowBlurCornerRadii {
    ShadowBlurSize topLeft;
    ShadowBlurSize topRight;
    ShadowBlurSize bottomLeft;
    ShadowBlurSize bottomRight;
};

// Where ShadowBlur's Swift draws a shadow, for one draw: the GraphicsContext of the GraphicsContext overloads of
// ShadowBlur::drawRectShadow() and drawInsetShadow(), or the callbacks the other overloads take (each passes the ones it
// takes).
class SWIFT_VIEW SWIFT_SAFE ShadowBlurDestination {
public:
    using DrawBufferCallback = Function<void(ImageBuffer&, const FloatPoint&, const FloatSize&)>;
    using DrawImageCallback = Function<void(ImageBuffer&, const FloatRect&, const FloatRect&)>;
    using FillRectCallback = Function<void(const FloatRect&, const Color&)>;
    using FillRectWithHoleCallback = Function<void(const FloatRect&, const FloatRect&, const Color&)>;
    using DrawShadowCallback = Function<void(GraphicsContext&)>;

    explicit ShadowBlurDestination(GraphicsContext& graphicsContext LIFETIME_BOUND)
        : m_graphicsContext(&graphicsContext)
    {
    }

    ShadowBlurDestination(const DrawBufferCallback* drawBuffer LIFETIME_BOUND, const DrawImageCallback* drawImage LIFETIME_BOUND, const FillRectCallback* fillRect LIFETIME_BOUND, const FillRectWithHoleCallback* fillRectWithHole LIFETIME_BOUND, const DrawShadowCallback* drawShadow LIFETIME_BOUND)
        : m_drawBuffer(drawBuffer)
        , m_drawImage(drawImage)
        , m_fillRect(fillRect)
        , m_fillRectWithHole(fillRectWithHole)
        , m_drawShadow(drawShadow)
    {
    }

    bool hasGraphicsContext() const { return m_graphicsContext; }
    GraphicsContextView graphicsContext() const LIFETIME_BOUND;

    void drawBuffer(ImageBuffer&, const FloatPoint&, const FloatSize&) const;
    void drawImage(ImageBuffer&, const FloatRect&, const FloatRect&) const;
    void fillRect(const FloatRect&, const Color&) const;
    void fillRectWithHole(const FloatRect&, const FloatRect&, const Color&) const;
    // Draws the shadow's shape into the layer image's context.
    void drawShadow(ImageBuffer& layerImage) const;

private:
    GraphicsContext* m_graphicsContext { nullptr };
    const DrawBufferCallback* m_drawBuffer { nullptr };
    const DrawImageCallback* m_drawImage { nullptr };
    const FillRectCallback* m_fillRect { nullptr };
    const FillRectWithHoleCallback* m_fillRectWithHole { nullptr };
    const DrawShadowCallback* m_drawShadow { nullptr };
};

#if USE(CG)
// Starts the timer, on the main run loop, that purges ShadowBlur's scratch buffer (ShadowBlurDrawing.swift), or
// restarts it.
void scheduleShadowBlurScratchBufferPurge();
#endif

} // namespace WebCore
