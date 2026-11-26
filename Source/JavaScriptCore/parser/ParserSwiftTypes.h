/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

// The values the C++ entry points (Parser.h) and the Swift parser (parser/ParserEntry.swift) exchange: handles, the
// modes of a parse, its result, and the small structs that cross with the ASTBuilder facade (ParserSwiftFacadeInlines.h).
// Everything here is trivially copyable. A handle is an index into a per-parse table of ParserSwiftFacadeInlines.h's
// JSParseState; 0 is null, and every facade member checks a handle before it loads through it.

#pragma once

#include "ConstructorKind.h"
#include "ExecutableInfo.h"
#include "ImplementationVisibility.h"
#include "ParserModes.h"
#include "ParserTokens.h"
#include <cstdint>
#include <optional>
#include <span>

namespace JSC {

// ParserSwiftFacadeInlines.h's facade, which jscParse8/jscParse16 receive inout. Declared here so that a file including
// JSCSwift-Swift.h, which names it, needs only this header and not the ASTBuilder.
class JSParseState;
template<typename State> class JSParseFacadeBase;
using JSParseFacade = JSParseFacadeBase<JSParseState>;

// The characters of the whole provider; uint8_t is Latin1Character.
using JSParseInput8 = std::span<const uint8_t>;
using JSParseInput16 = std::span<const char16_t>;

// A node the ASTBuilder made, an identifier of the arena or the VM, a scope's C++ containers, and containers taken
// out of a scope for a node. Each kind is its own struct so that one cannot be passed for another. A scope handle is
// its depth on the stack of live scopes: the Swift parser's Scope holds it, and it is removed from the Swift stack when
// the scope is popped (a read through a ScopeRef checks its generation; a read by index into the live scope stack is
// bounds-checked).
struct JSParseNode {
    uint32_t index { 0 };
};
struct JSParseIdentifier {
    uint32_t index { 0 };
};
struct JSParseScope {
    uint32_t index { 0 };
};
struct JSParseEnvironment {
    uint32_t index { 0 };
};
struct JSParseFunctionStack {
    uint32_t index { 0 };
};

// What JSParseState::popScope returns: the containers a node takes (null handles unless the pop was asked for them) and, for
// an arrow function's scope, whether its used variables held `arguments`.
struct JSParsePoppedScope {
    JSParseEnvironment lexicalVariables;
    JSParseFunctionStack functionDeclarations;
    bool usesArguments { false };
};

// What the parse makes: the ParsedNode type of the entry.
enum class JSParseRootKind : uint8_t { Program, ModuleProgram, Eval, Function };

// Everything a parse reads that is not in the facade, fixed for the parse.
struct JSParseModes {
    uint32_t startOffset { 0 }; // SourceCode::startOffset(): where the lexer starts, in the provider's characters.
    uint32_t endOffset { 0 };
    std::optional<int32_t> functionConstructorParametersEndPosition; // The Function constructor's parse (isFunctionConstructor) only.
    JSParseIdentifier calleeName; // parse<FunctionNode>'s name: null for the other entries.
    JSParseRootKind rootKind { JSParseRootKind::Program };
    SourceParseMode parseMode { SourceParseMode::ProgramMode };
    JSParserScriptMode scriptMode { JSParserScriptMode::Classic };
    JSParserBuiltinMode builtinMode { JSParserBuiltinMode::NotBuiltin };
    LexicallyScopedFeatures lexicallyScopedFeatures { NoLexicallyScopedFeatures };
    FunctionMode functionMode { FunctionMode::None };
    SuperBinding superBinding { SuperBinding::NotNeeded };
    ConstructorKind constructorKind { ConstructorKind::None };
    ConstructorKind constructorKindForTopLevelFunctionExpressions { ConstructorKind::None };
    DerivedContextType derivedContextType { DerivedContextType::None };
    EvalContextType evalContextType { EvalContextType::None };
    ImplementationVisibility implementationVisibility { ImplementationVisibility::Public };
    bool isFunctionConstructor { false }; // parseFunctionForFunctionConstructor.
    bool isInsideOrdinaryFunction { false };
    bool hasParentScopePrivateNames { false };
    // Options.
    bool useSourceProviderCache { false }; // Read once, when the parse starts.
    bool exposePrivateIdentifiers { false };
    bool useExplicitResourceManagement { false };
    bool useImportDefer { false };
};

// A range of the provider's characters.
struct JSParseExtent {
    uint32_t start { 0 };
    uint32_t length { 0 };
};

// How a parse ended.
enum class JSParseOutcome : uint8_t { Succeeded, SyntaxError, StackOverflow };

// What the Swift returns. On failure parseWithSwift makes the ParserError from the token fields and the facade's message.
struct JSParseResult {
    JSParseOutcome outcome { JSParseOutcome::SyntaxError };
    JSParseNode sourceElements;
    JSParseNode parameters;
    JSParseScope rootScope; // Its declared and lexical variables, function declarations and hoisted functions.
    CodeFeatures features { NoFeatures };
    InnerArrowFunctionCodeFeatures innerArrowFunctionFeatures { NoInnerArrowFunctionFeatures };
    LexicallyScopedFeatures lexicallyScopedFeatures { NoLexicallyScopedFeatures };
    uint32_t usedPrivateNameCount { 0 };
    uint32_t endOffset { 0 }; // The lexer's currentOffset() when the parse stopped: the end, or the error's offset.
    JSTokenLocation startLocation; // The first token's location: the ParsedNode's start.
    JSTokenType tokenType { EOFTOK };
    JSTextPosition tokenStartPosition;
    JSTextPosition tokenEndPosition;
    std::optional<JSParseExtent> sourceURLDirective;
    std::optional<JSParseExtent> sourceMappingURLDirective;
};

// ParserFunctionInfo<ASTBuilder> and ParserClassInfo<ASTBuilder>, with handles for the pointers.
struct JSParseFunctionInfo {
    JSParseIdentifier name;
    JSParseNode body;
    uint32_t parameterCount { 0 };
    uint32_t functionLength { 0 };
    uint32_t startOffset { 0 };
    uint32_t endOffset { 0 };
};

struct JSParseClassInfo {
    JSParseIdentifier className;
    uint32_t startOffset { 0 };
    uint32_t endOffset { 0 };
};

// ASTBuilder::BinaryOperand: an expression and its BinaryOpInfo.
struct JSParseBinaryOperand {
    JSParseNode expression;
    JSTextPosition start;
    JSTextPosition divot;
    JSTextPosition end;
    bool hasAssignment { false };
};

// The scalar fields of a SourceProviderCacheItem the parser reads back on a hit, and the ones it records for a body
// it parsed (SourceProviderCacheItemCreationParameters) less the variables, which the facade takes from the scope.
struct JSParseCachedFunction {
    bool needsFullActivation { false };
    bool usesEval { false };
    bool usesImportMeta { false };
    bool needsSuperBinding { false };
    bool isBodyArrowExpression { false };
    unsigned lastTokenStartOffset { 0 };
    unsigned lastTokenEndOffset { 0 };
    unsigned endFunctionOffset { 0 };
    unsigned parameterCount { 0 };
    JSTokenType tokenType { CLOSEBRACE };
    InnerArrowFunctionCodeFeatures innerArrowFunctionFeatures { NoInnerArrowFunctionFeatures };
    LexicallyScopedFeatures lexicallyScopedFeatures { NoLexicallyScopedFeatures };
    ConstructorKind constructorKind { ConstructorKind::None };
    SuperBinding expectedSuperBinding { SuperBinding::NotNeeded };
    ImplementationVisibility implementationVisibility { ImplementationVisibility::Public };
};

} // namespace JSC
