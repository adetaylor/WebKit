/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#pragma once

#include <WebCore/AffineTransform.h>
#include <WebCore/Color.h>
#include <WebCore/ColorSpace.h>
#include <WebCore/FloatRect.h>
#include <WebCore/GraphicsTypes.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/WindRule.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

class GraphicsContext;
class Path;

// A GraphicsContext lent to WebCore's Swift for one call. Swift can't keep it: the view is non-escapable. Its members are
// the GraphicsContext calls WebCore's Swift makes, with GraphicsContext's default arguments.
class SWIFT_NONESCAPABLE SWIFT_SAFE GraphicsContextView {
public:
    explicit GraphicsContextView(GraphicsContext& context LIFETIME_BOUND)
        : m_context(context)
    {
    }

    void save() const;
    void restore() const;
    void translate(const FloatSize&) const;
    void clip(const FloatRect&) const;
    void clipToImageBuffer(ImageBuffer&, const FloatRect&) const;
    void setAlpha(float) const;
    void setFillColor(const Color&) const;
    void setFillRule(WindRule) const;
    // A pattern of the image, repeated in both directions.
    void setFillPattern(ImageBuffer&, const AffineTransform& patternSpaceTransform) const;
    void setCompositeOperation(CompositeOperator, BlendMode) const;
    void clearDropShadow() const;
    void fillRect(const FloatRect&) const;
    void fillRect(const FloatRect&, const Color&) const;
    void fillPath(const Path&) const;
    void clearRect(const FloatRect&) const;
    void drawImageBuffer(ImageBuffer&, const FloatPoint& destination, CompositeOperator) const;
    void drawImageBuffer(ImageBuffer&, const FloatRect& destination, CompositeOperator) const;
    void drawImageBuffer(ImageBuffer&, const FloatRect& destination, const FloatRect& source, CompositeOperator, BlendMode) const;

private:
    GraphicsContext& m_context;
};

// An ImageBuffer that WebCore's Swift draws into. It keeps the image buffer alive, and lends its context while Swift holds
// it.
class SWIFT_SELF_CONTAINED ImageBufferDrawing {
public:
    explicit ImageBufferDrawing(ImageBuffer& imageBuffer)
        : m_imageBuffer(imageBuffer)
    {
    }

    GraphicsContextView context() const LIFETIME_BOUND;

private:
    Ref<ImageBuffer> m_imageBuffer;
};

// Values that WebCore's Swift draws with and can't spell itself: ColorSpace::SRGB() returns a reference, and Color's
// named colors are constexpr static members.
namespace GraphicsContextSwiftBridge {

inline ColorSpace sRGBColorSpace()
{
    return ColorSpace::SRGB();
}

inline Color blackColor()
{
    return Color::black;
}

} // namespace GraphicsContextSwiftBridge

} // namespace WebCore
