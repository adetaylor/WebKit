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
        print("Got frame state")
    }
}
