// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

/// The class of a binary expression's right operand, which decides how `/` and `%` are spelled.
@_spi(Testing)
public enum ScalarClass: CaseIterable, Sendable {
    /// `i32`, `u32` or `AbstractInt`, a reference to one, or a vector of them.
    case integer
    /// Every other type: the floating-point types, and the types no division accepts.
    case nonInteger

    /// C++ `satisfies(rightType, Constraints::Integer)` once a vector has been replaced by its element type
    /// (MetalFunctionWriter.cpp:3011-3015).
    @_spi(Testing)
    public init(rightOperandType: TypeID?, in types: borrowing TypeStore) {
        var rightType = rightOperandType
        if let vectorType = types.getIf(Types.Vector.self, rightType) {
            rightType = vectorType.element
        }
        self = satisfies(rightType, .integer, types) ? .integer : .nonInteger
    }
}

/// How the writer spells a binary operation in MSL (MetalFunctionWriter.cpp:3004-3096).
@_spi(Testing)
public enum BinaryEmission: Sendable {
    /// `(lhs <operator> rhs)`; the text is the operator with its surrounding spaces.
    case infix(MSLText)
    /// `function(lhs, rhs)`.
    case call(MSLText)
}

/// The MSL spelling of `operation`: exhaustive over the operation and the class of its right operand, so an integer
/// `/` or `%` has no infix spelling.
///
/// Integer division and remainder go through `__wgslDiv` and `__wgslMod`, which neutralise a zero divisor and `INT_MIN / -1`;
/// emitNecessaryHelpers defines them when the type checker recorded a use (`helpers`, TypeCheck.cpp:1471-1473), so a call
/// without that record would name a helper the library does not define. Floating-point `%` is `fmod`. Shifts stay bare:
/// Metal masks every shift amount to the width of the shifted type.
@_spi(Testing)
public func emission(for operation: BinaryOperation, rhs: ScalarClass, helpers: UsesFlags) -> BinaryEmission {
    switch (operation, rhs) {
    case (.divide, .integer):
        guard helpers.contains(.division) else {
            wgslFatal("an integer division without the __wgslDiv helper", cppSite: "TypeCheck.cpp:1471")
        }
        return .call("__wgslDiv")
    case (.modulo, .integer):
        guard helpers.contains(.modulo) else {
            wgslFatal("an integer modulo without the __wgslMod helper", cppSite: "TypeCheck.cpp:1473")
        }
        return .call("__wgslMod")
    case (.modulo, .nonInteger):
        return .call("fmod")
    case (.divide, .nonInteger):
        return .infix(" / ")
    case (.add, _):
        return .infix(" + ")
    case (.subtract, _):
        return .infix(" - ")
    case (.multiply, _):
        return .infix(" * ")
    case (.and, _):
        return .infix(" & ")
    case (.or, _):
        return .infix(" | ")
    case (.xor, _):
        return .infix(" ^ ")
    case (.leftShift, _):
        return .infix(" << ")
    case (.rightShift, _):
        return .infix(" >> ")
    case (.equal, _):
        return .infix(" == ")
    case (.notEqual, _):
        return .infix(" != ")
    case (.greaterThan, _):
        return .infix(" > ")
    case (.greaterEqual, _):
        return .infix(" >= ")
    case (.lessThan, _):
        return .infix(" < ")
    case (.lessEqual, _):
        return .infix(" <= ")
    case (.shortCircuitAnd, _):
        return .infix(" && ")
    case (.shortCircuitOr, _):
        return .infix(" || ")
    }
}

extension FunctionDefinitionWriter {
    /// The callee of a value constructor (MetalFunctionWriter.cpp:2953-2958 and :2974-2979): a float-to-integer conversion
    /// goes through `__wgslFtoi<T>`, which saturates where an MSL conversion of an out-of-range value is undefined.
    mutating func printConstructorTarget(_ type: TypeID, isFloatToIntConversion: Bool) {
        if isFloatToIntConversion {
            body.append("__wgslFtoi<")
            printValueType(type)
            body.append(">")
        } else {
            printValueType(type)
        }
    }
}
