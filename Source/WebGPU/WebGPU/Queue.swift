// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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

import CoreVideo
import Dispatch
import Foundation
import IOSurface
import Metal
import WebGPU_Internal.APIConversions
import WebGPU_Internal.BindGroup
import WebGPU_Internal.Buffer
import WebGPU_Internal.CommandBuffer
import WebGPU_Internal.CommandEncoder
import WebGPU_Internal.CxxBridging
import WebGPU_Internal.Device
import WebGPU_Internal.Queue
import WebGPU_Internal.Texture
import WebGPU_Private.WebGPU
import WebGPU_Private.WebGPUCpp
import simd

private let largeBufferSize = WebGPU.largeBufferSize

// The ByteOwner of a write's bytes, which a large write reads in place. A Swift class, so that writes without one pass
// nil: an Optional foreign reference type is not safe to copy.
private final class AliasableBytes {
    private let owner: WebGPU.ByteOwner

    init(_ owner: WebGPU.ByteOwner) {
        self.owner = owner
    }

    // A buffer over `length` of the owner's bytes from `offset`, which keeps the owner alive for as long as it exists.
    func newBuffer(_ device: WebGPU.Metal.Device, from offset: UInt64, length: UInt64) -> (any MTLBuffer)? {
        WebGPU.Metal.newBufferAliasingOwner(device, owner, offset, length)
    }
}

// WTF's checkedSum<T>() and checkedProduct<T>() for unsigned operands: nil, where they report an overflow, when an
// operand or a partial result does not fit in T.
private func checkedSum<T: FixedWidthInteger & UnsignedInteger>(_: T.Type, _ operands: UInt64...) -> T? {
    var result: T = 0
    for operand in operands {
        guard let value = T(exactly: operand) else {
            return nil
        }
        let (sum, overflow) = result.addingReportingOverflow(value)
        if overflow {
            return nil
        }
        result = sum
    }
    return result
}

private func checkedProduct<T: FixedWidthInteger & UnsignedInteger>(_: T.Type, _ first: UInt64, _ rest: UInt64...) -> T? {
    guard var result = T(exactly: first) else {
        return nil
    }
    for operand in rest {
        guard let value = T(exactly: operand) else {
            return nil
        }
        let (product, overflow) = result.multipliedReportingOverflow(by: value)
        if overflow {
            return nil
        }
        result = product
    }
    return result
}

// Crashes, as WTF's Checked<T>::value() does on an overflowed value.
private func checkedValueOverflowed() -> Never {
    fatalError("Checked<T>::value() of an overflowed value")
}

// Saturates where UInt32(_:) would trap.
private func truncatedUInt32(_ value: CGFloat) -> UInt32 {
    if !(value > 0) {
        return 0
    }
    if value >= 4_294_967_296.0 {
        return UInt32.max
    }
    return UInt32(value)
}

#if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
// MTLStorageModeManaged, which Macs with discrete memory still need.
#if hasAttribute(diagnose)
@diagnose(DeprecatedDeclaration, as: ignored, reason: "Managed storage is still required on Macs with discrete memory")
#endif
var deprecatedManagedStorageMode: MTLStorageMode {
    .managed
}
#endif

func hasUnifiedMemory(_ deviceImpl: DeviceImpl) -> Bool {
    #if arch(x86_64)
    false
    #else
    deviceImpl.device()?.hasUnifiedMemory ?? false
    #endif
}

// A C++ caller's CompletionHandler<void(bool)>, called at most once: Swift owns it from the hand-over on.
final class BoolCompletionHandlerBox {
    private var handler: WTF.BoolCompletionHandler?

    init(_ handler: consuming WTF.BoolCompletionHandler) {
        self.handler = consume handler
    }

    func call(_ value: Bool) {
        if var handler = handler.take() {
            handler(value)
        }
    }
}

// A Swift onSubmittedWorkDone callback, called at most once. The call releases the closure and what it captured.
private final class OneShotCallback {
    private var callback: ((Bool) -> Void)?

    init(_ callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }

    func call(_ success: Bool) {
        if let callback = callback.take() {
            callback(success)
        }
    }
}

// A C++ caller's Function<void()>, called at most once.
private final class ScheduledCallbackBox {
    private var callback: WebGPU.Metal.Instance.WorkItem?

    init(_ callback: consuming WebGPU.Metal.Instance.WorkItem) {
        self.callback = consume callback
    }

    func call() {
        if let callback = callback.take() {
            callback()
        }
    }
}

private func appendCallback<Callback>(_ map: inout WTFHashMap<UInt64, [Callback]>, _ key: UInt64, _ callback: Callback) {
    if let index = map.valueIndex(forKey: key) {
        var callbacks = map.values[index]
        map.replaceValue(at: index, with: [])
        callbacks.append(callback)
        map.replaceValue(at: index, with: callbacks)
    } else {
        map.insertAbsent(key, [callback])
    }
}

private func takeCallbacks<Callback>(_ map: inout WTFHashMap<UInt64, [Callback]>, _ key: UInt64) -> [Callback] {
    guard let callbacks = map.value(forKey: key) else {
        return []
    }
    map.remove(key)
    return callbacks
}

// How a write reaches a resource while the queue is idle.
private enum WriteStorage {
    case cpu
    case gpu
    case unsupported
}

private func writeStorage(_ resource: (any MTLResource)?) -> WriteStorage {
    // A nil resource counts as shared.
    let storageMode = resource?.storageMode ?? .shared
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    if storageMode == deprecatedManagedStorageMode {
        return .cpu
    }
    #endif
    switch storageMode {
    case .shared:
        return .cpu
    case .private:
        // The only way to get data into a private resource is to tell the GPU to copy it in.
        return .gpu
    default:
        return .unsupported
    }
}

// The largest 32-bit and 16-bit index values in the whole 4-byte words of `data`, for the index-buffer validation.
private func maxIndexValue(_ data: Span<UInt8>) -> (maxUInt32: UInt32, maxUInt16: UInt16) {
    let bytes = data.bytes
    let blockSize = 64
    let blockCount = data.count / blockSize
    var maxUInt32: UInt32 = 0
    var maxUInt16: UInt16 = 0
    if blockCount != 0 {
        // The simd module's functions: the generic SIMD operations are not vectorized, and are 100 times slower.
        var maxUInt32s = bytes.load(fromByteOffset: 0, as: simd_uint16.self)
        var maxUInt16s = bytes.load(fromByteOffset: 0, as: simd_ushort32.self)
        for block in 1..<blockCount {
            maxUInt32s = simd_max(maxUInt32s, bytes.load(fromByteOffset: block &* blockSize, as: simd_uint16.self))
            maxUInt16s = simd_max(maxUInt16s, bytes.load(fromByteOffset: block &* blockSize, as: simd_ushort32.self))
        }
        maxUInt32 = simd_reduce_max(maxUInt32s)
        maxUInt16 = simd_reduce_max(maxUInt16s)
    }
    for word in (blockCount * blockSize / 4)..<(data.count / 4) {
        let value = bytes.load(fromByteOffset: word &* 4, as: UInt32.self)
        maxUInt32 = max(maxUInt32, value)
        maxUInt16 = max(maxUInt16, UInt16(truncatingIfNeeded: value), UInt16(truncatingIfNeeded: value &>> 16))
    }
    return (maxUInt32, maxUInt16)
}

// Whether a write of this extent covers the whole subresource, so that it needs no lazy clear first.
func writeWillCompletelyClear(
    _ textureDimension: WebGPU.TextureDimension,
    _ widthForMetal: UInt32,
    _ logicalSizeWidth: UInt32,
    _ heightForMetal: UInt32,
    _ logicalSizeHeight: UInt32,
    _ depthForMetal: UInt32,
    _ logicalSizeDepthOrArrayLayers: UInt32
) -> Bool {
    switch textureDimension {
    case ._1d:
        return widthForMetal == logicalSizeWidth
    case ._2d:
        return widthForMetal == logicalSizeWidth && heightForMetal == logicalSizeHeight
    case ._3d:
        return widthForMetal == logicalSizeWidth && heightForMetal == logicalSizeHeight && depthForMetal == logicalSizeDepthOrArrayLayers
    @unknown default:
        assertionFailure()
        return false
    }
}

// The texel copy destination of a tagged destination.
private func untaggedDestination(_ destination: WebGPU.ImageCopyTextureTagged) -> WebGPU.TexelCopyTextureInfo {
    WebGPU.TexelCopyTextureInfo(
        texture: destination.texture,
        mipLevel: destination.mipLevel,
        origin: destination.origin,
        aspect: destination.aspect
    )
}

// As WTFLogAlways("%@") prints an NSError, or nil.
private func errorDescription(_ error: (any Error)?) -> String {
    error.map { "\($0 as NSError)" } ?? "(null)"
}

private func copyExternalImageSourceStorageMode(_ deviceImpl: DeviceImpl) -> MTLStorageMode {
    #if WTF_PLATFORM_MAC || WTF_PLATFORM_MACCATALYST
    #if ENABLE_WEBGPU_BY_DEFAULT
    hasUnifiedMemory(deviceImpl) ? .shared : deprecatedManagedStorageMode
    #else
    deprecatedManagedStorageMode
    #endif
    #else
    .shared
    #endif
}

// The part of a queue that the shell's Metal completed handler touches on a Metal thread.
@_expose(Cxx)
final class QueueCompletion: Sendable {
    // Entered just before each commit and left by that command buffer's completed handler, so it is empty
    // exactly when every committed command buffer has completed.
    private let committedNotCompleted = DispatchGroup()

    fileprivate init() {}

    fileprivate func willCommit() {
        committedNotCompleted.enter()
    }

    // Runs on a Metal completion thread.
    @_expose(Cxx)
    func didComplete() {
        committedNotCompleted.leave()
    }

    // FIXME: Wait for committedNotCompleted.
    fileprivate func waitForAllCommittedWorkToComplete() {
    }
}

// A command buffer of a submit, with its Impl (the CommandBuffer shell keeps the Impl alive).
private struct SubmittedCommand {
    let shell: WebGPU.Metal.CommandBuffer
    let impl: CommandBufferImpl
}

// MARK: Lazy zero-initialization

/// Proof that the queue timeline orders some work before every command buffer committed from now on: a command buffer
/// was just committed, a zero fill or a write was just encoded on the staging command buffer (QueueImpl.commit commits it
/// before any other command buffer), or a write was just performed. fileprivate: only this file can make one, and the
/// markers only borrow it, so as a ~Copyable value it cannot be kept for later.
struct CommitToken: ~Copyable {
    fileprivate init() {
    }
}

/// A region to zero-fill before the command buffer that reads it.
struct InitFixUp {
    let texture: TextureImpl
    let region: InitRegion
}

/// The initialization state of the regions as the command buffers of a submit before the current one leave it.
private struct InitOverlay {
    struct Key: Hashable {
        let texture: ObjectIdentifier
        let region: InitRegion

        init(_ texture: TextureImpl, _ region: InitRegion) {
            self.texture = ObjectIdentifier(texture)
            self.region = region
        }
    }

    private var state: [Key: Bool] = [:]

    func isInitialized(_ texture: TextureImpl, _ region: InitRegion) -> Bool {
        state[Key(texture, region)] ?? texture.isInitialized(region)
    }

    mutating func set(_ texture: TextureImpl, _ region: InitRegion, _ initialized: Bool) {
        state[Key(texture, region)] = initialized
    }
}

/// Encodes on `blit` a zero fill of `region`, from the zeroed buffer `zeroBuffer` returns for a length.
///
/// A combined depth-stencil format is filled one aspect at a time. Marks nothing: false when nothing was encoded.
func encodeBlitZeroFill(
    _ texture: TextureImpl,
    _ region: InitRegion,
    _ blit: any MTLBlitCommandEncoder,
    zeroBuffer: (UInt) -> (any MTLBuffer)?
) -> Bool {
    guard !texture.isTransient, let format = texture.backingFormat, let mtlTexture = texture.texture() else {
        return false
    }
    let (mipLevel, layer) = texture.initSubresource(region)
    var copyFormat = format
    var options: MTLBlitOption = []
    switch texture.initAspect(region) {
    case .depth:
        copyFormat = .Depth32float
        options = .depthFromDepthStencil
    case .stencil:
        copyFormat = .Stencil8
        options = .stencilFromDepthStencil
    case .color:
        if mtlTexture.pixelFormat == .x32_stencil8 {
            copyFormat = .Depth32float
        }
    }
    let dimension = texture.backingDimension
    let logicalExtent = texture.logicalMiplevelSpecificTextureExtent(mipLevel)
    if logicalExtent.width == 0 || (dimension != ._1d && logicalExtent.height == 0)
        || (dimension == ._3d && logicalExtent.depthOrArrayLayers == 0)
    {
        return false
    }
    let isVolume = dimension == ._3d
    let physicalExtent = physicalTextureExtent(dimension, copyFormat, logicalExtent)
    let bytesPerRow = textureBytesPerRow(copyFormat, physicalExtent.width, texture.backingSampleCount)
    let (bytesPerImage, bytesPerImageOverflowed) = bytesPerRow.multipliedReportingOverflow(by: UInt(physicalExtent.height))
    let (length, lengthOverflowed) = bytesPerImage.multipliedReportingOverflow(by: isVolume ? UInt(physicalExtent.depthOrArrayLayers) : 1)
    let slice = isVolume ? 0 : Int(layer)
    guard !bytesPerImageOverflowed, !lengthOverflowed, length != 0, slice < mtlTexture.arrayLength, let source = zeroBuffer(length) else {
        return false
    }
    let sourceSize: MTLSize
    switch dimension {
    case ._1d:
        sourceSize = MTLSize(width: Int(logicalExtent.width), height: 1, depth: 1)
    case ._3d:
        sourceSize = MTLSize(
            width: Int(logicalExtent.width),
            height: Int(logicalExtent.height),
            depth: Int(logicalExtent.depthOrArrayLayers)
        )
    default:
        sourceSize = MTLSize(width: Int(logicalExtent.width), height: Int(logicalExtent.height), depth: 1)
    }
    blit.copy(
        from: source,
        sourceOffset: 0,
        sourceBytesPerRow: Int(bitPattern: bytesPerRow),
        sourceBytesPerImage: isVolume ? Int(bitPattern: bytesPerImage) : 0,
        sourceSize: sourceSize,
        to: mtlTexture,
        destinationSlice: slice,
        destinationLevel: Int(mipLevel),
        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        options: options
    )
    return true
}

// Mirrors the `webKitCopyExternalImage*` constants in copyExternalImageShaderSource.
private enum CopyExternalImageFlags {
    static let flipY: UInt32 = 1 << 0
    static let forceOpaqueAlpha: UInt32 = 1 << 1
    static let unpremultiplySource: UInt32 = 1 << 2
    static let premultiplyDestination: UInt32 = 1 << 3
    static let decodeSourceTransferFunction: UInt32 = 1 << 4
    static let encodeDestinationTransferFunction: UInt32 = 1 << 5
    static let cancelSRGBDestinationEncoding: UInt32 = 1 << 6
    static let sourceIsVideoFrame: UInt32 = 1 << 7
}

// https://drafts.csswg.org/css-color-4/#color-conversion-code, in row-major order and applied to
// linear-light values.
private let identityColorMatrix: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
private let sRGBToDisplayP3ColorMatrix: [Float] = [
    0.8224621, 0.1775380, 0,
    0.0331941, 0.9668058, 0,
    0.0170827, 0.0723974, 0.9105199,
]
private let displayP3ToSRGBColorMatrix: [Float] = [
    1.2249401, -0.2249404, 0,
    -0.0420569, 1.0420571, 0,
    -0.0196376, -0.0786361, 1.0982735,
]

// Video is tagged with primaries of its own, which are usually neither of the two color spaces
// copyExternalImageToTexture names. Derived from each set of primaries against the same D65 white
// point the two matrices above use, so that a video which really is BT.709 still yields the identity.
private let smpteCToSRGBColorMatrix: [Float] = [
    0.9395421, 0.0501814, 0.0102766,
    0.0177722, 0.9657929, 0.0164349,
    -0.0016216, -0.0043697, 1.0059913,
]
private let smpteCToDisplayP3ColorMatrix: [Float] = [
    0.7758929, 0.2127372, 0.0113699,
    0.0483696, 0.9353999, 0.0162305,
    0.0158600, 0.0667994, 0.9173406,
]
private let ebu3213ToSRGBColorMatrix: [Float] = [
    1.0440432, -0.0440432, 0,
    0, 1, 0,
    0, 0.0117934, 0.9882066,
]
private let ebu3213ToDisplayP3ColorMatrix: [Float] = [
    0.8586858, 0.1413142, 0,
    0.0346562, 0.9653438, 0,
    0.0178350, 0.0823832, 0.8997818,
]
private let bt2020ToSRGBColorMatrix: [Float] = [
    1.6604910, -0.5876411, -0.0728499,
    -0.1245505, 1.1328999, -0.0083494,
    -0.0181508, -0.1005789, 1.1187297,
]
private let bt2020ToDisplayP3ColorMatrix: [Float] = [
    1.3435783, -0.2821797, -0.0613986,
    -0.0652975, 1.0757879, -0.0104905,
    0.0028218, -0.0195985, 1.0167767,
]

// Leaves the frame's coordinates alone, which is what a frame whose clean aperture is its whole coded
// extent needs, and what the IOSurface path - which never samples - is given.
private let identityUVRemapMatrix: [Float] = [1, 0, 0, 1, 0, 0]

// The inverse of a frame's display transform, in normalized coordinates and flattened the same way
// the crop matrix is: a coordinate in the presented image maps back to the frame pixel which holds
// it. The forward transform mirrors x, when the frame is mirrored, and then rotates clockwise, so the
// inverse un-rotates and then un-mirrors.
private func inverseDisplayTransformMatrix(_ rotation: WebGPU.VideoFrameRotation, _ isMirrored: Bool) -> [Float] {
    var matrix = identityUVRemapMatrix
    switch rotation {
    case WebGPU.VideoFrameRotation.None:
        break
    case WebGPU.VideoFrameRotation.Right:
        matrix = [0, -1, 1, 0, 0, 1]
    case WebGPU.VideoFrameRotation.UpsideDown:
        matrix = [-1, 0, 0, -1, 1, 1]
    case WebGPU.VideoFrameRotation.Left:
        matrix = [0, 1, -1, 0, 1, 0]
    default:
        break
    }

    if isMirrored {
        // Reflect only the coordinate the mirror moved, about the middle of the frame.
        matrix[0] = -matrix[0]
        matrix[2] = -matrix[2]
        matrix[4] = 1 - matrix[4]
    }

    return matrix
}

// The affine which applies inner and then outer, in that same flattened layout.
private func concatenatedAffineTransforms(_ outer: [Float], _ inner: [Float]) -> [Float] {
    [
        outer[0] * inner[0] + outer[2] * inner[1],
        outer[1] * inner[0] + outer[3] * inner[1],
        outer[0] * inner[2] + outer[2] * inner[3],
        outer[1] * inner[2] + outer[3] * inner[3],
        outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
        outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    ]
}

private enum CopyExternalImageSourcePrimaries {
    case srgb // ITU-R BT.709, whose primaries sRGB shares.
    case displayP3
    case smpteC // ITU-R BT.601 525-line, as NTSC video is tagged.
    case ebu3213 // ITU-R BT.601 625-line, as PAL video is tagged.
    case bt2020
}

private func sourcePrimariesForPixelBuffer(_ pixelBuffer: CVPixelBuffer?) -> CopyExternalImageSourcePrimaries {
    guard let pixelBuffer, let primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) else {
        return .srgb
    }

    if CFEqual(primaries, kCVImageBufferColorPrimaries_SMPTE_C) {
        return .smpteC
    }
    if CFEqual(primaries, kCVImageBufferColorPrimaries_EBU_3213) {
        return .ebu3213
    }
    if CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020) {
        return .bt2020
    }
    // The DCI white point is not D65, but WebKit treats DCI-P3 content as Display P3 elsewhere too.
    if CFEqual(primaries, kCVImageBufferColorPrimaries_P3_D65) || CFEqual(primaries, kCVImageBufferColorPrimaries_DCI_P3) {
        return .displayP3
    }

    // ITU-R BT.709, and anything unrecognized: leaving the values alone is what the readback path this
    // replaced did as well.
    return .srgb
}

private func colorMatrixBetweenPrimaries(_ source: CopyExternalImageSourcePrimaries, _ destinationIsDisplayP3: Bool) -> [Float] {
    switch source {
    case .srgb:
        destinationIsDisplayP3 ? sRGBToDisplayP3ColorMatrix : identityColorMatrix
    case .displayP3:
        destinationIsDisplayP3 ? identityColorMatrix : displayP3ToSRGBColorMatrix
    case .smpteC:
        destinationIsDisplayP3 ? smpteCToDisplayP3ColorMatrix : smpteCToSRGBColorMatrix
    case .ebu3213:
        destinationIsDisplayP3 ? ebu3213ToDisplayP3ColorMatrix : ebu3213ToSRGBColorMatrix
    case .bt2020:
        destinationIsDisplayP3 ? bt2020ToDisplayP3ColorMatrix : bt2020ToSRGBColorMatrix
    }
}

private func isLinear(_ colorSpace: WebGPU.PredefinedColorSpace) -> Bool {
    colorSpace == WebGPU.PredefinedColorSpace.SRGBLinear || colorSpace == WebGPU.PredefinedColorSpace.DisplayP3Linear
}

private func isDisplayP3(_ colorSpace: WebGPU.PredefinedColorSpace) -> Bool {
    colorSpace == WebGPU.PredefinedColorSpace.DisplayP3 || colorSpace == WebGPU.PredefinedColorSpace.DisplayP3Linear
}

private func floats(_ values: (Float, Float, Float, Float, Float, Float)) -> [Float] {
    [values.0, values.1, values.2, values.3, values.4, values.5]
}

private func floats(_ values: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)) -> [Float] {
    [values.0, values.1, values.2, values.3, values.4, values.5, values.6, values.7, values.8, values.9, values.10, values.11]
}

private func tuple9(_ values: [Float]) -> (Float, Float, Float, Float, Float, Float, Float, Float, Float) {
    (values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8])
}

private func tuple6(_ values: [Float]) -> (Float, Float, Float, Float, Float, Float) {
    (values[0], values[1], values[2], values[3], values[4], values[5])
}

private func tuple12(_ values: [Float]) -> (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float) {
    (values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8], values[9], values[10], values[11])
}

// https://gpuweb.github.io/gpuweb/#dom-gpuqueue-copyexternalimagetotexture asks for a color format
// which is renderable, because the copy is performed by rendering into the destination, and whose
// channels are normalized or floating point, because the fragment stage writes floats. Which formats
// are renderable depends on the features the device enabled - texture-formats-tier1 and
// rg11b10ufloat-renderable both widen the set - so ask Texture rather than keeping a list here.
private func isValidCopyExternalImageDestinationFormat(_ format: WebGPU.TextureFormat, _ device: WebGPU.Metal.Device) -> Bool {
    if !isColorRenderableFormat(format, device) {
        return false
    }

    switch format {
    // A render pass can target these, but the fragment stage writes floats, not integers.
    case WebGPU.TextureFormat.R8uint, WebGPU.TextureFormat.R8sint, WebGPU.TextureFormat.R16uint, WebGPU.TextureFormat.R16sint,
        WebGPU.TextureFormat.R32uint, WebGPU.TextureFormat.R32sint, WebGPU.TextureFormat.Rg8uint, WebGPU.TextureFormat.Rg8sint,
        WebGPU.TextureFormat.Rg16uint, WebGPU.TextureFormat.Rg16sint, WebGPU.TextureFormat.Rg32uint, WebGPU.TextureFormat.Rg32sint,
        WebGPU.TextureFormat.Rgb10a2uint, WebGPU.TextureFormat.Rgba8uint, WebGPU.TextureFormat.Rgba8sint,
        WebGPU.TextureFormat.Rgba16uint, WebGPU.TextureFormat.Rgba16sint, WebGPU.TextureFormat.Rgba32uint, WebGPU.TextureFormat.Rgba32sint,
        // texture-formats-tier1 makes these renderable, but the spec excludes them all the same.
        WebGPU.TextureFormat.R8snorm, WebGPU.TextureFormat.R16snorm, WebGPU.TextureFormat.Rg8snorm, WebGPU.TextureFormat.Rg16snorm,
        WebGPU.TextureFormat.Rgba8snorm, WebGPU.TextureFormat.Rgba16snorm:
        return false
    default:
        return true
    }
}

// isValidToUseWith(object, queue) of IsValidToUseWith.h, given the object's own validity and its device's Impl.
private func isValidToUse(_ objectIsValid: Bool, _ objectDeviceImpl: DeviceImpl, _ deviceImpl: DeviceImpl) -> Bool {
    objectIsValid && objectDeviceImpl === deviceImpl && deviceImpl.isValid()
}

// One per GPUQueue, owned by the C++ shell WebGPU::Metal::Queue. The shell's entry points pass the Device in, having
// checked that it is still alive.
//
// Used only on its Instance's API thread, so deliberately not Sendable; the Metal threads only ever get
// `completion()`. The counters are bumped by work items the handlers schedule back onto the API thread.
@_expose(Cxx)
final class QueueImpl {
    private var backingCommandQueue: (any MTLCommandQueue)?
    private let backingCompletion = QueueCompletion()

    private var backingStagingCommandBuffer: (any MTLCommandBuffer)?
    // At most one of these is open on the staging command buffer.
    private var blitCommandEncoder: (any MTLBlitCommandEncoder)?
    private var stagedCopyEncoder: (any MTLComputeCommandEncoder)?

    // nil on an invalid queue and once the queue has been made invalid, where every operation on them is a no-op.
    // Foundation collections, for Objective-C equality.
    private var createdNotCommittedBuffers: NSMutableOrderedSet?
    private var openCommandEncoders: NSMapTable<AnyObject, AnyObject>?
    private var retainedCounterSampleBuffers: [UInt64: NSMutableSet]?

    private var backingSubmittedCommandBufferCount: UInt64 = 0
    private var backingCompletedCommandBufferCount: UInt64 = 0
    private var backingScheduledCommandBufferCount: UInt64 = 0
    // Keyed by the submitted count each callback waits for. makeInvalid() calls them in WTF::HashMap order.
    private var scheduledCallbacks = WTFHashMap<UInt64, [() -> Void]>()
    private var doneCallbacks = WTFHashMap<UInt64, [OneShotCallback]>()

    private var backingTemporaryBuffer: (any MTLBuffer)?
    private var temporaryBufferOffset: UInt64 = 0
    // Zero-filled by Metal when it was created and never written: the source of the zero fills, kept up to this length.
    private var zeroBuffer: (any MTLBuffer)?
    private static let maximumKeptZeroBufferLength: UInt = 4 * 1024 * 1024

    private var backingStagedCopyPipelineState: (any MTLComputePipelineState)?
    private var stagedCopyPipelineCreationFailed = false
    // Renders one source texel per destination texel, so the pipeline only varies by the destination's
    // pixel format. Cached per format, because a copy per animation frame is the expected usage.
    private var copyExternalImagePipelineStates: [UInt: any MTLRenderPipelineState] = [:]
    private var copyExternalImagePipelineCreationFailed = false

    // Filled by the shell's submit() just before it calls submit(_:_:_:).
    private var commandsToSubmit: [SubmittedCommand] = []

    fileprivate init(commandQueue: (any MTLCommandQueue)?, allocatesBookkeeping: Bool) {
        backingCommandQueue = commandQueue
        guard allocatesBookkeeping else {
            return
        }
        createdNotCommittedBuffers = NSMutableOrderedSet()
        openCommandEncoders = NSMapTable.strongToStrongObjects()
        retainedCounterSampleBuffers = [:]
    }

    @_expose(Cxx)
    func isValid() -> Bool {
        backingCommandQueue != nil
    }

    @_expose(Cxx)
    func setLabel(_ label: NSString?) {
        backingCommandQueue?.label = label as String?
    }

    @_expose(Cxx)
    func completion() -> QueueCompletion {
        backingCompletion
    }

    @_expose(Cxx)
    func waitForAllCommittedWorkToComplete() {
        backingCompletion.waitForAllCommittedWorkToComplete()
    }

    // MARK: Invalidation

    // Calls every scheduled callback, then every done callback with false, each in WTF iteration order. Both maps are
    // emptied before the first call.
    @_expose(Cxx)
    func makeInvalid(_ queue: WebGPU.Metal.Queue) {
        backingCommandQueue = nil
        let scheduled = scheduledCallbacks
        let done = doneCallbacks
        scheduledCallbacks.removeAll()
        doneCallbacks.removeAll()
        scheduled.forEachInWTFOrder { _, callbacks in
            for callback in callbacks {
                callback()
            }
        }
        done.forEachInWTFOrder { _, callbacks in
            for callback in callbacks {
                callback.call(false)
            }
        }
        removeCommandBuffersAndDropState(queue)
    }

    private func removeCommandBuffersAndDropState(_ queue: WebGPU.Metal.Queue) {
        while let commandBuffer = createdNotCommittedBuffers?.firstObject as? any MTLCommandBuffer {
            removeMTLCommandBuffer(queue, commandBuffer)
        }

        createdNotCommittedBuffers = nil
        openCommandEncoders = nil
        blitCommandEncoder = nil
        stagedCopyEncoder = nil
        backingStagingCommandBuffer = nil
        backingTemporaryBuffer = nil
        zeroBuffer = nil
    }

    // MARK: Command buffer bookkeeping

    private func makeCommandBuffer(_ descriptor: MTLCommandBufferDescriptor?) -> (any MTLCommandBuffer)? {
        guard let descriptor, let commandBuffer = backingCommandQueue?.makeCommandBuffer(descriptor: descriptor) else {
            return nil
        }
        createdNotCommittedBuffers?.add(commandBuffer)
        return commandBuffer
    }

    private func forgetCommandBuffer(_ commandBuffer: any MTLCommandBuffer) {
        openCommandEncoders?.removeObject(forKey: commandBuffer)
        createdNotCommittedBuffers?.remove(commandBuffer)
    }

    @_expose(Cxx)
    func commandBufferWithDescriptor(_ queue: WebGPU.Metal.Queue, _ descriptor: MTLCommandBufferDescriptor?) -> (any MTLCommandBuffer)? {
        if !isValid() {
            return nil
        }

        let maxCommandBufferCount = 1000
        if (createdNotCommittedBuffers?.count ?? 0) >= maxCommandBufferCount {
            queue.loseTheDevice(WebGPU.DeviceLostReason.Destroyed)
            return nil
        }

        let commandBuffer = makeCommandBuffer(descriptor)
        queue.retainDeviceUntilCompleted(commandBuffer)
        return commandBuffer
    }

    @_expose(Cxx)
    func encoderForBuffer(_ commandBuffer: (any MTLCommandBuffer)?) -> (any MTLCommandEncoder)? {
        guard let commandBuffer else {
            return nil
        }
        return openCommandEncoders?.object(forKey: commandBuffer) as? any MTLCommandEncoder
    }

    // Ends the encoder if it is the one open on the command buffer. The shell's endEncoding() then resolves the
    // Device's timestamps; it must not pass the shell in, because ~Queue calls it.
    @_expose(Cxx)
    func endEncodingIfCurrent(_ commandEncoder: (any MTLCommandEncoder)?, _ commandBuffer: (any MTLCommandBuffer)?) -> Bool {
        guard let currentEncoder = encoderForBuffer(commandBuffer), let commandEncoder, currentEncoder === commandEncoder else {
            return false
        }

        currentEncoder.endEncoding()
        if let commandBuffer {
            openCommandEncoders?.removeObject(forKey: commandBuffer)
        }
        return true
    }

    private func endEncoding(
        _ queue: WebGPU.Metal.Queue,
        _ commandEncoder: (any MTLCommandEncoder)?,
        _ commandBuffer: (any MTLCommandBuffer)?
    ) {
        if endEncodingIfCurrent(commandEncoder, commandBuffer) {
            queue.resolveDeviceTimestamps(commandBuffer)
        }
    }

    @_expose(Cxx)
    func setEncoderForBuffer(
        _ queue: WebGPU.Metal.Queue,
        _ commandBuffer: (any MTLCommandBuffer)?,
        _ commandEncoder: (any MTLCommandEncoder)?
    ) {
        guard let commandBuffer else {
            return
        }
        endEncoding(queue, encoderForBuffer(commandBuffer), commandBuffer)
        if let commandEncoder {
            openCommandEncoders?.setObject(commandEncoder, forKey: commandBuffer)
        } else {
            openCommandEncoders?.removeObject(forKey: commandBuffer)
        }
    }

    @_expose(Cxx)
    func removeMTLCommandBuffer(_ queue: WebGPU.Metal.Queue, _ commandBuffer: (any MTLCommandBuffer)?) {
        guard let commandBuffer else {
            return
        }

        endEncoding(queue, encoderForBuffer(commandBuffer), commandBuffer)
        forgetCommandBuffer(commandBuffer)
    }

    // Staged work goes first: the zero fills already marked as done, and the queue writes. This is also how the command
    // buffers PresentationContextIOSurface and ExternalTextureImport commit come after them.
    @_expose(Cxx)
    func commitMTLCommandBuffer(_ queue: WebGPU.Metal.Queue, _ commandBuffer: (any MTLCommandBuffer)?) {
        _ = commit(queue, commandBuffer, commitsStagedWorkFirst: true)
    }

    // True only when `commandBuffer` was committed. submit() commits the staged work itself, before its command buffers.
    private func commit(_ queue: WebGPU.Metal.Queue, _ commandBuffer: (any MTLCommandBuffer)?, commitsStagedWorkFirst: Bool) -> Bool {
        guard let commandBuffer, commandBuffer.status.rawValue < MTLCommandBufferStatus.committed.rawValue, isValid() else {
            removeMTLCommandBuffer(queue, commandBuffer)
            return false
        }
        if commitsStagedWorkFirst, let staging = backingStagingCommandBuffer, staging !== commandBuffer {
            finalizeBlitCommandEncoder(queue)
        }

        assert(commandBuffer.commandQueue === backingCommandQueue)
        queue.addCommitHandlers(commandBuffer)

        // Before the commit, so the completed handler can never run first.
        backingCompletion.willCommit()
        commandBuffer.commit()
        forgetCommandBuffer(commandBuffer)
        backingSubmittedCommandBufferCount &+= 1
        return true
    }

    // MARK: The staging command buffer

    @_expose(Cxx)
    func stagingCommandBuffer() -> (any MTLCommandBuffer)? {
        backingStagingCommandBuffer
    }

    @_expose(Cxx)
    func stagingEncoder() -> (any MTLCommandEncoder)? {
        if let blitCommandEncoder {
            return blitCommandEncoder
        }
        return stagedCopyEncoder
    }

    private func isOpenOnStagingCommandBuffer(_ encoder: (any MTLCommandEncoder)?) -> Bool {
        guard let encoder, let openEncoder = encoderForBuffer(backingStagingCommandBuffer) else {
            return false
        }
        return encoder === openEncoder
    }

    @_expose(Cxx)
    func ensureBlitCommandEncoder(_ queue: WebGPU.Metal.Queue) -> (any MTLBlitCommandEncoder)? {
        if isOpenOnStagingCommandBuffer(blitCommandEncoder) {
            return blitCommandEncoder
        }

        if isOpenOnStagingCommandBuffer(stagedCopyEncoder) {
            // Switch encoder types on the open staging command buffer rather than minting a second one.
            endEncoding(queue, stagedCopyEncoder, backingStagingCommandBuffer)
            stagedCopyEncoder = nil
            blitCommandEncoder = backingStagingCommandBuffer?.makeBlitCommandEncoder()
            guard let encoder = blitCommandEncoder else {
                // See ensureStagedCopyEncoder(): committing beats orphaning the work already encoded.
                commitMTLCommandBuffer(queue, backingStagingCommandBuffer)
                backingStagingCommandBuffer = nil
                return nil
            }
            setEncoderForBuffer(queue, backingStagingCommandBuffer, encoder)
            return encoder
        }

        backingStagingCommandBuffer = commandBufferWithDescriptor(queue, MTLCommandBufferDescriptor())
        stagedCopyEncoder = nil
        blitCommandEncoder = backingStagingCommandBuffer?.makeBlitCommandEncoder()
        setEncoderForBuffer(queue, backingStagingCommandBuffer, blitCommandEncoder)
        return blitCommandEncoder
    }

    private func ensureStagedCopyEncoder(_ queue: WebGPU.Metal.Queue) -> (any MTLComputeCommandEncoder)? {
        if isOpenOnStagingCommandBuffer(stagedCopyEncoder) {
            return stagedCopyEncoder
        }

        if isOpenOnStagingCommandBuffer(blitCommandEncoder) {
            // Switch encoder types on the open staging command buffer rather than minting a second one.
            endEncoding(queue, blitCommandEncoder, backingStagingCommandBuffer)
            blitCommandEncoder = nil
            stagedCopyEncoder = backingStagingCommandBuffer?.makeComputeCommandEncoder()
            guard let encoder = stagedCopyEncoder else {
                // Encoder creation failed after the previous encoder was ended, so the staging command
                // buffer now holds real work with nothing open on it. finalizeBlitCommandEncoder() keys
                // off the encoders, so leaving it here would orphan it and drop that work; commit it.
                commitMTLCommandBuffer(queue, backingStagingCommandBuffer)
                backingStagingCommandBuffer = nil
                return nil
            }
            setEncoderForBuffer(queue, backingStagingCommandBuffer, encoder)
            return encoder
        }

        backingStagingCommandBuffer = commandBufferWithDescriptor(queue, MTLCommandBufferDescriptor())
        blitCommandEncoder = nil
        stagedCopyEncoder = backingStagingCommandBuffer?.makeComputeCommandEncoder()
        setEncoderForBuffer(queue, backingStagingCommandBuffer, stagedCopyEncoder)
        return stagedCopyEncoder
    }

    // Finalizes the staging command buffer, whichever encoder type is currently open on it.
    @_expose(Cxx)
    func finalizeBlitCommandEncoder(_ queue: WebGPU.Metal.Queue) {
        if let stagingEncoder = stagingEncoder() {
            endEncoding(queue, stagingEncoder, backingStagingCommandBuffer)
            commitMTLCommandBuffer(queue, backingStagingCommandBuffer)
            blitCommandEncoder = nil
            stagedCopyEncoder = nil
            backingStagingCommandBuffer = nil
        } else if let commandBuffer = backingStagingCommandBuffer {
            // A staging command buffer with no encoder open: reachable if encoder creation failed. Its
            // already-encoded work must still reach the GPU in order, so commit rather than drop.
            commitMTLCommandBuffer(queue, commandBuffer)
            backingStagingCommandBuffer = nil
        }
    }

    // Closes both staging encoders but keeps the staging command buffer open, so that other work can follow
    // the staged work on it.
    private func endStagingEncoders(_ queue: WebGPU.Metal.Queue) {
        if let encoder = blitCommandEncoder {
            endEncoding(queue, encoder, backingStagingCommandBuffer)
            blitCommandEncoder = nil
        }
        if let encoder = stagedCopyEncoder {
            endEncoding(queue, encoder, backingStagingCommandBuffer)
            stagedCopyEncoder = nil
        }
    }

    // MARK: Counters and callbacks. The counters wrap.

    // Runs in the work item the shell's scheduled handler posts to the API thread.
    @_expose(Cxx)
    func didScheduleCommandBuffer() {
        backingScheduledCommandBufferCount &+= 1
        for callback in takeCallbacks(&scheduledCallbacks, backingScheduledCommandBufferCount) {
            callback()
        }
    }

    // Runs in the work item the shell's completed handler posts to the API thread.
    @_expose(Cxx)
    func didCompleteCommandBuffer() {
        backingCompletedCommandBufferCount &+= 1
        for callback in takeCallbacks(&doneCallbacks, backingCompletedCommandBufferCount) {
            callback.call(true)
        }
    }

    private func isIdle() -> Bool {
        backingSubmittedCommandBufferCount == backingCompletedCommandBufferCount && blitCommandEncoder == nil && stagedCopyEncoder == nil
    }

    private func isSchedulingIdle() -> Bool {
        backingSubmittedCommandBufferCount == backingScheduledCommandBufferCount
    }

    // https://gpuweb.github.io/gpuweb/#dom-gpuqueue-onsubmittedworkdone
    // The callback gets false when the device is lost.
    @_expose(!Cxx)
    func onSubmittedWorkDone(_ queue: WebGPU.Metal.Queue, deviceIsUsable: Bool, _ callback: @escaping (Bool) -> Void) {
        guard deviceIsUsable else {
            callback(false)
            return
        }

        assert(backingSubmittedCommandBufferCount >= backingCompletedCommandBufferCount)

        finalizeBlitCommandEncoder(queue)

        let oneShot = OneShotCallback(callback)
        if isIdle() {
            queue.scheduleWork(consuming: WebGPU.Metal.Instance.WorkItem { oneShot.call(true) })
            return
        }

        appendCallback(&doneCallbacks, backingSubmittedCommandBufferCount, oneShot)
    }

    // Queue::onSubmittedWorkDone(CompletionHandler<void(bool)>&&): the handler is moved out of `callback`.
    @_expose(Cxx)
    func onSubmittedWorkDone(_ queue: WebGPU.Metal.Queue, _ deviceIsUsable: Bool, _ callback: inout WTF.BoolCompletionHandler) {
        let handler = BoolCompletionHandlerBox(exchange(&callback, with: WTF.BoolCompletionHandler()))
        onSubmittedWorkDone(queue, deviceIsUsable: deviceIsUsable) { success in
            handler.call(success)
        }
    }

    // Queue::onSubmittedWorkScheduled: the Function is moved out of `callback`.
    @_expose(Cxx)
    func onSubmittedWorkScheduled(_ queue: WebGPU.Metal.Queue, _ deviceIsUsable: Bool, _ callback: inout WebGPU.Metal.Instance.WorkItem) {
        assert(backingSubmittedCommandBufferCount >= backingScheduledCommandBufferCount)
        let handler = ScheduledCallbackBox(exchange(&callback, with: WebGPU.Metal.Instance.WorkItem()))
        guard deviceIsUsable else {
            handler.call()
            return
        }

        finalizeBlitCommandEncoder(queue)

        if isSchedulingIdle() {
            queue.scheduleWork(consuming: WebGPU.Metal.Instance.WorkItem { handler.call() })
            return
        }

        appendCallback(&scheduledCallbacks, backingSubmittedCommandBufferCount) {
            handler.call()
        }
    }

    // Keeps a frame's texture cache planes alive until the queue's submitted work is done: the cache's textures stay
    // valid only while their CVMetalTextures live.
    func retainUntilSubmittedWorkDone(_ queue: WebGPU.Metal.Queue, _ deviceIsUsable: Bool, _ plane0: CVBuffer, _ plane1: CVBuffer?) {
        onSubmittedWorkDone(queue, deviceIsUsable: deviceIsUsable) { _ in
            withExtendedLifetime((plane0, plane1)) {}
        }
    }

    // Queue::trimICB: copies the first `newSize` commands of `source` into `destination` on the staging blit encoder.
    func trimICB(
        _ queue: WebGPU.Metal.Queue,
        _ destination: (any MTLIndirectCommandBuffer)?,
        _ source: (any MTLIndirectCommandBuffer)?,
        _ newSize: UInt
    ) -> (any MTLIndirectCommandBuffer)? {
        let blitCommandEncoder = ensureBlitCommandEncoder(queue)
        if let destination, let source {
            blitCommandEncoder?
                .copyIndirectCommandBuffer(source, sourceRange: 0..<Int(newSize), destination: destination, destinationIndex: 0)
        }
        return destination
    }

    // MARK: Counter sample buffers, kept alive per command encoder until the shell's work item releases them.

    @_expose(Cxx)
    func retainCounterSampleBuffers(_ encoderImpl: CommandEncoderImpl) -> UInt64 {
        let encoderHandle = encoderImpl.uniqueId
        retainedCounterSampleBuffers?[encoderHandle] = encoderImpl.timestampBuffers()
        return encoderHandle
    }

    @_expose(Cxx)
    func releaseCounterSampleBuffers(_ encoderHandle: UInt64) {
        retainedCounterSampleBuffers?[encoderHandle] = nil
    }

    // MARK: submit

    @_expose(Cxx)
    func appendCommandToSubmit(_ command: WebGPU.Metal.CommandBuffer, _ commandImpl: CommandBufferImpl) {
        commandsToSubmit.append(SubmittedCommand(shell: command, impl: commandImpl))
    }

    private func errorValidatingSubmit(_ commands: [SubmittedCommand], _ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) -> NSString?
    {
        for command in commands {
            let status = command.impl.commandBuffer()?.status.rawValue ?? MTLCommandBufferStatus.notEnqueued.rawValue
            if !isValidToUse(command.impl.isValid(), command.impl.deviceImpl, deviceImpl) || command.impl.bufferMapCount() != 0
                || status >= MTLCommandBufferStatus.committed.rawValue
            {
                return command.impl.lastError() ?? "Validation failure."
            }
        }

        // FIXME: "Every GPUQuerySet referenced in a command in any element of commandBuffers is in the available state."
        // FIXME: "For occlusion queries, occlusionQuerySet in beginRenderPass() does not constitute a reference, while beginOcclusionQuery() does."

        // There's only one queue right now, so there is no need to make sure that the command buffers are being submitted to the correct queue.

        return nil
    }

    // The command buffers are the ones the shell just appended.
    @_expose(Cxx)
    func submit(_ queue: WebGPU.Metal.Queue, _ device: WebGPU.Metal.Device, _ deviceImpl: DeviceImpl) {
        let commands = commandsToSubmit
        commandsToSubmit = []

        // https://gpuweb.github.io/gpuweb/#dom-gpuqueue-submit
        if let error = errorValidatingSubmit(commands, device, deviceImpl) {
            deviceImpl.generateAValidationError(error as String)
            for command in commands {
                command.impl.makeInvalid(command.shell, command.impl.lastError() ?? error)
            }
            return
        }

        let commandBuffersToSubmit = NSMutableOrderedSet(capacity: commands.count)
        // In the order of commandBuffersToSubmit, each with the command buffer it came from.
        var submissions: [(commandBuffer: any MTLCommandBuffer, command: SubmittedCommand)] = []
        var validationError: NSString?
        for command in commands {
            guard let mtlBuffer = command.impl.commandBuffer(), !commandBuffersToSubmit.contains(mtlBuffer) else {
                validationError = command.impl.lastError() ?? "Command buffer appears twice."
                break
            }
            commandBuffersToSubmit.add(mtlBuffer)
            submissions.append((mtlBuffer, command))
        }

        // Lazy zero-initialization, decided now that the commit order is known: before willCommit, so that a failure can
        // still reject the whole submit, and before the staging command buffer is committed, which may now hold zero fills.
        let initializationFailed = validationError == nil && !stageInitializationFixUps(queue, device, submissions)
        finalizeBlitCommandEncoder(queue)

        for command in commands {
            if let validationError {
                command.impl.makeInvalid(command.shell, command.impl.lastError() ?? validationError)
            } else if initializationFailed {
                command.impl.makeInvalid(command.shell, "GPUQueue.submit: lazy zero-initialization failed")
            } else {
                command.shell.registerCompletedHandler(command.impl.willCommit("command buffer was submitted"))
            }
        }
        if validationError != nil {
            deviceImpl.generateAValidationError("Command buffer appears twice.")
            return
        }
        if initializationFailed {
            deviceImpl.generateAValidationError("GPUQueue.submit: lazy zero-initialization failed")
            return
        }

        for submission in submissions {
            _ = submission.command.impl.preCommitHandler(submission.command.shell)
            // A command encoder that overflowed one MTLCommandBuffer's render encoder budget spilled the
            // filled buffers here. They hold the commands encoded before this one, so they have to be
            // committed first; sequential commits on the same MTLCommandQueue execute in order.
            for priorCommandBuffer in submission.command.impl.takePriorCommandBuffers() {
                _ = commit(queue, priorCommandBuffer, commitsStagedWorkFirst: false)
            }
            if commit(queue, submission.commandBuffer, commitsStagedWorkFirst: false) {
                let token = CommitToken()
                submission.command.impl.applyInitializationEffects(token)
            } else {
                submission.command.impl.dropInitializationLedger()
            }
            submission.command.impl.postCommitHandler(submission.command.shell)
        }

        if MTLCaptureManager.shared().isCapturing && shouldStopCaptureAfterSubmit() {
            MTLCaptureManager.shared().stopCapture()
        }
    }

    // MARK: writeBuffer

    private func validateWriteBuffer(
        _ buffer: WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ bufferOffset: UInt64,
        _ size: Int,
        _ deviceImpl: DeviceImpl
    ) -> Bool {
        if !isValidToUse(buffer.isValid(), bufferImpl.deviceImpl, deviceImpl) {
            return false
        }

        if buffer.state() != WebGPU.Metal.Buffer.State.Unmapped {
            return false
        }

        if !buffer.usage().contains(WebGPU.BufferUsage.CopyDestination) {
            return false
        }

        if size % 4 != 0 {
            return false
        }

        if bufferOffset % 4 != 0 {
            return false
        }

        guard let end = checkedSum(UInt64.self, bufferOffset, UInt64(size)), end <= buffer.currentSize() else {
            return false
        }

        return true
    }

    @_expose(Cxx)
    func writeBuffer(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ buffer: WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ bufferOffset: UInt64,
        _ data: WebGPU.Metal.QueueBytes
    ) {
        let bytes: Span<UInt8> = data.span()
        writeBuffer(queue, device, deviceImpl, buffer, bufferImpl, bufferOffset, bytes: bytes, nil)
    }

    // writeBuffer() of all of `owner`'s bytes, `data`.
    @_expose(Cxx)
    func writeBufferFromOwner(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ buffer: WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ bufferOffset: UInt64,
        _ data: WebGPU.Metal.QueueBytes,
        _ owner: WebGPU.ByteOwner
    ) {
        let bytes: Span<UInt8> = data.span()
        writeBuffer(queue, device, deviceImpl, buffer, bufferImpl, bufferOffset, bytes: bytes, AliasableBytes(owner))
    }

    // `aliasable` owns exactly `data`.
    private func writeBuffer(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ buffer: WebGPU.Metal.Buffer,
        _ bufferImpl: BufferImpl,
        _ bufferOffset: UInt64,
        bytes data: Span<UInt8>,
        _ aliasable: AliasableBytes?
    ) {
        // https://gpuweb.github.io/gpuweb/#dom-gpuqueue-writebuffer

        let dataSize = data.count
        if !validateWriteBuffer(buffer, bufferImpl, bufferOffset, dataSize, deviceImpl)
            || !isValidToUse(buffer.isValid(), bufferImpl.deviceImpl, deviceImpl)
        {
            deviceImpl.generateAValidationError("Validation failure.")
            return
        }

        if data.isEmpty {
            return
        }

        if buffer.isDestroyed() {
            deviceImpl.generateAValidationError("GPUQueue.writeBuffer: destination buffer is destroyed")
            return
        }

        // FIXME(PERFORMANCE): Instead of checking whether or not the whole queue is idle,
        // we could detect whether this specific resource is idle, if we tracked every resource.
        var needsInvalidation = true

        if dataSize < 16 * 1024 && buffer.usage().contains(WebGPU.BufferUsage.Index)
            && !buffer.usage().contains(WebGPU.BufferUsage.Indirect)
        {
            let maxValues = maxIndexValue(data)
            if !buffer.needsIndexValidation(maxValues.maxUInt32, maxValues.maxUInt16) {
                needsInvalidation = false
                buffer.indexBufferContentsModified(maxValues.maxUInt32, maxValues.maxUInt16)
            }
        }
        if needsInvalidation {
            buffer.indirectBufferInvalidated()
        }
        if isIdle() {
            switch writeStorage(buffer.buffer()) {
            case .cpu:
                WebGPU.Metal.writeBufferContents(buffer.buffer(), bufferOffset, data)
                return
            case .gpu:
                break
            case .unsupported:
                assertionFailure()
                return
            }
        }
        stageBufferWrite(queue, device, deviceImpl, buffer.buffer(), bufferOffset, bytes: data, aliasable)
    }

    private func temporaryBufferNeedsReplacement(_ dataSize: UInt64) -> Bool {
        guard let backingTemporaryBuffer else {
            return true
        }
        return temporaryBufferOffset &+ dataSize > UInt64(backingTemporaryBuffer.length)
    }

    // The offset of the bytes in the returned buffer is stored into `offset`.
    @_expose(Cxx)
    func newTemporaryBufferWithBytes(
        _ device: WebGPU.Metal.Device,
        _ data: WebGPU.Metal.QueueBytes,
        _ noCopy: Bool,
        _ offset: inout UInt64
    ) -> (any MTLBuffer)? {
        let bytes: Span<UInt8> = data.span()
        return newTemporaryBuffer(device, bytes: bytes, aliasing: nil, from: 0, noCopy, &offset)
    }

    // `data` starts `ownerOffset` bytes into the bytes `aliasable` owns.
    private func newTemporaryBuffer(
        _ device: WebGPU.Metal.Device,
        bytes data: Span<UInt8>,
        aliasing aliasable: AliasableBytes?,
        from ownerOffset: UInt64,
        _ noCopy: Bool,
        _ offset: inout UInt64
    ) -> (any MTLBuffer)? {
        if noCopy {
            offset = 0
            if let aliasable {
                return aliasable.newBuffer(device, from: ownerOffset, length: UInt64(data.count))
            }
            // Without an owner, nothing keeps `data` alive until the GPU has read it. So it is copied, into a buffer
            // of its own that the command buffer which reads it releases: the temporary buffer does not grow to its size.
            guard let buffer = device.safeCreateBuffer(UInt(data.count), true) else {
                return nil
            }
            WebGPU.Metal.copyBytesToBuffer(buffer, 0, data)
            return buffer
        }

        let priorOffset = reserveTemporaryBufferRange(device, UInt64(data.count))
        // An empty span from C++ may have a null base address, which the Span overload's conversion back traps on.
        if !data.isEmpty {
            WebGPU.Metal.copyBytesToBuffer(backingTemporaryBuffer, priorOffset, data)
        }
        offset = priorOffset
        return backingTemporaryBuffer
    }

    // Returns where `dataSize` bytes go in the temporary buffer, replacing the buffer first if they do not fit.
    private func reserveTemporaryBufferRange(_ device: WebGPU.Metal.Device, _ dataSize: UInt64) -> UInt64 {
        if temporaryBufferNeedsReplacement(dataSize) {
            backingTemporaryBuffer = device.safeCreateBuffer(UInt(max(dataSize, 64 * 1024)), true)
            temporaryBufferOffset = 0
        }

        // The next range starts 64-byte aligned.
        let priorOffset = temporaryBufferOffset
        temporaryBufferOffset &+= (dataSize &+ 63) & ~UInt64(63)
        return priorOffset
    }

    @_expose(Cxx)
    func stageBufferWrite(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ buffer: (any MTLBuffer)?,
        _ bufferOffset: UInt64,
        _ data: WebGPU.Metal.QueueBytes
    ) {
        let bytes: Span<UInt8> = data.span()
        stageBufferWrite(queue, device, deviceImpl, buffer, bufferOffset, bytes: bytes, nil)
    }

    private func stageBufferWrite(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ buffer: (any MTLBuffer)?,
        _ bufferOffset: UInt64,
        bytes data: Span<UInt8>,
        _ aliasable: AliasableBytes?
    ) {
        guard let buffer, !data.isEmpty else {
            return
        }

        let noCopy = UInt64(data.count) >= largeBufferSize
        var temporaryBufferOffset: UInt64 = 0
        guard let temporaryBuffer = newTemporaryBuffer(device, bytes: data, aliasing: aliasable, from: 0, noCopy, &temporaryBufferOffset)
        else {
            assertionFailure()
            return
        }

        encodeStagedCopy(queue, deviceImpl, temporaryBuffer, temporaryBufferOffset, buffer, bufferOffset, UInt64(data.count), noCopy)
    }

    // Encodes an already-staged copy, choosing the channel it rides.
    //
    // Encode the staged copy on the compute channel when possible. Standalone blit-only staging command
    // buffers interleaved with user compute submissions intermittently deadlock the AGX blit/DMA channel
    // (the driver reports kIOGPUCommandBufferCallbackErrorHang on the staging command buffer and
    // discards neighboring command buffers as innocent victims), losing the device. Encoding the same
    // copies as compute dispatches keeps the commit points, queue ordering, and hazard tracking
    // identical while keeping the per-frame hot path off the blit channel entirely. GPUQueue.writeBuffer
    // validation guarantees 4-byte alignment of both offset and size, and the staging suballocator is
    // 64-byte aligned, so the word-copy kernel covers every spec-reachable write; the blit encoder
    // remains as the fallback (and for writeTexture, clearBuffer, and internal copies).
    private func encodeStagedCopy(
        _ queue: WebGPU.Metal.Queue,
        _ deviceImpl: DeviceImpl,
        _ temporaryBuffer: any MTLBuffer,
        _ temporaryBufferOffset: UInt64,
        _ buffer: any MTLBuffer,
        _ bufferOffset: UInt64,
        _ size: UInt64,
        _ finalizeAfterCopy: Bool
    ) {
        if size == 0 {
            return
        }

        // The copy kernel's loop is bounded by wordCount alone, so a bad range would write out of
        // bounds rather than fault. Check both sides here, by subtraction so the sums cannot overflow.
        let bufferLength = UInt64(buffer.length)
        if bufferOffset > bufferLength || size > bufferLength - bufferOffset {
            return
        }
        let temporaryBufferLength = UInt64(temporaryBuffer.length)
        if temporaryBufferOffset > temporaryBufferLength || size > temporaryBufferLength - temporaryBufferOffset {
            return
        }

        let wordAligned = bufferOffset % 4 == 0 && size % 4 == 0 && temporaryBufferOffset % 4 == 0
        let pipelineState = wordAligned ? stagedCopyPipelineState(deviceImpl) : nil
        // A null encoder here means creation failed, not that compute is unavailable; fall through to
        // the blit encoder rather than dropping the copy, which would leave the destination stale.
        let stagedCopyEncoder = pipelineState != nil ? ensureStagedCopyEncoder(queue) : nil
        if let stagedCopyEncoder, let pipelineState {
            let wordCount = size / 4
            stagedCopyEncoder.setComputePipelineState(pipelineState)
            stagedCopyEncoder.setBuffer(temporaryBuffer, offset: 0, index: 0)
            stagedCopyEncoder.setBuffer(buffer, offset: 0, index: 1)
            WebGPU.Metal.Queue.setStagedCopyArguments(stagedCopyEncoder, temporaryBufferOffset / 4, bufferOffset / 4, wordCount)
            let threadsPerThreadgroup = min(UInt64(256), UInt64(pipelineState.maxTotalThreadsPerThreadgroup))
            let threadgroups = min((wordCount &+ threadsPerThreadgroup &- 1) / threadsPerThreadgroup, 2048)
            stagedCopyEncoder.dispatchThreadgroups(
                MTLSize(width: Int(threadgroups), height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: Int(threadsPerThreadgroup), height: 1, depth: 1)
            )

            if finalizeAfterCopy {
                finalizeBlitCommandEncoder(queue)
            }
            return
        }

        guard let blitCommandEncoder = ensureBlitCommandEncoder(queue) else {
            return
        }

        blitCommandEncoder.copy(
            from: temporaryBuffer,
            sourceOffset: Int(temporaryBufferOffset),
            to: buffer,
            destinationOffset: Int(bufferOffset),
            size: Int(size)
        )

        if finalizeAfterCopy {
            finalizeBlitCommandEncoder(queue)
        }
    }

    @_expose(Cxx)
    func clearBuffer(_ queue: WebGPU.Metal.Queue, _ buffer: (any MTLBuffer)?, _ offset: UInt, _ size: UInt) {
        let length = UInt(buffer?.length ?? 0)
        if offset > length {
            return
        }

        let blitCommandEncoder = ensureBlitCommandEncoder(queue)
        guard let buffer else {
            return
        }
        let lengthMinusOffset = length - offset
        blitCommandEncoder?.fill(buffer: buffer, range: Int(offset)..<Int(offset + min(lengthMinusOffset, size)), value: 0)
    }

    // MARK: Pipelines

    private func stagedCopyPipelineState(_ deviceImpl: DeviceImpl) -> (any MTLComputePipelineState)? {
        if let backingStagedCopyPipelineState {
            return backingStagedCopyPipelineState
        }
        if stagedCopyPipelineCreationFailed {
            return nil
        }

        guard let mtlDevice = deviceImpl.device() else {
            return nil
        }

        var pipelineState: (any MTLComputePipelineState)?
        var error: (any Error)?
        do {
            let library = try mtlDevice.makeLibrary(source: stagedCopyShaderSource, options: nil)
            if let function = library.makeFunction(name: "csStagedBufferCopy") {
                pipelineState = try mtlDevice.makeComputePipelineState(function: function)
            }
        } catch let caught {
            error = caught
        }
        backingStagedCopyPipelineState = pipelineState
        stagedCopyPipelineCreationFailed = pipelineState == nil
        if pipelineState == nil {
            WebGPU.Metal.logAlways(
                "WebGPU: staged-copy compute pipeline creation failed (\(errorDescription(error))); staged writes will fall back to blit"
            )
        }
        return pipelineState
    }

    private func copyExternalImagePipelineState(_ deviceImpl: DeviceImpl, _ pixelFormat: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if copyExternalImagePipelineCreationFailed || pixelFormat == .invalid {
            return nil
        }

        if let cachedPipelineState = copyExternalImagePipelineStates[pixelFormat.rawValue] {
            return cachedPipelineState
        }

        guard let mtlDevice = deviceImpl.device() else {
            return nil
        }

        var pipelineState: (any MTLRenderPipelineState)?
        var error: (any Error)?
        do {
            let library = try mtlDevice.makeLibrary(source: copyExternalImageShaderSource, options: nil)
            if let vertexFunction = library.makeFunction(name: "vsCopyExternalImage"),
                let fragmentFunction = library.makeFunction(name: "fsCopyExternalImage")
            {
                let pipelineDescriptor = MTLRenderPipelineDescriptor()
                pipelineDescriptor.vertexFunction = vertexFunction
                pipelineDescriptor.fragmentFunction = fragmentFunction
                pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
                pipelineState = try mtlDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            }
        } catch let caught {
            error = caught
        }

        guard let pipelineState else {
            copyExternalImagePipelineCreationFailed = true
            WebGPU.Metal.logAlways("WebGPU: copyExternalImageToTexture render pipeline creation failed (\(errorDescription(error)))")
            return nil
        }
        copyExternalImagePipelineStates[pixelFormat.rawValue] = pipelineState
        return pipelineState
    }

    // MARK: Lazy zero-initialization

    private func stagingZeroBuffer(_ device: WebGPU.Metal.Device, length: UInt) -> (any MTLBuffer)? {
        if let zeroBuffer, UInt(zeroBuffer.length) >= length {
            return zeroBuffer
        }
        let buffer = device.safeCreateBuffer(length, false)
        if length <= Self.maximumKeptZeroBufferLength {
            zeroBuffer = buffer
        }
        return buffer
    }

    /// An empty render pass on `commandBuffer` that clears `region` of a render-attachment texture to zero.
    ///
    /// It loads and stores the other aspect of a combined format, and needs no zeroed buffer. False when nothing was
    /// encoded.
    private func encodeRenderZeroFill(
        _ queue: WebGPU.Metal.Queue,
        _ texture: TextureImpl,
        _ region: InitRegion,
        _ commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        guard !texture.isTransient, let format = texture.backingFormat, let mtlTexture = texture.texture() else {
            return false
        }
        let (mipLevel, layer) = texture.initSubresource(region)
        let aspect = texture.initAspect(region)
        let hasDepth = containsDepthAspect(format)
        let hasStencil = containsStencilAspect(format)
        let descriptor = MTLRenderPassDescriptor()
        if !hasDepth && !hasStencil {
            guard let color = descriptor.colorAttachments[0] else {
                return false
            }
            color.texture = mtlTexture
            color.level = Int(mipLevel)
            color.slice = Int(layer)
            color.loadAction = .clear
            color.storeAction = .store
            color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        if hasDepth, let depth = descriptor.depthAttachment {
            depth.texture = mtlTexture
            depth.level = Int(mipLevel)
            depth.slice = Int(layer)
            depth.loadAction = aspect == .stencil ? .load : .clear
            depth.storeAction = .store
            depth.clearDepth = 0
        }
        if hasStencil, let stencil = descriptor.stencilAttachment {
            stencil.texture = mtlTexture
            stencil.level = Int(mipLevel)
            stencil.slice = Int(layer)
            stencil.loadAction = aspect == .depth ? .load : .clear
            stencil.storeAction = .store
            stencil.clearStencil = 0
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        setEncoderForBuffer(queue, commandBuffer, encoder)
        endEncoding(queue, encoder, commandBuffer)
        return true
    }

    /// Zero-fills one region on the staging command buffer and marks it initialized.
    ///
    /// commit() commits the staging command buffer before any later command buffer. False when no zero fill could be
    /// encoded: the region stays uninitialized.
    private func stageZeroFill(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ texture: TextureImpl,
        _ region: InitRegion
    ) -> Bool {
        if texture.isInitialized(region) || texture.isTransient {
            return true
        }
        let encoded: Bool
        if texture.prefersRenderZeroFill {
            guard ensureBlitCommandEncoder(queue) != nil, let commandBuffer = backingStagingCommandBuffer else {
                return false
            }
            endStagingEncoders(queue)
            encoded = encodeRenderZeroFill(queue, texture, region, commandBuffer)
            // ensureBlitCommandEncoder() only reuses a staging command buffer that has an open encoder.
            blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()
            if let encoder = blitCommandEncoder {
                setEncoderForBuffer(queue, commandBuffer, encoder)
            } else {
                finalizeBlitCommandEncoder(queue)
            }
        } else {
            guard let blit = ensureBlitCommandEncoder(queue) else {
                return false
            }
            encoded = encodeBlitZeroFill(texture, region, blit, zeroBuffer: { stagingZeroBuffer(device, length: $0) })
        }
        guard encoded else {
            return false
        }
        let token = CommitToken()
        texture.markInitialized(region, token)
        return true
    }

    /// Zero-fills `fixUp` at the end of `commandBuffer`, a finished command buffer of the submit in progress.
    private func encodeZeroFill(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ fixUp: InitFixUp,
        into commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        if fixUp.texture.prefersRenderZeroFill {
            return encodeRenderZeroFill(queue, fixUp.texture, fixUp.region, commandBuffer)
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }
        setEncoderForBuffer(queue, commandBuffer, blit)
        let encoded = encodeBlitZeroFill(fixUp.texture, fixUp.region, blit, zeroBuffer: { stagingZeroBuffer(device, length: $0) })
        endEncoding(queue, blit, commandBuffer)
        return encoded
    }

    /// Writes a written region down as initialized, once the write was encoded on the staging command buffer or performed.
    private func markWritten(_ texture: TextureImpl, _ regions: [InitRegion]) {
        let token = CommitToken()
        for region in regions {
            texture.markInitialized(region, token)
        }
    }

    /// Zero-fills what the command buffers require, given the regions as the command buffers before them in this submit
    /// leave them.
    ///
    /// A region an earlier command buffer of this submit discarded is zero-filled at the end of that command buffer
    /// (before the batch, it would wipe what the command buffers in between read); every other one on the staging command
    /// buffer, which is committed first. False when a zero fill could not be encoded.
    private func stageInitializationFixUps(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ submissions: [(commandBuffer: any MTLCommandBuffer, command: SubmittedCommand)]
    ) -> Bool {
        // The steady state: no encoder read a region that might not be initialized when it runs.
        guard submissions.contains(where: { $0.command.impl.hasInitializationRequirements }) else {
            return true
        }
        var overlay = InitOverlay()
        var lastDiscarder: [InitOverlay.Key: Int] = [:]
        var beforeAll: [InitFixUp] = []
        var afterDiscarder: [(index: Int, fixUp: InitFixUp)] = []
        for (index, submission) in submissions.enumerated() {
            submission.command.impl.forEachInitializationRequirement { texture, region in
                if overlay.isInitialized(texture, region) || texture.isTransient {
                    return
                }
                if let discarder = lastDiscarder[InitOverlay.Key(texture, region)] {
                    afterDiscarder.append((discarder, InitFixUp(texture: texture, region: region)))
                } else {
                    beforeAll.append(InitFixUp(texture: texture, region: region))
                }
                overlay.set(texture, region, true)
            }
            submission.command.impl.forEachInitializationEffect { texture, region, effect in
                overlay.set(texture, region, effect == .written)
                lastDiscarder[InitOverlay.Key(texture, region)] = effect == .written ? nil : index
            }
        }
        for fixUp in beforeAll {
            guard stageZeroFill(queue, device, fixUp.texture, fixUp.region) else {
                return false
            }
        }
        for (index, fixUp) in afterDiscarder {
            guard encodeZeroFill(queue, device, fixUp, into: submissions[index].commandBuffer) else {
                return false
            }
            submissions[index].command.impl.noteAppendedZeroFill(fixUp)
        }
        return true
    }

    // Queue::clearTextureViewIfNeeded, for bind groups: zero-fills, on the staging command buffer committed at once, every
    // uninitialized region the view covers. False when one could not be zero-filled.
    @_expose(Cxx)
    func clearTextureIfNeeded(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ parentImpl: TextureImpl,
        _ aspect: WebGPU.TextureAspect,
        _ mipLevelCount: UInt32,
        _ arrayLayerCount: UInt32,
        _ baseMipLevel: UInt32,
        _ baseArrayLayer: UInt32
    ) -> Bool {
        var initialized = true
        if !parentImpl.isFullyInitialized {
            for slice in 0..<arrayLayerCount {
                for mipLevel in 0..<mipLevelCount {
                    let checkedParentMipLevel = checkedSum(UInt32.self, UInt64(baseMipLevel), UInt64(mipLevel))
                    let checkedParentSlice = checkedSum(UInt32.self, UInt64(baseArrayLayer), UInt64(slice))
                    guard let parentMipLevel = checkedParentMipLevel, let parentSlice = checkedParentSlice else {
                        return false
                    }
                    for region in parentImpl.initRegions(mipLevel: parentMipLevel, layer: parentSlice, aspect: aspect)
                    where !stageZeroFill(queue, device, parentImpl, region) {
                        initialized = false
                    }
                }
            }
        }
        finalizeBlitCommandEncoder(queue)
        return initialized
    }

    // MARK: writeTexture

    private func errorValidatingWriteTexture(
        _ destination: WebGPU.TexelCopyTextureInfo,
        _ dataLayout: WebGPU.TexelCopyBufferLayout,
        _ size: WebGPU.Extent3D,
        _ dataByteSize: Int,
        _ texture: WebGPU.Metal.Texture,
        _ textureImpl: TextureImpl,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl
    ) -> String? {
        func errorString(_ error: String) -> String {
            "GPUQueue.writeTexture: \(error)"
        }
        if !isValidToUse(texture.isValid(), textureImpl.deviceImpl, deviceImpl) {
            return errorString("destination texture is not valid")
        }

        if let error = WebGPU.Metal.Texture.errorValidatingImageCopyTexture(destination, size) {
            return errorString(error)
        }

        if !texture.usage().contains(WebGPU.TextureUsage.CopyDestination) {
            return errorString("texture usage does not contain CopyDst")
        }

        if texture.sampleCount() != 1 {
            return errorString("destinationTexture sampleCount is not 1")
        }

        if let error = WebGPU.Metal.Texture.errorValidatingTextureCopyRange(destination, size) {
            return errorString(error)
        }

        if !refersToSingleAspect(texture.format(), destination.aspect) {
            return errorString("refersToSingleAspect failed")
        }

        var copyFormat = texture.format()

        if isDepthOrStencilFormat(texture.format()) {
            if !isValidDepthStencilCopyDestination(texture.format(), destination.aspect) {
                return errorString("isValidDepthStencilCopyDestination failed")
            }

            guard let format = aspectSpecificFormat(texture.format(), destination.aspect) else {
                return errorString("destination aspect has no aspect-specific format")
            }
            copyFormat = format
        }

        if let error = errorValidatingLinearTextureData(dataLayout, UInt64(dataByteSize), copyFormat, size) {
            return errorString(error)
        }

        return nil
    }

    @_expose(Cxx)
    func writeTexture(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ textureImpl: TextureImpl,
        _ destination: WebGPU.TexelCopyTextureInfo,
        _ data: WebGPU.Metal.QueueBytes,
        _ dataLayout: WebGPU.TexelCopyBufferLayout,
        _ size: WebGPU.Extent3D,
        _ skipValidation: Bool
    ) {
        let bytes: Span<UInt8> = data.span()
        _ = writeTexture(queue, device, deviceImpl, textureImpl, destination, bytes: bytes, nil, dataLayout, size, skipValidation, .decide)
    }

    // writeTexture() of all of `owner`'s bytes, `data`.
    @_expose(Cxx)
    func writeTextureFromOwner(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ textureImpl: TextureImpl,
        _ destination: WebGPU.TexelCopyTextureInfo,
        _ data: WebGPU.Metal.QueueBytes,
        _ owner: WebGPU.ByteOwner,
        _ dataLayout: WebGPU.TexelCopyBufferLayout,
        _ size: WebGPU.Extent3D
    ) {
        let bytes: Span<UInt8> = data.span()
        _ = writeTexture(
            queue,
            device,
            deviceImpl,
            textureImpl,
            destination,
            bytes: bytes,
            AliasableBytes(owner),
            dataLayout,
            size,
            false,
            .decide
        )
    }

    // Whether a write decides how it initializes its destination, or is one row of a write that already did.
    private enum WriteInitialization {
        case decide
        case handledByCaller
    }

    // False when not every byte of the write was encoded or performed, so that its full writes are not recorded.
    // `aliasable` owns exactly `data`.
    private func writeTexture(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ textureImpl: TextureImpl,
        _ destination: WebGPU.TexelCopyTextureInfo,
        bytes data: Span<UInt8>,
        _ aliasable: AliasableBytes?,
        _ dataLayout: WebGPU.TexelCopyBufferLayout,
        _ size: WebGPU.Extent3D,
        _ skipValidation: Bool,
        _ initialization: WriteInitialization
    ) -> Bool {
        // https://gpuweb.github.io/gpuweb/#dom-gpuqueue-writetexture

        var dataByteSize = data.count
        let texture = WebGPU.Metal.metal(destination.texture)
        if texture.isDestroyed() {
            deviceImpl.generateAValidationError("GPUQueue.writeTexture: destination texture is destroyed")
            return false
        }

        var textureFormat = texture.format()
        if isDepthOrStencilFormat(textureFormat) {
            guard let aspectSpecificFormat = aspectSpecificFormat(textureFormat, destination.aspect) else {
                deviceImpl.generateAValidationError("Invalid depth-stencil format")
                return false
            }
            textureFormat = aspectSpecificFormat
        }

        if !skipValidation {
            if let error = errorValidatingWriteTexture(
                destination,
                dataLayout,
                size,
                dataByteSize,
                texture,
                textureImpl,
                device,
                deviceImpl
            ) {
                deviceImpl.generateAValidationError(error)
                return false
            }
        }

        if data.isEmpty || dataByteSize == 0 || UInt64(dataByteSize) <= dataLayout.offset {
            return false
        }

        let blockSize = texelBlockSize(textureFormat)
        let logicalSize = texture.logicalMiplevelSpecificTextureExtent(destination.mipLevel)
        let widthForMetal = logicalSize.width < destination.origin.x ? 0 : min(size.width, logicalSize.width - destination.origin.x)
        if widthForMetal == 0 {
            return false
        }

        let heightForMetal = logicalSize.height < destination.origin.y ? 0 : min(size.height, logicalSize.height - destination.origin.y)
        let depthForMetal =
            logicalSize.depthOrArrayLayers < destination.origin.z
            ? 0 : min(size.depthOrArrayLayers, logicalSize.depthOrArrayLayers - destination.origin.z)

        var bytesPerRow = UInt(Optional(fromCxx: dataLayout.bytesPerRow) ?? UInt32(WGPU_COPY_STRIDE_UNDEFINED))
        if bytesPerRow == WGPU_COPY_STRIDE_UNDEFINED {
            let dataBytesPerRow = size.height != 0 ? (dataByteSize / Int(size.height)) : dataByteSize
            let textureBytesPerRow = textureBytesPerRow(textureFormat, widthForMetal, texture.sampleCount())
            bytesPerRow = UInt(max(UInt32(truncatingIfNeeded: dataBytesPerRow), UInt32(truncatingIfNeeded: textureBytesPerRow)))
        }

        let limits = deviceImpl.capabilities.limits
        switch texture.dimension() {
        case WebGPU.TextureDimension._1d:
            if let blockSizeTimes1DTextureLimit = checkedProduct(UInt32.self, UInt64(blockSize), UInt64(limits.maxTextureDimension1D)) {
                bytesPerRow = UInt(min(UInt32(truncatingIfNeeded: bytesPerRow), blockSizeTimes1DTextureLimit))
            }
        case WebGPU.TextureDimension._2d, WebGPU.TextureDimension._3d:
            if let blockSizeTimes2DTextureLimit = checkedProduct(UInt32.self, UInt64(blockSize), UInt64(limits.maxTextureDimension2D)) {
                bytesPerRow = UInt(min(UInt32(truncatingIfNeeded: bytesPerRow), blockSizeTimes2DTextureLimit))
            }
        default:
            break
        }

        let rowsPerImage = UInt(Optional(fromCxx: dataLayout.rowsPerImage) ?? size.height)
        guard let checkedBytesPerImage = checkedProduct(UInt32.self, UInt64(bytesPerRow), UInt64(rowsPerImage)) else {
            return false
        }
        var bytesPerImage = UInt(checkedBytesPerImage)

        var options: MTLBlitOption = []
        switch destination.aspect {
        case WebGPU.TextureAspect.All:
            options = []
        case WebGPU.TextureAspect.StencilOnly:
            options = .stencilFromDepthStencil
        case WebGPU.TextureAspect.DepthOnly:
            options = .depthFromDepthStencil
        default:
            break
        }

        let mtlTexture = texture.texture()
        let textureDimension = texture.dimension()
        let sliceCount = textureDimension == WebGPU.TextureDimension._3d ? 1 : size.depthOrArrayLayers
        // Marked once the write below has been encoded or performed.
        var regionsWrittenInFull: [InitRegion] = []
        var clearWasNeeded = false
        if initialization == .decide {
            let writesAll = writeWillCompletelyClear(
                textureDimension,
                widthForMetal,
                logicalSize.width,
                heightForMetal,
                logicalSize.height,
                depthForMetal,
                logicalSize.depthOrArrayLayers
            )
            for layer in 0..<sliceCount {
                guard let checkedDestinationSlice = checkedSum(UInt32.self, UInt64(destination.origin.z), UInt64(layer)) else {
                    return false
                }
                let destinationSlice: UInt32 = textureDimension == WebGPU.TextureDimension._3d ? 0 : checkedDestinationSlice
                for region in textureImpl.initRegions(mipLevel: destination.mipLevel, layer: destinationSlice, aspect: destination.aspect)
                where !textureImpl.isInitialized(region) {
                    if writesAll {
                        regionsWrittenInFull.append(region)
                    } else {
                        clearWasNeeded = true
                        guard stageZeroFill(queue, device, textureImpl, region) else {
                            return false
                        }
                    }
                }
            }
        }

        guard let checkedBlockSizeTimes2048 = checkedProduct(UInt32.self, 2048, UInt64(blockSize)) else {
            return false
        }
        let maxRowBytes = textureDimension == WebGPU.TextureDimension._3d ? UInt(checkedBlockSizeTimes2048) : bytesPerRow
        let isCompressed = isCompressedFormat(textureFormat)
        let blockHeight = texelBlockHeight(textureFormat)
        let blockWidth = texelBlockWidth(textureFormat)
        let texelBlock = WebGPU.Metal.TexelBlockLayout(width: blockWidth, height: blockHeight, size: blockSize)
        if !isCompressed && (bytesPerRow % UInt(blockSize) != 0 || bytesPerRow > maxRowBytes) {
            var newSize = WebGPU.Extent3D()
            newSize.width = size.width
            newSize.height = isCompressed ? blockSize : blockHeight
            newSize.depthOrArrayLayers = 1

            if textureDimension != WebGPU.TextureDimension._1d
                && (heightForMetal > newSize.height || depthForMetal > newSize.depthOrArrayLayers)
            {
                var newDataLayout = WebGPU.TexelCopyBufferLayout()
                newDataLayout.offset = 0
                newDataLayout.bytesPerRow = .init(
                    min(
                        UInt32(truncatingIfNeeded: maxRowBytes),
                        Optional(fromCxx: dataLayout.bytesPerRow) ?? UInt32(WGPU_COPY_STRIDE_UNDEFINED)
                    )
                )
                newDataLayout.rowsPerImage = .init(newSize.height)

                let blockWidth = texelBlockWidth(textureFormat)
                let widthInBlocks = blockWidth != 0 ? (widthForMetal / blockWidth) : 0
                guard let bytesInLastRow = checkedProduct(UInt64.self, UInt64(blockSize), UInt64(widthInBlocks)) else {
                    return false
                }

                let endZ = max(UInt32(1), depthForMetal)
                var z: UInt32 = 0
                while z < endZ {
                    var newDestination = destination
                    guard let newDestinationOriginZ = checkedSum(UInt32.self, UInt64(destination.origin.z), UInt64(z)) else {
                        return false
                    }
                    newDestination.origin.z = newDestinationOriginZ
                    let endY = textureDimension == WebGPU.TextureDimension._1d ? max(UInt32(1), heightForMetal) : heightForMetal
                    var y: UInt32 = 0
                    while y < endY {
                        guard let destinationOriginYPlusY = checkedSum(UInt32.self, UInt64(destination.origin.y), UInt64(y)) else {
                            return false
                        }
                        newDestination.origin.y = destinationOriginYPlusY
                        guard
                            let newDestinationOriginYPlusHeight = checkedSum(
                                UInt32.self,
                                UInt64(newDestination.origin.y),
                                UInt64(newSize.height)
                            )
                        else {
                            checkedValueOverflowed()
                        }
                        if newDestinationOriginYPlusHeight > logicalSize.height {
                            newSize.height = newDestinationOriginYPlusHeight - logicalSize.height
                        }

                        guard let bytesPerRowTimesHeight = checkedProduct(UInt32.self, UInt64(bytesPerRow), UInt64(newSize.height)) else {
                            return false
                        }
                        let chunkSize: UInt64 = (y &+ 1 == endY) ? bytesInLastRow : UInt64(bytesPerRowTimesHeight)
                        var x: UInt32 = 0
                        while x < widthForMetal {
                            guard let destinationOriginXPlusX = checkedSum(UInt32.self, UInt64(destination.origin.x), UInt64(x)) else {
                                return false
                            }
                            newDestination.origin.x = destinationOriginXPlusX
                            let yTimesBytesPerRow = checkedProduct(UInt32.self, UInt64(y), UInt64(bytesPerRow))
                            let zTimesBytesPerImage = checkedProduct(UInt32.self, UInt64(z), UInt64(bytesPerImage))
                            guard let yTimesBytesPerRow, let zTimesBytesPerImage else {
                                return false
                            }
                            guard let offset = checkedSum(UInt32.self, UInt64(x), UInt64(yTimesBytesPerRow), UInt64(zTimesBytesPerImage))
                            else {
                                return false
                            }
                            guard let offsetPlusSize = checkedSum(UInt32.self, UInt64(offset), chunkSize), Int(offsetPlusSize) <= data.count
                            else {
                                return false
                            }

                            guard
                                writeTexture(
                                    queue,
                                    device,
                                    deviceImpl,
                                    textureImpl,
                                    newDestination,
                                    bytes: data.extracting(Int(offset)..<Int(offsetPlusSize)),
                                    nil,
                                    newDataLayout,
                                    newSize,
                                    false,
                                    .handledByCaller
                                )
                            else {
                                return false
                            }
                            guard let xPlusMaxRowBytes = checkedSum(UInt32.self, UInt64(x), UInt64(maxRowBytes)) else {
                                return false
                            }
                            x = xPlusMaxRowBytes
                        }
                        guard let yPlusHeight = checkedSum(UInt32.self, UInt64(y), UInt64(newSize.height)) else {
                            return false
                        }
                        y = yPlusHeight
                    }
                    z &+= 1
                }
                markWritten(textureImpl, regionsWrittenInFull)
                return true
            }

            bytesPerRow = 0
            bytesPerImage = 0
        }

        switch textureDimension {
        case WebGPU.TextureDimension._1d, WebGPU.TextureDimension._2d:
            if widthForMetal == 0 || heightForMetal == 0 {
                return false
            }
        case WebGPU.TextureDimension._3d:
            if widthForMetal == 0 || heightForMetal == 0 || depthForMetal == 0 {
                return false
            }
        default:
            break
        }

        // The compressed rows below, repacked; from then on the writes read these instead of `data`.
        var repacked: ContiguousArray<UInt8> = []
        var isRepacked = false
        guard
            let newBytesPerRow = checkedProduct(
                UInt32.self,
                UInt64(blockSize),
                UInt64((widthForMetal / blockWidth) + ((widthForMetal % blockWidth) != 0 ? 1 : 0))
            )
        else {
            return false
        }
        var dataLayoutOffset = dataLayout.offset
        let widthMismatch =
            UInt(newBytesPerRow) != bytesPerRow && widthForMetal == logicalSize.width && heightForMetal == logicalSize.height
        let multipleOfBlockSize = bytesPerRow % UInt(blockSize) != 0
        if isCompressed && (widthMismatch || multipleOfBlockSize) {
            let maxY = max(UInt(blockHeight), UInt(heightForMetal)) / UInt(blockHeight)
            let blockRows = UInt(logicalSize.height / blockHeight + (logicalSize.height % blockHeight != 0 ? 1 : 0))
            guard let newBytesPerImage = checkedProduct(UInt32.self, UInt64(newBytesPerRow), UInt64(max(UInt(blockHeight), blockRows)))
            else {
                return false
            }
            let maxZ = max(UInt(1), UInt(size.depthOrArrayLayers))
            guard let newDataSize = checkedProduct(UInt32.self, UInt64(newBytesPerImage), UInt64(maxZ)) else {
                return false
            }
            repacked = ContiguousArray(repeating: 0, count: Int(newDataSize))
            isRepacked = true
            dataLayoutOffset = 0

            let verticalOffset = checkedProduct(UInt64.self, UInt64(maxY != 0 ? (maxY - 1) : 0), UInt64(bytesPerRow))
            assert(maxZ != 0)
            let depthOffset = checkedProduct(UInt64.self, UInt64(maxZ - 1), UInt64(bytesPerImage))
            guard let verticalOffsetValue = verticalOffset, let depthOffsetValue = depthOffset else {
                checkedValueOverflowed()
            }
            if checkedSum(UInt64.self, verticalOffsetValue, depthOffsetValue, UInt64(newBytesPerRow)) == nil {
                deviceImpl.generateAValidationError("Result overflows uin64_t")
                return false
            }

            if maxY != 0 {
                let maxYMinus1TimesNewBytesPerRow = checkedProduct(UInt32.self, UInt64(maxY - 1), UInt64(newBytesPerRow))
                let maxZMinus1TimesNewBytesPerImage = checkedProduct(UInt32.self, UInt64(maxZ - 1), UInt64(newBytesPerImage))
                let maxYMinus1TimesBytesPerRow = checkedProduct(UInt32.self, UInt64(maxY - 1), UInt64(bytesPerRow))
                let maxZMinus1TimesBytesPerImage = checkedProduct(UInt32.self, UInt64(maxZ - 1), UInt64(bytesPerImage))
                guard let maxYMinus1TimesNewBytesPerRow, let maxZMinus1TimesNewBytesPerImage, let maxYMinus1TimesBytesPerRow,
                    let maxZMinus1TimesBytesPerImage
                else {
                    return false
                }
                let checkedNewBytesSum = checkedSum(
                    UInt32.self,
                    UInt64(maxYMinus1TimesNewBytesPerRow),
                    UInt64(maxZMinus1TimesNewBytesPerImage),
                    UInt64(newBytesPerRow)
                )
                let checkedBytesSum = checkedSum(
                    UInt32.self,
                    UInt64(maxYMinus1TimesBytesPerRow),
                    UInt64(maxZMinus1TimesBytesPerImage),
                    dataLayout.offset,
                    UInt64(newBytesPerRow)
                )
                guard let checkedNewBytesSum, let checkedBytesSum else {
                    return false
                }
                if Int(checkedNewBytesSum) > repacked.count || Int(checkedBytesSum) > data.count {
                    let y = maxY - 1
                    let z = maxZ - 1
                    deviceImpl.generateAValidationError(
                        "y(\(y)) * newBytesPerRow(\(newBytesPerRow)) + z(\(z)) * newBytesPerImage(\(newBytesPerImage)) + newBytesPerRow(\(newBytesPerRow)) > newData.size()(\(repacked.count)) || y(\(y)) * bytesPerRow(\(bytesPerRow)) + z(\(z)) * bytesPerImage(\(bytesPerImage)) + newBytesPerRow(\(newBytesPerRow)) > dataSize(\(data.count)), copySize \(widthForMetal), \(heightForMetal), \(depthForMetal), textureSize \(logicalSize.width), \(logicalSize.height), \(logicalSize.depthOrArrayLayers), offset \(dataLayout.offset)"
                    )
                    return false
                }
            }

            var repackedBytes = repacked.mutableSpan
            for z in 0..<maxZ {
                for y in 0..<maxY {
                    let yTimesBytesPerRow = checkedProduct(UInt32.self, UInt64(y), UInt64(bytesPerRow))
                    let yTimesNewBytesPerRow = checkedProduct(UInt32.self, UInt64(y), UInt64(newBytesPerRow))
                    let zTimesBytesPerImage = checkedProduct(UInt32.self, UInt64(z), UInt64(bytesPerImage))
                    let zTimesNewBytesPerImage = checkedProduct(UInt32.self, UInt64(z), UInt64(newBytesPerImage))
                    guard let yTimesBytesPerRow, let yTimesNewBytesPerRow, let zTimesBytesPerImage, let zTimesNewBytesPerImage else {
                        return false
                    }
                    let checkedYPlusZPlusOffset = checkedSum(
                        UInt32.self,
                        UInt64(yTimesBytesPerRow),
                        UInt64(zTimesBytesPerImage),
                        dataLayout.offset
                    )
                    let checkedNewYPlusNewZ = checkedSum(UInt32.self, UInt64(yTimesNewBytesPerRow), UInt64(zTimesNewBytesPerImage))
                    guard let checkedYPlusZPlusOffset, let checkedNewYPlusNewZ else {
                        return false
                    }
                    let destinationStart = Int(checkedNewYPlusNewZ)
                    let sourceStart = Int(checkedYPlusZPlusOffset)
                    for byte in 0..<Int(newBytesPerRow) {
                        repackedBytes[destinationStart + byte] = data[sourceStart + byte]
                    }
                }
            }

            bytesPerRow = UInt(newBytesPerRow)
            dataByteSize = repacked.count
            bytesPerImage = UInt(newBytesPerImage)
        }

        let repackedBytes = repacked
        let source: Span<UInt8> = isRepacked ? repackedBytes.span : data
        // A layer the write skipped (its source offset is not aligned, reachable over IPC only) is not written.
        var skippedLayer = false
        // FIXME(PERFORMANCE): Instead of checking whether or not the whole queue is idle,
        // we could detect whether this specific resource is idle, if we tracked every resource.
        if isIdle() && options.isEmpty && !clearWasNeeded {
            switch writeStorage(mtlTexture) {
            case .cpu:
                switch textureDimension {
                case WebGPU.TextureDimension._1d:
                    if widthForMetal == 0 || heightForMetal == 0 {
                        return false
                    }

                    let region = MTLRegion(
                        origin: MTLOrigin(x: Int(destination.origin.x), y: 0, z: 0),
                        size: MTLSize(width: Int(widthForMetal), height: 1, depth: 1)
                    )
                    for layer in 0..<size.depthOrArrayLayers {
                        guard let layerTimesBytesPerImage = checkedProduct(UInt32.self, UInt64(layer), UInt64(bytesPerImage)) else {
                            return false
                        }
                        guard let dataLayoutOffsetPlusSum = checkedSum(UInt32.self, dataLayoutOffset, UInt64(layerTimesBytesPerImage))
                        else {
                            return false
                        }
                        let sourceOffset = UInt(dataLayoutOffsetPlusSum)
                        if sourceOffset % UInt(blockSize) != 0 {
                            skippedLayer = true
                            continue
                        }
                        guard let destinationSlice = checkedSum(UInt.self, UInt64(destination.origin.z), UInt64(layer)) else {
                            return false
                        }
                        WebGPU.Metal.replaceRegion(
                            mtlTexture,
                            region,
                            destination.mipLevel,
                            UInt64(destinationSlice),
                            source,
                            UInt64(sourceOffset),
                            0,
                            0,
                            texelBlock
                        )
                    }
                case WebGPU.TextureDimension._2d:
                    if widthForMetal == 0 || heightForMetal == 0 {
                        return false
                    }

                    let region = MTLRegion(
                        origin: MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: 0),
                        size: MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: 1)
                    )
                    for layer in 0..<size.depthOrArrayLayers {
                        guard let layerTimesBytesPerImage = checkedProduct(UInt32.self, UInt64(layer), UInt64(bytesPerImage)) else {
                            return false
                        }

                        guard let sourceOffset = checkedSum(UInt.self, dataLayoutOffset, UInt64(layerTimesBytesPerImage)) else {
                            return false
                        }
                        if sourceOffset % UInt(blockSize) != 0 {
                            skippedLayer = true
                            continue
                        }
                        guard let destinationSlice = checkedSum(UInt.self, UInt64(destination.origin.z), UInt64(layer)) else {
                            return false
                        }
                        WebGPU.Metal.replaceRegion(
                            mtlTexture,
                            region,
                            destination.mipLevel,
                            UInt64(destinationSlice),
                            source,
                            UInt64(sourceOffset),
                            UInt64(bytesPerRow),
                            0,
                            texelBlock
                        )
                    }
                case WebGPU.TextureDimension._3d:
                    if widthForMetal == 0 || heightForMetal == 0 || depthForMetal == 0 {
                        return false
                    }

                    let region = MTLRegion(
                        origin: MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: Int(destination.origin.z)),
                        size: MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: Int(depthForMetal))
                    )
                    let sourceOffset = UInt(dataLayoutOffset)
                    if sourceOffset % UInt(blockSize) != 0 {
                        skippedLayer = true
                        break
                    }
                    WebGPU.Metal.replaceRegion(
                        mtlTexture,
                        region,
                        destination.mipLevel,
                        0,
                        source,
                        UInt64(sourceOffset),
                        UInt64(bytesPerRow),
                        UInt64(bytesPerImage),
                        texelBlock
                    )
                default:
                    skippedLayer = true
                }
                if skippedLayer {
                    return false
                }
                markWritten(textureImpl, regionsWrittenInFull)
                return true
            case .gpu:
                break
            case .unsupported:
                assertionFailure()
                return false
            }
        }

        let blitCommandEncoder = ensureBlitCommandEncoder(queue)
        // FIXME(PERFORMANCE): Suballocate, so the common case doesn't need to hit the kernel.
        // FIXME(PERFORMANCE): Should this temporary buffer really be shared?
        let newBufferSize = UInt(dataByteSize) &- UInt(dataLayoutOffset)
        let noCopy = UInt64(newBufferSize) >= largeBufferSize
        var temporaryBufferOffset: UInt64 = 0
        let stagedBuffer: (any MTLBuffer)?
        if isRepacked {
            // The repacked bytes are copied, even into a buffer of their own: nothing else would keep them alive.
            stagedBuffer = newTemporaryBuffer(device, bytes: source, aliasing: nil, from: 0, noCopy, &temporaryBufferOffset)
        } else {
            stagedBuffer = newTemporaryBuffer(
                device,
                bytes: data.extracting(Int(dataLayoutOffset)..<data.count),
                aliasing: aliasable,
                from: dataLayoutOffset,
                noCopy,
                &temporaryBufferOffset
            )
        }
        guard let temporaryBuffer = stagedBuffer else {
            return false
        }
        assert(UInt(temporaryBuffer.length) >= newBufferSize)

        if let mtlTexture {
            switch texture.dimension() {
            case WebGPU.TextureDimension._1d:
                // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400771-copyfrombuffer?language=objc
                // "When you copy to a 1D texture, height and depth must be 1."
                let sourceSize = MTLSize(width: Int(widthForMetal), height: 1, depth: 1)
                if widthForMetal == 0 || heightForMetal == 0 {
                    return false
                }

                let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: 0, z: 0)

                for layer in 0..<size.depthOrArrayLayers {
                    guard let sourceOffset = checkedProduct(UInt.self, UInt64(layer), UInt64(bytesPerImage)) else {
                        return false
                    }
                    guard let destinationSlice = checkedSum(UInt.self, UInt64(destination.origin.z), UInt64(layer)) else {
                        return false
                    }
                    guard let widthTimesBlockSize = checkedProduct(UInt.self, UInt64(widthForMetal), UInt64(blockSize)) else {
                        return false
                    }
                    guard let sourceOffsetSum = checkedSum(UInt.self, UInt64(sourceOffset), UInt64(widthTimesBlockSize)) else {
                        return false
                    }
                    if sourceOffsetSum > newBufferSize || sourceOffset % UInt(blockSize) != 0 {
                        skippedLayer = true
                        continue
                    }

                    blitCommandEncoder?
                        .copy(
                            from: temporaryBuffer,
                            sourceOffset: Int(bitPattern: sourceOffset &+ UInt(temporaryBufferOffset)),
                            sourceBytesPerRow: Int(bitPattern: bytesPerRow),
                            sourceBytesPerImage: 0,
                            sourceSize: sourceSize,
                            to: mtlTexture,
                            destinationSlice: Int(bitPattern: destinationSlice),
                            destinationLevel: Int(destination.mipLevel),
                            destinationOrigin: destinationOrigin,
                            options: options
                        )
                }
            case WebGPU.TextureDimension._2d:
                // https://developer.apple.com/documentation/metal/mtlblitcommandencoder/1400771-copyfrombuffer?language=objc
                // "When you copy to a 2D texture, depth must be 1."
                let sourceSize = MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: 1)
                if widthForMetal == 0 || heightForMetal == 0
                    || (bytesPerRow != 0 && bytesPerRow < textureBytesPerRow(textureFormat, widthForMetal, texture.sampleCount()))
                {
                    return false
                }

                let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: 0)
                for layer in 0..<size.depthOrArrayLayers {
                    guard let sourceOffset = checkedProduct(UInt.self, UInt64(layer), UInt64(bytesPerImage)) else {
                        return false
                    }
                    guard let destinationSlice = checkedSum(UInt.self, UInt64(destination.origin.z), UInt64(layer)) else {
                        return false
                    }
                    if sourceOffset % UInt(blockSize) != 0 {
                        skippedLayer = true
                        continue
                    }
                    blitCommandEncoder?
                        .copy(
                            from: temporaryBuffer,
                            sourceOffset: Int(bitPattern: sourceOffset &+ UInt(temporaryBufferOffset)),
                            sourceBytesPerRow: Int(bitPattern: bytesPerRow),
                            sourceBytesPerImage: 0,
                            sourceSize: sourceSize,
                            to: mtlTexture,
                            destinationSlice: Int(bitPattern: destinationSlice),
                            destinationLevel: Int(destination.mipLevel),
                            destinationOrigin: destinationOrigin,
                            options: options
                        )
                }
            case WebGPU.TextureDimension._3d:
                let sourceSize = MTLSize(width: Int(widthForMetal), height: Int(heightForMetal), depth: Int(depthForMetal))
                let destinationOrigin = MTLOrigin(x: Int(destination.origin.x), y: Int(destination.origin.y), z: Int(destination.origin.z))
                if widthForMetal == 0 || heightForMetal == 0 || depthForMetal == 0
                    || (bytesPerRow != 0 && bytesPerRow < textureBytesPerRow(textureFormat, widthForMetal, texture.sampleCount()))
                {
                    return false
                }

                blitCommandEncoder?
                    .copy(
                        from: temporaryBuffer,
                        sourceOffset: Int(truncatingIfNeeded: temporaryBufferOffset),
                        sourceBytesPerRow: Int(bitPattern: bytesPerRow),
                        sourceBytesPerImage: Int(bitPattern: bytesPerImage),
                        sourceSize: sourceSize,
                        to: mtlTexture,
                        destinationSlice: 0,
                        destinationLevel: Int(destination.mipLevel),
                        destinationOrigin: destinationOrigin,
                        options: options
                    )
            default:
                skippedLayer = true
            }
        } else {
            skippedLayer = true
        }
        // Nothing is written without a staging blit encoder.
        if blitCommandEncoder == nil {
            skippedLayer = true
        }
        if !skippedLayer {
            markWritten(textureImpl, regionsWrittenInFull)
        }

        if noCopy {
            finalizeBlitCommandEncoder(queue)
        }
        return !skippedLayer
    }

    // MARK: copyExternalImageToTexture

    private func errorValidatingCopyExternalImageToTexture(
        _ destination: WebGPU.ImageCopyTextureTagged,
        _ copySize: WebGPU.Extent3D,
        _ texture: WebGPU.Metal.Texture,
        _ textureImpl: TextureImpl,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl
    ) -> String? {
        // https://gpuweb.github.io/gpuweb/#abstract-opdef-validating-gpuimagecopytexturetagged
        func errorString(_ error: String) -> String {
            "GPUQueue.copyExternalImageToTexture: \(error)"
        }
        if !isValidToUse(texture.isValid(), textureImpl.deviceImpl, deviceImpl) {
            return errorString("destination texture is not valid")
        }

        let texelCopyDestination = untaggedDestination(destination)

        if let error = WebGPU.Metal.Texture.errorValidatingImageCopyTexture(texelCopyDestination, copySize) {
            return errorString(error)
        }

        if let error = WebGPU.Metal.Texture.errorValidatingTextureCopyRange(texelCopyDestination, copySize) {
            return errorString(error)
        }

        if copySize.depthOrArrayLayers > 1 {
            return errorString("copySize.depthOrArrayLayers is greater than 1")
        }

        if destination.aspect != WebGPU.TextureAspect.All {
            return errorString("destination aspect is not All")
        }

        if texture.dimension() != WebGPU.TextureDimension._2d {
            return errorString("destination texture dimension is not 2D")
        }

        if texture.sampleCount() != 1 {
            return errorString("destination texture sampleCount is not 1")
        }

        if !texture.usage().contains(WebGPU.TextureUsage.CopyDestination) {
            return errorString("destination texture usage does not contain CopyDst")
        }

        // The copy is performed by rendering into the destination, which is why the spec asks for this on
        // top of CopyDst.
        if !texture.usage().contains(WebGPU.TextureUsage.RenderAttachment) {
            return errorString("destination texture usage does not contain RenderAttachment")
        }

        if !isValidCopyExternalImageDestinationFormat(texture.format(), device) {
            return errorString("destination texture format cannot be a copyExternalImageToTexture destination")
        }

        return nil
    }

    @_expose(Cxx)
    func copyExternalImageToTexture(
        _ queue: WebGPU.Metal.Queue,
        _ device: WebGPU.Metal.Device,
        _ deviceImpl: DeviceImpl,
        _ textureImpl: TextureImpl,
        _ source: WebGPU.Metal.CopyExternalImageSource,
        _ ioSurface: IOSurfaceRef?,
        _ pixelBuffer: CVPixelBuffer?,
        _ destination: WebGPU.ImageCopyTextureTagged,
        _ copySize: WebGPU.Extent3D
    ) {
        // https://gpuweb.github.io/gpuweb/#dom-gpuqueue-copyexternalimagetotexture
        let texture = WebGPU.Metal.metal(destination.texture)
        if texture.isDestroyed() {
            deviceImpl.generateAValidationError("GPUQueue.copyExternalImageToTexture: destination texture is destroyed")
            return
        }

        if let error = errorValidatingCopyExternalImageToTexture(destination, copySize, texture, textureImpl, device, deviceImpl) {
            deviceImpl.generateAValidationError(error)
            return
        }

        if ioSurface == nil && pixelBuffer == nil {
            deviceImpl.generateAValidationError("GPUQueue.copyExternalImageToTexture: source image is not valid")
            return
        }

        // errorValidatingTextureCopyRange() has already rejected a copy reaching past the destination mip
        // level, so this only ever clamps away an empty copy.
        let logicalSize = texture.logicalMiplevelSpecificTextureExtent(destination.mipLevel)
        let widthForMetal = logicalSize.width < destination.origin.x ? 0 : min(copySize.width, logicalSize.width - destination.origin.x)
        let heightForMetal = logicalSize.height < destination.origin.y ? 0 : min(copySize.height, logicalSize.height - destination.origin.y)
        if widthForMetal == 0 || heightForMetal == 0 {
            return
        }

        let destinationFormat = texture.format()
        guard let pipelineState = copyExternalImagePipelineState(deviceImpl, texturePixelFormat(destinationFormat)) else {
            return
        }

        var flags: UInt32 = 0
        var sourceWidth: UInt32 = 0
        var sourceHeight: UInt32 = 0
        var sourceTexture: (any MTLTexture)?
        // The chroma plane of a decoded video frame, or a swizzled view of a single-plane frame's own
        // texture. Bound by the IOSurface path below too, which never reads it, because Metal validates
        // every texture the fragment function declares.
        var sourceSecondPlaneTexture: (any MTLTexture)?
        var uvRemapMatrix = identityUVRemapMatrix
        var ycbcrMatrix = [Float](repeating: 0, count: 12)
        var sourcePrimaries: CopyExternalImageSourcePrimaries = isDisplayP3(source.colorSpace) ? .displayP3 : .srgb

        if let pixelBuffer {
            // The frame's planes are wrapped in MTLTextures exactly the way importExternalTexture() wraps
            // them, so a video reaches the destination without its pixels ever leaving the GPU.
            let frame = deviceImpl.externalTextureImporter.importPixelBuffer(
                device,
                deviceImpl,
                pixelBuffer,
                source.colorSpace,
                premultiplyAlpha: false
            )
            sourceTexture = frame.texture0
            sourceSecondPlaneTexture = frame.texture1
            if sourceTexture == nil || sourceSecondPlaneTexture == nil {
                return
            }

            // The frame's clean aperture, which is both the extent script sees and the extent the crop
            // matrix normalizes against, rather than the larger extent the planes may be coded at.
            let cleanSize = CVImageBufferGetCleanRect(pixelBuffer).size
            sourceWidth = truncatedUInt32(cleanSize.width)
            sourceHeight = truncatedUInt32(cleanSize.height)
            // A quarter turn presents the frame's extent transposed, and both the copy's coordinates and
            // the origin script asked to copy from are in the presented image.
            if source.pixelBufferRotation == WebGPU.VideoFrameRotation.Right || source.pixelBufferRotation == WebGPU.VideoFrameRotation.Left
            {
                swap(&sourceWidth, &sourceHeight)
            }
            if sourceWidth == 0 || sourceHeight == 0 {
                return
            }

            // Sampling happens in the presented image's coordinates, so undo the display transform before
            // the frame's own crop, which is expressed in its stored coordinates. Both are affine, so
            // composing them here costs the shader nothing.
            uvRemapMatrix = concatenatedAffineTransforms(
                floats(frame.constants.uvRemapping),
                inverseDisplayTransformMatrix(source.pixelBufferRotation, source.pixelBufferIsMirrored)
            )
            ycbcrMatrix = floats(frame.constants.colorSpaceConversion)
            // A frame's primaries are its own, and are usually neither of the two the caller can name.
            sourcePrimaries = sourcePrimariesForPixelBuffer(pixelBuffer)
            flags |= CopyExternalImageFlags.sourceIsVideoFrame
        } else if let ioSurface {
            let surfaceWidth = UInt32(truncatingIfNeeded: IOSurfaceGetWidth(ioSurface))
            let surfaceHeight = UInt32(truncatingIfNeeded: IOSurfaceGetHeight(ioSurface))
            // The surface can be larger than the image it backs, so the reachable extent is the smaller of
            // the two. Nothing past it may be read: it is either padding or another image's pixels.
            sourceWidth = min(surfaceWidth, source.sourceSize.width)
            sourceHeight = min(surfaceHeight, source.sourceSize.height)
            if sourceWidth == 0 || sourceHeight == 0 {
                return
            }

            guard let sourceFormat = Optional(fromCxx: source.sourceFormat) else {
                return
            }
            let sourcePixelFormat = texturePixelFormat(sourceFormat)
            if sourcePixelFormat == .invalid {
                return
            }

            let sourceTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: sourcePixelFormat,
                width: Int(surfaceWidth),
                height: Int(surfaceHeight),
                mipmapped: false
            )
            sourceTextureDescriptor.usage = .shaderRead
            sourceTextureDescriptor.storageMode = copyExternalImageSourceStorageMode(deviceImpl)
            sourceTexture = deviceImpl.newTextureWithDescriptor(sourceTextureDescriptor, ioSurface, 0)
            if sourceTexture == nil {
                return
            }
            sourceSecondPlaneTexture = sourceTexture
        }

        if source.flipY {
            flags |= CopyExternalImageFlags.flipY
        }
        if !source.hasAlpha {
            flags |= CopyExternalImageFlags.forceOpaqueAlpha
        }

        let colorMatrix = colorMatrixBetweenPrimaries(sourcePrimaries, isDisplayP3(destination.colorSpace))
        let primariesDiffer = colorMatrix != identityColorMatrix
        let transferFunctionsDiffer = isLinear(source.colorSpace) != isLinear(destination.colorSpace)
        let convertsColor = primariesDiffer || transferFunctionsDiffer
        if convertsColor {
            // Primaries are converted in linear light, so the source is decoded and the destination
            // re-encoded around the matrix. Either step is skipped when that end is already linear.
            if !isLinear(source.colorSpace) {
                flags |= CopyExternalImageFlags.decodeSourceTransferFunction
            }
            if !isLinear(destination.colorSpace) {
                flags |= CopyExternalImageFlags.encodeDestinationTransferFunction
            }
        }

        // Only unpremultiply when something downstream needs unpremultiplied values: a color conversion,
        // or an unpremultiplied destination. Two premultiplied ends with no conversion is a passthrough.
        if source.premultipliedAlpha && (convertsColor || !destination.premultipliedAlpha) {
            flags |= CopyExternalImageFlags.unpremultiplySource
        }
        if destination.premultipliedAlpha && (convertsColor || !source.premultipliedAlpha) {
            flags |= CopyExternalImageFlags.premultiplyDestination
        }

        if removeSRGBSuffix(destinationFormat) != destinationFormat {
            flags |= CopyExternalImageFlags.cancelSRGBDestinationEncoding
        }

        // A 2D destination, per the validation above, so origin.z is an array layer and never a depth
        // plane, and errorValidatingTextureCopyRange() has bounded it.
        let destinationSlice = destination.origin.z

        // Marked once the copy has been encoded.
        var regionsWrittenInFull: [InitRegion] = []
        let writesAll = writeWillCompletelyClear(
            WebGPU.TextureDimension._2d,
            widthForMetal,
            logicalSize.width,
            heightForMetal,
            logicalSize.height,
            1,
            logicalSize.depthOrArrayLayers
        )
        for region in textureImpl.initRegions(mipLevel: destination.mipLevel, layer: destinationSlice, aspect: .All)
        where !textureImpl.isInitialized(region) {
            if writesAll {
                regionsWrittenInFull.append(region)
            } else {
                guard stageZeroFill(queue, device, textureImpl, region) else {
                    return
                }
            }
        }

        // The clear above, if there was one, is encoded on the queue's staging command buffer. The render
        // pass has to follow it on that same buffer, which means closing whichever encoder is open on it.
        _ = ensureBlitCommandEncoder(queue)
        guard let commandBuffer = backingStagingCommandBuffer else {
            return
        }
        endStagingEncoders(queue)

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture.texture()
        renderPassDescriptor.colorAttachments[0].level = Int(destination.mipLevel)
        renderPassDescriptor.colorAttachments[0].slice = Int(destinationSlice)
        // The copy may cover only part of the level, and the rest has to survive it.
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderCommandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            // The clear is real work already encoded on this command buffer, and finalizeBlitCommandEncoder()
            // keys off the encoders, so leaving it here would orphan it. Commit instead.
            finalizeBlitCommandEncoder(queue)
            return
        }
        setEncoderForBuffer(queue, commandBuffer, renderCommandEncoder)

        var arguments = WebGPU.Metal.CopyExternalImageArguments()
        arguments.sourceOriginX = source.origin.x
        arguments.sourceOriginY = source.origin.y
        arguments.destinationOriginX = destination.origin.x
        arguments.destinationOriginY = destination.origin.y
        arguments.copyWidth = widthForMetal
        arguments.copyHeight = heightForMetal
        arguments.sourceMaxX = sourceWidth &- 1
        arguments.sourceMaxY = sourceHeight &- 1
        arguments.flags = flags
        arguments.colorMatrix = tuple9(colorMatrix)
        arguments.uvRemapMatrix = tuple6(uvRemapMatrix)
        arguments.ycbcrMatrix = tuple12(ycbcrMatrix)

        // The viewport is what confines the full-NDC quad to the destination rectangle, and it is also
        // what makes [[position]] in the fragment shader land on the destination texel being written.
        let viewport = MTLViewport(
            originX: Double(destination.origin.x),
            originY: Double(destination.origin.y),
            width: Double(widthForMetal),
            height: Double(heightForMetal),
            znear: 0,
            zfar: 1
        )

        renderCommandEncoder.setRenderPipelineState(pipelineState)
        renderCommandEncoder.setViewport(viewport)
        renderCommandEncoder.setFragmentTexture(sourceTexture, index: 0)
        renderCommandEncoder.setFragmentTexture(sourceSecondPlaneTexture, index: 1)
        WebGPU.Metal.Queue.setCopyExternalImageArguments(renderCommandEncoder, arguments)
        renderCommandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        endEncoding(queue, renderCommandEncoder, commandBuffer)
        markWritten(textureImpl, regionsWrittenInFull)
        // ensureBlitCommandEncoder() would otherwise mint a fresh staging buffer over this one, because it
        // keys off the blit and staged-copy encoders, both of which are nil now. Commit while it can.
        finalizeBlitCommandEncoder(queue)
    }
}

@_expose(Cxx)
func makeQueueImpl(_ commandQueue: (any MTLCommandQueue)?) -> QueueImpl {
    QueueImpl(commandQueue: commandQueue, allocatesBookkeeping: true)
}

@_expose(Cxx)
func makeInvalidQueueImpl() -> QueueImpl {
    QueueImpl(commandQueue: nil, allocatesBookkeeping: false)
}

// A frame carries primaries of its own, which are usually neither of the two color spaces WebGPU names, so both
// importExternalTexture() and copyExternalImageToTexture() have to convert them. Row-major and applied to linear-light
// values; nil when the frame's primaries already are the destination's, which has to stay a no-op rather than a
// transfer function round trip.
func pixelBufferPrimariesConversionMatrix(_ pixelBuffer: CVPixelBuffer?, _ destination: WebGPU.PredefinedColorSpace) -> [Float]? {
    let result = colorMatrixBetweenPrimaries(sourcePrimariesForPixelBuffer(pixelBuffer), isDisplayP3(destination))
    return result == identityColorMatrix ? nil : result
}

// MARK: Shader sources. The Metal argument structs mirror CopyExternalImageArguments (Queue.h) and
// StagedCopyArguments (Queue.mm).

private let stagedCopyShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct WebKitStagedCopyArgs {
        ulong sourceWordOffset;
        ulong destinationWordOffset;
        ulong wordCount;
    };
    [[kernel]] void csStagedBufferCopy(device const uint* source [[buffer(0)]], device uint* destination [[buffer(1)]], constant WebKitStagedCopyArgs& args [[buffer(2)]], uint threadIndex [[thread_position_in_grid]], uint threadsPerGrid [[threads_per_grid]])
    {
        for (ulong i = threadIndex; i < args.wordCount; i += threadsPerGrid)
            destination[args.destinationWordOffset + i] = source[args.sourceWordOffset + i];
    }
    """

private let copyExternalImageShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct WebKitCopyExternalImageArgs {
        uint sourceOriginX;
        uint sourceOriginY;
        uint destinationOriginX;
        uint destinationOriginY;
        uint copyWidth;
        uint copyHeight;
        uint sourceMaxX;
        uint sourceMaxY;
        uint flags;
        float colorMatrix[9];
        float uvRemapMatrix[6];
        float ycbcrMatrix[12];
    };
    constant uint webKitCopyExternalImageFlipY = 1;
    constant uint webKitCopyExternalImageForceOpaqueAlpha = 2;
    constant uint webKitCopyExternalImageUnpremultiplySource = 4;
    constant uint webKitCopyExternalImagePremultiplyDestination = 8;
    constant uint webKitCopyExternalImageDecodeSourceTransferFunction = 16;
    constant uint webKitCopyExternalImageEncodeDestinationTransferFunction = 32;
    constant uint webKitCopyExternalImageCancelSRGBDestinationEncoding = 64;
    constant uint webKitCopyExternalImageSourceIsVideoFrame = 128;
    // A frame's chroma plane is half resolution, so it has to be filtered rather than read, and the crop
    // the coordinates go through can leave them just outside the plane at the edges.
    constexpr sampler webKitCopyExternalImageFrameSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // Sign-preserving, so that the out-of-[0, 1] values an rgba16float surface can hold survive.
    float3 webKitSRGBToLinear(float3 encoded)
    {
        float3 magnitude = abs(encoded);
        return sign(encoded) * select(pow((magnitude + 0.055f) / 1.055f, 2.4f), magnitude / 12.92f, magnitude <= 0.04045f);
    }
    float3 webKitLinearToSRGB(float3 linearLight)
    {
        float3 magnitude = abs(linearLight);
        return sign(linearLight) * select(1.055f * pow(magnitude, 1.f / 2.4f) - 0.055f, magnitude * 12.92f, magnitude <= 0.0031308f);
    }
    struct WebKitCopyExternalImageVertexOut {
        float4 position [[position]];
    };
    [[vertex]] WebKitCopyExternalImageVertexOut vsCopyExternalImage(uint vertexID [[vertex_id]])
    {
        // A triangle strip covering all of NDC. The viewport is what restricts rasterization to the
        // destination rectangle, so the vertex stage needs none of the copy parameters.
        WebKitCopyExternalImageVertexOut out;
        out.position = float4((vertexID & 1) ? 1.f : -1.f, (vertexID & 2) ? 1.f : -1.f, 0.f, 1.f);
        return out;
    }
    [[fragment]] float4 fsCopyExternalImage(WebKitCopyExternalImageVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]], texture2d<float> sourceSecondPlane [[texture(1)]], constant WebKitCopyExternalImageArgs& args [[buffer(0)]])
    {
        uint2 copyPosition = uint2(in.position.xy) - uint2(args.destinationOriginX, args.destinationOriginY);
        uint sourceY = (args.flags & webKitCopyExternalImageFlipY) ? (args.copyHeight - 1 - copyPosition.y) : copyPosition.y;
        // Clamped because a caller-supplied rectangle reaching past the end of the source must read the
        // edge rather than whatever the surface's padding holds.
        uint2 sourcePosition = min(uint2(args.sourceOriginX + copyPosition.x, args.sourceOriginY + sourceY), uint2(args.sourceMaxX, args.sourceMaxY));
        float4 color;
        if (args.flags & webKitCopyExternalImageSourceIsVideoFrame) {
            // A decoded frame's two planes, sampled the way textureSampleBaseClampToEdge samples an
            // external texture: the frame's own crop applied to normalized coordinates, then out of its
            // YCbCr space. A single-plane frame arrives as a swizzled view of the first plane paired with
            // the identity matrix, so both kinds of frame take this one path.
            float2 frameCoordinates = (float2(sourcePosition) + 0.5f) / float2(args.sourceMaxX + 1, args.sourceMaxY + 1);
            float2 croppedCoordinates = float2(
                args.uvRemapMatrix[0] * frameCoordinates.x + args.uvRemapMatrix[2] * frameCoordinates.y + args.uvRemapMatrix[4],
                args.uvRemapMatrix[1] * frameCoordinates.x + args.uvRemapMatrix[3] * frameCoordinates.y + args.uvRemapMatrix[5]);
            float3 ycbcr = float3(source.sample(webKitCopyExternalImageFrameSampler, croppedCoordinates).r, sourceSecondPlane.sample(webKitCopyExternalImageFrameSampler, croppedCoordinates).rg);
            // Column-major, matching how the host flattened it, and affine: the fourth column is added.
            color = float4(
                args.ycbcrMatrix[0] * ycbcr.x + args.ycbcrMatrix[3] * ycbcr.y + args.ycbcrMatrix[6] * ycbcr.z + args.ycbcrMatrix[9],
                args.ycbcrMatrix[1] * ycbcr.x + args.ycbcrMatrix[4] * ycbcr.y + args.ycbcrMatrix[7] * ycbcr.z + args.ycbcrMatrix[10],
                args.ycbcrMatrix[2] * ycbcr.x + args.ycbcrMatrix[5] * ycbcr.y + args.ycbcrMatrix[8] * ycbcr.z + args.ycbcrMatrix[11],
                1.f);
        } else {
            // One source texel per destination texel, so read() rather than sample(): no filtering, and no
            // sampler state to get wrong.
            color = source.read(sourcePosition);
        }
        if (args.flags & webKitCopyExternalImageForceOpaqueAlpha)
            color.a = 1.f;
        if ((args.flags & webKitCopyExternalImageUnpremultiplySource) && color.a > 0.f)
            color.rgb /= color.a;
        if (args.flags & webKitCopyExternalImageDecodeSourceTransferFunction)
            color.rgb = webKitSRGBToLinear(color.rgb);
        // Explicit dot products, so that the host's row-major storage order is unambiguous. The matrix is
        // the identity when the source and destination share primaries, which leaves the values alone.
        float3 rgb = color.rgb;
        color.r = args.colorMatrix[0] * rgb.r + args.colorMatrix[1] * rgb.g + args.colorMatrix[2] * rgb.b;
        color.g = args.colorMatrix[3] * rgb.r + args.colorMatrix[4] * rgb.g + args.colorMatrix[5] * rgb.b;
        color.b = args.colorMatrix[6] * rgb.r + args.colorMatrix[7] * rgb.g + args.colorMatrix[8] * rgb.b;
        if (args.flags & webKitCopyExternalImageEncodeDestinationTransferFunction)
            color.rgb = webKitLinearToSRGB(color.rgb);
        if (args.flags & webKitCopyExternalImagePremultiplyDestination)
            color.rgb *= color.a;
        // Metal applies the sRGB transfer function on the way into an _sRGB attachment. Undo it here, so
        // that the texels stored are the ones writeTexture would have stored for the same copy.
        if (args.flags & webKitCopyExternalImageCancelSRGBDestinationEncoding)
            color.rgb = webKitSRGBToLinear(color.rgb);
        return color;
    }
    """
