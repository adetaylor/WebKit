// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1.  Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
// ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT && WTF_PLATFORM_MAC

import AppKit
import Synchronization
import WebCore_Private.Core.CGRendererSPI
import WebCore_Private.Core.MacControlPainter
import WebCore_Private.Core.WebControlView
import pal.spi.cg.CoreGraphicsSPI
import pal.spi.cocoa.NSButtonCellSPI
import pal.spi.mac.CoreUISPI
import pal.spi.mac.NSAppearanceSPI
import pal.spi.mac.NSCellSPI
import pal.spi.mac.NSGraphicsSPI
import pal.spi.mac.NSSearchFieldCellSPI
#if ENABLE_SERVICE_CONTROLS
import pal.spi.mac.NSServicesRolloverButtonCellSPI
#endif
import pal.spi.mac.NSViewSPI

// MARK: Entering the drawing

// AppKit isolates its cells and views to the main actor, but the GPU process's rendering backends draw them without a
// view off the main thread, as the C++ did. Each ControlFactoryMac, and so each MacControlCells, is used on one thread:
// the web process's main thread, or one rendering backend's. MacControlCells is entered only through this, which runs
// its main-actor code on that thread without checking it.
private func enterControlDrawing<Argument, Result>(_ argument: Argument, _ body: @MainActor (Argument) -> Result) -> Result {
    withoutActuallyEscaping(body) { body in
        unsafe unsafeBitCast(body, to: ((Argument) -> Result).self)(argument)
    }
}

// NSAppearance.performAsCurrentDrawingAppearance(), whose block doesn't check the thread either (see
// enterControlDrawing()): a block made by main-actor code would.
private func withDrawingAppearance(_ appearance: NSAppearance, _ body: @MainActor () -> Void) {
    withoutActuallyEscaping(body) { body in
        appearance.performAsCurrentDrawingAppearance {
            enterControlDrawing(body) { body in body() }
        }
    }
}

// MARK: WebCore's geometry, in its arithmetic

private func truncatedInt32(_ value: Float) -> Int32 {
    if value.isNaN {
        return 0
    }
    if value >= Float(Int32.max) {
        return .max
    }
    if value <= Float(Int32.min) {
        return .min
    }
    return Int32(value)
}

private struct MacFloatPoint {
    var x: Float
    var y: Float

    var transposed: MacFloatPoint { MacFloatPoint(x: y, y: x) }
}

private struct MacFloatSize {
    var width: Float
    var height: Float

    var transposed: MacFloatSize { MacFloatSize(width: height, height: width) }
    var cgSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
}

private struct MacIntSize {
    var width: Int32
    var height: Int32

    var transposed: MacIntSize { MacIntSize(width: height, height: width) }
    var floatSize: MacFloatSize { MacFloatSize(width: Float(width), height: Float(height)) }

    mutating func multiply(by scale: Float) {
        width = truncatedInt32(Float(width) * scale)
        height = truncatedInt32(Float(height) * scale)
    }
}

private struct MacIntOutsets {
    var top: Int32
    var right: Int32
    var bottom: Int32
    var left: Int32
}

private struct MacFloatRect {
    var x: Float
    var y: Float
    var width: Float
    var height: Float

    init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ location: MacFloatPoint, _ size: MacFloatSize) {
        self.init(x: location.x, y: location.y, width: size.width, height: size.height)
    }

    init(_ rect: CGRect) {
        self.init(x: Float(rect.origin.x), y: Float(rect.origin.y), width: Float(rect.size.width), height: Float(rect.size.height))
    }

    var cgRect: CGRect { CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) }

    var location: MacFloatPoint {
        get { MacFloatPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    var size: MacFloatSize {
        get { MacFloatSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }

    var maxX: Float { x + width }
    var maxY: Float { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var center: MacFloatPoint { MacFloatPoint(x: x + width / 2, y: y + height / 2) }
    var transposed: MacFloatRect { MacFloatRect(location.transposed, size.transposed) }

    mutating func multiply(by scale: Float) {
        x = x * scale
        y = y * scale
        width = width * scale
        height = height * scale
    }

    mutating func outsetX(_ dx: Float) {
        x = x - dx
        width = width + dx + dx
    }

    mutating func outsetY(_ dy: Float) {
        y = y - dy
        height = height + dy + dy
    }

    mutating func outset(_ d: Float) {
        outsetX(d)
        outsetY(d)
    }

    mutating func expand(top: Float, right: Float, bottom: Float, left: Float) {
        x += -left
        y += -top
        width += left + right
        height += top + bottom
    }

    mutating func contract(top: Float, right: Float, bottom: Float, left: Float) {
        x += left
        y += top
        width += -(left + right)
        height += -(top + bottom)
    }

    mutating func formUnion(_ other: MacFloatRect) {
        if other.isEmpty {
            return
        }
        if isEmpty {
            self = other
            return
        }
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(self.maxX, other.maxX)
        let maxY = max(self.maxY, other.maxY)
        x = minX
        y = minY
        width = maxX - minX
        height = maxY - minY
    }
}

// The IntRect of a FloatRect, as a FloatRect of its values.
private struct MacIntRect {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    init(_ rect: MacFloatRect) {
        x = truncatedInt32(rect.x)
        y = truncatedInt32(rect.y)
        width = truncatedInt32(rect.width)
        height = truncatedInt32(rect.height)
    }

    mutating func multiply(by scale: Float) {
        x = truncatedInt32(Float(x) * scale)
        y = truncatedInt32(Float(y) * scale)
        width = truncatedInt32(Float(width) * scale)
        height = truncatedInt32(Float(height) * scale)
    }

    var cgRect: CGRect { CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)) }
}

// WTF's piOverTwoFloat: π/2 rounded to the nearest Float (Float.pi rounds toward zero).
private let piOverTwoFloat = Float(Double.pi / 2)

extension WebCore.MacControlState {
    fileprivate var isVerticalSlider: Bool { appearance == .SliderVertical }

    fileprivate var withoutFocus: WebCore.MacControlState {
        var state = self
        state.isFocused = false
        return state
    }
}

// The slider track's shading, from { 0, 0, 0, 0.678 } to { 0, 0, 0, 0.13 }. CG calls it on its own threads, so it isn't
// main-actor code.
private func sliderTrackGradientInterpolate(
    _: UnsafeMutableRawPointer?,
    _ inData: UnsafePointer<CGFloat>,
    _ outData: UnsafeMutablePointer<CGFloat>
) {
    let darkColor: Float = 0
    let darkAlpha: Float = 0.678
    let lightColor: Float = 0
    let lightAlpha: Float = 0.13
    let a = Float(unsafe inData[0])
    let color = CGFloat((1 - a) * darkColor + a * lightColor)
    unsafe (outData[0], outData[1], outData[2], outData[3]) = (color, color, color, CGFloat((1 - a) * darkAlpha + a * lightAlpha))
}

// MARK: The cells

// What one draw() draws with.
private struct MacControlDrawing {
    let context: CGContext
    let borderRect: MacFloatRect
    let deviceScaleFactor: Float
    let state: WebCore.MacControlState
    let accentColor: NSColor?
    let textColor: CGColor?
    let focusRingColor: CGColor?

    var layers: UInt { state.layers }
}

// The NSServicesRolloverButtonCell copies are made under one lock: -[NSButtonCell copyWithZone:] changes the process's
// shared cell for a moment.
private let servicesRolloverButtonCellCopyLock = Mutex(())

// ControlFactoryMac's cells, and the Mac controls' drawing (ControlMac and its subclasses).
@MainActor
private final class MacControlCells {
    private var drawingViewStorage: WebControlView?
    private var buttonCellStorage: NSButtonCell?
    private var defaultButtonCellStorage: NSButtonCell?
    private var checkboxCellStorage: NSButtonCell?
    private var radioCellStorage: NSButtonCell?
    private var levelIndicatorCellStorage: NSLevelIndicatorCell?
    private var popUpButtonCellStorage: NSPopUpButtonCell?
    #if ENABLE_SERVICE_CONTROLS
    private var servicesRolloverButtonCellStorage: NSServicesRolloverButtonCell?
    #endif
    private var searchFieldCellStorage: NSSearchFieldCell?
    private var searchMenuTemplateStorage: NSMenu?
    private var sliderCellStorage: NSSliderCell?
    private var textFieldCellStorage: NSTextFieldCell?

    // What the layers that MacControlPainter::makeLayer() is filling draw, innermost last.
    private var layerContents: [(CGContext) -> Void] = []

    // MARK: Cells

    private static func makeButtonCell() -> NSButtonCell {
        let buttonCell = NSButtonCell()
        buttonCell.title = ""
        buttonCell.setButtonType(.momentaryPushIn)
        return buttonCell
    }

    private var buttonCell: NSButtonCell {
        if let buttonCellStorage {
            return buttonCellStorage
        }
        let buttonCell = Self.makeButtonCell()
        buttonCellStorage = buttonCell
        return buttonCell
    }

    private var defaultButtonCell: NSButtonCell {
        if let defaultButtonCellStorage {
            return defaultButtonCellStorage
        }
        let buttonCell = Self.makeButtonCell()
        buttonCell.keyEquivalent = "\r"
        defaultButtonCellStorage = buttonCell
        return buttonCell
    }

    private static func makeToggleButtonCell() -> NSButtonCell {
        let buttonCell = NSButtonCell()
        buttonCell.title = ""
        buttonCell.focusRingType = .exterior
        return buttonCell
    }

    private var checkboxCell: NSButtonCell {
        if let checkboxCellStorage {
            return checkboxCellStorage
        }
        let buttonCell = Self.makeToggleButtonCell()
        buttonCell.setButtonType(.switch)
        buttonCell.allowsMixedState = true
        checkboxCellStorage = buttonCell
        return buttonCell
    }

    private var radioCell: NSButtonCell {
        if let radioCellStorage {
            return radioCellStorage
        }
        let buttonCell = Self.makeToggleButtonCell()
        buttonCell.setButtonType(.radio)
        radioCellStorage = buttonCell
        return buttonCell
    }

    private var levelIndicatorCell: NSLevelIndicatorCell {
        if let levelIndicatorCellStorage {
            return levelIndicatorCellStorage
        }
        let levelIndicatorCell = NSLevelIndicatorCell(levelIndicatorStyle: .continuousCapacity)
        levelIndicatorCell.levelIndicatorStyle = .continuousCapacity
        levelIndicatorCellStorage = levelIndicatorCell
        return levelIndicatorCell
    }

    private var popUpButtonCell: NSPopUpButtonCell {
        if let popUpButtonCellStorage {
            return popUpButtonCellStorage
        }
        let popUpButtonCell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        popUpButtonCell.usesItemFromMenu = false
        popUpButtonCell.focusRingType = .exterior
        popUpButtonCell.userInterfaceLayoutDirection = .leftToRight
        popUpButtonCellStorage = popUpButtonCell
        return popUpButtonCell
    }

    #if ENABLE_SERVICE_CONTROLS
    // +serviceRolloverButtonCellForStyle: returns a process-wide shared cell, so each ControlFactoryMac draws a private
    // copy of it.
    private var servicesRolloverButtonCell: NSServicesRolloverButtonCell? {
        if let servicesRolloverButtonCellStorage {
            return servicesRolloverButtonCellStorage
        }
        let copy = servicesRolloverButtonCellCopyLock.withLock { _ in
            // The internal SDK's declaration returns an optional.
            (NSServicesRolloverButtonCell.serviceRolloverButtonCell(for: .rollover) as NSServicesRolloverButtonCell?)?.copy()
        }
        guard let servicesRolloverButtonCell = copy as? NSServicesRolloverButtonCell else {
            return nil
        }
        servicesRolloverButtonCell.bezelStyle = .pushDisclosure
        servicesRolloverButtonCell.setButtonType(.pushOnPushOff)
        servicesRolloverButtonCell.imagePosition = .imageOnly
        servicesRolloverButtonCell.state = .off
        servicesRolloverButtonCellStorage = servicesRolloverButtonCell
        return servicesRolloverButtonCell
    }
    #endif

    private var searchFieldCell: NSSearchFieldCell {
        if let searchFieldCellStorage {
            return searchFieldCellStorage
        }
        let searchFieldCell = NSSearchFieldCell(textCell: "")
        searchFieldCell.bezelStyle = .roundedBezel
        searchFieldCell.isBezeled = true
        searchFieldCell.isEditable = true
        searchFieldCell.focusRingType = .exterior
        searchFieldCell.isCenteredLook = false
        searchFieldCellStorage = searchFieldCell
        return searchFieldCell
    }

    private var searchMenuTemplate: NSMenu {
        if let searchMenuTemplateStorage {
            return searchMenuTemplateStorage
        }
        let searchMenuTemplate = NSMenu(title: "")
        searchMenuTemplateStorage = searchMenuTemplate
        return searchMenuTemplate
    }

    private var sliderCell: NSSliderCell {
        if let sliderCellStorage {
            return sliderCellStorage
        }
        let sliderCell = NSSliderCell()
        sliderCell.sliderType = .linear
        sliderCell.controlSize = .small
        sliderCell.focusRingType = .exterior
        sliderCellStorage = sliderCell
        return sliderCell
    }

    private var textFieldCell: NSTextFieldCell {
        if let textFieldCellStorage {
            return textFieldCellStorage
        }
        let textFieldCell = WebControlTextFieldCell(textCell: "")
        textFieldCell.isBezeled = true
        textFieldCell.isEditable = true
        textFieldCell.focusRingType = .exterior
        // WebCore paints the background: WebControlTextFieldCell asks CoreUI for the borders only.
        textFieldCell.drawsBackground = false
        textFieldCellStorage = textFieldCell
        return textFieldCell
    }

    private func buttonCellForAppearance(_ state: WebCore.MacControlState) -> NSButtonCell {
        switch state.appearance {
        case .DefaultButton:
            defaultButtonCell
        case .Checkbox:
            checkboxCell
        case .Radio:
            radioCell
        default:
            buttonCell
        }
    }

    #if ENABLE_SERVICE_CONTROLS
    func servicesRolloverButtonCellSize() -> CGSize {
        servicesRolloverButtonCell?.cellSize ?? .zero
    }
    #endif

    // MARK: Layers

    func makeLayer(_ drawing: MacControlDrawing, _ size: MacFloatSize, _ scale: Float, _ content: (CGContext) -> Void) -> UInt8 {
        withoutActuallyEscaping(content) { content in
            layerContents.append(content)
            defer { layerContents.removeLast() }
            return WebCore.MacControlPainter.makeLayer(drawing.layers, size.width, size.height, scale)
        }
    }

    func fillLayer(_ context: CGContext) {
        layerContents.last?(context)
    }

    private func drawLayer(
        _ drawing: MacControlDrawing,
        _ layer: UInt8,
        _ location: MacFloatPoint,
        alpha: Float? = nil,
        isPlusLighter: Bool = false,
        isRotatedHalfTurn: Bool = false
    ) {
        var options = WebCore.MacControlLayerDrawing()
        options.x = location.x
        options.y = location.y
        if let alpha {
            options.setsAlpha = true
            options.alpha = alpha
        }
        options.isPlusLighter = isPlusLighter
        options.isRotatedHalfTurn = isRotatedHalfTurn
        WebCore.MacControlPainter.drawLayer(drawing.layers, layer, options)
    }

    // MARK: AppKit's current context and appearance

    // LocalCurrentContextSaver.
    private func withCurrentContext(_ context: CGContext, flipped: Bool, _ body: () -> Void) {
        let savedContext = NSGraphicsContext.current
        if savedContext?.cgContext === context {
            body()
            return
        }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        body()
        NSGraphicsContext.current = savedContext
    }

    // LocalCurrentGraphicsContext.
    private func withCurrentGraphicsContext(_ context: CGContext, flipped: Bool = true, _ body: () -> Void) {
        context.saveGState()
        withCurrentContext(context, flipped: flipped, body)
        context.restoreGState()
    }

    // LocalDefaultSystemAppearance.
    private func withControlAppearance(_ drawing: MacControlDrawing, _ body: @MainActor () -> Void) {
        guard var appearance = NSAppearance(named: drawing.state.usesDarkAppearance ? .darkAqua : .aqua) else {
            body()
            return
        }
        if let accentColor = drawing.accentColor {
            // The internal SDK's declaration returns an optional.
            guard let tintedAppearance = appearance.applyingTintColor(accentColor) as NSAppearance? else {
                body()
                return
            }
            appearance = tintedAppearance
        }
        withDrawingAppearance(appearance, body)
    }

    private func drawCoreUI(_ rect: CGRect, _ context: CGContext, _ options: [CFString: CFTypeRef]) {
        NSAppearance.currentDrawing()._draw(in: rect, context: context, options: options)
    }

    // MARK: Cell states

    private static var userPrefersContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private static var userPrefersWithoutColorDifferentiation: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    private static func updateCheckedState(_ cell: NSCell, _ state: WebCore.MacControlState) {
        let oldIndeterminate = cell.state == .mixed
        let indeterminate = state.isIndeterminate
        let oldChecked = cell.state == .on
        let checked = state.isChecked
        if oldIndeterminate == indeterminate && oldChecked == checked {
            return
        }
        let newState: NSControl.StateValue = indeterminate ? .mixed : (checked ? .on : .off)
        if let buttonCell = cell as? NSButtonCell {
            buttonCell._setState(newState.rawValue, animated: false)
        } else {
            cell.state = newState
        }
    }

    private static func updateEnabledState(_ cell: NSCell, _ state: WebCore.MacControlState) {
        if state.isEnabled == cell.isEnabled {
            return
        }
        cell.isEnabled = state.isEnabled
    }

    private static func updateFocusedState(_ cell: NSCell, _ state: WebCore.MacControlState) {
        if state.isFocused == cell.showsFirstResponder {
            return
        }
        cell.showsFirstResponder = state.isFocused
    }

    private static func updatePressedState(_ cell: NSCell, _ state: WebCore.MacControlState) {
        if state.isPressed == cell.isHighlighted {
            return
        }
        if let buttonCell = cell as? NSButtonCell {
            buttonCell._setHighlighted(state.isPressed, animated: false)
        } else {
            cell.isHighlighted = state.isPressed
        }
    }

    // MARK: Control sizes

    private static func cellSizeIndex(_ controlSize: NSControl.ControlSize) -> Int {
        Int(controlSize.rawValue)
    }

    // The cell size each control has for each NSControlSize, or none.
    private func cellSize(_ controlSize: NSControl.ControlSize, _ state: WebCore.MacControlState) -> MacIntSize {
        let index = Self.cellSizeIndex(controlSize)
        switch state.appearance {
        case .Button, .DefaultButton, .PushButton, .SquareButton:
            // Buttons really only constrain height. They respect width.
            return [
                MacIntSize(width: 0, height: 20), MacIntSize(width: 0, height: 16), MacIntSize(width: 0, height: 13),
                MacIntSize(width: 0, height: 28),
            ][index]
        case .Checkbox:
            return [
                MacIntSize(width: 14, height: 14), MacIntSize(width: 12, height: 12), MacIntSize(width: 10, height: 10),
                MacIntSize(width: 16, height: 16),
            ][index]
        case .Radio:
            if state.usesLargeControls {
                return [
                    MacIntSize(width: 14, height: 14), MacIntSize(width: 12, height: 12), MacIntSize(width: 10, height: 10),
                    MacIntSize(width: 16, height: 16),
                ][index]
            }
            return [
                MacIntSize(width: 16, height: 16), MacIntSize(width: 12, height: 12), MacIntSize(width: 10, height: 10),
                MacIntSize(width: 0, height: 0),
            ][index]
        case .InnerSpinButton:
            return [
                MacIntSize(width: 19, height: 27), MacIntSize(width: 15, height: 22), MacIntSize(width: 13, height: 15),
                MacIntSize(width: 19, height: 27),
            ][index]
        case .Menulist:
            return [
                MacIntSize(width: 0, height: 21), MacIntSize(width: 0, height: 18), MacIntSize(width: 0, height: 15),
                MacIntSize(width: 0, height: 24),
            ][index]
        case .ProgressBar:
            return [
                MacIntSize(width: 0, height: 20), MacIntSize(width: 0, height: 12), MacIntSize(width: 0, height: 12),
                MacIntSize(width: 0, height: 20),
            ][index]
        case .SearchFieldCancelButton:
            return [
                MacIntSize(width: 22, height: 22), MacIntSize(width: 19, height: 19), MacIntSize(width: 15, height: 15),
                MacIntSize(width: 22, height: 22),
            ][index]
        case .Switch:
            return Self.switchCellSize(controlSize)
        default:
            return MacIntSize(width: 0, height: 0)
        }
    }

    private func cellOutsets(_ controlSize: NSControl.ControlSize, _ state: WebCore.MacControlState) -> MacIntOutsets {
        let index = Self.cellSizeIndex(controlSize)
        switch state.appearance {
        case .Button, .DefaultButton, .PushButton, .SquareButton:
            // FIXME: Determine these values programmatically.
            // https://bugs.webkit.org/show_bug.cgi?id=251066
            return [
                MacIntOutsets(top: 5, right: 7, bottom: 7, left: 7),
                MacIntOutsets(top: 4, right: 6, bottom: 7, left: 6),
                MacIntOutsets(top: 1, right: 2, bottom: 2, left: 2),
                MacIntOutsets(top: 6, right: 6, bottom: 6, left: 6),
            ][index]
        case .Checkbox:
            return [
                MacIntOutsets(top: 2, right: 2, bottom: 2, left: 2),
                MacIntOutsets(top: 2, right: 1, bottom: 2, left: 1),
                MacIntOutsets(top: 0, right: 0, bottom: 1, left: 0),
                MacIntOutsets(top: 2, right: 2, bottom: 2, left: 2),
            ][index]
        case .Radio:
            return [
                MacIntOutsets(top: 1, right: 0, bottom: 1, left: 2),
                MacIntOutsets(top: 1, right: 1, bottom: 2, left: 1),
                MacIntOutsets(top: 0, right: 0, bottom: 1, left: 1),
                MacIntOutsets(top: 1, right: 0, bottom: 1, left: 2),
            ][index]
        case .Menulist:
            return [
                MacIntOutsets(top: 0, right: 3, bottom: 1, left: 3),
                MacIntOutsets(top: 0, right: 3, bottom: 2, left: 3),
                MacIntOutsets(top: 0, right: 1, bottom: 0, left: 1),
                MacIntOutsets(top: 0, right: 6, bottom: 2, left: 6),
            ][index]
        case .ProgressBar:
            return MacIntOutsets(top: 0, right: 0, bottom: 1, left: 0)
        case .Switch:
            return Self.switchCellOutsets(controlSize)
        default:
            return MacIntOutsets(top: 0, right: 0, bottom: 0, left: 0)
        }
    }

    private static func inflatedRect(
        _ bounds: MacFloatRect,
        _ size: MacFloatSize,
        _ outsets: MacIntOutsets,
        _ state: WebCore.MacControlState
    ) -> MacFloatRect {
        var inflatedRect = MacFloatRect(bounds.location, size)
        inflatedRect.expand(
            top: Float(outsets.top) * state.zoomFactor,
            right: Float(outsets.right) * state.zoomFactor,
            bottom: Float(outsets.bottom) * state.zoomFactor,
            left: Float(outsets.left) * state.zoomFactor
        )
        var union = bounds
        union.formUnion(inflatedRect)
        return union
    }

    private func controlSizeForFont(_ state: WebCore.MacControlState) -> NSControl.ControlSize {
        if state.fontSize >= 21 && state.usesLargeControls {
            return .large
        }
        if state.fontSize >= 16 {
            return .regular
        }
        if state.fontSize >= 11 {
            return .small
        }
        return .mini
    }

    private func controlSizeForSystemFont(_ state: WebCore.MacControlState) -> NSControl.ControlSize {
        let fontSize = CGFloat(state.fontSize)
        if fontSize >= NSFont.systemFontSize(for: .large) && state.usesLargeControls {
            return .large
        }
        if fontSize >= NSFont.systemFontSize(for: .regular) {
            return .regular
        }
        if fontSize >= NSFont.systemFontSize(for: .small) {
            return .small
        }
        return .mini
    }

    private func controlSizeForSize(_ size: MacFloatSize, _ state: WebCore.MacControlState) -> NSControl.ControlSize {
        func fits(_ controlSize: NSControl.ControlSize) -> Bool {
            let cellSize = cellSize(controlSize, state)
            return size.width >= Float(truncatedInt32(Float(cellSize.width) * state.zoomFactor))
                && size.height >= Float(truncatedInt32(Float(cellSize.height) * state.zoomFactor))
        }
        if state.usesLargeControls && fits(.large) {
            return .large
        }
        if fits(.regular) {
            return .regular
        }
        if fits(.small) {
            return .small
        }
        return .mini
    }

    private func sizeForSystemFont(_ state: WebCore.MacControlState) -> MacIntSize {
        var size = cellSize(controlSizeForSystemFont(state), state)
        size.multiply(by: state.zoomFactor)
        return size
    }

    // MARK: updateCellStates()

    func updateCellStates(_ rect: MacFloatRect, _ state: WebCore.MacControlState) {
        switch state.appearance {
        case .Listbox, .TextArea:
            return
        case .SearchFieldCancelButton:
            // The cancel button's highlight is updated before the search field's states.
            let cancelButtonCell = searchFieldCell.cancelButtonCell
            if !state.isEnabled && !state.isReadOnly {
                if let cancelButtonCell {
                    Self.updatePressedState(cancelButtonCell, state)
                }
            } else if cancelButtonCell?.isHighlighted == true {
                cancelButtonCell?.isHighlighted = false
            }
        default:
            break
        }

        WebControlWindow.hasKeyAppearance = state.isWindowActive

        switch state.appearance {
        case .Button, .DefaultButton, .PushButton, .SquareButton:
            let buttonCell = buttonCellForAppearance(state)
            updateButtonCellStates(buttonCell, rect, state)
            buttonCell.bezelStyle = bezelStyle(rect, state)
        case .ColorWell:
            updateButtonCellStates(buttonCell, rect, state)
            buttonCell.bezelStyle = Self.texturedSquareBezelStyle
        case .Checkbox, .Radio:
            updateButtonCellStates(buttonCellForAppearance(state), rect, state)
        case .Menulist:
            let popUpButtonCell = popUpButtonCell
            popUpButtonCell.userInterfaceLayoutDirection = state.isInlineFlipped ? .rightToLeft : .leftToRight
            Self.updateCheckedState(popUpButtonCell, state)
            Self.updateEnabledState(popUpButtonCell, state)
            Self.updatePressedState(popUpButtonCell, state)
            // Only update if we have to, since AppKit does work even if the size is the same.
            let controlSize = controlSizeForSize(rect.size, state)
            if controlSize != popUpButtonCell.controlSize {
                popUpButtonCell.controlSize = controlSize
            }
        case .Meter:
            updateMeterCellStates(state)
        case .SearchField, .SearchFieldCancelButton:
            updateSearchFieldCellStates(state)
        case .SearchFieldResultsButton, .SearchFieldResultsDecoration:
            updateSearchFieldCellStates(state)
            let searchMenuTemplate = state.appearance == .SearchFieldResultsButton ? searchMenuTemplate : nil
            if searchFieldCell.searchMenuTemplate !== searchMenuTemplate {
                searchFieldCell.searchMenuTemplate = searchMenuTemplate
            }
        case .SliderThumbHorizontal, .SliderThumbVertical:
            Self.updateEnabledState(sliderCell, state)
            Self.updateFocusedState(sliderCell, state)
        default:
            break
        }
    }

    // ButtonControlMac::updateCellStates().
    private func updateButtonCellStates(_ buttonCell: NSButtonCell, _ rect: MacFloatRect, _ state: WebCore.MacControlState) {
        Self.updatePressedState(buttonCell, state)
        Self.updateEnabledState(buttonCell, state)
        Self.updateCheckedState(buttonCell, state)

        if state.isPresenting {
            buttonCell._setHighlighted(true, animated: false)
        }

        // Window inactive state does not need to be checked explicitly, since we paint parented to
        // a view in a window whose key state can be detected.

        // Only update if we have to, since AppKit does work even if the size is the same.
        let controlSize = controlSizeForSize(rect.size, state)
        if controlSize != buttonCell.controlSize {
            buttonCell.controlSize = controlSize
        }
    }

    private func updateMeterCellStates(_ state: WebCore.MacControlState) {
        let levelIndicatorCell = levelIndicatorCell
        levelIndicatorCell.userInterfaceLayoutDirection = state.isInlineFlipped ? .rightToLeft : .leftToRight

        // Because NSLevelIndicatorCell does not support optimum-in-the-middle type coloring,
        // we explicitly control the color instead giving low and high value to NSLevelIndicatorCell as is.
        switch state.meterGaugeRegion {
        case 0:
            // Make meter the green.
            levelIndicatorCell.warningValue = state.meterValue + 1
            levelIndicatorCell.criticalValue = state.meterValue + 2
        case 1:
            // Make the meter yellow.
            levelIndicatorCell.warningValue = state.meterValue - 1
            levelIndicatorCell.criticalValue = state.meterValue + 1
        default:
            // Make the meter red.
            levelIndicatorCell.warningValue = state.meterValue - 2
            levelIndicatorCell.criticalValue = state.meterValue - 1
        }
        levelIndicatorCell.objectValue = NSNumber(value: state.meterValue)
        levelIndicatorCell.minValue = state.meterMinimum
        levelIndicatorCell.maxValue = state.meterMaximum
    }

    // SearchControlMac::updateCellStates().
    private func updateSearchFieldCellStates(_ state: WebCore.MacControlState) {
        let searchFieldCell = searchFieldCell
        searchFieldCell.placeholderString = ""
        searchFieldCell.controlSize = controlSizeForFont(state)
        Self.updateEnabledState(searchFieldCell, state)
        Self.updateFocusedState(searchFieldCell, state)
    }

    // MARK: sizeForBounds() and rectForBounds()

    func sizeForBounds(_ bounds: MacFloatRect, _ state: WebCore.MacControlState) -> MacFloatSize {
        guard state.appearance == .Meter else {
            return bounds.size
        }
        var logicalSize = state.isVertical ? bounds.size.transposed : bounds.size
        // Makes enough room for cell's intrinsic size.
        let cellBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(truncatedInt32(logicalSize.width)),
            height: CGFloat(truncatedInt32(logicalSize.height))
        )
        let cellSize = levelIndicatorCell.cellSize(forBounds: cellBounds)
        logicalSize = MacFloatSize(
            width: max(logicalSize.width, Float(cellSize.width)),
            height: max(logicalSize.height, Float(cellSize.height))
        )
        return state.isVertical ? logicalSize.transposed : logicalSize
    }

    func rectForBounds(_ bounds: MacFloatRect, _ state: WebCore.MacControlState) -> MacFloatRect {
        switch state.appearance {
        case .Button, .DefaultButton, .PushButton, .SquareButton:
            return buttonRectForBounds(bounds, state)
        case .Checkbox, .Radio:
            let controlSize = buttonCellForAppearance(state).controlSize
            var size = cellSize(controlSize, state).floatSize
            size.width *= state.zoomFactor
            size.height *= state.zoomFactor
            return Self.inflatedRect(bounds, size, cellOutsets(controlSize, state), state)
        case .Menulist:
            return menuListRectForBounds(bounds, state)
        case .ProgressBar:
            return progressBarRectForBounds(bounds, state)
        case .SearchFieldCancelButton:
            let sizeBasedOnFontSize = sizeForSystemFont(state)
            let difference = MacFloatSize(
                width: bounds.width - Float(sizeBasedOnFontSize.width),
                height: bounds.height - Float(sizeBasedOnFontSize.height)
            )
            if abs(difference.width) < Float.ulpOfOne && abs(difference.height) < Float.ulpOfOne {
                return bounds
            }
            // Vertically centered and right aligned.
            let location = MacFloatPoint(x: bounds.x + difference.width, y: bounds.y + difference.height / 2)
            return MacFloatRect(location, sizeBasedOnFontSize.floatSize)
        case .SliderThumbHorizontal:
            return bounds
        case .SliderThumbVertical:
            // Make the height of the vertical slider slightly larger so NSSliderCell will draw a vertical slider.
            let verticalSliderHeightPadding: Float = 0.1
            return MacFloatRect(
                bounds.location,
                MacFloatSize(width: bounds.width + 0, height: bounds.height + verticalSliderHeightPadding * state.zoomFactor)
            )
        case .SliderHorizontal, .SliderVertical:
            return sliderTrackRectForBounds(bounds, state)
        default:
            return bounds
        }
    }

    // MARK: draw()

    func draw(_ drawing: MacControlDrawing) {
        let state = drawing.state
        if state.appearance == .Listbox || state.appearance == .TextArea {
            drawTextArea(drawing)
            return
        }

        WebControlView.clipBounds = state.focusRingClipRect
        defer { WebControlView.clipBounds = .zero }

        switch state.appearance {
        case .Button, .DefaultButton, .PushButton, .SquareButton:
            drawButton(drawing)
        case .Checkbox, .Radio:
            drawToggleButton(drawing)
        case .ColorWell:
            withControlAppearance(drawing) {
                self.drawCell(drawing, drawing.context, drawing.borderRect, state, self.buttonCell)
            }
        #if ENABLE_SERVICE_CONTROLS
        case .ImageControlsButton:
            withControlAppearance(drawing) {
                if let servicesRolloverButtonCell = self.servicesRolloverButtonCell {
                    self.drawCell(drawing, drawing.context, drawing.borderRect, state, servicesRolloverButtonCell)
                }
            }
        #endif
        case .InnerSpinButton:
            drawInnerSpinButton(drawing)
        case .Menulist:
            drawMenuList(drawing)
        case .MenulistButton:
            drawMenuListButton(drawing)
        case .Meter:
            drawMeter(drawing)
        case .ProgressBar:
            drawProgressBar(drawing)
        case .SearchField:
            drawSearchField(drawing)
        case .SearchFieldCancelButton:
            drawSearchFieldCancelButton(drawing)
        case .SearchFieldResultsButton, .SearchFieldResultsDecoration:
            withZoomedCell(drawing, drawing.borderRect) { logicalRect in
                if let searchButtonCell = self.searchFieldCell.searchButtonCell {
                    self.drawCell(drawing, drawing.context, logicalRect, state, searchButtonCell)
                }
            }
        case .SliderThumbHorizontal, .SliderThumbVertical:
            // Never draw a focus ring for the slider thumb.
            withZoomedCell(drawing, rectForBounds(drawing.borderRect, state)) { logicalRect in
                self.drawCell(drawing, drawing.context, logicalRect, state.withoutFocus, self.sliderCell)
            }
        case .SliderHorizontal, .SliderVertical:
            drawSliderTrack(drawing)
        case .Switch:
            drawSwitchTrack(drawing)
            drawSwitchThumb(drawing)
        case .TextField:
            drawTextField(drawing)
        default:
            break
        }
    }

    // In the control's appearance, with the context scaled by the zoom and the rect scaled back: how most cells draw.
    private func withZoomedCell(_ drawing: MacControlDrawing, _ rect: MacFloatRect, _ body: @MainActor (MacFloatRect) -> Void) {
        withControlAppearance(drawing) {
            let context = drawing.context
            context.saveGState()
            var logicalRect = rect
            if drawing.state.zoomFactor != 1 {
                logicalRect.multiply(by: 1 / drawing.state.zoomFactor)
                context.scaleBy(x: CGFloat(drawing.state.zoomFactor), y: CGFloat(drawing.state.zoomFactor))
            }
            body(logicalRect)
            context.restoreGState()
        }
    }

    // MARK: Cells (ControlMac)

    // Draws through an image buffer when the context is scaled, so that the cell draws at its own size.
    private func drawCell(
        _ drawing: MacControlDrawing,
        _ context: CGContext,
        _ rect: MacFloatRect,
        _ state: WebCore.MacControlState,
        _ cell: NSCell,
        drawCell: Bool = true
    ) {
        let userCTM = context.ctm.concatenating(CGContextGetBaseCTM(context).inverted())
        let useImageBuffer = hypot(userCTM.a, userCTM.b) != 1.0 || hypot(userCTM.c, userCTM.d) != 1.0
        if !useImageBuffer {
            drawCellOrFocusRing(drawing, context, rect, state, cell, drawCell: drawCell)
            return
        }

        let focusRingOutlineWidth: Float = 3
        let focusRingPadding = MacFloatSize(width: focusRingOutlineWidth, height: focusRingOutlineWidth)
        let cellDrawingRect = MacFloatRect(MacFloatPoint(x: focusRingPadding.width, y: focusRingPadding.height), rect.size)
        let imageBufferSize = MacFloatSize(
            width: cellDrawingRect.width + 2 * focusRingPadding.width,
            height: cellDrawingRect.height + 2 * focusRingPadding.height
        )
        let layer = makeLayer(drawing, imageBufferSize, drawing.deviceScaleFactor) { layerContext in
            self.drawCellOrFocusRing(drawing, layerContext, cellDrawingRect, state, cell, drawCell: drawCell)
        }
        if layer == 0 {
            return
        }
        drawLayer(drawing, layer, MacFloatPoint(x: rect.x - focusRingPadding.width, y: rect.y - focusRingPadding.height))
    }

    private func drawCellOrFocusRing(
        _ drawing: MacControlDrawing,
        _ context: CGContext,
        _ rect: MacFloatRect,
        _ state: WebCore.MacControlState,
        _ cell: NSCell,
        drawCell: Bool
    ) {
        if drawCell {
            drawCellInternal(drawing, context, rect, state, cell)
        }
        if state.isFocused {
            drawCellFocusRing(drawing, context, rect, state, cell)
        }
    }

    private func drawCellInternal(
        _ drawing: MacControlDrawing,
        _ context: CGContext,
        _ rect: MacFloatRect,
        _ state: WebCore.MacControlState,
        _ cell: NSCell
    ) {
        // For slider cells, draw only the knob.
        if let sliderCell = cell as? NSSliderCell {
            withCurrentGraphicsContext(context) {
                sliderCell.drawKnob(rect.cgRect)
            }
            return
        }

        if drawing.state.drawsViewlessCells {
            applyViewlessCellSettings(drawing, state, cell)
            // FIXME: rdar://106067079 - Remove un-flipping the flipped coordinates.
            performDrawingWithUnflippedContext(context, rect) { adjustedRect in
                (cell as any WebViewlessCellDrawing).draw(withFrame: adjustedRect.cgRect, in: nil)
            }
            return
        }

        let view = drawingView(rect, state)
        withCurrentGraphicsContext(context) {
            cell.draw(withFrame: rect.cgRect, in: view)
            unsafe cell.controlView = nil
        }
    }

    private func drawCellFocusRing(
        _ drawing: MacControlDrawing,
        _ context: CGContext,
        _ rect: MacFloatRect,
        _ state: WebCore.MacControlState,
        _ cell: NSCell
    ) {
        guard let color = drawing.focusRingColor else {
            return
        }

        context.saveGState()

        var focusRingStyle = CGFocusRingStyle()
        _ = unsafe NSInitializeCGFocusRingStyleForTime(.only, &focusRingStyle, .greatestFiniteMagnitude)

        // We want to respect the CGContext clipping and also not overpaint any
        // existing focus ring. The way to do this is set accumulate to
        // -1. According to CoreGraphics, the reasoning for this behavior has been
        // lost in time.
        focusRingStyle.accumulate = -1

        // The color is opaque, since CoreGraphics applies the opacity when drawing.
        let style = unsafe CGStyleCreateFocusRingWithColor(&focusRingStyle, color)
        CGContextSetStyle(context, style)

        context.beginTransparencyLayer(in: rect.cgRect, auxiliaryInfo: nil)
        if drawing.state.drawsViewlessCells {
            applyViewlessCellSettings(drawing, state, cell)
            // FIXME: rdar://106067079 - Remove un-flipping the flipped coordinates.
            performDrawingWithUnflippedContext(context, rect) { adjustedRect in
                (cell as any WebViewlessCellDrawing).drawFocusRingMask(withFrame: adjustedRect.cgRect, in: nil)
            }
        } else {
            let view = drawingView(rect, state)
            withCurrentGraphicsContext(context) {
                cell.drawFocusRingMask(withFrame: rect.cgRect, in: view)
            }
        }
        context.endTransparencyLayer()

        context.restoreGState()
    }

    private func applyViewlessCellSettings(_ drawing: MacControlDrawing, _ state: WebCore.MacControlState, _ cell: NSCell) {
        cell._fallbackBackingScaleFactor = CGFloat(drawing.deviceScaleFactor)
        cell._fallbackBezelPresentationState = state.isWindowActive ? .activeKey : .inactive
        if state.isInFormSemanticContext {
            cell._fallbackSemanticContext = .form
        }
    }

    private func performDrawingWithUnflippedContext(_ context: CGContext, _ rect: MacFloatRect, _ draw: (MacFloatRect) -> Void) {
        var adjustedRect = rect
        context.saveGState()

        // Move the coordinates origin to topleft of rect.
        context.translateBy(x: CGFloat(adjustedRect.x), y: CGFloat(adjustedRect.y))
        adjustedRect.location = MacFloatPoint(x: 0, y: 0)

        // Un-flip the coordinates.
        context.translateBy(x: 0, y: CGFloat(adjustedRect.height))
        context.scaleBy(x: 1, y: -1)

        withCurrentGraphicsContext(context, flipped: false) {
            draw(adjustedRect)
        }
        context.restoreGState()
    }

    // A fake view, for the cells drawn in a view.
    private func drawingView(_ rect: MacFloatRect, _ state: WebCore.MacControlState) -> WebControlView {
        let view = drawingViewStorage ?? WebControlView()
        drawingViewStorage = view
        view.setFrameSize(rect.size.cgSize)
        view.appearance = NSAppearance.currentDrawing()
        if state.isInFormSemanticContext {
            view._semanticContext = .form
        }
        return view
    }

    private func drawListButton(_ drawing: MacControlDrawing, _ rect: MacFloatRect) {
        let state = drawing.state
        if !state.hasListButton {
            return
        }

        // We can't paint an NSComboBoxCell since they are not height-resizable.

        let comboBoxSize = MacFloatSize(width: 40, height: 19)
        let comboBoxButtonSize = MacFloatSize(width: 16, height: 16)
        let comboBoxButtonInset = MacFloatPoint(x: 5, y: 1)
        let comboBoxButtonCornerRadii: Float = 4

        let desiredComboBoxButtonSize = MacFloatSize(width: 12, height: 12)
        let desiredComboBoxInset: Float = 2

        let comboBoxLayer = makeLayer(drawing, comboBoxSize, drawing.deviceScaleFactor) { comboBoxContext in
            let coreUIState: CFString = state.isPresenting || state.isListButtonPressed ? kCUIStatePressed : kCUIStateActive
            self.drawCoreUI(
                CGRect(x: 0, y: 0, width: CGFloat(comboBoxSize.width), height: CGFloat(comboBoxSize.height)),
                comboBoxContext,
                [
                    kCUIWidgetKey: kCUIWidgetButtonComboBox,
                    kCUISizeKey: kCUISizeRegular,
                    kCUIStateKey: coreUIState,
                    kCUIUserInterfaceLayoutDirectionKey: kCUIUserInterfaceLayoutDirectionLeftToRight,
                ]
            )
        }
        if comboBoxLayer == 0 {
            return
        }

        let comboBoxButtonLayer = makeLayer(drawing, desiredComboBoxButtonSize, drawing.deviceScaleFactor) { comboBoxButtonContext in
            let scale = desiredComboBoxButtonSize.width / comboBoxButtonSize.width
            comboBoxButtonContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            WebCore.MacControlPainter.clipToRoundedRect(
                drawing.layers,
                MacFloatRect(MacFloatPoint(x: 0, y: 0), comboBoxButtonSize).cgRect,
                comboBoxButtonCornerRadii
            )
            comboBoxButtonContext.translateBy(x: CGFloat(-comboBoxButtonInset.x), y: CGFloat(-comboBoxButtonInset.y))
            self.drawLayer(drawing, comboBoxLayer, MacFloatPoint(x: 0, y: 0), isRotatedHalfTurn: true)
        }
        if comboBoxButtonLayer == 0 {
            return
        }

        let isVerticalWritingMode = state.isVertical

        let logicalRect = isVerticalWritingMode ? rect.transposed : rect
        let desiredComboBoxButtonLogicalSize = isVerticalWritingMode ? desiredComboBoxButtonSize.transposed : desiredComboBoxButtonSize

        var listButtonLocation: MacFloatPoint
        let listButtonLogicalTop = logicalRect.center.y - desiredComboBoxButtonLogicalSize.height / 2
        if state.isInlineFlipped {
            listButtonLocation = MacFloatPoint(x: logicalRect.x + desiredComboBoxInset, y: listButtonLogicalTop)
        } else {
            listButtonLocation = MacFloatPoint(
                x: logicalRect.maxX - desiredComboBoxButtonLogicalSize.width - desiredComboBoxInset,
                y: listButtonLogicalTop
            )
        }

        if isVerticalWritingMode {
            listButtonLocation = listButtonLocation.transposed
        }

        drawLayer(drawing, comboBoxButtonLayer, listButtonLocation)
    }

    // MARK: Buttons (ButtonMac, ToggleButtonMac)

    // NSBezelStyleShadowlessSquare and NSBezelStyleTexturedSquare, which AppKit will deprecate.
    private static let shadowlessSquareBezelStyle = NSButton.BezelStyle(rawValue: 6) ?? .smallSquare
    private static let texturedSquareBezelStyle = NSButton.BezelStyle(rawValue: 8) ?? .smallSquare

    private func bezelStyle(_ rect: MacFloatRect, _ state: WebCore.MacControlState) -> NSButton.BezelStyle {
        let shadowlessSquare = Self.shadowlessSquareBezelStyle
        if state.appearance == .SquareButton {
            return shadowlessSquare
        }
        let controlSize: NSControl.ControlSize = state.usesLargeControls ? .large : .regular
        let size = cellSize(controlSize, state)
        if rect.height > Float(size.height) * state.zoomFactor {
            return shadowlessSquare
        }
        return .push
    }

    private func buttonRectForBounds(_ bounds: MacFloatRect, _ state: WebCore.MacControlState) -> MacFloatRect {
        let buttonCell = buttonCellForAppearance(state)
        if buttonCell.bezelStyle != .push {
            return bounds
        }

        let controlSize = buttonCell.controlSize
        // Explicitly use a float size to support non-integral sizes following zoom.
        var size = cellSize(controlSize, state).floatSize
        size.width *= state.zoomFactor
        size.height *= state.zoomFactor
        size.width = bounds.width

        var rect = bounds
        let delta = rect.height - size.height
        if delta > 0 {
            rect.outsetY(-delta / 2)
        }
        return Self.inflatedRect(rect, size, cellOutsets(controlSize, state), state)
    }

    private func drawButton(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withZoomedCell(drawing, buttonRectForBounds(drawing.borderRect, state)) { inflatedRect in
            self.drawCell(drawing, drawing.context, inflatedRect, state, self.buttonCellForAppearance(state))
        }
    }

    private func drawToggleButton(_ drawing: MacControlDrawing) {
        let state = drawing.state
        let buttonCell = buttonCellForAppearance(state)
        withZoomedCell(drawing, rectForBounds(drawing.borderRect, state)) { logicalRect in
            let context = drawing.context
            if buttonCell._stateAnimationRunning() {
                context.translateBy(x: CGFloat(logicalRect.x), y: CGFloat(logicalRect.y))
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: CGFloat(-logicalRect.height))
                buttonCell._renderCurrentAnimationFrame(in: context, atLocation: .zero)
                if !buttonCell._stateAnimationRunning() && state.isFocused {
                    self.drawCell(drawing, context, logicalRect, state, buttonCell, drawCell: false)
                }
            } else {
                self.drawCell(drawing, context, logicalRect, state, buttonCell)
            }
        }
    }

    // MARK: Inner spin button (InnerSpinButtonMac)

    private func drawInnerSpinButton(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withControlAppearance(drawing) {
            // We don't use NSStepperCell because there are no ways to draw an
            // NSStepperCell with the up button highlighted.

            let coreUIState: CFString
            if !state.isEnabled {
                coreUIState = kCUIStateDisabled
            } else if state.isPressed {
                coreUIState = kCUIStatePressed
            } else {
                coreUIState = kCUIStateActive
            }

            let coreUISize: CFString
            let controlSize = self.controlSizeForSize(drawing.borderRect.size, state)
            if controlSize == .mini {
                coreUISize = kCUISizeMini
            } else if controlSize == .small {
                coreUISize = kCUISizeSmall
            } else {
                coreUISize = kCUISizeRegular
            }

            var logicalRect = MacIntRect(drawing.borderRect)

            let context = drawing.context
            context.saveGState()

            if state.zoomFactor != 1 {
                logicalRect.multiply(by: 1 / state.zoomFactor)
                context.scaleBy(x: CGFloat(state.zoomFactor), y: CGFloat(state.zoomFactor))
            }

            self.drawCoreUI(
                logicalRect.cgRect,
                context,
                [
                    kCUIWidgetKey: kCUIWidgetButtonLittleArrows,
                    kCUISizeKey: coreUISize,
                    kCUIStateKey: coreUIState,
                    kCUIValueKey: NSNumber(value: Int32(state.isSpinUp ? 1 : 0)),
                    kCUIIsFlippedKey: NSNumber(value: false),
                    kCUIScaleKey: NSNumber(value: Int32(1)),
                    kCUIMaskOnlyKey: NSNumber(value: false),
                ]
            )

            context.restoreGState()
        }
    }

    // MARK: Menu lists (MenuListMac, MenuListButtonMac)

    private func menuListRectForBounds(_ bounds: MacFloatRect, _ state: WebCore.MacControlState) -> MacFloatRect {
        let minimumMenuListSize = sizeForSystemFont(state).width
        if bounds.width < Float(minimumMenuListSize) {
            return bounds
        }

        let controlSize = popUpButtonCell.controlSize
        var size = cellSize(controlSize, state)
        let outsets = cellOutsets(controlSize, state)

        size.multiply(by: state.zoomFactor)
        size.width = truncatedInt32(bounds.width)

        // Make enough room for the shadow.
        return Self.inflatedRect(bounds, size.floatSize, outsets, state)
    }

    private func drawMenuList(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withZoomedCell(drawing, menuListRectForBounds(drawing.borderRect, state)) { inflatedRect in
            self.drawCell(drawing, drawing.context, inflatedRect, state, self.popUpButtonCell)
        }
    }

    // SF symbols 6: chevron.up.chevron.down / semibold / 20pt.
    // FIXME: This is duplicated with RenderThemeCocoa.mm.
    private enum MenuListButtonGlyph {
        enum Element {
            case move(Float, Float)
            case line(Float, Float)
            case curve(Float, Float, Float, Float, Float, Float)
        }

        static let elements: [Element] = [
            .move(7.05356, 0.0),
            .curve(6.6506, 0.0, 6.31419, 0.159764, 5.98845, 0.476187),
            .line(0.449547, 5.79359),
            .curve(0.188162, 6.04876, 0.0, 6.37185, 0.0, 6.75753),
            .curve(0.0, 7.5262, 0.619975, 8.0783, 1.31101, 8.0783),
            .curve(1.64075, 8.0783, 1.99003, 7.97934, 2.27895, 7.69662),
            .line(7.05356, 3.02633),
            .line(11.8215, 7.69662),
            .curve(12.1171, 7.97268, 12.4597, 8.0783, 12.7895, 8.0783),
            .curve(13.4805, 8.0783, 14.1005, 7.5262, 14.1005, 6.75753),
            .curve(14.1005, 6.37185, 13.9159, 6.04876, 13.6509, 5.79359),
            .line(8.11201, 0.476187),
            .curve(7.78627, 0.159764, 7.44987, 0.0, 7.05356, 0.0),
            .move(7.05356, 20.1625),
            .curve(7.44987, 20.1625, 7.78627, 19.9961, 8.11201, 19.6833),
            .line(13.6509, 14.3659),
            .curve(13.9159, 14.1071, 14.1005, 13.7907, 14.1005, 13.3984),
            .curve(14.1005, 12.6297, 13.4805, 12.0811, 12.7895, 12.0811),
            .curve(12.4597, 12.0811, 12.1171, 12.1899, 11.8215, 12.4659),
            .line(7.05356, 17.1362),
            .line(2.27895, 12.4659),
            .curve(1.99003, 12.1801, 1.64075, 12.0811, 1.31101, 12.0811),
            .curve(0.619975, 12.0811, 0.0, 12.6297, 0.0, 13.3984),
            .curve(0.0, 13.7907, 0.188162, 14.1071, 0.449547, 14.3659),
            .line(5.98845, 19.6833),
            .curve(6.31419, 19.9961, 6.6506, 20.1625, 7.05356, 20.1625),
        ]

        static let baseWidth: Float = 14.4618
        static let baseHeight: Float = 20.1723

        // Path::transform() of a translation then a scale: AffineTransform's mapPoint(), in double, narrowed to float.
        static func glyphPath(origin: MacFloatPoint, scale: Float) -> CGPath {
            func map(_ x: Float, _ y: Float) -> CGPoint {
                let mappedX = Float(Double(scale) * Double(x) + 0 * Double(y) + Double(origin.x))
                let mappedY = Float(0 * Double(x) + Double(scale) * Double(y) + Double(origin.y))
                return CGPoint(x: CGFloat(mappedX), y: CGFloat(mappedY))
            }
            let path = CGMutablePath()
            for element in elements {
                switch element {
                case .move(let x, let y):
                    path.move(to: map(x, y))
                case .line(let x, let y):
                    path.addLine(to: map(x, y))
                case .curve(let x1, let y1, let x2, let y2, let x, let y):
                    path.addCurve(to: map(x, y), control1: map(x1, y1), control2: map(x2, y2))
                }
            }
            return path
        }
    }

    private func drawMenuListButton(_ drawing: MacControlDrawing) {
        let state = drawing.state
        var bounds = drawing.borderRect
        bounds.contract(top: state.borderTop, right: state.borderRight, bottom: state.borderBottom, left: state.borderLeft)
        if bounds.isEmpty {
            return
        }

        let glyphScale = 0.55 * state.fontSize / MenuListButtonGlyph.baseWidth
        let glyphSize = MacFloatSize(width: MenuListButtonGlyph.baseWidth * glyphScale, height: MenuListButtonGlyph.baseHeight * glyphScale)

        let isVerticalWritingMode = state.isVertical
        let logicalBounds = isVerticalWritingMode ? bounds.transposed : bounds

        let glyphInlineSize = isVerticalWritingMode ? glyphSize.height : glyphSize.width
        let glyphBlockSize = isVerticalWritingMode ? glyphSize.width : glyphSize.height

        let arrowPaddingAfter: Int32 = 6
        let endEdge: Float
        if state.isInlineFlipped {
            endEdge = logicalBounds.x + Float(arrowPaddingAfter) * state.zoomFactor
        } else {
            endEdge = logicalBounds.maxX - Float(arrowPaddingAfter) * state.zoomFactor - glyphInlineSize
        }

        var glyphOrigin = MacFloatPoint(x: endEdge, y: logicalBounds.y + (logicalBounds.height - glyphBlockSize) / 2)
        if isVerticalWritingMode {
            glyphOrigin = glyphOrigin.transposed
        }

        guard let textColor = drawing.textColor else {
            return
        }
        let context = drawing.context
        context.saveGState()
        context.setFillColor(textColor)
        CGRendererDrawPath(
            context,
            state.fillsEvenOdd ? .eoFill : .fill,
            MenuListButtonGlyph.glyphPath(origin: glyphOrigin, scale: glyphScale)
        )
        context.restoreGState()
    }

    // MARK: Meter (MeterMac)

    private func drawMeter(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withControlAppearance(drawing) {
            let context = drawing.context
            context.saveGState()
            var rect = drawing.borderRect
            if state.isVertical {
                rect.size = rect.size.transposed
                context.translateBy(x: CGFloat(rect.height), y: 0)
                context.translateBy(x: CGFloat(rect.x), y: CGFloat(rect.y))
                context.rotate(by: CGFloat(piOverTwoFloat))
                context.translateBy(x: CGFloat(-rect.x), y: CGFloat(-rect.y))
            }
            self.drawCell(drawing, context, rect, state, self.levelIndicatorCell)
            context.restoreGState()
        }
    }

    // MARK: Progress bar (ProgressBarMac)

    private func progressBarRectForBounds(_ bounds: MacFloatRect, _ state: WebCore.MacControlState) -> MacFloatRect {
        let isVerticalWritingMode = state.isVertical
        var logicalBounds = bounds
        if isVerticalWritingMode {
            logicalBounds.size = bounds.size.transposed
        }

        let minimumProgressBarBlockSize = sizeForSystemFont(state).height
        if logicalBounds.height > Float(minimumProgressBarBlockSize) {
            return bounds
        }

        let controlSize = controlSizeForFont(state)
        var size = cellSize(controlSize, state)
        var outsets = cellOutsets(controlSize, state)
        size.multiply(by: state.zoomFactor)

        if isVerticalWritingMode {
            outsets = MacIntOutsets(top: outsets.left, right: outsets.top, bottom: outsets.right, left: outsets.bottom)
            size.width = size.height
            size.height = truncatedInt32(bounds.height)
        } else {
            size.width = truncatedInt32(bounds.width)
        }

        // Make enough room for the shadow.
        return Self.inflatedRect(bounds, size.floatSize, outsets, state)
    }

    private func drawProgressBar(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withControlAppearance(drawing) {
            let isVerticalWritingMode = state.isVertical
            var inflatedRect = self.progressBarRectForBounds(drawing.borderRect, state)
            if isVerticalWritingMode {
                inflatedRect.size = inflatedRect.size.transposed
            }

            let controlSize = self.controlSizeForFont(state)
            let isIndeterminate = state.progressPosition < 0
            let isActive = state.isWindowActive

            let coreUISize: CFString
            switch controlSize {
            case .mini, .small:
                coreUISize = kCUISizeSmall
            default:
                coreUISize = kCUISizeRegular
            }

            let layer = self.makeLayer(drawing, inflatedRect.size, drawing.deviceScaleFactor) { layerContext in
                self.drawCoreUI(
                    CGRect(x: 0, y: 0, width: CGFloat(inflatedRect.width), height: CGFloat(inflatedRect.height)),
                    layerContext,
                    [
                        kCUIWidgetKey: isIndeterminate ? kCUIWidgetProgressIndeterminateBar : kCUIWidgetProgressBar,
                        kCUIValueKey: NSNumber(value: isIndeterminate ? 1 : min((1.0).nextDown, state.progressPosition)),
                        kCUISizeKey: coreUISize,
                        kCUIUserInterfaceLayoutDirectionKey: kCUIUserInterfaceLayoutDirectionLeftToRight,
                        kCUIScaleKey: NSNumber(value: drawing.deviceScaleFactor),
                        kCUIPresentationStateKey: isActive ? kCUIPresentationStateActiveKey : kCUIPresentationStateInactive,
                        kCUIOrientationKey: kCUIOrientHorizontal,
                        kCUIAnimationStartTimeKey: NSNumber(value: state.progressAnimationStartTime),
                        kCUIAnimationTimeKey: NSNumber(value: state.progressAnimationTime),
                    ]
                )
            }
            if layer == 0 {
                return
            }

            let context = drawing.context
            context.saveGState()
            if isVerticalWritingMode {
                context.translateBy(x: CGFloat(inflatedRect.height), y: 0)
                context.translateBy(x: CGFloat(inflatedRect.x), y: CGFloat(inflatedRect.y))
                context.rotate(by: CGFloat(piOverTwoFloat))
                context.translateBy(x: CGFloat(-inflatedRect.x), y: CGFloat(-inflatedRect.y))
            }
            if state.isInlineFlipped {
                context.translateBy(x: CGFloat(2 * inflatedRect.x + inflatedRect.width), y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            self.drawLayer(drawing, layer, inflatedRect.location)
            context.restoreGState()
        }
    }

    // MARK: Search fields (SearchFieldMac, SearchFieldCancelButtonMac)

    private func drawSearchField(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withZoomedCell(drawing, drawing.borderRect) { logicalRect in
            let searchFieldCell = self.searchFieldCell
            searchFieldCell.searchButtonCell = nil
            self.drawCell(drawing, drawing.context, logicalRect, state, searchFieldCell)
            searchFieldCell.resetSearchButtonCell()

            self.drawListButton(drawing, drawing.borderRect)
        }
    }

    private func drawSearchFieldCancelButton(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withZoomedCell(drawing, rectForBounds(drawing.borderRect, state)) { logicalRect in
            // Never draw a focus ring for the cancel button.
            if let cancelButtonCell = self.searchFieldCell.cancelButtonCell {
                self.drawCell(drawing, drawing.context, logicalRect, state.withoutFocus, cancelButtonCell)
            }
        }
    }

    // MARK: Slider track (SliderTrackMac)

    private func sliderTrackRectForBounds(_ bounds: MacFloatRect, _ state: WebCore.MacControlState) -> MacFloatRect {
        let sliderTrackWidth: Int32 = 5
        let trackWidth = Float(sliderTrackWidth) * state.zoomFactor
        var rect = bounds

        // Set the height/width and align the location in the center of the difference.
        if state.appearance == .SliderHorizontal {
            rect.height = trackWidth
            rect.y = rect.y + (bounds.height - rect.height) / 2
        } else {
            rect.width = trackWidth
            rect.x = rect.x + (bounds.width - rect.width) / 2
        }
        return rect
    }

    private func drawSliderTrack(_ drawing: MacControlDrawing) {
        let state = drawing.state
        let sliderTrackRadius: Float = 2
        let context = drawing.context
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return
        }

        context.saveGState()

        let logicalRect = sliderTrackRectForBounds(drawing.borderRect, state)
        context.clip(to: logicalRect.cgRect)

        // Interpolates from { 0, 0, 0, 0.678 } to { 0, 0, 0, 0.13 }.
        var callbacks = unsafe CGFunctionCallbacks(version: 0, evaluate: sliderTrackGradientInterpolate, releaseInfo: nil)
        guard
            let function = unsafe CGFunction(
                info: nil,
                domainDimension: 1,
                domain: nil,
                rangeDimension: 4,
                range: nil,
                callbacks: &callbacks
            )
        else {
            context.restoreGState()
            return
        }

        let shading: CGShading?
        if state.isVerticalSlider {
            shading = CGShading(
                axialSpace: colorSpace,
                start: CGPoint(x: CGFloat(logicalRect.x), y: CGFloat(logicalRect.maxY)),
                end: CGPoint(x: CGFloat(logicalRect.maxX), y: CGFloat(logicalRect.maxY)),
                function: function,
                extendStart: false,
                extendEnd: false
            )
        } else {
            shading = CGShading(
                axialSpace: colorSpace,
                start: CGPoint(x: CGFloat(logicalRect.x), y: CGFloat(logicalRect.y)),
                end: CGPoint(x: CGFloat(logicalRect.x), y: CGFloat(logicalRect.maxY)),
                function: function,
                extendStart: false,
                extendEnd: false
            )
        }

        WebCore.MacControlPainter.clipToRoundedRect(drawing.layers, logicalRect.cgRect, sliderTrackRadius)
        if let shading {
            context.drawShading(shading)
        }

        context.restoreGState()
    }

    // MARK: Switch (SwitchMac, SwitchMacUtilities)

    private static func switchCellSize(_ controlSize: NSControl.ControlSize) -> MacIntSize {
        [
            MacIntSize(width: 38, height: 22), MacIntSize(width: 32, height: 18), MacIntSize(width: 26, height: 15),
            MacIntSize(width: 38, height: 22),
        ][cellSizeIndex(controlSize)]
    }

    private static func switchCellOutsets(_ controlSize: NSControl.ControlSize) -> MacIntOutsets {
        [
            MacIntOutsets(top: 2, right: 2, bottom: 1, left: 2),
            MacIntOutsets(top: 2, right: 2, bottom: 1, left: 2),
            MacIntOutsets(top: 1, right: 1, bottom: 0, left: 1),
            MacIntOutsets(top: 2, right: 2, bottom: 1, left: 2),
        ][cellSizeIndex(controlSize)]
    }

    private static func switchVisualCellSize(_ size: MacIntSize, _ state: WebCore.MacControlState) -> MacFloatSize {
        var size = size
        if state.isVertical {
            size = size.transposed
        }
        size.multiply(by: state.zoomFactor)
        return size.floatSize
    }

    private static func switchVisualCellOutsets(_ controlSize: NSControl.ControlSize, _ isVertical: Bool) -> MacIntOutsets {
        var outsets = switchCellOutsets(controlSize)
        if isVertical {
            outsets = MacIntOutsets(top: outsets.left, right: outsets.top, bottom: outsets.right, left: outsets.bottom)
        }
        return outsets
    }

    private static func switchCoreUISize(_ controlSize: NSControl.ControlSize) -> CFString {
        if controlSize == .mini {
            return kCUISizeMini
        }
        if controlSize == .small {
            return kCUISizeSmall
        }
        return kCUISizeRegular
    }

    private static func switchEaseInOut(_ progress: Float) -> Float {
        -2.0 * powf(progress, 3.0) + 3.0 * powf(progress, 2.0)
    }

    private static func switchRectWithTransposedSize(_ rect: MacFloatRect, _ isVertical: Bool) -> MacFloatRect {
        var logicalRect = rect
        if isVertical {
            logicalRect.size = logicalRect.size.transposed
        }
        return logicalRect
    }

    private static func switchTrackRectForBounds(_ bounds: MacFloatRect, _ size: MacFloatSize) -> MacFloatRect {
        let offsetY = max((bounds.height - size.height) / 2.0, 0.0)
        return MacFloatRect(MacFloatPoint(x: bounds.x, y: bounds.y + offsetY), size)
    }

    private static func rotateForVerticalWritingMode(_ context: CGContext, _ rect: MacFloatRect) {
        context.translateBy(x: CGFloat(rect.height), y: 0)
        context.translateBy(x: CGFloat(rect.x), y: CGFloat(rect.y))
        context.rotate(by: CGFloat(piOverTwoFloat))
        context.translateBy(x: CGFloat(-rect.x), y: CGFloat(-rect.y))
    }

    private func makeSwitchTrackMaskLayer(
        _ drawing: MacControlDrawing,
        _ trackRectSize: MacFloatSize,
        _ isRTL: Bool,
        _ coreUISize: CFString
    ) -> UInt8 {
        makeLayer(drawing, trackRectSize, drawing.deviceScaleFactor) { maskContext in
            maskContext.saveGState()
            self.drawCoreUI(
                CGRect(x: 0, y: 0, width: CGFloat(trackRectSize.width), height: CGFloat(trackRectSize.height)),
                maskContext,
                [
                    kCUIWidgetKey: kCUIWidgetSwitchFillMask,
                    kCUISizeKey: coreUISize,
                    kCUIUserInterfaceLayoutDirectionKey: isRTL
                        ? kCUIUserInterfaceLayoutDirectionRightToLeft : kCUIUserInterfaceLayoutDirectionLeftToRight,
                    kCUIScaleKey: NSNumber(value: drawing.deviceScaleFactor),
                ]
            )
            maskContext.restoreGState()
        }
    }

    private func makeSwitchTrackStateLayer(
        _ drawing: MacControlDrawing,
        _ maskLayer: UInt8,
        _ trackRectSize: MacFloatSize,
        isOn: Bool,
        needsOnOffLabels: Bool,
        coreUISize: CFString
    ) -> UInt8 {
        let state = drawing.state
        let isInlineFlipped = state.isInlineFlipped
        let isVertical = state.isVertical
        var layer: UInt8 = 0
        withControlAppearance(drawing) {
            let drawingTrackRect = MacFloatRect(x: 0, y: 0, width: trackRectSize.width, height: trackRectSize.height)
            layer = self.makeLayer(drawing, trackRectSize, drawing.deviceScaleFactor) { trackContext in
                let coreUIValue = NSNumber(value: Int32(isOn ? 1 : 0))
                let coreUIState: CFString = !state.isEnabled ? kCUIStateDisabled : state.isPressed ? kCUIStatePressed : kCUIStateActive
                let coreUIPresentation: CFString = state.isWindowActive ? kCUIPresentationStateActiveKey : kCUIPresentationStateInactive
                let coreUIDirection: CFString =
                    isInlineFlipped ? kCUIUserInterfaceLayoutDirectionRightToLeft : kCUIUserInterfaceLayoutDirectionLeftToRight
                let scale = NSNumber(value: drawing.deviceScaleFactor)

                trackContext.saveGState()

                // FIXME: clipping in context() might not always be accurate for context().platformContext().
                WebCore.MacControlPainter.clipToLayer(drawing.layers, maskLayer, drawingTrackRect.cgRect)

                self.drawCoreUI(
                    drawingTrackRect.cgRect,
                    trackContext,
                    [
                        kCUIWidgetKey: kCUIWidgetSwitchFill,
                        kCUIStateKey: coreUIState,
                        kCUIValueKey: coreUIValue,
                        kCUIPresentationStateKey: coreUIPresentation,
                        kCUISizeKey: coreUISize,
                        kCUIUserInterfaceLayoutDirectionKey: coreUIDirection,
                        kCUIScaleKey: scale,
                    ]
                )

                self.drawCoreUI(
                    drawingTrackRect.cgRect,
                    trackContext,
                    [
                        kCUIWidgetKey: kCUIWidgetSwitchBorder,
                        kCUISizeKey: coreUISize,
                        kCUIUserInterfaceLayoutDirectionKey: coreUIDirection,
                        kCUIScaleKey: scale,
                    ]
                )

                if needsOnOffLabels {
                    // This ensures the on label continues to appear upright.
                    if isVertical && isOn {
                        let isRegularSize = coreUISize === kCUISizeRegular
                        if isInlineFlipped {
                            let thumbLogicalLeftAxis = trackRectSize.width - trackRectSize.height
                            let y = -thumbLogicalLeftAxis
                            trackContext.translateBy(x: CGFloat(thumbLogicalLeftAxis), y: CGFloat(y))
                        }
                        if !isInlineFlipped && isRegularSize {
                            trackContext.translateBy(x: 0, y: 1)
                        }
                        Self.rotateForVerticalWritingMode(trackContext, drawingTrackRect)
                    }

                    self.drawCoreUI(
                        drawingTrackRect.cgRect,
                        trackContext,
                        [
                            kCUIWidgetKey: kCUIWidgetSwitchOnOffLabel,
                            // FIXME: Below does not pass kCUIStatePressed like NSCoreUIStateForSwitchState does,
                            // as passing that does not appear to work correctly. Might be related to
                            // rdar://118563716.
                            kCUIStateKey: !state.isEnabled ? kCUIStateDisabled : kCUIStateActive,
                            kCUIValueKey: coreUIValue,
                            kCUIPresentationStateKey: coreUIPresentation,
                            kCUISizeKey: coreUISize,
                            kCUIUserInterfaceLayoutDirectionKey: coreUIDirection,
                            kCUIScaleKey: scale,
                        ]
                    )
                }

                trackContext.restoreGState()
            }
        }
        return layer
    }

    private func drawSwitchTrack(_ drawing: MacControlDrawing) {
        let state = drawing.state
        let context = drawing.context
        context.saveGState()
        defer { context.restoreGState() }

        let isOn = state.switchIsOn
        let isInlineFlipped = state.isInlineFlipped
        let isVertical = state.isVertical
        let needsOnOffLabels = Self.userPrefersWithoutColorDifferentiation
        let progress = Self.switchEaseInOut(state.switchProgress)

        let logicalBounds = Self.switchRectWithTransposedSize(drawing.borderRect, isVertical)
        let controlSize = controlSizeForSize(logicalBounds.size, state)
        let size = Self.switchVisualCellSize(cellSize(controlSize, state), state)
        let outsets = Self.switchVisualCellOutsets(controlSize, isVertical)

        var trackRect = Self.switchTrackRectForBounds(logicalBounds, size)
        var inflatedTrackRect = Self.inflatedRect(trackRect, size, outsets, state)
        if isVertical {
            inflatedTrackRect.size = inflatedTrackRect.size.transposed
        }

        if state.zoomFactor != 1 {
            inflatedTrackRect.multiply(by: 1 / state.zoomFactor)
            trackRect.multiply(by: 1 / state.zoomFactor)
            context.scaleBy(x: CGFloat(state.zoomFactor), y: CGFloat(state.zoomFactor))
        }

        let coreUISize = Self.switchCoreUISize(controlSize)

        let maskLayer = makeSwitchTrackMaskLayer(drawing, inflatedTrackRect.size, isInlineFlipped, coreUISize)
        if maskLayer == 0 {
            return
        }

        func makeTrackLayer(_ isOn: Bool) -> UInt8 {
            makeSwitchTrackStateLayer(
                drawing,
                maskLayer,
                inflatedTrackRect.size,
                isOn: isOn,
                needsOnOffLabels: needsOnOffLabels,
                coreUISize: coreUISize
            )
        }

        let trackLayer: UInt8
        if progress == 0.0 || progress == 1.0 {
            trackLayer = makeTrackLayer(progress == 0.0 ? !isOn : isOn)
            if trackLayer == 0 {
                return
            }
        } else {
            let fromLayer = makeTrackLayer(!isOn)
            if fromLayer == 0 {
                return
            }
            let toLayer = makeTrackLayer(isOn)
            if toLayer == 0 {
                return
            }
            trackLayer = makeLayer(drawing, inflatedTrackRect.size, drawing.deviceScaleFactor) { _ in
                // FIXME: As above, not using context().platformContext() here is likely dubious.
                self.drawLayer(drawing, fromLayer, MacFloatPoint(x: 0, y: 0), alpha: 1.0 - progress)
                self.drawLayer(drawing, toLayer, MacFloatPoint(x: 0, y: 0), alpha: progress, isPlusLighter: true)
            }
            if trackLayer == 0 {
                return
            }
        }

        context.saveGState()
        if isVertical {
            Self.rotateForVerticalWritingMode(context, inflatedTrackRect)
        }
        drawLayer(drawing, trackLayer, inflatedTrackRect.location)
        context.restoreGState()

        if state.isFocused {
            WebCore.MacControlPainter.drawFocusRing(drawing.layers, trackRect.cgRect, state.zoomFactor)
        }
    }

    private func drawSwitchThumb(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withControlAppearance(drawing) {
            let context = drawing.context
            context.saveGState()
            defer { context.restoreGState() }

            let isOn = state.switchIsOn
            let isInlineFlipped = state.isInlineFlipped
            let isVertical = state.isVertical
            let progress = Self.switchEaseInOut(state.switchProgress)

            let logicalBounds = Self.switchRectWithTransposedSize(drawing.borderRect, isVertical)
            let controlSize = self.controlSizeForSize(logicalBounds.size, state)
            let logicalTrackSize = self.cellSize(controlSize, state)
            let logicalThumbSize = MacIntSize(width: logicalTrackSize.height, height: logicalTrackSize.height)
            let trackSize = Self.switchVisualCellSize(logicalTrackSize, state)
            let thumbSize = Self.switchVisualCellSize(logicalThumbSize, state)
            let outsets = Self.switchVisualCellOutsets(controlSize, isVertical)

            let trackRect = Self.switchTrackRectForBounds(logicalBounds, trackSize)
            let thumbRect = Self.switchTrackRectForBounds(logicalBounds, thumbSize)

            var inflatedTrackRect = Self.inflatedRect(trackRect, trackSize, outsets, state)
            var inflatedThumbRect = Self.inflatedRect(thumbRect, thumbSize, outsets, state)
            if isVertical {
                inflatedTrackRect.size = inflatedTrackRect.size.transposed
                inflatedThumbRect.size = inflatedThumbRect.size.transposed
            }

            if state.zoomFactor != 1 {
                inflatedTrackRect.multiply(by: 1 / state.zoomFactor)
                inflatedThumbRect.multiply(by: 1 / state.zoomFactor)
                context.scaleBy(x: CGFloat(state.zoomFactor), y: CGFloat(state.zoomFactor))
            }

            let drawingThumbIsLogicallyLeft = (!isInlineFlipped && !isOn) || (isInlineFlipped && isOn)
            let drawingThumbLogicalXAxis = inflatedTrackRect.width - inflatedThumbRect.width
            let drawingThumbLogicalXAxisProgress = drawingThumbLogicalXAxis * progress
            let drawingThumbLogicalX =
                drawingThumbIsLogicallyLeft ? drawingThumbLogicalXAxis - drawingThumbLogicalXAxisProgress : drawingThumbLogicalXAxisProgress
            let drawingThumbRect = CGRect(
                x: CGFloat(drawingThumbLogicalX),
                y: 0,
                width: CGFloat(inflatedThumbRect.width),
                height: CGFloat(inflatedThumbRect.height)
            )

            let coreUISize = Self.switchCoreUISize(controlSize)

            let maskLayer = self.makeSwitchTrackMaskLayer(drawing, inflatedTrackRect.size, isInlineFlipped, coreUISize)
            if maskLayer == 0 {
                return
            }

            let thumbLayer = self.makeLayer(drawing, inflatedTrackRect.size, drawing.deviceScaleFactor) { thumbContext in
                thumbContext.saveGState()
                // FIXME: clipping in context() might not always be accurate for context().platformContext().
                WebCore.MacControlPainter.clipToLayer(
                    drawing.layers,
                    maskLayer,
                    CGRect(x: 0, y: 0, width: CGFloat(inflatedTrackRect.width), height: CGFloat(inflatedTrackRect.height))
                )
                self.drawCoreUI(
                    drawingThumbRect,
                    thumbContext,
                    [
                        kCUIWidgetKey: kCUIWidgetSwitchKnob,
                        kCUIStateKey: !state.isEnabled ? kCUIStateDisabled : state.isPressed ? kCUIStatePressed : kCUIStateActive,
                        kCUISizeKey: coreUISize,
                        kCUIUserInterfaceLayoutDirectionKey: isInlineFlipped
                            ? kCUIUserInterfaceLayoutDirectionRightToLeft : kCUIUserInterfaceLayoutDirectionLeftToRight,
                        kCUIScaleKey: NSNumber(value: drawing.deviceScaleFactor),
                    ]
                )
                thumbContext.restoreGState()
            }
            if thumbLayer == 0 {
                return
            }

            if isVertical {
                Self.rotateForVerticalWritingMode(context, inflatedTrackRect)
            }
            self.drawLayer(drawing, thumbLayer, inflatedTrackRect.location)
        }
    }

    // MARK: Text controls (TextAreaMac, TextFieldMac)

    private func drawTextArea(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withControlAppearance(drawing) {
            self.withCurrentGraphicsContext(drawing.context) {
                _NSDrawCarbonThemeListBox(drawing.borderRect.cgRect, state.isEnabled && !state.isReadOnly, true, true)
            }
        }
    }

    private func drawTextField(_ drawing: MacControlDrawing) {
        let state = drawing.state
        withControlAppearance(drawing) {
            let context = drawing.context
            context.saveGState()

            var paintRect = drawing.borderRect
            let enabled = state.isEnabled && !state.isReadOnly

            // <rdar://problem/88948646> Prevent AppKit from painting text fields in the light appearance
            // with increased contrast, as the border is not painted, rendering the control invisible.
            if Self.userPrefersContrast && !state.usesDarkAppearance {
                let strokeThickness: Int32 = 1
                var strokeRect = paintRect
                strokeRect.outset(-Float(strokeThickness) / 2.0)
                // Color::black and Color::darkGray, in sRGB.
                let gray: CGFloat = enabled ? 0 : CGFloat(Float(128) / 255)
                if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                    let strokeColor = unsafe CGColor(colorSpace: colorSpace, components: [gray, gray, gray, 1])
                {
                    context.setStrokeColor(strokeColor)
                    context.setLineWidth(CGFloat(strokeThickness))
                    context.addRect(strokeRect.cgRect)
                    context.strokePath()
                }
            } else {
                // <rdar://problem/22896977> We adjust the paint rect here to account for how AppKit draws the text
                // field cell slightly smaller than the rect we pass to drawWithFrame.
                let transform = context.ctm
                let xScale = hypot(transform.a, transform.b)
                let yScale = hypot(transform.c, transform.d)
                if xScale > 1 || yScale > 1 {
                    paintRect.outsetX(Float(1 / xScale))
                    paintRect.outsetY(Float(2 / yScale))
                    paintRect.x += 0
                    paintRect.y += Float(-1 / yScale)
                }

                let textFieldCell = self.textFieldCell
                textFieldCell.isEnabled = enabled
                self.drawCell(drawing, context, paintRect, state.withoutFocus, textFieldCell)
            }

            self.drawListButton(drawing, drawing.borderRect)

            context.restoreGState()
        }
    }
}

// MARK: MacControlPainter

extension WebCore.MacControlPainter {
    // The factory's cells, made on first use. m_swiftState holds a +1 reference, which destroySwiftState() releases.
    private mutating func controlCells() -> MacControlCells {
        if let state = unsafe UnsafeRawPointer(bitPattern: m_swiftState) {
            return unsafe Unmanaged<MacControlCells>.fromOpaque(state).takeUnretainedValue()
        }
        let cells = enterControlDrawing(()) { _ in MacControlCells() }
        m_swiftState = UInt(bitPattern: unsafe Unmanaged.passRetained(cells).toOpaque())
        return cells
    }

    @cxx
    @implementation
    static func destroySwiftState(_ swiftState: UInt) {
        if let state = unsafe UnsafeRawPointer(bitPattern: swiftState) {
            unsafe Unmanaged<MacControlCells>.fromOpaque(state).release()
        }
    }

    @cxx
    @implementation
    mutating func updateCellStates(_ bounds: CGRect, _ state: WebCore.MacControlState) {
        enterControlDrawing((controlCells(), MacFloatRect(bounds), state)) { arguments in
            arguments.0.updateCellStates(arguments.1, arguments.2)
        }
    }

    @cxx
    @implementation
    mutating func sizeForBounds(_ bounds: CGRect, _ state: WebCore.MacControlState) -> CGSize {
        enterControlDrawing((controlCells(), MacFloatRect(bounds), state)) { arguments in
            arguments.0.sizeForBounds(arguments.1, arguments.2).cgSize
        }
    }

    @cxx
    @implementation
    mutating func rectForBounds(_ bounds: CGRect, _ state: WebCore.MacControlState) -> CGRect {
        enterControlDrawing((controlCells(), MacFloatRect(bounds), state)) { arguments in
            arguments.0.rectForBounds(arguments.1, arguments.2).cgRect
        }
    }

    @cxx
    @implementation
    mutating func draw(
        _ context: CGContext?,
        _ borderRect: CGRect,
        _ deviceScaleFactor: Float,
        _ state: WebCore.MacControlState,
        _ accentColor: CFTypeRef?,
        _ textColor: CGColor?,
        _ focusRingColor: CGColor?
    ) {
        guard let context else {
            return
        }
        let cells = controlCells()
        if state.fillsLayer {
            enterControlDrawing((cells, context)) { arguments in
                arguments.0.fillLayer(arguments.1)
            }
            return
        }
        let drawing = MacControlDrawing(
            context: context,
            borderRect: MacFloatRect(borderRect),
            deviceScaleFactor: deviceScaleFactor,
            state: state,
            accentColor: accentColor as? NSColor,
            textColor: textColor,
            focusRingColor: focusRingColor
        )
        enterControlDrawing((cells, drawing)) { arguments in
            arguments.0.draw(arguments.1)
        }
    }

    @cxx
    @implementation
    mutating func servicesRolloverButtonCellSize() -> CGSize {
        #if ENABLE_SERVICE_CONTROLS
        enterControlDrawing(controlCells()) { cells in
            cells.servicesRolloverButtonCellSize()
        }
        #else
        .zero
        #endif
    }
}

#endif // ENABLE_WEBCORE_SWIFT && WTF_PLATFORM_MAC
