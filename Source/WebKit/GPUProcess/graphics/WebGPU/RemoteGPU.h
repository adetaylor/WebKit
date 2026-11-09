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

#pragma once

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "RemoteGPURequestAdapterResponse.h"
#include "SharedPreferencesForWebProcess.h"
#include "StreamConnectionWorkQueue.h"
#include "StreamMessageReceiver.h"
#include "StreamServerConnection.h"
#include "WebGPUIdentifier.h"
#include "WebModelIdentifier.h"
#include <CoreGraphics/CGImage.h>
#include <IOSurface/IOSurfaceRef.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/CompletionHandler.h>
#include <wtf/MachSendRight.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadAssertions.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/UniqueRef.h>
#include <wtf/WeakPtr.h>

namespace IPC {
class Connection;
}

namespace WebCore {
class IOSurface;
class ImageBuffer;
class NativeImage;
class ProcessIdentity;
}

namespace WebModel {
struct ImageAsset;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class ModelObjectHeap;
class RemoteRenderingBackend;

// The receiver of a web process's WebGPU messages to its GPU, on its own work queue. Swift handles the WebGPU messages
// (RemoteGPU.swift), on the registry of WebGPU objects that m_swiftState holds; C++ keeps the receiver's lifecycle, the
// rendering backend's image buffers, and the Model process's meshes.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteGPU.swift") RemoteGPU final : public CanMakeWeakPtr<RemoteGPU>, public IPC::StreamServerConnection::Client {
    WTF_MAKE_TZONE_ALLOCATED(RemoteGPU);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RemoteGPU);
public:
    static Ref<RemoteGPU> create(WebGPUIdentifier identifier, GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteRenderingBackend& renderingBackend, Ref<IPC::StreamServerConnection>&& serverConnection)
    {
        auto result = adoptRef(*new RemoteGPU(identifier, gpuConnectionToWebProcess, renderingBackend, WTF::move(serverConnection)));
        result->initialize();
        return result;
    }

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const { return m_sharedPreferencesForWebProcess; }

    virtual ~RemoteGPU();

    void stopListeningForIPC();

    void paintNativeImageToImageBuffer(WebCore::NativeImage&, WebCore::RenderingResourceIdentifier);
    // Paints the image, or else the IOSurface's image, into the rendering backend's image buffer with that identifier.
    void paintToImageBuffer(CGImageRef WTF_NULLABLE, IOSurfaceRef WTF_NULLABLE, bool forceOpaque, uint64_t imageBufferIdentifier);
    RefPtr<WebCore::ImageBuffer> imageBuffer(WebCore::RenderingResourceIdentifier);
    RefPtr<GPUConnectionToWebProcess> gpuConnectionToWebProcess() const;
    // Null once the receiver stops listening.
    RefPtr<IPC::StreamServerConnection> streamConnection() const { return m_streamConnection; }

    static Vector<UniqueRef<WebCore::IOSurface>> createRenderBuffers(unsigned width, unsigned height, const WebCore::ProcessIdentity&, bool standardDynamicRange = false);
    IPC::StreamConnectionWorkQueue& workQueue() const { return m_workQueue; }

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { IPC::StreamMessageReceiver::ref(); }
    void deref() const { IPC::StreamMessageReceiver::deref(); }
#endif

private:
    RemoteGPU(WebGPUIdentifier, GPUConnectionToWebProcess&, RemoteRenderingBackend&, Ref<IPC::StreamServerConnection>&&);

    RemoteGPU(const RemoteGPU&) = delete;
    RemoteGPU(RemoteGPU&&) = delete;
    RemoteGPU& operator=(const RemoteGPU&) = delete;
    RemoteGPU& operator=(RemoteGPU&&) = delete;

    void initialize();
    void workQueueInitialize();
    void workQueueUninitialize();

    template<typename T>
    IPC::Error send(T&& message) const
    {
        return protect(*m_streamConnection)->send(std::forward<T>(message), m_identifier);
    }

    // IPC::StreamServerConnection::Client overrides.
    void didReceiveInvalidMessage(IPC::StreamServerConnection&, IPC::MessageName, const Vector<uint32_t>&) final;

    NODELETE void createModelBacking(unsigned width, unsigned height, WebModel::ImageAsset&& diffuseTexture, WebModel::ImageAsset&& specularTexture, WebKit::WebModelIdentifier, bool standardDynamicRange, CompletionHandler<void(Vector<MachSendRight>&&)>&&);

    // Implemented in Swift (RemoteGPU.swift), on the state that m_swiftState holds from swiftInitialize() to the
    // destructor: the scheduler of the WebGPU instance's work on the work queue, and the registry of the WebGPU objects,
    // which holds this receiver until swiftUninitialize() releases it. The scheduler holds work scheduled once the receiver
    // begins stopping, which swiftRunScheduledWork() runs.
    void swiftInitialize(MachSendRight webProcessResourceOwner);
    static void destroySwiftState(uintptr_t);
    void swiftBeginStopping();
    void swiftRunScheduledWork(bool thenStopped);
    void swiftUninitialize();

    ThreadSafeWeakPtr<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    SharedPreferencesForWebProcess m_sharedPreferencesForWebProcess;
    const Ref<IPC::StreamConnectionWorkQueue> m_workQueue;
    RefPtr<IPC::StreamServerConnection> m_streamConnection;
    const Ref<ModelObjectHeap> m_modelObjectHeap WTF_GUARDED_BY_CAPABILITY(workQueue());
    const WebGPUIdentifier m_identifier;
    const Ref<RemoteRenderingBackend> m_renderingBackend;
    uintptr_t m_swiftState { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
