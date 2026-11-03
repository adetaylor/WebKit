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
@_implementationOnly import WebGPU_Internal.Adapter
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
@_implementationOnly import WebGPU_Internal.Queue
@_implementationOnly import WebGPU_Internal.RenderPassEncoder
@_implementationOnly import WebGPU_Internal.RenderPipeline
@_implementationOnly import WebGPU_Internal.RenderBundle
@_implementationOnly import WebGPU_Internal.RenderBundleEncoder
@_implementationOnly import WebGPU_Internal.Sampler
@_implementationOnly import WebGPU_Internal.ShaderModule
@_implementationOnly import WebGPU_Internal.Texture
@_implementationOnly import WebGPU_Internal.TextureView
import WebGPU_Private.WebGPUCpp

// The Impls behind the ::WebGPU C++ API objects that C++ still makes for the GPU process's Swift receivers: the
// adapter's devices, the textures of presentation contexts and XR, WebCore's external textures, and the passes, whose
// descriptors C++ converts.

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
public final class ComputePipelineReference {
    public let impl: ComputePipelineImpl
    let shell: WebGPU.Metal.ComputePipeline

    init(_ impl: ComputePipelineImpl, _ shell: WebGPU.Metal.ComputePipeline) {
        self.impl = impl
        self.shell = shell
    }
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
public final class RenderBundleReference {
    public let impl: RenderBundleImpl
    let shell: WebGPU.Metal.RenderBundle

    init(_ impl: RenderBundleImpl, _ shell: WebGPU.Metal.RenderBundle) {
        self.impl = impl
        self.shell = shell
    }
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
public func reference(of adapter: WebGPU.Adapter) -> AdapterReference {
    var shell: WebGPU.Metal.Adapter?
    let impl = ImplLookup.lookUp(AdapterImpl.self) { shell = WebGPU.Metal.deliverImpl(adapter) }
    guard let shell else {
        preconditionFailure("C++ delivered no shell")
    }
    return AdapterReference(impl, shell)
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

// A compute pass encoder with its shell, which the pass's Impl needs alive, as Swift holds one.
@_spi(WebKitGPU)
public final class ComputePassEncoderReference {
    public let impl: ComputePassEncoderImpl
    let shell: WebGPU.Metal.ComputePassEncoder

    init(_ impl: ComputePassEncoderImpl, _ shell: WebGPU.Metal.ComputePassEncoder) {
        self.impl = impl
        self.shell = shell
    }
}

// A render pass encoder with its shell, which the pass's Impl needs alive, as Swift holds one.
@_spi(WebKitGPU)
public final class RenderPassEncoderReference {
    public let impl: RenderPassEncoderImpl
    let shell: WebGPU.Metal.RenderPassEncoder

    init(_ impl: RenderPassEncoderImpl, _ shell: WebGPU.Metal.RenderPassEncoder) {
        self.impl = impl
        self.shell = shell
    }
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
extension AdapterReference: GPUObjectReference {
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
extension ComputePassEncoderReference: GPUObjectReference {
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
extension CommandBufferReference: GPUObjectReference {
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
extension QueueReference: GPUObjectReference {
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
extension RenderPassEncoderReference: GPUObjectReference {
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
extension DeviceReference {
    public var apiObject: WebGPU.Device { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension ExternalTextureReference {
    public var apiObject: WebGPU.ExternalTexture { WebGPU.Metal.apiObject(shell) }
}

@_spi(WebKitGPU)
extension QueueReference {
    public var apiObject: WebGPU.Queue { WebGPU.Metal.apiObject(shell) }
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
