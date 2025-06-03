internal import WebKit_Internal

@available(WK_IOS_TBA, WK_MAC_TBA, WK_XROS_TBA, *)
@_expose(Cxx)
public func WebBackForwardList_swiftBit_thunk(webBackForwardList: WebKit.WebBackForwardList) {
    return webBackForwardList.swiftBit()
}


@available(WK_IOS_TBA, WK_MAC_TBA, WK_XROS_TBA, *)
@_expose(Cxx)
public func WebBackForwardList_swiftAddItem_thunk(webBackForwardList: WebKit.WebBackForwardList, connection: IPC.Connection, navigatedFrameState: WebKit.FrameState) {
    return webBackForwardList.swiftAddItem(connection: connection, navigatedFrameState: navigatedFrameState)
}


extension WebKit.WebBackForwardList {
    func swiftBit() {
        print("Hello!");
    }

    func swiftAddItem(connection: IPC.Connection, navigatedFrameState: WebKit.FrameState) {
        /*
            if (RefPtr webPageProxy = m_page.get()) {
        backForwardAddItemShared(connection, WTFMove(navigatedFrameState), webPageProxy->didLoadWebArchive() ? LoadedWebArchive::Yes : LoadedWebArchive::No);
        }
        */
        if let webPageProxy: WebKit.WebPageProxy = self.getPage() {
            let web_archive = webPageProxy.didLoadWebArchive() ? WebKit.LoadedWebArchive.Yes : WebKit.LoadedWebArchive.No;
            self.backForwardAddItemShared2(connection, navigatedFrameState, web_archive);
        }
    }
}
