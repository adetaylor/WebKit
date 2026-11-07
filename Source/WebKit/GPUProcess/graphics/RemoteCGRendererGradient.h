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

#include <WebCore/AffineTransform.h>
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/Gradient.h>
#include <wtf/Ref.h>

namespace WebKit {

// The gradient of RemoteCGRenderer's gradient messages, which goes as RemoteGraphicsContext's Ref<Gradient> does.
class RemoteCGRendererGradient {
public:
    explicit RemoteCGRendererGradient(Ref<WebCore::Gradient>&& gradient)
        : m_gradient(WTF::move(gradient))
    {
    }

    const Ref<WebCore::Gradient>& gradient() const LIFETIME_BOUND __attribute__((availability(swift, unavailable))) { return m_gradient; }

    // The gradient as a brush, with the space transform (SourceBrush::setGradient()).
    CGRendererBrushSource brushSource(const WebCore::AffineTransform& spaceTransform) const { return CGRendererBrushSource { m_gradient.copyRef(), spaceTransform }; }

private:
    Ref<WebCore::Gradient> m_gradient;
};

} // namespace WebKit

#endif // ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
