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

extension FunctionDefinitionWriter {
    mutating func visit(_ statement: StatementID) {
        dispatch(statement)
    }

    mutating func visit(_ assignment: AssignmentStatement, _ id: StatementID) {
        visit(assignment.lhs)
        body.append(" = ")
        guard let assignmentType = shaderModule.inferredType(of: assignment.lhs) else {
            visit(assignment.rhs)
            return
        }

        guard case .reference(let reference) = shaderModule.types[assignmentType] else {
            wgslFatal("the left-hand side of an assignment is not a reference", cppSite: "MetalFunctionWriter.cpp:3222")
        }
        visitExpression(reference.element, assignment.rhs)
    }

    mutating func visit(_ statement: CallStatement, _ id: StatementID) {
        visitCallExpression(
            shaderModule.inferredType(of: statement.call),
            shaderModule.downcast(CallExpression.self, statement.call),
            statement.call
        )
    }

    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        var serialized = false
        var needsPack = false
        var leftExpression = statement.leftExpression
        if case .identityExpression(let identity) = shaderModule[leftExpression].kind {
            leftExpression = identity.expression
        }
        if case .callExpression(let call) = shaderModule[leftExpression].kind {
            let target = call.target
            if case .identifierExpression(let identifier) = shaderModule[target].kind {
                if shaderModule.symbol(of: identifier.identifier) == shaderModule.symbols.intern(.fixed(.unpack)) {
                    serialized = true
                    let rawExpr = shaderModule[call.arguments, 0]
                    visit(rawExpr)
                    var rawType = shaderModule.inferredType(of: rawExpr)
                    if let ref = shaderModule.types.getIf(Types.Reference.self, rawType) {
                        rawType = ref.element
                    }
                    if let matrix = shaderModule.types.getIf(Types.Matrix.self, rawType) {
                        needsPack = matrix.rows == 3
                    }
                }
            }
        }
        if !serialized {
            visit(statement.leftExpression)
        }

        body.append(" = ")
        if needsPack {
            body.append("__pack(")
        }
        serializeBinaryExpression(statement.leftExpression, statement.operation, statement.rightExpression)
        if needsPack {
            body.append(")")
        }
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        body.append("{\n")
        indent.increment()
        visitStatements(statement.statements)
        indent.decrement()
        body.append(indent)
        body.append("}")
    }

    mutating func visitStatements(_ statements: ListID<StatementID>) {
        var cursor = shaderModule.cursor(statements)
        while let statement = shaderModule.next(&cursor) {
            body.append(indent)
            checkErrorAndVisit(statement)
            switch shaderModule.tag(of: statement) {
            case .assignmentStatement, .breakStatement, .callStatement, .compoundAssignmentStatement, .continueStatement,
                .decrementIncrementStatement, .discardStatement, .phonyAssignmentStatement, .returnStatement, .variableStatement:
                body.append(";")
            case .compoundStatement, .constAssertStatement, .forStatement, .ifStatement, .loopStatement, .switchStatement,
                .whileStatement:
                break
            }
            body.append("\n")
        }
    }

    mutating func visit(_ statement: DecrementIncrementStatement, _ id: StatementID) {
        visit(statement.expression)
        switch statement.operation {
        case .increment:
            body.append("++")
        case .decrement:
            body.append("--")
        }
    }

    // DEV-11: x86_64 spells discard as C++ does under CPU(X86_64), without the trailing `;`.
    mutating func visit(_ statement: DiscardStatement, _ id: StatementID) {
        #if arch(x86_64)
        body.append(MTLWorkaround.discardFragment)
        #else
        body.append("discard_fragment();")
        #endif
    }

    mutating func visit(_ statement: IfStatement, _ id: StatementID) {
        body.append("if (")
        visit(statement.test)
        body.append(") ")
        visit(shaderModule.downcast(CompoundStatement.self, statement.trueBody), statement.trueBody)
        if let falseBody = statement.maybeFalseBody {
            body.append(" else ")
            visit(falseBody)
        }
    }

    mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID) {
        body.append("(void)(")
        visit(statement.rhs)
        body.append(")")
    }

    /// The names of the fragment return structure and of its member with the `builtIn` builtin.
    mutating func returnIdentifierForFunction(_ builtIn: Builtin, _ function: FunctionID?) -> (structure: Symbol, member: Symbol)? {
        guard let function, shaderModule[function].stage == .fragment else {
            return nil
        }

        if let expression = shaderModule[function].maybeReturnType {
            if let inferredType = shaderModule.inferredType(of: expression) {
                guard let returnStruct = shaderModule.types.getIf(Types.Struct.self, inferredType) else {
                    return nil
                }

                let structure = shaderModule[returnStruct.structure]
                var members = shaderModule.cursor(structure.members)
                while let member = shaderModule.next(&members) {
                    if shaderModule[member].builtin == builtIn {
                        return (shaderModule.symbol(of: structure.name), shaderModule.symbol(of: shaderModule[member].name))
                    }
                    var attributes = shaderModule.cursor(shaderModule[member].attributes)
                    while let attribute = shaderModule.next(&attributes) {
                        let builtinAttribute = shaderModule.dynamicDowncast(BuiltinAttribute.self, attribute)
                        if let builtinAttribute, builtinAttribute.builtin == builtIn {
                            return (shaderModule.symbol(of: structure.name), shaderModule.symbol(of: shaderModule[member].name))
                        }
                    }
                }
            }
        }

        return nil
    }

    mutating func visit(_ statement: ReturnStatement, _ id: StatementID) {
        let fragDepthIdentifier = returnIdentifierForFunction(.fragDepth, currentFunction)
        let sampleMaskIdentifier = returnIdentifierForFunction(.sampleMask, currentFunction)
        if let fragDepthIdentifier {
            body.append(identifier: fragDepthIdentifier.structure, in: shaderModule.symbols)
            body.append(" __wgslFragmentReturnResult = ")
        } else if let sampleMaskIdentifier {
            body.append(identifier: sampleMaskIdentifier.structure, in: shaderModule.symbols)
            body.append(" __wgslFragmentReturnResult = ")
        } else {
            body.append("return")
        }
        if let expression = statement.maybeExpression {
            body.append(" ")
            visit(expression)
        }

        if let fragDepthIdentifier {
            body.append(";\n__wgslFragmentReturnResult.")
            body.append(identifier: fragDepthIdentifier.member, in: shaderModule.symbols)
            body.append(" = clamp(__wgslFragmentReturnResult.")
            body.append(identifier: fragDepthIdentifier.member, in: shaderModule.symbols)
            body.append(", as_type<float>(")
            body.appendDynamicOffsetsElement(.fragDepthMinimum)
            body.append("), as_type<float>(")
            body.appendDynamicOffsetsElement(.fragDepthMaximum)
            body.append("));\n")
        }
        if let sampleMaskIdentifier {
            body.append(";\n__wgslFragmentReturnResult.")
            body.append(identifier: sampleMaskIdentifier.member, in: shaderModule.symbols)
            body.append(" = (__wgslFragmentReturnResult.")
            body.append(identifier: sampleMaskIdentifier.member, in: shaderModule.symbols)
            body.append(" & ")
            body.appendDynamicOffsetsElement(.sampleMask)
            body.append(");\n")
        }
        if fragDepthIdentifier != nil || sampleMaskIdentifier != nil {
            body.append("return __wgslFragmentReturnResult")
        }
    }

    mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        // DEV-03: a nest of for statements, each the only statement of the body of the one before it (the zero-initialization of
        // a nested array, GlobalVariableRewriter.cpp:2660), is written with a loop where the C++ recurses through the bodies.
        let base = forStatementNest.count
        var current = statement
        while true {
            writeForStatementHeader(current)
            guard let nested = soleNestedForStatement(current.body) else {
                visit(shaderModule.downcast(CompoundStatement.self, current.body), current.body)
                writeForStatementTrailer(current)
                break
            }
            // visit(CompoundStatement) and visitStatements up to the nested statement.
            body.append("{\n")
            indent.increment()
            body.append(indent)
            forStatementNest.append(current)
            guard !hasError else {
                break
            }
            current = nested
        }
        while forStatementNest.count > base {
            let outer = forStatementNest.removeLast()
            body.append("\n")
            indent.decrement()
            body.append(indent)
            body.append("}")
            writeForStatementTrailer(outer)
        }
    }

    private mutating func writeForStatementHeader(_ statement: ForStatement) {
        if statement.isInternallyGenerated {
            body.append("for (")
        } else {
            body.append("{ ")
            body.append(declareForwardProgress())
            body.append(" for (")
        }

        if let initializer = statement.maybeInitializer {
            visit(initializer)
        }
        body.append(";")
        if let test = statement.maybeTest {
            body.append(" ")
            visit(test)
        }
        body.append(";")
        if let update = statement.maybeUpdate {
            body.append(" ")
            visit(update)
        }

        if statement.isInternallyGenerated {
            body.append(")")
        } else {
            body.append(") { ")
            body.append(checkForwardProgress())
            body.append(" ")
        }
    }

    private mutating func writeForStatementTrailer(_ statement: ForStatement) {
        if !statement.isInternallyGenerated {
            body.append("}")
            body.append("}")
        }
    }

    /// The for statement that is the only statement of the compound statement `body`.
    private mutating func soleNestedForStatement(_ body: StatementID) -> ForStatement? {
        let statements = shaderModule.downcast(CompoundStatement.self, body).statements
        guard shaderModule.count(statements) == 1,
            case .forStatement(let nested) = shaderModule[shaderModule[statements, 0]].kind
        else {
            return nil
        }
        return nested
    }

    mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        body.append("{ ")
        body.append(declareForwardProgress())
        body.append(" while (true) { ")
        body.append(checkForwardProgress())
        body.append(" \n")
        if statement.containsSwitch {
            body.append("bool __continuing = false;\n")
            body.append(indent)
        }
        let savedContinuing = continuing
        continuing = statement.continuing

        indent.increment()
        visitStatements(statement.body)

        if let loopContinuing = statement.continuing {
            body.append(indent)
            visit(loopContinuing)
        }
        indent.decrement()
        continuing = savedContinuing
        body.append(indent)
        body.append("}")
        body.append(indent)
        body.append("}")
    }

    mutating func visit(_ continuing: Continuing) {
        // Do not emit the same continuing for continue statements within the continuing block
        let savedContinuing = self.continuing
        self.continuing = nil
        defer { self.continuing = savedContinuing }

        body.append("{\n")
        indent.increment()
        visitStatements(continuing.body)

        if let breakIf = continuing.breakIf {
            body.append(indent)
            body.append("if (")
            visit(breakIf)
            body.append(")\n")

            indent.increment()
            body.append(indent)
            body.append("break;\n")
            indent.decrement()
        }
        indent.decrement()
        body.append(indent)
        body.append("}\n")
    }

    mutating func visit(_ statement: WhileStatement, _ id: StatementID) {
        body.append("{ ")
        body.append(declareForwardProgress())
        body.append(" while (")
        visit(statement.test)
        body.append(") { ")
        body.append(checkForwardProgress())
        body.append(" ")
        visit(shaderModule.downcast(CompoundStatement.self, statement.body), statement.body)
        body.append("}")
        body.append("}")
    }

    mutating func visit(_ statement: SwitchStatement, _ id: StatementID) {
        func visitClause(_ clauseID: SwitchClauseID, isDefault: Bool = false) {
            let clause = shaderModule[clauseID]
            var selectors = shaderModule.cursor(clause.selectors)
            while let selector = shaderModule.next(&selectors) {
                body.append("\n")
                body.append(indent)
                body.append("case ")
                visit(selector)
                body.append(":")
            }
            if isDefault {
                body.append("\n")
                body.append(indent)
                body.append("default:")
            }
            // rdar://154262212: the opaque-scope workaround is only needed when
            // shader validation is enabled; emit it selectively based on DeviceState.
            if shaderValidationEnabled() {
                body.append("\n{ ")
                body.append(MTLWorkaround.declareOpaqueScope)
                body.append("\n")
            } else {
                body.append(" ")
            }
            visit(shaderModule.downcast(CompoundStatement.self, clause.body), clause.body)

            indent.increment()
            if shaderValidationEnabled() {
                body.append("\n")
                body.append(indent)
                body.append("\n}\nbreak;")
            } else {
                body.append("\n")
                body.append(indent)
                body.append("break;")
            }
            indent.decrement()
        }

        body.append("switch (")
        visit(statement.value)
        body.append(") {")
        var clauses = shaderModule.cursor(statement.clauses)
        while let clause = shaderModule.next(&clauses) {
            visitClause(clause)
        }
        visitClause(statement.defaultClause, isDefault: true)
        body.append("\n")
        body.append(indent)
        body.append("}")
        if statement.isInsideLoop {
            body.append("\n")
            body.append(indent)
            body.append("if (__continuing) {")
            indent.increment()
            guard let continuing else {
                wgslFatal("a switch inside a loop without the loop's continuing", cppSite: "MetalFunctionWriter.cpp:3509")
            }
            visit(continuing)
            indent.decrement()
            body.append("\n")
            body.append(indent)
            body.append("}")
        } else if statement.isNestedInsideLoop {
            body.append("\n")
            body.append(indent)
            body.append("if (__continuing) {")
            indent.increment()
            body.append("\n")
            body.append(indent)
            body.append("break;")
            indent.decrement()
            body.append("\n")
            body.append(indent)
            body.append("}")
        }
    }

    mutating func visit(_ statement: BreakStatement, _ id: StatementID) {
        body.append("break")
    }

    mutating func visit(_ statement: ContinueStatement, _ id: StatementID) {
        if statement.isFromSwitchToContinuing {
            body.append("__continuing = true;\n")
            body.append(indent)
            body.append("break")
            return
        }
        if let continuing {
            visit(continuing)
            body.append(indent)
        }
        body.append("continue")
    }
}

// MARK: - Swift-only

/// The statement emitter's bytes for `statement` of `function`, for the statement tests.
///
/// The writer is in the state the function writer puts it in for `function`'s body: `function` is the current function, the
/// indentation is 0 and no continuing is in scope.
@_spi(Testing)
public func emitStatementForTesting(
    _ statement: StatementID,
    of function: FunctionID,
    _ shaderModule: inout ShaderModule,
    _ deviceState: DeviceState
) -> ContiguousArray<UInt8> {
    var writer = FunctionDefinitionWriter(
        shaderModule: shaderModule,
        stringBuilder: MSLWriter(),
        prepareResult: Reflection.EntryPointInformations(),
        constantValues: OverrideValues(),
        deviceState: deviceState
    )
    writer.currentFunction = function
    writer.visit(statement)
    let bytes = writer.body.bytes
    shaderModule = writer.shaderModule
    return bytes
}
