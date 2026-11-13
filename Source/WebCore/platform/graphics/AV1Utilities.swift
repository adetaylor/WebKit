// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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
import WebCore_Private.Core.AV1CodecConfigurationRecord
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCore_Private.Core.PlatformVideoColorPrimaries
import WebCore_Private.Core.PlatformVideoMatrixCoefficients
import WebCore_Private.Core.PlatformVideoTransferCharacteristics
import WebCore_Private.Core.VideoCodecParameterTypes
import wtf

// AV1CodecConfigurationRecord's static constexpr defaults, which don't import.
private let defaultMonochrome: UInt8 = 0
private let defaultChromaSubsampling = WebCore.AV1ConfigurationChromaSubsampling.Subsampling_420_Unknown.rawValue
private let defaultColorPrimaries = WebCore.AV1ConfigurationColorPrimaries.BT_709_6.rawValue
private let defaultTransferCharacteristics = WebCore.AV1ConfigurationTransferCharacteristics.BT_709_6.rawValue
private let defaultMatrixCoefficients = WebCore.AV1ConfigurationMatrixCoefficients.BT_709_6.rawValue
private let defaultVideoFullRangeFlag = WebCore.AV1ConfigurationRange.VideoRange

// The values each enumeration defines; the imported enumerations accept any raw value.

private func isValidAV1Profile(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationProfile(rawValue: value) {
    case .Main, .High, .Professional:
        true
    default:
        false
    }
}

private func isValidAV1Level(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationLevel(rawValue: value) {
    case .Level_2_0, .Level_2_1, .Level_2_2, .Level_2_3, .Level_3_0, .Level_3_1, .Level_3_2, .Level_3_3, .Level_4_0,
        .Level_4_1, .Level_4_2, .Level_4_3, .Level_5_0, .Level_5_1, .Level_5_2, .Level_5_3, .Level_6_0, .Level_6_1,
        .Level_6_2, .Level_6_3, .Level_7_0, .Level_7_1, .Level_7_2, .Level_7_3, .Level_Maximum:
        true
    default:
        false
    }
}

private func isValidAV1ChromaSubsampling(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationChromaSubsampling(rawValue: value) {
    case .Subsampling_444, .Subsampling_422, .Subsampling_420_Unknown, .Subsampling_420_Vertical,
        .Subsampling_420_Colocated:
        true
    default:
        false
    }
}

private func isValidAV1Range(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationRange(rawValue: value) {
    case .VideoRange, .FullRange:
        true
    default:
        false
    }
}

private func isValidAV1ColorPrimaries(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationColorPrimaries(rawValue: value) {
    case .BT_709_6, .Unspecified, .BT_470_6_M, .BT_470_7_BG, .BT_601_7, .SMPTE_ST_240, .Film,
        .BT_2020_Nonconstant_Luminance, .SMPTE_ST_428_1, .SMPTE_RP_431_2, .SMPTE_EG_432_1, .EBU_Tech_3213_E:
        true
    default:
        false
    }
}

private func isValidAV1TransferCharacteristics(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationTransferCharacteristics(rawValue: value) {
    case .BT_709_6, .Unspecified, .BT_470_6_M, .BT_470_7_BG, .BT_601_7, .SMPTE_ST_240, .Linear, .Logrithmic,
        .Logrithmic_Sqrt, .IEC_61966_2_4, .BT_1361_0, .IEC_61966_2_1, .BT_2020_10bit, .BT_2020_12bit, .SMPTE_ST_2084,
        .SMPTE_ST_428_1, .BT_2100_HLG:
        true
    default:
        false
    }
}

private func isValidAV1MatrixCoefficients(_ value: UInt8) -> Bool {
    switch WebCore.AV1ConfigurationMatrixCoefficients(rawValue: value) {
    case .Identity, .BT_709_6, .Unspecified, .FCC, .BT_470_7_BG, .BT_601_7, .SMPTE_ST_240, .YCgCo,
        .BT_2020_Nonconstant_Luminance, .BT_2020_Constant_Luminance, .SMPTE_ST_2085, .Chromacity_Nonconstant_Luminance,
        .Chromacity_Constant_Luminance, .BT_2100_ICC:
        true
    default:
        false
    }
}

// MARK: Codec strings

extension Span where Element: WTFCodeUnit {
    // parseInteger<uint8_t>() of the whole string, if isValid accepts the value.
    fileprivate func parseAV1Value(_ isValid: (UInt8) -> Bool) -> UInt8? {
        guard let value = parseInteger(UInt8.self), isValid(value) else {
            return nil
        }
        return value
    }
}

// Ref: https://aomediacodec.github.io/av1-isobmff/#codecsparam
// <sample entry 4CC>.<profile>.<level><tier>.<bitDepth>.<monochrome>.<chromaSubsampling>.
// <colorPrimaries>.<transferCharacteristics>.<matrixCoefficients>.<videoFullRangeFlag>
private func parseAV1CodecParameters<CodeUnit: WTFCodeUnit>(
    _ codec: Span<CodeUnit>,
    into record: inout WebCore.AV1CodecFields
) -> Bool {
    var elements = codec.split(separator: ".")
    guard let codecName = elements.next(), codecName.equals("av01") else {
        return false
    }

    guard let profileElement = elements.next(), let profile = profileElement.parseAV1Value(isValidAV1Profile),
        let profileValue = WebCore.AV1ConfigurationProfile(rawValue: profile)
    else {
        return false
    }
    record.profile = profileValue

    guard let levelTier = elements.next(), levelTier.count >= 3,
        let level = levelTier.substring(0, levelTier.count - 1).parseAV1Value(isValidAV1Level),
        let levelValue = WebCore.AV1ConfigurationLevel(rawValue: level)
    else {
        return false
    }
    record.level = levelValue

    switch levelTier[levelTier.count - 1] {
    case 0x4D: // 'M'
        record.tier = .Main
    case 0x48: // 'H'
        record.tier = .High
    default:
        return false
    }

    guard let bitDepthElement = elements.next(), let bitDepth = bitDepthElement.parseInteger(UInt8.self), bitDepth <= 12
    else {
        return false
    }
    record.bitDepth = bitDepth

    // The other fields are optional. Without any of them the defaults apply. A string that stops after monochrome,
    // chromaSubsampling, colorPrimaries or transferCharacteristics keeps the defaults of the fields after it, but one
    // that stops after matrixCoefficients is invalid.
    guard let monochromeElement = elements.next() else {
        record.monochrome = defaultMonochrome
        record.chromaSubsampling = defaultChromaSubsampling
        record.colorPrimaries = defaultColorPrimaries
        record.transferCharacteristics = defaultTransferCharacteristics
        record.matrixCoefficients = defaultMatrixCoefficients
        record.videoFullRangeFlag = defaultVideoFullRangeFlag
        return true
    }
    guard let monochrome = monochromeElement.parseInteger(UInt8.self), monochrome <= 1 else {
        return false
    }
    record.monochrome = monochrome

    guard let chromaSubsamplingElement = elements.next() else {
        return true
    }
    guard let chromaSubsampling = chromaSubsamplingElement.parseAV1Value(isValidAV1ChromaSubsampling) else {
        return false
    }
    record.chromaSubsampling = chromaSubsampling

    guard let colorPrimariesElement = elements.next() else {
        return true
    }
    guard let colorPrimaries = colorPrimariesElement.parseAV1Value(isValidAV1ColorPrimaries) else {
        return false
    }
    record.colorPrimaries = colorPrimaries

    guard let transferCharacteristicsElement = elements.next() else {
        return true
    }
    guard let transferCharacteristics = transferCharacteristicsElement.parseAV1Value(isValidAV1TransferCharacteristics)
    else {
        return false
    }
    record.transferCharacteristics = transferCharacteristics

    guard let matrixCoefficientsElement = elements.next() else {
        return true
    }
    guard let matrixCoefficients = matrixCoefficientsElement.parseAV1Value(isValidAV1MatrixCoefficients) else {
        return false
    }
    record.matrixCoefficients = matrixCoefficients

    guard let videoFullRangeFlagElement = elements.next(),
        let videoFullRangeFlag = videoFullRangeFlagElement.parseAV1Value(isValidAV1Range),
        let videoFullRangeFlagValue = WebCore.AV1ConfigurationRange(rawValue: videoFullRangeFlag)
    else {
        return false
    }
    record.videoFullRangeFlag = videoFullRangeFlagValue

    return elements.isAtEnd
}

// The short form when every optional field has its default value. Out-of-range values keep their last digits.
private struct AV1CodecString: Latin1StringFormat {
    let profile: UInt8
    let level: UInt8
    let isMainTier: Bool
    let bitDepth: UInt8
    let monochrome: UInt8
    let chromaSubsampling: UInt8
    let colorPrimaries: UInt8
    let transferCharacteristics: UInt8
    let matrixCoefficients: UInt8
    let videoFullRangeFlag: WebCore.AV1ConfigurationRange

    init(_ record: borrowing WebCore.AV1CodecFields) {
        profile = record.profile.rawValue
        level = record.level.rawValue
        isMainTier = record.tier == .Main
        bitDepth = record.bitDepth
        monochrome = record.monochrome
        chromaSubsampling = record.chromaSubsampling
        colorPrimaries = record.colorPrimaries
        transferCharacteristics = record.transferCharacteristics
        matrixCoefficients = record.matrixCoefficients
        videoFullRangeFlag = record.videoFullRangeFlag
    }

    @_lifetime(output: copy output)
    func write<Output: Latin1Output & ~Copyable & ~Escapable>(to output: inout Output) {
        output.append("av01.")
        appendDigit(profile, to: &output)
        output.append(0x2E)
        appendTwoDigits(level, to: &output)
        output.append(isMainTier ? 0x4D : 0x48) // 'M' or 'H'
        output.append(0x2E)
        appendTwoDigits(bitDepth, to: &output)

        let hasDefaultOptionalFields =
            monochrome == defaultMonochrome && chromaSubsampling == defaultChromaSubsampling
            && colorPrimaries == defaultColorPrimaries && transferCharacteristics == defaultTransferCharacteristics
            && matrixCoefficients == defaultMatrixCoefficients && videoFullRangeFlag == defaultVideoFullRangeFlag
        if hasDefaultOptionalFields {
            return
        }
        output.append(0x2E)
        appendDigit(monochrome, to: &output)
        output.append(0x2E)
        appendDigit(chromaSubsampling / 100, to: &output)
        appendTwoDigits(chromaSubsampling, to: &output)
        output.append(0x2E)
        appendTwoDigits(colorPrimaries, to: &output)
        output.append(0x2E)
        appendTwoDigits(transferCharacteristics, to: &output)
        output.append(0x2E)
        appendTwoDigits(matrixCoefficients, to: &output)
        output.append(0x2E)
        appendDigit(videoFullRangeFlag.rawValue, to: &output)
    }

    @_lifetime(output: copy output) @inline(__always)
    private func appendDigit<Output: Latin1Output & ~Copyable & ~Escapable>(_ value: UInt8, to output: inout Output) {
        output.append(0x30 + value % 10)
    }

    @_lifetime(output: copy output) @inline(__always)
    private func appendTwoDigits<Output: Latin1Output & ~Copyable & ~Escapable>(_ value: UInt8, to output: inout Output) {
        appendDigit(value / 10, to: &output)
        appendDigit(value, to: &output)
    }
}

func av1CodecParametersString(_ record: borrowing WebCore.AV1CodecFields) -> WebCore.MediaParserShortString {
    makeShortString(AV1CodecString(record))
}

// MARK: Validation

// Ref: https://aomediacodec.github.io/av1-spec/av1-spec.pdf, 6.4.1 (general sequence header OBU semantics) and
// 6.4.2 (color config semantics). A profile outside the enumeration passes the profile checks.
private func isValidAV1ConfigurationRecord(_ record: borrowing WebCore.AV1CodecFields) -> Bool {
    let chromaSubsamplingValue = record.chromaSubsampling
    guard isValidAV1ChromaSubsampling(chromaSubsamplingValue),
        let chromaSubsampling = WebCore.AV1ConfigurationChromaSubsampling(rawValue: chromaSubsamplingValue)
    else {
        return false
    }
    let bitDepth = record.bitDepth
    let monochrome = record.monochrome

    switch record.profile {
    case .Main:
        if bitDepth != 8 && bitDepth != 10 {
            return false
        }
        if chromaSubsampling != .Subsampling_420_Unknown && chromaSubsampling != .Subsampling_420_Vertical
            && chromaSubsampling != .Subsampling_420_Colocated
        {
            return false
        }
    case .High:
        if bitDepth != 8 && bitDepth != 10 {
            return false
        }
        if monochrome != 0 {
            return false
        }
        if chromaSubsampling != .Subsampling_444 {
            return false
        }
    case .Professional:
        if bitDepth == 8 || bitDepth == 10 {
            if chromaSubsampling != .Subsampling_444 {
                return false
            }
        } else if bitDepth != 12 {
            return false
        }
    @unknown default:
        break
    }

    // With monochrome, the only valid subsampling is 4:2:0 with an unknown chroma sample position.
    return monochrome == 0 || chromaSubsampling == .Subsampling_420_Unknown
}

private struct AV1LevelLimits {
    var maxPicSize: UInt32
    var maxWidth: UInt32
    var maxHeight: UInt32
    var maxFramerate: Double
    var mainMaxBitrate: UInt32
    var highMaxBitrate: UInt32

    init(
        _ maxPicSize: UInt32,
        _ maxWidth: UInt32,
        _ maxHeight: UInt32,
        _ maxFramerate: Double,
        _ mainMaxBitrate: UInt32,
        _ highMaxBitrate: UInt32
    ) {
        self.maxPicSize = maxPicSize
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFramerate = maxFramerate
        self.mainMaxBitrate = mainMaxBitrate
        self.highMaxBitrate = highMaxBitrate
    }
}

// "AV1 Bitstream & Decoding Process Specification", Version 1.0.0 with Errata 1, Annex A: Profiles and levels.
private func av1LevelLimits(_ level: WebCore.AV1ConfigurationLevel) -> AV1LevelLimits? {
    switch level {
    case .Level_2_0:
        AV1LevelLimits(147_456, 2048, 1152, 30, 1_572_864, 0)
    case .Level_2_1:
        AV1LevelLimits(278_784, 2816, 1584, 30, 3_145_728, 0)
    case .Level_3_0:
        AV1LevelLimits(665_856, 4352, 2448, 30, 6_291_456, 0)
    case .Level_3_1:
        AV1LevelLimits(1_065_024, 5504, 3096, 30, 10_485_760, 0)
    case .Level_4_0:
        AV1LevelLimits(2_359_296, 6144, 3456, 30, 12_582_912, 31_457_280)
    case .Level_4_1:
        AV1LevelLimits(2_359_296, 6144, 3456, 60, 20_971_520, 52_428_800)
    case .Level_5_0:
        AV1LevelLimits(8_912_896, 8192, 4352, 30, 31_457_280, 104_857_600)
    case .Level_5_1:
        AV1LevelLimits(8_912_896, 8192, 4352, 60, 41_943_040, 167_772_160)
    case .Level_5_2, .Level_5_3:
        AV1LevelLimits(8_912_896, 8192, 4352, 120, 62_914_560, 251_658_240)
    case .Level_6_0:
        AV1LevelLimits(35_651_584, 16384, 8704, 30, 62_914_560, 251_658_240)
    case .Level_6_1:
        AV1LevelLimits(35_651_584, 16384, 8704, 60, 104_857_600, 503_316_480)
    case .Level_6_2, .Level_6_3:
        AV1LevelLimits(35_651_584, 16384, 8704, 120, 167_772_160, 838_860_800)
    default:
        nil
    }
}

// MARK: Decoder configuration record (av1C)

// Ref: https://aomediacodec.github.io/av1-isobmff/, 2.3: AV1 Codec Configuration Box.
private func parseAV1DecoderConfigurationRecord(_ data: Span<UInt8>, into record: inout WebCore.AV1CodecFields) -> Bool {
    guard data.count >= 4 else {
        return false
    }
    var reader = SpanBitReader(data)

    // marker, version
    guard reader.readBits(1) == 1, reader.readBits(7) == 1 else {
        return false
    }

    let profile = UInt8(truncatingIfNeeded: reader.readBits(3))
    guard reader.ok, isValidAV1Profile(profile), let profileValue = WebCore.AV1ConfigurationProfile(rawValue: profile) else {
        return false
    }
    record.profile = profileValue

    let level = UInt8(truncatingIfNeeded: reader.readBits(5))
    guard reader.ok, isValidAV1Level(level), let levelValue = WebCore.AV1ConfigurationLevel(rawValue: level) else {
        return false
    }
    record.level = levelValue

    record.tier = reader.readFlag() ? .High : .Main
    let highBitDepth = reader.readFlag()
    let twelveBit = reader.readFlag()
    if !highBitDepth && twelveBit {
        return false
    }
    record.bitDepth = highBitDepth ? (twelveBit ? 12 : 10) : 8

    record.monochrome = reader.readFlag() ? 1 : 0
    let chromaSubsamplingX: UInt8 = reader.readFlag() ? 1 : 0
    let chromaSubsamplingY: UInt8 = reader.readFlag() ? 1 : 0
    let chromaSamplePosition = UInt8(truncatingIfNeeded: reader.readBits(2))
    guard reader.ok else {
        return false
    }
    let hasChromaSamplePosition = chromaSubsamplingX != 0 && chromaSubsamplingY != 0
    record.chromaSubsampling =
        chromaSubsamplingX * 100 + chromaSubsamplingY * 10 + (hasChromaSamplePosition ? chromaSamplePosition : 0)

    record.width = 0
    record.height = 0
    return true
}

// MARK: Sequence header OBU

// Ref: https://aomediacodec.github.io/av1-spec/, 5.5: sequence_header_obu(). Fills what a codec string describes,
// and the maximum frame size; leaves codecName alone.
func parseSequenceHeaderOBU(_ data: Span<UInt8>, into record: inout WebCore.AV1CodecFields) -> Bool {
    var reader = SpanBitReader(data)

    let seqProfile = UInt8(truncatingIfNeeded: reader.readBits(3))
    guard reader.ok, isValidAV1Profile(seqProfile), let profile = WebCore.AV1ConfigurationProfile(rawValue: seqProfile) else {
        return false
    }
    record.profile = profile

    let stillPicture = reader.readFlag()
    let reducedStillPictureHeader = reader.readFlag()
    guard reader.ok, !reducedStillPictureHeader || stillPicture else {
        return false
    }

    if reducedStillPictureHeader {
        let seqLevelIdx = UInt8(truncatingIfNeeded: reader.readBits(5))
        guard reader.ok, isValidAV1Level(seqLevelIdx), let level = WebCore.AV1ConfigurationLevel(rawValue: seqLevelIdx) else {
            return false
        }
        record.level = level
        record.tier = .Main
    } else {
        var decoderModelInfoPresentFlag = false
        var bufferDelayLengthMinus1 = 0
        if reader.readFlag() { // timing_info_present_flag
            // timing_info(): num_units_in_display_tick, time_scale, equal_picture_interval.
            reader.consumeBits(64)
            if reader.readFlag() {
                // num_ticks_per_picture_minus_1, a uvlc() that stops after 32 leading zeros.
                var leadingZeros = 0
                while leadingZeros < 32 && !reader.readFlag() {
                    leadingZeros += 1
                }
                if leadingZeros > 0 && leadingZeros < 32 {
                    reader.consumeBits(leadingZeros)
                }
            }
            decoderModelInfoPresentFlag = reader.readFlag()
            if decoderModelInfoPresentFlag {
                // decoder_model_info(): buffer_delay_length_minus_1, num_units_in_decoding_tick,
                // buffer_removal_time_length_minus_1, frame_presentation_time_length_minus_1.
                bufferDelayLengthMinus1 = Int(reader.readBits(5))
                reader.consumeBits(32 + 5 + 5)
            }
        }
        let initialDisplayDelayPresentFlag = reader.readFlag()
        let operatingPointsCntMinus1 = Int(reader.readBits(5))
        guard reader.ok else {
            return false
        }

        for i in 0...operatingPointsCntMinus1 {
            reader.consumeBits(12) // operating_point_idc[i]
            let seqLevelIdx = UInt8(truncatingIfNeeded: reader.readBits(5))
            guard reader.ok else {
                return false
            }
            if i == 0 {
                guard isValidAV1Level(seqLevelIdx), let level = WebCore.AV1ConfigurationLevel(rawValue: seqLevelIdx) else {
                    return false
                }
                record.level = level
            }
            // seq_tier[i] is only present above level 3.3.
            let seqTier = seqLevelIdx > 7 && reader.readFlag()
            if i == 0 {
                record.tier = seqTier ? .High : .Main
            }
            if decoderModelInfoPresentFlag && reader.readFlag() { // decoder_model_present_for_this_op[i]
                // operating_parameters_info(i): decoder_buffer_delay, encoder_buffer_delay, low_delay_mode_flag.
                let n = bufferDelayLengthMinus1 + 1
                reader.consumeBits(n + n + 1)
            }
            if initialDisplayDelayPresentFlag && reader.readFlag() { // initial_display_delay_present_for_this_op[i]
                reader.consumeBits(4) // initial_display_delay_minus_1[i]
            }
            guard reader.ok else {
                return false
            }
        }
    }

    let frameWidthBitsMinus1 = Int(reader.readBits(4))
    let frameHeightBitsMinus1 = Int(reader.readBits(4))
    let maxFrameWidthMinus1 = reader.readBits(frameWidthBitsMinus1 + 1)
    let maxFrameHeightMinus1 = reader.readBits(frameHeightBitsMinus1 + 1)
    guard reader.ok else {
        return false
    }
    // At most 16 bits each.
    record.width = maxFrameWidthMinus1 + 1
    record.height = maxFrameHeightMinus1 + 1

    if !reducedStillPictureHeader && reader.readFlag() { // frame_id_numbers_present_flag
        reader.consumeBits(4 + 3) // delta_frame_id_length_minus_2, additional_frame_id_length_minus_1
    }

    reader.consumeBits(3) // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter

    if !reducedStillPictureHeader {
        reader.consumeBits(4) // enable_interintra_compound, enable_masked_compound, enable_warped_motion, enable_dual_filter
        let enableOrderHint = reader.readFlag()
        if enableOrderHint {
            reader.consumeBits(2) // enable_jnt_comp, enable_ref_frame_mvs
        }
        // seq_choose_screen_content_tools means SELECT_SCREEN_CONTENT_TOOLS, otherwise seq_force_screen_content_tools.
        let seqForceScreenContentTools = reader.readFlag() || reader.readFlag()
        if seqForceScreenContentTools && !reader.readFlag() { // seq_choose_integer_mv
            reader.consumeBits(1) // seq_force_integer_mv
        }
        if enableOrderHint {
            reader.consumeBits(3) // order_hint_bits_minus_1
        }
    }

    reader.consumeBits(3) // enable_superres, enable_cdef, enable_restoration

    // color_config()
    let highBitdepth = reader.readFlag()
    if seqProfile == 2 && highBitdepth {
        record.bitDepth = reader.readFlag() ? 12 : 10 // twelve_bit
    } else {
        record.bitDepth = highBitdepth ? 10 : 8
    }

    let monochrome = seqProfile != 1 && reader.readFlag()
    record.monochrome = monochrome ? 1 : 0

    var colorPrimaries = WebCore.AV1ConfigurationColorPrimaries.Unspecified.rawValue
    var transferCharacteristics = WebCore.AV1ConfigurationTransferCharacteristics.Unspecified.rawValue
    var matrixCoefficients = WebCore.AV1ConfigurationMatrixCoefficients.Unspecified.rawValue
    if reader.readFlag() { // color_description_present_flag
        colorPrimaries = UInt8(truncatingIfNeeded: reader.readBits(8))
        transferCharacteristics = UInt8(truncatingIfNeeded: reader.readBits(8))
        matrixCoefficients = UInt8(truncatingIfNeeded: reader.readBits(8))
    }
    guard reader.ok else {
        return false
    }
    record.colorPrimaries = colorPrimaries
    record.transferCharacteristics = transferCharacteristics
    record.matrixCoefficients = matrixCoefficients

    let colorRange: Bool
    var subsamplingX: UInt8 = 1
    var subsamplingY: UInt8 = 1
    var chromaSamplePosition: UInt8 = 0 // CSP_UNKNOWN
    if monochrome {
        colorRange = reader.readFlag()
    } else if colorPrimaries == WebCore.AV1ConfigurationColorPrimaries.BT_709_6.rawValue
        && transferCharacteristics == WebCore.AV1ConfigurationTransferCharacteristics.IEC_61966_2_1.rawValue
        && matrixCoefficients == WebCore.AV1ConfigurationMatrixCoefficients.Identity.rawValue
    {
        colorRange = true
        subsamplingX = 0
        subsamplingY = 0
    } else {
        colorRange = reader.readFlag()
        switch seqProfile {
        case 0:
            break
        case 1:
            subsamplingX = 0
            subsamplingY = 0
        default:
            if record.bitDepth == 12 {
                subsamplingX = reader.readFlag() ? 1 : 0
                subsamplingY = subsamplingX != 0 && reader.readFlag() ? 1 : 0
            } else {
                subsamplingY = 0
            }
        }
        if subsamplingX != 0 && subsamplingY != 0 {
            chromaSamplePosition = UInt8(truncatingIfNeeded: reader.readBits(2))
        }
    }
    guard reader.ok else {
        return false
    }

    record.videoFullRangeFlag = colorRange ? .FullRange : .VideoRange
    // The reserved chroma_sample_position 3 gives 113, which isn't a valid chromaSubsampling.
    let hasChromaSamplePosition = subsamplingX != 0 && subsamplingY != 0
    record.chromaSubsampling = subsamplingX * 100 + subsamplingY * 10 + (hasChromaSamplePosition ? chromaSamplePosition : 0)
    return true
}

// leb128() as AV1Utilities.cpp read obu_size: at most 8 bytes, and 0 for a value of 2^32 - 1 or more or when the data
// runs out. index moves past the bytes read either way.
private func readULEBSize(_ data: Span<UInt8>, _ index: inout Int) -> UInt64 {
    var value: UInt64 = 0
    for byteIndex in 0..<8 {
        guard index < data.count else {
            return 0
        }
        let byte = data[index]
        index += 1
        value |= UInt64(byte & 0x7F) << (7 * byteIndex)
        if value >= UInt64(UInt32.max) {
            return 0
        }
        if byte & 0x80 == 0 {
            break
        }
    }
    return value
}

// The first sequence header OBU of a stream of OBUs that all have obu_size: the ranges of the whole OBU and of its
// payload.
private func findSequenceHeaderOBU(in data: Span<UInt8>) -> (obu: Range<Int>, payload: Range<Int>)? {
    var index = 0
    while index < data.count {
        let start = index
        let header = data[index]
        index += 1
        // obu_forbidden_bit, obu_has_size_field
        guard header & 0x80 == 0, header & 0x02 != 0 else {
            return nil
        }
        if header & 0x04 != 0 { // obu_extension_flag
            index += 1
        }
        let payloadSize = readULEBSize(data, &index)
        let end = UInt64(index) + payloadSize
        guard end <= UInt64(data.count) else {
            return nil
        }
        if header >> 3 == 1 { // OBU_SEQUENCE_HEADER
            return (start..<Int(end), index..<Int(end))
        }
        index = Int(end)
    }
    return nil
}

// MARK: Stream to VideoInfo

private func platformVideoColorPrimaries(_ value: UInt8) -> WebCore.PlatformVideoColorPrimaries {
    switch WebCore.AV1ConfigurationColorPrimaries(rawValue: value) {
    case .BT_709_6:
        .Bt709
    case .BT_470_6_M:
        .Bt470m
    case .BT_470_7_BG:
        .Bt470bg
    case .BT_601_7:
        .Smpte170m
    case .SMPTE_ST_240:
        .Smpte240m
    case .Film:
        .Film
    case .BT_2020_Nonconstant_Luminance:
        .Bt2020
    case .SMPTE_ST_428_1:
        .SmpteSt4281
    case .SMPTE_RP_431_2:
        .SmpteRp431
    case .SMPTE_EG_432_1:
        .SmpteEg432
    case .EBU_Tech_3213_E:
        .JedecP22Phosphors
    default:
        .Unspecified
    }
}

private func platformVideoTransferCharacteristics(_ value: UInt8) -> WebCore.PlatformVideoTransferCharacteristics {
    switch WebCore.AV1ConfigurationTransferCharacteristics(rawValue: value) {
    case .BT_709_6:
        .Bt709
    case .BT_470_6_M:
        .Gamma22curve
    case .BT_470_7_BG:
        .Gamma28curve
    case .BT_601_7:
        .Smpte170m
    case .SMPTE_ST_240:
        .Smpte240m
    case .Linear:
        .Linear
    case .Logrithmic:
        .Log
    case .Logrithmic_Sqrt:
        .LogSqrt
    case .IEC_61966_2_4:
        .Iec6196624
    case .BT_1361_0:
        .Bt1361ExtendedColourGamut
    case .IEC_61966_2_1:
        .Iec6196621
    case .BT_2020_10bit:
        .Bt2020_10bit
    case .BT_2020_12bit:
        .Bt2020_12bit
    case .SMPTE_ST_2084:
        .SmpteSt2084
    case .SMPTE_ST_428_1:
        .SmpteSt4281
    case .BT_2100_HLG:
        .AribStdB67Hlg
    default:
        .Unspecified
    }
}

private func platformVideoMatrixCoefficients(_ value: UInt8) -> WebCore.PlatformVideoMatrixCoefficients {
    switch WebCore.AV1ConfigurationMatrixCoefficients(rawValue: value) {
    case .Identity:
        .Rgb
    case .BT_709_6:
        .Bt709
    case .FCC:
        .Fcc
    case .BT_470_7_BG:
        .Bt470bg
    case .BT_601_7:
        .Smpte170m
    case .SMPTE_ST_240:
        .Smpte240m
    case .YCgCo:
        .YCgCo
    case .BT_2020_Nonconstant_Luminance:
        .Bt2020NonconstantLuminance
    case .BT_2020_Constant_Luminance:
        .Bt2020ConstantLuminance
    default:
        .Unspecified
    }
}

private func videoInfoFields(_ record: borrowing WebCore.AV1CodecFields) -> WebCore.VideoInfoFields {
    var fields = WebCore.VideoInfoFields()
    fields.codecName = 0x6176_3031 // 'av01'
    fields.atomType = 0x6176_3143 // 'av1C'
    fields.width = Float(record.width)
    fields.height = Float(record.height)
    fields.displayWidth = fields.width
    fields.displayHeight = fields.height
    fields.bitDepth = record.bitDepth
    fields.primaries = platformVideoColorPrimaries(record.colorPrimaries)
    fields.transfer = platformVideoTransferCharacteristics(record.transferCharacteristics)
    fields.matrix = platformVideoMatrixCoefficients(record.matrixCoefficients)
    fields.fullRange = record.videoFullRangeFlag == .FullRange
    return fields
}

// An av1C box payload: the four bytes of AV1CodecConfigurationRecord (marker, version, seq_profile, seq_level_idx_0,
// seq_tier_0, high_bitdepth, twelve_bit, monochrome, chroma_subsampling_x/y, chroma_sample_position, and no
// initial_presentation_delay), then configOBUs.
private func appendAV1CodecConfigurationBox(
    _ record: borrowing WebCore.AV1CodecFields,
    configOBUs: Span<UInt8>,
    to atom: inout WebCore.MediaParserByteVector
) {
    let profile = record.profile.rawValue
    let level = record.level.rawValue
    let tier = record.tier.rawValue
    let monochrome = record.monochrome
    let bitDepth = record.bitDepth
    let chromaSubsampling = record.chromaSubsampling
    let highBitdepth: UInt8 = bitDepth > 8 ? 1 : 0
    let twelveBit: UInt8 = bitDepth == 12 ? 1 : 0
    let chromaSubsamplingX = (chromaSubsampling / 100) & 1
    let chromaSubsamplingY = ((chromaSubsampling / 10) % 10) & 1
    let chromaSamplePosition = chromaSubsampling % 10

    atom.append(consuming: 0x81)
    atom.append(consuming: profile << 5 | level)
    atom.append(
        consuming: tier << 7 | highBitdepth << 6 | twelveBit << 5 | monochrome << 4 | chromaSubsamplingX << 3
            | chromaSubsamplingY << 2 | chromaSamplePosition
    )
    atom.append(consuming: 0)
    WebCore.appendBytes(&atom, configOBUs)
}

// MARK: Entry points for AV1Utilities.cpp

@_expose(Cxx)
func parseAV1CodecParametersImpl(_ codec: borrowing WebCore.MediaParserText) -> WebCore.AV1CodecFieldsResult {
    var result = WebCore.AV1CodecFieldsResult()
    result.parsed =
        codec.is8Bit
        ? parseAV1CodecParameters(codec.span8() as Span<UInt8>, into: &result.fields)
        : parseAV1CodecParameters(codec.span16() as Span<UInt16>, into: &result.fields)
    return result
}

@_expose(Cxx)
func createAV1CodecParametersStringImpl(_ record: WebCore.AV1CodecFields) -> WebCore.MediaParserShortString {
    av1CodecParametersString(record)
}

@_expose(Cxx)
func validateAV1ConfigurationRecordImpl(_ record: WebCore.AV1CodecFields) -> Bool {
    isValidAV1ConfigurationRecord(record)
}

// Whether a video of this size, frame rate and bit rate is within the record's level and tier.
@_expose(Cxx)
func validateAV1PerLevelConstraintsImpl(
    _ record: WebCore.AV1CodecFields,
    _ width: UInt32,
    _ height: UInt32,
    _ framerate: Double,
    _ bitrate: UInt64
) -> Bool {
    guard let limits = av1LevelLimits(record.level) else {
        return false
    }
    let maxBitrate = record.tier == .Main ? limits.mainMaxBitrate : limits.highMaxBitrate
    return width <= limits.maxWidth && height <= limits.maxHeight
        && UInt64(width) * UInt64(height) <= UInt64(limits.maxPicSize) && framerate <= limits.maxFramerate
        && bitrate <= UInt64(maxBitrate)
}

@_expose(Cxx)
func parseAV1DecoderConfigurationRecordImpl(_ data: borrowing WebCore.MediaParserBytes) -> WebCore.AV1CodecFieldsResult {
    let bytes: Span<UInt8> = data.span()
    var result = WebCore.AV1CodecFieldsResult()
    result.parsed = parseAV1DecoderConfigurationRecord(bytes, into: &result.fields)
    return result
}

// From the stream's first sequence header OBU: the VideoInfo fields it gives (with the frame size as the display size),
// its codec string, and the av1C box payload, which carries the whole OBU. Without one, codecString is left alone.
@_expose(Cxx)
func createVideoInfoFromAV1StreamImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ atom: inout WebCore.MediaParserByteVector,
    _ codecString: inout WebCore.MediaParserShortString
) -> WebCore.AV1VideoInfoResult {
    let bytes: Span<UInt8> = data.span()
    var record = WebCore.AV1CodecFields()
    guard let sequenceHeader = findSequenceHeaderOBU(in: bytes), parseSequenceHeaderOBU(bytes.extracting(sequenceHeader.payload), into: &record)
    else {
        return WebCore.AV1VideoInfoResult()
    }
    appendAV1CodecConfigurationBox(record, configOBUs: bytes.extracting(sequenceHeader.obu), to: &atom)
    codecString = av1CodecParametersString(record)
    var result = WebCore.AV1VideoInfoResult()
    result.videoInfo = videoInfoFields(record)
    result.created = true
    return result
}

@_expose(Cxx)
func parseAV1ProfileStringImpl(_ string: borrowing WebCore.MediaParserText) -> WebCore.AV1ValueResult {
    let value =
        string.is8Bit
        ? (string.span8() as Span<UInt8>).parseAV1Value(isValidAV1Profile)
        : (string.span16() as Span<UInt16>).parseAV1Value(isValidAV1Profile)
    return av1ValueResult(value)
}

@_expose(Cxx)
func parseAV1LevelStringImpl(_ string: borrowing WebCore.MediaParserText) -> WebCore.AV1ValueResult {
    let value =
        string.is8Bit
        ? (string.span8() as Span<UInt8>).parseAV1Value(isValidAV1Level)
        : (string.span16() as Span<UInt16>).parseAV1Value(isValidAV1Level)
    return av1ValueResult(value)
}

private func av1ValueResult(_ value: UInt8?) -> WebCore.AV1ValueResult {
    var result = WebCore.AV1ValueResult()
    if let value {
        result.value = value
        result.parsed = true
    }
    return result
}

#endif // ENABLE_WEBCORE_SWIFT
