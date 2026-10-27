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
internal import WGSL
import WebGPU_Internal.ComputePipeline
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Private.WebGPUCpp

// Shared by the compute and render pipeline creation code.

/// One compiled entry point, waiting for Metal to compile its MSL.
final class PreparedLibrary {
    let entryPoint: EntryPointInformation
    let resolvedOverrides: ResolvedOverrides
    let metalSource: WTF.String
    let label: NSString?
    let appleGPUFamily: UInt32
    let usesInvariant: Bool

    init(entryPoint: EntryPointInformation, resolvedOverrides: ResolvedOverrides, msl: WTF.String, label: NSString?, deviceImpl: DeviceImpl)
    {
        self.entryPoint = entryPoint
        self.resolvedOverrides = resolvedOverrides
        self.metalSource = msl
        self.label = label
        self.appleGPUFamily = deviceImpl.appleGPUFamily()
        self.usesInvariant = entryPoint.usesInvariant
    }

    func mangledName() -> NSString {
        entryPoint.mangledName as NSString
    }
}

struct PrepareLibraryError: Error {
    let message: String?
}

/// Compiles `entryPoint` of `shaderModule` to MSL.
///
/// A nil `layout` means no layout yet, or auto layout. The minimum buffer sizes of an explicit layout are merged into
/// `minimumBufferSizes`, after the compiler has written the shader's sizes back into it.
func prepareLibrary(
    _ shaderModule: ShaderModuleImpl,
    layout: PipelineLayoutImpl?,
    entryPoint: Name?,
    label: NSString?,
    constants: [PipelineConstant],
    deviceImpl: DeviceImpl,
    minimumBufferSizes: inout MinimumBufferSizes
) -> Result<PreparedLibrary, PrepareLibraryError> {
    guard let entryPoint, !entryPoint.utf16.isEmpty, shaderModule.isValid() else {
        return .failure(PrepareLibraryError(message: nil))
    }

    var explicitLayout: PipelineLayout? = nil
    if let layout, layout.numberOfBindGroupLayouts() > 0 {
        explicitLayout = makeExplicitWGSLLayout(layout)
    }

    let deviceState = DeviceState(
        appleGPUFamily: deviceImpl.appleGPUFamily(),
        shaderValidationEnabled: deviceImpl.isShaderValidationEnabled()
    )
    let information: EntryPointInformation
    let library: GeneratedLibrary
    switch shaderModule.compile(entryPoint: entryPoint, explicitLayout: &explicitLayout, constants: constants, deviceState: deviceState) {
    case .prepareFailed(let error), .generateFailed(let error):
        return .failure(PrepareLibraryError(message: error.message))
    case .entryPointNotFound, .invalidPipelineConstant:
        return .failure(PrepareLibraryError(message: nil))
    case .compiled(let compiledInformation, let generatedLibrary):
        information = compiledInformation
        library = generatedLibrary
    }

    if let layout, let explicitLayout {
        for group in 0..<layout.numberOfBindGroupLayouts() {
            let groupIndex = UInt32(truncatingIfNeeded: group)
            minimumBufferSizes.addGroup(groupIndex)
            for entry in explicitLayout.bindGroupLayouts[group].entries {
                if case .buffer(let buffer) = entry.bindingMember {
                    minimumBufferSizes.merge(group: groupIndex, binding: entry.binding, size: buffer.minBindingSize)
                }
            }
        }
    }

    return .success(
        PreparedLibrary(
            entryPoint: information,
            resolvedOverrides: library.resolvedOverrides,
            msl: wtfString(utf8: library.msl.utf8),
            label: label,
            deviceImpl: deviceImpl
        )
    )
}

// MARK: - The library and pipeline-state compiles

/// Whether a compile may run asynchronously, which it only does while the device has an Instance.
enum LibraryCompilation {
    case synchronous
    case asynchronous
}

/// PSO logging, in debug and fuzzing builds, compiles one pipeline at a time.
func asynchronousIfPossible() -> LibraryCompilation {
    WebGPU.Metal.psoLoggingIsEnabled() ? .synchronous : .asynchronous
}

/// The scheduler of the device's Instance, for a compile that runs asynchronously; nil compiles synchronously.
///
/// The compile holds the scheduler and not the Instance, so that no Metal thread releases the Instance.
func asynchronousCompileScheduler(
    _ compilation: LibraryCompilation,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl
) -> InstanceScheduler? {
    guard compilation == .asynchronous, CxxBridging.protectedInstance(device) != nil else {
        return nil
    }
    return deviceImpl.instanceScheduler()
}

/// Runs `body` with the device's error reporting paused or not, as `suppressErrors` says, then restores it.
func withErrorReporting(_ deviceImpl: DeviceImpl, suppressingErrors suppressErrors: Bool, _ body: () -> Void) {
    let wasPaused = deviceImpl.pauseErrorReporting(suppressErrors)
    defer {
        _ = deviceImpl.pauseErrorReporting(wasPaused)
    }
    body()
}

/// An asynchronous compile's continuation, carried from Metal's completion queue to the API thread.
///
/// Unchecked Sendable: the continuation and what it captures belong to the Instance's API thread. The Metal thread only
/// hands the box to a work item, and the scheduler's hop orders that before the API thread resumes it.
private final class CompileContinuation<Value>: @unchecked Sendable {
    private var body: ((Value?, NSError?) -> Void)?

    init(_ body: @escaping (Value?, NSError?) -> Void) {
        self.body = body
    }

    func resume(_ value: Value?, _ error: (any Error)?) {
        if let body = body.take() {
            body(value, error.map { $0 as NSError })
        }
    }
}

/// The hop of an asynchronous compile back to the API thread.
///
/// Metal's completion handler holds it, and with it the Instance's scheduler. The work item it schedules holds only the
/// continuation, so a work item that never runs releases the continuation once Metal releases its handler.
private final class CompileHop<Value: Sendable>: Sendable {
    private let scheduler: InstanceScheduler
    private let continuation: CompileContinuation<Value>

    init(_ scheduler: InstanceScheduler, _ continuation: @escaping (Value?, NSError?) -> Void) {
        self.scheduler = scheduler
        self.continuation = CompileContinuation(continuation)
    }

    // On Metal's completion queue.
    func deliver(_ value: Value?, _ error: (any Error)?) {
        let continuation = continuation
        var workItem = CxxBridging.InstanceWorkItem {
            continuation.resume(value, error)
        }
        scheduler.scheduleWork(&workItem)
    }
}

#if ENABLE_WEBGPU_BY_DEFAULT
/// The math settings of every generated library, read from the user defaults once.
private let libraryMathSettings: (mode: MTLMathMode, functions: MTLMathFloatingPointFunctions) = {
    let defaults = UserDefaults.standard
    let requireSafeMath = defaults.bool(forKey: "WebKitWebGPUEnableSafeMath")
    let mode: MTLMathMode = requireSafeMath || defaults.bool(forKey: "WebKitWebGPUEnableSafeMathMode") ? .safe : .relaxed
    let functions: MTLMathFloatingPointFunctions =
        requireSafeMath || defaults.bool(forKey: "WebKitWebGPUEnablePrecisionMathFunctions") ? .precise : .fast
    return (mode, functions)
}()
#else
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "fastMathEnabled is the math setting before mathMode")
#endif
private func enableFastMath(_ options: MTLCompileOptions) {
    options.fastMathEnabled = true
}
#endif

private func compileOptions(_ library: PreparedLibrary) -> MTLCompileOptions {
    let options = MTLCompileOptions()
    options.preprocessorMacros = ["__wgslMetalAppleGPUFamily": "\(library.appleGPUFamily)" as NSString]
    #if ENABLE_WEBGPU_BY_DEFAULT
    options.mathMode = libraryMathSettings.mode
    options.mathFloatingPointFunctions = libraryMathSettings.functions
    #else
    enableFastMath(options)
    #endif
    if library.usesInvariant {
        options.preserveInvariance = true
    }
    return options
}

private func libraryCompilationError(_ source: Swift.String, _ compilationError: (any Error)?) -> NSError {
    // FIXME: https://bugs.webkit.org/show_bug.cgi?id=250442
    let description = compilationError.map { ($0 as NSError).localizedDescription } ?? "(null)"
    WebGPU.Metal.logAlways("MSL compilation error: \(description)")
    return NSError(
        domain: "WebGPU",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to compile the shader source, generated metal:\n\(source) - error \(description)"]
    )
}

/// `completion` runs on the API thread: at once when the compile is synchronous, after the hop when it is not.
func compileLibrary(
    _ library: PreparedLibrary,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ compilation: LibraryCompilation,
    _ completion: @escaping ((any MTLLibrary)?, NSError?) -> Void
) {
    let metalDevice = deviceImpl.device()
    let source = (CxxBridging.convertWTFStringToNSString(library.metalSource) ?? "") as Swift.String
    let label = (library.label ?? "") as Swift.String

    if let scheduler = asynchronousCompileScheduler(compilation, device, deviceImpl) {
        // A nil device is lost or destroyed, which reports no error, and would never call back.
        guard let metalDevice else {
            completion(nil, nil)
            return
        }
        let hop = CompileHop<any MTLLibrary>(scheduler, completion)
        metalDevice.makeLibrary(source: source, options: compileOptions(library)) { mtlLibrary, compilationError in
            guard let mtlLibrary, compilationError == nil else {
                hop.deliver(nil, libraryCompilationError(source, compilationError))
                return
            }
            mtlLibrary.label = label
            hop.deliver(mtlLibrary, nil)
        }
        return
    }

    var compiledLibrary: (any MTLLibrary)?
    var error: NSError?
    WebGPU.Metal.newLibraryWithSource(metalDevice, source, compileOptions(library)) { mtlLibrary, compilationError in
        guard let mtlLibrary, compilationError == nil else {
            error = libraryCompilationError(source, compilationError)
            return
        }
        mtlLibrary.label = label
        compiledLibrary = mtlLibrary
    }
    completion(compiledLibrary, error)
}

private func reportPipelineStateError(_ error: NSError?) {
    if let error {
        WebGPU.Metal.logAlways("Pipeline state creation error: \(error.description)")
    }
}

/// `completion` gets the pipeline state, nil when it failed (logged), on the API thread as compileLibrary's does.
func createComputePipelineState(
    _ descriptor: MTLComputePipelineDescriptor,
    _ shaderSource: WTF.String,
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ compilation: LibraryCompilation,
    _ completion: @escaping ((any MTLComputePipelineState)?) -> Void
) {
    if let scheduler = asynchronousCompileScheduler(compilation, device, deviceImpl) {
        // As in compileLibrary: a lost device is nil and would never call back.
        guard let metalDevice = deviceImpl.device() else {
            completion(nil)
            return
        }
        let hop = CompileHop<any MTLComputePipelineState>(scheduler) { state, error in
            reportPipelineStateError(error)
            completion(state)
        }
        metalDevice.makeComputePipelineState(descriptor: descriptor, options: []) { state, _, error in
            hop.deliver(state, error)
        }
        return
    }

    var computePipelineState: (any MTLComputePipelineState)?
    var stateError: (any Error)?
    WebGPU.Metal.newComputePipelineState(deviceImpl.device(), descriptor, shaderSource) { state, error in
        computePipelineState = state
        stateError = error
    }
    reportPipelineStateError(stateError.map { $0 as NSError })
    completion(computePipelineState)
}

/// The asynchronous precompile of a render pipeline's state.
///
/// Its error is not reported: the first draw compiles the state again and reports it.
func precompileRenderPipelineState(
    _ descriptor: MTLRenderPipelineDescriptor,
    _ metalDevice: (any MTLDevice)?,
    _ scheduler: InstanceScheduler,
    _ completion: @escaping ((any MTLRenderPipelineState)?) -> Void
) {
    // As in compileLibrary: a lost device is nil and would never call back.
    guard let metalDevice else {
        completion(nil)
        return
    }
    let hop = CompileHop<any MTLRenderPipelineState>(scheduler) { state, _ in
        completion(state)
    }
    metalDevice.makeRenderPipelineState(descriptor: descriptor) { state, error in
        hop.deliver(state, error)
    }
}
