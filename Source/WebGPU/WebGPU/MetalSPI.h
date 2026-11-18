/*
 * Copyright (c) 2023 Apple Inc. All rights reserved.
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

#import <wtf/Compiler.h>
#import <wtf/Platform.h>

DECLARE_SYSTEM_HEADER

#import <CoreVideo/CVBase.h>
#import <Metal/Metal.h>

// CoreVideoInterop.swift and ExternalTextureImport.swift spell HAVE(COREVIDEO_METAL_SUPPORT) out, because Swift cannot
// evaluate the CoreVideo macro it expands to.
#if HAVE(COREVIDEO_METAL_SUPPORT) != (HAVE(WEBGPU_IMPLEMENTATION) && (PLATFORM(MAC) || PLATFORM(IOS) || PLATFORM(VISION)))
#error "Update the HAVE(COREVIDEO_METAL_SUPPORT) conditions in CoreVideoInterop.swift and ExternalTextureImport.swift"
#endif

#if USE(APPLE_INTERNAL_SDK)
#import <Metal/MTLCommandBuffer_Private.h>
#import <Metal/MTLDevice_Private.h>
#import <Metal/MTLResource_Private.h>
#import <Metal/MTLTexture_Private.h>
#endif

// Metal's compiles as Swift imports them without dropping the error (warnings) that comes with an object: Swift calls these
// selectors on an MTLDevice through AnyObject.
@protocol WebGPUMTLDeviceCompilation
- (nullable id<MTLLibrary>)newLibraryWithSource:(NSString * _Nonnull)source options:(nullable MTLCompileOptions *)options error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NOTHROW NS_SWIFT_NAME(makeLibraryKeepingWarnings(source:options:error:));
- (nullable id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor * _Nonnull)descriptor options:(MTLPipelineOption)options reflection:(MTLAutoreleasedComputePipelineReflection * _Nullable)reflection error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NOTHROW NS_SWIFT_NAME(makeComputePipelineStateKeepingWarnings(descriptor:options:reflection:error:));
- (nullable id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor * _Nonnull)descriptor error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NOTHROW NS_SWIFT_NAME(makeRenderPipelineStateKeepingWarnings(descriptor:error:));
@end

// FIXME: remove after radar://104903411 or after we place the mask into the last buffer
@interface MTLRenderPipelineDescriptor (WebGPUSampleMask)
- (void)setSampleMask:(NSUInteger)mask;
@end
