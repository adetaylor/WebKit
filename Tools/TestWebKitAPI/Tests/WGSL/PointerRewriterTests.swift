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

// Each expected text, except in the DEV_21_* tests, is what the C++ `AST::StringDumper` printed for the same source after
// rewritePointers. On these sources the C++ AST before mangleNames dumps the same
// as the parser's output and rewriteEvaluationOrder changes nothing, so parse, PointerTyper and mangleNames give the
// module that rewritePointers gets in C++.

/// Types what PointerRewriter reads as C++ TypeCheck does on these sources: `&x`, and identifiers that name a pointer
/// parameter or a `let` whose initializer is a pointer, get `ptr<function, i32>`; `*e` gets `ref<function, i32>`.
private struct PointerTyper: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Bool>()
    let pointerType: TypeID
    let referenceType: TypeID

    init(shaderModule: consuming ShaderModule, pointerType: TypeID, referenceType: TypeID) {
        self.shaderModule = shaderModule
        self.pointerType = pointerType
        self.referenceType = referenceType
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

private struct PreparedModule: ~Copyable {
    var module: ShaderModule
    let pointerType: TypeID
    let referenceType: TypeID
}

/// The module rewritePointers gets in C++: parsed, typed by PointerTyper and mangled.
private func mangledModule(_ source: String) -> PreparedModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure)
    }
    let pointerType = module.types.pointerType(.function, module.types.i32Type, .readWrite)
    let referenceType = module.types.referenceType(.function, module.types.i32Type, .readWrite)
    var typer = PointerTyper(shaderModule: module, pointerType: pointerType, referenceType: referenceType)
    typer.visitShaderModule()
    module = typer.shaderModule
    mangleNames(&module)
    return PreparedModule(module: module, pointerType: pointerType, referenceType: referenceType)
}

private func rewritten(_ source: String) -> String {
    var prepared = mangledModule(source)
    rewritePointers(&prepared.module)
    return ASTStringDumper.dump(prepared.module)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    String(decoding: module.symbols.codeUnits(of: module.symbol(of: identifier)), as: UTF16.self)
}

private func offset(of needle: String, in source: String) -> UInt32 {
    let haystack = Array(source.utf16)
    let pattern = Array(needle.utf16)
    var index = 0
    while index + pattern.count <= haystack.count {
        if Array(haystack[index..<index + pattern.count]) == pattern {
            return UInt32(index)
        }
        index += 1
    }
    Issue.record("\(needle) is not in the source")
    return UInt32.max
}

/// The last statement of the body of the module's `index`-th declaration, a function.
private func lastStatement(_ module: borrowing ShaderModule, ofFunction index: Int) -> StatementID? {
    guard case .function(let function) = module[module.declarations, index],
        case .compoundStatement(let body) = module[module[function].body].kind,
        module.count(body.statements) > 0
    else {
        return nil
    }
    return module[body.statements, module.count(body.statements) - 1]
}

/// The operands of `x = *&x + *p2 + -x`, the first assignment of the module's first function.
private func sumOperands(_ module: borrowing ShaderModule) -> [ExpressionID]? {
    guard case .function(let function) = module[module.declarations, 0],
        case .compoundStatement(let body) = module[module[function].body].kind
    else {
        return nil
    }
    for index in 0..<module.count(body.statements) {
        guard case .assignmentStatement(let assignment) = module[module[body.statements, index]].kind else {
            continue
        }
        guard case .binaryExpression(let sum) = module[assignment.rhs].kind,
            case .binaryExpression(let dereferences) = module[sum.leftExpression].kind
        else {
            return nil
        }
        return [dereferences.leftExpression, dereferences.rightExpression, sum.rightExpression]
    }
    return nil
}

@Suite
struct WGSLPointerRewriterTests {
    @Test
    func matchesTheCxxDump() {
        let source =
            """
            fn f(pp: ptr<function, i32>) -> i32 {
              let q = pp;
              return *q;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 1;
              var y: i32;
              let p = &x;
              *p = 2;
              let p2 = p;
              y = *p2 + *&x;
              _ = &y;
              _ = *p;
              let v = x;
              _ = v;
              {
                let r = &y;
                *r = 3;
                let p = 5;
                _ = p;
              }
              *p = -*p;
              if (x > 0) {
                let r = &x;
                *r = 4;
              } else {
                _ = &x;
              }
              loop {
                let s = &x;
                *s += 1;
                if (*s > 3) {
                  break;
                }
                continuing {
                  let t = &y;
                  *t = x;
                  break if *t > 5;
                }
              }
              switch x {
                case 1: {
                  let w = &y;
                  *w = 7;
                }
                default: {
                }
              }
              while (x < 3) {
                let u = &x;
                *u += 1;
              }
              _ = f(&y);
            }
            """
        let beforeRewritePointers =
            """
            fn function0(
                parameter0: ptr<function, i32>
            ) ->  i32
            {
                var local0 = parameter0;
                return *local0;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local1 = 1;
                var local2: i32;
                var local3 = &local1;
                *local3 = 2;
                var local4 = local3;
                local2 = *local4 + *&local1;
                _ = &local2;
                _ = *local3;
                var local5 = local1;
                _ = local5;
                {
                    var local6 = &local2;
                    *local6 = 3;
                    var local7 = 5;
                    _ = local7;
                }

                *local3 = -*local3;
                if local1 > 0
                {
                    var local8 = &local1;
                    *local8 = 4;
                }
                else
                {
                    _ = &local1;
                }

                var local9 = &local1;    *local9 += 1;    if *local9 > 3
                {

                }
                var local10 = &local2;    *local10 = local1;*local10 > 5
            local11    {
                    var local11 = &local2;
                    *local11 = 7;
                }
                {}

            local1 < 3    {
                    var local12 = &local1;
                    *local12 += 1;
                }

                _ = function0(&local2);
            }


            """
        let expected =
            """
            fn function0(
                parameter0: ptr<function, i32>
            ) ->  i32
            {
                return *parameter0;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local1 = 1;
                var local2: i32;
                local1 = 2;
                local2 = local1 + local1;
                _ = local1;
                var local5 = local1;
                _ = local5;
                {
                    local2 = 3;
                    var local7 = 5;
                    _ = local7;
                }

                local1 = -local1;
                if local1 > 0
                {
                    local1 = 4;
                }
                else
                {}

                local1 += 1;    if local1 > 3
                {

                }
                local2 = local1;*local10 > 5
            local11    {
                    local2 = 7;
                }
                {}

            local1 < 3    {
                    local1 += 1;
                }

                _ = function0(&local2);
            }


            """
        var prepared = mangledModule(source)
        #expect(ASTStringDumper.dump(prepared.module) == beforeRewritePointers)
        rewritePointers(&prepared.module)
        #expect(ASTStringDumper.dump(prepared.module) == expected)
    }

    @Test
    func compoundStatementAndVariableStatementHooksRemovePointerLets() {
        let source =
            """
            fn f() {
              var x = 1;
              var y: i32;
              let v = x;
              let p = &x;
              {
                let r = &y;
                *r = v;
              }
              *p = y;
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
                var local1: i32;
                var local2 = local0;
                {
                    local1 = local2;
                }

                local0 = local1;
            }


            """
        #expect(rewritten(source) == expected)
    }

    @Test
    func phonyAssignmentHookRemovesPointerDiscardsAndRewritesTheOthers() {
        let source =
            """
            fn f() {
              var x = 1;
              let p = &x;
              _ = &x;
              _ = p;
              _ = *p;
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
                _ = local0;
            }


            """
        #expect(rewritten(source) == expected)
    }

    @Test
    func loopStatementHookRewritesTheBodyAndContinuingButNotBreakIf() {
        let source =
            """
            fn f() {
              var x = 1;
              loop {
                let s = &x;
                *s += 1;
                continuing {
                  let t = &x;
                  *t = 2;
                  break if *t > 5;
                }
              }
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
                local0 += 1;    local0 = 2;*local2 > 5
            }


            """
        #expect(rewritten(source) == expected)
    }

    @Test
    func identifierExpressionHookReplacesTheInnermostPointerLet() {
        let source =
            """
            fn g(q: ptr<function, i32>) -> i32 {
              return *q;
            }

            fn f() -> i32 {
              var x = 1;
              let p = &x;
              {
                let p = 2;
                x = p;
              }
              return g(p);
            }
            """
        let expected =
            """
            fn function0(
                parameter0: ptr<function, i32>
            ) ->  i32
            {
                return *parameter0;
            }

            fn function1() ->  i32
            {
                var local0 = 1;
                {
                    var local2 = 2;
                    local0 = local2;
                }

                return function0(&local0);
            }


            """
        var prepared = mangledModule(source)
        rewritePointers(&prepared.module)
        let pointerType = prepared.pointerType
        let module = prepared.module
        #expect(ASTStringDumper.dump(module) == expected)

        guard let statement = lastStatement(module, ofFunction: 1),
            case .returnStatement(let returnStatement) = module[statement].kind,
            let value = returnStatement.maybeExpression,
            case .callExpression(let call) = module[value].kind,
            module.count(call.arguments) == 1
        else {
            Issue.record("no call of g")
            return
        }
        let argument = module[call.arguments, 0]
        guard case .identityExpression(let identity) = module[argument].kind,
            case .unaryExpression(let addressOf) = module[identity.expression].kind
        else {
            Issue.record("the argument is not an IdentityExpression of the initializer")
            return
        }
        #expect(addressOf.operation == .addressOf)
        #expect(module.span(of: argument).offset == offset(of: "p);", in: source))
        #expect(module.span(of: argument).length == 1)
        #expect(module.inferredType(of: argument) == pointerType)
    }

    @Test
    func unaryExpressionHookFoldsADereferenceOfAnAddressOf() {
        let source =
            """
            fn f(q: ptr<function, i32>) {
              var x = 1;
              let p = &x;
              let p2 = p;
              x = *&x + *p2 + -x;
              *q = x;
            }
            """
        let expected =
            """
            fn function0(
                parameter0: ptr<function, i32>
            )
            {
                var local0 = 1;
                local0 = local0 + local0 + -local0;
                *parameter0 = local0;
            }


            """
        var prepared = mangledModule(source)
        guard let operands = sumOperands(prepared.module) else {
            Issue.record("no x = *&x + *p2 + -x")
            return
        }
        let spans = operands.map { prepared.module.span(of: $0) }
        rewritePointers(&prepared.module)
        let referenceType = prepared.referenceType
        let module = prepared.module
        #expect(ASTStringDumper.dump(module) == expected)

        for (index, spelling) in ["*&x", "*p2"].enumerated() {
            let expression = operands[index]
            guard case .identityExpression(let identity) = module[expression].kind,
                case .identifierExpression(let x) = module[identity.expression].kind
            else {
                Issue.record("\(spelling) is not an IdentityExpression of x")
                continue
            }
            #expect(text(module, x.identifier) == "local0")
            #expect(spans[index].offset == offset(of: spelling, in: source))
            #expect(module.span(of: expression) == spans[index])
            #expect(module.inferredType(of: expression) == referenceType)
        }
        guard case .unaryExpression(let negate) = module[operands[2]].kind else {
            Issue.record("-x was rewritten")
            return
        }
        #expect(negate.operation == .negate)
    }

    @Test
    func forStatementHookRewritesTheBodyAndKeepsOtherClauses() {
        let source =
            """
            fn f() {
              var x = 1;
              for (var i = 0; i < 10; i++) {
                let p = &x;
                *p += i;
              }
              for (let q = 2; x < q; x++) {
                _ = &x;
              }
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
            for (    var local1 = 0;;local1 < 10;    local1++;)    {
                    local0 += local1;
                }

            for (    var local3 = 2;;local0 < local3;    local0++;)    {}

            }


            """
        #expect(rewritten(source) == expected)
    }

    // C++ removes the whole for statement here (the enclosing list's index is recorded for the clause).
    @Test
    func DEV_21_pointerLetInAForInitializerRemovesOnlyTheInitializer() {
        let source =
            """
            fn f() {
              var x = 1;
              for (let i = &x; *i < 10; x++) {
                *i += 2;
              }
              x = 2;
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
            for (;local0 < 10;    local0++;)    {
                    local0 += 2;
                }

                local0 = 2;
            }


            """
        #expect(rewritten(source) == expected)
    }

    // The C++ records the first loop's index twice and traps removing it again (DEV-21); the Swift removes only the clause.
    @Test
    func DEV_21_pointerPhonyAssignmentsInForClausesAreRemoved() {
        let source =
            """
            fn f() {
              var x = 1;
              for (_ = &x; x < 10; _ = &x) {
                x++;
              }
              for (x = 0; x < 10; _ = &x) {
                x++;
              }
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
            for (;local0 < 10;)    {
                    local0++;
                }

            for (    local0 = 0;;local0 < 10;)    {
                    local0++;
                }

            }


            """
        #expect(rewritten(source) == expected)
    }

    // The C++ drops this function's only return path (DEV-21); the Swift keeps it.
    @Test
    func DEV_21_nonVoidFunctionKeepsItsOnlyReturnPath() {
        let source =
            """
            fn f() -> i32 {
              var x = 1;
              for (let q = &x; ; ) {
                return *q;
              }
            }

            @compute @workgroup_size(1)
            fn main() {
              _ = f();
            }
            """
        let msl = onCompileThread { _ in
            var outcome = staticCheckForTesting(SourceText(source), configuration: testsConfiguration, stopAfter: .uniformityAnalysis)
            if let failure = outcome.failure {
                logCompilationError(failure)
                return ""
            }
            guard case .function(let function) = outcome.shaderModule[outcome.shaderModule.declarations, 0] else {
                Issue.record("f is not the first declaration")
                return ""
            }
            var bytes = ContiguousArray<UInt8>()
            ModuleState.withTestScope(&outcome.shaderModule) { module in
                bytes = emitStatementForTesting(module[function].body, of: function, &module, DeviceState(appleGPUFamily: 4))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        // The C++ MSL of the same function written as `for (; ; ) { return x; }`.
        let expected =
            """
            {
                int local0 = 1;
                { uint32_t __wgslEnsureForwardProgress = 0; for (;;) { if (__wgslEnsureForwardProgress == 4294967295u) break; {
                    return local0;
                }}}
            }
            """
        #expect(msl == expected)
    }
}
