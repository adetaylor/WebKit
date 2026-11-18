// Copyright (C) 2025 Apple Inc. All rights reserved.
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

#if ENABLE_IPC_TESTING_API && ENABLE_IPC_TESTING_SWIFT

import WebKit_Internal
import wtf
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Proxy interface to test IPC activities related to receiving messages in Swift.
@_expose(Cxx)
final class IPCTesterReceiver {
    // Optional just because of an initialization order issue. Always occupied after initialization finished.
    private var messageForwarder: RefIPCTesterReceiverMessageForwarder?

    @MainActor
    private var pendingDeferredReply: CheckedContinuation<UInt64, Never>?
    @MainActor
    private var deferredReplyArgument: UInt32 = 0
    @MainActor
    private var recordedTexts: [String?] = []

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
        self.messageForwarder = WebKit.IPCTesterReceiverMessageForwarder.create(target: self)
    }

    @used
    func getMessageReceiver() -> RefIPCTesterReceiverMessageForwarder {
        guard let messageForwarder = self.messageForwarder else {
            fatalError("Unreachable - guaranteed to exist")
        }
        return messageForwarder
    }

    @MainActor
    func asyncMessage(
        connection: IPC.Connection,
        arg1: UInt32
    ) -> UInt32 {
        arg1 + 2
    }

    @MainActor
    func deferredReplyMessage(
        connection: IPC.Connection,
        arg1: UInt32
    ) async -> UInt64 {
        deferredReplyArgument = arg1
        return await withCheckedContinuation { continuation in
            pendingDeferredReply = continuation
        }
    }

    @MainActor
    func completeDeferredReply(connection: IPC.Connection, arg1: UInt32) {
        let continuation = pendingDeferredReply
        pendingDeferredReply = nil
        continuation?.resume(returning: UInt64(deferredReplyArgument) + UInt64(arg1) + 2)
    }

    // Takes C++ types, so negates the value without touching the WTF::String.
    @MainActor
    func transformInner(connection: IPC.Connection, inner: WebKit.IPCTesterInner) -> WebKit.IPCTesterInner {
        var reply = inner
        reply.value = 0 &- inner.value
        return reply
    }

    // The handlers below take Swift types, and must reply as ipcTesterTransformed() and the other
    // functions in IPCTesterPayload.h do.

    @MainActor
    func transformInnerSwift(connection: IPC.Connection, inner: IPCTypes.IPCTesterInner) -> IPCTypes.IPCTesterInner {
        Self.transformed(inner)
    }

    @MainActor
    func transformPayloadSwift(connection: IPC.Connection, payload: IPCTypes.IPCTesterPayload) -> IPCTypes.IPCTesterPayload {
        Self.transformed(payload)
    }

    @MainActor
    func transformPayloadSynchronouslySwift(
        connection: IPC.Connection,
        payload: IPCTypes.IPCTesterPayload
    ) -> IPCTypes.IPCTesterPayload {
        Self.transformed(payload)
    }

    @MainActor
    func transformNodeSwift(
        connection: IPC.Connection,
        node: IPCTypes.IPCTesterNode,
        link: IPCTypes.IPCTesterNode?
    ) -> (mirrored: IPCTypes.IPCTesterNode?, nodeCount: UInt32) {
        let nodeCount = Self.nodeCount(node) + (link.map(Self.nodeCount) ?? 0)
        return (link == nil ? nil : Self.mirrored(node), nodeCount)
    }

    @MainActor
    func describeSwift(
        connection: IPC.Connection,
        color: IPCTypes.IPCTesterColor,
        flags: IPCTypes.IPCTesterFlag,
        choice: IPCTypes.IPCTesterChoice,
        identifier: IPCTypes.IPCConnectionTesterIdentifier,
        variant: IPCTypes.IPCTesterVariant,
        flag: Bool
    ) -> String? {
        let colorName =
            switch color {
            case .red: "red"
            case .green: "green"
            case .blue: "blue"
            }
        let flagNames = [(IPCTypes.IPCTesterFlag.first, "first"), (.second, "second"), (.third, "third")]
            .filter { flags.contains($0.0) }
            .map(\.1)
        let variantDescription =
            switch variant {
            case .uint64(let value): "uint64:\(value)"
            case .string(let value): "string:\(value ?? "null")"
            case .ipcTesterInner(let value): "inner:\(value.value):\(value.label ?? "null")"
            }
        let flagsDescription = flagNames.isEmpty ? "none" : flagNames.joined(separator: "|")
        return "color=\(colorName) flags=\(flagsDescription) choice=\(choice == .yes ? "yes" : "no") "
            + "identifier=\(identifier.rawValue) variant=\(variantDescription) flag=\(flag)"
    }

    @MainActor
    func halveEvenNumberSwift(connection: IPC.Connection, value: UInt32) throws(InvalidMessage) -> UInt32 {
        try messageCheck("The number to halve must be even") {
            value.isMultiple(of: 2)
        }
        return value / 2
    }

    @MainActor
    func recordSwift(connection: IPC.Connection, text: String?) {
        recordedTexts.append(text)
    }

    @MainActor
    func takeRecordedSwift(connection: IPC.Connection) -> [String?] {
        let texts = recordedTexts
        recordedTexts = []
        return texts
    }

    @MainActor
    func clearRecordedSwift(connection: IPC.Connection) {
        recordedTexts = []
    }

    @MainActor
    func reverseAtomsSwift(connection: IPC.Connection, atoms: [String?]) -> [String?] {
        atoms.reversed()
    }

    // Hands the string to C++ and back, as a handler passing a Swift-typed argument on to C++ would.
    @MainActor
    func roundTripStringThroughCxxSwift(
        connection: IPC.Connection,
        text: String?
    ) -> (roundTripped: String?, cxxLength: UInt32, cxxIsNull: Bool, cxxIs8Bit: Bool) {
        let cxxString = IPCCoding.WTFString.cxxString(text)
        return (IPCCoding.WTFString.swiftString(cxxString), cxxString.length(), cxxString.isNull(), cxxString.is8Bit())
    }

    @MainActor
    func roundTripBufferSwift(
        connection: IPC.Connection,
        buffer: WebCore.SharedBuffer?
    ) -> (roundTripped: WebCore.SharedBuffer?, size: UInt64) {
        (buffer, UInt64(buffer?.size() ?? 0))
    }

    #if WTF_PLATFORM_COCOA
    // A ColorSpace decoded in Swift and in C++ must make alike color spaces of the same bytes.

    @MainActor
    func describeColorSpaceSwift(connection: IPC.Connection, colorSpace: IPCTypes.ColorSpace) -> String? {
        IPCCoding.WTFString.swiftString(WebKit.ipcTesterDescription(colorSpace.cgColorSpace))
    }

    @MainActor
    func describeCxxDecodedColorSpaceSwift(
        connection: IPC.Connection,
        colorSpace: CxxDecodedArguments.IPCTesterReceiver.DescribeCxxDecodedColorSpaceSwiftColorSpace
    ) -> String? {
        IPCCoding.WTFString.swiftString(WebKit.ipcTesterDescription(WebKit.ipcTesterCxxDecodedColorSpace(colorSpace)))
    }

    @MainActor
    func compareColorSpacesSwift(
        connection: IPC.Connection,
        colorSpace: IPCTypes.ColorSpace,
        cxxDecodedColorSpace: CxxDecodedArguments.IPCTesterReceiver.CompareColorSpacesSwiftCxxDecodedColorSpace
    ) -> Bool {
        colorSpace.cgColorSpace == WebKit.ipcTesterCxxDecodedColorSpace(cxxDecodedColorSpace)
    }

    // A control part and style, and a system image, decoded in Swift and in C++ must be described alike: as
    // ipcTesterDescription() describes them (IPCTesterPayload.h).

    @MainActor
    func describeControlSwift(connection: IPC.Connection, part: IPCTypes.ControlPart, style: IPCTypes.ControlStyle) -> String? {
        Self.description(part) + Self.description(style)
    }

    @MainActor
    func describeSystemImageSwift(connection: IPC.Connection, image: IPCTypes.SystemImage) -> String? {
        switch image {
        #if ENABLE_APPLE_PAY
        case .applePayLogoSystemImage(let logo):
            return "applePayLogo=\(logo.applePayLogoStyle.rawValue)"
        #endif
        #if USE_APPKIT
        case .appKitControlSystemImage(let controlImage):
            return "appKitControl=0 tint=\(Self.description(controlImage.tintColor)) dark=\(controlImage.useDarkAppearance ? 1 : 0)"
        #endif
        }
    }

    // A filter decoded in Swift and in C++ must be described alike: as ipcTesterDescription() describes it
    // (IPCTesterPayload.h).

    @MainActor
    func describeFilterSwift(connection: IPC.Connection, filter: IPCTypes.Filter) -> String? {
        switch filter {
        case .cssFilterRenderer(let cssFilter):
            return "css(functions=\(cssFilter.functions.count)" + cssFilter.functions.map { " " + Self.description($0) }.joined()
                + Self.description(cssFilter.geometry, cssFilter.filterRenderingModes, cssFilter.renderingOptions) + ")"
        case .svgFilterRenderer(let svgFilter):
            return Self.description(svgFilter)
        }
    }

    private static func description(_ values: Float...) -> String {
        values.map { "\($0.bitPattern)" }.joined(separator: ",")
    }

    private static func description(_ values: [Float]) -> String {
        "\(values.count)" + values.map { ":\($0.bitPattern)" }.joined()
    }

    private static func description(_ rect: IPCTypes.FloatRect) -> String {
        description(rect.location.x, rect.location.y, rect.size.width, rect.size.height)
    }

    private static func description(_ function: IPCTypes.ComponentTransferFunction) -> String {
        "\(function.type.rawValue),"
            + description(function.slope, function.intercept, function.amplitude, function.exponent, function.offset) + ","
            + description(function.tableValues)
    }

    private static func description(_ lightSource: IPCTypes.LightSource) -> String {
        switch lightSource {
        case .distantLightSource(let distant):
            return "distant:" + description(distant.azimuth, distant.elevation)
        case .pointLightSource(let point):
            return "point:" + description(point.position.x, point.position.y, point.position.z)
        case .spotLightSource(let spot):
            return "spot:"
                + description(spot.position.x, spot.position.y, spot.position.z, spot.direction.x, spot.direction.y, spot.direction.z,
                    spot.specularExponent, spot.limitingConeAngle)
        }
    }

    private static func description(
        _ geometry: IPCTypes.FilterGeometry,
        _ modes: IPCTypes.FilterRenderingMode,
        _ options: IPCTypes.FilterRenderingOption
    ) -> String {
        " referenceBox=" + description(geometry.referenceBox) + " filterRegion=" + description(geometry.filterRegion) + " scale="
            + description(geometry.scale.width, geometry.scale.height) + " modes=\(modes.rawValue) options=\(options.rawValue)"
    }

    private static func description(_ svgFilter: IPCTypes.SVGFilterRenderer) -> String {
        var result = "svg(units=\(svgFilter.primitiveUnits.rawValue) expression=\(svgFilter.expression.count)"
        for term in svgFilter.expression {
            result += ":\(term.index),\(term.level)"
            if let geometry = term.geometry {
                let flags: [IPCTypes.FilterEffectGeometryFlags] = [.hasX, .hasY, .hasWidth, .hasHeight]
                let values = [geometry.boundaries.location.x, geometry.boundaries.location.y, geometry.boundaries.size.width, geometry.boundaries.size.height]
                for (flag, value) in zip(flags, values) {
                    result += geometry.flags.contains(flag) ? ",\(value.bitPattern)" : ",-"
                }
            }
        }
        result += " effects=\(svgFilter.effects.count)" + svgFilter.effects.map { " " + description(FunctionOrEffect.effect($0)) }.joined()
        result += description(svgFilter.geometry, svgFilter.filterRenderingModes, svgFilter.renderingOptions)
        result += " identifier=" + (svgFilter.renderingResourceIdentifierIfExists.map { "\($0.rawValue)" } ?? "none") + ")"
        return result
    }

    private enum FunctionOrEffect {
        case function(IPCTypes.FilterFunction)
        case effect(IPCTypes.FilterEffect)
    }

    private static func description(_ function: IPCTypes.FilterFunction) -> String {
        description(FunctionOrEffect.function(function))
    }

    private static func colorSpaceName(_ colorSpace: IPCTypes.ColorSpace) -> String {
        colorSpace.cgColorSpace.name.map { String($0) } ?? "none"
    }

    // The effects of a filter function, and of an SVG filter's effects, which are the same types in two enums.
    private static func description(_ item: FunctionOrEffect) -> String {
        let fields: String
        let colorSpace: IPCTypes.ColorSpace
        switch item {
        case .function(.svgFilterRenderer(let svgFilter)):
            return description(svgFilter)
        case .function(.feBlend(let blend)), .effect(.feBlend(let blend)):
            fields = "blend(\(blend.blendMode.rawValue)"
            colorSpace = blend.operatingColorSpace
        case .function(.feColorMatrix(let colorMatrix)), .effect(.feColorMatrix(let colorMatrix)):
            fields = "colorMatrix(\(colorMatrix.type.rawValue)," + description(colorMatrix.values)
            colorSpace = colorMatrix.operatingColorSpace
        case .function(.feComponentTransfer(let transfer)), .effect(.feComponentTransfer(let transfer)):
            fields = "componentTransfer(" + [transfer.redFunction, transfer.greenFunction, transfer.blueFunction, transfer.alphaFunction].map {
                description($0) + ";"
            }.joined()
            colorSpace = transfer.operatingColorSpace
        case .function(.feComposite(let composite)), .effect(.feComposite(let composite)):
            fields = "composite(\(composite.operation.rawValue)," + description(composite.k1, composite.k2, composite.k3, composite.k4)
            colorSpace = composite.operatingColorSpace
        case .function(.feConvolveMatrix(let convolve)), .effect(.feConvolveMatrix(let convolve)):
            fields = "convolveMatrix(\(convolve.kernelSize.width)x\(convolve.kernelSize.height)," + description(convolve.divisor, convolve.bias)
                + ",\(convolve.targetOffset.x),\(convolve.targetOffset.y),\(convolve.edgeMode.rawValue),"
                + description(convolve.kernelUnitLength.x, convolve.kernelUnitLength.y) + ",\(convolve.preserveAlpha ? 1 : 0),"
                + description(convolve.kernel)
            colorSpace = convolve.operatingColorSpace
        case .function(.feDiffuseLighting(let lighting)), .effect(.feDiffuseLighting(let lighting)):
            fields = "diffuseLighting(" + description(lighting.lightingColor) + ","
                + description(lighting.surfaceScale, lighting.diffuseConstant, lighting.kernelUnitLengthX, lighting.kernelUnitLengthY) + ","
                + description(lighting.lightSource)
            colorSpace = lighting.operatingColorSpace
        case .function(.feDisplacementMap(let displacement)), .effect(.feDisplacementMap(let displacement)):
            fields = "displacementMap(\(displacement.xChannelSelector.rawValue),\(displacement.yChannelSelector.rawValue),"
                + description(displacement.scale) + ",\(displacement.in2IsTainted ? 1 : 0)"
            colorSpace = displacement.operatingColorSpace
        case .function(.feDropShadow(let shadow)), .effect(.feDropShadow(let shadow)):
            fields = "dropShadow(" + description(shadow.stdDeviationX, shadow.stdDeviationY, shadow.dx, shadow.dy) + ","
                + description(shadow.shadowColor) + "," + description(shadow.shadowOpacity)
            colorSpace = shadow.operatingColorSpace
        case .function(.feFlood(let flood)), .effect(.feFlood(let flood)):
            fields = "flood(" + description(flood.floodColor) + "," + description(flood.floodOpacity)
            colorSpace = flood.operatingColorSpace
        case .function(.feGaussianBlur(let blur)), .effect(.feGaussianBlur(let blur)):
            fields = "gaussianBlur(" + description(blur.stdDeviationX, blur.stdDeviationY) + ",\(blur.edgeMode.rawValue)"
            colorSpace = blur.operatingColorSpace
        case .function(.feImage(let image)), .effect(.feImage(let image)):
            return "image(\(image.sourceImage.imageIdentifier.rawValue)," + description(image.sourceImageRect) + ")"
        case .function(.feMerge(let merge)), .effect(.feMerge(let merge)):
            fields = "merge(\(merge.numberOfEffectInputs)"
            colorSpace = merge.operatingColorSpace
        case .function(.feMorphology(let morphology)), .effect(.feMorphology(let morphology)):
            fields = "morphology(\(morphology.morphologyOperator.rawValue)," + description(morphology.radiusX, morphology.radiusY)
            colorSpace = morphology.operatingColorSpace
        case .function(.feOffset(let offset)), .effect(.feOffset(let offset)):
            fields = "offset(" + description(offset.dx, offset.dy)
            colorSpace = offset.operatingColorSpace
        case .function(.feSpecularLighting(let lighting)), .effect(.feSpecularLighting(let lighting)):
            fields = "specularLighting(" + description(lighting.lightingColor) + ","
                + description(lighting.surfaceScale, lighting.specularConstant, lighting.specularExponent, lighting.kernelUnitLengthX,
                    lighting.kernelUnitLengthY) + "," + description(lighting.lightSource)
            colorSpace = lighting.operatingColorSpace
        case .function(.feTile(let tile)), .effect(.feTile(let tile)):
            fields = "tile("
            colorSpace = tile.operatingColorSpace
        case .function(.feTurbulence(let turbulence)), .effect(.feTurbulence(let turbulence)):
            fields = "turbulence(\(turbulence.type.rawValue)," + description(turbulence.baseFrequencyX, turbulence.baseFrequencyY)
                + ",\(turbulence.numOctaves)," + description(turbulence.seed) + ",\(turbulence.stitchTiles ? 1 : 0)"
            colorSpace = turbulence.operatingColorSpace
        case .function(.sourceAlpha(let sourceAlpha)), .effect(.sourceAlpha(let sourceAlpha)):
            fields = "sourceAlpha("
            colorSpace = sourceAlpha.operatingColorSpace
        case .function(.sourceGraphic(let sourceGraphic)), .effect(.sourceGraphic(let sourceGraphic)):
            fields = "sourceGraphic("
            colorSpace = sourceGraphic.operatingColorSpace
        }
        return fields + " colorSpace=" + colorSpaceName(colorSpace) + ")"
    }

    #if ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
    // A fill rule, a transform and a color as the CG renderer takes it, decoded in Swift and in C++, must be described alike:
    // as ipcTesterDescription() describes them (IPCTesterPayload.h).

    @MainActor
    func describeDrawingFormsSwift(
        connection: IPC.Connection,
        windRule: IPCTypes.WindRule,
        transform: IPCTypes.AffineTransform,
        color: IPCTypes.CGRendererColorValue
    ) -> String? {
        let values = transform.span.map { String($0.bitPattern) }.joined(separator: ",")
        let data = color.data
        let dataValues = [
            String(data.c1.bitPattern), String(data.c2.bitPattern), String(data.c3.bitPattern), String(data.alpha.bitPattern), String(data.packedColor),
            String(data.colorSpace), String(data.form), data.isSemantic ? "1" : "0", data.usesFunctionSerialization ? "1" : "0",
        ]
        return "rule=\(windRule.rawValue) transform=\(values) color=\(color.packedColor),\(color.isPacked ? 1 : 0),\(color.isVisible ? 1 : 0) data="
            + dataValues.joined(separator: ",")
    }

    @MainActor
    func describeCxxDecodedDrawingFormsSwift(
        connection: IPC.Connection,
        windRule: CxxDecodedArguments.IPCTesterReceiver.DescribeCxxDecodedDrawingFormsSwiftWindRule,
        transform: CxxDecodedArguments.IPCTesterReceiver.DescribeCxxDecodedDrawingFormsSwiftTransform,
        color: CxxDecodedArguments.IPCTesterReceiver.DescribeCxxDecodedDrawingFormsSwiftColor
    ) -> String? {
        IPCCoding.WTFString.swiftString(WebKit.ipcTesterCxxDecodedDrawingFormsDescription(windRule, transform, color))
    }

    // A path decoded in Swift and in C++ must give the CG renderer alike CGPaths and facts.

    @MainActor
    func describePathSwift(connection: IPC.Connection, path: IPCTypes.Path) -> String? {
        IPCCoding.WTFString.swiftString(path.testingDescription)
    }

    #if ENABLE_GPU_PROCESS
    // RemoteCGRenderer's messages whose arguments Swift decodes, encoded as the web process encodes them, must be decoded and
    // encoded again by their Swift coders into the same bytes.
    @MainActor
    func wireFormMismatchesOfCGRendererSwift(connection: IPC.Connection) -> String? {
        IPCCoding.WTFString.swiftString(WebKit.ipcTesterCGRendererWireFormMismatches())
    }
    #endif

    @MainActor
    func describeCxxDecodedPathSwift(connection: IPC.Connection, path: CxxDecodedArguments.IPCTesterReceiver.DescribeCxxDecodedPathSwiftPath) -> String? {
        IPCCoding.WTFString.swiftString(WebKit.ipcTesterCxxDecodedPathDescription(path))
    }
    #endif

    private static func description(_ color: IPCTypes.WebCoreColor) -> String {
        guard let data = color.data else {
            return "invalid"
        }
        let flags = "\(data.isSemantic ? 1 : 0),\(data.usesFunctionSerialization ? 1 : 0),"
        switch data.components {
        case .packed(let value):
            return flags + "packed:\(value)"
        case .outOfLine(let colorSpace, let c1, let c2, let c3, let alpha):
            return flags + "\(colorSpace.rawValue):\(c1.bitPattern),\(c2.bitPattern),\(c3.bitPattern),\(alpha.bitPattern)"
        }
    }

    private static func description(_ part: IPCTypes.ControlPart) -> String {
        var appearance: UInt8 = 0
        var details = ""
        switch part {
        case .buttonPart(let button):
            appearance = button.type.rawValue
        case .colorWellPart:
            appearance = WebCore.StyleAppearance.ColorWell.rawValue
        case .innerSpinButtonPart:
            appearance = WebCore.StyleAppearance.InnerSpinButton.rawValue
        case .menuListButtonPart:
            appearance = WebCore.StyleAppearance.MenulistButton.rawValue
        case .menuListPart:
            appearance = WebCore.StyleAppearance.Menulist.rawValue
        case .meterPart(let meter):
            appearance = WebCore.StyleAppearance.Meter.rawValue
            details = " meter=\(meter.gaugeRegion.rawValue),\(meter.value.bitPattern),\(meter.minimum.bitPattern),\(meter.maximum.bitPattern)"
        case .progressBarPart(let progressBar):
            appearance = WebCore.StyleAppearance.ProgressBar.rawValue
            details = " progress=\(progressBar.position.bitPattern),\(progressBar.animationStartTime.bitPattern)"
        case .searchFieldPart:
            appearance = WebCore.StyleAppearance.SearchField.rawValue
        case .searchFieldResultsPart(let results):
            appearance = results.type.rawValue
        case .searchFieldCancelButtonPart:
            appearance = WebCore.StyleAppearance.SearchFieldCancelButton.rawValue
        case .sliderThumbPart(let thumb):
            appearance = thumb.type.rawValue
        case .sliderTrackPart(let track):
            appearance = track.type.rawValue
            let thumb = track.thumbSize
            let bounds = track.trackBounds
            details = " slider=\(thumb.width)x\(thumb.height),\(bounds.location.x),\(bounds.location.y),\(bounds.size.width)x\(bounds.size.height),"
                + "\(track.thumbPosition.bitPattern),ticks:\(track.tickRatios.count)" + track.tickRatios.map { ":\($0.bitPattern)" }.joined()
        case .switchPart(let switchPart):
            appearance = WebCore.StyleAppearance.Switch.rawValue
            details = " switch=\(switchPart.isOn ? 1 : 0),\(switchPart.progress.bitPattern)"
        case .textAreaPart(let textArea):
            appearance = textArea.type.rawValue
        case .textFieldPart:
            appearance = WebCore.StyleAppearance.TextField.rawValue
        case .toggleButtonPart(let toggleButton):
            appearance = toggleButton.type.rawValue
        #if ENABLE_APPLE_PAY
        case .applePayButtonPart(let button):
            appearance = WebCore.StyleAppearance.ApplePayButton.rawValue
            details = " applePay=\(button.buttonType.rawValue),\(button.buttonStyle.rawValue),\(button.locale ?? "null")"
        #endif
        #if ENABLE_SERVICE_CONTROLS
        case .imageControlsButtonPart:
            appearance = WebCore.StyleAppearance.ImageControlsButton.rawValue
        #endif
        }
        return "appearance=\(appearance)" + details
    }

    private static func description(_ style: IPCTypes.ControlStyle) -> String {
        let border = style.borderWidth
        return " states=\(style.states.rawValue) fontSize=\(style.fontSize.bitPattern) zoom=\(style.zoomFactor.bitPattern)"
            + " accent=\(description(style.accentColor)) text=\(description(style.textColor))"
            + " border=\(border.top.bitPattern),\(border.right.bitPattern),\(border.bottom.bitPattern),\(border.left.bitPattern)"
    }
    #endif

    @MainActor
    func halveEvenNumberSyncHandlerSwift(connection: IPC.Connection, value: UInt32) throws(InvalidMessage) -> UInt32 {
        try halveEvenNumberSwift(connection: connection, value: value)
    }

    @MainActor
    func transformPayloadSyncHandlerSwift(connection: IPC.Connection, payload: IPCTypes.IPCTesterPayload) -> IPCTypes.IPCTesterPayload {
        Self.transformed(payload)
    }

    @MainActor
    func recordSyncHandlerSwift(connection: IPC.Connection, text: String?) {
        recordSwift(connection: connection, text: text)
    }

    @MainActor
    func swapPairsSwift(connection: IPC.Connection, pairs: [(String?, UInt32)]) -> [(UInt32, String?)] {
        pairs.map { ($0.1, $0.0) }
    }

    @MainActor
    func enabledMessageSwift(connection: IPC.Connection, value: UInt32) -> UInt32 {
        value &* 2
    }

    @MainActor
    func disabledMessageSwift(connection: IPC.Connection, value: UInt32) -> UInt32 {
        value &* 2
    }

    @used
    func sharedPreferencesForWebProcess() -> WebKit.OptionalSharedPreferencesForWebProcess {
        WebKit.ipcTesterSharedPreferences()
    }

    private static func exclaimed(_ string: String?) -> String? {
        string.map { $0 + "!" }
    }

    private static func transformed(_ inner: IPCTypes.IPCTesterInner) -> IPCTypes.IPCTesterInner {
        IPCTypes.IPCTesterInner(value: 0 &- inner.value, label: exclaimed(inner.label))
    }

    private static func transformed(_ payload: IPCTypes.IPCTesterPayload) -> IPCTypes.IPCTesterPayload {
        var result = payload
        result.flag.toggle()
        result.u8 &+= 1
        result.u16 &+= 1
        result.u32 &+= 1
        result.u64 &+= 1
        result.i8 &-= 1
        result.i16 &-= 1
        result.i32 &-= 1
        result.i64 &-= 1
        result.f *= 2
        result.d *= 2
        result.text = exclaimed(payload.text)
        result.numbers.reverse()
        result.strings.reverse()
        result.color = payload.color.map { color in
            switch color {
            case .red: .green
            case .green: .blue
            case .blue: .red
            }
        }
        result.flags = payload.flags.symmetricDifference([.first, .second, .third])
        result.choice = payload.choice == .yes ? .no : .yes
        result.inner = transformed(payload.inner)
        result.inners = payload.inners.map(transformed)
        result.variant =
            switch payload.variant {
            case .uint64(let value): .uint64(value &+ 1)
            case .string(let value): .string(exclaimed(value))
            case .ipcTesterInner(let value): .ipcTesterInner(transformed(value))
            }
        return result
    }

    private static func mirrored(_ node: IPCTypes.IPCTesterNode) -> IPCTypes.IPCTesterNode {
        IPCTypes.IPCTesterNode(
            name: exclaimed(node.name),
            children: node.children.reversed().map(mirrored)
        )
    }

    private static func nodeCount(_ node: IPCTypes.IPCTesterNode) -> UInt32 {
        node.children.reduce(1) { $0 + nodeCount($1) }
    }
}

#if ENABLE_GPU_PROCESS && ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT
private func reencode<Coder: IPCCoder>(_: Coder.Type, _ decoder: inout IPC.SwiftDecoder, _ encoder: IPC.SwiftReplyEncoder) throws(IPCDecodingError) {
    Coder.encode(try Coder.decode(from: &decoder), to: encoder)
}

// The storage that variant 0 decodes every DrawGlyphs's run into, as a live dispatch decodes into the renderer's, so that a longer
// run then a shorter one decode into storage larger than the run. Only the main thread uses it, one call at a time, as only a
// renderer's work queue uses the renderer's (GlyphRun.Storage).
private let ipcTesterLiveGlyphRun = IPCTypes.GlyphRun.Storage()

// For ipcTesterCGRendererWireFormMismatches(): decodes the arguments of one of RemoteCGRenderer's messages with the coders that
// its Swift dispatch decodes them with, and encodes them again with the same coders. A DrawGlyphs's run decodes into storage of
// its own for variant 1, as the recorder's does, and else into ipcTesterLiveGlyphRun. False if they don't decode.
@_expose(Cxx)
func ipcTesterReencodeCGRendererArguments(_ messageName: UInt16, _ decoder: inout IPC.SwiftDecoder, _ encoder: IPC.SwiftReplyEncoder, _ variant: UInt8) -> Bool {
    do throws(IPCDecodingError) {
        switch IPC.MessageName(rawValue: messageName) {
        case .RemoteCGRenderer_SetLineDash:
            try reencode(IPCCoding.Vector<Double>.self, &decoder, encoder)
            try reencode(Float.self, &decoder, encoder)
        case .RemoteCGRenderer_FillPathSegment, .RemoteCGRenderer_StrokePathSegment:
            try reencode(IPCCoding.CxxDecoded.PathSegment.self, &decoder, encoder)
        case .RemoteCGRenderer_StrokeLinesWithColorAndThickness:
            try reencode(IPCCoding.TrivialSpan<WebCore.PathDataLineColorThickness>.self, &decoder, encoder)
        case .RemoteCGRenderer_SetDropShadow:
            try reencode(IPCTypes.CxxName.CGRendererShadowValues.self, &decoder, encoder)
            try reencode(IPCTypes.CxxName.CGRendererColorData.self, &decoder, encoder)
            try reencode(Bool.self, &decoder, encoder)
        case .RemoteCGRenderer_SetStyle:
            try reencode(IPCTypes.CxxName.WebKit_RemoteCGRendererStyleKind.self, &decoder, encoder)
            try reencode(IPCTypes.CxxName.CGRendererShadowValues.self, &decoder, encoder)
            try reencode(IPCTypes.CxxName.CGRendererColorData.self, &decoder, encoder)
            try reencode(Bool.self, &decoder, encoder)
            try reencode(Float.self, &decoder, encoder)
            try reencode(Float.self, &decoder, encoder)
            try reencode(IPCCoding.StdArray20<Float>.self, &decoder, encoder)
        case .RemoteCGRenderer_DrawLinesForText:
            try reencode(IPCTypes.CxxName.WebCore_FloatPoint.self, &decoder, encoder)
            try reencode(Float.self, &decoder, encoder)
            try reencode(IPCCoding.TrivialSpan<WebCore.FloatSegment>.self, &decoder, encoder)
            try reencode(Bool.self, &decoder, encoder)
            try reencode(Bool.self, &decoder, encoder)
            try reencode(IPCCoding.CxxEnum<WebCore.StrokeStyle>.self, &decoder, encoder)
        case .RemoteCGRenderer_DrawGlyphs:
            try reencode(IPCTypes.CxxName.WebCore_RenderingResourceIdentifier.self, &decoder, encoder)
            let run =
                if variant == 1 {
                    try IPCTypes.GlyphRun.decode(from: &decoder)
                } else {
                    try IPCTypes.GlyphRun.decode(from: &decoder, context: ipcTesterLiveGlyphRun)
                }
            IPCTypes.GlyphRun.encode(run, to: encoder)
            try reencode(IPCTypes.CxxName.WebCore_FloatPoint.self, &decoder, encoder)
            try reencode(IPCCoding.CxxEnum<WebCore.FontSmoothingMode>.self, &decoder, encoder)
        default:
            return false
        }
    } catch {
        return false
    }
    return true
}
#endif

#endif
