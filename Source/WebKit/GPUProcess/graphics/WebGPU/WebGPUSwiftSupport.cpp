/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
#include "WebGPUSwiftSupport.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "RemoteBindGroupLayoutMessages.h"
#include "RemoteGPU.h"
#include "StreamServerConnection.h"
#include "WebGPUObjectHeap.h"
#include "WebKit-Swift.h"

namespace WebKit {

WebGPUSwiftReceiverContext::WebGPUSwiftReceiverContext(WebGPU::ObjectHeap& objectHeap, RemoteGPU& gpu, WebGPUIdentifier identifier)
    : m_objectHeap(objectHeap)
    , m_gpu(gpu)
    , m_identifier(identifier)
{
}

void WebGPUSwiftReceiverContext::removeFromObjectHeap() const
{
    if (RefPtr objectHeap = m_objectHeap.get())
        objectHeap->removeObject(m_identifier);
}

std::optional<SharedPreferencesForWebProcess> WebGPUSwiftReceiverContext::sharedPreferencesForWebProcess() const
{
    if (RefPtr gpu = m_gpu.get())
        return gpu->sharedPreferencesForWebProcess();
    return std::nullopt;
}

static void addBindGroupLayout(WebGPU::ObjectHeap& objectHeap, RemoteGPU& gpu, IPC::StreamServerConnection& streamConnection, ::WebGPU::BindGroupLayout& bindGroupLayout, WebGPUIdentifier identifier)
{
    WebGPUSwiftReceiverContext context { objectHeap, gpu, identifier };
    auto remoteBindGroupLayout = RemoteBindGroupLayout::init(RemoteBindGroupLayoutBacking { bindGroupLayout }, context);
    objectHeap.addObject(identifier, WebGPU::BindGroupLayoutObject { bindGroupLayout, WTF::move(remoteBindGroupLayout), context, streamConnection, Messages::RemoteBindGroupLayout::messageReceiverName(), identifier });
}

bool WebGPUSwiftReceiverContext::makeChild(WebGPUSwiftChildKind kind, uint32_t index, uint64_t identifier) const
{
    RefPtr objectHeap = m_objectHeap.get();
    RefPtr gpu = m_gpu.get();
    if (!objectHeap || !gpu)
        return true;
    RefPtr streamConnection = gpu->m_streamConnection;
    if (!streamConnection)
        return true;

    WebGPUIdentifier childIdentifier { identifier };
    switch (kind) {
    case WebGPUSwiftChildKind::ComputePipelineBindGroupLayout: {
        RefPtr computePipeline = objectHeap->convertComputePipelineFromBacking(m_identifier);
        if (!computePipeline)
            return false;
        Ref bindGroupLayout = computePipeline->getBindGroupLayout(index);
        addBindGroupLayout(*objectHeap, *gpu, *streamConnection, bindGroupLayout, childIdentifier);
        return true;
    }
    case WebGPUSwiftChildKind::RenderPipelineBindGroupLayout: {
        RefPtr renderPipeline = objectHeap->convertRenderPipelineFromBacking(m_identifier);
        if (!renderPipeline)
            return false;
        Ref bindGroupLayout = renderPipeline->getBindGroupLayout(index);
        addBindGroupLayout(*objectHeap, *gpu, *streamConnection, bindGroupLayout, childIdentifier);
        return true;
    }
    }
    RELEASE_ASSERT_NOT_REACHED();
}

::WebGPU::ExternalTexture* WebGPUSwiftReceiverContext::externalTexture(uint64_t identifier) const
{
    RefPtr objectHeap = m_objectHeap.get();
    if (!objectHeap)
        return nullptr;
    RefPtr externalTexture = objectHeap->convertExternalTextureFromBacking(WebGPUIdentifier { identifier }).get();
    return externalTexture.leakRef();
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
