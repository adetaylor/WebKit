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
//
// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

private import CxxStdlib
import Metal
@_implementationOnly import WebGPU_Internal.BindGroup
@_implementationOnly import WebGPU_Internal.Buffer
@_implementationOnly import WebGPU_Internal.ComputePipeline
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
@_implementationOnly import WebGPU_Internal.PresentationContext
@_implementationOnly import WebGPU_Internal.Queue
@_implementationOnly import WebGPU_Internal.RenderBundleEncoder
@_implementationOnly import WebGPU_Internal.RenderPipeline
@_implementationOnly import WebGPU_Internal.ShaderModule
@_implementationOnly import WebGPU_Internal.XRProjectionLayer
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
// The state of a GPUBuffer, held by its Swift callers and the bind groups, bundles and encoders that use it. Used only on
// the instance's API thread, so not Sendable.
@_spi(WebKitGPU)
public final class BufferImpl: GPUObjectReference, LinkedImpl {
    private var linkSlot = ImplLinkSlot<BufferImpl>()
    private var backingBuffer: (any MTLBuffer)?
    private let initialByteSize: UInt64
    private let usageBits: UInt16
    private var mapState: BufferMapState
    // The serial of the latest mapAsync request; serials start at 1.
    private var lastMapSerial: UInt64 = 0
    // Ranges handed out since the buffer was mapped: sorted, disjoint and non-adjacent.
    private var mappedRanges: [Range<UInt64>] = []
    private let mappedAtCreation: Bool

    // The smallest vertex count that any entry currently in drawIndexedCache was proven against by the clamp shader. Only
    // meaningful while drawIndexedCache is non-empty.
    private var minValidatedVertexCount = UInt32.max

    private var backingMustTakeSlowIndexValidationPath = false
    private var backingContentsGeneration: UInt64 = 0
    private var backingIndexContentsGeneration: UInt64 = 0
    private var indexValueUpperBoundUInt32: UInt32 = 0
    private var indexValueUpperBoundUInt16: UInt16 = 0
    // Keyed by the gpuResourceID of the indirect command buffer; 0 for draws outside one.
    private var didReadOOBByCommandBuffer: [UInt64: Bool] = [:]

    /// The encoders that used the buffer.
    var tracking = EncoderTracking()
    private var drawIndexedCache = WTFHashMap<DrawIndexKey, DrawIndexValidationEntry>()
    // Whether drawIndexedCache and skippedValidationEncoders may be non-empty. Every index write reads them, and unlike the
    // containers these plain flags are read without a dynamic exclusivity check.
    private var drawIndexedCacheHasEntries = false
    private var hasSkippedValidationEncoders = false
    private var hasPendingIndexWriteEncoders = false
    // The bind groups and render bundles that hold the buffer.
    private var bindGroupHolders = ImplLinkList<BindGroupImpl>()
    private var renderBundleHolders = ImplLinkList<RenderBundleImpl>()
    // The encoders that skipped validating a draw with this index buffer.
    private var skippedValidationEncoders = EncoderTracking()
    // The encoders that recorded a write to the buffer that their command buffers have not committed yet.
    private var pendingIndexWriteEncoders = EncoderTracking()
    // The command buffer this buffer was last cleared for, so that several failed validations sharing one command
    // buffer do not each capture a "prior" copy and queue a restore of it.
    private var clearedForCommandBuffer: ObjectIdentifier?
    // Declared last, so that the device outlives the rest of the buffer.
    let deviceImpl: DeviceImpl

    fileprivate init(
        buffer: (any MTLBuffer)?,
        size: UInt64,
        usageBits: UInt16,
        mappedAtCreation: Bool,
        deviceImpl: DeviceImpl
    ) {
        self.backingBuffer = buffer
        self.initialByteSize = size
        self.usageBits = usageBits
        self.mapState = mappedAtCreation ? .mappedAtCreation(0..<size) : .unmapped
        self.mappedAtCreation = mappedAtCreation
        self.deviceImpl = deviceImpl
    }

    deinit {
        linkSlot.end()
    }

    var link: ImplLink<BufferImpl> {
        linkSlot.link(for: self)
    }

    func buffer() -> (any MTLBuffer)? {
        backingBuffer
    }

    func initialSize() -> UInt64 {
        initialByteSize
    }

    func currentSize() -> UInt64 {
        UInt64(backingBuffer?.length ?? 0)
    }

    // Raw value of OptionSet<WebGPU::BufferUsage>.
    func usageRawValue() -> UInt16 {
        usageBits
    }

    // Whether a mapAsync() is pending.
    var isMappingPending: Bool {
        if case .pending = mapState {
            return true
        }
        return false
    }

    func isDestroyed() -> Bool {
        if case .destroyed = mapState {
            return true
        }
        return false
    }

    public func isValid() -> Bool {
        isDestroyed() || backingBuffer != nil
    }

    var isUnmapped: Bool {
        if case .unmapped = mapState {
            return true
        }
        return false
    }

    func setLabel(_ label: WTF.String) {
        backingBuffer?.label = stringNilIfEmpty(label)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-destroy
    @_spi(WebKitGPU)
    public func destroy() {
        if mapState.hasMapping {
            // FIXME: ASSERT() that this call doesn't fail.
            unmap()
        }

        mapState = .destroyed
        backingBuffer = deviceImpl.placeholderBuffer()
        for encoder in tracking.takeLive() {
            encoder.makeSubmitInvalid(nil)
        }

        let bindGroups = bindGroupHolders.values
        for bindGroup in bindGroups {
            bindGroup.releaseDestroyedResources()
        }
        bindGroupHolders.removeAll()
        let renderBundles = renderBundleHolders.values
        for renderBundle in renderBundles {
            renderBundle.releaseDestroyedResources()
        }
        renderBundleHolders.removeAll()
    }

    // MARK: Encoder tracking

    // Each encoder holds the buffer once, from the first use until its clearTracking().
    func setCommandEncoder(_ encoder: CommandEncoderImpl, mayModifyBuffer: Bool) {
        let isNewEntry = !tracking.contains(encoder) && tracking.add(encoder)
        if isNewEntry {
            encoder.trackBuffer(self)
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
    func addBindGroupHolder(_ bindGroup: BindGroupImpl) {
        if isDestroyed() {
            return
        }
        bindGroupHolders.add(bindGroup)
    }

    func addRenderBundleHolder(_ renderBundle: RenderBundleImpl) {
        if isDestroyed() {
            return
        }
        renderBundleHolders.add(renderBundle)
    }

    // mapAsync, for a Swift caller.
    func mapAsync(
        _ modeBits: UInt8,
        _ rangeFits: Bool,
        _ offset: UInt64,
        _ rangeSize: UInt64,
        _ handler: @escaping (Bool) -> Void
    ) {
        if let error = rangeFits ? errorValidatingMapAsync(modeBits, offset, rangeSize) : mapAsyncError("offset and rangeSize overflowed") {
            deviceImpl.generateAValidationError(error)
            handler(false)
            return
        }

        let mapRequest = beginMapping(modeBits, offset, rangeSize)

        deviceImpl.defaultQueueImpl.onSubmittedWorkDone(deviceIsUsable: deviceImpl.isValid() && !deviceImpl.isLost()) { success in
            self.completeMapping(mapRequest, success)
            handler(success)
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
    // Validates and records [offset, offset + rangeSize). Returns whether getMappedRange() may copy that part of the
    // contents.
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
    @_spi(WebKitGPU)
    public func unmap() {
        guard mapState.hasMapping else {
            return
        }
        let encoders = tracking
        encoders.forEachLive { $0.decrementBufferMapCount() }
        indirectBufferInvalidated(nil)

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

    func needsIndexValidation(_ maxUInt32Index: UInt32, _ maxUInt16Index: UInt16) -> Bool {
        // Nothing has been validated since the last invalidation, so there is no cached verdict whose
        // assumptions a write could break.
        if !drawIndexedCacheHasEntries {
            return true
        }

        // Every live cache entry was proven against a vertex count of at least minValidatedVertexCount,
        // and the clamp shader accepts an index only if it is below the vertex count it was proven
        // against. A write whose largest value stays below that bound therefore cannot make any cached
        // draw fetch out of bounds no matter where in the buffer it lands, so the cached verdicts may be
        // kept. Both interpretations are checked because the cache is shared across index types.
        // Anything else has to be revalidated.
        return maxUInt32Index >= minValidatedVertexCount || UInt32(maxUInt16Index) >= minValidatedVertexCount
    }

    func indexBufferContentsModified(_ maxUInt32Value: UInt32, _ maxUInt16Value: UInt16) {
        backingIndexContentsGeneration += 1
        indexValueUpperBoundUInt32 = max(indexValueUpperBoundUInt32, maxUInt32Value)
        indexValueUpperBoundUInt16 = max(indexValueUpperBoundUInt16, maxUInt16Value)
    }

    func allIndexValuesBelow(_ isUInt16: Bool, _ vertexCount: UInt32) -> Bool {
        (isUInt16 ? UInt32(indexValueUpperBoundUInt16) : indexValueUpperBoundUInt32) < vertexCount
    }

    func invalidateIndexContents() {
        backingContentsGeneration += 1
        backingIndexContentsGeneration += 1
        indexValueUpperBoundUInt32 = .max
        indexValueUpperBoundUInt16 = .max
    }

    func contentsGeneration() -> UInt64 {
        backingContentsGeneration
    }

    func indexContentsGeneration() -> UInt64 {
        backingIndexContentsGeneration
    }

    func mustTakeSlowIndexValidationPath() -> Bool {
        backingMustTakeSlowIndexValidationPath
    }

    // MARK: Draw-indexed validation cache

    /// `icbResourceID` is the indirect command buffer's gpuResourceID._impl, 0 outside one.
    static func drawIndexKey(
        firstIndex: UInt32,
        indexCount: UInt32,
        baseVertex: Int32,
        indexType: MTLIndexType,
        primitiveOffset: UInt32,
        icbResourceID: UInt64
    ) -> DrawIndexKey {
        DrawIndexKey(
            firstIndex: firstIndex,
            indexCount: indexCount,
            primitiveOffsetWithIndexType: primitiveOffset | UInt32(truncatingIfNeeded: indexType.rawValue &<< 1),
            icbLow: UInt32(truncatingIfNeeded: icbResourceID),
            icbHigh: UInt32(truncatingIfNeeded: icbResourceID &>> 32),
            baseVertex: baseVertex
        )
    }

    func canSkipDrawIndexedValidation(_ key: DrawIndexKey, vertexCount: UInt32) -> DrawIndexValidationEntry? {
        guard !hasPendingRecordedIndexWrite(), let entry = drawIndexedCache.value(forKey: key),
            entry.indexContentsGeneration == backingIndexContentsGeneration, entry.vertexCount <= vertexCount
        else {
            return nil
        }
        return entry
    }

    func drawIndexedValidated(_ key: DrawIndexKey, vertexCount: UInt32, validationGeneration: UInt64) {
        if hasPendingRecordedIndexWrite() {
            return
        }

        let maxCacheSize = 1_000_000
        if drawIndexedCache.count > maxCacheSize {
            clearDrawIndexedCache()
        }

        drawIndexedCache.set(key, DrawIndexValidationEntry(vertexCount: vertexCount, indexContentsGeneration: validationGeneration))
        drawIndexedCacheHasEntries = true

        minValidatedVertexCount = min(minValidatedVertexCount, vertexCount)
    }

    private func clearDrawIndexedCache() {
        if drawIndexedCacheHasEntries {
            drawIndexedCache.removeAll()
            drawIndexedCacheHasEntries = false
        }
        minValidatedVertexCount = .max
    }

    /// Right after canSkipDrawIndexedValidation found `key`.
    ///
    /// The encoder records the cached entry's vertex count.
    func skippedDrawIndexedValidation(_ encoder: CommandEncoderImpl, _ key: DrawIndexKey, vertexCount: UInt32) {
        _ = skippedValidationEncoders.add(encoder)
        hasSkippedValidationEncoders = true
        let cachedVertexCount = drawIndexedCache.value(forKey: key)?.vertexCount ?? vertexCount
        encoder.recordSkippedDrawIndexedValidation(self, key, vertexCount: cachedVertexCount)
    }

    /// Invalidates now, and again when the encoder's command buffer is committed.
    ///
    /// Both are no-ops for a buffer without Index or Indirect usage (the invalidation returns at once), so such a buffer
    /// queues nothing.
    func indirectBufferInvalidated(by encoder: CommandEncoderImpl) {
        if !hasUsage(.Indirect) && !hasUsage(.Index) {
            return
        }
        indirectBufferInvalidated(nil)
        _ = pendingIndexWriteEncoders.add(encoder)
        hasPendingIndexWriteEncoders = true
        encoder.addCommitAction(.indirectBufferInvalidated(BufferAndEncoderLinks(buffer: self, encoder: encoder)))
    }

    /// The commit action indirectBufferInvalidated(by:) queued.
    func indirectBufferInvalidatedAtCommit(by encoder: CommandEncoderImpl) {
        pendingIndexWriteEncoders.remove(encoder)
        hasPendingIndexWriteEncoders = !pendingIndexWriteEncoders.isEmpty
        indirectBufferInvalidated(encoder)
    }

    /// Whether an encoder that is still alive recorded a write to the buffer that its command buffer has not committed.
    private func hasPendingRecordedIndexWrite() -> Bool {
        if !hasPendingIndexWriteEncoders {
            return false
        }
        let liveCount = pendingIndexWriteEncoders.liveCount()
        hasPendingIndexWriteEncoders = liveCount != 0
        return liveCount != 0
    }

    func indirectBufferInvalidatedWithoutEncoder() {
        indirectBufferInvalidated(nil)
    }

    /// Validation can be skipped later only when the one encoder that skipped it is the one invalidating.
    func indirectBufferInvalidated(_ encoder: CommandEncoderImpl?) {
        if !hasUsage(.Indirect) && !hasUsage(.Index) {
            return
        }

        if hasSkippedValidationEncoders {
            let currentSize = skippedValidationEncoders.liveCount()
            hasSkippedValidationEncoders = currentSize != 0
            if currentSize != 0 {
                let validationNotNeeded = currentSize == 1 && encoder != nil && skippedValidationEncoders.firstLive === encoder
                if !validationNotNeeded {
                    backingMustTakeSlowIndexValidationPath = true
                }
            }
        }

        clearDrawIndexedCache()
        invalidateIndexContents()
    }

    func removeSkippedValidationCommandEncoder(_ encoder: CommandEncoderImpl) {
        skippedValidationEncoders.remove(encoder)
        hasSkippedValidationEncoders = !skippedValidationEncoders.isEmpty
    }

    func clearMustTakeSlowIndexValidationPath() {
        let liveCount = skippedValidationEncoders.liveCount()
        hasSkippedValidationEncoders = liveCount != 0
        if liveCount != 0 {
            return
        }
        backingMustTakeSlowIndexValidationPath = false
    }

    /// When the indices are invalid, the GPU work in `commandBuffer` reads cleared ones, and the post-commit action
    /// writes the old ones back.
    func takeSlowIndexValidationPath(_ commandBuffer: CommandBufferImpl, _ key: DrawIndexKey, vertexCount: UInt32) {
        let isUInt16 = key.indexTypeRawValue == MTLIndexType.uint16.rawValue
        deviceImpl.defaultQueueImpl.makeGPUWritesVisible(backingBuffer)
        let verified = WebGPU.Metal.verifyIndexBufferForSlowPath(
            backingBuffer,
            key.firstIndex,
            key.indexCount,
            isUInt16,
            key.primitiveOffset,
            vertexCount
        )
        if !verified {
            clearIndexBuffer(for: commandBuffer)
        }
    }

    /// Right after executeBundles reused the baked ICB slot of an indexed indirect draw that indexes this buffer.
    func skippedBundleIndirectDrawValidation(_ encoder: CommandEncoderImpl, _ draw: ReusedIndirectIndexedDraw) {
        encoder.recordReusedIndirectIndexedDraw(self, draw)
    }

    /// At commit, for a reused draw whose indices changed after its slot was baked: as takeSlowIndexValidationPath(),
    /// with the checks of the clamp shader.
    func takeSlowBundleIndirectDrawValidationPath(_ commandBuffer: CommandBufferImpl, _ draw: ReusedIndirectIndexedDraw) {
        // The baked slot holds the baseVertex the clamp shader saw, so the arguments are only a usable stand-in for it
        // while nothing has rewritten them since. Anything else falls back to clearing unconditionally.
        let indirectBuffer = draw.indirectBufferImpl
        let indirectArguments =
            !indirectBuffer.isDestroyed() && indirectBuffer.contentsGeneration() == draw.indirectGeneration
            ? indirectBuffer.buffer() : nil
        let primitiveOffset: UInt32 = draw.primitiveType == .lineStrip || draw.primitiveType == .triangleStrip ? 1 : 0
        deviceImpl.defaultQueueImpl.makeGPUWritesVisible(backingBuffer, indirectArguments)
        let verified = WebGPU.Metal.verifyBundleIndirectDrawIndexBufferForSlowPath(
            backingBuffer,
            indirectArguments,
            draw.indirectOffset,
            draw.indexBufferOffset,
            draw.indexType == .uint16,
            draw.minVertexCount.indexClampVertexCount(primitiveOffset: primitiveOffset),
            primitiveOffset
        )
        if !verified {
            clearIndexBuffer(for: commandBuffer)
        }
    }

    /// Clears the buffer for the GPU work in `commandBuffer`, at most once per command buffer, and queues the write of
    /// its old contents once that work completed.
    private func clearIndexBuffer(for commandBuffer: CommandBufferImpl) {
        let commandBufferIdentity = commandBuffer.commandBuffer().map { ObjectIdentifier($0) }
        if let commandBufferIdentity, clearedForCommandBuffer == commandBufferIdentity {
            return
        }
        clearedForCommandBuffer = commandBufferIdentity
        let priorContents = WebGPU.Metal.copyBufferContents(backingBuffer)
        let queueImpl = deviceImpl.defaultQueueImpl
        queueImpl.clearBuffer(backingBuffer, 0, UInt.max)
        queueImpl.finalizeBlitCommandEncoder()
        #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
        if let backingBuffer, backingBuffer.storageMode == deprecatedManagedStorageMode {
            bufferDidModifyRange(backingBuffer, 0, UInt64(backingBuffer.length))
        }
        #endif
        if let priorContents {
            commandBuffer.addPostCommitAction(.restoreIndexBufferContents(self, priorContents))
        }
    }

    /// Writes back the contents clearIndexBuffer cleared, once the command buffer completed.
    func restoreIndexBufferContents(_ priorContents: NSMutableData) {
        let bytes = [UInt8](priorContents as Data)
        deviceImpl.defaultQueueImpl.writeBuffer(deviceImpl, self, 0, bytes: bytes.span)
    }

    /// The restore of the contents clearIndexBuffer cleared is next, once the command buffer completed.
    func indexBufferContentsWillBeRestored() {
        clearedForCommandBuffer = nil
    }

    // MARK: Out-of-bounds reads

    func didReadOOB(_ commandBufferKey: UInt64) -> Bool {
        didReadOOBByCommandBuffer[commandBufferKey] ?? false
    }

    // Sticky: once a draw read out of bounds, it stays recorded.
    func recordReadOOB(_ commandBufferKey: UInt64, _ didRead: Bool) {
        didReadOOBByCommandBuffer[commandBufferKey] = didRead || didReadOOB(commandBufferKey)
    }

    func hasUsage(_ usage: WebGPU.BufferUsage) -> Bool {
        usageBits & usage.rawValue != 0
    }

    private func mapAsyncError(_ message: String) -> NSString {
        "GPUBuffer.mapAsync: \(message)" as NSString
    }

    private func validatedMappedRange(_ offset: UInt64, _ rangeSize: UInt64) -> Range<UInt64>? {
        guard let range = validatedMappedRangeBounds(offset, rangeSize) else {
            return nil
        }
        // An empty range overlaps nothing.
        guard !mappedRanges.contains(where: { $0.overlaps(range) }) else {
            return nil
        }
        return range
    }

    // validatedMappedRange() without the check that the range does not overlap one that was handed out.
    private func validatedMappedRangeBounds(_ offset: UInt64, _ rangeSize: UInt64) -> Range<UInt64>? {
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
        return offset..<end
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

// https://gpuweb.github.io/gpuweb/#dictdef-gpubufferdescriptor, without its label.
@_spi(WebKitGPU)
public struct GPUBufferDescriptor {
    // The bits of OptionSet<WebGPU::BufferUsage>.
    public var usage: UInt16 = 0
    public var size: UInt64 = 0
    public var mappedAtCreation = false

    public init() {
    }
}

func createBufferImpl(_ deviceImpl: DeviceImpl, _ descriptor: GPUBufferDescriptor, label: WTF.String) -> BufferImpl {
    var parameters = WebGPU.Metal.BufferParameters()
    parameters.size = descriptor.size
    parameters.usage = descriptor.usage
    parameters.mappedAtCreation = descriptor.mappedAtCreation
    return createBufferImpl(deviceImpl, parameters, label)
}

// Device::createBuffer. https://gpuweb.github.io/gpuweb/#dom-gpudevice-createbuffer
func createBufferImpl(
    _ deviceImpl: DeviceImpl,
    _ parameters: WebGPU.Metal.BufferParameters,
    _ label: WTF.String
) -> BufferImpl {
    if !deviceImpl.isValid() {
        return makeInvalidBufferImpl(deviceImpl)
    }

    if !isValidBufferDescriptor(parameters, deviceImpl, deviceImpl.capabilities.limits.maxBufferSize) {
        deviceImpl.generateAValidationError("Validation failure.")
        return makeInvalidBufferImpl(deviceImpl)
    }

    // FIXME(PERFORMANCE): Consider write-combining CPU cache mode.
    // FIXME(PERFORMANCE): Consider implementing hazard tracking ourself.
    let storageMode = bufferStorageMode(hasUnifiedMemory(deviceImpl), parameters.usage, parameters.mappedAtCreation)
    guard let buffer = deviceImpl.safeCreateBuffer(UInt(parameters.size), storageMode) else {
        deviceImpl.generateAnOutOfMemoryError("Allocation failure.")
        return makeInvalidBufferImpl(deviceImpl)
    }

    buffer.label = stringNilIfEmpty(label) ?? ""
    return BufferImpl(
        buffer: buffer,
        size: parameters.size,
        usageBits: parameters.usage,
        mappedAtCreation: parameters.mappedAtCreation,
        deviceImpl: deviceImpl
    )
}

func makeInvalidBufferImpl(_ deviceImpl: DeviceImpl) -> BufferImpl {
    BufferImpl(buffer: nil, size: 0, usageBits: 0, mappedAtCreation: false, deviceImpl: deviceImpl)
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

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createbuffer: an invalid buffer on failure.
    public func createBuffer(_ descriptor: GPUBufferDescriptor, label: Swift.String?) -> BufferReference {
        createBufferImpl(self, descriptor, label: WTF.String(label ?? ""))
    }
}

@_spi(WebKitGPU)
extension BufferImpl {
    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-mapasync. `mode` is the bits of
    // OptionSet<WebGPU::MapMode>; nil size: the rest of the buffer after the offset.
    public func mapAsync(_ mode: UInt8, _ offset: UInt64, _ size: UInt64?, _ completion: @escaping (Bool) -> Void) {
        let rangeSize = size ?? (initialSize() > offset ? initialSize() - offset : 0)
        let rangeFits = UInt(exactly: offset) != nil && UInt(exactly: rangeSize) != nil
        mapAsync(mode, rangeFits, rangeFits ? offset : 0, rangeFits ? rangeSize : 0, completion)
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpubuffer-getmappedrange, as Buffer::getMappedRange() reserves the range, but
    // giving a copy of its bytes. No bytes if the range can't be given.
    public func getMappedRange(_ offset: UInt64, _ size: UInt64?) -> [UInt8] {
        let rangeSize = size ?? (initialSize() > offset ? initialSize() - offset : 0)
        guard UInt(exactly: offset) != nil, UInt(exactly: rangeSize) != nil, reserveMappedRange(offset, rangeSize) else {
            return []
        }
        // The reserved range lies within the mapping, so within the contents.
        guard let byteCount = Int(exactly: rangeSize), byteCount > 0 else {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var destination = bytes.mutableSpan
        WebGPU.Metal.readBufferContents(buffer(), offset, &destination)
        return bytes
    }

    // Writes data into the buffer's contents at that offset, as a mapped range of them is written. Returns false,
    // writing nothing, if the contents don't hold it there.
    public func writeContents(_ data: Span<UInt8>, at offset: UInt64) -> Bool {
        WebGPU.Metal.writeBufferContentsIfInBounds(buffer(), offset, data)
    }

    public func setLabel(_ label: Swift.String?) {
        setLabel(WTF.String(label ?? ""))
    }

    // Buffer::generateAValidationError.
    public func generateAValidationError() {
        deviceImpl.generateAValidationError("Buffer state was not unmapped")
    }
}

@_spi(WebKitGPU)
public typealias BufferReference = BufferImpl
