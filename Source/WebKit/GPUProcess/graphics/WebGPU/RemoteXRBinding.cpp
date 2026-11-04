/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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
#include "RemoteXRBinding.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteGPU.h"
#include "RemoteXRBindingMessages.h"
#include "RemoteXRProjectionLayer.h"
#include "RemoteXRSubImage.h"
#include "StreamServerConnection.h"
#include "WebGPUObjectHeap.h"
#include "WebKit-Swift.h"
#include <WebCore/WebGPUCppAPI.h>
#include <wtf/TZoneMalloc.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteXRBinding);

Ref<RemoteXRBinding> RemoteXRBinding::create(GPUConnectionToWebProcess& gpuConnectionToWebProcess, WebGPUXRBinding&& binding, WebGPU::ObjectHeap& objectHeap, RemoteGPU& gpu, Ref<IPC::StreamServerConnection>&& streamConnection, WebGPUIdentifier identifier)
{
    return adoptRef(*new RemoteXRBinding(gpuConnectionToWebProcess, WTF::move(binding), objectHeap, gpu, WTF::move(streamConnection), identifier));
}

RemoteXRBinding::RemoteXRBinding(GPUConnectionToWebProcess& gpuConnectionToWebProcess, WebGPUXRBinding&& binding, WebGPU::ObjectHeap& objectHeap, RemoteGPU& gpu, Ref<IPC::StreamServerConnection>&& streamConnection, WebGPUIdentifier identifier)
    : m_binding(makeUniqueWithoutFastMallocCheck<WebGPUXRBinding>(WTF::move(binding)))
    , m_objectHeap(objectHeap)
    , m_streamConnection(WTF::move(streamConnection))
    , m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_identifier(identifier)
    , m_gpu(gpu)
{
    protect(m_streamConnection)->startReceivingMessages(*this, Messages::RemoteXRBinding::messageReceiverName(), m_identifier.toUInt64());
}

RemoteXRBinding::~RemoteXRBinding() = default;

void RemoteXRBinding::destruct()
{
    protect(m_objectHeap)->removeObject(m_identifier);
}

void RemoteXRBinding::createProjectionLayer(::WebGPU::TextureFormat colorFormat, std::optional<::WebGPU::TextureFormat> depthStencilFormat, OptionSet<::WebGPU::TextureUsage> textureUsage, double scaleFactor, WebGPUIdentifier identifier)
{
    Ref objectHeap = m_objectHeap.get();
    Ref remoteProjectionLayer = RemoteXRProjectionLayer::create(m_binding->createProjectionLayer(std::to_underlying(colorFormat), depthStencilFormat.has_value(), std::to_underlying(depthStencilFormat.value_or(colorFormat)), textureUsage.toRaw(), scaleFactor), objectHeap, protect(m_streamConnection), protect(m_gpu), identifier);
    objectHeap->addObject(identifier, remoteProjectionLayer);
}

void RemoteXRBinding::getViewSubImage(WebGPUIdentifier projectionLayerIdentifier, WebGPUIdentifier identifier)
{
    Ref objectHeap = m_objectHeap.get();
    RefPtr projectionLayer = objectHeap->xrProjectionLayer(projectionLayerIdentifier);
    if (!projectionLayer) {
        // FIXME: Add MESSAGE_CHECK call
        return;
    }

    auto subImage = m_binding->getViewSubImage(projectionLayer->layer());
    if (!subImage.isValid()) {
        // FIXME: Add MESSAGE_CHECK call
        return;
    }

    Ref remoteSubImage = RemoteXRSubImage::create(*m_gpuConnectionToWebProcess.get(), WTF::move(subImage), objectHeap, protect(m_streamConnection), protect(m_gpu), identifier);
    objectHeap->addObject(identifier, remoteSubImage);
}

void RemoteXRBinding::stopListeningForIPC()
{
    protect(m_streamConnection)->stopReceivingMessages(Messages::RemoteXRBinding::messageReceiverName(), m_identifier.toUInt64());
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
