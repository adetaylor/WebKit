/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#pragma once

#if ENABLE(GPU_PROCESS_SWIFT)

// Stable C++ aliases for the IPC message argument types used by the GPU
// process's Swift message receiver. Swift's C++ interop renders bare
// `std::optional<X>`, `Vector<X>`, `RefPtr<X>`, etc. as Swift type names that
// vary by libc++ release / interop version; pinning each to a hand-written
// `using` here gives the Swift handler signatures (in GPUProcess.swift) a
// predictable spelling. Consumers in Swift refer to these as
// `WebKit.OptionalCaptureDevice` etc.
//
// Mirrors the WebBackForwardListSwiftUtilities.h convention.
//
// Coverage audit (Phase 4.1.c.1): every templated wrapper used in
// GPUProcess.messages.in has an alias here. Bare struct / class / enum /
// identifier types (e.g. WebKit::GPUProcessCreationParameters,
// WebCore::ProcessIdentifier, PAL::SessionID, IPC::ConnectionHandle) are
// imported into Swift directly via their fully-qualified names and do not
// need aliases; if any later turn out to need one, add it here.

#include "CoreIPCAuditToken.h"
#include "GPUProcess.h"
#include "GPUProcessConnectionParameters.h"
#include "GPUProcessCreationParameters.h"
#include "GPUProcessMessages.h"
#include "GPUProcessPreferences.h"
#include "GPUProcessSessionParameters.h"
#include "RemoteSnapshotIdentifier.h"
#include "SandboxExtension.h"
#include "SharedBufferReference.h"
#include "SharedFileHandle.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/CaptureDevice.h>
#include <WebCore/DisplayCapturePromptType.h>
#include <WebCore/FloatSize.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/IntDegrees.h>
#include <WebCore/MediaPlayerIdentifier.h>
#include <WebCore/MockMediaDevice.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/ScreenProperties.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/ShareableBitmap.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/VideoFrame.h>
#include <WebCore/VideoFrameMetadata.h>
#include <pal/SessionID.h>
#include <span>
#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Ref.h>
#include <wtf/RefCountable.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

namespace WebKit {

// std::optional<X> aliases — one per X used by GPUProcess.messages.in's
// reply / argument types.
using OptionalCaptureDevice = std::optional<WebCore::CaptureDevice>;
using OptionalCoreIPCAuditToken = std::optional<WebKit::CoreIPCAuditToken>;
using OptionalProcessIdentity = std::optional<WebCore::ProcessIdentity>;
using OptionalShareableBitmapHandle = std::optional<WebCore::ShareableBitmapHandle>;
using OptionalSharedFileHandle = std::optional<IPC::SharedFileHandle>;
using OptionalString = std::optional<String>;

// Vector<X> aliases.
using VectorSandboxExtensionHandle = Vector<WebKit::SandboxExtension::Handle>;
using VectorString = Vector<String>;

// RefPtr<X> alias (only one variant for now — the SinkCompletedSnapshotToPDF
// reply).
using RefPtrSharedBuffer = RefPtr<WebCore::SharedBuffer>;

// std::span<X> alias used by ResolveBookmarkDataForCacheDirectory.
using SpanConstUint8 = std::span<const uint8_t>;

// ---------------------------------------------------------------------------
// Swift→C++ shim functions for GPUProcess IPC dispatch.
//
// The autogen-generated GPUProcessMessageForwarder dispatches every IPC
// message via target.get()->method(args, completionHandler) where target is
// the Swift class GPUProcess. The Swift handler bodies in GPUProcess.swift
// call these inline shims to forward each message back to the existing C++
// implementations on CxxGPUProcess::singleton().
//
// Two reasons every handler goes through a shim (even the no-reply ones):
//   1. Swift's clang importer does not currently surface
//      WebKit::CxxGPUProcess directly (multiple inheritance + CRTP), so the
//      Swift handler can't write `WebKit.CxxGPUProcess.singleton().method()`.
//   2. For messages with completion handlers, the autogen passes Swift a
//      WTF::RefCountable<CompletionHandler<...>>* wrapper. The C++ method on
//      CxxGPUProcess takes CompletionHandler<...>&&. Each completion-handler
//      shim adopts a +1 retain on the wrapper, constructs a fresh C++
//      CompletionHandler that invokes the wrapper when called, and forwards
//      to CxxGPUProcess::singleton().method(args, freshHandler).
//
// For the three messages with [RefWrap]-annotated noncopyable arguments
// (InitializeGPUProcess.processCreationParameters,
// CreateGPUConnectionToWebProcess.connectionHandle/parameters), the shim
// signature accepts the autogen's WrappedArgs::GPUProcess::<M>_<param>*
// (i.e. WTF::RefCountable<X>*) and unwraps via WTFMove(**ptr) before calling
// CxxGPUProcess. Sidesteps swiftc's silent-drop bug for `consuming`
// noncopyable params (see ~/uncopyable-parameter-thunk-problem/).

inline void swiftStubRemoveSession(PAL::SessionID sessionID)
{
    CxxGPUProcess::singleton().removeSession(sessionID);
}

#if ENABLE(MEDIA_STREAM)
inline void swiftStubUpdateCaptureOrigin(WrappedArgs::GPUProcess::UpdateCaptureOrigin_originData* originData, WebCore::ProcessIdentifier processID)
{
    Ref originDataRef = *originData;
    CxxGPUProcess::singleton().updateCaptureOrigin(*originDataRef.get(), processID);
}
#endif // ENABLE(MEDIA_STREAM)

#if HAVE(SCREEN_CAPTURE_KIT)
#endif

#if HAVE(AUDIO_COMPONENT_SERVER_REGISTRATIONS)
inline void swiftStubConsumeAudioComponentRegistrations(IPC::SharedBufferReference registrationData)
{
    CxxGPUProcess::singleton().consumeAudioComponentRegistrations(registrationData);
}
#endif

inline void swiftStubInitializeGPUProcess(WrappedArgs::GPUProcess::InitializeGPUProcess_processCreationParameters* processCreationParameters, WTF::RefCountable<WTF::CompletionHandler<void()>>* handler)
{
    Ref handlerRef = *handler;
    Ref paramsRef = *processCreationParameters;
    CxxGPUProcess::singleton().initializeGPUProcess(WTF::move(*paramsRef.get()),
        WTF::CompletionHandler<void()>([handlerRef = WTF::move(handlerRef)] () mutable {
            (*handlerRef.get())();
        }));
}

inline void swiftStubCreateGPUConnectionToWebProcess(WebCore::ProcessIdentifier processIdentifier, PAL::SessionID sessionID, WrappedArgs::GPUProcess::CreateGPUConnectionToWebProcess_connectionHandle* connectionHandle, WrappedArgs::GPUProcess::CreateGPUConnectionToWebProcess_parameters* parameters, WTF::RefCountable<WTF::CompletionHandler<void()>>* handler)
{
    Ref handlerRef = *handler;
    Ref handleRef = *connectionHandle;
    Ref paramsRef = *parameters;
    CxxGPUProcess::singleton().createGPUConnectionToWebProcess(processIdentifier, sessionID, WTF::move(*handleRef.get()), WTF::move(*paramsRef.get()),
        WTF::CompletionHandler<void()>([handlerRef = WTF::move(handlerRef)] () mutable {
            (*handlerRef.get())();
        }));
}

inline void swiftStubSharedPreferencesForWebProcessDidChange(WebCore::ProcessIdentifier processIdentifier, SharedPreferencesForWebProcess sharedPreferencesForWebProcess, WTF::RefCountable<WTF::CompletionHandler<void()>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().sharedPreferencesForWebProcessDidChange(processIdentifier, WTF::move(sharedPreferencesForWebProcess),
        WTF::CompletionHandler<void()>([handlerRef = WTF::move(handlerRef)] () mutable {
            (*handlerRef.get())();
        }));
}

inline void swiftStubPrepareToSuspend(bool isSuspensionImminent, MonotonicTime estimatedSuspendTime, WTF::RefCountable<WTF::CompletionHandler<void()>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().prepareToSuspend(isSuspensionImminent, estimatedSuspendTime,
        WTF::CompletionHandler<void()>([handlerRef = WTF::move(handlerRef)] () mutable {
            (*handlerRef.get())();
        }));
}

#if ENABLE(MEDIA_STREAM)
inline void swiftStubUpdateCaptureAccess(bool allowAudioCapture, bool allowVideoCapture, bool allowDisplayCapture, WebCore::ProcessIdentifier processID, WTF::RefCountable<WTF::CompletionHandler<void()>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().updateCaptureAccess(allowAudioCapture, allowVideoCapture, allowDisplayCapture, processID,
        WTF::CompletionHandler<void()>([handlerRef = WTF::move(handlerRef)] () mutable {
            (*handlerRef.get())();
        }));
}
#endif

#if PLATFORM(COCOA)
inline void swiftStubSinkCompletedSnapshotToPDF(RemoteSnapshotIdentifier identifier, WebCore::FloatSize size, WebCore::FrameIdentifier rootFrameIdentifier, WTF::RefCountable<WTF::CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().sinkCompletedSnapshotToPDF(identifier, size, rootFrameIdentifier,
        WTF::CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>([handlerRef = WTF::move(handlerRef)] (RefPtr<WebCore::SharedBuffer>&& result) mutable {
            (*handlerRef.get())(WTF::move(result));
        }));
}
#endif

inline void swiftStubSinkCompletedSnapshotToBitmap(RemoteSnapshotIdentifier identifier, WebCore::FloatSize size, WebCore::FrameIdentifier rootFrameIdentifier, WTF::RefCountable<WTF::CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().sinkCompletedSnapshotToBitmap(identifier, size, rootFrameIdentifier,
        WTF::CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>&&)>([handlerRef = WTF::move(handlerRef)] (std::optional<WebCore::ShareableBitmap::Handle>&& image) mutable {
            (*handlerRef.get())(WTF::move(image));
        }));
}

#if HAVE(SCREEN_CAPTURE_KIT)
inline void swiftStubPromptForGetDisplayMedia(WebCore::DisplayCapturePromptType type, WTF::RefCountable<WTF::CompletionHandler<void(std::optional<WebCore::CaptureDevice>&&)>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().promptForGetDisplayMedia(type,
        WTF::CompletionHandler<void(std::optional<WebCore::CaptureDevice>)>([handlerRef = WTF::move(handlerRef)] (std::optional<WebCore::CaptureDevice> device) mutable {
            (*handlerRef.get())(WTF::move(device));
        }));
}
#endif

#if ENABLE(WEBXR)
inline void swiftStubWebXRPromptAccepted(std::optional<WebCore::ProcessIdentity> processIdentity, WTF::RefCountable<WTF::CompletionHandler<void(bool)>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().webXRPromptAccepted(WTF::move(processIdentity),
        WTF::CompletionHandler<void(bool)>([handlerRef = WTF::move(handlerRef)] (bool accepted) mutable {
            (*handlerRef.get())(accepted);
        }));
}
#endif

#if PLATFORM(COCOA)
inline void swiftStubPostWillTakeSnapshotNotification(WTF::RefCountable<WTF::CompletionHandler<void()>>* handler)
{
    Ref handlerRef = *handler;
    CxxGPUProcess::singleton().postWillTakeSnapshotNotification(
        WTF::CompletionHandler<void()>([handlerRef = WTF::move(handlerRef)] () mutable {
            (*handlerRef.get())();
        }));
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_SWIFT)
