/*
 * Copyright (C) 2017-2025 Apple Inc. All rights reserved.
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
#include "UserMediaCaptureManagerProxy.h"

#if PLATFORM(COCOA) && ENABLE(MEDIA_STREAM)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "Logging.h"
#include <WebCore/AudioSession.h>
#include <WebCore/AudioUtilities.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <wtf/NativePromise.h>
#include <wtf/cocoa/Entitlements.h>

#if PLATFORM(IOS_FAMILY) && HAVE(AVCAPTUREDEVICEROTATIONCOORDINATOR)
#include <WebCore/AVVideoCaptureSource.h>
#endif

namespace WebKit {
using namespace WebCore;

void userMediaCaptureDidApplyEnvironment(GPUConnectionToWebProcess& connection, uint64_t pageIdentifier)
{
    protect(connection.gpuProcess())->didApplyCaptureEnvironment(connection.webProcessIdentifier(), PageIdentifier { pageIdentifier });
}

void userMediaCaptureMicrophoneUnitWillStart(GPUConnectionToWebProcess& connection, uint64_t pageIdentifier)
{
#if PLATFORM(IOS_FAMILY)
    connection.providePresentingApplicationPID(PageIdentifier { pageIdentifier });
#else
    UNUSED_PARAM(connection);
    UNUSED_PARAM(pageIdentifier);
#endif
    // FIXME: We should ensure that WebProcess sets up the AudioSession properly before starting to capture microphone.
    Ref session = AudioSession::singleton();
    RELEASE_LOG_ERROR_IF(!session->isActive() || session->category() != AudioSession::CategoryType::PlayAndRecord, WebRTC, "Audio session should be active (%d) and category should be play and record (%d)", session->isActive(), session->category() != AudioSession::CategoryType::PlayAndRecord);

    session->setCategory(AudioSession::CategoryType::PlayAndRecord, AudioSession::Mode::VideoChat, RouteSharingPolicy::Default);
    session->tryToSetActive(true)->whenSettled(RunLoop::mainSingleton(), [](auto&&) { });
}

uint64_t userMediaCaptureAudioFrameChunkSize()
{
    return std::max(WebCore::AudioUtilities::renderQuantumSize, AudioSession::singleton().preferredBufferSize());
}

ProcessIdentity userMediaCaptureResourceOwner(GPUConnectionToWebProcess& connection)
{
    return connection.webProcessIdentity();
}

IPC::Connection* userMediaCaptureUIProcessConnection(GPUConnectionToWebProcess& connection)
{
    return RefPtr { protect(connection.gpuProcess())->parentProcessConnection() }.leakRef();
}

#if PLATFORM(IOS_FAMILY)
bool applyUserMediaCaptureEnvironment(GPUConnectionToWebProcess& connection, bool isCamera, uint64_t pageIdentifier)
{
#if ENABLE(APP_PRIVACY_REPORT) && !PLATFORM(MACCATALYST)
    protect(connection.gpuProcess())->setCaptureTCCIdentity(connection.applicationBundleIdentifier());
#endif
#if ENABLE(EXTENSION_CAPABILITIES) && !PLATFORM(IOS_FAMILY_SIMULATOR)
    auto mediaPlaybackEnvironment = connection.mediaPlaybackEnvironment(PageIdentifier { pageIdentifier });
    bool hasMediaEnvironment = !mediaPlaybackEnvironment.isEmpty();
    RealtimeMediaSourceCenter::singleton().setCurrentMediaEnvironment(WTF::move(mediaPlaybackEnvironment));
    if (!hasMediaEnvironment && !RealtimeMediaSourceCenter::singleton().hasIdentity() && isCamera && WTF::processHasEntitlement("com.apple.developer.web-browser-engine.rendering"_s))
        return false;
#else
    UNUSED_PARAM(isCamera);
    UNUSED_PARAM(pageIdentifier);
#endif
    return true;
}

void provideUserMediaCapturePresentingApplicationPID(GPUConnectionToWebProcess& connection, uint64_t pageIdentifier)
{
    connection.providePresentingApplicationPID(PageIdentifier { pageIdentifier });
}

void userMediaCaptureCameraWillStart(GPUConnectionToWebProcess& connection, uint64_t pageIdentifier)
{
    connection.providePresentingApplicationPID(PageIdentifier { pageIdentifier });
#if HAVE(AVCAPTUREDEVICEROTATIONCOORDINATOR)
    AVVideoCaptureSource::setUseAVCaptureDeviceRotationCoordinatorAPI(connection.sharedPreferencesForWebProcess() && connection.sharedPreferencesForWebProcess()->useAVCaptureDeviceRotationCoordinatorAPI);
#endif
}
#endif

}

#endif
