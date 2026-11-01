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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/ColorSpace.h>
#include <WebCore/FloatSize.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/IntRect.h>
#include <WebCore/IntSize.h>
#include <WebCore/PixelBuffer.h>
#include <WebCore/PixelBufferFormat.h>
#include <WebCore/RenderingMode.h>
#include <wtf/RefPtr.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

class ImageBufferAllocator;

// The optional references FilterImageImpl stores and returns. Swift can't safely store or return an Optional of a
// foreign reference type, whose nil is a null reference.
using RefPtrImageBuffer = RefPtr<ImageBuffer>;
using RefPtrPixelBuffer = RefPtr<PixelBuffer>;

// The allocator of a filter's images, which each FilterImageImpl stores and passes to the functions below. It isn't a
// reference count: the FilterResults that owns the allocator keeps it for as long as it makes images with it. Swift
// can't read it.
class SWIFT_SAFE FilterImageAllocator {
public:
#if !defined(__swift__)
    explicit FilterImageAllocator(ImageBufferAllocator& allocator)
        : m_allocator(&allocator)
    {
    }

    ImageBufferAllocator& allocator() const { return *m_allocator; }
#endif

private:
    ImageBufferAllocator* m_allocator;
};

// What FilterImageImpl needs from C++: its allocator, and the ImageBuffer operations Swift can't call itself.
namespace FilterGraphicsBridge {

// Null if the allocator fails.
RefPtr<PixelBuffer> createPixelBuffer(const FilterImageAllocator&, const PixelBufferFormat&, const IntSize&);
RefPtr<ImageBuffer> createImageBuffer(const FilterImageAllocator&, const FloatSize&, const ColorSpace&, RenderingMode);
RefPtr<PixelBuffer> getPixelBuffer(const ImageBuffer&, const PixelBufferFormat&, const IntRect& sourceRect, const FilterImageAllocator&);
void putPixelBuffer(ImageBuffer&, const PixelBuffer&, const IntRect& sourceRect);

// PixelBuffer::size(), format() and bytes() return a reference or a span, which Swift can't use safely.
inline IntSize size(const PixelBuffer& pixelBuffer) { return pixelBuffer.size(); }
inline PixelBufferFormat format(const PixelBuffer& pixelBuffer) { return pixelBuffer.format(); }
inline size_t byteCount(const PixelBuffer& pixelBuffer) { return pixelBuffer.bytes().size(); }
inline bool isSamePixelBuffer(const PixelBuffer& a, const PixelBuffer& b) { return &a == &b; }

} // namespace FilterGraphicsBridge

} // namespace WebCore
