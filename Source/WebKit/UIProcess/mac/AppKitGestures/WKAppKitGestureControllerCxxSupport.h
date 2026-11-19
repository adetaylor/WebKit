/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#pragma once

#import <wtf/Platform.h>

#if HAVE(APPKIT_GESTURES_SUPPORT)

#import "InteractionInformationAtPosition.h"
#import "InteractionInformationRequest.h"
#import "TransactionID.h"
#import "WKAppKitGestureController.h"
#import "WKClickHighlightController.h"
#import "WKDeferringGestureRecognizer.h"
#import "WKPointerTrackingGestureRecognizer.h"
#import "WKPressGestureRecognizer.h"
#import <WebCore/ElementContext.h>
#import <WebCore/IntPoint.h>
#import <optional>

namespace WebKit {

using OptionalInteractionInformationAtPosition = std::optional<InteractionInformationAtPosition>;
using OptionalIntPoint = std::optional<WebCore::IntPoint>;
using OptionalTransactionID = std::optional<TransactionID>;

namespace CxxInteropSupport {

// ENABLE(MODEL_ELEMENT_STAGE_MODE) is an expression, which Swift's compilation conditions do not include.
inline bool isInteractiveModel(const InteractionInformationAtPosition& info)
{
#if ENABLE(MODEL_ELEMENT_STAGE_MODE)
    return info.isInteractiveModel;
#else
    UNUSED_PARAM(info);
    return false;
#endif
}

} // namespace CxxInteropSupport

} // namespace WebKit

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// The C++ that WKAppKitGestureController uses and Swift cannot call: its PositionInformationManager, the momentum
// event generator, Live Text's image analysis, and the page's drawing area.
NS_SWIFT_UI_ACTOR
@interface WKAppKitGestureControllerCxxSupport : NSObject

@property (nonatomic, weak, nullable) WKAppKitGestureController *controller;

// Position information, after -setUpPositionInformation. A completion runs exactly once: before the call returns when
// the current information answers the request, when the page's answer arrives, or with no information when the request
// is reset or abandoned or the manager goes away.
- (void)setUpPositionInformation;
- (void)doAfterPositionInformationUpdate:(WebKit::InteractionInformationRequest)request completion:(NS_SWIFT_UI_ACTOR void (^)(WebKit::OptionalInteractionInformationAtPosition info))completion NS_SWIFT_NAME(doAfterPositionInformationUpdate(_:completion:));
- (void)invalidatePositionInformation;
- (void)resetPositionInformation;
- (void)abandonPositionInformationRequest;
- (BOOL)positionInformationIsApproximatelyValid:(WebKit::InteractionInformationRequest)request radius:(int)radius;
@property (nonatomic, readonly) BOOL hasValidPositionInformation;
@property (nonatomic, readonly) WebKit::InteractionInformationAtPosition positionInformation;
@property (nonatomic, readonly) BOOL positionInformationIsHoverActivatedByClick;
@property (nonatomic, readonly) WebKit::OptionalIntPoint nearbySliderInteractionLocation;
#if !__has_feature(modules)
- (void)positionInformationDidChange:(const WebKit::InteractionInformationAtPosition&)info;
#endif

// Live Text. The completion is not called when the press is not over an image Live Text can analyze, or when the
// controller or its web view goes away first.
- (void)preflightImageAnalysis:(WebKit::InteractionInformationRequest)request completion:(NS_SWIFT_UI_ACTOR void (^)(BOOL foundText, WebCore::ElementContext element))completion;

// Momentum.
- (void)startMomentumAtPosition:(NSPoint)position globalPosition:(NSPoint)globalPosition timestamp:(double)timestamp velocity:(NSSize)velocity fastScrollMultiplier:(double)fastScrollMultiplier;
- (void)interruptMomentum;
- (void)resetMomentum;

// The page. doAfterProcessingAllPendingMouseEvents: drops its completion when the controller has no web view.
- (uint8_t)touchActionsAtPoint:(NSPoint)point;
@property (nonatomic, readonly) WebKit::OptionalTransactionID lastCommittedMainFrameLayerTreeTransactionID;
- (void)doAfterProcessingAllPendingMouseEvents:(NS_SWIFT_UI_ACTOR void (^)(void))completion NS_SWIFT_NAME(doAfterProcessingAllPendingMouseEvents(_:));

@end

@interface WKAppKitGestureController ()
@property (nonatomic, readonly) WKAppKitGestureControllerCxxSupport *cxxSupport;
@end

@interface WKAppKitGestureController (MomentumEventGeneration)
- (void)generatedMomentumDidEnd;
@end

@interface WKAppKitGestureController (WKClickHighlightControllerDelegate) <WKClickHighlightControllerDelegate>
@end

@interface WKAppKitGestureController (WKDeferringGestureRecognizerDelegate) <WKDeferringGestureRecognizerDelegate>
@end

@interface WKAppKitGestureController (WKPointerTrackingGestureRecognizerDelegate) <WKPointerTrackingGestureRecognizerDelegate>
@end

@interface WKAppKitGestureController (WKPressGestureRecognizerDelegate) <WKPressGestureRecognizerDelegate>
@end

NS_HEADER_AUDIT_END(nullability, sendability)

#endif // HAVE(APPKIT_GESTURES_SUPPORT)
