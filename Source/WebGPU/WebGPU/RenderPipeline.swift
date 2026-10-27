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
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Internal.PipelineLayout
import WebGPU_Internal.PresentationContext
import WebGPU_Internal.RenderPipeline
import WebGPU_Internal.ShaderModule
import WebGPU_Private.WebGPUCpp

private let defaultRenderPipelineSampleMask = UInt32.max

/// A Metal pipeline state compiled on first use.
///
/// A failed compile is kept: later draws report it again without compiling.
private enum PipelineStateCompilation {
    case notCompiled
    case compiled(any MTLRenderPipelineState)
    case failed
}

// One per GPURenderPipeline, owned by the C++ RenderPipeline. Owns all of the pipeline's state, including the Device;
// the render encoders read it directly.
@_expose(Cxx)
final class RenderPipelineImpl {
    // nil == invalid pipeline.
    private let backingRenderPipelineDescriptor: MTLRenderPipelineDescriptor?
    // What render passes draw with: compiled lazily or installed by the async precompile, and replaced by the indirect
    // command buffer variant once that is compiled (icbState), which works in a pass too.
    private var passState = PipelineStateCompilation.notCompiled
    // The variant that supports indirect command buffers, compiled from a copy of the descriptor for render bundles.
    private var icbState = PipelineStateCompilation.notCompiled
    private let backingDepthStencilDescriptor: MTLDepthStencilDescriptor?
    private let backingDepthStencilState: (any MTLDepthStencilState)?
    // Never null: an invalid pipeline carries an invalid-state layout.
    private let backingPipelineLayout: WebGPU.Metal.PipelineLayout
    let pipelineLayoutImpl: PipelineLayoutImpl
    let deviceImpl: DeviceImpl
    let parameters: WebGPU.Metal.RenderPipelineParameters

    // The MTLIndexType of the strip index format.
    let indexType: MTLIndexType?
    // In insertion order (ascending buffer index).
    let requiredVertexBuffers: [RequiredVertexBuffer]
    // requiredVertexBuffers in WTF::HashMap order after inserting the buffer indices in ascending order. Every walk whose
    // first failure picks a message uses this.
    let requiredVertexBuffersInWTFOrder: [RequiredVertexBuffer]
    let primitiveTopology: WebGPU.PrimitiveTopology
    let stripIndexFormat: WebGPU.IndexFormat?
    let colorTargetFormats: [WebGPU.TextureFormat?]
    let depthStencilFormat: WebGPU.TextureFormat?
    let minimumBufferSizes: MinimumBufferSizes
    // Zero or one pipeline, kept alive by this one.
    private var lastStrideAsStridePipelines: [WebGPU.Metal.RenderPipeline] = []
    private var lastStrideAsStrideImpl: RenderPipelineImpl?
    // Declared last, so that the device outlives the rest of the pipeline.
    let device: WebGPU.Metal.Device

    fileprivate init(
        renderPipelineDescriptor: MTLRenderPipelineDescriptor?,
        depthStencilDescriptor: MTLDepthStencilDescriptor?,
        metalDevice: (any MTLDevice)?,
        pipelineLayout: WebGPU.Metal.PipelineLayout,
        pipelineLayoutImpl: PipelineLayoutImpl,
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl,
        parameters: WebGPU.Metal.RenderPipelineParameters,
        indexType: MTLIndexType?,
        requiredVertexBuffers: [RequiredVertexBuffer],
        primitiveTopology: WebGPU.PrimitiveTopology,
        stripIndexFormat: WebGPU.IndexFormat?,
        colorTargetFormats: [WebGPU.TextureFormat?],
        depthStencilFormat: WebGPU.TextureFormat?,
        minimumBufferSizes: MinimumBufferSizes
    ) {
        self.backingRenderPipelineDescriptor = renderPipelineDescriptor
        self.backingDepthStencilDescriptor = depthStencilDescriptor
        self.backingDepthStencilState = depthStencilDescriptor.flatMap { metalDevice?.makeDepthStencilState(descriptor: $0) }
        self.backingPipelineLayout = pipelineLayout
        self.pipelineLayoutImpl = pipelineLayoutImpl
        self.deviceImpl = deviceImpl
        self.parameters = parameters
        self.indexType = indexType
        self.requiredVertexBuffers = requiredVertexBuffers
        self.requiredVertexBuffersInWTFOrder = inWTFHashTableOrder(requiredVertexBuffers)
        self.primitiveTopology = primitiveTopology
        self.stripIndexFormat = stripIndexFormat
        self.colorTargetFormats = colorTargetFormats
        self.depthStencilFormat = depthStencilFormat
        self.minimumBufferSizes = minimumBufferSizes
        self.device = device
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        backingRenderPipelineDescriptor != nil && pipelineLayoutImpl.isValid()
    }

    func cachedRenderPipelineState() -> (any MTLRenderPipelineState)? {
        if case .compiled(let state) = passState {
            return state
        }
        return nil
    }

    // Like the pass state, but the state must support indirect command buffers. The compile works on a copy of the
    // descriptor: a failure leaves the state render passes draw with as it was. nil after a failed compile, now or
    // earlier; the caller reports it each time. The Metal device is passed per call because Device drops its MTLDevice
    // when it is lost.
    func icbRenderPipelineState(_ metalDevice: (any MTLDevice)?) -> (any MTLRenderPipelineState)? {
        switch icbState {
        case .compiled(let state):
            return state
        case .failed:
            return nil
        case .notCompiled:
            break
        }
        if case .compiled(let state) = passState, backingRenderPipelineDescriptor?.supportIndirectCommandBuffers == true {
            icbState = .compiled(state)
            return state
        }
        guard let icbDescriptor = backingRenderPipelineDescriptor?.copy() as? MTLRenderPipelineDescriptor else {
            icbState = .failed
            return nil
        }
        icbDescriptor.supportIndirectCommandBuffers = true
        guard let state = try? metalDevice?.makeRenderPipelineState(descriptor: icbDescriptor) else {
            icbState = .failed
            return nil
        }
        backingRenderPipelineDescriptor?.supportIndirectCommandBuffers = true
        icbState = .compiled(state)
        passState = .compiled(state)
        return state
    }

    // Reports a failed compile on the pipeline's device on every call; nothing compiles after the first failure.
    func compiledRenderPipelineState() -> (any MTLRenderPipelineState)? {
        switch passState {
        case .compiled(let state):
            return state
        case .failed:
            break
        case .notCompiled:
            if let state = compile(deviceImpl.device()) {
                passState = .compiled(state)
                return state
            }
            passState = .failed
        }
        deviceImpl.generateAnOutOfMemoryError("Render pipeline failed compilation likely due to being too complex, please reduce its size")
        return nil
    }

    // RenderPipeline::getBindGroupLayout. The shell adopts the +1 result.
    @_expose(Cxx)
    func getBindGroupLayout(_ groupIndex: UInt32) -> WebGPU.Metal.BindGroupLayout {
        pipelineBindGroupLayout(
            device,
            deviceImpl,
            pipelineIsValid: isValid(),
            invalidPipelineMessage: "getBindGroupLayout: RenderPipeline is invalid",
            pipelineLayoutImpl,
            groupIndex
        )
    }

    // A failed precompile is not kept: the first draw compiles again.
    @_expose(!Cxx)
    func setPrecompiledRenderPipelineState(_ state: (any MTLRenderPipelineState)?) {
        guard case .notCompiled = passState else {
            assertionFailure("the pipeline state was compiled before its precompile finished")
            return
        }
        if let state {
            passState = .compiled(state)
        }
    }

    private func compile(_ metalDevice: (any MTLDevice)?) -> (any MTLRenderPipelineState)? {
        guard let descriptor = backingRenderPipelineDescriptor else {
            return nil
        }
        return try? metalDevice?.makeRenderPipelineState(descriptor: descriptor)
    }

    func depthStencilDescriptor() -> MTLDepthStencilDescriptor? {
        backingDepthStencilDescriptor
    }

    func depthStencilState() -> (any MTLDepthStencilState)? {
        backingDepthStencilState
    }

    func writesDepth() -> Bool {
        backingDepthStencilDescriptor?.isDepthWriteEnabled ?? false
    }

    @_expose(Cxx)
    func pipelineLayout() -> WebGPU.Metal.PipelineLayout {
        backingPipelineLayout
    }

    func sampleMask() -> UInt32 {
        parameters.sampleMask
    }

    // The same pipeline, with each required vertex buffer's stride replaced by its last stride. It shares this
    // pipeline's layout, depth-stencil descriptor, parameters and unique id.
    private func makeLastStrideAsStrideImpl(_ metalDevice: (any MTLDevice)?) -> RenderPipelineImpl {
        let clonedRenderPipelineDescriptor = backingRenderPipelineDescriptor?.copy() as? MTLRenderPipelineDescriptor
        var buffers = requiredVertexBuffers
        if let vertexDescriptor = clonedRenderPipelineDescriptor?.vertexDescriptor {
            for i in buffers.indices {
                vertexDescriptor.layouts[Int(buffers[i].bufferIndex)].stride = Int(truncatingIfNeeded: buffers[i].lastStride)
                buffers[i].stride = buffers[i].lastStride
            }
        }
        return RenderPipelineImpl(
            renderPipelineDescriptor: clonedRenderPipelineDescriptor,
            depthStencilDescriptor: backingDepthStencilDescriptor,
            metalDevice: metalDevice,
            pipelineLayout: backingPipelineLayout,
            pipelineLayoutImpl: pipelineLayoutImpl,
            device: device,
            deviceImpl: deviceImpl,
            parameters: parameters,
            indexType: indexType,
            requiredVertexBuffers: buffers,
            primitiveTopology: primitiveTopology,
            stripIndexFormat: stripIndexFormat,
            colorTargetFormats: colorTargetFormats,
            depthStencilFormat: depthStencilFormat,
            minimumBufferSizes: minimumBufferSizes
        )
    }

    /// The last-stride-as-stride pipeline, made on first use and kept alive by this pipeline.
    ///
    /// The new shell is made through DeviceImpl.stagedRenderPipelineImpl.
    @_expose(!Cxx)
    func lastStrideAsStride() -> (pipeline: WebGPU.Metal.RenderPipeline, impl: RenderPipelineImpl) {
        if let impl = lastStrideAsStrideImpl, !lastStrideAsStridePipelines.isEmpty {
            return (lastStrideAsStridePipelines[0], impl)
        }
        let impl = makeLastStrideAsStrideImpl(deviceImpl.device())
        precondition(deviceImpl.stagedRenderPipelineImpl == nil)
        deviceImpl.stagedRenderPipelineImpl = impl
        let pipeline = WebGPU.Metal.RenderPipeline.createWithStagedImpl(device).ptr()
        lastStrideAsStridePipelines = [pipeline]
        lastStrideAsStrideImpl = impl
        return (pipeline, impl)
    }

    @_expose(!Cxx)
    func validateDepthStencilState(depthReadOnly: Bool, stencilReadOnly: Bool) -> Bool {
        if depthReadOnly && writesDepth() {
            return false
        }
        if stencilReadOnly && parameters.writesStencil {
            return false
        }
        return true
    }

    @_expose(!Cxx)
    func errorValidatingColorDepthStencilTargets(_ attachments: borrowing PassAttachments) -> String? {
        let sampleCount = parameters.sampleCount
        let colorAttachmentCount = attachments.colorViewIndices.count
        if !parameters.hasFragment {
            if colorAttachmentCount != 0 {
                return "No fragment shader but render pass has color attachments"
            }
        } else {
            let colorTargetCount = colorTargetFormats.count
            for index in 0..<max(colorTargetCount, colorAttachmentCount) {
                let attachmentView = index < colorAttachmentCount ? attachments.colorTarget(index) : nil
                let descriptorTargetFormat = index < colorTargetCount ? colorTargetFormats[index] : nil
                guard let attachmentView else {
                    guard let descriptorTargetFormat else {
                        continue
                    }
                    return "No attachment view but descriptorTargetFormat(\(formatName(descriptorTargetFormat)))"
                }
                if descriptorTargetFormat != attachmentView.format {
                    return
                        "descriptorTargetFormat(\(descriptorTargetFormat.map(formatName) ?? "undefined")) != attachmentView->format(\(formatName(attachmentView.format)))"
                }
                if attachmentView.sampleCount != sampleCount {
                    return "attachmentView->sampleCount(\(attachmentView.sampleCount)) != m_sampleCount(\(sampleCount))"
                }
            }
        }

        guard let pipelineDepthStencilFormat = depthStencilFormat else {
            if !attachments.hasDepthStencil {
                return nil
            }
            return "depthStencil is missing but render pass has a depth stencil attachment"
        }

        guard attachments.hasDepthStencil else {
            return "m_depthStencilFormat(\(formatName(pipelineDepthStencilFormat))) but render pass has no depth stencil attachment"
        }
        guard let texture = attachments.depthStencilTarget else {
            return "depthStencilAttachment exists but no depthStencilView"
        }
        if texture.format != pipelineDepthStencilFormat {
            return "texture.format(\(formatName(texture.format))) != m_depthStencilFormat(\(formatName(pipelineDepthStencilFormat)))"
        }
        // A message to a nil texture returns 0, MTLPixelFormatInvalid.
        let mtlPixelFormat = attachments.depthStencilView?.metalTexture?.pixelFormat ?? .invalid
        if mtlPixelFormat == .x32_stencil8 && pipelineDepthStencilFormat == .Stencil8 {
            return "mtlPixelFormat == MTLPixelFormatX32_Stencil8 && descriptorFormat == WebGPU::TextureFormat::Stencil8"
        }
        if mtlPixelFormat == .depth32Float_stencil8
            && (pipelineDepthStencilFormat == .Depth32float || pipelineDepthStencilFormat == .Depth24plus)
        {
            return
                "mtlPixelFormat == MTLPixelFormatDepth32Float_Stencil8 && (descriptorFormat == WebGPU::TextureFormat::Depth32float || descriptorFormat == WebGPU::TextureFormat::Depth24plus)"
        }
        if texture.sampleCount != sampleCount {
            return "texture.sampleCount(\(texture.sampleCount)) != m_sampleCount(\(sampleCount))"
        }
        return nil
    }

    @_expose(!Cxx)
    func validateRenderBundle(
        depthReadOnly: Bool,
        stencilReadOnly: Bool,
        sampleCount: UInt32,
        colorFormats: [WebGPU.TextureFormat?],
        depthStencilFormat bundleDepthStencilFormat: WebGPU.TextureFormat?
    ) -> Bool {
        if !validateDepthStencilState(depthReadOnly: depthReadOnly, stencilReadOnly: stencilReadOnly) {
            return false
        }

        if sampleCount != parameters.sampleCount {
            return false
        }

        let colorTargetCount = colorTargetFormats.count
        for index in 0..<max(colorTargetCount, colorFormats.count) {
            let colorFormat = index < colorFormats.count ? colorFormats[index] : nil
            let descriptorFormat = index < colorTargetCount ? colorTargetFormats[index] : nil
            if descriptorFormat != colorFormat {
                return false
            }
        }

        guard let depthStencilFormat else {
            return bundleDepthStencilFormat == nil
        }
        return bundleDepthStencilFormat == depthStencilFormat
    }
}

@_expose(Cxx)
func makeInvalidRenderPipelineImpl(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ pipelineLayout: WebGPU.Metal.PipelineLayout,
    _ pipelineLayoutImpl: PipelineLayoutImpl
) -> RenderPipelineImpl {
    var parameters = WebGPU.Metal.RenderPipelineParameters()
    parameters.sampleMask = UInt32.max
    return RenderPipelineImpl(
        renderPipelineDescriptor: nil,
        depthStencilDescriptor: nil,
        metalDevice: nil,
        pipelineLayout: pipelineLayout,
        pipelineLayoutImpl: pipelineLayoutImpl,
        device: device,
        deviceImpl: deviceImpl,
        parameters: parameters,
        indexType: nil,
        requiredVertexBuffers: [],
        primitiveTopology: WebGPU.PrimitiveTopology.TriangleList,
        stripIndexFormat: nil,
        colorTargetFormats: [],
        depthStencilFormat: nil,
        minimumBufferSizes: MinimumBufferSizes()
    )
}

// Device::createRenderPipeline and its asynchronous forms. C++ resolves the descriptor's shader modules and layout
// (from pipelineToReplace or the descriptor), which Swift cannot downcast, and sets them with their Impls.
@_expose(Cxx)
final class RenderPipelineBuilder {
    private let device: WebGPU.Metal.Device
    private let deviceImpl: DeviceImpl
    private let vertexModule: WebGPU.Metal.ShaderModule
    private let vertexModuleImpl: ShaderModuleImpl
    // Zero-or-one FRTs as arrays, never Optional<FRT>.
    private var fragmentModule: [WebGPU.Metal.ShaderModule] = []
    private var fragmentModuleImpl: ShaderModuleImpl?
    private var layout: [WebGPU.Metal.PipelineLayout] = []
    private var layoutImpl: PipelineLayoutImpl?
    private var isReplacingPipeline = false

    fileprivate init(
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl,
        vertexModule: WebGPU.Metal.ShaderModule,
        vertexModuleImpl: ShaderModuleImpl
    ) {
        self.device = device
        self.deviceImpl = deviceImpl
        self.vertexModule = vertexModule
        self.vertexModuleImpl = vertexModuleImpl
    }

    @_expose(Cxx)
    func setFragmentModule(_ module: WebGPU.Metal.ShaderModule, _ impl: ShaderModuleImpl) {
        fragmentModule = [module]
        fragmentModuleImpl = impl
    }

    @_expose(Cxx)
    func setPipelineLayout(_ layout: WebGPU.Metal.PipelineLayout, _ impl: PipelineLayoutImpl, _ isReplacingPipeline: Bool) {
        self.layout = [layout]
        self.layoutImpl = impl
        self.isReplacingPipeline = isReplacingPipeline
    }

    /// The synchronous createRenderPipeline: the pipeline, +1.
    @_expose(Cxx)
    func create(_ descriptor: borrowing WebGPU.RenderPipelineDescriptor) -> WebGPU.Metal.RenderPipeline {
        var result: [WebGPU.Metal.RenderPipeline] = []
        create(descriptor, isAsync: false, .synchronous) { pipeline, _ in
            result = [pipeline]
        }
        // A synchronous creation never defers its completion.
        precondition(result.count == 1)
        return result[0]
    }

    /// createRenderPipelineAsync, and createRenderPipelineWithPipelineLayoutFromPipelineAsync (a replacing builder).
    ///
    /// A replacing builder pauses error reporting while it runs. Takes the callback, leaving `callback` empty.
    @_expose(Cxx)
    func createAsync(
        _ descriptor: borrowing WebGPU.RenderPipelineDescriptor,
        _ callback: inout WebGPU.Metal.CreateRenderPipelineAsyncCallback
    ) {
        let completion = RenderPipelineAsyncCompletion(
            device,
            deviceImpl,
            exchange(&callback, with: WebGPU.Metal.CreateRenderPipelineAsyncCallback())
        )
        let wasErrorReportingPaused = isReplacingPipeline ? deviceImpl.pauseErrorReporting(true) : nil
        create(descriptor, isAsync: true, asynchronousIfPossible()) { pipeline, message in
            completion.complete(pipeline, message)
        }
        if let wasErrorReportingPaused {
            _ = deviceImpl.pauseErrorReporting(wasErrorReportingPaused)
        }
    }

    // `report` gets the pipeline (an invalid one on failure, with the message the asynchronous forms resolve with) on
    // the API thread: before this returns when every compile is synchronous. The pipeline exists before its shaders
    // compile: it only holds on to the MTLRenderPipelineDescriptor, which attachFunctions completes, and its pipeline
    // state is precompiled (asynchronously) or compiled on demand once Metal is done with the MSL. Everything that reads
    // `descriptor` happens in prepare(), before that.
    private func create(
        _ descriptor: borrowing WebGPU.RenderPipelineDescriptor,
        isAsync: Bool,
        _ compilation: LibraryCompilation,
        _ report: @escaping (WebGPU.Metal.RenderPipeline, String?) -> Void
    ) {
        let device = self.device
        let deviceImpl = self.deviceImpl
        // The synchronous form reports the error itself.
        let fail = { (message: String) in
            if !isAsync {
                deviceImpl.generateAValidationError(message)
            }
            report(WebGPU.Metal.RenderPipeline.createInvalid(device).ptr(), message)
        }

        let renderPipelineDescriptor = MTLRenderPipelineDescriptor()
        setRenderShaderValidation(renderPipelineDescriptor)
        precondition(renderPipelineDescriptor.responds(to: Selector(("setSampleMask:"))))

        let pending = prepare(descriptor, renderPipelineDescriptor)
        if let error = pending.backingErrorMessage {
            return fail(error)
        }
        let impl = pending.takeImpl()
        deviceImpl.stagedRenderPipelineImpl = impl
        let pipeline = WebGPU.Metal.RenderPipeline.createWithStagedImpl(device).ptr()
        let vertexLibrary = pending.vertexLibrary()
        let fragmentLibrary = pending.fragment

        let suppressErrors = deviceImpl.isErrorReportingPaused()
        let finishCreation = { (vertex: (any MTLLibrary)?, fragment: (any MTLLibrary)?, libraryError: NSError?) in
            withErrorReporting(deviceImpl, suppressingErrors: suppressErrors) {
                if let error = pending.attachFunctions(vertex, fragment, libraryError) {
                    return fail(error)
                }
                let renderPipelineDescriptor = pending.renderPipelineDescriptor()
                if WebGPU.Metal.psoLoggingIsEnabled() {
                    let shaderLocations = ContiguousArray(pending.shaderLocations)
                    let error = WebGPU.Metal.reproduceRenderPipelineState(
                        deviceImpl.device(),
                        deviceImpl.deviceLimits().maxVertexBuffers,
                        renderPipelineDescriptor,
                        vertexLibrary.metalSource,
                        fragmentLibrary?.metalSource ?? WTF.String(),
                        shaderLocations.span
                    )
                    if !error.isNull() {
                        return fail(CxxBridging.convertWTFStringToNSString(error).map { $0 as String } ?? "")
                    }
                }

                guard let scheduler = asynchronousCompileScheduler(compilation, device, deviceImpl) else {
                    return report(pipeline, nil)
                }
                // Compile the pipeline state now rather than leaving it to the first draw. This is only an
                // optimization: nothing here can invalidate the pipeline, and if the compile fails the lazy
                // RenderPipelineImpl.compiledRenderPipelineState path still runs, and reports the failure, at first use.
                precompileRenderPipelineState(renderPipelineDescriptor, deviceImpl.device(), scheduler) { renderPipelineState in
                    if let renderPipelineState {
                        impl.setPrecompiledRenderPipelineState(renderPipelineState)
                    }
                    report(pipeline, nil)
                }
            }
        }

        // Compile the fragment MSL once the vertex MSL is done. The two stages of one pipeline are serialized, but
        // independent pipelines still compile concurrently, which is the point.
        compileLibrary(vertexLibrary, device, deviceImpl, compilation) { vertex, vertexError in
            guard let vertex, let fragmentLibrary else {
                return finishCreation(vertex, nil, vertexError)
            }
            compileLibrary(fragmentLibrary, device, deviceImpl, compilation) { fragment, fragmentError in
                finishCreation(vertex, fragment, fragmentError)
            }
        }
    }

    // `renderPipelineDescriptor` is new and empty apart from the shader validation set on it.
    private func prepare(
        _ descriptor: borrowing WebGPU.RenderPipelineDescriptor,
        _ renderPipelineDescriptor: MTLRenderPipelineDescriptor
    ) -> PendingRenderPipeline {
        let limits = deviceImpl.capabilities.limits
        let hasFragment = WebGPU.Metal.renderPipelineHasFragment(descriptor)
        let colorTargets: Span<WebGPU.Metal.OptionalColorTargetState> = WebGPU.Metal.renderPipelineColorTargets(descriptor)
        let colorTargetCount = colorTargets.count

        // FIXME: Implement this according to the description in
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpurenderpipelinedescriptor
        if (hasFragment && UInt64(colorTargetCount) > UInt64(limits.maxColorAttachments)) || !deviceImpl.isValid() {
            return PendingRenderPipeline(errorMessage: "device or descriptor is not valid")
        }

        // createNSString() semantics: an empty or null label is @"", not nil.
        let label = (CxxBridging.convertWTFStringToNSString(descriptor.label) ?? "") as NSString

        // The pipeline stores and validates with the C API enums.
        let primitiveTopology = descriptor.primitive.topology
        let stripIndexFormat = Optional(fromCxx: descriptor.primitive.stripIndexFormat)

        var explicitLayout: [WebGPU.Metal.PipelineLayout] = []
        var explicitLayoutImpl: PipelineLayoutImpl?
        if let layoutImpl, !layout.isEmpty {
            // isValidToUseWithDevice(layout, device) of IsValidToUseWith.h.
            // With the same device, the layout's device validity is deviceImpl.isValid().
            if !layoutImpl.isValid() || !CxxBridging.areDevicesEqual(layoutImpl.device, device) || !deviceImpl.isValid() {
                return PendingRenderPipeline(errorMessage: "Pipeline layout is not valid or created from different device")
            }
            if isReplacingPipeline || !layoutImpl.isAutoLayout() {
                explicitLayout = layout
                explicitLayoutImpl = layoutImpl
            }
        }

        if !vertexModuleImpl.isValid() {
            return PendingRenderPipeline(errorMessage: "Vertex module is not valid")
        }
        if vertexModuleImpl.deviceImpl !== deviceImpl {
            return PendingRenderPipeline(errorMessage: "Vertex module was created with a different device")
        }

        let vertexEntryPoint = wgslName(descriptor.vertex.stage.entryPoint) ?? vertexModuleImpl.defaultVertexEntryPoint
        let vertexReflection = vertexModuleImpl.reflection(forEntryPoint: vertexEntryPoint)
        let vertexStageIn = vertexReflection?.stageIn
        if let error = errorValidatingVertexStageIn(vertexStageIn, limits) {
            return PendingRenderPipeline(errorMessage: error)
        }

        var minimumBufferSizes = MinimumBufferSizes()
        var bindGroupEntries: [[ResolvedLayoutEntry]] = []
        let vertexLibrary: PreparedLibrary
        switch prepareLibrary(
            vertexModuleImpl,
            layout: explicitLayoutImpl,
            entryPoint: vertexEntryPoint,
            label: label,
            constants: pipelineConstants(descriptor.vertex.stage),
            deviceImpl: deviceImpl,
            minimumBufferSizes: &minimumBufferSizes
        ) {
        case .success(let library):
            vertexLibrary = library
        case .failure(let error):
            return PendingRenderPipeline(errorMessage: error.message ?? "Vertex library failed creation")
        }

        // Truncated, not clamped.
        let vertexShaderBindingCount = UInt32(truncatingIfNeeded: vertexLibrary.entryPoint.bindingCount)
        if explicitLayoutImpl == nil {
            if let error = appendDefaultLayout(&bindGroupEntries, from: vertexLibrary.entryPoint.defaultLayout, limits: limits) {
                return PendingRenderPipeline(errorMessage: error)
            }
        }
        if vertexLibrary.entryPoint.specializationConstants.count != vertexLibrary.resolvedOverrides.count {
            return PendingRenderPipeline(errorMessage: "Vertex function could not be created")
        }
        let vertexOutputs = vertexReflection?.vertexOutputs
        let vertexClipDistancesCount = vertexReflection?.clipDistancesCount ?? 0

        var usesFragDepth = false
        var usesSampleMask = false
        var colorAttachmentCount: UInt32 = 0
        var fragmentEntryPoint: Name?
        var fragmentReflection: EntryPointReflection?
        if hasFragment {
            guard let fragmentModuleImpl, !fragmentModule.isEmpty else {
                preconditionFailure("C++ sets the fragment module of a descriptor with a fragment state")
            }
            if !fragmentModuleImpl.isValid() {
                return PendingRenderPipeline(errorMessage: "Fragment module is invalid")
            }
            if fragmentModuleImpl.deviceImpl !== deviceImpl {
                return PendingRenderPipeline(errorMessage: "Fragment module was created with a different device")
            }

            fragmentEntryPoint =
                wgslName(WebGPU.Metal.renderPipelineFragmentEntryPoint(descriptor)) ?? fragmentModuleImpl.defaultFragmentEntryPoint
            fragmentReflection = fragmentModuleImpl.reflection(forEntryPoint: fragmentEntryPoint)
            usesFragDepth = fragmentReflection?.usesFragDepth ?? false
            usesSampleMask = fragmentReflection?.usesSampleMaskInOutput ?? false
            colorAttachmentCount = UInt32(truncatingIfNeeded: colorTargetCount)
        }

        if let error = errorValidatingInterstageShaderInterfaces(
            limits,
            primitiveTopology,
            vertexOutputs: vertexOutputs,
            vertexClipDistancesCount: vertexClipDistancesCount,
            hasFragmentModule: hasFragment,
            fragment: fragmentReflection
        ) {
            return PendingRenderPipeline(errorMessage: error)
        }

        var hasAtLeastOneColorTarget = false
        var fragmentLibrary: PreparedLibrary?
        if hasFragment, let fragmentModuleImpl {
            var bytesPerSample: UInt32 = 0
            for i in 0..<colorTargetCount {
                guard let target = Optional(fromCxx: colorTargets[i]) else {
                    continue
                }
                hasAtLeastOneColorTarget = true
                if let error = errorConfiguringColorTarget(target, i, renderPipelineDescriptor, fragmentReflection, &bytesPerSample) {
                    return PendingRenderPipeline(errorMessage: error)
                }
            }

            if bytesPerSample > limits.maxColorAttachmentBytesPerSample {
                return PendingRenderPipeline(
                    errorMessage:
                        "Bytes per sample(\(bytesPerSample)) exceeded maximum allowed limit(\(limits.maxColorAttachmentBytesPerSample))"
                )
            }

            let library: PreparedLibrary
            switch prepareLibrary(
                fragmentModuleImpl,
                layout: explicitLayoutImpl,
                entryPoint: fragmentEntryPoint,
                label: label,
                constants: fragmentPipelineConstants(descriptor),
                deviceImpl: deviceImpl,
                minimumBufferSizes: &minimumBufferSizes
            ) {
            case .success(let preparedLibrary):
                library = preparedLibrary
            case .failure(let error):
                return PendingRenderPipeline(errorMessage: error.message ?? "Fragment library could not be created")
            }

            if explicitLayoutImpl == nil {
                if let error = appendDefaultLayout(&bindGroupEntries, from: library.entryPoint.defaultLayout, limits: limits) {
                    return PendingRenderPipeline(errorMessage: error)
                }
            }
            if library.entryPoint.specializationConstants.count != library.resolvedOverrides.count {
                return PendingRenderPipeline(errorMessage: "Fragment function failed creation")
            }
            fragmentLibrary = library
        }

        var depthStencilDescriptor: MTLDepthStencilDescriptor?
        var depthBias: Float = 0
        var depthBiasSlopeScale: Float = 0
        var depthBiasClamp: Float = 0
        let depthStencil = Optional(fromCxx: descriptor.depthStencil)
        if let depthStencil {
            if let error = errorValidatingDepthStencilState(depthStencil) {
                return PendingRenderPipeline(errorMessage: error)
            }

            let depthStencilFormat = texturePixelFormat(depthStencil.format)
            renderPipelineDescriptor.depthAttachmentPixelFormat =
                isStencilOnlyFormat(depthStencilFormat) ? MTLPixelFormat.invalid : depthStencilFormat
            if stencilOnlyAspectMetalFormat(depthStencil.format) != nil {
                renderPipelineDescriptor.stencilAttachmentPixelFormat = depthStencilFormat
            }

            let newDepthStencilDescriptor = MTLDepthStencilDescriptor()
            newDepthStencilDescriptor.depthCompareFunction =
                Optional(fromCxx: depthStencil.depthCompare).map { mtlCompareFunction($0) } ?? MTLCompareFunction.always
            newDepthStencilDescriptor.isDepthWriteEnabled = Optional(fromCxx: depthStencil.depthWriteEnabled) ?? false
            populateStencilOperation(
                newDepthStencilDescriptor.frontFaceStencil,
                depthStencil.stencilFront,
                depthStencil.stencilReadMask,
                depthStencil.stencilWriteMask
            )
            populateStencilOperation(
                newDepthStencilDescriptor.backFaceStencil,
                depthStencil.stencilBack,
                depthStencil.stencilReadMask,
                depthStencil.stencilWriteMask
            )
            depthStencilDescriptor = newDepthStencilDescriptor
            depthBias = Float(depthStencil.depthBias)
            depthBiasSlopeScale = depthStencil.depthBiasSlopeScale
            depthBiasClamp = depthStencil.depthBiasClamp

            // Depth bias is derived from the slope of the primitive being rasterized, which only points
            // and lines lack, so for those topologies it has to be left at zero.
            if primitiveTopology != WebGPU.PrimitiveTopology.TriangleList && primitiveTopology != WebGPU.PrimitiveTopology.TriangleStrip {
                if depthBias != 0 || depthBiasSlopeScale != 0 || depthBiasClamp != 0 {
                    return PendingRenderPipeline(
                        errorMessage:
                            "depthBias, depthBiasSlopeScale, and depthBiasClamp must be 0 unless primitive.topology is a triangle topology"
                    )
                }
            }
        }

        // A render pipeline needs somewhere to render to. hasAtLeastOneColorTarget can only be set from
        // the fragment state's targets, so a vertex-only pipeline has to bring its own depth-stencil.
        if !hasAtLeastOneColorTarget && depthStencil == nil {
            return PendingRenderPipeline(errorMessage: "No color targets or depth stencil were specified in the descriptor")
        }
        if usesFragDepth && renderPipelineDescriptor.depthAttachmentPixelFormat == MTLPixelFormat.invalid {
            return PendingRenderPipeline(errorMessage: "Shader writes to frag depth but no depth texture set")
        }

        let multisample = descriptor.multisample
        if multisample.count != 1 && multisample.count != 4 {
            return PendingRenderPipeline(errorMessage: "multisample count must be either 1 or 4")
        }
        renderPipelineDescriptor.rasterSampleCount = Int(multisample.count)
        renderPipelineDescriptor.isAlphaToCoverageEnabled = multisample.alphaToCoverageEnabled
        if multisample.alphaToCoverageEnabled {
            if usesSampleMask {
                return PendingRenderPipeline(errorMessage: "Can not use sampleMask with alphaToCoverage")
            }
            if !hasFragment {
                return PendingRenderPipeline(errorMessage: "Using alphaToCoverage requires a fragment state")
            }
            let firstTarget = colorTargetCount == 0 ? nil : Optional(fromCxx: colorTargets[0])
            guard let firstTarget, hasAlphaChannel(firstTarget.format), supportsBlending(firstTarget.format, device) else {
                return PendingRenderPipeline(errorMessage: "Using alphaToCoverage requires a fragment state")
            }
            if multisample.count == 1 {
                return PendingRenderPipeline(errorMessage: "Using alphaToCoverage requires multisampling")
            }
        }

        var sampleMask = defaultRenderPipelineSampleMask
        if multisample.mask != sampleMask {
            if !usesSampleMask {
                WebGPU.Metal.setRenderPipelineSampleMask(renderPipelineDescriptor, multisample.mask)
            }
            sampleMask = multisample.mask
        }

        var requiredVertexBuffers: [RequiredVertexBuffer] = []
        var shaderLocations: [UInt32] = []
        let vertexBufferCount = WebGPU.Metal.renderPipelineVertexBufferCount(descriptor)
        if vertexBufferCount != 0 {
            guard let vertexStageIn else {
                let attributes: Span<WebGPU.VertexAttribute> = WebGPU.Metal.renderPipelineVertexAttributes(descriptor, 0)
                let attributeCount = attributes.count
                return PendingRenderPipeline(
                    errorMessage:
                        "Vertex shader has no stageIn parameters but buffer count was \(vertexBufferCount) and attribute count was \(attributeCount)"
                )
            }
            let vertexDescriptor = MTLVertexDescriptor()
            if let error = errorCreatingVertexDescriptor(
                descriptor,
                vertexDescriptor,
                vertexBufferCount,
                limits,
                vertexStageIn,
                &requiredVertexBuffers,
                &shaderLocations
            ) {
                return PendingRenderPipeline(errorMessage: "vertex descriptor creation failed \(error)")
            }
            renderPipelineDescriptor.vertexDescriptor = vertexDescriptor
        }

        if let vertexStageIn, !vertexStageIn.isEmpty, vertexBufferCount == 0 {
            return PendingRenderPipeline(
                errorMessage: "Vertex descriptor passed zero buffers for stage_in but shader requires buffers for stage_in"
            )
        }

        var depthClipMode = MTLDepthClipMode.clip
        if descriptor.primitive.unclippedDepth {
            if !deviceImpl.hasFeature(WebGPU.FeatureName.DepthClipControl) {
                return PendingRenderPipeline(errorMessage: "unclippedDepth used without enabling depth-clip-control feature")
            }
            depthClipMode = MTLDepthClipMode.clamp
        }

        renderPipelineDescriptor.inputPrimitiveTopology = mtlPrimitiveTopologyClass(primitiveTopology)

        // These properties are to be used by the render command encoder, not the render pipeline.
        // Therefore, the render pipeline stores these, and when the render command encoder is assigned
        // a pipeline, the render command encoder can get these information out of the render pipeline.
        if primitiveTopology != WebGPU.PrimitiveTopology.LineStrip && primitiveTopology != WebGPU.PrimitiveTopology.TriangleStrip {
            if stripIndexFormat != nil {
                return PendingRenderPipeline(
                    errorMessage: "If primitive.topology is not line-strip or triangle-strip, primitive.stripIndexFormat must be undefined."
                )
            }
        }

        if deviceImpl.pipelineIdsExhausted() {
            deviceImpl.loseTheDevice(WebGPU.DeviceLostReason.Unknown)
            return PendingRenderPipeline(errorMessage: "too many render pipelines")
        }

        let finalLayout: WebGPU.Metal.PipelineLayout
        let finalLayoutImpl: PipelineLayoutImpl
        if let explicitLayoutImpl, !explicitLayout.isEmpty {
            finalLayout = explicitLayout[0]
            finalLayoutImpl = explicitLayoutImpl
        } else {
            let generated = makeGeneratedPipelineLayout(device: device, deviceImpl: deviceImpl, entries: bindGroupEntries)
            if !generated.impl.isValid() {
                return PendingRenderPipeline(errorMessage: "Generated pipeline layout is not valid")
            }
            finalLayout = generated.shell
            finalLayoutImpl = generated.impl
        }

        var colorTargetFormats: [WebGPU.TextureFormat?] = []
        for i in 0..<colorTargetCount {
            colorTargetFormats.append(Optional(fromCxx: colorTargets[i])?.format)
        }

        var parameters = WebGPU.Metal.RenderPipelineParameters()
        parameters.primitiveType = mtlPrimitiveType(primitiveTopology)
        parameters.frontFace = mtlWinding(descriptor.primitive.frontFace)
        parameters.cullMode = mtlCullMode(descriptor.primitive.cullMode)
        parameters.depthClipMode = depthClipMode
        parameters.depthBias = depthBias
        parameters.depthBiasSlopeScale = depthBiasSlopeScale
        parameters.depthBiasClamp = depthBiasClamp
        parameters.sampleMask = sampleMask
        parameters.colorAttachmentCount = colorAttachmentCount
        parameters.sampleCount = multisample.count
        parameters.vertexShaderBindingCount = vertexShaderBindingCount
        parameters.uniqueId = deviceImpl.takePipelineId()
        parameters.hasFragment = hasFragment
        parameters.writesStencil = writesStencil(depthStencil, descriptor.primitive.cullMode)

        let impl = RenderPipelineImpl(
            renderPipelineDescriptor: renderPipelineDescriptor,
            depthStencilDescriptor: depthStencilDescriptor,
            metalDevice: deviceImpl.device(),
            pipelineLayout: finalLayout,
            pipelineLayoutImpl: finalLayoutImpl,
            device: device,
            deviceImpl: deviceImpl,
            parameters: parameters,
            indexType: stripIndexFormat.flatMap { mtlIndexType($0) },
            requiredVertexBuffers: requiredVertexBuffers,
            primitiveTopology: primitiveTopology,
            stripIndexFormat: stripIndexFormat,
            colorTargetFormats: colorTargetFormats,
            depthStencilFormat: depthStencil?.format,
            minimumBufferSizes: minimumBufferSizes
        )
        return PendingRenderPipeline(
            impl: impl,
            vertexLibrary: vertexLibrary,
            fragmentLibrary: fragmentLibrary,
            renderPipelineDescriptor: renderPipelineDescriptor,
            label: label,
            shaderLocations: shaderLocations
        )
    }

    // One color target of the fragment state; `index` is its slot.
    private func errorConfiguringColorTarget(
        _ target: WebGPU.ColorTargetState,
        _ index: Int,
        _ renderPipelineDescriptor: MTLRenderPipelineDescriptor,
        _ fragment: EntryPointReflection?,
        _ bytesPerSample: inout UInt32
    ) -> String? {
        let targetFormat = target.format
        let writeMask = target.writeMask.toRaw()
        let fragmentFunctionReturnType = fragment?.fragmentOutputType(at: UInt32(truncatingIfNeeded: index)) ?? MTLDataType.none
        // swift-format-ignore: NeverForceUnwrap
        let mtlColorAttachment = renderPipelineDescriptor.colorAttachments[index]!

        if isDepthOrStencilFormat(targetFormat) || !isRenderableFormat(targetFormat, device) {
            return "Depth / stencil format passed to color format"
        }

        // Wraps in UInt32.
        let alignment = UInt64(renderTargetPixelByteAlignment(targetFormat))
        let remainder = alignment == 0 ? UInt64(bytesPerSample) : UInt64(bytesPerSample) % alignment
        if remainder != 0 {
            bytesPerSample = bytesPerSample &+ UInt32(truncatingIfNeeded: alignment &- remainder)
        }
        bytesPerSample = bytesPerSample &+ renderTargetPixelByteCost(targetFormat)
        mtlColorAttachment.pixelFormat = texturePixelFormat(targetFormat)

        if writeMask & WebGPU.ColorWrite.Invalid.rawValue != 0 {
            return "writeMask is invalid"
        }
        if fragmentFunctionReturnType == MTLDataType.none && writeMask != 0 {
            return "writeMask is invalid"
        }
        mtlColorAttachment.writeMask = mtlColorWriteMask(rawWriteMask: UInt32(writeMask))

        var readsAlpha = false
        if let blend = Optional(fromCxx: target.blend) {
            if !supportsBlending(targetFormat, device) {
                return "Color target attempted to use blending on non-blendable format"
            }
            mtlColorAttachment.isBlendingEnabled = true

            let alphaBlend = blend.alpha
            let colorBlend = blend.color
            func isValidBlend(_ component: WebGPU.BlendComponent) -> Bool {
                if component.operation == WebGPU.BlendOperation.Min || component.operation == WebGPU.BlendOperation.Max {
                    return component.srcFactor == WebGPU.BlendFactor.One && component.dstFactor == WebGPU.BlendFactor.One
                }
                return true
            }
            if !isValidBlend(alphaBlend) || !isValidBlend(colorBlend) {
                return "Blend states are not valid"
            }
            mtlColorAttachment.alphaBlendOperation = mtlBlendOperation(alphaBlend.operation)
            mtlColorAttachment.sourceAlphaBlendFactor = mtlBlendFactor(alphaBlend.srcFactor)
            mtlColorAttachment.destinationAlphaBlendFactor = mtlBlendFactor(alphaBlend.dstFactor)

            mtlColorAttachment.rgbBlendOperation = mtlBlendOperation(colorBlend.operation)
            mtlColorAttachment.sourceRGBBlendFactor = mtlBlendFactor(colorBlend.srcFactor)
            mtlColorAttachment.destinationRGBBlendFactor = mtlBlendFactor(colorBlend.dstFactor)
            func readsAlphaFactor(_ factor: WebGPU.BlendFactor) -> Bool {
                factor == WebGPU.BlendFactor.SrcAlpha || factor == WebGPU.BlendFactor.OneMinusSrcAlpha
                    || factor == WebGPU.BlendFactor.SrcAlphaSaturated
            }
            readsAlpha = readsAlphaFactor(colorBlend.srcFactor) || readsAlphaFactor(colorBlend.dstFactor)
        } else {
            mtlColorAttachment.isBlendingEnabled = false
        }

        if !textureFormatAllowedForReturnType(targetFormat, dataType: fragmentFunctionReturnType, readsAlpha: readsAlpha) {
            // The index and the pixel format are swapped in this message.
            return
                "pipeline creation - color target pixel format(\(index)) for location(\(mtlColorAttachment.pixelFormat.rawValue)) is incompatible with shader output data type of \(fragmentFunctionReturnType.rawValue)"
        }
        return nil
    }
}

@_expose(Cxx)
func makeRenderPipelineBuilder(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ vertexModule: WebGPU.Metal.ShaderModule,
    _ vertexModuleImpl: ShaderModuleImpl
) -> RenderPipelineBuilder {
    RenderPipelineBuilder(device: device, deviceImpl: deviceImpl, vertexModule: vertexModule, vertexModuleImpl: vertexModuleImpl)
}

// RenderPipelineBuilder.prepare's result.
private final class PendingRenderPipeline {
    // nil when the pipeline was built.
    let backingErrorMessage: String?
    private var impl: RenderPipelineImpl?
    private let vertex: PreparedLibrary?
    let fragment: PreparedLibrary?
    private let descriptor: MTLRenderPipelineDescriptor?
    private let label: NSString?
    // The descriptor's attribute locations, for the PSO repro dump.
    let shaderLocations: [UInt32]

    init(errorMessage: String) {
        self.backingErrorMessage = errorMessage
        self.impl = nil
        self.vertex = nil
        self.fragment = nil
        self.descriptor = nil
        self.label = nil
        self.shaderLocations = []
    }

    init(
        impl: RenderPipelineImpl,
        vertexLibrary: PreparedLibrary,
        fragmentLibrary: PreparedLibrary?,
        renderPipelineDescriptor: MTLRenderPipelineDescriptor,
        label: NSString?,
        shaderLocations: [UInt32]
    ) {
        self.backingErrorMessage = nil
        self.impl = impl
        self.vertex = vertexLibrary
        self.fragment = fragmentLibrary
        self.descriptor = renderPipelineDescriptor
        self.label = label
        self.shaderLocations = shaderLocations
    }

    func takeImpl() -> RenderPipelineImpl {
        guard let impl else {
            preconditionFailure("takeImpl() on a failed or already taken PendingRenderPipeline")
        }
        self.impl = nil
        return impl
    }

    func vertexLibrary() -> PreparedLibrary {
        guard let vertex else {
            preconditionFailure("vertexLibrary() on a failed PendingRenderPipeline")
        }
        return vertex
    }

    func renderPipelineDescriptor() -> MTLRenderPipelineDescriptor {
        guard let descriptor else {
            preconditionFailure("renderPipelineDescriptor() on a failed PendingRenderPipeline")
        }
        return descriptor
    }

    // finishCreation's library and function checks. nil: the functions are attached to the descriptor.
    func attachFunctions(_ vertexLibrary: (any MTLLibrary)?, _ fragmentLibrary: (any MTLLibrary)?, _ libraryError: NSError?) -> String? {
        guard let descriptor, let vertex else {
            preconditionFailure("attachFunctions() on a failed PendingRenderPipeline")
        }

        guard let vertexLibrary else {
            return libraryError?.localizedDescription ?? "Vertex library failed creation"
        }
        let vertexFunction: (any MTLFunction)? = createFunction(vertexLibrary, vertex.mangledName() as String, label as String?)
        guard let vertexFunction, vertexFunction.functionType == .vertex else {
            return "Vertex function could not be created"
        }
        descriptor.vertexFunction = vertexFunction

        if let fragment {
            guard let fragmentLibrary else {
                return libraryError?.localizedDescription ?? "Fragment library could not be created"
            }
            let fragmentFunction: (any MTLFunction)? = createFunction(fragmentLibrary, fragment.mangledName() as String, label as String?)
            guard let fragmentFunction, fragmentFunction.functionType == .fragment else {
                return "Fragment function failed creation"
            }
            descriptor.fragmentFunction = fragmentFunction
        }
        return nil
    }
}

/// Resolves the embedder's callback on a later turn of the API thread, never re-entrantly from the creation (at once
/// when the device has no Instance).
private final class RenderPipelineAsyncCompletion {
    private let device: WebGPU.Metal.Device
    private let deviceImpl: DeviceImpl
    private var callback: WebGPU.Metal.CreateRenderPipelineAsyncCallback

    init(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, _ callback: consuming WebGPU.Metal.CreateRenderPipelineAsyncCallback) {
        self.device = device
        self.deviceImpl = deviceImpl
        self.callback = callback
    }

    func complete(_ pipeline: WebGPU.Metal.RenderPipeline, _ message: String?) {
        guard let instance = CxxBridging.protectedInstance(device) else {
            return resolve(pipeline, message)
        }
        instance.scheduleWork(
            consuming: WebGPU.Metal.Instance.WorkItem {
                self.resolve(pipeline, message)
            }
        )
    }

    private func resolve(_ pipeline: WebGPU.Metal.RenderPipeline, _ message: String?) {
        var callback = exchange(&self.callback, with: WebGPU.Metal.CreateRenderPipelineAsyncCallback())
        // A lost device makes invalid objects without errors.
        WebGPU.Metal.callCreateRenderPipelineAsyncCallback(&callback, pipeline, deviceImpl.isDestroyed() || pipeline.isValid(), message)
    }
}

// The locations are in WTF::HashMap order, which decides the location an error names.
private func errorValidatingVertexStageIn(_ stageIn: [StageInLocation]?, _ limits: WebGPU.Limits) -> String? {
    guard let stageIn else {
        return nil
    }

    let maxVertexAttributeLocation = limits.maxVertexAttributes
    var shaderLocations = Set<UInt32>()
    for entry in stageIn {
        if entry.location >= maxVertexAttributeLocation {
            return "Shader location \(entry.location) exceeds the maximum allowed value of \(maxVertexAttributeLocation)"
        }
        if shaderLocations.contains(entry.location) {
            return "Shader location \(entry.location) appears twice"
        }
        shaderLocations.insert(entry.location)
    }
    return nil
}

// The UInt32 arithmetic wraps.
private func errorValidatingInterstageShaderInterfaces(
    _ limits: WebGPU.Limits,
    _ primitiveTopology: WebGPU.PrimitiveTopology,
    vertexOutputs: [InterStageVariable]?,
    vertexClipDistancesCount: UInt32,
    hasFragmentModule: Bool,
    fragment: EntryPointReflection?
) -> String? {
    guard let vertexOutputs else {
        return "vertex shader has no outputs"
    }

    let componentsPerVariable: UInt32 = 4
    let componentsPerVariableMinusOne = componentsPerVariable - 1
    var maxVertexShaderOutputComponents = limits.maxInterStageShaderVariables &* componentsPerVariable
    if primitiveTopology == WebGPU.PrimitiveTopology.PointList {
        if maxVertexShaderOutputComponents == 0 {
            return "maxVertexShaderOutputComponents is zero"
        }
        maxVertexShaderOutputComponents &-= componentsPerVariable
    }

    // Per spec: if clip_distances is declared, decrement maxVertexShaderOutputComponents by clipDistancesSize
    if vertexClipDistancesCount != 0 {
        if maxVertexShaderOutputComponents < vertexClipDistancesCount {
            return "clip_distances requires more components than available"
        }
        maxVertexShaderOutputComponents &-=
            ((vertexClipDistancesCount &+ componentsPerVariableMinusOne) / componentsPerVariable) &* componentsPerVariable
    }

    var maxInterStageShaderVariables = limits.maxInterStageShaderVariables

    // Per spec: if clip_distances is declared, decrement maxVertexShaderOutputLocation by ceil(clipDistancesSize / 4)
    if vertexClipDistancesCount != 0 {
        let clipDistancesVec4Count = (vertexClipDistancesCount &+ componentsPerVariableMinusOne) / componentsPerVariable
        if maxInterStageShaderVariables < clipDistancesVec4Count {
            return "clip_distances requires more location slots than available"
        }
        maxInterStageShaderVariables &-= clipDistancesVec4Count
    }
    var vertexScalarComponents: UInt32 = 0
    for output in vertexOutputs {
        if output.location >= maxInterStageShaderVariables {
            return "location >= maxInterStageShaderVariables"
        }
        vertexScalarComponents &+= componentsForDataType(output.dataType)
    }

    if vertexScalarComponents > maxVertexShaderOutputComponents {
        return "vertexScalarComponents > maxVertexShaderOutputComponents"
    }

    guard hasFragmentModule else {
        return nil
    }

    var maxFragmentShaderInputComponents = limits.maxInterStageShaderVariables &* componentsPerVariable
    func decrementByVariable() -> Bool {
        if maxFragmentShaderInputComponents < componentsPerVariable {
            return false
        }
        maxFragmentShaderInputComponents -= componentsPerVariable
        return true
    }
    if fragment?.usesFrontFacingInInput == true && !decrementByVariable() {
        return "maxFragmentShaderInputComponents is less than zero due to front facing"
    }
    if fragment?.usesSampleIndexInInput == true && !decrementByVariable() {
        return "maxFragmentShaderInputComponents is less than zero due to sample index"
    }
    if fragment?.usesSampleMaskInInput == true && !decrementByVariable() {
        return "maxFragmentShaderInputComponents is less than zero due to sample mask"
    }
    if fragment?.usesPrimitiveIndexInInput == true && !decrementByVariable() {
        return "maxFragmentShaderInputComponents is less than zero due to primitive index"
    }
    if fragment?.usesSubgroupInvocationIdInInput == true && !decrementByVariable() {
        return "maxFragmentShaderInputComponents is less than zero due to subgroup invocation id"
    }
    if fragment?.usesSubgroupSizeInInput == true && !decrementByVariable() {
        return "maxFragmentShaderInputComponents is less than zero due to subgroup size"
    }

    // Both lists are in WTF::HashMap order, which decides the first failure.
    if let fragmentInputs = fragment?.fragmentInputs {
        let defaultInterpolation = Interpolation(type: .perspective, sampling: .center)
        var fragmentScalarComponents: UInt32 = 0
        for input in fragmentInputs {
            guard let output = vertexOutputs.first(where: { $0.location == input.location }), output.dataType == input.dataType else {
                return "data type between fragment inputs and vertex outputs do not match"
            }

            fragmentScalarComponents &+= componentsForDataType(input.dataType)
            if (input.interpolation ?? defaultInterpolation) != (output.interpolation ?? defaultInterpolation) {
                return "interpolation attributes do not match"
            }
        }
        if fragmentScalarComponents > maxFragmentShaderInputComponents {
            return
                "fragmentScalarComponents(\(fragmentScalarComponents)) > maxFragmentShaderInputComponents(\(maxFragmentShaderInputComponents))"
        }
    }

    if let fragmentOutputs = fragment?.fragmentOutputs {
        let maxColorAttachments = limits.maxColorAttachments
        for output in fragmentOutputs where output.location >= maxColorAttachments {
            return "location(\(output.location)) >= maxColorAttachments(\(maxColorAttachments))"
        }
    }

    return nil
}

private func errorValidatingDepthStencilState(_ depthStencil: WebGPU.DepthStencilState) -> String? {
    func error(_ message: String) -> String {
        "Invalid DepthStencilState: \(message)"
    }

    let format = depthStencil.format
    if !isDepthOrStencilFormat(format) {
        return error("Color format passed to depth / stencil format")
    }

    let hasDepthFormat = depthOnlyAspectMetalFormat(format) != nil
    let depthWriteEnabled = Optional(fromCxx: depthStencil.depthWriteEnabled)
    let depthCompare = Optional(fromCxx: depthStencil.depthCompare)
    if (depthWriteEnabled ?? false) || (depthCompare != nil && depthCompare != WebGPU.CompareFunction.Always) {
        if !hasDepthFormat {
            return error("depth-stencil state missing format")
        }
    }

    func isDefault(_ face: WebGPU.StencilFaceState) -> Bool {
        face.compare == WebGPU.CompareFunction.Always && face.failOp == WebGPU.StencilOperation.Keep
            && face.depthFailOp == WebGPU.StencilOperation.Keep && face.passOp == WebGPU.StencilOperation.Keep
    }
    let front = depthStencil.stencilFront
    let back = depthStencil.stencilBack
    if !isDefault(front) || !isDefault(back) {
        if stencilOnlyAspectMetalFormat(format) == nil {
            return error(
                "missing stencil format - stencilFront: compare = \(compareFunctionName(front.compare)), failOp = \(stencilOperationName(front.failOp)), depthFailOp = \(stencilOperationName(front.depthFailOp)), passOp = \(stencilOperationName(front.passOp)), stencilBack: compare = \(compareFunctionName(back.compare)), failOp = \(stencilOperationName(back.failOp)), depthFailOp = \(stencilOperationName(back.depthFailOp)), passOp = \(stencilOperationName(back.passOp))"
            )
        }
    }

    if hasDepthFormat {
        guard let depthWriteEnabled else {
            return error("depthWrite must be provided")
        }

        if depthWriteEnabled || front.depthFailOp != WebGPU.StencilOperation.Keep || back.depthFailOp != WebGPU.StencilOperation.Keep {
            if depthCompare == nil {
                return error("Depth compare must be provided")
            }
        }
    }
    return nil
}

private func populateStencilOperation(
    _ mtlStencil: MTLStencilDescriptor,
    _ stencil: WebGPU.StencilFaceState,
    _ stencilReadMask: UInt32,
    _ stencilWriteMask: UInt32
) {
    mtlStencil.stencilCompareFunction = mtlCompareFunction(stencil.compare)
    mtlStencil.stencilFailureOperation = mtlStencilOperation(stencil.failOp)
    mtlStencil.depthFailureOperation = mtlStencilOperation(stencil.depthFailOp)
    mtlStencil.depthStencilPassOperation = mtlStencilOperation(stencil.passOp)
    mtlStencil.writeMask = stencilWriteMask
    mtlStencil.readMask = stencilReadMask
}

private func writesStencil(_ depthStencil: WebGPU.DepthStencilState?, _ cullMode: WebGPU.CullMode) -> Bool {
    guard let depthStencil, depthStencil.stencilWriteMask != 0 else {
        return false
    }
    let keep = WebGPU.StencilOperation.Keep
    let front = depthStencil.stencilFront
    let back = depthStencil.stencilBack
    if cullMode != WebGPU.CullMode.Front && (front.passOp != keep || front.depthFailOp != keep || front.failOp != keep) {
        return true
    }
    if cullMode != WebGPU.CullMode.Back && (back.passOp != keep || back.depthFailOp != keep || back.failOp != keep) {
        return true
    }
    return false
}

// Fills `vertexDescriptor`, the required vertex buffers (ascending buffer index) and the attribute locations in
// descriptor order. Returns the error message, or nil.
private func errorCreatingVertexDescriptor(
    _ descriptor: borrowing WebGPU.RenderPipelineDescriptor,
    _ vertexDescriptor: MTLVertexDescriptor,
    _ bufferCount: Int,
    _ limits: WebGPU.Limits,
    _ stageIn: [StageInLocation],
    _ requiredVertexBuffers: inout [RequiredVertexBuffer],
    _ shaderLocations: inout [UInt32]
) -> String? {
    if UInt64(bufferCount) > UInt64(limits.maxVertexBuffers) {
        return "vertexBuffer count(\(bufferCount)) exceeds limit(\(limits.maxVertexBuffers))"
    }

    var totalAttributeCount: UInt32 = 0
    var formatForShaderLocation: [UInt32: WebGPU.VertexFormat] = [:]
    for bufferIndex in 0..<bufferCount {
        guard let buffer = Optional(fromCxx: WebGPU.Metal.renderPipelineVertexBuffer(descriptor, bufferIndex)) else {
            continue
        }

        let arrayStride = buffer.arrayStride
        if arrayStride > UInt64(limits.maxVertexBufferArrayStride) || arrayStride % 4 != 0 {
            return
                "buffer.arrayStride(\(arrayStride)) > limits.maxVertexBufferArrayStride(\(limits.maxVertexBufferArrayStride)) || (buffer.arrayStride \(arrayStride))"
        }

        let attributes: Span<WebGPU.VertexAttribute> = WebGPU.Metal.renderPipelineVertexAttributes(descriptor, bufferIndex)
        let attributeCount = attributes.count
        if attributeCount == 0 {
            continue
        }

        // Also fails when the count itself does not fit in UInt32.
        let (newTotalAttributeCount, overflowed) = totalAttributeCount.addingReportingOverflow(UInt32(truncatingIfNeeded: attributeCount))
        if overflowed || UInt64(attributeCount) > UInt64(UInt32.max) {
            return "Over 2^32 - 1 attributes in the vertex descriptor, failing due to out-of-memory."
        }
        totalAttributeCount = newTotalAttributeCount

        let stride = max(UInt64(4), arrayStride)
        var lastStride: UInt64 = 0
        // swift-format-ignore: NeverForceUnwrap
        let layout = vertexDescriptor.layouts[bufferIndex]!
        layout.stride = Int(truncatingIfNeeded: stride)
        let stepMode = buffer.stepMode
        layout.stepFunction = mtlVertexStepFunction(stepMode, arrayStride: arrayStride)
        if layout.stepFunction == MTLVertexStepFunction.constant {
            layout.stepRate = 0
        }
        for attributeIndex in attributes.indices {
            let attribute = attributes[attributeIndex]
            let attributeFormat = attribute.format
            let formatSize = UInt64(vertexFormatSize(attributeFormat))
            let (offsetPlusFormatSize, offsetOverflowed) = attribute.offset.addingReportingOverflow(formatSize)
            if offsetOverflowed {
                return "attribute.offset + formatSize > uint64::max()"
            }
            lastStride = max(lastStride, offsetPlusFormatSize)
            if arrayStride == 0 {
                if offsetPlusFormatSize > UInt64(limits.maxVertexBufferArrayStride) {
                    return "attribute.offset + formatSize > limits.maxVertexBufferArrayStride"
                }
            } else if offsetPlusFormatSize > arrayStride {
                return "attribute.offset(\(attribute.offset)) + formatSize(\(formatSize)) > buffer.arrayStride(\(arrayStride))"
            }

            let alignment = min(UInt64(4), formatSize)
            if attribute.offset % alignment != 0 {
                return "attribute.offset(\(attribute.offset)) mod std::min<size_t>(4, formatSize)(\(alignment)) is not zero"
            }

            let shaderLocation = attribute.shaderLocation
            let isDuplicate = formatForShaderLocation[shaderLocation] != nil
            if shaderLocation >= limits.maxVertexAttributes || isDuplicate {
                return
                    "shaderLocation(\(shaderLocation)) >= limits.maxVertexAttributes(\(limits.maxVertexAttributes)) || shaderLocations.contains(shaderLocation) \(isDuplicate ? 1 : 0)"
            }

            formatForShaderLocation[shaderLocation] = attributeFormat
            shaderLocations.append(shaderLocation)
            // swift-format-ignore: NeverForceUnwrap
            let mtlAttribute = vertexDescriptor.attributes[Int(shaderLocation)]!
            mtlAttribute.format = mtlVertexFormat(attributeFormat)
            mtlAttribute.bufferIndex = bufferIndex
            mtlAttribute.offset = Int(truncatingIfNeeded: attribute.offset)
        }

        requiredVertexBuffers.append(
            RequiredVertexBuffer(
                bufferIndex: UInt32(truncatingIfNeeded: bufferIndex),
                stride: arrayStride,
                lastStride: lastStride,
                stepMode: stepMode
            )
        )
    }

    // In WTF::HashMap order, which decides the first mismatch. The message prints the shader's format as both `format`
    // and `otherFormat`.
    for entry in stageIn {
        let formatSize = vertexFormatSize(entry.format)
        let matchesFormat = formatForShaderLocation[entry.location].map { vertexFormatType($0) == vertexFormatType(entry.format) } ?? false
        if !matchesFormat {
            let name = vertexFormatName(entry.format)
            return
                "!matchesFormat(attribute(\(Int32(bitPattern: entry.location))), format(\(name)), size(\(formatSize)), otherFormat(\(name))"
        }
    }

    if totalAttributeCount > limits.maxVertexAttributes {
        return "totalAttributeCount > limits.maxVertexAttributes"
    }
    return nil
}

private func fragmentPipelineConstants(_ descriptor: borrowing WebGPU.RenderPipelineDescriptor) -> [PipelineConstant] {
    let constants: Span<WebGPU.ConstantEntry> = WebGPU.Metal.renderPipelineFragmentConstants(descriptor)
    return pipelineConstants(constants)
}

private func formatName(_ format: WebGPU.TextureFormat) -> String {
    textureFormatName(format)
}

// The order a WTF::HashMap<uint32_t, ...> iterates after adding the buffers' indices in array order.
private func inWTFHashTableOrder(_ buffers: [RequiredVertexBuffer]) -> [RequiredVertexBuffer] {
    if buffers.count < 2 {
        return buffers
    }
    var order = WTFHashMap<UInt32, Int>()
    for (position, buffer) in buffers.enumerated() {
        order.add(buffer.bufferIndex) { position }
    }
    var result: [RequiredVertexBuffer] = []
    result.reserveCapacity(buffers.count)
    order.forEachInWTFOrder { _, position in
        result.append(buffers[position])
    }
    return result
}
