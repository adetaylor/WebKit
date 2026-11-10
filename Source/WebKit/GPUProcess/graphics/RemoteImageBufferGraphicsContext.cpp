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
#include "RemoteRenderingBackend.h"
#include <WebCore/ImageBuffer.h>

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#include "RemoteGraphicsContextMessages.h"
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "HandleMessage.h"
#include "ImageBufferBackendHandleSharing.h"
#include "RemoteSharedResourceCache.h"
#include "SwiftCoding.h"
#include "RemoteCGRendererGlyphs.h"
#include "RemoteCGRendererLineDash.h"
#include "RemoteCGRendererLineSegments.h"
#include "RemoteCGRendererLineStrokes.h"
#include "RemoteCGRendererMessages.h"
#include "RemoteCGRendererPathSegment.h"
#include "RemoteCGRendererResources.h"
#include "RemoteCGRendererShadow.h"
#include "RemoteCGRendererStyle.h"
#include "RemoteResourceCache.h"
#include "StreamMessageReceiver.h"
#include "WebKit-Swift.h"
#include <WebCore/DisplayListRecorderImpl.h>
#include <WebCore/Gradient.h>
#include <WebCore/PixelBuffer.h>
#include <wtf/Lock.h>
#if PLATFORM(COCOA)
#include <WebCore/GraphicsLayerContentsDisplayDelegate.h>
#include <WebCore/PlatformCALayerDelegatedContents.h>
#endif
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#include <WebCore/DynamicContentScalingDisplayList.h>
#endif
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#include <WebCore/BifurcatedGraphicsContext.h>
#endif

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_renderingBackend->streamConnection());

namespace WebKit {
using namespace WebCore;

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

// What the one placeholder of the WebCore display list that a DisplayList image buffer's context records keeps: the buffer's
// drawing, recorded in Swift (RemoteCGRendererRecordedDrawing, RemoteImageBuffer.swift), which it draws into the context the
// display list is drawn into, if that context can lend its renderer.
class RemoteCGRendererRecordedDrawingHandle final : public ThreadSafeRefCounted<RemoteCGRendererRecordedDrawingHandle> {
public:
    static Ref<RemoteCGRendererRecordedDrawingHandle> adopt(uintptr_t drawing)
    {
        return adoptRef(*new RemoteCGRendererRecordedDrawingHandle(drawing));
    }

    ~RemoteCGRendererRecordedDrawingHandle()
    {
        RemoteCGRendererRecordedDrawing::releaseDrawing(m_drawing);
    }

    void draw(GraphicsContext& context) const
    {
        if (!context.canLendSwiftRenderer())
            return;
        replayIntoContext(static_cast<GraphicsContextCG&>(context), [&](CGRendererCore& state, RemoteCGRendererResources& resources) {
            RemoteCGRendererRecordedDrawing::draw(m_drawing, state, &resources);
        });
    }

private:
    explicit RemoteCGRendererRecordedDrawingHandle(uintptr_t drawing)
        : m_drawing(drawing)
    {
        RELEASE_ASSERT(drawing);
    }

    const uintptr_t m_drawing;
};

#endif

Ref<RemoteImageBufferGraphicsContext> RemoteImageBufferGraphicsContext::create(ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& renderingBackend)
{
    Ref instance = adoptRef(*new RemoteImageBufferGraphicsContext(imageBuffer, identifier, renderingBackend));
    instance->startListeningForIPC();
    return instance;
}

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
RemoteImageBufferGraphicsContext::RemoteImageBufferGraphicsContext(ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& renderingBackend)
    : RemoteGraphicsContext(imageBuffer.context(), renderingBackend)
    , m_imageBuffer(imageBuffer)
    , m_identifier(identifier)
{
}
#else
RemoteImageBufferGraphicsContext::RemoteImageBufferGraphicsContext(ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& renderingBackend)
    : m_renderingBackend(renderingBackend)
    , m_context(imageBuffer.context())
    , m_imageBuffer(imageBuffer)
    , m_identifier(identifier)
{
}
#endif

RemoteImageBufferGraphicsContext::~RemoteImageBufferGraphicsContext()
{
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    releaseImageBuffer();
    if (m_isSwiftRendererLender)
        cgContext().removeSwiftRendererLender();
#endif
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

RemoteImageBufferGraphicsContext* RemoteImageBufferGraphicsContext::createForImageBufferReceiver(ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& renderingBackend)
{
    Ref instance = create(imageBuffer, identifier, renderingBackend);
    instance->m_countsImageBuffer = true;
    instance->m_renderingResourcesRequest = ScopedRenderingResourcesRequest::acquire();
    renderingBackend.sharedResourceCache().didCreateImageBuffer(imageBuffer.renderingPurpose(), imageBuffer.renderingMode());
    return &instance.leakRef();
}

void RemoteImageBufferGraphicsContext::installRecordedDrawing(uintptr_t drawing)
{
    ASSERT(m_imageBuffer->renderingMode() == RenderingMode::DisplayList);
    Ref handle = RemoteCGRendererRecordedDrawingHandle::adopt(drawing);
    static_cast<DisplayList::RecorderImpl&>(imageBufferContext()).drawPlaceholder([handle = WTF::move(handle)](GraphicsContext& context) {
        handle->draw(context);
    });
}

void RemoteImageBufferGraphicsContext::releaseImageBuffer()
{
    if (!std::exchange(m_countsImageBuffer, false))
        return;
    m_renderingBackend->sharedResourceCache().didReleaseImageBuffer(m_imageBuffer->renderingPurpose(), m_imageBuffer->renderingMode());
    m_renderingResourcesRequest = { };
    // Volatile image buffers do not have contexts.
    if (m_imageBuffer->volatilityState() == VolatilityState::Volatile)
        return;
    if (!m_imageBuffer->hasBackend())
        return;
    m_imageBuffer->context().unwindStateStack();
}

RemoteImageBufferPixelsResult RemoteImageBufferGraphicsContext::getPixelBuffer(IPC::CxxDecodedArgument<PixelBufferFormat>& outputFormat, int x, int y, int width, int height)
{
    RefPtr memory = m_renderingBackend->sharedMemoryForGetPixelBuffer();
    if (!memory)
        return RemoteImageBufferPixelsResult::NoSharedMemory;
    auto destinationFormat = outputFormat.take();
    RELEASE_ASSERT(destinationFormat);
    if (!ImageBuffer::supportedPixelBufferFormats(destinationFormat->pixelFormat))
        return RemoteImageBufferPixelsResult::UnsupportedFormat;
    IntRect srcRect { { x, y }, { width, height } };
    if (RefPtr pixelBuffer = m_imageBuffer->getPixelBuffer(*destinationFormat, srcRect)) {
        if (pixelBuffer->bytes().size() > memory->size())
            return RemoteImageBufferPixelsResult::SharedMemoryTooSmall;
        memcpySpan(memory->mutableSpan(), pixelBuffer->bytes());
    } else
        zeroSpan(memory->mutableSpan());
    return RemoteImageBufferPixelsResult::Copied;
}

bool RemoteImageBufferGraphicsContext::setPixelBufferSharedMemory(IPC::CxxDecodedArgument<SharedMemory::Handle>& handle)
{
    m_renderingBackend->setSharedMemoryForGetPixelBuffer(nullptr);
    auto memoryHandle = handle.take();
    RELEASE_ASSERT(memoryHandle);
    RefPtr sharedMemory = SharedMemory::map(WTF::move(*memoryHandle), SharedMemory::Protection::ReadWrite);
    if (!sharedMemory)
        return false;
    m_renderingBackend->setSharedMemoryForGetPixelBuffer(WTF::move(sharedMemory));
    return true;
}

void RemoteImageBufferGraphicsContext::putPixelBuffer(const PixelBufferSourceView& pixelBuffer, IntPoint srcPoint, IntSize srcSize, IntPoint destPoint, AlphaPremultiplication destFormat)
{
    m_imageBuffer->putPixelBuffer(pixelBuffer, { srcPoint, srcSize }, destPoint, destFormat);
}

bool RemoteImageBufferGraphicsContext::copyNativeImage(uint64_t imageIdentifier)
{
    RefPtr image = m_imageBuffer->copyNativeImage();
    // The buffer may have failed to allocate, or the copy may fail.
    if (!image)
        image = RemoteRenderingBackend::createPlaceholderNativeImage();
    if (!image)
        return false;
    return m_renderingBackend->addCachedNativeImage(image.releaseNonNull(), RenderingResourceIdentifier { imageIdentifier });
}

void RemoteImageBufferGraphicsContext::encodeBackendHandle(IPC::SwiftReplyEncoder& encoder)
{
    std::optional<ImageBufferBackendHandle> handle;
    if (auto* sharing = m_imageBuffer->toBackendSharing())
        handle = downcast<ImageBufferBackendHandleSharing>(*sharing).createBackendHandle();
    encoder.encodeWithArgumentCoder(WTF::move(handle));
}

#if PLATFORM(COCOA)
void RemoteImageBufferGraphicsContext::encodeDisplayBuffer(IPC::SwiftReplyEncoder& encoder)
{
    RefPtr displayDelegate = m_displayDelegate;
    if (!displayDelegate) {
        displayDelegate = m_imageBuffer->layerContentsDisplayDelegate();
        m_displayDelegate = displayDelegate;
    } else
        m_imageBuffer->prepareForDisplay();
    auto contents = displayDelegate ? displayDelegate->delegatedContents() : std::nullopt;
    if (!contents) {
        m_displayBufferFence = nullptr;
        encoder.encodeWithArgumentCoder(MachSendRight { });
        return;
    }
    m_displayBufferFence = WTF::move(contents->finishedFence);
    encoder.encodeWithArgumentCoder(WTF::move(contents->surface));
}

void RemoteImageBufferGraphicsContext::waitForDisplayBuffer()
{
    if (RefPtr fence = std::exchange(m_displayBufferFence, nullptr))
        fence->waitFor(WebCore::delegatedContentsFinishedTimeout);
}
#endif

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
void RemoteImageBufferGraphicsContext::encodeDynamicContentScalingDisplayList(IPC::SwiftReplyEncoder& encoder)
{
    std::optional<DynamicContentScalingDisplayList> displayList { m_imageBuffer->dynamicContentScalingDisplayList() };
    encoder.encodeWithArgumentCoder(WTF::move(displayList));
}
#endif

GraphicsContext& RemoteImageBufferGraphicsContext::drawingContext()
{
    return m_discardedDrawingTarget ? m_discardedDrawingTarget->context() : imageBufferContext();
}

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

void RemoteImageBufferGraphicsContext::startListeningForIPC()
{
    auto& streamConnection = m_renderingBackend->streamConnection();
#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    streamConnection.startReceivingMessages(*this, Messages::RemoteGraphicsContext::messageReceiverName(), m_identifier.toUInt64());
#else
#if !ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    // The context of an image buffer that failed to allocate (NullImageBufferBackend) draws nothing and can't lend a
    // renderer: its drawing is drawn into an image buffer of its own, which nothing shows.
    if (!imageBufferContext().canLendSwiftRenderer() && m_imageBuffer->renderingMode() != RenderingMode::DisplayList)
        m_discardedDrawingTarget = ImageBuffer::create({ 1, 1 }, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, ColorSpace::SRGB(), PixelFormat::BGRA8);
#endif
    if (drawingContext().canLendSwiftRenderer()) {
        if (!m_isSwiftRendererLender) {
            cgContext().addSwiftRendererLender();
            m_isSwiftRendererLender = true;
        }
        Ref resources = RemoteCGRendererResources::create(m_renderingBackend, m_discardedDrawingTarget ? *m_discardedDrawingTarget : m_imageBuffer.get());
        Ref forwarder = RemoteCGRenderer::createMessageReceiver(resources.ptr(), m_renderingBackend.ptr());
        forwarder->setStateLender(*this);
        streamConnection.startReceivingMessages(forwarder, Messages::RemoteCGRenderer::messageReceiverName(), m_identifier.toUInt64());
        return;
    }
    // The image buffer's Swift receiver records the drawing of one whose drawing is recorded (installRecordedDrawing()).
    if (m_imageBuffer->renderingMode() == RenderingMode::DisplayList)
        return;
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    streamConnection.startReceivingMessages(*this, Messages::RemoteCGRenderer::messageReceiverName(), m_identifier.toUInt64());
#else
    RELEASE_ASSERT_NOT_REACHED();
#endif
#endif
}

void RemoteImageBufferGraphicsContext::stopListeningForIPC()
{
    auto& streamConnection = m_renderingBackend->streamConnection();
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    streamConnection.stopReceivingMessages(Messages::RemoteCGRenderer::messageReceiverName(), m_identifier.toUInt64());
#else
    streamConnection.stopReceivingMessages(Messages::RemoteGraphicsContext::messageReceiverName(), m_identifier.toUInt64());
#endif
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)

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
    HANDLE_CG_RENDERER_MESSAGE(FillPath, &RemoteGraphicsContext::fillPath)
    HANDLE_CG_RENDERER_MESSAGE(StrokePath, &RemoteGraphicsContext::strokePath)
    HANDLE_CG_RENDERER_MESSAGE(DrawPath, &RemoteGraphicsContext::drawPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipPath, &RemoteGraphicsContext::clipPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipOutToPath, &RemoteGraphicsContext::clipOutToPath)
    HANDLE_CG_RENDERER_MESSAGE(FillCachedPath, &RemoteGraphicsContext::fillCachedPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipCachedPath, &RemoteGraphicsContext::clipCachedPath)
    HANDLE_CG_RENDERER_MESSAGE(DrawNativeImage, &RemoteGraphicsContext::drawNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(DrawImageBuffer, &RemoteImageBufferGraphicsContext::drawImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(DrawPatternNativeImage, &RemoteGraphicsContext::drawPatternNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(DrawPatternImageBuffer, &RemoteGraphicsContext::drawPatternImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(SetFillColor, &RemoteImageBufferGraphicsContext::setFillColor)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokeColor, &RemoteImageBufferGraphicsContext::setStrokeColor)
    HANDLE_CG_RENDERER_MESSAGE(SetDropShadow, &RemoteImageBufferGraphicsContext::setDropShadow)
    HANDLE_CG_RENDERER_MESSAGE(SetStyle, &RemoteImageBufferGraphicsContext::setStyle)
    HANDLE_CG_RENDERER_MESSAGE(SetTextDrawingMode, &RemoteGraphicsContext::setTextDrawingMode)
    HANDLE_CG_RENDERER_MESSAGE(SetShadowsIgnoreTransforms, &RemoteGraphicsContext::setShadowsIgnoreTransforms)
    HANDLE_CG_RENDERER_MESSAGE(SetLineDash, &RemoteImageBufferGraphicsContext::setLineDash)
    HANDLE_CG_RENDERER_MESSAGE(FillRectWithColor, &RemoteImageBufferGraphicsContext::fillRectWithColor)
    HANDLE_CG_RENDERER_MESSAGE(FillCompositedRect, &RemoteImageBufferGraphicsContext::fillCompositedRect)
    HANDLE_CG_RENDERER_MESSAGE(ApplyDeviceScaleFactor, &RemoteGraphicsContext::applyDeviceScaleFactor)
    HANDLE_CG_RENDERER_MESSAGE(ClipRoundedRect, &RemoteGraphicsContext::clipRoundedRect)
    HANDLE_CG_RENDERER_MESSAGE(ClipOutRoundedRect, &RemoteGraphicsContext::clipOutRoundedRect)
    HANDLE_CG_RENDERER_MESSAGE(ClipToNativeImage, &RemoteGraphicsContext::clipToNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(BeginTransparencyLayer, &RemoteGraphicsContext::beginTransparencyLayer)
    HANDLE_CG_RENDERER_MESSAGE(BeginTransparencyLayerWithCompositeMode, &RemoteGraphicsContext::beginTransparencyLayerWithCompositeMode)
    HANDLE_CG_RENDERER_MESSAGE(EndTransparencyLayer, &RemoteGraphicsContext::endTransparencyLayer)
    HANDLE_CG_RENDERER_MESSAGE(SetURLForRect, &RemoteGraphicsContext::setURLForRect)
    HANDLE_CG_RENDERER_MESSAGE(SetFillCachedGradient, &RemoteGraphicsContext::setFillCachedGradient)
    HANDLE_CG_RENDERER_MESSAGE(SetFillPatternNativeImage, &RemoteGraphicsContext::setFillPatternNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(SetFillPatternImageBuffer, &RemoteGraphicsContext::setFillPatternImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokeCachedGradient, &RemoteGraphicsContext::setStrokeCachedGradient)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokePatternNativeImage, &RemoteGraphicsContext::setStrokePatternNativeImage)
    HANDLE_CG_RENDERER_MESSAGE(SetStrokePatternImageBuffer, &RemoteGraphicsContext::setStrokePatternImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(FillRectWithCachedGradient, &RemoteImageBufferGraphicsContext::fillRectWithCachedGradient)
    HANDLE_CG_RENDERER_MESSAGE(DrawLinesForText, &RemoteImageBufferGraphicsContext::drawLinesForText)
    HANDLE_CG_RENDERER_MESSAGE(DrawDotsForDocumentMarker, &RemoteImageBufferGraphicsContext::drawDotsForDocumentMarker)
    HANDLE_CG_RENDERER_MESSAGE(DrawGlyphs, &RemoteImageBufferGraphicsContext::drawGlyphs)
    HANDLE_CG_RENDERER_MESSAGE(FillRectWithCachedGradientAndSpaceTransform, &RemoteImageBufferGraphicsContext::fillRectWithCachedGradientAndSpaceTransform)
    HANDLE_CG_RENDERER_MESSAGE(FillRoundedRect, &RemoteImageBufferGraphicsContext::fillRoundedRect)
    HANDLE_CG_RENDERER_MESSAGE(FillRectWithRoundedHole, &RemoteImageBufferGraphicsContext::fillRectWithRoundedHole)
    HANDLE_CG_RENDERER_MESSAGE(ClipTransformedPath, &RemoteGraphicsContext::clipTransformedPath)
    HANDLE_CG_RENDERER_MESSAGE(ClipTransformedCachedPath, &RemoteGraphicsContext::clipTransformedCachedPath)
    HANDLE_CG_RENDERER_MESSAGE(DrawFocusRingPath, &RemoteImageBufferGraphicsContext::drawFocusRingPath)
    HANDLE_CG_RENDERER_MESSAGE(BeginPage, &RemoteGraphicsContext::beginPage)
    HANDLE_CG_RENDERER_MESSAGE(EndPage, &RemoteGraphicsContext::endPage)
    HANDLE_CG_RENDERER_MESSAGE(DrawMeshGradient, &RemoteGraphicsContext::drawMeshGradient)
    HANDLE_CG_RENDERER_MESSAGE(DrawFilteredImageBuffer, &RemoteGraphicsContext::drawFilteredImageBuffer)
    HANDLE_CG_RENDERER_MESSAGE(DrawControlPart, &RemoteGraphicsContext::drawControlPart)
    HANDLE_CG_RENDERER_MESSAGE(DrawSystemImage, &RemoteGraphicsContext::drawSystemImage)
#if USE(SYSTEM_PREVIEW)
    HANDLE_CG_RENDERER_MESSAGE(DrawBadgeSystemImage, &RemoteGraphicsContext::drawBadgeSystemImage)
#endif
#if PLATFORM(COCOA) && ENABLE(VIDEO)
    HANDLE_CG_RENDERER_MESSAGE(DrawVideoFrame, &RemoteGraphicsContext::drawVideoFrame)
    HANDLE_CG_RENDERER_MESSAGE(SetSharedVideoFrameSemaphore, &RemoteImageBufferGraphicsContext::setSharedVideoFrameSemaphore)
    HANDLE_CG_RENDERER_MESSAGE(SetSharedVideoFrameMemory, &RemoteImageBufferGraphicsContext::setSharedVideoFrameMemory)
#endif
    HANDLE_CG_RENDERER_MESSAGE(DrawDisplayList, &RemoteImageBufferGraphicsContext::drawRecordedDisplayList)
#undef HANDLE_CG_RENDERER_MESSAGE
    RELEASE_LOG_ERROR(IPC, "Unhandled stream message %s to %" PRIu64, IPC::description(decoder.messageName()).characters(), decoder.destinationID());
    decoder.markInvalid();
}

// A display list, recorded in Swift, which each of the two contexts that a dynamic content scaling image buffer's context
// paints into replays, as each draws what this draws into the buffer's.
void RemoteImageBufferGraphicsContext::drawRecordedDisplayList(RemoteDisplayListIdentifier identifier)
{
    auto recording = RemoteCGRendererDisplayLists::forBackend(m_renderingBackend.ptr()).recording(displayListKey(identifier));
    MESSAGE_CHECK(recording);
    auto& bifurcatedContext = static_cast<BifurcatedGraphicsContext&>(context());
    for (auto* paintedContext : { &bifurcatedContext.primaryContext(), &bifurcatedContext.secondaryContext() }) {
        if (!paintedContext->canLendSwiftRenderer())
            continue;
        replayIntoContext(static_cast<GraphicsContextCG&>(*paintedContext), [&](CGRendererCore& state, RemoteCGRendererResources& resources) {
            recording.get().draw(state, &resources);
        });
    }
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

void RemoteImageBufferGraphicsContext::drawFocusRingPath(const Path& path, float outlineWidth, const CGRendererColorValue& color, float zoomFactor)
{
    RemoteGraphicsContext::drawFocusRingPath(path, outlineWidth, CGRendererColorFromValue(color), zoomFactor);
}

void RemoteImageBufferGraphicsContext::setDropShadow(const RemoteCGRendererShadow& shadow)
{
    RemoteGraphicsContext::setDropShadow(dropShadowFrom(shadow));
}

void RemoteImageBufferGraphicsContext::setStyle(const RemoteCGRendererStyle& style)
{
    RemoteGraphicsContext::setStyle(styleFrom(style));
}

void RemoteImageBufferGraphicsContext::setLineDash(const RemoteCGRendererLineDash& dashes, float dashOffset)
{
    context().setLineDash(DashArray(dashes.span()), dashOffset);
}

void RemoteImageBufferGraphicsContext::setFillColor(const CGRendererColorValue& color)
{
    RemoteGraphicsContext::setFillColor(CGRendererColorFromValue(color));
}

void RemoteImageBufferGraphicsContext::setStrokeColor(const CGRendererColorValue& color)
{
    RemoteGraphicsContext::setStrokeColor(CGRendererColorFromValue(color));
}

void RemoteImageBufferGraphicsContext::fillRectWithColor(const FloatRect& rect, const CGRendererColorValue& color)
{
    RemoteGraphicsContext::fillRectWithColor(rect, CGRendererColorFromValue(color));
}

void RemoteImageBufferGraphicsContext::fillCompositedRect(const FloatRect& rect, const CGRendererColorValue& color, CompositeOperator op, BlendMode blendMode)
{
    RemoteGraphicsContext::fillCompositedRect(rect, CGRendererColorFromValue(color), op, blendMode);
}

void RemoteImageBufferGraphicsContext::fillRoundedRect(const FloatRoundedRect& rect, const CGRendererColorValue& color, BlendMode blendMode)
{
    RemoteGraphicsContext::fillRoundedRect(rect, CGRendererColorFromValue(color), blendMode);
}

void RemoteImageBufferGraphicsContext::fillRectWithRoundedHole(const FloatRect& rect, const FloatRoundedRect& roundedHoleRect, const CGRendererColorValue& color)
{
    RemoteGraphicsContext::fillRectWithRoundedHole(rect, roundedHoleRect, CGRendererColorFromValue(color));
}

void RemoteImageBufferGraphicsContext::drawLinesForText(const FloatPoint& point, float thickness, const RemoteCGRendererLineSegments& lineSegments, bool printing, bool doubleLines, StrokeStyle strokeStyle)
{
    RemoteGraphicsContext::drawLinesForText(point, thickness, lineSegments.span(), printing, doubleLines, strokeStyle);
}

void RemoteImageBufferGraphicsContext::drawDotsForDocumentMarker(const FloatRect& rect, DocumentMarkerLineStyleMode mode, const CGRendererColorValue& color)
{
    RemoteGraphicsContext::drawDotsForDocumentMarker(rect, { mode, CGRendererColorFromValue(color) });
}

void RemoteImageBufferGraphicsContext::drawGlyphs(RenderingResourceIdentifier fontIdentifier, const RemoteCGRendererGlyphs& glyphs, FloatPoint localAnchor, FontSmoothingMode smoothingMode)
{
    const Vector<GlyphBufferGlyph, 128> glyphsCopy { glyphs.glyphs() };
    Vector<FloatSize, 128> advances;
    advances.appendContainerWithMapping(glyphs.advances(), [](auto& advance) { return FloatSize { advance }; });
    RemoteGraphicsContext::drawGlyphs(fontIdentifier, { glyphsCopy.span().data(), advances.span().data(), glyphsCopy.size() }, localAnchor, smoothingMode);
}

void RemoteImageBufferGraphicsContext::fillRectWithCachedGradient(const FloatRect& rect, RemoteGradientIdentifier identifier)
{
    RefPtr gradient = resourceCache().cachedGradient(identifier);
    MESSAGE_CHECK(gradient);
    context().fillRect(rect, *gradient);
}

void RemoteImageBufferGraphicsContext::fillRectWithCachedGradientAndSpaceTransform(const FloatRect& rect, RemoteGradientIdentifier identifier, const AffineTransform& transform, RequiresClipToRect requiresClipToRect)
{
    RefPtr gradient = resourceCache().cachedGradient(identifier);
    MESSAGE_CHECK(gradient);
    context().fillRect(rect, *gradient, transform, requiresClipToRect);
}

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
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
#endif

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS)
