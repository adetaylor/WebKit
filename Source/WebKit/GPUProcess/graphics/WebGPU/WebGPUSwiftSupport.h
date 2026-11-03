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
#include <WebCore/SharedMemory.h>
#include <WebCore/WebGPUCppAPI.h>
#include <concepts>
#include <memory>
#include <type_traits>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/WeakPtr.h>

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
    WebGPUSwiftRegistryHost(WebGPU::ObjectHeap&, RemoteGPU&);

    std::optional<SharedPreferencesForWebProcess> sharedPreferencesForWebProcess() const;
    RefPtr<IPC::StreamServerConnection> streamConnection() const;

    // Makes the device's XR binding, and its receiver. False if the device makes none.
    bool addXRBinding(::WebGPU::Device&, uint64_t identifier) const;
    // Adds a device to those that RemoteGPU destroys when its work queue stops.
    void trackDevice(::WebGPU::Device&) const;

    // A queue's WriteTexture message, as RemoteQueue handles it. Returns false if there's no shared memory, or no more
    // than the message could have carried in the stream.
    bool writeSharedMemoryToTexture(::WebGPU::Queue&, IPC::CxxDecodedArgument<WebGPU::ImageCopyTexture>&, IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>&, IPC::CxxDecodedArgument<WebGPU::ImageDataLayout>&, IPC::CxxDecodedArgument<WebGPU::Extent3D>&) const;
    // A queue's CopyExternalImageToTexture message, as RemoteQueue handles it: the source is an image buffer of the
    // RemoteGPU's rendering backend, which WebCore's WebGPU integration copies from.
    void copyExternalImageToTexture(::WebGPU::Queue&, IPC::CxxDecodedArgument<WebGPU::ImageCopyExternalImage>&, IPC::CxxDecodedArgument<WebGPU::ImageCopyTextureTagged>&, IPC::CxxDecodedArgument<WebGPU::Extent3D>&) const;

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

// The C++ API objects that Swift receivers and the registry pass to C++, and that C++ passes to them. Swift can't
// name the ::WebGPU types in the C++ it generates: it names them WebGPU::..., which inside namespace WebKit means
// WebKit::WebGPU::....
class RemoteBufferBacking {
public:
    explicit RemoteBufferBacking(::WebGPU::Buffer& backing)
        : m_backing(backing)
    {
    }

    ::WebGPU::Buffer& get() const SWIFT_RETURNS_UNRETAINED { return m_backing; }

private:
    Ref<::WebGPU::Buffer> m_backing;
} SWIFT_SELF_CONTAINED;

using OptionalRemoteBufferBacking = std::optional<RemoteBufferBacking>;

// Copies the shared memory that a buffer's Copy message gives into the buffer at that offset, as the C++ receiver does.
// Returns false if there's none, or no more than the message could have carried in the stream.
bool copySharedMemoryToBuffer(::WebGPU::Buffer&, IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>&, uint64_t offset);
// A queue's WriteBuffer message, as RemoteQueue handles it: the queue reads the shared memory in place, and keeps it
// until the GPU has. Returns false if there's none, or no more than the message could have carried in the stream.
bool writeSharedMemoryToBuffer(::WebGPU::Queue&, ::WebGPU::Buffer&, IPC::CxxDecodedArgument<std::optional<WebCore::SharedMemory::Handle>>&, uint64_t bufferOffset);

class RemoteDeviceBacking {
public:
    explicit RemoteDeviceBacking(::WebGPU::Device& backing)
        : m_backing(backing)
    {
    }

    ::WebGPU::Device& get() const SWIFT_RETURNS_UNRETAINED { return m_backing; }

private:
    Ref<::WebGPU::Device> m_backing;
} SWIFT_SELF_CONTAINED;

using OptionalRemoteDeviceBacking = std::optional<RemoteDeviceBacking>;

class RemoteTextureBacking {
public:
    explicit RemoteTextureBacking(::WebGPU::Texture& backing)
        : m_backing(backing)
    {
    }

    ::WebGPU::Texture& get() const SWIFT_RETURNS_UNRETAINED { return m_backing; }

private:
    Ref<::WebGPU::Texture> m_backing;
} SWIFT_SELF_CONTAINED;

using OptionalRemoteTextureBacking = std::optional<RemoteTextureBacking>;

class RemoteExternalTextureBacking {
public:
    explicit RemoteExternalTextureBacking(::WebGPU::ExternalTexture& backing)
        : m_backing(backing)
    {
    }

    ::WebGPU::ExternalTexture& get() const SWIFT_RETURNS_UNRETAINED { return m_backing; }

private:
    Ref<::WebGPU::ExternalTexture> m_backing;
} SWIFT_SELF_CONTAINED;

using OptionalRemoteExternalTextureBacking = std::optional<RemoteExternalTextureBacking>;

#if PLATFORM(COCOA) && ENABLE(VIDEO)
// A device receiver's reader of the video frames that the web process shares with it, and its imports of video frames
// as external textures, which take WebCore's media types.
class WebGPUSwiftVideoFrames final : public RefCounted<WebGPUSwiftVideoFrames> {
public:
    // Null if the RemoteGPU or its connection to the web process has gone.
    static WebGPUSwiftVideoFrames* WTF_NULLABLE create(const WebGPUSwiftRegistryHost&) SWIFT_RETURNS_RETAINED;

    ~WebGPUSwiftVideoFrames();

    void setSemaphore(IPC::CxxDecodedArgument<IPC::Semaphore>&);
    void setSharedMemory(IPC::CxxDecodedArgument<WebCore::SharedMemory::Handle>&);

    // Imports the video frame that the descriptor names for the device, as RemoteDevice does. std::nullopt with isInvalid
    // set if the message is invalid, and std::nullopt alone if WebGPU has gone.
    OptionalRemoteExternalTextureBacking importExternalTexture(::WebGPU::Device&, IPC::CxxDecodedArgument<WebGPU::ExternalTextureDescriptor>&, bool& isInvalid);
    // Gives the external texture the frame that the media player is showing, as RemoteDevice does.
    void updateExternalTexture(::WebGPU::ExternalTexture&, uint64_t mediaPlayerIdentifier);
    // A queue's CopyExternalImageFromVideoFrameToTexture message, as RemoteQueue handles it.
    void copyExternalImageFromVideoFrameToTexture(::WebGPU::Queue&, IPC::CxxDecodedArgument<WebGPU::ImageCopyExternalImageVideoSource>&, IPC::CxxDecodedArgument<WebGPU::ImageCopyTextureTagged>&, IPC::CxxDecodedArgument<WebGPU::Extent3D>&);

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
