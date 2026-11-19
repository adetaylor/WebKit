/*
 * Copyright (C) 2020-2024 Apple Inc. All rights reserved.
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

#include "BufferIdentifierSet.h"
#include "Connection.h"
#include "ImageBufferBackendHandle.h"
#include "ImageBufferSetIdentifier.h"
#include "MarkSurfacesAsVolatileRequestIdentifier.h"
#include "PrepareBackingStoreBuffersData.h"
#include "RemoteDisplayListIdentifier.h"
#include "RemoteDisplayListRecorderIdentifier.h"
#include "RemoteGradientIdentifier.h"
#include "RemoteGraphicsContextIdentifier.h"
#include "RemoteMeshGradientIdentifier.h"
#include "RemotePathImplIdentifier.h"
#include "RemoteRenderingBackendIdentifier.h"
#include "RemoteSerializedImageBufferIdentifier.h"
#include "RemoteSharedResourceCache.h"
#include "RemoteSnapshotIdentifier.h"
#include "RemoteSnapshotRecorderIdentifier.h"
#include "RenderingUpdateID.h"
#include "SharedPreferencesForWebProcess.h"
#include "StreamConnectionWorkQueue.h"
#include "StreamMessageReceiver.h"
#include "StreamServerConnection.h"
#include <WebCore/FontBase.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/NativeImage.h>
#include <WebCore/ShareableBitmap.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/RenderingResourceIdentifier.h>
#include <wtf/BlockPtr.h>
#include <wtf/RefCountable.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

#if USE(CG)
#include <CoreGraphics/CoreGraphics.h>
#endif

#if !ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "IPCEvent.h"
#include "MessageReceiver.h"
#include "MessageSender.h"
#include "RemoteResourceCache.h"
#include "RemoteSnapshotSink.h"
#include "ScopedActiveMessageReceiveQueue.h"
#include "ScopedRenderingResourcesRequest.h"
#include <WebCore/PixelFormat.h>
#include <WebCore/ProcessIdentity.h>
#include <wtf/HashMap.h>
#endif

namespace WebCore {
class Filter;
class Gradient;
class MeshGradient;
class PathImpl;
struct FontCustomPlatformData;
struct FontCustomPlatformSerializedData;
}

namespace WebKit {

class GPUConnectionToWebProcess;
class RemoteImageBufferSet;
class SharedFont;
struct ImageBufferSetPrepareBufferForDisplayInputData;
enum class SwapBuffersDisplayRequirement : uint8_t;

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

using RefPtrImageBuffer = RefPtr<WebCore::ImageBuffer>;
using RefPtrNativeImage = RefPtr<WebCore::NativeImage>;
using RefGradient = Ref<WebCore::Gradient>;
using RefMeshGradient = Ref<WebCore::MeshGradient>;
using RefPathImpl = Ref<WebCore::PathImpl>;
using RefFilter = Ref<WebCore::Filter>;
using OptionalRenderingResourceIdentifier = std::optional<WebCore::RenderingResourceIdentifier>;
using ImageBufferSetPrepareBufferForDisplayInputs = Vector<ImageBufferSetPrepareBufferForDisplayInputData>;
using ImageBufferSetVolatileBuffers = Vector<std::pair<ImageBufferSetIdentifier, OptionSet<BufferInSetType>>>;
using SwapBuffersDisplayRequirements = Vector<SwapBuffersDisplayRequirement>;
using OptionSetBufferInSetType = OptionSet<BufferInSetType>;
using OptionalShareableBitmapHandle = std::optional<WebCore::ShareableBitmap::Handle>;
using OptionalImageBufferTransferIdentifier = std::optional<WebCore::ImageBufferTransferIdentifier>;
using RefSharedFont = Ref<SharedFont>;
using ShareableBitmapHandleBox = WTF::RefCountable<WebCore::ShareableBitmap::Handle>;

// The replies of the backend's messages that have them, which Swift completes through pointee, or, for those that take a move-only
// value, the complete() functions after the class.
using NativeImageBitmapCompletionHandler = WTF::RefCountable<CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>)>>;
using MoveSerializedBufferToTransferHeapCompletionHandler = WTF::RefCountable<CompletionHandler<void(std::optional<WebCore::ImageBufferTransferIdentifier>)>>;
using CreateSnapshotCompletionHandler = WTF::RefCountable<CompletionHandler<void()>>;
using SinkSnapshotRecorderIntoSnapshotFrameCompletionHandler = WTF::RefCountable<CompletionHandler<void(bool)>>;
using GetImageBufferResourceLimitsForTestingCompletionHandler = WTF::RefCountable<CompletionHandler<void(WebCore::ImageBufferResourceLimits)>>;

// With the CG renderer in Swift, the backend's message handlers and its state are Swift's (RemoteRenderingBackend.swift).
// m_swiftState holds the state from when the connection adds the backend (GPUConnectionToWebProcess::swiftAddRenderingBackend())
// to the destructor. The handlers whose arguments Swift can't take adapt them and call Swift.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteRenderingBackend.swift") RemoteRenderingBackend : public CanMakeWeakPtr<RemoteRenderingBackend>, public IPC::StreamServerConnection::Client {
    WTF_MAKE_TZONE_ALLOCATED(RemoteRenderingBackend);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RemoteRenderingBackend);

public:
    static Ref<RemoteRenderingBackend> create(GPUConnectionToWebProcess&, RemoteRenderingBackendIdentifier, Ref<IPC::StreamServerConnection>&&);
    virtual ~RemoteRenderingBackend();
    // Once the connection has added the backend (GPUConnectionToWebProcess::swiftAddRenderingBackend()).
    void startListeningForIPC() { dispatch([protectedThis = Ref { *this }] { protectedThis->workQueueInitialize(); }); }
    SWIFT_MAIN_ACTOR void stopListeningForIPC() { m_workQueue->stopAndWaitForCompletion([protectedThis = Ref { *this }] { protectedThis->workQueueUninitialize(); }); }

    NODELETE std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const { return m_sharedPreferencesForWebProcess; }
    size_t acceleratedImageBufferLimit() const { return m_sharedPreferencesForWebProcess.acceleratedImageBufferLimit; }

    // Stands in for an image that could not be created, so that the web process can keep using its identifier. Clipping to it
    // clips everything.
    static RefPtrNativeImage createPlaceholderNativeImage();
    RemoteSharedResourceCache& sharedResourceCache() { return m_sharedResourceCache; }

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    // Runs Function in RemoteRenderingBackend task queue.
    void dispatch(Function<void()>&& task) { m_workQueue->dispatch(WTF::move(task)); }
    void dispatchBlock(void (^block)(void)) { dispatch([block = makeBlockPtr(block)] { block(); }); }

    IPC::StreamServerConnection& streamConnection() const { return m_streamConnection.get(); }
    // Ends the messages to a receiver on the stream connection: false if none receives them.
    bool tryStopReceivingMessages(IPC::ReceiverName receiverName, uint64_t destinationID)
    {
        assertIsCurrent(workQueue());
        return m_streamConnection->tryStopReceivingMessages(receiverName, destinationID);
    }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { IPC::StreamMessageReceiver::ref(); }
    void deref() const { IPC::StreamMessageReceiver::deref(); }
#endif

    GPUConnectionToWebProcess& gpuConnectionToWebProcess() { return m_gpuConnectionToWebProcess.get(); }

    void setSharedMemoryForGetPixelBuffer(RefPtr<WebCore::SharedMemory> memory) { m_getPixelBufferSharedMemory = WTF::move(memory); }
    RefPtr<WebCore::SharedMemory> sharedMemoryForGetPixelBuffer() const { return m_getPixelBufferSharedMemory; }

    IPC::StreamConnectionWorkQueue& workQueue() const { return m_workQueue; }

    // On the backend's registry of image buffers' receivers and its cache of native images, which Swift draws.
    RefPtrImageBuffer imageBuffer(WebCore::RenderingResourceIdentifier);
    RefPtrNativeImage cachedNativeImage(WebCore::RenderingResourceIdentifier);
    // False if an image already has the identifier.
    bool addCachedNativeImage(Ref<WebCore::NativeImage>&& image, WebCore::RenderingResourceIdentifier identifier) { return putNativeImageInCache(image.get(), identifier, false); }
    // Puts a native image in the cache, replacing the one it has under the identifier where replaces is true: false if it
    // already has one, or if it has none to replace.
    bool putNativeImageInCache(WebCore::NativeImage& image, WebCore::RenderingResourceIdentifier identifier, bool replaces)
    {
        auto size = image.size();
        return swiftCacheNativeImage(image, image.platformImage().get(), size.width(), size.height(), image.headroom(), identifier, replaces);
    }

    // Paints the image into the image buffer with that identifier, scaled to its backend size, from another thread, which waits
    // for it on the work queue.
    void paintNativeImageToImageBuffer(WebCore::NativeImage&, WebCore::RenderingResourceIdentifier);

    RefPtrImageBuffer allocateImageBuffer(WebCore::FloatSize logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, WebCore::ColorSpace, WebCore::ImageBufferFormat, WebCore::ImageBufferCreationContext);
    RefPtrImageBuffer allocateImageBuffer(WebCore::FloatSize logicalSize, WebCore::RenderingMode renderingMode, WebCore::RenderingPurpose purpose, float resolutionScale, WebCore::ColorSpace colorSpace, WebCore::ImageBufferFormat bufferFormat)
    {
        return allocateImageBuffer(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, { });
    }

    RemoteRenderingBackendIdentifier identifier() { return m_renderingBackendIdentifier; }

    // m_swiftState, for Swift, which can't write it directly. Unsafe to set: the state must be a retained
    // RemoteRenderingBackendState that nothing else releases.
    uintptr_t swiftState() const { return m_swiftState; }
    SWIFT_UNSAFE void setSwiftState(uintptr_t state) { m_swiftState = state; }
    // For Swift, from any thread: has the work queue call swiftReleasePendingRecordings().
    void scheduleSwiftReleases() { dispatch([protectedThis = Ref { *this }] { protectedThis->swiftReleasePendingRecordings(); }); }

    // The messages that Swift can't make, to the web process.
    void sendDidFailToCreateBackend(WebCore::RenderingResourceIdentifier);
    void sendDidMarkLayersAsVolatile(MarkSurfacesAsVolatileRequestIdentifier, ImageBufferSetVolatileBuffers&&, bool allSucceeded);
    void sendDidFinalizeRenderingUpdate(RenderingUpdateID);

    // What Swift can't do itself: call ImageBuffer::create<>() and other templates, take move-only values, and tell whether
    // a buffer has other references than the caller's.
    RefPtrImageBuffer makeImageBuffer(WebCore::FloatSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, WebCore::ColorSpace, WebCore::ImageBufferFormat, const WebCore::ImageBufferCreationContext&);
    // Takes the bitmap.
    static RefPtrImageBuffer createImageBufferAdoptingBitmap(WebCore::FloatSize, float resolutionScale, WebCore::ColorSpace, WebCore::ImageBufferFormat, WebCore::RenderingPurpose, const WebCore::ImageBufferCreationContext&, ShareableBitmapHandleBox&);
    static void adjustImageBufferCreationContext(RemoteSharedResourceCache&, WebCore::ImageBufferCreationContext&);
    static void clearSurfacePool(WebCore::ImageBufferCreationContext&);
    static bool hasOnlyReference(const RefPtrImageBuffer& imageBuffer) { return imageBuffer && imageBuffer->hasOneRef(); }
    static RefPtrNativeImage sinkIntoNativeImage(RefPtrImageBuffer& imageBuffer) { return WebCore::ImageBuffer::sinkIntoNativeImage(WTF::move(imageBuffer)); }
    // Releases the buffer's context, so that no state of this backend leaks through it.
    static bool addSerializedImageBuffer(RemoteSharedResourceCache&, RemoteSerializedImageBufferIdentifier, RefPtrImageBuffer&);
    static OptionalImageBufferTransferIdentifier depositTransferredImageBuffer(WebCore::ProcessIdentifier owner, RefPtrImageBuffer&);
    // Null if the handle describes another buffer than the one it identifies.
    static RefPtrImageBuffer takeTransferredImageBuffer(const WebCore::ImageBufferTransferHandle&);
    // A handle to a bitmap of the image, which the image draws from from then on: none if it can't be made.
    OptionalShareableBitmapHandle createBitmapHandleReplacingPlatformImage(WebCore::NativeImage&);
    static void appendVolatileBuffers(ImageBufferSetVolatileBuffers& buffers, ImageBufferSetIdentifier identifier, OptionSetBufferInSetType volatileBuffers) { buffers.append({ identifier, volatileBuffers }); }
    static void appendRawVolatileBuffers(ImageBufferSetVolatileBuffers& buffers, ImageBufferSetIdentifier identifier, uint8_t volatileBuffers) { buffers.append({ identifier, OptionSet<BufferInSetType>::fromRaw(volatileBuffers) }); }
    static bool hasHandle(const OptionalShareableBitmapHandle& handle) { return !!handle; }
    static RefPtrNativeImage createNativeImage(WebCore::ShareableBitmap&);
    // The image buffer's IOSurface, if it has one, and whether its colour space is Display P3.
    static IOSurfaceRef WTF_NULLABLE surfaceForCopy(WebCore::ImageBuffer&, bool& isDisplayP3) CF_RETURNS_NOT_RETAINED;
    // An image that CG doesn't cache.
    static RefPtrNativeImage createTransientNativeImage(CGImageRef);
    static RefSharedFont createFont(const WebCore::FontInternalAttributes&, const WebCore::FontPlatformDataAttributes&, WebCore::FontCustomPlatformData* WTF_NULLABLE, uint64_t& renderingResourceIdentifier);


private:
    RemoteRenderingBackend(GPUConnectionToWebProcess&, RemoteRenderingBackendIdentifier, Ref<IPC::StreamServerConnection>&&);
    void workQueueInitialize()
    {
        assertIsCurrent(workQueue());
        m_streamConnection->open(*this, m_workQueue.get());
        m_streamConnection->startReceivingMessages(*this, IPC::ReceiverName::RemoteRenderingBackend, m_renderingBackendIdentifier.toUInt64());
    }
    void workQueueUninitialize();

    // IPC::StreamServerConnection::Client overrides.
    void didReceiveInvalidMessage(IPC::StreamServerConnection&, IPC::MessageName, const Vector<uint32_t>&) final;

    // Messages to be received.
    void createImageBuffer(WebCore::FloatSize logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, WebCore::ColorSpace, WebCore::ImageBufferFormat, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void createMappableImageBuffer(WebCore::FloatSize logicalSize, WebCore::RenderingMode renderingMode, WebCore::RenderingPurpose purpose, float resolutionScale, WebCore::ColorSpace colorSpace, WebCore::ImageBufferFormat bufferFormat, ImageBufferBackendHandle&& backingStore, WebCore::RenderingResourceIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier)
    {
        auto* handle = std::get_if<WebCore::ShareableBitmap::Handle>(&backingStore);
        swiftCreateMappableImageBuffer(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, handle ? ShareableBitmapHandleBox::create(WTF::move(*handle)).ptr() : nullptr, identifier, contextIdentifier);
    }
    // The bitmap is null if the backing store isn't one.
    void swiftCreateMappableImageBuffer(WebCore::FloatSize logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, WebCore::ColorSpace, WebCore::ImageBufferFormat, ShareableBitmapHandleBox* WTF_NULLABLE bitmap, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void releaseImageBuffer(WebCore::RenderingResourceIdentifier);
    void sinkImageBufferIntoNativeImage(WebCore::RenderingResourceIdentifier, WebCore::RenderingResourceIdentifier imageIdentifier);
    void moveToSerializedBuffer(WebCore::RenderingResourceIdentifier, RemoteSerializedImageBufferIdentifier);
    void moveToImageBuffer(RemoteSerializedImageBufferIdentifier, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void moveSerializedBufferToTransferHeap(RemoteSerializedImageBufferIdentifier, MoveSerializedBufferToTransferHeapCompletionHandler*);
    void takeTransferredBuffer(WebCore::ImageBufferTransferHandle, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void createDisplayListRecorder(RemoteDisplayListRecorderIdentifier);
    void sinkDisplayListRecorderIntoDisplayList(RemoteDisplayListRecorderIdentifier, RemoteDisplayListIdentifier);
    void releaseDisplayList(RemoteDisplayListIdentifier);
    void destroyGetPixelBufferSharedMemory() { m_getPixelBufferSharedMemory = nullptr; }
    void nativeImageBitmap(WebCore::RenderingResourceIdentifier imageIdentifier, NativeImageBitmapCompletionHandler*);
    void cacheNativeImage(WebCore::ShareableBitmap::Handle&& handle, WebCore::RenderingResourceIdentifier identifier) { swiftCacheNativeImageFromBitmap(WebCore::ShareableBitmap::create(WTF::move(handle)).get(), identifier); }
    void swiftCacheNativeImageFromBitmap(WebCore::ShareableBitmap* WTF_NULLABLE, WebCore::RenderingResourceIdentifier);
    void cacheNativeImageFromSharedNativeImage(RemoteNativeImageReadReference&&);
    // The shared image that the reference names, once another stream connection publishes it: found is false if the message is
    // deferred until then, and the image is null if there is none.
    void swiftCacheSharedNativeImage(WebCore::RenderingResourceIdentifier, bool found, WebCore::NativeImage* WTF_NULLABLE);
    void releaseNativeImage(WebCore::RenderingResourceIdentifier);
    void cachePathImpl(RefPathImpl, RemotePathImplIdentifier);
    void releasePathImpl(RemotePathImplIdentifier);
    void cacheGradient(RefGradient, RemoteGradientIdentifier);
    void releaseGradient(RemoteGradientIdentifier);
    void cacheMeshGradient(RefMeshGradient, RemoteMeshGradientIdentifier);
    void releaseMeshGradient(RemoteMeshGradientIdentifier);
    void cacheFilter(RefFilter);
    void releaseFilter(WebCore::RenderingResourceIdentifier);
    void cacheFont(WebCore::FontInternalAttributes, WebCore::FontPlatformDataAttributes, OptionalRenderingResourceIdentifier);
    void releaseFont(WebCore::RenderingResourceIdentifier);
    void cacheFontCustomPlatformData(WebCore::FontCustomPlatformSerializedData&&);
    // Null if the data couldn't be deserialized.
    void swiftCacheFontCustomPlatformData(WebCore::FontCustomPlatformData* WTF_NULLABLE, uint64_t renderingResourceIdentifier);
    void releaseFontCustomPlatformData(WebCore::RenderingResourceIdentifier);
    void releaseMemory();
    void finalizeRenderingUpdate(RenderingUpdateID identifier) { sendDidFinalizeRenderingUpdate(identifier); }
    void markSurfacesVolatile(MarkSurfacesAsVolatileRequestIdentifier, ImageBufferSetVolatileBuffers, bool forcePurge);
    void createImageBufferSet(ImageBufferSetIdentifier, RemoteGraphicsContextIdentifier);
    void releaseImageBufferSet(ImageBufferSetIdentifier);
    void prepareImageBufferSetsForDisplay(ImageBufferSetPrepareBufferForDisplayInputs&& inputs) { swiftPrepareImageBufferSetsForDisplay(inputs); }
    // Unsafe: the inputs are the caller's, which nothing else uses during the call.
    SWIFT_UNSAFE void swiftPrepareImageBufferSetsForDisplay(ImageBufferSetPrepareBufferForDisplayInputs&);
    // The buffers are prepared after the reply, to unblock the web process as soon as possible.
    void prepareImageBufferSetsForDisplaySync(ImageBufferSetPrepareBufferForDisplayInputs&& inputs, CompletionHandler<void(SwapBuffersDisplayRequirements&&)>&& completionHandler)
    {
        SwapBuffersDisplayRequirements requirements;
        requirements.resizeToFit(inputs.size());
        if (!swiftEnsureBuffersForDisplay(inputs, requirements))
            return;
        completionHandler(WTF::move(requirements));
        swiftPrepareBuffersForDisplay(inputs);
    }
    // Unsafe: the inputs and the requirements are the caller's, which nothing else uses during the call. False if the message is
    // invalid.
    SWIFT_UNSAFE bool swiftEnsureBuffersForDisplay(ImageBufferSetPrepareBufferForDisplayInputs&, SwapBuffersDisplayRequirements&);
    // Prepares the buffers that swiftEnsureBuffersForDisplay() found need display.
    SWIFT_UNSAFE void swiftPrepareBuffersForDisplay(ImageBufferSetPrepareBufferForDisplayInputs&);
    void createSnapshot(RemoteSnapshotIdentifier, WebCore::FrameIdentifier rootFrameIdentifier, WebCore::FloatSize, CreateSnapshotCompletionHandler*);
    void createSnapshotRecorder(RemoteSnapshotRecorderIdentifier, RemoteSnapshotIdentifier);
    void sinkSnapshotRecorderIntoSnapshotFrame(RemoteSnapshotRecorderIdentifier, WebCore::FrameIdentifier, SinkSnapshotRecorderIntoSnapshotFrameCompletionHandler*);
    void getImageBufferResourceLimitsForTesting(GetImageBufferResourceLimitsForTestingCompletionHandler*);

    // With the native image's platform image (null for one this process can't read), its size and its headroom.
    bool swiftCacheNativeImage(WebCore::NativeImage&, CGImageRef WTF_NULLABLE, float width, float height, float headroom, WebCore::RenderingResourceIdentifier, bool replaces);
    // Unsafe: the state must be the one the connection made, which only the destructor releases.
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    // Lets go, on the work queue, of the recordings that other threads let go of (scheduleSwiftReleases()).
    void swiftReleasePendingRecordings();

    const Ref<IPC::StreamConnectionWorkQueue> m_workQueue;
    const Ref<IPC::StreamServerConnection> m_streamConnection;
    const Ref<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    const Ref<RemoteSharedResourceCache> m_sharedResourceCache;
    // Snapshot taken on the main thread at construction and only ever read on the work queue,
    // so it needs no locking. See sharedPreferencesForWebProcess().
    const SharedPreferencesForWebProcess m_sharedPreferencesForWebProcess;
    RemoteRenderingBackendIdentifier m_renderingBackendIdentifier;
    RefPtr<WebCore::SharedMemory> m_getPixelBufferSharedMemory;
    uintptr_t m_swiftState __attribute__((availability(swift, unavailable))) { 0 };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

inline void complete(NativeImageBitmapCompletionHandler& handler, std::optional<WebCore::ShareableBitmap::Handle>&& handle) { (*handler)(WTF::move(handle)); }

#else

class RemoteDisplayListRecorder;
class RemoteImageBuffer;
class RemoteSnapshotRecorder;
struct BufferIdentifierSet;
struct ImageBufferSetPrepareBufferForDisplayOutputData;

class SWIFT_PRIVATE_FILEID("WebKit/RemoteRenderingBackend.swift") RemoteRenderingBackend : public CanMakeWeakPtr<RemoteRenderingBackend>, public IPC::StreamServerConnection::Client {
    WTF_MAKE_TZONE_ALLOCATED(RemoteRenderingBackend);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RemoteRenderingBackend);

public:
    static Ref<RemoteRenderingBackend> create(GPUConnectionToWebProcess&, RemoteRenderingBackendIdentifier, Ref<IPC::StreamServerConnection>&&);
    virtual ~RemoteRenderingBackend();
    // Once the connection has added the backend (GPUConnectionToWebProcess::swiftAddRenderingBackend()).
    void startListeningForIPC();
    SWIFT_MAIN_ACTOR void stopListeningForIPC();

    NODELETE std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;

    RemoteResourceCache& remoteResourceCache() LIFETIME_BOUND { return m_remoteResourceCache; }
    // Stands in for an image that could not be created, so that the web process can keep using its
    // identifier. Clipping to it clips everything.
    static RefPtr<WebCore::NativeImage> createPlaceholderNativeImage();
    RemoteSharedResourceCache& sharedResourceCache() { return m_sharedResourceCache; }

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    // Runs Function in RemoteRenderingBackend task queue.
    void dispatch(Function<void()>&&);

    IPC::StreamServerConnection& streamConnection() const { return m_streamConnection.get(); }
    // Ends the messages to a receiver on the stream connection: false if none receives them.
    bool tryStopReceivingMessages(IPC::ReceiverName receiverName, uint64_t destinationID)
    {
        assertIsCurrent(workQueue());
        return m_streamConnection->tryStopReceivingMessages(receiverName, destinationID);
    }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { IPC::StreamMessageReceiver::ref(); }
    void deref() const { IPC::StreamMessageReceiver::deref(); }
#endif

    GPUConnectionToWebProcess& gpuConnectionToWebProcess() { return m_gpuConnectionToWebProcess.get(); }

    void setSharedMemoryForGetPixelBuffer(RefPtr<WebCore::SharedMemory> memory) { m_getPixelBufferSharedMemory = WTF::move(memory); }
    RefPtr<WebCore::SharedMemory> sharedMemoryForGetPixelBuffer() const { return m_getPixelBufferSharedMemory; }

    IPC::StreamConnectionWorkQueue& workQueue() const { return m_workQueue; }

    // With the CG renderer in Swift, implemented in Swift (RemoteRenderingBackend.swift), on its registry of image buffers.
    RefPtr<WebCore::ImageBuffer> imageBuffer(WebCore::RenderingResourceIdentifier);

    RefPtr<WebCore::ImageBuffer> allocateImageBuffer(const WebCore::FloatSize& logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, const WebCore::ColorSpace&, WebCore::ImageBufferFormat, WebCore::ImageBufferCreationContext, std::optional<ImageBufferBackendHandle>&& providedBackingStore);
    RefPtr<WebCore::ImageBuffer> allocateImageBuffer(const WebCore::FloatSize& logicalSize, WebCore::RenderingMode renderingMode, WebCore::RenderingPurpose purpose, float resolutionScale, const WebCore::ColorSpace& colorSpace, WebCore::ImageBufferFormat bufferFormat, WebCore::ImageBufferCreationContext creationContext)
    {
        return allocateImageBuffer(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, WTF::move(creationContext), std::nullopt);
    }
    // With no creation context or backing store, for Swift, which can't pass an rvalue reference.
    RefPtr<WebCore::ImageBuffer> allocateImageBuffer(const WebCore::FloatSize& logicalSize, WebCore::RenderingMode renderingMode, WebCore::RenderingPurpose purpose, float resolutionScale, const WebCore::ColorSpace& colorSpace, WebCore::ImageBufferFormat bufferFormat)
    {
        return allocateImageBuffer(logicalSize, renderingMode, purpose, resolutionScale, colorSpace, bufferFormat, { }, std::nullopt);
    }

    RemoteRenderingBackendIdentifier identifier() { return m_renderingBackendIdentifier; }
private:
    friend class RemoteImageBufferSet;
    RemoteRenderingBackend(GPUConnectionToWebProcess&, RemoteRenderingBackendIdentifier, Ref<IPC::StreamServerConnection>&&);
    void workQueueInitialize();
    void workQueueUninitialize();
    template<typename T>
    IPC::Error send(T&& message) const
    {
        return m_streamConnection->send(std::forward<T>(message), m_renderingBackendIdentifier);
    }

    // IPC::StreamServerConnection::Client overrides.
    void didReceiveInvalidMessage(IPC::StreamServerConnection&, IPC::MessageName, const Vector<uint32_t>&) final;

    // Messages to be received.
    void createImageBuffer(const WebCore::FloatSize& logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, const WebCore::ColorSpace&, WebCore::ImageBufferFormat, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void createMappableImageBuffer(const WebCore::FloatSize& logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, const WebCore::ColorSpace&, WebCore::ImageBufferFormat, ImageBufferBackendHandle&& backingStore, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void createImageBufferWithBackingStore(const WebCore::FloatSize& logicalSize, WebCore::RenderingMode, WebCore::RenderingPurpose, float resolutionScale, const WebCore::ColorSpace&, WebCore::ImageBufferFormat, std::optional<ImageBufferBackendHandle>&& backingStore, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void releaseImageBuffer(WebCore::RenderingResourceIdentifier);
    // The receiver of an image buffer's messages, from its creation to its release (takeImageBuffer()): false if one already
    // has the identifier.
    bool addImageBuffer(Ref<WebCore::ImageBuffer>&&, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    RefPtr<WebCore::ImageBuffer> takeImageBuffer(WebCore::RenderingResourceIdentifier);
    void sinkImageBufferIntoNativeImage(WebCore::RenderingResourceIdentifier, WebCore::RenderingResourceIdentifier imageIdentifier);
    void moveToSerializedBuffer(WebCore::RenderingResourceIdentifier, RemoteSerializedImageBufferIdentifier);
    void moveToImageBuffer(RemoteSerializedImageBufferIdentifier, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void moveSerializedBufferToTransferHeap(RemoteSerializedImageBufferIdentifier, CompletionHandler<void(std::optional<WebCore::ImageBufferTransferIdentifier>)>&&);
    void takeTransferredBuffer(const WebCore::ImageBufferTransferHandle&, WebCore::RenderingResourceIdentifier, RemoteGraphicsContextIdentifier);
    void createDisplayListRecorder(RemoteDisplayListRecorderIdentifier);
    void sinkDisplayListRecorderIntoDisplayList(RemoteDisplayListRecorderIdentifier, RemoteDisplayListIdentifier);
    void releaseDisplayList(RemoteDisplayListIdentifier);
    void destroyGetPixelBufferSharedMemory();
    void nativeImageBitmap(WebCore::RenderingResourceIdentifier imageIdentifier, CompletionHandler<void(std::optional<WebCore::ShareableBitmap::Handle>)>&&);
    void cacheNativeImage(WebCore::ShareableBitmap::Handle&&, WebCore::RenderingResourceIdentifier);
    void cacheNativeImageFromSharedNativeImage(RemoteNativeImageReadReference&&);
    void releaseNativeImage(WebCore::RenderingResourceIdentifier);
    void cachePathImpl(Ref<WebCore::PathImpl>&&, RemotePathImplIdentifier);
    void releasePathImpl(RemotePathImplIdentifier);
    void cacheGradient(Ref<const WebCore::Gradient>&&, RemoteGradientIdentifier);
    void releaseGradient(RemoteGradientIdentifier);
    void cacheMeshGradient(Ref<WebCore::MeshGradient>&&, RemoteMeshGradientIdentifier);
    void releaseMeshGradient(RemoteMeshGradientIdentifier);
    void cacheFilter(Ref<WebCore::Filter>&&);
    void releaseFilter(WebCore::RenderingResourceIdentifier);
    void cacheFont(const WebCore::FontInternalAttributes&, WebCore::FontPlatformDataAttributes, std::optional<WebCore::RenderingResourceIdentifier>);
    void releaseFont(WebCore::RenderingResourceIdentifier);
    void cacheFontCustomPlatformData(WebCore::FontCustomPlatformSerializedData&&);
    void releaseFontCustomPlatformData(WebCore::RenderingResourceIdentifier);
    void releaseMemory();
    void finalizeRenderingUpdate(RenderingUpdateID);
    void markSurfacesVolatile(MarkSurfacesAsVolatileRequestIdentifier, const Vector<std::pair<ImageBufferSetIdentifier, OptionSet<BufferInSetType>>>&, bool forcePurge);
    void createImageBufferSet(WebKit::ImageBufferSetIdentifier, RemoteGraphicsContextIdentifier);
    void releaseImageBufferSet(WebKit::ImageBufferSetIdentifier);

#if USE(GRAPHICS_LAYER_WC)
    void flush(IPC::Semaphore&&);
#endif

#if PLATFORM(COCOA)
    void prepareImageBufferSetsForDisplay(Vector<ImageBufferSetPrepareBufferForDisplayInputData> swapBuffersInput);
    void prepareImageBufferSetsForDisplaySync(Vector<ImageBufferSetPrepareBufferForDisplayInputData> swapBuffersInput, CompletionHandler<void(Vector<SwapBuffersDisplayRequirement>&&)>&&);
#endif

    void createSnapshot(RemoteSnapshotIdentifier, WebCore::FrameIdentifier rootFrameIdentifier, const WebCore::FloatSize&, CompletionHandler<void()>&&);
    void createSnapshotRecorder(RemoteSnapshotRecorderIdentifier, RemoteSnapshotIdentifier);
    void sinkSnapshotRecorderIntoSnapshotFrame(RemoteSnapshotRecorderIdentifier, WebCore::FrameIdentifier, CompletionHandler<void(bool)>&&);

    NODELETE bool shouldUseLockdownFontParser() const;

    void getImageBufferResourceLimitsForTesting(CompletionHandler<void(WebCore::ImageBufferResourceLimits)>&&);


    const Ref<IPC::StreamConnectionWorkQueue> m_workQueue;
    const Ref<IPC::StreamServerConnection> m_streamConnection;
    const Ref<GPUConnectionToWebProcess> m_gpuConnectionToWebProcess;
    const Ref<RemoteSharedResourceCache> m_sharedResourceCache;
    // Snapshot taken on the main thread at construction and only ever read on the work queue,
    // so it needs no locking. See sharedPreferencesForWebProcess().
    const SharedPreferencesForWebProcess m_sharedPreferencesForWebProcess;
    RemoteResourceCache m_remoteResourceCache;
    WebCore::ProcessIdentity m_resourceOwner;
    RemoteRenderingBackendIdentifier m_renderingBackendIdentifier;
    RefPtr<WebCore::SharedMemory> m_getPixelBufferSharedMemory;

    HashMap<WebCore::RenderingResourceIdentifier, IPC::ScopedActiveMessageReceiveQueue<RemoteImageBuffer>> m_remoteImageBuffers WTF_GUARDED_BY_CAPABILITY(workQueue());

    HashMap<ImageBufferSetIdentifier, IPC::ScopedActiveMessageReceiveQueue<RemoteImageBufferSet>> m_remoteImageBufferSets WTF_GUARDED_BY_CAPABILITY(workQueue());
    HashMap<RemoteDisplayListRecorderIdentifier, IPC::ScopedActiveMessageReceiveQueue<RemoteDisplayListRecorder>> m_remoteDisplayListRecorders WTF_GUARDED_BY_CAPABILITY(workQueue());
    HashMap<RemoteSnapshotRecorderIdentifier, IPC::ScopedActiveMessageReceiveQueue<RemoteSnapshotRecorder>> m_remoteSnapshotRecorders WTF_GUARDED_BY_CAPABILITY(workQueue());
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

bool isSmallLayerBacking(const WebCore::ImageBufferParameters&);

// IPC::tryStartReceivingSwiftMessages() on the backend's stream connection, for the Swift receivers that the backend's
// handlers make.
template<typename ForwarderRef>
bool tryStartReceivingSwiftMessages(RemoteRenderingBackend& backend, const ForwarderRef& forwarder, IPC::ReceiverName receiverName, uint64_t destinationID)
{
    return IPC::tryStartReceivingSwiftMessages(backend.streamConnection(), forwarder, receiverName, destinationID);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS)
