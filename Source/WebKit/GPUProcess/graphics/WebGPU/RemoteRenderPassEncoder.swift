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

// Receives the messages of a WebGPU render pass encoder, on its stream connection's work queue, and calls its
// RenderPassEncoderImpl, with the references of the objects they name, from the registry.
@_expose(Cxx)
final class RemoteRenderPassEncoder {
    private let impl: RenderPassEncoderImpl
    private let context: WebKit.WebGPUSwiftReceiverContext
    private let objects: WebGPUImplTable

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init(backing: WebKit.RemoteRenderPassEncoderBacking, context: WebKit.WebGPUSwiftReceiverContext, objects: WebGPUImplTable) {
        self.impl = WebGPUSwift.impl(of: backing.get())
        self.context = context
        self.objects = objects
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @used
    func getMessageReceiver() -> RefRemoteRenderPassEncoderMessageForwarder {
        WebKit.RemoteRenderPassEncoderMessageForwarder.create(target: self)
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        context.sharedPreferencesForWebProcess()
    }

    private func buffer(_ identifier: IPCTypes.WebGPUIdentifier) -> BufferReference? {
        objects.object(identifier, as: BufferReference.self)
    }

    func destruct() {
        context.removeFromObjectHeap()
    }

    func setPipeline(identifier: IPCTypes.WebGPUIdentifier) {
        let pipeline = objects.object(identifier, as: RenderPipelineReference.self)
        guard let pipeline else {
            return
        }
        impl.setPipeline(pipeline)
    }

    func setIndexBuffer(
        identifier: IPCTypes.WebGPUIdentifier,
        indexFormat: IPCTypes.IndexFormat,
        offset: UInt64,
        size: UInt64?
    ) {
        guard let buffer = buffer(identifier) else {
            return
        }
        impl.setIndexBuffer(buffer, WebGPU.IndexFormat(indexFormat), offset, size)
    }

    func setVertexBuffer(
        slot: UInt32,
        identifier: IPCTypes.WebGPUIdentifier,
        offset: UInt64,
        size: UInt64?
    ) {
        guard let buffer = buffer(identifier) else {
            return
        }
        impl.setVertexBuffer(slot, buffer.impl, offset, size)
    }

    func unsetVertexBuffer(slot: UInt32, offset: UInt64, size: UInt64?) {
        impl.setVertexBuffer(slot, nil, offset, size)
    }

    func draw(vertexCount: UInt32, instanceCount: UInt32, firstVertex: UInt32, firstInstance: UInt32) {
        impl.draw(vertexCount, instanceCount, firstVertex, firstInstance)
    }

    func drawIndexed(
        indexCount: UInt32,
        instanceCount: UInt32,
        firstIndex: UInt32,
        baseVertex: Int32,
        firstInstance: UInt32
    ) {
        impl.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance)
    }

    func drawIndirect(indirectBuffer: IPCTypes.WebGPUIdentifier, indirectOffset: UInt64) {
        guard let buffer = buffer(indirectBuffer) else {
            return
        }
        impl.drawIndirect(buffer.impl, indirectOffset)
    }

    func drawIndexedIndirect(indirectBuffer: IPCTypes.WebGPUIdentifier, indirectOffset: UInt64) {
        guard let buffer = buffer(indirectBuffer) else {
            return
        }
        impl.drawIndexedIndirect(buffer.impl, indirectOffset)
    }

    func setBindGroup(
        index: UInt32,
        identifier: IPCTypes.WebGPUIdentifier?,
        dynamicOffsets: [UInt32]?
    ) {
        guard let identifier else {
            impl.setBindGroup(index, nil, dynamicOffsets: dynamicOffsets)
            return
        }
        let group = objects.object(identifier, as: BindGroupReference.self)
        guard let group else {
            return
        }
        impl.setBindGroup(index, group, dynamicOffsets: dynamicOffsets)
    }

    func pushDebugGroup(groupLabel: String?) {
        impl.pushDebugGroup(groupLabel)
    }

    func popDebugGroup() {
        impl.popDebugGroup()
    }

    func insertDebugMarker(markerLabel: String?) {
        impl.insertDebugMarker(markerLabel)
    }

    func setViewport(x: Float, y: Float, width: Float, height: Float, minDepth: Float, maxDepth: Float) {
        impl.setViewport(x, y, width, height, minDepth, maxDepth)
    }

    func setScissorRect(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        impl.setScissorRect(x, y, width, height)
    }

    func setBlendConstant(color: IPCTypes.Color) {
        impl.setBlendConstant(WebGPU.Color(r: color.r, g: color.g, b: color.b, a: color.a))
    }

    func setStencilReference(stencilValue: UInt32) {
        impl.setStencilReference(stencilValue)
    }

    func beginOcclusionQuery(queryIndex: UInt32) {
        impl.beginOcclusionQuery(queryIndex)
    }

    func endOcclusionQuery() {
        impl.endOcclusionQuery()
    }

    // Executes none of the bundles if any isn't in the object heap.
    func executeBundles(bundles: [IPCTypes.WebGPUIdentifier]) {
        var references: [RenderBundleReference] = []
        references.reserveCapacity(bundles.count)
        for identifier in bundles {
            let bundle = objects.object(identifier, as: RenderBundleReference.self)
            guard let bundle else {
                return
            }
            references.append(bundle)
        }
        impl.executeBundles(references)
    }

    func end() {
        impl.endPass()
    }

    func setLabel(label: String?) {
        impl.setLabel(label)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
