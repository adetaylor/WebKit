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

// The builder of the syntax-only passes. Its nodes carry only the kind the grammar asks about; nothing is allocated and
// the facade is touched only to compare names and to check a regular expression's syntax.
struct SyntaxChecker: TreeBuilder {
    // A property's type and whether it is `__proto__: value`. A zero type is null.
    struct Property: TreeHandle, BitwiseCopyable {
        var type: JSC.PropertyNode.`Type` = .init(rawValue: 0)
        var isUnderscoreProtoSetter = false

        static var null: Property { Property() }
        var isNull: Bool { type.rawValue == 0 }
        var parseNode: JSC.JSParseNode? { nil }
    }

    // What a node is. `null` is the node of a failed or absent production; `newTarget` and `importMeta` are the
    // meta properties. The Int32 raw type keeps the recursive grammar functions' frames small: without it the inliner
    // folds more of the grammar into them.
    enum Kind: Int32 {
        case null
        case resolveEvalExpr
        case resolveExpr
        case integerExpr
        case doubleExpr
        case stringExpr
        case bigIntExpr
        case thisExpr
        case nullExpr
        case boolExpr
        case regExpExpr
        case objectLiteralExpr
        case functionExpr
        case classExpr
        case superExpr
        case importExpr
        case bracketExpr
        case dotExpr
        case callExpr
        case newExpr
        case preExpr
        case postExpr
        case unaryExpr
        case binaryExpr
        case optionalChain
        case privateDotExpr
        case conditionalExpr
        case assignmentExpr
        case typeofExpr
        case deleteExpr
        case arrayLiteralExpr
        case bindingDestructuring
        case restParameter
        case arrayDestructuring
        case objectDestructuring
        case sourceElementsResult
        case functionBodyResult
        case spreadExpr
        case objectSpreadExpr
        case argumentsResult
        case propertyListResult
        case argumentsListResult
        case elementsListResult
        case statementResult
        case formalParameterListResult
        case clauseResult
        case clauseListResult
        case commaExpr
        case destructuringAssignment
        case templateStringResult
        case templateStringListResult
        case templateExpressionListResult
        case templateExpr
        case taggedTemplateExpr
        case yieldExpr
        case awaitExpr
        case moduleNameResult
        case privateIdentifier
        case importSpecifierResult
        case importSpecifierListResult
        case importAttributesListResult
        case exportSpecifierResult
        case exportSpecifierListResult
        case newTarget
        case importMeta
    }

    // A node is only its kind, held as a plain integer with null as 0 (as the C++ SyntaxChecker's NoneExpr), so a null
    // test is one compare against zero: the grammar asks what a node is, never for its contents.
    struct Node: TreeHandle, BitwiseCopyable, Equatable {
        let rawValue: Int32

        @inline(always)
        init(kind: Kind) { rawValue = kind.rawValue }

        static var null: Node { Node(kind: .null) }
        var isNull: Bool { rawValue == 0 }
        var parseNode: JSC.JSParseNode? { nil }
    }

    typealias BinaryOperand = Node
    typealias SavedBinaryExpression = Node

    static var createsAST: Bool { false }
    static var needsFreeVariableInfo: Bool { false }
    static var dontBuildKeywords: LexerFlags { .dontBuildKeywords }
    static var dontBuildStrings: LexerFlags { .dontBuildStrings }

    var topBinaryExpr = Node.null
    var topUnaryToken: Int32 = 0

    init() {}

    /// PropertyNode::isUnderscoreProtoSetter(vm, name, type, needsSuperBinding, isClassProperty).
    @inline(always)
    private func isUnderscoreProtoSetterName(
        _ facade: inout JSC.JSParseFacade,
        _ name: JSC.JSParseIdentifier,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Bool {
        !name.isNull && name.matches(.underscoreProto, &facade) && type == JSC.PropertyNode.Constant
            && superBinding != .Needed && tag == .No
    }

    @inline(always)
    mutating func enterBinaryExpression() -> Node {
        let saved = topBinaryExpr
        topBinaryExpr = .null
        return saved
    }
    @inline(always)
    mutating func leaveBinaryExpression(_ saved: Node) { topBinaryExpr = saved }
    @inline(always)
    mutating func enterUnaryExpression() -> Int32 {
        let saved = topUnaryToken
        topUnaryToken = 0
        return saved
    }
    @inline(always)
    mutating func leaveUnaryExpression(_ saved: Int32) { topUnaryToken = saved }
    @inline(always)
    mutating func makeStaticBlockFunctionCallNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ function: Node,
        _ divot: JSC.JSTextPosition,
        _ divotStart: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) -> Node { Node(kind: .callExpr) }
    @inline(always)
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
    ) -> Node { Node(kind: .callExpr) }
    @inline(always)
    mutating func createSourceElements(_ facade: inout JSC.JSParseFacade) -> Node { Node(kind: .sourceElementsResult) }
    @inline(always)
    mutating func features(_ facade: inout JSC.JSParseFacade) -> Int32 { 0 }
    @inline(always)
    mutating func makePrefixNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ op: JSC.Operator,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .preExpr) }
    @inline(always)
    mutating func makePostfixNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ op: JSC.Operator,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .postExpr) }
    @inline(always)
    mutating func makeTypeOfNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .typeofExpr) }
    @inline(always)
    mutating func makeDeleteNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .deleteExpr) }
    @inline(always)
    mutating func makeNegateNode(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .unaryExpr)
    }
    @inline(always)
    mutating func makeBitwiseNotNode(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .unaryExpr)
    }
    @inline(always)
    mutating func createLogicalNot(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .unaryExpr)
    }
    @inline(always)
    mutating func createUnaryPlus(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .unaryExpr)
    }
    @inline(always)
    mutating func createVoid(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .unaryExpr)
    }
    @inline(always)
    mutating func createThisExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node { Node(kind: .thisExpr) }
    @inline(always)
    mutating func createSuperExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node { Node(kind: .superExpr) }
    @inline(always)
    mutating func createImportExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ option: Node,
        _ deferred: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .importExpr) }
    @inline(always)
    mutating func createNewTargetExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node { Node(kind: .newTarget) }
    @inline(always)
    mutating func createImportMetaExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .importMeta)
    }
    @inline(always)
    mutating func setIsParenthesized(_ facade: inout JSC.JSParseFacade, _ expr: Node) {}
    @inline(always)
    mutating func isMetaProperty(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool {
        node.rawValue == Kind.newTarget.rawValue || node.rawValue == Kind.importMeta.rawValue
    }
    @inline(always)
    mutating func isNewTarget(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool { node == Node(kind: .newTarget) }
    @inline(always)
    mutating func isImportMeta(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool { node == Node(kind: .importMeta) }
    @inline(always)
    mutating func createResolve(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ needToCheckUsesArguments: Bool
    ) -> Node { Node(kind: .resolveExpr) }
    @inline(always)
    mutating func createPrivateIdentifierNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .privateIdentifier) }
    @inline(always)
    mutating func createObjectLiteral(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node {
        Node(kind: .objectLiteralExpr)
    }
    @inline(always)
    mutating func createObjectLiteral(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ properties: Node) -> Node {
        Node(kind: .objectLiteralExpr)
    }
    @inline(always)
    mutating func createArray(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ elisions: Int32) -> Node {
        Node(kind: .arrayLiteralExpr)
    }
    @inline(always)
    mutating func createArray(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ elems: Node) -> Node {
        Node(kind: .arrayLiteralExpr)
    }
    @inline(always)
    mutating func createArray(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ elisions: Int32, _ elems: Node) -> Node
    { Node(kind: .arrayLiteralExpr) }
    @inline(always)
    mutating func createDoubleExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ d: Double) -> Node {
        Node(kind: .doubleExpr)
    }
    @inline(always)
    mutating func createIntegerExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ d: Double) -> Node {
        Node(kind: .integerExpr)
    }
    @inline(always)
    mutating func createBigInt(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ bigInt: JSC.JSParseIdentifier,
        _ radix: UInt8
    ) -> Node { Node(kind: .bigIntExpr) }
    @inline(always)
    mutating func createString(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ string: JSC.JSParseIdentifier) -> Node
    { Node(kind: .stringExpr) }
    @inline(always)
    mutating func createBoolean(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ b: Bool) -> Node {
        Node(kind: .boolExpr)
    }
    @inline(always)
    mutating func createNull(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node { Node(kind: .nullExpr) }
    @inline(always)
    mutating func createBracketAccess(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ property: Node,
        _ propertyHasAssignments: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .bracketExpr) }
    @inline(always)
    mutating func createDotAccess(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ property: JSC.JSParseIdentifier,
        _ type: JSC.DotType,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { type == .PrivateMember ? Node(kind: .privateDotExpr) : Node(kind: .dotExpr) }
    @inline(always)
    mutating func createSpreadExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .spreadExpr) }
    @inline(always)
    mutating func createObjectSpreadExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .objectSpreadExpr) }
    @inline(always)
    mutating func createTemplateString(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ cooked: JSC.JSParseIdentifier,
        _ raw: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .templateStringResult) }
    @inline(always)
    mutating func createTemplateStringList(_ facade: inout JSC.JSParseFacade, _ templateString: Node) -> Node {
        Node(kind: .templateStringListResult)
    }
    @inline(always)
    mutating func createTemplateStringList(_ facade: inout JSC.JSParseFacade, _ templateStringList: Node, _ templateString: Node) -> Node {
        Node(kind: .templateStringListResult)
    }
    @inline(always)
    mutating func createTemplateExpressionList(_ facade: inout JSC.JSParseFacade, _ expression: Node) -> Node {
        Node(kind: .templateExpressionListResult)
    }
    @inline(always)
    mutating func createTemplateExpressionList(
        _ facade: inout JSC.JSParseFacade,
        _ templateExpressionListNode: Node,
        _ expression: Node
    ) -> Node { Node(kind: .templateExpressionListResult) }
    @inline(always)
    mutating func createTemplateLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ templateStringList: Node
    ) -> Node { Node(kind: .templateExpr) }
    @inline(always)
    mutating func createTemplateLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ templateStringList: Node,
        _ templateExpressionList: Node
    ) -> Node { Node(kind: .templateExpr) }
    @inline(always)
    mutating func createTaggedTemplate(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ templateLiteral: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .taggedTemplateExpr) }
    @inline(always)
    mutating func createRegExp(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: JSC.JSParseIdentifier,
        _ flags: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ skipSyntaxCheck: Bool
    ) -> Node { !skipSyntaxCheck && facade.checkRegularExpressionSyntax(pattern, flags) != 0 ? .null : Node(kind: .regExpExpr) }
    @inline(always)
    mutating func createNewExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ arguments: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .newExpr) }
    @inline(always)
    mutating func createNewExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .newExpr) }
    @inline(always)
    mutating func createOptionalChain(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ expr: Node,
        _ isOutermost: Bool
    ) -> Node { Node(kind: .optionalChain) }
    @inline(always)
    mutating func createConditionalExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ condition: Node,
        _ lhs: Node,
        _ rhs: Node
    ) -> Node { Node(kind: .conditionalExpr) }
    @inline(always)
    mutating func createAssignResolve(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ rhs: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ assignmentContext: JSC.AssignmentContext
    ) -> Node { Node(kind: .assignmentExpr) }
    @inline(always)
    mutating func createYield(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node { Node(kind: .yieldExpr) }
    @inline(always)
    mutating func createYield(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ argument: Node,
        _ delegate: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .yieldExpr) }
    @inline(always)
    mutating func createAwait(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ argument: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .awaitExpr) }
    @inline(always)
    mutating func createDefineField(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ initializer: Node,
        _ type: JSC.DefineFieldNode.`Type`
    ) -> Node { .null }
    @inline(always)
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
    ) -> Node { Node(kind: .classExpr) }
    @inline(always)
    mutating func createFunctionExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node { Node(kind: .functionExpr) }
    @inline(always)
    mutating func createGeneratorFunctionBody(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>,
        _ name: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .functionExpr) }
    @inline(always)
    mutating func createAsyncFunctionBody(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>,
        _ parseMode: JSC.SourceParseMode,
        _ name: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .functionExpr) }
    @inline(always)
    mutating func createMethodDefinition(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node { Node(kind: .functionExpr) }
    @inline(always)
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
    ) -> Node { Node(kind: .functionBodyResult) }
    @inline(always)
    mutating func createArrowFunctionExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node { Node(kind: .functionExpr) }
    @inline(always)
    mutating func createArguments(_ facade: inout JSC.JSParseFacade) -> Node { Node(kind: .argumentsResult) }
    @inline(always)
    mutating func createArguments(_ facade: inout JSC.JSParseFacade, _ args: Node, _ hasAssignments: Bool) -> Node {
        Node(kind: .argumentsResult)
    }
    @inline(always)
    mutating func createArgumentsList(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ arg: Node) -> Node {
        Node(kind: .argumentsListResult)
    }
    @inline(always)
    mutating func createArgumentsList(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ args: Node, _ arg: Node) -> Node
    { Node(kind: .argumentsListResult) }
    @inline(always)
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: JSC.JSParseIdentifier,
        _ functionInfo: FunctionInfo<Self>,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: Node,
        _ functionInfo: FunctionInfo<Self>,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: Double,
        _ functionInfo: FunctionInfo<Self>,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: JSC.JSParseIdentifier,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: JSC.JSParseIdentifier,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ inferName: JSC.InferName,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        Property(type: type, isUnderscoreProtoSetter: isUnderscoreProtoSetterName(&facade, propertyName, type, superBinding, tag))
    }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: Double,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: Node,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ identifier: JSC.JSParseIdentifier,
        _ propertyName: Node,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property { Property(type: type) }
    @inline(always)
    mutating func createPropertyList(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ property: Property) -> Node {
        Node(kind: .propertyListResult)
    }
    @inline(always)
    mutating func createPropertyList(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ property: Property,
        _ tail: Node
    ) -> Node { Node(kind: .propertyListResult) }
    @inline(always)
    mutating func createElementList(_ facade: inout JSC.JSParseFacade, _ elisions: Int32, _ expr: Node) -> Node {
        Node(kind: .elementsListResult)
    }
    @inline(always)
    mutating func createElementList(_ facade: inout JSC.JSParseFacade, _ elems: Node, _ elisions: Int32, _ expr: Node) -> Node {
        Node(kind: .elementsListResult)
    }
    @inline(always)
    mutating func createElementList(_ facade: inout JSC.JSParseFacade, _ elems: Node) -> Node { Node(kind: .elementsListResult) }
    @inline(always)
    mutating func createFormalParameterList(_ facade: inout JSC.JSParseFacade) -> Node { Node(kind: .formalParameterListResult) }
    @inline(always)
    mutating func appendParameter(_ facade: inout JSC.JSParseFacade, _ list: Node, _ pattern: Node, _ defaultValue: Node) {}
    @inline(always)
    mutating func createClause(_ facade: inout JSC.JSParseFacade, _ expr: Node, _ statements: Node) -> Node { Node(kind: .clauseResult) }
    @inline(always)
    mutating func createClauseList(_ facade: inout JSC.JSParseFacade, _ clause: Node) -> Node { Node(kind: .clauseListResult) }
    @inline(always)
    mutating func createClauseList(_ facade: inout JSC.JSParseFacade, _ tail: Node, _ clause: Node) -> Node {
        Node(kind: .clauseListResult)
    }
    @inline(always)
    mutating func createFuncDeclStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<Self>
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createClassDeclStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ classExpression: Node,
        _ classStart: JSC.JSTextPosition,
        _ classEnd: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createBlockStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ elements: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ functionStack: JSC.JSParseFunctionStack
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createExprStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createIfStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ condition: Node,
        _ trueBlock: Node,
        _ falseBlock: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createForLoop(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ initializer: Node,
        _ condition: Node,
        _ iter: Node,
        _ statements: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ initializerContainsClosure: Bool
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
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
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
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
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
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
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
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
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func isBindingNode(_ facade: inout JSC.JSParseFacade, _ pattern: Node) -> Bool { pattern == Node(kind: .bindingDestructuring) }
    @inline(always)
    mutating func isLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool {
        node == Node(kind: .resolveExpr) || node == Node(kind: .dotExpr) || node == Node(kind: .privateDotExpr)
            || node == Node(kind: .bracketExpr)
    }
    @inline(always)
    mutating func isAssignmentLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool {
        isLocation(&facade, node) || node == Node(kind: .destructuringAssignment)
    }
    @inline(always)
    mutating func isPrivateLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool { node == Node(kind: .privateDotExpr) }
    @inline(always)
    mutating func isObjectOrArrayLiteral(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool {
        node == Node(kind: .objectLiteralExpr) || node == Node(kind: .arrayLiteralExpr)
    }
    @inline(always)
    mutating func isFunctionCall(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Bool { node == Node(kind: .callExpr) }
    @inline(always)
    mutating func shouldSkipPauseLocation(_ facade: inout JSC.JSParseFacade, _ statement: Node) -> Bool { true }
    @inline(always)
    mutating func createEmptyStatement(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node {
        Node(kind: .statementResult)
    }
    @inline(always)
    mutating func createDeclarationStatement(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ expr: Node) -> Node {
        Node(kind: .statementResult)
    }
    @inline(always)
    mutating func createEmptyVarExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ identifier: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .assignmentExpr) }
    @inline(always)
    mutating func createEmptyLetExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ identifier: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .assignmentExpr) }
    @inline(always)
    mutating func createReturnStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createBreakStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createContinueStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createTryStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ tryBlock: Node,
        _ catchPattern: Node,
        _ catchBlock: Node,
        _ finallyBlock: Node,
        _ catchEnvironment: JSC.JSParseEnvironment
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createSwitchStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ firstClauses: Node,
        _ defaultClause: Node,
        _ secondClauses: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ functionStack: JSC.JSParseFunctionStack
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createWhileStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ statement: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createDoWhileStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ statement: Node,
        _ expr: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createLabelStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ statement: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createWithStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ statement: Node,
        _ start: UInt32,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createThrowStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createDebugger(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node {
        Node(kind: .statementResult)
    }
    @inline(always)
    mutating func createModuleName(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ moduleName: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .moduleNameResult) }
    @inline(always)
    mutating func createImportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ importedName: JSC.JSParseIdentifier,
        _ localName: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .importSpecifierResult) }
    @inline(always)
    mutating func createImportSpecifierList(_ facade: inout JSC.JSParseFacade) -> Node { Node(kind: .importSpecifierListResult) }
    @inline(always)
    mutating func appendImportSpecifier(_ facade: inout JSC.JSParseFacade, _ specifierList: Node, _ specifier: Node) {}
    @inline(always)
    mutating func createImportAttributesList(_ facade: inout JSC.JSParseFacade) -> Node { Node(kind: .importAttributesListResult) }
    @inline(always)
    mutating func appendImportAttribute(
        _ facade: inout JSC.JSParseFacade,
        _ attributesList: Node,
        _ key: JSC.JSParseIdentifier,
        _ value: JSC.JSParseIdentifier
    ) {}
    @inline(always)
    mutating func createImportDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.ImportDeclarationNode.ImportType,
        _ importSpecifierList: Node,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createExportAllDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createExportDefaultDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ declaration: Node,
        _ localName: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createExportLocalDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ declaration: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createExportNamedDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ exportSpecifierList: Node,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node { Node(kind: .statementResult) }
    @inline(always)
    mutating func createExportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ localName: JSC.JSParseIdentifier,
        _ exportedName: JSC.JSParseIdentifier
    ) -> Node { Node(kind: .exportSpecifierResult) }
    @inline(always)
    mutating func createExportSpecifierList(_ facade: inout JSC.JSParseFacade) -> Node { Node(kind: .exportSpecifierListResult) }
    @inline(always)
    mutating func appendExportSpecifier(_ facade: inout JSC.JSParseFacade, _ specifierList: Node, _ specifier: Node) {}
    @inline(always)
    mutating func appendStatement(_ facade: inout JSC.JSParseFacade, _ elements: Node, _ statement: Node) {}
    @inline(always)
    mutating func createCommaExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ node: Node) -> Node {
        Node(kind: .commaExpr)
    }
    @inline(always)
    mutating func appendToCommaExpr(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation, _ tail: Node, _ next: Node) -> Node
    { Node(kind: .commaExpr) }
    @inline(always)
    mutating func appendBinaryExpressionInfo(
        _ facade: inout JSC.JSParseFacade,
        _ operandStackDepth: inout Int32,
        _ current: Node,
        _ exprStart: JSC.JSTextPosition,
        _ lhs: JSC.JSTextPosition,
        _ rhs: JSC.JSTextPosition,
        _ hasAssignments: Bool
    ) {
        topBinaryExpr = topBinaryExpr.isNull ? current : Node(kind: .binaryExpr)
        operandStackDepth += 1
    }
    // Logic to handle datastructures used during parsing of binary expressions
    @inline(always)
    mutating func operatorStackPop(_ facade: inout JSC.JSParseFacade, _ operatorStackDepth: inout Int32) { operatorStackDepth -= 1 }
    @inline(always)
    mutating func operatorStackShouldReduce(_ facade: inout JSC.JSParseFacade, _ precedence: Int32) -> Bool { true }
    @inline(always)
    mutating func getFromOperandStack(_ facade: inout JSC.JSParseFacade, _ i: Int32) -> BinaryOperand { topBinaryExpr }
    @inline(always)
    mutating func shrinkOperandStackBy(_ facade: inout JSC.JSParseFacade, _ operandStackDepth: inout Int32, _ amount: Int32) {
        operandStackDepth -= amount
    }
    @inline(always)
    mutating func appendBinaryOperation(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ operandStackDepth: inout Int32,
        _ operatorStackDepth: inout Int32,
        _ lhs: BinaryOperand,
        _ rhs: BinaryOperand
    ) { operandStackDepth += 1 }
    @inline(always)
    mutating func operatorStackAppend(
        _ facade: inout JSC.JSParseFacade,
        _ operatorStackDepth: inout Int32,
        _ op: Int32,
        _ precedence: Int32
    ) { operatorStackDepth += 1 }
    @inline(always)
    mutating func popOperandStack(_ facade: inout JSC.JSParseFacade, _ depth: inout Int32) -> Node {
        let result = topBinaryExpr
        topBinaryExpr = .null
        return result
    }
    @inline(always)
    mutating func appendUnaryToken(
        _ facade: inout JSC.JSParseFacade,
        _ tokenStackDepth: inout Int32,
        _ type: Int32,
        _ start: JSC.JSTextPosition
    ) {
        tokenStackDepth = 1
        topUnaryToken = type
    }
    @inline(always)
    mutating func unaryTokenStackLastType(_ facade: inout JSC.JSParseFacade, _ depth: inout Int32) -> Int32 { topUnaryToken }
    @inline(always)
    mutating func unaryTokenStackLastStart(_ facade: inout JSC.JSParseFacade, _ depth: inout Int32) -> JSC.JSTextPosition {
        JSC.JSTextPosition()
    }
    @inline(always)
    mutating func unaryTokenStackRemoveLast(_ facade: inout JSC.JSParseFacade, _ tokenStackDepth: inout Int32) { tokenStackDepth = 0 }
    @inline(always)
    mutating func unaryTokenStackDepth(_ facade: inout JSC.JSParseFacade) -> Int32 { 0 }
    @inline(always)
    mutating func setUnaryTokenStackDepth(_ facade: inout JSC.JSParseFacade, _ oldDepth: Int32) {}
    @inline(always)
    mutating func assignmentStackAppend(
        _ facade: inout JSC.JSParseFacade,
        _ assignmentStackDepth: inout Int32,
        _ node: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ assignmentCount: Int32,
        _ op: JSC.Operator
    ) { assignmentStackDepth = 1 }
    @inline(always)
    mutating func createAssignment(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ assignmentStackDepth: inout Int32,
        _ rhs: Node,
        _ initialAssignmentCount: Int32,
        _ currentAssignmentCount: Int32,
        _ lastTokenEnd: JSC.JSTextPosition
    ) -> Node {
        assignmentStackDepth = 0
        return Node(kind: .assignmentExpr)
    }
    @inline(always)
    mutating func isUnderscoreProtoSetter(_ facade: inout JSC.JSParseFacade, _ property: Property) -> Bool {
        property.isUnderscoreProtoSetter
    }
    @inline(always)
    mutating func isResolve(_ facade: inout JSC.JSParseFacade, _ expr: Node) -> Bool {
        expr == Node(kind: .resolveExpr) || expr == Node(kind: .resolveEvalExpr)
    }
    @inline(always)
    mutating func createDestructuringAssignment(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ initializer: Node
    ) -> Node { Node(kind: .destructuringAssignment) }
    @inline(always)
    mutating func createArrayPattern(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node {
        Node(kind: .arrayDestructuring)
    }
    @inline(always)
    mutating func appendArrayPatternSkipEntry(_ facade: inout JSC.JSParseFacade, _ node: Node, _ location: JSC.JSTokenLocation) {}
    @inline(always)
    mutating func appendArrayPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ defaultValue: Node
    ) {}
    @inline(always)
    mutating func appendArrayPatternRestEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node
    ) {}
    @inline(always)
    mutating func finishArrayPattern(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) {}
    @inline(always)
    mutating func createObjectPattern(_ facade: inout JSC.JSParseFacade, _ location: JSC.JSTokenLocation) -> Node {
        Node(kind: .objectDestructuring)
    }
    @inline(always)
    mutating func appendObjectPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ wasString: Bool,
        _ identifier: JSC.JSParseIdentifier,
        _ pattern: Node,
        _ defaultValue: Node
    ) {}
    @inline(always)
    mutating func appendObjectPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ propertyExpression: Node,
        _ pattern: Node,
        _ defaultValue: Node
    ) {}
    @inline(always)
    mutating func appendObjectPatternRestEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node
    ) {}
    @inline(always)
    mutating func setContainsObjectRestElement(_ facade: inout JSC.JSParseFacade, _ node: Node, _ containsRestElement: Bool) {}
    @inline(always)
    mutating func setContainsComputedProperty(_ facade: inout JSC.JSParseFacade, _ node: Node, _ containsComputedProperty: Bool) {}
    @inline(always)
    mutating func finishObjectPattern(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) {}
    @inline(always)
    mutating func createBindingLocation(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ boundProperty: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ context: JSC.AssignmentContext
    ) -> Node { Node(kind: .bindingDestructuring) }
    @inline(always)
    mutating func createRestParameter(_ facade: inout JSC.JSParseFacade, _ pattern: Node, _ numParametersToSkip: Int) -> Node {
        Node(kind: .restParameter)
    }
    @inline(always)
    mutating func createAssignmentElement(
        _ facade: inout JSC.JSParseFacade,
        _ assignmentTarget: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node { Node(kind: .bindingDestructuring) }
    @inline(always)
    mutating func setEndOffset(_ facade: inout JSC.JSParseFacade, _ node: Node, _ offset: Int32) {}
    @inline(always)
    mutating func endOffset(_ facade: inout JSC.JSParseFacade, _ node: Node) -> Int32 { 0 }
    @inline(always)
    mutating func setStartOffset(_ facade: inout JSC.JSParseFacade, _ node: Node, _ offset: Int32) {}
    @inline(always)
    mutating func setStartOffsetWithNode(_ facade: inout JSC.JSParseFacade, _ node: Node, _ offset: Int32) {}
    @inline(always)
    mutating func breakpointLocation(_ facade: inout JSC.JSParseFacade, _ node: Node) -> JSC.JSTextPosition { JSC.JSTextPosition() }
    @inline(always)
    mutating func propagateArgumentsUse(_ facade: inout JSC.JSParseFacade) {}
    @inline(always)
    mutating func hasArgumentsFeature(_ facade: inout JSC.JSParseFacade) -> Bool { true }
}
