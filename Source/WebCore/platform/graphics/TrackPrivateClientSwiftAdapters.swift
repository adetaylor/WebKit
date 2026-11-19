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

#if ENABLE_VIDEO

import WebCore_Private.Core.AudioTrackPrivate
import WebCore_Private.Core.InbandTextTrackPrivate
import WebCore_Private.Core.VideoTrackPrivate

// What TrackPrivateBaseClient hears, on the main thread.
@_spi(WebKitGPU) @MainActor public protocol TrackPrivateClientDelegate: AnyObject {
    func idChanged(_ identifier: UInt64)
    func labelChanged(_ label: WTF.String)
    func languageChanged(_ language: WTF.String)
    func willRemove()
}

// What AudioTrackPrivateClient hears, on the main thread.
@_spi(WebKitGPU) @MainActor public protocol AudioTrackPrivateClientDelegate: TrackPrivateClientDelegate {
    func enabledChanged(_ enabled: Bool)
    func configurationChanged(_ configuration: WebCore.PlatformAudioTrackConfiguration)
}

// What VideoTrackPrivateClient hears, on the main thread.
@_spi(WebKitGPU) @MainActor public protocol VideoTrackPrivateClientDelegate: TrackPrivateClientDelegate {
    func selectedChanged(_ selected: Bool)
    func configurationChanged(_ configuration: WebCore.PlatformVideoTrackConfiguration)
}

// What InbandTextTrackPrivateClient hears, on the main thread. The data cues' and WebVTT cue data's bytes are copies.
@_spi(WebKitGPU) @MainActor public protocol InbandTextTrackPrivateClientDelegate: TrackPrivateClientDelegate {
    func addDataCue(start: WTF.MediaTime, end: WTF.MediaTime, data: WebCore.SharedBuffer)
    #if ENABLE_DATACUE_VALUE
    func addDataCue(start: WTF.MediaTime, end: WTF.MediaTime, cue: WebCore.SerializedPlatformDataCue, type: WTF.String)
    func updateDataCue(start: WTF.MediaTime, end: WTF.MediaTime, cue: WebCore.SerializedPlatformDataCue)
    func removeDataCue(start: WTF.MediaTime, end: WTF.MediaTime, cue: WebCore.SerializedPlatformDataCue)
    #endif
    func addGenericCue(_ cue: WebCore.InbandGenericCue)
    func updateGenericCue(_ cue: WebCore.InbandGenericCue)
    func removeGenericCue(_ cue: WebCore.InbandGenericCue)
    func parseWebVTTFileHeader(_ header: WTF.String)
    func parseWebVTTCueData(_ data: WebCore.SharedBuffer)
    func parseWebVTTCueData(_ cue: WebCore.ISOWebVTTCue)
}

extension InbandTextTrackPrivateClientDelegate {
    @_spi(WebKitGPU) public func parseWebVTTFileHeader(_ header: WTF.String) {
        assertionFailure()
    }
}

// MARK: Audio

private typealias AudioTrackDelegateBox = SwiftDelegateBox<any AudioTrackPrivateClientDelegate>

// The track's client for the delegate until the adapter is released. The adapter holds the delegate weakly.
@_spi(WebKitGPU) public func makeTrackPrivateClientAdapter(
    _ track: WebCore.AudioTrackPrivate,
    delegate: any AudioTrackPrivateClientDelegate
) -> WebCore.SwiftAudioTrackPrivateClientAdapter {
    // Safety: the box is retained for the adapter, whose destructor releases it.
    unsafe WebCore.SwiftAudioTrackPrivateClientAdapter.create(track, AudioTrackDelegateBox.retained { [weak delegate] in delegate })
}

// What Swift can't read of a track itself: its configuration, which C++ returns by reference, and its equality.
@_spi(WebKitGPU) public func trackPrivateConfiguration(_ track: WebCore.AudioTrackPrivate) -> WebCore.PlatformAudioTrackConfiguration {
    WebCore.SwiftAudioTrackPrivateClientAdapter.configuration(track)
}

@_spi(WebKitGPU) public func trackPrivatesAreEqual(_ a: WebCore.AudioTrackPrivate, _ b: WebCore.AudioTrackPrivate) -> Bool {
    WebCore.SwiftAudioTrackPrivateClientAdapter.equal(a, b)
}

extension WebCore.SwiftAudioTrackPrivateClientAdapter {
    private var delegate: (any AudioTrackPrivateClientDelegate)? {
        // Safety: m_delegateBox is the box that create() was given, which only the destructor releases.
        unsafe AudioTrackDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        // Safety: the destructor passes the box that create() was given, once.
        unsafe AudioTrackDelegateBox.release(box)
    }

    @cxx
    @implementation
    @MainActor
    func idChanged(_ identifier: WebCore.TrackID) {
        delegate?.idChanged(identifier)
    }

    // Unsafe: C++ lends the label for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func labelChanged(_ label: borrowing WTF.String) {
        delegate?.labelChanged(copy label)
    }

    // Unsafe: C++ lends the language for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func languageChanged(_ language: borrowing WTF.String) {
        delegate?.languageChanged(copy language)
    }

    @cxx
    @implementation
    @MainActor
    func willRemove() {
        delegate?.willRemove()
    }

    @cxx
    @implementation
    @MainActor
    func enabledChanged(_ enabled: Bool) {
        delegate?.enabledChanged(enabled)
    }

    // Unsafe: C++ lends the configuration for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func configurationChanged(_ configuration: borrowing WebCore.PlatformAudioTrackConfiguration) {
        delegate?.configurationChanged(copy configuration)
    }
}

// MARK: Video

private typealias VideoTrackDelegateBox = SwiftDelegateBox<any VideoTrackPrivateClientDelegate>

// The track's client for the delegate until the adapter is released. The adapter holds the delegate weakly.
@_spi(WebKitGPU) public func makeTrackPrivateClientAdapter(
    _ track: WebCore.VideoTrackPrivate,
    delegate: any VideoTrackPrivateClientDelegate
) -> WebCore.SwiftVideoTrackPrivateClientAdapter {
    // Safety: the box is retained for the adapter, whose destructor releases it.
    unsafe WebCore.SwiftVideoTrackPrivateClientAdapter.create(track, VideoTrackDelegateBox.retained { [weak delegate] in delegate })
}

@_spi(WebKitGPU) public func trackPrivateConfiguration(_ track: WebCore.VideoTrackPrivate) -> WebCore.PlatformVideoTrackConfiguration {
    WebCore.SwiftVideoTrackPrivateClientAdapter.configuration(track)
}

@_spi(WebKitGPU) public func trackPrivatesAreEqual(_ a: WebCore.VideoTrackPrivate, _ b: WebCore.VideoTrackPrivate) -> Bool {
    WebCore.SwiftVideoTrackPrivateClientAdapter.equal(a, b)
}

extension WebCore.SwiftVideoTrackPrivateClientAdapter {
    private var delegate: (any VideoTrackPrivateClientDelegate)? {
        // Safety: m_delegateBox is the box that create() was given, which only the destructor releases.
        unsafe VideoTrackDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        // Safety: the destructor passes the box that create() was given, once.
        unsafe VideoTrackDelegateBox.release(box)
    }

    @cxx
    @implementation
    @MainActor
    func idChanged(_ identifier: WebCore.TrackID) {
        delegate?.idChanged(identifier)
    }

    // Unsafe: C++ lends the label for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func labelChanged(_ label: borrowing WTF.String) {
        delegate?.labelChanged(copy label)
    }

    // Unsafe: C++ lends the language for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func languageChanged(_ language: borrowing WTF.String) {
        delegate?.languageChanged(copy language)
    }

    @cxx
    @implementation
    @MainActor
    func willRemove() {
        delegate?.willRemove()
    }

    @cxx
    @implementation
    @MainActor
    func selectedChanged(_ selected: Bool) {
        delegate?.selectedChanged(selected)
    }

    // Unsafe: C++ lends the configuration for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func configurationChanged(_ configuration: borrowing WebCore.PlatformVideoTrackConfiguration) {
        delegate?.configurationChanged(copy configuration)
    }
}

// MARK: Text

private typealias TextTrackDelegateBox = SwiftDelegateBox<any InbandTextTrackPrivateClientDelegate>

// The track's client for the delegate until the adapter is released. The adapter holds the delegate weakly.
@_spi(WebKitGPU) public func makeTrackPrivateClientAdapter(
    _ track: WebCore.InbandTextTrackPrivate,
    delegate: any InbandTextTrackPrivateClientDelegate
) -> WebCore.SwiftInbandTextTrackPrivateClientAdapter {
    // Safety: the box is retained for the adapter, whose destructor releases it.
    unsafe WebCore.SwiftInbandTextTrackPrivateClientAdapter.create(track, TextTrackDelegateBox.retained { [weak delegate] in delegate })
}

@_spi(WebKitGPU) public func trackPrivatesAreEqual(_ a: WebCore.InbandTextTrackPrivate, _ b: WebCore.InbandTextTrackPrivate) -> Bool {
    WebCore.SwiftInbandTextTrackPrivateClientAdapter.equal(a, b)
}

extension WebCore.SwiftInbandTextTrackPrivateClientAdapter {
    private var delegate: (any InbandTextTrackPrivateClientDelegate)? {
        // Safety: m_delegateBox is the box that create() was given, which only the destructor releases.
        unsafe TextTrackDelegateBox.loadDelegate(m_delegateBox)
    }

    @cxx
    @implementation
    static func releaseDelegateBox(_ box: UInt) {
        // Safety: the destructor passes the box that create() was given, once.
        unsafe TextTrackDelegateBox.release(box)
    }

    @cxx
    @implementation
    @MainActor
    func idChanged(_ identifier: WebCore.TrackID) {
        delegate?.idChanged(identifier)
    }

    // Unsafe: C++ lends the label for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func labelChanged(_ label: borrowing WTF.String) {
        delegate?.labelChanged(copy label)
    }

    // Unsafe: C++ lends the language for the call.
    @cxx
    @implementation
    @MainActor
    @unsafe
    func languageChanged(_ language: borrowing WTF.String) {
        delegate?.languageChanged(copy language)
    }

    @cxx
    @implementation
    @MainActor
    func willRemove() {
        delegate?.willRemove()
    }

    @cxx
    @implementation
    @MainActor
    func addGenericCue(_ cue: WebCore.InbandGenericCue) {
        delegate?.addGenericCue(cue)
    }

    @cxx
    @implementation
    @MainActor
    func updateGenericCue(_ cue: WebCore.InbandGenericCue) {
        delegate?.updateGenericCue(cue)
    }

    @cxx
    @implementation
    @MainActor
    func removeGenericCue(_ cue: WebCore.InbandGenericCue) {
        delegate?.removeGenericCue(cue)
    }

    @cxx
    @implementation
    @MainActor
    func swiftAddDataCue(_ start: WTF.MediaTime, _ end: WTF.MediaTime, _ data: WebCore.SharedBuffer) {
        delegate?.addDataCue(start: start, end: end, data: data)
    }

    #if ENABLE_DATACUE_VALUE
    @cxx
    @implementation
    @MainActor
    func swiftAddDataCueWithType(_ start: WTF.MediaTime, _ end: WTF.MediaTime, _ cue: WebCore.SerializedPlatformDataCue, _ type: WTF.String) {
        delegate?.addDataCue(start: start, end: end, cue: cue, type: type)
    }

    @cxx
    @implementation
    @MainActor
    func swiftUpdateDataCue(_ start: WTF.MediaTime, _ end: WTF.MediaTime, _ cue: WebCore.SerializedPlatformDataCue) {
        delegate?.updateDataCue(start: start, end: end, cue: cue)
    }

    @cxx
    @implementation
    @MainActor
    func swiftRemoveDataCue(_ start: WTF.MediaTime, _ end: WTF.MediaTime, _ cue: WebCore.SerializedPlatformDataCue) {
        delegate?.removeDataCue(start: start, end: end, cue: cue)
    }
    #endif

    @cxx
    @implementation
    @MainActor
    func swiftParseWebVTTFileHeader(_ header: WTF.String) {
        delegate?.parseWebVTTFileHeader(header)
    }

    @cxx
    @implementation
    @MainActor
    func swiftParseWebVTTCueData(_ data: WebCore.SharedBuffer) {
        delegate?.parseWebVTTCueData(data)
    }

    @cxx
    @implementation
    @MainActor
    func swiftParseWebVTTCue(_ cue: WebCore.ISOWebVTTCue) {
        delegate?.parseWebVTTCueData(cue)
    }
}

#endif // ENABLE_VIDEO
