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

extension TypeChecker {
    // Statements
    mutating func visit(_ statement: StatementID) throws(CompilationMessage) {
        switch shaderModule.tag(of: statement) {
        case .assignmentStatement:
            try visit(shaderModule.downcast(AssignmentStatement.self, statement), statement)
        case .callStatement:
            try visit(shaderModule.downcast(CallStatement.self, statement), statement)
        case .compoundAssignmentStatement:
            try visit(shaderModule.downcast(CompoundAssignmentStatement.self, statement), statement)
        case .compoundStatement:
            try visit(shaderModule.downcast(CompoundStatement.self, statement), statement)
        case .constAssertStatement:
            try visit(shaderModule.downcast(ConstAssertStatement.self, statement).assertion)
        case .decrementIncrementStatement:
            try visit(shaderModule.downcast(DecrementIncrementStatement.self, statement), statement)
        case .forStatement:
            try visit(shaderModule.downcast(ForStatement.self, statement), statement)
        case .ifStatement:
            try visit(shaderModule.downcast(IfStatement.self, statement), statement)
        case .loopStatement:
            try visit(shaderModule.downcast(LoopStatement.self, statement), statement)
        case .phonyAssignmentStatement:
            try visit(shaderModule.downcast(PhonyAssignmentStatement.self, statement), statement)
        case .returnStatement:
            try visit(shaderModule.downcast(ReturnStatement.self, statement), statement)
        case .switchStatement:
            try visit(shaderModule.downcast(SwitchStatement.self, statement), statement)
        case .variableStatement:
            try visit(shaderModule.downcast(VariableStatement.self, statement).variable)
        case .whileStatement:
            try visit(shaderModule.downcast(WhileStatement.self, statement), statement)
        case .breakStatement, .discardStatement:
            return
        case .continueStatement:
            earliestContinueOffset = cxxMin(earliestContinueOffset, shaderModule.span(of: statement).offset)
        }
    }

    mutating func visit(_ statement: AssignmentStatement, _ id: StatementID) throws(CompilationMessage) {
        let lhs = try infer(statement.lhs, .runtime)
        let rhs = try infer(statement.rhs, .runtime)

        guard let reference = shaderModule.types.getIf(Types.Reference.self, lhs) else {
            throw CompilationMessage(
                text: "cannot assign to a value of type '\(ShaderModule.typeString(lhs, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        if reference.accessMode == .read {
            throw CompilationMessage(
                text: "cannot store into a read-only type '\(ShaderModule.typeString(lhs, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        if !unify(reference.element, rhs) {
            throw CompilationMessage(
                text:
                    "cannot assign value of type '\(ShaderModule.typeString(rhs, in: &shaderModule))' to '\(ShaderModule.typeString(reference.element, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        shaderModule.setInferredType(reference.element, for: statement.rhs)
        try convertValue(shaderModule.span(of: statement.rhs), reference.element, of: statement.rhs)
    }

    mutating func visit(_ statement: CallStatement, _ id: StatementID) throws(CompilationMessage) {
        _ = try infer(statement.call, .runtime, .yes)
    }

    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) throws(CompilationMessage) {
        let left = try infer(statement.leftExpression, .runtime)
        guard let referenceType = shaderModule.types.getIf(Types.Reference.self, left) else {
            throw CompilationMessage(
                text: "cannot assign to a value of type '\(ShaderModule.typeString(left, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        try binaryExpression(shaderModule.span(of: id), nil, statement.operation, statement.leftExpression, statement.rightExpression)

        if inferredType != referenceType.element {
            guard let inferredType else {
                wgslFatal("binaryExpression inferred no type", cppSite: "TypeCheck.cpp:1020")
            }
            throw CompilationMessage(
                text:
                    "cannot assign '\(ShaderModule.typeString(inferredType, in: &shaderModule))' to '\(ShaderModule.typeString(referenceType.element, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        // Reset the inferred type since this is a statement
        inferredType = nil
        currentEvaluation = nil
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) throws(CompilationMessage) {
        let blockScope = openContextScope()
        defer { closeContextScope(blockScope) }
        try visitStatements(statement.statements)
    }

    mutating func visitStatements(_ statements: ListID<StatementID>) throws(CompilationMessage) {
        var cursor = shaderModule.cursor(statements)
        while let statement = shaderModule.next(&cursor) {
            try visit(statement)
        }
    }

    mutating func visit(_ statement: DecrementIncrementStatement, _ id: StatementID) throws(CompilationMessage) {
        let expression = try infer(statement.expression, .runtime)

        guard let reference = shaderModule.types.getIf(Types.Reference.self, expression) else {
            throw CompilationMessage(
                text: "cannot modify a value of type '\(ShaderModule.typeString(expression, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        if reference.accessMode == .read {
            throw CompilationMessage(
                text: "cannot modify read-only type '\(ShaderModule.typeString(expression, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        if !unify(shaderModule.types.i32Type, reference.element) && !unify(shaderModule.types.u32Type, reference.element) {
            let operation: StaticString
            switch statement.operation {
            case .increment:
                operation = "increment"
            case .decrement:
                operation = "decrement"
            }
            throw CompilationMessage(
                text:
                    "\(operation) can only be applied to integers, found \(ShaderModule.typeString(reference.element, in: &shaderModule))",
                span: shaderModule.span(of: id)
            )
        }
    }

    mutating func visit(_ statement: IfStatement, _ id: StatementID) throws(CompilationMessage) {
        let test = try infer(statement.test, .runtime)

        if !unify(test, shaderModule.types.boolType) {
            throw CompilationMessage(
                text: "expected 'bool', found '\(ShaderModule.typeString(test, in: &shaderModule))'",
                span: shaderModule.span(of: statement.test)
            )
        }

        try visit(shaderModule.downcast(CompoundStatement.self, statement.trueBody), statement.trueBody)
        if let falseBody = statement.maybeFalseBody {
            try visit(falseBody)
        }
    }

    mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID) throws(CompilationMessage) {
        let type = try infer(statement.rhs, .runtime)

        // https://www.w3.org/TR/WGSL/#phony-assignment-section
        // Naming a variable loads from it, so its store type has to be one the load rule accepts.
        // Textures and samplers are exempt: they are handles, and reading one never loads a value.
        if let reference = shaderModule.types.getIf(Types.Reference.self, type) {
            let element = reference.element
            if !shaderModule.isConstructible(element) && !shaderModule.isTexture(element) && !shaderModule.isSampler(element) {
                throw CompilationMessage(
                    text: "cannot assign '\(ShaderModule.typeString(element, in: &shaderModule))' to '_' because it is not constructible",
                    span: shaderModule.span(of: statement.rhs)
                )
            }
        }
    }

    mutating func visit(_ statement: ReturnStatement, _ id: StatementID) throws(CompilationMessage) {
        let type: TypeID
        let expression = statement.maybeExpression
        if let expression {
            type = try infer(expression, .runtime)
        } else {
            type = shaderModule.types.voidType
        }

        guard let returnType else {
            wgslFatal("return statement outside a function", cppSite: "TypeCheck.cpp:1108")
        }

        if !unify(returnType, type) {
            throw CompilationMessage(
                text:
                    "return statement type does not match its function return type, returned '\(ShaderModule.typeString(type, in: &shaderModule))', expected '\(ShaderModule.typeString(returnType, in: &shaderModule))'",
                span: shaderModule.span(of: id)
            )
        }

        if let expression {
            shaderModule.setInferredType(returnType, for: expression)
            try convertValue(shaderModule.span(of: expression), returnType, of: expression)
        }
    }

    mutating func visit(_ statement: ForStatement, _ id: StatementID) throws(CompilationMessage) {
        let forScope = openContextScope()
        defer { closeContextScope(forScope) }
        let savedEarliestContinueOffset = earliestContinueOffset
        earliestContinueOffset = UInt32.max
        defer { earliestContinueOffset = savedEarliestContinueOffset }

        if let initializer = statement.maybeInitializer {
            try visit(initializer)
        }

        if let test = statement.maybeTest {
            let testType = try infer(test, .runtime)
            if !unify(shaderModule.types.boolType, testType) {
                throw CompilationMessage(
                    text: "for-loop condition must be bool, got \(ShaderModule.typeString(testType, in: &shaderModule))",
                    span: shaderModule.span(of: test)
                )
            }
        }

        if let update = statement.maybeUpdate {
            try visit(update)
        }

        try visit(shaderModule.downcast(CompoundStatement.self, statement.body), statement.body)
    }

    mutating func visit(_ statement: LoopStatement, _ id: StatementID) throws(CompilationMessage) {
        let loopScope = openContextScope()
        defer { closeContextScope(loopScope) }
        try visitAttributes(statement.attributes)

        // https://www.w3.org/TR/WGSL/#continue-statement
        // A continue must not jump over the declaration of a value that the continuing clause then
        // reads, so every declaration following the earliest continue in this body gets marked and the
        // continuing clause rejects the identifiers that resolve to one of them. The offset is shadowed
        // here so that a continue inside a nested loop, which targets that loop, does not count.
        let savedEarliestContinueOffset = earliestContinueOffset
        earliestContinueOffset = UInt32.max
        defer { earliestContinueOffset = savedEarliestContinueOffset }

        var body = shaderModule.cursor(statement.body)
        while let bodyStatement = shaderModule.next(&body) {
            let savedDeclaringAfterContinue = declaringAfterContinue
            declaringAfterContinue =
                shaderModule.is(VariableStatement.self, bodyStatement)
                && shaderModule.span(of: bodyStatement).offset > earliestContinueOffset
            defer { declaringAfterContinue = savedDeclaringAfterContinue }
            try visit(bodyStatement)
        }

        if let continuing = statement.continuing {
            try visit(continuing, id)
        }
    }

    mutating func visit(_ statement: WhileStatement, _ id: StatementID) throws(CompilationMessage) {
        let savedEarliestContinueOffset = earliestContinueOffset
        earliestContinueOffset = UInt32.max
        defer { earliestContinueOffset = savedEarliestContinueOffset }

        let testType = try infer(statement.test, .runtime)
        if !unify(shaderModule.types.boolType, testType) {
            throw CompilationMessage(
                text: "while condition must be bool, got \(ShaderModule.typeString(testType, in: &shaderModule))",
                span: shaderModule.span(of: statement.test)
            )
        }

        try visit(shaderModule.downcast(CompoundStatement.self, statement.body), statement.body)
    }

    mutating func visit(_ statement: SwitchStatement, _ id: StatementID) throws(CompilationMessage) {
        var valueType = try infer(statement.value, .runtime)
        if !satisfies(valueType, .concreteInteger, shaderModule.types) {
            throw CompilationMessage(text: "switch selector must be of type i32 or u32", span: shaderModule.span(of: statement.value))
        }

        // https://www.w3.org/TR/WGSL/#switch-statement
        // No two case selectors in a switch may have the same value. A switch has few enough clauses
        // that a linear scan is cheaper than building a hash table.
        var selectorValues: [Int64] = []
        func visitClause(_ clause: SwitchClauseID) throws(CompilationMessage) {
            let clause = shaderModule[clause]
            var selectors = shaderModule.cursor(clause.selectors)
            while let selector = shaderModule.next(&selectors) {
                let selectorType = try infer(selector, .runtime)
                if let constantValue = shaderModule.constantValue(of: selector) {
                    let value = constantValue.integerValue()
                    if selectorValues.contains(value) {
                        throw CompilationMessage(
                            text: "the case selector value '\(value)' appears more than once in the switch statement",
                            span: shaderModule.span(of: selector)
                        )
                    }
                    selectorValues.append(value)
                }
                if unify(valueType, selectorType) {
                    // If the selectorType can satisfy the value type, we're good to go.
                    // e.g. valueType is i32 or u32 and the selector is a literal of type AbstractInt
                    continue
                }
                if unify(selectorType, valueType) {
                    // If the opposite is true, we have to promote valueType
                    // e.g. valueType is a constant of type AbstractInt and the selector has type i32 or u32
                    valueType = selectorType
                    continue
                }
                // Otherwise, the types are incompatible, and we have an error
                // e.g. valueType has type u32 the selector has type i32
                throw CompilationMessage(
                    text:
                        "the case selector values must have the same type as the selector expression: the selector expression has type '\(ShaderModule.typeString(valueType, in: &shaderModule))' and case selector has type '\(ShaderModule.typeString(selectorType, in: &shaderModule))'",
                    span: shaderModule.span(of: selector)
                )
            }
            try visit(shaderModule.downcast(CompoundStatement.self, clause.body), clause.body)
        }

        try visitAttributes(statement.bodyAttributes)
        try visitClause(statement.defaultClause)
        var clauses = shaderModule.cursor(statement.clauses)
        while let clause = shaderModule.next(&clauses) {
            try visitClause(clause)
        }
    }

    /// `loop` is the LoopStatement whose `continuing` this is.
    mutating func visit(_ continuing: Continuing, _ loop: StatementID) throws(CompilationMessage) {
        let continuingScope = openContextScope()
        defer { closeContextScope(continuingScope) }
        let savedInContinuingClause = inContinuingClause
        inContinuingClause = true
        defer { inContinuingClause = savedInContinuingClause }

        try visitAttributes(continuing.attributes)

        var body = shaderModule.cursor(continuing.body)
        while let statement = shaderModule.next(&body) {
            try visit(statement)
        }

        if let breakIf = continuing.breakIf {
            let type = try infer(breakIf, .runtime)
            if !unify(shaderModule.types.boolType, type) {
                throw CompilationMessage(
                    text: "expected 'bool', found \(ShaderModule.typeString(type, in: &shaderModule))",
                    span: shaderModule.span(of: breakIf)
                )
            }
        }
    }

    mutating func visitAttributes(_ attributes: ListID<AttributeID>) throws(CompilationMessage) {
        var cursor = shaderModule.cursor(attributes)
        while let attribute = shaderModule.next(&cursor) {
            try visit(attribute)
        }
    }

    mutating func analyze(_ statement: StatementID) throws(CompilationMessage) -> Behaviors {
        var behaviors = Behaviors()
        switch shaderModule.tag(of: statement) {
        case .assignmentStatement, .callStatement, .compoundAssignmentStatement, .constAssertStatement, .decrementIncrementStatement,
            .discardStatement, .phonyAssignmentStatement, .variableStatement:
            behaviors = [.next]
        case .breakStatement:
            guard let lastTarget = breakTargetStack.last else {
                throw CompilationMessage(text: "break statement must be in a loop or switch case", span: shaderModule.span(of: statement))
            }

            if case .continuing = lastTarget {
                throw CompilationMessage(
                    text: "`break` must not be used to exit from a continuing block. Use `break-if` instead",
                    span: shaderModule.span(of: statement)
                )
            }

            behaviors = [.break]
        case .returnStatement:
            if breakTargetStack.contains(where: Self.isContinuing) {
                throw CompilationMessage(
                    text: "continuing blocks must not contain a return statement",
                    span: shaderModule.span(of: statement)
                )
            }

            behaviors = [.return]
        case .continueStatement:
            var hasLoopTarget = false
            var hasSwitchTarget = false
            var i = breakTargetStack.count &- 1
            targets: while i >= 0 {
                let target = breakTargetStack[i]
                if case .switchStatement = target {
                    hasSwitchTarget = true
                    i &-= 1
                    continue
                }

                hasLoopTarget = true

                if case .continuing = target {
                    throw CompilationMessage(
                        text: "continuing blocks must not contain a continue statement",
                        span: shaderModule.span(of: statement)
                    )
                }

                if case .loopStatement(let loop) = target {
                    if hasSwitchTarget && shaderModule.downcast(LoopStatement.self, loop).continuing != nil {
                        shaderModule.modify(LoopStatement.self, loop) { $0.setContainsSwitch() }
                        shaderModule.modify(ContinueStatement.self, statement) { $0.setIsFromSwitchToContinuing() }
                        var j = i &+ 1
                        while j < breakTargetStack.count {
                            guard case .switchStatement(let switchStatement) = breakTargetStack[j] else {
                                wgslFatal("std::get of a break target that is not a switch", cppSite: "TypeCheck.cpp:2412")
                            }
                            if j == i &+ 1 {
                                shaderModule.modify(SwitchStatement.self, switchStatement) { $0.setIsInsideLoop() }
                            } else {
                                shaderModule.modify(SwitchStatement.self, switchStatement) { $0.setIsNestedInsideLoop() }
                            }
                            j &+= 1
                        }
                    }
                    break targets
                }

                assert(Self.isForOrWhile(target))
                break targets
            }

            if !hasLoopTarget {
                throw CompilationMessage(text: "continue statement must be in a loop", span: shaderModule.span(of: statement))
            }

            behaviors = [.continue]
        case .compoundStatement:
            behaviors = try analyze(shaderModule.downcast(CompoundStatement.self, statement), statement)
        case .forStatement:
            behaviors = try analyze(shaderModule.downcast(ForStatement.self, statement), statement)
        case .ifStatement:
            behaviors = try analyze(shaderModule.downcast(IfStatement.self, statement), statement)
        case .loopStatement:
            behaviors = try analyze(shaderModule.downcast(LoopStatement.self, statement), statement)
        case .switchStatement:
            behaviors = try analyze(shaderModule.downcast(SwitchStatement.self, statement), statement)
        case .whileStatement:
            behaviors = try analyze(shaderModule.downcast(WhileStatement.self, statement), statement)
        }
        shaderModule.modify(statement) { $0.setBehaviors(behaviors) }
        return behaviors
    }

    mutating func analyze(_ statement: CompoundStatement, _ id: StatementID) throws(CompilationMessage) -> Behaviors {
        let behaviors = try analyzeStatements(statement.statements)
        shaderModule.modify(id) { $0.setBehaviors(behaviors) }
        return behaviors
    }

    mutating func analyze(_ statement: ForStatement, _ id: StatementID) throws(CompilationMessage) -> Behaviors {
        var behaviors = Behaviors()
        if statement.maybeTest != nil {
            behaviors.formUnion([.next, .break])
        }

        breakTargetStack.append(.forStatement(id))
        let bodyBehaviors = try analyze(shaderModule.downcast(CompoundStatement.self, statement.body), statement.body)
        behaviors.formUnion(bodyBehaviors)
        breakTargetStack.removeLast()

        if behaviors.contains(.break) {
            behaviors.subtract([.break, .continue])
            behaviors.formUnion(.next)
        } else {
            behaviors.subtract([.next, .continue])
        }

        if behaviors.isEmpty {
            throw CompilationMessage(text: "for-loop does not exit", span: shaderModule.span(of: id))
        }

        return behaviors
    }

    mutating func analyze(_ statement: IfStatement, _ id: StatementID) throws(CompilationMessage) -> Behaviors {
        var behaviors = try analyze(shaderModule.downcast(CompoundStatement.self, statement.trueBody), statement.trueBody)
        if let elseBody = statement.maybeFalseBody {
            let elseBehaviors = try analyze(elseBody)
            behaviors.formUnion(elseBehaviors)
        } else {
            behaviors.formUnion(.next)
        }
        return behaviors
    }

    mutating func analyze(_ statement: LoopStatement, _ id: StatementID) throws(CompilationMessage) -> Behaviors {
        breakTargetStack.append(.loopStatement(id))
        var behaviors = try analyzeStatements(statement.body)
        shaderModule.modify(LoopStatement.self, id) { $0.setBodyBehaviors(behaviors) }
        if let continuing = statement.continuing {
            breakTargetStack.append(.continuing(id))
            let body = try analyzeStatements(continuing.body)
            behaviors.formUnion(body)
            breakTargetStack.removeLast()
            if continuing.breakIf != nil {
                behaviors.formUnion([.break, .continue])
            }
        }
        breakTargetStack.removeLast()
        if behaviors.contains(.break) {
            behaviors.subtract([.break, .continue])
            behaviors.formUnion(.next)
        } else {
            behaviors.subtract([.next, .continue])
        }

        if behaviors.isEmpty {
            throw CompilationMessage(text: "loop does not exit", span: shaderModule.span(of: id))
        }

        return behaviors
    }

    mutating func analyze(_ statement: SwitchStatement, _ id: StatementID) throws(CompilationMessage) -> Behaviors {
        breakTargetStack.append(.switchStatement(id))
        let defaultBody = shaderModule[statement.defaultClause].body
        var behaviors = try analyze(shaderModule.downcast(CompoundStatement.self, defaultBody), defaultBody)
        var clauses = shaderModule.cursor(statement.clauses)
        while let clause = shaderModule.next(&clauses) {
            let clauseBody = shaderModule[clause].body
            let clauseBehaviors = try analyze(shaderModule.downcast(CompoundStatement.self, clauseBody), clauseBody)
            behaviors.formUnion(clauseBehaviors)
        }
        breakTargetStack.removeLast()

        if behaviors.contains(.break) {
            behaviors.subtract(.break)
            behaviors.formUnion(.next)
        }

        return behaviors
    }

    mutating func analyze(_ statement: WhileStatement, _ id: StatementID) throws(CompilationMessage) -> Behaviors {
        var behaviors: Behaviors = [.next, .break]
        breakTargetStack.append(.whileStatement(id))
        let statementBehaviors = try analyze(shaderModule.downcast(CompoundStatement.self, statement.body), statement.body)
        behaviors.formUnion(statementBehaviors)
        breakTargetStack.removeLast()
        behaviors.subtract([.break, .continue])
        return behaviors
    }

    mutating func analyzeStatements(_ statements: ListID<StatementID>) throws(CompilationMessage) -> Behaviors {
        var behaviors: Behaviors = .next
        var cursor = shaderModule.cursor(statements)
        while let statement = shaderModule.next(&cursor) {
            let behavior = try analyze(statement)
            if behaviors.contains(.next) {
                behaviors.subtract(.next)
                behaviors.formUnion(behavior)
            }
        }
        return behaviors
    }

    private static func isContinuing(_ target: BreakTarget) -> Bool {
        if case .continuing = target {
            return true
        }
        return false
    }

    private static func isForOrWhile(_ target: BreakTarget) -> Bool {
        switch target {
        case .forStatement, .whileStatement:
            return true
        case .switchStatement, .loopStatement, .continuing:
            return false
        }
    }
}
