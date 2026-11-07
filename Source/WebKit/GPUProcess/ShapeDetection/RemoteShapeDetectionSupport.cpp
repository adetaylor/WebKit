/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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
#include "RemoteShapeDetectionSupport.h"

#if ENABLE(GPU_PROCESS) && HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)

#include "RemoteBarcodeDetectorMessages.h"
#include "RemoteFaceDetectorMessages.h"
#include "RemoteRenderingBackend.h"
#include "RemoteResourceCache.h"
#include "RemoteTextDetectorMessages.h"
#include "WebKit-Swift.h"
#include <WebCore/BarcodeDetectorImplementation.h>
#include <WebCore/BarcodeDetectorOptionsInterface.h>
#include <WebCore/FaceDetectorOptionsInterface.h>
#include <WebCore/NativeImage.h>

namespace WebKit {

RemoteShapeDetectionResources::RemoteShapeDetectionResources(RemoteRenderingBackend& backend)
    : m_backend(backend)
{
}

RemoteShapeDetectionResources::~RemoteShapeDetectionResources() = default;

RemoteRenderingBackend& RemoteShapeDetectionResources::backend() const
{
    return m_backend.get();
}

std::optional<SharedPreferencesForWebProcess> RemoteShapeDetectionResources::sharedPreferencesForWebProcess() const
{
    return m_backend.get().sharedPreferencesForWebProcess();
}

CGImageRef copyShapeDetectionImage(const RemoteShapeDetectionResources& resources, uint64_t renderingResourceIdentifier, bool& found)
{
    RefPtr image = resources.backend().remoteResourceCache().cachedNativeImage(WebCore::RenderingResourceIdentifier { renderingResourceIdentifier });
    found = !!image;
    if (!image)
        return nullptr;
    return image->platformImage().leakRef();
}

template<typename Forwarder>
static Ref<IPC::StreamMessageReceiver> withSharedPreferences(Ref<Forwarder>&& forwarder, Ref<RemoteShapeDetectionResources>&& resources)
{
    forwarder->setSharedPreferencesProvider([resources = WTF::move(resources)] {
        return resources->sharedPreferencesForWebProcess();
    });
    return forwarder;
}

Ref<IPC::StreamMessageReceiver> createRemoteBarcodeDetectorReceiver(RemoteRenderingBackend& backend, const WebCore::ShapeDetection::BarcodeDetectorOptions& options)
{
    Ref resources = RemoteShapeDetectionResources::create(backend);
    Ref forwarder = RemoteBarcodeDetector::createMessageReceiver(resources.ptr(), WebCore::ShapeDetection::BarcodeDetectorImpl::formatMask(options.formats));
    return withSharedPreferences(WTF::move(forwarder), WTF::move(resources));
}

Ref<IPC::StreamMessageReceiver> createRemoteFaceDetectorReceiver(RemoteRenderingBackend& backend, const WebCore::ShapeDetection::FaceDetectorOptions& options)
{
    Ref resources = RemoteShapeDetectionResources::create(backend);
    Ref forwarder = RemoteFaceDetector::createMessageReceiver(resources.ptr(), options.maxDetectedFaces);
    return withSharedPreferences(WTF::move(forwarder), WTF::move(resources));
}

Ref<IPC::StreamMessageReceiver> createRemoteTextDetectorReceiver(RemoteRenderingBackend& backend)
{
    Ref resources = RemoteShapeDetectionResources::create(backend);
    Ref forwarder = RemoteTextDetector::createMessageReceiver(resources.ptr());
    return withSharedPreferences(WTF::move(forwarder), WTF::move(resources));
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS) && HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)
