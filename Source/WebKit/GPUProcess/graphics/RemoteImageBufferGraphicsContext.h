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

#include "RemoteGraphicsContext.h"

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include <WebCore/GraphicsContextCG.h>
#endif

namespace WebKit {

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
class RemoteCGRenderer;
class RemoteCGRendererLineStrokes;
class RemoteCGRendererPath;
class RemoteCGRendererPathSegment;
class RemoteCGRendererGlyphs;
class RemoteCGRendererLineDash;
class RemoteCGRendererLineSegments;
struct RemoteCGRendererShadow;
struct RemoteCGRendererStyle;
#endif

// RemoteGraphicsContext playing back the IPC GraphicsContext drawing commands to a GraphicsContext of an ImageBuffer.
// Used to create renderings to the ImageBuffer.
class RemoteImageBufferGraphicsContext final : public RemoteGraphicsContext {
public:
    static Ref<RemoteImageBufferGraphicsContext> create(WebCore::ImageBuffer&, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);
    ~RemoteImageBufferGraphicsContext();
    void stopListeningForIPC();

    void drawImageBuffer(WebCore::RenderingResourceIdentifier imageBufferIdentifier, const WebCore::FloatRect& destinationRect, const WebCore::FloatRect& srcRect, WebCore::RasterDrawingOptions) final;
    bool drawsInto(const WebCore::ImageBuffer& imageBuffer) const final { return &imageBuffer == m_imageBuffer.ptr(); }

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // RemoteCGRenderer's paths and path segments, which its Swift handlers decline for a gradient, as RemoteGraphicsContext
    // draws them.
    void fillPathSegment(const RemoteCGRendererPathSegment&);
    void strokePathSegment(const RemoteCGRendererPathSegment&);
    void fillPath(const RemoteCGRendererPath&);
    void strokePath(const RemoteCGRendererPath&);
    void drawPath(const RemoteCGRendererPath&);
    void clipPath(const RemoteCGRendererPath&, WebCore::WindRule);
    void clipOutToPath(const RemoteCGRendererPath&);
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
    void drawGlyphs(WebCore::RenderingResourceIdentifier fontIdentifier, const RemoteCGRendererGlyphs&, WebCore::FloatPoint localAnchor, WebCore::FontSmoothingMode);
    void fillRectWithCachedGradientAndSpaceTransform(const WebCore::FloatRect&, RemoteGradientIdentifier, const WebCore::AffineTransform&, WebCore::RequiresClipToRect);
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // RemoteCGRenderer's handlers' state, the context's renderer, which the context lends for one message. The context is
    // the one this receiver's C++ handlers draw into; this counts itself as its lender (addSwiftRendererLender()).
    WebCore::GraphicsContextCG::SwiftRendererLend lendSwiftReceiverState() { return WebCore::GraphicsContextCG::lendSwiftRenderer(cgContext()); }
#endif


private:
    RemoteImageBufferGraphicsContext(WebCore::ImageBuffer&, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);
    void startListeningForIPC();

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    // RemoteCGRenderer's messages, for a context without a Swift renderer: drawn through the context, as
    // RemoteGraphicsContext's.
    void didReceiveCGRendererMessage(IPC::StreamServerConnection&, IPC::Decoder&);
    void setFillPackedColorValue(uint32_t);
    void setStrokePackedColorValue(uint32_t);
    void setStrokePackedColorValueAndThickness(uint32_t, float);
    void strokeLines(const RemoteCGRendererLineStrokes&);
#endif

    const Ref<WebCore::ImageBuffer> m_imageBuffer;
    const RemoteGraphicsContextIdentifier m_identifier;
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
    // Takes RemoteCGRenderer's messages when the context draws with a Swift renderer, which it lends their handlers. Used
    // only on the work queue.
    std::unique_ptr<RemoteCGRenderer> m_cgRenderer;
    WebCore::GraphicsContextCG& cgContext() { return static_cast<WebCore::GraphicsContextCG&>(context()); }
    // Whether this counts itself as a lender of its GraphicsContextCG's renderer, while it has a Swift receiver.
    bool m_isSwiftRendererLender { false };
#endif
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
