/*
 * Copyright (C) 2010-2019 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ASTBuilder.h"

namespace JSC {

// ASTBuilder's out-of-line members: compiled here, once, and called by the Swift through the facade, so the Swift
// does not compile the nodes they allocate (their vtables would name typeinfo that RTTI-less C++ never emits).

ExpressionNode* ASTBuilder::createNewTargetExpr(const JSTokenLocation location)
{
    usesNewTarget();
    return new (m_parserArena) NewTargetNode(location);
}

ExpressionNode* ASTBuilder::createImportMetaExpr(const JSTokenLocation& location, ExpressionNode* expr)
{
    return new (m_parserArena) ImportMetaNode(location, expr);
}

ExpressionNode* ASTBuilder::createDotAccess(const JSTokenLocation& location, ExpressionNode* base, const Identifier* property, DotType type, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
{
    if (base->isSuperNode())
        usesSuperProperty();

    DotAccessorNode* node = new (m_parserArena) DotAccessorNode(location, base, *property, type);
    setExceptionLocation(node, start, divot, end);
    return node;
}

ExpressionNode* ASTBuilder::createDoubleExpr(const JSTokenLocation& location, double d)
{
    return new (m_parserArena) DoubleNode(location, d);
}

ExpressionNode* ASTBuilder::createIntegerExpr(const JSTokenLocation& location, double d)
{
    return new (m_parserArena) IntegerNode(location, d);
}

ExpressionNode* ASTBuilder::createBoolean(const JSTokenLocation& location, bool b)
{
    return new (m_parserArena) BooleanNode(location, b);
}

ExpressionNode* ASTBuilder::createNull(const JSTokenLocation& location)
{
    return new (m_parserArena) NullNode(location);
}

ExpressionNode* ASTBuilder::createPrivateIdentifierNode(const JSTokenLocation& location, const Identifier& ident)
{
    return new (m_parserArena) PrivateIdentifierNode(location, ident);
}

ExpressionNode* ASTBuilder::createFunctionExpr(const JSTokenLocation& location, const ParserFunctionInfo<ASTBuilder>& functionInfo)
{
    FuncExprNode* result = new (m_parserArena) FuncExprNode(location, *functionInfo.name, functionInfo.body,
        m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.endOffset));
    functionInfo.body->setStartOffset(location.startOffset);
    return result;
}

ExpressionNode* ASTBuilder::createAsyncFunctionBody(const JSTokenLocation& location, const ParserFunctionInfo<ASTBuilder>& functionInfo, SourceParseMode parseMode, const Identifier& name)
{
    if (parseMode == SourceParseMode::AsyncArrowFunctionBodyMode) {
        SourceCode source = m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.body->isArrowFunctionBodyExpression() ? functionInfo.endOffset - 1 : functionInfo.endOffset);
        FuncExprNode* result = new (m_parserArena) FuncExprNode(location, *functionInfo.name, functionInfo.body, source);
        if (!name.isNull())
            result->metadata()->setEcmaName(name);
        functionInfo.body->setStartOffset(location.startOffset);
        return result;
    }
    FuncExprNode* result =  static_cast<FuncExprNode*>(createFunctionExpr(location, functionInfo));
    if (!name.isNull())
        result->metadata()->setEcmaName(name);
    return result;
}

ExpressionNode* ASTBuilder::createMethodDefinition(const JSTokenLocation& location, const ParserFunctionInfo<ASTBuilder>& functionInfo)
{
    MethodDefinitionNode* result = new (m_parserArena) MethodDefinitionNode(location, *functionInfo.name, functionInfo.body,
        m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.endOffset));
    functionInfo.body->setStartOffset(location.startOffset);
    return result;
}

ExpressionNode* ASTBuilder::createArrowFunctionExpr(const JSTokenLocation& location, const ParserFunctionInfo<ASTBuilder>& functionInfo)
{
    usesArrowFunction();
    SourceCode source = m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.body->isArrowFunctionBodyExpression() ? functionInfo.endOffset - 1 : functionInfo.endOffset);
    ArrowFuncExprNode* result = new (m_parserArena) ArrowFuncExprNode(location, *functionInfo.name, functionInfo.body, source);
    functionInfo.body->setStartOffset(location.startOffset);
    return result;
}

PropertyNode* ASTBuilder::createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type,
    const Identifier* name, const ParserFunctionInfo<ASTBuilder>& functionInfo, ClassElementTag tag)
{
    ASSERT(name);
    functionInfo.body->setStartOffset(location.startOffset);
    functionInfo.body->setEcmaName(*name);
    SourceCode source = m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.endOffset);
    MethodDefinitionNode* methodDef = new (m_parserArena) MethodDefinitionNode(location, m_vm.propertyNames->nullIdentifier, functionInfo.body, source);
    return new (m_parserArena) PropertyNode(*name, methodDef, type, SuperBinding::Needed, tag);
}

PropertyNode* ASTBuilder::createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type,
    ExpressionNode* name, const ParserFunctionInfo<ASTBuilder>& functionInfo, ClassElementTag tag)
{
    ASSERT(name);
    functionInfo.body->setStartOffset(location.startOffset);
    SourceCode source = m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.endOffset);
    MethodDefinitionNode* methodDef = new (m_parserArena) MethodDefinitionNode(location, m_vm.propertyNames->nullIdentifier, functionInfo.body, source);
    return new (m_parserArena) PropertyNode(name, methodDef, type, SuperBinding::Needed, tag);
}

PropertyNode* ASTBuilder::createGetterOrSetterProperty(VM& vm, ParserArena& parserArena, const JSTokenLocation& location, PropertyNode::Type type,
    double name, const ParserFunctionInfo<ASTBuilder>& functionInfo, ClassElementTag tag)
{
    functionInfo.body->setStartOffset(location.startOffset);
    const Identifier& ident = parserArena.identifierArena().makeNumericIdentifier(vm, name);
    functionInfo.body->setEcmaName(ident);
    SourceCode source = m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.endOffset);
    MethodDefinitionNode* methodDef = new (m_parserArena) MethodDefinitionNode(location, vm.propertyNames->nullIdentifier, functionInfo.body, source);
    return new (m_parserArena) PropertyNode(ident, methodDef, type, SuperBinding::Needed, tag);
}

ExpressionNode* ASTBuilder::createIntegerLikeNumber(const JSTokenLocation& location, double d)
{
    return new (m_parserArena) IntegerNode(location, d);
}

ExpressionNode* ASTBuilder::createDoubleLikeNumber(const JSTokenLocation& location, double d)
{
    return new (m_parserArena) DoubleNode(location, d);
}

ExpressionNode* ASTBuilder::makeTypeOfNode(const JSTokenLocation& location, ExpressionNode* expr, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
{
    if (expr->isResolveNode()) {
        ResolveNode* resolve = static_cast<ResolveNode*>(expr);
        return new (m_parserArena) TypeOfResolveNode(location, resolve->identifier(), start, divot, end);
    }
    return new (m_parserArena) TypeOfValueNode(location, expr);
}

ExpressionNode* ASTBuilder::makeDeleteNode(const JSTokenLocation& location, ExpressionNode* expr, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
{
    if (expr->isOptionalChain()) {
        OptionalChainNode* optionalChain = static_cast<OptionalChainNode*>(expr);
        if (optionalChain->expr()->isLocation()) {
            ASSERT(!optionalChain->expr()->isResolveNode());
            optionalChain->setExpr(makeDeleteNode(location, optionalChain->expr(), start, divot, end));
            return optionalChain;
        }
    }

    if (!expr->isLocation())
        return new (m_parserArena) DeleteValueNode(location, expr);
    if (expr->isResolveNode()) {
        ResolveNode* resolve = static_cast<ResolveNode*>(expr);
        return new (m_parserArena) DeleteResolveNode(location, resolve->identifier(), divot, start, end);
    }
    if (expr->isBracketAccessorNode()) {
        BracketAccessorNode* bracket = static_cast<BracketAccessorNode*>(expr);
        return new (m_parserArena) DeleteBracketNode(location, bracket->base(), bracket->subscript(), divot, start, end);
    }
    ASSERT(expr->isDotAccessorNode());
    checkArgumentsLengthModification(expr);
    DotAccessorNode* dot = static_cast<DotAccessorNode*>(expr);
    return new (m_parserArena) DeleteDotNode(location, dot->base(), dot->identifier(), divot, start, end);
}

ExpressionNode* ASTBuilder::makeNegateNode(const JSTokenLocation& location, ExpressionNode* n)
{
    if (n->isNumber()) {
        const NumberNode& numberNode = static_cast<const NumberNode&>(*n);
        return createNumberFromUnaryOperation(location, -numberNode.value(), numberNode);
    }

    if (n->isBigInt()) {
        const BigIntNode& bigIntNode = static_cast<const BigIntNode&>(*n);
        return createBigIntFromUnaryOperation(location, !bigIntNode.sign(), bigIntNode);
    }

    return new (m_parserArena) NegateNode(location, n);
}

ExpressionNode* ASTBuilder::makeBitwiseNotNode(const JSTokenLocation& location, ExpressionNode* expr)
{
    if (expr->isNumber())
        return createIntegerLikeNumber(location, ~toInt32(static_cast<NumberNode*>(expr)->value()));
    return new (m_parserArena) BitwiseNotNode(location, expr);
}

ExpressionNode* ASTBuilder::makePowNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createNumberFromBinaryOperation(location, operationMathPow(numberExpr1.value(), numberExpr2.value()), numberExpr1, numberExpr2);
    }

    return new (m_parserArena) PowNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeMultNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createNumberFromBinaryOperation(location, numberExpr1.value() * numberExpr2.value(), numberExpr1, numberExpr2);
    }

    if (expr1->isNumber() && static_cast<NumberNode*>(expr1)->value() == 1)
        return createUnaryPlus(location, expr2);

    if (expr2->isNumber() && static_cast<NumberNode*>(expr2)->value() == 1)
        return createUnaryPlus(location, expr1);

    return new (m_parserArena) MultNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeDivNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        double result = numberExpr1.value() / numberExpr2.value();
        if (truncateDoubleToInt64(result) == result)
            return createNumberFromBinaryOperation(location, result, numberExpr1, numberExpr2);
        return createDoubleLikeNumber(location, result);
    }
    return new (m_parserArena) DivNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeModNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, fmod(numberExpr1.value(), numberExpr2.value()));
    }
    return new (m_parserArena) ModNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeAddNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createNumberFromBinaryOperation(location, numberExpr1.value() + numberExpr2.value(), numberExpr1, numberExpr2);
    }
    return new (m_parserArena) AddNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeSubNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createNumberFromBinaryOperation(location, numberExpr1.value() - numberExpr2.value(), numberExpr1, numberExpr2);
    }
    return new (m_parserArena) SubNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeLeftShiftNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, toInt32(numberExpr1.value()) << (toUInt32(numberExpr2.value()) & 0x1f));
    }
    return new (m_parserArena) LeftShiftNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeRightShiftNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, toInt32(numberExpr1.value()) >> (toUInt32(numberExpr2.value()) & 0x1f));
    }
    return new (m_parserArena) RightShiftNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeURightShiftNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, toUInt32(numberExpr1.value()) >> (toUInt32(numberExpr2.value()) & 0x1f));
    }
    return new (m_parserArena) UnsignedRightShiftNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeBitOrNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, toInt32(numberExpr1.value()) | toInt32(numberExpr2.value()));
    }
    return new (m_parserArena) BitOrNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeBitAndNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, toInt32(numberExpr1.value()) & toInt32(numberExpr2.value()));
    }
    return new (m_parserArena) BitAndNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeBitXOrNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2, bool rightHasAssignments)
{
    if (expr1->isNumber() && expr2->isNumber()) {
        const NumberNode& numberExpr1 = static_cast<NumberNode&>(*expr1);
        const NumberNode& numberExpr2 = static_cast<NumberNode&>(*expr2);
        return createIntegerLikeNumber(location, toInt32(numberExpr1.value()) ^ toInt32(numberExpr2.value()));
    }
    return new (m_parserArena) BitXOrNode(location, expr1, expr2, rightHasAssignments);
}

ExpressionNode* ASTBuilder::makeCoalesceNode(const JSTokenLocation& location, ExpressionNode* expr1, ExpressionNode* expr2)
{
    // Optimization for `x?.y ?? z`.
    if (expr1->isOptionalChain()) {
        OptionalChainNode* optionalChain = static_cast<OptionalChainNode*>(expr1);
        if (!optionalChain->expr()->isDeleteNode()) {
            constexpr bool hasAbsorbedOptionalChain = true;
            return new (m_parserArena) CoalesceNode(location, optionalChain->expr(), expr2, hasAbsorbedOptionalChain);
        }
    }
    constexpr bool hasAbsorbedOptionalChain = false;
    return new (m_parserArena) CoalesceNode(location, expr1, expr2, hasAbsorbedOptionalChain);
}

ExpressionNode* ASTBuilder::makeStaticBlockFunctionCallNode(const JSTokenLocation& location, ExpressionNode* func, const JSTextPosition& divot, const JSTextPosition& divotStart, const JSTextPosition& divotEnd)
{
    return new (m_parserArena) StaticBlockFunctionCallNode(location, func, divot, divotStart, divotEnd);
}

ExpressionNode* ASTBuilder::makeFunctionCallNode(const JSTokenLocation& location, ExpressionNode* func, bool previousBaseWasSuper, ArgumentsNode* args, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd, size_t callOrApplyChildDepth, bool isOptionalCall)
{
    if (func->isSuperNode())
        usesSuperCall();

    if (func->isBytecodeIntrinsicNode()) {
        ASSERT(!isOptionalCall);
        BytecodeIntrinsicNode* intrinsic = static_cast<BytecodeIntrinsicNode*>(func);
        if (intrinsic->type() == BytecodeIntrinsicNode::Type::Constant && intrinsic->entry().type() == BytecodeIntrinsicRegistry::Type::Emitter)
            return new (m_parserArena) BytecodeIntrinsicNode(BytecodeIntrinsicNode::Type::Function, location, intrinsic->entry(), intrinsic->identifier(), args, divot, divotStart, divotEnd);
    }

    if (isOptionalCall && func->isOptionalChain()) {
        OptionalChainNode* optionalChain = static_cast<OptionalChainNode*>(func);
        if (optionalChain->expr()->isLocation()) {
            ASSERT(!optionalChain->expr()->isResolveNode());
            // We must take care to preserve our `this` value in cases like `a?.b?.()`.
            return makeFunctionCallNode(location, optionalChain->expr(), previousBaseWasSuper, args, divotStart, divot, divotEnd, callOrApplyChildDepth, isOptionalCall);
        }
    }

    if (!func->isLocation())
        return new (m_parserArena) FunctionCallValueNode(location, func, args, divot, divotStart, divotEnd, isOptionalCall);
    if (func->isResolveNode()) {
        ResolveNode* resolve = static_cast<ResolveNode*>(func);
        const Identifier& identifier = resolve->identifier();
        if (identifier == m_vm.propertyNames->eval && !isOptionalCall) {
            usesEval();
            return new (m_parserArena) EvalFunctionCallNode(location, args, divot, divotStart, divotEnd);
        }
        return new (m_parserArena) FunctionCallResolveNode(location, identifier, args, divot, divotStart, divotEnd, isOptionalCall);
    }
    if (func->isBracketAccessorNode()) {
        BracketAccessorNode* bracket = static_cast<BracketAccessorNode*>(func);
        FunctionCallBracketNode* node = new (m_parserArena) FunctionCallBracketNode(location, bracket->base(), bracket->subscript(), bracket->subscriptHasAssignments(), args, divot, divotStart, divotEnd, isOptionalCall);
        node->setSubexpressionInfo(bracket->divot(), bracket->divotEnd().offset);
        return node;
    }
    ASSERT(func->isDotAccessorNode());
    DotAccessorNode* dot = static_cast<DotAccessorNode*>(func);
    FunctionCallDotNode* node = nullptr;
    if (!previousBaseWasSuper && (dot->identifier() == m_vm.propertyNames->builtinNames().callPublicName() || dot->identifier() == m_vm.propertyNames->builtinNames().callPrivateName()))
        node = new (m_parserArena) CallFunctionCallDotNode(location, dot->base(), dot->identifier(), dot->type(), args, divot, divotStart, divotEnd, isOptionalCall, callOrApplyChildDepth);
    else if (!previousBaseWasSuper && (dot->identifier() == m_vm.propertyNames->builtinNames().applyPublicName() || dot->identifier() == m_vm.propertyNames->builtinNames().applyPrivateName())) {
        // FIXME: This check is only needed because we haven't taught the bytecode generator to inline
        // Reflect.apply yet. See https://bugs.webkit.org/show_bug.cgi?id=190668.
        if (!dot->base()->isResolveNode() || static_cast<ResolveNode*>(dot->base())->identifier() != m_vm.propertyNames->Reflect)
            node = new (m_parserArena) ApplyFunctionCallDotNode(location, dot->base(), dot->identifier(), dot->type(), args, divot, divotStart, divotEnd, isOptionalCall, callOrApplyChildDepth);
    } else if (!previousBaseWasSuper
        && dot->identifier() == m_vm.propertyNames->hasOwnProperty
        && args->m_listNode
        && args->m_listNode->m_expr
        && args->m_listNode->m_expr->isResolveNode()
        && !args->m_listNode->m_next
        && (dot->base()->isResolveNode() || dot->base()->isThisNode())) {
        // We match the AST pattern:
        // <resolveNode|thisNode>.hasOwnProperty(<resolveNode>)
        // i.e:
        // o.hasOwnProperty(p)
        node = new (m_parserArena) HasOwnPropertyFunctionCallDotNode(location, dot->base(), dot->identifier(), dot->type(), args, divot, divotStart, divotEnd, isOptionalCall);
    } else if (dot->identifier() == m_vm.propertyNames->construct
        && dot->base()->isResolveNode()
        && static_cast<ResolveNode*>(dot->base())->identifier() == m_vm.propertyNames->Reflect
        && args->m_listNode
        && args->m_listNode->m_next) {
        node = new (m_parserArena) ReflectConstructFunctionCallDotNode(location, dot->base(), dot->identifier(), dot->type(), args, divot, divotStart, divotEnd, isOptionalCall);
    }
    if (!node)
        node = new (m_parserArena) FunctionCallDotNode(location, dot->base(), dot->identifier(), dot->type(), args, divot, divotStart, divotEnd, isOptionalCall);
    node->setSubexpressionInfo(dot->divot(), dot->divotEnd().offset);
    return node;
}

ExpressionNode* ASTBuilder::makeBinaryNode(const JSTokenLocation& location, int token, std::pair<ExpressionNode*, BinaryOpInfo> lhs, std::pair<ExpressionNode*, BinaryOpInfo> rhs)
{
    switch (token) {
    case COALESCE:
        return makeCoalesceNode(location, lhs.first, rhs.first);

    case OR:
        return new (m_parserArena) LogicalOpNode(location, lhs.first, rhs.first, LogicalOperator::Or);

    case AND:
        return new (m_parserArena) LogicalOpNode(location, lhs.first, rhs.first, LogicalOperator::And);

    case BITOR:
        return makeBitOrNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case BITXOR:
        return makeBitXOrNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case BITAND:
        return makeBitAndNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case EQEQ:
        return new (m_parserArena) EqualNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case NE:
        return new (m_parserArena) NotEqualNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case STREQ:
        return new (m_parserArena) StrictEqualNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case STRNEQ:
        return new (m_parserArena) NotStrictEqualNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case LT:
        return new (m_parserArena) LessNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case GT:
        return new (m_parserArena) GreaterNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case LE:
        return new (m_parserArena) LessEqNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case GE:
        return new (m_parserArena) GreaterEqNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case INSTANCEOF: {
        InstanceOfNode* node = new (m_parserArena) InstanceOfNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);
        setExceptionLocation(node, lhs.second.start, rhs.second.start, rhs.second.end);
        return node;
    }

    case INTOKEN: {
        InNode* node = new (m_parserArena) InNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);
        setExceptionLocation(node, lhs.second.start, rhs.second.start, rhs.second.end);
        return node;
    }

    case LSHIFT:
        return makeLeftShiftNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case RSHIFT:
        return makeRightShiftNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case URSHIFT:
        return makeURightShiftNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case PLUS:
        return makeAddNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case MINUS:
        return makeSubNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case TIMES:
        return makeMultNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case DIVIDE:
        return makeDivNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case MOD:
        return makeModNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);

    case POW:
        return makePowNode(location, lhs.first, rhs.first, rhs.second.hasAssignment);
    }
    CRASH();
    return nullptr;
}

ExpressionNode* ASTBuilder::makeAssignNode(const JSTokenLocation& location, ExpressionNode* loc, Operator op, ExpressionNode* expr, bool locHasAssignments, bool exprHasAssignments, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
{
    if (!loc->isLocation()) {
        ASSERT(loc->isFunctionCall());
        return new (m_parserArena) AssignErrorNode(location, loc, divot, start, end);
    }

    if (loc->isResolveNode()) {
        ResolveNode* resolve = static_cast<ResolveNode*>(loc);

        if (op == Operator::Equal) {
            if (!resolve->isParenthesized()) {
                if (expr->isBaseFuncExprNode()) {
                    auto metadata = static_cast<BaseFuncExprNode*>(expr)->metadata();
                    metadata->setEcmaName(resolve->identifier());
                } else if (expr->isClassExprNode())
                    static_cast<ClassExprNode*>(expr)->setEcmaName(resolve->identifier());
            }
            AssignResolveNode* node = new (m_parserArena) AssignResolveNode(location, resolve->identifier(), expr, AssignmentContext::AssignmentExpression);
            setExceptionLocation(node, start, divot, end);
            return node;
        }

        if (op == Operator::CoalesceEq || op == Operator::OrEq || op == Operator::AndEq) {
            if (!resolve->isParenthesized()) {
                if (expr->isBaseFuncExprNode()) {
                    auto metadata = static_cast<BaseFuncExprNode*>(expr)->metadata();
                    metadata->setEcmaName(resolve->identifier());
                } else if (expr->isClassExprNode())
                    static_cast<ClassExprNode*>(expr)->setEcmaName(resolve->identifier());
            }
            return new (m_parserArena) ShortCircuitReadModifyResolveNode(location, resolve->identifier(), op, expr, exprHasAssignments, divot, start, end);
        }

        return new (m_parserArena) ReadModifyResolveNode(location, resolve->identifier(), op, expr, exprHasAssignments, divot, start, end);
    }

    if (loc->isBracketAccessorNode()) {
        BracketAccessorNode* bracket = static_cast<BracketAccessorNode*>(loc);

        if (op == Operator::Equal)
            return new (m_parserArena) AssignBracketNode(location, bracket->base(), bracket->subscript(), expr, locHasAssignments, exprHasAssignments, bracket->divot(), start, end);

        if (op == Operator::CoalesceEq || op == Operator::OrEq || op == Operator::AndEq) {
            auto* node = new (m_parserArena) ShortCircuitReadModifyBracketNode(location, bracket->base(), bracket->subscript(), op, expr, locHasAssignments, exprHasAssignments, divot, start, end);
            node->setSubexpressionInfo(bracket->divot(), bracket->divotEnd().offset);
            return node;
        }

        ReadModifyBracketNode* node = new (m_parserArena) ReadModifyBracketNode(location, bracket->base(), bracket->subscript(), op, expr, locHasAssignments, exprHasAssignments, divot, start, end);
        node->setSubexpressionInfo(bracket->divot(), bracket->divotEnd().offset);
        return node;
    }

    ASSERT(loc->isDotAccessorNode());
    DotAccessorNode* dot = static_cast<DotAccessorNode*>(loc);

    if (op == Operator::Equal)
        return new (m_parserArena) AssignDotNode(location, dot->base(), dot->identifier(), dot->type(), expr, exprHasAssignments, dot->divot(), start, end);

    if (op == Operator::CoalesceEq || op == Operator::OrEq || op == Operator::AndEq) {
        auto* node = new (m_parserArena) ShortCircuitReadModifyDotNode(location, dot->base(), dot->identifier(), dot->type(), op, expr, exprHasAssignments, divot, start, end);
        node->setSubexpressionInfo(dot->divot(), dot->divotEnd().offset);
        return node;
    }

    ReadModifyDotNode* node = new (m_parserArena) ReadModifyDotNode(location, dot->base(), dot->identifier(), dot->type(), op, expr, exprHasAssignments, divot, start, end);
    node->setSubexpressionInfo(dot->divot(), dot->divotEnd().offset);
    return node;
}

ExpressionNode* ASTBuilder::makePrefixNode(const JSTokenLocation& location, ExpressionNode* expr, Operator op, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
{
    checkArgumentsLengthModification(expr);
    return new (m_parserArena) PrefixNode(location, expr, op, divot, start, end);
}

ExpressionNode* ASTBuilder::makePostfixNode(const JSTokenLocation& location, ExpressionNode* expr, Operator op, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
{
    checkArgumentsLengthModification(expr);
    return new (m_parserArena) PostfixNode(location, expr, op, divot, start, end);
}

} // namespace JSC
