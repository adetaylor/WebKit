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

#include "GPUConnectionToWebProcess.h"
#include "ImageBufferShareableAllocator.h"
#include "IPCSemaphore.h"
#include "RemoteCGRendererGlyphs.h"
#include "RemoteRenderingBackend.h"
#include "RemoteResourceCache.h"
#include "RemoteSharedResourceCache.h"
#include "SharedFont.h"
#include "SharedPreferencesForWebProcess.h"
#include "SharedVideoFrame.h"
#include <WebCore/ControlFactory.h>
#include <WebCore/FEImage.h>
#include <WebCore/FilterResults.h>
#include <WebCore/Gradient.h>
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/NativeImage.h>
#include <WebCore/SVGFilterRenderer.h>

#if USE(SYSTEM_PREVIEW)
#include <WebCore/ARKitBadgeSystemImage.h>
#endif

#if PLATFORM(COCOA) && ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeap.h"
#include <WebCore/VideoFrame.h>
#endif

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

RefPtr<SharedFont> RemoteCGRendererResources::cachedFont(RenderingResourceIdentifier identifier) const
{
    return m_backend->remoteResourceCache().cachedFont(identifier);
}

RemoteCGRendererGlyphDraw makeRemoteCGRendererGlyphDraw()
{
    return { };
}

RemoteCGRendererGlyphDraw::~RemoteCGRendererGlyphDraw() = default;

RemoteCGRendererGlyphPreparationResult RemoteCGRendererGlyphDraw::prepare(const RemoteCGRendererGlyphs& glyphs, const RemoteCGRendererResources& resources, RenderingResourceIdentifier fontIdentifier, FontSmoothingMode smoothingMode, const CGRendererGlyphContext& glyphContext)
{
    m_preparation = std::nullopt;
    m_positions.clear();
    m_glyphs.clear();
    m_glyphs.append(glyphs.glyphs());
    // At the precision of RemoteGraphicsContext's DrawGlyphs, so that the run draws as it does there.
    m_advances.clear();
    m_advances.appendContainerWithMapping(glyphs.advances(), [](auto& advance) {
        return GlyphBufferAdvance { static_cast<float>(advance.width), static_cast<float>(advance.height) };
    });
    RefPtr font = resources.cachedFont(fontIdentifier);
    if (!font)
        return { false, false };
    auto& context = static_cast<GraphicsContextCG&>(resources.target().context());
    // The fill color is only for the shadow's.
    std::optional<Color> simpleShadowColor;
    std::optional<Color> fillColor;
    if (glyphContext.hasSimpleShadow) {
        simpleShadowColor = CGRendererColorFromValue(glyphContext.shadowColor);
        fillColor = CGRendererColorFromValue(glyphContext.fillColor);
    }
    m_preparation.emplace(*font, m_glyphs.span(), smoothingMode, simpleShadowColor ? &*simpleShadowColor : nullptr, fillColor ? *fillColor : Color::black, context.colorSpace(), context.isInTransparencyLayer() || glyphContext.hasReceiverTransparencyLayer);
    if (!m_preparation->draws() || !m_preparation->font())
        return { true, false };
    m_positions.grow(m_glyphs.size());
    return { true, true };
}

CGColorRef copyGlyphShadowFillColor(const RemoteCGRendererGlyphDraw& draw)
{
    return RetainPtr { draw.shadowFillColor() }.leakRef();
}

RefPtr<Gradient> RemoteCGRendererResources::cachedGradient(RemoteGradientIdentifier identifier) const
{
    return m_backend->remoteResourceCache().cachedGradient(identifier);
}

RefPtr<ImageBuffer> RemoteCGRendererResources::imageBuffer(RenderingResourceIdentifier identifier) const
{
    return m_backend->imageBuffer(identifier);
}

CGImageRef copyNativeImage(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier, const FloatRect& sourceRect, RasterDrawingOptions options, CGRendererImageFacts& facts)
{
    facts = { };
    facts.resolutionScale = 1;
    RefPtr image = resources.cachedNativeImage(identifier);
    if (!image)
        return nullptr;
    facts.found = true;
    CGRendererSetInvertColorMatrix(*image, sourceRect, options, facts);
    return copyImage(*image, facts);
}

CGImageRef copyImageBufferImage(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier, const FloatRect& sourceRect, RasterDrawingOptions options, bool clonesAcceleratedTarget, CGRendererImageFacts& facts)
{
    facts = { };
    facts.resolutionScale = 1;
    RefPtr imageBuffer = resources.imageBuffer(identifier);
    if (!imageBuffer)
        return nullptr;
    facts.found = true;
    Ref target = resources.target();
    if (clonesAcceleratedTarget && imageBuffer == target.ptr() && imageBuffer->renderingMode() == RenderingMode::Accelerated) {
        imageBuffer = imageBuffer->clone();
        if (!imageBuffer)
            return nullptr;
        imageBuffer->flushDrawingContext();
        facts.isSelfCopy = true;
        resources.setSelfCopy(RefPtr { imageBuffer });
    }
    facts.resolutionScale = imageBuffer->resolutionScale();
    RefPtr image = static_cast<GraphicsContextCG&>(target->context()).nativeImageForSwiftReceiver(*imageBuffer);
    if (!image) {
        resources.releaseSelfCopy();
        facts.isSelfCopy = false;
        return nullptr;
    }
    auto scaledSourceRect = sourceRect;
    scaledSourceRect.scale(facts.resolutionScale);
    CGRendererSetInvertColorMatrix(*image, scaledSourceRect, options, facts);
    return copyImage(*image, facts);
}

CGRendererBrushSource cachedGradientBrush(const RemoteCGRendererResources& resources, RemoteGradientIdentifier identifier, const AffineTransform& spaceTransform, bool& found)
{
    RefPtr gradient = resources.cachedGradient(identifier);
    found = !!gradient;
    if (!gradient)
        return { };
    return { gradient.releaseNonNull(), spaceTransform };
}

CGRendererBrushSource nativeImagePatternBrush(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier, const PatternParameters& parameters, bool& found)
{
    RefPtr tileImage = resources.cachedNativeImage(identifier);
    found = !!tileImage;
    if (!tileImage)
        return { };
    return CGRendererBrushSource { WebCore::Pattern::create({ tileImage.releaseNonNull() }, parameters) };
}

CGRendererBrushSource imageBufferPatternBrush(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier, const PatternParameters& parameters, bool& found, bool& drawsIntoTarget)
{
    RefPtr tileImageBuffer = resources.imageBuffer(identifier);
    found = !!tileImageBuffer;
    drawsIntoTarget = tileImageBuffer.get() == &resources.target();
    if (!tileImageBuffer || drawsIntoTarget)
        return { };
    return CGRendererBrushSource { WebCore::Pattern::create({ tileImageBuffer.releaseNonNull() }, parameters) };
}

CFURLRef copyURL(const URL& link)
{
    return link.createCFURL().leakRef();
}

CGImageRef copyNativeImageForClip(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier)
{
    RefPtr image = resources.cachedNativeImage(identifier);
    if (!image)
        return nullptr;
    RetainPtr platformImage = image->platformImage();
    return platformImage.leakRef();
}

ControlFactory& RemoteCGRendererResources::controlFactory() const
{
    if (!m_controlFactory)
        m_controlFactory = ControlFactory::create();
    return *m_controlFactory;
}

#if PLATFORM(COCOA) && ENABLE(VIDEO)
SharedVideoFrameReader& RemoteCGRendererResources::sharedVideoFrameReader() const
{
    if (!m_sharedVideoFrameReader) {
        Ref gpuConnectionToWebProcess = m_backend->gpuConnectionToWebProcess();
        m_sharedVideoFrameReader = makeUnique<SharedVideoFrameReader>(Ref { gpuConnectionToWebProcess->videoFrameObjectHeap() }, gpuConnectionToWebProcess->webProcessIdentity());
    }
    return *m_sharedVideoFrameReader;
}
#endif

bool drawMeshGradient(const RemoteCGRendererResources& resources, CGRendererLeafContext& leaf, RemoteMeshGradientIdentifier identifier, const FloatRect& destination)
{
    RefPtr gradient = resources.backend().remoteResourceCache().cachedMeshGradient(identifier);
    if (!gradient)
        return false;
    leaf.context().drawMeshGradient(*gradient, destination);
    return true;
}

static std::optional<SourceImage> sourceImage(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier)
{
    if (RefPtr sourceNativeImage = resources.cachedNativeImage(identifier))
        return { { sourceNativeImage.releaseNonNull() } };
    if (RefPtr sourceImageBuffer = resources.imageBuffer(identifier))
        return { { sourceImageBuffer.releaseNonNull() } };
    return std::nullopt;
}

bool hasFilterSources(const RemoteCGRendererResources& resources, std::optional<RenderingResourceIdentifier> sourceImageIdentifier, const Ref<Filter>& filter)
{
    if (sourceImageIdentifier && !resources.imageBuffer(*sourceImageIdentifier))
        return false;
    for (auto& effect : filter->effectsOfType(FilterEffect::Type::FEImage)) {
        Ref feImage = downcast<FEImage>(effect.get());
        if (!sourceImage(resources, feImage->sourceImage().imageIdentifier()))
            return false;
    }
    RefPtr svgFilter = dynamicDowncast<SVGFilterRenderer>(filter.get());
    if (svgFilter && svgFilter->hasValidRenderingResourceIdentifier())
        return is<SVGFilterRenderer>(resources.backend().remoteResourceCache().cachedFilter(filter->renderingResourceIdentifier()));
    return true;
}

static bool useIOSurfaceWebKitBehavior(const RemoteCGRendererResources& resources)
{
#if USE(APPLE_INTERNAL_SDK)
    auto preferences = resources.backend().sharedPreferencesForWebProcess();
    return preferences && preferences->useIOSurfaceWebKitBehavior;
#else
    UNUSED_PARAM(resources);
    return false;
#endif
}

static std::unique_ptr<ImageBufferAllocator> filterResultsAllocator(const RemoteCGRendererResources& resources)
{
    Ref sharedResourceCache = resources.backend().sharedResourceCache();
#if HAVE(IOSURFACE)
    return makeUnique<ImageBufferShareableAllocator>(sharedResourceCache->resourceOwner(), &sharedResourceCache->ioSurfacePool(), useIOSurfaceWebKitBehavior(resources));
#else
    return makeUnique<ImageBufferShareableAllocator>(sharedResourceCache->resourceOwner());
#endif
}

bool drawFilteredImageBuffer(const RemoteCGRendererResources& resources, CGRendererLeafContext& leaf, std::optional<RenderingResourceIdentifier> sourceImageIdentifier, const FloatRect& sourceImageRect, const Ref<Filter>& filter)
{
    if (!hasFilterSources(resources, sourceImageIdentifier, filter))
        return false;

    RefPtr<ImageBuffer> sourceImageBuffer;
    if (sourceImageIdentifier)
        sourceImageBuffer = resources.imageBuffer(*sourceImageIdentifier);

    auto draw = [&](Filter& filterToDraw, FilterResults& results) {
        for (auto& effect : filterToDraw.effectsOfType(FilterEffect::Type::FEImage)) {
            Ref feImage = downcast<FEImage>(effect.get());
            feImage->setImageSource(*sourceImage(resources, feImage->sourceImage().imageIdentifier()));
        }
        leaf.context().drawFilteredImageBuffer(sourceImageBuffer.get(), sourceImageRect, filterToDraw, results);
    };

    RefPtr svgFilter = dynamicDowncast<SVGFilterRenderer>(filter.get());
    if (!svgFilter || !svgFilter->hasValidRenderingResourceIdentifier()) {
        FilterResults results(filterResultsAllocator(resources));
        draw(filter.get(), results);
        return true;
    }

    RefPtr cachedSVGFilter = dynamicDowncast<SVGFilterRenderer>(resources.backend().remoteResourceCache().cachedFilter(filter->renderingResourceIdentifier()));
    cachedSVGFilter->mergeEffects(svgFilter->effects());
    auto& results = cachedSVGFilter->ensureResults([&] {
        return makeUnique<FilterResults>(filterResultsAllocator(resources));
    });
    draw(*cachedSVGFilter, results);
    return true;
}

void drawControlPart(const RemoteCGRendererResources& resources, CGRendererLeafContext& leaf, const Ref<ControlPart>& part, const FloatRoundedRect& borderRect, float deviceScaleFactor, const ControlStyle& style)
{
    part->setOverrideControlFactory(&resources.controlFactory());
    leaf.context().drawControlPart(part, borderRect, deviceScaleFactor, style);
    part->setOverrideControlFactory(nullptr);
}

void drawSystemImage(CGRendererLeafContext& leaf, const Ref<SystemImage>& systemImage, const FloatRect& destinationRect)
{
    leaf.context().drawSystemImage(systemImage, destinationRect);
}

#if USE(SYSTEM_PREVIEW)
bool drawBadgeSystemImage(const RemoteCGRendererResources& resources, CGRendererLeafContext& leaf, std::optional<RenderingResourceIdentifier> imageIdentifier, const FloatRect& destinationRect)
{
    RefPtr<NativeImage> nativeImage;
    if (imageIdentifier) {
        nativeImage = resources.cachedNativeImage(*imageIdentifier);
        if (!nativeImage)
            return false;
    }
    Ref badge = ARKitBadgeSystemImage::create(WTF::move(nativeImage));
    leaf.context().drawSystemImage(badge, destinationRect);
    return true;
}
#endif

#if PLATFORM(COCOA) && ENABLE(VIDEO)
CGImageRef copyVideoFrameImage(const RemoteCGRendererResources& resources, const SharedVideoFrame& frame, CGRendererImageFacts& facts, bool& hasAlpha)
{
    facts = { };
    facts.resolutionScale = 1;
    facts.found = true;
    hasAlpha = false;
    RefPtr videoFrame = resources.sharedVideoFrameReader().read(SharedVideoFrame { frame });
    if (!videoFrame)
        return nullptr;
    RefPtr image = videoFrame->copyNativeImage();
    if (!image)
        return nullptr;
    hasAlpha = image->hasAlpha();
    return copyImage(*image, facts);
}

void setSharedVideoFrameSemaphore(const RemoteCGRendererResources& resources, const IPC::Semaphore& semaphore)
{
    resources.sharedVideoFrameReader().setSemaphore(IPC::Semaphore { semaphore.createSendRight() });
}

void setSharedVideoFrameMemory(const RemoteCGRendererResources& resources, const SharedMemory::Handle& handle)
{
    resources.sharedVideoFrameReader().setSharedMemory(SharedMemory::Handle { handle });
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
