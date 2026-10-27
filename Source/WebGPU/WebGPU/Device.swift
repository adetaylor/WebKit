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

import Foundation
import IOSurface
import Metal
import WebGPU_Internal.Adapter
import WebGPU_Internal.Device
import WebGPU_Internal.Instance
import WebGPU_Internal.Queue
import WebGPU_Internal.ShaderModule
import WebGPU_Internal.XRSubImage
import WebGPU_Private.WebGPUCpp

/// A strong reference to a C++ shell that follows the usual Swift parameter conventions.
///
/// Imported C++ reference types are passed unowned, so a function taking one retains it around the calls it makes.
/// Creation paths pass this instead, `consuming`, so that the one reference an Impl keeps is the only one made.
struct ShellReference<Shell> {
    let shell: Shell
}

typealias DeviceShell = ShellReference<WebGPU.Metal.Device>

// One per GPUDevice, owned by the C++ shell WebGPU::Metal::Device.
//
// Used only on its Instance's API thread, so deliberately not Sendable: the device observer and the Metal completed
// handlers hop back through Instance::scheduleWork, and hand their references to the shells over to the work items,
// so that the last of them is released on the API thread.
@_expose(Cxx)
final class DeviceImpl {
    private struct ErrorScope {
        let filter: WebGPU.ErrorFilter
        // The first error the scope caught; later ones are dropped.
        var error: (type: WebGPU.ErrorType, message: WTF.String)?
    }

    // nil == invalid, lost or destroyed device.
    private var metalDevice: (any MTLDevice)?
    private var lost = false
    private var destroyed = false

    private var errorScopes: [ErrorScope] = []
    private var errorReportingPaused = false

    // Handed over by the shell. Always taken out before being called: a callback can re-enter and register the next one.
    private var uncapturedErrorCallback: WebGPU.Metal.UncapturedErrorCallback?
    private var deviceLostCallback: WebGPU.Metal.DeviceLostCallback?

    @_expose(!Cxx)
    let capabilities: DeviceCapabilities
    /// The limits the encoders read, and the Metal buffer slots that follow from them.
    @_expose(!Cxx)
    let limits: EncoderLimits

    private let backingAppleGPUFamily: UInt32
    private let backingMaxVerticesPerDrawCall: UInt32
    private let shaderValidationEnabled: Bool

    private let backingPlaceholderBuffer: (any MTLBuffer)?
    private let backingPlaceholderTexture: (any MTLTexture)?
    private let backingPlaceholderDepthStencilTexture: (any MTLTexture)?

    // Keyed by HelperPipelineSlot (DeviceHelpers.swift).
    private var renderPipelineStates: [UInt8: any MTLRenderPipelineState] = [:]
    private var dispatchCallBuffer: (any MTLBuffer)?
    private var dispatchCallPipelineState: (any MTLComputePipelineState)?
    /// nopVertexFunction()'s function, once compiled (nil within when the compile failed).
    private var nopVertexFunctionCache: (any MTLFunction)?? = nil
    private var resolveTimestampsEvent: (any MTLSharedEvent)?

    private static let maxPipelines: UInt64 = 1 << (64 - 5)
    private var nextCommandEncoderId: UInt64 = 0
    private var lastPipelineLayoutId: UInt64 = 0
    private var lastPipelineId: UInt64 = 0
    private var lastBindGroupLayoutId: UInt32 = 0
    private var lastBindGroupId: UInt32 = 0
    // Pairs of bind group layout ids (low and high 32 bits) known to be compatible. Lookups only: its order never shows.
    private var bindGroupCompatibilityCache = WTFHashSet<UInt64>()
    // The staged-Impl handoff of BindGroupLayout.swift and PipelineLayout.swift: Swift stages an Impl it made, then the
    // shell's createWithStagedImpl takes it back and wraps it. Synchronous, on the API thread, never nested.
    var stagedBindGroupLayoutImpl: BindGroupLayoutImpl?
    var stagedPipelineLayoutImpl: PipelineLayoutImpl?
    var stagedRenderPipelineImpl: RenderPipelineImpl?
    var stagedComputePipelineImpl: ComputePipelineImpl?
    // The scheduler of the Instance of the device's adapter, if it had one when the device was made: the asynchronous
    // pipeline compiles hop back through it.
    private var instanceSchedulerHandle: InstanceSchedulerHandle?
    @_expose(!Cxx)
    let externalTextureImporter: ExternalTextureImporter
    /// The builders Device::createPipelineLayout and Device::createBindGroup reuse.
    @_expose(!Cxx)
    let pipelineLayoutBuilder = PipelineLayoutBuilder()
    @_expose(!Cxx)
    let bindGroupBuilder = BindGroupBuilder()
    /// The valid textures createTexture made, which destroy() destroys.
    @_expose(!Cxx)
    var textures = TextureShellList()

    // The default queue, with its Impl; C++ callers get the shell.
    private let backingDefaultQueue: WebGPU.Metal.Queue
    @_expose(!Cxx)
    let defaultQueueImpl: QueueImpl
    // The adapter also provides the Instance. A valid device has one XR sub-image, which its constructor installs. The
    // device observer is the token of the shell's macOS device-removal observer, which ~Device unregisters.
    private let backingAdapter: WebGPU.Metal.Adapter
    // Whether the Instance had a web process to attribute resources to when the device was made. The Instance's web
    // process never changes and a gone Instance never comes back, so without one nothing is ever attributed.
    private let attributesResources: Bool
    private var xrSubImages: [WebGPU.Metal.XRSubImage] = []
    private var backingDeviceObserver: (any NSObjectProtocol)?

    fileprivate init(
        metalDevice: (any MTLDevice)?,
        capabilities: borrowing WebGPU.Metal.HardwareCapabilities,
        adapter: WebGPU.Metal.Adapter,
        defaultQueue: WebGPU.Metal.Queue,
        defaultQueueImpl: QueueImpl
    ) {
        self.metalDevice = metalDevice
        backingAdapter = adapter
        attributesResources = DeviceImpl.instanceHasWebProcess(adapter)
        backingDefaultQueue = defaultQueue
        self.defaultQueueImpl = defaultQueueImpl
        externalTextureImporter = ExternalTextureImporter(metalDevice: metalDevice)
        let deviceCapabilities = DeviceCapabilities(capabilities)
        self.capabilities = deviceCapabilities
        guard let metalDevice else {
            backingAppleGPUFamily = 0
            backingMaxVerticesPerDrawCall = 0
            shaderValidationEnabled = true
            limits = .invalidDevice
            backingPlaceholderBuffer = nil
            backingPlaceholderTexture = nil
            backingPlaceholderDepthStencilTexture = nil
            return
        }
        backingAppleGPUFamily = computeAppleGPUFamily(metalDevice)
        backingMaxVerticesPerDrawCall = computeMaxCountForDevice(metalDevice)
        shaderValidationEnabled = WebGPU.Metal.isShaderValidationEnabled(metalDevice)
        limits = deviceCapabilities.validDeviceEncoderLimits
        let placeholderBuffer = makeBuffer(metalDevice, 1, .shared, .defaultCache, .default)
        DeviceImpl.setOwnerWithIdentity(placeholderBuffer, adapter)
        backingPlaceholderBuffer = placeholderBuffer
        (backingPlaceholderTexture, backingPlaceholderDepthStencilTexture) = makePlaceholderTextures(metalDevice)
    }

    // MARK: Validity and loss

    @_expose(Cxx)
    func device() -> (any MTLDevice)? {
        metalDevice
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        metalDevice != nil
    }

    @_expose(Cxx)
    func isLost() -> Bool {
        lost
    }

    @_expose(Cxx)
    func isDestroyed() -> Bool {
        destroyed
    }

    @_expose(Cxx)
    func makeInvalid() {
        metalDevice = nil
        backingDefaultQueue.makeInvalid()
    }

    // The callback runs between the adapter's invalidation and the queue's.
    @_expose(Cxx)
    func loseTheDevice(_ reason: WebGPU.DeviceLostReason) {
        metalDevice = nil
        backingAdapter.makeInvalid()
        if var callback = deviceLostCallback.take() {
            callback(reason, consuming: WebGPU.Metal.deviceLostMessage())
        }
        backingDefaultQueue.makeInvalid()
        lost = true
    }

    @_expose(Cxx)
    func destroy() {
        destroyed = true
        destroyAllTextures()
        loseTheDevice(.Destroyed)
    }

    // MARK: Callbacks. The shell hands a C++ CompletionHandler over by moving it out of `callback`, and passes
    // whether it was set (an empty handler registers nothing).

    @_expose(Cxx)
    func resolveDeviceLostPromise(_ callback: inout WebGPU.Metal.DeviceLostCallback, _ hasCallback: Bool) {
        let incoming = exchange(&callback, with: WebGPU.Metal.DeviceLostCallback())
        if var previous = deviceLostCallback.take() {
            previous(.Destroyed, consuming: WebGPU.Metal.deviceDestroyedMessage())
        }
        deviceLostCallback = hasCallback ? consume incoming : nil
        if lost {
            loseTheDevice(.Destroyed)
        } else if !backingAdapter.isValid() {
            loseTheDevice(.Unknown)
        }
    }

    @_expose(Cxx)
    func resolveUncapturedErrorEvent(_ callback: inout WebGPU.Metal.UncapturedErrorCallback, _ hasCallback: Bool) {
        let incoming = exchange(&callback, with: WebGPU.Metal.UncapturedErrorCallback())
        if var previous = uncapturedErrorCallback.take() {
            previous(false, consuming: WebGPU.Metal.OptionalError())
        }
        uncapturedErrorCallback = hasCallback ? consume incoming : nil
    }

    // Called from ~Device.
    @_expose(Cxx)
    func completeCallbacksForDestruction() {
        if var callback = deviceLostCallback.take() {
            callback(.Destroyed, consuming: WebGPU.Metal.deviceDestroyedMessage())
        }
        if var callback = uncapturedErrorCallback.take() {
            callback(false, consuming: WebGPU.Metal.OptionalError())
        }
    }

    // MARK: Error scopes

    @_expose(Cxx)
    func pushErrorScope(_ filter: WebGPU.ErrorFilter) {
        errorScopes.append(ErrorScope(filter: filter, error: nil))
    }

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-generate-an-error
    // Reported to the current error scope (https://gpuweb.github.io/gpuweb/#abstract-opdef-current-error-scope), or
    // as uncaptured when reporting is not paused and no scope with a matching filter is open.
    @_expose(Cxx)
    func generateAnError(_ filter: WebGPU.ErrorFilter, _ type: WebGPU.ErrorType, _ message: WTF.String) {
        if errorReportingPaused {
            return
        }
        if let index = errorScopes.lastIndex(where: { $0.filter == filter }) {
            if errorScopes[index].error == nil {
                errorScopes[index].error = (type: type, message: message)
            }
            return
        }
        if var callback = uncapturedErrorCallback.take() {
            callback(true, consuming: WebGPU.Metal.OptionalError(WebGPU.Error(type: type, message: message)))
        }
    }

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-generate-a-validation-error
    @_expose(!Cxx)
    func generateAValidationError(_ message: Swift.String) {
        generateAnError(.Validation, .Validation, WTF.String(message))
    }

    @_expose(!Cxx)
    func generateAValidationError(_ message: NSString) {
        generateAValidationError(message as Swift.String)
    }

    // https://gpuweb.github.io/gpuweb/#abstract-opdef-generate-an-out-of-memory-error
    @_expose(!Cxx)
    func generateAnOutOfMemoryError(_ message: Swift.String) {
        generateAnError(.OutOfMemory, .OutOfMemory, WTF.String(message))
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-poperrorscope
    // A lost device completes as a scope without errors; an empty stack fails. Without an Instance to call back on, the
    // scope's error is dropped and the callback runs now.
    @_expose(Cxx)
    func popErrorScope(_ callback: inout WebGPU.Metal.UncapturedErrorCallback, _ instance: WebGPU.Metal.Instance?) {
        var handler = exchange(&callback, with: WebGPU.Metal.UncapturedErrorCallback())
        if lost {
            handler(true, consuming: WebGPU.Metal.OptionalError())
            return
        }
        guard let scope = errorScopes.popLast() else {
            handler(false, consuming: WebGPU.Metal.OptionalError())
            return
        }
        guard let instance else {
            handler(true, consuming: WebGPU.Metal.OptionalError())
            return
        }
        let box = PendingCallback(consume handler)
        let caught = scope.error
        instance.scheduleWork(
            consuming: WebGPU.Metal.Instance.WorkItem {
                guard var handler = box.handler.take() else {
                    return
                }
                if let caught {
                    handler(false, consuming: WebGPU.Metal.OptionalError(WebGPU.Error(type: caught.type, message: caught.message)))
                } else {
                    handler(true, consuming: WebGPU.Metal.OptionalError())
                }
            }
        )
    }

    // Returns the previous value.
    @_expose(Cxx)
    func pauseErrorReporting(_ pause: Bool) -> Bool {
        let previous = errorReportingPaused
        errorReportingPaused = pause
        return previous
    }

    @_expose(!Cxx)
    func isErrorReportingPaused() -> Bool {
        errorReportingPaused
    }

    // MARK: Capabilities

    // WebGPU::Device::limits(), by value.
    @_expose(Cxx)
    func deviceLimits() -> WebGPU.Limits {
        capabilities.limits
    }

    @_expose(Cxx)
    func hasFeature(_ feature: WebGPU.FeatureName) -> Bool {
        capabilities.hasFeature(feature)
    }

    @_expose(Cxx)
    func copyFeatures(_ destination: inout WebGPU.Metal.FeatureNames) {
        for feature in capabilities.features {
            destination.append(consuming: feature)
        }
    }

    @_expose(Cxx)
    func timestampCounterSet() -> (any MTLCounterSet)? {
        capabilities.base.timestampCounterSet
    }

    @_expose(Cxx)
    func memoryBarrierLimit() -> UInt32 {
        capabilities.base.memoryBarrierLimit
    }

    @_expose(Cxx)
    func supportsNonPrivateDepthStencilTextures() -> Bool {
        capabilities.base.supportsNonPrivateDepthStencilTextures
    }

    @_expose(Cxx)
    func supportsMemorylessTextures() -> Bool {
        capabilities.base.supportsMemorylessTextures
    }

    // The slots the shader compiler puts the dynamic offsets in: the ones the encoders send them to. Only for a valid
    // device (Device::createShaderModule checks first).
    @_expose(Cxx)
    func maxBuffersPlusVertexBuffersForVertexStage() -> UInt32 {
        limits.slots.vertexDynamicOffsets.rawValue
    }

    @_expose(Cxx)
    func maxBuffersForFragmentStage() -> UInt32 {
        limits.slots.fragmentDynamicOffsets.rawValue
    }

    @_expose(Cxx)
    func maxBuffersForComputeStage() -> UInt32 {
        limits.slots.computeDynamicOffsets.rawValue
    }

    // MARK: Device-derived scalars

    @_expose(Cxx)
    func appleGPUFamily() -> UInt32 {
        backingAppleGPUFamily
    }

    @_expose(Cxx)
    func maxVerticesPerDrawCall() -> UInt32 {
        backingMaxVerticesPerDrawCall
    }

    @_expose(Cxx)
    func isShaderValidationEnabled() -> Bool {
        shaderValidationEnabled
    }

    // MARK: Resources, attributed to the web process that owns the device's Instance

    // Looks the web process up on every call: nothing is attributed once the Instance is gone.
    @_expose(Cxx)
    func setOwnerWithIdentity(_ resource: (any MTLResource)?) {
        if attributesResources {
            DeviceImpl.setOwnerWithIdentity(resource, backingAdapter)
        }
    }

    private static func instanceHasWebProcess(_ adapter: WebGPU.Metal.Adapter) -> Bool {
        let webProcessID = adapter.webProcessIdentity()
        return withExtendedLifetime(webProcessID) {
            webProcessID.sendRight() != MACH_PORT_NULL
        }
    }

    private static func setOwnerWithIdentity(_ resource: (any MTLResource)?, _ adapter: WebGPU.Metal.Adapter) {
        let webProcessID = adapter.webProcessIdentity()
        withExtendedLifetime(webProcessID) {
            let port = webProcessID.sendRight()
            guard port != MACH_PORT_NULL, let resource, resource.responds(to: setOwnerWithIdentitySelector) else {
                return
            }
            _ = resource.__setOwnerWithIdentity(port)
        }
    }

    @_expose(Cxx)
    func safeCreateBuffer(
        _ length: UInt,
        _ storageMode: MTLStorageMode,
        _ skipAttribution: Bool = false,
        _ cpuCacheMode: MTLCPUCacheMode = .defaultCache,
        _ hazardTrackingMode: MTLHazardTrackingMode = .default
    ) -> (any MTLBuffer)? {
        let buffer = metalDevice.flatMap { makeBuffer($0, length, storageMode, cpuCacheMode, hazardTrackingMode) }
        if !skipAttribution {
            setOwnerWithIdentity(buffer)
        }
        return buffer
    }

    @_expose(!Cxx)
    func safeCreateBuffer(_ length: UInt, _ skipAttribution: Bool = false) -> (any MTLBuffer)? {
        safeCreateBuffer(length, .shared, skipAttribution)
    }

    @_expose(Cxx)
    func newTextureWithDescriptor(_ descriptor: MTLTextureDescriptor, _ ioSurface: IOSurfaceRef?, _ plane: UInt) -> (any MTLTexture)? {
        let texture =
            if let ioSurface {
                metalDevice?.makeTexture(descriptor: descriptor, iosurface: ioSurface, plane: Int(clamping: plane))
            } else {
                metalDevice?.makeTexture(descriptor: descriptor)
            }
        setOwnerWithIdentity(texture)
        return texture
    }

    // MARK: Placeholder resources

    @_expose(Cxx)
    func placeholderBuffer() -> (any MTLBuffer)? {
        backingPlaceholderBuffer
    }

    @_expose(Cxx)
    func placeholderTexture(_ depthOrStencil: Bool) -> (any MTLTexture)? {
        depthOrStencil ? backingPlaceholderDepthStencilTexture : backingPlaceholderTexture
    }

    // MARK: Lazily created helpers, built in DeviceHelpers.swift

    func cachedRenderPipelineState(_ slot: UInt8) -> (any MTLRenderPipelineState)? {
        renderPipelineStates[slot]
    }

    func setCachedRenderPipelineState(_ slot: UInt8, _ state: (any MTLRenderPipelineState)?) {
        renderPipelineStates[slot] = state
    }

    func cachedDispatchCallBuffer() -> (any MTLBuffer)? {
        dispatchCallBuffer
    }

    func setCachedDispatchCallBuffer(_ buffer: (any MTLBuffer)?) {
        dispatchCallBuffer = buffer
    }

    func cachedDispatchCallPipelineState() -> (any MTLComputePipelineState)? {
        dispatchCallPipelineState
    }

    func setCachedDispatchCallPipelineState(_ state: (any MTLComputePipelineState)?) {
        dispatchCallPipelineState = state
    }

    // The vertex function of CommandEncoder's clear passes, compiled once per device.
    @_expose(!Cxx)
    func nopVertexFunction() -> (any MTLFunction)? {
        if let nopVertexFunctionCache {
            return nopVertexFunctionCache
        }
        let function = compileNopVertexFunction(device())
        nopVertexFunctionCache = .some(function)
        return function
    }

    // Not created on a lost device; once created it outlives the loss.
    @_expose(Cxx)
    func resolveTimestampsSharedEvent() -> (any MTLSharedEvent)? {
        if resolveTimestampsEvent == nil {
            resolveTimestampsEvent = metalDevice?.makeSharedEvent()
        }
        return resolveTimestampsEvent
    }

    // MARK: Object identifiers

    func takeCommandEncoderId() -> UInt64 {
        defer { nextCommandEncoderId &+= 1 }
        return nextCommandEncoderId
    }

    func pipelineLayoutIdsExhausted() -> Bool {
        lastPipelineLayoutId == UInt64.max
    }

    func takePipelineLayoutId() -> UInt64 {
        lastPipelineLayoutId += 1
        return lastPipelineLayoutId
    }

    func pipelineIdsExhausted() -> Bool {
        lastPipelineId == Self.maxPipelines
    }

    func takePipelineId() -> UInt64 {
        lastPipelineId += 1
        return lastPipelineId
    }

    func bindGroupLayoutIdsExhausted() -> Bool {
        lastBindGroupLayoutId == UInt32.max
    }

    func takeBindGroupLayoutId() -> UInt32 {
        lastBindGroupLayoutId += 1
        return lastBindGroupLayoutId
    }

    func bindGroupIdsExhausted() -> Bool {
        lastBindGroupId == UInt32.max
    }

    func takeBindGroupId() -> UInt32 {
        lastBindGroupId += 1
        return lastBindGroupId
    }

    // MARK: Bind group layout compatibility cache

    private static func layoutPairKey(_ layoutA: UInt32, _ layoutB: UInt32) -> UInt64 {
        UInt64(layoutA) | (UInt64(layoutB) << 32)
    }

    func isCachedCompatible(_ layoutA: UInt32, _ layoutB: UInt32) -> Bool {
        layoutA != 0 && layoutB != 0 && bindGroupCompatibilityCache.contains(Self.layoutPairKey(layoutA, layoutB))
    }

    func setCachedCompatible(_ layoutA: UInt32, _ layoutB: UInt32) {
        bindGroupCompatibilityCache.add(Self.layoutPairKey(layoutA, layoutB))
    }

    func removeCachedBindGroupLayout(_ layout: UInt32) {
        if layout == 0 {
            return
        }
        var keysToRemove: [UInt64] = []
        bindGroupCompatibilityCache.forEachKeyInWTFOrder { key in
            if UInt32(truncatingIfNeeded: key) == layout || UInt32(truncatingIfNeeded: key >> 32) == layout {
                keysToRemove.append(key)
            }
        }
        for key in keysToRemove {
            bindGroupCompatibilityCache.remove(key)
        }
    }

    // MARK: Encoder support

    private func destroyAllTextures() {
        let liveTextures = textures.values
        textures.removeAll()
        for texture in liveTextures where !texture.isDestroyed() {
            texture.destroy()
        }
    }

    // MARK: Staged Impls (see stagedBindGroupLayoutImpl)

    @_expose(Cxx)
    func takeStagedBindGroupLayoutImpl() -> BindGroupLayoutImpl {
        guard let impl = stagedBindGroupLayoutImpl else {
            preconditionFailure("No staged BindGroupLayoutImpl")
        }
        stagedBindGroupLayoutImpl = nil
        return impl
    }

    @_expose(Cxx)
    func takeStagedPipelineLayoutImpl() -> PipelineLayoutImpl {
        guard let impl = stagedPipelineLayoutImpl else {
            preconditionFailure("No staged PipelineLayoutImpl")
        }
        stagedPipelineLayoutImpl = nil
        return impl
    }

    @_expose(Cxx)
    func takeStagedRenderPipelineImpl() -> RenderPipelineImpl {
        guard let impl = stagedRenderPipelineImpl else {
            preconditionFailure("No staged RenderPipelineImpl")
        }
        stagedRenderPipelineImpl = nil
        return impl
    }

    @_expose(Cxx)
    func takeStagedComputePipelineImpl() -> ComputePipelineImpl {
        guard let impl = stagedComputePipelineImpl else {
            preconditionFailure("No staged ComputePipelineImpl")
        }
        stagedComputePipelineImpl = nil
        return impl
    }

    // MARK: The Instance's scheduler

    @_expose(Cxx)
    func setInstanceSchedulerHandle(_ handle: InstanceSchedulerHandle) {
        instanceSchedulerHandle = handle
    }

    /// Alive whenever the Instance is.
    @_expose(!Cxx)
    func instanceScheduler() -> InstanceScheduler? {
        instanceSchedulerHandle?.liveScheduler()
    }

    // MARK: Default queue, adapter, XR sub-image, device observer (the helper pipelines are in DeviceHelpers.swift)

    @_expose(Cxx)
    func defaultQueue() -> WebGPU.Metal.Queue {
        backingDefaultQueue
    }

    @_expose(Cxx)
    func adapter() -> WebGPU.Metal.Adapter {
        backingAdapter
    }

    @_expose(Cxx)
    func installXRSubImage(_ subImage: WebGPU.Metal.XRSubImage) {
        xrSubImages = [subImage]
    }

    @_expose(Cxx)
    func hasXRSubImage() -> Bool {
        !xrSubImages.isEmpty
    }

    // Only when hasXRSubImage().
    @_expose(Cxx)
    func xrSubImage() -> WebGPU.Metal.XRSubImage {
        xrSubImages[0]
    }

    @_expose(Cxx)
    func setDeviceObserver(_ observer: (any NSObjectProtocol)?) {
        backingDeviceObserver = observer
    }

    @_expose(Cxx)
    func deviceObserver() -> (any NSObjectProtocol)? {
        backingDeviceObserver
    }
}

// A C++ CompletionHandler waiting in a work item; whoever runs first takes it.
private final class PendingCallback<Handler: ~Copyable> {
    var handler: Handler?

    init(_ handler: consuming Handler) {
        self.handler = consume handler
    }
}

private let setOwnerWithIdentitySelector = NSSelectorFromString("setOwnerWithIdentity:")

private func makeBuffer(
    _ metalDevice: any MTLDevice,
    _ length: UInt,
    _ storageMode: MTLStorageMode,
    _ cpuCacheMode: MTLCPUCacheMode,
    _ hazardTrackingMode: MTLHazardTrackingMode
) -> (any MTLBuffer)? {
    let options = MTLResourceOptions(
        rawValue: (cpuCacheMode.rawValue << UInt(MTLResourceCPUCacheModeShift))
            | (storageMode.rawValue << UInt(MTLResourceStorageModeShift))
            | (hazardTrackingMode.rawValue << UInt(MTLResourceHazardTrackingModeShift))
    )
    return metalDevice.makeBuffer(length: Int(clamping: max(1, length)), options: options)
}

private func hasUnifiedMemory(_ metalDevice: any MTLDevice) -> Bool {
    #if arch(x86_64)
    false
    #else
    metalDevice.hasUnifiedMemory
    #endif
}

#if WTF_PLATFORM_MAC
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "Managed storage is still required on discrete-memory Macs")
#endif
private let managedStorageMode: MTLStorageMode = .managed
#endif

private func makePlaceholderTextures(_ metalDevice: any MTLDevice) -> ((any MTLTexture)?, (any MTLTexture)?) {
    let descriptor = MTLTextureDescriptor()
    descriptor.width = 1
    descriptor.height = 1
    descriptor.mipmapLevelCount = 1
    descriptor.pixelFormat = .bgra8Unorm
    descriptor.textureType = .type2D
    #if WTF_PLATFORM_MAC
    descriptor.storageMode = hasUnifiedMemory(metalDevice) ? .shared : managedStorageMode
    #else
    descriptor.storageMode = .shared
    #endif
    descriptor.usage = [.shaderRead, .renderTarget]
    let texture = metalDevice.makeTexture(descriptor: descriptor)
    descriptor.pixelFormat = .depth32Float_stencil8
    descriptor.storageMode = .private
    return (texture, metalDevice.makeTexture(descriptor: descriptor))
}

private func computeMaxCountForDevice(_ metalDevice: any MTLDevice) -> UInt32 {
    #if HAVE_METAL_FAMILY_9
    if metalDevice.supportsFamily(.apple9) {
        return 3 << 30
    }
    #endif
    if metalDevice.supportsFamily(mac2Family) {
        return 3 << 30
    }
    return 2 << 30
}

private func computeAppleGPUFamily(_ metalDevice: any MTLDevice) -> UInt32 {
    #if HAVE_METAL_FAMILY_9
    if metalDevice.supportsFamily(.apple9) {
        return 9
    }
    #endif
    #if HAVE_METAL_FAMILY_8
    if metalDevice.supportsFamily(.apple8) {
        return 8
    }
    #endif
    if metalDevice.supportsFamily(.apple7) {
        return 7
    }
    if metalDevice.supportsFamily(.apple6) {
        return 6
    }
    if metalDevice.supportsFamily(.apple5) {
        return 5
    }
    if metalDevice.supportsFamily(.apple4) {
        return 4
    }
    return 0xFF
}

// An invalid device is made with a nil MTLDevice and `HardwareCapabilities { }`.
@_expose(Cxx)
func makeDeviceImpl(
    _ metalDevice: (any MTLDevice)?,
    _ capabilities: borrowing WebGPU.Metal.HardwareCapabilities,
    _ adapter: WebGPU.Metal.Adapter,
    _ defaultQueue: WebGPU.Metal.Queue,
    _ defaultQueueImpl: QueueImpl
) -> DeviceImpl {
    DeviceImpl(
        metalDevice: metalDevice,
        capabilities: capabilities,
        adapter: adapter,
        defaultQueue: defaultQueue,
        defaultQueueImpl: defaultQueueImpl
    )
}
