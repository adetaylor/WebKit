// Copyright (c) 2021-2023 Apple Inc. All rights reserved.
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

// The raw memory WebGPU shares with Metal: MTLBuffer contents, the bytes the encoders copy in, texture uploads and
// argument-buffer constants. Every `unsafe` the framework needs for them is in this file.

import Darwin
import Metal

extension MTLBuffer {
    // All `length` bytes of the contents, or nil for a buffer without CPU-visible contents (private storage).
    @inline(__always)
    func withCPUVisibleContents<R>(_ body: (inout MutableRawSpan) -> R) -> R? {
        let byteCount = length
        // Safety: contents() is null without CPU-visible storage, and the bit pattern round trip keeps the null check.
        guard let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: contents())) else {
            return nil
        }
        // Safety: Metal keeps `length` bytes at `base` for as long as the buffer, which the caller holds for the call.
        var contents = unsafe MutableRawSpan(_unsafeStart: base, byteCount: byteCount)
        return body(&contents)
    }

    // The contents, which a buffer the CPU writes into has: traps if a non-empty buffer has none.
    @inline(__always)
    func withContents<R>(_ body: (inout MutableRawSpan) -> R) -> R {
        if let result = withCPUVisibleContents(body) {
            return result
        }
        precondition(length == 0, "A buffer the CPU writes into has no contents")
        var empty = MutableRawSpan()
        return body(&empty)
    }
}

extension MutableRawSpan {
    // Copies `source` to `byteOffset`. Traps unless it fits.
    @inline(__always)
    mutating func copyMemory(from source: RawSpan, toByteOffset byteOffset: Int = 0) {
        precondition(byteOffset >= 0 && byteOffset <= byteCount && source.byteCount <= byteCount &- byteOffset)
        guard !source.isEmpty else {
            return
        }
        withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { sourceBytes in
                // Safety: the precondition keeps [byteOffset, byteOffset + source.byteCount) inside the destination.
                unsafe UnsafeMutableRawBufferPointer(rebasing: destination[byteOffset...]).copyMemory(from: sourceBytes)
            }
        }
    }

    // Zeroes `count` bytes from `byteOffset`. Traps unless they fit.
    @inline(__always)
    mutating func zeroBytes(at byteOffset: Int, count: Int) {
        precondition(byteOffset >= 0 && count >= 0 && byteOffset <= byteCount && count <= byteCount &- byteOffset)
        guard count != 0 else {
            return
        }
        // memset, as the C++ zeroSpan() was, so that a large zero fill isn't a byte loop in unoptimized builds.
        withUnsafeMutableBytes { bytes in
            // Safety: the precondition keeps [byteOffset, byteOffset + count) inside the span.
            _ = unsafe memset(UnsafeMutableRawBufferPointer(rebasing: bytes[byteOffset..<(byteOffset &+ count)]).baseAddress, 0, count)
        }
    }
}

// The contents of `buffer`, or none for nil.
@inline(__always)
func withContents<R>(of buffer: (any MTLBuffer)?, _ body: (inout MutableRawSpan) -> R) -> R {
    if let buffer {
        return buffer.withContents(body)
    }
    var empty = MutableRawSpan()
    return body(&empty)
}

// Copies `source` into the contents of `buffer` at `offset`. Traps unless it fits.
@inline(__always)
func copyBytes(_ source: RawSpan, toContentsOf buffer: (any MTLBuffer)?, at offset: UInt64) {
    withContents(of: buffer) { contents in
        guard let byteOffset = Int(exactly: offset) else {
            preconditionFailure("The offset is outside the contents")
        }
        contents.copyMemory(from: source, toByteOffset: byteOffset)
    }
}

// Zeroes `count` bytes of the contents of `buffer` from `offset`. Traps unless they fit.
@inline(__always)
func zeroContents(of buffer: (any MTLBuffer)?, at offset: UInt64, count: UInt64) {
    withContents(of: buffer) { contents in
        guard let byteOffset = Int(exactly: offset), let byteCount = Int(exactly: count) else {
            preconditionFailure("The range is outside the contents")
        }
        contents.zeroBytes(at: byteOffset, count: byteCount)
    }
}

// The bytes of `value`, as the encoders copy them in.
@inline(__always)
func withBytes<T: BitwiseCopyable, R>(of value: T, _ body: (RawSpan) -> R) -> R {
    withUnsafeBytes(of: value) { bytes in
        // Safety: the span is only used during `body`, while `bytes` stays valid.
        body(unsafe RawSpan(_unsafeBytes: bytes))
    }
}

extension MTLRenderCommandEncoder {
    // Metal copies the bytes before this returns. Nothing is bound for no bytes.
    @inline(__always)
    func setVertexBytes(_ bytes: RawSpan, index: Int) {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            // Safety: Metal reads `buffer.count` bytes from `baseAddress`, which `bytes` holds during the call.
            unsafe setVertexBytes(baseAddress, length: buffer.count, index: index)
        }
    }

    @inline(__always)
    func setFragmentBytes(_ bytes: RawSpan, index: Int) {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            // Safety: as setVertexBytes(_:index:).
            unsafe setFragmentBytes(baseAddress, length: buffer.count, index: index)
        }
    }
}

extension MTLComputeCommandEncoder {
    @inline(__always)
    func setBytes(_ bytes: RawSpan, index: Int) {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            // Safety: as MTLRenderCommandEncoder.setVertexBytes(_:index:).
            unsafe setBytes(baseAddress, length: buffer.count, index: index)
        }
    }
}

// The texel block of the format a texture write copies, from which replace(region:...) computes the bytes Metal reads.
struct TexelBlockLayout {
    var width: UInt32 = 1
    var height: UInt32 = 1
    var size: UInt32 = 0
}

// The bytes replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage: reads: each of the region's images,
// bytesPerImage apart, has its rows of blocks, bytesPerRow apart, and the last row is only as long as the region's blocks.
private func replaceRegionSourceSize(
    _ region: MTLRegion,
    _ bytesPerRow: UInt64,
    _ bytesPerImage: UInt64,
    _ block: TexelBlockLayout
) -> UInt64 {
    precondition(block.width != 0 && block.height != 0)
    let blockWidth = UInt64(block.width)
    let blockHeight = UInt64(block.height)
    let width = UInt64(region.size.width)
    let height = UInt64(region.size.height)
    let blocksPerRow = width / blockWidth + (width % blockWidth != 0 ? 1 : 0)
    let rows = height / blockHeight + (height % blockHeight != 0 ? 1 : 0)
    if blocksPerRow == 0 || rows == 0 || region.size.depth == 0 {
        return 0
    }
    let (images, imagesOverflow) = (UInt64(region.size.depth) - 1).multipliedReportingOverflow(by: bytesPerImage)
    let (rowBytes, rowsOverflow) = (rows - 1).multipliedReportingOverflow(by: bytesPerRow)
    let (lastRow, lastRowOverflow) = blocksPerRow.multipliedReportingOverflow(by: UInt64(block.size))
    let (partial, partialOverflow) = images.addingReportingOverflow(rowBytes)
    let (size, sizeOverflow) = partial.addingReportingOverflow(lastRow)
    precondition(!imagesOverflow && !rowsOverflow && !lastRowOverflow && !partialOverflow && !sizeOverflow)
    return size
}

// Uploads the bytes of `data` from `sourceOffset` into `texture`. Traps unless `data` holds every byte Metal reads.
func replaceRegion(
    of texture: (any MTLTexture)?,
    region: MTLRegion,
    mipmapLevel: UInt32,
    slice: UInt64,
    from data: RawSpan,
    sourceOffset: UInt64,
    bytesPerRow: UInt64,
    bytesPerImage: UInt64,
    block: TexelBlockLayout
) {
    guard let offset = Int(exactly: sourceOffset), offset <= data.byteCount else {
        preconditionFailure("The source offset is outside the data")
    }
    let source = data.extracting(offset..<data.byteCount)
    precondition(replaceRegionSourceSize(region, bytesPerRow, bytesPerImage, block) <= UInt64(source.byteCount))
    guard let texture else {
        return
    }
    source.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return
        }
        // Safety: the precondition above bounds every byte Metal reads by `bytes`.
        unsafe texture.replace(
            region: region,
            mipmapLevel: Int(mipmapLevel),
            slice: Int(truncatingIfNeeded: slice),
            withBytes: baseAddress,
            bytesPerRow: Int(truncatingIfNeeded: bytesPerRow),
            bytesPerImage: Int(truncatingIfNeeded: bytesPerImage)
        )
    }
}

extension MTLArgumentEncoder {
    // Writes `value` into the constant at `index` of the argument buffer, which the layout declared as a T. Nothing
    // for a constant Metal has no storage for.
    @inline(__always)
    func storeConstant<T: BitwiseCopyable>(_ value: T, at index: Int) {
        // Safety: as MTLBuffer.withCPUVisibleContents(_:), the round trip keeps the null check.
        guard let address = unsafe UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: constantData(at: index))) else {
            return
        }
        // Safety: Metal sizes the constant at `index` for the type the argument encoder's layout declared for it.
        unsafe address.storeBytes(of: value, as: T.self)
    }
}

// A buffer over `length` of the owner's bytes from `offset`, which keeps the owner alive for as long as it exists. nil
// when the owner has fewer bytes.
func makeBuffer(_ device: (any MTLDevice)?, aliasing owner: any GPUByteOwner, from offset: UInt64, length: UInt64) -> (any MTLBuffer)? {
    owner.withBytes { bytes -> (any MTLBuffer)? in
        let byteCount = UInt64(bytes.byteCount)
        guard offset <= byteCount, length <= byteCount - offset, let device else {
            return nil
        }
        return bytes.extracting(Int(offset)..<Int(offset + length))
            .withUnsafeBytes { range -> (any MTLBuffer)? in
                guard let baseAddress = range.baseAddress else {
                    return nil
                }
                // Safety: Metal reads the bytes in place until it destroys the buffer, and only then releases the
                // deallocator, which holds their owner, whose bytes stay at this address until it goes. The buffer is only
                // ever a copy source, so nothing writes to them.
                return unsafe device.makeBuffer(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                    length: range.count,
                    options: .storageModeShared,
                    deallocator: { _, _ in
                        withExtendedLifetime(owner) {
                        }
                    }
                )
            }
    }
}

// Makes CPU writes to the range of a managed buffer (Macs with discrete memory) visible to the GPU.
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "Managed buffers on Macs with discrete memory still need it")
#endif
func bufferDidModifyRange(_ buffer: any MTLBuffer, _ offset: UInt64, _ length: UInt64) {
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    buffer.didModifyRange(Int(truncatingIfNeeded: offset)..<Int(truncatingIfNeeded: offset &+ length))
    #endif
}
