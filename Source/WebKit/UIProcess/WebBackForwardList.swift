// Copyright (C) 2025-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if compiler(>=6.2)

internal import WebCore_Private
internal import WebKit_Internal
internal import wtf

#if ENABLE_BACK_FORWARD_LIST_SWIFT

// A note on swift-format-ignore: NeverForceUnwrap:
// This file currently aims to closely adhere to the C++ original which uses
// RefPtr.get() and friends frequently; this is functionally similar to force
// unwrapping so that's been retained.

// rdar://164119356 may allow us to automate some of these conformances
// using SWIFT_CONFORMS_TO_PROTOCOL
extension RefFrameState: CxxRef {
    typealias Pointee = WebKit.FrameState
}

extension RefWebBackForwardListItem: CxxRef {
    typealias Pointee = WebKit.WebBackForwardListItem
}

extension VectorRefFrameState: CxxRefVector {
    typealias Element = RefFrameState
}

extension VectorRefWebBackForwardListItem: CxxRefVector {
    typealias Element = RefWebBackForwardListItem
}

// Some of these utility functions would be better in WebBackForwardListSwiftUtilities.h
// but can't be put there as we are unable to use swift::Array and swift::String
// rdar://161270632

// Temporary partial WTF logging support from Swift
// rdar://168139823 is the task of exposing WebKit logging properly in Swift
private func backForwardLog(msgCreator: () -> String) {
    // rdar://133777029 likely will allow us to avoid the performance penalty
    // of creating the string if logging is disabled.
    let msg = msgCreator()

    let span = msg.utf8CString.span
    // Safety: the buffer pointer is guaranteed to be
    // valid and null-terminated during the call to
    // doLog
    unsafe span.withUnsafeBufferPointer { ptr in
        // swift-format-ignore: NeverForceUnwrap
        unsafe doLog(ptr.baseAddress!)
    }
}

private func loadingReleaseLog(msgCreator: () -> String) {
    let msg = msgCreator()

    let span = msg.utf8CString.span
    // Safety: the buffer pointer is guaranteed to be
    // valid and null-terminated during the call to
    // doLoadingReleaseLog
    unsafe span.withUnsafeBufferPointer { ptr in
        // swift-format-ignore: NeverForceUnwrap
        unsafe doLoadingReleaseLog(ptr.baseAddress!)
    }
}

// Temporary partial MESSAGE_CHECK_BASE support from Swift
// Idiomatic equivalent represented by rdar://168139740
private func messageCheck(process: RefWebProcessProxy, assertion: () -> Bool) -> Bool {
    messageCheckCompletion(process: process, assertion: assertion, completionHandler: {})
}

private func messageCheckCompletion(process: RefWebProcessProxy, assertion: () -> Bool, completionHandler: () -> Void) -> Bool {
    if !assertion() {
        messageCheckFailed(process)
        completionHandler()
        return true
    }
    return false
}

final class WebBackForwardList {

    var page: WeakPtrWebPageProxy
    // Optional just because of an initialization order issue.
    // Always occupied after initialization finished.
    var messageForwarder: RefWebBackForwardListMessageForwarder?
    // Although the BackForwardList is in Swift, we retain a C++
    // API::Object subclass because Swift can't yet inherit from C++ -
    // rdar://163102366
    // Always occupied after construction
    var apiImpl: RefWebBackForwardListAPIImpl?

    init(page: WeakPtrWebPageProxy) {
        self.page = page
        self.messageForwarder = WebKit.WebBackForwardListMessageForwarder.create(target: self)
    }

    func webPageProxyDestroyed() {
        // Break the reference cycle between the Swift WebBackForwardList and the C++ WebBackForwardListAPIImpl
        self.apiImpl = nil
    }

    func getMessageReceiver() -> RefWebBackForwardListMessageForwarder {
        // Guaranteed to be Some after construction
        // swift-format-ignore: NeverForceUnwrap
        self.messageForwarder!
    }

    func getAPIImpl() -> RefWebBackForwardListAPIImpl {
        if let apiImpl = self.apiImpl {
            return apiImpl
        }
        // Safety: we're creating a pointer which will immediately be stored in a
        // proper ref-counted reference on the C++ side before this call returns.
        // Workaround for rdar://163107752.
        let apiImpl = WebKit.WebBackForwardListAPIImpl.create(
            unsafe OpaquePointer(
                Unmanaged.passRetained(self).toOpaque()
            )
        )
        self.apiImpl = apiImpl
        return apiImpl
    }
}

#endif // ENABLE_BACK_FORWARD_LIST_SWIFT

#endif // compiler(>=6.2)
