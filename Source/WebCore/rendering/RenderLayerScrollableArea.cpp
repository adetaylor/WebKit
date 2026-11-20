/*
 * Copyright (C) 2006-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2019 Adobe. All rights reserved.
 * Copyright (C) 2014 Google. All rights reserved.
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

#include "config.h"
#include "RenderLayerScrollableArea.h"

#include "AnchorPositionEvaluator.h"
#include "Chrome.h"
#include "ContainerNodeInlines.h"
#include "DebugPageOverlays.h"
#include "DocumentInlines.h"
#include "DocumentView.h"
#include "Editor.h"
#include "ElementInlines.h"
#include "ElementInlinesLight.h"
#include "ElementRuleCollector.h"
#include "EventHandler.h"
#include "FocusController.h"
#include "FrameInlines.h"
#include "FrameSelection.h"
#include "GraphicsLayer.h"
#include "HTMLBodyElement.h"
#include "HTMLHtmlElement.h"
#include "HitTestResult.h"
#include "InspectorInstrumentation.h"
#include "LayoutScope.h"
#include "Logging.h"
#include "RenderBoxInlines.h"
#include "RenderBoxModelObjectInlines.h"
#include "RenderElementInlines.h"
#include "RenderFlexibleBox.h"
#include "RenderGeometryMap.h"
#include "RenderLayerBacking.h"
#include "RenderLayerCompositor.h"
#include "RenderLayerInlines.h"
#include "RenderMarquee.h"
#include "RenderObjectInlines.h"
#include "RenderScrollbar.h"
#include "RenderScrollbarPart.h"
#include "RenderTheme.h"
#include "RenderView.h"
#include "ScrollAnchoringController.h"
#include "ScrollAnimator.h"
#include "ScrollbarTheme.h"
#include "ScrollbarUpdateScope.h"
#include "ScrollbarsController.h"
#include "ScrollingCoordinator.h"
#include "ShadowRoot.h"
#include "StyleComputedStyle+GettersInlines.h"
#include <wtf/SetForScope.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RenderLayerScrollableArea);

RenderLayerScrollableArea::RenderLayerScrollableArea(RenderLayer& layer)
    : m_layer(layer)
{
    auto& renderer = m_layer.renderer();
    if (renderer.settings().cssScrollAnchoringEnabled() && !is<HTMLHtmlElement>(renderer.element()) && !is<HTMLBodyElement>(renderer.element()))
        lazyInitialize(m_scrollAnchoringController, WTF::makeUnique<ScrollAnchoringController>(*this));
}

RenderLayerScrollableArea::~RenderLayerScrollableArea() = default;

bool RenderLayerScrollableArea::addToFrameViewScrollableAreas()
{
    return protect(m_layer.renderer().view().frameView())->addScrollableArea(this);
}

bool RenderLayerScrollableArea::removeFromFrameViewScrollableAreas()
{
    return protect(m_layer.renderer().view().frameView())->removeScrollableArea(this);
}

void RenderLayerScrollableArea::addToFrameViewAnimatedScrollAreas()
{
    protect(m_layer.renderer().view().frameView())->addScrollableAreaForAnimatedScroll(this);
}

void RenderLayerScrollableArea::removeFromFrameViewAnimatedScrollAreas()
{
    protect(m_layer.renderer().view().frameView())->removeScrollableAreaForAnimatedScroll(this);
}

void RenderLayerScrollableArea::setScrollAnimatorCurrentPosition(ScrollPosition position)
{
    scrollAnimator().setCurrentPosition(position);
}

FloatPoint RenderLayerScrollableArea::scrollOffsetAdjustedForSnappingForSwift(FloatPoint offset, ScrollSnapPointSelectionMethod method) const
{
    return scrollAnimator().scrollOffsetAdjustedForSnapping(offset, method);
}

bool RenderLayerScrollableArea::retargetRunningAnimationForSwift(FloatPoint position, ScrollAnimationCurve curve)
{
    return scrollAnimator().retargetRunningAnimation(position, curve);
}

void RenderLayerScrollableArea::cancelAnimationsForSwift()
{
    scrollAnimator().cancelAnimations();
}

bool RenderLayerScrollableArea::existingScrollAnimatorIsUserScrollInProgress() const
{
    auto* scrollAnimator = existingScrollAnimator();
    return scrollAnimator && scrollAnimator->isUserScrollInProgress();
}

bool RenderLayerScrollableArea::existingScrollAnimatorIsRubberBandInProgress() const
{
    auto* scrollAnimator = existingScrollAnimator();
    return scrollAnimator && scrollAnimator->isRubberBandInProgress();
}

bool RenderLayerScrollableArea::existingScrollAnimatorIsScrollSnapInProgress() const
{
    auto* scrollAnimator = existingScrollAnimator();
    return scrollAnimator && scrollAnimator->isScrollSnapInProgress();
}

bool RenderLayerScrollableArea::shouldPlaceVerticalScrollbarOnLeft() const
{
    return m_layer.renderer().shouldPlaceVerticalScrollbarOnLeft();
}

#if ENABLE(IOS_TOUCH_EVENTS)
bool RenderLayerScrollableArea::handleTouchEvent(const PlatformTouchEvent& touchEvent)
{
    // If we have accelerated scrolling, let the scrolling be handled outside of WebKit.
    if (hasCompositedScrollableOverflow())
        return false;

    return ScrollableArea::handleTouchEvent(touchEvent);
}

void RenderLayerScrollableArea::registerAsTouchEventListenerForScrolling()
{
    auto& renderer = m_layer.renderer();
    if (!renderer.element() || m_registeredAsTouchEventListenerForScrolling)
        return;

    renderer.document().addTouchEventHandler(*renderer.element());
    m_registeredAsTouchEventListenerForScrolling = true;
}

void RenderLayerScrollableArea::unregisterAsTouchEventListenerForScrolling()
{
    auto& renderer = m_layer.renderer();
    if (!renderer.element() || !m_registeredAsTouchEventListenerForScrolling)
        return;

    renderer.document().removeTouchEventHandler(*renderer.element());
    m_registeredAsTouchEventListenerForScrolling = false;
}
#endif // ENABLE(IOS_TOUCH_EVENTS)

IntRect RenderLayerScrollableArea::scrollableAreaBoundingBox(bool* isInsideFixed) const
{
    return m_layer.renderer().absoluteBoundingBoxRect(/* useTransforms */ true, isInsideFixed);
}

bool RenderLayerScrollableArea::requestScrollToPosition(const ScrollPosition& position, const ScrollPositionChangeOptions& options)
{
#if ENABLE(ASYNC_SCROLLING)
    LOG_WITH_STREAM(Scrolling, stream << "RenderLayerScrollableArea::requestScrollToPosition " << position << " options  " << options);

    if (RefPtr scrollingCoordinator = protect(m_layer.page())->scrollingCoordinator())
        return scrollingCoordinator->requestScrollToPosition(*this, position, options);
#else
    UNUSED_PARAM(position);
    UNUSED_PARAM(options);
#endif
    return false;
}

bool RenderLayerScrollableArea::requestStartKeyboardScrollAnimation(const KeyboardScroll& scrollData)
{
    if (RefPtr scrollingCoordinator = protect(m_layer.page())->scrollingCoordinator())
        return scrollingCoordinator->requestStartKeyboardScrollAnimation(*this, scrollData);

    return false;
}

bool RenderLayerScrollableArea::requestStopKeyboardScrollAnimation(bool immediate)
{
    if (RefPtr scrollingCoordinator = protect(m_layer.page())->scrollingCoordinator())
        return scrollingCoordinator->requestStopKeyboardScrollAnimation(*this, immediate);

    return false;
}

void RenderLayerScrollableArea::stopAsyncAnimatedScroll()
{
#if ENABLE(ASYNC_SCROLLING)
    LOG_WITH_STREAM(Scrolling, stream << m_layer << " stopAsyncAnimatedScroll");

    if (RefPtr scrollingCoordinator = protect(m_layer.page())->scrollingCoordinator())
        return scrollingCoordinator->stopAnimatedScroll(*this);
#endif
}

void RenderLayerScrollableArea::updateMarqueePosition()
{
    if (!m_marquee)
        return;

    SetForScope updatingMarqueePosition(m_updatingMarqueePosition, true);
    m_marquee->updateMarqueePosition();
}

void RenderLayerScrollableArea::createOrDestroyMarquee()
{
    auto& renderer = m_layer.renderer();
    if (renderer.isHTMLMarquee() && renderer.style().marqueeBehavior() != MarqueeBehavior::None && renderer.isRenderBox()) {
        if (!m_marquee)
            m_marquee = makeUnique<RenderMarquee>(&m_layer);
        m_marquee->updateMarqueeStyle();
    } else if (m_marquee)
        m_marquee = nullptr;
}

void RenderLayerScrollableArea::setScrollOffset(const ScrollOffset& offset)
{
    scrollTo(scrollPositionFromOffset(offset));
}

std::optional<ScrollingNodeID> RenderLayerScrollableArea::scrollingNodeID() const
{
    if (!m_layer.isComposited())
        return std::nullopt;

    return m_layer.backing()->scrollingNodeIDForRole(ScrollCoordinationRole::Scrolling);
}

bool RenderLayerScrollableArea::handleWheelEventForScrolling(const PlatformWheelEvent& wheelEvent, std::optional<WheelScrollGestureState> gestureState)
{
    if (!isScrollableOrRubberbandable())
        return false;

#if ENABLE(ASYNC_SCROLLING)
    if (usesAsyncScrolling() && scrollingNodeID()) {
        if (RefPtr scrollingCoordinator = protect(m_layer.page())->scrollingCoordinator()) {
            auto result = scrollingCoordinator->handleWheelEventForScrolling(wheelEvent, *scrollingNodeID(), gestureState);
            if (!result.needsMainThreadProcessing())
                return result.wasHandled;
        }
    }
#endif

    return ScrollableArea::handleWheelEventForScrolling(wheelEvent, gestureState);
}

void RenderLayerScrollableArea::availableContentSizeChanged(AvailableSizeChangeReason reason)
{
    ScrollableArea::availableContentSizeChanged(reason);

    auto& renderer = m_layer.renderer();
    if (reason == AvailableSizeChangeReason::ScrollbarsChanged) {
        if (auto* renderBlock = dynamicDowncast<RenderBlock>(renderer))
            renderBlock->setShouldForceRelayoutChildren(true);
        renderer.setNeedsLayout();
    }
}

#if PLATFORM(IOS_FAMILY)
void RenderLayerScrollableArea::didStartScroll()
{
    m_layer.page().chrome().client().didStartOverflowScroll();
}

void RenderLayerScrollableArea::didEndScroll()
{
    m_layer.page().chrome().client().didEndOverflowScroll();
}

void RenderLayerScrollableArea::didUpdateScroll()
{
    // Send this notification when we scroll, since this is how we keep selection updated.
    m_layer.page().chrome().client().didLayout(ChromeClient::Scroll);
}
#endif

void RenderLayerScrollableArea::createScrollbarsController()
{
    m_layer.page().chrome().client().ensureScrollbarsController(protect(m_layer.page()), *this);
}

NODELETE static inline RenderElement* rendererForScrollbar(RenderLayerModelObject& renderer)
{
    if (auto* element = renderer.element()) {
        if (auto* shadowRoot = element->containingShadowRoot()) {
            if (shadowRoot->mode() == ShadowRootMode::UserAgent) {
                if (auto* hostRenderer = shadowRoot->host()->renderer())
                    return hostRenderer;
            }
        }
    }

    return &renderer;
}

RenderBox* RenderLayerScrollableArea::scrollCornerForSwift() const
{
    return m_scrollCorner.get();
}

RenderBox* RenderLayerScrollableArea::resizerForSwift() const
{
    return m_resizer.get();
}

Ref<Scrollbar> RenderLayerScrollableArea::createScrollbar(ScrollbarOrientation orientation)
{
    auto& renderer = m_layer.renderer();
    RefPtr<Scrollbar> widget;
    ASSERT(rendererForScrollbar(renderer));
    auto& actualRenderer = *rendererForScrollbar(renderer);
    auto* actualRenderBox = dynamicDowncast<RenderBox>(actualRenderer);
    bool usesLegacyScrollbarStyle = actualRenderBox && actualRenderBox->style().usesLegacyScrollbarStyle();
    RefPtr element = actualRenderBox ? actualRenderBox->element() : nullptr;
    if (usesLegacyScrollbarStyle && element)
        widget = RenderScrollbar::createCustomScrollbar(*this, orientation, element.get());
    else {
        widget = Scrollbar::createNativeScrollbar(*this, orientation, scrollbarWidthStyle());
        
        didAddScrollbar(widget.get(), orientation);
        if (Ref page = m_layer.page(); page->isMonitoringWheelEvents())
            scrollAnimator().setWheelEventTestMonitor(page->wheelEventTestMonitor());
    }
    protect(renderer.view().frameView())->addChild(*widget);
    return widget.releaseNonNull();
}

ScrollableArea* RenderLayerScrollableArea::enclosingScrollableArea() const
{
    if (auto* scrollableLayer = m_layer.enclosingScrollableLayer(IncludeSelfOrNot::ExcludeSelf, CrossFrameBoundaries::No))
        return scrollableLayer->scrollableArea();

    auto& renderer = m_layer.renderer();
    return &renderer.view().frameView();
}

Style::ScrollbarGutter RenderLayerScrollableArea::scrollbarGutterStyle()  const
{
    if (auto* renderer = m_layer.renderBox())
        return renderer->style().scrollbarGutter();
    return CSS::Keyword::Auto { };
}

ScrollbarWidth RenderLayerScrollableArea::scrollbarWidthStyle()  const
{
    if (m_layer.renderBox())
        return Style::toPlatform(m_layer.renderer().style().scrollbarWidth());
    return ScrollbarWidth::Auto;
}

std::optional<ScrollbarColor> RenderLayerScrollableArea::scrollbarColorStyle() const
{
    if (m_layer.renderBox()) {
        if (auto value = m_layer.renderer().style().scrollbarColor().tryValue()) {
            Style::ColorResolver colorResolver { m_layer.renderer().style() };
            return ScrollbarColor {
                .thumbColor = colorResolver.colorResolvingCurrentColorApplyingColorFilter(value->thumb),
                .trackColor = colorResolver.colorResolvingCurrentColorApplyingColorFilter(value->track)
            };
        }
    }

    return { };
}

void RenderLayerScrollableArea::updateScrollbarsAfterStyleChange(const Style::ComputedStyle* oldStyle)
{
    updateScrollbarsAfterStyleChange(!!oldStyle, oldStyle && oldStyle->shouldPlaceVerticalScrollbarOnLeft());
}

std::optional<ScrollbarUpdateScope> RenderLayerScrollableArea::updateScrollInfoAfterLayout()
{
    auto info = updateScrollInfoAfterLayoutForScope();
    if (!info.needsScrollbarUpdateScope)
        return { };

    EnumSet<ScrollbarOrientation> autoScrollbarChanges;
    if (info.horizontalAutoScrollbarChanged)
        autoScrollbarChanges.add(ScrollbarOrientation::Horizontal);
    if (info.verticalAutoScrollbarChanged)
        autoScrollbarChanges.add(ScrollbarOrientation::Vertical);

    return std::optional<ScrollbarUpdateScope> { std::in_place, *this, info.originalScrollPosition, autoScrollbarChanges, info.hasHorizontalOverflow ? HasHorizontalOverflow::Yes : HasHorizontalOverflow::No, info.hasVerticalOverflow ? HasVerticalOverflow::Yes : HasVerticalOverflow::No };
}

void RenderLayerScrollableArea::updateTouchEventListenerForScrolling(bool needsToBeRegistered)
{
#if ENABLE(IOS_TOUCH_EVENTS)
    if (needsToBeRegistered && !canUseCompositedScrolling())
        registerAsTouchEventListenerForScrolling();
    else {
        // We only need the touch listener for unaccelerated overflow scrolling, so if we became
        // accelerated, remove ourselves as a touch event listener.
        unregisterAsTouchEventListenerForScrolling();
    }
#else
    UNUSED_PARAM(needsToBeRegistered);
#endif
}

void RenderLayerScrollableArea::paintScrollCornerPart(NOESCAPE LentGraphicsContext context, LayoutPoint paintOffset, LayoutRect rect)
{
    m_scrollCorner->paintIntoRect(*context, paintOffset, rect);
}

void RenderLayerScrollableArea::paintResizerPart(NOESCAPE LentGraphicsContext context, LayoutPoint paintOffset, LayoutRect rect)
{
    m_resizer->paintIntoRect(*context, paintOffset, rect);
}

void RenderLayerScrollableArea::paintPlatformResizer(NOESCAPE LentGraphicsContext context, LayoutRect rect)
{
    auto& renderer = m_layer.renderer();
    renderer.theme().paintPlatformResizer(renderer, *context, rect);
}

void RenderLayerScrollableArea::paintPlatformResizerFrame(NOESCAPE LentGraphicsContext context, LayoutRect rect)
{
    auto& renderer = m_layer.renderer();
    renderer.theme().paintPlatformResizerFrame(renderer, *context, rect);
}

bool RenderLayerScrollableArea::scroll(ScrollDirection direction, ScrollGranularity granularity, unsigned stepCount)
{
    return ScrollableArea::scroll(direction, granularity, stepCount);
}

void RenderLayerScrollableArea::updateSnapOffsets()
{
    // FIXME: Extend support beyond HTMLElements.
    RefPtr enclosingElement = m_layer.enclosingElement();
    if (!is<HTMLElement>(enclosingElement))
        return;

    CheckedPtr box = enclosingElement->renderBox();
    if (!box)
        return;

    if (!mayHaveScrollSnappedBoxes(*box)) {
        clearSnapOffsets();
        return;
    }
    updateSnapOffsetsForScrollableArea(*this, *box, box->style(), box->paddingBoxRect(), box->style().writingMode(), protect(m_layer.renderer().document().focusedElement()).get(), protect(m_layer.renderer().document().cssTarget()).get());
}

void RenderLayerScrollableArea::paintOverlayScrollbars(GraphicsContext& context, const LayoutRect& damageRect, OptionSet<PaintBehavior> paintBehavior, RenderObject* subtreePaintRoot)
{
    if (!m_containsDirtyOverlayScrollbars)
        return;

    LayerFreeForbiddenScope layerFreeForbiddenScope;
    RenderLayer::LayerPaintingInfo paintingInfo(&m_layer, enclosingIntRect(damageRect), paintBehavior, LayoutSize(), subtreePaintRoot);
    m_layer.paintLayer(LentGraphicsContext { context }, paintingInfo, RenderLayer::PaintLayerFlag::PaintingOverlayScrollbars);

    m_containsDirtyOverlayScrollbars = false;
}

GraphicsLayer* RenderLayerScrollableArea::layerForHorizontalScrollbar() const
{
    return m_layer.backing() ? m_layer.backing()->layerForHorizontalScrollbar() : nullptr;
}

GraphicsLayer* RenderLayerScrollableArea::layerForVerticalScrollbar() const
{
    return m_layer.backing() ? m_layer.backing()->layerForVerticalScrollbar() : nullptr;
}

GraphicsLayer* RenderLayerScrollableArea::layerForScrollCorner() const
{
    return m_layer.backing() ? m_layer.backing()->layerForScrollCorner() : nullptr;
}

void RenderLayerScrollableArea::updateScrollCornerStyle()
{
    auto& renderer = m_layer.renderer();
    RenderElement* actualRenderer = rendererForScrollbar(renderer);
    auto corner = (renderer.hasNonVisibleOverflow() && !renderer.style().usesStandardScrollbarStyle()) ? actualRenderer->resolvePseudoElementStyle({ PseudoElementType::WebKitScrollbarCorner }, &actualRenderer->style()) : nullptr;

    if (!corner) {
        clearScrollCorner();
        return;
    }

    if (!m_scrollCorner) {
        m_scrollCorner = createRenderer<RenderScrollbarPart>(protect(renderer.document()), makeUniqueRefFromNonNullUniquePtr(WTF::move(corner)));
        // FIXME: A renderer should be a child of its parent!
        m_scrollCorner->setParent(&renderer);
        m_scrollCorner->initializeStyle();
    } else
        m_scrollCorner->setStyle(makeUniqueRefFromNonNullUniquePtr(WTF::move(corner)));
}

void RenderLayerScrollableArea::clearScrollCorner()
{
    if (!m_scrollCorner)
        return;
    m_scrollCorner->setParent(nullptr);
    m_scrollCorner = nullptr;
}

void RenderLayerScrollableArea::updateResizerStyle()
{
    if (!m_resizer && !m_layer.canResize())
        return;

    auto& renderer = m_layer.renderer();
    RenderElement* actualRenderer = rendererForScrollbar(renderer);
    auto resizer = renderer.hasNonVisibleOverflow() ? actualRenderer->resolvePseudoElementStyle({ PseudoElementType::WebKitResizer }, &actualRenderer->style()) : nullptr;

    if (!resizer) {
        clearResizer();
        return;
    }

    if (!m_resizer) {
        m_resizer = createRenderer<RenderScrollbarPart>(protect(renderer.document()), makeUniqueRefFromNonNullUniquePtr(WTF::move(resizer)));
        // FIXME: A renderer should be a child of its parent!
        m_resizer->setParent(&renderer);
        m_resizer->initializeStyle();
    } else
        m_resizer->setStyle(makeUniqueRefFromNonNullUniquePtr(WTF::move(resizer)));
}

void RenderLayerScrollableArea::clearResizer()
{
    if (!m_resizer)
        return;
    m_resizer->setParent(nullptr);
    m_resizer = nullptr;
}

static inline int adjustedScrollDelta(int beginningDelta)
{
    // This implemention matches Firefox's.
    // http://mxr.mozilla.org/firefox/source/toolkit/content/widgets/browser.xml#856.
    const int speedReducer = 12;

    int adjustedDelta = beginningDelta / speedReducer;
    if (adjustedDelta > 1)
        adjustedDelta = static_cast<int>(adjustedDelta * sqrt(static_cast<double>(adjustedDelta))) - 1;
    else if (adjustedDelta < -1)
        adjustedDelta = static_cast<int>(adjustedDelta * sqrt(static_cast<double>(-adjustedDelta))) + 1;

    return adjustedDelta;
}

static inline IntSize adjustedScrollDelta(const IntSize& delta)
{
    return IntSize(adjustedScrollDelta(delta.width()), adjustedScrollDelta(delta.height()));
}

void RenderLayerScrollableArea::panScrollFromPoint(const IntPoint& sourcePoint)
{
    IntPoint lastKnownMousePosition = flooredIntPoint(m_layer.renderer().frame().eventHandler().lastKnownMousePosition());

    // We need to check if the last known mouse position is out of the window. When the mouse is out of the window, the position is incoherent
    static IntPoint previousMousePosition;
    if (lastKnownMousePosition.x() < 0 || lastKnownMousePosition.y() < 0)
        lastKnownMousePosition = previousMousePosition;
    else
        previousMousePosition = lastKnownMousePosition;

    IntSize delta = lastKnownMousePosition - sourcePoint;

    if (std::abs(delta.width()) <= ScrollView::noPanScrollRadius) // at the center we let the space for the icon
        delta.setWidth(0);
    if (std::abs(delta.height()) <= ScrollView::noPanScrollRadius)
        delta.setHeight(0);

    scrollByRecursively(adjustedScrollDelta(delta));
}

void RenderLayerScrollableArea::scrollByRecursively(const IntSize& delta, ScrollableArea** scrolledArea)
{
    if (delta.isZero())
        return;

    auto& renderer = m_layer.renderer();
    bool restrictedByLineClamp = false;
    if (renderer.parent())
        restrictedByLineClamp = renderer.parent()->style().hasLegacyLineClamp();

    if (renderer.hasNonVisibleOverflow() && !restrictedByLineClamp) {
        ScrollOffset newScrollOffset = scrollOffset() + delta;
        scrollToOffset(newScrollOffset);
        if (scrolledArea)
            *scrolledArea = this;

        // If this layer can't do the scroll we ask the next layer up that can scroll to try
        IntSize remainingScrollOffset = newScrollOffset - scrollOffset();
        if (!remainingScrollOffset.isZero() && renderer.parent()) {
            // FIXME: This skips scrollable frames.
            if (auto* enclosingScrollableLayer = m_layer.enclosingScrollableLayer(IncludeSelfOrNot::ExcludeSelf, CrossFrameBoundaries::Yes)) {
                if (CheckedPtr scrollableArea = enclosingScrollableLayer->scrollableArea())
                    scrollableArea->scrollByRecursively(remainingScrollOffset, scrolledArea);
            }

            renderer.frame().eventHandler().updateAutoscrollRenderer();
        }
    } else {
        // If we are here, we were called on a renderer that can be programmatically scrolled, but doesn't
        // have an overflow clip. Which means that it is a document node that can be scrolled.
        protect(renderer.view().frameView())->scrollBy(delta);
        if (scrolledArea)
            *scrolledArea = &renderer.view().frameView();

        // FIXME: If we didn't scroll the whole way, do we want to try looking at the frames ownerElement?
        // https://bugs.webkit.org/show_bug.cgi?id=28237
    }
}

void RenderLayerScrollableArea::logMockScrollbarsControllerMessage(const String& message) const
{
    protect(m_layer.renderer().document())->addConsoleMessage(MessageSource::Other, MessageLevel::Debug, makeString("RenderLayer: "_s, message));
}

void RenderLayerScrollableArea::didStartScrollAnimation()
{
    protect(m_layer.page())->scheduleRenderingUpdate({ RenderingUpdateStep::Scroll });
}

void RenderLayerScrollableArea::updateAnchorPositionedAfterScroll()
{
    Style::AnchorPositionEvaluator::updateScrollAdjustments(m_layer.renderer().view());
}

std::optional<FrameIdentifier> RenderLayerScrollableArea::rootFrameID() const
{
    return m_layer.renderer().frame().rootFrame().frameID();
}

void RenderLayerScrollableArea::scrollbarWidthChanged(ScrollbarWidth width)
{
    scrollbarsController().scrollbarWidthChanged(width);
    availableContentSizeChanged(AvailableSizeChangeReason::ScrollbarsChanged);
}

#if ENABLE(FORM_CONTROL_REFRESH)
bool RenderLayerScrollableArea::formControlRefreshEnabled() const
{
    return m_layer.page().settings().formControlRefreshEnabled();
}
#endif


} // namespace WebCore
