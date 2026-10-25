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

/// C++ `Constraint` (`uint8_t`) with the `Constraints::` constants (Constraints.h:35-66).
///
/// `satisfies` and `satisfyOrPromote` compare raw values where the C++ compares the integers, so the raw values are the
/// C++ bits.
@_spi(Testing)
public struct Constraint: OptionSet, BitwiseCopyable, Hashable, Sendable {
    @_spi(Testing)
    public let rawValue: UInt8

    @_spi(Testing)
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    @_spi(Testing)
    public static let none: Constraint = []

    @_spi(Testing)
    public static let bool = Constraint(rawValue: 1 << 0)
    @_spi(Testing)
    public static let abstractInt = Constraint(rawValue: 1 << 1)
    @_spi(Testing)
    public static let i32 = Constraint(rawValue: 1 << 2)
    @_spi(Testing)
    public static let u32 = Constraint(rawValue: 1 << 3)
    @_spi(Testing)
    public static let abstractFloat = Constraint(rawValue: 1 << 4)
    @_spi(Testing)
    public static let f32 = Constraint(rawValue: 1 << 5)
    @_spi(Testing)
    public static let f16 = Constraint(rawValue: 1 << 6)

    @_spi(Testing)
    public static let concreteFloat: Constraint = [.f16, .f32]
    @_spi(Testing)
    public static let float: Constraint = [.concreteFloat, .abstractFloat]

    @_spi(Testing)
    public static let concreteInteger: Constraint = [.i32, .u32]
    @_spi(Testing)
    public static let integer: Constraint = [.concreteInteger, .abstractInt]
    @_spi(Testing)
    public static let signedInteger: Constraint = [.i32, .abstractInt]

    @_spi(Testing)
    public static let scalar: Constraint = [.bool, .integer, .float]
    @_spi(Testing)
    public static let concreteScalar: Constraint = [.bool, .concreteInteger, .concreteFloat]

    @_spi(Testing)
    public static let concrete32BitNumber: Constraint = [.concreteInteger, .f32]

    @_spi(Testing)
    public static let signedNumber: Constraint = [.float, .signedInteger]
    @_spi(Testing)
    public static let number: Constraint = [.float, .integer]
    @_spi(Testing)
    public static let concreteNumber: Constraint = [.concreteInteger, .concreteFloat]
}

/// C++ `satisfies(const Type*, Constraint)`; a nil type is the C++ null pointer.
@_spi(Testing)
public func satisfies(_ type: TypeID?, _ constraint: Constraint, _ types: borrowing TypeStore) -> Bool {
    if constraint == .none {
        return true
    }

    guard let primitive = types.getIf(Types.Primitive.self, type) else {
        if let reference = types.getIf(Types.Reference.self, type) {
            return satisfies(reference.element, constraint, types)
        }
        return false
    }

    switch primitive.kind {
    case .abstractInt:
        return constraint.rawValue >= Constraint.abstractInt.rawValue
    case .abstractFloat:
        return !constraint.isDisjoint(with: .float)
    case .i32:
        return constraint.contains(.i32)
    case .u32:
        return constraint.contains(.u32)
    case .f32:
        return constraint.contains(.f32)
    case .f16:
        return constraint.contains(.f16)
    case .bool:
        return constraint.contains(.bool)

    case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
        return false
    }
}

/// C++ `satisfyOrPromote(const Type*, Constraint, const TypeStore&)`; a nil type is the C++ null pointer.
@_spi(Testing)
public func satisfyOrPromote(_ type: TypeID?, _ constraint: Constraint, _ types: borrowing TypeStore) -> TypeID? {
    if constraint == .none {
        return type
    }

    guard let primitive = types.getIf(Types.Primitive.self, type) else {
        if let reference = types.getIf(Types.Reference.self, type) {
            return satisfyOrPromote(reference.element, constraint, types)
        }
        return nil
    }

    switch primitive.kind {
    case .abstractInt:
        if constraint.rawValue < Constraint.abstractInt.rawValue {
            return nil
        }
        if constraint.contains(.abstractInt) {
            return type
        }
        if constraint.contains(.i32) {
            return types.i32Type
        }
        if constraint.contains(.u32) {
            return types.u32Type
        }
        if constraint.contains(.abstractFloat) {
            return types.abstractFloatType
        }
        if constraint.contains(.f32) {
            return types.f32Type
        }
        if constraint.contains(.f16) {
            return types.f16Type
        }
        wgslFatal("satisfyOrPromote: no promotion of AbstractInt satisfies the constraint", cppSite: "Constraints.cpp:100")
    case .abstractFloat:
        if constraint.rawValue < Constraint.abstractFloat.rawValue {
            return nil
        }
        if constraint.contains(.abstractFloat) {
            return type
        }
        if constraint.contains(.f32) {
            return types.f32Type
        }
        if constraint.contains(.f16) {
            return types.f16Type
        }
        wgslFatal("satisfyOrPromote: no promotion of AbstractFloat satisfies the constraint", cppSite: "Constraints.cpp:110")
    case .i32:
        if !constraint.contains(.i32) {
            return nil
        }
        return type
    case .u32:
        if !constraint.contains(.u32) {
            return nil
        }
        return type
    case .f32:
        if !constraint.contains(.f32) {
            return nil
        }
        return type
    case .f16:
        if !constraint.contains(.f16) {
            return nil
        }
        return type
    case .bool:
        if !constraint.contains(.bool) {
            return nil
        }
        return type

    case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
        return nil
    }
}

/// C++ `concretize(const Type*, TypeStore&)`.
@_spi(Testing)
public func concretize(_ type: TypeID, _ types: inout TypeStore) -> TypeID? {
    // DEV-03: an explicit stack where Constraints.cpp recurses, as alias chains nest arrays without bound (innermost first).
    var containers: [ConcretizeContainer] = []
    var current = type
    var leaf: TypeID?
    walk: while true {
        switch types[current] {
        case .primitive:
            leaf = satisfyOrPromote(current, .concreteScalar, types)
            break walk
        case .vector(let vector):
            containers.append(.vector(vector.size))
            current = vector.element
        case .matrix(let matrix):
            containers.append(.matrix(columns: matrix.columns, rows: matrix.rows))
            current = matrix.element
        case .array(let array):
            containers.append(.array(array.size))
            current = array.element
        case .struct:
            leaf = current
            break walk
        case .primitiveStruct(let primitiveStruct):
            leaf = concretize(primitiveStruct, current, &types)
            break walk
        case .pointer:
            leaf = current
            break walk
        case .atomic:
            leaf = current
            break walk
        case .function, .texture, .textureStorage, .textureDepth, .reference, .typeConstructor:
            leaf = nil
            break walk
        }
    }

    var result = leaf
    while let container = containers.popLast() {
        guard let element = result else {
            return nil
        }
        switch container {
        case .vector(let size):
            result = types.vectorType(size, element)
        case .matrix(let columns, let rows):
            result = types.matrixType(columns, rows, element)
        case .array(let size):
            result = types.arrayType(element, size)
        }
    }
    return result
}

/// The `PrimitiveStruct` case of `concretize`.
///
/// The values of a primitive struct are scalars and vectors, so the recursion is one level deep.
private func concretize(_ primitiveStruct: Types.PrimitiveStruct, _ type: TypeID, _ types: inout TypeStore) -> TypeID? {
    switch primitiveStruct.kind {
    case .frexpResult:
        let fract = concretize(types[primitiveStruct.values, Types.PrimitiveStruct.FrexpResult.fract], &types)
        let exp = concretize(types[primitiveStruct.values, Types.PrimitiveStruct.FrexpResult.exp], &types)
        guard let fract, let exp else {
            return nil
        }
        return types.frexpResultType(fract, exp)
    case .modfResult:
        let fract = concretize(types[primitiveStruct.values, Types.PrimitiveStruct.ModfResult.fract], &types)
        let whole = concretize(types[primitiveStruct.values, Types.PrimitiveStruct.ModfResult.whole], &types)
        guard let fract, let whole else {
            return nil
        }
        return types.modfResultType(fract, whole)
    case .atomicCompareExchangeResult:
        return type
    }
}

/// A container `concretize` rebuilds around the concretized element.
private enum ConcretizeContainer {
    case vector(UInt8)
    case matrix(columns: UInt8, rows: UInt8)
    case array(Types.Array.Size)
}
