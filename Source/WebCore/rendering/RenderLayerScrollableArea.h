/*
 * Copyright (C) 2003, 2009, 2012, 2015 Apple Inc. All rights reserved.
 * Copyright (C) 2020 Igalia S.L.
 *
 * Portions are Copyright (C) 1998 Netscape Communications Corporation.
 *
 * Other contributors:
 *   Robert O'Callahan <roc+@cs.cmu.edu>
 *   David Baron <dbaron@fas.harvard.edu>
 *   Christian Biesinger <cbiesinger@web.de>
 *   Randall Jesup <rjesup@wgate.com>
 *   Roland Mainz <roland.mainz@informatik.med.uni-giessen.de>
 *   Josh Soref <timeless@mac.com>
 *   Boris Zbarsky <bzbarsky@mit.edu>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * Alternatively, the contents of this file may be used under the terms
 * of either the Mozilla Public License Version 1.1, found at
 * http://www.mozilla.org/MPL/ (the "MPL") or the GNU General Public
 * License Version 2.0, found at http://www.fsf.org/copyleft/gpl.html
 * (the "GPL"), in which case the provisions of the MPL or the GPL are
 * applicable instead of those above.  If you wish to allow use of your
 * version of this file only under the terms of one of those two
 * licenses (the MPL or the GPL) and not to allow others to use your
 * version of this file under the LGPL, indicate your decision by
 * deletingthe provisions above and replace them with the notice and
 * other provisions required by the MPL or the GPL, as the case may be.
 * If you do not delete the provisions above, a recipient may use your
 * version of this file under any of the LGPL, the MPL or the GPL.
 */

#pragma once

#include <WebCore/RenderLayer.h>
#include <WebCore/ScrollableArea.h>
#include <WebCore/ScrollbarTheme.h>
#include <wtf/Platform.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class RenderMarquee;

class RenderLayerScrollableArea final : public ScrollableArea, public CanMakeCheckedPtr<RenderLayerScrollableArea> {
    WTF_MAKE_TZONE_ALLOCATED(RenderLayerScrollableArea);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RenderLayerScrollableArea);
    friend class ScrollbarUpdateScope;
public:
    SWIFT_UNAVAILABLE_IN_SWIFT explicit RenderLayerScrollableArea(RenderLayer&);
    virtual ~RenderLayerScrollableArea();

    // CheckedPtr interface
    uint32_t checkedPtrCount() const final { return CanMakeCheckedPtr::checkedPtrCount(); }
    uint32_t checkedPtrCountWithoutThreadCheck() const final { return CanMakeCheckedPtr::checkedPtrCountWithoutThreadCheck(); }
    SWIFT_UNSAFE void incrementCheckedPtrCount() const final { CanMakeCheckedPtr::incrementCheckedPtrCount(); }
    SWIFT_UNSAFE void decrementCheckedPtrCount() const final { CanMakeCheckedPtr::decrementCheckedPtrCount(); }
    SWIFT_UNSAFE void setDidBeginCheckedPtrDeletion() final { CanMakeCheckedPtr::setDidBeginCheckedPtrDeletion(); }

    RenderLayer& layer() LIFETIME_BOUND { return m_layer; }

    void clear();
    // The layer's renderer and description, for Swift, which would retain the layer to ask it: clear() and debugDescription()
    // run while the layer is destroyed.
    RenderLayerModelObject& layerRendererForSwift() const { return m_layer.renderer(); }
    String layerDebugDescriptionForSwift() const { return m_layer.debugDescription(); }

    // The calls that pass this area as a ScrollableArea, for Swift, which cannot convert to the base class.
    bool addToFrameViewScrollableAreas();
    bool removeFromFrameViewScrollableAreas();
    void addToFrameViewAnimatedScrollAreas();
    void removeFromFrameViewAnimatedScrollAreas();
    void paintScrollCornerWithTheme(NOESCAPE LentGraphicsContext context, IntRect rect) { ScrollbarTheme::theme().paintScrollCorner(*this, *context, rect); }

    RenderMarquee* marquee() const { return m_marquee.get(); }
    void updateMarqueePosition();
    void createOrDestroyMarquee();

    void restoreScrollPosition();

#if ENABLE(IOS_TOUCH_EVENTS)
    void registerAsTouchEventListenerForScrolling();
    void unregisterAsTouchEventListenerForScrolling();
#endif

    using OptionalScrollPosition = std::optional<ScrollPosition>;
    NODELETE void setPostLayoutScrollPosition(OptionalScrollPosition);
    void applyPostLayoutScrollPositionIfNeeded();
    bool hasPostLayoutScrollPosition() { return !!m_postLayoutScrollPosition; }

    // ScrollableArea members, for Swift, which does not import the base class.
    ScrollOffset scrollOffsetForSwift() const { return scrollOffset(); }
    ScrollType currentScrollTypeForSwift() const { return currentScrollType(); }

    int scrollWidth() const;
    int scrollHeight() const;

    void panScrollFromPoint(const IntPoint&);

    // Scrolling methods for layers that can scroll their overflow.
    WEBCORE_EXPORT void scrollByRecursively(const IntSize& delta, ScrollableArea** scrolledArea = nullptr);

    // Attempt to scroll the given ScrollOffset, returning the real target offset after it has
    // been adjusted by scroll snapping.
    WEBCORE_EXPORT ScrollOffset scrollToOffset(ScrollOffset, ScrollPositionChangeOptions = ScrollPositionChangeOptions::createProgrammatic());

    void scrollToXPosition(int x, ScrollPositionChangeOptions);
    void scrollToYPosition(int y, ScrollPositionChangeOptions);
    void setScrollPosition(ScrollPosition, ScrollPositionChangeOptions);

    // These are only used by marquee.
    void scrollToXOffset(int x) { scrollToOffset(ScrollOffset(x, scrollOffset().y()), ScrollPositionChangeOptions::createProgrammaticUnclamped()); }
    void scrollToYOffset(int y) { scrollToOffset(ScrollOffset(scrollOffset().x(), y), ScrollPositionChangeOptions::createProgrammaticUnclamped()); }

    NODELETE bool scrollsOverflow() const;
    bool hasScrollableHorizontalOverflow() const;
    bool hasScrollableVerticalOverflow() const;
    bool hasScrollbars() const { return horizontalScrollbar() || verticalScrollbar(); }
    bool hasHorizontalScrollbar() const { return horizontalScrollbar(); }
    bool hasVerticalScrollbar() const { return verticalScrollbar(); }
    void setHasHorizontalScrollbar(bool);
    void setHasVerticalScrollbar(bool);

    NODELETE OverscrollBehavior horizontalOverscrollBehavior() const final;
    NODELETE OverscrollBehavior verticalOverscrollBehavior() const final;

    Color scrollbarThumbColorStyle() const final;
    Color scrollbarTrackColorStyle() const final;
    NODELETE Style::ScrollbarGutter scrollbarGutterStyle() const final;
    NODELETE ScrollbarWidth scrollbarWidthStyle() const final;
    std::optional<ScrollbarColor> scrollbarColorStyle() const final;

    bool requiresScrollPositionReconciliation() const { return m_requiresScrollPositionReconciliation; }
    void setRequiresScrollPositionReconciliation(bool requiresReconciliation = true) { m_requiresScrollPositionReconciliation = requiresReconciliation; }

    // Returns true when the layer could do touch scrolling, but doesn't look at whether there is actually scrollable overflow.
    NODELETE bool canUseCompositedScrolling() const;
    // Returns true when there is actually scrollable overflow (requires layout to be up-to-date).
    bool hasCompositedScrollableOverflow() const { return m_hasCompositedScrollableOverflow; }

    int verticalScrollbarWidth(OverlayScrollbarSizeRelevancy = OverlayScrollbarSizeRelevancy::IgnoreOverlayScrollbarSize, bool isHorizontalWritingMode = true) const;
    int horizontalScrollbarHeight(OverlayScrollbarSizeRelevancy = OverlayScrollbarSizeRelevancy::IgnoreOverlayScrollbarSize, bool isHorizontalWritingMode = true) const;

    static int themeScrollbarThickness(ScrollbarWidth width) { return ScrollbarTheme::theme().scrollbarThickness(width); }
    static bool themeUsesOverlayScrollbars() { return ScrollbarTheme::theme().usesOverlayScrollbars(); }

    NODELETE bool hasOverflowControls() const;
    bool hitTestOverflowControls(HitTestResultView, IntPoint localPoint);

    void paintOverflowControls(GraphicsContext& context, OptionSet<PaintBehavior> paintBehavior, const IntPoint& paintOffset, const IntRect& damageRect, bool paintingOverlayControls = false) { paintOverflowControls(LentGraphicsContext { context }, paintBehavior, paintOffset, damageRect, paintingOverlayControls); }
    void paintOverflowControls(NOESCAPE LentGraphicsContext, OptionSet<PaintBehavior>, IntPoint paintOffset, IntRect damageRect, bool paintingOverlayControls);
    void paintScrollCorner(NOESCAPE LentGraphicsContext, IntPoint paintOffset, IntRect scrollCornerRect, IntRect damageRect);
    void paintResizer(NOESCAPE LentGraphicsContext, LayoutPoint paintOffset, IntRect resizerRect, LayoutRect damageRect);
    using ScrollbarPaintBehaviors = OptionSet<ScrollbarPaintBehavior>;
    static void paintScrollbar(Scrollbar& scrollbar, NOESCAPE LentGraphicsContext context, IntRect damageRect, ScrollbarPaintBehaviors paintBehavior) { scrollbar.paint(*context, damageRect, paintBehavior); }
    void paintOverlayScrollbars(GraphicsContext&, const LayoutRect& damageRect, OptionSet<PaintBehavior>, RenderObject* subtreePaintRoot = nullptr);

    void updateScrollbarSteps();
    std::optional<ScrollbarUpdateScope> updateScrollInfoAfterLayout();
    struct ScrollInfoAfterLayout {
        ScrollPosition originalScrollPosition;
        bool needsScrollbarUpdateScope { false };
        bool horizontalAutoScrollbarChanged { false };
        bool verticalAutoScrollbarChanged { false };
        bool hasHorizontalOverflow { false };
        bool hasVerticalOverflow { false };
    };

    bool scroll(ScrollDirection, ScrollGranularity, unsigned stepCount = 1);

public:
    // All methods in this section override ScrollableaArea methods (final).
    void availableContentSizeChanged(AvailableSizeChangeReason) final;

    NativeScrollbarVisibility horizontalNativeScrollbarVisibility() const final;
    NativeScrollbarVisibility verticalNativeScrollbarVisibility() const final;

    bool canShowNonOverlayScrollbars() const final;

    ScrollPosition scrollPosition() const final { return m_scrollPosition; }

    Scrollbar* horizontalScrollbar() const final { return m_hBar.get(); }
    Scrollbar* verticalScrollbar() const final { return m_vBar.get(); }
    ScrollableArea* enclosingScrollableArea() const final;

    bool handleWheelEventForScrolling(const PlatformWheelEvent&, std::optional<WheelScrollGestureState>) final;
    bool isScrollableOrRubberbandable() final;
    bool hasScrollableOrRubberbandableAncestor() final;
    bool useDarkAppearance() const final;
    void updateSnapOffsets() final;

#if PLATFORM(IOS_FAMILY)
#if ENABLE(IOS_TOUCH_EVENTS)
    bool handleTouchEvent(const PlatformTouchEvent&) final;
#endif

    void didStartScroll() final;
    void didEndScroll() final;
    void didUpdateScroll() final;
#endif

    NODELETE GraphicsLayer* layerForHorizontalScrollbar() const final;
    NODELETE GraphicsLayer* layerForVerticalScrollbar() const final;
    NODELETE GraphicsLayer* layerForScrollCorner() const final;

    bool usesCompositedScrolling() const final;
    bool usesAsyncScrolling() const final;

    NODELETE bool shouldPlaceVerticalScrollbarOnLeft() const final;

    bool isRenderLayer() const final { return true; }
    void invalidateScrollbarRect(Scrollbar& scrollbar, const IntRect& rect) final { invalidateScrollbarRectInLayer(scrollbar, rect); }
    void invalidateScrollCornerRect(const IntRect& rect) final { invalidateScrollCornerRectInLayer(rect); }
    NODELETE bool isActive() const final;
    bool isScrollCornerVisible() const final;
    IntRect scrollCornerRect() const final;
    IntRect convertFromScrollbarToContainingView(const Scrollbar& scrollbar, const IntRect& rect) const final { return convertFromScrollbarToContainingViewInLayer(scrollbar, rect); }
    IntRect convertFromContainingViewToScrollbar(const Scrollbar& scrollbar, const IntRect& rect) const final { return convertFromContainingViewToScrollbarInLayer(scrollbar, rect); }
    IntPoint convertFromScrollbarToContainingView(const Scrollbar& scrollbar, const IntPoint& point) const final { return convertFromScrollbarToContainingViewInLayer(scrollbar, point); }
    IntPoint convertFromContainingViewToScrollbar(const Scrollbar& scrollbar, const IntPoint& point) const final { return convertFromContainingViewToScrollbarInLayer(scrollbar, point); }
    void setScrollOffset(const ScrollOffset&) final;
    WEBCORE_EXPORT std::optional<ScrollingNodeID> scrollingNodeID() const final;

    using VisibleContentRectIncludesScrollbars = ScrollableArea::VisibleContentRectIncludesScrollbars;
    using VisibleContentRectBehavior = ScrollableArea::VisibleContentRectBehavior;
    IntRect visibleContentRectInternal(VisibleContentRectIncludesScrollbars, VisibleContentRectBehavior) const final;
    IntSize overhangAmount() const final;
    IntPoint lastKnownMousePositionInView() const final;
    NODELETE bool isHandlingWheelEvent() const final;
    bool shouldSuspendScrollAnimations() const final;
    IntRect scrollableAreaBoundingBox(bool* isInsideFixed = nullptr) const final;
    bool isUserScrollInProgress() const final;
    bool isRubberBandInProgress() const final;
    NODELETE bool forceUpdateScrollbarsOnMainThreadForPerformanceTesting() const final;
    bool isScrollSnapInProgress() const final;
    NODELETE bool scrollAnimatorEnabled() const final;
    NODELETE bool mockScrollbarsControllerEnabled() const final;
    void logMockScrollbarsControllerMessage(const String&) const final;

    String debugDescription() const final;
    void didStartScrollAnimation() final;

    IntSize visibleSize() const final;
    IntSize contentsSize() const final;
    IntSize reachableTotalContentsSize() const final;

    bool requestStartKeyboardScrollAnimation(const KeyboardScroll&) final;
    bool requestStopKeyboardScrollAnimation(bool immediate) final;

    bool requestScrollToPosition(const ScrollPosition&, const ScrollPositionChangeOptions& options) final;
    void stopAsyncAnimatedScroll() final;

    bool containsDirtyOverlayScrollbars() const { return m_containsDirtyOverlayScrollbars; }
    void setContainsDirtyOverlayScrollbars(bool dirtyScrollbars) { m_containsDirtyOverlayScrollbars = dirtyScrollbars; }

    void updateScrollbarsAfterStyleChange(const Style::ComputedStyle* oldStyle);
    // The old style by reference, or none, for Swift, which takes no pointer argument.
    void updateScrollbarsAfterStyleChange(const Style::ComputedStyle& oldStyle) { updateScrollbarsAfterStyleChange(&oldStyle); }
    void updateScrollbarsAfterStyleChangeWithoutOldStyle() { updateScrollbarsAfterStyleChange(nullptr); }
    void updateScrollbarsAfterStyleChange(bool hasOldStyle, bool oldStyleShouldPlaceVerticalScrollbarOnLeft);

    bool positionOverflowControls(IntSize);

    void updateAllScrollbarRelatedStyle();

    RenderLayer::OverflowControlRects overflowControlsRects() const;

    using OptionalBool = std::optional<bool>;
    bool hasOverlayScrollbarsForSwift() const { return hasOverlayScrollbars(); }

    bool overflowControlsIntersectRect(IntRect localRect) const;

    bool scrollingMayRevealBackground() const;

    void computeHasCompositedScrollableOverflow(LayoutUpToDate);

    // NOTE: This should only be called by the overridden setScrollOffset from ScrollableArea.
    void scrollTo(ScrollPosition);
    void updateCompositingLayersAfterScroll();

    IntSize scrollbarOffset(const Scrollbar&) const;

    std::optional<LayoutRect> updateScrollPosition(const ScrollPositionChangeOptions&, const LayoutRect& revealRect, const LayoutRect& localExposeRect);
    bool isVisibleToHitTesting() const final;
    void animatedScrollDidEnd() final;
    LayoutRect scrollRectToVisible(LayoutRect absoluteRect, ScrollRectToVisibleOptions);

    ScrollAnchoringController* scrollAnchoringController() const final { return m_scrollAnchoringController.get(); }

    void updateAnchorPositionedAfterScroll() final;

    void createScrollbarsController() final;

    NODELETE std::optional<FrameIdentifier> rootFrameID() const final;

    void scrollbarWidthChanged(ScrollbarWidth) override;

#if ENABLE(FORM_CONTROL_REFRESH)
    bool formControlRefreshEnabled() const override;
#endif

private:
    bool hasHorizontalOverflow() const;
    bool hasVerticalOverflow() const;

    NODELETE bool showsOverflowControls() const;

    ScrollOffset clampScrollOffset(ScrollOffset) const;

    void invalidateScrollbarRectInLayer(Scrollbar&, IntRect);
    void invalidateScrollCornerRectInLayer(IntRect);
    static bool isSameScrollbar(const Scrollbar* a, const Scrollbar* b) { return a == b; }
    // ScrollableArea's non-const members, which Swift sees as mutating.
    void invalidateScrollCornerForSwift(IntRect rect) { invalidateScrollCorner(rect); }
    void setIsAwaitingScrollendForSwift(bool isAwaitingScrollend) { setIsAwaitingScrollend(isAwaitingScrollend); }
    // ScrollAnimator is not imported into Swift.
    void setScrollAnimatorCurrentPosition(ScrollPosition);
    bool existingScrollAnimatorIsUserScrollInProgress() const;
    bool existingScrollAnimatorIsRubberBandInProgress() const;
    bool existingScrollAnimatorIsScrollSnapInProgress() const;

    void computeScrollDimensions();
    void computeScrollOrigin();

    void updateScrollableAreaSet(bool hasOverflow);

    void updateScrollCornerStyle();
    void updateResizerStyle();

    Ref<Scrollbar> createScrollbar(ScrollbarOrientation);

    // Swift does not see ScrollableArea's members or the scrollbar parts' type.
    void setScrollOriginForSwift(IntPoint origin) { setScrollOrigin(origin); }
    ScrollOffset scrollOffsetFromPositionForSwift(ScrollPosition position) const { return scrollOffsetFromPosition(position); }
    ScrollPosition scrollPositionFromOffsetForSwift(ScrollOffset offset) const { return scrollPositionFromOffset(offset); }
    void setCurrentScrollTypeForSwift(ScrollType scrollType) { setCurrentScrollType(scrollType); }
    void setCurrentScrollRelativityForSwift(ScrollRelativity scrollRelativity) { setCurrentScrollRelativity(scrollRelativity); }
    void scrollToPositionWithAnimationForSwift(FloatPoint position, ScrollPositionChangeOptions options) { scrollToPositionWithAnimation(position, options); }
    bool scrollToPositionWithoutAnimationForSwift(FloatPoint position, ScrollClamping clamping) { return scrollToPositionWithoutAnimation(position, clamping); }
    FloatPoint scrollOffsetAdjustedForSnappingForSwift(FloatPoint, ScrollSnapPointSelectionMethod) const;
    bool retargetRunningAnimationForSwift(FloatPoint, ScrollAnimationCurve);
    void cancelAnimationsForSwift();
    void willRemoveScrollbarForSwift(Scrollbar& scrollbar, ScrollbarOrientation orientation) { willRemoveScrollbar(scrollbar, orientation); }
    void setHorizontalScrollElasticityForSwift(ScrollElasticity elasticity) { setHorizontalScrollElasticity(elasticity); }
    void setVerticalScrollElasticityForSwift(ScrollElasticity elasticity) { setVerticalScrollElasticity(elasticity); }
    RenderBox* scrollCornerForSwift() const;
    RenderBox* resizerForSwift() const;
    void destroyScrollbar(ScrollbarOrientation);

    void clearScrollCorner();
    void clearResizer();

    void updateScrollbarPresenceAndState(std::optional<bool> hasHorizontalOverflow = std::nullopt, std::optional<bool> hasVerticalOverflow = std::nullopt);
    void registerScrollableAreaForAnimatedScroll();

    ScrollInfoAfterLayout updateScrollInfoAfterLayoutForScope();
    IntRect convertFromScrollbarToContainingViewInLayer(const Scrollbar&, IntRect) const;
    IntRect convertFromContainingViewToScrollbarInLayer(const Scrollbar&, IntRect) const;
    IntPoint convertFromScrollbarToContainingViewInLayer(const Scrollbar&, IntPoint) const;
    IntPoint convertFromContainingViewToScrollbarInLayer(const Scrollbar&, IntPoint) const;
    void updateTouchEventListenerForScrolling(bool needsToBeRegistered);
    // Swift does not see the scrollbar parts' type or reach a GraphicsContext.
    void paintScrollCornerPart(NOESCAPE LentGraphicsContext, LayoutPoint paintOffset, LayoutRect);
    void paintResizerPart(NOESCAPE LentGraphicsContext, LayoutPoint paintOffset, LayoutRect);
    void paintPlatformResizer(NOESCAPE LentGraphicsContext, LayoutRect);
    void paintPlatformResizerFrame(NOESCAPE LentGraphicsContext, LayoutRect);

    float deviceScaleFactor() const final;
    void scrollDidEnd() final;

private:
    bool m_scrollDimensionsDirty { true };
    bool m_registeredScrollableArea { false };
    bool m_hasCompositedScrollableOverflow { false };

#if PLATFORM(IOS_FAMILY) && ENABLE(IOS_TOUCH_EVENTS)
    bool m_registeredAsTouchEventListenerForScrolling { false };
#endif
    bool m_requiresScrollPositionReconciliation { false };
    bool m_containsDirtyOverlayScrollbars { false };
    bool m_updatingMarqueePosition { false };
    
    bool m_isRegisteredForAnimatedScroll { false };

    bool m_useDarkAppearanceForScrollbars { false };

    // The width/height of our scrolled area.
    int m_scrollWidth { 0 };
    int m_scrollHeight { 0 };

    RenderLayer& m_layer;
    ScrollPosition m_scrollPosition;
    std::optional<ScrollPosition> m_postLayoutScrollPosition;

    // For layers with overflow, we have a pair of scrollbars.
    RefPtr<Scrollbar> m_hBar;
    RefPtr<Scrollbar> m_vBar;

    IntPoint m_cachedOverlayScrollbarOffset;

    // Renderers to hold our custom scroll corner and resizer.
    RenderPtr<RenderScrollbarPart> m_scrollCorner;
    RenderPtr<RenderScrollbarPart> m_resizer;

    std::unique_ptr<RenderMarquee> m_marquee;

    const std::unique_ptr<ScrollAnchoringController> m_scrollAnchoringController;

    // Swift retains and releases a scrollable area through its checked pointer count. If C++ destroys one while Swift
    // holds it, its memory is zero-filled and not freed, so Swift's next use faults. A function that returns one leaves
    // it owned by C++, and Swift retains it.
} SWIFT_SHARED_REFERENCE(.incrementCheckedPtrCount, .decrementCheckedPtrCount) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT SWIFT_PRIVATE_FILEID("WebCore/RenderLayerTree.swift");

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_BEGIN(WebCore::RenderLayerScrollableArea)
static bool isType(const WebCore::ScrollableArea& area) { return area.isRenderLayer(); }
SPECIALIZE_TYPE_TRAITS_END()
