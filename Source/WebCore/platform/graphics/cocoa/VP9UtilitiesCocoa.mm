/*
 * Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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
#import "VP9UtilitiesCocoaInternal.h"

#if ENABLE(VP9) && PLATFORM(COCOA)

#if USE(LIBWEBRTC)
#import "LibWebRTCProvider.h"
#endif
#import "Logging.h"
#import "MediaParsersShellSupport.h"
#import "MediaStrategy.h"
#import "PlatformMediaCapabilitiesInfo.h"
#import "PlatformMediaCapabilitiesVideoConfiguration.h"
#import "PlatformScreen.h"
#import "PlatformStrategies.h"
#import "ScreenProperties.h"
#import "SystemBattery.h"
#import "TrackInfo.h"
#import "VideoCodecParameterTypes.h"
#import "VideoDecoder.h"
#import <webm/common/vp9_header_parser.h>

#if ENABLE(WEBCORE_SWIFT)
#import "WebCore-Swift.h"
#endif

#import <pal/cocoa/AVFoundationSoftLink.h>
#import <pal/cf/CoreMediaSoftLink.h>
#import "CoreVideoSoftLink.h"
#import "VideoToolboxSoftLink.h"

namespace WebCore {

VP9TestingOverrides& VP9TestingOverrides::singleton()
{
    static NeverDestroyed<VP9TestingOverrides> instance;
    return instance;
}

void VP9TestingOverrides::setHardwareDecoderDisabled(std::optional<bool>&& disabled)
{
    {
        Locker locker { m_hardwareDecoderLock };
        m_hardwareDecoderDisabled = WTF::move(disabled);
    }
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setVP9HardwareDecoderEnabledOverride(std::optional<bool>&& enabled)
{
    {
        Locker locker { m_hardwareDecoderLock };
        m_vp9HardwareDecoderEnabledOverride = WTF::move(enabled);
    }
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setVP9DecoderDisabled(std::optional<bool>&& disabled)
{
    m_vp9DecoderDisabled = WTF::move(disabled);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setSWVPDecodersAlwaysEnabled(bool enabled)
{
    m_swVPDecodersAlwaysEnabled = enabled;
    // We don't call the configurationChangedCallback to prevent unnecessarily starting the GPU process.
}

void VP9TestingOverrides::setVP9ScreenSizeAndScale(std::optional<ScreenDataOverrides>&& overrides)
{
    m_screenSizeAndScale = WTF::move(overrides);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setConfigurationChangedCallback(std::function<void(bool)>&& callback)
{
    m_configurationChangedCallback = WTF::move(callback);
}

void VP9TestingOverrides::resetOverridesToDefaultValues()
{
    setHardwareDecoderDisabled(std::nullopt);
    setVP9DecoderDisabled(std::nullopt);
    setVP9ScreenSizeAndScale(std::nullopt);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(true);
}

void VP9TestingOverrides::setShouldEnableVP9Decoder(bool enabled)
{
    m_vp9DecoderEnabled = enabled;
}

bool VP9TestingOverrides::shouldEnableVP9Decoder() const
{
    return m_vp9DecoderEnabled;
}

enum class ResolutionCategory : uint8_t {
    R_480p,
    R_720p,
    R_1080p,
    R_2K,
    R_4K,
    R_8K,
    R_12K,
};

static ResolutionCategory LEGACY_NODELETE resolutionCategory(const FloatSize& size)
{
    auto pixels = size.area();
    if (pixels > 7680 * 4320)
        return ResolutionCategory::R_12K;
    if (pixels > 4096 * 2160)
        return ResolutionCategory::R_8K;
    if (pixels > 2048 * 1080)
        return ResolutionCategory::R_4K;
    if (pixels > 1920 * 1080)
        return ResolutionCategory::R_2K;
    if (pixels > 1280 * 720)
        return ResolutionCategory::R_1080p;
    if (pixels > 640 * 480)
        return ResolutionCategory::R_720p;
    return ResolutionCategory::R_480p;
}

void registerWebKitVP9Decoder()
{
#if USE(LIBWEBRTC)
    LibWebRTCProvider::registerWebKitVP9Decoder();
#endif
}

static Lock s_vp9HardwareDecoderAvailableInProcessLock;
static std::optional<bool> s_vp9HardwareDecoderAvailableInProcess WTF_GUARDED_BY_LOCK(s_vp9HardwareDecoderAvailableInProcessLock) = { };
void setVP9HardwareDecoderAvailableInProcess(bool value)
{
    Locker locker { s_vp9HardwareDecoderAvailableInProcessLock };
    ASSERT(!s_vp9HardwareDecoderAvailableInProcess || *s_vp9HardwareDecoderAvailableInProcess == value);
    s_vp9HardwareDecoderAvailableInProcess = value;
}

static bool internalVP9HardwareDecoderAvailableInProcess()
{
    Locker locker { s_vp9HardwareDecoderAvailableInProcessLock };
    if (!s_vp9HardwareDecoderAvailableInProcess)
        s_vp9HardwareDecoderAvailableInProcess = canLoad_VideoToolbox_VTIsHardwareDecodeSupported() && VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9);
    return *s_vp9HardwareDecoderAvailableInProcess;
}

void registerSupplementalVP9Decoder()
{
    ASSERT(isMainThread());

    if (!VideoToolboxLibrary(true))
        return;

    if (canLoad_VideoToolbox_VTRegisterSupplementalVideoDecoderIfAvailable())
        softLink_VideoToolbox_VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);

    Locker locker { s_vp9HardwareDecoderAvailableInProcessLock };
    if (s_vp9HardwareDecoderAvailableInProcess && !*s_vp9HardwareDecoderAvailableInProcess)
        s_vp9HardwareDecoderAvailableInProcess = { };
}

static bool LEGACY_NODELETE isSWDecodersAlwaysEnabled()
{
    return VP9TestingOverrides::singleton().swVPDecodersAlwaysEnabled();
}

bool shouldEnableSWVP9Decoder()
{
    return isSWDecodersAlwaysEnabled() || (!vp9HardwareDecoderAvailable() && !systemHasBattery());
}

static bool LEGACY_NODELETE isVP9HardwareDecoderAvailabilityKnown()
{
    return VP9TestingOverrides::singleton().hardwareDecoderDisabled() || VP9TestingOverrides::singleton().vp9HardwareDecoderEnabledOverride();
}

bool isVP9DecoderAvailable()
{
    if (isSWDecodersAlwaysEnabled())
        return true;
#if PLATFORM(IOS) || PLATFORM(VISION)
    return vp9HardwareDecoderAvailable();
#else
    return (shouldEnableSWVP9Decoder() && VideoDecoder::isVPXSupported()) || vp9HardwareDecoderAvailable();
#endif
}

bool isVP8DecoderAvailable()
{
    return VideoDecoder::isVPXSupported();
}

bool vp9HardwareDecoderAvailable()
{
    // If the GPUP hasn't delivered VP9 hardware decoder capability yet,
    // ensure it's initialized and re-check.
    if (!isVP9HardwareDecoderAvailabilityKnown() && hasPlatformStrategies()) {
        RELEASE_LOG_ERROR(Media, "SourceBufferParserWebM::isContentTypeSupported: VP9 availability unknown, ensuring codecs support is initialized");
        platformStrategies()->mediaStrategy()->ensureCodecsSupportChecksInitialized();
    }

    if (auto disabledForTesting = VP9TestingOverrides::singleton().hardwareDecoderDisabled())
        return !*disabledForTesting;

    if (auto vp9HardwareDecoderOverride = VP9TestingOverrides::singleton().vp9HardwareDecoderEnabledOverride())
        return *vp9HardwareDecoderOverride;

    return internalVP9HardwareDecoderAvailableInProcess();
}

bool vp9HardwareDecoderAvailableInProcess()
{
    if (auto disabledForTesting = VP9TestingOverrides::singleton().hardwareDecoderDisabled())
        return !*disabledForTesting;

    return internalVP9HardwareDecoderAvailableInProcess();
}

static bool isVP9CodecConfigurationRecordSupported(const VPCodecConfigurationRecord& codecConfiguration)
{
    if (!isVP9DecoderAvailable())
        return false;

    // HW & SW VP9 Decoders support Profile 0 & 2:
    if (codecConfiguration.profile && codecConfiguration.profile != 2)
        return false;

    // HW & SW VP9 Decoders support only 420 chroma subsampling:
    if (codecConfiguration.chromaSubsampling > VPConfigurationChromaSubsampling::Subsampling_420_Colocated)
        return false;

    // HW & SW VP9 Decoders support 8 or 10 bit color:
    if (codecConfiguration.bitDepth > 10)
        return false;

    // HW & SW VP9 Decoders support up to Level 6:
    if (codecConfiguration.level > VPConfigurationLevel::Level_6)
        return false;

    // Hardware decoders are always available.
    if (vp9HardwareDecoderAvailable() && !isSWDecodersAlwaysEnabled())
        return true;

    // For wall-powered devices, always report VP9 as supported, even if not powerEfficient.
    if (!systemHasBattery())
        return true;

    // For battery-powered devices, always report VP9 as supported when running on AC power,
    // but only on battery when there is an attached screen whose resolution is large enough
    // to support 4K video.
    if (systemHasAC())
        return true;

    bool has4kScreen = false;
    if (auto overrideForTesting = VP9TestingOverrides::singleton().vp9ScreenSizeAndScale()) {
        auto screenSize = FloatSize(overrideForTesting->width, overrideForTesting->height).scaled(overrideForTesting->scale);
        has4kScreen = resolutionCategory(screenSize) >= ResolutionCategory::R_4K;
    } else {
        Ref screen = PlatformScreen::singleton();
        for (auto& screenData : screen->screenDatas().values()) {
            if (resolutionCategory(screenData.screenRect.size().scaled(screenData.scaleFactor)) >= ResolutionCategory::R_4K) {
                has4kScreen = true;
                break;
            }
        }
    }

    return has4kScreen;
}

static bool isVP8CodecConfigurationRecordSupported(const VPCodecConfigurationRecord& codecConfiguration)
{
    if (!isVP8DecoderAvailable())
        return false;

    // VP8 decoder only supports Profile 0;
    if (codecConfiguration.profile)
        return false;

    // VP8 decoder only supports 420 chroma subsampling.
    if (codecConfiguration.chromaSubsampling > VPConfigurationChromaSubsampling::Subsampling_420_Colocated)
        return false;

    // VP8 decoder only supports 8-bit color:
    if (codecConfiguration.bitDepth > 8)
        return false;

    return true;
}

bool isVPCodecConfigurationRecordSupported(const VPCodecConfigurationRecord& codecConfiguration)
{
    if (codecConfiguration.codecName == "vp08"_s || codecConfiguration.codecName == "vp8"_s)
        return isVP8CodecConfigurationRecordSupported(codecConfiguration);

    if (codecConfiguration.codecName == "vp09"_s || codecConfiguration.codecName == "vp9"_s)
        return isVP9CodecConfigurationRecordSupported(codecConfiguration);

    return false;
}

std::optional<PlatformMediaCapabilitiesInfo> validateVPParameters(const VPCodecConfigurationRecord& codecConfiguration, const PlatformMediaCapabilitiesVideoConfiguration& videoConfiguration)
{
    if (!isVPCodecConfigurationRecordSupported(codecConfiguration))
        return std::nullopt;

    // PlatformMediaCapabilitiesVideoConfiguration and VPCodecConfigurationRecord can have conflicting values for HDR properties. If so, reject.
    if (videoConfiguration.transferFunction) {
        // Note: Transfer Characteristics are defined by ISO/IEC 23091-2:2019.
        if (*videoConfiguration.transferFunction == PlatformMediaCapabilitiesTransferFunction::SRGB && codecConfiguration.transferCharacteristics > 15)
            return std::nullopt;
        if (*videoConfiguration.transferFunction == PlatformMediaCapabilitiesTransferFunction::PQ && codecConfiguration.transferCharacteristics != 16)
            return std::nullopt;
        if (*videoConfiguration.transferFunction == PlatformMediaCapabilitiesTransferFunction::HLG && codecConfiguration.transferCharacteristics != 18)
            return std::nullopt;
    }

    if (videoConfiguration.colorGamut) {
        if (*videoConfiguration.colorGamut == PlatformMediaCapabilitiesColorGamut::Rec2020 && codecConfiguration.colorPrimaries != 9)
            return std::nullopt;
    }
    return computeVPParameters(videoConfiguration, vp9HardwareDecoderAvailable());
}

bool isVPSoftwareDecoderSmooth(const PlatformMediaCapabilitiesVideoConfiguration& videoConfiguration)
{
    if (videoConfiguration.height <= 1080 && videoConfiguration.framerate > 60)
        return false;

    if (videoConfiguration.height <= 2160 && videoConfiguration.framerate > 30)
        return false;

    return true;
}

std::optional<PlatformMediaCapabilitiesInfo> computeVPParameters(const PlatformMediaCapabilitiesVideoConfiguration& videoConfiguration, bool vp9HardwareDecoderAvailable)
{
    PlatformMediaCapabilitiesInfo info;

    if (vp9HardwareDecoderAvailable) {
        // HW VP9 Decoder does not support alpha channel:
        if (videoConfiguration.alphaChannel && *videoConfiguration.alphaChannel)
            return std::nullopt;

        // HW VP9 Decoder can support up to 4K @ 120 or 8K @ 30
        auto resolution = resolutionCategory({ (float)videoConfiguration.width, (float)videoConfiguration.height });
        if (resolution > ResolutionCategory::R_8K)
            return std::nullopt;
        if (resolution == ResolutionCategory::R_8K && videoConfiguration.framerate > 30)
            info.smooth = false;
        else if (resolution <= ResolutionCategory::R_4K && videoConfiguration.framerate > 120)
            info.smooth = false;
        else
            info.smooth = true;

        info.powerEfficient = true;
        info.supported = true;
        return info;
    }

    info.powerEfficient = false;

    // SW VP9 Decoder has much more variable capabilities depending on CPU characteristics.
    // FIXME: Add a lookup table for device-to-capabilities. For now, assume that the SW VP9
    // decoder can support 4K @ 30.
    info.smooth = isVPSoftwareDecoderSmooth(videoConfiguration);

    if (isSWDecodersAlwaysEnabled()) {
        info.supported = true;
        return info;
    }

    // For wall-powered devices, always report VP9 as supported, even if not powerEfficient.
    if (!systemHasBattery()) {
        info.supported = true;
        return info;
    }

    // For battery-powered devices, always report VP9 as supported when running on AC power,
    // but only on battery when there is an attached screen whose resolution is large enough
    // to support 4K video.
    if (systemHasAC()) {
        info.supported = true;
        return info;
    }

    bool has4kScreen = false;

    if (auto overrideForTesting = VP9TestingOverrides::singleton().vp9ScreenSizeAndScale()) {
        auto screenSize = FloatSize(overrideForTesting->width, overrideForTesting->height).scaled(overrideForTesting->scale);
        has4kScreen = resolutionCategory(screenSize) >= ResolutionCategory::R_4K;
    } else {
        Ref screen = PlatformScreen::singleton();
        for (auto& screenData : screen->screenDatas().values()) {
            if (resolutionCategory(screenData.screenRect.size().scaled(screenData.scaleFactor)) >= ResolutionCategory::R_4K) {
                has4kScreen = true;
                break;
            }
        }
    }

    if (!has4kScreen)
        return std::nullopt;

    info.supported = true;
    return info;
}

#if ENABLE(WEBCORE_SWIFT)

// The header and colour parsing and the VideoInfo fields are in VP9Utilities.swift.

static WebMVideoFields webMVideoFields(const webm::Video& video)
{
    auto& colour = video.colour.value();
    return {
        .hasColour = video.colour.is_present(),
        .hasChromaSubsamplingX = colour.chroma_subsampling_x.is_present(),
        .hasChromaSubsamplingY = colour.chroma_subsampling_y.is_present(),
        .hasRange = colour.range.is_present(),
        .hasBitsPerChannel = colour.bits_per_channel.is_present(),
        .hasTransferCharacteristics = colour.transfer_characteristics.is_present(),
        .hasMatrixCoefficients = colour.matrix_coefficients.is_present(),
        .hasPrimaries = colour.primaries.is_present(),
        .hasDisplayWidth = video.display_width.is_present(),
        .hasDisplayHeight = video.display_height.is_present(),
        .chromaSubsamplingX = colour.chroma_subsampling_x.value(),
        .chromaSubsamplingY = colour.chroma_subsampling_y.value(),
        .range = static_cast<uint64_t>(colour.range.value()),
        .bitsPerChannel = colour.bits_per_channel.value(),
        .transferCharacteristics = static_cast<uint64_t>(colour.transfer_characteristics.value()),
        .matrixCoefficients = static_cast<uint64_t>(colour.matrix_coefficients.value()),
        .primaries = static_cast<uint64_t>(colour.primaries.value()),
        .displayWidth = video.display_width.value(),
        .displayHeight = video.display_height.value(),
    };
}

Ref<VideoInfo> createVideoInfoFromVP9HeaderParser(const vp9_parser::Vp9HeaderParser& parser, const webm::Video& video)
{
    VP9HeaderFields header {
        .profile = parser.profile(),
        .bitDepth = parser.bit_depth(),
        .colorRange = parser.color_range(),
        .subsamplingX = parser.subsampling_x(),
        .subsamplingY = parser.subsampling_y(),
        .colorSpace = parser.color_space(),
        .width = parser.width(),
        .height = parser.height(),
        .displayWidth = parser.display_width(),
        .displayHeight = parser.display_height(),
    };
    Vector<uint8_t> atom;
    auto result = createVideoInfoFromVP9HeaderParserImpl(header, webMVideoFields(video), atom);
    return makeVideoInfo(result.fields, makeStringFromShortString(result.codecString), WTF::move(atom));
}

std::optional<VP8FrameHeader> parseVP8FrameHeader(std::span<const uint8_t> frameData)
{
    auto result = parseVP8FrameHeaderImpl({ frameData });
    if (!result.parsed)
        return std::nullopt;
    return result.header;
}

Ref<VideoInfo> createVideoInfoFromVP8Header(const VP8FrameHeader& header, const webm::Video& video)
{
    Vector<uint8_t> atom;
    auto result = createVideoInfoFromVP8HeaderImpl(header, webMVideoFields(video), atom);
    return makeVideoInfo(result.fields, makeStringFromShortString(result.codecString), WTF::move(atom));
}

Ref<VideoInfo> createVideoInfoFromVPCodecConfigurationRecord(const VPCodecConfigurationRecord& record, const std::optional<PlatformVideoColorSpace>& colorSpaceOverride)
{
    Vector<uint8_t> atom;
    auto result = createVideoInfoFromVPCodecConfigurationRecordImpl(record.codecName == "vp09"_s, vpCodecFields(record), atom);
    return makeVideoInfo(result.fields, makeString(record.codecName, makeStringFromShortString(result.codecString)), WTF::move(atom), colorSpaceOverride);
}

RefPtr<VideoInfo> createVideoInfoFromVP9Stream(std::span<const uint8_t> data, uint16_t width, uint16_t height)
{
    Vector<uint8_t> atom;
    auto result = createVideoInfoFromVP9StreamImpl({ data }, width, height, atom);
    if (!result.created)
        return nullptr;
    return makeVideoInfo(result.fields, makeStringFromShortString(result.codecString), WTF::move(atom));
}

#endif // ENABLE(WEBCORE_SWIFT)

}

#endif // PLATFORM(COCOA)
