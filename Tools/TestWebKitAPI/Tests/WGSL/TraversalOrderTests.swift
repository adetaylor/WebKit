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

// The default traversal (ASTVisitor.swift) against the C++ AST::Visitor: `allNodeKindsGolden` is the C++ recorder's report
// over `allNodeKindsSource`, with errors set at events 3, 6, 11, 22, 134, 416 and 480, and `buildAllNodeKinds` builds the
// same module, with the C++
// parser's spans, through the IR constructors: once as `WGSL::parse` leaves it and once as `staticCheck` does (where
// `rewritePointers` has removed `let p = &x;` and turned `*p` into an IdentityExpression of `x`).

// MARK: - Recorder

private func spanText(_ span: SourceSpan) -> String {
    "\(span.line):\(span.lineOffset):\(span.offset):\(span.length)"
}

private func kindName(_ kind: NodeKind) -> String {
    let name = String(describing: kind)
    return name.prefix(1).uppercased() + name.dropFirst()
}

/// Logs every hook, then calls the default traversal; sets an error right after the `errorAt`-th event (1-based).
private struct TraversalRecorder: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var events: [String] = []
    let errorAt: Int

    init(shaderModule: consuming ShaderModule, errorAt: Int) {
        self.shaderModule = shaderModule
        self.errorAt = errorAt
    }

    private mutating func event(_ text: String, _ span: SourceSpan?) {
        events.append(text + " " + (span.map(spanText) ?? "-"))
        if events.count == errorAt {
            setError(CompilationMessage("traversal error", span: span ?? .empty))
        }
    }

    private mutating func category(_ name: String, _ kind: NodeKind, _ span: SourceSpan) {
        event("cat " + name + " " + kindName(kind), span)
    }

    mutating func visitShaderModule() {
        event("hook ShaderModule", nil)
        visitShaderModuleChildren()
    }

    mutating func visit(_ directive: DirectiveID) {
        category("directive", shaderModule[directive].kind.tag.nodeKind, shaderModule[directive].span)
        dispatch(directive)
    }

    mutating func visit(_ directive: DiagnosticDirective, _ id: DirectiveID) {
        event("hook DiagnosticDirective", shaderModule[id].span)
        visitChildren(directive, id)
    }

    mutating func visit(_ diagnostic: Diagnostic) {
        event("hook Diagnostic", nil)
    }

    mutating func visit(_ declaration: Declaration) {
        category("declaration", declaration.nodeKind, shaderModule.span(of: declaration))
        dispatch(declaration)
    }

    mutating func visit(_ function: FunctionID) {
        event("hook Function", shaderModule[function].span)
        visitChildren(function)
    }

    mutating func visit(_ variable: VariableID) {
        event("hook Variable", shaderModule[variable].span)
        visitChildren(variable)
    }

    mutating func visit(_ structure: StructureID) {
        event("hook Structure", shaderModule[structure].span)
        visitChildren(structure)
    }

    mutating func visit(_ alias: TypeAliasID) {
        event("hook TypeAlias", shaderModule[alias].span)
        visitChildren(alias)
    }

    mutating func visit(_ assertion: ConstAssertID) {
        event("hook ConstAssert", shaderModule[assertion].span)
        visitChildren(assertion)
    }

    mutating func visit(_ attribute: AttributeID) {
        category("attribute", shaderModule.nodeKind(of: attribute), shaderModule.span(of: attribute))
        dispatch(attribute)
    }

    mutating func visit(_ attribute: AlignAttribute, _ id: AttributeID) {
        event("hook AlignAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: BindingAttribute, _ id: AttributeID) {
        event("hook BindingAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: BuiltinAttribute, _ id: AttributeID) {
        event("hook BuiltinAttribute", shaderModule.span(of: id))
    }

    mutating func visit(_ attribute: ConstAttribute, _ id: AttributeID) {
        event("hook ConstAttribute", shaderModule.span(of: id))
    }

    mutating func visit(_ attribute: DiagnosticAttribute, _ id: AttributeID) {
        event("hook DiagnosticAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: GroupAttribute, _ id: AttributeID) {
        event("hook GroupAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: IdAttribute, _ id: AttributeID) {
        event("hook IdAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: InterpolateAttribute, _ id: AttributeID) {
        event("hook InterpolateAttribute", shaderModule.span(of: id))
    }

    mutating func visit(_ attribute: InvariantAttribute, _ id: AttributeID) {
        event("hook InvariantAttribute", shaderModule.span(of: id))
    }

    mutating func visit(_ attribute: LocationAttribute, _ id: AttributeID) {
        event("hook LocationAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: MustUseAttribute, _ id: AttributeID) {
        event("hook MustUseAttribute", shaderModule.span(of: id))
    }

    mutating func visit(_ attribute: SizeAttribute, _ id: AttributeID) {
        event("hook SizeAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ attribute: StageAttribute, _ id: AttributeID) {
        event("hook StageAttribute", shaderModule.span(of: id))
    }

    mutating func visit(_ attribute: WorkgroupSizeAttribute, _ id: AttributeID) {
        event("hook WorkgroupSizeAttribute", shaderModule.span(of: id))
        visitChildren(attribute, id)
    }

    mutating func visit(_ expression: ExpressionID) {
        category("expression", shaderModule.nodeKind(of: expression), shaderModule.span(of: expression))
        dispatch(expression)
    }

    mutating func visit(_ literal: AbstractFloatLiteral, _ id: ExpressionID) {
        event("hook AbstractFloatLiteral", shaderModule.span(of: id))
    }

    mutating func visit(_ literal: AbstractIntegerLiteral, _ id: ExpressionID) {
        event("hook AbstractIntegerLiteral", shaderModule.span(of: id))
    }

    mutating func visit(_ expression: BinaryExpression, _ id: ExpressionID) {
        event("hook BinaryExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ literal: BoolLiteral, _ id: ExpressionID) {
        event("hook BoolLiteral", shaderModule.span(of: id))
    }

    mutating func visit(_ expression: CallExpression, _ id: ExpressionID) {
        event("hook CallExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: FieldAccessExpression, _ id: ExpressionID) {
        event("hook FieldAccessExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ literal: Float32Literal, _ id: ExpressionID) {
        event("hook Float32Literal", shaderModule.span(of: id))
    }

    mutating func visit(_ literal: Float16Literal, _ id: ExpressionID) {
        event("hook Float16Literal", shaderModule.span(of: id))
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        event("hook IdentifierExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: IdentityExpression, _ id: ExpressionID) {
        event("hook IdentityExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: IndexAccessExpression, _ id: ExpressionID) {
        event("hook IndexAccessExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: PointerDereferenceExpression, _ id: ExpressionID) {
        event("hook PointerDereferenceExpression", shaderModule.span(of: id))
    }

    mutating func visit(_ literal: Signed32Literal, _ id: ExpressionID) {
        event("hook Signed32Literal", shaderModule.span(of: id))
    }

    mutating func visit(_ expression: UnaryExpression, _ id: ExpressionID) {
        event("hook UnaryExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ literal: Unsigned32Literal, _ id: ExpressionID) {
        event("hook Unsigned32Literal", shaderModule.span(of: id))
    }

    mutating func visit(_ parameter: ParameterID) {
        event("hook Parameter", shaderModule[parameter].span)
        visitChildren(parameter)
    }

    mutating func visit(_ identifier: IdentifierID) {
        event("hook Identifier", shaderModule[identifier].span)
    }

    mutating func visit(_ statement: StatementID) {
        category("statement", shaderModule.nodeKind(of: statement), shaderModule.span(of: statement))
        dispatch(statement)
    }

    mutating func visit(_ statement: AssignmentStatement, _ id: StatementID) {
        event("hook AssignmentStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: BreakStatement, _ id: StatementID) {
        event("hook BreakStatement", shaderModule.span(of: id))
    }

    mutating func visit(_ statement: CallStatement, _ id: StatementID) {
        event("hook CallStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        event("hook CompoundAssignmentStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        event("hook CompoundStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: ConstAssertStatement, _ id: StatementID) {
        event("hook ConstAssertStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: ContinueStatement, _ id: StatementID) {
        event("hook ContinueStatement", shaderModule.span(of: id))
    }

    mutating func visit(_ statement: DecrementIncrementStatement, _ id: StatementID) {
        event("hook DecrementIncrementStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: DiscardStatement, _ id: StatementID) {
        event("hook DiscardStatement", shaderModule.span(of: id))
    }

    mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        event("hook ForStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: IfStatement, _ id: StatementID) {
        event("hook IfStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        event("hook LoopStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID) {
        event("hook PhonyAssignmentStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: ReturnStatement, _ id: StatementID) {
        event("hook ReturnStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: SwitchStatement, _ id: StatementID) {
        event("hook SwitchStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        event("hook VariableStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: WhileStatement, _ id: StatementID) {
        event("hook WhileStatement", shaderModule.span(of: id))
        visitChildren(statement, id)
    }

    mutating func visit(_ expression: ArrayTypeExpression, _ id: ExpressionID) {
        event("hook ArrayTypeExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: ElaboratedTypeExpression, _ id: ExpressionID) {
        event("hook ElaboratedTypeExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: ReferenceTypeExpression, _ id: ExpressionID) {
        event("hook ReferenceTypeExpression", shaderModule.span(of: id))
        visitChildren(expression, id)
    }

    mutating func visit(_ member: StructureMemberID) {
        event("hook StructureMember", shaderModule[member].span)
        visitChildren(member)
    }

    mutating func visit(_ qualifier: VariableQualifier) {
        event("hook VariableQualifier", qualifier.span)
    }

    mutating func visit(_ clause: SwitchClauseID) {
        event("hook SwitchClause", nil)
        visitChildren(clause)
    }

    mutating func visit(_ continuing: Continuing) {
        event("hook Continuing", nil)
        visitChildren(continuing)
    }
}

/// The C++ recorder's `traversalReport`: the section header, then one line per event.
private func traversalSection(_ header: String, _ shaderModule: consuming ShaderModule, errorAt: Int = 0) -> String {
    var recorder = TraversalRecorder(shaderModule: shaderModule, errorAt: errorAt)
    recorder.visitShaderModule()
    var text = header + " count=\(recorder.events.count)\n"
    for event in recorder.events {
        text += event + "\n"
    }
    return text
}

// MARK: - The golden module through the IR constructors

private struct AllNodeKindsBuilder: ~Copyable {
    var module = ShaderModule(source: SourceText(allNodeKindsSource), configuration: Configuration(supportedFeatures: [.shaderF16]))

    /// "line:lineOffset:offset:length", as the golden prints spans.
    func span(_ text: String) -> SourceSpan {
        let fields = text.split(separator: ":").map { UInt32($0) ?? 0 }
        return SourceSpan(line: fields[0], lineOffset: fields[1], offset: fields[2], length: fields[3])
    }

    mutating func identifier(_ name: StaticString, _ at: String) -> ExpressionID {
        module.constructIdentifierExpression(span: span(at), identifier: module.makeIdentifier(name, span: span(at)))
    }

    mutating func int(_ value: Int64, _ at: String) -> ExpressionID {
        module.construct(span: span(at), AbstractIntegerLiteral(value: value))
    }

    mutating func float(_ value: Double, _ at: String) -> ExpressionID {
        module.construct(span: span(at), AbstractFloatLiteral(value: value))
    }

    mutating func binary(_ operation: BinaryOperation, _ left: ExpressionID, _ right: ExpressionID, _ at: String) -> ExpressionID {
        module.construct(span: span(at), BinaryExpression(leftExpression: left, rightExpression: right, operation: operation))
    }

    mutating func unary(_ operation: UnaryOperation, _ operand: ExpressionID, _ at: String) -> ExpressionID {
        module.construct(span: span(at), UnaryExpression(expression: operand, operation: operation))
    }

    mutating func call(_ target: ExpressionID, _ arguments: [ExpressionID], _ at: String) -> ExpressionID {
        module.construct(span: span(at), CallExpression(target: target, arguments: module.makeList(arguments)))
    }

    mutating func field(_ base: ExpressionID, _ name: StaticString, _ at: String) -> ExpressionID {
        module.constructFieldAccessExpression(span: span(at), base: base, fieldName: module.makeIdentifier(name))
    }

    mutating func elaborated(_ base: StaticString, _ arguments: [ExpressionID], _ at: String) -> ExpressionID {
        module.constructElaboratedTypeExpression(span: span(at), base: module.makeIdentifier(base), arguments: module.makeList(arguments))
    }

    mutating func attributes(_ attributes: [AttributeID]) -> ListID<AttributeID> {
        module.makeList(attributes)
    }

    mutating func attribute(_ kind: AttributeKind, _ at: String) -> AttributeID {
        module.construct(span: span(at), kind)
    }

    /// `@diagnostic(off, derivative_uniformity)`; the ones on lists the default traversal skips are made with an empty span.
    mutating func diagnostic(_ at: String = "0:0:0:0") -> AttributeID {
        attribute(
            .diagnosticAttribute(DiagnosticAttribute(diagnostic: Diagnostic(severity: .off, triggeringRule: .derivativeUniformity))),
            at
        )
    }

    mutating func statement<P: PlainStatementPayload>(_ payload: P, _ at: String) -> StatementID {
        module.construct(span: span(at), payload)
    }

    mutating func compound(_ attributes: [AttributeID], _ statements: [StatementID], _ at: String) -> StatementID {
        statement(CompoundStatement(attributes: module.makeList(attributes), statements: module.makeList(statements)), at)
    }

    mutating func variable(
        _ flavor: VariableFlavor,
        _ name: StaticString,
        _ at: String,
        attributes: [AttributeID] = [],
        qualifier: VariableQualifier? = nil,
        type: ExpressionID? = nil,
        initializer: ExpressionID? = nil
    ) -> VariableID {
        module.constructVariable(
            span: span(at),
            flavor: flavor,
            name: module.makeIdentifier(name),
            qualifier: qualifier,
            type: type,
            initializer: initializer,
            attributes: module.makeList(attributes)
        )
    }

    mutating func variableStatement(_ variable: VariableID, _ at: String) -> StatementID {
        statement(VariableStatement(variable: variable), at)
    }

    mutating func member(_ name: StaticString, _ at: String, _ attributes: [AttributeID], _ type: ExpressionID) -> StructureMemberID {
        module.constructStructureMember(
            span: span(at),
            name: module.makeIdentifier(name),
            type: type,
            attributes: module.makeList(attributes)
        )
    }

    mutating func parameter(_ name: StaticString, _ at: String, _ attributes: [AttributeID], _ type: ExpressionID) -> ParameterID {
        module.constructParameter(
            span: span(at),
            name: module.makeIdentifier(name),
            typeName: type,
            attributes: module.makeList(attributes),
            role: .userDefined
        )
    }

    mutating func function(
        _ name: StaticString,
        _ at: String,
        attributes: [AttributeID] = [],
        parameters: [ParameterID] = [],
        returnAttributes: [AttributeID] = [],
        returnType: ExpressionID? = nil,
        body: StatementID
    ) {
        let function = module.constructFunction(
            span: span(at),
            name: module.makeIdentifier(name),
            parameters: module.makeList(parameters),
            returnType: returnType,
            body: body,
            attributes: module.makeList(attributes),
            returnAttributes: module.makeList(returnAttributes)
        )
        module.append(module.declarations, .function(function))
    }
}

/// `allNodeKindsSource` as `WGSL::parse` leaves it, or (`afterCheck`) as `staticCheck` leaves it.
func buildAllNodeKinds(afterCheck: Bool) -> ShaderModule {
    var b = AllNodeKindsBuilder()

    // diagnostic(off, derivative_uniformity);
    let directive = b.module.construct(
        span: b.span("1:0:0:53"),
        .diagnosticDirective(DiagnosticDirective(diagnostic: Diagnostic(severity: .off, triggeringRule: .derivativeUniformity)))
    )
    b.module.append(b.module.directives, directive)

    // alias Scalar = f32;
    let alias = b.module.constructTypeAlias(
        span: b.span("4:0:53:20"),
        name: b.module.makeIdentifier("Scalar"),
        type: b.identifier("f32", "4:15:68:3")
    )
    b.module.append(b.module.declarations, .typeAlias(alias))

    // const_assert 1 < 2;
    let assertion = b.module.constructConstAssert(
        span: b.span("5:0:73:21"),
        test: b.binary(.lessThan, b.int(1, "5:13:86:2"), b.int(2, "5:17:90:1"), "5:15:88:3")
    )
    b.module.append(b.module.declarations, .constAssert(assertion))

    // struct Data { @align(16) @size(32) value: vec4<f32>, items: array<u32, 4>, }
    let value = b.member(
        "value",
        "8:4:112:37",
        [
            b.attribute(.alignAttribute(AlignAttribute(alignment: b.int(16, "8:11:119:2"))), "8:4:112:11"),
            b.attribute(.sizeAttribute(SizeAttribute(size: b.int(32, "8:21:129:2"))), "8:15:123:10"),
        ],
        b.elaborated("vec4", [b.identifier("f32", "8:37:145:3")], "8:32:140:9")
    )
    let itemsType = b.module.construct(
        span: b.span("9:16:167:8"),
        ArrayTypeExpression(maybeElementType: b.identifier("u32", "9:17:168:3"), maybeElementCount: b.int(4, "9:22:173:1"))
    )
    let items = b.member("items", "9:4:155:20", [], itemsType)
    let data = b.module.constructStructure(
        span: b.span("7:0:94:86"),
        name: b.module.makeIdentifier("Data"),
        members: b.module.makeList([value, items]),
        role: .userDefined
    )
    b.module.append(b.module.declarations, .structure(data))

    // struct VertexOut { @builtin(position) @invariant position: vec4f, @location(0) @interpolate(flat) id: u32, }
    let position = b.member(
        "position",
        "13:4:203:45",
        [
            b.attribute(.builtinAttribute(BuiltinAttribute(builtin: .position)), "13:4:203:19"),
            b.attribute(.invariantAttribute(InvariantAttribute()), "13:23:222:11"),
        ],
        b.identifier("vec4f", "13:44:243:5")
    )
    let id = b.member(
        "id",
        "14:4:254:39",
        [
            b.attribute(.locationAttribute(LocationAttribute(location: b.int(0, "14:14:264:1"))), "14:4:254:13"),
            b.attribute(.interpolateAttribute(InterpolateAttribute(type: .flat, sampling: .first)), "14:17:267:19"),
        ],
        b.identifier("u32", "14:40:290:3")
    )
    let vertexOut = b.module.constructStructure(
        span: b.span("12:0:180:118"),
        name: b.module.makeIdentifier("VertexOut"),
        members: b.module.makeList([position, id]),
        role: .userDefined
    )
    b.module.append(b.module.declarations, .structure(vertexOut))

    // @group(0) @binding(0) var<storage, read_write> data: Data;
    let dataVariable = b.variable(
        .var,
        "data",
        "17:22:320:35",
        attributes: [
            b.attribute(.groupAttribute(GroupAttribute(group: b.int(0, "17:7:305:1"))), "17:0:298:10"),
            b.attribute(.bindingAttribute(BindingAttribute(binding: b.int(0, "17:19:317:1"))), "17:10:308:12"),
        ],
        qualifier: VariableQualifier(
            span: b.span("17:25:323:22"),
            addressSpace: .storage,
            accessMode: .readWrite,
            hasExplicitAccessMode: true
        ),
        type: b.identifier("Data", "17:53:351:4")
    )
    b.module.append(b.module.declarations, .variable(dataVariable))

    // @id(7) override scale: Scalar = 1.0;
    let scale = b.variable(
        .override,
        "scale",
        "18:7:364:28",
        attributes: [b.attribute(.idAttribute(IdAttribute(value: b.int(7, "18:4:361:1"))), "18:0:357:7")],
        type: b.identifier("Scalar", "18:23:380:7"),
        initializer: b.float(1, "18:32:389:3")
    )
    b.module.append(b.module.declarations, .variable(scale))

    // var<private> counter: i32 = 1i;
    let counter = b.variable(
        .var,
        "counter",
        "19:0:394:30",
        qualifier: VariableQualifier(span: b.span("19:3:397:10"), addressSpace: .private, accessMode: .readWrite),
        type: b.identifier("i32", "19:22:416:4"),
        initializer: b.module.construct(span: b.span("19:28:422:2"), Signed32Literal(value: 1))
    )
    b.module.append(b.module.declarations, .variable(counter))

    // @must_use fn helper(a: f32, b: ptr<function, f32>) -> f32 { return a + *b; }
    let helperReturn = b.statement(
        ReturnStatement(
            maybeExpression: b.binary(
                .add,
                b.identifier("a", "23:11:498:2"),
                b.unary(.dereference, b.identifier("b", "23:16:503:1"), "23:15:502:2"),
                "23:13:500:4"
            )
        ),
        "23:4:491:13"
    )
    b.function(
        "helper",
        "22:0:437:72",
        attributes: [b.attribute(.mustUseAttribute(MustUseAttribute()), "21:0:427:10")],
        parameters: [
            b.parameter("a", "22:10:447:6", [], b.identifier("f32", "22:13:450:3")),
            b.parameter(
                "b",
                "22:18:455:21",
                [],
                b.elaborated("ptr", [b.identifier("function", "22:25:462:8"), b.identifier("f32", "22:35:472:3")], "22:21:458:18")
            ),
        ],
        returnType: b.identifier("f32", "22:44:481:4"),
        body: b.compound([], [helperReturn], "22:48:485:24")
    )

    // fn noop() @diagnostic(off, derivative_uniformity) {}
    b.function("noop", "26:0:509:54", body: b.compound([b.diagnostic()], [], "26:50:559:4"))

    // @diagnostic(off, derivative_uniformity) @fragment fn fs(@location(0) @interpolate(flat) id: u32) -> @location(0) vec4f
    let discardBody = b.compound([], [b.statement(DiscardStatement(), "32:8:712:13")], "31:18:702:29")
    let fsIf = b.statement(
        IfStatement(
            test: b.binary(
                .equal,
                b.identifier("id", "31:8:692:3"),
                b.module.construct(span: b.span("31:14:698:2"), Unsigned32Literal(value: 0)),
                "31:11:695:5"
            ),
            trueBody: discardBody,
            maybeFalseBody: nil,
            attributes: b.attributes([])
        ),
        "31:4:688:43"
    )
    let fsReturn = b.statement(
        ReturnStatement(
            maybeExpression: b.call(b.identifier("vec4f", "34:11:738:5"), [b.identifier("scale", "34:17:744:5")], "34:11:738:12")
        ),
        "34:4:731:19"
    )
    b.function(
        "fs",
        "30:0:613:142",
        attributes: [b.diagnostic("28:0:563:40"), b.attribute(.stageAttribute(StageAttribute(stage: .fragment)), "29:0:603:10")],
        parameters: [
            b.parameter(
                "id",
                "30:6:619:39",
                [
                    b.attribute(.locationAttribute(LocationAttribute(location: b.int(0, "30:16:629:1"))), "30:6:619:13"),
                    b.attribute(.interpolateAttribute(InterpolateAttribute(type: .flat, sampling: .first)), "30:19:632:19"),
                ],
                b.identifier("u32", "30:42:655:3")
            )
        ],
        returnAttributes: [b.attribute(.locationAttribute(LocationAttribute(location: b.int(0, "30:60:673:1"))), "30:50:663:13")],
        returnType: b.identifier("vec4f", "30:63:676:6"),
        body: b.compound([], [fsIf, fsReturn], "30:69:682:73")
    )

    // @vertex fn vs(@builtin(vertex_index) index: u32) -> VertexOut
    let out = b.variable(.var, "out", "39:4:823:18", type: b.identifier("VertexOut", "39:13:832:9"))
    let vsStatements = [
        b.variableStatement(out, "39:4:823:24"),
        b.statement(
            AssignmentStatement(
                lhs: b.field(b.identifier("out", "40:4:847:3"), "position", "40:4:847:13"),
                rhs: b.call(b.identifier("vec4f", "40:19:862:5"), [b.float(0, "40:25:868:3")], "40:19:862:10")
            ),
            "40:17:860:12"
        ),
        b.statement(
            AssignmentStatement(
                lhs: b.field(b.identifier("out", "41:4:878:3"), "id", "41:4:878:7"),
                rhs: b.identifier("index", "41:13:887:5")
            ),
            "41:11:885:7"
        ),
        b.statement(ReturnStatement(maybeExpression: b.identifier("out", "42:11:905:3")), "42:4:898:10"),
    ]
    b.function(
        "vs",
        "38:0:763:150",
        attributes: [b.attribute(.stageAttribute(StageAttribute(stage: .vertex)), "37:0:755:8")],
        parameters: [
            b.parameter(
                "index",
                "38:6:769:33",
                [b.attribute(.builtinAttribute(BuiltinAttribute(builtin: .vertexIndex)), "38:6:769:23")],
                b.identifier("u32", "38:36:799:3")
            )
        ],
        returnType: b.identifier("VertexOut", "38:44:807:10"),
        body: b.compound([], vsStatements, "38:54:817:96")
    )

    // @compute @workgroup_size(8, 1, 1) fn cs(@builtin(local_invocation_index) lid: u32)
    var csStatements: [StatementID] = []
    let x = b.variable(
        .var,
        "x",
        "47:4:1002:17",
        type: b.identifier("f32", "47:11:1009:4"),
        initializer: b.module.construct(span: b.span("47:17:1015:4"), Float32Literal(value: 1))
    )
    csStatements.append(b.variableStatement(x, "47:4:1002:23"))
    let helperCall = b.call(
        b.identifier("helper", "48:12:1033:6"),
        [b.identifier("x", "48:19:1040:1"), b.unary(.addressOf, b.identifier("x", "48:23:1044:1"), "48:22:1043:2")],
        "48:12:1033:13"
    )
    csStatements.append(b.variableStatement(b.variable(.let, "y", "48:4:1025:21", initializer: helperCall), "48:4:1025:27"))
    csStatements.append(
        b.variableStatement(b.variable(.const, "z", "49:4:1052:13", initializer: b.float(2, "49:14:1062:3")), "49:4:1052:19")
    )
    let h = b.variable(
        .var,
        "h",
        "50:4:1071:17",
        type: b.identifier("f16", "50:11:1078:4"),
        initializer: b.module.construct(span: b.span("50:17:1084:4"), Float16Literal(value: Half(1.0)))
    )
    csStatements.append(b.variableStatement(h, "50:4:1071:23"))
    let arrayType = b.module.construct(
        span: b.span("51:19:1109:8"),
        ArrayTypeExpression(maybeElementType: b.identifier("i32", "51:20:1110:3"), maybeElementCount: b.int(2, "51:25:1115:1"))
    )
    let arrayCall = b.call(
        arrayType,
        [b.int(1, "51:28:1118:1"), b.unary(.negate, b.int(2, "51:32:1122:1"), "51:31:1121:2")],
        "51:14:1104:20"
    )
    csStatements.append(b.variableStatement(b.variable(.var, "arr", "51:4:1094:30", initializer: arrayCall), "51:4:1094:36"))
    let pointee = b.identifier("x", "52:13:1139:1")
    let dereference: ExpressionID
    if afterCheck {
        dereference = b.module.constructIdentityExpression(span: b.span("53:4:1146:3"), expression: pointee)
    } else {
        let p = b.variable(.let, "p", "52:4:1130:10", initializer: b.unary(.addressOf, pointee, "52:12:1138:2"))
        csStatements.append(b.variableStatement(p, "52:4:1130:16"))
        dereference = b.unary(.dereference, b.identifier("p", "53:5:1147:2"), "53:4:1146:3")
    }
    csStatements.append(b.statement(AssignmentStatement(lhs: dereference, rhs: b.float(2, "53:9:1151:3")), "53:7:1149:5"))
    csStatements.append(
        b.statement(
            CompoundAssignmentStatement(
                leftExpression: b.identifier("x", "54:4:1160:2"),
                rightExpression: b.binary(.multiply, b.identifier("y", "54:9:1165:2"), b.identifier("z", "54:13:1169:1"), "54:11:1167:3"),
                operation: .add
            ),
            "54:6:1162:8"
        )
    )
    csStatements.append(
        b.statement(DecrementIncrementStatement(expression: b.identifier("counter", "55:4:1176:7"), operation: .increment), "55:11:1183:2")
    )
    csStatements.append(b.statement(PhonyAssignmentStatement(rhs: b.identifier("h", "56:8:1195:1")), "56:4:1191:5"))
    csStatements.append(
        b.statement(
            PhonyAssignmentStatement(
                rhs: b.unary(.not, b.module.construct(span: b.span("57:9:1207:4"), BoolLiteral(value: true)), "57:8:1206:5")
            ),
            "57:4:1202:9"
        )
    )
    let itemsAccess = b.module.construct(
        span: b.span("58:4:1217:14"),
        IndexAccessExpression(base: b.field(b.identifier("data", "58:4:1217:4"), "items", "58:4:1217:10"), index: b.int(0, "58:15:1228:1"))
    )
    let lidPlusOne = b.binary(
        .add,
        b.identifier("lid", "58:20:1233:4"),
        b.module.construct(span: b.span("58:26:1239:2"), Unsigned32Literal(value: 1)),
        "58:24:1237:4"
    )
    csStatements.append(b.statement(AssignmentStatement(lhs: itemsAccess, rhs: lidPlusOne), "58:18:1231:10"))

    // @diagnostic(…) for (var i = 0; i < 4; i++) @diagnostic(…) { @diagnostic(…) if (i == 1) @diagnostic(…) { continue; }
    // else if (i == 2) { break; } else @diagnostic(…) { } }
    let continueBody = b.compound([b.diagnostic()], [b.statement(ContinueStatement(), "61:12:1471:18")], "60:100:1457:34")
    let breakBody = b.compound([], [b.statement(BreakStatement(), "63:12:1522:15")], "62:27:1508:31")
    let elseBody = b.compound([b.diagnostic()], [], "64:55:1584:16")
    let elseIf = b.statement(
        IfStatement(
            test: b.binary(.equal, b.identifier("i", "62:19:1500:2"), b.int(2, "62:24:1505:1"), "62:21:1502:4"),
            trueBody: breakBody,
            maybeFalseBody: elseBody,
            attributes: b.attributes([])
        ),
        "60:8:1365:235"
    )
    let forIf = b.statement(
        IfStatement(
            test: b.binary(.equal, b.identifier("i", "60:52:1409:2"), b.int(1, "60:57:1414:1"), "60:54:1411:4"),
            trueBody: continueBody,
            maybeFalseBody: elseIf,
            attributes: b.attributes([b.diagnostic("60:8:1365:40")])
        ),
        "60:8:1365:235"
    )
    let forStatement = b.statement(
        ForStatement(
            attributes: b.attributes([b.diagnostic()]),
            maybeInitializer: b.variableStatement(
                b.variable(.var, "i", "59:49:1292:9", initializer: b.int(0, "59:57:1300:1")),
                "59:44:1287:14"
            ),
            maybeTest: b.binary(.lessThan, b.identifier("i", "59:60:1303:2"), b.int(4, "59:64:1307:1"), "59:62:1305:3"),
            maybeUpdate: b.statement(
                DecrementIncrementStatement(expression: b.identifier("i", "59:67:1310:1"), operation: .increment),
                "59:68:1311:2"
            ),
            body: b.compound([b.diagnostic()], [forIf], "59:112:1355:251")
        ),
        "59:44:1287:319"
    )
    csStatements.append(forStatement)

    // @diagnostic(…) loop @diagnostic(…) { counter--; continuing @diagnostic(…) { break if counter < 0; } }
    let continuing = Continuing(
        body: b.module.makeEmptyList(StatementID.self),
        attributes: b.attributes([b.diagnostic("69:19:1731:40")]),
        breakIf: b.binary(.lessThan, b.identifier("counter", "70:21:1794:8"), b.int(0, "70:31:1804:1"), "70:29:1802:3")
    )
    let loopBody = [
        b.statement(DecrementIncrementStatement(expression: b.identifier("counter", "68:8:1701:7"), operation: .decrement), "68:15:1708:2")
    ]
    csStatements.append(
        b.statement(
            LoopStatement(
                attributes: b.attributes([b.diagnostic("67:4:1606:40")]),
                bodyAttributes: b.attributes([b.diagnostic()]),
                body: b.module.makeList(loopBody),
                continuing: continuing
            ),
            "67:44:1646:181"
        )
    )

    // @diagnostic(…) while (counter < 2) @diagnostic(…) { counter = counter + 1; }
    let whileAssignment = b.statement(
        AssignmentStatement(
            lhs: b.identifier("counter", "74:8:1937:8"),
            rhs: b.binary(.add, b.identifier("counter", "74:18:1947:8"), b.int(1, "74:28:1957:1"), "74:26:1955:3")
        ),
        "74:16:1945:13"
    )
    csStatements.append(
        b.statement(
            WhileStatement(
                attributes: b.attributes([b.diagnostic()]),
                test: b.binary(.lessThan, b.identifier("counter", "73:51:1874:8"), b.int(2, "73:61:1884:1"), "73:59:1882:3"),
                body: b.compound([b.diagnostic()], [whileAssignment], "73:104:1927:43")
            ),
            "73:44:1867:103"
        )
    )

    // @diagnostic(…) switch (counter) @diagnostic(…) { case 0, 1: @diagnostic(…) { counter = arr[1]; }
    // default: @diagnostic(…) { } }
    let arrAccess = b.module.construct(
        span: b.span("78:22:2152:6"),
        IndexAccessExpression(base: b.identifier("arr", "78:22:2152:3"), index: b.int(1, "78:26:2156:1"))
    )
    let caseBody = b.compound(
        [b.diagnostic()],
        [b.statement(AssignmentStatement(lhs: b.identifier("counter", "78:12:2142:8"), rhs: arrAccess), "78:20:2150:8")],
        "77:59:2128:50"
    )
    let caseClause = b.module.constructSwitchClause(
        selectors: b.module.makeList([b.int(0, "77:13:2082:1"), b.int(1, "77:16:2085:1")]),
        body: caseBody
    )
    let defaultClause = b.module.constructSwitchClause(
        selectors: b.module.makeEmptyList(ExpressionID.self),
        body: b.compound([b.diagnostic()], [], "80:57:2227:16")
    )
    csStatements.append(
        b.statement(
            SwitchStatement(
                attributes: b.attributes([b.diagnostic()]),
                value: b.identifier("counter", "76:52:2018:7"),
                bodyAttributes: b.attributes([b.diagnostic("76:61:2027:40")]),
                clauses: b.module.makeList([caseClause]),
                defaultClause: defaultClause
            ),
            "76:44:2010:239"
        )
    )

    // @diagnostic(…) { const_assert true; }
    let innerAssertion = b.module.constructConstAssert(
        span: b.span("84:8:2299:23"),
        test: b.module.construct(span: b.span("84:21:2312:4"), BoolLiteral(value: true))
    )
    csStatements.append(
        b.compound([b.diagnostic()], [b.statement(ConstAssertStatement(assertion: innerAssertion), "84:8:2299:23")], "83:44:2289:39")
    )

    // noop();
    csStatements.append(
        b.module.constructCallStatement(span: b.span("86:4:2328:6"), call: b.call(b.identifier("noop", "86:4:2328:4"), [], "86:4:2328:6"))
    )

    b.function(
        "cs",
        "46:0:947:1391",
        attributes: [
            b.attribute(.stageAttribute(StageAttribute(stage: .compute)), "45:0:913:9"),
            b.attribute(
                .workgroupSizeAttribute(
                    WorkgroupSizeAttribute(x: b.int(8, "45:25:938:1"), maybeY: b.int(1, "45:28:941:1"), maybeZ: b.int(1, "45:31:944:1"))
                ),
                "45:9:922:25"
            ),
        ],
        parameters: [
            b.parameter(
                "lid",
                "46:6:953:41",
                [b.attribute(.builtinAttribute(BuiltinAttribute(builtin: .localInvocationIndex)), "46:6:953:33")],
                b.identifier("u32", "46:44:991:3")
            )
        ],
        body: b.compound([], csStatements, "46:49:996:1342")
    )
    return b.module
}

// MARK: - Tests

/// One category/per-kind hook counter.
private struct HookCounter: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var declarations = 0
    var statements = 0
    var expressions = 0
    var compoundStatements = 0
    var callStatements = 0
    var callExpressions = 0
    var identifierExpressions = 0
    var identifiers = 0

    mutating func visit(_ declaration: Declaration) {
        declarations += 1
        dispatch(declaration)
    }

    mutating func visit(_ statement: StatementID) {
        statements += 1
        dispatch(statement)
    }

    mutating func visit(_ expression: ExpressionID) {
        expressions += 1
        dispatch(expression)
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        compoundStatements += 1
        visitChildren(statement, id)
    }

    mutating func visit(_ statement: CallStatement, _ id: StatementID) {
        callStatements += 1
        visitChildren(statement, id)
    }

    mutating func visit(_ expression: CallExpression, _ id: ExpressionID) {
        callExpressions += 1
        visitChildren(expression, id)
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        identifierExpressions += 1
        visitChildren(expression, id)
    }

    mutating func visit(_ identifier: IdentifierID) {
        identifiers += 1
    }
}

/// Sets an error at every hook it reaches, so a second `setError` overwrites the first (release C++).
private struct DoubleError: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    mutating func visit(_ expression: BinaryExpression, _ id: ExpressionID) {
        setError(CompilationMessage("first", span: shaderModule.span(of: id)))
        visitChildren(expression, id)
        setError(CompilationMessage("second", span: shaderModule.span(of: expression.rightExpression)))
    }
}

private func probeSpan(_ n: UInt32) -> SourceSpan {
    SourceSpan(line: 1, lineOffset: n, offset: n, length: 1)
}

/// The module `fn f(){ g(); }`.
private func probeModule() -> ShaderModule {
    var module = ShaderModule(source: SourceText("fn f(){ g(); }"))
    let target = module.constructIdentifierExpression(span: probeSpan(8), identifier: module.makeIdentifier("g", span: probeSpan(8)))
    let call = module.construct(span: probeSpan(8), CallExpression(target: target, arguments: module.makeEmptyList(ExpressionID.self)))
    let statement = module.constructCallStatement(span: probeSpan(8), call: call)
    let body = module.construct(
        span: probeSpan(6),
        CompoundStatement(attributes: module.makeEmptyList(AttributeID.self), statements: module.makeList([statement]))
    )
    let function = module.constructFunction(
        span: probeSpan(0),
        name: module.makeIdentifier("f", span: probeSpan(3)),
        parameters: module.makeEmptyList(ParameterID.self),
        returnType: nil,
        body: body,
        attributes: module.makeEmptyList(AttributeID.self),
        returnAttributes: module.makeEmptyList(AttributeID.self)
    )
    module.append(module.declarations, .function(function))
    return module
}

/// The module `const_assert (1 + 2) + 3;`.
private func doubleErrorModule() -> ShaderModule {
    var module = ShaderModule(source: SourceText("const_assert (1 + 2) + 3;"))
    let one = module.construct(span: probeSpan(14), AbstractIntegerLiteral(value: 1))
    let two = module.construct(span: probeSpan(18), AbstractIntegerLiteral(value: 2))
    let three = module.construct(span: probeSpan(23), AbstractIntegerLiteral(value: 3))
    let inner = module.construct(span: probeSpan(16), BinaryExpression(leftExpression: one, rightExpression: two, operation: .add))
    let outer = module.construct(span: probeSpan(21), BinaryExpression(leftExpression: inner, rightExpression: three, operation: .add))
    let assertion = module.constructConstAssert(span: probeSpan(0), test: outer)
    module.append(module.declarations, .constAssert(assertion))
    return module
}

@Suite
struct WGSLTraversalOrderTests {
    @Test
    func allNodeKindsMatchesTheCxxGolden() {
        var actual = traversalSection("traversal after=parse", buildAllNodeKinds(afterCheck: false))
        actual += traversalSection("traversal after=check", buildAllNodeKinds(afterCheck: true))
        for errorAt in [3, 6, 11, 22, 134, 416, 480] {
            actual += traversalSection("traversal after=check error-at=\(errorAt)", buildAllNodeKinds(afterCheck: true), errorAt: errorAt)
        }
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false)
        let expectedLines = allNodeKindsGolden.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < actualLines.count && index < expectedLines.count && actualLines[index] == expectedLines[index] {
            index += 1
        }
        #expect(
            actual == allNodeKindsGolden,
            "first difference at line \(index + 1): \(index < actualLines.count ? String(actualLines[index]) : "<end>") != \(index < expectedLines.count ? String(expectedLines[index]) : "<end>")"
        )
    }

    @Test
    func traversalProbeHooksFire() {
        var probe = TraversalProbe(shaderModule: buildAllNodeKinds(afterCheck: false))
        probe.run()
        let parseSection = allNodeKindsGolden.split(separator: "traversal after=check")[0].split(separator: "\n")
        let binaryExpressions = probe.binaryExpressions
        let ifStatements = probe.ifStatements
        #expect(binaryExpressions == parseSection.filter { $0.hasPrefix("hook BinaryExpression ") }.count)
        #expect(ifStatements == parseSection.filter { $0.hasPrefix("hook IfStatement ") }.count)
        #expect(ifStatements == 3)
    }

    @Test
    func categoryHooksFireOnceOnTheProbe() {
        var counter = HookCounter(shaderModule: probeModule())
        counter.visitShaderModule()
        #expect(counter.declarations == 1)
        #expect(counter.statements == 1)
        #expect(counter.expressions == 1)
        #expect(counter.compoundStatements == 1)
        #expect(counter.callStatements == 1)
        #expect(counter.callExpressions == 1)
        #expect(counter.identifierExpressions == 1)
        #expect(counter.identifiers == 1)
        let result = counter.result()
        #expect(result == nil)
    }

    @Test
    func setErrorStopsCheckedVisits() {
        var recorder = TraversalRecorder(shaderModule: probeModule(), errorAt: 3)
        recorder.visitShaderModule()
        #expect(recorder.events == ["hook ShaderModule -", "cat declaration Function 1:0:0:1", "hook Function 1:0:0:1"])
        let hasError = recorder.hasError
        #expect(hasError)
        let result = recorder.result()
        #expect(result == CompilationMessage("traversal error", span: probeSpan(0)))
    }

    // Release C++ compiles the ASSERT(!hasError()) away and the second setError overwrites the first. The
    // assert is live wherever WGSL is unoptimized (CompileThread.recommendedStackSize is set exactly then).
    @Test(.enabled(if: CompileThread.recommendedStackSize == nil))
    func secondSetErrorOverwritesTheFirst() {
        var visitor = DoubleError(shaderModule: doubleErrorModule())
        visitor.visitShaderModule()
        let hasError = visitor.hasError
        #expect(hasError)
        let result = visitor.result()
        #expect(result == CompilationMessage("second", span: probeSpan(23)))
    }

    @Test
    func kindsNoSourceProduces() {
        var module = ShaderModule(source: SourceText(""))
        let constAttribute = module.construct(span: probeSpan(1), .constAttribute(ConstAttribute()))
        let element = module.constructIdentifierExpression(span: probeSpan(3), identifier: module.makeIdentifier("f32", span: probeSpan(3)))
        let reference = module.construct(span: probeSpan(2), ReferenceTypeExpression(type: element))
        let pointer = module.constructIdentifierExpression(span: probeSpan(5), identifier: module.makeIdentifier("p", span: probeSpan(5)))
        let dereference = module.construct(span: probeSpan(4), PointerDereferenceExpression(target: pointer))
        let variable = module.constructVariable(
            span: probeSpan(0),
            flavor: .const,
            name: module.makeIdentifier("v"),
            type: reference,
            initializer: nil,
            attributes: module.makeList([constAttribute])
        )
        module.append(module.declarations, .variable(variable))
        var recorder = TraversalRecorder(shaderModule: module, errorAt: 0)
        recorder.visitShaderModule()
        #expect(
            recorder.events == [
                "hook ShaderModule -",
                "cat declaration Variable 1:0:0:1",
                "hook Variable 1:0:0:1",
                "cat attribute ConstAttribute 1:1:1:1",
                "hook ConstAttribute 1:1:1:1",
                "cat expression ReferenceTypeExpression 1:2:2:1",
                "hook ReferenceTypeExpression 1:2:2:1",
                "cat expression IdentifierExpression 1:3:3:1",
                "hook IdentifierExpression 1:3:3:1",
                "hook Identifier 1:3:3:1",
            ]
        )
        recorder.events = []
        let payload = recorder.shaderModule.downcast(PointerDereferenceExpression.self, dereference)
        recorder.visit(payload, dereference)
        #expect(recorder.events == ["hook PointerDereferenceExpression 1:4:4:1"])
    }

    // The category dispatch of a PointerDereferenceExpression is C++ ASSERT_NOT_REACHED("Unhandled Expression"): a trap
    // where asserts are live, and in release no per-kind hook (its target is not visited).
    @Test(.enabled(if: CompileThread.recommendedStackSize == nil))
    func pointerDereferenceCategoryReachesNoHook() {
        var module = ShaderModule(source: SourceText(""))
        let pointer = module.constructIdentifierExpression(span: probeSpan(5), identifier: module.makeIdentifier("p", span: probeSpan(5)))
        let dereference = module.construct(span: probeSpan(4), PointerDereferenceExpression(target: pointer))
        let assertion = module.constructConstAssert(span: probeSpan(0), test: dereference)
        module.append(module.declarations, .constAssert(assertion))
        var recorder = TraversalRecorder(shaderModule: module, errorAt: 0)
        recorder.visitShaderModule()
        #expect(
            recorder.events == [
                "hook ShaderModule -",
                "cat declaration ConstAssert 1:0:0:1",
                "hook ConstAssert 1:0:0:1",
                "cat expression PointerDereferenceExpression 1:4:4:1",
            ]
        )
    }
}

// MARK: - Golden

private let allNodeKindsSource = """
    enable f16;
    diagnostic(off, derivative_uniformity);

    alias Scalar = f32;
    const_assert 1 < 2;

    struct Data {
        @align(16) @size(32) value: vec4<f32>,
        items: array<u32, 4>,
    }

    struct VertexOut {
        @builtin(position) @invariant position: vec4f,
        @location(0) @interpolate(flat) id: u32,
    }

    @group(0) @binding(0) var<storage, read_write> data: Data;
    @id(7) override scale: Scalar = 1.0;
    var<private> counter: i32 = 1i;

    @must_use
    fn helper(a: f32, b: ptr<function, f32>) -> f32 {
        return a + *b;
    }

    fn noop() @diagnostic(off, derivative_uniformity) {}

    @diagnostic(off, derivative_uniformity)
    @fragment
    fn fs(@location(0) @interpolate(flat) id: u32) -> @location(0) vec4f {
        if (id == 0u) {
            discard;
        }
        return vec4f(scale);
    }

    @vertex
    fn vs(@builtin(vertex_index) index: u32) -> VertexOut {
        var out: VertexOut;
        out.position = vec4f(0.0);
        out.id = index;
        return out;
    }

    @compute @workgroup_size(8, 1, 1)
    fn cs(@builtin(local_invocation_index) lid: u32) {
        var x: f32 = 1.0f;
        let y = helper(x, &x);
        const z = 2.0;
        var h: f16 = 1.0h;
        var arr = array<i32, 2>(1, -2);
        let p = &x;
        *p = 2.0;
        x += y * z;
        counter++;
        _ = h;
        _ = !true;
        data.items[0] = lid + 1u;
        @diagnostic(off, derivative_uniformity) for (var i = 0; i < 4; i++) @diagnostic(off, derivative_uniformity) {
            @diagnostic(off, derivative_uniformity) if (i == 1) @diagnostic(off, derivative_uniformity) {
                continue;
            } else if (i == 2) {
                break;
            } else @diagnostic(off, derivative_uniformity) {
            }
        }
        @diagnostic(off, derivative_uniformity) loop @diagnostic(off, derivative_uniformity) {
            counter--;
            continuing @diagnostic(off, derivative_uniformity) {
                break if counter < 0;
            }
        }
        @diagnostic(off, derivative_uniformity) while (counter < 2) @diagnostic(off, derivative_uniformity) {
            counter = counter + 1;
        }
        @diagnostic(off, derivative_uniformity) switch (counter) @diagnostic(off, derivative_uniformity) {
            case 0, 1: @diagnostic(off, derivative_uniformity) {
                counter = arr[1];
            }
            default: @diagnostic(off, derivative_uniformity) {
            }
        }
        @diagnostic(off, derivative_uniformity) {
            const_assert true;
        }
        noop();
    }

    """

private let allNodeKindsGolden = """
    traversal after=parse count=497
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    hook BinaryExpression 5:15:88:3
    cat expression AbstractIntegerLiteral 5:13:86:2
    hook AbstractIntegerLiteral 5:13:86:2
    cat expression AbstractIntegerLiteral 5:17:90:1
    hook AbstractIntegerLiteral 5:17:90:1
    cat declaration Structure 7:0:94:86
    hook Structure 7:0:94:86
    hook StructureMember 8:4:112:37
    cat attribute AlignAttribute 8:4:112:11
    hook AlignAttribute 8:4:112:11
    cat expression AbstractIntegerLiteral 8:11:119:2
    hook AbstractIntegerLiteral 8:11:119:2
    cat attribute SizeAttribute 8:15:123:10
    hook SizeAttribute 8:15:123:10
    cat expression AbstractIntegerLiteral 8:21:129:2
    hook AbstractIntegerLiteral 8:21:129:2
    cat expression ElaboratedTypeExpression 8:32:140:9
    hook ElaboratedTypeExpression 8:32:140:9
    cat expression IdentifierExpression 8:37:145:3
    hook IdentifierExpression 8:37:145:3
    hook Identifier 8:37:145:3
    hook StructureMember 9:4:155:20
    cat expression ArrayTypeExpression 9:16:167:8
    hook ArrayTypeExpression 9:16:167:8
    cat expression IdentifierExpression 9:17:168:3
    hook IdentifierExpression 9:17:168:3
    hook Identifier 9:17:168:3
    cat expression AbstractIntegerLiteral 9:22:173:1
    hook AbstractIntegerLiteral 9:22:173:1
    cat declaration Structure 12:0:180:118
    hook Structure 12:0:180:118
    hook StructureMember 13:4:203:45
    cat attribute BuiltinAttribute 13:4:203:19
    hook BuiltinAttribute 13:4:203:19
    cat attribute InvariantAttribute 13:23:222:11
    hook InvariantAttribute 13:23:222:11
    cat expression IdentifierExpression 13:44:243:5
    hook IdentifierExpression 13:44:243:5
    hook Identifier 13:44:243:5
    hook StructureMember 14:4:254:39
    cat attribute LocationAttribute 14:4:254:13
    hook LocationAttribute 14:4:254:13
    cat expression AbstractIntegerLiteral 14:14:264:1
    hook AbstractIntegerLiteral 14:14:264:1
    cat attribute InterpolateAttribute 14:17:267:19
    hook InterpolateAttribute 14:17:267:19
    cat expression IdentifierExpression 14:40:290:3
    hook IdentifierExpression 14:40:290:3
    hook Identifier 14:40:290:3
    cat declaration Variable 17:22:320:35
    hook Variable 17:22:320:35
    cat attribute GroupAttribute 17:0:298:10
    hook GroupAttribute 17:0:298:10
    cat expression AbstractIntegerLiteral 17:7:305:1
    hook AbstractIntegerLiteral 17:7:305:1
    cat attribute BindingAttribute 17:10:308:12
    hook BindingAttribute 17:10:308:12
    cat expression AbstractIntegerLiteral 17:19:317:1
    hook AbstractIntegerLiteral 17:19:317:1
    hook VariableQualifier 17:25:323:22
    cat expression IdentifierExpression 17:53:351:4
    hook IdentifierExpression 17:53:351:4
    hook Identifier 17:53:351:4
    cat declaration Variable 18:7:364:28
    hook Variable 18:7:364:28
    cat attribute IdAttribute 18:0:357:7
    hook IdAttribute 18:0:357:7
    cat expression AbstractIntegerLiteral 18:4:361:1
    hook AbstractIntegerLiteral 18:4:361:1
    cat expression IdentifierExpression 18:23:380:7
    hook IdentifierExpression 18:23:380:7
    hook Identifier 18:23:380:7
    cat expression AbstractFloatLiteral 18:32:389:3
    hook AbstractFloatLiteral 18:32:389:3
    cat declaration Variable 19:0:394:30
    hook Variable 19:0:394:30
    hook VariableQualifier 19:3:397:10
    cat expression IdentifierExpression 19:22:416:4
    hook IdentifierExpression 19:22:416:4
    hook Identifier 19:22:416:4
    cat expression Signed32Literal 19:28:422:2
    hook Signed32Literal 19:28:422:2
    cat declaration Function 22:0:437:72
    hook Function 22:0:437:72
    cat attribute MustUseAttribute 21:0:427:10
    hook MustUseAttribute 21:0:427:10
    hook Parameter 22:10:447:6
    cat expression IdentifierExpression 22:13:450:3
    hook IdentifierExpression 22:13:450:3
    hook Identifier 22:13:450:3
    hook Parameter 22:18:455:21
    cat expression ElaboratedTypeExpression 22:21:458:18
    hook ElaboratedTypeExpression 22:21:458:18
    cat expression IdentifierExpression 22:25:462:8
    hook IdentifierExpression 22:25:462:8
    hook Identifier 22:25:462:8
    cat expression IdentifierExpression 22:35:472:3
    hook IdentifierExpression 22:35:472:3
    hook Identifier 22:35:472:3
    cat expression IdentifierExpression 22:44:481:4
    hook IdentifierExpression 22:44:481:4
    hook Identifier 22:44:481:4
    hook CompoundStatement 22:48:485:24
    cat statement ReturnStatement 23:4:491:13
    hook ReturnStatement 23:4:491:13
    cat expression BinaryExpression 23:13:500:4
    hook BinaryExpression 23:13:500:4
    cat expression IdentifierExpression 23:11:498:2
    hook IdentifierExpression 23:11:498:2
    hook Identifier 23:11:498:2
    cat expression UnaryExpression 23:15:502:2
    hook UnaryExpression 23:15:502:2
    cat expression IdentifierExpression 23:16:503:1
    hook IdentifierExpression 23:16:503:1
    hook Identifier 23:16:503:1
    cat declaration Function 26:0:509:54
    hook Function 26:0:509:54
    hook CompoundStatement 26:50:559:4
    cat declaration Function 30:0:613:142
    hook Function 30:0:613:142
    cat attribute DiagnosticAttribute 28:0:563:40
    hook DiagnosticAttribute 28:0:563:40
    hook Diagnostic -
    cat attribute StageAttribute 29:0:603:10
    hook StageAttribute 29:0:603:10
    hook Parameter 30:6:619:39
    cat attribute LocationAttribute 30:6:619:13
    hook LocationAttribute 30:6:619:13
    cat expression AbstractIntegerLiteral 30:16:629:1
    hook AbstractIntegerLiteral 30:16:629:1
    cat attribute InterpolateAttribute 30:19:632:19
    hook InterpolateAttribute 30:19:632:19
    cat expression IdentifierExpression 30:42:655:3
    hook IdentifierExpression 30:42:655:3
    hook Identifier 30:42:655:3
    cat attribute LocationAttribute 30:50:663:13
    hook LocationAttribute 30:50:663:13
    cat expression AbstractIntegerLiteral 30:60:673:1
    hook AbstractIntegerLiteral 30:60:673:1
    cat expression IdentifierExpression 30:63:676:6
    hook IdentifierExpression 30:63:676:6
    hook Identifier 30:63:676:6
    hook CompoundStatement 30:69:682:73
    cat statement IfStatement 31:4:688:43
    hook IfStatement 31:4:688:43
    cat expression BinaryExpression 31:11:695:5
    hook BinaryExpression 31:11:695:5
    cat expression IdentifierExpression 31:8:692:3
    hook IdentifierExpression 31:8:692:3
    hook Identifier 31:8:692:3
    cat expression Unsigned32Literal 31:14:698:2
    hook Unsigned32Literal 31:14:698:2
    hook CompoundStatement 31:18:702:29
    cat statement DiscardStatement 32:8:712:13
    hook DiscardStatement 32:8:712:13
    cat statement ReturnStatement 34:4:731:19
    hook ReturnStatement 34:4:731:19
    cat expression CallExpression 34:11:738:12
    hook CallExpression 34:11:738:12
    cat expression IdentifierExpression 34:11:738:5
    hook IdentifierExpression 34:11:738:5
    hook Identifier 34:11:738:5
    cat expression IdentifierExpression 34:17:744:5
    hook IdentifierExpression 34:17:744:5
    hook Identifier 34:17:744:5
    cat declaration Function 38:0:763:150
    hook Function 38:0:763:150
    cat attribute StageAttribute 37:0:755:8
    hook StageAttribute 37:0:755:8
    hook Parameter 38:6:769:33
    cat attribute BuiltinAttribute 38:6:769:23
    hook BuiltinAttribute 38:6:769:23
    cat expression IdentifierExpression 38:36:799:3
    hook IdentifierExpression 38:36:799:3
    hook Identifier 38:36:799:3
    cat expression IdentifierExpression 38:44:807:10
    hook IdentifierExpression 38:44:807:10
    hook Identifier 38:44:807:10
    hook CompoundStatement 38:54:817:96
    cat statement VariableStatement 39:4:823:24
    hook VariableStatement 39:4:823:24
    hook Variable 39:4:823:18
    cat expression IdentifierExpression 39:13:832:9
    hook IdentifierExpression 39:13:832:9
    hook Identifier 39:13:832:9
    cat statement AssignmentStatement 40:17:860:12
    hook AssignmentStatement 40:17:860:12
    cat expression FieldAccessExpression 40:4:847:13
    hook FieldAccessExpression 40:4:847:13
    cat expression IdentifierExpression 40:4:847:3
    hook IdentifierExpression 40:4:847:3
    hook Identifier 40:4:847:3
    cat expression CallExpression 40:19:862:10
    hook CallExpression 40:19:862:10
    cat expression IdentifierExpression 40:19:862:5
    hook IdentifierExpression 40:19:862:5
    hook Identifier 40:19:862:5
    cat expression AbstractFloatLiteral 40:25:868:3
    hook AbstractFloatLiteral 40:25:868:3
    cat statement AssignmentStatement 41:11:885:7
    hook AssignmentStatement 41:11:885:7
    cat expression FieldAccessExpression 41:4:878:7
    hook FieldAccessExpression 41:4:878:7
    cat expression IdentifierExpression 41:4:878:3
    hook IdentifierExpression 41:4:878:3
    hook Identifier 41:4:878:3
    cat expression IdentifierExpression 41:13:887:5
    hook IdentifierExpression 41:13:887:5
    hook Identifier 41:13:887:5
    cat statement ReturnStatement 42:4:898:10
    hook ReturnStatement 42:4:898:10
    cat expression IdentifierExpression 42:11:905:3
    hook IdentifierExpression 42:11:905:3
    hook Identifier 42:11:905:3
    cat declaration Function 46:0:947:1391
    hook Function 46:0:947:1391
    cat attribute StageAttribute 45:0:913:9
    hook StageAttribute 45:0:913:9
    cat attribute WorkgroupSizeAttribute 45:9:922:25
    hook WorkgroupSizeAttribute 45:9:922:25
    cat expression AbstractIntegerLiteral 45:25:938:1
    hook AbstractIntegerLiteral 45:25:938:1
    cat expression AbstractIntegerLiteral 45:28:941:1
    hook AbstractIntegerLiteral 45:28:941:1
    cat expression AbstractIntegerLiteral 45:31:944:1
    hook AbstractIntegerLiteral 45:31:944:1
    hook Parameter 46:6:953:41
    cat attribute BuiltinAttribute 46:6:953:33
    hook BuiltinAttribute 46:6:953:33
    cat expression IdentifierExpression 46:44:991:3
    hook IdentifierExpression 46:44:991:3
    hook Identifier 46:44:991:3
    hook CompoundStatement 46:49:996:1342
    cat statement VariableStatement 47:4:1002:23
    hook VariableStatement 47:4:1002:23
    hook Variable 47:4:1002:17
    cat expression IdentifierExpression 47:11:1009:4
    hook IdentifierExpression 47:11:1009:4
    hook Identifier 47:11:1009:4
    cat expression Float32Literal 47:17:1015:4
    hook Float32Literal 47:17:1015:4
    cat statement VariableStatement 48:4:1025:27
    hook VariableStatement 48:4:1025:27
    hook Variable 48:4:1025:21
    cat expression CallExpression 48:12:1033:13
    hook CallExpression 48:12:1033:13
    cat expression IdentifierExpression 48:12:1033:6
    hook IdentifierExpression 48:12:1033:6
    hook Identifier 48:12:1033:6
    cat expression IdentifierExpression 48:19:1040:1
    hook IdentifierExpression 48:19:1040:1
    hook Identifier 48:19:1040:1
    cat expression UnaryExpression 48:22:1043:2
    hook UnaryExpression 48:22:1043:2
    cat expression IdentifierExpression 48:23:1044:1
    hook IdentifierExpression 48:23:1044:1
    hook Identifier 48:23:1044:1
    cat statement VariableStatement 49:4:1052:19
    hook VariableStatement 49:4:1052:19
    hook Variable 49:4:1052:13
    cat expression AbstractFloatLiteral 49:14:1062:3
    hook AbstractFloatLiteral 49:14:1062:3
    cat statement VariableStatement 50:4:1071:23
    hook VariableStatement 50:4:1071:23
    hook Variable 50:4:1071:17
    cat expression IdentifierExpression 50:11:1078:4
    hook IdentifierExpression 50:11:1078:4
    hook Identifier 50:11:1078:4
    cat expression Float16Literal 50:17:1084:4
    hook Float16Literal 50:17:1084:4
    cat statement VariableStatement 51:4:1094:36
    hook VariableStatement 51:4:1094:36
    hook Variable 51:4:1094:30
    cat expression CallExpression 51:14:1104:20
    hook CallExpression 51:14:1104:20
    cat expression ArrayTypeExpression 51:19:1109:8
    hook ArrayTypeExpression 51:19:1109:8
    cat expression IdentifierExpression 51:20:1110:3
    hook IdentifierExpression 51:20:1110:3
    hook Identifier 51:20:1110:3
    cat expression AbstractIntegerLiteral 51:25:1115:1
    hook AbstractIntegerLiteral 51:25:1115:1
    cat expression AbstractIntegerLiteral 51:28:1118:1
    hook AbstractIntegerLiteral 51:28:1118:1
    cat expression UnaryExpression 51:31:1121:2
    hook UnaryExpression 51:31:1121:2
    cat expression AbstractIntegerLiteral 51:32:1122:1
    hook AbstractIntegerLiteral 51:32:1122:1
    cat statement VariableStatement 52:4:1130:16
    hook VariableStatement 52:4:1130:16
    hook Variable 52:4:1130:10
    cat expression UnaryExpression 52:12:1138:2
    hook UnaryExpression 52:12:1138:2
    cat expression IdentifierExpression 52:13:1139:1
    hook IdentifierExpression 52:13:1139:1
    hook Identifier 52:13:1139:1
    cat statement AssignmentStatement 53:7:1149:5
    hook AssignmentStatement 53:7:1149:5
    cat expression UnaryExpression 53:4:1146:3
    hook UnaryExpression 53:4:1146:3
    cat expression IdentifierExpression 53:5:1147:2
    hook IdentifierExpression 53:5:1147:2
    hook Identifier 53:5:1147:2
    cat expression AbstractFloatLiteral 53:9:1151:3
    hook AbstractFloatLiteral 53:9:1151:3
    cat statement CompoundAssignmentStatement 54:6:1162:8
    hook CompoundAssignmentStatement 54:6:1162:8
    cat expression IdentifierExpression 54:4:1160:2
    hook IdentifierExpression 54:4:1160:2
    hook Identifier 54:4:1160:2
    cat expression BinaryExpression 54:11:1167:3
    hook BinaryExpression 54:11:1167:3
    cat expression IdentifierExpression 54:9:1165:2
    hook IdentifierExpression 54:9:1165:2
    hook Identifier 54:9:1165:2
    cat expression IdentifierExpression 54:13:1169:1
    hook IdentifierExpression 54:13:1169:1
    hook Identifier 54:13:1169:1
    cat statement DecrementIncrementStatement 55:11:1183:2
    hook DecrementIncrementStatement 55:11:1183:2
    cat expression IdentifierExpression 55:4:1176:7
    hook IdentifierExpression 55:4:1176:7
    hook Identifier 55:4:1176:7
    cat statement PhonyAssignmentStatement 56:4:1191:5
    hook PhonyAssignmentStatement 56:4:1191:5
    cat expression IdentifierExpression 56:8:1195:1
    hook IdentifierExpression 56:8:1195:1
    hook Identifier 56:8:1195:1
    cat statement PhonyAssignmentStatement 57:4:1202:9
    hook PhonyAssignmentStatement 57:4:1202:9
    cat expression UnaryExpression 57:8:1206:5
    hook UnaryExpression 57:8:1206:5
    cat expression BoolLiteral 57:9:1207:4
    hook BoolLiteral 57:9:1207:4
    cat statement AssignmentStatement 58:18:1231:10
    hook AssignmentStatement 58:18:1231:10
    cat expression IndexAccessExpression 58:4:1217:14
    hook IndexAccessExpression 58:4:1217:14
    cat expression FieldAccessExpression 58:4:1217:10
    hook FieldAccessExpression 58:4:1217:10
    cat expression IdentifierExpression 58:4:1217:4
    hook IdentifierExpression 58:4:1217:4
    hook Identifier 58:4:1217:4
    cat expression AbstractIntegerLiteral 58:15:1228:1
    hook AbstractIntegerLiteral 58:15:1228:1
    cat expression BinaryExpression 58:24:1237:4
    hook BinaryExpression 58:24:1237:4
    cat expression IdentifierExpression 58:20:1233:4
    hook IdentifierExpression 58:20:1233:4
    hook Identifier 58:20:1233:4
    cat expression Unsigned32Literal 58:26:1239:2
    hook Unsigned32Literal 58:26:1239:2
    cat statement ForStatement 59:44:1287:319
    hook ForStatement 59:44:1287:319
    cat statement VariableStatement 59:44:1287:14
    hook VariableStatement 59:44:1287:14
    hook Variable 59:49:1292:9
    cat expression AbstractIntegerLiteral 59:57:1300:1
    hook AbstractIntegerLiteral 59:57:1300:1
    cat expression BinaryExpression 59:62:1305:3
    hook BinaryExpression 59:62:1305:3
    cat expression IdentifierExpression 59:60:1303:2
    hook IdentifierExpression 59:60:1303:2
    hook Identifier 59:60:1303:2
    cat expression AbstractIntegerLiteral 59:64:1307:1
    hook AbstractIntegerLiteral 59:64:1307:1
    cat statement DecrementIncrementStatement 59:68:1311:2
    hook DecrementIncrementStatement 59:68:1311:2
    cat expression IdentifierExpression 59:67:1310:1
    hook IdentifierExpression 59:67:1310:1
    hook Identifier 59:67:1310:1
    hook CompoundStatement 59:112:1355:251
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat attribute DiagnosticAttribute 60:8:1365:40
    hook DiagnosticAttribute 60:8:1365:40
    hook Diagnostic -
    cat expression BinaryExpression 60:54:1411:4
    hook BinaryExpression 60:54:1411:4
    cat expression IdentifierExpression 60:52:1409:2
    hook IdentifierExpression 60:52:1409:2
    hook Identifier 60:52:1409:2
    cat expression AbstractIntegerLiteral 60:57:1414:1
    hook AbstractIntegerLiteral 60:57:1414:1
    hook CompoundStatement 60:100:1457:34
    cat statement ContinueStatement 61:12:1471:18
    hook ContinueStatement 61:12:1471:18
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat expression BinaryExpression 62:21:1502:4
    hook BinaryExpression 62:21:1502:4
    cat expression IdentifierExpression 62:19:1500:2
    hook IdentifierExpression 62:19:1500:2
    hook Identifier 62:19:1500:2
    cat expression AbstractIntegerLiteral 62:24:1505:1
    hook AbstractIntegerLiteral 62:24:1505:1
    hook CompoundStatement 62:27:1508:31
    cat statement BreakStatement 63:12:1522:15
    hook BreakStatement 63:12:1522:15
    cat statement CompoundStatement 64:55:1584:16
    hook CompoundStatement 64:55:1584:16
    cat statement LoopStatement 67:44:1646:181
    hook LoopStatement 67:44:1646:181
    cat attribute DiagnosticAttribute 67:4:1606:40
    hook DiagnosticAttribute 67:4:1606:40
    hook Diagnostic -
    cat statement DecrementIncrementStatement 68:15:1708:2
    hook DecrementIncrementStatement 68:15:1708:2
    cat expression IdentifierExpression 68:8:1701:7
    hook IdentifierExpression 68:8:1701:7
    hook Identifier 68:8:1701:7
    hook Continuing -
    cat attribute DiagnosticAttribute 69:19:1731:40
    hook DiagnosticAttribute 69:19:1731:40
    hook Diagnostic -
    cat expression BinaryExpression 70:29:1802:3
    hook BinaryExpression 70:29:1802:3
    cat expression IdentifierExpression 70:21:1794:8
    hook IdentifierExpression 70:21:1794:8
    hook Identifier 70:21:1794:8
    cat expression AbstractIntegerLiteral 70:31:1804:1
    hook AbstractIntegerLiteral 70:31:1804:1
    cat statement WhileStatement 73:44:1867:103
    hook WhileStatement 73:44:1867:103
    cat expression BinaryExpression 73:59:1882:3
    hook BinaryExpression 73:59:1882:3
    cat expression IdentifierExpression 73:51:1874:8
    hook IdentifierExpression 73:51:1874:8
    hook Identifier 73:51:1874:8
    cat expression AbstractIntegerLiteral 73:61:1884:1
    hook AbstractIntegerLiteral 73:61:1884:1
    hook CompoundStatement 73:104:1927:43
    cat statement AssignmentStatement 74:16:1945:13
    hook AssignmentStatement 74:16:1945:13
    cat expression IdentifierExpression 74:8:1937:8
    hook IdentifierExpression 74:8:1937:8
    hook Identifier 74:8:1937:8
    cat expression BinaryExpression 74:26:1955:3
    hook BinaryExpression 74:26:1955:3
    cat expression IdentifierExpression 74:18:1947:8
    hook IdentifierExpression 74:18:1947:8
    hook Identifier 74:18:1947:8
    cat expression AbstractIntegerLiteral 74:28:1957:1
    hook AbstractIntegerLiteral 74:28:1957:1
    cat statement SwitchStatement 76:44:2010:239
    hook SwitchStatement 76:44:2010:239
    cat expression IdentifierExpression 76:52:2018:7
    hook IdentifierExpression 76:52:2018:7
    hook Identifier 76:52:2018:7
    cat attribute DiagnosticAttribute 76:61:2027:40
    hook DiagnosticAttribute 76:61:2027:40
    hook Diagnostic -
    hook SwitchClause -
    cat expression AbstractIntegerLiteral 77:13:2082:1
    hook AbstractIntegerLiteral 77:13:2082:1
    cat expression AbstractIntegerLiteral 77:16:2085:1
    hook AbstractIntegerLiteral 77:16:2085:1
    hook CompoundStatement 77:59:2128:50
    cat statement AssignmentStatement 78:20:2150:8
    hook AssignmentStatement 78:20:2150:8
    cat expression IdentifierExpression 78:12:2142:8
    hook IdentifierExpression 78:12:2142:8
    hook Identifier 78:12:2142:8
    cat expression IndexAccessExpression 78:22:2152:6
    hook IndexAccessExpression 78:22:2152:6
    cat expression IdentifierExpression 78:22:2152:3
    hook IdentifierExpression 78:22:2152:3
    hook Identifier 78:22:2152:3
    cat expression AbstractIntegerLiteral 78:26:2156:1
    hook AbstractIntegerLiteral 78:26:2156:1
    hook SwitchClause -
    hook CompoundStatement 80:57:2227:16
    cat statement CompoundStatement 83:44:2289:39
    hook CompoundStatement 83:44:2289:39
    cat statement ConstAssertStatement 84:8:2299:23
    hook ConstAssertStatement 84:8:2299:23
    hook ConstAssert 84:8:2299:23
    cat expression BoolLiteral 84:21:2312:4
    hook BoolLiteral 84:21:2312:4
    cat statement CallStatement 86:4:2328:6
    hook CallStatement 86:4:2328:6
    hook CallExpression 86:4:2328:6
    cat expression IdentifierExpression 86:4:2328:4
    hook IdentifierExpression 86:4:2328:4
    hook Identifier 86:4:2328:4
    traversal after=check count=489
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    hook BinaryExpression 5:15:88:3
    cat expression AbstractIntegerLiteral 5:13:86:2
    hook AbstractIntegerLiteral 5:13:86:2
    cat expression AbstractIntegerLiteral 5:17:90:1
    hook AbstractIntegerLiteral 5:17:90:1
    cat declaration Structure 7:0:94:86
    hook Structure 7:0:94:86
    hook StructureMember 8:4:112:37
    cat attribute AlignAttribute 8:4:112:11
    hook AlignAttribute 8:4:112:11
    cat expression AbstractIntegerLiteral 8:11:119:2
    hook AbstractIntegerLiteral 8:11:119:2
    cat attribute SizeAttribute 8:15:123:10
    hook SizeAttribute 8:15:123:10
    cat expression AbstractIntegerLiteral 8:21:129:2
    hook AbstractIntegerLiteral 8:21:129:2
    cat expression ElaboratedTypeExpression 8:32:140:9
    hook ElaboratedTypeExpression 8:32:140:9
    cat expression IdentifierExpression 8:37:145:3
    hook IdentifierExpression 8:37:145:3
    hook Identifier 8:37:145:3
    hook StructureMember 9:4:155:20
    cat expression ArrayTypeExpression 9:16:167:8
    hook ArrayTypeExpression 9:16:167:8
    cat expression IdentifierExpression 9:17:168:3
    hook IdentifierExpression 9:17:168:3
    hook Identifier 9:17:168:3
    cat expression AbstractIntegerLiteral 9:22:173:1
    hook AbstractIntegerLiteral 9:22:173:1
    cat declaration Structure 12:0:180:118
    hook Structure 12:0:180:118
    hook StructureMember 13:4:203:45
    cat attribute BuiltinAttribute 13:4:203:19
    hook BuiltinAttribute 13:4:203:19
    cat attribute InvariantAttribute 13:23:222:11
    hook InvariantAttribute 13:23:222:11
    cat expression IdentifierExpression 13:44:243:5
    hook IdentifierExpression 13:44:243:5
    hook Identifier 13:44:243:5
    hook StructureMember 14:4:254:39
    cat attribute LocationAttribute 14:4:254:13
    hook LocationAttribute 14:4:254:13
    cat expression AbstractIntegerLiteral 14:14:264:1
    hook AbstractIntegerLiteral 14:14:264:1
    cat attribute InterpolateAttribute 14:17:267:19
    hook InterpolateAttribute 14:17:267:19
    cat expression IdentifierExpression 14:40:290:3
    hook IdentifierExpression 14:40:290:3
    hook Identifier 14:40:290:3
    cat declaration Variable 17:22:320:35
    hook Variable 17:22:320:35
    cat attribute GroupAttribute 17:0:298:10
    hook GroupAttribute 17:0:298:10
    cat expression AbstractIntegerLiteral 17:7:305:1
    hook AbstractIntegerLiteral 17:7:305:1
    cat attribute BindingAttribute 17:10:308:12
    hook BindingAttribute 17:10:308:12
    cat expression AbstractIntegerLiteral 17:19:317:1
    hook AbstractIntegerLiteral 17:19:317:1
    hook VariableQualifier 17:25:323:22
    cat expression IdentifierExpression 17:53:351:4
    hook IdentifierExpression 17:53:351:4
    hook Identifier 17:53:351:4
    cat declaration Variable 18:7:364:28
    hook Variable 18:7:364:28
    cat attribute IdAttribute 18:0:357:7
    hook IdAttribute 18:0:357:7
    cat expression AbstractIntegerLiteral 18:4:361:1
    hook AbstractIntegerLiteral 18:4:361:1
    cat expression IdentifierExpression 18:23:380:7
    hook IdentifierExpression 18:23:380:7
    hook Identifier 18:23:380:7
    cat expression AbstractFloatLiteral 18:32:389:3
    hook AbstractFloatLiteral 18:32:389:3
    cat declaration Variable 19:0:394:30
    hook Variable 19:0:394:30
    hook VariableQualifier 19:3:397:10
    cat expression IdentifierExpression 19:22:416:4
    hook IdentifierExpression 19:22:416:4
    hook Identifier 19:22:416:4
    cat expression Signed32Literal 19:28:422:2
    hook Signed32Literal 19:28:422:2
    cat declaration Function 22:0:437:72
    hook Function 22:0:437:72
    cat attribute MustUseAttribute 21:0:427:10
    hook MustUseAttribute 21:0:427:10
    hook Parameter 22:10:447:6
    cat expression IdentifierExpression 22:13:450:3
    hook IdentifierExpression 22:13:450:3
    hook Identifier 22:13:450:3
    hook Parameter 22:18:455:21
    cat expression ElaboratedTypeExpression 22:21:458:18
    hook ElaboratedTypeExpression 22:21:458:18
    cat expression IdentifierExpression 22:25:462:8
    hook IdentifierExpression 22:25:462:8
    hook Identifier 22:25:462:8
    cat expression IdentifierExpression 22:35:472:3
    hook IdentifierExpression 22:35:472:3
    hook Identifier 22:35:472:3
    cat expression IdentifierExpression 22:44:481:4
    hook IdentifierExpression 22:44:481:4
    hook Identifier 22:44:481:4
    hook CompoundStatement 22:48:485:24
    cat statement ReturnStatement 23:4:491:13
    hook ReturnStatement 23:4:491:13
    cat expression BinaryExpression 23:13:500:4
    hook BinaryExpression 23:13:500:4
    cat expression IdentifierExpression 23:11:498:2
    hook IdentifierExpression 23:11:498:2
    hook Identifier 23:11:498:2
    cat expression UnaryExpression 23:15:502:2
    hook UnaryExpression 23:15:502:2
    cat expression IdentifierExpression 23:16:503:1
    hook IdentifierExpression 23:16:503:1
    hook Identifier 23:16:503:1
    cat declaration Function 26:0:509:54
    hook Function 26:0:509:54
    hook CompoundStatement 26:50:559:4
    cat declaration Function 30:0:613:142
    hook Function 30:0:613:142
    cat attribute DiagnosticAttribute 28:0:563:40
    hook DiagnosticAttribute 28:0:563:40
    hook Diagnostic -
    cat attribute StageAttribute 29:0:603:10
    hook StageAttribute 29:0:603:10
    hook Parameter 30:6:619:39
    cat attribute LocationAttribute 30:6:619:13
    hook LocationAttribute 30:6:619:13
    cat expression AbstractIntegerLiteral 30:16:629:1
    hook AbstractIntegerLiteral 30:16:629:1
    cat attribute InterpolateAttribute 30:19:632:19
    hook InterpolateAttribute 30:19:632:19
    cat expression IdentifierExpression 30:42:655:3
    hook IdentifierExpression 30:42:655:3
    hook Identifier 30:42:655:3
    cat attribute LocationAttribute 30:50:663:13
    hook LocationAttribute 30:50:663:13
    cat expression AbstractIntegerLiteral 30:60:673:1
    hook AbstractIntegerLiteral 30:60:673:1
    cat expression IdentifierExpression 30:63:676:6
    hook IdentifierExpression 30:63:676:6
    hook Identifier 30:63:676:6
    hook CompoundStatement 30:69:682:73
    cat statement IfStatement 31:4:688:43
    hook IfStatement 31:4:688:43
    cat expression BinaryExpression 31:11:695:5
    hook BinaryExpression 31:11:695:5
    cat expression IdentifierExpression 31:8:692:3
    hook IdentifierExpression 31:8:692:3
    hook Identifier 31:8:692:3
    cat expression Unsigned32Literal 31:14:698:2
    hook Unsigned32Literal 31:14:698:2
    hook CompoundStatement 31:18:702:29
    cat statement DiscardStatement 32:8:712:13
    hook DiscardStatement 32:8:712:13
    cat statement ReturnStatement 34:4:731:19
    hook ReturnStatement 34:4:731:19
    cat expression CallExpression 34:11:738:12
    hook CallExpression 34:11:738:12
    cat expression IdentifierExpression 34:11:738:5
    hook IdentifierExpression 34:11:738:5
    hook Identifier 34:11:738:5
    cat expression IdentifierExpression 34:17:744:5
    hook IdentifierExpression 34:17:744:5
    hook Identifier 34:17:744:5
    cat declaration Function 38:0:763:150
    hook Function 38:0:763:150
    cat attribute StageAttribute 37:0:755:8
    hook StageAttribute 37:0:755:8
    hook Parameter 38:6:769:33
    cat attribute BuiltinAttribute 38:6:769:23
    hook BuiltinAttribute 38:6:769:23
    cat expression IdentifierExpression 38:36:799:3
    hook IdentifierExpression 38:36:799:3
    hook Identifier 38:36:799:3
    cat expression IdentifierExpression 38:44:807:10
    hook IdentifierExpression 38:44:807:10
    hook Identifier 38:44:807:10
    hook CompoundStatement 38:54:817:96
    cat statement VariableStatement 39:4:823:24
    hook VariableStatement 39:4:823:24
    hook Variable 39:4:823:18
    cat expression IdentifierExpression 39:13:832:9
    hook IdentifierExpression 39:13:832:9
    hook Identifier 39:13:832:9
    cat statement AssignmentStatement 40:17:860:12
    hook AssignmentStatement 40:17:860:12
    cat expression FieldAccessExpression 40:4:847:13
    hook FieldAccessExpression 40:4:847:13
    cat expression IdentifierExpression 40:4:847:3
    hook IdentifierExpression 40:4:847:3
    hook Identifier 40:4:847:3
    cat expression CallExpression 40:19:862:10
    hook CallExpression 40:19:862:10
    cat expression IdentifierExpression 40:19:862:5
    hook IdentifierExpression 40:19:862:5
    hook Identifier 40:19:862:5
    cat expression AbstractFloatLiteral 40:25:868:3
    hook AbstractFloatLiteral 40:25:868:3
    cat statement AssignmentStatement 41:11:885:7
    hook AssignmentStatement 41:11:885:7
    cat expression FieldAccessExpression 41:4:878:7
    hook FieldAccessExpression 41:4:878:7
    cat expression IdentifierExpression 41:4:878:3
    hook IdentifierExpression 41:4:878:3
    hook Identifier 41:4:878:3
    cat expression IdentifierExpression 41:13:887:5
    hook IdentifierExpression 41:13:887:5
    hook Identifier 41:13:887:5
    cat statement ReturnStatement 42:4:898:10
    hook ReturnStatement 42:4:898:10
    cat expression IdentifierExpression 42:11:905:3
    hook IdentifierExpression 42:11:905:3
    hook Identifier 42:11:905:3
    cat declaration Function 46:0:947:1391
    hook Function 46:0:947:1391
    cat attribute StageAttribute 45:0:913:9
    hook StageAttribute 45:0:913:9
    cat attribute WorkgroupSizeAttribute 45:9:922:25
    hook WorkgroupSizeAttribute 45:9:922:25
    cat expression AbstractIntegerLiteral 45:25:938:1
    hook AbstractIntegerLiteral 45:25:938:1
    cat expression AbstractIntegerLiteral 45:28:941:1
    hook AbstractIntegerLiteral 45:28:941:1
    cat expression AbstractIntegerLiteral 45:31:944:1
    hook AbstractIntegerLiteral 45:31:944:1
    hook Parameter 46:6:953:41
    cat attribute BuiltinAttribute 46:6:953:33
    hook BuiltinAttribute 46:6:953:33
    cat expression IdentifierExpression 46:44:991:3
    hook IdentifierExpression 46:44:991:3
    hook Identifier 46:44:991:3
    hook CompoundStatement 46:49:996:1342
    cat statement VariableStatement 47:4:1002:23
    hook VariableStatement 47:4:1002:23
    hook Variable 47:4:1002:17
    cat expression IdentifierExpression 47:11:1009:4
    hook IdentifierExpression 47:11:1009:4
    hook Identifier 47:11:1009:4
    cat expression Float32Literal 47:17:1015:4
    hook Float32Literal 47:17:1015:4
    cat statement VariableStatement 48:4:1025:27
    hook VariableStatement 48:4:1025:27
    hook Variable 48:4:1025:21
    cat expression CallExpression 48:12:1033:13
    hook CallExpression 48:12:1033:13
    cat expression IdentifierExpression 48:12:1033:6
    hook IdentifierExpression 48:12:1033:6
    hook Identifier 48:12:1033:6
    cat expression IdentifierExpression 48:19:1040:1
    hook IdentifierExpression 48:19:1040:1
    hook Identifier 48:19:1040:1
    cat expression UnaryExpression 48:22:1043:2
    hook UnaryExpression 48:22:1043:2
    cat expression IdentifierExpression 48:23:1044:1
    hook IdentifierExpression 48:23:1044:1
    hook Identifier 48:23:1044:1
    cat statement VariableStatement 49:4:1052:19
    hook VariableStatement 49:4:1052:19
    hook Variable 49:4:1052:13
    cat expression AbstractFloatLiteral 49:14:1062:3
    hook AbstractFloatLiteral 49:14:1062:3
    cat statement VariableStatement 50:4:1071:23
    hook VariableStatement 50:4:1071:23
    hook Variable 50:4:1071:17
    cat expression IdentifierExpression 50:11:1078:4
    hook IdentifierExpression 50:11:1078:4
    hook Identifier 50:11:1078:4
    cat expression Float16Literal 50:17:1084:4
    hook Float16Literal 50:17:1084:4
    cat statement VariableStatement 51:4:1094:36
    hook VariableStatement 51:4:1094:36
    hook Variable 51:4:1094:30
    cat expression CallExpression 51:14:1104:20
    hook CallExpression 51:14:1104:20
    cat expression ArrayTypeExpression 51:19:1109:8
    hook ArrayTypeExpression 51:19:1109:8
    cat expression IdentifierExpression 51:20:1110:3
    hook IdentifierExpression 51:20:1110:3
    hook Identifier 51:20:1110:3
    cat expression AbstractIntegerLiteral 51:25:1115:1
    hook AbstractIntegerLiteral 51:25:1115:1
    cat expression AbstractIntegerLiteral 51:28:1118:1
    hook AbstractIntegerLiteral 51:28:1118:1
    cat expression UnaryExpression 51:31:1121:2
    hook UnaryExpression 51:31:1121:2
    cat expression AbstractIntegerLiteral 51:32:1122:1
    hook AbstractIntegerLiteral 51:32:1122:1
    cat statement AssignmentStatement 53:7:1149:5
    hook AssignmentStatement 53:7:1149:5
    cat expression IdentityExpression 53:4:1146:3
    hook IdentityExpression 53:4:1146:3
    cat expression IdentifierExpression 52:13:1139:1
    hook IdentifierExpression 52:13:1139:1
    hook Identifier 52:13:1139:1
    cat expression AbstractFloatLiteral 53:9:1151:3
    hook AbstractFloatLiteral 53:9:1151:3
    cat statement CompoundAssignmentStatement 54:6:1162:8
    hook CompoundAssignmentStatement 54:6:1162:8
    cat expression IdentifierExpression 54:4:1160:2
    hook IdentifierExpression 54:4:1160:2
    hook Identifier 54:4:1160:2
    cat expression BinaryExpression 54:11:1167:3
    hook BinaryExpression 54:11:1167:3
    cat expression IdentifierExpression 54:9:1165:2
    hook IdentifierExpression 54:9:1165:2
    hook Identifier 54:9:1165:2
    cat expression IdentifierExpression 54:13:1169:1
    hook IdentifierExpression 54:13:1169:1
    hook Identifier 54:13:1169:1
    cat statement DecrementIncrementStatement 55:11:1183:2
    hook DecrementIncrementStatement 55:11:1183:2
    cat expression IdentifierExpression 55:4:1176:7
    hook IdentifierExpression 55:4:1176:7
    hook Identifier 55:4:1176:7
    cat statement PhonyAssignmentStatement 56:4:1191:5
    hook PhonyAssignmentStatement 56:4:1191:5
    cat expression IdentifierExpression 56:8:1195:1
    hook IdentifierExpression 56:8:1195:1
    hook Identifier 56:8:1195:1
    cat statement PhonyAssignmentStatement 57:4:1202:9
    hook PhonyAssignmentStatement 57:4:1202:9
    cat expression UnaryExpression 57:8:1206:5
    hook UnaryExpression 57:8:1206:5
    cat expression BoolLiteral 57:9:1207:4
    hook BoolLiteral 57:9:1207:4
    cat statement AssignmentStatement 58:18:1231:10
    hook AssignmentStatement 58:18:1231:10
    cat expression IndexAccessExpression 58:4:1217:14
    hook IndexAccessExpression 58:4:1217:14
    cat expression FieldAccessExpression 58:4:1217:10
    hook FieldAccessExpression 58:4:1217:10
    cat expression IdentifierExpression 58:4:1217:4
    hook IdentifierExpression 58:4:1217:4
    hook Identifier 58:4:1217:4
    cat expression AbstractIntegerLiteral 58:15:1228:1
    hook AbstractIntegerLiteral 58:15:1228:1
    cat expression BinaryExpression 58:24:1237:4
    hook BinaryExpression 58:24:1237:4
    cat expression IdentifierExpression 58:20:1233:4
    hook IdentifierExpression 58:20:1233:4
    hook Identifier 58:20:1233:4
    cat expression Unsigned32Literal 58:26:1239:2
    hook Unsigned32Literal 58:26:1239:2
    cat statement ForStatement 59:44:1287:319
    hook ForStatement 59:44:1287:319
    cat statement VariableStatement 59:44:1287:14
    hook VariableStatement 59:44:1287:14
    hook Variable 59:49:1292:9
    cat expression AbstractIntegerLiteral 59:57:1300:1
    hook AbstractIntegerLiteral 59:57:1300:1
    cat expression BinaryExpression 59:62:1305:3
    hook BinaryExpression 59:62:1305:3
    cat expression IdentifierExpression 59:60:1303:2
    hook IdentifierExpression 59:60:1303:2
    hook Identifier 59:60:1303:2
    cat expression AbstractIntegerLiteral 59:64:1307:1
    hook AbstractIntegerLiteral 59:64:1307:1
    cat statement DecrementIncrementStatement 59:68:1311:2
    hook DecrementIncrementStatement 59:68:1311:2
    cat expression IdentifierExpression 59:67:1310:1
    hook IdentifierExpression 59:67:1310:1
    hook Identifier 59:67:1310:1
    hook CompoundStatement 59:112:1355:251
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat attribute DiagnosticAttribute 60:8:1365:40
    hook DiagnosticAttribute 60:8:1365:40
    hook Diagnostic -
    cat expression BinaryExpression 60:54:1411:4
    hook BinaryExpression 60:54:1411:4
    cat expression IdentifierExpression 60:52:1409:2
    hook IdentifierExpression 60:52:1409:2
    hook Identifier 60:52:1409:2
    cat expression AbstractIntegerLiteral 60:57:1414:1
    hook AbstractIntegerLiteral 60:57:1414:1
    hook CompoundStatement 60:100:1457:34
    cat statement ContinueStatement 61:12:1471:18
    hook ContinueStatement 61:12:1471:18
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat expression BinaryExpression 62:21:1502:4
    hook BinaryExpression 62:21:1502:4
    cat expression IdentifierExpression 62:19:1500:2
    hook IdentifierExpression 62:19:1500:2
    hook Identifier 62:19:1500:2
    cat expression AbstractIntegerLiteral 62:24:1505:1
    hook AbstractIntegerLiteral 62:24:1505:1
    hook CompoundStatement 62:27:1508:31
    cat statement BreakStatement 63:12:1522:15
    hook BreakStatement 63:12:1522:15
    cat statement CompoundStatement 64:55:1584:16
    hook CompoundStatement 64:55:1584:16
    cat statement LoopStatement 67:44:1646:181
    hook LoopStatement 67:44:1646:181
    cat attribute DiagnosticAttribute 67:4:1606:40
    hook DiagnosticAttribute 67:4:1606:40
    hook Diagnostic -
    cat statement DecrementIncrementStatement 68:15:1708:2
    hook DecrementIncrementStatement 68:15:1708:2
    cat expression IdentifierExpression 68:8:1701:7
    hook IdentifierExpression 68:8:1701:7
    hook Identifier 68:8:1701:7
    hook Continuing -
    cat attribute DiagnosticAttribute 69:19:1731:40
    hook DiagnosticAttribute 69:19:1731:40
    hook Diagnostic -
    cat expression BinaryExpression 70:29:1802:3
    hook BinaryExpression 70:29:1802:3
    cat expression IdentifierExpression 70:21:1794:8
    hook IdentifierExpression 70:21:1794:8
    hook Identifier 70:21:1794:8
    cat expression AbstractIntegerLiteral 70:31:1804:1
    hook AbstractIntegerLiteral 70:31:1804:1
    cat statement WhileStatement 73:44:1867:103
    hook WhileStatement 73:44:1867:103
    cat expression BinaryExpression 73:59:1882:3
    hook BinaryExpression 73:59:1882:3
    cat expression IdentifierExpression 73:51:1874:8
    hook IdentifierExpression 73:51:1874:8
    hook Identifier 73:51:1874:8
    cat expression AbstractIntegerLiteral 73:61:1884:1
    hook AbstractIntegerLiteral 73:61:1884:1
    hook CompoundStatement 73:104:1927:43
    cat statement AssignmentStatement 74:16:1945:13
    hook AssignmentStatement 74:16:1945:13
    cat expression IdentifierExpression 74:8:1937:8
    hook IdentifierExpression 74:8:1937:8
    hook Identifier 74:8:1937:8
    cat expression BinaryExpression 74:26:1955:3
    hook BinaryExpression 74:26:1955:3
    cat expression IdentifierExpression 74:18:1947:8
    hook IdentifierExpression 74:18:1947:8
    hook Identifier 74:18:1947:8
    cat expression AbstractIntegerLiteral 74:28:1957:1
    hook AbstractIntegerLiteral 74:28:1957:1
    cat statement SwitchStatement 76:44:2010:239
    hook SwitchStatement 76:44:2010:239
    cat expression IdentifierExpression 76:52:2018:7
    hook IdentifierExpression 76:52:2018:7
    hook Identifier 76:52:2018:7
    cat attribute DiagnosticAttribute 76:61:2027:40
    hook DiagnosticAttribute 76:61:2027:40
    hook Diagnostic -
    hook SwitchClause -
    cat expression AbstractIntegerLiteral 77:13:2082:1
    hook AbstractIntegerLiteral 77:13:2082:1
    cat expression AbstractIntegerLiteral 77:16:2085:1
    hook AbstractIntegerLiteral 77:16:2085:1
    hook CompoundStatement 77:59:2128:50
    cat statement AssignmentStatement 78:20:2150:8
    hook AssignmentStatement 78:20:2150:8
    cat expression IdentifierExpression 78:12:2142:8
    hook IdentifierExpression 78:12:2142:8
    hook Identifier 78:12:2142:8
    cat expression IndexAccessExpression 78:22:2152:6
    hook IndexAccessExpression 78:22:2152:6
    cat expression IdentifierExpression 78:22:2152:3
    hook IdentifierExpression 78:22:2152:3
    hook Identifier 78:22:2152:3
    cat expression AbstractIntegerLiteral 78:26:2156:1
    hook AbstractIntegerLiteral 78:26:2156:1
    hook SwitchClause -
    hook CompoundStatement 80:57:2227:16
    cat statement CompoundStatement 83:44:2289:39
    hook CompoundStatement 83:44:2289:39
    cat statement ConstAssertStatement 84:8:2299:23
    hook ConstAssertStatement 84:8:2299:23
    hook ConstAssert 84:8:2299:23
    cat expression BoolLiteral 84:21:2312:4
    hook BoolLiteral 84:21:2312:4
    cat statement CallStatement 86:4:2328:6
    hook CallStatement 86:4:2328:6
    hook CallExpression 86:4:2328:6
    cat expression IdentifierExpression 86:4:2328:4
    hook IdentifierExpression 86:4:2328:4
    hook Identifier 86:4:2328:4
    traversal after=check error-at=3 count=4
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    traversal after=check error-at=6 count=7
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    traversal after=check error-at=11 count=12
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    traversal after=check error-at=22 count=23
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    hook BinaryExpression 5:15:88:3
    cat expression AbstractIntegerLiteral 5:13:86:2
    hook AbstractIntegerLiteral 5:13:86:2
    cat expression AbstractIntegerLiteral 5:17:90:1
    hook AbstractIntegerLiteral 5:17:90:1
    cat declaration Structure 7:0:94:86
    hook Structure 7:0:94:86
    hook StructureMember 8:4:112:37
    cat attribute AlignAttribute 8:4:112:11
    hook AlignAttribute 8:4:112:11
    cat expression AbstractIntegerLiteral 8:11:119:2
    traversal after=check error-at=134 count=135
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    hook BinaryExpression 5:15:88:3
    cat expression AbstractIntegerLiteral 5:13:86:2
    hook AbstractIntegerLiteral 5:13:86:2
    cat expression AbstractIntegerLiteral 5:17:90:1
    hook AbstractIntegerLiteral 5:17:90:1
    cat declaration Structure 7:0:94:86
    hook Structure 7:0:94:86
    hook StructureMember 8:4:112:37
    cat attribute AlignAttribute 8:4:112:11
    hook AlignAttribute 8:4:112:11
    cat expression AbstractIntegerLiteral 8:11:119:2
    hook AbstractIntegerLiteral 8:11:119:2
    cat attribute SizeAttribute 8:15:123:10
    hook SizeAttribute 8:15:123:10
    cat expression AbstractIntegerLiteral 8:21:129:2
    hook AbstractIntegerLiteral 8:21:129:2
    cat expression ElaboratedTypeExpression 8:32:140:9
    hook ElaboratedTypeExpression 8:32:140:9
    cat expression IdentifierExpression 8:37:145:3
    hook IdentifierExpression 8:37:145:3
    hook Identifier 8:37:145:3
    hook StructureMember 9:4:155:20
    cat expression ArrayTypeExpression 9:16:167:8
    hook ArrayTypeExpression 9:16:167:8
    cat expression IdentifierExpression 9:17:168:3
    hook IdentifierExpression 9:17:168:3
    hook Identifier 9:17:168:3
    cat expression AbstractIntegerLiteral 9:22:173:1
    hook AbstractIntegerLiteral 9:22:173:1
    cat declaration Structure 12:0:180:118
    hook Structure 12:0:180:118
    hook StructureMember 13:4:203:45
    cat attribute BuiltinAttribute 13:4:203:19
    hook BuiltinAttribute 13:4:203:19
    cat attribute InvariantAttribute 13:23:222:11
    hook InvariantAttribute 13:23:222:11
    cat expression IdentifierExpression 13:44:243:5
    hook IdentifierExpression 13:44:243:5
    hook Identifier 13:44:243:5
    hook StructureMember 14:4:254:39
    cat attribute LocationAttribute 14:4:254:13
    hook LocationAttribute 14:4:254:13
    cat expression AbstractIntegerLiteral 14:14:264:1
    hook AbstractIntegerLiteral 14:14:264:1
    cat attribute InterpolateAttribute 14:17:267:19
    hook InterpolateAttribute 14:17:267:19
    cat expression IdentifierExpression 14:40:290:3
    hook IdentifierExpression 14:40:290:3
    hook Identifier 14:40:290:3
    cat declaration Variable 17:22:320:35
    hook Variable 17:22:320:35
    cat attribute GroupAttribute 17:0:298:10
    hook GroupAttribute 17:0:298:10
    cat expression AbstractIntegerLiteral 17:7:305:1
    hook AbstractIntegerLiteral 17:7:305:1
    cat attribute BindingAttribute 17:10:308:12
    hook BindingAttribute 17:10:308:12
    cat expression AbstractIntegerLiteral 17:19:317:1
    hook AbstractIntegerLiteral 17:19:317:1
    hook VariableQualifier 17:25:323:22
    cat expression IdentifierExpression 17:53:351:4
    hook IdentifierExpression 17:53:351:4
    hook Identifier 17:53:351:4
    cat declaration Variable 18:7:364:28
    hook Variable 18:7:364:28
    cat attribute IdAttribute 18:0:357:7
    hook IdAttribute 18:0:357:7
    cat expression AbstractIntegerLiteral 18:4:361:1
    hook AbstractIntegerLiteral 18:4:361:1
    cat expression IdentifierExpression 18:23:380:7
    hook IdentifierExpression 18:23:380:7
    hook Identifier 18:23:380:7
    cat expression AbstractFloatLiteral 18:32:389:3
    hook AbstractFloatLiteral 18:32:389:3
    cat declaration Variable 19:0:394:30
    hook Variable 19:0:394:30
    hook VariableQualifier 19:3:397:10
    cat expression IdentifierExpression 19:22:416:4
    hook IdentifierExpression 19:22:416:4
    hook Identifier 19:22:416:4
    cat expression Signed32Literal 19:28:422:2
    hook Signed32Literal 19:28:422:2
    cat declaration Function 22:0:437:72
    hook Function 22:0:437:72
    cat attribute MustUseAttribute 21:0:427:10
    hook MustUseAttribute 21:0:427:10
    hook Parameter 22:10:447:6
    cat expression IdentifierExpression 22:13:450:3
    hook IdentifierExpression 22:13:450:3
    hook Identifier 22:13:450:3
    hook Parameter 22:18:455:21
    cat expression ElaboratedTypeExpression 22:21:458:18
    hook ElaboratedTypeExpression 22:21:458:18
    cat expression IdentifierExpression 22:25:462:8
    hook IdentifierExpression 22:25:462:8
    hook Identifier 22:25:462:8
    cat expression IdentifierExpression 22:35:472:3
    hook IdentifierExpression 22:35:472:3
    hook Identifier 22:35:472:3
    cat expression IdentifierExpression 22:44:481:4
    hook IdentifierExpression 22:44:481:4
    hook Identifier 22:44:481:4
    hook CompoundStatement 22:48:485:24
    cat statement ReturnStatement 23:4:491:13
    hook ReturnStatement 23:4:491:13
    cat expression BinaryExpression 23:13:500:4
    hook BinaryExpression 23:13:500:4
    cat expression IdentifierExpression 23:11:498:2
    hook IdentifierExpression 23:11:498:2
    hook Identifier 23:11:498:2
    cat expression UnaryExpression 23:15:502:2
    hook UnaryExpression 23:15:502:2
    cat expression IdentifierExpression 23:16:503:1
    hook IdentifierExpression 23:16:503:1
    hook Identifier 23:16:503:1
    cat declaration Function 26:0:509:54
    hook Function 26:0:509:54
    hook CompoundStatement 26:50:559:4
    cat declaration Function 30:0:613:142
    hook Function 30:0:613:142
    cat attribute DiagnosticAttribute 28:0:563:40
    hook DiagnosticAttribute 28:0:563:40
    hook Diagnostic -
    traversal after=check error-at=416 count=416
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    hook BinaryExpression 5:15:88:3
    cat expression AbstractIntegerLiteral 5:13:86:2
    hook AbstractIntegerLiteral 5:13:86:2
    cat expression AbstractIntegerLiteral 5:17:90:1
    hook AbstractIntegerLiteral 5:17:90:1
    cat declaration Structure 7:0:94:86
    hook Structure 7:0:94:86
    hook StructureMember 8:4:112:37
    cat attribute AlignAttribute 8:4:112:11
    hook AlignAttribute 8:4:112:11
    cat expression AbstractIntegerLiteral 8:11:119:2
    hook AbstractIntegerLiteral 8:11:119:2
    cat attribute SizeAttribute 8:15:123:10
    hook SizeAttribute 8:15:123:10
    cat expression AbstractIntegerLiteral 8:21:129:2
    hook AbstractIntegerLiteral 8:21:129:2
    cat expression ElaboratedTypeExpression 8:32:140:9
    hook ElaboratedTypeExpression 8:32:140:9
    cat expression IdentifierExpression 8:37:145:3
    hook IdentifierExpression 8:37:145:3
    hook Identifier 8:37:145:3
    hook StructureMember 9:4:155:20
    cat expression ArrayTypeExpression 9:16:167:8
    hook ArrayTypeExpression 9:16:167:8
    cat expression IdentifierExpression 9:17:168:3
    hook IdentifierExpression 9:17:168:3
    hook Identifier 9:17:168:3
    cat expression AbstractIntegerLiteral 9:22:173:1
    hook AbstractIntegerLiteral 9:22:173:1
    cat declaration Structure 12:0:180:118
    hook Structure 12:0:180:118
    hook StructureMember 13:4:203:45
    cat attribute BuiltinAttribute 13:4:203:19
    hook BuiltinAttribute 13:4:203:19
    cat attribute InvariantAttribute 13:23:222:11
    hook InvariantAttribute 13:23:222:11
    cat expression IdentifierExpression 13:44:243:5
    hook IdentifierExpression 13:44:243:5
    hook Identifier 13:44:243:5
    hook StructureMember 14:4:254:39
    cat attribute LocationAttribute 14:4:254:13
    hook LocationAttribute 14:4:254:13
    cat expression AbstractIntegerLiteral 14:14:264:1
    hook AbstractIntegerLiteral 14:14:264:1
    cat attribute InterpolateAttribute 14:17:267:19
    hook InterpolateAttribute 14:17:267:19
    cat expression IdentifierExpression 14:40:290:3
    hook IdentifierExpression 14:40:290:3
    hook Identifier 14:40:290:3
    cat declaration Variable 17:22:320:35
    hook Variable 17:22:320:35
    cat attribute GroupAttribute 17:0:298:10
    hook GroupAttribute 17:0:298:10
    cat expression AbstractIntegerLiteral 17:7:305:1
    hook AbstractIntegerLiteral 17:7:305:1
    cat attribute BindingAttribute 17:10:308:12
    hook BindingAttribute 17:10:308:12
    cat expression AbstractIntegerLiteral 17:19:317:1
    hook AbstractIntegerLiteral 17:19:317:1
    hook VariableQualifier 17:25:323:22
    cat expression IdentifierExpression 17:53:351:4
    hook IdentifierExpression 17:53:351:4
    hook Identifier 17:53:351:4
    cat declaration Variable 18:7:364:28
    hook Variable 18:7:364:28
    cat attribute IdAttribute 18:0:357:7
    hook IdAttribute 18:0:357:7
    cat expression AbstractIntegerLiteral 18:4:361:1
    hook AbstractIntegerLiteral 18:4:361:1
    cat expression IdentifierExpression 18:23:380:7
    hook IdentifierExpression 18:23:380:7
    hook Identifier 18:23:380:7
    cat expression AbstractFloatLiteral 18:32:389:3
    hook AbstractFloatLiteral 18:32:389:3
    cat declaration Variable 19:0:394:30
    hook Variable 19:0:394:30
    hook VariableQualifier 19:3:397:10
    cat expression IdentifierExpression 19:22:416:4
    hook IdentifierExpression 19:22:416:4
    hook Identifier 19:22:416:4
    cat expression Signed32Literal 19:28:422:2
    hook Signed32Literal 19:28:422:2
    cat declaration Function 22:0:437:72
    hook Function 22:0:437:72
    cat attribute MustUseAttribute 21:0:427:10
    hook MustUseAttribute 21:0:427:10
    hook Parameter 22:10:447:6
    cat expression IdentifierExpression 22:13:450:3
    hook IdentifierExpression 22:13:450:3
    hook Identifier 22:13:450:3
    hook Parameter 22:18:455:21
    cat expression ElaboratedTypeExpression 22:21:458:18
    hook ElaboratedTypeExpression 22:21:458:18
    cat expression IdentifierExpression 22:25:462:8
    hook IdentifierExpression 22:25:462:8
    hook Identifier 22:25:462:8
    cat expression IdentifierExpression 22:35:472:3
    hook IdentifierExpression 22:35:472:3
    hook Identifier 22:35:472:3
    cat expression IdentifierExpression 22:44:481:4
    hook IdentifierExpression 22:44:481:4
    hook Identifier 22:44:481:4
    hook CompoundStatement 22:48:485:24
    cat statement ReturnStatement 23:4:491:13
    hook ReturnStatement 23:4:491:13
    cat expression BinaryExpression 23:13:500:4
    hook BinaryExpression 23:13:500:4
    cat expression IdentifierExpression 23:11:498:2
    hook IdentifierExpression 23:11:498:2
    hook Identifier 23:11:498:2
    cat expression UnaryExpression 23:15:502:2
    hook UnaryExpression 23:15:502:2
    cat expression IdentifierExpression 23:16:503:1
    hook IdentifierExpression 23:16:503:1
    hook Identifier 23:16:503:1
    cat declaration Function 26:0:509:54
    hook Function 26:0:509:54
    hook CompoundStatement 26:50:559:4
    cat declaration Function 30:0:613:142
    hook Function 30:0:613:142
    cat attribute DiagnosticAttribute 28:0:563:40
    hook DiagnosticAttribute 28:0:563:40
    hook Diagnostic -
    cat attribute StageAttribute 29:0:603:10
    hook StageAttribute 29:0:603:10
    hook Parameter 30:6:619:39
    cat attribute LocationAttribute 30:6:619:13
    hook LocationAttribute 30:6:619:13
    cat expression AbstractIntegerLiteral 30:16:629:1
    hook AbstractIntegerLiteral 30:16:629:1
    cat attribute InterpolateAttribute 30:19:632:19
    hook InterpolateAttribute 30:19:632:19
    cat expression IdentifierExpression 30:42:655:3
    hook IdentifierExpression 30:42:655:3
    hook Identifier 30:42:655:3
    cat attribute LocationAttribute 30:50:663:13
    hook LocationAttribute 30:50:663:13
    cat expression AbstractIntegerLiteral 30:60:673:1
    hook AbstractIntegerLiteral 30:60:673:1
    cat expression IdentifierExpression 30:63:676:6
    hook IdentifierExpression 30:63:676:6
    hook Identifier 30:63:676:6
    hook CompoundStatement 30:69:682:73
    cat statement IfStatement 31:4:688:43
    hook IfStatement 31:4:688:43
    cat expression BinaryExpression 31:11:695:5
    hook BinaryExpression 31:11:695:5
    cat expression IdentifierExpression 31:8:692:3
    hook IdentifierExpression 31:8:692:3
    hook Identifier 31:8:692:3
    cat expression Unsigned32Literal 31:14:698:2
    hook Unsigned32Literal 31:14:698:2
    hook CompoundStatement 31:18:702:29
    cat statement DiscardStatement 32:8:712:13
    hook DiscardStatement 32:8:712:13
    cat statement ReturnStatement 34:4:731:19
    hook ReturnStatement 34:4:731:19
    cat expression CallExpression 34:11:738:12
    hook CallExpression 34:11:738:12
    cat expression IdentifierExpression 34:11:738:5
    hook IdentifierExpression 34:11:738:5
    hook Identifier 34:11:738:5
    cat expression IdentifierExpression 34:17:744:5
    hook IdentifierExpression 34:17:744:5
    hook Identifier 34:17:744:5
    cat declaration Function 38:0:763:150
    hook Function 38:0:763:150
    cat attribute StageAttribute 37:0:755:8
    hook StageAttribute 37:0:755:8
    hook Parameter 38:6:769:33
    cat attribute BuiltinAttribute 38:6:769:23
    hook BuiltinAttribute 38:6:769:23
    cat expression IdentifierExpression 38:36:799:3
    hook IdentifierExpression 38:36:799:3
    hook Identifier 38:36:799:3
    cat expression IdentifierExpression 38:44:807:10
    hook IdentifierExpression 38:44:807:10
    hook Identifier 38:44:807:10
    hook CompoundStatement 38:54:817:96
    cat statement VariableStatement 39:4:823:24
    hook VariableStatement 39:4:823:24
    hook Variable 39:4:823:18
    cat expression IdentifierExpression 39:13:832:9
    hook IdentifierExpression 39:13:832:9
    hook Identifier 39:13:832:9
    cat statement AssignmentStatement 40:17:860:12
    hook AssignmentStatement 40:17:860:12
    cat expression FieldAccessExpression 40:4:847:13
    hook FieldAccessExpression 40:4:847:13
    cat expression IdentifierExpression 40:4:847:3
    hook IdentifierExpression 40:4:847:3
    hook Identifier 40:4:847:3
    cat expression CallExpression 40:19:862:10
    hook CallExpression 40:19:862:10
    cat expression IdentifierExpression 40:19:862:5
    hook IdentifierExpression 40:19:862:5
    hook Identifier 40:19:862:5
    cat expression AbstractFloatLiteral 40:25:868:3
    hook AbstractFloatLiteral 40:25:868:3
    cat statement AssignmentStatement 41:11:885:7
    hook AssignmentStatement 41:11:885:7
    cat expression FieldAccessExpression 41:4:878:7
    hook FieldAccessExpression 41:4:878:7
    cat expression IdentifierExpression 41:4:878:3
    hook IdentifierExpression 41:4:878:3
    hook Identifier 41:4:878:3
    cat expression IdentifierExpression 41:13:887:5
    hook IdentifierExpression 41:13:887:5
    hook Identifier 41:13:887:5
    cat statement ReturnStatement 42:4:898:10
    hook ReturnStatement 42:4:898:10
    cat expression IdentifierExpression 42:11:905:3
    hook IdentifierExpression 42:11:905:3
    hook Identifier 42:11:905:3
    cat declaration Function 46:0:947:1391
    hook Function 46:0:947:1391
    cat attribute StageAttribute 45:0:913:9
    hook StageAttribute 45:0:913:9
    cat attribute WorkgroupSizeAttribute 45:9:922:25
    hook WorkgroupSizeAttribute 45:9:922:25
    cat expression AbstractIntegerLiteral 45:25:938:1
    hook AbstractIntegerLiteral 45:25:938:1
    cat expression AbstractIntegerLiteral 45:28:941:1
    hook AbstractIntegerLiteral 45:28:941:1
    cat expression AbstractIntegerLiteral 45:31:944:1
    hook AbstractIntegerLiteral 45:31:944:1
    hook Parameter 46:6:953:41
    cat attribute BuiltinAttribute 46:6:953:33
    hook BuiltinAttribute 46:6:953:33
    cat expression IdentifierExpression 46:44:991:3
    hook IdentifierExpression 46:44:991:3
    hook Identifier 46:44:991:3
    hook CompoundStatement 46:49:996:1342
    cat statement VariableStatement 47:4:1002:23
    hook VariableStatement 47:4:1002:23
    hook Variable 47:4:1002:17
    cat expression IdentifierExpression 47:11:1009:4
    hook IdentifierExpression 47:11:1009:4
    hook Identifier 47:11:1009:4
    cat expression Float32Literal 47:17:1015:4
    hook Float32Literal 47:17:1015:4
    cat statement VariableStatement 48:4:1025:27
    hook VariableStatement 48:4:1025:27
    hook Variable 48:4:1025:21
    cat expression CallExpression 48:12:1033:13
    hook CallExpression 48:12:1033:13
    cat expression IdentifierExpression 48:12:1033:6
    hook IdentifierExpression 48:12:1033:6
    hook Identifier 48:12:1033:6
    cat expression IdentifierExpression 48:19:1040:1
    hook IdentifierExpression 48:19:1040:1
    hook Identifier 48:19:1040:1
    cat expression UnaryExpression 48:22:1043:2
    hook UnaryExpression 48:22:1043:2
    cat expression IdentifierExpression 48:23:1044:1
    hook IdentifierExpression 48:23:1044:1
    hook Identifier 48:23:1044:1
    cat statement VariableStatement 49:4:1052:19
    hook VariableStatement 49:4:1052:19
    hook Variable 49:4:1052:13
    cat expression AbstractFloatLiteral 49:14:1062:3
    hook AbstractFloatLiteral 49:14:1062:3
    cat statement VariableStatement 50:4:1071:23
    hook VariableStatement 50:4:1071:23
    hook Variable 50:4:1071:17
    cat expression IdentifierExpression 50:11:1078:4
    hook IdentifierExpression 50:11:1078:4
    hook Identifier 50:11:1078:4
    cat expression Float16Literal 50:17:1084:4
    hook Float16Literal 50:17:1084:4
    cat statement VariableStatement 51:4:1094:36
    hook VariableStatement 51:4:1094:36
    hook Variable 51:4:1094:30
    cat expression CallExpression 51:14:1104:20
    hook CallExpression 51:14:1104:20
    cat expression ArrayTypeExpression 51:19:1109:8
    hook ArrayTypeExpression 51:19:1109:8
    cat expression IdentifierExpression 51:20:1110:3
    hook IdentifierExpression 51:20:1110:3
    hook Identifier 51:20:1110:3
    cat expression AbstractIntegerLiteral 51:25:1115:1
    hook AbstractIntegerLiteral 51:25:1115:1
    cat expression AbstractIntegerLiteral 51:28:1118:1
    hook AbstractIntegerLiteral 51:28:1118:1
    cat expression UnaryExpression 51:31:1121:2
    hook UnaryExpression 51:31:1121:2
    cat expression AbstractIntegerLiteral 51:32:1122:1
    hook AbstractIntegerLiteral 51:32:1122:1
    cat statement AssignmentStatement 53:7:1149:5
    hook AssignmentStatement 53:7:1149:5
    cat expression IdentityExpression 53:4:1146:3
    hook IdentityExpression 53:4:1146:3
    cat expression IdentifierExpression 52:13:1139:1
    hook IdentifierExpression 52:13:1139:1
    hook Identifier 52:13:1139:1
    cat expression AbstractFloatLiteral 53:9:1151:3
    hook AbstractFloatLiteral 53:9:1151:3
    cat statement CompoundAssignmentStatement 54:6:1162:8
    hook CompoundAssignmentStatement 54:6:1162:8
    cat expression IdentifierExpression 54:4:1160:2
    hook IdentifierExpression 54:4:1160:2
    hook Identifier 54:4:1160:2
    cat expression BinaryExpression 54:11:1167:3
    hook BinaryExpression 54:11:1167:3
    cat expression IdentifierExpression 54:9:1165:2
    hook IdentifierExpression 54:9:1165:2
    hook Identifier 54:9:1165:2
    cat expression IdentifierExpression 54:13:1169:1
    hook IdentifierExpression 54:13:1169:1
    hook Identifier 54:13:1169:1
    cat statement DecrementIncrementStatement 55:11:1183:2
    hook DecrementIncrementStatement 55:11:1183:2
    cat expression IdentifierExpression 55:4:1176:7
    hook IdentifierExpression 55:4:1176:7
    hook Identifier 55:4:1176:7
    cat statement PhonyAssignmentStatement 56:4:1191:5
    hook PhonyAssignmentStatement 56:4:1191:5
    cat expression IdentifierExpression 56:8:1195:1
    hook IdentifierExpression 56:8:1195:1
    hook Identifier 56:8:1195:1
    cat statement PhonyAssignmentStatement 57:4:1202:9
    hook PhonyAssignmentStatement 57:4:1202:9
    cat expression UnaryExpression 57:8:1206:5
    hook UnaryExpression 57:8:1206:5
    cat expression BoolLiteral 57:9:1207:4
    hook BoolLiteral 57:9:1207:4
    cat statement AssignmentStatement 58:18:1231:10
    hook AssignmentStatement 58:18:1231:10
    cat expression IndexAccessExpression 58:4:1217:14
    hook IndexAccessExpression 58:4:1217:14
    cat expression FieldAccessExpression 58:4:1217:10
    hook FieldAccessExpression 58:4:1217:10
    cat expression IdentifierExpression 58:4:1217:4
    hook IdentifierExpression 58:4:1217:4
    hook Identifier 58:4:1217:4
    cat expression AbstractIntegerLiteral 58:15:1228:1
    hook AbstractIntegerLiteral 58:15:1228:1
    cat expression BinaryExpression 58:24:1237:4
    hook BinaryExpression 58:24:1237:4
    cat expression IdentifierExpression 58:20:1233:4
    hook IdentifierExpression 58:20:1233:4
    hook Identifier 58:20:1233:4
    cat expression Unsigned32Literal 58:26:1239:2
    hook Unsigned32Literal 58:26:1239:2
    cat statement ForStatement 59:44:1287:319
    hook ForStatement 59:44:1287:319
    cat statement VariableStatement 59:44:1287:14
    hook VariableStatement 59:44:1287:14
    hook Variable 59:49:1292:9
    cat expression AbstractIntegerLiteral 59:57:1300:1
    hook AbstractIntegerLiteral 59:57:1300:1
    cat expression BinaryExpression 59:62:1305:3
    hook BinaryExpression 59:62:1305:3
    cat expression IdentifierExpression 59:60:1303:2
    hook IdentifierExpression 59:60:1303:2
    hook Identifier 59:60:1303:2
    cat expression AbstractIntegerLiteral 59:64:1307:1
    hook AbstractIntegerLiteral 59:64:1307:1
    cat statement DecrementIncrementStatement 59:68:1311:2
    hook DecrementIncrementStatement 59:68:1311:2
    cat expression IdentifierExpression 59:67:1310:1
    hook IdentifierExpression 59:67:1310:1
    hook Identifier 59:67:1310:1
    hook CompoundStatement 59:112:1355:251
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat attribute DiagnosticAttribute 60:8:1365:40
    hook DiagnosticAttribute 60:8:1365:40
    hook Diagnostic -
    cat expression BinaryExpression 60:54:1411:4
    hook BinaryExpression 60:54:1411:4
    cat expression IdentifierExpression 60:52:1409:2
    hook IdentifierExpression 60:52:1409:2
    hook Identifier 60:52:1409:2
    cat expression AbstractIntegerLiteral 60:57:1414:1
    hook AbstractIntegerLiteral 60:57:1414:1
    hook CompoundStatement 60:100:1457:34
    cat statement ContinueStatement 61:12:1471:18
    hook ContinueStatement 61:12:1471:18
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat expression BinaryExpression 62:21:1502:4
    hook BinaryExpression 62:21:1502:4
    cat expression IdentifierExpression 62:19:1500:2
    hook IdentifierExpression 62:19:1500:2
    hook Identifier 62:19:1500:2
    cat expression AbstractIntegerLiteral 62:24:1505:1
    hook AbstractIntegerLiteral 62:24:1505:1
    hook CompoundStatement 62:27:1508:31
    cat statement BreakStatement 63:12:1522:15
    hook BreakStatement 63:12:1522:15
    cat statement CompoundStatement 64:55:1584:16
    hook CompoundStatement 64:55:1584:16
    cat statement LoopStatement 67:44:1646:181
    hook LoopStatement 67:44:1646:181
    cat attribute DiagnosticAttribute 67:4:1606:40
    hook DiagnosticAttribute 67:4:1606:40
    hook Diagnostic -
    cat statement DecrementIncrementStatement 68:15:1708:2
    hook DecrementIncrementStatement 68:15:1708:2
    cat expression IdentifierExpression 68:8:1701:7
    hook IdentifierExpression 68:8:1701:7
    hook Identifier 68:8:1701:7
    hook Continuing -
    traversal after=check error-at=480 count=480
    hook ShaderModule -
    cat directive DiagnosticDirective 1:0:0:53
    hook DiagnosticDirective 1:0:0:53
    hook Diagnostic -
    cat declaration TypeAlias 4:0:53:20
    hook TypeAlias 4:0:53:20
    cat expression IdentifierExpression 4:15:68:3
    hook IdentifierExpression 4:15:68:3
    hook Identifier 4:15:68:3
    cat declaration ConstAssert 5:0:73:21
    hook ConstAssert 5:0:73:21
    cat expression BinaryExpression 5:15:88:3
    hook BinaryExpression 5:15:88:3
    cat expression AbstractIntegerLiteral 5:13:86:2
    hook AbstractIntegerLiteral 5:13:86:2
    cat expression AbstractIntegerLiteral 5:17:90:1
    hook AbstractIntegerLiteral 5:17:90:1
    cat declaration Structure 7:0:94:86
    hook Structure 7:0:94:86
    hook StructureMember 8:4:112:37
    cat attribute AlignAttribute 8:4:112:11
    hook AlignAttribute 8:4:112:11
    cat expression AbstractIntegerLiteral 8:11:119:2
    hook AbstractIntegerLiteral 8:11:119:2
    cat attribute SizeAttribute 8:15:123:10
    hook SizeAttribute 8:15:123:10
    cat expression AbstractIntegerLiteral 8:21:129:2
    hook AbstractIntegerLiteral 8:21:129:2
    cat expression ElaboratedTypeExpression 8:32:140:9
    hook ElaboratedTypeExpression 8:32:140:9
    cat expression IdentifierExpression 8:37:145:3
    hook IdentifierExpression 8:37:145:3
    hook Identifier 8:37:145:3
    hook StructureMember 9:4:155:20
    cat expression ArrayTypeExpression 9:16:167:8
    hook ArrayTypeExpression 9:16:167:8
    cat expression IdentifierExpression 9:17:168:3
    hook IdentifierExpression 9:17:168:3
    hook Identifier 9:17:168:3
    cat expression AbstractIntegerLiteral 9:22:173:1
    hook AbstractIntegerLiteral 9:22:173:1
    cat declaration Structure 12:0:180:118
    hook Structure 12:0:180:118
    hook StructureMember 13:4:203:45
    cat attribute BuiltinAttribute 13:4:203:19
    hook BuiltinAttribute 13:4:203:19
    cat attribute InvariantAttribute 13:23:222:11
    hook InvariantAttribute 13:23:222:11
    cat expression IdentifierExpression 13:44:243:5
    hook IdentifierExpression 13:44:243:5
    hook Identifier 13:44:243:5
    hook StructureMember 14:4:254:39
    cat attribute LocationAttribute 14:4:254:13
    hook LocationAttribute 14:4:254:13
    cat expression AbstractIntegerLiteral 14:14:264:1
    hook AbstractIntegerLiteral 14:14:264:1
    cat attribute InterpolateAttribute 14:17:267:19
    hook InterpolateAttribute 14:17:267:19
    cat expression IdentifierExpression 14:40:290:3
    hook IdentifierExpression 14:40:290:3
    hook Identifier 14:40:290:3
    cat declaration Variable 17:22:320:35
    hook Variable 17:22:320:35
    cat attribute GroupAttribute 17:0:298:10
    hook GroupAttribute 17:0:298:10
    cat expression AbstractIntegerLiteral 17:7:305:1
    hook AbstractIntegerLiteral 17:7:305:1
    cat attribute BindingAttribute 17:10:308:12
    hook BindingAttribute 17:10:308:12
    cat expression AbstractIntegerLiteral 17:19:317:1
    hook AbstractIntegerLiteral 17:19:317:1
    hook VariableQualifier 17:25:323:22
    cat expression IdentifierExpression 17:53:351:4
    hook IdentifierExpression 17:53:351:4
    hook Identifier 17:53:351:4
    cat declaration Variable 18:7:364:28
    hook Variable 18:7:364:28
    cat attribute IdAttribute 18:0:357:7
    hook IdAttribute 18:0:357:7
    cat expression AbstractIntegerLiteral 18:4:361:1
    hook AbstractIntegerLiteral 18:4:361:1
    cat expression IdentifierExpression 18:23:380:7
    hook IdentifierExpression 18:23:380:7
    hook Identifier 18:23:380:7
    cat expression AbstractFloatLiteral 18:32:389:3
    hook AbstractFloatLiteral 18:32:389:3
    cat declaration Variable 19:0:394:30
    hook Variable 19:0:394:30
    hook VariableQualifier 19:3:397:10
    cat expression IdentifierExpression 19:22:416:4
    hook IdentifierExpression 19:22:416:4
    hook Identifier 19:22:416:4
    cat expression Signed32Literal 19:28:422:2
    hook Signed32Literal 19:28:422:2
    cat declaration Function 22:0:437:72
    hook Function 22:0:437:72
    cat attribute MustUseAttribute 21:0:427:10
    hook MustUseAttribute 21:0:427:10
    hook Parameter 22:10:447:6
    cat expression IdentifierExpression 22:13:450:3
    hook IdentifierExpression 22:13:450:3
    hook Identifier 22:13:450:3
    hook Parameter 22:18:455:21
    cat expression ElaboratedTypeExpression 22:21:458:18
    hook ElaboratedTypeExpression 22:21:458:18
    cat expression IdentifierExpression 22:25:462:8
    hook IdentifierExpression 22:25:462:8
    hook Identifier 22:25:462:8
    cat expression IdentifierExpression 22:35:472:3
    hook IdentifierExpression 22:35:472:3
    hook Identifier 22:35:472:3
    cat expression IdentifierExpression 22:44:481:4
    hook IdentifierExpression 22:44:481:4
    hook Identifier 22:44:481:4
    hook CompoundStatement 22:48:485:24
    cat statement ReturnStatement 23:4:491:13
    hook ReturnStatement 23:4:491:13
    cat expression BinaryExpression 23:13:500:4
    hook BinaryExpression 23:13:500:4
    cat expression IdentifierExpression 23:11:498:2
    hook IdentifierExpression 23:11:498:2
    hook Identifier 23:11:498:2
    cat expression UnaryExpression 23:15:502:2
    hook UnaryExpression 23:15:502:2
    cat expression IdentifierExpression 23:16:503:1
    hook IdentifierExpression 23:16:503:1
    hook Identifier 23:16:503:1
    cat declaration Function 26:0:509:54
    hook Function 26:0:509:54
    hook CompoundStatement 26:50:559:4
    cat declaration Function 30:0:613:142
    hook Function 30:0:613:142
    cat attribute DiagnosticAttribute 28:0:563:40
    hook DiagnosticAttribute 28:0:563:40
    hook Diagnostic -
    cat attribute StageAttribute 29:0:603:10
    hook StageAttribute 29:0:603:10
    hook Parameter 30:6:619:39
    cat attribute LocationAttribute 30:6:619:13
    hook LocationAttribute 30:6:619:13
    cat expression AbstractIntegerLiteral 30:16:629:1
    hook AbstractIntegerLiteral 30:16:629:1
    cat attribute InterpolateAttribute 30:19:632:19
    hook InterpolateAttribute 30:19:632:19
    cat expression IdentifierExpression 30:42:655:3
    hook IdentifierExpression 30:42:655:3
    hook Identifier 30:42:655:3
    cat attribute LocationAttribute 30:50:663:13
    hook LocationAttribute 30:50:663:13
    cat expression AbstractIntegerLiteral 30:60:673:1
    hook AbstractIntegerLiteral 30:60:673:1
    cat expression IdentifierExpression 30:63:676:6
    hook IdentifierExpression 30:63:676:6
    hook Identifier 30:63:676:6
    hook CompoundStatement 30:69:682:73
    cat statement IfStatement 31:4:688:43
    hook IfStatement 31:4:688:43
    cat expression BinaryExpression 31:11:695:5
    hook BinaryExpression 31:11:695:5
    cat expression IdentifierExpression 31:8:692:3
    hook IdentifierExpression 31:8:692:3
    hook Identifier 31:8:692:3
    cat expression Unsigned32Literal 31:14:698:2
    hook Unsigned32Literal 31:14:698:2
    hook CompoundStatement 31:18:702:29
    cat statement DiscardStatement 32:8:712:13
    hook DiscardStatement 32:8:712:13
    cat statement ReturnStatement 34:4:731:19
    hook ReturnStatement 34:4:731:19
    cat expression CallExpression 34:11:738:12
    hook CallExpression 34:11:738:12
    cat expression IdentifierExpression 34:11:738:5
    hook IdentifierExpression 34:11:738:5
    hook Identifier 34:11:738:5
    cat expression IdentifierExpression 34:17:744:5
    hook IdentifierExpression 34:17:744:5
    hook Identifier 34:17:744:5
    cat declaration Function 38:0:763:150
    hook Function 38:0:763:150
    cat attribute StageAttribute 37:0:755:8
    hook StageAttribute 37:0:755:8
    hook Parameter 38:6:769:33
    cat attribute BuiltinAttribute 38:6:769:23
    hook BuiltinAttribute 38:6:769:23
    cat expression IdentifierExpression 38:36:799:3
    hook IdentifierExpression 38:36:799:3
    hook Identifier 38:36:799:3
    cat expression IdentifierExpression 38:44:807:10
    hook IdentifierExpression 38:44:807:10
    hook Identifier 38:44:807:10
    hook CompoundStatement 38:54:817:96
    cat statement VariableStatement 39:4:823:24
    hook VariableStatement 39:4:823:24
    hook Variable 39:4:823:18
    cat expression IdentifierExpression 39:13:832:9
    hook IdentifierExpression 39:13:832:9
    hook Identifier 39:13:832:9
    cat statement AssignmentStatement 40:17:860:12
    hook AssignmentStatement 40:17:860:12
    cat expression FieldAccessExpression 40:4:847:13
    hook FieldAccessExpression 40:4:847:13
    cat expression IdentifierExpression 40:4:847:3
    hook IdentifierExpression 40:4:847:3
    hook Identifier 40:4:847:3
    cat expression CallExpression 40:19:862:10
    hook CallExpression 40:19:862:10
    cat expression IdentifierExpression 40:19:862:5
    hook IdentifierExpression 40:19:862:5
    hook Identifier 40:19:862:5
    cat expression AbstractFloatLiteral 40:25:868:3
    hook AbstractFloatLiteral 40:25:868:3
    cat statement AssignmentStatement 41:11:885:7
    hook AssignmentStatement 41:11:885:7
    cat expression FieldAccessExpression 41:4:878:7
    hook FieldAccessExpression 41:4:878:7
    cat expression IdentifierExpression 41:4:878:3
    hook IdentifierExpression 41:4:878:3
    hook Identifier 41:4:878:3
    cat expression IdentifierExpression 41:13:887:5
    hook IdentifierExpression 41:13:887:5
    hook Identifier 41:13:887:5
    cat statement ReturnStatement 42:4:898:10
    hook ReturnStatement 42:4:898:10
    cat expression IdentifierExpression 42:11:905:3
    hook IdentifierExpression 42:11:905:3
    hook Identifier 42:11:905:3
    cat declaration Function 46:0:947:1391
    hook Function 46:0:947:1391
    cat attribute StageAttribute 45:0:913:9
    hook StageAttribute 45:0:913:9
    cat attribute WorkgroupSizeAttribute 45:9:922:25
    hook WorkgroupSizeAttribute 45:9:922:25
    cat expression AbstractIntegerLiteral 45:25:938:1
    hook AbstractIntegerLiteral 45:25:938:1
    cat expression AbstractIntegerLiteral 45:28:941:1
    hook AbstractIntegerLiteral 45:28:941:1
    cat expression AbstractIntegerLiteral 45:31:944:1
    hook AbstractIntegerLiteral 45:31:944:1
    hook Parameter 46:6:953:41
    cat attribute BuiltinAttribute 46:6:953:33
    hook BuiltinAttribute 46:6:953:33
    cat expression IdentifierExpression 46:44:991:3
    hook IdentifierExpression 46:44:991:3
    hook Identifier 46:44:991:3
    hook CompoundStatement 46:49:996:1342
    cat statement VariableStatement 47:4:1002:23
    hook VariableStatement 47:4:1002:23
    hook Variable 47:4:1002:17
    cat expression IdentifierExpression 47:11:1009:4
    hook IdentifierExpression 47:11:1009:4
    hook Identifier 47:11:1009:4
    cat expression Float32Literal 47:17:1015:4
    hook Float32Literal 47:17:1015:4
    cat statement VariableStatement 48:4:1025:27
    hook VariableStatement 48:4:1025:27
    hook Variable 48:4:1025:21
    cat expression CallExpression 48:12:1033:13
    hook CallExpression 48:12:1033:13
    cat expression IdentifierExpression 48:12:1033:6
    hook IdentifierExpression 48:12:1033:6
    hook Identifier 48:12:1033:6
    cat expression IdentifierExpression 48:19:1040:1
    hook IdentifierExpression 48:19:1040:1
    hook Identifier 48:19:1040:1
    cat expression UnaryExpression 48:22:1043:2
    hook UnaryExpression 48:22:1043:2
    cat expression IdentifierExpression 48:23:1044:1
    hook IdentifierExpression 48:23:1044:1
    hook Identifier 48:23:1044:1
    cat statement VariableStatement 49:4:1052:19
    hook VariableStatement 49:4:1052:19
    hook Variable 49:4:1052:13
    cat expression AbstractFloatLiteral 49:14:1062:3
    hook AbstractFloatLiteral 49:14:1062:3
    cat statement VariableStatement 50:4:1071:23
    hook VariableStatement 50:4:1071:23
    hook Variable 50:4:1071:17
    cat expression IdentifierExpression 50:11:1078:4
    hook IdentifierExpression 50:11:1078:4
    hook Identifier 50:11:1078:4
    cat expression Float16Literal 50:17:1084:4
    hook Float16Literal 50:17:1084:4
    cat statement VariableStatement 51:4:1094:36
    hook VariableStatement 51:4:1094:36
    hook Variable 51:4:1094:30
    cat expression CallExpression 51:14:1104:20
    hook CallExpression 51:14:1104:20
    cat expression ArrayTypeExpression 51:19:1109:8
    hook ArrayTypeExpression 51:19:1109:8
    cat expression IdentifierExpression 51:20:1110:3
    hook IdentifierExpression 51:20:1110:3
    hook Identifier 51:20:1110:3
    cat expression AbstractIntegerLiteral 51:25:1115:1
    hook AbstractIntegerLiteral 51:25:1115:1
    cat expression AbstractIntegerLiteral 51:28:1118:1
    hook AbstractIntegerLiteral 51:28:1118:1
    cat expression UnaryExpression 51:31:1121:2
    hook UnaryExpression 51:31:1121:2
    cat expression AbstractIntegerLiteral 51:32:1122:1
    hook AbstractIntegerLiteral 51:32:1122:1
    cat statement AssignmentStatement 53:7:1149:5
    hook AssignmentStatement 53:7:1149:5
    cat expression IdentityExpression 53:4:1146:3
    hook IdentityExpression 53:4:1146:3
    cat expression IdentifierExpression 52:13:1139:1
    hook IdentifierExpression 52:13:1139:1
    hook Identifier 52:13:1139:1
    cat expression AbstractFloatLiteral 53:9:1151:3
    hook AbstractFloatLiteral 53:9:1151:3
    cat statement CompoundAssignmentStatement 54:6:1162:8
    hook CompoundAssignmentStatement 54:6:1162:8
    cat expression IdentifierExpression 54:4:1160:2
    hook IdentifierExpression 54:4:1160:2
    hook Identifier 54:4:1160:2
    cat expression BinaryExpression 54:11:1167:3
    hook BinaryExpression 54:11:1167:3
    cat expression IdentifierExpression 54:9:1165:2
    hook IdentifierExpression 54:9:1165:2
    hook Identifier 54:9:1165:2
    cat expression IdentifierExpression 54:13:1169:1
    hook IdentifierExpression 54:13:1169:1
    hook Identifier 54:13:1169:1
    cat statement DecrementIncrementStatement 55:11:1183:2
    hook DecrementIncrementStatement 55:11:1183:2
    cat expression IdentifierExpression 55:4:1176:7
    hook IdentifierExpression 55:4:1176:7
    hook Identifier 55:4:1176:7
    cat statement PhonyAssignmentStatement 56:4:1191:5
    hook PhonyAssignmentStatement 56:4:1191:5
    cat expression IdentifierExpression 56:8:1195:1
    hook IdentifierExpression 56:8:1195:1
    hook Identifier 56:8:1195:1
    cat statement PhonyAssignmentStatement 57:4:1202:9
    hook PhonyAssignmentStatement 57:4:1202:9
    cat expression UnaryExpression 57:8:1206:5
    hook UnaryExpression 57:8:1206:5
    cat expression BoolLiteral 57:9:1207:4
    hook BoolLiteral 57:9:1207:4
    cat statement AssignmentStatement 58:18:1231:10
    hook AssignmentStatement 58:18:1231:10
    cat expression IndexAccessExpression 58:4:1217:14
    hook IndexAccessExpression 58:4:1217:14
    cat expression FieldAccessExpression 58:4:1217:10
    hook FieldAccessExpression 58:4:1217:10
    cat expression IdentifierExpression 58:4:1217:4
    hook IdentifierExpression 58:4:1217:4
    hook Identifier 58:4:1217:4
    cat expression AbstractIntegerLiteral 58:15:1228:1
    hook AbstractIntegerLiteral 58:15:1228:1
    cat expression BinaryExpression 58:24:1237:4
    hook BinaryExpression 58:24:1237:4
    cat expression IdentifierExpression 58:20:1233:4
    hook IdentifierExpression 58:20:1233:4
    hook Identifier 58:20:1233:4
    cat expression Unsigned32Literal 58:26:1239:2
    hook Unsigned32Literal 58:26:1239:2
    cat statement ForStatement 59:44:1287:319
    hook ForStatement 59:44:1287:319
    cat statement VariableStatement 59:44:1287:14
    hook VariableStatement 59:44:1287:14
    hook Variable 59:49:1292:9
    cat expression AbstractIntegerLiteral 59:57:1300:1
    hook AbstractIntegerLiteral 59:57:1300:1
    cat expression BinaryExpression 59:62:1305:3
    hook BinaryExpression 59:62:1305:3
    cat expression IdentifierExpression 59:60:1303:2
    hook IdentifierExpression 59:60:1303:2
    hook Identifier 59:60:1303:2
    cat expression AbstractIntegerLiteral 59:64:1307:1
    hook AbstractIntegerLiteral 59:64:1307:1
    cat statement DecrementIncrementStatement 59:68:1311:2
    hook DecrementIncrementStatement 59:68:1311:2
    cat expression IdentifierExpression 59:67:1310:1
    hook IdentifierExpression 59:67:1310:1
    hook Identifier 59:67:1310:1
    hook CompoundStatement 59:112:1355:251
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat attribute DiagnosticAttribute 60:8:1365:40
    hook DiagnosticAttribute 60:8:1365:40
    hook Diagnostic -
    cat expression BinaryExpression 60:54:1411:4
    hook BinaryExpression 60:54:1411:4
    cat expression IdentifierExpression 60:52:1409:2
    hook IdentifierExpression 60:52:1409:2
    hook Identifier 60:52:1409:2
    cat expression AbstractIntegerLiteral 60:57:1414:1
    hook AbstractIntegerLiteral 60:57:1414:1
    hook CompoundStatement 60:100:1457:34
    cat statement ContinueStatement 61:12:1471:18
    hook ContinueStatement 61:12:1471:18
    cat statement IfStatement 60:8:1365:235
    hook IfStatement 60:8:1365:235
    cat expression BinaryExpression 62:21:1502:4
    hook BinaryExpression 62:21:1502:4
    cat expression IdentifierExpression 62:19:1500:2
    hook IdentifierExpression 62:19:1500:2
    hook Identifier 62:19:1500:2
    cat expression AbstractIntegerLiteral 62:24:1505:1
    hook AbstractIntegerLiteral 62:24:1505:1
    hook CompoundStatement 62:27:1508:31
    cat statement BreakStatement 63:12:1522:15
    hook BreakStatement 63:12:1522:15
    cat statement CompoundStatement 64:55:1584:16
    hook CompoundStatement 64:55:1584:16
    cat statement LoopStatement 67:44:1646:181
    hook LoopStatement 67:44:1646:181
    cat attribute DiagnosticAttribute 67:4:1606:40
    hook DiagnosticAttribute 67:4:1606:40
    hook Diagnostic -
    cat statement DecrementIncrementStatement 68:15:1708:2
    hook DecrementIncrementStatement 68:15:1708:2
    cat expression IdentifierExpression 68:8:1701:7
    hook IdentifierExpression 68:8:1701:7
    hook Identifier 68:8:1701:7
    hook Continuing -
    cat attribute DiagnosticAttribute 69:19:1731:40
    hook DiagnosticAttribute 69:19:1731:40
    hook Diagnostic -
    cat expression BinaryExpression 70:29:1802:3
    hook BinaryExpression 70:29:1802:3
    cat expression IdentifierExpression 70:21:1794:8
    hook IdentifierExpression 70:21:1794:8
    hook Identifier 70:21:1794:8
    cat expression AbstractIntegerLiteral 70:31:1804:1
    hook AbstractIntegerLiteral 70:31:1804:1
    cat statement WhileStatement 73:44:1867:103
    hook WhileStatement 73:44:1867:103
    cat expression BinaryExpression 73:59:1882:3
    hook BinaryExpression 73:59:1882:3
    cat expression IdentifierExpression 73:51:1874:8
    hook IdentifierExpression 73:51:1874:8
    hook Identifier 73:51:1874:8
    cat expression AbstractIntegerLiteral 73:61:1884:1
    hook AbstractIntegerLiteral 73:61:1884:1
    hook CompoundStatement 73:104:1927:43
    cat statement AssignmentStatement 74:16:1945:13
    hook AssignmentStatement 74:16:1945:13
    cat expression IdentifierExpression 74:8:1937:8
    hook IdentifierExpression 74:8:1937:8
    hook Identifier 74:8:1937:8
    cat expression BinaryExpression 74:26:1955:3
    hook BinaryExpression 74:26:1955:3
    cat expression IdentifierExpression 74:18:1947:8
    hook IdentifierExpression 74:18:1947:8
    hook Identifier 74:18:1947:8
    cat expression AbstractIntegerLiteral 74:28:1957:1
    hook AbstractIntegerLiteral 74:28:1957:1
    cat statement SwitchStatement 76:44:2010:239
    hook SwitchStatement 76:44:2010:239
    cat expression IdentifierExpression 76:52:2018:7
    hook IdentifierExpression 76:52:2018:7
    hook Identifier 76:52:2018:7
    cat attribute DiagnosticAttribute 76:61:2027:40
    hook DiagnosticAttribute 76:61:2027:40
    hook Diagnostic -
    hook SwitchClause -
    cat expression AbstractIntegerLiteral 77:13:2082:1
    hook AbstractIntegerLiteral 77:13:2082:1
    cat expression AbstractIntegerLiteral 77:16:2085:1
    hook AbstractIntegerLiteral 77:16:2085:1
    hook CompoundStatement 77:59:2128:50
    cat statement AssignmentStatement 78:20:2150:8
    hook AssignmentStatement 78:20:2150:8
    cat expression IdentifierExpression 78:12:2142:8
    hook IdentifierExpression 78:12:2142:8
    hook Identifier 78:12:2142:8
    cat expression IndexAccessExpression 78:22:2152:6
    hook IndexAccessExpression 78:22:2152:6
    cat expression IdentifierExpression 78:22:2152:3
    hook IdentifierExpression 78:22:2152:3
    hook Identifier 78:22:2152:3
    cat expression AbstractIntegerLiteral 78:26:2156:1
    hook AbstractIntegerLiteral 78:26:2156:1
    hook SwitchClause -
    hook CompoundStatement 80:57:2227:16
    cat statement CompoundStatement 83:44:2289:39
    hook CompoundStatement 83:44:2289:39
    cat statement ConstAssertStatement 84:8:2299:23
    hook ConstAssertStatement 84:8:2299:23

    """
