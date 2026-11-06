/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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
#include "SpeechRecognitionRemoteRealtimeMediaSource.h"

#if ENABLE(MEDIA_STREAM)

#include "MessageSenderInlines.h"
#include "SpeechRecognitionRealtimeMediaSourceManagerMessages.h"
#include "SpeechRecognitionRemoteRealtimeMediaSourceManager.h"

#if PLATFORM(COCOA)
#include "SharedCARingBuffer.h"
#include <WebCore/CARingBuffer.h>
#include <WebCore/WebAudioBufferList.h>
#endif

namespace WebKit {

Ref<WebCore::RealtimeMediaSource> SpeechRecognitionRemoteRealtimeMediaSource::create(SpeechRecognitionRemoteRealtimeMediaSourceManager& manager, const WebCore::CaptureDevice& captureDevice, WebCore::PageIdentifier pageIdentifier, WebCore::SpeechRecognitionConnectionClientIdentifier clientIdentifier)
{
    return adoptRef(*new SpeechRecognitionRemoteRealtimeMediaSource(WebCore::RealtimeMediaSourceIdentifier::generate(), manager, captureDevice, pageIdentifier, clientIdentifier));
}

SpeechRecognitionRemoteRealtimeMediaSource::SpeechRecognitionRemoteRealtimeMediaSource(WebCore::RealtimeMediaSourceIdentifier identifier, SpeechRecognitionRemoteRealtimeMediaSourceManager& manager, const WebCore::CaptureDevice& captureDevice, WebCore::PageIdentifier pageIdentifier, WebCore::SpeechRecognitionConnectionClientIdentifier clientIdentifier)
    : WebCore::RealtimeMediaSource(captureDevice, { }, pageIdentifier)
    , m_identifier(identifier)
    , m_clientIdentifier(clientIdentifier)
    , m_manager(manager)
#if PLATFORM(COCOA)
    , m_queue(WorkQueue::create("SpeechRecognitionRemoteRealtimeMediaSource"_s))
#endif
{
    manager.addSource(*this, captureDevice);
}

SpeechRecognitionRemoteRealtimeMediaSource::~SpeechRecognitionRemoteRealtimeMediaSource()
{
    if (RefPtr manager = m_manager.get())
        manager->removeSource(*this);
}

void SpeechRecognitionRemoteRealtimeMediaSource::startProducingData()
{
    if (RefPtr manager = m_manager.get())
        manager->send(Messages::SpeechRecognitionRealtimeMediaSourceManager::Start { m_identifier });
}

void SpeechRecognitionRemoteRealtimeMediaSource::stopProducingData()
{
    if (RefPtr manager = m_manager.get())
        manager->send(Messages::SpeechRecognitionRealtimeMediaSourceManager::Stop { m_identifier });
}

#if PLATFORM(COCOA)

void SpeechRecognitionRemoteRealtimeMediaSource::setStorage(ConsumerSharedCARingBuffer::Handle&& handle, const WebCore::CAAudioStreamDescription& description)
{
    auto ringBuffer = ConsumerSharedCARingBuffer::map(description, WTF::move(handle));
    m_frameCount = ringBuffer ? std::optional { ringBuffer->frameCount() } : std::nullopt;
    m_queue->dispatch([protectedThis = Ref { *this }, ringBuffer = WTF::move(ringBuffer), description] mutable {
        protectedThis->m_buffer = nullptr;
        protectedThis->m_ringBuffer = WTF::move(ringBuffer);
        if (!protectedThis->m_ringBuffer)
            return;
        protectedThis->m_description = description;
        protectedThis->m_buffer = makeUnique<WebCore::WebAudioBufferList>(description);
    });
}

void SpeechRecognitionRemoteRealtimeMediaSource::fetchAndDeliverSamples(MediaTime time, uint64_t numberOfFrames)
{
    assertIsCurrent(m_queue.get());
    if (!m_buffer)
        return;

    m_buffer->setSampleCount(numberOfFrames);
    m_ringBuffer->fetch(m_buffer->list(), numberOfFrames, time.timeValue());
    audioSamplesAvailable(time, *m_buffer, *m_description, numberOfFrames);
}

#endif

std::optional<uint32_t> SpeechRecognitionRemoteRealtimeMediaSource::audioBufferFrameCount() const
{
#if PLATFORM(COCOA)
    return m_frameCount;
#else
    return std::nullopt;
#endif
}

void SpeechRecognitionRemoteRealtimeMediaSource::remoteAudioSamplesAvailable(MediaTime time, uint64_t numberOfFrames)
{
#if PLATFORM(COCOA)
    if (!m_frameCount) {
        LOG_ERROR("Buffer for remote source is null");
        captureFailed();
        return;
    }

    // Fetched off the main thread; SpeechRecognitionCaptureSourceImpl hands the main thread a copy.
    m_queue->dispatch([protectedThis = Ref { *this }, time, numberOfFrames] {
        protectedThis->fetchAndDeliverSamples(time, numberOfFrames);
    });
#else
    UNUSED_PARAM(time);
    UNUSED_PARAM(numberOfFrames);
#endif
}

void SpeechRecognitionRemoteRealtimeMediaSource::remoteCaptureFailed()
{
    captureFailed();
}

void SpeechRecognitionRemoteRealtimeMediaSource::remoteSourceStopped()
{
    stop();
}

} // namespace WebKit

#endif
