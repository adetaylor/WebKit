/*
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
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
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CSSPropertyParserConsumer+Image.h"

#include "CSSCalcSymbolTable.h"
#include "CSSCanvasValue.h"
#include "CSSColor.h"
#include "CSSColorImageValue.h"
#include "CSSColorInterpolationMethod.h"
#include "CSSCrossfadeValue.h"
#include "CSSCursorImageValue.h"
#include "CSSFilterImageValue.h"
#include "CSSGradientValue.h"
#include "CSSImageSetOptionValue.h"
#include "CSSImageSetValue.h"
#include "CSSImageValue.h"
#include "CSSLightDarkImageValue.h"
#include "CSSMeshGradientValue.h"
#include "CSSNamedImageValue.h"
#include "CSSPaintImageValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveNumericTypes.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+AnglePercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserConsumer+ColorInterpolationMethod.h"
#include "CSSPropertyParserConsumer+Filter.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+MetaResolver.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+Percentage.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Position.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+ResolutionDefinitions.h"
#include "CSSPropertyParserConsumer+Shapes.h"
#include "CSSPropertyParserConsumer+String.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserOptions.h"
#include "CSSPropertyParserState.h"
#include "CSSStringValue.h"
#include "CSSValue.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "CSSVariableData.h"
#include <wtf/SortedArrayMap.h>
#include "CSSPropertyConsumerSwiftBuilders.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// MARK: <mesh-gradient()>
// The Swift <image> consumer doesn't parse mesh-gradient(), so its C++ parser stays here, for the image values that
// start with it.

static std::optional<CSS::CoordinatePair> consumeMeshGradientCoordinatePair(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <coordinate-pair> = <length-percentage>{2}
    // https://drafts.csswg.org/css-shapes-2/#typedef-shape-coordinate-pair

    auto rangeCopy = range;

    auto x = MetaConsumer<CSS::CoordinatePair::value_type>::consume(rangeCopy, state);
    if (!x)
        return { };
    auto y = MetaConsumer<CSS::CoordinatePair::value_type>::consume(rangeCopy, state);
    if (!y)
        return { };

    range = rangeCopy;
    return CSS::CoordinatePair { WTF::move(*x), WTF::move(*y) };
}

static bool stopColorIs8Bit(const CSS::Color& color)
{
    return color.isKeyword() || color.absoluteColor().tryGetAsSRGBABytes();
}

static bool stopColorIs8Bit(const Markable<CSS::Color>& color)
{
    return !color || stopColorIs8Bit(*color);
}

static CSS::GradientColorInterpolationMethod computeGradientColorInterpolationMethod(std::optional<CSS::ColorInterpolationMethod> parsedColorInterpolationMethod, CSS::GradientColorInterpolationMethod::Default defaultColorInterpolationMethod)
{
    if (parsedColorInterpolationMethod)
        return { .method = *parsedColorInterpolationMethod, .defaultMethod = defaultColorInterpolationMethod };

    switch (defaultColorInterpolationMethod) {
    case CSS::GradientColorInterpolationMethod::Default::SRGB:
        return { .method = { ColorInterpolationMethod::SRGB { }, AlphaPremultiplication::Premultiplied }, .defaultMethod = defaultColorInterpolationMethod };

    case CSS::GradientColorInterpolationMethod::Default::OKLab:
        return { .method = { ColorInterpolationMethod::OKLab { }, AlphaPremultiplication::Premultiplied }, .defaultMethod = defaultColorInterpolationMethod };
    }

    ASSERT_NOT_REACHED();
    return { .method = { ColorInterpolationMethod::SRGB { }, AlphaPremultiplication::Premultiplied }, .defaultMethod = defaultColorInterpolationMethod };
}

// https://github.com/w3c/csswg-drafts/pull/14655

static std::optional<CSS::MeshGradientRelativeControlPoint> consumeMeshGradientRelativeControlPoint(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <mesh-relative-control-point> = <coordinate-pair> [from origin]?

    auto rangeCopy = range;

    auto offset = consumeMeshGradientCoordinatePair(rangeCopy, state);
    if (!offset)
        return { };

    std::optional<CSS::Keyword::Origin> anchor;
    if (consumeIdent<CSSValueID::From>(rangeCopy)) {
        if (!consumeIdent<CSSValueID::Origin>(rangeCopy))
            return { };
        anchor = CSS::Keyword::Origin { };
    }

    range = rangeCopy;

    return CSS::MeshGradientRelativeControlPoint {
        .offset = WTF::move(*offset),
        .anchor = WTF::move(anchor),
    };
}

template<typename ControlPoints> static std::optional<ControlPoints> consumeMeshGradientControlPoints(CSSParserTokenRange& range, NOESCAPE const auto& consumeControlPoint)
{
    // [ with <control-point> [ / <control-point> ]{0,3} ]?

    if (!consumeIdent<CSSValueID::With>(range))
        return ControlPoints { };

    typename ControlPoints::value_type::Container controlPoints;
    do {
        auto controlPoint = consumeControlPoint(range);
        if (!controlPoint)
            return { };
        controlPoints.append(WTF::move(*controlPoint));
    } while (controlPoints.size() < 4 && consumeSlashIncludingWhitespace(range));

    return ControlPoints { WTF::move(controlPoints) };
}

static std::optional<CSS::MeshGradientPoint> consumeMeshGradientPoint(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <mesh-point> = <color> [ <mesh-absolute-position> | <mesh-relative-position> ]?

    auto color = consumeUnresolvedColor(range, state);
    if (!color)
        return { };

    std::optional<CSS::MeshGradientPoint::Location> location;

    if (consumeIdent<CSSValueID::By>(range)) {
        // <mesh-relative-position> = by <coordinate-pair> [ with <mesh-relative-control-point> [ / <mesh-relative-control-point> ]{0,3} ]?

        auto offset = consumeMeshGradientCoordinatePair(range, state);
        if (!offset)
            return { };

        auto controlPoints = consumeMeshGradientControlPoints<CSS::MeshGradientRelativePosition::ControlPoints>(range, [&](auto& range) {
            return consumeMeshGradientRelativeControlPoint(range, state);
        });
        if (!controlPoints)
            return { };

        location = CSS::MeshGradientRelativePosition {
            .offset = WTF::move(*offset),
            .controlPoints = WTF::move(*controlPoints),
        };
    } else if (auto position = consumePositionUnresolved(range, state)) {
        // <mesh-absolute-position> = <position> [ with <position> [ / <position> ]{0,3} ]?

        auto controlPoints = consumeMeshGradientControlPoints<CSS::MeshGradientAbsolutePosition::ControlPoints>(range, [&](auto& range) {
            return consumePositionUnresolved(range, state);
        });
        if (!controlPoints)
            return { };

        location = CSS::MeshGradientAbsolutePosition {
            .position = WTF::move(*position),
            .controlPoints = WTF::move(*controlPoints),
        };
    }

    return CSS::MeshGradientPoint {
        .color = WTF::move(*color),
        .location = WTF::move(location),
    };
}

static RefPtr<CSSValue> consumeMeshGradient(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // mesh-gradient( [ <color-interpolation-method> || <color> ]?,
    //                <mesh-point>#{2,} [ ';' <mesh-point>#{2,} ]+
    //              )
    // <mesh-point> = <color> [ <mesh-absolute-position> | <mesh-relative-position> ]?
    // <mesh-absolute-position> = <position> [ with <position> [ / <position> ]{0,3} ]?
    // <mesh-relative-position> = by <coordinate-pair> [ with <mesh-relative-control-point> [ / <mesh-relative-control-point> ]{0,3} ]?
    // <mesh-relative-control-point> = <coordinate-pair> [from origin]?

    if (!state.context.cssMeshGradientsEnabled)
        return nullptr;

    // FIXME: A lone <color> is ambiguous between the prelude and the first <mesh-point> so the prelude is
    // only recognized when it contains a <color-interpolation-method>.

    std::optional<CSS::ColorInterpolationMethod> colorInterpolationMethod;
    Markable<CSS::Color> backgroundColor;

    auto preludeRange = range;
    if (preludeRange.peek().id() == CSSValueID::In) {
        colorInterpolationMethod = consumeColorInterpolationMethod(preludeRange, state);
        if (!colorInterpolationMethod)
            return nullptr;

        if (preludeRange.peek().type() != CommaToken) {
            auto preludeColor = consumeUnresolvedColor(preludeRange, state);
            if (!preludeColor)
                return nullptr;
            backgroundColor = WTF::move(*preludeColor);
        }
    } else if (auto preludeColor = consumeUnresolvedColor(preludeRange, state); preludeColor && preludeRange.peek().id() == CSSValueID::In) {
        colorInterpolationMethod = consumeColorInterpolationMethod(preludeRange, state);
        if (!colorInterpolationMethod)
            return nullptr;
        backgroundColor = WTF::move(*preludeColor);
    }

    if (colorInterpolationMethod) {
        if (!consumeCommaIncludingWhitespace(preludeRange))
            return nullptr;
        range = preludeRange;
    }

    CSS::MeshGradientRows::Container rows;
    CSS::MeshGradientRow::Container row;
    while (true) {
        auto point = consumeMeshGradientPoint(range, state);
        if (!point)
            return nullptr;
        row.append(WTF::move(*point));

        if (consumeCommaIncludingWhitespace(range))
            continue;

        rows.append(CSS::MeshGradientRow { std::exchange(row, { }) });

        if (range.atEnd())
            break;
        if (!consumeSemicolon(range))
            return nullptr;
    }

    // A mesh needs at least two rows and two columns, and rows of equal length.
    if (rows.size() < 2 || rows[0].size() < 2)
        return nullptr;
    for (auto& meshRow : rows) {
        if (meshRow.size() != rows[0].size())
            return nullptr;
    }

    auto defaultColorInterpolationMethod = CSS::GradientColorInterpolationMethod::Default::SRGB;
    if (!stopColorIs8Bit(backgroundColor))
        defaultColorInterpolationMethod = CSS::GradientColorInterpolationMethod::Default::OKLab;
    for (auto& meshRow : rows) {
        for (auto& point : meshRow) {
            if (!stopColorIs8Bit(point.color))
                defaultColorInterpolationMethod = CSS::GradientColorInterpolationMethod::Default::OKLab;
        }
    }

    return CSSMeshGradientValue::create({
        .parameters = {
            .colorInterpolationMethod = computeGradientColorInterpolationMethod(colorInterpolationMethod, defaultColorInterpolationMethod),
            .backgroundColor = WTF::move(backgroundColor),
            .rows = { WTF::move(rows) },
        }
    });
}

RefPtr<CSSValue> consumeImage(CSSParserTokenRange& range, CSS::PropertyParserState& state, OptionSet<AllowedImageType> allowedImageTypes)
{
    if (range.peek().type() == FunctionToken && range.peek().functionId() == CSSValueID::MeshGradient) {
        if (!allowedImageTypes.contains(AllowedImageType::GeneratedImage))
            return nullptr;
        auto rangeCopy = range;
        auto args = consumeFunction(rangeCopy);
        RefPtr result = consumeMeshGradient(args, state);
        if (!result || !args.atEnd())
            return nullptr;
        range = rangeCopy;
        return result;
    }
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::Image, allowedImageTypes.toRaw());
}

// MARK: <image> | none

RefPtr<CSSValue> consumeImageOrNone(CSSParserTokenRange& range, CSS::PropertyParserState& state, OptionSet<AllowedImageType> allowedImageTypes)
{
    if (range.peek().id() == CSSValueID::None && allowedImageTypes.contains(AllowedImageType::GeneratedImage))
        return consumeIdent(range);
    return consumeImage(range, state, allowedImageTypes);
}

std::optional<CSS::ImageOrNone> consumeUnresolvedImageOrNone(CSSParserTokenRange& range, CSS::PropertyParserState& state, OptionSet<AllowedImageType> allowedImageTypes)
{
    if (range.peek().id() == CSSValueID::None && allowedImageTypes.contains(AllowedImageType::GeneratedImage)) {
        range.consumeIncludingWhitespace();
        return CSS::ImageOrNone { CSS::Keyword::None { } };
    }
    RefPtr image = consumeImage(range, state, allowedImageTypes);
    if (!image)
        return std::nullopt;
    return CSS::ImageOrNone { CSS::ImageWrapper { image.releaseNonNull() } };
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
