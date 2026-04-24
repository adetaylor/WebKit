// Copyright (C) 2025 Apple Inc. All rights reserved.
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
// INTERRUPTION) IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
// OF THE POSSIBILITY OF SUCH DAMAGE.

#if compiler(>=6.2.3)

#if ENABLE_SEC_ITEM_SHIM && ENABLE_SEC_ITEM_SHIM_PROXY_SWIFT

import Security
import WebKit_Internal

final class SecItemShimProxy {
    private var messageForwarder: RefSecItemShimProxyMessageForwarder?

    init() {
        self.messageForwarder = WebKit.SecItemShimProxyMessageForwarder.create(target: self)
    }

    func getMessageReceiver() -> RefSecItemShimProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    func secItemRequest(request: WebKit.SecItemRequestData, completionHandler: CompletionHandlers.SecItemShimProxy.SecItemRequestCompletionHandler) {
        // Note: unlike the C++ implementation we cannot terminate the connection on invalid data
        // (no connection parameter available in Swift message receiver).
        guard !secItemDictionaryContainsInMemoryObject(secItemRequestQuery(request)) else {
            callCompletionHandlerWithStatus(completionHandler, errSecParam)
            return
        }
        guard !secItemDictionaryContainsInMemoryObject(secItemRequestAttributesToMatch(request)) else {
            callCompletionHandlerWithStatus(completionHandler, errSecParam)
            return
        }
        // unsafe: secItemRequestType returns a C++ value type (rdar://170233903)
        let type = unsafe secItemRequestType(request)
        switch type {
        case .Invalid:
            // TODO(rdar://168139823): LOG_ERROR("SecItemShimProxy::secItemRequest received an invalid data request. Please file a bug if you know how you caused this.")
            callCompletionHandlerWithStatus(completionHandler, errSecParam)
        case .CopyMatching:
            var result: CFTypeRef? = nil
            // unsafe: &result creates an UnsafeMutablePointer
            let resultCode = unsafe SecItemCopyMatching(secItemRequestQuery(request)!, &result)
            callCompletionHandlerWithCopyMatchingResult(completionHandler, resultCode, result)
        case .Add:
            // unsafe: nil for UnsafeMutablePointer<CFTypeRef?>? parameter
            let resultCode = unsafe SecItemAdd(secItemRequestQuery(request)!, nil)
            callCompletionHandlerWithStatus(completionHandler, resultCode)
        case .Update:
            let resultCode = SecItemUpdate(secItemRequestQuery(request)!, secItemRequestAttributesToMatch(request)!)
            callCompletionHandlerWithStatus(completionHandler, resultCode)
        case .Delete:
            let resultCode = SecItemDelete(secItemRequestQuery(request)!)
            callCompletionHandlerWithStatus(completionHandler, resultCode)
        default:
            callCompletionHandlerWithStatus(completionHandler, errSecParam)
        }
    }

    func secItemRequestSync(request: WebKit.SecItemRequestData, completionHandler: CompletionHandlers.SecItemShimProxy.SecItemRequestSyncCompletionHandler) {
        // unsafe: consuming a non-trivially-moveable C++ type into another Swift function
        unsafe secItemRequest(request: request, completionHandler: completionHandler)
    }
}

#endif // ENABLE_SEC_ITEM_SHIM && ENABLE_SEC_ITEM_SHIM_PROXY_SWIFT

#endif // compiler(>=6.2.3)
