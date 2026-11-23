// Copyright (C) 2012, 2015 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_ASYNC_SCROLLING

internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.ScrollPhysicsTypes
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollingCoordinator
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import WebCore_Private.Core.ScrollingStateTree
internal import wtf

extension WebCore.RequestedScrollData {
    fileprivate mutating func accumulateDelta(_ newRequest: WebCore.RequestedScrollData) {
        switch requestType {
        case .PositionUpdate:
            let position = requestedScrollPosition()
            let delta = newRequest.requestedScrollDelta()
            setRequestedScrollPosition(position + delta)
        case .DeltaUpdate, .ImplicitDeltaUpdate:
            let delta = requestedScrollDelta()
            let newDelta = newRequest.requestedScrollDelta()
            setRequestedScrollDelta(delta + newDelta)
        case .AnimatedPositionUpdate, .AnimatedDeltaUpdate, .CancelAnimatedScroll:
            assertionFailure()
            return
        @unknown default:
            return
        }
        // An empty Markable<ScrollRequestIdentifier> holds the zero identifier.
        let currentIdentifier = identifierValue()
        let newIdentifier = newRequest.identifierValue()
        if currentIdentifier != 0, newIdentifier != 0, newIdentifier > currentIdentifier {
            identifier = newRequest.identifier
        }
    }
}

private func mergeDeltaUpdate(
    _ scrollRequest: WebCore.RequestedScrollData,
    _ first: inout WebCore.RequestedScrollData,
    _ second: inout WebCore.RequestedScrollData?
) {
    assert(second.map { WebCore.isAnimatedUpdate($0.requestType) } ?? true)
    // The delta update removes any existing animation update.
    second = nil

    switch first.requestType {
    case .PositionUpdate, .DeltaUpdate:
        first.accumulateDelta(scrollRequest)
    case .ImplicitDeltaUpdate:
        if scrollRequest.requestType == .DeltaUpdate {
            first.requestType = .DeltaUpdate
        }
        first.accumulateDelta(scrollRequest)
    case .AnimatedPositionUpdate, .AnimatedDeltaUpdate:
        if scrollRequest.requestType == .ImplicitDeltaUpdate {
            // Keep the animated scroll, after the delta. The last request carries the most recent identifier.
            var animatedRequest = first
            first = scrollRequest
            first.requestType = .DeltaUpdate
            swap(&first.identifier, &animatedRequest.identifier)
            second = animatedRequest
            return
        }
        first = scrollRequest
    case .CancelAnimatedScroll:
        first = scrollRequest
        if first.requestType == .ImplicitDeltaUpdate {
            first.requestType = .DeltaUpdate
        }
    @unknown default:
        break
    }
}

private func mergeAnimatedUpdate(
    _ scrollRequest: WebCore.RequestedScrollData,
    _ first: inout WebCore.RequestedScrollData,
    _ second: inout WebCore.RequestedScrollData?
) {
    if let existing = second {
        assert(WebCore.isAnimatedUpdate(existing.requestType))
        second = scrollRequest
        return
    }

    switch first.requestType {
    case .PositionUpdate, .DeltaUpdate:
        second = scrollRequest
    case .ImplicitDeltaUpdate:
        first.requestType = .DeltaUpdate
        second = scrollRequest
    case .AnimatedPositionUpdate, .AnimatedDeltaUpdate, .CancelAnimatedScroll:
        first = scrollRequest
    @unknown default:
        break
    }
}

private func mergeCancelAnimatedScroll(
    _ scrollRequest: WebCore.RequestedScrollData,
    _ first: inout WebCore.RequestedScrollData,
    _ second: inout WebCore.RequestedScrollData?
) {
    if let existing = second {
        assert(WebCore.isAnimatedUpdate(existing.requestType))
        second = nil
        first.identifier = scrollRequest.identifier
        return
    }

    switch first.requestType {
    case .PositionUpdate, .DeltaUpdate, .CancelAnimatedScroll:
        first.identifier = scrollRequest.identifier
    case .ImplicitDeltaUpdate:
        first.requestType = .DeltaUpdate
        first.identifier = scrollRequest.identifier
    case .AnimatedPositionUpdate, .AnimatedDeltaUpdate:
        first = scrollRequest
    @unknown default:
        break
    }
}

extension WebCore.ScrollingStateScrollingNode {
    // The fields the scrolling tree's commit copies, for its Swift: a read here is visible to the optimiser, where an
    // imported getter is an opaque call around which Swift retains both nodes (docs/interop-limitations.md 56).
    var scrollableAreaSizeValue: WebCore.FloatSize { m_scrollableAreaSize }
    var totalContentsSizeValue: WebCore.FloatSize { m_totalContentsSize }
    var reachableContentsSizeValue: WebCore.FloatSize { m_reachableContentsSize }
    var scrollPositionValue: WebCore.FloatPoint { m_scrollPosition }
    var scrollOriginValue: WebCore.IntPoint { m_scrollOrigin }
    var currentHorizontalSnapPointIndexValue: WebCore.OptionalSnapPointIndex { m_currentHorizontalSnapPointIndex }
    var currentVerticalSnapPointIndexValue: WebCore.OptionalSnapPointIndex { m_currentVerticalSnapPointIndex }
    #if ENABLE_SCROLLING_THREAD
    var synchronousScrollingReasonsValue: WebCore.SynchronousScrollingReasons { m_synchronousScrollingReasons }
    #endif

    // Note that this list does not include Property::RequestedScrollPosition, which is imperative, not stateful.
    var scrollingNodeApplicableProperties: WebCore.ScrollingStateNodeProperties {
        var properties = stateNodeApplicableProperties
        properties.add(.init(
            .ScrollableAreaSize, .TotalContentsSize, .ReachableContentsSize, .ScrollPosition, .ScrollOrigin,
            .ScrollableAreaParams))
        #if ENABLE_SCROLLING_THREAD
        properties.add(.init(.ReasonsForSynchronousScrolling))
        #endif
        properties.add(.init(
            .SnapOffsetsInfo, .CurrentHorizontalSnapOffsetIndex, .CurrentVerticalSnapOffsetIndex,
            .IsMonitoringWheelEvents, .ScrollContainerLayer, .ScrolledContentsLayer, .HorizontalScrollbarLayer,
            .VerticalScrollbarLayer, .PainterForScrollbar, .ScrollbarEnabledState))
        return properties
    }

    @cxx
    @implementation
    public override func applicableProperties() -> WebCore.ScrollingStateNodeProperties {
        scrollingNodeApplicableProperties
    }

    @cxx
    @implementation
    public func setScrollableAreaSize(_ size: WebCore.FloatSize) {
        if m_scrollableAreaSize == size {
            return
        }

        m_scrollableAreaSize = size
        setPropertyChanged(.ScrollableAreaSize)
    }

    @cxx
    @implementation
    public func setTotalContentsSize(_ totalContentsSize: WebCore.FloatSize) {
        if m_totalContentsSize == totalContentsSize {
            return
        }

        m_totalContentsSize = totalContentsSize
        setPropertyChanged(.TotalContentsSize)
    }

    @cxx
    @implementation
    public func setReachableContentsSize(_ reachableContentsSize: WebCore.FloatSize) {
        if m_reachableContentsSize == reachableContentsSize {
            return
        }

        m_reachableContentsSize = reachableContentsSize
        setPropertyChanged(.ReachableContentsSize)
    }

    @cxx
    @implementation
    public func setScrollPosition(_ scrollPosition: WebCore.FloatPoint) {
        if m_scrollPosition == scrollPosition {
            return
        }

        m_scrollPosition = scrollPosition
        setPropertyChanged(.ScrollPosition)
    }

    @cxx
    @implementation
    public func setScrollOrigin(_ scrollOrigin: WebCore.IntPoint) {
        if m_scrollOrigin == scrollOrigin {
            return
        }

        m_scrollOrigin = scrollOrigin
        setPropertyChanged(.ScrollOrigin)
    }

    @cxx
    @implementation
    public func setCurrentHorizontalSnapPointIndex(_ index: WebCore.OptionalSnapPointIndex) {
        if Optional(fromCxx: m_currentHorizontalSnapPointIndex) == Optional(fromCxx: index) {
            return
        }

        m_currentHorizontalSnapPointIndex = index
        setPropertyChanged(.CurrentHorizontalSnapOffsetIndex)
    }

    @cxx
    @implementation
    public func setCurrentVerticalSnapPointIndex(_ index: WebCore.OptionalSnapPointIndex) {
        if Optional(fromCxx: m_currentVerticalSnapPointIndex) == Optional(fromCxx: index) {
            return
        }

        m_currentVerticalSnapPointIndex = index
        setPropertyChanged(.CurrentVerticalSnapOffsetIndex)
    }

    #if ENABLE_SCROLLING_THREAD
    @cxx
    @implementation
    public func setSynchronousScrollingReasons(_ reasons: WebCore.SynchronousScrollingReasons) {
        if m_synchronousScrollingReasons.toRaw() == reasons.toRaw() {
            return
        }

        m_synchronousScrollingReasons = reasons
        setPropertyChanged(.ReasonsForSynchronousScrolling)
    }
    #endif

    @cxx
    @implementation
    func mergeOrAppendScrollRequest(_ scrollRequest: WebCore.RequestedScrollData) {
        // This logic is based on the following invariants:
        // * all ScrollRequestTypes other than ImplicitDeltaUpdate cancel ongoing animated scrolls
        // * a CancelAnimatedScroll followed by a ImplicitDeltaUpdate will become a DeltaUpdate
        // * thus, if a CancelAnimatedScroll is present, it will be the only item
        // * the only valid two-entry combinations have an animated update as the second entry
        // The logic needs to ensure that scrollData.identifier is always present in the new state (we must not lose the most recent identifier).

        let count = m_requestedScrollData.size()
        if count == 0 {
            assertionFailure()
            m_requestedScrollData.resize(1)
            m_requestedScrollData[0] = scrollRequest
            return
        }

        // The requests after the merge: at most two, the second an animated update.
        var first = m_requestedScrollData[0]
        var second: WebCore.RequestedScrollData? = count > 1 ? m_requestedScrollData[1] : nil

        switch scrollRequest.requestType {
        case .PositionUpdate:
            // A position update will automatically cancel any animated scroll, and overrule an existing position or delta scroll.
            first = scrollRequest
            second = nil
        case .DeltaUpdate, .ImplicitDeltaUpdate:
            mergeDeltaUpdate(scrollRequest, &first, &second)
        case .AnimatedPositionUpdate, .AnimatedDeltaUpdate:
            mergeAnimatedUpdate(scrollRequest, &first, &second)
        case .CancelAnimatedScroll:
            mergeCancelAnimatedScroll(scrollRequest, &first, &second)
        @unknown default:
            break
        }

        m_requestedScrollData.resize(second == nil ? 1 : 2)
        m_requestedScrollData[0] = first
        if let second {
            m_requestedScrollData[1] = second
        }
    }

    @cxx
    @implementation
    public func hasScrollPositionRequest() -> Bool {
        hasChangedProperty(.RequestedScrollPosition) && m_requestedScrollData.size() != 0
            && m_requestedScrollData[0].requestType != .CancelAnimatedScroll
    }

    // The delta of the first scroll request that scrolls by a delta, for the scrolling tree's first commit of the node.
    var firstRequestedScrollDelta: WebCore.FloatSize? {
        for index in 0..<m_requestedScrollData.size() where m_requestedScrollData[index].hasRequestedScrollDelta() {
            return m_requestedScrollData[index].requestedScrollDelta()
        }
        return nil
    }

    @cxx
    @implementation
    public func setIsMonitoringWheelEvents(_ isMonitoringWheelEvents: Bool) {
        if isMonitoringWheelEvents == m_isMonitoringWheelEvents {
            return
        }

        m_isMonitoringWheelEvents = isMonitoringWheelEvents
        setPropertyChanged(.IsMonitoringWheelEvents)
    }

    @cxx
    @implementation
    public func setMouseIsOverContentArea(_ flag: Bool) {
        if flag == m_mouseIsOverContentArea {
            return
        }

        m_mouseIsOverContentArea = flag
        setPropertyChanged(.ContentAreaHoverState)
    }

    @cxx
    @implementation
    public func setMouseMovedInContentArea(_ mouseLocationState: WebCore.MouseLocationState) {
        m_mouseLocationState = mouseLocationState
        setPropertyChanged(.MouseActivityState)
    }

    @cxx
    @implementation
    public func setScrollbarHoverState(_ hoverState: WebCore.ScrollbarHoverState) {
        if hoverState.mouseIsOverHorizontalScrollbar == m_scrollbarHoverState.mouseIsOverHorizontalScrollbar
            && hoverState.mouseIsOverVerticalScrollbar == m_scrollbarHoverState.mouseIsOverVerticalScrollbar {
            return
        }

        m_scrollbarHoverState = hoverState
        setPropertyChanged(.ScrollbarHoverState)
    }

    @cxx
    @implementation
    public func setScrollbarEnabledState(_ orientation: WebCore.ScrollbarOrientation, _ enabled: Bool) {
        let isHorizontal = orientation == .Horizontal
        if (isHorizontal ? m_scrollbarEnabledState.horizontalScrollbarIsEnabled : m_scrollbarEnabledState.verticalScrollbarIsEnabled) == enabled {
            return
        }

        if isHorizontal {
            m_scrollbarEnabledState.horizontalScrollbarIsEnabled = enabled
        } else {
            m_scrollbarEnabledState.verticalScrollbarIsEnabled = enabled
        }

        setPropertyChanged(.ScrollbarEnabledState)
    }

    @cxx
    @implementation
    public func setScrollbarLayoutDirection(_ scrollbarLayoutDirection: WebCore.UserInterfaceLayoutDirection) {
        if scrollbarLayoutDirection == m_scrollbarLayoutDirection {
            return
        }

        m_scrollbarLayoutDirection = scrollbarLayoutDirection
        setPropertyChanged(.ScrollbarLayoutDirection)
    }

    @cxx
    @implementation
    public func setScrollbarWidth(_ scrollbarWidth: WebCore.ScrollbarWidth) {
        if scrollbarWidth == m_scrollbarWidth {
            return
        }
        m_scrollbarWidth = scrollbarWidth
        setPropertyChanged(.ScrollbarWidth)
    }

    @cxx
    @implementation
    public func setUseDarkAppearanceForScrollbars(_ useDarkAppearanceForScrollbars: Bool) {
        if useDarkAppearanceForScrollbars == m_useDarkAppearanceForScrollbars {
            return
        }
        m_useDarkAppearanceForScrollbars = useDarkAppearanceForScrollbars
        setPropertyChanged(.UseDarkAppearanceForScrollbars)
    }

    func scrollingNodePropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        var ts = makeScrollingDumpStream(indent, formattingFlags, containerSizeLimit)
        ts.append(stateNodePropertiesText(behavior, indent, formattingFlags, containerSizeLimit))

        func appendNumbers(_ ts: inout WTF.TextStream, _ first: Float, _ second: Float) {
            ts.append(WTF.TextStream.FormatNumberRespectingIntegers(Double(first)))
            ts.appendUTF8(" ".utf8.span)
            ts.append(WTF.TextStream.FormatNumberRespectingIntegers(Double(second)))
        }

        if !m_scrollPosition.isZero() {
            ts.startGroup()
            ts.appendUTF8("scroll position ".utf8.span)
            appendNumbers(&ts, m_scrollPosition.x(), m_scrollPosition.y())
            ts.endGroup()
        }

        if !m_scrollableAreaSize.isEmpty() {
            ts.startGroup()
            ts.appendUTF8("scrollable area size ".utf8.span)
            appendNumbers(&ts, m_scrollableAreaSize.width(), m_scrollableAreaSize.height())
            ts.endGroup()
        }

        if !m_totalContentsSize.isEmpty() {
            ts.startGroup()
            ts.appendUTF8("contents size ".utf8.span)
            appendNumbers(&ts, m_totalContentsSize.width(), m_totalContentsSize.height())
            ts.endGroup()
        }

        if !(m_reachableContentsSize == m_totalContentsSize) {
            ts.writeScrollingProperty("reachable contents size") { $0.append(m_reachableContentsSize) }
        }

        for index in 0..<m_requestedScrollData.size() {
            let request = m_requestedScrollData[index]
            let requestType = request.requestType
            if requestType == .PositionUpdate || requestType == .AnimatedPositionUpdate {
                let scrollPosition = request.requestedScrollPosition()
                if !scrollPosition.isZero() {
                    ts.startGroup()
                    ts.appendUTF8("requested scroll position ".utf8.span)
                    appendNumbers(&ts, scrollPosition.x(), scrollPosition.y())
                    ts.endGroup()
                }
            } else if requestType == .DeltaUpdate || requestType == .AnimatedDeltaUpdate || requestType == .ImplicitDeltaUpdate {
                let scrollDelta = request.requestedScrollDelta()
                if !scrollDelta.isZero() {
                    ts.startGroup()
                    if requestType == .DeltaUpdate || requestType == .AnimatedDeltaUpdate {
                        ts.appendUTF8("requested scroll delta ".utf8.span)
                    } else {
                        ts.appendUTF8("requested scroll implicit delta ".utf8.span)
                    }
                    appendNumbers(&ts, scrollDelta.width(), scrollDelta.height())
                    ts.endGroup()
                }
            }

            if request.scrollType == .Programmatic {
                ts.writeScrollingProperty("requested scroll position represents programmatic scroll") { $0.append(true) }
            }

            if request.clamping == .Unclamped {
                ts.writeScrollingProperty("requested scroll position clamping") { $0.append(request.clamping) }
            }

            if WebCore.isAnimatedUpdate(requestType) {
                ts.writeScrollingProperty("requested scroll position is animated") { $0.append(true) }
            }

            if request.animationCurve != .Default {
                ts.writeScrollingProperty("requested scroll animation curve") { $0.append(request.animationCurve) }
            }
        }

        if !m_scrollOrigin.isZero() {
            ts.writeScrollingProperty("scroll origin") { $0.append(m_scrollOrigin) }
        }

        ts.append(snapOffsetsPropertiesText(indent, formattingFlags, containerSizeLimit))

        if Optional(fromCxx: m_currentHorizontalSnapPointIndex) != nil {
            ts.writeScrollingProperty("current horizontal snap point index") {
                $0.append(m_currentHorizontalSnapPointIndex)
            }
        }

        if Optional(fromCxx: m_currentVerticalSnapPointIndex) != nil {
            ts.writeScrollingProperty("current vertical snap point index") { $0.append(m_currentVerticalSnapPointIndex) }
        }

        ts.writeScrollingProperty("scrollable area parameters") { $0.append(m_scrollableAreaParameters) }

        #if ENABLE_SCROLLING_THREAD
        if !m_synchronousScrollingReasons.isEmpty() {
            ts.writeScrollingProperty("Scrolling on main thread because:") {
                $0.append(WebCore.ScrollingCoordinator.synchronousScrollingReasonsAsText(m_synchronousScrollingReasons))
            }
        }
        #endif

        if m_useDarkAppearanceForScrollbars {
            ts.writeScrollingProperty("uses dark appearance for scrollbars") { $0.append(m_useDarkAppearanceForScrollbars) }
        }

        if m_isMonitoringWheelEvents {
            ts.writeScrollingProperty("expects wheel event test trigger") { $0.append(m_isMonitoringWheelEvents) }
        }

        if behavior.contains(.IncludeLayerIDs) {
            if Optional(fromCxx: m_scrollContainerLayer.layerID()) != nil {
                ts.writeScrollingProperty("scroll container layer") { $0.append(m_scrollContainerLayer.layerID()) }
            }
            if Optional(fromCxx: m_scrolledContentsLayer.layerID()) != nil {
                ts.writeScrollingProperty("scrolled contents layer") { $0.append(m_scrolledContentsLayer.layerID()) }
            }
        }

        return ts.release()
    }

    @cxx
    @implementation
    public override func dumpPropertiesText(
        _ behavior: WebCore.ScrollingStateTreeAsTextBehaviors,
        _ indent: Int32,
        _ formattingFlags: WebCore.TextStreamFormattingFlags,
        _ containerSizeLimit: UInt32
    ) -> WTF.String {
        scrollingNodePropertiesText(behavior, indent, formattingFlags, containerSizeLimit)
    }
}

#endif
