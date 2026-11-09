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
import Synchronization
@_implementationOnly import WGSL
@_implementationOnly import WebGPU_Internal.ComputePipeline
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.MetalSPI
@_spiOnly import WebGPU_Private.WebGPUCpp

// Shared by the compute and render pipeline creation code.

// https://gpuweb.github.io/gpuweb/#dictdef-gpuprogrammablestage
@_spi(WebKitGPU)
public struct GPUProgrammableStage {
    public var module: ShaderModuleReference
    // nil: the only entry point of the module for the stage.
    public var entryPoint: Swift.String?
    // The override keys and https://gpuweb.github.io/gpuweb/#typedefdef-gpupipelineconstantvalue values.
    public var constants: [(key: Swift.String, value: Double)]

    public init(module: ShaderModuleReference, entryPoint: Swift.String?, constants: [(key: Swift.String, value: Double)]) {
        self.module = module
        self.entryPoint = entryPoint
        self.constants = constants
    }

    var entryPointName: Name? {
        entryPoint.map { Name($0) }
    }

    var pipelineConstants: [PipelineConstant] {
        constants.map { PipelineConstant(key: Name($0.key), value: $0.value) }
    }
}

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
    psoLoggingIsEnabled() ? .synchronous : .asynchronous
}

/// The scheduler of the device's Instance, for a compile that runs asynchronously; nil compiles synchronously.
///
/// The compile holds the scheduler and not the Instance, so that no Metal thread releases the Instance.
func asynchronousCompileScheduler(
    _ compilation: LibraryCompilation,
    _ deviceImpl: DeviceImpl
) -> InstanceScheduler? {
    guard compilation == .asynchronous, deviceImpl.instanceImpl != nil else {
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
#endif

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "fastMathEnabled is the math setting before mathMode")
#endif
func enableFastMath(_ options: MTLCompileOptions) {
    options.fastMathEnabled = true
}

// Metal's synchronous compiles, with the error (warnings) that Metal returns together with an object, which their throwing
// imports drop: Pipeline.swift treats an object with an error as a failure. nil and nil for a nil device.

func newLibraryKeepingWarnings(
    _ device: (any MTLDevice)?,
    _ source: String,
    _ options: MTLCompileOptions?
) -> ((any MTLLibrary)?, NSError?) {
    guard let device else {
        return (nil, nil)
    }
    var error: NSError?
    // Safety: `error` outlives the call, which only stores an autoreleased NSError into it.
    let library = unsafe (device as AnyObject).makeLibraryKeepingWarnings(source: source, options: options, error: &error)
    return (library, error)
}

private func newComputePipelineStateKeepingWarnings(
    _ device: (any MTLDevice)?,
    _ descriptor: MTLComputePipelineDescriptor
) -> ((any MTLComputePipelineState)?, NSError?) {
    guard let device else {
        return (nil, nil)
    }
    var error: NSError?
    // Safety: as in newLibraryKeepingWarnings().
    let state = unsafe (device as AnyObject).makeComputePipelineStateKeepingWarnings(
        descriptor: descriptor,
        options: [],
        reflection: nil,
        error: &error
    )
    return (state, error)
}

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
    logAlways("MSL compilation error: \(description)")
    return NSError(
        domain: "WebGPU",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to compile the shader source, generated metal:\n\(source) - error \(description)"]
    )
}

/// `completion` runs on the API thread: at once when the compile is synchronous, after the hop when it is not.
func compileLibrary(
    _ library: PreparedLibrary,
    _ deviceImpl: DeviceImpl,
    _ compilation: LibraryCompilation,
    _ completion: @escaping ((any MTLLibrary)?, NSError?) -> Void
) {
    let metalDevice = deviceImpl.device()
    let source = stringNilIfEmpty(library.metalSource) ?? ""
    let label = (library.label ?? "") as Swift.String

    if let scheduler = asynchronousCompileScheduler(compilation, deviceImpl) {
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

    let (mtlLibrary, compilationError) = newLibraryKeepingWarnings(metalDevice, source, compileOptions(library))
    guard let mtlLibrary, compilationError == nil else {
        completion(nil, libraryCompilationError(source, compilationError))
        return
    }
    mtlLibrary.label = label
    completion(mtlLibrary, nil)
}

private func reportPipelineStateError(_ error: NSError?) {
    if let error {
        logAlways("Pipeline state creation error: \(error.description)")
    }
}

/// `completion` gets the pipeline state, nil when it failed (logged), on the API thread as compileLibrary's does.
func createComputePipelineState(
    _ descriptor: MTLComputePipelineDescriptor,
    _ shaderSource: WTF.String,
    _ deviceImpl: DeviceImpl,
    _ compilation: LibraryCompilation,
    _ completion: @escaping ((any MTLComputePipelineState)?) -> Void
) {
    if let scheduler = asynchronousCompileScheduler(compilation, deviceImpl) {
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

    #if WEBGPU_PSO_REPRO
    dumpMetalReproCaseComputePSO(stringNilIfEmpty(shaderSource) ?? "", descriptor.computeFunction?.name ?? "")
    #endif
    let (computePipelineState, stateError) = newComputePipelineStateKeepingWarnings(deviceImpl.device(), descriptor)
    #if WEBGPU_PSO_REPRO
    clearMetalPSORepro()
    #endif
    reportPipelineStateError(stateError)
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

// MARK: - PSO repro (debug and fuzzing builds)

/// Whether PSO logging makes every compile synchronous, writing the repro case of each pipeline state compile: only in
/// debug and fuzzing builds.
func psoLoggingIsEnabled() -> Bool {
    #if WEBGPU_PSO_REPRO
    enablePsoLogging()
    #else
    false
    #endif
}

#if WEBGPU_PSO_REPRO
private func enablePsoLogging() -> Bool {
    #if WEBGPU_PSO_REPRO_ALWAYS
    true
    #else
    UserDefaults.standard.bool(forKey: "WebKitWebGPULogPSOState")
    #endif
}

/// The render pipeline's repro case, with its synchronous pipeline-state compile: the compile's error message, which makes
/// the pipeline invalid, or nil.
func reproduceRenderPipelineState(
    _ device: (any MTLDevice)?,
    _ maxVertexBuffers: UInt32,
    _ renderPipelineDescriptor: MTLRenderPipelineDescriptor,
    _ vertexShaderSource: borrowing WTF.String,
    _ fragmentShaderSource: borrowing WTF.String,
    _ shaderLocations: [UInt32]
) -> String? {
    let dumped = dumpMetalReproCaseRenderPSO(
        stringNilIfEmpty(vertexShaderSource) ?? "",
        renderPipelineDescriptor.vertexFunction?.name ?? "",
        stringNilIfEmpty(fragmentShaderSource) ?? "",
        renderPipelineDescriptor.fragmentFunction?.name ?? "",
        renderPipelineDescriptor,
        sortedInWTFHashTableOrder(shaderLocations),
        maxVertexBuffers
    )
    guard dumped else {
        return nil
    }
    renderPipelineDescriptor.supportIndirectCommandBuffers = true
    var error: NSError?
    if let device {
        // Safety: as in newLibraryKeepingWarnings().
        _ = unsafe (device as AnyObject).makeRenderPipelineStateKeepingWarnings(descriptor: renderPipelineDescriptor, error: &error)
    }
    clearMetalPSORepro()
    return error?.localizedDescription
}

// The repro case of this thread's compile.
private var psoRepro: String {
    get {
        Foundation.Thread.current.threadDictionary[psoReproKey] as? String ?? ""
    }
    set {
        Foundation.Thread.current.threadDictionary[psoReproKey] = newValue
    }
}

private let psoReproKey = "WebKitWebGPUPSORepro"

// The handlers that the exit handlers replaced, by signal.
private let existingSignalHandlers = Mutex<[sig_t?]>(Array(repeating: nil, count: 32))

// The address signal() returns a handler at: 0 for SIG_DFL, 1 for SIG_IGN and -1 for SIG_ERR, which aren't functions.
private func signalHandlerAddress(_ handler: sig_t?) -> Int {
    // Safety: an optional C function pointer is one pointer-sized word, 0 for nil.
    unsafe unsafeBitCast(handler, to: Int.self)
}

private func printPsoOnProgramExit(_ sig: Int32) {
    let repro = psoRepro
    if !repro.isEmpty {
        logAlways(
            "// ------------------------------------------------------------------------\n// Dumping Metal repro case:\n// ------------------------------------------------------------------------\n\(repro)\n// ------------------------------------------------------------------------\n// End of repro case\n// ------------------------------------------------------------------------"
        )
    }

    let previousHandler = existingSignalHandlers.withLock { $0[Int(sig)] }
    if let previousHandler, signalHandlerAddress(previousHandler) != 1, signalHandlerAddress(previousHandler) != -1 {
        previousHandler(sig)
    }
}

private let psoExitHandlersRegistered: Bool = {
    var handlersRegistered = true
    for sig in [SIGINT, SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGSEGV] {
        let previous = signal(sig, SIG_DFL)
        precondition(Int(sig) < 32)
        existingSignalHandlers.withLock { $0[Int(sig)] = previous }
        errno = 0
        if signalHandlerAddress(signal(sig, printPsoOnProgramExit)) == -1 {
            logAlways("Error: Unable to install signal handler for \(sig) - errno \(errno)")
            handlersRegistered = false
        }
    }
    return handlersRegistered
}()

private func printToFileForPsoRepro() {
    #if os(macOS)
    let defaultURL = FileManager.default.temporaryDirectory
    #else
    let defaultURL = URL(fileURLWithPath: "/tmp/", isDirectory: true)
    #endif
    var outputURL = defaultURL.appendingPathComponent("com.apple.WebKit")
    do {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true, attributes: nil)
    } catch {
        logAlways("Error saving repro to \(outputURL as NSURL) - \(error as NSError)")
        return
    }

    outputURL = outputURL.appendingPathComponent("psoRepro.mm")
    if (try? Data(psoRepro.utf8).write(to: outputURL)) != nil {
        logAlways("Sucessfully saved repro to \(outputURL as NSURL)")
    } else {
        logAlways("Error saving repro to \(outputURL as NSURL) - (null)")
    }
}

private func dumpMetalReproCaseComputePSO(_ shaderSource: String, _ functionName: String) {
    if !enablePsoLogging() {
        return
    }

    let printToFile = !psoExitHandlersRegistered

    var repro = psoPreamble
    repro += psoComputeMainPrefix
    repro += shaderSource
    repro += ")\";"
    repro += psoComputeLibraryAndFunction
    repro += functionName
    repro += ")];"
    repro += psoComputePipelineAndMainEnd
    psoRepro = repro

    if printToFile {
        printToFileForPsoRepro()
    }
}

private func dumpMetalReproCaseRenderPSO(
    _ vertexShaderSource: String,
    _ vertexFunctionName: String,
    _ fragmentShaderSource: String,
    _ fragmentFunctionName: String,
    _ descriptor: MTLRenderPipelineDescriptor,
    _ shaderLocations: [UInt32],
    _ maxVertexBuffers: UInt32
) -> Bool {
    if !enablePsoLogging() {
        return false
    }

    let printToFile = !psoExitHandlersRegistered

    var repro = psoRepro
    repro += psoPreamble
    repro += psoRenderMakePsoPrefix
    repro += vertexShaderSource
    repro += ")\";\nNSString *fragmentShaderSource = @R\"("
    repro += fragmentShaderSource
    repro += ")\";"
    repro += psoRenderLibrariesAndFunctionPrefix
    repro += vertexFunctionName
    repro += "\"]; functionFS = [fragmentLibrary newFunctionWithName:@\""
    repro += fragmentFunctionName
    repro += psoRenderDescriptorPrefix
    repro += "\(descriptor.rasterSampleCount)"
    repro += ";\n mtlRenderPipelineDescriptor.alphaToCoverageEnabled = "
    repro += descriptor.isAlphaToCoverageEnabled ? "1" : "0"
    repro += ";\n mtlRenderPipelineDescriptor.alphaToOneEnabled = "
    repro += descriptor.isAlphaToOneEnabled ? "1" : "0"
    repro += ";\n mtlRenderPipelineDescriptor.rasterizationEnabled = "
    repro += descriptor.isRasterizationEnabled ? "1" : "0"
    repro += ";\n mtlRenderPipelineDescriptor.maxVertexAmplificationCount = "
    repro += "\(UInt32(truncatingIfNeeded: descriptor.maxVertexAmplificationCount))"
    repro += ";\n mtlRenderPipelineDescriptor.depthAttachmentPixelFormat = (MTLPixelFormat)"
    repro += "\(UInt32(truncatingIfNeeded: descriptor.depthAttachmentPixelFormat.rawValue))"
    repro += ";\n mtlRenderPipelineDescriptor.stencilAttachmentPixelFormat = (MTLPixelFormat)"
    repro += "\(UInt32(truncatingIfNeeded: descriptor.stencilAttachmentPixelFormat.rawValue))"
    repro += ";\n mtlRenderPipelineDescriptor.inputPrimitiveTopology = (MTLPrimitiveTopologyClass)"
    repro += "\(UInt32(truncatingIfNeeded: descriptor.inputPrimitiveTopology.rawValue))"
    repro += ";\n mtlRenderPipelineDescriptor.supportIndirectCommandBuffers = YES;\n MTLVertexDescriptor *vertexDescriptor = [MTLVertexDescriptor new];"

    for i in 0..<Int(maxVertexBuffers) {
        if let d = descriptor.vertexDescriptor?.layouts[i] {
            repro += "{uint32_t location = "
            repro += "\(i)"
            repro += "; vertexDescriptor.layouts[location].stride = "
            repro += "\(d.stride)"
            repro += "; vertexDescriptor.layouts[location].stepFunction = (MTLVertexStepFunction)"
            repro += "\(d.stepFunction.rawValue)"
            repro += "; vertexDescriptor.layouts[location].stepRate = "
            repro += "\(d.stepRate)"
            repro += ";} mtlRenderPipelineDescriptor.vertexDescriptor = vertexDescriptor; \n"
        }
    }

    for shaderLocation in shaderLocations {
        if let a = descriptor.vertexDescriptor?.attributes[Int(shaderLocation)] {
            repro += "{uint32_t shaderLocation = "
            repro += "\(shaderLocation)"
            repro += "; vertexDescriptor.attributes[shaderLocation].format = (MTLVertexFormat)"
            repro += "\(UInt32(truncatingIfNeeded: a.format.rawValue))"
            repro += "; vertexDescriptor.attributes[shaderLocation].bufferIndex = "
            repro += "\(a.bufferIndex)"
            repro += "; vertexDescriptor.attributes[shaderLocation].offset = "
            repro += "\(a.offset)"
            repro += ";}\n"
        }
    }

    for i in 0..<8 {
        if let c = descriptor.colorAttachments[i] {
            repro += "{uint32_t i = "
            repro += "\(i)"
            repro += "; MTLRenderPipelineColorAttachmentDescriptor* c = mtlRenderPipelineDescriptor.colorAttachments[i]; c.pixelFormat = (MTLPixelFormat)"
            repro += "\(UInt32(truncatingIfNeeded: c.pixelFormat.rawValue))"
            repro += "; c.blendingEnabled = (BOOL)"
            repro += c.isBlendingEnabled ? "1" : "0"
            repro += "; c.sourceRGBBlendFactor = (MTLBlendFactor)"
            repro += "\(c.sourceRGBBlendFactor.rawValue)"
            repro += "; c.destinationRGBBlendFactor = (MTLBlendFactor)"
            repro += "\(c.destinationRGBBlendFactor.rawValue)"
            repro += "; c.rgbBlendOperation = (MTLBlendOperation)"
            repro += "\(c.rgbBlendOperation.rawValue)"
            repro += "; c.sourceAlphaBlendFactor = (MTLBlendFactor)"
            repro += "\(c.sourceAlphaBlendFactor.rawValue)"
            repro += "; c.destinationAlphaBlendFactor = (MTLBlendFactor)"
            repro += "\(c.destinationAlphaBlendFactor.rawValue)"
            repro += "; c.alphaBlendOperation = (MTLBlendOperation)"
            repro += "\(c.alphaBlendOperation.rawValue)"
            repro += "; c.writeMask = (MTLColorWriteMask)"
            repro += "\(c.writeMask.rawValue)"
            repro += ";}\n"
        }
    }

    repro += psoRenderMakePsoEndAndMain
    psoRepro = repro

    if printToFile {
        printToFileForPsoRepro()
    }

    return true
}

private func clearMetalPSORepro() {
    psoRepro = ""
}

// MARK: The repro case's fixed text


private let psoPreamble =
    #"""

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

    """#

private let psoComputeMainPrefix =
    #"""

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

    """# + "    "

private let psoComputeLibraryAndFunction =
    #"""

        id<MTLLibrary> library = [device newLibraryWithSource:shaderSource options:options error:&error];
        if (!library || error) {
            NSLog(@"Failed to create library");
            return 1;
        }

        // 4. Create a Metal compute function.
        id<MTLFunction> computeFunction = [library newFunctionWithName:

    """# + "    "

private let psoComputePipelineAndMainEnd =
    #"""

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

    """# + "    "

private let psoRenderMakePsoPrefix =
    #"""

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

    """# + "    "

private let psoRenderLibrariesAndFunctionPrefix =
    #"""

        id<MTLLibrary> vertexLibrary = [device newLibraryWithSource:vertexShaderSource options:options error:&error];
        if (error)
            NSLog(@"error compiling vertex shader");

        id<MTLLibrary> fragmentLibrary = [device newLibraryWithSource:fragmentShaderSource options:options error:&error];
        if (error)
            NSLog(@"error compiling fragment shader");

        functionVS = [vertexLibrary newFunctionWithName:@"
    """#

private let psoRenderDescriptorPrefix =
    #"""
    "];

        mtlRenderPipelineDescriptor.vertexFunction = functionVS;
        mtlRenderPipelineDescriptor.fragmentFunction = functionFS;

        mtlRenderPipelineDescriptor.rasterSampleCount =
    """# + " "

private let psoRenderMakePsoEndAndMain =
    #"""
    mtlRenderPipelineDescriptor.vertexDescriptor = vertexDescriptor;
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

    """# + "    "

#endif // WEBGPU_PSO_REPRO
