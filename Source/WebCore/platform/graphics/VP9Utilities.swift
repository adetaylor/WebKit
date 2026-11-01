// Copyright (C) 2020 Apple Inc. All rights reserved.
// Copyright (C) 2020-2021 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

// Swift builds the safe Span overloads of the views' span() with the Cxx module, which Xcode builds only find if this file
// imports it.
private import Cxx
import WebCore_Internal.MediaParsersCxxBridging
import WebCore_Internal.PlatformVideoColorPrimaries
import WebCore_Internal.PlatformVideoMatrixCoefficients
import WebCore_Internal.PlatformVideoTransferCharacteristics
import WebCore_Internal.VPCodecConfigurationRecord
import WebCore_Internal.VideoCodecParameterTypes
import wtf

// The VP8 and VP9 parsing of VP9Utilities.cpp and VP9UtilitiesCocoa.mm: codec strings, vpcC records, frame headers, and
// the fields of their VideoInfos. The C++ shells keep the declarations and build the Strings and VideoInfos. Records
// cross with their codecName untouched: a parsed name comes back as a CodecKind, and a record's name comes in as a view.

// The VPConfiguration* constants of VPCodecConfigurationRecord.h, which don't import, and their validity tables.
private enum VPLevel {
    static let level1: UInt8 = 10

    static func isValid(_ level: UInt8) -> Bool {
        switch level {
        case 10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 52, 60, 61, 62:
            true
        default:
            false
        }
    }
}

private enum VPChromaSubsampling {
    static let subsampling420Colocated: UInt8 = 1
    static let subsampling422: UInt8 = 2
    static let subsampling444: UInt8 = 3

    static func isValid(_ subsampling: UInt8) -> Bool {
        subsampling <= subsampling444
    }
}

private enum VPRange {
    static let videoRange: UInt8 = 0
    static let fullRange: UInt8 = 1

    static func isValid(_ range: UInt8) -> Bool {
        range == videoRange || range == fullRange
    }
}

private enum VPColorPrimaries {
    static let bt709: UInt8 = 1
    static let unspecified: UInt8 = 2
    static let bt601: UInt8 = 6
    static let smpteST240: UInt8 = 7
    static let bt2020: UInt8 = 9

    static func isValid<T: FixedWidthInteger>(_ primaries: T) -> Bool {
        switch primaries {
        case 1, 2, 4...12, 22:
            true
        default:
            false
        }
    }
}

private enum VPTransferCharacteristics {
    static let bt709: UInt8 = 1
    static let unspecified: UInt8 = 2
    static let bt601: UInt8 = 6
    static let smpteST240: UInt8 = 7
    static let iec6196621: UInt8 = 13
    static let bt2020TenBit: UInt8 = 14
    static let bt2020TwelveBit: UInt8 = 15

    static func isValid<T: FixedWidthInteger>(_ transfer: T) -> Bool {
        switch transfer {
        case 1, 2, 4...18:
            true
        default:
            false
        }
    }
}

private enum VPMatrixCoefficients {
    static let identity: UInt8 = 0
    static let bt709: UInt8 = 1
    static let unspecified: UInt8 = 2
    static let bt601: UInt8 = 6
    static let smpteST240: UInt8 = 7
    static let bt2020NonconstantLuminance: UInt8 = 9

    static func isValid(_ matrix: UInt8) -> Bool {
        switch matrix {
        case 0, 1, 2, 4...14:
            true
        default:
            false
        }
    }
}

private func isValidVPProfile(_ profile: UInt8) -> Bool {
    profile <= 3
}

private func isValidVPBitDepth(_ bitDepth: UInt8) -> Bool {
    bitDepth == 8 || bitDepth == 10 || bitDepth == 12
}

// MARK: Codec strings

// parseVPCodecParameters (VP9Utilities.cpp): "vp8" and "vp9", alone or as "vp8.0"/"vp9.0", or
// "vp08|vp09.PP.LL.DD[.CC.cp.tc.mc.FF]" with the WTF parseInteger/split leniencies. Unnamed when it doesn't parse.
private func parseVPCodecParameters<CodeUnit: WTFCodeUnit>(
    _ codec: Span<CodeUnit>,
    into record: inout WebCore.VPCodecFields
) -> WebCore.CodecKind {
    var pieces = codec.split(separator: ".")
    guard let name = pieces.next() else {
        return .Unnamed
    }

    let kind: WebCore.CodecKind
    if name.equals("vp8") {
        kind = .Vp8
    } else if name.equals("vp9") {
        kind = .Vp9
    } else if name.equals("vp08") {
        kind = .Vp08
    } else if name.equals("vp09") {
        kind = .Vp09
    } else {
        return .Unnamed
    }

    // The legacy identifiers have no parameters.
    if kind == .Vp8 || kind == .Vp9 {
        if pieces.isAtEnd || codec.equals("vp8.0") || codec.equals("vp9.0") {
            return kind
        }
        return .Unnamed
    }

    guard let profile = pieces.next()?.parseInteger(UInt8.self), isValidVPProfile(profile) else {
        return .Unnamed
    }
    record.profile = profile

    guard let level = pieces.next()?.parseInteger(UInt8.self), VPLevel.isValid(level) else {
        return .Unnamed
    }
    record.level = level

    guard let bitDepth = pieces.next()?.parseInteger(UInt8.self), isValidVPBitDepth(bitDepth) else {
        return .Unnamed
    }
    record.bitDepth = bitDepth

    // The colour fields are all there or all absent.
    guard let chromaSubsamplingPiece = pieces.next() else {
        return kind
    }
    guard let chromaSubsampling = chromaSubsamplingPiece.parseInteger(UInt8.self), VPChromaSubsampling.isValid(chromaSubsampling) else {
        return .Unnamed
    }
    record.chromaSubsampling = chromaSubsampling

    guard let colorPrimaries = pieces.next()?.parseInteger(UInt8.self), VPColorPrimaries.isValid(colorPrimaries) else {
        return .Unnamed
    }
    record.colorPrimaries = colorPrimaries

    guard let transferCharacteristics = pieces.next()?.parseInteger(UInt8.self), VPTransferCharacteristics.isValid(transferCharacteristics)
    else {
        return .Unnamed
    }
    record.transferCharacteristics = transferCharacteristics

    guard let matrixCoefficients = pieces.next()?.parseInteger(UInt8.self), VPMatrixCoefficients.isValid(matrixCoefficients) else {
        return .Unnamed
    }
    record.matrixCoefficients = matrixCoefficients

    // "If matrixCoefficients is 0 (RGB), then chroma subsampling MUST be 3 (4:4:4)."
    if matrixCoefficients == VPMatrixCoefficients.identity && chromaSubsampling != VPChromaSubsampling.subsampling444 {
        return .Unnamed
    }

    guard let videoFullRangeFlag = pieces.next()?.parseInteger(UInt8.self), VPRange.isValid(videoFullRangeFlag) else {
        return .Unnamed
    }
    record.videoFullRangeFlag = videoFullRangeFlag

    return pieces.isAtEnd ? kind : .Unnamed
}

// parseVPCodecParametersIgnoringColorFields: the mandatory fields and chromaSubsampling, whatever follows them.
private func parseVPCodecParametersIgnoringColorFields<CodeUnit: WTFCodeUnit>(
    _ codec: Span<CodeUnit>,
    into record: inout WebCore.VPCodecFields
) -> WebCore.CodecKind {
    var mandatoryFieldsEnd = 0
    var searchStart = 0
    for _ in 0..<4 {
        guard let separator = codec.find(".", from: searchStart) else {
            return parseVPCodecParameters(codec, into: &record)
        }
        mandatoryFieldsEnd = separator
        searchStart = separator + 1
    }

    let kind = parseVPCodecParameters(codec.left(mandatoryFieldsEnd), into: &record)
    if kind == .Unnamed {
        return .Unnamed
    }

    var chromaSubsamplingField = codec.substring(searchStart)
    if let separator = chromaSubsamplingField.find(".") {
        chromaSubsamplingField = chromaSubsamplingField.left(separator)
    }
    guard let chromaSubsampling = chromaSubsamplingField.parseInteger(UInt8.self), VPChromaSubsampling.isValid(chromaSubsampling) else {
        return .Unnamed
    }
    record.chromaSubsampling = chromaSubsampling
    return kind
}

// createVPCodecParametersString after the codec name: nothing if a field is out of range, then ".PP.LL.DD", then
// ".CC.cp.tc.mc.FF" unless those are all the defaults. Every value is written with at least two digits.
private struct VPCodecParametersString: Latin1StringFormat {
    // "vp08" or "vp09" before the parameters, or nothing.
    let name: Swift.String
    let record: WebCore.VPCodecFields

    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output) {
        output.append(name)

        let profile = record.profile
        let level = record.level
        let bitDepth = record.bitDepth
        let chromaSubsampling = record.chromaSubsampling
        let colorPrimaries = record.colorPrimaries
        let transferCharacteristics = record.transferCharacteristics
        let matrixCoefficients = record.matrixCoefficients
        let videoFullRangeFlag = record.videoFullRangeFlag

        guard isValidVPProfile(profile), VPLevel.isValid(level), isValidVPBitDepth(bitDepth),
            VPChromaSubsampling.isValid(chromaSubsampling), VPColorPrimaries.isValid(colorPrimaries),
            VPTransferCharacteristics.isValid(transferCharacteristics), VPMatrixCoefficients.isValid(matrixCoefficients),
            VPRange.isValid(videoFullRangeFlag)
        else {
            return
        }

        output.append(".0")
        output.appendDecimal(profile)
        output.append(".")
        output.appendDecimal(level)
        output.append(".")
        appendTwoDigits(bitDepth, to: &output)

        if chromaSubsampling == VPChromaSubsampling.subsampling420Colocated && videoFullRangeFlag == VPRange.videoRange
            && colorPrimaries == VPColorPrimaries.bt709 && transferCharacteristics == VPTransferCharacteristics.bt709
            && matrixCoefficients == VPMatrixCoefficients.bt709
        {
            return
        }

        output.append(".0")
        output.appendDecimal(chromaSubsampling)
        output.append(".")
        appendTwoDigits(colorPrimaries, to: &output)
        output.append(".")
        appendTwoDigits(transferCharacteristics, to: &output)
        output.append(".")
        appendTwoDigits(matrixCoefficients, to: &output)
        output.append(".0")
        output.appendDecimal(videoFullRangeFlag)
    }

    @_lifetime(output: copy output) @inline(__always)
    private func appendTwoDigits<Output: Latin1Output & ~Copyable & ~Escapable>(_ value: UInt8, to output: inout Output) {
        if value < 10 {
            output.append(0x30)
        }
        output.appendDecimal(value)
    }
}

// The record of a VP8 ("vp08") or VP9 ("vp09") stream, which Swift named itself.
private func vpCodecParametersString(isVP9: Bool, record: borrowing WebCore.VPCodecFields) -> WebCore.MediaParserShortString {
    makeShortString(VPCodecParametersString(name: isVP9 ? "vp09" : "vp08", record: record))
}

// MARK: vpcC records and VP8/VP9 frames

// createVPCodecConfigurationRecordFromVPCC: a VPCodecConfigurationRecord box payload ("VP Codec ISO Media File Format
// Binding"), version and flags first, with no codec initialization data. The record gets no codec name.
private func parseVPCC(_ vpcc: Span<UInt8>, into record: inout WebCore.VPCodecFields) -> Bool {
    guard vpcc.count >= 12 else {
        return false
    }

    var reader = SpanBitReader(vpcc)
    _ = reader.read(8) // version
    _ = reader.read(24) // flags
    guard let profile = reader.read(8), let level = reader.read(8), let bitDepth = reader.read(4), let chromaSubsampling = reader.read(3),
        let videoFullRangeFlag = reader.readBit(), let colorPrimaries = reader.read(8), let transferCharacteristics = reader.read(8),
        let matrixCoefficients = reader.read(8)
    else {
        return false
    }
    record.profile = UInt8(truncatingIfNeeded: profile)
    record.level = UInt8(truncatingIfNeeded: level)
    record.bitDepth = UInt8(truncatingIfNeeded: bitDepth)
    record.chromaSubsampling = UInt8(truncatingIfNeeded: chromaSubsampling)
    record.videoFullRangeFlag = videoFullRangeFlag ? 1 : 0
    record.colorPrimaries = UInt8(truncatingIfNeeded: colorPrimaries)
    record.transferCharacteristics = UInt8(truncatingIfNeeded: transferCharacteristics)
    record.matrixCoefficients = UInt8(truncatingIfNeeded: matrixCoefficients)

    // codecInitializationDataSize must be 0 for VP8 and VP9.
    return reader.read(16) == 0
}

// vpcCFromVPCodecConfigurationRecord: the 12-byte vpcC payload for a record, version 1.
private func appendVPCC(of record: borrowing WebCore.VPCodecFields, to atom: inout WebCore.MediaParserByteVector) {
    atom.reserveCapacity(atom.size() + 12)
    // Version 1, no flags.
    atom.append(consuming: 1)
    atom.append(consuming: 0)
    atom.append(consuming: 0)
    atom.append(consuming: 0)
    atom.append(consuming: record.profile)
    atom.append(consuming: record.level)
    atom.append(consuming: (record.bitDepth & 0xF) << 4 | (record.chromaSubsampling & 0x7) << 1 | (record.videoFullRangeFlag & 0x1))
    atom.append(consuming: record.colorPrimaries)
    atom.append(consuming: record.transferCharacteristics)
    atom.append(consuming: record.matrixCoefficients)
    // codecIntializationDataSize
    atom.append(consuming: 0)
    atom.append(consuming: 0)
}

// setConfigurationColorSpaceFromVP9ColorSpace: the colour of a VP9 color_space (VP9 Bitstream & Decoding Process
// Specification 0.6, 7.2.2), as ISO 23091-2 code points.
private func setColorFromVP9ColorSpace(_ colorSpace: UInt8, in record: inout WebCore.VPCodecFields) {
    switch colorSpace {
    case 1, 3: // CS_BT_601, CS_SMPTE_170
        record.colorPrimaries = VPColorPrimaries.bt601
        record.transferCharacteristics = VPTransferCharacteristics.bt601
        record.matrixCoefficients = VPMatrixCoefficients.bt601
    case 2: // CS_BT_709
        record.colorPrimaries = VPColorPrimaries.bt709
        record.transferCharacteristics = VPTransferCharacteristics.bt709
        record.matrixCoefficients = VPMatrixCoefficients.bt709
    case 4: // CS_SMPTE_240
        record.colorPrimaries = VPColorPrimaries.smpteST240
        record.transferCharacteristics = VPTransferCharacteristics.smpteST240
        record.matrixCoefficients = VPMatrixCoefficients.smpteST240
    case 5: // CS_BT_2020, assumed non-constant luminance as the VP9 specification suggests.
        record.colorPrimaries = VPColorPrimaries.bt2020
        record.matrixCoefficients = VPMatrixCoefficients.bt2020NonconstantLuminance
        record.transferCharacteristics =
            record.bitDepth <= 10 ? VPTransferCharacteristics.bt2020TenBit : VPTransferCharacteristics.bt2020TwelveBit
    case 7: // CS_RGB
        record.colorPrimaries = VPColorPrimaries.bt709
        record.transferCharacteristics = VPTransferCharacteristics.iec6196621
        record.matrixCoefficients = VPMatrixCoefficients.identity
    default: // CS_UNKNOWN, CS_RESERVED
        record.colorPrimaries = VPColorPrimaries.unspecified
        record.transferCharacteristics = VPTransferCharacteristics.unspecified
        record.matrixCoefficients = VPMatrixCoefficients.unspecified
    }
}

// The chroma subsampling of subsampling_x/subsampling_y (or a WebM Colour's ChromaSubsamplingHorz/Vert), with bitwise
// tests on the raw values. 4:4:0 can't be expressed in vpcC and becomes 4:2:0.
private func vpChromaSubsampling(x: UInt64, y: UInt64) -> UInt8 {
    let notX: UInt64 = x == 0 ? 1 : 0
    let notY: UInt64 = y == 0 ? 1 : 0
    if x & y != 0 {
        return VPChromaSubsampling.subsampling420Colocated
    }
    if x & notY != 0 {
        return VPChromaSubsampling.subsampling422
    }
    if notX & notY != 0 {
        return VPChromaSubsampling.subsampling444
    }
    return VPChromaSubsampling.subsampling420Colocated
}

private func fillVP8Record(colorSpace: Bool, into record: inout WebCore.VPCodecFields) {
    record.profile = 0
    record.level = VPLevel.level1
    record.bitDepth = 8
    record.videoFullRangeFlag = VPRange.videoRange
    record.chromaSubsampling = VPChromaSubsampling.subsampling420Colocated
    record.colorPrimaries = colorSpace ? VPColorPrimaries.unspecified : VPColorPrimaries.bt601
    record.transferCharacteristics = colorSpace ? VPTransferCharacteristics.unspecified : VPTransferCharacteristics.bt601
    record.matrixCoefficients = colorSpace ? VPMatrixCoefficients.unspecified : VPMatrixCoefficients.bt601
}

// vpCodecConfigurationRecordFromVPXByteStream: the record of a VP8 or VP9 key frame's uncompressed header, Vp08 or
// Vp09, or Unnamed. A VP8 frame is taken as a key frame when bit 0 of its first byte is set.
private func vpCodecConfigurationRecord(
    fromVPXByteStream data: Span<UInt8>,
    isVP8: Bool,
    into record: inout WebCore.VPCodecFields
) -> WebCore.CodecKind {
    guard data.count >= 11 else {
        return .Unnamed
    }

    if isVP8 {
        guard data[0] & 1 != 0, (data[0] >> 1) & 0x7 <= 3, data[3] == 0x9d, data[4] == 0x01, data[5] == 0x2a else {
            return .Unnamed
        }
        fillVP8Record(colorSpace: data[10] & 0x80 != 0, into: &record)
        return .Vp08
    }

    // 11 bytes hold every field read below.
    var reader = SpanBitReader(data)
    guard reader.read(2) == 2 else { // frame_marker
        return .Unnamed
    }
    guard let profileLowBit = reader.read(1), let profileHighBit = reader.read(1) else {
        return .Unnamed
    }
    var profile = UInt8(truncatingIfNeeded: profileLowBit | profileHighBit << 1)
    if profile == 3 {
        guard let reservedZero = reader.read(1) else {
            return .Unnamed
        }
        profile += UInt8(truncatingIfNeeded: reservedZero)
    }
    guard reader.read(1) == 0, reader.read(1) == 0 else { // show_existing_frame, frame_type (NON_KEY_FRAME)
        return .Unnamed
    }
    _ = reader.read(1) // show_frame
    _ = reader.read(1) // error_resilient_mode
    guard reader.read(8) == 0x49, reader.read(8) == 0x83, reader.read(8) == 0x42 else { // frame_sync_code
        return .Unnamed
    }

    record.profile = profile
    if profile >= 2 {
        guard let tenOrTwelveBit = reader.read(1) else {
            return .Unnamed
        }
        record.bitDepth = tenOrTwelveBit != 0 ? 12 : 10
    }
    guard let colorSpaceBits = reader.read(3) else {
        return .Unnamed
    }
    let colorSpace = UInt8(truncatingIfNeeded: colorSpaceBits)
    var subsamplingX: UInt64 = 1
    var subsamplingY: UInt64 = 1
    if colorSpace != 7 { // CS_RGB
        guard let colorRange = reader.read(1) else {
            return .Unnamed
        }
        record.videoFullRangeFlag = colorRange != 0 ? VPRange.fullRange : VPRange.videoRange
        if profile == 1 || profile == 3 {
            guard let x = reader.read(1), let y = reader.read(1) else {
                return .Unnamed
            }
            subsamplingX = x
            subsamplingY = y
            _ = reader.read(1) // reserved_zero
        }
    } else {
        record.videoFullRangeFlag = VPRange.fullRange
        if profile == 1 || profile == 3 {
            subsamplingX = 0
            subsamplingY = 0
            _ = reader.read(1) // reserved_zero
        }
    }
    record.chromaSubsampling = vpChromaSubsampling(x: subsamplingX, y: subsamplingY)
    setColorFromVP9ColorSpace(colorSpace, in: &record)

    let width = reader.read(16)
    let height = reader.read(16)
    if let width, let height {
        // frame_width_minus_1 of 65535 wraps to 0.
        record.frameWidth = UInt16(truncatingIfNeeded: width + 1)
        record.frameHeight = UInt16(truncatingIfNeeded: height + 1)
    }
    return .Vp09
}

// parseVP8FrameHeader (VP9UtilitiesCocoa.mm), with its bit layout: the first 3 bytes are read as part of a little-endian
// 32-bit word whose top bit is taken as the key frame flag. Only key frames have the rest.
private func parseVP8FrameHeader(_ data: Span<UInt8>, into header: inout WebCore.VP8FrameHeader) -> Bool {
    guard data.count >= 11 else {
        return false
    }

    let uncompressedChunk = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
    header.keyframe = uncompressedChunk & 0x8000_0000 != 0
    header.version = UInt8(truncatingIfNeeded: (uncompressedChunk >> 28) & 0x7)
    header.showFrame = uncompressedChunk & 0x0800_0000 != 0
    header.partitionSize = (uncompressedChunk >> 8) & 0x7FFFF
    if !header.keyframe {
        return true
    }

    guard data[3] == 0x9d, data[4] == 0x01, data[5] == 0x2a else {
        return false
    }

    let horizontalAndWidthField = UInt16(data[6]) | UInt16(data[7]) << 8
    header.horizontalScale = UInt8(truncatingIfNeeded: horizontalAndWidthField >> 14)
    header.width = horizontalAndWidthField & 0x3FFF
    let verticalAndHeightField = UInt16(data[8]) | UInt16(data[9]) << 8
    header.verticalScale = UInt8(truncatingIfNeeded: verticalAndHeightField >> 14)
    header.height = verticalAndHeightField & 0x3FFF
    header.colorSpace = data[10] & 0x80 != 0
    header.needsClamping = data[10] & 0x40 != 0
    return true
}

// MARK: VideoInfo fields

// libwebm's Primaries, TransferCharacteristics and MatrixCoefficients have the ISO 23091-2 values of the
// VPConfiguration codes, so a known value maps to itself. libwebm keeps any value; an unknown one is Unspecified.
private func vpColorPrimaries(fromWebM primaries: UInt64) -> UInt8 {
    VPColorPrimaries.isValid(primaries) ? UInt8(truncatingIfNeeded: primaries) : VPColorPrimaries.unspecified
}

private func vpTransferCharacteristics(fromWebM transfer: UInt64) -> UInt8 {
    VPTransferCharacteristics.isValid(transfer) ? UInt8(truncatingIfNeeded: transfer) : VPTransferCharacteristics.unspecified
}

private func vpMatrixCoefficients(fromWebM matrix: UInt64) -> UInt8 {
    switch matrix {
    case 0, 1, 2, 4...10:
        UInt8(truncatingIfNeeded: matrix)
    default:
        VPMatrixCoefficients.unspecified
    }
}

// The WebM container's Colour values, which override the ones in the frame.
private func applyWebMColour(_ video: WebCore.WebMVideoFields, to record: inout WebCore.VPCodecFields) {
    guard video.hasColour else {
        return
    }
    if video.hasChromaSubsamplingX && video.hasChromaSubsamplingY {
        record.chromaSubsampling = vpChromaSubsampling(x: video.chromaSubsamplingX, y: video.chromaSubsamplingY)
    }
    // libwebm's Range: 0 kUnspecified, 1 kBroadcast, 2 kFull, 3 kDerived.
    if video.hasRange && video.range != 0 {
        record.videoFullRangeFlag = video.range == 2 ? VPRange.fullRange : VPRange.videoRange
    }
    if video.hasBitsPerChannel {
        record.bitDepth = UInt8(truncatingIfNeeded: video.bitsPerChannel)
    }
    if video.hasTransferCharacteristics {
        record.transferCharacteristics = vpTransferCharacteristics(fromWebM: video.transferCharacteristics)
    }
    if video.hasMatrixCoefficients {
        record.matrixCoefficients = vpMatrixCoefficients(fromWebM: video.matrixCoefficients)
    }
    if video.hasPrimaries {
        record.colorPrimaries = vpColorPrimaries(fromWebM: video.primaries)
    }
}

private func platformColorPrimaries(fromVP primaries: UInt8) -> WebCore.PlatformVideoColorPrimaries {
    switch primaries {
    case 1:
        .Bt709
    case 4:
        .Bt470m
    case 5:
        .Bt470bg
    case 6:
        .Smpte170m
    case 7:
        .Smpte240m
    case 8:
        .Film
    case 9:
        .Bt2020
    case 10:
        .SmpteSt4281
    case 11:
        .SmpteRp431
    case 12:
        .SmpteEg432
    case 22:
        .JedecP22Phosphors
    default:
        .Unspecified
    }
}

private func platformTransferCharacteristics(fromVP transfer: UInt8) -> WebCore.PlatformVideoTransferCharacteristics {
    switch transfer {
    case 1:
        .Bt709
    case 4:
        .Gamma22curve
    case 5:
        .Gamma28curve
    case 6:
        .Smpte170m
    case 7:
        .Smpte240m
    case 8:
        .Linear
    case 9:
        .Log
    case 10:
        .LogSqrt
    case 11:
        .Iec6196624
    case 12:
        .Bt1361ExtendedColourGamut
    case 13:
        .Iec6196621
    case 14:
        .Bt2020_10bit
    case 15:
        .Bt2020_12bit
    case 16:
        .SmpteSt2084
    case 17:
        .SmpteSt4281
    case 18:
        .AribStdB67Hlg
    default:
        .Unspecified
    }
}

private func platformMatrixCoefficients(fromVP matrix: UInt8) -> WebCore.PlatformVideoMatrixCoefficients {
    switch matrix {
    case 0:
        .Rgb
    case 1:
        .Bt709
    case 4:
        .Fcc
    case 5:
        .Bt470bg
    case 6:
        .Smpte170m
    case 7:
        .Smpte240m
    case 8:
        .YCgCo
    case 9:
        .Bt2020NonconstantLuminance
    case 10:
        .Bt2020ConstantLuminance
    default:
        .Unspecified
    }
}

private let fourCCVP08: UInt32 = 0x7670_3038 // 'vp08'
private let fourCCVP09: UInt32 = 0x7670_3039 // 'vp09'
private let fourCCVPCC: UInt32 = 0x7670_6343 // 'vpcC'

// What VP9UtilitiesCocoa.mm's createVideoInfoFromVPCodecConfigurationRecord put in a VideoInfo, but its codec string:
// the colour space of the record's code points, and a vpcC atom.
private func fillVPVideoInfo(
    isVP9: Bool,
    record: borrowing WebCore.VPCodecFields,
    size: (width: Float, height: Float),
    displaySize: (width: Float, height: Float),
    fields: inout WebCore.VideoInfoFields,
    atom: inout WebCore.MediaParserByteVector
) {
    fields.codecName = isVP9 ? fourCCVP09 : fourCCVP08
    fields.atomType = fourCCVPCC
    fields.width = size.width
    fields.height = size.height
    fields.displayWidth = displaySize.width
    fields.displayHeight = displaySize.height
    fields.bitDepth = record.bitDepth
    fields.primaries = platformColorPrimaries(fromVP: record.colorPrimaries)
    fields.transfer = platformTransferCharacteristics(fromVP: record.transferCharacteristics)
    fields.matrix = platformMatrixCoefficients(fromVP: record.matrixCoefficients)
    fields.fullRange = record.videoFullRangeFlag == VPRange.fullRange
    appendVPCC(of: record, to: &atom)
}

private func vpFrameSize(of record: borrowing WebCore.VPCodecFields) -> (width: Float, height: Float) {
    (Float(record.frameWidth), Float(record.frameHeight))
}

// MARK: Entry points for VP9Utilities.cpp

@_expose(Cxx)
func parseVPCodecParametersImpl(_ codec: borrowing WebCore.MediaParserText) -> WebCore.VPCodecFieldsResult {
    var result = WebCore.VPCodecFieldsResult()
    result.codecName =
        codec.is8Bit
        ? parseVPCodecParameters(codec.span8() as Span<UInt8>, into: &result.fields)
        : parseVPCodecParameters(codec.span16() as Span<UInt16>, into: &result.fields)
    result.parsed = result.codecName != .Unnamed
    return result
}

@_expose(Cxx)
func parseVPCodecParametersIgnoringColorFieldsImpl(_ codec: borrowing WebCore.MediaParserText) -> WebCore.VPCodecFieldsResult {
    var result = WebCore.VPCodecFieldsResult()
    result.codecName =
        codec.is8Bit
        ? parseVPCodecParametersIgnoringColorFields(codec.span8() as Span<UInt8>, into: &result.fields)
        : parseVPCodecParametersIgnoringColorFields(codec.span16() as Span<UInt16>, into: &result.fields)
    result.parsed = result.codecName != .Unnamed
    return result
}

// The codec string after the record's codec name, which the caller puts in front.
@_expose(Cxx)
func createVPCodecParametersStringImpl(_ record: WebCore.VPCodecFields) -> WebCore.MediaParserShortString {
    makeShortString(VPCodecParametersString(name: "", record: record))
}

@_expose(Cxx)
func createVPCodecConfigurationRecordFromVPCCImpl(_ vpcc: borrowing WebCore.MediaParserBytes) -> WebCore.VPCodecFieldsResult {
    let bytes: Span<UInt8> = vpcc.span()
    var result = WebCore.VPCodecFieldsResult()
    result.parsed = parseVPCC(bytes, into: &result.fields)
    return result
}

@_expose(Cxx)
func vpCodecConfigurationRecordFromVPXByteStreamImpl(
    _ codec: WebCore.VPXCodec,
    _ data: borrowing WebCore.MediaParserBytes
) -> WebCore.VPCodecFieldsResult {
    let bytes: Span<UInt8> = data.span()
    var result = WebCore.VPCodecFieldsResult()
    result.codecName = vpCodecConfigurationRecord(fromVPXByteStream: bytes, isVP8: codec == .Vp8, into: &result.fields)
    result.parsed = result.codecName != .Unnamed
    return result
}

// MARK: Entry points for VP9UtilitiesCocoa.mm

@_expose(Cxx)
func parseVP8FrameHeaderImpl(_ frame: borrowing WebCore.MediaParserBytes) -> WebCore.VP8FrameHeaderResult {
    let bytes: Span<UInt8> = frame.span()
    var result = WebCore.VP8FrameHeaderResult()
    result.parsed = parseVP8FrameHeader(bytes, into: &result.header)
    return result
}

// createVideoInfoFromVPCodecConfigurationRecord(record, colorSpaceOverride), for a record named "vp09" if isVP9. The
// codec string is the part after the record's name, which the caller puts in front.
@_expose(Cxx)
func createVideoInfoFromVPCodecConfigurationRecordImpl(
    _ isVP9: Bool,
    _ record: WebCore.VPCodecFields,
    _ atom: inout WebCore.MediaParserByteVector
) -> WebCore.VPVideoInfoResult {
    var result = WebCore.VPVideoInfoResult()
    let size = vpFrameSize(of: record)
    fillVPVideoInfo(isVP9: isVP9, record: record, size: size, displaySize: size, fields: &result.fields, atom: &atom)
    result.codecString = makeShortString(VPCodecParametersString(name: "", record: record))
    result.created = true
    return result
}

// createVideoInfoFromVP9Stream: nothing if `data` doesn't start with a VP9 key frame. A non-zero width or height
// replaces the frame's, and a frame with unspecified colour is taken to be BT.709.
@_expose(Cxx)
func createVideoInfoFromVP9StreamImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ width: UInt16,
    _ height: UInt16,
    _ atom: inout WebCore.MediaParserByteVector
) -> WebCore.VPVideoInfoResult {
    let bytes: Span<UInt8> = data.span()
    var result = WebCore.VPVideoInfoResult()
    var record = WebCore.VPCodecFields()
    guard vpCodecConfigurationRecord(fromVPXByteStream: bytes, isVP8: false, into: &record) == .Vp09 else {
        return result
    }

    if width != 0 {
        record.frameWidth = width
    }
    if height != 0 {
        record.frameHeight = height
    }
    if record.colorPrimaries == VPColorPrimaries.unspecified && record.transferCharacteristics == VPTransferCharacteristics.unspecified
        && record.matrixCoefficients == VPMatrixCoefficients.unspecified
    {
        record.colorPrimaries = VPColorPrimaries.bt709
        record.transferCharacteristics = VPTransferCharacteristics.bt709
        record.matrixCoefficients = VPMatrixCoefficients.bt709
    }

    let size = vpFrameSize(of: record)
    fillVPVideoInfo(isVP9: true, record: record, size: size, displaySize: size, fields: &result.fields, atom: &atom)
    result.codecString = vpCodecParametersString(isVP9: true, record: record)
    result.created = true
    return result
}

// createVideoInfoFromVP9HeaderParser: a VP9 key frame's header, with the WebM container's colour and display size over
// it.
@_expose(Cxx)
func createVideoInfoFromVP9HeaderParserImpl(
    _ header: WebCore.VP9HeaderFields,
    _ video: WebCore.WebMVideoFields,
    _ atom: inout WebCore.MediaParserByteVector
) -> WebCore.VPVideoInfoResult {
    var record = WebCore.VPCodecFields()
    record.profile = UInt8(truncatingIfNeeded: header.profile)
    // CoreMedia doesn't care about the VP9 level.
    record.level = VPLevel.level1
    record.bitDepth = UInt8(truncatingIfNeeded: header.bitDepth)
    record.videoFullRangeFlag = header.colorRange != 0 ? VPRange.fullRange : VPRange.videoRange
    // vpChromaSubsampling() takes uint64_t values, as a WebM Colour has them; the header's ints are converted.
    record.chromaSubsampling = vpChromaSubsampling(
        x: UInt64(bitPattern: Int64(header.subsamplingX)),
        y: UInt64(bitPattern: Int64(header.subsamplingY))
    )
    setColorFromVP9ColorSpace(UInt8(truncatingIfNeeded: header.colorSpace), in: &record)
    applyWebMColour(video, to: &record)

    // The header's int display size is converted to uint64_t, the type of the WebM element's.
    let displayWidth = video.hasDisplayWidth ? video.displayWidth : UInt64(bitPattern: Int64(header.displayWidth))
    let displayHeight = video.hasDisplayHeight ? video.displayHeight : UInt64(bitPattern: Int64(header.displayHeight))
    var result = WebCore.VPVideoInfoResult()
    fillVPVideoInfo(
        isVP9: true,
        record: record,
        size: (Float(header.width), Float(header.height)),
        displaySize: (Float(displayWidth), Float(displayHeight)),
        fields: &result.fields,
        atom: &atom
    )
    result.codecString = vpCodecParametersString(isVP9: true, record: record)
    result.created = true
    return result
}

// createVideoInfoFromVP8Header: a VP8 key frame's header, with the WebM container's colour and display size over it.
@_expose(Cxx)
func createVideoInfoFromVP8HeaderImpl(
    _ header: WebCore.VP8FrameHeader,
    _ video: WebCore.WebMVideoFields,
    _ atom: inout WebCore.MediaParserByteVector
) -> WebCore.VPVideoInfoResult {
    var record = WebCore.VPCodecFields()
    fillVP8Record(colorSpace: header.colorSpace, into: &record)
    applyWebMColour(video, to: &record)

    let width = header.width
    let height = header.height
    let displayWidth = video.hasDisplayWidth ? video.displayWidth : UInt64(width)
    let displayHeight = video.hasDisplayHeight ? video.displayHeight : UInt64(height)
    var result = WebCore.VPVideoInfoResult()
    fillVPVideoInfo(
        isVP9: false,
        record: record,
        size: (Float(width), Float(height)),
        displaySize: (Float(displayWidth), Float(displayHeight)),
        fields: &result.fields,
        atom: &atom
    )
    result.codecString = vpCodecParametersString(isVP9: false, record: record)
    result.created = true
    return result
}

#endif // ENABLE_WEBCORE_SWIFT
