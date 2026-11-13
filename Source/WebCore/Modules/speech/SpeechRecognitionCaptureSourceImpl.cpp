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
#include "SpeechRecognitionCaptureSourceImpl.h"

#if ENABLE(MEDIA_STREAM)

#include "SpeechRecognitionUpdate.h"
#include <wtf/CryptographicallyRandomNumber.h>
#include <wtf/TZoneMallocInlines.h>

#if PLATFORM(COCOA)
#include "CAAudioStreamDescription.h"
#include "WebAudioBufferList.h"
#endif

namespace WebCore {

#if !RELEASE_LOG_DISABLED
static uint64_t nextLogIdentifier()
{
    static uint64_t logIdentifier = cryptographicallyRandomNumber<uint32_t>();
    return ++logIdentifier;
}

NODELETE static RefPtr<Logger>& nullLogger()
{
    static NeverDestroyed<RefPtr<Logger>> logger;
    return logger;
}
#endif

WTF_MAKE_TZONE_ALLOCATED_IMPL(SpeechRecognitionCaptureSourceImpl);

SpeechRecognitionCaptureSourceImpl::SpeechRecognitionCaptureSourceImpl(SpeechRecognitionConnectionClientIdentifier identifier, DataCallback&& dataCallback, StateUpdateCallback&& stateUpdateCallback, Ref<RealtimeMediaSource>&& source)
    : m_clientIdentifier(identifier)
    , m_dataCallback(WTF::move(dataCallback))
    , m_stateUpdateCallback(WTF::move(stateUpdateCallback))
    , m_source(WTF::move(source))
{
#if !RELEASE_LOG_DISABLED
    if (!nullLogger().get()) {
        nullLogger() = Logger::create(this);
        nullLogger()->setEnabled(this, false);
    }

    m_source->setLogger(protect(*nullLogger()).get(), nextLogIdentifier());
#endif

    m_source->addAudioSampleObserver(*this);
    m_source->addObserver(*this);
    m_source->start();

    initializeWeakPtrFactory();
}

SpeechRecognitionCaptureSourceImpl::~SpeechRecognitionCaptureSourceImpl()
{
    m_source->removeAudioSampleObserver(*this);
    m_source->removeObserver(*this);
    m_source->stop();
}

void SpeechRecognitionCaptureSourceImpl::audioSamplesAvailable(const WTF::MediaTime& time, const PlatformAudioData& data, const AudioStreamDescription& description, size_t sampleCount)
{
    if (isMainThread())
        return m_dataCallback(time, data, description, sampleCount);

#if PLATFORM(COCOA)
    // Heap allocations are forbidden on the audio thread for performance reasons so we need to
    // explicitly allow the following allocation(s).
    DisableMallocRestrictionsForCurrentThreadScope scope;
    ASSERT(description.platformDescription().type == PlatformDescription::CAAudioStreamBasicType);
    auto audioDescription = toCAAudioStreamDescription(description);
    auto& source = downcast<WebAudioBufferList>(data);
    auto copy = makeUnique<WebAudioBufferList>(audioDescription, sampleCount);
    for (uint32_t index = 0; index < copy->bufferCount(); ++index) {
        auto destination = copy->bufferAsSpan(index);
        auto samples = index < source.bufferCount() ? source.bufferAsSpan(index) : std::span<uint8_t> { };
        auto copiedSize = std::min(destination.size(), samples.size());
        memcpySpan(destination, samples.first(copiedSize));
        zeroSpan(destination.subspan(copiedSize));
    }
    callOnMainThread([weakThis = WeakPtr { *this }, copy = WTF::move(copy), time, audioDescription, sampleCount] {
        if (CheckedPtr checkedThis = weakThis.get())
            checkedThis->m_dataCallback(time, *copy, audioDescription, sampleCount);
    });
#endif
}

void SpeechRecognitionCaptureSourceImpl::sourceStarted()
{
    ASSERT(isMainThread());
    m_stateUpdateCallback(SpeechRecognitionUpdate::create(m_clientIdentifier, SpeechRecognitionUpdateType::AudioStart));
}

void SpeechRecognitionCaptureSourceImpl::sourceStopped()
{
    ASSERT(isMainThread());
    ASSERT(m_source->captureDidFail());
    m_stateUpdateCallback(SpeechRecognitionUpdate::createError(m_clientIdentifier, SpeechRecognitionError { SpeechRecognitionErrorType::AudioCapture, "Source is stopped"_s }));
}

void SpeechRecognitionCaptureSourceImpl::sourceMutedChanged()
{
    ASSERT(isMainThread());
    m_stateUpdateCallback(SpeechRecognitionUpdate::createError(m_clientIdentifier, SpeechRecognitionError { SpeechRecognitionErrorType::AudioCapture, "Source is muted"_s }));
}

void SpeechRecognitionCaptureSourceImpl::mute()
{
    m_source->setMuted(true);
}

} // namespace WebCore

#endif
