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

internal import WebKit_Internal
internal import wtf

internal typealias BackForwardFrameItemIdentifier = WebCore.BackForwardFrameItemIdentifier
internal typealias FrameIdentifier = WebCore.FrameIdentifier
internal typealias WebBackForwardListItem = WebKit.WebBackForwardListItem
internal typealias WebBackForwardListCounts = WebKit.WebBackForwardListCounts
internal typealias BackForwardListState = WebKit.BackForwardListState
internal typealias FrameState = WebKit.FrameState
internal typealias WebPageProxy = WebKit.WebPageProxy
internal typealias WebFrameProxy = WebKit.WebFrameProxy

// TODO ensure all this code complies with:
// never to return a refcounted type from Swift to C++
// due to https://www.swift.org/documentation/cxx-interop/#:~:text=methods.-,Exposing%20C++%20Shared%20Reference%20Types%20back%20from%20Swift,-C

#if ENABLE_BACKFORWARDLIST_SWIFT

// Some of these utility functions would be better in SwiftUtilities.h
// but can't be put there as we are unable to use swift::Array and swift::String
// rdar://161270632

extension VectorRefWebBackForwardListItem {
    init (array: [WebBackForwardListItem]) {
        // Safety: false positive, rdar://163805967
        var vec = unsafe VectorRefWebBackForwardListItem.init();
        for item in array {
        // Safety: false positive, rdar://163805967
            unsafe vec.append(consuming: RefWebBackForwardListItem(item));
        }
        // Safety: false positive, rdar://163805967
        unsafe self = unsafe vec;
    }
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
        // Safety - we are guaranteed to get a valid buffer from the Swift
        // string for the duration that we're using it to construct the WTF::String.
        // The WTF::String will take a copy.
        var wtfString: WTF.String?;
        let span = swiftString.utf8CString.span;
        unsafe span.withUnsafeBufferPointer { ptr in
            // Warning here is rdar://163018821
            let cppspan = unsafe SpanConstChar(ptr.baseAddress!, span.count);
            wtfString = unsafe WTF.String.fromUTF8(cppspan);
        }
        self = wtfString!
    }
}

extension VectorRefFrameState {
    init (items: [FrameState]) {
        var result = VectorRefFrameState.init();
        for item in items {
            result.append(consuming: RefFrameState(item));
        }
        self = result;
    }
}

extension API.Array {
    // Can't be a designated initializer because we can't see private fields.
    static func create(list: [API.Object]) -> API.Array {
        var vec = VectorAPIObject();
        vec.reserveCapacity(list.count);
        for item in list {
            vec.append(consuming: RefPtrAPIObject(item));
        }
        let array = API.Array.create(consuming: vec);
        return array.take();
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
        // Safety: we'll make a copy of the referent
        // before the vector goes out of scope. It's guaranteed
        // to have a valid lifetime, be initialized, and be
        // within the vector bounds.
        let item = vec.__atUnsafe(pos);
        pos+=1;
        return item.pointee.copyRef();
    }
}

func backForwardLog(msgCreator: () -> String) {
    if !willLog() {
        return;
    }
    let msg = msgCreator();

    let span = msg.utf8CString.span;
    // Safety: the buffer pointer is guaranteed to be
    // valid and null-terminated during the call to
    // doLog
    unsafe span.withUnsafeBufferPointer { ptr in
        unsafe doLog(ptr.baseAddress!);
    }
}

func loadingReleaseLog(msgCreator: () -> String) {
    let msg = msgCreator();

    let span = msg.utf8CString.span;
    // Safety: the buffer pointer is guaranteed to be
    // valid and null-terminated during the call to
    // doLoadingReleaseLog
    unsafe span.withUnsafeBufferPointer { ptr in
        unsafe doLoadingReleaseLog(ptr.baseAddress!);
    }
}

func messageCheck(process: RefWebProcessProxy, assertion: () -> Bool, _file: String = #file, _line: Int = #line) {
    // TODO - a future version of this would be enhanced to use the _file and _line
    if !assertion() {
        messageCheckFailed(process);
    }
}

enum Direction {
    case Backward
    case Forward
}

@_expose(Cxx)
internal class WebBackForwardListWeakRef {
    weak var list: WebBackForwardList?;
    init(list: WebBackForwardList) {
        self.list = list
    }

    @_expose(Cxx)
    internal func getUnderlyingList() -> WebBackForwardList {
        return list!
    }
}

@_expose(Cxx)
internal class WebBackForwardList {
    static let DefaultCapacity = 100;

    var page: WeakPtrWebPageProxy;
    var entries: [WebBackForwardListItem] = [];
    var currentIndex: Array.Index?;
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    var messageForwarder: RefWebBackForwardListMessageForwarder?;

    func myPtr() -> Int {
        // Safety: it's guaranteed to be possible to convert this pointer to a string
        // rdar://162286500
        return Int(bitPattern: unsafe Unmanaged.passUnretained(self).toOpaque());
    }

    @_expose(Cxx)
    internal init(page: WeakPtrWebPageProxy) {
        self.page = page
        let weakRefContainer = WebBackForwardListWeakRef(list: self);
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        self.messageForwarder = unsafe WebKit.WebBackForwardListMessageForwarder.create(OpaquePointer(Unmanaged.passRetained(weakRefContainer).toOpaque()));
        backForwardLog(msgCreator: {
            return "(Back/Forward) Created WebBackForwardList \(myPtr())";
        });
    }

    @_expose(Cxx)
    internal func getMessageReceiver() -> RefWebBackForwardListMessageForwarder {
        return self.messageForwarder!;
    }

    @_expose(Cxx)
    internal func preDestructionChecks() {
        // A WebBackForwardList should never be destroyed unless it s associated page has been closed or is invalid.
        assert(page.get().map { !$0.hasRunningProcess() } ?? (currentIndex == nil))
    }

    @_expose(Cxx)
    internal func itemForID(identifier: BackForwardItemIdentifier) -> WebBackForwardListItem? {
        // TODO consider restructuring this a bit. It's a bit odd that it basically refers
        // to a map within WebBackForwardListItem. Maybe WebBackForwardList should
        // own that map.
        // TODO think more about how this gets converted to a RefPtr on return.
        guard let page = page.get() else {
            return nil
        }

        let item = WebBackForwardListItem.itemForID(identifier);
        guard let item else {
            return nil;
        }

        // We can't use == here due to rdar://162357139
        assert(contentsMatch(item.pageID(), page.identifier()));
        return item;
    }

    @_expose(Cxx)
    internal func pageClosed() {
        backForwardLog(msgCreator: {
            return "(Back/Forward) WebBackForwardList \(myPtr()) had its page closed with current size \(entries.count)";
        });

        // We should have always started out with an m_page and we should never close the page twice
        assert(page.__convertToBool());
        if page.__convertToBool() {
            for item in entries {
                didRemoveItem(item: item);
            }
        }

        page.clear();
        entries.removeAll();
        currentIndex = nil;
    }

    func assertStateOk() {
        assert(currentIndex.map { $0 < entries.count } ?? true)
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
            if entries.count > WebBackForwardList.DefaultCapacity {
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

        backForwardLog(msgCreator: {
            return "(Back/Forward) WebBackForwardList \(myPtr()) added an item. Current size \(entries.count), current index \(currentIndex), threw away \(removedItems.count) items";
        });
        // Safety: false positive, rdar://163805967
        unsafe page.didChangeBackForwardList(newItem, consuming: VectorRefWebBackForwardListItem(array: removedItems));
    }

    @_expose(Cxx)
    internal func goToItem(item: WebBackForwardListItem) {
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

        let targetIndex = entries.firstIndex(where: { identitiesMatch($0, item) });

        // If the target item wasn't even in the list, there's nothing else to do.
        guard var targetIndex else {
            backForwardLog(msgCreator: {
                let identifier = String(wtfString: item.identifier().toString());
                let url = String(wtfString: item.urlCopy());
                return "(Back/Forward) WebBackForwardList \(myPtr()) could not go to item \(identifier) (\(url)) because it was not found";
            });
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
        if !identitiesMatch(currentItem, item) {
            page.recordAutomaticNavigationSnapshot();
            shouldKeepCurrentItem = page.shouldKeepCurrentBackForwardListItemInList(currentItem);
        }

        // If the client said to remove the current item, remove it and then update the target index.
        var removedItems: [WebBackForwardListItem] = [];
        if (!shouldKeepCurrentItem) {
            removedItems.append(entries.remove(at: priorCurrentIndex));
            targetIndex = entries.firstIndex(where: { identitiesMatch($0, item) })!;
        }

        currentIndex = targetIndex;

        backForwardLog(msgCreator: {
            let itemIdentifier = String(wtfString: item.identifier().toString());
            return "(Back/Forward) WebBackForwardList \(myPtr()) going to item \(itemIdentifier), is now at index \(targetIndex)";
        });
        // Safety: false positive, rdar://163805967
        unsafe page.didChangeBackForwardList(Optional.none, consuming: VectorRefWebBackForwardListItem(array: removedItems));
    }

    @_expose(Cxx)
    internal func currentItem() -> WebBackForwardListItem? {
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
    internal func backItem() -> WebBackForwardListItem? {
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
    internal func forwardItem() -> WebBackForwardListItem? {
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
    internal func itemAtIndex(index: Array.Index) -> WebBackForwardListItem? {
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
    internal func backListCount() -> Array.Index {
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
    internal func forwardListCount() -> Array.Index {
        assertStateOk();

        guard page.__convertToBool() else {
            return 0;
        }

        guard let currentIndex = currentIndex else {
            return 0;
        }
        return entries.count - (currentIndex + 1);
    }

    @_expose(Cxx)
    internal func backListAsAPIArrayWithLimit(limit: UInt) -> API.Array {
        assertStateOk();

        guard page.__convertToBool() else {
            return API.Array.create().take();
        }

        if currentIndex == nil {
            return API.Array.create().take();
        }

        let backListSize = backListCount();
        let size = min(backListSize, Int(limit));
        guard size > 0 else {
            return API.Array.create().take();
        }
        assert(backListSize >= size);
        let startIndex = backListSize - size;

        return API.Array.create(list: entries[startIndex..<startIndex + size].map { toAPIObject($0) })
    }

    @_expose(Cxx)
    internal func forwardListAsAPIArrayWithLimit(limit: UInt) -> API.Array {
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
        return API.Array.create(list: entries[startIndex..<startIndex+size].map { toAPIObject($0) })
    }

    @_expose(Cxx)
    internal func removeAllItems()  {
        assertStateOk();

        backForwardLog(msgCreator: {
            "(Back/Forward) WebBackForwardList \(myPtr()) removeAllItems (has \(entries.count) of them)";
        });

        for item in entries {
            didRemoveItem(item: item);
        }
        currentIndex = nil;

        let entriesCopy = entries;
        entries.removeAll();
        guard let page = page.get() else {
            return; // TODO consider asserting instead; whatever the C++ would have done
        }
        // Safety: false positive, rdar://163805967
        unsafe page.didChangeBackForwardList(Optional.none, consuming: VectorRefWebBackForwardListItem(array: entriesCopy));
    }

    @_expose(Cxx)
    internal func clear()  {
        assertStateOk();

        backForwardLog(msgCreator: {
            "(Back/Forward) WebBackForwardList \(myPtr()) clear (has \(entries.count) of them)";
        });

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
            if !identitiesMatch(item, currentItem) {
                didRemoveItem(item: item);
            }
        }

        var removedItems: [WebBackForwardListItem] = [];
        removedItems.reserveCapacity(size-1);

        // TODO this was previously done in terms of indices, there might be a reason
        for item in entries {
            if !identitiesMatch(item, currentItem) {
                removedItems.append(item);
            }
        }

        currentIndex = 0;
        entries.removeAll();
        entries.append(currentItem);
        // Safety: false positive, rdar://163805967
        unsafe page.didChangeBackForwardList(nil, consuming: VectorRefWebBackForwardListItem(array: removedItems));
    }

    @_expose(Cxx)
    internal func backForwardListState(filter: WebBackForwardListItemFilter) -> BackForwardListState {
        assertStateOk();

        var backForwardListState = BackForwardListState.init();
        if let currentIndex = currentIndex {
            // May be subject to rdar://129159672
            backForwardListState.currentIndex.pointee = UInt32(currentIndex);
        }

        for (i, entry) in entries.enumerated() {
            if !filter.call(entry) {
                if let stateCurrentIndex = Optional(fromCxx: backForwardListState.currentIndex) {
                    if i < stateCurrentIndex && stateCurrentIndex != 0 {
                        // May be subject to rdar://129159672
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
                // May be subject to rdar://129159672
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
        // Safety: it's OK to pass a null pointer to this function; in fact that's the default
        return unsafe WebBackForwardListItem.create(consuming: RefFrameState(state), pageIdentifier, state.frameID, nil);
    }

    @_expose(Cxx)
    internal func restoreFromState(backForwardListState: BackForwardListState) {
        guard let page = page.get() else {
            return;
        }

        // FIXME: Enable restoring resourceDirectoryURL.
        entries.removeAll();
        entries.reserveCapacity(backForwardListState.items.size());
        for item in VectorRefFrameStateIterator(vec: backForwardListState.items) {
            let stateCopy = item.take().copy().take();
            setBackForwardItemIdentifiers(frameState: stateCopy, itemID: generateBackForwardItemIdentifier());
            currentIndex = entries.isEmpty ? nil : entries.count - 1;
            // FIXME: navigatedFrameID will always be the main frame ID, causing the restored session state to be sent to an incorrect process when going back or forward with site isolation enabled.
            // Safety: false positive, rdar://163805967
            let item = unsafe createWebBackForwardListItem(state: stateCopy, pageIdentifier: page.identifier());    
            // Safety: false positive, rdar://163805967
            unsafe entries.append(item.take());
        }

        currentIndex = Optional(fromCxx: backForwardListState.currentIndex).map({ val in Int(val) })
        backForwardLog(msgCreator: {
            "(Back/Forward) WebBackForwardList \(myPtr()) restored from state (has \(entries.count) entries)";
        });
    }

    @_expose(Cxx)
    internal func setItemsAsRestoredFromSession() {
        for entry in entries {
            entry.setWasRestoredFromSession()
        }
    }

    @_expose(Cxx)
    internal func setItemsAsRestoredFromSessionIf(functor: WebBackForwardListItemFilter) {
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
        // TODO SWIFT expose platform macros to Swift to remove the following call on most platforms
        item.setNullSnapshot();
    }

    @_expose(Cxx)
    internal func goBackItemSkippingItemsWithoutUserGesture() -> WebBackForwardListItem? {
        return itemSkippingBackForwardItemsAddedByJSWithoutUserGesture(direction: Direction.Backward);
    }

    @_expose(Cxx)
    internal func goForwardItemSkippingItemsWithoutUserGesture() -> WebBackForwardListItem? {
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

        // TODO - see if these platform macros are getting through
#if PLATFORM_COCOA
        if !WTF.linkedOnOrAfterSDKWithBehavior(WTF.SDKAlignedBehavior.UIBackForwardSkipsHistoryItemsWithoutUserGesture) {
            return item;
        }
#endif

        // For example:
        // Yahoo -> Yahoo#a (no userInteraction) -> Google -> Google#a (no user interaction) -> Google#b (no user interaction)
        // If we're on Google and navigate back, we don't want to skip anything and load Yahoo#a.
        // However, if we're on Yahoo and navigate forward, we do want to skip items and end up on Google#b.
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

            loadingReleaseLog(msgCreator: {
                "UI Navigation is skipping a WebBackForwardListItem because it was added by JavaScript without user interaction";
            });
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

            loadingReleaseLog(msgCreator: {
                "UI Navigation is skipping a WebBackForwardListItem that has user interaction because we started on an item that didn't have interaction";
            });
        } else {
            // If going forward and there are items that we created by JS without user interaction, move forward to the last
            // one in the series.
            var nextItem = itemAtIndex(index: itemIndex + 1);
            while let unwrappedNextItem = nextItem, unwrappedNextItem.wasCreatedByJSWithoutUserInteraction() {
                item = unwrappedNextItem;
                itemIndex += 1;
                nextItem = itemAtIndex(index: itemIndex);
            }
        }
        return item;
    }

    @_expose(Cxx)
    internal func loggingString() -> Swift.String {
        var result = "\nWebBackForwardList \(myPtr()) - \(entries.count) entries, has current index \(currentIndex != nil ? "YES" : "NO") (\(currentIndex ?? 0))\n"

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
        let itemID = navigatedFrameState.itemID.pointee;
        setBackForwardItemIdentifier(frameState: frameState, itemID: itemID);
        frameState.replaceChildFrameState(consuming: RefFrameState(navigatedFrameState));
        return frameState;
    }

    @_expose(Cxx)
    // TODO rename to something more descriptive even back in C++
    // It's called from backForwardAddItem, but calls addItem.
    // What specifically does this layer do?
    internal func backForwardAddItemShared(connection: IPC.Connection, navigatedFrameState: FrameState, loadedWebArchive: WebKit.LoadedWebArchive) {
        let process = WebKit.WebProcessProxy.fromConnection(connection);

        // 'nil' works around rdar://162310543
        // Safety: it's OK to pass a null pointer to these two functions; in fact it's the default
        let itemURL = unsafe WTF.URL(navigatedFrameState.urlString, nil);
        let itemOriginalURL = unsafe WTF.URL(navigatedFrameState.originalURLString, nil);

#if PLATFORM_COCOA
#if PLATFORM_MAC
        let do_message_checks = WTF.linkedOnOrAfterSDKWithBehavior(WTF.SDKAlignedBehavior.PushStateFilePathRestriction)
            && !WTF.MacApplication.isMimeoPhotoProject();  // rdar://112445672.
#else
        let do_message_checks = WTF.linkedOnOrAfterSDKWithBehavior(WTF.SDKAlignedBehavior.PushStateFilePathRestriction);
#endif
        if do_message_checks {
            assert(!itemURL.protocolIsFile() || process.wasPreviouslyApprovedFileURL(itemURL));
            messageCheck(process, !itemURL.protocolIsFile() || process.take().wasPreviouslyApprovedFileURL(itemURL));
            messageCheck(process, !itemOriginalURL.protocolIsFile() || process.take().wasPreviouslyApprovedFileURL(itemOriginalURL));
        }
#endif

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
        let processPtr = process.take();
        assert(!isRemoteFrameNavigation || webPageProxy.protectedPreferences().take().siteIsolationEnabled());

        // Safety: false positive, rdar://163805967
        let item = unsafe createWebBackForwardListItem(state: navigatedFrameState, pageIdentifier: webPageProxy.identifier()).take();
        item.setResourceDirectoryURL(consuming: webPageProxy.currentResourceDirectoryURL());
        item.setIsRemoteFrameNavigation(isRemoteFrameNavigation);
        if loadedWebArchive == WebKit.LoadedWebArchive.Yes {
            item.setDataStoreForWebArchive(processPtr.websiteDataStore());
        }
        addItem(newItem: item);
    }

    // IPCs from here on

    @_expose(Cxx)
    internal func backForwardAddItem(connection: IPC.Connection, navigatedFrameState: RefFrameState) {
        if let page = page.get() {
            let loadedWebArchive = page.didLoadWebArchive()
                    ? WebKit.LoadedWebArchive.Yes
                    : WebKit.LoadedWebArchive.No
            backForwardAddItemShared(connection: connection, navigatedFrameState: navigatedFrameState.take(), loadedWebArchive: loadedWebArchive);
        }
    }

    @_expose(Cxx)
    internal func backForwardSetChildItem(frameItemID: BackForwardFrameItemIdentifier, frameState: RefFrameState) {
        guard let item = currentItem() else {
            return;
        }

        if let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(item.identifier(), frameItemID) {
            frameItem.setChild(consuming: frameState);
        }
    }

    @_expose(Cxx)
    internal func backForwardClearChildren(itemID: BackForwardItemIdentifier, frameItemID: BackForwardFrameItemIdentifier) {
        // TODO consider whether it even makes sense for this to be in BackForwardList.
        let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(itemID, frameItemID);
        if let frameItem {
            frameItem.clearChildren();
        }
    }

    @_expose(Cxx)
    internal func backForwardUpdateItem(connection: IPC.Connection, frameState: RefFrameState) {
        let itemID = frameState.take().itemID.pointee;
        let frameItemID = frameState.take().frameItemID.pointee;
        guard let frameItem = WebKit.WebBackForwardListFrameItem.itemForID(itemID, frameItemID) else {
            return;
        }
        guard let item = frameItem.backForwardListItem() else {
            return;
        }
        guard let webPageProxy = page.get() else {
            return;
        }
        // We can't use == here due to rdar://162357139
        assert(contentsMatch(webPageProxy.identifier(), item.pageID()) && contentsMatch(itemID, item.identifier()));
        if let process = WebKit.AuxiliaryProcessProxy.fromConnection(connection) {
            // The downcast in C++ is really just used to assert that the process is a WebProcessProxy
            assert(downcastToWebProcessProxy(process).__convertToBool());
            let hasBackForwardCacheEntry = item.protectedBackForwardCacheEntry().__convertToBool();
            if hasBackForwardCacheEntry != frameState.take().hasCachedPage {
                if frameState.take().hasCachedPage {
                    webPageProxy.protectedBackForwardCache().take().addEntry(item, process.coreProcessIdentifier());
                } else if !item.hasSuspendedPage() {
                    webPageProxy.protectedBackForwardCache().take().removeEntry(item);
                }
            }

            frameItem.setFrameState(consuming: frameState);
        }
    }

    @_expose(Cxx)
    internal func backForwardGoToItem(itemID: BackForwardItemIdentifier, completionHandler: ConstCountsCompletionHandler) {
        // On process swap, we tell the previous process to ignore the load, which causes it so restore its current back forward item to its previous
        // value. Since the load is really going on in a new provisional process, we want to ignore such requests from the committed process.
        // Any real new load in the committed process would have cleared m_provisionalPage.
        if let webPageProxy = page.get() {
            if webPageProxy.hasProvisionalPage() {
            completionHandler.call(WebKit.WebBackForwardListCounts(backCount: UInt32(backListCount()), forwardCount: UInt32(forwardListCount())));
            return;
            }
        }

        backForwardGoToItemShared(itemID: itemID, completionHandler: completionHandler);
    }

    @_expose(Cxx)
    internal func backForwardListContainsItem(itemID: BackForwardItemIdentifier, completionHandler: BoolCompletionHandler) {
        completionHandler.call(itemForID(identifier: itemID) != nil);
    }

    @_expose(Cxx)
    internal func backForwardGoToItemShared(itemID: BackForwardItemIdentifier, completionHandler: ConstCountsCompletionHandler) {
        // TODO SWIFT make MESSAGE_CHECK Swift equivalents
        // if (RefPtr webPageProxy = m_page.get())
        //     MESSAGE_CHECK_COMPLETION(webPageProxy->protectedLegacyMainFrameProcess(), !WebKit::isInspectorPage(*webPageProxy), completionHandler(counts()));

        guard let item = itemForID(identifier: itemID) else {
            completionHandler.call(WebKit.WebBackForwardListCounts(backCount: UInt32(backListCount()), forwardCount: UInt32(forwardListCount())));
            return;
        }

        goToItem(item: item);
        completionHandler.call(WebKit.WebBackForwardListCounts(backCount: UInt32(backListCount()), forwardCount: UInt32(forwardListCount())));
    }

    // TODO consider altering the C++ to abstract this too.
    func frameStateForItem(item: WebBackForwardListItem, frameID: FrameIdentifier) -> FrameState {
        if let frameItem = item.protectedMainFrameItem().take().childItemForFrameID(frameID) {
            return frameItem.copyFrameStateWithChildren().take();
        } else {
            return item.mainFrameState().take();
        }
    }

    @_expose(Cxx)
    internal func backForwardAllItems(frameID: FrameIdentifier, completionHandler: VectorRefFrameStateCompletionHandler) {
        var frameStates: [FrameState] = [];
        for item in entries {
            frameStates.append(frameStateForItem(item: item, frameID: frameID));
        }
        // Safety: believed to be a false positive, rdar://162608225
        unsafe completionHandler.call(consuming: VectorRefFrameState(items: frameStates));
    }

    @_expose(Cxx)
    internal func backForwardItemAtIndex(index: Int32, frameID: FrameIdentifier, completionHandler: RefPtrFrameStateCompletionHandler) {
        // FIXME: This should verify that the web process requesting the item hosts the specified frame.
        let index = Int(index);
        guard let item = itemAtIndex(index: index) else {
            // Safety: believed to be a false positive, rdar://162608225
            unsafe completionHandler.call(consuming: RefPtrFrameState());
            return;
        }
        let frameState = frameStateForItem(item: item, frameID: frameID);
        // Safety: believed to be a false positive, rdar://162608225
        unsafe completionHandler.call(consuming: RefPtrFrameState(frameState));
    }

    @_expose(Cxx)
    internal func backForwardListCounts(completionHandler: CountsCompletionHandler) {
        // TODO consider inlining the C++ equivalent before we even get as far as the Swift
        // Safety: believed to be a false positive, rdar://162608225
        unsafe completionHandler.call(consuming: WebKit.WebBackForwardListCounts(backCount: UInt32(backListCount()), forwardCount: UInt32(forwardListCount())));
    }
}

#endif // ENABLE_BACKFORWARDLIST_SWIFT
