// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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

private import Cxx
import WebCore_Internal.AV1CodecConfigurationRecord
import WebCore_Internal.CMParsingTypes
import WebCore_Internal.MediaParsersCxxBridging
import WebCore_Internal.VideoCodecParameterTypes
import wtf

// The codec strings of codecFromFormatDescription(), whose shell reads the media subtype and fetches the decoder
// configuration atom.

private enum CodecFourCC {
    static let avc1: UInt32 = 0x6176_6331 // kCMVideoCodecType_H264
    static let cavc: UInt32 = 0x6361_7663
    static let hvc1: UInt32 = 0x6876_6331 // kCMVideoCodecType_HEVC
    static let muxa: UInt32 = 0x6D75_7861 // kCMVideoCodecType_HEVCWithAlpha
    static let chvc: UInt32 = 0x6368_7663
    static let dvh1: UInt32 = 0x6476_6831 // kCMVideoCodecType_DolbyVisionHEVC
    static let cdh1: UInt32 = 0x6364_6831
    static let mp4v: UInt32 = 0x6D70_3476 // kCMVideoCodecType_MPEG4Video
    static let vp09: UInt32 = 0x7670_3039 // kCMVideoCodecType_VP9
    static let av01: UInt32 = 0x6176_3031 // kCMVideoCodecType_AV1
    static let ac3: UInt32 = 0x6163_2D33 // kAudioFormatAC3
    static let aac: UInt32 = 0x6161_6320 // kAudioFormatMPEG4AAC
    static let aach: UInt32 = 0x6161_6368 // kAudioFormatMPEG4AAC_HE
    static let aacp: UInt32 = 0x6161_6370 // kAudioFormatMPEG4AAC_HE_V2
    static let aacl: UInt32 = 0x6161_636C // kAudioFormatMPEG4AAC_LD
    static let aace: UInt32 = 0x6161_6365 // kAudioFormatMPEG4AAC_ELD
    static let flac: UInt32 = 0x666C_6163 // kAudioFormatFLAC
    static let opus: UInt32 = 0x6F70_7573 // kAudioFormatOpus
    static let ec3: UInt32 = 0x6563_2D33 // kAudioFormatEnhancedAC3
    static let ecPlus3: UInt32 = 0x6563_2B33
    static let qec3: UInt32 = 0x7165_6333
    static let ce3: UInt32 = 0x6365_2D33
    static let dts: UInt32 = 0x6474_7320

    static let avcC: UInt32 = 0x6176_6343
    static let hvcC: UInt32 = 0x6876_6343
    static let dvcC: UInt32 = 0x6476_6343
    static let av1C: UInt32 = 0x6176_3143
}

// The SampleDescriptionExtensionAtoms key of the decoder configuration record the subtype's codec string comes from,
// or 0.
@_expose(Cxx)
func codecConfigurationAtomTypeImpl(_ subtype: UInt32) -> UInt32 {
    switch subtype {
    case CodecFourCC.avc1, CodecFourCC.cavc:
        return CodecFourCC.avcC
    case CodecFourCC.hvc1, CodecFourCC.muxa, CodecFourCC.chvc:
        return CodecFourCC.hvcC
    case CodecFourCC.dvh1, CodecFourCC.cdh1:
        return CodecFourCC.dvcC
    #if ENABLE_AV1
    case CodecFourCC.av01:
        return CodecFourCC.av1C
    #endif
    default:
        return 0
    }
}

// Without the atom, or when it doesn't parse, the codec string is the bare codec name. Fixed names come back as
// FormatDescriptionCodecName for the shell to return as literals; a string built from the atom comes back in codecString.
@_expose(Cxx)
func codecStringFromFormatDescriptionImpl(
    _ subtype: UInt32,
    _ atom: borrowing WebCore.MediaParserBytes,
    _ hasAtom: Bool
) -> WebCore.FormatDescriptionCodecResult {
    var result = WebCore.FormatDescriptionCodecResult()
    result.name = codecName(subtype, atom, hasAtom, &result.codecString)
    return result
}

private func codecName(
    _ subtype: UInt32,
    _ atom: borrowing WebCore.MediaParserBytes,
    _ hasAtom: Bool,
    _ codecString: inout WebCore.MediaParserShortString
) -> WebCore.FormatDescriptionCodecName {
    switch subtype {
    case CodecFourCC.avc1, CodecFourCC.cavc:
        guard hasAtom else {
            return .Avc1
        }
        let record = parseAVCDecoderConfigurationRecordImpl(atom)
        guard record.parsed else {
            return .Avc1
        }
        codecString = createAVCCodecParametersStringImpl(record.parameters)
        return .Parsed
    case CodecFourCC.hvc1, CodecFourCC.muxa, CodecFourCC.chvc:
        guard hasAtom else {
            return .Hvc1
        }
        let record = parseHEVCDecoderConfigurationRecordImpl(CodecFourCC.hvc1, atom)
        guard record.parsed else {
            return .Hvc1
        }
        codecString = hevcCodecParametersShortString(record.fields)
        return .Parsed
    case CodecFourCC.dvh1, CodecFourCC.cdh1:
        guard hasAtom else {
            return .Dvh1
        }
        let record = parseDoViDecoderConfigurationRecordImpl(atom)
        guard record.parsed else {
            return .Dvh1
        }
        codecString = createDoViCodecParametersStringImpl(record.parameters)
        return .Parsed
    case CodecFourCC.mp4v:
        return .Mp4v
    case CodecFourCC.vp09:
        return .Vp09
    case CodecFourCC.ac3:
        return .Ac3
    case CodecFourCC.aac:
        return .Mp4a40_2
    case CodecFourCC.aach:
        return .Mp4a40_5
    case CodecFourCC.aacp:
        return .Mp4a40_29
    case CodecFourCC.aacl:
        return .Mp4a40_23
    case CodecFourCC.aace:
        return .Mp4a40_39
    case CodecFourCC.flac:
        return .Flac
    case CodecFourCC.opus:
        return .Opus
    case CodecFourCC.ec3, CodecFourCC.ecPlus3, CodecFourCC.qec3, CodecFourCC.ce3:
        return .Ec3
    case CodecFourCC.dts:
        return .Dts
    #if ENABLE_AV1
    case CodecFourCC.av01:
        guard hasAtom else {
            return .Av01
        }
        let record = parseAV1DecoderConfigurationRecordImpl(atom)
        guard record.parsed else {
            return .Av01
        }
        codecString = av1CodecParametersString(record.fields)
        return .Parsed
    #endif
    default:
        return .Unknown
    }
}

#endif // ENABLE_WEBCORE_SWIFT
