// Copyright (C) 2018-2026 Apple Inc. All rights reserved.
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

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCore_Private.Core.VideoCodecParameterTypes
import wtf

// The AVC, HEVC and Dolby Vision codec strings and decoder configuration records, and the parameter sets of an hvcC
// box, for HEVCUtilities.cpp. The codec strings are parsed with WTF's leniencies (WTFCompatParsing.swift).

extension WTFCodeUnit {
    fileprivate static func ascii(_ character: Unicode.Scalar) -> Self {
        Self(truncatingIfNeeded: character.value)
    }
}

// MARK: AVC

// ISO/IEC 14496-15:2014, Annex E.2: "avc1", then profile_idc, the constraint flags and level_idc as one hexadecimal
// number, of which only the low 24 bits count. Anything after it is ignored.
private func parseAVCCodecParameters<CodeUnit: WTFCodeUnit>(_ codec: Span<CodeUnit>) -> WebCore.AVCParameters? {
    var pieces = codec.split(separator: ".")
    guard let name = pieces.next(), name.equals("avc1"), let profileFlagsAndLevel = pieces.next()?.parseInteger(UInt32.self, base: 16)
    else {
        return nil
    }

    var parameters = WebCore.AVCParameters()
    parameters.profileIDC = UInt8(truncatingIfNeeded: profileFlagsAndLevel >> 16)
    parameters.constraintsFlags = UInt8(truncatingIfNeeded: profileFlagsAndLevel >> 8)
    parameters.levelIDC = UInt8(truncatingIfNeeded: profileFlagsAndLevel)
    return parameters
}

@_expose(Cxx)
func parseAVCCodecParametersImpl(_ codec: borrowing WebCore.MediaParserText) -> WebCore.AVCParametersResult {
    let parameters = codec.is8Bit ? parseAVCCodecParameters(codec.span8() as Span<UInt8>) : parseAVCCodecParameters(codec.span16() as Span<UInt16>)
    var result = WebCore.AVCParametersResult()
    if let parameters {
        result.parameters = parameters
        result.parsed = true
    }
    return result
}

@_expose(Cxx)
func createAVCCodecParametersStringImpl(_ parameters: WebCore.AVCParameters) -> WebCore.MediaParserShortString {
    makeShortString(AVCCodecString(parameters: parameters))
}

private struct AVCCodecString: Latin1StringFormat {
    let parameters: WebCore.AVCParameters

    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output) {
        output.append("avc1.")
        output.appendHex(parameters.profileIDC, minimumDigits: 2)
        output.appendHex(parameters.constraintsFlags, minimumDigits: 2)
        output.appendHex(parameters.levelIDC, minimumDigits: 2)
    }
}

// AVCDecoderConfigurationRecord (ISO/IEC 14496-15): at least 24 bytes; AVCProfileIndication, profile_compatibility and
// AVCLevelIndication follow configurationVersion.
@_expose(Cxx)
func parseAVCDecoderConfigurationRecordImpl(_ record: borrowing WebCore.MediaParserBytes) -> WebCore.AVCParametersResult {
    let bytes: Span<UInt8> = record.span()
    var result = WebCore.AVCParametersResult()
    guard bytes.count >= 24 else {
        return result
    }

    result.parameters.profileIDC = bytes[1]
    result.parameters.constraintsFlags = bytes[2]
    result.parameters.levelIDC = bytes[3]
    result.parsed = true
    return result
}

// MARK: HEVC

// ISO/IEC 14496-15:2014, Annex E.3: "hvc1" or "hev1"; an optional general_profile_space letter ('A' to 'C' for 1 to 3)
// and general_profile_idc in decimal; general_profile_compatibility_flags bit-reversed, in hexadecimal; the general
// tier ('L' or 'H') and general_level_idc in decimal; then up to six general_constraint_indicator_flags bytes in
// hexadecimal, trailing zero bytes omitted. Pieces after those six are ignored.
private func parseHEVCCodecParameters<CodeUnit: WTFCodeUnit>(_ codec: Span<CodeUnit>) -> WebCore.HEVCCodecFields? {
    var pieces = codec.split(separator: ".")
    guard let name = pieces.next() else {
        return nil
    }

    var fields = WebCore.HEVCCodecFields()
    if name.equals("hvc1") {
        fields.codec = .Hvc1
    } else if name.equals("hev1") {
        fields.codec = .Hev1
    } else {
        return nil
    }

    guard var profile = pieces.next() else {
        return nil
    }
    let firstCharacter = profile[0]
    if firstCharacter >= .ascii("A") && firstCharacter <= .ascii("C") {
        fields.generalProfileSpace = 1 + UInt16(firstCharacter - .ascii("A"))
        profile = profile.substring(1)
    }
    guard let profileIDC = profile.parseInteger(UInt8.self), let compatibilityFlags = pieces.next()?.parseInteger(UInt32.self, base: 16)
    else {
        return nil
    }
    fields.generalProfileIDC = UInt16(profileIDC)
    fields.generalProfileCompatibilityFlags = reverseBits(compatibilityFlags)

    guard let tierAndLevel = pieces.next() else {
        return nil
    }
    let tier = tierAndLevel[0]
    guard tier == .ascii("L") || tier == .ascii("H"), let levelIDC = tierAndLevel.substring(1).parseInteger(UInt8.self) else {
        return nil
    }
    fields.generalTierFlag = tier == .ascii("L") ? 0 : 1
    fields.generalLevelIDC = UInt16(levelIDC)

    var constraintFlags: UInt64 = 0
    for index in 0..<6 {
        guard let piece = pieces.next() else {
            break
        }
        guard let flags = piece.parseInteger(UInt8.self, base: 16) else {
            return nil
        }
        constraintFlags |= UInt64(flags) << (8 * index)
    }
    fields.generalConstraintIndicatorFlags = (
        UInt8(truncatingIfNeeded: constraintFlags),
        UInt8(truncatingIfNeeded: constraintFlags >> 8),
        UInt8(truncatingIfNeeded: constraintFlags >> 16),
        UInt8(truncatingIfNeeded: constraintFlags >> 24),
        UInt8(truncatingIfNeeded: constraintFlags >> 32),
        UInt8(truncatingIfNeeded: constraintFlags >> 40)
    )
    fields.generalConstraintIndicatorFlagCount = 6
    return fields
}

@_expose(Cxx)
func parseHEVCCodecParametersImpl(_ codec: borrowing WebCore.MediaParserText) -> WebCore.HEVCCodecFieldsResult {
    let fields = codec.is8Bit ? parseHEVCCodecParameters(codec.span8() as Span<UInt8>) : parseHEVCCodecParameters(codec.span16() as Span<UInt16>)
    var result = WebCore.HEVCCodecFieldsResult()
    if let fields {
        result.fields = fields
        result.parsed = true
    }
    return result
}

// The constraint flags come from constraintFlags, not from the fields: there can be any number of them, because
// Internals passes whatever script gives it.
@_expose(Cxx)
func createHEVCCodecParametersStringImpl(
    _ fields: WebCore.HEVCCodecFields,
    _ constraintFlags: borrowing WebCore.MediaParserBytes
) -> WTF.String {
    makeLatin1String(HEVCCodecString(fields: fields, constraintFlags: constraintFlags.span()))
}

// The codec string of fields whose constraint flags are their own six, which fits a MediaParserShortString.
func hevcCodecParametersShortString(_ fields: WebCore.HEVCCodecFields) -> WebCore.MediaParserShortString {
    makeShortString(HEVCFieldsCodecString(fields: fields))
}

private struct HEVCCodecString: Latin1StringFormat, ~Escapable {
    let fields: WebCore.HEVCCodecFields
    let constraintFlags: Span<UInt8>

    @_lifetime(copy constraintFlags)
    init(fields: WebCore.HEVCCodecFields, constraintFlags: Span<UInt8>) {
        self.fields = fields
        self.constraintFlags = constraintFlags
    }

    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output) {
        writeHEVCCodecStringPrefix(fields, to: &output)

        var flagCount = constraintFlags.count
        while flagCount > 0 && constraintFlags[flagCount - 1] == 0 {
            flagCount -= 1
        }
        for index in 0..<flagCount {
            output.append(".")
            output.appendHex(constraintFlags[index], minimumDigits: 2)
        }
    }
}

private struct HEVCFieldsCodecString: Latin1StringFormat {
    let fields: WebCore.HEVCCodecFields

    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output) {
        writeHEVCCodecStringPrefix(fields, to: &output)

        var flagCount = min(Int(fields.generalConstraintIndicatorFlagCount), 6)
        while flagCount > 0 && flag(flagCount - 1) == 0 {
            flagCount -= 1
        }
        for index in 0..<flagCount {
            output.append(".")
            output.appendHex(flag(index), minimumDigits: 2)
        }
    }

    private func flag(_ index: Int) -> UInt8 {
        let flags = fields.generalConstraintIndicatorFlags
        return switch index {
        case 0: flags.0
        case 1: flags.1
        case 2: flags.2
        case 3: flags.3
        case 4: flags.4
        default: flags.5
        }
    }
}

@_lifetime(output: copy output)
private func writeHEVCCodecStringPrefix<Output: Latin1Output & ~Copyable & ~Escapable>(
    _ fields: WebCore.HEVCCodecFields,
    to output: inout Output
) {
    output.append(fields.codec == .Hev1 ? "hev1." : "hvc1.")
    if fields.generalProfileSpace != 0 {
        // 'A' + generalProfileSpace - 1, narrowed to 8 bits.
        output.append(UInt8(truncatingIfNeeded: 0x41 + Int(fields.generalProfileSpace) - 1))
    }
    output.appendDecimal(fields.generalProfileIDC)
    output.append(".")
    output.appendHex(reverseBits(fields.generalProfileCompatibilityFlags))
    output.append(fields.generalTierFlag != 0 ? ".H" : ".L")
    output.appendDecimal(fields.generalLevelIDC)
}

// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15:2014, 8.3.3.1): at least 23 bytes; general_profile_space,
// general_tier_flag and general_profile_idc in byte 1, then general_profile_compatibility_flags (as stored, not
// reversed), the six general_constraint_indicator_flags bytes and general_level_idc.
@_expose(Cxx)
func parseHEVCDecoderConfigurationRecordImpl(_ codecCode: UInt32, _ record: borrowing WebCore.MediaParserBytes) -> WebCore.HEVCCodecFieldsResult {
    let bytes: Span<UInt8> = record.span()
    guard let fields = parseHEVCDecoderConfigurationRecord(codecCode, bytes) else {
        return WebCore.HEVCCodecFieldsResult()
    }
    var result = WebCore.HEVCCodecFieldsResult()
    result.fields = fields
    result.parsed = true
    return result
}

private func parseHEVCDecoderConfigurationRecord(_ codecCode: UInt32, _ bytes: Span<UInt8>) -> WebCore.HEVCCodecFields? {
    guard bytes.count >= 23, let compatibilityFlags = ByteCursor(bytes).uint32(at: 2) else {
        return nil
    }

    var result = WebCore.HEVCCodecFields()
    switch codecCode {
    case 0x6865_7631: // 'hev1'
        result.codec = .Hev1
    case 0x6876_6331: // 'hvc1'
        result.codec = .Hvc1
    default:
        return nil
    }

    let profileSpaceTierIDC = bytes[1]
    result.generalProfileSpace = UInt16(profileSpaceTierIDC >> 6)
    result.generalTierFlag = (profileSpaceTierIDC >> 5) & 1
    result.generalProfileIDC = UInt16(profileSpaceTierIDC & 0b1_1111)
    result.generalProfileCompatibilityFlags = compatibilityFlags
    result.generalConstraintIndicatorFlags = (bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11])
    result.generalConstraintIndicatorFlagCount = 6
    result.generalLevelIDC = UInt16(bytes[12])
    return result
}

// The NAL unit arrays of an HEVCDecoderConfigurationRecord (ISO/IEC 14496-15, 8.3.3.1). Each parameter set NAL unit
// goes into parameterSets as four words: the NAL unit type of its array, its offset in hvcc (low half, then high
// half), and its size. On failure parameterSets may hold the ones found before the error.
@_expose(Cxx)
func parseHVCCParameterSetsImpl(
    _ hvcc: borrowing WebCore.MediaParserBytes,
    _ lengthFieldSize: inout Int,
    _ parameterSets: inout WebCore.MediaParserUInt32Vector
) -> Bool {
    let bytes: Span<UInt8> = hvcc.span()
    guard bytes.count >= 23 else {
        return false
    }

    // The 21 bytes of fields before lengthSizeMinusOne are unused.
    var reader = SpanBitReader(bytes)
    guard reader.skipBytes(21), let lengthSizeMinusOne = reader.read(UInt8.self), let arrayCount = reader.read(UInt8.self) else {
        return false
    }

    for _ in 0..<arrayCount {
        // array_completeness(1), reserved(1), NAL_unit_type(6), then numNalus.
        guard let arrayHeader = reader.read(UInt8.self), let naluCount = reader.read(UInt16.self) else {
            return false
        }
        for _ in 0..<naluCount {
            guard let size = reader.read(UInt16.self), size != 0 else {
                return false
            }
            let offset = UInt64(truncatingIfNeeded: reader.byteOffset)
            guard reader.skipBytes(Int(size)) else {
                return false
            }
            parameterSets.append(consuming: UInt32(arrayHeader & 0x3F))
            parameterSets.append(consuming: UInt32(truncatingIfNeeded: offset))
            parameterSets.append(consuming: UInt32(truncatingIfNeeded: offset >> 32))
            parameterSets.append(consuming: UInt32(size))
        }
    }

    lengthFieldSize = Int(lengthSizeMinusOne & 0x3) + 1
    return true
}

// MARK: Dolby Vision

// The codec names are matched like the keys of a SortedArrayMap of PackedLettersLiteral, by ORing each character with
// 0x20, so "dvh\u{11}" is "dvh1" too.
private func doViCodec<CodeUnit: WTFCodeUnit>(_ name: Span<CodeUnit>) -> WebCore.DoViParameters.Codec? {
    if name.equalLettersIgnoringASCIICase("dva1") {
        return .AVC1
    }
    if name.equalLettersIgnoringASCIICase("dvav") {
        return .AVC3
    }
    if name.equalLettersIgnoringASCIICase("dvh1") {
        return .HVC1
    }
    if name.equalLettersIgnoringASCIICase("dvhe") {
        return .HEV1
    }
    return nil
}

// Table 7 of "Dolby Vision Profiles and Levels Version 1.3.2": the profile names, which include the codec name.
private func alphabeticDoViProfileID<CodeUnit: WTFCodeUnit>(_ profile: Span<CodeUnit>) -> UInt16? {
    if profile.equalLettersIgnoringASCIICase("dvav.se") {
        return 9
    }
    if profile.equalLettersIgnoringASCIICase("dvhe.dtb") {
        return 7
    }
    if profile.equalLettersIgnoringASCIICase("dvhe.dtr") {
        return 4
    }
    if profile.equalLettersIgnoringASCIICase("dvhe.st") {
        return 8
    }
    if profile.equalLettersIgnoringASCIICase("dvhe.stn") {
        return 5
    }
    return nil
}

// Section 4.1 of "Dolby Vision Profiles and Levels Version 1.3.2"; nil for the profiles that aren't supported.
private func maximumDoViLevelID(_ profileID: UInt16) -> UInt16? {
    switch profileID {
    case 4, 7:
        9
    case 5, 8:
        13
    case 9:
        5
    default:
        nil
    }
}

private func isValidDoViProfileID(_ profileID: UInt16, for codec: WebCore.DoViParameters.Codec) -> Bool {
    if profileID == 9 {
        return codec == .AVC1 || codec == .AVC3
    }
    return codec == .HVC1 || codec == .HEV1
}

// "Dolby Vision Profiles and Levels Version 1.3.2": "dva1", "dvav", "dvh1" or "dvhe"; the profile, in decimal with a
// leading zero or as an alphabetic name; then the level in decimal. Anything after it is ignored.
private func parseDoViCodecParameters<CodeUnit: WTFCodeUnit>(_ codec: Span<CodeUnit>) -> WebCore.DoViParameters? {
    var pieces = codec.split(separator: ".")
    guard let name = pieces.next(), let codecType = doViCodec(name), let profile = pieces.next() else {
        return nil
    }

    var parameters = WebCore.DoViParameters()
    parameters.codec = codecType
    if profile[0] == .ascii("0") {
        guard let profileID = profile.parseInteger(UInt8.self) else {
            return nil
        }
        parameters.bitstreamProfileID = UInt16(profileID)
    } else {
        // An alphabetic name is matched against the start of the whole string, as if the codec name and the separator
        // always took five characters.
        guard let profileID = alphabeticDoViProfileID(codec.left(5 + profile.count)) else {
            return nil
        }
        parameters.bitstreamProfileID = profileID
    }

    guard let maximumLevelID = maximumDoViLevelID(parameters.bitstreamProfileID),
        isValidDoViProfileID(parameters.bitstreamProfileID, for: parameters.codec),
        let levelID = pieces.next()?.parseInteger(UInt8.self), UInt16(levelID) <= maximumLevelID
    else {
        return nil
    }
    parameters.bitstreamLevelID = UInt16(levelID)
    return parameters
}

@_expose(Cxx)
func parseDoViCodecParametersImpl(_ codec: borrowing WebCore.MediaParserText) -> WebCore.DoViParametersResult {
    let parameters = codec.is8Bit ? parseDoViCodecParameters(codec.span8() as Span<UInt8>) : parseDoViCodecParameters(codec.span16() as Span<UInt16>)
    var result = WebCore.DoViParametersResult()
    if let parameters {
        result.parameters = parameters
        result.parsed = true
    }
    return result
}

// Always "dvh1", whatever the codec.
@_expose(Cxx)
func createDoViCodecParametersStringImpl(_ parameters: WebCore.DoViParameters) -> WebCore.MediaParserShortString {
    makeShortString(DoViCodecString(parameters: parameters))
}

private struct DoViCodecString: Latin1StringFormat {
    let parameters: WebCore.DoViParameters

    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output) {
        output.append("dvh1.")
        if parameters.bitstreamProfileID < 10 {
            output.append("0")
        }
        output.appendDecimal(parameters.bitstreamProfileID)
        output.append(".")
        if parameters.bitstreamLevelID < 10 {
            output.append("0")
        }
        output.appendDecimal(parameters.bitstreamLevelID)
    }
}

// DOVIDecoderConfigurationRecord ("Dolby Vision Streams Within the ISO Base Media File Format, Version 2.0"): at least
// 24 bytes; dv_profile(7) and dv_level(6) follow dv_version_major and dv_version_minor. The codec stays HVC1.
@_expose(Cxx)
func parseDoViDecoderConfigurationRecordImpl(_ record: borrowing WebCore.MediaParserBytes) -> WebCore.DoViParametersResult {
    let bytes: Span<UInt8> = record.span()
    var result = WebCore.DoViParametersResult()
    guard bytes.count >= 24, let profileLevelAndFlags = ByteCursor(bytes).uint16(at: 2) else {
        return result
    }

    result.parameters.bitstreamProfileID = profileLevelAndFlags >> 9
    result.parameters.bitstreamLevelID = (profileLevelAndFlags >> 3) & 0b11_1111
    result.parsed = true
    return result
}

// MARK: LibWebRTC codec strings

// LibWebRTCCodecsProxy's checks of a decoder's codec string: an H.264 one is High profile and level 5.2 at most, an HEVC
// one is one VideoToolbox decodes, a VP9 one is anything, and an AV1 one has a profile of 0, 1 or 2.
@_expose(Cxx)
func webRTCDecoderCodecStringCheckImpl(
    _ codec: WebCore.WebRTCVideoCodec,
    _ codecString: borrowing WebCore.MediaParserText
) -> WebCore.WebRTCCodecStringCheck {
    switch codec {
    case .H264:
        return webRTCAVCCodecStringCheck(codecString)
    case .H265:
        return webRTCHEVCCodecStringCheck(codecString)
    case .AV1:
        var check = WebCore.WebRTCCodecStringCheck()
        check.valid =
            codecString.is8Bit
            ? isWebRTCAV1CodecString(codecString.span8() as Span<UInt8>) : isWebRTCAV1CodecString(codecString.span16() as Span<UInt16>)
        return check
    default:
        var check = WebCore.WebRTCCodecStringCheck()
        check.valid = true
        return check
    }
}

// LibWebRTCCodecsProxy's checks of an encoder's configuration: H.264 with one spatial layer and one temporal layer, or two
// for low latency; HEVC with one of each; and the codec string, if any, as for a decoder.
@_expose(Cxx)
func webRTCEncoderConfigurationCheckImpl(
    _ codec: WebCore.WebRTCVideoCodec,
    _ codecString: borrowing WebCore.MediaParserText,
    _ hasCodecString: Bool,
    _ useLowLatency: Bool,
    _ scalabilityMode: WebCore.WebRTCScalabilityMode
) -> WebCore.WebRTCCodecStringCheck {
    var check = WebCore.WebRTCCodecStringCheck()
    switch codec {
    case .H264:
        guard scalabilityMode == .L1T1 || (scalabilityMode == .L1T2 && useLowLatency) else {
            return check
        }
        guard hasCodecString else {
            check.valid = true
            return check
        }
        return webRTCAVCCodecStringCheck(codecString)
    case .H265:
        guard scalabilityMode == .L1T1 else {
            return check
        }
        guard hasCodecString else {
            check.valid = true
            return check
        }
        return webRTCHEVCCodecStringCheck(codecString)
    default:
        check.valid = true
        return check
    }
}

private func webRTCAVCCodecStringCheck(_ codecString: borrowing WebCore.MediaParserText) -> WebCore.WebRTCCodecStringCheck {
    let parameters =
        codecString.is8Bit
        ? parseAVCCodecParameters(codecString.span8() as Span<UInt8>) : parseAVCCodecParameters(codecString.span16() as Span<UInt16>)
    var check = WebCore.WebRTCCodecStringCheck()
    if let parameters {
        check.valid = parameters.profileIDC <= 100 && parameters.levelIDC <= 52
    }
    return check
}

private func webRTCHEVCCodecStringCheck(_ codecString: borrowing WebCore.MediaParserText) -> WebCore.WebRTCCodecStringCheck {
    let fields =
        codecString.is8Bit
        ? parseHEVCCodecParameters(codecString.span8() as Span<UInt8>) : parseHEVCCodecParameters(codecString.span16() as Span<UInt16>)
    var check = WebCore.WebRTCCodecStringCheck()
    if let fields {
        check.hevcFields = fields
        check.needsHEVCDecoderCheck = true
    }
    return check
}

private func isWebRTCAV1CodecString<CodeUnit: WTFCodeUnit>(_ codec: Span<CodeUnit>) -> Bool {
    guard codec.startsWith("av01."), codec.count >= 7 else {
        return false
    }
    let profile = codec[5]
    return (profile == .ascii("0") || profile == .ascii("1") || profile == .ascii("2")) && codec[6] == .ascii(".")
}

// MARK: Helpers

private func assign<T>(_ value: T?, to destination: inout T) -> Bool {
    guard let value else {
        return false
    }
    destination = value
    return true
}

private func reverseBits(_ value: UInt32) -> UInt32 {
    var value = value
    value = (value & 0xAAAA_AAAA) >> 1 | (value & 0x5555_5555) << 1
    value = (value & 0xCCCC_CCCC) >> 2 | (value & 0x3333_3333) << 2
    value = (value & 0xF0F0_F0F0) >> 4 | (value & 0x0F0F_0F0F) << 4
    value = (value & 0xFF00_FF00) >> 8 | (value & 0x00FF_00FF) << 8
    return value >> 16 | value << 16
}

#endif // ENABLE_WEBCORE_SWIFT
