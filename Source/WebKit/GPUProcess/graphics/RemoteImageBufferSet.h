/*
 * Copyright (C) 2020-2023 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(GPU_PROCESS)

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && !ENABLE(RE_DYNAMIC_CONTENT_SCALING)

#include "ImageBufferBackendHandleSharing.h"
#include "ImageBufferSetIdentifier.h"
#include "PrepareBackingStoreBuffersData.h"
#include "RemoteGraphicsContextIdentifier.h"
#include "RemoteImageBufferSetConfiguration.h"
#include "RemoteRenderingBackend.h"
#include "RenderingUpdateID.h"
#include "StreamMessageReceiver.h"
#include "StreamServerConnection.h"
#include <WebCore/ImageBuffer.h>
#include <wtf/SwiftBridging.h>

namespace WebKit {

// A set's buffers, as the end of its preparation for display leaves them.
struct RemoteImageBufferSetBuffers {
    RefPtr<WebCore::ImageBuffer> front;
    RefPtr<WebCore::ImageBuffer> back;
    RefPtr<WebCore::ImageBuffer> secondaryBack;

    static RemoteImageBufferSetBuffers make(RefPtrImageBuffer front, RefPtrImageBuffer back, RefPtrImageBuffer secondaryBack) { return { WTF::move(front), WTF::move(back), WTF::move(secondaryBack) }; }
};

// The image buffers of a layer: the front buffer that a rendering update draws into, and the back buffers that the display
// may still show. Implemented in Swift (RemoteImageBufferSet.swift), on the state that m_swiftState holds, on the rendering
// backend's work queue; the replies that hold C++ handles are made here.
class SWIFT_PRIVATE_FILEID("WebKit/RemoteImageBufferSet.swift") RemoteImageBufferSet final : public IPC::StreamMessageReceiver {
public:
    static Ref<RemoteImageBufferSet> create(ImageBufferSetIdentifier identifier, RemoteGraphicsContextIdentifier contextIdentifier, RemoteRenderingBackend& backend)
    {
        Ref set = adoptRef(*new RemoteImageBufferSet(identifier, createSwiftState(contextIdentifier, backend), backend));
        backend.streamConnection().startReceivingMessages(set.get(), IPC::ReceiverName::RemoteImageBufferSet, identifier.toUInt64());
        return set;
    }
    ~RemoteImageBufferSet() { destroySwiftState(m_swiftState); }
    void stopListeningForIPC() { m_renderingBackend->streamConnection().stopReceivingMessages(IPC::ReceiverName::RemoteImageBufferSet, m_identifier.toUInt64()); }
    void ref() const { StreamMessageReceiver::ref(); }
    void deref() const { StreamMessageReceiver::deref(); }

    // Makes the front buffer valid, by swapping in a back buffer or allocating one, and, unless it needs no display, starts
    // receiving its drawing. For a full display, the dirty region becomes the layer's bounds.
    SwapBuffersDisplayRequirement ensureBufferForDisplay(ImageBufferSetPrepareBufferForDisplayInputData&, bool isSync);
    // Copies what the dirty region leaves of the previous frame into the new front buffer, clips to the region, and clears
    // the pixels to be drawn, unless drawing will be opaque.
    void prepareBufferForDisplay(WebCore::Region dirtyRegion, bool requiresClearedPixels);
    bool makeBuffersVolatile(OptionSet<BufferInSetType> requestedBuffers, OptionSet<BufferInSetType>& volatileBuffers, bool forcePurge)
    {
        auto result = swiftMakeBuffersVolatile(requestedBuffers.toRaw(), forcePurge);
        volatileBuffers = OptionSet<BufferInSetType>::fromRaw(result & 0xff);
        return !(result & swiftSomeBuffersStayedNonVolatile);
    }
    bool isPreparingForDisplay() const;

private:
    RemoteImageBufferSet(ImageBufferSetIdentifier identifier, uintptr_t swiftState, RemoteRenderingBackend& backend)
        : m_identifier(identifier)
        , m_renderingBackend(backend)
        , m_swiftState(swiftState)
    {
    }

    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    // Messages
    void updateConfiguration(RemoteImageBufferSetConfiguration);
    void endPrepareForDisplay(RenderingUpdateID renderingUpdateID, CompletionHandler<void(ImageBufferSetPrepareBufferForDisplayOutputData, RenderingUpdateID)>&& completionHandler)
    {
        ImageBufferSetPrepareBufferForDisplayOutputData outputData;
        auto buffers = swiftEndPrepareForDisplay();
        auto identifier = [](const RefPtr<WebCore::ImageBuffer>& buffer) -> std::optional<WebCore::RenderingResourceIdentifier> {
            return buffer ? std::optional { buffer->renderingResourceIdentifier() } : std::nullopt;
        };
        // The handle is a C++ variant.
        if (buffers.front)
            outputData.backendHandle = downcast<ImageBufferBackendHandleSharing>(*buffers.front->toBackendSharing()).createBackendHandle();
        outputData.bufferCacheIdentifiers = { identifier(buffers.front), identifier(buffers.back), identifier(buffers.secondaryBack) };
        // If we failed to allocate a front buffer then nothing was painted, so let the web process know that it needs to
        // repaint the whole layer next time.
        if (!buffers.front)
            outputData.displayRequirement = SwapBuffersDisplayRequirement::NeedsFullDisplay;
        completionHandler(WTF::move(outputData), renderingUpdateID);
    }
    void submitDrawingCommands();

    // Stops receiving the front buffer's drawing, flushes it, and returns the buffers.
    RemoteImageBufferSetBuffers swiftEndPrepareForDisplay();
    // The BufferInSetType raw values of the buffers it made volatile, and swiftSomeBuffersStayedNonVolatile if it failed to
    // make one volatile.
    // rdar://191583570
    uint16_t swiftMakeBuffersVolatile(uint8_t requestedBuffers, bool forcePurge);
    static constexpr uint16_t swiftSomeBuffersStayedNonVolatile = 1 << 8;
    static uintptr_t createSwiftState(RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);
    SWIFT_UNSAFE static void destroySwiftState(uintptr_t);
    uintptr_t swiftState() const { return m_swiftState; }
    ImageBufferSetIdentifier identifier() const { return m_identifier; }

    const ImageBufferSetIdentifier m_identifier;
    const Ref<RemoteRenderingBackend> m_renderingBackend;
    const uintptr_t m_swiftState;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

using RefRemoteImageBufferSet = Ref<RemoteImageBufferSet>;

} // namespace WebKit

#else

#include "IPCEvent.h"
#include <wtf/SwiftBridging.h>
#include "ImageBufferSetIdentifier.h"
#include "PrepareBackingStoreBuffersData.h"
#include "RemoteGraphicsContextIdentifier.h"
#include "RemoteImageBufferSetConfiguration.h"
#include "RenderingUpdateID.h"
#include "ScopedActiveMessageReceiveQueue.h"
#include "StreamConnectionWorkQueue.h"
#include "StreamMessageReceiver.h"
#include <WebCore/ImageBuffer.h>

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
#include <WebCore/DynamicContentScalingDisplayList.h>
#endif

namespace WebKit {

class RemoteImageBufferGraphicsContext;
class RemoteRenderingBackend;

class RemoteImageBufferSet : public IPC::StreamMessageReceiver {
public:
    static Ref<RemoteImageBufferSet> create(ImageBufferSetIdentifier, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);
    ~RemoteImageBufferSet();
    void stopListeningForIPC();

    // Ensures frontBuffer is valid, either by swapping an existing back
    // buffer, or allocating a new one.
    SwapBuffersDisplayRequirement ensureBufferForDisplay(ImageBufferSetPrepareBufferForDisplayInputData& inputData, bool isSync)
    {
        auto displayRequirement = SwapBuffersDisplayRequirement::NeedsNormalDisplay;
        ensureBufferForDisplay(inputData, displayRequirement, isSync);
        return displayRequirement;
    }

    // Initializes the contents of the new front buffer using the previous
    // frames (if applicable), clips to the dirty region, and clears the pixels
    // to be drawn (unless drawing will be opaque).
    void prepareBufferForDisplay(const WebCore::Region& dirtyRegion, bool requiresClearedPixels);

    bool makeBuffersVolatile(OptionSet<BufferInSetType> requestedBuffers, OptionSet<BufferInSetType>& volatileBuffers, bool forcePurge);

    bool isPreparingForDisplay() const { return m_context.get(); }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the type hierarchy.
    void ref() const { IPC::StreamMessageReceiver::ref(); }
    void deref() const { IPC::StreamMessageReceiver::deref(); }
#endif

private:
    RemoteImageBufferSet(ImageBufferSetIdentifier, RemoteGraphicsContextIdentifier, RemoteRenderingBackend&);

    void startListeningForIPC();
    NODELETE IPC::StreamConnectionWorkQueue& workQueue() const;

    void ensureBufferForDisplay(ImageBufferSetPrepareBufferForDisplayInputData&, SwapBuffersDisplayRequirement&, bool isSync);

    // Tries to swap one of the existing back buffers to the new front buffer, if any are
    // not currently in-use.
    SwapBuffersDisplayRequirement swapBuffersForDisplay(bool hasEmptyDirtyRegion, bool supportsPartialRepaint);

    // IPC::StreamMessageReceiver
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;

    // Messages
    void updateConfiguration(const RemoteImageBufferSetConfiguration&);
    void endPrepareForDisplay(RenderingUpdateID, CompletionHandler<void(ImageBufferSetPrepareBufferForDisplayOutputData, RenderingUpdateID)>&&);
    void submitDrawingCommands();

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    void dynamicContentScalingDisplayList(CompletionHandler<void(std::optional<WebCore::DynamicContentScalingDisplayList>&&)>&&);
    WebCore::DynamicContentScalingResourceCache ensureDynamicContentScalingResourceCache();
#endif

    bool isOpaque() const
    {
        return pixelFormatIsOpaque(m_configuration.bufferFormat.pixelFormat);
    }

    const ImageBufferSetIdentifier m_identifier;
    const RemoteGraphicsContextIdentifier m_contextIdentifier;
    const Ref<RemoteRenderingBackend> m_renderingBackend;
    RefPtr<WebCore::ImageBuffer> m_frontBuffer;
    RefPtr<WebCore::ImageBuffer> m_backBuffer;
    RefPtr<WebCore::ImageBuffer> m_secondaryBackBuffer;
    std::optional<WebCore::IntRect> m_previouslyPaintedRect;
    bool m_frontBufferIsCleared { false };
    RemoteImageBufferSetConfiguration m_configuration;
    IPC::ScopedActiveMessageReceiveQueue<RemoteImageBufferGraphicsContext> m_context;

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    WebCore::DynamicContentScalingResourceCache m_dynamicContentScalingResourceCache;
#endif
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// RemoteRenderingBackend.swift keeps the sets with dynamic content scaling too.
using RefRemoteImageBufferSet = Ref<RemoteImageBufferSet>;


} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT) && !ENABLE(RE_DYNAMIC_CONTENT_SCALING)

#endif // ENABLE(GPU_PROCESS)
