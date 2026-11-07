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

class RemoteCGRendererResources;

// The shadow of RemoteCGRenderer's SetDropShadow, which goes as RemoteGraphicsContext's does.
class RemoteCGRendererShadow {
public:
    explicit RemoteCGRendererShadow(const std::optional<WebCore::GraphicsDropShadow>& shadow)
        : m_shadow(shadow)
    {
    }

    const std::optional<WebCore::GraphicsDropShadow>& shadow() const LIFETIME_BOUND __attribute__((availability(swift, unavailable))) { return m_shadow; }
    bool hasShadow() const { return !!m_shadow; }

private:
    std::optional<WebCore::GraphicsDropShadow> m_shadow;
};

// What the renderer takes of the shadow, as GraphicsContextCG converts one for the receiver's context, with the CGColor,
// which this returns, of a valid color that isn't sRGBA8. A function, since Swift takes what a C++ method returns as
// unretained whatever its annotation.
CGColorRef _Nullable copyShadow(const RemoteCGRendererResources&, const RemoteCGRendererShadow&, CGRendererShadowValues&, CGRendererColorData&) CF_RETURNS_RETAINED;

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
