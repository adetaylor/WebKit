/*
 * Copyright (c) 2024 Apple Inc. All rights reserved.
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
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <utility>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/Ref.h>
#import <wtf/WeakPtr.h>

namespace WebGPU::Metal {

class Device;

#if USE(APPLE_INTERNAL_SDK) && HAVE(COMPOSITOR_SERVICES) && !PLATFORM(IOS_FAMILY_SIMULATOR)
// The SPI and soft-linked CompositorServices calls XRProjectionLayerImpl.startFrame makes in internal SDK device builds
// with CompositorServices (visionOS, and the Mac from macOS 27). XRProjectionLayer.swift makes the other builds' textures.
id<MTLTexture> makeXRSharedTexture(id<MTLDevice>, mach_port_t);
id<MTLSharedEvent> makeXRSharedEvent(id<MTLDevice>, mach_port_t);
NSArray<id<MTLRasterizationRateMap>> *makeXRRasterizationRateMaps(id<MTLDevice>, unsigned screenWidth, unsigned screenHeight, std::span<const float> horizontalSamplesLeft NOESCAPE, std::span<const float> horizontalSamplesRight NOESCAPE, std::span<const float> verticalSamples NOESCAPE);
#endif

} // namespace WebGPU::Metal
