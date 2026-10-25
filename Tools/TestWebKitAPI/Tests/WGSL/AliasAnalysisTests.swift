// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
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

// Unless a test says otherwise, each expected result is what the C++ compiler reported for the same source when it stopped
// after aliasAnalysis. aliasAnalysis only asks whether a call argument
// is a pointer, so PointerTyper stands in for TypeCheck, and the module goes through the other C++ passes that run
// before aliasAnalysis and do not need TypeCheck: reorderGlobals, mangleNames, rewriteEvaluationOrder, rewritePointers.

/// Types what aliasAnalysis and rewritePointers read as C++ TypeCheck does on these sources: `&x`, and identifiers that
/// name a pointer parameter or a `let` whose initializer is a pointer, get a pointer type; `*e` gets a reference type.
private struct PointerTyper: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Bool>()
    let pointerType: TypeID
    let referenceType: TypeID

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
        pointerType = self.shaderModule.types.pointerType(.function, self.shaderModule.types.i32Type, .readWrite)
        referenceType = self.shaderModule.types.referenceType(.function, self.shaderModule.types.i32Type, .readWrite)
    }

    mutating func visit(_ parameter: ParameterID) {
        visitChildren(parameter)
        var isPointer = false
        if case .elaboratedTypeExpression(let type) = shaderModule[shaderModule[parameter].typeName].kind {
            isPointer = text(shaderModule, type.base) == "ptr"
        }
        introduceVariable(shaderModule[parameter].name, isPointer)
    }

    mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        visitChildren(statement, id)
        var isPointer = false
        if let initializer = shaderModule[statement.variable].maybeInitializer {
            isPointer = shaderModule.inferredType(of: initializer) == pointerType
        }
        introduceVariable(shaderModule[statement.variable].name, isPointer)
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        if readVariable(expression.identifier) == true {
            shaderModule.setInferredType(pointerType, for: id)
        }
    }

    mutating func visit(_ unary: UnaryExpression, _ id: ExpressionID) {
        visitChildren(unary, id)
        if unary.operation == .addressOf {
            shaderModule.setInferredType(pointerType, for: id)
        } else if unary.operation == .dereference {
            shaderModule.setInferredType(referenceType, for: id)
        }
    }
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    String(decoding: module.symbols.codeUnits(of: module.symbol(of: identifier)), as: UTF16.self)
}

private func parsedAndTyped(_ source: String, reorder: Bool) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure)
    }
    if reorder, let failure = reorderGlobals(&module) {
        logCompilationError(failure)
    }
    var typer = PointerTyper(shaderModule: module)
    typer.visitShaderModule()
    return typer.shaderModule
}

/// The module aliasAnalysis gets in C++: reordered, typed by PointerTyper, mangled, evaluation-ordered and pointer-rewritten.
private func preparedModule(_ source: String) -> ShaderModule {
    var module = parsedAndTyped(source, reorder: true)
    mangleNames(&module)
    rewriteEvaluationOrder(&module)
    rewritePointers(&module)
    return module
}

private func analyzed(_ source: String) -> FailedCheck? {
    var module = preparedModule(source)
    return aliasAnalysis(&module)
}

/// White-box: aliasAnalysis straight after parsing and typing.
///
/// Without mangleNames the source names reach the pass, so its scopes and the order in which its hooks introduce and
/// read names are observable.
private func analyzedUnmangled(_ source: String) -> FailedCheck? {
    var module = parsedAndTyped(source, reorder: false)
    return aliasAnalysis(&module)
}

private func expectAliasedArgument(
    _ result: FailedCheck?,
    _ line: UInt32,
    _ lineOffset: UInt32,
    _ offset: UInt32,
    _ length: UInt32,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let result else {
        Issue.record("no error", sourceLocation: sourceLocation)
        return
    }
    #expect(result.errors.count == 1, sourceLocation: sourceLocation)
    #expect(result.warnings.isEmpty, sourceLocation: sourceLocation)
    expectMessage(result.errors.first, "invalid aliased pointer argument", sourceLocation: sourceLocation)
    #expect(
        result.errors.first?.span == SourceSpan(line: line, lineOffset: lineOffset, offset: offset, length: length),
        sourceLocation: sourceLocation
    )
}

private func expectNoError(_ result: FailedCheck?, sourceLocation: SourceLocation = #_sourceLocation) {
    if let result {
        logCompilationError(result, sourceLocation: sourceLocation)
    }
}

/// The span of the `occurrence`-th (from 0) `needle` in `source`, with 1-based lines as the lexer counts them.
private func span(of needle: String, occurrence: Int = 0, in source: String) -> SourceSpan {
    let haystack = Array(source.utf16)
    let pattern = Array(needle.utf16)
    var remaining = occurrence
    var line: UInt32 = 1
    var lineStart = 0
    var index = 0
    while index + pattern.count <= haystack.count {
        if Array(haystack[index..<index + pattern.count]) == pattern {
            if remaining == 0 {
                return SourceSpan(line: line, lineOffset: UInt32(index - lineStart), offset: UInt32(index), length: UInt32(pattern.count))
            }
            remaining -= 1
        }
        if haystack[index] == UInt16(UInt8(ascii: "\n")) {
            line += 1
            lineStart = index + 1
        }
        index += 1
    }
    Issue.record("\(needle) is not in the source")
    return .empty
}

private let readAndWrittenParameters =
    """
    fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
      *p = 1;
      _ = *q;
    }

    @compute @workgroup_size(1)
    fn main() {
      var x = 0;
      f(&x, &x);
    }
    """

@Suite
struct WGSLAliasAnalysisTests {
    @Test
    func functionHookGivesParametersLocationsAndIdentifierHookRecordsReads() {
        expectAliasedArgument(analyzed(readAndWrittenParameters), 9, 8, 137, 2)

        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              _ = *p;
              _ = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectNoError(analyzed(source))
    }

    @Test
    func assignmentHookRecordsAWriteThroughTheLeftHandSide() {
        let writtenTwice =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              *q = 2;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              var y = 0;
              f(&x, &y);
              f(&y, &x);
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(writtenTwice), 12, 8, 176, 2)

        let readThenWritten =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              _ = *p;
              *q = 1;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(readThenWritten), 9, 8, 137, 2)
    }

    @Test
    func assignmentHookDoesNotVisitTheLeftHandSide() {
        // `*q` in the index is not recorded as a read, so the C++ accepts the two pointers into `s`.
        let source =
            """
            struct S {
              a: array<i32, 2>,
              i: i32,
            }

            fn f(p: ptr<function, array<i32, 2>>, q: ptr<function, i32>) {
              (*p)[*q] = 1;
            }

            @compute @workgroup_size(1)
            fn main() {
              var s: S;
              f(&s.a, &s.i);
            }
            """
        expectNoError(analyzed(source))
    }

    @Test
    func compoundAssignmentHookWritesTheLeftAndVisitsTheRight() {
        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p += *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(source), 8, 8, 129, 2)
    }

    @Test
    func decrementIncrementHookWritesWithoutVisiting() {
        let written =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              (*p)++;
              _ = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(written), 9, 8, 137, 2)

        let indexNotRead =
            """
            struct S {
              a: array<i32, 2>,
              i: i32,
            }

            fn f(p: ptr<function, array<i32, 2>>, q: ptr<function, i32>) {
              (*p)[*q]++;
            }

            @compute @workgroup_size(1)
            fn main() {
              var s: S;
              f(&s.a, &s.i);
            }
            """
        expectNoError(analyzed(indexNotRead))
    }

    @Test
    func variableStatementHookIntroducesALocalThatShadowsAGlobal() {
        let source =
            """
            var<private> g: i32;

            fn f(p: ptr<function, i32>) {
              *p = 1;
              g = 2;
            }

            @compute @workgroup_size(1)
            fn main() {
              var g = 0;
              f(&g);
            }
            """
        expectNoError(analyzed(source))
    }

    @Test
    func variableStatementHookVisitsTheInitializer() {
        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              var y = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(source), 9, 8, 141, 2)
    }

    @Test
    func variableStatementHookIntroducesTheLocalBeforeVisitingItsInitializer() {
        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              {
                let q = *q;
              }
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        // mangleNames gives the local and the parameter different names, so the C++ sees the read of the parameter.
        expectAliasedArgument(analyzed(source), 11, 8, 151, 2)
        // White-box (AliasAnalysis.cpp:388-389): unmangled, `*q` reads the local the hook has just introduced.
        expectNoError(analyzedUnmangled(source))
    }

    @Test
    func callExpressionHookVisitsTheChildrenOfAConstructorCall() {
        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              _ = array<i32, 1>(*q);
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(source), 9, 8, 152, 2)
    }

    @Test
    func callExpressionHookVisitsTheChildrenOfABuiltinCall() {
        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              _ = max(*q, 1);
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(source), 9, 8, 145, 2)
    }

    @Test(
        arguments: [
            ("_ = atomicAdd(p, 1);", 198),
            ("_ = atomicAnd(p, 1);", 198),
            ("_ = atomicCompareExchangeWeak(p, 0, 1);", 217),
            ("_ = atomicExchange(p, 1);", 203),
            ("_ = atomicMax(p, 1);", 198),
            ("_ = atomicMin(p, 1);", 198),
            ("_ = atomicOr(p, 1);", 197),
            ("atomicStore(p, 1);", 196),
            ("_ = atomicSub(p, 1);", 198),
            ("_ = atomicXor(p, 1);", 198),
            ("_ = atomicLoad(p);", nil),
        ] as [(String, UInt32?)]
    )
    func callExpressionHookTreatsTheFirstArgumentOfAnAtomicWriteAsWritten(_ call: String, _ offset: UInt32?) {
        let source =
            """
            var<workgroup> a: atomic<i32>;

            fn f(p: ptr<workgroup, atomic<i32>>, q: ptr<workgroup, atomic<i32>>) {
              \(call)
              _ = atomicLoad(q);
            }

            @compute @workgroup_size(1)
            fn main() {
              f(&a, &a);
            }
            """
        if let offset {
            expectAliasedArgument(analyzed(source), 10, 8, offset, 2)
        } else {
            expectNoError(analyzed(source))
        }
    }

    @Test
    func callExpressionHookFindsAUserFunctionBeforeTheAtomicNames() {
        let source =
            """
            fn atomicAdd(p: ptr<function, i32>, v: i32) {
            }

            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              atomicAdd(p, 1);
              _ = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, &x);
            }
            """
        expectNoError(analyzed(source))
        expectNoError(analyzedUnmangled(source))
    }

    @Test
    func callExpressionHookPropagatesTheCalleesGlobals() {
        let source =
            """
            var<private> g: i32;

            fn w() {
              g = 1;
            }

            fn mid() {
              w();
            }

            fn f(p: ptr<private, i32>) {
              mid();
              _ = *p;
            }

            @compute @workgroup_size(1)
            fn main() {
              f(&g);
            }
            """
        expectAliasedArgument(analyzed(source), 18, 4, 159, 2)

        let readThroughACall =
            """
            var<private> g: i32;

            fn r() {
              _ = g;
            }

            fn f(p: ptr<private, i32>) {
              r();
              *p = 1;
            }

            @compute @workgroup_size(1)
            fn main() {
              f(&g);
            }
            """
        expectAliasedArgument(analyzed(readThroughACall), 14, 4, 136, 2)
    }

    @Test
    func callExpressionHookPropagatesPointerParameterUses() {
        let source =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              _ = *q;
            }

            fn g(p: ptr<function, i32>, q: ptr<function, i32>) {
              f(p, q);
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              var y = 0;
              g(&x, &y);
              g(&x, &x);
            }
            """
        expectAliasedArgument(analyzed(source), 15, 8, 230, 2)
    }

    @Test
    func callExpressionHookDoesNotVisitTheArgumentsOfAUserCall() {
        // `*q` is not recorded as a read, so the C++ accepts the aliased pointers.
        let source =
            """
            fn k(v: i32) {
            }

            fn c(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              k(*q);
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              c(&x, &x);
            }
            """
        expectNoError(analyzed(source))
    }

    @Test
    func callExpressionHookSkipsNonPointerArguments() {
        let source =
            """
            fn f(p: ptr<function, i32>, v: i32) {
              *p = 1;
              _ = v;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              f(&x, x);
            }
            """
        expectNoError(analyzed(source))
    }

    @Test
    func callExpressionHookFindsTheRootThroughIdentityIndexAndFieldAccesses() {
        let throughLet =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              _ = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              let r = &x;
              f(r, &x);
            }
            """
        expectAliasedArgument(analyzed(throughLet), 10, 7, 150, 2)

        let throughIndex =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              _ = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var a = array<i32, 2>(0, 0);
              f(&a[0], &a[1]);
            }
            """
        expectAliasedArgument(analyzed(throughIndex), 9, 11, 158, 5)

        let throughField =
            """
            struct S {
              a: array<i32, 2>,
              i: i32,
            }

            fn f(p: ptr<function, array<i32, 2>>, q: ptr<function, i32>) {
              *p = array<i32, 2>(1, 2);
              _ = *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var s: S;
              f(&s.a, &s.i);
            }
            """
        expectAliasedArgument(analyzed(throughField), 14, 10, 210, 4)
    }

    @Test
    func callExpressionHookChecksAPointerToAGlobalAgainstTheCalleesGlobals() {
        let globalWrittenParameterRead =
            """
            var<private> g: i32;

            fn f(p: ptr<private, i32>) {
              g = 1;
              _ = *p;
            }

            @compute @workgroup_size(1)
            fn main() {
              f(&g);
            }
            """
        expectAliasedArgument(analyzed(globalWrittenParameterRead), 10, 4, 117, 2)

        let globalReadParameterWritten =
            """
            var<private> g: i32;

            fn f(p: ptr<private, i32>) {
              _ = g;
              *p = 1;
            }

            @compute @workgroup_size(1)
            fn main() {
              f(&g);
            }
            """
        expectAliasedArgument(analyzed(globalReadParameterWritten), 10, 4, 117, 2)

        let bothRead =
            """
            var<private> g: i32;

            fn f(p: ptr<private, i32>) {
              _ = g;
              _ = *p;
            }

            @compute @workgroup_size(1)
            fn main() {
              f(&g);
            }
            """
        expectNoError(analyzed(bothRead))
    }

    @Test
    func theFirstErrorStopsTheAnalysis() {
        let laterFunction =
            """
            fn f(p: ptr<function, i32>, q: ptr<function, i32>) {
              *p = 1;
              *q = 2;
            }

            fn g() {
              var x = 0;
              f(&x, &x);
            }

            @compute @workgroup_size(1)
            fn main() {
              var y = 0;
              f(&y, &y);
              g();
            }
            """
        expectAliasedArgument(analyzed(laterFunction), 8, 8, 106, 2)

        let laterCall =
            """
            fn h(p: ptr<function, i32>, q: ptr<function, i32>) -> i32 {
              *p = 1;
              return *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 0;
              var y = 0;
              _ = h(&x, &x) + h(&y, &y);
            }
            """
        expectAliasedArgument(analyzed(laterCall), 10, 12, 164, 2)
    }

    @Test
    func functionHookIntroducesTheParametersInAScopeThatEndsWithTheFunction() {
        // In `k`, `p` is the global again: if `f`'s parameter were still in scope, `k` would read its own parameter instead.
        let source =
            """
            var<private> p: i32;

            fn f(p: ptr<private, i32>) {
              *p = 1;
            }

            fn k(q: ptr<private, i32>) {
              *q = 1;
              _ = p;
            }

            @compute @workgroup_size(1)
            fn main() {
              k(&p);
            }
            """
        expectAliasedArgument(analyzed(source), 14, 4, 159, 2)
        expectAliasedArgument(analyzedUnmangled(source), 14, 4, 159, 2)

        // `k`'s `r` is a new parameter: were the parameters introduced outside a scope of their own, it would be a
        // redeclaration of `f`'s `r`, and the write through it would count as a write through `q`.
        let reusedParameterName =
            """
            var<private> g: i32;

            fn f(r: ptr<private, i32>) {
              *r = 1;
            }

            fn k(q: ptr<private, i32>, r: ptr<private, i32>) {
              _ = *q;
              *r = 2;
            }

            @compute @workgroup_size(1)
            fn main() {
              k(&g, &g);
            }
            """
        expectAliasedArgument(analyzed(reusedParameterName), 14, 8, 186, 2)
        expectAliasedArgument(analyzedUnmangled(reusedParameterName), 14, 8, 186, 2)
    }

    @Test
    func functionHookVisitsTheChildrenOfTheFunctionAfterIntroducingTheParameters() {
        // White-box, not valid WGSL (C++ TypeCheck rejects it). The hook calls AST::Visitor::visit(function)
        // (AliasAnalysis.cpp:270), which visits the parameter and return types as well as the body, so `n` is a read of
        // the global in both functions; `p` is written.
        let throughParameterType =
            """
            var<private> n: i32;

            fn f(p: ptr<private, i32>, q: ptr<private, array<i32, n>>) {
              *p = 1;
            }

            fn main() {
              var a: array<i32, 4>;
              f(&n, &a);
            }
            """
        let parameterTypeResult = analyzedUnmangled(throughParameterType)
        let parameterTypeSpan = span(of: "&n", in: throughParameterType)
        expectAliasedArgument(
            parameterTypeResult,
            parameterTypeSpan.line,
            parameterTypeSpan.lineOffset,
            parameterTypeSpan.offset,
            parameterTypeSpan.length
        )

        let throughReturnType =
            """
            var<private> n: i32;

            fn f(p: ptr<private, i32>) -> array<i32, n> {
              *p = 1;
            }

            fn main() {
              f(&n);
            }
            """
        let returnTypeResult = analyzedUnmangled(throughReturnType)
        let returnTypeSpan = span(of: "&n", in: throughReturnType)
        expectAliasedArgument(
            returnTypeResult,
            returnTypeSpan.line,
            returnTypeSpan.lineOffset,
            returnTypeSpan.offset,
            returnTypeSpan.length
        )

        // A parameter shadows the global in the parameter types too: they are visited after the parameters are introduced.
        let shadowedInParameterType =
            """
            var<private> n: i32;

            fn f(p: ptr<private, i32>, n: ptr<private, array<i32, n>>) {
              *p = 1;
            }

            fn main() {
              var a: array<i32, 4>;
              f(&n, &a);
            }
            """
        expectNoError(analyzedUnmangled(shadowedInParameterType))
    }

    @Test
    func aliasAnalysisLeavesTheModuleUnchanged() {
        var module = preparedModule(readAndWrittenParameters)
        let before = ASTStringDumper.dump(module)
        _ = aliasAnalysis(&module)
        #expect(ASTStringDumper.dump(module) == before)
    }
}
