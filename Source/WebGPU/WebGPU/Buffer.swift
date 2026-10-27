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

private import CxxStdlib
import Metal
import WebGPU_Internal.Adapter
import WebGPU_Internal.BindGroup
import WebGPU_Internal.BindGroupLayout
import WebGPU_Internal.Buffer
import WebGPU_Internal.ComputePipeline
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Internal.ExternalTexture
import WebGPU_Internal.PipelineLayout
import WebGPU_Internal.PresentationContext
import WebGPU_Internal.Queue
import WebGPU_Internal.RenderBundle
import WebGPU_Internal.RenderBundleEncoder
import WebGPU_Internal.RenderPipeline
import WebGPU_Internal.Sampler
import WebGPU_Internal.ShaderModule
import WebGPU_Internal.XRBinding
import WebGPU_Internal.XRProjectionLayer
import WebGPU_Internal.XRSubImage
import WebGPU_Internal.XRView
import WebGPU_Private.CxxBridgingPublic
import WebGPU_Private.WebGPUCpp

struct DrawIndexValidationEntry {
    let vertexCount: UInt32
    let indexContentsGeneration: UInt64
}

/// A mapAsync request that passed validation: `range` lies within the buffer. `serial` tells this request's
/// completion apart from the completion of an earlier request that unmap() or destroy() abandoned.
struct BufferMapRequest {
    let serial: UInt64
    /// [[map mode]]: recorded for the specification, not read.
    let modeBits: UInt8
    let range: Range<UInt64>

    /// nil unless [offset, offset + size) fits in `limit` bytes.
    init?(serial: UInt64, modeBits: UInt8, offset: UInt64, size: UInt64, limit: UInt64) {
        let (end, overflowed) = offset.addingReportingOverflow(size)
        guard !overflowed, end <= limit else {
            return nil
        }
        self.serial = serial
        self.modeBits = modeBits
        self.range = offset..<end
    }
}

/// https://gpuweb.github.io/gpuweb/#buffer-internals-state. [[mapping]] exists only in the cases that have one, and a
/// pending map remembers which request it is waiting for.
enum BufferMapState {
    case unmapped
    case pending(BufferMapRequest)
    case mapped(BufferMapRequest)
    case mappedAtCreation(Range<UInt64>)
    case destroyed

    /// WebGPU::Metal::Buffer::State, for C++.
    var cxxState: WebGPU.Metal.Buffer.State {
        switch self {
        case .unmapped: .Unmapped
        case .pending: .MappingPending
        case .mapped: .Mapped
        case .mappedAtCreation: .MappedAtCreation
        case .destroyed: .Destroyed
        }
    }

    /// What unmap() undoes: a pending map or a mapping.
    var hasMapping: Bool {
        switch self {
        case .pending, .mapped, .mappedAtCreation: true
        case .unmapped, .destroyed: false
        }
    }

    /// Whether an encoder that starts using the buffer counts it as mapped: every state but unmapped (a destroyed
    /// buffer also makes the submit invalid).
    var countsAsMappedForNewEncoders: Bool {
        switch self {
        case .unmapped: false
        case .pending, .mapped, .mappedAtCreation, .destroyed: true
        }
    }

    /// [[mapping]]: the range getMappedRange may hand out.
    var mapping: Range<UInt64>? {
        switch self {
        case .mapped(let request): request.range
        case .mappedAtCreation(let range): range
        case .unmapped, .pending, .destroyed: nil
        }
    }
}

// https://gpuweb.github.io/gpuweb/#buffer-interface
// The state of a GPUBuffer, owned by the C++ shell WebGPU::Metal::Buffer. Used only on the instance's API thread, so
// not Sendable.
@_expose(Cxx)
final class BufferImpl {
    private var backingBuffer: (any MTLBuffer)?
    private let initialByteSize: UInt64
    private let usageBits: UInt16
    private var mapState: BufferMapState
    // The serial of the latest mapAsync request; serials start at 1.
    private var lastMapSerial: UInt64 = 0
    // Ranges handed out since the buffer was mapped: sorted, disjoint and non-adjacent.
    private var mappedRanges: [Range<UInt64>] = []
    private let mappedAtCreation: Bool

    // Largest index values of the latest writeBuffer, and the largest ones a draw already validated.
    private var pendingMaxUInt32Index: UInt32 = 0
    private var pendingMaxUInt16Index: UInt16 = 0
    private var validatedMaxUInt32Index: UInt32 = 0
    private var validatedMaxUInt16Index: UInt16 = 0

    private var backingMustTakeSlowIndexValidationPath = false
    private var backingContentsGeneration: UInt64 = 0
    private var backingIndexContentsGeneration: UInt64 = 0
    private var indexValueUpperBoundUInt32: UInt32 = 0
    private var indexValueUpperBoundUInt16: UInt16 = 0
    // Keyed by the gpuResourceID of the indirect command buffer; 0 for draws outside one.
    private var didReadOOBByCommandBuffer: [UInt64: Bool] = [:]

    let deviceImpl: DeviceImpl
    /// The encoders that used the buffer.
    @_expose(!Cxx)
    var tracking = EncoderTracking()
    private var drawIndexedCache = WTFHashMap<DrawIndexKey, DrawIndexValidationEntry>()
    // The bind groups and render bundles that hold the buffer.
    private var bindGroupHolders = CxxBridging.BindGroupHolders()
    private var renderBundleHolders = WeakImplList<RenderBundleImpl>()
    // The encoders that skipped validating a draw with this index buffer.
    private var skippedValidationEncoders = EncoderTracking()
    // The shell that owns this Impl, for the strong references encoders and post-commit actions hold.
    private var ownerShell = CxxBridging.BufferWeakPtr()
    // Declared last, so that the device outlives the rest of the buffer.
    let device: WebGPU.Metal.Device
    @_expose(Cxx)
    func shellDevice() -> WebGPU.Metal.Device { device }

    fileprivate init(
        buffer: (any MTLBuffer)?,
        size: UInt64,
        usageBits: UInt16,
        mappedAtCreation: Bool,
        device: WebGPU.Metal.Device,
        deviceImpl: DeviceImpl
    ) {
        self.backingBuffer = buffer
        self.initialByteSize = size
        self.usageBits = usageBits
        self.mapState = mappedAtCreation ? .mappedAtCreation(0..<size) : .unmapped
        self.mappedAtCreation = mappedAtCreation
        self.deviceImpl = deviceImpl
        self.device = device
    }

    // Buffer::create, once the shell exists.
    @_expose(Cxx)
    func setShell(_ shell: WebGPU.Metal.Buffer) {
        ownerShell = CxxBridging.bufferThreadSafeWeakPtr(shell)
    }

    @_expose(Cxx)
    func buffer() -> (any MTLBuffer)? {
        backingBuffer
    }

    @_expose(Cxx)
    func initialSize() -> UInt64 {
        initialByteSize
    }

    @_expose(Cxx)
    func currentSize() -> UInt64 {
        UInt64(backingBuffer?.length ?? 0)
    }

    // Raw value of OptionSet<WebGPU::BufferUsage>.
    @_expose(Cxx)
    func usageRawValue() -> UInt16 {
        usageBits
    }

    // Raw value of WebGPU::Metal::Buffer::State.
    @_expose(Cxx)
    func stateRawValue() -> UInt8 {
        mapState.cxxState.rawValue
    }

    @_expose(Cxx)
    func isDestroyed() -> Bool {
        if case .destroyed = mapState {
            return true
        }
        return false
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        isDestroyed() || backingBuffer != nil
    }

    @_expose(Cxx)
    func setLabel(_ label: WTF.String) {
        backingBuffer?.label = CxxBridging.convertWTFStringToNSString(label) as String?
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-destroy
    @_expose(Cxx)
    func destroy() {
        if mapState.hasMapping {
            // FIXME: ASSERT() that this call doesn't fail.
            unmap()
        }

        mapState = .destroyed
        backingBuffer = deviceImpl.placeholderBuffer()
        for encoder in tracking.takeLive() {
            encoder.makeSubmitInvalid(nil)
        }

        bindGroupHolders.releaseDestroyedResourcesAndClear()
        let renderBundles = renderBundleHolders.values
        for renderBundle in renderBundles {
            renderBundle.releaseDestroyedResources()
        }
        renderBundleHolders.removeAll()
    }

    // MARK: Encoder tracking

    // Each encoder holds the buffer once, from the first use until its clearTracking().
    @_expose(!Cxx)
    func setCommandEncoder(_ encoder: CommandEncoderImpl, mayModifyBuffer: Bool) {
        let isNewEntry = !tracking.contains(encoder) && tracking.add(encoder)
        if isNewEntry, let shell = CxxBridging.protectedBuffer(ownerShell) {
            encoder.trackBuffer(shell, self)
        }
        #if arch(x86_64)
        encoder.addBuffer(backingBuffer)
        #else
        if deviceImpl.isShaderValidationEnabled() {
            encoder.addBuffer(backingBuffer)
        }
        #endif

        if isNewEntry && mapState.countsAsMappedForNewEncoders {
            encoder.incrementBufferMapCount()
        }
        if isDestroyed() {
            encoder.makeSubmitInvalid(nil)
        }
    }

    /// A destroyed buffer has nothing to release later, so it records no holder.
    @_expose(!Cxx)
    func addBindGroupHolder(_ bindGroup: WebGPU.Metal.BindGroup) {
        if isDestroyed() {
            return
        }
        bindGroupHolders.add(bindGroup)
    }

    @_expose(!Cxx)
    func addRenderBundleHolder(_ renderBundle: RenderBundleImpl) {
        if isDestroyed() {
            return
        }
        renderBundleHolders.add(renderBundle)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-mapasync
    // `rangeFits` is false when the range does not fit in size_t, which only 32-bit platforms reach. The handler is
    // moved out of `callback`. Until the queue runs it, the completion holds the shell.
    @_expose(Cxx)
    func mapAsync(
        _ shell: WebGPU.Metal.Buffer,
        _ modeBits: UInt8,
        _ rangeFits: Bool,
        _ offset: UInt64,
        _ rangeSize: UInt64,
        _ callback: inout WTF.BoolCompletionHandler
    ) {
        let handler = BoolCompletionHandlerBox(exchange(&callback, with: WTF.BoolCompletionHandler()))
        if let error = rangeFits ? errorValidatingMapAsync(modeBits, offset, rangeSize) : mapAsyncError("offset and rangeSize overflowed") {
            deviceImpl.generateAValidationError(error)
            handler.call(false)
            return
        }

        let mapRequest = beginMapping(modeBits, offset, rangeSize)

        let queue = deviceImpl.defaultQueue()
        deviceImpl.defaultQueueImpl.onSubmittedWorkDone(queue, deviceIsUsable: deviceImpl.isValid() && !deviceImpl.isLost()) { success in
            withExtendedLifetime(shell) {
                self.completeMapping(mapRequest, success)
                handler.call(success)
            }
        }
    }

    // nil when mapAsync may proceed.
    private func errorValidatingMapAsync(_ modeBits: UInt8, _ offset: UInt64, _ rangeSize: UInt64) -> NSString? {
        if !isValid() {
            return mapAsyncError("Buffer is not valid")
        }
        if offset % 8 != 0 {
            return mapAsyncError("Offset is not divisible by 8")
        }
        if rangeSize % 4 != 0 {
            return mapAsyncError("range size is not divisible by 4")
        }
        let (end, overflowed) = offset.addingReportingOverflow(rangeSize)
        if overflowed || end > currentSize() {
            return mapAsyncError("offset and rangeSize overflowed")
        }
        guard case .unmapped = mapState else {
            return mapAsyncError("state != Unmapped")
        }
        let read = WebGPU.MapMode.Read.rawValue
        let write = WebGPU.MapMode.Write.rawValue
        if modeBits != read && modeBits != write {
            return mapAsyncError("readWriteModeFlags != Read && readWriteModeFlags != Write")
        }
        if modeBits & read != 0 && !hasUsage(.MapRead) {
            return mapAsyncError("(mode & Read) && !(usage & Read)")
        }
        if modeBits & write != 0 && !hasUsage(.MapWrite) {
            return mapAsyncError("(mode & Write) && !(usage & Write)")
        }
        return nil
    }

    // Right after errorValidatingMapAsync() accepted the same arguments. Returns the request's serial, for
    // completeMapping(); 0, which no request has, if the range does not fit (errorValidatingMapAsync rejects that).
    private func beginMapping(_ modeBits: UInt8, _ offset: UInt64, _ rangeSize: UInt64) -> UInt64 {
        guard case .unmapped = mapState,
            let request = BufferMapRequest(
                serial: lastMapSerial &+ 1,
                modeBits: modeBits,
                offset: offset,
                size: rangeSize,
                limit: currentSize()
            )
        else {
            return 0
        }
        lastMapSerial = request.serial
        mapState = .pending(request)
        let encoders = tracking
        encoders.forEachLive { $0.incrementBufferMapCount() }
        return request.serial
    }

    // Runs when the queue's submitted work is done. Acts only if the request is still the pending one: an unmap() or
    // destroy() in the meantime wins, and so does the next mapAsync() after an unmap(). A failure (device loss)
    // returns the buffer to unmapped.
    private func completeMapping(_ serial: UInt64, _ success: Bool) {
        guard case .pending(let request) = mapState, request.serial == serial else {
            return
        }
        guard success else {
            unmap()
            return
        }
        mapState = .mapped(request)
        mappedRanges = []
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-getmappedrange
    // Validates and records [offset, offset + rangeSize). Returns whether the shell may return that
    // part of the contents; the shell forms the span, so no pointer is made here.
    @_expose(Cxx)
    func reserveMappedRange(_ offset: UInt64, _ rangeSize: UInt64) -> Bool {
        guard isValid(), let range = validatedMappedRange(offset, rangeSize) else {
            return false
        }
        insertMappedRange(range)
        guard let buffer = backingBuffer else {
            return false
        }
        return buffer.storageMode != .private && buffer.storageMode != .memoryless && buffer.length != 0
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-unmap
    @_expose(Cxx)
    func unmap() {
        guard mapState.hasMapping else {
            return
        }
        let encoders = tracking
        encoders.forEachLive { $0.decrementBufferMapCount() }
        indirectBufferInvalidated(nil)

        pendingMaxUInt32Index = 0
        pendingMaxUInt16Index = 0
        if let buffer = backingBuffer, bufferNeedsDidModifyRangeAfterUnmap(buffer) {
            if mappedAtCreation {
                bufferDidModifyRange(buffer, 0, UInt64(buffer.length))
            } else {
                for range in mappedRanges {
                    bufferDidModifyRange(buffer, range.lowerBound, range.upperBound - range.lowerBound)
                }
            }
        }
        mapState = .unmapped
        mappedRanges = []
    }

    @_expose(Cxx)
    func needsIndexValidation(_ maxUInt32Index: UInt32, _ maxUInt16Index: UInt16) -> Bool {
        let needsUpdate = maxUInt32Index > validatedMaxUInt32Index || maxUInt16Index > validatedMaxUInt16Index
        pendingMaxUInt32Index = maxUInt32Index
        pendingMaxUInt16Index = maxUInt16Index
        return needsUpdate
    }

    @_expose(Cxx)
    func indexBufferContentsModified(_ maxUInt32Value: UInt32, _ maxUInt16Value: UInt16) {
        backingIndexContentsGeneration += 1
        indexValueUpperBoundUInt32 = max(indexValueUpperBoundUInt32, maxUInt32Value)
        indexValueUpperBoundUInt16 = max(indexValueUpperBoundUInt16, maxUInt16Value)
    }

    @_expose(Cxx)
    func allIndexValuesBelow(_ isUInt16: Bool, _ vertexCount: UInt32) -> Bool {
        (isUInt16 ? UInt32(indexValueUpperBoundUInt16) : indexValueUpperBoundUInt32) < vertexCount
    }

    @_expose(!Cxx)
    func clearPendingIndexMaxima() {
        pendingMaxUInt32Index = 0
        pendingMaxUInt16Index = 0
    }

    // After a successful clamp pass, later writes up to these values need no invalidation.
    @_expose(!Cxx)
    func promotePendingIndexMaxima() {
        validatedMaxUInt32Index = max(validatedMaxUInt32Index, pendingMaxUInt32Index)
        validatedMaxUInt16Index = max(validatedMaxUInt16Index, pendingMaxUInt16Index)
    }

    @_expose(!Cxx)
    func invalidateIndexContents() {
        backingContentsGeneration += 1
        backingIndexContentsGeneration += 1
        indexValueUpperBoundUInt32 = .max
        indexValueUpperBoundUInt16 = .max
        validatedMaxUInt32Index = 0
        validatedMaxUInt16Index = 0
    }

    @_expose(Cxx)
    func contentsGeneration() -> UInt64 {
        backingContentsGeneration
    }

    @_expose(Cxx)
    func indexContentsGeneration() -> UInt64 {
        backingIndexContentsGeneration
    }

    @_expose(!Cxx)
    func mustTakeSlowIndexValidationPath() -> Bool {
        backingMustTakeSlowIndexValidationPath
    }

    // MARK: Draw-indexed validation cache

    /// `icbResourceID` is the indirect command buffer's gpuResourceID._impl, 0 outside one.
    @_expose(!Cxx)
    static func drawIndexKey(
        firstIndex: UInt32,
        indexCount: UInt32,
        indexType: MTLIndexType,
        primitiveOffset: UInt32,
        icbResourceID: UInt64
    ) -> DrawIndexKey {
        DrawIndexKey(
            firstIndex: firstIndex,
            indexCount: indexCount,
            primitiveOffsetWithIndexType: primitiveOffset | UInt32(truncatingIfNeeded: indexType.rawValue &<< 1),
            icbLow: UInt32(truncatingIfNeeded: icbResourceID),
            icbHigh: UInt32(truncatingIfNeeded: icbResourceID &>> 32)
        )
    }

    @_expose(!Cxx)
    func canSkipDrawIndexedValidation(_ key: DrawIndexKey, vertexCount: UInt32) -> DrawIndexValidationEntry? {
        guard let entry = drawIndexedCache.value(forKey: key), entry.indexContentsGeneration == backingIndexContentsGeneration,
            entry.vertexCount <= vertexCount
        else {
            return nil
        }
        return entry
    }

    @_expose(!Cxx)
    func drawIndexedValidated(_ key: DrawIndexKey, vertexCount: UInt32, validationGeneration: UInt64) {
        let maxCacheSize = 1_000_000
        if drawIndexedCache.count > maxCacheSize {
            drawIndexedCache.removeAll()
        }

        drawIndexedCache.set(key, DrawIndexValidationEntry(vertexCount: vertexCount, indexContentsGeneration: validationGeneration))

        promotePendingIndexMaxima()
    }

    // Buffer::drawIndexedValidated, for the completion handlers' work items. `indexTypeRawValue` is an MTLIndexType.
    @_expose(Cxx)
    func drawIndexedValidatedForShell(
        _ firstIndex: UInt32,
        _ indexCount: UInt32,
        _ vertexCount: UInt32,
        _ indexTypeRawValue: UInt32,
        _ primitiveOffset: UInt32,
        _ validationGeneration: UInt64,
        _ icbResourceID: UInt64
    ) {
        let key = DrawIndexKey(
            firstIndex: firstIndex,
            indexCount: indexCount,
            primitiveOffsetWithIndexType: primitiveOffset | (indexTypeRawValue &<< 1),
            icbLow: UInt32(truncatingIfNeeded: icbResourceID),
            icbHigh: UInt32(truncatingIfNeeded: icbResourceID &>> 32)
        )
        drawIndexedValidated(key, vertexCount: vertexCount, validationGeneration: validationGeneration)
    }

    /// Right after canSkipDrawIndexedValidation found `key`.
    ///
    /// The encoder records the cached entry's vertex count.
    @_expose(!Cxx)
    func skippedDrawIndexedValidation(_ encoder: CommandEncoderImpl, _ key: DrawIndexKey, vertexCount: UInt32) {
        _ = skippedValidationEncoders.add(encoder)
        let cachedVertexCount = drawIndexedCache.value(forKey: key)?.vertexCount ?? vertexCount
        encoder.recordSkippedDrawIndexedValidation(self, key, vertexCount: cachedVertexCount)
    }

    /// Invalidates now, and again when the encoder's command buffer is committed.
    ///
    /// Both are no-ops for a buffer without Index or Indirect usage (its pending maxima are always 0 and the invalidation
    /// returns at once), so such a buffer queues nothing.
    @_expose(!Cxx)
    func indirectBufferInvalidated(by encoder: CommandEncoderImpl) {
        if !hasUsage(.Indirect) && !hasUsage(.Index) {
            return
        }
        clearPendingIndexMaxima()
        indirectBufferInvalidated(nil)
        encoder.addCommitAction(.indirectBufferInvalidated(WeakBufferAndEncoder(buffer: self, encoder: encoder)))
    }

    @_expose(Cxx)
    func indirectBufferInvalidatedWithoutEncoder() {
        indirectBufferInvalidated(nil)
    }

    /// Validation can be skipped later only when the one encoder that skipped it is the one invalidating.
    @_expose(!Cxx)
    func indirectBufferInvalidated(_ encoder: CommandEncoderImpl?) {
        if !hasUsage(.Indirect) && !hasUsage(.Index) {
            return
        }

        let currentSize = skippedValidationEncoders.liveCount()
        if currentSize != 0 {
            let validationNotNeeded = currentSize == 1 && encoder != nil && skippedValidationEncoders.firstLive === encoder
            if !validationNotNeeded {
                backingMustTakeSlowIndexValidationPath = true
            }
        }

        drawIndexedCache.removeAll()
        invalidateIndexContents()
    }

    @_expose(!Cxx)
    func removeSkippedValidationCommandEncoder(_ encoder: CommandEncoderImpl) {
        skippedValidationEncoders.remove(encoder)
    }

    @_expose(!Cxx)
    func clearMustTakeSlowIndexValidationPath() {
        if skippedValidationEncoders.liveCount() != 0 {
            return
        }
        backingMustTakeSlowIndexValidationPath = false
    }

    /// When the indices are invalid, the GPU work in `commandBuffer` reads cleared ones, and the post-commit action
    /// writes the old ones back.
    @_expose(!Cxx)
    func takeSlowIndexValidationPath(_ commandBuffer: CommandBufferImpl, _ key: DrawIndexKey, vertexCount: UInt32) {
        guard let shell = CxxBridging.protectedBuffer(ownerShell) else {
            return
        }
        let isUInt16 = key.indexTypeRawValue == MTLIndexType.uint16.rawValue
        if let priorContents = WebGPU.Metal.takeSlowIndexValidationPath(
            shell,
            key.firstIndex,
            key.indexCount,
            isUInt16,
            key.primitiveOffset,
            vertexCount
        ) {
            commandBuffer.addPostCommitAction(.restoreIndexBufferContents(shell, self, priorContents))
        }
    }

    // MARK: Out-of-bounds reads

    @_expose(Cxx)
    func didReadOOB(_ commandBufferKey: UInt64) -> Bool {
        didReadOOBByCommandBuffer[commandBufferKey] ?? false
    }

    // Sticky: once a draw read out of bounds, it stays recorded.
    @_expose(Cxx)
    func recordReadOOB(_ commandBufferKey: UInt64, _ didRead: Bool) {
        didReadOOBByCommandBuffer[commandBufferKey] = didRead || didReadOOB(commandBufferKey)
    }

    private func hasUsage(_ usage: WebGPU.BufferUsage) -> Bool {
        usageBits & usage.rawValue != 0
    }

    private func mapAsyncError(_ message: String) -> NSString {
        "GPUBuffer.mapAsync: \(message)" as NSString
    }

    private func validatedMappedRange(_ offset: UInt64, _ rangeSize: UInt64) -> Range<UInt64>? {
        guard let mapping = mapState.mapping else {
            return nil
        }
        guard offset % 8 == 0, rangeSize % 4 == 0, offset >= mapping.lowerBound else {
            return nil
        }
        let (end, overflowed) = offset.addingReportingOverflow(rangeSize)
        guard !overflowed, end <= mapping.upperBound else {
            return nil
        }
        let range = offset..<end
        // An empty range overlaps nothing.
        guard !mappedRanges.contains(where: { $0.overlaps(range) }) else {
            return nil
        }
        return range
    }

    // Keeps mappedRanges sorted, with touching ranges merged.
    private func insertMappedRange(_ range: Range<UInt64>) {
        guard !range.isEmpty else {
            return
        }
        var merged = range
        mappedRanges.removeAll { existing in
            guard existing.lowerBound <= merged.upperBound && merged.lowerBound <= existing.upperBound else {
                return false
            }
            merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            return true
        }
        let index = mappedRanges.firstIndex { $0.lowerBound > merged.lowerBound } ?? mappedRanges.endIndex
        mappedRanges.insert(merged, at: index)
    }
}

// Device::createBuffer. https://gpuweb.github.io/gpuweb/#dom-gpudevice-createbuffer
@_expose(Cxx)
func createBufferImpl(
    _ device: WebGPU.Metal.Device,
    _ deviceImpl: DeviceImpl,
    _ parameters: WebGPU.Metal.BufferParameters,
    _ label: WTF.String
) -> BufferImpl {
    if !deviceImpl.isValid() {
        return makeInvalidBufferImpl(device, deviceImpl)
    }

    if !isValidBufferDescriptor(parameters, deviceImpl, deviceImpl.capabilities.limits.maxBufferSize) {
        deviceImpl.generateAValidationError("Validation failure.")
        return makeInvalidBufferImpl(device, deviceImpl)
    }

    // FIXME(PERFORMANCE): Consider write-combining CPU cache mode.
    // FIXME(PERFORMANCE): Consider implementing hazard tracking ourself.
    let storageMode = bufferStorageMode(hasUnifiedMemory(deviceImpl), parameters.usage, parameters.mappedAtCreation)
    guard let buffer = deviceImpl.safeCreateBuffer(UInt(parameters.size), storageMode) else {
        device.generateAnOutOfMemoryError(consuming: wtfString("Allocation failure."))
        return makeInvalidBufferImpl(device, deviceImpl)
    }

    buffer.label = CxxBridging.convertWTFStringToNSString(label) as String? ?? ""
    return BufferImpl(
        buffer: buffer,
        size: parameters.size,
        usageBits: parameters.usage,
        mappedAtCreation: parameters.mappedAtCreation,
        device: device,
        deviceImpl: deviceImpl
    )
}

@_expose(Cxx)
func makeInvalidBufferImpl(_ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> BufferImpl {
    BufferImpl(buffer: nil, size: 0, usageBits: 0, mappedAtCreation: false, device: device, deviceImpl: deviceImpl)
}

private func hasBufferUsage(_ usageBits: UInt16, _ usage: WebGPU.BufferUsage) -> Bool {
    usageBits & usage.rawValue != 0
}

// https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpubufferdescriptor, and createBuffer's own checks.
private func isValidBufferDescriptor(_ parameters: WebGPU.Metal.BufferParameters, _ deviceImpl: DeviceImpl, _ maxBufferSize: UInt64) -> Bool
{
    let usage = parameters.usage
    if deviceImpl.isLost() {
        return false
    }

    // FIXME: "If any of the bits of descriptor’s usage aren’t present in this device’s [[allowed buffer usages]] return false."

    if hasBufferUsage(usage, .MapRead) && hasBufferUsage(usage, .MapWrite) {
        return false
    }

    if usage == 0 || hasBufferUsage(usage, .Invalid) {
        return false
    }

    let mapReadBufferUsages = WebGPU.BufferUsage.CopyDestination.rawValue | WebGPU.BufferUsage.MapRead.rawValue
    if hasBufferUsage(usage, .MapRead) && usage & ~mapReadBufferUsages != 0 {
        return false
    }

    let mapWriteBufferUsages = WebGPU.BufferUsage.CopySource.rawValue | WebGPU.BufferUsage.MapWrite.rawValue
    if hasBufferUsage(usage, .MapWrite) && usage & ~mapWriteBufferUsages != 0 {
        return false
    }

    if parameters.mappedAtCreation && parameters.size % 4 != 0 {
        return false
    }

    return parameters.size <= maxBufferSize
}

private func bufferStorageMode(_ deviceHasUnifiedMemory: Bool, _ usage: UInt16, _ mappedAtCreation: Bool) -> MTLStorageMode {
    if deviceHasUnifiedMemory {
        return .shared
    }
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    if hasBufferUsage(usage, .MapRead) || hasBufferUsage(usage, .MapWrite) || hasBufferUsage(usage, .Index) || mappedAtCreation {
        return deprecatedManagedStorageMode
    }
    #endif
    return .private
}

// CPU writes to a managed buffer (Intel Macs only) must be flushed before the GPU reads them.
private func bufferNeedsDidModifyRangeAfterUnmap(_ buffer: any MTLBuffer) -> Bool {
    #if arch(x86_64) && (WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST)
    buffer.storageMode == deprecatedManagedStorageMode
    #else
    false
    #endif
}

#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "Managed buffers on Macs with discrete memory still need it")
#endif
private func bufferDidModifyRange(_ buffer: any MTLBuffer, _ offset: UInt64, _ length: UInt64) {
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    buffer.didModifyRange(Int(truncatingIfNeeded: offset)..<Int(truncatingIfNeeded: offset &+ length))
    #endif
}
