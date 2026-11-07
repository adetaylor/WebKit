/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
#include "RemoteImageBufferGraphicsContext.h"

#if ENABLE(GPU_PROCESS)

#include "Logging.h"
#include "RemoteGraphicsContextMessages.h"

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "HandleMessage.h"
#include "RemoteCGRendererLineDash.h"
#include "RemoteCGRendererLineStrokes.h"
#include "RemoteCGRendererMessages.h"
#include "RemoteCGRendererPath.h"
#include "RemoteCGRendererPathSegment.h"
#include "RemoteCGRendererResources.h"
#include "RemoteCGRendererShadow.h"
#include "RemoteCGRendererStyle.h"
#include "WebKit-Swift.h"
#endif

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_renderingBackend->streamConnection());

namespace WebKit {
using namespace WebCore;

Ref<RemoteImageBufferGraphicsContext> RemoteImageBufferGraphicsContext::create(ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& renderingBackend)
{
    Ref instance = adoptRef(*new RemoteImageBufferGraphicsContext(imageBuffer, identifier, renderingBackend));
    instance->startListeningForIPC();
    return instance;
}

RemoteImageBufferGraphicsContext::RemoteImageBufferGraphicsContext(ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& renderingBackend)
    : RemoteGraphicsContext(imageBuffer.context(), renderingBackend)
    , m_imageBuffer(imageBuffer)
    , m_identifier(identifier)
{
}

RemoteImageBufferGraphicsContext::~RemoteImageBufferGraphicsContext()
{
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (m_isSwiftRendererLender)
        cgContext().removeSwiftRendererLender();
#endif
}

void RemoteImageBufferGraphicsContext::startListeningForIPC()
{
    auto& streamConnection = m_renderingBackend->streamConnection();
    streamConnection.startReceivingMessages(*this, Messages::RemoteGraphicsContext::messageReceiverName(), m_identifier.toUInt64());
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    if (context().canLendSwiftRenderer()) {
        if (!m_isSwiftRendererLender) {
            cgContext().addSwiftRendererLender();
            m_isSwiftRendererLender = true;
        }
        Ref resources = RemoteCGRendererResources::create(m_renderingBackend, m_imageBuffer);
        m_cgRenderer = WTF::makeUniqueWithoutFastMallocCheck<RemoteCGRenderer>(RemoteCGRenderer::init(resources.ptr()));
        Ref forwarder = m_cgRenderer->getMessageReceiver();
        forwarder->setStateLender(*this);
        streamConnection.startReceivingMessages(forwarder, Messages::RemoteCGRenderer::messageReceiverName(), m_identifier.toUInt64());
    } else
        streamConnection.startReceivingMessages(*this, Messages::RemoteCGRenderer::messageReceiverName(), m_identifier.toUInt64());
#endif
}

void RemoteImageBufferGraphicsContext::stopListeningForIPC()
{
    auto& streamConnection = m_renderingBackend->streamConnection();
    streamConnection.stopReceivingMessages(Messages::RemoteGraphicsContext::messageReceiverName(), m_identifier.toUInt64());
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    streamConnection.stopReceivingMessages(Messages::RemoteCGRenderer::messageReceiverName(), m_identifier.toUInt64());
    m_cgRenderer = nullptr;
#endif
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

void RemoteImageBufferGraphicsContext::didReceiveStreamMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
    if (decoder.messageReceiverName() == Messages::RemoteCGRenderer::messageReceiverName()) {
        didReceiveCGRendererMessage(connection, decoder);
        return;
    }
    RemoteGraphicsContext::didReceiveStreamMessage(connection, decoder);
}

void RemoteImageBufferGraphicsContext::didReceiveCGRendererMessage(IPC::StreamServerConnection& connection, IPC::Decoder& decoder)
{
#define HANDLE_CG_RENDERER_MESSAGE(message, function) \
    if (decoder.messageName() == Messages::RemoteCGRenderer::message::name()) { \
        IPC::handleMessage<Messages::RemoteCGRenderer::message>(connection, decoder, this, function); \
        return; \
    }
    HANDLE_CG_RENDERER_MESSAGE(Save, &RemoteGraphicsContext::save)
    HANDLE_CG_RENDERER_MESSAGE(Restore, &RemoteGraphicsContext::restore)
    HANDLE_CG_RENDERER_MESSAGE(Translate, &RemoteGraphicsContext::translate)
    HANDLE_CG_RENDERER_MESSAGE(Rotate, &RemoteGraphicsContext::rotate)
    HANDLE_CG_RENDERER_MESSAGE(Scale, &RemoteGraphicsContext::scale)
    HANDLE_CG_RENDERER_MESSAGE(SetCTM, &RemoteGraphicsContext::setCTM)
    HANDLE_CG_RENDERER_MESSAGE(ConcatCTM, &RemoteGraphicsContext::concatCTM)
    HANDLE_CG_RENDERER_MESSAGE(SetFillPackedColor, &RemoteImageBufferGraphicsContext::setFillPackedColorValue)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokePackedColor, &RemoteImageBufferGraphicsContext::setStrokePackedColorValue)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokePackedColorAndThickness, &RemoteImageBufferGraphicsContext::setStrokePackedColorValueAndThickness)
    HANDLE_CG_RENDERER_MESSAGE(SetFillRule, &RemoteGraphicsContext::setFillRule)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokeThickness, &RemoteGraphicsContext::setStrokeThickness)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokeStyle, &RemoteGraphicsContext::setStrokeStyle)
    HANDLE_CG_RENDERER_MESSAGE(SetCompositeMode, &RemoteGraphicsContext::setCompositeMode)
    HANDLE_CG_RENDERER_MESSAGE(SetAlpha, &RemoteGraphicsContext::setAlpha)
    HANDLE_CG_RENDERER_MESSAGE(SetImageInterpolationQuality, &RemoteGraphicsContext::setImageInterpolationQuality)
    HANDLE_CG_RENDERER_MESSAGE(SetShouldAntialias, &RemoteGraphicsContext::setShouldAntialias)
    HANDLE_CG_RENDERER_MESSAGE(SetShouldSmoothFonts, &RemoteGraphicsContext::setShouldSmoothFonts)
    HANDLE_CG_RENDERER_MESSAGE(SetShouldSubpixelQuantizeFonts, &RemoteGraphicsContext::setShouldSubpixelQuantizeFonts)
    HANDLE_CG_RENDERER_MESSAGE(SetLineCap, &RemoteGraphicsContext::setLineCap)
    HANDLE_CG_RENDERER_MESSAGE(SetLineJoin, &RemoteGraphicsContext::setLineJoin)
    HANDLE_CG_RENDERER_MESSAGE(SetMiterLimit, &RemoteGraphicsContext::setMiterLimit)
    HANDLE_CG_RENDERER_MESSAGE(Clip, &RemoteGraphicsContext::clip)
    HANDLE_CG_RENDERER_MESSAGE(ClipOut, &RemoteGraphicsContext::clipOut)
    HANDLE_CG_RENDERER_MESSAGE(ResetClip, &RemoteGraphicsContext::resetClip)
    HANDLE_CG_RENDERER_MESSAGE(DrawLine, &RemoteGraphicsContext::drawLine)
    HANDLE_CG_RENDERER_MESSAGE(FillRect, &RemoteGraphicsContext::fillRect)
    HANDLE_CG_RENDERER_MESSAGE(FillEllipse, &RemoteGraphicsContext::fillEllipse)
    HANDLE_CG_RENDERER_MESSAGE(StrokeRect, &RemoteGraphicsContext::strokeRect)
    HANDLE_CG_RENDERER_MESSAGE(StrokeEllipse, &RemoteGraphicsContext::strokeEllipse)
    HANDLE_CG_RENDERER_MESSAGE(ClearRect, &RemoteGraphicsContext::clearRect)
    HANDLE_CG_RENDERER_MESSAGE(ApplyStrokePattern, &RemoteGraphicsContext::applyStrokePattern)
    HANDLE_CG_RENDERER_MESSAGE(ApplyFillPattern, &RemoteGraphicsContext::applyFillPattern)
    HANDLE_CG_RENDERER_MESSAGE(DrawRect, &RemoteGraphicsContext::drawRect)
    HANDLE_CG_RENDERER_MESSAGE(DrawEllipse, &RemoteGraphicsContext::drawEllipse)
    HANDLE_CG_RENDERER_MESSAGE(FillLine, &RemoteGraphicsContext::fillLine)
    HANDLE_CG_RENDERER_MESSAGE(FillArc, &RemoteGraphicsContext::fillArc)
    HANDLE_CG_RENDERER_MESSAGE(FillClosedArc, &RemoteGraphicsContext::fillClosedArc)
    HANDLE_CG_RENDERER_MESSAGE(FillQuadCurve, &RemoteGraphicsContext::fillQuadCurve)
    HANDLE_CG_RENDERER_MESSAGE(FillBezierCurve, &RemoteGraphicsContext::fillBezierCurve)
    HANDLE_CG_RENDERER_MESSAGE(FillPathSegment, &RemoteImageBufferGraphicsContext::fillPathSegment)
    HANDLE_CG_RENDERER_MESSAGE(StrokeLine, &RemoteGraphicsContext::strokeLine)
    HANDLE_CG_RENDERER_MESSAGE(StrokeLinesWithColorAndThickness, &RemoteImageBufferGraphicsContext::strokeLines)
    HANDLE_CG_RENDERER_MESSAGE(StrokeArc, &RemoteGraphicsContext::strokeArc)
    HANDLE_CG_RENDERER_MESSAGE(StrokeClosedArc, &RemoteGraphicsContext::strokeClosedArc)
    HANDLE_CG_RENDERER_MESSAGE(StrokeQuadCurve, &RemoteGraphicsContext::strokeQuadCurve)
    HANDLE_CG_RENDERER_MESSAGE(StrokeBezierCurve, &RemoteGraphicsContext::strokeBezierCurve)
    HANDLE_CG_RENDERER_MESSAGE(StrokePathSegment, &RemoteImageBufferGraphicsContext::strokePathSegment)
    HANDLE_CG_RENDERER_MESSAGE(FillPath, &RemoteImageBufferGraphicsContext::fillPath)
    HANDLE_CG_RENDERER_MESSAGE(StrokePath, &RemoteImageBufferGraphicsContext::strokePath)
    HANDLE_CG_RENDERER_MESSAGE(DrawPath, &RemoteImageBufferGraphicsContext::drawPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipPath, &RemoteImageBufferGraphicsContext::clipPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipOutToPath, &RemoteImageBufferGraphicsContext::clipOutToPath)
    HANDLE_CG_RENDERER_MESSAGE(FillCachedPath, &RemoteGraphicsContext::fillCachedPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipCachedPath, &RemoteGraphicsContext::clipCachedPath)
    HANDLE_CG_RENDERER_MESSAGE(DrawNativeImage, &RemoteGraphicsContext::drawNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(DrawImageBuffer, &RemoteImageBufferGraphicsContext::drawImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(DrawPatternNativeImage, &RemoteGraphicsContext::drawPatternNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(DrawPatternImageBuffer, &RemoteGraphicsContext::drawPatternImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(SetFillColor, &RemoteGraphicsContext::setFillColor)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokeColor, &RemoteGraphicsContext::setStrokeColor)
    HANDLE_CG_RENDERER_MESSAGE(SetDropShadow, &RemoteImageBufferGraphicsContext::setDropShadow)
    HANDLE_CG_RENDERER_MESSAGE(SetStyle, &RemoteImageBufferGraphicsContext::setStyle)
    HANDLE_CG_RENDERER_MESSAGE(SetTextDrawingMode, &RemoteGraphicsContext::setTextDrawingMode)
    HANDLE_CG_RENDERER_MESSAGE(SetShadowsIgnoreTransforms, &RemoteGraphicsContext::setShadowsIgnoreTransforms)
    HANDLE_CG_RENDERER_MESSAGE(SetLineDash, &RemoteImageBufferGraphicsContext::setLineDash)
    HANDLE_CG_RENDERER_MESSAGE(FillRectWithColor, &RemoteGraphicsContext::fillRectWithColor)
    HANDLE_CG_RENDERER_MESSAGE(FillCompositedRect, &RemoteGraphicsContext::fillCompositedRect)
    HANDLE_CG_RENDERER_MESSAGE(ApplyDeviceScaleFactor, &RemoteGraphicsContext::applyDeviceScaleFactor)
    HANDLE_CG_RENDERER_MESSAGE(ClipRoundedRect, &RemoteGraphicsContext::clipRoundedRect)
    HANDLE_CG_RENDERER_MESSAGE(ClipOutRoundedRect, &RemoteGraphicsContext::clipOutRoundedRect)
    HANDLE_CG_RENDERER_MESSAGE(ClipToNativeImage, &RemoteGraphicsContext::clipToNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(BeginTransparencyLayer, &RemoteGraphicsContext::beginTransparencyLayer)
    HANDLE_CG_RENDERER_MESSAGE(BeginTransparencyLayerWithCompositeMode, &RemoteGraphicsContext::beginTransparencyLayerWithCompositeMode)
    HANDLE_CG_RENDERER_MESSAGE(EndTransparencyLayer, &RemoteGraphicsContext::endTransparencyLayer)
    HANDLE_CG_RENDERER_MESSAGE(SetURLForRect, &RemoteGraphicsContext::setURLForRect)
#undef HANDLE_CG_RENDERER_MESSAGE
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

void RemoteImageBufferGraphicsContext::setFillPackedColorValue(uint32_t color)
{
    setFillPackedColor(WebCore::PackedColor::RGBA { color });
}

void RemoteImageBufferGraphicsContext::setStrokePackedColorValue(uint32_t color)
{
    setStrokePackedColor(WebCore::PackedColor::RGBA { color });
}

void RemoteImageBufferGraphicsContext::setStrokePackedColorValueAndThickness(uint32_t color, float thickness)
{
    setStrokePackedColorAndThickness(WebCore::PackedColor::RGBA { color }, thickness);
}

void RemoteImageBufferGraphicsContext::strokeLines(const RemoteCGRendererLineStrokes& lines)
{
    strokeLinesWithColorAndThickness(lines.span());
}

void RemoteImageBufferGraphicsContext::fillPathSegment(const RemoteCGRendererPathSegment& segment)
{
    RemoteGraphicsContext::fillPathSegment(segment.segment());
}

void RemoteImageBufferGraphicsContext::strokePathSegment(const RemoteCGRendererPathSegment& segment)
{
    RemoteGraphicsContext::strokePathSegment(segment.segment());
}

void RemoteImageBufferGraphicsContext::fillPath(const RemoteCGRendererPath& path)
{
    RemoteGraphicsContext::fillPath(path.path());
}

void RemoteImageBufferGraphicsContext::strokePath(const RemoteCGRendererPath& path)
{
    RemoteGraphicsContext::strokePath(path.path());
}

void RemoteImageBufferGraphicsContext::drawPath(const RemoteCGRendererPath& path)
{
    RemoteGraphicsContext::drawPath(path.path());
}

void RemoteImageBufferGraphicsContext::clipPath(const RemoteCGRendererPath& path, WindRule rule)
{
    RemoteGraphicsContext::clipPath(path.path(), rule);
}

void RemoteImageBufferGraphicsContext::clipOutToPath(const RemoteCGRendererPath& path)
{
    RemoteGraphicsContext::clipOutToPath(path.path());
}

void RemoteImageBufferGraphicsContext::setDropShadow(const RemoteCGRendererShadow& shadow)
{
    RemoteGraphicsContext::setDropShadow(shadow.shadow());
}

void RemoteImageBufferGraphicsContext::setStyle(const RemoteCGRendererStyle& style)
{
    RemoteGraphicsContext::setStyle(style.style());
}

void RemoteImageBufferGraphicsContext::setLineDash(const RemoteCGRendererLineDash& dashes, float dashOffset)
{
    context().setLineDash(DashArray(dashes.span()), dashOffset);
}

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

void RemoteImageBufferGraphicsContext::drawImageBuffer(RenderingResourceIdentifier imageBufferIdentifier, const FloatRect& destinationRect, const FloatRect& srcRect, RasterDrawingOptions options)
{
    RefPtr sourceImage = imageBuffer(imageBufferIdentifier);
    MESSAGE_CHECK(sourceImage);
    bool selfCopy = false;
    if (sourceImage == m_imageBuffer.ptr() && sourceImage->renderingMode() == RenderingMode::Accelerated) {
        sourceImage = sourceImage->clone();
        sourceImage->flushDrawingContext();
        selfCopy = true;
    }
    context().drawImageBuffer(*sourceImage, destinationRect, srcRect, options);
    if (selfCopy)
        m_imageBuffer->flushDrawingContext();
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS)
