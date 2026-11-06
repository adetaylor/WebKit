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
#include "RemoteGraphicsContextMessages.h"
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteCGRendererLineStrokes.h"
#include "RemoteCGRendererMessages.h"
#include "RemoteCGRendererPath.h"
#include "RemoteCGRendererPathSegment.h"
#endif
#include "RemoteImageBufferProxy.h"
#include "RemoteRenderingBackendProxy.h"
#include "RemoteSnapshotRecorderMessages.h"
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
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    m_drawsWithCGRendererReceiver = true;
#endif
}

RemoteGraphicsContextProxy::RemoteGraphicsContextProxy(const FloatRect& initialClip, const AffineTransform& initialCTM, const ColorSpace& colorSpace, WebCore::ContentsFormat contentsFormat, RenderingMode renderingMode, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackendProxy& renderingBackend)
    : RemoteGraphicsContextProxy({ }, initialClip, initialCTM, colorSpace, DrawGlyphsMode::Deconstruct, contentsFormat, renderingMode, identifier, renderingBackend)
{
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    m_drawsWithCGRendererReceiver = true;
#endif
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

// A message that an image buffer's context takes in RemoteCGRenderer (the GPU process's Swift receiver, drawing with the Swift
// CG renderer), and any other context in RemoteGraphicsContext.
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#define SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(name, arguments, swiftArguments) do { \
        if (m_drawsWithCGRendererReceiver) \
            send(Messages::RemoteCGRenderer::name swiftArguments); \
        else \
            send(Messages::RemoteGraphicsContext::name arguments); \
    } while (0)
#else
#define SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(name, arguments, swiftArguments) send(Messages::RemoteGraphicsContext::name arguments)
#endif
#define SEND_RENDERER_MESSAGE(name, ...) SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(name, (__VA_ARGS__), (__VA_ARGS__))

template<typename T>
ALWAYS_INLINE void RemoteGraphicsContextProxy::send(T&& message)
{
    // Buffered line strokes sit in front of the IPC stream; each sender is
    // responsible for calling sendPendingDrawsIfNecessary() before reaching
    // here (see its declaration). This catches a missed call site: the buffer
    // must be empty unless we are sending the batch message itself.
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    ASSERT(m_pendingLineStrokes.isEmpty() || (std::is_same_v<std::decay_t<T>, Messages::RemoteGraphicsContext::StrokeLinesWithColorAndThickness>) || (std::is_same_v<std::decay_t<T>, Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness>));
#else
    ASSERT(m_pendingLineStrokes.isEmpty() || (std::is_same_v<std::decay_t<T>, Messages::RemoteGraphicsContext::StrokeLinesWithColorAndThickness>));
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

void RemoteGraphicsContextProxy::restore(GraphicsContextState::Purpose purpose)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForRestore(purpose))
        return;
    SEND_RENDERER_MESSAGE(Restore);
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
    SEND_RENDERER_MESSAGE(SetCTM, transform);
}

void RemoteGraphicsContextProxy::concatCTM(const AffineTransform& transform)
{
    sendPendingDrawsIfNecessary();
    if (!updateStateForConcatCTM(transform))
        return;
    SEND_RENDERER_MESSAGE(ConcatCTM, transform);
}

void RemoteGraphicsContextProxy::setLineCap(LineCap lineCap)
{
    sendPendingDrawsIfNecessary();
    SEND_RENDERER_MESSAGE(SetLineCap, lineCap);
}

void RemoteGraphicsContextProxy::setLineDash(const DashArray& array, float dashOffset)
{
    sendPendingDrawsIfNecessary();
    send(Messages::RemoteGraphicsContext::SetLineDash(FixedVector<double>(array.span()), dashOffset));
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
    send(Messages::RemoteGraphicsContext::ClipRoundedRect(rect));
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
    send(Messages::RemoteGraphicsContext::ClipOutRoundedRect(rect));
}

void RemoteGraphicsContextProxy::clipToNativeImage(const NativeImage& image, const FloatRect& destinationRect)
{
    sendPendingDrawsIfNecessary();
    if (!recordResourceUse(image))
        return;
    updateStateForClipToImage(destinationRect);
    send(Messages::RemoteGraphicsContext::ClipToNativeImage(image.renderingResourceIdentifier(), destinationRect));
}

void RemoteGraphicsContextProxy::clipOut(const Path& path)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipOut(path);
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(ClipOutToPath, (path), (RemoteCGRendererPath { path }));
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

    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(ClipPath, (path, rule), (RemoteCGRendererPath { path }, rule));
}

void RemoteGraphicsContextProxy::clipTransformedPath(const AffineTransform& pathTransform, const Path& path, WindRule rule)
{
    sendPendingDrawsIfNecessary();
    updateStateForClipTransformedPath(pathTransform, path);
    if (RefPtr impl = path.asImpl(); impl && !impl->isTransient()) {
        if (auto identifier = recordResourceUse(*impl)) {
            send(Messages::RemoteGraphicsContext::ClipTransformedCachedPath(pathTransform, *identifier, rule));
            return;
        }
    }

    send(Messages::RemoteGraphicsContext::ClipTransformedPath(pathTransform, path, rule));
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

    send(Messages::RemoteGraphicsContext::DrawFilteredImageBuffer(WTF::move(identifier), sourceImageRect, filter));
}

void RemoteGraphicsContextProxy::drawGlyphs(const Font& font, std::span<const GlyphBufferGlyph> glyphs, std::span<const GlyphBufferAdvance> advances, const FloatPoint& localAnchor, FontSmoothingMode smoothingMode)
{
    if (decomposeDrawGlyphsIfNeeded(font, glyphs, advances, localAnchor, smoothingMode))
        return;
    drawGlyphsImmediate(font, glyphs, advances, localAnchor, smoothingMode);
}

void RemoteGraphicsContextProxy::drawGlyphsImmediate(const FontBase& font, std::span<const GlyphBufferGlyph> glyphs, std::span<const GlyphBufferAdvance> advances, const FloatPoint& localAnchor, FontSmoothingMode smoothingMode)
{
    ASSERT(glyphs.size() == advances.size());
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    recordResourceUse(const_cast<FontBase&>(font));
    send(Messages::RemoteGraphicsContext::DrawGlyphs(font.renderingResourceIdentifier(), { glyphs.data(), Vector<FloatSize>(advances).span().data(), glyphs.size() }, localAnchor, smoothingMode));
}

void RemoteGraphicsContextProxy::drawDisplayList(const DisplayList::DisplayList& displayList, ControlFactory&)
{
    auto identifier = recordResourceUse(displayList);
    if (!identifier)
        return;
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::DrawDisplayList(*identifier));
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

        send(Messages::RemoteGraphicsContext::DrawBadgeSystemImage(renderingResourceIdentifier, destinationRect));
        return;
    }
#endif
    send(Messages::RemoteGraphicsContext::DrawSystemImage(systemImage, destinationRect));
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
    send(Messages::RemoteGraphicsContext::BeginTransparencyLayer(opacity));
}

void RemoteGraphicsContextProxy::beginTransparencyLayer(CompositeOperator compositeOperator, BlendMode blendMode)
{
    sendPendingDrawsIfNecessary();
    updateStateForBeginTransparencyLayer(compositeOperator, blendMode);
    send(Messages::RemoteGraphicsContext::BeginTransparencyLayerWithCompositeMode({ compositeOperator, blendMode }));
}

void RemoteGraphicsContextProxy::endTransparencyLayer()
{
    sendPendingDrawsIfNecessary();
    if (updateStateForEndTransparencyLayer())
        send(Messages::RemoteGraphicsContext::EndTransparencyLayer());
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
    send(Messages::RemoteGraphicsContext::DrawLinesForText(point, thickness, lineSegments, printing, doubleLines, style));
}

void RemoteGraphicsContextProxy::drawDotsForDocumentMarker(const FloatRect& rect, DocumentMarkerLineStyle style)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::DrawDotsForDocumentMarker(rect, style));
}

void RemoteGraphicsContextProxy::drawMeshGradient(MeshGradient& gradient, const FloatRect& destination)
{
    auto identifier = recordResourceUse(gradient);
    if (!identifier)
        return;

    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::DrawMeshGradient(*identifier, destination));
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
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(DrawPath, (path), (RemoteCGRendererPath { path }));
}

void RemoteGraphicsContextProxy::drawFocusRing(const Path& path, float outlineWidth, const Color& color, float zoomFactor)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::DrawFocusRingPath(path, outlineWidth, color, zoomFactor));
}

void RemoteGraphicsContextProxy::drawFocusRing(const Vector<FloatRect>& rects, float outlineWidth, const Color& color, float zoomFactor)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::DrawFocusRingRects(rects, outlineWidth, color, zoomFactor));
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
            SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(FillPathSegment, (*segment), (RemoteCGRendererPathSegment { *segment }));
        });
        return;
    }

    if (RefPtr impl = path.asImpl(); impl && !impl->isTransient()) {
        if (auto identifier = recordResourceUse(*impl)) {
            SEND_RENDERER_MESSAGE(FillCachedPath, *identifier);
            return;
        }
    }

    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(FillPath, (path), (RemoteCGRendererPath { path }));
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
    send(Messages::RemoteGraphicsContext::FillRectWithColor(rect, color));
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, Gradient& gradient)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::FillRectWithGradient(rect, gradient));
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, Gradient& gradient, const AffineTransform& gradientSpaceTransform, RequiresClipToRect requiresClipToRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::FillRectWithGradientAndSpaceTransform(rect, gradient, gradientSpaceTransform, requiresClipToRect));
}

void RemoteGraphicsContextProxy::fillRect(const FloatRect& rect, const Color& color, CompositeOperator op, BlendMode mode)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::FillCompositedRect(rect, color, op, mode));
}

void RemoteGraphicsContextProxy::fillRoundedRect(const FloatRoundedRect& roundedRect, const Color& color, BlendMode mode)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::FillRoundedRect(roundedRect, color, mode));
}

void RemoteGraphicsContextProxy::fillRectWithRoundedHole(const FloatRect& rect, const FloatRoundedRect& roundedRect, const Color& color)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::FillRectWithRoundedHole(rect, roundedRect, color));
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
        send(Messages::RemoteGraphicsContext::SetSharedVideoFrameSemaphore { semaphore });
    }, [&](SharedMemory::Handle&& handle) {
        send(Messages::RemoteGraphicsContext::SetSharedVideoFrameMemory { WTF::move(handle) });
    });
    if (!sharedVideoFrame)
        return;
    send(Messages::RemoteGraphicsContext::DrawVideoFrame(WTF::move(*sharedVideoFrame), destination, shouldDiscardAlpha, options));
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
                SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(StrokePathSegment, (*segment), (RemoteCGRendererPathSegment { *segment }));
            });
        return;
    }
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS(StrokePath, (path), (RemoteCGRendererPath { path }));
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
    if (!m_pendingLineStrokes.capacity())
        m_pendingLineStrokes.reserveInitialCapacity(maxPendingLineStrokes);

    m_pendingLineStrokes.append({ line, strokeData.color, strokeData.thickness });

    if (m_pendingLineStrokes.size() >= maxPendingLineStrokes)
        sendPendingDraws();
}

void RemoteGraphicsContextProxy::sendPendingDraws()
{
    if (m_pendingLineStrokes.isEmpty())
        return;

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (m_drawsWithCGRendererReceiver) {
        RemoteCGRendererLineStrokes lines { WTF::move(m_pendingLineStrokes) };
        send(Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness(lines));
        m_pendingLineStrokes = lines.takeLines();
        m_pendingLineStrokes.shrink(0);
        return;
    }
#endif
    send(Messages::RemoteGraphicsContext::StrokeLinesWithColorAndThickness(m_pendingLineStrokes.span()));

    m_pendingLineStrokes.shrink(0);
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
    send(Messages::RemoteGraphicsContext::DrawControlPart(part, borderRect, deviceScaleFactor, style));
}

#if USE(CG)

void RemoteGraphicsContextProxy::applyStrokePattern()
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(ApplyStrokePattern);
}

void RemoteGraphicsContextProxy::applyFillPattern()
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    SEND_RENDERER_MESSAGE(ApplyFillPattern);
}

#endif // USE(CG)

void RemoteGraphicsContextProxy::applyDeviceScaleFactor(float scaleFactor)
{
    sendPendingDrawsIfNecessary();
    updateStateForApplyDeviceScaleFactor(scaleFactor);
    send(Messages::RemoteGraphicsContext::ApplyDeviceScaleFactor(scaleFactor));
}

void RemoteGraphicsContextProxy::beginPage(const FloatRect& pageRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::BeginPage(pageRect));
    updateStateForBeginPage();
}

void RemoteGraphicsContextProxy::endPage()
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::EndPage());
}

void RemoteGraphicsContextProxy::setURLForRect(const URL& link, const FloatRect& destRect)
{
    sendPendingDrawsIfNecessary();
    appendStateChangeItemIfNecessary();
    send(Messages::RemoteGraphicsContext::SetURLForRect(link, destRect));
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

std::optional<RemoteGradientIdentifier> RemoteGraphicsContextProxy::recordResourceUse(Gradient& gradient)
{
    if (gradient.isTransient())
        return std::nullopt;
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
                    send(Messages::RemoteGraphicsContext::SetFillPatternNativeImage(image->renderingResourceIdentifier(), pattern->parameters()));
            } else if (RefPtr buffer = pattern->tileImageBuffer()) {
                if (recordResourceUse(*buffer))
                    send(Messages::RemoteGraphicsContext::SetFillPatternImageBuffer(buffer->renderingResourceIdentifier(), pattern->parameters()));
            }
        } else if (RefPtr gradient = fillBrush.gradient()) {
            if (auto identifier = recordResourceUse(*gradient))
                send(Messages::RemoteGraphicsContext::SetFillCachedGradient(*identifier, fillBrush.gradientSpaceTransform()));
            else
                send(Messages::RemoteGraphicsContext::SetFillGradient(*gradient, fillBrush.gradientSpaceTransform()));
        } else
            send(Messages::RemoteGraphicsContext::SetFillColor(fillBrush.color()));
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
                    send(Messages::RemoteGraphicsContext::SetStrokePatternNativeImage(image->renderingResourceIdentifier(), pattern->parameters()));
            } else if (RefPtr buffer = pattern->tileImageBuffer()) {
                if (recordResourceUse(*buffer))
                    send(Messages::RemoteGraphicsContext::SetStrokePatternImageBuffer(buffer->renderingResourceIdentifier(), pattern->parameters()));
            }
        } else if (RefPtr gradient = strokeBrush.gradient()) {
            if (auto identifier = recordResourceUse(*gradient))
                send(Messages::RemoteGraphicsContext::SetStrokeCachedGradient(*identifier, strokeBrush.gradientSpaceTransform()));
            else
                send(Messages::RemoteGraphicsContext::SetStrokeGradient(*gradient, strokeBrush.gradientSpaceTransform()));
        } else
            send(Messages::RemoteGraphicsContext::SetStrokeColor(strokeBrush.color()));
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
        send(Messages::RemoteGraphicsContext::SetShadowsIgnoreTransforms(state.shadowsIgnoreTransforms()));
    if (changes.contains(GraphicsContextState::Change::DropShadow))
        send(Messages::RemoteGraphicsContext::SetDropShadow(state.dropShadow()));
    if (changes.contains(GraphicsContextState::Change::Style))
        send(Messages::RemoteGraphicsContext::SetStyle(state.style()));
    if (changes.contains(GraphicsContextState::Change::Alpha))
        SEND_RENDERER_MESSAGE(SetAlpha, state.alpha());
    if (changes.contains(GraphicsContextState::Change::TextDrawingMode))
        send(Messages::RemoteGraphicsContext::SetTextDrawingMode(state.textDrawingMode()));
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
template void RemoteGraphicsContextProxy::send<Messages::RemoteSnapshotRecorder::DrawSnapshotFrame>(Messages::RemoteSnapshotRecorder::DrawSnapshotFrame&&);

}

#undef SEND_RENDERER_MESSAGE
#undef SEND_RENDERER_MESSAGE_WITH_SWIFT_ARGUMENTS

#endif
