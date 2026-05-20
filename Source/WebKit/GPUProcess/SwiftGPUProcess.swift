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

import Darwin
import Foundation
import WebKit_Internal

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

// xpc_dictionary_copy_mach_send returns a mach send right (UInt32) for the
// named key, or MACH_PORT_NULL if no such entry exists. Used by
// XPCServiceInitializerDelegate::getConnectionIdentifier to pull the
// "server-port" mach port out of the XPC initializer message; we reproduce
// that here against the message directly.
@_silgen_name("xpc_dictionary_copy_mach_send")
private func xpcDictionaryCopyMachSend(_ dictionary: OpaquePointer, _ key: UnsafePointer<CChar>) -> mach_port_t

// Typed bridges over the tail of the XPCServiceInitializer template body. See
// GPUServiceEntryPoint.mm for the full rationale; constructing
// AuxiliaryProcessInitializationParameters (with its IPC::Connection::Identifier
// + ObjectIdentifier<WebCore::ProcessIdentifierType> members) and instantiating
// XPCServiceInitializerDelegate (which needs OSObjectPtr<xpc_connection_t>) from
// Swift would require importing more C++ machinery than is worth it, so the
// .mm file exposes thin extern "C" entry points that the Swift orchestrator
// calls with already-extracted primitives.
@_silgen_name("WebKitGPUProcessInitializeAfterSwiftBootstrap")
private func webKitGPUProcessInitializeAfterSwiftBootstrap(
    _ connection: OpaquePointer,
    _ serverPort: mach_port_t,
    _ uiProcessName: UnsafePointer<CChar>,
    _ clientIdentifier: UnsafePointer<CChar>,
    _ clientBundleIdentifier: UnsafePointer<CChar>?,
    _ processIdentifierRawValue: UInt64,
    _ extraInitDataKeys: UnsafePointer<UnsafePointer<CChar>?>?,
    _ extraInitDataValues: UnsafePointer<UnsafePointer<CChar>?>?,
    _ extraInitDataCount: Int)

@_silgen_name("WebKitGPUProcessCheckEntitlements")
private func webKitGPUProcessCheckEntitlements(_ connection: OpaquePointer, _ initializerMessage: OpaquePointer?) -> Bool

@_silgen_name("WebKitGPUProcessConnectedProcessIsSandboxed")
private func webKitGPUProcessConnectedProcessIsSandboxed(_ connection: OpaquePointer) -> Bool

@_silgen_name("WebKitGPUProcessSetGlobalMaxQOSClassUtility")
private func webKitGPUProcessSetGlobalMaxQOSClassUtility()

// Typed bridges that reproduce the two halves of WebKit::disableJSC's body
// (Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.mm)
// for the Swift path. The C++ template body in WebKitGPUServiceInitializerImpl
// runs inside disableJSC([&] { ... }); the Swift orchestrator runs the body
// itself, so we call the prologue before the rest of initialize (it sets the
// g_jscConfig / g_wtfConfig security flags, calls WTF::initializeMainThread,
// runs JSC::Options::initialize with disableJIT + useWasm=false, and a
// compilerFence) and the epilogue (JSC::Config::finalize) after, matching
// the line-for-line behavior of disableJSC. g_jscConfig / g_wtfConfig are
// macros that expand to inline addressOf*Config() dereferences and
// JSC::Options::initialize takes a C++ callable, neither of which import
// cleanly into Swift; the typed shims in GPUServiceEntryPoint.mm keep the
// language boundary minimal.
@_silgen_name("WebKitGPUProcessDisableJSCPrologue")
private func webKitGPUProcessDisableJSCPrologue()

@_silgen_name("WebKitGPUProcessDisableJSCEpilogue")
private func webKitGPUProcessDisableJSCEpilogue()

// MARK: - IPC handler bodies (Phase 3 POC)

// Typed C bridge to GPUConnectionToWebProcess::objectCountForTesting(). Defined
// in GPUProcess.cpp under ENABLE(GPU_PROCESS_SWIFT). The bridge exists because
// GPUConnectionToWebProcess's base list (ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr,
// WebCore::NowPlayingManagerClient, IPC::Connection::Client) keeps Swift's C++
// interop from synthesizing the class, so the single inline-static counter
// accessor we need is re-exposed as a plain extern "C" function instead. Same
// pattern as the WebKitGPUProcess* typed bridges above.
@_silgen_name("WebKitGPUProcessConnectionToWebProcessObjectCount")
internal func webKitGPUProcessConnectionToWebProcessObjectCount() -> UInt64

// Swift-owned body of GPUProcess::webProcessConnectionCountForTesting. The
// autogenerated IPC dispatcher (DerivedSources/GPUProcessMessageReceiver.cpp)
// calls the C++ method by name, so GPUProcess.cpp keeps a thin dispatch shim
// gated under ENABLE(GPU_PROCESS_SWIFT) that forwards to this @_cdecl entry
// point. The actual one-line logic lives here.
//
// Pattern for future GPU process IPC handler migrations:
//   1. Keep the C++ GPUProcess::method declaration (autogen references it).
//   2. Replace the C++ body with an ENABLE(GPU_PROCESS_SWIFT)-gated dispatch
//      to extern "C" swiftGPUProcess<Method>(...); the #else branch keeps the
//      original body so the OFF configuration still builds and works.
//   3. Add a top-level `@_cdecl("swiftGPUProcess<Method>") public func ...`
//      here whose body is the migrated logic.
//   4. If the body needs WebKit/WTF types, try importing the relevant header
//      via Source/WebKit/Modules/Internal/WebKitInternalCxx.h under the
//      existing ENABLE(GPU_PROCESS_SWIFT) block first; if the class fails to
//      import (heavy base classes / templates), add a thin extern "C" typed
//      bridge in the corresponding .cpp / .mm and @_silgen_name to it from
//      here. This handler needs the bridge for that reason — see
//      WebKitGPUProcessConnectionToWebProcessObjectCount above.
//
// `public` matters: @_cdecl on a `private` function yields "private external"
// linkage, which hides the symbol from the dylib's export table and causes a
// link-time undefined-symbol error when the C++ shim tries to reference it.
// See the GPUServiceInitializer entry point for the same constraint.
//
// Return type is the primitive UInt64 so no OpaquePointer dance is needed at
// the language boundary; future handlers that take/return C++ types may need
// the prologue/epilogue typed-bridge pattern (see WebKitGPUProcessDisableJSC*
// above) instead.
@_cdecl("swiftGPUProcessWebProcessConnectionCountForTesting")
public func swiftGPUProcessWebProcessConnectionCountForTesting() -> UInt64 {
    return webKitGPUProcessConnectionToWebProcessObjectCount()
}

#if ENABLE_MEDIA_STREAM
// Typed C bridge to WebCore::MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled.
// Defined in GPUProcess.cpp under ENABLE(GPU_PROCESS_SWIFT) && ENABLE(MEDIA_STREAM).
// Same pattern as WebKitGPUProcessConnectionToWebProcessObjectCount above —
// keeps the WebCore static call on the C++ side where the include for
// <WebCore/MockRealtimeMediaSourceCenter.h> already lives.
@_silgen_name("WebKitGPUProcessSetMockRealtimeMediaSourceCenterEnabled")
internal func webKitGPUProcessSetMockRealtimeMediaSourceCenterEnabled(_ isEnabled: Bool)

// Swift-owned body of GPUProcess::setMockCaptureDevicesEnabled. The
// autogenerated IPC dispatcher (DerivedSources/GPUProcessMessageReceiver.cpp)
// calls the C++ method by name; GPUProcess.cpp keeps a thin dispatch shim
// gated under ENABLE(GPU_PROCESS_SWIFT) that forwards to this @_cdecl entry
// point. The actual one-line logic lives here. `public` is load-bearing
// (see note on swiftGPUProcessWebProcessConnectionCountForTesting above).
//
// Gated on ENABLE_MEDIA_STREAM because ENABLE_MEDIA_STREAM reaches Swift via
// the -D definitions emitted by Source/cmake/WebKitMacros.cmake's
// _WEBKIT_CONFIG_FILE_VARIABLES loop, and the C++ side won't reference
// swiftGPUProcessSetMockCaptureDevicesEnabled outside the MEDIA_STREAM gate.
@_cdecl("swiftGPUProcessSetMockCaptureDevicesEnabled")
public func swiftGPUProcessSetMockCaptureDevicesEnabled(_ isEnabled: Bool) {
    webKitGPUProcessSetMockRealtimeMediaSourceCenterEnabled(isEnabled)
}

// Phase 3 batch: four additional mock-media static handlers migrated together.
// Each follows the same shape as swiftGPUProcessSetMockCaptureDevicesEnabled
// above — a typed extern "C" bridge in GPUProcess.cpp does the WebCore static
// call, and the @_cdecl entry point here owns the Swift-side handler body.
// `public` is load-bearing on every @_cdecl (see prior gotcha note).

@_silgen_name("WebKitGPUProcessMockMediaCenterSetDevicesEmpty")
internal func webKitGPUProcessMockMediaCenterSetDevicesEmpty()

@_cdecl("swiftGPUProcessClearMockMediaDevices")
public func swiftGPUProcessClearMockMediaDevices() {
    webKitGPUProcessMockMediaCenterSetDevicesEmpty()
}

@_silgen_name("WebKitGPUProcessMockMediaCenterResetDevices")
internal func webKitGPUProcessMockMediaCenterResetDevices()

@_cdecl("swiftGPUProcessResetMockMediaDevices")
public func swiftGPUProcessResetMockMediaDevices() {
    webKitGPUProcessMockMediaCenterResetDevices()
}

@_silgen_name("WebKitGPUProcessMockMediaCenterSetCaptureDevicesInterrupted")
internal func webKitGPUProcessMockMediaCenterSetCaptureDevicesInterrupted(_ isCameraInterrupted: Bool, _ isMicrophoneInterrupted: Bool)

@_cdecl("swiftGPUProcessSetMockCaptureDevicesInterrupted")
public func swiftGPUProcessSetMockCaptureDevicesInterrupted(_ isCameraInterrupted: Bool, _ isMicrophoneInterrupted: Bool) {
    webKitGPUProcessMockMediaCenterSetCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted)
}

@_silgen_name("WebKitGPUProcessMockMediaCenterTriggerCaptureConfigurationChange")
internal func webKitGPUProcessMockMediaCenterTriggerCaptureConfigurationChange(_ forCamera: Bool, _ forMicrophone: Bool, _ forDisplay: Bool)

@_cdecl("swiftGPUProcessTriggerMockCaptureConfigurationChange")
public func swiftGPUProcessTriggerMockCaptureConfigurationChange(_ forCamera: Bool, _ forMicrophone: Bool, _ forDisplay: Bool) {
    webKitGPUProcessMockMediaCenterTriggerCaptureConfigurationChange(forCamera, forMicrophone, forDisplay)
}

// Phase 3 batch 2: string-arg mock-media handlers. The String <-> const char*
// conversion happens on the C++ side (utf8().data() before the call, then
// String::fromUTF8 inside the bridge), so the Swift signatures stay POD —
// UnsafePointer<CChar> just plumbs the bytes straight through to the bridge.
// `public` on each @_cdecl is load-bearing for symbol export, same as above.

@_silgen_name("WebKitGPUProcessMockMediaCenterRemoveDevice")
internal func webKitGPUProcessMockMediaCenterRemoveDevice(_ persistentId: UnsafePointer<CChar>)

// Bridge for Swift GPUProcess.addMockMediaDevice(device:). The arg is
// [RefWrap]-annotated in messages.in (MockMediaDevice contains a
// std::variant; passing by value crashes swiftc IRGen — see
// ~/swift-gpu-compiler-crash/), so the autogen hands Swift a foreign-
// reference RefCountable<MockMediaDevice>* which we forward straight
// to the C++ side; the body in GPUProcess.cpp unwraps and calls
// WebCore::MockRealtimeMediaSourceCenter::addDevice.
@_silgen_name("WebKitGPUProcessMockMediaCenterAddDeviceFromWrap")
internal func webKitGPUProcessMockMediaCenterAddDeviceFromWrap(_ wrapped: WrappedArgs.GPUProcess.AddMockMediaDevice_device)

@_cdecl("swiftGPUProcessRemoveMockMediaDevice")
public func swiftGPUProcessRemoveMockMediaDevice(_ persistentId: UnsafePointer<CChar>) {
    webKitGPUProcessMockMediaCenterRemoveDevice(persistentId)
}

@_silgen_name("WebKitGPUProcessMockMediaCenterSetDeviceIsEphemeral")
internal func webKitGPUProcessMockMediaCenterSetDeviceIsEphemeral(_ persistentId: UnsafePointer<CChar>, _ isEphemeral: Bool)

@_cdecl("swiftGPUProcessSetMockMediaDeviceIsEphemeral")
public func swiftGPUProcessSetMockMediaDeviceIsEphemeral(_ persistentId: UnsafePointer<CChar>, _ isEphemeral: Bool) {
    webKitGPUProcessMockMediaCenterSetDeviceIsEphemeral(persistentId, isEphemeral)
}
#endif

// Phase 3 handler: ScreenCaptureKitSharingSessionManager::cancelGetDisplayMediaPrompt.
// This handler is gated on HAVE(SCREEN_CAPTURE_KIT) on the C++ side, but
// HAVE_SCREEN_CAPTURE_KIT is defined in Source/WTF/wtf/PlatformHave.h and is
// not propagated to Swift as a conditional-compilation flag (it's not in
// cmake's _WEBKIT_CONFIG_FILE_VARIABLES, which only includes options exposed
// via EXPOSE_VARIABLE_TO_BUILD / SET_AND_EXPOSE_TO_BUILD). The Swift @_cdecl
// is therefore defined unconditionally; the C++ gate keeps both the bridge
// symbol and the call site absent when SCREEN_CAPTURE_KIT is off, so the
// Swift function is never reached in that configuration.
// `public` on the @_cdecl is load-bearing for symbol export.

@_silgen_name("WebKitGPUProcessScreenCaptureKitSharingSessionManagerCancelGetDisplayMediaPrompt")
internal func webKitGPUProcessScreenCaptureKitSharingSessionManagerCancelGetDisplayMediaPrompt()

@_cdecl("swiftGPUProcessCancelGetDisplayMediaPrompt")
public func swiftGPUProcessCancelGetDisplayMediaPrompt() {
    webKitGPUProcessScreenCaptureKitSharingSessionManagerCancelGetDisplayMediaPrompt()
}

// Phase 3 handler: GPUProcess::userPreferredLanguagesChanged. Vector<String>
// at the IPC boundary becomes parallel arrays (const char** + size_t count)
// across the C++/Swift boundary. The C++ shim in GPUProcess.cpp builds the
// UTF-8 CStrings, this @_cdecl plumbs the buffers straight through to the
// WebKitGPUProcessOverrideUserPreferredLanguages bridge, which reconstructs
// a Vector<String> via String::fromUTF8 and calls WTF::overrideUserPreferredLanguages.
// This is the Vector<T> pattern reused later for handlers taking Vector<SandboxExtension::Handle>.
// Not gated: the bridge symbol exists whenever ENABLE(GPU_PROCESS_SWIFT) is on,
// which is the only configuration that ever calls this Swift function.
// `public` on the @_cdecl is load-bearing for symbol export.

@_silgen_name("WebKitGPUProcessOverrideUserPreferredLanguages")
internal func webKitGPUProcessOverrideUserPreferredLanguages(_ languages: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int)

@_cdecl("swiftGPUProcessUserPreferredLanguagesChanged")
public func swiftGPUProcessUserPreferredLanguagesChanged(_ languages: UnsafePointer<UnsafePointer<CChar>?>, _ count: Int) {
    webKitGPUProcessOverrideUserPreferredLanguages(languages, count)
}

// MARK: - VP9 bridges (Phase 2.a)
//
// Bridges for the updateGPUProcessPreferences handler. The Swift GPUProcess
// class owns the m_preferences / m_haveEnabled* state on the ON path and
// orchestrates the body in GPUProcess.swift; the handful of WebCore static
// calls and the std::optional<bool> field extraction stay on the C++ side
// behind these bridges. Each bridge is gated on
// ENABLE(VP9) && PLATFORM(COCOA) in GPUProcess.cpp to match the original
// gating; ENABLE_VP9 reaches Swift as a -D flag (PlatformEnableCocoa.h
// processed by generate-platform-swift-args.py), while PLATFORM(COCOA) is
// implicit because ENABLE_GPU_PROCESS_SWIFT is only enabled on Cocoa
// (OptionsMac.cmake — the only enable site).

#if ENABLE_VP9
// Extract the std::optional<bool> vp9DecoderEnabled / plain-bool
// swVPDecodersAlwaysEnabled fields out of GPUProcessPreferences into POD out
// parameters; the importer doesn't bridge std::optional<bool> to Swift's
// Optional<Bool>, so Swift reads the IPC argument through this bridge by
// passing a pointer to the consuming parameter via withUnsafePointer(to:).
@_silgen_name("WebKitGPUProcessExtractPreferences")
internal func webKitGPUProcessExtractPreferences(
    _ preferences: UnsafePointer<WebKit.GPUProcessPreferences>,
    _ outVP9HasValue: UnsafeMutablePointer<Bool>,
    _ outVP9Value: UnsafeMutablePointer<Bool>,
    _ outSWVP: UnsafeMutablePointer<Bool>)

@_silgen_name("WebKitGPUProcessVP9SetShouldEnableVP9Decoder")
internal func webKitGPUProcessVP9SetShouldEnableVP9Decoder(_ enabled: Bool)

@_silgen_name("WebKitGPUProcessVP9SetSWVPDecodersAlwaysEnabled")
internal func webKitGPUProcessVP9SetSWVPDecodersAlwaysEnabled(_ enabled: Bool)

@_silgen_name("WebKitGPUProcessVP9RegisterSupplementalVP9Decoder")
internal func webKitGPUProcessVP9RegisterSupplementalVP9Decoder()

@_silgen_name("WebKitGPUProcessVP9ShouldEnableSWVP9Decoder")
internal func webKitGPUProcessVP9ShouldEnableSWVP9Decoder() -> Bool

@_silgen_name("WebKitGPUProcessVP9RegisterWebKitVP9Decoder")
internal func webKitGPUProcessVP9RegisterWebKitVP9Decoder()
#endif // ENABLE_VP9

// MARK: - Parameter struct

// Swift-side mirror of WebKit::AuxiliaryProcessInitializationParameters with
// native Swift types. The C++ struct is built inside
// WebKitGPUProcessInitializeAfterSwiftBootstrap from these primitives so
// IPC::Connection::Identifier / ObjectIdentifier<...> / HashMap<String, String>
// don't have to cross the Swift language boundary directly. Fields here line
// up 1:1 with the fields populated by the C++ XPCServiceInitializerDelegate
// methods (getExtraInitializationData, getConnectionIdentifier, etc.).
private struct GPUProcessInitParameters {
    var uiProcessName: Swift.String = ""
    var clientIdentifier: Swift.String = ""
    var clientBundleIdentifier: Swift.String = ""
    var processIdentifier: UInt64 = 0
    var serverPort: mach_port_t = 0
    var extraInitializationData: [(Swift.String, Swift.String)] = []
}

// MARK: - Delegate reimplementations

// Reads the "extra-initialization-data" sub-dictionary from the XPC initializer
// message and populates `extraInitializationData` to match
// XPCServiceInitializerDelegate::getExtraInitializationData in
// Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.mm.
// Keys: inspector-process, service-worker-process, registrable-domain, is-prewarmed,
// enable-lockdown-mode / enable-enhanced-security (mutually exclusive — only one
// is added), user-directory-suffix (only when the client is not sandboxed), and
// always-runs-at-background-priority. Each key is added only if its value is
// non-empty, matching the C++ branches. Order matches the C++ delegate so the
// final HashMap content is identical.
private func readExtraInitializationData(connection: OpaquePointer, initializerMessage: OpaquePointer?) -> [(Swift.String, Swift.String)] {
    var result: [(Swift.String, Swift.String)] = []
    guard let initializerMessage,
          let extraData = xpcDictionaryGetValue(initializerMessage, "extra-initialization-data") else {
        return result
    }

    func addIfNonEmpty(_ key: Swift.String) {
        guard let cString = key.withCString({ xpcDictionaryGetString(extraData, $0) }), cString.pointee != 0 else { return }
        let value = Swift.String(cString: cString)
        if !value.isEmpty {
            result.append((key, value))
        }
    }

    addIfNonEmpty("inspector-process")
    addIfNonEmpty("service-worker-process")
    addIfNonEmpty("registrable-domain")
    addIfNonEmpty("is-prewarmed")

    // The lockdown / enhanced-security keys are mutually exclusive in the C++
    // delegate: enhanced-security is only added if lockdown was absent/empty.
    let lockdownCStr = "enable-lockdown-mode".withCString { xpcDictionaryGetString(extraData, $0) }
    if let lockdownCStr, lockdownCStr.pointee != 0 {
        let value = Swift.String(cString: lockdownCStr)
        if !value.isEmpty {
            result.append(("enable-lockdown-mode", value))
        } else {
            addIfNonEmpty("enable-enhanced-security")
        }
    } else {
        addIfNonEmpty("enable-enhanced-security")
    }

    // user-directory-suffix is only read for non-sandboxed clients (matches the
    // C++ delegate's !isClientSandboxed() guard). Delegating sandbox detection
    // to the C++ bridge below keeps the audit-token / sandbox_check_by_audit_token
    // path identical to the existing implementation.
    if !webKitGPUProcessConnectedProcessIsSandboxed(connection) {
        addIfNonEmpty("user-directory-suffix")
    }

    addIfNonEmpty("always-runs-at-background-priority")

    return result
}

// MARK: - SwiftGPUProcess

// SwiftGPUProcess is the Swift-side orchestrator for the GPU process. It owns
// the call hierarchy entered via the XPC GPUServiceInitializer symbol (see
// GPUServiceEntryPoint.swift). With this commit it owns the entire
// XPCServiceInitializer<WebKit::GPUProcess, WebKit::GPUServiceInitializerDelegate>
// template body: it sets up the OS transaction, configures JSC, publishes
// SDK-aligned behaviors, records the auxiliary process type, runs
// InitializeWebKit2, extracts every AuxiliaryProcessInitializationParameters
// field directly from the XPC initializer message, checks entitlements,
// replaces the default voucher, applies the QoS class, and finally calls the
// WebKitGPUProcessInitializeAfterSwiftBootstrap typed bridge that constructs
// the C++ parameter struct and dispatches WebKit::GPUProcess::singleton().initialize().
// The matching C++ template body in WebKitGPUServiceInitializerImpl is gated
// out under ENABLE(GPU_PROCESS_SWIFT) and only runs on the off path.
//
// Ordering must match the template body in
// Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.h:
//   setOSTransaction, getExtraInitializationData, setJSCOptions,
//   getClientSDKAlignedBehaviors+setSDKAlignedBehaviors, setAuxiliaryProcessType,
//   InitializeWebKit2, checkEntitlements, getConnectionIdentifier,
//   getClientIdentifier, getClientBundleIdentifier, getProcessIdentifier,
//   getClientProcessName, voucher_replace_default_voucher, QoS class setter,
//   initializeAuxiliaryProcess.
//
// The C++ template body runs inside disableJSC([&]{...}), which sets a few
// g_jscConfig / g_wtfConfig security flags, initializes the main thread,
// runs JSC::Options::initialize with disableJIT + useWasm=false, fences,
// runs the body, then calls JSC::Config::finalize() at the end. The Swift
// path performs that same setup via two typed bridges
// (WebKitGPUProcessDisableJSCPrologue / WebKitGPUProcessDisableJSCEpilogue
// in GPUServiceEntryPoint.mm): the prologue runs first thing in initialize
// (before setOSTransaction) and the epilogue runs after the final bridge
// call, preserving the load-bearing invariants (security flags set, JIT/Wasm
// disabled, JSC config finalized) that the C++ disableJSC wrapper guarantees.
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
        // Step 0a: Run the disableJSC prologue (matches the first half of
        // WebKit::disableJSC's body in XPCServiceEntryPoint.mm). Sets the
        // g_jscConfig vmCreationDisallowed / vmEntryDisallowed flags and
        // g_wtfConfig.useSpecialAbortForExtraSecurityImplications, initializes
        // the main thread, calls JSC::Options::initialize([] { disableJIT();
        // useWasm() = false; }), and emits a compiler fence. This must run
        // before anything else (including setOSTransaction below) so that the
        // security flags are in place before any code path can touch JSC, and
        // before setJSCOptions further down which RELEASE_ASSERTs that
        // g_jscConfig.initializeHasBeenCalled is false. The epilogue
        // (JSC::Config::finalize) runs at the very end of this function,
        // after the C++ bridge call, matching the disableJSC C++ shape.
        webKitGPUProcessDisableJSCPrologue()

        // Step 1: Leak an OS transaction so the XPC service stays alive for as
        // long as we want it to (matching the C++ shim's `setOSTransaction(
        // adoptOSObject(os_transaction_create("WebKit XPC Service")))` early in
        // the template body). The C++ call is gated on !USE(RUNNINGBOARD) — on
        // RunningBoard platforms the system manages our lifetime via process
        // assertions, and creating an extra os_transaction_t there is harmless
        // because nothing observes it. The Swift conditional-compilation flag
        // set only carries ENABLE_*/HAVE_* macros (see _WEBKIT_CONFIG_FILE_VARIABLES
        // in Source/cmake/WebKitMacros.cmake), so USE(RUNNINGBOARD) isn't
        // visible to Swift; calling unconditionally is the simplest correct
        // approach. os_transaction_create returns +1 (XPC_RETURNS_RETAINED),
        // and we stash that retain in transactionToken for the process's
        // lifetime.
        if SwiftGPUProcess.transactionToken == nil {
            SwiftGPUProcess.transactionToken = os_transaction_create("WebKit XPC Service")
        }

        // Step 2: Build our Swift-side parameters struct. Read the extra
        // initialization data sub-dictionary up front because both setJSCOptions
        // (next) and the final HashMap forwarded into the C++ parameter struct
        // need entries from it, and to match the C++ template body's ordering
        // which calls getExtraInitializationData before setJSCOptions.
        var params = GPUProcessInitParameters()
        params.extraInitializationData = readExtraInitializationData(connection: connection, initializerMessage: initializerMessage)

        // Step 3: Configure JSC options from the XPC initializer message. The
        // C++ shim would normally read the two JSC bool flags out of the
        // parameters.extraInitializationData HashMap; we already have them in
        // params.extraInitializationData but pull them from the sub-dictionary
        // here too so the code is robust to the lockdown/enhanced-security
        // mutual-exclusion logic. The ordering is load-bearing: setJSCOptions
        // RELEASE_ASSERTs that JSC has not yet been initialized, so it must run
        // before InitializeWebKit2() below.
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

        // Step 4: Load the client SDK-aligned behaviors bitset out of the XPC
        // initializer message and publish it to WTF. Reimplements
        // XPCServiceInitializerDelegate::getClientSDKAlignedBehaviors against
        // the initializer message directly. If the XPC blob is absent or empty,
        // skip the set call — the C++ delegate path returns false in the same
        // case and the value is then left as the default-constructed bitset
        // that would never have been published.
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

        // Step 5: Record the auxiliary process type. WTF::setAuxiliaryProcessType
        // is an idempotent setter on a process-global. computeSDKAlignedBehaviors
        // asserts it is not called in an auxiliary process, so this must precede
        // InitializeWebKit2 below (which calls linkedOnOrAfterSDKWithBehavior).
        WTF.setAuxiliaryProcessType(WTF.AuxiliaryProcessType.GPU)

        // Step 6: Initialize WebKit2. InitializeWebKit2() calls
        // linkedOnOrAfterSDKWithBehavior(), so SDK-aligned behaviors and the
        // auxiliary process type must already be set (steps 4-5 above). It also
        // initializes JSC's config, so setJSCOptions (step 3) must precede it
        // because setJSCOptions RELEASE_ASSERTs JSC has not yet been initialized.
        WebKit.InitializeWebKit2()

        // Step 7: Check entitlements. Bridged to C++ because the base
        // XPCServiceInitializerDelegate::checkEntitlements implementation does
        // platform-specific sandbox / mach-lookup checks that are clearer to
        // keep in their existing location. Returns true on non-Mac/Catalyst,
        // and on Mac/Catalyst returns true unless the client is sandboxed AND
        // missing the network-client entitlement AND fails the nsurlsessiond
        // mach-lookup sandbox check (see XPCServiceEntryPoint.mm).
        if !webKitGPUProcessCheckEntitlements(connection, initializerMessage) {
            exitProcessFailure()
        }

        // Step 8: Extract the IPC connection identifier (the "server-port"
        // mach send right out of the XPC message). Matches
        // XPCServiceInitializerDelegate::getConnectionIdentifier.
        // MACH_PORT_VALID returns false for both MACH_PORT_NULL and
        // MACH_PORT_DEAD (any port name whose top bit indicates the dead-name
        // sentinel); replicate that here with the same bit-test the kernel
        // header (mach/port.h) does.
        guard let initializerMessage else {
            // No initializer message means we can't extract a server port —
            // matches the C++ delegate returning false from getConnectionIdentifier.
            exitProcessFailure()
        }
        params.serverPort = xpcDictionaryCopyMachSend(initializerMessage, "server-port")
        if !machPortIsValid(params.serverPort) {
            exitProcessFailure()
        }

        // Step 9: Read the client identifier. Empty is an error. Matches
        // XPCServiceInitializerDelegate::getClientIdentifier.
        if let cStr = xpcDictionaryGetString(initializerMessage, "client-identifier") {
            params.clientIdentifier = Swift.String(cString: cStr)
        }
        if params.clientIdentifier.isEmpty {
            exitProcessFailure()
        }

        // Step 10: Read the client bundle identifier. Empty is OK — host
        // processes (e.g. command line apps) may not have a bundle identifier.
        // Matches XPCServiceInitializerDelegate::getClientBundleIdentifier
        // followed by the comment in the template body "// The host process
        // may not have a bundle identifier...".
        if let cStr = xpcDictionaryGetString(initializerMessage, "client-bundle-identifier") {
            params.clientBundleIdentifier = Swift.String(cString: cStr)
        }

        // Step 11: Read the process identifier ("process-identifier" string,
        // parsed as uint64). Validation: the value must be a positive integer
        // and not the hash-table-deleted-value sentinel (UINT64_MAX), matching
        // ObjectIdentifierGenericBase<uint64_t>::isValidIdentifier in
        // Source/WTF/wtf/ObjectIdentifier.h. Matches
        // XPCServiceInitializerDelegate::getProcessIdentifier.
        guard let pidCStr = xpcDictionaryGetString(initializerMessage, "process-identifier"),
              let parsedIdentifier = UInt64(Swift.String(cString: pidCStr)),
              parsedIdentifier > 0, parsedIdentifier != UInt64.max else {
            exitProcessFailure()
        }
        params.processIdentifier = parsedIdentifier

        // Step 12: Read the UI process name. Empty is an error. Matches
        // XPCServiceInitializerDelegate::getClientProcessName.
        if let cStr = xpcDictionaryGetString(initializerMessage, "ui-process-name") {
            params.uiProcessName = Swift.String(cString: cStr)
        }
        if params.uiProcessName.isEmpty {
            exitProcessFailure()
        }

        // Step 13: Replace the task default voucher with whatever XPC
        // propagated. voucher_replace_default_voucher writes the propagated
        // voucher into the task; the call is idempotent given the same
        // propagated voucher.
        voucher_replace_default_voucher()

        // Step 14: Apply the QoS class cap if the parent process requested it.
        // HAVE(QOS_CLASSES) is on for all Cocoa platforms (PlatformHave.h), so
        // this is unconditional. Mirrors the C++ template body's
        //   if (parameters.extraInitializationData.contains("always-runs-at-background-priority"_s))
        //       Thread::setGlobalMaxQOSClass(QOS_CLASS_UTILITY);
        if params.extraInitializationData.contains(where: { $0.0 == "always-runs-at-background-priority" }) {
            webKitGPUProcessSetGlobalMaxQOSClassUtility()
        }

        // Step 15: Build the C++ AuxiliaryProcessInitializationParameters and
        // dispatch into WebKit::GPUProcess::singleton().initialize(...). The
        // typed bridge (defined in GPUServiceEntryPoint.mm) takes plain C
        // primitives and constructs the C++ struct fields (String::fromUTF8 for
        // strings, IPC::Connection::Identifier(port, xpcConnection) for the
        // mach send right + XPC connection pair, ObjectIdentifier<...> for the
        // process identifier, HashMap<String, String> built from the parallel
        // key/value C-string arrays).
        callIntoCxxBridge(connection: connection, params: params)

        // Step 16: Run the disableJSC epilogue (matches the tail of
        // WebKit::disableJSC's body — JSC::Config::finalize()). This freezes
        // the JSC config so subsequent code cannot mutate it; the C++ template
        // body relies on the disableJSC RAII shape to do this after the body
        // returns, and we do the same here by calling the typed bridge after
        // the body has finished orchestrating.
        webKitGPUProcessDisableJSCEpilogue()
    }

    // Helper that converts the Swift `params` into the C primitives the typed
    // bridge expects, using nested withCString closures so every C string
    // pointer remains valid for the duration of the call. Pulled out so the
    // main initialize body above isn't dominated by indentation.
    private func callIntoCxxBridge(connection: OpaquePointer, params: GPUProcessInitParameters) {
        params.uiProcessName.withCString { uiProcessNameCStr in
            params.clientIdentifier.withCString { clientIdentifierCStr in
                let clientBundleIdentifierBuffer: [CChar]? = params.clientBundleIdentifier.isEmpty ? nil : Array(params.clientBundleIdentifier.utf8CString)
                let extraKeyBuffers: [[CChar]] = params.extraInitializationData.map { Array($0.0.utf8CString) }
                let extraValueBuffers: [[CChar]] = params.extraInitializationData.map { Array($0.1.utf8CString) }

                clientBundleIdentifierBuffer.withOptionalUnsafeBufferPointer { clientBundleIdentifierCStr in
                    extraKeyBuffers.withUnsafeCStringPointers { keysPointer in
                        extraValueBuffers.withUnsafeCStringPointers { valuesPointer in
                            webKitGPUProcessInitializeAfterSwiftBootstrap(
                                connection,
                                params.serverPort,
                                uiProcessNameCStr,
                                clientIdentifierCStr,
                                clientBundleIdentifierCStr,
                                params.processIdentifier,
                                keysPointer,
                                valuesPointer,
                                params.extraInitializationData.count)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Small helpers

// `[[noreturn]] WTF::exitProcess(int)` does import as Never-returning via
// Swift's C++ interop, but call sites that use `guard ... else { ... }` read
// more clearly with a one-liner. Wrap it here so the call sites can sit in
// `guard ... else { ... }` blocks without needing to repeat the literal exit
// code on every site, and so the wrapper itself is the documented "all-paths
// abort" used by every parameter-extraction failure in this file.
private func exitProcessFailure() -> Never {
    WTF.exitProcess(EXIT_FAILURE)
}

// Mirrors MACH_PORT_VALID from <mach/port.h>: a port name is "valid" when it
// is neither MACH_PORT_NULL (0) nor MACH_PORT_DEAD (((mach_port_name_t)~0)).
// Both Mach macros are visible to Swift as untyped integer literals so we
// build them up via mach_port_t initializers.
private func machPortIsValid(_ port: mach_port_t) -> Bool {
    return port != mach_port_t(0) && port != mach_port_t.max
}

private extension Optional where Wrapped == [CChar] {
    // Calls `body` with an UnsafePointer<CChar>? — nil for the .none case,
    // otherwise a pointer into the contiguous storage of the wrapped array.
    func withOptionalUnsafeBufferPointer<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .none:
            return body(nil)
        case .some(let buffer):
            return buffer.withUnsafeBufferPointer { ptr in body(ptr.baseAddress) }
        }
    }
}

private extension Array where Element == [CChar] {
    // Calls `body` with a buffer of optional C-string pointers (one per
    // wrapped [CChar]). Used to forward the two parallel arrays of
    // extra-init-data keys/values to the C bridge. The pointers are valid
    // only for the duration of the call; the wrapped buffers must outlive
    // it (which is guaranteed by the enclosing nested closures in
    // callIntoCxxBridge).
    func withUnsafeCStringPointers<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
        if isEmpty {
            return body(nil)
        }
        var pointers: [UnsafePointer<CChar>?] = []
        pointers.reserveCapacity(count)
        return withUnsafeCStringPointersRecursive(index: 0, pointers: &pointers, body: body)
    }

    private func withUnsafeCStringPointersRecursive<R>(index: Int, pointers: inout [UnsafePointer<CChar>?], body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
        if index == count {
            return pointers.withUnsafeBufferPointer { buf in body(buf.baseAddress) }
        }
        return self[index].withUnsafeBufferPointer { buf in
            pointers.append(buf.baseAddress)
            return withUnsafeCStringPointersRecursive(index: index + 1, pointers: &pointers, body: body)
        }
    }
}

#endif // ENABLE_GPU_PROCESS_SWIFT
