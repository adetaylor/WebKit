// Copyright (C) 2025 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if HAVE_APPKIT_GESTURES_SUPPORT

import AppKit
import WebKit_Internal
import os
private import CxxStdlib
private import AppKit_Private.NSClickGestureRecognizer_Private
private import AppKit_Private.NSPanGestureRecognizer_Private
private import AppKit_Private.NSPressGestureRecognizer_Private
private import AppKit_Private.NSTouch_Private
private import WebCore_Private

#if !ENABLE_MAC_GESTURE_EVENTS || !ENABLE_IMAGE_ANALYSIS || !ENABLE_TWO_PHASE_CLICKS
#error("WKAppKitGestureController assumes MAC_GESTURE_EVENTS, IMAGE_ANALYSIS and TWO_PHASE_CLICKS")
#endif

private let sharedPositionInformationToleranceRadius: Int32 = 15
private let panPositionInformationToleranceRadius = sharedPositionInformationToleranceRadius
private let mouseDownPositionInformationToleranceRadius = sharedPositionInformationToleranceRadius

private func saturatingInt32(_ value: Double) -> Int32 {
    value.isNaN ? 0 : Int32(min(max(value, Double(Int32.min)), Double(Int32.max)))
}

extension NSPanGestureRecognizer {
    func startLocation(in view: NSView) -> NSPoint {
        if responds(to: #selector(NSPanGestureRecognizer._startLocation(in:))) {
            return _startLocation(in: view)
        }

        return location(in: view)
    }

    func takeTranslation(in view: NSView) -> WebCore.FloatSize {
        let translation = WebCore.toFloatSize(WebCore.FloatPoint(self.translation(in: view)))
        setTranslation(.zero, in: view)
        return translation
    }
}

extension WebKit.WebEventPhase {
    init(_ state: NSGestureRecognizer.State) {
        switch state {
        case .possible:
            self = .MayBegin
        case .began:
            self = .Began
        case .changed:
            self = .Changed
        case .ended:
            self = .Ended
        case .cancelled, .failed:
            self = .Cancelled
        @unknown default:
            assertionFailure("Unknown gesture recognizer state")
            self = .None
        }
    }
}

extension WebKit.InteractionInformationAtPosition {
    var representsDraggableElement: Bool {
        isLink || isImage || isAttachment || isDHTMLDraggable || isColorInput || prefersDraggingOverTextSelection
    }

    var representsSelectableContent: Bool {
        isSelectable() || isFocusableWithSelectableText()
    }

    var prefersDirectManipulation: Bool {
        isRangeInput || isARIASlider || hasDirectionalResizeCursor || isInResizeControl || isCustomSlider
            || WebKit.CxxInteropSupport.isInteractiveModel(self)
    }

    var representsSecondaryClickableElement: Bool {
        if prefersDirectManipulation {
            return false
        }

        if representsSelectableContent {
            return true
        }

        if shouldTreatLongClickAsSecondaryClickQuirk {
            return true
        }

        if isImage {
            return true
        }

        return isOverVideo && selectability != .UnselectableDueToFocusableElement
    }
}

private let scrollViewPanGestureClass: AnyClass? = NSClassFromString("NSScrollViewPanGestureRecognizer")

@MainActor
private func isBuiltInScrollViewPanGestureRecognizer(_ recognizer: NSGestureRecognizer?) -> Bool {
    guard let scrollViewPanGestureClass else {
        return false
    }
    return recognizer?.isKind(of: scrollViewPanGestureClass) ?? false
}

// The outcome of the image-analysis preflight, used to resolve the two image-analysis deferring
// gestures. Over an image we defer both text selection and the drag / context-menu fallback until
// analysis finishes, then resolve them oppositely.
enum ImageAnalysisDeferralOutcome {
    case notApplicable // Not an image (or the press was abandoned): influence neither deferral.
    case noText // Image without selectable text: prevent text selection; allow drag / context menu.
    case foundText // Image with selectable text: allow text selection; prevent drag / context menu.
}

enum ImageAnalysisDeferralState {
    case undecided
    case deferring
    case gestureFailed
}

struct CompletedImageAnalysis {
    var element: WebCore.ElementContext
    var outcome: ImageAnalysisDeferralOutcome

    func outcome(for hostElement: WebCore.ElementContext?) -> ImageAnalysisDeferralOutcome? {
        guard let hostElement, element.isSameElement(hostElement) else {
            return nil
        }
        return outcome
    }
}

// Keeps the image-analysis deferrals open for the lifetime of an in-flight analysis. When the last
// reference is dropped (analysis finished or abandoned), it resolves both deferrals on the main run
// loop according to the recorded outcome. Mirrors the iOS ImageAnalysisGestureDeferralToken.
@MainActor
final class ImageAnalysisGestureDeferralToken {
    private weak var controller: WKAppKitGestureController?
    var outcome: ImageAnalysisDeferralOutcome = .notApplicable

    init(controller: WKAppKitGestureController) {
        self.controller = controller
    }

    isolated deinit {
        controller?.resolveImageAnalysisDeferrals(with: outcome)
    }
}

struct TouchActions: OptionSet {
    let rawValue: UInt8

    static let auto = Self(rawValue: WebCore.TouchAction.Auto.rawValue)
    static let manipulation = Self(rawValue: WebCore.TouchAction.Manipulation.rawValue)
    static let panX = Self(rawValue: WebCore.TouchAction.PanX.rawValue)
    static let panY = Self(rawValue: WebCore.TouchAction.PanY.rawValue)
    static let pinchZoom = Self(rawValue: WebCore.TouchAction.PinchZoom.rawValue)
}

struct PanAxes: OptionSet {
    let rawValue: UInt8

    static let horizontal = Self(rawValue: 1 << 0)
    static let vertical = Self(rawValue: 1 << 1)
}

@MainActor
private func isCatchingDeceleratingScroll(_ scrollViewPanGesture: NSGestureRecognizer?) -> Bool {
    guard let scrollView = scrollViewPanGesture?.view as? NSScrollView else {
        return false
    }

    // FIXME: _touchCaughtDeceleration was recently renamed in rdar://185652893, so keep this selector check for a bit.
    guard scrollView.responds(to: #selector(NSScrollView._touchCaughtDeceleration)) else {
        return false
    }

    return scrollView._touchCaughtDeceleration()
}

@MainActor
private func isBuiltInScrollViewMagnificationGestureRecognizer(_ gesture: NSGestureRecognizer) -> Bool {
    gesture is NSMagnificationGestureRecognizer && gesture._isScrollGestureRecognizer
}

private func isSamePair(_ a: NSGestureRecognizer, _ b: NSGestureRecognizer, as x: NSGestureRecognizer?, _ y: NSGestureRecognizer?) -> Bool {
    (a === x && b === y) || (b === x && a === y)
}

@objc
@implementation
extension WKAppKitGestureController {
    @nonobjc
    private(set) final weak var view: WKWebView?

    var webView: WKWebView? { view }

    @nonobjc
    private(set) final var panGestureRecognizer: NSPanGestureRecognizer?
    @nonobjc
    private final var primaryMouseTrackingGestureRecognizer: WKMouseTrackingGestureRecognizer?
    @nonobjc
    private final var secondaryMouseTrackingGestureRecognizer: WKMouseTrackingGestureRecognizer?

    @nonobjc
    private final var singleClickGestureRecognizer: NSPressGestureRecognizer?
    @nonobjc
    private(set) final var doubleClickGestureRecognizer: NSClickGestureRecognizer?
    @nonobjc
    private final var domDoubleClickGestureRecognizer: NSClickGestureRecognizer?

    // Auxiliary gesture recognizers to support context menus.
    @nonobjc
    private(set) final var secondaryClickGestureRecognizer: NSPressGestureRecognizer?
    @nonobjc
    private final var secondaryClickDeferringGestureRecognizer: WKDeferringGestureRecognizer?

    // Auxiliary gesture recognizers to support drag-and-drop.
    @nonobjc
    private final var textSelectionDragGesture: NSGestureRecognizer?
    @nonobjc
    private final var dragDeferringGestureRecognizer: WKDeferringGestureRecognizer?

    @nonobjc
    private final var enclosingScrollViewPanDeferringGestureRecognizer: WKDeferringGestureRecognizer?

    @nonobjc
    final var isMomentumActive = false
    @nonobjc
    final var lastPanWheelEventWasHandledByViewGestureController = false
    @nonobjc
    final var caughtDeceleratingScroll = false
    @nonobjc
    final var suppressNextPanScrollDelta = false

    @nonobjc
    private(set) final var isSuppressingSingleClickGestureForTextSelection = false

    @nonobjc
    final var layerTreeTransactionIdAtLastInteractionStart: WebKit.TransactionID?
    @nonobjc
    final var latestTapID: UInt64?
    @nonobjc
    private(set) final var clickHighlight: WKClickHighlightController?
    @nonobjc
    final let support = WKAppKitGestureControllerCxxSupport()
    var cxxSupport: WKAppKitGestureControllerCxxSupport { support }
    @nonobjc
    private final var uidOfTouchThatCaughtDeceleratingScroll: Int?

    // FIXME: Avoid bloat in WKAppKitGestureController by introducing a separate
    // gesture delegate that exclusively manages the mouse tracking recognizers.
    //
    // See mouseTrackingGestureRecognized(_:) where this state is used to transition
    // between tracking gestures when an active gesture's tracking conditions change.
    @nonobjc
    private final weak var activeMouseTrackingGestureRecognizer: WKMouseTrackingGestureRecognizer?
    @nonobjc
    private final var mouseTrackingHasSentMouseDown = false
    @nonobjc
    private final var mouseTrackingSendsMouseMoves = false
    @nonobjc
    private final var mayHaveHoverActivatedByClick = false
    @nonobjc
    private final var mouseTrackingStartLocationInWindow = WebCore.FloatPoint()
    @nonobjc
    private final var mouseTrackingIsSuppressedForTransformGesture = false
    @nonobjc
    private final var contentDeclinedTransformGesture = false
    @nonobjc
    private final var lastTransformGestureDriveTime: TimeInterval?

    @nonobjc
    private(set) final var dragPressGestureRecognizer: WKPressGestureRecognizer?

    @nonobjc
    private final var pointerTrackingGestureRecognizer: WKPointerTrackingGestureRecognizer?
    @nonobjc
    private final var pointerDownDeferringGestureRecognizer: WKDeferringGestureRecognizer?
    @nonobjc
    private final var isTrackingPointer = false
    @nonobjc
    private final var trackedPointerHasMoved = false
    @nonobjc
    private final var trackedPointerStartLocationInWindow = NSPoint.zero
    @nonobjc
    private final var trackedPointerLastLocationInWindow = NSPoint.zero

    @nonobjc
    private final var gestureDraggingSession: NSDraggingSession?
    @nonobjc
    private final var textSelectionDragCompletionHandler: ((NSDraggingSession) -> Void)?
    @nonobjc
    private final var dragGestureHasSentMouseDown = false
    @nonobjc
    private final var dragGestureDidReceiveDragStart = false
    @nonobjc
    private final var dragIdentifier: UInt64 = 0

    @nonobjc
    final var potentialTapIsInProgress = false

    @nonobjc
    private final var imageAnalysisGestureRecognizer: WKPressGestureRecognizer?
    @nonobjc
    private(set) final var imageAnalysisTextSelectionDeferringGestureRecognizer: WKDeferringGestureRecognizer?
    @nonobjc
    private(set) final var imageAnalysisDragAndContextMenuDeferringGestureRecognizer: WKDeferringGestureRecognizer?

    @nonobjc
    private final var lastCompletedImageAnalysis: CompletedImageAnalysis?
    @nonobjc
    final var imageAnalysisDeferralState = ImageAnalysisDeferralState.undecided

    @nonobjc
    final var fastScrollTracker = WKFastScrollTracker()
    @nonobjc
    final var directionalScrollLockTracker = WKDirectionalScrollLockTracker()

    @nonobjc
    private final var magnificationGestureRecognizer: NSMagnificationGestureRecognizer?
    @nonobjc
    private final var rotationGestureRecognizer: NSRotationGestureRecognizer?

    // FIXME: <webkit.org/b/321828> Avoid further bloating this class and instead manage state through a separate/independent entity.
    // Magnification and rotation GRs report their values cumulatively over a gesture.
    // These variables track the last reported value so that we can forward deltas.
    @nonobjc
    private final var lastCumulativeMagnification: Double = 0
    @nonobjc
    private final var lastCumulativeRotation: Double = 0

    @nonobjc
    final var hasEverMagnifiedDuringCurrentGesture = false

    @nonobjc
    private static func loggingDescription(for gestureRecognizer: NSGestureRecognizer?) -> String {
        guard let gestureRecognizer else {
            return "nil"
        }

        var parts: [String] = []
        parts.append("\(type(of: gestureRecognizer)): \(UInt(bitPattern: ObjectIdentifier(gestureRecognizer)))")

        if let name = gestureRecognizer.name {
            parts.append("name = \(name)")
        }

        parts.append("state = \(gestureRecognizer.state.name)")

        return "<\(parts.joined(separator: "; "))>"
    }

    @nonobjc
    private final var pageLogIdentifier: UInt64 {
        view?._protectedPage().get()?.logIdentifier() ?? 0
    }

    @nonobjc
    private final func logGestureAction(_ gesture: NSGestureRecognizer, function: String = #function) {
        Logger.viewGestures.debug("[pageProxyID=\(self.pageLogIdentifier)] \(function): \(Self.loggingDescription(for: gesture))")
    }

    @nonobjc
    private final func logArbitration(
        _ gestureRecognizer: NSGestureRecognizer,
        _ otherGestureRecognizer: NSGestureRecognizer,
        function: String = #function
    ) {
        Logger.viewGestures.debug(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(function): Gesture: \(Self.loggingDescription(for: gestureRecognizer)), \
            Other gesture: \(Self.loggingDescription(for: otherGestureRecognizer))
            """
        )
    }

    @nonobjc
    private final func touchActions(at point: NSPoint) -> TouchActions {
        TouchActions(rawValue: support.touchActions(at: point))
    }

    @nonobjc
    private final func touchActionsAllowedPanningAxes(at point: NSPoint) -> PanAxes {
        let touchActions = touchActions(at: point)
        let canPanHorizontally = !touchActions.isDisjoint(with: [.auto, .manipulation, .panX])
        let canPanVertically = !touchActions.isDisjoint(with: [.auto, .manipulation, .panY])

        var allowedAxes: PanAxes = []
        if canPanHorizontally {
            allowedAxes.insert(.horizontal)
        }
        if canPanVertically {
            allowedAxes.insert(.vertical)
        }

        return allowedAxes
    }

    @nonobjc
    private final func touchActionsAllowPanning(at point: NSPoint) -> Bool {
        !touchActionsAllowedPanningAxes(at: point).isEmpty
    }

    @nonobjc
    private final var panGestureRecognizerCanScroll: Bool {
        guard let webView = view else {
            return false
        }

        return touchActionsAllowPanning(at: panGestureRecognizer?.location(in: webView) ?? .zero)
    }

    @nonobjc
    private final var magnificationGestureRecognizerCanZoom: Bool {
        guard let webView = view else {
            return false
        }

        let touchActions = touchActions(at: magnificationGestureRecognizer?.location(in: webView) ?? .zero)
        return !touchActions.isDisjoint(with: [.auto, .manipulation, .pinchZoom])
    }

    @nonobjc
    private final func prefersUnlockedScroll(_ gesture: NSPanGestureRecognizer) -> Bool {
        gesture.touches.count > 1
    }

    @nonobjc
    private final func refreshControllerEligibility(_ gesture: NSPanGestureRecognizer) -> WebKit.RefreshControllerEligibility {
        gesture.touches.count == 1 ? .Eligible : .Ineligible
    }

    @nonobjc
    private final func prefersForwardingToGestureController(_ gesture: NSPanGestureRecognizer) -> Bool {
        gesture.touches.count == 1
    }

    @nonobjc
    private final func supportsMomentumScroll(_ gesture: NSPanGestureRecognizer) -> Bool {
        gesture.touches.count == 1
    }

    @nonobjc
    private final func nameForMouseTrackingGesture(_ gesture: NSPressGestureRecognizer) -> String {
        if gesture.numberOfTouchesRequired == 1 {
            return "WKMouseTrackingGestureSingle"
        }
        if gesture.numberOfTouchesRequired > 1 {
            return "WKMouseTrackingGestureMultiple"
        }

        assertionFailure("A mouse tracking gesture recognizer requires at least one touch")
        return "WKMouseTrackingGestureUnknown"
    }

    @nonobjc
    private final func mouseTrackingGestureRecognizerCanTrack(_ gesture: NSPressGestureRecognizer) -> Bool {
        guard let webView = view else {
            return false
        }

        if gesture.numberOfTouchesRequired <= 1 {
            return true
        }

        // If the web content permits panning, the pan GR will win.
        // This multi-touch tracking recognizer covers the remaining case, where
        // the content has opted out of panning. Web apps typically depend on
        // touch/pointer/mousemove events for a notion of "translation" in this
        // case, such as on maps.apple.com. As such, we complement the logic here
        // with the predicate in panGestureRecognizerCanScroll.
        return !touchActionsAllowPanning(at: gesture.location(in: webView))
    }

    // FIXME: rdar://185815023 (-[NSRotationGestureRecognizer locationInView:] should reflect live centroid of the gesture)
    // The rotation GR's location(in:) does not reflect its live centroid over
    // the course of a twist, so we compute it directly and use it to feed our
    // gesture machinery. Otherwise, the rotation and magnification locations stomp
    // over each other in ViewGestureController.
    @nonobjc
    private final func gestureCentroidInWindow(for gesture: NSGestureRecognizer) -> WebCore.FloatPoint {
        let touches: [NSTouch]
        if let magnificationGesture = gesture as? NSMagnificationGestureRecognizer {
            touches = magnificationGesture.touches
        } else if let rotationGesture = gesture as? NSRotationGestureRecognizer {
            touches = rotationGesture.touches
        } else {
            touches = []
        }

        let count = touches.count

        if count == 0 {
            return WebCore.FloatPoint(gesture.location(in: nil))
        }

        var centroidX: Float = 0
        var centroidY: Float = 0
        for touch in touches {
            let locationInWindow = touch.location(in: nil)
            centroidX = Float(Double(centroidX) + locationInWindow.x)
            centroidY = Float(Double(centroidY) + locationInWindow.y)
        }
        return WebCore.FloatPoint(centroidX, centroidY).scaled(Float(1.0 / Double(count)))
    }

    @nonobjc
    private final func isOnlyTouchDown(_ touch: NSTouch) -> Bool {
        guard let webView = view else {
            return false
        }

        guard let event = NSApp.currentEvent, event.type == .directTouch else {
            return false
        }

        let touches = event.touches(matching: .touching, in: webView)
        return touches.count == 1 && touches.first?._uid == touch._uid
    }

    @nonobjc
    private final func interruptMomentumIfNeeded(for touch: NSTouch) {
        // Other callers of resetCaughtDeceleratingScroll() can miss the end of a gesture
        // (e.g. a pan over content that disallows scrolling, which then neither scrolls, clicks, nor tracks the mouse).
        // We can't let that leak into the next interaction, or it would keep refusing gestures.
        // We only consider this a new interaction if 1) this is the only touch down,
        // and 2) isn't the touch that caught the scroll.
        if caughtDeceleratingScroll, uidOfTouchThatCaughtDeceleratingScroll != touch._uid, isOnlyTouchDown(touch) {
            Logger.viewGestures.log(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                Resetting stale caught decelerating scroll state from a previous interaction
                """
            )
            resetCaughtDeceleratingScroll()
        }

        let wasMomentumActive = isMomentumActive
        interruptMomentumIfNeeded()

        if wasMomentumActive && caughtDeceleratingScroll {
            uidOfTouchThatCaughtDeceleratingScroll = touch._uid
        }
    }

    @objc(gestureRecognizer:shouldReceiveTouch:)
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool {
        guard let webView = view else {
            return false
        }

        guard let impl = webView._impl(), !impl.ignoresAllEvents() else {
            return false
        }

        interruptMomentumIfNeeded(for: touch)

        if gestureRecognizer === panGestureRecognizer {
            let allowedAxes = touchActionsAllowedPanningAxes(at: touch.location(in: webView))
            panGestureRecognizer?._canPanHorizontally = allowedAxes.contains(.horizontal)
            panGestureRecognizer?._canPanVertically = allowedAxes.contains(.vertical)
        }

        return true
    }

    @objc(gestureRecognizer:shouldAttemptToRecognizeWithEvent:)
    func gestureRecognizer(_ gesture: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        // Every GR we maintain is exclusively direct touch-only, so we can unconditionally return false here.
        // This delegate implementation is only necessary for the magnification and rotation GRs since they
        // can not be configured as a (buttonMask + allowedTouchTypes) pair like the other gestures.

        // FIXME: <rdar://166268811> Migrate towards API (once available) that configures magnification/rotation GRs as touch-only.
        false
    }

    @nonobjc
    private final func configure(forScrolling gesture: NSPanGestureRecognizer) {
        // FIXME: Strictly, this should be `2` when allowsMagnification is true and the min/max zoom
        // scales are different, c.f. UIScrollView's _updatePanGestureConfiguration for prior art.
        gesture.maximumNumberOfTouches = 2
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
    }

    @nonobjc
    private final func configure(forSingleClick gesture: NSPressGestureRecognizer) {
        gesture.minimumPressDuration = 0
        gesture.cancelPastAllowableMovement = true
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        gesture.numberOfTouchesRequired = 1
    }

    @nonobjc
    private final func configure(forDoubleClick gesture: NSClickGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        gesture.numberOfTouchesRequired = 2
        gesture.numberOfClicksRequired = 2
    }

    @nonobjc
    private final func configure(forDOMDoubleClick gesture: NSClickGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        gesture.numberOfTouchesRequired = 1
        // Intentionally set to `1` and not `2`, see WKDOMDoubleClickGestureRecognizer.swift.
        // FIXME: rdar://184563102 (An NSClickGestureRecognizer with numberOfClicksRequired=2 results in other GRs being neglected for some gestures)
        gesture.numberOfClicksRequired = 1
    }

    @nonobjc
    private final func configure(forSecondaryClick gesture: NSPressGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
    }

    @nonobjc
    private final func configure(forMouseTracking gesture: NSPressGestureRecognizer, at index: Int) {
        gesture.minimumPressDuration = 0
        gesture.cancelPastAllowableMovement = false
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        gesture.numberOfTouchesRequired = index + 1
    }

    @nonobjc
    private final func configure(forPointerTracking gesture: NSPressGestureRecognizer) {
        gesture.minimumPressDuration = 0
        gesture.allowableMovement = CGFloat.greatestFiniteMagnitude
        gesture.cancelPastAllowableMovement = false
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        // FIXME: Tracking more than one touch needs a pointer per touch.
        gesture.numberOfTouchesRequired = 1
    }

    @nonobjc
    private final func configure(forPointerDownDeferral gesture: WKDeferringGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
    }

    @nonobjc
    private final func configure(forDragPress gesture: NSPressGestureRecognizer) {
        // Matching _UIDragInteractionDefaultLiftDelay.
        let dragPressMinimumDuration: TimeInterval = 0.325
        gesture.minimumPressDuration = dragPressMinimumDuration
        gesture.cancelPastAllowableMovement = false
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        gesture.numberOfTouchesRequired = 1
    }

    @nonobjc
    private final func configure(forDragDeferral gesture: WKDeferringGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
    }

    @nonobjc
    private final func configure(forSecondaryClickDeferral gesture: WKDeferringGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
    }

    @nonobjc
    private final func configure(forImageAnalysis gesture: NSPressGestureRecognizer) {
        // Mirrors the iOS WKImageAnalysisGestureRecognizer: a short, stationary long-press that starts
        // preflighting Live Text as soon as a press settles on an image. Movement cancels it, so a
        // scroll or drag over an image does not trigger analysis.
        gesture.minimumPressDuration = 0.1
        gesture.allowableMovement = 0
        gesture.cancelPastAllowableMovement = true
        gesture.allowedTouchTypes = .direct
        gesture.buttonMask = 0
        gesture.numberOfTouchesRequired = 1
    }

    @nonobjc
    final func configure(forImageAnalysisDeferral gesture: WKDeferringGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
    }

    @nonobjc
    private final func configure(forMagnification gesture: NSMagnificationGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
    }

    @nonobjc
    private final func configure(forRotation gesture: NSRotationGestureRecognizer) {
        gesture.allowedTouchTypes = .direct
    }

    init(view: WKWebView) {
        self.view = view
        super.init()
        support.controller = self
        clickHighlight = WKClickHighlightController(delegate: self)
    }

    func setUp() {
        guard view != nil else {
            return
        }

        support.setUpPositionInformation()

        setUpGestureRecognizers()
        addGesturesToWebView()
        enableGesturesIfNeeded()
        ensureGesturesAreNotArchived()
    }

    @nonobjc
    private final func setUpGestureRecognizers() {
        setUpPanGestureRecognizer()
        setUpPointerTrackingGestureRecognizer()
        setUpPointerDownDeferringGestureRecognizer()
        setUpMouseTrackingGestureRecognizers()
        setUpSingleClickGestureRecognizer()
        setUpDoubleClickGestureRecognizer()
        setUpDOMDoubleClickGestureRecognizer()

        setUpSecondaryClickGestureRecognizer()
        setUpSecondaryClickDeferringGestureRecognizer()

        setUpDragPressGestureRecognizer()
        setUpDragDeferringGestureRecognizer()

        setUpEnclosingScrollViewPanDeferringGestureRecognizer()

        setUpImageAnalysisGestureRecognizer()
        setUpImageAnalysisDeferringGestureRecognizers()

        setUpMagnificationGestureRecognizer()
        setUpRotationGestureRecognizer()
    }

    @nonobjc
    private final func setUpPanGestureRecognizer() {
        guard let webView = view else {
            return
        }

        let panGestureRecognizer = WKPanGestureRecognizer(webView: webView, target: self, action: #selector(panGestureRecognized))
        configure(forScrolling: panGestureRecognizer)

        panGestureRecognizer.delegate = self
        panGestureRecognizer.name = "WKPanGesture"

        self.panGestureRecognizer = panGestureRecognizer
    }

    @nonobjc
    private final func setUpMouseTrackingGestureRecognizers() {
        primaryMouseTrackingGestureRecognizer = makeMouseTrackingGestureRecognizer(at: 0)
        secondaryMouseTrackingGestureRecognizer = makeMouseTrackingGestureRecognizer(at: 1)
    }

    @nonobjc
    private final func makeMouseTrackingGestureRecognizer(at index: Int) -> WKMouseTrackingGestureRecognizer {
        let recognizer = WKMouseTrackingGestureRecognizer(target: self, action: #selector(mouseTrackingGestureRecognized))
        configure(forMouseTracking: recognizer, at: index)
        recognizer.delegate = self
        recognizer.name = nameForMouseTrackingGesture(recognizer)
        return recognizer
    }

    @nonobjc
    private final func setUpPointerTrackingGestureRecognizer() {
        let recognizer = WKPointerTrackingGestureRecognizer(
            target: self,
            action: #selector(pointerTrackingGestureRecognized)
        )
        pointerTrackingGestureRecognizer = recognizer
        configure(forPointerTracking: recognizer)
        recognizer.refusesToBeFailureRequirement = true
        recognizer.pointerTrackingDelegate = self
        recognizer.delegate = self
        recognizer.name = "WKPointerTrackingGesture"
    }

    @nonobjc
    private final func setUpPointerDownDeferringGestureRecognizer() {
        let recognizer = WKDeferringGestureRecognizer(deferringGestureDelegate: self)
        pointerDownDeferringGestureRecognizer = recognizer
        configure(forPointerDownDeferral: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKPointerDownDeferringGesture"
    }

    @nonobjc
    private final func setUpSingleClickGestureRecognizer() {
        let recognizer = WKPressGestureRecognizer(target: self, action: #selector(singleClickGestureRecognized))
        singleClickGestureRecognizer = recognizer
        configure(forSingleClick: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKSingleClickGesture"
    }

    @nonobjc
    private final func setUpDoubleClickGestureRecognizer() {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(doubleClickGestureRecognized))
        doubleClickGestureRecognizer = recognizer
        configure(forDoubleClick: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKDoubleClickGesture"
    }

    @nonobjc
    private final func setUpDOMDoubleClickGestureRecognizer() {
        let recognizer = WKDOMDoubleClickGestureRecognizer(target: self, action: #selector(domDoubleClickGestureRecognized))
        configure(forDOMDoubleClick: recognizer)

        recognizer.delegate = self
        recognizer.name = "WKDOMDoubleClickGesture"

        domDoubleClickGestureRecognizer = recognizer
    }

    // `domDoubleClickGestureRecognizer` is always created as a `WKDOMDoubleClickGestureRecognizer`.
    @nonobjc
    private final var typedDOMDoubleClickGestureRecognizer: WKDOMDoubleClickGestureRecognizer? {
        guard let recognizer = domDoubleClickGestureRecognizer else {
            return nil
        }

        guard let recognizer = recognizer as? WKDOMDoubleClickGestureRecognizer else {
            assertionFailure("DOM double click gesture recognizer was unexpectedly of type \(type(of: recognizer)).")
            return nil
        }

        return recognizer
    }

    @nonobjc
    private final func resetDOMDoubleClickGestureRecognizer() {
        typedDOMDoubleClickGestureRecognizer?.resetClick()
    }

    @nonobjc
    final func takeCompletedDOMDoubleClick() -> Bool {
        typedDOMDoubleClickGestureRecognizer?.takeCompletedDoubleClick() ?? false
    }

    @nonobjc
    private final func setUpSecondaryClickGestureRecognizer() {
        let recognizer = WKPressGestureRecognizer(target: self, action: #selector(secondaryClickGestureRecognized))
        secondaryClickGestureRecognizer = recognizer
        configure(forSecondaryClick: recognizer)
        recognizer.cancelPastAllowableMovement = true
        recognizer.delegate = self
        recognizer.name = "WKSecondaryClickGesture"
    }

    @nonobjc
    private final func setUpSecondaryClickDeferringGestureRecognizer() {
        let recognizer = WKDeferringGestureRecognizer(deferringGestureDelegate: self)
        secondaryClickDeferringGestureRecognizer = recognizer
        configure(forSecondaryClickDeferral: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKSecondaryClickDeferringGesture"
    }

    @nonobjc
    private final func setUpDragPressGestureRecognizer() {
        let recognizer = WKPressGestureRecognizer(target: self, action: #selector(dragPressGestureRecognized))
        dragPressGestureRecognizer = recognizer
        configure(forDragPress: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKDragPressGesture"
    }

    @nonobjc
    private final func setUpDragDeferringGestureRecognizer() {
        let recognizer = WKDeferringGestureRecognizer(deferringGestureDelegate: self)
        dragDeferringGestureRecognizer = recognizer
        configure(forDragDeferral: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKDragDeferringGesture"
    }

    @nonobjc
    private final func setUpEnclosingScrollViewPanDeferringGestureRecognizer() {
        let recognizer = WKDeferringGestureRecognizer(deferringGestureDelegate: self)
        enclosingScrollViewPanDeferringGestureRecognizer = recognizer
        recognizer.allowedTouchTypes = .direct
        recognizer.delegate = self
        recognizer.name = "WKEnclosingScrollViewPanDeferringGesture"
    }

    @nonobjc
    private final func setUpImageAnalysisGestureRecognizer() {
        let recognizer = WKPressGestureRecognizer(target: self, action: #selector(imageAnalysisGestureRecognized))
        imageAnalysisGestureRecognizer = recognizer
        configure(forImageAnalysis: recognizer)
        recognizer.refusesToBeFailureRequirement = true
        recognizer.delegate = self
        recognizer.pressDelegate = self
        recognizer.name = "WKImageAnalysisGesture"
    }

    @nonobjc
    private final func setUpImageAnalysisDeferringGestureRecognizers() {
        // One deferral holds text selection over an image until analysis resolves; the other holds the
        // drag-press / secondary-click recognizers. See the Image Analysis design note for why both exist
        // and why they resolve to opposite outcomes.
        imageAnalysisTextSelectionDeferringGestureRecognizer = makeImageAnalysisDeferringGestureRecognizer(
            withName: "WKImageAnalysisTextSelectionDeferringGesture"
        )
        imageAnalysisDragAndContextMenuDeferringGestureRecognizer = makeImageAnalysisDeferringGestureRecognizer(
            withName: "WKImageAnalysisDragAndContextMenuDeferringGesture"
        )
    }

    @nonobjc
    final func makeImageAnalysisDeferringGestureRecognizer(withName name: String) -> WKDeferringGestureRecognizer {
        let deferringGestureRecognizer = WKDeferringGestureRecognizer(deferringGestureDelegate: self)
        configure(forImageAnalysisDeferral: deferringGestureRecognizer)
        deferringGestureRecognizer.name = name
        deferringGestureRecognizer.delegate = self
        deferringGestureRecognizer.immediatelyFailsAfterTouchEnd = true
        return deferringGestureRecognizer
    }

    @nonobjc
    private final func setUpMagnificationGestureRecognizer() {
        let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(magnificationGestureRecognized))
        magnificationGestureRecognizer = recognizer
        configure(forMagnification: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKMagnificationGesture"
    }

    @nonobjc
    private final func setUpRotationGestureRecognizer() {
        let recognizer = NSRotationGestureRecognizer(target: self, action: #selector(rotationGestureRecognized))
        rotationGestureRecognizer = recognizer
        configure(forRotation: recognizer)
        recognizer.delegate = self
        recognizer.name = "WKRotationGesture"
    }

    @nonobjc
    private final var installedGestureRecognizers: [NSGestureRecognizer] {
        let recognizers: [NSGestureRecognizer?] = [
            panGestureRecognizer,
            pointerTrackingGestureRecognizer,
            pointerDownDeferringGestureRecognizer,
            primaryMouseTrackingGestureRecognizer,
            secondaryMouseTrackingGestureRecognizer,
            singleClickGestureRecognizer,
            doubleClickGestureRecognizer,
            domDoubleClickGestureRecognizer,
            secondaryClickGestureRecognizer,
            secondaryClickDeferringGestureRecognizer,
            dragPressGestureRecognizer,
            dragDeferringGestureRecognizer,
            enclosingScrollViewPanDeferringGestureRecognizer,
            imageAnalysisGestureRecognizer,
            imageAnalysisTextSelectionDeferringGestureRecognizer,
            imageAnalysisDragAndContextMenuDeferringGestureRecognizer,
            magnificationGestureRecognizer,
            rotationGestureRecognizer,
        ]
        return recognizers.compactMap { $0 }
    }

    @nonobjc
    private final func addGesturesToWebView() {
        guard let webView = view else {
            return
        }

        for recognizer in installedGestureRecognizers {
            webView.addGestureRecognizer(recognizer)
        }
    }

    @nonobjc
    private final func enableGesturesIfNeeded() {
        enableGestureIfNeeded(panGestureRecognizer)
        enableGestureIfNeeded(pointerTrackingGestureRecognizer)
        enableGestureIfNeeded(primaryMouseTrackingGestureRecognizer)
        enableGestureIfNeeded(secondaryMouseTrackingGestureRecognizer)
        enableGestureIfNeeded(singleClickGestureRecognizer)
        enableGestureIfNeeded(doubleClickGestureRecognizer)
        enableGestureIfNeeded(domDoubleClickGestureRecognizer)
        enableGestureIfNeeded(secondaryClickGestureRecognizer)
        enableGestureIfNeeded(dragPressGestureRecognizer)
        enableGestureIfNeeded(imageAnalysisGestureRecognizer)
        enableGestureIfNeeded(magnificationGestureRecognizer)
        enableGestureIfNeeded(rotationGestureRecognizer)

        // The deferring gesture recognizers are intentionally not enabled.
    }

    func preferencesDidChange() {
        enableGesturesIfNeeded()
        if let panGestureRecognizer {
            configure(forScrolling: panGestureRecognizer)
        }
    }

    @nonobjc
    private final func ensureGesturesAreNotArchived() {
        // The set of gestures managed by WKAppKitGestureController are configured
        // and installed freshly for every web view initialization, and as such we
        // want to avoid duplicate sets when views are decoded.

        for recognizer in installedGestureRecognizers {
            recognizer.shouldBeArchived = false
        }
    }

    @nonobjc
    private final func enableGestureIfNeeded(_ gesture: NSGestureRecognizer?) {
        guard view != nil else {
            return
        }

        let gestureEnabled =
            gesture !== imageAnalysisGestureRecognizer || WebKit.isLiveTextAvailableAndEnabled()

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            \(Self.loggingDescription(for: gesture)) setEnabled:\(gestureEnabled)
            """
        )
        gesture?.isEnabled = gestureEnabled
    }

    @nonobjc
    private final func syntheticMouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval = GetCurrentEventTime(),
        windowNumber: Int,
        clickCount: Int = 1,
        pressure: Float,
        reportingMovementFor recognizer: WKPressGestureRecognizer? = nil
    ) -> NSEvent? {
        let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: pressure
        )
        guard let event, let recognizer else {
            return event
        }
        return recognizer.eventReportingMovement(event, atWindowLocation: location)
    }

    func beginSuppressingSingleClickGestureForTextSelection() {
        guard let webView = view else {
            return
        }

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Begin suppressing single-click gesture for text selection
            """
        )

        isSuppressingSingleClickGestureForTextSelection = true

        handleTapCancelled()
        webView._protectedPage().get()?.cancelPotentialTap()
    }

    func endSuppressingSingleClickGestureForTextSelection() {
        guard view != nil else {
            return
        }

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            End suppressing single-click gesture for text selection
            """
        )

        isSuppressingSingleClickGestureForTextSelection = false
    }

    // MARK: Gesture Recognition

    @objc
    private func panGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        precondition(panGestureRecognizer === gesture)

        guard let impl = webView._impl(), let panGestureRecognizer else {
            return
        }

        if impl.ignoresAllEvents() {
            Logger.viewGestures.debug("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Ignored gesture")
            return
        }

        if gesture.state == .began {
            cancelPointerTrackingIfNeeded()
            impl.dismissContentRelativeChildWindowsWithAnimation(false)
            fastScrollTracker.didStartGesture(atLocation: gesture.location(in: nil))
            directionalScrollLockTracker.didStartGesture()
        }

        #if HAVE_NSREFRESHCONTROLLER
        impl.updateRefreshControllerForPanGesture(gesture.state, refreshControllerEligibility(panGestureRecognizer))
        #endif

        sendWheelEvent(for: panGestureRecognizer)
        startMomentumIfNeeded(for: panGestureRecognizer)

        switch gesture.state {
        case .ended, .cancelled, .failed:
            // After the wheel and momentum events above, so both still see this gesture's locked axis.
            directionalScrollLockTracker.didEndGesture()
            resetCaughtDeceleratingScroll()
        default:
            break
        }
    }

    @objc
    private func singleClickGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        precondition(singleClickGestureRecognizer === gesture)

        guard let impl = webView._impl(), !impl.ignoresAllEvents() else {
            return
        }

        if caughtDeceleratingScroll {
            // This gesture is interrupting a decelerating scroll; it should stop the scroll (and may
            // turn into a pan) but must never perform a click.
            switch gesture.state {
            case .ended, .cancelled, .failed:
                resetCaughtDeceleratingScroll()
                handleTapCancelled()
            default:
                break
            }
            return
        }

        // Clicks aren't delivered to NSButton's built-in click gesture
        // recognizer when a parent view's GR recognizes first, so we
        // forward the click manually.
        if let page = webView._protectedPage().get(), !page.preferences().useAlternatePDFHUD(), gesture.state == .began,
            let hitView = impl.hitTestPDFHUD(WebCore.FloatPoint(gesture.location(in: webView))).get(), impl.isViewVisible(hitView)
        {
            (hitView as? NSButton)?.performClick(nil)
            gesture.state = .cancelled
            return
        }

        switch gesture.state {
        case .began:
            handleTapBegan(gesture)
        case .ended:
            handleTapEnded(gesture)
        case .cancelled, .failed:
            handleTapCancelled()
        default:
            break
        }
    }

    @objc
    private func doubleClickGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        precondition(doubleClickGestureRecognizer === gesture)

        guard let impl = webView._impl() else {
            return
        }
        impl.dismissContentRelativeChildWindowsWithAnimation(false)

        let magnificationOrigin = webView.convert(gesture.location(in: nil), from: nil)
        impl.handleSmartMagnificationGesture(magnificationOrigin)
    }

    @objc
    private func domDoubleClickGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        precondition(domDoubleClickGestureRecognizer === gesture)

        // The single-click gesture may have already committed this click as a double click.
        guard takeCompletedDOMDoubleClick() else {
            return
        }

        guard let impl = webView._impl(), !impl.ignoresAllEvents() else {
            return
        }

        let location = gesture.location(in: webView)

        if layerTreeTransactionIdAtLastInteractionStart == nil {
            updateLayerTreeTransactionIdAtLastInteractionStart()
        }

        guard let layerTreeTransactionIdAtLastInteractionStart else {
            return
        }

        let modifiers = WebKit.WebEventFactory.toWebEventModifierFlags(gesture.modifierFlags)

        webView._protectedPage().get()?
            .handleDoubleTapForDoubleClickAtPoint(
                WebCore.roundedIntPoint(location),
                modifiers,
                layerTreeTransactionIdAtLastInteractionStart,
                .Touch,
                .OneFingerTap
            )
    }

    @objc
    private func secondaryClickGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        precondition(secondaryClickGestureRecognizer === gesture)

        guard gesture.state == .began else {
            return
        }

        handleTapCancelled()
        cancelPointerTrackingIfNeeded()

        let modifierFlags = gesture.modifierFlags
        let location = gesture.location(in: nil)
        guard let impl = webView._impl() else {
            return
        }
        let windowNumber = impl.windowNumber()

        let mouseDown = syntheticMouseEvent(
            .rightMouseDown,
            at: location,
            modifierFlags: modifierFlags,
            windowNumber: windowNumber,
            pressure: 1
        )
        impl.mouseDown(mouseDown, .Touch, .Yes)

        let mouseUp = syntheticMouseEvent(
            .rightMouseUp,
            at: location,
            modifierFlags: modifierFlags,
            windowNumber: windowNumber,
            pressure: 0
        )
        impl.mouseUp(mouseUp, .Touch, .Yes)
    }

    @nonobjc
    private final func movementExceedsClickAllowableMovement(_ movementInWindow: NSSize) -> Bool {
        let allowableMovement = singleClickGestureRecognizer?.allowableMovement ?? 0
        return abs(movementInWindow.width) > allowableMovement || abs(movementInWindow.height) > allowableMovement
    }

    @nonobjc
    private final func isMouseTrackingGestureRecognizer(_ gesture: NSGestureRecognizer) -> Bool {
        gesture is WKMouseTrackingGestureRecognizer
    }

    @nonobjc
    private final func mouseTrackingWillBeHandedOff() -> Bool {
        guard mouseTrackingHasSentMouseDown else {
            return false
        }

        return [primaryMouseTrackingGestureRecognizer, secondaryMouseTrackingGestureRecognizer]
            .contains {
                $0?.state == .began || $0?.state == .changed
            }
    }

    @nonobjc
    private final var isRecognizingTransformGesture: Bool {
        func isRecognizing(_ gesture: NSGestureRecognizer?) -> Bool {
            switch gesture?.state {
            case .began, .changed:
                true
            default:
                false
            }
        }

        return isRecognizing(magnificationGestureRecognizer) || isRecognizing(rotationGestureRecognizer)
    }

    @nonobjc
    final var isTransformGestureActiveOrEnding: Bool {
        func isActiveOrEnding(_ gesture: NSGestureRecognizer?) -> Bool {
            switch gesture?.state {
            case .began, .changed, .ended:
                true
            default:
                false
            }
        }

        return isActiveOrEnding(magnificationGestureRecognizer) || isActiveOrEnding(rotationGestureRecognizer)
    }

    @nonobjc
    private final func shouldSuppressMouseTrackingForTransformGesture() -> Bool {
        let transformGestureDriveTimeout: TimeInterval = 0.050

        guard contentDeclinedTransformGesture, isRecognizingTransformGesture, let lastTransformGestureDriveTime else {
            return false
        }

        return ProcessInfo.processInfo.systemUptime - lastTransformGestureDriveTime < transformGestureDriveTimeout
    }

    func transformGestureWasNotHandledByContent() {
        guard isRecognizingTransformGesture else {
            return
        }

        contentDeclinedTransformGesture = true
        transformGestureDidDrive()
    }

    @nonobjc
    private final func transformGestureDidEnd() {
        guard !isRecognizingTransformGesture else {
            return
        }

        contentDeclinedTransformGesture = false
        resetCaughtDeceleratingScroll()
    }

    @nonobjc
    private final func transformGestureDidDrive() {
        lastTransformGestureDriveTime = ProcessInfo.processInfo.systemUptime

        guard contentDeclinedTransformGesture, mouseTrackingHasSentMouseDown, let impl = view?._impl(), !impl.ignoresAllEvents() else {
            return
        }

        let activeMouseTrackingGesture = activeMouseTrackingGestureRecognizer
        let modifierFlags = activeMouseTrackingGesture?.modifierFlags ?? []
        let locationInWindow =
            activeMouseTrackingGesture?.mouseLocationInWindow
            ?? NSPoint(x: CGFloat(mouseTrackingStartLocationInWindow.x()), y: CGFloat(mouseTrackingStartLocationInWindow.y()))

        let mouseUp = syntheticMouseEvent(
            .leftMouseUp,
            at: locationInWindow,
            modifierFlags: modifierFlags,
            windowNumber: impl.windowNumber(),
            pressure: 0,
            reportingMovementFor: activeMouseTrackingGesture
        )
        impl.mouseUp(mouseUp, .Touch, .No)

        mouseTrackingHasSentMouseDown = false
        mouseTrackingIsSuppressedForTransformGesture = true
    }

    @objc
    private func mouseTrackingGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        let stateAtEntry = gesture.state
        defer {
            if caughtDeceleratingScroll {
                switch stateAtEntry {
                case .ended, .cancelled, .failed:
                    resetCaughtDeceleratingScroll()
                default:
                    break
                }
            }
        }

        if dragGestureHasSentMouseDown {
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                Exiting early because dragGestureHasSentMouseDown is true
                """
            )
            return
        }

        if isSuppressingSingleClickGestureForTextSelection {
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                Exiting early because isSuppressingSingleClickGestureForTextSelection is true
                """
            )
            return
        }

        guard let mouseTrackingGesture = gesture as? WKMouseTrackingGestureRecognizer else {
            preconditionFailure("Mouse tracking action from another recognizer")
        }

        guard let impl = webView._impl(), !impl.ignoresAllEvents() else {
            return
        }

        let modifierFlags = gesture.modifierFlags
        let windowNumber = impl.windowNumber()
        let timestamp = GetCurrentEventTime()

        switch gesture.state {
        case .began:
            mouseTrackingIsSuppressedForTransformGesture = false
            activeMouseTrackingGestureRecognizer = mouseTrackingGesture
            if mouseTrackingHasSentMouseDown {
                mouseTrackingGesture.beginTrackingMouseInherited(
                    fromWindowLocation: NSPoint(
                        x: CGFloat(mouseTrackingStartLocationInWindow.x()),
                        y: CGFloat(mouseTrackingStartLocationInWindow.y())
                    )
                )
            } else {
                mouseTrackingGesture.beginTrackingMouse()
            }

        case .changed:
            guard activeMouseTrackingGestureRecognizer === mouseTrackingGesture else {
                break
            }

            if shouldSuppressMouseTrackingForTransformGesture() {
                mouseTrackingIsSuppressedForTransformGesture = true
                break
            }

            if !mouseTrackingHasSentMouseDown && !mouseTrackingSendsMouseMoves {
                // Either the synthetic single-click path or this mouse-tracking path delivers a mouse
                // down for a given interaction, but never both. An event that stays within the single-click
                // gesture's allowable movement is a click: that gesture stays alive and, when it ends, the
                // synthetic click path delivers the mouse down, mouse up, and click.
                // Only once the event moves past that threshold — at which point the single-click gesture
                // cancels and this becomes a drag — does mouse tracking take over event delivery. Sending a
                // mouse down here for a stationary click would deliver a second mouse down to the content,
                // which should be avoided.
                guard movementExceedsClickAllowableMovement(mouseTrackingGesture.movementInWindowSinceStart) else {
                    break
                }

                let isResumingAfterTransformGesture = mouseTrackingIsSuppressedForTransformGesture
                mouseTrackingIsSuppressedForTransformGesture = false
                let mouseDownLocation =
                    isResumingAfterTransformGesture
                    ? mouseTrackingGesture.mouseLocationInWindow
                    : mouseTrackingGesture.startLocationInWindow

                if isResumingAfterTransformGesture {
                    mouseTrackingGesture.beginReportingMovement(fromWindowLocation: mouseDownLocation)
                }

                if isHoverActivatedByClick(at: webView.convert(mouseDownLocation, from: nil)) {
                    mouseTrackingSendsMouseMoves = true
                } else {
                    let mouseDown = syntheticMouseEvent(
                        .leftMouseDown,
                        at: adjustedMouseDownLocation(inWindow: mouseDownLocation),
                        modifierFlags: modifierFlags,
                        timestamp: timestamp,
                        windowNumber: windowNumber,
                        pressure: 1
                    )
                    impl.mouseDown(mouseDown, .Touch, .No)
                    mouseTrackingHasSentMouseDown = true
                }
            }

            if mouseTrackingSendsMouseMoves {
                let locationInWindow = mouseTrackingGesture.mouseLocationInWindow
                let mouseMoved = syntheticMouseEvent(
                    .mouseMoved,
                    at: locationInWindow,
                    modifierFlags: modifierFlags,
                    timestamp: timestamp,
                    windowNumber: windowNumber,
                    clickCount: 0,
                    pressure: 0,
                    reportingMovementFor: mouseTrackingGesture
                )
                impl.mouseMoved(mouseMoved, .Touch)
                break
            }

            let locationInWindow = mouseTrackingGesture.mouseLocationInWindow
            let mouseDragged = syntheticMouseEvent(
                .leftMouseDragged,
                at: locationInWindow,
                modifierFlags: modifierFlags,
                timestamp: timestamp,
                windowNumber: windowNumber,
                pressure: 1,
                reportingMovementFor: mouseTrackingGesture
            )
            impl.mouseDragged(mouseDragged, .Touch, .No)

        case .ended, .cancelled, .failed:
            guard activeMouseTrackingGestureRecognizer === mouseTrackingGesture else {
                break
            }

            activeMouseTrackingGestureRecognizer = nil

            if mouseTrackingSendsMouseMoves {
                mouseTrackingSendsMouseMoves = false
                break
            }

            if mouseTrackingWillBeHandedOff() {
                Logger.viewGestures.debug(
                    """
                    [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                    Handing off mouse tracking to another gesture
                    """
                )
                mouseTrackingStartLocationInWindow = WebCore.FloatPoint(mouseTrackingGesture.mouseLocationInWindow)
                break
            }

            if mouseTrackingHasSentMouseDown {
                mouseTrackingHasSentMouseDown = false
                let locationInWindow = mouseTrackingGesture.mouseLocationInWindow
                let mouseUp = syntheticMouseEvent(
                    .leftMouseUp,
                    at: locationInWindow,
                    modifierFlags: modifierFlags,
                    timestamp: timestamp,
                    windowNumber: windowNumber,
                    pressure: 0,
                    reportingMovementFor: mouseTrackingGesture
                )
                impl.mouseUp(mouseUp, .Touch, .No)
            }

        default:
            break
        }
    }

    // MARK: Pointer Tracking

    @nonobjc
    private final func dispatchTrackedPointerEvent(
        _ phase: WebKit.WebEventPhase,
        atLocationInWindow locationInWindow: NSPoint,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let webView = view, let page = webView._protectedPage().get() else {
            return
        }

        let location = WebCore.FloatPoint(webView.convert(locationInWindow, from: nil))
        let modifiers = WebKit.WebEventFactory.toWebEventModifierFlags(modifierFlags)
        page.dispatchTrackedPointerEvent(
            nil,
            phase,
            location,
            modifiers,
            consuming: .init { [weak self] wasCanceled in
                guard phase == .Began else {
                    return
                }
                self?.didDispatchPointerDown(wasCanceled: wasCanceled)
            }
        )
    }

    @nonobjc
    private final func didDispatchPointerDown(wasCanceled: Bool) {
        guard let pointerDownDeferringGestureRecognizer, pointerDownDeferringGestureRecognizer.state == .possible else {
            return
        }

        Logger.viewGestures.debug(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            deferral resolved: pointerdown canceled=\(wasCanceled)
            """
        )

        pointerDownDeferringGestureRecognizer.endDeferralShouldPreventGestures(wasCanceled)
    }

    @nonobjc
    private final func pointerTrackingShouldBegin(at locationInView: NSPoint, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard let webView = view, pointerTrackingGestureRecognizer?.isEnabled ?? false else {
            return false
        }

        if !(webView._impl()?.window()?.isKeyWindow ?? false) && !modifierFlags.contains(.command) {
            return false
        }

        // A pan here is delivered as mouse moves with no button held, so the page must not see a pressed pointer.
        if isHoverActivatedByClick(at: locationInView) {
            return false
        }

        return !isPointInScrollbar(locationInView)
    }

    @nonobjc
    private final func cancelPointerTrackingIfNeeded() {
        guard isTrackingPointer else {
            return
        }
        isTrackingPointer = false

        Logger.viewGestures.debug(
            "[pageProxyID=\(self.pageLogIdentifier)] \(#function): Canceling the tracked pointer"
        )

        dispatchTrackedPointerEvent(.Cancelled, atLocationInWindow: trackedPointerLastLocationInWindow, modifierFlags: [])
    }

    @objc
    private func pointerTrackingGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard view != nil else {
            return
        }

        logGestureAction(gesture)

        precondition(pointerTrackingGestureRecognizer === gesture)

        switch gesture.state {
        case .cancelled, .failed:
            cancelPointerTrackingIfNeeded()
        default:
            break
        }
    }

    // MARK: Image Analysis

    // Gesture-driven Live Text is arbitrated by three recognizers, plus ImageAnalysisGestureDeferralToken:
    //
    //   1. imageAnalysisGestureRecognizer (the "preflight") -- a settled 0.1s press that kicks off Vision
    //      image analysis. It's a passive observer of the interaction it measures: it recognizes
    //      simultaneously with everything, prevents nothing, and is always allowed to begin.
    //   2. imageAnalysisTextSelectionDeferringGestureRecognizer -- holds the text-selection gestures over an image until
    //      analysis resolves.
    //   3. imageAnalysisDragAndContextMenuDeferringGestureRecognizer -- holds the drag-press and secondary-click
    //      (context menu) recognizers over an image until analysis resolves.
    //
    // The two deferrals resolve to *opposite* booleans (see resolveImageAnalysisDeferrals(with:)):
    // on "text found" we must ALLOW text selection while PREVENTING drag / context menu (Live Text wins),
    // and the reverse on "no text". A single WKDeferringGestureRecognizer can't express that -- its
    // endDeferralShouldPreventGestures(_:) applies one boolean (state = .ended / .failed) to everything it
    // defers -- so the two opposite outcomes require two separate deferrals.
    //
    // iOS needs no fallback deferral because its drag / context menu are UIKit interactions gated by a
    // ProceedWithTextSelectionInImage callback. macOS drag-press / secondary-click are NSGestureRecognizers
    // on independent timers, so they must be *deferred* to keep them from firing before analysis resolves.

    @objc
    private func imageAnalysisGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        precondition(imageAnalysisGestureRecognizer === gesture)

        guard gesture.state == .began else {
            return
        }

        guard let impl = webView._impl(), !impl.ignoresAllEvents() else {
            return
        }

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            \(Self.loggingDescription(for: gesture))
            """
        )

        var request = positionInformationRequest(at: gesture.location(in: webView))
        request.includeImageData = true

        // The token keeps the image-analysis deferral open until the async analysis chain finishes (or is
        // abandoned). Capturing it through each stage of preflightImageAnalysis(_:completion:) means the deferral
        // resolves exactly when the last stage completes; dropping it early (e.g. not an image) resolves it as
        // "allow text selection".
        let gestureDeferralToken = ImageAnalysisGestureDeferralToken(controller: self)
        support.preflightImageAnalysis(request) { [weak self] foundText, element in
            let outcome: ImageAnalysisDeferralOutcome = foundText ? .foundText : .noText

            gestureDeferralToken.outcome = outcome

            if let self {
                self.lastCompletedImageAnalysis = CompletedImageAnalysis(element: element, outcome: outcome)
            }
        }
    }

    @nonobjc
    final func shouldPreventGestures(
        deferredBy deferringGestureRecognizer: NSGestureRecognizer?,
        for outcome: ImageAnalysisDeferralOutcome
    ) -> Bool {
        // Text found -> Live Text wins: allow the deferred text selection, prevent the drag / context-menu
        // fallback. No text -> the reverse.
        if deferringGestureRecognizer === imageAnalysisTextSelectionDeferringGestureRecognizer {
            return outcome == .noText
        }

        if deferringGestureRecognizer === imageAnalysisDragAndContextMenuDeferringGestureRecognizer {
            return outcome == .foundText
        }

        assertionFailure("Unexpected image analysis deferring gesture recognizer")
        return false
    }

    @nonobjc
    final func resolveImageAnalysisDeferrals(with outcome: ImageAnalysisDeferralOutcome) {
        if imageAnalysisDeferralState == .deferring {
            imageAnalysisDeferralState = .undecided
        }

        let preventTextSelection = shouldPreventGestures(deferredBy: imageAnalysisTextSelectionDeferringGestureRecognizer, for: outcome)
        let preventDragAndContextMenu = shouldPreventGestures(
            deferredBy: imageAnalysisDragAndContextMenuDeferringGestureRecognizer,
            for: outcome
        )

        // Only resolve a deferral that's still deferring. A deferral may already be resolved by the time the
        // analysis token drops -- e.g. it failed on lift (immediatelyFailsAfterTouchEnd) before slow
        // analysis finished -- and re-setting an already-terminal gesture state would be a no-op at best.
        endDeferralIfStillDeferring(imageAnalysisTextSelectionDeferringGestureRecognizer, preventingGestures: preventTextSelection)
        endDeferralIfStillDeferring(
            imageAnalysisDragAndContextMenuDeferringGestureRecognizer,
            preventingGestures: preventDragAndContextMenu
        )
    }

    @nonobjc
    private final func endDeferralIfStillDeferring(_ recognizer: WKDeferringGestureRecognizer?, preventingGestures: Bool) {
        guard let recognizer, recognizer.state == .possible else {
            return
        }
        recognizer.endDeferralShouldPreventGestures(preventingGestures)
    }

    // MARK: WKDeferringGestureRecognizerDelegate

    @nonobjc
    private final func shouldPreventGestures(
        deferredBy deferringGestureRecognizer: WKDeferringGestureRecognizer,
        info: WebKit.InteractionInformationAtPosition,
        isInScrollbar: Bool
    ) -> Bool? {
        let overLiveTextImage = WebKit.isLiveTextAvailableAndEnabled() && info.isImage

        // Over a scrollbar: drive the scrollbar, not text selection -- prevent the deferred gestures
        // so the mouse-tracking -> `Scrollbar::mouseDown` path wins.
        if isInScrollbar {
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                deferral resolved: over scrollbar; preventing text-selection gestures
                """
            )
            return true
        }

        if deferringGestureRecognizer === imageAnalysisTextSelectionDeferringGestureRecognizer
            || deferringGestureRecognizer === imageAnalysisDragAndContextMenuDeferringGestureRecognizer
        {
            // Image-analysis deferrals (see the Image Analysis design note): over an image with Live
            // Text available, keep deferring (nil) until the preflight's analysis token resolves both
            // deferrals (see resolveImageAnalysisDeferrals(with:)); otherwise this deferral has no
            // opinion, so release. We only have basic hit-test info here (this request does not fetch
            // image data), so key off info.isImage; the preflight does the full analyzability check.
            if overLiveTextImage {
                if let reusableOutcome = lastCompletedImageAnalysis?.outcome(for: info.hostImageOrVideoElementContext.value) {
                    let prevent = shouldPreventGestures(deferredBy: deferringGestureRecognizer, for: reusableOutcome)
                    Logger.viewGestures.debug(
                        """
                        [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                        deferral resolved: reusing completed image analysis outcome \
                        (prevent=\(prevent))
                        """
                    )
                    return prevent
                }

                if imageAnalysisDeferralState == .gestureFailed {
                    Logger.viewGestures.debug(
                        """
                        [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                        deferral resolved: image analysis preflight failed; not preventing
                        """
                    )
                    return false
                }

                imageAnalysisDeferralState = .deferring
                return nil
            }

            return false
        }

        if deferringGestureRecognizer === dragDeferringGestureRecognizer {
            let isDraggable = info.representsDraggableElement

            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                deferral resolved: isDraggable=\(isDraggable) \
                (link=\(info.isLink) image=\(info.isImage) \
                attachment=\(info.isAttachment) \
                dhtml=\(info.isDHTMLDraggable) color=\(info.isColorInput) \
                prefersDrag=\(info.prefersDraggingOverTextSelection))
                """
            )

            return isDraggable && !overLiveTextImage
        }

        if deferringGestureRecognizer === secondaryClickDeferringGestureRecognizer {
            let isSelectable = info.representsSelectableContent
            let prefersManipulation = info.prefersDirectManipulation

            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                deferral resolved: isSelectable=\(isSelectable) \
                prefersDirectManipulation=\(prefersManipulation) \
                (selectability=\(info.selectability.rawValue) \
                overEditableContent=\(info.isOverEditableContent))
                """
            )

            return (!isSelectable || prefersManipulation) && !overLiveTextImage
        }

        if deferringGestureRecognizer === enclosingScrollViewPanDeferringGestureRecognizer {
            let prefersManipulation = info.prefersDirectManipulation

            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                deferral resolved: enclosing scroll view pan yields to content=\(prefersManipulation)
                """
            )

            return prefersManipulation
        }

        preconditionFailure("Unexpected deferring gesture recognizer")
    }

    // MARK: Position Information

    func didCommitLoadForMainFrame() {
        support.invalidatePositionInformation()
        resetDOMDoubleClickGestureRecognizer()
        layerTreeTransactionIdAtLastInteractionStart = nil
        lastCompletedImageAnalysis = nil
        isTrackingPointer = false
    }

    @nonobjc
    final func isPointInScrollbar(_ locationInView: NSPoint) -> Bool {
        view?._impl()?.isPointInScrollbar(locationInView) ?? false
    }

    @nonobjc
    final func secondaryClickShouldBegin(at locationInView: NSPoint) -> Bool {
        guard view != nil else {
            return false
        }

        let radius = saturatingInt32((secondaryClickGestureRecognizer?.allowableMovement ?? 0).rounded(.up))

        let information = support.positionInformation

        let requestIsValid = isPositionInformationValid(at: locationInView, radius: radius)
        let isSecondaryClickable = information.representsSecondaryClickableElement
        let isOverSelectableText = information.isOverSelectableText

        // The secondary click owns points that are not over selectable text (e.g. the page background
        // or a video player). Over a run of selectable text, the text selection manager should win so
        // that a long press selects a word instead of synthesizing a context menu.
        let shouldBegin = requestIsValid && isSecondaryClickable && !isOverSelectableText

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Secondary click shouldBegin → \(shouldBegin) \
            (hasInfo=\(self.support.hasValidPositionInformation) \
            requestIsValid=\(requestIsValid) \
            secondaryClickable=\(isSecondaryClickable) \
            overSelectableText=\(isOverSelectableText) selectability=\(information.selectability.rawValue) \
            prefersManipulation=\(information.prefersDirectManipulation) \
            image=\(information.isImage) video=\(information.isOverVideo) \
            longClickQuirk=\(information.shouldTreatLongClickAsSecondaryClickQuirk) radius=\(radius))
            """
        )

        if !requestIsValid {
            support.invalidatePositionInformation()
        }

        return shouldBegin
    }

    @nonobjc
    final func positionInformationRequest(at locationInView: NSPoint) -> WebKit.InteractionInformationRequest {
        var request = WebKit.InteractionInformationRequest(WebCore.IntPoint(locationInView))
        request.inputSource = .Touch
        return request
    }

    @nonobjc
    final func adjustedMouseDownLocation(inWindow locationInWindow: NSPoint) -> NSPoint {
        guard let webView = view, let adjustedLocationInView = support.nearbySliderInteractionLocation.value else {
            return locationInWindow
        }

        let locationInView = webView.convert(locationInWindow, from: nil)
        if !isPositionInformationValid(at: locationInView, radius: mouseDownPositionInformationToleranceRadius) {
            return locationInWindow
        }

        let adjustedLocationInViewCoordinates = CGPoint(adjustedLocationInView)

        let maximumInteractionAdjustmentDistance: CGFloat = 48
        if abs(adjustedLocationInViewCoordinates.x - locationInView.x) > maximumInteractionAdjustmentDistance
            || abs(adjustedLocationInViewCoordinates.y - locationInView.y) > maximumInteractionAdjustmentDistance
        {
            return locationInWindow
        }

        if !NSPointInRect(adjustedLocationInViewCoordinates, webView.bounds) {
            return locationInWindow
        }

        return webView.convert(adjustedLocationInViewCoordinates, to: nil)
    }

    @nonobjc
    private final func isPositionInformationValid(at locationInView: NSPoint, radius: Int32) -> Bool {
        let request = positionInformationRequest(at: locationInView)
        return support.positionInformationIsApproximatelyValid(request, radius: radius)
    }

    @nonobjc
    final func dragPressShouldBegin(at locationInView: NSPoint) -> Bool {
        guard view != nil else {
            return false
        }

        let radius = saturatingInt32((dragPressGestureRecognizer?.allowableMovement ?? 0).rounded(.up))

        let information = support.positionInformation

        // FIXME: Migrate to requestDragStart: IPC for an authoritative decision.
        // The heuristic below approximates DragController::draggableElement() by consulting the same element-type and style signals.
        let isDraggable = information.representsDraggableElement
        let requestIsValid = isPositionInformationValid(at: locationInView, radius: radius)
        let shouldDrag = requestIsValid && isDraggable && !information.isHoverActivatedByClick

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Drag-press shouldBegin → \(shouldDrag) \
            (hasInfo=\(self.support.hasValidPositionInformation) \
            link=\(information.isLink) image=\(information.isImage) \
            attachment=\(information.isAttachment) \
            dhtml=\(information.isDHTMLDraggable) color=\(information.isColorInput) \
            prefersDrag=\(information.prefersDraggingOverTextSelection) \
            hoverActivatedByClick=\(information.isHoverActivatedByClick) radius=\(radius))
            """
        )

        if !requestIsValid {
            support.invalidatePositionInformation()
        }

        return shouldDrag
    }

    @nonobjc
    final func panShouldBegin(at locationInView: NSPoint) -> Bool {
        guard view != nil else {
            return false
        }

        let requestIsValid = isPositionInformationValid(
            at: locationInView,
            radius: panPositionInformationToleranceRadius
        )

        let information = support.positionInformation

        // FIXME: (rdar://181964604) Because of this logic, vertically scrolling over these elements likely will not work.
        let prefersInteraction = information.prefersDirectManipulation
        let usesHoverActivatedByClickBounds = !requestIsValid && isInsideHoverActivatedByClickBounds(at: locationInView)
        let yieldToContent =
            (requestIsValid && (prefersInteraction || information.isHoverActivatedByClick)) || usesHoverActivatedByClickBounds

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Pan shouldBegin → \(!yieldToContent) \
            (hasInfo=\(self.support.hasValidPositionInformation) \
            valid=\(requestIsValid) prefersInteraction=\(prefersInteraction) \
            hoverActivatedByClick=\(information.isHoverActivatedByClick) \
            fallback=\(usesHoverActivatedByClickBounds))
            """
        )

        return !yieldToContent
    }

    @nonobjc
    private final func isInsideHoverActivatedByClickBounds(at locationInView: NSPoint) -> Bool {
        guard let page = view?._protectedPage().get(), let bounds = page.hoverActivatedByClickBounds().value else {
            return false
        }
        return bounds.contains(WebCore.IntPoint(locationInView))
    }

    @nonobjc
    final func isHoverActivatedByClick(at locationInView: NSPoint) -> Bool {
        if !isPositionInformationValid(at: locationInView, radius: panPositionInformationToleranceRadius) {
            return isInsideHoverActivatedByClickBounds(at: locationInView)
        }

        return support.positionInformationIsHoverActivatedByClick
    }

    // MARK: Drag Handling

    @objc
    private func dragPressGestureRecognized(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        logGestureAction(gesture)

        guard let dragPressGestureRecognizer, dragPressGestureRecognizer === gesture else {
            return
        }

        guard let impl = webView._impl() else {
            return
        }

        if impl.ignoresAllEvents() {
            Logger.viewGestures.debug("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Ignored gesture")
            return
        }

        let modifierFlags = gesture.modifierFlags
        let locationInWindow = gesture.location(in: nil)
        let windowNumber = impl.windowNumber()
        let timestamp = GetCurrentEventTime()

        switch gesture.state {
        case .began:
            handleTapCancelled()
            dragGestureHasSentMouseDown = false
            dragGestureDidReceiveDragStart = false
            dragIdentifier &+= 1

            let mouseDown = syntheticMouseEvent(
                .leftMouseDown,
                at: locationInWindow,
                modifierFlags: modifierFlags,
                timestamp: timestamp,
                windowNumber: windowNumber,
                pressure: 1
            )
            impl.mouseDown(mouseDown, .Touch, .Yes)
            dragGestureHasSentMouseDown = true

            dragPressGestureRecognizer.beginReportingMovement(fromWindowLocation: locationInWindow)

        case .changed:
            guard dragGestureHasSentMouseDown else {
                break
            }
            // Drive WebCore's drag-initiation hysteresis. Once the session exists, AppKit tracks the
            // gesture itself and WebCore is driven by the platform drag callbacks, so we stop feeding it.
            if gestureDraggingSession == nil {
                let mouseDragged = syntheticMouseEvent(
                    .leftMouseDragged,
                    at: locationInWindow,
                    modifierFlags: modifierFlags,
                    timestamp: timestamp,
                    windowNumber: windowNumber,
                    pressure: 1,
                    reportingMovementFor: dragPressGestureRecognizer
                )
                impl.mouseDragged(mouseDragged, .Touch, .Yes)
            }

        case .ended, .cancelled, .failed:
            guard dragGestureHasSentMouseDown else {
                break
            }

            let mouseUp = syntheticMouseEvent(
                .leftMouseUp,
                at: locationInWindow,
                modifierFlags: modifierFlags,
                timestamp: timestamp,
                windowNumber: windowNumber,
                pressure: 0,
                reportingMovementFor: dragPressGestureRecognizer
            )
            impl.mouseUp(mouseUp, .Touch, .Yes)

            // Normally, drag state is cleared in draggingSessionEnded() (normal completion) or in startDrag() when
            // beginDraggingSession(with:gesture:source:) returns nil (gesture ended before session started).
            // But, if the page prevents dragstart, we won't get startDrag(), so clear the state ourselves.
            support.doAfterProcessingAllPendingMouseEvents { [weak self, dragIdentifier = self.dragIdentifier] in
                guard let self, self.dragIdentifier == dragIdentifier else {
                    return
                }
                if !self.dragGestureHasSentMouseDown || self.dragGestureDidReceiveDragStart || self.gestureDraggingSession != nil {
                    return
                }
                self.dragGestureHasSentMouseDown = false
            }

        default:
            break
        }
    }

    // MARK: Click Handling

    @nonobjc
    final func updateLayerTreeTransactionIdAtLastInteractionStart() {
        if let transactionID = support.lastCommittedMainFrameLayerTreeTransactionID.value {
            layerTreeTransactionIdAtLastInteractionStart = transactionID
        }
    }

    @nonobjc
    final func handleTapBegan(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        // Equivalent to acceptsFirstMouse, but here because potential taps are asynchronous, which
        // means that the window can get focus from this tap before we complete the click.
        let commandKeyIsDown = gesture.modifierFlags.contains(.command)
        if !(webView._impl()?.window()?.isKeyWindow ?? false) && !commandKeyIsDown {
            Logger.viewGestures.log(
                "[pageProxyID=\(self.pageLogIdentifier)] \(#function): Tap began in an inactive window; suppressing"
            )
            return
        }

        guard !isSuppressingSingleClickGestureForTextSelection else {
            return
        }

        let position = WebCore.FloatPoint(gesture.location(in: webView))

        updateLayerTreeTransactionIdAtLastInteractionStart()

        let tapID = WebKit.TapIdentifier.generate()
        latestTapID = tapID.toUInt64()
        potentialTapIsInProgress = true

        clickHighlight?.beginRequest(tapID, expectsFastCommit: true)

        webView._protectedPage().get()?.potentialTapAtPosition(.init(), position, false, tapID, .Touch)
    }

    @nonobjc
    final func handleTapEnded(_ gesture: NSGestureRecognizer) {
        guard let webView = view else {
            return
        }

        guard potentialTapIsInProgress else {
            return
        }

        endPotentialTapAndEnableDoubleTapGesturesIfNecessary()

        guard let layerTreeTransactionIdAtLastInteractionStart else {
            handleTapCancelled()
            return
        }

        // If this tap completes a double tap, the web process delivers it as a double click when there is a listener
        // for one, instead of the DOM double-click gesture also sending it.
        let completesDoubleClick: WebKit.CompletesDoubleClick = takeCompletedDOMDoubleClick() ? .Yes : .No

        clickHighlight?.showPendingHighlightForCommittedClick()

        let modifiers = WebKit.WebEventFactory.toWebEventModifierFlags(gesture.modifierFlags)
        webView._protectedPage().get()?
            .commitPotentialTap(
                .init(),
                modifiers,
                layerTreeTransactionIdAtLastInteractionStart,
                WebCore.mousePointerID,
                completesDoubleClick
            )

        clickHighlight?.fadeUnlessAwaitingHighlight()
    }

    @nonobjc
    final func handleTapCancelled() {
        clickHighlight?.cancel()

        guard potentialTapIsInProgress else {
            return
        }

        potentialTapIsInProgress = false

        if let webView = view {
            webView._protectedPage().get()?.cancelPotentialTap()
        }
    }

    @nonobjc
    private final func endPotentialTapAndEnableDoubleTapGesturesIfNecessary() {
        potentialTapIsInProgress = false
        setDoubleTapGesturesEnabled(true)
    }

    @nonobjc
    final func setDoubleTapGesturesEnabled(_ enabled: Bool) {
        doubleClickGestureRecognizer?.isEnabled = enabled
    }

    // MARK: Two-Phase Click Response Handlers

    @objc(potentialTapInProgress)
    var isPotentialTapInProgress: Bool {
        @objc(isPotentialTapInProgress)
        get { potentialTapIsInProgress }
    }

    var clickHighlightController: WKClickHighlightController? { clickHighlight }

    func disableDoubleTapGesturesDuringTapIfNecessary(forRequest requestID: UInt64) {
        guard latestTapID == requestID else {
            return
        }

        setDoubleTapGesturesEnabled(false)
    }

    func commitPotentialTapFailed() {
        guard view != nil else {
            return
        }

        handleTapCancelled()

        Logger.viewGestures.error("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Commit potential tap failed")
    }

    func didCompleteSyntheticClick() {
        guard let webView = view else {
            return
        }

        Logger.viewGestures.log("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Synthetic click completed")

        let hasHoverActivatedByClick = webView._protectedPage().get()?.hoverActivatedByClickBounds().has_value() ?? false
        let hadHoverActivatedByClick = mayHaveHoverActivatedByClick
        mayHaveHoverActivatedByClick = hasHoverActivatedByClick
        if hadHoverActivatedByClick || hasHoverActivatedByClick {
            support.invalidatePositionInformation()
        }
    }

    func didHandleTapAsHover() {
        guard view != nil else {
            return
        }

        Logger.viewGestures.log("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Tap was handled as hover")

        mayHaveHoverActivatedByClick = true
        support.invalidatePositionInformation()
    }

    @objc(didNotHandleTapAsClickAtPoint:)
    func didNotHandleTapAsClick(at point: NSPoint) {
        guard view != nil else {
            return
        }

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Tap at (\(point.x, format: .fixed(precision: 0)), \(point.y, format: .fixed(precision: 0))) was not handled as click
            """
        )

        // FIXME: Consider smart magnification here if a double tap is pending and the point hasn't moved significantly.
    }

    // MARK: Wheel Event Handling

    @nonobjc
    private final func panVelocity(in view: NSView?) -> NSPoint {
        guard let panGestureRecognizer = panGestureRecognizer as? WKPanGestureRecognizer else {
            return .zero
        }
        return panGestureRecognizer.wk_velocity(in: view)
    }

    @nonobjc
    final func sendWheelEvent(for gesture: NSPanGestureRecognizer) {
        guard let webView = view, let impl = webView._impl() else {
            return
        }

        let timestamp = WTF.MonotonicTime.fromRawSeconds(gesture.timestamp)
        let locationInViewCoordinates = gesture.location(in: webView)
        let locationInView = WebCore.FloatPoint(locationInViewCoordinates)
        let position = WebCore.IntPoint(locationInView)
        let globalPosition = WebCore.globalPoint(gesture.location(in: nil), impl.window())
        var gestureDelta = gesture.takeTranslation(in: webView)

        if suppressNextPanScrollDelta {
            suppressNextPanScrollDelta = false
            gestureDelta = WebCore.FloatSize()
        }

        guard let page = webView._protectedPage().get() else {
            return
        }

        if page.delegatesScalingToUIProcess(), impl.moveMagnificationOriginIfMagnifying(locationInViewCoordinates) {
            gestureDelta = WebCore.FloatSize()
        }

        let pinnedState = page.pinnedStateIncludingAncestorsAtPoint(locationInView)
        let canScrollHorizontally = gesture._canPanHorizontally && !(pinnedState[.Left] && pinnedState[.Right])
        let canScrollVertically = gesture._canPanVertically && !(pinnedState[.Top] && pinnedState[.Bottom])
        gestureDelta = WebCore.FloatSize(
            directionalScrollLockTracker.update(
                delta: CGSize(gestureDelta),
                canScrollHorizontally: canScrollHorizontally,
                canScrollVertically: canScrollVertically,
                prefersUnlocked: prefersUnlockedScroll(gesture),
                time: gesture.timestamp
            )
        )

        func makeWheelEventInit(_ delta: WebCore.FloatSize, phase: WebKit.WebEventPhase) -> WebKit.WebWheelEventInit {
            var event = WebKit.WebEventData()
            event.type = .Wheel
            event.timestamp = timestamp

            var wheel = WebKit.WebWheelEventData()
            wheel.position = position
            wheel.globalPosition = WebCore.IntPoint(globalPosition)
            wheel.delta = delta
            wheel.wheelTicks = delta.scaled(1 / Float(WebCore.Scrollbar.pixelsPerLineStep()))
            wheel.granularity = .ScrollByPixelWheelEvent
            wheel.directionInvertedFromDevice = false
            wheel.phase = phase
            wheel.momentumPhase = .None
            wheel.hasPreciseScrollingDeltas = true
            wheel.scrollCount = 1
            wheel.unacceleratedScrollingDelta = delta
            wheel.ioHIDEventTimestamp = timestamp
            wheel.momentumEndType = .Unknown
            wheel.inputSource = .Touch
            return WebKit.WebWheelEventInit(event: event, wheel: wheel)
        }

        let phase = WebKit.WebEventPhase(gesture.state)
        if phase == .Began {
            hasEverMagnifiedDuringCurrentGesture = false
        }
        // The third argument is the C++ default, which Swift does not take from the declaration.
        if !WTF.areEssentiallyEqual(impl.magnification(), 1, Double.ulpOfOne) {
            hasEverMagnifiedDuringCurrentGesture = true
        }

        let forwardToGestureController = impl.allowsBackForwardNavigationGestures() && prefersForwardingToGestureController(gesture)

        func dispatchWheelEvent(_ delta: WebCore.FloatSize, phase: WebKit.WebEventPhase) {
            interruptMomentumForScrollWheelEvent()

            lastPanWheelEventWasHandledByViewGestureController =
                forwardToGestureController
                && impl.handleScrollWheelEventForNavigationGesture(
                    WebKit.NativeWebWheelEvent.create(WebKit.WebWheelEvent.create(consuming: makeWheelEventInit(delta, phase: phase)).get())
                        .get()
                )
            if lastPanWheelEventWasHandledByViewGestureController {
                Logger.viewGestures.debug(
                    "[pageProxyID=\(self.pageLogIdentifier)] \(#function): View gesture controller handled gesture"
                )
                return
            }

            page.handleNativeWheelEvent(
                consuming: WebKit.NativeWebWheelEvent.create(
                    WebKit.WebWheelEvent.create(consuming: makeWheelEventInit(delta, phase: phase)).get()
                )
            )
        }

        if phase == .Began {
            dispatchWheelEvent(WebCore.FloatSize(), phase: .MayBegin)
        }

        dispatchWheelEvent(gestureDelta, phase: phase)
    }

    @objc
    var everMagnifiedDuringCurrentGesture: Bool { hasEverMagnifiedDuringCurrentGesture }

    // MARK: Momentum Handling

    @nonobjc
    final func startMomentumIfNeeded(for gesture: NSPanGestureRecognizer) {
        guard let webView = view else {
            return
        }

        guard gesture.state == .ended, supportsMomentumScroll(gesture) else {
            return
        }

        // Momentum started now would scroll out of sight and then show up all at once.
        if isTransformGestureActiveOrEnding {
            fastScrollTracker.reset()
            return
        }

        // A swipe navigates instead of scrolling, so it has no momentum. Momentum would scroll the page navigated to.
        if lastPanWheelEventWasHandledByViewGestureController {
            fastScrollTracker.reset()
            return
        }

        let unfilteredVelocity = WebCore.toFloatSize(WebCore.FloatPoint(panVelocity(in: webView)))

        // Continue the scroll along the same axis the drag was locked to rather than reintroducing
        // diagonal drift; also keeps fastScrollTracker's velocity heuristics off-axis-clean.
        let velocity = WebCore.FloatSize(
            directionalScrollLockTracker.filterVelocity(
                CGSize(unfilteredVelocity),
                prefersUnlocked: prefersUnlockedScroll(gesture)
            )
        )

        let minimumVelocityForSwipe: Float = 20
        let minimumVelocityForMomentum: Float = 250

        func maximumComponentMagnitude(_ vector: WebCore.FloatSize) -> Float {
            max(abs(vector.width()), abs(vector.height()))
        }

        // Advance the swipe chain for every gesture that was fast enough to be a swipe, judged on the
        // unfiltered velocity: the user swiped even if the lock just zeroed the axis they swiped along, and
        // the tracker has to see it to consume its caughtMomentum and advance its endTime. Slower gestures
        // leave the tracker alone.
        let fastScrollMultiplier =
            maximumComponentMagnitude(unfilteredVelocity) >= minimumVelocityForSwipe
            ? fastScrollTracker.update(location: gesture.location(in: nil), velocity: CGSize(velocity), time: gesture.timestamp) : 1

        // Suppressing the gesture itself is judged on the filtered velocity, which can only be smaller, so
        // anything reaching this point has already been through the tracker above.
        let velocityMagnitude = maximumComponentMagnitude(velocity)
        if velocityMagnitude < minimumVelocityForMomentum {
            return
        }

        support.startMomentum(
            atPosition: gesture.location(in: webView),
            globalPosition: WebCore.globalPoint(gesture.location(in: nil), webView._impl()?.window()),
            timestamp: gesture.timestamp,
            velocity: CGSize(velocity),
            fastScrollMultiplier: fastScrollMultiplier
        )
        isMomentumActive = true

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Started momentum scrolling with velocity \(velocityMagnitude, format: .fixed(precision: 2)) pts/s
            """
        )
    }

    @nonobjc
    final func interruptMomentumIfNeeded() {
        guard isMomentumActive else {
            return
        }
        isMomentumActive = false

        guard let webView = view else {
            return
        }

        fastScrollTracker.didCatchMomentum()
        directionalScrollLockTracker.didCatchMomentum()
        caughtDeceleratingScroll = true
        suppressNextPanScrollDelta = true

        support.invalidatePositionInformation()

        support.interruptMomentum()

        if let page = webView._protectedPage().get() {
            page.interruptSyntheticMomentumScrolling()
            Logger.viewGestures.log("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Interrupted momentum scrolling")
        }
    }

    func interruptMomentumForScrollWheelEvent() {
        support.interruptMomentum()
    }

    @nonobjc
    final func resetCaughtDeceleratingScroll() {
        caughtDeceleratingScroll = false
        suppressNextPanScrollDelta = false
    }

    // MARK: Magnification and Rotation

    @nonobjc
    private final func currentMagnification(_ magnification: Double, atPhase phase: WebKit.WebEventPhase) -> Double {
        if phase == .Began {
            lastCumulativeMagnification = 0
        }
        let currentMagnification = (1 + magnification) / (1 + lastCumulativeMagnification) - 1
        lastCumulativeMagnification = magnification
        return currentMagnification
    }

    @nonobjc
    private final func currentRotation(_ rotation: Double, atPhase phase: WebKit.WebEventPhase) -> Double {
        if phase == .Began {
            lastCumulativeRotation = 0
        }
        let currentRotation = rotation - lastCumulativeRotation
        lastCumulativeRotation = rotation
        return currentRotation
    }

    @objc
    private func magnificationGestureRecognized(_ gesture: NSMagnificationGestureRecognizer) {
        guard let webView = view else {
            return
        }

        let phase = WebKit.WebEventPhase(gesture.state)
        let magnification = currentMagnification(gesture.magnification, atPhase: phase)

        if phase == .Began || phase == .Changed {
            transformGestureDidDrive()
        } else {
            transformGestureDidEnd()
        }

        let initValue = WebKit.NativeWebGestureEvent.Init(
            kind: .Magnification,
            phase: phase,
            locationInWindow: gestureCentroidInWindow(for: gesture),
            gestureScale: Float(magnification),
            gestureRotation: 0,
            timestamp: WTF.MonotonicTime.fromRawSeconds(GetCurrentEventTime()),
            allowsNativeZoom: magnificationGestureRecognizerCanZoom,
            inputSource: .Touch
        )
        let webEvent = WebKit.NativeWebGestureEvent.create(initValue, webView).get()

        guard let viewImpl = webView._impl() else {
            return
        }

        if !viewImpl.allowsMagnification() {
            if let webEvent {
                webView._protectedPage().get()?.handleGestureEvent(consuming: .init(webEvent))
            }
            return
        }

        if phase == .Began {
            viewImpl.dismissContentRelativeChildWindowsWithAnimation(false)
        }

        let origin = webEvent.map { CGPoint($0.position()) } ?? .zero
        if viewImpl.handleMagnificationGestureIfMagnifying(magnification, phase, origin, .Touch) {
            return
        }

        if let webEvent {
            webView._protectedPage().get()?.handleGestureEvent(consuming: .init(webEvent))
        }
    }

    @objc
    private func rotationGestureRecognized(_ gesture: NSRotationGestureRecognizer) {
        guard let webView = view else {
            return
        }

        let phase = WebKit.WebEventPhase(gesture.state)

        if phase == .Began || phase == .Changed {
            transformGestureDidDrive()
        } else {
            transformGestureDidEnd()
        }

        let initValue = WebKit.NativeWebGestureEvent.Init(
            kind: .Rotation,
            phase: phase,
            locationInWindow: gestureCentroidInWindow(for: gesture),
            gestureScale: 0,
            gestureRotation: Float(currentRotation(gesture.rotationInDegrees, atPhase: phase)),
            timestamp: WTF.MonotonicTime.fromRawSeconds(GetCurrentEventTime()),
            allowsNativeZoom: true,
            inputSource: .Touch
        )
        if let event = WebKit.NativeWebGestureEvent.create(initValue, webView).get() {
            webView._protectedPage().get()?.handleGestureEvent(consuming: .init(event))
        }
    }

    // MARK: Drag Gesture State

    var activeDragGestureRecognizer: NSGestureRecognizer? {
        if let textSelectionDragGesture {
            return textSelectionDragGesture
        }
        if dragGestureHasSentMouseDown {
            return dragPressGestureRecognizer
        }
        return nil
    }

    func setTextSelectionDragGesture(_ gesture: NSGestureRecognizer, completionHandler: @escaping (NSDraggingSession) -> Void) {
        if let textSelectionDragGesture {
            Logger.viewGestures.error(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                Replacing prior text-selection drag gesture \
                \(Self.loggingDescription(for: textSelectionDragGesture)) (completion handler set: \
                \(self.textSelectionDragCompletionHandler != nil)); prior drag never reached \
                setGestureDraggingSession(_:)
                """
            )
            assertionFailure("A text selection drag gesture is already set")
        }

        textSelectionDragGesture = gesture
        textSelectionDragCompletionHandler = completionHandler
    }

    func didReceiveDragStart() {
        dragGestureDidReceiveDragStart = true
    }

    func setGestureDraggingSession(_ session: NSDraggingSession?) {
        gestureDraggingSession = session
        guard let session else {
            return
        }

        cancelPointerTrackingIfNeeded()

        Logger.viewGestures.log("[pageProxyID=\(self.pageLogIdentifier)] \(#function): Drag session began")

        if let handler = textSelectionDragCompletionHandler.take() {
            handler(session)
        }
    }

    func clearGestureDragState() {
        gestureDraggingSession = nil
        textSelectionDragGesture = nil
        textSelectionDragCompletionHandler = nil
        dragGestureHasSentMouseDown = false
        dragGestureDidReceiveDragStart = false
    }

    func cancelClickHighlight() {
        clickHighlight?.cancel()
    }

    func reset() {
        clearGestureDragState()
        handleTapCancelled()
        cancelPointerTrackingIfNeeded()
        activeMouseTrackingGestureRecognizer = nil
        mouseTrackingHasSentMouseDown = false
        mouseTrackingIsSuppressedForTransformGesture = false
        contentDeclinedTransformGesture = false
        lastTransformGestureDriveTime = nil
        support.resetMomentum()
        mouseTrackingSendsMouseMoves = false
        mayHaveHoverActivatedByClick = false
        isMomentumActive = false
        resetCaughtDeceleratingScroll()
        resetDOMDoubleClickGestureRecognizer()
        fastScrollTracker.reset()
        directionalScrollLockTracker.reset()
        isSuppressingSingleClickGestureForTextSelection = false
        latestTapID = nil
        layerTreeTransactionIdAtLastInteractionStart = nil
        lastCompletedImageAnalysis = nil
        support.resetPositionInformation()
    }

    // MARK: NSGestureRecognizerDelegate

    // The text selection manager's gestures, read as the NSArray AppKit returns: the tests below are identity
    // tests, so no element is bridged or class-checked.
    @nonobjc
    private static func textSelectionGestures(of webView: WKWebView) -> NSArray? {
        webView.textSelectionManager?.gesturesForFailureRequirements as NSArray?
    }

    @nonobjc
    private static func isTextSelectionGesture(_ gesture: NSGestureRecognizer, of webView: WKWebView) -> Bool {
        guard let gestures = textSelectionGestures(of: webView) else {
            return false
        }
        return gestures.indexOfObjectIdentical(to: gesture) != NSNotFound
    }

    @nonobjc
    private final func shouldRecognizeSimultaneouslyWithMouseTrackingGesture(_ gesture: NSGestureRecognizer) -> Bool {
        guard let webView = view else {
            return false
        }

        if isMouseTrackingGestureRecognizer(gesture) || isOurManipulationGestureRecognizer(gesture) {
            return true
        }

        if gesture === doubleClickGestureRecognizer || gesture === singleClickGestureRecognizer || gesture === dragPressGestureRecognizer {
            return true
        }

        if gesture.name == "NSThemeFrame.panTouchGestureRecognizer" {
            return true
        }

        if Self.isTextSelectionGesture(gesture, of: webView) {
            return true
        }

        // An enclosing scroll view pan can report that it "began" even while being deferred,
        // so let mouse tracking recognize simultaneously until we have a deferral decision.
        return isEnclosingScrollViewPanHeldByDeferral(gesture)
    }

    @nonobjc
    private final func isEnclosingScrollViewPanHeldByDeferral(_ gesture: NSGestureRecognizer) -> Bool {
        guard let enclosingScrollViewPanDeferringGestureRecognizer else {
            return false
        }

        let deferralState = enclosingScrollViewPanDeferringGestureRecognizer.state
        return (deferralState == .possible || deferralState == .ended)
            && deferringGestureRecognizer(enclosingScrollViewPanDeferringGestureRecognizer, shouldDeferOtherGestureRecognizer: gesture)
    }

    @objc(gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:)
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        guard let webView = view else {
            return false
        }

        logArbitration(gestureRecognizer, otherGestureRecognizer)

        if isSamePair(gestureRecognizer, otherGestureRecognizer, as: singleClickGestureRecognizer, panGestureRecognizer) {
            return true
        }

        if isSamePair(gestureRecognizer, otherGestureRecognizer, as: magnificationGestureRecognizer, panGestureRecognizer) {
            return true
        }

        if isSamePair(gestureRecognizer, otherGestureRecognizer, as: rotationGestureRecognizer, panGestureRecognizer) {
            return true
        }

        if isSamePair(gestureRecognizer, otherGestureRecognizer, as: magnificationGestureRecognizer, rotationGestureRecognizer) {
            return true
        }

        if gestureRecognizer is WKDeferringGestureRecognizer || otherGestureRecognizer is WKDeferringGestureRecognizer {
            return true
        }

        // Live Text (see the Image Analysis design note): the preflight is a passive observer, so it
        // recognizes simultaneously with everything -- it must never block, or be blocked by, the
        // interaction it measures.
        if gestureRecognizer === imageAnalysisGestureRecognizer || otherGestureRecognizer === imageAnalysisGestureRecognizer {
            return true
        }

        if gestureRecognizer === pointerTrackingGestureRecognizer || otherGestureRecognizer === pointerTrackingGestureRecognizer {
            return true
        }

        if gestureRecognizer === domDoubleClickGestureRecognizer || otherGestureRecognizer === domDoubleClickGestureRecognizer {
            return true
        }

        if isMouseTrackingGestureRecognizer(gestureRecognizer)
            && shouldRecognizeSimultaneouslyWithMouseTrackingGesture(otherGestureRecognizer)
        {
            return true
        }

        if isMouseTrackingGestureRecognizer(otherGestureRecognizer)
            && shouldRecognizeSimultaneouslyWithMouseTrackingGesture(gestureRecognizer)
        {
            return true
        }

        if isSamePair(gestureRecognizer, otherGestureRecognizer, as: dragPressGestureRecognizer, singleClickGestureRecognizer) {
            return true
        }

        if gestureRecognizer === singleClickGestureRecognizer
            && isBuiltInScrollViewPanGestureRecognizer(otherGestureRecognizer)
            && otherGestureRecognizer.view is NSScrollView
            && !isCatchingDeceleratingScroll(otherGestureRecognizer)
        {
            return true
        }

        // Allow the single click GR to be simultaneously recognized with any of those from the text
        // selection manager.
        if gestureRecognizer === singleClickGestureRecognizer {
            return Self.isTextSelectionGesture(otherGestureRecognizer, of: webView)
        }

        if otherGestureRecognizer === singleClickGestureRecognizer {
            return Self.isTextSelectionGesture(gestureRecognizer, of: webView)
        }

        return false
    }

    @objc(gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:)
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        guard let webView = view else {
            return false
        }

        logArbitration(gestureRecognizer, otherGestureRecognizer)

        if let deferringGestureRecognizer = gestureRecognizer as? WKDeferringGestureRecognizer {
            return deferringGestureRecognizer.shouldDefer(otherGestureRecognizer)
        }

        // Fail any gestures from the text selection manager if the secondary click GR handles them.
        return gestureRecognizer === secondaryClickGestureRecognizer && Self.isTextSelectionGesture(otherGestureRecognizer, of: webView)
    }

    @objc(gestureRecognizer:shouldRequireFailureOfGestureRecognizer:)
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        guard view != nil else {
            return false
        }

        logArbitration(gestureRecognizer, otherGestureRecognizer)

        if gestureRecognizer === singleClickGestureRecognizer && otherGestureRecognizer === doubleClickGestureRecognizer {
            return true
        }

        if isMouseTrackingGestureRecognizer(gestureRecognizer) && otherGestureRecognizer === panGestureRecognizer {
            let panCanScroll = panGestureRecognizerCanScroll
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                Mouse tracking requires pan to fail: \(panCanScroll)
                """
            )
            return panCanScroll
        }

        return false
    }

    @objc(gestureRecognizerShouldBegin:)
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let webView = view else {
            return false
        }

        if gestureRecognizer === pointerTrackingGestureRecognizer {
            return pointerTrackingShouldBegin(
                at: gestureRecognizer.location(in: webView),
                modifierFlags: gestureRecognizer.modifierFlags
            )
        }

        Logger.viewGestures.debug(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Gesture: \(Self.loggingDescription(for: gestureRecognizer))
            """
        )

        let locationInViewCoordinates =
            if let panGestureRecognizer, gestureRecognizer === panGestureRecognizer {
                panGestureRecognizer.startLocation(in: webView)
            } else {
                gestureRecognizer.location(in: webView)
            }

        if gestureRecognizer is WKDeferringGestureRecognizer {
            return true
        }

        // While catching a decelerating scroll, only select gestures are allowed to begin:
        // - single click, so it can reset the interruption state
        // - mouse tracking or pan, so they can continue with successive scrolls (scrollbar drag for the former)
        // - magnification or rotation, so they can continue with simultaneous manipulation gestures
        if caughtDeceleratingScroll {
            if gestureRecognizer === singleClickGestureRecognizer {
                return true
            }
            if isMouseTrackingGestureRecognizer(gestureRecognizer) && isPointInScrollbar(locationInViewCoordinates) {
                return true
            }
            if !isOurManipulationGestureRecognizer(gestureRecognizer) {
                return false
            }
        }

        // An event over a scrollbar is a scrollbar interaction; only a mouse-tracking gesture (which drives
        // `Scrollbar::mouseDown` -> thumb drag) should handle it. The AppKit text-selection/context-menu gestures
        // are handled separately in the deferral delegate.
        if isPointInScrollbar(locationInViewCoordinates) && !isMouseTrackingGestureRecognizer(gestureRecognizer) {
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                Denying gesture over scrollbar: \(Self.loggingDescription(for: gestureRecognizer))
                """
            )
            return false
        }

        if gestureRecognizer === doubleClickGestureRecognizer {
            return webView._impl()?.allowsMagnification() ?? false
        }

        // Live Text (see the Image Analysis design note): the preflight is a passive observer and is only
        // enabled when Live Text is available, so it's always allowed to begin to measure the press.
        if gestureRecognizer === imageAnalysisGestureRecognizer {
            return true
        }

        if gestureRecognizer === domDoubleClickGestureRecognizer {
            return true
        }

        if gestureRecognizer === secondaryClickGestureRecognizer {
            return secondaryClickShouldBegin(at: locationInViewCoordinates)
        }

        if gestureRecognizer === dragPressGestureRecognizer {
            return dragPressShouldBegin(at: locationInViewCoordinates)
        }

        if gestureRecognizer === panGestureRecognizer {
            return panShouldBegin(at: locationInViewCoordinates)
        }

        if gestureRecognizer === singleClickGestureRecognizer {
            guard let impl = webView._impl() else {
                return false
            }
            return !impl.isTextSelectedAtPoint(locationInViewCoordinates)
        }

        if let mouseTrackingGesture = gestureRecognizer as? WKMouseTrackingGestureRecognizer {
            if !mouseTrackingGestureRecognizerCanTrack(mouseTrackingGesture) {
                Logger.viewGestures.debug(
                    """
                    [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                    Denying mouse tracking gesture: \(Self.loggingDescription(for: gestureRecognizer))
                    """
                )
                return false
            }
            guard let impl = webView._impl() else {
                return false
            }
            return !impl.isTextSelectedAtPoint(locationInViewCoordinates)
        }

        return true
    }

    @nonobjc
    private final func isOurManipulationGestureRecognizer(_ gesture: NSGestureRecognizer) -> Bool {
        gesture === panGestureRecognizer || gesture === magnificationGestureRecognizer || gesture === rotationGestureRecognizer
    }

    @nonobjc
    private final func isSomeManipulationGestureRecognizer(_ gesture: NSGestureRecognizer) -> Bool {
        isOurManipulationGestureRecognizer(gesture)
            || isBuiltInScrollViewPanGestureRecognizer(gesture)
            || isBuiltInScrollViewMagnificationGestureRecognizer(gesture)
    }

    @objc(_gestureRecognizer:canPreventGestureRecognizer:)
    private func gestureRecognizer(
        _ preventingGestureRecognizer: NSGestureRecognizer,
        canPrevent preventedGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        guard let webView = view else {
            return false
        }

        Logger.viewGestures.debug(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Preventing gesture: \(Self.loggingDescription(for: preventingGestureRecognizer)), Prevented gesture: \
            \(Self.loggingDescription(for: preventedGestureRecognizer))
            """
        )

        // None of our gesture recognizers may prevent an enclosing scroll view's pan (or any other
        // scroll/zoom) gesture, so that a scroll can always be handed off to the enclosing scroll view
        // e.g. a scroll over a draggable <img> in a non-scrollable web view.
        if isSomeManipulationGestureRecognizer(preventedGestureRecognizer) {
            return false
        }

        // Live Text (see the Image Analysis design note): the preflight is a passive observer, so it prevents
        // nothing.
        if preventingGestureRecognizer === imageAnalysisGestureRecognizer {
            return false
        }

        if preventingGestureRecognizer === pointerTrackingGestureRecognizer
            || preventedGestureRecognizer === pointerTrackingGestureRecognizer
        {
            return false
        }

        if preventingGestureRecognizer === domDoubleClickGestureRecognizer || preventedGestureRecognizer === domDoubleClickGestureRecognizer
        {
            return false
        }

        // Live Text: when the fallback deferral recognizes to block drag / context menu (text found), it must
        // only affect the drag-press and secondary-click recognizers it defers -- never the text-selection
        // gestures, which Live Text needs to proceed. (Its hold over drag-press / secondary-click is enforced
        // by the deferral failure-requirement, not by this prevention hook.)
        if preventingGestureRecognizer === imageAnalysisDragAndContextMenuDeferringGestureRecognizer {
            return preventedGestureRecognizer === dragPressGestureRecognizer
                || preventedGestureRecognizer === secondaryClickGestureRecognizer
        }

        let isOurClickGesture =
            preventingGestureRecognizer === singleClickGestureRecognizer
            || preventingGestureRecognizer === secondaryClickGestureRecognizer
            || isMouseTrackingGestureRecognizer(preventingGestureRecognizer)
            || preventingGestureRecognizer === dragPressGestureRecognizer

        if !isOurClickGesture {
            return true
        }

        // Don't let other click gestures prevent the secondary click GR; it must be allowed to fire its
        // press timer (0.72s) without being short-circuited by gestures that recognize earlier
        // (e.g. single click and mouse-tracking, which both transition to Began at mouse-down).
        if preventedGestureRecognizer === secondaryClickGestureRecognizer {
            return false
        }

        // Don't let our click gestures prevent text selection manager gestures;
        // they should be allowed to recognize simultaneously (per shouldRecognizeSimultaneouslyWithGestureRecognizer:).
        if Self.isTextSelectionGesture(preventedGestureRecognizer, of: webView) {
            return false
        }

        return true
    }
}

@objc(WKPointerTrackingGestureRecognizerDelegate)
@implementation
extension WKAppKitGestureController {
    @objc(pointerTrackingGestureRecognizer:didUpdateTouchWithState:locationInWindow:modifierFlags:)
    func pointerTrackingGestureRecognizer(
        _ gestureRecognizer: WKPointerTrackingGestureRecognizer,
        didUpdateTouchWith state: NSGestureRecognizer.State,
        locationInWindow: NSPoint,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let webView = view else {
            return
        }

        Logger.viewGestures.debug(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            \(Self.loggingDescription(for: gestureRecognizer)) touch state \
            \(state.name) at \(NSStringFromPoint(locationInWindow))
            """
        )

        switch state {
        case .began:
            cancelPointerTrackingIfNeeded()

            if webView._impl()?.ignoresAllEvents() ?? true {
                break
            }

            let locationInView = webView.convert(locationInWindow, from: nil)
            if !pointerTrackingShouldBegin(at: locationInView, modifierFlags: modifierFlags) {
                // The page must not treat the click that follows as the release of the last tracked touch.
                if isHoverActivatedByClick(at: locationInView) {
                    dispatchTrackedPointerEvent(
                        .Cancelled,
                        atLocationInWindow: locationInWindow,
                        modifierFlags: modifierFlags
                    )
                }
                break
            }

            isTrackingPointer = true
            trackedPointerHasMoved = false
            trackedPointerStartLocationInWindow = locationInWindow
            trackedPointerLastLocationInWindow = locationInWindow
            dispatchTrackedPointerEvent(.Began, atLocationInWindow: locationInWindow, modifierFlags: modifierFlags)

        case .changed:
            guard isTrackingPointer else {
                break
            }

            trackedPointerLastLocationInWindow = locationInWindow

            // Report no movement until the touch has moved too far to be a tap, so that a
            // touch that is held still reads as still.
            if !trackedPointerHasMoved {
                let movementInWindow = NSSize(
                    width: locationInWindow.x - trackedPointerStartLocationInWindow.x,
                    height: locationInWindow.y - trackedPointerStartLocationInWindow.y
                )
                guard movementExceedsClickAllowableMovement(movementInWindow) else {
                    break
                }
                trackedPointerHasMoved = true
            }

            dispatchTrackedPointerEvent(.Changed, atLocationInWindow: locationInWindow, modifierFlags: modifierFlags)

        case .ended:
            guard isTrackingPointer else {
                break
            }
            isTrackingPointer = false

            dispatchTrackedPointerEvent(
                .Ended,
                atLocationInWindow: trackedPointerHasMoved ? locationInWindow : trackedPointerStartLocationInWindow,
                modifierFlags: modifierFlags
            )

        case .cancelled:
            cancelPointerTrackingIfNeeded()

        default:
            break
        }
    }
}

@objc(WKPressGestureRecognizerDelegate)
@implementation
extension WKAppKitGestureController {
    func pressGestureRecognizerDidFail(_ gestureRecognizer: WKPressGestureRecognizer) {
        guard gestureRecognizer === imageAnalysisGestureRecognizer else {
            return
        }

        // Similar to iOS's -imageAnalysisGestureDidFail: if the initial gesture fails, resolve our deferrals immediately.
        if imageAnalysisDeferralState != .deferring {
            imageAnalysisDeferralState = .gestureFailed
            return
        }

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            Image analysis preflight failed; releasing image-analysis deferrals
            """
        )

        resolveImageAnalysisDeferrals(with: .notApplicable)
    }
}

@objc(WKClickHighlightControllerDelegate)
@implementation
extension WKAppKitGestureController {
    func clickHighlightController(_ controller: WKClickHighlightController, installHighlightView highlightView: WKClickHighlightView) {
        view?._impl()?.installClickHighlightView(highlightView)
    }

    func clickHighlightControllerContentScale(_ controller: WKClickHighlightController) -> CGFloat {
        // The highlighted quads are already in view coordinates.
        1
    }

    func clickHighlightControllerCornerRadiusScale(_ controller: WKClickHighlightController) -> CGFloat {
        guard let page = view?._protectedPage().get() else {
            return 1
        }

        return page.pageScaleFactor() * page.viewScaleFactor()
    }

    func clickHighlightControllerUnobscuredRect(_ controller: WKClickHighlightController) -> CGRect {
        guard let webView = view else {
            return .zero
        }

        var unobscuredRect = WebCore.FloatRect(webView.bounds)
        if let page = webView._protectedPage().get() {
            unobscuredRect.contract(page.obscuredContentInsets)
        }
        return CGRect(unobscuredRect)
    }

    func clickHighlightControllerBoundaryRect(_ controller: WKClickHighlightController) -> CGRect {
        clickHighlightControllerUnobscuredRect(controller)
    }

    func clickHighlightControllerIsPotentialTapInProgress(_ controller: WKClickHighlightController) -> Bool {
        isPotentialTapInProgress
    }
}

@objc(MomentumEventGeneration)
@implementation
extension WKAppKitGestureController {
    func generatedMomentumDidEnd() {
        isMomentumActive = false

        // Only the delta suppression is tied to momentum: once it has stopped, continuing to
        // zero deltas stops top scroll stretching from engaging.
        //
        // Whether the interaction caught a decelerating scroll is a property of the gesture
        // (and not the momentum). Clearing it here lets the scroll interrupt click through.
        // Instead, we should let the gesture end paths own/reset it instead.
        suppressNextPanScrollDelta = false
    }
}

@objc(WKDeferringGestureRecognizerDelegate)
@implementation
extension WKAppKitGestureController {
    @objc(deferringGestureRecognizer:shouldDeferOtherGestureRecognizer:)
    func deferringGestureRecognizer(
        _ deferringGestureRecognizer: WKDeferringGestureRecognizer,
        shouldDeferOtherGestureRecognizer gestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        guard let webView = view else {
            return false
        }

        // Live Text (see the Image Analysis design note): the fallback deferral holds the drag-press /
        // secondary-click recognizers -- not text selection -- until analysis resolves, so a slow analysis
        // can't let drag-press fire and drag the image before Live Text has a chance to win.
        if deferringGestureRecognizer === imageAnalysisDragAndContextMenuDeferringGestureRecognizer {
            return gestureRecognizer === dragPressGestureRecognizer || gestureRecognizer === secondaryClickGestureRecognizer
        }

        // Defer panning any scroll view that encloses the web view so that we can delegate to direct-manipulation elements if needed.
        if deferringGestureRecognizer === enclosingScrollViewPanDeferringGestureRecognizer {
            if !isBuiltInScrollViewPanGestureRecognizer(gestureRecognizer) {
                return false
            }

            guard let scrollView = gestureRecognizer.view as? NSScrollView else {
                return false
            }
            return webView.isDescendant(of: scrollView)
        }

        return Self.isTextSelectionGesture(gestureRecognizer, of: webView)
    }

    @objc(deferringGestureRecognizer:shouldDeferGesturesForEventThatWillBeginTouches:)
    func deferringGestureRecognizer(
        _ deferringGestureRecognizer: WKDeferringGestureRecognizer,
        shouldDeferGesturesForEventThatWillBeginTouches event: NSEvent
    ) -> Bool {
        guard let webView = view else {
            return false
        }

        if deferringGestureRecognizer === imageAnalysisTextSelectionDeferringGestureRecognizer
            || deferringGestureRecognizer === imageAnalysisDragAndContextMenuDeferringGestureRecognizer
        {
            imageAnalysisDeferralState = .undecided
        }

        if deferringGestureRecognizer === enclosingScrollViewPanDeferringGestureRecognizer {
            if webView.enclosingScrollView == nil || !(webView._protectedPage().get()?.hasRunningProcess() ?? false) {
                return false
            }

            if caughtDeceleratingScroll {
                return false
            }
        }

        // An event that catches a decelerating scroll only stops the scroll (and may continue it as a new pan),
        // so it must never begin a text selection or any other deferred gesture, no matter how long it's held
        // before moving.
        if caughtDeceleratingScroll {
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                deferral resolved: event caught a decelerating scroll; preventing deferred gestures
                """
            )
            deferringGestureRecognizer.endDeferralShouldPreventGestures(true)
            return true
        }

        let locationInView = webView.convert(event.locationInWindow, from: nil)

        let isInScrollbar = isPointInScrollbar(locationInView)

        if !isInScrollbar && (webView._impl()?.isTextSelectedAtPoint(locationInView) ?? false) {
            Logger.viewGestures.debug(
                """
                [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                deferral: not deferring; text already selected at \(NSStringFromPoint(locationInView))
                """
            )
            return false
        }

        // This deferral waits on the page's reply to the pointerdown and not on position
        // information, so there is only something to wait for if pointer tracking will begin.
        if deferringGestureRecognizer === pointerDownDeferringGestureRecognizer {
            return pointerTrackingShouldBegin(at: locationInView, modifierFlags: event.modifierFlags)
        }

        Logger.viewGestures.debug(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            deferral: deferring; awaiting position info at \(NSStringFromPoint(locationInView))
            """
        )

        let request = positionInformationRequest(at: locationInView)
        support.doAfterPositionInformationUpdate(request) { [weak self, weak deferringGestureRecognizer] info in
            guard let self, let deferringGestureRecognizer else {
                return
            }

            guard let info = info.value else {
                if deferringGestureRecognizer === self.enclosingScrollViewPanDeferringGestureRecognizer
                    && deferringGestureRecognizer.state == .possible
                {
                    deferringGestureRecognizer.endDeferralShouldPreventGestures(false)
                }
                return
            }

            guard self.view != nil else {
                return
            }

            let deferralState = deferringGestureRecognizer.state
            if deferralState != .possible {
                Logger.viewGestures.debug(
                    """
                    [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
                    deferral: position info arrived after deferring gesture exited Possible (state=\(deferralState.rawValue)); \
                    skipping resolution
                    """
                )
                return
            }

            let shouldPreventGestures = self.shouldPreventGestures(
                deferredBy: deferringGestureRecognizer,
                info: info,
                isInScrollbar: isInScrollbar
            )

            if let shouldPreventGestures {
                deferringGestureRecognizer.endDeferralShouldPreventGestures(shouldPreventGestures)
            }
        }

        return true
    }

    @objc(deferringGestureRecognizer:didEndTouchesWithEvent:)
    func deferringGestureRecognizer(_ deferringGestureRecognizer: WKDeferringGestureRecognizer, didEndTouchesWith event: NSEvent) {
        guard deferringGestureRecognizer.state == .possible else {
            return
        }

        Logger.viewGestures.log(
            """
            [pageProxyID=\(self.pageLogIdentifier)] \(#function): \
            deferral: touch ended before position info arrived; unblocking text selection
            """
        )

        if deferringGestureRecognizer !== pointerDownDeferringGestureRecognizer {
            support.abandonPositionInformationRequest()
        }

        deferringGestureRecognizer.endDeferralShouldPreventGestures(false)
    }

    @objc(deferringGestureRecognizer:didTransitionToState:)
    func deferringGestureRecognizer(
        _ deferringGestureRecognizer: WKDeferringGestureRecognizer,
        didTransitionTo state: NSGestureRecognizer.State
    ) {
    }
}

extension WebKit.WebPageProxy {
    // A copy of the insets: obscuredContentInsets() returns a reference into the page's internals, which live as
    // long as the page, and the page is held for the duration of this call.
    fileprivate var obscuredContentInsets: WebCore.FloatBoxExtent {
        unsafe __obscuredContentInsetsUnsafe().pointee
    }
}

extension NSGestureRecognizer.State {
    fileprivate var name: String {
        switch self {
        case .possible: "Possible"
        case .began: "Began"
        case .changed: "Changed"
        case .ended: "Ended"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        @unknown default: "Unknown(\(rawValue))"
        }
    }
}

#endif // HAVE_APPKIT_GESTURES_SUPPORT
