/*
 * Copyright (c) 2022 Apple Inc. All rights reserved.
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

#import <Metal/Metal.h>
#import <limits>
#import <type_traits>
#import <utility>
#import <wtf/GenericHashKey.h>
#import <wtf/HashFunctions.h>
#import <wtf/HashMap.h>
#import <wtf/HashSet.h>
#import <wtf/Hasher.h>
#import <wtf/OptionSet.h>
#import <wtf/RefPtr.h>
#import <wtf/Variant.h>
#import <wtf/Vector.h>
#import <wtf/WeakPtr.h>

namespace WebGPU::Metal {

class BindGroup;
class Buffer;
class ExternalTexture;
class RenderBundle;
class Texture;
class TextureView;

// The layout the indirect-command-buffer clamp shader declares for its index data.
struct IndexData {
    uint64_t renderCommand { 0 };
    uint32_t minVertexCount { UINT32_MAX };
    uint32_t minInstanceCount { UINT32_MAX };
    uint64_t bufferGpuAddress { 0 };
    uint32_t indexBufferElementCountMinusOne { 0 };
    uint32_t indexCount { 0 };
    uint32_t instanceCount { 0 };
    uint32_t firstIndex { 0 };
    int32_t baseVertex { 0 };
    uint32_t firstInstance { 0 };
    uint32_t primitiveType { MTLPrimitiveTypeTriangle };
};
// The clamp shader's IndexDataUshort/IndexDataUint (DeviceHelpers.swift) assert the same offsets, which Swift reads
// from this struct.
static_assert(sizeof(IndexData) == 56);
static_assert(!offsetof(IndexData, renderCommand));
static_assert(offsetof(IndexData, minVertexCount) == 8);
static_assert(offsetof(IndexData, minInstanceCount) == 12);
static_assert(offsetof(IndexData, bufferGpuAddress) == 16);
static_assert(offsetof(IndexData, indexBufferElementCountMinusOne) == 24);
static_assert(offsetof(IndexData, indexCount) == 28);
static_assert(offsetof(IndexData, instanceCount) == 32);
static_assert(offsetof(IndexData, firstIndex) == 36);
static_assert(offsetof(IndexData, baseVertex) == 40);
static_assert(offsetof(IndexData, firstInstance) == 44);
static_assert(offsetof(IndexData, primitiveType) == 48);

} // namespace WebGPU::Metal
