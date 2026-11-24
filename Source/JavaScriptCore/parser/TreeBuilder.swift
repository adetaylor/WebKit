// Copyright (C) 2010-2019 Apple Inc. All rights reserved.
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

internal import JSCSwiftBoundary

/// A handle a tree builder returns: the null value is what a production returns when it fails.
protocol TreeHandle {
    static var null: Self { get }
    var isNull: Bool { get }
    /// The facade's node handle: the handle itself for the AST builder's, nil for the syntax checker's, which keeps no node.
    var parseNode: JSC.JSParseNode? { get }
}

extension JSC.JSParseNode: TreeHandle {
    static var null: JSC.JSParseNode { JSC.JSParseNode() }
    var isNull: Bool { index == 0 }
    var parseNode: JSC.JSParseNode? { self }
}

extension JSC.JSParseIdentifier {
    var isNull: Bool { index == 0 }
}

/// What a function declaration or expression produces: its name, body node, parameter count, length and source range.
struct FunctionInfo<Builder: TreeBuilder> {
    var name = JSC.JSParseIdentifier()
    var body = Builder.Node.null
    var parameterCount: UInt32 = 0
    var functionLength: UInt32 = 0
    var startOffset: UInt32 = 0
    var endOffset: UInt32 = 0
}

/// What a class produces: its name and source range.
typealias ClassInfo = JSC.JSParseClassInfo

// What the grammar builds with: the tree builder members the parser calls. The integer types of an offset or a
// count follow ASTBuilder's, and the facade checks each node's class when a member receives it.
protocol TreeBuilder {
    associatedtype Node: TreeHandle
    associatedtype Property: TreeHandle
    associatedtype BinaryOperand: BitwiseCopyable
    /// What entering a binary expression saves for leaving it: SyntaxChecker's top operand, nothing for the AST builder.
    associatedtype SavedBinaryExpression: BitwiseCopyable

    typealias Expression = Node
    typealias SourceElements = Node
    typealias Arguments = Node
    typealias PropertyList = Node
    typealias ElementList = Node
    typealias TemplateString = Node
    typealias TemplateLiteral = Node
    typealias FormalParameterList = Node
    typealias FunctionBody = Node
    typealias ClassExpression = Node
    typealias ModuleName = Node
    typealias ImportSpecifier = Node
    typealias ImportAttributesList = Node
    typealias ExportSpecifier = Node
    typealias Statement = Node
    typealias ClauseList = Node
    typealias Clause = Node
    typealias DestructuringPattern = Node

    static var createsAST: Bool { get }
    static var needsFreeVariableInfo: Bool { get }
    static var dontBuildKeywords: LexerFlags { get }
    static var dontBuildStrings: LexerFlags { get }

    // SyntaxChecker saves its innermost binary expression and unary token on
    // entering a production and restores them on leaving it.
    mutating func enterBinaryExpression() -> SavedBinaryExpression
    mutating func leaveBinaryExpression(_ saved: SavedBinaryExpression)
    mutating func enterUnaryExpression() -> Int32
    mutating func leaveUnaryExpression(_ saved: Int32)

    mutating func makeStaticBlockFunctionCallNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ function: Node,
        _ divot: JSC.JSTextPosition,
        _ divotStart: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) -> Node
    mutating func makeFunctionCallNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ function: Node,
        _ previousBaseWasSuper: Bool,
        _ args: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition,
        _ callOrApplyChildDepth: Int,
        _ isOptionalCall: Bool
    ) -> Node
    mutating func createSourceElements(_ facade: inout JSC.JSParseFacade) -> Node
    mutating func features(_ facade: inout JSC.JSParseFacade) -> Int32
    mutating func makePrefixNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ op: JSC.Operator,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func makePostfixNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ op: JSC.Operator,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func makeTypeOfNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func makeDeleteNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func makeNegateNode(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func makeBitwiseNotNode(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func createLogicalNot(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func createUnaryPlus(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func createVoid(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func createThisExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createSuperExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createImportExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ option: Node,
        _ deferred: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createNewTargetExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createImportMetaExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func setIsParenthesized(_ facade: inout JSC.JSParseFacade, _ expr: Node)
    mutating func isMetaProperty(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func isNewTarget(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func isImportMeta(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func createResolve(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ needToCheckUsesArguments: Bool
    ) -> Node
    mutating func createPrivateIdentifierNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier
    ) -> Node
    mutating func createObjectLiteral(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createObjectLiteral(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ properties: Node) -> Node
    mutating func createArray(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ elisions: Int32) -> Node
    mutating func createArray(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ elems: Node) -> Node
    mutating func createArray(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ elisions: Int32, _ elems: Node) -> Node
    mutating func createDoubleExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ d: Double) -> Node
    mutating func createIntegerExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ d: Double) -> Node
    mutating func createBigInt(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ bigInt: JSC.JSParseIdentifier,
        _ radix: UInt8
    ) -> Node
    mutating func createString(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ string: JSC.JSParseIdentifier) -> Node
    mutating func createBoolean(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ b: Bool) -> Node
    mutating func createNull(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createBracketAccess(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ property: Node,
        _ propertyHasAssignments: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createDotAccess(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ property: JSC.JSParseIdentifier,
        _ type: JSC.DotType,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createSpreadExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createObjectSpreadExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createTemplateString(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ cooked: JSC.JSParseIdentifier,
        _ raw: JSC.JSParseIdentifier
    ) -> Node
    mutating func createTemplateStringList(_ facade: inout JSC.JSParseFacade, _ templateString: Node) -> Node
    mutating func createTemplateStringList(_ facade: inout JSC.JSParseFacade, _ templateStringList: Node, _ templateString: Node) -> Node
    mutating func createTemplateExpressionList(_ facade: inout JSC.JSParseFacade, _ expression: Node) -> Node
    mutating func createTemplateExpressionList(
        _ facade: inout JSC.JSParseFacade,
        _ templateExpressionListNode: Node,
        _ expression: Node
    ) -> Node
    mutating func createTemplateLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ templateStringList: Node
    ) -> Node
    mutating func createTemplateLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ templateStringList: Node,
        _ templateExpressionList: Node
    ) -> Node
    mutating func createTaggedTemplate(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ templateLiteral: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createRegExp(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: JSC.JSParseIdentifier,
        _ flags: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ skipSyntaxCheck: Bool
    ) -> Node
    mutating func createNewExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ arguments: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createNewExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createOptionalChain(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ expr: Node,
        _ isOutermost: Bool
    ) -> Node
    mutating func createConditionalExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ condition: Node,
        _ lhs: Node,
        _ rhs: Node
    ) -> Node
    mutating func createAssignResolve(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ rhs: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ assignmentContext: JSC.AssignmentContext
    ) -> Node
    mutating func createYield(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createYield(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ argument: Node,
        _ delegate: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createAwait(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ argument: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createDefineField(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ initializer: Node,
        _ type: JSC.DefineFieldNode.`Type`
    ) -> Node
    mutating func createClassExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ classInfo: ClassInfo,
        _ classHeadEnvironment: JSC.JSParseEnvironment,
        _ classEnvironment: JSC.JSParseEnvironment,
        _ constructor: Node,
        _ parentClass: Node,
        _ classElements: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createFunctionExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node
    mutating func createGeneratorFunctionBody(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>,
        _ name: JSC.JSParseIdentifier
    ) -> Node
    mutating func createAsyncFunctionBody(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>,
        _ parseMode: JSC.SourceParseMode,
        _ name: JSC.JSParseIdentifier
    ) -> Node
    mutating func createMethodDefinition(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node
    mutating func createFunctionMetadata(
        _ facade: inout JSC.JSParseFacade,
        _ startLocation: JSC.JSTokenLocation,
        _ endLocation: JSC.JSTokenLocation,
        _ functionStart: UInt32,
        _ functionNameStart: Int32,
        _ parametersStart: Int32,
        _ implementationVisibility: JSC.ImplementationVisibility,
        _ lexicallyScopedFeatures: JSC.LexicallyScopedFeatures,
        _ constructorKind: JSC.ConstructorKind,
        _ superBinding: JSC.SuperBinding,
        _ parameterCount: UInt32,
        _ mode: JSC.SourceParseMode,
        _ isArrowFunctionBodyExpression: Bool
    ) -> Node
    mutating func createArrowFunctionExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node
    mutating func createArguments(_ facade: inout JSC.JSParseFacade) -> Node
    mutating func createArguments(_ facade: inout JSC.JSParseFacade, _ args: Node, _ hasAssignments: Bool) -> Node
    mutating func createArgumentsList(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ arg: Node) -> Node
    mutating func createArgumentsList(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ args: Node, _ arg: Node) -> Node
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: JSC.JSParseIdentifier,
        _ functionInfo: FunctionInfo<Self>,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: Node,
        _ functionInfo: FunctionInfo<Self>,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: Double,
        _ functionInfo: FunctionInfo<Self>,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: JSC.JSParseIdentifier,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: JSC.JSParseIdentifier,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ inferName: JSC.InferName,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: Double,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: Node,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ identifier: JSC.JSParseIdentifier,
        _ propertyName: Node,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property
    mutating func createPropertyList(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ property: Property) -> Node
    mutating func createPropertyList(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ property: Property,
        _ tail: Node
    ) -> Node
    mutating func createElementList(_ facade: inout JSC.JSParseFacade, _ elisions: Int32, _ expr: Node) -> Node
    mutating func createElementList(_ facade: inout JSC.JSParseFacade, _ elems: Node, _ elisions: Int32, _ expr: Node) -> Node
    mutating func createElementList(_ facade: inout JSC.JSParseFacade, _ elems: Node) -> Node
    mutating func createFormalParameterList(_ facade: inout JSC.JSParseFacade) -> Node
    mutating func appendParameter(_ facade: inout JSC.JSParseFacade, _ list: Node, _ pattern: Node, _ defaultValue: Node)
    mutating func createClause(_ facade: inout JSC.JSParseFacade, _ expr: Node, _ statements: Node) -> Node
    mutating func createClauseList(_ facade: inout JSC.JSParseFacade, _ clause: Node) -> Node
    mutating func createClauseList(_ facade: inout JSC.JSParseFacade, _ tail: Node, _ clause: Node) -> Node
    mutating func createFuncDeclStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node
    mutating func createClassDeclStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ classExpression: Node,
        _ classStart: JSC.JSTextPosition,
        _ classEnd: JSC.JSTextPosition
    ) -> Node
    mutating func createBlockStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ elements: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ functionStack: JSC.JSParseFunctionStack
    ) -> Node
    mutating func createExprStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition
    ) -> Node
    mutating func createIfStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ condition: Node,
        _ trueBlock: Node,
        _ falseBlock: Node
    ) -> Node
    mutating func createForLoop(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ initializer: Node,
        _ condition: Node,
        _ iter: Node,
        _ statements: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ initializerContainsClosure: Bool
    ) -> Node
    mutating func createForInLoop(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ lhs: Node,
        _ iter: Node,
        _ statements: Node,
        _ endLocation: JSC.JSTokenLocation,
        _ eStart: JSC.JSTextPosition,
        _ eDivot: JSC.JSTextPosition,
        _ eEnd: JSC.JSTextPosition,
        _ lexicalVariables: JSC.JSParseEnvironment
    ) -> Node
    mutating func createForInLoopWithDestructuringPattern(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ iter: Node,
        _ statements: Node,
        _ declLocation: JSC.JSTokenLocation,
        _ eStart: JSC.JSTextPosition,
        _ eDivot: JSC.JSTextPosition,
        _ eEnd: JSC.JSTextPosition,
        _ lexicalVariables: JSC.JSParseEnvironment
    ) -> Node
    mutating func createForOfLoop(
        _ facade: inout JSC.JSParseFacade,
        _ isForAwait: Bool,
        _ location: JSC.JSTokenLocation,
        _ lhs: Node,
        _ iter: Node,
        _ statements: Node,
        _ endLocation: JSC.JSTokenLocation,
        _ eStart: JSC.JSTextPosition,
        _ eDivot: JSC.JSTextPosition,
        _ eEnd: JSC.JSTextPosition,
        _ lexicalVariables: JSC.JSParseEnvironment
    ) -> Node
    mutating func createForOfLoopWithDestructuringPattern(
        _ facade: inout JSC.JSParseFacade,
        _ isForAwait: Bool,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ iter: Node,
        _ statements: Node,
        _ declLocation: JSC.JSTokenLocation,
        _ eStart: JSC.JSTextPosition,
        _ eDivot: JSC.JSTextPosition,
        _ eEnd: JSC.JSTextPosition,
        _ lexicalVariables: JSC.JSParseEnvironment
    ) -> Node
    mutating func isBindingNode(_ facade: inout JSC.JSParseFacade, _ pattern: Node) -> Bool
    mutating func isLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func isAssignmentLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func isPrivateLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func isObjectOrArrayLiteral(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func isFunctionCall(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool
    mutating func shouldSkipPauseLocation(_ facade: inout JSC.JSParseFacade, _ statement: Node) -> Bool
    mutating func createEmptyStatement(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createDeclarationStatement(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node
    mutating func createEmptyVarExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ identifier: JSC.JSParseIdentifier
    ) -> Node
    mutating func createEmptyLetExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ identifier: JSC.JSParseIdentifier
    ) -> Node
    mutating func createReturnStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createBreakStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createContinueStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createTryStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ tryBlock: Node,
        _ catchPattern: Node,
        _ catchBlock: Node,
        _ finallyBlock: Node,
        _ catchEnvironment: JSC.JSParseEnvironment
    ) -> Node
    mutating func createSwitchStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ firstClauses: Node,
        _ defaultClause: Node,
        _ secondClauses: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ functionStack: JSC.JSParseFunctionStack
    ) -> Node
    mutating func createWhileStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ statement: Node
    ) -> Node
    mutating func createDoWhileStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ statement: Node,
        _ expr: Node
    ) -> Node
    mutating func createLabelStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ statement: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createWithStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ statement: Node,
        _ start: UInt32,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createThrowStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func createDebugger(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func createModuleName(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ moduleName: JSC.JSParseIdentifier
    ) -> Node
    mutating func createImportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ importedName: JSC.JSParseIdentifier,
        _ localName: JSC.JSParseIdentifier
    ) -> Node
    mutating func createImportSpecifierList(_ facade: inout JSC.JSParseFacade) -> Node
    mutating func appendImportSpecifier(_ facade: inout JSC.JSParseFacade, _ specifierList: Node, _ specifier: Node)
    mutating func createImportAttributesList(_ facade: inout JSC.JSParseFacade) -> Node
    mutating func appendImportAttribute(
        _ facade: inout JSC.JSParseFacade,
        _ attributesList: Node,
        _ key: JSC.JSParseIdentifier,
        _ value: JSC.JSParseIdentifier
    )
    mutating func createImportDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.ImportDeclarationNode.ImportType,
        _ importSpecifierList: Node,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node
    mutating func createExportAllDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node
    mutating func createExportDefaultDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ declaration: Node,
        _ localName: JSC.JSParseIdentifier
    ) -> Node
    mutating func createExportLocalDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ declaration: Node
    ) -> Node
    mutating func createExportNamedDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ exportSpecifierList: Node,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node
    mutating func createExportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ localName: JSC.JSParseIdentifier,
        _ exportedName: JSC.JSParseIdentifier
    ) -> Node
    mutating func createExportSpecifierList(_ facade: inout JSC.JSParseFacade) -> Node
    mutating func appendExportSpecifier(_ facade: inout JSC.JSParseFacade, _ specifierList: Node, _ specifier: Node)
    mutating func appendStatement(_ facade: inout JSC.JSParseFacade, _ elements: Node, _ statement: Node)
    mutating func createCommaExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ node: Node) -> Node
    mutating func appendToCommaExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ tail: Node, _ next: Node) -> Node
    mutating func appendBinaryExpressionInfo(
        _ facade: inout JSC.JSParseFacade,
        _ operandStackDepth: inout Int32,
        _ current: Node,
        _ exprStart: JSC.JSTextPosition,
        _ lhs: JSC.JSTextPosition,
        _ rhs: JSC.JSTextPosition,
        _ hasAssignments: Bool
    )
    mutating func operatorStackPop(_ facade: inout JSC.JSParseFacade, _ operatorStackDepth: inout Int32)
    mutating func operatorStackShouldReduce(_ facade: inout JSC.JSParseFacade, _ precedence: Int32) -> Bool
    mutating func getFromOperandStack(_ facade: inout JSC.JSParseFacade, _ i: Int32) -> BinaryOperand
    mutating func shrinkOperandStackBy(_ facade: inout JSC.JSParseFacade, _ operandStackDepth: inout Int32, _ amount: Int32)
    mutating func appendBinaryOperation(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ operandStackDepth: inout Int32,
        _ operatorStackDepth: inout Int32,
        _ lhs: BinaryOperand,
        _ rhs: BinaryOperand
    )
    mutating func operatorStackAppend(
        _ facade: inout JSC.JSParseFacade,
        _ operatorStackDepth: inout Int32,
        _ op: Int32,
        _ precedence: Int32
    )
    mutating func popOperandStack(_ facade: inout JSC.JSParseFacade, _ depth: inout Int32) -> Node
    mutating func appendUnaryToken(
        _ facade: inout JSC.JSParseFacade,
        _ tokenStackDepth: inout Int32,
        _ type: Int32,
        _ start: JSC.JSTextPosition
    )
    mutating func unaryTokenStackLastType(_ facade: inout JSC.JSParseFacade, _ depth: inout Int32) -> Int32
    mutating func unaryTokenStackLastStart(_ facade: inout JSC.JSParseFacade, _ depth: inout Int32) -> JSC.JSTextPosition
    mutating func unaryTokenStackRemoveLast(_ facade: inout JSC.JSParseFacade, _ tokenStackDepth: inout Int32)
    mutating func unaryTokenStackDepth(_ facade: inout JSC.JSParseFacade) -> Int32
    mutating func setUnaryTokenStackDepth(_ facade: inout JSC.JSParseFacade, _ oldDepth: Int32)
    mutating func assignmentStackAppend(
        _ facade: inout JSC.JSParseFacade,
        _ assignmentStackDepth: inout Int32,
        _ node: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ assignmentCount: Int32,
        _ op: JSC.Operator
    )
    mutating func createAssignment(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ assignmentStackDepth: inout Int32,
        _ rhs: Node,
        _ initialAssignmentCount: Int32,
        _ currentAssignmentCount: Int32,
        _ lastTokenEnd: JSC.JSTextPosition
    ) -> Node
    mutating func isUnderscoreProtoSetter(_ facade: inout JSC.JSParseFacade, _ property: Property) -> Bool
    mutating func isResolve(_ facade: inout JSC.JSParseFacade, _ expr: Node) -> Bool
    mutating func createDestructuringAssignment(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ initializer: Node
    ) -> Node
    mutating func createArrayPattern(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func appendArrayPatternSkipEntry(_ facade: inout JSC.JSParseFacade, _ node: Node, _ location: JSC.JSTokenLocation)
    mutating func appendArrayPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ defaultValue: Node
    )
    mutating func appendArrayPatternRestEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node
    )
    mutating func finishArrayPattern(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    )
    mutating func createObjectPattern(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node
    mutating func appendObjectPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ wasString: Bool,
        _ identifier: JSC.JSParseIdentifier,
        _ pattern: Node,
        _ defaultValue: Node
    )
    mutating func appendObjectPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ propertyExpression: Node,
        _ pattern: Node,
        _ defaultValue: Node
    )
    mutating func appendObjectPatternRestEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node
    )
    mutating func setContainsObjectRestElement(_ facade: inout JSC.JSParseFacade, _ node: Node, _ containsRestElement: Bool)
    mutating func setContainsComputedProperty(_ facade: inout JSC.JSParseFacade, _ node: Node, _ containsComputedProperty: Bool)
    mutating func finishObjectPattern(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    )
    mutating func createBindingLocation(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ boundProperty: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ context: JSC.AssignmentContext
    ) -> Node
    mutating func createRestParameter(_ facade: inout JSC.JSParseFacade, _ pattern: Node, _ numParametersToSkip: Int) -> Node
    mutating func createAssignmentElement(
        _ facade: inout JSC.JSParseFacade,
        _ assignmentTarget: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node
    mutating func setEndOffset(_ facade: inout JSC.JSParseFacade, _ node: Node, _ offset: Int32)
    mutating func endOffset(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Int32
    mutating func setStartOffset(_ facade: inout JSC.JSParseFacade, _ node: Node, _ offset: Int32)
    mutating func setStartOffsetWithNode(_ facade: inout JSC.JSParseFacade, _ node: Node, _ offset: Int32)
    mutating func breakpointLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> JSC.JSTextPosition
    mutating func propagateArgumentsUse(_ facade: inout JSC.JSParseFacade)
    mutating func hasArgumentsFeature(_ facade: inout JSC.JSParseFacade) -> Bool
}
