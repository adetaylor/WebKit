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

#if ENABLE(IPC_TESTING_API)

#include "IPCConnectionTesterIdentifier.h"
#include "SharedPreferencesForWebProcess.h"
#include <optional>
#include <wtf/Markable.h>
#include <wtf/OptionSet.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Variant.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#if PLATFORM(COCOA)
#include <CoreGraphics/CoreGraphics.h>
#include <WebCore/ColorSpace.h>
#include <WebCore/ControlPart.h>
#include <WebCore/CSSFilterRenderer.h>
#include <WebCore/ControlStyle.h>
#include <WebCore/DistantLightSource.h>
#include <WebCore/FEBlend.h>
#include <WebCore/FEColorMatrix.h>
#include <WebCore/FEComponentTransfer.h>
#include <WebCore/FEComposite.h>
#include <WebCore/FEConvolveMatrix.h>
#include <WebCore/FEDiffuseLighting.h>
#include <WebCore/FEDisplacementMap.h>
#include <WebCore/FEDropShadow.h>
#include <WebCore/FEFlood.h>
#include <WebCore/FEGaussianBlur.h>
#include <WebCore/FEImage.h>
#include <WebCore/FEMerge.h>
#include <WebCore/FEMorphology.h>
#include <WebCore/FEOffset.h>
#include <WebCore/FESpecularLighting.h>
#include <WebCore/FETile.h>
#include <WebCore/FETurbulence.h>
#include <WebCore/PointLightSource.h>
#include <WebCore/SVGFilterRenderer.h>
#include <WebCore/SourceAlpha.h>
#include <WebCore/SourceGraphic.h>
#include <WebCore/SpotLightSource.h>
#include <WebCore/MeterPart.h>
#include <WebCore/ProgressBarPart.h>
#include <WebCore/SliderTrackPart.h>
#include <WebCore/SwitchPart.h>
#include <WebCore/SystemImage.h>
#if ENABLE(APPLE_PAY)
#include <WebCore/ApplePayButtonPart.h>
#include <WebCore/ApplePayLogoSystemImage.h>
#endif
#if USE(APPKIT)
#include <WebCore/AppKitControlSystemImage.h>
#endif
#include <wtf/RetainPtr.h>
#include <wtf/cf/VectorCF.h>
#include <wtf/text/StringHash.h>
#if ENABLE(IPC_TESTING_SWIFT)
#include "SwiftCoding.h"
#endif
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include <WebCore/AffineTransform.h>
#include <WebCore/CGRendererSwiftBridge.h>
#include <WebCore/Path.h>
#include <WebCore/PathCG.h>
#include <WebCore/WindRule.h>
#endif
#endif

namespace WebKit {

// Types that IPCTester sends to IPCTesterReceiver to check that its Swift receiver decodes and
// encodes them exactly as C++ does, whether it takes them as C++ types or as Swift types.

enum class IPCTesterColor : uint8_t {
    Red,
    Green,
    Blue,
};

enum class IPCTesterFlag : uint8_t {
    First = 1 << 0,
    Second = 1 << 1,
    Third = 1 << 2,
};

enum class IPCTesterChoice : bool {
    No,
    Yes,
};

struct IPCTesterInner {
    int32_t value { 0 };
    String label;

    friend bool operator==(const IPCTesterInner&, const IPCTesterInner&) = default;
};

using IPCTesterVariant = Variant<uint64_t, String, IPCTesterInner>;

struct IPCTesterPayload {
    bool flag { false };
    uint8_t u8 { 0 };
    uint16_t u16 { 0 };
    uint32_t u32 { 0 };
    uint64_t u64 { 0 };
    int8_t i8 { 0 };
    int16_t i16 { 0 };
    int32_t i32 { 0 };
    int64_t i64 { 0 };
    float f { 0 };
    double d { 0 };
    String text { };
    String nullText { };
    Vector<uint32_t> numbers { };
    Vector<String> strings { };
    std::optional<IPCTesterColor> color { };
    OptionSet<IPCTesterFlag> flags { };
    IPCTesterChoice choice { IPCTesterChoice::No };
    IPCTesterInner inner { };
    Vector<IPCTesterInner> inners { };
    IPCTesterVariant variant { };
    Markable<IPCConnectionTesterIdentifier> identifier { };

    friend bool operator==(const IPCTesterPayload&, const IPCTesterPayload&) = default;
};

class IPCTesterNode final : public RefCounted<IPCTesterNode> {
public:
    static Ref<IPCTesterNode> create(String&& name, Vector<Ref<IPCTesterNode>>&& children)
    {
        return adoptRef(*new IPCTesterNode(WTF::move(name), WTF::move(children)));
    }

    const String& name() const { return m_name; }
    const Vector<Ref<IPCTesterNode>>& children() const { return m_children; }

private:
    IPCTesterNode(String&& name, Vector<Ref<IPCTesterNode>>&& children)
        : m_name(WTF::move(name))
        , m_children(WTF::move(children))
    {
    }

    String m_name;
    Vector<Ref<IPCTesterNode>> m_children;
};

// The preferences IPCTesterReceiver checks the EnabledBy of its messages against.
inline std::optional<SharedPreferencesForWebProcess> ipcTesterSharedPreferences()
{
    SharedPreferencesForWebProcess preferences;
    preferences.allowTestOnlyIPC = true;
    return preferences;
}

// What IPCTesterReceiver replies, which its Swift (IPCTesterReceiver.swift) and C++ implementations
// compute identically. Each changes every field, so that a field decoded or encoded in the wrong place
// shows up even though it went through both a decoder and an encoder.

inline String ipcTesterExclaimed(const String& string)
{
    return string.isNull() ? String() : makeString(string, '!');
}

inline IPCTesterInner ipcTesterTransformed(const IPCTesterInner& inner)
{
    return { static_cast<int32_t>(0u - static_cast<uint32_t>(inner.value)), ipcTesterExclaimed(inner.label) };
}

inline IPCTesterPayload ipcTesterTransformed(const IPCTesterPayload& payload)
{
    IPCTesterPayload result = payload;
    result.flag = !payload.flag;
    result.u8 = payload.u8 + 1;
    result.u16 = payload.u16 + 1;
    result.u32 = payload.u32 + 1;
    result.u64 = payload.u64 + 1;
    result.i8 = static_cast<int8_t>(static_cast<uint8_t>(payload.i8) - 1);
    result.i16 = static_cast<int16_t>(static_cast<uint16_t>(payload.i16) - 1);
    result.i32 = static_cast<int32_t>(static_cast<uint32_t>(payload.i32) - 1);
    result.i64 = static_cast<int64_t>(static_cast<uint64_t>(payload.i64) - 1);
    result.f = payload.f * 2;
    result.d = payload.d * 2;
    result.text = ipcTesterExclaimed(payload.text);
    result.numbers.reverse();
    result.strings.reverse();
    if (payload.color)
        result.color = *payload.color == IPCTesterColor::Red ? IPCTesterColor::Green : *payload.color == IPCTesterColor::Green ? IPCTesterColor::Blue : IPCTesterColor::Red;
    result.flags = payload.flags ^ OptionSet<IPCTesterFlag> { IPCTesterFlag::First, IPCTesterFlag::Second, IPCTesterFlag::Third };
    result.choice = payload.choice == IPCTesterChoice::Yes ? IPCTesterChoice::No : IPCTesterChoice::Yes;
    result.inner = ipcTesterTransformed(payload.inner);
    result.inners = payload.inners.map([](auto& inner) {
        return ipcTesterTransformed(inner);
    });
    result.variant = WTF::switchOn(payload.variant, [](uint64_t value) -> IPCTesterVariant {
        return value + 1;
    }, [](const String& value) -> IPCTesterVariant {
        return ipcTesterExclaimed(value);
    }, [](const IPCTesterInner& value) -> IPCTesterVariant {
        return ipcTesterTransformed(value);
    });
    return result;
}

inline Ref<IPCTesterNode> ipcTesterMirrored(const IPCTesterNode& node)
{
    auto children = node.children().map([](auto& child) {
        return ipcTesterMirrored(child);
    });
    children.reverse();
    return IPCTesterNode::create(ipcTesterExclaimed(node.name()), WTF::move(children));
}

inline uint32_t ipcTesterNodeCount(const IPCTesterNode& node)
{
    uint32_t count = 1;
    for (auto& child : node.children())
        count += ipcTesterNodeCount(child);
    return count;
}

inline String ipcTesterDescription(IPCTesterColor color, OptionSet<IPCTesterFlag> flags, IPCTesterChoice choice, IPCConnectionTesterIdentifier identifier, const IPCTesterVariant& variant, bool flag)
{
    auto describeString = [](const String& string) -> String {
        return string.isNull() ? "null"_s : string;
    };
    StringBuilder builder;
    builder.append("color="_s, color == IPCTesterColor::Red ? "red"_s : color == IPCTesterColor::Green ? "green"_s : "blue"_s);
    builder.append(" flags="_s);
    if (flags.isEmpty())
        builder.append("none"_s);
    bool needsSeparator = false;
    for (auto [value, name] : { std::pair { IPCTesterFlag::First, "first"_s }, std::pair { IPCTesterFlag::Second, "second"_s }, std::pair { IPCTesterFlag::Third, "third"_s } }) {
        if (!flags.contains(value))
            continue;
        if (needsSeparator)
            builder.append('|');
        builder.append(name);
        needsSeparator = true;
    }
    builder.append(" choice="_s, choice == IPCTesterChoice::Yes ? "yes"_s : "no"_s);
    builder.append(" identifier="_s, identifier.toUInt64());
    builder.append(" variant="_s);
    WTF::switchOn(variant, [&](uint64_t value) {
        builder.append("uint64:"_s, value);
    }, [&](const String& value) {
        builder.append("string:"_s, describeString(value));
    }, [&](const IPCTesterInner& value) {
        builder.append("inner:"_s, value.value, ':', describeString(value.label));
    });
    builder.append(" flag="_s, flag ? "true"_s : "false"_s);
    return builder.toString();
}

#if PLATFORM(COCOA)
// What CoreGraphics knows of a color space, which IPCTesterReceiver replies for a ColorSpace decoded in C++ and in Swift, so
// that a test can check that both make alike color spaces of the same bytes, and reject the same bytes.
inline String ipcTesterDescription(CGColorSpaceRef WTF_NONNULL colorSpace)
{
    RetainPtr<CFStringRef> name = CGColorSpaceGetName(colorSpace);
    auto iccData = adoptCF(CGColorSpaceCopyICCData(colorSpace));
    auto iccBytes = iccData ? span(iccData.get()) : std::span<const uint8_t> { };
    return makeString("model="_s, static_cast<int>(CGColorSpaceGetModel(colorSpace)), " components="_s, CGColorSpaceGetNumberOfComponents(colorSpace),
        " name="_s, name ? String(name.get()) : "none"_s, " icc="_s, iccData ? static_cast<int64_t>(iccBytes.size()) : -1,
        " iccHash="_s, StringHasher::computeHashAndMaskTop8Bits(iccBytes), " extended="_s, CGColorSpaceUsesExtendedRange(colorSpace),
        " wideGamut="_s, CGColorSpaceIsWideGamutRGB(colorSpace));
}

// What a control part and its style, and a system image, are made of, which IPCTesterReceiver replies for those decoded in C++
// and in Swift (IPCTesterReceiver.swift describes the Swift forms alike), so that a test can check that both decode the same
// bytes alike, and reject the same bytes. Floats are described by their bits.
inline void ipcTesterAppendColorDescription(StringBuilder& builder, const WebCore::Color& color)
{
    auto data = color.data();
    if (!data) {
        builder.append("invalid"_s);
        return;
    }
    builder.append(data->isSemantic ? 1 : 0, ',', data->usesFunctionSerialization ? 1 : 0, ',');
    WTF::switchOn(data->data, [&](WebCore::PackedColor::RGBA packed) {
        builder.append("packed:"_s, packed.value);
    }, [&](const WebCore::OutOfLineColorDataForIPC& components) {
        builder.append(static_cast<unsigned>(components.colorSpace), ':', std::bit_cast<uint32_t>(components.c1), ',', std::bit_cast<uint32_t>(components.c2), ',',
            std::bit_cast<uint32_t>(components.c3), ',', std::bit_cast<uint32_t>(components.alpha));
    });
}

inline String ipcTesterDescription(const WebCore::ControlPart& part, const WebCore::ControlStyle& style)
{
    StringBuilder builder;
    builder.append("appearance="_s, static_cast<unsigned>(part.type()));
    if (auto* meter = dynamicDowncast<WebCore::MeterPart>(part)) {
        builder.append(" meter="_s, static_cast<unsigned>(meter->gaugeRegion()), ',', std::bit_cast<uint64_t>(meter->value()), ',', std::bit_cast<uint64_t>(meter->minimum()), ',',
            std::bit_cast<uint64_t>(meter->maximum()));
    } else if (auto* progressBar = dynamicDowncast<WebCore::ProgressBarPart>(part))
        builder.append(" progress="_s, std::bit_cast<uint64_t>(progressBar->position()), ',', std::bit_cast<uint64_t>(progressBar->animationStartTime().seconds()));
    else if (auto* sliderTrack = dynamicDowncast<WebCore::SliderTrackPart>(part)) {
        auto thumb = sliderTrack->thumbSize();
        auto track = sliderTrack->trackBounds();
        builder.append(" slider="_s, thumb.width(), 'x', thumb.height(), ',', track.x(), ',', track.y(), ',', track.width(), 'x', track.height(), ',',
            std::bit_cast<uint64_t>(sliderTrack->thumbPosition()), ",ticks:"_s, sliderTrack->tickRatios().size());
        for (auto ratio : sliderTrack->tickRatios())
            builder.append(':', std::bit_cast<uint64_t>(ratio));
    } else if (auto* switchPart = dynamicDowncast<WebCore::SwitchPart>(part))
        builder.append(" switch="_s, switchPart->isOn() ? 1 : 0, ',', std::bit_cast<uint32_t>(switchPart->progress()));
#if ENABLE(APPLE_PAY)
    else if (auto* applePayButton = dynamicDowncast<WebCore::ApplePayButtonPart>(part)) {
        builder.append(" applePay="_s, static_cast<unsigned>(applePayButton->buttonType()), ',', static_cast<unsigned>(applePayButton->buttonStyle()), ',',
            applePayButton->locale().isNull() ? "null"_s : applePayButton->locale());
    }
#endif
    builder.append(" states="_s, style.states.toRaw(), " fontSize="_s, std::bit_cast<uint32_t>(style.fontSize), " zoom="_s, std::bit_cast<uint32_t>(style.zoomFactor), " accent="_s);
    ipcTesterAppendColorDescription(builder, style.accentColor);
    builder.append(" text="_s);
    ipcTesterAppendColorDescription(builder, style.textColor);
    builder.append(" border="_s, std::bit_cast<uint32_t>(style.borderWidth.top()), ',', std::bit_cast<uint32_t>(style.borderWidth.right()), ',',
        std::bit_cast<uint32_t>(style.borderWidth.bottom()), ',', std::bit_cast<uint32_t>(style.borderWidth.left()));
    return builder.toString();
}

inline String ipcTesterDescription(const WebCore::SystemImage& image)
{
    StringBuilder builder;
#if ENABLE(APPLE_PAY)
    if (auto* logo = dynamicDowncast<WebCore::ApplePayLogoSystemImage>(image)) {
        builder.append("applePayLogo="_s, static_cast<unsigned>(logo->applePayLogoStyle()));
        return builder.toString();
    }
#endif
#if USE(APPKIT)
    if (auto* controlImage = dynamicDowncast<WebCore::AppKitControlSystemImage>(image)) {
        builder.append("appKitControl="_s, static_cast<unsigned>(controlImage->controlType()), " tint="_s);
        ipcTesterAppendColorDescription(builder, controlImage->tintColor());
        builder.append(" dark="_s, controlImage->useDarkAppearance() ? 1 : 0);
        return builder.toString();
    }
#endif
    UNUSED_PARAM(image);
    return "unknown"_s;
}

// What a filter is made of, which IPCTesterReceiver replies for one decoded in C++ and in Swift (IPCTesterReceiver.swift
// describes the Swift form alike), so that a test can check that both decoders check and normalize the same bytes alike.
// Floats are described by their bits, color spaces by their names.
inline void ipcTesterAppendFloats(StringBuilder& builder, std::initializer_list<float> values)
{
    bool first = true;
    for (auto value : values) {
        if (!first)
            builder.append(',');
        first = false;
        builder.append(std::bit_cast<uint32_t>(value));
    }
}

inline void ipcTesterAppendFloatVector(StringBuilder& builder, const Vector<float>& values)
{
    builder.append(values.size());
    for (auto value : values)
        builder.append(':', std::bit_cast<uint32_t>(value));
}

inline void ipcTesterAppendRect(StringBuilder& builder, const WebCore::FloatRect& rect)
{
    ipcTesterAppendFloats(builder, { rect.x(), rect.y(), rect.width(), rect.height() });
}

inline void ipcTesterAppendComponentTransferFunction(StringBuilder& builder, const WebCore::ComponentTransferFunction& function)
{
    builder.append(static_cast<unsigned>(function.type), ',');
    ipcTesterAppendFloats(builder, { function.slope, function.intercept, function.amplitude, function.exponent, function.offset });
    builder.append(',');
    ipcTesterAppendFloatVector(builder, function.tableValues);
}

inline void ipcTesterAppendLightSourceDescription(StringBuilder& builder, const WebCore::LightSource& lightSource)
{
    if (auto* distant = dynamicDowncast<WebCore::DistantLightSource>(lightSource)) {
        builder.append("distant:"_s);
        ipcTesterAppendFloats(builder, { distant->azimuth(), distant->elevation() });
    } else if (auto* point = dynamicDowncast<WebCore::PointLightSource>(lightSource)) {
        builder.append("point:"_s);
        ipcTesterAppendFloats(builder, { point->position().x(), point->position().y(), point->position().z() });
    } else if (auto* spot = dynamicDowncast<WebCore::SpotLightSource>(lightSource)) {
        builder.append("spot:"_s);
        ipcTesterAppendFloats(builder, { spot->position().x(), spot->position().y(), spot->position().z(), spot->direction().x(), spot->direction().y(),
            spot->direction().z(), spot->specularExponent(), spot->limitingConeAngle() });
    }
}

inline void ipcTesterAppendFilterFunctionDescription(StringBuilder&, const WebCore::FilterFunction&);

inline void ipcTesterAppendFilterGeometry(StringBuilder& builder, const WebCore::Filter& filter)
{
    builder.append(" referenceBox="_s);
    ipcTesterAppendRect(builder, filter.referenceBox());
    builder.append(" filterRegion="_s);
    ipcTesterAppendRect(builder, filter.filterRegion());
    builder.append(" scale="_s);
    ipcTesterAppendFloats(builder, { filter.filterScale().width(), filter.filterScale().height() });
    builder.append(" modes="_s, filter.filterRenderingModes().toRaw(), " options="_s, filter.renderingOptions().toRaw());
}

inline void ipcTesterAppendFilterFunctionDescription(StringBuilder& builder, const WebCore::FilterFunction& function)
{
    using Type = WebCore::FilterFunction::Type;
    if (auto* svgFilter = dynamicDowncast<WebCore::SVGFilterRenderer>(function)) {
        builder.append("svg(units="_s, static_cast<unsigned>(svgFilter->primitiveUnits()), " expression="_s, svgFilter->expression().size());
        for (auto& term : svgFilter->expression()) {
            builder.append(':', term.index, ',', term.level);
            if (term.geometry) {
                for (auto value : { term.geometry->x(), term.geometry->y(), term.geometry->width(), term.geometry->height() }) {
                    if (value)
                        builder.append(',', std::bit_cast<uint32_t>(*value));
                    else
                        builder.append(",-"_s);
                }
            }
        }
        builder.append(" effects="_s, svgFilter->effects().size());
        for (auto& effect : svgFilter->effects()) {
            builder.append(' ');
            ipcTesterAppendFilterFunctionDescription(builder, effect.get());
        }
        ipcTesterAppendFilterGeometry(builder, *svgFilter);
        auto identifier = svgFilter->renderingResourceIdentifierIfExists();
        builder.append(" identifier="_s, identifier ? String::number(identifier->toUInt64()) : "none"_s, ')');
        return;
    }
    auto* effect = dynamicDowncast<WebCore::FilterEffect>(function);
    if (!effect) {
        builder.append("unknown"_s);
        return;
    }
    switch (effect->filterType()) {
    case Type::FEBlend:
        builder.append("blend("_s, static_cast<unsigned>(downcast<WebCore::FEBlend>(*effect).blendMode()));
        break;
    case Type::FEColorMatrix: {
        auto& colorMatrix = downcast<WebCore::FEColorMatrix>(*effect);
        builder.append("colorMatrix("_s, static_cast<unsigned>(colorMatrix.type()), ',');
        ipcTesterAppendFloatVector(builder, colorMatrix.values());
        break;
    }
    case Type::FEComponentTransfer: {
        auto& transfer = downcast<WebCore::FEComponentTransfer>(*effect);
        builder.append("componentTransfer("_s);
        for (auto& function : { transfer.redFunction(), transfer.greenFunction(), transfer.blueFunction(), transfer.alphaFunction() }) {
            ipcTesterAppendComponentTransferFunction(builder, function);
            builder.append(';');
        }
        break;
    }
    case Type::FEComposite: {
        auto& composite = downcast<WebCore::FEComposite>(*effect);
        builder.append("composite("_s, static_cast<unsigned>(composite.operation()), ',');
        ipcTesterAppendFloats(builder, { composite.k1(), composite.k2(), composite.k3(), composite.k4() });
        break;
    }
    case Type::FEConvolveMatrix: {
        auto& convolve = downcast<WebCore::FEConvolveMatrix>(*effect);
        builder.append("convolveMatrix("_s, convolve.kernelSize().width(), 'x', convolve.kernelSize().height(), ',');
        ipcTesterAppendFloats(builder, { convolve.divisor(), convolve.bias() });
        builder.append(',', convolve.targetOffset().x(), ',', convolve.targetOffset().y(), ',', static_cast<unsigned>(convolve.edgeMode()), ',');
        ipcTesterAppendFloats(builder, { convolve.kernelUnitLength().x(), convolve.kernelUnitLength().y() });
        builder.append(',', convolve.preserveAlpha() ? 1 : 0, ',');
        ipcTesterAppendFloatVector(builder, convolve.kernel());
        break;
    }
    case Type::FEDiffuseLighting: {
        auto& lighting = downcast<WebCore::FEDiffuseLighting>(*effect);
        builder.append("diffuseLighting("_s);
        ipcTesterAppendColorDescription(builder, lighting.lightingColor());
        builder.append(',');
        ipcTesterAppendFloats(builder, { lighting.surfaceScale(), lighting.diffuseConstant(), lighting.kernelUnitLengthX(), lighting.kernelUnitLengthY() });
        builder.append(',');
        ipcTesterAppendLightSourceDescription(builder, lighting.lightSource());
        break;
    }
    case Type::FEDisplacementMap: {
        auto& displacement = downcast<WebCore::FEDisplacementMap>(*effect);
        builder.append("displacementMap("_s, static_cast<unsigned>(displacement.xChannelSelector()), ',', static_cast<unsigned>(displacement.yChannelSelector()), ',');
        ipcTesterAppendFloats(builder, { displacement.scale() });
        builder.append(',', displacement.in2IsTainted() ? 1 : 0);
        break;
    }
    case Type::FEDropShadow: {
        auto& shadow = downcast<WebCore::FEDropShadow>(*effect);
        builder.append("dropShadow("_s);
        ipcTesterAppendFloats(builder, { shadow.stdDeviationX(), shadow.stdDeviationY(), shadow.dx(), shadow.dy() });
        builder.append(',');
        ipcTesterAppendColorDescription(builder, shadow.shadowColor());
        builder.append(',');
        ipcTesterAppendFloats(builder, { shadow.shadowOpacity() });
        break;
    }
    case Type::FEFlood: {
        auto& flood = downcast<WebCore::FEFlood>(*effect);
        builder.append("flood("_s);
        ipcTesterAppendColorDescription(builder, flood.floodColor());
        builder.append(',');
        ipcTesterAppendFloats(builder, { flood.floodOpacity() });
        break;
    }
    case Type::FEGaussianBlur: {
        auto& blur = downcast<WebCore::FEGaussianBlur>(*effect);
        builder.append("gaussianBlur("_s);
        ipcTesterAppendFloats(builder, { blur.stdDeviationX(), blur.stdDeviationY() });
        builder.append(',', static_cast<unsigned>(blur.edgeMode()));
        break;
    }
    case Type::FEImage: {
        auto& image = downcast<WebCore::FEImage>(*effect);
        builder.append("image("_s, image.sourceImage().imageIdentifier().toUInt64(), ',');
        ipcTesterAppendRect(builder, image.sourceImageRect());
        builder.append(')');
        return;
    }
    case Type::FEMerge:
        builder.append("merge("_s, downcast<WebCore::FEMerge>(*effect).numberOfEffectInputs());
        break;
    case Type::FEMorphology: {
        auto& morphology = downcast<WebCore::FEMorphology>(*effect);
        builder.append("morphology("_s, static_cast<unsigned>(morphology.morphologyOperator()), ',');
        ipcTesterAppendFloats(builder, { morphology.radiusX(), morphology.radiusY() });
        break;
    }
    case Type::FEOffset: {
        auto& offset = downcast<WebCore::FEOffset>(*effect);
        builder.append("offset("_s);
        ipcTesterAppendFloats(builder, { offset.dx(), offset.dy() });
        break;
    }
    case Type::FESpecularLighting: {
        auto& lighting = downcast<WebCore::FESpecularLighting>(*effect);
        builder.append("specularLighting("_s);
        ipcTesterAppendColorDescription(builder, lighting.lightingColor());
        builder.append(',');
        ipcTesterAppendFloats(builder, { lighting.surfaceScale(), lighting.specularConstant(), lighting.specularExponent(), lighting.kernelUnitLengthX(),
            lighting.kernelUnitLengthY() });
        builder.append(',');
        ipcTesterAppendLightSourceDescription(builder, lighting.lightSource());
        break;
    }
    case Type::FETile:
        builder.append("tile("_s);
        break;
    case Type::FETurbulence: {
        auto& turbulence = downcast<WebCore::FETurbulence>(*effect);
        builder.append("turbulence("_s, static_cast<unsigned>(turbulence.type()), ',');
        ipcTesterAppendFloats(builder, { turbulence.baseFrequencyX(), turbulence.baseFrequencyY() });
        builder.append(',', turbulence.numOctaves(), ',');
        ipcTesterAppendFloats(builder, { turbulence.seed() });
        builder.append(',', turbulence.stitchTiles() ? 1 : 0);
        break;
    }
    case Type::SourceAlpha:
        builder.append("sourceAlpha("_s);
        break;
    case Type::SourceGraphic:
        builder.append("sourceGraphic("_s);
        break;
    default:
        builder.append("unknown"_s);
        return;
    }
    RetainPtr<CFStringRef> name = CGColorSpaceGetName(effect->operatingColorSpace().platformColorSpace());
    builder.append(" colorSpace="_s, name ? String(name.get()) : "none"_s, ')');
}

inline String ipcTesterDescription(const WebCore::Filter& filter)
{
    StringBuilder builder;
    if (auto* cssFilter = dynamicDowncast<WebCore::CSSFilterRenderer>(filter)) {
        builder.append("css(functions="_s, cssFilter->functions().size());
        for (auto& function : cssFilter->functions()) {
            builder.append(' ');
            ipcTesterAppendFilterFunctionDescription(builder, function.get());
        }
        ipcTesterAppendFilterGeometry(builder, *cssFilter);
        builder.append(')');
    } else
        ipcTesterAppendFilterFunctionDescription(builder, filter);
    return builder.toString();
}

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
// What a fill rule, a transform and a color as the CG renderer takes it are made of, which IPCTesterReceiver replies for those
// decoded in C++ and in Swift (IPCTesterReceiver.swift describes the Swift forms alike). Floats and doubles are described by
// their bits.
inline String ipcTesterDescription(WebCore::WindRule rule, const WebCore::AffineTransform& transform, const CGRendererColorValue& color)
{
    StringBuilder builder;
    builder.append("rule="_s, static_cast<unsigned>(rule), " transform="_s);
    bool isFirst = true;
    for (double value : transform.span()) {
        builder.append(isFirst ? ""_s : ","_s, std::bit_cast<uint64_t>(value));
        isFirst = false;
    }
    const auto& data = color.data;
    builder.append(" color="_s, color.packedColor, ',', color.isPacked ? 1 : 0, ',', color.isVisible ? 1 : 0, " data="_s, std::bit_cast<uint32_t>(data.c1), ',',
        std::bit_cast<uint32_t>(data.c2), ',', std::bit_cast<uint32_t>(data.c3), ',', std::bit_cast<uint32_t>(data.alpha), ',', data.packedColor, ',',
        static_cast<unsigned>(data.colorSpace), ',', static_cast<unsigned>(data.form), ',', data.isSemantic ? 1 : 0, ',', data.usesFunctionSerialization ? 1 : 0);
    return builder.toString();
}

// What the CG renderer takes of a path (CGRendererPathFacts and the CGPath of a path of more than one segment), for a path
// decoded in Swift, and for one decoded in C++, of which Path itself gives them.
// A digest of the pixels of a bitmap filled black after a clip out.
template<typename ClipOut> uint64_t ipcTesterClipOutDigest(const ClipOut& clipOut)
{
    constexpr size_t side = 64;
    RetainPtr colorSpace = adoptCF(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    RetainPtr context = adoptCF(CGBitmapContextCreate(nullptr, side, side, 8, side * 4, colorSpace.get(), kCGImageAlphaPremultipliedLast));
    CGContextSetRGBFillColor(context.get(), 1, 1, 1, 1);
    CGContextFillRect(context.get(), CGRectMake(0, 0, side, side));
    clipOut(context.get());
    CGContextSetRGBFillColor(context.get(), 0, 0, 0, 1);
    CGContextFillRect(context.get(), CGRectMake(0, 0, side, side));
    uint64_t digest = 14695981039346656037ull;
    for (auto byte : unsafeMakeSpan(static_cast<const uint8_t*>(CGBitmapContextGetData(context.get())), side * side * 4)) {
        digest ^= byte;
        digest *= 1099511628211ull;
    }
    return digest;
}

inline String ipcTesterPathDescription(CGPathRef WTF_NULLABLE platformPath, CGRendererPathFacts facts, uint64_t clipOutDigest) __attribute__((availability(swift, unavailable)))
{
    auto appendSegment = [](StringBuilder& builder, const CGRendererPathSegment& values) {
        builder.append(static_cast<unsigned>(values.kind), ':', values.flag ? 1 : 0);
        for (float value : std::span { values.values })
            builder.append(',', std::bit_cast<uint32_t>(value));
    };
    StringBuilder builder;
    builder.append("segments="_s, facts.segmentCount);
    if (facts.segmentCount == 1) {
        builder.append(" segment="_s);
        appendSegment(builder, facts.segment);
    }
    builder.append(" wedge="_s);
    appendSegment(builder, facts.pieWedgeArc);
    builder.append(" clipout="_s, clipOutDigest);
    if (!platformPath)
        return builder.toString();
    builder.append(" bounds="_s, std::bit_cast<uint64_t>(facts.fastBoundingRect.origin.x), ',', std::bit_cast<uint64_t>(facts.fastBoundingRect.origin.y), ',',
        std::bit_cast<uint64_t>(facts.fastBoundingRect.size.width), ',', std::bit_cast<uint64_t>(facts.fastBoundingRect.size.height), " elements="_s);
    CGPathApply(platformPath, &builder, [](void* info, const CGPathElement* element) {
        auto& builder = *static_cast<StringBuilder*>(info);
        size_t pointCount = 0;
        switch (element->type) {
        case kCGPathElementMoveToPoint:
        case kCGPathElementAddLineToPoint:
            pointCount = 1;
            break;
        case kCGPathElementAddQuadCurveToPoint:
            pointCount = 2;
            break;
        case kCGPathElementAddCurveToPoint:
            pointCount = 3;
            break;
        case kCGPathElementCloseSubpath:
            break;
        }
        builder.append(' ', static_cast<int>(element->type));
        for (auto& point : unsafeMakeSpan(element->points, pointCount))
            builder.append(',', std::bit_cast<uint64_t>(point.x), ',', std::bit_cast<uint64_t>(point.y));
    });
    return builder.toString();
}

// The same for a path decoded in Swift, clipped out as the renderer clips it out (CGRendererPath.clipOut()).
inline String ipcTesterPathDescription(CGPathRef WTF_NULLABLE platformPath, CGRendererPathFacts facts)
{
    RetainPtr<CGPathRef> clipOutPath = platformPath;
    if (!clipOutPath && facts.segmentCount == 1)
        clipOutPath = adoptCF(CGRendererCreatePath(facts.segment));
    auto digest = ipcTesterClipOutDigest([&](CGContextRef context) {
        if (clipOutPath) {
            CGRendererClipOutToPlatformPath(context, clipOutPath.get());
            return;
        }
        CGContextBeginPath(context);
        CGContextAddRect(context, CGContextGetClipBoundingBox(context));
        CGContextEOClip(context);
    });
    return ipcTesterPathDescription(platformPath, facts, digest);
}

inline String ipcTesterDescription(const WebCore::Path& path)
{
    auto segments = path.segments();
    CGRendererPathFacts facts { segments.size(), { }, { { }, CGRendererPathSegmentKind::CloseSubpath, false }, CGRectZero, false };
    if (segments.size() == 1)
        facts.segment = CGRendererPathSegmentValues(segments[0]);
    if (auto arc = path.pieWedgeArc())
        facts.pieWedgeArc = CGRendererPathSegmentValues(WebCore::PathSegment { *arc });
    // C++ clips a PathCG of the segments out, as GraphicsContextCG::clipOut() does a Path of a CGPath.
    Ref pathCG = WebCore::PathCG::create(segments.span());
    auto digest = ipcTesterClipOutDigest([&](CGContextRef context) {
        CGRendererClipOutToPathImpl(context, pathCG.get());
    });
    if (segments.size() < 2)
        return ipcTesterPathDescription(nullptr, facts, digest);
    facts.fastBoundingRect = path.fastBoundingRect();
    facts.hasFastBoundingRect = true;
    return ipcTesterPathDescription(path.platformPath(), facts, digest);
}
#endif

#if ENABLE(IPC_TESTING_SWIFT)
#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
inline String ipcTesterCxxDecodedDrawingFormsDescription(IPC::CxxDecodedArgument<WebCore::WindRule>& ruleArgument, IPC::CxxDecodedArgument<WebCore::AffineTransform>& transformArgument, IPC::CxxDecodedArgument<CGRendererColorValue>& colorArgument)
{
    auto rule = ruleArgument.take();
    auto transform = transformArgument.take();
    auto color = colorArgument.take();
    RELEASE_ASSERT(rule && transform && color);
    return ipcTesterDescription(*rule, *transform, *color);
}

inline String ipcTesterCxxDecodedPathDescription(IPC::CxxDecodedArgument<WebCore::Path>& pathArgument)
{
    auto path = pathArgument.take();
    RELEASE_ASSERT(path);
    return ipcTesterDescription(*path);
}

#if ENABLE(GPU_PROCESS)
// Where the Swift coders of RemoteCGRenderer's messages don't decode and encode what C++ encodes as the web process does
// (IPCTesterCGRendererWireForms.cpp): a line for each, empty if none.
String ipcTesterCGRendererWireFormMismatches();
#endif
#endif
#endif

#if ENABLE(IPC_TESTING_SWIFT)
// The CGColorSpace of a ColorSpace that C++ decoded for IPCTesterReceiver's Swift receiver.
inline CGColorSpaceRef WTF_NONNULL ipcTesterCxxDecodedColorSpace(IPC::CxxDecodedArgument<WebCore::ColorSpace>& colorSpaceArgument) CF_RETURNS_RETAINED
{
    auto colorSpace = colorSpaceArgument.take();
    RELEASE_ASSERT(colorSpace);
    return RetainPtr { colorSpace->platformColorSpace() }.leakRef();
}
#endif
#endif

} // namespace WebKit

#endif // ENABLE(IPC_TESTING_API)
