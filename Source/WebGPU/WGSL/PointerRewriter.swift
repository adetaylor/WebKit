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

private struct PointerRewriter: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<ExpressionID?>()

    private var currentStatementIndex = 0
    private var indicesToDelete: [Int] = []

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func run() {
        visitShaderModule()
    }

    private mutating func rewrite(_ statements: ListID<StatementID>) {
        let indexScope = currentStatementIndex
        currentStatementIndex = 0
        defer { currentStatementIndex = indexScope }
        let insertionScope = indicesToDelete
        indicesToDelete = []
        defer { indicesToDelete = insertionScope }
        let blockScope = openContextScope()
        defer { closeContextScope(blockScope) }

        var cursor = shaderModule.cursor(statements)
        while let statement = shaderModule.next(&cursor) {
            visit(statement)
            currentStatementIndex += 1
        }

        var i = indicesToDelete.count - 1
        while i >= 0 {
            shaderModule.remove(statements, indicesToDelete[i])
            i -= 1
        }
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        let blockScope = openContextScope()
        defer { closeContextScope(blockScope) }
        rewrite(statement.statements)
    }

    mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        visitChildren(statement, id)

        let variable = statement.variable
        guard let initializer = shaderModule[variable].maybeInitializer else {
            introduceVariable(shaderModule[variable].name, nil)
            return
        }

        guard shaderModule.types.getIf(Types.Pointer.self, shaderModule.inferredType(of: initializer)) != nil else {
            introduceVariable(shaderModule[variable].name, nil)
            return
        }

        introduceVariable(shaderModule[variable].name, initializer)
        indicesToDelete.append(currentStatementIndex)
    }

    mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID) {
        guard shaderModule.types.getIf(Types.Pointer.self, shaderModule.inferredType(of: statement.rhs)) != nil else {
            visitChildren(statement, id)
            return
        }
        indicesToDelete.append(currentStatementIndex)
    }

    mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        let loopScope = openContextScope()
        defer { closeContextScope(loopScope) }
        rewrite(statement.body)

        if let continuing = statement.continuing {
            let continuingScope = openContextScope()
            defer { closeContextScope(continuingScope) }
            rewrite(continuing.body)
        }
    }

    // DEV-21: a pointer `let` or phony assignment in a for clause removes that clause; C++ removes the whole for statement.
    mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        let forScope = openContextScope()
        defer { closeContextScope(forScope) }
        let removesInitializer = rewriteForClause(statement.maybeInitializer)
        maybeCheckErrorAndVisit(statement.maybeTest)
        let removesUpdate = rewriteForClause(statement.maybeUpdate)
        checkErrorAndVisitCompound(statement.body)

        guard removesInitializer || removesUpdate else {
            return
        }
        var rewritten = ForStatement(
            attributes: statement.attributes,
            maybeInitializer: removesInitializer ? nil : statement.maybeInitializer,
            maybeTest: statement.maybeTest,
            maybeUpdate: removesUpdate ? nil : statement.maybeUpdate,
            body: statement.body
        )
        rewritten.isInternallyGenerated = statement.isInternallyGenerated
        shaderModule.modify(id) { node in
            node.kind = .forStatement(rewritten)
        }
    }

    private mutating func rewriteForClause(_ clause: StatementID?) -> Bool {
        guard let clause else {
            return false
        }
        let insertionScope = indicesToDelete
        indicesToDelete = []
        defer { indicesToDelete = insertionScope }
        checkErrorAndVisit(clause)
        return !indicesToDelete.isEmpty
    }

    mutating func visit(_ identifier: IdentifierExpression, _ id: ExpressionID) {
        guard let variable = readVariable(identifier.identifier), let initializer = variable else {
            return
        }

        let identity = shaderModule.constructIdentityExpression(span: shaderModule.span(of: id), expression: initializer)
        shaderModule.replace(id, with: identity)
    }

    mutating func visit(_ unary: UnaryExpression, _ id: ExpressionID) {
        visitChildren(unary, id)

        guard unary.operation == .dereference else {
            return
        }

        var nested = unary.expression
        while case .identityExpression(let identity) = shaderModule[nested].kind {
            nested = identity.expression
        }

        guard case .unaryExpression(let nestedUnary) = shaderModule[nested].kind, nestedUnary.operation == .addressOf else {
            return
        }

        let identity = shaderModule.constructIdentityExpression(span: shaderModule.span(of: id), expression: nestedUnary.expression)
        shaderModule.setInferredType(shaderModule.inferredType(of: id), for: identity)
        shaderModule.replace(id, with: identity)
    }
}

@_spi(Testing)
public func rewritePointers(_ shaderModule: inout ShaderModule) {
    var rewriter = PointerRewriter(shaderModule: shaderModule)
    rewriter.run()
    shaderModule = rewriter.shaderModule
}
