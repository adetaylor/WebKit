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
#import "CommandBuffer.h"

#import "APIConversions.h"
#import "CommandEncoder.h"
#import "Device.h"
#import "Instance.h"
#import "Queue.h"
#import <wtf/TZoneMallocInlines.h>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

namespace WebGPU::Metal {

struct CommandBufferImplBox {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(CommandBufferImplBox);
    WebGPUSwift::CommandBufferImpl impl;
    // The impl's completion, taken once, so that registering the Metal handler needs no call into Swift.
    WebGPUSwift::CommandBufferCompletion completion;
};
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(CommandBufferImplBox);

static std::unique_ptr<CommandBufferImplBox> makeCommandBufferImplBox(WebGPUSwift::CommandBufferImpl impl)
{
    return makeUnique<CommandBufferImplBox>(CommandBufferImplBox { .impl = impl, .completion = impl.completion() });
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(CommandBuffer);

Ref<CommandBuffer> CommandBuffer::create(const WebGPUSwift::CommandBufferImpl& impl)
{
    return adoptRef(*new CommandBuffer(makeCommandBufferImplBox(impl)));
}

Ref<CommandBuffer> CommandBuffer::createInvalid(Device& device)
{
    return adoptRef(*new CommandBuffer(makeCommandBufferImplBox(makeInvalidCommandBufferImpl(&device, device.swiftImpl()))));
}

CommandBuffer::CommandBuffer(std::unique_ptr<CommandBufferImplBox>&& impl)
    : m_impl(WTF::move(impl))
{
}

CommandBuffer::~CommandBuffer() = default;

bool CommandBuffer::isValid() const
{
    return m_impl->impl.isValid();
}

WebGPUSwift::CommandBufferImpl& CommandBuffer::swiftImpl() const
{
    return m_impl->impl;
}

Device& CommandBuffer::device() const
{
    return borrowSwiftRetained(m_impl->impl.shellDevice());
}

id<MTLCommandBuffer> CommandBuffer::commandBuffer() const
{
    return m_impl->impl.commandBuffer();
}

void CommandBuffer::setLabel(String&& label)
{
    m_impl->impl.setLabel(label.createNSString().get());
}

void CommandBuffer::setBufferMapCount(int bufferMapCount)
{
    m_impl->impl.setBufferMapCount(bufferMapCount);
}

int CommandBuffer::bufferMapCount() const
{
    return m_impl->impl.bufferMapCount();
}

double CommandBuffer::gpuExecutionDurationSeconds() const
{
    return m_impl->impl.gpuExecutionDurationSeconds();
}

void CommandBuffer::makeInvalid(NSString* lastError)
{
    m_impl->impl.makeInvalid(lastError);
}

NSString* CommandBuffer::lastError() const
{
    return m_impl->impl.lastError();
}

bool CommandBuffer::waitForCompletion()
{
    return m_impl->impl.waitForCompletion();
}

} // namespace WebGPU::Metal
