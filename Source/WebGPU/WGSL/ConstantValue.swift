// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

// A constant value might be:
// - a scalar
// - a vector
// - a matrix
// - a fixed-size array type
// - a structure

@_spi(Testing)
public struct ConstantArray: Equatable {
    private var storage: ConstantElements

    @_spi(Testing)
    public var elements: [ConstantValue] {
        get { storage.elements }
        _modify {
            if !isKnownUniquelyReferenced(&storage) {
                storage = ConstantElements(storage.elements)
            }
            yield &storage.elements
        }
    }

    @_spi(Testing)
    public init(size: Int) {
        storage = ConstantElements(defaultConstantValues(size))
    }

    @_spi(Testing)
    public init(_ elements: [ConstantValue]) {
        storage = ConstantElements(elements)
    }

    @_spi(Testing)
    public func upperBound() -> Int { elements.count }

    @_spi(Testing)
    public subscript(index: UInt32) -> ConstantValue {
        elements[Int(index)]
    }
}

@_spi(Testing)
public struct ConstantVector: Equatable {
    @_spi(Testing)
    public var elements: [ConstantValue]

    @_spi(Testing)
    public init(size: Int) {
        elements = defaultConstantValues(size)
    }

    @_spi(Testing)
    public init(_ elements: [ConstantValue]) {
        self.elements = elements
    }

    @_spi(Testing)
    public func upperBound() -> Int { elements.count }

    @_spi(Testing)
    public subscript(index: UInt32) -> ConstantValue {
        elements[Int(index)]
    }
}

/// Column-major: column `c` is `elements[c * rows ..< (c + 1) * rows]`.
@_spi(Testing)
public struct ConstantMatrix: Equatable {
    @_spi(Testing)
    public let columns: UInt32
    @_spi(Testing)
    public let rows: UInt32
    @_spi(Testing)
    public var elements: [ConstantValue]

    @_spi(Testing)
    public init(columns: UInt32, rows: UInt32) {
        self.columns = columns
        self.rows = rows
        elements = defaultConstantValues(Int(columns &* rows))
    }

    @_spi(Testing)
    public init(columns: UInt32, rows: UInt32, _ elements: [ConstantValue]) {
        self.columns = columns
        self.rows = rows
        self.elements = elements
        guard elements.count == Int(columns &* rows) else {
            wgslFatal("matrix element count is not columns * rows", cppSite: "ConstantValue.h:136")
        }
    }

    @_spi(Testing)
    public func upperBound() -> Int { Int(columns) }

    @_spi(Testing)
    public subscript(index: UInt32) -> ConstantVector {
        var result = ConstantVector(size: Int(rows))
        var i: UInt32 = 0
        while i < rows {
            result.elements[Int(i)] = elements[Int(index &* rows &+ i)]
            i += 1
        }
        return result
    }
}

/// C++ `HashMap<String, ConstantValue> fields`: (key, value) pairs in insertion order, with `HashMap::get`/`set` semantics.
///
/// The order is observable only in dumps and in the Metal writer. Primitive-struct results are built in the C++ hash order
/// (`frexpResult`, `modfResult`); user structs keep the order in which their fields are set, the member order (DEV-02).
@_spi(Testing)
public struct ConstantStruct: Equatable {
    private var storage = ConstantFields()

    @_spi(Testing)
    public fileprivate(set) var fields: [(key: Symbol, value: ConstantValue)] {
        get { storage.fields }
        _modify {
            if !isKnownUniquelyReferenced(&storage) {
                storage = ConstantFields(storage.fields)
            }
            yield &storage.fields
        }
    }

    @_spi(Testing)
    public init() {}

    /// `HashMap::get`: the value, or `ConstantValue()` (`.defaultValue`) for a missing key.
    @_spi(Testing)
    public func get(_ key: Symbol) -> ConstantValue {
        var index = 0
        while index < fields.count {
            if fields[index].key == key {
                return fields[index].value
            }
            index += 1
        }
        return .defaultValue
    }

    /// `HashMap::set`: replaces the value of an existing key in place, otherwise appends.
    @_spi(Testing)
    public mutating func set(_ key: Symbol, _ value: ConstantValue) {
        var index = 0
        while index < fields.count {
            if fields[index].key == key {
                fields[index].value = value
                return
            }
            index += 1
        }
        fields.append((key: key, value: value))
    }
}

/// C++ `ConstantValue`.
///
/// The cases are the alternatives of `Variant<float, half, double, int32_t, uint32_t, int64_t, bool, ConstantArray,
/// ConstantVector, ConstantMatrix, ConstantStruct>`, same order. Not `CustomStringConvertible`: messages use
/// `dump(into:_:)`. Equality is structural and bit-exact (C++ has no `operator==`): `.float(-0.0) != .float(0.0)`,
/// and a NaN equals the same NaN.
@_spi(Testing)
public enum ConstantValue: Equatable {
    case float(Float)
    case half(Half)
    case double(Double)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case bool(Bool)
    case array(ConstantArray)
    case vector(ConstantVector)
    case matrix(ConstantMatrix)
    case `struct`(ConstantStruct)

    /// C++ `ConstantValue()`, the first alternative default-constructed. `HashMap<…, ConstantValue>::get` of a missing
    /// key and `FixedVector<ConstantValue>(n)` produce it.
    @_spi(Testing)
    public static var defaultValue: ConstantValue { .float(0) }

    @_spi(Testing)
    public var isBool: Bool {
        if case .bool = self { true } else { false }
    }

    @_spi(Testing)
    public var isVector: Bool {
        if case .vector = self { true } else { false }
    }

    @_spi(Testing)
    public var isMatrix: Bool {
        if case .matrix = self { true } else { false }
    }

    @_spi(Testing)
    public var isArray: Bool {
        if case .array = self { true } else { false }
    }

    @_spi(Testing)
    public func toBool() -> Bool {
        guard case .bool(let value) = self else {
            wgslFatal("std::get<bool> of a constant that is not a bool", cppSite: "ConstantValue.h:164")
        }
        return value
    }

    @_spi(Testing)
    public func integerValue() -> Int64 {
        switch self {
        case .int32(let i32): Int64(i32)
        case .uint32(let u32): Int64(u32)
        case .int64(let abstractInt): abstractInt
        case .float, .half, .double, .bool, .array, .vector, .matrix, .struct:
            wgslFatal("integerValue() of a constant that is not an integer", cppSite: "ConstantValue.h:174")
        }
    }

    @_spi(Testing)
    public func getHalf() -> Half {
        switch self {
        case .float(let f32): Half(f32)
        case .double(let f64): Half(f64)
        case .half, .int32, .uint32, .int64, .bool, .array, .vector, .matrix, .struct:
            wgslFatal("getHalf() of a constant that is not a float or an AbstractFloat", cppSite: "ConstantValue.h:182")
        }
    }

    @_spi(Testing)
    public func toVector() -> ConstantVector {
        guard case .vector(let vector) = self else {
            wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantValue.h:187")
        }
        return vector
    }

    @_spi(Testing)
    public func upperBound() -> Int {
        switch self {
        case .array(let array): array.upperBound()
        case .vector(let vector): vector.upperBound()
        case .matrix(let matrix): matrix.upperBound()
        case .float, .half, .double, .int32, .uint32, .int64, .bool, .struct:
            wgslFatal("upperBound() of a constant that is not an array, a vector or a matrix", cppSite: "ConstantValue.h:198")
        }
    }

    @_spi(Testing)
    public subscript(index: UInt32) -> ConstantValue {
        switch self {
        case .array(let array): array[index]
        case .vector(let vector): vector[index]
        case .matrix(let matrix): .vector(matrix[index])
        case .float, .half, .double, .int32, .uint32, .int64, .bool, .struct:
            wgslFatal("subscript of a constant that is not an array, a vector or a matrix", cppSite: "ConstantValue.h:209")
        }
    }
}

// MARK: - Storage

/// The elements of a `ConstantArray`, shared by its copies until one is modified.
final class ConstantElements {
    var elements: [ConstantValue]

    init(_ elements: [ConstantValue]) {
        self.elements = elements
    }

    deinit {
        // DEV-03: the arrays and structs nested in the elements are freed by a loop, where freeing them recursively takes
        // native frames per level (type nesting has no depth limit: alias chains bypass the composite limit of 15).
        var pending: [ConstantValue] = []
        appendNested(elements, &pending)
        elements = []
        freeNested(&pending)
    }
}

/// The fields of a `ConstantStruct`, shared by its copies until one is modified, and freed like `ConstantElements`.
final class ConstantFields {
    var fields: [(key: Symbol, value: ConstantValue)]

    init(_ fields: [(key: Symbol, value: ConstantValue)] = []) {
        self.fields = fields
    }

    deinit {
        var pending: [ConstantValue] = []
        appendNested(fields, &pending)
        fields = []
        freeNested(&pending)
    }
}

/// Frees `pending`, and the storage nested in it that nothing else holds, one value at a time.
private func freeNested(_ pending: inout [ConstantValue]) {
    while let value = pending.popLast() {
        detachNested(value, &pending)
    }
}

/// Empties the storage of `value`, an array or a struct, into `pending` when `value` holds the only reference to it.
private func detachNested(_ value: consuming ConstantValue, _ pending: inout [ConstantValue]) {
    switch consume value {
    case .array(var array):
        array.detachStorage(&pending)
    case .struct(var constantStruct):
        constantStruct.detachStorage(&pending)
    case .float, .half, .double, .int32, .uint32, .int64, .bool, .vector, .matrix:
        break
    }
}

private func appendNested(_ elements: [ConstantValue], _ pending: inout [ConstantValue]) {
    var index = 0
    while index < elements.count {
        if elements[index].holdsStorage {
            pending.append(elements[index])
        }
        index &+= 1
    }
}

private func appendNested(_ fields: [(key: Symbol, value: ConstantValue)], _ pending: inout [ConstantValue]) {
    var index = 0
    while index < fields.count {
        if fields[index].value.holdsStorage {
            pending.append(fields[index].value)
        }
        index &+= 1
    }
}

extension ConstantArray {
    fileprivate mutating func detachStorage(_ pending: inout [ConstantValue]) {
        guard isKnownUniquelyReferenced(&storage) else {
            return
        }
        appendNested(storage.elements, &pending)
        storage.elements = []
    }
}

extension ConstantStruct {
    fileprivate mutating func detachStorage(_ pending: inout [ConstantValue]) {
        guard isKnownUniquelyReferenced(&storage) else {
            return
        }
        appendNested(storage.fields, &pending)
        storage.fields = []
    }
}

extension ConstantValue {
    /// Whether the value is an array or a struct, whose storage can hold more of them.
    fileprivate var holdsStorage: Bool {
        switch self {
        case .array, .struct: true
        case .float, .half, .double, .int32, .uint32, .int64, .bool, .vector, .matrix: false
        }
    }
}

// MARK: - convertInteger, convertFloat

/// `convertInteger<int32_t>(int64_t)`.
@_spi(Testing)
public func convertInteger(_: Int32.Type, _ value: Int64) -> Int32? {
    Int32(exactly: value)
}

/// `convertInteger<uint32_t>(int64_t)`.
@_spi(Testing)
public func convertInteger(_: UInt32.Type, _ value: Int64) -> UInt32? {
    UInt32(exactly: value)
}

private let halfMax: Float = 0x1.ffcp15

// The range check is in the source type, before narrowing, and rejects NaN (so also the infinities).

/// `convertFloat<float>(float)`.
@_spi(Testing)
public func convertFloat(_: Float.Type, _ value: Float) -> Float? {
    let max = Float.greatestFiniteMagnitude
    let lowest = -max
    if value > max {
        return nil
    }
    if value < lowest {
        return nil
    }
    if value.isNaN {
        return nil
    }
    return value
}

/// `convertFloat<float>(double)`.
@_spi(Testing)
public func convertFloat(_: Float.Type, _ value: Double) -> Float? {
    let max = Double(Float.greatestFiniteMagnitude)
    let lowest = -max
    if value > max {
        return nil
    }
    if value < lowest {
        return nil
    }
    if value.isNaN {
        return nil
    }
    return Float(value)
}

/// `convertFloat<half>(half)`: compared as `float`, as `__fp16` promotes.
@_spi(Testing)
public func convertFloat(_: Half.Type, _ value: Half) -> Half? {
    let max = halfMax
    let lowest = -max
    if Float(value) > max {
        return nil
    }
    if Float(value) < lowest {
        return nil
    }
    if Float(value).isNaN {
        return nil
    }
    return value
}

/// `convertFloat<half>(float)`.
@_spi(Testing)
public func convertFloat(_: Half.Type, _ value: Float) -> Half? {
    let max = halfMax
    let lowest = -max
    if value > max {
        return nil
    }
    if value < lowest {
        return nil
    }
    if value.isNaN {
        return nil
    }
    return Half(value)
}

/// `convertFloat<half>(double)`: the double is narrowed directly, with one rounding.
@_spi(Testing)
public func convertFloat(_: Half.Type, _ value: Double) -> Half? {
    let max = Double(halfMax)
    let lowest = -max
    if value > max {
        return nil
    }
    if value < lowest {
        return nil
    }
    if value.isNaN {
        return nil
    }
    return Half(value)
}

/// `convertFloat<double>(double)`.
@_spi(Testing)
public func convertFloat(_: Double.Type, _ value: Double) -> Double? {
    let max = Double.greatestFiniteMagnitude
    let lowest = -max
    if value > max {
        return nil
    }
    if value < lowest {
        return nil
    }
    if value.isNaN {
        return nil
    }
    return value
}

// MARK: - dump

extension ConstantValue {
    /// `ConstantValue::dump` into a message.
    ///
    /// Struct keys are printed with `symbols`.
    @_spi(Testing)
    public func dump(into out: inout MessageText, _ symbols: borrowing SymbolTable) {
        // DEV-03: an explicit stack of what is left to print, where the C++ recurses into the elements and fields (type
        // nesting has no depth limit).
        var pending: [ConstantDumpStep] = []
        var step = ConstantDumpStep.value(self)
        while true {
            switch step {
            case .value(let value):
                value.dumpStep(into: &out, &pending)
            case .elements(let elements, let next):
                if next < elements.count {
                    if next > 0 {
                        out.append(", ")
                    }
                    pending.append(.elements(elements, next: next &+ 1))
                    pending.append(.value(elements[next]))
                } else {
                    out.append(")")
                }
            case .fields(let fields, let next):
                if next < fields.count {
                    if next > 0 {
                        out.append(", ")
                    }
                    out.append(symbols.text(of: fields[next].key))
                    out.append(": ")
                    pending.append(.fields(fields, next: next &+ 1))
                    pending.append(.value(fields[next].value))
                } else {
                    out.append(" }")
                }
            }
            guard let next = pending.popLast() else {
                return
            }
            step = next
        }
    }

    /// Prints a scalar, or the start of an array, a vector, a matrix or a struct, whose elements or fields `dump` prints next.
    private func dumpStep(into out: inout MessageText, _ pending: inout [ConstantDumpStep]) {
        switch self {
        case .double(let d):
            out.append("\(number: d)")
        case .float(let f):
            out.append("\(number: f)")
            if f.isFinite {
                out.append("f")
            }
        case .half(let h):
            out.append("\(number: h)")
            if Double(h).isFinite {
                out.append("h")
            }
        case .int64(let i):
            out.append("\(i)")
        case .int32(let i):
            out.append("\(i)i")
        case .uint32(let u):
            out.append("\(u)u")
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .array(let a):
            out.append("array(")
            pending.append(.elements(a.elements, next: 0))
        case .vector(let v):
            out.append("vec\(v.elements.count)(")
            pending.append(.elements(v.elements, next: 0))
        case .matrix(let m):
            out.append("mat\(m.columns)x\(m.rows)(")
            pending.append(.elements(m.elements, next: 0))
        case .struct(let s):
            out.append("struct { ")
            // DEV-02: the fields' insertion order (member order for user structs), not the C++ HashMap's.
            pending.append(.fields(s.fields, next: 0))
        }
    }
}

/// What `ConstantValue.dump` has left to print: a value, or the elements or fields of one from `next` on, then its closing
/// text.
private enum ConstantDumpStep {
    case value(ConstantValue)
    case elements([ConstantValue], next: Int)
    case fields([(key: Symbol, value: ConstantValue)], next: Int)
}

// MARK: - convertValueImpl

/// Converts `value` in place to `type`, element by element in order; on failure the elements already converted stay
/// converted (the message then dumps the partially converted value).
///
/// A composite element is written to only when the conversion changes it or fails on it (`isConverted`), so that elements
/// shared with other values (all the elements of a zero value, the constant an identifier reads) stay shared: a write to
/// one copies it, and level by level the whole value. Scalars are converted in place from the first one that changes.
/// Storage that several elements share is read and converted once (`ConversionState`).
@_spi(Testing)
public func convertValueImpl(_ span: SourceSpan, _ type: TypeID, _ value: inout ConstantValue, _ types: borrowing TypeStore) -> Bool {
    var state = ConversionState(memoizedReads: ConversionState.memoizedReads)
    return convertValueImpl(span, type, &value, types, &state)
}

/// `convertValueImpl`, remembering each array and struct whose scan or conversion reads at least `memoizedReads` elements
/// and fields besides those of the values it remembers already (`min(memoizedReads, 16)` where it meets shared storage);
/// `reads` is set to the number of elements and fields it read.
@_spi(Testing)
public func convertValueImpl(
    _ span: SourceSpan,
    _ type: TypeID,
    _ value: inout ConstantValue,
    _ types: borrowing TypeStore,
    memoizedReads: Int,
    reads: inout Int
) -> Bool {
    var state = ConversionState(memoizedReads: memoizedReads)
    defer { reads = state.reads }
    return convertValueImpl(span, type, &value, types, &state)
}

/// `state.path` holds the indices at which the caller's scan stopped below `value`, the last one in `value`, or nothing.
private func convertValueImpl(
    _ span: SourceSpan,
    _ type: TypeID,
    _ value: inout ConstantValue,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Bool {
    switch types[type] {
    case .primitive(let primitive):
        switch primitive.kind {
        case .f32:
            var result: Float?
            if case .float(let f32) = value {
                result = convertFloat(Float.self, f32)
            } else if case .double(let abstractFloat) = value {
                result = convertFloat(Float.self, abstractFloat)
            } else if case .int64(let abstractInt) = value {
                result = convertFloat(Float.self, Double(abstractInt))
            }

            guard let result else {
                return false
            }
            value = .float(result)
            return true
        case .f16:
            var result: Half?
            if case .half(let f16) = value {
                result = convertFloat(Half.self, f16)
            } else if case .double(let abstractFloat) = value {
                result = convertFloat(Half.self, abstractFloat)
            } else if case .int64(let abstractInt) = value {
                result = convertFloat(Half.self, Double(abstractInt))
            }

            guard let result else {
                return false
            }
            value = .half(result)
            return true
        case .i32:
            if case .int32 = value {
                return true
            }
            var result: Int32?
            if case .int64(let abstractInt) = value {
                result = convertInteger(Int32.self, abstractInt)
            }

            guard let result else {
                return false
            }
            value = .int32(result)
            return true
        case .u32:
            if case .uint32 = value {
                return true
            }
            var result: UInt32?
            if case .int64(let abstractInt) = value {
                result = convertInteger(UInt32.self, abstractInt)
            }

            guard let result else {
                return false
            }
            value = .uint32(result)
            return true
        case .abstractInt:
            guard case .int64 = value else {
                wgslFatal("an AbstractInt constant that is not an int64_t", cppSite: "ConstantValue.cpp:185")
            }
            return true
        case .abstractFloat:
            let result: Double?
            if case .double(let abstractFloat) = value {
                result = convertFloat(Double.self, abstractFloat)
            } else if case .int64(let abstractInt) = value {
                result = convertFloat(Double.self, Double(abstractInt))
            } else {
                wgslFatal("an AbstractFloat constant that is not a double or an int64_t", cppSite: "ConstantValue.cpp:194")
            }
            guard let result else {
                return false
            }
            value = .double(result)
            return true
        case .bool:
            guard case .bool = value else {
                wgslFatal("a bool constant that is not a bool", cppSite: "ConstantValue.cpp:201")
            }
            return true
        case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
            return false
        }
    case .vector(let vectorType):
        guard case .vector(var vector) = value else {
            wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "ConstantValue.cpp:215")
        }
        var index = state.path.popLast() ?? firstElementToConvert(vector.elements, from: 0, vectorType.element, types, &state)
        guard index < vector.elements.count else {
            return true
        }
        // Drops value's reference so that the elements are converted in place rather than copied; written back on every exit.
        value = .defaultValue
        defer { value = .vector(vector) }
        // Scalars hold no storage that other values share, so the rest are converted in place as they are.
        while index < vector.elements.count {
            state.reads &+= 1
            if !convertValueImpl(span, vectorType.element, &vector.elements[index], types, &state) {
                return false
            }
            index += 1
        }
        return true
    case .matrix(let matrixType):
        guard case .matrix(var matrix) = value else {
            wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "ConstantValue.cpp:224")
        }
        var index = state.path.popLast() ?? firstElementToConvert(matrix.elements, from: 0, matrixType.element, types, &state)
        guard index < matrix.elements.count else {
            return true
        }
        value = .defaultValue
        defer { value = .matrix(matrix) }
        while index < matrix.elements.count {
            state.reads &+= 1
            if !convertValueImpl(span, matrixType.element, &matrix.elements[index], types, &state) {
                return false
            }
            index += 1
        }
        return true
    case .array, .struct:
        return convertNested(span, type, &value, types, &state)
    case .primitiveStruct(let primitiveStruct):
        guard case .struct(var constantStruct) = value else {
            wgslFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "ConstantValue.cpp:251")
        }
        var index = state.path.popLast() ?? firstFieldToConvert(constantStruct.fields, from: 0, primitiveStruct, types, &state)
        guard index < constantStruct.fields.count else {
            return true
        }
        value = .defaultValue
        defer { value = .struct(constantStruct) }
        let keys = Types.PrimitiveStruct.keys(primitiveStruct.kind)
        while index < constantStruct.fields.count {
            state.reads &+= 1
            guard let key = keys.tryGet(constantStruct.fields[index].key) else {
                wgslFatal("a primitive struct constant field that its type does not have", cppSite: "ConstantValue.cpp:255")
            }
            let type = types[primitiveStruct.values, key]
            if !convertValueImpl(span, type, &constantStruct.fields[index].value, types, &state) {
                return false
            }
            index = firstFieldToConvert(constantStruct.fields, from: index + 1, primitiveStruct, types, &state)
        }
        return true
    case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic, .typeConstructor:
        wgslFatal("convertValueImpl to a type that has no constant values", cppSite: "ConstantValue.cpp:263")
    }
}

/// `convertValueImpl` of `value` to an array or a struct type.
private func convertNested(
    _ span: SourceSpan,
    _ type: TypeID,
    _ value: inout ConstantValue,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Bool {
    // DEV-03: the arrays and structs nested in `value` are converted one level after another (`ConversionLevel`), where the
    // C++ recurses: type nesting has no depth limit.
    guard var level = beginConversionLevel(type, value, types, &state) else {
        return true
    }
    // Drops value's reference so that the elements are converted in place rather than copied; written back on every exit.
    value = .defaultValue
    var outer: [ConversionLevel] = []
    while true {
        if level.isConverted, let nested = convertChildren(span, &level, types, &state) {
            outer.append(level)
            level = nested
            continue
        }
        guard var parent = outer.popLast() else {
            value = level.value
            return level.isConverted
        }
        parent.setChild(level.value)
        if level.isConverted, let childType = parent.childType {
            parent.childType = nil
            endConversion(childType, parent.child, types, &state)
            parent.next(types, &state)
        } else {
            parent.isConverted = false
        }
        level = parent
    }
}

/// A level of a conversion: an array or a struct moved out of its place (the value converted, or an element or a field of
/// the level above), converted from element or field `index` on.
private struct ConversionLevel {
    var value: ConstantValue
    let kind: ConversionLevelKind
    var index: Int
    /// The end of the run of elements equal to element `index`.
    var runEnd = 0
    /// The type of element or field `index` while the level below converts it.
    var childType: TypeID?
    /// False once the conversion of an element or a field failed.
    var isConverted = true

    var count: Int {
        switch kind {
        case .elements: array.elements.count
        case .fields: constantStruct.fields.count
        }
    }

    /// Element or field `index`.
    var child: ConstantValue {
        switch kind {
        case .elements: array.elements[index]
        case .fields: constantStruct.fields[index].value
        }
    }

    var array: ConstantArray {
        guard case .array(let array) = value else {
            wgslFatal("std::get<ConstantArray> of a constant that is not an array", cppSite: "ConstantValue.cpp:233")
        }
        return array
    }

    var constantStruct: ConstantStruct {
        guard case .struct(let constantStruct) = value else {
            wgslFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "ConstantValue.cpp:241")
        }
        return constantStruct
    }

    /// Replaces element or field `index`, in place.
    mutating func setChild(_ child: ConstantValue) {
        switch kind {
        case .elements:
            var array = self.array
            value = .defaultValue
            array.elements[index] = child
            value = .array(array)
        case .fields:
            var constantStruct = self.constantStruct
            value = .defaultValue
            constantStruct.fields[index].value = child
            value = .struct(constantStruct)
        }
    }

    /// Moves on from element or field `index`, converted: the run of elements equal to it before its conversion take its
    /// converted value, then the next element or field to convert is found.
    mutating func next(_ types: borrowing TypeStore, _ state: inout ConversionState) {
        switch kind {
        case .elements(let element):
            var array = self.array
            value = .defaultValue
            shareConverted(&array.elements, index, runEnd)
            index = firstElementToConvert(array.elements, from: runEnd, element, types, &state)
            value = .array(array)
        case .fields(let fields):
            index = firstFieldToConvert(constantStruct.fields, from: index + 1, fields, types, &state)
        }
    }

    /// Converts the elements from `index` on, in place, when they hold no arrays or structs.
    mutating func convertElements(_ span: SourceSpan, _ element: TypeID, _ types: borrowing TypeStore, _ state: inout ConversionState) {
        var array = self.array
        value = .defaultValue
        defer { value = .array(array) }
        while index < array.elements.count {
            let runEnd = endOfEqualRun(array.elements, index, &state)
            if !convertElement(span, element, &array.elements[index], types, &state) {
                isConverted = false
                return
            }
            shareConverted(&array.elements, index, runEnd)
            index = firstElementToConvert(array.elements, from: runEnd, element, types, &state)
        }
    }

    /// Converts the scalar elements from `index` on, in place.
    mutating func convertScalars(_ span: SourceSpan, _ element: TypeID, _ types: borrowing TypeStore, _ state: inout ConversionState) {
        var array = self.array
        value = .defaultValue
        defer { value = .array(array) }
        while index < array.elements.count {
            state.reads &+= 1
            if !convertValueImpl(span, element, &array.elements[index], types, &state) {
                isConverted = false
                return
            }
            index += 1
        }
    }
}

private enum ConversionLevelKind {
    /// An array of elements of this type.
    case elements(TypeID)
    /// A struct of these fields.
    case fields(SymbolMap<TypeID>)
}

/// The level of the conversion of `value` to `type`, an array or a struct type, from the element or field at which the
/// caller's scan stopped (`state.path`) or its own scan stops; nil when every element or field is converted.
private func beginConversionLevel(
    _ type: TypeID,
    _ value: ConstantValue,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> ConversionLevel? {
    switch types[type] {
    case .array(let arrayType):
        guard case .array(let array) = value else {
            wgslFatal("std::get<ConstantArray> of a constant that is not an array", cppSite: "ConstantValue.cpp:233")
        }
        let index = state.path.popLast() ?? firstElementToConvert(array.elements, from: 0, arrayType.element, types, &state)
        guard index < array.elements.count else {
            return nil
        }
        return ConversionLevel(value: value, kind: .elements(arrayType.element), index: index)
    case .struct(let structType):
        guard case .struct(let constantStruct) = value else {
            wgslFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "ConstantValue.cpp:241")
        }
        let fields = types.fields(of: structType.fields)
        // DEV-02: the constant's field order, where C++ iterates the type's field HashMap; every type field must be among them.
        let index = state.path.popLast() ?? firstFieldToConvert(constantStruct.fields, from: 0, fields, types, &state)
        guard index < constantStruct.fields.count else {
            checkHasEveryField(constantStruct, fields)
            return nil
        }
        return ConversionLevel(value: value, kind: .fields(fields), index: index)
    case .primitive, .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer,
        .atomic, .typeConstructor:
        wgslFatal("convertValueImpl to a type that has no constant values", cppSite: "ConstantValue.cpp:263")
    }
}

/// Converts the elements or fields of `level` from `level.index` on, until the conversion of one fails
/// (`level.isConverted` is then false) or one is an array or a struct to convert, whose level is returned
/// (`level.childType` is then its type).
private func convertChildren(
    _ span: SourceSpan,
    _ level: inout ConversionLevel,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> ConversionLevel? {
    if case .elements(let element) = level.kind {
        switch types[element] {
        case .array, .struct:
            break
        case .primitive:
            level.convertScalars(span, element, types, &state)
            return nil
        case .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic,
            .typeConstructor:
            level.convertElements(span, element, types, &state)
            return nil
        }
    }
    while level.index < level.count {
        let type: TypeID
        switch level.kind {
        case .elements(let element):
            level.runEnd = endOfEqualRun(level.array.elements, level.index, &state)
            type = element
        case .fields(let fields):
            state.reads &+= 1
            guard let fieldType = fields.find(level.constantStruct.fields[level.index].key) else {
                level.next(types, &state)
                continue
            }
            type = fieldType
        }
        if let nested = convertElement(span, type, &level, types, &state) {
            level.childType = type
            return nested
        }
        guard level.isConverted else {
            return nil
        }
        level.next(types, &state)
    }
    if case .fields(let fields) = level.kind {
        checkHasEveryField(level.constantStruct, fields)
    }
    return nil
}

/// `convertElement` of element or field `level.index`: the level of its conversion when it is an array or a struct that the
/// level below converts, else nil once it is converted in place (`level.isConverted` is false when that failed).
private func convertElement(
    _ span: SourceSpan,
    _ type: TypeID,
    _ level: inout ConversionLevel,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> ConversionLevel? {
    var child = level.child
    switch types[type] {
    case .array, .struct:
        if state.memo != nil && takeKnownConversion(type, &child, types, &state) {
            level.setChild(child)
            return nil
        }
        beginConversion(child, type, types, &state)
        guard let nested = beginConversionLevel(type, child, types, &state) else {
            endConversion(type, child, types, &state)
            return nil
        }
        level.setChild(.defaultValue)
        return nested
    case .primitive, .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer,
        .atomic, .typeConstructor:
        level.setChild(.defaultValue)
        level.isConverted = convertElement(span, type, &child, types, &state)
        level.setChild(child)
        return nil
    }
}

/// The state of one conversion.
///
/// Values share storage as Swift arrays do: the elements of a zero value, the elements `c` of `array(c, c)` or
/// `array(c, d, c)` and the fields `t` of `S(t, t)` hold one buffer, and so does every value built from them, at every
/// level. Equal values convert to equal values with equal success, so a run of equal elements is read once (`isEqual`
/// compares values that share their storage in O(1), others within a budget). An array or a struct whose scan or
/// conversion read `memoizedReads` elements and fields (16 where it met an equal or remembered value) besides those of
/// the values remembered already is remembered, with its conversion, and every later occurrence of its storage takes
/// that: a value that is not remembered costs fewer reads than that, however often it recurs.
private struct ConversionState {
    static let memoizedReads = 1024

    /// The indices at which a scan stopped, one per level from the deepest: convertValueImpl starts converting each level
    /// there instead of reading again what the scan read.
    var path: [Int] = []
    /// The number of elements and fields read so far.
    var reads = 0
    /// The number of elements and fields read so far that are equal to one read before (the element or field before
    /// them, or a remembered value).
    var shares = 0
    /// The number of `reads` in the scans and conversions of the remembered values.
    var knownReads = 0
    let memoizedReads: Int
    /// Nil until the first scan or conversion of an array or a struct, so that other conversions allocate nothing more.
    var memo: ConversionMemo?

    init(memoizedReads: Int) {
        self.memoizedReads = memoizedReads
    }

    /// Whether a value whose scan or conversion started at `start` is worth remembering; when it is, its reads count as
    /// `knownReads`.
    mutating func isWorthRemembering(since start: ConversionStart) -> Bool {
        let valueReads = (reads &- knownReads) &- start.unknownReads
        guard valueReads >= memoizedReads || (valueReads >= min(memoizedReads, 16) && shares != start.shares) else {
            return false
        }
        knownReads &+= valueReads
        return true
    }
}

/// The remembered arrays and structs of a conversion, and the scans and conversions of arrays and structs in progress
/// (kept here rather than in the recursion's frames).
private struct ConversionMemo {
    /// The remembered values and their conversions, by their storage and the type they were converted to.
    var known = KnownConversions()
    /// The scans and conversions in progress, outermost first.
    var starts: [ConversionStart] = []
}

private struct ConversionStart {
    /// The value being converted; nil for a scan.
    let source: ConstantValue?
    /// `reads - knownReads` at the start.
    let unknownReads: Int
    let shares: Int
}

private struct KnownConversion {
    /// Holds its storage, so that no other buffer gets the storage's identity while it is remembered.
    let value: ConstantValue
    /// The value itself when `changed` is false.
    let converted: ConstantValue
    let changed: Bool
}

private struct KnownKey: Equatable {
    let storage: ObjectIdentifier
    let type: TypeID
}

/// An open-addressing table of remembered conversions, at most half full, over a multiplicative hash of their keys: the
/// identities are the addresses of live buffers, which no source text chooses.
private struct KnownConversions {
    private var keys: [KnownKey] = []
    private var conversions: [KnownConversion] = []
    /// 0 for an empty slot, else a position in `keys` + 1; none, or a power of two of them.
    private var slots: [Int] = []
    /// 64 - log2(slots.count).
    private var shift: UInt64 = 64

    var isEmpty: Bool { keys.isEmpty }

    func find(_ key: KnownKey) -> KnownConversion? {
        guard !slots.isEmpty else {
            return nil
        }
        let mask = slots.count &- 1
        var slot = hash(key)
        while slots[slot] != 0 {
            let position = slots[slot] &- 1
            if keys[position] == key {
                return conversions[position]
            }
            slot = (slot &+ 1) & mask
        }
        return nil
    }

    /// Adds `conversion` for `key`, which the table does not hold.
    mutating func add(_ key: KnownKey, _ conversion: KnownConversion) {
        keys.append(key)
        conversions.append(conversion)
        if keys.count &* 2 > slots.count {
            slots = Array(repeating: 0, count: slots.isEmpty ? 16 : slots.count &* 2)
            shift = slots.count == 16 ? 60 : shift &- 1
            var position = 0
            while position < keys.count {
                insert(position)
                position &+= 1
            }
        } else {
            insert(keys.count &- 1)
        }
    }

    private mutating func insert(_ position: Int) {
        let mask = slots.count &- 1
        var slot = hash(keys[position])
        while slots[slot] != 0 {
            slot = (slot &+ 1) & mask
        }
        slots[slot] = position &+ 1
    }

    /// A slot, from the top bits of a Fibonacci hash.
    private func hash(_ key: KnownKey) -> Int {
        let bits = UInt64(UInt(bitPattern: key.storage)) ^ (UInt64(key.type.raw) &* 0xD6E8_FEB8_6659_FD93)
        return Int(truncatingIfNeeded: (bits &* 0x9E37_79B9_7F4A_7C15) >> shift)
    }
}

/// The object that holds the elements or the fields of `value`, an array or a struct, else nil.
///
/// Values that share their storage have the same one, and while a value lives no other buffer has its identity.
@inline(__always)
private func storageIdentity(_ value: ConstantValue) -> ObjectIdentifier? {
    switch value {
    case .array(let array): storageIdentity(array.elements)
    case .struct(let constantStruct): storageIdentity(constantStruct.fields)
    case .float, .half, .double, .int32, .uint32, .int64, .bool, .vector, .matrix: nil
    }
}

@inline(__always)
private func storageIdentity<Element>(_ elements: [Element]) -> ObjectIdentifier? {
    // The buffer object, which isTriviallyIdentical compares by its elements' address; @inlinable, so it back-deploys.
    guard let owner = elements._owner else {
        return nil
    }
    return ObjectIdentifier(owner)
}

/// The remembered conversion of the storage of `value` to `type`.
@inline(never)
private func knownConversion(_ value: ConstantValue, _ type: TypeID, _ state: borrowing ConversionState) -> KnownConversion? {
    guard state.memo?.known.isEmpty == false, let storage = storageIdentity(value),
        let known = state.memo?.known.find(KnownKey(storage: storage, type: type)), sharesStorage(known.value, value)
    else {
        return nil
    }
    return known
}

/// Starts the scan of an array or a struct, or the conversion of `source`, an element or a field that a scan stopped at.
@inline(never)
private func begin(_ source: ConstantValue?, _ state: inout ConversionState) {
    if state.memo == nil {
        state.memo = ConversionMemo()
    }
    state.memo?.starts.append(ConversionStart(source: source, unknownReads: state.reads &- state.knownReads, shares: state.shares))
}

/// Ends the scan that `startScan` started, which found whether `value` is converted to `type`, and returns that.
@inline(never)
private func endScan(
    _ value: ConstantValue,
    _ type: TypeID,
    _ isConverted: Bool,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Bool {
    if !isNeverRemembered(value, type, types, state), let start = state.memo?.starts.popLast(), isConverted {
        remember(value, type, value, changed: false, since: start, &state)
    }
    return isConverted
}

/// Starts the conversion of `value`, an element or a field that a scan stopped at, to `type`.
@inline(never)
private func beginConversion(_ value: ConstantValue, _ type: TypeID, _ types: borrowing TypeStore, _ state: inout ConversionState) {
    if !isNeverRemembered(value, type, types, state) {
        begin(value, &state)
    }
}

/// Ends the conversion that `beginConversion` started, which gave `converted`.
@inline(never)
private func endConversion(_ type: TypeID, _ converted: ConstantValue, _ types: borrowing TypeStore, _ state: inout ConversionState) {
    if !isNeverRemembered(converted, type, types, state), let start = state.memo?.starts.popLast(), let source = start.source {
        remember(source, type, converted, changed: true, since: start, &state)
    }
}

/// Remembers `value` and its conversion to `type`, when it is an array or a struct whose scan or conversion, which
/// started at `start`, is worth it.
private func remember(
    _ value: ConstantValue,
    _ type: TypeID,
    _ converted: ConstantValue,
    changed: Bool,
    since start: ConversionStart,
    _ state: inout ConversionState
) {
    switch value {
    case .array, .struct:
        guard state.isWorthRemembering(since: start), let storage = storageIdentity(value) else {
            return
        }
        state.memo?.known.add(KnownKey(storage: storage, type: type), KnownConversion(value: value, converted: converted, changed: changed))
    case .float, .half, .double, .int32, .uint32, .int64, .bool, .vector, .matrix:
        break
    }
}

/// `convertValueImpl` of an element or a field that a scan stopped at: a remembered one takes its conversion from the
/// memo, and one whose conversion is worth remembering is remembered.
@inline(never)
private func convertElement(
    _ span: SourceSpan,
    _ type: TypeID,
    _ value: inout ConstantValue,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Bool {
    if state.memo != nil && takeKnownConversion(type, &value, types, &state) {
        return true
    }
    beginConversion(value, type, types, &state)
    guard convertValueImpl(span, type, &value, types, &state) else {
        return false
    }
    endConversion(type, value, types, &state)
    return true
}

/// Whether `value` is an array of scalars whose scans and conversions to `type` read fewer than `memoizedReads` elements
/// and meet no shared storage, so that the memo never holds it: it is neither looked up nor started.
@inline(__always)
private func isNeverRemembered(
    _ value: ConstantValue,
    _ type: TypeID,
    _ types: borrowing TypeStore,
    _ state: borrowing ConversionState
) -> Bool {
    guard case .array(let arrayType) = types[type], case .primitive = types[arrayType.element], case .array(let array) = value
    else {
        return false
    }
    return array.elements.count < state.memoizedReads
}

/// Replaces `value`, an element or a field that a scan stopped at, with its remembered conversion to `type`.
@inline(never)
private func takeKnownConversion(
    _ type: TypeID,
    _ value: inout ConstantValue,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Bool {
    guard !isNeverRemembered(value, type, types, state), let known = knownConversion(value, type, state) else {
        return false
    }
    value = known.converted
    state.shares &+= 1
    return true
}

/// Whether `lhs` and `rhs` are arrays, vectors, matrices or structs that share their storage, which makes them equal.
@inline(__always)
private func sharesStorage(_ lhs: ConstantValue, _ rhs: ConstantValue) -> Bool {
    switch (lhs, rhs) {
    case (.array(let a), .array(let b)): sharesStorage(a.elements, b.elements)
    case (.vector(let a), .vector(let b)): sharesStorage(a.elements, b.elements)
    case (.matrix(let a), .matrix(let b)): a.columns == b.columns && a.rows == b.rows && sharesStorage(a.elements, b.elements)
    case (.struct(let a), .struct(let b)): sharesStorage(a.fields, b.fields)
    case (.float, _), (.half, _), (.double, _), (.int32, _), (.uint32, _), (.int64, _), (.bool, _), (.array, _), (.vector, _),
        (.matrix, _), (.struct, _):
        false
    }
}

@inline(__always)
private func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
    // lint-exempt-next-line(L-BD-1): Array.isTriviallyIdentical is @_alwaysEmitIntoClient, so it back-deploys.
    lhs.isTriviallyIdentical(to: rhs)
}

/// Whether `lhs == rhs`, for two composite values compared in at most 64 steps.
///
/// Values that share their storage are equal at once, and values whose elements (or fields) are scalars or share their
/// storage pair by pair are compared element by element. Others are not counted as equal (they are scanned instead): two
/// equal values built apart from shared storage are as long to compare as their logical size, which can be exponential in
/// the source.
private func isEqual(_ lhs: ConstantValue, _ rhs: ConstantValue) -> Bool {
    switch (lhs, rhs) {
    case (.array(let a), .array(let b)): return areShallowEqual(a.elements, b.elements)
    case (.vector(let a), .vector(let b)): return areShallowEqual(a.elements, b.elements)
    case (.matrix(let a), .matrix(let b)): return a.columns == b.columns && a.rows == b.rows && areShallowEqual(a.elements, b.elements)
    case (.struct(let a), .struct(let b)):
        if sharesStorage(a.fields, b.fields) {
            return true
        }
        guard a.fields.count == b.fields.count && a.fields.count <= 64 else {
            return false
        }
        var index = 0
        while index < a.fields.count {
            guard a.fields[index].key == b.fields[index].key && isShallowEqual(a.fields[index].value, b.fields[index].value) else {
                return false
            }
            index += 1
        }
        return true
    case (.float, _), (.half, _), (.double, _), (.int32, _), (.uint32, _), (.int64, _), (.bool, _), (.array, _), (.vector, _),
        (.matrix, _), (.struct, _):
        return false
    }
}

private func areShallowEqual(_ lhs: [ConstantValue], _ rhs: [ConstantValue]) -> Bool {
    if sharesStorage(lhs, rhs) {
        return true
    }
    guard lhs.count == rhs.count && lhs.count <= 64 else {
        return false
    }
    var index = 0
    while index < lhs.count {
        guard isShallowEqual(lhs[index], rhs[index]) else {
            return false
        }
        index += 1
    }
    return true
}

/// `lhs == rhs` for scalars; for composite values, whether they share their storage.
private func isShallowEqual(_ lhs: ConstantValue, _ rhs: ConstantValue) -> Bool {
    switch (lhs, rhs) {
    case (.float(let a), .float(let b)): a.bitPattern == b.bitPattern
    case (.half(let a), .half(let b)): a.bitPattern == b.bitPattern
    case (.double(let a), .double(let b)): a.bitPattern == b.bitPattern
    case (.int32(let a), .int32(let b)): a == b
    case (.uint32(let a), .uint32(let b)): a == b
    case (.int64(let a), .int64(let b)): a == b
    case (.bool(let a), .bool(let b)): a == b
    case (.array, _), (.vector, _), (.matrix, _), (.struct, _): sharesStorage(lhs, rhs)
    case (.float, _), (.half, _), (.double, _), (.int32, _), (.uint32, _), (.int64, _), (.bool, _): false
    }
}

/// Gives the elements of a run equal to `elements[index]` before its conversion its converted value, which keeps them
/// shared.
@inline(never)
private func shareConverted(_ elements: inout [ConstantValue], _ index: Int, _ runEnd: Int) {
    var copy = index + 1
    while copy < runEnd {
        elements[copy] = elements[index]
        copy += 1
    }
}

/// The end of the run of elements from `index` on that are `isEqual` to `elements[index]` when it is a composite value;
/// `index + 1` for a scalar.
@inline(never)
private func endOfEqualRun(_ elements: [ConstantValue], _ index: Int, _ state: inout ConversionState) -> Int {
    var end = index + 1
    switch elements[index] {
    case .array, .vector, .matrix, .struct:
        while end < elements.count && isEqual(elements[end], elements[index]) {
            end += 1
        }
    case .float, .half, .double, .int32, .uint32, .int64, .bool:
        break
    }
    state.reads &+= end - index
    state.shares &+= end - index - 1
    return end
}

/// Whether `convertValueImpl(span, type, &value, types)` would return true and leave `value` as it is. When not, and the
/// scan of `value`'s elements stopped at one, appends its index to `state.path`.
private func isConverted(_ value: ConstantValue, _ type: TypeID, _ types: borrowing TypeStore, _ state: inout ConversionState) -> Bool {
    switch types[type] {
    case .primitive(let primitive):
        switch primitive.kind {
        case .f32:
            guard case .float(let f32) = value else {
                return false
            }
            return convertFloat(Float.self, f32) != nil
        case .f16:
            guard case .half(let f16) = value else {
                return false
            }
            return convertFloat(Half.self, f16) != nil
        case .i32:
            guard case .int32 = value else {
                return false
            }
            return true
        case .u32:
            guard case .uint32 = value else {
                return false
            }
            return true
        case .abstractInt:
            guard case .int64 = value else {
                return false
            }
            return true
        case .abstractFloat:
            guard case .double(let abstractFloat) = value else {
                return false
            }
            return convertFloat(Double.self, abstractFloat) != nil
        case .bool:
            guard case .bool = value else {
                return false
            }
            return true
        case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
            return false
        }
    case .vector(let vectorType):
        guard case .vector(let vector) = value else {
            return false
        }
        return isEnd(scanElements(vector.elements, from: 0, vectorType.element, types, &state), vector.elements.count, &state.path)
    case .matrix(let matrixType):
        guard case .matrix(let matrix) = value else {
            return false
        }
        return isEnd(scanElements(matrix.elements, from: 0, matrixType.element, types, &state), matrix.elements.count, &state.path)
    case .array, .struct:
        return isConvertedNested(value, type, types, &state)
    case .primitiveStruct(let primitiveStruct):
        guard case .struct(let constantStruct) = value else {
            return false
        }
        let index = firstFieldToConvert(constantStruct.fields, from: 0, primitiveStruct, types, &state)
        return isEnd(index, constantStruct.fields.count, &state.path)
    case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic, .typeConstructor:
        return false
    }
}

/// `isConverted` of `value` to an array or a struct type.
private func isConvertedNested(
    _ value: ConstantValue,
    _ type: TypeID,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Bool {
    // DEV-03: the arrays and structs nested in `value` are scanned one level after another (`ScanLevel`), where the C++
    // recurses: type nesting has no depth limit.
    var level: ScanLevel
    switch beginScan(value, type, types, &state) {
    case .converted(let isConverted):
        return isConverted
    case .level(let first):
        level = first
    }
    var outer: [ScanLevel] = []
    while true {
        if let nested = scanChildren(&level, types, &state) {
            outer.append(level)
            level = nested
            continue
        }
        var isConverted = endScan(level, types, &state)
        while true {
            guard let parent = outer.popLast() else {
                return isConverted
            }
            level = parent
            if isConverted {
                level.index += 1
                break
            }
            isConverted = endScan(level, types, &state)
        }
    }
}

/// A level of a scan: the elements of an array or the fields of a struct, read from `index` on.
private struct ScanLevel {
    let value: ConstantValue
    let type: TypeID
    let children: ScanChildren
    var index = 0
}

private enum ScanChildren {
    case elements([ConstantValue], element: TypeID)
    case fields(ConstantStruct, SymbolMap<TypeID>)
}

private enum ScanStart {
    case converted(Bool)
    case level(ScanLevel)
}

/// The start of `isConverted(value, type)`: the level to scan when `type` is an array or a struct type, `value` is one and
/// it is not remembered; else whether `value` is converted.
private func beginScan(_ value: ConstantValue, _ type: TypeID, _ types: borrowing TypeStore, _ state: inout ConversionState) -> ScanStart {
    switch types[type] {
    case .array(let arrayType):
        guard case .array(let array) = value else {
            return .converted(false)
        }
        if let isKnownConverted = startScan(value, type, types, &state) {
            return .converted(isKnownConverted)
        }
        return .level(ScanLevel(value: value, type: type, children: .elements(array.elements, element: arrayType.element)))
    case .struct(let structType):
        guard case .struct(let constantStruct) = value else {
            return .converted(false)
        }
        if let isKnownConverted = startScan(value, type, types, &state) {
            return .converted(isKnownConverted)
        }
        return .level(ScanLevel(value: value, type: type, children: .fields(constantStruct, types.fields(of: structType.fields))))
    case .primitive, .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer,
        .atomic, .typeConstructor:
        return .converted(isConverted(value, type, types, &state))
    }
}

/// Reads the children of `level` from `level.index` on, as `scanElements` and `firstFieldToConvert` do, until one is not
/// converted (`level.index` is then its index) or is an array or a struct whose level is returned.
private func scanChildren(_ level: inout ScanLevel, _ types: borrowing TypeStore, _ state: inout ConversionState) -> ScanLevel? {
    switch level.children {
    case .elements(let elements, let element):
        switch types[element] {
        case .array, .struct:
            break
        case .primitive, .vector, .matrix, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer,
            .atomic, .typeConstructor:
            level.index = scanElements(elements, from: level.index, element, types, &state)
            return nil
        }
        while level.index < elements.count {
            if elementNeedsCheck(elements, level.index, &state) {
                switch beginScan(elements[level.index], element, types, &state) {
                case .converted(let isConverted):
                    guard isConverted else {
                        return nil
                    }
                case .level(let nested):
                    return nested
                }
            }
            level.index += 1
        }
    case .fields(let constantStruct, let fields):
        let constantFields = constantStruct.fields
        while level.index < constantFields.count {
            if let type = fieldTypeToCheck(constantFields, level.index, fields, &state) {
                switch beginScan(constantFields[level.index].value, type, types, &state) {
                case .converted(let isConverted):
                    guard isConverted else {
                        return nil
                    }
                case .level(let nested):
                    return nested
                }
            }
            level.index += 1
        }
    }
    return nil
}

/// The end of `isConverted` of the value of `level`, whose scan stopped at `level.index`.
private func endScan(_ level: ScanLevel, _ types: borrowing TypeStore, _ state: inout ConversionState) -> Bool {
    switch level.children {
    case .elements(let elements, _):
        return endScan(level.value, level.type, isEnd(level.index, elements.count, &state.path), types, &state)
    case .fields(let constantStruct, let fields):
        return endScan(
            level.value,
            level.type,
            isEnd(level.index, constantStruct.fields.count, &state.path) && foundFieldCount(constantStruct, fields) == fields.count,
            types,
            &state
        )
    }
}

/// Whether `value`, an array or a struct, is converted to `type`, when it is remembered; else nil, and its scan starts.
@inline(never)
private func startScan(_ value: ConstantValue, _ type: TypeID, _ types: borrowing TypeStore, _ state: inout ConversionState) -> Bool? {
    if isNeverRemembered(value, type, types, state) {
        return nil
    }
    if state.memo != nil, let known = knownConversion(value, type, state) {
        state.shares &+= 1
        return !known.changed
    }
    begin(nil, &state)
    return nil
}

/// Whether a scan that stopped at `index` read all `count` elements; when not, appends `index` to `path`.
@inline(never)
private func isEnd(_ index: Int, _ count: Int, _ path: inout [Int]) -> Bool {
    guard index == count else {
        path.append(index)
        return false
    }
    return true
}

/// The index of the first element from `start` on that is not `isConverted` to `type`, or `elements.count`.
///
/// The elements before `start` are converted. Not inlined into the recursion of convertValueImpl, to keep its frames small.
@inline(never)
private func firstElementToConvert(
    _ elements: [ConstantValue],
    from start: Int,
    _ type: TypeID,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Int {
    scanElements(elements, from: start, type, types, &state)
}

@inline(__always)
private func scanElements(
    _ elements: [ConstantValue],
    from start: Int,
    _ type: TypeID,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Int {
    var index = start
    while index < elements.count {
        if elementNeedsCheck(elements, index, &state) && !isConverted(elements[index], type, types, &state) {
            break
        }
        index += 1
    }
    return index
}

/// Reads element `index` for a scan: whether it is to be checked, which it is not when it equals the element before it.
@inline(__always)
private func elementNeedsCheck(_ elements: [ConstantValue], _ index: Int, _ state: inout ConversionState) -> Bool {
    state.reads &+= 1
    if index > 0 && equalsCompositeBefore(elements, index) {
        state.shares &+= 1
        return false
    }
    return true
}

/// Whether `elements[index]` is a composite value `isEqual` to the one before it (then both are converted, or neither).
@inline(never)
private func equalsCompositeBefore(_ elements: [ConstantValue], _ index: Int) -> Bool {
    switch elements[index] {
    case .array, .vector, .matrix, .struct:
        return isEqual(elements[index], elements[index - 1])
    case .float, .half, .double, .int32, .uint32, .int64, .bool:
        return false
    }
}

/// The index of the first field from `start` on that is a field of the struct type and not `isConverted` to its type, or
/// `constantFields.count`.
///
/// The fields of the struct type before `start` are converted.
@inline(never)
private func firstFieldToConvert(
    _ constantFields: [(key: Symbol, value: ConstantValue)],
    from start: Int,
    _ fields: borrowing SymbolMap<TypeID>,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Int {
    var index = start
    while index < constantFields.count {
        if let type = fieldTypeToCheck(constantFields, index, fields, &state),
            !isConverted(constantFields[index].value, type, types, &state)
        {
            break
        }
        index += 1
    }
    return index
}

/// Reads field `index` for a scan: the type to check it against, or nil when it is not a field of the struct type or
/// repeats the field before it.
@inline(__always)
private func fieldTypeToCheck(
    _ constantFields: [(key: Symbol, value: ConstantValue)],
    _ index: Int,
    _ fields: borrowing SymbolMap<TypeID>,
    _ state: inout ConversionState
) -> TypeID? {
    state.reads &+= 1
    guard let type = fields.find(constantFields[index].key) else {
        return nil
    }
    if repeatsFieldBefore(constantFields, index, type, fields) {
        state.shares &+= 1
        return nil
    }
    return type
}

/// Whether field `index` is a composite value `isEqual` to the field before it, of the same type (then both are converted).
///
/// The fields of the zero value of `struct S { a: T, b: T }` share their storage, so a value nested through such structs is
/// read once per level, not once per path to its scalars.
@inline(never)
private func repeatsFieldBefore(
    _ constantFields: [(key: Symbol, value: ConstantValue)],
    _ index: Int,
    _ type: TypeID,
    _ fields: borrowing SymbolMap<TypeID>
) -> Bool {
    guard index > 0, fields.find(constantFields[index - 1].key) == type else {
        return false
    }
    switch constantFields[index].value {
    case .array, .vector, .matrix, .struct:
        return isEqual(constantFields[index].value, constantFields[index - 1].value)
    case .float, .half, .double, .int32, .uint32, .int64, .bool:
        return false
    }
}

/// The index of the first field from `start` on that is not a field of the primitive struct type or not `isConverted` to
/// its type, or `constantFields.count`.
@inline(never)
private func firstFieldToConvert(
    _ constantFields: [(key: Symbol, value: ConstantValue)],
    from start: Int,
    _ primitiveStruct: Types.PrimitiveStruct,
    _ types: borrowing TypeStore,
    _ state: inout ConversionState
) -> Int {
    let keys = Types.PrimitiveStruct.keys(primitiveStruct.kind)
    var index = start
    while index < constantFields.count {
        state.reads &+= 1
        guard let key = keys.tryGet(constantFields[index].key),
            isConverted(constantFields[index].value, types[primitiveStruct.values, key], types, &state)
        else {
            break
        }
        index += 1
    }
    return index
}

/// The number of fields of `constantStruct` that are fields of the struct type.
private func foundFieldCount(_ constantStruct: ConstantStruct, _ fields: borrowing SymbolMap<TypeID>) -> Int {
    var found = 0
    var index = 0
    while index < constantStruct.fields.count {
        if fields.contains(constantStruct.fields[index].key) {
            found += 1
        }
        index += 1
    }
    return found
}

private func checkHasEveryField(_ constantStruct: ConstantStruct, _ fields: borrowing SymbolMap<TypeID>) {
    guard foundFieldCount(constantStruct, fields) == fields.count else {
        wgslFatal("a struct type field that the constant does not have", cppSite: "ConstantValue.cpp:244")
    }
}

// MARK: - Swift-only

extension ShaderModule {
    /// The `StringTypeAdapter<ConstantValue>` text of `value`, for a message.
    @_spi(Testing)
    public func dump(_ value: ConstantValue) -> MessageText {
        var text = MessageText(codeUnits: [])
        value.dump(into: &text, symbols)
        return text
    }
}

extension ConstantArray {
    @_spi(Testing)
    public static func == (lhs: ConstantArray, rhs: ConstantArray) -> Bool {
        lhs.elements == rhs.elements
    }
}

extension ConstantStruct {
    /// `ConstantStruct({ { "fract"_s, fract }, { "exp"_s, exp } })` (frexp), in that HashMap's order.
    @_spi(Testing)
    public static func frexpResult(fract: ConstantValue, exp: ConstantValue) -> ConstantStruct {
        var result = ConstantStruct()
        result.fields = [(key: Symbol(BuiltinSymbols.fract), value: fract), (key: Symbol(BuiltinSymbols.exp), value: exp)]
        return result
    }

    /// `ConstantStruct({ { "fract"_s, fract }, { "whole"_s, whole } })` (modf), in that HashMap's order.
    @_spi(Testing)
    public static func modfResult(fract: ConstantValue, whole: ConstantValue) -> ConstantStruct {
        var result = ConstantStruct()
        result.fields = [(key: Symbol(BuiltinSymbols.fract), value: fract), (key: Symbol(BuiltinSymbols.whole), value: whole)]
        return result
    }

    @_spi(Testing)
    public static func == (lhs: ConstantStruct, rhs: ConstantStruct) -> Bool {
        // Values that share their fields, as the equal members of a zero value do, are equal without reading them (as
        // `Array.==` does for shared storage).
        // lint-exempt-next-line(L-BD-1): Array.isTriviallyIdentical is @_alwaysEmitIntoClient, so it back-deploys.
        if lhs.fields.isTriviallyIdentical(to: rhs.fields) {
            return true
        }
        guard lhs.fields.count == rhs.fields.count else {
            return false
        }
        var index = 0
        while index < lhs.fields.count {
            guard lhs.fields[index].key == rhs.fields[index].key && lhs.fields[index].value == rhs.fields[index].value else {
                return false
            }
            index += 1
        }
        return true
    }
}

extension ConstantValue {
    @_spi(Testing)
    public static func == (lhs: ConstantValue, rhs: ConstantValue) -> Bool {
        switch (lhs, rhs) {
        case (.float(let a), .float(let b)): a.bitPattern == b.bitPattern
        case (.half(let a), .half(let b)): a.bitPattern == b.bitPattern
        case (.double(let a), .double(let b)): a.bitPattern == b.bitPattern
        case (.int32(let a), .int32(let b)): a == b
        case (.uint32(let a), .uint32(let b)): a == b
        case (.int64(let a), .int64(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.vector(let a), .vector(let b)): a == b
        case (.matrix(let a), .matrix(let b)): a == b
        case (.struct(let a), .struct(let b)): a == b
        case (.float, _), (.half, _), (.double, _), (.int32, _), (.uint32, _), (.int64, _), (.bool, _), (.array, _), (.vector, _),
            (.matrix, _), (.struct, _):
            false
        }
    }
}

/// `count` default values (C++ `FixedVector<ConstantValue>(count)`); not `Array(repeating:count:)`, which takes the
/// runtime's generic path at -O.
func defaultConstantValues(_ count: Int) -> [ConstantValue] {
    var values: [ConstantValue] = []
    values.reserveCapacity(count)
    var index = 0
    while index < count {
        values.append(.defaultValue)
        index &+= 1
    }
    return values
}
