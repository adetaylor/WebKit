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

#import "WGSLAPI.h"
#import <WebGPU/WebGPUCpp.h>
#import <variant>
#import <wtf/CompletionHandler.h>
#import <wtf/FastMalloc.h>
#import <wtf/HashMap.h>
#import <wtf/Ref.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/text/StringHash.h>
#import <wtf/text/WTFString.h>


namespace WebGPU::Metal {

class Device;
class PipelineLayout;
struct WGSLModule;

// https://gpuweb.github.io/gpuweb/#gpushadermodule
class ShaderModule final : public WebGPU::ShaderModule {
    WTF_MAKE_TZONE_ALLOCATED(ShaderModule);
public:
    static Ref<ShaderModule> create(std::unique_ptr<WGSLModule>&& module, WGSL::StaticCheckResult&& checkResult, HashMap<String, Ref<PipelineLayout>>&& pipelineLayoutHints, HashMap<String, WGSL::CompiledEntryPoint>&& entryPointInformation, id<MTLLibrary> library, Device& device)
    {
        return adoptRef(*new ShaderModule(WTF::move(module), WTF::move(checkResult), WTF::move(pipelineLayoutHints), WTF::move(entryPointInformation), library, device));
    }
    static Ref<ShaderModule> createInvalid(Device& device, WGSL::StaticCheckResult&& checkResult = { })
    {
        return adoptRef(*new ShaderModule(device, WTF::move(checkResult)));
    }

    ~ShaderModule();

    void compilationInfo(CompletionHandler<void(WebGPU::CompilationInfo&&)>&&) final;
    void setLabel(String&&) final;

    bool isValid() const final { return !!m_wgslModule; }

    static WGSL::PipelineLayout convertPipelineLayout(const PipelineLayout&);
    static id<MTLLibrary> createLibrary(id<MTLDevice>, const String& msl, String&& label, NSError **, WGSL::DeviceState&&);
    static id<MTLLibrary> createLibrary(id<MTLDevice>, NSString *msl, NSString *label, NSError **, const WGSL::DeviceState&);
    static void createLibraryAsync(id<MTLDevice>, NSString *msl, NSString *label, const WGSL::DeviceState&, CompletionHandler<void(id<MTLLibrary>, NSError *)>&&);

    // Pipeline.mm's prepareLibrary: prepare + generate one entry point and roll the module back. A null
    // layout asks the compiler for the default layout; otherwise it writes minBindingSize back into it.
    WGSL::CompilationResult compile(const String& entryPoint, WGSL::PipelineLayout*, std::span<const WebGPU::ConstantEntry>, const WGSL::DeviceState&) const;
    std::optional<WGSL::WorkgroupSize> evaluateWorkgroupSize(const String& entryPoint, const WGSL::ResolvedOverrides&) const;
    // The same function the compiler uses for vertex bind group [[buffer(n)]] indices.
    static uint32_t LEGACY_NODELETE vertexBufferIndexForBindGroup(uint32_t groupIndex, uint32_t maxIndex);

    const PipelineLayout* pipelineLayoutHint(const String&) const;
    const WGSL::CompiledEntryPoint* entryPointInformation(const String&) const;
    id<MTLLibrary> library() const { return m_library; }

    Device& device() const { return m_device; }
    const String& LEGACY_NODELETE defaultVertexEntryPoint() const;
    const String& LEGACY_NODELETE defaultFragmentEntryPoint() const;
    const String& LEGACY_NODELETE defaultComputeEntryPoint() const;

    using VertexStageIn = HashMap<uint32_t, WebGPU::VertexFormat, DefaultHash<uint32_t>, WTF::UnsignedWithZeroKeyHashTraits<uint32_t>>;
    using FragmentOutputs = HashMap<uint32_t, MTLDataType, DefaultHash<uint32_t>, WTF::UnsignedWithZeroKeyHashTraits<uint32_t>>;
    struct VertexOutputFragmentInput {
        MTLDataType dataType { MTLDataTypeNone };
        std::optional<WGSL::Interpolation> interpolation { std::nullopt };
    };
    using VertexOutputs = HashMap<uint32_t, VertexOutputFragmentInput, DefaultHash<uint32_t>, WTF::UnsignedWithZeroKeyHashTraits<uint32_t>>;
    using FragmentInputs = VertexOutputs;
    const FragmentOutputs* fragmentReturnTypeForEntryPoint(const String&) const;
    const FragmentInputs* fragmentInputsForEntryPoint(const String&) const;
    const VertexStageIn* stageInTypesForEntryPoint(const String&) const;
    const VertexOutputs* vertexReturnTypeForEntryPoint(const String&) const;
    bool usesFrontFacingInInput(const String&) const;
    bool usesSampleIndexInInput(const String&) const;
    bool usesSampleMaskInInput(const String&) const;
    bool usesSampleMaskInOutput(const String&) const;
    bool usesFragDepth(const String&) const;
    bool usesPrimitiveIndexInInput(const String&) const;
    bool usesSubgroupInvocationIdInInput(const String&) const;
    bool usesSubgroupSizeInInput(const String&) const;
    uint32_t clipDistancesCount(const String&) const;

private:
    ShaderModule(std::unique_ptr<WGSLModule>&&, WGSL::StaticCheckResult&&, HashMap<String, Ref<PipelineLayout>>&&, HashMap<String, WGSL::CompiledEntryPoint>&&, id<MTLLibrary>, Device&);
    ShaderModule(Device&, WGSL::StaticCheckResult&&);

    // Errors and warnings for getCompilationInfo, and the IO reflection the constructor reads.
    const WGSL::StaticCheckResult m_checkResult;
    // The checked Swift module; null iff the shader module is invalid.
    const std::unique_ptr<WGSLModule> m_wgslModule;
    const HashMap<String, Ref<PipelineLayout>> m_pipelineLayoutHints;
    const HashMap<String, WGSL::CompiledEntryPoint> m_entryPointInformation;
    const id<MTLLibrary> m_library { nil }; // This is only non-null if we could compile the module early.

    const Ref<Device> m_device;
    HashMap<String, FragmentOutputs> m_fragmentReturnTypeForEntryPoint;
    HashMap<String, FragmentInputs> m_fragmentInputsForEntryPoint;
    HashMap<String, VertexOutputs> m_vertexReturnTypeForEntryPoint;
    HashMap<String, VertexStageIn> m_stageInTypesForEntryPoint;

    String m_defaultVertexEntryPoint;
    String m_defaultFragmentEntryPoint;
    String m_defaultComputeEntryPoint;

    struct ShaderModuleState {
        bool usesFrontFacingInInput { false };
        bool usesSampleIndexInInput { false };
        bool usesSampleMaskInInput { false };
        bool usesSampleMaskInOutput { false };
        bool usesFragDepth { false };
        bool usesPrimitiveIndexInInput { false };
        bool usesSubgroupInvocationIdInInput { false };
        bool usesSubgroupSizeInInput { false };
        uint32_t clipDistancesCount { 0 }; // Number of clip distances (0 if not used)
    };
    const ShaderModuleState* shaderModuleState(const String&) const;
    ShaderModuleState& populateShaderModuleState(const String&);
    HashMap<String, ShaderModuleState> m_usageInformationPerEntryPoint;
};

} // namespace WebGPU::Metal
