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

import Synchronization
@_implementationOnly import WebGPU_Internal.BindGroup
@_implementationOnly import WebGPU_Internal.BindGroupLayout
@_implementationOnly import WebGPU_Internal.Buffer
@_implementationOnly import WebGPU_Internal.CommandBuffer
@_implementationOnly import WebGPU_Internal.CommandEncoder
@_implementationOnly import WebGPU_Internal.ComputePassEncoder
@_implementationOnly import WebGPU_Internal.ComputePipeline
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.ExternalTexture
@_implementationOnly import WebGPU_Internal.QuerySet
@_implementationOnly import WebGPU_Internal.RenderPassEncoder
@_implementationOnly import WebGPU_Internal.RenderPipeline
@_implementationOnly import WebGPU_Internal.RenderBundle
@_implementationOnly import WebGPU_Internal.RenderBundleEncoder
@_implementationOnly import WebGPU_Internal.Sampler
@_implementationOnly import WebGPU_Internal.ShaderModule
@_implementationOnly import WebGPU_Internal.Texture
@_implementationOnly import WebGPU_Internal.TextureView
import WebGPU_Private.WebGPUCpp

// The Impls behind the ::WebGPU C++ API objects that the GPU process's Swift receivers are given, until they create
// their objects in Swift.

@_spi(WebKitGPU)
public func impl(of querySet: WebGPU.QuerySet) -> QuerySetImpl {
    ImplLookup.lookUp(QuerySetImpl.self) { WebGPU.Metal.deliverImpl(querySet) }
}

@_spi(WebKitGPU)
public func impl(of bindGroup: WebGPU.BindGroup) -> BindGroupImpl {
    ImplLookup.lookUp(BindGroupImpl.self) { _ = WebGPU.Metal.deliverImpl(bindGroup) }
}

@_spi(WebKitGPU)
public func impl(of externalTexture: WebGPU.ExternalTexture) -> ExternalTextureImpl {
    ImplLookup.lookUp(ExternalTextureImpl.self) { _ = WebGPU.Metal.deliverImpl(externalTexture) }
}

@_spi(WebKitGPU)
public func impl(of sampler: WebGPU.Sampler) -> SamplerImpl {
    ImplLookup.lookUp(SamplerImpl.self) { WebGPU.Metal.deliverImpl(sampler) }
}

@_spi(WebKitGPU)
public func impl(of textureView: WebGPU.TextureView) -> TextureViewImpl {
    ImplLookup.lookUp(TextureViewImpl.self) { _ = WebGPU.Metal.deliverImpl(textureView) }
}

@_spi(WebKitGPU)
public func impl(of bindGroupLayout: WebGPU.BindGroupLayout) -> BindGroupLayoutImpl {
    ImplLookup.lookUp(BindGroupLayoutImpl.self) { WebGPU.Metal.deliverImpl(bindGroupLayout) }
}

@_spi(WebKitGPU)
public func impl(of renderBundle: WebGPU.RenderBundle) -> RenderBundleImpl {
    ImplLookup.lookUp(RenderBundleImpl.self) { _ = WebGPU.Metal.deliverImpl(renderBundle) }
}

@_spi(WebKitGPU)
public func impl(of commandBuffer: WebGPU.CommandBuffer) -> CommandBufferImpl {
    ImplLookup.lookUp(CommandBufferImpl.self) { WebGPU.Metal.deliverImpl(commandBuffer) }
}

@_spi(WebKitGPU)
public func impl(of computePassEncoder: WebGPU.ComputePassEncoder) -> ComputePassEncoderImpl {
    ImplLookup.lookUp(ComputePassEncoderImpl.self) { WebGPU.Metal.deliverImpl(computePassEncoder) }
}

@_spi(WebKitGPU)
public func impl(of renderPassEncoder: WebGPU.RenderPassEncoder) -> RenderPassEncoderImpl {
    ImplLookup.lookUp(RenderPassEncoderImpl.self) { WebGPU.Metal.deliverImpl(renderPassEncoder) }
}

// An Impl with the shell of the same object, for the encoders that keep the shells of the objects they're given, which
// WebKit can't name.

@_spi(WebKitGPU)
public final class BindGroupReference {
    public let impl: BindGroupImpl
    let shell: WebGPU.Metal.BindGroup

    init(_ impl: BindGroupImpl, _ shell: WebGPU.Metal.BindGroup) {
        self.impl = impl
        self.shell = shell
    }
}

@_spi(WebKitGPU)
public func reference(of bindGroup: WebGPU.BindGroup) -> BindGroupReference {
    var shell: WebGPU.Metal.BindGroup?
    let impl = ImplLookup.lookUp(BindGroupImpl.self) { shell = WebGPU.Metal.deliverImpl(bindGroup) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return BindGroupReference(impl, shell)
}

@_spi(WebKitGPU)
public final class ComputePipelineReference {
    public let impl: ComputePipelineImpl
    let shell: WebGPU.Metal.ComputePipeline

    init(_ impl: ComputePipelineImpl, _ shell: WebGPU.Metal.ComputePipeline) {
        self.impl = impl
        self.shell = shell
    }
}

@_spi(WebKitGPU)
public func reference(of computePipeline: WebGPU.ComputePipeline) -> ComputePipelineReference {
    var shell: WebGPU.Metal.ComputePipeline?
    let impl = ImplLookup.lookUp(ComputePipelineImpl.self) { shell = WebGPU.Metal.deliverImpl(computePipeline) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return ComputePipelineReference(impl, shell)
}

@_spi(WebKitGPU)
extension BufferReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-mapasync, as Buffer's shell calls it. `mode` is the bits of
    // OptionSet<WebGPU::MapMode>; nil size: the rest of the buffer after the offset.
    public func mapAsync(_ mode: UInt8, _ offset: UInt64, _ size: UInt64?, _ completion: @escaping (Bool) -> Void) {
        let rangeSize = size ?? (impl.initialSize() > offset ? impl.initialSize() - offset : 0)
        let rangeFits = UInt(exactly: offset) != nil && UInt(exactly: rangeSize) != nil
        impl.mapAsync(shell, mode, rangeFits, rangeFits ? offset : 0, rangeFits ? rangeSize : 0, completion)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-getmappedrange, as Buffer::getMappedRange() reserves the range, but
    // giving a copy of its bytes. No bytes if the range can't be given.
    public func getMappedRange(_ offset: UInt64, _ size: UInt64?) -> [UInt8] {
        let rangeSize = size ?? (impl.initialSize() > offset ? impl.initialSize() - offset : 0)
        guard UInt(exactly: offset) != nil, UInt(exactly: rangeSize) != nil, impl.reserveMappedRange(offset, rangeSize) else {
            return []
        }
        // The reserved range lies within the mapping, so within the contents.
        guard let byteCount = Int(exactly: rangeSize), byteCount > 0 else {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var destination = bytes.mutableSpan
        WebGPU.Metal.readBufferContents(impl.buffer(), offset, &destination)
        return bytes
    }

    // Writes data into the buffer's contents at that offset, as a mapped range of them is written. Returns false,
    // writing nothing, if the contents don't hold it there.
    public func writeContents(_ data: Span<UInt8>, at offset: UInt64) -> Bool {
        WebGPU.Metal.writeBufferContentsIfInBounds(impl.buffer(), offset, data)
    }

    public func unmap() {
        impl.unmap()
    }

    public func destroy() {
        impl.destroy()
    }

    public func setLabel(_ label: Swift.String?) {
        impl.setLabel(WTF.String(label ?? ""))
    }

    // Buffer::generateAValidationError.
    public func generateAValidationError() {
        impl.deviceImpl.generateAValidationError("Buffer state was not unmapped")
    }
}

@_spi(WebKitGPU)
extension ComputePipelineReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpupipelinebase-getbindgrouplayout
    public func getBindGroupLayout(_ groupIndex: UInt32) -> BindGroupLayoutReference {
        impl.bindGroupLayout(groupIndex)
    }
}

@_spi(WebKitGPU)
extension RenderPipelineReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpupipelinebase-getbindgrouplayout
    public func getBindGroupLayout(_ groupIndex: UInt32) -> BindGroupLayoutReference {
        impl.bindGroupLayout(groupIndex)
    }
}

@_spi(WebKitGPU)
public final class BufferReference {
    public let impl: BufferImpl
    let shell: WebGPU.Metal.Buffer

    init(_ impl: BufferImpl, _ shell: WebGPU.Metal.Buffer) {
        self.impl = impl
        self.shell = shell
    }
}

@_spi(WebKitGPU)
public func reference(of buffer: WebGPU.Buffer) -> BufferReference {
    var shell: WebGPU.Metal.Buffer?
    let impl = ImplLookup.lookUp(BufferImpl.self) { shell = WebGPU.Metal.deliverImpl(buffer) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return BufferReference(impl, shell)
}

@_spi(WebKitGPU)
public final class RenderBundleReference {
    public let impl: RenderBundleImpl
    let shell: WebGPU.Metal.RenderBundle

    init(_ impl: RenderBundleImpl, _ shell: WebGPU.Metal.RenderBundle) {
        self.impl = impl
        self.shell = shell
    }
}

@_spi(WebKitGPU)
public func reference(of renderBundle: WebGPU.RenderBundle) -> RenderBundleReference {
    var shell: WebGPU.Metal.RenderBundle?
    let impl = ImplLookup.lookUp(RenderBundleImpl.self) { shell = WebGPU.Metal.deliverImpl(renderBundle) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return RenderBundleReference(impl, shell)
}

@_spi(WebKitGPU)
public final class RenderPipelineReference {
    public let impl: RenderPipelineImpl
    let shell: WebGPU.Metal.RenderPipeline

    init(_ impl: RenderPipelineImpl, _ shell: WebGPU.Metal.RenderPipeline) {
        self.impl = impl
        self.shell = shell
    }
}

@_spi(WebKitGPU)
public func reference(of renderPipeline: WebGPU.RenderPipeline) -> RenderPipelineReference {
    var shell: WebGPU.Metal.RenderPipeline?
    let impl = ImplLookup.lookUp(RenderPipelineImpl.self) { shell = WebGPU.Metal.deliverImpl(renderPipeline) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return RenderPipelineReference(impl, shell)
}

@_spi(WebKitGPU)
public func reference(of renderBundleEncoder: WebGPU.RenderBundleEncoder) -> RenderBundleEncoderReference {
    var shell: WebGPU.Metal.RenderBundleEncoder?
    let impl = ImplLookup.lookUp(RenderBundleEncoderImpl.self) { shell = WebGPU.Metal.deliverImpl(renderBundleEncoder) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return RenderBundleEncoderReference(impl, shell)
}

@_spi(WebKitGPU)
public func reference(of device: WebGPU.Device) -> DeviceReference {
    var shell: WebGPU.Metal.Device?
    let impl = ImplLookup.lookUp(DeviceImpl.self) { shell = WebGPU.Metal.deliverImpl(device) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return DeviceReference(impl, shell)
}

@_spi(WebKitGPU)
public func reference(of texture: WebGPU.Texture) -> TextureReference {
    var shell: WebGPU.Metal.Texture?
    let impl = ImplLookup.lookUp(TextureImpl.self) { shell = WebGPU.Metal.deliverImpl(texture) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return TextureReference(impl, shell)
}

@_spi(WebKitGPU)
public func reference(of textureView: WebGPU.TextureView) -> TextureViewReference {
    var shell: WebGPU.Metal.TextureView?
    let impl = ImplLookup.lookUp(TextureViewImpl.self) { shell = WebGPU.Metal.deliverImpl(textureView) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return TextureViewReference(impl, shell)
}

@_spi(WebKitGPU)
public func reference(of externalTexture: WebGPU.ExternalTexture) -> ExternalTextureReference {
    var shell: WebGPU.Metal.ExternalTexture?
    let impl = ImplLookup.lookUp(ExternalTextureImpl.self) { shell = WebGPU.Metal.deliverImpl(externalTexture) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return ExternalTextureReference(impl, shell)
}

// A WebGPU object that Swift holds, as the GPU process's registry of them keeps it: whether it's valid, as its shell's
// isValid() says.
@_spi(WebKitGPU)
public protocol GPUObjectReference: AnyObject {
    var isValid: Bool { get }
}

@_spi(WebKitGPU)
extension BindGroupLayoutReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension BindGroupReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension BufferReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension CommandEncoderReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension ComputePipelineReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension DeviceReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension ExternalTextureReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension PipelineLayoutReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension QuerySetReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension RenderBundleEncoderReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension RenderBundleReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension RenderPipelineReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension SamplerReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension ShaderModuleReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension TextureReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

@_spi(WebKitGPU)
extension TextureViewReference: GPUObjectReference {
    public var isValid: Bool { shell.isValid() }
}

// The objects as the ::WebGPU C++ API objects they are, for the GPU process's C++.

@_spi(WebKitGPU)
extension BufferReference {
    public var apiObject: WebGPU.Buffer { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension CommandEncoderReference {
    public var apiObject: WebGPU.CommandEncoder { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension DeviceReference {
    public var apiObject: WebGPU.Device { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension ExternalTextureReference {
    public var apiObject: WebGPU.ExternalTexture { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension QuerySetReference {
    public var apiObject: WebGPU.QuerySet { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension ShaderModuleReference {
    public var apiObject: WebGPU.ShaderModule { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension TextureReference {
    public var apiObject: WebGPU.Texture { WebGPU.Metal.apiObject(shell) }
}

// The base class of every Impl that impl(of:) gives, so that C++ delivers all of them through receiveImpl().
@_expose(Cxx)
@_spi(WebKitGPU)
public class DeliverableImpl {
    init() {
    }
}

// `sending` lets ImplLookup box the Impl in a Sendable Delivery. C++ doesn't really hand the Impl over, since its shell
// keeps a reference, but an Impl is only used on its Instance's API thread, and the Delivery is only seen on that thread,
// by the lookUp() whose synchronous call into C++ made this call.
@_expose(Cxx)
func receiveImpl(_ impl: sending DeliverableImpl) {
    ImplLookup.receive(impl)
}

// A C++ shell can't return its Impl to Swift, since a C++ signature that names a Swift class doesn't import into
// Swift, but it can pass it to a Swift function. So lookUp() calls C++ to deliver the Impl to receive(), which puts
// it in a slot that only that call of lookUp() can see.
private enum ImplLookup {
    // Sendable, so that a task-local value can hold it.
    final class Delivery: Sendable {
        private let impl: Mutex<DeliverableImpl?>

        init(_ impl: sending DeliverableImpl) {
            self.impl = Mutex(impl)
        }

        func take() -> DeliverableImpl? {
            impl.withLock { impl -> sending DeliverableImpl? in
                let taken = impl
                impl = nil
                return taken
            }
        }
    }

    final class Slot: Sendable {
        let delivery = Mutex<Delivery?>(nil)
    }

    @TaskLocal private static var slot: Slot?

    static func lookUp<Impl: DeliverableImpl>(_: Impl.Type, _ deliver: () -> Void) -> Impl {
        let slot = Slot()
        $slot.withValue(slot) {
            deliver()
        }
        guard let impl = slot.delivery.withLock({ $0 })?.take() as? Impl else {
            preconditionFailure("C++ delivered no Impl of the expected type")
        }
        return impl
    }

    static func receive(_ impl: sending DeliverableImpl) {
        guard let slot else {
            preconditionFailure("C++ delivered an Impl outside ImplLookup.lookUp()")
        }
        let delivery = Delivery(impl)
        slot.delivery.withLock { stored in
            precondition(stored == nil, "C++ delivered more than one Impl")
            stored = delivery
        }
    }
}
