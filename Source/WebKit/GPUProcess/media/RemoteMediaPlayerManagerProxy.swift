// Copyright (C) 2019 Apple Inc. All rights reserved.
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

#if ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT

import WebKit_Internal

// The media players of the GPU process's RemoteMediaPlayerManagerProxys, one for each web process's connection: by the
// manager's identifier, then by player identifier.
@MainActor
final class RemoteMediaPlayerManagers {
    fileprivate var players: [UInt64: [UInt64: WebKit.RemoteMediaPlayerProxy]] = [:]

    fileprivate nonisolated init() {
    }
}

let remoteMediaPlayerManagers = RemoteMediaPlayerManagers()

extension WebKit.RemoteMediaPlayerManagerProxy {
    @cxx
    @implementation
    func clear() {
        let identifier = identifier()
        MainActor.assumeIsolated {
            let players = remoteMediaPlayerManagers.players.removeValue(forKey: identifier) ?? [:]
            for player in players.values {
                player.invalidate()
            }
        }
    }

    @cxx
    @implementation
    static func swiftDestroy(_ identifier: UInt64) {
        MainActor.assumeIsolated {
            let players = remoteMediaPlayerManagers.players.removeValue(forKey: identifier) ?? [:]
            for player in players.values {
                player.invalidate()
            }
        }
    }

    // These and the C++ callers of these run on the main thread, which the C++ declarations tell Swift.
    @cxx
    @implementation
    @MainActor
    func player(_ identifier: UInt64) -> WebKit.RefPtrRemoteMediaPlayerProxy {
        MainActor.preconditionIsolated()
        return WebKit.RefPtrRemoteMediaPlayerProxy(remoteMediaPlayerManagers.players[self.identifier()]?[identifier])
    }

    @cxx
    @implementation
    @MainActor
    func swiftMediaPlayer(_ identifier: UInt64) -> WebKit.RefPtrMediaPlayer {
        MainActor.preconditionIsolated()
        guard let player = remoteMediaPlayerManagers.players[self.identifier()]?[identifier] else {
            return WebKit.RefPtrMediaPlayer(nil)
        }
        return player.mediaPlayer()
    }

    @cxx
    @implementation
    @MainActor
    func hostedVideoLayerBoundsForTesting(_ clientIdentifier: WebCore.MediaPlayerClientIdentifier) -> WebKit.OptionalFloatRect {
        MainActor.preconditionIsolated()
        for player in (remoteMediaPlayerManagers.players[self.identifier()] ?? [:]).values {
            let bounds = player.hostedVideoLayerBoundsForTesting(clientIdentifier)
            if bounds.value != nil {
                return bounds
            }
        }
        return WebKit.OptionalFloatRect()
    }

    // MARK: Messages

    @MainActor
    func createMediaPlayer(
        connection: IPC.Connection,
        identifier: IPCTypes.MediaPlayerIdentifier,
        clientIdentifier: IPCTypes.MediaPlayerClientIdentifier,
        remoteEngineIdentifier: IPCTypes.MediaPlayerMediaEngineIdentifier,
        proxyConfiguration: CxxDecodedArguments.RemoteMediaPlayerManagerProxy.CreateMediaPlayerProxyConfiguration
    ) throws(InvalidMessage) {
        guard let gpuConnection = swiftGPUConnection() else {
            return
        }
        // Replacing a player would drop it without invalidating it.
        try messageCheck { remoteMediaPlayerManagers.players[self.identifier()]?[identifier.rawValue] == nil }
        let engine = remoteEngineIdentifier.rawValue
        if !Self.hasMediaEngine(engine, true) {
            // Terminate only for a containment bypass: the engine is registered here for capability
            // queries (Supports scope) but not for playback. An entirely-absent engine (e.g. media
            // framework unavailable in recoveryOS) degrades to a null player.
            try messageCheck { !Self.hasMediaEngine(engine, false) }
        }
        let player = createPlayer(gpuConnection, identifier.rawValue, clientIdentifier.rawValue, engine, proxyConfiguration)
        remoteMediaPlayerManagers.players[self.identifier(), default: [:]][identifier.rawValue] = player
    }

    @MainActor
    func deleteMediaPlayer(connection: IPC.Connection, identifier: IPCTypes.MediaPlayerIdentifier) {
        if let player = remoteMediaPlayerManagers.players[self.identifier()]?.removeValue(forKey: identifier.rawValue) {
            player.invalidate()
        }
        guard let gpuConnection = swiftGPUConnection() else {
            return
        }
        if !WebKit.hasOutstandingRenderingResourceUsage() {
            gpuConnection.tryExitIfUnusedAndUnderMemoryPressure()
        }
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT
