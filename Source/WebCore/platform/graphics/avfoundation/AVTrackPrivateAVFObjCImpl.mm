/*
 * Copyright (C) 2013-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#import "config.h"
#import "AVTrackPrivateAVFObjCImpl.h"

#if ENABLE(VIDEO)

#import "FormatDescriptionUtilities.h"
#import "MediaSelectionGroupAVFObjC.h"
#import "PlatformAudioTrackConfiguration.h"
#import "PlatformVideoTrackConfiguration.h"
#import "FourCC.h"
#import <AVFoundation/AVAssetTrack.h>
#import <AVFoundation/AVMediaSelectionGroup.h>
#import <AVFoundation/AVPlayerItemTrack.h>
#import <wtf/MainThread.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/TZoneMallocInlines.h>

#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AVTrackPrivateAVFObjCImpl);

static NSArray* assetTrackConfigurationKeyNamesSingleton()
{
    static NeverDestroyed<RetainPtr<NSArray>> keys = adoptNS([[NSArray alloc] initWithObjects:@"formatDescriptions", @"estimatedDataRate", @"nominalFrameRate", nil]);
    return keys.get();
}

AVTrackPrivateAVFObjCImpl::AVTrackPrivateAVFObjCImpl(AVPlayerItemTrack* track)
    : m_playerItemTrack(track)
    , m_assetTrack([track assetTrack])
{
    initializeAssetTrack();
}

AVTrackPrivateAVFObjCImpl::AVTrackPrivateAVFObjCImpl(AVAssetTrack* track)
    : m_assetTrack(track)
{
    initializeAssetTrack();
}

AVTrackPrivateAVFObjCImpl::AVTrackPrivateAVFObjCImpl(MediaSelectionOptionAVFObjC& option)
    : m_mediaSelectionOption(&option)
    , m_avMediaSelectionOption(option.avMediaSelectionOption())
    , m_assetTrack(option.assetTrack())
{
    initializeAssetTrack();
}

AVTrackPrivateAVFObjCImpl::~AVTrackPrivateAVFObjCImpl() = default;

void AVTrackPrivateAVFObjCImpl::initializeAssetTrack()
{
    if (!m_assetTrack)
        return;

    [m_assetTrack loadValuesAsynchronouslyForKeys:assetTrackConfigurationKeyNamesSingleton() completionHandler:[weakThis = ThreadSafeWeakPtr { *this }]() mutable {
        callOnMainThread([weakThis = WTF::move(weakThis)] {
            if (RefPtr protectedThis = weakThis.get())
                protectedThis->initializationCompleted();
        });
    }];
}

void AVTrackPrivateAVFObjCImpl::initializationCompleted()
{
    assertIsMainThread();

    if (RefPtr observer = m_audioTrackConfigurationObserver)
        (*observer)();
    if (RefPtr observer = m_videoTrackConfigurationObserver)
        (*observer)();
}

AVTrackProperties AVTrackPrivateAVFObjCImpl::properties() const
{
    AVTrackProperties properties { readProperties(), InbandTextTrackPrivate::Kind::None, { }, { } };
    properties.formatDescription = adoptCF(reinterpret_cast<CMFormatDescriptionRef>(std::exchange(properties.retainedFormatDescription, 0)));

    if (m_assetTrack)
        properties.textKind = textKindForAVAssetTrack(m_assetTrack.get());
    else if (m_mediaSelectionOption)
        properties.textKind = textKindForAVMediaSelectionOption(m_avMediaSelectionOption.get());

    if (m_assetTrack)
        properties.language = languageForAVAssetTrack(m_assetTrack.get());
    if (properties.language.isEmpty() && m_mediaSelectionOption)
        properties.language = languageForAVMediaSelectionOption(m_avMediaSelectionOption.get());
    if (properties.language.isEmpty())
        properties.language = emptyString();

    return properties;
}

InbandTextTrackPrivate::Kind AVTrackPrivateAVFObjCImpl::textKindForAVAssetTrack(const AVAssetTrack *track)
{
    RetainPtr mediaType = [track mediaType];
    if ([mediaType isEqualToString:AVMediaTypeClosedCaption])
        return InbandTextTrackPrivate::Kind::Captions;
    if ([mediaType isEqualToString:AVMediaTypeSubtitle]) {

        if ([track hasMediaCharacteristic:AVMediaCharacteristicContainsOnlyForcedSubtitles])
            return InbandTextTrackPrivate::Kind::Forced;

        // An "SDH" track is a subtitle track created for the deaf or hard-of-hearing. "captions" in WebVTT are
        // "labeled as appropriate for the hard-of-hearing", so tag SDH sutitles as "captions".
        if ([track hasMediaCharacteristic:AVMediaCharacteristicTranscribesSpokenDialogForAccessibility])
            return InbandTextTrackPrivate::Kind::Captions;
        if ([track hasMediaCharacteristic:AVMediaCharacteristicDescribesMusicAndSoundForAccessibility])
            return InbandTextTrackPrivate::Kind::Captions;

        return InbandTextTrackPrivate::Kind::Subtitles;
    }

    RetainPtr formatDescriptions = [track formatDescriptions];
    if ([formatDescriptions count]) {
        FourCC codec = PAL::softLink_CoreMedia_CMFormatDescriptionGetMediaSubType((__bridge CMFormatDescriptionRef)[formatDescriptions objectAtIndex:0]);
        if (codec == kCMSubtitleFormatType_WebVTT)
            return InbandTextTrackPrivate::Kind::Captions;
    }

    return InbandTextTrackPrivate::Kind::Captions;
}

InbandTextTrackPrivate::Kind AVTrackPrivateAVFObjCImpl::textKindForAVMediaSelectionOption(const AVMediaSelectionOption *option)
{
    RetainPtr mediaType = [option mediaType];
    if ([mediaType isEqualToString:AVMediaTypeClosedCaption])
        return InbandTextTrackPrivate::Kind::Captions;
    if ([mediaType isEqualToString:AVMediaTypeSubtitle]) {

        if ([option hasMediaCharacteristic:AVMediaCharacteristicContainsOnlyForcedSubtitles])
            return InbandTextTrackPrivate::Kind::Forced;

        // An "SDH" track is a subtitle track created for the deaf or hard-of-hearing. "captions" in WebVTT are
        // "labeled as appropriate for the hard-of-hearing", so tag SDH sutitles as "captions".
        if ([option hasMediaCharacteristic:AVMediaCharacteristicTranscribesSpokenDialogForAccessibility])
            return InbandTextTrackPrivate::Kind::Captions;
        if ([option hasMediaCharacteristic:AVMediaCharacteristicDescribesMusicAndSoundForAccessibility])
            return InbandTextTrackPrivate::Kind::Captions;

        return InbandTextTrackPrivate::Kind::Subtitles;
    }

    return InbandTextTrackPrivate::Kind::Captions;
}

String AVTrackPrivateAVFObjCImpl::languageForAVAssetTrack(const AVAssetTrack *track)
{
    RetainPtr language = [track extendedLanguageTag];

    // If the language code is stored as a QuickTime 5-bit packed code there aren't enough bits for a full
    // RFC 4646 language tag so extendedLanguageTag returns NULL. In this case languageCode will return the
    // ISO 639-2/T language code so check it.
    if (!language)
        language = [track languageCode];

    // Some legacy tracks have "und" as a language, treat that the same as no language at all.
    if (!language || [language isEqualToString:@"und"])
        return emptyString();

    return language.get();
}

String AVTrackPrivateAVFObjCImpl::languageForAVMediaSelectionOption(const AVMediaSelectionOption *option)
{
    RetainPtr language = [option extendedLanguageTag];

    // If the language code is stored as a QuickTime 5-bit packed code there aren't enough bits for a full
    // RFC 4646 language tag so extendedLanguageTag returns NULL. In this case languageCode will return the
    // ISO 639-2/T language code so check it.
    if (!language)
        language = [[option locale] objectForKey:NSLocaleLanguageCode];

    // Some legacy tracks have "und" as a language, treat that the same as no language at all.
    if (!language || [language isEqualToString:@"und"])
        return emptyString();

    return language.get();
}


PlatformVideoTrackConfiguration AVTrackProperties::videoTrackConfiguration() const
{
    return {
        { codecFromFormatDescription(formatDescription.get()) },
        width,
        height,
        colorSpaceFromFormatDescription(formatDescription.get()).value_or(PlatformVideoColorSpace { }),
        framerate,
        bitrate,
        immersiveVideoMetadataFromFormatDescription(formatDescription.get()),
        formatDescriptionIsProtected(formatDescription.get()),
    };
}

static uint32_t sampleRateFrom(const AudioStreamBasicDescription* streamDescription)
{
    if (!streamDescription || !std::isfinite(streamDescription->mSampleRate) || streamDescription->mSampleRate < 0 || streamDescription->mSampleRate > std::numeric_limits<uint32_t>::max())
        return 0;
    return streamDescription->mSampleRate;
}

PlatformAudioTrackConfiguration AVTrackProperties::audioTrackConfiguration() const
{
    const AudioStreamBasicDescription* streamDescription = formatDescription ? PAL::CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription.get()) : nullptr;
    return {
        { codecFromFormatDescription(formatDescription.get()) },
        sampleRateFrom(streamDescription),
        streamDescription ? streamDescription->mChannelsPerFrame : 0,
        bitrate,
        formatDescriptionIsProtected(formatDescription.get()),
    };
}

void AVTrackPrivateAVFObjCImpl::setVideoTrackConfigurationObserver(VideoTrackConfigurationObserver& observer)
{
    assertIsMainThread();

    m_videoTrackConfigurationObserver = observer;
}

void AVTrackPrivateAVFObjCImpl::setAudioTrackConfigurationObserver(AudioTrackConfigurationObserver& observer)
{
    assertIsMainThread();

    m_audioTrackConfigurationObserver = observer;
}

}

#endif // ENABLE(VIDEO)
