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

#include "config.h"
#include "GraphicsContextSwiftBridge.h"

#include "GraphicsContext.h"
#include "ImageBuffer.h"
#include "NativeImage.h"
#include "Path.h"
#include "Pattern.h"

namespace WebCore {

void GraphicsContextView::save() const
{
    m_context.save();
}

void GraphicsContextView::restore() const
{
    m_context.restore();
}

void GraphicsContextView::translate(const FloatSize& size) const
{
    m_context.translate(size);
}

void GraphicsContextView::clip(const FloatRect& rect) const
{
    m_context.clip(rect);
}

bool GraphicsContextView::clipToImageBuffer(ImageBuffer& imageBuffer, const FloatRect& rect) const
{
    // The image buffer is not drawn to after this.
    RefPtr nativeImage = imageBuffer.createNativeImageReference();
    if (!nativeImage)
        return false;
    m_context.clipToNativeImage(*nativeImage, rect);
    return true;
}

void GraphicsContextView::setAlpha(float alpha) const
{
    m_context.setAlpha(alpha);
}

void GraphicsContextView::setFillColor(const Color& color) const
{
    m_context.setFillColor(color);
}

void GraphicsContextView::setFillRule(WindRule fillRule) const
{
    m_context.setFillRule(fillRule);
}

void GraphicsContextView::setFillPattern(ImageBuffer& imageBuffer, const AffineTransform& patternSpaceTransform) const
{
    m_context.setFillPattern(Pattern::create({ Ref { imageBuffer } }, { true, true, patternSpaceTransform }));
}

void GraphicsContextView::setCompositeOperation(CompositeOperator compositeOperator, BlendMode blendMode) const
{
    m_context.setCompositeOperation(compositeOperator, blendMode);
}

void GraphicsContextView::clearDropShadow() const
{
    m_context.clearDropShadow();
}

void GraphicsContextView::fillRect(const FloatRect& rect) const
{
    m_context.fillRect(rect);
}

void GraphicsContextView::fillRect(const FloatRect& rect, const Color& color) const
{
    m_context.fillRect(rect, color);
}

void GraphicsContextView::fillPath(const Path& path) const
{
    m_context.fillPath(path);
}

void GraphicsContextView::clearRect(const FloatRect& rect) const
{
    m_context.clearRect(rect);
}

void GraphicsContextView::drawImageBuffer(ImageBuffer& imageBuffer, const FloatPoint& destination, CompositeOperator compositeOperator) const
{
    m_context.drawImageBuffer(imageBuffer, destination, { compositeOperator });
}

void GraphicsContextView::drawImageBuffer(ImageBuffer& imageBuffer, const FloatRect& destination, CompositeOperator compositeOperator) const
{
    m_context.drawImageBuffer(imageBuffer, destination, { compositeOperator });
}

void GraphicsContextView::drawImageBuffer(ImageBuffer& imageBuffer, const FloatRect& destination, const FloatRect& source, CompositeOperator compositeOperator, BlendMode blendMode) const
{
    m_context.drawImageBuffer(imageBuffer, destination, source, { compositeOperator, blendMode });
}

GraphicsContextView ImageBufferDrawing::context() const
{
    return GraphicsContextView { m_imageBuffer->context() };
}

} // namespace WebCore
