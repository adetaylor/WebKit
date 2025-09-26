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
@_spi(Internal)
public import WebKit_Internal
internal import wtf

@_spi(Internal)
public typealias BackForwardItemIdentifier = WebCore.BackForwardItemIdentifier
@_spi(Internal)
public typealias FrameIdentifier = WebCore.FrameIdentifier
@_spi(Internal)
public typealias WebBackForwardListItem = WebKit.WebBackForwardListItem
@_spi(Internal)
public typealias WebBackForwardListCounts = WebKit.WebBackForwardListCounts
@_spi(Internal)
public typealias BackForwardListState = WebKit.BackForwardListState
@_spi(Internal)
public typealias FrameState = WebKit.FrameState
@_spi(Internal)
public typealias WebPageProxy = WebKit.WebPageProxy
@_spi(Internal)
public typealias BackForwardFrameItemIdentifier = WebCore.BackForwardFrameItemIdentifier

#if ENABLE_BACKFORWARDLIST_SWIFT

// TODO: some of these utility functions would be better in SwiftUtilities.h
// but can't be put there as we are unable to use swift;:Array and swift::String
// rdar://161270632

func toVector(array: [WebBackForwardListItem]) -> VectorRefBackForwardListItem {
    var vec = VectorRefBackForwardListItem.init();
    for item in array {
        vec.append(consuming: toRefWebBackForwardListItem(item));
    }
    return vec;
}

func wtfStringToSwiftString(wtfString: WTF.String) -> String {
    // TODO choose conversions which are correct
    return String.init(wtfString.utf8(WTF.LenientConversion).toStdString())
}

func swiftStringToWtfString(swiftString: String) -> WTF.String {
    // TODO choose conversions which are correct
    var wtfString: WTF.String? = Optional.none;
    let len = swiftString.utf8.count;
    swiftString.utf8CString.withUnsafeBufferPointer { ptr in
        let span = SpanChar.init(ptr, len);
        wtfString = WTF.String.fromUTF8(span);
    }
    return wtfString!;
}

enum Direction {
    case Backward
    case Forward
}

// TODO see if this can be achieved using SWIFT_CONFORMS_TO_PROTOCOL
extension WebKit.WebPageProxyIdentifier: Equatable {
    @_spi(Internal)
    static public func == (lhs: WebKit.WebPageProxyIdentifier, rhs: WebKit.WebPageProxyIdentifier) -> Bool {
        return webPageProxyIdentifiersEquate(lhs, rhs);
    }
}

// TODO make efficient
// TODO investigate the extent to which we can make this generic
func toWTFVectorAPIObject(list: [API.Object]) -> VectorAPIObject {
    var vec = VectorAPIObject();
    vec.reserveCapacity(list.count);
    for item in list {
        vec.append(consuming: toRefPtrAPIObject(item));
    }
    return vec;
}

@_expose(Cxx)
@_spi(Internal)
@safe // The unsafety here is the WeakPtr<WebPageProxy>. We're managing that correctly.
      // TODO make a safe wrapper for WTF.WeakPtr.
public class WebBackForwardListSwift {
    static let DefaultCapacity = 100;

    var page: WeakPtrWebPageProxy;
    var entries: [WebBackForwardListItem] = [];
    var currentIndex: Array.Index?;

    @_expose(Cxx)
    @_spi(Internal)
    public init(page: WeakPtrWebPageProxy) {
        // LOG(BackForward, "(Back/Forward) Created WebBackForwardList %p", this); // TODO
        self.page = page
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func preDestructionChecks() {
        // A WebBackForwardList should never be destroyed unless it's associated page has been closed or is invalid.
        // ASSERT((!m_page && !m_currentIndex) || !m_page->hasRunningProcess()); // TODO
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func itemForID(identifier: BackForwardItemIdentifier) -> WebBackForwardListItem? {
        // TODO consider restructuring this a bit. It's a bit odd that it basically refers
        // to a map within WebBackForwardListItem. Maybe WebBackForwardListSwift should
        // own that map.
        // TODO think more about how this gets converted to a RefPtr on return.
        guard let page = getPageWeakPtr(page) else {
            return nil
        }

        let item = WebBackForwardListItem.itemForID(identifier);
        guard let item else {
            return nil;
        }

        assert(item.pageID() == page.identifier());
        return item;
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func pageClosed() {
        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p had its page closed with current size %zu", this, m_entries.count); // TODO

        // We should have always started out with an m_page and we should never close the page twice
        assert(pageWeakPtrIsOccupied(page)); // TODO ensure this is similar to ASSERT in C++
        // TODO rename to something less daft
        let definitePage = getPageWeakPtr(page)!;

        for item in entries {
            didRemoveItem(item: item);
        }

        page.clear();
        entries.removeAll();
        currentIndex = nil;
    }

    func assertStateOk() {
        // TODO figure out how to even put the if condition inside the assert
        if let currentIndex {
            assert(currentIndex < entries.count)
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func addItem(newItem: WebBackForwardListItem) {
        assertStateOk();

        guard let page = getPageWeakPtr(page) else {
            return;
        }

        var removedItems: [WebBackForwardListItem] = [];

        if let initialCurrentIndex = currentIndex {
            currentIndex = Optional.some(initialCurrentIndex); // TODO make more idiomatic
        
            page.recordAutomaticNavigationSnapshot();

            // Toss everything in the forward list.
            let targetSize = initialCurrentIndex + 1;
            removedItems.reserveCapacity(entries.count - targetSize);

            // TODO recode using Array.subscript if this
            // turns out to be OK for didRemoveItem
            while entries.count > targetSize {
                didRemoveItem(item: entries.last!);
                removedItems.append(entries.removeLast());
            }

            while !entries.isEmpty {
                let lastEntry = entries.last!;
                if !lastEntry.isRemoteFrameNavigation()
                        || derefRefBackForwardListFrameItem(lastEntry.protectedNavigatedFrameItem()).sharesAncestor(derefRefBackForwardListFrameItem(newItem.protectedNavigatedFrameItem())) {
                    break;
                }
                didRemoveItem(item: lastEntry);
                removedItems.append(entries.removeLast());

                if entries.isEmpty {
                    currentIndex = nil;
                } else {
                    currentIndex = currentIndex! - 1;
                }
            }

            // Toss the first item if the list is getting too big, as long as we're not using it
            // (or even if we are, if we only want 1 entry).
            if var initialCurrentIndex = currentIndex {
                if entries.count > WebBackForwardListSwift.DefaultCapacity {
                    didRemoveItem(item: entries.first!);
                    removedItems.append(entries.removeFirst());
                }

                if entries.isEmpty {
                    currentIndex = nil;
                } else {
                    currentIndex = initialCurrentIndex - 1;
                }
            }
        } else {
            // If we have no current item index we should also not have any entries.
            assert(entries.isEmpty);
            // TODO restructure to use an enum so these can't get out of sync

            // But just in case it does happen in practice we'll get back in to a consistent state now before adding the new item.
            for item in entries {
                didRemoveItem(item: item);
            }
            removedItems.append(contentsOf: entries);
            entries.removeAll();
        }

        var shouldKeepCurrentItem = true;

        // TODO nicer pattern?
        if let initialCurrentIndex = currentIndex {
            shouldKeepCurrentItem = page.shouldKeepCurrentBackForwardListItemInList(entries[initialCurrentIndex]);
            if shouldKeepCurrentItem {
                currentIndex = initialCurrentIndex+1;
            }
        } else {
            assert(entries.isEmpty);
            currentIndex = 0
        }

        let currentIndex = currentIndex!; // TODO nicer pattern?
        if (!shouldKeepCurrentItem) {
            // m_current should never be pointing past the end of the entries Vector.
            // If it is, something has gone wrong and we should not try to swap in the new item.
            assert(currentIndex < entries.count);
            removedItems.append(entries[currentIndex])
        } else {
            // m_current should never be pointing more than 1 past the end of the entries Vector.
            // If it is, something has gone wrong and we should not try to insert the new item.
            assert(currentIndex <= entries.count);
            if (currentIndex <= entries.count) {
                entries.insert(newItem, at: currentIndex);
            }
        }

        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p added an item. Current size %zu, current index %zu, threw away %zu items", this, m_entries.count, *m_currentIndex, removedItems.count); // TODO
        // TODO the array here will need to be converted
        page.didChangeBackForwardList(newItem, consuming: toVector(array: removedItems));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func goToItem(item: WebBackForwardListItem) {
        assertStateOk();

        guard !entries.isEmpty else {
            return;
        }
        guard let page = getPageWeakPtr(page) else {
            return;
        }
        guard let priorCurrentIndex = currentIndex else {
            return;
        }

        // TODO replace with entries.firstIndex if we can conform to Equatable
        var targetIndex: Int? = Optional.none;
        for (i, entry) in entries.enumerated() {
            if itemsMatch(entry, item) {
                targetIndex = i;
                break;
            }
        }

        // If the target item wasn't even in the list, there's nothing else to do.
        guard var targetIndex else {
            // LOG(BackForward, "(Back/Forward) WebBackForwardList %p could not go to item %s (%s) because it was not found", this, item.identifier().toString().utf8().data(), item.url().utf8().data()); // TODO
            return;
        }

        if targetIndex < priorCurrentIndex {
            let delta = entries.count - targetIndex - 1;
            let deltaValue = if delta > 10 { "over10" } else { delta.description };
            page.logDiagnosticMessage(WebCore.DiagnosticLoggingKeys.backNavigationDeltaKey(), swiftStringToWtfString(deltaValue), WebCore.ShouldSample.No);
        }

        // If we're going to an item different from the current item, ask the client if the current
        // item should remain in the list.
        let currentItem = entries[priorCurrentIndex];
        var shouldKeepCurrentItem = true;
        if !itemsMatch(currentItem, item) {
            page.recordAutomaticNavigationSnapshot();
            shouldKeepCurrentItem = page.shouldKeepCurrentBackForwardListItemInList(currentItem);
        }

        // If the client said to remove the current item, remove it and then update the target index.
        var removedItems: [WebBackForwardListItem] = [];
        if (!shouldKeepCurrentItem) {
            removedItems.append(entries.remove(at: priorCurrentIndex));

            // TODO replace with entries.firstIndex if we can conform to Equatable
            var thisTargetIndex: Int? = Optional.none;
            for (i, entry) in entries.enumerated() {
                if itemsMatch(entry, item) {
                    thisTargetIndex = i;
                    break;
                }
            }
            targetIndex = thisTargetIndex!;
        }

        currentIndex = targetIndex;

        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p going to item %s, is now at index %zu", this, item.identifier().toString().utf8().data(), targetIndex); // TODO
        page.didChangeBackForwardList(Optional.none, consuming: toVector(array: removedItems));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func currentItem() -> WebBackForwardListItem? {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return nil;
        }

        guard let currentIndex = currentIndex else {
            return nil;
        }

        return entries[currentIndex];
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backItem() -> WebBackForwardListItem? {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return nil;
        }

        guard let currentIndex = currentIndex else {
            return nil;
        }

        if currentIndex > 0 {
            return entries[currentIndex - 1];
        } else {
            return nil;
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func forwardItem() -> WebBackForwardListItem? {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return nil;
        }

        guard let currentIndex = currentIndex else {
            return nil;
        }

        if currentIndex < entries.count-1 {
            return entries[currentIndex + 1];
        } else {
            return nil;
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func itemAtIndex(index: Array.Index) -> WebBackForwardListItem? {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return nil;
        }

        guard let currentIndex = currentIndex else {
            return nil;
        }
    
        // Do range checks without doing math on index to avoid overflow.
        if (index < 0 && -index > backListCount()) {
            return nil;
        }
        
        if (index > 0 && index > forwardListCount()) {
            return nil;
        }

        return entries[index + currentIndex];
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backListCount() -> Array.Index {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return 0;
        }

        guard let currentIndex = currentIndex else {
            return 0;
        }

        return currentIndex;
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func forwardListCount() -> Array.Index {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return 0;
        }

        guard let currentIndex = currentIndex else {
            return 0;
        }
        return entries.count - (currentIndex + 1);
    }

    // TODO file a radar about the diagnostics here if API.Array is not copyable
    // and is not SWIFT_SHARED_REFERENCE: the diagnostics are simply
    // 'error: 'Array' is not a member type of enum '__ObjC.API''
    @_expose(Cxx)
    @_spi(Internal)
    public func backListAsAPIArrayWithLimit(limit: UInt) -> API.Array {
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return derefRefAPIArray(API.Array.create());
        }

        guard let currentIndex = currentIndex else {
            return derefRefAPIArray(API.Array.create());
        }

        let backListSize = backListCount();
        let size = min(backListSize, Int(limit));
        guard size > 0 else {
            return derefRefAPIArray(API.Array.create());
        }
        assert(backListSize >= size);
        let startIndex = backListSize - size;

        return toWTFVectorAPIObject(list: entries[startIndex..<startIndex + size].map { toAPIObject($0) })
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func forwardListAsAPIArrayWithLimit(limit: UInt) -> API.Array {
        // TODO see if we can abstract bits of these two functions
        assertStateOk();

        guard pageWeakPtrIsOccupied(page) else {
            return derefRefAPIArray(API.Array.create());
        }

        guard let currentIndex = currentIndex else {
            return derefRefAPIArray(API.Array.create());
        }

        let size = min(forwardListCount(), Int(limit));
        guard size > 0 else {
            return derefRefAPIArray(API.Array.create());
        }
        let startIndex = currentIndex + 1;
        return toWTFVectorAPIObject(list: entries[startIndex..<startIndex+size].map { toAPIObject($0) })
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func removeAllItems()  {
        assertStateOk();

        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p removeAllItems (has %zu of them)", this, m_entries.count); // TODO

        for item in entries {
            didRemoveItem(item: item);
        }
        currentIndex = nil;
        // TODO make more efficient
        let entriesCopy = entries;
        entries.removeAll();
        guard let page = getPageWeakPtr(page) else {
            return; // TODO consider asserting instead; whatever the C++ would have done
        }
        page.didChangeBackForwardList(Optional.none, consuming: entriesCopy);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func clear()  {
        assertStateOk();

        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p clear (has %zu of them)", this, m_entries.count); // TODO

        let size = entries.count;
        guard let page else {
            return;
        }
        guard size > 1 else {
            return;
        }

        let currentItem = currentItem();
        guard let currentItem = currentItem else {
            // We should only ever have no current item if we also have no current item index.
            assert(currentIndex == nil);

            // But just in case it does happen in practice we should get back into a consistent state now.
            // TODO some of the C++ places which aim to "get back into a consistent state"
            // notify the WebPageProxy of the change; others don't
            removeAllItems();
            return;
        }

        for item in entries {
            // TODO there must be a way to use === here or similar. Ask.
            if !itemsMatch(item, currentItem) {
                didRemoveItem(item: item);
            }
        }

        var removedItems: [WebBackForwardListItem] = [];
        removedItems.reserveCapacity(size-1);

        // TODO this was previously done in terms of indices, there might be a reason
        for item in entries {
            if !itemsMatch(item, currentItem) {
                removedItems.append(item);
            }
        }

        currentIndex = 0;
        entries.removeAll();
        entries.append(currentItem);
        page.didChangeBackForwardList(Optional.none, consuming: removedItems);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardListState(filter: ((WebBackForwardListItem) -> Bool)?) -> BackForwardListState {
        assertStateOk();

        var backForwardListState = BackForwardListState.init();
        if let currentIndex = currentIndex {
            backForwardListState.setCurrentIndex(currentIndex);
        }

        entries.enumerate().forEach { i, entry in
            if let filter = filter {
                if !filter(entry) {
                    if let stateCurrentIndex = backForwardListState.currentIndex {
                        if i < stateCurrentIndex && stateCurrentIndex != 0 {
                            backForwardListState.currentIndex -= 1;
                        }
                    }
                    continue;
                }
                backForwardListState.items.append(entry.mainFrameState())
            }
        }

        if backForwardListState.items.isEmpty() {
            backForwardListState.currentIndex = nil;
        } else if backForwardListState.items.size() <= backForwardListState.currentIndex! {
            backForwardListState.currentIndex = backForwardListState.items.size()-1;
        }
        return backForwardListState;
    }

    func setBackForwardItemIdentifiers(frameState: FrameState, itemID: BackForwardItemIdentifier) {
        frameState.itemID = itemID;
        frameState.frameItemID = BackForwardFrameItemIdentifier.generate();
        for child in frameState.children {
            setBackForwardItemIdentifiers(frameState: child, itemID: itemID); // TODO ensure child is a reference type
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func restoreFromState(backForwardListState: BackForwardListState) {
        guard let page = getPageWeakPtr(page) else {
            return;
        }

        // FIXME: Enable restoring resourceDirectoryURL.
        entries.removeAll();
        entries.reserveCapacity(backForwardListState.items.count);
        // TODO not as efficient as C++ we're replacing
        for item in backForwardListState.items {
            let stateCopy = item.state.copy(); // TODO may not be necessary depending on how we unpack from Refs.
            setBackForwardItemIdentifiers(frameState: stateCopy, itemID: BackForwardItemIdentifier.generate());
            currentIndex = entries.isEmpty ? nil : entries.count - 1;
            // FIXME: navigatedFrameID will always be the main frame ID, causing the restored session state to be sent to an incorrect process when going back or forward with site isolation enabled.
            let navigatedFrameID = stateCopy.frameID;
            // TODO ensure items not copied unduly
            let item = WebKit.WebBackForwardListItem.create(stateCopy, page.identifier(), consuming: navigatedFrameID);
            entries.append(item);
        }

        currentIndex = backForwardListState.currentIndex;
        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p restored from state (has %zu entries)", this, m_entries.count); // TODO
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func setItemsAsRestoredFromSession() {
        setItemsAsRestoredFromSessionIf(functor: { (WebBackForwardList) in true })
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func setItemsAsRestoredFromSessionIf(functor: (WebBackForwardListItem) -> Bool) {
        for entry in entries {
            if functor(entry) {
                entry.setWasRestoredFromSession()
            }
        }
    }

    func didRemoveItem(item: WebBackForwardListItem) {
        item.wasRemovedFromBackForwardList();
        guard let page else {
            assert(false);
        }
        page.backForwardRemovedItem(item.identifier());
        // TODO expose platform macros to Swift to remove the following call on most platforms
        item.setNullSnapshot();
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func goBackItemSkippingItemsWithoutUserGesture() -> WebBackForwardListItem? {
        return itemSkippingBackForwardItemsAddedByJSWithoutUserGesture(direction: Direction.Backward);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func goForwardItemSkippingItemsWithoutUserGesture() -> WebBackForwardListItem? {
        return itemSkippingBackForwardItemsAddedByJSWithoutUserGesture(direction: Direction.Forward);
    }

    func itemSkippingBackForwardItemsAddedByJSWithoutUserGesture(direction: Direction) -> WebBackForwardListItem? {
        let delta = switch direction {
            case .Backward: -1;
            case .Forward: 1
        };
        var itemIndex = delta;
        let item = itemAtIndex(index: itemIndex);
        guard var item = item else {
            return nil;
        }

        // TODO get platform defines here and make this work
        // #if PLATFORM(COCOA)
        //     if (!linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::UIBackForwardSkipsHistoryItemsWithoutUserGesture))
        //         return item;
        // #endif

        // For example:
        // Yahoo -> Yahoo#a (no userInteraction) -> Google -> Google#a (no user interaction) -> Google#b (no user interaction)
        // If we're on Google and navigate back, we don't want to skip anything and load Yahoo#a.
        // However, if we're on Yahoo and navigate forward, we do want to skip items and end up on Google#b.
        // TODO consider the unwrap below, perhaps use the guarded item above?
        if direction == Direction.Backward && currentItem()!.wasCreatedByJSWithoutUserInteraction() {
            return item;
        }

        // For example:
        // Yahoo -> Yahoo#a (no userInteraction) -> Google -> Google#a (no user interaction) -> Google#b (no user interaction)
        // If we are on Google#b and navigate backwards, we want to skip over Google#a and Google, to end up on Yahoo#a.
        // If we are on Yahoo#a and navigate forwards, we want to skip over Google and Google#a, to end up on Google#b.
        let originalItem = item;
        while item.wasCreatedByJSWithoutUserInteraction() {
            itemIndex += delta;
            let thisItem = itemAtIndex(index: itemIndex);
            guard let thisItem else {
                return originalItem;
            }
            item = thisItem;
            // RELEASE_LOG(Loading, "UI Navigation is skipping a WebBackForwardListItem because it was added by JavaScript without user interaction"); // TODO
        }

        // We are now on the next item that has user interaction.
        assert(!item.wasCreatedByJSWithoutUserInteraction());

        if (direction == Direction.Backward) {
            // If going backwards, skip over next item with user iteraction since this is the one the user
            // thinks they're on.
            itemIndex -= 1;
            let thisItem = itemAtIndex(index: itemIndex);
            guard let thisItem else {
                return originalItem;
            }
            item = thisItem;

            // RELEASE_LOG(Loading, "UI Navigation is skipping a WebBackForwardListItem that has user interaction because we started on an item that didn't have interaction"); // TODO
        } else {
            // If going forward and there are items that we created by JS without user interaction, move forward to the last
            // one in the series.
            var nextItem = itemAtIndex(index: itemIndex + 1);
            while var nextItem = nextItem, nextItem.wasCreatedByJSWithoutUserInteraction() {
                item = nextItem;
                nextItem = itemAtIndex(index: itemIndex);
                itemIndex += 1;
            }
        }
        return item;
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func loggingString() {
        // Safety: it's guaranteed to be possible to convert this pointer to a string
        // TODO: raise a radar for that fact that there is no actual unsafety here
        // (or find a workaround)
        let ptrbit = unsafe "0x\(Unmanaged.passUnretained(self).toOpaque())"
        var result = "\nWebBackForwardList \(ptrbit) - \(entries.count) entries, has current index \(currentIndex != nil ? "YES" : "NO") (\(currentIndex ?? 0))\n"

        for (i, entry) in entries.enumerated() {
            let prefix = (currentIndex == i) ? " * " : " - "
            result += prefix + wtfStringToSwiftString(entry.loggingString())
        }

        return result
    }

    func addChildItem(parentFrameID: FrameIdentifier, frameState: FrameState) {
        guard let currentItem = currentItem() else {
            return;
        }
        guard let parentItem = currentItem.protectedMainFrameItem().childItemForFrameID(parentFrameID) else {
            return;
        }
        parentItem.setChild(frameState);
    }

    func setBackForwardItemIdentifier(frameState: FrameState, itemID: BackForwardItemIdentifier) {
        frameState.itemID = itemID;
        for child in frameState.children {
            setBackForwardItemIdentifier(frameState: child, itemID: itemID);
        }
    }

    func completeFrameStateForNavigation(navigatedFrameState: FrameState) -> FrameState {
        guard let currentItem = currentItem() else {
            return navigatedFrameState;
        }
        guard let navigatedFrameID = navigatedFrameState.getFrameID() else {
            return navigatedFrameState;
        }
        guard let mainFrameItem = currentItem.mainFrameItem() else {
            return navigatedFrameState;
        }
        if mainFrameItem.childItemForFrameID(navigatedFrameID) == nil {
            return navigatedFrameState;
        }
        let frameState = derefRefFrameState(currentItem.mainFrameState());
        setBackForwardItemIdentifier(frameState: frameState, itemID: navigatedFrameState.itemID);
        frameState.replaceChildFrameState(consuming: navigatedFrameState);
        return frameState;
    }

    @_expose(Cxx)
    @_spi(Internal)
    // TODO rename to something more descriptive even back in C++
    // It's called from backForwardAddItem, but calls addItem.
    // What specifically does this layer do?
    public func backForwardAddItemShared(connection: IPC.Connection, navigatedFrameState: FrameState, loadedWebArchive: WebKit.LoadedWebArchive) {
        let process = WebKit.WebProcessProxy.fromConnection(connection);

        let itemURL = WTF.URL.init(navigatedFrameState.urlString);
        let itemOriginalURL = WTF.URL.init(navigatedFrameState.originalURLString);

        // TODO convert all the following once we have platform macros
        // #if PLATFORM(COCOA)
        //     if (linkedOnOrAfterSDKWithBehavior(SDKAlignedBehavior::PushStateFilePathRestriction)
        // #if PLATFORM(MAC)
        //         && !WTF::MacApplication::isMimeoPhotoProject() // rdar://112445672.
        // #endif // PLATFORM(MAC)
        //     ) {
        // #endif // PLATFORM(COCOA)
        //         ASSERT(!itemURL.protocolIsFile() || process->wasPreviouslyApprovedFileURL(itemURL));
        //         MESSAGE_CHECK(process, !itemURL.protocolIsFile() || process->wasPreviouslyApprovedFileURL(itemURL));
        //         MESSAGE_CHECK(process, !itemOriginalURL.protocolIsFile() || process->wasPreviouslyApprovedFileURL(itemOriginalURL));
        // #if PLATFORM(COCOA)
        //     }
        // #endif

        guard let targetFrame = WebKit.WebFrameProxy.webFrame(navigatedFrameState.getFrameID()) else {
            return;
        }

        if targetFrame.isPendingInitialHistoryItem() {
            targetFrame.setIsPendingInitialHistoryItem(false);
            if let parent = targetFrame.parentFrame() {
                addChildItem(parentFrameID: parent.frameID(), frameState: navigatedFrameState);
            }
        }

        guard let webPageProxy = getPageWeakPtr(page) else {
            return;
        }

        let isRemoteFrameNavigation = webPageProxy.isRemoteFrameNavigation(process);
        // TODO this is a good example of 'process' sometimes needing to be two different kinds of pointers.
        // Add to relevant rdar
        let processPtr = derefRefWebProcessProxy(process);
        assert(!isRemoteFrameNavigation || webPageProxy.preferences().siteIsolationEnabled());

        let navigatedFrameID = navigatedFrameState.getFrameID();
        let item = WebBackForwardListItem.create(completeFrameStateForNavigation(navigatedFrameState: navigatedFrameState),
            webPageProxy.identifier(), navigatedFrameID);
        item.setResourceDirectoryURL(webPageProxy.currentResourceDirectoryURL());
        item.setIsRemoteFrameNavigation(isRemoteFrameNavigation);
        if loadedWebArchive == WebKit.LoadedWebArchive.Yes {
            item.setDataStoreForWebArchive(processPtr.websiteDataStore());
        }
        addItem(newItem: item);
    }

    // IPCs from here on

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardAddItem(connection: IPC.Connection, navigatedFrameState: FrameState) {
        // TODO make the following a more idiomatic if let, or similar
        if let page = getPageWeakPtr(page) {
            let loadedWebArchive = page.didLoadWebArchive()
                    ? WebKit.LoadedWebArchive.Yes
                    : WebKit.LoadedWebArchive.No
            backForwardAddItemShared(connection: connection, navigatedFrameState: navigatedFrameState, loadedWebArchive: loadedWebArchive);
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardSetChildItem(frameItemID: BackForwardFrameItemIdentifier, frameState: FrameState) {
        guard let item = currentItem() else {
            return;
        }

        if let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(item.identifier(), frameItemID) {
            frameItem.setChild(consuming: toRefFrameState(frameState));
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardClearChildren(itemID: BackForwardItemIdentifier, frameItemID: BackForwardFrameItemIdentifier) {
        // TODO consider whether it even makes sense for this to be in BackForwardList.
        let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(itemID, frameItemID);
        if let frameItem {
            frameItem.clearChildren();
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardUpdateItem(connection: IPC.Connection, frameState: WebKit.FrameState) {
        guard let itemID = frameState.itemID else {
            return;
        }
        guard let frameItemID = frameState.frameItemID else {
            return;
        }
        guard let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(itemID, frameItemID) else {
            return;
        }
        guard let item = frameItem.backForwardListItem() else {
            return;
        }
        guard let webPageProxy = getPageWeakPtr(page) else {
            return;
        }
        assert(webPageProxy.identifier() == item.pageID() && itemID == item.identifier());
        // TODO the C++ downcasts the APP to a WebProcessProxy
        let process = WebKit.AuxiliaryProcessProxy.fromConnection(connection);
        let hasBackForwardCacheEntry = item.backForwardCacheEntry() != nil;
        if hasBackForwardCacheEntry != frameState.hasCachedPage {
            if frameState.hasCachedPage {
                derefRefWebBackForwardCache(webPageProxy.protectedBackForwardCache()).addEntry(item, process.coreProcessIdentifier());
            } else if !item.suspendedPage() {
                derefRefWebBackForwardCache(webPageProxy.protectedBackForwardCache()).removeEntry(item);
            }
        }

        frameItem.setFrameState(frameState);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardGoToItem(itemID: BackForwardItemIdentifier, completionHandler: (WebBackForwardListCounts) -> ()) {
        // On process swap, we tell the previous process to ignore the load, which causes it so restore its current back forward item to its previous
        // value. Since the load is really going on in a new provisional process, we want to ignore such requests from the committed process.
        // Any real new load in the committed process would have cleared m_provisionalPage.
        if let webPageProxy = getPageWeakPtr(page) {
            if webPageProxy.hasProvisionalPage() {
                backForwardListCounts(completionHandler: completionHandler);
                return;
            }
        }

        backForwardGoToItemShared(itemID: itemID, completionHandler: completionHandler);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardListContainsItem(itemID: BackForwardItemIdentifier, completionHandler: (Bool) -> ()) {
        completionHandler(itemForID(identifier: itemID) != nil);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardGoToItemShared(itemID: BackForwardItemIdentifier, completionHandler: (WebBackForwardListCounts) -> ()) {
        // TODO make MESSAGE_CHECK Swift equivalents
        // if (RefPtr webPageProxy = m_page.get())
        //     MESSAGE_CHECK_COMPLETION(webPageProxy->protectedLegacyMainFrameProcess(), !WebKit::isInspectorPage(*webPageProxy), completionHandler(counts()));

        guard let item = itemForID(identifier: itemID) else {
            backForwardListCounts(completionHandler: completionHandler);
            return;
        }

        goToItem(item: item);
        backForwardListCounts(completionHandler: completionHandler);
    }

    // TODO consider altering the C++ to abstract this too.
    func frameStateForItem(item: WebBackForwardListItem, frameID: FrameIdentifier) -> FrameState {
        // TODO once we have Ref<->Swift interop figured out, work out if we should be
        // calling "protected"MainFrameItem here.
        if let frameItem = derefRefWebBackForwardListFrameItem(item.protectedMainFrameItem()).childItemForFrameID(frameID) {
            return derefRefFrameState(frameItem.copyFrameStateWithChildren());
        } else {
            return derefRefFrameState(item.mainFrameState());
        }
    }

    // TODO figure out where and how best to convert the completionHandler parameter to a Vec
    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardAllItems(frameID: FrameIdentifier, completionHandler: ([FrameState]) -> ()) {
        var frameStates: [FrameState] = [];
        for item in entries {
            frameStates.append(frameStateForItem(item: item, frameID: frameID));
        }
        completionHandler(frameStates);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardItemAtIndex(index: Int32, frameID: FrameIdentifier, completionHandler: (FrameState?) -> ()) {
        // FIXME: This should verify that the web process requesting the item hosts the specified frame.
        let index = Int(index);
        guard let item = itemAtIndex(index: index) else {
            completionHandler(nil);
            return;
        }
        completionHandler(frameStateForItem(item: item, frameID: frameID));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardListCounts(completionHandler: (WebBackForwardListCounts) -> ()) {
        // TODO consider inlining the C++ equivalent before we even get as far as the Swift
        let counts = WebKit.WebBackForwardListCounts.init(backCount: UInt32(backListCount()), forwardCount: UInt32(forwardListCount()));
        completionHandler(counts);
    }
}

#endif // ENABLE_BACKFORWARDLIST_SWIFT
