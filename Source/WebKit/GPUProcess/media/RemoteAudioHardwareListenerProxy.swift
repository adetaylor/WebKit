/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS_MEDIA_SWIFT

import WebKit_Internal

// A web process's listener for the audio hardware's activity and its output device's buffer sizes, which tells the web
// process (RemoteAudioHardwareListener.messages.in) about them on its connection.
@MainActor
final class RemoteAudioHardwareListenerProxy {
    private typealias Messages = WebKit.GPUConnectionToWebProcess.RemoteAudioHardwareListenerMessages
    private typealias Callback = WebCore.AudioHardwareListenerCallbacks.Callback

    private let identifier: UInt64
    private let connection: IPC.Connection
    private var callbacks: WebCore.AudioHardwareListenerCallbacks?

    init(identifier: UInt64, connection: IPC.Connection) {
        self.identifier = identifier
        self.connection = connection
        // The listener calls these on the main thread.
        callbacks = WebCore.AudioHardwareListenerCallbacks.create(
            consuming: Callback { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.didBecomeActive()
                }
            },
            consuming: Callback { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.didBecomeInactive()
                }
            },
            consuming: Callback { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.outputDeviceChanged()
                }
            }
        )
        outputDeviceChanged()
    }

    private func didBecomeActive() {
        Messages.audioHardwareDidBecomeActive(on: connection, to: identifier)
    }

    private func didBecomeInactive() {
        Messages.audioHardwareDidBecomeInactive(on: connection, to: identifier)
    }

    private func outputDeviceChanged() {
        guard let callbacks else {
            return
        }
        Messages.audioOutputDeviceChanged(
            on: connection,
            to: identifier,
            bufferSizeMinimum: callbacks.minimumSupportedBufferSize(),
            bufferSizeMaximum: callbacks.maximumSupportedBufferSize()
        )
    }
}

extension GPUConnectionState {
    func createAudioHardwareListener(_ identifier: UInt64, connection: IPC.Connection) {
        guard audioHardwareListeners[identifier] == nil else {
            assertionFailure("The web process created the listener twice")
            return
        }
        audioHardwareListeners[identifier] = RemoteAudioHardwareListenerProxy(identifier: identifier, connection: connection)
    }

    func releaseAudioHardwareListener(_ identifier: UInt64) {
        let listener = audioHardwareListeners.removeValue(forKey: identifier)
        assert(listener != nil, "The web process released a listener it had not created")
    }
}

#endif // ENABLE_GPU_PROCESS_MEDIA_SWIFT
