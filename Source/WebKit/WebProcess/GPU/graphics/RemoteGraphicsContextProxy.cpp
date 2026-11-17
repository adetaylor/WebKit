/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
#include "RemoteGraphicsContextProxy.h"

#if ENABLE(GPU_PROCESS)

#include "Logging.h"
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteGraphicsContextMessages.h"
#endif
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteCGRendererMessages.h"
#include "RemoteCGRendererStyleKind.h"
#endif
#include "RemoteImageBufferProxy.h"
#include "RemoteRenderingBackendProxy.h"
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteSnapshotRecorderMessages.h"
#endif
#include "SharedVideoFrame.h"
#include "StreamClientConnection.h"
#include "WebProcess.h"
#include <WebCore/DisplayList.h>
#include <WebCore/DisplayListItems.h>
#include <WebCore/FEImage.h>
#include <WebCore/Filter.h>
#include <WebCore/GraphicsContext.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/MediaPlayer.h>
#include <WebCore/NotImplemented.h>
#include <WebCore/SVGFilterRenderer.h>
#include <wtf/MathExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/URL.h>
#include <wtf/text/TextStream.h>

#if USE(SYSTEM_PREVIEW)
#include <WebCore/ARKitBadgeSystemImage.h>
#endif

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteGraphicsContextProxy);

RemoteGraphicsContextProxy::RemoteGraphicsContextProxy(const FloatRect& initialClip, const AffineTransform& initialCTM, const ColorSpace& colorSpace, RenderingMode renderingMode, RemoteRenderingBackendProxy& renderingBackend)
    : RemoteGraphicsContextProxy({ }, initialClip, initialCTM, colorSpace, DrawGlyphsMode::Deconstruct, std::nullopt, renderingMode, RemoteGraphicsContextIdentifier::generate(), renderingBackend)
{
}

RemoteGraphicsContextProxy::RemoteGraphicsContextProxy(const FloatRect& initialClip, const AffineTransform& initialCTM, const ColorSpace& colorSpace, WebCore::ContentsFormat contentsFormat, RenderingMode renderingMode, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackendProxy& renderingBackend)
    : RemoteGraphicsContextProxy({ }, initialClip, initialCTM, colorSpace, DrawGlyphsMode::Deconstruct, contentsFormat, renderingMode, identifier, renderingBackend)
{
}

RemoteGraphicsContextProxy::RemoteGraphicsContextProxy(const GraphicsContextState& state, const FloatRect& initialClip, const AffineTransform& initialCTM, const ColorSpace& colorSpace, DrawGlyphsMode drawGlyphsMode, std::optional<ContentsFormat> contentsFormat, RenderingMode renderingMode, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackendProxy& renderingBackend)
    : DisplayList::Recorder(IsDeferred::No, state, initialClip, initialCTM, colorSpace, drawGlyphsMode)
    , m_renderingMode(renderingMode)
    , m_identifier(identifier)
    , m_renderingBackend(renderingBackend)
    , m_contentsFormat(contentsFormat)
{
}

RemoteGraphicsContextProxy::~RemoteGraphicsContextProxy() = default;

// A message that the GPU process takes in RemoteCGRenderer, its Swift receiver, drawing with the Swift CG renderer, where it
// has one, and in RemoteGraphicsContext otherwise.
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#define SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(name, arguments, swiftArguments) send(Messages::RemoteCGRenderer::name swiftArguments)
#else
#define SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(name, arguments, swiftArguments) send(Messages::RemoteGraphicsContext::name arguments)
#endif
#define SEND_RENDERER_MESSAGE(name, ...) SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(name, (__VA_ARGS__), (__VA_ARGS__))

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
// A color as RemoteCGRenderer takes it: plain values, from which the GPU process rebuilds the same Color.
static CGRendererColorValue rendererColorValue(const Color& color)
{
    CGRendererColorValue value;
    CGRendererColorValueOf(color, value);
    return value;
}

// A shadow and a style as RemoteCGRenderer's SetDropShadow and SetStyle take them: plain values, which the GPU process doesn't
// need to switch on. hasShadow is false for none.
struct RendererShadow {
    CGRendererShadowValues values { };
    CGRendererColorData color { };
    bool hasShadow { false };
};

static RendererShadow rendererShadow(const std::optional<GraphicsDropShadow>& shadow)
{
    RendererShadow result;
    if (shadow) {
        result.hasShadow = true;
        CGRendererShadowValuesOf(*shadow, result.values, result.color);
    }
    return result;
}

struct RendererStyle {
    RemoteCGRendererStyleKind kind { RemoteCGRendererStyleKind::None };
    RendererShadow dropShadow;
    float blurWidth { 0 };
    float blurHeight { 0 };
    std::array<float, 20> colorMatrix { };
};

static RendererStyle rendererStyle(const std::optional<WebCore::GraphicsStyle>& style)
{
    RendererStyle result;
    if (!style)
        return result;
    WTF::switchOn(*style,
        [&](const WebCore::GraphicsDropShadow& shadow) {
            result.kind = RemoteCGRendererStyleKind::DropShadow;
            result.dropShadow = rendererShadow(shadow);
        },
        [&](const WebCore::GraphicsGaussianBlur& blur) {
            result.kind = RemoteCGRendererStyleKind::GaussianBlur;
            result.blurWidth = blur.radius.width();
            result.blurHeight = blur.radius.height();
        },
        [&](const WebCore::GraphicsColorMatrix& matrix) {
            result.kind = RemoteCGRendererStyleKind::ColorMatrix;
            result.colorMatrix = matrix.values;
        });
    return result;
}
#endif

template<typename T>
ALWAYS_INLINE void RemoteGraphicsContextProxy::send(T&& message)
{
    // Buffered line strokes sit in front of the IPC stream; each sender is
    // responsible for calling sendPendingDrawsIfNecessary() before reaching
    // here (see its declaration). This catches a missed call site: the buffer
    // must be empty unless we are sending the batch message itself.
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    ASSERT(m_pendingLineStrokes.isEmpty() || (std::is_same_v<std::decay_t<T>, Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness>));
#else
    ASSERT(m_pendingLineStrokes.isEmpty() || (std::is_same_v<std::decay_t<T>, Messages::RemoteGraphicsContext::StrokeLinesWithColorAndThickness>));
    ASSERT(m_pendingArcStrokes.isEmpty() || (std::is_same_v<std::decay_t<T>, Messages::RemoteGraphicsContext::StrokeArcsWithColorAndThickness>));
#endif
    RefPtr connection = m_connection;
    if (!connection) [[unlikely]] {
        if (RefPtr backend = m_renderingBackend.get())
            connection = backend->connection();
        if (!connection)
            return;
        m_connection = connection;
    }

    if (!m_hasDrawn) {
        if (RefPtr client = m_client.get())
            client->backingStoreWillChange();
        m_hasDrawn = true;
    }
    auto result = connection->send(std::forward<T>(message), m_identifier);
    if (result != IPC::Error::NoError) [[unlikely]] {
        RELEASE_LOG(RemoteLayerBuffers, "RemoteGraphicsContextProxy::send - failed, name:%" PUBLIC_LOG_STRING ", error:%" PUBLIC_LOG_STRING,
            IPC::description(T::name()).characters(), IPC::errorAsString(result).characters());
        didBecomeUnresponsive();
    }
}

void RemoteGraphicsContextProxy::didBecomeUnresponsive() const
{
    RefPtr backend = m_renderingBackend.get();
    if (!backend) [[unlikely]]
        return;
    backend->didBecomeUnresponsive();
}

bool RemoteGraphicsContextProxy::knownToHaveFloatBasedBacking() const
{
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    return m_contentsFormat && *m_contentsFormat == ContentsFormat::RGBA16F;
#else
    return false;
#endif
}

RenderingMode RemoteGraphicsContextProxy::renderingMode() const
{
    return m_renderingMode;
}

void RemoteGraphicsContextProxy::save(GraphicsContextState::Purpose purpose)
{
    sendPendingDrawsIfNecessary();
    updateStateForSave(purpose);
    SEND_RENDERER_MESSAGE(Save);
}

bool RemoteGraphicsContextProxy::restore(GraphicsContextState::Purpose purpose)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForRestore(purpose))
        return false;
    SEND_RENDERER_MESSAGE(Restore);
    return true;
}

void RemoteGraphicsContextProxy::translate(float x, float y)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForTranslate(x, y))
        return;
    SEND_RENDERER_MESSAGE(Translate, x, y);
}

void RemoteGraphicsContextProxy::rotate(float angle)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForRotate(angle))
        return;
    SEND_RENDERER_MESSAGE(Rotate, angle);
}

void RemoteGraphicsContextProxy::scale(const FloatSize& scale)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForScale(scale))
        return;
    SEND_RENDERER_MESSAGE(Scale, scale);
}

void RemoteGraphicsContextProxy::setCTM(const AffineTransform& transform)
{
    sendPendingDrawsIfNecessary();
    updateStateForSetCTM(transform);
    SEND_RENDERER_MESSAGE(SetCTM, m_ctmToRemote * transform);
}

void RemoteGraphicsContextProxy::concatCTM(const AffineTransform& transform)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForConcatCTM(transform))
        return;
    SEND_RENDERER_MESSAGE(ConcatCTM, transform);
}

void RemoteGraphicsContextProxy::saveTransform()
{
    sendPendingDrawsIfNecessary();
    updateStateForSaveTransform();
    SEND_RENDERER_MESSAGE(SaveTransform);
}

bool RemoteGraphicsContextProxy::restoreTransform()
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForRestoreTransform())
        return false;
    SEND_RENDERER_MESSAGE(RestoreTransform);
    return true;
}

void RemoteGraphicsContextProxy::setLineCap(LineCap lineCap)
{
    sendPendingDrawsIfNecessary();
    SEND_RENDERER_MESSAGE(SetLineCap, lineCap);
}

void RemoteGraphicsContextProxy::setLineDash(const DashArray& array, float dashOffset)
{
    sendPendingDrawsIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(SetLineDash, (FixedVector<double>(array.span()), dashOffset), (array.span(), dashOffset));
}

void RemoteGraphicsContextProxy::setLineJoin(LineJoin lineJoin)
{
    sendPendingDrawsIfNecessary();
    SEND_RENDERER_MESSAGE(SetLineJoin, lineJoin);
}

void RemoteGraphicsContextProxy::setMiterLimit(float limit)
{
    sendPendingDrawsIfNecessary();
    SEND_RENDERER_MESSAGE(SetMiterLimit, limit);
}

void RemoteGraphicsContextProxy::clip(const FloatRect& rect)
{
    sendPendingDrawsIfNecessary();
    updateStateForClip(rect);
    SEND_RENDERER_MESSAGE(Clip, rect);
}

void RemoteGraphicsContextProxy::clipRoundedRect(const FloatRoundedRect& rect)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipRoundedRect(rect);
    SEND_RENDERER_MESSAGE(ClipRoundedRect, rect);
}

void RemoteGraphicsContextProxy::clipOut(const FloatRect& rect)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipOut(rect);
    SEND_RENDERER_MESSAGE(ClipOut, rect);
}

void RemoteGraphicsContextProxy::clipOutRoundedRect(const FloatRoundedRect& rect)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipOutRoundedRect(rect);
    SEND_RENDERER_MESSAGE(ClipOutRoundedRect, rect);
}

void RemoteGraphicsContextProxy::clipToNativeImage(const NativeImage& image, const FloatRect& destinationRect)
{
    sendPendingDrawsIfNecessary();
    if (!recordResourceUse(image))
        return;
    updateStateForClipToImage(destinationRect);
    SEND_RENDERER_MESSAGE(ClipToNativeImage, image.renderingResourceIdentifier(), destinationRect);
}

void RemoteGraphicsContextProxy::clipOut(const Path& path)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipOut(path);
    SEND_RENDERER_MESSAGE(ClipOutToPath, path);
}

void RemoteGraphicsContextProxy::clipPath(const Path& path, WindRule rule)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipPath(path);
    if (RefPtr impl = path.asImpl(); impl && !impl->isTransient()) {
        if (auto identifier = recordResourceUse(*impl)) {
            SEND_RENDERER_MESSAGE(ClipCachedPath, *identifier, rule);
            return;
        }
    }

    SEND_RENDERER_MESSAGE(ClipPath, path, rule);
}

void RemoteGraphicsContextProxy::clipTransformedPath(const AffineTransform& pathTransform, const Path& path, WindRule rule)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipTransformedPath(pathTransform, path);
    if (RefPtr impl = path.asImpl(); impl && !impl->isTransient()) {
        if (auto identifier = recordResourceUse(*impl)) {
            SEND_RENDERER_MESSAGE(ClipTransformedCachedPath, pathTransform, *identifier, rule);
            return;
        }
    }

    SEND_RENDERER_MESSAGE(ClipTransformedPath, pathTransform, path, rule);
}

void RemoteGraphicsContextProxy::resetClip()
{
    sendPendingDrawsIfNecessary();
    updateStateForResetClip();
    SEND_RENDERER_MESSAGE(ResetClip);
    clip(initialClip());
}

void RemoteGraphicsContextProxy::drawFilteredImageBuffer(ImageBuffer* sourceImage, const FloatRect& sourceImageRect, Filter& filter, FilterResults& results)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();

    for (auto& effect : filter.effectsOfType(FilterEffect::Type::FEImage)) {
        Ref feImage = downcast<FEImage>(effect.get());
        if (!recordResourceUse(feImage->sourceImage())) {
            GraphicsContext::drawFilteredImageBuffer(sourceImage, sourceImageRect, filter, results);
            return;
        }
    }

    RefPtr svgFilter = dynamicDowncast<SVGFilterRenderer>(filter);
    if (svgFilter && svgFilter->hasValidRenderingResourceIdentifier())
        recordResourceUse(filter);

    std::optional<RenderingResourceIdentifier> identifier;
    if (sourceImage) {
        if (!recordResourceUse(*sourceImage)) {
            GraphicsContext::drawFilteredImageBuffer(sourceImage, sourceImageRect, filter, results);
            return;
        }
        identifier = sourceImage->renderingResourceIdentifier();
    }

    SEND_RENDERER_MESSAGE(DrawFilteredImageBuffer, WTF::move(identifier), sourceImageRect, filter);
}

void RemoteGraphicsContextProxy::drawGlyphs(const Font& font, std::span<const GlyphBufferGlyph> glyphs, std::span<const GlyphBufferAdvance> advances, const FloatPoint& localAnchor, FontSmoothingMode smoothingMode)
{
    if (decomposeDrawGlyphsIfNeeded(font, glyphs, advances, localAnchor, smoothingMode))
        return;
    drawGlyphsImmediate(font, glyphs, advances, localAnchor, smoothingMode);
}

void RemoteGraphicsContextProxy::drawGlyphsImmediate(const FontBase& font, std::span<const GlyphBufferGlyph> glyphs, std::span<const GlyphBufferAdvance> advances, const FloatPoint& localAnchor, FontSmoothingMode smoothingMode)
{
    ASSERT_WITH_SECURITY_IMPLICATION(glyphs.size() == advances.size());
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    recordResourceUse(const_cast<FontBase&>(font));
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    send(Messages::RemoteCGRenderer::DrawGlyphs(font.renderingResourceIdentifier(), { glyphs.data(), advances.data(), std::min(glyphs.size(), advances.size()) }, localAnchor, smoothingMode));
#else
    send(Messages::RemoteGraphicsContext::DrawGlyphs(font.renderingResourceIdentifier(), { glyphs.data(), Vector<FloatSize>(advances).span().data(), glyphs.size() }, localAnchor, smoothingMode));
#endif
}

void RemoteGraphicsContextProxy::drawDisplayList(const DisplayList::DisplayList& displayList, ControlFactory&)
{
    auto identifier = recordResourceUse(displayList);
    if (!identifier)
        return;
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawDisplayList, *identifier);
}

void RemoteGraphicsContextProxy::drawImageBuffer(ImageBuffer& imageBuffer, const FloatRect& destRect, const FloatRect& srcRect, RasterDrawingOptions options)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();

    if (!recordResourceUse(imageBuffer)) {
        GraphicsContext::drawImageBuffer(imageBuffer, destRect, srcRect, options);
        return;
    }

    SEND_RENDERER_MESSAGE(DrawImageBuffer, imageBuffer.renderingResourceIdentifier(), destRect, srcRect, options);
}

void RemoteGraphicsContextProxy::drawNativeImage(const NativeImage& image, const FloatRect& destRect, const FloatRect& srcRect, RasterDrawingOptions options)
{
#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    auto headroom = options.headroom();
    if (headroom == Headroom::FromImage)
        headroom = image.headroom();
    if (m_maxEDRHeadroom) {
        if (*m_maxEDRHeadroom < headroom)
            headroom = Headroom(*m_maxEDRHeadroom);
    }
    m_maxPaintedEDRHeadroom = std::max(m_maxPaintedEDRHeadroom, headroom.headroom);
    m_maxRequestedEDRHeadroom = std::max(m_maxRequestedEDRHeadroom, image.headroom().headroom);
    RasterDrawingOptions clampedOptions(options, headroom);
#endif
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    if (!recordResourceUse(const_cast<NativeImage&>(image)))
        return;
#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    SEND_RENDERER_MESSAGE(DrawNativeImage, image.renderingResourceIdentifier(), destRect, srcRect, clampedOptions);
#else
    SEND_RENDERER_MESSAGE(DrawNativeImage, image.renderingResourceIdentifier(), destRect, srcRect, options);
#endif
}

void RemoteGraphicsContextProxy::drawSystemImage(SystemImage& systemImage, const FloatRect& destinationRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
#if USE(SYSTEM_PREVIEW)
    if (RefPtr badgeSystemImage = dynamicDowncast<ARKitBadgeSystemImage>(systemImage)) {
        std::optional<RenderingResourceIdentifier> renderingResourceIdentifier;

        if (RefPtr nativeImage = badgeSystemImage->nativeImage()) {
            if (!recordResourceUse(*nativeImage))
                return;
            renderingResourceIdentifier = nativeImage->renderingResourceIdentifier();
        }

        SEND_RENDERER_MESSAGE(DrawBadgeSystemImage, renderingResourceIdentifier, destinationRect);
        return;
    }
#endif
    SEND_RENDERER_MESSAGE(DrawSystemImage, systemImage, destinationRect);
}

void RemoteGraphicsContextProxy::drawPattern(const NativeImage& image, const FloatRect& destRect, const FloatRect& tileRect, const AffineTransform& patternTransform, const FloatPoint& phase, const FloatSize& spacing, RasterDrawingOptions options)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    if (!recordResourceUse(const_cast<NativeImage&>(image)))
        return;
    SEND_RENDERER_MESSAGE(DrawPatternNativeImage, image.renderingResourceIdentifier(), destRect, tileRect, patternTransform, phase, spacing, options);
}

void RemoteGraphicsContextProxy::drawPattern(ImageBuffer& imageBuffer, const FloatRect& destRect, const FloatRect& tileRect, const AffineTransform& patternTransform, const FloatPoint& phase, const FloatSize& spacing, RasterDrawingOptions options)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    if (!recordResourceUse(imageBuffer)) {
        GraphicsContext::drawPattern(imageBuffer, destRect, tileRect, patternTransform, phase, spacing, options);
        return;
    }

    SEND_RENDERER_MESSAGE(DrawPatternImageBuffer, imageBuffer.renderingResourceIdentifier(), destRect, tileRect, patternTransform, phase, spacing, options);
}

void RemoteGraphicsContextProxy::beginTransparencyLayer(float opacity)
{
    sendPendingDrawsIfNecessary();
    updateStateForBeginTransparencyLayer(opacity);
    SEND_RENDERER_MESSAGE(BeginTransparencyLayer, opacity);
}

void RemoteGraphicsContextProxy::beginTransparencyLayer(CompositeOperator compositeOperator, BlendMode blendMode)
{
    sendPendingDrawsIfNecessary();
    updateStateForBeginTransparencyLayer(compositeOperator, blendMode);
    SEND_RENDERER_MESSAGE(BeginTransparencyLayerWithCompositeMode, CompositeMode { compositeOperator, blendMode });
}

void RemoteGraphicsContextProxy::endTransparencyLayer()
{
    sendPendingDrawsIfNecessary();
    if (updateStateForEndTransparencyLayer())
        SEND_RENDERER_MESSAGE(EndTransparencyLayer);
}

void RemoteGraphicsContextProxy::drawRect(const FloatRect& rect, float width)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawRect, rect, width);
}

void RemoteGraphicsContextProxy::drawLine(const FloatPoint& point1, const FloatPoint& point2)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawLine, point1, point2);
}

void RemoteGraphicsContextProxy::drawLinesForText(const FloatPoint& point, float thickness, std::span<const FloatSegment> lineSegments, bool printing, bool doubleLines, StrokeStyle style)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawLinesForText, point, thickness, lineSegments, printing, doubleLines, style);
}

void RemoteGraphicsContextProxy::drawDotsForDocumentMarker(const FloatRect& rect, DocumentMarkerLineStyle style)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(DrawDotsForDocumentMarker, (rect, style), (rect, style.mode, rendererColorValue(style.color)));
}

void RemoteGraphicsContextProxy::drawMeshGradient(MeshGradient& gradient, const FloatRect& destination)
{
    auto identifier = recordResourceUse(gradient);
    if (!identifier)
        return;

    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawMeshGradient, *identifier, destination);
}

void RemoteGraphicsContextProxy::drawEllipse(const FloatRect& rect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawEllipse, rect);
}

void RemoteGraphicsContextProxy::drawPath(const Path& path)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawPath, path);
}

void RemoteGraphicsContextProxy::drawFocusRing(const Path& path, float outlineWidth, const Color& color, float zoomFactor)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(DrawFocusRingPath, (path, outlineWidth, color, zoomFactor), (path, outlineWidth, rendererColorValue(color), zoomFactor));
}

void RemoteGraphicsContextProxy::drawFocusRing(const Vector<FloatRect>& rects, float outlineWidth, const Color& color, float zoomFactor)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // RemoteCGRenderer draws the focus ring of the path of the rects, as GraphicsContextCG does.
    Path path;
    for (auto& rect : rects)
        path.addRect(rect);
    send(Messages::RemoteCGRenderer::DrawFocusRingPath(path, outlineWidth, rendererColorValue(color), zoomFactor));
#else
    send(Messages::RemoteGraphicsContext::DrawFocusRingRects(rects, outlineWidth, color, zoomFactor));
#endif
}

void RemoteGraphicsContextProxy::fillPath(const Path& path)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();

    if (auto segment = path.singleSegment()) {
        WTF::switchOn(segment->data(),
        [&](const PathArc &arc) {
            SEND_RENDERER_MESSAGE(FillArc, arc);
        },
        [&](const PathClosedArc& closedArc) {
            SEND_RENDERER_MESSAGE(FillClosedArc, closedArc);
        },
        [&](const PathDataLine& line) {
            SEND_RENDERER_MESSAGE(FillLine, line);
        },
        [&](const PathDataQuadCurve& curve) {
            SEND_RENDERER_MESSAGE(FillQuadCurve, curve);
        },
        [&](const PathDataBezierCurve& curve) {
            SEND_RENDERER_MESSAGE(FillBezierCurve, curve);
        },
        [&](auto&&) {
            SEND_RENDERER_MESSAGE(FillPathSegment, *segment);
        });
        return;
    }

    if (RefPtr impl = path.asImpl(); impl && !impl->isTransient()) {
        if (auto identifier = recordResourceUse(*impl)) {
            SEND_RENDERER_MESSAGE(FillCachedPath, *identifier);
            return;
        }
    }

    SEND_RENDERER_MESSAGE(FillPath, path);
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, RequiresClipToRect requiresClipToRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(FillRect, rect, requiresClipToRect);
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, const Color& color)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(FillRectWithColor, (rect, color), (rect, rendererColorValue(color)));
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, const Gradient& gradient)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (auto identifier = recordResourceUse(gradient))
        send(Messages::RemoteCGRenderer::FillRectWithCachedGradient(rect, *identifier));
#else
    send(Messages::RemoteGraphicsContext::FillRectWithGradient(rect, gradient));
#endif
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, const Gradient& gradient, const AffineTransform& gradientSpaceTransform, RequiresClipToRect requiresClipToRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (auto identifier = recordResourceUse(gradient))
        send(Messages::RemoteCGRenderer::FillRectWithCachedGradientAndSpaceTransform(rect, *identifier, gradientSpaceTransform, requiresClipToRect));
#else
    send(Messages::RemoteGraphicsContext::FillRectWithGradientAndSpaceTransform(rect, gradient, gradientSpaceTransform, requiresClipToRect));
#endif
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, const Color& color, CompositeOperator op, BlendMode mode)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(FillCompositedRect, (rect, color, op, mode), (rect, rendererColorValue(color), op, mode));
}

void RemoteGraphicsContextProxy::fillRoundedRect(const FloatRoundedRect& roundedRect, const Color& color, BlendMode mode)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(FillRoundedRect, (roundedRect, color, mode), (roundedRect, rendererColorValue(color), mode));
}

void RemoteGraphicsContextProxy::fillRectWithRoundedHole(const FloatRect& rect, const FloatRoundedRect& roundedRect, const Color& color)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(FillRectWithRoundedHole, (rect, roundedRect, color), (rect, roundedRect, rendererColorValue(color)));
}

void RemoteGraphicsContextProxy::fillEllipse(const FloatRect& rect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(FillEllipse, rect);
}

#if ENABLE(VIDEO)
void RemoteGraphicsContextProxy::drawVideoFrame(const VideoFrame& frame, const FloatRect& destination, ShouldDiscardAlpha shouldDiscardAlpha, RasterDrawingOptions options)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
#if PLATFORM(COCOA)
    RefPtr backend = m_renderingBackend;
    RefPtr gpuProcessIPCConnection = backend ? backend->gpuProcessIPCConnection() : nullptr;
    if (!gpuProcessIPCConnection)
        return;

    Locker locker { m_sharedVideoFrameWriterLock };
    if (!m_sharedVideoFrameWriter)
        m_sharedVideoFrameWriter = makeUnique<SharedVideoFrameWriter>();

    auto sharedVideoFrame = m_sharedVideoFrameWriter->write(frame, *gpuProcessIPCConnection, [&](auto& semaphore) {
        SEND_RENDERER_MESSAGE(SetSharedVideoFrameSemaphore, semaphore);
    }, [&](SharedMemory::Handle&& handle) {
        SEND_RENDERER_MESSAGE(SetSharedVideoFrameMemory, WTF::move(handle));
    });
    if (!sharedVideoFrame)
        return;
    SEND_RENDERER_MESSAGE(DrawVideoFrame, WTF::move(*sharedVideoFrame), destination, shouldDiscardAlpha, options);
#endif
}
#endif

void RemoteGraphicsContextProxy::strokePath(const Path& path)
{
    if (const auto* segment = path.singleSegmentIfExists()) {
        if (const auto* line = std::get_if<PathDataLine>(&segment->data())) {
            if (auto inlineStroke = inlineStrokeStateIfBatchable()) {
                bufferLine(*line, *inlineStroke);
                return;
            }
            // Non-stroke state is pending, or this is a gradient/pattern stroke:
            // emit the batch so far and the new state, then draw the line alone.
            sendPendingDrawsIfNecessary();
            appendStateChangeItemIfNecessary();
            SEND_RENDERER_MESSAGE(StrokeLine, *line);
            return;
        }
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
        if (const auto* arc = std::get_if<PathArc>(&segment->data())) {
            if (auto inlineStroke = inlineStrokeStateIfBatchable()) {
                bufferArc(*arc, *inlineStroke);
                return;
            }
            sendPendingDrawsIfNecessary();
            appendStateChangeItemIfNecessary();
            send(Messages::RemoteGraphicsContext::StrokeArc(*arc));
            return;
        }
#endif
        sendPendingDrawsIfNecessary();
        appendStateChangeItemIfNecessary();
        WTF::switchOn(segment->data(),
            [&](const PathArc &arc) {
                SEND_RENDERER_MESSAGE(StrokeArc, arc);
            },
            [&](const PathClosedArc& closedArc) {
                SEND_RENDERER_MESSAGE(StrokeClosedArc, closedArc);
            },
            [&](const PathDataLine& line) {
                SEND_RENDERER_MESSAGE(StrokeLine, line);
            },
            [&](const PathDataQuadCurve& curve) {
                SEND_RENDERER_MESSAGE(StrokeQuadCurve, curve);
            },
            [&](const PathDataBezierCurve& curve) {
                SEND_RENDERER_MESSAGE(StrokeBezierCurve, curve);
            },
            [&](auto&&) {
                SEND_RENDERER_MESSAGE(StrokePathSegment, *segment);
            });
        return;
    }
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(StrokePath, path);
}

void RemoteGraphicsContextProxy::strokeRect(const FloatRect& rect, float width)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(StrokeRect, rect, width);
}

void RemoteGraphicsContextProxy::strokeEllipse(const FloatRect& rect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(StrokeEllipse, rect);
}

void RemoteGraphicsContextProxy::bufferLine(const PathDataLine& line, const InlineStrokeData& strokeData)
{
    if (!m_pendingArcStrokes.isEmpty())
        sendPendingDraws();

    if (!m_pendingLineStrokes.capacity())
        m_pendingLineStrokes.reserveInitialCapacity(maxPendingLineStrokes);

    m_pendingLineStrokes.append({ line, strokeData.color, strokeData.thickness });

    if (m_pendingLineStrokes.size() >= maxPendingLineStrokes)
        sendPendingDraws();
}

void RemoteGraphicsContextProxy::bufferArc(const PathArc& arc, const InlineStrokeData& strokeData)
{
    if (!m_pendingLineStrokes.isEmpty())
        sendPendingDraws();

    if (!m_pendingArcStrokes.capacity())
        m_pendingArcStrokes.reserveInitialCapacity(maxPendingArcStrokes);

    m_pendingArcStrokes.append({ arc.center, arc.radius, arc.startAngle, arc.endAngle, strokeData.color, strokeData.thickness, arc.direction == RotationDirection::Clockwise ? 1u : 0u });

    if (m_pendingArcStrokes.size() >= maxPendingArcStrokes)
        sendPendingDraws();
}

void RemoteGraphicsContextProxy::sendPendingDraws()
{
    ASSERT(m_pendingLineStrokes.isEmpty() || m_pendingArcStrokes.isEmpty());

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    send(Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness(m_pendingLineStrokes.span()));
    m_pendingLineStrokes.shrink(0);
#else
    if (!m_pendingLineStrokes.isEmpty()) {
        send(Messages::RemoteGraphicsContext::StrokeLinesWithColorAndThickness(m_pendingLineStrokes.span()));
        m_pendingLineStrokes.shrink(0);
    }

    if (!m_pendingArcStrokes.isEmpty()) {
        send(Messages::RemoteGraphicsContext::StrokeArcsWithColorAndThickness(m_pendingArcStrokes.span()));
        m_pendingArcStrokes.shrink(0);
    }
#endif
}

void RemoteGraphicsContextProxy::clearRect(const FloatRect& rect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(ClearRect, rect);
}

void RemoteGraphicsContextProxy::drawControlPart(ControlPart& part, const FloatRoundedRect& borderRect, float deviceScaleFactor, const ControlStyle& style)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(DrawControlPart, part, borderRect, deviceScaleFactor, style);
}

void RemoteGraphicsContextProxy::applyDeviceScaleFactor(float scaleFactor)
{
    sendPendingDrawsIfNecessary();
    updateStateForApplyDeviceScaleFactor(scaleFactor);
    SEND_RENDERER_MESSAGE(ApplyDeviceScaleFactor, scaleFactor);
}

void RemoteGraphicsContextProxy::beginPage(const FloatRect& pageRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(BeginPage, pageRect);
    updateStateForBeginPage();
}

void RemoteGraphicsContextProxy::endPage()
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(EndPage);
}

void RemoteGraphicsContextProxy::setURLForRect(const URL& link, const FloatRect& destRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(SetURLForRect, link, destRect);
}

bool RemoteGraphicsContextProxy::recordResourceUse(const NativeImage& image)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return false;
    }

    auto colorSpace = image.colorSpace();

    if (image.headroom() > Headroom::None) {
#if ENABLE(PIXEL_FORMAT_RGBA16F) && USE(CG)
        // The image will be drawn to a Float16 layer, so use extended range sRGB
        // to preserve the HDR contents.
        if (m_contentsFormat && *m_contentsFormat == ContentsFormat::RGBA16F)
            colorSpace = ColorSpace::ExtendedSRGB();
        else
#endif
#if PLATFORM(IOS_FAMILY)
            // iOS typically renders into extended range sRGB to preserve wide gamut colors, but we want
            // a non-extended range colorspace here so that the contents are tone mapped to SDR range.
            colorSpace = ColorSpace::DisplayP3();
#else
            colorSpace = ColorSpace::SRGB();
#endif
    }

    return renderingBackend->remoteResourceCacheProxy().recordNativeImageUse(image, colorSpace);
}

bool RemoteGraphicsContextProxy::recordResourceUse(ImageBuffer& imageBuffer)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return false;
    }
    RefPtr cachedImageBuffer = renderingBackend->cachedImageBuffer(imageBuffer);
    if (!cachedImageBuffer)
        return false;
    // This draw consumes the source buffer's contents, so its buffered line
    // strokes must reach the GPU process first.
    cachedImageBuffer->sendPendingDrawsIfNecessary();
    return true;
}

bool RemoteGraphicsContextProxy::recordResourceUse(const SourceImage& image)
{
    if (RefPtr imageBuffer = image.imageBufferIfExists())
        return recordResourceUse(*imageBuffer);

    if (RefPtr nativeImage = image.nativeImageIfExists())
        return recordResourceUse(*nativeImage);

    return true;
}

bool RemoteGraphicsContextProxy::recordResourceUse(FontBase& font)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return false;
    }

    renderingBackend->remoteResourceCacheProxy().recordFontUse(font);
    return true;
}

std::optional<RemoteGradientIdentifier> RemoteGraphicsContextProxy::recordResourceUse(const Gradient& gradient)
{
    // RemoteCGRenderer takes every gradient from the resource cache, and RemoteGraphicsContext a transient one inline.
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (gradient.isTransient())
        return std::nullopt;
#endif
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return std::nullopt;
    }

    return renderingBackend->remoteResourceCacheProxy().recordGradientUse(gradient);
}

std::optional<RemoteMeshGradientIdentifier> RemoteGraphicsContextProxy::recordResourceUse(MeshGradient& gradient)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return std::nullopt;
    }

    return renderingBackend->remoteResourceCacheProxy().recordMeshGradientUse(gradient);
}

std::optional<RemotePathImplIdentifier> RemoteGraphicsContextProxy::recordResourceUse(const WebCore::PathImpl& path)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return std::nullopt;
    }

    return renderingBackend->remoteResourceCacheProxy().recordPathImplUse(path);
}

bool RemoteGraphicsContextProxy::recordResourceUse(Filter& filter)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return false;
    }

    renderingBackend->remoteResourceCacheProxy().recordFilterUse(filter);
    return true;
}

std::optional<RemoteDisplayListIdentifier> RemoteGraphicsContextProxy::recordResourceUse(const DisplayList::DisplayList& displayList)
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return { };
    }
    return renderingBackend->remoteResourceCacheProxy().recordDisplayListUse(displayList);
}

RefPtr<ImageBuffer> RemoteGraphicsContextProxy::createImageBuffer(const FloatSize& size, float resolutionScale, const ColorSpace& colorSpace, std::optional<RenderingMode> renderingMode, std::optional<RenderingMethod> renderingMethod, WebCore::ImageBufferFormat pixelFormat) const
{
    RefPtr renderingBackend = m_renderingBackend.get();
    if (!renderingBackend) [[unlikely]] {
        ASSERT_NOT_REACHED();
        return nullptr;
    }

    if (renderingMethod)
        return Recorder::createImageBuffer(size, resolutionScale, colorSpace, renderingMode, renderingMethod);

    // FIXME: Ideally we'd plumb the purpose through for callers of GraphicsContext::createImageBuffer().
    RenderingPurpose purpose = RenderingPurpose::Unspecified;
    return renderingBackend->createImageBuffer(size, renderingMode.value_or(this->renderingModeForCompatibleBuffer()), purpose, resolutionScale, colorSpace, pixelFormat);
}

RefPtr<ImageBuffer> RemoteGraphicsContextProxy::createAlignedImageBuffer(const FloatSize& size, const ColorSpace& colorSpace, std::optional<RenderingMethod> renderingMethod) const
{
    auto renderingMode = !renderingMethod ? this->renderingModeForCompatibleBuffer() : RenderingMode::Unaccelerated;
    return GraphicsContext::createScaledImageBuffer(size, scaleFactor(), colorSpace, renderingMode, renderingMethod);
}

RefPtr<ImageBuffer> RemoteGraphicsContextProxy::createAlignedImageBuffer(const FloatRect& rect, const ColorSpace& colorSpace, std::optional<RenderingMethod> renderingMethod) const
{
    auto renderingMode = !renderingMethod ? this->renderingModeForCompatibleBuffer() : RenderingMode::Unaccelerated;
    return GraphicsContext::createScaledImageBuffer(rect, scaleFactor(), colorSpace, renderingMode, renderingMethod);
}

void RemoteGraphicsContextProxy::appendStateChangeItemIfNecessary()
{
    auto& state = m_state;
    auto pendingChanges = computeStateChanges();
    if (!pendingChanges)
        return;
    auto changes = pendingChanges;
    if (changes.contains(GraphicsContextState::Change::FillBrush)) {
        const auto& fillBrush = state.fillBrush();
        if (auto packedColor = fillBrush.packedColor())
            SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(SetFillPackedColor, (*packedColor), (packedColor->value));
        else if (RefPtr pattern = fillBrush.pattern()) {
            if (RefPtr image = pattern->tileNativeImage()) {
                if (recordResourceUse(*image))
                    SEND_RENDERER_MESSAGE(SetFillPatternNativeImage, image->renderingResourceIdentifier(), pattern->parameters());
            } else if (RefPtr buffer = pattern->tileImageBuffer()) {
                if (recordResourceUse(*buffer))
                    SEND_RENDERER_MESSAGE(SetFillPatternImageBuffer, buffer->renderingResourceIdentifier(), pattern->parameters());
            }
        } else if (RefPtr gradient = fillBrush.gradient()) {
            if (auto identifier = recordResourceUse(*gradient))
                SEND_RENDERER_MESSAGE(SetFillCachedGradient, *identifier, fillBrush.gradientSpaceTransform());
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
            else
                send(Messages::RemoteGraphicsContext::SetFillGradient(*gradient, fillBrush.gradientSpaceTransform()));
#endif
        } else
            SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(SetFillColor, (fillBrush.color()), (rendererColorValue(fillBrush.color())));
    }
    if (changes.contains(GraphicsContextState::Change::StrokeBrush)) {
        const auto& strokeBrush = state.strokeBrush();
        if (auto packedColor = strokeBrush.packedColor()) {
            if (changes.contains(GraphicsContextState::Change::StrokeThickness)) {
                SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(SetStrokePackedColorAndThickness, (*packedColor, state.strokeThickness()), (packedColor->value, state.strokeThickness()));
                changes.remove(GraphicsContextState::Change::StrokeThickness);
            } else
                SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(SetStrokePackedColor, (*packedColor), (packedColor->value));
        } else if (RefPtr pattern = strokeBrush.pattern()) {
            if (RefPtr image = pattern->tileNativeImage()) {
                if (recordResourceUse(*image))
                    SEND_RENDERER_MESSAGE(SetStrokePatternNativeImage, image->renderingResourceIdentifier(), pattern->parameters());
            } else if (RefPtr buffer = pattern->tileImageBuffer()) {
                if (recordResourceUse(*buffer))
                    SEND_RENDERER_MESSAGE(SetStrokePatternImageBuffer, buffer->renderingResourceIdentifier(), pattern->parameters());
            }
        } else if (RefPtr gradient = strokeBrush.gradient()) {
            if (auto identifier = recordResourceUse(*gradient))
                SEND_RENDERER_MESSAGE(SetStrokeCachedGradient, *identifier, strokeBrush.gradientSpaceTransform());
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
            else
                send(Messages::RemoteGraphicsContext::SetStrokeGradient(*gradient, strokeBrush.gradientSpaceTransform()));
#endif
        } else
            SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(SetStrokeColor, (strokeBrush.color()), (rendererColorValue(strokeBrush.color())));
    }
    if (changes.contains(GraphicsContextState::Change::FillRule))
        SEND_RENDERER_MESSAGE(SetFillRule, state.fillRule());
    if (changes.contains(GraphicsContextState::Change::StrokeThickness))
        SEND_RENDERER_MESSAGE(SetStrokeThickness, state.strokeThickness());
    if (changes.contains(GraphicsContextState::Change::StrokeStyle))
        SEND_RENDERER_MESSAGE(SetStrokeStyle, state.strokeStyle());
    if (changes.contains(GraphicsContextState::Change::CompositeMode))
        SEND_RENDERER_MESSAGE(SetCompositeMode, state.compositeMode());
    // Note: due to bugs in GraphicsContext interface and GraphicsContextCG, we have to send ShadowsIgnoreTransforms
    // before the DropShadow and Style.
    if (changes.contains(GraphicsContextState::Change::ShadowsIgnoreTransforms))
        SEND_RENDERER_MESSAGE(SetShadowsIgnoreTransforms, state.shadowsIgnoreTransforms());
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (changes.contains(GraphicsContextState::Change::DropShadow)) {
        auto shadow = rendererShadow(state.dropShadow());
        send(Messages::RemoteCGRenderer::SetDropShadow(shadow.values, shadow.color, shadow.hasShadow));
    }
    if (changes.contains(GraphicsContextState::Change::Style)) {
        auto style = rendererStyle(state.style());
        send(Messages::RemoteCGRenderer::SetStyle(style.kind, style.dropShadow.values, style.dropShadow.color, style.dropShadow.hasShadow, style.blurWidth, style.blurHeight, style.colorMatrix));
    }
#else
    if (changes.contains(GraphicsContextState::Change::DropShadow))
        SEND_RENDERER_MESSAGE(SetDropShadow, state.dropShadow());
    if (changes.contains(GraphicsContextState::Change::Style))
        SEND_RENDERER_MESSAGE(SetStyle, state.style());
#endif
    if (changes.contains(GraphicsContextState::Change::Alpha))
        SEND_RENDERER_MESSAGE(SetAlpha, state.alpha());
    if (changes.contains(GraphicsContextState::Change::TextDrawingMode))
        SEND_RENDERER_MESSAGE(SetTextDrawingMode, state.textDrawingMode());
    if (changes.contains(GraphicsContextState::Change::ImageInterpolationQuality))
        SEND_RENDERER_MESSAGE(SetImageInterpolationQuality, state.imageInterpolationQuality());
    if (changes.contains(GraphicsContextState::Change::ShouldAntialias))
        SEND_RENDERER_MESSAGE(SetShouldAntialias, state.shouldAntialias());
    if (changes.contains(GraphicsContextState::Change::ShouldSmoothFonts))
        SEND_RENDERER_MESSAGE(SetShouldSmoothFonts, state.shouldSmoothFonts());
    if (changes.contains(GraphicsContextState::Change::ShouldSubpixelQuantizeFonts))
        SEND_RENDERER_MESSAGE(SetShouldSubpixelQuantizeFonts, state.shouldSubpixelQuantizeFonts());

    commitStateChanges(pendingChanges);
}

std::optional<RemoteGraphicsContextProxy::InlineStrokeData> RemoteGraphicsContextProxy::inlineStrokeStateIfBatchable()
{
    auto& state = m_state;
    auto changes = computeStateChanges();
    // Only fold the line into the batch if the sole pending state changes are
    // stroke color and/or thickness; anything else has to go through the normal
    // state-flush path.
    if (changes && !changes.containsOnly({ GraphicsContextState::Change::StrokeBrush, GraphicsContextState::Change::StrokeThickness }))
        return std::nullopt;

    auto packedColor = state.strokeBrush().packedColor();
    if (!packedColor)
        return std::nullopt; // Gradient/pattern stroke: not representable inline.

    if (changes) {
        // The stroke color and thickness travel inline with each buffered line. The GPU process
        // applies them with setStrokeColor()/setStrokeThickness(), which replace the whole brush, so
        // this is exactly the same state change the normal flush path would have made.
        commitStateChanges(changes);
    }
    return InlineStrokeData { *packedColor, state.strokeThickness() };
}

void RemoteGraphicsContextProxy::disconnect()
{
    m_connection = nullptr;
#if PLATFORM(COCOA) && ENABLE(VIDEO)
    Locker locker { m_sharedVideoFrameWriterLock };
    if (m_sharedVideoFrameWriter) {
        m_sharedVideoFrameWriter->disable();
        m_sharedVideoFrameWriter = nullptr;
    }
#endif
}

void RemoteGraphicsContextProxy::abandon()
{
    disconnect();
    m_renderingBackend = nullptr;
}

// Instantiate the send() helper for the few subclass messages here to avoid listing it in the header.
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
template void RemoteGraphicsContextProxy::send<Messages::RemoteCGRenderer::DrawSnapshotFrame>(Messages::RemoteCGRenderer::DrawSnapshotFrame&&);
#else
template void RemoteGraphicsContextProxy::send<Messages::RemoteSnapshotRecorder::DrawSnapshotFrame>(Messages::RemoteSnapshotRecorder::DrawSnapshotFrame&&);
#endif

}

#undef SEND_RENDERER_MESSAGE
#undef SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS

#endif
