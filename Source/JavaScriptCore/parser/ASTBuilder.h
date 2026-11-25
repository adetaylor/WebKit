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

#pragma once

#include "BuiltinNames.h"
#include "BytecodeIntrinsicRegistry.h"
#include "MathCommon.h"
#include "NodeConstructors.h"
#include "Parser.h"
#include "ParserFunctionInfo.h"
#include "VariableEnvironment.h"
#include "YarrSyntaxChecker.h"
#include <utility>
#include <wtf/MathExtras.h>

namespace JSC {

enum class InferName {
    Allowed,
    Disallowed,
};

class ASTBuilder {
    struct BinaryOpInfo {
        BinaryOpInfo() {}
        BinaryOpInfo(const JSTextPosition& otherStart, const JSTextPosition& otherDivot, const JSTextPosition& otherEnd, bool rhsHasAssignment)
            : start(otherStart)
            , divot(otherDivot)
            , end(otherEnd)
            , hasAssignment(rhsHasAssignment)
        {
        }
        BinaryOpInfo(const BinaryOpInfo& lhs, const BinaryOpInfo& rhs)
            : start(lhs.start)
            , divot(rhs.start)
            , end(rhs.end)
            , hasAssignment(lhs.hasAssignment || rhs.hasAssignment)
        {
        }
        JSTextPosition start;
        JSTextPosition divot;
        JSTextPosition end;
        bool hasAssignment;
    };
    
    
    struct AssignmentInfo {
        AssignmentInfo() {}
        AssignmentInfo(ExpressionNode* node, const JSTextPosition& start, const JSTextPosition& divot, int initAssignments, Operator op)
            : m_node(node)
            , m_start(start)
            , m_divot(divot)
            , m_initAssignments(initAssignments)
            , m_op(op)
        {
        }
        ExpressionNode* m_node;
        JSTextPosition m_start;
        JSTextPosition m_divot;
        int m_initAssignments;
        Operator m_op;
    };
public:
    ASTBuilder(VM& vm, ParserArena& parserArena, const SourceCode* sourceCode)
        : m_vm(vm)
        , m_parserArena(parserArena)
        , m_sourceCode(sourceCode)
        , m_evalCount(0)
    {
    }
    
    struct BinaryExprContext {
        BinaryExprContext(ASTBuilder&) {}
    };
    struct UnaryExprContext {
        UnaryExprContext(ASTBuilder&) {}
    };

    typedef ExpressionNode* Expression;
    typedef JSC::SourceElements* SourceElements;
    typedef PropertyNode* Property;
    typedef FunctionParameters* FormalParameterList;
    typedef FunctionMetadataNode* FunctionBody;
    typedef std::pair<ExpressionNode*, BinaryOpInfo> BinaryOperand;
    typedef DestructuringPatternNode* DestructuringPattern;
    typedef ArrayPatternNode* ArrayPattern;
    typedef ObjectPatternNode* ObjectPattern;
    typedef BindingNode* BindingPattern;
    typedef AssignmentElementNode* AssignmentElement;

    ExpressionNode* makeBinaryNode(const JSTokenLocation&, int token, std::pair<ExpressionNode*, BinaryOpInfo>, std::pair<ExpressionNode*, BinaryOpInfo>);
    ExpressionNode* makeStaticBlockFunctionCallNode(const JSTokenLocation&, ExpressionNode* func, const JSTextPosition& divot, const JSTextPosition& divotStart, const JSTextPosition& divotEnd);
    ExpressionNode* makeFunctionCallNode(const JSTokenLocation&, ExpressionNode* func, bool previousBaseWasSuper, ArgumentsNode* args, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd, size_t callOrApplyChildDepth, bool isOptionalCall);

    JSC::SourceElements* createSourceElements() { return new (m_parserArena) JSC::SourceElements(); }

    int features() const { return m_scope.m_features; }

    ExpressionNode* makeAssignNode(const JSTokenLocation&, ExpressionNode* left, Operator, ExpressionNode* right, bool leftHasAssignments, bool rightHasAssignments, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end);
    ExpressionNode* makePrefixNode(const JSTokenLocation&, ExpressionNode*, Operator, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end);
    ExpressionNode* makePostfixNode(const JSTokenLocation&, ExpressionNode*, Operator, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end);
    ExpressionNode* makeTypeOfNode(const JSTokenLocation&, ExpressionNode*, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end);
    ExpressionNode* makeDeleteNode(const JSTokenLocation&, ExpressionNode*, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end);
    ExpressionNode* makeNegateNode(const JSTokenLocation&, ExpressionNode*);
    ExpressionNode* makeBitwiseNotNode(const JSTokenLocation&, ExpressionNode*);
    ExpressionNode* makePowNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeMultNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeDivNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeModNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeAddNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeSubNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeBitXOrNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeBitAndNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeBitOrNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeCoalesceNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right);
    ExpressionNode* makeLeftShiftNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeRightShiftNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);
    ExpressionNode* makeURightShiftNode(const JSTokenLocation&, ExpressionNode* left, ExpressionNode* right, bool rightHasAssignments);

    ExpressionNode* createLogicalNot(const JSTokenLocation& location, ExpressionNode* expr)
    {
        if (expr->isNumber())
            return createBoolean(location, isZeroOrUnordered(static_cast<NumberNode*>(expr)->value()));

        return new (m_parserArena) LogicalNotNode(location, expr);
    }
    ExpressionNode* createUnaryPlus(const JSTokenLocation& location, ExpressionNode* expr)
    {
        // Unary plus is ToNumber, which is the identity for Number. For anything else, it is observable.
        if (expr->resultDescriptor().definitelyIsNumber())
            return expr;

        return new (m_parserArena) UnaryPlusNode(location, expr);
    }
    ExpressionNode* createVoid(const JSTokenLocation& location, ExpressionNode* expr)
    {
        return new (m_parserArena) VoidNode(location, expr);
    }
    ExpressionNode* createThisExpr(const JSTokenLocation& location)
    {
        usesThis();
        return new (m_parserArena) ThisNode(location);
    }
    ExpressionNode* createSuperExpr(const JSTokenLocation& location)
    {
        return new (m_parserArena) SuperNode(location);
    }
    ExpressionNode* createImportExpr(const JSTokenLocation& location, ExpressionNode* expr, ExpressionNode* option, bool deferred, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        auto* node = new (m_parserArena) ImportNode(location, expr, option, deferred);
        setExceptionLocation(node, start, divot, end);
        return node;
    }
    ExpressionNode* createNewTargetExpr(const JSTokenLocation);
    ExpressionNode* createImportMetaExpr(const JSTokenLocation&, ExpressionNode*);
    void setIsParenthesized(ExpressionNode* expr) { expr->setIsParenthesized(); }
    bool isMetaProperty(ExpressionNode* node) { return node->isMetaProperty(); }
    bool isNewTarget(ExpressionNode* node) { return node->isNewTarget(); }
    bool isImportMeta(ExpressionNode* node) { return node->isImportMeta(); }
    ExpressionNode* createResolve(const JSTokenLocation& location, const Identifier& ident, const JSTextPosition& start, const JSTextPosition& end, const bool needToCheckUsesArguments = true)
    {
        if (needToCheckUsesArguments && m_vm.propertyNames->arguments == ident)
            usesArguments();

        if (ident.isSymbol()) {
            auto entry = m_vm.bytecodeIntrinsicRegistry().lookup(ident);
            if (entry)
                return new (m_parserArena) BytecodeIntrinsicNode(BytecodeIntrinsicNode::Type::Constant, location, entry.value(), ident, nullptr, start, start, end);
        }

        return new (m_parserArena) ResolveNode(location, ident, start);
    }
    ExpressionNode* createPrivateIdentifierNode(const JSTokenLocation&, const Identifier&);
    ExpressionNode* createObjectLiteral(const JSTokenLocation& location) { return new (m_parserArena) ObjectLiteralNode(location); }
    ExpressionNode* createObjectLiteral(const JSTokenLocation& location, PropertyListNode* properties) { return new (m_parserArena) ObjectLiteralNode(location, properties); }

    ExpressionNode* createArray(const JSTokenLocation& location, int elisions)
    {
        return new (m_parserArena) ArrayNode(location, elisions);
    }

    ExpressionNode* createArray(const JSTokenLocation& location, ElementNode* elems) { return new (m_parserArena) ArrayNode(location, elems); }
    ExpressionNode* createArray(const JSTokenLocation& location, int elisions, ElementNode* elems)
    {
        return new (m_parserArena) ArrayNode(location, elisions, elems);
    }
    ExpressionNode* createDoubleExpr(const JSTokenLocation&, double);
    ExpressionNode* createIntegerExpr(const JSTokenLocation&, double);

    ExpressionNode* createBigInt(const JSTokenLocation& location, const Identifier* bigInt, uint8_t radix)
    {
        return new (m_parserArena) BigIntNode(location, *bigInt, radix);
    }

    ExpressionNode* createString(const JSTokenLocation& location, const Identifier* string)
    {
        ASSERT(string);
        return new (m_parserArena) StringNode(location, *string);
    }

    ExpressionNode* createBoolean(const JSTokenLocation&, bool);

    ExpressionNode* createNull(const JSTokenLocation&);

    ExpressionNode* createBracketAccess(const JSTokenLocation& location, ExpressionNode* base, ExpressionNode* property, bool propertyHasAssignments, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        if (base->isSuperNode())
            usesSuperProperty();

        BracketAccessorNode* node = new (m_parserArena) BracketAccessorNode(location, base, property, propertyHasAssignments);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    ExpressionNode* createDotAccess(const JSTokenLocation&, ExpressionNode* base, const Identifier* property, DotType, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end);

    ExpressionNode* createSpreadExpression(const JSTokenLocation& location, ExpressionNode* expression, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        auto node = new (m_parserArena) SpreadExpressionNode(location, expression);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    ExpressionNode* createObjectSpreadExpression(const JSTokenLocation& location, ExpressionNode* expression, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        auto node = new (m_parserArena) ObjectSpreadExpressionNode(location, expression);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    TemplateStringNode* createTemplateString(const JSTokenLocation& location, const Identifier* cooked, const Identifier* raw)
    {
        return new (m_parserArena) TemplateStringNode(location, cooked, raw);
    }

    TemplateStringListNode* createTemplateStringList(TemplateStringNode* templateString)
    {
        return new (m_parserArena) TemplateStringListNode(templateString);
    }

    TemplateStringListNode* createTemplateStringList(TemplateStringListNode* templateStringList, TemplateStringNode* templateString)
    {
        return new (m_parserArena) TemplateStringListNode(templateStringList, templateString);
    }

    TemplateExpressionListNode* createTemplateExpressionList(ExpressionNode* expression)
    {
        return new (m_parserArena) TemplateExpressionListNode(expression);
    }

    TemplateExpressionListNode* createTemplateExpressionList(TemplateExpressionListNode* templateExpressionListNode, ExpressionNode* expression)
    {
        return new (m_parserArena) TemplateExpressionListNode(templateExpressionListNode, expression);
    }

    TemplateLiteralNode* createTemplateLiteral(const JSTokenLocation& location, TemplateStringListNode* templateStringList)
    {
        return new (m_parserArena) TemplateLiteralNode(location, templateStringList);
    }

    TemplateLiteralNode* createTemplateLiteral(const JSTokenLocation& location, TemplateStringListNode* templateStringList, TemplateExpressionListNode* templateExpressionList)
    {
        return new (m_parserArena) TemplateLiteralNode(location, templateStringList, templateExpressionList);
    }

    ExpressionNode* createTaggedTemplate(const JSTokenLocation& location, ExpressionNode* base, TemplateLiteralNode* templateLiteral, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        auto node = new (m_parserArena) TaggedTemplateNode(location, base, templateLiteral);
        setExceptionLocation(node, start, divot, end);
        setEndOffset(node, end.offset);
        return node;
    }

    ExpressionNode* createRegExp(const JSTokenLocation& location, const Identifier& pattern, const Identifier& flags, const JSTextPosition& start, bool skipSyntaxCheck)
    {
        if (!skipSyntaxCheck && Yarr::hasError(Yarr::checkSyntax(pattern.string(), flags.string())))
            return nullptr;
        RegExpNode* node = new (m_parserArena) RegExpNode(location, pattern, flags);
        int size = pattern.length() + 2; // + 2 for the two /'s
        JSTextPosition end = start + size;
        setExceptionLocation(node, start, end, end);
        return node;
    }

    ExpressionNode* createNewExpr(const JSTokenLocation& location, ExpressionNode* expr, ArgumentsNode* arguments, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        NewExprNode* node = new (m_parserArena) NewExprNode(location, expr, arguments);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    ExpressionNode* createNewExpr(const JSTokenLocation& location, ExpressionNode* expr, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        NewExprNode* node = new (m_parserArena) NewExprNode(location, expr);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    ExpressionNode* createOptionalChain(const JSTokenLocation& location, ExpressionNode* base, ExpressionNode* expr, bool isOutermost)
    {
        if (base)
            base->setIsOptionalChainBase();
        return new (m_parserArena) OptionalChainNode(location, expr, isOutermost);
    }

    ExpressionNode* createConditionalExpr(const JSTokenLocation& location, ExpressionNode* condition, ExpressionNode* lhs, ExpressionNode* rhs)
    {
        return new (m_parserArena) ConditionalNode(location, condition, lhs, rhs);
    }

    ExpressionNode* createAssignResolve(const JSTokenLocation& location, const Identifier& ident, ExpressionNode* rhs, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end, AssignmentContext assignmentContext)
    {
        if (rhs->isBaseFuncExprNode()) {
            auto metadata = static_cast<BaseFuncExprNode*>(rhs)->metadata();
            metadata->setEcmaName(ident);
        } else if (rhs->isClassExprNode())
            static_cast<ClassExprNode*>(rhs)->setEcmaName(ident);
        if (assignmentContext == AssignmentContext::AwaitUsingDeclarationStatement)
            usesAwait();
        AssignResolveNode* node = new (m_parserArena) AssignResolveNode(location, ident, rhs, assignmentContext);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    YieldExprNode* createYield(const JSTokenLocation& location)
    {
        return new (m_parserArena) YieldExprNode(location, nullptr, /* delegate */ false);
    }

    YieldExprNode* createYield(const JSTokenLocation& location, ExpressionNode* argument, bool delegate, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        YieldExprNode* node = new (m_parserArena) YieldExprNode(location, argument, delegate);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    AwaitExprNode* createAwait(const JSTokenLocation& location, ExpressionNode* argument, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        ASSERT(argument);
        usesAwait();
        AwaitExprNode* node = new (m_parserArena) AwaitExprNode(location, argument);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    DefineFieldNode* createDefineField(const JSTokenLocation& location, const Identifier& ident, ExpressionNode* initializer, DefineFieldNode::Type type)
    {
        if (initializer && type != DefineFieldNode::Type::ComputedName) {
            if (initializer->isBaseFuncExprNode())
                static_cast<BaseFuncExprNode*>(initializer)->metadata()->setEcmaName(ident);
            else if (initializer->isClassExprNode())
                static_cast<ClassExprNode*>(initializer)->setEcmaName(ident);
        }
        return new (m_parserArena) DefineFieldNode(location, ident, initializer, type);
    }

    ClassExprNode* createClassExpr(const JSTokenLocation& location, const ParserClassInfo<ASTBuilder>& classInfo, VariableEnvironment&& classHeadEnvironment, VariableEnvironment&& classEnvironment, ExpressionNode* constructor,
        ExpressionNode* parentClass, PropertyListNode* classElements, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end)
    {
        SourceCode source = m_sourceCode->subExpression(classInfo.startOffset, classInfo.endOffset);
        ClassExprNode* node = new (m_parserArena) ClassExprNode(location, *classInfo.className, source, WTF::move(classHeadEnvironment), WTF::move(classEnvironment), constructor, parentClass, classElements);
        setExceptionLocation(node, start, divot, end);
        return node;
    }

    ExpressionNode* createFunctionExpr(const JSTokenLocation&, const ParserFunctionInfo<ASTBuilder>&);

    ExpressionNode* createGeneratorFunctionBody(const JSTokenLocation& location, const ParserFunctionInfo<ASTBuilder>& functionInfo, const Identifier& name)
    {
        FuncExprNode* result = static_cast<FuncExprNode*>(createFunctionExpr(location, functionInfo));
        if (!name.isNull())
            result->metadata()->setEcmaName(name);
        return result;
    }

    ExpressionNode* createAsyncFunctionBody(const JSTokenLocation&, const ParserFunctionInfo<ASTBuilder>&, SourceParseMode, const Identifier& name);

    ExpressionNode* createMethodDefinition(const JSTokenLocation&, const ParserFunctionInfo<ASTBuilder>&);
    
    FunctionMetadataNode* createFunctionMetadata(
        const JSTokenLocation& startLocation, const JSTokenLocation& endLocation, 
        unsigned functionStart, int functionNameStart,
        int parametersStart, ImplementationVisibility implementationVisibility, LexicallyScopedFeatures lexicallyScopedFeatures,
        ConstructorKind constructorKind, SuperBinding superBinding,
        unsigned parameterCount,
        SourceParseMode mode, bool isArrowFunctionBodyExpression)
    {
        return new (m_parserArena) FunctionMetadataNode(
            m_parserArena, startLocation, endLocation, functionStart,
            functionNameStart, parametersStart, implementationVisibility,
            lexicallyScopedFeatures, constructorKind, superBinding,
            parameterCount, mode, isArrowFunctionBodyExpression);
    }

    ExpressionNode* createArrowFunctionExpr(const JSTokenLocation&, const ParserFunctionInfo<ASTBuilder>&);

    ArgumentsNode* createArguments() { return new (m_parserArena) ArgumentsNode(); }
    ArgumentsNode* createArguments(ArgumentListNode* args, bool hasAssignments) { return new (m_parserArena) ArgumentsNode(args, hasAssignments); }
    ArgumentListNode* createArgumentsList(const JSTokenLocation& location, ExpressionNode* arg) { return new (m_parserArena) ArgumentListNode(location, arg); }
    ArgumentListNode* createArgumentsList(const JSTokenLocation& location, ArgumentListNode* args, ExpressionNode* arg) { return new (m_parserArena) ArgumentListNode(location, args, arg); }

    NEVER_INLINE PropertyNode* createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type,
        const Identifier* name, const ParserFunctionInfo<ASTBuilder>&, ClassElementTag);

    NEVER_INLINE PropertyNode* createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type,
        ExpressionNode* name, const ParserFunctionInfo<ASTBuilder>&, ClassElementTag);

    NEVER_INLINE PropertyNode* createGetterOrSetterProperty(VM& vm, ParserArena& parserArena, const JSTokenLocation& location, PropertyNode::Type type,
        double name, const ParserFunctionInfo<ASTBuilder>&, ClassElementTag);

    PropertyNode* createProperty(const Identifier* propertyName, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag)
    {
        return new (m_parserArena) PropertyNode(*propertyName, type, superBinding, tag);
    }
    PropertyNode* createProperty(const Identifier* propertyName, ExpressionNode* node, PropertyNode::Type type, SuperBinding superBinding, InferName inferName, ClassElementTag tag)
    {
        if (inferName == InferName::Allowed) {
            if (node->isBaseFuncExprNode()) {
                auto metadata = static_cast<BaseFuncExprNode*>(node)->metadata();
                metadata->setEcmaName(*propertyName);
            } else if (node->isClassExprNode())
                static_cast<ClassExprNode*>(node)->setEcmaName(*propertyName);
        }
        return new (m_parserArena) PropertyNode(*propertyName, node, type, superBinding, tag);
    }
    PropertyNode* createProperty(ExpressionNode* node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag)
    {
        return new (m_parserArena) PropertyNode(node, type, superBinding, tag);
    }
    PropertyNode* createProperty(VM& vm, ParserArena& parserArena, double propertyName, ExpressionNode* node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag)
    {
        return new (m_parserArena) PropertyNode(parserArena.identifierArena().makeNumericIdentifier(vm, propertyName), node, type, superBinding, tag);
    }
    PropertyNode* createProperty(ExpressionNode* propertyName, ExpressionNode* node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { return new (m_parserArena) PropertyNode(propertyName, node, type, superBinding, tag); }
    PropertyNode* createProperty(const Identifier* identifier, ExpressionNode* propertyName, ExpressionNode* node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { return new (m_parserArena) PropertyNode(*identifier, propertyName, node, type, superBinding, tag); }
    PropertyListNode* createPropertyList(const JSTokenLocation& location, PropertyNode* property) { return new (m_parserArena) PropertyListNode(location, property); }
    PropertyListNode* createPropertyList(const JSTokenLocation& location, PropertyNode* property, PropertyListNode* tail) { return new (m_parserArena) PropertyListNode(location, property, tail); }

    ElementNode* createElementList(int elisions, ExpressionNode* expr) { return new (m_parserArena) ElementNode(elisions, expr); }
    ElementNode* createElementList(ElementNode* elems, int elisions, ExpressionNode* expr) { return new (m_parserArena) ElementNode(elems, elisions, expr); }
    ElementNode* createElementList(ArgumentListNode* elems)
    {
        ElementNode* head = new (m_parserArena) ElementNode(0, elems->m_expr);
        ElementNode* tail = head;
        elems = elems->m_next;
        while (elems) {
            tail = new (m_parserArena) ElementNode(tail, 0, elems->m_expr);
            elems = elems->m_next;
        }
        return head;
    }

    FormalParameterList createFormalParameterList() { return new (m_parserArena) FunctionParameters(); }
    void appendParameter(FormalParameterList list, DestructuringPattern pattern, ExpressionNode* defaultValue) 
    { 
        list->append(pattern, defaultValue); 
        tryInferNameInPattern(pattern, defaultValue);
    }

    CaseClauseNode* createClause(ExpressionNode* expr, JSC::SourceElements* statements) { return new (m_parserArena) CaseClauseNode(expr, statements); }
    ClauseListNode* createClauseList(CaseClauseNode* clause) { return new (m_parserArena) ClauseListNode(clause); }
    ClauseListNode* createClauseList(ClauseListNode* tail, CaseClauseNode* clause) { return new (m_parserArena) ClauseListNode(tail, clause); }

    StatementNode* createFuncDeclStatement(const JSTokenLocation& location, const ParserFunctionInfo<ASTBuilder>& functionInfo)
    {
        FuncDeclNode* decl = new (m_parserArena) FuncDeclNode(location, *functionInfo.name, functionInfo.body,
            m_sourceCode->subExpression(functionInfo.startOffset, functionInfo.endOffset));
        if (*functionInfo.name == m_vm.propertyNames->arguments)
            usesArguments();
        functionInfo.body->setStartOffset(location.startOffset);
        return decl;
    }

    StatementNode* createClassDeclStatement(const JSTokenLocation& location, ClassExprNode* classExpression,
        const JSTextPosition& classStart, const JSTextPosition& classEnd)
    {
        ExpressionNode* assign = createAssignResolve(location, classExpression->name(), classExpression, classStart, classStart + 1, classEnd, AssignmentContext::DeclarationStatement);
        ClassDeclNode* decl = new (m_parserArena) ClassDeclNode(location, assign);
        decl->setStartOffset(location.startOffset);
        return decl;
    }

    StatementNode* createBlockStatement(const JSTokenLocation& location, JSC::SourceElements* elements, VariableEnvironment&& lexicalVariables, DeclarationStacks::FunctionStack&& functionStack)
    {
        BlockNode* block = new (m_parserArena) BlockNode(location, elements, WTF::move(lexicalVariables), WTF::move(functionStack));
        block->setStartOffset(location.startOffset);
        return block;
    }

    StatementNode* createExprStatement(const JSTokenLocation& location, ExpressionNode* expr, const JSTextPosition& start)
    {
        ExprStatementNode* result = new (m_parserArena) ExprStatementNode(location, expr);
        result->setStartOffset(start);
        return result;
    }

    StatementNode* createIfStatement(const JSTokenLocation& location, ExpressionNode* condition, StatementNode* trueBlock, StatementNode* falseBlock)
    {
        IfElseNode* result = new (m_parserArena) IfElseNode(location, condition, trueBlock, falseBlock);
        result->setStartOffset(location.startOffset);
        return result;
    }

    StatementNode* createForLoop(const JSTokenLocation& location, ExpressionNode* initializer, ExpressionNode* condition, ExpressionNode* iter, StatementNode* statements, VariableEnvironment&& lexicalVariables, bool initializerContainsClosure)
    {
        ForNode* result = new (m_parserArena) ForNode(location, initializer, condition, iter, statements, WTF::move(lexicalVariables), initializerContainsClosure);
        result->setStartOffset(location.startOffset);
        return result;
    }

    StatementNode* createForInLoop(const JSTokenLocation& location, ExpressionNode* lhs, ExpressionNode* iter, StatementNode* statements, const JSTokenLocation&, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, VariableEnvironment&& lexicalVariables)
    {
        ForInNode* result = new (m_parserArena) ForInNode(location, lhs, iter, statements, WTF::move(lexicalVariables));
        result->setStartOffset(location.startOffset);
        setExceptionLocation(result, eStart, eDivot, eEnd);
        return result;
    }
    
    StatementNode* createForInLoop(const JSTokenLocation& location, DestructuringPatternNode* pattern, ExpressionNode* iter, StatementNode* statements, const JSTokenLocation& declLocation, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, VariableEnvironment&& lexicalVariables)
    {
        auto lexpr = new (m_parserArena) DestructuringAssignmentNode(declLocation, pattern, nullptr);
        return createForInLoop(location, lexpr, iter, statements, declLocation, eStart, eDivot, eEnd, WTF::move(lexicalVariables));
    }
    
    StatementNode* createForOfLoop(bool isForAwait, const JSTokenLocation& location, ExpressionNode* lhs, ExpressionNode* iter, StatementNode* statements, const JSTokenLocation&, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, VariableEnvironment&& lexicalVariables)
    {
        ForOfNode* result = new (m_parserArena) ForOfNode(isForAwait, location, lhs, iter, statements, WTF::move(lexicalVariables));
        result->setStartOffset(location.startOffset);
        setExceptionLocation(result, eStart, eDivot, eEnd);
        if (isForAwait)
            usesAwait();
        return result;
    }
    
    StatementNode* createForOfLoop(bool isForAwait, const JSTokenLocation& location, DestructuringPatternNode* pattern, ExpressionNode* iter, StatementNode* statements, const JSTokenLocation& declLocation, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, VariableEnvironment&& lexicalVariables)
    {
        auto lexpr = new (m_parserArena) DestructuringAssignmentNode(declLocation, pattern, nullptr);
        return createForOfLoop(isForAwait, location, lexpr, iter, statements, declLocation, eStart, eDivot, eEnd, WTF::move(lexicalVariables));
    }

    bool isBindingNode(const DestructuringPattern& pattern)
    {
        return pattern->isBindingNode();
    }

    bool isLocation(const Expression& node)
    {
        return node->isLocation();
    }

    bool isAssignmentLocation(const Expression& node)
    {
        return node->isAssignmentLocation();
    }

    bool isPrivateLocation(const Expression& node)
    {
        return node->isPrivateLocation();
    }

    bool isObjectLiteral(const Expression& node)
    {
        return node->isObjectLiteral();
    }

    bool isArrayLiteral(const Expression& node)
    {
        return node->isArrayLiteral();
    }

    bool isObjectOrArrayLiteral(const Expression& node)
    {
        return isObjectLiteral(node) || isArrayLiteral(node);
    }

    bool isFunctionCall(const Expression& node)
    {
        return node->isFunctionCall();
    }

    bool shouldSkipPauseLocation(StatementNode* statement) const
    {
        return !statement || statement->isLabel();
    }

    StatementNode* createEmptyStatement(const JSTokenLocation& location) { return new (m_parserArena) EmptyStatementNode(location); }

    StatementNode* createDeclarationStatement(const JSTokenLocation& location, ExpressionNode* expr)
    {
        StatementNode* result;
        result = new (m_parserArena) DeclarationStatement(location, expr);
        result->setStartOffset(location.startOffset);
        return result;
    }

    ExpressionNode* createEmptyVarExpression(const JSTokenLocation& location, const Identifier& identifier)
    {
        return new (m_parserArena) EmptyVarExpression(location, identifier);
    }

    ExpressionNode* createEmptyLetExpression(const JSTokenLocation& location, const Identifier& identifier)
    {
        return new (m_parserArena) EmptyLetExpression(location, identifier);
    }

    StatementNode* createReturnStatement(const JSTokenLocation& location, ExpressionNode* expression, const JSTextPosition& start, const JSTextPosition& end)
    {
        ReturnNode* result = new (m_parserArena) ReturnNode(location, expression);
        setExceptionLocation(result, start, end, end);
        result->setStartOffset(start);
        return result;
    }

    StatementNode* createBreakStatement(const JSTokenLocation& location, const Identifier* ident, const JSTextPosition& start, const JSTextPosition& end)
    {
        BreakNode* result = new (m_parserArena) BreakNode(location, *ident);
        setExceptionLocation(result, start, end, end);
        result->setStartOffset(start);
        return result;
    }

    StatementNode* createContinueStatement(const JSTokenLocation& location, const Identifier* ident, const JSTextPosition& start, const JSTextPosition& end)
    {
        ContinueNode* result = new (m_parserArena) ContinueNode(location, *ident);
        setExceptionLocation(result, start, end, end);
        result->setStartOffset(start);
        return result;
    }

    StatementNode* createTryStatement(const JSTokenLocation& location, StatementNode* tryBlock, DestructuringPatternNode* catchPattern, StatementNode* catchBlock, StatementNode* finallyBlock, VariableEnvironment&& catchEnvironment)
    {
        TryNode* result = new (m_parserArena) TryNode(location, tryBlock, catchPattern, catchBlock, WTF::move(catchEnvironment), finallyBlock);
        result->setStartOffset(location.startOffset);
        return result;
    }

    StatementNode* createSwitchStatement(const JSTokenLocation& location, ExpressionNode* expr, ClauseListNode* firstClauses, CaseClauseNode* defaultClause, ClauseListNode* secondClauses, VariableEnvironment&& lexicalVariables, DeclarationStacks::FunctionStack&& functionStack)
    {
        CaseBlockNode* cases = new (m_parserArena) CaseBlockNode(firstClauses, defaultClause, secondClauses);
        SwitchNode* result = new (m_parserArena) SwitchNode(location, expr, cases, WTF::move(lexicalVariables), WTF::move(functionStack));
        result->setStartOffset(location.startOffset);
        return result;
    }

    StatementNode* createWhileStatement(const JSTokenLocation& location, ExpressionNode* expr, StatementNode* statement)
    {
        WhileNode* result = new (m_parserArena) WhileNode(location, expr, statement);
        result->setStartOffset(location.startOffset);
        return result;
    }

    StatementNode* createDoWhileStatement(const JSTokenLocation& location, StatementNode* statement, ExpressionNode* expr)
    {
        DoWhileNode* result = new (m_parserArena) DoWhileNode(location, statement, expr);
        result->setStartOffset(location.startOffset);
        return result;
    }

    StatementNode* createLabelStatement(const JSTokenLocation& location, const Identifier* ident, StatementNode* statement, const JSTextPosition& start, const JSTextPosition& end)
    {
        LabelNode* result = new (m_parserArena) LabelNode(location, *ident, statement);
        setExceptionLocation(result, start, end, end);
        return result;
    }

    StatementNode* createWithStatement(const JSTokenLocation& location, ExpressionNode* expr, StatementNode* statement, unsigned start, const JSTextPosition& end)
    {
        usesWith();
        WithNode* result = new (m_parserArena) WithNode(location, expr, statement, end, end - start);
        result->setStartOffset(location.startOffset);
        return result;
    }    
    
    StatementNode* createThrowStatement(const JSTokenLocation& location, ExpressionNode* expr, const JSTextPosition& start, const JSTextPosition& end)
    {
        ThrowNode* result = new (m_parserArena) ThrowNode(location, expr);
        result->setStartOffset(start);
        setExceptionLocation(result, start, end, end);
        return result;
    }
    
    StatementNode* createDebugger(const JSTokenLocation& location)
    {
        DebuggerStatementNode* result = new (m_parserArena) DebuggerStatementNode(location);
        result->setStartOffset(location.startOffset);
        return result;
    }

    ModuleNameNode* createModuleName(const JSTokenLocation& location, const Identifier& moduleName)
    {
        return new (m_parserArena) ModuleNameNode(location, moduleName);
    }

    ImportSpecifierNode* createImportSpecifier(const JSTokenLocation& location, const Identifier& importedName, const Identifier& localName)
    {
        return new (m_parserArena) ImportSpecifierNode(location, importedName, localName);
    }

    ImportSpecifierListNode* createImportSpecifierList()
    {
        return new (m_parserArena) ImportSpecifierListNode();
    }

    void appendImportSpecifier(ImportSpecifierListNode* specifierList, ImportSpecifierNode* specifier)
    {
        specifierList->append(specifier);
    }

    ImportAttributesListNode* createImportAttributesList()
    {
        return new (m_parserArena) ImportAttributesListNode();
    }

    void appendImportAttribute(ImportAttributesListNode* attributesList, const Identifier& key, const Identifier& value)
    {
        attributesList->append(key, value);
    }

    StatementNode* createImportDeclaration(const JSTokenLocation& location, ImportDeclarationNode::ImportType type, ImportSpecifierListNode* importSpecifierList, ModuleNameNode* moduleName, ImportAttributesListNode* importAttributesList)
    {
        return new (m_parserArena) ImportDeclarationNode(location, type, importSpecifierList, moduleName, importAttributesList);
    }

    StatementNode* createExportAllDeclaration(const JSTokenLocation& location, ModuleNameNode* moduleName, ImportAttributesListNode* importAttributesList)
    {
        return new (m_parserArena) ExportAllDeclarationNode(location, moduleName, importAttributesList);
    }

    StatementNode* createExportDefaultDeclaration(const JSTokenLocation& location, StatementNode* declaration, const Identifier& localName)
    {
        return new (m_parserArena) ExportDefaultDeclarationNode(location, declaration, localName);
    }

    StatementNode* createExportLocalDeclaration(const JSTokenLocation& location, StatementNode* declaration)
    {
        return new (m_parserArena) ExportLocalDeclarationNode(location, declaration);
    }

    StatementNode* createExportNamedDeclaration(const JSTokenLocation& location, ExportSpecifierListNode* exportSpecifierList, ModuleNameNode* moduleName, ImportAttributesListNode* importAttributesList)
    {
        return new (m_parserArena) ExportNamedDeclarationNode(location, exportSpecifierList, moduleName, importAttributesList);
    }

    ExportSpecifierNode* createExportSpecifier(const JSTokenLocation& location, const Identifier& localName, const Identifier& exportedName)
    {
        return new (m_parserArena) ExportSpecifierNode(location, localName, exportedName);
    }

    ExportSpecifierListNode* createExportSpecifierList()
    {
        return new (m_parserArena) ExportSpecifierListNode();
    }

    void appendExportSpecifier(ExportSpecifierListNode* specifierList, ExportSpecifierNode* specifier)
    {
        specifierList->append(specifier);
    }

    void appendStatement(JSC::SourceElements* elements, JSC::StatementNode* statement)
    {
        elements->append(statement);
    }

    CommaNode* createCommaExpr(const JSTokenLocation& location, ExpressionNode* node)
    {
        return new (m_parserArena) CommaNode(location, node);
    }

    CommaNode* appendToCommaExpr(const JSTokenLocation& location, ExpressionNode* tail, ExpressionNode* next)
    {
        ASSERT(tail->isCommaNode());
        ASSERT(next);
        CommaNode* newTail = new (m_parserArena) CommaNode(location, next);
        static_cast<CommaNode*>(tail)->setNext(newTail);
        return newTail;
    }

    int evalCount() const { return m_evalCount; }

    void appendBinaryExpressionInfo(int& operandStackDepth, ExpressionNode* current, const JSTextPosition& exprStart, const JSTextPosition& lhs, const JSTextPosition& rhs, bool hasAssignments)
    {
        operandStackDepth++;
        m_binaryOperandStack.append(std::make_pair(current, BinaryOpInfo(exprStart, lhs, rhs, hasAssignments)));
    }

    // Logic to handle datastructures used during parsing of binary expressions
    void operatorStackPop(int& operatorStackDepth)
    {
        operatorStackDepth--;
        m_binaryOperatorStack.removeLast();
    }
    bool operatorStackShouldReduce(int precedence)
    {
        // If the current precedence of the operator stack is the same to the one of the given operator,
        // it depends on the associative whether we reduce the stack.
        // If the operator is right associative, we should not reduce the stack right now.
        if (precedence == m_binaryOperatorStack.last().second)
            return !(m_binaryOperatorStack.last().first & RightAssociativeBinaryOpTokenFlag);
        return precedence < m_binaryOperatorStack.last().second;
    }
    const BinaryOperand& getFromOperandStack(int i) { return m_binaryOperandStack[m_binaryOperandStack.size() + i]; }
    void shrinkOperandStackBy(int& operandStackDepth, int amount)
    {
        operandStackDepth -= amount;
        ASSERT(operandStackDepth >= 0);
        RELEASE_ASSERT(amount >= 0 && static_cast<size_t>(amount) <= m_binaryOperandStack.size());
        m_binaryOperandStack.shrink(m_binaryOperandStack.size() - amount);
    }
    void appendBinaryOperation(const JSTokenLocation& location, int& operandStackDepth, int&, const BinaryOperand& lhs, const BinaryOperand& rhs)
    {
        operandStackDepth++;
        m_binaryOperandStack.append(std::make_pair(makeBinaryNode(location, m_binaryOperatorStack.last().first, lhs, rhs), BinaryOpInfo(lhs.second, rhs.second)));
    }
    void operatorStackAppend(int& operatorStackDepth, int op, int precedence)
    {
        operatorStackDepth++;
        m_binaryOperatorStack.append(std::make_pair(op, precedence));
    }
    ExpressionNode* popOperandStack(int&)
    {
        ExpressionNode* result = m_binaryOperandStack.last().first;
        m_binaryOperandStack.removeLast();
        return result;
    }
    
    void appendUnaryToken(int& tokenStackDepth, int type, const JSTextPosition& start)
    {
        tokenStackDepth++;
        m_unaryTokenStack.append(std::make_pair(type, start));
    }

    int unaryTokenStackLastType(int&)
    {
        return m_unaryTokenStack.last().first;
    }
    
    const JSTextPosition& unaryTokenStackLastStart(int&)
    {
        return m_unaryTokenStack.last().second;
    }
    
    void unaryTokenStackRemoveLast(int& tokenStackDepth)
    {
        tokenStackDepth--;
        m_unaryTokenStack.removeLast();
    }

    int unaryTokenStackDepth() const
    {
        return m_unaryTokenStack.size();
    }

    void setUnaryTokenStackDepth(int oldDepth)
    {
        m_unaryTokenStack.shrink(oldDepth);
    }
    
    void assignmentStackAppend(int& assignmentStackDepth, ExpressionNode* node, const JSTextPosition& start, const JSTextPosition& divot, int assignmentCount, Operator op)
    {
        assignmentStackDepth++;
        m_assignmentInfoStack.append(AssignmentInfo(node, start, divot, assignmentCount, op));
    }

    ExpressionNode* createAssignment(const JSTokenLocation& location, int& assignmentStackDepth, ExpressionNode* rhs, int initialAssignmentCount, int currentAssignmentCount, const JSTextPosition& lastTokenEnd)
    {
        AssignmentInfo& info = m_assignmentInfoStack.last();
        checkArgumentsLengthModification(info.m_node);
        ExpressionNode* result = makeAssignNode(location, info.m_node, info.m_op, rhs, info.m_initAssignments != initialAssignmentCount, info.m_initAssignments != currentAssignmentCount, info.m_start, info.m_divot + 1, lastTokenEnd);
        m_assignmentInfoStack.removeLast();
        assignmentStackDepth--;
        return result;
    }

    PropertyNode::Type getType(const Property& property) const { return property->type(); }
    bool isUnderscoreProtoSetter(const Property& property) const { return PropertyNode::isUnderscoreProtoSetter(m_vm, *property); }
    bool isResolve(ExpressionNode* expr) const { return expr->isResolveNode(); }

    ExpressionNode* createDestructuringAssignment(const JSTokenLocation& location, DestructuringPattern pattern, ExpressionNode* initializer)
    {
        return new (m_parserArena) DestructuringAssignmentNode(location, pattern, initializer);
    }
    
    ArrayPattern createArrayPattern(const JSTokenLocation&)
    {
        return new (m_parserArena) ArrayPatternNode();
    }
    
    void appendArrayPatternSkipEntry(ArrayPattern node, const JSTokenLocation& location)
    {
        node->appendIndex(ArrayPatternNode::BindingType::Elision, location, nullptr, nullptr);
    }

    void appendArrayPatternEntry(ArrayPattern node, const JSTokenLocation& location, DestructuringPattern pattern, ExpressionNode* defaultValue)
    {
        node->appendIndex(ArrayPatternNode::BindingType::Element, location, pattern, defaultValue);
        tryInferNameInPattern(pattern, defaultValue);
    }

    void appendArrayPatternRestEntry(ArrayPattern node, const JSTokenLocation& location, DestructuringPattern pattern)
    {
        node->appendIndex(ArrayPatternNode::BindingType::RestElement, location, pattern, nullptr);
    }

    void finishArrayPattern(ArrayPattern node, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd)
    {
        setExceptionLocation(node, divotStart, divot, divotEnd);
    }
    
    ObjectPattern createObjectPattern(const JSTokenLocation&)
    {
        return new (m_parserArena) ObjectPatternNode();
    }

    void appendObjectPatternEntry(ObjectPattern node, const JSTokenLocation& location, bool wasString, const Identifier& identifier, DestructuringPattern pattern, ExpressionNode* defaultValue)
    {
        node->appendEntry(location, identifier, wasString, pattern, defaultValue, ObjectPatternNode::BindingType::Element);
        tryInferNameInPattern(pattern, defaultValue);
    }

    void appendObjectPatternEntry(VM& vm, ObjectPattern node, const JSTokenLocation& location, ExpressionNode* propertyExpression, DestructuringPattern pattern, ExpressionNode* defaultValue)
    {
        node->appendEntry(vm, location, propertyExpression, pattern, defaultValue, ObjectPatternNode::BindingType::Element);
        tryInferNameInPattern(pattern, defaultValue);
    }
    
    void appendObjectPatternRestEntry(VM& vm, ObjectPattern node, const JSTokenLocation& location, DestructuringPattern pattern)
    {
        node->appendEntry(vm, location, nullptr, pattern, nullptr, ObjectPatternNode::BindingType::RestElement);
    }

    void setContainsObjectRestElement(ObjectPattern node, bool containsRestElement)
    {
        node->setContainsRestElement(containsRestElement);
    }
    
    void setContainsComputedProperty(ObjectPattern node, bool containsComputedProperty)
    {
        node->setContainsComputedProperty(containsComputedProperty);
    }

    void finishObjectPattern(ObjectPattern node, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd)
    {
        setExceptionLocation(node, divotStart, divot, divotEnd);
    }

    BindingPattern createBindingLocation(const JSTokenLocation&, const Identifier& boundProperty, const JSTextPosition& start, const JSTextPosition& end, AssignmentContext context)
    {
        if (context == AssignmentContext::AwaitUsingDeclarationStatement)
            usesAwait();
        return new (m_parserArena) BindingNode(boundProperty, start, end, context);
    }

    RestParameterNode* createRestParameter(DestructuringPatternNode* pattern, size_t numParametersToSkip)
    {
        return new (m_parserArena) RestParameterNode(pattern, numParametersToSkip);
    }

    AssignmentElement createAssignmentElement(const Expression& assignmentTarget, const JSTextPosition& start, const JSTextPosition& end)
    {
        checkArgumentsLengthModification(assignmentTarget);
        return new (m_parserArena) AssignmentElementNode(assignmentTarget, start, end);
    }

    void setEndOffset(Node* node, int offset)
    {
        node->setEndOffset(offset);
    }

    int endOffset(Node* node)
    {
        return node->endOffset();
    }

    void setStartOffset(CaseClauseNode* node, int offset)
    {
        node->setStartOffset(offset);
    }

    void setStartOffset(Node* node, int offset)
    {
        node->setStartOffset(offset);
    }

    JSTextPosition breakpointLocation(Node* node)
    {
        node->setNeedsDebugHook();
        return node->position();
    }

    void propagateArgumentsUse() { usesArguments(); }

    bool hasArgumentsFeature() const { return m_scope.m_features & ArgumentsFeature; }

private:
    struct Scope {
        Scope() = default;

        int m_features { 0 };
    };

    void checkArgumentsLengthModification(const ExpressionNode* node)
    {
        // Since we exclude pattern `arguments.length` to enable ArgumentsFeature,
        // we need re-enable ArgumentsFeature for `arguments.length` modification.
        if (node && node->isArgumentsLengthAccess(m_vm))
            usesArguments();
    }

    static void setExceptionLocation(ThrowableExpressionData* node, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd)
    {
        ASSERT(divot && divotStart && divotEnd);
        node->setExceptionSourceCode(divot, divotStart, divotEnd);
    }

    void usesThis() { m_scope.m_features |= ThisFeature; }
    void usesArrowFunction() { m_scope.m_features |= ArrowFunctionFeature; }
    void usesArguments() { m_scope.m_features |= ArgumentsFeature; }
    void usesWith() { m_scope.m_features |= WithFeature; }
    void usesSuperCall() { m_scope.m_features |= SuperCallFeature; }
    void usesSuperProperty() { m_scope.m_features |= SuperPropertyFeature; }
    void usesEval() 
    {
        m_evalCount++;
        m_scope.m_features |= EvalFeature;
    }
    void usesNewTarget() { m_scope.m_features |= NewTargetFeature; }
    void usesAwait() { m_scope.m_features |= AwaitFeature; }
    ExpressionNode* createIntegerLikeNumber(const JSTokenLocation&, double);
    ExpressionNode* createDoubleLikeNumber(const JSTokenLocation&, double);
    ExpressionNode* createBigIntWithSign(const JSTokenLocation& location, const Identifier& bigInt, uint8_t radix, bool sign)
    {
        return new (m_parserArena) BigIntNode(location, bigInt, radix, sign);
    }
    ExpressionNode* createNumberFromBinaryOperation(const JSTokenLocation& location, double value, const NumberNode& originalNodeA, const NumberNode& originalNodeB)
    {
        if (originalNodeA.isIntegerNode() && originalNodeB.isIntegerNode())
            return createIntegerLikeNumber(location, value);
        return createDoubleLikeNumber(location, value);
    }
    ExpressionNode* createNumberFromUnaryOperation(const JSTokenLocation& location, double value, const NumberNode& originalNode)
    {
        if (originalNode.isIntegerNode())
            return createIntegerLikeNumber(location, value);
        return createDoubleLikeNumber(location, value);
    }
    ExpressionNode* createBigIntFromUnaryOperation(const JSTokenLocation& location, bool sign, const BigIntNode& originalNode)
    {
        return createBigIntWithSign(location, originalNode.identifier(), originalNode.radix(), sign);
    }

    void tryInferNameInPattern(DestructuringPattern pattern, ExpressionNode* defaultValue)
    {
        if (!defaultValue)
            return;

        if (pattern->isBindingNode()) {
            const Identifier& ident = static_cast<BindingNode*>(pattern)->boundProperty();
            tryInferNameInPatternWithIdentifier(ident, defaultValue);
        } else if (pattern->isAssignmentElementNode()) {
            const ExpressionNode* assignmentTarget = static_cast<AssignmentElementNode*>(pattern)->assignmentTarget();
            if (assignmentTarget->isResolveNode() && !assignmentTarget->isParenthesized()) {
                const Identifier& ident = static_cast<const ResolveNode*>(assignmentTarget)->identifier();
                tryInferNameInPatternWithIdentifier(ident, defaultValue);
            }
        }
    }

    void tryInferNameInPatternWithIdentifier(const Identifier& ident, ExpressionNode* defaultValue)
    {
        if (defaultValue->isBaseFuncExprNode()) {
            auto metadata = static_cast<BaseFuncExprNode*>(defaultValue)->metadata();
            metadata->setEcmaName(ident);
        } else if (defaultValue->isClassExprNode())
            static_cast<ClassExprNode*>(defaultValue)->setEcmaName(ident);
    }

    VM& m_vm;
    ParserArena& m_parserArena;
    const SourceCode* m_sourceCode;
    Scope m_scope;
    Vector<BinaryOperand, 10> m_binaryOperandStack;
    Vector<AssignmentInfo, 10> m_assignmentInfoStack;
    Vector<std::pair<int, int>, 10> m_binaryOperatorStack;
    Vector<std::pair<int, JSTextPosition>, 10> m_unaryTokenStack;
    int m_evalCount;
};

}
