/*
 * Copyright (c) 2021-2022 Apple Inc. All rights reserved.
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

#import "Instance.h"
#import <CoreVideo/CVMetalTextureCache.h>
#import <CoreVideo/CVPixelBuffer.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakPtr.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

#if !defined(__swift__)
namespace WebGPU {
class QueueImpl;
}
#endif

namespace WebGPU::Metal {

class Buffer;
class CommandBuffer;
class CommandEncoder;
class Device;
class Texture;
class TextureView;

// Opaque box holding the Swift QueueImpl; defined in Queue.mm.
struct QueueImplBox;

// Host mirror of the MSL `WebKitCopyExternalImageArgs` in Queue.swift. It is a hand-maintained ABI: Queue.mm pins the
// size and every offset with static_asserts. Every field is a scalar or an array of scalars: MSL lays those out exactly
// as C does, while its vector and matrix types carry alignment rules of their own.
struct CopyExternalImageArguments {
    uint32_t sourceOriginX;
    uint32_t sourceOriginY;
    uint32_t destinationOriginX;
    uint32_t destinationOriginY;
    uint32_t copyWidth;
    uint32_t copyHeight;
    uint32_t sourceMaxX;
    uint32_t sourceMaxY;
    uint32_t flags;
    float colorMatrix[9]; // Row-major.
    // A video frame's simd::float3x2 crop and simd::float4x3 YCbCr matrices, flattened column-major.
    // Flattened because a simd float3 column is padded to 16 bytes, so neither matrix has a size the
    // arithmetic would guess right.
    float uvRemapMatrix[6];
    float ycbcrMatrix[12];
};

// The scalars of a WebGPU::ImageCopyExternalImage, handed to Swift in one value. Its IOSurface and pixel buffer
// are passed alongside.
struct CopyExternalImageSource {
    std::optional<WebGPU::TextureFormat> sourceFormat;
    WebGPU::Extent2D sourceSize;
    WebGPU::VideoFrameRotation pixelBufferRotation { WebGPU::VideoFrameRotation::None };
    bool pixelBufferIsMirrored { false };
    WebGPU::Origin2D origin;
    bool flipY { false };
    bool hasAlpha { true };
    bool premultipliedAlpha { true };
    WebGPU::PredefinedColorSpace colorSpace { WebGPU::PredefinedColorSpace::SRGB };
};

// Bytes an entry point lends to QueueImpl for the duration of the call. Imported as ~Escapable, so Swift reads them as
// a lifetime-checked Span<UInt8>, with no `unsafe`.
struct SWIFT_VIEW QueueBytes {
    std::span<const uint8_t> bytes;
    std::span<const uint8_t> span() const LIFETIME_BOUND { return bytes; }
};

// https://gpuweb.github.io/gpuweb/#gpuqueue
// A device owns its default queue, not the other way around.
// The state is in QueueImpl, except the Device and Instance weak pointers and the Metal handlers, whose work items call
// QueueImpl's drains.
class Queue final : public WebGPU::Queue {
    WTF_MAKE_TZONE_ALLOCATED(Queue);
public:
    static Ref<Queue> create(id<MTLCommandQueue>, Adapter&, Device&);
    static Ref<Queue> createInvalid(Adapter&, Device&);

    ~Queue();

    // The callback is called with false when the device is lost.
    void onSubmittedWorkDone(CompletionHandler<void(bool)>&& callback);
    void submit(Vector<Ref<WebGPU::Metal::CommandBuffer>>&& commands);
    void writeBuffer(Buffer&, uint64_t bufferOffset, std::span<uint8_t> data);
    void writeBuffer(id<MTLBuffer>, uint64_t bufferOffset, std::span<uint8_t> data);
    void clearBuffer(id<MTLBuffer>, NSUInteger offset = 0, NSUInteger size = NSUIntegerMax);
    void writeTexture(const WebGPU::TexelCopyTextureInfo& destination, std::span<uint8_t> data, const WebGPU::TexelCopyBufferLayout&, const WebGPU::Extent3D& writeSize, bool skipValidation = false);
    void copyExternalImageToTexture(const WebGPU::ImageCopyExternalImage& source, const WebGPU::ImageCopyTextureTagged& destination, const WebGPU::Extent3D& copySize) final;
    void setLabel(String&&) final;

    void submit(Vector<Ref<WebGPU::CommandBuffer>>&&) final;
    void onSubmittedWorkDone(CompletionHandler<void()>&&) final;
    void writeBuffer(WebGPU::Buffer&, uint64_t bufferOffset, std::span<const uint8_t> data) final;
    void writeTexture(const WebGPU::TexelCopyTextureInfo& destination, std::span<const uint8_t> data, const WebGPU::TexelCopyBufferLayout&, const WebGPU::Extent3D& writeSize) final;
    void writeBuffer(WebGPU::Buffer&, uint64_t bufferOffset, Ref<WebGPU::ByteOwner>&& data) final;
    void writeTexture(const WebGPU::TexelCopyTextureInfo& destination, Ref<WebGPU::ByteOwner>&& data, const WebGPU::TexelCopyBufferLayout&, const WebGPU::Extent3D& writeSize) final;

    void onSubmittedWorkScheduled(Function<void()>&&);

    bool isValid() const final;
#if !defined(__swift__)
    WebGPU::QueueImpl& swiftImpl() const LIFETIME_BOUND;
#endif
    void makeInvalid();

#if !defined(__swift__)
    // For the C API. The device must be alive.
    Ref<Device> device() const;
#endif
    void generateAValidationError(String&&);
    id<MTLCommandBuffer> _Nullable commandBufferWithDescriptor(MTLCommandBufferDescriptor*);
    void commitMTLCommandBuffer(id<MTLCommandBuffer>);
    void removeMTLCommandBuffer(id<MTLCommandBuffer>);
    void setEncoderForBuffer(id<MTLCommandBuffer>, id<MTLCommandEncoder>);
    id<MTLCommandEncoder> _Nullable encoderForBuffer(id<MTLCommandBuffer>) const;
    // False when the view could not be zero-filled, so nothing may read it.
    bool clearTextureViewIfNeeded(TextureView&);
    bool clearTextureViewIfNeeded(Texture&);
    void endEncoding(id<MTLCommandEncoder>, id<MTLCommandBuffer>) const;

    id<MTLBlitCommandEncoder> ensureBlitCommandEncoder();
    void finalizeBlitCommandEncoder();

    // This can be called on a background thread. It never references the Instance.
    void scheduleWork(Instance::WorkItem&&);
    [[nodiscard]] uint64_t retainCounterSampleBuffer(CommandEncoder&);
    // API thread only.
    void releaseCounterSampleBuffer(uint64_t);
    void retainTimestampsForOneUpdate(NSMutableSet<id<MTLCounterSampleBuffer>> *);
    void waitForAllCommitedWorkToComplete();
    void synchronizeResourceAndWait(id<MTLBuffer>);
    std::pair<id<MTLBuffer>, uint64_t> newTemporaryBufferWithBytes(std::span<uint8_t> data, bool noCopy);

    // Primitives Queue.swift calls. Public because SWIFT_PRIVATE_FILEID only opens non-public members to extensions
    // of this class, not to QueueImpl. Each reads the weak Device or Instance pointer, registers Metal handlers, or
    // hands Metal the bytes of a C struct; none calls back into QueueImpl. The ones that move bytes are free
    // functions, below the class.
    void resolveDeviceTimestamps(id<MTLCommandBuffer>) const;
    void loseTheDevice(WebGPU::DeviceLostReason);
    void retainDeviceUntilCompleted(id<MTLCommandBuffer> _Nullable);
    void addCommitHandlers(id<MTLCommandBuffer>);
    static void setStagedCopyArguments(id<MTLComputeCommandEncoder>, uint64_t sourceWordOffset, uint64_t destinationWordOffset, uint64_t wordCount);
    static void setCopyExternalImageArguments(id<MTLRenderCommandEncoder>, const CopyExternalImageArguments&);

private:
    Queue(std::unique_ptr<QueueImplBox>&&, Adapter&, Device&);

    // API-thread only. The Metal handlers capture the box's QueueCompletion, which is Sendable, instead.
    const std::unique_ptr<QueueImplBox> m_impl;
    ThreadSafeWeakPtr<Device> m_device; // The only kind of queues that exist right now are default queues, which are owned by Devices.
    // Read on the API thread only; Metal threads schedule work through the box's scheduler handle.
    const ThreadSafeWeakPtr<Instance> m_instance;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(refQueue, derefQueue) SWIFT_PRIVATE_FILEID("WebGPU/Queue.swift");

// Byte-moving primitives for Queue.swift. Free functions with NOESCAPE spans, so that Swift gets overloads taking
// Span<UInt8>; static members of Queue, a foreign reference type, would not get them (rdar://161274084).

// The texel block of the format a texture write copies, from which replaceRegion() computes the bytes Metal reads.
struct TexelBlockLayout {
    uint32_t width { 1 };
    uint32_t height { 1 };
    uint32_t size { 0 };
};

void writeBufferContents(id<MTLBuffer>, uint64_t bufferOffset, std::span<const uint8_t> data NOESCAPE);
void copyBytesToBuffer(id<MTLBuffer> _Nullable, uint64_t offset, std::span<const uint8_t> data NOESCAPE);
// RELEASE_ASSERTs that every byte Metal reads, from sourceOffset on, is inside `data`.
void replaceRegion(id<MTLTexture> _Nullable, MTLRegion, uint32_t mipLevel, uint64_t slice, std::span<const uint8_t> data NOESCAPE, uint64_t sourceOffset, uint64_t bytesPerRow, uint64_t bytesPerImage, TexelBlockLayout);
// A buffer over `length` bytes of the ByteOwner from `offset`, which keeps the ByteOwner alive for as long as it exists.
// Null when the ByteOwner has fewer bytes.
id<MTLBuffer> _Nullable newBufferAliasingOwner(const Device&, const WebGPU::ByteOwner&, uint64_t offset, uint64_t length);

// For ExternalTextureImport.swift: a plane's bytes, through a raw pointer, into as much of the texture as both have, when
// the plane's rows hold `bytesPerPixel` bytes (those of the texture's format; 0 if unknown) for every pixel copied. The
// base address must be locked.
void copyPixelBufferPlane(id<MTLTexture>, CVPixelBufferRef, size_t plane, size_t bytesPerPixel);

// CoreVideo calls for ExternalTextureImport.swift, with their results returned: CVPixelBufferGetIOSurface is not
// audited for Swift, which would get an Unmanaged reference, and the others write through out-parameters, which Swift
// can only pass as unsafe pointers.
IOSurfaceRef _Nullable pixelBufferIOSurface(CVPixelBufferRef) CF_RETURNS_NOT_RETAINED;
#if HAVE(COREVIDEO_METAL_SUPPORT)
CVMetalTextureCacheRef _Nullable createCoreVideoTextureCache(id<MTLDevice>) CF_RETURNS_RETAINED;
// Null unless CoreVideo succeeded.
CVMetalTextureRef _Nullable createCoreVideoPlaneTexture(CVMetalTextureCacheRef, CVPixelBufferRef, MTLPixelFormat, size_t plane) CF_RETURNS_RETAINED;
// The coordinates of a plane's clean aperture that the import's UV remapping needs.
struct CleanTexCoords {
    float lowerLeftX { 0 };
    float lowerRightY { 0 };
    float upperRightX { 0 };
    float upperLeftY { 0 };
};
CleanTexCoords cleanTexCoords(CVMetalTextureRef);
#endif

} // namespace WebGPU::Metal

#if !ENABLE(SWIFT_BASE_CLASS_ANNOTATIONS)
inline void refQueue(WebGPU::Metal::Queue* obj)
{
    obj->ref();
}

inline void derefQueue(WebGPU::Metal::Queue* obj)
{
    obj->deref();
}
#endif

IGNORE_CLANG_WARNINGS_END
