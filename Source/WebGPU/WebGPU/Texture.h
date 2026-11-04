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

#pragma once

#import "BindableResource.h"
#import <Metal/Metal.h>
#import <WebGPU/WebGPUCpp.h>
#import <cstddef>
#import <memory>
#import <span>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/HashSet.h>
#import <wtf/Lock.h>
#import <wtf/Ref.h>
#import <wtf/Seconds.h>
#import <wtf/SwiftBridging.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/ThreadSafeWeakHashSet.h>
#import <wtf/TypeCasts.h>
#import <wtf/Vector.h>
#import <wtf/WeakHashSet.h>
#import <wtf/WeakPtr.h>

namespace WebGPU::Metal {

// A WebGPU::TextureDescriptor without its label and view formats, as Texture.swift reads it. The usage OptionSet
// travels as its raw bits.
struct TextureParameters {
    uint32_t width { 0 };
    uint32_t height { 0 };
    uint32_t depthOrArrayLayers { 0 };
    uint32_t mipLevelCount { 0 };
    uint32_t sampleCount { 0 };
    WebGPU::TextureDimension dimension { WebGPU::TextureDimension::_2d };
    WebGPU::TextureFormat format { WebGPU::TextureFormat::Rgba8unorm };
    uint8_t usage { 0 };
};

// A WebGPU::TextureViewDescriptor without its label, as Texture.swift reads it. Each std::nullopt member is a cleared
// has* flag, and the usage OptionSet travels as its raw bits.
struct TextureViewDescriptorParameters {
    WebGPU::TextureFormat format { WebGPU::TextureFormat::Rgba8unorm };
    bool hasFormat { false };
    WebGPU::TextureViewDimension dimension { WebGPU::TextureViewDimension::_2d };
    bool hasDimension { false };
    uint32_t baseMipLevel { 0 };
    uint32_t mipLevelCount { 0 };
    bool hasMipLevelCount { false };
    uint32_t baseArrayLayer { 0 };
    uint32_t arrayLayerCount { 0 };
    bool hasArrayLayerCount { false };
    WebGPU::TextureAspect aspect { WebGPU::TextureAspect::All };
    uint8_t usage { 0 };
    WebGPU::TextureComponentSwizzle swizzle;
};

// View formats borrowed for the duration of a call into Texture.swift, which reads them as a Span.
struct TextureFormatsView {
    std::span<const WebGPU::TextureFormat> formats;
    std::span<const WebGPU::TextureFormat> span() const LIFETIME_BOUND { return formats; }
} SWIFT_VIEW;

} // namespace WebGPU::Metal

