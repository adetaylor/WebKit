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

#import <Platform/Logging.h>
#import <Shared/SessionState.h>
#import <Shared/WebBackForwardListItem.h>
#import <UIProcess/WebBackForwardCache.h>
#import <UIProcess/WebFrameProxy.h>
#import <UIProcess/WebPageProxy.h>
#import <UIProcess/WebProcessProxy.h>
#import <wtf/Markable.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

// Workaround for rdar://162358154
using VectorAPIObject = Vector<RefPtr<API::Object>>;
using VectorRefWebBackForwardListItem = Vector<Ref<WebKit::WebBackForwardListItem>>;
using RefWebBackForwardListItem = Ref<WebKit::WebBackForwardListItem>;
using RefFrameState = Ref<WebKit::FrameState>;
using RefPtrFrameState = RefPtr<WebKit::FrameState>;
using RefPtrAPIObject = RefPtr<API::Object>;
using VectorRefFrameState = Vector<Ref<WebKit::FrameState>>;
using WeakPtrWebPageProxy = WeakPtr<WebKit::WebPageProxy>;
using SpanConstChar = std::span<const char>;
using MarkableBackForwardItemIdentifier = WTF::Markable<WebCore::BackForwardItemIdentifier>;
using MarkableBackForwardFrameItemIdentifier = WTF::Markable<WebCore::BackForwardFrameItemIdentifier>;

// Workaround for rdar://159211965 where SPI causes problems
// in implementing Equatable (otherwise we could use a Swift-side typealias.)
using BackForwardItemIdentifier = WebCore::BackForwardItemIdentifier;

// Swift does not understand full preprocessor macros such as LOG. In due course we
// will need to expose an equivalent of our WTF logging system to Swift, but for now,
// we'll have a single special-purpose equivalent.
// Swift does not yet support calling variadic C++ functions, so to avoid the cost of
// string interpolation when logging is disabled, such Swift log items will be constructed
// in a closure depending on whether logging is enabled.
inline bool willLog() {
    // TODO enable in due course
    // return WTFWillLogWithLevel(&WebKit2LogBackForward, WTFLogLevel::Always);
    return true;
}

// Our logging macro system does not work nicely under Swift, probably because Swift uses
// clang modules.
extern "C" {
    extern WTFLogChannel WebKit2LogBackForward;
    extern WTFLogChannel WebKit2LogLoading;
}

inline void doLog(const char* _Nonnull msg) {
    LOG(BackForward, "%s", msg);
    // The LOG macro does not work, possibly because of clang modules.
    // Should expand to:
    // if (WebKit2LogBackForward.state != logChannelStateOff)
    //     WTFLog(&WebKit2LogBackForward, "%s", msg);
}

inline void doLoadingReleaseLog(const char* _Nonnull msg) {
    RELEASE_LOG(Loading, "%s", msg);
}

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

// Workaround for rdar://162361370
// (storing a WTF::Function inside a copyable, in this case ref-counted, type)
template<typename> class FunctionContainer;

template <typename Out, typename... In>
class FunctionContainer<Out(In...)>: public RefCounted<FunctionContainer<Out(In...)>> {
public:
    static Ref<FunctionContainer<Out(In...)>> create(WTF::Function<Out(In...)>&& fn) {
        return adoptRef(*new FunctionContainer(WTFMove(fn)));
    }

    Out call(In... in) const
    {
        return m_fn(std::forward<In>(in)...);
    }
    void ref() { WTF::ref(this); }
    void deref() { WTF::deref(this); }

private:
    FunctionContainer(WTF::Function<Out(In...)>&& fn) : m_fn(WTFMove(fn)) {}
    WTF::Function<Out(In...)> m_fn;
    // The following line requires rdar://160696723, so if it doesn't build,
    // you're probably not using a sufficiently recent swiftc.
} SWIFT_SHARED_REFERENCE(.ref, .deref);

using WebBackForwardListItemFilter = FunctionContainer<bool (WebKit::WebBackForwardListItem&)>;
using CountsCompletionHandler = FunctionContainer<void(WebKit::WebBackForwardListCounts&&)>;
using ConstCountsCompletionHandler = FunctionContainer<void(const WebKit::WebBackForwardListCounts&)>;
using BoolCompletionHandler = FunctionContainer<void(bool)>;
using VectorRefFrameStateCompletionHandler = FunctionContainer<void(Vector<Ref<WebKit::FrameState>>&&)>;
using RefPtrFrameStateCompletionHandler = FunctionContainer<void(RefPtr<WebKit::FrameState>&&)>;
