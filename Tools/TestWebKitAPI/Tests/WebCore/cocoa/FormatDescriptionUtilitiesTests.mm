/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"

#if USE(AVFOUNDATION)

#import <CoreMedia/CMFormatDescription.h>
#import <WebCore/FormatDescriptionUtilities.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

#import <pal/cf/CoreMediaSoftLink.h>

namespace TestWebKitAPI {

static String codecString(FourCharCode subtype, NSDictionary *extensions = nil)
{
    CMFormatDescriptionRef rawDescription = nullptr;
    PAL::CMVideoFormatDescriptionCreate(kCFAllocatorDefault, subtype, 640, 480, (__bridge CFDictionaryRef)extensions, &rawDescription);
    RetainPtr description = adoptCF(rawDescription);
    EXPECT_TRUE(description);
    return WebCore::codecFromFormatDescription(description.get());
}

static String codecString(FourCharCode subtype, NSString *atomKey, id atom)
{
    return codecString(subtype, @{ (__bridge NSString *)PAL::kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{ atomKey: atom } });
}

static NSData *data(std::initializer_list<uint8_t> bytes, size_t size)
{
    NSMutableData *result = [NSMutableData dataWithLength:size];
    std::ranges::copy(bytes, static_cast<uint8_t*>(result.mutableBytes));
    return result;
}

// The configuration records give "avc1.64001F", "hvc1.1.6.L93.90", "dvh1.05.06" and "av01.0.04M.08".
static NSData *avcC() { return data({ 0x01, 0x64, 0x00, 0x1F }, 24); }
static NSData *hvcC() { return data({ 0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5D }, 23); }
static NSData *dvcC() { return data({ 0x01, 0x00, 0x0A, 0x30 }, 24); }
static NSData *av1C() { return data({ 0x81, 0x04, 0x0C, 0x00 }, 4); }

TEST(FormatDescriptionUtilities, CodecStringsWithoutConfigurationRecords)
{
    EXPECT_EQ(WebCore::codecFromFormatDescription(nullptr), emptyString());

    std::pair<FourCharCode, ASCIILiteral> expectations[] = {
        { kCMVideoCodecType_H264, "avc1"_s }, { 'cavc', "avc1"_s }, { kCMVideoCodecType_HEVC, "hvc1"_s },
        { kCMVideoCodecType_HEVCWithAlpha, "hvc1"_s }, { 'chvc', "hvc1"_s }, { kCMVideoCodecType_DolbyVisionHEVC, "dvh1"_s },
        { 'cdh1', "dvh1"_s }, { kCMVideoCodecType_MPEG4Video, "mp4v"_s }, { kCMVideoCodecType_VP9, "vp09"_s },
        { kAudioFormatAC3, "ac-3"_s }, { kAudioFormatMPEG4AAC, "mp4a.40.2"_s }, { kAudioFormatMPEG4AAC_HE, "mp4a.40.5"_s },
        { kAudioFormatMPEG4AAC_HE_V2, "mp4a.40.29"_s }, { kAudioFormatMPEG4AAC_LD, "mp4a.40.23"_s },
        { kAudioFormatMPEG4AAC_ELD, "mp4a.40.39"_s }, { kAudioFormatFLAC, "flac"_s }, { kAudioFormatOpus, "opus"_s },
        { kAudioFormatEnhancedAC3, "ec-3"_s }, { 'ec+3', "ec-3"_s }, { 'qec3', "ec-3"_s }, { 'ce-3', "ec-3"_s }, { 'dts ', "dts"_s },
#if ENABLE(AV1)
        { kCMVideoCodecType_AV1, "av01"_s },
#endif
    };
    for (auto& [subtype, expected] : expectations)
        EXPECT_EQ(codecString(subtype), String { expected }) << subtype;

    auto unknown = codecString('apch');
    EXPECT_FALSE(unknown.isNull());
    EXPECT_TRUE(unknown.isEmpty());
}

TEST(FormatDescriptionUtilities, CodecStringsFromConfigurationRecords)
{
    EXPECT_EQ(codecString(kCMVideoCodecType_H264, @"avcC", avcC()), "avc1.64001F"_s);
    EXPECT_EQ(codecString('cavc', @"avcC", avcC()), "avc1.64001F"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_HEVC, @"hvcC", hvcC()), "hvc1.1.6.L93.90"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_HEVCWithAlpha, @"hvcC", hvcC()), "hvc1.1.6.L93.90"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_DolbyVisionHEVC, @"dvcC", dvcC()), "dvh1.05.06"_s);
#if ENABLE(AV1)
    EXPECT_EQ(codecString(kCMVideoCodecType_AV1, @"av1C", av1C()), "av01.0.04M.08"_s);
#endif
}

// Without a record that parses, the codec string is the codec name.
TEST(FormatDescriptionUtilities, CodecStringsFromUnusableConfigurationRecords)
{
    EXPECT_EQ(codecString(kCMVideoCodecType_H264, @"hvcC", avcC()), "avc1"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_H264, @"avcC", [avcC() subdataWithRange:NSMakeRange(0, 23)]), "avc1"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_H264, @"avcC", [NSData data]), "avc1"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_H264, @"avcC", @[ avcC() ]), "avc1"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_HEVC, @"hvcC", [NSData data]), "hvc1"_s);
    EXPECT_EQ(codecString(kCMVideoCodecType_DolbyVisionHEVC, @"dvcC", @"dvcC"), "dvh1"_s);
#if ENABLE(AV1)
    EXPECT_EQ(codecString(kCMVideoCodecType_AV1, @"av1C", data({ 0x80, 0x04, 0x0C, 0x00 }, 4)), "av01"_s);
#endif
    EXPECT_EQ(codecString(kCMVideoCodecType_H264, @{ (__bridge NSString *)PAL::kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @"atoms" }), "avc1"_s);
}

TEST(FormatDescriptionUtilities, CodecStringOfProtectedContentComesFromItsOriginalFormat)
{
    NSDictionary *extensions = @{
        (__bridge NSString *)PAL::kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{ @"avcC": avcC() },
        (__bridge NSString *)PAL::kCMFormatDescriptionExtension_ProtectedContentOriginalFormat: @(kCMVideoCodecType_H264),
    };
    EXPECT_EQ(codecString('encv', extensions), "avc1.64001F"_s);
}

} // namespace TestWebKitAPI

#endif // USE(AVFOUNDATION)
