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
@_implementationOnly import WebGPU_Internal.Adapter
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.Instance
@_implementationOnly import WebGPU_Internal.Queue
@_implementationOnly import WebGPU_Internal.ShaderModule
import WebGPU_Private.WebGPUCpp

// https://gpuweb.github.io/gpuweb/#gpudevice
//
// Used only on its Instance's API thread, so deliberately not Sendable: the device observer and the Metal completed
// handlers hop back through the Instance's scheduler, and hand their references to the device over to the work items,
// so that the last of them is released on the API thread.
@_expose(Cxx)
@_spi(WebKitGPU)
public final class DeviceImpl: GPUObjectReference {
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

    // Always taken out before being called: a callback can re-enter and register the next one.
    private var uncapturedErrorCallback: ((Bool, CaughtError?) -> Void)?
    private var deviceLostCallback: ((WebGPU.DeviceLostReason, WTF.String) -> Void)?

    @_expose(!Cxx)
    let capabilities: DeviceCapabilities
    /// The limits the encoders read, and the Metal buffer slots that follow from them.
    let encoderLimits: EncoderLimits

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
    // The scheduler of the Instance of the device's adapter, if it had one when the device was made: the asynchronous
    // pipeline compiles hop back through it.
    private let instanceSchedulerHandle: InstanceSchedulerHandle?
    // The Instance of the device's adapter, if it had one when the device was made.
    @_expose(!Cxx)
    private(set) weak var instanceImpl: InstanceImpl?
    @_expose(!Cxx)
    let externalTextureImporter: ExternalTextureImporter
    /// The builders Device::createPipelineLayout and Device::createBindGroup reuse.
    @_expose(!Cxx)
    let pipelineLayoutBuilder = PipelineLayoutBuilder()
    @_expose(!Cxx)
    let bindGroupBuilder = BindGroupBuilder()
    /// The valid textures createTexture made, which destroy() destroys.
    @_expose(!Cxx)
    var textures = WeakImplList<TextureImpl>()

    @_expose(!Cxx)
    let defaultQueueImpl: QueueImpl
    // The adapter also provides the Instance. A valid device has one XR sub-image. The device observer is the token of
    // the macOS device-removal observer, which deinit unregisters.
    private let backingAdapter: WebGPU.Metal.Adapter
    private let adapterImpl: AdapterImpl
    // Whether the Instance had a web process to attribute resources to when the device was made. The Instance's web
    // process never changes and a gone Instance never comes back, so without one nothing is ever attributed.
    private let attributesResources: Bool
    @_expose(!Cxx)
    private(set) var xrSubImageImpl: XRSubImageImpl?
    // The debug encoder timestamps: each command buffer's counter sample buffers until its last encoder ends, then the
    // buffers they were resolved into until it completes. The command buffers are weak keys.
    private let sampleCounterBuffers = NSMapTable<AnyObject, NSMutableArray>.weakToStrongObjects()
    private let resolvedSampleCounterBuffers = NSMapTable<AnyObject, NSMutableArray>.weakToStrongObjects()
    private var backingDeviceObserver: (any NSObjectProtocol)?

    fileprivate init(
        metalDevice: (any MTLDevice)?,
        capabilities: borrowing WebGPU.Metal.HardwareCapabilities,
        adapter: WebGPU.Metal.Adapter,
        adapterImpl: AdapterImpl,
        defaultQueue: (any MTLCommandQueue)?
    ) {
        self.metalDevice = metalDevice
        backingAdapter = adapter
        self.adapterImpl = adapterImpl
        instanceImpl = adapterImpl.instanceImpl
        instanceSchedulerHandle = adapterImpl.instanceImpl != nil ? adapterImpl.instanceSchedulerHandle : nil
        attributesResources = DeviceImpl.instanceHasWebProcess(adapter)
        defaultQueueImpl = defaultQueue.map { makeQueueImpl($0) } ?? makeInvalidQueueImpl()
        externalTextureImporter = ExternalTextureImporter(metalDevice: metalDevice)
        let deviceCapabilities = DeviceCapabilities(capabilities)
        self.capabilities = deviceCapabilities
        guard let metalDevice else {
            backingAppleGPUFamily = 0
            backingMaxVerticesPerDrawCall = 0
            shaderValidationEnabled = true
            encoderLimits = .invalidDevice
            backingPlaceholderBuffer = nil
            backingPlaceholderTexture = nil
            backingPlaceholderDepthStencilTexture = nil
            defaultQueueImpl.deviceImpl = self
            defaultQueueImpl.setSchedulerHandle(instanceSchedulerHandle)
            return
        }
        backingAppleGPUFamily = computeAppleGPUFamily(metalDevice)
        backingMaxVerticesPerDrawCall = computeMaxCountForDevice(metalDevice)
        shaderValidationEnabled = WebGPU.Metal.isShaderValidationEnabled(metalDevice)
        encoderLimits = deviceCapabilities.validDeviceEncoderLimits
        let placeholderBuffer = makeBuffer(metalDevice, 1, .shared, .defaultCache, .default)
        DeviceImpl.setOwnerWithIdentity(placeholderBuffer, adapter)
        backingPlaceholderBuffer = placeholderBuffer
        (backingPlaceholderTexture, backingPlaceholderDepthStencilTexture) = makePlaceholderTextures(metalDevice)
        defaultQueueImpl.deviceImpl = self
        defaultQueueImpl.setSchedulerHandle(instanceSchedulerHandle)
        xrSubImageImpl = makeXRSubImageImpl()
    }

    deinit {
        if let backingDeviceObserver {
            WebGPU.Metal.removeDeviceObserver(backingDeviceObserver)
        }
        completeCallbacksForDestruction()
    }

    // MARK: Validity and loss

    @_expose(Cxx)
    func device() -> (any MTLDevice)? {
        metalDevice
    }

    public func isValid() -> Bool {
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
        defaultQueueImpl.makeInvalid()
    }

    // The callback runs between the adapter's invalidation and the queue's.
    @_expose(Cxx)
    func loseTheDevice(_ reason: WebGPU.DeviceLostReason) {
        metalDevice = nil
        adapterImpl.makeInvalid()
        if let callback = deviceLostCallback.take() {
            callback(reason, WebGPU.Metal.deviceLostMessage())
        }
        defaultQueueImpl.makeInvalid()
        lost = true
    }

    public func destroy() {
        destroyed = true
        destroyAllTextures()
        loseTheDevice(.Destroyed)
    }

    // MARK: Callbacks

    // resolveDeviceLostPromise's callback; nil registers nothing.
    @_expose(!Cxx)
    func setDeviceLostCallback(_ callback: ((WebGPU.DeviceLostReason, WTF.String) -> Void)?) {
        if let previous = deviceLostCallback.take() {
            previous(.Destroyed, WebGPU.Metal.deviceDestroyedMessage())
        }
        deviceLostCallback = callback
        if lost {
            loseTheDevice(.Destroyed)
        } else if !adapterImpl.isValid() {
            loseTheDevice(.Unknown)
        }
    }

    // resolveUncapturedErrorEvent's callback; nil registers nothing.
    @_expose(!Cxx)
    func setUncapturedErrorCallback(_ callback: ((Bool, CaughtError?) -> Void)?) {
        if let previous = uncapturedErrorCallback.take() {
            previous(false, nil)
        }
        uncapturedErrorCallback = callback
    }

    private func completeCallbacksForDestruction() {
        if let callback = deviceLostCallback.take() {
            callback(.Destroyed, WebGPU.Metal.deviceDestroyedMessage())
        }
        if let callback = uncapturedErrorCallback.take() {
            callback(false, nil)
        }
    }

    // MARK: Error scopes

    public func pushErrorScope(_ filter: WebGPU.ErrorFilter) {
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
        if let callback = uncapturedErrorCallback.take() {
            callback(true, (type: type, message: message))
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
    // `callback` gets whether the scope was popped (or the device is lost) and the error the scope caught. A lost device
    // completes as a scope without errors; an empty stack fails. Without an Instance to call back on, the scope's error
    // is dropped and the callback runs now.
    @_expose(!Cxx)
    func popErrorScopeCaughtError(_ callback: @escaping (Bool, CaughtError?) -> Void) {
        if lost {
            callback(true, nil)
            return
        }
        guard let scope = errorScopes.popLast() else {
            callback(false, nil)
            return
        }
        guard instanceImpl != nil else {
            callback(true, nil)
            return
        }
        let caught = scope.error
        scheduleWork {
            if let caught {
                callback(false, caught)
            } else {
                callback(true, nil)
            }
        }
    }

    // Runs `work` in a later work item on the API thread, or now, without the Instance to schedule it.
    @_expose(!Cxx)
    func scheduleWork(_ work: @escaping () -> Void) {
        guard instanceImpl != nil, let instanceSchedulerHandle else {
            return work()
        }
        APIThreadWork<Void> { _ in work() }.schedule((), on: instanceSchedulerHandle)
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
    func deviceLimits() -> WebGPU.Limits {
        capabilities.limits
    }

    @_expose(Cxx)
    func hasFeature(_ feature: WebGPU.FeatureName) -> Bool {
        capabilities.hasFeature(feature)
    }

    func copyFeatures(_ destination: inout WebGPU.Metal.FeatureNames) {
        for feature in capabilities.features {
            destination.append(consuming: feature)
        }
    }

    @_expose(!Cxx)
    var featureList: [WebGPU.FeatureName] {
        capabilities.features
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
    func maxBuffersPlusVertexBuffersForVertexStage() -> UInt32 {
        encoderLimits.slots.vertexDynamicOffsets.rawValue
    }

    func maxBuffersForFragmentStage() -> UInt32 {
        encoderLimits.slots.fragmentDynamicOffsets.rawValue
    }

    func maxBuffersForComputeStage() -> UInt32 {
        encoderLimits.slots.computeDynamicOffsets.rawValue
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

    // MARK: Debug encoder timestamps (DebugToggles.enableEncoderTimestamps())

    // A counter sample buffer of `timestampCount` samples for a pass of `commandBuffer`, tracked for it.
    @_expose(!Cxx)
    func timestampsBuffer(_ commandBuffer: (any MTLCommandBuffer)?, _ timestampCount: Int) -> (any MTLCounterSampleBuffer)? {
        #if WTF_PLATFORM_WATCHOS
        return nil
        #else
        guard let metalDevice else {
            return nil
        }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.sampleCount = timestampCount
        descriptor.storageMode = .shared
        descriptor.counterSet = timestampCounterSet()
        let buffer: any MTLCounterSampleBuffer
        do {
            buffer = try metalDevice.makeCounterSampleBuffer(descriptor: descriptor)
        } catch {
            WebGPU.Metal.logAlways("newCounterSamplerBufferWithDescriptor failed \(error.localizedDescription)")
            return nil
        }
        trackTimestampsBuffer(commandBuffer, buffer)
        return buffer
        #endif
    }

    // Records a counter sample buffer of `commandBuffer`, to resolve when its last encoder ends.
    @_expose(!Cxx)
    func trackTimestampsBuffer(_ commandBuffer: (any MTLCommandBuffer)?, _ counterSampleBuffer: any MTLCounterSampleBuffer) {
        guard let commandBuffer else {
            return
        }
        if let sampleBuffers = sampleCounterBuffers.object(forKey: commandBuffer) {
            sampleBuffers.add(counterSampleBuffer)
        } else {
            sampleCounterBuffers.setObject(NSMutableArray(object: counterSampleBuffer), forKey: commandBuffer)
        }
    }

    // Resolves the counter sample buffers tracked for `commandBuffer` into buffers that are logged when it completes.
    @_expose(!Cxx)
    func resolveTimestampsForBuffer(_ commandBuffer: (any MTLCommandBuffer)?) {
        guard enableEncoderTimestamps(), let commandBuffer, let sampleBuffers = sampleCounterBuffers.object(forKey: commandBuffer) else {
            return
        }
        sampleCounterBuffers.removeObject(forKey: commandBuffer)
        for case let sampleBuffer as any MTLCounterSampleBuffer in sampleBuffers {
            let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()
            let timestampCount = sampleBuffer.sampleCount
            guard let counterDataBuffer = safeCreateBuffer(UInt(MemoryLayout<MTLCounterResultTimestamp>.size) * UInt(timestampCount)) else {
                blitCommandEncoder?.endEncoding()
                continue
            }
            blitCommandEncoder?.resolveCounters(sampleBuffer, range: 0..<timestampCount, destinationBuffer: counterDataBuffer, destinationOffset: 0)
            blitCommandEncoder?.endEncoding()
            let resolvedBuffers: NSMutableArray
            if let existing = resolvedSampleCounterBuffers.object(forKey: commandBuffer) {
                existing.add(counterDataBuffer)
                resolvedBuffers = existing
            } else {
                resolvedBuffers = NSMutableArray(object: counterDataBuffer)
                resolvedSampleCounterBuffers.setObject(resolvedBuffers, forKey: commandBuffer)
            }
            let forget = APIThreadWork<Void> { [weak self, weak commandBuffer] _ in
                if let commandBuffer {
                    self?.resolvedSampleCounterBuffers.removeObject(forKey: commandBuffer)
                }
            }
            let scheduler = instanceSchedulerHandle
            WebGPU.Metal.logTimestampsWhenCompleted(commandBuffer, resolvedBuffers) {
                forget.schedule((), on: scheduler)
            }
        }
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
            texture.destroyAndReleaseHolders()
        }
    }

    // MARK: The Instance's scheduler

    // Keeps the device alive in its Instance until the command buffer is gone.
    @_expose(!Cxx)
    func retainUntilCompleted(_ commandBuffer: (any MTLCommandBuffer)?) {
        instanceImpl?.retainDevice(self, commandBuffer)
    }

    // What the Metal handlers schedule their API-thread work through.
    @_expose(!Cxx)
    func schedulerHandle() -> InstanceSchedulerHandle? {
        instanceSchedulerHandle
    }

    /// Alive whenever the Instance is.
    @_expose(!Cxx)
    func instanceScheduler() -> InstanceScheduler? {
        instanceSchedulerHandle?.liveScheduler()
    }

    // MARK: Default queue, adapter, XR sub-image, device observer (the helper pipelines are in DeviceHelpers.swift)

    @_expose(Cxx)
    func adapter() -> WebGPU.Metal.Adapter {
        backingAdapter
    }

    // The macOS device-removal observer: any notification about the device loses it.
    fileprivate func observeDeviceRemoval() {
        #if WTF_PLATFORM_MAC
        guard let metalDevice else {
            return
        }
        let scheduler = instanceSchedulerHandle
        let lose = APIThreadWork<Void> { [weak self] _ in
            guard let self, self.metalDevice != nil else {
                return
            }
            self.loseTheDevice(.Unknown)
        }
        backingDeviceObserver = WebGPU.Metal.addDeviceObserver(metalDevice) {
            lose.schedule((), on: scheduler)
        }
        #endif
    }
}

// An error that an error scope caught, or an uncaptured one.
typealias CaughtError = (type: WebGPU.ErrorType, message: WTF.String)

// https://gpuweb.github.io/gpuweb/#gpuerror
@_spi(WebKitGPU)
public struct GPUError {
    public let type: WebGPU.ErrorType
    public let message: Swift.String
}

// A device that isn't kept alive.
@_spi(WebKitGPU)
public final class DeviceWeakReference {
    private weak var impl: DeviceImpl?

    init(_ impl: DeviceImpl) {
        self.impl = impl
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-destroy, if the device is still alive.
    public func destroy() {
        impl?.destroy()
    }
}

@_spi(WebKitGPU)
public typealias DeviceReference = DeviceImpl

// The operations of a device for Swift callers that create nothing.
@_spi(WebKitGPU)
extension DeviceImpl {
    // What the callers used when it had a shell too.
    var impl: DeviceImpl {
        self
    }

    // https://immersive-web.github.io/WebXR-WebGPU-Binding/#gpuxrbinding
    public func createXRBinding() -> XRBindingReference {
        XRBindingReference(self)
    }

    // The device, without keeping it alive: work in flight can keep it alive after Swift lets go of it.
    public var weakReference: DeviceWeakReference {
        DeviceWeakReference(impl)
    }

    public var features: [WebGPU.FeatureName] {
        impl.featureList
    }

    public var limits: WebGPU.Limits {
        impl.deviceLimits()
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-poperrorscope: whether the scope was popped, and its error.
    public func popErrorScope(_ completion: @escaping (Bool, GPUError?) -> Void) {
        popErrorScopeCaughtError { success, error in
            completion(success, error.map { GPUError(type: $0.type, message: stringNilIfEmpty($0.message) ?? "") })
        }
    }

    // The next uncaptured error, or false without one when another callback replaces this one or the device goes.
    public func resolveUncapturedErrorEvent(_ completion: @escaping (Bool, GPUError?) -> Void) {
        setUncapturedErrorCallback { success, error in
            completion(success, error.map { GPUError(type: $0.type, message: stringNilIfEmpty($0.message) ?? "") })
        }
    }

    public func resolveDeviceLostPromise(_ completion: @escaping (WebGPU.DeviceLostReason) -> Void) {
        setDeviceLostCallback { reason, _ in
            completion(reason)
        }
    }

    // Completes the callbacks that resolveDeviceLostPromise() and resolveUncapturedErrorEvent() hold, and holds none.
    public func completeHeldCallbacks() {
        setDeviceLostCallback(nil)
        setUncapturedErrorCallback(nil)
    }

    public func pauseAllErrorReporting(_ pause: Bool) {
        _ = impl.pauseErrorReporting(pause)
    }

    // Device::setLabel: MTLDevices are process-global, so two contexts' labels would fight each other.
    public func setLabel(_ label: Swift.String?) {
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-queue
    public var queue: QueueReference {
        impl.defaultQueueImpl
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

// https://gpuweb.github.io/gpuweb/#dom-gpuadapter-requestdevice, once the adapter has accepted the request: an invalid
// device when Metal gives it no queue.
func makeDevice(
    _ metalDevice: (any MTLDevice)?,
    _ label: WTF.String,
    _ capabilities: borrowing WebGPU.Metal.HardwareCapabilities,
    _ adapter: WebGPU.Metal.Adapter,
    _ adapterImpl: AdapterImpl
) -> DeviceImpl {
    guard let commandQueue = makeDefaultCommandQueue(metalDevice, label) else {
        return makeInvalidDevice(adapter, adapterImpl)
    }
    let device = DeviceImpl(
        metalDevice: metalDevice,
        capabilities: capabilities,
        adapter: adapter,
        adapterImpl: adapterImpl,
        defaultQueue: commandQueue
    )
    device.observeDeviceRemoval()
    registerForFrameCapture(metalDevice)
    return device
}

private func makeInvalidDevice(_ adapter: WebGPU.Metal.Adapter, _ adapterImpl: AdapterImpl) -> DeviceImpl {
    let device = DeviceImpl(
        metalDevice: nil,
        capabilities: WebGPU.Metal.HardwareCapabilities(),
        adapter: adapter,
        adapterImpl: adapterImpl,
        defaultQueue: nil
    )
    if !adapterImpl.isValid() {
        device.makeInvalid()
    }
    return device
}
