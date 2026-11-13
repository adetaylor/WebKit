// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2026 Apple Inc. All rights reserved.
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

// WGSL evaluates the reference of an assignment's left hand side before it evaluates the value
// being assigned, and evaluates that reference exactly once even for a compound assignment.
// Metal inherits C++17's rules instead, where the right operand of `=` is sequenced *before* the
// left one, and where a compound assignment has to be expanded into `lhs = lhs op rhs`, which
// mentions the left hand side twice. Either difference is observable whenever an index expression
// in the assignment target calls a function that writes to memory.
//
// Both are fixed by pinning every side effecting index in an assignment target to a let declared
// immediately before the statement, which leaves the assignment itself indexing by plain values.
// The same applies to a pointer valued let, whose initializer the pointer rewriter inlines into
// each use: hoisting the indices out first keeps them from being evaluated at those uses instead.
private struct EvaluationOrderRewriter: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    var userFunctions = LookupSet<Symbol>()
    private var hoisted: [StatementID] = []
    private var hoistCount: UInt32 = 0

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func run() {
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .function(let function) = declaration {
                userFunctions.add(shaderModule.symbol(of: shaderModule[function].name))
            }
        }

        visitShaderModule()
    }

    private mutating func rewrite(_ statements: ListID<StatementID>) {
        var insertions: [(Int, [StatementID])] = []

        var index = 0
        while index < shaderModule.count(statements) {
            hoistAssignmentTarget(shaderModule[statements, index])
            // The hoisted declarations have to be taken before descending into the statement, since a
            // nested block hoists into its own list.
            if !hoisted.isEmpty {
                insertions.append((index, hoisted))
                hoisted = []
            }
            visit(shaderModule[statements, index])
            index += 1
        }

        // Inserting from the back leaves the indices of the earlier insertion points untouched.
        var i = insertions.count
        while i > 0 {
            i -= 1
            shaderModule.insertVector(statements, insertions[i].0, insertions[i].1)
        }
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        rewrite(statement.statements)
    }

    mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        rewrite(statement.body)
        if let continuing = statement.continuing {
            rewrite(continuing.body)
        }
    }

    private mutating func hoistAssignmentTarget(_ statement: StatementID) {
        switch shaderModule[statement].kind {
        case .assignmentStatement(let assignment):
            hoistIndices(assignment.lhs)
        case .compoundAssignmentStatement(let assignment):
            hoistIndices(assignment.leftExpression)
        case .variableStatement(let variableStatement):
            guard let initializer = shaderModule[variableStatement.variable].maybeInitializer,
                let type = shaderModule.inferredType(of: initializer)
            else {
                break
            }
            if shaderModule.types.getIf(Types.Pointer.self, type) != nil {
                hoistIndices(initializer)
            }
        case .forStatement(let forStatement):
            // DEV-21: PointerRewriter inlines a for initializer's pointer `let`, so hoist its indices; C++ hoists nothing here.
            if let initializer = forStatement.maybeInitializer, case .variableStatement = shaderModule[initializer].kind {
                hoistAssignmentTarget(initializer)
            }
        case .breakStatement, .callStatement, .compoundStatement, .constAssertStatement, .continueStatement,
            .decrementIncrementStatement, .discardStatement, .ifStatement, .loopStatement,
            .phonyAssignmentStatement, .returnStatement, .switchStatement, .whileStatement:
            break
        }
    }

    private mutating func hoistIndices(_ expression: ExpressionID) {
        switch shaderModule[expression].kind {
        case .identityExpression(let identity):
            hoistIndices(identity.expression)
        case .unaryExpression(let unary):
            hoistIndices(unary.expression)
        case .pointerDereferenceExpression(let dereference):
            hoistIndices(dereference.target)
        case .fieldAccessExpression(let access):
            hoistIndices(access.base)
        case .indexAccessExpression(let access):
            // The base sits to the left of the index, so anything hoisted out of it has to come first.
            hoistIndices(access.base)
            if mayHaveSideEffects(access.index) {
                hoist(access, expression)
            }
        case .abstractFloatLiteral, .abstractIntegerLiteral, .binaryExpression, .boolLiteral, .callExpression, .float32Literal,
            .float16Literal, .identifierExpression, .checkedIndexAccessExpression, .signed32Literal, .unsigned32Literal,
            .arrayTypeExpression, .elaboratedTypeExpression, .referenceTypeExpression:
            break
        }
    }

    private mutating func mayHaveSideEffects(_ expression: ExpressionID) -> Bool {
        // A const expression was already folded, so whatever it called happened at compile time.
        if shaderModule.constantValue(of: expression) != nil {
            return false
        }

        guard let type = shaderModule.inferredType(of: expression) else {
            return false
        }

        // An index is normally a plain integer. A reference or a pointer would need the hoisted let to
        // be declared with a type this pass has no way to spell, and cannot be produced by a call, so
        // leave those alone.
        if shaderModule.types.getIf(Types.Reference.self, type) != nil || shaderModule.types.getIf(Types.Pointer.self, type) != nil {
            return false
        }

        var finder = SideEffectFinder(rewriter: self)
        let found = finder.check(expression)
        self = finder.rewriter
        return found
    }

    private mutating func hoist(_ access: IndexAccessExpression, _ id: ExpressionID) {
        let index = access.index
        let name = shaderModule.symbols.intern(ReservedName.evaluationOrderTemporary(hoistCount))
        hoistCount &+= 1

        let variable = shaderModule.constructVariable(
            span: .empty,
            flavor: .let,
            name: shaderModule.makeIdentifier(name),
            qualifier: nil,
            type: nil,
            initializer: index,
            attributes: shaderModule.makeEmptyList(AttributeID.self)
        )
        hoisted.append(shaderModule.construct(span: .empty, VariableStatement(variable: variable)))

        let identifier = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(name))
        shaderModule.setInferredType(shaderModule.inferredType(of: index), for: identifier)

        let newAccess = shaderModule.construct(span: shaderModule.span(of: id), IndexAccessExpression(base: access.base, index: identifier))
        shaderModule.setInferredType(shaderModule.inferredType(of: id), for: newAccess)

        shaderModule.replace(id, with: newAccess)
    }
}

// Only a call to a user declared function or to an atomic built-in can write to memory that a
// later part of the same statement could observe. Every other call, including a type constructor
// or a built-in such as min(), is a pure computation whose position does not matter.
private struct SideEffectFinder: ASTVisitor, ~Copyable {
    /// The rewriter, moved in for one `check`: it owns the module and `userFunctions`, which the C++ visitor reaches by
    /// reference.
    var rewriter: EvaluationOrderRewriter
    var expectedError: CompilationMessage?
    var hasError = false

    private var found = false

    // lint-exempt-next-line(L-PERF-2): yields the rewriter's module in place; the finder only walks one assignment target's index.
    var shaderModule: ShaderModule {
        _read { yield rewriter.shaderModule }
        _modify { yield &rewriter.shaderModule }
    }

    init(rewriter: consuming EvaluationOrderRewriter) {
        self.rewriter = rewriter
    }

    mutating func check(_ expression: ExpressionID) -> Bool {
        visit(expression)
        return found
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        if !call.isConstructor {
            if let target = shaderModule.dynamicDowncast(IdentifierExpression.self, call.target) {
                let name = shaderModule.symbol(of: target.identifier)
                if rewriter.userFunctions.contains(name) || startsWith(shaderModule.symbols, name, atomicPrefix) {
                    found = true
                }
            }
        }
        visitChildren(call, id)
    }
}

@_spi(Testing)
public func rewriteEvaluationOrder(_ shaderModule: inout ShaderModule) {
    var rewriter = EvaluationOrderRewriter(shaderModule: shaderModule)
    rewriter.run()
    shaderModule = rewriter.shaderModule
}

private let atomicPrefix = ContiguousArray("atomic".utf16)

/// WTF `String::startsWith` on a symbol's code units.
private func startsWith(_ symbols: borrowing SymbolTable, _ symbol: Symbol, _ prefix: ContiguousArray<UInt16>) -> Bool {
    guard symbols.length(of: symbol) >= prefix.count else {
        return false
    }
    var index = 0
    while index < prefix.count {
        guard symbols.codeUnit(of: symbol, at: index) == prefix[index] else {
            return false
        }
        index += 1
    }
    return true
}
