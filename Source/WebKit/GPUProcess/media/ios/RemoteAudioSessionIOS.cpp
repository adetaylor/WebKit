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
#include "RemoteAudioSessionIOS.h"

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION) && PLATFORM(IOS_FAMILY)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include <WebCore/AVAudioSessionCaptureDeviceManager.h>
#include <WebCore/AudioSession.h>
#include <WebCore/MediaSessionHelperIOS.h>

namespace WebKit {

using namespace WebCore;

void RemoteAudioSessionIOS::setHostProcessAttribution()
{
    if (auto auditToken = protect(GPUProcess::singleton().parentProcessConnection())->getAuditToken())
        AudioSession::singleton().setHostProcessAttribution(*auditToken);
}

void RemoteAudioSessionIOS::providePresentingApplicationPID(GPUConnectionToWebProcess& webProcessConnection)
{
#if ENABLE(EXTENSION_CAPABILITIES)
    if (webProcessConnection.sharedPreferencesForWebProcessValue().mediaCapabilityGrantsEnabled)
        return;
#endif

    ProcessID pid = protect(GPUProcess::singleton().parentProcessConnection())->remoteProcessID();

#if !PLATFORM(APPLETV)
    // Presenting application audit tokens are per-page, but AudioSessions are per-web-process,
    // and it's not straightforward to know in the GPU process which page is responsible for activating
    // the shared AVAudioSession. In reality, all pages in a given web process share a presenting
    // application, so it's sufficient to use the first page's audit token.
    auto& auditTokens = webProcessConnection.presentingApplicationAuditTokens();
    if (!auditTokens.isEmpty())
        pid = webProcessConnection.presentingApplicationPID(*auditTokens.keys().begin());
#ifndef NDEBUG
    for (auto& pageIdentifier : auditTokens.keys())
        ASSERT(pid == webProcessConnection.presentingApplicationPID(pageIdentifier));
#endif
#endif

    protect(MediaSessionHelper::sharedHelper())->providePresentingApplicationPID(pid);
}

void RemoteAudioSessionIOS::setPreferredSpeakerID(const String& speakerID)
{
#if ENABLE(MEDIA_STREAM)
    AVAudioSessionCaptureDeviceManager::singleton().setPreferredSpeakerID(speakerID);
#else
    UNUSED_PARAM(speakerID);
#endif
}

void RemoteAudioSessionPresentingProcesses::add(GPUConnectionToWebProcess& gpuConnectionToWebProcess, bool isActive)
{
    // AVAudioSession will take out an assertion on all the "presenting applications"
    // when it moves to a "playing" state. But it's possible that (e.g.) multiple
    // applications may be using SafariViewService simultaneously. So only include
    // tokens from those proxies whose sessions are currently "active". Only their
    // presenting applications will be kept from becoming "suspended" during playback.
#if ENABLE(EXTENSION_CAPABILITIES)
    if (gpuConnectionToWebProcess.sharedPreferencesForWebProcessValue().mediaCapabilityGrantsEnabled)
        return;
#endif
    m_shouldAppendParentProcess = true;
    if (!isActive)
        return;
    for (auto& token : gpuConnectionToWebProcess.presentingApplicationAuditTokens().values())
        m_processes.append(token.auditToken());
}

void RemoteAudioSessionPresentingProcesses::commit()
{
    if (auto token = protect(GPUProcess::singleton().parentProcessConnection())->getAuditToken(); token && m_shouldAppendParentProcess)
        m_processes.append(*token);

    if (!m_processes.isEmpty())
        AudioSession::singleton().setPresentingProcesses(std::exchange(m_processes, { }));
}

} // namespace WebKit

#endif
