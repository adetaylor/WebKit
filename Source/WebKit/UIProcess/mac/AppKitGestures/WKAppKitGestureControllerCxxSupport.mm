/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

#import "config.h"
#import "WKAppKitGestureControllerCxxSupport.h"

#if HAVE(APPKIT_GESTURES_SUPPORT)

#import "DrawingAreaProxy.h"
#import "ImageAnalysisUtilities.h"
#import "InteractionInformationAtPosition.h"
#import "InteractionInformationRequest.h"
#import "MomentumEventDispatcher.h"
#import "NativeWebWheelEvent.h"
#import "RemoteLayerTreeDrawingAreaProxy.h"
#import "RemoteScrollingTreeCocoa.h"
#import "ScrollingAccelerationCurve.h"
#import "TextRecognitionUpdateResult.h"
#import "WKWebView.h"
#import "WKWebViewInternal.h"
#import "WebEventFactory.h"
#import "WebEventType.h"
#import "WebPageProxy.h"
#import "WebViewImpl.h"
#import "WebWheelEvent.h"
#import <QuartzCore/CADisplayLink.h>
#import <WebCore/ElementContext.h>
#import <WebCore/EventRegion.h>
#import <WebCore/FloatPoint.h>
#import <WebCore/FloatSize.h>
#import <WebCore/IntPoint.h>
#import <WebCore/TextRecognitionResult.h>
#import <wtf/BlockPtr.h>
#import <wtf/CheckedPtr.h>
#import <wtf/Markable.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/WeakObjCPtr.h>

static WebCore::FloatSize toRawPlatformDelta(WebCore::FloatSize delta)
{
    // rawPlatformDelta uses IOHIDEvent coordinate conventions, which have the opposite
    // sign from WebKit's delta field. This matches WebEventFactory.mm which negates
    // IOHIDEventFieldScrollX/Y values when extracting rawPlatformDelta from real events.
    return -delta;
}

static bool isAnalyzableImageForLiveText(const WebKit::InteractionInformationAtPosition& info)
{
    return info.isImage && info.image && info.hostImageOrVideoElementContext && !info.isAnimatedImage && !info.isContentEditable;
}

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)

namespace WebKit {
class AppKitGestureMomentumEventGenerator;
}

@interface WKAppKitGestureMomentumDisplayLinkTarget : NSObject
- (instancetype)initWithGenerator:(WebKit::AppKitGestureMomentumEventGenerator&)generator;
- (void)invalidate;
- (void)displayLinkFired:(CADisplayLink *)displayLink;
@end

namespace WebKit {

class AppKitGestureMomentumEventGenerator final : public MomentumEventDispatcher::Client {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(AppKitGestureMomentumEventGenerator);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(AppKitGestureMomentumEventGenerator);
public:
    explicit AppKitGestureMomentumEventGenerator(WKAppKitGestureController *controller)
        : m_controller(controller)
        , m_dispatcher(makeUnique<MomentumEventDispatcher>(*this))
    {
    }

    bool isActive() const { return m_isActive; }

    void start(WebPageProxy& page, const NativeWebWheelEvent& event)
    {
        ASSERT(event.momentumPhase() == WebWheelEvent::Phase::Began);

        interrupt();

        m_pageIdentifier = page.webPageIDInMainFrameProcess();
        m_displayID = page.displayID().value_or(0);

        auto curve = ScrollingAccelerationCurve::fromNativeWheelEvent(event).or_else([] {
            return ScrollingAccelerationCurve::fallbackCurve();
        });
        m_dispatcher->setScrollingAccelerationCurve(*m_pageIdentifier, WTF::move(curve));

        RefPtr drawingArea = page.drawingArea();
        m_dispatcher->pageScreenDidChange(*m_pageIdentifier, m_displayID, drawingArea ? drawingArea->displayNominalFramesPerSecond() : std::nullopt);

        m_dispatcher->handleWheelEvent(*m_pageIdentifier, event, { });
    }

    void interrupt()
    {
        if (!m_isActive)
            return;

        auto timestamp = MonotonicTime::now();
        Ref event = WebWheelEvent::create({ WebEventType::Wheel, { }, timestamp }, {
            .granularity = WebWheelEvent::Granularity::ScrollByPixelWheelEvent,
            .directionInvertedFromDevice = false,
            .phase = WebWheelEvent::Phase::Cancelled,
            .momentumPhase = WebWheelEvent::Phase::None,
            .hasPreciseScrollingDeltas = true,
            .scrollCount = 1,
            .ioHIDEventTimestamp = timestamp,
            .rawPlatformDelta = std::nullopt,
            .momentumEndType = WebWheelEvent::MomentumEndType::Interrupted,
            .inputSource = WebEventInputSource::Touch,
        });
        m_dispatcher->handleWheelEvent(*m_pageIdentifier, event, { });
        ASSERT(!m_isActive);
    }

    void displayDidRefresh()
    {
        m_dispatcher->displayDidRefresh(m_displayID);
    }

private:
    void handleSyntheticWheelEvent(WebCore::PageIdentifier, const WebWheelEvent& event, WebCore::RectEdges<WebCore::RubberBandingBehavior>) final
    {
        // The controller sends the momentum Began event itself, since the scrolling thread needs its
        // rawPlatformDelta to start its own curve.
        if (event.momentumPhase() == WebWheelEvent::Phase::Began)
            return;

        RetainPtr webView = [m_controller.get() webView];
        if (!webView)
            return;

        [webView _protectedPage]->handleNativeWheelEvent(NativeWebWheelEvent::create(event));
    }

    void startDisplayDidRefreshCallbacks(WebCore::PlatformDisplayID) final
    {
        m_isActive = true;

        RetainPtr webView = [m_controller.get() webView];
        if (!webView || m_displayLink)
            return;

        m_displayLinkTarget = adoptNS([[WKAppKitGestureMomentumDisplayLinkTarget alloc] initWithGenerator:*this]);
        m_displayLink = [webView displayLinkWithTarget:m_displayLinkTarget.get() selector:@selector(displayLinkFired:)];
        [m_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }

    void stopDisplayDidRefreshCallbacks(WebCore::PlatformDisplayID) final
    {
        [std::exchange(m_displayLink, nil) invalidate];
        [std::exchange(m_displayLinkTarget, nil) invalidate];
    }

    void didEndSyntheticMomentumScrolling() final
    {
        m_isActive = false;
        RetainPtr controller = m_controller.get();
        [controller generatedMomentumDidEnd];
    }

#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)
    void flushMomentumEventLoggingSoon() final { }
#endif

    WeakObjCPtr<WKAppKitGestureController> m_controller;
    Markable<WebCore::PageIdentifier> m_pageIdentifier;
    WebCore::PlatformDisplayID m_displayID { 0 };
    bool m_isActive { false };
    RetainPtr<WKAppKitGestureMomentumDisplayLinkTarget> m_displayLinkTarget;
    RetainPtr<CADisplayLink> m_displayLink;
    const std::unique_ptr<MomentumEventDispatcher> m_dispatcher;
};

} // namespace WebKit

// The display link retains its target, so this keeps it from retaining the gesture controller.
@implementation WKAppKitGestureMomentumDisplayLinkTarget {
    CheckedPtr<WebKit::AppKitGestureMomentumEventGenerator> _generator;
}

- (instancetype)initWithGenerator:(WebKit::AppKitGestureMomentumEventGenerator&)generator
{
    if (!(self = [super init]))
        return nil;

    _generator = &generator;
    return self;
}

- (void)invalidate
{
    _generator = nullptr;
}

- (void)displayLinkFired:(CADisplayLink *)displayLink
{
    if (CheckedPtr generator = _generator)
        generator->displayDidRefresh();
}

@end

#endif // ENABLE(MOMENTUM_EVENT_DISPATCHER)

@implementation WKAppKitGestureControllerCxxSupport {
    WeakObjCPtr<WKAppKitGestureController> _controller;
    BlockPtr<void(WebKit::InteractionInformationAtPosition)> _positionInformationDidChangeHandler;
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    std::unique_ptr<WebKit::AppKitGestureMomentumEventGenerator> _momentumEventGenerator;
#endif
}

- (WKAppKitGestureController *)controller
{
    return _controller.getAutoreleased();
}

- (void)setController:(WKAppKitGestureController *)controller
{
    _controller = controller;
}

- (void)setPositionInformationDidChangeHandler:(void (^)(WebKit::InteractionInformationAtPosition))handler
{
    _positionInformationDidChangeHandler = makeBlockPtr(handler);
}

- (void)positionInformationDidChange:(const WebKit::InteractionInformationAtPosition&)info
{
    // Resolving queued callbacks can re-enter into client code (e.g. UI delegate callbacks), which
    // may release the WKWebView and tear the controller down before the handler returns.
    RetainPtr protectedController = _controller.get();
    // The handler stays alive until it returns, even if it is replaced while it runs.
    auto handler = _positionInformationDidChangeHandler;
    RELEASE_ASSERT(handler);
    handler(info);
}

- (void)preflightImageAnalysis:(WebKit::InteractionInformationAtPosition)info completion:(void (^)(BOOL foundText, WebCore::ElementContext element))completion
{
    RetainPtr webView = [_controller.get() webView];
    if (!webView)
        return;

    if (!isAnalyzableImageForLiveText(info)) {
        // Not an analyzable image: leave both image-analysis deferrals with the default
        // NotApplicable outcome, so text selection and the drag / context-menu fallback each
        // resolve on their own (non-image) merits.
        return;
    }

    // This dereference is guaranteed to be non-nil due to the `isAnalyzableImageForLiveText` check above.
    const auto elementContext = *info.hostImageOrVideoElementContext;

    // This dereference is guaranteed to be non-nil due to the `isAnalyzableImageForLiveText` check above.
    RetainPtr cgImage = info.image->createPlatformImage();
    if (!cgImage) {
        // An image we can't rasterize: treat it as an image without text so the press falls
        // through to drag / context menu.
        completion(NO, elementContext);
        return;
    }

    RELEASE_LOG(ImageAnalysis, "Image analysis preflight gesture initiated.");

    const auto requestLocation = info.request.point;

    RetainPtr analyzerRequest = WebKit::createImageAnalyzerRequest(cgImage.get(), VKAnalysisTypeText);
    const auto startTime = MonotonicTime::now();
    protect([webView _impl])->processImageAnalyzerRequest(analyzerRequest.get(), [weakSelf = WeakObjCPtr<WKAppKitGestureControllerCxxSupport>(self), elementContext, requestLocation, completion = makeBlockPtr(completion), startTime](RetainPtr<VKCImageAnalysis>&& result, NSError *) mutable {
        RetainPtr strongSelf = weakSelf.get();
        if (!strongSelf)
            return;

        RetainPtr webView = [strongSelf->_controller.get() webView];
        if (!webView)
            return;

        auto hasTextResults = [result hasResultsForAnalysisTypes:VKAnalysisTypeText];
        RELEASE_LOG(ImageAnalysis, "Image analysis completed in %.0f ms (found text? %d)", (MonotonicTime::now() - startTime).milliseconds(), hasTextResults);

        [webView _protectedPage]->updateWithTextRecognitionResult(WebKit::makeTextRecognitionResult(result.get()), elementContext, requestLocation, [elementContext, completion = WTF::move(completion)](const auto& updateResult) mutable {
            // Text found and injected as an image overlay -> allow the deferred text selection and
            // prevent the drag / context-menu fallback (Live Text wins). Otherwise -> the reverse.
            completion(updateResult == WebKit::TextRecognitionUpdateResult::Text, elementContext);
        });
    });
}

- (uint8_t)touchActionsAtPoint:(NSPoint)point
{
    OptionSet<WebCore::TouchAction> defaultTouchActions { WebCore::TouchAction::Auto };

    RetainPtr webView = [_controller.get() webView];
    if (!webView)
        return defaultTouchActions.toRaw();

    RefPtr remoteDrawingArea = dynamicDowncast<WebKit::RemoteLayerTreeDrawingAreaProxy>([webView _protectedPage]->drawingArea());
    if (!remoteDrawingArea)
        return defaultTouchActions.toRaw();

    RetainPtr rootLayer = remoteDrawingArea->remoteLayerTreeHost().rootLayer();
    if (!rootLayer)
        return defaultTouchActions.toRaw();

    WebCore::FloatPoint location { point };
    return WebKit::eventRegionForPoint(rootLayer.get(), location).transform([&location](const WebCore::EventRegion& eventRegion) {
        return eventRegion.touchActionsForPoint(WebCore::roundedIntPoint(location));
    }).value_or(defaultTouchActions).toRaw();
}

- (WebKit::OptionalTransactionID)lastCommittedMainFrameLayerTreeTransactionID
{
    RetainPtr webView = [_controller.get() webView];
    if (!webView)
        return { };

    RefPtr drawingArea = [webView _protectedPage]->drawingArea();
    if (!drawingArea)
        return { };

    RefPtr remoteDrawingArea = dynamicDowncast<WebKit::RemoteLayerTreeDrawingAreaProxy>(*drawingArea);
    if (!remoteDrawingArea)
        return { };

    return remoteDrawingArea->lastCommittedMainFrameLayerTreeTransactionID();
}

- (void)doAfterProcessingAllPendingMouseEvents:(void (^)(void))completion
{
    RetainPtr webView = [_controller.get() webView];
    if (!webView)
        return;

    [webView _protectedPage]->doAfterProcessingAllPendingMouseEvents([completion = makeBlockPtr(completion)] {
        completion();
    });
}

- (void)startMomentumAtPosition:(NSPoint)positionValue globalPosition:(NSPoint)globalPositionValue timestamp:(double)rawTimestamp velocity:(NSSize)velocityValue fastScrollMultiplier:(double)fastScrollMultiplier
{
    RetainPtr webView = [_controller.get() webView];
    if (!webView)
        return;

    auto velocity = WebCore::FloatSize { velocityValue };
    auto timestamp = MonotonicTime::fromRawSeconds(rawTimestamp);
    WebCore::IntPoint position { positionValue };
    WebCore::IntPoint globalPosition { globalPositionValue };
    Ref momentumEvent = WebKit::WebWheelEvent::create({ WebKit::WebEventType::Wheel, { }, timestamp }, {
        .position = position,
        .globalPosition = globalPosition,
        .granularity = WebKit::WebWheelEvent::Granularity::ScrollByPixelWheelEvent,
        .directionInvertedFromDevice = false,
        .phase = WebKit::WebWheelEvent::Phase::None,
        .momentumPhase = WebKit::WebWheelEvent::Phase::Began,
        .hasPreciseScrollingDeltas = true,
        .scrollCount = 1,
        .ioHIDEventTimestamp = timestamp,
        .rawPlatformDelta = std::nullopt,
        .momentumEndType = WebKit::WebWheelEvent::MomentumEndType::Unknown,
        .inputSource = WebKit::WebEventInputSource::Touch,
        .momentumFastScrollMultiplier = static_cast<float>(fastScrollMultiplier),
    });
    Ref nativeMomentumEvent = WebKit::NativeWebWheelEvent::create(momentumEvent);

    nativeMomentumEvent->setRawPlatformDelta([&nativeMomentumEvent, velocity] {
        static constexpr WebCore::FramesPerSecond fallbackMomentumFrameRate { 60 };
        auto momentumFrameRate = WebKit::ScrollingAccelerationCurve::fromNativeWheelEvent(nativeMomentumEvent)
            .or_else([] {
                return WebKit::ScrollingAccelerationCurve::fallbackCurve();
            }).transform([](const auto& curve) {
                return curve.frameRate();
            }).value_or(fallbackMomentumFrameRate);
        auto initialMomentumDelta = velocity / momentumFrameRate;
        return toRawPlatformDelta(initialMomentumDelta);
    }());

#if HAVE(NSREFRESHCONTROLLER)
    // The refresh controller should not track synthetic momentum scrolling.
    protect([webView _impl])->clearRefreshControllerTracking();
#endif

    RefPtr page = [webView _protectedPage];
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    // Started first, so that any momentum it ends is ended before this momentum begins.
    if (!_momentumEventGenerator)
        _momentumEventGenerator = makeUnique<WebKit::AppKitGestureMomentumEventGenerator>(_controller.get());
    CheckedRef { *_momentumEventGenerator }->start(*page, nativeMomentumEvent);
#endif
    page->handleNativeWheelEvent(WTF::move(nativeMomentumEvent));
}

- (void)interruptMomentum
{
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    if (CheckedPtr generator = _momentumEventGenerator)
        generator->interrupt();
#endif
}

- (void)resetMomentum
{
#if ENABLE(MOMENTUM_EVENT_DISPATCHER)
    _momentumEventGenerator = nullptr;
#endif
}
@end

#endif // HAVE(APPKIT_GESTURES_SUPPORT)
