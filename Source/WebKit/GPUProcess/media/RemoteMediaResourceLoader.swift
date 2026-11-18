// Copyright (C) 2019 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS_MEDIA_SWIFT && ENABLE_VIDEO

import Synchronization
import WebKit_Internal

// @unchecked Sendable: copying a ThreadSafeWeakPtr, its get() and its destruction are safe on any thread.
private struct WeakResource: @unchecked Sendable {
    let pointer: WebKit.RemoteMediaResourceWeakPtr
}

// The resources that a RemoteMediaResourceLoader hands its messages to, by identifier, for any thread: requestResource()
// adds each on any thread, and the web process's acknowledgement of its removal removes it.
final class RemoteMediaResourceLoaderState: Sendable {
    private let resources = Mutex<[UInt64: WeakResource]>([:])

    fileprivate func add(_ identifier: UInt64, _ resource: WebKit.RemoteMediaResourceWeakPtr) {
        let resource = WeakResource(pointer: resource)
        resources.withLock { resources in
            assert(resources[identifier] == nil)
            resources[identifier] = resource
        }
    }

    fileprivate func resource(_ identifier: UInt64) -> WebKit.RemoteMediaResourceWeakPtr? {
        resources.withLock { $0[identifier] }?.pointer
    }

    fileprivate func remove(_ identifier: UInt64) {
        let removed = resources.withLock { $0.removeValue(forKey: identifier) }
        assert(removed != nil)
    }
}

// The members of the C++ loader (RemoteMediaResourceLoader.h) that reach its Swift state, which m_swiftState holds
// retained, by address, from the loader's constructor to its destructor, and the handlers of its messages that take no
// reply, on its work queue.
extension WebKit.RemoteMediaResourceLoader {
    @cxx
    @implementation
    static func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteMediaResourceLoaderState()).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<RemoteMediaResourceLoaderState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The loader has no Swift state")
        }
        return unsafe address
    }

    private var state: RemoteMediaResourceLoaderState {
        // Safety: m_swiftState is a retained RemoteMediaResourceLoaderState from the constructor to the destructor, and
        // nothing changes it.
        unsafe Unmanaged<RemoteMediaResourceLoaderState>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    @cxx
    @implementation
    func swiftAddMediaResource(_ identifier: UInt64, _ resource: WebKit.RemoteMediaResourceWeakPtr) {
        state.add(identifier, resource)
    }

    @cxx
    @implementation
    func swiftMediaResource(_ identifier: UInt64) -> WebKit.RemoteMediaResourceWeakPtr {
        state.resource(identifier) ?? WebKit.RemoteMediaResourceWeakPtr()
    }

    @cxx
    @implementation
    func swiftRemoveMediaResource(_ identifier: UInt64) {
        state.remove(identifier)
    }

    private func resource(_ identifier: IPCTypes.RemoteMediaResourceIdentifier) -> WebKit.RemoteMediaResource? {
        assert(Self.isCurrentQueue())
        return state.resource(identifier.rawValue)?.get().get()
    }

    func dataSent(connection: IPC.Connection, identifier: IPCTypes.RemoteMediaResourceIdentifier, bytesSent: UInt64, totalBytesToBeSent: UInt64) {
        resource(identifier)?.dataSent(bytesSent, totalBytesToBeSent)
    }

    func accessControlCheckFailed(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteMediaResourceIdentifier,
        error: CxxDecodedArguments.RemoteMediaResourceLoader.AccessControlCheckFailedError
    ) {
        resource(identifier)?.accessControlCheckFailed(error)
    }

    func loadFailed(connection: IPC.Connection, identifier: IPCTypes.RemoteMediaResourceIdentifier, error: CxxDecodedArguments.RemoteMediaResourceLoader.LoadFailedError) {
        resource(identifier)?.loadFailed(error)
    }

    func loadFinished(
        connection: IPC.Connection,
        identifier: IPCTypes.RemoteMediaResourceIdentifier,
        metrics: CxxDecodedArguments.RemoteMediaResourceLoader.LoadFinishedMetrics
    ) {
        resource(identifier)?.loadFinished(metrics)
    }
}

#endif
