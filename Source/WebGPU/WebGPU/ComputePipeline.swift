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

import Foundation
import Metal
@_implementationOnly import WGSL
@_implementationOnly import WebGPU_Internal.ComputePipeline
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.PipelineLayout
import WebGPU_Private.WebGPUCpp

// One per GPUComputePipeline, held by its Swift callers, the passes that set it and the C++ API's shell
// WebGPU::Metal::ComputePipeline. The compute pass reads it directly.
@_expose(Cxx)
@_spi(WebKitGPU)
public final class ComputePipelineImpl: GPUObjectReference {
    // nil == invalid pipeline.
    private let backingComputePipelineState: (any MTLComputePipelineState)?
    // An invalid pipeline carries an invalid-state layout.
    let pipelineLayoutImpl: PipelineLayoutImpl
    // All zero for an invalid pipeline.
    let parameters: WebGPU.Metal.ComputePipelineParameters
    let minimumBufferSizes: MinimumBufferSizes
    // Declared last, so that the device outlives the rest of the pipeline.
    let deviceImpl: DeviceImpl
    let device: WebGPU.Metal.Device

    init(
        computePipelineState: (any MTLComputePipelineState)?,
        pipelineLayoutImpl: PipelineLayoutImpl,
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl,
        parameters: WebGPU.Metal.ComputePipelineParameters,
        minimumBufferSizes: MinimumBufferSizes
    ) {
        self.backingComputePipelineState = computePipelineState
        self.pipelineLayoutImpl = pipelineLayoutImpl
        self.parameters = parameters
        self.minimumBufferSizes = minimumBufferSizes
        self.deviceImpl = deviceImpl
        self.device = device
    }

    func computePipelineState() -> (any MTLComputePipelineState)? {
        backingComputePipelineState
    }

    @_expose(Cxx)
    public func isValid() -> Bool {
        backingComputePipelineState != nil && pipelineLayoutImpl.isValid()
    }

    var threadsPerThreadgroup: MTLSize {
        MTLSize(
            width: Int(bitPattern: parameters.threadsPerThreadgroupWidth),
            height: Int(bitPattern: parameters.threadsPerThreadgroupHeight),
            depth: Int(bitPattern: parameters.threadsPerThreadgroupDepth)
        )
    }

    @_expose(Cxx)
    func pipelineLayout() -> PipelineLayoutImpl {
        pipelineLayoutImpl
    }

    func uniqueId() -> UInt64 {
        parameters.uniqueId
    }

    // ComputePipeline::getBindGroupLayout, which wraps it in a shell.
    @_expose(Cxx)
    func bindGroupLayout(_ groupIndex: UInt32) -> BindGroupLayoutImpl {
        pipelineBindGroupLayout(
            device,
            deviceImpl,
            pipelineIsValid: isValid(),
            invalidPipelineMessage: "getBindGroupLayout: ComputePipeline is invalid",
            pipelineLayoutImpl,
            groupIndex
        )
    }
}

/// GPUPipelineBase.getBindGroupLayout, for both kinds of pipeline.
///
/// An invalid pipeline, or a group index of maxBindGroups or more, reports a validation error and invalidates the
/// pipeline's layout. Every group the layout does not have gets a new invalid bind group layout.
func pipelineBindGroupLayout(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    pipelineIsValid: Bool,
    invalidPipelineMessage: String,
    _ layoutImpl: PipelineLayoutImpl,
    _ groupIndex: UInt32
) -> BindGroupLayoutImpl {
    func invalidBindGroupLayout() -> BindGroupLayoutImpl {
        makeInvalidBindGroupLayoutImpl(device, deviceImpl)
    }

    if !pipelineIsValid {
        deviceImpl.generateAValidationError(invalidPipelineMessage)
        layoutImpl.makeInvalid()
        return invalidBindGroupLayout()
    }

    if groupIndex >= layoutImpl.numberOfBindGroupLayouts() {
        if groupIndex >= deviceImpl.limits.maxBindGroups {
            deviceImpl.generateAValidationError("getBindGroupLayout: groupIndex is out of range")
            layoutImpl.makeInvalid()
        }
        return invalidBindGroupLayout()
    }

    guard let impl = layoutImpl.bindGroupLayout(at: Int(groupIndex)) else {
        preconditionFailure("a valid pipeline layout has the Impl of each of its bind group layouts")
    }
    return impl
}

@_expose(Cxx)
func makeInvalidComputePipelineImpl(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ pipelineLayoutImpl: PipelineLayoutImpl
) -> ComputePipelineImpl {
    ComputePipelineImpl(
        computePipelineState: nil,
        pipelineLayoutImpl: pipelineLayoutImpl,
        device: device,
        deviceImpl: deviceImpl,
        parameters: WebGPU.Metal.ComputePipelineParameters(),
        minimumBufferSizes: MinimumBufferSizes()
    )
}

// MARK: - Creation (Device::createComputePipeline)

// https://gpuweb.github.io/gpuweb/#dictdef-gpucomputepipelinedescriptor, without its label.
@_spi(WebKitGPU)
public struct GPUComputePipelineDescriptor {
    // nil: a layout that the pipeline generates from its shader.
    public var layout: PipelineLayoutReference?
    public var compute: GPUProgrammableStage

    public init(layout: PipelineLayoutReference?, compute: GPUProgrammableStage) {
        self.layout = layout
        self.compute = compute
    }
}

// What compute pipeline creation reads of its descriptor, apart from the module and the layout, which the builder has.
@_implementationOnly
struct ComputePipelineInput {
    // createNSString() semantics: an empty or null label is @"", not nil.
    let label: Swift.String
    let entryPoint: Name?
    let constants: [PipelineConstant]

    init(_ descriptor: borrowing WebGPU.ComputePipelineDescriptor) {
        label = stringNilIfEmpty(descriptor.label) ?? ""
        entryPoint = wgslName(descriptor.compute.entryPoint)
        constants = pipelineConstants(descriptor.compute)
    }

    init(_ descriptor: GPUComputePipelineDescriptor, label: Swift.String) {
        self.label = label
        entryPoint = descriptor.compute.entryPointName
        constants = descriptor.compute.pipelineConstants
    }
}

/// Device::createComputePipeline and its asynchronous forms.
///
/// The C++ resolves the shader module and the layout (the replaced pipeline's or the descriptor's), which Swift cannot
/// downcast, and sets them with their Impls.
@_expose(Cxx)
final class ComputePipelineBuilder {
    private let device: WebGPU.Metal.Device
    private let deviceImpl: DeviceImpl
    private let shaderModuleImpl: ShaderModuleImpl
    private var layoutImpl: PipelineLayoutImpl?
    private var isReplacingPipeline = false

    fileprivate init(device: WebGPU.Metal.Device, deviceImpl: DeviceImpl, shaderModuleImpl: ShaderModuleImpl) {
        self.device = device
        self.deviceImpl = deviceImpl
        self.shaderModuleImpl = shaderModuleImpl
    }

    @_expose(Cxx)
    func setPipelineLayout(_ impl: PipelineLayoutImpl, _ isReplacingPipeline: Bool) {
        self.layoutImpl = impl
        self.isReplacingPipeline = isReplacingPipeline
    }

    /// The synchronous createComputePipeline: the pipeline, +1.
    @_expose(Cxx)
    func create(_ descriptor: borrowing WebGPU.ComputePipelineDescriptor) -> WebGPU.Metal.ComputePipeline {
        var result: [WebGPU.Metal.ComputePipeline] = []
        create(ComputePipelineInput(descriptor), isAsync: false, .synchronous) { pipeline, _ in
            result = [makeComputePipelineShell(pipeline)]
        }
        // A synchronous creation never defers its completion.
        precondition(result.count == 1)
        return result[0]
    }

    /// createComputePipelineAsync, and createComputePipelineWithPipelineLayoutFromPipelineAsync (a replacing builder).
    ///
    /// A replacing builder pauses error reporting while it runs. Takes the callback, leaving `callback` empty.
    @_expose(Cxx)
    func createAsync(
        _ descriptor: borrowing WebGPU.ComputePipelineDescriptor,
        _ callback: inout WebGPU.Metal.CreateComputePipelineAsyncCallback
    ) {
        let completion = ComputePipelineAsyncCompletion(
            device,
            deviceImpl,
            exchange(&callback, with: WebGPU.Metal.CreateComputePipelineAsyncCallback())
        )
        let wasErrorReportingPaused = isReplacingPipeline ? deviceImpl.pauseErrorReporting(true) : nil
        create(ComputePipelineInput(descriptor), isAsync: true, asynchronousIfPossible()) { pipeline, message in
            completion.complete(makeComputePipelineShell(pipeline), message)
        }
        if let wasErrorReportingPaused {
            _ = deviceImpl.pauseErrorReporting(wasErrorReportingPaused)
        }
    }

    // The synchronous createComputePipeline, for a Swift caller.
    @_expose(!Cxx)
    func create(_ descriptor: ComputePipelineInput) -> ComputePipelineReference {
        var result: [ComputePipelineReference] = []
        create(descriptor, isAsync: false, .synchronous) { pipeline, _ in
            result = [pipeline]
        }
        precondition(result.count == 1)
        return result[0]
    }

    // createComputePipelineAsync and its replacing form, for a Swift caller. `completion` gets the pipeline, whether it
    // succeeded, and the message it failed with, on a later turn of the API thread, as the C++ caller's callback does.
    @_expose(!Cxx)
    func createAsync(_ descriptor: ComputePipelineInput, _ completion: @escaping (ComputePipelineReference, Bool, String?) -> Void) {
        let device = self.device
        let deviceImpl = self.deviceImpl
        let wasErrorReportingPaused = isReplacingPipeline ? deviceImpl.pauseErrorReporting(true) : nil
        create(descriptor, isAsync: true, asynchronousIfPossible()) { pipeline, message in
            let resolve = {
                // A lost device makes invalid objects without errors.
                completion(pipeline, pipeline.isValid() || deviceImpl.isDestroyed(), message)
            }
            guard let instance = CxxBridging.protectedInstance(device) else {
                return resolve()
            }
            instance.scheduleWork(consuming: WebGPU.Metal.Instance.WorkItem { resolve() })
        }
        if let wasErrorReportingPaused {
            _ = deviceImpl.pauseErrorReporting(wasErrorReportingPaused)
        }
    }

    // `report` gets the pipeline (an invalid one on failure, with the message the asynchronous forms resolve with) on
    // the API thread: before this returns when every compile is synchronous.
    private func create(
        _ descriptor: ComputePipelineInput,
        isAsync: Bool,
        _ compilation: LibraryCompilation,
        _ report: @escaping (ComputePipelineImpl, String?) -> Void
    ) {
        let device = self.device
        let deviceImpl = self.deviceImpl
        // The synchronous form reports the error itself.
        let fail = { (message: String?) in
            if !isAsync {
                deviceImpl.generateAValidationError(message ?? "createComputePipeline failed")
            }
            report(makeInvalidComputePipeline(device, deviceImpl), message)
        }

        guard shaderModuleImpl.isValid(), shaderModuleImpl.deviceImpl === deviceImpl, let layoutImpl else {
            return fail(nil)
        }
        // isValidToUseWithDevice(layout, device). With the same device, the layout's device validity is deviceImpl.isValid().
        if !layoutImpl.isValid() || !CxxBridging.areDevicesEqual(layoutImpl.device, device) || !deviceImpl.isValid() {
            return fail("GPUDevice.createComputePipeline: Pipeline layout is invalid")
        }

        let pending = prepareComputePipeline(device, deviceImpl, descriptor, shaderModuleImpl, layoutImpl, isReplacingPipeline)
        guard let prepared = pending.prepared else {
            return fail(pending.failureMessage)
        }

        let suppressErrors = deviceImpl.isErrorReportingPaused()
        compileLibrary(prepared.library, device, deviceImpl, compilation) { library, libraryError in
            withErrorReporting(deviceImpl, suppressingErrors: suppressErrors) {
                guard let library else {
                    return fail(libraryError?.localizedDescription ?? "Compute library failed creation")
                }
                guard let computePipelineDescriptor = prepared.makeComputePipelineDescriptor(library) else {
                    return fail(nil)
                }
                // The pipeline state is the second half of the compile, and it is what a dispatch actually needs,
                // so the pipeline isn't handed back until Metal is done with it.
                createComputePipelineState(computePipelineDescriptor, prepared.library.metalSource, device, deviceImpl, compilation) {
                    computePipelineState in
                    withErrorReporting(deviceImpl, suppressingErrors: suppressErrors) {
                        guard let computePipelineState else {
                            deviceImpl.generateAnOutOfMemoryError(
                                "Compute pipeline failed compilation likely due to being too complex, please reduce its size"
                            )
                            return fail("GPUCompuePipeline could not compile")
                        }
                        report(prepared.makeImpl(computePipelineState, device), nil)
                    }
                }
            }
        }
    }
}

@_expose(Cxx)
func makeComputePipelineBuilder(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ shaderModuleImpl: ShaderModuleImpl
) -> ComputePipelineBuilder {
    ComputePipelineBuilder(device: device, deviceImpl: deviceImpl, shaderModuleImpl: shaderModuleImpl)
}

// The builder of a Swift caller's descriptor, with the module and layout that C++ sets on a C++ caller's: the layout of
// `pipelineToReplace` for createComputePipelineWithPipelineLayoutFromPipelineAsync.
func makeComputePipelineBuilder(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ descriptor: GPUComputePipelineDescriptor,
    replacingLayoutOf pipelineToReplace: ComputePipelineReference? = nil
) -> ComputePipelineBuilder {
    let builder = ComputePipelineBuilder(device: device, deviceImpl: deviceImpl, shaderModuleImpl: descriptor.compute.module.impl)
    if let pipelineToReplace {
        builder.setPipelineLayout(pipelineToReplace.impl.pipelineLayoutImpl, true)
    } else if let layout = descriptor.layout {
        builder.setPipelineLayout(layout, false)
    }
    return builder
}

/// Resolves the embedder's callback on a later turn of the API thread, never re-entrantly from the creation (at once
/// when the device has no Instance).
private final class ComputePipelineAsyncCompletion {
    private let device: WebGPU.Metal.Device
    private let deviceImpl: DeviceImpl
    private var callback: WebGPU.Metal.CreateComputePipelineAsyncCallback

    init(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, _ callback: consuming WebGPU.Metal.CreateComputePipelineAsyncCallback) {
        self.device = device
        self.deviceImpl = deviceImpl
        self.callback = callback
    }

    func complete(_ pipeline: WebGPU.Metal.ComputePipeline, _ message: String?) {
        guard let instance = CxxBridging.protectedInstance(device) else {
            return resolve(pipeline, message)
        }
        instance.scheduleWork(
            consuming: WebGPU.Metal.Instance.WorkItem {
                self.resolve(pipeline, message)
            }
        )
    }

    private func resolve(_ pipeline: WebGPU.Metal.ComputePipeline, _ message: String?) {
        var callback = exchange(&self.callback, with: WebGPU.Metal.CreateComputePipelineAsyncCallback())
        // A lost device makes invalid objects without errors.
        WebGPU.Metal.callCreateComputePipelineAsyncCallback(&callback, pipeline, pipeline.isValid() || deviceImpl.isDestroyed(), message)
    }
}

/// Everything of Device::createComputePipeline up to the MSL compile, after ComputePipelineBuilder.create has
/// rejected an invalid module, a module or layout of another device, and a missing layout.
private func prepareComputePipeline(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ descriptor: ComputePipelineInput,
    _ shaderModuleImpl: ShaderModuleImpl,
    _ layoutImpl: PipelineLayoutImpl,
    _ isReplacingPipeline: Bool
) -> PendingComputePipeline {
    let limits = deviceImpl.capabilities.limits
    let label = descriptor.label
    let entryPoint = descriptor.entryPoint ?? shaderModuleImpl.defaultComputeEntryPoint
    var minimumBufferSizes = MinimumBufferSizes()
    let library: PreparedLibrary
    switch prepareLibrary(
        shaderModuleImpl,
        layout: layoutImpl,
        entryPoint: entryPoint,
        label: label as NSString,
        constants: descriptor.constants,
        deviceImpl: deviceImpl,
        minimumBufferSizes: &minimumBufferSizes
    ) {
    case .success(let preparedLibrary):
        library = preparedLibrary
    case .failure(let error):
        return PendingComputePipeline(failure: error.message ?? "Compute library failed creation")
    }

    let information = library.entryPoint
    if information.stage != .compute || information.typedEntryPoint != .compute {
        return PendingComputePipeline(failure: nil)
    }

    if information.specializationConstants.count != library.resolvedOverrides.count {
        return PendingComputePipeline(failure: nil)
    }

    guard let size = shaderModuleImpl.evaluateWorkgroupSize(entryPoint: information.originalName, overrides: library.resolvedOverrides)
    else {
        return PendingComputePipeline(failure: "Failed to evaluate overrides")
    }
    if information.sizeForWorkgroupVariables > UInt64(limits.maxComputeWorkgroupStorageSize) {
        return PendingComputePipeline(failure: nil)
    }

    // Truncated to NSUInteger, as MTLSizeMake does, but in UInt64 so that arm64_32 rejects the same sizes as 64-bit; the
    // product wraps.
    let width = UInt64(truncatingIfNeeded: size.width)
    let height = UInt64(truncatingIfNeeded: size.height)
    let depth = UInt64(truncatingIfNeeded: size.depth)
    if width == 0 || width > UInt64(limits.maxComputeWorkgroupSizeX) || height == 0 || height > UInt64(limits.maxComputeWorkgroupSizeY)
        || depth == 0
        || depth > UInt64(limits.maxComputeWorkgroupSizeZ) || width &* height &* depth > UInt64(limits.maxComputeInvocationsPerWorkgroup)
    {
        return PendingComputePipeline(failure: nil)
    }

    if deviceImpl.pipelineIdsExhausted() {
        deviceImpl.loseTheDevice(.Unknown)
        return PendingComputePipeline(failure: "too many compute pipelines")
    }

    var finalLayoutImpl = layoutImpl
    if !isReplacingPipeline && layoutImpl.isAutoLayout(), let defaultLayout = information.defaultLayout {
        var bindGroupEntries: [[ResolvedLayoutEntry]] = []
        if let layoutError = appendDefaultLayout(&bindGroupEntries, from: defaultLayout, limits: limits) {
            return PendingComputePipeline(failure: layoutError)
        }
        let generated = makeGeneratedPipelineLayout(device: device, deviceImpl: deviceImpl, entries: bindGroupEntries)
        if !generated.isValid() {
            return PendingComputePipeline(failure: nil)
        }
        finalLayoutImpl = generated
    }

    // Claimed up front, so that pipelines compiling concurrently cannot be handed the same one.
    var parameters = WebGPU.Metal.ComputePipelineParameters()
    parameters.uniqueId = deviceImpl.takePipelineId()
    parameters.threadsPerThreadgroupWidth = UInt(width)
    parameters.threadsPerThreadgroupHeight = UInt(height)
    parameters.threadsPerThreadgroupDepth = UInt(depth)

    return PendingComputePipeline(
        PreparedComputePipeline(
            library: library,
            label: label,
            layoutImpl: finalLayoutImpl,
            deviceImpl: deviceImpl,
            minimumBufferSizes: minimumBufferSizes,
            parameters: parameters
        )
    )
}

/// prepareComputePipeline's result: the prepared pipeline, or the failure message (nil for the default
/// "createComputePipeline failed", and no PipelineError message).
private struct PendingComputePipeline {
    let prepared: PreparedComputePipeline?
    let failureMessage: String?

    init(failure message: String?) {
        self.prepared = nil
        self.failureMessage = message
    }

    init(_ prepared: PreparedComputePipeline) {
        self.prepared = prepared
        self.failureMessage = nil
    }
}

private final class PreparedComputePipeline {
    let library: PreparedLibrary
    let label: String
    // The layout the pipeline gets: the descriptor's, the replaced pipeline's, or the generated one.
    let layoutImpl: PipelineLayoutImpl
    let deviceImpl: DeviceImpl
    let minimumBufferSizes: MinimumBufferSizes
    let parameters: WebGPU.Metal.ComputePipelineParameters

    init(
        library: PreparedLibrary,
        label: String,
        layoutImpl: PipelineLayoutImpl,
        deviceImpl: DeviceImpl,
        minimumBufferSizes: MinimumBufferSizes,
        parameters: WebGPU.Metal.ComputePipelineParameters
    ) {
        self.library = library
        self.label = label
        self.layoutImpl = layoutImpl
        self.deviceImpl = deviceImpl
        self.minimumBufferSizes = minimumBufferSizes
        self.parameters = parameters
    }

    /// The function checks and createComputePipelineDescriptor. nil: an invalid pipeline without a message.
    func makeComputePipelineDescriptor(_ library: any MTLLibrary) -> MTLComputePipelineDescriptor? {
        guard let function = createFunction(library, self.library.entryPoint.mangledName, label), function.functionType == .kernel else {
            return nil
        }

        let descriptor = MTLComputePipelineDescriptor()
        setComputeShaderValidation(descriptor)
        descriptor.computeFunction = function
        for index in 0..<layoutImpl.numberOfBindGroupLayouts() {
            // Argument buffers are always immutable in WebGPU.
            descriptor.buffers[index].mutability = .immutable
        }
        descriptor.label = label
        return descriptor
    }

    // `device` is the one creation started on, which the creation holds: the prepared pipeline holds no Device
    // reference of its own.
    func makeImpl(_ state: any MTLComputePipelineState, _ device: WebGPU.Metal.Device) -> ComputePipelineImpl {
        ComputePipelineImpl(
            computePipelineState: state,
            pipelineLayoutImpl: layoutImpl,
            device: device,
            deviceImpl: deviceImpl,
            parameters: parameters,
            minimumBufferSizes: minimumBufferSizes
        )
    }
}

// An invalid pipeline still holds an invalid pipeline layout, so that it always has one.
func makeInvalidComputePipeline(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> ComputePipelineImpl {
    makeInvalidComputePipelineImpl(device, deviceImpl, makeInvalidPipelineLayoutImpl(device))
}

// Wraps a pipeline for the C++ API in a new shell, through DeviceImpl.stagedComputePipelineImpl.
private func makeComputePipelineShell(_ impl: ComputePipelineImpl) -> WebGPU.Metal.ComputePipeline {
    precondition(impl.deviceImpl.stagedComputePipelineImpl == nil)
    impl.deviceImpl.stagedComputePipelineImpl = impl
    return WebGPU.Metal.ComputePipeline.createWithStagedImpl(impl.device).ptr()
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createcomputepipeline: an invalid pipeline on failure.
    public func createComputePipeline(_ descriptor: GPUComputePipelineDescriptor, label: Swift.String?) -> ComputePipelineReference {
        makeComputePipelineBuilder(shell, impl, descriptor).create(ComputePipelineInput(descriptor, label: label ?? ""))
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createcomputepipelineasync, and, with `pipelineToReplace`, the
    // creation that takes that pipeline's layout. `completion` gets the pipeline, whether it succeeded, and the message
    // it failed with.
    public func createComputePipelineAsync(
        _ descriptor: GPUComputePipelineDescriptor,
        label: Swift.String?,
        replacingLayoutOf pipelineToReplace: ComputePipelineReference? = nil,
        _ completion: @escaping (ComputePipelineReference, Bool, Swift.String?) -> Void
    ) {
        makeComputePipelineBuilder(shell, impl, descriptor, replacingLayoutOf: pipelineToReplace)
            .createAsync(ComputePipelineInput(descriptor, label: label ?? ""), completion)
    }
}
