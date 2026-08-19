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
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadGroup.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

#if ENABLE(BACK_FORWARD_LIST_SWIFT)
#include "WebBackForwardListMessages.h"
#include <wtf/RefCountable.h>
#include <wtf/SwiftData.h>
#endif

namespace API {
class Array;
}

namespace WebKit {

class FrameState;
class WebPageProxy;

struct BackForwardListState;
struct WebBackForwardListCounts;

enum class AllowSkippingBackForwardItems : bool { No, Yes };

#if ENABLE(BACK_FORWARD_LIST_SWIFT)

// The Swift struct holding this class's state. Declared in WebBackForwardList.swift.
struct WebBackForwardListSwiftData;

// Callbacks handed to Swift are wrapped in RefCountable so that Swift can hold and
// call them. FIXME(rdar://162361370) removes the need for this. The equivalents for
// the IPC replies are generated into WebBackForwardListMessages.h.
using WebBackForwardListItemFilter = WTF::RefCountable<Function<bool(WebBackForwardListItem&)>>;

#endif

// Where this class's member functions are implemented depends on
// ENABLE(BACK_FORWARD_LIST_SWIFT):
//  - enabled: the state lives in a Swift struct held by m_swiftData, and the member
//    functions below marked as such are implemented by `@cxx @implementation`
//    functions in WebBackForwardList.swift.
//  - disabled: the state and every member function are plain C++, in
//    WebBackForwardList.cpp.
// The public API, and therefore every caller, is the same either way.
class WebBackForwardList final : public API::ObjectImpl<API::Object::Type::BackForwardList>, public IPC::MessageReceiver {
public:
    static Ref<WebBackForwardList> create(WebPageProxy& page)
    {
        return adoptRef(*new WebBackForwardList(page));
    }

    ~WebBackForwardList();

    void ref() const final { API::ObjectImpl<API::Object::Type::BackForwardList>::ref(); }
    void deref() const final { API::ObjectImpl<API::Object::Type::BackForwardList>::deref(); }

    // Implemented in Swift when ENABLE(BACK_FORWARD_LIST_SWIFT).

    void pageClosed();

    WebBackForwardListItem* NODELETE WTF_NULLABLE itemForID(WebCore::BackForwardItemIdentifier);

    void goToItem(WebBackForwardListItem&);
    void removeAllItems();
    void clear();

    WebBackForwardListItem* NODELETE WTF_NULLABLE currentItem() const;
    RefPtr<WebBackForwardListItem> backItem() const;
    RefPtr<WebBackForwardListItem> forwardItem() const;

    RefPtr<WebBackForwardListItem> itemAtDeltaFromCurrentIndex(int, AllowSkippingBackForwardItems = AllowSkippingBackForwardItems::Yes) const;

    RefPtr<WebBackForwardListItem> goBackItemSkippingItemsWithoutUserGesture() const;
    RefPtr<WebBackForwardListItem> goForwardItemSkippingItemsWithoutUserGesture() const;

    unsigned backListCountForAPI() const;
    unsigned forwardListCountForAPI() const;

    Ref<API::Array> backListAsAPIArrayWithLimit(unsigned limit) const;
    Ref<API::Array> forwardListAsAPIArrayWithLimit(unsigned limit) const;

    void restoreFromState(BackForwardListState);
    void setItemsAsRestoredFromSession();

    void backForwardAddItemShared(IPC::Connection&, Ref<FrameState>&&, LoadedWebArchive);
    void backForwardGoToItemShared(WebCore::BackForwardItemIdentifier);

    FrameState* NODELETE WTF_NULLABLE findFrameStateInItem(WebCore::BackForwardItemIdentifier, WebCore::FrameIdentifier parentFrameID, WebCore::FrameIdentifier childFrameID, uint64_t childFrameIndex, const String& childFrameName);
    void updateFrameIdentifier(WebCore::FrameIdentifier oldFrameID, WebCore::FrameIdentifier newFrameID);

    void replaceFrameStateForChild(WebBackForwardListItem&, WebCore::FrameIdentifier, Ref<FrameState>&& newFrameState);

    String loggingString() const;

    // Always implemented in C++, in WebBackForwardList.cpp.

    Ref<API::Array> backList() const;
    Ref<API::Array> forwardList() const;

    BackForwardListState backForwardListState(WTF::Function<bool (WebBackForwardListItem&)>&&) const;
    void setItemsAsRestoredFromSessionIf(NOESCAPE Function<bool(WebBackForwardListItem&)>&&);

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&);
    void didReceiveProvisionalMessage(IPC::Connection&, IPC::Decoder&);
    void didReceiveSyncMessage(IPC::Connection&, IPC::Decoder&, UniqueRef<IPC::Encoder>&);

#if !ENABLE(BACK_FORWARD_LIST_SWIFT)
    enum class MakeAPIArray : bool { No, Yes };
#endif

private:
    explicit WebBackForwardList(WebPageProxy&);

#if ENABLE(BACK_FORWARD_LIST_SWIFT)

    // Implemented in Swift. These exist because Swift cannot yet consume a
    // WTF::Function or a WTF::CompletionHandler directly; the public entry points above
    // wrap the callback for them.
    BackForwardListState backForwardListStateMatching(WebBackForwardListItemFilter&) const;
    void setItemsAsRestoredFromSessionMatching(WebBackForwardListItemFilter&);
    void setHandlingProvisionalMessage(bool);
    bool isSafeToDestroy() const;

    // IPC messages, implemented in Swift and touching only the Swift state.
    void backForwardAddItem(IPC::Connection&, Ref<FrameState>&&);
    void backForwardSetChildItem(IPC::Connection&, WebCore::BackForwardFrameItemIdentifier, Ref<FrameState>&&);
    void backForwardClearChildren(WebCore::BackForwardItemIdentifier, WebCore::BackForwardFrameItemIdentifier);
    void backForwardUpdateItem(IPC::Connection&, Ref<FrameState>&&);
    void backForwardGoToItem(WebCore::BackForwardItemIdentifier);
    void backForwardAllItems(WebCore::FrameIdentifier, CompletionHandlers::WebBackForwardList::BackForwardAllItemsCompletionHandler*);
    void backForwardItemAtIndexForWebContent(IPC::Connection*, int32_t index, WebCore::FrameIdentifier, CompletionHandlers::WebBackForwardList::BackForwardItemAtIndexForWebContentCompletionHandler*);
    void backForwardListContainsItem(WebCore::BackForwardItemIdentifier, CompletionHandlers::WebBackForwardList::BackForwardListContainsItemCompletionHandler*);
    void backForwardListCounts(CompletionHandlers::WebBackForwardList::BackForwardListCountsCompletionHandler*);

    SwiftData<WebBackForwardListSwiftData> m_swiftData;

#else // ENABLE(BACK_FORWARD_LIST_SWIFT)

    enum class NavigationDirection { Backward, Forward };
    std::pair<RefPtr<WebBackForwardListItem>, size_t> itemStartingAtIndexSkippingItemsAddedByJSWithoutUserGesture(NavigationDirection, size_t startingIndex) const;
    std::pair<RefPtr<WebBackForwardListItem>, size_t> itemAtIndexWithoutSkipping(size_t) const;

    std::pair<unsigned, RefPtr<API::Array>> backListWithLimitInternal(unsigned limit, MakeAPIArray) const;
    std::pair<unsigned, RefPtr<API::Array>> forwardListWithLimitInternal(unsigned limit, MakeAPIArray) const;

    unsigned NODELETE rawBackListEntryCount() const;
    unsigned NODELETE rawForwardListEntryCount() const;

    void addItem(Ref<WebBackForwardListItem>&&);
    void addChildItem(WebCore::FrameIdentifier, Ref<FrameState>&&);
    void didRemoveItem(WebBackForwardListItem&);
    const BackForwardListItemVector& entries() const LIFETIME_BOUND { return m_entries; }
    WebBackForwardListCounts NODELETE rawCounts() const;
    Ref<FrameState> completeFrameStateForNavigation(Ref<FrameState>&&);

    // IPC messages
    void backForwardAddItem(IPC::Connection&, Ref<FrameState>&&);
    void backForwardSetChildItem(IPC::Connection&, WebCore::BackForwardFrameItemIdentifier, Ref<FrameState>&&);
    void backForwardClearChildren(WebCore::BackForwardItemIdentifier, WebCore::BackForwardFrameItemIdentifier);
    void backForwardUpdateItem(IPC::Connection&, Ref<FrameState>&&);
    void backForwardGoToItem(WebCore::BackForwardItemIdentifier);
    void backForwardAllItems(WebCore::FrameIdentifier, CompletionHandler<void(Vector<Ref<FrameState>>&&)>&&);
    void backForwardItemAtIndexForWebContent(IPC::Connection&, int32_t index, WebCore::FrameIdentifier, CompletionHandler<void(RefPtr<FrameState>&&)>&&);
    void backForwardListContainsItem(WebCore::BackForwardItemIdentifier, CompletionHandler<void(bool)>&&);
    void backForwardListCounts(CompletionHandler<void(WebBackForwardListCounts&&)>&&);

    WeakPtr<WebPageProxy> m_page;
    BackForwardListItemVector m_entries;
    std::optional<size_t> m_currentIndex;
    bool m_handlingProvisionalMessage { false };

#endif // ENABLE(BACK_FORWARD_LIST_SWIFT)
} SWIFT_SHARED_REFERENCE(refBackForwardList, derefBackForwardList) SWIFT_RETURNED_AS_UNRETAINED_BY_DEFAULT;

} // namespace WebKit

inline void refBackForwardList(WebKit::WebBackForwardList* WTF_NONNULL list)
{
    list->ref();
}

inline void derefBackForwardList(WebKit::WebBackForwardList* WTF_NONNULL list)
{
    list->deref();
}

SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::WebBackForwardList)
static bool isType(const API::Object& object) { return object.type() == API::Object::Type::BackForwardList; }
SPECIALIZE_TYPE_TRAITS_END()
