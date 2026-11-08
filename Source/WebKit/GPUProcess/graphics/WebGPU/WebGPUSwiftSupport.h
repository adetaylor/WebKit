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

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)

#include "IPCSemaphore.h"
#include "MessageReceiver.h"
#include "RemoteGPURequestAdapterResponse.h"
#include "SharedPreferencesForWebProcess.h"
#include "StreamServerConnection.h"
#include "SwiftCoding.h"
#include "WebGPUExtent3D.h"
#include "WebGPUExternalTextureDescriptor.h"
#include "WebGPUIdentifier.h"
#include "WebGPUImageCopyExternalImage.h"
#include "WebGPUImageCopyTexture.h"
#include "WebGPUImageCopyTextureTagged.h"
#include "WebGPUImageDataLayout.h"
#include "WebGPURequestAdapterOptions.h"
#include <WebCore/SharedMemory.h>
#include <WebCore/WebGPUCppAPI.h>
#include <concepts>
#include <memory>
#include <type_traits>
#include <wtf/CompletionHandler.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

#if PLATFORM(COCOA)
#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurfaceRef.h>
#endif

namespace WebCore {
class ColorSpace;
class IOSurface;
}
#if ENABLE(WEBXR) && PLATFORM(COCOA)
#include <WebCore/PlatformXR.h>
#include <wtf/MachSendRight.h>
#endif

namespace WebKit {

class RemoteGPU;
class SharedVideoFrameReader;

namespace WebGPU {
class ObjectHeap;
}

// Whether the Swift registry of WebGPU objects has an object, and whether it's valid, for RemoteGPU::isValid().
enum class WebGPUSwiftObjectState : uint8_t {
    Absent,
    Invalid,
    Valid,
};

// What the Swift registry of WebGPU objects uses of the C++ around it: the object heap, which owns the receivers still
// written in C++, and the RemoteGPU, for its stream connection and shared preferences, both weakly.
class WebGPUSwiftRegistryHost {
public:
    friend class WebGPUCompositorRenderBuffers;

    WebGPUSwiftRegistryHost(WebGPU::ObjectHeap&, RemoteGPU&);

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;
    RefPtr<IPC::StreamServerConnection> streamConnection() const;

#if PLATFORM(COCOA)
    // The source of a queue's CopyExternalImageToTexture message, as WebCore's WebGPU integration copies from it: the
    // IOSurface of the RemoteGPU's rendering backend's image buffer with that identifier, read from the origin.
    // std::nullopt if there's nothing to copy.
    std::optional<::WebGPU::ImageCopyExternalImage> externalImage(uint64_t imageBufferIdentifier, ::WebGPU::Origin2D, bool flipY, bool premultipliedAlpha) const;
#endif

private:
    friend class WebGPUSwiftVideoFrames;

    WeakPtr<WebGPU::ObjectHeap> m_objectHeap;
    WeakPtr<RemoteGPU> m_gpu;
} SWIFT_SELF_CONTAINED;

// Keeps the messages for a WebGPU receiver written in Swift coming from the stream connection, as
// IPC::ScopedActiveMessageReceiveQueue does for a C++ receiver, until it goes.
class WebGPUSwiftReceiverRegistration final : public RefCounted<WebGPUSwiftReceiverRegistration> {
public:
    static Ref<WebGPUSwiftReceiverRegistration> create(IPC::StreamServerConnection& streamConnection, IPC::StreamMessageReceiver& receiver, IPC::ReceiverName receiverName, uint64_t identifier)
    {
        return adoptRef(*new WebGPUSwiftReceiverRegistration(streamConnection, receiver, receiverName, identifier));
    }

    ~WebGPUSwiftReceiverRegistration();

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<WebGPUSwiftReceiverRegistration>::ref(); }
    void deref() const { RefCounted<WebGPUSwiftReceiverRegistration>::deref(); }
#endif

private:
    WebGPUSwiftReceiverRegistration(IPC::StreamServerConnection&, IPC::StreamMessageReceiver&, IPC::ReceiverName, uint64_t identifier);

    const Ref<IPC::StreamServerConnection> m_streamConnection;
    const IPC::ReceiverName m_receiverName;
    const uint64_t m_identifier;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

template<typename> struct IsRefOfStreamMessageReceiver : std::false_type { };
template<typename T> struct IsRefOfStreamMessageReceiver<Ref<T>> : std::bool_constant<std::derived_from<T, IPC::StreamMessageReceiver>> { };

// Registers a Swift receiver's message forwarder for those messages, with the RemoteGPU's shared preferences. Null if
// the RemoteGPU or its stream connection has gone. A template so that Swift, which can't pass a forwarder as the
// StreamMessageReceiver it is, can pass the Ref to it that it holds. The static_assert is used because the constraint
// isn't enforced for Swift callers.
template<typename ForwarderRef>
WebGPUSwiftReceiverRegistration* WTF_NULLABLE registerWebGPUSwiftReceiver(const WebGPUSwiftRegistryHost& host, const ForwarderRef& forwarder, IPC::ReceiverName receiverName, uint64_t identifier) SWIFT_RETURNS_RETAINED
{
    static_assert(IsRefOfStreamMessageReceiver<ForwarderRef>::value);
    RefPtr streamConnection = host.streamConnection();
    if (!streamConnection)
        return nullptr;
    forwarder->setSharedPreferencesProvider([host] {
        return host.sharedPreferencesForWebProcess();
    });
    return &WebGPUSwiftReceiverRegistration::create(*streamConnection, forwarder.get(), receiverName, identifier).leakRef();
}

// The descriptor of the instance that the registry makes, which C++ makes for it: Swift can't take the descriptor, which
// can't be copied, as a parameter.
class WebGPUSwiftInstanceDescriptor final : public RefCounted<WebGPUSwiftInstanceDescriptor> {
public:
    static Ref<WebGPUSwiftInstanceDescriptor> create(::WebGPU::InstanceDescriptor&& descriptor)
    {
        return adoptRef(*new WebGPUSwiftInstanceDescriptor(WTF::move(descriptor)));
    }

    // Once.
    ::WebGPU::InstanceDescriptor take() { return std::exchange(m_descriptor, { }); }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<WebGPUSwiftInstanceDescriptor>::ref(); }
    void deref() const { RefCounted<WebGPUSwiftInstanceDescriptor>::deref(); }
#endif

private:
    explicit WebGPUSwiftInstanceDescriptor(::WebGPU::InstanceDescriptor&& descriptor)
        : m_descriptor(WTF::move(descriptor))
    {
    }

    ::WebGPU::InstanceDescriptor m_descriptor;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

#if ENABLE(WEBXR) && PLATFORM(COCOA)
// The compositor's buffers and the rasterization rate map of an XR projection layer's StartFrame message, which C++
// decodes: the send rights, which the frame owns while the Swift receiver starts the layer's frame with them, and the
// samples, which it lends.
class WebGPUXRFrame {
    WTF_MAKE_NONCOPYABLE(WebGPUXRFrame);
public:
    WebGPUXRFrame(IPC::CxxDecodedArgument<MachSendRight>& colorBuffer, IPC::CxxDecodedArgument<MachSendRight>& depthBuffer, IPC::CxxDecodedArgument<MachSendRight>& completionSyncEvent, IPC::CxxDecodedArgument<PlatformXR::RateMapDescription>&);
    WebGPUXRFrame(WebGPUXRFrame&&) = default;
    ~WebGPUXRFrame();

    // MACH_PORT_NULL for a buffer that the compositor didn't send.
    mach_port_t colorBuffer() const { return m_colorBuffer.sendRight(); }
    mach_port_t depthBuffer() const { return m_depthBuffer.sendRight(); }
    mach_port_t completionSyncEvent() const { return m_completionSyncEvent.sendRight(); }

    uint32_t screenWidth() const { return static_cast<uint32_t>(m_rateMapDescription.screenSize.width()); }
    uint32_t screenHeight() const { return static_cast<uint32_t>(m_rateMapDescription.screenSize.height()); }
    ::WebGPU::XRRasterizationSamples horizontalSamplesLeft() const LIFETIME_BOUND { return { m_rateMapDescription.horizontalSamplesLeft.span() }; }
    ::WebGPU::XRRasterizationSamples horizontalSamplesRight() const LIFETIME_BOUND { return { m_rateMapDescription.horizontalSamplesRight.span() }; }
    ::WebGPU::XRRasterizationSamples verticalSamples() const LIFETIME_BOUND { return { m_rateMapDescription.verticalSamples.span() }; }

private:
    MachSendRight m_colorBuffer;
    MachSendRight m_depthBuffer;
    MachSendRight m_completionSyncEvent;
    PlatformXR::RateMapDescription m_rateMapDescription;
} SWIFT_NONCOPYABLE;
#endif

using OptionalOwnedBytes = std::optional<::WebGPU::OwnedBytes>;

// The bytes of the shared memory that a message's handle names, mapped read-only, for a write that may read them after
// it returns. std::nullopt if there's none, or no more than the message could have carried in the stream.
OptionalOwnedBytes mapSharedMemory(IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>&);

// Whether a write with copy is no larger than the web process sends in a message (WebGPU::maxCrossProcessResourceCopySize).
bool isValidWebGPUWriteWithCopySize(size_t);



#if PLATFORM(COCOA)
// The render buffers that the compositor shows a WebGPU canvas from, which RemoteCompositorIntegration.swift makes and
// gives the canvas: IOSurfaces, whose send rights its RecreateRenderBuffers reply carries.
class WebGPUCompositorRenderBuffers final : public RefCounted<WebGPUCompositorRenderBuffers> {
public:
    static WebGPUCompositorRenderBuffers* WTF_NONNULL create() SWIFT_RETURNS_RETAINED;

    ~WebGPUCompositorRenderBuffers();

    void clear();
    // Up to three buffers, at most the largest 2D texture in size, in the IOSurface format of the texture format and the
    // alpha mode. A buffer that can't be made is left out.
    void allocate(int32_t width, int32_t height, IPC::CxxDecodedArgument<WebCore::ColorSpace>&, bool premultiplied, uint8_t textureFormat, uint32_t bufferCount);
    size_t size() const { return m_buffers.size(); }
    void setContentEDRHeadroom(float);
    // RemoteGPU's paint, into the image buffer with that identifier, of the canvas's texture image, or else of the
    // buffer's own image.
    void paint(const WebGPUSwiftRegistryHost&, CGImageRef WTF_NULLABLE textureImage, uint32_t bufferIndex, bool premultiplied, uint64_t imageBufferIdentifier) const;

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<WebGPUCompositorRenderBuffers>::ref(); }
    void deref() const { RefCounted<WebGPUCompositorRenderBuffers>::deref(); }
#endif

private:
    friend IOSurfaceRef WTF_NONNULL copyCompositorRenderBufferSurface(const WebGPUCompositorRenderBuffers&, size_t index) CF_RETURNS_RETAINED;

    WebGPUCompositorRenderBuffers();

    Vector<UniqueRef<WebCore::IOSurface>> m_buffers;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A render buffer's IOSurface, for the canvas. A function, since Swift takes what a C++ method returns as unretained.
IOSurfaceRef WTF_NONNULL copyCompositorRenderBufferSurface(const WebGPUCompositorRenderBuffers&, size_t index) CF_RETURNS_RETAINED;
#endif

#if PLATFORM(COCOA) && ENABLE(VIDEO)
// A device receiver's reader of the video frames that the web process shares with it, and its imports of video frames
// as external textures, which take WebCore's media types.
class WebGPUSwiftVideoFrames final : public RefCounted<WebGPUSwiftVideoFrames> {
public:
    // Null if the RemoteGPU or its connection to the web process has gone.
    static WebGPUSwiftVideoFrames* WTF_NULLABLE create(const WebGPUSwiftRegistryHost&) SWIFT_RETURNS_RETAINED;

    ~WebGPUSwiftVideoFrames();

    // Each takes a right of its own to the port that the receiver's IPCTypes.Semaphore or SharedMemoryHandle owns.
    void setSemaphore(mach_port_t);
    void setSharedMemory(mach_port_t, uint64_t size);

    // The descriptor of a device's ImportExternalTextureFromVideoFrame message, with the pixel buffer of the video frame
    // it names, as WebCore's WebGPU integration imports it. std::nullopt with isInvalid set if the message is invalid, and
    // std::nullopt alone if WebGPU has gone.
    std::optional<::WebGPU::ExternalTextureDescriptor> externalTextureDescriptor(IPC::CxxDecodedArgument<WebGPU::ExternalTextureDescriptor>&, bool& isInvalid);
    // The frame that the media player is showing, as a descriptor whose pixel buffer an external texture's update reads.
    // std::nullopt if the connection to the web process has gone.
    std::optional<::WebGPU::ExternalTextureDescriptor> mediaPlayerFrame(uint64_t mediaPlayerIdentifier);
    // The source of a queue's CopyExternalImageFromVideoFrameToTexture message, with the pixel buffer of the video frame it
    // names, as WebCore's WebGPU integration copies from it. std::nullopt if there's nothing to copy.
    std::optional<::WebGPU::ImageCopyExternalImage> externalImage(IPC::CxxDecodedArgument<WebGPU::ImageCopyExternalImageVideoSource>&);

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<WebGPUSwiftVideoFrames>::ref(); }
    void deref() const { RefCounted<WebGPUSwiftVideoFrames>::deref(); }
#endif

private:
    WebGPUSwiftVideoFrames(const WebGPUSwiftRegistryHost&, std::unique_ptr<SharedVideoFrameReader>&&);

    const WebGPUSwiftRegistryHost m_host;
    const std::unique_ptr<SharedVideoFrameReader> m_sharedVideoFrameReader;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);
#endif



} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
