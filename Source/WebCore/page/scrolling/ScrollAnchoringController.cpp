/*
* Copyright (C) 2022 Apple Inc. All rights reserved.
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
#include "ScrollAnchoringController.h"

#include "ContainerNodeInlines.h"
#include "Document.h"
#include "DocumentQuirks.h"
#include "FloatRect.h"
#include "LegacyRenderSVGModelObject.h"
#include "LocalFrameView.h"
#include "Logging.h"
#include "Quirks.h"
#include "RenderBlockFlow.h"
#include "RenderBox.h"
#include "RenderBoxInlines.h"
#include "RenderElementInlines.h"
#include "RenderIterator.h"
#include "RenderLayerScrollableArea.h"
#include "RenderObjectInlines.h"
#include "RenderSVGModelObject.h"
#include "RenderText.h"
#include "RenderView.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollAnchoringController);

ScrollAnchoringController::ScrollAnchoringController(ScrollableArea& owningScroller)
    : m_owningScrollableArea(owningScroller)
{
}

ScrollAnchoringController::~ScrollAnchoringController()
{
    invalidate();
}

void ScrollAnchoringController::updateScrollableAreaRegistration()
{
    Ref frameView = this->frameView();
    if (shouldMaintainScrollAnchor())
        frameView->addScrollableAreaForScrollAnchoring(m_owningScrollableArea);
    else
        frameView->removeScrollableAreaForScrollAnchoring(m_owningScrollableArea);
}

LocalFrameView& ScrollAnchoringController::frameView() const
{
    if (auto* renderLayerScrollableArea = dynamicDowncast<RenderLayerScrollableArea>(m_owningScrollableArea))
        return renderLayerScrollableArea->layer().renderer().view().frameView();

    return downcast<LocalFrameView>(downcast<ScrollView>(m_owningScrollableArea));
}

RenderBox* ScrollAnchoringController::scrollableAreaBox() const
{
    if (auto* renderLayerScrollableArea = dynamicDowncast<RenderLayerScrollableArea>(m_owningScrollableArea))
        return renderLayerScrollableArea->layer().renderBox();

    if (auto* frameView = dynamicDowncast<LocalFrameView>(downcast<ScrollView>(m_owningScrollableArea)))
        return frameView->renderView();

    return nullptr;
}

void ScrollAnchoringController::invalidate()
{
    LOG_WITH_STREAM(ScrollAnchoring, stream << "ScrollAnchoringController " << this << " invalidateAnchorElement() invalidating anchor for frame: " << frameView() << " for scroller: " << m_owningScrollableArea);

    m_anchorObject = nullptr;
    m_lastAnchorOffset = { };

    if (m_isQueuedForScrollPositionUpdate) {
        m_isQueuedForScrollPositionUpdate = false;
        protect(frameView())->dequeueScrollableAreaForScrollAnchoringUpdate(m_owningScrollableArea);
    }
}

static FloatRect candidateLocalRectForAnchoring(RenderObject& renderer)
{
    if (CheckedPtr box = dynamicDowncast<RenderBox>(renderer)) {
        auto anchoringBounds = box->borderBoxRect();
        if (!box->hasNonVisibleOverflow())
            anchoringBounds.shiftMaxYEdgeTo(box->layoutOverflowRect().maxY());

        return anchoringBounds;
    }

    if (CheckedPtr text = dynamicDowncast<RenderText>(renderer))
        return text->linesBoundingBox();

    if (CheckedPtr text = dynamicDowncast<RenderText>(renderer))
        return text->linesBoundingBox();

    if (is<LegacyRenderSVGModelObject>(renderer))
        return renderer.decoratedBoundingBox();

    if (is<RenderSVGModelObject>(renderer))
        return renderer.decoratedBoundingBox();

    return { };
}

auto ScrollAnchoringController::computeScrollerRelativeRects(RenderObject& candidate, RespectScrollPadding respectScrollPadding) const -> Rects
{
    CheckedPtr scrollerBox = scrollableAreaBox();
    if (!scrollerBox)
        return { };

    auto localAnchoringRect = candidateLocalRectForAnchoring(candidate);
    LOG_WITH_STREAM(ScrollAnchoring, stream << "computeScrollerRelativeRects - candidate " << candidate << " localAnchoringRect " << localAnchoringRect);

    if (scrollerBox->isRenderView()) {
        RefPtr frameView = dynamicDowncast<LocalFrameView>(downcast<ScrollView>(m_owningScrollableArea));
        if (!frameView)
            return { };

        // This is not affected by page scale.
        auto scrollViewport = frameView->visualViewportRect();

        RefPtr documentElement = frameView->frame().document() ? frameView->frame().document()->documentElement() : nullptr;
        if (!documentElement)
            return { };

        CheckedPtr docRenderer = documentElement->renderBox();
        if (!docRenderer)
            return { };

        if (respectScrollPadding == RespectScrollPadding::Yes)
            scrollViewport.contract(docRenderer->scrollPaddingForViewportRect(scrollViewport));

        return {
            // Map to the RenderView to exclude page scale.
            .boundsRelativeToScrolledContent = candidate.localToContainerQuad(localAnchoringRect, dynamicDowncast<RenderView>(*scrollerBox)).boundingBox(),
            .scrollerContentsVisibleRect = scrollViewport
        };
    }

    CheckedRef owningScrollableArea = m_owningScrollableArea;
    auto scrollerRect = LayoutRect { owningScrollableArea->visibleContentRect() };
    if (respectScrollPadding == RespectScrollPadding::Yes)
        scrollerRect.contract(scrollerBox->scrollPaddingForViewportRect(scrollerRect));

    // FIXME: Check for writing modes.
    // FIXME: This really needs to compute bounds relative to the padding box.
    auto boundsInScrollerContentCoordinates = candidate.localToContainerQuad(localAnchoringRect, scrollerBox.get()).boundingBox();
    boundsInScrollerContentCoordinates.moveBy(owningScrollableArea->scrollPosition());

    return {
        .boundsRelativeToScrolledContent = boundsInScrollerContentCoordinates,
        .scrollerContentsVisibleRect = scrollerRect
    };
}

// For each absolutely-positioned element A whose containing block is N...
AnchorSearchStatus ScrollAnchoringController::findAnchorInOutOfFlowObjects(RenderObject& candidate)
{
    CheckedPtr containingBlock = dynamicDowncast<RenderBoxModelObject>(candidate);
    if (!containingBlock)
        return AnchorSearchStatus::Exclude;

    auto* outOfFlowBoxes = containingBlock->outOfFlowBoxes();
    if (!outOfFlowBoxes)
        return AnchorSearchStatus::Exclude;

    for (CheckedRef outOfFlowBox : *outOfFlowBoxes) {
        auto status = findAnchorRecursive(outOfFlowBox.ptr());
        if (isViableStatus(status))
            return status;
    }

    return AnchorSearchStatus::Exclude;
}

bool ScrollAnchoringController::hasOverflowAnchorNone(const RenderElement& renderer)
{
    return renderer.style().overflowAnchor() == OverflowAnchor::None;
}

bool ScrollAnchoringController::shouldDisableScrollAnchoringQuirk(const RenderBox& scrollerBox)
{
    return protect(scrollerBox.document())->quirks().shouldDisableScrollAnchoringQuirk();
}

bool ScrollAnchoringController::shouldDescendIntoObjectWithEmptyLayoutOverflow(const RenderObject& candidate)
{
    if (!is<RenderElement>(candidate))
        return false;

    if (candidate.isInline())
        return true;

    if (CheckedPtr blockFlow = dynamicDowncast<RenderBlockFlow>(candidate))
        return blockFlow->subtreeContainsFloats();

    return false;
}

Document* ScrollAnchoringController::frameDocument() const
{
    return frameView().frame().document();
}

void ScrollAnchoringController::queueForScrollPositionUpdate()
{
    protect(frameView())->queueScrollableAreaForScrollAnchoringUpdate(m_owningScrollableArea);
}

void ScrollAnchoringController::scrollOwningScrollableArea(ScrollPosition newScrollPosition, FloatSize adjustment)
{
    CheckedRef owningScrollableArea = m_owningScrollableArea;
    auto options = ScrollPositionChangeOptions::createProgrammatic();
    options.originalScrollDelta = adjustment;
    options.interruptsAnimation = ScrollInterruptsAnimation::No;

    auto revealScope = ScrollbarRevealBehaviorScope(owningScrollableArea, ScrollbarRevealBehavior::DontReveal);
    auto scrollTypeScope = ScrollTypeScope(owningScrollableArea, ScrollType::Programmatic);

    // FIXME: This has to explicitly not stop animated scrolls (use ImplicitDeltaUpdate).
    if (!owningScrollableArea->requestScrollToPosition(newScrollPosition, options))
        owningScrollableArea->scrollToPositionWithoutAnimation(newScrollPosition);
}

bool ScrollAnchoringController::DisablementHeuristic::disabledByHeuristic(IntSize adjustment)
{
    auto now = ApproximateTime::now();

    if (m_nextEnablementTime && now < *m_nextEnablementTime) {
        LOG_WITH_STREAM(ScrollAnchoring, stream << "ScrollAnchoringController::DisablementHeuristic - currently disabled");
        return true;
    }

    auto nonZeroAxis = [](IntSize adjustment) {
        if (adjustment.height())
            return adjustment.height();
        return adjustment.width();
    };

    if (!m_samplingStartTime) {
        m_samplingStartTime = now;
        m_accumulatedAdjustment = nonZeroAxis(adjustment);
        m_samplingAdjustmentCount = 1;
        return false;
    }

    ++m_samplingAdjustmentCount;
    m_accumulatedAdjustment += nonZeroAxis(adjustment);

    // This is designed to detect feedback between scroll anchoring and content changes that trigger scroll position oscillations,
    // so look for adjustments that happen within a few frames that have cumulative small delta. Try to re-enable after 3s.
    static constexpr unsigned maxAdjustments = 10;
    static constexpr auto samplingDuration = 350_ms;
    static constexpr auto reenablementDelay = 3_s;
    static constexpr float meanAdjustmentMax = 2.0f;
    auto timeSinceSamplingStart = now - *m_samplingStartTime;

    if (timeSinceSamplingStart < samplingDuration) {
        if (m_samplingAdjustmentCount < maxAdjustments)
            return false;

        auto meanAdjustment = std::abs(m_accumulatedAdjustment / m_samplingAdjustmentCount);
        if (meanAdjustment > meanAdjustmentMax)
            return false;

        LOG_WITH_STREAM(ScrollAnchoring, stream << "ScrollAnchoringController::DisablementHeuristic - suppressing anchoring because " << m_samplingAdjustmentCount << " adjustments in the last " << timeSinceSamplingStart << " with mean adjustment " << meanAdjustment << ". Trying again in " << reenablementDelay);
        reset();
        m_nextEnablementTime = now + reenablementDelay;
        return true;
    }

    reset();
    return false;
}

void ScrollAnchoringController::DisablementHeuristic::reset()
{
    LOG_WITH_STREAM(ScrollAnchoring, stream << "ScrollAnchoringController::DisablementHeuristic - reset");
    m_nextEnablementTime = { };
    m_samplingStartTime = { };
    m_accumulatedAdjustment = 0;
    m_samplingAdjustmentCount = 0;
}

} // namespace WebCore
