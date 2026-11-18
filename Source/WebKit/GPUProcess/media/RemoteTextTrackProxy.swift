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
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT

import WebKit_Internal

extension WebKit.RemoteTextTrackProxy {
    // The configuration of the track, which the web process makes its track from.
    private func configuration() -> WebKit.TextTrackPrivateRemoteConfiguration {
        let track = trackPrivate()
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

    @cxx
    @implementation
    func addToWebProcess() {
        guard let connection = webProcessConnection() else {
            return
        }
        Messages.MediaPlayerPrivateRemote.sendAddRemoteTextTrack(connection, m_mediaPlayerIdentifier.toUInt64(), configuration())
    }

    @cxx
    @implementation
    func configurationChanged() {
        guard let connection = webProcessConnection() else {
            return
        }
        let previousIdentifier = m_id
        m_id = id()
        Messages.MediaPlayerPrivateRemote.sendRemoteTextTrackConfigurationChanged(
            connection,
            m_mediaPlayerIdentifier.toUInt64(),
            previousIdentifier,
            configuration()
        )
    }

    @cxx
    @implementation
    func willRemove() {
        assertionFailure()
    }

    @cxx
    @implementation
    func idChanged(_ identifier: WebCore.TrackID) {
        configurationChanged()
    }




    @cxx
    @implementation
    func swiftParseWebVTTFileHeader(_ header: WTF.String) {
        guard let connection = webProcessConnection() else {
            return
        }
        Messages.MediaPlayerPrivateRemote.sendParseWebVTTFileHeader(connection, m_mediaPlayerIdentifier.toUInt64(), id(), header)
    }

    @cxx
    @implementation
    func swiftParseWebVTTCueData(_ cue: WebCore.ISOWebVTTCue) {
        guard let connection = webProcessConnection() else {
            return
        }
        Messages.MediaPlayerPrivateRemote.sendParseWebVTTCueDataStruct(connection, m_mediaPlayerIdentifier.toUInt64(), id(), cue)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_VIDEO && ENABLE_GPU_PROCESS_MEDIA_SWIFT
