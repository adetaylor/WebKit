/*
 * Copyright (C) 2020-2025 Apple Inc. All rights reserved.
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
#include "LibWebRTCCodecsProxyHandle.h"

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)

#include "GPUConnectionToWebProcess.h"
#include "GPUProcess.h"
#include "LibWebRTCCodecsProxyMessages.h"
#include "LibWebRTCCodecsProxyPlatform.h"
#include "RemoteVideoFrameObjectHeapHandle.h"
#include "WebKit-Swift.h"
#include <wtf/MainThread.h>

namespace WebKit {

Ref<LibWebRTCCodecsProxyHandle> LibWebRTCCodecsProxyHandle::create(GPUConnectionToWebProcess& webProcessConnection, SharedPreferencesForWebProcess& sharedPreferencesForWebProcess)
{
    Ref platform = LibWebRTCCodecsProxyPlatform::create(webProcessConnection.connection(), webProcessConnection.gpuProcess().libWebRTCCodecsQueue(), webProcessConnection.videoFrameObjectHeap(), webProcessConnection.webProcessIdentity(), sharedPreferencesForWebProcess);
    Ref handle = adoptRef(*new LibWebRTCCodecsProxyHandle(platform.copyRef()));
    Ref forwarder = handle->m_proxy->getMessageReceiver();
    forwarder->setSharedPreferencesProvider([platform] {
        return platform->sharedPreferencesForWebProcess();
    });
    forwarder->startReceivingMessages(platform->connection(), platform->workQueue());
    return handle;
}

LibWebRTCCodecsProxyHandle::LibWebRTCCodecsProxyHandle(Ref<LibWebRTCCodecsProxyPlatform>&& platform)
    : m_platform(WTF::move(platform))
    , m_proxy(makeUniqueWithoutFastMallocCheck<LibWebRTCCodecsProxy>(LibWebRTCCodecsProxy::init(m_platform.ptr())))
{
}

LibWebRTCCodecsProxyHandle::~LibWebRTCCodecsProxyHandle() = default;

void LibWebRTCCodecsProxyHandle::stopListeningForIPC(Ref<LibWebRTCCodecsProxyHandle>&&)
{
    m_proxy->stopListeningForIPC();
}

bool LibWebRTCCodecsProxyHandle::allowsExitUnderMemoryPressure() const
{
    assertIsMainRunLoop();
    return m_proxy->allowsExitUnderMemoryPressure();
}

void LibWebRTCCodecsProxyHandle::updateSharedPreferencesForWebProcess(SharedPreferencesForWebProcess sharedPreferencesForWebProcess)
{
    m_platform->updateSharedPreferencesForWebProcess(WTF::move(sharedPreferencesForWebProcess));
}

}

#endif
