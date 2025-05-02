internal import WebKit_Internal

@available(WK_IOS_TBA, WK_MAC_TBA, WK_XROS_TBA, *)
@_expose(Cxx)
public func WebBackForwardList_swiftBit_thunk(webBackForwardList: WebKit.WebBackForwardList) {
    return webBackForwardList.swiftBit()
}


@available(WK_IOS_TBA, WK_MAC_TBA, WK_XROS_TBA, *)
@_expose(Cxx)
public func WebBackForwardList_swiftAddItem_thunk(webBackForwardList: WebKit.WebBackForwardList, navigatedFrameState: WebKit.FrameState) {
    return webBackForwardList.swiftAddItem(navigatedFrameState: navigatedFrameState)
}


extension WebKit.WebBackForwardList {
    func swiftBit() {
        print("Hello!");
    }

    func swiftAddItem(navigatedFrameState: WebKit.FrameState) {
        print("Got frame state")
    }
}
