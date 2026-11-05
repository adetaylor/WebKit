// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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


#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT

@_spi(WebKitGPU) import WebGPUSwift
import WebKit_Internal

// Receives the messages of a WebGPU device, on its stream connection's work queue, and calls its DeviceImpl. The
// objects it makes go in the registry, with their receivers, except for the XR bindings, whose receivers are C++ and
// go in the object heap.
@_expose(Cxx)
final class RemoteDevice {
    private let device: DeviceReference
    private let link: WebGPURegistryLink
    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    private let videoFrames: WebKit.WebGPUSwiftVideoFrames?
    #endif

    @_expose(!Cxx)
    init(_ device: DeviceReference, link: WebGPURegistryLink) {
        self.device = device
        self.link = link
        #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
        videoFrames = link.objects.flatMap { WebKit.WebGPUSwiftVideoFrames.create($0.host) }
        #endif
    }

    deinit {
        // The device can outlive this receiver, so complete the callbacks that reply to the web process.
        device.completeHeldCallbacks()
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteDeviceMessageForwarder {
        WebKit.RemoteDeviceMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func destroy() {
        device.destroy()
    }

    func destruct() {
        link.remove()
    }

    func createXRBinding(identifier: IPCTypes.WebGPUIdentifier) {
        link.objects?.host.addXRBinding(link.identifier, identifier.rawValue)
    }

    func createBuffer(descriptor: IPCTypes.BufferDescriptor, identifier: IPCTypes.WebGPUIdentifier) {
        guard let bufferLink = link.child(identifier) else {
            return
        }
        var bufferDescriptor = GPUBufferDescriptor()
        bufferDescriptor.usage = descriptor.usage.rawValue
        bufferDescriptor.size = descriptor.size
        bufferDescriptor.mappedAtCreation = descriptor.mappedAtCreation
        RemoteBuffer.add(device.createBuffer(bufferDescriptor, label: descriptor.label), mappedAtCreation: descriptor.mappedAtCreation, bufferLink)
    }

    func createTexture(descriptor: IPCTypes.TextureDescriptor, identifier: IPCTypes.WebGPUIdentifier) {
        guard let textureLink = link.child(identifier) else {
            return
        }
        var textureDescriptor = GPUTextureDescriptor()
        textureDescriptor.usage = descriptor.usage.rawValue
        textureDescriptor.dimension = sameNumbering(descriptor.dimension)
        textureDescriptor.size = WebGPU.Extent3D(descriptor.size)
        textureDescriptor.format = sameNumbering(descriptor.format)
        textureDescriptor.mipLevelCount = descriptor.mipLevelCount
        textureDescriptor.sampleCount = descriptor.sampleCount
        textureDescriptor.viewFormats = descriptor.viewFormats.map { sameNumbering($0) }
        RemoteTexture.add(device.createTexture(textureDescriptor, label: descriptor.label), textureLink)
    }

    func createSampler(descriptor: IPCTypes.SamplerDescriptor, identifier: IPCTypes.WebGPUIdentifier) {
        guard let samplerLink = link.child(identifier) else {
            return
        }
        var samplerDescriptor = GPUSamplerDescriptor()
        samplerDescriptor.addressModeU = sameNumbering(descriptor.addressModeU)
        samplerDescriptor.addressModeV = sameNumbering(descriptor.addressModeV)
        samplerDescriptor.addressModeW = sameNumbering(descriptor.addressModeW)
        samplerDescriptor.magFilter = sameNumbering(descriptor.magFilter)
        samplerDescriptor.minFilter = sameNumbering(descriptor.minFilter)
        samplerDescriptor.mipmapFilter = sameNumbering(descriptor.mipmapFilter)
        samplerDescriptor.lodMinClamp = descriptor.lodMinClamp
        samplerDescriptor.lodMaxClamp = descriptor.lodMaxClamp
        samplerDescriptor.compare = descriptor.compare.map { sameNumbering($0) }
        samplerDescriptor.maxAnisotropy = descriptor.maxAnisotropy
        RemoteSampler.add(device.createSampler(samplerDescriptor, label: descriptor.label), samplerLink)
    }

    func createBindGroupLayout(
        descriptor: IPCTypes.BindGroupLayoutDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) {
        guard let layoutLink = link.child(identifier) else {
            return
        }
        let entries = descriptor.entries.map { entry in
            var layoutEntry = GPUBindGroupLayoutEntry()
            layoutEntry.binding = entry.binding
            layoutEntry.visibility = entry.visibility.rawValue
            layoutEntry.buffer = entry.buffer.map { WebGPU.BufferBindingLayout($0) }
            layoutEntry.sampler = entry.sampler.map { WebGPU.SamplerBindingLayout($0) }
            layoutEntry.texture = entry.texture.map { WebGPU.TextureBindingLayout($0) }
            layoutEntry.storageTexture = entry.storageTexture.map { WebGPU.StorageTextureBindingLayout($0) }
            layoutEntry.externalTexture = entry.externalTexture.map { _ in WebGPU.ExternalTextureBindingLayout() }
            return layoutEntry
        }
        RemoteBindGroupLayout.add(device.createBindGroupLayout(entries, label: descriptor.label), layoutLink)
    }

    func createPipelineLayout(
        descriptor: IPCTypes.PipelineLayoutDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let layoutLink = link.child(identifier) else {
            return
        }
        var bindGroupLayouts: [BindGroupLayoutReference]?
        if let identifiers = descriptor.bindGroupLayouts {
            var layouts: [BindGroupLayoutReference] = []
            layouts.reserveCapacity(identifiers.count)
            for layoutIdentifier in identifiers {
                layouts.append(try messageChecked(objects.object(layoutIdentifier, as: BindGroupLayoutReference.self)))
            }
            bindGroupLayouts = layouts
        }
        RemotePipelineLayout.add(device.createPipelineLayout(bindGroupLayouts, label: descriptor.label), layoutLink)
    }

    func createBindGroup(
        descriptor: IPCTypes.BindGroupDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let groupLink = link.child(identifier) else {
            return
        }
        let layout = try messageChecked(objects.object(descriptor.bindGroupLayout, as: BindGroupLayoutReference.self))
        var entries: [GPUBindGroupEntry] = []
        entries.reserveCapacity(descriptor.entries.count)
        for entry in descriptor.entries {
            entries.append(GPUBindGroupEntry(binding: entry.binding, resource: try messageChecked(bindingResource(entry, objects))))
        }
        RemoteBindGroup.add(device.createBindGroup(layout, entries, label: descriptor.label), groupLink)
    }

    private func bindingResource(_ entry: IPCTypes.BindGroupEntry, _ objects: WebGPUImplTable) -> GPUBindingResource? {
        switch entry.type {
        case .sampler:
            objects.object(entry.identifier, as: SamplerReference.self).map { .sampler($0) }
        case .texture:
            objects.object(entry.identifier, as: TextureReference.self).map { .texture($0) }
        case .textureView:
            objects.object(entry.identifier, as: TextureViewReference.self).map { .textureView($0) }
        case .bufferBinding:
            objects.object(entry.bufferBinding.buffer, as: BufferReference.self).map {
                .buffer($0, offset: entry.bufferBinding.offset, size: entry.bufferBinding.size)
            }
        case .externalTexture:
            objects.object(entry.identifier, as: ExternalTextureReference.self).map { .externalTexture($0) }
        }
    }

    func createShaderModule(
        descriptor: IPCTypes.ShaderModuleDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let shaderModuleLink = link.child(identifier) else {
            return
        }
        // WebGPU doesn't use the compilation hints yet, but one naming a layout that doesn't exist makes the message
        // invalid, as converting the descriptor did.
        for hint in descriptor.hints {
            _ = try messageChecked(objects.object(hint.hint.pipelineLayout, as: PipelineLayoutReference.self))
        }
        RemoteShaderModule.add(device.createShaderModule(code: descriptor.code ?? "", label: descriptor.label), shaderModuleLink)
    }

    func createComputePipeline(
        descriptor: IPCTypes.ComputePipelineDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let pipelineLink = link.child(identifier) else {
            return
        }
        let computeDescriptor = try messageChecked(computePipelineDescriptor(descriptor, objects, allowingNoLayout: false))
        RemoteComputePipeline.add(device.createComputePipeline(computeDescriptor, label: descriptor.label), pipelineLink)
    }

    func createComputePipelineWithPipelineLayoutFromPipeline(
        descriptor: IPCTypes.ComputePipelineDescriptor,
        identifier: IPCTypes.WebGPUIdentifier,
        pipelineToReplaceIdentifier: IPCTypes.WebGPUIdentifier,
        reply: consuming RemoteDeviceCreateComputePipelineWithPipelineLayoutFromPipelineReply
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let pipelineLink = link.child(identifier) else {
            return
        }
        let computeDescriptor = try messageChecked(computePipelineDescriptor(descriptor, objects, allowingNoLayout: true))
        let pipelineToReplace = try messageChecked(objects.object(pipelineToReplaceIdentifier, as: ComputePipelineReference.self))
        let pendingReply = CopyableBox(value: reply)
        device.createComputePipelineAsync(computeDescriptor, label: descriptor.label, replacingLayoutOf: pipelineToReplace) { pipeline, success, _ in
            guard let reply = pendingReply.take() else {
                return
            }
            if success {
                RemoteComputePipeline.add(pipeline, pipelineLink)
            }
            reply.send(success)
        }
    }

    func createComputePipelineAsync(
        descriptor: IPCTypes.ComputePipelineDescriptor,
        identifier: IPCTypes.WebGPUIdentifier,
        reply: consuming RemoteDeviceCreateComputePipelineAsyncReply
    ) {
        guard let objects = link.objects, let pipelineLink = link.child(identifier) else {
            return
        }
        guard let computeDescriptor = computePipelineDescriptor(descriptor, objects, allowingNoLayout: false) else {
            reply.send((success: false, error: ""))
            return
        }
        let pendingReply = CopyableBox(value: reply)
        device.createComputePipelineAsync(computeDescriptor, label: descriptor.label) { pipeline, success, message in
            guard let reply = pendingReply.take() else {
                return
            }
            guard success else {
                reply.send((success: false, error: message))
                return
            }
            RemoteComputePipeline.add(pipeline, pipelineLink)
            reply.send((success: true, error: nil))
        }
    }

    func createRenderPipeline(
        descriptor: IPCTypes.RenderPipelineDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let pipelineLink = link.child(identifier) else {
            return
        }
        let renderDescriptor = try messageChecked(renderPipelineDescriptor(descriptor, objects, allowingNoLayout: false))
        RemoteRenderPipeline.add(device.createRenderPipeline(renderDescriptor, label: descriptor.label), pipelineLink)
    }

    func createRenderPipelineWithPipelineLayoutFromPipeline(
        descriptor: IPCTypes.RenderPipelineDescriptor,
        identifier: IPCTypes.WebGPUIdentifier,
        pipelineToReplaceIdentifier: IPCTypes.WebGPUIdentifier,
        reply: consuming RemoteDeviceCreateRenderPipelineWithPipelineLayoutFromPipelineReply
    ) throws(InvalidMessage) {
        guard let objects = link.objects, let pipelineLink = link.child(identifier) else {
            return
        }
        let renderDescriptor = try messageChecked(renderPipelineDescriptor(descriptor, objects, allowingNoLayout: true))
        let pipelineToReplace = try messageChecked(objects.object(pipelineToReplaceIdentifier, as: RenderPipelineReference.self))
        let pendingReply = CopyableBox(value: reply)
        device.createRenderPipelineAsync(renderDescriptor, label: descriptor.label, replacingLayoutOf: pipelineToReplace) { pipeline, success, _ in
            guard let reply = pendingReply.take() else {
                return
            }
            if success {
                RemoteRenderPipeline.add(pipeline, pipelineLink)
            }
            reply.send(success)
        }
    }

    func createRenderPipelineAsync(
        descriptor: IPCTypes.RenderPipelineDescriptor,
        identifier: IPCTypes.WebGPUIdentifier,
        reply: consuming RemoteDeviceCreateRenderPipelineAsyncReply
    ) {
        guard let objects = link.objects, let pipelineLink = link.child(identifier) else {
            return
        }
        guard let renderDescriptor = renderPipelineDescriptor(descriptor, objects, allowingNoLayout: false) else {
            reply.send((success: false, error: ""))
            return
        }
        let pendingReply = CopyableBox(value: reply)
        device.createRenderPipelineAsync(renderDescriptor, label: descriptor.label) { pipeline, success, message in
            guard let reply = pendingReply.take() else {
                return
            }
            guard success else {
                reply.send((success: false, error: message))
                return
            }
            RemoteRenderPipeline.add(pipeline, pipelineLink)
            reply.send((success: true, error: nil))
        }
    }

    func createCommandEncoder(
        descriptor: IPCTypes.CommandEncoderDescriptor?,
        identifier: IPCTypes.WebGPUIdentifier
    ) {
        guard let encoderLink = link.child(identifier) else {
            return
        }
        RemoteCommandEncoder.add(device.createCommandEncoder(label: descriptor?.label), encoderLink)
    }

    func createRenderBundleEncoder(
        descriptor: IPCTypes.RenderBundleEncoderDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) {
        guard let encoderLink = link.child(identifier) else {
            return
        }
        var encoderDescriptor = GPURenderBundleEncoderDescriptor()
        encoderDescriptor.colorFormats = descriptor.colorFormats.map { $0.map { sameNumbering($0) } }
        encoderDescriptor.depthStencilFormat = descriptor.depthStencilFormat.map { sameNumbering($0) }
        encoderDescriptor.sampleCount = descriptor.sampleCount
        encoderDescriptor.depthReadOnly = descriptor.depthReadOnly
        encoderDescriptor.stencilReadOnly = descriptor.stencilReadOnly
        RemoteRenderBundleEncoder.add(device.createRenderBundleEncoder(encoderDescriptor, label: descriptor.label), encoderLink)
    }

    func createQuerySet(descriptor: IPCTypes.QuerySetDescriptor, identifier: IPCTypes.WebGPUIdentifier) {
        guard let querySetLink = link.child(identifier) else {
            return
        }
        var querySetDescriptor = GPUQuerySetDescriptor()
        querySetDescriptor.type = sameNumbering(descriptor.type)
        querySetDescriptor.count = descriptor.count
        RemoteQuerySet.add(device.createQuerySet(querySetDescriptor, label: descriptor.label), querySetLink)
    }

    func pushErrorScope(errorFilter: IPCTypes.ErrorFilter) {
        device.pushErrorScope(sameNumbering(errorFilter))
    }

    func popErrorScope(reply: consuming RemoteDevicePopErrorScopeReply) {
        let pendingReply = CopyableBox(value: reply)
        device.popErrorScope { success, error in
            if let reply = pendingReply.take() {
                reply.send((success: success, error: error.map { IPCTypes.Error($0) }))
            }
        }
    }

    func resolveUncapturedErrorEvent(reply: consuming RemoteDeviceResolveUncapturedErrorEventReply) {
        let pendingReply = CopyableBox(value: reply)
        device.resolveUncapturedErrorEvent { hasUncapturedError, error in
            if let reply = pendingReply.take() {
                reply.send((hasUncapturedError: hasUncapturedError, error: error.map { IPCTypes.Error($0) }))
            }
        }
    }

    func resolveDeviceLostPromise(reply: consuming RemoteDeviceResolveDeviceLostPromiseReply) {
        let pendingReply = CopyableBox(value: reply)
        device.resolveDeviceLostPromise { reason in
            if let reply = pendingReply.take() {
                reply.send(sameNumbering(reason))
            }
        }
    }

    func setLabel(label: String?) {
        device.setLabel(label)
    }

    func pauseAllErrorReporting(pauseErrorReporting: Bool) {
        device.pauseAllErrorReporting(pauseErrorReporting)
    }

    #if WTF_PLATFORM_COCOA && ENABLE_VIDEO
    func setSharedVideoFrameSemaphore(
        semaphore: CxxDecodedArguments.RemoteDevice.SetSharedVideoFrameSemaphoreSemaphore
    ) {
        videoFrames?.setSemaphore(semaphore)
    }

    func setSharedVideoFrameMemory(
        storageHandle: CxxDecodedArguments.RemoteDevice.SetSharedVideoFrameMemoryStorageHandle
    ) {
        videoFrames?.setSharedMemory(storageHandle)
    }

    func importExternalTextureFromVideoFrame(
        descriptor: CxxDecodedArguments.RemoteDevice.ImportExternalTextureFromVideoFrameDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) throws(InvalidMessage) {
        guard let videoFrames, let externalTextureLink = link.child(identifier) else {
            return
        }
        var isInvalid = false
        let externalTextureDescriptor = videoFrames.externalTextureDescriptor(descriptor, &isInvalid)
        try messageCheck {
            !isInvalid
        }
        guard let externalTextureDescriptor = externalTextureDescriptor.value else {
            return
        }
        RemoteExternalTexture.add(device.importExternalTexture(externalTextureDescriptor), externalTextureLink)
    }

    func updateExternalTexture(
        externalTextureIdentifier: IPCTypes.WebGPUIdentifier,
        mediaIdentifier: IPCTypes.MediaPlayerIdentifier
    ) {
        guard let videoFrames, let externalTexture = link.objects?.object(externalTextureIdentifier, as: ExternalTextureReference.self) else {
            return
        }
        externalTexture.destroy()
        guard let frame = videoFrames.mediaPlayerFrame(mediaIdentifier.rawValue).value else {
            return
        }
        externalTexture.update(frame)
    }
    #endif

    // ConvertFromBackingContext's conversion of the descriptors, which finds the objects they name in the registry: nil
    // if one isn't there. Without allowingNoLayout, a descriptor must name a layout.
    private func computePipelineDescriptor(
        _ descriptor: IPCTypes.ComputePipelineDescriptor,
        _ objects: WebGPUImplTable,
        allowingNoLayout: Bool
    ) -> GPUComputePipelineDescriptor? {
        guard let layout = pipelineLayout(descriptor.layout, objects, allowingNoLayout: allowingNoLayout),
            let compute = programmableStage(descriptor.compute.module, descriptor.compute.entryPoint, descriptor.compute.constants, objects)
        else {
            return nil
        }
        return GPUComputePipelineDescriptor(layout: layout, compute: compute)
    }

    private func renderPipelineDescriptor(
        _ descriptor: IPCTypes.RenderPipelineDescriptor,
        _ objects: WebGPUImplTable,
        allowingNoLayout: Bool
    ) -> GPURenderPipelineDescriptor? {
        guard let layout = pipelineLayout(descriptor.layout, objects, allowingNoLayout: allowingNoLayout),
            let vertexStage = programmableStage(descriptor.vertex.module, descriptor.vertex.entryPoint, descriptor.vertex.constants, objects)
        else {
            return nil
        }
        let vertex = GPUVertexState(stage: vertexStage, buffers: descriptor.vertex.buffers.map { $0.map { GPUVertexBufferLayout($0) } })
        var renderDescriptor = GPURenderPipelineDescriptor(layout: layout, vertex: vertex)
        if let primitive = descriptor.primitive {
            renderDescriptor.primitive = GPUPrimitiveState(primitive)
        }
        renderDescriptor.depthStencil = descriptor.depthStencil.map { GPUDepthStencilState($0) }
        if let multisample = descriptor.multisample {
            renderDescriptor.multisample = WebGPU.MultisampleState(multisample)
        }
        if let fragment = descriptor.fragment {
            guard let fragmentStage = programmableStage(fragment.module, fragment.entryPoint, fragment.constants, objects) else {
                return nil
            }
            renderDescriptor.fragment = GPUFragmentState(stage: fragmentStage, targets: fragment.targets.map { $0.map { GPUColorTargetState($0) } })
        }
        return renderDescriptor
    }

    // The layout a pipeline descriptor names: .some(nil) for none, when that's allowed, and nil if it's invalid.
    private func pipelineLayout(
        _ identifier: IPCTypes.WebGPUIdentifier?,
        _ objects: WebGPUImplTable,
        allowingNoLayout: Bool
    ) -> PipelineLayoutReference?? {
        guard let identifier else {
            return allowingNoLayout ? .some(nil) : nil
        }
        guard let layout = objects.object(identifier, as: PipelineLayoutReference.self) else {
            return nil
        }
        return .some(layout)
    }

    private func programmableStage(
        _ module: IPCTypes.WebGPUIdentifier,
        _ entryPoint: String?,
        _ constants: [IPCTypes.PipelineConstant],
        _ objects: WebGPUImplTable
    ) -> GPUProgrammableStage? {
        guard let shaderModule = objects.object(module, as: ShaderModuleReference.self) else {
            return nil
        }
        return GPUProgrammableStage(module: shaderModule, entryPoint: entryPoint, constants: constants.map { (key: $0.key ?? "", value: $0.value) })
    }
}

extension IPCTypes.Error {
    fileprivate init(_ error: GPUError) {
        self.init(type: sameNumbering(error.type), message: error.message)
    }
}

extension WebGPU.BufferBindingLayout {
    fileprivate init(_ layout: IPCTypes.BufferBindingLayout) {
        self.init()
        type = sameNumbering(layout.type)
        hasDynamicOffset = layout.hasDynamicOffset
        minBindingSize = layout.minBindingSize
    }
}

extension WebGPU.SamplerBindingLayout {
    fileprivate init(_ layout: IPCTypes.SamplerBindingLayout) {
        self.init()
        type = sameNumbering(layout.type)
    }
}

extension WebGPU.TextureBindingLayout {
    fileprivate init(_ layout: IPCTypes.TextureBindingLayout) {
        self.init()
        sampleType = sameNumbering(layout.sampleType)
        viewDimension = sameNumbering(layout.viewDimension)
        multisampled = layout.multisampled
    }
}

extension WebGPU.StorageTextureBindingLayout {
    fileprivate init(_ layout: IPCTypes.StorageTextureBindingLayout) {
        self.init()
        access = sameNumbering(layout.access)
        format = sameNumbering(layout.format)
        viewDimension = sameNumbering(layout.viewDimension)
    }
}

extension WebGPU.VertexAttribute {
    fileprivate init(_ attribute: IPCTypes.VertexAttribute) {
        self.init()
        format = sameNumbering(attribute.format)
        offset = attribute.offset
        shaderLocation = attribute.shaderLocation
    }
}

extension WebGPU.BlendComponent {
    fileprivate init(_ component: IPCTypes.BlendComponent) {
        self.init()
        operation = sameNumbering(component.operation)
        srcFactor = sameNumbering(component.srcFactor)
        dstFactor = sameNumbering(component.dstFactor)
    }
}

extension WebGPU.BlendState {
    fileprivate init(_ state: IPCTypes.BlendState) {
        self.init()
        color = WebGPU.BlendComponent(state.color)
        alpha = WebGPU.BlendComponent(state.alpha)
    }
}

extension WebGPU.StencilFaceState {
    fileprivate init(_ state: IPCTypes.StencilFaceState) {
        self.init()
        compare = sameNumbering(state.compare)
        failOp = sameNumbering(state.failOp)
        depthFailOp = sameNumbering(state.depthFailOp)
        passOp = sameNumbering(state.passOp)
    }
}

extension WebGPU.MultisampleState {
    fileprivate init(_ state: IPCTypes.MultisampleState) {
        self.init()
        count = state.count
        mask = state.mask
        alphaToCoverageEnabled = state.alphaToCoverageEnabled
    }
}

extension GPUVertexBufferLayout {
    fileprivate init(_ layout: IPCTypes.VertexBufferLayout) {
        self.init()
        arrayStride = layout.arrayStride
        stepMode = sameNumbering(layout.stepMode)
        attributes = layout.attributes.map { WebGPU.VertexAttribute($0) }
    }
}

extension GPUPrimitiveState {
    fileprivate init(_ state: IPCTypes.PrimitiveState) {
        self.init()
        topology = sameNumbering(state.topology)
        stripIndexFormat = state.stripIndexFormat.map { sameNumbering($0) }
        frontFace = sameNumbering(state.frontFace)
        cullMode = sameNumbering(state.cullMode)
        unclippedDepth = state.unclippedDepth
    }
}

extension GPUDepthStencilState {
    fileprivate init(_ state: IPCTypes.DepthStencilState) {
        self.init()
        format = sameNumbering(state.format)
        depthWriteEnabled = state.depthWriteEnabled
        depthCompare = state.depthCompare.map { sameNumbering($0) }
        stencilFront = WebGPU.StencilFaceState(state.stencilFront)
        stencilBack = WebGPU.StencilFaceState(state.stencilBack)
        stencilReadMask = state.stencilReadMask
        stencilWriteMask = state.stencilWriteMask
        depthBias = state.depthBias
        depthBiasSlopeScale = state.depthBiasSlopeScale
        depthBiasClamp = state.depthBiasClamp
    }
}

extension GPUColorTargetState {
    fileprivate init(_ state: IPCTypes.ColorTargetState) {
        self.init()
        format = sameNumbering(state.format)
        blend = state.blend.map { WebGPU.BlendState($0) }
        writeMask = state.writeMask.rawValue
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
