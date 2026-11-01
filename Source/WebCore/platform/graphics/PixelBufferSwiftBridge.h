/*
 * Copyright (C) 2021-2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/AlphaPremultiplication.h>
#include <WebCore/ColorSpace.h>
#include <WebCore/IntPoint.h>
#include <WebCore/IntRect.h>
#include <WebCore/IntSize.h>
#include <WebCore/PixelBuffer.h>
#include <WebCore/PixelFormat.h>
#include <span>
#include <wtf/Compiler.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

// Pixel bytes C++ lends to Swift for one call. Swift reads them with no `unsafe`, as long as it spells
// the type: `let bytes: Span<UInt8> = view.span()`.
struct SWIFT_VIEW PixelBytes {
    std::span<const uint8_t> bytes;

    std::span<const uint8_t> span() const LIFETIME_BOUND { return bytes; }
};

// Writable pixel bytes C++ lends to Swift for one call, as an `inout` parameter:
// `var bytes: MutableSpan<UInt8> = view.mutableSpan()`. Swift assumes that no other view passed in the
// same call covers the same memory.
struct SWIFT_VIEW MutablePixelBytes {
    std::span<uint8_t> bytes;

    std::span<uint8_t> mutableSpan() LIFETIME_BOUND { return bytes; }
};

// The bytes of a PixelBuffer that Swift holds. The Ref keeps them alive while any span from it is in use.
class SWIFT_SELF_CONTAINED PixelBufferAccess {
public:
    explicit PixelBufferAccess(PixelBuffer& buffer)
        : m_buffer(buffer)
    {
    }

    std::span<const uint8_t> span() const LIFETIME_BOUND { return m_buffer->bytes(); }
    std::span<uint8_t> mutableSpan() LIFETIME_BOUND { return m_buffer->bytes(); }

private:
    Ref<PixelBuffer> m_buffer;
};

#if USE(CG)
// ColorSpace::platformColorSpace() isn't available in Swift: it returns a pointer that the ColorSpace owns. Swift
// retains the result when it receives it.
CF_RETURNS_NOT_RETAINED inline CGColorSpaceRef platformColorSpace(const ColorSpace& colorSpace)
{
    return colorSpace.platformColorSpace();
}
#endif

// The parts of a PixelBufferFormat that pixel loops need, without the color space.
struct PixelConversionFormat {
    PixelFormat pixelFormat;
    AlphaPremultiplication alphaFormat;
};

// An ImageBufferBackend pixel transfer (PixelTransfer.swift) before any clipping: the requested source rect, the
// backend's size and stride, and for a put, the pixel buffer's size and where the source rect goes in the backend.
// Plain integers, because Swift can only read an IntRect through out-of-line calls.
struct PixelTransferGeometry {
    int sourceX;
    int sourceY;
    int sourceWidth;
    int sourceHeight;
    int destinationX;
    int destinationY;
    int pixelBufferWidth;
    int pixelBufferHeight;
    int backendWidth;
    int backendHeight;
    unsigned backendBytesPerRow;
};

} // namespace WebCore
