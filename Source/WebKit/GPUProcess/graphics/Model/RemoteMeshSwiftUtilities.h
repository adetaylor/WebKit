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

#pragma once

#include <wtf/Platform.h>

#if ENABLE(GPU_PROCESS_MODEL)

#include "GPUConnectionToWebProcess.h"
#include "Mesh.h"
#include "ModelObjectHeap.h"
#include "ModelTypes.h"
#include "RemoteGPU.h"
#include "RemoteMeshMessages.h"
#include "StreamConnectionWorkQueue.h"
#include "StreamServerConnection.h"
#include "WebModelIdentifier.h"
// For the complete WebCore::NativeImage that RemoteMesh.swift holds a RefPtr to.
#include <WebCore/NativeImage.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/MachSendRight.h>
#include <wtf/Ref.h>
#include <wtf/Vector.h>

// The type-system workarounds RemoteMesh.swift needs. Everything here is an adapter for
// something Swift cannot currently express; none of it makes decisions of its own.
namespace WebKit {

// Two things here are out of Swift's reach: it will not upcast an imported C++ reference type to a
// base class, even when the base is itself a foreign reference type; and WebModelIdentifier's
// toUInt64() is a member of a class template, which the importer does not expose. Naming
// Messages::RemoteMesh::messageReceiverName() from Swift does work, despite its inline body.
inline void startReceivingMeshMessages(IPC::StreamServerConnection& streamConnection, Ref<RemoteMeshMessageForwarder> forwarder, WebModelIdentifier identifier)
{
    streamConnection.startReceivingMessages(forwarder.get(), Messages::RemoteMesh::messageReceiverName(), identifier.toUInt64());
}

// Only here for toUInt64(); there is no upcast in this one.
inline void stopReceivingMeshMessages(IPC::StreamServerConnection& streamConnection, WebModelIdentifier identifier)
{
    streamConnection.stopReceivingMessages(Messages::RemoteMesh::messageReceiverName(), identifier.toUInt64());
}

// Mesh::render() takes a WTF::Function, and the result has to hop back onto the GPU work queue
// before the reply is sent, which needs a second one. WTF::Function does have an Objective-C block
// constructor for Swift under __swift__, but nothing in the tree uses it; only WTF::CompletionHandler
// has a proven Swift-closure bridge. Keep this in C++ until that path is worked out.
inline void renderMesh(Mesh& mesh, RemoteGPU& gpu, uint32_t textureIndex, CompletionHandlers::RemoteMesh::RenderCompletionHandler& completionHandler)
{
    Ref workQueue = gpu.workQueue();
    mesh.render(textureIndex, [workQueue = WTF::move(workQueue), completionHandler = protect(completionHandler)] (bool result) mutable {
        protect(workQueue)->dispatch([result, completionHandler = WTF::move(completionHandler)] mutable {
            (*completionHandler.get())(result);
        });
    });
}

// Allocating the replacement buffers yields a Vector<UniqueRef<WebCore::IOSurface>>, which is
// not representable in Swift.
inline Vector<MachSendRight> resizeMeshRenderBuffers(Mesh& mesh, RemoteGPU& gpu, uint32_t width, uint32_t height, bool standardDynamicRange)
{
    RefPtr gpuProcessConnection = gpu.gpuConnectionToWebProcess();
    if (!gpuProcessConnection)
        return { };

    auto renderBuffers = RemoteGPU::createRenderBuffers(width, height, gpuProcessConnection->webProcessIdentity(), standardDynamicRange);
    WebModel::ResizeMeshDescriptor descriptor { width, height, WTF::move(renderBuffers) };
    mesh.updateRenderBuffers(WTF::move(descriptor));
    return mesh.ioSurfaceHandles();
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_MODEL)
