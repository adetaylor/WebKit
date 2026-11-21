/*
 * Copyright (C) 2009, 2013 Apple Inc. All rights reserved.
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

#include <WebCore/ChromeClient.h>
#include <WebCore/GraphicsLayerClient.h>
#include <WebCore/LayerAncestorClippingStack.h>
#include <WebCore/RenderGeometryMap.h>
#include <WebCore/RenderLayer.h>
#include <pal/HysteresisActivity.h>
#include <wtf/CheckedPtr.h>
#include <wtf/HashMap.h>
#include <wtf/InlineWeakPtr.h>
#include <wtf/ObjectIdentifier.h>
#include <wtf/OptionSet.h>
#include <wtf/Platform.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakHashSet.h>

namespace WebCore {

class DisplayRefreshMonitorFactory;
class FixedPositionViewportConstraints;
class GraphicsLayer;
class LocalFrameView;
class RenderEmbeddedObject;
class RenderVideo;
class RenderWidget;
class ScrollingCoordinator;
class Settings;
class StickyPositionViewportConstraints;
class TiledBacking;

enum class CompositingPolicy : bool;
enum class ScrollingNodeType : uint8_t;

enum class CompositingUpdateType {
    AfterStyleChange,
    AfterLayout,
    OnScroll,
    OnCompositedScroll
};

enum class CompositingReason : uint64_t {
    Transform3D                            = 1LLU << 0,
    Video                                  = 1LLU << 1,
    Canvas                                 = 1LLU << 2,
    Plugin                                 = 1LLU << 3,
    IFrame                                 = 1LLU << 4,
    BackfaceVisibilityHidden               = 1LLU << 5,
    ClipsCompositingDescendants            = 1LLU << 6,
    Animation                              = 1LLU << 7,
    Filters                                = 1LLU << 8,
    PositionFixed                          = 1LLU << 9,
    PositionSticky                         = 1LLU << 10,
    OverflowScrolling                      = 1LLU << 11,
    Stacking                               = 1LLU << 12,
    Overlap                                = 1LLU << 13,
    OverflowScrollPositioning              = 1LLU << 14,
    NegativeZIndexChildren                 = 1LLU << 15,
    TransformWithCompositedDescendants     = 1LLU << 16,
    OpacityWithCompositedDescendants       = 1LLU << 17,
    MaskWithCompositedDescendants          = 1LLU << 18,
    ReflectionWithCompositedDescendants    = 1LLU << 19,
    FilterWithCompositedDescendants        = 1LLU << 20,
    BlendingWithCompositedDescendants      = 1LLU << 21,
    Perspective                            = 1LLU << 22,
    Preserve3D                             = 1LLU << 23,
    WillChange                             = 1LLU << 24,
    Root                                   = 1LLU << 25,
    IsolatesCompositedBlendingDescendants  = 1LLU << 26,
    Model                                  = 1LLU << 27,
    BackdropRoot                           = 1LLU << 28,
    AnchorPositioning                      = 1LLU << 29,
    SpatialPortal                          = 1LLU << 30,
    SpatialPortalHosting                   = 1LLU << 31,
    ScreenCaptureProtection                = 1LLU << 32,
};

enum class ScrollCoordinationRole {
    ViewportConstrained = 1 << 0,
    Scrolling           = 1 << 1,
    ScrollingProxy      = 1 << 2,
    FrameHosting        = 1 << 3,
    PluginHosting       = 1 << 4,
    Positioning         = 1 << 5,
};

using OptionalScrollingNodeID = std::optional<ScrollingNodeID>;

struct ScrollingTreeState {
    Markable<ScrollingNodeID> parentNodeID;
    bool hasParent { false };
    size_t nextChildIndex { 0 };
    bool needSynchronousScrollingReasonsUpdate { false };

    std::optional<ScrollingNodeID> parentNodeIDForSwift() const { return parentNodeID; }
    void setParentNodeIDForSwift(std::optional<ScrollingNodeID> nodeID) { parentNodeID = nodeID; }
};

// A GraphicsLayer child list that Swift builds and hands to GraphicsLayer::setChildren().
class GraphicsLayerChildList {
public:
    void append(GraphicsLayer& layer) { m_layers.append(layer); }
    void setAsChildrenOf(GraphicsLayer& parent) { parent.setChildren(WTF::move(m_layers)); }

private:
    Vector<Ref<GraphicsLayer>> m_layers;
};

// The scrolling node IDs and the slow repaint renderers a scrolling tree update reads, for Swift, which does not
// iterate a HashSet or a Vector.
class ScrollingNodeIDList {
public:
    void append(ScrollingNodeID nodeID) { m_nodeIDs.append(nodeID); }
    void remove(ScrollingNodeID nodeID) { m_nodeIDs.removeFirst(nodeID); }
    size_t size() const { return m_nodeIDs.size(); }
    ScrollingNodeID at(size_t index) const { return m_nodeIDs[index]; }
    Vector<ScrollingNodeID> takeNodeIDs() { return WTF::move(m_nodeIDs); }

private:
    Vector<ScrollingNodeID> m_nodeIDs;
};

class RenderElementList {
public:
    size_t size() const { return m_renderers.size(); }
    RenderElement* rendererAt(size_t index) const;

private:
    friend class RenderLayerCompositor;
    Vector<SingleThreadWeakPtr<RenderElement>> m_renderers;
};

enum class ViewportConstrainedSublayers : uint8_t {
    None,
    Anchor,
    ClippingAndAnchor,
};

static constexpr OptionSet<ScrollCoordinationRole> allScrollCoordinationRoles()
{
    return {
        ScrollCoordinationRole::Scrolling,
        ScrollCoordinationRole::ScrollingProxy,
        ScrollCoordinationRole::ViewportConstrained,
        ScrollCoordinationRole::FrameHosting,
        ScrollCoordinationRole::PluginHosting,
        ScrollCoordinationRole::Positioning
    };
}

#if PLATFORM(IOS_FAMILY)
class LegacyWebKitScrollingLayerCoordinator {
    WTF_MAKE_TZONE_ALLOCATED(LegacyWebKitScrollingLayerCoordinator);
public:
    LegacyWebKitScrollingLayerCoordinator(ChromeClient& chromeClient, bool coordinateViewportConstrainedLayers)
        : m_chromeClient(chromeClient)
        , m_coordinateViewportConstrainedLayers(coordinateViewportConstrainedLayers)
    {
    }

    void registerAllViewportConstrainedLayers(RenderLayerCompositor&);
    void unregisterAllViewportConstrainedLayers();
    
    void registerAllScrollingLayers();
    void unregisterAllScrollingLayers();
    
    void addScrollingLayer(RenderLayer&);
    void removeScrollingLayer(RenderLayer&, RenderLayerBacking&);

    void addViewportConstrainedLayer(RenderLayer&);
    void removeViewportConstrainedLayer(RenderLayer&);

    void removeLayer(RenderLayer&);

private:
    void updateScrollingLayer(RenderLayer&);

    ChromeClient& m_chromeClient;

    InlineWeakKeyHashSet<RenderLayer> m_scrollingLayers;
    InlineWeakKeyHashSet<RenderLayer> m_viewportConstrainedLayers;

    const bool m_coordinateViewportConstrainedLayers;
};
#endif

// RenderLayerCompositor manages the hierarchy of
// composited RenderLayers. It determines which RenderLayers
// become compositing, and creates and maintains a hierarchy of
// GraphicsLayers based on the RenderLayer painting order.
// 
// There is one RenderLayerCompositor per RenderView.

class RenderLayerCompositor final : public GraphicsLayerClient, public CanMakeCheckedPtr<RenderLayerCompositor> {
    WTF_MAKE_TZONE_ALLOCATED(RenderLayerCompositor);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RenderLayerCompositor);
    friend class LegacyWebKitScrollingLayerCoordinator;
public:
    SWIFT_UNAVAILABLE_IN_SWIFT explicit RenderLayerCompositor(RenderView&);
    virtual ~RenderLayerCompositor();

    // Return true if this RenderView is in "compositing mode" (i.e. has one or more
    // composited RenderLayers)
    bool usesCompositing() const { return m_compositing; }
    // This will make a compositing layer at the root automatically, and hook up to
    // the native view/window system.
    void enableCompositingMode(bool enable = true);

    bool inForcedCompositingMode() const { return m_forceCompositingMode; }

    // True when some content element other than the root is composited.
    bool hasContentCompositingLayers() const { return m_contentLayersCount; }

    // Returns true if the accelerated compositing is enabled
    bool hasAcceleratedCompositing() const { return m_hasAcceleratedCompositing; }

    NODELETE bool canRender3DTransforms() const;

    void willRecalcStyle();

    // Returns true if the composited layers were actually updated.
    bool didRecalcStyleWithNoPendingLayout();

    // GraphicsLayers buffer state, which gets pushed to the underlying platform layers
    // at specific times.
    void notifyFlushRequired(const GraphicsLayer*) override;
    void notifySubsequentFlushRequired(const GraphicsLayer*) override;
    void flushPendingLayerChanges(bool isFlushRoot = true);
    NODELETE void setRenderingIsSuppressed(bool);

    // Called when the GraphicsLayer for the given RenderLayer has flushed changes inside of flushPendingLayerChanges().
    void didChangePlatformLayerForLayer(RenderLayer&, const GraphicsLayer*);

    // Called when something outside WebKit affects the visible rect (e.g. delegated scrolling). Might schedule a layer flush.
    void didChangeVisibleRect();
    
    // Rebuild the tree of compositing layers
    bool updateCompositingLayers(CompositingUpdateType, RenderLayer* updateRoot = nullptr);
    // This is only used when state changes and we do not exepect a style update or layout to happen soon (e.g. when
    // we discover that an iframe is overlapped during painting).
    void scheduleCompositingLayerUpdate();

    // Destroys a scrolling node after unparenting its children, and marks the children's layers as needing a
    // scrolling tree update so that they get reattached.
    void unparentChildrenAndDestroyScrollingNode(ScrollingNodeID);
    // This is used to cancel any pending update timers when the document goes into back/forward cache.
    void cancelCompositingLayerUpdate();

    // Update event regions, which only needs to happen once per rendering update.
    void updateEventRegions();
    void updateEventRegionsRecursive(RenderLayer&);

    struct RequiresCompositingData {
        LayoutUpToDate layoutUpToDate { LayoutUpToDate::Yes };
        RenderLayer::ViewportConstrainedNotCompositedReason nonCompositedForPositionReason { RenderLayer::NoNotCompositedReason };
        bool reevaluateAfterLayout { false };
        bool intrinsic { false };
    };

    // A RequiresCompositingData that a C++ caller lends to Swift for the duration of one call. Made from a reference,
    // so it is never null; operator* is the data.
    class RequiresCompositingDataView {
    public:
        RequiresCompositingDataView(RequiresCompositingData& data LIFETIME_BOUND)
            : m_data(std::bit_cast<uintptr_t>(&data))
        {
        }

        RequiresCompositingData& operator*() const LIFETIME_BOUND { return *std::bit_cast<RequiresCompositingData*>(m_data); }

    private:
        // An integer, as in PaintInfoView: Swift does not import a pointer to a view type.
        uintptr_t m_data;
    } SWIFT_VIEW;

    // ChromeClient's compositing triggers, which Swift cannot name through the abstract ChromeClient.
    enum class CompositingTrigger : unsigned {
        ThreeDTransform = ChromeClient::ThreeDTransformTrigger,
        Video = ChromeClient::VideoTrigger,
        Plugin = ChromeClient::PluginTrigger,
        Canvas = ChromeClient::CanvasTrigger,
        Animation = ChromeClient::AnimationTrigger,
        Filter = ChromeClient::FilterTrigger,
        ScrollableNonMainFrame = ChromeClient::ScrollableNonMainFrameTrigger,
        AnimatedOpacity = ChromeClient::AnimatedOpacityTrigger,
    };
    bool hasCompositingTrigger(CompositingTrigger trigger) const { return m_compositingTriggers & static_cast<unsigned>(trigger); }

    // Whether layer's backing needs a graphics layer to do clipping by an ancestor (non-stacking-context parent with overflow).
    bool clippedByAncestor(RenderLayer&, const RenderLayer* compositingAncestor) const;

    bool updateAncestorClippingStack(RenderLayer&, const RenderLayer* compositingAncestor) const;

    // Returns the ScrollingNodeID for the containing async-scrollable layer that scrolls this renderer's border box.
    // May return 0 for position-fixed content.
    WEBCORE_EXPORT static std::optional<ScrollingNodeID> asyncScrollableContainerNodeID(const RenderObject&);

    // Whether layer's backing needs a graphics layer to clip z-order children of the given layer.
    static bool clipsCompositingDescendants(const RenderLayer&);

    // Whether the given layer needs an extra 'contents' layer.
    NODELETE bool needsContentsCompositingLayer(const RenderLayer&) const;

    bool fixedLayerIntersectsViewport(const RenderLayer&) const;

    NODELETE bool supportsFixedRootBackgroundCompositing() const;
    bool needsFixedRootBackgroundLayer(const RenderLayer&) const;
    NODELETE GraphicsLayer* fixedRootBackgroundLayer() const;

    void rootOrBodyStyleChanged(RenderElement&, const Style::ComputedStyle* oldStyle);

    // Called after the view transparency, or the document or base background color change.
    void rootBackgroundColorOrTransparencyChanged();
    
    // Repaint the appropriate layers when the given RenderLayer starts or stops being composited.
    void repaintOnCompositingChange(RenderLayer&, RenderLayerModelObject* repaintContainer);

    void repaintInCompositedAncestor(RenderLayer&, LayoutRect);
    
    // Notify us that a layer has been removed
    void layerWillBeRemoved(RenderLayer& parent, RenderLayer& child);

    void establishesTopLayerWillChangeForLayer(RenderLayer&);

    // Get the nearest ancestor layer that has overflow or clip, but is not a stacking context
    NODELETE RenderLayer* enclosingNonStackingClippingLayer(const RenderLayer&) const;

    // Repaint all composited layers.
    void repaintCompositedLayers();

    // Returns true if the given layer needs it own backing store.
    bool requiresOwnBackingStore(const RenderLayer&, const RenderLayer* compositingAncestorLayer, LayoutRect layerCompositedBoundsInAncestor, LayoutRect ancestorCompositedBounds) const;

    NODELETE WEBCORE_EXPORT RenderLayer& rootRenderLayer() const;
    NODELETE GraphicsLayer* rootGraphicsLayer() const;

    GraphicsLayer* scrollContainerLayer() const { return m_scrollContainerLayer.get(); }
    GraphicsLayer* scrolledContentsLayer() const { return m_scrolledContentsLayer.get(); }
    GraphicsLayer* clipLayer() const { return m_clipLayer.get(); }
    GraphicsLayer* rootContentsLayer() const { return m_rootContentsLayer.get(); }

    GraphicsLayer* layerForClipping() const {  return m_clipLayer ? m_clipLayer.get() : m_scrollContainerLayer.get();  }

#if HAVE(RUBBER_BANDING)
    GraphicsLayer* headerLayer() const { return m_layerForHeader.get(); }
    GraphicsLayer* footerLayer() const { return m_layerForFooter.get(); }
    GraphicsLayer* layerForTopOverhangColorExtension() const { return m_layerForTopOverhangColorExtension.get(); }
    GraphicsLayer* layerForTopOverhangImage() const { return m_layerForTopOverhangImage.get(); }
    GraphicsLayer* layerForBottomOverhangArea() const { return m_layerForBottomOverhangArea.get(); }
#endif

    enum RootLayerAttachment {
        RootLayerUnattached,
        RootLayerAttachedViaChromeClient,
        RootLayerAttachedViaEnclosingFrame
    };

    RootLayerAttachment rootLayerAttachment() const { return m_rootLayerAttachment; }
    void updateRootLayerAttachment();
    void updateRootLayerPosition();
    
    void setIsInWindow(bool);

    void clearBackingForAllLayers();
    void invalidateEventRegionForAllFrames();
    void invalidateEventRegionForAllLayers();
    
    NODELETE void layerBecameComposited(const RenderLayer&);
    void layerBecameNonComposited(const RenderLayer&);
    
#if ENABLE(VIDEO)
    // Use by RenderVideo to ask if it should try to use accelerated compositing.
    bool canAccelerateVideoRendering(RenderVideo&) const;
#endif

    // Walk the tree looking for layers with 3d transforms. Useful in case you need
    // to know if there is non-affine content, e.g. for drawing into an image.
    bool has3DContent() const;

    static bool hasCompositedWidgetContents(const RenderObject&);
    static bool isCompositedPlugin(const RenderObject&);

#if HAVE(CORE_ANIMATION_SEPARATED_LAYERS)
    static bool isSeparated(const RenderObject&);
#endif

#if ENABLE(SPATIAL_PORTAL)
    static bool isSpatialPortal(const RenderObject&);
    static bool isPromotedSpatialPortalChild(const RenderLayer&);
    static RenderLayer* promotedSpatialPortalChildForLayer(RenderLayer&);
#endif

    bool isRunningTransformAnimation(RenderLayerModelObject&) const;

    static RenderLayerCompositor* frameContentsCompositor(RenderWidget&);

    struct WidgetLayerAttachment {
        bool widgetLayersAttachedAsChildren { false };
        bool layerHierarchyChanged { false };
    };
    WidgetLayerAttachment attachWidgetContentLayersIfNecessary(RenderWidget&);
    WidgetLayerAttachment attachWidgetContentLayersIfNecessaryForSwift(RenderLayerModelObject&);

    GraphicsLayer* viewTransitionNewContentLayer(RenderLayer&);

    // Update the geometry of the layers used for clipping and scrolling in frames.
    void frameViewDidChangeLocation(FloatPoint contentsOffset);
    void frameViewDidChangeSize();
    void frameViewDidScroll();
    void frameViewDidAddOrRemoveScrollbars();
    void frameViewDidLayout();
    void rootLayerConfigurationChanged();

    void widgetDidChangeSize(RenderWidget&);

    WEBCORE_EXPORT String layerTreeAsText(OptionSet<LayerTreeAsTextOptions> = { }) const;
    WEBCORE_EXPORT String trackedRepaintRectsAsText() const;

    WEBCORE_EXPORT String layerTreeAsText(OptionSet<LayerTreeAsTextOptions> = { }, uint32_t baseIndent = 0);
    WEBCORE_EXPORT std::optional<String> platformLayerTreeAsText(Element&, OptionSet<PlatformLayerTreeAsTextFlags>);

    float deviceScaleFactor() const override;
    float contentsScaleMultiplierForNewTiles(const GraphicsLayer*) const override;
    float pageScaleFactor() const override;
    float zoomedOutPageScaleFactor() const override;
    bool delegatesScaling() const override;
    FloatSize enclosingFrameViewVisibleSize() const override;
    void didChangePlatformLayerForLayer(const GraphicsLayer*) override { }

    void layerTiledBackingUsageChanged(const GraphicsLayer*, bool /*usingTiledBacking*/);
    
    bool acceleratedDrawingEnabled() const { return m_acceleratedDrawingEnabled; }
    bool useDynamicContentScalingDisplayListsForDOMRendering() const { return m_useDynamicContentScalingDisplayListsForDOMRendering; }

    void deviceOrPageScaleFactorChanged();

    GraphicsLayer* layerForHorizontalScrollbar() const { return m_layerForHorizontalScrollbar.get(); }
    GraphicsLayer* layerForVerticalScrollbar() const { return m_layerForVerticalScrollbar.get(); }
    GraphicsLayer* layerForScrollCorner() const { return m_layerForScrollCorner.get(); }
#if HAVE(RUBBER_BANDING)
    GraphicsLayer* layerForOverhangAreas() const { return m_layerForOverhangAreas.get(); }
    GraphicsLayer* layerForContentShadow() const { return m_contentShadowLayer.get(); }

    void updateLayerForTopOverhangColorExtension(bool wantsLayer);
    void updateLayerForTopOverhangImage(bool wantsLayer);
    void updateLayerForBottomOverhangArea(bool wantsLayer);
    void updateLayerForHeader(bool wantsLayer);
    void updateLayerForFooter(bool wantsLayer);

    void updateLayerForOverhangAreasBackgroundColor();
    void updateSizeAndPositionForTopOverhangColorExtensionLayer();
    void updateSizeAndPositionForOverhangAreaLayer();
#endif // HAVE(RUBBER_BANDING)

    void updateRootContentsLayerBackgroundColor();

    ViewportConstrainedSublayers viewportConstrainedSublayers(const RenderLayer&, const RenderLayer* compositingAncestor) const;

    // FIXME: make the coordinated/async terminology consistent.
    bool useCoordinatedScrollingForLayer(const RenderLayer&) const;
    ScrollPositioningBehavior computeCoordinatedPositioningForLayer(const RenderLayer&, const RenderLayer* compositingAncestor) const;
    bool isLayerForPluginWithScrollCoordinatedContents(const RenderLayer&) const;

    NODELETE ScrollableArea* scrollableAreaForScrollingNodeID(std::optional<ScrollingNodeID>) const;

    void removeFromScrollCoordinatedLayers(RenderLayerBacking&);

    // Takes the layer from the backing: the backing's destructor calls this while its layer is destroyed.
    void willRemoveScrollingLayerWithBacking(RenderLayerBacking&);
    void didAddScrollingLayer(RenderLayer&);

    void resetTrackedRepaintRects();
    void setTracksRepaints(bool tracksRepaints) { m_isTrackingRepaints = tracksRepaints; }

    bool viewHasTransparentBackground(Color* backgroundColor = nullptr) const;

    NODELETE bool viewNeedsToInvalidateEventRegionOfEnclosingCompositingLayerForRepaint() const;

    bool hasNonMainLayersWithTiledBacking() const { return m_layersWithTiledBackingCount; }

    using CompositingReasons = OptionSet<CompositingReason>;
    CompositingReasons reasonsForCompositing(const RenderLayer&) const;
    
    void didPaintBacking(RenderLayerBacking*);

    const Color& rootExtendedBackgroundColor() const LIFETIME_BOUND { return m_rootExtendedBackgroundColor; }

    void updateRootContentLayerClipping();
    void updateRootContentsLayerAppliesPageScale();

    void setRootElementCapturedInViewTransition(bool);

    // For testing.
    void startTrackingLayerFlushes() { m_layerFlushCount = 0; }
    unsigned layerFlushCount() const { return m_layerFlushCount; }

    void startTrackingCompositingUpdates() { m_compositingUpdateCount = 0; }
    unsigned compositingUpdateCount() const { return m_compositingUpdateCount; }

    // Whether ASSERT_WITH_SECURITY_IMPLICATION checks: in builds with assertions or with security assertions.
    static constexpr bool securityAssertionsEnabled() { return !ASSERT_WITH_SECURITY_IMPLICATION_DISABLED; }

private:

    // The body of updateCompositingLayers(), called inside its LayerFreeForbiddenScope.
    SWIFT_UNSAFE bool updateCompositingLayersInScope(CompositingUpdateType, RenderLayer* updateRoot);

    NODELETE bool documentUsesTiledBacking() const;

    bool requiresHorizontalScrollbarLayer() const;
    bool requiresVerticalScrollbarLayer() const;
    bool requiresScrollCornerLayer() const;
#if HAVE(RUBBER_BANDING)
    NODELETE bool requiresOverhangAreasLayer() const;
#endif

    // Returns true if the policy changed.
    bool updateCompositingPolicy();
    bool canUpdateCompositingPolicy() const;
    void beginWillChangeAreaEstimate();
    // The Swift addToWillChangeAreaEstimate() adds a will-change layer's absolute bounds through these.
    bool hasWillChangeAreaEstimateForSwift() const { return !!m_willChangeAreaEstimate; }
    void addToWillChangeAreaEstimateForSwift(FloatRect absoluteBounds);
    bool willChangeAreaEstimateExceedsBudget();

    // GraphicsLayerClient implementation
    void paintContents(const GraphicsLayer&, GraphicsContext&, const FloatRect&, OptionSet<GraphicsLayerPaintBehavior>) override;
    void customPositionForVisibleRectComputation(const GraphicsLayer*, FloatPoint&) const override;
    bool shouldDumpPropertyForLayer(const GraphicsLayer*, ASCIILiteral propertyName, OptionSet<LayerTreeAsTextOptions>) const override;
    bool backdropRootIsOpaque(const GraphicsLayer*) const override;
    bool isFlushingLayers() const override { return m_flushingLayers; }
    bool isTrackingRepaints() const override { return m_isTrackingRepaints; }
#if ENABLE(THREADED_ANIMATIONS)
    std::optional<MonotonicTime> renderingUpdateTimestamp() const override;
#endif

    // Copy the accelerated compositing related flags from Settings
    void cacheAcceleratedCompositingFlags();
    void cacheAcceleratedCompositingFlagsAfterLayout();

    // Whether the given RL needs a compositing layer.
    bool needsToBeComposited(const RenderLayer&, NOESCAPE RequiresCompositingDataView) const;
    // Whether the layer has an intrinsic need for compositing layer.
    bool requiresCompositingLayer(const RenderLayer&, NOESCAPE RequiresCompositingDataView) const;
    // Whether the layer could ever be composited.
    bool canBeComposited(const RenderLayer&) const;

    void createBacking(RenderLayer&);
    void clearReplicaLayerOfReflectionSource(RenderLayer&);
    void rendererCompositingBackingChanged(RenderLayer&);
    void frameViewFixedObjectsDidChange();

    // Repaint this and its child layers.
    void recursiveRepaintLayer(RenderLayer&);

    // Adjusts a layer's absolute overlap bounds for sticky and fixed positioning.
    LayoutRect overlapExtentForPositionedRenderer(const RenderLayer&, LayoutRect bounds) const;

    void clearBackingProviderSequencesInStackingContextOfLayer(RenderLayer&);

    void updateCompositingLayersTimerFired();

    void computeCompositingRequirements(RenderLayer& rootLayer, RenderLayer& compositingAncestor, NOESCAPE RenderGeometryMapView);

    // GraphicsLayer creation for Swift, which cannot pass the compositor as the layer's client or name the layer.
    enum class GraphicsLayerName : uint8_t {
        TopOverhangImage, TopOverhangColorExtension, BottomOverhang, Header, Footer, OverhangAreas, ContentShadow,
        HorizontalScrollbarContainer, VerticalScrollbarContainer, ScrollCorner, ContentRoot, OverflowControlsHost,
        FrameScrolledContents, ScrollContainer, FrameClipping,
    };
    // Each name has its own field. A field's layer has the compositor as its client, so the compositor clears it before dropping it.
    void createGraphicsLayer(GraphicsLayerName, GraphicsLayer::Type);
    void unparentAndClearGraphicsLayer(GraphicsLayerName);
    SWIFT_UNAVAILABLE_IN_SWIFT RefPtr<GraphicsLayer>& graphicsLayerField(GraphicsLayerName);
    GraphicsLayer* overflowControlsHostLayer() const { return m_overflowControlsHostLayer.get(); }
    // The chrome client, the page overlay controller and the scrolling coordinator's scrollable area calls, which Swift cannot make.
    void chromeClientDidAddHeaderLayer(GraphicsLayer&);
    void chromeClientDidAddFooterLayer(GraphicsLayer&);
    void attachRootGraphicsLayerViaChromeClient(GraphicsLayer*);
    GraphicsLayer& layerWithDocumentOverlays() const;
    Color fixedContainerEdgesTopColor() const;
    void frameViewScrollbarLayerDidChange(ScrollbarOrientation);
    bool viewHasTransparentBackgroundForSwift() const { return viewHasTransparentBackground(); }
    bool viewHasTransparentBackgroundForSwift(Color& backgroundColor) const { return viewHasTransparentBackground(&backgroundColor); }
    void chromeClientPageExtendedBackgroundColorDidChange();
    bool visualUpdatesAllowed() const;
    int pageOverlayCount() const;
    ChromeClient::CompositingTriggerFlags allowedCompositingTriggers() const;
    static bool useDynamicContentScalingDisplayListsForDOMRendering(const Settings&);
    bool documentHasHDRContent() const;
    void setViewportConstrainedLayersNeedCompositingGeometryUpdate();
    void computeCompositingRequirementsInGeometryMap(RenderLayer& rootLayer, RenderLayer& updateRoot);
    void updateLayerPositionsForTreeDebugging(RenderLayer&);
    bool hasSubscrollers() const;
    void layerTreeDidChange();

    static bool documentHasActiveViewTransitionCapturedDocumentElement(const RenderObject&);
    static bool isSpatialPortalForSwift(const RenderObject&);
    static bool isModelInSystemPreviewLink(RenderLayerModelObject&);
    static bool isSameGraphicsLayer(const GraphicsLayer* a, const GraphicsLayer* b) { return a == b; }

    static bool clippingChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool styleAffectsLayerGeometry(const Style::ComputedStyle&);
    static bool filterOutsetsChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool recompositeChangeRequiresGeometryUpdate(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool recompositeChangeRequiresChildrenGeometryUpdate(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool styleChangeAffectsAnchorLayer(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool borderChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool imageRenderingChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool appleColorFilterOverrideChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool usedPointerEventsChanged(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool opacityChangedToOrFromTransparent(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);
    static bool styleChangeAffectsSeparatedProperties(const RenderLayerModelObject&);

    bool layerHas3DContent(const RenderLayer&) const;

    bool allowBackingStoreDetachingForFixedPosition(RenderLayer&, LayoutRect absoluteBounds);

    GraphicsLayer* documentOverlayHostLayer();

    bool needsCompositingForContentOrOverlays() const;

    void scheduleRenderingUpdate();

    void ensureRootLayer();
    void destroyRootLayer();

    void attachRootLayer(RootLayerAttachment);
    void detachRootLayer();
    
    void rootLayerAttachmentChanged();

    void updateOverflowControlsLayers();

    void updateScrollLayerPosition();
    void updateScrollLayerClipping();

    FloatRect insetClipLayerRect() const;

    void notifyIFramesOfCompositingChange();

#if PLATFORM(IOS_FAMILY)
    void updateScrollCoordinatedLayersAfterFlushIncludingSubframes();
    void updateScrollCoordinatedLayersAfterFlush();
#endif

    FloatRect visibleRectForLayerFlushing() const;
    
    NODELETE Page& page() const;

    GraphicsLayerFactory* graphicsLayerFactory() const;
    ScrollingCoordinator* scrollingCoordinator() const;

    void setNeedsScrollingTreeUpdateForChildrenOfNode(ScrollingCoordinator&, ScrollingNodeID);

    // Non layout-dependent
    bool requiresCompositingForAnimation(RenderLayerModelObject&) const;
    bool requiresCompositingForTransform(RenderLayerModelObject&) const;
    bool requiresCompositingForVideo(RenderLayerModelObject&) const;
    bool requiresCompositingForCanvas(RenderLayerModelObject&) const;
    NODELETE bool requiresCompositingForModel(RenderLayerModelObject&) const;
    NODELETE bool requiresCompositingForSpatialPortal(RenderLayerModelObject&) const;
    bool requiresCompositingForSpatialPortalHosting(const RenderLayer&) const;
    bool requiresCompositingForScreenCaptureProtection(RenderLayerModelObject&) const;

    // Layout-dependent
    bool requiresCompositingForScrollableFrame(RequiresCompositingData&) const;
    bool requiresCompositingForPosition(RenderLayerModelObject&, const RenderLayer&, NOESCAPE RequiresCompositingDataView) const;
    IndirectCompositingReason computeIndirectCompositingReason(const RenderLayer&, bool hasCompositedDescendants, bool has3DTransformedDescendants, bool paintsIntoProvidedBacking) const;

    static ScrollPositioningBehavior layerScrollBehaviorRelativeToCompositedAncestor(const RenderLayer&, const RenderLayer& compositedAncestor);

    static bool styleChangeMayAffectIndirectCompositingReasons(const Style::ComputedStyle& oldStyle, const Style::ComputedStyle& newStyle);

    // The scrolling node map, the unresolved relations and the scrolling coordinator calls that Swift cannot
    // make itself: the node layers are RefPtrs, the constraints are polymorphic, and a scrollable area or a
    // frame view is passed as its ScrollableArea base.
    bool documentIsFullscreenForSwift() const;
    bool hasLayersWithUnresolvedRelationsForSwift() { return !m_layersWithUnresolvedRelations.computeIsEmpty(); }
    ScrollingNodeIDList scrollingNodeIDsForSwift() const;
    RenderLayerWeakList layersWithUnresolvedRelationsForSwift() const;
    void clearLayersWithUnresolvedRelationsForSwift();
    RenderElementList slowRepaintObjectsForSwift() const;
    static void setRelatedOverflowScrollingNodesForSwift(ScrollingCoordinator&, ScrollingNodeID, ScrollingNodeIDList);
    static void setRelatedOverflowScrollingNodeForSwift(ScrollingCoordinator&, ScrollingNodeID, ScrollingNodeID relatedNodeID);
    static bool isSameScrollingNodeIDForSwift(std::optional<ScrollingNodeID> a, std::optional<ScrollingNodeID> b) { return a == b; }
    void addScrollingNodeLayerForSwift(ScrollingNodeID, RenderLayer&);
    void removeScrollingNodeLayerForSwift(ScrollingNodeID);
    void addLayerWithUnresolvedRelationsForSwift(RenderLayer&);
    static void setNodeLayersForSwift(ScrollingCoordinator&, ScrollingNodeID, GraphicsLayer*, GraphicsLayer* scrollContainerLayer, GraphicsLayer* scrolledContentsLayer, GraphicsLayer* counterScrollingLayer, GraphicsLayer* insetClipLayer, GraphicsLayer* rootContentsLayer, GraphicsLayer* horizontalScrollbarLayer, GraphicsLayer* verticalScrollbarLayer, GraphicsLayer* viewportAnchorLayer);
    static void setScrollingNodeScrollableAreaGeometryForSwift(ScrollingCoordinator&, ScrollingNodeID, RenderLayerScrollableArea&);
    static void setScrollingNodeScrollableAreaGeometryForSwift(ScrollingCoordinator&, ScrollingNodeID, LocalFrameView&);
    void ensureScrollbarsControllerForSwift(RenderLayerScrollableArea&);
    void ensureScrollbarsControllerForSwift(LocalFrameView&);
    void setFixedViewportConstraintsForSwift(ScrollingCoordinator&, ScrollingNodeID, RenderLayer&);
    void setStickyViewportConstraintsForSwift(ScrollingCoordinator&, ScrollingNodeID, RenderLayer&);
    static void setLayerHostingContextIdentifierForSwift(ScrollingCoordinator&, ScrollingNodeID, RenderLayer&);
#if PLATFORM(IOS_FAMILY)
    void updateLegacyViewportConstrainedLayer(RenderLayer&, bool isViewportConstrained);
    void removeFromLegacyScrollingLayerCoordinator(RenderLayerBacking&);
#endif

    void updateScrollingNodeLayers(ScrollingNodeID, RenderLayer&, ScrollingCoordinator&);

    void resolveScrollingTreeRelationships();
    bool setupScrollProxyRelatedOverflowScrollingNode(ScrollingCoordinator&, ScrollingNodeID, RenderLayer&);

    void updateSynchronousScrollingNodes();

    SWIFT_UNAVAILABLE_IN_SWIFT FixedPositionViewportConstraints computeFixedViewportConstraints(RenderLayer&) const;
    SWIFT_UNAVAILABLE_IN_SWIFT StickyPositionViewportConstraints computeStickyViewportConstraints(RenderLayer&) const;

    LayoutRoundedRect parentRelativeScrollableRect(const RenderLayer&, const RenderLayer* ancestorLayer) const;

    // Returns list of layers and their clip rects required to clip the given layer, which include clips in the
    // containing block chain between the given layer and its composited ancestor.
    Vector<CompositedClipData> computeAncestorClippingStack(RenderLayer&, const RenderLayer* compositingAncestor) const;

    NODELETE bool requiresScrollLayer(RootLayerAttachment) const;
#if HAVE(RUBBER_BANDING)
    bool requiresContentShadowLayer() const;
#endif

    // True if the FrameView uses a ScrollingCoordinator.
    bool hasCoordinatedScrolling() const;

    // FIXME: make the coordinated/async terminology consistent.
    bool isAsyncScrollableStickyLayer(const RenderLayer&, const RenderLayer** enclosingAcceleratedOverflowLayer = nullptr) const;
    bool isAsyncScrollableStickyLayerForSwift(const RenderLayer& layer) const { return isAsyncScrollableStickyLayer(layer); }

    bool shouldCompositeOverflowControls() const;

    bool isRootFrameCompositor() const;
    NODELETE bool isMainFrameCompositor() const;

    void updateCompositingForLayerTreeAsTextDump();

    const CheckedRef<RenderView> m_renderView;
    Timer m_updateCompositingLayersTimer;
    Timer m_updateRenderingTimer;

    ChromeClient::CompositingTriggerFlags m_compositingTriggers { static_cast<ChromeClient::CompositingTriggerFlags>(ChromeClient::AllTriggers) };
    bool m_hasAcceleratedCompositing { true };
    
    CompositingPolicy m_compositingPolicy;
    PAL::HysteresisActivity m_compositingPolicyHysteresis;
    MonotonicTime m_willChangeBudgetBackoffEndTime;
    Seconds m_willChangeBudgetBackoffDuration;

    struct WillChangeAreaEstimate {
        double budget { 0 };
        FloatRect coverageRect;
        double area { 0 };
    };
    std::optional<WillChangeAreaEstimate> m_willChangeAreaEstimate;

    bool m_ignoresWillChangeOverBudget { false };
    bool m_showDebugBorders { false };
    bool m_showRepaintCounter { false };
    bool m_acceleratedDrawingEnabled { false };
    bool m_useDynamicContentScalingDisplayListsForDOMRendering { false };

    bool m_compositing { false };
    bool m_flushingLayers { false };
    bool m_shouldFlushOnReattach { false };
    bool m_forceCompositingMode { false };
    bool m_rootElementCapturedInViewTransition { false };

    bool m_isTrackingRepaints { false }; // Used for testing.

    unsigned m_contentLayersCount { 0 };
    unsigned m_layersWithTiledBackingCount { 0 };
    unsigned m_layerFlushCount { 0 };
    unsigned m_compositingUpdateCount { 0 };

    RootLayerAttachment m_rootLayerAttachment { RootLayerUnattached };

    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_rootContentsLayer;

    // Enclosing clipping layer for iframe content
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_clipLayer;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_scrollContainerLayer;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_scrolledContentsLayer;

    // Enclosing layer for overflow controls and the clipping layer
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_overflowControlsHostLayer;

    // Layers for overflow controls
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForHorizontalScrollbar;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForVerticalScrollbar;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForScrollCorner;
#if HAVE(RUBBER_BANDING)
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForOverhangAreas;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_contentShadowLayer;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForTopOverhangImage;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForTopOverhangColorExtension;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForBottomOverhangArea;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForHeader;
    SWIFT_UNSAFE RefPtr<GraphicsLayer> m_layerForFooter;
#endif

    bool m_viewBackgroundIsTransparent { false };

    Color m_viewBackgroundColor;
    Color m_rootExtendedBackgroundColor;

    HashMap<ScrollingNodeID, InlineWeakPtr<RenderLayer>> m_scrollingNodeToLayerMap;
    InlineWeakKeyHashSet<RenderLayer> m_layersWithUnresolvedRelations;
#if PLATFORM(IOS_FAMILY)
    const std::unique_ptr<LegacyWebKitScrollingLayerCoordinator> m_legacyScrollingLayerCoordinator;
#endif

    // Swift retains and releases a compositor through its checked pointer count. If C++ destroys one while Swift holds
    // it, its memory is zero-filled and not freed, so Swift's next use faults. A function that returns one leaves it
    // owned by C++, and Swift retains it.
} SWIFT_SHARED_REFERENCE(.incrementCheckedPtrCount, .decrementCheckedPtrCount) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/RenderLayerCompositor.swift");

void paintScrollbar(Scrollbar*, GraphicsContext&, const IntRect& clip, const Color& backgroundColor = Color());

WTF::TextStream& operator<<(WTF::TextStream&, CompositingUpdateType);
WTF::TextStream& operator<<(WTF::TextStream&, CompositingPolicy);
WTF::TextStream& operator<<(WTF::TextStream&, CompositingReason);

} // namespace WebCore

#if ENABLE(TREE_DEBUGGING)
// Outside the WebCore namespace for ease of invocation from the debugger.
void showGraphicsLayerTreeForCompositor(WebCore::RenderLayerCompositor&);
#endif
