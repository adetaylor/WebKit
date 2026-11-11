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

#include "config.h"
#include "RemoteAudioDestinationManager.h"

#if ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "Logging.h"
#include "RemoteAudioDestinationManagerMessages.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/AudioOutputUnit.h>
#include <wtf/TZoneMallocInlines.h>

#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
#include <WebCore/SpatialAudioExperienceHelper.h>
#endif

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteAudioDestinationManager);

RemoteAudioDestinationManager::RemoteAudioDestinationManager(GPUConnectionToWebProcess& connection)
    : m_gpuConnectionToWebProcess(connection)
{
    m_swiftState = createSwiftState();
}

RemoteAudioDestinationManager::~RemoteAudioDestinationManager()
{
    // The destinations stop rendering before they go.
    destroySwiftState(std::exchange(m_swiftState, 0));
}

void RemoteAudioDestinationManager::ref() const
{
    m_gpuConnectionToWebProcess.get()->ref();
}

void RemoteAudioDestinationManager::deref() const
{
    m_gpuConnectionToWebProcess.get()->deref();
}

bool RemoteAudioDestinationManager::isLockdownModeEnabled() const
{
    RefPtr connection = m_gpuConnectionToWebProcess.get();
    return connection && connection->isLockdownModeEnabled();
}

bool RemoteAudioDestinationManager::prefersSpatialAudioExperience() const
{
#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    auto sharedPreferences = sharedPreferencesForWebProcess();
    return sharedPreferences && sharedPreferences->preferSpatialAudioExperience;
#else
    return false;
#endif
}

void RemoteAudioDestinationManager::tryExitIfUnusedAndUnderMemoryPressure()
{
    if (RefPtr connection = m_gpuConnectionToWebProcess.get())
        connection->gpuProcess().tryExitIfUnusedAndUnderMemoryPressure();
}

void RemoteAudioDestinationManager::destinationWasDeleted(uint64_t identifier)
{
#if PLATFORM(IOS_FAMILY)
    m_sceneIdentifiers.remove(identifier);
#else
    UNUSED_PARAM(identifier);
#endif
}

std::optional<SharedPreferencesForWebProcess> RemoteAudioDestinationManager::sharedPreferencesForWebProcess() const
{
    if (RefPtr gpuConnectionToWebProcess = m_gpuConnectionToWebProcess.get())
        return gpuConnectionToWebProcess->sharedPreferencesForWebProcess();

    return std::nullopt;
}

#if PLATFORM(IOS_FAMILY)
void RemoteAudioDestinationManager::setSceneIdentifier(RemoteAudioDestinationIdentifier identifier, String&& sceneIdentifier)
{
    auto target = spatialTarget(identifier.toUInt64());
    if (!target.outputUnitIdentifier)
        return;
    auto& currentSceneIdentifier = m_sceneIdentifiers.add(identifier.toUInt64(), String { }).iterator->value;
    if (currentSceneIdentifier == sceneIdentifier)
        return;
    currentSceneIdentifier = WTF::move(sceneIdentifier);
#if HAVE(SPATIAL_AUDIO_EXPERIENCE)
    if (!target.prefersSpatialAudioExperience) {
        RELEASE_LOG(Media, "RemoteAudioDestination::setSceneIdentifier(%" PRIu64 ") %" PUBLIC_LOG_STRING ", but !prefersSpatialAudioExperience, so bailing", identifier.toUInt64(), currentSceneIdentifier.utf8().data());
        return;
    }

    RELEASE_LOG(Media, "RemoteAudioDestination::setSceneIdentifier(%" PRIu64 ") %" PUBLIC_LOG_STRING, identifier.toUInt64(), currentSceneIdentifier.utf8().data());
    RetainPtr experience = WebCore::createSpatialAudioExperienceWithOptions({ .sceneIdentifier = currentSceneIdentifier });
    WebCore::AudioOutputUnit::setSpatialAudioExperience(target.outputUnitIdentifier, experience.get());
#endif
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
