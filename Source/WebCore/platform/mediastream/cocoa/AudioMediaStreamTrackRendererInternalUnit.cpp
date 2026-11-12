/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#include "AudioMediaStreamTrackRendererInternalUnit.h"

#if ENABLE(MEDIA_STREAM)

#include "AudioMediaStreamTrackRenderer.h"
#include "AudioOutputUnit.h"
#include "AudioSampleDataSource.h"
#include "AudioSession.h"
#include "CAAudioStreamDescription.h"
#include "Logging.h"
#include <pal/cf/CoreAudioExtras.h>
#include <pal/spi/cocoa/AudioToolboxSPI.h>
#include <wtf/Lock.h>
#include <wtf/RefCounted.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>

#include <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

// An in-process track renderer's unit (AudioOutputUnit.swift's TrackRendererUnit), which renders the client's audio.
class LocalAudioMediaStreamTrackRendererInternalUnit final : public AudioMediaStreamTrackRendererInternalUnit, public RefCounted<LocalAudioMediaStreamTrackRendererInternalUnit>  {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(LocalAudioMediaStreamTrackRendererInternalUnit);
public:
    static Ref<AudioMediaStreamTrackRendererInternalUnit> create(const String& deviceID, Client& client)
    {
        auto unit = adoptRef(*new LocalAudioMediaStreamTrackRendererInternalUnit(client));
        unit->setAudioOutputDevice(deviceID);
        return unit;
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    explicit LocalAudioMediaStreamTrackRendererInternalUnit(Client&);

    // AudioMediaStreamTrackRendererInternalUnit API.
    void start() final { m_unit.start(); }
    void stop() final { m_unit.stop(); }
    void retrieveFormatDescription(CompletionHandler<void(std::optional<CAAudioStreamDescription>)>&&) final;
    void setAudioOutputDevice(const String&);

    // The unit's render callback, which AudioOutputUnit.swift calls between its timeline check and its clipping.
    static OSStatus renderClient(void*, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32 inBusNumber, UInt32 sampleCount, AudioBufferList*);

    ThreadSafeWeakPtr<Client> m_client;
    AudioTrackRendererUnit m_unit;
};

LocalAudioMediaStreamTrackRendererInternalUnit::LocalAudioMediaStreamTrackRendererInternalUnit(Client& client)
    : m_client(client)
    , m_unit(renderClient, this)
{
    m_unit.setEventHandler([this](OptionSet<AudioOutputUnit::Event> events) {
        if (!events.contains(AudioOutputUnit::Event::TimelineDiscontinuity))
            return;
        if (RefPtr client = m_client.get())
            client->reset();
    });
}

void LocalAudioMediaStreamTrackRendererInternalUnit::retrieveFormatDescription(CompletionHandler<void(std::optional<CAAudioStreamDescription>)>&& callback)
{
    auto format = m_unit.format();
    if (!format) {
        callback(std::nullopt);
        return;
    }
    callback(CAAudioStreamDescription { *format });
}

void LocalAudioMediaStreamTrackRendererInternalUnit::setAudioOutputDevice(const String& deviceID)
{
    m_unit.setDevice(deviceID);
}

OSStatus LocalAudioMediaStreamTrackRendererInternalUnit::renderClient(void* processor, AudioUnitRenderActionFlags* actionFlags, const AudioTimeStamp* timeStamp, UInt32, UInt32 sampleCount, AudioBufferList* ioData)
{
    RefPtr client = static_cast<LocalAudioMediaStreamTrackRendererInternalUnit*>(processor)->m_client.get();
    if (!client)
        return kAudio_ParamError;
    return client->render(sampleCount, *ioData, timeStamp->mSampleTime, timeStamp->mHostTime, *actionFlags);
}

static auto createInternalUnit = LocalAudioMediaStreamTrackRendererInternalUnit::create;

void AudioMediaStreamTrackRendererInternalUnit::setCreateFunction(CreateFunction function)
{
    ASSERT(function);
    createInternalUnit = function;
}

Ref<AudioMediaStreamTrackRendererInternalUnit> AudioMediaStreamTrackRendererInternalUnit::create(const String& deviceID, Client& client)
{
    return createInternalUnit(deviceID, client);
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM)
