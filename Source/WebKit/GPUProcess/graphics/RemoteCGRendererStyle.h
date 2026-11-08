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

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "RemoteCGRendererShadow.h"
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/GraphicsStyle.h>
#include <algorithm>
#include <array>
#include <optional>
#include <span>

namespace WebKit {

enum class RemoteCGRendererStyleKind : uint8_t { None, DropShadow, GaussianBlur, ColorMatrix };

// The style of RemoteCGRenderer's SetStyle, as plain values (rendererStyle()), for Swift, which can't switch on
// GraphicsStyle's variant.
struct RemoteCGRendererStyle {
    RemoteCGRendererStyleKind kind;
    RemoteCGRendererShadow dropShadow;
    float blurWidth;
    float blurHeight;
    std::array<float, 20> colorMatrix;
};

__attribute__((availability(swift, unavailable))) inline RemoteCGRendererStyle rendererStyle(const std::optional<WebCore::GraphicsStyle>& style)
{
    RemoteCGRendererStyle result { };
    if (!style)
        return result;
    WTF::switchOn(*style,
        [&](const WebCore::GraphicsDropShadow& shadow) {
            result.kind = RemoteCGRendererStyleKind::DropShadow;
            result.dropShadow = rendererShadow(shadow);
        },
        [&](const WebCore::GraphicsGaussianBlur& blur) {
            result.kind = RemoteCGRendererStyleKind::GaussianBlur;
            result.blurWidth = blur.radius.width();
            result.blurHeight = blur.radius.height();
        },
        [&](const WebCore::GraphicsColorMatrix& matrix) {
            result.kind = RemoteCGRendererStyleKind::ColorMatrix;
            result.colorMatrix = matrix.values;
        });
    return result;
}

__attribute__((availability(swift, unavailable))) inline std::optional<WebCore::GraphicsStyle> styleFrom(const RemoteCGRendererStyle& style)
{
    switch (style.kind) {
    case RemoteCGRendererStyleKind::None:
        return std::nullopt;
    case RemoteCGRendererStyleKind::DropShadow:
        return WebCore::GraphicsStyle { CGRendererDropShadowFromValues(style.dropShadow.values, style.dropShadow.color) };
    case RemoteCGRendererStyleKind::GaussianBlur:
        return WebCore::GraphicsStyle { WebCore::GraphicsGaussianBlur { { style.blurWidth, style.blurHeight } } };
    case RemoteCGRendererStyleKind::ColorMatrix:
        return WebCore::GraphicsStyle { WebCore::GraphicsColorMatrix { style.colorMatrix } };
    }
    RELEASE_ASSERT_NOT_REACHED();
}

#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
inline CGRendererColorMatrix colorMatrix(RemoteCGRendererStyle style)
{
    CGRendererColorMatrix values { };
    std::ranges::copy(style.colorMatrix, std::span { values.values }.begin());
    return values;
}
#endif

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
