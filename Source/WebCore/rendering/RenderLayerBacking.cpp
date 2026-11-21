/*
 * Copyright (C) 2009-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"

#include "RenderLayerBacking.h"

#include "BackgroundPainter.h"
#include "BitmapImage.h"
#include "BlendingKeyframes.h"
#include "BorderShape.h"
#include "CSSPropertyNames.h"
#include "CachedImage.h"
#include "CanvasRenderingContext2DBase.h"
#include "Chrome.h"
#include "ColorBlending.h"
#include "ContainerNodeInlines.h"
#include "CornerRadii.h"
#include "DebugOverlayRegions.h"
#include "DebugPageOverlays.h"
#include "Document.h"
#include "DocumentPage.h"
#include "EventRegion.h"
#include "FontCascade.h"
#include "FontSelector.h"
#include "GraphicsContext.h"
#include "GraphicsLayer.h"
#include "GraphicsLayerFactory.h"
#include "GraphicsLayerFilterAnimationValue.h"
#include "GraphicsLayerFloatAnimationValue.h"
#include "GraphicsLayerKeyframeValueList.h"
#include "GraphicsLayerTransformAnimationValue.h"
#include "HTMLAnchorElement.h"
#include "HTMLBodyElement.h"
#include "HTMLCanvasElement.h"
#include "HTMLModelElement.h"
#include "HTMLNames.h"
#include "HTMLPlugInElement.h"
#include "HTMLVideoElement.h"
#include "ImageObserver.h"
#include "InspectorInstrumentation.h"
#include "LayerAncestorClippingStack.h"
#include "LocalFrame.h"
#include "LocalFrameView.h"
#include "Logging.h"
#include "Model.h"
#include "NullGraphicsContext.h"
#include "Page.h"
#include "PaintClipPathScope.h"
#include "PaintInfo.h"
#include "PathOperation.h"
#include "PerformanceLoggingClient.h"
#include "PluginViewBase.h"
#include "ProgressTracker.h"
#include "RemoteFrame.h"
#include "RemoteFrameClient.h"
#include "RenderAncestorIterator.h"
#include "RenderBoxInlines.h"
#include "RenderDescendantIterator.h"
#include "RenderElementInlines.h"
#include "RenderEmbeddedObject.h"
#include "RenderFragmentContainer.h"
#include "RenderFragmentedFlow.h"
#include "RenderHTMLCanvas.h"
#include "RenderImage.h"
#include "RenderLayerCompositor.h"
#include "RenderLayerInlines.h"
#include "RenderLayerSVGAdditions.h"
#include "RenderLayerScrollableArea.h"
#include "RenderMedia.h"
#include "RenderModel.h"
#include "RenderSVGHiddenContainer.h"
#include "RenderSVGModelObject.h"
#include "RenderTextControlSingleLine.h"
#include "RenderTheme.h"
#include "RenderVideo.h"
#include "RenderView.h"
#include "RenderViewTransitionCapture.h"
#include "RotateTransformOperation.h"
#include "SVGGraphicsElement.h"
#include "ScaleTransformOperation.h"
#include "ScrollingCoordinator.h"
#include "Settings.h"
#include "StylePrimitiveNumericTypes+Evaluation.h"
#include "StyleResolver.h"
#include "StyleTransformResolver.h"
#include "Styleable.h"
#include "TiledBacking.h"
#include "ViewTransition.h"
#include <wtf/SystemTracing.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/TextStream.h>

#if ENABLE(FULLSCREEN_API)
#include "DocumentFullscreen.h"
#endif

#if PLATFORM(IOS_FAMILY)
#include <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#endif

#if PLATFORM(MAC)
#include "LocalDefaultSystemAppearance.h"
#endif

#if ENABLE(THREADED_ANIMATIONS)
#include "AcceleratedEffect.h"
#include "AcceleratedEffectStack.h"
#include "AcceleratedEffectValues.h"
#include "KeyframeEffect.h"
#include "KeyframeEffectStack.h"
#include <wtf/WeakListHashSet.h>
#endif

#if ENABLE(MODEL_CONTEXT)
#include "ModelContext.h"
#endif

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS) && ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
#include "ARKitBadgeSystemImage.h"
#endif

#if ENABLE(SPATIAL_PORTAL)
#include "SpatialPortalController.h"
#endif

#if ENABLE(AX_CUSTOM_COLOR_MODE)
#include <WebKitAdditions/AXCustomColorModeController.h>
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderLayerBacking);

using namespace HTMLNames;

CanvasCompositingStrategy canvasCompositingStrategy(const RenderObject& renderer)
{
    ASSERT(renderer.isRenderHTMLCanvas());
    CheckedRef canvasRenderer = downcast<RenderHTMLCanvas>(renderer);
    RefPtr context = protect(canvasRenderer->canvasElement())->renderingContext();
    if (canvasRenderer->hasDrawableContent() && !(context && context->delegatesDisplay()))
        return CanvasPaintedToLayer;
    if (!context)
        return CanvasPaintedToEnclosingLayer;
    if (context->delegatesDisplay())
        return CanvasAsLayerContents;
    if (RefPtr context2D = dynamicDowncast<CanvasRenderingContext2DBase>(context)) {
        // If the canvas is accelerated but drawing is not, ensure we get a
        // standalone layer for the canvas. RenderLayerBacking::createPrimaryGraphicsLayer()
        // will enable acceleration for that layer, so that we don't incur readback.
        if (context2D->isAccelerated()) {
            CheckedRef compositor = renderer.view().layer()->compositor();
            if (!compositor->acceleratedDrawingEnabled() || compositor->useDynamicContentScalingDisplayListsForDOMRendering())
                return CanvasPaintedToLayer;
        }
    }

    return CanvasPaintedToEnclosingLayer;
}


RenderLayerBacking::RenderLayerBacking(RenderLayer& layer)
    : m_owningLayer(layer)
{
    if (layer.isRenderViewLayer()) {
        m_isMainFrameRenderViewLayer = renderer().frame().isMainFrame();
        m_isRootFrameRenderViewLayer = protect(renderer().frame())->isRootFrame();
        m_isFrameLayerWithTiledBacking = renderer().page().chrome().client().shouldUseTiledBackingForFrameView(protect(renderer().view().frameView()));
    }

    createPrimaryGraphicsLayer();
#if ENABLE(FULLSCREEN_API)
    auto isFullsizeBackdrop = [](const RenderElement& renderer) -> bool {
        CheckedRef style = renderer.style();
        if (style->pseudoElementType() != PseudoElementType::Backdrop || style->position() != PositionType::Fixed)
            return false;

        if (!style->transform().isNone() || !style->offsetPath().isNone() || !style->clip().isAuto() || Style::hasImageInAnyLayer(style->maskLayers()) || !style->maskBorderSource().isNone())
            return false;

        auto* box = dynamicDowncast<RenderBox>(renderer);
        if (!box)
            return false;

        // Only use background layers on the fullscreen element's backdrop.
        RefPtr documentFullscreen = box->document().fullscreenIfExists();
        if (!documentFullscreen)
            return false;
        RefPtr fullscreenElement = documentFullscreen->fullscreenElement();
        if (!fullscreenElement || !fullscreenElement->renderer() || protect(fullscreenElement->renderer())->pseudoElementRenderer(PseudoElementType::Backdrop) != &renderer)
            return false;

        auto rendererRect = box->borderBoxRectInContainer();
        return rendererRect == protect(box->view())->borderBoxRectInContainer();
    };
    setRequiresBackgroundLayer(isFullsizeBackdrop(layer.renderer()));
#endif

    if (CheckedPtr tiledBacking = this->tiledBacking()) {
        tiledBacking->setIsInWindow(renderer().page().isInWindow());

        if (m_isFrameLayerWithTiledBacking) {
            tiledBacking->setScrollingPerformanceTestingEnabled(renderer().settings().scrollingPerformanceTestingEnabled());
            adjustTiledBackingCoverage();
        }
    }

    m_owningLayer.setAncestorsHaveDescendantNeedingEventRegionUpdate();
}

RenderLayerBacking::~RenderLayerBacking()
{
    // Note that m_owningLayer->backing() is null here.
    clearAncestorClippingStack();
    updateDescendantClippingLayer(false);
    clearOverflowControlsLayers();
    updateForegroundLayer(false);
    clearSVGSegmentLayers();
    updateBackgroundLayer(false);
    updateMaskingLayer(false, false);
    updateScrollingLayers(false);
    
    ASSERT(!m_viewportConstrainedNodeID);
    ASSERT(!m_scrollingNodeID);
    ASSERT(!m_frameHostingNodeID);
    ASSERT(!m_pluginHostingNodeID);
    ASSERT(!m_positioningNodeID);

    destroyGraphicsLayers();
}

void RenderLayerBacking::willBeDestroyed(OptionSet<UpdateBackingSharingFlags> flags)
{
    ASSERT(m_owningLayer.backing() == this);
    protect(compositor())->removeFromScrollCoordinatedLayers(*this);

    clearBackingSharingLayers(flags);
}

static void clearBackingSharingLayerProviders(InlineWeakKeyListHashSet<RenderLayer>& sharingLayers, const RenderLayer& providerLayer, OptionSet<UpdateBackingSharingFlags> flags)
{
    for (auto& layer : sharingLayers | dereferenceView) {
        if (layer.backingProviderLayer() == &providerLayer)
            layer.setBackingProviderLayer(nullptr, flags);
    }
}

void RenderLayerBacking::setBackingSharingLayers(InlineWeakKeyListHashSet<RenderLayer>&& sharingLayers)
{
    bool sharingLayersChanged = m_backingSharingLayers.computeSize() != sharingLayers.computeSize();
    clearBackingSharingLayerProviders(m_backingSharingLayers, m_owningLayer, { UpdateBackingSharingFlags::DuringCompositingUpdate });

    for (auto& oldSharingLayer : m_backingSharingLayers | dereferenceView) {
        if (!sharingLayers.contains(oldSharingLayer))
            sharingLayersChanged = true;
    }

    if (sharingLayersChanged) {
        if (!sharingLayers.computeIsEmpty())
            setRequiresOwnBackingStore(true);
    }

    auto oldSharingLayers = std::exchange(m_backingSharingLayers, WTF::move(sharingLayers));

    for (auto& layer : m_backingSharingLayers | dereferenceView)
        layer.setBackingProviderLayer(&m_owningLayer, { UpdateBackingSharingFlags::DuringCompositingUpdate });
}

void RenderLayerBacking::removeBackingSharingLayer(RenderLayer& layer, OptionSet<UpdateBackingSharingFlags> flags)
{
    layer.setBackingProviderLayer(nullptr, flags);
    m_backingSharingLayers.remove(layer);
}

void RenderLayerBacking::clearBackingSharingLayers(OptionSet<UpdateBackingSharingFlags> flags)
{
    // The owning layer may be getting destroyed, so it cannot be protected.
    SUPPRESS_UNCHECKED_ARG SUPPRESS_UNCOUNTED_ARG clearBackingSharingLayerProviders(m_backingSharingLayers, m_owningLayer, flags);
    m_backingSharingLayers.clear();
}

Ref<GraphicsLayer> RenderLayerBacking::createGraphicsLayer(const String& name, GraphicsLayer::Type layerType)
{
    auto* graphicsLayerFactory = renderer().page().chrome().client().graphicsLayerFactory();

    auto graphicsLayer = GraphicsLayer::create(graphicsLayerFactory, *this, layerType);

    graphicsLayer->setName(name);

#if USE(CA)
    graphicsLayer->setAcceleratesDrawing(compositor().acceleratedDrawingEnabled());
#endif

    if (renderer().isSVGLayerAwareRenderer() && renderer().document().settings().layerBasedSVGEngineEnabled())
        graphicsLayer->setShouldUpdateRootRelativeScaleFactor(true);
    
    return graphicsLayer;
}

RefPtr<GraphicsLayer>& RenderLayerBacking::graphicsLayerField(GraphicsLayerName name)
{
    switch (name) {
    case GraphicsLayerName::Primary: return m_graphicsLayer;
    case GraphicsLayerName::PageTiledBackingContainment: return m_childContainmentLayer;
    case GraphicsLayerName::Mask: return m_maskLayer;
    case GraphicsLayerName::Foreground: return m_foregroundLayer;
    case GraphicsLayerName::Background: return m_backgroundLayer;
    case GraphicsLayerName::ContentsContainment: return m_contentsContainmentLayer;
    case GraphicsLayerName::ViewportAnchor: return m_viewportAnchorLayer;
    case GraphicsLayerName::ViewportClipping: return m_viewportClippingLayer;
    case GraphicsLayerName::ChildClipping: return m_childContainmentLayer;
    case GraphicsLayerName::TransformFlattening: return m_transformFlatteningLayer;
    case GraphicsLayerName::HorizontalScrollbar: return m_layerForHorizontalScrollbar;
    case GraphicsLayerName::VerticalScrollbar: return m_layerForVerticalScrollbar;
    case GraphicsLayerName::ScrollCorner: return m_layerForScrollCorner;
    case GraphicsLayerName::OverflowControlsContainer: return m_overflowControlsContainer;
    case GraphicsLayerName::ScrollContainer: return m_scrollContainerLayer;
    case GraphicsLayerName::ScrolledContents: return m_scrolledContentsLayer;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void RenderLayerBacking::createGraphicsLayer(GraphicsLayerName name, GraphicsLayer::Type type)
{
    auto layerName = [&] -> String {
        switch (name) {
        case GraphicsLayerName::Primary: {
            String layerName = m_owningLayer.name();
            const unsigned maxLayerNameLength = 100;
            if (layerName.length() > maxLayerNameLength)
                layerName = makeString(StringView(layerName).left(maxLayerNameLength), "..."_s);
            return layerName;
        }
        case GraphicsLayerName::PageTiledBackingContainment: return "Page TiledBacking containment"_s;
        case GraphicsLayerName::Mask: return "mask"_s;
        case GraphicsLayerName::Foreground: return makeString(m_owningLayer.name(), " (foreground)"_s);
        case GraphicsLayerName::Background: return makeString(m_owningLayer.name(), " (background)"_s);
        case GraphicsLayerName::ContentsContainment: return makeString(m_owningLayer.name(), " (contents containment)"_s);
        case GraphicsLayerName::ViewportAnchor: return makeString(m_owningLayer.name(), " (anchor)"_s);
        case GraphicsLayerName::ViewportClipping: return makeString(m_owningLayer.name(), " (clipping)"_s);
        case GraphicsLayerName::ChildClipping: return "child clipping"_s;
        case GraphicsLayerName::TransformFlattening: return makeString(m_owningLayer.name(), " (3d flattening)"_s);
        case GraphicsLayerName::HorizontalScrollbar: return "horizontal scrollbar"_s;
        case GraphicsLayerName::VerticalScrollbar: return "vertical scrollbar"_s;
        case GraphicsLayerName::ScrollCorner: return "scroll corner"_s;
        case GraphicsLayerName::OverflowControlsContainer: return "overflow controls container"_s;
        case GraphicsLayerName::ScrollContainer: return "scroll container"_s;
        case GraphicsLayerName::ScrolledContents: return "scrolled contents"_s;
        }
        RELEASE_ASSERT_NOT_REACHED();
    };
    auto& field = graphicsLayerField(name);
    RELEASE_ASSERT(!field);
    field = createGraphicsLayer(layerName(), type);
}

void RenderLayerBacking::unparentAndClearGraphicsLayer(GraphicsLayerName name)
{
    GraphicsLayer::unparentAndClear(graphicsLayerField(name));
}

bool RenderLayerBacking::destroyGraphicsLayer(GraphicsLayerName name)
{
    auto& field = graphicsLayerField(name);
    if (!field)
        return false;
    willDestroyLayer(field.get());
    GraphicsLayer::unparentAndClear(field);
    return true;
}

void RenderLayerBacking::clearGraphicsLayer(GraphicsLayerName name)
{
    GraphicsLayer::clear(graphicsLayerField(name));
}

bool RenderLayerBacking::canvasShouldAccelerate() const
{
    RefPtr element = renderer().element();
    RELEASE_ASSERT(element);
    return downcast<HTMLCanvasElement>(*element).shouldAccelerate();
}

void RenderLayerBacking::clearCanvasContentsFromLayer()
{
    if (RefPtr canvas = dynamicDowncast<HTMLCanvasElement>(renderer().element())) {
        if (RefPtr context = canvas->renderingContext())
            context->clearContentsFromLayer();
    }
}

bool RenderLayerBacking::clipPathIsReferencePath() const
{
    return WTF::holdsAlternative<Style::ReferencePath>(renderer().style().clipPath());
}

void RenderLayerBacking::unparentAndClearSystemPreviewLayers()
{
#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    GraphicsLayer::unparentAndClear(m_systemPreviewBadgeLayer);
    GraphicsLayer::unparentAndClear(m_systemPreviewWrapperLayer);
#endif
}

void RenderLayerBacking::scrollableAreaScrollbarLayerDidChange(ScrollbarOrientation orientation)
{
    if (RefPtr scrollingCoordinator = m_owningLayer.page().scrollingCoordinator()) {
        if (auto* scrollableArea = m_owningLayer.scrollableArea())
            scrollingCoordinator->scrollableAreaScrollbarLayerDidChange(*scrollableArea, orientation);
    }
}

void RenderLayerBacking::setNeedsFixedContainerEdgesUpdateViaChromeClient()
{
    renderer().page().chrome().client().setNeedsFixedContainerEdgesUpdate();
}

bool RenderLayerBacking::updateContentsContainmentLayerForSwift()
{
#if ENABLE(MODEL_PROCESS)
    return updateContentsContainmentLayer();
#else
    return false;
#endif
}

void RenderLayerBacking::setUsesDisplayListDrawing(bool usesDisplayListDrawing)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    // Note that this only affects the primary layer.
    Ref graphicsLayer = *m_graphicsLayer;
    if (usesDisplayListDrawing == graphicsLayer->usesDisplayListDrawing())
        return;

    graphicsLayer->setUsesDisplayListDrawing(usesDisplayListDrawing);
    if (graphicsLayer->drawsContent())
        graphicsLayer->setNeedsDisplay();
}

String RenderLayerBacking::displayListAsText(OptionSet<DisplayList::AsTextFlag> flags) const
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    return protect(m_graphicsLayer)->displayListAsText(flags);
}

void RenderLayerBacking::setIsTrackingDisplayListReplay(bool isTrackingReplay)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    protect(m_graphicsLayer)->setIsTrackingDisplayListReplay(isTrackingReplay);
}

String RenderLayerBacking::replayDisplayListAsText(OptionSet<DisplayList::AsTextFlag> flags) const
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    return protect(m_graphicsLayer)->replayDisplayListAsText(flags);
}

TiledBacking* RenderLayerBacking::tiledBacking() const
{
    return m_graphicsLayer->tiledBacking();
}

bool RenderLayerBacking::shouldSetContentsDisplayDelegate() const
{
    if (!renderer().isRenderHTMLCanvas())
        return false;

    return canvasCompositingStrategy(protect(renderer())) == CanvasAsLayerContents;
}

bool RenderLayerBacking::hasContentsDisplayDelegate() const
{
    return m_graphicsLayer && m_graphicsLayer->hasContentsDisplayDelegate();
}

#if PLATFORM(IOS_FAMILY)
bool RenderLayerBacking::needsIOSDumpRenderTreeMainFrameRenderViewLayerIsAlwaysOpaqueHack(const GraphicsLayer& layer) const
{
    if (m_isMainFrameRenderViewLayer && WTF::CocoaApplication::isDumpRenderTree()) {
        // In iOS WebKit1 the main frame's RenderView layer is always transparent. We lie that it is opaque so that
        // internals.layerTreeAsText() tests succeed.
        ASSERT_UNUSED(layer, !layer.contentsOpaque());
        return true;
    }
    return false;
}
#endif

static LayoutRect scrollContainerLayerBox(const RenderBox& renderBox)
{
    return renderBox.paddingBoxRect();
}

static LayoutRect clippingLayerBox(const RenderLayerModelObject& renderer)
{
    LayoutRect result = LayoutRect::infiniteRect();
    if (renderer.hasNonVisibleOverflow()) {
        if (CheckedPtr box = dynamicDowncast<RenderBox>(renderer))
            result = box->overflowClipRect({ });
        else if (CheckedPtr modelObject = dynamicDowncast<RenderSVGModelObject>(renderer))
            result = modelObject->overflowClipRect({ });
        // overflow: clip on one axis only leaves the other axis infinite.
        result.makeRenderable();
    }

    if (renderer.hasClip()) {
        if (auto* box = dynamicDowncast<RenderBox>(renderer))
            result.intersect(box->clipRect({ }));
    }

    return result;
}

LayoutRect RenderLayerBacking::clippingLayerBoxForSwift() const
{
    return clippingLayerBox(renderer());
}

void RenderLayerBacking::updateTransform(const Style::ComputedStyle& style)
{
    TransformationMatrix t;
    CheckedRef renderer = this->renderer();
    if (renderer->effectiveCapturedInViewTransition()) {
        if (RefPtr activeViewTransition = renderer->document().activeViewTransition()) {
            if (CheckedPtr viewTransitionCapture = activeViewTransition->viewTransitionNewPseudoForCapturedElement(renderer)) {
                t.scaleNonUniform(viewTransitionCapture->scale().width(), viewTransitionCapture->scale().height());
                t.translateRight(viewTransitionCapture->captureContentInset().x(), viewTransitionCapture->captureContentInset().y());
            }
            if (m_owningLayer.isRenderViewLayer()) {
                auto scrollPosition = protect(renderer->view().frameView())->scrollPosition();
                t.translate(-scrollPosition.x(), -scrollPosition.y());
            }
        }
    } else if (m_owningLayer.isTransformed())
        m_owningLayer.updateTransformFromStyle(t, style, Style::TransformResolver::individualTransformOperations);
    
    Ref graphicsLayer = *m_graphicsLayer;
    if (RefPtr contentsContainmentLayer = m_contentsContainmentLayer) {
        contentsContainmentLayer->setTransform(t);
        graphicsLayer->setTransform({ });
    } else
        graphicsLayer->setTransform(t);
}

static IntOutsets clampedFilterSamplingOutsets(const IntOutsets& outsets)
{
    // Cap like LayoutRect::infiniteRect(), to leave room for expanding clip rects.
    static constexpr int maximumFilterSamplingOutset = (LayoutUnit::nearlyMax() / 2).toInt();

    auto clampSide = [](int side) {
        return std::clamp(side, 0, maximumFilterSamplingOutset);
    };
    return { clampSide(outsets.top()), clampSide(outsets.right()), clampSide(outsets.bottom()), clampSide(outsets.left()) };
}

IntOutsets RenderLayerBacking::filterSamplingOutsets(const RenderLayer& layer)
{
    auto& renderer = layer.renderer();
    auto& filter = renderer.style().filter();
    if (filter.hasReferenceFilter())
        return { };

    if (auto* backing = layer.backing(); backing && !filter.isNone() && !backing->canCompositeFilters())
        return { };

    IntOutsets outsets;
    if (auto* backing = layer.backing())
        outsets = backing->filterAnimationOutsets();
    if (filter.hasFilterThatMovesPixels())
        outsets = max(outsets, renderer.computeFilterOutsets());
    return clampedFilterSamplingOutsets(outsets).xyFlippedCopy();
}

IntOutsets RenderLayerBacking::accumulatedFilterSamplingOutsets(const IntOutsets& accumulatedOutsets, const IntOutsets& outsets)
{
    return clampedFilterSamplingOutsets(accumulatedOutsets + outsets);
}

bool RenderLayerBacking::ancestorLayerMayClipForSwift(const RenderLayer& layer, const RenderLayer& ancestorLayer, bool isContainingBlockChain)
{
    return ancestorLayerMayClip(layer, ancestorLayer, isContainingBlockChain);
}

void RenderLayerBacking::updateFilters(const Style::ComputedStyle& style)
{
    bool hasReferenceFilter = style.filter().hasReferenceFilter();
    Ref graphicsLayer = *m_graphicsLayer;
    m_canCompositeFilters = graphicsLayer->setFilters(hasReferenceFilter ? FilterOperations { } : Style::toPlatform(style.filter(), style)) && !hasReferenceFilter;
    graphicsLayer->setFilterSamplingOutsets(filterSamplingOutsets(m_owningLayer));
}

void RenderLayerBacking::updateFilterAnimationOutsets()
{
    IntOutsets outsets;
    for (auto& animationOutsets : m_filterAnimationOutsetsByName.values())
        outsets = max(outsets, animationOutsets);
#if ENABLE(THREADED_ANIMATIONS)
    outsets = max(outsets, m_filterAnimationOutsetsFromAcceleratedEffects);
#endif
    if (outsets == m_filterAnimationOutsets)
        return;

    m_filterAnimationOutsets = outsets;
    protect(m_graphicsLayer)->setFilterSamplingOutsets(filterSamplingOutsets(m_owningLayer));
    m_owningLayer.setDescendantsNeedUpdateBackingAndHierarchyTraversal();
    m_owningLayer.setSubsequentLayersNeedCompositingRequirementsTraversal();
    protect(compositor())->scheduleCompositingLayerUpdate();
}

void RenderLayerBacking::updateFilterAnimationOutsetsForSwift(NOESCAPE BlendingKeyframesView keyframes, bool hasFilterAnimationOutsets, IntOutsets filterAnimationOutsets)
{
    if (hasFilterAnimationOutsets) {
        m_filterAnimationOutsetsByName.set((*keyframes).acceleratedAnimationName(), filterAnimationOutsets);
        updateFilterAnimationOutsets();
    } else if (m_filterAnimationOutsetsByName.remove((*keyframes).acceleratedAnimationName()))
        updateFilterAnimationOutsets();
}

void RenderLayerBacking::removeFilterAnimationOutsetsForSwift(const String& animationName)
{
    if (m_filterAnimationOutsetsByName.remove(animationName))
        updateFilterAnimationOutsets();
}

void RenderLayerBacking::updateBackdropFilters(const Style::ComputedStyle& style)
{
    m_canCompositeBackdropFilters = !style.backdropFilter().hasReferenceFilter() && protect(m_graphicsLayer)->setBackdropFilters(Style::toPlatform(style.backdropFilter(), style));
}

#if HAVE(CORE_MATERIAL)
void RenderLayerBacking::updateAppleVisualEffect(const Style::ComputedStyle& style)
{
    AppleVisualEffectData visualEffectData;

    visualEffectData.effect = style.appleVisualEffect();
    visualEffectData.contextEffect = style.usedAppleVisualEffectForSubtree();
    visualEffectData.colorScheme = protect(renderer().document())->useDarkAppearance(&style) ? AppleVisualEffectData::ColorScheme::Dark : AppleVisualEffectData::ColorScheme::Light;

#if HAVE(MATERIAL_HOSTING)
    if (appleVisualEffectIsHostedMaterial(style.appleVisualEffect())) {
        if (CheckedPtr renderBox = dynamicDowncast<RenderBox>(renderer())) {
            if (renderBox->style().border().hasBorderRadius()) {
                auto borderShape = BorderShape::shapeForBorderRect(renderBox->usedStyle(), renderBox->borderBoxRect());
                auto roundedBoxRect = borderShape.deprecatedRoundedRect();
                roundedBoxRect.move(contentOffsetInCompositingLayer());
                visualEffectData.borderRect = roundedBoxRect.pixelSnappedRoundedRectForPainting(pixelSnappingScaleFactor());
            }
        }
    }
#endif

    protect(m_graphicsLayer)->setAppleVisualEffectData(visualEffectData);
}
#endif

bool RenderLayerBacking::shouldForceInvertBitmapImageForSwift(RenderImage& imageRenderer)
{
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    RefPtr styleImage = imageRenderer.imageResource().styleImage();
    return styleImage && AXCustomColorModeController::shouldForceInvertBitmapImage(imageRenderer, *styleImage);
#else
    UNUSED_PARAM(imageRenderer);
    return false;
#endif
}

void RenderLayerBacking::updateScreenCaptureProtection()
{
    CheckedPtr innerBlock = dynamicDowncast<RenderTextControlInnerBlock>(renderer());
    m_graphicsLayer->setHidesFromScreenCapture(innerBlock && innerBlock->shouldHideFromScreenCapture());
}

NODELETE static bool hasNonZeroTransformOrigin(const RenderLayerModelObject& renderer)
{
    auto& style = renderer.style();
    auto fixedTransformOriginX = style.transformOriginX().tryFixed();
    auto fixedTransformOriginY = style.transformOriginY().tryFixed();
    return (fixedTransformOriginX && !fixedTransformOriginX->isZero())
        || (fixedTransformOriginY && !fixedTransformOriginY->isZero());
}

bool RenderLayerBacking::rendererHasNonZeroTransformOrigin() const
{
    return hasNonZeroTransformOrigin(renderer());
}

void RenderLayerBacking::updateAfterWidgetResize()
{
    CheckedPtr renderWidget = dynamicDowncast<RenderWidget>(renderer());
    if (!renderWidget)
        return;

    if (CheckedPtr innerCompositor = RenderLayerCompositor::frameContentsCompositor(*renderWidget)) {
        innerCompositor->frameViewDidChangeSize();
        auto snappedContentOrigin = roundPointToDevicePixels(contentsBox().location(), pixelSnappingScaleFactor());
        innerCompositor->frameViewDidChangeLocation(snappedContentOrigin);
    }

    if (RefPtr contentsLayer = layerForContents())
        contentsLayer->setPosition(flooredIntPoint(contentsBox().location()));
}

// This can only update things that don't require up-to-date layout.
void RenderLayerBacking::updateConfigurationAfterStyleChange()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    updateConfigurationAfterStyleChangeInScope();
}

bool RenderLayerBacking::updateConfiguration(const RenderLayer* compositingAncestor)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    return updateConfigurationInScope(compositingAncestor);
}

void RenderLayerBacking::updateAfterDescendants()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    updateAfterDescendantsInScope();
}

#if ENABLE(SPATIAL_PORTAL)
void RenderLayerBacking::configureSpatialPortalLayer(SpatialPortalController& controller)
{
    updateContentsRects();
    CheckedRef renderer = this->renderer();
    auto portalBackgroundColor = blendSourceOver(renderer->theme().systemColor(CSSValueID::Canvas, renderer->styleColorOptions(StyleColorOptionsPurpose::Rendering)), rendererBackgroundColor());
    controller.configureGraphicsLayer(protect(*m_graphicsLayer), portalBackgroundColor);
    controller.sizeMayHaveChanged();
}

static bool collectPortalHostedLayers(RenderLayer& promotedChild, NodeIdentifier rootNodeID, RenderLayer& layer, const FloatPoint& childOriginInPortal, const FloatSize& childSize, Vector<PortalPromotedChild>& children)
{
    if (auto* backing = layer.backing()) {
        if (backing->foregroundLayer() || backing->backgroundLayer() || backing->hasClippingLayer() || backing->hasAncestorClippingLayers() || backing->scrollContainerLayer() || backing->hasMaskLayer() || backing->viewportClippingOrAnchorLayer() || backing->overflowControlsContainer())
            return false;

        RefPtr graphicsLayer = backing->graphicsLayer();
        if (compositedWithOwnBackingStore(layer) && graphicsLayer->drawsContent()) {
            RefPtr element = layer.renderer().element();
            if (!element || backing->tiledBacking() || !SpatialPortalController::canHostPromotedChild(layer.renderer()))
                return false;

            auto transform = SpatialPortalController::transformForHostedLayer(layer, promotedChild);
            if (!transform)
                return false;

            FloatRect quadRect { { }, graphicsLayer->size() };
            if (&layer == &promotedChild)
                quadRect.move(graphicsLayer->offsetFromRenderer() + backing->subpixelOffsetFromRenderer());

            children.append({
                .nodeID = element->nodeIdentifier(),
                .rootNodeID = rootNodeID,
                .layer = *graphicsLayer,
                .quadRectInChildSpace = quadRect,
                .childOriginInPortal = childOriginInPortal,
                .childSize = childSize,
                .transform = *transform,
            });
        }
    }

    if (!layer.hasCompositingDescendant())
        return true;

    if (layer.renderer().hasNonVisibleOverflow() || !SpatialPortalController::canHostPromotedChild(layer.renderer()))
        return false;

    layer.updateLayerListsIfNeeded();
    if (layer.isStackingContext()) {
        for (auto* child : layer.negativeZOrderLayers()) {
            if (child->isComposited() || child->hasCompositingDescendant())
                return false;
        }
    }

    for (auto* child : layer.normalFlowLayers()) {
        if (!collectPortalHostedLayers(promotedChild, rootNodeID, *child, childOriginInPortal, childSize, children))
            return false;
    }

    if (layer.isStackingContext()) {
        for (auto* child : layer.positiveZOrderLayers()) {
            if (!collectPortalHostedLayers(promotedChild, rootNodeID, *child, childOriginInPortal, childSize, children))
                return false;
        }
    }

    return true;
}

void RenderLayerBacking::updatePortalPromotedChildren(SpatialPortalController& controller)
{
    CheckedPtr portalBox = dynamicDowncast<RenderBox>(renderer());
    if (!portalBox)
        return;

    FloatSize portalBorderOffset { portalBox->borderLeft().toFloat(), portalBox->borderTop().toFloat() };
    Vector<PortalPromotedChild> children;
    for (auto* childLayer = m_owningLayer.firstChild(); childLayer; childLayer = childLayer->nextSibling()) {
        if (!RenderLayerCompositor::isPromotedSpatialPortalChild(*childLayer))
            continue;

        RefPtr childElement = childLayer->renderer().element();
        if (!childElement || !compositedWithOwnBackingStore(*childLayer) || childLayer->paintsIntoProvidedBacking())
            continue;

        FloatSize offsetFromPortal { childLayer->offsetFromAncestor(&m_owningLayer) };
        Vector<PortalPromotedChild> hostedLayers;
        FloatSize childSize { childLayer->rendererBorderBoxRect().size() };
        if (collectPortalHostedLayers(*childLayer, childElement->nodeIdentifier(), *childLayer, toFloatPoint(offsetFromPortal - portalBorderOffset), childSize, hostedLayers))
            children.appendVector(WTF::move(hostedLayers));
    }

    bool hadPortalContent = controller.hasPortalContent();
    controller.updatePromotedChildren(WTF::move(children));
    if (hadPortalContent != controller.hasPortalContent())
        configureSpatialPortalLayer(controller);

    updateHostedPromotedChildren();
}

void RenderLayerBacking::updateHostedPromotedChildren()
{
    for (auto* childLayer = m_owningLayer.firstChild(); childLayer; childLayer = childLayer->nextSibling()) {
        if (auto* backing = childLayer->backing())
            backing->updateIsHostedInSpatialPortalScene();
    }
}

void RenderLayerBacking::updateIsHostedInSpatialPortalScene()
{
    m_graphicsLayer->setIsHostedInSpatialPortalScene(!!hostingSpatialPortalController());
}

SpatialPortalController* RenderLayerBacking::promotedChildPortalController() const
{
    auto* promotedChild = RenderLayerCompositor::promotedSpatialPortalChildForLayer(m_owningLayer);
    if (!promotedChild)
        return nullptr;

    RefPtr portalElement = promotedChild->parent()->renderer().element();
    return portalElement ? portalElement->spatialPortalController() : nullptr;
}

SpatialPortalController* RenderLayerBacking::hostingSpatialPortalController() const
{
    if (!RenderLayerCompositor::isPromotedSpatialPortalChild(m_owningLayer))
        return nullptr;

    auto* controller = promotedChildPortalController();
    RefPtr element = renderer().element();
    if (!element || !controller || !controller->hostsPromotedChild(element->nodeIdentifier()))
        return nullptr;

    return controller;
}
#endif

void RenderLayerBacking::updatePortalPromotedChildrenForSwift()
{
#if ENABLE(SPATIAL_PORTAL)
    if (RefPtr element = renderer().element()) {
        if (CheckedPtr controller = element->spatialPortalController())
            updatePortalPromotedChildren(*controller);
    }
#endif
}

void RenderLayerBacking::updateIsHostedInSpatialPortalSceneForSwift()
{
#if ENABLE(SPATIAL_PORTAL)
    updateIsHostedInSpatialPortalScene();
#endif
}

bool RenderLayerBacking::isInPromotedSpatialPortalChildForSwift() const
{
#if ENABLE(SPATIAL_PORTAL)
    return !!RenderLayerCompositor::promotedSpatialPortalChildForLayer(m_owningLayer);
#else
    return false;
#endif
}

bool RenderLayerBacking::updateSystemPreviewBadgeLayerForSwift()
{
#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    if (updateSystemPreviewBadgeLayer(needsSystemPreviewBadgeLayer())) {
        // Badge layer needs the contents containment layer to live as its parent so it sits next to m_graphicsLayer.
        updateContentsContainmentLayer();
        return true;
    }
#endif
    return false;
}

bool RenderLayerBacking::scrollContainerClipHasNonZeroRadii() const
{
    // If it's scrollable, it has to be a box.
    auto& renderBox = downcast<RenderBox>(renderer());
    auto borderShape = BorderShape::shapeForBorderRect(renderBox.usedStyle(), renderBox.borderBoxRect());
    FloatRoundedRect contentsClippingRect = borderShape.deprecatedPixelSnappedInnerRoundedRect(pixelSnappingScaleFactor());
    return contentsClippingRect.hasNonZeroRadii();
}

// Gives the primary layer the contents of a plugin, video, remote frame, canvas or model renderer. Returns true if the
// layer configuration changed.
bool RenderLayerBacking::updateContentsLayerForReplacedRenderer()
{
    bool layerConfigChanged = false;
    CheckedRef renderer = this->renderer();
    Ref graphicsLayer = *m_graphicsLayer;

    auto attachPluginLayer = [&](RenderEmbeddedObject& rendererEmbeddedObject) {
        RefPtr pluginViewBase = dynamicDowncast<PluginViewBase>(rendererEmbeddedObject.widget());
        if (!pluginViewBase)
            return;

        switch (pluginViewBase->layerHostingStrategy()) {
        case PluginLayerHostingStrategy::None:
            break;
        case PluginLayerHostingStrategy::PlatformLayer:
            SUPPRESS_FORWARD_DECL_ARG graphicsLayer->setContentsToPlatformLayer(pluginViewBase->platformLayer(), GraphicsLayer::ContentsLayerPurpose::Plugin);
            break;
        case PluginLayerHostingStrategy::GraphicsLayer:
            // layer is parented in RenderLayerCompositor::updateBackingAndHierarchy().
            break;
        }
    };

    if (RenderLayerCompositor::isCompositedPlugin(renderer))
        attachPluginLayer(downcast<RenderEmbeddedObject>(renderer));

#if ENABLE(VIDEO)
    else if (CheckedPtr renderVideo = dynamicDowncast<RenderVideo>(renderer); renderVideo && renderVideo->shouldDisplayVideo()) {
        Ref videoElement = downcast<HTMLVideoElement>(*renderer->element());
        if (graphicsLayer->layerMode() == GraphicsLayer::LayerMode::LayerHostingContextId
#if ENABLE(GPU_PROCESS)
            && videoElement->document().settings().blockMediaLayerRehostingInWebContentProcess()
            && videoElement->document().page()
            && videoElement->document().page()->chrome().client().isUsingUISideCompositing()
#endif
            )
            graphicsLayer->setContentsToVideoElement(videoElement, GraphicsLayer::ContentsLayerPurpose::Media);
        else
            graphicsLayer->setContentsToMediaPlayer(protect(videoElement->player()), GraphicsLayer::ContentsLayerPurpose::Media);
        updateContentsRects();
    }
#endif
    else if (RefPtr remoteFrame = is<RenderWidget>(renderer) ? downcast<RenderWidget>(renderer).remoteFrame() : nullptr; remoteFrame && remoteFrame->layerHostingContextIdentifier())
        graphicsLayer->setContentsToPlatformLayerHost(*remoteFrame->layerHostingContextIdentifier());
    else if (shouldSetContentsDisplayDelegate()) {
        RefPtr canvas = downcast<HTMLCanvasElement>(renderer->element());
        if (RefPtr context = canvas->renderingContext())
            context->setContentsToLayer(graphicsLayer);

        layerConfigChanged = true;
    }
#if ENABLE(MODEL_ELEMENT)
    else if (is<RenderModel>(renderer)) {
        RefPtr element = downcast<HTMLModelElement>(renderer->element());

        auto modelBackgroundColor = blendSourceOver(renderer->theme().systemColor(CSSValueID::Canvas, renderer->styleColorOptions(StyleColorOptionsPurpose::Rendering)), rendererBackgroundColor());
        element->configureGraphicsLayer(graphicsLayer, modelBackgroundColor);
        element->sizeMayHaveChanged();

        layerConfigChanged = true;
    }
#endif // ENABLE(MODEL_ELEMENT)

#if ENABLE(SPATIAL_PORTAL)
    if (RefPtr element = renderer->element()) {
        if (CheckedPtr controller = element->spatialPortalController()) {
            configureSpatialPortalLayer(*controller);
            layerConfigChanged = true;
        }
    }
#endif // ENABLE(SPATIAL_PORTAL)

    return layerConfigChanged;
}

static FloatRoundedRect contentsClippingRectForCornerShape(const FloatRoundedRect& clippingRect, const Style::ComputedStyle& style)
{
    if (style.border().hasNonRoundCornerShape())
        return FloatRoundedRect { clippingRect.rect() };
    return clippingRect;
}

RenderLayer::OptionalLayoutRect RenderLayerBacking::viewTransitionCaptureOverflowRect() const
{
    if (!renderer().effectiveCapturedInViewTransition() || !renderer().element())
        return std::nullopt;
    RefPtr activeViewTransition = renderer().document().activeViewTransition();
    if (!activeViewTransition)
        return std::nullopt;
    CheckedPtr viewTransitionCapture = activeViewTransition->viewTransitionNewPseudoForCapturedElement(renderer());
    if (!viewTransitionCapture)
        return std::nullopt;
    return viewTransitionCapture->captureOverflowRect();
}

FloatRoundedRect RenderLayerBacking::innerBorderShapeContentsClippingRect(FloatSize offsetFromRenderer) const
{
    auto borderShape = BorderShape::shapeForBorderRect(renderer().usedStyle(), m_owningLayer.rendererBorderBoxRect());
    auto contentsClippingRect = contentsClippingRectForCornerShape(borderShape.deprecatedPixelSnappedInnerRoundedRect(pixelSnappingScaleFactor()), renderer().style());
    contentsClippingRect.move(LayoutSize(-offsetFromRenderer));
    return contentsClippingRect;
}

bool RenderLayerBacking::rendererIsRunningOrAboutToRunAcceleratedTransformRelatedAnimation() const
{
    auto styleable = Styleable::fromRenderer(renderer());
    return styleable && styleable->isRunningOrAboutToRunAcceleratedTransformRelatedAnimation();
}

void RenderLayerBacking::rendererSizeMayHaveChanged()
{
#if ENABLE(MODEL_ELEMENT)
    if (is<RenderModel>(renderer()))
        downcast<HTMLModelElement>(renderer().element())->sizeMayHaveChanged();
#endif

#if ENABLE(SPATIAL_PORTAL)
    if (RefPtr element = renderer().element()) {
        if (CheckedPtr controller = element->spatialPortalController())
            controller->sizeMayHaveChanged();
    }
#endif
}

void RenderLayerBacking::updateSystemPreviewBadgeLayerGeometryForSwift()
{
#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    updateSystemPreviewBadgeLayerGeometry();
#endif
}

unsigned RenderLayerBacking::frameTreeDepthForSwift() const
{
    return renderer().frame().tree().depth();
}

void RenderLayerBacking::setNeedsTextBackdropUpdateForCustomColorMode()
{
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    // Without a controller no pass has run yet, and the first one will cover this repaint anyway.
    if (CheckedPtr controller = renderer().document().axCustomColorModeControllerIfExists())
        controller->setNeedsTextBackdropUpdate();
#endif
}

static void setContentsClipShapePath(GraphicsLayer& graphicsLayer, const Style::ComputedStyle& style, const BorderShape& borderShape, float pixelSnappingScaleFactor, const FloatSize& offset)
{
    if (!style.border().hasCornerShapeOutsideRoundedRect()) {
        if (!graphicsLayer.contentsClipShapePath().isEmpty())
            graphicsLayer.setContentsClipShapePath({ });
        return;
    }

    auto shapePath = borderShape.pathForInnerShape(pixelSnappingScaleFactor);
    shapePath.translate(offset);
    graphicsLayer.setContentsClipShapePath(shapePath);
}

FloatRoundedRect RenderLayerBacking::replacedContentsClippingRect(const RenderReplaced& renderReplaced, bool clipToVideoBox)
{
    auto borderShape = renderReplaced.borderShapeForContentClipping(renderReplaced.borderBoxRect());
    setContentsClipShapePath(*m_graphicsLayer, renderReplaced.style(), borderShape, pixelSnappingScaleFactor(), contentOffsetInCompositingLayer());
    auto contentsClippingRect = contentsClippingRectForCornerShape(borderShape.deprecatedPixelSnappedInnerRoundedRect(pixelSnappingScaleFactor()), renderReplaced.style());
#if ENABLE(VIDEO)
    // Intersect with the (small) destination rect so the oversized contents layer is clipped to what's actually visible.
    if (clipToVideoBox)
        contentsClippingRect = FloatRoundedRect(intersection(contentsClippingRect.rect(), FloatRect(downcast<RenderVideo>(renderReplaced).videoBox())), contentsClippingRect.radii());
#else
    UNUSED_PARAM(clipToVideoBox);
#endif
    return contentsClippingRect;
}

bool RenderLayerBacking::updateContentsClippingForSeparatedLayer(bool includeSpatialPortal)
{
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS) || ENABLE(SPATIAL_PORTAL)
    bool needsContentsClippingRectUpdate = false;
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    if (RenderLayerCompositor::isSeparated(renderer()))
        needsContentsClippingRectUpdate = true;
#endif
#if ENABLE(SPATIAL_PORTAL)
    if (includeSpatialPortal && RenderLayerCompositor::isSpatialPortal(renderer()))
        needsContentsClippingRectUpdate = true;
#endif

    if (needsContentsClippingRectUpdate) {
        if (CheckedPtr renderBox = dynamicDowncast<RenderBox>(renderer())) {
            auto borderShape = BorderShape::shapeForBorderRect(renderBox->usedStyle(), renderBox->borderBoxRect());
            auto contentsClippingRect = contentsClippingRectForCornerShape(borderShape.deprecatedPixelSnappedInnerRoundedRect(pixelSnappingScaleFactor()), renderBox->style());
            contentsClippingRect.move(contentOffsetInCompositingLayer());
            m_graphicsLayer->setContentsClippingRect(contentsClippingRect);
            setContentsClipShapePath(*m_graphicsLayer, renderBox->style(), borderShape, pixelSnappingScaleFactor(), contentOffsetInCompositingLayer());
            return true;
        }
    }
#else
    UNUSED_PARAM(includeSpatialPortal);
#endif
    return false;
}

FloatRoundedRect RenderLayerBacking::backdropFiltersRoundedRect(const RenderBox& renderBox)
{
    auto borderShape = BorderShape::shapeForBorderRect(renderBox.usedStyle(), renderBox.borderBoxRect());
    auto roundedBoxRect = borderShape.deprecatedRoundedRect();
    roundedBoxRect.move(contentOffsetInCompositingLayer());
    auto backdropFiltersRect = roundedBoxRect.pixelSnappedRoundedRectForPainting(pixelSnappingScaleFactor());

    if (renderBox.style().border().hasNonRoundCornerShape()) {
        auto shapePath = borderShape.pathForOuterShape(pixelSnappingScaleFactor());
        shapePath.translate(FloatSize { contentOffsetInCompositingLayer() });
        m_graphicsLayer->setBackdropFiltersShapePath(shapePath);
    } else
        m_graphicsLayer->setBackdropFiltersShapePath({ });
    return backdropFiltersRect;
}

void RenderLayerBacking::setClippingLayerContentsClipShapePath(GraphicsLayer& clipLayer) const
{
    if (CheckedPtr box = dynamicDowncast<RenderBox>(renderer())) {
        auto borderShape = BorderShape::shapeForBorderRect(box->usedStyle(), m_owningLayer.rendererBorderBoxRect());
        setContentsClipShapePath(clipLayer, renderer().style(), borderShape, pixelSnappingScaleFactor(), -clipLayer.offsetFromRenderer());
    }
}

Path RenderLayerBacking::clipPathForMaskLayer(LayoutRect referenceBoxForClippedInline, LayoutSize offset, WindRule& windRule) const
{
    auto [clipPath, clipWindRule] = Paint::ClipPathScope::computeClipPath(renderer(), offset, referenceBoxForClippedInline);
    windRule = clipWindRule;
    return clipPath;
}

GraphicsLayer* RenderLayerBacking::layerForContents() const
{
    if (!RenderLayerCompositor::isCompositedPlugin(renderer()))
        return nullptr;

    RefPtr pluginViewBase = dynamicDowncast<PluginViewBase>(downcast<RenderEmbeddedObject>(renderer()).widget());
    if (!pluginViewBase)
        return nullptr;

    if (pluginViewBase->layerHostingStrategy() != PluginLayerHostingStrategy::GraphicsLayer)
        return nullptr;

    return pluginViewBase->graphicsLayer();
}

void RenderLayerBacking::updateDrawsContent()
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    updateDrawsContentInScope();
}

#if HAVE(SUPPORT_HDR_DISPLAY)
void RenderLayerBacking::updateDrawsHDRContent(bool drawsHDRContent)
{
    Ref graphicsLayer = *m_graphicsLayer;
    graphicsLayer->setDrawsHDRContent(drawsHDRContent);
    if (drawsHDRContent) {
        LOG_WITH_STREAM(HDR, stream << "RenderLayerBacking " << *this << " updateDrawContent headroom " << m_owningLayer.page().displayEDRHeadroom());
        graphicsLayer->setNeedsDisplayIfEDRHeadroomExceeds(m_owningLayer.page().displayEDRHeadroom());
        graphicsLayer->setTonemappingEnabled(m_owningLayer.page().hdrLayersRequireTonemapping());
    } else
        graphicsLayer->setTonemappingEnabled(false);
}
#endif

#if ENABLE(ASYNC_SCROLLING)
bool RenderLayerBacking::documentOrPageRequiresEventRegion() const
{
#if ENABLE(TOUCH_ACTION_REGIONS)
    if (renderer().document().mayHaveElementsWithNonAutoTouchAction())
        return true;
#endif
#if ENABLE(EDITABLE_REGION)
    LOG_WITH_STREAM(EventRegions, stream << "RenderLayerBacking: " << this << " maintainsEventRegion - mayHaveEditableElements: " << renderer().document().mayHaveEditableElements() << " shouldBuildEditableRegion: " << renderer().page().shouldBuildEditableRegion());
    if (renderer().document().mayHaveEditableElements() && renderer().page().shouldBuildEditableRegion())
        return true;
#endif
#if ENABLE(WHEEL_EVENT_REGIONS)
    if (renderer().document().hasWheelEventHandlers() || renderer().document().mayHaveListBoxes())
        return true;
#endif
#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
    if (renderer().page().shouldBuildInteractionRegions())
        return true;
#endif
#if ENABLE(TOUCH_EVENT_REGIONS)
    if (renderer().document().shouldUseTouchEventRegions()) {
        if (renderer().document().hasTouchEventHandlers())
            return true;
        if (renderer().document().needsPointerEventHandlingForPopoverOrDialog())
            return true;
    }
#endif
    return false;
}

void RenderLayerBacking::updateEventRegion()
{
    LOG_WITH_STREAM(EventRegions, stream << m_owningLayer << " " << this << " updateEventRegion (needs update: " << needsEventRegionUpdate() << ", maintainsEventRegion: " << maintainsEventRegion() << ")");

    if (!maintainsEventRegion())
        return;

    if (!needsEventRegionUpdate())
        return;

    TraceScope scope(ComputeEventRegionsStart, ComputeEventRegionsEnd);

    auto visibleToHitTesting = renderer().visibleToHitTesting();

    auto setEventRegionToLayerBounds = [&](GraphicsLayer* graphicsLayer) {
        if (!graphicsLayer)
            return;

        EventRegion eventRegion;
        auto eventRegionContext = eventRegion.makeContext();
        if (visibleToHitTesting)
            eventRegionContext->unite(FloatRoundedRect(FloatRect({ }, graphicsLayer->size())), renderer(), renderer().style());

#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
        eventRegionContext->copyInteractionRegionsToEventRegion(renderer().document().settings().interactionRegionMinimumCornerRadius());
#endif
        graphicsLayer->setEventRegion(WTF::move(eventRegion));
    };

    auto updateEventRegionForLayer = [&](GraphicsLayer& graphicsLayer) {
        NullGraphicsContext nullContext;
        EventRegion eventRegion;
#if ENABLE(EDITABLE_REGION)
        if (renderer().page().shouldBuildEditableRegion())
            eventRegion.ensureEditableRegion();
#endif
        auto eventRegionContext = eventRegion.makeContext();
#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
        eventRegionContext->reserveCapacityForInteractionRegions(graphicsLayer.eventRegion().interactionRegions().size());
#endif
        auto layerOffset = graphicsLayer.scrollOffset() - graphicsLayer.offsetFromRenderer();
        auto layerBounds = FloatRoundedRect(FloatRect(-layerOffset, graphicsLayer.size()));

        if (visibleToHitTesting) {
            if (&graphicsLayer == m_scrolledContentsLayer) {
                // Initialize scrolled contents layer with layer-sized event region as it can all used for scrolling.
                // This avoids generating unnecessarily complex event regions. We still need to to do the paint to capture touch-action regions.
                eventRegionContext->unite(layerBounds, renderer(), renderer().style());
            }
        }

        if (m_owningLayer.isRenderViewLayer() && (&graphicsLayer == m_graphicsLayer || &graphicsLayer == m_foregroundLayer)) {
            // Event handlers on the root cover the entire layer.
            eventRegionContext->unite(layerBounds, renderer(), renderer().style());
        }

        auto dirtyRect = enclosingIntRect(FloatRect(FloatPoint(graphicsLayer.offsetFromRenderer()), graphicsLayer.size()));
        paintIntoLayer(&graphicsLayer, nullContext, dirtyRect, { }, eventRegionContext.ptr());

#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
        eventRegionContext->copyInteractionRegionsToEventRegion(renderer().document().settings().interactionRegionMinimumCornerRadius());
#endif
        eventRegion.translate(toIntSize(roundedIntPoint(layerOffset)));
        graphicsLayer.setEventRegion(WTF::move(eventRegion));
    };

    updateEventRegionForLayer(*m_graphicsLayer);

    setEventRegionToLayerBounds(m_scrollContainerLayer.get());
    setEventRegionToLayerBounds(m_layerForHorizontalScrollbar.get());
    setEventRegionToLayerBounds(m_layerForVerticalScrollbar.get());
    setEventRegionToLayerBounds(m_layerForScrollCorner.get());

    if (m_scrolledContentsLayer)
        updateEventRegionForLayer(*m_scrolledContentsLayer);

    if (m_foregroundLayer)
        updateEventRegionForLayer(*m_foregroundLayer);

    forEachSVGSegmentLayer([&](GraphicsLayer& segmentLayer) {
        updateEventRegionForLayer(segmentLayer);
    });

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS) && ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
    // Give the system-preview badge its own interaction region so gaze hover lights it up
    // the way it would for the (anchor-wrapped) model itself, AND make it click-through
    // outside the actual badge rect so users can still click the model area for AR launch.
    if (m_systemPreviewBadgeLayer) {
        FloatRect layerBounds({ }, m_systemPreviewBadgeLayer->size());
        // Match ARKitBadgeSystemImage::draw: top-right corner with size 35+8 (small) or 70+20 (large).
        using BadgeMetrics = ARKitBadgeSystemImage::BadgeMetrics;
        bool useSmallBadge = layerBounds.width() < BadgeMetrics::minimumSizeForLarge || layerBounds.height() < BadgeMetrics::minimumSizeForLarge;
        int badgeOffset = useSmallBadge ? BadgeMetrics::smallOffset : BadgeMetrics::largeOffset;
        int badgeDimension = useSmallBadge ? BadgeMetrics::smallDimension : BadgeMetrics::largeDimension;
        FloatRect badgeRect(layerBounds.width() - badgeDimension - badgeOffset, badgeOffset, badgeDimension, badgeDimension);

        EventRegion eventRegion;
        auto eventRegionContext = eventRegion.makeContext();
        if (visibleToHitTesting)
            eventRegionContext->unite(FloatRoundedRect(badgeRect, CornerRadii(badgeDimension / 2.0f)), renderer(), renderer().style());
        eventRegionContext->uniteInteractionRegions(renderer(), badgeRect, { }, std::nullopt);
        eventRegionContext->copyInteractionRegionsToEventRegion(renderer().document().settings().interactionRegionMinimumCornerRadius());
        m_systemPreviewBadgeLayer->setEventRegion(WTF::move(eventRegion));
    }
#endif

#if ENABLE(SPATIAL_PORTAL) && ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
    // A portal scene draws the layers of promoted children, and so their interaction regions too.
    if (CheckedPtr controller = promotedChildPortalController())
        controller->promotedChildEventRegionDidChange();
#endif

    setNeedsEventRegionUpdate(false);
}
#endif

#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
void RenderLayerBacking::clearInteractionRegions()
{
    auto clearInteractionRegionsForLayer = [&](GraphicsLayer& graphicsLayer) {
        if (graphicsLayer.eventRegion().interactionRegions().isEmpty())
            return;

        EventRegion eventRegion = graphicsLayer.eventRegion();
        eventRegion.clearInteractionRegions();
        graphicsLayer.setEventRegion(WTF::move(eventRegion));
    };

    clearInteractionRegionsForLayer(*m_graphicsLayer);

    if (m_scrolledContentsLayer)
        clearInteractionRegionsForLayer(*m_scrolledContentsLayer);

    if (m_foregroundLayer)
        clearInteractionRegionsForLayer(*m_foregroundLayer);

    forEachSVGSegmentLayer([&](GraphicsLayer& segmentLayer) {
        clearInteractionRegionsForLayer(segmentLayer);
    });

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    if (m_systemPreviewBadgeLayer)
        clearInteractionRegionsForLayer(*m_systemPreviewBadgeLayer);
#endif
}
#endif

#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
void RenderLayerBacking::updateSeparatedProperties()
{
    bool isSeparated = RenderLayerCompositor::isSeparated(renderer());
    m_graphicsLayer->setIsSeparated(isSeparated);

    const auto& renderImage = dynamicDowncast<RenderImage>(renderer());
    if (!renderImage)
        return;

    bool isSeparatedImage = [&] {
        if (!isSeparated)
            return false;
        if (!renderImage->cachedImage() || renderImage->cachedImage()->errorOccurred())
            return false;
        RefPtr bitmapImage = dynamicDowncast<BitmapImage>(renderImage->cachedImage()->image());
        if (!bitmapImage)
            return false;
        if (bitmapImage.get() == &BitmapImage::nullImage())
            return false;
        return !bitmapImage->isAnimated() && bitmapImage->nativeImage();
    }();

    m_graphicsLayer->setIsSeparatedImage(isSeparatedImage);
}
#endif

// Truncating a stack can call into its backing, so the stack is out of its field while it is updated.
static void updateClippingStackWithClipData(std::unique_ptr<LayerAncestorClippingStack>& field, RenderLayerCompositor& compositor, Vector<CompositedClipData>&& clippingData)
{
    auto stack = std::exchange(field, nullptr);
    stack->updateWithClipData(compositor, WTF::move(clippingData));
    RELEASE_ASSERT(!field);
    field = WTF::move(stack);
}

bool RenderLayerBacking::updateAncestorClippingStack(Vector<CompositedClipData>&& clippingData)
{
    if (!m_ancestorClippingStack && clippingData.isEmpty())
        return false;

    if (m_ancestorClippingStack && clippingData.isEmpty()) {
        // Clearing a stack's layers can call into this backing, so the stacks are out of their fields first.
        auto ancestorClippingStack = std::exchange(m_ancestorClippingStack, nullptr);
        auto overflowControlsHostLayerAncestorClippingStack = std::exchange(m_overflowControlsHostLayerAncestorClippingStack, nullptr);
        ancestorClippingStack->clear(compositor());
        if (overflowControlsHostLayerAncestorClippingStack)
            overflowControlsHostLayerAncestorClippingStack->clear(compositor());
        return true;
    }
    
    if (!m_ancestorClippingStack) {
        m_ancestorClippingStack = makeUnique<LayerAncestorClippingStack>(WTF::move(clippingData));
        LOG_WITH_STREAM(Compositing, stream << "layer " << &m_owningLayer << " ancestorClippingStack " << *m_ancestorClippingStack);
        return true;
    }
    
    if (m_ancestorClippingStack->equalToClipData(clippingData)) {
        LOG_WITH_STREAM(Compositing, stream << "layer " << &m_owningLayer << " ancestorClippingStack " << *m_ancestorClippingStack);
        return false;
    }
    
    updateClippingStackWithClipData(m_ancestorClippingStack, compositor(), Vector { clippingData });
    LOG_WITH_STREAM(Compositing, stream << "layer " << &m_owningLayer << " ancestorClippingStack " << *m_ancestorClippingStack);
    if (m_overflowControlsHostLayerAncestorClippingStack)
        updateClippingStackWithClipData(m_overflowControlsHostLayerAncestorClippingStack, compositor(), WTF::move(clippingData));
    return true;
}

void RenderLayerBacking::ensureOverflowControlsHostLayerAncestorClippingStack(const RenderLayer* compositedAncestor)
{
    RELEASE_ASSERT(m_ancestorClippingStack);
    auto clippingData = m_ancestorClippingStack->compositedClipData();

    if (m_overflowControlsHostLayerAncestorClippingStack)
        updateClippingStackWithClipData(m_overflowControlsHostLayerAncestorClippingStack, compositor(), WTF::move(clippingData));
    else
        m_overflowControlsHostLayerAncestorClippingStack = makeUnique<LayerAncestorClippingStack>(WTF::move(clippingData));

    ensureClippingStackLayers(ClippingStackName::OverflowControlsHost);

    updateClippingStackLayerGeometry(ClippingStackName::OverflowControlsHost, compositedAncestor, computeParentGraphicsLayerRect(compositedAncestor));

    connectClippingStackLayers(ClippingStackName::OverflowControlsHost);
}

static const RenderBox* boxNeedingShapeMaskForClip(const CompositedClipData& clipData)
{
    // Rectangular clip entries are an intersection of ancestor clips, and their clippingLayer is the layer being clipped, not the clipper.
    if (!clipData.clipRect.hasNonZeroRadii())
        return nullptr;

    auto* clippingLayer = clipData.clippingLayer.get();
    if (!clippingLayer)
        return nullptr;

    auto* box = dynamicDowncast<RenderBox>(clippingLayer->renderer());
    if (!box || !box->style().border().hasCornerShapeOutsideRoundedRect())
        return nullptr;
    return box;
}

LayerAncestorClippingStack* RenderLayerBacking::clippingStack(ClippingStackName name) const
{
    switch (name) {
    case ClippingStackName::Ancestor: return m_ancestorClippingStack.get();
    case ClippingStackName::OverflowControlsHost: return m_overflowControlsHostLayerAncestorClippingStack.get();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

std::unique_ptr<LayerAncestorClippingStack>& RenderLayerBacking::clippingStackField(ClippingStackName name)
{
    switch (name) {
    case ClippingStackName::Ancestor: return m_ancestorClippingStack;
    case ClippingStackName::OverflowControlsHost: return m_overflowControlsHostLayerAncestorClippingStack;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static LayerAncestorClippingStack::ClippingStackEntry& clippingStackEntry(LayerAncestorClippingStack* clippingStack, size_t index)
{
    RELEASE_ASSERT(clippingStack);
    return clippingStack->stack().at(index);
}

size_t RenderLayerBacking::clippingStackSize(ClippingStackName name) const
{
    auto* stack = clippingStack(name);
    return stack ? stack->stack().size() : 0;
}

bool RenderLayerBacking::clippingStackEntryIsOverflowScroll(ClippingStackName name, size_t index) const
{
    return clippingStackEntry(clippingStack(name), index).clipData.isOverflowScroll;
}

bool RenderLayerBacking::clippingStackEntryNeedsShapeMask(ClippingStackName name, size_t index) const
{
    return boxNeedingShapeMaskForClip(clippingStackEntry(clippingStack(name), index).clipData);
}

RefPtr<GraphicsLayer>& RenderLayerBacking::clippingStackEntryLayerField(ClippingStackName name, size_t index, ClippingStackLayerName layerName) const
{
    auto& entry = clippingStackEntry(clippingStack(name), index);
    switch (layerName) {
    case ClippingStackLayerName::Clipping: return entry.clippingLayer;
    case ClippingStackLayerName::Scrolling: return entry.scrollingLayer;
    case ClippingStackLayerName::ShapeMask: return entry.shapeMaskLayer;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

GraphicsLayer* RenderLayerBacking::clippingStackEntryLayer(ClippingStackName name, size_t index, ClippingStackLayerName layerName) const
{
    return clippingStackEntryLayerField(name, index, layerName).get();
}

void RenderLayerBacking::createClippingStackEntryLayer(ClippingStackName name, size_t index, ClippingStackLayerName layerName)
{
    auto& field = clippingStackEntryLayerField(name, index, layerName);
    RELEASE_ASSERT(!field);
    switch (layerName) {
    case ClippingStackLayerName::Clipping:
        field = createGraphicsLayer(clippingStackEntryIsOverflowScroll(name, index) ? "clip for scroller"_s : "ancestor clipping"_s);
        return;
    case ClippingStackLayerName::Scrolling:
        field = createGraphicsLayer("scrolling proxy"_s);
        return;
    case ClippingStackLayerName::ShapeMask:
        field = createGraphicsLayer("ancestor clip shape mask"_s, GraphicsLayer::Type::Shape);
        return;
    }
}

void RenderLayerBacking::unparentAndClearClippingStackEntryLayer(ClippingStackName name, size_t index, ClippingStackLayerName layerName)
{
    GraphicsLayer::unparentAndClear(clippingStackEntryLayerField(name, index, layerName));
}

void RenderLayerBacking::clearClippingStack(ClippingStackName name)
{
    // Clearing the stack's layers can call into this backing, so the stack is out of its field first.
    auto stack = std::exchange(clippingStackField(name), nullptr);
    RELEASE_ASSERT(stack);
    stack->clear(compositor());
}

LayoutRect RenderLayerBacking::clippingStackEntryClipRect(ClippingStackName name, size_t index) const
{
    return clippingStackEntry(clippingStack(name), index).clipData.clipRect.rect();
}

RenderLayer* RenderLayerBacking::clippingStackEntryClippingLayer(ClippingStackName name, size_t index) const
{
    return clippingStackEntry(clippingStack(name), index).clipData.clippingLayer.get();
}

void RenderLayerBacking::updateClippingStackEntryContentsClipping(ClippingStackName name, size_t index, FloatSize snappedClippingLayerSize)
{
    auto& entry = clippingStackEntry(clippingStack(name), index);
    RELEASE_ASSERT(entry.clippingLayer);
    auto roundedClipRect = entry.clipData.clipRect;
    auto clipRect = roundedClipRect.rect();
    clipRect.setLocation({ });
    roundedClipRect.setRect(clipRect);

    if (CheckedPtr box = boxNeedingShapeMaskForClip(entry.clipData); box && entry.shapeMaskLayer) {
        entry.clippingLayer->setContentsClippingRect(contentsClippingRectForCornerShape(FloatRoundedRect(roundedClipRect), box->style()));

        auto borderShape = BorderShape::shapeForBorderRect(box->usedStyle(), box->borderBoxRect());
        auto shapePath = borderShape.pathForInnerShape(pixelSnappingScaleFactor());
        auto clipOffsetInBox = box->overflowClipRect(LayoutPoint { }).location();
        shapePath.translate(FloatSize { -clipOffsetInBox.x().toFloat(), -clipOffsetInBox.y().toFloat() });

        entry.shapeMaskLayer->setSize(snappedClippingLayerSize);
        entry.shapeMaskLayer->setPosition(FloatPoint());
        entry.shapeMaskLayer->setShapeLayerPath(shapePath);
        entry.shapeMaskLayer->setShapeLayerWindRule(WindRule::NonZero);
    } else if (auto* clippingLayer = entry.clipData.clippingLayer.get(); clippingLayer && clippingLayer->renderer().style().border().hasNonRoundCornerShape())
        entry.clippingLayer->setContentsClippingRect(contentsClippingRectForCornerShape(FloatRoundedRect(roundedClipRect), clippingLayer->renderer().style()));
    else
        entry.clippingLayer->setContentsClippingRect(FloatRoundedRect(roundedClipRect));
    entry.clippingLayer->setContentsRectClipsDescendants(true);
}

bool RenderLayerBacking::needsRepaintOnCompositedScroll() const
{
    if (!hasScrollingLayer())
        return false;

    if (Style::hasImageWithAttachment(renderer().style().backgroundLayers(), FillAttachment::LocalBackground))
        return true;

    if (RefPtr scrollingCoordinator = m_owningLayer.page().scrollingCoordinator())
        return scrollingCoordinator->hasSynchronousScrollingReasons(m_scrollingNodeID);

    return false;
}

#if ENABLE(MODEL_PROCESS)
bool RenderLayerBacking::updateContentsContainmentLayer()
{
#if USE(SYSTEM_PREVIEW)
    bool needsContainment = m_backgroundLayer || m_systemPreviewBadgeLayer;
#else
    bool needsContainment = m_backgroundLayer;
#endif
    bool layerChanged = false;
    if (needsContainment) {
        if (!m_contentsContainmentLayer) {
            auto layerName = makeString(m_owningLayer.name(), " (contents containment)"_s);
            m_contentsContainmentLayer = createGraphicsLayer(layerName);
            m_contentsContainmentLayer->setAppliesPageScale(true);
            m_graphicsLayer->setAppliesPageScale(false);
            layerChanged = true;
        }
    } else if (m_contentsContainmentLayer) {
        willDestroyLayer(m_contentsContainmentLayer.get());
        GraphicsLayer::unparentAndClear(m_contentsContainmentLayer);
        layerChanged = true;
        m_graphicsLayer->setAppliesPageScale(true);
    }
    return layerChanged;
}
#endif

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
bool RenderLayerBacking::needsSystemPreviewBadgeLayer() const
{
#if PLATFORM(VISION)
    if (!renderer().document().settings().systemPreviewEnabled())
        return false;
    CheckedPtr renderModel = dynamicDowncast<RenderModel>(renderer());
    if (!renderModel)
        return false;
    RefPtr anchor = dynamicDowncast<HTMLAnchorElement>(renderModel->modelElement().parentElement());
    return anchor && anchor->isSystemPreviewLink();
#else
    // On other platforms the inline paint in RenderModel::paintReplaced is sufficient.
    return false;
#endif
}

bool RenderLayerBacking::updateSystemPreviewBadgeLayer(bool needsLayer)
{
    bool layerChanged = false;
    if (needsLayer) {
        if (!m_systemPreviewBadgeLayer) {
            auto layerName = makeString(m_owningLayer.name(), " (system preview badge)"_s);
            m_systemPreviewBadgeLayer = createGraphicsLayer(layerName);
            m_systemPreviewBadgeLayer->setDrawsContent(true);
            m_systemPreviewBadgeLayer->setAnchorPoint({ });
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
            m_systemPreviewBadgeLayer->setIsSeparated(false);
#endif
            layerChanged = true;
        }
        if (!m_systemPreviewWrapperLayer) {
            auto layerName = makeString(m_owningLayer.name(), " (system preview wrapper)"_s);
            m_systemPreviewWrapperLayer = createGraphicsLayer(layerName);
            m_systemPreviewWrapperLayer->setAnchorPoint({ });
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
            m_systemPreviewWrapperLayer->setIsSeparated(false);
#endif
            layerChanged = true;
        }
    } else {
        if (m_systemPreviewBadgeLayer) {
            willDestroyLayer(m_systemPreviewBadgeLayer.get());
            GraphicsLayer::unparentAndClear(m_systemPreviewBadgeLayer);
            layerChanged = true;
        }
        if (m_systemPreviewWrapperLayer) {
            willDestroyLayer(m_systemPreviewWrapperLayer.get());
            GraphicsLayer::unparentAndClear(m_systemPreviewWrapperLayer);
            layerChanged = true;
        }
    }
    return layerChanged;
}

void RenderLayerBacking::updateSystemPreviewBadgeLayerGeometry()
{
    if (!m_systemPreviewBadgeLayer)
        return;
    CheckedPtr renderModel = dynamicDowncast<RenderModel>(renderer());
    if (!renderModel)
        return;

    auto contentRect = renderModel->replacedContentRect();
    auto snapped = snapRectToDevicePixels(contentRect, renderModel->modelElement().document().pixelSnappingScaleFactor());
    m_systemPreviewBadgeLayer->setPosition(snapped.location());
    m_systemPreviewBadgeLayer->setSize(snapped.size());
    m_systemPreviewBadgeLayer->setNeedsDisplay();
}

void RenderLayerBacking::paintSystemPreviewBadgeLayer(GraphicsContext& context, const FloatRect& clip)
{
    if (!m_systemPreviewBadgeLayer)
        return;
    auto rect = FloatRect({ }, m_systemPreviewBadgeLayer->size());
    GraphicsContextStateSaver stateSaver(context);
    context.clip(clip);
    PaintInfo paintInfo(context, LayoutRect(rect), PaintPhase::Foreground, { });
    renderer().theme().paintSystemPreviewBadge(paintInfo, rect);
}
#endif

static bool canDirectlyCompositeBackgroundBackgroundImage(const RenderElement& renderer)
{
    const Style::ComputedStyle& style = renderer.style();

    if (!GraphicsLayer::supportsContentsTiling())
        return false;

    auto& backgroundLayers = style.backgroundLayers();
    if (backgroundLayers.usedLength() > 1)
        return false;

    if (!Style::imagesAreLoaded(backgroundLayers, renderer))
        return false;

    auto& layer = backgroundLayers.usedFirst();

    if (layer.attachment() != FillAttachment::ScrollBackground)
        return false;

    // FIXME: Allow color+image compositing when it makes sense.
    // For now bailing out.
    if (style.visitedDependentUsedBackgroundColorApplyingColorFilter().isVisible())
        return false;

    // FIXME: support gradients with isGeneratedImage.
    RefPtr styleImage = layer.image().tryStyleImage();
    if (!styleImage->hasCachedImage())
        return false;

    RefPtr image = styleImage->cachedImage()->image();
    if (!image->isBitmapImage())
        return false;

    return true;
}

bool RenderLayerBacking::canDirectlyCompositeBackgroundImage() const
{
    return canDirectlyCompositeBackgroundBackgroundImage(renderer());
}

bool RenderLayerBacking::boxPaintsOwnBackground() const
{
    CheckedPtr box = renderBox();
    RELEASE_ASSERT(box);
    return Paint::BackgroundPainter::paintsOwnBackground(*box);
}

// Only bitmap images are directly composited, so the layer shows the image's current frame at its natural size.
RefPtr<NativeImage> RenderLayerBacking::nativeImageForDirectlyCompositedImage(Image& image)
{
    // Showing the image in a layer uses its decoded data, as drawing it would.
    if (RefPtr observer = image.imageObserver())
        observer->didDraw(image);

    RefPtr bitmapImage = dynamicDowncast<BitmapImage>(image);
    if (!bitmapImage)
        return nullptr;

    return bitmapImage->currentNativeImage();
}

// Returns true if the contents rect was updated.
bool RenderLayerBacking::updateDirectlyCompositedBackgroundImage(bool isSimpleContainer)
{
    if (!isSimpleContainer) {
        m_graphicsLayer->setContentsToNativeImage(nullptr);
        return false;
    }

    auto& backgroundLayers = renderer().style().backgroundLayers();
    if (!Style::hasImageInAnyLayer(backgroundLayers)) {
        m_graphicsLayer->setContentsToNativeImage(nullptr);
        return false;
    }

    auto& backgroundLayer = backgroundLayers.usedFirst();
    auto backgroundBox = LayoutRect { backgroundBoxForSimpleContainerPainting() };
    CheckedPtr box = renderBox();
    RELEASE_ASSERT(box);
    // FIXME: Absolute paint location is required here.
    auto geometry = Paint::BackgroundPainter::calculateFillLayerImageGeometry(*box, box.get(), backgroundLayer, renderer().style().usedZoomForLength(), { }, backgroundBox);

    m_graphicsLayer->setContentsTileSize(geometry.tileSize);
    m_graphicsLayer->setContentsTilePhase(geometry.phase);
    m_graphicsLayer->setContentsRect(geometry.destinationRect);
    m_graphicsLayer->setContentsClippingRect(FloatRoundedRect(geometry.destinationRect));
    RefPtr styleImage = backgroundLayer.image().tryStyleImage();
    auto* cachedImage = styleImage ? styleImage->cachedImage() : nullptr;
    RefPtr image = cachedImage ? cachedImage->image() : nullptr;
    RELEASE_ASSERT(image);
    if (RefPtr nativeImage = nativeImageForDirectlyCompositedImage(*image))
        m_graphicsLayer->setContentsToNativeImage(nativeImage.get());

    return true;
}

const RenderReplaced* RenderLayerBacking::rendererAsRenderReplaced() const
{
    return dynamicDowncast<RenderReplaced>(renderer());
}

const RenderVideo* RenderLayerBacking::rendererAsRenderVideo() const
{
#if ENABLE(VIDEO)
    return dynamicDowncast<RenderVideo>(renderer());
#else
    return nullptr;
#endif
}

bool RenderLayerBacking::canvasHasDrawableContent() const
{
    return downcast<RenderHTMLCanvas>(renderer()).hasDrawableContent();
}

IntSize RenderLayerBacking::canvasElementSize() const
{
    return downcast<RenderHTMLCanvas>(renderer()).canvasElement().size();
}

bool RenderLayerBacking::viewTransitionCaptureHasDisplayOnlyImage() const
{
    auto* viewTransitionCapture = dynamicDowncast<RenderViewTransitionCapture>(renderer());
    return viewTransitionCapture && viewTransitionCapture->displayOnlyImage();
}

bool RenderLayerBacking::viewTransitionCaptureImageIsDirectlyComposited() const
{
    auto image = downcast<RenderViewTransitionCapture>(renderer()).image();
    if (!image)
        return false;
    return m_graphicsLayer->shouldDirectlyCompositeImageBuffer(image.get());
}

void RenderLayerBacking::setViewTransitionCaptureImageAsContents()
{
    auto& viewTransitionCapture = downcast<RenderViewTransitionCapture>(renderer());
    if (RefPtr image = viewTransitionCapture.displayOnlyImage())
        m_graphicsLayer->setContentsToNativeImage(image.get());
    else if (auto image = viewTransitionCapture.image())
        m_graphicsLayer->setContentsToImageBuffer(image.get());
}

LayoutRect RenderLayerBacking::viewTransitionCaptureLocalOverflowRect() const
{
    return downcast<RenderViewTransitionCapture>(renderer()).captureLocalOverflowRect();
}

BitmapImage* RenderLayerBacking::asBitmapImage(Image* image)
{
    return dynamicDowncast<BitmapImage>(image);
}

bool RenderLayerBacking::rendererHostsRemoteFrame() const
{
    CheckedPtr renderWidget = dynamicDowncast<RenderWidget>(renderer());
    return renderWidget && renderWidget->remoteFrame();
}

bool RenderLayerBacking::rendererIsSpatialPortal() const
{
#if ENABLE(SPATIAL_PORTAL)
    return RenderLayerCompositor::isSpatialPortal(renderer());
#else
    return false;
#endif
}

bool RenderLayerBacking::rendererMayHaveNonZeroOpacity() const
{
    auto styleable = Styleable::fromRenderer(renderer());
    return !styleable || styleable->mayHaveNonZeroOpacity();
}

bool RenderLayerBacking::isBitmapOnly() const
{
    return m_owningLayer.isBitmapOnly();
}

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
bool RenderLayerBacking::layerAllowsDynamicContentScaling(const GraphicsLayer*) const
{
    return m_owningLayer.allowsDynamicContentScaling();
}
#endif

void RenderLayerBacking::contentChanged(ContentChangeType changeType, const std::optional<FloatRect>& dirtyRect)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    contentChangedInScope(changeType, dirtyRect);
}

GraphicsLayer* RenderLayerBacking::parentForSublayers() const
{
    if (m_scrolledContentsLayer)
        return m_scrolledContentsLayer.get();

    return m_childContainmentLayer ? m_childContainmentLayer.get() : m_graphicsLayer.get();
}

GraphicsLayer* RenderLayerBacking::childForSuperlayers() const
{
    if (m_owningLayer.isRenderViewLayer()) {
        // If the document element is captured, then the RenderView's layer will get attached
        // into the view-transition tree, and we instead want to attach the root of the VT tree to our ancestor.
        if (protect(m_owningLayer.renderer().document())->activeViewTransitionCapturedDocumentElement()) {
            if (WeakPtr viewTransitionContainingBlock = m_owningLayer.renderer().view().viewTransitionContainingBlock(); viewTransitionContainingBlock && viewTransitionContainingBlock->hasLayer() && viewTransitionContainingBlock->layer()->backing())
                return viewTransitionContainingBlock->layer()->backing()->childForSuperlayers();
        }
    }
    return childForSuperlayersExcludingViewTransitions();
}

GraphicsLayer* RenderLayerBacking::childForSuperlayersExcludingViewTransitions() const
{
    if (m_transformFlatteningLayer)
        return m_transformFlatteningLayer.get();

    if (m_ancestorClippingStack)
        return m_ancestorClippingStack->firstLayer();

    if (RefPtr viewportConstrainedLayer = viewportClippingOrAnchorLayer())
        return viewportConstrainedLayer.unsafeGet();

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    if (m_systemPreviewWrapperLayer)
        return m_systemPreviewWrapperLayer.get();
#endif

    if (m_contentsContainmentLayer)
        return m_contentsContainmentLayer.get();

    return m_graphicsLayer.get();
}

LayoutSize RenderLayerBacking::offsetRelativeToRendererOriginForDescendantLayers() const
{
    if (m_scrolledContentsLayer)
        return toLayoutSize(scrollContainerLayerBox(downcast<RenderBox>(renderer())).location());

    if (hasClippingLayer())
        return toLayoutSize(clippingLayerBox(renderer()).location());

    return { };
}

void RenderLayerBacking::paintIntoLayer(const GraphicsLayer* graphicsLayer, GraphicsContext& context,
    const IntRect& paintDirtyRect, // In the coords of rootLayer.
    OptionSet<PaintBehavior> paintBehavior, RegionContext* regionContext)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    if ((paintsIntoWindow() || paintsIntoCompositedAncestor()) && graphicsLayer->paintingPhase() != OptionSet<GraphicsLayerPaintingPhase>(GraphicsLayerPaintingPhase::ChildClippingMask)) {
#if !PLATFORM(IOS_FAMILY) && !OS(WINDOWS)
        // FIXME: Looks like the CALayer tree is out of sync with the GraphicsLayer heirarchy
        // when pages are restored from the BackForwardCache.
        // <rdar://problem/8712587> ASSERT: When Going Back to Page with Plugins in BackForwardCache
        ASSERT_NOT_REACHED();
#endif
        return;
    }
    auto paintFlags = paintFlagsForLayer(*graphicsLayer);

    if (is<EventRegionContext>(regionContext))
        paintFlags.add(RenderLayer::PaintLayerFlag::CollectingEventRegion);

    RenderObject::SetLayoutNeededForbiddenScope forbidSetNeedsLayout(renderer());

    auto paintOneLayer = [&](RenderLayer& layer, OptionSet<RenderLayer::PaintLayerFlag> paintFlags) {
        LocalFrameView::PaintingState paintingState;
        if (!regionContext) {
            InspectorInstrumentation::willPaint(layer.renderer());

            if (layer.isRenderViewLayer())
                renderer().view().frameView().willPaintContents(context, paintDirtyRect, paintingState, regionContext);
        }

        RenderLayer::LayerPaintingInfo paintingInfo(&m_owningLayer, paintDirtyRect, paintBehavior, -m_subpixelOffsetFromRenderer);
        paintingInfo.setRegionContext(regionContext);

        if (&layer == &m_owningLayer) {
            // Limit the owning SVG layer's DOM-order child walk to the part of the flat list this GraphicsLayer
            // owns: the primary segment for the primary layer, the matching segment for each overlay. std::nullopt (no segments)
            // leaves the common path unchanged. Only m_owningLayer has a flat list.
            auto svgPaintOrderItemRange = svgSegmentRangeForGraphicsLayer(*graphicsLayer);
            {
                bool shouldResetCompositeMode = false;
                if (m_shouldPaintUsingCompositeCopy && context.compositeMode() == CompositeMode { CompositeOperator::SourceOver, BlendMode::Normal }) {
                    context.setCompositeMode({ CompositeOperator::Copy, BlendMode::Normal });
                    shouldResetCompositeMode = true;
                }
                layer.paintLayerContents(LentGraphicsContext { context }, paintingInfo, paintFlags, svgPaintOrderItemRange);
                if (shouldResetCompositeMode)
                    context.setCompositeMode({ CompositeOperator::SourceOver, BlendMode::Normal });
            }
            auto* scrollableArea = layer.scrollableArea();
            if (scrollableArea && scrollableArea->containsDirtyOverlayScrollbars() && !regionContext)
                layer.paintLayerContents(LentGraphicsContext { context }, paintingInfo, paintFlags | RenderLayer::PaintLayerFlag::PaintingOverlayScrollbars, svgPaintOrderItemRange);
        } else
            layer.paintLayerWithEffects(LentGraphicsContext { context }, paintingInfo, paintFlags);

        if (!regionContext) {
            if (layer.isRenderViewLayer())
                renderer().view().frameView().didPaintContents(context, paintDirtyRect, paintingState);

            InspectorInstrumentation::didPaint(layer.renderer(), paintDirtyRect);
        }

        ASSERT(!m_owningLayer.m_usedTransparency);
    };

    paintOneLayer(m_owningLayer, paintFlags);
    
    // FIXME: Need to check m_foregroundLayer, masking etc. webkit.org/b/197565.
    RefPtr<GraphicsLayer> destinationForSharingLayers = m_scrolledContentsLayer ? m_scrolledContentsLayer.get() : m_graphicsLayer.get();

    if (graphicsLayer == destinationForSharingLayers) {
        OptionSet<RenderLayer::PaintLayerFlag> sharingLayerPaintFlags = {
            RenderLayer::PaintLayerFlag::PaintingCompositingBackgroundPhase,
            RenderLayer::PaintLayerFlag::PaintingCompositingForegroundPhase
        };

        if (graphicsLayer->paintingPhase().contains(GraphicsLayerPaintingPhase::OverflowContents))
            sharingLayerPaintFlags.add(RenderLayer::PaintLayerFlag::PaintingOverflowContents);

        if (is<EventRegionContext>(regionContext))
            sharingLayerPaintFlags.add(RenderLayer::PaintLayerFlag::CollectingEventRegion);

        for (auto& layer : m_backingSharingLayers | dereferenceView)
            paintOneLayer(layer, sharingLayerPaintFlags);
    }

    if (!regionContext)
        compositor().didPaintBacking(this);
}

#if ENABLE(TOUCH_ACTION_REGIONS) || ENABLE(WHEEL_EVENT_REGIONS) || ENABLE(TOUCH_EVENT_REGIONS)
struct PatternDescription {
    ASCIILiteral name;
    FloatSize phase;
    SRGBA<uint8_t> fillColor;
};

static RefPtr<const Pattern> patternForDescription(PatternDescription description, FloatSize contentOffset, GraphicsContext& destContext)
{
    const FloatSize tileSize { 32, 18 };

    auto imageBuffer = destContext.createAlignedImageBuffer(tileSize);
    if (!imageBuffer)
        return nullptr;

    {
        GraphicsContext& imageContext = imageBuffer->context();

        FontCascadeDescription fontDescription;
        fontDescription.setOneFamily("Helvetica"_s);
        fontDescription.setComputedSize(10);
        fontDescription.setUsedSize(10);
        fontDescription.setWeight(FontSelectionValue(500));
        FontCascade font(WTF::move(fontDescription));
        font.update(nullptr);

        TextRun textRun = TextRun(StringView { description.name });
        imageContext.setFillColor(description.fillColor);

        constexpr float textGap = 4;
        constexpr float yOffset = 12;
        imageContext.drawText(font, textRun, { textGap, yOffset }, 0);
    }

    AffineTransform patternOffsetTransform;
    patternOffsetTransform.translate(contentOffset + description.phase);
    patternOffsetTransform.scale(1 / destContext.scaleFactor());

    return Pattern::create({ imageBuffer.releaseNonNull() }, { true, true, patternOffsetTransform });
};
#endif

#if ENABLE(TOUCH_ACTION_REGIONS)
static RefPtr<const Pattern> patternForTouchAction(TouchAction touchAction, FloatSize contentOffset, GraphicsContext& destContext)
{
    auto toIndex = [](TouchAction touchAction) -> unsigned {
        switch (touchAction) {
        case TouchAction::None:
            return 1;
        case TouchAction::Manipulation:
            return 2;
        case TouchAction::PanX:
            return 3;
        case TouchAction::PanY:
            return 4;
        case TouchAction::PinchZoom:
            return 5;
        case TouchAction::Auto:
            break;
        }
        return 0;
    };

    constexpr auto fillColor = Color::black.colorWithAlphaByte(128);

    static const std::array patternDescriptions {
        PatternDescription { "auto"_s, { }, fillColor },
        PatternDescription { "none"_s, { }, fillColor },
        PatternDescription { "manip"_s, { }, fillColor },
        PatternDescription { "pan-x"_s, { }, fillColor },
        PatternDescription { "pan-y"_s, { 0, 9 }, fillColor },
        PatternDescription { "p-z"_s, { 16, 4.5 }, fillColor },
    };
    
    auto actionIndex = toIndex(touchAction);
    if (!actionIndex || actionIndex >= patternDescriptions.size())
        return nullptr;

    return patternForDescription(patternDescriptions[actionIndex], contentOffset, destContext);
}
#endif

#if ENABLE(WHEEL_EVENT_REGIONS) || ENABLE(TOUCH_EVENT_REGIONS)
static RefPtr<const Pattern> patternForEventListenerRegionType(EventListenerRegionType type, FloatSize contentOffset, GraphicsContext& destContext)
{
    auto patternAndPhase = [&]() -> PatternDescription {
        switch (type) {
        case EventListenerRegionType::Wheel:
            return { "wheel"_s, { }, Color::darkGreen.colorWithAlphaByte(128) };
        case EventListenerRegionType::NonPassiveWheel:
            return { "sync"_s, { 0, 9 }, SRGBA<uint8_t> { 200, 0, 0, 128 } };
        case EventListenerRegionType::MouseClick:
            break;
        case EventListenerRegionType::TouchStart:
        case EventListenerRegionType::TouchMove:
        case EventListenerRegionType::TouchEnd:
        case EventListenerRegionType::TouchForceChange:
        case EventListenerRegionType::TouchCancel:
            return { "touch"_s, { }, Color::gray.colorWithAlphaByte(128) };
        case EventListenerRegionType::NonPassiveTouchStart:
        case EventListenerRegionType::NonPassiveTouchEnd:
        case EventListenerRegionType::NonPassiveTouchMove:
        case EventListenerRegionType::NonPassiveTouchForceChange:
            return { "sync touch"_s, { 0, 9 }, SRGBA<uint8_t> { 200, 200, 0, 128 } };
        case EventListenerRegionType::PointerDown:
        case EventListenerRegionType::PointerEnter:
        case EventListenerRegionType::PointerLeave:
        case EventListenerRegionType::PointerMove:
        case EventListenerRegionType::PointerOut:
        case EventListenerRegionType::PointerOver:
        case EventListenerRegionType::PointerUp:
            return { "pointer"_s, { }, Color::gray.colorWithAlphaByte(128) };
        case EventListenerRegionType::NonPassivePointerDown:
        case EventListenerRegionType::NonPassivePointerEnter:
        case EventListenerRegionType::NonPassivePointerLeave:
        case EventListenerRegionType::NonPassivePointerMove:
        case EventListenerRegionType::NonPassivePointerOut:
        case EventListenerRegionType::NonPassivePointerOver:
        case EventListenerRegionType::NonPassivePointerUp:
            return { "sync pointer"_s, { 0, 9 }, SRGBA<uint8_t> { 200, 200, 0, 128 } };
        case EventListenerRegionType::GestureChange:
        case EventListenerRegionType::GestureEnd:
        case EventListenerRegionType::GestureStart:
            return { "gesture"_s, { }, Color::lightGray.colorWithAlphaByte(128) };
        case EventListenerRegionType::NonPassiveGestureChange:
        case EventListenerRegionType::NonPassiveGestureEnd:
        case EventListenerRegionType::NonPassiveGestureStart:
            return { "sync gesture"_s, { 0, 9 }, SRGBA<uint8_t> { 200, 200, 0, 128 } };
        default:
            return { ""_s, { }, Color::black };
        }
        ASSERT_NOT_REACHED();
        return { ""_s, { }, Color::black };
    }();

    return patternForDescription(patternAndPhase, contentOffset, destContext);
}
#endif

void RenderLayerBacking::paintDebugOverlays(const GraphicsLayer* graphicsLayer, GraphicsContext& context)
{
    auto& eventRegion = graphicsLayer->eventRegion();
    if (eventRegion.isEmpty())
        return;

    GraphicsContextStateSaver stateSaver(context);

    // The region is offset by offsetFromRenderer() so undo that.
    auto contentOffset = roundedIntSize(graphicsLayer->offsetFromRenderer());
    context.translate(contentOffset);

    auto visibleDebugOverlayRegions = OptionSet<DebugOverlayRegions>::fromRaw(renderer().settings().visibleDebugOverlayRegions());
    if (visibleDebugOverlayRegions.containsAny({ DebugOverlayRegions::TouchActionRegion, DebugOverlayRegions::WheelEventHandlerRegion })) {
        constexpr auto regionColor = Color::blue.colorWithAlphaByte(50);
        context.setFillColor(regionColor);
        for (auto rect : eventRegion.region().rects())
            context.fillRect(rect);
    }

    if (visibleDebugOverlayRegions.contains(DebugOverlayRegions::TouchEventRegion)) {
        static constexpr auto regionColor = Color::red.colorWithAlphaByte(50);
        context.setFillColor(regionColor);
        for (auto rect : eventRegion.region().rects())
            context.fillRect(rect);
    }

#if ENABLE(TOUCH_ACTION_REGIONS)
    if (visibleDebugOverlayRegions.contains(DebugOverlayRegions::TouchActionRegion)) {
        constexpr std::array touchActionList {
            TouchAction::None,
            TouchAction::Manipulation,
            TouchAction::PanX,
            TouchAction::PanY,
            TouchAction::PinchZoom,
        };

        for (auto action : touchActionList) {
            auto* actionRegion = graphicsLayer->eventRegion().regionForTouchAction(action);
            if (!actionRegion)
                continue;

            auto fillPattern = patternForTouchAction(action, contentOffsetInCompositingLayer(), context);
            if (!fillPattern)
                continue;

            context.setFillPattern(fillPattern.releaseNonNull());
            for (auto rect : actionRegion->rects())
                context.fillRect(rect);
        }
    }
#endif

#if ENABLE(WHEEL_EVENT_REGIONS)
    if (visibleDebugOverlayRegions.contains(DebugOverlayRegions::WheelEventHandlerRegion)) {
        for (auto type : { EventListenerRegionType::Wheel, EventListenerRegionType::NonPassiveWheel }) {
            auto fillPattern = patternForEventListenerRegionType(type, graphicsLayer->offsetFromRenderer(), context);
            context.setFillPattern(fillPattern.releaseNonNull());

            auto& region = graphicsLayer->eventRegion().eventListenerRegionForType(type);
            for (auto rect : region.rects())
                context.fillRect(rect);
        }
    }
#endif

#if ENABLE(TOUCH_EVENT_REGIONS)
    if (visibleDebugOverlayRegions.contains(DebugOverlayRegions::TouchEventRegion)) {
        const auto& touchEventRegion = graphicsLayer->eventRegion().touchEventListenerRegion();

        if (!touchEventRegion.asynchronousDispatchRegion.isEmpty()) {
            if (RefPtr fillPattern = patternForEventListenerRegionType(EventListenerRegionType::TouchStart, graphicsLayer->offsetFromRenderer(), context)) {
                context.setFillPattern(fillPattern.releaseNonNull());
                for (auto rect : touchEventRegion.asynchronousDispatchRegion.rects())
                    context.fillRect(rect);
            }
        }

        for (const auto& [eventType, region] : touchEventRegion.eventSpecificSynchronousDispatchRegions) {
            if (region.isEmpty())
                continue;

            EventListenerRegionType regionType;
            switch (eventType) {
            case EventTrackingRegionsEventType::Touchstart:
                regionType = EventListenerRegionType::NonPassiveTouchStart;
                break;
            case EventTrackingRegionsEventType::Touchend:
                regionType = EventListenerRegionType::NonPassiveTouchEnd;
                break;
            case EventTrackingRegionsEventType::Touchmove:
                regionType = EventListenerRegionType::NonPassiveTouchMove;
                break;
            case EventTrackingRegionsEventType::Touchforcechange:
                regionType = EventListenerRegionType::NonPassiveTouchForceChange;
                break;
            default:
                continue;
            }

            if (RefPtr fillPattern = patternForEventListenerRegionType(regionType, graphicsLayer->offsetFromRenderer(), context)) {
                context.setFillPattern(fillPattern.releaseNonNull());
                for (auto rect : region.rects())
                    context.fillRect(rect);
            }
        }
    }
#endif

#if ENABLE(EDITABLE_REGION)
    if (visibleDebugOverlayRegions.contains(DebugOverlayRegions::EditableElementRegion)) {
        context.setFillColor(SRGBA<uint8_t> { 128, 0, 128, 50 });
        for (auto rect : eventRegion.rectsForEditableElements())
            context.fillRect(rect);
    }
#endif

#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
    if (DebugPageOverlays::shouldPaintOverlayIntoLayerForRegionType(renderer().page(), DebugPageOverlays::RegionType::InteractionRegion)) {
        context.setStrokeThickness(1);

        for (const auto& region : eventRegion.interactionRegions()) {
            if (region.type == InteractionRegion::Type::Occlusion)
                context.setStrokeColor(Color::red);
            else
                context.setStrokeColor(Color::green);
            
            auto rect = region.rectInLayerCoordinates;
            Path path;
            path.addRoundedRect(rect, { region.cornerRadius, region.cornerRadius });
            context.strokePath(path);
        }
    }
#endif
}

// Up-call from compositing layer drawing callback.
void RenderLayerBacking::paintContents(const GraphicsLayer& graphicsLayer, GraphicsContext& context, const FloatRect& clip, OptionSet<GraphicsLayerPaintBehavior> layerPaintBehavior)
{
#ifndef NDEBUG
    renderer().page().setIsPainting(true);
#endif

#if PLATFORM(MAC)
    LocalDefaultSystemAppearance localAppearance(renderer().useDarkAppearance());
#endif

#if HAVE(SUPPORT_HDR_DISPLAY)
    if (layerPaintBehavior.contains(GraphicsLayerPaintBehavior::TonemapHDRToDisplayHeadroom))
        context.setMaxEDRHeadroom(m_owningLayer.page().displayEDRHeadroom());
    else
        context.setMaxEDRHeadroom(std::nullopt);
#endif

    // The dirtyRect is in the coords of the painting root.
    FloatRect adjustedClipRect = clip;
    adjustedClipRect.move(m_subpixelOffsetFromRenderer);
    IntRect dirtyRect = enclosingIntRect(adjustedClipRect);

    if (!layerPaintBehavior.contains(GraphicsLayerPaintBehavior::ForceSynchronousImageDecode)) {
        if (!graphicsLayer.repaintCount())
            layerPaintBehavior.add(GraphicsLayerPaintBehavior::DefaultAsynchronousImageDecode);
    }

    if (&graphicsLayer == m_graphicsLayer.get()
        || &graphicsLayer == m_foregroundLayer.get()
        || &graphicsLayer == m_backgroundLayer.get()
        || &graphicsLayer == m_maskLayer.get()
        || &graphicsLayer == m_scrolledContentsLayer.get()
        || svgSegmentRangeForGraphicsLayer(graphicsLayer)) {

        if (!graphicsLayer.paintingPhase().contains(GraphicsLayerPaintingPhase::OverflowContents))
            dirtyRect.intersect(enclosingIntRect(compositedBoundsIncludingMargin()));

        // We have to use the same root as for hit testing, because both methods can compute and cache clipRects.
        OptionSet<PaintBehavior> behavior = PaintBehavior::Normal;
        if (layerPaintBehavior.contains(GraphicsLayerPaintBehavior::ForceSynchronousImageDecode))
            behavior.add(PaintBehavior::ForceSynchronousImageDecode);
        else if (layerPaintBehavior.contains(GraphicsLayerPaintBehavior::DefaultAsynchronousImageDecode))
            behavior.add(PaintBehavior::DefaultAsynchronousImageDecode);

#if HAVE(SUPPORT_HDR_DISPLAY)
        if (graphicsLayer.drawsHDRContent())
            behavior.add(PaintBehavior::DrawsHDRContent);
#endif

        paintIntoLayer(&graphicsLayer, context, dirtyRect, behavior);

#if ENABLE(SPATIAL_PORTAL)
        if (&graphicsLayer == m_graphicsLayer.get()) {
            if (CheckedPtr controller = promotedChildPortalController())
                controller->promotedChildDidPaint();
        }
#endif

        auto visibleDebugOverlayRegions = OptionSet<DebugOverlayRegions>::fromRaw(renderer().settings().visibleDebugOverlayRegions());

        if (visibleDebugOverlayRegions.containsAny({ DebugOverlayRegions::TouchActionRegion, DebugOverlayRegions::TouchEventRegion, DebugOverlayRegions::EditableElementRegion, DebugOverlayRegions::WheelEventHandlerRegion, DebugOverlayRegions::InteractionRegion }))
            paintDebugOverlays(&graphicsLayer, context);

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    } else if (&graphicsLayer == m_systemPreviewBadgeLayer.get()) {
        paintSystemPreviewBadgeLayer(context, clip);
#endif
    } else if (&graphicsLayer == layerForHorizontalScrollbar()) {
        if (m_owningLayer.hasVisibleContent()) {
            auto* scrollableArea = m_owningLayer.scrollableArea();
            ASSERT(scrollableArea);

            paintScrollbar(scrollableArea->horizontalScrollbar(), context, dirtyRect);
        }
    } else if (&graphicsLayer == layerForVerticalScrollbar()) {
        if (m_owningLayer.hasVisibleContent()) {
            auto* scrollableArea = m_owningLayer.scrollableArea();
            ASSERT(scrollableArea);

            paintScrollbar(scrollableArea->verticalScrollbar(), context, dirtyRect);
        }
    } else if (&graphicsLayer == layerForScrollCorner()) {
        auto* scrollableArea = m_owningLayer.scrollableArea();
        ASSERT(scrollableArea);

        auto controlsRects = scrollableArea->overflowControlsRects();
        auto cornerRect = controlsRects.scrollCornerOrResizerRect();
        GraphicsContextStateSaver stateSaver(context);
        context.translate(-cornerRect.location());
        LayoutRect transformedClip = LayoutRect(clip);
        transformedClip.moveBy(cornerRect.location());

        scrollableArea->paintScrollCorner(LentGraphicsContext { context }, IntPoint(), controlsRects.scrollCorner, snappedIntRect(transformedClip));
        scrollableArea->paintResizer(LentGraphicsContext { context }, IntPoint(), controlsRects.resizer, transformedClip);
    }
#ifndef NDEBUG
    renderer().page().setIsPainting(false);
#endif
#if HAVE(SUPPORT_HDR_DISPLAY)
    context.setMaxEDRHeadroom(std::nullopt);
#endif
}

bool RenderLayerBacking::getCurrentTransform(const GraphicsLayer* graphicsLayer, TransformationMatrix& transform) const
{
    RefPtr transformedLayer = m_contentsContainmentLayer.get() ? m_contentsContainmentLayer.get() : m_graphicsLayer.get();
    if (graphicsLayer != transformedLayer)
        return false;

    if (m_owningLayer.isTransformed()) {
        transform = m_owningLayer.currentTransform(Style::TransformResolver::individualTransformOperations);
        return true;
    }
    return false;
}

bool RenderLayerBacking::isFlushingLayers() const
{
    return static_cast<GraphicsLayerClient&>(compositor()).isFlushingLayers();
}

bool RenderLayerBacking::isTrackingRepaints() const
{
    return static_cast<GraphicsLayerClient&>(compositor()).isTrackingRepaints();
}

bool RenderLayerBacking::shouldDumpPropertyForLayer(const GraphicsLayer* layer, ASCIILiteral propertyName, OptionSet<LayerTreeAsTextOptions> options) const
{
    // For backwards compatibility with WebKit1 and other platforms,
    // skip some properties on the root tile cache.
    if (m_isMainFrameRenderViewLayer && layer == m_graphicsLayer.get() && !(options & LayerTreeAsTextOptions::IncludeRootLayerProperties)) {
        if (propertyName == "drawsContent"_s)
            return false;

        // Background color could be of interest to tests or other dumpers if it's non-white.
        if (propertyName == "backgroundColor"_s && Color::isWhiteColor(layer->backgroundColor()))
            return false;

        // The root tile cache's repaints will show up at the top with FrameView's,
        // so don't dump them twice.
        if (propertyName == "repaintRects"_s)
            return false;
    }

    if (m_owningLayer.isRenderViewLayer() && (layer == m_graphicsLayer.get() || layer == m_contentsContainmentLayer.get())) {
        if (propertyName == "anchorPoint"_s)
            return layer->anchorPoint() != FloatPoint3D { };

        return true;
    }

    if (propertyName == "anchorPoint"_s)
        return layer->anchorPoint() != FloatPoint3D(0.5f, 0.5f, 0);

    return true;
}

void RenderLayerBacking::logFilledVisibleFreshTile(unsigned blankPixelCount)
{
    if (auto* loggingClient = renderer().page().performanceLoggingClient())
        loggingClient->logScrollingEvent(PerformanceLoggingClient::ScrollingEvent::FilledTile, MonotonicTime::now(), blankPixelCount);
}

#ifndef NDEBUG
void RenderLayerBacking::verifyNotPainting()
{
    ASSERT(!renderer().page().isPainting());
}
#endif

bool RenderLayerBacking::addAnimationForSwift(AnimatedProperty property, NOESCAPE BlendingKeyframesView keyframes, FloatSize referenceBoxSize, const GraphicsLayerAnimation& animation, double timeOffset)
{
    GraphicsLayerKeyframeValueList values(property);
    for (auto& currentKeyframe : *keyframes) {
        const Style::ComputedStyle* keyframeStyle = currentKeyframe.style();
        if (!keyframeStyle)
            continue;

        auto zoom = keyframeStyle->usedZoomForLength();

        double offset = currentKeyframe.offset();
        RefPtr timingFunction = currentKeyframe.timingFunction();

        switch (property) {
        case AnimatedProperty::Rotate:
            if (currentKeyframe.animatesProperty(CSSPropertyID::Rotate))
                values.insert(makeUnique<GraphicsLayerTransformAnimationValue>(offset, Style::toPlatform(keyframeStyle->rotate(), referenceBoxSize, zoom).get(), timingFunction));
            break;
        case AnimatedProperty::Scale:
            if (currentKeyframe.animatesProperty(CSSPropertyID::Scale))
                values.insert(makeUnique<GraphicsLayerTransformAnimationValue>(offset, Style::toPlatform(keyframeStyle->scale(), referenceBoxSize, zoom).get(), timingFunction));
            break;
        case AnimatedProperty::Translate:
            if (currentKeyframe.animatesProperty(CSSPropertyID::Translate))
                values.insert(makeUnique<GraphicsLayerTransformAnimationValue>(offset, Style::toPlatform(keyframeStyle->translate(), referenceBoxSize, zoom).get(), timingFunction));
            break;
        case AnimatedProperty::Transform:
            if (currentKeyframe.animatesProperty(CSSPropertyID::Transform))
                values.insert(makeUnique<GraphicsLayerTransformAnimationValue>(offset, Style::toPlatform(keyframeStyle->transform(), referenceBoxSize, zoom), timingFunction));
            break;
        case AnimatedProperty::Opacity:
            if (currentKeyframe.animatesProperty(CSSPropertyID::Opacity))
                values.insert(makeUnique<GraphicsLayerFloatAnimationValue>(offset, Style::evaluate<float>(keyframeStyle->opacity()), timingFunction));
            break;
        case AnimatedProperty::Filter:
            if (currentKeyframe.animatesProperty(CSSPropertyID::Filter))
                values.insert(makeUnique<GraphicsLayerFilterAnimationValue>(offset, Style::toPlatform(keyframeStyle->filter(), renderer().style()), timingFunction));
            break;
        case AnimatedProperty::WebkitBackdropFilter:
            if (currentKeyframe.animatesProperty(CSSPropertyID::WebkitBackdropFilter) || currentKeyframe.animatesProperty(CSSPropertyID::BackdropFilter))
                values.insert(makeUnique<GraphicsLayerFilterAnimationValue>(offset, Style::toPlatform(keyframeStyle->backdropFilter(), renderer().style()), timingFunction));
            break;
        default:
            ASSERT_NOT_REACHED();
            break;
        }
    }
    return m_graphicsLayer->addAnimation(values, &animation, (*keyframes).acceleratedAnimationName(), timeOffset);
}

#if ENABLE(THREADED_ANIMATIONS)
const AcceleratedEffectStack* RenderLayerBacking::acceleratedEffectStack() const
{
    return m_graphicsLayer->acceleratedEffectStack();
}

void RenderLayerBacking::updateAcceleratedEffectsAndBaseValues(HashSet<Ref<AcceleratedTimeline>>& timelines)
{
    auto& renderer = this->renderer();
    OptionSet<AcceleratedEffectProperty> disallowedAcceleratedProperties;

    auto rendererAllowsTransform = renderer.isRenderBox() || renderer.isSVGLayerAwareRenderer();
    if (!rendererAllowsTransform)
        disallowedAcceleratedProperties.add(transformRelatedAcceleratedProperties);

    auto target = Styleable::fromRenderer(renderer);
    ASSERT(target);

    bool hasEffectAffectingFilter = false;
    bool hasEffectAffectingBackdropFilter = false;
    auto borderBoxRect = snappedIntRect(m_owningLayer.rendererBorderBoxRect());

    auto* style = target->lastStyleChangeEventStyle();
    auto baseValues = [&]() -> AcceleratedEffectValues {
        if (style)
            return { *style, borderBoxRect, &renderer };
        return { };
    }();

    // We keep property sets to track all properties we've encountered as well as
    // those we know will interpolate (ie. the animation is in the "running" state).
    // We will use these to determine if there are non-interpolating animations
    // that we can disregard.
    OptionSet<AcceleratedEffectProperty> allAcceleratedProperties;
    OptionSet<AcceleratedEffectProperty> interpolatingProperties;

    // We keep another property set to track proeprties for which we have found an
    // interpolating effect that fully replaces any previous effect or base value.
    // The purpose of this property set is to not add any effect, running or otherwise,
    // that is fully replaced by effects higher up the effect stack, ensuring a minimal
    // amount of accelerated effects.
    OptionSet<AcceleratedEffectProperty> replacedAcceleratedProperties;

    AcceleratedEffects acceleratedEffects;
    Vector<std::pair<Ref<AcceleratedEffect>, Ref<KeyframeEffect>>> filterEffects;
    HashSet<Ref<AcceleratedTimeline>> effectTimelines;
    if (auto* effectStack = target->keyframeEffectStack()) {
        if (effectStack->allowsAcceleration()) {
            auto animatesWidth = effectStack->containsProperty(CSSPropertyID::Width);
            auto animatesHeight = effectStack->containsProperty(CSSPropertyID::Height);
            auto animatesOffsetPath = effectStack->containsProperty(CSSPropertyID::OffsetPath);

            // If offset-distance is a percentage or is calculated, we won't have the necessary
            // information in the remote layer tree to recompute it based on an animated offset-path.
            if (animatesOffsetPath && style->offsetDistance().isPercentOrCalculated())
                disallowedAcceleratedProperties.add(transformRelatedAcceleratedProperties);

            for (const auto& effect : effectStack->sortedEffects() | std::views::reverse) {
                if (!effect || !effect->canHaveAcceleratedRepresentation() || !effect->canBeAccelerated())
                    continue;
                if (!disallowedAcceleratedProperties.containsAll(transformRelatedAcceleratedProperties)) {
                    if (animatesWidth || animatesHeight) {
                        auto& blendingKeyframes = effect->blendingKeyframes();
                        if ((animatesWidth && blendingKeyframes.hasWidthDependentTransform()) || (animatesHeight && blendingKeyframes.hasHeightDependentTransform()))
                            disallowedAcceleratedProperties.add(transformRelatedAcceleratedProperties);
                    }
                    if (animatesOffsetPath) {
                        auto& blendingKeyframes = effect->blendingKeyframes();
                        if (blendingKeyframes.animatesOffsetDistanceToPercentOrCalculated())
                            disallowedAcceleratedProperties.add(transformRelatedAcceleratedProperties);
                    }
                }
                Ref acceleratedEffect = effect->acceleratedRepresentation(borderBoxRect, baseValues, disallowedAcceleratedProperties);
                // FIXME: it feels like we should be able to assert here, or perhaps we could just fold this into the logic
                // to determine whether we have an interpolating effect.
                auto& acceleratedProperties = acceleratedEffect->animatedProperties();
                if (acceleratedProperties.isEmpty())
                    continue;
                // This effect is fully replaced by effects higher up the stack.
                if (replacedAcceleratedProperties.containsAll(acceleratedProperties))
                    continue;
                // Keep track of properties replaced by this effect.
                replacedAcceleratedProperties.add(acceleratedEffect->replacedProperties());
                // Keep track of this effect's properties in the list of all known properties.
                allAcceleratedProperties.add(acceleratedProperties);
                if (effect->isRunningAccelerated())
                    interpolatingProperties.add(acceleratedProperties);
                // We can only handle one effect in the stack targeting the filter and backdrop-filter properties
                // because of the complexities involved with possibly blending across multiple filter types. Since
                // this is bound to be rare, it's a lot easier to simply disallow acceleration in this case.
                if (acceleratedProperties.contains(AcceleratedEffectProperty::Filter)) {
                    if (hasEffectAffectingFilter)
                        disallowedAcceleratedProperties.add(AcceleratedEffectProperty::Filter);
                    hasEffectAffectingFilter = true;
                }
                if (acceleratedProperties.contains(AcceleratedEffectProperty::BackdropFilter)) {
                    if (hasEffectAffectingBackdropFilter)
                        disallowedAcceleratedProperties.add(AcceleratedEffectProperty::BackdropFilter);
                    hasEffectAffectingBackdropFilter = true;
                }
                if (acceleratedProperties.contains(AcceleratedEffectProperty::Filter))
                    filterEffects.append(std::pair { acceleratedEffect, Ref { *effect } });
                effectTimelines.add(Ref { *acceleratedEffect->timeline() });
                acceleratedEffects.append(WTF::move(acceleratedEffect));
            }
        }
    }

    // Effects were added in reverse, so we need to reverse the accelerated effects.
    acceleratedEffects.reverse();

    // Now let's prune any effect that only animates a non-interpolating property.
    auto nonInterpolatingProperties = allAcceleratedProperties ^ interpolatingProperties ^ disallowedAcceleratedProperties;
    if (!nonInterpolatingProperties.isEmpty()) {
        // Remove effects that are only animating non-interpolating properties and
        // re-populate the set of timelines from the remaining effects.
        acceleratedEffects.removeAllMatching([&](auto& acceleratedEffect) {
            return nonInterpolatingProperties.containsAll(acceleratedEffect->animatedProperties());
        });
        effectTimelines.clear();
        for (auto& acceleratedEffect : acceleratedEffects)
            effectTimelines.add(Ref { *acceleratedEffect->timeline() });
    }

    // If all of the effects in the stack are either idle, paused or filling, then the
    // effect stack will not produce an interpolated value and we don't need to run
    // any of these effects. Otherwise, add the timelines we've encountered for the
    // effects to the general timelines list.
    if (interpolatingProperties.isEmpty()) {
        acceleratedEffects.clear();
        baseValues = { };
    } else
        timelines.addAll(effectTimelines);

    // If a filter property was disallowed, it's because it cannot be represented remotely,
    // so we must ensure we reset it in the base values so that we don't attempt to encode
    // an unsupported filter operation.
    if (!hasEffectAffectingFilter || disallowedAcceleratedProperties.contains(AcceleratedEffectProperty::Filter)) {
        for (auto& effect : acceleratedEffects)
            effect->clearProperty(AcceleratedEffectProperty::Filter);
        baseValues.filter = { };
    }
    if (!hasEffectAffectingBackdropFilter || disallowedAcceleratedProperties.contains(AcceleratedEffectProperty::BackdropFilter)) {
        for (auto& effect : acceleratedEffects)
            effect->clearProperty(AcceleratedEffectProperty::BackdropFilter);
        baseValues.backdropFilter = { };
    }

    // Accelerated effects remain in the remote layer tree as long as they are interpolating. Once their
    // associated animation reaches its natural end, their target's accelerated effect stack will be update
    // and a new remote layer tree transaction will be committed to remove that accelerated effect. However,
    // in the case where that effect does not fill forwards, there could be a moment between the moment it
    // finished naturally in the remote layer tree and the moment it is indeed removed where the associated
    // layer is in an unwanted state for a frame (or more if the Web process is under heavy load). As such,
    // we must make such effects forward-filling. It is important however not to do so for effects that will
    // be used as input for other effects further up the stack.
    OptionSet<AcceleratedEffectProperty> composedAcceleratedProperties;
    for (auto& effect : acceleratedEffects | std::views::reverse) {
        // Nothing to do if the effect is not associated with a monotonic timeline.
        if (!effect->timeline()->isMonotonic())
            continue;
        // Nothing to do if the effect is forward-filling already.
        const auto& fill = effect->timing().fill;
        if (fill == FillMode::Forwards || fill == FillMode::Both)
            continue;
        // We only want to force the effect to be forward-filling if none of its
        // animated properties affect other effects up the stack.
        auto shouldBecomeForwardsFilling = !composedAcceleratedProperties.containsAny(effect->animatedProperties());
        composedAcceleratedProperties.add(effect->composedProperties());
        if (shouldBecomeForwardsFilling)
            effect->makeForwardsFilling();
    }

    IntOutsets filterAnimationOutsetsFromAcceleratedEffects;
    for (auto& [acceleratedEffect, effect] : filterEffects) {
        if (!acceleratedEffect->animatedProperties().contains(AcceleratedEffectProperty::Filter))
            continue;
        if (acceleratedEffects.containsIf([&](auto& remainingEffect) { return remainingEffect.ptr() == acceleratedEffect.ptr(); }))
            filterAnimationOutsetsFromAcceleratedEffects = max(filterAnimationOutsetsFromAcceleratedEffects, effect->computeExtentOfFilterAnimation());
    }

    m_graphicsLayer->setAcceleratedEffectsAndBaseValues(WTF::move(acceleratedEffects), WTF::move(baseValues));

    m_filterAnimationOutsetsFromAcceleratedEffects = filterAnimationOutsetsFromAcceleratedEffects;
    updateFilterAnimationOutsets();

    if (!renderer.view().needsLayout() && !m_owningLayer.normalFlowListDirty() && !m_owningLayer.zOrderListsDirty())
        updateAnimationExtent();

    m_owningLayer.setNeedsPostLayoutCompositingUpdate();
    m_owningLayer.setNeedsCompositingGeometryUpdate();
}
#endif

void RenderLayerBacking::notifyAnimationStarted(const GraphicsLayer*, const String&, MonotonicTime)
{
}

TextStream& operator<<(TextStream& ts, const RenderLayerBacking& backing)
{
    ts << "RenderLayerBacking "_s << &backing << " bounds "_s << backing.compositedBounds();

    if (backing.isFrameLayerWithTiledBacking())
        ts << " frame layer tiled backing"_s;
    if (backing.paintsIntoWindow())
        ts << " paintsIntoWindow"_s;
    if (backing.paintsIntoCompositedAncestor())
        ts << " paintsIntoCompositedAncestor"_s;

    ts << " primary layer ID "_s << (backing.graphicsLayer()->primaryLayerID() ? backing.graphicsLayer()->primaryLayerID()->object().toUInt64() : 0);
    if (auto nodeID = backing.scrollingNodeIDForRole(ScrollCoordinationRole::ViewportConstrained))
        ts << " viewport constrained scrolling node "_s << nodeID;
    if (auto nodeID = backing.scrollingNodeIDForRole(ScrollCoordinationRole::Scrolling))
        ts << " scrolling node "_s << nodeID;

    if (backing.ancestorClippingStack())
        ts << " ancestor clip stack "_s << *backing.ancestorClippingStack();

    if (auto nodeID = backing.scrollingNodeIDForRole(ScrollCoordinationRole::FrameHosting))
        ts << " frame hosting node "_s << nodeID;
    if (auto nodeID = backing.scrollingNodeIDForRole(ScrollCoordinationRole::PluginHosting))
        ts << " plugin hosting node "_s << nodeID;
    if (auto nodeID = backing.scrollingNodeIDForRole(ScrollCoordinationRole::Positioning))
        ts << " positioning node "_s << nodeID;
    return ts;
}

void RenderLayerBacking::dumpProperties(const GraphicsLayer* layer, TextStream& ts, OptionSet<LayerTreeAsTextOptions> options) const
{
    if (!is<RenderWidget>(renderer()))
        return;

    // If this is the leaf layer for a RemoteFrame, then collect layers from the frame's process.
    if (RefPtr remoteFrame = downcast<RenderWidget>(renderer()).remoteFrame(); remoteFrame && layer->children().isEmpty()) {
        ts << indent << "(children 1\n"_s;
        ts << remoteFrame->client().layerTreeAsText(ts.indent() + 1, options);
        ts << indent << ")\n"_s;
    }
}

OptionSet<ContentsFormat> RenderLayerBacking::screenContentsFormats() const
{
#if ENABLE(SPATIAL_PORTAL)
    if (RenderLayerCompositor::promotedSpatialPortalChildForLayer(m_owningLayer))
        return { ContentsFormat::RGBA8 };
#endif

#if PLATFORM(MAC) || PLATFORM(IOS_FAMILY)
    return WebCore::screenContentsFormats(&renderer().view().frameView());
#else
    return { };
#endif
}


} // namespace WebCore
