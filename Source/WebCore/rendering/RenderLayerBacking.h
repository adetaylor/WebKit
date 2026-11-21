/*
 * Copyright (C) 2009, 2010, 2011 Apple Inc. All rights reserved.
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

#pragma once

#include <WebCore/BoxExtents.h>
#include <WebCore/BoxSides.h>
#include <WebCore/FloatPoint.h>
#include <WebCore/FloatPoint3D.h>
#include <WebCore/GraphicsLayerClient.h>
#include <WebCore/GraphicsLayerEnums.h>
#include <WebCore/RenderLayer.h>
#include <WebCore/RenderLayerCompositor.h>
#include <WebCore/ScrollingCoordinator.h>
#include <wtf/HashMap.h>
#include <wtf/Platform.h>
#include <wtf/Range.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakListHashSet.h>

namespace WebCore {

class BitmapImage;
class BlendingKeyframesView;
class GraphicsLayer;
class GraphicsLayerAnimation;
class Image;
class NativeImage;
class Path;
class RegionContext;
class RenderImage;
class RenderLayerCompositor;
class RenderReplaced;
class RenderVideo;
class SpatialPortalController;
class TiledBacking;
class TransformationMatrix;

enum class WindRule : bool;

#if ENABLE(THREADED_ANIMATIONS)
class AcceleratedEffectStack;
class AcceleratedTimeline;
#endif

using ScrollCoordinationRoles = OptionSet<ScrollCoordinationRole>;

enum CompositingLayerType {
    NormalCompositingLayer, // non-tiled layer with backing store
    TiledCompositingLayer, // tiled layer (always has backing store)
    MediaCompositingLayer, // layer that contains an image, video, WebGL or plugin
    ContainerCompositingLayer // layer with no backing store
};

namespace DisplayList {
enum class AsTextFlag : uint8_t;
}

// RenderLayerBacking controls the compositing behavior for a single RenderLayer.
// It holds the various GraphicsLayers, and makes decisions about intra-layer rendering
// optimizations.
// 
// There is one RenderLayerBacking for each RenderLayer that is composited.

class RenderLayerBacking final : public GraphicsLayerClient, public CanMakeCheckedPtr<RenderLayerBacking> {
    WTF_MAKE_TZONE_ALLOCATED(RenderLayerBacking);
    WTF_MAKE_NONCOPYABLE(RenderLayerBacking);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RenderLayerBacking);
public:
    SWIFT_UNAVAILABLE_IN_SWIFT explicit RenderLayerBacking(RenderLayer&);
    ~RenderLayerBacking();

    // Do cleanup while layer->backing() is still valid.
    void willBeDestroyed(OptionSet<UpdateBackingSharingFlags>);

    RenderLayer& owningLayer() const { return m_owningLayer; }

    // Included layers are non-z-order descendant layers that are painted into this backing.
    void setBackingSharingLayers(InlineWeakKeyListHashSet<RenderLayer>&&);
    // The sharing layers in paint order, as Swift's compositing update collects them.
    void setBackingSharingLayersForSwift(const RenderLayerWeakList& list)
    {
        InlineWeakKeyListHashSet<RenderLayer> layers;
        for (auto& layer : list.m_layers) {
            if (auto* sharingLayer = layer.get())
                layers.add(*sharingLayer);
        }
        setBackingSharingLayers(WTF::move(layers));
    }

    bool hasBackingSharingLayers() const { return !m_backingSharingLayers.computeIsEmpty(); }
    RenderLayerWeakList backingSharingLayersForSwift() const
    {
        RenderLayerWeakList list;
        for (auto& layer : m_backingSharingLayers | dereferenceView)
            list.append(layer);
        return list;
    }

    void removeBackingSharingLayer(RenderLayer&, OptionSet<UpdateBackingSharingFlags>);
    void clearBackingSharingLayers(OptionSet<UpdateBackingSharingFlags>);

    void updateConfigurationAfterStyleChange();
    // The body of updateConfigurationAfterStyleChange(), called inside its LayerFreeForbiddenScope.
    SWIFT_UNSAFE void updateConfigurationAfterStyleChangeInScope();

    // Returns true if layer configuration changed.
    bool updateConfiguration(const RenderLayer* compositingAncestor);
    // The body of updateConfiguration(), called inside its LayerFreeForbiddenScope.
    SWIFT_UNSAFE bool updateConfigurationInScope(const RenderLayer* compositingAncestor);

    // Update graphics layer position and bounds.
    void updateGeometry(const RenderLayer* compositingAncestor);
    void updateAnimationExtent();

    // Update state the requires that descendant layers have been updated.
    void updateAfterDescendants();
    // The body of updateAfterDescendants(), called inside its LayerFreeForbiddenScope.
    SWIFT_UNSAFE void updateAfterDescendantsInScope();

    // Update contents and clipping structure.
    void updateDrawsContent();
    // The body of updateDrawsContent(), called inside its LayerFreeForbiddenScope.
    SWIFT_UNSAFE void updateDrawsContentInScope();
    
    void updateAfterLayout(bool needsClippingUpdate, bool needsFullRepaint);
    
    GraphicsLayer* graphicsLayer() const { return m_graphicsLayer.get(); }
    bool hasContentsDisplayDelegate() const;

    // Layer to clip children
    bool hasClippingLayer() const { return (m_childContainmentLayer && !m_isFrameLayerWithTiledBacking); }
    GraphicsLayer* clippingLayer() const { return !m_isFrameLayerWithTiledBacking ? m_childContainmentLayer.get() : nullptr; }

    // The two ancestor clipping stacks, by name.
    enum class ClippingStackName : uint8_t { Ancestor, OverflowControlsHost };
    bool hasAncestorClippingLayers() const { return !!m_ancestorClippingStack; }
    LayerAncestorClippingStack* ancestorClippingStack() const LIFETIME_BOUND { return m_ancestorClippingStack.get(); }
    bool updateAncestorClippingStack(Vector<CompositedClipData>&&);

    void ensureOverflowControlsHostLayerAncestorClippingStack(const RenderLayer* compositedAncestor);
    LayerAncestorClippingStack* overflowControlsHostLayerAncestorClippingStack() const LIFETIME_BOUND { return m_overflowControlsHostLayerAncestorClippingStack.get(); }

    // The ancestor clipping stacks for Swift, which does not import LayerAncestorClippingStack.
    bool hasAncestorClippingLayersWithScrollingForSwift() const { return m_ancestorClippingStack && m_ancestorClippingStack->hasAnyScrollingLayers(); }
    size_t ancestorClippingStackSizeForSwift() const { return m_ancestorClippingStack ? m_ancestorClippingStack->stack().size() : 0; }
    RenderLayer* overflowScrollClippingLayerForSwift(size_t index) const
    {
        if (!m_ancestorClippingStack)
            return nullptr;
        auto& clipData = m_ancestorClippingStack->stack()[index].clipData;
        return clipData.isOverflowScroll ? clipData.clippingLayer.get() : nullptr;
    }
    bool ancestorClippingStackEntryIsOverflowScrollForSwift(size_t index) const { return m_ancestorClippingStack && m_ancestorClippingStack->stack()[index].clipData.isOverflowScroll; }
    std::optional<ScrollingNodeID> ancestorClippingStackProxyNodeIDForSwift(size_t index) const
    {
        if (!m_ancestorClippingStack)
            return std::nullopt;
        return m_ancestorClippingStack->stack()[index].overflowScrollProxyNodeID;
    }
    void setAncestorClippingStackProxyNodeIDForSwift(size_t index, ScrollingNodeID nodeID)
    {
        if (m_ancestorClippingStack)
            m_ancestorClippingStack->stack()[index].overflowScrollProxyNodeID = nodeID;
    }
    GraphicsLayer* ancestorClippingStackScrollingLayerForSwift(size_t index) const { return m_ancestorClippingStack ? m_ancestorClippingStack->stack()[index].scrollingLayer.get() : nullptr; }
    GraphicsLayer* overflowControlsHostClippingFirstLayerForSwift() const { return m_overflowControlsHostLayerAncestorClippingStack ? m_overflowControlsHostLayerAncestorClippingStack->firstLayer() : nullptr; }
    GraphicsLayer* overflowControlsHostClippingLastLayerForSwift() const { return m_overflowControlsHostLayerAncestorClippingStack ? m_overflowControlsHostLayerAncestorClippingStack->lastLayer() : nullptr; }

    GraphicsLayer* contentsContainmentLayer() const { return m_contentsContainmentLayer.get(); }
    GraphicsLayer* viewportAnchorLayer() const { return m_viewportAnchorLayer.get(); }
    GraphicsLayer* viewportClippingOrAnchorLayer() const { return m_viewportClippingLayer.get() ?: viewportAnchorLayer(); }

    GraphicsLayer* foregroundLayer() const { return m_foregroundLayer.get(); }
    GraphicsLayer* backgroundLayer() const { return m_backgroundLayer.get(); }
    bool backgroundLayerPaintsFixedRootBackground() const { return m_backgroundLayerPaintsFixedRootBackground; }

    bool hasSVGPaintOrderSegments() const { return !m_svgPaintOrderSegments.isEmpty(); }
    size_t svgSegmentCountForSwift() const { return m_svgPaintOrderSegments.size(); }
    GraphicsLayer* svgSegmentLayerForSwift(size_t index) const { return m_svgPaintOrderSegments[index].graphicsLayer.get(); }
    RenderLayer* svgSegmentPrecedingCompositedChildForSwift(size_t index) const { return m_svgPaintOrderSegments[index].precedingCompositedChild.get(); }
    FloatRect svgSegmentBoundsInLayerSpaceForSwift(size_t index) const { return m_svgPaintOrderSegments[index].segmentBoundsInLayerSpace; }
    void setSVGSegmentBoundsInLayerSpaceForSwift(size_t index, FloatRect bounds) { m_svgPaintOrderSegments[index].segmentBoundsInLayerSpace = bounds; }
    FloatRect computeSVGSegmentBoundsForSwift(size_t index) { return computeSVGSegmentBounds(m_svgPaintOrderSegments[index]); }
    bool svgSegmentHasInlineContentForSwift(size_t index) { return svgSegmentHasInlineContent(m_svgPaintOrderSegments[index]); }
    NODELETE std::optional<WTF::Range<unsigned>> svgSegmentRangeForGraphicsLayer(const GraphicsLayer&) const;

#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    GraphicsLayer* systemPreviewBadgeLayer() const { return m_systemPreviewBadgeLayer.get(); }
#endif

    bool needsRepaintOnCompositedScroll() const;

    bool requiresBackgroundLayer() const { return m_requiresBackgroundLayer; }
    NODELETE void setRequiresBackgroundLayer(bool);

    bool hasScrollingLayer() const { return m_scrollContainerLayer != nullptr; }
    GraphicsLayer* scrollContainerLayer() const { return m_scrollContainerLayer.get(); }
    GraphicsLayer* scrolledContentsLayer() const { return m_scrolledContentsLayer.get(); }

    void detachFromScrollingCoordinator(OptionSet<ScrollCoordinationRole>);

    std::optional<ScrollingNodeID> scrollingNodeIDForRole(ScrollCoordinationRole role) const
    {
        switch (role) {
        case ScrollCoordinationRole::Scrolling:
            return m_scrollingNodeID;
        case ScrollCoordinationRole::ScrollingProxy:
            // These nodeIDs are stored in m_ancestorClippingStack.
            ASSERT_NOT_REACHED();
            return std::nullopt;
        case ScrollCoordinationRole::FrameHosting:
            return m_frameHostingNodeID;
        case ScrollCoordinationRole::PluginHosting:
            return m_pluginHostingNodeID;
        case ScrollCoordinationRole::ViewportConstrained:
            return m_viewportConstrainedNodeID;
        case ScrollCoordinationRole::Positioning:
            return m_positioningNodeID;
        }
        return std::nullopt;
    }

    bool hasAnyScrollingNodeID() const
    {
        return m_scrollingNodeID || m_frameHostingNodeID || m_pluginHostingNodeID
            || m_viewportConstrainedNodeID || m_positioningNodeID || m_ancestorClippingStack;
    }

    void setScrollingNodeIDForRole(ScrollingNodeID, ScrollCoordinationRole);

    // The features a build can override that the backing's Swift tests.
#if ENABLE(VIDEO)
    static constexpr bool videoEnabledForSwift() { return true; }
#else
    static constexpr bool videoEnabledForSwift() { return false; }
#endif
    static bool shouldForceInvertBitmapImageForSwift(RenderImage&);
#if ENABLE(MODEL_ELEMENT)
    static constexpr bool modelElementEnabledForSwift() { return true; }
#else
    static constexpr bool modelElementEnabledForSwift() { return false; }
#endif
#if ENABLE(MODEL_PROCESS)
    static constexpr bool modelProcessEnabledForSwift() { return true; }
#else
    static constexpr bool modelProcessEnabledForSwift() { return false; }
#endif
#if USE(CA)
    static constexpr bool usesCAForSwift() { return true; }
#else
    static constexpr bool usesCAForSwift() { return false; }
#endif
#if ENABLE(WEBGL) || ENABLE(OFFSCREEN_CANVAS)
    static constexpr bool webGLOrOffscreenCanvasEnabledForSwift() { return true; }
#else
    static constexpr bool webGLOrOffscreenCanvasEnabledForSwift() { return false; }
#endif

    bool hasMaskLayer() const { return m_maskLayer; }

    NODELETE WEBCORE_EXPORT GraphicsLayer* parentForSublayers() const;
    GraphicsLayer* childForSuperlayers() const;
    GraphicsLayer* childForSuperlayersExcludingViewTransitions() const;

    // RenderLayers with backing normally short-circuit paintLayer() because
    // their content is rendered via callbacks from GraphicsLayer. However, the document
    // layer is special, because it has a GraphicsLayer to act as a container for the GraphicsLayers
    // for descendants, but its contents usually render into the window (in which case this returns true).
    // This returns false for other layers, and when the document layer actually needs to paint into its backing store
    // for some reason.
    bool paintsIntoWindow() const;

    // Returns true for a composited layer that has no backing store of its own, so
    // paints into some ancestor layer.
    bool paintsIntoCompositedAncestor() const { return !m_requiresOwnBackingStore; }

    void setRequiresOwnBackingStore(bool);

    void setContentsNeedDisplay(GraphicsLayerShouldClipToLayer = GraphicsLayerShouldClipToLayer::Clip);
    // r is in the coordinate space of the layer's render object
    void setContentsNeedDisplayInRect(LayoutRect, GraphicsLayerShouldClipToLayer = GraphicsLayerShouldClipToLayer::Clip);

    // Notification from the renderer that its content changed.
    void contentChanged(ContentChangeType, const std::optional<FloatRect>&);
    // The body of contentChanged(), called inside its LayerFreeForbiddenScope.
    SWIFT_UNSAFE void contentChangedInScope(ContentChangeType, std::optional<FloatRect>);

    // Interface to start and finish animations.
    bool startAnimation(double timeOffset, const GraphicsLayerAnimation&, NOESCAPE BlendingKeyframesView, IntOutsets filterAnimationOutsets);
    void animationPaused(double timeOffset, String name);
    void animationFinished(String name);
    void transformRelatedPropertyDidChange();

    const IntOutsets& filterAnimationOutsets() const { return m_filterAnimationOutsets; }
    IntOutsets filterAnimationOutsetsForSwift() const { return m_filterAnimationOutsets; }
    // max() of two outsets, which Swift cannot call.
    static IntOutsets maxOutsetsForSwift(const IntOutsets& a, const IntOutsets& b) { return max(a, b); }

#if ENABLE(THREADED_ANIMATIONS)
    NODELETE const AcceleratedEffectStack* acceleratedEffectStack() const;
    void updateAcceleratedEffectsAndBaseValues(HashSet<Ref<AcceleratedTimeline>>&);
#endif

    WEBCORE_EXPORT LayoutRect compositedBounds() const;
    // Returns true if changed.
    bool setCompositedBounds(LayoutRect);
    // Returns true if changed.
    bool updateCompositedBounds();
    
    void updateAllowsBackingStoreDetaching(bool allowDetachingForFixed);

#if ENABLE(ASYNC_SCROLLING)
    bool maintainsEventRegion() const;
    void updateEventRegion();
    // The document and page conditions of maintainsEventRegion() that depend on the platform's features.
    bool documentOrPageRequiresEventRegion() const;
    
    bool needsEventRegionUpdate() const { return m_needsEventRegionUpdate; }
    NODELETE void setNeedsEventRegionUpdate(bool needsUpdate = true);
#endif

#if ENABLE(INTERACTION_REGIONS_IN_EVENT_REGION)
    void clearInteractionRegions();
#endif

#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    void updateSeparatedProperties();
#endif

    void updateAfterWidgetResize();
    void positionOverflowControlsLayers();
    
    bool isFrameLayerWithTiledBacking() const { return m_isFrameLayerWithTiledBacking; }

    WEBCORE_EXPORT TiledBacking* tiledBacking() const;
    void adjustTiledBackingCoverage();
    void setTiledBackingHasMargins(BoxSideSet);
    
    void updateDebugIndicators(bool showBorder, bool showRepaintCounter);

    // GraphicsLayerClient interface
    void tiledBackingUsageChanged(const GraphicsLayer*, bool /*usingTiledBacking*/) override;
    void notifyAnimationStarted(const GraphicsLayer*, const String& animationKey, MonotonicTime startTime) override;
    void notifyFlushRequired(const GraphicsLayer*) override;
    void notifySubsequentFlushRequired(const GraphicsLayer*) override;

    void paintContents(const GraphicsLayer&, GraphicsContext&, const FloatRect& clip, OptionSet<GraphicsLayerPaintBehavior>) override;

    float deviceScaleFactor() const override;
    float contentsScaleMultiplierForNewTiles(const GraphicsLayer*) const override;

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    bool layerAllowsDynamicContentScaling(const GraphicsLayer*) const override;
#endif

    bool paintsOpaquelyAtNonIntegralScales(const GraphicsLayer*) const override;

    float pageScaleFactor() const override;
    float zoomedOutPageScaleFactor() const override;
    bool delegatesScaling() const override;

    FloatSize enclosingFrameViewVisibleSize() const override;

    void didChangePlatformLayerForLayer(const GraphicsLayer*) override;
    bool getCurrentTransform(const GraphicsLayer*, TransformationMatrix&) const override;

    bool isFlushingLayers() const override;
    bool isTrackingRepaints() const override;
    bool shouldSkipLayerInDump(const GraphicsLayer*, OptionSet<LayerTreeAsTextOptions>) const override;
    bool shouldDumpPropertyForLayer(const GraphicsLayer*, ASCIILiteral propertyName, OptionSet<LayerTreeAsTextOptions>) const override;

    bool shouldAggressivelyRetainTiles(const GraphicsLayer*) const override;
    bool shouldTemporarilyRetainTileCohorts(const GraphicsLayer*) const override;
    bool useGiantTiles() const override;
    bool cssUnprefixedBackdropFilterEnabled() const override;
    void logFilledVisibleFreshTile(unsigned) override;
    bool needsPixelAligment() const override { return !m_isMainFrameRenderViewLayer; }

    OptionSet<ContentsFormat> screenContentsFormats() const override;

    LayoutSize subpixelOffsetFromRenderer() const { return m_subpixelOffsetFromRenderer; }

#if ENABLE(SPATIAL_PORTAL)
    SpatialPortalController* hostingSpatialPortalController() const;
    void updateHostedPromotedChildren();
#endif

    TransformationMatrix transformMatrixForProperty(AnimatedProperty) const final;

    void dumpProperties(const GraphicsLayer*, TextStream&, OptionSet<LayerTreeAsTextOptions>) const final;

#if PLATFORM(IOS_FAMILY)
    bool needsIOSDumpRenderTreeMainFrameRenderViewLayerIsAlwaysOpaqueHack(const GraphicsLayer&) const override;
#endif

#ifndef NDEBUG
    void verifyNotPainting() override;
#endif

    WEBCORE_EXPORT LayoutRect contentsBox() const;

    // Like contentsBox(), but for video, never applies the object-view-box crop-bypass or the
    // object-fit: cover overflow — used as the fullscreen/PiP transition-anchor rect, which must
    // reflect the video's true on-screen inline box, not compositing-only crop geometry.
    WEBCORE_EXPORT LayoutRect inlineVideoContentsBox() const;

    // For informative purposes only.
    WEBCORE_EXPORT CompositingLayerType compositingLayerType() const;
    
    GraphicsLayer* layerForHorizontalScrollbar() const { return m_layerForHorizontalScrollbar.get(); }
    GraphicsLayer* layerForVerticalScrollbar() const { return m_layerForVerticalScrollbar.get(); }
    GraphicsLayer* layerForScrollCorner() const { return m_layerForScrollCorner.get(); }
    GraphicsLayer* overflowControlsContainer() const { return m_overflowControlsContainer.get(); }

    GraphicsLayer* layerForContents() const;

    void adjustOverflowControlsPositionRelativeToAncestor(const RenderLayer&);

    bool canCompositeFilters() const { return m_canCompositeFilters; }
    bool canCompositeBackdropFilters() const { return m_canCompositeBackdropFilters; }

    // Return an estimate of the backing store area (in pixels) allocated by this object's GraphicsLayers.
    WEBCORE_EXPORT double backingStoreMemoryEstimate() const;
    
    // For testing only.
    WEBCORE_EXPORT void setUsesDisplayListDrawing(bool);
    WEBCORE_EXPORT String displayListAsText(OptionSet<DisplayList::AsTextFlag>) const;

    WEBCORE_EXPORT void setIsTrackingDisplayListReplay(bool);
    WEBCORE_EXPORT String replayDisplayListAsText(OptionSet<DisplayList::AsTextFlag>) const;

    bool shouldPaintUsingCompositeCopy() const { return m_shouldPaintUsingCompositeCopy; }

    void purgeFrontBufferForTesting();
    void purgeBackBufferForTesting();
    void markFrontBufferVolatileForTesting();
private:
    // Called only by the constructor and the destructor.
    SWIFT_UNSAFE void createPrimaryGraphicsLayer();
    SWIFT_UNSAFE void destroyGraphicsLayers();
    SWIFT_UNSAFE void clearAncestorClippingStack();

    OptionSet<RenderLayer::PaintLayerFlag> paintFlagsForLayer(const GraphicsLayer&) const;
    LayoutRect compositedBoundsIncludingMargin() const;

    FloatRect backgroundBoxForSimpleContainerPainting() const;


    void updateAppliesPageScale();
    
    void willDestroyLayer(const GraphicsLayer*);

    SWIFT_UNAVAILABLE_IN_SWIFT Ref<GraphicsLayer> createGraphicsLayer(const String&, GraphicsLayerType = GraphicsLayerType::Normal);

    // GraphicsLayer creation for Swift, which cannot pass the backing as the layer's client or compose the layer's name.
    enum class GraphicsLayerName : uint8_t {
        Primary, PageTiledBackingContainment, Foreground, Background, ContentsContainment, ViewportAnchor, ViewportClipping,
        ChildClipping, Mask, TransformFlattening, HorizontalScrollbar, VerticalScrollbar, ScrollCorner, OverflowControlsContainer,
        ScrollContainer, ScrolledContents,
    };
    // Each name has its own field. A field's layer has the backing as its client, so the backing clears it before dropping it.
    void createGraphicsLayer(GraphicsLayerName, GraphicsLayerType);
    void unparentAndClearGraphicsLayer(GraphicsLayerName);
    // Drops the layer of the name if there is one, after willDestroyLayer(), and returns whether there was one.
    bool destroyGraphicsLayer(GraphicsLayerName);
    void clearGraphicsLayer(GraphicsLayerName);
    GraphicsLayer* graphicsLayerForSwift(GraphicsLayerName name) { return graphicsLayerField(name).get(); }
    SWIFT_UNAVAILABLE_IN_SWIFT RefPtr<GraphicsLayer>& graphicsLayerField(GraphicsLayerName);
    static bool isSameGraphicsLayer(const GraphicsLayer* a, const GraphicsLayer* b) { return a == b; }
    // The entries of the ancestor clipping stacks for Swift, by stack and index. An entry's layers have the backing as
    // their client, like the backing's own, so C++ creates and drops them.
    enum class ClippingStackLayerName : uint8_t { Clipping, Scrolling, ShapeMask };
    bool hasClippingStack(ClippingStackName name) const { return clippingStack(name); }
    size_t clippingStackSize(ClippingStackName) const;
    bool clippingStackEntryIsOverflowScroll(ClippingStackName, size_t) const;
    bool clippingStackEntryNeedsShapeMask(ClippingStackName, size_t) const;
    LayoutRect clippingStackEntryClipRect(ClippingStackName, size_t) const;
    RenderLayer* clippingStackEntryClippingLayer(ClippingStackName, size_t) const;
    // Sets the entry's clipping rect, and its shape mask when the clip is not a rounded rect.
    void updateClippingStackEntryContentsClipping(ClippingStackName, size_t, FloatSize snappedClippingLayerSize);
    GraphicsLayer* clippingStackEntryLayer(ClippingStackName, size_t, ClippingStackLayerName) const;
    void createClippingStackEntryLayer(ClippingStackName, size_t, ClippingStackLayerName);
    void unparentAndClearClippingStackEntryLayer(ClippingStackName, size_t, ClippingStackLayerName);
    // Drops the stack, after removing its scrolling nodes and layers.
    void clearClippingStack(ClippingStackName);
    // Drops the stack as it is.
    void destroyClippingStack(ClippingStackName name) { clippingStackField(name) = nullptr; }
    void detachAncestorClippingStackFromScrollingCoordinator()
    {
        RELEASE_ASSERT(m_ancestorClippingStack);
        m_ancestorClippingStack->detachFromScrollingCoordinator(compositor());
    }
    SWIFT_UNAVAILABLE_IN_SWIFT LayerAncestorClippingStack* clippingStack(ClippingStackName) const;
    SWIFT_UNAVAILABLE_IN_SWIFT std::unique_ptr<LayerAncestorClippingStack>& clippingStackField(ClippingStackName);
    SWIFT_UNAVAILABLE_IN_SWIFT RefPtr<GraphicsLayer>& clippingStackEntryLayerField(ClippingStackName, size_t, ClippingStackLayerName) const;

    // The canvas, the style, the scrolling coordinator and chrome client calls, and another platform's layers, which
    // Swift cannot reach.
    bool canvasShouldAccelerate() const;
    void clearCanvasContentsFromLayer();
    bool clipPathIsReferencePath() const;
    bool viewHasTransparentBackgroundForSwift() const { return compositor().viewHasTransparentBackground(); }
    bool viewHasTransparentBackgroundForSwift(Color& backgroundColor) const { return compositor().viewHasTransparentBackground(&backgroundColor); }
    bool canDirectlyCompositeBackgroundImage() const;
    bool boxPaintsOwnBackground() const;
    bool updateSystemPreviewBadgeLayerForSwift();
    bool scrollContainerClipHasNonZeroRadii() const;
    bool updateContentsLayerForReplacedRenderer();
    LayoutRect clippingLayerBoxForSwift() const;
    bool rendererHasNonZeroTransformOrigin() const;
    RenderLayer::OptionalLayoutRect viewTransitionCaptureOverflowRect() const;
    FloatRoundedRect innerBorderShapeContentsClippingRect(FloatSize offsetFromRenderer) const;
    // The replaced content's clipping rect for its border shape (and a video's box), setting the primary layer's clip shape path.
    FloatRoundedRect replacedContentsClippingRect(const RenderReplaced&, bool clipToVideoBox);
    // Sets the contents clipping of a separated layer's box (and of a spatial portal's) to its border shape.
    bool updateContentsClippingForSeparatedLayer(bool includeSpatialPortal);
    // The backdrop filters' rect for a box's rounded border shape, setting the primary layer's backdrop shape path.
    FloatRoundedRect backdropFiltersRoundedRect(const RenderBox&);
    // Sets the clip shape path of the layer that clips children (m_childContainmentLayer) to a box's border shape.
    void setClippingLayerContentsClipShapePath(GraphicsLayer&) const;
    bool rendererIsRunningOrAboutToRunAcceleratedTransformRelatedAnimation() const;
    void rendererSizeMayHaveChanged();
    // The spatial portal calls of updateAfterDescendants(), updateGeometry() and createPrimaryGraphicsLayer(), and whether
    // the layer is a promoted child of a spatial portal or in one, which do nothing or are false without ENABLE(SPATIAL_PORTAL).
    void updatePortalPromotedChildrenForSwift();
    void updateIsHostedInSpatialPortalSceneForSwift();
    bool isInPromotedSpatialPortalChildForSwift() const;
    void updateSystemPreviewBadgeLayerGeometryForSwift();
    void setNeedsTextBackdropUpdateForCustomColorMode();
    unsigned frameTreeDepthForSwift() const;
    void scrollableAreaScrollbarLayerDidChange(ScrollbarOrientation);
    void setNeedsFixedContainerEdgesUpdateViaChromeClient();
    bool updateContentsContainmentLayerForSwift();
#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    GraphicsLayer* systemPreviewWrapperLayerForSwift() const { return m_systemPreviewWrapperLayer.get(); }
    GraphicsLayer* systemPreviewBadgeLayerForSwift() const { return m_systemPreviewBadgeLayer.get(); }
#else
    GraphicsLayer* systemPreviewWrapperLayerForSwift() const { return nullptr; }
    GraphicsLayer* systemPreviewBadgeLayerForSwift() const { return nullptr; }
#endif
    void unparentAndClearSystemPreviewLayers();

    GraphicsLayer* maskLayer() const { return m_maskLayer.get(); }
    GraphicsLayer* transformFlatteningLayer() const { return m_transformFlatteningLayer.get(); }
    GraphicsLayer* childContainmentLayer() const { return m_childContainmentLayer.get(); }

    RenderLayerModelObject& renderer() const { return m_owningLayer.renderer(); }
    RenderBox* renderBox() const { return m_owningLayer.renderBox(); }
    RenderLayerCompositor& compositor() const { return m_owningLayer.compositor(); }

    void updateInternalHierarchy();
    bool updateViewportConstrainedSublayers(ViewportConstrainedSublayers);
    bool updateAncestorClipping(bool needsAncestorClip, const RenderLayer* compositingAncestor);
    bool updateDescendantClippingLayer(bool needsDescendantClip);
    bool updateOverflowControlsLayers(bool needsHorizontalScrollbarLayer, bool needsVerticalScrollbarLayer, bool needsScrollCornerLayer);
    void clearOverflowControlsLayers();
    bool updateForegroundLayer(bool needsForegroundLayer);
    bool updateBackgroundLayer(bool needsBackgroundLayer);

    // SVG paint-order segmentation. Out-of-line methods are defined in RenderLayerBackingSVGAdditions.cpp.
    struct SVGPaintOrderSegment;
    bool updateSVGSegmentLayers();
    void clearSVGSegmentLayers();
    template<typename Function> void forEachSVGSegmentLayer(NOESCAPE const Function& function) const
    {
        for (auto& segment : m_svgPaintOrderSegments) {
            if (segment.graphicsLayer)
                function(*segment.graphicsLayer);
        }
    }
    FloatRect computeSVGSegmentBounds(const SVGPaintOrderSegment&);
    bool svgSegmentHasInlineContent(const SVGPaintOrderSegment&);

#if ENABLE(MODEL_PROCESS)
    bool updateContentsContainmentLayer();
#endif
    bool updateMaskingLayer(bool hasMask, bool hasClipPath);
    void updateReflectionLayer();
    bool updateTransformFlatteningLayer(const RenderLayer* compositingAncestor);
#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    bool updateSystemPreviewBadgeLayer(bool needsLayer);
    bool needsSystemPreviewBadgeLayer() const;
    void updateSystemPreviewBadgeLayerGeometry();
    void paintSystemPreviewBadgeLayer(GraphicsContext&, const FloatRect& clip);
#endif

    bool requiresLayerForScrollbar(Scrollbar*) const;
    bool requiresHorizontalScrollbarLayer() const;
    bool requiresVerticalScrollbarLayer() const;
    bool requiresScrollCornerLayer() const;
    bool updateScrollingLayers(bool scrollingLayers);
    
    // The mask layer's shape for a clip-path, in the renderer's coordinates.
    Path clipPathForMaskLayer(LayoutRect referenceBoxForClippedInline, LayoutSize offset, WindRule&) const;

    void setBackgroundLayerPaintsFixedRootBackground(bool);

    // The offset from the top-left of this compositing layer at which the renderer's contents are painted.
    LayoutSize contentOffsetInCompositingLayer() const;
    LayoutSize offsetRelativeToRendererOriginForDescendantLayers() const;
    
    void ensureClippingStackLayers(ClippingStackName);
    void removeClippingStackLayers(ClippingStackName);

    // Returns the parent graphics layer rect for the layers inside the stack.
    LayoutRect updateClippingStackLayerGeometry(ClippingStackName, const RenderLayer* compositedAncestor, LayoutRect parentGraphicsLayerRect);

    void connectClippingStackLayers(ClippingStackName);

#if ENABLE(SPATIAL_PORTAL)
    void configureSpatialPortalLayer(SpatialPortalController&);
    void updatePortalPromotedChildren(SpatialPortalController&);
    void updateIsHostedInSpatialPortalScene();
    SpatialPortalController* promotedChildPortalController() const;
#endif
    void updateTransform(const Style::ComputedStyle&);
    void updateChildrenTransformAndAnchorPoint(LayoutRect primaryGraphicsLayerRect, LayoutSize offsetFromParentGraphicsLayer);
    void updateFilters(const Style::ComputedStyle&);
    void updateBackdropFilters(const Style::ComputedStyle&);
    bool updateBackdropRoot();
    void updateScreenCaptureProtection();
#if HAVE(CORE_MATERIAL)
    void updateAppleVisualEffect(const Style::ComputedStyle&);
#endif

    // Return the opacity value that this layer should use for compositing.
    NODELETE float compositingOpacity(float rendererOpacity) const;
    Color rendererBackgroundColor() const;

    bool isMainFrameRenderViewLayer() const;
    
#if HAVE(SUPPORT_HDR_DISPLAY)
    void updateDrawsHDRContent(bool);
#endif

    // Swift has no downcast of a renderer or an image. Each is null when it is not of the type.
    const RenderReplaced* rendererAsRenderReplaced() const;
    const RenderVideo* rendererAsRenderVideo() const;
    // The canvas and view transition capture facts, for a renderer of that type, which Swift cannot name.
    bool canvasHasDrawableContent() const;
    IntSize canvasElementSize() const;
    bool viewTransitionCaptureHasDisplayOnlyImage() const;
    bool viewTransitionCaptureImageIsDirectlyComposited() const;
    void setViewTransitionCaptureImageAsContents();
    LayoutRect viewTransitionCaptureLocalOverflowRect() const;
    static BitmapImage* asBitmapImage(Image*);
    bool rendererMayHaveNonZeroOpacity() const;
    bool rendererIsSpatialPortal() const;
    bool rendererHostsRemoteFrame() const;
    static RefPtr<NativeImage> nativeImageForDirectlyCompositedImage(Image&);
    bool isBitmapOnly() const;

    bool updateDirectlyCompositedBackgroundImage(bool isSimpleContainer);

    void updateContentsRects();

    bool shouldClipCompositedBounds() const;
    static IntOutsets filterSamplingOutsets(const RenderLayer&);
    static IntOutsets accumulatedFilterSamplingOutsets(const IntOutsets& accumulatedOutsets, const IntOutsets&);
    static bool ancestorLayerMayClipForSwift(const RenderLayer&, const RenderLayer& ancestorLayer, bool isContainingBlockChain);
    void updateFilterAnimationOutsets();
    // Records the filter outsets of the keyframes' animation when hasFilterAnimationOutsets, and forgets them otherwise.
    void updateFilterAnimationOutsetsForSwift(NOESCAPE BlendingKeyframesView, bool hasFilterAnimationOutsets, IntOutsets filterAnimationOutsets);
    void removeFilterAnimationOutsetsForSwift(const String& animationName);
    // Adds the animation of one property to the primary layer, with the values of the keyframes that animate it, which
    // Swift cannot convert from their styles.
    bool addAnimationForSwift(AnimatedProperty, NOESCAPE BlendingKeyframesView, FloatSize referenceBoxSize, const GraphicsLayerAnimation&, double timeOffset);

    bool hasTiledBackingFlatteningLayer() const { return (m_childContainmentLayer && m_isFrameLayerWithTiledBacking); }
    GraphicsLayer* tileCacheFlatteningLayer() const { return m_isFrameLayerWithTiledBacking ? m_childContainmentLayer.get() : nullptr; }

    void paintIntoLayer(const GraphicsLayer*, GraphicsContext&, const IntRect& paintDirtyRect, OptionSet<PaintBehavior>, RegionContext* = nullptr);
    void paintDebugOverlays(const GraphicsLayer*, GraphicsContext&);


    bool canIssueSetNeedsDisplay() const { return !paintsIntoWindow() && !paintsIntoCompositedAncestor(); }
    NODELETE float pixelSnappingScaleFactor() const;
    LayoutRect computeParentGraphicsLayerRect(const RenderLayer* compositedAncestor) const;

    bool shouldSetContentsDisplayDelegate() const;

    void setNeedsFixedContainerEdgesUpdateIfNeeded();

    RenderLayer& m_owningLayer;
    
    // A list other layers that paint into this backing store, later than m_owningLayer in paint order.
    InlineWeakKeyListHashSet<RenderLayer> m_backingSharingLayers;

    SWIFT_UNSAFE std::unique_ptr<LayerAncestorClippingStack> m_ancestorClippingStack; // Only used if we are clipped by an ancestor which is not a stacking context.
    SWIFT_UNSAFE std::unique_ptr<LayerAncestorClippingStack> m_overflowControlsHostLayerAncestorClippingStack; // Used when we have an overflow controls host layer which was reparented, and needs clipping by ancestors.

    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_contentsContainmentLayer; // Only used if we have a background layer; takes the transform.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_graphicsLayer;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_foregroundLayer; // Only used in cases where we need to draw the foreground separately.

    // A composited SVG child splits its container's DOM-order paint list (childrenInDOMOrderForSVG) at its
    // index. Non-composited content painting after a composited child goes into a single overlay
    // "(svg segment N)" GraphicsLayer above the composited child's layer, rather than giving each such
    // sibling its own RenderLayer. Segments cover the flat list in order: the primary segment =
    // [0, firstCompositedChild] paints into the primary graphics layer (null graphicsLayer). Each later
    // segment = (prevCompositedChild, thisCompositedChild] paints into its own overlay.
    struct SVGPaintOrderSegment {
        WTF::Range<unsigned> childIndexRange { 0, 0 }; // Half-open [begin, end) into childrenInDOMOrderForSVG().
        InlineWeakPtr<RenderLayer> precedingCompositedChild; // null for the primary segment.
        RefPtr<GraphicsLayer> graphicsLayer; // null for the primary segment (paints into the primary graphics layer).
        // Visual bounds of this segment's inline-painted content in the overlay's own (foreground-local)
        // coordinate space. Set in updateGeometry, empty if not cropped. Scopes the overlay's invalidation.
        FloatRect segmentBoundsInLayerSpace;
    };
    SWIFT_UNSAFE Vector<SVGPaintOrderSegment> m_svgPaintOrderSegments; // Only used for SVG container layers; empty unless a composited child splits the paint list.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_backgroundLayer; // Only used in cases where we need to draw the background separately.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_childContainmentLayer; // Only used if we have clipping on a stacking context with compositing children, or if the layer has a tile cache.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_viewportClippingLayer; // Only used on fixed/sticky elements. Contains the viewport anchor layer.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_viewportAnchorLayer; // Only used on fixed/sticky elements.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_maskLayer; // Only used if we have a mask and/or clip-path.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_transformFlatteningLayer;
#if USE(SYSTEM_PREVIEW) && ENABLE(MODEL_PROCESS)
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_systemPreviewWrapperLayer; // Outer wrapper above m_contentsContainmentLayer, parents the model subtree and the badge layer as siblings.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_systemPreviewBadgeLayer; // Sibling of m_contentsContainmentLayer; lifts the AR badge in front of the model's separated portal on visionOS.
#endif

    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForHorizontalScrollbar;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForVerticalScrollbar;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForScrollCorner;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_overflowControlsContainer;

    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_scrollContainerLayer; // Only used if the layer is using composited scrolling.
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_scrolledContentsLayer; // Only used if the layer is using composited scrolling.

    LayoutRect m_compositedBounds;
    LayoutSize m_subpixelOffsetFromRenderer; // This is the subpixel distance between the primary graphics layer and the associated renderer's bounds.
    LayoutSize m_compositedBoundsOffsetFromGraphicsLayer; // This is the subpixel distance between the primary graphics layer and the render layer bounds.

    HashMap<String, IntOutsets> m_filterAnimationOutsetsByName;
#if ENABLE(THREADED_ANIMATIONS)
    IntOutsets m_filterAnimationOutsetsFromAcceleratedEffects;
#endif
    IntOutsets m_filterAnimationOutsets;

    Markable<ScrollingNodeID> m_viewportConstrainedNodeID;
    Markable<ScrollingNodeID> m_scrollingNodeID;
    Markable<ScrollingNodeID> m_frameHostingNodeID;
    Markable<ScrollingNodeID> m_pluginHostingNodeID;
    Markable<ScrollingNodeID> m_positioningNodeID;

    bool m_artificiallyInflatedBounds { false }; // bounds had to be made non-zero to make transform-origin work
    bool m_isMainFrameRenderViewLayer { false };
    bool m_isRootFrameRenderViewLayer { false };
    bool m_isFrameLayerWithTiledBacking { false };
    bool m_requiresOwnBackingStore { true };
    bool m_canCompositeFilters { false };
    bool m_canCompositeBackdropFilters { false };
    bool m_backgroundLayerPaintsFixedRootBackground { false };
    bool m_requiresBackgroundLayer { false };
    bool m_hasSubpixelRounding { false };
#if ENABLE(ASYNC_SCROLLING)
    bool m_needsEventRegionUpdate { true };
#endif
    bool m_shouldPaintUsingCompositeCopy { false };

    // Swift retains and releases a backing through its checked pointer count. If C++ destroys one while Swift holds it,
    // its memory is zero-filled and not freed, so Swift's next use faults. A function that returns one leaves it owned
    // by C++, and Swift retains it.
} SWIFT_SHARED_REFERENCE(.incrementCheckedPtrCount, .decrementCheckedPtrCount) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/RenderLayerBacking.swift");

enum CanvasCompositingStrategy {
    CanvasPaintedToEnclosingLayer,
    CanvasPaintedToLayer,
    CanvasAsLayerContents
};
CanvasCompositingStrategy canvasCompositingStrategy(const RenderObject&);

WTF::TextStream& operator<<(WTF::TextStream&, const RenderLayerBacking&);

} // namespace WebCore
