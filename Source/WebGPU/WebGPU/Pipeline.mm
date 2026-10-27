/*
 * Copyright (c) 2023 Apple Inc. All rights reserved.
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
#import "Pipeline.h"

#import "APIConversions.h"
#import "Device.h"
#import "Instance.h"
#import "RenderPipeline.h"
#import "ShaderModule.h"
#import <memory>

#if ENABLE(WEBGPU_SWIFT)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WebGPU.h>
#import "WebGPUSwift-Generated.h"
#endif

#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
#include <csignal>
#include <cstdlib>
#include <wtf/FileHandle.h>
#include <wtf/FileSystem.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#endif

namespace WebGPU::Metal {

#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
static bool enablePsoLogging();
#endif

void newLibraryWithSource(id<MTLDevice> device, NSString *source, MTLCompileOptions *options, NOESCAPE void (^result)(id<MTLLibrary>, NSError *))
{
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
    result(library, error);
}

void newComputePipelineState(id<MTLDevice> device, MTLComputePipelineDescriptor *descriptor, const String& shaderSource, NOESCAPE void (^result)(id<MTLComputePipelineState>, NSError *))
{
    NSError *error = nil;
#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
    dumpMetalReproCaseComputePSO(String { shaderSource }, descriptor.computeFunction.name);
#else
    UNUSED_PARAM(shaderSource);
#endif
    id<MTLComputePipelineState> computePipelineState = [device newComputePipelineStateWithDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
    clearMetalPSORepro();
#endif
    result(computePipelineState, error);
}

bool psoLoggingIsEnabled()
{
#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
    return enablePsoLogging();
#else
    return false;
#endif
}

String reproduceRenderPipelineState(id<MTLDevice> device, uint32_t maxVertexBuffers, MTLRenderPipelineDescriptor *renderPipelineDescriptor, const String& vertexShaderSource, const String& fragmentShaderSource, std::span<const uint32_t> shaderLocations NOESCAPE)
{
#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
    Vector<uint32_t> sortedShaderLocations { shaderLocations };
    sortInWTFHashTableOrder(sortedShaderLocations.mutableSpan());
    if (!dumpMetalReproCaseRenderPSO(String { vertexShaderSource }, renderPipelineDescriptor.vertexFunction.name, String { fragmentShaderSource }, renderPipelineDescriptor.fragmentFunction.name, renderPipelineDescriptor, sortedShaderLocations.span(), maxVertexBuffers))
        return { };
    renderPipelineDescriptor.supportIndirectCommandBuffers = YES;
    NSError *error = nil;
    id<MTLRenderPipelineState> renderPipelineState = [device newRenderPipelineStateWithDescriptor:renderPipelineDescriptor error:&error];
    UNUSED_PARAM(renderPipelineState);
    clearMetalPSORepro();
    return error ? String { error.localizedDescription } : String { };
#else
    UNUSED_PARAM(device);
    UNUSED_PARAM(maxVertexBuffers);
    UNUSED_PARAM(renderPipelineDescriptor);
    UNUSED_PARAM(vertexShaderSource);
    UNUSED_PARAM(fragmentShaderSource);
    UNUSED_PARAM(shaderLocations);
    return { };
#endif
}

#if !defined(NDEBUG) || (defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED)
static bool enablePsoLogging()
{
#if defined(ENABLE_LIBFUZZER) && ENABLE_LIBFUZZER && defined(ASAN_ENABLED) && ASAN_ENABLED
    return true;
#else
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"WebKitWebGPULogPSOState"];
#endif
}

static StringBuilder& psoReproStringBuilder()
{
    __attribute__((no_destroy)) static thread_local StringBuilder sb;
    return sb;
}

static Vector<void (*)(int)>& existingSigabortHandlers()
{
    __attribute__((no_destroy)) static Vector<void (*)(int)> handlers;
    return handlers;
}

static String psoPreamble()
{
    return R"(
    // Compile and run with:
    //
    //  clang++ -fobjc-arc -O3 psoRepro.mm -o repro -framework Metal -fsanitize=address -framework Cocoa -std=c++20 && AGC_ENABLE_STATUS_FILE=1 FS_CACHE_SIZE=0 MTL_MONOLITHIC_COMPILER=1 ./repro
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

    static uint32_t computeAppleGPUFamily(id<MTLDevice> device)
    {
        if ([device supportsFamily:MTLGPUFamilyApple9])
            return 9;
        if ([device supportsFamily:MTLGPUFamilyApple8])
            return 8;
        if ([device supportsFamily:MTLGPUFamilyApple7])
            return 7;
        if ([device supportsFamily:MTLGPUFamilyApple6])
            return 6;
        if ([device supportsFamily:MTLGPUFamilyApple5])
            return 5;
        if ([device supportsFamily:MTLGPUFamilyApple4])
            return 4;
        return 0xFF;
    }
)"_s;
}

static void printPsoOnProgramExit(int sig)
{
    if (psoReproStringBuilder().length())
        /* NOLINT */ SAFE_WTFLOGALWAYS("// ------------------------------------------------------------------------\n// Dumping Metal repro case:\n// ------------------------------------------------------------------------\n%s\n// ------------------------------------------------------------------------\n// End of repro case\n// ------------------------------------------------------------------------", psoReproStringBuilder().toString().utf8());

    // SIG_DFL is null; SIG_IGN and SIG_ERR are not functions either.
    auto previousHandler = existingSigabortHandlers()[sig];
    if (previousHandler && previousHandler != SIG_IGN && previousHandler != SIG_ERR)
        previousHandler(sig);
}

static bool registerPsoExitHandlers()
{
    static std::once_flag onceFlag;
    static bool handlersRegistered = false;
    std::call_once(onceFlag, [&] {
        handlersRegistered = true;
        auto sigCodes = { SIGINT, SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGSEGV };
        existingSigabortHandlers().resize(32);
        for (auto sig : sigCodes) {
            void (*prev)(int) = signal(sig, SIG_DFL);
            RELEASE_ASSERT(static_cast<size_t>(sig) < existingSigabortHandlers().size());
            existingSigabortHandlers()[sig] = prev;
            errno = 0;
            if (signal(sig, printPsoOnProgramExit) == SIG_ERR) {
                WTFLogAlways("Error: Unable to install signal handler for %d - errno %d", sig, errno); // NOLINT
                handlersRegistered = false;
            }
        }
    });

    return handlersRegistered;
}

static void printToFileForPsoRepro()
{
    NSError* error;
#if PLATFORM(IOS_FAMILY)
    NSURL* defaultURL = [NSURL fileURLWithPath:@"/tmp/" isDirectory:YES];
#else
    NSURL* defaultURL = [NSFileManager.defaultManager temporaryDirectory];
#endif
    NSURL* outputURL = [defaultURL URLByAppendingPathComponent:@"com.apple.WebKit"];
    BOOL directoryCreated = [NSFileManager.defaultManager createDirectoryAtURL:outputURL withIntermediateDirectories:YES attributes:nil error:&error];
    if (!directoryCreated || error) {
        WTFLogAlways("Error saving repro to %@ - %@", outputURL, error); // NOLINT
        return;
    }

    outputURL = [outputURL URLByAppendingPathComponent:@"psoRepro.mm"];
    if (FileSystem::overwriteEntireFile(outputURL.path, byteCast<uint8_t>(psoReproStringBuilder().span<Latin1Character>())))
        WTFLogAlways("Sucessfully saved repro to %@", outputURL); // NOLINT
    else
        WTFLogAlways("Error saving repro to %@ - %@", outputURL, error); // NOLINT
}

void dumpMetalReproCaseComputePSO(String&& shaderSource, String&& functionName)
{
    if (!enablePsoLogging())
        return;

    bool printToFile = !registerPsoExitHandlers();

    auto& sb = psoReproStringBuilder();
    sb.clear();
    sb.append(psoPreamble());
    /* NOLINT */ sb.append(R"(
    int main(int argc, const char * argv[])
    {
        @autoreleasepool {
        NSError *error = nil;

        // 1. Create a Metal device.
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            NSLog(@"Metal is not supported on this device.");
            return 1;
        }

        MTLCompileOptions* options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeRelaxed;
        options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
        options.preprocessorMacros = @{ @"__wgslMetalAppleGPUFamily" : [NSString stringWithFormat:@"%u", computeAppleGPUFamily(device)] };

        // 2. Load the shader source.
        NSString *shaderSource = @R"(
    )"_s); /* NOLINT */
    sb.append(shaderSource);
    sb.append(")\";"_s);
    /* NOLINT */ sb.append(R"(
    id<MTLLibrary> library = [device newLibraryWithSource:shaderSource options:options error:&error];
    if (!library || error) {
        NSLog(@"Failed to create library");
        return 1;
    }

    // 4. Create a Metal compute function.
    id<MTLFunction> computeFunction = [library newFunctionWithName:
    )"_s); /* NOLINT */
    sb.append(functionName);
    sb.append(")];"_s);
    /* NOLINT */ sb.append(R"(
    if (!computeFunction) {
        NSLog(@"Failed to create compute function.");
        return 1;
    }

    // 5. Create a Metal compute pipeline state.
    auto computePipelineDescriptor = [MTLComputePipelineDescriptor new];
    computePipelineDescriptor.computeFunction = computeFunction;
    computePipelineDescriptor.supportIndirectCommandBuffers = YES;
    id<MTLComputePipelineState> computePipelineState = [device newComputePipelineStateWithDescriptor:computePipelineDescriptor options:MTLPipelineOptionNone reflection:nil error:&error];

    if (computePipelineState)
        NSLog(@"SUCCESS");
    else
        NSLog(@"FAILED");
    }
    return 0;
    }
    )"_s); /* NOLINT */

    if (printToFile)
        printToFileForPsoRepro();
}

bool dumpMetalReproCaseRenderPSO(String&& vertexShaderSource, String&& vertexFunctionName, String&& fragmentShaderSource, String&& fragmentFunctionName, MTLRenderPipelineDescriptor* descriptor, std::span<const uint32_t> shaderLocations, uint32_t maxVertexBuffers)
{
    if (!enablePsoLogging())
        return false;

    bool printToFile = !registerPsoExitHandlers();

    auto& sb = psoReproStringBuilder();
    sb.append(psoPreamble());
    /* NOLINT */ sb.append(R"(
    static id<MTLRenderPipelineState> makePso(id<MTLDevice> device)
    {
        MTLRenderPipelineDescriptor* mtlRenderPipelineDescriptor = [MTLRenderPipelineDescriptor new];
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.mathMode = MTLMathModeRelaxed;
        options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
        options.preprocessorMacros = @{ @"__wgslMetalAppleGPUFamily" : [NSString stringWithFormat:@"%u", computeAppleGPUFamily(device)] };
        const auto& mtlColorAttachment = mtlRenderPipelineDescriptor.colorAttachments[0];

        id<MTLFunction> functionVS = nil;
        id<MTLFunction> functionFS = nil;
        NSError *error = nil;
        NSString *vertexShaderSource = @R"(
    )"_s); /* NOLINT */
    sb.append(vertexShaderSource);
    sb.append(")\";\nNSString *fragmentShaderSource = @R\"("_s);
    sb.append(fragmentShaderSource);
    sb.append(")\";"_s);
    /* NOLINT */ sb.append(R"(
    id<MTLLibrary> vertexLibrary = [device newLibraryWithSource:vertexShaderSource options:options error:&error];
    if (error)
        NSLog(@"error compiling vertex shader");

    id<MTLLibrary> fragmentLibrary = [device newLibraryWithSource:fragmentShaderSource options:options error:&error];
    if (error)
        NSLog(@"error compiling fragment shader");

    functionVS = [vertexLibrary newFunctionWithName:@")"_s); /* NOLINT */
    sb.append(vertexFunctionName);
    sb.append("\"]; functionFS = [fragmentLibrary newFunctionWithName:@\""_s);
    sb.append(fragmentFunctionName);
    /* NOLINT */ sb.append(R"("];

    mtlRenderPipelineDescriptor.vertexFunction = functionVS;
    mtlRenderPipelineDescriptor.fragmentFunction = functionFS;

    mtlRenderPipelineDescriptor.rasterSampleCount = )"_s); /* NOLINT */
    sb.append(makeString(descriptor.rasterSampleCount));
    sb.append(";\n mtlRenderPipelineDescriptor.alphaToCoverageEnabled = "_s);
    sb.append(makeString(descriptor.alphaToCoverageEnabled));
    sb.append(";\n mtlRenderPipelineDescriptor.alphaToOneEnabled = "_s);
    sb.append(makeString((int)descriptor.alphaToOneEnabled));
    sb.append(";\n mtlRenderPipelineDescriptor.rasterizationEnabled = "_s);
    sb.append(makeString((int)descriptor.rasterizationEnabled));
    sb.append(";\n mtlRenderPipelineDescriptor.maxVertexAmplificationCount = "_s);
    sb.append(makeString((unsigned)descriptor.maxVertexAmplificationCount));
    sb.append(";\n mtlRenderPipelineDescriptor.depthAttachmentPixelFormat = (MTLPixelFormat)"_s);
    sb.append(makeString((unsigned)descriptor.depthAttachmentPixelFormat));
    sb.append(";\n mtlRenderPipelineDescriptor.stencilAttachmentPixelFormat = (MTLPixelFormat)"_s);
    sb.append(makeString((unsigned)descriptor.stencilAttachmentPixelFormat));
    sb.append(";\n mtlRenderPipelineDescriptor.inputPrimitiveTopology = (MTLPrimitiveTopologyClass)"_s);
    sb.append(makeString((unsigned)descriptor.inputPrimitiveTopology));
    sb.append(";\n mtlRenderPipelineDescriptor.supportIndirectCommandBuffers = YES;\n MTLVertexDescriptor *vertexDescriptor = [MTLVertexDescriptor new];"_s);

    for (size_t i = 0; i < maxVertexBuffers; ++i) {
        if (MTLVertexBufferLayoutDescriptor* d = descriptor.vertexDescriptor.layouts[i]) {
            sb.append("{uint32_t location = "_s);
            sb.append(makeString(i));
            sb.append("; vertexDescriptor.layouts[location].stride = "_s);
            sb.append(makeString(d.stride));
            sb.append("; vertexDescriptor.layouts[location].stepFunction = (MTLVertexStepFunction)"_s);
            sb.append(d.stepFunction);
            sb.append("; vertexDescriptor.layouts[location].stepRate = "_s);
            sb.append(d.stepRate);
            sb.append(";} mtlRenderPipelineDescriptor.vertexDescriptor = vertexDescriptor; \n"_s);
        }
    }

    for (auto shaderLocation : shaderLocations) {
        if (MTLVertexAttributeDescriptor* a = descriptor.vertexDescriptor.attributes[shaderLocation]) {
            sb.append("{uint32_t shaderLocation = "_s);
            sb.append(makeString(shaderLocation));
            sb.append("; vertexDescriptor.attributes[shaderLocation].format = (MTLVertexFormat)"_s);
            sb.append(makeString((unsigned)a.format));
            sb.append("; vertexDescriptor.attributes[shaderLocation].bufferIndex = "_s);
            sb.append(makeString(a.bufferIndex));
            sb.append("; vertexDescriptor.attributes[shaderLocation].offset = "_s);
            sb.append(makeString(a.offset));
            sb.append(";}\n"_s);
        }
    }

    for (size_t i = 0; i < 8; ++i) {
        if (MTLRenderPipelineColorAttachmentDescriptor* c = descriptor.colorAttachments[i]) {
            sb.append("{uint32_t i = "_s);
            sb.append(makeString(i));
            sb.append("; MTLRenderPipelineColorAttachmentDescriptor* c = mtlRenderPipelineDescriptor.colorAttachments[i]; c.pixelFormat = (MTLPixelFormat)"_s);
            sb.append(makeString((unsigned)c.pixelFormat));
            sb.append("; c.blendingEnabled = (BOOL)"_s);
            sb.append(makeString(c.blendingEnabled));
            sb.append("; c.sourceRGBBlendFactor = (MTLBlendFactor)"_s);
            sb.append(makeString(c.sourceRGBBlendFactor));
            sb.append("; c.destinationRGBBlendFactor = (MTLBlendFactor)"_s);
            sb.append(makeString(c.destinationRGBBlendFactor));
            sb.append("; c.rgbBlendOperation = (MTLBlendOperation)"_s);
            sb.append(makeString(c.rgbBlendOperation));
            sb.append("; c.sourceAlphaBlendFactor = (MTLBlendFactor)"_s);
            sb.append(makeString(c.sourceAlphaBlendFactor));
            sb.append("; c.destinationAlphaBlendFactor = (MTLBlendFactor)"_s);
            sb.append(makeString(c.destinationAlphaBlendFactor));
            sb.append("; c.alphaBlendOperation = (MTLBlendOperation)"_s);
            sb.append(makeString(c.alphaBlendOperation));
            sb.append("; c.writeMask = (MTLColorWriteMask)"_s);
            sb.append(makeString(c.writeMask));
            sb.append(";}\n"_s);
        }
    }

    /* NOLINT */ sb.append(R"(mtlRenderPipelineDescriptor.vertexDescriptor = vertexDescriptor;
    return [device newRenderPipelineStateWithDescriptor:mtlRenderPipelineDescriptor error:&error];
    }

    int main()
    {
        auto device = MTLCreateSystemDefaultDevice();
        NSLog(@"Device is %@", [device name]);

        id<MTLRenderPipelineState> pso = makePso(device);
        if (pso)
            NSLog(@"PASS");
        else
            NSLog(@"FAIL");

        return 0;
    }
    )"_s); /* NOLINT */

    if (printToFile)
        printToFileForPsoRepro();

    return true;
}

void clearMetalPSORepro()
{
    psoReproStringBuilder().clear();
}

#endif

} // namespace WebGPU::Metal
