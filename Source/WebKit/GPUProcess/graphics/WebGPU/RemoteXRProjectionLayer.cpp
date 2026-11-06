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
#include "RemoteXRProjectionLayer.h"

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "RemoteGPU.h"
#include "RemoteXRProjectionLayerMessages.h"
#include "StreamServerConnection.h"
#include "WebGPUObjectHeap.h"
#include "WebKit-Swift.h"
#include <WebCore/PlatformXR.h>
#include <WebCore/WebGPUCppAPI.h>
#include <wtf/MachSendRight.h>
#include <wtf/TZoneMalloc.h>

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_OPTIONAL_CONNECTION_BASE(assertion, m_streamConnection)

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteXRProjectionLayer);

Ref<RemoteXRProjectionLayer> RemoteXRProjectionLayer::create(WebGPUXRProjectionLayer&& layer, WebGPU::ObjectHeap& objectHeap, Ref<IPC::StreamServerConnection>&& streamConnection, RemoteGPU& gpu, WebGPUIdentifier identifier)
{
    return adoptRef(*new RemoteXRProjectionLayer(WTF::move(layer), objectHeap, WTF::move(streamConnection), gpu, identifier));
}

RemoteXRProjectionLayer::RemoteXRProjectionLayer(WebGPUXRProjectionLayer&& layer, WebGPU::ObjectHeap& objectHeap, Ref<IPC::StreamServerConnection>&& streamConnection, RemoteGPU& gpu, WebGPUIdentifier identifier)
    : m_layer(makeUniqueWithoutFastMallocCheck<WebGPUXRProjectionLayer>(WTF::move(layer)))
    , m_objectHeap(objectHeap)
    , m_streamConnection(WTF::move(streamConnection))
    , m_identifier(identifier)
    , m_gpu(gpu)
{
    protect(m_streamConnection)->startReceivingMessages(*this, Messages::RemoteXRProjectionLayer::messageReceiverName(), m_identifier.toUInt64());
}

RemoteXRProjectionLayer::~RemoteXRProjectionLayer() = default;

void RemoteXRProjectionLayer::destruct()
{
    protect(m_objectHeap)->removeObject(m_identifier);
}

#if PLATFORM(COCOA)
void RemoteXRProjectionLayer::startFrame(uint64_t frameIndex, MachSendRight&& colorBuffer, MachSendRight&& depthBuffer, MachSendRight&& completionSyncEvent, uint64_t reusableTextureIndex, PlatformXR::RateMapDescription&& rateMapDescription)
{
#if ENABLE(WEBXR)
    m_layer->startFrame(frameIndex, colorBuffer.sendRight(), depthBuffer.sendRight(), completionSyncEvent.sendRight(), reusableTextureIndex, rateMapDescription.screenSize.width(), rateMapDescription.screenSize.height(), { rateMapDescription.horizontalSamplesLeft.span() }, { rateMapDescription.horizontalSamplesRight.span() }, { rateMapDescription.verticalSamples.span() });
#else
    UNUSED_PARAM(frameIndex);
    UNUSED_PARAM(colorBuffer);
    UNUSED_PARAM(depthBuffer);
    UNUSED_PARAM(completionSyncEvent);
    UNUSED_PARAM(reusableTextureIndex);
    UNUSED_PARAM(rateMapDescription);
#endif
}
#endif

void RemoteXRProjectionLayer::endFrame()
{
}

void RemoteXRProjectionLayer::destroy()
{
    m_layer->destroy();
}

void RemoteXRProjectionLayer::stopListeningForIPC()
{
    protect(m_streamConnection)->stopReceivingMessages(Messages::RemoteXRProjectionLayer::messageReceiverName(), m_identifier.toUInt64());
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
