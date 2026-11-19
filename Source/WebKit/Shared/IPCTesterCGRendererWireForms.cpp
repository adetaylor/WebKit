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

#include "config.h"
#include "IPCTesterPayload.h"

#if ENABLE(IPC_TESTING_API) && ENABLE(IPC_TESTING_SWIFT) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS) && ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)

#include "Decoder.h"
#include "HandleMessage.h"
#include "RemoteCGRendererMessages.h"
#include "RemoteCGRendererStyleKind.h"
#include "SwiftCoding.h"
#include "WebKit-Swift.h"
#include <WebCore/FloatSegment.h>
#include <WebCore/PathSegment.h>
#include <WebCore/PathSegmentData.h>
#include <wtf/text/StringBuilder.h>

namespace WebKit {

using namespace WebCore;

// Encodes the arguments of one of RemoteCGRenderer's messages with the C++ ArgumentCoders of the types that the web process
// sends them as, has the message's Swift coders decode and encode them again (ipcTesterReencodeCGRendererArguments()), and
// notes where that doesn't give back the bytes that C++ encoded expected, by default the same arguments, or where Swift
// doesn't reject the message cut short by a byte.
template<typename Message>
static void checkCGRendererWireForm(StringBuilder& mismatches, ASCIILiteral label, const typename Message::Arguments& arguments, std::optional<typename Message::Arguments> expectedArguments = std::nullopt, uint8_t variant = 0)
{
    auto encode = [](const typename Message::Arguments& values) {
        Vector<uint8_t> encoded;
        std::apply([&](auto&... value) {
            IPC::appendRecordedMessage(encoded, Message::name(), value...);
        }, values);
        return encoded;
    };
    auto encoded = encode(arguments);
    auto expected = expectedArguments ? encode(*expectedArguments) : encoded;

    auto reencode = [&](std::span<const uint8_t> message, Vector<uint8_t>& reencoded) {
        bool decoded = false;
        IPC::forEachRecordedMessage(message, [&](IPC::Decoder& decoder) {
            NonEscapableBorrowLender<IPC::SwiftDecoder> lender { decoder };
            auto swiftDecoder = lender.view();
            Ref swiftEncoder = adoptRef(*IPC::SwiftReplyEncoder::createForRecordedMessage(Message::name()));
            decoded = ipcTesterReencodeCGRendererArguments(static_cast<uint16_t>(Message::name()), swiftDecoder, swiftEncoder.ptr(), variant) && decoder.isValid();
            if (decoded)
                IPC::appendSwiftEncodedRecordedMessage(reencoded, swiftEncoder.get());
            return true;
        });
        return decoded;
    };

    Vector<uint8_t> reencoded;
    if (!reencode(encoded.span(), reencoded))
        mismatches.append(label, ": Swift rejected it\n"_s);
    else if (reencoded != expected)
        mismatches.append(label, ": Swift encoded other bytes\n"_s);

    // The message cut short by a byte, with its size adjusted.
    Vector<uint8_t> truncated { encoded.span().first(encoded.size() - 1) };
    uint32_t size = encoded.size() - 1 - sizeof(uint32_t);
    memcpySpan(truncated.mutableSpan().first(sizeof(size)), asByteSpan(size));
    Vector<uint8_t> ignored;
    if (reencode(truncated.span(), ignored))
        mismatches.append(label, ": Swift accepted it cut short\n"_s);
}

// A malformed form of one of the messages, whose arguments encode() encodes: C++ must reject it, and Swift must too.
template<typename Message>
static void checkCGRendererWireFormRejected(StringBuilder& mismatches, ASCIILiteral label, NOESCAPE const Invocable<void(IPC::Encoder&)> auto& encode, uint8_t variant = 0)
{
    IPC::Encoder encoder(Message::name(), 0);
    encode(encoder);
    Vector<uint8_t> message;
    uint32_t size = encoder.span().size();
    message.append(asByteSpan(size));
    message.append(encoder.span());

    IPC::forEachRecordedMessage(message.span(), [&](IPC::Decoder& decoder) {
        if (decoder.decode<typename Message::Arguments>())
            mismatches.append(label, ": C++ accepted it\n"_s);
        return true;
    });
    IPC::forEachRecordedMessage(message.span(), [&](IPC::Decoder& decoder) {
        NonEscapableBorrowLender<IPC::SwiftDecoder> lender { decoder };
        auto swiftDecoder = lender.view();
        Ref swiftEncoder = adoptRef(*IPC::SwiftReplyEncoder::createForRecordedMessage(Message::name()));
        if (ipcTesterReencodeCGRendererArguments(static_cast<uint16_t>(Message::name()), swiftDecoder, swiftEncoder.ptr(), variant) && decoder.isValid())
            mismatches.append(label, ": Swift accepted it\n"_s);
        return true;
    });
}

static void checkMalformedCGRendererWireForms(StringBuilder& mismatches)
{
    constexpr uint64_t hugeCount = 1ull << 63;
    auto encodeColorData = [](IPC::Encoder& encoder, uint8_t colorSpace, uint8_t form) {
        encoder << 0.25f << 0.5f << 0.75f << 1.0f << static_cast<uint32_t>(0x336699ff) << colorSpace << form << false << false;
    };
    auto encodeShadowValues = [](IPC::Encoder& encoder, uint8_t isValid) {
        encoder << 3.0f << -4.0f << 5.0f << 0.5f << static_cast<uint32_t>(0x11223344) << isValid << true << false;
    };
    auto encodeMatrix = [](IPC::Encoder& encoder) {
        for (int index = 0; index < 20; ++index)
            encoder << static_cast<float>(index);
    };

    for (uint64_t count : { static_cast<uint64_t>(1000), hugeCount }) {
        checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::SetLineDash>(mismatches, "SetLineDash of more dashes than the message has"_s, [&](auto& encoder) {
            encoder << count << 1.5 << 2.5 << 0.5f;
        });
        checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness>(mismatches, "StrokeLinesWithColorAndThickness of more lines than the message has"_s, [&](auto& encoder) {
            PathDataLineColorThickness line { PathDataLine { { 1, 2 }, { 3, 4 } }, PackedColor::RGBA { 0 }, 1 };
            encoder << count;
            encoder.encodeSpan(singleElementSpan(line));
        });
        checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::DrawLinesForText>(mismatches, "DrawLinesForText of more segments than the message has"_s, [&](auto& encoder) {
            encoder << FloatPoint { 1, 2 } << 1.5f << count << 0.0f << 10.0f << false << false << StrokeStyle::SolidStroke;
        });
        for (uint8_t variant : { 0, 1 }) {
            checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::DrawGlyphs>(mismatches, "DrawGlyphs of more glyphs than the message has"_s, [&](auto& encoder) {
                encoder << RenderingResourceIdentifier::generate() << count << static_cast<uint16_t>(1) << 1.0 << 2.0 << FloatPoint { } << FontSmoothingMode::Auto;
            }, variant);
        }
    }

    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::DrawLinesForText>(mismatches, "DrawLinesForText with a stroke style out of range"_s, [&](auto& encoder) {
        encoder << FloatPoint { 1, 2 } << 1.5f << static_cast<uint64_t>(0) << false << false << static_cast<uint8_t>(6);
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::DrawLinesForText>(mismatches, "DrawLinesForText with a bool of 2"_s, [&](auto& encoder) {
        encoder << FloatPoint { 1, 2 } << 1.5f << static_cast<uint64_t>(0) << static_cast<uint8_t>(2) << false << StrokeStyle::SolidStroke;
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::DrawGlyphs>(mismatches, "DrawGlyphs with a smoothing mode out of range"_s, [&](auto& encoder) {
        encoder << RenderingResourceIdentifier::generate() << static_cast<uint64_t>(0) << FloatPoint { } << static_cast<uint8_t>(4);
    });

    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::SetStyle>(mismatches, "SetStyle of a kind out of range"_s, [&](auto& encoder) {
        encoder << static_cast<uint8_t>(4);
        encodeShadowValues(encoder, 1);
        encodeColorData(encoder, 0, 2);
        encoder << true << 1.5f << 2.5f;
        encodeMatrix(encoder);
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::SetStyle>(mismatches, "SetStyle with a bool of 2"_s, [&](auto& encoder) {
        encoder << RemoteCGRendererStyleKind::DropShadow;
        encodeShadowValues(encoder, 1);
        encodeColorData(encoder, 0, 2);
        encoder << static_cast<uint8_t>(2) << 1.5f << 2.5f;
        encodeMatrix(encoder);
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::SetDropShadow>(mismatches, "SetDropShadow with a shadow bool of 2"_s, [&](auto& encoder) {
        encodeShadowValues(encoder, 2);
        encodeColorData(encoder, 0, 2);
        encoder << true;
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::SetDropShadow>(mismatches, "SetDropShadow with a color space out of range"_s, [&](auto& encoder) {
        encodeShadowValues(encoder, 1);
        encodeColorData(encoder, 255, 2);
        encoder << true;
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::SetDropShadow>(mismatches, "SetDropShadow with a color form out of range"_s, [&](auto& encoder) {
        encodeShadowValues(encoder, 1);
        encodeColorData(encoder, 0, 3);
        encoder << true;
    });

    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::FillPathSegment>(mismatches, "FillPathSegment of a variant index out of range"_s, [&](auto& encoder) {
        encoder << static_cast<uint8_t>(17) << 1.0f << 2.0f;
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::FillPathSegment>(mismatches, "FillPathSegment of an arc with a direction out of range"_s, [&](auto& encoder) {
        encoder << static_cast<uint8_t>(5) << FloatPoint { 1, 2 } << 3.0f << 0.25f << 1.5f << static_cast<uint8_t>(2);
    });
    checkCGRendererWireFormRejected<Messages::RemoteCGRenderer::StrokePathSegment>(mismatches, "StrokePathSegment of a rounded rect with a strategy out of range"_s, [&](auto& encoder) {
        encoder << static_cast<uint8_t>(10) << FloatRoundedRect { { 1, 2, 30, 40 }, { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } } << static_cast<uint8_t>(2);
    });
}

String ipcTesterCGRendererWireFormMismatches()
{
    StringBuilder mismatches;

    Vector<double> dashes { 1.5, 2.25, 0, 1e300 };
    checkCGRendererWireForm<Messages::RemoteCGRenderer::SetLineDash>(mismatches, "SetLineDash"_s, { dashes.span(), 0.5f });
    checkCGRendererWireForm<Messages::RemoteCGRenderer::SetLineDash>(mismatches, "SetLineDash of no dashes"_s, { std::span<const double> { }, -1 });

    PathSegment segments[] = {
        PathSegment { PathMoveTo { { 1, 2 } } },
        PathSegment { PathLineTo { { -3, 4.5 } } },
        PathSegment { PathQuadCurveTo { { 1, 2 }, { 3, 4 } } },
        PathSegment { PathBezierCurveTo { { 1, 2 }, { 3, 4 }, { 5, 6 } } },
        PathSegment { PathArcTo { { 1, 2 }, { 3, 4 }, 5 } },
        PathSegment { PathArc { { 1, 2 }, 3, 0.25, 1.5, RotationDirection::Counterclockwise } },
        PathSegment { PathClosedArc { { { 1, 2 }, 3, 0.25, 1.5, RotationDirection::Clockwise } } },
        PathSegment { PathEllipse { { 1, 2 }, 3, 4, 0.5, 0, 6, RotationDirection::Counterclockwise } },
        PathSegment { PathEllipseInRect { { 1, 2, 3, 4 } } },
        PathSegment { PathRect { { 1, 2, 3, 4 } } },
        PathSegment { PathRoundedRect { FloatRoundedRect { { 1, 2, 30, 40 }, { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } }, PathRoundedRect::Strategy::PreferBezier } },
        PathSegment { PathContinuousRoundedRect { { 1, 2, 3, 4 }, 5, 6 } },
        PathSegment { PathDataLine { { 1, 2 }, { 3, 4 } } },
        PathSegment { PathDataQuadCurve { { 1, 2 }, { 3, 4 }, { 5, 6 } } },
        PathSegment { PathDataBezierCurve { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } } },
        PathSegment { PathDataArc { { 1, 2 }, { 3, 4 }, { 5, 6 }, 7 } },
        PathSegment { PathCloseSubpath { } },
    };
    for (auto& segment : segments) {
        checkCGRendererWireForm<Messages::RemoteCGRenderer::FillPathSegment>(mismatches, "FillPathSegment"_s, { segment });
        checkCGRendererWireForm<Messages::RemoteCGRenderer::StrokePathSegment>(mismatches, "StrokePathSegment"_s, { segment });
    }

    Vector<PathDataLineColorThickness> lines {
        { PathDataLine { { 1, 2 }, { 3, 4 } }, PackedColor::RGBA { 0x336699ff }, 2 },
        { PathDataLine { { -1, 0.5 }, { 1e30, -0.0f } }, PackedColor::RGBA { 0 }, 0.25 },
    };
    for (uint8_t variant : { 0, 1 }) {
        checkCGRendererWireForm<Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness>(mismatches, "StrokeLinesWithColorAndThickness"_s, { lines.span() }, std::nullopt, variant);
        checkCGRendererWireForm<Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness>(mismatches, "StrokeLinesWithColorAndThickness of fewer lines"_s, { lines.span().last(1) }, std::nullopt, variant);
        checkCGRendererWireForm<Messages::RemoteCGRenderer::StrokeLinesWithColorAndThickness>(mismatches, "StrokeLinesWithColorAndThickness of no lines"_s, { std::span<const PathDataLineColorThickness> { } }, std::nullopt, variant);
    }

    CGRendererShadowValues shadowValues { 3, -4, 5, 0.5, 0x11223344, true, true, false };
    CGRendererColorData shadowColor { 0.25, 0.5, 0.75, 1, 0x336699ff, 0, 2, false, true };
    checkCGRendererWireForm<Messages::RemoteCGRenderer::SetDropShadow>(mismatches, "SetDropShadow"_s, { shadowValues, shadowColor, true });
    checkCGRendererWireForm<Messages::RemoteCGRenderer::SetDropShadow>(mismatches, "SetDropShadow of none"_s, { CGRendererShadowValues { }, CGRendererColorData { }, false });

    std::array<float, 20> matrix;
    for (size_t index = 0; index < matrix.size(); ++index)
        matrix[index] = 0.5f * index - 3;
    for (auto kind : { RemoteCGRendererStyleKind::None, RemoteCGRendererStyleKind::DropShadow, RemoteCGRendererStyleKind::GaussianBlur, RemoteCGRendererStyleKind::ColorMatrix })
        checkCGRendererWireForm<Messages::RemoteCGRenderer::SetStyle>(mismatches, "SetStyle"_s, { kind, shadowValues, shadowColor, true, 1.5, 2.5, matrix });

    Vector<FloatSegment> lineSegments { { 0, 10 }, { 12.5, 20 }, { -1, 1e20 } };
    for (uint8_t variant : { 0, 1 }) {
        checkCGRendererWireForm<Messages::RemoteCGRenderer::DrawLinesForText>(mismatches, "DrawLinesForText"_s, { FloatPoint { 1, 2 }, 1.5, lineSegments.span(), false, true, StrokeStyle::WavyStroke }, std::nullopt, variant);
        checkCGRendererWireForm<Messages::RemoteCGRenderer::DrawLinesForText>(mismatches, "DrawLinesForText of fewer segments"_s, { FloatPoint { 1, 2 }, 1.5, lineSegments.span().first(1), false, false, StrokeStyle::SolidStroke }, std::nullopt, variant);
        checkCGRendererWireForm<Messages::RemoteCGRenderer::DrawLinesForText>(mismatches, "DrawLinesForText of no segments"_s, { FloatPoint { }, 0, std::span<const FloatSegment> { }, true, false, StrokeStyle::SolidStroke }, std::nullopt, variant);
    }

    // A live run (variant 0) decodes into storage it reuses, which a longer run then a shorter one checks, and a recorded run
    // (variant 1) into storage of its own. Swift takes the advances at float precision, as RemoteGraphicsContext's DrawGlyphs
    // has them.
    auto identifier = RenderingResourceIdentifier::generate();
    Vector<GlyphBufferGlyph> glyphs { 1, 2, 3, 0xffff };
    Vector<GlyphBufferAdvance> advances { { 1, 2 }, { 0.5, -0.25 }, { 1e10, 0 }, { 3, 4 } };
    Vector<GlyphBufferAdvance> preciseAdvances { { 0.1, 1.0 / 3 }, { 1e30, -1e-300 } };
    Vector<GlyphBufferAdvance> roundedAdvances;
    for (auto& advance : preciseAdvances)
        roundedAdvances.append({ static_cast<float>(advance.width), static_cast<float>(advance.height) });
    for (uint8_t variant : { 0, 1 }) {
        using Arguments = Messages::RemoteCGRenderer::DrawGlyphs::Arguments;
        checkCGRendererWireForm<Messages::RemoteCGRenderer::DrawGlyphs>(mismatches, "DrawGlyphs"_s, Arguments { identifier, { glyphs.span().data(), advances.span().data(), glyphs.size() }, FloatPoint { 1, 2 }, FontSmoothingMode::SubpixelAntialiased }, std::nullopt, variant);
        checkCGRendererWireForm<Messages::RemoteCGRenderer::DrawGlyphs>(mismatches, "DrawGlyphs of precise advances"_s, Arguments { identifier, { glyphs.span().data(), preciseAdvances.span().data(), preciseAdvances.size() }, FloatPoint { }, FontSmoothingMode::Auto }, Arguments { identifier, { glyphs.span().data(), roundedAdvances.span().data(), roundedAdvances.size() }, FloatPoint { }, FontSmoothingMode::Auto }, variant);
        checkCGRendererWireForm<Messages::RemoteCGRenderer::DrawGlyphs>(mismatches, "DrawGlyphs of no glyphs"_s, Arguments { identifier, { }, FloatPoint { }, FontSmoothingMode::None }, std::nullopt, variant);
    }

    checkMalformedCGRendererWireForms(mismatches);

    return mismatches.toString();
}

} // namespace WebKit

#endif
