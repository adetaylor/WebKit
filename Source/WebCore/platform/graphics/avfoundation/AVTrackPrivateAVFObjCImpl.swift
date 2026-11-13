// Copyright (C) 2013-2025 Apple Inc. All rights reserved.
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

// What the AVFoundation players' track privates read of their tracks: the enabled state, index, identifier, audio and
// video kinds, label and format of an AVPlayerItemTrack, AVAssetTrack or AVMediaSelectionOption, and the enabled state
// they set. AVTrackPrivateAVFObjCImpl.mm keeps the C++ class that the track privates hold, the asynchronous loading of
// the asset track's format, the configurations built from the format description, and the text kinds and languages that
// the text track privates share.
//
// WebCore soft-links AVFoundation and CoreMedia: their symbols come from the generated accessors. No AVFoundation class
// is used where its class object would be needed.
//
// Threads: the track private's. An AVPlayerItemTrack's asset track is reached through a re-declared selector, as the C++
// did: the SDK isolates it to the main actor, but the AVPlayer player runs on WebCore's main thread, which is the web
// thread in WebKitLegacy on iOS.

internal import AVFoundation
internal import CoreMedia
import WebCore_Private.Core.AVTrackPrivateAVFObjCImpl

private func wtfString(_ string: Swift.String) -> WTF.String {
    let units = ContiguousArray(string.utf16)
    return WTF.String(units.span)
}

private func truncatedUInt32(_ value: Double) -> UInt32 {
    guard value.isFinite, value >= 0, value < 4_294_967_296 else {
        return 0
    }
    return UInt32(value)
}

private func truncatedUInt64(_ value: Double) -> UInt64 {
    guard value.isFinite, value >= 0, value < 18_446_744_073_709_551_616 else {
        return 0
    }
    return UInt64(value)
}

// The asset track's synchronous accessors, which AVFoundation deprecates in favour of asynchronous loading. They don't
// block: AVTrackPrivateAVFObjCImpl.mm loads the format keys first, and the others are the track's own.
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously, once loaded")
#endif
private func isLoaded(_ track: AVAssetTrack, _ key: Swift.String) -> Bool {
    // A null error pointer: AVFoundation writes no error.
    unsafe track.statusOfValue(forKey: key, error: nil) == .loaded
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously, once loaded")
#endif
private func hasCharacteristic(_ track: AVAssetTrack, _ characteristic: AVMediaCharacteristic) -> Bool {
    track.hasMediaCharacteristic(characteristic)
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously, once loaded")
#endif
private func naturalSize(_ track: AVAssetTrack) -> CGSize {
    track.naturalSize
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously, once loaded")
#endif
private func nominalFrameRate(_ track: AVAssetTrack) -> Double {
    Double(track.nominalFrameRate)
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously, once loaded")
#endif
private func estimatedDataRate(_ track: AVAssetTrack) -> Double {
    Double(track.estimatedDataRate)
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously, once loaded")
#endif
private func firstFormatDescription(_ track: AVAssetTrack) -> Any? {
    track.formatDescriptions.first
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "the C++ track privates read these synchronously")
#endif
private func stringValue(_ item: AVMetadataItem) -> Swift.String? {
    item.stringValue
}

private func audioKind(_ assetTrack: AVAssetTrack?, _ option: AVMediaSelectionOption?) -> WebCore.AudioTrackPrivate.Kind {
    if let assetTrack {
        // Check if accessibility characteristics are missing from AVAssetTrack but might be preserved in MediaSelectionOption
        let hasDescribes = hasCharacteristic(assetTrack, AVFoundationSoftLink.AVMediaCharacteristicDescribesVideoForAccessibility)
        if !hasDescribes, let option, option.hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicDescribesVideoForAccessibility) {
            return .Description
        }
        if hasCharacteristic(assetTrack, AVFoundationSoftLink.AVMediaCharacteristicIsAuxiliaryContent) {
            return .Alternative
        }
        if hasDescribes {
            return .Description
        }
        if hasCharacteristic(assetTrack, AVFoundationSoftLink.AVMediaCharacteristicIsMainProgramContent) {
            return .Main
        }
        return .None
    }
    guard let option else {
        return .None
    }
    if option.hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicIsAuxiliaryContent) {
        return .Alternative
    }
    if option.hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicDescribesVideoForAccessibility) {
        return .Description
    }
    if option.hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicIsMainProgramContent) {
        return .Main
    }
    return .None
}

private func videoKind(_ hasMediaCharacteristic: (AVMediaCharacteristic) -> Bool) -> WebCore.VideoTrackPrivate.Kind {
    if hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicDescribesVideoForAccessibility) {
        return .Sign
    }
    if hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicTranscribesSpokenDialogForAccessibility) {
        return .Captions
    }
    if hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicIsAuxiliaryContent) {
        return .Alternative
    }
    if hasMediaCharacteristic(AVFoundationSoftLink.AVMediaCharacteristicIsMainProgramContent) {
        return .Main
    }
    return .None
}

private func index(of track: AVAssetTrack) -> Int32 {
    guard let asset = track.asset, let tracks = AVFoundationMember.tracks(of: asset)?.tracks else {
        return 0
    }
    // NSArray's NSNotFound, converted to an int as the C++ did.
    return Int32(truncatingIfNeeded: tracks.index(of: track))
}

private func identifier(of option: AVMediaSelectionOption) -> UInt64 {
    guard option.responds(to: NSSelectorFromString("optionID")), let identifier = option.value(forKey: "optionID") as? NSNumber else {
        return 0
    }
    return identifier.uint64Value
}

// The title in commonMetadata, in one of the user's preferred languages if possible: empty if there is no title, and nil
// if it has no string value.
private func metadataTitle(_ commonMetadata: NSArray?) -> Swift.String? {
    guard let withKey = AVFoundationMember.metadataItemsWithKey(of: AVFoundationClass.AVMetadataItem),
        let forPreferredLanguages = AVFoundationMember.metadataItemsForPreferredLanguages(of: AVFoundationClass.AVMetadataItem)
    else {
        return ""
    }
    // Both arrays come from AVFoundation, which the re-declaration's NSArray parameter erases: commonMetadata, and the
    // titles filtered from it.
    let titles = unsafe withKey.metadataItemsWithKey(
        from: commonMetadata ?? NSArray(),
        withKey: AVFoundationSoftLink.AVMetadataCommonKeyTitle.rawValue as NSString,
        keySpace: AVFoundationSoftLink.AVMetadataKeySpaceCommon.rawValue as NSString
    )
    guard titles.count > 0 else {
        return ""
    }
    let titlesForPreferredLanguages = unsafe forPreferredLanguages.metadataItemsForPreferredLanguages(
        from: titles,
        filteredAndSortedAccordingToPreferredLanguages: NSLocale.preferredLanguages as NSArray
    )
    let first = titlesForPreferredLanguages.count > 0 ? titlesForPreferredLanguages.object(at: 0) : titles.object(at: 0)
    guard let item = AVFoundationClass.cast(first as AnyObject, to: AVFoundationClass.AVMetadataItem) else {
        return nil
    }
    return stringValue(item)
}

extension WebCore.AVTrackPrivateAVFObjCImpl {
    // The asset track whose format the track has: the player item track's, or else the one it was made with, or else
    // the media selection option's.
    private func formatAssetTrack() -> AVAssetTrack? {
        if let playerItemTrack = m_playerItemTrack.get(), let assetTrack = AVFoundationMember.assetTrack(of: playerItemTrack)?.assetTrack {
            return assetTrack
        }
        if let assetTrack = m_assetTrack.get() {
            return assetTrack
        }
        return m_mediaSelectionOption.get()?.assetTrack()
    }

    private func readEnabled() -> Bool {
        if let playerItemTrack = m_playerItemTrack.get() {
            return playerItemTrack.isEnabled
        }
        if let option = m_mediaSelectionOption.get() {
            return option.selected()
        }
        return false
    }

    private func readLabel() -> WTF.String {
        var commonMetadata: NSArray?
        if let assetTrack = m_assetTrack.get() {
            commonMetadata = AVFoundationMember.commonMetadata(of: assetTrack)?.commonMetadata
        }
        if commonMetadata?.count ?? 0 == 0, m_mediaSelectionOption.get() != nil, let option = m_avMediaSelectionOption.get() {
            commonMetadata = AVFoundationMember.commonMetadata(of: option)?.commonMetadata
        }
        guard let title = metadataTitle(commonMetadata) else {
            return WTF.String()
        }
        return wtfString(title)
    }

    private func readFormat(_ properties: inout WebCore.AVTrackSwiftProperties) {
        guard let assetTrack = formatAssetTrack() else {
            return
        }
        let size = naturalSize(assetTrack)
        properties.width = truncatedUInt32(Double(size.width))
        properties.height = truncatedUInt32(Double(size.height))
        if isLoaded(assetTrack, "nominalFrameRate") {
            properties.framerate = nominalFrameRate(assetTrack)
        }
        if isLoaded(assetTrack, "estimatedDataRate") {
            properties.bitrate = truncatedUInt64(estimatedDataRate(assetTrack))
        }
        guard isLoaded(assetTrack, "formatDescriptions"), let first = firstFormatDescription(assetTrack) else {
            return
        }
        let object = first as AnyObject
        guard CFGetTypeID(object) == CMFormatDescriptionGetTypeID() else {
            return
        }
        // Checked by its type identifier above.
        let formatDescription = object as! CMFormatDescription
        // properties() adopts this reference.
        properties.retainedFormatDescription = UInt(bitPattern: unsafe Unmanaged.passRetained(formatDescription).toOpaque())
    }

    @cxx
    @implementation
    func readProperties() -> WebCore.AVTrackSwiftProperties {
        let assetTrack = m_assetTrack.get()
        let selectionOption = m_mediaSelectionOption.get()
        let option = selectionOption != nil ? m_avMediaSelectionOption.get() : nil

        var properties = WebCore.AVTrackSwiftProperties()
        properties.enabled = readEnabled()
        if let assetTrack {
            properties.index = index(of: assetTrack)
            properties.id = UInt64(truncatingIfNeeded: Int64(assetTrack.trackID))
            properties.videoKind = videoKind { hasCharacteristic(assetTrack, $0) }
        } else if let selectionOption {
            properties.index = selectionOption.index()
            if let option {
                properties.id = identifier(of: option)
                properties.videoKind = videoKind { option.hasMediaCharacteristic($0) }
            }
        }
        properties.audioKind = audioKind(assetTrack, option)
        properties.label = readLabel()
        readFormat(&properties)
        return properties
    }

    @cxx
    @implementation
    func setEnabled(_ enabled: Bool) {
        if let playerItemTrack = m_playerItemTrack.get() {
            playerItemTrack.isEnabled = enabled
            return
        }
        m_mediaSelectionOption.get()?.setSelected(enabled)
    }
}
