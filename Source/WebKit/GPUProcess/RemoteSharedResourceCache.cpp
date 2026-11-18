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

#if ENABLE(GPU_PROCESS)
#include "RemoteSharedResourceCache.h"

#include "GPUConnectionToWebProcess.h"
#include <wtf/TZoneMallocInlines.h>

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "ImageBufferShareableAllocator.h"
#include "RemoteRenderingBackend.h"
#include "SharedPreferencesForWebProcess.h"
#include <WebCore/FilterGraphicsBridge.h>
#endif

#if HAVE(IOSURFACE)
#include <WebCore/IOSurfacePool.h>
#endif

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(RemoteSharedResourceCache);

Ref<RemoteSharedResourceCache> RemoteSharedResourceCache::create(GPUConnectionToWebProcess& gpuConnectionToWebProcess)
{
    return adoptRef(*new RemoteSharedResourceCache(gpuConnectionToWebProcess));
}

RemoteSharedResourceCache::RemoteSharedResourceCache(GPUConnectionToWebProcess& gpuConnectionToWebProcess)
    : m_resourceOwner(gpuConnectionToWebProcess.webProcessIdentity())
#if HAVE(IOSURFACE)
    , m_ioSurfacePool(IOSurfacePool::create())
#endif
    , m_swiftState(createSwiftState())
{
}

RemoteSharedResourceCache::~RemoteSharedResourceCache()
{
    destroySwiftState(m_swiftState);
}

bool RemoteSharedResourceCache::addSerializedImageBuffer(RemoteSerializedImageBufferIdentifier identifier, Ref<ImageBuffer> imageBuffer)
{
    didCreateImageBuffer(imageBuffer->renderingPurpose(), imageBuffer->renderingMode());
    return m_serializedImageBuffers.add({ identifier, 0 }, WTF::move(imageBuffer));
}

RefPtr<ImageBuffer> RemoteSharedResourceCache::takeSerializedImageBuffer(RemoteSerializedImageBufferIdentifier identifier)
{
    RefPtr imageBuffer = m_serializedImageBuffers.take({ { identifier, 0 }, 0 }, defaultRemoteSharedResourceCacheTimeout);
    if (imageBuffer)
        didReleaseImageBuffer(imageBuffer->renderingPurpose(), imageBuffer->renderingMode());
    return imageBuffer;
}

bool RemoteSharedResourceCache::addNativeImage(RemoteNativeImageReference reference, Ref<NativeImage> image)
{
    return m_nativeImages.add(reference, WTF::move(image));
}

RefPtr<NativeImage> RemoteSharedResourceCache::readNativeImage(RemoteNativeImageReadReference&& read, Seconds timeout)
{
    return m_nativeImages.read(WTF::move(read), timeout);
}

std::optional<RefPtr<NativeImage>> RemoteSharedResourceCache::readNativeImage(IPC::StreamServerConnection& connection, RemoteNativeImageReadReference&& read)
{
    return m_nativeImages.read(connection, WTF::move(read));
}

void RemoteSharedResourceCache::releaseNativeImage(RemoteNativeImageWriteReference&& write)
{
    m_nativeImages.remove(WTF::move(write));
}

void RemoteSharedResourceCache::releaseSerializedImageBuffer(RemoteSerializedImageBufferIdentifier identifier)
{
    // Must wait due to using current accounting mechanism.
    takeSerializedImageBuffer(identifier);
}

void RemoteSharedResourceCache::lowMemoryHandler()
{
#if HAVE(IOSURFACE)
    Ref { m_ioSurfacePool }->discardAllSurfaces();
#endif
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
static bool useIOSurfaceWebKitBehavior(RemoteRenderingBackend& backend)
{
#if USE(APPLE_INTERNAL_SDK)
    auto preferences = backend.sharedPreferencesForWebProcess();
    return preferences && preferences->useIOSurfaceWebKitBehavior;
#else
    UNUSED_PARAM(backend);
    return false;
#endif
}

FilterImageAllocator* createFilterImageAllocator(RemoteRenderingBackend* backend)
{
    if (!backend)
        return &FilterImageAllocator::create(makeUnique<ImageBufferAllocator>()).leakRef();
    Ref sharedResourceCache = backend->sharedResourceCache();
#if HAVE(IOSURFACE)
    auto allocator = makeUnique<ImageBufferShareableAllocator>(sharedResourceCache->resourceOwner(), &sharedResourceCache->ioSurfacePool(), useIOSurfaceWebKitBehavior(*backend));
#else
    auto allocator = makeUnique<ImageBufferShareableAllocator>(sharedResourceCache->resourceOwner());
#endif
    return &FilterImageAllocator::create(WTF::move(allocator)).leakRef();
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
