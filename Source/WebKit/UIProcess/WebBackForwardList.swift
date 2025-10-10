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
public typealias BackForwardFrameItemIdentifier = WebCore.BackForwardFrameItemIdentifier
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
public typealias WebFrameProxy = WebKit.WebFrameProxy

#if ENABLE_BACKFORWARDLIST_SWIFT

// TODO: some of these utility functions would be better in SwiftUtilities.h
// but can't be put there as we are unable to use swift::Array and swift::String
// rdar://161270632

func toVector(array: [WebBackForwardListItem]) -> VectorRefWebBackForwardListItem {
    var vec = VectorRefWebBackForwardListItem.init();
    for item in array {
        vec.append(consuming: RefWebBackForwardListItem(item));
    }
    return vec;
}

extension String {
    init(wtfString: WTF.String) {
        self = String(wtfString.utf8(WTF.LenientConversion).toStdString())
    }
}

extension WTF.String {
    init(swiftString: String) {
        // rdar://162517354 prevents us from simply writing
        // self = WTF.String.fromUTF8(swiftString.utf8CString.span);
        var wtfString: WTF.String?;
        let span = swiftString.utf8CString.span;
        span.withUnsafeBufferPointer { ptr in
            let cppspan = SpanConstChar(ptr.baseAddress!, span.count);
            wtfString = WTF.String.fromUTF8(cppspan);
        }
        self = wtfString!
    }
}

enum Direction {
    case Backward
    case Forward
}

extension WebKit.WebPageProxyIdentifier: Equatable {
    @_spi(Internal)
    static public func == (lhs: WebKit.WebPageProxyIdentifier, rhs: WebKit.WebPageProxyIdentifier) -> Bool {
        return contentsMatch(lhs, rhs);
    }
}

struct VectorRefFrameStateIterator: Sequence, IteratorProtocol {
    init(vec: VectorRefFrameState) {
        self.vec = vec
        self.pos = 0;
    }
    var vec: VectorRefFrameState;
    var pos: Int;
    mutating func next() -> RefFrameState? {
        if pos >= vec.size() {
            return nil;
        }
        let item = vec.atCopy(pos);
        pos+=1;
        return item;
    }
}

func toVectorRefFrameState(items: [FrameState]) -> VectorRefFrameState {
    var result = VectorRefFrameState.init();
    for item in items {
        result.append(consuming: RefFrameState(item));
    }
    return result;
}

// TODO make efficient
// TODO investigate the extent to which we can make this generic
func toWTFVectorAPIObject(list: [API.Object]) -> API.Array {
    var vec = VectorAPIObject();
    vec.reserveCapacity(list.count);
    for item in list {
        vec.append(consuming: RefPtrAPIObject(item));
    }
    var array = API.Array.create(consuming: vec);
    return array.take();
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
        guard let page = page.get() else {
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
        assert(page.__convertToBool()); // TODO ensure this is similar to ASSERT in C++
        // TODO rename to something less daft
        let definitePage = page.get()!;

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

    func addItem(newItem: WebBackForwardListItem) {
        assertStateOk();

        guard let page = page.get() else {
            return;
        }

        var removedItems: [WebBackForwardListItem] = [];

        if let initialCurrentIndex = currentIndex {
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
                        || lastEntry.protectedNavigatedFrameItem().take().sharesAncestor(newItem.protectedNavigatedFrameItem().take()) {
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
            if entries.count > WebBackForwardListSwift.DefaultCapacity {
                if currentIndex! > 0 {
                    didRemoveItem(item: entries.first!);
                    removedItems.append(entries.removeFirst());
                }

                if entries.isEmpty {
                    currentIndex = nil;
                } else {
                    currentIndex = currentIndex! - 1;
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
            entries[currentIndex] = newItem;
        } else {
            // m_current should never be pointing more than 1 past the end of the entries Vector.
            // If it is, something has gone wrong and we should not try to insert the new item.
            assert(currentIndex <= entries.count);
            if (currentIndex <= entries.count) {
                entries.insert(newItem, at: currentIndex);
            }
        }

        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p added an item. Current size %zu, current index %zu, threw away %zu items", this, m_entries.count, *m_currentIndex, removedItems.count); // TODO
        page.didChangeBackForwardList(newItem, consuming: toVector(array: removedItems));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func goToItem(item: WebBackForwardListItem) {
        assertStateOk();

        guard !entries.isEmpty else {
            return;
        }
        guard let page = page.get() else {
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
            page.logDiagnosticMessage(WebCore.DiagnosticLoggingKeys.backNavigationDeltaKey(),
                WTF.String(swiftString: deltaValue),
                WebCore.ShouldSample.No);
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

        guard page.__convertToBool() else {
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

        guard page.__convertToBool() else {
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

        guard page.__convertToBool() else {
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

        guard page.__convertToBool() else {
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

        guard page.__convertToBool() else {
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

        guard page.__convertToBool() else {
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

        guard page.__convertToBool() else {
            return API.Array.create().take();
        }

        guard let currentIndex = currentIndex else {
            return API.Array.create().take();
        }

        let backListSize = backListCount();
        let size = min(backListSize, Int(limit));
        guard size > 0 else {
            return API.Array.create().take();
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

        guard page.__convertToBool() else {
            return API.Array.create().take();
        }

        guard let currentIndex = currentIndex else {
            return API.Array.create().take();
        }

        let size = min(forwardListCount(), Int(limit));
        guard size > 0 else {
            return API.Array.create().take();
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
        guard let page = page.get() else {
            return; // TODO consider asserting instead; whatever the C++ would have done
        }
        page.didChangeBackForwardList(Optional.none, consuming: toVector(array: entriesCopy));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func clear()  {
        assertStateOk();

        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p clear (has %zu of them)", this, m_entries.count); // TODO

        let size = entries.count;
        guard let page = page.get() else {
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
        page.didChangeBackForwardList(Optional.none, consuming: toVector(array: removedItems));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardListState(filter: WebBackForwardListItemFilter) -> BackForwardListState {
        assertStateOk();

        var backForwardListState = BackForwardListState.init();
        if let currentIndex = currentIndex {
            // TODO consider overflows etc. in this cast
            // TODO may be subject to rdar://129159672
            backForwardListState.currentIndex.pointee = UInt32(currentIndex);
        }

        for (i, entry) in entries.enumerated() {
            if !filter.call(entry) {
                if let stateCurrentIndex = Optional(fromCxx: backForwardListState.currentIndex) {
                    if i < stateCurrentIndex && stateCurrentIndex != 0 {
                        // TODO may be subject to rdar://129159672
                        backForwardListState.currentIndex.pointee = stateCurrentIndex-1;
                    }
                }
                continue;
            }
            backForwardListState.items.append(consuming: entry.mainFrameState())
        }

        if backForwardListState.items.isEmpty() {
            backForwardListState.currentIndex = nil
        } else if let currentIndex = Optional(fromCxx: backForwardListState.currentIndex) {
            if backForwardListState.items.size() <= currentIndex {
                // TODO may be subject to rdar://129159672
                backForwardListState.currentIndex.pointee = UInt32(backForwardListState.items.size())-1;
            }
        }
        return backForwardListState;
    }

    func setBackForwardItemIdentifiers(frameState: FrameState, itemID: BackForwardItemIdentifier) {
        frameState.itemID = MarkableBackForwardItemIdentifier(itemID);
        frameState.frameItemID = MarkableBackForwardFrameItemIdentifier(generateBackForwardFrameItemIdentifier());
        for child in VectorRefFrameStateIterator(vec: frameState.children) {
            setBackForwardItemIdentifiers(frameState: child.take(), itemID: itemID); // TODO ensure child is a reference type
        }
    }

    func createWebBackForwardListItem(state: FrameState, pageIdentifier: WebKit.WebPageProxyIdentifier) -> RefWebBackForwardListItem {
        // rdar://162310543 requires us to pass 'nil' here
        return WebBackForwardListItem.create(consuming: RefFrameState(state), pageIdentifier, state.frameID, nil);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func restoreFromState(backForwardListState: BackForwardListState) {
        guard let page = page.get() else {
            return;
        }

        // FIXME: Enable restoring resourceDirectoryURL.
        entries.removeAll();
        entries.reserveCapacity(backForwardListState.items.size());
        // TODO not as efficient as C++ we're replacing
        for item in VectorRefFrameStateIterator(vec: backForwardListState.items) {
            let stateCopy = item.take().copy().take(); // TODO may not be necessary depending on how we unpack from Refs.
            setBackForwardItemIdentifiers(frameState: stateCopy, itemID: generateBackForwardItemIdentifier());
            currentIndex = entries.isEmpty ? nil : entries.count - 1;
            // FIXME: navigatedFrameID will always be the main frame ID, causing the restored session state to be sent to an incorrect process when going back or forward with site isolation enabled.
            var item = createWebBackForwardListItem(state: stateCopy, pageIdentifier: page.identifier());
            entries.append(item.take());
        }

        // TODO think about overflows
        currentIndex = Optional(fromCxx: backForwardListState.currentIndex).map({ val in Int(val) })
        // LOG(BackForward, "(Back/Forward) WebBackForwardList %p restored from state (has %zu entries)", this, m_entries.count); // TODO
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func setItemsAsRestoredFromSession() {
        for entry in entries {
            entry.setWasRestoredFromSession()
        }
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func setItemsAsRestoredFromSessionIf(functor: WebBackForwardListItemFilter) {
        for entry in entries {
            if functor.call(entry) {
                entry.setWasRestoredFromSession()
            }
        }
    }

    func didRemoveItem(item: WebBackForwardListItem) {
        item.wasRemovedFromBackForwardList();
        let page = page.get()!;
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
            while var unwrappedNextItem = nextItem, unwrappedNextItem.wasCreatedByJSWithoutUserInteraction() {
                item = unwrappedNextItem;
                nextItem = itemAtIndex(index: itemIndex);
                itemIndex += 1;
            }
        }
        return item;
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func loggingString() -> Swift.String {
        // Safety: it's guaranteed to be possible to convert this pointer to a string
        // rdar://162286500
        let ptrbit = unsafe "0x\(Unmanaged.passUnretained(self).toOpaque())"
        var result = "\nWebBackForwardList \(ptrbit) - \(entries.count) entries, has current index \(currentIndex != nil ? "YES" : "NO") (\(currentIndex ?? 0))\n"

        for (i, entry) in entries.enumerated() {
            let prefix = (currentIndex == i) ? " * " : " - "
            result += prefix + String(wtfString: entry.loggingString())
        }

        return result
    }

    func addChildItem(parentFrameID: FrameIdentifier, frameState: FrameState) {
        guard let currentItem = currentItem() else {
            return;
        }
        guard let parentItem = currentItem.protectedMainFrameItem().take().childItemForFrameID(parentFrameID) else {
            return;
        }
        parentItem.setChild(consuming: RefFrameState(frameState));
    }

    func setBackForwardItemIdentifier(frameState: FrameState, itemID: BackForwardItemIdentifier) {
        frameState.itemID = MarkableBackForwardItemIdentifier(itemID);
        for child in VectorRefFrameStateIterator(vec: frameState.children) {
            setBackForwardItemIdentifier(frameState: child.take(), itemID: itemID);
        }
    }

    func completeFrameStateForNavigation(navigatedFrameState: FrameState) -> FrameState {
        guard let currentItem = currentItem() else {
            return navigatedFrameState;
        }
        guard let navigatedFrameID = Optional(fromCxx: navigatedFrameState.frameID) else {
            return navigatedFrameState;
        }
        let mainFrameItem = currentItem.protectedMainFrameItem().take();
        if let mainFrameID = Optional(fromCxx: mainFrameItem.frameID()) {
            if contentsMatch(mainFrameID, navigatedFrameID) {
                return navigatedFrameState;
            }
        }

        if mainFrameItem.childItemForFrameID(navigatedFrameID) == nil {
            return navigatedFrameState;
        }
        let frameState = currentItem.mainFrameState().take();
        setBackForwardItemIdentifier(frameState: frameState, itemID: navigatedFrameState.itemID.value().pointee);
        frameState.replaceChildFrameState(consuming: RefFrameState(navigatedFrameState));
        return frameState;
    }

    @_expose(Cxx)
    @_spi(Internal)
    // TODO rename to something more descriptive even back in C++
    // It's called from backForwardAddItem, but calls addItem.
    // What specifically does this layer do?
    public func backForwardAddItemShared(connection: IPC.Connection, navigatedFrameState: FrameState, loadedWebArchive: WebKit.LoadedWebArchive) {
        let process = WebKit.WebProcessProxy.fromConnection(connection);

        // TODO look up the rdar for the need to pass the nil parameter which is default
        let itemURL = WTF.URL(navigatedFrameState.urlString, nil);
        let itemOriginalURL = WTF.URL(navigatedFrameState.originalURLString, nil);

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

        let navigatedFrameID = navigatedFrameState.frameID;
        let targetFrame = WebFrameProxy.webFrame(navigatedFrameID);

        guard let targetFrame else {
            return;
        }

        if targetFrame.isPendingInitialHistoryItem() {
            targetFrame.setIsPendingInitialHistoryItem(false);
            if let parent = targetFrame.parentFrame() {
                addChildItem(parentFrameID: parent.frameID(), frameState: navigatedFrameState);
            }
        }

        guard let webPageProxy = page.get() else {
            return;
        }

        let isRemoteFrameNavigation = webPageProxy.isRemoteFrameNavigation(process);
        // TODO this is a good example of 'process' sometimes needing to be two different kinds of pointers.
        // Add to relevant rdar
        let processPtr = process.take();
        assert(!isRemoteFrameNavigation || webPageProxy.protectedPreferences().take().siteIsolationEnabled());

        let item = createWebBackForwardListItem(state: navigatedFrameState, pageIdentifier: webPageProxy.identifier()).take();
        item.setResourceDirectoryURL(consuming: webPageProxy.currentResourceDirectoryURL());
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
        if let page = page.get() {
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
            frameItem.setChild(consuming: RefFrameState(frameState));
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
        if !frameState.itemID.__convertToBool() {
            return;
        }
        let itemID = frameState.itemID.value().pointee;
        if !frameState.frameItemID.__convertToBool() {
            return;
        }
        let frameItemID = frameState.frameItemID.value().pointee;
        guard let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(itemID, frameItemID) else {
            return;
        }
        guard let item = frameItem.backForwardListItem() else {
            return;
        }
        guard let webPageProxy = page.get() else {
            return;
        }
        // TODO do the Equatable stuff to allow this assert
        // assert(webPageProxy.identifier() == item.pageID() && itemID == item.identifier());
        let process = WebKit.AuxiliaryProcessProxy.fromConnection(connection);
        // The downcast in C++ is really just used to assert that the process is a WebProcessProxy
        assert(downcastToWebProcessProxy(process).__convertToBool());
        let hasBackForwardCacheEntry = item.protectedBackForwardCacheEntry().__convertToBool();
        if hasBackForwardCacheEntry != frameState.hasCachedPage {
            if frameState.hasCachedPage {
                webPageProxy.protectedBackForwardCache().take().addEntry(item, process.coreProcessIdentifier());
            } else if !item.hasSuspendedPage() {
                webPageProxy.protectedBackForwardCache().take().removeEntry(item);
            }
        }

        frameItem.setFrameState(consuming: RefFrameState(frameState));
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardGoToItem(itemID: BackForwardItemIdentifier) -> WebBackForwardListCounts {
        // On process swap, we tell the previous process to ignore the load, which causes it so restore its current back forward item to its previous
        // value. Since the load is really going on in a new provisional process, we want to ignore such requests from the committed process.
        // Any real new load in the committed process would have cleared m_provisionalPage.
        if let webPageProxy = page.get() {
            if webPageProxy.hasProvisionalPage() {
                return backForwardListCounts();
            }
        }

        return backForwardGoToItemShared(itemID: itemID);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardListContainsItem(itemID: BackForwardItemIdentifier) -> Bool{
        return itemForID(identifier: itemID) != nil;
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardGoToItemShared(itemID: BackForwardItemIdentifier) -> WebBackForwardListCounts {
        // TODO make MESSAGE_CHECK Swift equivalents
        // if (RefPtr webPageProxy = m_page.get())
        //     MESSAGE_CHECK_COMPLETION(webPageProxy->protectedLegacyMainFrameProcess(), !WebKit::isInspectorPage(*webPageProxy), completionHandler(counts()));

        guard let item = itemForID(identifier: itemID) else {
            return backForwardListCounts();
        }

        goToItem(item: item);
        return backForwardListCounts();
    }

    // TODO consider altering the C++ to abstract this too.
    func frameStateForItem(item: WebBackForwardListItem, frameID: FrameIdentifier) -> FrameState {
        if let frameItem = item.protectedMainFrameItem().take().childItemForFrameID(frameID) {
            return frameItem.copyFrameStateWithChildren().take();
        } else {
            return item.mainFrameState().take();
        }
    }

    // TODO figure out where and how best to convert the completionHandler parameter to a Vec
    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardAllItems(frameID: FrameIdentifier) -> VectorRefFrameState{
        var frameStates: [FrameState] = [];
        for item in entries {
            frameStates.append(frameStateForItem(item: item, frameID: frameID));
        }
        return toVectorRefFrameState(items: frameStates);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardItemAtIndex(index: Int32, frameID: FrameIdentifier) -> FrameState?{
        // FIXME: This should verify that the web process requesting the item hosts the specified frame.
        let index = Int(index);
        guard let item = itemAtIndex(index: index) else {
            return nil;
        }
        return frameStateForItem(item: item, frameID: frameID);
    }

    @_expose(Cxx)
    @_spi(Internal)
    public func backForwardListCounts() -> WebBackForwardListCounts {
        // TODO consider inlining the C++ equivalent before we even get as far as the Swift
        return WebKit.WebBackForwardListCounts.init(backCount: UInt32(backListCount()), forwardCount: UInt32(forwardListCount()));
    }
}

#endif // ENABLE_BACKFORWARDLIST_SWIFT
