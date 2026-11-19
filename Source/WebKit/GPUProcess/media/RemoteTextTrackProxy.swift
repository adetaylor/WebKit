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

// A media player's text track, which the web process makes its track from, and whose changes and cues it hears of
// (MediaPlayerPrivateRemote.messages.in) on the player's connection.
@MainActor
final class RemoteTextTrackProxy: InbandTextTrackPrivateClientDelegate {
    let track: WebCore.InbandTextTrackPrivate
    private let connection: IPC.Connection
    private let mediaPlayerIdentifier: UInt64
    private var identifier: WebCore.TrackID
    // Keeps the proxy the track's client.
    private var adapter: WebCore.SwiftInbandTextTrackPrivateClientAdapter?

    init(track: WebCore.InbandTextTrackPrivate, connection: IPC.Connection, mediaPlayerIdentifier: UInt64) {
        self.track = track
        self.connection = connection
        self.mediaPlayerIdentifier = mediaPlayerIdentifier
        identifier = track.id()
        adapter = makeTrackPrivateClientAdapter(track, delegate: self)
        Messages.MediaPlayerPrivateRemote.sendAddRemoteTextTrack(connection, mediaPlayerIdentifier, configuration())
    }

    var id: WebCore.TrackID {
        track.id()
    }

    func isTrack(_ other: WebCore.InbandTextTrackPrivate) -> Bool {
        trackPrivatesAreEqual(other, track)
    }

    func setMode(_ mode: WebCore.InbandTextTrackPrivateMode) {
        track.setMode(mode)
    }

    private func configuration() -> WebKit.TextTrackPrivateRemoteConfiguration {
        var configuration = WebKit.TextTrackPrivateRemoteConfiguration()
        configuration.trackId = track.id()
        configuration.label = track.label()
        configuration.language = track.language()
        configuration.trackIndex = track.trackIndex()
        configuration.inBandMetadataTrackDispatchType = track.inBandMetadataTrackDispatchType()
        configuration.startTimeVariance = track.startTimeVariance()
        configuration.cueFormat = track.cueFormat()
        configuration.isClosedCaptions = track.isClosedCaptions()
        configuration.isSDH = track.isSDH()
        configuration.containsOnlyForcedSubtitles = track.containsOnlyForcedSubtitles()
        configuration.isMainProgramContent = track.isMainProgramContent()
        configuration.isEasyToRead = track.isEasyToRead()
        configuration.isDefault = track.isDefault()
        configuration.isMachineGenerated = track.isMachineGenerated()
        configuration.kind = track.kind()
        return configuration
    }

    private func configurationChanged() {
        let previousIdentifier = identifier
        identifier = track.id()
        Messages.MediaPlayerPrivateRemote.sendRemoteTextTrackConfigurationChanged(connection, mediaPlayerIdentifier, previousIdentifier, configuration())
    }

    // MARK: InbandTextTrackPrivateClientDelegate

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

    func addDataCue(start: WTF.MediaTime, end: WTF.MediaTime, data: WebCore.SharedBuffer) {
        WebKit.sendAddDataCue(connection, mediaPlayerIdentifier, track.id(), start, end, data)
    }

    #if ENABLE_DATACUE_VALUE
    func addDataCue(start: WTF.MediaTime, end: WTF.MediaTime, cue: WebCore.SerializedPlatformDataCue, type: WTF.String) {
        WebKit.sendDataCue(connection, mediaPlayerIdentifier, track.id(), .Add, start, end, cue, type)
    }

    func updateDataCue(start: WTF.MediaTime, end: WTF.MediaTime, cue: WebCore.SerializedPlatformDataCue) {
        WebKit.sendDataCue(connection, mediaPlayerIdentifier, track.id(), .Update, start, end, cue, WTF.String())
    }

    func removeDataCue(start: WTF.MediaTime, end: WTF.MediaTime, cue: WebCore.SerializedPlatformDataCue) {
        WebKit.sendDataCue(connection, mediaPlayerIdentifier, track.id(), .Remove, start, end, cue, WTF.String())
    }
    #endif

    func addGenericCue(_ cue: WebCore.InbandGenericCue) {
        WebKit.sendGenericCue(connection, mediaPlayerIdentifier, track.id(), .Add, cue)
    }

    func updateGenericCue(_ cue: WebCore.InbandGenericCue) {
        WebKit.sendGenericCue(connection, mediaPlayerIdentifier, track.id(), .Update, cue)
    }

    func removeGenericCue(_ cue: WebCore.InbandGenericCue) {
        WebKit.sendGenericCue(connection, mediaPlayerIdentifier, track.id(), .Remove, cue)
    }

    func parseWebVTTFileHeader(_ header: WTF.String) {
        Messages.MediaPlayerPrivateRemote.sendParseWebVTTFileHeader(connection, mediaPlayerIdentifier, track.id(), header)
    }

    func parseWebVTTCueData(_ data: WebCore.SharedBuffer) {
        WebKit.sendParseWebVTTCueData(connection, mediaPlayerIdentifier, track.id(), data)
    }

    func parseWebVTTCueData(_ cue: WebCore.ISOWebVTTCue) {
        Messages.MediaPlayerPrivateRemote.sendParseWebVTTCueDataStruct(connection, mediaPlayerIdentifier, track.id(), cue)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT
