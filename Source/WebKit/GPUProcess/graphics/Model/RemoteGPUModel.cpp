/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
#include "RemoteGPUModel.h"

#if ENABLE(GPU_PROCESS_MODEL) && ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "GPUConnectionToWebProcess.h"
#include "Logging.h"
#include "MeshImpl.h"
#include "ModelObjectHeap.h"
#include "ModelTypes.h"
#include "RemoteGPUModelMessages.h"
#include "RemoteMesh.h"
#include "RemoteRenderingBackend.h"
#include "StreamServerConnection.h"
#include "SwiftReceiverOwner.h"
#include "WebKitMesh.h"
#include <WebCore/IOSurface.h>
#include <WebCore/ProcessIdentity.h>
#include <wtf/TZoneMallocInlines.h>

#define MESSAGE_CHECK(assertion) MESSAGE_CHECK_BASE(assertion, m_owner->streamConnection())

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteGPUModel);

Ref<RemoteGPUModel> RemoteGPUModel::create(GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteRenderingBackend& renderingBackend, IPC::SwiftReceiverOwner& owner, WebGPUIdentifier identifier)
{
    return adoptRef(*new RemoteGPUModel(gpuConnectionToWebProcess, renderingBackend, owner, identifier));
}

RemoteGPUModel::RemoteGPUModel(GPUConnectionToWebProcess& gpuConnectionToWebProcess, RemoteRenderingBackend& renderingBackend, IPC::SwiftReceiverOwner& owner, WebGPUIdentifier identifier)
    : m_gpuConnectionToWebProcess(gpuConnectionToWebProcess)
    , m_renderingBackend(renderingBackend)
    , m_owner(owner)
    , m_modelObjectHeap(ModelObjectHeap::create())
    , m_identifier(identifier)
{
    weakPtrFactory().prepareForUseOnlyOnNonMainThread();
    // The stream connection lets go of this when the owner invalidates it, as its receiver stops, and the meshes go with it.
    owner.streamConnection()->startReceivingMessages(*this, Messages::RemoteGPUModel::messageReceiverName(), identifier.toUInt64());
}

RemoteGPUModel::~RemoteGPUModel() = default;

std::optional<SharedPreferencesForWebProcess> RemoteGPUModel::sharedPreferencesForWebProcess() const
{
    return m_owner->sharedPreferencesForWebProcess();
}

IPC::StreamConnectionWorkQueue& RemoteGPUModel::workQueue() const
{
    return m_owner->workQueue();
}

Vector<UniqueRef<WebCore::IOSurface>> RemoteGPUModel::createRenderBuffers(unsigned width, unsigned height, const WebCore::ProcessIdentity& processIdentity, bool standardDynamicRange)
{
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    const auto colorFormat = standardDynamicRange ? WebCore::IOSurface::Format::BGRA : WebCore::IOSurface::Format::RGBA16F;
#else
    const auto colorFormat = WebCore::IOSurface::Format::BGRA;
#endif
    const auto colorSpace = standardDynamicRange ? WebCore::ColorSpace::LinearDisplayP3() : WebCore::ColorSpace::ExtendedLinearDisplayP3();

    Vector<UniqueRef<WebCore::IOSurface>> ioSurfaces;

    constexpr auto surfaceCount = 2;
    for (auto i = 0; i < surfaceCount; ++i) {
        if (auto buffer = WebCore::IOSurface::create(nullptr, WebCore::IntSize(width, height), colorSpace, WebCore::IOSurface::Name::WebGPU, colorFormat)) {
            buffer->setOwnershipIdentity(processIdentity);
            ioSurfaces.append(makeUniqueRefFromNonNullUniquePtr(WTF::move(buffer)));
        }
    }

    return ioSurfaces;
}

static RefPtr<WebKit::Mesh> createModelBackingInternal(unsigned width, unsigned height, WebModel::ImageAsset&& diffuseTexture, WebModel::ImageAsset&& specularTexture, const WebCore::ProcessIdentity& processIdentity, bool standardDynamicRange, CompletionHandler<void(Vector<MachSendRight>&&)>&& callback)
{
    auto ioSurfaceVector = RemoteGPUModel::createRenderBuffers(width, height, processIdentity, standardDynamicRange);
    Vector<RetainPtr<IOSurfaceRef>> ioSurfaces;
    for (auto& ioSurface : ioSurfaceVector)
        ioSurfaces.append(ioSurface->surface());

    WebModelCreateMeshDescriptor backingDescriptor {
        .width = width,
        .height = height,
        .ioSurfaces = WTF::move(ioSurfaces),
        .diffuseTexture = WTF::move(diffuseTexture),
        .specularTexture = WTF::move(specularTexture),
        .processIdentity = &processIdentity,
        .standardDynamicRange = standardDynamicRange
    };

    auto mesh = WebKit::MeshImpl::create(WebMesh::create(backingDescriptor), WTF::move(ioSurfaceVector));
    callback(mesh->ioSurfaceHandles());
    return mesh;
}

void RemoteGPUModel::createModelBacking(unsigned width, unsigned height, WebModel::ImageAsset&& diffuseTexture, WebModel::ImageAsset&& specularTexture, WebModelIdentifier identifier, bool standardDynamicRange, CompletionHandler<void(Vector<MachSendRight>&&)>&& callback)
{
    assertIsCurrent(workQueue());

    MESSAGE_CHECK(width <= WKBridgeMaximumTextureDimension && height <= WKBridgeMaximumTextureDimension);
    auto& inputSpecularTexture = specularTexture;
    auto& inputDiffuseTexture = diffuseTexture;
    {
#define loadData(...) std::nullopt
        WEBMODEL_WEB_MODEL_PLAYER_DECLARE_DIFFUSE_AND_SPECULAR_TEXTURES
#undef loadData
#define equalIgnoringDataContents(a, b, dataSize) \
            (a.dataHandle ? a.dataHandle->size() : 0) == dataSize && \
            a.width == b.width && \
            a.height == b.height && \
            a.depth == b.depth && \
            a.textureType == b.textureType && \
            a.pixelFormat == b.pixelFormat && \
            a.mipmapLevelCount == b.mipmapLevelCount && \
            a.arrayLength == b.arrayLength && \
            a.textureUsage == b.textureUsage

        MESSAGE_CHECK(equalIgnoringDataContents(inputDiffuseTexture, diffuseTexture, 49152));
        MESSAGE_CHECK(equalIgnoringDataContents(inputSpecularTexture, specularTexture, 1048572));
#undef equalIgnoringDataContents
    }
    Ref objectHeap = m_modelObjectHeap;

    auto gpuProcessConnection = m_gpuConnectionToWebProcess.get();
    MESSAGE_CHECK(gpuProcessConnection);

    auto mesh = createModelBackingInternal(width, height, WTF::move(diffuseTexture), WTF::move(specularTexture), gpuProcessConnection->webProcessIdentity(), standardDynamicRange, WTF::move(callback));
    RefPtr streamConnection = m_owner->streamConnection();
    MESSAGE_CHECK(streamConnection);
    auto remoteMesh = RemoteMesh::create(*gpuProcessConnection, *this, *mesh, objectHeap, streamConnection.releaseNonNull(), identifier, standardDynamicRange);
    objectHeap->addObject(identifier, remoteMesh);
}

} // namespace WebKit

#undef MESSAGE_CHECK

#endif // ENABLE(GPU_PROCESS_MODEL) && ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
