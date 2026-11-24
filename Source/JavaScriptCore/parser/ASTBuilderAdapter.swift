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

// TreeBuilder over the facade: every member calls the facade's forwarder of the same name, which makes the AST node
// in the facade's node table and returns its handle. The facade is not copyable and the parser passes it as an inout
// borrow, so the builder cannot store it; each member takes it as a parameter.
struct ASTBuilderAdapter: TreeBuilder {
    typealias Node = JSC.JSParseNode
    typealias Property = JSC.JSParseNode
    typealias BinaryOperand = JSC.JSParseBinaryOperand
    typealias SavedBinaryExpression = Int32

    static var createsAST: Bool { true }
    static var needsFreeVariableInfo: Bool { true }
    static var dontBuildKeywords: LexerFlags { [] }
    static var dontBuildStrings: LexerFlags { [] }

    // ASTBuilder keeps its operator and operand stacks itself.
    @inline(always)
    mutating func enterBinaryExpression() -> Int32 { 0 }
    @inline(always)
    mutating func leaveBinaryExpression(_ saved: Int32) {}
    @inline(always)
    mutating func enterUnaryExpression() -> Int32 { 0 }
    @inline(always)
    mutating func leaveUnaryExpression(_ saved: Int32) {}

    @inline(always)
    mutating func makeStaticBlockFunctionCallNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ function: Node,
        _ divot: JSC.JSTextPosition,
        _ divotStart: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) -> Node {
        facade.makeStaticBlockFunctionCallNode(location, function, divot, divotStart, divotEnd)
    }
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
    ) -> Node {
        facade.makeFunctionCallNode(
            location,
            function,
            previousBaseWasSuper,
            args,
            divotStart,
            divot,
            divotEnd,
            callOrApplyChildDepth,
            isOptionalCall
        )
    }
    @inline(always)
    mutating func createSourceElements(
        _ facade: inout JSC.JSParseFacade
    ) -> Node {
        facade.createSourceElements()
    }
    @inline(always)
    mutating func features(
        _ facade: inout JSC.JSParseFacade
    ) -> Int32 {
        facade.features()
    }
    @inline(always)
    mutating func makePrefixNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ op: JSC.Operator,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.makePrefixNode(location, expr, op, start, divot, end)
    }
    @inline(always)
    mutating func makePostfixNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ op: JSC.Operator,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.makePostfixNode(location, expr, op, start, divot, end)
    }
    @inline(always)
    mutating func makeTypeOfNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.makeTypeOfNode(location, expr, start, divot, end)
    }
    @inline(always)
    mutating func makeDeleteNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.makeDeleteNode(location, expr, start, divot, end)
    }
    @inline(always)
    mutating func makeNegateNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.makeNegateNode(location, expr)
    }
    @inline(always)
    mutating func makeBitwiseNotNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.makeBitwiseNotNode(location, expr)
    }
    @inline(always)
    mutating func createLogicalNot(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.createLogicalNot(location, expr)
    }
    @inline(always)
    mutating func createUnaryPlus(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.createUnaryPlus(location, expr)
    }
    @inline(always)
    mutating func createVoid(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.createVoid(location, expr)
    }
    @inline(always)
    mutating func createThisExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createThisExpr(location)
    }
    @inline(always)
    mutating func createSuperExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createSuperExpr(location)
    }
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
    ) -> Node {
        facade.createImportExpr(location, expr, option, deferred, start, divot, end)
    }
    @inline(always)
    mutating func createNewTargetExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createNewTargetExpr(location)
    }
    @inline(always)
    mutating func createImportMetaExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.createImportMetaExpr(location, expr)
    }
    @inline(always)
    mutating func setIsParenthesized(
        _ facade: inout JSC.JSParseFacade,
        _ expr: Node
    ) {
        facade.setIsParenthesized(expr)
    }
    @inline(always)
    mutating func isMetaProperty(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isMetaProperty(node)
    }
    @inline(always)
    mutating func isNewTarget(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isNewTarget(node)
    }
    @inline(always)
    mutating func isImportMeta(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isImportMeta(node)
    }
    @inline(always)
    mutating func createResolve(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ needToCheckUsesArguments: Bool
    ) -> Node {
        facade.createResolve(location, ident, start, end, needToCheckUsesArguments)
    }
    @inline(always)
    mutating func createPrivateIdentifierNode(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier
    ) -> Node {
        facade.createPrivateIdentifierNode(location, ident)
    }
    @inline(always)
    mutating func createObjectLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createObjectLiteral(location)
    }
    @inline(always)
    mutating func createObjectLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ properties: Node
    ) -> Node {
        facade.createObjectLiteral(location, properties)
    }
    @inline(always)
    mutating func createArray(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ elisions: Int32
    ) -> Node {
        facade.createArray(location, elisions)
    }
    @inline(always)
    mutating func createArray(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ elems: Node
    ) -> Node {
        facade.createArray(location, elems)
    }
    @inline(always)
    mutating func createArray(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ elisions: Int32,
        _ elems: Node
    ) -> Node {
        facade.createArray(location, elisions, elems)
    }
    @inline(always)
    mutating func createDoubleExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ d: Double
    ) -> Node {
        facade.createDoubleExpr(location, d)
    }
    @inline(always)
    mutating func createIntegerExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ d: Double
    ) -> Node {
        facade.createIntegerExpr(location, d)
    }
    @inline(always)
    mutating func createBigInt(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ bigInt: JSC.JSParseIdentifier,
        _ radix: UInt8
    ) -> Node {
        facade.createBigInt(location, bigInt, radix)
    }
    @inline(always)
    mutating func createString(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ string: JSC.JSParseIdentifier
    ) -> Node {
        facade.createString(location, string)
    }
    @inline(always)
    mutating func createBoolean(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ b: Bool
    ) -> Node {
        facade.createBoolean(location, b)
    }
    @inline(always)
    mutating func createNull(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createNull(location)
    }
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
    ) -> Node {
        facade.createBracketAccess(location, base, property, propertyHasAssignments, start, divot, end)
    }
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
    ) -> Node {
        facade.createDotAccess(location, base, property, type, start, divot, end)
    }
    @inline(always)
    mutating func createSpreadExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createSpreadExpression(location, expression, start, divot, end)
    }
    @inline(always)
    mutating func createObjectSpreadExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createObjectSpreadExpression(location, expression, start, divot, end)
    }
    @inline(always)
    mutating func createTemplateString(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ cooked: JSC.JSParseIdentifier,
        _ raw: JSC.JSParseIdentifier
    ) -> Node {
        facade.createTemplateString(location, cooked, raw)
    }
    @inline(always)
    mutating func createTemplateStringList(
        _ facade: inout JSC.JSParseFacade,
        _ templateString: Node
    ) -> Node {
        facade.createTemplateStringList(templateString)
    }
    @inline(always)
    mutating func createTemplateStringList(
        _ facade: inout JSC.JSParseFacade,
        _ templateStringList: Node,
        _ templateString: Node
    ) -> Node {
        facade.createTemplateStringList(templateStringList, templateString)
    }
    @inline(always)
    mutating func createTemplateExpressionList(
        _ facade: inout JSC.JSParseFacade,
        _ expression: Node
    ) -> Node {
        facade.createTemplateExpressionList(expression)
    }
    @inline(always)
    mutating func createTemplateExpressionList(
        _ facade: inout JSC.JSParseFacade,
        _ templateExpressionListNode: Node,
        _ expression: Node
    ) -> Node {
        facade.createTemplateExpressionList(templateExpressionListNode, expression)
    }
    @inline(always)
    mutating func createTemplateLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ templateStringList: Node
    ) -> Node {
        facade.createTemplateLiteral(location, templateStringList)
    }
    @inline(always)
    mutating func createTemplateLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ templateStringList: Node,
        _ templateExpressionList: Node
    ) -> Node {
        facade.createTemplateLiteral(location, templateStringList, templateExpressionList)
    }
    @inline(always)
    mutating func createTaggedTemplate(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ templateLiteral: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createTaggedTemplate(location, base, templateLiteral, start, divot, end)
    }
    @inline(always)
    mutating func createRegExp(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: JSC.JSParseIdentifier,
        _ flags: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ skipSyntaxCheck: Bool
    ) -> Node {
        facade.createRegExp(location, pattern, flags, start, skipSyntaxCheck)
    }
    @inline(always)
    mutating func createNewExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ arguments: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createNewExpr(location, expr, arguments, start, divot, end)
    }
    @inline(always)
    mutating func createNewExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createNewExpr(location, expr, start, divot, end)
    }
    @inline(always)
    mutating func createOptionalChain(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ base: Node,
        _ expr: Node,
        _ isOutermost: Bool
    ) -> Node {
        facade.createOptionalChain(location, base, expr, isOutermost)
    }
    @inline(always)
    mutating func createConditionalExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ condition: Node,
        _ lhs: Node,
        _ rhs: Node
    ) -> Node {
        facade.createConditionalExpr(location, condition, lhs, rhs)
    }
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
    ) -> Node {
        facade.createAssignResolve(location, ident, rhs, start, divot, end, assignmentContext)
    }
    @inline(always)
    mutating func createYield(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createYield(location)
    }
    @inline(always)
    mutating func createYield(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ argument: Node,
        _ delegate: Bool,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createYield(location, argument, delegate, start, divot, end)
    }
    @inline(always)
    mutating func createAwait(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ argument: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createAwait(location, argument, start, divot, end)
    }
    @inline(always)
    mutating func createDefineField(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ initializer: Node,
        _ type: JSC.DefineFieldNode.`Type`
    ) -> Node {
        facade.createDefineField(location, ident, initializer, type)
    }
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
    ) -> Node {
        facade.createClassExpr(
            location,
            classInfo,
            classHeadEnvironment,
            classEnvironment,
            constructor,
            parentClass,
            classElements,
            start,
            divot,
            end
        )
    }
    @inline(always)
    mutating func createFunctionExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>
    ) -> Node {
        facade.createFunctionExpr(location, JSC.JSParseFunctionInfo(functionInfo))
    }
    @inline(always)
    mutating func createGeneratorFunctionBody(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>,
        _ name: JSC.JSParseIdentifier
    ) -> Node {
        facade.createGeneratorFunctionBody(location, JSC.JSParseFunctionInfo(functionInfo), name)
    }
    @inline(always)
    mutating func createAsyncFunctionBody(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>,
        _ parseMode: JSC.SourceParseMode,
        _ name: JSC.JSParseIdentifier
    ) -> Node {
        facade.createAsyncFunctionBody(location, JSC.JSParseFunctionInfo(functionInfo), parseMode, name)
    }
    @inline(always)
    mutating func createMethodDefinition(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>
    ) -> Node {
        facade.createMethodDefinition(location, JSC.JSParseFunctionInfo(functionInfo))
    }
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
    ) -> Node {
        facade.createFunctionMetadata(
            startLocation,
            endLocation,
            functionStart,
            functionNameStart,
            parametersStart,
            implementationVisibility,
            lexicallyScopedFeatures,
            constructorKind,
            superBinding,
            parameterCount,
            mode,
            isArrowFunctionBodyExpression
        )
    }
    @inline(always)
    mutating func createArrowFunctionExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>
    ) -> Node {
        facade.createArrowFunctionExpr(location, JSC.JSParseFunctionInfo(functionInfo))
    }
    @inline(always)
    mutating func createArguments(
        _ facade: inout JSC.JSParseFacade
    ) -> Node {
        facade.createArguments()
    }
    @inline(always)
    mutating func createArguments(
        _ facade: inout JSC.JSParseFacade,
        _ args: Node,
        _ hasAssignments: Bool
    ) -> Node {
        facade.createArguments(args, hasAssignments)
    }
    @inline(always)
    mutating func createArgumentsList(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ arg: Node
    ) -> Node {
        facade.createArgumentsList(location, arg)
    }
    @inline(always)
    mutating func createArgumentsList(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ args: Node,
        _ arg: Node
    ) -> Node {
        facade.createArgumentsList(location, args, arg)
    }
    @inline(always)
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: JSC.JSParseIdentifier,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createGetterOrSetterProperty(location, type, name, JSC.JSParseFunctionInfo(functionInfo), tag)
    }
    @inline(always)
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: Node,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createGetterOrSetterProperty(location, type, name, JSC.JSParseFunctionInfo(functionInfo), tag)
    }
    @inline(always)
    mutating func createGetterOrSetterProperty(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.PropertyNode.`Type`,
        _ name: Double,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createGetterOrSetterProperty(location, type, name, JSC.JSParseFunctionInfo(functionInfo), tag)
    }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: JSC.JSParseIdentifier,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createProperty(propertyName, type, superBinding, tag)
    }
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
        facade.createProperty(propertyName, node, type, superBinding, inferName, tag)
    }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createProperty(node, type, superBinding, tag)
    }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: Double,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createProperty(propertyName, node, type, superBinding, tag)
    }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ propertyName: Node,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createProperty(propertyName, node, type, superBinding, tag)
    }
    @inline(always)
    mutating func createProperty(
        _ facade: inout JSC.JSParseFacade,
        _ identifier: JSC.JSParseIdentifier,
        _ propertyName: Node,
        _ node: Node,
        _ type: JSC.PropertyNode.`Type`,
        _ superBinding: JSC.SuperBinding,
        _ tag: JSC.ClassElementTag
    ) -> Property {
        facade.createProperty(identifier, propertyName, node, type, superBinding, tag)
    }
    @inline(always)
    mutating func createPropertyList(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ property: Property
    ) -> Node {
        facade.createPropertyList(location, property)
    }
    @inline(always)
    mutating func createPropertyList(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ property: Property,
        _ tail: Node
    ) -> Node {
        facade.createPropertyList(location, property, tail)
    }
    @inline(always)
    mutating func createElementList(
        _ facade: inout JSC.JSParseFacade,
        _ elisions: Int32,
        _ expr: Node
    ) -> Node {
        facade.createElementList(elisions, expr)
    }
    @inline(always)
    mutating func createElementList(
        _ facade: inout JSC.JSParseFacade,
        _ elems: Node,
        _ elisions: Int32,
        _ expr: Node
    ) -> Node {
        facade.createElementList(elems, elisions, expr)
    }
    @inline(always)
    mutating func createElementList(
        _ facade: inout JSC.JSParseFacade,
        _ elems: Node
    ) -> Node {
        facade.createElementList(elems)
    }
    @inline(always)
    mutating func createFormalParameterList(
        _ facade: inout JSC.JSParseFacade
    ) -> Node {
        facade.createFormalParameterList()
    }
    @inline(always)
    mutating func appendParameter(
        _ facade: inout JSC.JSParseFacade,
        _ list: Node,
        _ pattern: Node,
        _ defaultValue: Node
    ) {
        facade.appendParameter(list, pattern, defaultValue)
    }
    @inline(always)
    mutating func createClause(
        _ facade: inout JSC.JSParseFacade,
        _ expr: Node,
        _ statements: Node
    ) -> Node {
        expr.isNull ? facade.createDefaultClause(statements) : facade.createClause(expr, statements)
    }
    @inline(always)
    mutating func createClauseList(
        _ facade: inout JSC.JSParseFacade,
        _ clause: Node
    ) -> Node {
        facade.createClauseList(clause)
    }
    @inline(always)
    mutating func createClauseList(
        _ facade: inout JSC.JSParseFacade,
        _ tail: Node,
        _ clause: Node
    ) -> Node {
        facade.createClauseList(tail, clause)
    }
    @inline(always)
    mutating func createFuncDeclStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ functionInfo: FunctionInfo<ASTBuilderAdapter>
    ) -> Node {
        facade.createFuncDeclStatement(location, JSC.JSParseFunctionInfo(functionInfo))
    }
    @inline(always)
    mutating func createClassDeclStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ classExpression: Node,
        _ classStart: JSC.JSTextPosition,
        _ classEnd: JSC.JSTextPosition
    ) -> Node {
        facade.createClassDeclStatement(location, classExpression, classStart, classEnd)
    }
    @inline(always)
    mutating func createBlockStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ elements: Node,
        _ lexicalVariables: JSC.JSParseEnvironment,
        _ functionStack: JSC.JSParseFunctionStack
    ) -> Node {
        facade.createBlockStatement(location, elements, lexicalVariables, functionStack)
    }
    @inline(always)
    mutating func createExprStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition
    ) -> Node {
        facade.createExprStatement(location, expr, start)
    }
    @inline(always)
    mutating func createIfStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ condition: Node,
        _ trueBlock: Node,
        _ falseBlock: Node
    ) -> Node {
        facade.createIfStatement(location, condition, trueBlock, falseBlock)
    }
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
    ) -> Node {
        facade.createForLoop(location, initializer, condition, iter, statements, lexicalVariables, initializerContainsClosure)
    }
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
    ) -> Node {
        facade.createForInLoop(location, lhs, iter, statements, endLocation, eStart, eDivot, eEnd, lexicalVariables)
    }
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
    ) -> Node {
        facade.createForInLoopWithDestructuringPattern(
            location,
            pattern,
            iter,
            statements,
            declLocation,
            eStart,
            eDivot,
            eEnd,
            lexicalVariables
        )
    }
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
    ) -> Node {
        facade.createForOfLoop(isForAwait, location, lhs, iter, statements, endLocation, eStart, eDivot, eEnd, lexicalVariables)
    }
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
    ) -> Node {
        facade.createForOfLoopWithDestructuringPattern(
            isForAwait,
            location,
            pattern,
            iter,
            statements,
            declLocation,
            eStart,
            eDivot,
            eEnd,
            lexicalVariables
        )
    }
    @inline(always)
    mutating func isBindingNode(
        _ facade: inout JSC.JSParseFacade,
        _ pattern: Node
    ) -> Bool {
        facade.isBindingNode(pattern)
    }
    @inline(always)
    mutating func isLocation(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isLocation(node)
    }
    @inline(always)
    mutating func isAssignmentLocation(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isAssignmentLocation(node)
    }
    @inline(always)
    mutating func isPrivateLocation(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isPrivateLocation(node)
    }
    @inline(always)
    mutating func isObjectOrArrayLiteral(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isObjectOrArrayLiteral(node)
    }
    @inline(always)
    mutating func isFunctionCall(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Bool {
        facade.isFunctionCall(node)
    }
    @inline(always)
    mutating func shouldSkipPauseLocation(
        _ facade: inout JSC.JSParseFacade,
        _ statement: Node
    ) -> Bool {
        facade.shouldSkipPauseLocation(statement)
    }
    @inline(always)
    mutating func createEmptyStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createEmptyStatement(location)
    }
    @inline(always)
    mutating func createDeclarationStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node
    ) -> Node {
        facade.createDeclarationStatement(location, expr)
    }
    @inline(always)
    mutating func createEmptyVarExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ identifier: JSC.JSParseIdentifier
    ) -> Node {
        facade.createEmptyVarExpression(location, identifier)
    }
    @inline(always)
    mutating func createEmptyLetExpression(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ identifier: JSC.JSParseIdentifier
    ) -> Node {
        facade.createEmptyLetExpression(location, identifier)
    }
    @inline(always)
    mutating func createReturnStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expression: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createReturnStatement(location, expression, start, end)
    }
    @inline(always)
    mutating func createBreakStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createBreakStatement(location, ident, start, end)
    }
    @inline(always)
    mutating func createContinueStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createContinueStatement(location, ident, start, end)
    }
    @inline(always)
    mutating func createTryStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ tryBlock: Node,
        _ catchPattern: Node,
        _ catchBlock: Node,
        _ finallyBlock: Node,
        _ catchEnvironment: JSC.JSParseEnvironment
    ) -> Node {
        facade.createTryStatement(location, tryBlock, catchPattern, catchBlock, finallyBlock, catchEnvironment)
    }
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
    ) -> Node {
        facade.createSwitchStatement(location, expr, firstClauses, defaultClause, secondClauses, lexicalVariables, functionStack)
    }
    @inline(always)
    mutating func createWhileStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ statement: Node
    ) -> Node {
        facade.createWhileStatement(location, expr, statement)
    }
    @inline(always)
    mutating func createDoWhileStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ statement: Node,
        _ expr: Node
    ) -> Node {
        facade.createDoWhileStatement(location, statement, expr)
    }
    @inline(always)
    mutating func createLabelStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ ident: JSC.JSParseIdentifier,
        _ statement: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createLabelStatement(location, ident, statement, start, end)
    }
    @inline(always)
    mutating func createWithStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ statement: Node,
        _ start: UInt32,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createWithStatement(location, expr, statement, start, end)
    }
    @inline(always)
    mutating func createThrowStatement(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ expr: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createThrowStatement(location, expr, start, end)
    }
    @inline(always)
    mutating func createDebugger(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createDebugger(location)
    }
    @inline(always)
    mutating func createModuleName(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ moduleName: JSC.JSParseIdentifier
    ) -> Node {
        facade.createModuleName(location, moduleName)
    }
    @inline(always)
    mutating func createImportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ importedName: JSC.JSParseIdentifier,
        _ localName: JSC.JSParseIdentifier
    ) -> Node {
        facade.createImportSpecifier(location, importedName, localName)
    }
    @inline(always)
    mutating func createImportSpecifierList(
        _ facade: inout JSC.JSParseFacade
    ) -> Node {
        facade.createImportSpecifierList()
    }
    @inline(always)
    mutating func appendImportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ specifierList: Node,
        _ specifier: Node
    ) {
        facade.appendImportSpecifier(specifierList, specifier)
    }
    @inline(always)
    mutating func createImportAttributesList(
        _ facade: inout JSC.JSParseFacade
    ) -> Node {
        facade.createImportAttributesList()
    }
    @inline(always)
    mutating func appendImportAttribute(
        _ facade: inout JSC.JSParseFacade,
        _ attributesList: Node,
        _ key: JSC.JSParseIdentifier,
        _ value: JSC.JSParseIdentifier
    ) {
        facade.appendImportAttribute(attributesList, key, value)
    }
    @inline(always)
    mutating func createImportDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ type: JSC.ImportDeclarationNode.ImportType,
        _ importSpecifierList: Node,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node {
        facade.createImportDeclaration(location, type, importSpecifierList, moduleName, importAttributesList)
    }
    @inline(always)
    mutating func createExportAllDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node {
        facade.createExportAllDeclaration(location, moduleName, importAttributesList)
    }
    @inline(always)
    mutating func createExportDefaultDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ declaration: Node,
        _ localName: JSC.JSParseIdentifier
    ) -> Node {
        facade.createExportDefaultDeclaration(location, declaration, localName)
    }
    @inline(always)
    mutating func createExportLocalDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ declaration: Node
    ) -> Node {
        facade.createExportLocalDeclaration(location, declaration)
    }
    @inline(always)
    mutating func createExportNamedDeclaration(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ exportSpecifierList: Node,
        _ moduleName: Node,
        _ importAttributesList: Node
    ) -> Node {
        facade.createExportNamedDeclaration(location, exportSpecifierList, moduleName, importAttributesList)
    }
    @inline(always)
    mutating func createExportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ localName: JSC.JSParseIdentifier,
        _ exportedName: JSC.JSParseIdentifier
    ) -> Node {
        facade.createExportSpecifier(location, localName, exportedName)
    }
    @inline(always)
    mutating func createExportSpecifierList(
        _ facade: inout JSC.JSParseFacade
    ) -> Node {
        facade.createExportSpecifierList()
    }
    @inline(always)
    mutating func appendExportSpecifier(
        _ facade: inout JSC.JSParseFacade,
        _ specifierList: Node,
        _ specifier: Node
    ) {
        facade.appendExportSpecifier(specifierList, specifier)
    }
    @inline(always)
    mutating func appendStatement(
        _ facade: inout JSC.JSParseFacade,
        _ elements: Node,
        _ statement: Node
    ) {
        facade.appendStatement(elements, statement)
    }
    @inline(always)
    mutating func createCommaExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ node: Node
    ) -> Node {
        facade.createCommaExpr(location, node)
    }
    @inline(always)
    mutating func appendToCommaExpr(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ tail: Node,
        _ next: Node
    ) -> Node {
        facade.appendToCommaExpr(location, tail, next)
    }
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
        facade.appendBinaryExpressionInfo(&operandStackDepth, current, exprStart, lhs, rhs, hasAssignments)
    }
    @inline(always)
    mutating func operatorStackPop(
        _ facade: inout JSC.JSParseFacade,
        _ operatorStackDepth: inout Int32
    ) {
        facade.operatorStackPop(&operatorStackDepth)
    }
    @inline(always)
    mutating func operatorStackShouldReduce(
        _ facade: inout JSC.JSParseFacade,
        _ precedence: Int32
    ) -> Bool {
        facade.operatorStackShouldReduce(precedence)
    }
    @inline(always)
    mutating func getFromOperandStack(
        _ facade: inout JSC.JSParseFacade,
        _ i: Int32
    ) -> BinaryOperand {
        facade.getFromOperandStack(i)
    }
    @inline(always)
    mutating func shrinkOperandStackBy(
        _ facade: inout JSC.JSParseFacade,
        _ operandStackDepth: inout Int32,
        _ amount: Int32
    ) {
        facade.shrinkOperandStackBy(&operandStackDepth, amount)
    }
    @inline(always)
    mutating func appendBinaryOperation(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ operandStackDepth: inout Int32,
        _ operatorStackDepth: inout Int32,
        _ lhs: BinaryOperand,
        _ rhs: BinaryOperand
    ) {
        facade.appendBinaryOperation(location, &operandStackDepth, &operatorStackDepth, lhs, rhs)
    }
    @inline(always)
    mutating func operatorStackAppend(
        _ facade: inout JSC.JSParseFacade,
        _ operatorStackDepth: inout Int32,
        _ op: Int32,
        _ precedence: Int32
    ) {
        facade.operatorStackAppend(&operatorStackDepth, op, precedence)
    }
    @inline(always)
    mutating func popOperandStack(
        _ facade: inout JSC.JSParseFacade,
        _ depth: inout Int32
    ) -> Node {
        facade.popOperandStack(&depth)
    }
    @inline(always)
    mutating func appendUnaryToken(
        _ facade: inout JSC.JSParseFacade,
        _ tokenStackDepth: inout Int32,
        _ type: Int32,
        _ start: JSC.JSTextPosition
    ) {
        facade.appendUnaryToken(&tokenStackDepth, type, start)
    }
    @inline(always)
    mutating func unaryTokenStackLastType(
        _ facade: inout JSC.JSParseFacade,
        _ depth: inout Int32
    ) -> Int32 {
        facade.unaryTokenStackLastType(&depth)
    }
    @inline(always)
    mutating func unaryTokenStackLastStart(
        _ facade: inout JSC.JSParseFacade,
        _ depth: inout Int32
    ) -> JSC.JSTextPosition {
        facade.unaryTokenStackLastStart(&depth)
    }
    @inline(always)
    mutating func unaryTokenStackRemoveLast(
        _ facade: inout JSC.JSParseFacade,
        _ tokenStackDepth: inout Int32
    ) {
        facade.unaryTokenStackRemoveLast(&tokenStackDepth)
    }
    @inline(always)
    mutating func unaryTokenStackDepth(
        _ facade: inout JSC.JSParseFacade
    ) -> Int32 {
        facade.unaryTokenStackDepth()
    }
    @inline(always)
    mutating func setUnaryTokenStackDepth(
        _ facade: inout JSC.JSParseFacade,
        _ oldDepth: Int32
    ) {
        facade.setUnaryTokenStackDepth(oldDepth)
    }
    @inline(always)
    mutating func assignmentStackAppend(
        _ facade: inout JSC.JSParseFacade,
        _ assignmentStackDepth: inout Int32,
        _ node: Node,
        _ start: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ assignmentCount: Int32,
        _ op: JSC.Operator
    ) {
        facade.assignmentStackAppend(&assignmentStackDepth, node, start, divot, assignmentCount, op)
    }
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
        facade.createAssignment(location, &assignmentStackDepth, rhs, initialAssignmentCount, currentAssignmentCount, lastTokenEnd)
    }
    @inline(always)
    mutating func isUnderscoreProtoSetter(
        _ facade: inout JSC.JSParseFacade,
        _ property: Property
    ) -> Bool {
        facade.isUnderscoreProtoSetter(property)
    }
    @inline(always)
    mutating func isResolve(
        _ facade: inout JSC.JSParseFacade,
        _ expr: Node
    ) -> Bool {
        facade.isResolve(expr)
    }
    @inline(always)
    mutating func createDestructuringAssignment(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ initializer: Node
    ) -> Node {
        facade.createDestructuringAssignment(location, pattern, initializer)
    }
    @inline(always)
    mutating func createArrayPattern(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createArrayPattern(location)
    }
    @inline(always)
    mutating func appendArrayPatternSkipEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation
    ) {
        facade.appendArrayPatternSkipEntry(node, location)
    }
    @inline(always)
    mutating func appendArrayPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node,
        _ defaultValue: Node
    ) {
        facade.appendArrayPatternEntry(node, location, pattern, defaultValue)
    }
    @inline(always)
    mutating func appendArrayPatternRestEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node
    ) {
        facade.appendArrayPatternRestEntry(node, location, pattern)
    }
    @inline(always)
    mutating func finishArrayPattern(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) {
        facade.finishArrayPattern(node, divotStart, divot, divotEnd)
    }
    @inline(always)
    mutating func createObjectPattern(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation
    ) -> Node {
        facade.createObjectPattern(location)
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
    ) {
        facade.appendObjectPatternEntry(node, location, wasString, identifier, pattern, defaultValue)
    }
    @inline(always)
    mutating func appendObjectPatternEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ propertyExpression: Node,
        _ pattern: Node,
        _ defaultValue: Node
    ) {
        facade.appendObjectPatternEntry(node, location, propertyExpression, pattern, defaultValue)
    }
    @inline(always)
    mutating func appendObjectPatternRestEntry(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ location: JSC.JSTokenLocation,
        _ pattern: Node
    ) {
        facade.appendObjectPatternRestEntry(node, location, pattern)
    }
    @inline(always)
    mutating func setContainsObjectRestElement(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ containsRestElement: Bool
    ) {
        facade.setContainsObjectRestElement(node, containsRestElement)
    }
    @inline(always)
    mutating func setContainsComputedProperty(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ containsComputedProperty: Bool
    ) {
        facade.setContainsComputedProperty(node, containsComputedProperty)
    }
    @inline(always)
    mutating func finishObjectPattern(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ divotStart: JSC.JSTextPosition,
        _ divot: JSC.JSTextPosition,
        _ divotEnd: JSC.JSTextPosition
    ) {
        facade.finishObjectPattern(node, divotStart, divot, divotEnd)
    }
    @inline(always)
    mutating func createBindingLocation(
        _ facade: inout JSC.JSParseFacade,
        _ location: JSC.JSTokenLocation,
        _ boundProperty: JSC.JSParseIdentifier,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition,
        _ context: JSC.AssignmentContext
    ) -> Node {
        facade.createBindingLocation(location, boundProperty, start, end, context)
    }
    @inline(always)
    mutating func createRestParameter(
        _ facade: inout JSC.JSParseFacade,
        _ pattern: Node,
        _ numParametersToSkip: Int
    ) -> Node {
        facade.createRestParameter(pattern, numParametersToSkip)
    }
    @inline(always)
    mutating func createAssignmentElement(
        _ facade: inout JSC.JSParseFacade,
        _ assignmentTarget: Node,
        _ start: JSC.JSTextPosition,
        _ end: JSC.JSTextPosition
    ) -> Node {
        facade.createAssignmentElement(assignmentTarget, start, end)
    }
    @inline(always)
    mutating func setEndOffset(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ offset: Int32
    ) {
        facade.setEndOffset(node, offset)
    }
    @inline(always)
    mutating func endOffset(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> Int32 {
        facade.endOffset(node)
    }
    @inline(always)
    mutating func setStartOffset(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ offset: Int32
    ) {
        facade.setStartOffset(node, offset)
    }
    @inline(always)
    mutating func setStartOffsetWithNode(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node,
        _ offset: Int32
    ) {
        facade.setStartOffsetWithNode(node, offset)
    }
    @inline(always)
    mutating func breakpointLocation(
        _ facade: inout JSC.JSParseFacade,
        _ node: Node
    ) -> JSC.JSTextPosition {
        facade.breakpointLocation(node)
    }
    @inline(always)
    mutating func propagateArgumentsUse(
        _ facade: inout JSC.JSParseFacade
    ) {
        facade.propagateArgumentsUse()
    }
    @inline(always)
    mutating func hasArgumentsFeature(
        _ facade: inout JSC.JSParseFacade
    ) -> Bool {
        facade.hasArgumentsFeature()
    }
}

extension JSC.JSParseFunctionInfo {
    @inline(always)
    init(_ info: FunctionInfo<ASTBuilderAdapter>) {
        self.init()
        name = info.name
        body = info.body
        parameterCount = info.parameterCount
        functionLength = info.functionLength
        startOffset = info.startOffset
        endOffset = info.endOffset
    }
}
