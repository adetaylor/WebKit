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

/// C++ `AST::StringDumper`.
///
/// It only reads the module, which it borrows, so it walks the AST itself instead of conforming to `ASTVisitor` (whose
/// conformers own the module); the `AST::Visitor` dispatch and default traversal it inherits are at the end of the file.
struct StringDumper {
    private var out = StringPrintStream()
    private var indent = MessageText(codeUnits: [])

    /// C++ `bumpIndent`: adds a level and returns the indent the scope restores when it ends.
    private mutating func bumpIndent() -> MessageText {
        let scope = indent
        indent.append("    ")
        return scope
    }

    private mutating func visitVector(_ shaderModule: borrowing ShaderModule, _ nodes: ListID<AttributeID>, _ joiner: StaticString) {
        guard shaderModule.count(nodes) != 0 else {
            return
        }

        visit(shaderModule, shaderModule[nodes, 0])
        var n = 1
        while n < shaderModule.count(nodes) {
            out.print(joiner)
            visit(shaderModule, shaderModule[nodes, n])
            n += 1
        }
    }

    private mutating func visitVector(_ shaderModule: borrowing ShaderModule, _ nodes: ListID<ParameterID>, _ joiner: StaticString) {
        guard shaderModule.count(nodes) != 0 else {
            return
        }

        visit(shaderModule, shaderModule[nodes, 0])
        var n = 1
        while n < shaderModule.count(nodes) {
            out.print(joiner)
            visit(shaderModule, shaderModule[nodes, n])
            n += 1
        }
    }

    private mutating func visitVector(_ shaderModule: borrowing ShaderModule, _ nodes: ListID<StructureMemberID>, _ joiner: StaticString) {
        guard shaderModule.count(nodes) != 0 else {
            return
        }

        visit(shaderModule, shaderModule[nodes, 0])
        var n = 1
        while n < shaderModule.count(nodes) {
            out.print(joiner)
            visit(shaderModule, shaderModule[nodes, n])
            n += 1
        }
    }

    private mutating func visitVector(_ shaderModule: borrowing ShaderModule, _ nodes: ListID<ExpressionID>, _ joiner: StaticString) {
        guard shaderModule.count(nodes) != 0 else {
            return
        }

        visit(shaderModule, shaderModule[nodes, 0])
        var n = 1
        while n < shaderModule.count(nodes) {
            out.print(joiner)
            visit(shaderModule, shaderModule[nodes, n])
            n += 1
        }
    }

    private mutating func visitVector(_ shaderModule: borrowing ShaderModule, _ nodes: ListID<StatementID>, _ joiner: StaticString) {
        guard shaderModule.count(nodes) != 0 else {
            return
        }

        visit(shaderModule, shaderModule[nodes, 0])
        var n = 1
        while n < shaderModule.count(nodes) {
            out.print(joiner)
            visit(shaderModule, shaderModule[nodes, n])
            n += 1
        }
    }

    func toString() -> MessageText {
        out.toString()
    }

    // Shader Module
    mutating func visit(_ shaderModule: borrowing ShaderModule) {
        var directives = shaderModule.cursor(shaderModule.directives)
        while let directive = shaderModule.next(&directives) {
            visit(shaderModule, directive)
        }
        if shaderModule.count(shaderModule.directives) != 0 {
            out.print("\n\n")
        }

        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            visit(shaderModule, declaration)
            out.print("\n")
        }
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ diagnostic: Diagnostic) {
        out.print("diagnostic(")
        out.print(WGSL.toString(diagnostic.severity))
        out.print(", ")
        out.print(WGSL.toString(diagnostic.triggeringRule))
        out.print(")")
    }

    // Attribute
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ binding: BindingAttribute) {
        out.print("@binding(")
        visit(shaderModule, binding.binding)
        out.print(")")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ builtin: BuiltinAttribute) {
        out.print("@builtin(")
        out.print(WGSL.toString(builtin.builtin))
        out.print(")")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ group: GroupAttribute) {
        out.print("@group(")
        visit(shaderModule, group.group)
        out.print(")")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ location: LocationAttribute) {
        out.print("@location(")
        visit(shaderModule, location.location)
        out.print(")")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ stage: StageAttribute) {
        out.print("@")
        out.print(WGSL.toString(stage.stage))
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ workgroupSize: WorkgroupSizeAttribute) {
        out.print("@workgroup_size(")
        visit(shaderModule, workgroupSize.x)
        if let y = workgroupSize.maybeY {
            out.print(", ")
            visit(shaderModule, y)
            if let z = workgroupSize.maybeZ {
                out.print(", ")
                visit(shaderModule, z)
            }
        }
        out.print(")")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ attribute: DiagnosticAttribute) {
        out.print("@")
        visit(shaderModule, attribute.diagnostic)
    }

    // Declaration
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: FunctionID) {
        let function = shaderModule[id]
        out.print(string: indent)
        if shaderModule.count(function.attributes) != 0 {
            visitVector(shaderModule, function.attributes, " ")
            out.print("\n")
            out.print(string: indent)
        }
        out.print("fn ")
        printIdentifier(shaderModule, function.name)
        out.print("(")
        if shaderModule.count(function.parameters) != 0 {
            out.print("\n")
            do {
                let indent = bumpIndent()
                defer { self.indent = indent }
                visitVector(shaderModule, function.parameters, "\n")
            }
            out.print("\n")
            out.print(string: indent)
        }
        out.print(")")
        if let returnType = function.maybeReturnType {
            out.print(" -> ")
            visitVector(shaderModule, function.returnAttributes, " ")
            out.print(" ")
            visit(shaderModule, returnType)
        }
        out.print("\n")
        out.print(string: indent)
        visit(shaderModule, shaderModule.downcast(CompoundStatement.self, function.body))
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: StructureID) {
        let structure = shaderModule[id]
        out.print(string: indent)
        out.print("struct ")
        printIdentifier(shaderModule, structure.name)
        out.print(" {")
        if shaderModule.count(structure.members) != 0 {
            out.print("\n")
            do {
                let indent = bumpIndent()
                defer { self.indent = indent }
                visitVector(shaderModule, structure.members, ",\n")
            }
            out.print("\n")
            out.print(string: indent)
        }
        out.print("}\n")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: VariableID) {
        let variable = shaderModule[id]
        if shaderModule.count(variable.attributes) != 0 {
            visitVector(shaderModule, variable.attributes, " ")
            out.print(" ")
        }
        out.print("var")
        if let qualifier = variable.maybeQualifier {
            visit(shaderModule, qualifier)
        }
        out.print(" ")
        printIdentifier(shaderModule, variable.name)
        if let typeName = variable.maybeTypeName {
            out.print(": ")
            visit(shaderModule, typeName)
        }
        if let initializer = variable.maybeInitializer {
            out.print(" = ")
            visit(shaderModule, initializer)
        }
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: TypeAliasID) {
        let alias = shaderModule[id]
        out.print(string: indent)
        out.print("alias ")
        printIdentifier(shaderModule, alias.name)
        out.print(" = ")
        visit(shaderModule, alias.type)
        out.print(";")
    }

    // Expression
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: AbstractFloatLiteral) {
        printASCII(WTFNumberFormat.printfF(literal.value))
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: AbstractIntegerLiteral) {
        out.print(string: "\(literal.value)")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ arrayAccess: IndexAccessExpression) {
        visitPostfixBase(shaderModule, arrayAccess.base)
        visitAccess(shaderModule, PostfixAccess.index(arrayAccess.index))
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: BoolLiteral) {
        out.print(literal.value ? "true" : "false")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ expression: CallExpression) {
        visit(shaderModule, expression.target)
        out.print("(")
        if shaderModule.count(expression.arguments) != 0 {
            let indent = bumpIndent()
            defer { self.indent = indent }
            visitVector(shaderModule, expression.arguments, ", ")
        }
        out.print(")")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: Float32Literal) {
        printASCII(WTFNumberFormat.printfF(Double(literal.value)))
        out.print("f")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: Float16Literal) {
        printASCII(WTFNumberFormat.number(literal.value))
        out.print("h")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ identifier: IdentifierExpression) {
        printIdentifier(shaderModule, identifier.identifier)
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: Signed32Literal) {
        out.print(string: "\(literal.value)")
        out.print("i")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ fieldAccess: FieldAccessExpression) {
        visitPostfixBase(shaderModule, fieldAccess.base)
        visitAccess(shaderModule, PostfixAccess.field(fieldAccess.fieldName))
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ literal: Unsigned32Literal) {
        out.print(literal.value)
        out.print("u")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ expression: UnaryExpression) {
        out.print(toASCIILiteral(expression.operation))
        visit(shaderModule, expression.expression)
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ expression: BinaryExpression) {
        // DEV-03: the parser builds left-associative chains in a loop, so left operands nest without bound; the enclosing
        // expressions of the innermost one are kept on an explicit stack where the C++ recurses through leftExpression().
        var enclosing: [BinaryExpression] = []
        var innermost = expression
        while case .binaryExpression(let left) = shaderModule[innermost.leftExpression].kind {
            enclosing.append(innermost)
            innermost = left
        }
        visit(shaderModule, innermost.leftExpression)
        visitOperationAndRightExpression(shaderModule, innermost)
        while let expression = enclosing.popLast() {
            visitOperationAndRightExpression(shaderModule, expression)
        }
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ pointerDereference: PointerDereferenceExpression) {
        out.print("(*")
        visit(shaderModule, pointerDereference.target)
        out.print(")")
    }

    // Statement
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: AssignmentStatement) {
        out.print(string: indent)
        visit(shaderModule, statement.lhs)
        out.print(" = ")
        visit(shaderModule, statement.rhs)
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: CallStatement) {
        visit(shaderModule, shaderModule.downcast(CallExpression.self, statement.call))
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: CompoundAssignmentStatement) {
        out.print(string: indent)
        visit(shaderModule, statement.leftExpression)
        out.print(" ")
        out.print(toASCIILiteral(statement.operation))
        out.print("= ")
        visit(shaderModule, statement.rightExpression)
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ block: CompoundStatement) {
        out.print(string: indent)
        out.print("{")
        if shaderModule.count(block.statements) != 0 {
            do {
                let indent = bumpIndent()
                defer { self.indent = indent }
                out.print("\n")
                visitVector(shaderModule, block.statements, "\n")
            }
            out.print("\n")
            out.print(string: indent)
        }
        out.print("}\n")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: DecrementIncrementStatement) {
        out.print(string: indent)
        visit(shaderModule, statement.expression)
        var operation = MessageText(codeUnits: [])
        printInternal(&operation, statement.operation)
        out.print(string: operation)
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: IfStatement) {
        out.print(string: indent)
        out.print("if ")
        visit(shaderModule, statement.test)
        out.print("\n")
        visit(shaderModule, shaderModule.downcast(CompoundStatement.self, statement.trueBody))
        if let falseBody = statement.maybeFalseBody {
            out.print(string: indent)
            out.print("else")
            if shaderModule.is(IfStatement.self, falseBody) {
                out.print(" ")
            } else {
                out.print("\n")
            }
            visit(shaderModule, falseBody)
        }
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: PhonyAssignmentStatement) {
        out.print(string: indent)
        out.print("_ = ")
        visit(shaderModule, statement.rhs)
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: ReturnStatement) {
        out.print(string: indent)
        out.print("return")
        if let expression = statement.maybeExpression {
            out.print(" ")
            visit(shaderModule, expression)
        }
        out.print(";")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: VariableStatement) {
        out.print(string: indent)
        visit(shaderModule, statement.variable)
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: ForStatement) {
        out.print("for (")
        if let initializer = statement.maybeInitializer {
            visit(shaderModule, initializer)
        }
        out.print(";")
        if let test = statement.maybeTest {
            visit(shaderModule, test)
        }
        out.print(";")
        if let update = statement.maybeUpdate {
            visit(shaderModule, update)
        }
        out.print(")")
        visit(shaderModule, shaderModule.downcast(CompoundStatement.self, statement.body))
    }

    // Types
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ type: ArrayTypeExpression) {
        out.print("array")
        if let elementType = type.maybeElementType {
            out.print("<")
            visit(shaderModule, elementType)
            if let elementCount = type.maybeElementCount {
                out.print(", ")
                visit(shaderModule, elementCount)
            }
            out.print(">")
        }
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ type: ElaboratedTypeExpression) {
        printIdentifier(shaderModule, type.base)
        out.print("<")
        var first = true
        var arguments = shaderModule.cursor(type.arguments)
        while let argument = shaderModule.next(&arguments) {
            if !first {
                out.print(", ")
            }
            first = false
            visit(shaderModule, argument)
        }
        out.print(">")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ type: ReferenceTypeExpression) {
        visit(shaderModule, type.type)
        out.print("&")
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: ParameterID) {
        let parameter = shaderModule[id]
        out.print(string: indent)
        if shaderModule.count(parameter.attributes) != 0 {
            visitVector(shaderModule, parameter.attributes, " ")
            out.print(" ")
        }
        printIdentifier(shaderModule, parameter.name)
        out.print(": ")
        visit(shaderModule, parameter.typeName)
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: StructureMemberID) {
        let member = shaderModule[id]
        out.print(string: indent)
        if shaderModule.count(member.attributes) != 0 {
            visitVector(shaderModule, member.attributes, " ")
            out.print(" ")
        }
        printIdentifier(shaderModule, member.name)
        out.print(": ")
        visit(shaderModule, member.type)
    }

    mutating func visit(_ shaderModule: borrowing ShaderModule, _ qualifier: VariableQualifier) {
        out.print("<")
        out.print(WGSL.toString(qualifier.addressSpace))
        out.print(",")
        out.print(WGSL.toString(qualifier.accessMode))
        out.print(">")
    }
}

extension ShaderModule {
    /// C++ `dumpNode(PrintStream&, T&)` for an expression: the AST string dumper's text of `expression`, printed into `out`
    /// as one string.
    @_spi(Testing)
    public func dumpNode(_ expression: ExpressionID, into out: inout StringPrintStream) {
        var dumper = StringDumper()
        dumper.visit(self, expression)
        out.print(string: dumper.toString())
    }
}

extension StringDumper {
    /// C++ `out.print(identifier)`: the identifier's `String`.
    private mutating func printIdentifier(_ shaderModule: borrowing ShaderModule, _ identifier: IdentifierID) {
        out.print(string: shaderModule.symbols.text(of: shaderModule.symbol(of: identifier)))
    }

    /// The text of a WTF number formatter (`printf("%lf")` for `out.print(double)`, `String::number`).
    private mutating func printASCII(_ bytes: ContiguousArray<UInt8>) {
        var text = MessageText(codeUnits: [])
        text.codeUnits.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            text.codeUnits.append(UInt16(bytes[index]))
            index += 1
        }
        out.print(string: text)
    }
}

// MARK: - AST::Visitor (ASTVisitor.cpp): the dispatch, and the default traversal of the nodes the dumper does not print

extension StringDumper {
    // Directive
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ directive: DirectiveID) {
        switch shaderModule[directive].kind {
        case .diagnosticDirective(let node):
            visit(shaderModule, node)
        }
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ directive: DiagnosticDirective) {
        visit(shaderModule, directive.diagnostic)
    }

    // Declarations
    @inline(never)
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ declaration: Declaration) {
        switch declaration {
        case .function(let function):
            visit(shaderModule, function)
        case .variable(let variable):
            visit(shaderModule, variable)
        case .structure(let structure):
            visit(shaderModule, structure)
        case .typeAlias(let alias):
            visit(shaderModule, alias)
        case .constAssert(let assertion):
            visit(shaderModule, assertion)
        }
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ assertion: ConstAssertID) {
        visit(shaderModule, shaderModule[assertion].test)
    }

    // Attribute
    @inline(never)
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ attribute: AttributeID) {
        switch shaderModule[attribute].kind {
        case .alignAttribute(let node):
            visit(shaderModule, node.alignment)
        case .bindingAttribute(let node):
            visit(shaderModule, node)
        case .builtinAttribute(let node):
            visit(shaderModule, node)
        case .constAttribute:
            break
        case .diagnosticAttribute(let node):
            visit(shaderModule, node)
        case .groupAttribute(let node):
            visit(shaderModule, node)
        case .idAttribute(let node):
            visit(shaderModule, node.value)
        case .interpolateAttribute:
            break
        case .invariantAttribute:
            break
        case .locationAttribute(let node):
            visit(shaderModule, node)
        case .mustUseAttribute:
            break
        case .sizeAttribute(let node):
            visit(shaderModule, node.size)
        case .stageAttribute(let node):
            visit(shaderModule, node)
        case .workgroupSizeAttribute(let node):
            visit(shaderModule, node)
        }
    }

    // Expression

    /// Switches on the tag and calls one trampoline per kind, so the frame of this recursion binds no payload.
    @inline(never)
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ expression: ExpressionID) {
        switch shaderModule.tag(of: expression) {
        case .abstractFloatLiteral:
            visitAbstractFloatLiteralPayload(shaderModule, expression)
        case .abstractIntegerLiteral:
            visitAbstractIntegerLiteralPayload(shaderModule, expression)
        case .binaryExpression:
            visitBinaryExpressionPayload(shaderModule, expression)
        case .boolLiteral:
            visitBoolLiteralPayload(shaderModule, expression)
        case .callExpression:
            visitCallExpressionPayload(shaderModule, expression)
        case .fieldAccessExpression:
            visitFieldAccessExpressionPayload(shaderModule, expression)
        case .float32Literal:
            visitFloat32LiteralPayload(shaderModule, expression)
        case .float16Literal:
            visitFloat16LiteralPayload(shaderModule, expression)
        case .identifierExpression:
            visitIdentifierExpressionPayload(shaderModule, expression)
        case .identityExpression:
            visitIdentityExpressionPayload(shaderModule, expression)
        case .indexAccessExpression:
            visitIndexAccessExpressionPayload(shaderModule, expression)
        case .checkedIndexAccessExpression:
            visitCheckedIndexAccessExpressionPayload(shaderModule, expression)
        case .signed32Literal:
            visitSigned32LiteralPayload(shaderModule, expression)
        case .unaryExpression:
            visitUnaryExpressionPayload(shaderModule, expression)
        case .unsigned32Literal:
            visitUnsigned32LiteralPayload(shaderModule, expression)
        case .arrayTypeExpression:
            visitArrayTypeExpressionPayload(shaderModule, expression)
        case .elaboratedTypeExpression:
            visitElaboratedTypeExpressionPayload(shaderModule, expression)
        case .referenceTypeExpression:
            visitReferenceTypeExpressionPayload(shaderModule, expression)
        case .pointerDereferenceExpression:
            assertionFailure("Unhandled Expression")
        }
    }

    private mutating func visitAbstractFloatLiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .abstractFloatLiteral(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:239")
        }
        visit(shaderModule, node)
    }

    private mutating func visitAbstractIntegerLiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .abstractIntegerLiteral(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:242")
        }
        visit(shaderModule, node)
    }

    private mutating func visitBinaryExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .binaryExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:245")
        }
        visit(shaderModule, node)
    }

    private mutating func visitBoolLiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .boolLiteral(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:248")
        }
        visit(shaderModule, node)
    }

    private mutating func visitCallExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .callExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:251")
        }
        visit(shaderModule, node)
    }

    private mutating func visitFieldAccessExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .fieldAccessExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:254")
        }
        visit(shaderModule, node)
    }

    private mutating func visitFloat32LiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .float32Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:257")
        }
        visit(shaderModule, node)
    }

    private mutating func visitFloat16LiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .float16Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:260")
        }
        visit(shaderModule, node)
    }

    private mutating func visitIdentifierExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .identifierExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:263")
        }
        visit(shaderModule, node)
    }

    private mutating func visitIdentityExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .identityExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:266")
        }
        visit(shaderModule, node.expression)
    }

    private mutating func visitIndexAccessExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .indexAccessExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:269")
        }
        visit(shaderModule, node)
    }

    /// A checked access prints as the IndexAccessExpression it replaced.
    private mutating func visitCheckedIndexAccessExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .checkedIndexAccessExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:269")
        }
        visitPostfixBase(shaderModule, node.base)
        visitAccess(shaderModule, PostfixAccess.index(node.index))
    }

    private mutating func visitSigned32LiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .signed32Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:272")
        }
        visit(shaderModule, node)
    }

    private mutating func visitUnaryExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .unaryExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:275")
        }
        visit(shaderModule, node)
    }

    private mutating func visitUnsigned32LiteralPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .unsigned32Literal(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:278")
        }
        visit(shaderModule, node)
    }

    private mutating func visitArrayTypeExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .arrayTypeExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:281")
        }
        visit(shaderModule, node)
    }

    private mutating func visitElaboratedTypeExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .elaboratedTypeExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:284")
        }
        visit(shaderModule, node)
    }

    private mutating func visitReferenceTypeExpressionPayload(_ shaderModule: borrowing ShaderModule, _ id: ExpressionID) {
        guard case .referenceTypeExpression(let node) = shaderModule[id].kind else {
            wgslFatal("tag/kind mismatch", cppSite: "ASTVisitor.cpp:287")
        }
        visit(shaderModule, node)
    }

    /// What a postfix expression prints after its base.
    private enum PostfixAccess {
        case field(IdentifierID)
        case index(ExpressionID)
    }

    private mutating func visitPostfixBase(_ shaderModule: borrowing ShaderModule, _ base: ExpressionID) {
        // DEV-03: the parser builds postfix chains in a loop, so bases nest without bound; the accesses below `base` are kept
        // on an explicit stack and printed after the innermost base, in the order the C++ recursion through each base prints them.
        var accesses: [PostfixAccess] = []
        var innermost = base
        while true {
            let kind = shaderModule[innermost].kind
            if case .fieldAccessExpression(let node) = kind {
                accesses.append(.field(node.fieldName))
                innermost = node.base
            } else if case .indexAccessExpression(let node) = kind {
                accesses.append(.index(node.index))
                innermost = node.base
            } else if case .checkedIndexAccessExpression(let node) = kind {
                accesses.append(.index(node.index))
                innermost = node.base
            } else {
                break
            }
        }
        visit(shaderModule, innermost)
        while let access = accesses.popLast() {
            visitAccess(shaderModule, access)
        }
    }

    private mutating func visitAccess(_ shaderModule: borrowing ShaderModule, _ access: PostfixAccess) {
        switch access {
        case .field(let fieldName):
            out.print(".")
            printIdentifier(shaderModule, fieldName)
        case .index(let index):
            out.print("[")
            visit(shaderModule, index)
            out.print("]")
        }
    }

    private mutating func visitOperationAndRightExpression(_ shaderModule: borrowing ShaderModule, _ expression: BinaryExpression) {
        out.print(" ")
        out.print(toASCIILiteral(expression.operation))
        out.print(" ")
        visit(shaderModule, expression.rightExpression)
    }

    // Statement
    @inline(never)
    mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: StatementID) {
        switch shaderModule[statement].kind {
        case .assignmentStatement(let node):
            visit(shaderModule, node)
        case .breakStatement:
            break
        case .callStatement(let node):
            visit(shaderModule, node)
        case .compoundAssignmentStatement(let node):
            visit(shaderModule, node)
        case .compoundStatement(let node):
            visit(shaderModule, node)
        case .constAssertStatement(let node):
            visit(shaderModule, node.assertion)
        case .continueStatement:
            break
        case .decrementIncrementStatement(let node):
            visit(shaderModule, node)
        case .discardStatement:
            break
        case .forStatement(let node):
            visit(shaderModule, node)
        case .ifStatement(let node):
            visit(shaderModule, node)
        case .loopStatement(let node):
            visit(shaderModule, node)
        case .phonyAssignmentStatement(let node):
            visit(shaderModule, node)
        case .returnStatement(let node):
            visit(shaderModule, node)
        case .switchStatement(let node):
            visit(shaderModule, node)
        case .variableStatement(let node):
            visit(shaderModule, node)
        case .whileStatement(let node):
            visit(shaderModule, node)
        }
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: LoopStatement) {
        visitEach(shaderModule, statement.attributes)
        visitEach(shaderModule, statement.body)
        if let continuing = statement.continuing {
            visit(shaderModule, continuing)
        }
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ continuing: Continuing) {
        visitEach(shaderModule, continuing.body)
        visitEach(shaderModule, continuing.attributes)
        if let breakIf = continuing.breakIf {
            visit(shaderModule, breakIf)
        }
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: SwitchStatement) {
        visit(shaderModule, statement.value)
        visitEach(shaderModule, statement.bodyAttributes)
        var clauses = shaderModule.cursor(statement.clauses)
        while let clause = shaderModule.next(&clauses) {
            visit(shaderModule, clause)
        }
        visit(shaderModule, statement.defaultClause)
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ id: SwitchClauseID) {
        let clause = shaderModule[id]
        var selectors = shaderModule.cursor(clause.selectors)
        while let selector = shaderModule.next(&selectors) {
            visit(shaderModule, selector)
        }
        visit(shaderModule, shaderModule.downcast(CompoundStatement.self, clause.body))
    }

    private mutating func visit(_ shaderModule: borrowing ShaderModule, _ statement: WhileStatement) {
        visit(shaderModule, statement.test)
        visit(shaderModule, shaderModule.downcast(CompoundStatement.self, statement.body))
    }

    private mutating func visitEach(_ shaderModule: borrowing ShaderModule, _ attributes: ListID<AttributeID>) {
        var cursor = shaderModule.cursor(attributes)
        while let attribute = shaderModule.next(&cursor) {
            visit(shaderModule, attribute)
        }
    }

    private mutating func visitEach(_ shaderModule: borrowing ShaderModule, _ statements: ListID<StatementID>) {
        var cursor = shaderModule.cursor(statements)
        while let statement = shaderModule.next(&cursor) {
            visit(shaderModule, statement)
        }
    }
}

/// The text of `AST::StringDumper` over a module or an expression, as TestWGSL's `toString(ShaderModule&)` returns it.
@_spi(Testing)
public enum ASTStringDumper {
    @_spi(Testing)
    public static func dump(_ shaderModule: borrowing ShaderModule) -> String {
        var dumper = StringDumper()
        dumper.visit(shaderModule)
        return String(decoding: dumper.toString().codeUnits, as: UTF16.self)
    }

    @_spi(Testing)
    public static func dump(_ shaderModule: borrowing ShaderModule, _ expression: ExpressionID) -> String {
        var dumper = StringDumper()
        dumper.visit(shaderModule, expression)
        return String(decoding: dumper.toString().codeUnits, as: UTF16.self)
    }
}
