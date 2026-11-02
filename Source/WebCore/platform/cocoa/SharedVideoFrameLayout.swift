// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

import CoreVideo
// The safe Span overloads Swift synthesizes for the views' span accessors call Cxx's Span(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.SharedVideoFrameSwiftBridge

// The encoded layout: its eight fields as native-endian 32-bit integers, in declaration order.
private let encodedLayoutByteCount = 32

// The functions C++ calls take and return CoreVideo's CVBuffer: WebCore's own CVPixelBufferRef declarations make
// CVPixelBuffer resolve differently in the generated header than in the compiled Swift.
@_expose(Cxx)
func sharedVideoFrameLayout(_ pixelBuffer: CVBuffer?) -> WebCore.SharedVideoFrameLayout {
    var layout = WebCore.SharedVideoFrameLayout()
    guard let pixelBuffer else {
        return layout
    }
    layout.bufferType = CVPixelBufferGetPixelFormatType(pixelBuffer)
    if layout.bufferType == kCVPixelFormatType_32BGRA || layout.bufferType == kCVPixelFormatType_32ARGB {
        layout.width = UInt32(truncatingIfNeeded: CVPixelBufferGetWidth(pixelBuffer))
        layout.height = UInt32(truncatingIfNeeded: CVPixelBufferGetHeight(pixelBuffer))
        layout.bytesPerRow = UInt32(truncatingIfNeeded: CVPixelBufferGetBytesPerRow(pixelBuffer))
        return layout
    }
    layout.width = UInt32(truncatingIfNeeded: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0))
    layout.height = UInt32(truncatingIfNeeded: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
    layout.bytesPerRow = UInt32(truncatingIfNeeded: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    layout.widthPlaneB = UInt32(truncatingIfNeeded: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1))
    layout.heightPlaneB = UInt32(truncatingIfNeeded: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
    layout.bytesPerRowPlaneB = UInt32(truncatingIfNeeded: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1))
    if layout.bufferType == kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar {
        layout.bytesPerRowPlaneAlpha = UInt32(truncatingIfNeeded: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2))
    }
    return layout
}

@_expose(Cxx)
func sharedVideoFrameIsReadWriteSupported(_ layout: WebCore.SharedVideoFrameLayout) -> Bool {
    switch layout.bufferType {
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
        return true
    default:
        return false
    }
}

// The header followed by every plane; 0 on overflow.
@_expose(Cxx)
func sharedVideoFrameStorageSize(_ layout: WebCore.SharedVideoFrameLayout, headerSize: UInt) -> UInt {
    guard let sizePlaneA = UInt(layout.bytesPerRow).checkedMultiplied(by: UInt(layout.height)),
        let sizePlaneB = UInt(layout.bytesPerRowPlaneB).checkedMultiplied(by: UInt(layout.heightPlaneB)),
        var size = sizePlaneA.checkedAdding(sizePlaneB)?.checkedAdding(headerSize)
    else {
        return 0
    }
    if layout.bufferType == kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar {
        let sizePlaneAlpha = UInt(layout.bytesPerRowPlaneAlpha).checkedMultiplied(by: UInt(layout.height))
        guard let sizeWithAlpha = sizePlaneAlpha?.checkedAdding(size) else {
            return 0
        }
        size = sizeWithAlpha
    }
    return size
}

private func encode(_ layout: WebCore.SharedVideoFrameLayout, into bytes: inout MutableRawSpan) {
    precondition(bytes.byteCount >= encodedLayoutByteCount)
    bytes.storeBytes(of: layout.bufferType, toByteOffset: 0, as: UInt32.self)
    bytes.storeBytes(of: layout.width, toByteOffset: 4, as: UInt32.self)
    bytes.storeBytes(of: layout.height, toByteOffset: 8, as: UInt32.self)
    bytes.storeBytes(of: layout.bytesPerRow, toByteOffset: 12, as: UInt32.self)
    bytes.storeBytes(of: layout.widthPlaneB, toByteOffset: 16, as: UInt32.self)
    bytes.storeBytes(of: layout.heightPlaneB, toByteOffset: 20, as: UInt32.self)
    bytes.storeBytes(of: layout.bytesPerRowPlaneB, toByteOffset: 24, as: UInt32.self)
    bytes.storeBytes(of: layout.bytesPerRowPlaneAlpha, toByteOffset: 28, as: UInt32.self)
}

// Writes the first 32 bytes of `destination`, and traps if there are fewer.
@_expose(Cxx)
func sharedVideoFrameEncode(_ layout: WebCore.SharedVideoFrameLayout, _ destination: inout WebCore.MutablePixelBytes) {
    var span: MutableSpan<UInt8> = destination.mutableSpan()
    var bytes = span.mutableBytes
    encode(layout, into: &bytes)
}

// False for fewer than 32 bytes or a layout whose storage size overflows.
@_expose(Cxx)
func sharedVideoFrameDecode(
    _ source: borrowing WebCore.PixelBytes,
    headerSize: UInt,
    _ layout: inout WebCore.SharedVideoFrameLayout
) -> Bool {
    let span: Span<UInt8> = source.span()
    let bytes = span.bytes
    guard bytes.byteCount >= encodedLayoutByteCount else {
        return false
    }
    var decoded = WebCore.SharedVideoFrameLayout()
    decoded.bufferType = bytes.load(fromByteOffset: 0, as: UInt32.self)
    decoded.width = bytes.load(fromByteOffset: 4, as: UInt32.self)
    decoded.height = bytes.load(fromByteOffset: 8, as: UInt32.self)
    decoded.bytesPerRow = bytes.load(fromByteOffset: 12, as: UInt32.self)
    decoded.widthPlaneB = bytes.load(fromByteOffset: 16, as: UInt32.self)
    decoded.heightPlaneB = bytes.load(fromByteOffset: 20, as: UInt32.self)
    decoded.bytesPerRowPlaneB = bytes.load(fromByteOffset: 24, as: UInt32.self)
    decoded.bytesPerRowPlaneAlpha = bytes.load(fromByteOffset: 28, as: UInt32.self)
    guard sharedVideoFrameStorageSize(decoded, headerSize: headerSize) != 0 else {
        return false
    }
    layout = decoded
    return true
}

// CoreVideo documents its plane accessors as not covering non-planar buffers, so plane 0 of one is the whole buffer.
private func isWholeBuffer(_ pixelBuffer: CVPixelBuffer, _ plane: Int) -> Bool {
    plane == 0 && CVPixelBufferGetPlaneCount(pixelBuffer) == 0
}

private func planeBytesPerRow(_ pixelBuffer: CVPixelBuffer, _ plane: Int) -> Int {
    isWholeBuffer(pixelBuffer, plane)
        ? CVPixelBufferGetBytesPerRow(pixelBuffer) : CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
}

// The bytes of a plane of a locked pixel buffer: its rows, bounded by the buffer's data size. Nil when CoreVideo
// gives the plane no memory.
private func planeByteCount(_ pixelBuffer: CVPixelBuffer, _ plane: Int) -> Int? {
    let height =
        isWholeBuffer(pixelBuffer, plane)
        ? CVPixelBufferGetHeight(pixelBuffer) : CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
    guard let byteCount = planeBytesPerRow(pixelBuffer, plane).checkedMultiplied(by: height),
        byteCount <= CVPixelBufferGetDataSize(pixelBuffer)
    else {
        return nil
    }
    return byteCount
}

// Reads a plane of a pixel buffer locked for reading. Nil when CoreVideo gives the plane no memory.
private func withPlaneBytes<Result>(
    _ pixelBuffer: CVPixelBuffer,
    _ plane: Int,
    _ body: (Span<UInt8>) -> Result
) -> Result? {
    let wholeBuffer = isWholeBuffer(pixelBuffer, plane)
    guard let byteCount = planeByteCount(pixelBuffer, plane),
        let base = unsafe wholeBuffer
            ? CVPixelBufferGetBaseAddress(pixelBuffer) : CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
    else {
        return nil
    }
    // CoreVideo's plane geometry: the plane's rows start at `base`, inside the locked buffer.
    return body(unsafe UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: byteCount).span)
}

// Writes a plane of a pixel buffer locked for writing. Nil when CoreVideo gives the plane no memory.
private func withMutablePlaneBytes<Result>(
    _ pixelBuffer: CVPixelBuffer,
    _ plane: Int,
    _ body: (inout MutableSpan<UInt8>) -> Result
) -> Result? {
    let wholeBuffer = isWholeBuffer(pixelBuffer, plane)
    guard let byteCount = planeByteCount(pixelBuffer, plane),
        let base = unsafe wholeBuffer
            ? CVPixelBufferGetBaseAddress(pixelBuffer) : CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
    else {
        return nil
    }
    // CoreVideo's plane geometry: the plane's rows start at `base`, inside the locked buffer.
    var bytes = unsafe UnsafeMutableBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: byteCount).mutableSpan
    return body(&bytes)
}

// Copies `rows` rows of `sourceBytesPerRow` bytes from `source` at `offset` to the first rows of `plane`, cutting or
// zero-padding each to the plane's row size, and zeroes the rest of the plane. False, without writing, when either
// side is too short.
private func copyRows(
    from source: Span<UInt8>,
    offset: inout Int,
    rows: Int,
    sourceBytesPerRow: Int,
    to plane: inout MutableSpan<UInt8>,
    planeBytesPerRow: Int
) -> Bool {
    guard let sourceByteCount = rows.checkedMultiplied(by: sourceBytesPerRow),
        let sourceEnd = offset.checkedAdding(sourceByteCount), sourceEnd <= source.count,
        let planeRowsByteCount = rows.checkedMultiplied(by: planeBytesPerRow), planeRowsByteCount <= plane.count
    else {
        return false
    }
    let rowBytes = min(sourceBytesPerRow, planeBytesPerRow)
    var planeOffset = 0
    for _ in 0..<rows {
        copyBytes(from: source, at: offset, to: &plane, at: planeOffset, count: rowBytes)
        withMutableSubspan(of: &plane, planeOffset + rowBytes..<planeOffset + planeBytesPerRow) { $0.update(repeating: 0) }
        offset += sourceBytesPerRow
        planeOffset += planeBytesPerRow
    }
    withMutableSubspan(of: &plane, planeOffset..<plane.count) { $0.update(repeating: 0) }
    return true
}

private func copyRows(
    from source: Span<UInt8>,
    offset: inout Int,
    rows: Int,
    sourceBytesPerRow: Int,
    toPlane plane: Int,
    of pixelBuffer: CVPixelBuffer
) -> Bool {
    let bytesPerRow = planeBytesPerRow(pixelBuffer, plane)
    let copied = withMutablePlaneBytes(pixelBuffer, plane) { bytes in
        copyRows(
            from: source,
            offset: &offset,
            rows: rows,
            sourceBytesPerRow: sourceBytesPerRow,
            to: &bytes,
            planeBytesPerRow: bytesPerRow
        )
    }
    return copied ?? false
}

// The planes follow each other in `source`, plane A's rows `layout.bytesPerRow` apart and so on. Every byte of every
// plane of `pixelBuffer` is written.
private func copyPlanes(_ layout: WebCore.SharedVideoFrameLayout, from source: Span<UInt8>, to pixelBuffer: CVPixelBuffer) -> Bool {
    guard let height = Int(exactly: layout.height), let bytesPerRow = Int(exactly: layout.bytesPerRow),
        let heightPlaneB = Int(exactly: layout.heightPlaneB), let bytesPerRowPlaneB = Int(exactly: layout.bytesPerRowPlaneB),
        let bytesPerRowPlaneAlpha = Int(exactly: layout.bytesPerRowPlaneAlpha)
    else {
        return false
    }
    var offset = 0
    guard copyRows(from: source, offset: &offset, rows: height, sourceBytesPerRow: bytesPerRow, toPlane: 0, of: pixelBuffer)
    else {
        return false
    }
    let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
    if planeCount < 2 {
        return true
    }
    let rowsPlaneB = min(heightPlaneB, CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
    guard
        copyRows(
            from: source,
            offset: &offset,
            rows: rowsPlaneB,
            sourceBytesPerRow: bytesPerRowPlaneB,
            toPlane: 1,
            of: pixelBuffer
        )
    else {
        return false
    }
    if planeCount != 3 {
        return true
    }
    return copyRows(
        from: source,
        offset: &offset,
        rows: height,
        sourceBytesPerRow: bytesPerRowPlaneAlpha,
        toPlane: 2,
        of: pixelBuffer
    )
}

// The bytes that the encoding of a plane of `rows` rows of `pixelBytesPerRow` bytes of pixels takes, when the encoding
// has `encodedRows` rows of `encodedBytesPerRow` bytes. Nil if those rows can't fill the plane.
private func encodedPlaneByteCount(rows: Int, pixelBytesPerRow: Int, encodedRows: UInt32, encodedBytesPerRow: UInt32) -> Int? {
    guard UInt(encodedRows) >= UInt(rows), UInt(encodedBytesPerRow) >= UInt(pixelBytesPerRow),
        let encodedBytesPerRow = Int(exactly: encodedBytesPerRow)
    else {
        return nil
    }
    return rows.checkedMultiplied(by: encodedBytesPerRow)
}

// The widest and tallest frame: createBlackPixelBuffer()'s limit (maxIOSurfaceWidth) for frame sizes that come over IPC.
private let maximumFrameDimension: UInt32 = 1 << 15

// Whether `byteCount` bytes of encoded planes fill every pixel of a frame of `layout`'s format and size, laid out as
// CoreVideo lays out its buffers: each plane needs as many encoded rows as it has, each at least as long as its pixels.
private func encodedPlanesFillFrame(_ layout: WebCore.SharedVideoFrameLayout, byteCount: Int) -> Bool {
    guard layout.width <= maximumFrameDimension, layout.height <= maximumFrameDimension else {
        return false
    }
    let planes: (bytesPerPixel: Int, chromaBytesPerPixel: Int, hasAlphaPlane: Bool)
    switch layout.bufferType {
    case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
        planes = (4, 0, false)
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        planes = (1, 2, false)
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        planes = (2, 4, false)
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
        planes = (1, 2, true)
    default:
        return false
    }
    let width = Int(layout.width)
    let height = Int(layout.height)
    guard
        var total = encodedPlaneByteCount(
            rows: height,
            pixelBytesPerRow: width * planes.bytesPerPixel,
            encodedRows: layout.height,
            encodedBytesPerRow: layout.bytesPerRow
        )
    else {
        return false
    }
    if planes.chromaBytesPerPixel > 0 {
        guard
            let chroma = encodedPlaneByteCount(
                rows: (height + 1) / 2,
                pixelBytesPerRow: (width + 1) / 2 * planes.chromaBytesPerPixel,
                encodedRows: layout.heightPlaneB,
                encodedBytesPerRow: layout.bytesPerRowPlaneB
            ),
            let sum = total.checkedAdding(chroma)
        else {
            return false
        }
        total = sum
    }
    if planes.hasAlphaPlane {
        guard
            let alpha = encodedPlaneByteCount(
                rows: height,
                pixelBytesPerRow: width,
                encodedRows: layout.height,
                encodedBytesPerRow: layout.bytesPerRowPlaneAlpha
            ),
            let sum = total.checkedAdding(alpha)
        else {
            return false
        }
        total = sum
    }
    return total <= byteCount
}

// A new pixel buffer, from `pool` when there is one, holding the planes `source` holds. Returned +1. Nil, without
// creating a buffer, when `source` can't fill every pixel of it.
@_expose(Cxx)
func sharedVideoFrameCreatePixelBuffer(
    _ layout: WebCore.SharedVideoFrameLayout,
    _ source: borrowing WebCore.PixelBytes,
    _ pool: CVPixelBufferPool?
) -> CVBuffer? {
    let bytes: Span<UInt8> = source.span()
    guard encodedPlanesFillFrame(layout, byteCount: bytes.count) else {
        return nil
    }
    var created: CVPixelBuffer?
    // Both only write the new buffer through the out-parameter.
    let status =
        if let pool {
            unsafe CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        } else {
            unsafe CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(bitPattern: UInt(layout.width)),
                Int(bitPattern: UInt(layout.height)),
                layout.bufferType,
                nil,
                &created
            )
        }
    guard status == kCVReturnSuccess, let pixelBuffer = created else {
        return nil
    }
    if pool != nil {
        assert(UInt(bitPattern: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)) == UInt(layout.width))
        assert(UInt(bitPattern: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)) == UInt(layout.height))
        assert(CVPixelBufferGetPixelFormatType(pixelBuffer) == layout.bufferType)
    }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
        return nil
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    return copyPlanes(layout, from: bytes, to: pixelBuffer) ? pixelBuffer : nil
}

private enum PlaneAppend {
    case appended
    case noPlane
    case storageTooSmall
}

private func appendPlane(
    _ plane: Int,
    of pixelBuffer: CVPixelBuffer,
    to storage: inout MutableSpan<UInt8>,
    offset: inout Int
) -> PlaneAppend {
    let appended = withPlaneBytes(pixelBuffer, plane) { bytes -> PlaneAppend in
        guard let end = offset.checkedAdding(bytes.count), end <= storage.count else {
            return .storageTooSmall
        }
        copyBytes(from: bytes, at: 0, to: &storage, at: offset, count: bytes.count)
        offset = end
        return .appended
    }
    return appended ?? .noPlane
}

// Writes the encoded layout at the start of `destination`, then every plane of `pixelBuffer` from `headerSize` on.
@_expose(Cxx)
func sharedVideoFrameWritePixelBuffer(
    _ layout: WebCore.SharedVideoFrameLayout,
    _ pixelBuffer: CVBuffer?,
    headerSize: UInt,
    _ destination: inout WebCore.MutablePixelBytes
) -> WebCore.SharedVideoFrameWriteResult {
    guard let pixelBuffer, CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
        return .LockFailed
    }
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    guard unsafe CVPixelBufferGetBaseAddress(pixelBuffer) != nil else {
        return .NotReadable
    }
    var storage: MutableSpan<UInt8> = destination.mutableSpan()
    guard let headerSize = Int(exactly: headerSize), headerSize >= encodedLayoutByteCount, headerSize <= storage.count else {
        return .StorageTooSmall
    }
    var header = storage.mutableBytes
    encode(layout, into: &header)

    var offset = headerSize
    switch appendPlane(0, of: pixelBuffer, to: &storage, offset: &offset) {
    case .appended:
        break
    case .noPlane:
        return .PlaneANull
    case .storageTooSmall:
        return .StorageTooSmall
    }
    let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
    if planeCount < 2 {
        return .Success
    }
    switch appendPlane(1, of: pixelBuffer, to: &storage, offset: &offset) {
    case .appended:
        break
    case .noPlane:
        return .PlaneBNull
    case .storageTooSmall:
        return .StorageTooSmall
    }
    if planeCount != 3 {
        return .Success
    }
    switch appendPlane(2, of: pixelBuffer, to: &storage, offset: &offset) {
    case .appended:
        return .Success
    case .noPlane:
        return .PlaneAlphaNull
    case .storageTooSmall:
        return .StorageTooSmall
    }
}

#endif // ENABLE_WEBCORE_SWIFT
