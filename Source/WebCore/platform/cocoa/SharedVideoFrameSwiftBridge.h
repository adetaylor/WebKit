/*
 * Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

#include <cstdint>

// CoreVideo's own typedef chain. Swift treats a CVPixelBufferRef as CoreVideo's CVPixelBuffer only when the
// declarations it sees match it; `typedef struct __CVBuffer* CVPixelBufferRef` makes it a distinct class.
typedef struct __CVBuffer* CVBufferRef;
typedef CVBufferRef CVImageBufferRef;
typedef CVImageBufferRef CVPixelBufferRef;
typedef struct __CVPixelBufferPool* CVPixelBufferPoolRef;

namespace WebCore {

// The fields of a SharedVideoFrameInfo, in their encoding order.
struct SharedVideoFrameLayout {
    uint32_t bufferType { 0 };
    uint32_t width { 0 };
    uint32_t height { 0 };
    uint32_t bytesPerRow { 0 };
    uint32_t widthPlaneB { 0 };
    uint32_t heightPlaneB { 0 };
    uint32_t bytesPerRowPlaneB { 0 };
    uint32_t bytesPerRowPlaneAlpha { 0 };
};

enum class SharedVideoFrameWriteResult : uint8_t {
    Success,
    LockFailed,
    NotReadable,
    PlaneANull,
    PlaneBNull,
    PlaneAlphaNull,
    StorageTooSmall,
};

} // namespace WebCore
