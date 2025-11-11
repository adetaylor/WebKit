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

#pragma once

#import <Platform/IPC/Connection.h>
#import <Platform/Logging.h>
#import <Shared/SessionState.h>
#import <Shared/WebBackForwardListItem.h>
#import <UIProcess/WebBackForwardCache.h>
#import <UIProcess/WebFrameProxy.h>
#import <UIProcess/WebPageProxy.h>
#import <UIProcess/WebProcessProxy.h>
#import <wtf/Markable.h>
#import <wtf/RefCounted.h>
#import <wtf/SwiftBridging.h>
#import <wtf/SwiftWrappedFunction.h>
#import <wtf/SwiftWrappedCompletionHandler.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>
#import <MessageReceiver.h>
#import <WebBackForwardListMessages.h>

// Workaround for rdar://162358154
using VectorAPIObject = Vector<RefPtr<API::Object>>;
using VectorRefWebBackForwardListItem = Vector<Ref<WebKit::WebBackForwardListItem>>;
using RefWebBackForwardListItem = Ref<WebKit::WebBackForwardListItem>;
using RefFrameState = Ref<WebKit::FrameState>;
using RefPtrFrameState = RefPtr<WebKit::FrameState>;
using RefPtrAPIObject = RefPtr<API::Object>;
using RefWebProcessProxy = Ref<WebKit::WebProcessProxy>;
using VectorRefFrameState = Vector<Ref<WebKit::FrameState>>;
using WeakPtrWebPageProxy = WeakPtr<WebKit::WebPageProxy>;
using SpanConstChar = std::span<const char>;
using MarkableBackForwardItemIdentifier = WTF::Markable<WebCore::BackForwardItemIdentifier>;
using MarkableBackForwardFrameItemIdentifier = WTF::Markable<WebCore::BackForwardFrameItemIdentifier>;

inline void messageCheckFailed(Ref<WebKit::WebProcessProxy> process) {
    MESSAGE_CHECK_BASE(false, process->connection());
}

// Workaround for rdar://159211965 where SPI causes problems
// in implementing Equatable (otherwise we could use a Swift-side typealias.)
using BackForwardItemIdentifier = WebCore::BackForwardItemIdentifier;

// These can't be inline due to rdar://162531519
void doLog(const char* _Nonnull msg);
void doLoadingReleaseLog(const char* _Nonnull msg);
inline bool willLog() { return true; } // TODO - expose suitable API from WTF

// Workaround for rdar://85881664
inline API::Object* _Nonnull toAPIObject(WebKit::WebBackForwardListItem* _Nonnull item) {
    return item;
}

// Workaround for rdar://130765784
inline bool identitiesMatch(const WebKit::WebBackForwardListItem* _Nullable lhs, const WebKit::WebBackForwardListItem* _Nullable rhs) {
    return lhs == rhs;
}

// Workaround for rdar://162357139
template<typename T>
inline bool contentsMatch(const T& lhs, const T& rhs) {
    return lhs == rhs;
}

// Workaround for rdar://162519380
inline RefPtr<WebKit::WebProcessProxy> downcastToWebProcessProxy(WebKit::AuxiliaryProcessProxy* _Nonnull app) {
    return downcast<WebKit::WebProcessProxy>(app);
}

// Workaround for rdar://162193891
WebCore::BackForwardFrameItemIdentifier generateBackForwardFrameItemIdentifier();
WebCore::BackForwardItemIdentifier generateBackForwardItemIdentifier();

using WebBackForwardListItemFilter = WTF::SwiftWrappedFunction<bool (WebKit::WebBackForwardListItem&)>;
using CountsCompletionHandler = WTF::SwiftWrappedCompletionHandler<void(WebKit::WebBackForwardListCounts&&)>;
using ConstCountsCompletionHandler = WTF::SwiftWrappedCompletionHandler<void(const WebKit::WebBackForwardListCounts&)>;
using BoolCompletionHandler = WTF::SwiftWrappedCompletionHandler<void(bool)>;
using VectorRefFrameStateCompletionHandler = WTF::SwiftWrappedCompletionHandler<void(Vector<Ref<WebKit::FrameState>>&&)>;
using RefPtrFrameStateCompletionHandler = WTF::SwiftWrappedCompletionHandler<void(RefPtr<WebKit::FrameState>&&)>;

class WebBackForwardListMessageForwarder;
using RefWebBackForwardListMessageForwarder = WTF::Ref<WebKit::WebBackForwardListMessageForwarder>;
