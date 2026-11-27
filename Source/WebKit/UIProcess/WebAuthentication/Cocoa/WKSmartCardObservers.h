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

#if ENABLE(WEB_AUTHN)

#import <Foundation/Foundation.h>

// Key-value observers of CryptoTokenKit objects. They are declared here rather than in the files that create them so
// that Swift can implement them; each selector takes only what Swift can implement.

@class TKSmartCard;
@class TKSmartCardSlot;

namespace WebKit {
class CcidService;
}

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// Calls the handler once, on the main run loop, when the card becomes invalid.
@interface WKSmartCardObserver : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCard:(TKSmartCard *)card invalidationHandler:(NS_SWIFT_SENDABLE void (^)(void))handler NS_DESIGNATED_INITIALIZER;
@end

// Observes TKSmartCardSlotManager's slotNames and gives the new list to the service on the main run loop.
@interface _WKSmartCardSlotObserver : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithService:(WebKit::CcidService&)service NS_DESIGNATED_INITIALIZER;
@end

// Observes one slot's state; the service learns of a valid card or of its removal on the main run loop.
@interface _WKSmartCardSlotStateObserver : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithService:(WebKit::CcidService&)service slot:(nullable TKSmartCardSlot *)slot NS_DESIGNATED_INITIALIZER;
- (void)removeObserver;
@end

NS_HEADER_AUDIT_END(nullability, sendability)

#endif // ENABLE(WEB_AUTHN)
