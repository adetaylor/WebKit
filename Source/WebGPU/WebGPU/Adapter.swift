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
@_implementationOnly import WebGPU_Internal.Adapter
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.HardwareCapabilities
import WebGPU_Private.WebGPUCpp

// An adapter with its shell, as Swift holds one.
@_spi(WebKitGPU)
public final class AdapterReference {
    let impl: AdapterImpl
    let shell: WebGPU.Metal.Adapter

    init(_ impl: AdapterImpl, _ shell: WebGPU.Metal.Adapter) {
        self.impl = impl
        self.shell = shell
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpuadapter-requestdevice, as the shell's requestDevice() does: nil if the
    // request fails, which invalidates the adapter if it has already made a device. As WTF::String::createNSString()
    // makes the label for the C++ caller, a null one is empty.
    public func requestDevice(
        requiredFeatures: [WebGPU.FeatureName],
        requiredLimits: WebGPU.Limits?,
        label: Swift.String?
    ) -> DeviceReference? {
        var capabilities = WebGPU.Metal.HardwareCapabilities()
        for feature in requiredFeatures {
            capabilities.features.append(consuming: feature)
        }
        var invalidatesAdapter = false
        if impl.errorRequestingDevice(requiredLimits != nil, requiredLimits ?? WebGPU.Limits(), &capabilities, &invalidatesAdapter) != nil {
            if invalidatesAdapter {
                impl.makeInvalid()
            }
            return nil
        }

        return makeDevice(impl.device(), WTF.String(label ?? ""), capabilities, shell, impl)
    }

    // https://gpuweb.github.io/gpuweb/#gpuadapterinfo, as the shell's info() gives it: a Metal device is never a fallback
    // adapter.
    public var name: Swift.String {
        impl.device()?.name ?? ""
    }

    public var subgroupSizes: (min: UInt32, max: UInt32) {
        var minSize: UInt32 = 0
        var maxSize: UInt32 = 0
        impl.subgroupSizes(&minSize, &maxSize)
        return (minSize, maxSize)
    }

    // Sorted by raw value.
    public var features: [WebGPU.FeatureName] {
        impl.features
    }

    public var limits: WebGPU.Limits {
        impl.limits()
    }
}

// Owned by the C++ shell WebGPU::Metal::Adapter, which keeps the Instance back-reference.
@_expose(Cxx)
final class AdapterImpl: DeliverableImpl {
    // nil: the adapter is invalid. API thread only (device loss reaches makeInvalid() through Instance::scheduleWork).
    private var metalDevice: (any MTLDevice)?
    private let xrCompatible: Bool
    private var deviceRequested = false
    // Sorted by raw value.
    @_expose(!Cxx)
    let features: [WebGPU.FeatureName]
    private let adapterLimits: WebGPU.Limits
    // Given to the device this adapter creates.
    private let baseCapabilities: GPUBaseCapabilities
    // The adapter's Instance, and its scheduler, for the device this adapter creates.
    private(set) weak var instanceImpl: InstanceImpl?
    private(set) var instanceSchedulerHandle: InstanceSchedulerHandle?

    fileprivate init(
        metalDevice: (any MTLDevice)?,
        xrCompatible: Bool,
        features: [WebGPU.FeatureName],
        limits: WebGPU.Limits,
        baseCapabilities: GPUBaseCapabilities
    ) {
        self.metalDevice = metalDevice
        self.xrCompatible = xrCompatible
        self.features = features
        adapterLimits = limits
        self.baseCapabilities = baseCapabilities
    }

    @_expose(Cxx)
    func setInstance(_ instanceImpl: InstanceImpl, _ schedulerHandle: InstanceSchedulerHandle) {
        self.instanceImpl = instanceImpl
        instanceSchedulerHandle = schedulerHandle
    }

    @_expose(Cxx)
    func limits() -> WebGPU.Limits {
        adapterLimits
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        metalDevice != nil
    }

    @_expose(Cxx)
    func device() -> (any MTLDevice)? {
        metalDevice
    }

    @_expose(Cxx)
    func makeInvalid() {
        metalDevice = nil
    }

    func isXRCompatible() -> Bool {
        xrCompatible
    }

    @_expose(Cxx)
    func hasFeature(_ feature: WebGPU.FeatureName) -> Bool {
        features.contains(feature)
    }

    func copyFeatures(_ destination: inout WebGPU.Metal.FeatureNames) {
        for feature in features {
            destination.append(consuming: feature)
        }
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpuadapter-requestdevice
    // nil accepts the request and turns `capabilities`, which arrives holding the required features, into the
    // device's. Otherwise the request fails with the returned message, and the shell invalidates the adapter after
    // reporting it if `invalidatesAdapter` is set.
    func errorRequestingDevice(
        _ hasRequiredLimits: Bool,
        _ requiredLimits: WebGPU.Limits,
        _ capabilities: inout WebGPU.Metal.HardwareCapabilities,
        _ invalidatesAdapter: inout Bool
    ) -> NSString? {
        if deviceRequested {
            invalidatesAdapter = true
            return "Adapter can only request one device" as NSString
        }

        let limits: ValidatedLimits
        if hasRequiredLimits {
            guard let accepted = ValidatedLimits(requested: requiredLimits, adapter: adapterLimits) else {
                return "Device does not support requested limits" as NSString
            }
            limits = accepted
        } else {
            limits = .defaults
        }

        if includesUnsupportedFeatures(capabilities.features, features) {
            return "Device does not support requested features" as NSString
        }

        capabilities.limits = limits.limits
        baseCapabilities.copy(to: &capabilities.baseCapabilities)
        deviceRequested = true
        return nil
    }

    func subgroupSizes(_ minSize: inout UInt32, _ maxSize: inout UInt32) {
        guard hasFeature(.Subgroups) else {
            // Spec defaults when the feature is unsupported: https://github.com/gpuweb/gpuweb/pull/4963
            minSize = 4
            maxSize = 128
            return
        }
        // Metal exposes a single SIMD-group (subgroup) width per device, so min and max are equal.
        let size = subgroupSize()
        minSize = size
        maxSize = size
    }

    // Apple Silicon GPUs have a fixed SIMD-group width of 32; on other GPUs it is read from a trivial compute
    // pipeline's threadExecutionWidth, falling back to 32 if that cannot be built or the adapter is invalid.
    private func subgroupSize() -> UInt32 {
        guard let device = metalDevice else {
            return 32
        }
        if device.supportsFamily(.apple4) {
            return 32
        }
        let source = "#include <metal_stdlib>\nusing namespace metal;\nkernel void _webgpu_subgroup_size_probe() { }"
        guard let library = try? device.makeLibrary(source: source, options: nil),
            let function = library.makeFunction(name: "_webgpu_subgroup_size_probe"),
            let pipelineState = try? device.makeComputePipelineState(function: function)
        else {
            return 32
        }
        return UInt32(truncatingIfNeeded: pipelineState.threadExecutionWidth)
    }
}

// An invalid adapter is one made with no device and empty capabilities.
@_expose(Cxx)
func makeAdapterImpl(
    _ metalDevice: (any MTLDevice)?,
    _ xrCompatible: Bool,
    _ capabilities: borrowing WebGPU.Metal.HardwareCapabilities
) -> AdapterImpl {
    AdapterImpl(
        metalDevice: metalDevice,
        xrCompatible: xrCompatible,
        features: featureArray(capabilities.features),
        limits: capabilities.limits,
        baseCapabilities: GPUBaseCapabilities(capabilities.baseCapabilities)
    )
}
