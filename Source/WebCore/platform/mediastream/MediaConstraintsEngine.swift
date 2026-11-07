// Copyright (C) 2012 Google Inc. All rights reserved.
// Copyright (C) 2013-2023 Apple Inc. All rights reserved.
// Copyright (C) 2013 Nokia Corporation and/or its subsidiary(-ies).
// Copyright (C) 2015 Ericsson AB. All rights reserved.
// Copyright (C) 2016-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer
//    in the documentation and/or other materials provided with the
//    distribution.
// 3. Neither the name of Google Inc. nor the names of its contributors
//    may be used to endorse or promote products derived from this
//    software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2018-2024 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM

import WebCore_Private.Core.MediaConstraintsSwiftBridge

// The constraint engine of RealtimeMediaSource and RealtimeVideoCaptureSource: the fitness distances of
// https://w3c.github.io/mediacapture-main/#dfn-fitness-distance, SelectSettings, the fitness score of a source, the values
// applyConstraints() gives each setting, and the choice of a video preset. The constraints come from web content. Every
// result is the one the C++ gave, bit for bit: std::min and std::max keep their argument order, integers wrap and divide
// as arm64 does, and doubles convert to integers as arm64 does, so nothing here traps on any input.

// MARK: - Arithmetic as the C++ did it

private protocol ConstraintEngineValue: Comparable {
    static var zero: Self { get }
    var asDouble: Double { get }
    // std::abs, as arm64 computes it for an int: the magnitude of Int32.min is Int32.min.
    var cppMagnitude: Self { get }
    // a - b, wrapping for an int.
    static func cppDifference(_ a: Self, _ b: Self) -> Self
}

extension Int32: ConstraintEngineValue {
    fileprivate var asDouble: Double { Double(self) }
    fileprivate var cppMagnitude: Int32 { self < 0 ? 0 &- self : self }
    fileprivate static func cppDifference(_ a: Int32, _ b: Int32) -> Int32 { a &- b }
}

extension Double: ConstraintEngineValue {
    fileprivate var asDouble: Double { self }
    fileprivate var cppMagnitude: Double { magnitude }
    fileprivate static func cppDifference(_ a: Double, _ b: Double) -> Double { a - b }
}

// std::min and std::max: the first argument unless the second is strictly smaller (larger).
@inline(__always)
private func cppMin<T: Comparable>(_ a: T, _ b: T) -> T {
    b < a ? b : a
}

@inline(__always)
private func cppMax<T: Comparable>(_ a: T, _ b: T) -> T {
    a < b ? b : a
}

// Integer multiplication and division as arm64 does them: wrapping, and a division by zero gives 0.
@inline(__always)
private func arm64Multiply(_ a: Int32, _ b: Int32) -> Int32 {
    a &* b
}

@inline(__always)
private func arm64Divide(_ a: Int32, _ b: Int32) -> Int32 {
    b == 0 ? 0 : a.dividedReportingOverflow(by: b).partialValue
}

// MARK: - Constraints

private struct ConstraintEngineNumeric<Value: ConstraintEngineValue> {
    var min: Value?
    var max: Value?
    var exact: Value?
    var ideal: Value?

    var isEmpty: Bool { min == nil && max == nil && exact == nil && ideal == nil }
    var isMandatory: Bool { min != nil || max != nil || exact != nil }

    // Floating-point constraint values such as "aspectRatio: 1.333" would rarely match exactly.
    private static func nearlyEqual(_ a: Value, _ b: Value) -> Bool {
        (a.asDouble - b.asDouble).magnitude <= 0.00001
    }

    func validForRange(_ rangeMin: Value, _ rangeMax: Value) -> Bool {
        if isEmpty {
            return false
        }
        if let exact {
            if exact < rangeMin && !Self.nearlyEqual(exact, rangeMin) {
                return false
            }
            if exact > rangeMax && !Self.nearlyEqual(exact, rangeMax) {
                return false
            }
        }
        if let min, min > rangeMax && !Self.nearlyEqual(min, rangeMax) {
            return false
        }
        if let max, max < rangeMin && !Self.nearlyEqual(max, rangeMin) {
            return false
        }
        return true
    }

    func fitnessDistance(_ rangeMin: Value, _ rangeMax: Value) -> Double {
        if isEmpty {
            return 0
        }
        var valid = validForRange(rangeMin, rangeMax)
        if let exact {
            if valid, let min, exact < min {
                valid = false
            }
            if valid, let max, exact > max {
                valid = false
            }
            if !valid {
                return .infinity
            }
        }
        if let min {
            if valid, let max, min > max {
                valid = false
            }
            if !valid {
                return .infinity
            }
        }
        if let max {
            if valid, let min, max < min {
                valid = false
            }
            if !valid {
                return .infinity
            }
        }
        guard let constraintIdeal = ideal else {
            return 0
        }
        if constraintIdeal >= rangeMin && constraintIdeal <= rangeMax {
            return 0
        }
        let nearest = constraintIdeal > cppMax(rangeMin, rangeMax) ? rangeMax : rangeMin
        let numerator = Value.cppDifference(nearest, constraintIdeal).cppMagnitude.asDouble
        return numerator / cppMax(nearest.cppMagnitude, constraintIdeal.cppMagnitude).asDouble
    }

    func fitnessDistance(_ range: (min: Value, max: Value)) -> Double {
        fitnessDistance(range.min, range.max)
    }

    func valueForCapabilityRange(_ current: Value, _ capabilityMin: Value, _ capabilityMax: Value) -> Value {
        var value = Value.zero
        var min = capabilityMin
        var max = capabilityMax
        if let exact {
            return exact
        }
        if let constraintMin = self.min {
            value = constraintMin
            if value > min {
                min = value
            }
            if value < min {
                value = min
            }
            // If there is no ideal, don't change if minimum is smaller than current.
            if ideal == nil && value < current {
                value = current
            }
        }
        if let constraintMax = self.max {
            if constraintMax < max {
                max = constraintMax
            }
            if self.min != nil {
                if value > max {
                    value = max
                }
            } else {
                value = constraintMax
                if value > max {
                    value = max
                }
                // If there is no ideal, don't change if maximum is larger than current, as long as current is a valid
                // value for this capability.
                if ideal == nil && current >= min && current < value {
                    value = current
                }
            }
        }
        if let ideal {
            value = cppMax(min, cppMin(max, ideal))
        }
        return value
    }

    func valueForCapabilityRange(_ current: Value, _ range: (min: Value, max: Value)) -> Value {
        valueForCapabilityRange(current, range.min, range.max)
    }

    mutating func merge(_ other: Self) {
        if other.isEmpty {
            return
        }
        if let otherExact = other.exact {
            exact = otherExact
        }
        if let otherMin = other.min {
            min = otherMin
        }
        if let otherMax = other.max {
            max = otherMax
        }
        // https://w3c.github.io/mediacapture-main/#constrainable-interface
        // When processing advanced constraints the User Agent must attempt to apply, individually, any 'ideal'
        // constraints or a constraint given as a bare value for the property.
        if let otherIdeal = other.ideal {
            if let currentIdeal = ideal, !(otherIdeal > currentIdeal) {
                return
            }
            ideal = otherIdeal
        }
    }
}

// Discrete capability values, which the view lends.
private struct ConstraintEngineDiscreteValues: ~Escapable {
    let view: WebCore.MediaConstraintsEngineView
    let first: Int
    let count: Int

    @_lifetime(copy view)
    init(view: borrowing WebCore.MediaConstraintsEngineView, first: Int, count: Int) {
        self.view = copy view
        self.first = first
        self.count = count
    }

    subscript(index: Int) -> Int32 { view.discreteSampleValue(first + index) }

    func contains(_ value: Int32) -> Bool {
        for index in 0..<count where self[index] == value {
            return true
        }
        return false
    }
}

extension ConstraintEngineNumeric where Value == Int32 {
    func fitnessDistance(discreteValues: borrowing ConstraintEngineDiscreteValues) -> Double {
        var minDistance = Double.infinity
        for index in 0..<discreteValues.count {
            let value = discreteValues[index]
            let distance = fitnessDistance(value, value)
            if distance < minDistance {
                minDistance = distance
            }
        }
        return minDistance
    }

    func valueForDiscreteCapabilityValues(_ current: Int32, _ discreteValues: borrowing ConstraintEngineDiscreteValues) -> Int32? {
        var value: Int32?
        var discreteMin: Int32?
        var discreteMax: Int32?
        if let exact {
            return exact
        }
        if let constraintMin = min {
            for index in 0..<discreteValues.count where constraintMin >= discreteValues[index] {
                value = discreteValues[index]
                discreteMin = value
                // If there is no ideal, don't change if minimum is smaller than current.
                if ideal == nil, let chosen = value, chosen < current {
                    value = current
                }
                break
            }
        }
        if let constraintMax = max, discreteValues.count > 0, constraintMax >= discreteValues[0] {
            for index in 0..<discreteValues.count where constraintMax <= discreteValues[index] {
                discreteMax = discreteValues[index]
                value = discreteValues[index]
            }
        }
        if let ideal, discreteValues.contains(ideal) {
            var chosen = ideal
            if let discreteMax {
                chosen = cppMin(discreteMax, chosen)
            }
            if let discreteMin {
                chosen = cppMax(discreteMin, chosen)
            }
            value = chosen
        }
        return value
    }
}

private struct ConstraintEngineBoolean {
    var exact: Bool?
    var ideal: Bool?

    var isEmpty: Bool { exact == nil && ideal == nil }
    var isMandatory: Bool { exact != nil }

    func fitnessDistance(_ value: Bool) -> Double {
        if isEmpty {
            return 0
        }
        if let exact, value != exact {
            return .infinity
        }
        if ideal == nil || ideal == value {
            return 0
        }
        return 1
    }

    mutating func merge(_ other: Self) {
        if other.isEmpty {
            return
        }
        if let otherExact = other.exact {
            exact = otherExact
        }
        if let otherIdeal = other.ideal, ideal == nil || (otherIdeal && ideal == false) {
            ideal = otherIdeal
        }
    }

    // RealtimeMediaSource's booleanSettingFromConstraint(): exact, else ideal, else true.
    var setting: Bool { exact ?? ideal ?? true }
}

// A string list as MediaStringListValues describes it.
private struct ConstraintEngineStringList {
    var applyOrder: UInt32
    var matches: UInt8
    var hasValues: Bool

    init(_ values: WebCore.MediaStringListValues) {
        applyOrder = values.applyOrder
        matches = values.matches
        hasValues = values.hasValues
    }

    func contains(_ index: Int) -> Bool {
        matches & (1 << UInt8(index)) != 0
    }

    // StringConstraint::merge() appends the strings of other that the list doesn't have, so the modes of the merged list
    // are this list's, then those of other's that this list doesn't name, in their order.
    mutating func merge(_ other: Self) {
        guard other.hasValues else {
            return
        }
        var order = applyOrder
        var shift: UInt32 = 0
        while shift < 32 && (order >> shift) & 0xF != 0 {
            shift += 4
        }
        var otherOrder = other.applyOrder
        while otherOrder & 0xF != 0 {
            let entry = otherOrder & 0xF
            if !Self.order(order, contains: entry) && shift < 32 {
                order |= entry << shift
                shift += 4
            }
            otherOrder >>= 4
        }
        applyOrder = order
        matches |= other.matches
        hasValues = true
    }

    private static func order(_ order: UInt32, contains entry: UInt32) -> Bool {
        var remaining = order
        while remaining & 0xF != 0 {
            if remaining & 0xF == entry {
                return true
            }
            remaining >>= 4
        }
        return false
    }

    // The first mode of the list that `accepts` accepts.
    func firstMode(_ accepts: (UInt8) -> Bool) -> UInt8? {
        var remaining = applyOrder
        while remaining & 0xF != 0 {
            let mode = UInt8(remaining & 0xF) - 1
            if accepts(mode) {
                return mode
            }
            remaining >>= 4
        }
        return nil
    }
}

private struct ConstraintEngineString {
    var exact: ConstraintEngineStringList
    var ideal: ConstraintEngineStringList
    var exactWithoutEmptyStrings: ConstraintEngineStringList
    var idealWithoutEmptyStrings: ConstraintEngineStringList

    var isEmpty: Bool { !exact.hasValues && !ideal.hasValues }

    func removingEmptyStrings() -> Self {
        var result = self
        result.exact = exactWithoutEmptyStrings
        result.ideal = idealWithoutEmptyStrings
        return result
    }

    // StringConstraint::fitnessDistance(const String&), against string `index` of the ones it was compared with.
    func fitnessDistance(_ index: Int) -> Double {
        if isEmpty {
            return 0
        }
        if exact.hasValues && !exact.contains(index) {
            return .infinity
        }
        if !ideal.hasValues {
            return 0
        }
        return ideal.contains(index) ? 0 : 1
    }

    // StringConstraint::fitnessDistance(const Vector<String>&), against the strings whose bits are set in `indices`.
    func fitnessDistance(anyOf indices: UInt8) -> Double {
        if isEmpty {
            return 0
        }
        var minimumDistance = Double.infinity
        for index in 0..<8 where indices & (1 << UInt8(index)) != 0 {
            minimumDistance = cppMin(minimumDistance, fitnessDistance(index))
        }
        return minimumDistance
    }

    // StringConstraint::find(), with the filter accepting a mode in `modes`: the mode of the first string, exact ones
    // first, whose mode is accepted.
    func firstMode(in accepts: (UInt8) -> Bool) -> UInt8? {
        exact.firstMode(accepts) ?? ideal.firstMode(accepts)
    }

    mutating func merge(_ other: Self) {
        if other.isEmpty {
            return
        }
        exact.merge(other.exact)
        ideal.merge(other.ideal)
        exactWithoutEmptyStrings.merge(other.exactWithoutEmptyStrings)
        idealWithoutEmptyStrings.merge(other.idealWithoutEmptyStrings)
    }
}

private enum ConstraintEngineConstraint {
    case int(ConstraintEngineNumeric<Int32>)
    case double(ConstraintEngineNumeric<Double>)
    case boolean(ConstraintEngineBoolean)
    case string(ConstraintEngineString)
}

// A MediaTrackConstraintSetMap: a nil constraint is absent.
private struct ConstraintEngineSet {
    var width: ConstraintEngineNumeric<Int32>?
    var height: ConstraintEngineNumeric<Int32>?
    var sampleRate: ConstraintEngineNumeric<Int32>?
    var sampleSize: ConstraintEngineNumeric<Int32>?
    var aspectRatio: ConstraintEngineNumeric<Double>?
    var frameRate: ConstraintEngineNumeric<Double>?
    var volume: ConstraintEngineNumeric<Double>?
    var zoom: ConstraintEngineNumeric<Double>?
    var echoCancellation: ConstraintEngineBoolean?
    var torch: ConstraintEngineBoolean?
    var backgroundBlur: ConstraintEngineBoolean?
    var powerEfficient: ConstraintEngineBoolean?
    var facingMode: ConstraintEngineString?
    var deviceId: ConstraintEngineString?
    var groupId: ConstraintEngineString?
    var whiteBalanceMode: ConstraintEngineString?

    init() {
    }

    init(_ values: WebCore.MediaConstraintSetValues) {
        width = Self.numeric(values.width)
        height = Self.numeric(values.height)
        sampleRate = Self.numeric(values.sampleRate)
        sampleSize = Self.numeric(values.sampleSize)
        aspectRatio = Self.numeric(values.aspectRatio)
        frameRate = Self.numeric(values.frameRate)
        volume = Self.numeric(values.volume)
        zoom = Self.numeric(values.zoom)
        echoCancellation = Self.boolean(values.echoCancellation)
        torch = Self.boolean(values.torch)
        backgroundBlur = Self.boolean(values.backgroundBlur)
        powerEfficient = Self.boolean(values.powerEfficient)
        facingMode = Self.string(values.facingMode)
        deviceId = Self.string(values.deviceId)
        groupId = Self.string(values.groupId)
        whiteBalanceMode = Self.string(values.whiteBalanceMode)
    }

    private static func numeric(_ values: WebCore.MediaIntConstraintValues) -> ConstraintEngineNumeric<Int32>? {
        guard values.isPresent else {
            return nil
        }
        return ConstraintEngineNumeric(
            min: values.hasMin ? values.min : nil,
            max: values.hasMax ? values.max : nil,
            exact: values.hasExact ? values.exact : nil,
            ideal: values.hasIdeal ? values.ideal : nil
        )
    }

    private static func numeric(_ values: WebCore.MediaDoubleConstraintValues) -> ConstraintEngineNumeric<Double>? {
        guard values.isPresent else {
            return nil
        }
        return ConstraintEngineNumeric(
            min: values.hasMin ? values.min : nil,
            max: values.hasMax ? values.max : nil,
            exact: values.hasExact ? values.exact : nil,
            ideal: values.hasIdeal ? values.ideal : nil
        )
    }

    private static func boolean(_ values: WebCore.MediaBooleanConstraintValues) -> ConstraintEngineBoolean? {
        guard values.isPresent else {
            return nil
        }
        return ConstraintEngineBoolean(exact: values.hasExact ? values.exact : nil, ideal: values.hasIdeal ? values.ideal : nil)
    }

    private static func string(_ values: WebCore.MediaStringConstraintValues) -> ConstraintEngineString? {
        guard values.isPresent else {
            return nil
        }
        return ConstraintEngineString(
            exact: ConstraintEngineStringList(values.exact),
            ideal: ConstraintEngineStringList(values.ideal),
            exactWithoutEmptyStrings: ConstraintEngineStringList(values.exactWithoutEmptyStrings),
            idealWithoutEmptyStrings: ConstraintEngineStringList(values.idealWithoutEmptyStrings)
        )
    }

    // MediaTrackConstraintSetMap::filter(): the present, non-empty constraints in its order, until `body` returns true.
    func filter(_ body: (WebCore.MediaConstraintType, ConstraintEngineConstraint) -> Bool) {
        if let width, !width.isEmpty, body(.Width, .int(width)) {
            return
        }
        if let height, !height.isEmpty, body(.Height, .int(height)) {
            return
        }
        if let sampleRate, !sampleRate.isEmpty, body(.SampleRate, .int(sampleRate)) {
            return
        }
        if let sampleSize, !sampleSize.isEmpty, body(.SampleSize, .int(sampleSize)) {
            return
        }
        if let aspectRatio, !aspectRatio.isEmpty, body(.AspectRatio, .double(aspectRatio)) {
            return
        }
        if let frameRate, !frameRate.isEmpty, body(.FrameRate, .double(frameRate)) {
            return
        }
        if let volume, !volume.isEmpty, body(.Volume, .double(volume)) {
            return
        }
        if let echoCancellation, !echoCancellation.isEmpty, body(.EchoCancellation, .boolean(echoCancellation)) {
            return
        }
        if let facingMode, !facingMode.isEmpty, body(.FacingMode, .string(facingMode)) {
            return
        }
        if let deviceId, !deviceId.isEmpty, body(.DeviceId, .string(deviceId)) {
            return
        }
        if let groupId, !groupId.isEmpty, body(.GroupId, .string(groupId)) {
            return
        }
        if let whiteBalanceMode, !whiteBalanceMode.isEmpty, body(.WhiteBalanceMode, .string(whiteBalanceMode)) {
            return
        }
        if let zoom, !zoom.isEmpty, body(.Zoom, .double(zoom)) {
            return
        }
        if let torch, !torch.isEmpty, body(.Torch, .boolean(torch)) {
            return
        }
        if let backgroundBlur, !backgroundBlur.isEmpty, body(.BackgroundBlur, .boolean(backgroundBlur)) {
            return
        }
        if let powerEfficient, !powerEfficient.isEmpty, body(.PowerEfficient, .boolean(powerEfficient)) {
            return
        }
    }

    func forEachConstraint(_ body: (WebCore.MediaConstraintType, ConstraintEngineConstraint) -> Void) {
        filter { type, constraint in
            body(type, constraint)
            return false
        }
    }

    var isEmpty: Bool {
        var isEmpty = true
        filter { _, _ in
            isEmpty = false
            return true
        }
        return isEmpty
    }

    // MediaTrackConstraintSetMap::set(), which removes a device ID's empty strings.
    mutating func set(_ type: WebCore.MediaConstraintType, _ constraint: ConstraintEngineConstraint) {
        switch (type, constraint) {
        case (.Width, .int(let value)):
            width = value
        case (.Height, .int(let value)):
            height = value
        case (.SampleRate, .int(let value)):
            sampleRate = value
        case (.SampleSize, .int(let value)):
            sampleSize = value
        case (.AspectRatio, .double(let value)):
            aspectRatio = value
        case (.FrameRate, .double(let value)):
            frameRate = value
        case (.Volume, .double(let value)):
            volume = value
        case (.Zoom, .double(let value)):
            zoom = value
        case (.EchoCancellation, .boolean(let value)):
            echoCancellation = value
        case (.Torch, .boolean(let value)):
            torch = value
        case (.BackgroundBlur, .boolean(let value)):
            backgroundBlur = value
        case (.PowerEfficient, .boolean(let value)):
            powerEfficient = value
        case (.FacingMode, .string(let value)):
            facingMode = value
        case (.DeviceId, .string(let value)):
            deviceId = value.removingEmptyStrings()
        case (.GroupId, .string(let value)):
            groupId = value
        case (.WhiteBalanceMode, .string(let value)):
            whiteBalanceMode = value
        default:
            break
        }
    }

    // MediaTrackConstraintSetMap::merge().
    mutating func merge(_ type: WebCore.MediaConstraintType, _ constraint: ConstraintEngineConstraint) {
        switch (type, constraint) {
        case (.Width, .int(let value)):
            Self.merge(&width, value)
        case (.Height, .int(let value)):
            Self.merge(&height, value)
        case (.SampleRate, .int(let value)):
            Self.merge(&sampleRate, value)
        case (.SampleSize, .int(let value)):
            Self.merge(&sampleSize, value)
        case (.AspectRatio, .double(let value)):
            Self.merge(&aspectRatio, value)
        case (.FrameRate, .double(let value)):
            Self.merge(&frameRate, value)
        case (.Volume, .double(let value)):
            Self.merge(&volume, value)
        case (.Zoom, .double(let value)):
            Self.merge(&zoom, value)
        case (.EchoCancellation, .boolean(let value)):
            Self.merge(&echoCancellation, value)
        case (.Torch, .boolean(let value)):
            Self.merge(&torch, value)
        case (.BackgroundBlur, .boolean(let value)):
            Self.merge(&backgroundBlur, value)
        case (.PowerEfficient, .boolean(let value)):
            Self.merge(&powerEfficient, value)
        case (.FacingMode, .string(let value)):
            Self.merge(&facingMode, value)
        case (.DeviceId, .string(let value)):
            Self.merge(&deviceId, value)
        case (.GroupId, .string(let value)):
            Self.merge(&groupId, value)
        case (.WhiteBalanceMode, .string(let value)):
            Self.merge(&whiteBalanceMode, value)
        default:
            break
        }
    }

    private static func merge<Value: ConstraintEngineValue>(
        _ constraint: inout ConstraintEngineNumeric<Value>?,
        _ other: ConstraintEngineNumeric<Value>
    ) {
        if constraint == nil {
            constraint = other
        } else {
            constraint?.merge(other)
        }
    }

    private static func merge(_ constraint: inout ConstraintEngineBoolean?, _ other: ConstraintEngineBoolean) {
        if constraint == nil {
            constraint = other
        } else {
            constraint?.merge(other)
        }
    }

    private static func merge(_ constraint: inout ConstraintEngineString?, _ other: ConstraintEngineString) {
        if constraint == nil {
            constraint = other
        } else {
            constraint?.merge(other)
        }
    }
}

// MARK: - Video presets

private struct ConstraintEnginePresetRequest {
    var width: Int32?
    var height: Int32?
    var frameRate: Double?
    var zoom: Double?
    var shouldPreferPowerEfficiency = false

    var hasConstraints: Bool { width != nil || height != nil || frameRate != nil || zoom != nil }
}

private struct ConstraintEnginePresetChoice {
    var presetIndex: Int
    var width: Int32
    var height: Int32
    var frameRate: Double
    var zoom: Double
}

// RealtimeVideoCaptureSource's choice of a preset for a size, frame rate and zoom.
private struct ConstraintEnginePresets: ~Escapable {
    let view: WebCore.MediaConstraintsEngineView
    let presetCount: Int
    let standardVideoSizeCount: Int
    let canResizeVideoFrames: Bool
    let currentWidth: Int32
    let currentHeight: Int32
    let currentFrameRate: Double
    let currentZoom: Double

    @_lifetime(copy view)
    init(
        view: borrowing WebCore.MediaConstraintsEngineView,
        presetCount: Int,
        standardVideoSizeCount: Int,
        canResizeVideoFrames: Bool,
        currentWidth: Int32,
        currentHeight: Int32,
        currentFrameRate: Double,
        currentZoom: Double
    ) {
        self.view = copy view
        self.presetCount = presetCount
        self.standardVideoSizeCount = standardVideoSizeCount
        self.canResizeVideoFrames = canResizeVideoFrames
        self.currentWidth = currentWidth
        self.currentHeight = currentHeight
        self.currentFrameRate = currentFrameRate
        self.currentZoom = currentZoom
    }

    private func supportsFrameRate(_ preset: WebCore.MediaVideoPresetValues, _ frameRate: Double) -> Bool {
        let epsilon = 0.001
        for index in 0..<Int(preset.frameRateCount) {
            let range = view.frameRateRange(Int(preset.firstFrameRate) + index)
            if frameRate + epsilon >= range.minimum && frameRate - epsilon <= range.maximum {
                return true
            }
        }
        return false
    }

    private static func supportsZoom(_ preset: WebCore.MediaVideoPresetValues, _ zoom: Double) -> Bool {
        preset.minZoom <= zoom && zoom <= preset.maxZoom
    }

    private func supportsCaptureSize(_ width: Int32?, _ height: Int32?, _ function: (Int32, Int32) -> Bool) -> Bool {
        if let width, let height {
            return function(width, height)
        }
        for index in 0..<standardVideoSizeCount {
            let size = view.standardVideoSize(index)
            if let width {
                if width == size.width && function(size.width, size.height) {
                    return true
                }
            } else if height == size.height && function(size.width, size.height) {
                return true
            }
        }
        return false
    }

    private static func shouldUse(
        _ current: WebCore.MediaVideoPresetValues,
        _ candidate: WebCore.MediaVideoPresetValues,
        _ shouldPreferPowerEfficiency: Bool
    ) -> Bool {
        if shouldPreferPowerEfficiency && candidate.isEfficient && !current.isEfficient {
            return true
        }
        return candidate.width <= current.width && candidate.height <= current.height && candidate.isEfficient
    }

    // Whether `preset` replaces the preset at index `current`, if there is one.
    private func replaces(
        _ current: Int?,
        with preset: WebCore.MediaVideoPresetValues,
        _ shouldPreferPowerEfficiency: Bool
    ) -> Bool {
        guard let current else {
            return true
        }
        return Self.shouldUse(view.preset(current), preset, shouldPreferPowerEfficiency)
    }

    private func frameRate(from preset: WebCore.MediaVideoPresetValues) -> Double {
        var minFrameRate = Double.greatestFiniteMagnitude
        var maxFrameRate = 0.0
        for index in 0..<Int(preset.frameRateCount) {
            let range = view.frameRateRange(Int(preset.firstFrameRate) + index)
            if minFrameRate > range.minimum {
                minFrameRate = range.minimum
            }
            if maxFrameRate < range.maximum {
                maxFrameRate = range.maximum
            }
        }
        return currentFrameRate >= minFrameRate && currentFrameRate <= maxFrameRate ? currentFrameRate : maxFrameRate
    }

    private func zoom(from preset: WebCore.MediaVideoPresetValues) -> Double {
        if currentZoom < preset.minZoom {
            return preset.minZoom
        }
        if currentZoom > preset.maxZoom {
            return preset.maxZoom
        }
        return currentZoom
    }

    private static func aspectRatio(_ width: Int32, _ height: Int32) -> Double {
        Double(width) / Double(height)
    }

    // RealtimeVideoCaptureSource::bestSupportedSizeFrameRateAndZoom().
    func bestMatch(_ request: ConstraintEnginePresetRequest, tryPreservingSize: Bool = true) -> ConstraintEnginePresetChoice? {
        var requestedWidth = request.width
        var requestedHeight = request.height
        let requestedFrameRate = request.frameRate
        let requestedZoom = request.zoom
        if requestedWidth == nil && requestedHeight == nil && requestedFrameRate == nil && requestedZoom == nil {
            return nil
        }

        let initialRequestedWidth = requestedWidth
        let initialRequestedHeight = requestedHeight
        let currentSizeIsEmpty = currentWidth <= 0 || currentHeight <= 0
        if requestedWidth == nil && requestedHeight == nil && !currentSizeIsEmpty && tryPreservingSize {
            requestedWidth = currentWidth
            requestedHeight = currentHeight
        }

        var exactSizePreset: Int?
        var aspectRatioPreset: Int?
        var aspectRatioMatchSize: (width: Int32, height: Int32) = (0, 0)
        var resizePreset: Int?
        var resizeSize: (width: Int32, height: Int32) = (0, 0)

        for index in 0..<presetCount {
            let preset = view.preset(index)

            if let requestedFrameRate, !supportsFrameRate(preset, requestedFrameRate) {
                continue
            }
            if let requestedZoom, !Self.supportsZoom(preset, requestedZoom) {
                continue
            }
            if requestedWidth == nil && requestedHeight == nil {
                exactSizePreset = index
                break
            }

            // Don't look at presets smaller than the requested resolution because we never want to resize larger.
            if let requestedWidth, preset.width < requestedWidth {
                continue
            }
            if let requestedHeight, preset.height < requestedHeight {
                continue
            }

            if supportsCaptureSize(requestedWidth, requestedHeight, { preset.width == $0 && preset.height == $1 }) {
                if exactSizePreset == nil || preset.isEfficient {
                    exactSizePreset = index
                }
                continue
            }

            var encodingSize: (width: Int32, height: Int32) = (0, 0)
            let canResize = canResizeVideoFrames
            let lookForAspectRatioMatch = { (width: Int32, height: Int32) -> Bool in
                if (Self.aspectRatio(preset.width, preset.height) - Self.aspectRatio(width, height)).magnitude > 10e-7
                    || !canResize
                {
                    return false
                }
                encodingSize = (width, height)
                return true
            }
            if supportsCaptureSize(requestedWidth, requestedHeight, lookForAspectRatioMatch) {
                if replaces(aspectRatioPreset, with: preset, request.shouldPreferPowerEfficiency) {
                    aspectRatioPreset = index
                    aspectRatioMatchSize = encodingSize
                }
            }

            if exactSizePreset != nil || aspectRatioPreset != nil {
                continue
            }

            if let requestedWidth, requestedWidth > preset.width {
                continue
            }
            if let requestedHeight, requestedHeight > preset.height {
                continue
            }

            if let requestedWidth, let requestedHeight {
                if replaces(resizePreset, with: preset, request.shouldPreferPowerEfficiency) {
                    resizePreset = index
                    resizeSize = (requestedWidth, requestedHeight)
                }
            } else {
                for sizeIndex in 0..<standardVideoSizeCount {
                    let standardSize = view.standardVideoSize(sizeIndex)
                    if standardSize.width > preset.width || standardSize.height > preset.height {
                        break
                    }
                    if let requestedWidth, requestedWidth != standardSize.width {
                        continue
                    }
                    if let requestedHeight, requestedHeight != standardSize.height {
                        continue
                    }
                    if replaces(resizePreset, with: preset, request.shouldPreferPowerEfficiency) {
                        resizePreset = index
                        resizeSize = (standardSize.width, standardSize.height)
                    }
                }

                if replaces(resizePreset, with: preset, request.shouldPreferPowerEfficiency) {
                    resizePreset = index
                    if let requestedWidth {
                        resizeSize = (requestedWidth, arm64Divide(arm64Multiply(requestedWidth, preset.height), preset.width))
                    } else if let requestedHeight {
                        resizeSize = (arm64Divide(arm64Multiply(requestedHeight, preset.width), preset.height), requestedHeight)
                    }
                }
            }
        }

        if exactSizePreset == nil && aspectRatioPreset == nil && resizePreset == nil {
            if tryPreservingSize {
                return bestMatch(
                    ConstraintEnginePresetRequest(
                        width: initialRequestedWidth,
                        height: initialRequestedHeight,
                        frameRate: requestedFrameRate,
                        zoom: requestedZoom
                    ),
                    tryPreservingSize: false
                )
            }
            if requestedFrameRate != nil || requestedZoom != nil {
                return bestMatch(
                    ConstraintEnginePresetRequest(width: initialRequestedWidth, height: initialRequestedHeight),
                    tryPreservingSize: false
                )
            }
            return nil
        }

        func isEfficient(_ index: Int?) -> Bool {
            guard let index else {
                return false
            }
            return view.preset(index).isEfficient
        }

        let chosenIndex: Int
        var size: (width: Int32, height: Int32)
        let prefer = request.shouldPreferPowerEfficiency
        if let exactSizePreset,
            !prefer || isEfficient(exactSizePreset) || (!isEfficient(aspectRatioPreset) && !isEfficient(resizePreset))
        {
            chosenIndex = exactSizePreset
            let preset = view.preset(exactSizePreset)
            size = (preset.width, preset.height)
        } else if let aspectRatioPreset, !prefer || isEfficient(aspectRatioPreset) || !isEfficient(resizePreset) {
            chosenIndex = aspectRatioPreset
            size = aspectRatioMatchSize
        } else if let resizePreset {
            chosenIndex = resizePreset
            size = resizeSize
        } else {
            return nil
        }

        let chosen = view.preset(chosenIndex)
        return ConstraintEnginePresetChoice(
            presetIndex: chosenIndex,
            width: size.width,
            height: size.height,
            frameRate: requestedFrameRate ?? frameRate(from: chosen),
            zoom: requestedZoom ?? zoom(from: chosen)
        )
    }
}

// MARK: - Constraint evaluation

private struct ConstraintEngineResult {
    var invalidConstraint: WebCore.MediaConstraintType?
    var candidates = ConstraintEngineSet()
}

private struct ConstraintEngine: ~Escapable {
    let state: WebCore.MediaConstraintsSourceState
    let view: WebCore.MediaConstraintsEngineView
    let capabilities: WebCore.MediaConstraintsCapabilities

    @_lifetime(copy view)
    init(state: WebCore.MediaConstraintsSourceState, view: borrowing WebCore.MediaConstraintsEngineView) {
        self.state = state
        self.view = copy view
        capabilities = state.capabilities
    }

    private var discreteSampleRates: ConstraintEngineDiscreteValues? {
        @_lifetime(copy self)
        get {
            guard state.hasDiscreteSampleRates else {
                return nil
            }
            return ConstraintEngineDiscreteValues(view: view, first: 0, count: Int(state.discreteSampleRateCount))
        }
    }

    private var discreteSampleSizes: ConstraintEngineDiscreteValues? {
        @_lifetime(copy self)
        get {
            guard state.hasDiscreteSampleSizes else {
                return nil
            }
            let first = Int(state.discreteSampleRateCount)
            return ConstraintEngineDiscreteValues(view: view, first: first, count: Int(state.discreteSampleSizeCount))
        }
    }

    private var widthRange: (min: Int32, max: Int32) { (capabilities.width.min, capabilities.width.max) }
    private var heightRange: (min: Int32, max: Int32) { (capabilities.height.min, capabilities.height.max) }
    private var sampleRateRange: (min: Int32, max: Int32) { (capabilities.sampleRate.min, capabilities.sampleRate.max) }
    private var sampleSizeRange: (min: Int32, max: Int32) { (capabilities.sampleSize.min, capabilities.sampleSize.max) }
    private var aspectRatioRange: (min: Double, max: Double) {
        (capabilities.aspectRatio.min, capabilities.aspectRatio.max)
    }
    private var frameRateRange: (min: Double, max: Double) { (capabilities.frameRate.min, capabilities.frameRate.max) }
    private var volumeRange: (min: Double, max: Double) { (capabilities.volume.min, capabilities.volume.max) }
    private var zoomRange: (min: Double, max: Double) { (capabilities.zoom.min, capabilities.zoom.max) }

    // RealtimeMediaSource::supportsSizeFrameRateAndZoom() and RealtimeVideoCaptureSource's.
    private func supportsSizeFrameRateAndZoom(_ request: ConstraintEnginePresetRequest) -> Bool {
        guard state.usesPresets else {
            return true
        }
        if !request.hasConstraints {
            return true
        }
        let presets = ConstraintEnginePresets(
            view: view,
            presetCount: Int(state.presetCount),
            standardVideoSizeCount: Int(state.standardVideoSizeCount),
            canResizeVideoFrames: state.canResizeVideoFrames,
            currentWidth: state.width,
            currentHeight: state.height,
            currentFrameRate: state.frameRate,
            currentZoom: state.zoom
        )
        return presets.bestMatch(request) != nil
    }

    // RealtimeMediaSource::fitnessDistance(MediaConstraintType, const MediaConstraint&).
    private func fitnessDistance(_ type: WebCore.MediaConstraintType, _ constraint: ConstraintEngineConstraint) -> Double {
        switch constraint {
        case .int(let constraint):
            switch type {
            case .Width:
                return capabilities.supportsWidth ? constraint.fitnessDistance(widthRange) : 0
            case .Height:
                return capabilities.supportsHeight ? constraint.fitnessDistance(heightRange) : 0
            case .SampleRate:
                guard capabilities.supportsSampleRate else {
                    return 0
                }
                if let discreteSampleRates {
                    return constraint.fitnessDistance(discreteValues: discreteSampleRates)
                }
                return constraint.fitnessDistance(sampleRateRange)
            case .SampleSize:
                guard capabilities.supportsSampleSize else {
                    return 0
                }
                if let discreteSampleSizes {
                    return constraint.fitnessDistance(discreteValues: discreteSampleSizes)
                }
                return constraint.fitnessDistance(sampleSizeRange)
            default:
                return 0
            }
        case .double(let constraint):
            switch type {
            case .FrameRate:
                return capabilities.supportsFrameRate ? constraint.fitnessDistance(frameRateRange) : 0
            case .AspectRatio:
                return capabilities.supportsAspectRatio ? constraint.fitnessDistance(aspectRatioRange) : 0
            case .Volume:
                return capabilities.supportsVolume ? constraint.fitnessDistance(volumeRange) : 0
            case .Zoom:
                return capabilities.supportsZoom ? constraint.fitnessDistance(zoomRange) : 0
            default:
                return 0
            }
        case .string(let constraint):
            switch type {
            case .FacingMode:
                return capabilities.supportsFacingMode ? constraint.fitnessDistance(anyOf: capabilities.facingModes) : 0
            case .DeviceId:
                return constraint.fitnessDistance(0)
            case .GroupId:
                return capabilities.supportsDeviceId ? constraint.fitnessDistance(0) : 0
            case .WhiteBalanceMode:
                guard capabilities.supportsWhiteBalanceMode else {
                    return 0
                }
                return constraint.fitnessDistance(anyOf: capabilities.whiteBalanceModes)
            default:
                return 0
            }
        case .boolean(let constraint):
            switch type {
            case .EchoCancellation:
                // RealtimeMediaSourceCapabilities::EchoCancellation: Off, On, OnOrOff.
                if !capabilities.supportsEchoCancellation || capabilities.echoCancellation == 2 {
                    return 0
                }
                return constraint.fitnessDistance(capabilities.echoCancellation == 1)
            case .Torch:
                if !capabilities.supportsTorch || constraint.isMandatory {
                    return 0
                }
                return constraint.fitnessDistance(capabilities.torch)
            default:
                return 0
            }
        }
    }

    // RealtimeMediaSource::supportsConstraint().
    private func supportsConstraint(_ type: WebCore.MediaConstraintType) -> Bool {
        switch type {
        case .Width:
            return capabilities.supportsWidth
        case .Height:
            return capabilities.supportsHeight
        case .FrameRate:
            return capabilities.supportsFrameRate
        case .AspectRatio:
            return capabilities.supportsAspectRatio
        case .Volume:
            return capabilities.supportsVolume
        case .SampleRate:
            return capabilities.supportsSampleRate
        case .SampleSize:
            return capabilities.supportsSampleSize
        case .FacingMode:
            return capabilities.supportsFacingMode
        case .EchoCancellation:
            return capabilities.supportsEchoCancellation
        case .DeviceId, .GroupId:
            return capabilities.supportsDeviceId
        case .WhiteBalanceMode:
            return capabilities.supportsWhiteBalanceMode
        case .Zoom:
            return capabilities.supportsZoom
        case .Torch:
            return capabilities.supportsTorch
        case .BackgroundBlur:
            return capabilities.supportsBackgroundBlur
        case .PowerEfficient:
            return state.isCamera
        default:
            // DisplaySurface and LogicalSurface can't be changed by an application
            // (https://www.w3.org/TR/screen-capture/#new-constraints-for-captured-display-surfaces); FocusDistance and
            // Unknown aren't supported.
            return false
        }
    }

    private static func isSizeFrameRateZoomOrPowerEfficient(_ type: WebCore.MediaConstraintType) -> Bool {
        type == .Width || type == .Height || type == .FrameRate || type == .Zoom || type == .PowerEfficient
    }

    // RealtimeMediaSource::hasInvalidSizeFrameRateAndZoomConstraints(). Width, height, frame rate and zoom are checked
    // together, because while they may be supported individually the combination may not be supported.
    private func hasInvalidSizeFrameRateAndZoomConstraints(
        _ widthConstraint: ConstraintEngineNumeric<Int32>?,
        _ heightConstraint: ConstraintEngineNumeric<Int32>?,
        _ frameRateConstraint: ConstraintEngineNumeric<Double>?,
        _ zoomConstraint: ConstraintEngineNumeric<Double>?,
        _ distance: inout Double
    ) -> WebCore.MediaConstraintType? {
        if widthConstraint == nil && heightConstraint == nil && frameRateConstraint == nil && zoomConstraint == nil {
            return nil
        }

        distance = .infinity

        var width: Int32?
        if let widthConstraint, capabilities.supportsWidth {
            let constraintDistance = widthConstraint.fitnessDistance(widthRange)
            if constraintDistance.isInfinite {
                return .Width
            }
            distance = cppMin(distance, constraintDistance)
            if widthConstraint.isMandatory {
                width = widthConstraint.valueForCapabilityRange(state.width, widthRange)
            }
        }

        var height: Int32?
        if let heightConstraint, capabilities.supportsHeight {
            let constraintDistance = heightConstraint.fitnessDistance(heightRange)
            if constraintDistance.isInfinite {
                return .Height
            }
            distance = cppMin(distance, constraintDistance)
            if heightConstraint.isMandatory {
                height = heightConstraint.valueForCapabilityRange(state.height, heightRange)
            }
        }

        var frameRate: Double?
        if let frameRateConstraint, capabilities.supportsFrameRate {
            let constraintDistance = frameRateConstraint.fitnessDistance(frameRateRange)
            if constraintDistance.isInfinite {
                return .FrameRate
            }
            distance = cppMin(distance, constraintDistance)
            if frameRateConstraint.isMandatory {
                frameRate = frameRateConstraint.valueForCapabilityRange(state.frameRate, frameRateRange)
            }
        }

        var zoom: Double?
        if let zoomConstraint, capabilities.supportsZoom {
            let constraintDistance = zoomConstraint.fitnessDistance(zoomRange)
            if constraintDistance.isInfinite {
                return .Zoom
            }
            distance = cppMin(distance, constraintDistance)
            if zoomConstraint.isMandatory {
                zoom = zoomConstraint.valueForCapabilityRange(state.zoom, zoomRange)
            }
        }

        // Each of the non-null values is supported individually, see if they all can be applied at the same time.
        let request = ConstraintEnginePresetRequest(width: width, height: height, frameRate: frameRate, zoom: zoom)
        if !supportsSizeFrameRateAndZoom(request) {
            // Let's try without frame rate and zoom constraints if not mandatory.
            if !(frameRateConstraint?.isMandatory ?? false) && !(zoomConstraint?.isMandatory ?? false)
                && supportsSizeFrameRateAndZoom(ConstraintEnginePresetRequest(width: width, height: height))
            {
                return nil
            }
            if widthConstraint != nil {
                return .Width
            }
            if heightConstraint != nil {
                return .Height
            }
            return .FrameRate
        }
        return nil
    }

    // RealtimeMediaSource::selectSettings(), https://w3c.github.io/mediacapture-main/#dfn-selectsettings
    func selectSettings() -> ConstraintEngineResult {
        var result = ConstraintEngineResult()
        let mandatory = ConstraintEngineSet(state.mandatory)
        var minimumDistance = Double.infinity

        // 3. For every possible settings dictionary of copy compute its fitness distance, treating bare values of
        //    properties as ideal values. Let candidates be the set of settings dictionaries for which the fitness
        //    distance is finite.
        if let invalidConstraint = hasInvalidSizeFrameRateAndZoomConstraints(
            mandatory.width,
            mandatory.height,
            mandatory.frameRate,
            mandatory.zoom,
            &minimumDistance
        ) {
            result.invalidConstraint = invalidConstraint
            return result
        }

        var distance = Double.infinity
        var invalidConstraint: WebCore.MediaConstraintType?
        var candidates = ConstraintEngineSet()
        mandatory.filter { type, constraint in
            if !supportsConstraint(type) {
                return false
            }
            if Self.isSizeFrameRateZoomOrPowerEfficient(type) {
                candidates.set(type, constraint)
                return false
            }
            let constraintDistance = fitnessDistance(type, constraint)
            if constraintDistance.isInfinite {
                invalidConstraint = type
                return true
            }
            distance = cppMin(distance, constraintDistance)
            candidates.set(type, constraint)
            return false
        }
        if let invalidConstraint {
            result.invalidConstraint = invalidConstraint
            return result
        }
        minimumDistance = distance

        // 5. Iterate over the 'advanced' ConstraintSets in newConstraints in the order in which they were specified.
        //    5.1 compute the fitness distance between it and each settings dictionary in candidates, treating bare
        //    values of properties as exact.
        var supportedConstraints: [(distance: Double, index: Int)] = []
        for index in 0..<Int(state.advancedSetCount) {
            let advancedConstraint = ConstraintEngineSet(view.advancedSet(index))
            var constraintDistance = 0.0
            var supported = false

            if advancedConstraint.width != nil || advancedConstraint.height != nil || advancedConstraint.frameRate != nil
                || advancedConstraint.zoom != nil
            {
                if hasInvalidSizeFrameRateAndZoomConstraints(
                    advancedConstraint.width,
                    advancedConstraint.height,
                    advancedConstraint.frameRate,
                    advancedConstraint.zoom,
                    &constraintDistance
                ) != nil {
                    continue
                }
                supported = true
            }

            advancedConstraint.forEachConstraint { type, constraint in
                if Self.isSizeFrameRateZoomOrPowerEfficient(type) {
                    return
                }
                distance = fitnessDistance(type, constraint)
                constraintDistance += distance
                if !distance.isInfinite {
                    supported = true
                }
            }

            minimumDistance = cppMin(minimumDistance, constraintDistance)

            // 5.2 If the fitness distance is finite for one or more settings dictionaries in candidates, keep those
            //     settings dictionaries in candidates, discarding others. If the fitness distance is infinite for all
            //     settings dictionaries in candidates, ignore this ConstraintSet.
            if supported {
                supportedConstraints.append((constraintDistance, index))
            }
        }

        // 6. Select one settings dictionary from candidates, and return it as the result of the SelectSettings()
        //    algorithm. The UA should use the one with the smallest fitness distance, as calculated in step 3.
        let finalMinimumDistance = minimumDistance
        if let chosen = supportedConstraints.first(where: {
            !$0.distance.isInfinite && !($0.distance > finalMinimumDistance)
        }) {
            ConstraintEngineSet(view.advancedSet(chosen.index))
                .forEachConstraint { type, constraint in
                    candidates.merge(type, constraint)
                }
        }

        result.candidates = candidates
        return result
    }

    // RealtimeMediaSource::hasAnyInvalidConstraint()'s fitness score.
    func fitnessScore(_ candidates: ConstraintEngineSet) -> Double {
        var score = 0.0
        candidates.forEachConstraint { type, constraint in
            let distance = fitnessDistance(type, constraint)
            switch type {
            case .DeviceId:
                score += distance != 0 ? 1 : 32
            case .FacingMode:
                score += state.facingModeFitnessScoreAdjustment + (distance != 0 ? 1 : 32)
            default:
                score += distance != 0 ? 1 : 2
            }
        }
        return score
    }

    // RealtimeMediaSource::extractVideoPresetConstraints(const MediaTrackConstraintSetMap&).
    func videoPresetConstraints(_ candidates: ConstraintEngineSet) -> ConstraintEnginePresetRequest {
        var result = ConstraintEnginePresetRequest()

        if let constraint = candidates.width, capabilities.supportsWidth {
            result.width = constraint.valueForCapabilityRange(state.width, widthRange)
        }
        if let constraint = candidates.height, capabilities.supportsHeight {
            result.height = constraint.valueForCapabilityRange(state.height, heightRange)
        }
        if let constraint = candidates.aspectRatio, capabilities.supportsAspectRatio {
            let currentAspectRatio = state.width != 0 ? Double(state.width) / Double(state.height) : 0
            let aspectRatio = constraint.valueForCapabilityRange(currentAspectRatio, aspectRatioRange)
            if aspectRatio != 0 {
                if result.width == nil, let height = result.height {
                    result.width = Int32(arm64Truncating: Double(height) * aspectRatio)
                }
                if let width = result.width, result.height == nil {
                    result.height = Int32(arm64Truncating: Double(width) / aspectRatio)
                }
            }
        }
        if let constraint = candidates.frameRate, capabilities.supportsFrameRate {
            result.frameRate = constraint.valueForCapabilityRange(state.frameRate, frameRateRange)
        }
        if let constraint = candidates.zoom, capabilities.supportsZoom {
            result.zoom = constraint.valueForCapabilityRange(state.zoom, zoomRange)
        }
        if let constraint = candidates.powerEfficient, let setting = constraint.exact ?? constraint.ideal {
            result.shouldPreferPowerEfficiency = setting
        }
        return result
    }

    // RealtimeMediaSource::applyNumericConstraint(): the new value, if it differs from the current one.
    private static func numericSetting<Value: ConstraintEngineValue>(
        _ constraint: ConstraintEngineNumeric<Value>,
        _ current: Value,
        _ range: (min: Value, max: Value)
    ) -> Value? {
        let value = constraint.valueForCapabilityRange(current, range)
        return value != current ? value : nil
    }

    // applyNumericConstraint() for the sample rate, whose capability may be a list of discrete rates.
    private func sampleRateSetting(_ constraint: ConstraintEngineNumeric<Int32>) -> Int32? {
        guard let discreteSampleRates else {
            return Self.numericSetting(constraint, state.sampleRate, sampleRateRange)
        }
        guard let value = constraint.valueForDiscreteCapabilityValues(state.sampleRate, discreteSampleRates),
            value != state.sampleRate
        else {
            return nil
        }
        return value
    }

    // RealtimeMediaSource::applyConstraints(const MediaTrackConstraintSetMap&) and applyConstraint(): the settings to
    // change, from the source's current values.
    func settingsToApply(_ candidates: ConstraintEngineSet, _ evaluation: inout WebCore.MediaConstraintsEvaluation) {
        candidates.forEachConstraint { type, constraint in
            switch (type, constraint) {
            case (.SampleRate, .int(let constraint)):
                guard capabilities.supportsSampleRate,
                    let value = sampleRateSetting(constraint)
                else {
                    return
                }
                evaluation.setsSampleRate = true
                evaluation.sampleRate = value
            case (.SampleSize, .int(let constraint)):
                guard capabilities.supportsSampleSize,
                    let value = Self.numericSetting(constraint, state.sampleSize, sampleSizeRange)
                else {
                    return
                }
                evaluation.setsSampleSize = true
                evaluation.sampleSize = value
            case (.Volume, .double(let constraint)):
                guard capabilities.supportsVolume,
                    let value = Self.numericSetting(constraint, state.volume, volumeRange)
                else {
                    return
                }
                evaluation.setsVolume = true
                evaluation.volume = value
            case (.EchoCancellation, .boolean(let constraint)):
                guard capabilities.supportsEchoCancellation else {
                    return
                }
                evaluation.setsEchoCancellation = true
                switch capabilities.echoCancellation {
                case 0:
                    evaluation.echoCancellation = false
                case 1:
                    evaluation.echoCancellation = true
                default:
                    evaluation.echoCancellation = constraint.setting
                }
            case (.FacingMode, .string(let constraint)):
                guard capabilities.supportsFacingMode else {
                    return
                }
                let supportedModes = capabilities.facingModes
                // An empty string selects no mode, but stops the search if the source supports the unknown mode.
                let mode = constraint.firstMode {
                    let parsedMode = $0 == WebCore.mediaConstraintsEmptyFacingMode ? 0 : $0
                    return supportedModes & (1 << parsedMode) != 0
                }
                if let mode, mode != WebCore.mediaConstraintsEmptyFacingMode {
                    evaluation.setsFacingMode = true
                    evaluation.facingMode = mode
                }
            case (.WhiteBalanceMode, .string(let constraint)):
                guard capabilities.supportsWhiteBalanceMode else {
                    return
                }
                let supportedModes = capabilities.whiteBalanceModes
                if let mode = constraint.firstMode(in: { supportedModes & (1 << $0) != 0 }) {
                    evaluation.setsWhiteBalanceMode = true
                    evaluation.whiteBalanceMode = mode
                }
            case (.Torch, .boolean(let constraint)):
                guard capabilities.supportsTorch, let setting = constraint.exact ?? constraint.ideal else {
                    return
                }
                evaluation.setsTorch = true
                evaluation.torch = setting
            default:
                // Width, height, aspect ratio, frame rate and zoom go through the video preset constraints; device and
                // group IDs and display surfaces can't change; background blur and power efficiency aren't applied
                // (https://bugs.webkit.org/show_bug.cgi?id=275491).
                break
            }
        }
    }
}

private func mediaVideoPresetConstraints(_ request: ConstraintEnginePresetRequest) -> WebCore.MediaVideoPresetConstraints {
    var constraints = WebCore.MediaVideoPresetConstraints()
    if let width = request.width {
        constraints.hasWidth = true
        constraints.width = width
    }
    if let height = request.height {
        constraints.hasHeight = true
        constraints.height = height
    }
    if let frameRate = request.frameRate {
        constraints.hasFrameRate = true
        constraints.frameRate = frameRate
    }
    if let zoom = request.zoom {
        constraints.hasZoom = true
        constraints.zoom = zoom
    }
    constraints.shouldPreferPowerEfficiency = request.shouldPreferPowerEfficiency
    return constraints
}

private func presetRequest(_ constraints: WebCore.MediaVideoPresetConstraints) -> ConstraintEnginePresetRequest {
    ConstraintEnginePresetRequest(
        width: constraints.hasWidth ? constraints.width : nil,
        height: constraints.hasHeight ? constraints.height : nil,
        frameRate: constraints.hasFrameRate ? constraints.frameRate : nil,
        zoom: constraints.hasZoom ? constraints.zoom : nil,
        shouldPreferPowerEfficiency: constraints.shouldPreferPowerEfficiency
    )
}

// SelectSettings for the source `state` describes, and if it succeeds, what `state.purpose` asks for.
@_expose(Cxx)
func mediaConstraintsEvaluate(
    _ view: borrowing WebCore.MediaConstraintsEngineView,
    _ state: WebCore.MediaConstraintsSourceState
) -> WebCore.MediaConstraintsEvaluation {
    let engine = ConstraintEngine(state: state, view: view)
    var evaluation = WebCore.MediaConstraintsEvaluation()
    let result = engine.selectSettings()
    if let invalidConstraint = result.invalidConstraint {
        evaluation.hasInvalidConstraint = true
        evaluation.invalidConstraint = invalidConstraint
        return evaluation
    }
    let candidates = result.candidates
    switch state.purpose {
    case .FitnessScore:
        evaluation.fitnessScore = engine.fitnessScore(candidates)
    case .VideoPresetConstraints:
        evaluation.videoPresetConstraints = mediaVideoPresetConstraints(engine.videoPresetConstraints(candidates))
    default:
        evaluation.videoPresetConstraints = mediaVideoPresetConstraints(engine.videoPresetConstraints(candidates))
        evaluation.hasConstraintsToApply = !candidates.isEmpty
        engine.settingsToApply(candidates, &evaluation)
    }
    return evaluation
}

// RealtimeVideoCaptureSource::bestSupportedSizeFrameRateAndZoomConsideringObservers(). With several observers
// with adaptors, it only changes the capture size or frame rate if it is below the requested one.
@_expose(Cxx)
func mediaConstraintsBestVideoPreset(
    _ view: borrowing WebCore.MediaConstraintsEngineView,
    _ search: WebCore.MediaVideoPresetSearch
) -> WebCore.MediaVideoPresetMatch {
    var request = presetRequest(search.constraints)
    if search.hasSeveralVideoFrameObserversWithAdaptors {
        if let width = request.width, width <= search.settingsWidth {
            request.width = nil
        }
        if let height = request.height, height <= search.settingsHeight {
            request.height = nil
        }
        if let frameRate = request.frameRate, frameRate <= search.settingsFrameRate {
            request.frameRate = nil
        }
    }
    var match = WebCore.MediaVideoPresetMatch()
    guard request.hasConstraints else {
        return match
    }
    let presets = ConstraintEnginePresets(
        view: view,
        presetCount: Int(search.presetCount),
        standardVideoSizeCount: Int(search.standardVideoSizeCount),
        canResizeVideoFrames: search.canResizeVideoFrames,
        currentWidth: search.width,
        currentHeight: search.height,
        currentFrameRate: search.frameRate,
        currentZoom: search.zoom
    )
    guard let choice = presets.bestMatch(request) else {
        return match
    }
    match.found = true
    match.presetIndex = UInt32(choice.presetIndex)
    match.width = choice.width
    match.height = choice.height
    match.frameRate = choice.frameRate
    match.zoom = choice.zoom
    return match
}

#endif // ENABLE_WEBCORE_SWIFT && ENABLE_MEDIA_STREAM
