/*
 * Copyright (C) 2010, 2011 Apple Inc. All rights reserved.
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

#include "APIObject.h"
#include "LoadedWebArchive.h"
#include "MessageReceiver.h"
#include "WebBackForwardListItem.h"
#include <WebCore/BackForwardItemIdentifier.h>
#include <WebCore/LocalFrameLoaderClient.h>
#include <wtf/Function.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadGroup.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

namespace API {
class Array;
}

namespace WebKit {

class BrowsingContextGroup;
class FrameState;
class WebPageProxy;

struct BackForwardListState;
struct WebBackForwardListCounts;

enum class AllowSkippingBackForwardItems : bool { No, Yes };

using WebBackForwardListItemFilter = Function<bool(WebBackForwardListItem&)>;

// With ENABLE(BACK_FORWARD_LIST_SWIFT), the member functions marked below are implemented
// in WebBackForwardList.swift with `@cxx @implementation`, and the state lives in a Swift
// object owned through m_swiftState. Otherwise everything is implemented in
// WebBackForwardList.cpp. Callers see the same class either way.
class SWIFT_PRIVATE_FILEID("WebKit/WebBackForwardList.swift") WebBackForwardList : public API::ObjectImpl<API::Object::Type::BackForwardList>, public IPC::MessageReceiver {
public:
    static Ref<WebBackForwardList> create(WebPageProxy& page)
    {
        return adoptRef(*new WebBackForwardList(page));
    }

    void ref() const final { API::ObjectImpl<API::Object::Type::BackForwardList>::ref(); }
    void deref() const final { API::ObjectImpl<API::Object::Type::BackForwardList>::deref(); }

    virtual ~WebBackForwardList();

    // Implemented in Swift when ENABLE(BACK_FORWARD_LIST_SWIFT).

    void pageClosed();

    RefPtr<WebBackForwardListItem> itemForID(WebCore::BackForwardItemIdentifier);

    void goToItem(WebBackForwardListItem&);
    void removeAllItems();
    void clear();

    RefPtr<WebBackForwardListItem> currentItem() const;
    RefPtr<WebBackForwardListItem> backItem() const;
    RefPtr<WebBackForwardListItem> forwardItem() const;

    RefPtr<WebBackForwardListItem> itemAtDeltaFromCurrentIndex(int, AllowSkippingBackForwardItems = AllowSkippingBackForwardItems::Yes) const;

    RefPtr<WebBackForwardListItem> goBackItemSkippingItemsWithoutUserGesture() const;
    RefPtr<WebBackForwardListItem> goForwardItemSkippingItemsWithoutUserGesture() const;
    unsigned backListCountForAPI() const;
    unsigned forwardListCountForAPI() const;

    Ref<API::Array> backList() const;
    Ref<API::Array> forwardList() const;

    Ref<API::Array> backListAsAPIArrayWithLimit(unsigned limit) const;
    Ref<API::Array> forwardListAsAPIArrayWithLimit(unsigned limit) const;

    BackForwardListState backForwardListState(NOESCAPE const WebBackForwardListItemFilter&) const;
    void restoreFromState(BackForwardListState);

    void setItemsAsRestoredFromSession();
    void setItemsAsRestoredFromSessionIf(NOESCAPE const WebBackForwardListItemFilter&);

    // Swift can't yet implement functions taking rvalue references, so the Refs here are by value,
    // and a String parameter is by value so that the Swift implementation needn't be @unsafe.
    void backForwardAddItemShared(IPC::Connection&, Ref<FrameState>, LoadedWebArchive, BrowsingContextGroup&);
    void backForwardGoToItemShared(IPC::Connection&, WebCore::BackForwardItemIdentifier);

    RefPtr<FrameState> findFrameStateInItem(WebCore::BackForwardItemIdentifier, WebCore::FrameIdentifier parentFrameID, WebCore::FrameIdentifier childFrameID, uint64_t childFrameIndex, String childFrameName);
    void updateFrameIdentifier(WebCore::FrameIdentifier oldFrameID, WebCore::FrameIdentifier newFrameID);

    void replaceFrameStateForChild(WebBackForwardListItem&, WebCore::FrameIdentifier, Ref<FrameState> newFrameState);

    String loggingString() const;

    // Always implemented in C++.

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);
    void didReceiveProvisionalMessage(IPC::Connection&, IPC::Decoder&);
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);

#if !ENABLE(BACK_FORWARD_LIST_SWIFT)
    enum class MakeAPIArray : bool { No, Yes };
#endif

private:
    explicit WebBackForwardList(WebPageProxy&);

    // IPC messages. Those with a reply are always implemented in C++, since Swift can't take a
    // CompletionHandler, and get their reply from the functions after them.
    void backForwardAddItem(IPC::Connection&, Ref<FrameState>);
    void backForwardSetChildItem(IPC::Connection&, WebCore::BackForwardFrameItemIdentifier, Ref<FrameState>);
    void backForwardClearChildren(WebCore::BackForwardItemIdentifier, WebCore::BackForwardFrameItemIdentifier);
    void backForwardUpdateItem(IPC::Connection&, Ref<FrameState>);
    void backForwardGoToItem(IPC::Connection&, WebCore::BackForwardItemIdentifier);
    void backForwardAllItems(WebCore::FrameIdentifier, CompletionHandler<void(Vector<Ref<FrameState>>&&)>&&);
    void backForwardItemAtIndexForWebContent(IPC::Connection&, int32_t delta, WebCore::FrameIdentifier, CompletionHandler<void(RefPtr<FrameState>&&)>&&);
    void backForwardListContainsItem(WebCore::BackForwardItemIdentifier, CompletionHandler<void(bool)>&&);
    void backForwardListCounts(CompletionHandler<void(WebBackForwardListCounts&&)>&&);

    // Implemented in Swift when ENABLE(BACK_FORWARD_LIST_SWIFT).
    Vector<Ref<FrameState>> frameStatesForAllItems(WebCore::FrameIdentifier) const;
    RefPtr<FrameState> frameStateForWebContent(IPC::Connection&, int32_t delta, WebCore::FrameIdentifier) const;
    NODELETE WebBackForwardListCounts rawCounts() const;

#if ENABLE(BACK_FORWARD_LIST_SWIFT)

    // Implemented in Swift.
    void setHandlingProvisionalMessage(bool);
    static void* WTF_NONNULL createSwiftState(WeakPtr<WebPageProxy>);
    static void destroySwiftState(void* WTF_NONNULL swiftState);

    // A retained reference to the Swift object holding this list's state, created by the
    // constructor and released by the destructor.
    void* WTF_NONNULL const m_swiftState;

#else // ENABLE(BACK_FORWARD_LIST_SWIFT)

    enum class NavigationDirection { Backward, Forward };
    std::pair<RefPtr<WebBackForwardListItem>, size_t> itemStartingAtIndexSkippingItemsAddedByJSWithoutUserGesture(NavigationDirection, size_t startingIndex) const;
    std::pair<RefPtr<WebBackForwardListItem>, size_t> itemAtIndexWithoutSkipping(size_t) const;

    std::pair<unsigned, RefPtr<API::Array>> backListWithLimitInternal(unsigned limit, MakeAPIArray) const;
    std::pair<unsigned, RefPtr<API::Array>> forwardListWithLimitInternal(unsigned limit, MakeAPIArray) const;

    NODELETE unsigned rawBackListEntryCount() const;
    NODELETE unsigned rawForwardListEntryCount() const;

    void addItem(Ref<WebBackForwardListItem>&&);
    void addChildItem(WebCore::FrameIdentifier, Ref<FrameState>&&);
    void didRemoveItem(WebBackForwardListItem&);
    const BackForwardListItemVector& entries() const LIFETIME_BOUND { return m_entries; }
    Ref<FrameState> completeFrameStateForNavigation(Ref<FrameState>&&);

    WeakPtr<WebPageProxy> m_page;
    BackForwardListItemVector m_entries;
    std::optional<size_t> m_currentIndex;
    bool m_handlingProvisionalMessage { false };

#endif // ENABLE(BACK_FORWARD_LIST_SWIFT)
};

} // namespace WebKit

SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebBackForwardList)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::BackForwardList; }
SPECIALIZE_TYPE_TRAITS_END()
