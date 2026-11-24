/*
 * Copyright (C) 2009-2020 Apple Inc. All rights reserved.
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
#include "RenderLayerCompositor.h"

#include "AsyncScrollingCoordinator.h"
#include "BorderData.h"
#include "BorderShape.h"
#include "CSSPropertyNames.h"
#include "CanvasRenderingContext.h"
#include "Chrome.h"
#include "ChromeClient.h"
#include "ContainerNodeInlines.h"
#include "DocumentFullscreen.h"
#include "FixedContainerEdges.h"
#include "GraphicsLayer.h"
#include "GraphicsLayerFactory.h"
#include "HTMLAnchorElement.h"
#include "HTMLCanvasElement.h"
#include "HTMLIFrameElement.h"
#include "HTMLModelElement.h"
#include "HTMLNames.h"
#include "HitTestResult.h"
#include "InspectorInstrumentation.h"
#include "KeyframeEffectStack.h"
#include "LayerAncestorClippingStack.h"
#include "LocalFrame.h"
#include "LocalFrameView.h"
#include "Logging.h"
#include "NodeList.h"
#include "Page.h"
#include "PageOverlayController.h"
#include "PathOperation.h"
#include "RemoteFrame.h"
#include "RenderBoxInlines.h"
#include "RenderElementInlines.h"
#include "RenderElementStyleInlines.h"
#include "RenderEmbeddedObject.h"
#include "RenderFragmentedFlow.h"
#include "RenderGeometryMap.h"
#include "RenderHTMLCanvas.h"
#include "RenderIFrame.h"
#include "RenderImage.h"
#include "RenderLayerBacking.h"
#include "RenderLayerInlines.h"
#include "RenderLayerScrollableArea.h"
#include "RenderObjectInlines.h"
#include "RenderTextControlSingleLine.h"
#include "RenderVideo.h"
#include "RenderView.h"
#include "RenderViewTransitionCapture.h"
#include "RenderWidgetInlines.h"
#include "RotateTransformOperation.h"
#include "SVGGraphicsElement.h"
#include "ScaleTransformOperation.h"
#include "ScrollingConstraints.h"
#include "Settings.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleOffsetRotate.h"
#include "TiledBacking.h"
#include "TransformState.h"
#include "TranslateTransformOperation.h"
#include "ViewTransition.h"
#include <wtf/HexNumber.h>
#include <wtf/InlineWeakPtr.h>
#include <wtf/MemoryPressureHandler.h>
#include <wtf/ObjectIdentifier.h>
#include <wtf/Scope.h>
#include <wtf/SetForScope.h>
#include <wtf/SystemTracing.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/TextStream.h>

#if PLATFORM(IOS_FAMILY)
#include "LegacyTileCache.h"
#include "RenderScrollbar.h"
#endif

#if PLATFORM(MAC)
#include "LocalDefaultSystemAppearance.h"
#endif

#if ENABLE(TREE_DEBUGGING)
#include "RenderTreeAsText.h"
#endif

#if ENABLE(MODEL_ELEMENT)
#include "RenderModel.h"
#endif

#if !PLATFORM(MAC) && !PLATFORM(IOS_FAMILY) && !PLATFORM(GTK) && !PLATFORM(WPE)
#define USE_COMPOSITING_FOR_SMALL_CANVASES 1
#endif

namespace WebCore {

#if PLATFORM(IOS_FAMILY)
WTF_MAKE_TZONE_ALLOCATED_IMPL(LegacyWebKitScrollingLayerCoordinator);
#endif

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderLayerCompositor);

#if !USE(COMPOSITING_FOR_SMALL_CANVASES)
static const int canvasAreaThresholdRequiringCompositing = 50 * 100;
#endif

using namespace HTMLNames;

#if !LOG_DISABLED || ENABLE(TREE_DEBUGGING)
static inline bool compositingLogEnabled()
{
    return LogCompositing.state == WTFLogChannelState::On;
}
#endif

#if ENABLE(TREE_DEBUGGING)
static inline bool layersLogEnabled()
{
    return LogLayers.state == WTFLogChannelState::On;
}
#endif

static constexpr Seconds conservativeCompositingPolicyHysteresisDuration { 2_s };

static constexpr double willChangeBudgetViewportAreaMultiplier = 8;
static constexpr Seconds initialWillChangeBudgetBackoff { 2_s };
static constexpr Seconds maximumWillChangeBudgetBackoff { 32_s };

RenderLayerCompositor::RenderLayerCompositor(RenderView& renderView)
    : m_renderView(renderView)
    , m_updateCompositingLayersTimer(*this, &RenderLayerCompositor::updateCompositingLayersTimerFired)
    , m_updateRenderingTimer(*this, &RenderLayerCompositor::scheduleRenderingUpdate)
    , m_compositingPolicy { CompositingPolicy::Normal }
    , m_compositingPolicyHysteresis([](PAL::HysteresisState) { }, conservativeCompositingPolicyHysteresisDuration)
    , m_willChangeBudgetBackoffDuration(initialWillChangeBudgetBackoff)
{
#if PLATFORM(IOS_FAMILY)
    if (m_renderView->frameView().platformWidget())
        lazyInitialize(m_legacyScrollingLayerCoordinator, makeUnique<LegacyWebKitScrollingLayerCoordinator>(page().chrome().client(), isRootFrameCompositor()));
#endif
}

RenderLayerCompositor::~RenderLayerCompositor()
{
    // Take care that the owned GraphicsLayers are deleted first as their destructors may call back here.
    GraphicsLayer::unparentAndClear(m_rootContentsLayer);
    
    GraphicsLayer::unparentAndClear(m_clipLayer);
    GraphicsLayer::unparentAndClear(m_scrollContainerLayer);
    GraphicsLayer::unparentAndClear(m_scrolledContentsLayer);

    GraphicsLayer::unparentAndClear(m_overflowControlsHostLayer);

    GraphicsLayer::unparentAndClear(m_layerForHorizontalScrollbar);
    GraphicsLayer::unparentAndClear(m_layerForVerticalScrollbar);
    GraphicsLayer::unparentAndClear(m_layerForScrollCorner);

#if HAVE(RUBBER_BANDING)
    GraphicsLayer::unparentAndClear(m_layerForOverhangAreas);
    GraphicsLayer::unparentAndClear(m_contentShadowLayer);
    GraphicsLayer::unparentAndClear(m_layerForTopOverhangColorExtension);
    GraphicsLayer::unparentAndClear(m_layerForTopOverhangImage);
    GraphicsLayer::unparentAndClear(m_layerForBottomOverhangArea);
    GraphicsLayer::unparentAndClear(m_layerForHeader);
    GraphicsLayer::unparentAndClear(m_layerForFooter);
#endif

    ASSERT(m_rootLayerAttachment == RootLayerUnattached);
}

ChromeClient::CompositingTriggerFlags RenderLayerCompositor::allowedCompositingTriggers() const
{
    return page().chrome().client().allowedCompositingTriggers();
}

bool RenderLayerCompositor::useDynamicContentScalingDisplayListsForDOMRendering(const Settings& settings)
{
#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    return settings.useCGDisplayListsForDOMRendering();
#else
    UNUSED_PARAM(settings);
    return false;
#endif
}

bool RenderLayerCompositor::documentHasHDRContent() const
{
#if HAVE(SUPPORT_HDR_DISPLAY)
    return m_renderView->document().hasHDRContent();
#else
    return false;
#endif
}

bool RenderLayerCompositor::updateCompositingPolicy()
{
    if (!usesCompositing())
        return false;

    auto currentPolicy = m_compositingPolicy;
    if (page().compositingPolicyOverride()) {
        m_compositingPolicy = page().compositingPolicyOverride().value();
        return m_compositingPolicy != currentPolicy;
    }

    if (!canUpdateCompositingPolicy())
        return false;

    const auto isCurrentlyUnderMemoryPressureOrWarning = [] {
        return MemoryPressureHandler::singleton().isUnderMemoryPressure() || MemoryPressureHandler::singleton().isUnderMemoryWarning();
    };

    static auto cachedMemoryPolicy = WTF::MemoryUsagePolicy::Unrestricted;
    bool nowUnderMemoryPressure = isCurrentlyUnderMemoryPressureOrWarning();
    static bool cachedIsUnderMemoryPressureOrWarning = nowUnderMemoryPressure;

    if (cachedIsUnderMemoryPressureOrWarning != nowUnderMemoryPressure) {
        cachedMemoryPolicy = MemoryPressureHandler::singleton().currentMemoryUsagePolicy();
        cachedIsUnderMemoryPressureOrWarning = nowUnderMemoryPressure;
    }

    m_compositingPolicy = cachedMemoryPolicy == WTF::MemoryUsagePolicy::Unrestricted ? CompositingPolicy::Normal : CompositingPolicy::Conservative;

    bool didChangePolicy = currentPolicy != m_compositingPolicy;
    if (didChangePolicy && m_compositingPolicy == CompositingPolicy::Conservative)
        m_compositingPolicyHysteresis.impulse();

    return didChangePolicy;
}

bool RenderLayerCompositor::canUpdateCompositingPolicy() const
{
    return m_compositingPolicyHysteresis.state() == PAL::HysteresisState::Stopped;
}

void RenderLayerCompositor::customPositionForVisibleRectComputation(const GraphicsLayer* graphicsLayer, FloatPoint& position) const
{
    if (graphicsLayer != m_scrolledContentsLayer.get())
        return;

    FloatPoint scrollPosition = -position;
    Ref frameView = m_renderView->frameView();

    if (frameView->scrollBehaviorForFixedElements() == ScrollBehaviorForFixedElements::StickToDocumentBounds)
        scrollPosition = frameView->constrainScrollPositionForOverhang(roundedIntPoint(scrollPosition));

    position = -scrollPosition;
}

bool RenderLayerCompositor::shouldDumpPropertyForLayer(const GraphicsLayer* layer, ASCIILiteral propertyName, OptionSet<LayerTreeAsTextOptions>) const
{
    if (propertyName == "anchorPoint"_s)
        return layer->anchorPoint() != FloatPoint3D(0.5f, 0.5f, 0);

    return true;
}

void RenderLayerCompositor::scheduleRenderingUpdate()
{
    ASSERT(!m_flushingLayers);

    protect(page())->scheduleRenderingUpdate(RenderingUpdateStep::LayerFlush);
}

NODELETE static inline ScrollableArea::VisibleContentRectIncludesScrollbars scrollbarInclusionForVisibleRect()
{
#if USE(COORDINATED_GRAPHICS)
    return ScrollableArea::VisibleContentRectIncludesScrollbars::Yes;
#else
    return ScrollableArea::VisibleContentRectIncludesScrollbars::No;
#endif
}

FloatRect RenderLayerCompositor::visibleRectForLayerFlushing() const
{
    const Ref frameView = m_renderView->frameView();
#if PLATFORM(IOS_FAMILY)
    return frameView->exposedContentRect().raw();
#else

    // Having a m_scrolledContentsLayer indicates that we're doing scrolling via GraphicsLayers.
    FloatRect visibleRect;
    if (m_scrolledContentsLayer) {
        // The layers below are in unscaled contents coordinates when the page scale is delegated, and nothing
        // in the tree undoes the zoom on the way down, so unzoom the size here. This is what the iOS path
        // above gets from exposedContentRect(), and is a no-op when scaling isn't delegated.
        auto visibleSize = FloatSize { frameView->sizeForVisibleContent(scrollbarInclusionForVisibleRect()) };
        visibleSize.scale(1 / frameView->visibleContentScaleFactor());
        visibleRect = FloatRect { { }, visibleSize };
    } else
        visibleRect = frameView->visibleContentRect();

    if (auto exposedRect = frameView->viewExposedRect())
        visibleRect.intersect(*exposedRect);

    return visibleRect;
#endif
}

void RenderLayerCompositor::flushPendingLayerChanges(bool isFlushRoot)
{
    // LocalFrameView::flushCompositingStateIncludingSubframes() flushes each subframe,
    // but GraphicsLayer::flushCompositingState() will cross frame boundaries
    // if the GraphicsLayers are connected (the RootLayerAttachedViaEnclosingFrame case).
    // As long as we're not the root of the flush, we can bail.
    if (!isFlushRoot && rootLayerAttachment() == RootLayerAttachedViaEnclosingFrame)
        return;

    if (rootLayerAttachment() == RootLayerUnattached) {
        m_shouldFlushOnReattach = true;
        return;
    }

    ASSERT(!m_flushingLayers);
    {
        SetForScope flushingLayersScope(m_flushingLayers, true);

        if (RefPtr rootLayer = rootGraphicsLayer()) {
#if ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)
            LayerTreeHitTestLocker layerLocker(scrollingCoordinator());
#endif
            FloatRect visibleRect = visibleRectForLayerFlushing();
            LOG_WITH_STREAM(Compositing,  stream << "\nRenderLayerCompositor " << this << " flushPendingLayerChanges (is root " << isFlushRoot << ") visible rect " << visibleRect);
            rootLayer->flushCompositingState(visibleRect);
        }
        
        ASSERT(m_flushingLayers);

#if ENABLE(TREE_DEBUGGING)
        if (layersLogEnabled()) {
            LOG(Layers, "RenderLayerCompositor::flushPendingLayerChanges");
            showGraphicsLayerTree(rootGraphicsLayer());
        }
#endif
    }

#if PLATFORM(IOS_FAMILY)
    updateScrollCoordinatedLayersAfterFlushIncludingSubframes();

    if (isFlushRoot)
        page().chrome().client().didFlushCompositingLayers();
#endif

    ++m_layerFlushCount;
}

#if PLATFORM(IOS_FAMILY)
void RenderLayerCompositor::updateScrollCoordinatedLayersAfterFlushIncludingSubframes()
{
    updateScrollCoordinatedLayersAfterFlush();

    for (Ref localFrame : descendantFrames<LocalFrame>(m_renderView->frameView().frame())) {
        auto* view = localFrame->contentRenderer();
        if (!view)
            continue;

        view->compositor().updateScrollCoordinatedLayersAfterFlush();
    }
}

void RenderLayerCompositor::updateScrollCoordinatedLayersAfterFlush()
{
    if (m_legacyScrollingLayerCoordinator) {
        m_legacyScrollingLayerCoordinator->registerAllViewportConstrainedLayers(*this);
        m_legacyScrollingLayerCoordinator->registerAllScrollingLayers();
    }
}
#endif

void RenderLayerCompositor::didChangePlatformLayerForLayer(RenderLayer& layer, const GraphicsLayer*)
{
    RefPtr scrollingCoordinator = this->scrollingCoordinator();
    if (!scrollingCoordinator)
        return;

    auto* backing = layer.backing();
    if (auto nodeID = backing->scrollingNodeIDForRole(ScrollCoordinationRole::Scrolling))
        updateScrollingNodeLayers(*nodeID, layer, *scrollingCoordinator);

    if (auto* clippingStack = layer.backing()->ancestorClippingStack())
        clippingStack->updateScrollingNodeLayers(*scrollingCoordinator);

    if (auto nodeID = backing->scrollingNodeIDForRole(ScrollCoordinationRole::ViewportConstrained)) {
        scrollingCoordinator->setNodeLayers(*nodeID, {
            .layer = backing->viewportClippingOrAnchorLayer(),
            .viewportAnchorLayer = backing->viewportAnchorLayer()
        });
    }

    if (auto nodeID = backing->scrollingNodeIDForRole(ScrollCoordinationRole::FrameHosting))
        scrollingCoordinator->setNodeLayers(*nodeID, { backing->graphicsLayer() });

    if (auto nodeID = backing->scrollingNodeIDForRole(ScrollCoordinationRole::Positioning))
        scrollingCoordinator->setNodeLayers(*nodeID, { backing->graphicsLayer() });
}

#if ENABLE(THREADED_ANIMATIONS)
std::optional<MonotonicTime> RenderLayerCompositor::renderingUpdateTimestamp() const
{
    if (auto timestamp = page().lastRenderingUpdateTimestamp())
        return timestamp;
    return std::nullopt;
}
#endif

void RenderLayerCompositor::notifySubsequentFlushRequired(const GraphicsLayer*)
{
    if (!m_updateRenderingTimer.isActive())
        m_updateRenderingTimer.startOneShot(0_s);
}

void RenderLayerCompositor::layerTiledBackingUsageChanged(const GraphicsLayer* graphicsLayer, bool usingTiledBacking)
{
    if (usingTiledBacking) {
        ++m_layersWithTiledBackingCount;
        graphicsLayer->tiledBacking()->setIsInWindow(page().isInWindow());
    } else {
        ASSERT(m_layersWithTiledBackingCount > 0);
        --m_layersWithTiledBackingCount;
    }
}

void RenderLayerCompositor::scheduleCompositingLayerUpdate()
{
    if (!m_updateCompositingLayersTimer.isActive())
        m_updateCompositingLayersTimer.startOneShot(0_s);
}

void RenderLayerCompositor::cancelCompositingLayerUpdate()
{
    m_updateCompositingLayersTimer.stop();
}

// Returns true on a successful update.
bool RenderLayerCompositor::updateCompositingLayers(CompositingUpdateType updateType, RenderLayer* updateRootArg)
{
    LOG_WITH_STREAM(Compositing, stream << "RenderLayerCompositor " << this << " [" << m_renderView->frameView() << "] updateCompositingLayers " << updateType << " contentLayersCount " << m_contentLayersCount);

    TraceScope tracingScope(CompositingUpdateStart, CompositingUpdateEnd);
    LayerFreeForbiddenScope layerFreeForbiddenScope;

    updateLayerPositionsForTreeDebugging(rootRenderLayer());

    ASSERT(m_renderView->document().backForwardCacheState() == Document::NotInBackForwardCache
        || m_renderView->document().backForwardCacheState() == Document::AboutToEnterBackForwardCache);

    return updateCompositingLayersInScope(updateType, updateRootArg);
}

int RenderLayerCompositor::pageOverlayCount() const
{
    return page().pageOverlayController().overlayCount();
}

void RenderLayerCompositor::setViewportConstrainedLayersNeedCompositingGeometryUpdate()
{
    if (auto* viewportConstrainedObjects = m_renderView->frameView().viewportConstrainedObjects()) {
        for (auto& renderer : *viewportConstrainedObjects) {
            if (auto* layer = renderer.layer())
                layer->setNeedsCompositingGeometryUpdate();
        }
    }
}

void RenderLayerCompositor::computeCompositingRequirementsInGeometryMap(RenderLayer& rootLayer, RenderLayer& updateRoot)
{
    LayerFreeForbiddenScope layerFreeForbiddenScope;
    RenderGeometryMap geometryMap(MapCoordinatesMode::UseTransforms);
    computeCompositingRequirements(rootLayer, updateRoot, geometryMap);
}

void RenderLayerCompositor::updateLayerPositionsForTreeDebugging(RenderLayer& layer)
{
#if ENABLE(TREE_DEBUGGING)
    if (compositingLogEnabled())
        showPaintOrderTree(m_renderView->layer());
    layer.updateLayerPositionsAfterLayout(false, false);
#else
    UNUSED_PARAM(layer);
#endif
}

void RenderLayerCompositor::layerTreeDidChange()
{
    InspectorInstrumentation::layerTreeDidChange(protect(m_renderView->frame()));
}

GraphicsLayer* RenderLayerCompositor::viewTransitionNewContentLayer(RenderLayer& layer)
{
    if (layer.renderer().style().pseudoElementType() != PseudoElementType::ViewTransitionNew || !layer.hasVisibleContent())
        return nullptr;

    if (!downcast<RenderViewTransitionCapture>(layer.renderer()).canUseExistingLayers())
        return nullptr;

    RefPtr activeViewTransition = layer.renderer().document().activeViewTransition();
    if (!activeViewTransition)
        return nullptr;

    auto* capturedElement = activeViewTransition->namedElements().find(layer.renderer().style().pseudoElementNameArgument());
    if (!capturedElement)
        return nullptr;

    auto newStyleable = capturedElement->newElement.styleable();
    if (!newStyleable)
        return nullptr;

    CheckedPtr capturedRenderer = newStyleable->renderer();
    if (!capturedRenderer || !capturedRenderer->hasLayer())
        return nullptr;

    if (capturedRenderer->isDocumentElementRenderer()) {
        ASSERT(protect(capturedRenderer->document())->activeViewTransitionCapturedDocumentElement());
        capturedRenderer = &capturedRenderer->view();
        ASSERT(capturedRenderer->hasLayer());
    }

    auto& modelObject = downcast<RenderLayerModelObject>(*capturedRenderer);
    if (RenderLayerBacking* backing = modelObject.layer()->backing())
        return backing->childForSuperlayersExcludingViewTransitions();
    return nullptr;
}

bool RenderLayerCompositor::documentHasActiveViewTransitionCapturedDocumentElement(const RenderObject& renderer)
{
    return protect(renderer.document())->activeViewTransitionCapturedDocumentElement();
}

bool RenderLayerCompositor::isSpatialPortalForSwift(const RenderObject& renderer)
{
#if ENABLE(SPATIAL_PORTAL)
    return isSpatialPortal(renderer);
#else
    UNUSED_PARAM(renderer);
    return false;
#endif
}

GraphicsLayer* RenderLayerCompositor::documentOverlayHostLayer()
{
    if (!isRootFrameCompositor() || !m_compositing)
        return nullptr;

    if (!page().pageOverlayController().hasDocumentOverlays())
        return nullptr;

    // Host the document-overlay root scoped to THIS root frame; under Site Isolation several local
    // roots can share a process and each needs its own container (a GraphicsLayer has one parent).
    return &page().pageOverlayController().layerWithDocumentOverlaysForFrame(&m_renderView->frameView().frame());
}

void RenderLayerCompositor::layerBecameNonComposited(const RenderLayer& layer)
{
    // Inform the inspector that the given RenderLayer was destroyed.
    // FIXME: "destroyed" is a misnomer.
    InspectorInstrumentation::renderLayerDestroyed(protect(m_renderView->frame()), layer);

    if (&layer != m_renderView->layer()) {
        ASSERT(m_contentLayersCount > 0);
        --m_contentLayersCount;
    }
}

bool RenderLayerCompositor::clippingChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.overflowX() != newStyle.overflowX()
        || oldStyle.overflowY() != newStyle.overflowY()
        || oldStyle.clip() != newStyle.clip();
}

bool RenderLayerCompositor::styleAffectsLayerGeometry(const Style::ComputedStyle& style)
{
    return !style.clip().isAuto()
        || !style.clipPath().isNone()
        || style.border().hasBorderRadius();
}

bool RenderLayerCompositor::filterOutsetsChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    if (oldStyle.filter() == newStyle.filter())
        return false;

    return oldStyle.filter().calculateOutsets(oldStyle.usedZoomForLength()) != newStyle.filter().calculateOutsets(newStyle.usedZoomForLength());
}

bool RenderLayerCompositor::recompositeChangeRequiresGeometryUpdate(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.transform() != newStyle.transform()
        || oldStyle.translate() != newStyle.translate()
        || oldStyle.scale() != newStyle.scale()
        || oldStyle.rotate() != newStyle.rotate()
        || oldStyle.transformBox() != newStyle.transformBox()
        || oldStyle.transformOriginX() != newStyle.transformOriginX()
        || oldStyle.transformOriginY() != newStyle.transformOriginY()
        || oldStyle.transformOriginZ() != newStyle.transformOriginZ()
        || oldStyle.usedTransformStyle3D() != newStyle.usedTransformStyle3D()
        || oldStyle.perspective() != newStyle.perspective()
        || oldStyle.perspectiveOrigin() != newStyle.perspectiveOrigin()
        || oldStyle.backfaceVisibility() != newStyle.backfaceVisibility()
        || oldStyle.offsetPath() != newStyle.offsetPath()
        || oldStyle.offsetAnchor() != newStyle.offsetAnchor()
        || oldStyle.offsetPosition() != newStyle.offsetPosition()
        || oldStyle.offsetDistance() != newStyle.offsetDistance()
        || oldStyle.offsetRotate() != newStyle.offsetRotate()
        || oldStyle.clipPath() != newStyle.clipPath()
        || oldStyle.overscrollBehaviorX() != newStyle.overscrollBehaviorX()
        || oldStyle.overscrollBehaviorY() != newStyle.overscrollBehaviorY();
}

bool RenderLayerCompositor::recompositeChangeRequiresChildrenGeometryUpdate(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.perspective().isNone() != newStyle.perspective().isNone()
        || oldStyle.usedTransformStyle3D() != newStyle.usedTransformStyle3D();
}

bool RenderLayerCompositor::styleChangeAffectsAnchorLayer(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.hasViewportConstrainedPosition() != newStyle.hasViewportConstrainedPosition();
}

bool RenderLayerCompositor::borderChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.border() != newStyle.border();
}

bool RenderLayerCompositor::imageRenderingChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.imageRendering() != newStyle.imageRendering();
}

bool RenderLayerCompositor::appleColorFilterOverrideChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    return oldStyle.appleColorFilterOverride() != newStyle.appleColorFilterOverride();
#else
    UNUSED_PARAM(oldStyle);
    UNUSED_PARAM(newStyle);
    return false;
#endif
}

bool RenderLayerCompositor::usedPointerEventsChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.usedPointerEvents() != newStyle.usedPointerEvents();
}

bool RenderLayerCompositor::opacityChangedToOrFromTransparent(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    return oldStyle.opacity() != newStyle.opacity() && (oldStyle.opacity().isTransparent() || newStyle.opacity().isTransparent());
}

bool RenderLayerCompositor::styleChangeAffectsSeparatedProperties(const RenderLayerModelObject& renderer)
{
#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    auto& newStyle = renderer.style();
    if (!renderer.hasOldStyle())
        return newStyle.usedTransformStyle3D() == TransformStyle3D::Separated;

    auto& oldStyle = renderer[RenderLayerModelObjectOldStyleTag::OldStyle];
    return oldStyle.usedTransformStyle3D() != newStyle.usedTransformStyle3D()
        && (oldStyle.usedTransformStyle3D() == TransformStyle3D::Separated
            || newStyle.usedTransformStyle3D() == TransformStyle3D::Separated);
#else
    UNUSED_PARAM(renderer);
    return false;
#endif
}

void RenderLayerCompositor::establishesTopLayerWillChangeForLayer(RenderLayer& layer)
{
    clearBackingProviderSequencesInStackingContextOfLayer(layer);
}

void RenderLayerCompositor::createBacking(RenderLayer& layer)
{
    layer.ensureBacking();

    if (layer.isRenderViewLayer() && useCoordinatedScrollingForLayer(layer)) {
        Ref frameView = m_renderView->frameView();
        if (RefPtr scrollingCoordinator = this->scrollingCoordinator())
            scrollingCoordinator->frameViewRootLayerDidChange(frameView);
#if HAVE(RUBBER_BANDING)
        updateLayerForHeader(frameView->headerHeight());
        updateLayerForFooter(frameView->footerHeight());
#endif
        updateRootContentLayerClipping();

        if (auto* tiledBacking = layer.backing()->tiledBacking())
            tiledBacking->setObscuredContentInsets(frameView->obscuredContentInsets());
    }
}

void RenderLayerCompositor::clearReplicaLayerOfReflectionSource(RenderLayer& layer)
{
    auto* parent = layer.renderer().parent();
    RELEASE_ASSERT(parent);
    auto* sourceLayer = downcast<RenderLayerModelObject>(*parent).layer();
    RELEASE_ASSERT(sourceLayer);
    if (auto* backing = sourceLayer->backing()) {
        ASSERT(backing->graphicsLayer()->replicaLayer() == layer.backing()->graphicsLayer());
        RefPtr { backing->graphicsLayer() }->setReplicatedByLayer(nullptr);
    }
}

void RenderLayerCompositor::rendererCompositingBackingChanged(RenderLayer& layer)
{
#if ENABLE(VIDEO)
    if (CheckedPtr renderVideo = dynamicDowncast<RenderVideo>(layer.renderer())) {
        // If it's a video, give the media player a chance to hook up to the layer.
        renderVideo->acceleratedRenderingStateChanged();
    }
#endif

    if (RefPtr renderWidget = dynamicDowncast<RenderWidget>(layer.renderer())) {
        auto* innerCompositor = frameContentsCompositor(*renderWidget);
        if (innerCompositor && innerCompositor->usesCompositing())
            innerCompositor->updateRootLayerAttachment();
    }
}

RenderLayer* RenderLayerCompositor::enclosingNonStackingClippingLayer(const RenderLayer& layer) const
{
    for (auto* parent = layer.parent(); parent; parent = parent->parent()) {
        if (parent->isStackingContext())
            return nullptr;
        if (parent->renderer().hasClipOrNonVisibleOverflow())
            return parent;
    }
    return nullptr;
}

LayoutRect RenderLayerCompositor::overlapExtentForPositionedRenderer(const RenderLayer& layer, LayoutRect bounds) const
{
    auto& renderer = layer.renderer();
    if (renderer.isStickilyPositioned()) {
        // Use rectangle that represents union of all possible sticky element positions,
        // because it could be moved around without re-computing overlap.
        auto scrollInflated = m_renderView->frameView().fixedScrollableAreaBoundsInflatedForScrolling(bounds);
        auto& box = downcast<RenderBoxModelObject>(renderer);
        StickyPositionViewportConstraints constraints;
        auto constrainingRect = box.constrainingRectForStickyPosition();
        box.computeStickyPositionConstraints(constraints, constrainingRect);
        auto stickyBounds = LayoutRect(constraints.computeStickyExtent());
        // bounds includes the current sticky offset, but the sticky extent is relative to the box without that offset,
        // so remove the offset when positioning the sticky extent.
        auto stickyOffset = LayoutSize(constraints.computeStickyOffset(constrainingRect));
        stickyBounds.move(bounds.x() - stickyOffset.width() - LayoutUnit(constraints.stickyBoxRect().x()),
            bounds.y() - stickyOffset.height() - LayoutUnit(constraints.stickyBoxRect().y()));
        scrollInflated.intersect(stickyBounds);
        return scrollInflated;
    }
    if (renderer.isFixedPositioned() && renderer.container() == m_renderView.ptr()) {
        // Because fixed elements get moved around without re-computing overlap, we have to compute an overlap
        // rect that covers all the locations that the fixed element could move to.
        return m_renderView->frameView().fixedScrollableAreaBoundsInflatedForScrolling(bounds);
    }
    return bounds;
}

#if ENABLE(VIDEO)
bool RenderLayerCompositor::canAccelerateVideoRendering(RenderVideo& video) const
{
    if (!m_hasAcceleratedCompositing)
        return false;

    return video.supportsAcceleratedRendering();
}
#endif

void RenderLayerCompositor::widgetDidChangeSize(RenderWidget& widget)
{
    if (!widget.hasLayer())
        return;

    auto& layer = *widget.layer();

    LOG_WITH_STREAM(Compositing, stream << "RenderLayerCompositor " << this << " widgetDidChangeSize (layer " << &layer << ")");

    // Widget size affects answer to requiresCompositingForFrame() so we need to trigger
    // a compositing update.
    layer.setNeedsPostLayoutCompositingUpdate();
    scheduleCompositingLayerUpdate();

    if (layer.isComposited())
        layer.backing()->updateAfterWidgetResize();
}

void RenderLayerCompositor::updateScrollLayerClipping()
{
    RefPtr layerForClipping = this->layerForClipping();
    if (!layerForClipping)
        return;

    Ref frameView = m_renderView->frameView();

    auto layerRect = insetClipLayerRect();
    layerForClipping->setSize(layerRect.size());
    layerForClipping->setPosition(layerRect.location());

#if ENABLE(SCROLLING_THREAD)
    if (layerForClipping == m_clipLayer) {
        EventRegion eventRegion;
        auto eventRegionContext = eventRegion.makeContext();
        eventRegionContext->unite(FloatRoundedRect(FloatRect({ }, layerRect.size())), m_renderView, Style::ComputedStyle::defaultStyleSingleton());
#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
        eventRegionContext->copyInteractionRegionsToEventRegion(m_renderView->settings().interactionRegionMinimumCornerRadius());
#endif
        RefPtr { m_clipLayer }->setEventRegion(WTF::move(eventRegion));
    }
#endif
}

FloatRect RenderLayerCompositor::insetClipLayerRect() const
{
    Ref frameView = m_renderView->frameView();

    auto insetClipLayerRect = LocalFrameView::insetClipLayerRect(frameView->scrollPosition(), frameView->totalContentsSize(), frameView->obscuredContentInsets(), frameView->sizeForVisibleContent());
    insetClipLayerRect.move(frameView->insetForLeftScrollbarSpace(), 0);
    return insetClipLayerRect;
}

void RenderLayerCompositor::updateCompositingForLayerTreeAsTextDump()
{
    Ref frameView = m_renderView->frameView();

    frameView->updateLayoutAndStyleIfNeededRecursive(LayoutOptions::UpdateCompositingLayers);

    updateEventRegions();

    for (RefPtr child = frameView->frame().tree().firstRenderedChild(); child; child = child->tree().traverseNextRendered()) {
        RefPtr localChild = dynamicDowncast<LocalFrame>(child);
        if (!localChild)
            continue;
        if (auto* renderer = localChild->contentRenderer())
            renderer->compositor().updateEventRegions();
    }

    updateCompositingLayers(CompositingUpdateType::AfterLayout);

    if (!m_rootContentsLayer)
        return;

    flushPendingLayerChanges(true);
    // We need to trigger an update because the flushPendingLayerChanges() will have pushed changes to platform layers,
    // which may cause painting to happen in the current runloop.
    protect(page())->triggerRenderingUpdateForTesting();
}

String RenderLayerCompositor::layerTreeAsText(OptionSet<LayerTreeAsTextOptions> options, uint32_t baseIndent)
{
    LOG_WITH_STREAM(Compositing, stream << "RenderLayerCompositor " << this << " layerTreeAsText");

    updateCompositingForLayerTreeAsTextDump();

    // Exclude any implicitly created layers that wrap the root contents layer, unless the caller explicitly requested the true root to be included.
    RefPtr dumpRootLayer = (options & LayerTreeAsTextOptions::IncludeRootLayers) ? RefPtr { rootGraphicsLayer() } : m_rootContentsLayer;

    if (!dumpRootLayer)
        return String();

    // We skip dumping the scroll and clip layers to keep layerTreeAsText output
    // similar between platforms.
    String layerTreeText = dumpRootLayer->layerTreeAsText(options, baseIndent);

    // Dump an empty layer tree only if the only composited layer is the main frame's tiled backing,
    // so that tests expecting us to drop out of accelerated compositing when there are no layers succeed.
    if (!hasContentCompositingLayers() && documentUsesTiledBacking() && !(options & LayerTreeAsTextOptions::IncludeTileCaches) && !(options & LayerTreeAsTextOptions::IncludeRootLayerProperties))
        layerTreeText = emptyString();

    // The true root layer is not included in the dump, so if we want to report
    // its repaint rects, they must be included here.
    if (options & LayerTreeAsTextOptions::IncludeRepaintRects)
        return makeString(m_renderView->frameView().trackedRepaintRectsAsText(), layerTreeText);

    return layerTreeText;
}

std::optional<String> RenderLayerCompositor::platformLayerTreeAsText(Element& element, OptionSet<PlatformLayerTreeAsTextFlags> flags)
{
    LOG_WITH_STREAM(Compositing, stream << "RenderLayerCompositor " << this << " platformLayerTreeAsText");

    updateCompositingForLayerTreeAsTextDump();
    if (!element.renderer() || !element.renderer()->hasLayer())
        return std::nullopt;

    auto& layerModelObject = downcast<RenderLayerModelObject>(*element.renderer());
    if (!layerModelObject.layer()->isComposited())
        return std::nullopt;

    auto* backing = layerModelObject.layer()->backing();
    return backing->graphicsLayer()->platformLayerTreeAsText(flags);
}

static RenderView* frameContentsRenderView(RenderWidget& renderer)
{
    if (auto* contentDocument = renderer.frameOwnerElement().contentDocument())
        return contentDocument->renderView();

    return nullptr;
}

RenderLayerCompositor* RenderLayerCompositor::frameContentsCompositor(RenderWidget& renderer)
{
    if (auto* view = frameContentsRenderView(renderer))
        return &view->compositor();

    return nullptr;
}

auto RenderLayerCompositor::attachWidgetContentLayersIfNecessaryForSwift(RenderLayerModelObject& renderer) -> WidgetLayerAttachment
{
    if (auto* renderWidget = dynamicDowncast<RenderWidget>(renderer))
        return attachWidgetContentLayersIfNecessary(*renderWidget);
    return { };
}

auto RenderLayerCompositor::attachWidgetContentLayersIfNecessary(RenderWidget& renderer) -> WidgetLayerAttachment
{
    auto* layer = renderer.layer();
    if (!layer->isComposited())
        return { false, false };

    auto* backing = layer->backing();
    RefPtr hostingLayer = backing->parentForSublayers();

    bool isVisible = renderer.usedStyle().visibility() == UsedVisibility::Visible;

    auto addContentsLayerChildIfNecessary = [&](GraphicsLayer& contentsLayer, bool isVisible) -> bool {
        if (isVisible && hostingLayer->children().size() == 1 && hostingLayer->children()[0].ptr() == &contentsLayer)
            return false;

        if (!isVisible && hostingLayer->children().isEmpty())
            return false;

        hostingLayer->removeAllChildren();
        if (isVisible)
            hostingLayer->addChild(contentsLayer);
        return true;
    };

    WidgetLayerAttachment result;
    if (isCompositedPlugin(renderer)) {
        if (RefPtr contentsLayer = backing->layerForContents()) {
            result.widgetLayersAttachedAsChildren = isVisible;
            result.layerHierarchyChanged = addContentsLayerChildIfNecessary(*contentsLayer, isVisible);
            if (!isLayerForPluginWithScrollCoordinatedContents(*layer))
                return result;

            RefPtr scrollingCoordinator = this->scrollingCoordinator();
            if (!scrollingCoordinator)
                return result;

            auto pluginHostingNodeID = backing->scrollingNodeIDForRole(ScrollCoordinationRole::PluginHosting);
            if (!pluginHostingNodeID)
                return result;

            CheckedPtr renderEmbeddedObject = dynamicDowncast<RenderEmbeddedObject>(renderer);
            renderEmbeddedObject->willAttachScrollingNode();

            if (auto pluginScrollingNodeID = renderEmbeddedObject->scrollingNodeID()) {
                if (isVisible) {
                    scrollingCoordinator->insertNode(m_renderView->frameView().frame().rootFrame().frameID(), ScrollingNodeType::PluginScrolling, *pluginScrollingNodeID, *pluginHostingNodeID, 0);
                    renderEmbeddedObject->didAttachScrollingNode();
                } else
                    scrollingCoordinator->unparentNode(*pluginScrollingNodeID);
            }
            return result;
        }
    }

    auto* innerCompositor = frameContentsCompositor(renderer);
    if (!innerCompositor || !innerCompositor->usesCompositing() || innerCompositor->rootLayerAttachment() != RootLayerAttachedViaEnclosingFrame)
        return result;

    result.widgetLayersAttachedAsChildren = isVisible;
    if (RefPtr iframeRootLayer = innerCompositor->rootGraphicsLayer())
        result.layerHierarchyChanged = addContentsLayerChildIfNecessary(*iframeRootLayer, isVisible);

    if (auto frameHostingNodeID = backing->scrollingNodeIDForRole(ScrollCoordinationRole::FrameHosting)) {
        RefPtr scrollingCoordinator = this->scrollingCoordinator();
        if (!scrollingCoordinator)
            return result;

        auto* contentsRenderView = frameContentsRenderView(renderer);
        if (auto frameRootScrollingNodeID = contentsRenderView->frameView().scrollingNodeID()) {
            if (isVisible)
                scrollingCoordinator->insertNode(m_renderView->frameView().frame().rootFrame().frameID(), ScrollingNodeType::Subframe, *frameRootScrollingNodeID, *frameHostingNodeID, 0);
            else
                scrollingCoordinator->unparentNode(*frameRootScrollingNodeID);
        }
    }

    return result;
}

RenderLayer& RenderLayerCompositor::rootRenderLayer() const
{
    return *m_renderView->layer();
}

GraphicsLayer* RenderLayerCompositor::rootGraphicsLayer() const
{
    if (m_overflowControlsHostLayer)
        return m_overflowControlsHostLayer.get();
    return m_rootContentsLayer.get();
}

void RenderLayerCompositor::setIsInWindow(bool isInWindow)
{
    LOG(Compositing, "RenderLayerCompositor %p setIsInWindow %d", this, isInWindow);

    if (!usesCompositing())
        return;

    if (RefPtr rootLayer = rootGraphicsLayer()) {
        GraphicsLayer::traverse(*rootLayer, [isInWindow](GraphicsLayer& layer) {
            layer.setIsInWindow(isInWindow);
        });
    }

    if (isInWindow) {
        if (m_rootLayerAttachment != RootLayerUnattached)
            return;

        RootLayerAttachment attachment = isRootFrameCompositor() ? RootLayerAttachedViaChromeClient : RootLayerAttachedViaEnclosingFrame;
        attachRootLayer(attachment);
#if PLATFORM(IOS_FAMILY)
        if (m_legacyScrollingLayerCoordinator) {
            m_legacyScrollingLayerCoordinator->registerAllViewportConstrainedLayers(*this);
            m_legacyScrollingLayerCoordinator->registerAllScrollingLayers();
        }
#endif
    } else {
        if (m_rootLayerAttachment == RootLayerUnattached)
            return;

        detachRootLayer();
#if PLATFORM(IOS_FAMILY)
        if (m_legacyScrollingLayerCoordinator) {
            m_legacyScrollingLayerCoordinator->unregisterAllViewportConstrainedLayers();
            m_legacyScrollingLayerCoordinator->unregisterAllScrollingLayers();
        }
#endif
    }
}

void RenderLayerCompositor::invalidateEventRegionForAllFrames()
{
    for (RefPtr frame = &page().mainFrame(); frame; frame = frame->tree().traverseNext()) {
        RefPtr localFrame = dynamicDowncast<LocalFrame>(frame);
        if (!localFrame)
            continue;
        if (auto* view = localFrame->contentRenderer())
            view->compositor().invalidateEventRegionForAllLayers();
    }
}

static ASCIILiteral compositingReasonToString(CompositingReason reason)
{
    switch (reason) {
    case CompositingReason::Transform3D: return "3D transform"_s;
    case CompositingReason::Video: return "video"_s;
    case CompositingReason::Canvas: return "canvas"_s;
    case CompositingReason::Plugin: return "plugin"_s;
    case CompositingReason::IFrame: return "iframe"_s;
    case CompositingReason::BackfaceVisibilityHidden: return "backface-visibility: hidden"_s;
    case CompositingReason::ClipsCompositingDescendants: return "clips compositing descendants"_s;
    case CompositingReason::Animation: return "animation"_s;
    case CompositingReason::Filters: return "filters"_s;
    case CompositingReason::PositionFixed: return "position: fixed"_s;
    case CompositingReason::PositionSticky: return "position: sticky"_s;
    case CompositingReason::OverflowScrolling: return "async overflow scrolling"_s;
    case CompositingReason::Stacking: return "stacking"_s;
    case CompositingReason::Overlap: return "overlap"_s;
    case CompositingReason::OverflowScrollPositioning: return "overflow scroll positioning"_s;
    case CompositingReason::NegativeZIndexChildren: return "negative z-index children"_s;
    case CompositingReason::TransformWithCompositedDescendants: return "transform with composited descendants"_s;
    case CompositingReason::OpacityWithCompositedDescendants: return "opacity with composited descendants"_s;
    case CompositingReason::MaskWithCompositedDescendants: return "mask with composited descendants"_s;
    case CompositingReason::ReflectionWithCompositedDescendants: return "reflection with composited descendants"_s;
    case CompositingReason::FilterWithCompositedDescendants: return "filter with composited descendants"_s;
    case CompositingReason::BlendingWithCompositedDescendants: return "blending with composited descendants"_s;
    case CompositingReason::IsolatesCompositedBlendingDescendants: return "isolates composited blending descendants"_s;
    case CompositingReason::Perspective: return "perspective"_s;
    case CompositingReason::Preserve3D: return "preserve-3d"_s;
    case CompositingReason::WillChange: return "will-change"_s;
    case CompositingReason::Root: return "root"_s;
    case CompositingReason::Model: return "model"_s;
    case CompositingReason::SpatialPortal: return "spatial-portal"_s;
    case CompositingReason::SpatialPortalHosting: return "spatial-portal-hosting"_s;
    case CompositingReason::BackdropRoot: return "backdrop root"_s;
    case CompositingReason::AnchorPositioning: return "anchor positioning"_s;
    case CompositingReason::ScreenCaptureProtection: return "screen capture protection"_s;
    }
    return ""_s;
}


static bool canUseDescendantClippingLayer(const RenderLayer& layer)
{
    if (layer.isolatesCompositedBlending())
        return false;

    // We can only use the "descendant clipping layer" strategy when the clip rect is entirely within
    // the border box, because of interactions with border-radius clipping and compositing.
    if (auto* renderer = layer.renderBox(); renderer && renderer->hasClip()) {
        auto borderBoxRect = renderer->borderBoxRect();
        auto clipRect = renderer->clipRect({ });
        
        bool clipRectInsideBorderRect = intersection(borderBoxRect, clipRect) == clipRect;
        return clipRectInsideBorderRect;
    }

    return true;
}

bool RenderLayerCompositor::updateAncestorClippingStack(RenderLayer& layer, const RenderLayer* compositingAncestor) const
{
    ASSERT(layer.isComposited());

    auto clippingStack = computeAncestorClippingStack(layer, compositingAncestor);
    return layer.backing()->updateAncestorClippingStack(WTF::move(clippingStack));
}

Vector<CompositedClipData> RenderLayerCompositor::computeAncestorClippingStack(RenderLayer& layer, const RenderLayer* compositingAncestor) const
{
    // On first pass in WK1, the root may not have become composited yet.
    if (!compositingAncestor)
        return { };

    // We'll start by building a child-to-ancestors stack.
    Vector<CompositedClipData> newStack;

    // Walk up the containing block chain to composited ancestor, prepending an entry to the clip stack for:
    // * each composited scrolling layer
    // * each set of RenderLayers which contribute a clip.
    bool haveNonScrollableClippingIntermediateLayer = false;
    RenderLayer* currentClippedLayer = &layer;
    
    auto pushNonScrollableClip = [&](RenderLayer& clippedLayer, const RenderLayer& clippingRoot, ShouldRespectOverflowClip respectClip = IgnoreOverflowClip) {
        // Use IgnoreOverflowClip to ignore overflow contributed by clippingRoot (which may be a scroller).
        OptionSet<RenderLayer::ClipRectsOption> options = RenderLayer::ClipRectsOption::Temporary;
        if (respectClip == RespectOverflowClip)
            options.add(RenderLayer::ClipRectsOption::RespectOverflowClip);

        auto backgroundClip = clippedLayer.backgroundClipRect(RenderLayer::ClipRectsContext(&clippingRoot, PaintingClipRects, options));
        ASSERT(!backgroundClip.affectedByRadius());
        auto clipRect = backgroundClip.rect();
        if (clipRect.isInfinite())
            return;

        clipRect.makeRenderable();

        auto offset = layer.convertToLayerCoords(&clippingRoot, { }, RenderLayer::AdjustForColumns);
        clipRect.moveBy(-offset);

        CompositedClipData clipData { &clippedLayer, LayoutRoundedRect { clipRect }, false };
        newStack.insert(0, WTF::move(clipData));
    };

    traverseAncestorLayers(layer, [&](RenderLayer& ancestorLayer, bool isContainingBlockChain, bool /*isPaintOrderAncestor*/) {
        if (&ancestorLayer == compositingAncestor) {
            bool canUseDescendantClip = canUseDescendantClippingLayer(ancestorLayer);
            if (haveNonScrollableClippingIntermediateLayer)
                pushNonScrollableClip(*currentClippedLayer, ancestorLayer, !canUseDescendantClip ? RespectOverflowClip : IgnoreOverflowClip);
            else if (!canUseDescendantClip && newStack.isEmpty())
                pushNonScrollableClip(*currentClippedLayer, ancestorLayer, RespectOverflowClip);

            return AncestorTraversal::Stop;
        }

        if (ancestorLayerMayClip(layer, ancestorLayer, isContainingBlockChain)) {
            auto* box = ancestorLayer.renderBox();
            if (!box)
                return AncestorTraversal::Continue;

            if (ancestorLayer.hasCompositedScrollableOverflow()) {
                if (haveNonScrollableClippingIntermediateLayer) {
                    pushNonScrollableClip(*currentClippedLayer, ancestorLayer);
                    haveNonScrollableClippingIntermediateLayer = false;
                }

                auto clipRoundedRect = parentRelativeScrollableRect(ancestorLayer, &ancestorLayer);
                auto offset = layer.convertToLayerCoords(&ancestorLayer, { }, RenderLayer::AdjustForColumns);
                clipRoundedRect.moveBy(-offset);

                RectCorners<float> cornerCurvatures { 1.0f, 1.0f, 1.0f, 1.0f };
                if (box->usedStyle().hasBorderRadius())
                    cornerCurvatures = BorderShape::shapeForBorderRect(box->usedStyle(), box->borderBoxRect()).cornerCurvatures();

                CompositedClipData clipData { &ancestorLayer, clipRoundedRect, true, cornerCurvatures };
                newStack.insert(0, WTF::move(clipData));
                currentClippedLayer = &ancestorLayer;
            } else if (box->hasNonVisibleOverflow() && box->usedStyle().hasBorderRadius()) {
                if (haveNonScrollableClippingIntermediateLayer) {
                    pushNonScrollableClip(*currentClippedLayer, ancestorLayer);
                    haveNonScrollableClippingIntermediateLayer = false;
                }

                auto borderShape = BorderShape::shapeForBorderRect(box->usedStyle(), box->borderBoxRect());
                auto clipRoundedRect = borderShape.deprecatedInnerRoundedRect();

                auto offset = layer.convertToLayerCoords(&ancestorLayer, { }, RenderLayer::AdjustForColumns);
                auto rect = clipRoundedRect.rect();
                rect.moveBy(-offset);
                clipRoundedRect.setRect(rect);

                CompositedClipData clipData { &ancestorLayer, clipRoundedRect, false, borderShape.cornerCurvatures() };
                newStack.insert(0, WTF::move(clipData));
                currentClippedLayer = &ancestorLayer;
            } else
                haveNonScrollableClippingIntermediateLayer = true;
        }

        return AncestorTraversal::Continue;
    });
    
    return newStack;
}

// Note that this returns the ScrollingNodeID of the scroller this layer is embedded in, not the layer's own ScrollingNodeID if it has one.
bool RenderLayerCompositor::hasCompositedWidgetContents(const RenderObject& renderer)
{
    auto* renderWidget = dynamicDowncast<RenderWidget>(renderer);
    if (!renderWidget)
        return false;

    return renderWidget->requiresAcceleratedCompositing();
}

bool RenderLayerCompositor::isCompositedPlugin(const RenderObject& renderer)
{
    auto* renderEmbeddedObject = dynamicDowncast<RenderEmbeddedObject>(renderer);
    if (!renderEmbeddedObject)
        return false;

    return renderEmbeddedObject->requiresAcceleratedCompositing();
}

#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
bool RenderLayerCompositor::isSeparated(const RenderObject& renderer)
{
    return renderer.style().usedTransformStyle3D() == TransformStyle3D::Separated;
}
#endif

#if ENABLE(SPATIAL_PORTAL)
bool RenderLayerCompositor::isSpatialPortal(const RenderObject& renderer)
{
    CheckedPtr renderElement = dynamicDowncast<RenderElement>(renderer);
    if (!renderElement)
        return false;
    RefPtr element = renderElement->element();
    return element && element->establishesSpatialPortal();
}

bool RenderLayerCompositor::isPromotedSpatialPortalChild(const RenderLayer& layer)
{
    CheckedRef renderer = layer.renderer();
    if (!layer.preserves3D() && !(renderer->isTransformed() && renderer->style().has3DTransformOperation()))
        return false;

    auto* parent = layer.parent();
    return parent && isSpatialPortal(parent->renderer()) && layer.ancestorLayerIsDOMParent(parent);
}

RenderLayer* RenderLayerCompositor::promotedSpatialPortalChildForLayer(RenderLayer& layer)
{
    if (!layer.renderer().settings().spatialPortalEnabled())
        return nullptr;

    for (auto* current = &layer; current; current = current->parent()) {
        if (isPromotedSpatialPortalChild(*current))
            return current;
        if (isSpatialPortal(current->renderer()))
            return nullptr;
    }
    return nullptr;
}
#endif

bool RenderLayerCompositor::requiresCompositingForAnimation(RenderLayerModelObject& renderer) const
{
    if (!(m_compositingTriggers & ChromeClient::AnimationTrigger))
        return false;

    if (auto styleable = Styleable::fromRenderer(renderer)) {
        if (styleable->hasRunningAcceleratedAnimations())
            return true;
        if (auto* effectsStack = styleable->keyframeEffectStack()) {
            return (effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Opacity) && (usesCompositing() || (m_compositingTriggers & ChromeClient::AnimatedOpacityTrigger)))
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Filter)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::BackdropFilter)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::WebkitBackdropFilter)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Translate)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Scale)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Rotate)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Transform)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::OffsetAnchor)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::OffsetDistance)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::OffsetPath)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::OffsetPosition)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::OffsetRotate);
        }
    }

    return false;
}

static bool styleTransformOperationsAreRepresentableIn2D(const Style::ComputedStyle& style)
{
    return style.transform().isRepresentableIn2D()
        && style.translate().isRepresentableIn2D()
        && style.scale().isRepresentableIn2D()
        && style.rotate().isRepresentableIn2D();
}

bool RenderLayerCompositor::requiresCompositingForTransform(RenderLayerModelObject& renderer) const
{
    if (!(m_compositingTriggers & ChromeClient::ThreeDTransformTrigger))
        return false;

    // Note that we ask the renderer if it has a transform, because the style may have transforms,
    // but the renderer may be an inline that doesn't suppport them.
    if (!renderer.isTransformed())
        return false;

    auto compositingPolicy = m_compositingPolicy;
#if !USE(COMPOSITING_FOR_SMALL_CANVASES)
    if (auto* canvas = dynamicDowncast<HTMLCanvasElement>(renderer.element())) {
        auto canvasArea = canvas->size().area<RecordOverflow>();
        if (!canvasArea.hasOverflowed() && canvasArea < canvasAreaThresholdRequiringCompositing)
            compositingPolicy = CompositingPolicy::Conservative;
    }
#endif
    
    switch (compositingPolicy) {
    case CompositingPolicy::Normal:
        return renderer.style().has3DTransformOperation();
    case CompositingPolicy::Conservative:
        // Continue to allow pages to avoid the very slow software filter path.
        if (renderer.style().has3DTransformOperation() && renderer.hasFilter())
            return true;
        return !styleTransformOperationsAreRepresentableIn2D(renderer.style());
    }
    return false;
}

bool RenderLayerCompositor::requiresCompositingForVideo(RenderLayerModelObject& renderer) const
{
    if (!(m_compositingTriggers & ChromeClient::VideoTrigger))
        return false;

#if ENABLE(VIDEO)
    CheckedPtr video = dynamicDowncast<RenderVideo>(renderer);
    if (!video)
        return false;

    if ((video->requiresImmediateCompositing() || video->shouldDisplayVideo()) && canAccelerateVideoRendering(*video))
        return true;
#else
    UNUSED_PARAM(renderer);
#endif
    return false;
}

bool RenderLayerCompositor::requiresCompositingForCanvas(RenderLayerModelObject& renderer) const
{
    if (!(m_compositingTriggers & ChromeClient::CanvasTrigger))
        return false;

    CheckedPtr canvasRenderer = dynamicDowncast<RenderHTMLCanvas>(renderer);
    if (!canvasRenderer)
        return false;

    if (canvasRenderer->hasDrawableContent())
        return true;

    bool isCanvasLargeEnoughOrHDRToForceCompositing = true;
#if !USE(COMPOSITING_FOR_SMALL_CANVASES)
    RefPtr canvas = downcast<HTMLCanvasElement>(renderer.element());
    auto canvasArea = canvas->size().area<RecordOverflow>();
    if (canvasArea.hasOverflowed() || canvasArea < canvasAreaThresholdRequiringCompositing) {
#if ENABLE(PIXEL_FORMAT_RGBA16F)
        if (RefPtr renderingContext = canvas->renderingContext(); !renderingContext || !renderingContext->isHDR())
#endif
            isCanvasLargeEnoughOrHDRToForceCompositing = false;
    }
#endif

    CanvasCompositingStrategy compositingStrategy = canvasCompositingStrategy(renderer);
    if (compositingStrategy == CanvasAsLayerContents)
        return true;

    if (m_compositingPolicy == CompositingPolicy::Normal) {
#if ENABLE(PIXEL_FORMAT_RGBA16F)
        // An HDR canvas painted into its enclosing layer would make that whole layer HDR, and so would
        // also show other content painted into it (e.g. canvases with "standard" tone mapping) in HDR.
        if (compositingStrategy == CanvasPaintedToEnclosingLayer) {
            if (RefPtr renderingContext = downcast<HTMLCanvasElement>(renderer.element())->renderingContext(); renderingContext && renderingContext->isHDR())
                return true;
        }
#endif
        return compositingStrategy == CanvasPaintedToLayer && isCanvasLargeEnoughOrHDRToForceCompositing;
    }

    return false;
}

// Will-change is only a hint, so stop honoring it when pages use it for far more area than they can display.
void RenderLayerCompositor::beginWillChangeAreaEstimate()
{
    m_willChangeAreaEstimate = std::nullopt;

    if (m_ignoresWillChangeOverBudget) {
        if (MonotonicTime::now() < m_willChangeBudgetBackoffEndTime)
            return;
        m_ignoresWillChangeOverBudget = false;
        rootRenderLayer().setDescendantsNeedCompositingRequirementsTraversal();
    }

    Ref frameView = m_renderView->frameView();
    FloatRect visibleRect = frameView->visibleContentRect();
#if PLATFORM(IOS_FAMILY)
    FloatRect coverageRect = frameView->exposedContentRect().raw();
#else
    FloatRect coverageRect = visibleRect;
#endif
    // Tiled layers only retain tiles near the visible area.
    if (auto* backing = rootRenderLayer().backing()) {
        if (CheckedPtr tiledBacking = backing->tiledBacking())
            coverageRect.unite(tiledBacking->coverageRect());
    }

    m_willChangeAreaEstimate = WillChangeAreaEstimate { visibleRect.area() * willChangeBudgetViewportAreaMultiplier, coverageRect };
}

void RenderLayerCompositor::addToWillChangeAreaEstimateForSwift(FloatRect bounds)
{
    m_willChangeAreaEstimate->area += intersection(bounds, m_willChangeAreaEstimate->coverageRect).area();
}

bool RenderLayerCompositor::willChangeAreaEstimateExceedsBudget()
{
    auto estimate = std::exchange(m_willChangeAreaEstimate, std::nullopt);
    if (!estimate)
        return false;

    if (estimate->area <= estimate->budget) {
        if (estimate->area < estimate->budget / 2)
            m_willChangeBudgetBackoffDuration = initialWillChangeBudgetBackoff;
        return false;
    }

    RELEASE_LOG(Compositing, "RenderLayerCompositor %p will-change area %.0f exceeds budget %.0f, ignoring will-change for %.0fs", this, estimate->area, estimate->budget, m_willChangeBudgetBackoffDuration.seconds());
    m_ignoresWillChangeOverBudget = true;
    m_willChangeBudgetBackoffEndTime = MonotonicTime::now() + m_willChangeBudgetBackoffDuration;
    m_willChangeBudgetBackoffDuration = std::min(m_willChangeBudgetBackoffDuration * 2, maximumWillChangeBudgetBackoff);
    return true;
}

bool RenderLayerCompositor::requiresCompositingForModel(RenderLayerModelObject& renderer) const
{
#if ENABLE(MODEL_ELEMENT)
    if (is<RenderModel>(renderer))
        return true;
#else
    UNUSED_PARAM(renderer);
#endif

    return false;
}

bool RenderLayerCompositor::requiresCompositingForScreenCaptureProtection(RenderLayerModelObject& renderer) const
{
    CheckedPtr innerBlock = dynamicDowncast<RenderTextControlInnerBlock>(renderer);
    return innerBlock && innerBlock->requiresLayerForScreenCaptureProtection();
}

bool RenderLayerCompositor::requiresCompositingForSpatialPortal(RenderLayerModelObject& renderer) const
{
#if ENABLE(SPATIAL_PORTAL)
    return isSpatialPortal(renderer);
#else
    UNUSED_PARAM(renderer);
    return false;
#endif
}

bool RenderLayerCompositor::requiresCompositingForSpatialPortalHosting(const RenderLayer& layer) const
{
#if ENABLE(SPATIAL_PORTAL)
    return isPromotedSpatialPortalChild(layer);
#else
    UNUSED_PARAM(layer);
    return false;
#endif
}

bool RenderLayerCompositor::requiresCompositingForScrollableFrame(RequiresCompositingData& queryData) const
{
    if (isRootFrameCompositor())
        return false;

#if PLATFORM(COCOA) || USE(COORDINATED_GRAPHICS)
    if (!m_renderView->settings().asyncFrameScrollingEnabled())
        return false;
#endif

    if (!(m_compositingTriggers & ChromeClient::ScrollableNonMainFrameTrigger))
        return false;

    if (queryData.layoutUpToDate == LayoutUpToDate::No) {
        queryData.reevaluateAfterLayout = true;
        return m_renderView->isComposited();
    }

    return m_renderView->frameView().isScrollable();
}

bool RenderLayerCompositor::styleChangeMayAffectIndirectCompositingReasons(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle)
{
    if (RenderElement::createsGroupForStyle(newStyle) != RenderElement::createsGroupForStyle(oldStyle))
        return true;
    if (newStyle.isolation() != oldStyle.isolation())
        return true;
    if ((!newStyle.transform().isNone() || !newStyle.offsetPath().isNone()) != (!oldStyle.transform().isNone() || !oldStyle.offsetPath().isNone()))
        return true;
    if (newStyle.boxReflect().isNone() != oldStyle.boxReflect().isNone())
        return true;
    if (newStyle.usedTransformStyle3D() != oldStyle.usedTransformStyle3D())
        return true;
    if (newStyle.perspective().isNone() != oldStyle.perspective().isNone())
        return true;

    return false;
}

bool RenderLayerCompositor::isAsyncScrollableStickyLayer(const RenderLayer& layer, const RenderLayer** enclosingAcceleratedOverflowLayer) const
{
    ASSERT(layer.renderer().isStickilyPositioned());

    auto* enclosingOverflowLayer = layer.enclosingOverflowClipLayer(ExcludeSelf);

    if (enclosingOverflowLayer && enclosingOverflowLayer->hasCompositedScrollableOverflow()) {
        if (enclosingAcceleratedOverflowLayer)
            *enclosingAcceleratedOverflowLayer = enclosingOverflowLayer;
        return true;
    }

    // If the layer is inside normal overflow, it's not async-scrollable.
    if (enclosingOverflowLayer)
        return false;

    // No overflow ancestor, so see if the frame supports async scrolling.
    if (hasCoordinatedScrolling())
        return true;

#if PLATFORM(IOS_FAMILY)
    // iOS WK1 has fixed/sticky support in the main frame via WebFixedPositionContent.
    return isMainFrameCompositor();
#else
    return false;
#endif
}

bool RenderLayerCompositor::isLayerForPluginWithScrollCoordinatedContents(const RenderLayer& layer) const
{
    CheckedPtr renderEmbeddedObject = dynamicDowncast<RenderEmbeddedObject>(layer.renderer());
    if (!renderEmbeddedObject)
        return false;

    return renderEmbeddedObject->usesAsyncScrolling();
}

bool RenderLayerCompositor::isRunningTransformAnimation(RenderLayerModelObject& renderer) const
{
    if (!(m_compositingTriggers & ChromeClient::AnimationTrigger))
        return false;

    if (auto styleable = Styleable::fromRenderer(renderer)) {
        if (auto* effectsStack = styleable->keyframeEffectStack())
            return effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Transform)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Rotate)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Scale)
                || effectsStack->isCurrentlyAffectingProperty(CSSPropertyID::Translate);
    }

    return false;
}

bool RenderLayerCompositor::isModelInSystemPreviewLink(RenderLayerModelObject& renderer)
{
#if ENABLE(MODEL_PROCESS)
    if (CheckedPtr renderModel = dynamicDowncast<RenderModel>(renderer)) {
        RefPtr anchor = dynamicDowncast<HTMLAnchorElement>(renderModel->modelElement().parentElement());
        return anchor && anchor->isSystemPreviewLink();
    }
#else
    UNUSED_PARAM(renderer);
#endif
    return false;
}

bool RenderLayerCompositor::requiresScrollLayer(RootLayerAttachment attachment) const
{
    auto& frameView = m_renderView->frameView();

    // This applies when the application UI handles scrolling, in which case RenderLayerCompositor doesn't need to manage it.
    if (frameView.delegatedScrollingMode() == DelegatedScrollingMode::DelegatedToNativeScrollView && isMainFrameCompositor())
        return false;

    // We need to handle our own scrolling if we're:
    return !m_renderView->frameView().platformWidget() // viewless (i.e. non-Mac, or Mac in WebKit2)
        || attachment == RootLayerAttachedViaEnclosingFrame; // a composited frame on Mac
}

void paintScrollbar(Scrollbar* scrollbar, GraphicsContext& context, const IntRect& clip, const Color& backgroundColor)
{
    if (!scrollbar)
        return;

    context.save();
    const IntRect& scrollbarRect = scrollbar->frameRect();
    context.translate(-scrollbarRect.location());
    IntRect transformedClip = clip;
    transformedClip.moveBy(scrollbarRect.location());
#if HAVE(RUBBER_BANDING)
    UNUSED_PARAM(backgroundColor);
#else
    if (!scrollbar->isOverlayScrollbar() && backgroundColor.isVisible())
        context.fillRect(transformedClip, backgroundColor);
#endif
    scrollbar->paint(context, transformedClip);
    context.restore();
}

void RenderLayerCompositor::paintContents(const GraphicsLayer& graphicsLayer, GraphicsContext& context, const FloatRect& clip, OptionSet<GraphicsLayerPaintBehavior>)
{
#if PLATFORM(MAC)
    LocalDefaultSystemAppearance localAppearance(m_renderView->useDarkAppearance());
#endif

    IntRect pixelSnappedRectForIntegralPositionedItems = snappedIntRect(LayoutRect(clip));
    if (&graphicsLayer == layerForHorizontalScrollbar())
        paintScrollbar(RefPtr { m_renderView->frameView().horizontalScrollbar() }.get(), context, pixelSnappedRectForIntegralPositionedItems, m_viewBackgroundColor);
    else if (&graphicsLayer == layerForVerticalScrollbar())
        paintScrollbar(RefPtr { m_renderView->frameView().verticalScrollbar() }.get(), context, pixelSnappedRectForIntegralPositionedItems, m_viewBackgroundColor);
    else if (&graphicsLayer == layerForScrollCorner()) {
        Ref frameView = m_renderView->frameView();
        const IntRect& scrollCorner = frameView->scrollCornerRect();
        context.save();
        context.translate(-scrollCorner.location());
        IntRect transformedClip = pixelSnappedRectForIntegralPositionedItems;
        transformedClip.moveBy(scrollCorner.location());
        frameView->paintScrollCorner(context, transformedClip);
        context.restore();
    }
}

GraphicsLayer* RenderLayerCompositor::fixedRootBackgroundLayer() const
{
    // Get the fixed root background from the RenderView layer's backing.
    auto* viewLayer = m_renderView->layer();
    if (!viewLayer)
        return nullptr;

    if (viewLayer->isComposited() && viewLayer->backing()->backgroundLayerPaintsFixedRootBackground())
        return viewLayer->backing()->backgroundLayer();

    return nullptr;
}

void RenderLayerCompositor::resetTrackedRepaintRects()
{
    if (RefPtr rootLayer = rootGraphicsLayer()) {
        GraphicsLayer::traverse(*rootLayer, [](GraphicsLayer& layer) {
            layer.resetTrackedRepaints();
        });
    }
}

float RenderLayerCompositor::pageScaleFactor() const
{
    return page().pageScaleFactor();
}

bool RenderLayerCompositor::delegatesScaling() const
{
    return page().delegatesScaling();
}

FloatSize RenderLayerCompositor::enclosingFrameViewVisibleSize() const
{
    const Ref frameView = m_renderView->frameView();
#if PLATFORM(IOS_FAMILY)
    return frameView->exposedContentRect().raw().size();
#else
    if (m_scrolledContentsLayer)
        return frameView->sizeForVisibleContent(scrollbarInclusionForVisibleRect());
    return frameView->visibleContentRect().size();
#endif
}

float RenderLayerCompositor::contentsScaleMultiplierForNewTiles(const GraphicsLayer*) const
{
#if PLATFORM(IOS_FAMILY)
    RefPtr<LegacyTileCache> tileCache;
    RefPtr localMainFrame = page().localMainFrame();
    if (auto* frameView = localMainFrame ? localMainFrame->view() : nullptr)
        tileCache = frameView->legacyTileCache();

    if (!tileCache)
        return 1;

    return tileCache->tileControllerShouldUseLowScaleTiles() ? 0.125 : 1;
#else
    return 1;
#endif
}

RefPtr<GraphicsLayer>& RenderLayerCompositor::graphicsLayerField(GraphicsLayerName name)
{
    switch (name) {
#if HAVE(RUBBER_BANDING)
    case GraphicsLayerName::TopOverhangImage: return m_layerForTopOverhangImage;
    case GraphicsLayerName::TopOverhangColorExtension: return m_layerForTopOverhangColorExtension;
    case GraphicsLayerName::BottomOverhang: return m_layerForBottomOverhangArea;
    case GraphicsLayerName::Header: return m_layerForHeader;
    case GraphicsLayerName::Footer: return m_layerForFooter;
    case GraphicsLayerName::OverhangAreas: return m_layerForOverhangAreas;
    case GraphicsLayerName::ContentShadow: return m_contentShadowLayer;
#else
    case GraphicsLayerName::TopOverhangImage:
    case GraphicsLayerName::TopOverhangColorExtension:
    case GraphicsLayerName::BottomOverhang:
    case GraphicsLayerName::Header:
    case GraphicsLayerName::Footer:
    case GraphicsLayerName::OverhangAreas:
    case GraphicsLayerName::ContentShadow:
        break;
#endif
    case GraphicsLayerName::HorizontalScrollbarContainer: return m_layerForHorizontalScrollbar;
    case GraphicsLayerName::VerticalScrollbarContainer: return m_layerForVerticalScrollbar;
    case GraphicsLayerName::ScrollCorner: return m_layerForScrollCorner;
    case GraphicsLayerName::ContentRoot: return m_rootContentsLayer;
    case GraphicsLayerName::OverflowControlsHost: return m_overflowControlsHostLayer;
    case GraphicsLayerName::FrameScrolledContents: return m_scrolledContentsLayer;
    case GraphicsLayerName::ScrollContainer: return m_scrollContainerLayer;
    case GraphicsLayerName::FrameClipping: return m_clipLayer;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void RenderLayerCompositor::unparentAndClearGraphicsLayer(GraphicsLayerName name)
{
    RefPtr layer = std::exchange(graphicsLayerField(name), nullptr);
    if (!layer)
        return;
    layer->removeFromParent();
    layer->clearClient();
}

void RenderLayerCompositor::createGraphicsLayer(GraphicsLayerName name, GraphicsLayer::Type type)
{
    unparentAndClearGraphicsLayer(name);
    Ref layer = GraphicsLayer::create(graphicsLayerFactory(), *this, type);
    auto& field = graphicsLayerField(name);
    RELEASE_ASSERT(!field);
    field = layer.copyRef();
    switch (name) {
    case GraphicsLayerName::TopOverhangImage: layer->setName(MAKE_STATIC_STRING_IMPL("top overhang (image)")); break;
    case GraphicsLayerName::TopOverhangColorExtension: layer->setName(MAKE_STATIC_STRING_IMPL("top overhang (color extension)")); break;
    case GraphicsLayerName::BottomOverhang: layer->setName(MAKE_STATIC_STRING_IMPL("bottom overhang")); break;
    case GraphicsLayerName::Header: layer->setName(MAKE_STATIC_STRING_IMPL("header")); break;
    case GraphicsLayerName::Footer: layer->setName(MAKE_STATIC_STRING_IMPL("footer")); break;
    case GraphicsLayerName::OverhangAreas: layer->setName(MAKE_STATIC_STRING_IMPL("overhang areas")); break;
    case GraphicsLayerName::ContentShadow: layer->setName(MAKE_STATIC_STRING_IMPL("content shadow")); break;
    case GraphicsLayerName::HorizontalScrollbarContainer: layer->setName(MAKE_STATIC_STRING_IMPL("horizontal scrollbar container")); break;
    case GraphicsLayerName::VerticalScrollbarContainer: layer->setName(MAKE_STATIC_STRING_IMPL("vertical scrollbar container")); break;
    case GraphicsLayerName::ScrollCorner: layer->setName(MAKE_STATIC_STRING_IMPL("scroll corner")); break;
    case GraphicsLayerName::ContentRoot: layer->setName(MAKE_STATIC_STRING_IMPL("content root")); break;
    case GraphicsLayerName::OverflowControlsHost: layer->setName(MAKE_STATIC_STRING_IMPL("overflow controls host")); break;
    case GraphicsLayerName::FrameScrolledContents: layer->setName(MAKE_STATIC_STRING_IMPL("frame scrolled contents")); break;
    case GraphicsLayerName::ScrollContainer: layer->setName(MAKE_STATIC_STRING_IMPL("scroll container")); break;
    case GraphicsLayerName::FrameClipping: layer->setName(MAKE_STATIC_STRING_IMPL("frame clipping")); break;
    }
}

void RenderLayerCompositor::chromeClientDidAddHeaderLayer(GraphicsLayer& layer)
{
    page().chrome().client().didAddHeaderLayer(layer);
}

void RenderLayerCompositor::chromeClientDidAddFooterLayer(GraphicsLayer& layer)
{
    page().chrome().client().didAddFooterLayer(layer);
}

void RenderLayerCompositor::attachRootGraphicsLayerViaChromeClient(GraphicsLayer* layer)
{
    page().chrome().client().attachRootGraphicsLayer(protect(m_renderView->frameView().frame()), layer);
}

GraphicsLayer& RenderLayerCompositor::layerWithDocumentOverlays() const
{
    return page().pageOverlayController().layerWithDocumentOverlaysForFrame(&m_renderView->frameView().frame());
}

Color RenderLayerCompositor::fixedContainerEdgesTopColor() const
{
    return page().fixedContainerEdges().predominantColor(BoxSide::Top);
}

void RenderLayerCompositor::chromeClientPageExtendedBackgroundColorDidChange()
{
    page().chrome().client().pageExtendedBackgroundColorDidChange();
}

void RenderLayerCompositor::frameViewScrollbarLayerDidChange(ScrollbarOrientation orientation)
{
    if (RefPtr scrollingCoordinator = this->scrollingCoordinator())
        scrollingCoordinator->scrollableAreaScrollbarLayerDidChange(m_renderView->frameView(), orientation);
}

bool RenderLayerCompositor::viewHasTransparentBackground(Color* backgroundColor) const
{
    Ref frameView = m_renderView->frameView();
    if (frameView->isTransparent()) {
        if (backgroundColor)
            *backgroundColor = Color(); // Return an invalid color.
        return true;
    }

    Color documentBackgroundColor = frameView->documentBackgroundColor();
    if (!documentBackgroundColor.isValid())
        documentBackgroundColor = frameView->baseBackgroundColor();

    ASSERT(documentBackgroundColor.isValid());

    if (backgroundColor)
        *backgroundColor = documentBackgroundColor;

    return !documentBackgroundColor.isOpaque();
}

// We can't rely on getting layerStyleChanged() for a style change that affects the root background, because the style change may
// be on the body which has no RenderLayer.
void RenderLayerCompositor::rootOrBodyStyleChanged(RenderElement& renderer, const Style::ComputedStyle* oldStyle)
{
    if (!usesCompositing())
        return;

    Color oldBackgroundColor;
    if (oldStyle)
        oldBackgroundColor = oldStyle->visitedDependentUsedBackgroundColorApplyingColorFilter();

    if (oldBackgroundColor != renderer.style().visitedDependentUsedBackgroundColorApplyingColorFilter())
        rootBackgroundColorOrTransparencyChanged();

    bool hadFixedBackground = oldStyle && Style::hasEntirelyFixedBackground(oldStyle->backgroundLayers());
    if (hadFixedBackground != Style::hasEntirelyFixedBackground(renderer.style().backgroundLayers()))
        rootLayerConfigurationChanged();
    
    if (oldStyle && (oldStyle->overscrollBehaviorX() != renderer.style().overscrollBehaviorX() || oldStyle->overscrollBehaviorY() != renderer.style().overscrollBehaviorY())) {
        if (auto* layer = m_renderView->layer())
            layer->setNeedsCompositingGeometryUpdate();
    }
}

bool RenderLayerCompositor::documentIsFullscreenForSwift() const
{
#if ENABLE(FULLSCREEN_API)
    if (RefPtr fullscreen = m_renderView->document().fullscreenIfExists(); fullscreen && fullscreen->isFullscreen())
        return true;
#endif
    return false;
}

RenderElement* RenderElementList::rendererAt(size_t index) const
{
    return m_renderers[index].get();
}

ScrollingNodeIDList RenderLayerCompositor::scrollingNodeIDsForSwift() const
{
    HashSet<ScrollingNodeID> nodesToClear;
    nodesToClear.reserveInitialCapacity(m_scrollingNodeToLayerMap.size());
    for (auto key : m_scrollingNodeToLayerMap.keys())
        nodesToClear.add(key);

    ScrollingNodeIDList nodeIDs;
    for (auto nodeID : nodesToClear)
        nodeIDs.append(nodeID);
    return nodeIDs;
}

RenderLayerWeakList RenderLayerCompositor::layersWithUnresolvedRelationsForSwift() const
{
    RenderLayerWeakList layers;
    for (auto& layer : m_layersWithUnresolvedRelations | dereferenceView)
        layers.append(layer);
    return layers;
}

void RenderLayerCompositor::clearLayersWithUnresolvedRelationsForSwift()
{
    m_layersWithUnresolvedRelations.clear();
}

RenderElementList RenderLayerCompositor::slowRepaintObjectsForSwift() const
{
    RenderElementList renderers;
    if (auto slowRepaintObjects = m_renderView->frameView().slowRepaintObjects()) {
        for (auto& renderer : *slowRepaintObjects | dereferenceView)
            renderers.m_renderers.append(renderer);
    }
    return renderers;
}

void RenderLayerCompositor::addScrollingNodeLayerForSwift(ScrollingNodeID nodeID, RenderLayer& layer)
{
    m_scrollingNodeToLayerMap.add(nodeID, layer);
}

void RenderLayerCompositor::removeScrollingNodeLayerForSwift(ScrollingNodeID nodeID)
{
    m_scrollingNodeToLayerMap.remove(nodeID);
}

void RenderLayerCompositor::addLayerWithUnresolvedRelationsForSwift(RenderLayer& layer)
{
    m_layersWithUnresolvedRelations.add(layer);
}

void RenderLayerCompositor::setScrollingNodeScrollableAreaGeometryForSwift(ScrollingCoordinator& scrollingCoordinator, ScrollingNodeID nodeID, RenderLayerScrollableArea& scrollableArea)
{
    scrollingCoordinator.setScrollingNodeScrollableAreaGeometry(nodeID, scrollableArea);
}

void RenderLayerCompositor::setScrollingNodeScrollableAreaGeometryForSwift(ScrollingCoordinator& scrollingCoordinator, ScrollingNodeID nodeID, LocalFrameView& frameView)
{
    scrollingCoordinator.setScrollingNodeScrollableAreaGeometry(nodeID, frameView);
}

void RenderLayerCompositor::ensureScrollbarsControllerForSwift(RenderLayerScrollableArea& scrollableArea)
{
    page().chrome().client().ensureScrollbarsController(protect(page()), scrollableArea, true);
}

void RenderLayerCompositor::ensureScrollbarsControllerForSwift(LocalFrameView& frameView)
{
    page().chrome().client().ensureScrollbarsController(protect(page()), frameView, true);
}

void RenderLayerCompositor::setFixedViewportConstraintsForSwift(ScrollingCoordinator& scrollingCoordinator, ScrollingNodeID nodeID, RenderLayer& layer)
{
    RELEASE_ASSERT(layer.backing());
    scrollingCoordinator.setViewportConstraintedNodeConstraints(nodeID, computeFixedViewportConstraints(layer));
}

void RenderLayerCompositor::setStickyViewportConstraintsForSwift(ScrollingCoordinator& scrollingCoordinator, ScrollingNodeID nodeID, RenderLayer& layer)
{
    RELEASE_ASSERT(layer.backing());
    scrollingCoordinator.setViewportConstraintedNodeConstraints(nodeID, computeStickyViewportConstraints(layer));
}

void RenderLayerCompositor::setLayerHostingContextIdentifierForSwift(ScrollingCoordinator& scrollingCoordinator, ScrollingNodeID nodeID, RenderLayer& layer)
{
    if (auto* renderWidget = dynamicDowncast<RenderWidget>(layer.renderer())) {
        if (RefPtr frame = renderWidget->frameOwnerElement().contentFrame()) {
            if (auto* remoteFrame = dynamicDowncast<RemoteFrame>(frame.get()))
                scrollingCoordinator.setLayerHostingContextIdentifierForFrameHostingNode(nodeID, remoteFrame->layerHostingContextIdentifier());
        }
    }
}

#if PLATFORM(IOS_FAMILY)
void RenderLayerCompositor::updateLegacyViewportConstrainedLayer(RenderLayer& layer, bool isViewportConstrained)
{
    if (m_legacyScrollingLayerCoordinator) {
        if (isViewportConstrained)
            m_legacyScrollingLayerCoordinator->addViewportConstrainedLayer(layer);
        else
            m_legacyScrollingLayerCoordinator->removeViewportConstrainedLayer(layer);
    }
}

void RenderLayerCompositor::removeFromLegacyScrollingLayerCoordinator(RenderLayerBacking& backing)
{
    if (m_legacyScrollingLayerCoordinator)
        m_legacyScrollingLayerCoordinator->removeLayer(backing.owningLayer());
}
#endif

FixedPositionViewportConstraints RenderLayerCompositor::computeFixedViewportConstraints(RenderLayer& layer) const
{
    ASSERT(layer.isComposited());

    RefPtr scrollingNodeLayer = layer.backing()->viewportClippingOrAnchorLayer();
    if (!scrollingNodeLayer) {
        ASSERT_NOT_REACHED();
        return { };
    }

    FixedPositionViewportConstraints constraints;
    constraints.setLayerPositionAtLastLayout(scrollingNodeLayer->position());
    constraints.setViewportRectAtLastLayout(m_renderView->frameView().rectForFixedPositionLayout());
    constraints.setAlignmentOffset(scrollingNodeLayer->pixelAlignmentOffset());

    const Style::ComputedStyle& style = layer.renderer().style();
    if (!style.left().isAuto())
        constraints.addAnchorEdge(ViewportConstraints::AnchorEdgeLeft);

    if (!style.right().isAuto())
        constraints.addAnchorEdge(ViewportConstraints::AnchorEdgeRight);

    if (!style.top().isAuto())
        constraints.addAnchorEdge(ViewportConstraints::AnchorEdgeTop);

    if (!style.bottom().isAuto())
        constraints.addAnchorEdge(ViewportConstraints::AnchorEdgeBottom);

    // If left and right are auto, use left.
    if (style.left().isAuto() && style.right().isAuto())
        constraints.addAnchorEdge(ViewportConstraints::AnchorEdgeLeft);

    // If top and bottom are auto, use top.
    if (style.top().isAuto() && style.bottom().isAuto())
        constraints.addAnchorEdge(ViewportConstraints::AnchorEdgeTop);
        
    return constraints;
}

StickyPositionViewportConstraints RenderLayerCompositor::computeStickyViewportConstraints(RenderLayer& layer) const
{
    ASSERT(layer.isComposited());

    auto& renderer = downcast<RenderBoxModelObject>(layer.renderer());

    RefPtr scrollingNodeLayer = layer.backing()->viewportClippingOrAnchorLayer();
    if (!scrollingNodeLayer) {
        ASSERT_NOT_REACHED();
        return { };
    }

    RefPtr anchorLayer = layer.backing()->viewportAnchorLayer();
    if (!anchorLayer) {
        ASSERT_NOT_REACHED();
        return { };
    }

    StickyPositionViewportConstraints constraints;
    renderer.computeStickyPositionConstraints(constraints, renderer.constrainingRectForStickyPosition());

    constraints.setViewportRectAtLastLayout(m_renderView->frameView().rectForFixedPositionLayout());
    constraints.setLayerPositionAtLastLayout(scrollingNodeLayer->position());
    if (scrollingNodeLayer != anchorLayer)
        constraints.setAnchorLayerOffsetAtLastLayout(toFloatSize(anchorLayer->position()));
    constraints.setStickyOffsetAtLastLayout(renderer.stickyPositionOffset());
    constraints.setAlignmentOffset(scrollingNodeLayer->pixelAlignmentOffset());

    return constraints;
}

void RenderLayerCompositor::setNeedsScrollingTreeUpdateForChildrenOfNode(ScrollingCoordinator& scrollingCoordinator, ScrollingNodeID nodeID)
{
    for (auto childNodeID : scrollingCoordinator.childrenOfNode(nodeID)) {
        if (auto weakLayer = m_scrollingNodeToLayerMap.get(childNodeID))
            weakLayer->setNeedsScrollingTreeUpdate();
    }
}

LayoutRoundedRect RenderLayerCompositor::parentRelativeScrollableRect(const RenderLayer& layer, const RenderLayer* ancestorLayer) const
{
    // FIXME: ancestorLayer needs to be always non-null, so should become a reference.
    if (!ancestorLayer) {
        if (!layer.scrollableArea())
            return LayoutRoundedRect { LayoutRect { } };
        return LayoutRoundedRect { LayoutRect({ }, LayoutSize(CheckedPtr { layer.scrollableArea() }->visibleSize())) };
    }

    LayoutRoundedRect scrollableRect(LayoutRect { });
    {
        CheckedPtr box = dynamicDowncast<RenderBox>(layer.renderer());
        if (!box)
            return LayoutRoundedRect { LayoutRect { } };

        scrollableRect = LayoutRoundedRect { box->paddingBoxRect() };
        if (box->usedStyle().hasBorderRadius()) {
            auto borderShape = BorderShape::shapeForBorderRect(box->usedStyle(), box->borderBoxRect());
            scrollableRect = borderShape.deprecatedInnerRoundedRect();
        }
    }

    auto offset = layer.convertToLayerCoords(ancestorLayer, scrollableRect.rect().location()); // FIXME: broken for columns.
    auto rect = scrollableRect.rect();
    rect.setLocation(offset);
    scrollableRect.setRect(rect);
    return scrollableRect;
}

ScrollableArea* RenderLayerCompositor::scrollableAreaForScrollingNodeID(std::optional<ScrollingNodeID> nodeID) const
{
    if (!nodeID)
        return nullptr;

    if (*nodeID == m_renderView->frameView().scrollingNodeID())
        return &m_renderView->frameView();

    if (auto weakLayer = m_scrollingNodeToLayerMap.get(*nodeID))
        return weakLayer->scrollableArea();

    return nullptr;
}

void RenderLayerCompositor::willRemoveScrollingLayerWithBacking(RenderLayerBacking& backing)
{
    if (scrollingCoordinator())
        return;

#if PLATFORM(IOS_FAMILY)
    ASSERT(m_renderView->document().backForwardCacheState() == Document::NotInBackForwardCache);
    if (m_legacyScrollingLayerCoordinator)
        m_legacyScrollingLayerCoordinator->removeScrollingLayer(backing.owningLayer(), backing);
#else
    UNUSED_PARAM(backing);
#endif
}

// FIXME: This should really be called from the updateBackingAndHierarchy.
void RenderLayerCompositor::didAddScrollingLayer(RenderLayer& layer)
{
    if (scrollingCoordinator())
        return;

#if PLATFORM(IOS_FAMILY)
    ASSERT(m_renderView->document().backForwardCacheState() == Document::NotInBackForwardCache);
    if (m_legacyScrollingLayerCoordinator)
        m_legacyScrollingLayerCoordinator->addScrollingLayer(layer);
#else
    UNUSED_PARAM(layer);
#endif
}

ScrollingCoordinator* RenderLayerCompositor::scrollingCoordinator() const
{
    RefPtr frame = m_renderView->document().frame();
    if (!frame)
        return nullptr;

    RefPtr page = frame->page();
    if (!page)
        return nullptr;

    return page->scrollingCoordinator();
}

GraphicsLayerFactory* RenderLayerCompositor::graphicsLayerFactory() const
{
    return page().chrome().client().graphicsLayerFactory();
}

Page& RenderLayerCompositor::page() const
{
    return m_renderView->page();
}

TextStream& operator<<(TextStream& ts, CompositingUpdateType updateType)
{
    switch (updateType) {
    case CompositingUpdateType::AfterStyleChange: ts << "after style change"_s; break;
    case CompositingUpdateType::AfterLayout: ts << "after layout"_s; break;
    case CompositingUpdateType::OnScroll: ts << "on scroll"_s; break;
    case CompositingUpdateType::OnCompositedScroll: ts << "on composited scroll"_s; break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, CompositingPolicy compositingPolicy)
{
    switch (compositingPolicy) {
    case CompositingPolicy::Normal: ts << "normal"_s; break;
    case CompositingPolicy::Conservative: ts << "conservative"_s; break;
    }
    return ts;
}

TextStream& operator<<(TextStream& ts, CompositingReason compositingReason)
{
    return ts << compositingReasonToString(compositingReason);
}

#if PLATFORM(IOS_FAMILY)
typedef HashMap<PlatformLayer*, std::unique_ptr<ViewportConstraints>> LayerMap;
typedef HashMap<PlatformLayer*, PlatformLayer*> StickyContainerMap;

void LegacyWebKitScrollingLayerCoordinator::registerAllViewportConstrainedLayers(RenderLayerCompositor& compositor)
{
    if (!m_coordinateViewportConstrainedLayers)
        return;

    LayerMap layerMap;
    StickyContainerMap stickyContainerMap;

    for (auto& layer : m_viewportConstrainedLayers | dereferenceView) {
        ASSERT(layer.isComposited());

        std::unique_ptr<ViewportConstraints> constraints;
        if (layer.renderer().isStickilyPositioned()) {
            constraints = makeUnique<StickyPositionViewportConstraints>(compositor.computeStickyViewportConstraints(layer));
            const RenderLayer* enclosingTouchScrollableLayer = nullptr;
            if (compositor.isAsyncScrollableStickyLayer(layer, &enclosingTouchScrollableLayer) && enclosingTouchScrollableLayer) {
                ASSERT(enclosingTouchScrollableLayer->isComposited());
                // what
                stickyContainerMap.add(layer.backing()->graphicsLayer()->platformLayer(), enclosingTouchScrollableLayer->backing()->scrollContainerLayer()->platformLayer());
            }
        } else if (layer.renderer().isFixedPositioned())
            constraints = makeUnique<FixedPositionViewportConstraints>(compositor.computeFixedViewportConstraints(layer));
        else
            continue;

        layerMap.add(layer.backing()->graphicsLayer()->platformLayer(), WTF::move(constraints));
    }
    
    m_chromeClient.updateViewportConstrainedLayers(layerMap, stickyContainerMap);
}

void LegacyWebKitScrollingLayerCoordinator::unregisterAllViewportConstrainedLayers()
{
    if (!m_coordinateViewportConstrainedLayers)
        return;

    LayerMap layerMap;
    m_chromeClient.updateViewportConstrainedLayers(layerMap, { });
}

void LegacyWebKitScrollingLayerCoordinator::updateScrollingLayer(RenderLayer& layer)
{
    auto* backing = layer.backing();
    ASSERT(backing);

    auto* scrollableArea = layer.scrollableArea();
    ASSERT(scrollableArea);

    bool allowHorizontalScrollbar = scrollableArea->horizontalNativeScrollbarVisibility() != NativeScrollbarVisibility::HiddenByStyle;
    bool allowVerticalScrollbar = scrollableArea->verticalNativeScrollbarVisibility() != NativeScrollbarVisibility::HiddenByStyle;

    m_chromeClient.addOrUpdateScrollingLayer(layer.renderer().element(), backing->scrollContainerLayer()->platformLayer(), backing->scrolledContentsLayer()->platformLayer(),
        scrollableArea->reachableTotalContentsSize(), allowHorizontalScrollbar, allowVerticalScrollbar);
}

void LegacyWebKitScrollingLayerCoordinator::registerAllScrollingLayers()
{
    for (auto& layer : m_scrollingLayers | dereferenceView)
        updateScrollingLayer(layer);
}

void LegacyWebKitScrollingLayerCoordinator::unregisterAllScrollingLayers()
{
    for (auto& layer : m_scrollingLayers | dereferenceView) {
        auto* backing = layer.backing();
        ASSERT(backing);
        m_chromeClient.removeScrollingLayer(layer.renderer().element(), backing->scrollContainerLayer()->platformLayer(), backing->scrolledContentsLayer()->platformLayer());
    }
}

void LegacyWebKitScrollingLayerCoordinator::addScrollingLayer(RenderLayer& layer)
{
    m_scrollingLayers.add(layer);
}

void LegacyWebKitScrollingLayerCoordinator::removeScrollingLayer(RenderLayer& layer, RenderLayerBacking& backing)
{
    if (m_scrollingLayers.remove(layer)) {
        auto* scrollContainerLayer = backing.scrollContainerLayer()->platformLayer();
        auto* scrolledContentsLayer = backing.scrolledContentsLayer()->platformLayer();
        m_chromeClient.removeScrollingLayer(layer.renderer().element(), scrollContainerLayer, scrolledContentsLayer);
    }
}

void LegacyWebKitScrollingLayerCoordinator::removeLayer(RenderLayer& layer)
{
    removeScrollingLayer(layer, *layer.backing());

    // We'll put the new set of layers to the client via registerAllViewportConstrainedLayers() at flush time.
    m_viewportConstrainedLayers.remove(layer);
}

void LegacyWebKitScrollingLayerCoordinator::addViewportConstrainedLayer(RenderLayer& layer)
{
    m_viewportConstrainedLayers.add(layer);
}

void LegacyWebKitScrollingLayerCoordinator::removeViewportConstrainedLayer(RenderLayer& layer)
{
    m_viewportConstrainedLayers.remove(layer);
}

#endif

} // namespace WebCore

#if ENABLE(TREE_DEBUGGING)
void showGraphicsLayerTreeForCompositor(WebCore::RenderLayerCompositor& compositor)
{
    showGraphicsLayerTree(compositor.rootGraphicsLayer());
}
#endif
