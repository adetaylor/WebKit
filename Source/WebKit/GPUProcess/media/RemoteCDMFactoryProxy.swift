// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebCoreEME
import WebKit_Internal
import wtf

// The Swift state of a RemoteCDMFactoryProxy (RemoteCDMFactoryProxy.h): the GPU process's CDMs, CDM instances and
// sessions, whose messages their registrations route to them.
final class RemoteCDMFactoryState {
    // The factory, until the web process's connection closes: the factory and its state keep each other alive until then.
    private(set) var proxy: WebKit.RemoteCDMFactoryProxy?
    // By identifier, which ObjectIdentifier makes unique across the three kinds: removed before the receiver, so that its
    // messages stop before its forwarder goes. Declared first, so that it goes first.
    private var registrations: [UInt64: IPC.SwiftReceiverRegistration] = [:]
    private var cdms: [UInt64: RemoteCDMProxy] = [:]
    private var instances: [UInt64: RemoteCDMInstanceProxy] = [:]
    private var sessions: [UInt64: RemoteCDMInstanceSessionProxy] = [:]

    fileprivate init(proxy: WebKit.RemoteCDMFactoryProxy) {
        self.proxy = proxy
    }

    // So that the CDMs don't reach the factory and no receiver's messages are routed once the connection's gone.
    fileprivate func clear() {
        registrations.removeAll()
        cdms.removeAll()
        proxy = nil
    }

    fileprivate func hasInstance(_ identifier: UInt64) -> Bool {
        instances[identifier] != nil
    }

    fileprivate var allowsExitUnderMemoryPressure: Bool {
        instances.isEmpty
    }

    fileprivate func add(cdm: RemoteCDMProxy, identifier: UInt64) {
        guard let proxy else {
            return
        }
        registrations[identifier] = IPC.registerSwiftReceiver(proxy, cdm.getMessageReceiver(), .RemoteCDMProxy, identifier)
        cdms[identifier] = cdm
    }

    func add(instance: RemoteCDMInstanceProxy, identifier: UInt64) {
        guard let proxy else {
            return
        }
        registrations[identifier] = IPC.registerSwiftReceiver(proxy, instance.getMessageReceiver(), .RemoteCDMInstanceProxy, identifier)
        instances[identifier] = instance
    }

    func add(session: RemoteCDMInstanceSessionProxy, identifier: UInt64) {
        guard let proxy else {
            return
        }
        registrations[identifier] = IPC.registerSwiftReceiver(
            proxy,
            session.getMessageReceiver(),
            .RemoteCDMInstanceSessionProxy,
            identifier
        )
        sessions[identifier] = session
    }

    fileprivate func removeInstance(_ identifier: UInt64) {
        registrations.removeValue(forKey: identifier)
        instances.removeValue(forKey: identifier)
    }

    fileprivate func removeSession(_ identifier: UInt64) {
        registrations.removeValue(forKey: identifier)
        sessions.removeValue(forKey: identifier)
    }
}

// The members of the C++ factory that reach its Swift state, which m_swiftState holds retained, by address, from the
// factory's create() to its destructor, and the handlers of its messages.
extension WebKit.RemoteCDMFactoryProxy {
    @cxx
    @implementation
    func createSwiftState() -> UInt {
        UInt(bitPattern: unsafe Unmanaged.passRetained(RemoteCDMFactoryState(proxy: self)).toOpaque())
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        _ = unsafe Unmanaged<RemoteCDMFactoryState>.fromOpaque(stateAddress(swiftState)).takeRetainedValue()
    }

    private static func stateAddress(_ swiftState: UInt) -> UnsafeMutableRawPointer {
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: swiftState) else {
            preconditionFailure("The factory has no Swift state")
        }
        return unsafe address
    }

    private var state: RemoteCDMFactoryState {
        // Safety: m_swiftState is a retained RemoteCDMFactoryState from create() to the destructor, and nothing else
        // changes it.
        unsafe Unmanaged<RemoteCDMFactoryState>.fromOpaque(Self.stateAddress(m_swiftState)).takeUnretainedValue()
    }

    @cxx
    @implementation
    func clear() {
        state.clear()
    }

    @cxx
    @implementation
    func allowsExitUnderMemoryPressure() -> Bool {
        state.allowsExitUnderMemoryPressure
    }

    @cxx
    @implementation
    func hasInstance(_ identifier: UInt64) -> Bool {
        state.hasInstance(identifier)
    }

    @MainActor
    func createCDM(
        connection: IPC.Connection,
        keySystem: String?,
        mediaKeysHashSalt: String?
    ) -> (identifier: IPCTypes.RemoteCDMIdentifier?, configuration: IPCTypes.RemoteCDMConfiguration) {
        let noCDM = IPCTypes.RemoteCDMConfiguration(
            supportedInitDataTypes: [],
            supportedRobustnesses: [],
            supportsServerCertificates: false,
            supportsSessions: false,
            logIdentifier: 0
        )
        guard let handle = createCDM(IPCCoding.WTFString.cxxString(keySystem), IPCCoding.WTFString.cxxString(mediaKeysHashSalt)) else {
            return (nil, noCDM)
        }
        let state = state
        let cdm = RemoteCDMProxy(factory: state, cdm: handle, isClearKey: ClearKey.supportsKeySystem(keySystem))
        let identifier = Self.generateCDMIdentifier()
        state.add(cdm: cdm, identifier: identifier)
        return (IPCTypes.RemoteCDMIdentifier(rawValue: identifier), cdm.configuration)
    }

    @MainActor
    func supportsKeySystem(connection: IPC.Connection, keySystem: String?) -> Bool {
        ClearKey.supportsKeySystem(keySystem) || FairPlayCDM.supportsKeySystem(keySystem)
    }

    @MainActor
    func removeInstance(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceIdentifier) {
        // Before the C++ instance, whose removal then checks whether the GPU process may exit.
        state.removeInstance(identifier.rawValue)
        removeInstance(identifier.rawValue)
    }

    @MainActor
    func removeSession(connection: IPC.Connection, identifier: IPCTypes.RemoteCDMInstanceSessionIdentifier) {
        state.removeSession(identifier.rawValue)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_ENCRYPTED_MEDIA && ENABLE_GPU_PROCESS_CDM_SWIFT
