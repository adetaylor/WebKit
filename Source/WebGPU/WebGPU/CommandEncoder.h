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

#import "BindableResource.h"
#import "Device.h"
#import <WebGPU/WebGPU.h>
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/Function.h>
#import <wtf/Ref.h>
#import <wtf/RetainPtr.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

namespace WebGPU::Metal {

// What the timestamp writes' validation message prints of a query set's type.
using OptionalQueryType = std::optional<WebGPU::QueryType>;

// setBindGroup's dynamic offsets, borrowed for the duration of the call, for the encoders' Swift: a nonescapable view
// whose span() Swift reads as a lifetime-checked Span, where a std::span parameter would be unsafe (rdar://161269480).
struct DynamicOffsetsView {
    std::span<const uint32_t> offsets;

    std::span<const uint32_t> span() const LIFETIME_BOUND { return offsets; }
} SWIFT_VIEW;

// A WebGPU::RenderPassColorAttachment without its views, for Swift, which cannot get the alternatives of the variant
// members of the C++ API struct. CommandEncoder::beginRenderPass() stages the views' Impls.
struct ResolvedRenderPassColorAttachment {
    std::optional<uint32_t> depthSlice;
    WebGPU::Color clearValue;
    WebGPU::LoadOp loadOp { WebGPU::LoadOp::Load };
    WebGPU::StoreOp storeOp { WebGPU::StoreOp::Store };
};

// A WebGPU::RenderPassDepthStencilAttachment, as ResolvedRenderPassColorAttachment.
struct ResolvedRenderPassDepthStencilAttachment {
    float depthClearValue { 0 };
    std::optional<WebGPU::LoadOp> depthLoadOp;
    std::optional<WebGPU::StoreOp> depthStoreOp;
    bool depthReadOnly { false };
    uint32_t stencilClearValue { 0 };
    std::optional<WebGPU::LoadOp> stencilLoadOp;
    std::optional<WebGPU::StoreOp> stencilStoreOp;
    bool stencilReadOnly { false };
};

// std::nullopt for an empty color attachment slot.
inline std::optional<ResolvedRenderPassColorAttachment> resolvedColorAttachment(const WebGPU::RenderPassDescriptor& descriptor, size_t index)
{
    auto& attachment = descriptor.colorAttachments[index];
    if (!attachment)
        return std::nullopt;
    return ResolvedRenderPassColorAttachment {
        .depthSlice = attachment->depthSlice,
        .clearValue = attachment->clearValue,
        .loadOp = attachment->loadOp,
        .storeOp = attachment->storeOp,
    };
}

inline std::optional<ResolvedRenderPassDepthStencilAttachment> resolvedDepthStencilAttachment(const WebGPU::RenderPassDescriptor& descriptor)
{
    auto& attachment = descriptor.depthStencilAttachment;
    if (!attachment)
        return std::nullopt;
    return ResolvedRenderPassDepthStencilAttachment {
        .depthClearValue = attachment->depthClearValue,
        .depthLoadOp = attachment->depthLoadOp,
        .depthStoreOp = attachment->depthStoreOp,
        .depthReadOnly = attachment->depthReadOnly,
        .stencilClearValue = attachment->stencilClearValue,
        .stencilLoadOp = attachment->stencilLoadOp,
        .stencilStoreOp = attachment->stencilStoreOp,
        .stencilReadOnly = attachment->stencilReadOnly,
    };
}

} // namespace WebGPU::Metal

IGNORE_CLANG_WARNINGS_END
