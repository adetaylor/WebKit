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

import Foundation
import Security
import WebKit_Internal

// Validates that a dictionary received over IPC doesn't contain in-memory objects
// that would be unsafe to act on (rdar://104253249).
private func containsInMemoryObject(_ dictionary: CFDictionary?) -> Bool {
    guard let dictionary else { return false }
    let nsDict = dictionary as NSDictionary
    // kSecUseItemList is deprecated on iOS 12+
    if nsDict[kSecUseItemList] != nil { return true }
    return nsDict[kSecValueRef] != nil
}

// Temporary partial MESSAGE_CHECK_COMPLETION_BASE support from Swift
// Idiomatic equivalent represented by rdar://168139740
private func messageCheckCompletion(
    connection: IPC.Connection,
    completionHandler: () -> Void,
    _ assertion: @autoclosure () -> Bool
) -> Bool {
    if !assertion() {
        secItemMarkConnectionInvalid(connection)
        completionHandler()
        return true
    }
    return false
}

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

    func secItemRequest(connection: IPC.Connection, request: WebKit.SecItemRequestData, completionHandler: CompletionHandlers.SecItemShimProxy.SecItemRequestCompletionHandler) {
        let query = unsafe request.query()
        let attributes = unsafe request.attributesToMatch()
        let type = request.type()
        if messageCheckCompletion(
            connection: connection,
            completionHandler: { completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(errSecParam)) },
            !containsInMemoryObject(query)
        ) { return }
        if messageCheckCompletion(
            connection: connection,
            completionHandler: { completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(errSecParam)) },
            !containsInMemoryObject(attributes)
        ) { return }
        switch type {
        case .Invalid:
            // TODO(rdar://168139823): LOG_ERROR("SecItemShimProxy::secItemRequest received an invalid data request. Please file a bug if you know how you caused this.")
            completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(errSecParam))
        case .CopyMatching:
            var result: CFTypeRef? = nil
            // unsafe: &result creates an UnsafeMutablePointer
            let resultCode = unsafe SecItemCopyMatching(query!, &result)
            guard let result else {
                completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(resultCode))
                break
            }
            if CFGetTypeID(result) == CFArrayGetTypeID() {
                let resultArray = result as! CFArray
                if CFArrayGetCount(resultArray) > 0 {
                    let containedType = CFGetTypeID((resultArray as NSArray)[0] as AnyObject)
                    if containedType == SecCertificateGetTypeID() {
                        completionHandler.pointee(consuming: makeSecItemResponseDataWithCertCFArray(resultCode, resultArray))
                        break
                    }
#if HAVE_SEC_KEYCHAIN
                    if containedType == SecKeychainItemGetTypeID() {
                        completionHandler.pointee(consuming: makeSecItemResponseDataWithKeychainCFArray(resultCode, resultArray))
                        break
                    }
#endif
                }
            }
            completionHandler.pointee(consuming: makeSecItemResponseDataWithCFTypeRef(resultCode, result))
        case .Add:
            // unsafe: nil for UnsafeMutablePointer<CFTypeRef?>? parameter
            let resultCode = unsafe SecItemAdd(query!, nil)
            completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(resultCode))
        case .Update:
            let resultCode = SecItemUpdate(query!, attributes!)
            completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(resultCode))
        case .Delete:
            let resultCode = SecItemDelete(query!)
            completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(resultCode))
        default:
            completionHandler.pointee(consuming: makeSecItemResponseDataWithStatus(errSecParam))
        }
    }

    func secItemRequestSync(connection: IPC.Connection, request: WebKit.SecItemRequestData, completionHandler: CompletionHandlers.SecItemShimProxy.SecItemRequestSyncCompletionHandler) {
        secItemRequest(connection: connection, request: request, completionHandler: completionHandler)
    }
}

#endif // ENABLE_SEC_ITEM_SHIM && ENABLE_SEC_ITEM_SHIM_PROXY_SWIFT

#endif // compiler(>=6.2.3)
