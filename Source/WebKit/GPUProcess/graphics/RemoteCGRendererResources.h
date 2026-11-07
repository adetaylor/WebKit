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

#pragma once

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "RemoteCGRendererPath.h"
#include "RemotePathImplIdentifier.h"
#include <WebCore/Color.h>
#include <WebCore/FloatRoundedRect.h>
#include <WebCore/GraphicsTypes.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {
class ImageBuffer;
class NativeImage;
}

namespace WebKit {

class RemoteRenderingBackend;

// What an image buffer's RemoteCGRenderer looks up by identifier, in its rendering backend's resource cache and image buffers,
// as RemoteGraphicsContext's handlers do.
class RemoteCGRendererResources final : public RefCounted<RemoteCGRendererResources> {
public:
    static Ref<RemoteCGRendererResources> create(RemoteRenderingBackend& backend, WebCore::ImageBuffer& target) { return adoptRef(*new RemoteCGRendererResources(backend, target)); }
    ~RemoteCGRendererResources();

    // The cached path, or one that isn't valid.
    RemoteCGRendererPath cachedPath(RemotePathImplIdentifier) const;

    // The cached native image's image, which is null for an image this process can't read.
    RefPtr<WebCore::NativeImage> cachedNativeImage(WebCore::RenderingResourceIdentifier) const;
    WebCore::ImageBuffer& target() const { return m_target; }
    RefPtr<WebCore::ImageBuffer> imageBuffer(WebCore::RenderingResourceIdentifier) const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { RefCounted<RemoteCGRendererResources>::ref(); }
    void deref() const { RefCounted<RemoteCGRendererResources>::deref(); }
#endif

private:
    RemoteCGRendererResources(RemoteRenderingBackend&, WebCore::ImageBuffer& target);

    const Ref<RemoteRenderingBackend> m_backend;
    const Ref<WebCore::ImageBuffer> m_target;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// What the renderer takes of a color, as GraphicsContextCG converts one for the receiver's context, with the CGColor, which
// this returns, of a color that isn't sRGBA8. Inline for the sRGBA8 colors that most are.
CGColorRef _Nullable copyPlatformColor(const RemoteCGRendererResources&, const WebCore::Color&, CGRendererColorValue&) CF_RETURNS_RETAINED;
inline CGColorRef _Nullable copyColor(const RemoteCGRendererResources& resources, const WebCore::Color& color, CGRendererColorValue& value) CF_RETURNS_RETAINED
{
    if (auto packedColor = color.tryGetAsPackedInline()) {
        value = { };
        value.isPacked = true;
        value.packedColor = packedColor->value;
        value.isVisible = color.isVisible();
        return nullptr;
    }
    return copyPlatformColor(resources, color, value);
}

// The image of a ClipToNativeImage.
CGImageRef _Nullable copyNativeImageForClip(const RemoteCGRendererResources&, WebCore::RenderingResourceIdentifier) CF_RETURNS_RETAINED;

// The CFURL of a SetURLForRect's link, as GraphicsContextCG::setURLForRect() makes it.
CFURLRef _Nullable copyURL(const URL&) CF_RETURNS_RETAINED;

inline WebCore::FloatRect rectOfRoundedRect(const WebCore::FloatRoundedRect& rect)
{
    return rect.rect();
}

inline uint8_t textDrawingModeValue(WebCore::TextDrawingModeFlags mode)
{
    return mode.toRaw();
}

// The image of a cached native image, which is null for an image this process can't read, and of an image buffer other than
// the target, as GraphicsContext draws one (nativeImageForDrawing()): the receiver declines the target's own. Functions, since
// Swift takes what a C++ method returns as unretained whatever its annotation.
CGImageRef _Nullable copyNativeImage(const RemoteCGRendererResources&, WebCore::RenderingResourceIdentifier, CGRendererImageFacts&) CF_RETURNS_RETAINED;
CGImageRef _Nullable copyImageBufferImage(const RemoteCGRendererResources&, WebCore::RenderingResourceIdentifier, CGRendererImageFacts&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
