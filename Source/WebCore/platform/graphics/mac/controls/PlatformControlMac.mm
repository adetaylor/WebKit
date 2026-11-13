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

#import "config.h"
#import "PlatformControlMac.h"

#if PLATFORM(MAC)

#import "ColorCocoa.h"
#import "ControlFactoryMac.h"
#import "FloatRoundedRect.h"
#import "GraphicsContext.h"
#import "ImageBuffer.h"
#import "LocalDefaultSystemAppearance.h"
#import "MacControlPainter.h"
#import "MeterPart.h"
#import "NativeImage.h"
#import "ProgressBarPart.h"
#import "SliderTrackPart.h"
#import "SwitchPart.h"
#import <pal/spi/mac/NSCellSPI.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RuntimeApplicationChecks.h>
#import <wtf/SetForScope.h>
#import <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(PlatformControlMac);

// The contexts and image buffers of one PlatformControlMac::draw(), which MacControlState::layers points to.
struct MacControlLayers {
    MacControlPainter& painter;
    float deviceScaleFactor;
    Vector<GraphicsContext*, 4> contexts;
    Vector<RefPtr<ImageBuffer>, 8> imageBuffers;

    GraphicsContext& destination() const { return *contexts.first(); }
    GraphicsContext& current() const { return *contexts.last(); }

    static MacControlLayers& from(uintptr_t layers) { return *reinterpret_cast<MacControlLayers*>(layers); }

    RefPtr<ImageBuffer> imageBuffer(uint8_t layer) const
    {
        if (!layer || layer > imageBuffers.size())
            return nullptr;
        return imageBuffers[layer - 1];
    }
};

static bool drawsViewlessCells()
{
    static std::optional<bool> drawsViewlessCells;
    if (!drawsViewlessCells) {
        // FIXME: rdar://105249508 - Remove the GPUP check when the viewless focus ring an be drawn without a problem.
#if ENABLE(GPU_PROCESS)
        drawsViewlessCells = isInGPUProcess() && [NSCell instancesRespondToSelector:@selector(_setFallbackBackingScaleFactor:)];
#else
        drawsViewlessCells = [NSCell instancesRespondToSelector:@selector(_setFallbackBackingScaleFactor:)];
#endif
    }
    return *drawsViewlessCells;
}

PlatformControlMac::PlatformControlMac(ControlPart& owningPart, ControlFactoryMac& controlFactory)
    : PlatformControl(owningPart)
    , m_controlFactory(controlFactory)
{
}

PlatformControlMac::~PlatformControlMac() = default;

MacControlState PlatformControlMac::state(const ControlStyle& style) const
{
    auto part = m_owningPart.get();
    auto& states = style.states;

    MacControlState state;
    state.appearance = part->type();
    state.isPressed = states.contains(ControlStyle::State::Pressed);
    state.isFocused = states.contains(ControlStyle::State::Focused);
    state.isEnabled = states.contains(ControlStyle::State::Enabled);
    state.isChecked = states.contains(ControlStyle::State::Checked);
    state.isWindowActive = states.contains(ControlStyle::State::WindowActive);
    state.isIndeterminate = states.contains(ControlStyle::State::Indeterminate);
    state.isSpinUp = states.contains(ControlStyle::State::SpinUp);
    state.isPresenting = states.contains(ControlStyle::State::Presenting);
    state.isInFormSemanticContext = states.contains(ControlStyle::State::FormSemanticContext);
    state.usesDarkAppearance = states.contains(ControlStyle::State::DarkAppearance);
    state.isInlineFlipped = states.contains(ControlStyle::State::InlineFlippedWritingMode);
    state.usesLargeControls = states.contains(ControlStyle::State::LargeControls);
    state.isReadOnly = states.contains(ControlStyle::State::ReadOnly);
    state.hasListButton = states.contains(ControlStyle::State::ListButton);
    state.isListButtonPressed = states.contains(ControlStyle::State::ListButtonPressed);
    state.isVertical = states.contains(ControlStyle::State::VerticalWritingMode);
    state.fontSize = style.fontSize;
    state.zoomFactor = style.zoomFactor;
    state.borderTop = style.borderWidth.top();
    state.borderRight = style.borderWidth.right();
    state.borderBottom = style.borderWidth.bottom();
    state.borderLeft = style.borderWidth.left();

    if (RefPtr meter = dynamicDowncast<MeterPart>(part)) {
        state.meterValue = meter->value();
        state.meterMinimum = meter->minimum();
        state.meterMaximum = meter->maximum();
        state.meterGaugeRegion = static_cast<uint8_t>(meter->gaugeRegion());
    } else if (RefPtr progressBar = dynamicDowncast<ProgressBarPart>(part)) {
        state.progressPosition = progressBar->position();
        state.progressAnimationStartTime = progressBar->animationStartTime().seconds();
    } else if (RefPtr switchPart = dynamicDowncast<SwitchPart>(part)) {
        state.switchIsOn = switchPart->isOn();
        state.switchProgress = switchPart->progress();
    }
    return state;
}

void PlatformControlMac::setFocusRingClipRect(const FloatRect& clipBounds)
{
    m_focusRingClipRect = clipBounds;
}

void PlatformControlMac::updateCellStates(const FloatRect& bounds, const ControlStyle& style)
{
    m_controlFactory->painter().updateCellStates(bounds, state(style));
}

FloatSize PlatformControlMac::sizeForBounds(const FloatRect& bounds, const ControlStyle& style) const
{
    return FloatSize { m_controlFactory->painter().sizeForBounds(bounds, state(style)) };
}

FloatRect PlatformControlMac::rectForBounds(const FloatRect& bounds, const ControlStyle& style) const
{
    return FloatRect { m_controlFactory->painter().rectForBounds(bounds, state(style)) };
}

void PlatformControlMac::draw(GraphicsContext& context, const FloatRoundedRect& borderRect, float deviceScaleFactor, const ControlStyle& style)
{
    auto state = this->state(style);
    if (state.appearance == StyleAppearance::SliderHorizontal || state.appearance == StyleAppearance::SliderVertical) {
        auto part = m_owningPart.get();
        downcast<SliderTrackPart>(part).drawTicks(context, borderRect.rect(), style);
    }
    if (state.appearance == StyleAppearance::ProgressBar)
        state.progressAnimationTime = MonotonicTime::now().secondsSinceEpoch().seconds();
    state.drawsViewlessCells = drawsViewlessCells();
    state.focusRingClipRect = m_focusRingClipRect;

    RetainPtr<NSColor> accentColor;
    if (style.accentColor.isValid())
        accentColor = cocoaColor(style.accentColor);

    RetainPtr<CGColorRef> textColor;
    if (state.appearance == StyleAppearance::MenulistButton) {
        textColor = cachedCGColorInDestinationStandardRange(style.textColor, context.colorSpace());
        state.fillsEvenOdd = context.fillRule() == WindRule::EvenOdd;
    }

    // The color of a cell's focus ring, in the appearance the cell draws in.
    RetainPtr<CGColorRef> focusRingColor;
    if (state.isFocused) {
        LocalDefaultSystemAppearance localAppearance(state.usesDarkAppearance, style.accentColor);
        focusRingColor = cachedCGColor(colorFromCocoaColor([NSColor keyboardFocusIndicatorColor]).opaqueColor());
    }

    auto& painter = m_controlFactory->painter();
    MacControlLayers layers { painter, deviceScaleFactor, { &context }, { } };
    state.layers = reinterpret_cast<uintptr_t>(&layers);
    painter.draw(context.platformContext(), borderRect.rect(), deviceScaleFactor, state, (__bridge CFTypeRef)accentColor.get(), textColor.get(), focusRingColor.get());
}

MacControlPainter::~MacControlPainter()
{
    if (m_swiftState)
        destroySwiftState(m_swiftState);
}

uint8_t MacControlPainter::makeLayer(uintptr_t layersPointer, float width, float height, float scale)
{
    auto& layers = MacControlLayers::from(layersPointer);
    RefPtr imageBuffer = layers.destination().createImageBuffer(FloatSize { width, height }, scale);
    if (!imageBuffer || layers.imageBuffers.size() >= std::numeric_limits<uint8_t>::max())
        return 0;

    auto& context = imageBuffer->context();
    layers.contexts.append(&context);
    MacControlState state;
    state.fillsLayer = true;
    state.layers = layersPointer;
    layers.painter.draw(context.platformContext(), { }, layers.deviceScaleFactor, state, nullptr, nullptr, nullptr);
    layers.contexts.removeLast();

    layers.imageBuffers.append(WTF::move(imageBuffer));
    return layers.imageBuffers.size();
}

void MacControlPainter::drawLayer(uintptr_t layersPointer, uint8_t layer, MacControlLayerDrawing drawing)
{
    auto& layers = MacControlLayers::from(layersPointer);
    RefPtr imageBuffer = layers.imageBuffer(layer);
    if (!imageBuffer)
        return;
    layers.imageBuffers[layer - 1] = nullptr;

    auto& context = layers.current();
    if (drawing.setsAlpha)
        context.setAlpha(drawing.alpha);

    auto destination = FloatPoint { drawing.x, drawing.y };
    if (drawing.isPlusLighter)
        context.drawConsumingImageBuffer(WTF::move(imageBuffer), destination, RasterDrawingOptions { CompositeOperator::PlusLighter });
    else if (drawing.isRotatedHalfTurn)
        context.drawConsumingImageBuffer(WTF::move(imageBuffer), destination, RasterDrawingOptions { ImageOrientation::Orientation::OriginBottomRight });
    else if (drawing.setsAlpha)
        context.drawConsumingImageBuffer(WTF::move(imageBuffer), destination, RasterDrawingOptions { CompositeOperator::SourceOver });
    else
        context.drawConsumingImageBuffer(WTF::move(imageBuffer), destination);
}

void MacControlPainter::clipToLayer(uintptr_t layersPointer, uint8_t layer, CGRect rect)
{
    auto& layers = MacControlLayers::from(layersPointer);
    RefPtr imageBuffer = layers.imageBuffer(layer);
    if (!imageBuffer)
        return;
    // The layer is not drawn to after it is made.
    if (RefPtr image = imageBuffer->createNativeImageReference())
        layers.current().clipToNativeImage(*image, rect);
}

void MacControlPainter::clipToRoundedRect(uintptr_t layersPointer, CGRect rect, float radius)
{
    MacControlLayers::from(layersPointer).current().clipRoundedRect(FloatRoundedRect(rect, CornerRadii(radius)));
}

void MacControlPainter::drawFocusRing(uintptr_t layersPointer, CGRect rect, float zoomFactor)
{
    auto color = colorFromCocoaColor([NSColor keyboardFocusIndicatorColor]).opaqueColor();
    MacControlLayers::from(layersPointer).current().drawFocusRing(Vector { FloatRect { rect } }, 0, color, zoomFactor);
}

} // namespace WebCore

#endif // PLATFORM(MAC)
