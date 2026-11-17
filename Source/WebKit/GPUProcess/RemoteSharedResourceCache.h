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

#pragma once

#if ENABLE(GPU_PROCESS)

#include "MessageReceiver.h"
#include "RemoteNativeImageIdentifier.h"
#include "RemoteSerializedImageBufferIdentifier.h"
#include "ThreadSafeObjectHeap.h"
#include <WebCore/ImageBuffer.h>
#include <WebCore/ImageBufferResourceLimits.h>
#include <WebCore/ProcessIdentity.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/FastMalloc.h>
#include <wtf/Ref.h>
#include <wtf/Seconds.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>

#if USE(IOSURFACE)
#include <WebCore/IOSurfacePool.h>
#endif

namespace WebCore {
class FilterImageAllocator;
}

namespace WebKit {

class RemoteRenderingBackend;

// Timeout for waiting on a resource to be published in the shared cache from another work queue.
constexpr Seconds defaultRemoteSharedResourceCacheTimeout = 15_s;

class GPUConnectionToWebProcess;
// Class holding GPU process resources per Web Content process.
// Thread-safe. The counts of the image buffers are in the Swift state that m_swiftState holds (RemoteSharedResourceCache.swift).
class SWIFT_PRIVATE_FILEID("WebKit/RemoteSharedResourceCache.swift") RemoteSharedResourceCache final : public ThreadSafeRefCounted<RemoteSharedResourceCache>, IPC::MessageReceiver {
    WTF_MAKE_TZONE_ALLOCATED(RemoteSharedResourceCache);
public:
    static Ref<RemoteSharedResourceCache> create(GPUConnectionToWebProcess&);
    virtual ~RemoteSharedResourceCache();

    void ref() const final { ThreadSafeRefCounted::ref(); }
    void deref() const final { ThreadSafeRefCounted::deref(); }

    bool addSerializedImageBuffer(RemoteSerializedImageBufferIdentifier, Ref<WebCore::ImageBuffer>);
    RefPtr<WebCore::ImageBuffer> takeSerializedImageBuffer(RemoteSerializedImageBufferIdentifier);

    bool addNativeImage(RemoteNativeImageReference, Ref<WebCore::NativeImage>);
    RefPtr<WebCore::NativeImage> readNativeImage(RemoteNativeImageReadReference&&, Seconds timeout);
    // For stream message handlers: std::nullopt means that the handler should defer the message.
    std::optional<RefPtr<WebCore::NativeImage>> readNativeImage(IPC::StreamServerConnection&, RemoteNativeImageReadReference&&);

    // IPC::MessageReceiver
    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    const WebCore::ProcessIdentity& resourceOwner() const LIFETIME_BOUND { return m_resourceOwner; }
#if HAVE(IOSURFACE)
    WebCore::IOSurfacePool& ioSurfacePool() const { return m_ioSurfacePool; }
#endif

    // Implemented in Swift, on the per-connection counts in the Swift state and the per-process ones, from any thread.
    void didCreateImageBuffer(WebCore::RenderingPurpose, WebCore::RenderingMode);
    void didReleaseImageBuffer(WebCore::RenderingPurpose, WebCore::RenderingMode);
    bool reachedAcceleratedImageBufferLimit(WebCore::RenderingPurpose, size_t globalAcceleratedImageBufferLimit) const;
    bool reachedImageBufferForCanvasLimit() const;
    WebCore::ImageBufferResourceLimits getResourceLimitsForTesting(size_t globalAcceleratedImageBufferLimit) const;

    void lowMemoryHandler();

private:
    RemoteSharedResourceCache(GPUConnectionToWebProcess&);

    static uintptr_t createSwiftState();
    static void destroySwiftState(uintptr_t);

    // Messages
    void releaseSerializedImageBuffer(RemoteSerializedImageBufferIdentifier);
    void releaseNativeImage(RemoteNativeImageWriteReference&&);

    IPC::ThreadSafeObjectHeap<RemoteSerializedImageBufferIdentifier, RefPtr<WebCore::ImageBuffer>> m_serializedImageBuffers;
    IPC::ThreadSafeObjectHeap<WebCore::RenderingResourceIdentifier, RefPtr<WebCore::NativeImage>> m_nativeImages;

    WebCore::ProcessIdentity m_resourceOwner;
#if HAVE(IOSURFACE)
    const Ref<WebCore::IOSurfacePool> m_ioSurfacePool;
#endif
    // A retained reference to the Swift state, as an address, from the constructor to the destructor.
    const uintptr_t m_swiftState;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
// The allocator of the images of the filters that a Swift renderer applies (RemoteCGRendererFilters.swift): the backend's
// shared resource cache's, as RemoteGraphicsContext's, or, for a replay or a renderer without a backend, the default one.
WebCore::FilterImageAllocator* WTF_NONNULL createFilterImageAllocator(RemoteRenderingBackend* WTF_NULLABLE) SWIFT_RETURNS_RETAINED;
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
