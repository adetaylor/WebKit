// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// The box shorthands of CSSPropertyParserCustom.h, as `PropertyParser` methods: border, border-inline, border-block
// (consumeBorderShorthandComponents), border-radius and -webkit-border-radius, the eight border-*-radius sides, the
// eighteen corner shorthands (consumeCornerShorthand, tryConsumeCornerRadii, tryConsumeCornerShapes), border-image and -webkit-border-image,
// mask-border and -webkit-mask-box-image. Each follows the C++ as CSSPropertyParserShorthands.swift's header
// describes. The border-image values are parsed by the Swift of CSSPropertyConsumerSwiftValues.swift into
// CSSImageSwiftParts, from which addBorderImageLonghandsForSwift makes the longhands' values; the radii and the
// mask-border longhands' values are made here.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftBuilders

extension PropertyParser {
    // MARK: - border, border-inline, border-block

    /// `BorderShorthandComponents`.
    struct BorderShorthandComponents {
        var width: PropertyValue? = nil
        var style: PropertyValue? = nil
        var color: PropertyValue? = nil
    }

    /// `consumeBorderShorthandComponents`: width, style and color as border-left's longhands, each at most
    /// once, in any order, the first of the unparsed three that parses taken each time; at least one, and the end.
    mutating func consumeBorderShorthandComponents(_ calc: PropertyCalc) -> BorderShorthandComponents? {
        var components = BorderShorthandComponents()

        while components.width == nil || components.style == nil || components.color == nil {
            if components.width == nil {
                components.width = parseStylePropertyLonghand(.BorderLeftWidth, calc)
                if components.width != nil {
                    continue
                }
            }
            if components.style == nil {
                components.style = parseStylePropertyLonghand(.BorderLeftStyle, calc)
                if components.style != nil {
                    continue
                }
            }
            if components.color == nil {
                components.color = parseStylePropertyLonghand(.BorderLeftColor, calc)
                if components.color != nil {
                    continue
                }
            }
            break
        }

        if components.width == nil && components.style == nil && components.color == nil {
            return nil
        }

        guard atEnd else {
            return nil
        }

        return components
    }

    /// `consumeBorderShorthand`: the three groups as border-width, border-style and border-color, each to all
    /// of that shorthand's longhands (`state.important`, IsImplicit::No; a null one implicit initial), then border-image's
    /// five longhands reset (null).
    mutating func consumeBorderShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        guard let components = consumeBorderShorthandComponents(calc) else {
            return false
        }

        sink.addAllLonghands(WebCore.CSSPropertyID.BorderWidth.rawValue, components.width, false)
        sink.addAllLonghands(WebCore.CSSPropertyID.BorderStyle.rawValue, components.style, false)
        sink.addAllLonghands(WebCore.CSSPropertyID.BorderColor.rawValue, components.color, false)

        // `for (auto longhand : borderImageShorthand())`, in its CSSProperties.json order.
        shorthandAdd(sink, .BorderImageSource, nil)
        shorthandAdd(sink, .BorderImageSlice, nil)
        shorthandAdd(sink, .BorderImageWidth, nil)
        shorthandAdd(sink, .BorderImageOutset, nil)
        shorthandAdd(sink, .BorderImageRepeat, nil)
        return true
    }

    /// `consumeBorderInlineShorthand`.
    mutating func consumeBorderInlineShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        guard let components = consumeBorderShorthandComponents(calc) else {
            return false
        }

        sink.addAllLonghands(WebCore.CSSPropertyID.BorderInlineWidth.rawValue, components.width, false)
        sink.addAllLonghands(WebCore.CSSPropertyID.BorderInlineStyle.rawValue, components.style, false)
        sink.addAllLonghands(WebCore.CSSPropertyID.BorderInlineColor.rawValue, components.color, false)
        return true
    }

    /// `consumeBorderBlockShorthand`.
    mutating func consumeBorderBlockShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        guard let components = consumeBorderShorthandComponents(calc) else {
            return false
        }

        sink.addAllLonghands(WebCore.CSSPropertyID.BorderBlockWidth.rawValue, components.width, false)
        sink.addAllLonghands(WebCore.CSSPropertyID.BorderBlockStyle.rawValue, components.style, false)
        sink.addAllLonghands(WebCore.CSSPropertyID.BorderBlockColor.rawValue, components.color, false)
        return true
    }

    // MARK: - border-radius, -webkit-border-radius, border-*-radius

    /// `consumeBorderRadiusShorthand` and `consumeWebkitBorderRadiusShorthand`: consumeUnresolvedBorderRadius or its
    /// -webkit- quirk, where `a b` is `a / b` (consumeBorderRadius, which consumes to the end or fails), then the four
    /// corners, each `createCSSValue` of a MinimallySerializingSpaceSeparatedSize: a coalescing pair.
    /// <length-percentage [0,∞]>{1,4} [ / <length-percentage [0,∞]>{1,4} ]?
    mutating func consumeBorderRadiusShorthand(_ sink: borrowing ShorthandSink, webkit: Bool, _ calc: PropertyCalc) -> Bool {
        var horizontal = InlineArray<4, PropertyValue?>(repeating: nil)
        var count = 0
        while count < 4 && !atEnd && peekType() != PropertyTokenType.delimiter {
            guard let radius = primitive(borderRadius, calc) else {
                return false
            }
            horizontal[count] = radius
            count += 1
        }
        guard count != 0 else {
            return false
        }
        var vertical = horizontal
        if atEnd {
            if webkit && count == 2 {
                vertical = [horizontal[1], nil, nil, nil]
                horizontal[1] = nil
            }
        } else {
            guard consumeSlash() else {
                return false
            }
            vertical = InlineArray(repeating: nil)
            var verticalCount = 0
            while verticalCount < 4 && !atEnd {
                guard let radius = primitive(borderRadius, calc) else {
                    return false
                }
                vertical[verticalCount] = radius
                verticalCount += 1
            }
            guard verticalCount != 0, atEnd else {
                return false
            }
        }
        // completeQuadFromArray: absent radii complete the present ones.
        let h = completeRadii(horizontal)
        let v = completeRadii(vertical)
        shorthandAdd(sink, .BorderTopLeftRadius, makePair(h.0, v.0, coalescing: true))
        shorthandAdd(sink, .BorderTopRightRadius, makePair(h.1, v.1, coalescing: true))
        shorthandAdd(sink, .BorderBottomRightRadius, makePair(h.2, v.2, coalescing: true))
        shorthandAdd(sink, .BorderBottomLeftRadius, makePair(h.3, v.3, coalescing: true))
        return true
    }

    /// `CSS::LengthPercentage<Nonnegative>`, a radius.
    private var borderRadius: PropertyPrimitive {
        PropertyPrimitive(.lengthPercentage, min: 0)
    }

    /// `completeQuadFromArray` of 1-4 present radii: top-right and bottom-right default to top-left, bottom-left to
    /// top-right.
    private func completeRadii(_ radii: InlineArray<4, PropertyValue?>) -> (PropertyValue, PropertyValue, PropertyValue, PropertyValue) {
        guard let topLeft = radii[0] else {
            preconditionFailure()
        }
        let topRight = radii[1] ?? topLeft
        return (topLeft, topRight, radii[2] ?? topLeft, radii[3] ?? topRight)
    }

    mutating func consumeBorderRadiusShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBorderRadiusShorthand(sink, webkit: false, calc)
    }

    mutating func consumeWebkitBorderRadiusShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBorderRadiusShorthand(sink, webkit: true, calc)
    }

    /// `consumeBorderRadiusSideShorthand`: consumeUnresolvedBorderRadiusSide,
    /// <length-percentage [0,∞]>{1,2} [ / <length-percentage [0,∞]>{1,2} ]?, then the shorthand's two longhands in its
    /// order, each a coalescing pair; an absent second radius is the first.
    mutating func consumeBorderRadiusSideShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(longhands.count == 2)
        guard let first = primitive(borderRadius, calc) else {
            return false
        }
        let second = primitive(borderRadius, calc) ?? first
        var verticalFirst = first
        var verticalSecond = second
        if !atEnd {
            guard consumeSlash(), let radius = primitive(borderRadius, calc) else {
                return false
            }
            verticalFirst = radius
            verticalSecond = primitive(borderRadius, calc) ?? radius
            guard atEnd else {
                return false
            }
        }
        shorthandAdd(sink, longhands[0], makePair(first, verticalFirst, coalescing: true))
        shorthandAdd(sink, longhands[1], makePair(second, verticalSecond, coalescing: true))
        return true
    }

    // MARK: - corner, corner-*, corner-*-*

    /// `CornerShorthandHelpers::consumeCornerShorthandOfSize<N>` for the `corner-*` shorthand family:
    /// `<'border-radius'> || <'corner-shape'>`, `<'border-top-radius'> || <'corner-top-shape'>`, or
    /// `<'border-top-left-radius'> || <'corner-top-left-shape'>`, depending on the shorthand's size.
    ///
    /// Longhands: [radius_0, …, radius_{N-1}, shape_0, …, shape_{N-1}] where N = longhands.count / 2.
    /// Either component may be omitted; an omitted radius is `0px` and an omitted shape is `round`.
    mutating func consumeCornerShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let n = longhands.count / 2
        assert(n == 1 || n == 2 || n == 4)
        let shapeProperty = longhands[n]

        // `radii[i]` holds (horizontal, vertical) for corner i.
        var radii: [(PropertyValue, PropertyValue)]? = nil
        // `shapes[i]` holds the shape for corner i.
        var shapes: [PropertyValue]? = nil

        // `<radius> || <shape>`: the two components may appear in either order and either may be omitted.
        while !atEnd {
            if radii == nil {
                let savedIndex = index
                if let r = tryConsumeCornerRadii(n, calc) {
                    radii = r
                    continue
                }
                index = savedIndex
            }
            if shapes == nil {
                let savedIndex = index
                if let s = tryConsumeCornerShapes(n, shapeProperty, calc) {
                    shapes = s
                    continue
                }
                index = savedIndex
            }
            break
        }

        guard radii != nil || shapes != nil, atEnd else {
            return false
        }

        let zero: PropertyValue = WebCore.CSSPrimitiveValue.create(0, .Px).get()
        let zeroRadius = makePair(zero, zero, coalescing: true)
        let roundShape = keywordValue(.Round)
        for i in 0..<n {
            if let r = radii {
                shorthandAdd(sink, longhands[i], makePair(r[i].0, r[i].1, coalescing: true))
            } else {
                shorthandAdd(sink, longhands[i], zeroRadius)
            }
            shorthandAdd(sink, longhands[n + i], shapes?[i] ?? roundShape)
        }
        return true
    }

    /// `CornerShorthandHelpers::consumeCornerRadii<N>`: the N corner radii from the matching border-radius consumer.
    ///
    /// For N=1, `consumeUnresolvedBorderRadiusCorner`: `<length-percentage [0,∞]>{1,2}`, or the slash form
    /// `<length-percentage [0,∞]> / <length-percentage [0,∞]>`. For N=2,
    /// `consumeUnresolvedBorderRadiusSide`: two corners, the second optional. For N=4,
    /// `consumeUnresolvedBorderRadius`: 1–4 horizontal, optionally `/` and 1–4 vertical.
    /// Stops where the tokens stop looking like radii; the caller rejects what is left.
    private mutating func tryConsumeCornerRadii(_ n: Int, _ calc: PropertyCalc) -> [(PropertyValue, PropertyValue)]? {
        switch n {
        case 1:
            guard let h = primitive(borderRadius, calc) else { return nil }
            if consumeSlash() {
                guard let v = primitive(borderRadius, calc) else { return nil }
                return [(h, v)]
            }
            let v = primitive(borderRadius, calc) ?? h
            return [(h, v)]
        case 2:
            guard let h0 = primitive(borderRadius, calc) else { return nil }
            let h1 = primitive(borderRadius, calc) ?? h0
            if consumeSlash() {
                guard let v0 = primitive(borderRadius, calc) else { return nil }
                let v1 = primitive(borderRadius, calc) ?? v0
                return [(h0, v0), (h1, v1)]
            }
            return [(h0, h0), (h1, h1)]
        default: // n == 4
            var horizontal = InlineArray<4, PropertyValue?>(repeating: nil)
            var count = 0
            while count < 4 {
                guard let r = primitive(borderRadius, calc) else { break }
                horizontal[count] = r
                count += 1
            }
            guard count != 0 else { return nil }
            let h = completeRadii(horizontal)
            if !consumeSlash() {
                return [(h.0, h.0), (h.1, h.1), (h.2, h.2), (h.3, h.3)]
            }
            var vertical = InlineArray<4, PropertyValue?>(repeating: nil)
            var verticalCount = 0
            while verticalCount < 4 {
                guard let r = primitive(borderRadius, calc) else { break }
                vertical[verticalCount] = r
                verticalCount += 1
            }
            guard verticalCount != 0 else { return nil }
            let v = completeRadii(vertical)
            return [(h.0, v.0), (h.1, v.1), (h.2, v.2), (h.3, v.3)]
        }
    }

    /// `CornerShorthandHelpers::consumeCornerShapes<N>`: 1–N shapes, completed by the corner copy rules.
    /// The copy rules match `completeQuadFromArray`: [0] fills [1] and [2]; [1] fills [3].
    private mutating func tryConsumeCornerShapes(_ n: Int, _ shapeProperty: WebCore.CSSPropertyID, _ calc: PropertyCalc) -> [PropertyValue]? {
        var shapes = [PropertyValue]()
        for _ in 0..<n {
            guard let s = parseStylePropertyLonghand(shapeProperty, calc) else { break }
            shapes.append(s)
        }
        guard !shapes.isEmpty else { return nil }
        if shapes.count < n {
            let first = shapes[0]
            let second = shapes.count > 1 ? shapes[1] : first
            while shapes.count < n {
                shapes.append(shapes.count < 3 ? first : second)
            }
        }
        return shapes
    }

    // MARK: - border-image, -webkit-border-image, mask-border, -webkit-mask-box-image

    /// `consumeBorderImageShorthand` and `consumeWebkitBorderImageShorthand` (the legacy slice
    /// `fill` and the legacy width that sets the border widths): consumeUnresolvedBorderImage
    /// (consumeBorderImageParts, which consumes to the end or fails), then the five longhands.
    mutating func consumeBorderImageShorthand(_ sink: borrowing ShorthandSink, webkit: Bool) -> Bool {
        var parts = WebCore.CSSImageSwiftParts()
        guard consumeBorderImageParts(&parts, alwaysFill: webkit) else {
            return false
        }
        let options = webkit ? UInt8(WebCore.CSSPropertyConsumerSwiftBorderImageWidthOverridesWidthForLength) : 0
        WebCore.addBorderImageLonghandsForSwift(sink, options, consuming: consume parts)
        return true
    }

    mutating func consumeBorderImageShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBorderImageShorthand(sink, webkit: false)
    }

    mutating func consumeWebkitBorderImageShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBorderImageShorthand(sink, webkit: true)
    }

    /// `consumeMaskBorderShorthand` and `consumeWebkitMaskBoxImageShorthand` (the legacy slice `fill`, and an absent
    /// slice `0 fill`): consumeUnresolvedMaskBorder (consumeBorderImageComponents), then the five longhands, each the
    /// longhand's value (makeMaskBorderLonghandValue) or, for an absent part, the implicit initial value (null).
    mutating func consumeMaskBorderShorthand(_ sink: borrowing ShorthandSink, webkit: Bool) -> Bool {
        guard var parts = consumeBorderImageComponents(alwaysFill: webkit) else {
            return false
        }
        typealias Consumer = WebCore.CSSPropertyConsumerSwiftConsumer
        let none = WebCore.CSSColorSwiftComponents()
        let source = parts.source.map { WebCore.makeMaskBorderLonghandValue(Consumer.MaskBorderSource.rawValue, none, 0, $0.image).get() }
        shorthandAdd(sink, .MaskBorderSource, source)
        if webkit && parts.slice.type(0) == 0 {
            parts.slice.setValue(0, UInt8(WebCore.CSSColorSwiftChannelNumber), 0, 0)
            parts.fill.setSymbol(0, WebCore.CSSValueID.Fill.rawValue)
        }
        let slice =
            parts.slice.type(0) == 0
            ? nil
            : WebCore.makeMaskBorderLonghandValue(Consumer.MaskBorderSlice.rawValue, parts.slice, parts.fill.type(0) != 0 ? 1 : 0, nil)
                .get()
        shorthandAdd(sink, .MaskBorderSlice, slice)
        let width =
            parts.width.type(0) == 0
            ? nil : WebCore.makeMaskBorderLonghandValue(Consumer.MaskBorderWidth.rawValue, parts.width, 0, nil).get()
        shorthandAdd(sink, .MaskBorderWidth, width)
        let outset =
            parts.outset.type(0) == 0
            ? nil : WebCore.makeMaskBorderLonghandValue(Consumer.MaskBorderOutset.rawValue, parts.outset, 0, nil).get()
        shorthandAdd(sink, .MaskBorderOutset, outset)
        let rules =
            parts.rulesCount == 0
            ? nil
            : WebCore.makeMaskBorderLonghandValue(Consumer.MaskBorderRepeat.rawValue, parts.rules, parts.rulesCount, nil).get()
        shorthandAdd(sink, .MaskBorderRepeat, rules)
        return true
    }

    mutating func consumeMaskBorderShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeMaskBorderShorthand(sink, webkit: false)
    }

    mutating func consumeWebkitMaskBoxImageShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeMaskBorderShorthand(sink, webkit: true)
    }
}
