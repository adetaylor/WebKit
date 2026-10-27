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

import Metal
internal import WGSL
import WebGPU_Internal.Device
import WebGPU_Internal.ShaderModule
import WebGPU_Private.WebGPUCpp

private struct Message {
    let text: WTF.String
    let lineNumber: UInt32
    let lineOffset: UInt32
    let offset: UInt32
    let length: UInt32

    init(_ message: CompilationMessage) {
        text = wtfString(utf16: message.utf16)
        lineNumber = message.span.line
        lineOffset = message.span.lineOffset
        offset = message.span.offset
        length = message.span.length
    }
}

// CheckedModule is ~Copyable; the box lets the module be shared with the closures that run on the WGSL compile thread.
final class CheckedModuleBox {
    var module: CheckedModule

    init(_ module: consuming CheckedModule) {
        self.module = module
    }
}

// One per GPUShaderModule, owned by the C++ shell WebGPU::Metal::ShaderModule through an opaque box, and holding the
// Device. Pipeline creation reads the reflection and compiles through it directly.
@_expose(Cxx)
final class ShaderModuleImpl {
    // nil == invalid shader module.
    private let checkedModule: CheckedModuleBox?
    // Errors first, then warnings; getCompilationInfo reports them in that order.
    private let messages: [Message]
    private let errorCount: Int

    // In CheckedModule.entryPoints order. Empty for an invalid module.
    let entryPoints: [EntryPointReflection]
    // nil when the stage has no entry point, or more than one.
    let defaultVertexEntryPoint: Name?
    let defaultFragmentEntryPoint: Name?
    let defaultComputeEntryPoint: Name?
    // Declared last, so that the device outlives the rest of the module.
    let deviceImpl: DeviceImpl
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    init(
        checkedModule: CheckedModuleBox?,
        errors: [CompilationMessage],
        warnings: [CompilationMessage],
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl
    ) {
        self.deviceImpl = deviceImpl
        self.device = device
        self.checkedModule = checkedModule
        messages = (errors + warnings).map(Message.init)
        errorCount = errors.count

        var entryPoints: [EntryPointReflection] = []
        var vertexDefault = DefaultEntryPoint()
        var fragmentDefault = DefaultEntryPoint()
        var computeDefault = DefaultEntryPoint()
        for entryPoint in checkedModule?.module.entryPoints ?? [] {
            entryPoints.append(makeReflection(entryPoint))
            switch entryPoint.stage {
            case .vertex:
                vertexDefault.offer(entryPoint.name)
            case .fragment:
                fragmentDefault.offer(entryPoint.name)
            case .compute:
                computeDefault.offer(entryPoint.name)
            }
        }
        self.entryPoints = entryPoints
        defaultVertexEntryPoint = vertexDefault.name
        defaultFragmentEntryPoint = fragmentDefault.name
        defaultComputeEntryPoint = computeDefault.name
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        checkedModule != nil
    }

    @_expose(Cxx)
    func compilationMessageCount() -> Int {
        messages.count
    }

    @_expose(Cxx)
    func compilationErrorCount() -> Int {
        errorCount
    }

    @_expose(Cxx)
    func compilationMessageText(_ index: Int) -> WTF.String {
        messages[index].text
    }

    @_expose(Cxx)
    func compilationMessageLineNumber(_ index: Int) -> UInt32 {
        messages[index].lineNumber
    }

    @_expose(Cxx)
    func compilationMessageLineOffset(_ index: Int) -> UInt32 {
        messages[index].lineOffset
    }

    @_expose(Cxx)
    func compilationMessageOffset(_ index: Int) -> UInt32 {
        messages[index].offset
    }

    @_expose(Cxx)
    func compilationMessageLength(_ index: Int) -> UInt32 {
        messages[index].length
    }

    // A nil, unknown or empty name finds nothing. Each IO list is nil unless the entry point is of the stage that has it.
    func reflection(forEntryPoint name: Name?) -> EntryPointReflection? {
        guard let name else {
            return nil
        }
        return entryPoints.first { $0.name == name }
    }

    // Prepares, generates and rolls back one entry point on the WGSL compile thread. `explicitLayout` nil asks for the
    // default layout; otherwise the compiler writes minBindingSize back into it.
    func compile(
        entryPoint: Name,
        explicitLayout: inout PipelineLayout?,
        constants: [PipelineConstant],
        deviceState: DeviceState
    ) -> EntryPointCompilation {
        guard let checkedModule else {
            preconditionFailure("compile() on an invalid shader module")
        }
        var compilation: EntryPointCompilation?
        WebGPU.Metal.runOnWGSLCompileThread {
            if var layout = explicitLayout {
                compilation = checkedModule.module.compileEntryPoint(
                    entryPoint,
                    layout: &layout,
                    access: PipelineLayout.Access.self,
                    constants: constants,
                    deviceState: deviceState
                )
                explicitLayout = layout
            } else {
                compilation = checkedModule.module.compileEntryPoint(entryPoint, constants: constants, deviceState: deviceState)
            }
        }
        guard let compilation else {
            preconditionFailure("runOnWGSLCompileThread returned without running its work")
        }
        if case .compiled(_, let library) = compilation {
            dumpMetalCodeIfNeeded(library.msl.utf8)
        }
        return compilation
    }

    // On the WGSL compile thread, with the overrides compile() resolved.
    func evaluateWorkgroupSize(entryPoint: Name, overrides: ResolvedOverrides) -> WorkgroupExtent? {
        guard let checkedModule else {
            preconditionFailure("evaluateWorkgroupSize() on an invalid shader module")
        }
        var size: WorkgroupExtent?
        WebGPU.Metal.runOnWGSLCompileThread {
            size = checkedModule.module.evaluateWorkgroupSize(entryPoint: entryPoint, overrides: overrides).size
        }
        return size
    }
}

// The default entry point of a stage: its only entry point, else none.
private struct DefaultEntryPoint {
    // nil before the first entry point; an empty Name once there is more than one.
    private var candidate: Name?
    private var allowed = true

    var name: Name? {
        guard let candidate, !candidate.utf16.isEmpty else {
            return nil
        }
        return candidate
    }

    mutating func offer(_ entryPoint: Name) {
        if !allowed || !(candidate?.utf16.isEmpty ?? true) {
            allowed = false
            candidate = Name(utf16: [])
            return
        }
        candidate = entryPoint
    }
}

// MARK: - IO reflection

private func makeReflection(_ entryPoint: EntryPointIO) -> EntryPointReflection {
    var stageIn: [StageInLocation]?
    var vertexOutputs: [InterStageVariable]?
    var fragmentInputs: [InterStageVariable]?
    var fragmentOutputs: [FragmentOutput]?
    switch entryPoint.stage {
    case .vertex:
        let formats = entryPoint.stageIn.map { (location: $0.location, value: vertexFormat(for: $0.type)) }
        stageIn = inWTFHashTableOrder(formats).map { StageInLocation(location: $0.location, format: $0.value) }
        vertexOutputs = entryPoint.vertexOutputs.map(interStageVariables)
    case .fragment:
        fragmentInputs = interStageVariables(entryPoint.fragmentInputs)
        fragmentOutputs = entryPoint.fragmentOutputs.map { outputs in
            let types = outputs.map { (location: $0.location, value: metalDataType(for: $0.type)) }
            return inWTFHashTableOrder(types).map { FragmentOutput(location: $0.location, dataType: $0.value) }
        }
    case .compute:
        break
    }
    return EntryPointReflection(
        name: entryPoint.name,
        stage: entryPoint.stage,
        stageIn: stageIn,
        vertexOutputs: vertexOutputs,
        fragmentInputs: fragmentInputs,
        fragmentOutputs: fragmentOutputs,
        usesFrontFacingInInput: entryPoint.usesFrontFacingInInput,
        usesSampleIndexInInput: entryPoint.usesSampleIndexInInput,
        usesSampleMaskInInput: entryPoint.usesSampleMaskInInput,
        usesSampleMaskInOutput: entryPoint.usesSampleMaskInOutput,
        usesFragDepth: entryPoint.usesFragDepth,
        usesPrimitiveIndexInInput: entryPoint.usesPrimitiveIndexInInput,
        usesSubgroupInvocationIdInInput: entryPoint.usesSubgroupInvocationIdInInput,
        usesSubgroupSizeInInput: entryPoint.usesSubgroupSizeInInput,
        clipDistancesCount: entryPoint.clipDistancesCount
    )
}

private func interStageVariables(_ locations: [IOLocation]) -> [InterStageVariable] {
    let variables = locations.map {
        (location: $0.location, value: (dataType: metalDataType(for: $0.type), interpolation: $0.interpolation))
    }
    return inWTFHashTableOrder(variables)
        .map {
            InterStageVariable(location: $0.location, dataType: $0.value.dataType, interpolation: $0.value.interpolation)
        }
}

// The first value per location, in WTF::HashTable iteration order: RenderPipeline's walks over these lists report
// their first failure.
private func inWTFHashTableOrder<Value>(_ entries: [(location: UInt32, value: Value)]) -> [(location: UInt32, value: Value)] {
    var unique: [(location: UInt32, value: Value)] = []
    var seen = Set<UInt32>()
    for entry in entries where seen.insert(entry.location).inserted {
        unique.append(entry)
    }
    guard unique.count > 1 else {
        return unique
    }
    var keys = ContiguousArray(unique.map { $0.location })
    var destination = keys.mutableSpan
    WebGPU.Metal.sortInWTFHashTableOrder(&destination)
    let positions = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1.location, $0) })
    return keys.compactMap { key in positions[key].map { unique[$0] } }
}

// MARK: - IOType mappings

private func metalDataType(for type: IOType) -> MTLDataType {
    switch type {
    case .missing, .other:
        .none
    case .scalar(let scalar):
        metalDataType(scalar, vectorSize: 1)
    case .vector(let scalar, let size):
        metalDataType(scalar, vectorSize: size)
    }
}

private func metalDataType(_ scalar: IOScalar, vectorSize: UInt8) -> MTLDataType {
    switch (vectorSize, scalar) {
    case (1, .i32): .int
    case (1, .u32): .uint
    case (1, .f16): .half
    case (1, .f32): .float
    case (1, .bool): .bool
    case (2, .i32): .int2
    case (2, .u32): .uint2
    case (2, .f16): .half2
    case (2, .f32): .float2
    case (2, .bool): .bool2
    case (3, .i32): .int3
    case (3, .u32): .uint3
    case (3, .f16): .half3
    case (3, .f32): .float3
    case (3, .bool): .bool3
    case (4, .i32): .int4
    case (4, .u32): .uint4
    case (4, .f16): .half4
    case (4, .f32): .float4
    case (4, .bool): .bool4
    default:
        preconditionFailure("not an IO scalar or vector type")
    }
}

// f16 maps to float32 and vec3<f16> to float16x4.
private func vertexFormat(for type: IOType) -> WebGPU.VertexFormat {
    switch type {
    case .missing, .other:
        preconditionFailure("a vertex input without a scalar or vector type")
    case .scalar(let scalar):
        vertexFormat(scalar, vectorSize: 1)
    case .vector(let scalar, let size):
        vertexFormat(scalar, vectorSize: size)
    }
}

private func vertexFormat(_ scalar: IOScalar, vectorSize: UInt8) -> WebGPU.VertexFormat {
    switch (vectorSize, scalar) {
    case (1, .i32): .Sint32
    case (1, .u32): .Uint32
    case (1, .f16): .Float32
    case (1, .f32): .Float32
    case (2, .i32): .Sint32x2
    case (2, .u32): .Uint32x2
    case (2, .f16): .Float16x2
    case (2, .f32): .Float32x2
    case (3, .i32): .Sint32x3
    case (3, .u32): .Uint32x3
    case (3, .f16): .Float16x4
    case (3, .f32): .Float32x3
    case (4, .i32): .Sint32x4
    case (4, .u32): .Uint32x4
    case (4, .f16): .Float16x4
    case (4, .f32): .Float32x4
    default:
        preconditionFailure("not a vertex input scalar or vector type")
    }
}

// MARK: - Creation

// For Device::createShaderModule, after its device check.
@_expose(Cxx)
func createShaderModuleImpl(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ descriptor: borrowing WebGPU.ShaderModuleDescriptor
) -> ShaderModuleImpl {
    var supportedFeatures: Features = []
    if device.hasFeature(WebGPU.FeatureName.ClipDistances) {
        supportedFeatures.insert(.clipDistances)
    }
    if device.hasFeature(WebGPU.FeatureName.ShaderF16) {
        supportedFeatures.insert(.shaderF16)
    }
    if device.hasFeature(WebGPU.FeatureName.PrimitiveIndex) {
        supportedFeatures.insert(.primitiveIndex)
    }
    if device.hasFeature(WebGPU.FeatureName.Subgroups) {
        supportedFeatures.insert(.subgroups)
    }
    let configuration = Configuration(
        maxBuffersPlusVertexBuffersForVertexStage: device.maxBuffersPlusVertexBuffersForVertexStage(),
        maxBuffersForFragmentStage: device.maxBuffersForFragmentStage(),
        maxBuffersForComputeStage: device.maxBuffersForComputeStage(),
        maximumCombinedWorkgroupVariablesSize: device.limitsCopy().maxComputeWorkgroupStorageSize,
        supportedFeatures: supportedFeatures,
        identifierCharacterClasses: icuIdentifierCharacterClasses
    )
    let source = wgslSourceText(descriptor.code)

    var checkedModule: CheckedModuleBox?
    var errors: [CompilationMessage] = []
    var warnings: [CompilationMessage] = []
    WebGPU.Metal.runOnWGSLCompileThread {
        switch staticCheck(source, configuration: configuration) {
        case .failure(let failedCheck):
            errors = failedCheck.errors
            warnings = failedCheck.warnings
        case .success(let module):
            warnings = module.warnings
            checkedModule = CheckedModuleBox(module)
        }
    }
    return ShaderModuleImpl(checkedModule: checkedModule, errors: errors, warnings: warnings, device: device, deviceImpl: deviceImpl)
}

@_expose(Cxx)
func makeInvalidShaderModuleImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> ShaderModuleImpl {
    ShaderModuleImpl(checkedModule: nil, errors: [], warnings: [], device: device, deviceImpl: deviceImpl)
}
