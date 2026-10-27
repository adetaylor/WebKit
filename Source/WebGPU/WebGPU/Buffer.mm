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
#import "Buffer.h"

#import "APIConversions.h"
#import "BindGroup.h"
#import "CommandBuffer.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "RenderBundle.h"

#import <wtf/Borrow.h>
#import <wtf/CheckedArithmetic.h>
#import <wtf/StdLibExtras.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/cocoa/SpanCocoa.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct BufferImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(BufferImplBox);
    WebGPU::BufferImpl impl;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(BufferImplBox);

// The whole Ts of the buffer's contents from byteOffset on, through cpuVisibleContents(), which RELEASE_ASSERTs that a
// non-empty buffer has a CPU-visible base address.
template <typename T>
static inline std::span<T> span(id<MTLBuffer> buffer, uint64_t byteOffset = 0)
{
    auto bytes = cpuVisibleContents(buffer);
    if (byteOffset >= bytes.size())
        return { };
    bytes = bytes.subspan(byteOffset);
    return spanReinterpretCast<T>(bytes.first(bytes.size() - bytes.size() % sizeof(T)));
}

// Swift validates the descriptor, reports the errors and creates the MTLBuffer.
RefPtr<WebGPU::Buffer> Device::createBuffer(const WebGPU::BufferDescriptor& descriptor)
{
    BufferParameters parameters {
        .size = descriptor.size,
        .usage = descriptor.usage.toRaw(),
        .mappedAtCreation = descriptor.mappedAtCreation,
    };
    return Buffer::create(createBufferImpl(this, swiftImpl(), parameters, descriptor.label));
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(Buffer);

Ref<Buffer> Buffer::create(const WebGPU::BufferImpl& impl)
{
    auto box = makeUnique<BufferImplBox>(BufferImplBox { .impl = impl });
    Ref result = adoptRef(*new Buffer(WTF::move(box)));
    result->m_impl->impl.setShell(result.ptr());
    return result;
}

Ref<Buffer> Buffer::createInvalid(Device& device)
{
    return create(makeInvalidBufferImpl(&device, device.swiftImpl()));
}

Buffer::Buffer(std::unique_ptr<BufferImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

Buffer::~Buffer() = default;

WebGPU::BufferImpl& Buffer::swiftImpl() const
{
    return m_impl->impl;
}

Device& Buffer::device() const
{
    return borrowSwiftRetained(m_impl->impl.shellDevice());
}

void Buffer::destroy()
{
    crashIfBorrowed();

    m_impl->impl.destroy();
}

static uint64_t LEGACY_NODELETE computeRangeSize(uint64_t size, uint64_t offset)
{
    auto result = checkedDifference<uint64_t>(size, offset);
    if (result.hasOverflowed())
        return 0;
    return result.value();
}

// The offset and size of a mapped range as size_t. std::nullopt when either does not fit in size_t
// (32-bit platforms): no buffer is that large, so such a range is out of bounds.
static std::optional<std::pair<size_t, size_t>> LEGACY_NODELETE mappedRangeOffsetAndSize(uint64_t bufferSize, uint64_t offset, std::optional<uint64_t> size)
{
    uint64_t rangeSize = size ? *size : computeRangeSize(bufferSize, offset);
    if (!isInBounds<size_t>(offset) || !isInBounds<size_t>(rangeSize))
        return std::nullopt;
    return std::pair { static_cast<size_t>(offset), static_cast<size_t>(rangeSize) };
}

void Buffer::getMappedRange(uint64_t offset, std::optional<uint64_t> size, NOESCAPE const Function<void(std::span<uint8_t>)>& callback)
{
    callback(getMappedRangeSpan(offset, size));
}

std::span<uint8_t> Buffer::getMappedRangeSpan(uint64_t apiOffset, std::optional<uint64_t> size)
{
    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-getmappedrange
    auto offsetAndSize = mappedRangeOffsetAndSize(initialSize(), apiOffset, size);
    if (!offsetAndSize)
        return { };
    auto [offset, rangeSize] = *offsetAndSize;

    // Swift validated the range against [[mapping]], which lies within the MTLBuffer it keeps alive.
    if (!m_impl->impl.reserveMappedRange(offset, rangeSize))
        return { };
    return getBufferContents().subspan(offset, rangeSize);
}

std::span<uint8_t> Buffer::getBufferContents()
{
    return span<uint8_t>(buffer());
}

void Buffer::copyFrom(std::span<const uint8_t> data, size_t offset)
{
    if (data.empty())
        return;
    auto contents = getBufferContents();
    RELEASE_ASSERT(offset <= contents.size());
    memcpySpan(contents.subspan(offset), data);
}

// Swift validates, reports the errors and registers the mapping with the queue's submitted work.
void Buffer::mapAsync(OptionSet<WebGPU::MapMode> mode, uint64_t apiOffset, std::optional<uint64_t> size, CompletionHandler<void(bool)>&& callback)
{
    auto offsetAndSize = mappedRangeOffsetAndSize(initialSize(), apiOffset, size);
    auto [offset, rangeSize] = offsetAndSize.value_or(std::pair<size_t, size_t> { });
    m_impl->impl.mapAsync(this, mode.toRaw(), !!offsetAndSize, offset, rangeSize, callback);
}

void Buffer::unmap()
{
    m_impl->impl.unmap();
}

void Buffer::setLabel(String&& label)
{
    m_impl->impl.setLabel(WTF::move(label));
}

void Buffer::generateAValidationError()
{
    generateAValidationError("Buffer state was not unmapped"_s);
}

void Buffer::generateAValidationError(String&& message)
{
    device().generateAValidationError(WTF::move(message));
}

id<MTLBuffer> Buffer::buffer() const
{
    return m_impl->impl.buffer();
}

uint64_t Buffer::initialSize() const
{
    return m_impl->impl.initialSize();
}

uint64_t Buffer::currentSize() const
{
    return m_impl->impl.currentSize();
}

OptionSet<WebGPU::BufferUsage> Buffer::usage() const
{
    return OptionSet<WebGPU::BufferUsage>::fromRaw(m_impl->impl.usageRawValue());
}

Buffer::State Buffer::state() const
{
    return static_cast<State>(m_impl->impl.stateRawValue());
}

bool Buffer::isDestroyed() const
{
    return m_impl->impl.isDestroyed();
}

bool Buffer::isValid() const
{
    return m_impl->impl.isValid();
}

static uint64_t indirectCommandBufferKey(id<MTLIndirectCommandBuffer> icb)
{
    return icb.gpuResourceID._impl;
}

void Buffer::drawIndexedValidated(uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, MTLIndexType indexType, uint32_t primitiveOffset, uint64_t validationGeneration, id<MTLIndirectCommandBuffer> icb)
{
    m_impl->impl.drawIndexedValidatedForShell(firstIndex, indexCount, vertexCount, static_cast<uint32_t>(indexType), primitiveOffset, validationGeneration, indirectCommandBufferKey(icb));
}

template <typename T>
static bool verifyIndexBufferData(id<MTLBuffer> buffer, uint32_t firstIndex, uint32_t indexCount, uint32_t vertexCount, uint32_t primitiveRestart, uint32_t indexBufferOffsetInBytes = 0)
{
    auto indexData = span<T>(buffer, indexBufferOffsetInBytes);
    size_t endIndex = static_cast<size_t>(firstIndex) + indexCount;
    if (endIndex > indexData.size())
        return false;
    for (size_t index = firstIndex; index < endIndex; ++index) {
        T vertexIndex = primitiveRestart + indexData[index];
        if (vertexIndex >= vertexCount + primitiveRestart)
            return false;
    }

    return true;
}

static NSMutableData* copyContents(std::span<const uint8_t> contents)
{
    return [toNSData(contents).get() mutableCopy];
}

std::span<uint8_t> cpuVisibleContents(id<MTLBuffer> buffer)
{
    void* contents = buffer.contents;
    NSUInteger length = buffer.length;
    RELEASE_ASSERT(contents || !length);
    return unsafeMakeSpan(static_cast<uint8_t*>(contents), length);
}

NSMutableData* takeSlowIndexValidationPath(Buffer& buffer, uint32_t firstIndex, uint32_t indexCount, bool isUInt16, uint32_t primitiveOffset, uint32_t vertexCount)
{
    WTFLogAlways("WARNING: Severe performance penalty due to encoding drawIndexed calls out of order with submission"); // NOLINT
    Ref queue = buffer.device().getQueue();
    id<MTLBuffer> mtlBuffer = buffer.buffer();
    queue->waitForAllCommitedWorkToComplete();
    queue->synchronizeResourceAndWait(mtlBuffer);
    bool verified = false;
    if (isUInt16)
        verified = verifyIndexBufferData<uint16_t>(mtlBuffer, firstIndex, indexCount, vertexCount, primitiveOffset);
    else
        verified = verifyIndexBufferData<uint32_t>(mtlBuffer, firstIndex, indexCount, vertexCount, primitiveOffset);

    if (verified)
        return nil;

    SUPPRESS_UNCOUNTED_ARG NSMutableData* priorData = copyContents(borrow(buffer)->getBufferContents());

    queue->clearBuffer(mtlBuffer);
    queue->finalizeBlitCommandEncoder();
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
    ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    if (mtlBuffer.storageMode == MTLStorageModeManaged)
        [mtlBuffer didModifyRange:NSMakeRange(0, mtlBuffer.length)];
    ALLOW_DEPRECATED_DECLARATIONS_END
#endif
    return priorData;
}

void restoreIndexBufferContents(Buffer& buffer, id<MTLCommandBuffer> commandBuffer, NSMutableData* priorData)
{
    [commandBuffer waitUntilCompleted];
    Ref queue = buffer.device().getQueue();
    queue->writeBuffer(static_cast<WebGPU::Buffer&>(buffer), 0, WTF::span(priorData));
}

bool Buffer::didReadOOB(id<MTLIndirectCommandBuffer> icb) const
{
    return m_impl->impl.didReadOOB(indirectCommandBufferKey(icb));
}

void Buffer::didReadOOB(uint32_t v, id<MTLIndirectCommandBuffer> icb)
{
    m_impl->impl.recordReadOOB(indirectCommandBufferKey(icb), !!v);
}

void Buffer::indirectBufferInvalidated()
{
    m_impl->impl.indirectBufferInvalidatedWithoutEncoder();
}

bool Buffer::needsIndexValidation(uint32_t maxUnsignedIndex, uint16_t maxUshortIndex)
{
    return m_impl->impl.needsIndexValidation(maxUnsignedIndex, maxUshortIndex);
}

void Buffer::indexBufferContentsModified(uint32_t maxUintValue, uint16_t maxUshortValue)
{
    m_impl->impl.indexBufferContentsModified(maxUintValue, maxUshortValue);
}

bool Buffer::allIndexValuesBelow(MTLIndexType indexType, uint32_t vertexCount) const
{
    return m_impl->impl.allIndexValuesBelow(indexType == MTLIndexTypeUInt16, vertexCount);
}

uint64_t Buffer::contentsGeneration() const
{
    return m_impl->impl.contentsGeneration();
}

uint64_t Buffer::indexContentsGeneration() const
{
    return m_impl->impl.indexContentsGeneration();
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuBufferAddRef(WGPUBuffer buffer)
{
    WebGPU::Metal::fromAPI(buffer).ref();
}

void wgpuBufferRelease(WGPUBuffer buffer)
{
    WebGPU::Metal::fromAPI(buffer).deref();
}

void wgpuBufferDestroy(WGPUBuffer buffer)
{
    protect(WebGPU::Metal::fromAPI(buffer))->destroy();
}

WGPUBufferMapState wgpuBufferGetMapState(WGPUBuffer buffer)
{
    switch (protect(WebGPU::Metal::fromAPI(buffer))->state()) {
    case WebGPU::Metal::Buffer::State::Mapped:
        return WGPUBufferMapState_Mapped;
    case WebGPU::Metal::Buffer::State::MappedAtCreation:
        return WGPUBufferMapState_Mapped;
    case WebGPU::Metal::Buffer::State::MappingPending:
        return WGPUBufferMapState_Pending;
    case WebGPU::Metal::Buffer::State::Unmapped:
        return WGPUBufferMapState_Unmapped;
    case WebGPU::Metal::Buffer::State::Destroyed:
        return WGPUBufferMapState_Unmapped;
    }
}

void* wgpuBufferGetMappedRange(WGPUBuffer buffer, size_t offset, size_t size)
{
    return protect(WebGPU::Metal::fromAPI(buffer))->getMappedRangeSpan(offset, WebGPU::Metal::mapSizeFromAPI(size)).data();
}

const void* wgpuBufferGetConstMappedRange(WGPUBuffer buffer, size_t offset, size_t size)
{
    return wgpuBufferGetMappedRange(buffer, offset, size);
}

// mapAsync() validates only the Read and Write bits of the mode, as in the WebGPU specification, so the
// conversion drops unknown bits instead of failing.
static OptionSet<WebGPU::MapMode> mapModeFromAPIIgnoringUnknownBits(WGPUMapMode mode)
{
    return *WebGPU::Metal::mapModeFromAPI(mode & (WGPUMapMode_Read | WGPUMapMode_Write));
}

WGPUFuture wgpuBufferMapAsync(WGPUBuffer buffer, WGPUMapMode mode, size_t offset, size_t size, WGPUBufferMapCallbackInfo callbackInfo)
{
    Ref protectedBuffer = WebGPU::Metal::fromAPI(buffer);
    WebGPU::Metal::CAPIFuture future { protectedBuffer->device().instance() };
    protectedBuffer->mapAsync(mapModeFromAPIIgnoringUnknownBits(mode), offset, WebGPU::Metal::mapSizeFromAPI(size), [callbackInfo, future](bool success) {
        if (success)
            callbackInfo.callback(WGPUMapAsyncStatus_Success, WebGPU::Metal::toAPI(""_s), callbackInfo.userdata1, callbackInfo.userdata2);
        else
            callbackInfo.callback(WGPUMapAsyncStatus_Error, WebGPU::Metal::toAPI("mapAsync failed"_s), callbackInfo.userdata1, callbackInfo.userdata2);
        future.complete();
    });
    return future.future();
}

void wgpuBufferUnmap(WGPUBuffer buffer)
{
    protect(WebGPU::Metal::fromAPI(buffer))->unmap();
}

void wgpuBufferSetLabel(WGPUBuffer buffer, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(buffer))->setLabel(WebGPU::Metal::fromAPI(label));
}

// The size of the descriptor of the buffer.
uint64_t wgpuBufferGetSize(WGPUBuffer buffer)
{
    return WebGPU::Metal::fromAPI(buffer).initialSize();
}

WGPUBufferUsage wgpuBufferGetUsage(WGPUBuffer buffer)
{
    return WebGPU::Metal::toAPI(WebGPU::Metal::fromAPI(buffer).usage());
}
