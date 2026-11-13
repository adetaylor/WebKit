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

extension WebKit.RemoteAudioSessionProxy {
    @MainActor
    private var state: AudioSessionProxyState? {
        audioSessionArbiter.proxy(identifier())
    }

    @cxx
    @implementation
    func isActive() -> Bool {
        let identifier = identifier()
        return MainActor.assumeIsolated {
            audioSessionArbiter.proxy(identifier)?.isActive ?? false
        }
    }

    @cxx
    @implementation
    func soundStageSize() -> WebCore.AudioSessionSoundStageSize {
        let identifier = identifier()
        return MainActor.assumeIsolated {
            WebCore.AudioSessionSoundStageSize(audioSessionArbiter.proxy(identifier)?.soundStageSize ?? .automatic)
        }
    }

    @cxx
    @implementation
    func didSetActive(_ active: Bool) -> Bool {
        let identifier = identifier()
        return MainActor.assumeIsolated {
            guard let state = audioSessionArbiter.proxy(identifier) else {
                return false
            }
            let changed = state.isActive != active
            state.isActive = active
            if active {
                state.isInterrupted = false
            }
            return changed
        }
    }

    @MainActor
    func setCategory(
        connection: IPC.Connection,
        type: IPCTypes.AudioSessionCategory,
        mode: IPCTypes.AudioSessionMode,
        policy: IPCTypes.RouteSharingPolicy
    ) {
        guard let state else {
            return
        }
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
        guard let state else {
            return
        }
        state.preferredBufferSize = preferredBufferSize
        audioSessionArbiter.updatePreferredBufferSize()
    }

    @MainActor
    func setIsPlayingToBluetoothOverride(connection: IPC.Connection, value: Bool?) {
        state?.isPlayingToBluetoothOverrideChanged = true
        WebKit.RemoteAudioSessionProxyManager.setSessionIsPlayingToBluetoothOverride(value != nil, value ?? false)
    }

    @MainActor
    func setSoundStageSize(connection: IPC.Connection, size: IPCTypes.AudioSessionSoundStageSize) {
        guard let state else {
            return
        }
        state.soundStageSize = size
        audioSessionArbiter.updateSpatialExperience()
    }
}

#endif // ENABLE_GPU_PROCESS && USE_AUDIO_SESSION
