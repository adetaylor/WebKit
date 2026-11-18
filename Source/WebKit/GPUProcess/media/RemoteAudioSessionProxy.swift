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

#if ENABLE_GPU_PROCESS && USE_AUDIO_SESSION

import WebKit_Internal

@MainActor
private var lastAudioSessionProxyIdentifier: UInt64 = 0

// Receives the audio session messages of one web process's connection to the GPU process, which owns it
// (GPUConnectionState). What the web process asks of the audio session is its state, which the arbiter
// (RemoteAudioSessionProxyManager.swift) applies to the GPU process's audio session once the proxy joins the arbitration,
// with its first message or when the web process asks for the session's configuration.
@_expose(Cxx)
final class RemoteAudioSessionProxy {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefRemoteAudioSessionProxyMessageForwarder?
    // The connection, until it closes: the connection's Swift state, which the connection holds, holds this.
    private var connection: WebKit.GPUConnectionToWebProcess?
    private let state: AudioSessionProxyState

    @_expose(!Cxx)
    @MainActor
    init(connection: WebKit.GPUConnectionToWebProcess, processIdentifier: UInt64) {
        self.connection = connection
        lastAudioSessionProxyIdentifier += 1
        state = AudioSessionProxyState(identifier: lastAudioSessionProxyIdentifier, processIdentifier: processIdentifier, connection: connection)
        self.messageForwarder = WebKit.RemoteAudioSessionProxyMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteAudioSessionProxyMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        // The connection dispatches the receiver's messages on the main thread, which alone changes `connection`.
        MainActor.preconditionIsolated()
        guard let connection else {
            return WebKit.OptionalSharedPreferencesForWebProcess()
        }
        return connection.sharedPreferencesForWebProcess()
    }

    // The configuration of the GPU process's audio session, as the web process sees it, once the proxy has joined the
    // arbitration.
    @_expose(!Cxx)
    @MainActor
    func ensureConfiguration() -> IPCTypes.RemoteAudioSessionConfiguration {
        state.join()
        return state.configuration
    }

    #if WTF_PLATFORM_IOS_FAMILY
    @_expose(!Cxx)
    @MainActor
    func setPreferredSpeakerID(_ speakerID: String) {
        state.join()
        state.setPreferredSpeakerID(speakerID)
    }
    #endif

    // MARK: Messages

    @MainActor
    func setCategory(
        connection: IPC.Connection,
        type: IPCTypes.AudioSessionCategory,
        mode: IPCTypes.AudioSessionMode,
        policy: IPCTypes.RouteSharingPolicy
    ) {
        state.join()
        if state.category == type && state.mode == mode && state.routeSharingPolicy == policy && !state.isPlayingToBluetoothOverrideChanged {
            return
        }
        state.category = type
        state.mode = mode
        state.routeSharingPolicy = policy
        state.isPlayingToBluetoothOverrideChanged = false
        audioSessionArbiter.updateCategory()
    }

    @MainActor
    func setPreferredBufferSize(connection: IPC.Connection, preferredBufferSize: UInt64) {
        state.join()
        state.preferredBufferSize = preferredBufferSize
        audioSessionArbiter.updatePreferredBufferSize()
    }

    @MainActor
    func tryToSetActive(connection: IPC.Connection, active: Bool) async -> Bool {
        await state.tryToSetActive(active)
    }

    @MainActor
    func tryToSetActiveSync(connection: IPC.Connection, active: Bool) async -> Bool {
        await state.tryToSetActive(active)
    }

    @MainActor
    func setIsPlayingToBluetoothOverride(connection: IPC.Connection, value: Bool?) {
        state.join()
        state.isPlayingToBluetoothOverrideChanged = true
        WebCore.AudioSession.singleton().setOrClearIsPlayingToBluetoothOverride(value != nil, value ?? false)
    }

    @MainActor
    func triggerBeginInterruptionForTesting(connection: IPC.Connection) {
        state.join()
        WebCore.AudioSession.singleton().beginInterruptionForTesting()
    }

    @MainActor
    func triggerEndInterruptionForTesting(connection: IPC.Connection) {
        state.join()
        WebCore.AudioSession.singleton().endInterruptionForTesting()
    }

    // The category the GPU process applied to the real session, after reconciling what every web process reported. Each
    // process's own AudioSession only knows the value it asked for.
    @MainActor
    func systemCategoryForTesting(connection: IPC.Connection) -> IPCTypes.AudioSessionCategory {
        state.join()
        return IPCTypes.AudioSessionCategory(WebCore.AudioSession.singleton().category())
    }

    // How many times the GPU process made the real session active.
    @MainActor
    func systemActivationCountForTesting(connection: IPC.Connection) -> UInt64 {
        state.join()
        return WebCore.AudioSession.singleton().activationCountForTesting()
    }

    @MainActor
    func beginInterruptionRemote(connection: IPC.Connection) {
        state.join()
        audioSessionArbiter.beginInterruptionRemote()
    }

    @MainActor
    func endInterruptionRemote(connection: IPC.Connection, flags: IPCTypes.AudioSessionMayResume) {
        state.join()
        audioSessionArbiter.endInterruptionRemote(mayResume: flags == .yes)
    }

    @MainActor
    func setSceneIdentifier(connection: IPC.Connection, sceneIdentifier: String?) {
        state.join()
        state.sceneIdentifier = sceneIdentifier
        audioSessionArbiter.updateSpatialExperience()
    }

    @MainActor
    func setSoundStageSize(connection: IPC.Connection, size: IPCTypes.AudioSessionSoundStageSize) {
        state.join()
        state.soundStageSize = size
        audioSessionArbiter.updateSpatialExperience()
    }
}

extension RemoteAudioSessionProxy: GPUConnectionReceiver {
    @_expose(!Cxx)
    @MainActor
    var allowsExitUnderMemoryPressure: Bool {
        true
    }

    @_expose(!Cxx)
    @MainActor
    func connectionDidClose() {
        connection = nil
        state.leave()
    }
}

extension WebKit.GPUConnectionToWebProcess {
    @MainActor
    func ensureAudioSession(connection: IPC.Connection) -> IPCTypes.RemoteAudioSessionConfiguration {
        guard let audioSessionProxy = state.audioSessionProxy else {
            preconditionFailure("The connection has no audio session receiver")
        }
        return audioSessionProxy.ensureConfiguration()
    }

    #if WTF_PLATFORM_IOS_FAMILY
    // Unsafe: C++ lends the speaker ID for the call, which only reads it.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func setAudioSessionPreferredSpeakerID(_ speakerID: borrowing WTF.String) {
        state.audioSessionProxy?.setPreferredSpeakerID(IPCCoding.WTFString.swiftString(speakerID) ?? "")
    }
    #endif
}

#endif // ENABLE_GPU_PROCESS && USE_AUDIO_SESSION
