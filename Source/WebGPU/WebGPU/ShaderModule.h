/*
 * Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

#import "WGSLAPI.h"
#import <WebGPU/WebGPUCpp.h>
#import <memory>
#import <span>
#import <variant>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/text/StringHash.h>
#import <wtf/text/WTFString.h>

#if !defined(__swift__)
namespace WebGPU {
class ShaderModuleImpl;
}
#endif

namespace WebGPU::Metal {

class Device;
class PipelineLayout;

// Holds the Swift ShaderModuleImpl. Defined in ShaderModule.mm, where the generated Swift interop header is includable.
struct ShaderModuleImplBox;

// https://gpuweb.github.io/gpuweb/#gpushadermodule
// The Swift ShaderModuleImpl owns the checked WGSL module, the compilation messages, the per-entry-point IO
// reflection and the default entry points; pipeline creation reads them from it directly.
class ShaderModule final : public WebGPU::ShaderModule {
    WTF_MAKE_TZONE_ALLOCATED(ShaderModule);
public:
    static Ref<ShaderModule> create(std::unique_ptr<ShaderModuleImplBox>&&);
    static Ref<ShaderModule> createInvalid(Device&);

    ~ShaderModule();

    void compilationInfo(CompletionHandler<void(WebGPU::CompilationInfo&&)>&&) final;
    void setLabel(String&&) final;

    bool isValid() const final;

#if !defined(__swift__)
    // Borrowed from the Impl, which holds the reference.
    Device& device() const;
    WebGPU::ShaderModuleImpl& swiftImpl() const LIFETIME_BOUND;
#endif

private:
    explicit ShaderModule(std::unique_ptr<ShaderModuleImplBox>&&);

    const std::unique_ptr<ShaderModuleImplBox> m_impl;
};

// For the Swift pipeline-creation code.

// `work` runs on a thread with the stack WGSL compilation needs (the calling thread unless the compiler was built
// without optimization), and has returned when this does.
void runOnWGSLCompileThread(NOESCAPE void (^work)(void));
// Reorders `keys` (distinct) into the order a HashMap<uint32_t, T, DefaultHash<uint32_t>, UnsignedWithZeroKeyHashTraits<uint32_t>>
// filled with them in their current order iterates them, for walks whose first failure picks an error message.
void sortInWTFHashTableOrder(std::span<uint32_t> keys NOESCAPE);

} // namespace WebGPU::Metal
