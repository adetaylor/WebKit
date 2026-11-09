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

// Receives the messages of a WebGPU render bundle encoder, on its stream connection's work queue, and calls its
// RenderBundleEncoderImpl, with the references of the objects they name, from the registry.
@_expose(Cxx)
final class RemoteRenderBundleEncoder {
    private let encoder: RenderBundleEncoderReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ encoder: RenderBundleEncoderReference, _ link: WebGPURegistryLink) {
        self.encoder = encoder
        self.link = link
    }

    // Adds the render bundle encoder, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ encoder: RenderBundleEncoderReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteRenderBundleEncoder(encoder, link)
        let registration = IPC.registerSwiftStreamReceiver(objects.host, receiver.getMessageReceiver(), .RemoteRenderBundleEncoder, link.identifier)
        objects.add(link.identifier, encoder, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteRenderBundleEncoderMessageForwarder {
        WebKit.RemoteRenderBundleEncoderMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    private func buffer(_ identifier: IPCTypes.WebGPUIdentifier) -> BufferReference? {
        link.objects?.object(identifier, as: BufferReference.self)
    }

    func destruct() {
        link.remove()
    }

    func setPipeline(identifier: IPCTypes.WebGPUIdentifier) {
        guard let pipeline = link.objects?.object(identifier, as: RenderPipelineReference.self) else {
            return
        }
        encoder.setPipeline(pipeline)
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
        encoder.setIndexBuffer(buffer, WebGPU.IndexFormat(indexFormat), offset, size)
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
        encoder.setVertexBuffer(slot, buffer, offset, size)
    }

    func unsetVertexBuffer(slot: UInt32, offset: UInt64, size: UInt64?) {
        encoder.setVertexBuffer(slot, nil, offset, size)
    }

    func draw(vertexCount: UInt32, instanceCount: UInt32, firstVertex: UInt32, firstInstance: UInt32) {
        encoder.draw(vertexCount, instanceCount, firstVertex, firstInstance)
    }

    func drawIndexed(
        indexCount: UInt32,
        instanceCount: UInt32,
        firstIndex: UInt32,
        baseVertex: Int32,
        firstInstance: UInt32
    ) {
        encoder.drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance)
    }

    func drawIndirect(indirectBuffer: IPCTypes.WebGPUIdentifier, indirectOffset: UInt64) {
        guard let buffer = buffer(indirectBuffer) else {
            return
        }
        encoder.drawIndirect(buffer, indirectOffset)
    }

    func drawIndexedIndirect(indirectBuffer: IPCTypes.WebGPUIdentifier, indirectOffset: UInt64) {
        guard let buffer = buffer(indirectBuffer) else {
            return
        }
        encoder.drawIndexedIndirect(buffer, indirectOffset)
    }

    func setBindGroup(
        index: UInt32,
        identifier: IPCTypes.WebGPUIdentifier?,
        dynamicOffsets: [UInt32]?
    ) {
        guard let identifier else {
            encoder.setBindGroup(index, nil, dynamicOffsets: dynamicOffsets)
            return
        }
        guard let group = link.objects?.object(identifier, as: BindGroupReference.self) else {
            return
        }
        encoder.setBindGroup(index, group, dynamicOffsets: dynamicOffsets)
    }

    func pushDebugGroup(groupLabel: String?) {
        encoder.pushDebugGroup()
    }

    func popDebugGroup() {
        encoder.popDebugGroup()
    }

    func insertDebugMarker(markerLabel: String?) {
        encoder.insertDebugMarker()
    }

    func finish(
        descriptor: IPCTypes.RenderBundleDescriptor,
        identifier: IPCTypes.WebGPUIdentifier
    ) {
        guard let bundleLink = link.child(identifier) else {
            return
        }
        RemoteRenderBundle.add(encoder.finish(label: descriptor.label), bundleLink)
    }

    func setLabel(label: String?) {
        encoder.setLabel(label)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
