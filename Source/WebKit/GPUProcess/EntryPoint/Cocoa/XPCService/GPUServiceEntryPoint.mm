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
#import "EnvironmentUtilities.h"
#import "GPUProcess.h"
#import "WKBase.h"
#import "WebKit2Initialize.h"
#import "XPCServiceEntryPoint.h"
#import <JavaScriptCore/ExecutableAllocator.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/Threading.h>
#import <wtf/WTFProcess.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

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
// @_cdecl wrapper (see GPUServiceEntryPoint.swift); the wrapper forwards
// straight to WebKitGPUServiceInitializerImpl below so Swift can migrate
// individual lines out of this body one at a time. The body itself is the
// XPCServiceInitializer<GPUProcess, GPUServiceInitializerDelegate, false>
// template body inlined — keep it line-for-line identical to the template
// when adding new lines so future cross-process refactors stay tractable.
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

#if !ENABLE(GPU_PROCESS_SWIFT)
        // setJSCOptions is owned by Swift (SwiftGPUProcess.initialize) when
        // ENABLE_GPU_PROCESS_SWIFT is on; Swift reads the two JSC bool flags
        // directly out of the "extra-initialization-data" XPC sub-dictionary
        // and calls WebKit::setJSCOptions itself. getExtraInitializationData
        // above still runs so parameters.extraInitializationData is populated
        // for the later QoS check.
        if (initializerMessage) {
            bool enableLockdownMode = parameters.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-lockdown-mode"_s) == "1"_s;
            bool enableEnhancedSecurity = parameters.extraInitializationData.get<HashTranslatorASCIILiteral>("enable-enhanced-security"_s) == "1"_s;
            WebKit::setJSCOptions(initializerMessage, enableLockdownMode ? WebKit::EnableLockdownMode::Yes : WebKit::EnableLockdownMode::No, enableEnhancedSecurity ? WebKit::EnableEnhancedSecurity::Yes : WebKit::EnableEnhancedSecurity::No, /* isWebContentProcess */ false);
        }
#endif

#if !ENABLE(GPU_PROCESS_SWIFT)
        // Loading and publishing the client SDK-aligned behaviors bitset is
        // owned by Swift (SwiftGPUProcess.initialize) when
        // ENABLE_GPU_PROCESS_SWIFT is on; Swift reads the
        // "client-sdk-aligned-behaviors" XPC data blob from the initializer
        // message directly, memcpys it into a default-constructed
        // SDKAlignedBehaviors via C++ interop, and calls
        // WTF::setSDKAlignedBehaviors itself.
        WTF::SDKAlignedBehaviors clientSDKAlignedBehaviors;
        delegate.getClientSDKAlignedBehaviors(clientSDKAlignedBehaviors);
        WTF::setSDKAlignedBehaviors(clientSDKAlignedBehaviors);
#endif

        parameters.processType = WebKit::GPUProcess::processType;
#if !ENABLE(GPU_PROCESS_SWIFT)
        // setAuxiliaryProcessType is owned by Swift (SwiftGPUProcess.initialize)
        // when ENABLE_GPU_PROCESS_SWIFT is on; the call is an idempotent
        // global setter so dropping it here keeps semantics identical.
        WTF::setAuxiliaryProcessType(parameters.processType);
#endif

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
#if !ENABLE(GPU_PROCESS_SWIFT)
        // Owned by SwiftGPUProcess.initialize when ENABLE_GPU_PROCESS_SWIFT is on.
        voucher_replace_default_voucher();
#endif

#if HAVE(QOS_CLASSES)
        if (parameters.extraInitializationData.contains("always-runs-at-background-priority"_s))
            WTF::Thread::setGlobalMaxQOSClass(QOS_CLASS_UTILITY);
#endif

        WebKit::initializeAuxiliaryProcess<WebKit::GPUProcess>(WTF::move(parameters));
#endif // ENABLE(GPU_PROCESS)
    });
}

#if !ENABLE(GPU_PROCESS_SWIFT)

extern "C" WK_EXPORT void GPU_SERVICE_INITIALIZER(xpc_connection_t connection, xpc_object_t initializerMessage);

void GPU_SERVICE_INITIALIZER(xpc_connection_t connection, xpc_object_t initializerMessage)
{
    WebKitGPUServiceInitializerImpl(connection, initializerMessage);
}

#endif // !ENABLE(GPU_PROCESS_SWIFT)
