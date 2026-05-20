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

import WebKit_Internal

// Swift IPC receiver class that mirrors WebKit::CxxGPUProcess. The
// autogen-generated GPUProcessMessageForwarder dispatches every IPC message
// to one of the methods below via target.get()->method(args). Each method
// here is a stub forwarder that re-enters the existing C++ implementation
// on CxxGPUProcess::singleton() via a swiftStub<Method> shim in
// GPUProcessSwiftUtilities.h. The shape mirrors IPCTesterReceiver.swift /
// WebBackForwardList.swift.
//
// Why every method goes through a shim (even the no-reply ones):
// Swift's clang importer doesn't currently surface the WebKit::CxxGPUProcess
// type as a usable Swift type (multiple inheritance + CRTP), so the Swift
// handler bodies have no way to call CxxGPUProcess::singleton().method(args)
// directly. The inline shims in GPUProcessSwiftUtilities.h take the args by
// value (or by foreign-reference pointer for [RefWrap] noncopyable args), do
// the singleton call on the C++ side, and return.
//
// Three messages have noncopyable arguments tagged [RefWrap] in
// GPUProcess.messages.in (InitializeGPUProcess.processCreationParameters,
// CreateGPUConnectionToWebProcess.connectionHandle/parameters). For those,
// the autogen wraps the decoded arg in WTF::RefCountable<X> and the Swift
// signature names the autogen-emitted typedef
// `WrappedArgs.GPUProcess.<Message>_<param>`. Without the wrap, swiftc would
// silently drop the method from WebKit-Swift-CPP.h (consuming-noncopyable
// thunk emit fails); see ~/uncopyable-parameter-thunk-problem/ for the
// repro and Phase 4.1.c.0.b for the autogen change.
//
// Future phases will replace each forwarder body with a Swift-native
// implementation (eliminating the round-trip through C++).

final class GPUProcess {
    // Optional just because of an initialization order issue. Always occupied
    // after initialization finished.
    private var messageForwarder: RefGPUProcessMessageForwarder?

    init() {
        self.messageForwarder = WebKit.GPUProcessMessageForwarder.create(target: self)
    }

    func getMessageReceiver() -> RefGPUProcessMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    // MARK: - Messages without a reply

    func updateGPUProcessPreferences(preferences: consuming WebKit.GPUProcessPreferences) {
        WebKit.CxxGPUProcess.singleton().updateGPUProcessPreferences(consuming: preferences)
    }

    func updateSandboxAccess(extensions: consuming WebKit.VectorSandboxExtensionHandle) {
        WebKit.CxxGPUProcess.singleton().updateSandboxAccess(extensions)
    }

    func processDidResume() {
        // No-op: the C++ body is just RELEASE_LOG(ProcessSuspension, ...) +
        // CxxGPUProcess::resume() which is itself empty. Once WTF logging is
        // available from Swift (rdar://168139823) this will regain the log
        // line; until then the loss is accepted.
    }

    func addSession(sessionID: PAL.SessionID, parameters: consuming WebKit.GPUProcessSessionParameters) {
        WebKit.CxxGPUProcess.singleton().addSession(sessionID, consuming: parameters)
    }

    func removeSession(sessionID: PAL.SessionID) {
        WebKit.CxxGPUProcess.singleton().removeSession(sessionID)
    }

    func userPreferredLanguagesChanged(languages: consuming WebKit.VectorString) {
        // Forward Vector<String> -> (const char* const*, size_t count) via the
        // helper in GPUProcessSwiftStdlibExtras.swift, which iterates the
        // WTF::Vector through GPUCxxVectorIterator and builds a contiguous
        // pointer buffer for the closure body. The C bridge reconstructs a
        // Vector<String> via String::fromUTF8 and calls the WTF API.
        // `consuming` matches both sides: the autogen-generated forwarder hands
        // us a `consuming WebKit.VectorString`, and `withCStringPointersForGPU`
        // is itself `consuming` because it feeds `GPUCxxVectorIterator`, which
        // takes the vector by value (the iterator stores it).
        languages.withCStringPointersForGPU { pointers, count in
            webKitGPUProcessOverrideUserPreferredLanguages(pointers, count)
        }
    }

    #if ENABLE_MEDIA_STREAM
    func setMockCaptureDevicesEnabled(isEnabled: Bool) {
        webKitGPUProcessSetMockRealtimeMediaSourceCenterEnabled(isEnabled)
    }

    func setOrientationForMediaCapture(orientation: WebCore.IntDegrees) {
        WebKit.CxxGPUProcess.singleton().setOrientationForMediaCapture(orientation)
    }

    func rotationAngleForCaptureDeviceChanged(persistentId: WTF.String, rotation: WebCore.VideoFrameRotation) {
        WebKit.CxxGPUProcess.singleton().rotationAngleForCaptureDeviceChanged(persistentId, rotation)
    }

    // SecurityOriginData is an "address-only" C++ class (holds a WTF::String,
    // hence non-trivial copy semantics). Passing it by value through a Swift
    // method body crashes swift-frontend during IR generation
    // (AddressOnlyCXXClangRecordTypeInfo::emitCopyWithCopyOrMoveConstructor —
    // see ~/swift-gpu-compiler-crash/ for the standalone reproducer).
    // Workaround: tag with [RefWrap] in messages.in and take the autogen-
    // emitted RefCountable<...>* form here, sidestepping the by-value path.
    func updateCaptureOrigin(originData: WrappedArgs.GPUProcess.UpdateCaptureOrigin_originData, processID: WebCore.ProcessIdentifier) {
        WebKit.swiftStubUpdateCaptureOrigin(originData, processID)
    }

    func addMockMediaDevice(device: WrappedArgs.GPUProcess.AddMockMediaDevice_device) {
        webKitGPUProcessMockMediaCenterAddDeviceFromWrap(device)
    }

    func clearMockMediaDevices() {
        // First handler with a Swift-native body. The previous stub routed
        // forwarder -> Swift::clearMockMediaDevices -> swiftStubClear... ->
        // CxxGPUProcess::clearMockMediaDevices -> @_cdecl Swift -> C bridge.
        // Now: forwarder -> Swift::clearMockMediaDevices -> C bridge directly.
        // The @_cdecl shim and the swiftStub forwarder are dead on the
        // ENABLE(GPU_PROCESS_SWIFT)=ON path now; they remain for the OFF
        // path where the C++ dispatcher still calls CxxGPUProcess::clearMockMediaDevices.
        webKitGPUProcessMockMediaCenterSetDevicesEmpty()
    }

    func removeMockMediaDevice(persistentId: WTF.String) {
        // Forward WTF::String -> const char* via the WTF.String.withCStringForGPU
        // helper in GPUProcessSwiftStdlibExtras.swift. The C bridge calls
        // String::fromUTF8 to reconstruct on the C++ side.
        persistentId.withCStringForGPU { cStr in
            if let cStr {
                webKitGPUProcessMockMediaCenterRemoveDevice(cStr)
            }
        }
    }

    func setMockMediaDeviceIsEphemeral(persistentId: WTF.String, isEphemeral: Bool) {
        persistentId.withCStringForGPU { cStr in
            if let cStr {
                webKitGPUProcessMockMediaCenterSetDeviceIsEphemeral(cStr, isEphemeral)
            }
        }
    }

    func resetMockMediaDevices() {
        webKitGPUProcessMockMediaCenterResetDevices()
    }

    func setMockCaptureDevicesInterrupted(isCameraInterrupted: Bool, isMicrophoneInterrupted: Bool) {
        webKitGPUProcessMockMediaCenterSetCaptureDevicesInterrupted(isCameraInterrupted, isMicrophoneInterrupted)
    }

    func triggerMockCaptureConfigurationChange(forCamera: Bool, forMicrophone: Bool, forDisplay: Bool) {
        webKitGPUProcessMockMediaCenterTriggerCaptureConfigurationChange(forCamera, forMicrophone, forDisplay)
    }

    func setShouldListenToVoiceActivity(shouldListen: Bool) {
        WebKit.CxxGPUProcess.singleton().setShouldListenToVoiceActivity(shouldListen)
    }

    func enableMicrophoneMuteStatusAPI() {
        WebKit.CxxGPUProcess.singleton().enableMicrophoneMuteStatusAPI()
    }
    #endif // ENABLE_MEDIA_STREAM

    // PLATFORM(MAC)-only, but PLATFORM_MAC is not exposed to Swift, so the
    // Swift method declaration is unconditional. The autogen forwarder cpp
    // is gated on the same C++ macro and will not dispatch this message on
    // non-Mac platforms; the swiftStub shim is also gated, so the Swift body
    // is dead code on non-Mac builds (link-time elimination).
    func setScreenProperties(screenProperties: consuming WebCore.ScreenProperties) {
        WebKit.CxxGPUProcess.singleton().setScreenProperties(screenProperties)
    }

    func releaseSnapshot(identifier: WebKit.RemoteSnapshotIdentifier) {
        WebKit.CxxGPUProcess.singleton().releaseSnapshot(identifier)
    }

    func cancelGetDisplayMediaPrompt() {
        webKitGPUProcessScreenCaptureKitSharingSessionManagerCancelGetDisplayMediaPrompt()
    }

    func openDirectoryCacheInvalidated(handle: consuming WebKit.SandboxExtensionHandle) {
        WebKit.CxxGPUProcess.singleton().openDirectoryCacheInvalidated(consuming: handle)
    }

    func consumeAudioComponentRegistrations(registrationData: consuming IPC.SharedBufferReference) {
        // Swift can't see CxxGPUProcess.consumeAudioComponentRegistrations because
        // it's pulled in via `using AuxiliaryProcess::consumeAudioComponentRegistrations`,
        // which the clang importer doesn't surface on the derived class. Stay on the
        // swiftStub trampoline for this one.
        WebKit.swiftStubConsumeAudioComponentRegistrations(registrationData)
    }

    func enablePowerLogging(handle: consuming WebKit.SandboxExtensionHandle) {
        WebKit.CxxGPUProcess.singleton().enablePowerLogging(consuming: handle)
    }

    func setPresentingApplicationAuditToken(processIdentifier: WebCore.ProcessIdentifier, pageIdentifier: WebCore.PageIdentifier, auditToken: consuming WebKit.OptionalCoreIPCAuditToken) {
        WebKit.CxxGPUProcess.singleton().setPresentingApplicationAuditToken(processIdentifier, pageIdentifier, consuming: auditToken)
    }

    func registerFonts(sandboxExtensions: consuming WebKit.VectorSandboxExtensionHandle) {
        WebKit.CxxGPUProcess.singleton().registerFonts(consuming: sandboxExtensions)
    }

    // MARK: - Messages with a reply (forwarded via swiftStub<Method> shims)
    //
    // Three of these (initializeGPUProcess, createGPUConnectionToWebProcess)
    // take noncopyable args via the autogen-emitted WrappedArgs typedef.
    // sharedPreferencesForWebProcessDidChange / prepareToSuspend etc. take
    // their args with `consuming` because the wrappee is copyable.

    func initializeGPUProcess(processCreationParameters: WrappedArgs.GPUProcess.InitializeGPUProcess_processCreationParameters,
                              completionHandler: CompletionHandlers.GPUProcess.InitializeGPUProcessCompletionHandler) {
        WebKit.swiftStubInitializeGPUProcess(processCreationParameters, completionHandler)
    }

    func createGPUConnectionToWebProcess(processIdentifier: WebCore.ProcessIdentifier,
                                         sessionID: PAL.SessionID,
                                         connectionHandle: WrappedArgs.GPUProcess.CreateGPUConnectionToWebProcess_connectionHandle,
                                         parameters: WrappedArgs.GPUProcess.CreateGPUConnectionToWebProcess_parameters,
                                         completionHandler: CompletionHandlers.GPUProcess.CreateGPUConnectionToWebProcessCompletionHandler) {
        WebKit.swiftStubCreateGPUConnectionToWebProcess(processIdentifier, sessionID, connectionHandle, parameters, completionHandler)
    }

    func sharedPreferencesForWebProcessDidChange(processIdentifier: WebCore.ProcessIdentifier,
                                                 sharedPreferencesForWebProcess: consuming WebKit.SharedPreferencesForWebProcess,
                                                 completionHandler: CompletionHandlers.GPUProcess.SharedPreferencesForWebProcessDidChangeCompletionHandler) {
        WebKit.swiftStubSharedPreferencesForWebProcessDidChange(processIdentifier, sharedPreferencesForWebProcess, completionHandler)
    }

    func prepareToSuspend(isSuspensionImminent: Bool,
                          estimatedSuspendTime: WTF.MonotonicTime,
                          completionHandler: CompletionHandlers.GPUProcess.PrepareToSuspendCompletionHandler) {
        WebKit.swiftStubPrepareToSuspend(isSuspensionImminent, estimatedSuspendTime, completionHandler)
    }

    #if ENABLE_MEDIA_STREAM
    func updateCaptureAccess(allowAudioCapture: Bool,
                             allowVideoCapture: Bool,
                             allowDisplayCapture: Bool,
                             processID: WebCore.ProcessIdentifier,
                             completionHandler: CompletionHandlers.GPUProcess.UpdateCaptureAccessCompletionHandler) {
        WebKit.swiftStubUpdateCaptureAccess(allowAudioCapture, allowVideoCapture, allowDisplayCapture, processID, completionHandler)
    }
    #endif

    func sinkCompletedSnapshotToPDF(identifier: WebKit.RemoteSnapshotIdentifier,
                                    size: WebCore.FloatSize,
                                    rootFrameIdentifier: WebCore.FrameIdentifier,
                                    completionHandler: CompletionHandlers.GPUProcess.SinkCompletedSnapshotToPDFCompletionHandler) {
        WebKit.swiftStubSinkCompletedSnapshotToPDF(identifier, size, rootFrameIdentifier, completionHandler)
    }

    func sinkCompletedSnapshotToBitmap(identifier: WebKit.RemoteSnapshotIdentifier,
                                       size: WebCore.FloatSize,
                                       rootFrameIdentifier: WebCore.FrameIdentifier,
                                       completionHandler: CompletionHandlers.GPUProcess.SinkCompletedSnapshotToBitmapCompletionHandler) {
        WebKit.swiftStubSinkCompletedSnapshotToBitmap(identifier, size, rootFrameIdentifier, completionHandler)
    }

    func promptForGetDisplayMedia(type: WebCore.DisplayCapturePromptType,
                                  completionHandler: CompletionHandlers.GPUProcess.PromptForGetDisplayMediaCompletionHandler) {
        WebKit.swiftStubPromptForGetDisplayMedia(type, completionHandler)
    }

    func webProcessConnectionCountForTesting(completionHandler: CompletionHandlers.GPUProcess.WebProcessConnectionCountForTestingCompletionHandler) {
        completionHandler.pointee(webKitGPUProcessConnectionToWebProcessObjectCount())
    }

    #if ENABLE_WEBXR
    func webXRPromptAccepted(processIdentity: consuming WebKit.OptionalProcessIdentity,
                             completionHandler: CompletionHandlers.GPUProcess.WebXRPromptAcceptedCompletionHandler) {
        WebKit.swiftStubWebXRPromptAccepted(processIdentity, completionHandler)
    }
    #endif

    // PLATFORM(VISION) && ENABLE(MODEL_PROCESS)-gated handlers
    // (RequestSharedSimulationConnection, CreateMemoryAttributionIDForTask,
    // UnregisterMemoryAttributionID), and USE(EXTENSIONKIT)-gated
    // ResolveBookmarkDataForCacheDirectory, are omitted: those autogen
    // CompletionHandlers / shim symbols only exist when the C++ gate is
    // true, and PLATFORM_VISION / USE_EXTENSIONKIT are not exposed to
    // Swift's conditional compilation flag set. The autogen forwarder cpp is
    // gated on the same C++ macros, so on non-VISION / non-EXTENSIONKIT
    // platforms these messages never reach the Swift class. Re-add them
    // when WebKit gains a way to surface those flags to Swift.

    func postWillTakeSnapshotNotification(completionHandler: CompletionHandlers.GPUProcess.PostWillTakeSnapshotNotificationCompletionHandler) {
        WebKit.swiftStubPostWillTakeSnapshotNotification(completionHandler)
    }
}

#endif // ENABLE_GPU_PROCESS_SWIFT
