/*
 * Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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

#include "config.h"
#include "RemoteCGRendererResources.h"

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "RemoteCGRendererShadow.h"
#include "RemoteCGRendererStyle.h"
#include "RemoteRenderingBackend.h"
#include "RemoteResourceCache.h"
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/NativeImage.h>

namespace WebKit {
using namespace WebCore;

RemoteCGRendererResources::RemoteCGRendererResources(RemoteRenderingBackend& backend, ImageBuffer& target)
    : m_backend(backend)
    , m_target(target)
{
}

RemoteCGRendererResources::~RemoteCGRendererResources() = default;

RemoteCGRendererPath RemoteCGRendererResources::cachedPath(RemotePathImplIdentifier identifier) const
{
    RefPtr pathImpl = m_backend->remoteResourceCache().cachedPathImpl(identifier);
    if (!pathImpl)
        return { };
    return RemoteCGRendererPath { pathImpl.releaseNonNull() };
}

static CGImageRef copyImage(const NativeImage& image, CGRendererImageFacts& facts)
{
    auto size = image.size();
    facts.width = size.width();
    facts.height = size.height();
    facts.headroom = image.headroom();
    return image.platformImage().leakRef();
}

RefPtr<NativeImage> RemoteCGRendererResources::cachedNativeImage(RenderingResourceIdentifier identifier) const
{
    return m_backend->remoteResourceCache().cachedNativeImage(identifier);
}

RefPtr<ImageBuffer> RemoteCGRendererResources::imageBuffer(RenderingResourceIdentifier identifier) const
{
    return m_backend->imageBuffer(identifier);
}

CGImageRef copyNativeImage(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier, CGRendererImageFacts& facts)
{
    facts = { 0, 0, 1, 1, false, false };
    RefPtr image = resources.cachedNativeImage(identifier);
    if (!image)
        return nullptr;
    facts.found = true;
    return copyImage(*image, facts);
}

CGImageRef copyImageBufferImage(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier, CGRendererImageFacts& facts)
{
    facts = { 0, 0, 1, 1, false, false };
    RefPtr imageBuffer = resources.imageBuffer(identifier);
    if (!imageBuffer)
        return nullptr;
    facts.found = true;
    Ref target = resources.target();
    if (imageBuffer == target.ptr()) {
        facts.declines = true;
        return nullptr;
    }
    facts.resolutionScale = imageBuffer->resolutionScale();
    RefPtr image = static_cast<GraphicsContextCG&>(target->context()).nativeImageForSwiftReceiver(*imageBuffer);
    if (!image)
        return nullptr;
    return copyImage(*image, facts);
}

CGImageRef copyNativeImageForClip(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier)
{
    RefPtr image = resources.cachedNativeImage(identifier);
    if (!image)
        return nullptr;
    RetainPtr platformImage = image->platformImage();
    return platformImage.leakRef();
}

static GraphicsContextCG& targetContext(const RemoteCGRendererResources& resources)
{
    return static_cast<GraphicsContextCG&>(resources.target().context());
}

CGColorRef copyPlatformColor(const RemoteCGRendererResources& resources, const Color& color, CGRendererColorValue& value)
{
    return CGRendererCopyColor(targetContext(resources), color, value);
}

CGColorRef copyShadow(const RemoteCGRendererResources& resources, const RemoteCGRendererShadow& shadow, CGRendererShadowValues& values, CGRendererColorData& color)
{
    values = { };
    color = { };
    if (!shadow.shadow())
        return nullptr;
    return CGRendererCopyShadow(targetContext(resources), *shadow.shadow(), values, color);
}

CGColorRef copyStyleShadow(const RemoteCGRendererResources& resources, const RemoteCGRendererStyle& style, CGRendererShadowValues& values, CGRendererColorData& color)
{
    values = { };
    color = { };
    auto* shadow = style.dropShadow();
    if (!shadow)
        return nullptr;
    return CGRendererCopyShadow(targetContext(resources), *shadow, values, color);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
