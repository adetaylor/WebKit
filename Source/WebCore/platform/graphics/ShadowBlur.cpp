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

#include "config.h"
#include "ShadowBlur.h"

#include "AffineTransform.h"
#include "GraphicsContext.h"
#include "GraphicsContextSwiftBridge.h"
#include "ImageBuffer.h"
#include "PixelBufferSwiftBridge.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>

#if ENABLE(WEBCORE_SWIFT)
#include "WebCore-Swift.h"
#endif

namespace WebCore {

ShadowBlur::ShadowBlur(const FloatSize& radius, const FloatSize& offset, const Color& color, bool shadowsIgnoreTransforms)
    : m_color(color)
    , m_state(shadowBlurState({ radius.width(), radius.height() }, { offset.width(), offset.height() }, m_color.isVisible(), shadowsIgnoreTransforms, false))
{
}

ShadowBlur::ShadowBlur(const GraphicsDropShadow& dropShadow, bool shadowsIgnoreTransforms)
    : m_color(dropShadow.color)
{
    bool legacyRadius = false;
#if USE(CG)
    // Core Graphics incorrectly renders shadows with radius > 8px (<rdar://problem/8103442>),
    // but we need to preserve this buggy behavior for canvas and -webkit-box-shadow.
    legacyRadius = dropShadow.radiusMode == ShadowRadiusMode::Legacy;
#endif
    m_state = shadowBlurState({ dropShadow.radius, dropShadow.radius }, { dropShadow.offset.width(), dropShadow.offset.height() }, m_color.isVisible(), shadowsIgnoreTransforms, legacyRadius);
}

ShadowBlur::ShadowType ShadowBlur::type() const
{
    return static_cast<ShadowType>(m_state.type);
}

void ShadowBlur::blurLayerImage(std::span<uint8_t> imageData, const IntSize& size, int rowStride)
{
    MutablePixelBytes pixels { imageData };
    shadowBlurLayerImage(m_state, pixels, size.width(), size.height(), rowStride);
}

static_assert(static_cast<int>(ShadowBlurType::NoShadow) == ShadowBlur::NoShadow);
static_assert(static_cast<int>(ShadowBlurType::SolidShadow) == ShadowBlur::SolidShadow);
static_assert(static_cast<int>(ShadowBlurType::BlurShadow) == ShadowBlur::BlurShadow);

static ShadowBlurSize shadowBlurSize(const FloatSize& size)
{
    return { size.width(), size.height() };
}

static ShadowBlurRect shadowBlurRect(const FloatRect& rect)
{
    return { rect.x(), rect.y(), rect.width(), rect.height() };
}

static ShadowBlurCornerRadii shadowBlurCornerRadii(const CornerRadii& radii)
{
    return { shadowBlurSize(radii.topLeft()), shadowBlurSize(radii.topRight()), shadowBlurSize(radii.bottomLeft()), shadowBlurSize(radii.bottomRight()) };
}

void ShadowBlur::drawRectShadow(GraphicsContext& graphicsContext, const FloatRoundedRect& shadowedRect)
{
    shadowBlurDrawRectShadow(m_state, graphicsContext.getCTM(), graphicsContext.clipBounds(), shadowBlurRect(shadowedRect.rect()), shadowBlurCornerRadii(shadowedRect.radii()), m_color, ShadowBlurDestination { graphicsContext });
}

void ShadowBlur::drawInsetShadow(GraphicsContext& graphicsContext, const FloatRect& fullRect, const FloatRoundedRect& holeRect)
{
    shadowBlurDrawInsetShadow(m_state, graphicsContext.getCTM(), graphicsContext.clipBounds(), shadowBlurRect(fullRect), shadowBlurRect(holeRect.rect()), shadowBlurCornerRadii(holeRect.radii()), m_color, ShadowBlurDestination { graphicsContext });
}

void ShadowBlur::drawRectShadow(const AffineTransform& transform, const IntRect& clipBounds, const FloatRoundedRect& shadowedRect, NOESCAPE const DrawBufferCallback& drawBuffer, NOESCAPE const DrawImageCallback& drawImage, NOESCAPE const FillRectCallback& fillRect)
{
    shadowBlurDrawRectShadow(m_state, transform, clipBounds, shadowBlurRect(shadowedRect.rect()), shadowBlurCornerRadii(shadowedRect.radii()), m_color, { &drawBuffer, &drawImage, &fillRect, nullptr, nullptr });
}

void ShadowBlur::drawInsetShadow(const AffineTransform& transform, const IntRect& clipBounds, const FloatRect& fullRect, const FloatRoundedRect& holeRect, NOESCAPE const DrawBufferCallback& drawBuffer, NOESCAPE const DrawImageCallback& drawImage, NOESCAPE const FillRectWithHoleCallback& fillRectWithHole)
{
    shadowBlurDrawInsetShadow(m_state, transform, clipBounds, shadowBlurRect(fullRect), shadowBlurRect(holeRect.rect()), shadowBlurCornerRadii(holeRect.radii()), m_color, { &drawBuffer, &drawImage, nullptr, &fillRectWithHole, nullptr });
}

void ShadowBlur::drawShadowLayer(const AffineTransform& transform, const IntRect& clipBounds, const FloatRect& layerArea, NOESCAPE const DrawShadowCallback& drawShadow, NOESCAPE const DrawBufferCallback& drawBuffer)
{
    shadowBlurDrawShadowLayer(m_state, transform, clipBounds, shadowBlurRect(layerArea), m_color, { &drawBuffer, nullptr, nullptr, nullptr, &drawShadow });
}

GraphicsContextView ShadowBlurDestination::graphicsContext() const
{
    RELEASE_ASSERT(m_graphicsContext);
    return GraphicsContextView { *m_graphicsContext };
}

void ShadowBlurDestination::drawBuffer(ImageBuffer& layerImage, const FloatPoint& layerOrigin, const FloatSize& layerSize) const
{
    RELEASE_ASSERT(m_drawBuffer);
    (*m_drawBuffer)(layerImage, layerOrigin, layerSize);
}

void ShadowBlurDestination::drawImage(ImageBuffer& image, const FloatRect& destRect, const FloatRect& srcRect) const
{
    RELEASE_ASSERT(m_drawImage);
    (*m_drawImage)(image, destRect, srcRect);
}

void ShadowBlurDestination::fillRect(const FloatRect& rect, const Color& color) const
{
    RELEASE_ASSERT(m_fillRect);
    (*m_fillRect)(rect, color);
}

void ShadowBlurDestination::fillRectWithHole(const FloatRect& rect, const FloatRect& holeRect, const Color& color) const
{
    RELEASE_ASSERT(m_fillRectWithHole);
    (*m_fillRectWithHole)(rect, holeRect, color);
}

void ShadowBlurDestination::drawShadow(ImageBuffer& layerImage) const
{
    RELEASE_ASSERT(m_drawShadow);
    (*m_drawShadow)(layerImage.context());
}

#if USE(CG)
void scheduleShadowBlurScratchBufferPurge()
{
    static constexpr Seconds scratchBufferPurgeInterval { 2_s };

    // The timer fires on the main run loop and so must be started/restarted there: ShadowBlur draws on paint worker
    // threads in the GPU process, and restarting an active timer off its run loop's thread races with an in-flight
    // callback. The timer is only ever touched on the main run loop.
    ensureOnMainRunLoop([] {
        static NeverDestroyed<RunLoop::Timer> purgeTimer(RunLoop::mainSingleton(), "ScratchBuffer::PurgeTimer"_s, [] {
            purgeShadowBlurScratchBuffer();
        });
        purgeTimer->startOneShot(scratchBufferPurgeInterval);
    });
}
#endif

} // namespace WebCore
