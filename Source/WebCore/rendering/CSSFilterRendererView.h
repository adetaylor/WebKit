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
#include <WebCore/SVGFilterRendererView.h>
#include <cstdint>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>

namespace WebCore {

class CSSFilterRenderer;

// What a function of a CSS filter is, for applying it: an effect, a referenced SVG filter, or neither (it applies
// nothing, and the filter fails).
enum class CSSFilterFunctionKind : uint8_t {
    Effect,
    SVGFilter,
    Other
};

// A CSSFilterRenderer lent to WebCore's Swift for one apply: its functions, and what its effects need from it. Swift can't
// keep it.
class SWIFT_VIEW SWIFT_SAFE CSSFilterRendererView {
public:
#if !defined(__swift__)
    explicit CSSFilterRendererView(const CSSFilterRenderer&);
#endif
    CSSFilterRendererView(const CSSFilterRendererView&);
    ~CSSFilterRendererView();

    // Identifies the renderer to FilterResults. Swift only compares it.
    uintptr_t identifier() const;
    FilterRendererParameters parameters() const;

    unsigned functionCount() const;
    CSSFilterFunctionKind functionKind(unsigned index) const;
    FilterEffectView effect(unsigned index) const LIFETIME_BOUND;
    SVGFilterRendererView svgFilter(unsigned index) const LIFETIME_BOUND;

private:
    const Ref<const CSSFilterRenderer> m_renderer;
};

} // namespace WebCore
