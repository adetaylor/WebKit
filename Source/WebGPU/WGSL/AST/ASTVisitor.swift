// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

/// C++ `AST::Visitor`.
///
/// A pass is a `~Copyable` struct that owns the module while it runs (moved in and back out by its entry function); a
/// hook "overrides" C++ `visit(AST::X&)` by implementing the requirement, and `visitChildren(…)` is the default
/// traversal (C++ `AST::Visitor::visit(x)`).
@_spi(Testing)
public protocol ASTVisitor: ~Copyable {
    var shaderModule: ShaderModule { get set }
    /// C++ `m_expectedError`; the last `setError` wins, as in release C++.
    var expectedError: CompilationMessage? { get set }
    /// Kept beside `expectedError` so the per-node check copies no message.
    var hasError: Bool { get set }

    // Shader Module
    mutating func visitShaderModule()

    // Directive
    mutating func visit(_ directive: DirectiveID)
    mutating func visit(_ directive: DiagnosticDirective, _ id: DirectiveID)

    // Diagnostic
    mutating func visit(_ diagnostic: Diagnostic)

    // Declaration
    mutating func visit(_ declaration: Declaration)
    mutating func visit(_ function: FunctionID)
    mutating func visit(_ variable: VariableID)
    mutating func visit(_ structure: StructureID)
    mutating func visit(_ alias: TypeAliasID)
    mutating func visit(_ assertion: ConstAssertID)

    // Attribute
    mutating func visit(_ attribute: AttributeID)
    mutating func visit(_ attribute: AlignAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: BindingAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: BuiltinAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: ConstAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: DiagnosticAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: GroupAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: IdAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: InterpolateAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: InvariantAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: LocationAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: MustUseAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: SizeAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: StageAttribute, _ id: AttributeID)
    mutating func visit(_ attribute: WorkgroupSizeAttribute, _ id: AttributeID)

    // Expression
    mutating func visit(_ expression: ExpressionID)
    mutating func visit(_ literal: AbstractFloatLiteral, _ id: ExpressionID)
    mutating func visit(_ literal: AbstractIntegerLiteral, _ id: ExpressionID)
    mutating func visit(_ expression: BinaryExpression, _ id: ExpressionID)
    mutating func visit(_ literal: BoolLiteral, _ id: ExpressionID)
    mutating func visit(_ expression: CallExpression, _ id: ExpressionID)
    mutating func visit(_ expression: FieldAccessExpression, _ id: ExpressionID)
    mutating func visit(_ literal: Float32Literal, _ id: ExpressionID)
    mutating func visit(_ literal: Float16Literal, _ id: ExpressionID)
    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID)
    mutating func visit(_ expression: IdentityExpression, _ id: ExpressionID)
    mutating func visit(_ expression: IndexAccessExpression, _ id: ExpressionID)
    mutating func visit(_ expression: CheckedIndexAccessExpression, _ id: ExpressionID)
    mutating func visit(_ expression: PointerDereferenceExpression, _ id: ExpressionID)
    mutating func visit(_ literal: Signed32Literal, _ id: ExpressionID)
    mutating func visit(_ expression: UnaryExpression, _ id: ExpressionID)
    mutating func visit(_ literal: Unsigned32Literal, _ id: ExpressionID)

    mutating func visit(_ parameter: ParameterID)

    mutating func visit(_ identifier: IdentifierID)

    // Statement
    mutating func visit(_ statement: StatementID)
    mutating func visit(_ statement: AssignmentStatement, _ id: StatementID)
    mutating func visit(_ statement: BreakStatement, _ id: StatementID)
    mutating func visit(_ statement: CallStatement, _ id: StatementID)
    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID)
    mutating func visit(_ statement: CompoundStatement, _ id: StatementID)
    mutating func visit(_ statement: ConstAssertStatement, _ id: StatementID)
    mutating func visit(_ statement: ContinueStatement, _ id: StatementID)
    mutating func visit(_ statement: DecrementIncrementStatement, _ id: StatementID)
    mutating func visit(_ statement: DiscardStatement, _ id: StatementID)
    mutating func visit(_ statement: ForStatement, _ id: StatementID)
    mutating func visit(_ statement: IfStatement, _ id: StatementID)
    mutating func visit(_ statement: LoopStatement, _ id: StatementID)
    mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID)
    mutating func visit(_ statement: ReturnStatement, _ id: StatementID)
    mutating func visit(_ statement: SwitchStatement, _ id: StatementID)
    mutating func visit(_ statement: VariableStatement, _ id: StatementID)
    mutating func visit(_ statement: WhileStatement, _ id: StatementID)

    mutating func visit(_ expression: ArrayTypeExpression, _ id: ExpressionID)
    mutating func visit(_ expression: ElaboratedTypeExpression, _ id: ExpressionID)
    mutating func visit(_ expression: ReferenceTypeExpression, _ id: ExpressionID)

    mutating func visit(_ member: StructureMemberID)
    mutating func visit(_ qualifier: VariableQualifier)
    mutating func visit(_ clause: SwitchClauseID)
    mutating func visit(_ continuing: Continuing)
}

// MARK: - Error channel and checked visits (ASTVisitor.h:127-153)

extension ASTVisitor where Self: ~Copyable {
    @_spi(Testing)
    public func result() -> CompilationMessage? { // lint-exempt(L-PERF-2): once per pass, after its traversal
        expectedError
    }

    /// Release C++: the `ASSERT` compiles away and a second error overwrites the first.
    @_spi(Testing)
    public mutating func setError(_ error: CompilationMessage) {
        assert(!hasError)
        expectedError = error
        hasError = true
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ directive: DirectiveID) {
        if !hasError {
            visit(directive)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ declaration: Declaration) {
        if !hasError {
            visit(declaration)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ function: FunctionID) {
        if !hasError {
            visit(function)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ variable: VariableID) {
        if !hasError {
            visit(variable)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ structure: StructureID) {
        if !hasError {
            visit(structure)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ alias: TypeAliasID) {
        if !hasError {
            visit(alias)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ assertion: ConstAssertID) {
        if !hasError {
            visit(assertion)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ attribute: AttributeID) {
        if !hasError {
            visit(attribute)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ expression: ExpressionID) {
        if !hasError {
            visit(expression)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ parameter: ParameterID) {
        if !hasError {
            visit(parameter)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ identifier: IdentifierID) {
        if !hasError {
            visit(identifier)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ statement: StatementID) {
        if !hasError {
            visit(statement)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ member: StructureMemberID) {
        if !hasError {
            visit(member)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ clause: SwitchClauseID) {
        if !hasError {
            visit(clause)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisit(_ continuing: Continuing) {
        if !hasError {
            visit(continuing)
        }
    }

    /// C++ `checkErrorAndVisit(CompoundStatement&)`: the static type is `CompoundStatement`, so the per-kind hook is called
    /// and `visit(StatementID)` is bypassed.
    @_spi(Testing)
    public mutating func checkErrorAndVisitCompound(_ statement: StatementID) {
        if !hasError {
            visitCompoundStatementPayload(statement)
        }
    }

    /// C++ `checkErrorAndVisit(CallExpression&)`: the per-kind hook, bypassing `visit(ExpressionID)`.
    @_spi(Testing)
    public mutating func checkErrorAndVisitCall(_ expression: ExpressionID) {
        if !hasError {
            visitCallExpressionPayload(expression)
        }
    }

    @_spi(Testing)
    public mutating func maybeCheckErrorAndVisit(_ expression: ExpressionID?) {
        if !hasError, let expression {
            visit(expression)
        }
    }

    @_spi(Testing)
    public mutating func maybeCheckErrorAndVisit(_ statement: StatementID?) {
        if !hasError, let statement {
            visit(statement)
        }
    }

    @_spi(Testing)
    public mutating func maybeCheckErrorAndVisit(_ qualifier: VariableQualifier?) {
        if !hasError, let qualifier {
            visit(qualifier)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisitEach(_ list: ListID<ExpressionID>) {
        var cursor = shaderModule.cursor(list)
        while !cursor.isAtEnd {
            let expression = shaderModule.advance(&cursor)
            checkErrorAndVisit(expression)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisitEach(_ list: ListID<StatementID>) {
        var cursor = shaderModule.cursor(list)
        while !cursor.isAtEnd {
            let statement = shaderModule.advance(&cursor)
            checkErrorAndVisit(statement)
        }
    }

    @_spi(Testing)
    public mutating func checkErrorAndVisitEach(_ list: ListID<AttributeID>) {
        var cursor = shaderModule.cursor(list)
        while !cursor.isAtEnd {
            let attribute = shaderModule.advance(&cursor)
            checkErrorAndVisit(attribute)
        }
    }
}

// MARK: - Default traversal (ASTVisitor.cpp)

extension ASTVisitor where Self: ~Copyable {
    // Shader Module

    @_spi(Testing)
    public mutating func visitShaderModule() {
        visitShaderModuleChildren()
    }

    @_spi(Testing)
    public mutating func visitShaderModuleChildren() {
        var directives = shaderModule.cursor(shaderModule.directives)
        while !directives.isAtEnd {
            let directive = shaderModule.advance(&directives)
            checkErrorAndVisit(directive)
        }
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while !declarations.isAtEnd {
            let declaration = shaderModule.advance(&declarations)
            checkErrorAndVisit(declaration)
        }
    }

    // Directive

    @_spi(Testing)
    public mutating func visit(_ directive: DirectiveID) {
        dispatch(directive)
    }

    /// C++ `Visitor::visit(AST::Directive&)`.
    @_spi(Testing)
    public mutating func dispatch(_ directive: DirectiveID) {
        switch shaderModule[directive].kind {
        case .diagnosticDirective(let node):
            if !hasError {
                visit(node, directive)
            }
        }
    }

    @_spi(Testing)
    public mutating func visit(_ directive: DiagnosticDirective, _ id: DirectiveID) {
        visitChildren(directive, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ directive: DiagnosticDirective, _ id: DirectiveID) {
        visit(directive.diagnostic)
    }

    // Diagnostic

    @_spi(Testing)
    public mutating func visit(_ diagnostic: Diagnostic) {
    }

    // Declarations

    @_spi(Testing)
    public mutating func visit(_ declaration: Declaration) {
        dispatch(declaration)
    }

    /// C++ `Visitor::visit(AST::Declaration&)`.
    @_spi(Testing)
    @inline(never)
    public mutating func dispatch(_ declaration: Declaration) {
        guard !hasError else {
            return
        }
        switch declaration {
        case .function(let function):
            visit(function)
        case .variable(let variable):
            visit(variable)
        case .structure(let structure):
            visit(structure)
        case .typeAlias(let alias):
            visit(alias)
        case .constAssert(let assertion):
            visit(assertion)
        }
    }

    @_spi(Testing)
    public mutating func visit(_ alias: TypeAliasID) {
        visitChildren(alias)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ alias: TypeAliasID) {
        visit(shaderModule[alias].type)
    }

    @_spi(Testing)
    public mutating func visit(_ assertion: ConstAssertID) {
        visitChildren(assertion)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ assertion: ConstAssertID) {
        visit(shaderModule[assertion].test)
    }

    // Attribute

    @_spi(Testing)
    public mutating func visit(_ attribute: AttributeID) {
        dispatch(attribute)
    }

    /// C++ `Visitor::visit(AST::Attribute&)`.
    @_spi(Testing)
    @inline(never)
    public mutating func dispatch(_ attribute: AttributeID) {
        guard !hasError else {
            return
        }
        switch shaderModule[attribute].kind {
        case .alignAttribute(let node):
            visit(node, attribute)
        case .bindingAttribute(let node):
            visit(node, attribute)
        case .builtinAttribute(let node):
            visit(node, attribute)
        case .constAttribute(let node):
            visit(node, attribute)
        case .diagnosticAttribute(let node):
            visit(node, attribute)
        case .groupAttribute(let node):
            visit(node, attribute)
        case .idAttribute(let node):
            visit(node, attribute)
        case .interpolateAttribute(let node):
            visit(node, attribute)
        case .invariantAttribute(let node):
            visit(node, attribute)
        case .locationAttribute(let node):
            visit(node, attribute)
        case .mustUseAttribute(let node):
            visit(node, attribute)
        case .sizeAttribute(let node):
            visit(node, attribute)
        case .stageAttribute(let node):
            visit(node, attribute)
        case .workgroupSizeAttribute(let node):
            visit(node, attribute)
        }
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: AlignAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: AlignAttribute, _ id: AttributeID) {
        visit(attribute.alignment)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: BindingAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: BindingAttribute, _ id: AttributeID) {
        visit(attribute.binding)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: ConstAttribute, _ id: AttributeID) {
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: DiagnosticAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: DiagnosticAttribute, _ id: AttributeID) {
        visit(attribute.diagnostic)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: BuiltinAttribute, _ id: AttributeID) {
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: GroupAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: GroupAttribute, _ id: AttributeID) {
        visit(attribute.group)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: IdAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: IdAttribute, _ id: AttributeID) {
        visit(attribute.value)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: InterpolateAttribute, _ id: AttributeID) {
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: InvariantAttribute, _ id: AttributeID) {
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: LocationAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: LocationAttribute, _ id: AttributeID) {
        visit(attribute.location)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: MustUseAttribute, _ id: AttributeID) {
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: SizeAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: SizeAttribute, _ id: AttributeID) {
        visit(attribute.size)
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: StageAttribute, _ id: AttributeID) {
    }

    @_spi(Testing)
    public mutating func visit(_ attribute: WorkgroupSizeAttribute, _ id: AttributeID) {
        visitChildren(attribute, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ attribute: WorkgroupSizeAttribute, _ id: AttributeID) {
        checkErrorAndVisit(attribute.x)
        maybeCheckErrorAndVisit(attribute.maybeY)
        maybeCheckErrorAndVisit(attribute.maybeZ)
    }

    // Expression

    @_spi(Testing)
    public mutating func visit(_ expression: ExpressionID) {
        dispatch(expression)
    }

    /// C++ `Visitor::visit(AST::Expression&)`.
    ///
    /// Switches on the one-byte tag and calls one trampoline per kind, so the frame binds no payload; never reentrant
    /// (it does not call `visit(ExpressionID)`).
    @_spi(Testing)
    @inline(never)
    public mutating func dispatch(_ expression: ExpressionID) {
        guard !hasError else {
            return
        }
        switch shaderModule.tag(of: expression) {
        case .abstractFloatLiteral:
            visitAbstractFloatLiteralPayload(expression)
        case .abstractIntegerLiteral:
            visitAbstractIntegerLiteralPayload(expression)
        case .binaryExpression:
            visitBinaryExpressionPayload(expression)
        case .boolLiteral:
            visitBoolLiteralPayload(expression)
        case .callExpression:
            visitCallExpressionPayload(expression)
        case .fieldAccessExpression:
            visitFieldAccessExpressionPayload(expression)
        case .float32Literal:
            visitFloat32LiteralPayload(expression)
        case .float16Literal:
            visitFloat16LiteralPayload(expression)
        case .identifierExpression:
            visitIdentifierExpressionPayload(expression)
        case .identityExpression:
            visitIdentityExpressionPayload(expression)
        case .indexAccessExpression:
            visitIndexAccessExpressionPayload(expression)
        case .checkedIndexAccessExpression:
            visitCheckedIndexAccessExpressionPayload(expression)
        case .signed32Literal:
            visitSigned32LiteralPayload(expression)
        case .unaryExpression:
            visitUnaryExpressionPayload(expression)
        case .unsigned32Literal:
            visitUnsigned32LiteralPayload(expression)
        case .arrayTypeExpression:
            visitArrayTypeExpressionPayload(expression)
        case .elaboratedTypeExpression:
            visitElaboratedTypeExpressionPayload(expression)
        case .referenceTypeExpression:
            visitReferenceTypeExpressionPayload(expression)
        case .pointerDereferenceExpression:
            assertionFailure("Unhandled Expression")
        }
    }

    private mutating func visitAbstractFloatLiteralPayload(_ id: ExpressionID) {
        guard case .abstractFloatLiteral(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:239")
        }
        visit(node, id)
    }

    private mutating func visitAbstractIntegerLiteralPayload(_ id: ExpressionID) {
        guard case .abstractIntegerLiteral(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:242")
        }
        visit(node, id)
    }

    private mutating func visitBinaryExpressionPayload(_ id: ExpressionID) {
        guard case .binaryExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:245")
        }
        visit(node, id)
    }

    private mutating func visitBoolLiteralPayload(_ id: ExpressionID) {
        guard case .boolLiteral(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:248")
        }
        visit(node, id)
    }

    private mutating func visitCallExpressionPayload(_ id: ExpressionID) {
        guard case .callExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:251")
        }
        visit(node, id)
    }

    private mutating func visitFieldAccessExpressionPayload(_ id: ExpressionID) {
        guard case .fieldAccessExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:254")
        }
        visit(node, id)
    }

    private mutating func visitFloat32LiteralPayload(_ id: ExpressionID) {
        guard case .float32Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:257")
        }
        visit(node, id)
    }

    private mutating func visitFloat16LiteralPayload(_ id: ExpressionID) {
        guard case .float16Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:260")
        }
        visit(node, id)
    }

    private mutating func visitIdentifierExpressionPayload(_ id: ExpressionID) {
        guard case .identifierExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:263")
        }
        visit(node, id)
    }

    private mutating func visitIdentityExpressionPayload(_ id: ExpressionID) {
        guard case .identityExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:266")
        }
        visit(node, id)
    }

    private mutating func visitIndexAccessExpressionPayload(_ id: ExpressionID) {
        guard case .indexAccessExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:269")
        }
        visit(node, id)
    }

    private mutating func visitCheckedIndexAccessExpressionPayload(_ id: ExpressionID) {
        guard case .checkedIndexAccessExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:269")
        }
        visit(node, id)
    }

    private mutating func visitSigned32LiteralPayload(_ id: ExpressionID) {
        guard case .signed32Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:272")
        }
        visit(node, id)
    }

    private mutating func visitUnaryExpressionPayload(_ id: ExpressionID) {
        guard case .unaryExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:275")
        }
        visit(node, id)
    }

    private mutating func visitUnsigned32LiteralPayload(_ id: ExpressionID) {
        guard case .unsigned32Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:278")
        }
        visit(node, id)
    }

    private mutating func visitArrayTypeExpressionPayload(_ id: ExpressionID) {
        guard case .arrayTypeExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:281")
        }
        visit(node, id)
    }

    private mutating func visitElaboratedTypeExpressionPayload(_ id: ExpressionID) {
        guard case .elaboratedTypeExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:284")
        }
        visit(node, id)
    }

    private mutating func visitReferenceTypeExpressionPayload(_ id: ExpressionID) {
        guard case .referenceTypeExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:287")
        }
        visit(node, id)
    }

    @_spi(Testing)
    public mutating func visit(_ literal: AbstractFloatLiteral, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ literal: AbstractIntegerLiteral, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ expression: BinaryExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: BinaryExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.leftExpression)
        checkErrorAndVisit(expression.rightExpression)
    }

    @_spi(Testing)
    public mutating func visit(_ literal: BoolLiteral, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ expression: CallExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: CallExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.target)
        checkErrorAndVisitEach(expression.arguments)
    }

    @_spi(Testing)
    public mutating func visit(_ expression: FieldAccessExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: FieldAccessExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.base)
    }

    @_spi(Testing)
    public mutating func visit(_ literal: Float32Literal, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ literal: Float16Literal, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: IdentifierExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.identifier)
    }

    @_spi(Testing)
    public mutating func visit(_ expression: IndexAccessExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: IndexAccessExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.base)
        checkErrorAndVisit(expression.index)
    }

    @_spi(Testing)
    public mutating func visit(_ expression: CheckedIndexAccessExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: CheckedIndexAccessExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.base)
        checkErrorAndVisit(expression.index)
    }

    @_spi(Testing)
    public mutating func visit(_ expression: PointerDereferenceExpression, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ literal: Signed32Literal, _ id: ExpressionID) {
    }

    @_spi(Testing)
    public mutating func visit(_ expression: UnaryExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: UnaryExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.expression)
    }

    @_spi(Testing)
    public mutating func visit(_ literal: Unsigned32Literal, _ id: ExpressionID) {
    }

    // Function

    @_spi(Testing)
    public mutating func visit(_ function: FunctionID) {
        visitChildren(function)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ function: FunctionID) {
        let node = shaderModule[function]
        checkErrorAndVisitEach(node.attributes)
        var parameters = shaderModule.cursor(node.parameters)
        while !parameters.isAtEnd {
            let parameter = shaderModule.advance(&parameters)
            checkErrorAndVisit(parameter)
        }
        checkErrorAndVisitEach(node.returnAttributes)
        maybeCheckErrorAndVisit(node.maybeReturnType)
        checkErrorAndVisitCompound(node.body)
    }

    @_spi(Testing)
    public mutating func visit(_ parameter: ParameterID) {
        visitChildren(parameter)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ parameter: ParameterID) {
        let node = shaderModule[parameter]
        checkErrorAndVisitEach(node.attributes)
        checkErrorAndVisit(node.typeName)
    }

    // Identifier

    @_spi(Testing)
    public mutating func visit(_ identifier: IdentifierID) {
    }

    @_spi(Testing)
    public mutating func visit(_ expression: IdentityExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: IdentityExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.expression)
    }

    // Statement

    @_spi(Testing)
    public mutating func visit(_ statement: StatementID) {
        dispatch(statement)
    }

    /// C++ `Visitor::visit(AST::Statement&)`, trampolined like `dispatch(ExpressionID)`.
    @_spi(Testing)
    @inline(never)
    public mutating func dispatch(_ statement: StatementID) {
        guard !hasError else {
            return
        }
        switch shaderModule.tag(of: statement) {
        case .assignmentStatement:
            visitAssignmentStatementPayload(statement)
        case .breakStatement:
            visitBreakStatementPayload(statement)
        case .callStatement:
            visitCallStatementPayload(statement)
        case .compoundAssignmentStatement:
            visitCompoundAssignmentStatementPayload(statement)
        case .compoundStatement:
            visitCompoundStatementPayload(statement)
        case .constAssertStatement:
            visitConstAssertStatementPayload(statement)
        case .continueStatement:
            visitContinueStatementPayload(statement)
        case .decrementIncrementStatement:
            visitDecrementIncrementStatementPayload(statement)
        case .discardStatement:
            visitDiscardStatementPayload(statement)
        case .forStatement:
            visitForStatementPayload(statement)
        case .ifStatement:
            visitIfStatementPayload(statement)
        case .loopStatement:
            visitLoopStatementPayload(statement)
        case .phonyAssignmentStatement:
            visitPhonyAssignmentStatementPayload(statement)
        case .returnStatement:
            visitReturnStatementPayload(statement)
        case .switchStatement:
            visitSwitchStatementPayload(statement)
        case .variableStatement:
            visitVariableStatementPayload(statement)
        case .whileStatement:
            visitWhileStatementPayload(statement)
        }
    }

    private mutating func visitAssignmentStatementPayload(_ id: StatementID) {
        guard case .assignmentStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:398")
        }
        visit(node, id)
    }

    private mutating func visitBreakStatementPayload(_ id: StatementID) {
        guard case .breakStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:401")
        }
        visit(node, id)
    }

    private mutating func visitCallStatementPayload(_ id: StatementID) {
        guard case .callStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:404")
        }
        visit(node, id)
    }

    private mutating func visitCompoundAssignmentStatementPayload(_ id: StatementID) {
        guard case .compoundAssignmentStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:407")
        }
        visit(node, id)
    }

    private mutating func visitCompoundStatementPayload(_ id: StatementID) {
        guard case .compoundStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:410")
        }
        visit(node, id)
    }

    private mutating func visitConstAssertStatementPayload(_ id: StatementID) {
        guard case .constAssertStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:413")
        }
        visit(node, id)
    }

    private mutating func visitContinueStatementPayload(_ id: StatementID) {
        guard case .continueStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:416")
        }
        visit(node, id)
    }

    private mutating func visitDecrementIncrementStatementPayload(_ id: StatementID) {
        guard case .decrementIncrementStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:419")
        }
        visit(node, id)
    }

    private mutating func visitDiscardStatementPayload(_ id: StatementID) {
        guard case .discardStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:422")
        }
        visit(node, id)
    }

    private mutating func visitForStatementPayload(_ id: StatementID) {
        guard case .forStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:425")
        }
        visit(node, id)
    }

    private mutating func visitIfStatementPayload(_ id: StatementID) {
        guard case .ifStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:428")
        }
        visit(node, id)
    }

    private mutating func visitLoopStatementPayload(_ id: StatementID) {
        guard case .loopStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:431")
        }
        visit(node, id)
    }

    private mutating func visitPhonyAssignmentStatementPayload(_ id: StatementID) {
        guard case .phonyAssignmentStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:434")
        }
        visit(node, id)
    }

    private mutating func visitReturnStatementPayload(_ id: StatementID) {
        guard case .returnStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:437")
        }
        visit(node, id)
    }

    private mutating func visitSwitchStatementPayload(_ id: StatementID) {
        guard case .switchStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:440")
        }
        visit(node, id)
    }

    private mutating func visitVariableStatementPayload(_ id: StatementID) {
        guard case .variableStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:443")
        }
        visit(node, id)
    }

    private mutating func visitWhileStatementPayload(_ id: StatementID) {
        guard case .whileStatement(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:446")
        }
        visit(node, id)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: AssignmentStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: AssignmentStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.lhs)
        checkErrorAndVisit(statement.rhs)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: BreakStatement, _ id: StatementID) {
    }

    @_spi(Testing)
    public mutating func visit(_ statement: CallStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: CallStatement, _ id: StatementID) {
        checkErrorAndVisitCall(statement.call)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.leftExpression)
        checkErrorAndVisit(statement.rightExpression)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: CompoundStatement, _ id: StatementID) {
        checkErrorAndVisitEach(statement.statements)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: ConstAssertStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: ConstAssertStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.assertion)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: ContinueStatement, _ id: StatementID) {
    }

    @_spi(Testing)
    public mutating func visit(_ statement: DecrementIncrementStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: DecrementIncrementStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.expression)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: DiscardStatement, _ id: StatementID) {
    }

    @_spi(Testing)
    public mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: ForStatement, _ id: StatementID) {
        maybeCheckErrorAndVisit(statement.maybeInitializer)
        maybeCheckErrorAndVisit(statement.maybeTest)
        maybeCheckErrorAndVisit(statement.maybeUpdate)
        checkErrorAndVisitCompound(statement.body)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: IfStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: IfStatement, _ id: StatementID) {
        checkErrorAndVisitEach(statement.attributes)
        checkErrorAndVisit(statement.test)
        checkErrorAndVisitCompound(statement.trueBody)
        maybeCheckErrorAndVisit(statement.maybeFalseBody)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: LoopStatement, _ id: StatementID) {
        checkErrorAndVisitEach(statement.attributes)
        checkErrorAndVisitEach(statement.body)
        if let continuing = statement.continuing {
            checkErrorAndVisit(continuing)
        }
    }

    @_spi(Testing)
    public mutating func visit(_ continuing: Continuing) {
        visitChildren(continuing)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ continuing: Continuing) {
        checkErrorAndVisitEach(continuing.body)
        checkErrorAndVisitEach(continuing.attributes)
        maybeCheckErrorAndVisit(continuing.breakIf)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: PhonyAssignmentStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.rhs)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: ReturnStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: ReturnStatement, _ id: StatementID) {
        maybeCheckErrorAndVisit(statement.maybeExpression)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: SwitchStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: SwitchStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.value)
        checkErrorAndVisitEach(statement.bodyAttributes)
        var clauses = shaderModule.cursor(statement.clauses)
        while !clauses.isAtEnd {
            let clause = shaderModule.advance(&clauses)
            checkErrorAndVisit(clause)
        }
        checkErrorAndVisit(statement.defaultClause)
    }

    @_spi(Testing)
    public mutating func visit(_ clause: SwitchClauseID) {
        visitChildren(clause)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ clause: SwitchClauseID) {
        let node = shaderModule[clause]
        checkErrorAndVisitEach(node.selectors)
        checkErrorAndVisitCompound(node.body)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: VariableStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.variable)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: WhileStatement, _ id: StatementID) {
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ statement: WhileStatement, _ id: StatementID) {
        checkErrorAndVisit(statement.test)
        checkErrorAndVisitCompound(statement.body)
    }

    // Structure

    @_spi(Testing)
    public mutating func visit(_ structure: StructureID) {
        visitChildren(structure)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ structure: StructureID) {
        var members = shaderModule.cursor(shaderModule[structure].members)
        while !members.isAtEnd {
            let member = shaderModule.advance(&members)
            checkErrorAndVisit(member)
        }
    }

    @_spi(Testing)
    public mutating func visit(_ member: StructureMemberID) {
        visitChildren(member)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ member: StructureMemberID) {
        let node = shaderModule[member]
        checkErrorAndVisitEach(node.attributes)
        checkErrorAndVisit(node.type)
    }

    // Types

    @_spi(Testing)
    public mutating func visit(_ expression: ArrayTypeExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: ArrayTypeExpression, _ id: ExpressionID) {
        maybeCheckErrorAndVisit(expression.maybeElementType)
        maybeCheckErrorAndVisit(expression.maybeElementCount)
    }

    @_spi(Testing)
    public mutating func visit(_ expression: ElaboratedTypeExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: ElaboratedTypeExpression, _ id: ExpressionID) {
        checkErrorAndVisitEach(expression.arguments)
    }

    @_spi(Testing)
    public mutating func visit(_ expression: ReferenceTypeExpression, _ id: ExpressionID) {
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ expression: ReferenceTypeExpression, _ id: ExpressionID) {
        checkErrorAndVisit(expression.type)
    }

    // Variable

    @_spi(Testing)
    public mutating func visit(_ variable: VariableID) {
        visitChildren(variable)
    }

    @_spi(Testing)
    public mutating func visitChildren(_ variable: VariableID) {
        let node = shaderModule[variable]
        checkErrorAndVisitEach(node.attributes)
        maybeCheckErrorAndVisit(node.maybeQualifier)
        maybeCheckErrorAndVisit(node.maybeTypeName)
        maybeCheckErrorAndVisit(node.maybeInitializer)
    }

    @_spi(Testing)
    public mutating func visit(_ qualifier: VariableQualifier) {
    }
}

// MARK: - Default-traversal probe

/// An IR-only pass for stack-budget probes of the default traversal and for hook-fires tests: it overrides the
/// BinaryExpression and IfStatement hooks the way a pass does, and `run()` traverses the module with the code an in-module
/// pass gets.
@_spi(Testing)
public struct TraversalProbe: ASTVisitor, ~Copyable {
    @_spi(Testing)
    public var shaderModule: ShaderModule
    @_spi(Testing)
    public var expectedError: CompilationMessage?
    @_spi(Testing)
    public var hasError = false
    @_spi(Testing)
    public private(set) var binaryExpressions = 0
    @_spi(Testing)
    public private(set) var ifStatements = 0

    @_spi(Testing)
    public init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    @_spi(Testing)
    public mutating func run() {
        visitShaderModule()
    }

    @_spi(Testing)
    public mutating func visit(_ expression: BinaryExpression, _ id: ExpressionID) {
        binaryExpressions += 1
        visitChildren(expression, id)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: IfStatement, _ id: StatementID) {
        ifStatements += 1
        visitChildren(statement, id)
    }
}
