/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
#include "RemoteAudioMediaStreamTrackRendererInternalUnitManager.h"

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "GPUProcessConnectionMessages.h"
#include "Logging.h"
#include "RemoteAudioMediaStreamTrackRendererInternalUnitManagerMessages.h"
#include "RemoteAudioSessionProxy.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/AudioMediaStreamTrackRenderer.h>
#include <WebCore/AudioMediaStreamTrackRendererInternalUnit.h>
#include <WebCore/CAAudioStreamDescription.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteAudioMediaStreamTrackRendererInternalUnitManager);

RemoteAudioMediaStreamTrackRendererInternalUnitManager::RemoteAudioMediaStreamTrackRendererInternalUnitManager(GPUConnectionToWebProcess& gpuConnectionToWebProcess)
    : m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
{
    m_swiftState = createSwiftState();
    WebCore::AudioSession::addInterruptionObserver(*this);
}

RemoteAudioMediaStreamTrackRendererInternalUnitManager::~RemoteAudioMediaStreamTrackRendererInternalUnitManager()
{
    WebCore::AudioSession::removeInterruptionObserver(*this);
    // The units stop rendering before they go.
    destroySwiftState(std::exchange(m_swiftState, 0));
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::ref() const
{
    m_gpuConnectionToWebProcess.get()->ref();
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::deref() const
{
    m_gpuConnectionToWebProcess.get()->deref();
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::createUnit(AudioMediaStreamTrackRendererInternalUnitIdentifier identifier, const String& deviceID, CompletionHandler<void(std::optional<WebCore::CAAudioStreamDescription>, uint64_t)>&& callback)
{
    auto creation = createSwiftUnit(identifier.toUInt64(), WebCore::audioOutputDeviceForTrackRenderer(deviceID), deviceID == WebCore::AudioMediaStreamTrackRenderer::defaultDeviceID());
    if (!creation.hasFormat) {
        RELEASE_LOG(WebRTC, "RemoteAudioMediaStreamTrackRendererInternalUnitManagerUnit unable to get format description");
        callback(std::nullopt, 0);
        return;
    }
    callback(WebCore::CAAudioStreamDescription { creation.format }, creation.frameChunkSize);
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::setLastDeviceUsed(const String& deviceID)
{
#if PLATFORM(IOS_FAMILY) && USE(AUDIO_SESSION)
    RefPtr connection = m_gpuConnectionToWebProcess.get();
    Ref audioSession = connection->audioSessionProxy();
    audioSession->setPreferredSpeakerID(deviceID != WebCore::AudioMediaStreamTrackRenderer::defaultDeviceID() ? deviceID : emptyString());
#else
    UNUSED_PARAM(deviceID);
#endif
}

std::optional<SharedPreferencesForWebProcess> RemoteAudioMediaStreamTrackRendererInternalUnitManager::sharedPreferencesForWebProcess() const
{
    if (RefPtr gpuConnectionToWebProcess = m_gpuConnectionToWebProcess.get())
        return gpuConnectionToWebProcess->sharedPreferencesForWebProcess();

    return std::nullopt;
}

bool RemoteAudioMediaStreamTrackRendererInternalUnitManager::isLastToCaptureAudio() const
{
    RefPtr connection = m_gpuConnectionToWebProcess.get();
    return connection && connection->isLastToCaptureAudio();
}

bool RemoteAudioMediaStreamTrackRendererInternalUnitManager::isAudioSessionInterrupted() const
{
    return WebCore::AudioSession::singleton().isInterrupted();
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::tryExitIfUnusedAndUnderMemoryPressure()
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        connection->gpuProcess().tryExitIfUnusedAndUnderMemoryPressure();
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::resetUnit(uint64_t identifier)
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        connection->connection().send(Messages::GPUProcessConnection::ResetAudioMediaStreamTrackRendererInternalUnit { AudioMediaStreamTrackRendererInternalUnitIdentifier { identifier } }, 0);
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::beginAudioSessionInterruption()
{
    swiftBeginAudioSessionInterruption();
}

void RemoteAudioMediaStreamTrackRendererInternalUnitManager::endAudioSessionInterruption(WebCore::AudioSession::MayResume)
{
    swiftEndAudioSessionInterruption();
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
