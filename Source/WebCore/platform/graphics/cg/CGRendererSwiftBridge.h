/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

// The values GraphicsContextCG passes to CGRenderer.swift.

#include <CoreGraphics/CoreGraphics.h>
#include <span>
#include <stdint.h>
#include <wtf/SwiftBridging.h>

// A GraphicsDropShadow, with its color passed separately when it isn't sRGBA8.
struct CGRendererShadowValues {
    float width;
    float height;
    float radius;
    float opacity;
    uint32_t packedColor;
    bool isValid;
    bool isVisible;
};

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
struct CGRendererColorMatrix {
    float values[20];
};
#endif

// Rects lent to CGRenderer.swift for one call.
class SWIFT_NONESCAPABLE SWIFT_SAFE CGRendererRects {
public:
    explicit CGRendererRects(std::span<const CGRect> rects LIFETIME_BOUND)
        : m_rects(rects)
    {
    }

    size_t size() const { return m_rects.size(); }
    CGRect at(size_t index) const { return m_rects[index]; }

private:
    std::span<const CGRect> m_rects;
};
