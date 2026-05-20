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
// to one of the methods below via target.get()->method(args). The shape
// mirrors IPCTesterReceiver.swift / WebBackForwardList.swift.
//
// Three dispatch styles appear below:
//
//   1. Direct C-bridge calls (e.g. clearMockMediaDevices,
//      addMockMediaDevice) — the Swift body invokes a small extern "C"
//      bridge in GPUProcess.cpp, which calls into WebCore. No round-trip
//      through CxxGPUProcess. These are the closest thing to "Swift-native"
//      handlers we currently have; future phases will keep growing this
//      set.
//
//   2. Direct singleton().method(...) calls — possible because
//      CxxGPUProcess is annotated SWIFT_SHARED_REFERENCE in GPUProcess.h,
//      so the clang importer surfaces it as a Swift reference type and
//      WebKit.CxxGPUProcess.singleton() is callable from Swift. Used for
//      handlers whose args are pass-by-value (Bool / int-like / identifier
//      types) or pass-by-rvalue-ref (the importer maps T&& parameters to
//      a `consuming:` argument label).
//
//   3. swiftStub<Method> trampolines (in GPUProcessSwiftUtilities.h) — for
//      cases where styles 1 and 2 don't work yet:
//
//        - Messages with a CompletionHandler reply: the autogen hands
//          Swift a WTF::RefCountable<CompletionHandler<...>>* wrapper.
//          The swiftStub adopts a +1 retain on the wrapper, constructs a
//          fresh C++ CompletionHandler that invokes the wrapper when
//          called, and forwards to CxxGPUProcess. Constructing the
//          forwarding CompletionHandler isn't expressible in Swift.
//
//        - Messages with [RefWrap]'d noncopyable args (e.g.
//          InitializeGPUProcess.processCreationParameters,
//          CreateGPUConnectionToWebProcess.{connectionHandle,parameters}).
//          The shim accepts the autogen's
//          WrappedArgs::GPUProcess::<M>_<param>* (i.e.
//          WTF::RefCountable<X>*) and unwraps via WTFMove(**ptr). The
//          [RefWrap] dance sidesteps swiftc's silent-drop bug for
//          `consuming` noncopyable params (see
//          ~/uncopyable-parameter-thunk-problem/).
//
//        - SecurityOriginData / MockMediaDevice (address-only types whose
//          by-value Swift passage trips an IRGen crash; see
//          ~/swift-gpu-compiler-crash/) are also tagged [RefWrap].
//
//        - consumeAudioComponentRegistrations: surfaced via
//          `using AuxiliaryProcess::consumeAudioComponentRegistrations`,
//          which the clang importer doesn't expose on CxxGPUProcess.
//
// Future phases will keep replacing remaining swiftStub trampolines with
// styles 1 / 2 (or full Swift-native bodies that cut C++ entirely).

final class GPUProcess {
    // Optional just because of an initialization order issue. Always occupied
    // after initialization finished.
    private var messageForwarder: RefGPUProcessMessageForwarder?

    // Phase 2.a: Swift-owned state for the updateGPUProcessPreferences
    // handler. On the ON path the C++ CxxGPUProcess no longer carries
    // m_preferences / m_haveEnabled* (gated out in GPUProcess.h); the body
    // below is a faithful translation of the original C++ method. The
    // optional<bool> vp9DecoderEnabled is modeled as Swift's Bool? — the
    // C++ IPC argument's optional<bool> is unpacked across the language
    // boundary via the WebKitGPUProcessExtractPreferences C bridge because
    // clang's importer doesn't bridge std::optional<bool> to Optional<Bool>.
    #if ENABLE_VP9
    private var vp9DecoderEnabled: Bool?
    private var swVPDecodersAlwaysEnabled: Bool = false
    private var haveEnabledVP9Decoder: Bool = false
    private var haveEnabledSWVP9Decoder: Bool = false
    #endif

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
        // The original C++ body lived in CxxGPUProcess::updateGPUProcessPreferences
        // (now gated out under ENABLE(GPU_PROCESS_SWIFT)=ON). Swift owns the
        // mutable state and dispatches the WebCore static calls via the
        // WebKitGPUProcessVP9* C bridges (defined in GPUProcess.cpp under
        // ENABLE(VP9) && PLATFORM(COCOA)).
        //
        // PLATFORM(COCOA) is implicit on the ON path: ENABLE_GPU_PROCESS_SWIFT
        // is only set in Source/cmake/OptionsMac.cmake, so the COCOA gates from
        // the original body collapse to unconditional code here.
        #if ENABLE_VP9
        // Read the IPC arg's std::optional<bool> vp9DecoderEnabled and plain-
        // bool swVPDecodersAlwaysEnabled out via the C bridge. We can't read
        // those fields from Swift directly because the clang importer doesn't
        // surface std::optional<bool> as Swift Optional<Bool>. Pass a pointer
        // to the consuming arg via withUnsafePointer(to:); the bridge only
        // reads through it.
        var newVP9HasValue: Bool = false
        var newVP9Value: Bool = false
        var newSWVP: Bool = false
        withUnsafePointer(to: preferences) { ptr in
            webKitGPUProcessExtractPreferences(ptr, &newVP9HasValue, &newVP9Value, &newSWVP)
        }
        let newVP9: Bool? = newVP9HasValue ? newVP9Value : nil

        if updatePreference(old: &self.vp9DecoderEnabled, new: newVP9) {
            // Force-unwrap is safe: updatePreference returning true guarantees
            // that self.vp9DecoderEnabled has a value (either freshly assigned
            // from `new`, or defaulted to false in the second branch).
            let resolved = self.vp9DecoderEnabled!
            webKitGPUProcessVP9SetShouldEnableVP9Decoder(resolved)
            if !self.haveEnabledVP9Decoder && resolved {
                self.haveEnabledVP9Decoder = true
                webKitGPUProcessVP9RegisterSupplementalVP9Decoder()
            }
        }

        // The original C++ used std::exchange to atomically swap the stored
        // value and compare against the previous one. Reproduce that here:
        // remember the previous value before assignment, then dispatch only
        // on a delta.
        let previousSWVP = self.swVPDecodersAlwaysEnabled
        self.swVPDecodersAlwaysEnabled = newSWVP
        if newSWVP != previousSWVP {
            webKitGPUProcessVP9SetSWVPDecodersAlwaysEnabled(self.swVPDecodersAlwaysEnabled)
        }

        if !self.haveEnabledSWVP9Decoder && webKitGPUProcessVP9ShouldEnableSWVP9Decoder() {
            webKitGPUProcessVP9RegisterWebKitVP9Decoder()
            self.haveEnabledSWVP9Decoder = true
        }
        #endif // ENABLE_VP9
    }

    // Faithful translation of CxxGPUProcess::updatePreference (now gated out
    // on the ON path). The contract: returns true if the caller should
    // dispatch follow-up work (the slot was populated for the first time, or
    // its value changed). Mirrors the C++ semantics line for line — including
    // the "default to false the first time we see no incoming value" branch.
    private func updatePreference(old: inout Bool?, new: Bool?) -> Bool {
        if let new, old != .some(new) {
            old = new
            return true
        }
        if old == nil {
            old = false
            return true
        }
        return false
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
        // Bridge body lives in GPUProcess.cpp and registers a WebCore
        // muted-speech callback that sends GPUProcessProxy::VoiceActivityDetected.
        // The lambda capture stays in C++; Swift only invokes the bridge.
        webKitGPUProcessSetShouldListenToVoiceActivity(shouldListen)
    }

    func enableMicrophoneMuteStatusAPI() {
        // Bridge body lives in GPUProcess.cpp and registers a WebCore
        // mute-status callback that sends GPUProcessProxy::MicrophoneMuteStatusChanged.
        // The WeakPtr-captured lambda stays in C++; Swift only invokes the bridge.
        webKitGPUProcessEnableMicrophoneMuteStatusAPI()
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
