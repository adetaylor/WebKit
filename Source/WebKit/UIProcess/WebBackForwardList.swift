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
