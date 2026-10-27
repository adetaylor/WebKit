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

#import "ShaderModule.h"
#import "WGSLAPI.h"
#import <span>
#import <wtf/Function.h>

namespace WebGPU::Metal {

// For Pipeline.swift. Swift imports -newLibraryWithSource:options:error: and
// -newComputePipelineStateWithDescriptor:options:reflection:error: as throwing calls, which drop the error (warnings)
// that Metal returns together with an object; these call `result` with both before returning.
void newLibraryWithSource(id<MTLDevice>, NSString *source, MTLCompileOptions *, NOESCAPE void (^result)(id<MTLLibrary>, NSError *));
// Debug and fuzzing builds also write the PSO repro case around the compile.
void newComputePipelineState(id<MTLDevice>, MTLComputePipelineDescriptor *, const String& shaderSource, NOESCAPE void (^result)(id<MTLComputePipelineState>, NSError *));

// The PSO repro tooling of debug and fuzzing builds, which Swift cannot see (NDEBUG, ASAN_ENABLED): whether PSO logging
// makes every compile synchronous, and the render pipeline's repro case with its synchronous pipeline-state compile,
// whose error message (a null String without an error) makes the pipeline invalid. False and null in other builds.
bool psoLoggingIsEnabled();
String reproduceRenderPipelineState(id<MTLDevice>, uint32_t maxVertexBuffers, MTLRenderPipelineDescriptor *, const String& vertexShaderSource, const String& fragmentShaderSource, std::span<const uint32_t> shaderLocations NOESCAPE);

#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
void dumpMetalReproCaseComputePSO(String&& shaderSource, String&& functionName);
bool dumpMetalReproCaseRenderPSO(String&& vertexShaderSource, String&& vertexFunctionName, String&& fragmentShaderSource, String&& fragmentFunctionName, MTLRenderPipelineDescriptor*, std::span<const uint32_t> shaderLocations, uint32_t maxVertexBuffers);
void clearMetalPSORepro();
#endif

} // namespace WebGPU::Metal
