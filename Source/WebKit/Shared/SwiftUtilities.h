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

#import <WebKit/WebFrameProxy.h>
#import <wtf/Vector.h>
#import <optional>
#import <wtf/WeakPtr.h>
#import <Shared/SessionState.h>
#import <Shared/WebBackForwardListFrameItem.h>
#import <Shared/WebBackForwardListItem.h>
#import <UIProcess/WebBackForwardCache.h>
#import <UIProcess/WebPageProxy.h>
#import <UIProcess/WebPageProxyIdentifier.h>
#import <APIArray.h>
#import <wtf/Markable.h>
#import <Shared/WebBackForwardListItem.h>

// Types which Swift needs

// TODO: figure out the Swift limitation which prevents us using these generic
// types directly from Swift, and note the rdar.
using VectorAPIObject = Vector<RefPtr<API::Object>>;
using VectorRefBackForwardListItem = Vector<Ref<WebKit::WebBackForwardListItem>>;
using RefBackForwardListItem = Ref<WebKit::WebBackForwardListItem>;
using RefFrameState = Ref<WebKit::FrameState>;
using VectorRefFrameState = Vector<RefFrameState>;
using WeakPtrWebPageProxy = WeakPtr<WebKit::WebPageProxy>;
using SpanConstChar = std::span<const char>;
using MarkableBackForwardItemIdentifier = WTF::Markable<WebCore::BackForwardItemIdentifier>;
using MarkableBackForwardFrameItemIdentifier = WTF::Markable<WebCore::BackForwardFrameItemIdentifier>;

template<typename T>
Vector<RefPtr<API::Object>> toAPIObjectVector(const Vector<Ref<T>>& itemsVector)
{
    return itemsVector.map([](auto& menuItem) -> RefPtr<API::Object> {
        return menuItem.ptr();
    });
}

inline API::Object* _Nonnull toAPIObject(WebKit::WebBackForwardListItem* _Nonnull item) {
    return item;
}

// TODO wanted to make this available but cannot import a parameter of type swift::Array.
// File rdar?
// inline Vector<Ref<WebKit::WebBackForwardListItem>> toVector(const swift::Array<WebKit::WebBackForwardListItem* _Nonnull>& array) {

// TODO file a radar for the fact that Bool(fromCxx: someWeakPtr) does not work:
// error: initializer 'init(fromCxx:)' requires that 'WeakPtrWebPageProxy' (aka 'WTF.WeakPtr<WebKit.WebPageProxy, WTF.DefaultWeakPtrImpl, WTF.RawPtrTraits<WTF.DefaultWeakPtrImpl>>') conform to 'CxxConvertibleToBool'

// TODO it would be nice to use patterns like this, but we get
// "reference to var 'pageWeakPtrIsOccupied' is not concurrency-safe because it involves shared mutable state"

// template<typename T>
// bool weakPtrIsOccupied(const WTF::WeakPtr<T>& ptr) {
//     return static_cast<bool>(ptr);
// }

// inline auto pageWeakPtrIsOccupied = &weakPtrIsOccupied<WebKit::WebPageProxy>;

// TODO casting to Bool doesn't seem to work.
template<typename T>
inline bool operatorBool(const T& ptr) {
    return static_cast<bool>(ptr);
}

// TODO it would be nice to use patterns like this, but then the _Nullable
// annotations don't persist.
// TODO consider using macros yuck.

// template<typename T>
// T* _Nullable getWeakPtr(const WTF::WeakPtr<T>& ptr) {
//     return ptr.get();
// }

// inline auto getPageWeakPtr = &getWeakPtr<WebKit::WebPageProxy>;

// TODO this seems to give a WebPageProxy in Swift, not a WebPageProxy?. Why?
inline WebKit::WebPageProxy* _Nullable getPageWeakPtr(const WTF::WeakPtr<WebKit::WebPageProxy>& ptr) {
    // TODO think about if there's a window between the creation of a T* and its
    // Swift retain, during which its refcount could drop to 0 and cause UaF
    return ptr.get();
}

// TODO consider coming up with a reasonable naming convention for all these
inline RefPtr<API::Object> toRefPtrAPIObject(API::Object* _Nullable obj) {
    return obj;
}

// TODO initially it seemed as though Swift would be unwilling to call
// functions like all the following if they were generic, but I'm not so
// sure now. Try making generic equivalents to get rid of all this duplication.

inline Ref<WebKit::FrameState> toRefFrameState(WebKit::FrameState* _Nonnull obj) {
    return *obj;
}

inline Ref<WebKit::WebBackForwardListItem> toRefWebBackForwardListItem(WebKit::WebBackForwardListItem* _Nonnull obj) {
    return *obj;
}

// TODO think about if there's any window here during which these may be UaFed
inline WebKit::WebBackForwardListFrameItem* _Nonnull derefRefBackForwardListFrameItem(const WTF::Ref<WebKit::WebBackForwardListFrameItem>& ref) {
    return &ref.get();
}

inline WebKit::FrameState* _Nonnull derefRefFrameState(const WTF::Ref<WebKit::FrameState>& ref) {
    return &ref.get();
}

inline API::Array* _Nonnull derefRefAPIArray(const WTF::Ref<API::Array>& ref) {
    return &ref.get();
}

inline WebKit::WebBackForwardListFrameItem* _Nonnull derefRefWebBackForwardListFrameItem(const WTF::Ref<WebKit::WebBackForwardListFrameItem>& ref) {
    return &ref.get();
}

inline WebKit::WebBackForwardListItem* _Nonnull derefRefWebBackForwardListItem(const WTF::Ref<WebKit::WebBackForwardListItem>& ref) {
    return &ref.get();
}

inline WebKit::WebBackForwardCache* _Nonnull derefRefWebBackForwardCache(const WTF::Ref<WebKit::WebBackForwardCache>& ref) {
    return &ref.get();
}

inline WebKit::WebProcessProxy* _Nonnull derefRefWebProcessProxy(const WTF::Ref<WebKit::WebProcessProxy>& ref) {
    return &ref.get();
}

inline bool webPageProxyIdentifiersEquate(const WebKit::WebPageProxyIdentifier& lhs, const WebKit::WebPageProxyIdentifier& rhs) {
    return lhs == rhs;
}

// TODO - workaround for rdar://130765784
inline bool itemsMatch(const WebKit::WebBackForwardListItem* _Nullable lhs, const WebKit::WebBackForwardListItem* _Nullable rhs) {
    return lhs == rhs;
}

template<typename T>
inline bool contentsMatch(const T& lhs, const T& rhs) {
    return lhs == rhs;
}

// TODO Swift does not like std::optional of some types

inline Ref<WebKit::WebBackForwardListItem> createWebBackForwardListItemWithFrameID(Ref<WebKit::FrameState>&& frameState,
        WebKit::WebPageProxyIdentifier webPageProxyIdentifier, WebCore::FrameIdentifier frameIdentifier) {
    return WebKit::WebBackForwardListItem::create(WTFMove(frameState), webPageProxyIdentifier, frameIdentifier);
}

inline Ref<WebKit::WebBackForwardListItem> createWebBackForwardListItemWithoutFrameID(Ref<WebKit::FrameState>&& frameState,
        WebKit::WebPageProxyIdentifier webPageProxyIdentifier) {
    return WebKit::WebBackForwardListItem::create(WTFMove(frameState), webPageProxyIdentifier, std::nullopt);
}

inline WebKit::WebFrameProxy* _Nullable getWebFrameProxyWithFrameID(const WebCore::FrameIdentifier& frameID) {
    return WebKit::WebFrameProxy::webFrame(frameID);
}

inline WebKit::WebFrameProxy* _Nullable getWebFrameProxyWithoutFrameID() {
    return WebKit::WebFrameProxy::webFrame(std::nullopt);
}
