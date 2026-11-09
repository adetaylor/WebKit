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

// Receives the messages of a WebGPU compute pass encoder, on its stream connection's work queue, and calls its
// ComputePassEncoderImpl, with the references of the objects they name, from the registry.
@_expose(Cxx)
final class RemoteComputePassEncoder {
    private let impl: ComputePassEncoderImpl
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ computePassEncoder: ComputePassEncoderReference, _ link: WebGPURegistryLink) {
        impl = computePassEncoder
        self.link = link
    }

    // Adds the compute pass encoder, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ computePassEncoder: ComputePassEncoderReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteComputePassEncoder(computePassEncoder, link)
        let registration = IPC.registerSwiftStreamReceiver(objects.host, receiver.getMessageReceiver(), .RemoteComputePassEncoder, link.identifier)
        objects.add(link.identifier, computePassEncoder, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteComputePassEncoderMessageForwarder {
        WebKit.RemoteComputePassEncoderMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    private var objects: WebGPUImplTable? {
        link.objects
    }

    func destruct() {
        link.remove()
    }

    func setPipeline(identifier: IPCTypes.WebGPUIdentifier) {
        let pipeline = objects?.object(identifier, as: ComputePipelineReference.self)
        guard let pipeline else {
            return
        }
        impl.setPipeline(pipeline)
    }

    func dispatch(workgroupCountX: UInt32, workgroupCountY: UInt32, workgroupCountZ: UInt32) {
        impl.dispatch(workgroupCountX, workgroupCountY, workgroupCountZ)
    }

    func dispatchIndirect(indirectBuffer: IPCTypes.WebGPUIdentifier, indirectOffset: UInt64) {
        let buffer = objects?.object(indirectBuffer, as: BufferReference.self)
        guard let buffer else {
            return
        }
        impl.dispatchIndirect(buffer, indirectOffset)
    }

    func end() {
        impl.endPass()
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
        let group = objects?.object(identifier, as: BindGroupReference.self)
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

    func setLabel(label: String?) {
        impl.setLabel(label)
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
