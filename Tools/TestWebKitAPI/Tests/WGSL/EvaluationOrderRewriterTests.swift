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

// Each expected text is what the C++ `AST::StringDumper` printed for the same source after mangleNames (the module
// rewriteEvaluationOrder gets) and after rewriteEvaluationOrder.
// On these sources the C++ AST before mangleNames dumps the same as the parser's output, so parse, IndexTyper and
// mangleNames give the module that rewriteEvaluationOrder gets in C++, up to the types IndexTyper does not set.

/// Types what EvaluationOrderRewriter reads as C++ TypeCheck does on these sources.
///
/// A `var` (local or module-scope) and an index or field access are references, `&e` and a `let` initialized with a
/// pointer are pointers, `*e` is a reference, and calls, operators, `let`s and parameters are `i32`; `i32(…)` is a
/// constructor. Literals stay untyped: none of them contains a call.
private struct IndexTyper: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<TypeID>()
    let pointerType: TypeID
    let referenceType: TypeID

    init(shaderModule: consuming ShaderModule, pointerType: TypeID, referenceType: TypeID) {
        self.shaderModule = shaderModule
        self.pointerType = pointerType
        self.referenceType = referenceType
    }

    mutating func visit(_ parameter: ParameterID) {
        visitChildren(parameter)
        introduceVariable(shaderModule[parameter].name, shaderModule.types.i32Type)
    }

    mutating func visit(_ variable: VariableID) {
        visitChildren(variable)
        var type = shaderModule.types.i32Type
        if shaderModule[variable].flavor == .var {
            type = referenceType
        } else if let initializer = shaderModule[variable].maybeInitializer, shaderModule.inferredType(of: initializer) == pointerType {
            type = pointerType
        }
        introduceVariable(shaderModule[variable].name, type)
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        if let type = readVariable(expression.identifier) {
            shaderModule.setInferredType(type, for: id)
        }
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        visitChildren(call, id)
        shaderModule.setInferredType(shaderModule.types.i32Type, for: id)
        if case .identifierExpression(let target) = shaderModule[call.target].kind, text(shaderModule, target.identifier) == "i32" {
            shaderModule.modify(CallExpression.self, id) { $0.isConstructor = true }
        }
    }

    mutating func visit(_ binary: BinaryExpression, _ id: ExpressionID) {
        visitChildren(binary, id)
        shaderModule.setInferredType(shaderModule.types.i32Type, for: id)
    }

    mutating func visit(_ unary: UnaryExpression, _ id: ExpressionID) {
        visitChildren(unary, id)
        switch unary.operation {
        case .addressOf:
            shaderModule.setInferredType(pointerType, for: id)
        case .dereference:
            shaderModule.setInferredType(referenceType, for: id)
        case .complement, .negate, .not:
            shaderModule.setInferredType(shaderModule.types.i32Type, for: id)
        }
    }

    mutating func visit(_ access: IndexAccessExpression, _ id: ExpressionID) {
        visitChildren(access, id)
        shaderModule.setInferredType(referenceType, for: id)
    }

    mutating func visit(_ access: FieldAccessExpression, _ id: ExpressionID) {
        visitChildren(access, id)
        shaderModule.setInferredType(referenceType, for: id)
    }
}

/// The module rewriteEvaluationOrder gets in C++: parsed, typed by IndexTyper and mangled.
private func typedModule(_ source: String) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure)
    }
    let pointerType = module.types.pointerType(.function, module.types.i32Type, .readWrite)
    let referenceType = module.types.referenceType(.function, module.types.i32Type, .readWrite)
    var typer = IndexTyper(shaderModule: module, pointerType: pointerType, referenceType: referenceType)
    typer.visitShaderModule()
    module = typer.shaderModule
    mangleNames(&module)
    return module
}

private func expectDumps(_ source: String, _ beforeRewriteEvaluationOrder: String, _ expected: String) {
    var module = typedModule(source)
    #expect(ASTStringDumper.dump(module) == beforeRewriteEvaluationOrder)
    rewriteEvaluationOrder(&module)
    #expect(ASTStringDumper.dump(module) == expected)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    String(decoding: module.symbols.codeUnits(of: module.symbol(of: identifier)), as: UTF16.self)
}

/// The body of the module's `index`-th declaration, a function.
private func bodyStatements(_ module: borrowing ShaderModule, ofFunction index: Int) -> ListID<StatementID>? {
    guard case .function(let function) = module[module.declarations, index],
        case .compoundStatement(let body) = module[module[function].body].kind
    else {
        return nil
    }
    return body.statements
}

/// `a[f()] = 1;` in `main`, the third declaration.
private let singleAssignmentSource =
    """
    var<private> a: array<i32, 4>;

    fn f() -> i32 {
      a[1] = a[1] + 1;
      return a[1] & 3;
    }

    @compute @workgroup_size(1)
    fn main() {
      a[f()] = 1;
    }
    """

/// The statement count of `main` after rewriteEvaluationOrder, once `edit` has changed the call `f()` of
/// `singleAssignmentSource` (2 when the call is hoisted, 1 when it is not).
private func statementCount(afterEditingTheIndex edit: (inout ShaderModule, ExpressionID) -> Void) -> Int? {
    var module = typedModule(singleAssignmentSource)
    guard let statements = bodyStatements(module, ofFunction: 2),
        case .assignmentStatement(let assignment) = module[module[statements, 0]].kind,
        case .indexAccessExpression(let access) = module[assignment.lhs].kind
    else {
        Issue.record("main does not start with an indexed assignment")
        return nil
    }
    edit(&module, access.index)
    rewriteEvaluationOrder(&module)
    return module.count(statements)
}

@Suite
struct WGSLEvaluationOrderRewriterTests {
    @Test
    func matchesTheCxxDump() {
        let source =
            """
            var<private> a: array<i32, 4>;
            var<private> b: array<array<i32, 4>, 4>;
            var<workgroup> counter: atomic<u32>;

            var<private> m: array<array<vec4<i32>, 4>, 4>;

            fn f() -> i32 {
              a[0] = a[0] + 1;
              return a[0] & 3;
            }

            fn g(v: i32) -> i32 {
              return v & 3;
            }

            @compute @workgroup_size(1)
            fn main() {
              var i = 1;
              let l = 2;
              a[f()] = 1;
              a[1] = 2;
              a[i] = 3;
              a[l + 1] = 4;
              a[min(l, 3)] = 5;
              a[g(l)] += 6;
              a[i32(atomicAdd(&counter, 1u)) & 3] = 7;
              b[f()][g(1)] = 8;
              m[f()][g(2)].x = 9;
              m[g(3)][1].y = 10;
              a[a[f()]] = 11;
              a[min(f(), 3)] = 12;
              let p = &a[f()];
              *p = 13;
              let v = a[f()];
              _ = v;
              {
                a[f()] = 14;
              }
              if (i > 0) {
                a[f()] = 15;
              } else {
                b[g(i)][f()] -= 16;
              }
              loop {
                a[f()] = 17;
                if (i > 3) {
                  break;
                }
                continuing {
                  a[g(i)] = 18;
                  i++;
                  break if i > 5;
                }
              }
              for (var k = a[f()]; k < 2; a[f()] = k) {
                a[g(k)] = 19;
                k++;
              }
              while (i < 10) {
                a[f()] = 20;
                i++;
              }
              switch i {
                case 1: {
                  a[f()] = 21;
                }
                default: {
                }
              }
              a[f()]++;
              _ = a[f()];
              *&a[f()] = 22;
              (a[f()]) = 23;
            }
            """
        let beforeRewriteEvaluationOrder =
            """
            var<private,read_write> global0: array<i32, 4>;
            var<private,read_write> global1: array<array<i32, 4>, 4>;
            var<workgroup,read_write> global2: atomic<u32>;
            var<private,read_write> global3: array<array<vec4<i32>, 4>, 4>;
            fn function0() ->  i32
            {
                global0[0] = global0[0] + 1;
                return global0[0] & 3;
            }

            fn function1(
                parameter0: i32
            ) ->  i32
            {
                return parameter0 & 3;
            }

            @compute @workgroup_size(1)
            fn function2()
            {
                var local0 = 1;
                var local1 = 2;
                global0[function0()] = 1;
                global0[1] = 2;
                global0[local0] = 3;
                global0[local1 + 1] = 4;
                global0[min(local1, 3)] = 5;
                global0[function1(local1)] += 6;
                global0[i32(atomicAdd(&global2, 1u)) & 3] = 7;
                global1[function0()][function1(1)] = 8;
                global3[function0()][function1(2)].x = 9;
                global3[function1(3)][1].y = 10;
                global0[global0[function0()]] = 11;
                global0[min(function0(), 3)] = 12;
                var local2 = &global0[function0()];
                *local2 = 13;
                var local3 = global0[function0()];
                _ = local3;
                {
                    global0[function0()] = 14;
                }

                if local0 > 0
                {
                    global0[function0()] = 15;
                }
                else
                {
                    global1[function1(local0)][function0()] -= 16;
                }

                global0[function0()] = 17;    if local0 > 3
                {

                }
                global0[function1(local0)] = 18;    local0++;local0 > 5
            for (    var local4 = global0[function0()];;local4 < 2;    global0[function0()] = local4;)    {
                    global0[function1(local4)] = 19;
                    local4++;
                }

            local0 < 10    {
                    global0[function0()] = 20;
                    local0++;
                }

            local01    {
                    global0[function0()] = 21;
                }
                {}

                global0[function0()]++;
                _ = global0[function0()];
                *&global0[function0()] = 22;
                global0[function0()] = 23;
            }


            """
        let expected =
            """
            var<private,read_write> global0: array<i32, 4>;
            var<private,read_write> global1: array<array<i32, 4>, 4>;
            var<workgroup,read_write> global2: atomic<u32>;
            var<private,read_write> global3: array<array<vec4<i32>, 4>, 4>;
            fn function0() ->  i32
            {
                global0[0] = global0[0] + 1;
                return global0[0] & 3;
            }

            fn function1(
                parameter0: i32
            ) ->  i32
            {
                return parameter0 & 3;
            }

            @compute @workgroup_size(1)
            fn function2()
            {
                var local0 = 1;
                var local1 = 2;
                var __evalOrder0 = function0();
                global0[__evalOrder0] = 1;
                global0[1] = 2;
                global0[local0] = 3;
                global0[local1 + 1] = 4;
                global0[min(local1, 3)] = 5;
                var __evalOrder1 = function1(local1);
                global0[__evalOrder1] += 6;
                var __evalOrder2 = i32(atomicAdd(&global2, 1u)) & 3;
                global0[__evalOrder2] = 7;
                var __evalOrder3 = function0();
                var __evalOrder4 = function1(1);
                global1[__evalOrder3][__evalOrder4] = 8;
                var __evalOrder5 = function0();
                var __evalOrder6 = function1(2);
                global3[__evalOrder5][__evalOrder6].x = 9;
                var __evalOrder7 = function1(3);
                global3[__evalOrder7][1].y = 10;
                global0[global0[function0()]] = 11;
                var __evalOrder8 = min(function0(), 3);
                global0[__evalOrder8] = 12;
                var __evalOrder9 = function0();
                var local2 = &global0[__evalOrder9];
                *local2 = 13;
                var local3 = global0[function0()];
                _ = local3;
                {
                    var __evalOrder10 = function0();
                    global0[__evalOrder10] = 14;
                }

                if local0 > 0
                {
                    var __evalOrder11 = function0();
                    global0[__evalOrder11] = 15;
                }
                else
                {
                    var __evalOrder12 = function1(local0);
                    var __evalOrder13 = function0();
                    global1[__evalOrder12][__evalOrder13] -= 16;
                }

                var __evalOrder14 = function0();    global0[__evalOrder14] = 17;    if local0 > 3
                {

                }
                var __evalOrder15 = function1(local0);    global0[__evalOrder15] = 18;    local0++;local0 > 5
            for (    var local4 = global0[function0()];;local4 < 2;    global0[function0()] = local4;)    {
                    var __evalOrder16 = function1(local4);
                    global0[__evalOrder16] = 19;
                    local4++;
                }

            local0 < 10    {
                    var __evalOrder17 = function0();
                    global0[__evalOrder17] = 20;
                    local0++;
                }

            local01    {
                    var __evalOrder18 = function0();
                    global0[__evalOrder18] = 21;
                }
                {}

                global0[function0()]++;
                _ = global0[function0()];
                var __evalOrder19 = function0();
                *&global0[__evalOrder19] = 22;
                var __evalOrder20 = function0();
                global0[__evalOrder20] = 23;
            }


            """
        expectDumps(source, beforeRewriteEvaluationOrder, expected)
    }

    @Test
    func compoundStatementHookHoistsIntoEachBlockAndTheCountRunsAcrossFunctions() {
        let source =
            """
            var<private> a: array<i32, 4>;

            fn f() -> i32 {
              a[1] = a[1] + 1;
              return a[1] & 3;
            }

            fn h() {
              a[f()] = 1;
              {
                a[2] = 2;
                a[f()] = 3;
                {
                  a[f()] = 4;
                }
              }
              a[f()] = 5;
            }

            @compute @workgroup_size(1)
            fn main() {
              h();
              a[f()] = 6;
            }
            """
        let beforeRewriteEvaluationOrder =
            """
            var<private,read_write> global0: array<i32, 4>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            fn function1()
            {
                global0[function0()] = 1;
                {
                    global0[2] = 2;
                    global0[function0()] = 3;
                    {
                        global0[function0()] = 4;
                    }

                }

                global0[function0()] = 5;
            }

            @compute @workgroup_size(1)
            fn function2()
            {
            function1();
                global0[function0()] = 6;
            }


            """
        let expected =
            """
            var<private,read_write> global0: array<i32, 4>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            fn function1()
            {
                var __evalOrder0 = function0();
                global0[__evalOrder0] = 1;
                {
                    global0[2] = 2;
                    var __evalOrder1 = function0();
                    global0[__evalOrder1] = 3;
                    {
                        var __evalOrder2 = function0();
                        global0[__evalOrder2] = 4;
                    }

                }

                var __evalOrder3 = function0();
                global0[__evalOrder3] = 5;
            }

            @compute @workgroup_size(1)
            fn function2()
            {
            function1();
                var __evalOrder4 = function0();
                global0[__evalOrder4] = 6;
            }


            """
        expectDumps(source, beforeRewriteEvaluationOrder, expected)
    }

    @Test
    func loopStatementHookHoistsIntoTheBodyAndTheContinuing() {
        let source =
            """
            var<private> a: array<i32, 4>;

            fn f() -> i32 {
              a[1] = a[1] + 1;
              return a[1] & 3;
            }

            @compute @workgroup_size(1)
            fn main() {
              var i = 0;
              loop {
                a[f()] = 1;
                a[f()] += 2;
                continuing {
                  a[f()] = 3;
                  i++;
                  break if i > 2;
                }
              }
            }
            """
        let beforeRewriteEvaluationOrder =
            """
            var<private,read_write> global0: array<i32, 4>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local0 = 0;
                global0[function0()] = 1;    global0[function0()] += 2;    global0[function0()] = 3;    local0++;local0 > 2
            }


            """
        let expected =
            """
            var<private,read_write> global0: array<i32, 4>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local0 = 0;
                var __evalOrder0 = function0();    global0[__evalOrder0] = 1;    var __evalOrder1 = function0();    global0[__evalOrder1] += 2;    var __evalOrder2 = function0();    global0[__evalOrder2] = 3;    local0++;local0 > 2
            }


            """
        expectDumps(source, beforeRewriteEvaluationOrder, expected)
    }

    @Test
    func callExpressionHookFindsUserAndAtomicCallsAnywhereInTheIndex() {
        let source =
            """
            var<private> a: array<i32, 4>;
            var<workgroup> c: atomic<u32>;

            fn f() -> i32 {
              a[1] = a[1] + 1;
              return a[1] & 3;
            }

            @compute @workgroup_size(1)
            fn main() {
              let l = 1;
              a[min(f(), 3)] = 1;
              a[min(l, 3)] = 2;
              a[atomicLoad(&c) & 3u] = 3;
              a[i32(atomicAdd(&c, 1u)) & 3] = 4;
              a[abs(l)] = 5;
              a[max(min(l, 2), f())] = 6;
            }
            """
        let beforeRewriteEvaluationOrder =
            """
            var<private,read_write> global0: array<i32, 4>;
            var<workgroup,read_write> global1: atomic<u32>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local0 = 1;
                global0[min(function0(), 3)] = 1;
                global0[min(local0, 3)] = 2;
                global0[atomicLoad(&global1) & 3u] = 3;
                global0[i32(atomicAdd(&global1, 1u)) & 3] = 4;
                global0[abs(local0)] = 5;
                global0[max(min(local0, 2), function0())] = 6;
            }


            """
        let expected =
            """
            var<private,read_write> global0: array<i32, 4>;
            var<workgroup,read_write> global1: atomic<u32>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local0 = 1;
                var __evalOrder0 = min(function0(), 3);
                global0[__evalOrder0] = 1;
                global0[min(local0, 3)] = 2;
                var __evalOrder1 = atomicLoad(&global1) & 3u;
                global0[__evalOrder1] = 3;
                var __evalOrder2 = i32(atomicAdd(&global1, 1u)) & 3;
                global0[__evalOrder2] = 4;
                global0[abs(local0)] = 5;
                var __evalOrder3 = max(min(local0, 2), function0());
                global0[__evalOrder3] = 6;
            }


            """
        expectDumps(source, beforeRewriteEvaluationOrder, expected)
    }

    @Test
    func hoistedLetIsAReservedNameAndTheAccessIsReplacedInPlace() {
        var module = typedModule(singleAssignmentSource)
        guard let statements = bodyStatements(module, ofFunction: 2),
            case .assignmentStatement(let assignment) = module[module[statements, 0]].kind,
            case .indexAccessExpression(let access) = module[assignment.lhs].kind
        else {
            Issue.record("main does not start with an indexed assignment")
            return
        }
        let accessSpan = module.span(of: assignment.lhs)
        let accessType = module.inferredType(of: assignment.lhs)
        let indexType = module.inferredType(of: access.index)
        #expect(accessType != nil && indexType != nil)

        rewriteEvaluationOrder(&module)

        #expect(module.count(statements) == 2)
        guard case .variableStatement(let hoisted) = module[module[statements, 0]].kind,
            case .assignmentStatement(let rewritten) = module[module[statements, 1]].kind
        else {
            Issue.record("main is not `let __evalOrder0 = f(); a[__evalOrder0] = 1;`")
            return
        }
        #expect(module.span(of: module[statements, 0]) == .empty)
        let variable = module[hoisted.variable]
        #expect(variable.span == .empty)
        #expect(variable.flavor == .let)
        #expect(variable.maybeQualifier == nil)
        #expect(variable.maybeTypeName == nil)
        #expect(variable.maybeInitializer == access.index)
        #expect(module.count(variable.attributes) == 0)
        #expect(variable.role == .userDefined)
        #expect(variable.storeType == indexType)
        let name = module.symbol(of: variable.name)
        #expect(text(module, variable.name) == "__evalOrder0")
        #expect(name == module.symbols.intern(ReservedName.evaluationOrderTemporary(0)))
        #expect(module.symbols.provenance(of: name) == .reserved)

        #expect(rewritten.lhs == assignment.lhs)
        guard case .indexAccessExpression(let newAccess) = module[rewritten.lhs].kind,
            case .identifierExpression(let identifier) = module[newAccess.index].kind
        else {
            Issue.record("the assignment target is not an IndexAccessExpression indexed by an identifier")
            return
        }
        #expect(newAccess.base == access.base)
        #expect(module.span(of: rewritten.lhs) == accessSpan)
        #expect(module.inferredType(of: rewritten.lhs) == accessType)
        #expect(module.constantValue(of: rewritten.lhs) == nil)
        #expect(module.symbol(of: identifier.identifier) == name)
        #expect(identifier.identifier != variable.name)
        #expect(module.span(of: newAccess.index) == .empty)
        #expect(module.inferredType(of: newAccess.index) == indexType)
    }

    @Test
    func mayHaveSideEffectsSkipsConstantUntypedReferenceAndPointerIndices() {
        #expect(statementCount { _, _ in } == 2)
        #expect(statementCount { module, index in module.setConstantValue(.int32(1), for: index) } == 1)
        #expect(statementCount { module, index in module.setInferredType(nil, for: index) } == 1)
        #expect(
            statementCount { module, index in
                module.setInferredType(module.types.referenceType(.function, module.types.i32Type, .readWrite), for: index)
            } == 1
        )
        #expect(
            statementCount { module, index in
                module.setInferredType(module.types.pointerType(.function, module.types.i32Type, .readWrite), for: index)
            } == 1
        )
    }

    @Test
    func callExpressionHookSkipsConstructors() {
        #expect(statementCount { module, index in module.modify(CallExpression.self, index) { $0.isConstructor = true } } == 1)
    }

    @Test
    func callExpressionHookMatchesTheAtomicPrefixByCodeUnits() {
        let cases: [(String, Int)] = [
            ("atomic", 2), ("atomicStore", 2), ("atomi", 1), ("atomiC", 1), ("Atomic", 1), ("xatomic", 1), ("function1", 2),
            ("function2", 1),
        ]
        var index = 0
        while index < cases.count {
            let (name, count) = cases[index]
            let rewrittenCount = statementCount { module, call in
                guard case .callExpression(let payload) = module[call].kind,
                    case .identifierExpression(let target) = module[payload.target].kind
                else {
                    Issue.record("the index is not a call of an identifier")
                    return
                }
                module.replace(target.identifier, keepingSpanWith: module.symbols.intern(ContiguousArray(name.utf16)))
            }
            #expect(rewrittenCount == count, "\(name)")
            index += 1
        }
    }

    // C++ hoists nothing out of a for initializer, and its PointerRewriter then removes the whole for statement.
    @Test
    func DEV_21_sideEffectingIndexOfAPointerLetInAForInitializerIsHoisted() {
        let source =
            """
            var<private> a: array<i32, 4>;

            fn f() -> i32 {
              a[1] = a[1] + 1;
              return a[1] & 3;
            }

            @compute @workgroup_size(1)
            fn main() {
              var i = 0;
              for (let p = &a[f()]; *p < 10; i++) {
                *p += 1;
              }
              for (var k = a[f()]; k < 2; k++) {
              }
            }
            """
        let beforeRewriteEvaluationOrder =
            """
            var<private,read_write> global0: array<i32, 4>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local0 = 0;
            for (    var local1 = &global0[function0()];;*local1 < 10;    local0++;)    {
                    *local1 += 1;
                }

            for (    var local2 = global0[function0()];;local2 < 2;    local2++;)    {}

            }


            """
        let expected =
            """
            var<private,read_write> global0: array<i32, 4>;
            fn function0() ->  i32
            {
                global0[1] = global0[1] + 1;
                return global0[1] & 3;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local0 = 0;
                var __evalOrder0 = function0();
            for (    var local1 = &global0[__evalOrder0];;*local1 < 10;    local0++;)    {
                    *local1 += 1;
                }

            for (    var local2 = global0[function0()];;local2 < 2;    local2++;)    {}

            }


            """
        expectDumps(source, beforeRewriteEvaluationOrder, expected)
    }
}
