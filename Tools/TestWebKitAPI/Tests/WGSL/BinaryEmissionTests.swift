// swift-format-ignore-file: AlwaysUseLowerCamelCase
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

import Testing
@_spi(Testing) import WGSL

/// The bytes serializeBinaryExpression writes around operands spelled `lhs` and `rhs` (MetalFunctionWriter.cpp:3004-3096).
private func spelling(_ emission: BinaryEmission) -> String {
    var writer = MSLWriter()
    switch emission {
    case .infix(let infixOperator):
        writer.append("(lhs")
        writer.append(infixOperator)
        writer.append("rhs)")
    case .call(let function):
        writer.append(function)
        writer.append("(lhs, rhs)")
    }
    return String(decoding: writer.bytes, as: UTF8.self)
}

private let bothHelpers: UsesFlags = [.division, .modulo]

/// The C++ spellings, in BinaryOperation order: with an integer right operand, and with any other.
private let cxxSpellings: [(operation: BinaryOperation, integer: String, nonInteger: String)] = [
    (.add, "(lhs + rhs)", "(lhs + rhs)"),
    (.subtract, "(lhs - rhs)", "(lhs - rhs)"),
    (.multiply, "(lhs * rhs)", "(lhs * rhs)"),
    (.divide, "__wgslDiv(lhs, rhs)", "(lhs / rhs)"),
    (.modulo, "__wgslMod(lhs, rhs)", "fmod(lhs, rhs)"),
    (.and, "(lhs & rhs)", "(lhs & rhs)"),
    (.or, "(lhs | rhs)", "(lhs | rhs)"),
    (.xor, "(lhs ^ rhs)", "(lhs ^ rhs)"),
    (.leftShift, "(lhs << rhs)", "(lhs << rhs)"),
    (.rightShift, "(lhs >> rhs)", "(lhs >> rhs)"),
    (.equal, "(lhs == rhs)", "(lhs == rhs)"),
    (.notEqual, "(lhs != rhs)", "(lhs != rhs)"),
    (.greaterThan, "(lhs > rhs)", "(lhs > rhs)"),
    (.greaterEqual, "(lhs >= rhs)", "(lhs >= rhs)"),
    (.lessThan, "(lhs < rhs)", "(lhs < rhs)"),
    (.lessEqual, "(lhs <= rhs)", "(lhs <= rhs)"),
    (.shortCircuitAnd, "(lhs && rhs)", "(lhs && rhs)"),
    (.shortCircuitOr, "(lhs || rhs)", "(lhs || rhs)"),
]

/// The divisions and remainders of a module after the static passes, with the class of their right operand.
private struct DivisionCollector: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var divisions: [Division] = []

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func record(_ operation: BinaryOperation, _ rightExpression: ExpressionID) {
        guard operation == .divide || operation == .modulo else {
            return
        }
        let rhs = ScalarClass(rightOperandType: shaderModule.inferredType(of: rightExpression), in: shaderModule.types)
        divisions.append(Division(operation: operation, rhs: rhs))
    }

    mutating func visit(_ binary: BinaryExpression, _ id: ExpressionID) {
        record(binary.operation, binary.rightExpression)
        visitChildren(binary, id)
    }

    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        record(statement.operation, statement.rightExpression)
        visitChildren(statement, id)
    }
}

private struct Division: Sendable {
    let operation: BinaryOperation
    let rhs: ScalarClass
}

private struct StaticPassesResult: Sendable {
    let uses: UsesFlags
    let divisions: [Division]
}

/// The helper uses and the divisions of `source` after the static passes (WGSL.cpp:94-113), or nil if a pass failed.
private func staticPassesResult(_ source: SourceText) -> StaticPassesResult? {
    var module = ShaderModule(source: source, configuration: testsConfiguration)
    func failed(_ result: FailedCheck?) -> Bool {
        result.map { !$0.errors.isEmpty } ?? false
    }
    if failed(parse(&module)) || failed(reorderGlobals(&module)) || failed(typeCheck(&module)) || failed(validateAttributes(&module)) {
        return nil
    }
    buildCallGraph(&module)
    if failed(validateIO(&module)) || failed(validateVisibility(&module)) {
        return nil
    }
    mangleNames(&module)
    rewriteEvaluationOrder(&module)
    rewritePointers(&module)
    if failed(aliasAnalysis(&module)) || failed(uniformityAnalysis(&module)) {
        return nil
    }
    var collector = DivisionCollector(shaderModule: module)
    collector.visitShaderModule()
    return StaticPassesResult(uses: collector.shaderModule.uses, divisions: collector.divisions)
}

private let moduloSource = SourceText(
    """
    enable f16;

    @group(0) @binding(0) var<storage, read_write> output: array<i32, 4>;

    fn remainders(a: i32, b: u32, v: vec3<i32>, w: vec2<u32>, f: f32, h: f16, x: vec4<f32>) -> i32 {
        var r = a % a;
        r %= a;
        var s = b % b;
        s %= 3u;
        let t = v % v;
        let u = v % a;
        let y = w % 2u;
        let g = f % f;
        let k = h % h;
        let z = x % x;
        let q = 7 % 2;
        return r + i32(s) + t.x + u.y + i32(y.x) + i32(g) + i32(k) + i32(z.w) + q;
    }

    @compute @workgroup_size(1)
    fn main() {
        output[0] = remainders(1, 2u, vec3(3), vec2(4u), 5.0, 6.0h, vec4(7.0));
    }

    """
)

private let floatOnlySource = SourceText(
    """
    @group(0) @binding(0) var<storage, read_write> output: array<f32, 4>;

    @compute @workgroup_size(1)
    fn main() {
        var f = output[1];
        f /= output[2];
        f %= output[3];
        output[0] = (f / output[1]) % output[2];
        let i = i32(f);
        output[3] = f32(i);
    }

    """
)

@Suite
struct WGSLBinaryEmissionTests {
    // The emission table is the C++'s, for every operation and right-operand class.
    @Test
    func emissionTableMatchesTheCxxSpellings() {
        #expect(cxxSpellings.map(\.operation) == BinaryOperation.allCases)
        for entry in cxxSpellings {
            #expect(spelling(emission(for: entry.operation, rhs: .integer, helpers: bothHelpers)) == entry.integer, "\(entry.operation)")
            #expect(
                spelling(emission(for: entry.operation, rhs: .nonInteger, helpers: bothHelpers)) == entry.nonInteger,
                "\(entry.operation)"
            )
        }
    }

    // An integer `/` or `%` is only ever a __wgslDiv or __wgslMod call, and `%` has no infix spelling at all.
    @Test
    func integerDivisionAndRemainderOnlyThroughTheHelpers() {
        for operation in BinaryOperation.allCases {
            for rhs in ScalarClass.allCases {
                let text = spelling(emission(for: operation, rhs: rhs, helpers: bothHelpers))
                #expect(!text.contains(" % "), "\(operation) \(rhs)")
                if text.contains(" / ") {
                    #expect(operation == .divide && rhs == .nonInteger, "\(operation) \(rhs)")
                }
                if rhs == .integer && operation == .divide {
                    #expect(text == "__wgslDiv(lhs, rhs)")
                }
                if rhs == .integer && operation == .modulo {
                    #expect(text == "__wgslMod(lhs, rhs)")
                }
            }
        }
    }

    // Shifts stay bare MSL operators for every operand class: Metal masks the amount.
    @Test
    func shiftsAreBare() {
        for rhs in ScalarClass.allCases {
            #expect(spelling(emission(for: .leftShift, rhs: rhs, helpers: [])) == "(lhs << rhs)")
            #expect(spelling(emission(for: .rightShift, rhs: rhs, helpers: [])) == "(lhs >> rhs)")
        }
    }

    // Only the integer helpers need a recorded use; a module without one still spells float `/` and `%`.
    @Test
    func floatDivisionAndRemainderNeedNoHelperUse() {
        #expect(spelling(emission(for: .divide, rhs: .nonInteger, helpers: [])) == "(lhs / rhs)")
        #expect(spelling(emission(for: .modulo, rhs: .nonInteger, helpers: [])) == "fmod(lhs, rhs)")
        #expect(spelling(emission(for: .divide, rhs: .integer, helpers: [.division])) == "__wgslDiv(lhs, rhs)")
        #expect(spelling(emission(for: .modulo, rhs: .integer, helpers: [.modulo])) == "__wgslMod(lhs, rhs)")
    }

    // MetalFunctionWriter.cpp:3011-3015: a vector is replaced by its element type, then `satisfies(_, Integer)` decides,
    // which looks through a reference but not through a reference to a vector.
    @Test
    func rightOperandClass() {
        var module = ShaderModule(source: SourceText(""))
        let i32 = module.types.i32Type
        let u32 = module.types.u32Type
        let abstractInt = module.types.abstractIntType
        let f32 = module.types.f32Type
        let f16 = module.types.f16Type
        let abstractFloat = module.types.abstractFloatType
        let bool = module.types.boolType
        let vec3i = module.types.vectorType(3, i32)
        let vec2u = module.types.vectorType(2, u32)
        let vec4f = module.types.vectorType(4, f32)
        let referenceToI32 = module.types.referenceType(.function, i32, .readWrite)
        let referenceToVec3i = module.types.referenceType(.function, vec3i, .readWrite)
        let mat2x2f = module.types.matrixType(2, 2, f32)

        func rhsClass(_ type: TypeID?) -> ScalarClass {
            ScalarClass(rightOperandType: type, in: module.types)
        }
        #expect(rhsClass(i32) == .integer)
        #expect(rhsClass(u32) == .integer)
        #expect(rhsClass(abstractInt) == .integer)
        #expect(rhsClass(vec3i) == .integer)
        #expect(rhsClass(vec2u) == .integer)
        #expect(rhsClass(referenceToI32) == .integer)
        #expect(rhsClass(f32) == .nonInteger)
        #expect(rhsClass(f16) == .nonInteger)
        #expect(rhsClass(abstractFloat) == .nonInteger)
        #expect(rhsClass(vec4f) == .nonInteger)
        #expect(rhsClass(bool) == .nonInteger)
        #expect(rhsClass(mat2x2f) == .nonInteger)
        #expect(rhsClass(referenceToVec3i) == .nonInteger)
        #expect(rhsClass(nil) == .nonInteger)
    }

    // The precondition of the integer helpers holds after the static passes: the type checker records `.division` or
    // `.modulo` for every division or remainder whose right operand is an integer (TypeCheck.cpp:1466-1474), including the
    // compound assignments, so emission never meets an integer `/` or `%` without its helper.
    @Test
    func theTypeCheckerRecordsEveryIntegerDivisionAndRemainder() {
        let division = file("division.wgsl")
        let results = onCompileThread { _ in
            [staticPassesResult(division), staticPassesResult(moduloSource), staticPassesResult(floatOnlySource)]
        }
        #expect(results.count == 3)
        guard results.count == 3, let divisionResult = results[0], let moduloResult = results[1], let floatResult = results[2] else {
            Issue.record("a static pass failed")
            return
        }

        func checkHelpersRecorded(_ result: StaticPassesResult, sourceLocation: SourceLocation = #_sourceLocation) {
            for division in result.divisions where division.rhs == .integer {
                let helper: UsesFlags = division.operation == .divide ? .division : .modulo
                #expect(result.uses.contains(helper), "\(division.operation)", sourceLocation: sourceLocation)
                guard result.uses.contains(helper) else {
                    continue
                }
                let expected = division.operation == .divide ? "__wgslDiv(lhs, rhs)" : "__wgslMod(lhs, rhs)"
                #expect(
                    spelling(emission(for: division.operation, rhs: division.rhs, helpers: result.uses)) == expected,
                    sourceLocation: sourceLocation
                )
            }
        }

        // testI32 and testU32 have 4 divisions each and their compound forms 3 each; testF32 4 and testF32Compound 3.
        #expect(divisionResult.divisions.filter { $0.operation == .divide && $0.rhs == .integer }.count == 14)
        #expect(divisionResult.divisions.filter { $0.operation == .divide && $0.rhs == .nonInteger }.count == 7)
        #expect(divisionResult.uses.contains(.division))
        #expect(!divisionResult.uses.contains(.modulo))
        checkHelpersRecorded(divisionResult)

        #expect(moduloResult.divisions.filter { $0.operation == .modulo && $0.rhs == .integer }.count == 8)
        #expect(moduloResult.divisions.filter { $0.operation == .modulo && $0.rhs == .nonInteger }.count == 3)
        #expect(moduloResult.uses.contains(.modulo))
        #expect(!moduloResult.uses.contains(.division))
        checkHelpersRecorded(moduloResult)

        #expect(floatResult.divisions.count == 4)
        #expect(floatResult.divisions.allSatisfy { $0.rhs == .nonInteger })
        #expect(!floatResult.uses.contains(.division))
        #expect(!floatResult.uses.contains(.modulo))
        // The constructor printer's `__wgslFtoi<T>` relies on this flag for its helper.
        #expect(floatResult.uses.contains(.ftoi))
    }
}
