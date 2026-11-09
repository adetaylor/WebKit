// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import Metal
@_implementationOnly import WGSL
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.WGSLAPI
@_spiOnly import WebGPU_Private.WebGPUCpp

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

/// What a valid module was checked from, which checks again the same.
@_implementationOnly private struct ModuleSource {
    let text: SourceText
    let configuration: Configuration
}

/// Keeps a module's checked module until it is released.
final class CheckedModuleUse {
    private let moduleImpl: ShaderModuleImpl

    fileprivate init(_ moduleImpl: ShaderModuleImpl) {
        self.moduleImpl = moduleImpl
    }

    deinit {
        moduleImpl.endCheckedModuleUse()
    }
}

// One per GPUShaderModule, held by its Swift callers, and holding the Device. Pipeline creation reads the reflection and compiles through it directly.
@_spi(WebKitGPU)
public final class ShaderModuleImpl: GPUObjectReference {
    // nil == invalid shader module.
    private let source: ModuleSource?
    // The checked module while a pipeline is being created from it. It is many times the size of the source, so it is
    // checked again from the source the next time.
    private var checkedModule: CheckedModuleBox?
    private var checkedModuleUseCount = 0
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

    // `source` is what `checkedModule` was checked from; both or neither.
    fileprivate init(
        checkedModule: CheckedModuleBox?,
        source: ModuleSource?,
        errors: [CompilationMessage],
        warnings: [CompilationMessage],
        deviceImpl: DeviceImpl
    ) {
        self.deviceImpl = deviceImpl
        self.source = checkedModule != nil ? source : nil
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

    public func isValid() -> Bool {
        source != nil
    }

    /// Keeps the checked module, checking the source again first if it was released, until the use goes. nil for an
    /// invalid module.
    func useCheckedModule() -> CheckedModuleUse? {
        guard let source else {
            return nil
        }
        if checkedModule == nil {
            var checked: CheckedModuleBox?
            runOnWGSLCompileThread {
                // The source passed this check when the module was created, so it passes again.
                switch staticCheck(source.text, configuration: source.configuration) {
                case .failure:
                    break
                case .success(let module):
                    checked = CheckedModuleBox(module)
                }
            }
            guard let checked else {
                assertionFailure("a valid module's source failed its check")
                return nil
            }
            checkedModule = checked
        }
        checkedModuleUseCount += 1
        return CheckedModuleUse(self)
    }

    fileprivate func endCheckedModuleUse() {
        precondition(checkedModuleUseCount > 0)
        checkedModuleUseCount -= 1
        if checkedModuleUseCount == 0 {
            checkedModule = nil
        }
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpushadermodule-getcompilationinfo: errors first, then warnings. What
    // ShaderModule::compilationInfo gives, for a Swift caller.
    public func compilationInfo() -> [GPUShaderCompilationMessage] {
        messages.indices.map { index in
            let message = messages[index]
            return GPUShaderCompilationMessage(
                message: stringNilIfEmpty(message.text) ?? "",
                isError: index < errorCount,
                lineNumber: UInt64(message.lineNumber),
                linePosition: UInt64(message.lineOffset) + 1,
                offset: UInt64(message.offset),
                length: UInt64(message.length)
            )
        }
    }

    // The validation error message of a module that failed to compile. It is what C++ built with StringPrintStream, whose
    // round trip through UTF-8 replaces unpaired surrogates and cuts each message at a NUL.
    fileprivate func compilationErrorMessage() -> Swift.String {
        var result = "\(errorCount) error\(errorCount != 1 ? "s" : "") generated while compiling the shader:"
        for message in messages.prefix(errorCount) {
            let text = stringNilIfEmpty(message.text) ?? ""
            result += "\n\(message.lineNumber):\(message.lineOffset): \(text.prefix { $0 != "\0" })"
        }
        return result
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
            preconditionFailure("compile() on a shader module without a use of its checked module")
        }
        var compilation: EntryPointCompilation?
        runOnWGSLCompileThread {
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
            preconditionFailure("evaluateWorkgroupSize() on a shader module without a use of its checked module")
        }
        var size: WorkgroupExtent?
        runOnWGSLCompileThread {
            size = checkedModule.module.evaluateWorkgroupSize(entryPoint: entryPoint, overrides: overrides).size
        }
        return size
    }
}

// The default entry point of a stage: its only entry point, else none.
@_implementationOnly private struct DefaultEntryPoint {
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
        usesDualSourceBlending: entryPoint.usesDualSourceBlending,
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
    let keys = sortedInWTFHashTableOrder(unique.map { $0.location })
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

// https://gpuweb.github.io/gpuweb/#dictdef-gpucompilationmessage
@_spi(WebKitGPU)
public struct GPUShaderCompilationMessage {
    public let message: Swift.String
    // An error, or else a warning.
    public let isError: Bool
    public let lineNumber: UInt64
    public let linePosition: UInt64
    public let offset: UInt64
    public let length: UInt64
}

@_spi(WebKitGPU)
public typealias ShaderModuleReference = ShaderModuleImpl

// MARK: - Creation

// Device::createShaderModule, for a Swift caller. The descriptor's compilation hints aren't used yet, by either.
func createShaderModuleImpl(_ deviceImpl: DeviceImpl, code: Swift.String) -> ShaderModuleImpl {
    guard deviceImpl.isValid() else {
        return makeInvalidShaderModuleImpl(deviceImpl)
    }
    return createShaderModuleImpl(deviceImpl, source: SourceText(code))
}

// Reports the validation error of a module that fails to compile.
private func createShaderModuleImpl(_ deviceImpl: DeviceImpl, source: SourceText) -> ShaderModuleImpl {
    var supportedFeatures: Features = []
    if deviceImpl.hasFeature(WebGPU.FeatureName.ClipDistances) {
        supportedFeatures.insert(.clipDistances)
    }
    if deviceImpl.hasFeature(WebGPU.FeatureName.ShaderF16) {
        supportedFeatures.insert(.shaderF16)
    }
    if deviceImpl.hasFeature(WebGPU.FeatureName.PrimitiveIndex) {
        supportedFeatures.insert(.primitiveIndex)
    }
    if deviceImpl.hasFeature(WebGPU.FeatureName.Subgroups) {
        supportedFeatures.insert(.subgroups)
    }
    if deviceImpl.hasFeature(WebGPU.FeatureName.DualSourceBlending) {
        supportedFeatures.insert(.dualSourceBlending)
    }
    let configuration = Configuration(
        maxBuffersPlusVertexBuffersForVertexStage: deviceImpl.maxBuffersPlusVertexBuffersForVertexStage(),
        maxBuffersForFragmentStage: deviceImpl.maxBuffersForFragmentStage(),
        maxBuffersForComputeStage: deviceImpl.maxBuffersForComputeStage(),
        maximumCombinedWorkgroupVariablesSize: deviceImpl.deviceLimits().maxComputeWorkgroupStorageSize,
        supportedFeatures: supportedFeatures,
        identifierCharacterClasses: icuIdentifierCharacterClasses
    )
    var checkedModule: CheckedModuleBox?
    var errors: [CompilationMessage] = []
    var warnings: [CompilationMessage] = []
    runOnWGSLCompileThread {
        switch staticCheck(source, configuration: configuration) {
        case .failure(let failedCheck):
            errors = failedCheck.errors
            warnings = failedCheck.warnings
        case .success(let module):
            warnings = module.warnings
            checkedModule = CheckedModuleBox(module)
        }
    }
    let impl = ShaderModuleImpl(
        checkedModule: checkedModule,
        source: ModuleSource(text: source, configuration: configuration),
        errors: errors,
        warnings: warnings,
        deviceImpl: deviceImpl
    )
    if !impl.isValid() {
        deviceImpl.generateAValidationError(impl.compilationErrorMessage())
    }
    return impl
}

func makeInvalidShaderModuleImpl(_ deviceImpl: DeviceImpl) -> ShaderModuleImpl {
    ShaderModuleImpl(checkedModule: nil, source: nil, errors: [], warnings: [], deviceImpl: deviceImpl)
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createshadermodule, from WGSL. The label isn't kept.
    public func createShaderModule(code: Swift.String, label: Swift.String?) -> ShaderModuleReference {
        createShaderModuleImpl(self, code: code)
    }
}

// MARK: - The WGSL compile thread, hash table order and ICU (ShaderModule.mm)

/// Runs `work` on a thread with the stack WGSL compilation needs, and returns once it has run: the calling thread, unless
/// the compiler was built without optimization, which needs a larger stack than the WebGPU thread's.
func runOnWGSLCompileThread(_ work: () -> Void) {
    guard let stackSize = CompileThread.recommendedStackSize else {
        work()
        return
    }
    withoutActuallyEscaping(work) { work in
        let call = WGSLCompileThreadCall(work)
        let thread = Foundation.Thread {
            call.run()
        }
        thread.name = "WGSL compile"
        thread.stackSize = stackSize
        thread.qualityOfService = .userInteractive
        thread.start()
        call.wait()
    }
}

/// The work of one runOnWGSLCompileThread() call on its thread.
///
/// Unchecked Sendable: the thread runs the work and releases it before it signals, and the calling thread waits for the
/// signal before it goes on.
private final class WGSLCompileThreadCall: @unchecked Sendable {
    private var work: (() -> Void)?
    private let done = DispatchSemaphore(value: 0)

    init(_ work: @escaping () -> Void) {
        self.work = work
    }

    func run() {
        work.take()?()
        done.signal()
    }

    func wait() {
        done.wait()
    }
}

/// `keys` (distinct) in the order a HashMap<uint32_t, T, DefaultHash<uint32_t>, UnsignedWithZeroKeyHashTraits<uint32_t>>
/// filled with them in their current order iterates them, for walks whose first failure picks an error message. Table
/// sizing ignores the value type, so a WTFHashSet replica of the keys iterates in the same order.
func sortedInWTFHashTableOrder(_ keys: [UInt32]) -> [UInt32] {
    var table = WTFHashSet<UInt32>()
    for key in keys {
        // The traits' empty and deleted values, which HashTable rejects.
        precondition(key < UInt32.max - 1)
        table.add(key)
    }
    precondition(table.count == keys.count)
    var result: [UInt32] = []
    result.reserveCapacity(keys.count)
    table.forEachKeyInWTFOrder { result.append($0) }
    return result
}

/// XID_Start (false) or XID_Continue (true) of the running OS's ICU, as the sorted, disjoint, half-open [start, end) scalar
/// ranges the lexer classifies identifiers with, flattened.
func icuIdentifierRanges(xidContinue: Bool) -> [UInt32] {
    var status = U_ZERO_ERROR
    // Safety: `status` outlives the call, which only writes it, and ICU's property sets live as long as the process.
    let set = unsafe u_getBinaryPropertySet(xidContinue ? UCHAR_XID_CONTINUE : UCHAR_XID_START, &status)
    precondition(status.rawValue <= U_ZERO_ERROR.rawValue)
    // Safety: `set` is ICU's, as above.
    let itemCount = unsafe uset_getItemCount(set)
    var result: [UInt32] = []
    result.reserveCapacity(2 * Int(itemCount))
    for index in 0..<itemCount {
        var start: UChar32 = 0
        var end: UChar32 = 0
        // Safety: `start`, `end` and `status` outlive the call, which only writes them, and a nil string of capacity 0
        // gets no characters.
        let stringLength = unsafe uset_getItem(set, index, &start, &end, nil, 0, &status)
        precondition(stringLength == 0 && status.rawValue <= U_ZERO_ERROR.rawValue)
        result.append(UInt32(bitPattern: start))
        result.append(UInt32(bitPattern: end + 1))
    }
    return result
}
