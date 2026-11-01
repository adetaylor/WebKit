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

#include <WebCore/FilterEffectView.h>
#include <WebCore/FilterSwiftBridge.h>
#include <cstdint>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

class SVGFilterRenderer;

// An SVGFilterRenderer lent to WebCore's Swift for one apply: its expression and effects, and what its effects need from
// it. Swift can't keep it.
class SWIFT_VIEW SWIFT_SAFE SVGFilterRendererView {
public:
#if !defined(__swift__)
    explicit SVGFilterRendererView(const SVGFilterRenderer&);
#endif
    SVGFilterRendererView(const SVGFilterRendererView&);
    ~SVGFilterRendererView();

    // Identifies the renderer to FilterResults. Swift only compares it.
    uintptr_t identifier() const;
    FilterRendererParameters parameters() const;

    FilterEffectView effect(unsigned index) const LIFETIME_BOUND;

    unsigned termCount() const;
    unsigned termEffectIndex(unsigned term) const;
    FilterEffectGeometryValues termGeometry(unsigned term) const;

private:
    const Ref<const SVGFilterRenderer> m_renderer;
};

} // namespace WebCore
