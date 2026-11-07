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
#include <algorithm>
#include <optional>
#include <span>

namespace WebKit {

class RemoteCGRendererResources;

// The style of RemoteCGRenderer's SetStyle, which goes as RemoteGraphicsContext's does, for Swift, which can't switch on
// GraphicsStyle's variant.
class RemoteCGRendererStyle {
public:
    enum class Kind : uint8_t { None, DropShadow, GaussianBlur, ColorMatrix };

    explicit RemoteCGRendererStyle(const std::optional<WebCore::GraphicsStyle>& style)
        : m_style(style)
    {
    }

    const std::optional<WebCore::GraphicsStyle>& style() const LIFETIME_BOUND __attribute__((availability(swift, unavailable))) { return m_style; }

    Kind kind() const
    {
        if (!m_style)
            return Kind::None;
        return WTF::switchOn(*m_style,
            [](const WebCore::GraphicsDropShadow&) { return Kind::DropShadow; },
            [](const WebCore::GraphicsGaussianBlur&) { return Kind::GaussianBlur; },
            [](const WebCore::GraphicsColorMatrix&) { return Kind::ColorMatrix; });
    }
    const WebCore::GraphicsDropShadow* dropShadow() const __attribute__((availability(swift, unavailable))) { return m_style ? std::get_if<WebCore::GraphicsDropShadow>(&*m_style) : nullptr; }
    WebCore::FloatSize gaussianBlurRadius() const
    {
        auto* blur = m_style ? std::get_if<WebCore::GraphicsGaussianBlur>(&*m_style) : nullptr;
        return blur ? blur->radius : WebCore::FloatSize { };
    }
#if HAVE(CGSTYLE_COLORMATRIX_BLUR)
    CGRendererColorMatrix colorMatrix() const
    {
        CGRendererColorMatrix values { };
        if (auto* matrix = m_style ? std::get_if<WebCore::GraphicsColorMatrix>(&*m_style) : nullptr)
            std::ranges::copy(matrix->values, std::span { values.values }.begin());
        return values;
    }
#endif

private:
    std::optional<WebCore::GraphicsStyle> m_style;
};

// copyShadow() of the style's drop shadow.
CGColorRef _Nullable copyStyleShadow(const RemoteCGRendererResources&, const RemoteCGRendererStyle&, CGRendererShadowValues&, CGRendererColorData&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
