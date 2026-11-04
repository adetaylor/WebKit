/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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
#include "RemoteXRSubImage.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteGPU.h"
#include "RemoteXRSubImageMessages.h"
#include "StreamServerConnection.h"
#include "WebGPUObjectHeap.h"
#include "WebKit-Swift.h"
#include <WebCore/WebGPUCppAPI.h>
#include <wtf/TZoneMalloc.h>

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_streamConnection)

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteXRSubImage);

Ref<RemoteXRSubImage> RemoteXRSubImage::create(GPUConnectionToWebProcess& gpuConnectionToWebProcess, WebGPUXRSubImage&& subImage, WebGPU::ObjectHeap& objectHeap, Ref<IPC::StreamServerConnection>&& streamConnection, RemoteGPU& gpu, WebGPUIdentifier identifier)
{
    return adoptRef(*new RemoteXRSubImage(gpuConnectionToWebProcess, WTF::move(subImage), objectHeap, WTF::move(streamConnection), gpu, identifier));
}

RemoteXRSubImage::RemoteXRSubImage(GPUConnectionToWebProcess& gpuConnectionToWebProcess, WebGPUXRSubImage&& subImage, WebGPU::ObjectHeap& objectHeap, Ref<IPC::StreamServerConnection>&& streamConnection, RemoteGPU& gpu, WebGPUIdentifier identifier)
    : m_subImage(makeUniqueWithoutFastMallocCheck<WebGPUXRSubImage>(WTF::move(subImage)))
    , m_objectHeap(objectHeap)
    , m_streamConnection(WTF::move(streamConnection))
    , m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_identifier(identifier)
    , m_gpu(gpu)
{
    protect(m_streamConnection)->startReceivingMessages(*this, Messages::RemoteXRSubImage::messageReceiverName(), m_identifier.toUInt64());
}

RemoteXRSubImage::~RemoteXRSubImage() = default;

void RemoteXRSubImage::destruct()
{
    protect(m_objectHeap)->removeObject(m_identifier);
}

void RemoteXRSubImage::getColorTexture(WebGPUIdentifier identifier)
{
    if (!m_gpuConnectionToWebProcess.get())
        return;
    bool hasTexture = protect(m_objectHeap)->addXRSubImageTexture(*m_subImage, false, identifier);
    ASSERT_UNUSED(hasTexture, hasTexture);
}

void RemoteXRSubImage::getDepthTexture(WebGPUIdentifier identifier)
{
    if (!m_gpuConnectionToWebProcess.get())
        return;
    bool hasTexture = protect(m_objectHeap)->addXRSubImageTexture(*m_subImage, true, identifier);
    ASSERT_UNUSED(hasTexture, hasTexture);
}

void RemoteXRSubImage::stopListeningForIPC()
{
    protect(m_streamConnection)->stopReceivingMessages(Messages::RemoteXRSubImage::messageReceiverName(), m_identifier.toUInt64());
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
