// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// The only place the Swift WGSL compiler meets C++. In this file `WGSL.X` is the C++ namespace from
// WGSLAPI.h (an imported declaration shadows the module name); the Swift module's declarations are
// used unqualified.

private import CxxStdlib
internal import WGSL
import WebGPU_Internal.WGSLAPI

// MARK: - Entry points called from ShaderModule.mm

@_expose(Cxx)
func wgslStaticCheck(
    _ source: borrowing WTF.String,
    _ configuration: WGSL.Configuration,
    _ checkResult: inout WGSL.StaticCheckResult
) -> WGSLShaderModule? {
    let swiftConfiguration = Configuration(
        maxBuffersPlusVertexBuffersForVertexStage: configuration.maxBuffersPlusVertexBuffersForVertexStage,
        maxBuffersForFragmentStage: configuration.maxBuffersForFragmentStage,
        maxBuffersForComputeStage: configuration.maxBuffersForComputeStage,
        maximumCombinedWorkgroupVariablesSize: configuration.maximumCombinedWorkgroupVariablesSize,
        supportedFeatures: Features(rawValue: WGSL.Interop.rawFeatures(configuration)),
        identifierCharacterClasses: icuIdentifierCharacterClasses
    )

    switch staticCheck(makeSourceText(source), configuration: swiftConfiguration) {
    case .failure(let failedCheck):
        for error in failedCheck.errors {
            checkResult.errors.append(consuming: makeCompilationMessage(error))
        }
        for warning in failedCheck.warnings {
            checkResult.warnings.append(consuming: makeCompilationMessage(warning))
        }
        return nil
    case .success(let module):
        for warning in module.warnings {
            checkResult.warnings.append(consuming: makeCompilationMessage(warning))
        }
        for entryPoint in module.entryPoints {
            checkResult.entryPoints.append(consuming: makeEntryPointIO(entryPoint))
        }
        return WGSLShaderModule(module)
    }
}

@_expose(Cxx)
func wgslVertexBufferIndexForBindGroup(_ groupIndex: UInt32, _ maxIndex: UInt32) -> UInt32 {
    vertexBufferIndexForBindGroup(groupIndex, maxIndex: maxIndex)
}

// The stack size of the thread ShaderModule.mm runs wgslStaticCheck, compile and evaluateWorkgroupSize on;
// 0 means the calling thread.
@_expose(Cxx)
func wgslRecommendedCompileStackSize() -> UInt64 {
    UInt64(CompileThread.recommendedStackSize ?? 0)
}

// One per valid GPUShaderModule; owned by WebGPU::Metal::ShaderModule. Used only on the WebGPU
// thread; it may be released on any thread.
@_expose(Cxx)
final class WGSLShaderModule {
    private var module: CheckedModule

    fileprivate init(_ module: consuming CheckedModule) {
        self.module = module
    }

    // Pipeline.mm prepareLibrary. `layout` is used iff `hasExplicitLayout`; the compiler writes the
    // shader-derived minBindingSize of every buffer entry into it before returning.
    @_expose(Cxx)
    func compile(
        _ entryPoint: borrowing WTF.String,
        _ layout: inout WGSL.PipelineLayout,
        _ hasExplicitLayout: Bool,
        _ constants: borrowing WGSL.Interop.PipelineConstants,
        _ deviceState: WGSL.DeviceState
    ) -> WGSL.CompilationResult {
        let name = makeName(entryPoint)
        let pipelineConstants = makePipelineConstants(constants)
        let swiftDeviceState = DeviceState(
            appleGPUFamily: deviceState.appleGPUFamily,
            shaderValidationEnabled: deviceState.shaderValidationEnabled
        )

        let compilation =
            hasExplicitLayout
            ? module.compileEntryPoint(
                name,
                layout: &layout,
                access: CxxPipelineLayoutAccess.self,
                constants: pipelineConstants,
                deviceState: swiftDeviceState
            )
            : module.compileEntryPoint(name, constants: pipelineConstants, deviceState: swiftDeviceState)

        var result = WGSL.CompilationResult()
        switch compilation {
        case .prepareFailed(let error):
            result.failure = .PrepareFailed
            result.errorMessage = WGSL.Interop.makeStringFromUTF16(error.utf16.span)
        case .entryPointNotFound:
            result.failure = .EntryPointNotFound
        case .invalidPipelineConstant:
            result.failure = .InvalidPipelineConstant
        case .generateFailed(let error):
            result.failure = .GenerateFailed
            result.errorMessage = WGSL.Interop.makeStringFromUTF16(error.utf16.span)
        case .compiled(let information, let library):
            result.failure = .None
            result.entryPoint = makeCompiledEntryPoint(information)
            result.msl = makeWTFString(utf8: library.msl.utf8)
            for resolved in library.resolvedOverrides.entries {
                result.resolvedOverrides.append(consuming: makeResolvedOverride(resolved))
            }
        }
        return result
    }

    // ComputePipeline.mm metalSize, on the rolled-back module, with the overrides compile() resolved.
    @_expose(Cxx)
    func evaluateWorkgroupSize(
        _ entryPoint: borrowing WTF.String,
        _ overrides: borrowing WGSL.ResolvedOverrides
    ) -> WGSL.Interop.OptionalWorkgroupSize {
        var resolved: [ResolvedOverride] = []
        let entries: Span<WGSL.ResolvedOverride> = overrides.span()
        for index in entries.indices {
            resolved.append(makeSwiftResolvedOverride(entries[index]))
        }
        guard let size = module.evaluateWorkgroupSize(entryPoint: makeName(entryPoint), overrides: ResolvedOverrides(resolved)).size else {
            return WGSL.Interop.OptionalWorkgroupSize()
        }
        var cxxSize = WGSL.WorkgroupSize()
        cxxSize.width = size.width
        cxxSize.height = size.height
        cxxSize.depth = size.depth
        return WGSL.Interop.OptionalWorkgroupSize(cxxSize)
    }
}

// MARK: - The explicit layout, read and written in place

private enum CxxPipelineLayoutAccess: PipelineLayoutAccess {
    static func bindGroupLayoutCount(of layout: borrowing WGSL.PipelineLayout) -> Int {
        WGSL.Interop.bindGroupLayoutCount(layout)
    }

    static func entryCount(of layout: borrowing WGSL.PipelineLayout, bindGroupLayout group: Int) -> Int {
        WGSL.Interop.entryCount(layout, group)
    }

    static func entry(of layout: borrowing WGSL.PipelineLayout, bindGroupLayout group: Int, index: Int) -> ExplicitBindGroupLayoutEntry {
        ExplicitBindGroupLayoutEntry(
            binding: WGSL.Interop.entryBinding(layout, group, index),
            visibility: ShaderStages(rawValue: WGSL.Interop.entryVisibility(layout, group, index)),
            bindingMember: makeBindingMember(layout, group, index),
            vertex: makeStageSlots(WGSL.Interop.entryStageSlots(layout, group, index, .Vertex)),
            fragment: makeStageSlots(WGSL.Interop.entryStageSlots(layout, group, index, .Fragment)),
            compute: makeStageSlots(WGSL.Interop.entryStageSlots(layout, group, index, .Compute))
        )
    }

    static func setMinBindingSize(_ size: UInt64, in layout: inout WGSL.PipelineLayout, bindGroupLayout group: Int, index: Int) {
        WGSL.Interop.setMinBindingSize(&layout, group, index, size)
    }
}

private func makeStageSlots(_ slots: borrowing WGSL.Interop.StageSlots) -> StageSlots {
    StageSlots(
        argumentBufferIndex: Optional(fromCxx: slots.argumentBufferIndex),
        argumentBufferSizeIndex: Optional(fromCxx: slots.argumentBufferSizeIndex),
        bufferDynamicOffset: Optional(fromCxx: slots.bufferDynamicOffset)
    )
}

private func makeBindingMember(_ layout: borrowing WGSL.PipelineLayout, _ group: Int, _ index: Int) -> BindingMember {
    switch WGSL.Interop.entryBindingMemberKind(layout, group, index) {
    case .Buffer:
        let buffer = WGSL.Interop.entryBufferBinding(layout, group, index)
        let type: BufferBindingType =
            switch buffer.type {
            case .Uniform: .uniform
            case .Storage: .storage
            case .ReadOnlyStorage: .readOnlyStorage
            @unknown default: preconditionFailure("unknown WGSL::BufferBindingType")
            }
        return .buffer(BufferBindingLayout(type: type, hasDynamicOffset: buffer.hasDynamicOffset, minBindingSize: buffer.minBindingSize))
    case .Sampler:
        let type: SamplerBindingType =
            switch WGSL.Interop.entrySamplerBinding(layout, group, index).type {
            case .Filtering: .filtering
            case .NonFiltering: .nonFiltering
            case .Comparison: .comparison
            @unknown default: preconditionFailure("unknown WGSL::SamplerBindingType")
            }
        return .sampler(type)
    case .Texture:
        let texture = WGSL.Interop.entryTextureBinding(layout, group, index)
        return .texture(
            TextureBindingLayout(
                sampleType: makeSampleType(texture.sampleType),
                viewDimension: makeViewDimension(texture.viewDimension),
                multisampled: texture.multisampled
            )
        )
    case .StorageTexture:
        let storageTexture = WGSL.Interop.entryStorageTextureBinding(layout, group, index)
        guard let format = TexelFormat(rawValue: storageTexture.format.rawValue) else {
            preconditionFailure("unknown WGSL::TexelFormat")
        }
        let access: StorageTextureAccess =
            switch storageTexture.access {
            case .WriteOnly: .writeOnly
            case .ReadOnly: .readOnly
            case .ReadWrite: .readWrite
            @unknown default: preconditionFailure("unknown WGSL::StorageTextureAccess")
            }
        return .storageTexture(
            StorageTextureBindingLayout(access: access, format: format, viewDimension: makeViewDimension(storageTexture.viewDimension))
        )
    case .ExternalTexture:
        return .externalTexture
    @unknown default:
        preconditionFailure("unknown WGSL::Interop::BindingMemberKind")
    }
}

private func makeSampleType(_ sampleType: WGSL.TextureSampleType) -> TextureSampleType {
    switch sampleType {
    case .Float: .float
    case .UnfilterableFloat: .unfilterableFloat
    case .Depth: .depth
    case .SignedInt: .signedInt
    case .UnsignedInt: .unsignedInt
    @unknown default: preconditionFailure("unknown WGSL::TextureSampleType")
    }
}

private func makeViewDimension(_ viewDimension: WGSL.TextureViewDimension) -> TextureViewDimension {
    switch viewDimension {
    case .OneDimensional: .oneDimensional
    case .TwoDimensional: .twoDimensional
    case .TwoDimensionalArray: .twoDimensionalArray
    case .Cube: .cube
    case .CubeArray: .cubeArray
    case .ThreeDimensional: .threeDimensional
    @unknown default: preconditionFailure("unknown WGSL::TextureViewDimension")
    }
}

// MARK: - Swift values to C++ plain data

private func makeCompilationMessage(_ message: CompilationMessage) -> WGSL.CompilationMessage {
    WGSL.CompilationMessage(
        WGSL.Interop.makeStringFromUTF16(message.utf16.span),
        message.span.line,
        message.span.lineOffset,
        message.span.offset,
        message.span.length
    )
}

private func makeStage(_ stage: ShaderStage) -> WGSL.ShaderStage {
    switch stage {
    case .vertex: .Vertex
    case .fragment: .Fragment
    case .compute: .Compute
    }
}

private func makeIOLocation(_ location: IOLocation) -> WGSL.IOLocation {
    var result = WGSL.IOLocation()
    result.location = location.location
    switch location.type {
    case .missing:
        result.type.shape = .Missing
    case .other:
        result.type.shape = .Other
    case .scalar(let scalar):
        result.type.shape = .Scalar
        result.type.scalar = makeIOScalar(scalar)
    case .vector(let scalar, let size):
        result.type.shape = .Vector
        result.type.scalar = makeIOScalar(scalar)
        result.type.vectorSize = size
    }
    if let interpolation = location.interpolation {
        var cxxInterpolation = WGSL.Interpolation()
        cxxInterpolation.type =
            switch interpolation.type {
            case .flat: .Flat
            case .linear: .Linear
            case .perspective: .Perspective
            }
        cxxInterpolation.sampling =
            switch interpolation.sampling {
            case .center: .Center
            case .centroid: .Centroid
            case .either: .Either
            case .first: .First
            case .sample: .Sample
            }
        result.interpolation = .init(cxxInterpolation)
    }
    return result
}

private func makeIOScalar(_ scalar: IOScalar) -> WGSL.IOType.Scalar {
    switch scalar {
    case .i32: .I32
    case .u32: .U32
    case .f16: .F16
    case .f32: .F32
    case .bool: .Bool
    case .other: .Other
    }
}

private func makeIOLocations(_ locations: [IOLocation]) -> WGSL.Interop.IOLocations {
    var result = WGSL.Interop.IOLocations()
    for location in locations {
        result.append(consuming: makeIOLocation(location))
    }
    return result
}

private func makeEntryPointIO(_ entryPoint: EntryPointIO) -> WGSL.EntryPointIO {
    var result = WGSL.EntryPointIO()
    result.name = makeWTFString(entryPoint.name)
    result.stage = makeStage(entryPoint.stage)
    result.stageIn = makeIOLocations(entryPoint.stageIn)
    if let vertexOutputs = entryPoint.vertexOutputs {
        result.vertexOutputs = .init(makeIOLocations(vertexOutputs))
    }
    result.fragmentInputs = makeIOLocations(entryPoint.fragmentInputs)
    if let fragmentOutputs = entryPoint.fragmentOutputs {
        result.fragmentOutputs = .init(makeIOLocations(fragmentOutputs))
    }
    result.usesFrontFacingInInput = entryPoint.usesFrontFacingInInput
    result.usesSampleIndexInInput = entryPoint.usesSampleIndexInInput
    result.usesSampleMaskInInput = entryPoint.usesSampleMaskInInput
    result.usesSampleMaskInOutput = entryPoint.usesSampleMaskInOutput
    result.usesFragDepth = entryPoint.usesFragDepth
    result.usesPrimitiveIndexInInput = entryPoint.usesPrimitiveIndexInInput
    result.usesSubgroupInvocationIdInInput = entryPoint.usesSubgroupInvocationIdInInput
    result.usesSubgroupSizeInInput = entryPoint.usesSubgroupSizeInInput
    result.clipDistancesCount = entryPoint.clipDistancesCount
    return result
}

private func makeCompiledEntryPoint(_ information: EntryPointInformation) -> WGSL.CompiledEntryPoint {
    var result = WGSL.CompiledEntryPoint()
    result.originalName = makeWTFString(information.originalName)
    result.mangledName = makeWTFString(information.mangledName)
    result.stage = makeStage(information.stage)
    result.hasWorkgroupSize = information.typedEntryPoint == .compute
    if let defaultLayout = information.defaultLayout {
        result.defaultLayout = .init(makePipelineLayout(defaultLayout))
    }
    for constant in information.specializationConstants {
        var cxxConstant = WGSL.SpecializationConstant()
        cxxConstant.key = makeWTFString(constant.key)
        cxxConstant.type =
            switch constant.type {
            case .boolean: .Boolean
            case .float: .Float
            case .int: .Int
            case .unsigned: .Unsigned
            case .half: .Half
            }
        result.specializationConstants.append(consuming: cxxConstant)
    }
    result.sizeForWorkgroupVariables = information.sizeForWorkgroupVariables
    result.bindingCount = information.bindingCount
    result.usesInvariant = information.usesInvariant
    return result
}

private func makePipelineLayout(_ layout: PipelineLayout) -> WGSL.PipelineLayout {
    var result = WGSL.PipelineLayout()
    for bindGroupLayout in layout.bindGroupLayouts {
        var cxxBindGroupLayout = WGSL.BindGroupLayout()
        cxxBindGroupLayout.group = bindGroupLayout.group
        for entry in bindGroupLayout.entries {
            cxxBindGroupLayout.entries.append(consuming: makeBindGroupLayoutEntry(entry))
        }
        result.bindGroupLayouts.append(consuming: cxxBindGroupLayout)
    }
    return result
}

private func makeBindGroupLayoutEntry(_ entry: BindGroupLayoutEntry) -> WGSL.BindGroupLayoutEntry {
    var result = WGSL.BindGroupLayoutEntry()
    result.binding = entry.binding
    result.webBinding = entry.webBinding
    WGSL.Interop.setVisibility(&result, entry.visibility.rawValue)
    switch entry.bindingMember {
    case .buffer(let buffer):
        var cxxBuffer = WGSL.BufferBindingLayout()
        cxxBuffer.type =
            switch buffer.type {
            case .uniform: .Uniform
            case .storage: .Storage
            case .readOnlyStorage: .ReadOnlyStorage
            }
        cxxBuffer.hasDynamicOffset = buffer.hasDynamicOffset
        cxxBuffer.minBindingSize = buffer.minBindingSize
        WGSL.Interop.setBindingMember(&result, cxxBuffer)
    case .sampler(let type):
        var cxxSampler = WGSL.SamplerBindingLayout()
        cxxSampler.type =
            switch type {
            case .filtering: .Filtering
            case .nonFiltering: .NonFiltering
            case .comparison: .Comparison
            }
        WGSL.Interop.setBindingMember(&result, cxxSampler)
    case .texture(let texture):
        var cxxTexture = WGSL.TextureBindingLayout()
        cxxTexture.sampleType = makeCxxSampleType(texture.sampleType)
        cxxTexture.viewDimension = makeCxxViewDimension(texture.viewDimension)
        cxxTexture.multisampled = texture.multisampled
        WGSL.Interop.setBindingMember(&result, cxxTexture)
    case .storageTexture(let storageTexture):
        var cxxStorageTexture = WGSL.StorageTextureBindingLayout()
        cxxStorageTexture.access =
            switch storageTexture.access {
            case .writeOnly: .WriteOnly
            case .readOnly: .ReadOnly
            case .readWrite: .ReadWrite
            }
        guard let format = WGSL.TexelFormat(rawValue: storageTexture.format.rawValue) else {
            preconditionFailure("TexelFormat out of sync with WGSL::TexelFormat")
        }
        cxxStorageTexture.format = format
        cxxStorageTexture.viewDimension = makeCxxViewDimension(storageTexture.viewDimension)
        WGSL.Interop.setBindingMember(&result, cxxStorageTexture)
    case .externalTexture:
        WGSL.Interop.setBindingMember(&result, WGSL.ExternalTextureBindingLayout())
    }
    result.name = makeWTFString(entry.name)
    WGSL.Interop.setStageSlots(&result, .Vertex, makeCxxStageSlots(entry.vertex))
    WGSL.Interop.setStageSlots(&result, .Fragment, makeCxxStageSlots(entry.fragment))
    WGSL.Interop.setStageSlots(&result, .Compute, makeCxxStageSlots(entry.compute))
    return result
}

private func makeCxxStageSlots(_ slots: StageSlots) -> WGSL.Interop.StageSlots {
    var result = WGSL.Interop.StageSlots()
    if let index = slots.argumentBufferIndex {
        result.argumentBufferIndex = .init(index)
    }
    if let index = slots.argumentBufferSizeIndex {
        result.argumentBufferSizeIndex = .init(index)
    }
    if let offset = slots.bufferDynamicOffset {
        result.bufferDynamicOffset = .init(offset)
    }
    return result
}

private func makeCxxSampleType(_ sampleType: TextureSampleType) -> WGSL.TextureSampleType {
    switch sampleType {
    case .float: .Float
    case .unfilterableFloat: .UnfilterableFloat
    case .depth: .Depth
    case .signedInt: .SignedInt
    case .unsignedInt: .UnsignedInt
    }
}

private func makeCxxViewDimension(_ viewDimension: TextureViewDimension) -> WGSL.TextureViewDimension {
    switch viewDimension {
    case .oneDimensional: .OneDimensional
    case .twoDimensional: .TwoDimensional
    case .twoDimensionalArray: .TwoDimensionalArray
    case .cube: .Cube
    case .cubeArray: .CubeArray
    case .threeDimensional: .ThreeDimensional
    }
}

private func makeResolvedOverride(_ resolved: ResolvedOverride) -> WGSL.ResolvedOverride {
    var result = WGSL.ResolvedOverride()
    result.name = makeWTFString(resolved.name)
    switch resolved.value {
    case .bool(let value):
        result.kind = .Bool
        result.bits = value ? 1 : 0
    case .f32(let value):
        result.kind = .F32
        result.bits = UInt64(value.bitPattern)
    case .f16(let bits):
        result.kind = .F16
        result.bits = UInt64(bits)
    case .i32(let value):
        result.kind = .I32
        result.bits = UInt64(UInt32(bitPattern: value))
    case .u32(let value):
        result.kind = .U32
        result.bits = UInt64(value)
    case .abstractInt(let value):
        result.kind = .AbstractInt
        result.bits = UInt64(bitPattern: value)
    case .abstractFloat(let value):
        result.kind = .AbstractFloat
        result.bits = value.bitPattern
    }
    return result
}

private func makeSwiftResolvedOverride(_ resolved: borrowing WGSL.ResolvedOverride) -> ResolvedOverride {
    let value: ScalarValue =
        switch resolved.kind {
        case .Bool: .bool(resolved.bits != 0)
        case .F32: .f32(Float(bitPattern: UInt32(truncatingIfNeeded: resolved.bits)))
        case .F16: .f16(bits: UInt16(truncatingIfNeeded: resolved.bits))
        case .I32: .i32(Int32(bitPattern: UInt32(truncatingIfNeeded: resolved.bits)))
        case .U32: .u32(UInt32(truncatingIfNeeded: resolved.bits))
        case .AbstractInt: .abstractInt(Int64(bitPattern: resolved.bits))
        case .AbstractFloat: .abstractFloat(Double(bitPattern: resolved.bits))
        @unknown default: preconditionFailure("unknown WGSL::ResolvedOverride::Kind")
        }
    return ResolvedOverride(name: makeName(resolved.name), value: value)
}

private func makePipelineConstants(_ constants: borrowing WGSL.Interop.PipelineConstants) -> [PipelineConstant] {
    var result: [PipelineConstant] = []
    let entries: Span<WGSL.PipelineConstant> = constants.span()
    for index in entries.indices {
        result.append(PipelineConstant(key: makeName(entries[index].key), value: entries[index].value))
    }
    return result
}

// MARK: - Identifier classification

// The running OS's ICU XID tables, so that identifiers lex as ICU's u_stringHasBinaryProperty classifies them.
// Built once per process.
private let icuIdentifierCharacterClasses = IdentifierCharacterClasses(
    xidStartRanges: makeIdentifierRanges(xidContinue: false),
    xidContinueRanges: makeIdentifierRanges(xidContinue: true)
)

private func makeIdentifierRanges(xidContinue: Bool) -> [UInt32] {
    let ranges = WGSL.Interop.icuIdentifierRanges(xidContinue)
    var copy = ContiguousArray<UInt32>(repeating: 0, count: Int(ranges.size()))
    var destination = copy.mutableSpan
    WGSL.Interop.copyIdentifierRanges(ranges, &destination)
    return Array(copy)
}

// MARK: - Strings

// One memcpy from the WTF::String into Swift-owned storage, which the compiler then takes over.
private func makeSourceText(_ string: borrowing WTF.String) -> SourceText {
    let length = Int(string.length())
    if string.is8Bit() {
        var codeUnits = ContiguousArray<UInt8>(repeating: 0, count: length)
        var destination = codeUnits.mutableSpan
        WGSL.Interop.copyLatin1CodeUnits(string, &destination)
        return SourceText(latin1: codeUnits)
    }
    var codeUnits = ContiguousArray<UInt16>(repeating: 0, count: length)
    var destination = codeUnits.mutableSpan
    WGSL.Interop.copyUTF16CodeUnits(string, &destination)
    return SourceText(utf16: codeUnits)
}

private func makeName(_ string: borrowing WTF.String) -> Name {
    let length = Int(string.length())
    if string.is8Bit() {
        var codeUnits = ContiguousArray<UInt8>(repeating: 0, count: length)
        var destination = codeUnits.mutableSpan
        WGSL.Interop.copyLatin1CodeUnits(string, &destination)
        return Name(latin1: codeUnits)
    }
    var codeUnits = ContiguousArray<UInt16>(repeating: 0, count: length)
    var destination = codeUnits.mutableSpan
    WGSL.Interop.copyUTF16CodeUnits(string, &destination)
    return Name(utf16: codeUnits)
}

private func makeWTFString(_ name: Name) -> WTF.String {
    WGSL.Interop.makeStringFromUTF16(name.utf16.span)
}

private func makeWTFString(_ string: Swift.String) -> WTF.String {
    makeWTFString(utf8: ContiguousArray(string.utf8))
}

// The MSL path: one copy, no Swift-side scan, no intermediate Swift.String.
private func makeWTFString(utf8 bytes: ContiguousArray<UInt8>) -> WTF.String {
    WGSL.Interop.makeStringFromUTF8(bytes.span)
}
