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

#pragma once

#if ENABLE(GPU_PROCESS)

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && !ENABLE(RE_DYNAMIC_CONTENT_SCALING)

#include "RemoteGraphicsContextIdentifier.h"
#include "RemoteRenderingBackend.h"
#include "StreamServerConnection.h"
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/GraphicsLayerContentsDisplayDelegate.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/PlatformCALayerDelegatedContents.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace IPC {
template<typename> class CxxDecodedArgument;
class SwiftReplyEncoder;
}

namespace WebCore {
class SharedMemoryHandle;
struct PixelBufferFormat;
}

namespace WebKit {

// What RemoteImageBufferGraphicsContext::getPixelBuffer() did, so that Swift can check the message.
enum class RemoteImageBufferPixelsResult : uint8_t {
    Copied,
    NoSharedMemory,
    UnsupportedFormat,
    SharedMemoryTooSmall,
};

// The lender of the renderer of the context that an image buffer's drawing is drawn into, to the receiver of that drawing
// (RemoteCGRenderer), which it starts, for each message; for a buffer whose drawing is recorded, the image buffer's receiver
// records the drawing instead (RemoteImageBuffer.swift). The generated forwarder's per-message lend is inline here, with
// the work on WebCore types that Swift can't do safely.
class RemoteImageBufferGraphicsContext final : public ThreadSafeRefCounted<RemoteImageBufferGraphicsContext> {
public:
    static RemoteImageBufferGraphicsContext* WTF_NONNULL createForSwift(WebCore::ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& backend) SWIFT_RETURNS_RETAINED
    {
        Ref context = adoptRef(*new RemoteImageBufferGraphicsContext(imageBuffer, identifier, backend));
        context->startListeningForIPC();
        return &context.leakRef();
    }
    ~RemoteImageBufferGraphicsContext()
    {
        if (m_isSwiftRendererLender)
            cgContext().removeSwiftRendererLender();
    }
    void stopListeningForIPC() { m_renderingBackend->streamConnection().stopReceivingMessages(IPC::ReceiverName::RemoteCGRenderer, m_identifier.toUInt64()); }

    // For the Swift receiver of an image buffer whose drawing is recorded: the drawing that the one placeholder of the WebCore
    // display list that its context records draws, which the placeholder keeps. Unsafe: the drawing must be a retained
    // RemoteCGRendererRecordedDrawing that nothing else releases.
    SWIFT_UNSAFE void installRecordedDrawing(uintptr_t);
    // Copies the pixels of the rect into the shared memory that the rendering backend keeps for them, as the buffer's
    // getPixelBuffer() gives them in the format, or zeroes the memory if it gives none.
    RemoteImageBufferPixelsResult getPixelBuffer(IPC::CxxDecodedArgument<WebCore::PixelBufferFormat>&, int x, int y, int width, int height);
    // Maps the memory of the handle as the shared memory that the rendering backend keeps for pixels: false if it can't be
    // mapped, in which case the backend keeps none.
    bool setPixelBufferSharedMemory(IPC::CxxDecodedArgument<WebCore::SharedMemoryHandle>&);
    // Caches a copy of the buffer's image, or a placeholder if there is none, as the native image with the identifier: false
    // if one already has it.
    bool copyNativeImage(uint64_t imageIdentifier);
    void encodeBackendHandle(IPC::SwiftReplyEncoder&);
    // Prepares the buffer for display, and encodes the send right of the surface to display, or none. The display may still
    // be drawing it: waitForDisplayBuffer() waits until it is done, or until a timeout.
    void encodeDisplayBuffer(IPC::SwiftReplyEncoder&);
    void waitForDisplayBuffer();

    // RemoteCGRenderer's handlers' state, the context's renderer, which the context lends for one message.
    WebCore::GraphicsContextCG::SwiftRendererLend lendSwiftReceiverState() { return WebCore::GraphicsContextCG::lendSwiftRenderer(cgContext()); }

private:
    RemoteImageBufferGraphicsContext(WebCore::ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& backend)
        : m_renderingBackend(backend)
        , m_context(imageBuffer.context())
        , m_imageBuffer(imageBuffer)
        , m_identifier(identifier)
    {
        // The context of an image buffer that failed to allocate (NullImageBufferBackend) draws nothing and can't lend a
        // renderer: its drawing is drawn into an image buffer of its own, which nothing shows.
        if (!m_context.canLendSwiftRenderer() && imageBuffer.renderingMode() != WebCore::RenderingMode::DisplayList)
            m_discardedDrawingTarget = WebCore::ImageBuffer::create({ 1, 1 }, WebCore::RenderingMode::Unaccelerated, WebCore::RenderingPurpose::Unspecified, 1, WebCore::ColorSpace::SRGB(), WebCore::PixelFormat::BGRA8);
        m_isSwiftRendererLender = drawingContext().canLendSwiftRenderer();
        if (m_isSwiftRendererLender)
            cgContext().addSwiftRendererLender();
    }

    // Starts the receiver of the drawing, if the context lends a renderer.
    void startListeningForIPC();


    // The context that the Swift receiver draws into: the image buffer's, or for a buffer that failed to allocate, its
    // discarded drawing target's.
    WebCore::GraphicsContext& drawingContext() { return m_discardedDrawingTarget ? m_discardedDrawingTarget->context() : m_context; }
    WebCore::GraphicsContextCG& cgContext() { return static_cast<WebCore::GraphicsContextCG&>(drawingContext()); }

    const Ref<RemoteRenderingBackend> m_renderingBackend;
    WebCore::GraphicsContext& m_context;
    const Ref<WebCore::ImageBuffer> m_imageBuffer;
    const RemoteGraphicsContextIdentifier m_identifier;
    // What the drawing of an image buffer that failed to allocate is drawn into.
    RefPtr<WebCore::ImageBuffer> m_discardedDrawingTarget;
    // Whether this counts itself as a lender of its GraphicsContextCG's renderer.
    bool m_isSwiftRendererLender { false };
    RefPtr<WebCore::GraphicsLayerContentsDisplayDelegate> m_displayDelegate;
    RefPtr<WebCore::PlatformCALayerDelegatedContentsFence> m_displayBufferFence;
};

} // namespace WebKit

#else

#include "RemoteGraphicsContextIdentifier.h"

#include "RemoteGraphicsContext.h"

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#include "ArrayReferenceTuple.h"
#include <WebCore/GlyphBufferMembers.h>
#include <array>
#include <span>
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "ScopedRenderingResourcesRequest.h"
#include <WebCore/AlphaPremultiplication.h>
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/IntPoint.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#endif

namespace IPC {
template<typename> class CxxDecodedArgument;
class SwiftReplyEncoder;
}

namespace WebCore {
class GraphicsLayerContentsDisplayDelegate;
class PlatformCALayerDelegatedContentsFence;
class ImageBuffer;
class PixelBufferSourceView;
class SharedMemoryHandle;
struct PixelBufferFormat;
}

namespace WebKit {

class RemoteRenderingBackend;

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
// What RemoteImageBufferGraphicsContext::getPixelBuffer() did, so that Swift can check the message.
enum class RemoteImageBufferPixelsResult : uint8_t {
    Copied,
    NoSharedMemory,
    UnsupportedFormat,
    SharedMemoryTooSmall,
};

enum class RemoteCGRendererStyleKind : uint8_t;
#endif

class RemoteImageBufferGraphicsContext;

// RemoteGraphicsContext playing back the IPC GraphicsContext drawing commands to a GraphicsContext of an ImageBuffer.
// Used to create renderings to the ImageBuffer. With the CG renderer in Swift, it takes RemoteCGRenderer's messages for a
// context that can't lend its renderer, a dynamic content scaling image buffer's.
using RemoteImageBufferGraphicsContextBase = RemoteGraphicsContext;

class RemoteImageBufferGraphicsContext final : public RemoteImageBufferGraphicsContextBase {
public:
    static Ref<RemoteImageBufferGraphicsContext> create(WebCore::ImageBuffer&, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);
    ~RemoteImageBufferGraphicsContext();
    void stopListeningForIPC();

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // The context of the image buffer that an image buffer's Swift receiver (RemoteImageBuffer.swift) receives the messages
    // of, from the buffer's creation until the receiver releases it with stopListeningForIPC() and releaseImageBuffer(). It
    // counts the buffer in the shared resource cache, and keeps the GPU process's rendering resources, until then. The
    // other members are the receiver's handlers' work on WebCore types that Swift has no form of.
    static RemoteImageBufferGraphicsContext* WTF_NONNULL createForImageBufferReceiver(WebCore::ImageBuffer&, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&) SWIFT_RETURNS_RETAINED;
    // For the Swift receiver of an image buffer, which counts the buffer itself (RemoteImageBuffer.swift).
    static RemoteImageBufferGraphicsContext* WTF_NONNULL createForSwift(WebCore::ImageBuffer& imageBuffer, RemoteGraphicsContextIdentifier identifier, RemoteRenderingBackend& backend) SWIFT_RETURNS_RETAINED { return &create(imageBuffer, identifier, backend).leakRef(); }
    // Stops counting the buffer, and unwinds its context's state stack, whose restores may never come, as the web process may
    // have gone.
    void releaseImageBuffer();
    // For the Swift receiver of an image buffer whose drawing is recorded: the drawing that the one placeholder of the WebCore
    // display list that its context records draws, which the placeholder keeps. Unsafe: the drawing must be a retained
    // RemoteCGRendererRecordedDrawing that nothing else releases.
    SWIFT_UNSAFE void installRecordedDrawing(uintptr_t);

    // Copies the pixels of the rect into the shared memory that the rendering backend keeps for them, as the buffer's
    // getPixelBuffer() gives them in the format, or zeroes the memory if it gives none.
    RemoteImageBufferPixelsResult getPixelBuffer(IPC::CxxDecodedArgument<WebCore::PixelBufferFormat>&, int x, int y, int width, int height);
    // Maps the memory of the handle as the shared memory that the rendering backend keeps for pixels: false if it can't be
    // mapped, in which case the backend keeps none.
    bool setPixelBufferSharedMemory(IPC::CxxDecodedArgument<WebCore::SharedMemoryHandle>&);
    void putPixelBuffer(const WebCore::PixelBufferSourceView&, WebCore::IntPoint srcPoint, WebCore::IntSize srcSize, WebCore::IntPoint destPoint, WebCore::AlphaPremultiplication destFormat);
    // Caches a copy of the buffer's image, or a placeholder if there is none, as the native image with the identifier: false
    // if one already has it.
    bool copyNativeImage(uint64_t imageIdentifier);
    void encodeBackendHandle(IPC::SwiftReplyEncoder&);
#if PLATFORM(COCOA)
    // Prepares the buffer for display, and encodes the send right of the surface to display, or none. The display may still
    // be drawing it: waitForDisplayBuffer() waits until it is done, or until a timeout.
    void encodeDisplayBuffer(IPC::SwiftReplyEncoder&);
    void waitForDisplayBuffer();
#endif
#endif

    void drawImageBuffer(WebCore::RenderingResourceIdentifier imageBufferIdentifier, const WebCore::FloatRect& destinationRect, const WebCore::FloatRect& srcRect, WebCore::RasterDrawingOptions) final;
    bool drawsInto(const WebCore::ImageBuffer& imageBuffer) const final { return &imageBuffer == m_imageBuffer.ptr(); }

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    // RemoteCGRenderer's messages whose arguments differ from RemoteGraphicsContext's, as RemoteGraphicsContext draws them.
    void drawFocusRingPath(const WebCore::Path&, float outlineWidth, const CGRendererColorValue&, float zoomFactor);
    void setDropShadow(const CGRendererShadowValues&, const CGRendererColorData&, bool hasShadow);
    void setStyle(RemoteCGRendererStyleKind, const CGRendererShadowValues&, const CGRendererColorData&, bool hasShadow, float blurWidth, float blurHeight, const std::array<float, 20>& colorMatrix);
    void setLineDash(std::span<const double>, float dashOffset);
    void setFillColor(const CGRendererColorValue&);
    void setStrokeColor(const CGRendererColorValue&);
    void fillRectWithColor(const WebCore::FloatRect&, const CGRendererColorValue&);
    void fillCompositedRect(const WebCore::FloatRect&, const CGRendererColorValue&, WebCore::CompositeOperator, WebCore::BlendMode);
    void fillRoundedRect(const WebCore::FloatRoundedRect&, const CGRendererColorValue&, WebCore::BlendMode);
    void fillRectWithRoundedHole(const WebCore::FloatRect&, const WebCore::FloatRoundedRect&, const CGRendererColorValue&);
    void fillRectWithCachedGradient(const WebCore::FloatRect&, RemoteGradientIdentifier);
    void drawDotsForDocumentMarker(const WebCore::FloatRect&, WebCore::DocumentMarkerLineStyleMode, const CGRendererColorValue&);
    void drawGlyphs(WebCore::RenderingResourceIdentifier fontIdentifier, const IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance>&, WebCore::FloatPoint localAnchor, WebCore::FontSmoothingMode);
    void fillRectWithCachedGradientAndSpaceTransform(const WebCore::FloatRect&, RemoteGradientIdentifier, const WebCore::AffineTransform&, WebCore::RequiresClipToRect);
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // RemoteCGRenderer's handlers' state, the context's renderer, which the context lends for one message. The context is
    // the image buffer's; this counts itself as its lender (addSwiftRendererLender()).
    WebCore::GraphicsContextCG::SwiftRendererLend lendSwiftReceiverState() { return WebCore::GraphicsContextCG::lendSwiftRenderer(cgContext()); }
#endif

private:
    RemoteImageBufferGraphicsContext(WebCore::ImageBuffer&, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);
    void startListeningForIPC();

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    void didReceiveCGRendererMessage(IPC::StreamServerConnection&, IPC::Decoder&);
    void setFillPackedColorValue(uint32_t);
    void setStrokePackedColorValue(uint32_t);
    void setStrokePackedColorValueAndThickness(uint32_t, float);
    void drawRecordedDisplayList(RemoteDisplayListIdentifier);
#endif

    WebCore::GraphicsContext& imageBufferContext() { return context(); }
    const Ref<WebCore::ImageBuffer> m_imageBuffer;
    const RemoteGraphicsContextIdentifier m_identifier;
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // The context that the Swift receiver draws into: the image buffer's, or for a buffer that failed to allocate, its
    // discarded drawing target's.
    WebCore::GraphicsContext& drawingContext();
    WebCore::GraphicsContextCG& cgContext() { return static_cast<WebCore::GraphicsContextCG&>(drawingContext()); }
    // Whether this counts itself as a lender of its GraphicsContextCG's renderer, while it has a Swift receiver.
    bool m_isSwiftRendererLender { false };
    // What the drawing of an image buffer that failed to allocate is drawn into.
    RefPtr<WebCore::ImageBuffer> m_discardedDrawingTarget;
    // For an image buffer's Swift receiver: whether the buffer is still counted, and what it keeps.
    bool m_countsImageBuffer { false };
    ScopedRenderingResourcesRequest m_renderingResourcesRequest;
#if PLATFORM(COCOA)
    RefPtr<WebCore::GraphicsLayerContentsDisplayDelegate> m_displayDelegate;
    RefPtr<WebCore::PlatformCALayerDelegatedContentsFence> m_displayBufferFence;
#endif
#endif
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && !ENABLE(RE_DYNAMIC_CONTENT_SCALING)

#endif // ENABLE(GPU_PROCESS)
