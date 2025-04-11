internal import WebKit_Internal

@available(WK_IOS_TBA, WK_MAC_TBA, WK_XROS_TBA, *)
@_expose(Cxx)
public func WebBackForwardList_swiftBit_thunk(webBackForwardList: WebKit.WebBackForwardList) {
    return webBackForwardList.swiftBit()
}

extension WebKit.WebBackForwardList {
    func swiftBit() {
        print("Hello!");
    }
}