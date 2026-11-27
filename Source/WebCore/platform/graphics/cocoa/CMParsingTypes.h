/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#pragma once

#include <CoreMedia/CoreMedia.h>
#include <WebCore/CVUtilities.h>
#include <WebCore/ISOParseResults.h>
#include <WebCore/MediaChannelLayout.h>
#include <WebCore/MediaParsersCxxBridging.h>
#include <WebCore/MediaSamplesBlock.h>
#include <WebCore/VideoCodecParameterTypes.h>
#include <WebCore/WebMAudioUtilitiesCocoa.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/SwiftBridging.h>

namespace WebCore {

// The two kCVImageBufferPixelAspectRatio spacings, a fraction in lowest terms.
struct PixelAspectRatioSpacings {
    int64_t horizontal { 0 };
    int64_t vertical { 0 };
};

struct PixelAspectRatioResult {
    PixelAspectRatioSpacings spacings;
    bool valid { false };
};

// A video size as the integers CoreMedia and CoreVideo take.
struct VideoDimensions32 {
    int32_t width { 0 };
    int32_t height { 0 };
};

struct VideoDimensionsResult {
    VideoDimensions32 dimensions;
    bool valid { false };
};

// The first code units of a SampleDescriptionExtensionAtoms key: one more than a FourCC has, so that a longer key doesn't
// look like one.
struct ExtensionAtomKey {
    char16_t characters[5] { };
    uint8_t length { 0 };
};

struct FourCCResult {
    uint32_t value { 0 };
    bool valid { false };
};

// An AudioFormatVorbisModeInfo, and the mask that takes the mode number out of a packet's first byte.
struct VorbisModeParameters {
    uint32_t shortBlockSize { 0 };
    uint32_t longBlockSize { 0 };
    uint32_t modeCount { 0 };
    uint64_t modeFlags { 0 };
    uint32_t modeMask { 0 };
};

struct VorbisModeMaskResult {
    uint32_t modeMask { 0 };
    bool valid { false };
};

// A packet's frame count, and the block size it leaves for the next packet's.
struct VorbisPacketFrames {
    uint64_t frames { 0 };
    uint32_t lastBlockSize { 0 };
};

// The codec strings of codecFromFormatDescription() that are fixed names, so that the shell can return literals.
// Parsed means Swift built the string from a decoder configuration record.
enum class FormatDescriptionCodecName : uint8_t {
    Unknown,
    Parsed,
    Avc1,
    Hvc1,
    Dvh1,
    Av01,
    Mp4v,
    Vp09,
    Ac3,
    Mp4a40_2,
    Mp4a40_5,
    Mp4a40_29,
    Mp4a40_23,
    Mp4a40_39,
    Flac,
    Opus,
    Ec3,
    Dts,
};

// The codec name, and the codec string if it is Parsed.
struct FormatDescriptionCodecResult {
    FormatDescriptionCodecName name { FormatDescriptionCodecName::Unknown };
    MediaParserShortString codecString;
};

struct AudioStreamBasicDescriptionResult {
    AudioStreamBasicDescription description { };
    bool valid { false };
};

// The status of the call, or whether the channel layout was invalid for the number of channels.
struct AudioFormatDescriptionStatus {
    OSStatus status { 0 };
    bool invalidLayout { false };
};

// Where getKeyIDs() finds a format description's key IDs; keyID is the 'tenc' box's default KID.
enum class FormatDescriptionKeyIDsSource : uint8_t { None, TrackEncryptionBox, TransportStream };

struct FormatDescriptionKeyIDs {
    FormatDescriptionKeyIDsSource source { FormatDescriptionKeyIDsSource::None };
    InlineBytes16 keyID;
};

// MediaTime's comparison, which Swift doesn't import from its operator<=>.
inline bool isMediaTimeLessThan(const MediaTime& a, const MediaTime& b) { return a < b; }

// The buffers' CF objects, which Swift can't take out of a RetainPtr.
CF_RETURNS_RETAINED CMBlockBufferRef createCMBlockBufferForSharedBuffer(const MediaSamplesBlock&, size_t index);
CF_RETURNS_RETAINED CFDataRef createCFDataForSharedBuffer(const SharedBuffer&);

CF_RETURNS_NOT_RETAINED CFStringRef compressedAlphaDataAttachmentKey();

// The attachment keys toCMSampleBuffer() sets that PAL doesn't soft-link.
enum class SampleBufferAttachmentKey : uint8_t { BytesOfClearDataCount, CryptorIV };
CF_RETURNS_NOT_RETAINED CFStringRef sampleBufferAttachmentKey(SampleBufferAttachmentKey);

// The sample's attachments dictionary in CMSampleBufferGetSampleAttachmentsArray()'s array; null where the index is out
// of range or the value isn't a dictionary.
CF_RETURNS_NOT_RETAINED CFMutableDictionaryRef sampleAttachmentsDictionary(CFArrayRef, CFIndex);
void setSampleAttachment(CFMutableDictionaryRef, CFStringRef key, CFTypeRef value);

// CMAudioFormatDescriptionGetStreamBasicDescription's value, copied out; valid is false where it returns null.
AudioStreamBasicDescriptionResult audioStreamBasicDescription(CMFormatDescriptionRef);

// The description with the channel layout channelLayoutFromMediaChannelLayout() makes of the layout, if there is one;
// null with the status set where either fails.
CF_RETURNS_RETAINED CMFormatDescriptionRef createAudioFormatDescriptionWithLayout(AudioStreamBasicDescription, bool hasLayout, MediaChannelLayout, CFDictionaryRef extensions, AudioFormatDescriptionStatus&);

// PAL::CMBlockBufferCreateEmpty's block buffer with the status set; null where it fails or makes none.
CF_RETURNS_RETAINED CMBlockBufferRef createEmptyBlockBuffer(uint32_t capacity, OSStatus&);

CF_RETURNS_NOT_RETAINED CFStringRef separateAlphaStreamExtensionKey();

// For WebCoreDecompressionSession.swift, which takes no std::span and no SPI constant.
CF_RETURNS_RETAINED CMBlockBufferRef createCMBlockBufferForData(CFDataRef);
CF_RETURNS_RETAINED CFArrayRef createPixelFormatsWithAlphaPlaneArray();
CF_RETURNS_NOT_RETAINED CFStringRef pixelBufferPreferRealTimeCacheModeKey();
#if ENABLE(VP9)
bool vpxFrameIsKeyframe(uint32_t codec, CFDataRef frameData);
#endif
// The WebM alpha merge's pool, null with the status set where it fails, and its merged buffer, null where that fails.
CF_RETURNS_RETAINED CVPixelBufferPoolRef createMergedPixelBufferPool(size_t width, size_t height, OSType, CVReturn&);
CF_RETURNS_RETAINED CVPixelBufferRef createMergedPixelBuffer(CVPixelBufferRef color, CVPixelBufferRef alpha, CVPixelBufferPoolRef);
WEBCORE_EXPORT bool isCMSampleBufferRandomAccess(CMSampleBufferRef);

// CMUtilities.h's, for Swift, which takes an unannotated CFStringRef as unmanaged.
WEBCORE_EXPORT CF_RETURNS_NOT_RETAINED CFStringRef convertToCMColorPrimaries(PlatformVideoColorPrimaries);
WEBCORE_EXPORT CF_RETURNS_NOT_RETAINED CFStringRef convertToCMTransferFunction(PlatformVideoTransferCharacteristics);
WEBCORE_EXPORT CF_RETURNS_NOT_RETAINED CFStringRef convertToCMYCbCRMatrix(PlatformVideoMatrixCoefficients);

// audioStreamDescriptionFromAudioInfo()'s description.
AudioStreamBasicDescription audioStreamBasicDescriptionFromAudioInfo(const AudioInfo&);

// createFormatDescriptionFromTrackInfo()'s info, as Swift takes no pointer to a const C++ object.
using ConstTrackInfoRefPtr = RefPtr<const TrackInfo>;
using ConstAudioInfoRefPtr = RefPtr<const AudioInfo>;
using ConstVideoInfoRefPtr = RefPtr<const VideoInfo>;

#if PLATFORM(VISION)
void addImmersiveVideoMetadataExtensions(CFMutableDictionaryRef, const VideoInfo&);
CF_RETURNS_RETAINED CFDictionaryRef copyImmersiveVideoMetadata(CMFormatDescriptionRef);
#endif

}
