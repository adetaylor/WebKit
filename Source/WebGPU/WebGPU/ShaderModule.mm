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
#import "ShaderModule.h"

#import "APIConversions.h"
#import "Device.h"
#import "PipelineLayout.h"

#import <WebGPU/WebGPU.h>
#import <wtf/BlockPtr.h>
#import <wtf/DataLog.h>
#import <wtf/StringPrintStream.h>
#import <wtf/TZoneMallocInlines.h>

#if HAVE(WGSL_COMPILER)
#import "CxxBridging.h"
#import <WebGPU/CxxBridgingPublic.h>
#import <WebGPU/WGPUTextureImpl.h>
#import "WebGPUSwift-Generated.h"
#import <notify.h>
#import <unicode/uchar.h>
#import <unicode/uset.h>
#import <wtf/Threading.h>
#import <wtf/darwin/DispatchExtras.h>

namespace WGSL::Interop {

IdentifierRanges icuIdentifierRanges(bool xidContinue)
{
    UErrorCode status = U_ZERO_ERROR;
    const USet* set = u_getBinaryPropertySet(xidContinue ? UCHAR_XID_CONTINUE : UCHAR_XID_START, &status);
    RELEASE_ASSERT(U_SUCCESS(status));
    int32_t itemCount = uset_getItemCount(set);
    IdentifierRanges result;
    result.reserveInitialCapacity(2 * itemCount);
    for (int32_t i = 0; i < itemCount; ++i) {
        UChar32 start = 0;
        UChar32 end = 0;
        auto stringLength = uset_getItem(set, i, &start, &end, nullptr, 0, &status);
        RELEASE_ASSERT(!stringLength && U_SUCCESS(status));
        result.append(start);
        result.append(end + 1);
    }
    return result;
}

} // namespace WGSL::Interop
#endif

namespace WebGPU::Metal {

struct WGSLModule {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(WGSLModule);
#if HAVE(WGSL_COMPILER)
    WebGPU::WGSLShaderModule module;
#endif
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(WGSLModule);

#if HAVE(WGSL_COMPILER)
// The compiler built without optimization needs a larger stack than the WebGPU thread's; it then runs on its own thread.
static void runOnWGSLCompileThread(NOESCAPE const Function<void()>& work)
{
    auto stackSize = WebGPU::wgslRecommendedCompileStackSize();
    if (!stackSize) {
        work();
        return;
    }

    Thread::create("WGSL compile"_s, [&work] {
        work();
    }, ThreadType::Graphics, Thread::QOS::UserInteractive, Thread::SchedulingPolicy::Other, StackAllocationSpecification::RequestSize(stackSize))->waitForCompletion();
}

static void dumpMetalCodeIfNeeded(const String& metalCode)
{
    static bool dumpMetalCode = false;
    static std::once_flag onceFlag;
    std::call_once(onceFlag, [] {
        int dumpMetalCodeToken;
        notify_register_dispatch("com.apple.WebKit.WebGPU.TogglePrintMetalCode", &dumpMetalCodeToken, mainDispatchQueueSingleton(), ^(int) {
            dumpMetalCode = !dumpMetalCode;
        });
    });

    if (dumpMetalCode) {
        dataLogLn("Generated Metal code:");
        dataLogLn(metalCode);
    }
}
#endif

static MTLCompileOptions *compileOptions(const WGSL::DeviceState& deviceState)
{
    static bool requireSafeMath = false;
    auto options = [MTLCompileOptions new];
    options.preprocessorMacros = @{ @"__wgslMetalAppleGPUFamily" : [NSString stringWithFormat:@"%u", deviceState.appleGPUFamily] };
#if ENABLE(WEBGPU_BY_DEFAULT)
    static auto mathMode = MTLMathModeRelaxed;
    static auto mathFunctions = MTLMathFloatingPointFunctionsFast;
    static std::once_flag onceFlag;
    std::call_once(onceFlag, [&] {
        requireSafeMath = [[NSUserDefaults standardUserDefaults] boolForKey:@"WebKitWebGPUEnableSafeMath"];
        mathMode = requireSafeMath || [[NSUserDefaults standardUserDefaults] boolForKey:@"WebKitWebGPUEnableSafeMathMode"] ? MTLMathModeSafe : MTLMathModeRelaxed;
        mathFunctions = requireSafeMath || [[NSUserDefaults standardUserDefaults] boolForKey:@"WebKitWebGPUEnablePrecisionMathFunctions"] ? MTLMathFloatingPointFunctionsPrecise : MTLMathFloatingPointFunctionsFast;
    });
    options.mathMode = mathMode;
    options.mathFloatingPointFunctions = mathFunctions;
#else
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    options.fastMathEnabled = !requireSafeMath;
ALLOW_DEPRECATED_DECLARATIONS_END
#endif

    if (deviceState.usesInvariant)
        options.preserveInvariance = true;

    return options;
}

static NSError *libraryCompilationError(NSString *msl, NSError *compilationError)
{
    // FIXME: https://bugs.webkit.org/show_bug.cgi?id=250442
    WTFLogAlways("MSL compilation error: %@", [compilationError localizedDescription]); // NOLINT
    return [NSError errorWithDomain:@"WebGPU" code:1 userInfo:@{ NSLocalizedDescriptionKey: adoptNS([[NSString alloc] initWithFormat:@"Failed to compile the shader source, generated metal:\n%@ - error %@", msl, [compilationError localizedDescription]]).get() }];
}

id<MTLLibrary> ShaderModule::createLibrary(id<MTLDevice> device, const String& msl, String&& label, NSError** error, WGSL::DeviceState&& deviceState)
{
    return createLibrary(device, msl.createNSString().get(), label.createNSString().get(), error, deviceState);
}

id<MTLLibrary> ShaderModule::createLibrary(id<MTLDevice> device, NSString *msl, NSString *label, NSError** error, const WGSL::DeviceState& deviceState)
{
    NSError *compilationError = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:msl options:compileOptions(deviceState) error:&compilationError];
    if (!library || compilationError) {
        if (error)
            *error = libraryCompilationError(msl, compilationError);
        return nil;
    }
    library.label = label;
    return library;
}

void ShaderModule::createLibraryAsync(id<MTLDevice> device, NSString *msl, NSString *label, const WGSL::DeviceState& deviceState, CompletionHandler<void(id<MTLLibrary>, NSError *)>&& callback)
{
    [device newLibraryWithSource:msl options:compileOptions(deviceState) completionHandler:makeBlockPtr([msl, label, callback = WTF::move(callback)](id<MTLLibrary> library, NSError *compilationError) mutable {
        if (!library || compilationError) {
            callback(nil, libraryCompilationError(msl, compilationError));
            return;
        }
        library.label = label;
        callback(library, nil);
    }).get()];
}

static String featureName(WebGPU::FeatureName feature)
{
    switch (feature) {
    case WebGPU::FeatureName::DepthClipControl:
        return "depth-clip-control"_s;
    case WebGPU::FeatureName::Depth32floatStencil8:
        return "depth32float-stencil8"_s;
    case WebGPU::FeatureName::TimestampQuery:
        return "timestamp-query"_s;
    case WebGPU::FeatureName::TextureCompressionBc:
        return "texture-compression-bc"_s;
    case WebGPU::FeatureName::TextureCompressionBcSliced3d:
        return "texture-compression-bc-sliced-3d"_s;
    case WebGPU::FeatureName::TextureCompressionEtc2:
        return "texture-compression-etc2"_s;
    case WebGPU::FeatureName::TextureCompressionAstc:
        return "texture-compression-astc"_s;
    case WebGPU::FeatureName::TextureCompressionAstcSliced3d:
        return "texture-compression-astc-sliced-3d"_s;
    case WebGPU::FeatureName::IndirectFirstInstance:
        return "indirect-first-instance"_s;
    case WebGPU::FeatureName::ShaderF16:
        return "shader-f16"_s;
    case WebGPU::FeatureName::Rg11b10ufloatRenderable:
        return "rg11b10ufloat-renderable"_s;
    case WebGPU::FeatureName::Bgra8unormStorage:
        return "bgra8unorm-storage"_s;
    case WebGPU::FeatureName::Float32Filterable:
        return "float32-filterable"_s;
    case WebGPU::FeatureName::Float32Blendable:
        return "float32-blendable"_s;
    case WebGPU::FeatureName::ClipDistances:
        return "clip-distances"_s;
    case WebGPU::FeatureName::PrimitiveIndex:
        return "primitive-index"_s;
    case WebGPU::FeatureName::DualSourceBlending:
        return "dual-source-blending"_s;
    case WebGPU::FeatureName::Float16Renderable:
        return "float16-renderable"_s;
    case WebGPU::FeatureName::Float32Renderable:
        return "float32-renderable"_s;
    case WebGPU::FeatureName::CoreFeaturesAndLimits:
        return "core-features-and-limits"_s;
    case WebGPU::FeatureName::TextureFormatsTier1:
        return "texture-formats-tier1"_s;
    case WebGPU::FeatureName::TextureFormatsTier2:
        return "texture-formats-tier2"_s;
    case WebGPU::FeatureName::Subgroups:
        return "subgroups"_s;
    }
}

static OptionSet<WGSL::Feature> wgslFeatures(const Vector<WebGPU::FeatureName>& features)
{
    OptionSet<WGSL::Feature> result;
    for (auto feature : features) {
        switch (feature) {
        case WebGPU::FeatureName::ClipDistances:
            result.add(WGSL::Feature::ClipDistances);
            break;
        case WebGPU::FeatureName::ShaderF16:
            result.add(WGSL::Feature::ShaderF16);
            break;
        case WebGPU::FeatureName::PrimitiveIndex:
            result.add(WGSL::Feature::PrimitiveIndex);
            break;
        case WebGPU::FeatureName::Subgroups:
            result.add(WGSL::Feature::Subgroups);
            break;
        default:
            break;
        }
    }
    return result;
}

static Ref<ShaderModule> handleShaderSuccessOrFailure(WebGPU::Metal::Device &object, std::unique_ptr<WGSLModule>&& module, WGSL::StaticCheckResult&& checkResult, const WebGPU::ShaderModuleDescriptor &descriptor)
{
    if (module) {
        // FIXME: re-enable early compilation of descriptor.hints later on once deferred compilation is fully implemented
        // https://bugs.webkit.org/show_bug.cgi?id=254258
        UNUSED_PARAM(descriptor);
        return ShaderModule::create(WTF::move(module), WTF::move(checkResult), { }, { }, nil, object);
    }

    StringPrintStream message;
    message.print(String::number(checkResult.errors.size()), " error", checkResult.errors.size() != 1 ? "s" : "", " generated while compiling the shader:"_s);
    for (const auto& error : checkResult.errors)
        message.print("\n"_s, error);

    object.generateAValidationError(message.toString());
    return ShaderModule::createInvalid(object, WTF::move(checkResult));
}

RefPtr<WebGPU::ShaderModule> Device::createShaderModule(const WebGPU::ShaderModuleDescriptor& descriptor)
{
    if (!isValid())
        return ShaderModule::createInvalid(*this);

    WGSL::Configuration configuration {
        .maxBuffersPlusVertexBuffersForVertexStage = maxBuffersPlusVertexBuffersForVertexStage(),
        .maxBuffersForFragmentStage = maxBuffersForFragmentStage(),
        .maxBuffersForComputeStage = maxBuffersForComputeStage(),
        .maximumCombinedWorkgroupVariablesSize = limits().maxComputeWorkgroupStorageSize,
        .supportedFeatures = wgslFeatures(m_capabilities.features)
    };

    WGSL::StaticCheckResult checkResult;
    std::unique_ptr<WGSLModule> module;
#if HAVE(WGSL_COMPILER)
    runOnWGSLCompileThread([&] {
        if (auto checkedModule = WebGPU::wgslStaticCheck(descriptor.code, configuration, checkResult))
            module = makeUnique<WGSLModule>(WGSLModule { checkedModule.get() });
    });
#else
    UNUSED_VARIABLE(configuration);
    checkResult.errors.append(WGSL::CompilationMessage { "WGSL shader compilation is not available in this configuration"_s, 0, 0, 0, 0 });
#endif

    return handleShaderSuccessOrFailure(*this, WTF::move(module), WTF::move(checkResult), descriptor);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(ShaderModule);

static MTLDataType LEGACY_NODELETE metalDataTypeFromScalar(WGSL::IOType::Scalar scalar, int vectorSize = 1)
{
    switch (vectorSize) {
    case 1:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return MTLDataTypeInt;
        case WGSL::IOType::Scalar::U32:
            return MTLDataTypeUInt;
        case WGSL::IOType::Scalar::F16:
            return MTLDataTypeHalf;
        case WGSL::IOType::Scalar::F32:
            return MTLDataTypeFloat;
        case WGSL::IOType::Scalar::Bool:
            return MTLDataTypeBool;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    case 2:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return MTLDataTypeInt2;
        case WGSL::IOType::Scalar::U32:
            return MTLDataTypeUInt2;
        case WGSL::IOType::Scalar::F16:
            return MTLDataTypeHalf2;
        case WGSL::IOType::Scalar::F32:
            return MTLDataTypeFloat2;
        case WGSL::IOType::Scalar::Bool:
            return MTLDataTypeBool2;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    case 3:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return MTLDataTypeInt3;
        case WGSL::IOType::Scalar::U32:
            return MTLDataTypeUInt3;
        case WGSL::IOType::Scalar::F16:
            return MTLDataTypeHalf3;
        case WGSL::IOType::Scalar::F32:
            return MTLDataTypeFloat3;
        case WGSL::IOType::Scalar::Bool:
            return MTLDataTypeBool3;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    case 4:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return MTLDataTypeInt4;
        case WGSL::IOType::Scalar::U32:
            return MTLDataTypeUInt4;
        case WGSL::IOType::Scalar::F16:
            return MTLDataTypeHalf4;
        case WGSL::IOType::Scalar::F32:
            return MTLDataTypeFloat4;
        case WGSL::IOType::Scalar::Bool:
            return MTLDataTypeBool4;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

static WebGPU::VertexFormat LEGACY_NODELETE vertexFormatTypeFromScalar(WGSL::IOType::Scalar scalar, int vectorSize)
{
    switch (vectorSize) {
    case 1:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return WebGPU::VertexFormat::Sint32;
        case WGSL::IOType::Scalar::U32:
            return WebGPU::VertexFormat::Uint32;
        case WGSL::IOType::Scalar::F16:
            return WebGPU::VertexFormat::Float32;
        case WGSL::IOType::Scalar::F32:
            return WebGPU::VertexFormat::Float32;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    case 2:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return WebGPU::VertexFormat::Sint32x2;
        case WGSL::IOType::Scalar::U32:
            return WebGPU::VertexFormat::Uint32x2;
        case WGSL::IOType::Scalar::F16:
            return WebGPU::VertexFormat::Float16x2;
        case WGSL::IOType::Scalar::F32:
            return WebGPU::VertexFormat::Float32x2;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    case 3:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return WebGPU::VertexFormat::Sint32x3;
        case WGSL::IOType::Scalar::U32:
            return WebGPU::VertexFormat::Uint32x3;
        case WGSL::IOType::Scalar::F16:
            return WebGPU::VertexFormat::Float16x4;
        case WGSL::IOType::Scalar::F32:
            return WebGPU::VertexFormat::Float32x3;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    case 4:
        switch (scalar) {
        case WGSL::IOType::Scalar::I32:
            return WebGPU::VertexFormat::Sint32x4;
        case WGSL::IOType::Scalar::U32:
            return WebGPU::VertexFormat::Uint32x4;
        case WGSL::IOType::Scalar::F16:
            return WebGPU::VertexFormat::Float16x4;
        case WGSL::IOType::Scalar::F32:
            return WebGPU::VertexFormat::Float32x4;
        default:
            RELEASE_ASSERT_NOT_REACHED();
        }
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

static MTLDataType metalDataTypeForIOType(const WGSL::IOType& type)
{
    switch (type.shape) {
    case WGSL::IOType::Shape::Missing:
    case WGSL::IOType::Shape::Other:
        return MTLDataTypeNone;
    case WGSL::IOType::Shape::Scalar:
        return metalDataTypeFromScalar(type.scalar);
    case WGSL::IOType::Shape::Vector:
        return metalDataTypeFromScalar(type.scalar, type.vectorSize);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static WebGPU::VertexFormat vertexFormatTypeForIOType(const WGSL::IOType& type)
{
    switch (type.shape) {
    case WGSL::IOType::Shape::Missing:
    case WGSL::IOType::Shape::Other:
        RELEASE_ASSERT_NOT_REACHED();
    case WGSL::IOType::Shape::Scalar:
        return vertexFormatTypeFromScalar(type.scalar, 1);
    case WGSL::IOType::Shape::Vector:
        return vertexFormatTypeFromScalar(type.scalar, type.vectorSize);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

static ShaderModule::VertexStageIn stageInMap(const Vector<WGSL::IOLocation>& locations)
{
    ShaderModule::VertexStageIn result;
    for (auto& location : locations)
        result.add(location.location, vertexFormatTypeForIOType(location.type));
    return result;
}

static ShaderModule::VertexOutputs interStageMap(const Vector<WGSL::IOLocation>& locations)
{
    ShaderModule::VertexOutputs result;
    for (auto& location : locations) {
        result.add(location.location, ShaderModule::VertexOutputFragmentInput {
            .dataType = metalDataTypeForIOType(location.type),
            .interpolation = location.interpolation
        });
    }
    return result;
}

static ShaderModule::FragmentOutputs fragmentOutputMap(const Vector<WGSL::IOLocation>& locations)
{
    ShaderModule::FragmentOutputs result;
    for (auto& location : locations)
        result.add(location.location, metalDataTypeForIOType(location.type));
    return result;
}

const ShaderModule::ShaderModuleState* ShaderModule::shaderModuleState(const String& entryPoint) const
{
    if (entryPoint.isNull())
        return nullptr;

    if (auto it = m_usageInformationPerEntryPoint.find(entryPoint); it != m_usageInformationPerEntryPoint.end())
        return &it->value;

    return nullptr;
}

ShaderModule::ShaderModuleState& ShaderModule::populateShaderModuleState(const String& entryPoint)
{
    if (auto it = m_usageInformationPerEntryPoint.find(entryPoint); it != m_usageInformationPerEntryPoint.end())
        return it->value;

    return m_usageInformationPerEntryPoint.add(entryPoint, ShaderModule::ShaderModuleState()).iterator->value;
}

bool ShaderModule::usesFrontFacingInInput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesFrontFacingInInput;
    return false;
}
bool ShaderModule::usesSampleIndexInInput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesSampleIndexInInput;
    return false;
}
bool ShaderModule::usesSampleMaskInInput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesSampleMaskInInput;
    return false;
}

bool ShaderModule::usesSampleMaskInOutput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesSampleMaskInOutput;
    return false;
}

bool ShaderModule::usesFragDepth(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesFragDepth;
    return false;
}

bool ShaderModule::usesPrimitiveIndexInInput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesPrimitiveIndexInInput;
    return false;
}

bool ShaderModule::usesSubgroupInvocationIdInInput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesSubgroupInvocationIdInInput;
    return false;
}

bool ShaderModule::usesSubgroupSizeInInput(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->usesSubgroupSizeInInput;
    return false;
}

uint32_t ShaderModule::clipDistancesCount(const String& entryPoint) const
{
    if (auto state = shaderModuleState(entryPoint))
        return state->clipDistancesCount;
    return 0;
}

ShaderModule::ShaderModule(std::unique_ptr<WGSLModule>&& module, WGSL::StaticCheckResult&& checkResult, HashMap<String, Ref<PipelineLayout>>&& pipelineLayoutHints, HashMap<String, WGSL::CompiledEntryPoint>&& entryPointInformation, id<MTLLibrary> library, Device& device)
    : m_checkResult(WTF::move(checkResult))
    , m_wgslModule(WTF::move(module))
    , m_pipelineLayoutHints(WTF::move(pipelineLayoutHints))
    , m_entryPointInformation(WTF::move(entryPointInformation))
    , m_library(library)
    , m_device(device)
{
    bool allowVertexDefault = true, allowFragmentDefault = true, allowComputeDefault = true;
    if (!m_wgslModule)
        return;

    for (auto& entryPoint : m_checkResult.entryPoints) {
        ShaderModuleState state {
            .usesFrontFacingInInput = entryPoint.usesFrontFacingInInput,
            .usesSampleIndexInInput = entryPoint.usesSampleIndexInInput,
            .usesSampleMaskInInput = entryPoint.usesSampleMaskInInput,
            .usesSampleMaskInOutput = entryPoint.usesSampleMaskInOutput,
            .usesFragDepth = entryPoint.usesFragDepth,
            .usesPrimitiveIndexInInput = entryPoint.usesPrimitiveIndexInInput,
            .usesSubgroupInvocationIdInInput = entryPoint.usesSubgroupInvocationIdInInput,
            .usesSubgroupSizeInInput = entryPoint.usesSubgroupSizeInInput,
            .clipDistancesCount = entryPoint.clipDistancesCount,
        };
        // Only entry points that use one of these have a state.
        if (state.usesFrontFacingInInput || state.usesSampleIndexInInput || state.usesSampleMaskInInput || state.usesSampleMaskInOutput
            || state.usesFragDepth || state.usesPrimitiveIndexInInput || state.usesSubgroupInvocationIdInInput || state.usesSubgroupSizeInInput
            || state.clipDistancesCount)
            populateShaderModuleState(entryPoint.name) = state;
        switch (entryPoint.stage) {
        case WGSL::ShaderStage::Vertex: {
            m_stageInTypesForEntryPoint.add(entryPoint.name, stageInMap(entryPoint.stageIn));
            if (entryPoint.vertexOutputs)
                m_vertexReturnTypeForEntryPoint.add(entryPoint.name, interStageMap(*entryPoint.vertexOutputs));
            if (!allowVertexDefault || m_defaultVertexEntryPoint.length()) {
                allowVertexDefault = false;
                m_defaultVertexEntryPoint = emptyString();
                continue;
            }
            m_defaultVertexEntryPoint = entryPoint.name;
        } break;
        case WGSL::ShaderStage::Fragment: {
            m_fragmentInputsForEntryPoint.add(entryPoint.name, interStageMap(entryPoint.fragmentInputs));
            if (entryPoint.fragmentOutputs)
                m_fragmentReturnTypeForEntryPoint.add(entryPoint.name, fragmentOutputMap(*entryPoint.fragmentOutputs));
            if (!allowFragmentDefault || m_defaultFragmentEntryPoint.length()) {
                allowFragmentDefault = false;
                m_defaultFragmentEntryPoint = emptyString();
                continue;
            }
            m_defaultFragmentEntryPoint = entryPoint.name;
        } break;
        case WGSL::ShaderStage::Compute: {
            if (!allowComputeDefault || m_defaultComputeEntryPoint.length()) {
                allowComputeDefault = false;
                m_defaultComputeEntryPoint = emptyString();
                continue;
            }
            m_defaultComputeEntryPoint = entryPoint.name;
        } break;
        default:
            ASSERT_NOT_REACHED();
            break;
        }
    }
}

const ShaderModule::FragmentInputs* ShaderModule::fragmentInputsForEntryPoint(const String& entryPoint) const
{
    if (entryPoint.isNull())
        return nullptr;

    if (auto it = m_fragmentInputsForEntryPoint.find(entryPoint); it != m_fragmentInputsForEntryPoint.end())
        return &it->value;

    return nullptr;
}

const ShaderModule::FragmentOutputs* ShaderModule::fragmentReturnTypeForEntryPoint(const String& entryPoint) const
{
    if (entryPoint.isNull())
        return nullptr;

    if (auto it = m_fragmentReturnTypeForEntryPoint.find(entryPoint); it != m_fragmentReturnTypeForEntryPoint.end())
        return &it->value;

    return nullptr;
}

const ShaderModule::VertexOutputs* ShaderModule::vertexReturnTypeForEntryPoint(const String& entryPoint) const
{
    if (entryPoint.isNull())
        return nullptr;

    if (auto it = m_vertexReturnTypeForEntryPoint.find(entryPoint); it != m_vertexReturnTypeForEntryPoint.end())
        return &it->value;

    return nullptr;
}

const ShaderModule::VertexStageIn* ShaderModule::stageInTypesForEntryPoint(const String& entryPoint) const
{
    if (!entryPoint.length())
        return nullptr;

    if (auto it = m_stageInTypesForEntryPoint.find(entryPoint); it != m_stageInTypesForEntryPoint.end())
        return &it->value;

    return nullptr;
}

ShaderModule::ShaderModule(Device& device, WGSL::StaticCheckResult&& checkResult)
    : m_checkResult(WTF::move(checkResult))
    , m_device(device)
{
}

ShaderModule::~ShaderModule() = default;

struct Messages {
    const Vector<WGSL::CompilationMessage>& messages;
    WebGPU::CompilationMessageType type;
};

static void appendMessages(Vector<WebGPU::CompilationMessage>& result, const Messages& messages)
{
    for (const auto& compilationMessage : messages.messages) {
        result.append({
            .message = compilationMessage.message(),
            .type = messages.type,
            .lineNum = compilationMessage.lineNumber(),
            .linePos = compilationMessage.lineOffset() + 1,
            .offset = compilationMessage.offset(),
            .length = compilationMessage.length(),
        });
    }
}

void ShaderModule::compilationInfo(CompletionHandler<void(WebGPU::CompilationInfo&&)>&& callback)
{
    WebGPU::CompilationInfo compilationInfo;
    appendMessages(compilationInfo.messages, { m_checkResult.errors, WebGPU::CompilationMessageType::Error });
    appendMessages(compilationInfo.messages, { m_checkResult.warnings, WebGPU::CompilationMessageType::Warning });
    callback(WTF::move(compilationInfo));
}

void ShaderModule::setLabel(String&& label)
{
    if (m_library)
        m_library.label = label.createNSString().get();
}

static auto LEGACY_NODELETE wgslBindingType(BindGroupLayout::BufferBindingType bindingType)
{
    switch (bindingType) {
    case BindGroupLayout::BufferBindingType::Uniform:
        return WGSL::BufferBindingType::Uniform;
    case BindGroupLayout::BufferBindingType::Storage:
        return WGSL::BufferBindingType::Storage;
    case BindGroupLayout::BufferBindingType::ReadOnlyStorage:
        return WGSL::BufferBindingType::ReadOnlyStorage;
    case BindGroupLayout::BufferBindingType::Float3x2:
    case BindGroupLayout::BufferBindingType::Float4x3:
    case BindGroupLayout::BufferBindingType::Float3x3:
    case BindGroupLayout::BufferBindingType::UInt2:
    case BindGroupLayout::BufferBindingType::ArrayLength:
        ASSERT_NOT_REACHED("Unexpected buffer bindingType");
        return WGSL::BufferBindingType::Uniform;
    }
}

static auto LEGACY_NODELETE wgslSamplerType(WebGPU::SamplerBindingType bindingType)
{
    switch (bindingType) {
    case WebGPU::SamplerBindingType::Filtering:
        return WGSL::SamplerBindingType::Filtering;
    case WebGPU::SamplerBindingType::Comparison:
        return WGSL::SamplerBindingType::Comparison;
    case WebGPU::SamplerBindingType::NonFiltering:
        return WGSL::SamplerBindingType::NonFiltering;
    }
}

static auto LEGACY_NODELETE wgslSampleType(WebGPU::TextureSampleType sampleType)
{
    switch (sampleType) {
    case WebGPU::TextureSampleType::Sint:
        return WGSL::TextureSampleType::SignedInt;
    case WebGPU::TextureSampleType::Uint:
        return WGSL::TextureSampleType::UnsignedInt;
    case WebGPU::TextureSampleType::Depth:
        return WGSL::TextureSampleType::Depth;
    case WebGPU::TextureSampleType::Float:
        return WGSL::TextureSampleType::Float;
    case WebGPU::TextureSampleType::UnfilterableFloat:
        return WGSL::TextureSampleType::UnfilterableFloat;
    }
}

static auto LEGACY_NODELETE wgslViewDimension(WebGPU::TextureViewDimension viewDimension)
{
    switch (viewDimension) {
    case WebGPU::TextureViewDimension::Cube:
        return WGSL::TextureViewDimension::Cube;
    case WebGPU::TextureViewDimension::_1d:
        return WGSL::TextureViewDimension::OneDimensional;
    case WebGPU::TextureViewDimension::_2d:
        return WGSL::TextureViewDimension::TwoDimensional;
    case WebGPU::TextureViewDimension::_3d:
        return WGSL::TextureViewDimension::ThreeDimensional;
    case WebGPU::TextureViewDimension::CubeArray:
        return WGSL::TextureViewDimension::CubeArray;
    case WebGPU::TextureViewDimension::_2dArray:
        return WGSL::TextureViewDimension::TwoDimensionalArray;
    }
}

static WGSL::StorageTextureAccess LEGACY_NODELETE wgslAccess(WebGPU::StorageTextureAccess access)
{
    switch (access) {
    case WebGPU::StorageTextureAccess::WriteOnly:
        return WGSL::StorageTextureAccess::WriteOnly;
    case WebGPU::StorageTextureAccess::ReadOnly:
        return WGSL::StorageTextureAccess::ReadOnly;
    case WebGPU::StorageTextureAccess::ReadWrite:
        return WGSL::StorageTextureAccess::ReadWrite;
    }
}

static WGSL::TexelFormat LEGACY_NODELETE wgslFormat(WebGPU::TextureFormat format)
{
    switch (format) {
    case WebGPU::TextureFormat::Bgra8unorm:
        return WGSL::TexelFormat::BGRA8unorm;
    case WebGPU::TextureFormat::R16float:
        return WGSL::TexelFormat::R16float;
    case WebGPU::TextureFormat::R16sint:
        return WGSL::TexelFormat::R16sint;
    case WebGPU::TextureFormat::R16snorm:
        return WGSL::TexelFormat::R16snorm;
    case WebGPU::TextureFormat::R16uint:
        return WGSL::TexelFormat::R16uint;
    case WebGPU::TextureFormat::R16unorm:
        return WGSL::TexelFormat::R16unorm;
    case WebGPU::TextureFormat::R32float:
        return WGSL::TexelFormat::R32float;
    case WebGPU::TextureFormat::R32sint:
        return WGSL::TexelFormat::R32sint;
    case WebGPU::TextureFormat::R32uint:
        return WGSL::TexelFormat::R32uint;
    case WebGPU::TextureFormat::R8sint:
        return WGSL::TexelFormat::R8sint;
    case WebGPU::TextureFormat::R8snorm:
        return WGSL::TexelFormat::R8snorm;
    case WebGPU::TextureFormat::R8uint:
        return WGSL::TexelFormat::R8uint;
    case WebGPU::TextureFormat::R8unorm:
        return WGSL::TexelFormat::R8unorm;
    case WebGPU::TextureFormat::Rg11b10ufloat:
        return WGSL::TexelFormat::RG11B10ufloat;
    case WebGPU::TextureFormat::Rg16float:
        return WGSL::TexelFormat::RG16float;
    case WebGPU::TextureFormat::Rg16sint:
        return WGSL::TexelFormat::RG16sint;
    case WebGPU::TextureFormat::Rg16snorm:
        return WGSL::TexelFormat::RG16snorm;
    case WebGPU::TextureFormat::Rg16uint:
        return WGSL::TexelFormat::RG16uint;
    case WebGPU::TextureFormat::Rg16unorm:
        return WGSL::TexelFormat::RG16unorm;
    case WebGPU::TextureFormat::Rg32float:
        return WGSL::TexelFormat::RG32float;
    case WebGPU::TextureFormat::Rg32sint:
        return WGSL::TexelFormat::RG32sint;
    case WebGPU::TextureFormat::Rg32uint:
        return WGSL::TexelFormat::RG32uint;
    case WebGPU::TextureFormat::Rg8sint:
        return WGSL::TexelFormat::RG8sint;
    case WebGPU::TextureFormat::Rg8snorm:
        return WGSL::TexelFormat::RG8snorm;
    case WebGPU::TextureFormat::Rg8uint:
        return WGSL::TexelFormat::RG8uint;
    case WebGPU::TextureFormat::Rg8unorm:
        return WGSL::TexelFormat::RG8unorm;
    case WebGPU::TextureFormat::Rgb10a2uint:
        return WGSL::TexelFormat::RGB10A2uint;
    case WebGPU::TextureFormat::Rgb10a2unorm:
        return WGSL::TexelFormat::RGB10A2unorm;
    case WebGPU::TextureFormat::Rgba16float:
        return WGSL::TexelFormat::RGBA16float;
    case WebGPU::TextureFormat::Rgba16sint:
        return WGSL::TexelFormat::RGBA16sint;
    case WebGPU::TextureFormat::Rgba16snorm:
        return WGSL::TexelFormat::RGBA16snorm;
    case WebGPU::TextureFormat::Rgba16uint:
        return WGSL::TexelFormat::RGBA16uint;
    case WebGPU::TextureFormat::Rgba16unorm:
        return WGSL::TexelFormat::RGBA16unorm;
    case WebGPU::TextureFormat::Rgba32float:
        return WGSL::TexelFormat::RGBA32float;
    case WebGPU::TextureFormat::Rgba32sint:
        return WGSL::TexelFormat::RGBA32sint;
    case WebGPU::TextureFormat::Rgba32uint:
        return WGSL::TexelFormat::RGBA32uint;
    case WebGPU::TextureFormat::Rgba8sint:
        return WGSL::TexelFormat::RGBA8sint;
    case WebGPU::TextureFormat::Rgba8snorm:
        return WGSL::TexelFormat::RGBA8snorm;
    case WebGPU::TextureFormat::Rgba8uint:
        return WGSL::TexelFormat::RGBA8uint;
    case WebGPU::TextureFormat::Rgba8unorm:
        return WGSL::TexelFormat::RGBA8unorm;
    default:
        ASSERT_NOT_REACHED();
        return WGSL::TexelFormat::BGRA8unorm;
    }
}

static WGSL::BindGroupLayoutEntry::BindingMember convertBindingLayout(const BindGroupLayout::Entry::BindingLayout& bindingLayout)
{
    return WTF::switchOn(bindingLayout, [](const BindGroupLayout::BufferBindingLayout& bindingLayout) -> WGSL::BindGroupLayoutEntry::BindingMember {
        return WGSL::BufferBindingLayout {
            .type = wgslBindingType(bindingLayout.type),
            .hasDynamicOffset = !!bindingLayout.hasDynamicOffset,
            .minBindingSize = bindingLayout.minBindingSize
        };
    }, [](const BindGroupLayout::SamplerBindingLayout& bindingLayout) -> WGSL::BindGroupLayoutEntry::BindingMember {
        return WGSL::SamplerBindingLayout {
            .type = wgslSamplerType(bindingLayout.type)
        };
    }, [](const BindGroupLayout::TextureBindingLayout& bindingLayout) -> WGSL::BindGroupLayoutEntry::BindingMember {
        return WGSL::TextureBindingLayout {
            .sampleType = wgslSampleType(bindingLayout.sampleType),
            .viewDimension = wgslViewDimension(bindingLayout.viewDimension),
            .multisampled = !!bindingLayout.multisampled
        };
    }, [](const BindGroupLayout::StorageTextureBindingLayout& bindingLayout) -> WGSL::BindGroupLayoutEntry::BindingMember {
        return WGSL::StorageTextureBindingLayout {
            .access = wgslAccess(bindingLayout.access),
            .format = wgslFormat(bindingLayout.format),
            .viewDimension = wgslViewDimension(bindingLayout.viewDimension)
        };
    }, [](const BindGroupLayout::ExternalTextureBindingLayout&) -> WGSL::BindGroupLayoutEntry::BindingMember {
        return WGSL::ExternalTextureBindingLayout {
        };
    });
}

WGSL::PipelineLayout ShaderModule::convertPipelineLayout(const PipelineLayout& pipelineLayout)
{
    Vector<WGSL::BindGroupLayout> bindGroupLayouts;

    uint32_t maxVertexOffset = 0, maxFragmentOffset = 0, maxComputeOffset = 0;
    for (size_t i = 0; i < pipelineLayout.numberOfBindGroupLayouts(); ++i) {
        Ref bindGroupLayout = pipelineLayout.bindGroupLayout(i);
        WGSL::BindGroupLayout wgslBindGroupLayout;
        auto vertexOffset = maxVertexOffset, fragmentOffset = maxFragmentOffset, computeOffset = maxComputeOffset;
        for (auto& entry : bindGroupLayout->entries()) {
            WGSL::BindGroupLayoutEntry wgslEntry;
            wgslEntry.binding = entry.value.binding;
            wgslEntry.visibility = wgslEntry.visibility.fromRaw(entry.value.visibility.toRaw());
            wgslEntry.bindingMember = convertBindingLayout(entry.value.bindingLayout);
            wgslEntry.vertexArgumentBufferIndex = entry.value.argumentBufferIndices[WebGPU::Metal::ShaderStage::Vertex];
            wgslEntry.vertexArgumentBufferSizeIndex = entry.value.bufferSizeArgumentBufferIndices[WebGPU::Metal::ShaderStage::Vertex];
            if (entry.value.vertexDynamicOffset) {
                RELEASE_ASSERT(!(entry.value.vertexDynamicOffset.value() % sizeof(uint32_t)));
                wgslEntry.vertexBufferDynamicOffset = (vertexOffset + *entry.value.vertexDynamicOffset) / sizeof(uint32_t);
                maxVertexOffset = std::max<size_t>(maxVertexOffset, *entry.value.vertexDynamicOffset + sizeof(uint32_t) + vertexOffset);
            }
            wgslEntry.fragmentArgumentBufferIndex = entry.value.argumentBufferIndices[WebGPU::Metal::ShaderStage::Fragment];
            wgslEntry.fragmentArgumentBufferSizeIndex = entry.value.bufferSizeArgumentBufferIndices[WebGPU::Metal::ShaderStage::Fragment];
            if (entry.value.fragmentDynamicOffset) {
                RELEASE_ASSERT(!(entry.value.fragmentDynamicOffset.value() % sizeof(uint32_t)));
                wgslEntry.fragmentBufferDynamicOffset = (fragmentOffset + *entry.value.fragmentDynamicOffset) / sizeof(uint32_t) + RenderBundleEncoder::startIndexForFragmentDynamicOffsets;
                maxFragmentOffset = std::max<size_t>(maxFragmentOffset, *entry.value.fragmentDynamicOffset + sizeof(uint32_t) + fragmentOffset);
            }
            wgslEntry.computeArgumentBufferIndex = entry.value.argumentBufferIndices[WebGPU::Metal::ShaderStage::Compute];
            wgslEntry.computeArgumentBufferSizeIndex = entry.value.bufferSizeArgumentBufferIndices[WebGPU::Metal::ShaderStage::Compute];
            if (entry.value.computeDynamicOffset) {
                RELEASE_ASSERT(!(entry.value.computeDynamicOffset.value() % sizeof(uint32_t)));
                wgslEntry.computeBufferDynamicOffset = (computeOffset + *entry.value.computeDynamicOffset) / sizeof(uint32_t);
                maxComputeOffset = std::max<size_t>(maxComputeOffset, *entry.value.computeDynamicOffset + sizeof(uint32_t) + computeOffset);
            }
            wgslBindGroupLayout.entries.append(wgslEntry);
        }

        bindGroupLayouts.append(wgslBindGroupLayout);
    }

    return { .bindGroupLayouts = bindGroupLayouts };
}

WGSL::CompilationResult ShaderModule::compile(const String& entryPoint, WGSL::PipelineLayout* pipelineLayout, std::span<const WebGPU::ConstantEntry> constants, const WGSL::DeviceState& deviceState) const
{
    RELEASE_ASSERT(m_wgslModule);
#if HAVE(WGSL_COMPILER)
    WGSL::Interop::PipelineConstants pipelineConstants;
    pipelineConstants.reserveInitialCapacity(constants.size());
    for (auto& constant : constants)
        pipelineConstants.append({ constant.key, constant.value });
    WGSL::PipelineLayout unusedLayout;
    WGSL::CompilationResult result;
    runOnWGSLCompileThread([&] {
        result = m_wgslModule->module.compile(entryPoint, pipelineLayout ? *pipelineLayout : unusedLayout, !!pipelineLayout, pipelineConstants, deviceState);
    });
    if (result.failure == WGSL::CompilationFailure::None)
        dumpMetalCodeIfNeeded(result.msl);
    return result;
#else
    UNUSED_PARAM(entryPoint);
    UNUSED_PARAM(pipelineLayout);
    UNUSED_PARAM(constants);
    UNUSED_PARAM(deviceState);
    RELEASE_ASSERT_NOT_REACHED();
#endif
}

std::optional<WGSL::WorkgroupSize> ShaderModule::evaluateWorkgroupSize(const String& entryPoint, const WGSL::ResolvedOverrides& overrides) const
{
    RELEASE_ASSERT(m_wgslModule);
#if HAVE(WGSL_COMPILER)
    std::optional<WGSL::WorkgroupSize> result;
    runOnWGSLCompileThread([&] {
        result = m_wgslModule->module.evaluateWorkgroupSize(entryPoint, overrides);
    });
    return result;
#else
    UNUSED_PARAM(entryPoint);
    UNUSED_PARAM(overrides);
    RELEASE_ASSERT_NOT_REACHED();
#endif
}

// The Swift function is integer arithmetic only; the analyzer cannot see through the generated thunk.
SUPPRESS_NODELETE uint32_t ShaderModule::vertexBufferIndexForBindGroup(uint32_t groupIndex, uint32_t maxIndex)
{
#if HAVE(WGSL_COMPILER)
    return WebGPU::wgslVertexBufferIndexForBindGroup(groupIndex, maxIndex);
#else
    // Without a WGSL compiler no shader module is valid, so no generated code depends on this.
    return groupIndex > maxIndex ? groupIndex : (maxIndex - groupIndex);
#endif
}

const PipelineLayout* ShaderModule::pipelineLayoutHint(const String& name) const
{
    auto iterator = m_pipelineLayoutHints.find(name);
    if (iterator == m_pipelineLayoutHints.end())
        return nullptr;
    return iterator->value.ptr();
}

const WGSL::CompiledEntryPoint* ShaderModule::entryPointInformation(const String& name) const
{
    auto iterator = m_entryPointInformation.find(name);
    if (iterator != m_entryPointInformation.end())
        return &iterator->value;

    return nullptr;
}

const String& ShaderModule::defaultVertexEntryPoint() const
{
    return m_defaultVertexEntryPoint;
}

const String& ShaderModule::defaultFragmentEntryPoint() const
{
    return m_defaultFragmentEntryPoint;
}

const String& ShaderModule::defaultComputeEntryPoint() const
{
    return m_defaultComputeEntryPoint;
}

} // namespace WebGPU::Metal

#pragma mark WGPU Stubs

void LEGACY_NODELETE wgpuShaderModuleAddRef(WGPUShaderModule shaderModule)
{
    WebGPU::Metal::fromAPI(shaderModule).ref();
}

void wgpuShaderModuleRelease(WGPUShaderModule shaderModule)
{
    WebGPU::Metal::fromAPI(shaderModule).deref();
}

static void getCompilationInfo(WGPUShaderModule shaderModule, CompletionHandler<void(WGPUCompilationInfoRequestStatus, const WGPUCompilationInfo&)>&& callback)
{
    Ref protectedShaderModule = WebGPU::Metal::fromAPI(shaderModule);
    // The request succeeds for shader modules that compiled.
    auto status = protectedShaderModule->isValid() ? WGPUCompilationInfoRequestStatus_Success : WGPUCompilationInfoRequestStatus_Error;
    protectedShaderModule->compilationInfo([status, callback = WTF::move(callback)](WebGPU::CompilationInfo&& compilationInfo) mutable {
        auto messages = WebGPU::Metal::toAPI(compilationInfo);
        callback(status, WGPUCompilationInfo {
            .messageCount = messages.size(),
            .messages = messages.span().data(),
        });
    });
}

void wgpuShaderModuleGetCompilationInfo(WGPUShaderModule shaderModule, WGPUCompilationInfoCallback callback, void * userdata)
{
    getCompilationInfo(shaderModule, [callback, userdata](WGPUCompilationInfoRequestStatus status, const WGPUCompilationInfo& compilationInfo) {
        callback(status, &compilationInfo, userdata);
    });
}

void wgpuShaderModuleGetCompilationInfoWithBlock(WGPUShaderModule shaderModule, WGPUCompilationInfoBlockCallback callback)
{
    getCompilationInfo(shaderModule, [callback = WebGPU::Metal::fromAPI(WTF::move(callback))](WGPUCompilationInfoRequestStatus status, const WGPUCompilationInfo& compilationInfo) {
        callback(status, &compilationInfo);
    });
}

void wgpuShaderModuleSetLabel(WGPUShaderModule shaderModule, WGPUStringView label)
{
    protect(WebGPU::Metal::fromAPI(shaderModule))->setLabel(WebGPU::Metal::fromAPI(label));
}

String wgpuAdapterFeatureName(WGPUFeatureName feature)
{
    auto apiFeature = WebGPU::Metal::fromAPI(feature);
    return apiFeature ? WebGPU::Metal::featureName(*apiFeature) : emptyString();
}
