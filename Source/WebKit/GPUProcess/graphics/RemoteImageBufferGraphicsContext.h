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

#include "RemoteGraphicsContextIdentifier.h"

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#include "RemoteGraphicsContext.h"
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

class RemoteCGRendererLineStrokes;
class RemoteCGRendererPathSegment;
class RemoteCGRendererGlyphs;
class RemoteCGRendererLineDash;
class RemoteCGRendererLineSegments;
struct RemoteCGRendererShadow;
struct RemoteCGRendererStyle;
#endif

class RemoteImageBufferGraphicsContext;

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
// RemoteGraphicsContext playing back the IPC GraphicsContext drawing commands to a GraphicsContext of an ImageBuffer.
// Used to create renderings to the ImageBuffer. With the CG renderer in Swift, it takes RemoteCGRenderer's messages for a
// context that can't lend its renderer, a dynamic content scaling image buffer's.
using RemoteImageBufferGraphicsContextBase = RemoteGraphicsContext;
#else
// The receiver of an image buffer's drawing, in Swift: RemoteCGRenderer, to which the buffer's context lends its renderer
// for each message, or, for a buffer whose drawing is recorded, a recorder (RemoteCGRendererRecorder), whose recording is
// drawn where the buffer is.
using RemoteImageBufferGraphicsContextBase = ThreadSafeRefCounted<RemoteImageBufferGraphicsContext>;
#endif

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
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    void encodeDynamicContentScalingDisplayList(IPC::SwiftReplyEncoder&);
#endif
#endif

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    void drawImageBuffer(WebCore::RenderingResourceIdentifier imageBufferIdentifier, const WebCore::FloatRect& destinationRect, const WebCore::FloatRect& srcRect, WebCore::RasterDrawingOptions) final;
    bool drawsInto(const WebCore::ImageBuffer& imageBuffer) const final { return &imageBuffer == m_imageBuffer.ptr(); }
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    // RemoteCGRenderer's messages whose arguments differ from RemoteGraphicsContext's, as RemoteGraphicsContext draws them.
    void fillPathSegment(const RemoteCGRendererPathSegment&);
    void strokePathSegment(const RemoteCGRendererPathSegment&);
    void drawFocusRingPath(const WebCore::Path&, float outlineWidth, const CGRendererColorValue&, float zoomFactor);
    void setDropShadow(const RemoteCGRendererShadow&);
    void setStyle(const RemoteCGRendererStyle&);
    void setLineDash(const RemoteCGRendererLineDash&, float dashOffset);
    void setFillColor(const CGRendererColorValue&);
    void setStrokeColor(const CGRendererColorValue&);
    void fillRectWithColor(const WebCore::FloatRect&, const CGRendererColorValue&);
    void fillCompositedRect(const WebCore::FloatRect&, const CGRendererColorValue&, WebCore::CompositeOperator, WebCore::BlendMode);
    void fillRoundedRect(const WebCore::FloatRoundedRect&, const CGRendererColorValue&, WebCore::BlendMode);
    void fillRectWithRoundedHole(const WebCore::FloatRect&, const WebCore::FloatRoundedRect&, const CGRendererColorValue&);
    void fillRectWithCachedGradient(const WebCore::FloatRect&, RemoteGradientIdentifier);
    void drawLinesForText(const WebCore::FloatPoint&, float thickness, const RemoteCGRendererLineSegments&, bool printing, bool doubleLines, WebCore::StrokeStyle);
    void drawDotsForDocumentMarker(const WebCore::FloatRect&, WebCore::DocumentMarkerLineStyleMode, const CGRendererColorValue&);
    void drawGlyphs(WebCore::RenderingResourceIdentifier fontIdentifier, const RemoteCGRendererGlyphs&, WebCore::FloatPoint localAnchor, WebCore::FontSmoothingMode);
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
    void strokeLines(const RemoteCGRendererLineStrokes&);
    void drawRecordedDisplayList(RemoteDisplayListIdentifier);
#endif

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) || ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    WebCore::GraphicsContext& imageBufferContext() { return context(); }
#else
    WebCore::GraphicsContext& imageBufferContext() { return m_context; }
    const Ref<RemoteRenderingBackend> m_renderingBackend;
    WebCore::GraphicsContext& m_context;
#endif
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

#endif // ENABLE(GPU_PROCESS)
