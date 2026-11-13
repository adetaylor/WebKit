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
#include <WebCore/ControlStyle.h>
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

#if ENABLE(IPC_TESTING_SWIFT)
inline String ipcTesterCxxDecodedControlDescription(IPC::CxxDecodedArgument<Ref<WebCore::ControlPart>>& partArgument, IPC::CxxDecodedArgument<WebCore::ControlStyle>& styleArgument)
{
    auto part = partArgument.take();
    auto style = styleArgument.take();
    RELEASE_ASSERT(part && style);
    return ipcTesterDescription(part->get(), *style);
}

inline String ipcTesterCxxDecodedSystemImageDescription(IPC::CxxDecodedArgument<Ref<WebCore::SystemImage>>& imageArgument)
{
    auto image = imageArgument.take();
    RELEASE_ASSERT(image);
    return ipcTesterDescription(image->get());
}
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
