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

#if ENABLE_WEBCORE_SWIFT && USE_ACCELERATE && USE_CG

import Accelerate
import CoreGraphics
import WebCore_Internal.ColorSpace
import WebCore_Internal.PixelBufferFormat
import WebCore_Internal.PixelBufferSwiftBridge
import WebCore_Internal.PixelFormat
import Synchronization
import os

// The vImage calls of PixelConversion.swift. Each one runs over buffers from withVImageBuffers().

private let imagesLog = os.Logger(subsystem: "com.apple.WebKit", category: "Images")

// Out of line, so that the conversions don't set up a Logger on every call.
@inline(never)
private func logConverterCreationError(_ error: vImage_Error) {
    imagesLog.error("convertImagePixelsAcceleratedAnyToAny: vImageConverter_CreateWithCGImageFormat() failed with error: \(error)")
}

@inline(never)
private func logConversionError(_ error: vImage_Error) {
    imagesLog.error("convertImagePixelsAcceleratedAnyToAny: vImageConvert_AnyToAny() failed with error: \(error)")
}

private let noFlags = vImage_Flags(kvImageNoFlags)

// The vImage premultiply and unpremultiply functions for a pixel format with alpha. The ones for 8-bit components
// work with any order that has alpha last: vImagePremultiplyData_BGRA8888() is vImagePremultiplyData_RGBA8888().
enum VImageAlphaLayout {
    case alphaLast8888
    #if ENABLE_PIXEL_FORMAT_RGBA16F
    case rgba16F
    #endif
    #if ENABLE_PIXEL_FORMAT_RGBA16
    case rgba16U
    #endif
}

// Copies the color components of an opaque source in the same or swapped order, and sets every alpha to 255.
@inline(__always)
func vImagePermuteInsertingOpaqueAlpha(
    source: Span<UInt8>?,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationGeometry: VImageGeometry,
    swapComponentOrder: Bool
) {
    // 0x8 is the first of the four channels, 0x1 the last.
    let lastChannelMask: UInt8 = 0x1
    let map: SIMD4<UInt8> = swapComponentOrder ? SIMD4(2, 1, 0, 3) : SIMD4(0, 1, 2, 3)
    unsafe withVImageBuffers(source: source, sourceGeometry, destination: &destination, destinationGeometry) { source, destination in
        unsafe withVImageBytes(map) { map in
            unsafe withVImageBytes(SIMD4(0, 0, 0, 255)) { opaqueAlpha in
                _ = unsafe vImagePermuteChannelsWithMaskedInsert_ARGB8888(&source, &destination, map, lastChannelMask, opaqueAlpha, noFlags)
            }
        }
    }
}

@inline(__always)
func vImageConvertAlpha(
    _ layout: VImageAlphaLayout,
    unpremultiply: Bool,
    source: Span<UInt8>?,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationGeometry: VImageGeometry
) {
    unsafe withVImageBuffers(source: source, sourceGeometry, destination: &destination, destinationGeometry) { source, destination in
        switch (layout, unpremultiply) {
        case (.alphaLast8888, true):
            _ = unsafe vImageUnpremultiplyData_RGBA8888(&source, &destination, noFlags)
        case (.alphaLast8888, false):
            _ = unsafe vImagePremultiplyData_RGBA8888(&source, &destination, noFlags)
        #if ENABLE_PIXEL_FORMAT_RGBA16F
        case (.rgba16F, true):
            _ = unsafe vImageUnpremultiplyData_RGBA16F(&source, &destination, noFlags)
        case (.rgba16F, false):
            _ = unsafe vImagePremultiplyData_RGBA16F(&source, &destination, noFlags)
        #endif
        #if ENABLE_PIXEL_FORMAT_RGBA16
        case (.rgba16U, true):
            _ = unsafe vImageUnpremultiplyData_RGBA16U(&source, &destination, noFlags)
        case (.rgba16U, false):
            _ = unsafe vImagePremultiplyData_RGBA16U(&source, &destination, noFlags)
        #endif
        }
    }
}

// Swaps the first and third components of 8-bit pixels.
@inline(__always)
func vImageSwapFirstAndThirdComponents(
    source: Span<UInt8>?,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationGeometry: VImageGeometry
) {
    unsafe withVImageBuffers(source: source, sourceGeometry, destination: &destination, destinationGeometry) { source, destination in
        unsafe withVImageBytes(SIMD4(2, 1, 0, 3)) { map in
            _ = unsafe vImagePermuteChannels_ARGB8888(&source, &destination, map, noFlags)
        }
    }
}

// A vImage_CGImageFormat, holding its color space.
private struct VImageConverterFormat {
    let bitsPerComponent: UInt32
    let bitsPerPixel: UInt32
    let bitmapInfo: CGBitmapInfo
    let colorSpace: CGColorSpace

    init(_ format: borrowing WebCore.PixelBufferFormat) {
        let premultiplied = format.alphaFormat == .Premultiplied
        let (bitsPerComponent, bitsPerPixel, byteOrder, alphaInfo): (UInt32, UInt32, UInt32, CGImageAlphaInfo) =
            switch format.pixelFormat {
            case .RGBX8:
                (8, 32, CGImageByteOrderInfo.order32Big.rawValue, .noneSkipLast)
            case .RGBA8:
                (8, 32, CGImageByteOrderInfo.order32Big.rawValue, premultiplied ? .premultipliedLast : .last)
            case .BGRX8:
                (8, 32, CGImageByteOrderInfo.order32Little.rawValue, .noneSkipFirst)
            case .BGRA8:
                (8, 32, CGImageByteOrderInfo.order32Little.rawValue, premultiplied ? .premultipliedFirst : .first)
            #if ENABLE_PIXEL_FORMAT_RGBA16F
            case .RGBA16F:
                (
                    16, 64, CGImageByteOrderInfo.order16Host.rawValue | CGBitmapInfo.floatComponents.rawValue,
                    premultiplied ? .premultipliedLast : .last
                )
            #endif
            #if ENABLE_PIXEL_FORMAT_RGBA16
            case .RGBA16:
                (16, 64, CGImageByteOrderInfo.order16Little.rawValue, premultiplied ? .premultipliedLast : .last)
            #endif
            default:
                // We do not support conversions to or from the 10-bit-per-component formats.
                (8, 32, CGImageByteOrderInfo.order32Little.rawValue, .first)
            }
        self.bitsPerComponent = bitsPerComponent
        self.bitsPerPixel = bitsPerPixel
        self.bitmapInfo = CGBitmapInfo(rawValue: byteOrder | alphaInfo.rawValue)
        self.colorSpace = WebCore.platformColorSpace(format.colorSpace)
    }

    func isSameFormat(as other: VImageConverterFormat) -> Bool {
        bitsPerComponent == other.bitsPerComponent && bitsPerPixel == other.bitsPerPixel && bitmapInfo == other.bitmapInfo
            && colorSpace === other.colorSpace
    }
}

private struct CachedVImageConverter {
    let source: VImageConverterFormat
    let destination: VImageConverterFormat
    let converter: vImageConverter
}

// vImage documents that one converter may be used concurrently from multiple threads, and color spaces are immutable.
extension CachedVImageConverter: @unsafe @unchecked Sendable {
}

// Creating a converter takes tens of microseconds for a color space conversion, so the most recently used ones are kept,
// most recent first.
private let cachedVImageConverters = Mutex<[CachedVImageConverter]>([])
private let maximumCachedVImageConverters = 8

private func vImageConverter(from source: VImageConverterFormat, to destination: VImageConverterFormat) -> vImageConverter? {
    let cached = cachedVImageConverters.withLock { converters -> CachedVImageConverter? in
        guard
            let index = converters.firstIndex(where: { $0.source.isSameFormat(as: source) && $0.destination.isSameFormat(as: destination) })
        else {
            return nil
        }
        let converter = converters.remove(at: index)
        converters.insert(converter, at: 0)
        return converter
    }
    if let cached {
        return cached.converter
    }

    var sourceCGImageFormat = unsafe vImage_CGImageFormat(
        bitsPerComponent: source.bitsPerComponent,
        bitsPerPixel: source.bitsPerPixel,
        colorSpace: Unmanaged.passUnretained(source.colorSpace),
        bitmapInfo: source.bitmapInfo,
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )
    var destinationCGImageFormat = unsafe vImage_CGImageFormat(
        bitsPerComponent: destination.bitsPerComponent,
        bitsPerPixel: destination.bitsPerPixel,
        colorSpace: Unmanaged.passUnretained(destination.colorSpace),
        bitmapInfo: destination.bitmapInfo,
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )
    var error = kvImageNoError
    let converter = unsafe vImageConverter_CreateWithCGImageFormat(
        &sourceCGImageFormat,
        &destinationCGImageFormat,
        nil,
        noFlags,
        &error
    )?
    .takeRetainedValue()
    guard error == kvImageNoError, let converter else {
        logConverterCreationError(error)
        return nil
    }
    cachedVImageConverters.withLock { converters in
        converters.insert(CachedVImageConverter(source: source, destination: destination, converter: converter), at: 0)
        if converters.count > maximumCachedVImageConverters {
            converters.removeLast()
        }
    }
    return converter
}

// Converts between color spaces and component sizes. False if vImage fails.
func vImageConvertAnyToAny(
    source: Span<UInt8>?,
    _ sourceFormat: borrowing WebCore.PixelBufferFormat,
    _ sourceGeometry: VImageGeometry,
    destination: inout MutableSpan<UInt8>,
    _ destinationFormat: borrowing WebCore.PixelBufferFormat,
    _ destinationGeometry: VImageGeometry
) -> Bool {
    // FIXME: Consider using vImageConvert_AnyToAny for all conversions, not just ones that need a color space
    // or component size conversion, after judiciously performance testing them against each other.
    guard let converter = vImageConverter(from: VImageConverterFormat(sourceFormat), to: VImageConverterFormat(destinationFormat)) else {
        return false
    }
    let error = unsafe withVImageBuffers(source: source, sourceGeometry, destination: &destination, destinationGeometry) {
        source,
        destination in
        unsafe vImageConvert_AnyToAny(converter, &source, &destination, nil, noFlags)
    }
    guard error == kvImageNoError else {
        logConversionError(error)
        return false
    }
    return true
}

#endif // ENABLE_WEBCORE_SWIFT && USE_ACCELERATE && USE_CG
