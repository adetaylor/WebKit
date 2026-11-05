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
import Synchronization
@_implementationOnly import WebGPU_Internal.CxxBridging
@_implementationOnly import WebGPU_Internal.Device
import WebGPU_Private.WebGPUCpp

// https://gpuweb.github.io/gpuweb/#gpuqueryset, held by its Swift callers. API thread only. A timestamp query set owns a lease on a range of the
// process-wide counter sample buffer pool below and returns it on destroy() or deinit.
@_spi(WebKitGPU)
public final class QuerySetImpl: GPUObjectReference {
    // Occlusion query sets own a private MTLBuffer; timestamp query sets lease
    // [counterSampleOffset, counterSampleOffset + queryCount) samples of a pooled counter buffer.
    private var backing: QuerySetBacking
    private var backingVisibilityBuffer: (any MTLBuffer)? {
        if case .visibility(let buffer) = backing {
            return buffer
        }
        return nil
    }
    private var backingCounterSampleBuffer: (any MTLCounterSampleBuffer)? {
        if case .counters(let buffer) = backing {
            return buffer
        }
        return nil
    }
    private let counterSampleOffset: UInt32
    private let queryCount: UInt32
    // nil only for invalid query sets.
    let queryType: WebGPU.QueryType?
    private var destroyed = false
    /// The encoders that used this query set: emptied only by destroy(), never by the encoders.
    var tracking = EncoderTracking()
    // Declared last, so that the device outlives the rest of the query set.
    let deviceImpl: DeviceImpl

    fileprivate init(
        visibilityBuffer: (any MTLBuffer)?,
        counterSampleBuffer: (any MTLCounterSampleBuffer)?,
        counterSampleOffset: UInt32,
        queryCount: UInt32,
        queryType: WebGPU.QueryType?,
        deviceImpl: DeviceImpl
    ) {
        if let visibilityBuffer {
            backing = .visibility(visibilityBuffer)
        } else if let counterSampleBuffer {
            backing = .counters(counterSampleBuffer)
        } else {
            backing = .none
        }
        self.counterSampleOffset = counterSampleOffset
        self.queryCount = queryCount
        self.queryType = queryType
        self.deviceImpl = deviceImpl
    }

    deinit {
        releaseCounterSampleRange()
    }

    public func isValid() -> Bool {
        if case .none = backing {
            return destroyed
        }
        return true
    }

    func isDestroyed() -> Bool {
        destroyed
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpuqueryset-destroy
    @_spi(WebKitGPU)
    public func destroy() {
        destroyed = true
        releaseCounterSampleRange()
        backing = .none
        for encoder in tracking.takeLive() {
            encoder.makeSubmitInvalid(nil)
        }
    }

    // The encoder retains the Metal buffers, not the query set.
    func setCommandEncoder(_ encoder: CommandEncoderImpl) {
        if !tracking.contains(encoder) {
            _ = tracking.add(encoder)
        }
        encoder.addBuffer(backingVisibilityBuffer)
        encoder.addCounterSampleBuffer(backingCounterSampleBuffer)
        if destroyed {
            encoder.makeSubmitInvalid(nil)
        }
    }

    func setLabel(_ label: WTF.String) {
        setLabel(stringNilIfEmpty(label))
    }

    @_spi(WebKitGPU)
    public func setLabel(_ label: Swift.String?) {
        // MTLCounterSampleBuffer's label property is read-only.
        backingVisibilityBuffer?.label = label?.isEmpty == false ? label : nil
    }

    func count() -> UInt32 {
        queryCount
    }

    func hasType() -> Bool {
        queryType != nil
    }

    // Raw value of WebGPU::QueryType; only meaningful when hasType().
    func typeRawValue() -> UInt8 {
        queryType?.rawValue ?? 0
    }

    func visibilityBuffer() -> (any MTLBuffer)? {
        backingVisibilityBuffer
    }

    func counterSampleBuffer() -> (any MTLCounterSampleBuffer)? {
        backingCounterSampleBuffer
    }

    func counterSampleBufferOffset() -> UInt32 {
        counterSampleOffset
    }

    private func releaseCounterSampleRange() {
        if let buffer = backingCounterSampleBuffer {
            counterSampleBufferPoolRelease(buffer, counterSampleOffset, queryCount)
        }
    }
}

private let maxQueryCount: UInt32 = 4096

@_spi(WebKitGPU)
public typealias QuerySetReference = QuerySetImpl

// https://gpuweb.github.io/gpuweb/#dictdef-gpuquerysetdescriptor, without its label.
@_spi(WebKitGPU)
public struct GPUQuerySetDescriptor {
    public var type = WebGPU.QueryType.Occlusion
    public var count: UInt32 = 0

    public init() {
    }
}

func createQuerySetImpl(
    _ deviceImpl: DeviceImpl,
    _ descriptor: GPUQuerySetDescriptor,
    label: WTF.String,
    _ timestampCounterSet: (any MTLCounterSet)?
) -> QuerySetImpl {
    let count = descriptor.count
    if count > maxQueryCount || !deviceImpl.isValid() {
        deviceImpl.generateAValidationError("GPUQuerySetDescriptor.count must be <= 4096")
        return makeInvalidQuerySetImpl(deviceImpl)
    }

    switch descriptor.type {
    case WebGPU.QueryType.Timestamp:
        guard let metalDevice = deviceImpl.device(), let lease = counterSampleBufferPoolAcquire(count, metalDevice, timestampCounterSet)
        else {
            return makeInvalidQuerySetImpl(deviceImpl)
        }
        return QuerySetImpl(
            visibilityBuffer: nil,
            counterSampleBuffer: lease.buffer.buffer,
            counterSampleOffset: lease.offset,
            queryCount: count,
            queryType: WebGPU.QueryType.Timestamp,
            deviceImpl: deviceImpl
        )
    case WebGPU.QueryType.Occlusion:
        let buffer = deviceImpl.safeCreateBuffer(UInt(MemoryLayout<UInt64>.size) * UInt(count), .private)
        buffer?.label = stringNilIfEmpty(label)
        return QuerySetImpl(
            visibilityBuffer: buffer,
            counterSampleBuffer: nil,
            counterSampleOffset: 0,
            queryCount: count,
            queryType: WebGPU.QueryType.Occlusion,
            deviceImpl: deviceImpl
        )
    default:
        preconditionFailure("unknown WebGPU::QueryType")
    }
}

/// A query set's Metal storage: occlusion sets have a visibility buffer, timestamp sets a leased counter sample buffer
/// (never both, so one reference).
private enum QuerySetBacking {
    case visibility(any MTLBuffer)
    case counters(any MTLCounterSampleBuffer)
    case none
}

func makeInvalidQuerySetImpl(_ deviceImpl: DeviceImpl) -> QuerySetImpl {
    QuerySetImpl(
        visibilityBuffer: nil,
        counterSampleBuffer: nil,
        counterSampleOffset: 0,
        queryCount: 0,
        queryType: nil,
        deviceImpl: deviceImpl
    )
}

// MARK: Process-wide MTLCounterSampleBuffer pool

// The pool is per process because the limit on counter sample buffers is.
private let maxCounterSampleBuffers = 32
private let maxSampleBufferSize: UInt32 = 32 * 1024
private let sampleSize = UInt32(MemoryLayout<UInt64>.size)

// Every timestamp query set leasing part of a buffer shares it, whichever Instance's API thread created the set. The
// pool itself only stores the buffers and compares their identities under its lock. Unchecked Sendable because the SDK
// does not mark MTLCounterSampleBuffer Sendable, as it does MTLCounterSet.
private struct SharedCounterSampleBuffer: @unchecked Sendable {
    let buffer: any MTLCounterSampleBuffer
}

private struct CounterSampleBufferPool {
    var buffers = [SharedCounterSampleBuffer?](repeating: nil, count: maxCounterSampleBuffers)
    // Free byte ranges of each buffer: sorted, disjoint and never touching, which acquire and release both preserve.
    var freeRanges = [[Range<UInt32>]](repeating: [], count: maxCounterSampleBuffers)
}

// Shared by every Instance's API thread (one per RemoteGPU), and a QuerySetImpl can die on any thread.
private let counterSampleBufferPool = Mutex(CounterSampleBufferPool())

private func counterSampleBufferPoolAcquire(
    _ sampleCount: UInt32,
    _ device: any MTLDevice,
    _ counterSet: (any MTLCounterSet)?
) -> (buffer: SharedCounterSampleBuffer, offset: UInt32)? {
    let sampleCountInBytes = sampleCount &* sampleSize
    let lease: (buffer: SharedCounterSampleBuffer, offset: UInt32)? = counterSampleBufferPool.withLock { pool in
        for i in 0..<maxCounterSampleBuffers {
            if let buffer = pool.buffers[i] {
                // First fit, in ascending offset order.
                guard let index = pool.freeRanges[i].firstIndex(where: { $0.upperBound - $0.lowerBound >= sampleCountInBytes }) else {
                    continue
                }
                let range = pool.freeRanges[i][index]
                let remainder = (range.lowerBound &+ sampleCountInBytes)..<range.upperBound
                if remainder.isEmpty {
                    pool.freeRanges[i].remove(at: index)
                } else {
                    pool.freeRanges[i][index] = remainder
                }
                precondition(range.lowerBound / sampleSize < maxQueryCount)
                return (buffer, range.lowerBound / sampleSize)
            }

            let descriptor = MTLCounterSampleBufferDescriptor()
            descriptor.sampleCount = Int(maxSampleBufferSize / sampleSize)
            descriptor.storageMode = .shared
            descriptor.counterSet = counterSet
            guard let created = try? device.makeCounterSampleBuffer(descriptor: descriptor) else {
                return nil
            }
            let buffer = SharedCounterSampleBuffer(buffer: created)
            pool.buffers[i] = buffer
            if sampleCountInBytes < maxSampleBufferSize {
                insertFreeRange(sampleCountInBytes..<maxSampleBufferSize, into: &pool.freeRanges[i])
            }
            return (buffer, 0)
        }
        return nil
    }
    return lease
}

private func counterSampleBufferPoolRelease(_ buffer: any MTLCounterSampleBuffer, _ offset: UInt32, _ count: UInt32) {
    let identity = ObjectIdentifier(buffer)
    let offsetInBytes = offset &* sampleSize
    let endOffset = offsetInBytes &+ count &* sampleSize
    counterSampleBufferPool.withLock { pool in
        for i in 0..<maxCounterSampleBuffers {
            guard let pooled = pool.buffers[i], ObjectIdentifier(pooled.buffer) == identity else {
                continue
            }
            precondition(offsetInBytes < maxSampleBufferSize)
            if offsetInBytes < endOffset {
                insertFreeRange(offsetInBytes..<endOffset, into: &pool.freeRanges[i])
            }
        }
    }
}

// Overlapping or touching ranges merge.
private func insertFreeRange(_ range: Range<UInt32>, into ranges: inout [Range<UInt32>]) {
    var merged = range
    var result: [Range<UInt32>] = []
    result.reserveCapacity(ranges.count + 1)
    var inserted = false
    for existing in ranges {
        if existing.upperBound < merged.lowerBound {
            result.append(existing)
        } else if merged.upperBound < existing.lowerBound {
            if !inserted {
                result.append(merged)
                inserted = true
            }
            result.append(existing)
        } else {
            merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
        }
    }
    if !inserted {
        result.append(merged)
    }
    ranges = result
}

@_spi(WebKitGPU)
extension DeviceReference {
    // https://gpuweb.github.io/gpuweb/#dom-gpudevice-createqueryset
    public func createQuerySet(_ descriptor: GPUQuerySetDescriptor, label: Swift.String?) -> QuerySetImpl {
        createQuerySetImpl(self, descriptor, label: WTF.String(label ?? ""), timestampCounterSet())
    }
}
