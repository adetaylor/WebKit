// Copyright (C) 2026 Apple Inc. All rights reserved.
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
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. AND ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS_SWIFT

import Foundation
import WebKit_Internal

@_silgen_name("WebKitGPUServiceInitializerImpl")
private func webKitGPUServiceInitializerImpl(_ connection: OpaquePointer, _ initializerMessage: OpaquePointer?)

// <os/voucher_private.h> is gated on USE(APPLE_INTERNAL_SDK), so the C symbol is
// declared explicitly here for the public-SDK build. Matches the public-SDK
// extern "C" declaration in XPCServiceEntryPoint.h.
@_silgen_name("voucher_replace_default_voucher")
private func voucher_replace_default_voucher()

// <os/transaction_private.h> is gated on USE(APPLE_INTERNAL_SDK), so declare the
// C symbol explicitly here matching the public-SDK extern "C" declaration in
// WTF/wtf/spi/darwin/XPCSPI.h: XPC_RETURNS_RETAINED os_transaction_t
// os_transaction_create(const char *description). Return as OpaquePointer so we
// don't need the os_object protocol existential at the language boundary; the
// returned object is +1 retained and stashed in a process-lifetime static
// (transactionToken below) so its refcount never drops to zero.
@_silgen_name("os_transaction_create")
private func os_transaction_create(_ description: UnsafePointer<CChar>) -> OpaquePointer?

// xpc_object_t / xpc_connection_t in a Swift signature import as the
// `id <OS_xpc_object>` protocol existential, which trips the same emit-clang-header
// duplicate-declaration issue documented on GPUServiceInitializerSwiftEntry. Bind
// these xpc lookups via @_silgen_name with OpaquePointer parameters instead;
// xpc dispatches by symbol name so the language-boundary type is benign.
@_silgen_name("xpc_dictionary_get_value")
private func xpcDictionaryGetValue(_ dictionary: OpaquePointer, _ key: UnsafePointer<CChar>) -> OpaquePointer?

@_silgen_name("xpc_dictionary_get_string")
private func xpcDictionaryGetString(_ dictionary: OpaquePointer, _ key: UnsafePointer<CChar>) -> UnsafePointer<CChar>?

@_silgen_name("xpc_dictionary_get_data")
private func xpcDictionaryGetData(_ dictionary: OpaquePointer, _ key: UnsafePointer<CChar>, _ length: UnsafeMutablePointer<Int>) -> UnsafeRawPointer?

// SwiftGPUProcess is the Swift-side orchestrator for the GPU process. It owns
// the call hierarchy entered via the XPC GPUServiceInitializer symbol (see
// GPUServiceEntryPoint.swift). At present it wraps the existing C++
// XPCServiceInitializer<WebKit::GPUProcess, WebKit::GPUServiceInitializerDelegate>
// flow through a single C entry, WebKitGPUServiceInitializerImpl, while
// progressively translating individual initialization steps into Swift via
// direct C++ interop into WebKit_Internal. The XPC service runtime calls
// GPUServiceInitializer (provided as an @_cdecl in GPUServiceEntryPoint.swift)
// which forwards into shared.initialize(...).
public final class SwiftGPUProcess {
    public static let shared = SwiftGPUProcess()

    // Process-lifetime storage for the os_transaction_t returned by
    // os_transaction_create. The C++ shim stashes the equivalent in a
    // static NeverDestroyed<OSObjectPtr<os_transaction_t>> inside
    // WebKit::setOSTransaction; we hold the +1 retain that os_transaction_create
    // hands back (XPC_RETURNS_RETAINED in the public-SDK declaration) in this
    // static and never release it, matching that NeverDestroyed behavior. If
    // Swift were to release this, the XPC service could be killed by SIGTERM
    // during logout/reboot on platforms where we manage our own lifetime.
    // nonisolated(unsafe) because we only write this once from initialize()
    // before any concurrency starts.
    nonisolated(unsafe) private static var transactionToken: OpaquePointer?

    private init() {
    }

    public func initialize(connection: OpaquePointer, initializerMessage: OpaquePointer?) {
        // Leak an OS transaction so the XPC service stays alive for as long as
        // we want it to (matching the C++ shim's `setOSTransaction(adoptOSObject(
        // os_transaction_create("WebKit XPC Service")))` early in the template
        // body). The C++ call is gated on !USE(RUNNINGBOARD) — on RunningBoard
        // platforms the system manages our lifetime via process assertions, and
        // creating an extra os_transaction_t there is harmless because nothing
        // observes it. The Swift conditional-compilation flag set only carries
        // ENABLE_*/HAVE_* macros (see _WEBKIT_CONFIG_FILE_VARIABLES in
        // Source/cmake/WebKitMacros.cmake), so USE(RUNNINGBOARD) isn't visible
        // to Swift; calling unconditionally is the simplest correct approach.
        // os_transaction_create returns +1 (XPC_RETURNS_RETAINED), and we stash
        // that retain in transactionToken for the process's lifetime.
        if SwiftGPUProcess.transactionToken == nil {
            SwiftGPUProcess.transactionToken = os_transaction_create("WebKit XPC Service")
        }

        // Record the auxiliary process type ahead of the still-C++ initialization
        // body. WTF::setAuxiliaryProcessType is an idempotent setter on a
        // process-global, and the XPCServiceInitializer template body invokes it
        // with the same WTF::AuxiliaryProcessType::GPU value before
        // InitializeWebKit2() — calling it from Swift first leaves that
        // subsequent call a no-op. This is the first step migrated to a direct
        // C++ interop call out of WebKit_Internal; future commits will move
        // additional steps the same way (and remove the corresponding lines
        // from WebKitGPUServiceInitializerImpl once enough are owned by Swift).
        WTF.setAuxiliaryProcessType(WTF.AuxiliaryProcessType.GPU)

        // Replace the task default voucher with whatever XPC propagated. The
        // matching call in the C++ shim is gated out under ENABLE(GPU_PROCESS_SWIFT)
        // — voucher_replace_default_voucher writes the propagated voucher into
        // the task, so calling it once early here is semantically identical to
        // doing it at the original template-body position later.
        voucher_replace_default_voucher()

        // Configure JSC options from the XPC initializer message. The C++ shim
        // would normally read the two JSC bool flags out of the
        // parameters.extraInitializationData HashMap that getExtraInitializationData
        // populates from the "extra-initialization-data" XPC sub-dictionary; pull
        // them directly from that sub-dictionary here so this commit doesn't have
        // to migrate getExtraInitializationData too. The matching
        // `if (initializerMessage) { setJSCOptions(...) }` block in the C++ shim
        // is gated out under ENABLE(GPU_PROCESS_SWIFT). The ordering is
        // load-bearing: setJSCOptions RELEASE_ASSERTs that JSC has not yet been
        // initialized, so it must run before InitializeWebKit2() — which is
        // still inside webKitGPUServiceInitializerImpl below.
        if let initializerMessage {
            var enableLockdownMode = WebKit.EnableLockdownMode.No
            var enableEnhancedSecurity = WebKit.EnableEnhancedSecurity.No
            if let extraInitializationData = xpcDictionaryGetValue(initializerMessage, "extra-initialization-data") {
                if let lockdown = xpcDictionaryGetString(extraInitializationData, "enable-lockdown-mode"), strcmp(lockdown, "1") == 0 {
                    enableLockdownMode = .Yes
                }
                if let enhancedSecurity = xpcDictionaryGetString(extraInitializationData, "enable-enhanced-security"), strcmp(enhancedSecurity, "1") == 0 {
                    enableEnhancedSecurity = .Yes
                }
            }
            WebKit.setJSCOptions(unsafeBitCast(initializerMessage, to: xpc_object_t.self), enableLockdownMode, enableEnhancedSecurity, /* isWebContentProcess */ false)
        }

        // Load the client SDK-aligned behaviors bitset out of the XPC initializer
        // message and publish it to WTF. The C++ shim normally does this via
        // GPUServiceInitializerDelegate::getClientSDKAlignedBehaviors, which reads
        // the "client-sdk-aligned-behaviors" XPC data blob and memcpys it into a
        // SDKAlignedBehaviors BitSet's storage. Reimplement that here against the
        // initializer message directly (the delegate is still owned by the C++
        // shim), then call WTF::setSDKAlignedBehaviors via C++ interop. The
        // matching three lines in webKitGPUServiceInitializerImpl are gated out
        // under ENABLE(GPU_PROCESS_SWIFT). If the XPC blob is absent or empty,
        // skip the set call — the C++ delegate path returns false in the same
        // case and the value is then left as the default-constructed bitset that
        // would never have been published.
        if let initializerMessage {
            var dataLength: Int = 0
            if let dataPointer = xpcDictionaryGetData(initializerMessage, "client-sdk-aligned-behaviors", &dataLength), dataLength > 0 {
                var behaviors = WTF.SDKAlignedBehaviors()
                let storageSize = MemoryLayout.size(ofValue: behaviors)
                if dataLength <= storageSize {
                    withUnsafeMutableBytes(of: &behaviors) { storage in
                        if let base = storage.baseAddress {
                            memcpy(base, dataPointer, dataLength)
                        }
                    }
                    WTF.setSDKAlignedBehaviors(behaviors)
                }
            }
        }

        webKitGPUServiceInitializerImpl(connection, initializerMessage)
    }
}

#endif // ENABLE_GPU_PROCESS_SWIFT
