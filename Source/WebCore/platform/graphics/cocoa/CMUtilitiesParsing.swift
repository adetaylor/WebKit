// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

private import Cxx
import WebCore_Internal.CMParsingTypes
import WebCore_Internal.MediaParsersCxxBridging

// The parsing and arithmetic of CMUtilities.mm, whose CoreMedia, CoreVideo and AudioToolbox calls stay in C++.

// MARK: Extension atom keys

// A SampleDescriptionExtensionAtoms key is a FourCC when it has four characters; each gives its low 8 bits.
@_expose(Cxx)
func extensionAtomFourCCImpl(_ key: WebCore.ExtensionAtomKey) -> WebCore.FourCCResult {
    var result = WebCore.FourCCResult()
    guard key.length == 4 else {
        return result
    }
    let characters = key.characters
    for character in [characters.0, characters.1, characters.2, characters.3] {
        result.value = result.value << 8 | UInt32(character & 0xFF)
    }
    result.valid = true
    return result
}

// A key has to be four printable ASCII characters.
@_expose(Cxx)
func isExtensionAtomFourCCImpl(_ fourCC: UInt32) -> Bool {
    for shift in stride(from: 24, through: 0, by: -8) {
        let character = UInt8(truncatingIfNeeded: fourCC >> UInt32(shift))
        guard character >= 0x20 && character <= 0x7E else {
            return false
        }
    }
    return true
}

// MARK: Video geometry

// Truncated toward zero. Fails for a value that isn't finite or doesn't fit in an Int32.
@_expose(Cxx)
func videoDimensionsImpl(_ width: Float, _ height: Float) -> WebCore.VideoDimensionsResult {
    var result = WebCore.VideoDimensionsResult()
    guard let width = int32TruncatingTowardZero(width), let height = int32TruncatingTowardZero(height) else {
        return result
    }
    result.dimensions = WebCore.VideoDimensions32(width: width, height: height)
    result.valid = true
    return result
}

private func int32TruncatingTowardZero(_ value: Float) -> Int32? {
    // Both bounds are exactly representable; no Float lies strictly between -2^31 - 1 and -2^31.
    guard value >= -2_147_483_648 && value < 2_147_483_648 else {
        return nil
    }
    return Int32(value)
}

// displayWidth * height : displayHeight * width, each product rounded like std::llround, in lowest terms. None when a
// size is empty, the sizes are equal, or a product doesn't round to a positive Int64.
@_expose(Cxx)
func pixelAspectRatioImpl(
    _ width: Float,
    _ height: Float,
    _ displayWidth: Float,
    _ displayHeight: Float
) -> WebCore.PixelAspectRatioResult {
    var result = WebCore.PixelAspectRatioResult()
    // FloatSize::isEmpty() and operator!=: a NaN dimension is neither empty nor equal.
    let isEmpty = width <= 0 || height <= 0
    let isDisplayEmpty = displayWidth <= 0 || displayHeight <= 0
    let isSame = width == displayWidth && height == displayHeight
    guard !isEmpty && !isDisplayEmpty && !isSame else {
        return result
    }
    // The products are computed in Float.
    guard let horizontal = roundedToInt64(displayWidth * height), let vertical = roundedToInt64(displayHeight * width),
        horizontal > 0 && vertical > 0
    else {
        return result
    }
    let divisor = greatestCommonDivisor(horizontal, vertical)
    result.spacings = WebCore.PixelAspectRatioSpacings(horizontal: horizontal / divisor, vertical: vertical / divisor)
    result.valid = true
    return result
}

private func roundedToInt64(_ value: Float) -> Int64? {
    guard value.isFinite else {
        return nil
    }
    return Int64(exactly: value.rounded(.toNearestOrAwayFromZero))
}

private func greatestCommonDivisor(_ first: Int64, _ second: Int64) -> Int64 {
    var a = first
    var b = second
    while b != 0 {
        (a, b) = (b, a % b)
    }
    return a
}

// MARK: I420 to biplanar

// Fails, copying nothing, unless source is exactly one width x height I420 frame and the planes are its size.
@_expose(Cxx)
func copyI420ToBiplanarImpl(
    _ source: borrowing WebCore.MediaParserBytes,
    _ width: Int,
    _ height: Int,
    _ layout: WebCore.BiplanarPixelBufferLayout,
    _ luma: borrowing WebCore.MutablePixelPlane,
    _ chroma: borrowing WebCore.MutablePixelPlane
) -> Bool {
    let bytes: Span<UInt8> = source.span()
    guard width >= 0 && height >= 0 else {
        return false
    }
    let chromaWidth = width / 2 + width % 2
    let chromaHeight = height / 2 + height % 2
    guard let lumaSize = multiplied(width, height), let chromaSize = multiplied(chromaWidth, chromaHeight),
        let bothChromaSizes = multiplied(chromaSize, 2), let frameSize = added(lumaSize, bothChromaSizes),
        bytes.count == frameSize
    else {
        return false
    }

    guard
        layout.planeCount == 2 && layout.lumaWidth == width && layout.lumaHeight == height
            && layout.chromaWidth == chromaWidth && layout.chromaHeight == chromaHeight
    else {
        return false
    }

    var lumaPlane: MutableSpan<UInt8> = luma.mutableSpan()
    var chromaPlane: MutableSpan<UInt8> = chroma.mutableSpan()
    let lumaStride = layout.lumaBytesPerRow
    let chromaStride = layout.chromaBytesPerRow
    guard let chromaRowSize = multiplied(chromaWidth, 2), lumaStride >= width && chromaStride >= chromaRowSize,
        let lumaPlaneSize = multiplied(lumaStride, height), let chromaPlaneSize = multiplied(chromaStride, chromaHeight),
        lumaPlane.count >= lumaPlaneSize && chromaPlane.count >= chromaPlaneSize
    else {
        return false
    }

    // Every row offset below is within the sizes checked above.
    guard width > 0 else {
        return true
    }
    for row in 0..<height {
        let sourceStart = row * width
        copyBytes(bytes.extracting(sourceStart..<(sourceStart + width)), into: &lumaPlane, at: row * lumaStride)
    }
    let uPlane = bytes.extracting(lumaSize..<(lumaSize + chromaSize))
    let vPlane = bytes.extracting((lumaSize + chromaSize)..<frameSize)
    for row in 0..<chromaHeight {
        let sourceStart = row * chromaWidth
        let sourceRange = sourceStart..<(sourceStart + chromaWidth)
        WebCore.interleaveBytes(&chromaPlane, row * chromaStride, uPlane.extracting(sourceRange), vPlane.extracting(sourceRange))
    }
    return true
}

private func multiplied(_ first: Int, _ second: Int) -> Int? {
    let (result, overflow) = first.multipliedReportingOverflow(by: second)
    return overflow ? nil : result
}

private func added(_ first: Int, _ second: Int) -> Int? {
    let (result, overflow) = first.addingReportingOverflow(second)
    return overflow ? nil : result
}

// MARK: Length-prefixed to Annex B

// Each 32-bit big-endian NAL unit length becomes the start code 00 00 00 01. Appends nothing when a NAL unit runs past
// the end.
@_expose(Cxx)
func appendAnnexBFromLengthPrefixedImpl(_ data: borrowing WebCore.MediaParserBytes, _ output: inout WebCore.MediaParserByteVector) -> Bool {
    let bytes: Span<UInt8> = data.span()
    var offset = 0
    while offset < bytes.count {
        guard let packetSize = lengthPrefixedPacketSize(bytes, at: offset) else {
            return false
        }
        offset += 4 + packetSize
    }
    if bytes.isEmpty {
        return true
    }

    // Start codes and lengths have the same size.
    let start = output.size()
    WebCore.appendBytes(&output, bytes)
    var annexB: MutableSpan<UInt8> = output.mutableSpan()
    offset = 0
    while offset < bytes.count {
        guard let packetSize = lengthPrefixedPacketSize(bytes, at: offset) else {
            return false
        }
        annexB[start + offset] = 0
        annexB[start + offset + 1] = 0
        annexB[start + offset + 2] = 0
        annexB[start + offset + 3] = 1
        offset += 4 + packetSize
    }
    return true
}

private func lengthPrefixedPacketSize(_ bytes: Span<UInt8>, at offset: Int) -> Int? {
    let remaining = bytes.count - offset
    guard remaining >= 4 else {
        return nil
    }
    let length = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    // On 32-bit, a length that doesn't fit in an Int is rejected too.
    guard let packetSize = Int(exactly: length), packetSize <= remaining - 4 else {
        return nil
    }
    return packetSize
}

// MARK: Vorbis packet durations

// ilog(modeCount - 1) bits. A stream has at least one mode.
@_expose(Cxx)
func vorbisModeMaskImpl(_ modeCount: UInt32) -> WebCore.VorbisModeMaskResult {
    var result = WebCore.VorbisModeMaskResult()
    guard modeCount > 0 else {
        return result
    }
    let bitCount = UInt32.bitWidth - (modeCount - 1).leadingZeroBitCount
    result.modeMask = bitCount == UInt32.bitWidth ? .max : (1 << UInt32(bitCount)) - 1
    result.valid = true
    return result
}

@_expose(Cxx)
func vorbisPacketFramesImpl(
    _ packet: borrowing WebCore.MediaParserBytes,
    _ mode: WebCore.VorbisModeParameters,
    _ lastBlockSize: UInt32
) -> WebCore.VorbisPacketFrames {
    var result = WebCore.VorbisPacketFrames()
    result.lastBlockSize = lastBlockSize
    result.frames = UInt64(vorbisPacketFrames(packet.span(), mode, &result.lastBlockSize))
    return result
}

private func vorbisPacketFrames(_ bytes: Span<UInt8>, _ mode: WebCore.VorbisModeParameters, _ lastBlockSize: inout UInt32) -> Int {
    // The following calculation corresponds to the duration of the "finished audiodata"
    // produced by the decoder from the current packet in its position within
    // the stream, as documented by Xiph in the Vorbis I specification.
    // It also corresponds to the delta in granule position of the packet within
    // the same sequence of packets in an Ogg file, with the possible exception of
    // the ultimate packet, which may be assigned a smaller delta for the purpose
    // of trimming.
    guard !bytes.isEmpty else {
        return 0
    }
    let leadingByte = bytes[0]
    if leadingByte & 0b1 != 0 {
        return 0 // Not an audio packet.
    }
    let modeIndex = UInt32(leadingByte >> 1) & mode.modeMask
    guard modeIndex < mode.modeCount else {
        return 0 // Invalid mode.
    }
    // mModeFlags only has bits for the first 64 modes; any later mode is a short block.
    let isLongBlock = modeIndex < 64 && (mode.modeFlags >> UInt64(modeIndex)) & 1 != 0
    let blockSize = isLongBlock ? mode.longBlockSize : mode.shortBlockSize
    // The first vorbis packet decoded doesn't output audible content, and should be undetermined.
    // However as content could be fed in any order, we must assume that previous content could be available at some stage.
    let frames = (blockSize &+ lastBlockSize) / 4
    lastBlockSize = blockSize
    return Int(frames)
}

// MARK: Audio sample rates

// Truncated toward zero; 0 for a value that doesn't truncate to a UInt32, such as NaN.
@_expose(Cxx)
func audioSampleRateImpl(_ sampleRate: Double) -> UInt32 {
    guard sampleRate > -1 && sampleRate < 4_294_967_296 else {
        return 0
    }
    return UInt32(sampleRate)
}

#endif // ENABLE_WEBCORE_SWIFT
