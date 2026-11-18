// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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
//
// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
// Copyright (C) 2013 Google Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2013 Google Inc. All rights reserved.
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT

import CoreGraphics
@_spi(WebKitGPU) internal import WebCore
import WebCore_Private
import WebKit_Internal

// A filter that RemoteResourceCache cached for the C++ contexts (RemoteRenderingBackend::cacheFilter()), as the Swift draws of
// the SVG filters that name it keep it: the filter of the first draw that names it, into which the later draws merge their
// effects (SVGFilterRenderer::mergeEffects()), and the results of its effects (SVGFilterRenderer::ensureResults()). The
// web process caches a filter as it first draws it, so the first draw's filter is the one cached.
final class RemoteCGRendererCachedFilter {
    let identifier: UInt64
    // Whether RemoteResourceCache's filter is an SVG filter, which a draw names only if it is.
    let isSVGFilter: Bool
    private var filter: IPCTypes.SVGFilterRenderer?
    // The filter's description while it has no FEImage, whose images a draw looks up again; a merge that changes an effect
    // forgets it.
    private var description: SVGFilterDescription?
    private var results = FilterResultsState()
    private var allocator: WebCore.FilterImageAllocator?

    init(identifier: UInt64, isSVGFilter: Bool) {
        self.identifier = identifier
        self.isSVGFilter = isSVGFilter
    }

    // The filter with a draw's effects merged in, forgetting the results of the effects that changed and of those made from
    // them: nil if it isn't an SVG filter, or if the draw's filter has another number of effects.
    func merge(_ drawn: IPCTypes.SVGFilterRenderer) -> IPCTypes.SVGFilterRenderer? {
        guard isSVGFilter else {
            return nil
        }
        guard var merged = filter else {
            filter = drawn
            return drawn
        }
        guard merged.effects.count == drawn.effects.count else {
            return nil
        }
        for index in merged.effects.indices where merged.effects[index] != drawn.effects[index] {
            results.clearEffectResult(UInt(identifier), UInt32(index))
            merged.effects[index] = drawn.effects[index]
            description = nil
        }
        filter = merged
        return merged
    }

    // The description of the merged filter (merge()): the one it keeps, or a new one, which it keeps if the filter has no FEImage.
    // `drawnEffects`: the draw's effects, already described, which are the merged filter's. Nil if an FEImage's image is missing.
    func describe(
        _ merged: IPCTypes.SVGFilterRenderer,
        _ describer: RemoteCGRendererFilterDescriber,
        drawnEffects: [FilterEffectDescription]? = nil
    ) -> SVGFilterDescription? {
        if let description {
            return description
        }
        guard let effects = drawnEffects ?? describer.describeEffects(merged.effects) else {
            return nil
        }
        let described = describer.describe(merged, identifier: UInt(identifier), effects: effects)
        if !merged.hasFEImage {
            description = described
        }
        return described
    }

    // Applies the described filter with its results, whose images the backend's shared resource cache allocates.
    func apply(
        _ filter: borrowing SVGFilterDescription,
        _ sourceImage: WebCore.ImageBuffer?,
        _ sourceImageRect: WebCore.FloatRect,
        _ resources: RemoteCGRendererResources,
        _ absoluteImageRect: inout WebCore.IntRect
    ) -> WebCore.ImageBuffer? {
        let allocator = self.allocator ?? resources.filterImageAllocator(forReplay: false)
        self.allocator = allocator
        return applySVGFilter(filter, sourceImage, sourceImageRect, allocator, &results, true, &absoluteImageRect)
    }
}

// The descriptions of a DrawFilteredImageBuffer's filter that WebCore's Swift filter engine applies, as the C++ filters that
// IPC makes would apply: their effects, with their FEImage images looked up, and what applying them takes, as the C++
// filters derive it.
struct RemoteCGRendererFilterDescriber {
    // The renderer's descriptions of the effects of the filters it drew last.
    let descriptions: RemoteCGRendererFilterDescriptions
    // The native image or image buffer that an FEImage names: nil if there is neither, which is an invalid message.
    let imageSource: (UInt64) -> FilterImageSource?

    func describe(_ filter: IPCTypes.CSSFilterRenderer) -> CSSFilterDescription? {
        let geometry = filter.geometry
        let filterRegion = floatRect(geometry.filterRegion)
        let applyToSVGRenderer = filter.renderingOptions.contains(.applyToSVGRenderer)
        var enclosingFilterRegion = filterRegion
        #if USE_CORE_IMAGE
        // CSSFilterRenderer::computeEnclosingFilterRegion(), which propagates the region to the SVG filters.
        if applyToSVGRenderer {
            var svgFilterRegions: [WebCore.FloatRect] = []
            for case .svgFilterRenderer(let svgFilter) in filter.functions {
                svgFilterRegions.append(floatRect(svgFilter.geometry.filterRegion))
            }
            enclosingFilterRegion = describedCSSFilterEnclosingFilterRegion(filterRegion, svgFilterRegions)
        }
        #endif

        guard let (functionEffects, supportsAcceleratedRendering) = describeFunctionEffects(filter.functions) else {
            return nil
        }
        var functions: [CSSFilterFunctionDescription?] = []
        functions.reserveCapacity(filter.functions.count)
        for (index, function) in filter.functions.enumerated() {
            if case .svgFilterRenderer(let svgFilter) = function {
                let svgEnclosingFilterRegion: WebCore.FloatRect? = applyToSVGRenderer ? enclosingFilterRegion : nil
                // Identifies the SVG filter apart from the CSS filter (0) to their FilterResults.
                functions.append(.svgFilter(describe(
                    svgFilter,
                    identifier: UInt(index) + 1,
                    effects: functionEffects[index],
                    enclosingFilterRegion: svgEnclosingFilterRegion
                )))
            } else {
                functions.append(.effect(functionEffects[index][0]))
            }
        }

        let renderer = describedFilterRendererParameters(
            referenceBox: floatRect(geometry.referenceBox),
            filterRegion: filterRegion,
            scale: floatSize(geometry.scale),
            clampsFilterScale: true,
            enclosingFilterRegion: enclosingFilterRegion,
            preferredRenderingModes: filter.filterRenderingModes.rawValue,
            renderingOptions: filter.renderingOptions.rawValue,
            primitiveUnitsAreObjectBoundingBox: false,
            hasEffects: !functions.isEmpty,
            effectsSupportAcceleratedRendering: supportsAcceleratedRendering
        )
        return CSSFilterDescription(identifier: 0, renderer: renderer, functions: functions)
    }

    // `enclosingFilterRegion`: the region that a CSS filter that references the SVG filter propagates to it.
    func describe(_ filter: IPCTypes.SVGFilterRenderer, identifier: UInt, enclosingFilterRegion: WebCore.FloatRect? = nil) -> SVGFilterDescription? {
        guard let effects = describeEffects(filter.effects) else {
            return nil
        }
        return describe(filter, identifier: identifier, effects: effects, enclosingFilterRegion: enclosingFilterRegion)
    }

    // The effects of a CSS filter's functions: each one's effect, or its SVG filter's effects, and whether all of them can be
    // applied in Accelerated mode.
    private func describeFunctionEffects(_ functions: [IPCTypes.FilterFunction]) -> ([[FilterEffectDescription]], Bool)? {
        if let cached = descriptions.cssFunctions, cached.functions == functions {
            return (cached.effects, cached.accelerated)
        }
        var effects: [[FilterEffectDescription]] = []
        effects.reserveCapacity(functions.count)
        var hasFEImage = false
        for function in functions {
            if case .svgFilterRenderer(let svgFilter) = function {
                guard let described = describeNewEffects(svgFilter.effects) else {
                    return nil
                }
                hasFEImage = hasFEImage || svgFilter.hasFEImage
                effects.append(described)
                continue
            }
            if case .feImage = function {
                hasFEImage = true
            }
            guard let effect = describe(function) else {
                return nil
            }
            effects.append([effect])
        }
        let accelerated = effects.allSatisfy { $0.allSatisfy(\.supportsAcceleratedRendering) }
        descriptions.cssFunctions = hasFEImage ? nil : (functions, effects, accelerated)
        return (effects, accelerated)
    }

    // The effects of an SVG filter, which a draw of a cached SVG filter describes before it merges them.
    func describeEffects(_ effects: [IPCTypes.FilterEffect]) -> [FilterEffectDescription]? {
        if let cached = descriptions.svgEffects, cached.effects == effects {
            return cached.described
        }
        guard let described = describeNewEffects(effects) else {
            return nil
        }
        let hasFEImage = effects.contains { effect in
            if case .feImage = effect {
                return true
            }
            return false
        }
        descriptions.svgEffects = hasFEImage ? nil : (effects, described)
        return described
    }

    private func describeNewEffects(_ effects: [IPCTypes.FilterEffect]) -> [FilterEffectDescription]? {
        var described: [FilterEffectDescription] = []
        described.reserveCapacity(effects.count)
        for effect in effects {
            guard let effect = describeEffect(effect) else {
                return nil
            }
            described.append(effect)
        }
        return described
    }

    func describe(
        _ filter: IPCTypes.SVGFilterRenderer,
        identifier: UInt,
        effects: [FilterEffectDescription],
        enclosingFilterRegion: WebCore.FloatRect? = nil
    ) -> SVGFilterDescription {
        let geometry = filter.geometry
        let filterRegion = floatRect(geometry.filterRegion)
        let terms = filter.expression.map { term in
            SVGFilterTermDescription(effectIndex: term.index, geometry: geometryValues(term.geometry))
        }
        let renderer = describedFilterRendererParameters(
            referenceBox: floatRect(geometry.referenceBox),
            filterRegion: filterRegion,
            scale: floatSize(geometry.scale),
            clampsFilterScale: false,
            enclosingFilterRegion: enclosingFilterRegion ?? filterRegion,
            preferredRenderingModes: filter.filterRenderingModes.rawValue,
            renderingOptions: filter.renderingOptions.rawValue,
            primitiveUnitsAreObjectBoundingBox: filter.primitiveUnits.rawValue == svgUnitTypeObjectBoundingBox,
            hasEffects: !effects.isEmpty,
            effectsSupportAcceleratedRendering: effects.allSatisfy(\.supportsAcceleratedRendering)
        )
        return SVGFilterDescription(identifier: identifier, renderer: renderer, terms: terms, effects: effects)
    }

    // A CSS filter's function that is an effect.
    private func describe(_ function: IPCTypes.FilterFunction) -> FilterEffectDescription? {
        switch function {
        case .svgFilterRenderer:
            preconditionFailure("A CSS filter's SVG filters are described as filters")
        case .feBlend(let effect):
            return describeEffect(.feBlend(effect))
        case .feColorMatrix(let effect):
            return describeEffect(.feColorMatrix(effect))
        case .feComponentTransfer(let effect):
            return describeEffect(.feComponentTransfer(effect))
        case .feComposite(let effect):
            return describeEffect(.feComposite(effect))
        case .feConvolveMatrix(let effect):
            return describeEffect(.feConvolveMatrix(effect))
        case .feDiffuseLighting(let effect):
            return describeEffect(.feDiffuseLighting(effect))
        case .feDisplacementMap(let effect):
            return describeEffect(.feDisplacementMap(effect))
        case .feDropShadow(let effect):
            return describeEffect(.feDropShadow(effect))
        case .feFlood(let effect):
            return describeEffect(.feFlood(effect))
        case .feGaussianBlur(let effect):
            return describeEffect(.feGaussianBlur(effect))
        case .feImage(let effect):
            return describeEffect(.feImage(effect))
        case .feMerge(let effect):
            return describeEffect(.feMerge(effect))
        case .feMorphology(let effect):
            return describeEffect(.feMorphology(effect))
        case .feOffset(let effect):
            return describeEffect(.feOffset(effect))
        case .feSpecularLighting(let effect):
            return describeEffect(.feSpecularLighting(effect))
        case .feTile(let effect):
            return describeEffect(.feTile(effect))
        case .feTurbulence(let effect):
            return describeEffect(.feTurbulence(effect))
        case .sourceAlpha(let effect):
            return describeEffect(.sourceAlpha(effect))
        case .sourceGraphic(let effect):
            return describeEffect(.sourceGraphic(effect))
        }
    }

    // The effect as the C++ FilterEffect that IPC makes of it is: its constructor's normalizations are its description's.
    private func describeEffect(_ effect: IPCTypes.FilterEffect) -> FilterEffectDescription? {
        switch effect {
        case .feBlend(let blend):
            var parameters = WebCore.FEBlendParameters()
            parameters.mode = blend.blendMode
            return described(.blend(parameters), blend.operatingColorSpace)
        case .feColorMatrix(let colorMatrix):
            return described(.colorMatrix(FEColorMatrixValues(type: colorMatrix.type, values: colorMatrix.values)), colorMatrix.operatingColorSpace)
        case .feComponentTransfer(let transfer):
            let parameters = FEComponentTransferValues(
                red: transferFunction(transfer.redFunction),
                green: transferFunction(transfer.greenFunction),
                blue: transferFunction(transfer.blueFunction),
                alpha: transferFunction(transfer.alphaFunction)
            )
            return described(.componentTransfer(parameters), transfer.operatingColorSpace)
        case .feComposite(let composite):
            var parameters = WebCore.FECompositeParameters()
            parameters.operation = composite.operation
            parameters.k1 = composite.k1
            parameters.k2 = composite.k2
            parameters.k3 = composite.k3
            parameters.k4 = composite.k4
            return described(.composite(parameters), composite.operatingColorSpace)
        case .feConvolveMatrix(let convolve):
            let parameters = FEConvolveMatrixValues(
                kernelSize: WebCore.IntSize(convolve.kernelSize.width, convolve.kernelSize.height),
                divisor: convolve.divisor,
                bias: convolve.bias,
                targetOffset: WebCore.IntPoint(convolve.targetOffset.x, convolve.targetOffset.y),
                edgeMode: convolve.edgeMode,
                preserveAlpha: convolve.preserveAlpha,
                kernel: convolve.kernel
            )
            return described(.convolveMatrix(parameters), convolve.operatingColorSpace)
        case .feDiffuseLighting(let lighting):
            // FEDiffuseLighting: no specular constant, and the smallest specular exponent.
            var parameters = WebCore.FELightingParameters()
            parameters.type = .Diffuse
            parameters.surfaceScale = lighting.surfaceScale
            parameters.diffuseConstant = lighting.diffuseConstant
            parameters.specularConstant = 0
            parameters.specularExponent = 1
            parameters.kernelUnitLengthX = lighting.kernelUnitLengthX
            parameters.kernelUnitLengthY = lighting.kernelUnitLengthY
            return describedLighting(parameters, lighting.lightSource, lighting.lightingColor, lighting.operatingColorSpace)
        case .feSpecularLighting(let lighting):
            // FESpecularLighting: no diffuse constant.
            var parameters = WebCore.FELightingParameters()
            parameters.type = .Specular
            parameters.surfaceScale = lighting.surfaceScale
            parameters.diffuseConstant = 0
            parameters.specularConstant = lighting.specularConstant
            parameters.specularExponent = lighting.specularExponent
            parameters.kernelUnitLengthX = lighting.kernelUnitLengthX
            parameters.kernelUnitLengthY = lighting.kernelUnitLengthY
            return describedLighting(parameters, lighting.lightSource, lighting.lightingColor, lighting.operatingColorSpace)
        case .feDisplacementMap(let displacement):
            var parameters = WebCore.FEDisplacementMapParameters()
            parameters.xChannelSelector = displacement.xChannelSelector
            parameters.yChannelSelector = displacement.yChannelSelector
            parameters.scale = displacement.scale
            parameters.in2IsTainted = displacement.in2IsTainted
            return described(.displacementMap(parameters), displacement.operatingColorSpace)
        case .feDropShadow(let shadow):
            let colorSpace = FilterEffectDescription.colorSpace(shadow.operatingColorSpace.cgColorSpace)
            let shadowColor = FilterEffectDescription.color(shadow.shadowColor.cgRendererColorData)
            var parameters = WebCore.FEDropShadowParameters()
            parameters.stdDeviationX = shadow.stdDeviationX
            parameters.stdDeviationY = shadow.stdDeviationY
            parameters.dx = shadow.dx
            parameters.dy = shadow.dy
            parameters.shadowColor = shadowColor
            parameters.shadowOpacity = shadow.shadowOpacity
            let components = FilterEffectDescription.colorComponents(shadowColor, opacity: shadow.shadowOpacity, in: colorSpace)
            return described(.dropShadow(parameters, shadowColor: components), colorSpace)
        case .feFlood(let flood):
            let colorSpace = FilterEffectDescription.colorSpace(flood.operatingColorSpace.cgColorSpace)
            let floodColor = FilterEffectDescription.color(flood.floodColor.cgRendererColorData)
            var parameters = WebCore.FEFloodParameters()
            parameters.floodColor = floodColor
            parameters.floodOpacity = flood.floodOpacity
            let components = FilterEffectDescription.colorComponents(floodColor, opacity: flood.floodOpacity, in: colorSpace)
            return described(.flood(parameters, floodColor: components), colorSpace)
        case .feGaussianBlur(let blur):
            var parameters = WebCore.FEGaussianBlurParameters()
            parameters.stdDeviationX = blur.stdDeviationX
            parameters.stdDeviationY = blur.stdDeviationY
            parameters.edgeMode = blur.edgeMode
            return described(.gaussianBlur(parameters), blur.operatingColorSpace)
        case .feImage(let image):
            // FEImage has no operating color space of its own: FilterEffect's sRGB.
            guard let source = imageSource(image.sourceImage.imageIdentifier.rawValue) else {
                return nil
            }
            var parameters = WebCore.FEImageParameters()
            parameters.sourceImageRect = floatRect(image.sourceImageRect)
            return FilterEffectDescription(
                .image(parameters, source),
                operatingColorSpace: FilterEffectDescription.sRGBColorSpace,
                operatingColorSpaceIsSRGB: true
            )
        case .feMerge(let merge):
            return described(.merge(inputCount: merge.numberOfEffectInputs), merge.operatingColorSpace)
        case .feMorphology(let morphology):
            var parameters = WebCore.FEMorphologyParameters()
            parameters.type = morphology.morphologyOperator
            parameters.radiusX = morphology.radiusX
            parameters.radiusY = morphology.radiusY
            return described(.morphology(parameters), morphology.operatingColorSpace)
        case .feOffset(let offset):
            var parameters = WebCore.FEOffsetParameters()
            parameters.dx = offset.dx
            parameters.dy = offset.dy
            return described(.offset(parameters), offset.operatingColorSpace)
        case .feTile(let tile):
            return described(.tile, tile.operatingColorSpace)
        case .feTurbulence(let turbulence):
            var parameters = WebCore.FETurbulenceParameters()
            parameters.type = turbulence.type
            parameters.baseFrequencyX = turbulence.baseFrequencyX
            parameters.baseFrequencyY = turbulence.baseFrequencyY
            parameters.numOctaves = turbulence.numOctaves
            parameters.seed = turbulence.seed
            parameters.stitchTiles = turbulence.stitchTiles
            return described(.turbulence(parameters), turbulence.operatingColorSpace)
        case .sourceAlpha(let sourceAlpha):
            return described(.sourceAlpha, sourceAlpha.operatingColorSpace)
        case .sourceGraphic(let sourceGraphic):
            return described(.sourceGraphic, sourceGraphic.operatingColorSpace)
        }
    }

    private func described(_ parameters: FilterEffectParameters, _ colorSpace: IPCTypes.ColorSpace) -> FilterEffectDescription {
        described(parameters, FilterEffectDescription.colorSpace(colorSpace.cgColorSpace))
    }

    private func described(_ parameters: FilterEffectParameters, _ colorSpace: WebCore.ColorSpace) -> FilterEffectDescription {
        FilterEffectDescription(
            parameters,
            operatingColorSpace: colorSpace,
            operatingColorSpaceIsSRGB: FilterEffectDescription.colorSpaceIsSRGB(colorSpace)
        )
    }

    // LightSource::parameters() of the light source, and the lighting color in the operating color space.
    private func describedLighting(
        _ parameters: WebCore.FELightingParameters,
        _ lightSource: IPCTypes.LightSource,
        _ lightingColor: IPCTypes.WebCoreColor,
        _ operatingColorSpace: IPCTypes.ColorSpace
    ) -> FilterEffectDescription {
        let colorSpace = FilterEffectDescription.colorSpace(operatingColorSpace.cgColorSpace)
        var light = WebCore.LightSourceParameters()
        switch lightSource {
        case .distantLightSource(let distant):
            light.type = .Distant
            light.azimuth = distant.azimuth
            light.elevation = distant.elevation
        case .pointLightSource(let point):
            light.type = .Point
            light.position = floatPoint3D(point.position)
        case .spotLightSource(let spot):
            light.type = .Spot
            light.position = floatPoint3D(spot.position)
            light.pointsAt = floatPoint3D(spot.direction)
            light.specularExponent = spot.specularExponent
            light.limitingConeAngle = spot.limitingConeAngle
        }
        let color = FilterEffectDescription.color(lightingColor.cgRendererColorData)
        let components = FilterEffectDescription.colorComponents(color, in: colorSpace)
        return described(.lighting(parameters, lightSource: light, lightingColor: components), colorSpace)
    }

    private func transferFunction(_ function: IPCTypes.ComponentTransferFunction) -> ComponentTransferFunctionValues {
        ComponentTransferFunctionValues(
            type: function.type,
            slope: function.slope,
            intercept: function.intercept,
            amplitude: function.amplitude,
            exponent: function.exponent,
            offset: function.offset,
            tableValues: function.tableValues
        )
    }

    // filterEffectGeometryValues(): the x, y, width and height that the primitive sets, 0 for those it doesn't.
    private func geometryValues(_ geometry: IPCTypes.FilterEffectGeometry?) -> WebCore.FilterEffectGeometryValues {
        var values = WebCore.FilterEffectGeometryValues()
        guard let geometry else {
            return values
        }
        let boundaries = geometry.boundaries
        values.hasGeometry = true
        values.hasX = geometry.flags.contains(.hasX)
        values.hasY = geometry.flags.contains(.hasY)
        values.hasWidth = geometry.flags.contains(.hasWidth)
        values.hasHeight = geometry.flags.contains(.hasHeight)
        values.boundaries = WebCore.FloatRect(
            values.hasX ? boundaries.location.x : 0,
            values.hasY ? boundaries.location.y : 0,
            values.hasWidth ? boundaries.size.width : 0,
            values.hasHeight ? boundaries.size.height : 0
        )
        return values
    }
}

// SVGUnitTypes::SVG_UNIT_TYPE_OBJECTBOUNDINGBOX.
private let svgUnitTypeObjectBoundingBox: UInt8 = 2

func floatRect(_ rect: IPCTypes.FloatRect) -> WebCore.FloatRect {
    WebCore.FloatRect(rect.location.x, rect.location.y, rect.size.width, rect.size.height)
}

private func floatSize(_ size: IPCTypes.FloatSize) -> WebCore.FloatSize {
    WebCore.FloatSize(size.width, size.height)
}

private func floatPoint3D(_ point: IPCTypes.FloatPoint3D) -> WebCore.FloatPoint3D {
    WebCore.FloatPoint3D(point.x, point.y, point.z)
}

// The descriptions of the effects of the filters that a renderer drew last, which the next draw of a filter with equal effects
// reuses: describing an effect makes its ColorSpace and its colors, while a filter's geometry, from which what applying it
// takes is derived again for each draw, changes from draw to draw. A filter with an FEImage, whose image a draw looks up
// again, isn't kept.
final class RemoteCGRendererFilterDescriptions {
    // A CSS filter's functions, with the description of each one's effect, or of its SVG filter's effects, and whether all
    // of them can be applied in Accelerated mode.
    fileprivate var cssFunctions: (functions: [IPCTypes.FilterFunction], effects: [[FilterEffectDescription]], accelerated: Bool)?
    // An SVG filter's effects.
    fileprivate var svgEffects: (effects: [IPCTypes.FilterEffect], described: [FilterEffectDescription])?
}

extension IPCTypes.SVGFilterRenderer {
    var hasFEImage: Bool {
        effects.contains { effect in
            if case .feImage = effect {
                return true
            }
            return false
        }
    }
}

extension IPCTypes.Filter {
    // The identifiers of the native images and image buffers that the filter's FEImages name, which a recording keeps.
    var feImageIdentifiers: [UInt64] {
        var identifiers: [UInt64] = []
        func add(_ effects: [IPCTypes.FilterEffect]) {
            for case .feImage(let image) in effects {
                identifiers.append(image.sourceImage.imageIdentifier.rawValue)
            }
        }
        switch self {
        case .cssFilterRenderer(let cssFilter):
            for function in cssFilter.functions {
                switch function {
                case .svgFilterRenderer(let svgFilter):
                    add(svgFilter.effects)
                case .feImage(let image):
                    identifiers.append(image.sourceImage.imageIdentifier.rawValue)
                default:
                    break
                }
            }
        case .svgFilterRenderer(let svgFilter):
            add(svgFilter.effects)
        }
        return identifiers
    }
}

#endif // ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
