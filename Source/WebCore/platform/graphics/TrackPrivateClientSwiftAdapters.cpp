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

#include "config.h"
#include "AudioTrackPrivate.h"
#include "InbandTextTrackPrivate.h"
#include "VideoTrackPrivate.h"

#if ENABLE(VIDEO) && PLATFORM(COCOA) && ENABLE(WEBCORE_SWIFT)

#include <wtf/MainThread.h>

namespace WebCore {

static auto mainThreadDispatcher()
{
    return [](TrackPrivateBaseClient::Task&& task) {
        ensureOnMainThread(WTF::move(task));
    };
}

SwiftAudioTrackPrivateClientAdapter* SwiftAudioTrackPrivateClientAdapter::create(AudioTrackPrivate& track, uintptr_t delegateBox)
{
    return &adoptRef(*new SwiftAudioTrackPrivateClientAdapter(track, delegateBox)).leakRef();
}

SwiftAudioTrackPrivateClientAdapter::SwiftAudioTrackPrivateClientAdapter(AudioTrackPrivate& track, uintptr_t delegateBox)
    : m_track(track)
    , m_delegateBox(delegateBox)
{
    m_clientIndex = track.addClient(mainThreadDispatcher(), *this);
}

SwiftAudioTrackPrivateClientAdapter::~SwiftAudioTrackPrivateClientAdapter()
{
    m_track->removeClient(m_clientIndex);
    releaseDelegateBox(m_delegateBox);
}

SwiftVideoTrackPrivateClientAdapter* SwiftVideoTrackPrivateClientAdapter::create(VideoTrackPrivate& track, uintptr_t delegateBox)
{
    return &adoptRef(*new SwiftVideoTrackPrivateClientAdapter(track, delegateBox)).leakRef();
}

SwiftVideoTrackPrivateClientAdapter::SwiftVideoTrackPrivateClientAdapter(VideoTrackPrivate& track, uintptr_t delegateBox)
    : m_track(track)
    , m_delegateBox(delegateBox)
{
    m_clientIndex = track.addClient(mainThreadDispatcher(), *this);
}

SwiftVideoTrackPrivateClientAdapter::~SwiftVideoTrackPrivateClientAdapter()
{
    m_track->removeClient(m_clientIndex);
    releaseDelegateBox(m_delegateBox);
}

SwiftInbandTextTrackPrivateClientAdapter* SwiftInbandTextTrackPrivateClientAdapter::create(InbandTextTrackPrivate& track, uintptr_t delegateBox)
{
    return &adoptRef(*new SwiftInbandTextTrackPrivateClientAdapter(track, delegateBox)).leakRef();
}

SwiftInbandTextTrackPrivateClientAdapter::SwiftInbandTextTrackPrivateClientAdapter(InbandTextTrackPrivate& track, uintptr_t delegateBox)
    : m_track(track)
    , m_delegateBox(delegateBox)
{
    m_clientIndex = track.addClient(mainThreadDispatcher(), *this);
}

SwiftInbandTextTrackPrivateClientAdapter::~SwiftInbandTextTrackPrivateClientAdapter()
{
    m_track->removeClient(m_clientIndex);
    releaseDelegateBox(m_delegateBox);
}

void SwiftInbandTextTrackPrivateClientAdapter::addDataCue(const MediaTime& start, const MediaTime& end, std::span<const uint8_t> data)
{
    swiftAddDataCue(start, end, SharedBuffer::create(data));
}

#if ENABLE(DATACUE_VALUE)
void SwiftInbandTextTrackPrivateClientAdapter::addDataCue(const MediaTime& start, const MediaTime& end, Ref<SerializedPlatformDataCue>&& cue, const String& type)
{
    swiftAddDataCueWithType(start, end, cue, type);
}

void SwiftInbandTextTrackPrivateClientAdapter::updateDataCue(const MediaTime& start, const MediaTime& end, SerializedPlatformDataCue& cue)
{
    swiftUpdateDataCue(start, end, cue);
}

void SwiftInbandTextTrackPrivateClientAdapter::removeDataCue(const MediaTime& start, const MediaTime& end, SerializedPlatformDataCue& cue)
{
    swiftRemoveDataCue(start, end, cue);
}
#endif

void SwiftInbandTextTrackPrivateClientAdapter::parseWebVTTFileHeader(String&& header)
{
    swiftParseWebVTTFileHeader(WTF::move(header));
}

void SwiftInbandTextTrackPrivateClientAdapter::parseWebVTTCueData(std::span<const uint8_t> data)
{
    swiftParseWebVTTCueData(SharedBuffer::create(data));
}

void SwiftInbandTextTrackPrivateClientAdapter::parseWebVTTCueData(ISOWebVTTCue&& cue)
{
    swiftParseWebVTTCue(WTF::move(cue));
}

} // namespace WebCore

#endif // ENABLE(VIDEO) && PLATFORM(COCOA) && ENABLE(WEBCORE_SWIFT)
