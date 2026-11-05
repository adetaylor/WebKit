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
#include "RemoteCGRendererMessages.h"
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
        m_cgRenderer = WTF::makeUniqueWithoutFastMallocCheck<RemoteCGRenderer>(RemoteCGRenderer::init());
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
