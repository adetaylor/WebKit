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

/*
 * Copyright (C) 2023-2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <wtf/Platform.h>

#if PLATFORM(MAC)

#include <CoreGraphics/CoreGraphics.h>
#include <WebCore/StyleAppearance.h>
#include <cstdint>
#include <utility>
#include <wtf/SwiftBridging.h>

namespace WebCore {

// A control's ControlStyle and its part's values, as plain values.
struct MacControlState {
    StyleAppearance appearance { StyleAppearance::None };

    bool isPressed { false };
    bool isFocused { false };
    bool isEnabled { false };
    bool isChecked { false };
    bool isWindowActive { false };
    bool isIndeterminate { false };
    bool isSpinUp { false };
    bool isPresenting { false };
    bool isInFormSemanticContext { false };
    bool usesDarkAppearance { false };
    bool isInlineFlipped { false };
    bool usesLargeControls { false };
    bool isReadOnly { false };
    bool hasListButton { false };
    bool isListButtonPressed { false };
    bool isVertical { false };

    float fontSize { 12 };
    float zoomFactor { 1 };
    float borderTop { 0 };
    float borderRight { 0 };
    float borderBottom { 0 };
    float borderLeft { 0 };

    // MeterPart.
    double meterValue { 0 };
    double meterMinimum { 0 };
    double meterMaximum { 0 };
    uint8_t meterGaugeRegion { 0 };

    // ProgressBarPart, and the time the progress bar is drawn at.
    double progressPosition { 0 };
    double progressAnimationStartTime { 0 };
    double progressAnimationTime { 0 };

    // SwitchPart.
    bool switchIsOn { false };
    float switchProgress { 0 };

    // For draw(): whether cells draw without a view (only in the GPU process), and the context's clip bounds, which
    // bound the focus ring of a cell drawn in a view.
    bool drawsViewlessCells { false };
    CGRect focusRingClipRect { };

    // For draw() of the menu list button: the context's fill rule, which its glyph fills with.
    bool fillsEvenOdd { false };

    // For draw(): the drawing that makeLayer() is filling, and the layers of this drawing.
    bool fillsLayer { false };
    uintptr_t layers { 0 };
};

// The options of MacControlPainter::drawLayer().
struct MacControlLayerDrawing {
    float x { 0 };
    float y { 0 };
    bool setsAlpha { false };
    float alpha { 1 };
    bool isPlusLighter { false };
    bool isRotatedHalfTurn { false };
};

// The Mac controls' AppKit cells, one set per ControlFactoryMac, and their drawing. MacControlPainter.swift implements
// the members it doesn't define; PlatformControlMac calls them with each control's state.
class SWIFT_PRIVATE_FILEID("WebCore/MacControlPainter.swift") MacControlPainter {
public:
    MacControlPainter() = default;
    ~MacControlPainter();
    MacControlPainter(MacControlPainter&& other)
        : m_swiftState(std::exchange(other.m_swiftState, 0))
    {
    }
    MacControlPainter& operator=(MacControlPainter&&) = delete;

    void updateCellStates(CGRect bounds, MacControlState);
    CGSize sizeForBounds(CGRect bounds, MacControlState);
    CGRect rectForBounds(CGRect bounds, MacControlState);
    // accentColor is an NSColor.
    void draw(CGContextRef, CGRect borderRect, float deviceScaleFactor, MacControlState, CFTypeRef accentColor, CGColorRef textColor, CGColorRef focusRingColor);
    CGSize servicesRolloverButtonCellSize();

    // What draw() can't do on a CGContext: the image buffers that the context it draws into makes, and that context's
    // GraphicsContext clips and focus ring. `layers` is MacControlState's. A layer is a nonzero index.

    // Makes an image buffer with the destination's GraphicsContext, and fills it by calling draw() with its context.
    static uint8_t makeLayer(uintptr_t layers, float width, float height, float scale);
    // Draws a layer into the context being drawn into, and releases it.
    static void drawLayer(uintptr_t layers, uint8_t layer, MacControlLayerDrawing);
    static void clipToLayer(uintptr_t layers, uint8_t layer, CGRect);
    static void clipToRoundedRect(uintptr_t layers, CGRect, float radius);
    static void drawFocusRing(uintptr_t layers, CGRect, float zoomFactor);

private:
    static void destroySwiftState(uintptr_t);

    uintptr_t m_swiftState { 0 };
};

} // namespace WebCore

#endif // PLATFORM(MAC)
