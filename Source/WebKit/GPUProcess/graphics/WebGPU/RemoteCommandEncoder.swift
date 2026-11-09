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

// Receives the messages of a WebGPU command encoder, on its stream connection's work queue, and calls its
// CommandEncoderImpl, with the references of the objects they name, from the registry. The passes and command
// buffers it makes go in the registry, with their receivers.
@_expose(Cxx)
final class RemoteCommandEncoder {
    private let encoder: CommandEncoderReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ encoder: CommandEncoderReference, _ link: WebGPURegistryLink) {
        self.encoder = encoder
        self.link = link
    }

    // Adds the command encoder, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ encoder: CommandEncoderReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteCommandEncoder(encoder, link)
        let registration = IPC.registerSwiftStreamReceiver(objects.host, receiver.getMessageReceiver(), .RemoteCommandEncoder, link.identifier)
        objects.add(link.identifier, encoder, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteCommandEncoderMessageForwarder {
        WebKit.RemoteCommandEncoderMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    private var objects: WebGPUImplTable? {
        link.objects
    }

    func beginRenderPass(descriptor: IPCTypes.RenderPassDescriptor, identifier: IPCTypes.WebGPUIdentifier) throws(InvalidMessage) {
        guard let objects, let passLink = link.child(identifier) else {
            return
        }
        RemoteRenderPassEncoder.add(encoder.beginRenderPass(try GPURenderPassDescriptor(descriptor, objects)), passLink)
    }

    func beginComputePass(descriptor: IPCTypes.ComputePassDescriptor?, identifier: IPCTypes.WebGPUIdentifier) {
        guard let objects, let passLink = link.child(identifier) else {
            return
        }
        var computePassDescriptor = GPUComputePassDescriptor()
        computePassDescriptor.timestampWrites = descriptor?.timestampWrites.flatMap { GPUPassTimestampWrites($0, objects) }
        RemoteComputePassEncoder.add(encoder.beginComputePass(computePassDescriptor, label: descriptor?.label), passLink)
    }

    func copyBufferToBuffer(
        source: IPCTypes.WebGPUIdentifier,
        sourceOffset: UInt64,
        destination: IPCTypes.WebGPUIdentifier,
        destinationOffset: UInt64,
        size: UInt64
    ) {
        let sourceBuffer = objects?.object(source, as: BufferReference.self)
        assert(sourceBuffer != nil)
        let destinationBuffer = objects?.object(destination, as: BufferReference.self)
        assert(destinationBuffer != nil)
        guard let sourceBuffer, let destinationBuffer else {
            return
        }
        encoder.copyBufferToBuffer(sourceBuffer, sourceOffset, destinationBuffer, destinationOffset, size)
    }

    func copyBufferToTexture(
        source: IPCTypes.ImageCopyBuffer,
        destination: IPCTypes.ImageCopyTexture,
        copySize: IPCTypes.Extent3D
    ) {
        let sourceBuffer = objects?.object(source.buffer, as: BufferReference.self)
        assert(sourceBuffer != nil)
        let destinationTexture = objects?.object(destination.texture, as: TextureReference.self)
        assert(destinationTexture != nil)
        guard let sourceBuffer, let destinationTexture else {
            return
        }
        encoder.copyBufferToTexture(sourceBuffer, BufferCopyLocation(source), destinationTexture, TextureCopyLocation(destination), WebGPU.Extent3D(copySize))
    }

    func copyTextureToBuffer(
        source: IPCTypes.ImageCopyTexture,
        destination: IPCTypes.ImageCopyBuffer,
        copySize: IPCTypes.Extent3D
    ) {
        let sourceTexture = objects?.object(source.texture, as: TextureReference.self)
        assert(sourceTexture != nil)
        let destinationBuffer = objects?.object(destination.buffer, as: BufferReference.self)
        assert(destinationBuffer != nil)
        guard let sourceTexture, let destinationBuffer else {
            return
        }
        encoder.copyTextureToBuffer(sourceTexture, TextureCopyLocation(source), destinationBuffer, BufferCopyLocation(destination), WebGPU.Extent3D(copySize))
    }

    func copyTextureToTexture(
        source: IPCTypes.ImageCopyTexture,
        destination: IPCTypes.ImageCopyTexture,
        copySize: IPCTypes.Extent3D
    ) {
        let sourceTexture = objects?.object(source.texture, as: TextureReference.self)
        assert(sourceTexture != nil)
        let destinationTexture = objects?.object(destination.texture, as: TextureReference.self)
        assert(destinationTexture != nil)
        guard let sourceTexture, let destinationTexture else {
            return
        }
        encoder.copyTextureToTexture(sourceTexture, TextureCopyLocation(source), destinationTexture, TextureCopyLocation(destination), WebGPU.Extent3D(copySize))
    }

    func clearBuffer(buffer: IPCTypes.WebGPUIdentifier, offset: UInt64, size: UInt64?) {
        let clearedBuffer = objects?.object(buffer, as: BufferReference.self)
        assert(clearedBuffer != nil)
        guard let clearedBuffer else {
            return
        }
        encoder.clearBuffer(clearedBuffer, offset, size)
    }

    func destruct() {
        link.remove()
    }

    func pushDebugGroup(groupLabel: String?) {
        encoder.pushDebugGroup(groupLabel)
    }

    func popDebugGroup() {
        encoder.popDebugGroup()
    }

    func insertDebugMarker(markerLabel: String?) {
        encoder.insertDebugMarker(markerLabel)
    }

    func writeTimestamp(identifier: IPCTypes.WebGPUIdentifier, queryIndex: UInt32) {
        let querySet = objects?.object(identifier, as: QuerySetReference.self)
        assert(querySet != nil)
        guard let querySet else {
            return
        }
        encoder.writeTimestamp(querySet, queryIndex)
    }

    func resolveQuerySet(
        identifier: IPCTypes.WebGPUIdentifier,
        firstQuery: UInt32,
        queryCount: UInt32,
        destination: IPCTypes.WebGPUIdentifier,
        destinationOffset: UInt64
    ) {
        let querySet = objects?.object(identifier, as: QuerySetReference.self)
        assert(querySet != nil)
        let destinationBuffer = objects?.object(destination, as: BufferReference.self)
        assert(destinationBuffer != nil)
        guard let querySet, let destinationBuffer else {
            return
        }
        encoder.resolveQuerySet(querySet, firstQuery, queryCount, destinationBuffer, destinationOffset)
    }

    func finish(descriptor: IPCTypes.CommandBufferDescriptor, identifier: IPCTypes.WebGPUIdentifier) {
        guard let commandBufferLink = link.child(identifier) else {
            return
        }
        RemoteCommandBuffer.add(encoder.finish(label: descriptor.label), commandBufferLink)
    }

    func setLabel(label: String?) {
        encoder.setLabel(label)
    }
}

extension GPURenderPassAttachmentView {
    // The texture view with that identifier, or else the texture, as ConvertFromBackingContext looked them up.
    fileprivate init?(_ identifier: IPCTypes.WebGPUIdentifier, _ objects: WebGPUImplTable) {
        if let view = objects.object(identifier, as: TextureViewReference.self) {
            self = .textureView(view)
        } else if let texture = objects.object(identifier, as: TextureReference.self) {
            self = .texture(texture)
        } else {
            return nil
        }
    }
}

extension GPUPassTimestampWrites {
    // nil if the query set doesn't exist, which leaves the pass without timestamp writes, as ConvertFromBackingContext
    // did.
    fileprivate init?(_ timestampWrites: IPCTypes.RenderPassTimestampWrites, _ objects: WebGPUImplTable) {
        guard let querySet = objects.object(timestampWrites.querySet, as: QuerySetReference.self) else {
            return nil
        }
        self.init(querySet: querySet)
        beginningOfPassWriteIndex = timestampWrites.beginningOfPassWriteIndex
        endOfPassWriteIndex = timestampWrites.endOfPassWriteIndex
    }
}

extension GPURenderPassDescriptor {
    // A message naming an attachment or an occlusion query set that doesn't exist is invalid.
    fileprivate init(_ descriptor: IPCTypes.RenderPassDescriptor, _ objects: WebGPUImplTable) throws(InvalidMessage) {
        self.init()
        colorAttachments.reserveCapacity(descriptor.colorAttachments.count)
        for colorAttachment in descriptor.colorAttachments {
            guard let colorAttachment else {
                colorAttachments.append(nil)
                continue
            }
            var attachment = GPURenderPassColorAttachment(
                view: try messageChecked(GPURenderPassAttachmentView(colorAttachment.view, objects))
            )
            attachment.depthSlice = colorAttachment.depthSlice
            if let resolveTarget = colorAttachment.resolveTarget {
                attachment.resolveTarget = try messageChecked(GPURenderPassAttachmentView(resolveTarget, objects))
            }
            if let clearValue = colorAttachment.clearValue {
                attachment.clearValue = WebGPU.Color(r: clearValue.r, g: clearValue.g, b: clearValue.b, a: clearValue.a)
            }
            attachment.loadOp = sameNumbering(colorAttachment.loadOp)
            attachment.storeOp = sameNumbering(colorAttachment.storeOp)
            colorAttachments.append(attachment)
        }

        if let depthStencil = descriptor.depthStencilAttachment {
            var attachment = GPURenderPassDepthStencilAttachment(
                view: try messageChecked(GPURenderPassAttachmentView(depthStencil.view, objects))
            )
            attachment.depthClearValue = depthStencil.depthClearValue
            attachment.depthLoadOp = depthStencil.depthLoadOp.map { sameNumbering($0) }
            attachment.depthStoreOp = depthStencil.depthStoreOp.map { sameNumbering($0) }
            attachment.depthReadOnly = depthStencil.depthReadOnly
            attachment.stencilClearValue = depthStencil.stencilClearValue
            attachment.stencilLoadOp = depthStencil.stencilLoadOp.map { sameNumbering($0) }
            attachment.stencilStoreOp = depthStencil.stencilStoreOp.map { sameNumbering($0) }
            attachment.stencilReadOnly = depthStencil.stencilReadOnly
            depthStencilAttachment = attachment
        }

        if let occlusionQuerySet = descriptor.occlusionQuerySet {
            self.occlusionQuerySet = try messageChecked(objects.object(occlusionQuerySet, as: QuerySetReference.self))
        }
        timestampWrites = descriptor.timestampWrites.flatMap { GPUPassTimestampWrites($0, objects) }
        maxDrawCount = descriptor.maxDrawCount
    }
}

extension BufferCopyLocation {
    // ConvertFromBackingContext's conversion of the location, apart from the buffer.
    fileprivate init(_ location: IPCTypes.ImageCopyBuffer) {
        self.init()
        layout = WebGPU.TexelCopyBufferLayout(IPCTypes.TexelCopyBufferLayout(offset: location.offset, bytesPerRow: location.bytesPerRow, rowsPerImage: location.rowsPerImage))
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
