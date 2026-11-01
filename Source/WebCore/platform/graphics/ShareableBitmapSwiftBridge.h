/*
 * Copyright (C) 2010-2026 Apple Inc. All rights reserved.
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

#include <WebCore/PixelFormat.h>
#include <cstddef>
#include <cstdint>

namespace WebCore {

// A CheckedUint32 as plain data: the value the C++ Checked holds, and whether it has overflowed.
struct ShareableBitmapCheckedSize {
    uint32_t value;
    bool hasOverflowed;
};

// What a ShareableBitmapConfiguration constructor gives the layout calculation. pixelFormat is used only when
// hasPixelFormat is set, and colorSpaceUsesExtendedRange only when it isn't. bytesPerRowAlignment is the IOSurface
// row alignment where there are IOSurfaces.
struct ShareableBitmapLayoutRequest {
    int width;
    PixelFormat pixelFormat;
    bool hasPixelFormat;
    bool colorSpaceUsesExtendedRange;
    bool isOpaque;
    size_t bytesPerRowAlignment;
};

// The fields of a ShareableBitmapConfiguration that the layout calculation derives. bitmapInfo is a CGBitmapInfo,
// and 0 without CG.
struct ShareableBitmapLayout {
    PixelFormat pixelFormat;
    uint32_t bitsPerComponent;
    uint32_t bytesPerPixel;
    ShareableBitmapCheckedSize bytesPerRow;
    uint32_t bitmapInfo;
};

// The fields of a ShareableBitmapConfiguration that its byte size depends on.
struct ShareableBitmapGeometry {
    int width;
    int height;
    ShareableBitmapCheckedSize bytesPerRow;
};

enum class ShareableBitmapImagePixels : uint8_t {
    Copyable,
    Unusable,
    SizeMismatch,
};

} // namespace WebCore
