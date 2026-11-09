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
#include "CoreAudioCaptureDevice.h"
#include "CoreAudioCaptureDeviceManager.h"
#include "Logging.h"
#include <pal/cf/CoreAudioExtras.h>
#include <pal/spi/cocoa/AudioToolboxSPI.h>
#include <wtf/Lock.h>
#include <wtf/RefCounted.h>
#include <wtf/Scope.h>
#include <wtf/TZoneMallocInlines.h>

#include <pal/cf/CoreMediaSoftLink.h>

namespace WebCore {

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
    void createAudioUnitIfNeeded();

    // AudioMediaStreamTrackRendererInternalUnit API.
    void start() final;
    void stop() final;
    void retrieveFormatDescription(CompletionHandler<void(std::optional<CAAudioStreamDescription>)>&&) final;
    void setTrackPlayout(const AudioTrackPlayout& track) final { m_trackPlayout = &track; }
    void setAudioOutputDevice(const String&);

    // An in-process unit's render callback, which AudioOutputUnit.swift calls between its timeline check and its clipping.
    static OSStatus renderClient(void*, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32 inBusNumber, UInt32 sampleCount, AudioBufferList*);

    ThreadSafeWeakPtr<Client> m_client;
    std::optional<CAAudioStreamDescription> m_outputDescription;
    std::unique_ptr<AudioOutputUnit> m_unit;
    const AudioTrackPlayout* m_trackPlayout { nullptr };
    bool m_isStarted { false };
#if PLATFORM(MAC)
    uint32_t m_deviceID { 0 };
#endif
    String m_audioOutputDeviceID;
};


LocalAudioMediaStreamTrackRendererInternalUnit::LocalAudioMediaStreamTrackRendererInternalUnit(Client& client)
    : m_client(client)
{
}

void LocalAudioMediaStreamTrackRendererInternalUnit::retrieveFormatDescription(CompletionHandler<void(std::optional<CAAudioStreamDescription>)>&& callback)
{
    createAudioUnitIfNeeded();
    callback(m_outputDescription);
}

void LocalAudioMediaStreamTrackRendererInternalUnit::setAudioOutputDevice(const String& deviceID)
{
#if PLATFORM(MAC)
    if (deviceID == AudioMediaStreamTrackRenderer::defaultDeviceID())
        return;

    auto device = CoreAudioCaptureDeviceManager::singleton().coreAudioDeviceWithUID(deviceID);

    if (!device && !deviceID.isEmpty()) {
        RELEASE_LOG(WebRTC, "AudioMediaStreamTrackRendererInternalUnit::setAudioOutputDeviceId - did not find device");
        return;
    }

    m_audioOutputDeviceID = deviceID;

    auto audioUnitDeviceID = device ? device->deviceID() : 0;
    if (m_deviceID == audioUnitDeviceID)
        return;

    bool shouldRestart = m_isStarted;
    if (m_isStarted)
        stop();

    m_deviceID = audioUnitDeviceID;

    if (shouldRestart)
        start();
#else
    UNUSED_PARAM(deviceID);
#endif
}

void LocalAudioMediaStreamTrackRendererInternalUnit::start()
{
    RELEASE_LOG_INFO(WebRTC, "LocalAudioMediaStreamTrackRendererInternalUnit::start");
    if (m_isStarted)
        return;

    createAudioUnitIfNeeded();
    if (!m_unit)
        return;

    if (auto error = m_unit->start()) {
        RELEASE_LOG_ERROR(WebRTC, "AudioMediaStreamTrackRendererInternalUnit::start AudioOutputUnitStart failed, error = %d", error);
        m_unit = nullptr;
        return;
    }
    m_isStarted = true;
    RELEASE_LOG(WebRTC, "AudioMediaStreamTrackRendererInternalUnit is started");
}

void LocalAudioMediaStreamTrackRendererInternalUnit::stop()
{
    RELEASE_LOG_INFO(WebRTC, "LocalAudioMediaStreamTrackRendererInternalUnit::stop");
    if (!m_unit)
        return;

    if (m_isStarted) {
        m_unit->stop();
        m_isStarted = false;
    }

    m_unit = nullptr;
}

void LocalAudioMediaStreamTrackRendererInternalUnit::createAudioUnitIfNeeded()
{
    ASSERT(!m_unit || m_outputDescription);
    if (m_unit)
        return;

    uint32_t deviceID = 0;
#if PLATFORM(MAC)
    deviceID = m_deviceID;
#endif
    std::optional<AudioStreamBasicDescription> format;
    if (m_outputDescription)
        format = m_outputDescription->streamDescription();
    auto renderer = AudioOutputUnit::createTrackRenderer(deviceID, AudioSession::singleton().sampleRate(), format, !!m_trackPlayout);
    if (!renderer.unit) {
        static constexpr std::array<ASCIILiteral, 9> steps { ""_s, "unable to find remote IO unit component"_s, "unable to open vpio unit"_s, "unable to enable vpio unit output"_s, "unable to set unit device ID"_s, "unable to set vpio unit speaker proc"_s, "unable to get input stream format"_s, "unable to set input stream format"_s, "AudioUnitInitialize() failed"_s };
        RELEASE_LOG_ERROR(WebRTC, "AudioMediaStreamTrackRendererInternalUnit::createAudioUnit %" PUBLIC_LOG_STRING ", error = %d", steps[std::min<size_t>(renderer.failedStep, steps.size() - 1)].characters(), static_cast<int>(renderer.status));
        return;
    }

    if (!m_outputDescription)
        m_outputDescription = renderer.format;
    if (m_trackPlayout)
        renderer.unit->attachTrackPlayout(*m_trackPlayout);
    else
        renderer.unit->attachRenderCallback(renderClient, this);
    renderer.unit->setEventHandler([this](OptionSet<AudioOutputUnit::Event> events) {
        if (!events.contains(AudioOutputUnit::Event::TimelineDiscontinuity))
            return;
        if (RefPtr client = m_client.get())
            client->reset();
    });
    m_unit = WTF::move(renderer.unit);
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
