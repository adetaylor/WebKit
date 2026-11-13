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

#ifndef AVTrackPrivateAVFObjCImpl_h
#define AVTrackPrivateAVFObjCImpl_h

#if ENABLE(VIDEO)

#include "AudioTrackPrivate.h"
#include "InbandTextTrackPrivate.h"
#include "MediaSelectionGroupAVFObjC.h"
#include "VideoTrackPrivate.h"
#include <wtf/Observer.h>
#include <wtf/Ref.h>
#include <wtf/RetainPtr.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

OBJC_CLASS AVAssetTrack;
OBJC_CLASS AVPlayerItem;
OBJC_CLASS AVPlayerItemTrack;
OBJC_CLASS AVMediaSelectionGroup;
OBJC_CLASS AVMediaSelectionOption;

typedef const struct opaqueCMFormatDescription* CMFormatDescriptionRef;

namespace WebCore {

struct PlatformVideoTrackConfiguration;
struct PlatformAudioTrackConfiguration;

// What AVTrackPrivateAVFObjCImpl.swift reads of a track from AVFoundation in one go.
struct AVTrackSwiftProperties {
    bool enabled { false };
    int index { 0 };
    TrackID id { 0 };
    AudioTrackPrivate::Kind audioKind { AudioTrackPrivate::Kind::None };
    VideoTrackPrivate::Kind videoKind { VideoTrackPrivate::Kind::None };
    String label;

    // The asset track's format: zero until AVFoundation has loaded it.
    uint32_t width { 0 };
    uint32_t height { 0 };
    double framerate { 0 };
    uint64_t bitrate { 0 };
    // The asset track's first format description once loaded, as the address of a +1 reference that
    // AVTrackPrivateAVFObjCImpl::properties() adopts.
    uintptr_t retainedFormatDescription { 0 };
};

// A track's properties, for the track privates to cache.
struct AVTrackProperties : AVTrackSwiftProperties {
    InbandTextTrackPrivate::Kind textKind { InbandTextTrackPrivate::Kind::None };
    String language;
    RetainPtr<CMFormatDescriptionRef> formatDescription;

    PlatformVideoTrackConfiguration videoTrackConfiguration() const;
    PlatformAudioTrackConfiguration audioTrackConfiguration() const;
};

// The AVFoundation side of a track private. AVTrackPrivateAVFObjCImpl.swift implements the members this doesn't define.
class SWIFT_PRIVATE_FILEID("WebCore/AVTrackPrivateAVFObjCImpl.swift") AVTrackPrivateAVFObjCImpl final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<AVTrackPrivateAVFObjCImpl, WTF::DestructionThread::Main> {
    WTF_MAKE_TZONE_ALLOCATED(AVTrackPrivateAVFObjCImpl);
public:
    static Ref<AVTrackPrivateAVFObjCImpl> create(AVPlayerItemTrack* track) { return adoptRef(*new AVTrackPrivateAVFObjCImpl(track)); }
    static Ref<AVTrackPrivateAVFObjCImpl> create(AVAssetTrack* track) { return adoptRef(*new AVTrackPrivateAVFObjCImpl(track)); }
    static Ref<AVTrackPrivateAVFObjCImpl> create(MediaSelectionOptionAVFObjC& option) { return adoptRef(*new AVTrackPrivateAVFObjCImpl(option)); }
    ~AVTrackPrivateAVFObjCImpl();

    AVPlayerItemTrack* playerItemTrack() const { return m_playerItemTrack.get(); }
    AVAssetTrack* assetTrack() const { return m_assetTrack.get(); }
    MediaSelectionOptionAVFObjC* mediaSelectionOption() const { return m_mediaSelectionOption.get(); }

    AVTrackProperties properties() const;
    void setEnabled(bool);

    static InbandTextTrackPrivate::Kind textKindForAVAssetTrack(const AVAssetTrack *);
    static InbandTextTrackPrivate::Kind textKindForAVMediaSelectionOption(const AVMediaSelectionOption *);

    static String languageForAVAssetTrack(const AVAssetTrack *);
    static String languageForAVMediaSelectionOption(const AVMediaSelectionOption *);

    using VideoTrackConfigurationObserver = Observer<void()>;
    NODELETE void setVideoTrackConfigurationObserver(VideoTrackConfigurationObserver&);

    using AudioTrackConfigurationObserver = Observer<void()>;
    NODELETE void setAudioTrackConfigurationObserver(AudioTrackConfigurationObserver&);

private:
    AVTrackPrivateAVFObjCImpl(AVPlayerItemTrack*);
    AVTrackPrivateAVFObjCImpl(AVAssetTrack*);
    AVTrackPrivateAVFObjCImpl(MediaSelectionOptionAVFObjC&);

    void initializeAssetTrack();
    void initializationCompleted();

    AVTrackSwiftProperties readProperties() const;

    const RetainPtr<AVPlayerItemTrack> m_playerItemTrack;
    const RefPtr<MediaSelectionOptionAVFObjC> m_mediaSelectionOption;
    const RetainPtr<AVMediaSelectionOption> m_avMediaSelectionOption;
    const RetainPtr<AVAssetTrack> m_assetTrack;
    WeakPtr<VideoTrackConfigurationObserver> m_videoTrackConfigurationObserver;
    WeakPtr<AudioTrackConfigurationObserver> m_audioTrackConfigurationObserver;
};

}

#endif // ENABLE(VIDEO)

#endif
