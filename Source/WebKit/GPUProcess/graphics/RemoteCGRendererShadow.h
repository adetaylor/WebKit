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

#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/GraphicsStyle.h>
#include <optional>

namespace WebKit {

// The shadow of RemoteCGRenderer's SetDropShadow, as plain values: what the renderer takes of it, and its color's data,
// which gives back the same shadow (CGRendererShadowValuesOf()). hasShadow is false for none.
struct RemoteCGRendererShadow {
    CGRendererShadowValues values;
    CGRendererColorData color;
    bool hasShadow;
};

__attribute__((availability(swift, unavailable))) inline RemoteCGRendererShadow rendererShadow(const std::optional<WebCore::GraphicsDropShadow>& shadow)
{
    RemoteCGRendererShadow result { };
    if (shadow) {
        result.hasShadow = true;
        CGRendererShadowValuesOf(*shadow, result.values, result.color);
    }
    return result;
}

__attribute__((availability(swift, unavailable))) inline std::optional<WebCore::GraphicsDropShadow> dropShadowFrom(const RemoteCGRendererShadow& shadow)
{
    if (!shadow.hasShadow)
        return std::nullopt;
    return CGRendererDropShadowFromValues(shadow.values, shadow.color);
}

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
