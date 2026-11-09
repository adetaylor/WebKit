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

// Receives the messages of a WebGPU adapter, on its stream connection's work queue, and calls its AdapterImpl. The
// devices it makes go in the registry, with their receivers and their queues'.
@_expose(Cxx)
final class RemoteAdapter {
    private let adapter: AdapterReference
    private let link: WebGPURegistryLink

    @_expose(!Cxx)
    private init(_ adapter: AdapterReference, _ link: WebGPURegistryLink) {
        self.adapter = adapter
        self.link = link
    }

    // Adds the adapter, with this receiver of its messages, to the registry that the link names.
    @_expose(!Cxx)
    static func add(_ adapter: AdapterReference, _ link: WebGPURegistryLink) {
        guard let objects = link.objects else {
            return
        }
        let receiver = RemoteAdapter(adapter, link)
        let registration = WebKit.registerWebGPUSwiftReceiver(objects.host, receiver.getMessageReceiver(), .RemoteAdapter, link.identifier)
        objects.add(link.identifier, adapter, receiver: receiver, registration: registration)
    }

    // The forwarder keeps this alive, so this mustn't keep the forwarder: the C++ that registers it does.
    @_expose(!Cxx)
    func getMessageReceiver() -> RefRemoteAdapterMessageForwarder {
        WebKit.RemoteAdapterMessageForwarder.create(target: self)
    }

    @_expose(!Cxx)
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        link.sharedPreferencesForWebProcess()
    }

    func destruct() {
        link.remove()
    }

    // An empty reply if the adapter makes no device, or the registry has gone.
    func requestDevice(
        deviceDescriptor: IPCTypes.DeviceDescriptor,
        identifier: IPCTypes.WebGPUIdentifier,
        queueIdentifier: IPCTypes.WebGPUIdentifier
    ) -> (features: [IPCTypes.FeatureName], supportedLimits: IPCTypes.Limits) {
        let device = adapter.requestDevice(
            requiredFeatures: deviceDescriptor.requiredFeatures.map { sameNumbering($0) },
            requiredLimits: deviceDescriptor.requiredLimits.map { WebGPU.Limits($0) },
            label: deviceDescriptor.label
        )
        guard let device, let objects = link.objects else {
            return ([], IPCTypes.Limits(WebGPU.Limits()))
        }
        objects.addDevice(device, identifier.rawValue, queueIdentifier.rawValue)
        return (device.features.map { sameNumbering($0) }, IPCTypes.Limits(device.limits))
    }
}

extension WebGPU.Limits {
    fileprivate init(_ limits: IPCTypes.Limits) {
        self.init(
            maxTextureDimension1D: limits.maxTextureDimension1D,
            maxTextureDimension2D: limits.maxTextureDimension2D,
            maxTextureDimension3D: limits.maxTextureDimension3D,
            maxTextureArrayLayers: limits.maxTextureArrayLayers,
            maxBindGroups: limits.maxBindGroups,
            maxBindGroupsPlusVertexBuffers: limits.maxBindGroupsPlusVertexBuffers,
            maxBindingsPerBindGroup: limits.maxBindingsPerBindGroup,
            maxDynamicUniformBuffersPerPipelineLayout: limits.maxDynamicUniformBuffersPerPipelineLayout,
            maxDynamicStorageBuffersPerPipelineLayout: limits.maxDynamicStorageBuffersPerPipelineLayout,
            maxSampledTexturesPerShaderStage: limits.maxSampledTexturesPerShaderStage,
            maxSamplersPerShaderStage: limits.maxSamplersPerShaderStage,
            maxStorageBuffersPerShaderStage: limits.maxStorageBuffersPerShaderStage,
            maxStorageTexturesPerShaderStage: limits.maxStorageTexturesPerShaderStage,
            maxUniformBuffersPerShaderStage: limits.maxUniformBuffersPerShaderStage,
            maxUniformBufferBindingSize: limits.maxUniformBufferBindingSize,
            maxStorageBufferBindingSize: limits.maxStorageBufferBindingSize,
            minUniformBufferOffsetAlignment: limits.minUniformBufferOffsetAlignment,
            minStorageBufferOffsetAlignment: limits.minStorageBufferOffsetAlignment,
            maxVertexBuffers: limits.maxVertexBuffers,
            maxBufferSize: limits.maxBufferSize,
            maxVertexAttributes: limits.maxVertexAttributes,
            maxVertexBufferArrayStride: limits.maxVertexBufferArrayStride,
            maxInterStageShaderVariables: limits.maxInterStageShaderVariables,
            maxColorAttachments: limits.maxColorAttachments,
            maxColorAttachmentBytesPerSample: limits.maxColorAttachmentBytesPerSample,
            maxComputeWorkgroupStorageSize: limits.maxComputeWorkgroupStorageSize,
            maxComputeInvocationsPerWorkgroup: limits.maxComputeInvocationsPerWorkgroup,
            maxComputeWorkgroupSizeX: limits.maxComputeWorkgroupSizeX,
            maxComputeWorkgroupSizeY: limits.maxComputeWorkgroupSizeY,
            maxComputeWorkgroupSizeZ: limits.maxComputeWorkgroupSizeZ,
            maxComputeWorkgroupsPerDimension: limits.maxComputeWorkgroupsPerDimension,
            maxStorageBuffersInFragmentStage: limits.maxStorageBuffersInFragmentStage,
            maxStorageTexturesInFragmentStage: limits.maxStorageTexturesInFragmentStage,
            maxStorageBuffersInVertexStage: limits.maxStorageBuffersInVertexStage,
            maxStorageTexturesInVertexStage: limits.maxStorageTexturesInVertexStage
        )
    }
}

extension IPCTypes.Limits {
    init(_ limits: WebGPU.Limits) {
        self.init(
            maxTextureDimension1D: limits.maxTextureDimension1D,
            maxTextureDimension2D: limits.maxTextureDimension2D,
            maxTextureDimension3D: limits.maxTextureDimension3D,
            maxTextureArrayLayers: limits.maxTextureArrayLayers,
            maxBindGroups: limits.maxBindGroups,
            maxBindGroupsPlusVertexBuffers: limits.maxBindGroupsPlusVertexBuffers,
            maxBindingsPerBindGroup: limits.maxBindingsPerBindGroup,
            maxDynamicUniformBuffersPerPipelineLayout: limits.maxDynamicUniformBuffersPerPipelineLayout,
            maxDynamicStorageBuffersPerPipelineLayout: limits.maxDynamicStorageBuffersPerPipelineLayout,
            maxSampledTexturesPerShaderStage: limits.maxSampledTexturesPerShaderStage,
            maxSamplersPerShaderStage: limits.maxSamplersPerShaderStage,
            maxStorageBuffersPerShaderStage: limits.maxStorageBuffersPerShaderStage,
            maxStorageTexturesPerShaderStage: limits.maxStorageTexturesPerShaderStage,
            maxUniformBuffersPerShaderStage: limits.maxUniformBuffersPerShaderStage,
            maxUniformBufferBindingSize: limits.maxUniformBufferBindingSize,
            maxStorageBufferBindingSize: limits.maxStorageBufferBindingSize,
            minUniformBufferOffsetAlignment: limits.minUniformBufferOffsetAlignment,
            minStorageBufferOffsetAlignment: limits.minStorageBufferOffsetAlignment,
            maxVertexBuffers: limits.maxVertexBuffers,
            maxBufferSize: limits.maxBufferSize,
            maxVertexAttributes: limits.maxVertexAttributes,
            maxVertexBufferArrayStride: limits.maxVertexBufferArrayStride,
            maxInterStageShaderVariables: limits.maxInterStageShaderVariables,
            maxColorAttachments: limits.maxColorAttachments,
            maxColorAttachmentBytesPerSample: limits.maxColorAttachmentBytesPerSample,
            maxComputeWorkgroupStorageSize: limits.maxComputeWorkgroupStorageSize,
            maxComputeInvocationsPerWorkgroup: limits.maxComputeInvocationsPerWorkgroup,
            maxComputeWorkgroupSizeX: limits.maxComputeWorkgroupSizeX,
            maxComputeWorkgroupSizeY: limits.maxComputeWorkgroupSizeY,
            maxComputeWorkgroupSizeZ: limits.maxComputeWorkgroupSizeZ,
            maxComputeWorkgroupsPerDimension: limits.maxComputeWorkgroupsPerDimension,
            maxStorageBuffersInFragmentStage: limits.maxStorageBuffersInFragmentStage,
            maxStorageTexturesInFragmentStage: limits.maxStorageTexturesInFragmentStage,
            maxStorageBuffersInVertexStage: limits.maxStorageBuffersInVertexStage,
            maxStorageTexturesInVertexStage: limits.maxStorageTexturesInVertexStage
        )
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_WEBGPU_SWIFT
