/*
 * Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

#import "config.h"
#import "Queue.h"

#import "APIConversions.h"
#import "Buffer.h"
#import "CommandBuffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "IsValidToUseWith.h"
#import "Texture.h"
#import "TextureView.h"
#import <wtf/BlockPtr.h>
#import <wtf/Borrow.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct QueueImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(QueueImplBox);
    WebGPU::QueueImpl impl;
    // The impl's completion, taken once, so that registering the Metal handlers needs no call into Swift.
    WebGPU::QueueCompletion completion;
    // How scheduleWork() reaches the Instance's scheduler from any thread, without referencing the Instance.
    std::optional<WebGPU::InstanceSchedulerHandle> scheduler;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(QueueImplBox);

static std::unique_ptr<QueueImplBox> makeQueueImplBox(WebGPU::QueueImpl impl, Adapter& adapter)
{
    std::optional<WebGPU::InstanceSchedulerHandle> scheduler;
    if (RefPtr instance = adapter.instance())
        scheduler = instance->schedulerHandle();
    return makeUnique<QueueImplBox>(QueueImplBox { .impl = impl, .completion = impl.completion(), .scheduler = WTF::move(scheduler) });
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(Queue);

Ref<Queue> Queue::create(id<MTLCommandQueue> commandQueue, Adapter& adapter, Device& device)
{
    return adoptRef(*new Queue(makeQueueImplBox(makeQueueImpl(commandQueue), adapter), adapter, device));
}

Ref<Queue> Queue::createInvalid(Adapter& adapter, Device& device)
{
    return adoptRef(*new Queue(makeQueueImplBox(makeInvalidQueueImpl(), adapter), adapter, device));
}

Queue::Queue(std::unique_ptr<QueueImplBox>&& impl, Adapter& adapter, Device& device)
    : m_impl(WTF::move(impl))
    , m_device(device)
    , m_instance(adapter.weakInstance())
{
}

Queue::~Queue()
{
    // We can't actually call finalizeBlitCommandEncoder() here because, if there are pending copies,
    // that would cause them to be committed, which ends up retaining this in the completed handler.
    // It's actually fine, though, because we can just drop any pending copies on the floor.
    // If the queue is being destroyed, this is unobservable.
    // This must not pass the dying shell into Swift.
    if (id<MTLCommandEncoder> stagingEncoder = m_impl->impl.stagingEncoder())
        endEncoding(stagingEncoder, m_impl->impl.stagingCommandBuffer());
}

bool Queue::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPU::QueueImpl& Queue::swiftImpl() const
{
    return m_impl->impl;
}

id<MTLBlitCommandEncoder> Queue::ensureBlitCommandEncoder()
{
    return m_impl->impl.ensureBlitCommandEncoder(this);
}

void Queue::finalizeBlitCommandEncoder()
{
    m_impl->impl.finalizeBlitCommandEncoder(this);
}

// Host mirror of the MSL `WebKitStagedCopyArgs` declared in the kernel source in Queue.swift. It is a hand-maintained
// ABI, and getting the field widths wrong produces silently wrong offsets rather than a compile error. MSL `ulong` is
// 64-bit, so the static_asserts below pin size and every offset.
struct StagedCopyArguments {
    uint64_t sourceWordOffset;
    uint64_t destinationWordOffset;
    uint64_t wordCount;
};
static_assert(sizeof(StagedCopyArguments) == 24, "StagedCopyArguments must match MSL WebKitStagedCopyArgs (3 x ulong)");
static_assert(!offsetof(StagedCopyArguments, sourceWordOffset), "sourceWordOffset must be at offset 0");
static_assert(offsetof(StagedCopyArguments, destinationWordOffset) == 8, "destinationWordOffset must be at offset 8");
static_assert(offsetof(StagedCopyArguments, wordCount) == 16, "wordCount must be at offset 16");

void Queue::setStagedCopyArguments(id<MTLComputeCommandEncoder> encoder, uint64_t sourceWordOffset, uint64_t destinationWordOffset, uint64_t wordCount)
{
    StagedCopyArguments arguments { sourceWordOffset, destinationWordOffset, wordCount };
    [encoder setBytes:&arguments length:sizeof(arguments) atIndex:2];
}

void Queue::endEncoding(id<MTLCommandEncoder> commandEncoder, id<MTLCommandBuffer> commandBuffer) const
{
    if (m_impl->impl.endEncodingIfCurrent(commandEncoder, commandBuffer))
        resolveDeviceTimestamps(commandBuffer);
}

void Queue::resolveDeviceTimestamps(id<MTLCommandBuffer> commandBuffer) const
{
    if (RefPtr device = m_device.get())
        device->resolveTimestampsForBuffer(commandBuffer);
}

id<MTLCommandEncoder> Queue::encoderForBuffer(id<MTLCommandBuffer> commandBuffer) const
{
    return m_impl->impl.encoderForBuffer(commandBuffer);
}

void Queue::setEncoderForBuffer(id<MTLCommandBuffer> commandBuffer, id<MTLCommandEncoder> commandEncoder)
{
    m_impl->impl.setEncoderForBuffer(this, commandBuffer, commandEncoder);
}

id<MTLCommandBuffer> Queue::commandBufferWithDescriptor(MTLCommandBufferDescriptor* descriptor)
{
    return m_impl->impl.commandBufferWithDescriptor(this, descriptor);
}

void Queue::loseTheDevice(WebGPU::DeviceLostReason reason)
{
    if (RefPtr device = m_device)
        device->loseTheDevice(reason);
}

void Queue::retainDeviceUntilCompleted(id<MTLCommandBuffer> commandBuffer)
{
    if (auto instance = m_instance.get()) {
        if (auto device = m_device.get())
            instance->retainDevice(*device, commandBuffer);
    }
}

void Queue::makeInvalid()
{
    m_impl->impl.makeInvalid(this);
}

static bool isUsable(const RefPtr<Device>& device)
{
    return device && device->isValid() && !device->isLost();
}

// The device stays referenced for the call.
void Queue::onSubmittedWorkDone(CompletionHandler<void(bool)>&& callback)
{
    RefPtr device = m_device;
    m_impl->impl.onSubmittedWorkDone(this, isUsable(device), callback);
}

void Queue::onSubmittedWorkScheduled(Function<void()>&& completionHandler)
{
    RefPtr device = m_device;
    m_impl->impl.onSubmittedWorkScheduled(this, isUsable(device), completionHandler);
}

void Queue::removeMTLCommandBuffer(id<MTLCommandBuffer> commandBuffer)
{
    m_impl->impl.removeMTLCommandBuffer(this, commandBuffer);
}

void Queue::waitForAllCommitedWorkToComplete()
{
    m_impl->impl.waitForAllCommittedWorkToComplete();
}

template<unsigned errorCode>
[[noreturn]] void crashGPUProcess(NSError* error, NSError* underlyingError)
{
    WTFLogAlways("Encountered fatal command buffer error %@, underlying error %@", error, underlyingError); // NOLINT
    RELEASE_ASSERT_NOT_REACHED();
}

void Queue::commitMTLCommandBuffer(id<MTLCommandBuffer> commandBuffer)
{
    m_impl->impl.commitMTLCommandBuffer(this, commandBuffer);
}

// Called by QueueImpl just before each commit. The handlers are in C++ because they capture the Queue and hop to the
// API thread through the Instance, and because crashGPUProcess<N>() gives every fatal error code a crash signature of
// its own.
void Queue::addCommitHandlers(id<MTLCommandBuffer> commandBuffer)
{
    // Both handlers run on Metal threads and touch only the Sendable completion, the box's scheduler handle and the
    // refcount. Each hands its reference to the queue over to its work item, so that the queue is released on the
    // API thread, where the work items run.
    [commandBuffer addScheduledHandler:[protectedThis = protect(*this)](id<MTLCommandBuffer>) mutable {
        Queue& queue = protectedThis.get();
        queue.scheduleWork([protectedThis = WTF::move(protectedThis)] {
            protectedThis->m_impl->impl.didScheduleCommandBuffer();
        });
    }];
    [commandBuffer addCompletedHandler:[protectedThis = protect(*this), completion = m_impl->completion](id<MTLCommandBuffer> mtlCommandBuffer) mutable {
        MTLCommandBufferStatus status = mtlCommandBuffer.status;
        bool loseTheDevice = false;
        if (NSError *error = mtlCommandBuffer.error; status != MTLCommandBufferStatusCompleted) {
            loseTheDevice = !error || error.code != MTLCommandBufferErrorNotPermitted;
            if (loseTheDevice) {
                NSError* underlyingError = error.userInfo[NSUnderlyingErrorKey];
                if (underlyingError.code == 0x10a || underlyingError.code == 0x5)
                    loseTheDevice = false;
                else {
#define makeCase(N) case N: crashGPUProcess<N>(error, underlyingError);
                    switch (underlyingError.code) {
                        makeCase(9); // kIOGPUCommandBufferCallbackErrorInvalidResource = 9,
                        makeCase(10); // kIOGPUCommandBufferCallbackErrorInvalidInput = 10,
                        makeCase(11); // kIOGPUCommandBufferCallbackErrorPageFault = 11,
                        makeCase(16); // kIOGPUCommandBufferCallbackErrorProtectionViolation = 16,
                        makeCase(17); // kIOGPUCommandBufferCallbackErrorStackOverflow = 17,
                        break;
                    default:
                        break;
                    }
#undef makeCase
                    WTFLogAlways("Encountered non-fatal command buffer error %@, underlying error %@", error, underlyingError); // NOLINT
                }
            }
        }

        completion.didComplete();

        Queue& queue = protectedThis.get();
        queue.scheduleWork([loseTheDevice, protectedThis = WTF::move(protectedThis)] {
            protectedThis->m_impl->impl.didCompleteCommandBuffer();
            if (loseTheDevice) {
                auto device = protectedThis->m_device.get();
                if (device)
                    device->loseTheDevice(WebGPU::DeviceLostReason::Unknown);
            }
        });
    }];
}

void Queue::submit(Vector<Ref<WebGPU::Metal::CommandBuffer>>&& commands)
{
    RefPtr device = m_device;
    if (!device)
        return;

    for (Ref command : commands)
        m_impl->impl.appendCommandToSubmit(command.ptr(), command->swiftImpl());
    m_impl->impl.submit(this, device.get(), device->swiftImpl());
}

uint64_t Queue::retainCounterSampleBuffer(CommandEncoder& encoder)
{
    return m_impl->impl.retainCounterSampleBuffers(encoder.swiftImpl());
}

void Queue::releaseCounterSampleBuffer(uint64_t encoderHandle)
{
    m_impl->impl.releaseCounterSampleBuffers(encoderHandle);
}

void Queue::retainTimestampsForOneUpdate(NSMutableSet<id<MTLCounterSampleBuffer>> *timestamps)
{
    // Workaround for rdar://143905417
    if (!timestamps)
        return;

    scheduleWork([protectedThis = protect(*this), timestamps] {
        UNUSED_PARAM(timestamps);
    });
}

void Queue::synchronizeResourceAndWait(id<MTLBuffer> buffer)
{
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (buffer.storageMode != MTLStorageModeManaged)
        return;

    [ensureBlitCommandEncoder() synchronizeResource:buffer];
    ALLOW_DEPRECATED_DECLARATIONS_END
    id<MTLCommandBuffer> commandBuffer = m_impl->impl.stagingCommandBuffer();
    finalizeBlitCommandEncoder();
    [commandBuffer waitUntilCompleted];
#else
    UNUSED_PARAM(buffer);
#endif
}

void writeBufferContents(id<MTLBuffer> buffer, uint64_t bufferOffset, std::span<const uint8_t> data NOESCAPE)
{
    memcpySpan(cpuVisibleContents(buffer).subspan(bufferOffset, data.size()), data);
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (buffer.storageMode == MTLStorageModeManaged)
        [buffer didModifyRange:NSMakeRange(bufferOffset, data.size())];
    ALLOW_DEPRECATED_DECLARATIONS_END
#endif
}

void Queue::writeBuffer(Buffer& buffer, uint64_t bufferOffset, std::span<uint8_t> data)
{
    RefPtr device = m_device;
    if (!device)
        return;

    m_impl->impl.writeBuffer(this, device.get(), device->swiftImpl(), &buffer, buffer.swiftImpl(), bufferOffset, QueueBytes { data });
}

id<MTLBuffer> newBufferAliasingOwner(const Device& device, const WebGPU::ByteOwner& owner, uint64_t offset, uint64_t length)
{
    auto bytes = owner.span();
    if (offset > bytes.size() || length > bytes.size() - offset)
        return nil;
    bytes = bytes.subspan(static_cast<size_t>(offset), static_cast<size_t>(length));
    // Metal reads the bytes in place until it destroys the buffer, and only then releases the deallocator, which holds
    // their owner. The buffer is only ever a copy source, so nothing writes to them.
    auto keepOwnerAlive = makeBlockPtr([protectedOwner = Ref { owner }](void*, NSUInteger) { });
    return [device.device() newBufferWithBytesNoCopy:spanConstCast<uint8_t>(bytes).data() length:bytes.size() options:MTLResourceStorageModeShared deallocator:keepOwnerAlive.get()];
}

void copyBytesToBuffer(id<MTLBuffer> buffer, uint64_t offset, std::span<const uint8_t> data NOESCAPE)
{
    memcpySpan(cpuVisibleContents(buffer).subspan(offset), data);
}

std::pair<id<MTLBuffer>, uint64_t> Queue::newTemporaryBufferWithBytes(std::span<uint8_t> data, bool noCopy)
{
    RefPtr device = m_device;
    if (!device)
        return std::make_pair(nil, 0ull);

    uint64_t offset = 0;
    id<MTLBuffer> buffer = m_impl->impl.newTemporaryBufferWithBytes(device.get(), QueueBytes { data }, noCopy, offset);
    return std::make_pair(buffer, offset);
}

void Queue::writeBuffer(id<MTLBuffer> buffer, uint64_t bufferOffset, std::span<uint8_t> data)
{
    RefPtr device = m_device;
    if (!device)
        return;

    m_impl->impl.stageBufferWrite(this, device.get(), device->swiftImpl(), buffer, bufferOffset, QueueBytes { data });
}

void Queue::clearBuffer(id<MTLBuffer> buffer, NSUInteger offset, NSUInteger size)
{
    m_impl->impl.clearBuffer(this, buffer, offset, size);
}

Ref<Device> Queue::device() const
{
    RefPtr device = m_device;
    RELEASE_ASSERT(device);
    return device.releaseNonNull();
}

void Queue::generateAValidationError(String&& message)
{
    if (RefPtr device = m_device.get())
        device->generateAValidationError(WTF::move(message));
}

void Queue::writeTexture(const WebGPU::TexelCopyTextureInfo& destination, std::span<uint8_t> data, const WebGPU::TexelCopyBufferLayout& dataLayout, const WebGPU::Extent3D& size, bool skipValidation)
{
    RefPtr device = m_device;
    if (!device)
        return;

    Ref texture = metal(destination.texture);
    m_impl->impl.writeTexture(this, device.get(), device->swiftImpl(), texture->swiftImpl(), destination, QueueBytes { data }, dataLayout, size, skipValidation);
}

// The bytes replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage: reads: each of the region's images,
// bytesPerImage apart, has its rows of blocks, bytesPerRow apart, and the last row is only as long as the region's blocks.
static uint64_t replaceRegionSourceSize(MTLRegion region, uint64_t bytesPerRow, uint64_t bytesPerImage, TexelBlockLayout block)
{
    RELEASE_ASSERT(block.width && block.height);
    uint64_t blocksPerRow = region.size.width / block.width + (region.size.width % block.width ? 1 : 0);
    uint64_t rows = region.size.height / block.height + (region.size.height % block.height ? 1 : 0);
    if (!blocksPerRow || !rows || !region.size.depth)
        return 0;
    CheckedUint64 size = CheckedUint64(region.size.depth - 1) * bytesPerImage;
    size += CheckedUint64(rows - 1) * bytesPerRow;
    size += CheckedUint64(blocksPerRow) * block.size;
    RELEASE_ASSERT(!size.hasOverflowed());
    return size.value();
}

void replaceRegion(id<MTLTexture> texture, MTLRegion region, uint32_t mipLevel, uint64_t slice, std::span<const uint8_t> data NOESCAPE, uint64_t sourceOffset, uint64_t bytesPerRow, uint64_t bytesPerImage, TexelBlockLayout block)
{
    auto source = data.subspan(static_cast<size_t>(sourceOffset));
    RELEASE_ASSERT(replaceRegionSourceSize(region, bytesPerRow, bytesPerImage, block) <= source.size());
    [texture
        replaceRegion:region
        mipmapLevel:mipLevel
        slice:static_cast<NSUInteger>(slice)
        withBytes:byteCast<char>(source.data())
        bytesPerRow:static_cast<NSUInteger>(bytesPerRow)
        bytesPerImage:static_cast<NSUInteger>(bytesPerImage)];
}

static_assert(sizeof(CopyExternalImageArguments) == 144, "CopyExternalImageArguments must match MSL WebKitCopyExternalImageArgs (9 x uint + 27 x float)");
static_assert(!offsetof(CopyExternalImageArguments, sourceOriginX), "sourceOriginX must be at offset 0");
static_assert(offsetof(CopyExternalImageArguments, sourceOriginY) == 4, "sourceOriginY must be at offset 4");
static_assert(offsetof(CopyExternalImageArguments, destinationOriginX) == 8, "destinationOriginX must be at offset 8");
static_assert(offsetof(CopyExternalImageArguments, destinationOriginY) == 12, "destinationOriginY must be at offset 12");
static_assert(offsetof(CopyExternalImageArguments, copyWidth) == 16, "copyWidth must be at offset 16");
static_assert(offsetof(CopyExternalImageArguments, copyHeight) == 20, "copyHeight must be at offset 20");
static_assert(offsetof(CopyExternalImageArguments, sourceMaxX) == 24, "sourceMaxX must be at offset 24");
static_assert(offsetof(CopyExternalImageArguments, sourceMaxY) == 28, "sourceMaxY must be at offset 28");
static_assert(offsetof(CopyExternalImageArguments, flags) == 32, "flags must be at offset 32");
static_assert(offsetof(CopyExternalImageArguments, colorMatrix) == 36, "colorMatrix must be at offset 36");
static_assert(offsetof(CopyExternalImageArguments, uvRemapMatrix) == 72, "uvRemapMatrix must be at offset 72");
static_assert(offsetof(CopyExternalImageArguments, ycbcrMatrix) == 96, "ycbcrMatrix must be at offset 96");

void Queue::setCopyExternalImageArguments(id<MTLRenderCommandEncoder> encoder, const CopyExternalImageArguments& arguments)
{
    [encoder setFragmentBytes:&arguments length:sizeof(arguments) atIndex:0];
}

#pragma mark External texture import (ExternalTextureImport.swift)

// ExternalTextureImport.swift spells HAVE(COREVIDEO_METAL_SUPPORT) out, because Swift cannot evaluate the CoreVideo
// macro it expands to.
#if HAVE(COREVIDEO_METAL_SUPPORT) != (HAVE(WEBGPU_IMPLEMENTATION) && (PLATFORM(MAC) || PLATFORM(IOS) || PLATFORM(VISION)))
#error "Update the HAVE(COREVIDEO_METAL_SUPPORT) conditions in ExternalTextureImport.swift"
#endif

void copyPixelBufferPlane(id<MTLTexture> texture, CVPixelBufferRef pixelBuffer, size_t plane, size_t bytesPerPixel)
{
    // Metal reads `height` rows of `width * bytesPerPixel` bytes, bytesPerRow apart: never more rows, or wider ones, than
    // the plane has. A plane whose rows are narrower than that is not copied, which is what Metal itself does on Apple GPUs.
    size_t width = std::min<size_t>(CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), texture.width);
    size_t height = std::min<size_t>(CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), texture.height);
    if (!width || !height || !bytesPerPixel)
        return;
    size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
    auto bytesReadPerRow = checkedProduct<size_t>(width, bytesPerPixel);
    if (bytesReadPerRow.hasOverflowed() || bytesReadPerRow.value() > bytesPerRow)
        return;
    void* imageBytes = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane);
    RELEASE_ASSERT(imageBytes);

    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:imageBytes bytesPerRow:bytesPerRow];
}

IOSurfaceRef pixelBufferIOSurface(CVPixelBufferRef pixelBuffer)
{
    return CVPixelBufferGetIOSurface(pixelBuffer);
}

#if HAVE(COREVIDEO_METAL_SUPPORT)
CVMetalTextureCacheRef createCoreVideoTextureCache(id<MTLDevice> device)
{
    // This is an out-parameter which is returned retained.
    SUPPRESS_UNRETAINED_LOCAL CVMetalTextureCacheRef cache = nullptr;
    CVReturn result = CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache);
    ASSERT_UNUSED(result, result == kCVReturnSuccess);
    return cache;
}

CVMetalTextureRef createCoreVideoPlaneTexture(CVMetalTextureCacheRef cache, CVPixelBufferRef pixelBuffer, MTLPixelFormat pixelFormat, size_t plane)
{
    // This is an out-parameter which is immediately adopted below.
    SUPPRESS_UNRETAINED_LOCAL CVMetalTextureRef texture = nullptr;
    CVReturn status = CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, pixelBuffer, nullptr, pixelFormat, CVPixelBufferGetWidthOfPlane(pixelBuffer, plane), CVPixelBufferGetHeightOfPlane(pixelBuffer, plane), plane, &texture);
    RetainPtr adoptedTexture = adoptCF(texture);
    if (status != kCVReturnSuccess)
        return nullptr;
    return adoptedTexture.leakRef();
}

CleanTexCoords cleanTexCoords(CVMetalTextureRef texture)
{
    std::array<float, 2> lowerLeft { };
    std::array<float, 2> lowerRight { };
    std::array<float, 2> upperRight { };
    std::array<float, 2> upperLeft { };
    CVMetalTextureGetCleanTexCoords(texture, lowerLeft.data(), lowerRight.data(), upperRight.data(), upperLeft.data());
    return { .lowerLeftX = lowerLeft[0], .lowerRightY = lowerRight[1], .upperRightX = upperRight[0], .upperLeftY = upperLeft[1] };
}
#endif

void Queue::copyExternalImageToTexture(const WebGPU::ImageCopyExternalImage& source, const WebGPU::ImageCopyTextureTagged& destination, const WebGPU::Extent3D& copySize)
{
    // https://gpuweb.github.io/gpuweb/#dom-gpuqueue-copyexternalimagetotexture
    RefPtr device = m_device;
    if (!device)
        return;

    CopyExternalImageSource parameters {
        .sourceFormat = source.sourceFormat,
        .sourceSize = source.sourceSize,
        .pixelBufferRotation = source.pixelBufferRotation,
        .pixelBufferIsMirrored = source.pixelBufferIsMirrored,
        .origin = source.origin,
        .flipY = source.flipY,
        .hasAlpha = source.hasAlpha,
        .premultipliedAlpha = source.premultipliedAlpha,
        .colorSpace = source.colorSpace,
    };
    Ref texture = metal(destination.texture);
    m_impl->impl.copyExternalImageToTexture(this, device.get(), device->swiftImpl(), texture->swiftImpl(), parameters, source.source.get(), source.pixelBuffer.get(), destination, copySize);
}

void Queue::setLabel(String&& label)
{
    m_impl->impl.setLabel(label.createNSString().get());
}

void Queue::submit(Vector<Ref<WebGPU::CommandBuffer>>&& commands)
{
    submit(WTF::map(commands, [](auto& command) {
        return Ref { downcast<CommandBuffer>(command) };
    }));
}

void Queue::onSubmittedWorkDone(CompletionHandler<void()>&& callback)
{
    onSubmittedWorkDone(CompletionHandler<void(bool)> { [callback = WTF::move(callback)](bool) mutable {
        callback();
    } });
}

// The WebGPU::Metal writes only read `data`, and are done with it when they return.
void Queue::writeBuffer(WebGPU::Buffer& buffer, uint64_t bufferOffset, std::span<const uint8_t> data)
{
    writeBuffer(downcast<Buffer>(buffer), bufferOffset, spanConstCast<uint8_t>(data));
}

void Queue::writeTexture(const WebGPU::TexelCopyTextureInfo& destination, std::span<const uint8_t> data, const WebGPU::TexelCopyBufferLayout& dataLayout, const WebGPU::Extent3D& writeSize)
{
    writeTexture(destination, spanConstCast<uint8_t>(data), dataLayout, writeSize, false);
}

void Queue::writeBuffer(WebGPU::Buffer& buffer, uint64_t bufferOffset, Ref<WebGPU::ByteOwner>&& data)
{
    RefPtr device = m_device;
    if (!device)
        return;

    m_impl->impl.writeBufferFromOwner(this, device.get(), device->swiftImpl(), &downcast<Buffer>(buffer), downcast<Buffer>(buffer).swiftImpl(), bufferOffset, QueueBytes { data->span() }, data.ptr());
}

void Queue::writeTexture(const WebGPU::TexelCopyTextureInfo& destination, Ref<WebGPU::ByteOwner>&& data, const WebGPU::TexelCopyBufferLayout& dataLayout, const WebGPU::Extent3D& writeSize)
{
    RefPtr device = m_device;
    if (!device)
        return;

    Ref texture = metal(destination.texture);
    m_impl->impl.writeTextureFromOwner(this, device.get(), device->swiftImpl(), texture->swiftImpl(), destination, QueueBytes { data->span() }, data.ptr(), dataLayout, writeSize);
}

void Queue::scheduleWork(Instance::WorkItem&& workItem)
{
    // A copy of the handle: the work item can hold the last reference to this queue, and run on the API thread
    // before the call returns.
    if (auto scheduler = m_impl->scheduler)
        scheduler->scheduleWork(workItem);
}

bool Queue::clearTextureViewIfNeeded(TextureView& textureView)
{
    RefPtr device = m_device;
    if (!device)
        return false;

    Ref parentTexture = textureView.apiParentTexture();
    return m_impl->impl.clearTextureIfNeeded(this, device.get(), parentTexture->swiftImpl(), textureView.aspect(), textureView.mipLevelCount(), textureView.arrayLayerCount(), textureView.baseMipLevel(), textureView.baseArrayLayer());
}

bool Queue::clearTextureViewIfNeeded(Texture& texture)
{
    RefPtr device = m_device;
    if (!device)
        return false;

    return m_impl->impl.clearTextureIfNeeded(this, device.get(), texture.swiftImpl(), WebGPU::TextureAspect::All, texture.mipLevelCount(), texture.arrayLayerCount(), 0, 0);
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuQueueAddRef(WGPUQueue queue)
{
    WebGPU::Metal::fromAPI(queue).ref();
}

void wgpuQueueRelease(WGPUQueue queue)
{
    WebGPU::Metal::fromAPI(queue).deref();
}

// Work that cannot complete, because the device is lost, is WGPUQueueWorkDoneStatus_Error.
WGPUFuture wgpuQueueOnSubmittedWorkDone(WGPUQueue queue, WGPUQueueWorkDoneCallbackInfo callbackInfo)
{
    Ref protectedQueue = WebGPU::Metal::fromAPI(queue);
    WebGPU::Metal::CAPIFuture future { protectedQueue->device()->instance() };
    protectedQueue->onSubmittedWorkDone(CompletionHandler<void(bool)> { [callbackInfo, future](bool success) {
        if (success)
            callbackInfo.callback(WGPUQueueWorkDoneStatus_Success, WebGPU::Metal::toAPI(""_s), callbackInfo.userdata1, callbackInfo.userdata2);
        else
            callbackInfo.callback(WGPUQueueWorkDoneStatus_Error, WebGPU::Metal::toAPI("The device is lost"_s), callbackInfo.userdata1, callbackInfo.userdata2);
        future.complete();
    } });
    return future.future();
}

void wgpuQueueSubmit(WGPUQueue queue, size_t commandCount, const WGPUCommandBuffer* commands)
{
    Vector<Ref<WebGPU::Metal::CommandBuffer>> commandsToForward;
    for (auto& command : unsafeMakeSpan(commands, commandCount))
        commandsToForward.append(protect(WebGPU::Metal::fromAPI(command)));
    protect(WebGPU::Metal::fromAPI(queue))->submit(WTF::move(commandsToForward));
}

// The caller may reuse or free `data` as soon as these return, so they take the writes that copy it.
void wgpuQueueWriteBuffer(WGPUQueue queue, WGPUBuffer buffer, uint64_t bufferOffset, const void* data, size_t size)
{
    auto bytes = unsafeMakeSpan(static_cast<const uint8_t*>(data), size);
    protect(WebGPU::Metal::fromAPI(queue))->writeBuffer(protect(WebGPU::Metal::fromAPI(buffer)), bufferOffset, bytes);
}

void wgpuQueueWriteTexture(WGPUQueue queue, const WGPUTexelCopyTextureInfo* destination, const void* data, size_t dataSize, const WGPUTexelCopyBufferLayout* dataLayout, const WGPUExtent3D* writeSize)
{
    auto bytes = unsafeMakeSpan(static_cast<const uint8_t*>(data), dataSize);
    Ref protectedQueue = WebGPU::Metal::fromAPI(queue);
    auto apiDestination = WebGPU::Metal::fromAPI(*destination);
    if (!apiDestination) {
        protectedQueue->generateAValidationError("GPUQueue.writeTexture: the destination has a null texture or an invalid aspect"_s);
        return;
    }
    protectedQueue->writeTexture(*apiDestination, bytes, WebGPU::Metal::fromAPI(*dataLayout), WebGPU::Metal::fromAPI(*writeSize));
}

void wgpuQueueSetLabel(WGPUQueue queue, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(queue))->setLabel(WebGPU::Metal::fromAPI(label));
}
