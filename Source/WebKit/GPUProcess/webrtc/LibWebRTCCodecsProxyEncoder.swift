// Copyright (C) 2018-2026 Apple Inc. All rights reserved.
// Copyright (C) 2020-2025 Apple Inc. All rights reserved.
// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
// Copyright (C) 2025-2026 Apple Inc. All rights reserved.
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
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if USE_LIBWEBRTC && WTF_PLATFORM_COCOA && ENABLE_GPU_PROCESS

#if os(macOS)
@_weakLinked import CoreMedia
@_weakLinked import VideoToolbox
#else
import CoreMedia
import VideoToolbox
#endif
import CoreVideo
private import Cxx
import Foundation
import Synchronization
import WebCore_Private
import WebKit_Internal
import os

// MARK: H.264 profile and level

// Ported from webrtc::H264Profile/H264Level (api/video_codecs/h264_profile_level_id.h).
private enum H264Profile {
    case constrainedBaseline
    case baseline
    case main
    case constrainedHigh
    case high
    case predictiveHigh444
}

private enum H264Level: UInt8 {
    case level1_b = 0
    case level1 = 10
    case level1_1 = 11
    case level1_2 = 12
    case level1_3 = 13
    case level2 = 20
    case level2_1 = 21
    case level2_2 = 22
    case level3 = 30
    case level3_1 = 31
    case level3_2 = 32
    case level4 = 40
    case level4_1 = 41
    case level4_2 = 42
    case level5 = 50
    case level5_1 = 51
    case level5_2 = 52
}

// Bit pattern matcher for profile_iop, e.g. "x1xx0000" where 'x' matches either 0 or 1.
// Ported from libwebrtc api/video_codecs/h264_profile_level_id.cc.
private struct BitPattern {
    private let mask: UInt8
    private let maskedValue: UInt8

    init(_ pattern: String) {
        var mask: UInt8 = 0
        var maskedValue: UInt8 = 0
        for character in pattern.utf8 {
            mask <<= 1
            maskedValue <<= 1
            if character != UInt8(ascii: "x") {
                mask |= 1
            }
            if character == UInt8(ascii: "1") {
                maskedValue |= 1
            }
        }
        self.mask = mask
        self.maskedValue = maskedValue
    }

    func isMatch(_ value: UInt8) -> Bool {
        maskedValue == value & mask
    }
}

// This is from https://tools.ietf.org/html/rfc6184#section-8.1.
private let profilePatterns: [(profileIDC: UInt8, profileIOP: BitPattern, profile: H264Profile)] = [
    (0x42, BitPattern("x1xx0000"), .constrainedBaseline),
    (0x4D, BitPattern("1xxx0000"), .constrainedBaseline),
    (0x58, BitPattern("11xx0000"), .constrainedBaseline),
    (0x42, BitPattern("x0xx0000"), .baseline),
    (0x58, BitPattern("10xx0000"), .baseline),
    (0x4D, BitPattern("0x0x0000"), .main),
    (0x64, BitPattern("00000000"), .high),
    (0x64, BitPattern("00001100"), .constrainedHigh),
    (0xF4, BitPattern("00000000"), .predictiveHigh444),
]

// For level_idc=11 and profile_idc=0x42, 0x4D, or 0x58, the constraint set3 flag specifies if level 1b or level 1.1 is used.
private let constraintSet3Flag: UInt8 = 0x10

// The value of six hexadecimal digits.
private func parseProfileLevelIdDigits(_ string: String) -> UInt32? {
    var value: UInt32 = 0
    var count = 0
    for character in string.utf8 {
        let digit: UInt8
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            digit = character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            digit = character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            digit = character - UInt8(ascii: "A") + 10
        default:
            return nil
        }
        count += 1
        if count > 6 {
            return nil
        }
        value = value << 4 | UInt32(digit)
    }
    return count == 6 ? value : nil
}

// Ported from libwebrtc api/video_codecs/h264_profile_level_id.cc.
private func parseH264ProfileLevelId(_ string: String) -> (profile: H264Profile, level: H264Level)? {
    guard let profileLevelIdNumeric = parseProfileLevelIdDigits(string), profileLevelIdNumeric != 0 else {
        return nil
    }

    let levelIDC = UInt8(truncatingIfNeeded: profileLevelIdNumeric)
    let profileIOP = UInt8(truncatingIfNeeded: profileLevelIdNumeric >> 8)
    let profileIDC = UInt8(truncatingIfNeeded: profileLevelIdNumeric >> 16)

    guard let parsedLevel = H264Level(rawValue: levelIDC), parsedLevel != .level1_b else {
        return nil
    }
    let level: H264Level = parsedLevel == .level1_1 && profileIOP & constraintSet3Flag != 0 ? .level1_b : parsedLevel

    for pattern in profilePatterns where profileIDC == pattern.profileIDC && pattern.profileIOP.isMatch(profileIOP) {
        return (pattern.profile, level)
    }
    return nil
}

private func vtProfileLevel(profile: H264Profile, level: H264Level) -> CFString {
    switch profile {
    case .constrainedBaseline, .baseline:
        switch level {
        case .level3:
            kVTProfileLevel_H264_Baseline_3_0
        case .level3_1:
            kVTProfileLevel_H264_Baseline_3_1
        case .level3_2:
            kVTProfileLevel_H264_Baseline_3_2
        case .level4:
            kVTProfileLevel_H264_Baseline_4_0
        case .level4_1:
            kVTProfileLevel_H264_Baseline_4_1
        case .level4_2:
            kVTProfileLevel_H264_Baseline_4_2
        case .level5:
            kVTProfileLevel_H264_Baseline_5_0
        case .level5_1:
            kVTProfileLevel_H264_Baseline_5_1
        case .level5_2:
            kVTProfileLevel_H264_Baseline_5_2
        default:
            kVTProfileLevel_H264_Baseline_AutoLevel
        }
    case .main:
        switch level {
        case .level3:
            kVTProfileLevel_H264_Main_3_0
        case .level3_1:
            kVTProfileLevel_H264_Main_3_1
        case .level3_2:
            kVTProfileLevel_H264_Main_3_2
        case .level4:
            kVTProfileLevel_H264_Main_4_0
        case .level4_1:
            kVTProfileLevel_H264_Main_4_1
        case .level4_2:
            kVTProfileLevel_H264_Main_4_2
        case .level5:
            kVTProfileLevel_H264_Main_5_0
        case .level5_1:
            kVTProfileLevel_H264_Main_5_1
        case .level5_2:
            kVTProfileLevel_H264_Main_5_2
        default:
            kVTProfileLevel_H264_Main_AutoLevel
        }
    case .constrainedHigh, .high:
        // FIXME: Consider setting a more precise profile, at least for webcodecs.
        kVTProfileLevel_H264_High_AutoLevel
    case .predictiveHigh444:
        kVTProfileLevel_H264_High_AutoLevel
    }
}

private func isProfileLevelIdName(_ name: String) -> Bool {
    let expected = "profile-level-id".utf8
    guard name.utf8.count == expected.count else {
        return false
    }
    return zip(name.utf8, expected).allSatisfy { character, expectedCharacter in
        let lowercased = character >= UInt8(ascii: "A") && character <= UInt8(ascii: "Z") ? character + 32 : character
        return lowercased == expectedCharacter
    }
}

private func computeVTProfileLevel(_ parameters: [(String?, String?)]) -> CFString {
    // https://datatracker.ietf.org/doc/html/rfc6184#section-8.1: default to Constrained Baseline Level 3.1 when profile-level-id is absent.
    var profileLevelId: (profile: H264Profile, level: H264Level) = (.constrainedBaseline, .level3_1)
    for (name, value) in parameters {
        guard let name, isProfileLevelIdName(name) else {
            continue
        }
        if let value, let parsed = parseH264ProfileLevelId(value) {
            profileLevelId = parsed
        }
        break
    }
    return vtProfileLevel(profile: profileLevelId.profile, level: profileLevelId.level)
}

// MARK: Bitrate adjustment

// Certain hardware encoders tend to consistently overshoot the bitrate they are configured to encode at.
// This estimates an adjusted bitrate that, when set on the encoder, produces output closer to the desired bitrate.
private struct BitrateAdjuster {
    private static let updateInterval = 1.0
    private static let updateFrameInterval: UInt32 = 30
    private static let toleranceRatio: Float = 0.1
    private static let minAdjustedRatio: Float = 0.5
    private static let maxAdjustedRatio: Float = 0.95

    private var targetBitrateBps: UInt32 = 0
    private(set) var adjustedBitrateBps: UInt32 = 0
    private var lastAdjustedTargetBitrateBps: UInt32 = 0
    private var bytesSinceLastUpdate = 0
    private var framesSinceLastUpdate: UInt32 = 0
    private var lastUpdateTime: Double?

    private static func isWithinTolerance(_ bitrateBps: UInt32, _ targetBitrateBps: UInt32) -> Bool {
        if targetBitrateBps == 0 {
            return false
        }
        let delta = abs(Float(bitrateBps) - Float(targetBitrateBps))
        return delta / Float(targetBitrateBps) < toleranceRatio
    }

    mutating func setTargetBitrateBps(_ bitrateBps: UInt32) {
        if !Self.isWithinTolerance(bitrateBps, targetBitrateBps) || !Self.isWithinTolerance(bitrateBps, lastAdjustedTargetBitrateBps) {
            adjustedBitrateBps = bitrateBps
        }
        targetBitrateBps = bitrateBps
    }

    mutating func update(frameSize: Int) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
        bytesSinceLastUpdate &+= frameSize

        framesSinceLastUpdate &+= 1
        let lastUpdateTime = lastUpdateTime ?? now
        self.lastUpdateTime = lastUpdateTime
        let elapsed = now - lastUpdateTime
        if elapsed < Self.updateInterval || framesSinceLastUpdate < Self.updateFrameInterval {
            return
        }

        let targetBitrateBps = Float(targetBitrateBps)
        let estimatedBitrateBps = elapsed > 0 ? Float(Double(bytesSinceLastUpdate &* 8) / elapsed) : targetBitrateBps
        let error = targetBitrateBps - estimatedBitrateBps

        // Adjust if we've overshot by any amount or if we've undershot too much.
        if estimatedBitrateBps > targetBitrateBps || error > Self.toleranceRatio * targetBitrateBps {
            var adjustedBitrateBps = targetBitrateBps + 0.5 * error
            adjustedBitrateBps = max(adjustedBitrateBps, Self.minAdjustedRatio * targetBitrateBps)
            adjustedBitrateBps = min(adjustedBitrateBps, Self.maxAdjustedRatio * targetBitrateBps)
            self.adjustedBitrateBps = UInt32(adjustedBitrateBps)
        }

        self.lastUpdateTime = now
        framesSinceLastUpdate = 0
        bytesSinceLastUpdate = 0
        lastAdjustedTargetBitrateBps = self.targetBitrateBps
    }
}

// MARK: Encoded frames

// The parameter sets of an encoder's format description: H.264 SPS and PPS, or HEVC VPS, SPS and PPS.
private enum ParameterSetCodec {
    case h264
    case hevc

    // The number of parameter sets and the size of the NAL unit lengths, if the description has them.
    func countAndNALUnitHeaderLength(_ description: CMFormatDescription) -> (count: Int, nalUnitHeaderLength: Int32)? {
        var count = 0
        var nalUnitHeaderLength: Int32 = 0
        // Safety: the out parameters are local variables of the right types.
        let status =
            switch self {
            case .h264:
                unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalUnitHeaderLength)
            case .hevc:
                unsafe CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalUnitHeaderLength)
            }
        return status == noErr ? (count, nalUnitHeaderLength) : nil
    }

    // Appends a copy of a parameter set's bytes. Returns false if there is none at the index.
    func appendParameterSet(_ description: CMFormatDescription, at index: Int, to bytes: inout [UInt8]) -> Bool {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        // Safety: the out parameters are local variables of the right types.
        let status =
            switch self {
            case .h264:
                unsafe CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .hevc:
                unsafe CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
        guard status == noErr, let pointer = unsafe pointer else {
            return false
        }
        // Safety: the description keeps the parameter set's `size` bytes at `pointer` while the caller holds it, and
        // this copies them before returning.
        unsafe bytes.append(contentsOf: UnsafeBufferPointer(start: pointer, count: size))
        return true
    }
}

// The bytes of a sample buffer.
private func sampleBufferBytes(_ sampleBuffer: CMSampleBuffer) -> [UInt8]? {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        return nil
    }
    var bytes: [UInt8] = []
    guard appendBytes(of: blockBuffer, to: &bytes) else {
        return nil
    }
    return bytes
}

private func appendBytes(of blockBuffer: CMBlockBuffer, to bytes: inout [UInt8]) -> Bool {
    let count = CMBlockBufferGetDataLength(blockBuffer)
    guard count > 0 else {
        return true
    }
    let start = bytes.count
    bytes.append(contentsOf: repeatElement(0, count: count))
    let status = bytes.withUnsafeMutableBytes { destination in
        // Safety: the array holds `count` bytes from `start`, which the copy writes.
        unsafe CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: count, destination: destination.baseAddress! + start)
    }
    return status == noErr
}

// Each 32-bit big-endian NAL unit length becomes the start code 00 00 00 01. Returns false when a NAL unit runs past the
// end.
private func replaceLengthPrefixesWithStartCodes(_ bytes: inout [UInt8], from start: Int) -> Bool {
    var offset = start
    while offset < bytes.count {
        let remaining = bytes.count - offset
        guard remaining >= 4 else {
            return false
        }
        let length = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        // On 32-bit, a length that doesn't fit in an Int is rejected too.
        guard let packetSize = Int(exactly: length), packetSize <= remaining - 4 else {
            return false
        }
        offset += 4 + packetSize
    }
    offset = start
    while offset < bytes.count {
        let length = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        bytes[offset] = 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = 0
        bytes[offset + 3] = 1
        offset += 4 + Int(length)
    }
    return true
}

private let annexBHeaderBytes: [UInt8] = [0, 0, 0, 1]

// The Annex B form of an encoded H.264 or HEVC frame, with the parameter sets first if it is a key frame. Empty if it
// can't be converted.
private func annexBBytes(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool, parameterSets: ParameterSetCodec) -> [UInt8] {
    let releaseLog = WebKit.LogChannel.WebRTC().releaseLog
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
        releaseLog.error("convertParameterSetsCMSampleBufferToAnnexB no description")
        return []
    }

    guard let (parameterSetCount, naluHeaderSize) = parameterSets.countAndNALUnitHeaderLength(description) else {
        return []
    }
    guard naluHeaderSize == 4 else {
        releaseLog.error("convertParameterSetsCMSampleBufferToAnnexB unexpected nalu header size")
        return []
    }

    var annexB: [UInt8] = []
    if isKeyframe {
        for index in 0..<parameterSetCount {
            annexB.append(contentsOf: annexBHeaderBytes)
            guard parameterSets.appendParameterSet(description, at: index, to: &annexB) else {
                return []
            }
        }
    }

    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        releaseLog.error("convertParameterSetsCMSampleBufferToAnnexB no block buffer")
        return []
    }
    let start = annexB.count
    guard appendBytes(of: blockBuffer, to: &annexB) else {
        releaseLog.error("convertParameterSetsCMSampleBufferToAnnexB unable to get block buffer data")
        return []
    }
    guard replaceLengthPrefixesWithStartCodes(&annexB, from: start) else {
        releaseLog.error("convertParameterSetsCMSampleBufferToAnnexB missing data")
        return []
    }
    return annexB
}

// The encoded frame's first sample attachment: whether it is a key frame, and whether other frames depend on it.
private func sampleDependencies(_ sampleBuffer: CMSampleBuffer, readsDependedOnByOthers: Bool) -> (isKeyframe: Bool, isBaseLayer: Bool) {
    var isKeyframe = true
    var isBaseLayer = true
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as NSArray?,
        let attachment = attachments.firstObject as? NSDictionary
    {
        if let notSync = attachment[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }
        if readsDependedOnByOthers, let isDependedOnByOthers = attachment[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool {
            isBaseLayer = isDependedOnByOthers
        }
    }
    return (isKeyframe, isBaseLayer)
}

private struct EncoderOutputState {
    var bitrateAdjuster = BitrateAdjuster()
    var needsToSendDescription = true
}

// What an encoder's VideoToolbox session encodes, on the threads it outputs frames on: each frame goes to the web process,
// after the frame's description when the encoder changed, and its result goes to the codecs queue.
//
// @unchecked Sendable: the connection is safe to use on any thread, and the mutex guards the rest that changes.
final class LibWebRTCCodecsEncoderOutput: @unchecked Sendable {
    let identifier: IPCTypes.VideoEncoderIdentifier
    private let connection: IPC.Connection
    private let codecType: IPCTypes.VideoCodecType
    private let useAnnexB: Bool
    private let usesTwoTemporalLayers: Bool
    private let notifyResult: @Sendable (Bool) -> Void
    private let state = Mutex(EncoderOutputState())
    private let isEncoderReleased = Atomic<Bool>(false)

    init(
        identifier: IPCTypes.VideoEncoderIdentifier,
        connection: IPC.Connection,
        codecType: IPCTypes.VideoCodecType,
        useAnnexB: Bool,
        usesTwoTemporalLayers: Bool,
        notifyResult: @escaping @Sendable (Bool) -> Void
    ) {
        self.identifier = identifier
        self.connection = connection
        self.codecType = codecType
        self.useAnnexB = useAnnexB
        self.usesTwoTemporalLayers = usesTwoTemporalLayers
        self.notifyResult = notifyResult
    }

    func encoderWasReleased() {
        isEncoderReleased.store(true, ordering: .relaxed)
    }

    func notifyError() {
        notifyResult(false)
    }

    func setNeedsToSendDescription() {
        state.withLock { $0.needsToSendDescription = true }
    }

    func setTargetBitrateBps(_ bitrateBps: UInt32) -> UInt32 {
        state.withLock { state in
            state.bitrateAdjuster.setTargetBitrateBps(bitrateBps)
            return state.bitrateAdjuster.adjustedBitrateBps
        }
    }

    func sessionDidOutput(_ status: OSStatus, _ infoFlags: VTEncodeInfoFlags, _ sampleBuffer: CMSampleBuffer?, frameInfo: IPCTypes.GPUVideoEncoderFrameInfo, colorSpace: IPCTypes.PlatformVideoColorSpace) {
        guard !isEncoderReleased.load(ordering: .relaxed) else {
            return
        }
        guard status == noErr, let sampleBuffer else {
            notifyResult(false)
            return
        }
        if infoFlags.contains(.frameDropped) {
            notifyResult(true)
            return
        }

        let dependencies = sampleDependencies(sampleBuffer, readsDependedOnByOthers: usesTwoTemporalLayers)
        var frameInfo = frameInfo
        frameInfo.isKeyFrame = dependencies.isKeyframe
        frameInfo.temporalIndex = usesTwoTemporalLayers ? (dependencies.isBaseLayer ? 0 : 1) : nil

        let data: [UInt8]
        if useAnnexB {
            data = annexBBytes(sampleBuffer, isKeyframe: dependencies.isKeyframe, parameterSets: codecType == .h265 ? .hevc : .h264)
            guard !data.isEmpty else {
                notifyResult(false)
                return
            }
        } else {
            guard let bytes = sampleBufferBytes(sampleBuffer) else {
                notifyResult(false)
                return
            }
            data = bytes
        }

        sendDescriptionIfNeeded(sampleBuffer, colorSpace: colorSpace)
        WebKit.LibWebRTCCodecsProxy.LibWebRTCCodecsMessages.completedEncoding(on: connection, to: 0, identifier: identifier, data: data, info: frameInfo)
        notifyResult(true)

        let totalSampleSize = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        state.withLock { $0.bitrateAdjuster.update(frameSize: totalSampleSize) }
    }

    private var descriptionBoxName: CFString {
        codecType == .h265 ? "hvcC" as CFString : "avcC" as CFString
    }

    private func sendDescriptionIfNeeded(_ sampleBuffer: CMSampleBuffer, colorSpace: IPCTypes.PlatformVideoColorSpace) {
        let needsToSendDescription = state.withLock { $0.needsToSendDescription }
        guard needsToSendDescription else {
            return
        }

        if useAnnexB {
            sendDescription([], colorSpace: colorSpace)
            return
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let atoms = CMFormatDescriptionGetExtension(formatDescription, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary,
            let description = atoms[descriptionBoxName] as? Data
        else {
            return
        }
        sendDescription([UInt8](description), colorSpace: colorSpace)
    }

    private func sendDescription(_ description: [UInt8], colorSpace: IPCTypes.PlatformVideoColorSpace) {
        state.withLock { $0.needsToSendDescription = false }
        WebKit.LibWebRTCCodecsProxy.LibWebRTCCodecsMessages.setEncodingConfiguration(on: connection, to: 0, identifier: identifier, description: description, colorSpace: colorSpace)
    }
}

// MARK: Encoder

private func sameColorSpace(_ a: WebKit.LibWebRTCCodecsColorSpace, _ b: WebKit.LibWebRTCCodecsColorSpace) -> Bool {
    a.hasPrimaries == b.hasPrimaries && (!a.hasPrimaries || a.primaries == b.primaries)
        && a.hasTransfer == b.hasTransfer && (!a.hasTransfer || a.transfer == b.transfer)
        && a.hasMatrix == b.hasMatrix && (!a.hasMatrix || a.matrix == b.matrix)
        && a.hasFullRange == b.hasFullRange && (!a.hasFullRange || a.fullRange == b.fullRange)
        && a.hasChromaLocation == b.hasChromaLocation && (!a.hasChromaLocation || a.chromaLocation == b.chromaLocation)
}

// The nanoseconds of a frame's time, as a C++ conversion of the double would give them on arm64.
private func nanoseconds(_ time: IPCTypes.MediaTime) -> Int64 {
    let valid: UInt8 = 1 << 0
    let positiveInfinite: UInt8 = 1 << 2
    let negativeInfinite: UInt8 = 1 << 3
    let indefinite: UInt8 = 1 << 4
    let doubleValue: UInt8 = 1 << 5

    let seconds: Double
    if time.timeFlags & valid == 0 || time.timeFlags & indefinite != 0 {
        seconds = .nan
    } else if time.timeFlags & positiveInfinite != 0 {
        seconds = .infinity
    } else if time.timeFlags & negativeInfinite != 0 {
        seconds = -.infinity
    } else if time.timeFlags & doubleValue != 0 {
        seconds = Double(bitPattern: UInt64(bitPattern: time.timeValue))
    } else {
        seconds = Double(time.timeValue) / Double(time.timeScale)
    }

    let value = seconds * 1_000_000_000
    if value.isNaN {
        return 0
    }
    if value >= Double(Int64.max) {
        return .max
    }
    if value <= Double(Int64.min) {
        return .min
    }
    return Int64(value)
}

// An encoder of LibWebRTCCodecsProxy.swift, over a VideoToolbox compression session, on the codecs queue. It reads the
// frames shared with it, converts 32-bit BGRA ones to full range 4:2:0, and makes a new session when a frame's colour
// space changes.
final class LibWebRTCCodecsEncoder {
    let output: LibWebRTCCodecsEncoderOutput
    let frameSource: SharedVideoFrameSource
    private let codecType: IPCTypes.VideoCodecType
    private let scalabilityMode: IPCTypes.VideoEncoderScalabilityMode
    private let isLowLatencyEnabled: Bool
    private let profileLevel: CFString?
    private var session: VTCompressionSession?
    private var width: UInt16 = 0
    private var height: UInt16 = 0
    private var targetBitrateBps: UInt32 = 0
    private var colorSpace = WebKit.LibWebRTCCodecsColorSpace()
    private var pixelTransferSession: VTPixelTransferSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var pixelBufferPoolSize: (width: Int, height: Int) = (0, 0)

    // Nil if there is no encoder for the codec and the scalability mode.
    init?(
        codecType: IPCTypes.VideoCodecType,
        parameters: [(String?, String?)],
        isLowLatencyEnabled: Bool,
        scalabilityMode: IPCTypes.VideoEncoderScalabilityMode,
        output: LibWebRTCCodecsEncoderOutput,
        frameSource: SharedVideoFrameSource
    ) {
        switch codecType {
        case .h265:
            // We only support L1T1 for H265.
            self.scalabilityMode = .l1T1
            profileLevel = nil
        case .h264:
            guard scalabilityMode != .l1T3 else {
                return nil
            }
            self.scalabilityMode = scalabilityMode
            profileLevel = computeVTProfileLevel(parameters)
        case .vp9, .av1:
            return nil
        }
        self.codecType = codecType
        self.isLowLatencyEnabled = isLowLatencyEnabled
        self.output = output
        self.frameSource = frameSource
    }

    deinit {
        output.encoderWasReleased()
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        if let pixelTransferSession {
            VTPixelTransferSessionInvalidate(pixelTransferSession)
        }
    }

    func initialize(width: UInt16, height: UInt16, startBitrateKbps: UInt32) {
        self.width = width
        self.height = height
        targetBitrateBps = startBitrateKbps &* 1000
        // FIXME: We might want to check that the session creation went fine, or error the encoder otherwise.
        _ = resetCompressionSession()
    }

    func setRates(bitRateKbps: UInt32, frameRate: UInt32) {
        // FIXME: we should set kVTCompressionPropertyKey_ExpectedFrameRate according frameRate, and may have to use frameRate for duration.
        targetBitrateBps = bitRateKbps &* 1000
        setEncoderBitrateBps(targetBitrateBps)
    }

    func flush() {
        if let session {
            _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        }
    }

    // Returns false if the frame can't be read or converted. Otherwise its result goes to the output.
    func encodeFrame(_ frame: consuming IPCTypes.SharedVideoFrame, timeStamp: Int64, duration: UInt64?, isKeyframeRequired: Bool) -> Bool {
        guard var pixelBuffer = frameSource.readBuffer(frame.buffer) else {
            return false
        }

        var frameColorSpace = frame.colorSpace.codecsColorSpace
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            frameColorSpace = IPCTypes.PlatformVideoColorSpace(primaries: .bt709, transfer: .iec6196621, matrix: .bt709, fullRange: true, chromaLocation: nil).codecsColorSpace
            guard let converted = convertToFullRange420(pixelBuffer) else {
                return false
            }
            pixelBuffer = converted
        }

        WebKit.attachCodecsColorSpace(pixelBuffer, frameColorSpace)
        encode(pixelBuffer, timeStampNs: nanoseconds(frame.time), timeStamp: timeStamp, duration: duration, rotation: frame.rotation, isMirrored: frame.mirrored, isKeyframeRequired: isKeyframeRequired)
        return true
    }

    private func convertToFullRange420(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if pixelTransferSession == nil {
            var sessionOut: VTPixelTransferSession?
            guard unsafe VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &sessionOut) == noErr else {
                return nil
            }
            pixelTransferSession = sessionOut
        }
        guard let pixelTransferSession else {
            return nil
        }

        let size = (width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if pixelBufferPool == nil || pixelBufferPoolSize != size {
            pixelBufferPoolSize = size
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            var poolOut: CVPixelBufferPool?
            guard unsafe CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &poolOut) == kCVReturnSuccess else {
                pixelBufferPool = nil
                return nil
            }
            pixelBufferPool = poolOut
        }
        guard let pixelBufferPool else {
            return nil
        }

        var destinationOut: CVPixelBuffer?
        guard unsafe CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &destinationOut) == kCVReturnSuccess, let destination = destinationOut else {
            return nil
        }
        guard VTPixelTransferSessionTransferImage(pixelTransferSession, from: pixelBuffer, to: destination) == noErr else {
            return nil
        }
        return destination
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64, timeStamp: Int64, duration: UInt64?, rotation: IPCTypes.VideoFrameRotation, isMirrored: Bool, isKeyframeRequired: Bool) {
        let colorSpace = WebKit.colorSpaceOfPixelBuffer(pixelBuffer)
        if session == nil || !sameColorSpace(colorSpace, self.colorSpace) {
            self.colorSpace = colorSpace
            guard resetCompressionSession() else {
                output.notifyError()
                return
            }
        }
        guard let session else {
            return
        }

        let frameProperties: CFDictionary? = isKeyframeRequired ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let captureTimeMS = timeStampNs / 1_000_000
        let frameInfo = IPCTypes.GPUVideoEncoderFrameInfo(
            width: UInt32(width),
            height: UInt32(height),
            timeStamp: timeStamp,
            duration: duration,
            captureTimeMS: captureTimeMS,
            isKeyFrame: true,
            rotation: rotation,
            isMirrored: isMirrored,
            isScreenshare: false,
            qp: -1,
            temporalIndex: nil
        )
        let frameColorSpace = IPCTypes.PlatformVideoColorSpace(colorSpace)
        let output = output
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: cvImageBuffer(pixelBuffer),
            presentationTimeStamp: CMTimeMake(value: captureTimeMS, timescale: 1000),
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { encodeStatus, infoFlags, sampleBuffer in
            output.sessionDidOutput(encodeStatus, VTEncodeInfoFlags(rawValue: infoFlags), sampleBuffer, frameInfo: frameInfo, colorSpace: frameColorSpace)
        }
        if status != noErr {
            output.notifyError()
        }
    }

    private var cmCodecType: CMVideoCodecType {
        switch codecType {
        case .h264:
            kCMVideoCodecType_H264
        case .h265:
            kCMVideoCodecType_HEVC
        case .vp9:
            kCMVideoCodecType_VP9
        case .av1:
            kCMVideoCodecType_AV1
        }
    }

    private func resetCompressionSession() -> Bool {
        if let session {
            self.session = nil
            VTCompressionSessionInvalidate(session)
        }

        #if os(macOS) && !targetEnvironment(macCatalyst)
        let encoderSpecification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        #else
        let encoderSpecification = [CFString: Any]() as CFDictionary
        #endif
        var sessionOut: VTCompressionSession?
        let status = unsafe VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: cmCodecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionOut
        )
        guard status == noErr, let session = sessionOut else {
            return false
        }
        self.session = session

        output.setNeedsToSendDescription()
        configure(session)
        return true
    }

    private func configure(_ session: VTCompressionSession) {
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: isLowLatencyEnabled ? kCFBooleanTrue : kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTSessionSetProperties(session, propertyDictionary: WebKit.copyCompressionSessionColorProperties(colorSpace))

        setEncoderBitrateBps(targetBitrateBps)

        // A relatively large value for keyframe emission (7200 frames or 4 minutes).
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Int64(7200)))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: Double(240)))

        if scalabilityMode == .l1T2 {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_BaseLayerFrameRateFraction, value: NSNumber(value: Double(0.5)))
        }

        if let profileLevel {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)
        }

        _ = VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func setEncoderBitrateBps(_ bitrateBps: UInt32) {
        let adjustedBitrateBps = output.setTargetBitrateBps(bitrateBps)
        guard let session else {
            return
        }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: Int32(bitPattern: adjustedBitrateBps)))
    }
}

// Xcode builds import WebKit's CVPixelBuffer as a class of its own, distinct from VideoToolbox's CVImageBuffer.
private func cvImageBuffer<Buffer: AnyObject>(_ buffer: Buffer) -> CVImageBuffer {
    buffer as! CVImageBuffer
}

#endif
