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

internal import WebCore_Private.Core.Document
internal import WebCore_Private.Core.Editing
internal import WebCore_Private.Core.Element
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.IntSize
internal import WebCore_Private.Core.LocalFrame
internal import WebCore_Private.Core.LocalFrameView
internal import WebCore_Private.Core.Logging
internal import WebCore_Private.Core.RenderBlock
internal import WebCore_Private.Core.RenderBox
internal import WebCore_Private.Core.RenderElement
internal import WebCore_Private.Core.RenderLayer
internal import WebCore_Private.Core.RenderLayerModelObject
internal import WebCore_Private.Core.RenderLayerScrollableArea
internal import WebCore_Private.Core.RenderObject
internal import WebCore_Private.Core.RenderObjectStyle
internal import WebCore_Private.Core.ScrollAnchoringController
import os
internal import wtf

private let scrollAnchoringLogger = Logger(subsystem: "com.apple.WebKit", category: "ScrollAnchoring")

// LOG_WITH_STREAM(ScrollAnchoring, ...): writeMessage runs only while the channel is on.
private func logScrollAnchoring(_ writeMessage: (inout WTF.TextStream) -> Void) {
    #if !LOG_DISABLED
    guard WebCore.LogChannel.ScrollAnchoring().state != .Off else {
        return
    }
    var stream = WTF.TextStream(.SingleLine)
    writeMessage(&stream)
    WTF.logPreformatted(WebCore.LogChannel.ScrollAnchoring(), stream.release())
    #endif
}

private func isSameRenderer(_ a: WebCore.RenderObject?, _ b: WebCore.RenderObject?) -> Bool {
    WebCore.RenderObject.isSameRenderer(a, b)
}

private func isSamePosition(_ a: WebCore.ScrollPosition, _ b: WebCore.ScrollPosition) -> Bool {
    a.x() == b.x() && a.y() == b.y()
}

extension WebCore.WritingMode {
    fileprivate func hasScrolledFromOriginInBlockDirection(_ scrollPosition: WebCore.ScrollPosition) -> Bool {
        if isVertical() {
            return scrollPosition.x() != 0
        }
        return scrollPosition.y() != 0
    }

    fileprivate func constrainedToBlockDirection(_ scrollDelta: WebCore.IntSize) -> WebCore.IntSize {
        if isVertical() {
            return WebCore.IntSize(scrollDelta.width(), 0)
        }
        return WebCore.IntSize(0, scrollDelta.height())
    }

    fileprivate func inlineAndBlockStartCorner(of box: WebCore.FloatRect) -> WebCore.FloatPoint {
        switch blockDirection() {
        case .TopToBottom:
            return isInlineLeftToRight() ? box.location() : box.maxXMinYCorner()
        case .BottomToTop:
            return isInlineLeftToRight() ? box.minXMaxYCorner() : box.maxXMaxYCorner()
        case .LeftToRight:
            return isInlineTopToBottom() ? box.minXMinYCorner() : box.minXMaxYCorner()
        case .RightToLeft:
            return isInlineTopToBottom() ? box.maxXMinYCorner() : box.maxXMaxYCorner()
        @unknown default:
            return box.location()
        }
    }
}

extension WebCore.AnchorSearchStatus {
    fileprivate var name: Swift.String {
        switch self {
        case .Exclude: "Exclude"
        case .Continue: "Continue"
        case .Constrain: "Constrain"
        case .Choose: "Choose"
        @unknown default: ""
        }
    }
}

extension WebCore.RenderElement {
    fileprivate func mayMoveWithScroller(_ scrollerBox: WebCore.RenderBox) -> Bool {
        if isStickilyPositioned() || isFixedPositioned() {
            return false
        }
        return scrollerBox.asRenderBlock()!.isContainingBlockAncestorFor(self)
    }
}

extension WebCore.ScrollAnchoringController {
    private static func overflowAnchorProhibitsAnchoring(_ object: WebCore.RenderElement, _ scrollingAncestor: WebCore.RenderBox) -> Bool {
        var renderer: WebCore.RenderElement? = object
        while let current = renderer {
            if hasOverflowAnchorNone(current) {
                return true
            }
            if isSameRenderer(current, scrollingAncestor) {
                break
            }
            renderer = (current as WebCore.RenderObject).parent()
        }
        return false
    }
}

extension WebCore.Element {
    fileprivate var priorityCandidate: WebCore.RenderElement? {
        var element: WebCore.Element? = self
        while let current = element {
            if let renderer = current.renderer() {
                if !renderer.isAnonymousBlock() && (!renderer.isInline() || renderer.isAtomicInlineLevelBox()) {
                    return renderer
                }
            }
            element = current.parentElement()
        }
        return nil
    }
}

extension WebCore.ScrollAnchoringController {
    @cxx
    @implementation
    func shouldMaintainScrollAnchor() -> Bool {
        guard let scrollerBox = scrollableAreaBox() else {
            return false
        }

        // FIXME: Writing modes: only check the block direction?
        if !scrollerBox.hasPotentiallyScrollableOverflow() {
            return false
        }

        if Self.hasOverflowAnchorNone(scrollerBox) {
            return false
        }

        return scrollerBox.writingMode().hasScrolledFromOriginInBlockDirection(owningScrollPosition())
    }

    @cxx
    @implementation
    func scrollPositionDidChange() {
        if m_isUpdatingScrollPositionForAnchoring {
            return
        }

        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController::scrollPositionChanged() to ".utf8.span)
            stream.append(owningScrollPosition())
            stream.appendUTF8(" - clearing scroll anchor".utf8.span)
        }

        if owningScrollType() == .User {
            m_disablementHeuristic.reset()
        }

        clearAnchor(false)
        updateScrollableAreaRegistration()
    }

    @cxx
    @implementation
    func scrollerDidLayout() {
        updateScrollableAreaRegistration()
    }

    @cxx
    @implementation
    func clearAnchor(_ includeAncestors: Bool) {
        if m_isUpdatingScrollPositionForAnchoring {
            return
        }

        m_anchorObject = .init()
        m_lastAnchorOffset = .init()

        guard includeAncestors, !owningScrollableAreaIsScrollView(), let scrollerBox = scrollableAreaBox() else {
            return
        }

        var layer = scrollerBox.layer()
        while let current = layer {
            current.scrollableArea()?.scrollAnchoringController()?.clearAnchor(false)
            layer = current.parent()
        }
    }

    // https://drafts.csswg.org/css-scroll-anchoring/#scroll-adjustment
    // ...of the block start edge of the anchor node’s scroll anchoring bounding rect,
    // relative to the block start edge of the scrolling content in the block flow direction of the scroller.
    @cxx
    @implementation
    func computeOffsetFromOwningScroller(_ candidate: WebCore.RenderObject, _ scrollerBox: WebCore.RenderBox) -> WebCore.FloatPoint {
        let rects = computeScrollerRelativeRects(candidate, .No)

        let candidateCorner = candidate.writingMode().inlineAndBlockStartCorner(of: rects.boundsRelativeToScrolledContent)
        let scrollerCorner = scrollerBox.writingMode().inlineAndBlockStartCorner(of: rects.scrollerContentsVisibleRect)

        return WebCore.FloatPoint(candidateCorner.x() - scrollerCorner.x(), candidateCorner.y() - scrollerCorner.y())
    }

    @cxx
    @implementation
    func notifyChildHadSuppressingStyleChange(_ renderer: WebCore.RenderElement) {
        let scrollerBox = scrollableAreaBox()!

        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController ".utf8.span)
            writeAddress(&stream)
            stream.appendUTF8(" notifyChildHadSuppressingStyleChange() for ".utf8.span)
            stream.append(scrollerBox)
            stream.appendUTF8(" for ".utf8.span)
            stream.append(renderer)
        }

        scrollerBox.setScrollAnchoringSuppressionStyleChanged(true)
    }

    // MARK: - Anchor selection

    // https://drafts.csswg.org/css-scroll-anchoring/#anchor-priority-candidates
    @cxx
    @implementation
    func findPriorityCandidate(_ document: WebCore.Document) -> Bool {
        if scrollableAreaBox() == nil {
            return false
        }

        if let focusedElement = document.focusedElement(), WebCore.isEditableNode(focusedElement),
            let candidate = focusedElement.priorityCandidate
        {
            if Self.isViableStatus(examinePriorityCandidate(candidate)) {
                m_anchorObject = .init(candidate)
                // FIXME: Look inside the candidate?
                return true
            }
        }

        // FIXME: Find in page match

        return false
    }

    @cxx
    @implementation
    func examinePriorityCandidate(_ renderer: WebCore.RenderElement) -> WebCore.AnchorSearchStatus {
        let scrollerBox = scrollableAreaBox()

        var ancestor: WebCore.RenderElement? = renderer
        while let current = ancestor, !isSameRenderer(current, scrollerBox) {
            if Self.hasOverflowAnchorNone(current) {
                return .Exclude
            }

            if !current.mayMoveWithScroller(scrollerBox!) {
                return .Exclude
            }

            ancestor = (current as WebCore.RenderObject).parent()
        }

        guard let ancestor else {
            return .Exclude
        }

        return examineAnchorCandidate(ancestor)
    }

    // https://drafts.csswg.org/css-scroll-anchoring/#candidate-examination
    @cxx
    @implementation
    func examineAnchorCandidate(_ candidate: WebCore.RenderObject) -> WebCore.AnchorSearchStatus {
        let scrollerBox = scrollableAreaBox()

        if isSameRenderer(candidate, scrollerBox) {
            return .Continue
        }

        var isScrollableWithAnchor = false

        if let renderer = candidate.asRenderElement() {
            if Self.overflowAnchorProhibitsAnchoring(renderer, scrollerBox!) {
                return .Exclude
            }

            if candidate.isBR() {
                return .Exclude
            }

            if candidate.isAnonymous() {
                return .Continue
            }

            if !renderer.mayMoveWithScroller(scrollerBox!) {
                return .Exclude
            }

            if let candidateBox = candidate.asRenderBox(), candidateBox.canBeScrolledAndHasScrollableArea(), candidateBox.hasLayer(),
                let controller = candidate.asRenderLayerModelObject()!.layer()!.scrollableArea()?.scrollAnchoringController()
            {
                isScrollableWithAnchor = controller.shouldMaintainScrollAnchor()
            }
        }

        let rects = computeScrollerRelativeRects(candidate, .Yes)
        if rects.boundsRelativeToScrolledContent.isEmpty() {
            if Self.shouldDescendIntoObjectWithEmptyLayoutOverflow(candidate) {
                return .Continue
            }
            return .Exclude
        }

        if rects.scrollerContentsVisibleRect.contains(rects.boundsRelativeToScrolledContent) {
            return .Choose
        }

        // This takes scroll padding into account
        let intersectionRect = WebCore.intersection(rects.boundsRelativeToScrolledContent, rects.scrollerContentsVisibleRect)
        logScrollAnchoring { stream in
            stream.appendUTF8(" bounds in scrolled content ".utf8.span)
            stream.append(rects.boundsRelativeToScrolledContent)
            stream.appendUTF8(" scroller viewport ".utf8.span)
            stream.append(rects.scrollerContentsVisibleRect)
            stream.appendUTF8(" intersectionRect ".utf8.span)
            stream.append(intersectionRect)
        }

        if intersectionRect.isEmpty() {
            return .Exclude
        }

        return isScrollableWithAnchor ? .Choose : .Constrain
    }

    @cxx
    @implementation
    func findAnchorRecursive(_ object: WebCore.RenderObject?) -> WebCore.AnchorSearchStatus {
        guard let object, object.everHadLayout() else {
            return .Exclude
        }

        let status = examineAnchorCandidate(object)
        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController ".utf8.span)
            writeAddress(&stream)
            stream.appendUTF8(" findAnchorRecursive() element: ".utf8.span)
            stream.append(object)
            stream.appendUTF8(" examination result: ".utf8.span)
            stream.appendUTF8(status.name.utf8.span)
        }

        if Self.isViableStatus(status) {
            m_anchorObject = .init(object)
        }

        if status == .Choose || status == .Exclude {
            return status
        }

        guard let renderElement = object.asRenderElement() else {
            return .Exclude
        }

        var child = renderElement.firstChild()
        while let current = child {
            let childStatus = findAnchorRecursive(current)
            if childStatus == .Choose {
                return childStatus
            }

            if childStatus == .Constrain {
                // FIXME: Do something better in fragmented contexts?
                return childStatus
            }
            child = current.nextSibling()
        }

        let outOfFlowStatus = findAnchorInOutOfFlowObjects(object)
        if Self.isViableStatus(outOfFlowStatus) {
            return outOfFlowStatus
        }

        return status
    }

    // https://drafts.csswg.org/css-scroll-anchoring/#anchor-node-selection
    @cxx
    @implementation
    func chooseAnchorElement(_ document: WebCore.Document, _ scrollerBox: WebCore.RenderBox) {
        if !findPriorityCandidate(document) {
            _ = findAnchorRecursive(scrollableAreaBox())
        }

        guard let anchorObject = m_anchorObject.get() else {
            logScrollAnchoring { stream in
                stream.appendUTF8("ScrollAnchoringController ".utf8.span)
                writeAddress(&stream)
                stream.appendUTF8(" chooseAnchorElement() failed to find anchor".utf8.span)
            }
            return
        }

        m_lastAnchorOffset = computeOffsetFromOwningScroller(anchorObject, scrollerBox)
        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController::chooseAnchorElement() found anchor: ".utf8.span)
            stream.append(anchorObject)
            stream.appendUTF8(" offset: ".utf8.span)
            stream.append(m_lastAnchorOffset)
        }
    }

    // https://drafts.csswg.org/css-scroll-anchoring/#suppression-triggers
    @cxx
    @implementation
    func anchoringSuppressedByStyleChange() -> Bool {
        guard let anchorObject = m_anchorObject.get() else {
            return false
        }

        let scrollerBox = scrollableAreaBox()

        // ...any element in the path from the anchor node to the scrollable element (or document), inclusive of both.
        // m_anchorObject can be a RenderText, but that will never have scrollAnchoringSuppressionStyleChanged() set.
        if let renderer = anchorObject.asRenderElement(), renderer.scrollAnchoringSuppressionStyleChanged() {
            return true
        }

        var renderer = anchorObject.parent()
        while let current = renderer {
            if current.scrollAnchoringSuppressionStyleChanged() {
                return true
            }
            if isSameRenderer(current, scrollerBox) {
                break
            }
            renderer = (current as WebCore.RenderObject).parent()
        }

        return false
    }

    // MARK: - Layout

    @cxx
    @implementation
    func updateBeforeLayout() {
        let scrollerBox = scrollableAreaBox()!

        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController ".utf8.span)
            writeAddress(&stream)
            stream.appendUTF8(" on ".utf8.span)
            stream.append(scrollerBox)
            stream.appendUTF8(" updateBeforeLayout() - scroll position ".utf8.span)
            stream.append(owningScrollPosition())
            stream.appendUTF8(" queued ".utf8.span)
            stream.append(m_isQueuedForScrollPositionUpdate)
        }

        if Self.shouldDisableScrollAnchoringQuirk(scrollerBox) {
            invalidate()
            return
        }

        if m_isQueuedForScrollPositionUpdate {
            m_anchoringSuppressedByStyleChange = m_anchoringSuppressedByStyleChange || anchoringSuppressedByStyleChange()
            return
        }

        let scrollPosition = owningScrollPosition()
        if !scrollerBox.writingMode().hasScrolledFromOriginInBlockDirection(scrollPosition)
            || !isSamePosition(owningConstrainedScrollPosition(scrollPosition), scrollPosition)
        {
            clearAnchor(false)
            return
        }

        if m_anchorObject.get() == nil {
            guard let document = frameDocument() else {
                return
            }

            chooseAnchorElement(document, scrollerBox)
            if m_anchorObject.get() == nil {
                logScrollAnchoring { stream in
                    stream.appendUTF8("ScrollAnchoringController ".utf8.span)
                    writeAddress(&stream)
                    stream.appendUTF8(" updateBeforeLayout() - did not find anchor".utf8.span)
                }
                return
            }
        }

        m_anchoringSuppressedByStyleChange = anchoringSuppressedByStyleChange()

        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController ".utf8.span)
            writeAddress(&stream)
            stream.appendUTF8(" updateBeforeLayout() - anchor ".utf8.span)
            stream.append(m_anchorObject.get()!)
            stream.appendUTF8(" offset ".utf8.span)
            stream.append(m_lastAnchorOffset)
            stream.appendUTF8(" suppressedByStyleChange ".utf8.span)
            stream.append(m_anchoringSuppressedByStyleChange)
        }

        queueForScrollPositionUpdate()
        m_isQueuedForScrollPositionUpdate = true
    }

    // https://drafts.csswg.org/css-scroll-anchoring/#scroll-adjustment
    @cxx
    @implementation
    func adjustScrollPositionForAnchoring() {
        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController ".utf8.span)
            writeAddress(&stream)
            stream.appendUTF8(" adjustScrollPositionForAnchoring() - anchor ".utf8.span)
            stream.append(m_anchorObject.get())
            stream.appendUTF8(" offset ".utf8.span)
            stream.append(m_lastAnchorOffset)
            stream.appendUTF8(" suppressedByStyleChange  ".utf8.span)
            stream.append(m_anchoringSuppressedByStyleChange)
            stream.appendUTF8(" in scroll event ".utf8.span)
            stream.append(m_inScrollEventCount != 0)
            stream.appendUTF8(" in suppression scope ".utf8.span)
            stream.append(m_suppressionCount != 0)
        }

        // FIXME: Test for running animated scrolls?
        if m_inScrollEventCount != 0 || m_suppressionCount != 0 {
            // Drop the suppressed update so that the next layout picks a new anchor.
            // FIXME: Adjustments suppressed during scroll events stay queued, which keeps scroll anchoring off afterwards.
            if m_suppressionCount != 0 {
                m_isQueuedForScrollPositionUpdate = false
            }
            m_anchoringSuppressedByStyleChange = false
            clearAnchor(false)
            return
        }

        let queued = exchange(&m_isQueuedForScrollPositionUpdate, with: false)
        guard let anchorObject = m_anchorObject.get(), queued else {
            return
        }

        if m_anchoringSuppressedByStyleChange {
            m_anchoringSuppressedByStyleChange = false
            clearAnchor(false)
            return
        }

        let wasUpdatingScrollPositionForAnchoring = exchange(&m_isUpdatingScrollPositionForAnchoring, with: true)
        defer {
            m_isUpdatingScrollPositionForAnchoring = wasUpdatingScrollPositionForAnchoring
        }

        let scrollerBox = scrollableAreaBox()!

        let currentOffset = computeOffsetFromOwningScroller(anchorObject, scrollerBox)
        var adjustment = WebCore.FloatSize(currentOffset.x() - m_lastAnchorOffset.x(), currentOffset.y() - m_lastAnchorOffset.y())
        if adjustment.isZero() {
            return
        }

        // FIXME: Handle content-visibility.

        if scrollerBox.isRenderView() {
            adjustment.scale(frameView().frame().frameScaleFactor())
        }

        var roundedAdjustment = WebCore.roundedIntSize(adjustment)
        if roundedAdjustment.isZero() {
            return
        }

        roundedAdjustment = scrollerBox.writingMode().constrainedToBlockDirection(roundedAdjustment)

        if m_disablementHeuristic.disabledByHeuristic(roundedAdjustment) {
            scrollAnchoringLogger.log(
                "ScrollAnchoringController::adjustScrollPositionForAnchoring() is main frame: \(self.frameView().frame().isMainFrame(), privacy: .public), is main scroller: \(!self.owningScrollableAreaIsRenderLayer(), privacy: .public), adjustment (\(adjustment.width(), format: .fixed(precision: 2), privacy: .public), \(adjustment.height(), format: .fixed(precision: 2), privacy: .public)) disabled by heuristic"
            )
            return
        }

        let currentPosition = owningScrollPosition()
        let newScrollPosition = WebCore.ScrollPosition(currentPosition.x() &+ roundedAdjustment.width(), currentPosition.y() &+ roundedAdjustment.height())

        scrollAnchoringLogger.log(
            "ScrollAnchoringController::adjustScrollPositionForAnchoring() is main frame: \(self.frameView().frame().isMainFrame(), privacy: .public), is main scroller: \(!self.owningScrollableAreaIsRenderLayer(), privacy: .public), adjusting from (\(currentPosition.x(), privacy: .public), \(currentPosition.y(), privacy: .public)) to (\(newScrollPosition.x(), privacy: .public), \(newScrollPosition.y(), privacy: .public))"
        )
        logScrollAnchoring { stream in
            stream.appendUTF8("ScrollAnchoringController ".utf8.span)
            writeAddress(&stream)
            stream.appendUTF8(" adjustScrollPositionForAnchoring() for scroller element: ".utf8.span)
            stream.append(scrollableAreaBox())
            stream.appendUTF8(" anchor: ".utf8.span)
            stream.append(anchorObject)
            stream.appendUTF8(" adjusting from ".utf8.span)
            stream.append(currentPosition)
            stream.appendUTF8(" to ".utf8.span)
            stream.append(newScrollPosition)
        }

        scrollOwningScrollableArea(newScrollPosition, adjustment)
    }

    // MARK: - Suppression

    @cxx
    @implementation
    func willDispatchScrollEvent() {
        m_inScrollEventCount &+= 1
    }

    @cxx
    @implementation
    func didDispatchScrollEvent() {
        assert(m_inScrollEventCount != 0)
        m_inScrollEventCount &-= 1
    }

    // These nest.
    @cxx
    @implementation
    func startSuppressingScrollAnchoring() {
        m_suppressionCount &+= 1
    }

    @cxx
    @implementation
    func stopSuppressingScrollAnchoring() {
        assert(m_suppressionCount != 0)
        m_suppressionCount &-= 1
    }
}
