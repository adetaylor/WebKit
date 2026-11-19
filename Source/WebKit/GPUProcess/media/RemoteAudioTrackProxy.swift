// Copyright (C) 2020-2025 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE

#if ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT

@_spi(WebKitGPU) internal import WebCore
import WebKit_Internal

// A media player's audio track, which the web process makes its track from, and whose changes it hears of
// (MediaPlayerPrivateRemote.messages.in) on the player's connection.
@MainActor
final class RemoteAudioTrackProxy: AudioTrackPrivateClientDelegate {
    let track: WebCore.AudioTrackPrivate
    private let connection: IPC.Connection
    private let mediaPlayerIdentifier: UInt64
    private var identifier: WebCore.TrackID
    private var enabled = false
    // Keeps the proxy the track's client.
    private var adapter: WebCore.SwiftAudioTrackPrivateClientAdapter?

    init(track: WebCore.AudioTrackPrivate, connection: IPC.Connection, mediaPlayerIdentifier: UInt64) {
        self.track = track
        self.connection = connection
        self.mediaPlayerIdentifier = mediaPlayerIdentifier
        identifier = track.id()
        adapter = makeTrackPrivateClientAdapter(track, delegate: self)
        Messages.MediaPlayerPrivateRemote.sendAddRemoteAudioTrack(connection, mediaPlayerIdentifier, configuration())
    }

    var id: WebCore.TrackID {
        track.id()
    }

    func isTrack(_ other: WebCore.AudioTrackPrivate) -> Bool {
        trackPrivatesAreEqual(other, track)
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        track.setEnabled(enabled)
    }

    private func configuration() -> WebKit.AudioTrackPrivateRemoteConfiguration {
        var configuration = WebKit.AudioTrackPrivateRemoteConfiguration()
        configuration.trackId = track.id()
        configuration.label = track.label()
        configuration.language = track.language()
        configuration.startTimeVariance = track.startTimeVariance()
        configuration.trackIndex = track.trackIndex()
        configuration.enabled = track.enabled()
        configuration.kind = track.kind()
        configuration.trackConfiguration = trackPrivateConfiguration(track)
        return configuration
    }

    private func configurationChanged() {
        let previousIdentifier = identifier
        identifier = track.id()
        Messages.MediaPlayerPrivateRemote.sendRemoteAudioTrackConfigurationChanged(connection, mediaPlayerIdentifier, previousIdentifier, configuration())
    }

    // MARK: AudioTrackPrivateClientDelegate

    func idChanged(_: UInt64) {
        configurationChanged()
    }

    func labelChanged(_: WTF.String) {
        configurationChanged()
    }

    func languageChanged(_: WTF.String) {
        configurationChanged()
    }

    func willRemove() {
        assertionFailure()
    }

    func enabledChanged(_ enabled: Bool) {
        if enabled == self.enabled {
            return
        }
        self.enabled = enabled
        configurationChanged()
    }

    func configurationChanged(_: WebCore.PlatformAudioTrackConfiguration) {
        configurationChanged()
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT
