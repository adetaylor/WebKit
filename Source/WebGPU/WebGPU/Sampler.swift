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

private import CxxStdlib
import Metal
import Synchronization
import WebGPU_Internal.Device
import WebGPU_Private.WebGPUCpp

// Owned by the C++ shell WebGPU::Metal::Sampler. API thread only; the process-wide MTLSamplerState pool it leases from
// is the Mutex-protected `samplerStates` below.
@_expose(Cxx)
final class SamplerImpl {
    fileprivate struct Configuration {
        let metal: MetalSamplerConfiguration
        let comparison: Bool
        let filtering: Bool
    }

    // nil for an invalid sampler.
    private let configuration: Configuration?
    private var label: WTF.String
    private weak var cachedState: (any MTLSamplerState)?
    // Declared last, so that the device outlives the rest of the sampler.
    let deviceImpl: DeviceImpl
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    fileprivate init(device: WebGPU.Metal.Device, deviceImpl: DeviceImpl, configuration: Configuration?, label: WTF.String) {
        self.configuration = configuration
        self.label = label
        self.deviceImpl = deviceImpl
        self.device = device
        _ = tryCacheSamplerState()
    }

    fileprivate convenience init(device: WebGPU.Metal.Device, deviceImpl: DeviceImpl, descriptor: WebGPU.SamplerDescriptor) {
        let metal = MetalSamplerConfiguration(descriptor)
        assert(
            SamplerCacheKey(metal) == SamplerCacheKey(metal.makeDescriptor()),
            "SamplerCacheKey no longer matches the MTLSamplerDescriptor it describes"
        )
        let configuration = Configuration(
            metal: metal,
            comparison: Optional(fromCxx: descriptor.compare) != nil,
            filtering: descriptor.minFilter == WebGPU.FilterMode.Linear
                || descriptor.magFilter == WebGPU.FilterMode.Linear
                || descriptor.mipmapFilter == WebGPU.MipmapFilterMode.Linear
        )
        self.init(device: device, deviceImpl: deviceImpl, configuration: configuration, label: descriptor.label)
    }

    deinit {
        // A dead weak reference means the pool already dropped the entry.
        if let configuration, let cachedState {
            samplerCacheRelease(SamplerCacheKey(configuration.metal), cachedState)
        }
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        configuration != nil
    }

    @_expose(Cxx)
    func setLabel(_ newLabel: WTF.String) {
        label = newLabel
    }

    func isComparison() -> Bool {
        configuration?.comparison ?? false
    }

    func isFiltering() -> Bool {
        configuration?.filtering ?? false
    }

    func cachedSamplerState() -> (any MTLSamplerState)? {
        cachedState
    }

    func tryCacheSamplerState() -> (any MTLSamplerState)? {
        if let cachedState {
            return cachedState
        }
        guard let configuration, let device = deviceImpl.device() else {
            return nil
        }
        let state = samplerCacheAcquire(SamplerCacheKey(configuration.metal), configuration.metal, device)
        cachedState = state
        return state
    }
}

// https://gpuweb.github.io/gpuweb/#dom-gpudevice-createsampler
@_expose(Cxx)
func createSamplerImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl, _ descriptor: WebGPU.SamplerDescriptor) -> SamplerImpl {
    guard deviceImpl.isValid() else {
        return makeInvalidSamplerImpl(device, deviceImpl)
    }
    guard validateCreateSampler(descriptor) else {
        deviceImpl.generateAValidationError("Validation failure.")
        return makeInvalidSamplerImpl(device, deviceImpl)
    }
    return SamplerImpl(device: device, deviceImpl: deviceImpl, descriptor: descriptor)
}

@_expose(Cxx)
func makeInvalidSamplerImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> SamplerImpl {
    SamplerImpl(device: device, deviceImpl: deviceImpl, configuration: nil, label: WTF.String())
}

// https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpusamplerdescriptor
private func validateCreateSampler(_ descriptor: WebGPU.SamplerDescriptor) -> Bool {
    if descriptor.lodMinClamp.isNaN || descriptor.lodMinClamp < 0 {
        return false
    }
    if descriptor.lodMaxClamp.isNaN || descriptor.lodMaxClamp < descriptor.lodMinClamp {
        return false
    }
    if descriptor.maxAnisotropy < 1 {
        return false
    }
    if descriptor.maxAnisotropy > 1 {
        if descriptor.magFilter != WebGPU.FilterMode.Linear
            || descriptor.minFilter != WebGPU.FilterMode.Linear
            || descriptor.mipmapFilter != WebGPU.MipmapFilterMode.Linear
        {
            return false
        }
    }
    return true
}

// MARK: MTLSamplerDescriptor

// Imported Metal enums accept any raw value.
// swift-format-ignore: NeverForceUnwrap
private func metalEnum<T: RawRepresentable>(_ raw: UInt8) -> T where T.RawValue == UInt {
    T(rawValue: UInt(raw))!
}

// What a sampler's MTLSamplerState is built from, converted from WebGPU once. The Metal enums are kept as their raw
// values (all below 256), so that the configuration takes 16 bytes.
private struct MetalSamplerConfiguration: Sendable {
    let lodMinClamp: Float
    let lodMaxClamp: Float
    private let sAddressModeRawValue: UInt8
    private let tAddressModeRawValue: UInt8
    private let rAddressModeRawValue: UInt8
    /// magFilter in bit 0, minFilter in bit 1 (MTLSamplerMinMagFilter is 0 or 1), mipFilter in bits 2-3 (0 to 2): one
    /// byte, so that SamplerImpl.Configuration and its Optional fit in 16 bytes.
    private let filterBits: UInt8
    private let compareFunctionRawValue: UInt8
    private let maxAnisotropyValue: UInt8

    var sAddressMode: MTLSamplerAddressMode { metalEnum(sAddressModeRawValue) }
    var tAddressMode: MTLSamplerAddressMode { metalEnum(tAddressModeRawValue) }
    var rAddressMode: MTLSamplerAddressMode { metalEnum(rAddressModeRawValue) }
    var magFilter: MTLSamplerMinMagFilter { metalEnum(filterBits & 1) }
    var minFilter: MTLSamplerMinMagFilter { metalEnum((filterBits >> 1) & 1) }
    var mipFilter: MTLSamplerMipFilter { metalEnum((filterBits >> 2) & 3) }
    var compareFunction: MTLCompareFunction { metalEnum(compareFunctionRawValue) }
    var maxAnisotropy: Int { Int(maxAnisotropyValue) }

    init(_ descriptor: WebGPU.SamplerDescriptor) {
        sAddressModeRawValue = UInt8(metalAddressMode(descriptor.addressModeU).rawValue)
        tAddressModeRawValue = UInt8(metalAddressMode(descriptor.addressModeV).rawValue)
        rAddressModeRawValue = UInt8(metalAddressMode(descriptor.addressModeW).rawValue)
        filterBits =
            UInt8(metalMinMagFilter(descriptor.magFilter).rawValue)
            | UInt8(metalMinMagFilter(descriptor.minFilter).rawValue) << 1
            | UInt8(metalMipFilter(descriptor.mipmapFilter).rawValue) << 2
        lodMinClamp = descriptor.lodMinClamp
        lodMaxClamp = descriptor.lodMaxClamp
        compareFunctionRawValue = UInt8(metalCompareFunction(Optional(fromCxx: descriptor.compare)).rawValue)
        // https://developer.apple.com/documentation/metal/mtlsamplerdescriptor/1516164-maxanisotropy
        // "Values must be between 1 and 16, inclusive."
        maxAnisotropyValue = UInt8(min(descriptor.maxAnisotropy, 16))
    }

    func makeDescriptor() -> MTLSamplerDescriptor {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = sAddressMode
        descriptor.tAddressMode = tAddressMode
        descriptor.rAddressMode = rAddressMode
        descriptor.magFilter = magFilter
        descriptor.minFilter = minFilter
        descriptor.mipFilter = mipFilter
        descriptor.lodMinClamp = lodMinClamp
        descriptor.lodMaxClamp = lodMaxClamp
        descriptor.compareFunction = compareFunction
        descriptor.supportArgumentBuffers = true
        descriptor.maxAnisotropy = maxAnisotropy
        return descriptor
    }
}

private func metalAddressMode(_ addressMode: WebGPU.AddressMode) -> MTLSamplerAddressMode {
    switch addressMode {
    case WebGPU.AddressMode.Repeat:
        return .repeat
    case WebGPU.AddressMode.MirrorRepeat:
        return .mirrorRepeat
    case WebGPU.AddressMode.ClampToEdge:
        return .clampToEdge
    default:
        preconditionFailure("unknown WebGPU::AddressMode")
    }
}

private func metalMinMagFilter(_ filterMode: WebGPU.FilterMode) -> MTLSamplerMinMagFilter {
    switch filterMode {
    case WebGPU.FilterMode.Nearest:
        return .nearest
    case WebGPU.FilterMode.Linear:
        return .linear
    default:
        preconditionFailure("unknown WebGPU::FilterMode")
    }
}

private func metalMipFilter(_ filterMode: WebGPU.MipmapFilterMode) -> MTLSamplerMipFilter {
    switch filterMode {
    case WebGPU.MipmapFilterMode.Nearest:
        return .nearest
    case WebGPU.MipmapFilterMode.Linear:
        return .linear
    default:
        preconditionFailure("unknown WebGPU::MipmapFilterMode")
    }
}

private func metalCompareFunction(_ compareFunction: WebGPU.CompareFunction?) -> MTLCompareFunction {
    guard let compareFunction else {
        return .always
    }
    switch compareFunction {
    case WebGPU.CompareFunction.Never:
        return .never
    case WebGPU.CompareFunction.Less:
        return .less
    case WebGPU.CompareFunction.LessEqual:
        return .lessEqual
    case WebGPU.CompareFunction.Greater:
        return .greater
    case WebGPU.CompareFunction.GreaterEqual:
        return .greaterEqual
    case WebGPU.CompareFunction.Equal:
        return .equal
    case WebGPU.CompareFunction.NotEqual:
        return .notEqual
    case WebGPU.CompareFunction.Always:
        return .always
    default:
        preconditionFailure("unknown WebGPU::CompareFunction")
    }
}

// MARK: Process-wide MTLSamplerState pool

// The descriptor's enum and Bool fields packed low bit first, then the bits of its three float fields.
private struct SamplerCacheKey: WTFHashKey, Sendable {
    let miscHash: UInt32
    let lodMinClamp: UInt32
    let lodMaxClamp: UInt32
    let maxAnisotropy: UInt32

    private static func bits(_ value: UInt, _ width: UInt32, _ shift: UInt32) -> UInt32 {
        (UInt32(truncatingIfNeeded: value) & ((1 << width) - 1)) << shift
    }

    private static func miscHash(
        minFilter: MTLSamplerMinMagFilter,
        magFilter: MTLSamplerMinMagFilter,
        mipFilter: MTLSamplerMipFilter,
        sAddressMode: MTLSamplerAddressMode,
        tAddressMode: MTLSamplerAddressMode,
        rAddressMode: MTLSamplerAddressMode,
        normalizedCoordinates: Bool,
        borderColor: MTLSamplerBorderColor,
        lodAverage: Bool,
        compareFunction: MTLCompareFunction,
        supportArgumentBuffers: Bool
    ) -> UInt32 {
        bits(minFilter.rawValue, 2, 0)
            | bits(magFilter.rawValue, 2, 2)
            | bits(mipFilter.rawValue, 2, 4)
            | bits(sAddressMode.rawValue, 3, 6)
            | bits(tAddressMode.rawValue, 3, 9)
            | bits(rAddressMode.rawValue, 3, 12)
            | bits(normalizedCoordinates ? 1 : 0, 1, 15)
            | bits(borderColor.rawValue, 2, 16)
            | bits(lodAverage ? 1 : 0, 1, 18)
            | bits(compareFunction.rawValue, 3, 19)
            | bits(supportArgumentBuffers ? 1 : 0, 1, 22)
    }

    init(_ descriptor: MTLSamplerDescriptor) {
        miscHash = Self.miscHash(
            minFilter: descriptor.minFilter,
            magFilter: descriptor.magFilter,
            mipFilter: descriptor.mipFilter,
            sAddressMode: descriptor.sAddressMode,
            tAddressMode: descriptor.tAddressMode,
            rAddressMode: descriptor.rAddressMode,
            normalizedCoordinates: descriptor.normalizedCoordinates,
            borderColor: descriptor.borderColor,
            lodAverage: descriptor.lodAverage,
            compareFunction: descriptor.compareFunction,
            supportArgumentBuffers: descriptor.supportArgumentBuffers
        )
        lodMinClamp = descriptor.lodMinClamp.bitPattern
        lodMaxClamp = descriptor.lodMaxClamp.bitPattern
        maxAnisotropy = Float(descriptor.maxAnisotropy).bitPattern
    }

    /// The key of the descriptor makeDescriptor() builds, without building it: the fields it sets, and the defaults of
    /// the ones it leaves (Debug builds check the two agree on every sampler).
    init(_ configuration: MetalSamplerConfiguration) {
        let defaults = samplerDescriptorDefaults
        miscHash = Self.miscHash(
            minFilter: configuration.minFilter,
            magFilter: configuration.magFilter,
            mipFilter: configuration.mipFilter,
            sAddressMode: configuration.sAddressMode,
            tAddressMode: configuration.tAddressMode,
            rAddressMode: configuration.rAddressMode,
            normalizedCoordinates: defaults.normalizedCoordinates,
            borderColor: defaults.borderColor,
            lodAverage: defaults.lodAverage,
            compareFunction: configuration.compareFunction,
            supportArgumentBuffers: true
        )
        lodMinClamp = configuration.lodMinClamp.bitPattern
        lodMaxClamp = configuration.lodMaxClamp.bitPattern
        maxAnisotropy = Float(configuration.maxAnisotropy).bitPattern
    }

    var wtfHash: UInt32 {
        wtfIntHash(UInt64(miscHash) | UInt64(lodMinClamp) << 32)
            ^ wtfIntHash(UInt64(lodMaxClamp) | UInt64(maxAnisotropy) << 32 ^ 0x9e37_79b9_7f4a_7c15)
    }
}

// The MTLSamplerDescriptor fields makeDescriptor() leaves at their defaults.
private struct SamplerDescriptorDefaults: Sendable {
    let normalizedCoordinates: Bool
    let borderColor: MTLSamplerBorderColor
    let lodAverage: Bool
}

private let samplerDescriptorDefaults: SamplerDescriptorDefaults = {
    let descriptor = MTLSamplerDescriptor()
    return SamplerDescriptorDefaults(
        normalizedCoordinates: descriptor.normalizedCoordinates,
        borderColor: descriptor.borderColor,
        lodAverage: descriptor.lodAverage
    )
}()

private struct PooledSamplerState {
    var strong: (any MTLSamplerState)?
    weak var weak: (any MTLSamplerState)?
    var useCount: Int
}

// Shared by every Instance's API thread (one per RemoteGPU), and a SamplerImpl can die on any thread. Lookups only, so
// the order of the table never shows.
private let samplerStates = Mutex<WTFHashMap<SamplerCacheKey, PooledSamplerState>>(WTFHashMap())

private func samplerStateHardLimit(_ device: any MTLDevice) -> Int {
    // Reserve space for other frameworks using Metal.
    min(2048, device.maxArgumentBufferSamplerCount) / 2
}

// Most programs allocate one or two Samplers and that's it. But extreme test cases, at least, can churn through
// more. We want to be robust in the face of the hard limit Metal puts on the number of MTLSamplerStates that can
// be live at the same time.
private func samplerCacheAcquire(
    _ key: SamplerCacheKey,
    _ configuration: MetalSamplerConfiguration,
    _ device: any MTLDevice
) -> (any MTLSamplerState)? {
    let state: (any MTLSamplerState)? = samplerStates.withLock { states in
        if let index = states.valueIndex(forKey: key), let existing = states.values[index].weak {
            states.modifyValue(at: index) { $0.useCount += 1 }
            return existing
        }

        let hardLimit = samplerStateHardLimit(device)
        if states.count > hardLimit {
            // Every strong reference is released before the weak ones are tested.
            for index in 0..<states.count {
                states.modifyValue(at: index) { $0.strong = nil }
            }
            // Eviction can fail because of live references from running shaders, or other refcounting
            // shenanigans. When eviction fails, we keep the live weak reference in our map to continue to track
            // our footprint relative to our hard limit.
            var evicted: [SamplerCacheKey] = []
            states.forEachInWTFOrder { key, entry in
                if entry.weak == nil {
                    evicted.append(key)
                }
            }
            for key in evicted {
                states.remove(key)
            }
        }

        // Exceeding Metal's hard limit crashes when Metal validation is enabled, so fail the shader instead.
        if states.count > hardLimit {
            return nil
        }

        guard let created = device.makeSamplerState(descriptor: configuration.makeDescriptor()) else {
            return nil
        }
        states.set(key, PooledSamplerState(strong: created, weak: created, useCount: 1))
        return created
    }
    return state
}

private func samplerCacheRelease(_ key: SamplerCacheKey, _ samplerState: any MTLSamplerState) {
    samplerStates.withLock { states in
        guard let index = states.valueIndex(forKey: key), states.values[index].weak === samplerState else {
            preconditionFailure("releasing a sampler state the pool does not hold")
        }
        if states.values[index].useCount == 1 {
            states.remove(key)
        } else {
            states.modifyValue(at: index) { $0.useCount -= 1 }
        }
    }
}
