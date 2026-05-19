/*
 * Copyright (C) 2019-2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"

#import "AuxiliaryProcess.h"
#import "Connection.h"
#import "EnvironmentUtilities.h"
#import "GPUProcess.h"
#import "SandboxUtilities.h"
#import "WKBase.h"
#import "WebKit2Initialize.h"
#import "XPCServiceEntryPoint.h"
#import <JavaScriptCore/ExecutableAllocator.h>
#import <JavaScriptCore/JSCConfig.h>
#import <JavaScriptCore/Options.h>
#import <WebCore/ProcessIdentifier.h>
#import <wtf/Atomics.h>
#import <wtf/MainThread.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/Threading.h>
#import <wtf/WTFConfig.h>
#import <wtf/WTFProcess.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>
#import <wtf/text/WTFString.h>

#if USE(APPLE_INTERNAL_SDK)
#include <os/voucher_private.h>
#endif
#if !USE(RUNNINGBOARD)
#import <wtf/darwin/XPCExtras.h>
#endif

#if ENABLE(GPU_PROCESS)

namespace WebKit {

class GPUServiceInitializerDelegate : public XPCServiceInitializerDelegate {
public:
    GPUServiceInitializerDelegate(OSObjectPtr<xpc_connection_t> connection, xpc_object_t initializerMessage)
        : XPCServiceInitializerDelegate(WTF::move(connection), initializerMessage)
    {
    }
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)

// The GPU process entry point shipped to xpc is named GPUServiceInitializer
// (see GPU_SERVICE_INITIALIZER in XPCServiceEntryPoint.h). When
// ENABLE(GPU_PROCESS_SWIFT) is enabled that symbol is provided by a Swift
// @_cdecl wrapper (see GPUServiceEntryPoint.swift) which routes the call into
// SwiftGPUProcess.initialize; that Swift orchestrator now owns the whole
// XPCServiceInitializer<GPUProcess, GPUServiceInitializerDelegate, false>
// template body and calls the C++ AuxiliaryProcessInitializationParameters
// build + WebKit::GPUProcess::singleton().initialize() through the
// WebKitGPUProcessInitializeAfterSwiftBootstrap typed bridge below.
//
// When ENABLE(GPU_PROCESS_SWIFT) is off, WebKitGPUServiceInitializerImpl is
// still the XPC entry (via the GPU_SERVICE_INITIALIZER trampoline below) and
// runs the entire template body in C++ here. The body and the trampoline are
// both gated under !ENABLE(GPU_PROCESS_SWIFT).
#if !ENABLE(GPU_PROCESS_SWIFT)

extern "C" WK_EXPORT void WebKitGPUServiceInitializerImpl(xpc_connection_t connection, xpc_object_t initializerMessage);

void WebKitGPUServiceInitializerImpl(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    WebKit::disableJSC([&] {
#if ENABLE(GPU_PROCESS)
        WebKit::GPUServiceInitializerDelegate delegate(WTF::move(connection), initializerMessage);

#if !USE(RUNNINGBOARD)
        SUPPRESS_RETAINPTR_CTOR_ADOPT WebKit::setOSTransaction(adoptOSObject(os_transaction_create("WebKit XPC Service")));
#endif

        WebKit::AuxiliaryProcessInitializationParameters parameters;

        if (!delegate.getExtraInitializationData(parameters.extraInitializationData))
            WTF::exitProcess(EXIT_FAILURE);

        if (initializerMessage) {
            bool enableLockdownMode = parameters.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-lockdown-mode"_s) == "1"_s;
            bool enableEnhancedSecurity = parameters.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-enhanced-security"_s) == "1"_s;
            WebKit::setJSCOptions(initializerMessage, enableLockdownMode ? WebKit::EnableLockdownMode::Yes : WebKit::EnableLockdownMode::No, enableEnhancedSecurity ? WebKit::EnableEnhancedSecurity::Yes : WebKit::EnableEnhancedSecurity::No, /* isWebContentProcess */ false);
        }

        WTF::SDKAlignedBehaviors clientSDKAlignedBehaviors;
        delegate.getClientSDKAlignedBehaviors(clientSDKAlignedBehaviors);
        WTF::setSDKAlignedBehaviors(clientSDKAlignedBehaviors);

        parameters.processType = WebKit::CxxGPUProcess::processType;
        WTF::setAuxiliaryProcessType(parameters.processType);

        WebKit::InitializeWebKit2();

        if (!delegate.checkEntitlements())
            WTF::exitProcess(EXIT_FAILURE);

        if (!delegate.getConnectionIdentifier(parameters.connectionIdentifier))
            WTF::exitProcess(EXIT_FAILURE);

        if (!delegate.getClientIdentifier(parameters.clientIdentifier))
            WTF::exitProcess(EXIT_FAILURE);

        // The host process may not have a bundle identifier (e.g. a command line app), so don't require one.
        delegate.getClientBundleIdentifier(parameters.clientBundleIdentifier);

        std::optional<WebCore::ProcessIdentifier> processIdentifier;
        if (!delegate.getProcessIdentifier(processIdentifier))
            WTF::exitProcess(EXIT_FAILURE);
        parameters.processIdentifier = *processIdentifier;

        if (!delegate.getClientProcessName(parameters.uiProcessName))
            WTF::exitProcess(EXIT_FAILURE);

        // Set the task default voucher to the current value (as propagated by XPC).
        voucher_replace_default_voucher();

#if HAVE(QOS_CLASSES)
        if (parameters.extraInitializationData.contains("always-runs-at-background-priority"_s))
            WTF::Thread::setGlobalMaxQOSClass(QOS_CLASS_UTILITY);
#endif

        WebKit::initializeAuxiliaryProcess<WebKit::CxxGPUProcess>(WTF::move(parameters));
#endif // ENABLE(GPU_PROCESS)
    });
}

extern "C" WK_EXPORT void GPU_SERVICE_INITIALIZER(xpc_connection_t connection, xpc_object_t initializerMessage);

void GPU_SERVICE_INITIALIZER(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    WebKitGPUServiceInitializerImpl(connection, initializerMessage);
}

#endif // !ENABLE(GPU_PROCESS_SWIFT)

#if ENABLE(GPU_PROCESS_SWIFT) && ENABLE(GPU_PROCESS)

// Typed bridge invoked by SwiftGPUProcess.initialize at the tail of its
// orchestration, replacing the final
//   WebKit::initializeAuxiliaryProcess<WebKit::GPUProcess>(WTF::move(parameters));
// line of the template body that the Swift side has otherwise reproduced
// in full. Swift extracts every field of AuxiliaryProcessInitializationParameters
// directly from the XPC initializer message and passes them as plain C
// primitives; this function builds the C++ struct and dispatches to
// WebKit::GPUProcess::singleton().initialize(...). The HashMap<String, String>
// extraInitializationData entries are passed as two parallel C-string arrays
// (`extraInitDataKeys` / `extraInitDataValues`, both of length
// `extraInitDataCount`); the connection identifier is the mach send right
// extracted from the XPC message in Swift via xpc_dictionary_copy_mach_send
// plus the connection itself (which IPC::Connection::Identifier holds as an
// OSObjectPtr<xpc_connection_t> alongside the mach port).
extern "C" WK_EXPORT void WebKitGPUProcessInitializeAfterSwiftBootstrap(
    xpc_connection_t connection,
    mach_port_t serverPort,
    const char* uiProcessName,
    const char* clientIdentifier,
    const char* clientBundleIdentifier,
    uint64_t processIdentifierRawValue,
    const char* const* extraInitDataKeys,
    const char* const* extraInitDataValues,
    size_t extraInitDataCount);

void WebKitGPUProcessInitializeAfterSwiftBootstrap(
    xpc_connection_t connection,
    mach_port_t serverPort,
    const char* uiProcessName,
    const char* clientIdentifier,
    const char* clientBundleIdentifier,
    uint64_t processIdentifierRawValue,
    const char* const* extraInitDataKeys,
    const char* const* extraInitDataValues,
    size_t extraInitDataCount)
{
    WebKit::AuxiliaryProcessInitializationParameters parameters;
    parameters.processType = WebKit::CxxGPUProcess::processType;
    parameters.uiProcessName = String::fromUTF8(uiProcessName);
    parameters.clientIdentifier = String::fromUTF8(clientIdentifier);
    if (clientBundleIdentifier && *clientBundleIdentifier)
        parameters.clientBundleIdentifier = String::fromUTF8(clientBundleIdentifier);
    parameters.processIdentifier = ObjectIdentifier<WebCore::ProcessIdentifierType>(processIdentifierRawValue);
    parameters.connectionIdentifier = IPC::Connection::Identifier(serverPort, OSObjectPtr<xpc_connection_t> { connection });
    for (size_t i = 0; i < extraInitDataCount; ++i)
        parameters.extraInitializationData.add(String::fromUTF8(extraInitDataKeys[i]), String::fromUTF8(extraInitDataValues[i]));

    WebKit::initializeAuxiliaryProcess<WebKit::CxxGPUProcess>(WTF::move(parameters));
}

// Thin C bridge for the base XPCServiceInitializerDelegate::checkEntitlements
// behavior — instantiating the delegate is non-trivial from Swift (the
// constructor takes OSObjectPtr<xpc_connection_t>), and the entitlements /
// sandbox-check logic is platform-specific enough that duplicating it in
// Swift would be a footgun. Construct a transient delegate here and forward.
extern "C" WK_EXPORT bool WebKitGPUProcessCheckEntitlements(xpc_connection_t connection, xpc_object_t initializerMessage);

bool WebKitGPUProcessCheckEntitlements(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    WebKit::GPUServiceInitializerDelegate delegate(OSObjectPtr<xpc_connection_t> { connection }, initializerMessage);
    return delegate.checkEntitlements();
}

// Thin C bridge to WebKit::connectedProcessIsSandboxed; Swift needs this to
// decide whether to read the "user-directory-suffix" extra-init key (which the
// C++ XPCServiceInitializerDelegate::getExtraInitializationData also gates on
// !isClientSandboxed()).
extern "C" WK_EXPORT bool WebKitGPUProcessConnectedProcessIsSandboxed(xpc_connection_t connection);

bool WebKitGPUProcessConnectedProcessIsSandboxed(xpc_connection_t connection)
{
    return WebKit::connectedProcessIsSandboxed(connection);
}

// Thin C bridge to WTF::Thread::setGlobalMaxQOSClass(QOS_CLASS_UTILITY).
// HAVE(QOS_CLASSES) is on for all Cocoa platforms (PlatformHave.h), so this
// is unconditional here and Swift can call it unconditionally too.
extern "C" WK_EXPORT void WebKitGPUProcessSetGlobalMaxQOSClassUtility();

void WebKitGPUProcessSetGlobalMaxQOSClassUtility()
{
    WTF::Thread::setGlobalMaxQOSClass(QOS_CLASS_UTILITY);
}

// Typed bridges that reproduce the two halves of WebKit::disableJSC's body
// (Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.mm)
// for the Swift path. The C++ template body in WebKitGPUServiceInitializerImpl
// runs inside disableJSC([&] { ... }); the Swift orchestrator runs the body
// itself, so the prologue (everything before the completion handler invocation)
// and the epilogue (JSC::Config::finalize()) are wrapped here as plain C
// entry points and called from SwiftGPUProcess.initialize before and after the
// Swift body. The g_jscConfig / g_wtfConfig macros expand to inline
// JSC::addressOfJSCConfig() / WTF::addressOfWTFConfig() dereferences and
// JSC::Options::initialize takes a C++ callable, neither of which import
// cleanly into Swift; keeping these as typed shims preserves a line-for-line
// correspondence with WebKit::disableJSC's body.
extern "C" WK_EXPORT void WebKitGPUProcessDisableJSCPrologue();

void WebKitGPUProcessDisableJSCPrologue()
{
    g_jscConfig.vmCreationDisallowed = true;
    g_jscConfig.vmEntryDisallowed = true;
    g_wtfConfig.useSpecialAbortForExtraSecurityImplications = true;

    WTF::initializeMainThread();
    {
        JSC::Options::initialize([] {
            JSC::ExecutableAllocator::disableJIT();
            JSC::Options::useWasm() = false;
        });
    }
    WTF::compilerFence();
}

extern "C" WK_EXPORT void WebKitGPUProcessDisableJSCEpilogue();

void WebKitGPUProcessDisableJSCEpilogue()
{
    JSC::Config::finalize();
}

#endif // ENABLE(GPU_PROCESS_SWIFT) && ENABLE(GPU_PROCESS)
