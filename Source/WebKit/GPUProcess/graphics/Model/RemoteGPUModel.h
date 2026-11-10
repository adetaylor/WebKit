/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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

#pragma once

#if ENABLE(GPU_PROCESS_MODEL) && ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "SharedPreferencesForWebProcess.h"
#include "StreamMessageReceiver.h"
#include "WebGPUIdentifier.h"
#include "WebModelIdentifier.h"
#include <wtf/CompletionHandler.h>
#include <wtf/MachSendRight.h>
#include <wtf/Ref.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

namespace IPC {
class StreamConnectionWorkQueue;
class SwiftReceiverOwner;
}

namespace WebCore {
class IOSurface;
class ProcessIdentity;
}

namespace WebModel {
struct ImageAsset;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class ModelObjectHeap;
class RemoteRenderingBackend;

// The receiver of a web process's Model messages to its GPU, on the stream connection and work queue of the RemoteGPU with
// the same identifier, which its owner keeps receiving until it stops: it makes the meshes, which it keeps until then.
class RemoteGPUModel final : public IPC::StreamMessageReceiver, public CanMakeWeakPtr<RemoteGPUModel> {
    WTF_MAKE_TZONE_ALLOCATED(RemoteGPUModel);
public:
    static Ref<RemoteGPUModel> create(GPUConnectionToWebProcess&, RemoteRenderingBackend&, IPC::SwiftReceiverOwner&, WebGPUIdentifier);

    virtual ~RemoteGPUModel();

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;
    IPC::StreamConnectionWorkQueue& workQueue() const;
    RemoteRenderingBackend& renderingBackend() const { return m_renderingBackend.get(); }

    static Vector<UniqueRef<WebCore::IOSurface>> createRenderBuffers(unsigned width, unsigned height, const WebCore::ProcessIdentity&, bool standardDynamicRange = false);

private:
    RemoteGPUModel(GPUConnectionToWebProcess&, RemoteRenderingBackend&, IPC::SwiftReceiverOwner&, WebGPUIdentifier);

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    void createModelBacking(unsigned width, unsigned height, WebModel::ImageAsset&& diffuseTexture, WebModel::ImageAsset&& specularTexture, WebModelIdentifier, bool standardDynamicRange, CompletionHandler<void(Vector<MachSendRight>&&)>&&);

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    const Ref<RemoteRenderingBackend> m_renderingBackend;
    const Ref<IPC::SwiftReceiverOwner> m_owner;
    const Ref<ModelObjectHeap> m_modelObjectHeap;
    const WebGPUIdentifier m_identifier;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_MODEL) && ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
