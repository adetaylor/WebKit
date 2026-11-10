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
import simd

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

// The texel block of a texture's pixel format, which replaceRegion() copies by: traps for a format WebGPU doesn't make,
// or one with both a depth and a stencil aspect, which the CPU writes never upload into.
private func texelBlock(of texture: any MTLTexture) -> TexelBlockLayout {
    guard let format = textureFormat(texture.pixelFormat), !containsDepthAspect(format) || !containsStencilAspect(format) else {
        preconditionFailure("No texel block for the texture's pixel format")
    }
    let block = TexelBlockLayout(width: texelBlockWidth(format), height: texelBlockHeight(format), size: texelBlockSize(format))
    precondition(block.width != 0 && block.height != 0 && block.size != 0)
    return block
}

// Uploads the bytes of `data` from `sourceOffset` into `region` of `texture` at `mipmapLevel` and `slice`, by the texel
// blocks of the texture's pixel format. Traps unless the region, the level and the slice are in the texture, the strides
// are at least as long as the rows and images they step over, and `data` holds every byte Metal reads.
func replaceRegion(
    of texture: (any MTLTexture)?,
    region: MTLRegion,
    mipmapLevel: UInt32,
    slice: UInt64,
    from data: RawSpan,
    sourceOffset: UInt64,
    bytesPerRow: UInt64,
    bytesPerImage: UInt64
) {
    guard let offset = Int(exactly: sourceOffset), offset <= data.byteCount else {
        preconditionFailure("The source offset is outside the data")
    }
    let source = data.extracting(offset..<data.byteCount)
    guard let texture else {
        return
    }
    let block = texelBlock(of: texture)

    // The destination: the level's extent, rounded up to whole blocks as WebGPU's physical extent is.
    let level = Int(mipmapLevel)
    precondition(level < texture.mipmapLevelCount, "The level is outside the texture")
    func levelExtent(_ size: Int, _ blockSize: UInt32) -> UInt64 {
        let extent = UInt64(max(1, size >> level))
        let blockSize = UInt64(blockSize)
        return (extent + blockSize - 1) / blockSize * blockSize
    }
    let is3D = texture.textureType == .type3D
    let extentWidth = levelExtent(texture.width, block.width)
    let extentHeight = levelExtent(texture.height, block.height)
    let extentDepth = is3D ? levelExtent(texture.depth, 1) : 1
    func fits(_ origin: Int, _ size: Int, _ extent: UInt64) -> Bool {
        guard let origin = UInt64(exactly: origin), let size = UInt64(exactly: size) else {
            return false
        }
        let (end, overflow) = origin.addingReportingOverflow(size)
        return !overflow && end <= extent
    }
    precondition(
        fits(region.origin.x, region.size.width, extentWidth) && fits(region.origin.y, region.size.height, extentHeight)
            && fits(region.origin.z, region.size.depth, extentDepth),
        "The region is outside the texture"
    )
    let sliceCount: Int
    switch texture.textureType {
    case .type1DArray, .type2DArray:
        sliceCount = texture.arrayLength
    case .typeCube:
        sliceCount = 6
    case .typeCubeArray:
        sliceCount = 6 * texture.arrayLength
    default:
        sliceCount = 1
    }
    guard let destinationSlice = Int(exactly: slice), destinationSlice < sliceCount else {
        preconditionFailure("The slice is outside the texture")
    }

    // The source: rows of blocks, bytesPerRow apart, in images bytesPerImage apart; the last row only as long as the
    // region's blocks.
    let width = UInt64(region.size.width)
    let height = UInt64(region.size.height)
    let depth = UInt64(region.size.depth)
    let blocksPerRow = (width + UInt64(block.width) - 1) / UInt64(block.width)
    let rows = (height + UInt64(block.height) - 1) / UInt64(block.height)
    if blocksPerRow == 0 || rows == 0 || depth == 0 {
        return
    }
    let (rowBytes, rowBytesOverflow) = blocksPerRow.multipliedReportingOverflow(by: UInt64(block.size))
    let (rowSpan, rowSpanOverflow) = (rows - 1).multipliedReportingOverflow(by: bytesPerRow)
    let (imageBytes, imageBytesOverflow) = rowSpan.addingReportingOverflow(rowBytes)
    let (imageSpan, imageSpanOverflow) = (depth - 1).multipliedReportingOverflow(by: bytesPerImage)
    let (sourceSize, sourceSizeOverflow) = imageSpan.addingReportingOverflow(imageBytes)
    precondition(!rowBytesOverflow && !rowSpanOverflow && !imageBytesOverflow && !imageSpanOverflow && !sourceSizeOverflow)
    precondition(rows == 1 || bytesPerRow >= rowBytes, "The rows overlap")
    precondition(depth == 1 || bytesPerImage >= imageBytes, "The images overlap")
    precondition(sourceSize <= UInt64(source.byteCount), "The data doesn't hold the region")
    guard let metalBytesPerRow = Int(exactly: bytesPerRow), let metalBytesPerImage = Int(exactly: bytesPerImage) else {
        preconditionFailure("The strides don't fit in Int")
    }
    source.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
            return
        }
        // Safety: Metal writes the region of the level and slice, which the preconditions keep in the texture, and reads
        // `sourceSize` bytes, by the blocks of the texture's own format, with strides no shorter than what they step over,
        // which the preconditions keep in `bytes`.
        unsafe texture.replace(
            region: region,
            mipmapLevel: level,
            slice: destinationSlice,
            withBytes: baseAddress,
            bytesPerRow: metalBytesPerRow,
            bytesPerImage: metalBytesPerImage
        )
    }
}

/// Writes the constant arguments of an argument buffer: each store traps unless the layout declared a constant of the
/// stored type at the index, and the buffer holds the encoder's encodedLength bytes from the offset, where Metal places
/// every argument of the encoder.
struct ArgumentConstantWriter {
    private let encoder: any MTLArgumentEncoder
    private let buffer: any MTLBuffer
    private let offset: Int
    private let constantTypes: [UInt32: MTLDataType]

    /// nil without an encoder or a buffer, or unless the buffer has CPU-visible contents and holds the encoder's
    /// encodedLength bytes from `offset`. `constantTypes` are the data types of the arguments the encoder was made with,
    /// by index.
    init?(_ encoder: (any MTLArgumentEncoder)?, constantTypes: [UInt32: MTLDataType], buffer: (any MTLBuffer)?, offset: Int = 0) {
        guard let encoder, let buffer, buffer.storageMode != .private, offset >= 0, offset <= buffer.length,
            buffer.length - offset >= encoder.encodedLength
        else {
            return nil
        }
        self.encoder = encoder
        self.buffer = buffer
        self.offset = offset
        self.constantTypes = constantTypes
    }

    func storeInt(_ value: UInt32, at index: UInt32) {
        store(value, as: .int, at: index)
    }

    func storeUInt2(_ value: SIMD2<UInt32>, at index: UInt32) {
        store(value, as: .uint2, at: index)
    }

    func storeFloat3x2(_ value: simd_float3x2, at index: UInt32) {
        store(value, as: .float3x2, at: index)
    }

    func storeFloat4x3(_ value: simd_float4x3, at index: UInt32) {
        store(value, as: .float4x3, at: index)
    }

    func storeFloat3x4(_ value: simd_float3x4, at index: UInt32) {
        store(value, as: .float3x4, at: index)
    }

    // `T` is the Swift type of a Metal argument of `dataType`: the functions above pair them.
    private func store<T: BitwiseCopyable>(_ value: T, as dataType: MTLDataType, at index: UInt32) {
        precondition(constantTypes[index] == dataType, "The layout has no constant of this type at the index")
        encoder.setArgumentBuffer(buffer, offset: offset)
        let encodedLength = UInt(encoder.encodedLength)
        // Safety: pointers as integers, for the bounds check below.
        let contents = unsafe UInt(bitPattern: buffer.contents())
        let constant = unsafe UInt(bitPattern: encoder.constantData(at: Int(index)))
        let start = contents &+ UInt(offset)
        precondition(
            contents != 0 && constant >= start && constant - start <= encodedLength
                && UInt(MemoryLayout<T>.size) <= encodedLength - (constant - start),
            "The constant is outside the argument buffer"
        )
        // Safety: the contents of a buffer with CPU-visible storage stay at this address for as long as the buffer, which
        // holds the encoder's encodedLength bytes from `offset` (init), and the precondition keeps the store inside them.
        unsafe UnsafeMutableRawPointer(bitPattern: constant)?.storeBytes(of: value, as: T.self)
    }
}

// A buffer over `length` of the owner's bytes from `offset`, which keeps the owner alive for as long as it exists. nil
// when the owner has fewer bytes. Safe because only GPUByteOwner's unsafe initializer makes an owner, whose caller
// promises that the bytes stay put for as long as the owner exists.
func makeBuffer(_ device: (any MTLDevice)?, aliasing owner: GPUByteOwner, from offset: UInt64, length: UInt64) -> (any MTLBuffer)? {
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
