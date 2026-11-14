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
#include "RemoteSnapshot.h"
#include "SharedFont.h"
#include "SharedPreferencesForWebProcess.h"
#include "SharedVideoFrame.h"
#include <WebCore/FEImage.h>
#include <WebCore/FilterResults.h>
#include <WebCore/Gradient.h>
#include <WebCore/GraphicsContextCG.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/MeshGradientRendererCPU.h>
#include <WebCore/NativeImage.h>
#include <WebCore/SVGFilterRenderer.h>
#include <wtf/ZippedRange.h>

#if PLATFORM(COCOA) && ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeap.h"
#include <WebCore/VideoFrame.h>
#endif

namespace WebKit {
using namespace WebCore;

Ref<RemoteCGRendererRecordedResources> RemoteCGRendererRecordedResources::create()
{
    return adoptRef(*new RemoteCGRendererRecordedResources);
}

RemoteCGRendererRecordedResources::RemoteCGRendererRecordedResources() = default;

RemoteCGRendererRecordedResources::~RemoteCGRendererRecordedResources() = default;

RefPtr<RemoteCGRendererFont> RemoteCGRendererRecordedResources::font(RenderingResourceIdentifier identifier) const
{
    if (m_firstFont && m_firstFont->key == identifier)
        return m_firstFont->value.ptr();
    return m_fonts.get(identifier);
}

Ref<RemoteCGRendererFont> RemoteCGRendererRecordedResources::addFont(RenderingResourceIdentifier identifier, Ref<RemoteCGRendererFont>&& font)
{
    if (!m_firstFont) {
        m_firstFont.emplace(identifier, WTF::move(font));
        return m_firstFont->value;
    }
    if (m_firstFont->key == identifier)
        return m_firstFont->value;
    return m_fonts.add(identifier, WTF::move(font)).iterator->value;
}

void RemoteCGRendererRecordedResources::setFont(RenderingResourceIdentifier identifier, const Ref<RemoteCGRendererFont>& font)
{
    if (!m_firstFont)
        m_firstFont.emplace(identifier, font);
    else if (m_firstFont->key == identifier)
        m_firstFont->value = font;
    else
        m_fonts.set(identifier, font);
}

Ref<RemoteCGRendererRecordedResources> RemoteCGRendererRecordedResources::copy() const
{
    Ref copy = create();
    copy->m_paths = m_paths;
    copy->m_nativeImages = m_nativeImages;
    copy->m_imageBuffers = m_imageBuffers;
    copy->m_gradients = m_gradients;
    copy->m_firstFont = m_firstFont;
    copy->m_fonts = m_fonts;
    copy->m_meshGradients = m_meshGradients;
    copy->m_filters = m_filters;
    return copy;
}

Ref<RemoteCGRendererResources> RemoteCGRendererResources::createForRecorder(RemoteRenderingBackend& backend, RemoteSnapshot* snapshot)
{
    return adoptRef(*new RemoteCGRendererResources(&backend, nullptr, nullptr, snapshot));
}

RemoteCGRendererResources::RemoteCGRendererResources(RemoteRenderingBackend* backend, ImageBuffer* target, GraphicsContextCG* targetContext, RemoteSnapshot* snapshot)
    : m_backend(backend)
    , m_target(target)
    , m_targetContext(targetContext)
    , m_snapshot(snapshot)
    , m_recordedResources(RemoteCGRendererRecordedResources::create())
{
}

RemoteCGRendererResources::~RemoteCGRendererResources()
{
    ASSERT(m_replayedResources.isEmpty());
}

GraphicsContextCG& RemoteCGRendererResources::targetContext() const
{
    if (m_target)
        return static_cast<GraphicsContextCG&>(m_target->context());
    RELEASE_ASSERT(m_targetContext);
    return *m_targetContext;
}

void RemoteCGRendererResources::beginReplay(RemoteCGRendererRecordedResources& resources) const
{
    m_replayedResources.append(resources);
}

void RemoteCGRendererResources::endReplay() const
{
    m_replayedResources.removeLast();
}

RefPtr<PathImpl> RemoteCGRendererResources::cachedPathImpl(RemotePathImplIdentifier identifier) const
{
    if (isReplaying())
        return m_replayedResources.last()->m_paths.get(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->remoteResourceCache().cachedPathImpl(identifier);
}

RemoteCGRendererPath RemoteCGRendererResources::cachedPath(RemotePathImplIdentifier identifier) const
{
    RefPtr pathImpl = cachedPathImpl(identifier);
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
    if (isReplaying())
        return m_replayedResources.last()->m_nativeImages.get(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->remoteResourceCache().cachedNativeImage(identifier);
}

RefPtr<RemoteCGRendererFont> RemoteCGRendererResources::cachedFont(RenderingResourceIdentifier identifier) const
{
    if (isReplaying())
        return m_replayedResources.last()->font(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->remoteResourceCache().cachedCGRendererFont(identifier);
}

Ref<RemoteCGRendererFont> RemoteCGRendererFont::create(Ref<SharedFont>&& sharedFont)
{
    CGRendererGlyphFontFacts facts;
    CTFontRef ctFont = CGRendererGlyphFontFactsOf(sharedFont.get(), facts);
    return adoptRef(*new RemoteCGRendererFont(WTF::move(sharedFont), ctFont, facts));
}

RemoteCGRendererFont::RemoteCGRendererFont(Ref<SharedFont>&& sharedFont, CTFontRef ctFont, const CGRendererGlyphFontFacts& facts)
    : m_sharedFont(WTF::move(sharedFont))
    , m_ctFont(ctFont)
    , m_facts(facts)
{
}

RemoteCGRendererFont::~RemoteCGRendererFont() = default;

CGRendererGlyphFontFacts RemoteCGRendererFont::factsForGlyphs(std::span<const GlyphBufferGlyph> glyphs) const
{
    if (!m_ctFont)
        return { };
    auto facts = m_facts;
    if (facts.hasComplexColorFormatTables) {
        Locker locker { m_complexColorFormatGlyphsLock };
        if (m_sharedFont->hasAnyComplexColorFormatGlyphs(glyphs)) {
            ASSERT_NOT_REACHED();
            facts.draws = false;
        }
    }
    return facts;
}

CTFontRef copyGlyphsForDraw(const RemoteCGRendererResources& resources, RenderingResourceIdentifier fontIdentifier, const RemoteCGRendererGlyphs& glyphs, std::span<GlyphBufferGlyph> glyphsCopy NOESCAPE, std::span<GlyphBufferAdvance> advancesCopy NOESCAPE, CGRendererGlyphFontFacts& facts, bool& found)
{
    facts = { };
    RefPtr font = resources.cachedFont(fontIdentifier);
    found = !!font;
    if (!font || !font->ctFont())
        return nullptr;
    auto count = std::min({ glyphs.size(), glyphsCopy.size(), advancesCopy.size() });
    memcpySpan(glyphsCopy.first(count), glyphs.glyphs().first(count));
    // At the precision of RemoteGraphicsContext's DrawGlyphs, so that the run draws as it does there.
    for (auto [copy, advance] : zippedRange(advancesCopy.first(count), glyphs.advances().first(count)))
        copy = GlyphBufferAdvance { static_cast<float>(advance.width), static_cast<float>(advance.height) };
    facts = font->factsForGlyphs(glyphsCopy.first(count));
    return RetainPtr { font->ctFont() }.leakRef();
}

RefPtr<Gradient> RemoteCGRendererResources::cachedGradient(RemoteGradientIdentifier identifier) const
{
    if (isReplaying())
        return m_replayedResources.last()->m_gradients.get(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->remoteResourceCache().cachedGradient(identifier);
}

RefPtr<ImageBuffer> RemoteCGRendererResources::imageBuffer(RenderingResourceIdentifier identifier) const
{
    if (isReplaying())
        return m_replayedResources.last()->m_imageBuffers.get(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->imageBuffer(identifier);
}

RefPtr<MeshGradient> RemoteCGRendererResources::cachedMeshGradient(RemoteMeshGradientIdentifier identifier) const
{
    if (isReplaying())
        return m_replayedResources.last()->m_meshGradients.get(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->remoteResourceCache().cachedMeshGradient(identifier);
}

RefPtr<Filter> RemoteCGRendererResources::cachedFilter(RenderingResourceIdentifier identifier) const
{
    if (isReplaying())
        return m_replayedResources.last()->m_filters.get(identifier);
    if (!m_backend)
        return nullptr;
    return m_backend->remoteResourceCache().cachedFilter(identifier);
}

template<typename Map, typename Key, typename Value>
static bool addRecorded(Map& map, Key key, RefPtr<Value>&& value)
{
    if (!value)
        return false;
    map.add(key, value.releaseNonNull());
    return true;
}

bool RemoteCGRendererResources::recordPath(RemotePathImplIdentifier identifier) const
{
    return addRecorded(m_recordedResources->m_paths, identifier, cachedPathImpl(identifier));
}

bool RemoteCGRendererResources::recordNativeImage(RenderingResourceIdentifier identifier) const
{
    return addRecorded(m_recordedResources->m_nativeImages, identifier, cachedNativeImage(identifier));
}

bool RemoteCGRendererResources::recordImageBuffer(RenderingResourceIdentifier identifier) const
{
    return addRecorded(m_recordedResources->m_imageBuffers, identifier, imageBuffer(identifier));
}

bool RemoteCGRendererResources::recordGradient(RemoteGradientIdentifier identifier) const
{
    return addRecorded(m_recordedResources->m_gradients, identifier, cachedGradient(identifier));
}

bool RemoteCGRendererResources::recordGlyphs(RenderingResourceIdentifier fontIdentifier, const RemoteCGRendererRecordedGlyphs& glyphs) const
{
    RefPtr font = cachedFont(fontIdentifier);
    if (!font)
        return false;
    // A recording draws every run of an identifier in the font it first recorded for it, as the print process does.
    Ref recordedFont = m_recordedResources->addFont(fontIdentifier, font.releaseNonNull());
    auto& run = glyphs.m_run.get();
    RELEASE_ASSERT(!run.font);
    run.facts = recordedFont->factsForGlyphs(run.glyphs.span());
    run.font = WTF::move(recordedFont);
    return true;
}

bool RemoteCGRendererResources::recordMeshGradient(RemoteMeshGradientIdentifier identifier) const
{
    return addRecorded(m_recordedResources->m_meshGradients, identifier, cachedMeshGradient(identifier));
}

bool RemoteCGRendererResources::recordFilter(std::optional<RenderingResourceIdentifier> sourceImageIdentifier, const Ref<Filter>& filter) const
{
    if (sourceImageIdentifier && !recordImageBuffer(*sourceImageIdentifier))
        return false;
    for (auto& effect : filter->effectsOfType(FilterEffect::Type::FEImage)) {
        auto imageIdentifier = downcast<FEImage>(effect.get()).sourceImage().imageIdentifier();
        if (!recordNativeImage(imageIdentifier) && !recordImageBuffer(imageIdentifier))
            return false;
    }
    RefPtr svgFilter = dynamicDowncast<SVGFilterRenderer>(filter.get());
    if (!svgFilter || !svgFilter->hasValidRenderingResourceIdentifier())
        return true;
    RefPtr cachedSVGFilter = dynamicDowncast<SVGFilterRenderer>(cachedFilter(filter->renderingResourceIdentifier()));
    if (!cachedSVGFilter)
        return false;
    cachedSVGFilter->mergeEffects(svgFilter->effects());
    m_recordedResources->m_filters.set(filter->renderingResourceIdentifier(), cachedSVGFilter.releaseNonNull());
    return true;
}

#if USE(SYSTEM_PREVIEW)
bool RemoteCGRendererResources::recordBadgeImage(std::optional<RenderingResourceIdentifier> imageIdentifier) const
{
    return !imageIdentifier || recordNativeImage(*imageIdentifier);
}
#endif

Ref<RemoteCGRendererResources> RemoteCGRendererResources::createForRerecording()
{
    Ref resources = adoptRef(*new RemoteCGRendererResources(nullptr, nullptr, nullptr, nullptr));
    resources->m_isRerecording = true;
    return resources;
}

bool RemoteCGRendererResources::addSnapshotFrameReference(FrameIdentifier frameIdentifier) const
{
    if (!m_snapshot)
        return m_isRerecording;
    m_snapshot->addFrameReference(frameIdentifier);
    return true;
}

Ref<RemoteCGRendererRecordedResources> RemoteCGRendererResources::takeRecordedResources() const
{
    return std::exchange(m_recordedResources, RemoteCGRendererRecordedResources::create());
}

RemoteCGRendererRecordedResources* takeRecordedResources(const RemoteCGRendererResources& resources)
{
    return &resources.takeRecordedResources().leakRef();
}

RemoteCGRendererRecordedResources* copyRecordedResources(const RemoteCGRendererResources& resources)
{
    return &resources.copyRecordedResources().leakRef();
}

void replayIntoContext(GraphicsContextCG& context, NOESCAPE const Function<void(CGRendererCore&, RemoteCGRendererResources&)>& draw)
{
    context.addSwiftRendererLender();
    {
        Ref resources = RemoteCGRendererResources::createForReplay(context);
        auto lend = GraphicsContextCG::lendSwiftRenderer(context);
        draw(lend.state(), resources);
    }
    context.removeSwiftRendererLender();
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

CGImageRef copyImageBufferImage(const RemoteCGRendererResources& resources, ImageBuffer* foundImageBuffer, const FloatRect& sourceRect, RasterDrawingOptions options, bool clonesAcceleratedTarget, CGRendererImageFacts& facts)
{
    facts = { };
    facts.resolutionScale = 1;
    RefPtr imageBuffer = foundImageBuffer;
    if (!imageBuffer)
        return nullptr;
    facts.found = true;
    if (clonesAcceleratedTarget && imageBuffer == resources.targetImageBuffer() && imageBuffer->renderingMode() == RenderingMode::Accelerated) {
        imageBuffer = imageBuffer->clone();
        if (!imageBuffer)
            return nullptr;
        imageBuffer->flushDrawingContext();
        facts.isSelfCopy = true;
        resources.setSelfCopy(RefPtr { imageBuffer });
    }
    facts.resolutionScale = imageBuffer->resolutionScale();
    RefPtr image = resources.targetContext().nativeImageForSwiftReceiver(*imageBuffer);
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

CGRendererBrushSource imageBufferPatternBrush(const RemoteCGRendererResources& resources, ImageBuffer* foundTileImageBuffer, const PatternParameters& parameters, bool& found, bool& drawsIntoTarget)
{
    RefPtr tileImageBuffer = foundTileImageBuffer;
    found = !!tileImageBuffer;
    drawsIntoTarget = tileImageBuffer && tileImageBuffer.get() == resources.targetImageBuffer();
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

#if PLATFORM(COCOA) && ENABLE(VIDEO)
SharedVideoFrameReader& RemoteCGRendererResources::sharedVideoFrameReader() const
{
    if (!m_sharedVideoFrameReader) {
        RELEASE_ASSERT(m_backend);
        Ref gpuConnectionToWebProcess = m_backend->gpuConnectionToWebProcess();
        m_sharedVideoFrameReader = makeUnique<SharedVideoFrameReader>(Ref { gpuConnectionToWebProcess->videoFrameObjectHeap() }, gpuConnectionToWebProcess->webProcessIdentity());
    }
    return *m_sharedVideoFrameReader;
}
#endif

CGImageRef copyMeshGradientImage(const RemoteCGRendererResources& resources, RemoteMeshGradientIdentifier identifier, CGAffineTransform deviceTransform, const CGRendererDestinationColorSpace& destinationColorSpace, CGSize destinationSize, CGRendererImageFacts& facts, CGRendererImageOptions& options)
{
    facts = { };
    facts.resolutionScale = 1;
    options = CGRendererImageOptionsFor({ });
    RefPtr gradient = resources.cachedMeshGradient(identifier);
    if (!gradient)
        return nullptr;
    facts.found = true;
    float scale;
    auto pixelSize = MeshGradientRenderer::pixelSize(AffineTransform { deviceTransform }, FloatSize { destinationSize }, scale);
    if (pixelSize.isEmpty())
        return nullptr;
    auto& contextColorSpace = destinationColorSpace.colorSpace() ? *destinationColorSpace.colorSpace() : ColorSpace::SRGB();
    RefPtr image = MeshGradientRendererCPU { }.renderedImage(*gradient, pixelSize, scale, contextColorSpace, [](const IntSize& size, const ColorSpace& colorSpace, PixelFormat pixelFormat) {
        return ImageBuffer::create(size, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, colorSpace, ImageBufferFormat { pixelFormat });
    });
    if (!image)
        return nullptr;
    return copyImage(*image, facts);
}

static std::optional<SourceImage> sourceImage(const RemoteCGRendererResources& resources, RenderingResourceIdentifier identifier)
{
    if (RefPtr sourceNativeImage = resources.cachedNativeImage(identifier))
        return { { sourceNativeImage.releaseNonNull() } };
    if (RefPtr sourceImageBuffer = resources.imageBuffer(identifier))
        return { { sourceImageBuffer.releaseNonNull() } };
    return std::nullopt;
}

static bool hasFilterSources(const RemoteCGRendererResources& resources, std::optional<RenderingResourceIdentifier> sourceImageIdentifier, const Ref<Filter>& filter)
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
        return is<SVGFilterRenderer>(resources.cachedFilter(filter->renderingResourceIdentifier()));
    return true;
}

static bool useIOSurfaceWebKitBehavior(RemoteRenderingBackend& backend)
{
#if USE(APPLE_INTERNAL_SDK)
    auto preferences = backend.sharedPreferencesForWebProcess();
    return preferences && preferences->useIOSurfaceWebKitBehavior;
#else
    UNUSED_PARAM(backend);
    return false;
#endif
}

static std::unique_ptr<ImageBufferAllocator> filterResultsAllocator(RemoteRenderingBackend& backend)
{
    Ref sharedResourceCache = backend.sharedResourceCache();
#if HAVE(IOSURFACE)
    return makeUnique<ImageBufferShareableAllocator>(sharedResourceCache->resourceOwner(), &sharedResourceCache->ioSurfacePool(), useIOSurfaceWebKitBehavior(backend));
#else
    return makeUnique<ImageBufferShareableAllocator>(sharedResourceCache->resourceOwner());
#endif
}

CGImageRef copyFilteredImage(const RemoteCGRendererResources& resources, std::optional<RenderingResourceIdentifier> sourceImageIdentifier, const FloatRect& sourceImageRect, const Ref<Filter>& filter, RemoteCGRendererFilteredImage& filtered)
{
    filtered = { };
    if (!hasFilterSources(resources, sourceImageIdentifier, filter))
        return nullptr;
    filtered.valid = true;

    RefPtr<ImageBuffer> sourceImageBuffer;
    if (sourceImageIdentifier)
        sourceImageBuffer = resources.imageBuffer(*sourceImageIdentifier);

    // GraphicsContext::drawFilteredImageBuffer()'s result, drawn as GraphicsContext::drawImageBuffer() draws one.
    auto apply = [&](Filter& filterToDraw, FilterResults& results) -> CGImageRef {
        for (auto& effect : filterToDraw.effectsOfType(FilterEffect::Type::FEImage)) {
            Ref feImage = downcast<FEImage>(effect.get());
            feImage->setImageSource(*sourceImage(resources, feImage->sourceImage().imageIdentifier()));
        }
        auto result = filterToDraw.apply(sourceImageBuffer.get(), sourceImageRect, results, FilterResultBuffer::Rendered);
        if (!result)
            return nullptr;
        Ref imageBuffer = result->imageBuffer;
        RefPtr image = resources.targetContext().nativeImageForSwiftReceiver(imageBuffer.get());
        if (!image)
            return nullptr;
        filtered.scaleX = filterToDraw.filterScale().width();
        filtered.scaleY = filterToDraw.filterScale().height();
        filtered.facts.resolutionScale = imageBuffer->resolutionScale();
        filtered.facts.found = true;
        filtered.destination = FloatRect { result->absoluteImageRect };
        FloatRect source { { }, imageBuffer->logicalSize() };
        filtered.source = source;
        filtered.options = CGRendererImageOptionsFor({ });
        source.scale(filtered.facts.resolutionScale);
        CGRendererSetInvertColorMatrix(*image, source, { }, filtered.facts);
        filtered.imageBuffer = WTF::move(imageBuffer);
        return copyImage(*image, filtered.facts);
    };

    RefPtr svgFilter = dynamicDowncast<SVGFilterRenderer>(filter.get());
    bool namesCachedFilter = svgFilter && svgFilter->hasValidRenderingResourceIdentifier();
    // A recording's filter, which DisplayList's DrawFilteredImageBuffer draws with results of its own: the recorder merged
    // the message's effects into the cached filter it named.
    if (resources.isReplaying()) {
        RefPtr<Filter> filterToDraw = filter.ptr();
        if (namesCachedFilter)
            filterToDraw = resources.cachedFilter(filter->renderingResourceIdentifier());
        FilterResults results;
        return apply(*filterToDraw, results);
    }

    RefPtr backend = resources.backend();
    RELEASE_ASSERT(backend);
    if (!namesCachedFilter) {
        FilterResults results(filterResultsAllocator(*backend));
        return apply(filter.get(), results);
    }

    RefPtr cachedSVGFilter = dynamicDowncast<SVGFilterRenderer>(resources.cachedFilter(filter->renderingResourceIdentifier()));
    cachedSVGFilter->mergeEffects(svgFilter->effects());
    auto& results = cachedSVGFilter->ensureResults([&] {
        return makeUnique<FilterResults>(filterResultsAllocator(*backend));
    });
    return apply(*cachedSVGFilter, results);
}

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

void RemoteCGRendererResources::readVideoFrame(const SharedVideoFrame& frame) const
{
    RefPtr videoFrame = sharedVideoFrameReader().read(SharedVideoFrame { frame });
    UNUSED_VARIABLE(videoFrame);
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
