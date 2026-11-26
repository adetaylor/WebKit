/*
 *  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
 *  Copyright (C) 2001 Peter Kelly (pmk@post.com)
 *  Copyright (C) 2003-2023 Apple Inc. All rights reserved.
 *  Copyright (C) 2003-2024 Apple Inc. All rights reserved.
 *  Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Library General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Library General Public License for more details.
 *
 *  You should have received a copy of the GNU Library General Public License
 *  along with this library; see the file COPYING.LIB.  If not, write to
 *  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 *  Boston, MA 02110-1301, USA.
 *
 */

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

// The facade the Swift parser (ParserEntry.swift) calls for everything that stays C++ during a parse: identifiers, the
// C++ containers of each scope, the SourceProviderCache, the module and debugger data, and ASTBuilder (one forwarder per
// member the parser calls). Swift receives it inout and holds only handles (ParserSwiftTypes.h): indices into
// JSParseState's tables, checked on every load, which die with the parse.
//
// The shape is LiteralParserSwiftTypes.h's JSONParseSink: no data members, not copyable, a move constructor that crashes
// (Swift relocates a noncopyable C++ object only through it), and a user-provided destructor so that Swift passes it by
// address. Its members reach the JSParseState through state(), a static_cast that holds because every JSParseFacade is
// a JSParseState. Every member is non-const, and none names VM or ParserArena, which Swift does not import. The members
// on a hot path are ALWAYS_INLINE so that the importer compiles them into the Swift; the forwarders without it (the
// scope-merging and cache members, for one) are ordinary calls into the JSParseState's own members.

#pragma once

#include "ASTBuilder.h"
#include "DebuggerParseData.h"
#include "IdentifierInlines.h" // IdentifierArena::makeLatin1Identifier calls Identifier::createLatin1.
#include "JSCJSValueInlines.h" // The forwarders compile NodeConstructors.h into the Swift; its NumberNode needs JSValue(double).
#include "LexerUnicodeProperties.h"
#include "ModuleScopeData.h"
#include "Options.h"
#include "ParserArena.h"
#include "ParserError.h"
#include "ParserSwiftTypes.h"
#include "SourceProviderCache.h"
#include "SourceProviderCacheItem.h"
#include "VM.h"
#include "VariableEnvironment.h"
#include <array>
#include <tuple>
#include <wtf/CompactPointerTuple.h>
#include <wtf/FastFloat.h>
#include <wtf/text/StringBuilder.h>

namespace JSC {

class JSParseState;

// The error message is printed into a StringPrintStream, which takes a token's characters or an identifier
// through UTF-8 with lenient conversion: an unpaired surrogate comes back as U+FFFD.
void appendParseErrorCharactersReplacingUnpairedSurrogates(StringBuilder&, std::span<const char16_t>);

// ICU's u_hasBinaryProperty, out of line: the Swift importer does not see wtf/Platform.h's U_DISABLE_RENAMING, so it
// would call the versioned name, which libicucore does not export.
bool isNonLatin1IdentifierStart(uint32_t);
bool isNonLatin1IdentifierPart(uint32_t);

// ParseInt.h's parseIntOverflow, which this header does not include: its static functions would be compiled into every
// importer.
double parseIntOverflow8(std::span<const uint8_t> characters NOESCAPE, int radix);

// The VM's names the lexer and the parser compare with or produce, at identifier handles 1 to count: Keywords.table's
// keywords (CommonIdentifiers.h's own list) and the other names the parser and the lexer read from vm.propertyNames.
#define JSC_PARSER_SWIFT_KEYWORD_NAME(name) name##Keyword,
#define JSC_PARSER_SWIFT_OTHER_NAMES(macro) \
    macro(arguments) macro(async) macro(eval) macro(nullIdentifier) macro(of) macro(usingIdentifier) macro(as) \
    macro(from) macro(set) macro(get) macro(target) macro(prototype) macro(length) macro(Function) macro(constructor) \
    macro(underscoreProto) macro(useStrictIdentifier) macro(starDefaultPrivateName) macro(starNamespacePrivateName) \
    macro(undefinedPrivateName) macro(metaPrivateName) macro(constructorPrivateField) macro(generatorPrivateName) \
    macro(generatorFramePrivateName) macro(generatorStatePrivateName) macro(generatorValuePrivateName) \
    macro(generatorResumeModePrivateName)
#define JSC_PARSER_SWIFT_OTHER_NAME(name) name,
enum class JSParseWellKnownName : uint8_t {
    JSC_COMMON_IDENTIFIERS_EACH_KEYWORD(JSC_PARSER_SWIFT_KEYWORD_NAME)
    JSC_PARSER_SWIFT_OTHER_NAMES(JSC_PARSER_SWIFT_OTHER_NAME)
    JSC_PARSER_SWIFT_OTHER_NAME(meta) // builtinNames().metaPublicName(), import.meta's: CommonIdentifiers has no meta.
    Count
};
#undef JSC_PARSER_SWIFT_OTHER_NAME
#undef JSC_PARSER_SWIFT_KEYWORD_NAME

// Which of a scope's containers a member changes.
enum class JSParseEnvironmentKind : uint8_t { Lexical, Declared };
enum class JSParseNameSetKind : uint8_t { DeclaredParameters, VariablesBeingHoisted, ClosedVariableCandidates };

// VariableEnvironmentEntry's traits, one bit each, as environmentAdd sets them and environmentTraits reports them.
enum class JSParseVariableTrait : uint16_t {
    Captured = 1 << 0, Const = 1 << 1, Var = 1 << 2, Let = 1 << 3, Exported = 1 << 4, Imported = 1 << 5,
    ImportedNamespace = 1 << 6, Function = 1 << 7, Parameter = 1 << 8, SloppyModeHoistedFunction = 1 << 9,
    PrivateField = 1 << 10, PrivateMethod = 1 << 11, PrivateGetter = 1 << 12, PrivateSetter = 1 << 13,
    FunctionDeclaration = 1 << 14, Using = 1 << 15,
};

// VariableEnvironment::PrivateDeclarationResult, as declarePrivateAccessor returns it.
enum class JSParsePrivateDeclarationResult : uint8_t { Success, DuplicatedName, InvalidStaticNonStatic };
static_assert(static_cast<uint8_t>(VariableEnvironment::PrivateDeclarationResult::Success) == static_cast<uint8_t>(JSParsePrivateDeclarationResult::Success));
static_assert(static_cast<uint8_t>(VariableEnvironment::PrivateDeclarationResult::DuplicatedName) == static_cast<uint8_t>(JSParsePrivateDeclarationResult::DuplicatedName));
static_assert(static_cast<uint8_t>(VariableEnvironment::PrivateDeclarationResult::InvalidStaticNonStatic) == static_cast<uint8_t>(JSParsePrivateDeclarationResult::InvalidStaticNonStatic));

// UnlinkedFunctionExecutable::ClassElementDefinition::Kind, as classElementDefinitionKind returns it.
enum class JSParseClassElementKind : uint8_t { FieldWithLiteralPropertyKey, FieldWithComputedPropertyKey, FieldWithPrivatePropertyKey, StaticInitializationBlock };
static_assert(static_cast<uint8_t>(UnlinkedFunctionExecutable::ClassElementDefinition::Kind::FieldWithLiteralPropertyKey) == static_cast<uint8_t>(JSParseClassElementKind::FieldWithLiteralPropertyKey));
static_assert(static_cast<uint8_t>(UnlinkedFunctionExecutable::ClassElementDefinition::Kind::FieldWithComputedPropertyKey) == static_cast<uint8_t>(JSParseClassElementKind::FieldWithComputedPropertyKey));
static_assert(static_cast<uint8_t>(UnlinkedFunctionExecutable::ClassElementDefinition::Kind::FieldWithPrivatePropertyKey) == static_cast<uint8_t>(JSParseClassElementKind::FieldWithPrivatePropertyKey));
static_assert(static_cast<uint8_t>(UnlinkedFunctionExecutable::ClassElementDefinition::Kind::StaticInitializationBlock) == static_cast<uint8_t>(JSParseClassElementKind::StaticInitializationBlock));

// The builtin private names Parser.parseClass declares.
enum class JSParseClassBuiltinName : uint8_t { StaticInitializerBlock, PrivateBrand, PrivateClassBrand };

// The node kinds a handle can hold; a node kind added to ASTBuilder is added here.
using JSParseNodeTypes = std::tuple<
    ExpressionNode,
    SourceElements,
    TemplateStringNode,
    TemplateStringListNode,
    TemplateExpressionListNode,
    TemplateLiteralNode,
    YieldExprNode,
    AwaitExprNode,
    DefineFieldNode,
    ClassExprNode,
    FunctionMetadataNode,
    ArgumentsNode,
    ArgumentListNode,
    PropertyNode,
    PropertyListNode,
    ElementNode,
    FunctionParameters,
    CaseClauseNode,
    ClauseListNode,
    StatementNode,
    ModuleNameNode,
    ImportSpecifierNode,
    ImportSpecifierListNode,
    ImportAttributesListNode,
    ExportSpecifierNode,
    ExportSpecifierListNode,
    CommaNode,
    ArrayPatternNode,
    ObjectPatternNode,
    BindingNode,
    RestParameterNode,
    AssignmentElementNode
>;

template<typename State>
class __attribute__((swift_attr("~Sendable"))) JSParseFacadeBase {
public:
    JSParseFacadeBase(const JSParseFacadeBase&) = delete;
    JSParseFacadeBase& operator=(const JSParseFacadeBase&) = delete;
    [[noreturn]] JSParseFacadeBase(JSParseFacadeBase&&) { RELEASE_ASSERT_NOT_REACHED(); }
    ~JSParseFacadeBase() { }

    // Identifiers (IdentifierArena), each returning a new handle. The spans are characters Swift lexed or decoded.
    ALWAYS_INLINE JSParseIdentifier makeIdentifier8(std::span<const uint8_t> characters NOESCAPE) { auto& s = state(); return s.addIdentifier(s.identifierArena().makeIdentifier(s.vm(), spanReinterpretCast<const Latin1Character>(characters))); }
    ALWAYS_INLINE JSParseIdentifier makeIdentifier16(std::span<const char16_t> characters NOESCAPE) { auto& s = state(); return s.addIdentifier(s.identifierArena().makeIdentifier(s.vm(), characters)); }
    ALWAYS_INLINE JSParseIdentifier makeLatin1Identifier(std::span<const char16_t> characters NOESCAPE) { auto& s = state(); return s.addIdentifier(s.identifierArena().makeLatin1Identifier(s.vm(), characters)); }
    ALWAYS_INLINE JSParseIdentifier makeEmptyIdentifier() { auto& s = state(); return s.addIdentifier(s.identifierArena().makeEmptyIdentifier(s.vm())); }
    ALWAYS_INLINE JSParseIdentifier makeNumericIdentifier(double number) { auto& s = state(); return s.addIdentifier(s.identifierArena().makeNumericIdentifier(s.vm(), number)); }
    // JSBigInt::parseInt checks its radix only with a debug ASSERT; the lexer produces only these four.
    ALWAYS_INLINE JSParseIdentifier makeBigIntDecimalIdentifier(JSParseIdentifier digits, uint8_t radix) { RELEASE_ASSERT(radix == 2 || radix == 8 || radix == 10 || radix == 16); auto& s = state(); return s.addIdentifierOrNull(s.identifierArena().makeBigIntDecimalIdentifier(s.vm(), s.identifier(digits), radix)); }
    static constexpr ASCIILiteral instanceComputedFieldPrefix = "instanceComputedName"_s;
    static constexpr ASCIILiteral staticComputedFieldPrefix = "staticComputedName"_s;
    ALWAYS_INLINE JSParseIdentifier makeComputedFieldPrivateIdentifier(ClassElementTag tag, unsigned id) { auto& s = state(); return s.addIdentifier(s.identifierArena().makePrivateIdentifier(s.vm(), tag == ClassElementTag::Instance ? instanceComputedFieldPrefix : staticComputedFieldPrefix, id)); }
    // A builtin's @name: the well-known symbol or private name it spells, or the null handle for a name the builtin names do not hold.
    ALWAYS_INLINE JSParseIdentifier makeBuiltinIdentifier8(std::span<const uint8_t> characters NOESCAPE, bool isWellKnownSymbol) { auto& s = state(); auto span = spanReinterpretCast<const Latin1Character>(characters); auto& names = s.vm().propertyNames->builtinNames(); auto* symbol = isWellKnownSymbol ? names.lookUpWellKnownSymbol(span) : names.lookUpPrivateName(span); return symbol ? s.addIdentifier(s.identifierArena().makeIdentifier(s.vm(), symbol)) : JSParseIdentifier { }; }
    ALWAYS_INLINE JSParseIdentifier makeBuiltinIdentifier16(std::span<const char16_t> characters NOESCAPE, bool isWellKnownSymbol) { auto& s = state(); auto& names = s.vm().propertyNames->builtinNames(); auto* symbol = isWellKnownSymbol ? names.lookUpWellKnownSymbol(characters) : names.lookUpPrivateName(characters); return symbol ? s.addIdentifier(s.identifierArena().makeIdentifier(s.vm(), symbol)) : JSParseIdentifier { }; }
    // Well-known names are at fixed handles: Swift computes them as this does.
    ALWAYS_INLINE JSParseIdentifier wellKnownIdentifier(JSParseWellKnownName name) { RELEASE_ASSERT(name < JSParseWellKnownName::Count); return { static_cast<uint32_t>(name) + 1 }; }
    ALWAYS_INLINE uintptr_t identifierKey(JSParseIdentifier a) { auto* x = state().identifierOrNull(a); return x ? std::bit_cast<uintptr_t>(x->impl()) : 0; }
    // Entry 0 is null and every other entry is non-null (addIdentifier takes a reference), so x && y is a.index && b.index.
    ALWAYS_INLINE bool sameIdentifier(JSParseIdentifier a, JSParseIdentifier b) { auto& s = state(); auto* x = s.identifierOrNull(a); auto* y = s.identifierOrNull(b); return x == y || (x && y && *x == *y); }
    // The key of a well-known name, from a fixed table, so a constant name costs no check; identifierKey(a) == wellKnownKey(name) is
    // sameIdentifier(a, wellKnownIdentifier(name)): two Identifiers are equal when their impl pointers are, and the key of the null handle is 0.
    ALWAYS_INLINE uintptr_t wellKnownKey(JSParseWellKnownName name) { return state().wellKnownKey(name); }

    // Scopes: the C++ containers of each scope Swift pushes, by its depth, which must be a live one.
    ALWAYS_INLINE JSParseScope pushScope() { return state().pushScope(); }
    ALWAYS_INLINE void popScope(JSParseScope scope) { state().popScope(scope); }
    ALWAYS_INLINE bool environmentAdd(JSParseScope scope, JSParseEnvironmentKind kind, JSParseIdentifier identifier, uint16_t traits) { auto& s = state(); auto result = s.environment(scope, kind).add(s.identifier(identifier)); s.setTraits(result.iterator->value, traits); return result.isNewEntry; }
    // Scope::declareParameter's three outcomes, as bits: isDuplicateParameter, isArgumentsIdent and isValidStrictMode.
    static constexpr uint8_t declaredParameterDuplicate = 1;
    static constexpr uint8_t declaredParameterIsArguments = 2;
    static constexpr uint8_t declaredParameterValidStrictMode = 4;
    // Scope::declareParameter's body (Parser.h): one hash probe, the entry updated in place, the name added to the declared parameters.
    ALWAYS_INLINE uint8_t declareParameter(JSParseScope scope, JSParseIdentifier identifier)
    {
        auto& s = state();
        auto& ident = s.identifier(identifier);
        auto key = std::bit_cast<uintptr_t>(ident.impl());
        auto result = s.environment(scope, JSParseEnvironmentKind::Declared).add(ident);
        auto& entry = result.iterator->value;
        bool isDuplicate = !result.isNewEntry && entry.isParameter();
        bool isArguments = key == s.wellKnownKey(JSParseWellKnownName::arguments);
        bool isValid = !isDuplicate && key != s.wellKnownKey(JSParseWellKnownName::eval) && !isArguments && !s.isStrictModeReservedKey(key);
        entry.clearIsVar();
        entry.setIsParameter();
        s.nameSetAdd(s.mutableScope(scope), JSParseNameSetKind::DeclaredParameters, ident.impl());
        return (isDuplicate ? declaredParameterDuplicate : 0) | (isArguments ? declaredParameterIsArguments : 0) | (isValid ? declaredParameterValidStrictMode : 0);
    }
    ALWAYS_INLINE bool isStrictModeReservedWord(JSParseIdentifier identifier) { auto& s = state(); return s.isStrictModeReservedKey(std::bit_cast<uintptr_t>(s.identifier(identifier).impl())); }
    // The entry's traits, or std::nullopt when the environment has no entry for the name.
    ALWAYS_INLINE std::optional<uint16_t> environmentTraits(JSParseScope scope, JSParseEnvironmentKind kind, JSParseIdentifier identifier) { auto& s = state(); auto& environment = s.readEnvironment(scope, kind); auto iterator = environment.find(s.identifier(identifier).impl()); return iterator == environment.end() ? std::nullopt : std::optional<uint16_t>(iterator->value.bits()); }
    ALWAYS_INLINE bool environmentContains(JSParseScope scope, JSParseEnvironmentKind kind, JSParseIdentifier identifier) { auto& s = state(); return s.readEnvironment(scope, kind).contains(s.identifier(identifier).impl()); }
    ALWAYS_INLINE void environmentClearIsVar(JSParseScope scope, JSParseEnvironmentKind kind, JSParseIdentifier identifier) { auto& s = state(); auto& environment = s.environment(scope, kind); auto iterator = environment.find(s.identifier(identifier).impl()); RELEASE_ASSERT(iterator != environment.end()); iterator->value.clearIsVar(); }
    ALWAYS_INLINE void environmentMarkAllAsCaptured(JSParseScope scope, JSParseEnvironmentKind kind) { state().environment(scope, kind).markAllVariablesAsCaptured(); }
    ALWAYS_INLINE unsigned environmentSize(JSParseScope scope, JSParseEnvironmentKind kind) { return state().readEnvironment(scope, kind).size(); }
    ALWAYS_INLINE void setHasAwaitUsingDeclaration(JSParseScope scope) { state().mutableScope(scope).lexicalVariables.setHasAwaitUsingDeclaration(); }
    ALWAYS_INLINE bool declarePrivateField(JSParseScope scope, JSParseIdentifier identifier) { auto& s = state(); return s.mutableScope(scope).lexicalVariables.declarePrivateField(s.identifier(identifier)).isNewEntry; }
    ALWAYS_INLINE bool declarePrivateMethod(JSParseScope scope, JSParseIdentifier identifier, bool isStatic) { auto& s = state(); auto& environment = s.mutableScope(scope).lexicalVariables; return isStatic ? environment.declareStaticPrivateMethod(s.identifier(identifier)) : environment.declarePrivateMethod(s.identifier(identifier)); }
    ALWAYS_INLINE JSParsePrivateDeclarationResult declarePrivateAccessor(JSParseScope scope, JSParseIdentifier identifier, bool isSetter, bool isStatic) { auto& s = state(); auto& environment = s.mutableScope(scope).lexicalVariables; auto& name = s.identifier(identifier); return static_cast<JSParsePrivateDeclarationResult>(isSetter ? (isStatic ? environment.declareStaticPrivateSetter(name) : environment.declarePrivateSetter(name)) : (isStatic ? environment.declareStaticPrivateGetter(name) : environment.declarePrivateGetter(name))); }
    ALWAYS_INLINE bool hasPrivateName(JSParseScope scope, JSParseIdentifier identifier) { auto& s = state(); return s.scope(scope).lexicalVariables.hasPrivateName(s.identifier(identifier)); }
    ALWAYS_INLINE bool nameSetAdd(JSParseScope scope, JSParseNameSetKind kind, JSParseIdentifier identifier) { auto& s = state(); return s.nameSetAdd(s.mutableScope(scope), kind, s.identifier(identifier).impl()); }
    ALWAYS_INLINE bool nameSetContains(JSParseScope scope, JSParseNameSetKind kind, JSParseIdentifier identifier) { auto& s = state(); return s.nameSetContains(s.scope(scope), kind, s.identifier(identifier).impl()); }
    ALWAYS_INLINE unsigned nameSetSize(JSParseScope scope, JSParseNameSetKind kind) { auto& s = state(); return s.nameSetSize(s.scope(scope), kind); }
    // m_usedVariables, the stack of sets of a scope's variable uses.
    ALWAYS_INLINE void pushUsedVariableSet(JSParseScope scope) { auto& storage = state().mutableScope(scope); storage.usedVariables.constructAndAppend(); storage.lastAddedUsedVariable = nullptr; }
    ALWAYS_INLINE void useVariable(JSParseScope scope, JSParseIdentifier identifier) { auto& s = state(); s.useVariable(s.mutableScope(scope), s.identifier(identifier).impl()); }
    ALWAYS_INLINE bool usedVariablesContains(JSParseScope scope, JSParseIdentifier identifier) { auto& s = state(); return s.usedVariablesContains(s.scope(scope), s.identifier(identifier).impl()); }
    ALWAYS_INLINE unsigned usedVariableSetCount(JSParseScope scope) { return state().scope(scope).usedVariables.size(); }
    ALWAYS_INLINE void revertToPreviousUsedVariables(JSParseScope scope, unsigned count) { auto& storage = state().mutableScope(scope); RELEASE_ASSERT(count <= storage.usedVariables.size()); storage.usedVariables.shrink(count); storage.lastAddedUsedVariable = nullptr; }
    void mergeIntoPreviousUsedVariables(JSParseScope scope, unsigned count) { state().mergeIntoPreviousUsedVariables(state().mutableScope(scope), count); }
    void markLastUsedVariablesSetAsCaptured(JSParseScope scope, unsigned from) { state().markLastUsedVariablesSetAsCaptured(state().mutableScope(scope), from); }
    // The container work of Scope.collectFreeVariables; the flags are the nested scope's Swift state.
    void collectFreeVariables(JSParseScope into, JSParseScope nested, bool shouldTrackClosedVariables, bool filterArguments, bool nestedIsFunctionBoundary, bool nestedIsLexicalScope) { state().collectFreeVariables(into, nested, shouldTrackClosedVariables, filterArguments, nestedIsFunctionBoundary, nestedIsLexicalScope); }
    void computeLexicallyCapturedVariablesAndPurgeCandidates(JSParseScope scope) { state().computeLexicallyCapturedVariablesAndPurgeCandidates(state().mutableScope(scope)); }
    void collectNonLocalCapturesFromParameterExpressions(JSParseScope scope) { state().collectNonLocalCapturesFromParameterExpressions(state().mutableScope(scope)); }
    ALWAYS_INLINE bool hasNonLocalCapturesFromParameterExpressions(JSParseScope scope) { return !state().scope(scope).nonLocalCapturesFromParameterExpressions.isEmpty(); }
    // The function declarations and Annex B hoisting candidates, by node handle.
    ALWAYS_INLINE void appendFunction(JSParseScope scope, JSParseNode metadata) { auto& s = state(); s.mutableScope(scope).functionDeclarations.append(s.template node<FunctionMetadataNode>(metadata)); }
    ALWAYS_INLINE void addSloppyModeFunctionHoistingCandidate(JSParseScope scope, JSParseNode metadata, bool needsDuplicateDeclarationCheck) { auto& s = state(); s.mutableScope(scope).sloppyModeFunctionHoistingCandidates.add(s.template node<FunctionMetadataNode>(metadata), needsDuplicateDeclarationCheck); }
    ALWAYS_INLINE bool hasSloppyModeFunctionHoistingCandidates(JSParseScope scope) { return !state().scope(scope).sloppyModeFunctionHoistingCandidates.isEmpty(); }
    void finalizeSloppyModeFunctionHoisting(JSParseScope scope) { state().finalizeSloppyModeFunctionHoisting(state().mutableScope(scope)); }
    void bubbleSloppyModeFunctionHoistingCandidates(JSParseScope from, JSParseScope into, bool isSimpleCatchParameterScope) { state().bubbleSloppyModeFunctionHoistingCandidates(from, into, isSimpleCatchParameterScope); }
    // The containers a node takes: moved out of the scope into a handle the node's forwarder consumes once.
    ALWAYS_INLINE JSParseEnvironment takeEnvironment(JSParseScope scope, JSParseEnvironmentKind kind) { auto& s = state(); return s.addEnvironment(WTF::move(s.environment(scope, kind))); }
    ALWAYS_INLINE JSParseFunctionStack takeFunctionDeclarations(JSParseScope scope) { auto& s = state(); return s.addFunctionStack(WTF::move(s.mutableScope(scope).functionDeclarations)); }

    // The SourceProviderCache. A hit restores the item's used variables into the
    // scope's last set; Swift checks every offset of the item against the source before it moves the lexer.
    ALWAYS_INLINE bool hasFunctionCache() { return state().hasFunctionCache(); }
    std::optional<JSParseCachedFunction> findCachedFunction(JSParseScope scope, int32_t parametersStart) { return state().findCachedFunction(scope, parametersStart); }
    void recordCachedFunction(JSParseScope scope, const JSParseCachedFunction& record) { state().recordCachedFunction(scope, record); }
    void addRecordedCachedFunction(int32_t startOffset) { state().addRecordedCachedFunction(startOffset); }

    // The error message, which Swift assembles.
    ALWAYS_INLINE void appendErrorCharacters8(std::span<const uint8_t> characters NOESCAPE) { state().errorMessage().append(spanReinterpretCast<const Latin1Character>(characters)); }
    ALWAYS_INLINE void appendErrorCharacters16(std::span<const char16_t> characters NOESCAPE) { state().errorMessage().append(characters); }
    // A token's characters as an error message prints them (the lexer's own messages are built with makeString).
    ALWAYS_INLINE void appendPrintedErrorCharacters16(std::span<const char16_t> characters NOESCAPE) { appendParseErrorCharactersReplacingUnpairedSurrogates(state().errorMessage(), characters); }
    ALWAYS_INLINE void appendErrorIdentifier(JSParseIdentifier identifier)
    {
        auto& s = state();
        // An Identifier is printed through a C string, which ends at the first NUL (a string export
        // name can hold one).
        StringView string = s.identifier(identifier).string();
        if (size_t nul = string.find(static_cast<char16_t>(0)); nul != notFound)
            string = string.left(static_cast<unsigned>(nul));
        if (string.is8Bit())
            s.errorMessage().append(string);
        else
            appendParseErrorCharactersReplacingUnpairedSurrogates(s.errorMessage(), string.span16());
    }
    ALWAYS_INLINE void appendErrorNumber(int64_t number) { state().errorMessage().append(number); }
    ALWAYS_INLINE void clearErrorMessage() { state().errorMessage().clear(); }

    // ModuleScopeData and DebuggerParseData.
    ALWAYS_INLINE bool hasModuleScopeData() { return !!state().moduleScopeData(); }
    ALWAYS_INLINE bool moduleExportName(JSParseIdentifier name) { auto& s = state(); return s.checkedModuleScopeData().exportName(s.identifier(name)); }
    ALWAYS_INLINE void moduleExportBinding(JSParseIdentifier localName) { auto& s = state(); s.checkedModuleScopeData().exportBinding(s.identifier(localName)); }
    ALWAYS_INLINE void moduleExportBindingAs(JSParseIdentifier localName, JSParseIdentifier exportedName) { auto& s = state(); s.checkedModuleScopeData().exportBinding(s.identifier(localName), s.identifier(exportedName)); }
    ALWAYS_INLINE bool identifierHasUnpairedSurrogate(JSParseIdentifier identifier) { return hasUnpairedSurrogate(state().identifier(identifier).string()); }
    // Marks the module's exported bindings that name a top-level declaration; returns the first that names none, or the null handle.
    JSParseIdentifier markExportedBindingsAsExported(JSParseScope scope) { return state().markExportedBindingsAsExported(scope); }
    // The first private name the scope uses that neither it nor the eval's parent scopes declare, or the null handle.
    JSParseIdentifier undeclaredPrivateName(JSParseScope scope) { return state().undeclaredPrivateName(scope); }
    unsigned usedPrivateNameCount(JSParseScope scope) { return state().usedPrivateNameCount(scope); }
    bool hasRecordedCacheParameters(JSParseScope scope) { return !!state().scope(scope).cacheParameters; }
    // Marks the scope's captured declared variables captured.
    void markCapturedVariablesAsCaptured(JSParseScope scope, bool allDeclaredVariablesAreCaptured) { state().markCapturedVariablesAsCaptured(scope, allDeclaredVariablesAreCaptured); }
    ALWAYS_INLINE bool hasDebuggerParseData() { return !!state().debuggerParseData(); }
    ALWAYS_INLINE void appendDebuggerPause(const JSTextPosition& position) { state().checkedDebuggerParseData().pausePositions.appendPause(position); }
    ALWAYS_INLINE void appendDebuggerEntry(const JSTextPosition& position) { state().checkedDebuggerParseData().pausePositions.appendEntry(position); }
    ALWAYS_INLINE void appendDebuggerLeave(const JSTextPosition& position) { state().checkedDebuggerParseData().pausePositions.appendLeave(position); }

    // The inputs of a reparse.
    void copyParentScopePrivateNames(JSParseScope scope) { state().copyParentScopePrivateNames(scope); }
    ALWAYS_INLINE unsigned classElementDefinitionCount() { return state().classElementDefinitionCount(); }
    // The class element definitions of a class field initializer reparse.
    ALWAYS_INLINE JSParseIdentifier classElementDefinitionIdentifier(unsigned i) { auto& s = state(); return s.addIdentifier(s.classElementDefinition(i).ident); }
    ALWAYS_INLINE JSParseClassElementKind classElementDefinitionKind(unsigned i) { return static_cast<JSParseClassElementKind>(state().classElementDefinition(i).kind); }
    ALWAYS_INLINE int32_t classElementDefinitionPosition(unsigned i) { return state().classElementDefinition(i).position.offset; }
    ALWAYS_INLINE std::optional<int32_t> classElementDefinitionInitializerPosition(unsigned i) { auto& position = state().classElementDefinition(i).initializerPosition; return position ? std::optional<int32_t>(position->offset) : std::nullopt; }
    // PropertyListNode::setHasPrivateAccessors on the class's elements.
    ALWAYS_INLINE void setClassElementsHasPrivateAccessors(JSParseNode classElements, bool hasPrivateAccessors) { state().template node<PropertyListNode>(classElements)->setHasPrivateAccessors(hasPrivateAccessors); }
    ALWAYS_INLINE JSParseIdentifier makeClassBuiltinPrivateName(JSParseClassBuiltinName which)
    {
        auto& s = state();
        auto& names = s.vm().propertyNames->builtinNames();
        auto name = which == JSParseClassBuiltinName::StaticInitializerBlock ? names.staticInitializerBlockPrivateName() : which == JSParseClassBuiltinName::PrivateBrand ? names.privateBrandPrivateName() : names.privateClassBrandPrivateName();
        return s.addIdentifier(s.identifierArena().makeIdentifier(s.vm(), std::bit_cast<SymbolImpl*>(name.impl())));
    }

    // Shared C++: the stack limit, regular expression literals and the number conversions.
    ALWAYS_INLINE bool isSafeToRecurse() { return state().vm().isSafeToRecurse(); }
    // A regular expression literal: the RegExpCache holds only patterns that compiled, so a hit
    // skips the syntax check; otherwise the check's Yarr::ErrorCode, as its raw value (0: none), and its message.
    bool isRegularExpressionCached(JSParseIdentifier pattern, JSParseIdentifier flags) { return state().isRegularExpressionCached(pattern, flags); }
    uint8_t checkRegularExpressionSyntax(JSParseIdentifier pattern, JSParseIdentifier flags) { return state().checkRegularExpressionSyntax(pattern, flags); }
    // Whether the expression is a dot access of call or apply.
    bool isCallOrApplyDotAccessor(JSParseNode expr)
    {
        auto& s = state();
        auto* node = s.template node<ExpressionNode>(expr);
        if (!node->isDotAccessorNode())
            return false;
        auto& names = s.vm().propertyNames->builtinNames();
        auto& identifier = static_cast<DotAccessorNode*>(node)->identifier();
        return identifier == names.callPublicName() || identifier == names.applyPublicName();
    }
    void appendRegularExpressionErrorMessage(uint8_t errorCode) { state().appendRegularExpressionErrorMessage(errorCode); }
    ALWAYS_INLINE double parseDouble8(std::span<const uint8_t> characters NOESCAPE, size_t& parsedLength) { return WTF::parseDouble(spanReinterpretCast<const Latin1Character>(characters), parsedLength); }

    // The ASTBuilder, member for member.
    ALWAYS_INLINE JSParseNode makeStaticBlockFunctionCallNode(const JSTokenLocation& location, JSParseNode func, const JSTextPosition& divot, const JSTextPosition& divotStart, const JSTextPosition& divotEnd) { auto& s = state(); return s.add(s.builder().makeStaticBlockFunctionCallNode(location, s.template node<ExpressionNode>(func), divot, divotStart, divotEnd)); }
    ALWAYS_INLINE JSParseNode makeFunctionCallNode(const JSTokenLocation& location, JSParseNode func, bool previousBaseWasSuper, JSParseNode args, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd, size_t callOrApplyChildDepth, bool isOptionalCall) { auto& s = state(); return s.add(s.builder().makeFunctionCallNode(location, s.template node<ExpressionNode>(func), previousBaseWasSuper, s.template node<ArgumentsNode>(args), divotStart, divot, divotEnd, callOrApplyChildDepth, isOptionalCall)); }
    ALWAYS_INLINE JSParseNode createSourceElements() { auto& s = state(); return s.add(s.builder().createSourceElements()); }
    ALWAYS_INLINE int features() { return state().builder().features(); }
    ALWAYS_INLINE JSParseNode makePrefixNode(const JSTokenLocation& location, JSParseNode expr, Operator op, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().makePrefixNode(location, s.template node<ExpressionNode>(expr), op, start, divot, end)); }
    ALWAYS_INLINE JSParseNode makePostfixNode(const JSTokenLocation& location, JSParseNode expr, Operator op, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().makePostfixNode(location, s.template node<ExpressionNode>(expr), op, start, divot, end)); }
    ALWAYS_INLINE JSParseNode makeTypeOfNode(const JSTokenLocation& location, JSParseNode expr, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().makeTypeOfNode(location, s.template node<ExpressionNode>(expr), start, divot, end)); }
    ALWAYS_INLINE JSParseNode makeDeleteNode(const JSTokenLocation& location, JSParseNode expr, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().makeDeleteNode(location, s.template node<ExpressionNode>(expr), start, divot, end)); }
    ALWAYS_INLINE JSParseNode makeNegateNode(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().makeNegateNode(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode makeBitwiseNotNode(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().makeBitwiseNotNode(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createLogicalNot(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createLogicalNot(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createUnaryPlus(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createUnaryPlus(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createVoid(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createVoid(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createThisExpr(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createThisExpr(location)); }
    ALWAYS_INLINE JSParseNode createSuperExpr(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createSuperExpr(location)); }
    ALWAYS_INLINE JSParseNode createImportExpr(const JSTokenLocation& location, JSParseNode expr, JSParseNode option, bool deferred, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createImportExpr(location, s.template node<ExpressionNode>(expr), s.template nodeOrNull<ExpressionNode>(option), deferred, start, divot, end)); }
    ALWAYS_INLINE JSParseNode createNewTargetExpr(const JSTokenLocation location) { auto& s = state(); return s.add(s.builder().createNewTargetExpr(location)); }
    ALWAYS_INLINE JSParseNode createImportMetaExpr(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createImportMetaExpr(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE void setIsParenthesized(JSParseNode expr) { auto& s = state(); s.builder().setIsParenthesized(s.template node<ExpressionNode>(expr)); }
    ALWAYS_INLINE bool isMetaProperty(JSParseNode node) { auto& s = state(); return s.builder().isMetaProperty(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool isNewTarget(JSParseNode node) { auto& s = state(); return s.builder().isNewTarget(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool isImportMeta(JSParseNode node) { auto& s = state(); return s.builder().isImportMeta(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE JSParseNode createResolve(const JSTokenLocation& location, JSParseIdentifier ident, const JSTextPosition& start, const JSTextPosition& end, const bool needToCheckUsesArguments) { auto& s = state(); return s.add(s.builder().createResolve(location, s.identifier(ident), start, end, needToCheckUsesArguments)); }
    ALWAYS_INLINE JSParseNode createPrivateIdentifierNode(const JSTokenLocation& location, JSParseIdentifier ident) { auto& s = state(); return s.add(s.builder().createPrivateIdentifierNode(location, s.identifier(ident))); }
    ALWAYS_INLINE JSParseNode createObjectLiteral(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createObjectLiteral(location)); }
    ALWAYS_INLINE JSParseNode createObjectLiteral(const JSTokenLocation& location, JSParseNode properties) { auto& s = state(); RELEASE_ASSERT(!s.isClassElementList(properties)); return s.add(s.builder().createObjectLiteral(location, s.template node<PropertyListNode>(properties))); }
    ALWAYS_INLINE JSParseNode createArray(const JSTokenLocation& location, int elisions) { auto& s = state(); return s.add(s.builder().createArray(location, elisions)); }
    ALWAYS_INLINE JSParseNode createArray(const JSTokenLocation& location, JSParseNode elems) { auto& s = state(); return s.add(s.builder().createArray(location, s.template node<ElementNode>(elems))); }
    ALWAYS_INLINE JSParseNode createArray(const JSTokenLocation& location, int elisions, JSParseNode elems) { auto& s = state(); return s.add(s.builder().createArray(location, elisions, s.template node<ElementNode>(elems))); }
    ALWAYS_INLINE JSParseNode createDoubleExpr(const JSTokenLocation& location, double d) { auto& s = state(); return s.add(s.builder().createDoubleExpr(location, d)); }
    ALWAYS_INLINE JSParseNode createIntegerExpr(const JSTokenLocation& location, double d) { auto& s = state(); return s.add(s.builder().createIntegerExpr(location, d)); }
    ALWAYS_INLINE JSParseNode createBigInt(const JSTokenLocation& location, JSParseIdentifier bigInt, uint8_t radix) { auto& s = state(); return s.add(s.builder().createBigInt(location, &s.identifier(bigInt), radix)); }
    ALWAYS_INLINE JSParseNode createString(const JSTokenLocation& location, JSParseIdentifier string) { auto& s = state(); return s.add(s.builder().createString(location, &s.identifier(string))); }
    ALWAYS_INLINE JSParseNode createBoolean(const JSTokenLocation& location, bool b) { auto& s = state(); return s.add(s.builder().createBoolean(location, b)); }
    ALWAYS_INLINE JSParseNode createNull(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createNull(location)); }
    ALWAYS_INLINE JSParseNode createBracketAccess(const JSTokenLocation& location, JSParseNode base, JSParseNode property, bool propertyHasAssignments, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createBracketAccess(location, s.template node<ExpressionNode>(base), s.template node<ExpressionNode>(property), propertyHasAssignments, start, divot, end)); }
    ALWAYS_INLINE JSParseNode createDotAccess(const JSTokenLocation& location, JSParseNode base, JSParseIdentifier property, DotType type, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createDotAccess(location, s.template node<ExpressionNode>(base), &s.identifier(property), type, start, divot, end)); }
    ALWAYS_INLINE JSParseNode createSpreadExpression(const JSTokenLocation& location, JSParseNode expression, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createSpreadExpression(location, s.template node<ExpressionNode>(expression), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createObjectSpreadExpression(const JSTokenLocation& location, JSParseNode expression, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createObjectSpreadExpression(location, s.template node<ExpressionNode>(expression), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createTemplateString(const JSTokenLocation& location, JSParseIdentifier cooked, JSParseIdentifier raw) { auto& s = state(); return s.add(s.builder().createTemplateString(location, s.identifierOrNull(cooked), s.identifierOrNull(raw))); }
    ALWAYS_INLINE JSParseNode createTemplateStringList(JSParseNode templateString) { auto& s = state(); return s.add(s.builder().createTemplateStringList(s.template node<TemplateStringNode>(templateString))); }
    ALWAYS_INLINE JSParseNode createTemplateStringList(JSParseNode templateStringList, JSParseNode templateString) { auto& s = state(); return s.add(s.builder().createTemplateStringList(s.template node<TemplateStringListNode>(templateStringList), s.template node<TemplateStringNode>(templateString))); }
    ALWAYS_INLINE JSParseNode createTemplateExpressionList(JSParseNode expression) { auto& s = state(); return s.add(s.builder().createTemplateExpressionList(s.template node<ExpressionNode>(expression))); }
    ALWAYS_INLINE JSParseNode createTemplateExpressionList(JSParseNode templateExpressionListNode, JSParseNode expression) { auto& s = state(); return s.add(s.builder().createTemplateExpressionList(s.template node<TemplateExpressionListNode>(templateExpressionListNode), s.template node<ExpressionNode>(expression))); }
    ALWAYS_INLINE JSParseNode createTemplateLiteral(const JSTokenLocation& location, JSParseNode templateStringList) { auto& s = state(); return s.add(s.builder().createTemplateLiteral(location, s.template node<TemplateStringListNode>(templateStringList))); }
    ALWAYS_INLINE JSParseNode createTemplateLiteral(const JSTokenLocation& location, JSParseNode templateStringList, JSParseNode templateExpressionList) { auto& s = state(); return s.add(s.builder().createTemplateLiteral(location, s.template node<TemplateStringListNode>(templateStringList), s.template node<TemplateExpressionListNode>(templateExpressionList))); }
    ALWAYS_INLINE JSParseNode createTaggedTemplate(const JSTokenLocation& location, JSParseNode base, JSParseNode templateLiteral, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createTaggedTemplate(location, s.template node<ExpressionNode>(base), s.template node<TemplateLiteralNode>(templateLiteral), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createRegExp(const JSTokenLocation& location, JSParseIdentifier pattern, JSParseIdentifier flags, const JSTextPosition& start, bool skipSyntaxCheck) { auto& s = state(); return s.add(s.builder().createRegExp(location, s.identifier(pattern), s.identifier(flags), start, skipSyntaxCheck)); }
    ALWAYS_INLINE JSParseNode createNewExpr(const JSTokenLocation& location, JSParseNode expr, JSParseNode arguments, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createNewExpr(location, s.template node<ExpressionNode>(expr), s.template node<ArgumentsNode>(arguments), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createNewExpr(const JSTokenLocation& location, JSParseNode expr, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createNewExpr(location, s.template node<ExpressionNode>(expr), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createOptionalChain(const JSTokenLocation& location, JSParseNode base, JSParseNode expr, bool isOutermost) { auto& s = state(); return s.add(s.builder().createOptionalChain(location, s.template nodeOrNull<ExpressionNode>(base), s.template node<ExpressionNode>(expr), isOutermost)); }
    ALWAYS_INLINE JSParseNode createConditionalExpr(const JSTokenLocation& location, JSParseNode condition, JSParseNode lhs, JSParseNode rhs) { auto& s = state(); return s.add(s.builder().createConditionalExpr(location, s.template node<ExpressionNode>(condition), s.template node<ExpressionNode>(lhs), s.template node<ExpressionNode>(rhs))); }
    ALWAYS_INLINE JSParseNode createAssignResolve(const JSTokenLocation& location, JSParseIdentifier ident, JSParseNode rhs, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end, AssignmentContext assignmentContext) { auto& s = state(); return s.add(s.builder().createAssignResolve(location, s.identifier(ident), s.template node<ExpressionNode>(rhs), start, divot, end, assignmentContext)); }
    ALWAYS_INLINE JSParseNode createYield(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createYield(location)); }
    ALWAYS_INLINE JSParseNode createYield(const JSTokenLocation& location, JSParseNode argument, bool delegate, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createYield(location, s.template node<ExpressionNode>(argument), delegate, start, divot, end)); }
    ALWAYS_INLINE JSParseNode createAwait(const JSTokenLocation& location, JSParseNode argument, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createAwait(location, s.template node<ExpressionNode>(argument), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createDefineField(const JSTokenLocation& location, JSParseIdentifier ident, JSParseNode initializer, DefineFieldNode::Type type) { auto& s = state(); return s.add(s.builder().createDefineField(location, s.identifier(ident), s.template nodeOrNull<ExpressionNode>(initializer), type)); }
    ALWAYS_INLINE JSParseNode createClassExpr(const JSTokenLocation& location, const JSParseClassInfo& classInfo, JSParseEnvironment classHeadEnvironment, JSParseEnvironment classEnvironment, JSParseNode constructor, JSParseNode parentClass, JSParseNode classElements, const JSTextPosition& start, const JSTextPosition& divot, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createClassExpr(location, s.classInfo(classInfo), s.takeEnvironment(classHeadEnvironment), s.takeEnvironment(classEnvironment), s.template nodeOrNull<ExpressionNode>(constructor), s.template nodeOrNull<ExpressionNode>(parentClass), s.template nodeOrNull<PropertyListNode>(classElements), start, divot, end)); }
    ALWAYS_INLINE JSParseNode createFunctionExpr(const JSTokenLocation& location, const JSParseFunctionInfo& functionInfo) { auto& s = state(); return s.add(s.builder().createFunctionExpr(location, s.functionInfo(functionInfo))); }
    ALWAYS_INLINE JSParseNode createGeneratorFunctionBody(const JSTokenLocation& location, const JSParseFunctionInfo& functionInfo, JSParseIdentifier name) { auto& s = state(); return s.add(s.builder().createGeneratorFunctionBody(location, s.functionInfo(functionInfo), s.identifierOrNullIdentifier(name))); }
    ALWAYS_INLINE JSParseNode createAsyncFunctionBody(const JSTokenLocation& location, const JSParseFunctionInfo& functionInfo, SourceParseMode parseMode, JSParseIdentifier name) { auto& s = state(); return s.add(s.builder().createAsyncFunctionBody(location, s.functionInfo(functionInfo), parseMode, s.identifierOrNullIdentifier(name))); }
    ALWAYS_INLINE JSParseNode createMethodDefinition(const JSTokenLocation& location, const JSParseFunctionInfo& functionInfo) { auto& s = state(); return s.add(s.builder().createMethodDefinition(location, s.functionInfo(functionInfo))); }
    ALWAYS_INLINE JSParseNode createFunctionMetadata(const JSTokenLocation& startLocation, const JSTokenLocation& endLocation, unsigned functionStart, int functionNameStart, int parametersStart, ImplementationVisibility implementationVisibility, LexicallyScopedFeatures lexicallyScopedFeatures, ConstructorKind constructorKind, SuperBinding superBinding, unsigned parameterCount, SourceParseMode mode, bool isArrowFunctionBodyExpression) { auto& s = state(); return s.add(s.builder().createFunctionMetadata(startLocation, endLocation, functionStart, functionNameStart, parametersStart, implementationVisibility, lexicallyScopedFeatures, constructorKind, superBinding, parameterCount, mode, isArrowFunctionBodyExpression)); }
    ALWAYS_INLINE JSParseNode createArrowFunctionExpr(const JSTokenLocation& location, const JSParseFunctionInfo& functionInfo) { auto& s = state(); return s.add(s.builder().createArrowFunctionExpr(location, s.functionInfo(functionInfo))); }
    ALWAYS_INLINE JSParseNode createArguments() { auto& s = state(); return s.add(s.builder().createArguments()); }
    ALWAYS_INLINE JSParseNode createArguments(JSParseNode args, bool hasAssignments) { auto& s = state(); return s.add(s.builder().createArguments(s.template node<ArgumentListNode>(args), hasAssignments)); }
    ALWAYS_INLINE JSParseNode createArgumentsList(const JSTokenLocation& location, JSParseNode arg) { auto& s = state(); return s.add(s.builder().createArgumentsList(location, s.template node<ExpressionNode>(arg))); }
    ALWAYS_INLINE JSParseNode createArgumentsList(const JSTokenLocation& location, JSParseNode args, JSParseNode arg) { auto& s = state(); return s.add(s.builder().createArgumentsList(location, s.template node<ArgumentListNode>(args), s.template node<ExpressionNode>(arg))); }
    ALWAYS_INLINE JSParseNode createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type, JSParseIdentifier name, const JSParseFunctionInfo& functionInfo, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createGetterOrSetterProperty(location, type, &s.identifier(name), s.functionInfo(functionInfo), tag)); }
    ALWAYS_INLINE JSParseNode createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type, JSParseNode name, const JSParseFunctionInfo& functionInfo, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createGetterOrSetterProperty(location, type, s.template node<ExpressionNode>(name), s.functionInfo(functionInfo), tag)); }
    ALWAYS_INLINE JSParseNode createGetterOrSetterProperty(const JSTokenLocation& location, PropertyNode::Type type, double name, const JSParseFunctionInfo& functionInfo, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createGetterOrSetterProperty(s.vm(), s.arena(), location, type, name, s.functionInfo(functionInfo), tag)); }
    ALWAYS_INLINE JSParseNode createProperty(JSParseIdentifier propertyName, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createProperty(&s.identifier(propertyName), type, superBinding, tag)); }
    ALWAYS_INLINE JSParseNode createProperty(JSParseIdentifier propertyName, JSParseNode node, PropertyNode::Type type, SuperBinding superBinding, InferName inferName, ClassElementTag tag) { auto& s = state(); RELEASE_ASSERT(node.index || (tag != ClassElementTag::No && inferName == InferName::Disallowed)); return s.add(s.builder().createProperty(&s.identifier(propertyName), s.template nodeOrNull<ExpressionNode>(node), type, superBinding, inferName, tag)); }
    ALWAYS_INLINE JSParseNode createProperty(JSParseNode node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createProperty(s.template node<ExpressionNode>(node), type, superBinding, tag)); }
    ALWAYS_INLINE JSParseNode createProperty(double propertyName, JSParseNode node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createProperty(s.vm(), s.arena(), propertyName, s.template node<ExpressionNode>(node), type, superBinding, tag)); }
    ALWAYS_INLINE JSParseNode createProperty(JSParseNode propertyName, JSParseNode node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { auto& s = state(); return s.add(s.builder().createProperty(s.template node<ExpressionNode>(propertyName), s.template node<ExpressionNode>(node), type, superBinding, tag)); }
    ALWAYS_INLINE JSParseNode createProperty(JSParseIdentifier identifier, JSParseNode propertyName, JSParseNode node, PropertyNode::Type type, SuperBinding superBinding, ClassElementTag tag) { auto& s = state(); RELEASE_ASSERT(node.index || tag != ClassElementTag::No); return s.add(s.builder().createProperty(&s.identifier(identifier), s.template node<ExpressionNode>(propertyName), s.template nodeOrNull<ExpressionNode>(node), type, superBinding, tag)); }
    JSParseNode createPropertyList(const JSTokenLocation& location, JSParseNode property) { return state().createPropertyList(location, property); }
    JSParseNode createPropertyList(const JSTokenLocation& location, JSParseNode property, JSParseNode tail) { return state().createPropertyList(location, property, tail); }
    ALWAYS_INLINE JSParseNode createElementList(int elisions, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createElementList(elisions, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createElementList(JSParseNode elems, int elisions, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createElementList(s.template node<ElementNode>(elems), elisions, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createElementList(JSParseNode elems) { auto& s = state(); return s.add(s.builder().createElementList(s.template node<ArgumentListNode>(elems))); }
    ALWAYS_INLINE JSParseNode createFormalParameterList() { auto& s = state(); return s.add(s.builder().createFormalParameterList()); }
    ALWAYS_INLINE void appendParameter(JSParseNode list, JSParseNode pattern, JSParseNode defaultValue) { auto& s = state(); s.builder().appendParameter(s.template node<FunctionParameters>(list), s.template node<DestructuringPatternNode>(pattern), s.template nodeOrNull<ExpressionNode>(defaultValue)); }
    ALWAYS_INLINE JSParseNode createClause(JSParseNode expr, JSParseNode statements) { auto& s = state(); return s.add(s.builder().createClause(s.template node<ExpressionNode>(expr), s.template node<SourceElements>(statements))); }
    ALWAYS_INLINE JSParseNode createDefaultClause(JSParseNode statements) { auto& s = state(); return s.add(s.builder().createClause(nullptr, s.template node<SourceElements>(statements))); }
    ALWAYS_INLINE JSParseNode createClauseList(JSParseNode clause) { auto& s = state(); return s.add(s.builder().createClauseList(s.template node<CaseClauseNode>(clause))); }
    ALWAYS_INLINE JSParseNode createClauseList(JSParseNode tail, JSParseNode clause) { auto& s = state(); return s.add(s.builder().createClauseList(s.template node<ClauseListNode>(tail), s.template node<CaseClauseNode>(clause))); }
    ALWAYS_INLINE JSParseNode createFuncDeclStatement(const JSTokenLocation& location, const JSParseFunctionInfo& functionInfo) { auto& s = state(); return s.add(s.builder().createFuncDeclStatement(location, s.functionInfo(functionInfo))); }
    ALWAYS_INLINE JSParseNode createClassDeclStatement(const JSTokenLocation& location, JSParseNode classExpression, const JSTextPosition& classStart, const JSTextPosition& classEnd) { auto& s = state(); return s.add(s.builder().createClassDeclStatement(location, s.template node<ClassExprNode>(classExpression), classStart, classEnd)); }
    ALWAYS_INLINE JSParseNode createBlockStatement(const JSTokenLocation& location, JSParseNode elements, JSParseEnvironment lexicalVariables, JSParseFunctionStack functionStack) { auto& s = state(); return s.add(s.builder().createBlockStatement(location, s.template nodeOrNull<SourceElements>(elements), s.takeEnvironment(lexicalVariables), s.takeFunctionStack(functionStack))); }
    ALWAYS_INLINE JSParseNode createExprStatement(const JSTokenLocation& location, JSParseNode expr, const JSTextPosition& start) { auto& s = state(); return s.add(s.builder().createExprStatement(location, s.template node<ExpressionNode>(expr), start)); }
    ALWAYS_INLINE JSParseNode createIfStatement(const JSTokenLocation& location, JSParseNode condition, JSParseNode trueBlock, JSParseNode falseBlock) { auto& s = state(); return s.add(s.builder().createIfStatement(location, s.template node<ExpressionNode>(condition), s.template node<StatementNode>(trueBlock), s.template nodeOrNull<StatementNode>(falseBlock))); }
    ALWAYS_INLINE JSParseNode createForLoop(const JSTokenLocation& location, JSParseNode initializer, JSParseNode condition, JSParseNode iter, JSParseNode statements, JSParseEnvironment lexicalVariables, bool initializerContainsClosure) { auto& s = state(); return s.add(s.builder().createForLoop(location, s.template nodeOrNull<ExpressionNode>(initializer), s.template nodeOrNull<ExpressionNode>(condition), s.template nodeOrNull<ExpressionNode>(iter), s.template node<StatementNode>(statements), s.takeEnvironment(lexicalVariables), initializerContainsClosure)); }
    ALWAYS_INLINE JSParseNode createForInLoop(const JSTokenLocation& location, JSParseNode lhs, JSParseNode iter, JSParseNode statements, const JSTokenLocation& endLocation, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, JSParseEnvironment lexicalVariables) { auto& s = state(); return s.add(s.builder().createForInLoop(location, s.template node<ExpressionNode>(lhs), s.template node<ExpressionNode>(iter), s.template node<StatementNode>(statements), endLocation, eStart, eDivot, eEnd, s.takeEnvironment(lexicalVariables))); }
    ALWAYS_INLINE JSParseNode createForInLoopWithDestructuringPattern(const JSTokenLocation& location, JSParseNode pattern, JSParseNode iter, JSParseNode statements, const JSTokenLocation& declLocation, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, JSParseEnvironment lexicalVariables) { auto& s = state(); return s.add(s.builder().createForInLoop(location, s.template node<DestructuringPatternNode>(pattern), s.template node<ExpressionNode>(iter), s.template node<StatementNode>(statements), declLocation, eStart, eDivot, eEnd, s.takeEnvironment(lexicalVariables))); }
    ALWAYS_INLINE JSParseNode createForOfLoop(bool isForAwait, const JSTokenLocation& location, JSParseNode lhs, JSParseNode iter, JSParseNode statements, const JSTokenLocation& endLocation, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, JSParseEnvironment lexicalVariables) { auto& s = state(); return s.add(s.builder().createForOfLoop(isForAwait, location, s.template node<ExpressionNode>(lhs), s.template node<ExpressionNode>(iter), s.template node<StatementNode>(statements), endLocation, eStart, eDivot, eEnd, s.takeEnvironment(lexicalVariables))); }
    ALWAYS_INLINE JSParseNode createForOfLoopWithDestructuringPattern(bool isForAwait, const JSTokenLocation& location, JSParseNode pattern, JSParseNode iter, JSParseNode statements, const JSTokenLocation& declLocation, const JSTextPosition& eStart, const JSTextPosition& eDivot, const JSTextPosition& eEnd, JSParseEnvironment lexicalVariables) { auto& s = state(); return s.add(s.builder().createForOfLoop(isForAwait, location, s.template node<DestructuringPatternNode>(pattern), s.template node<ExpressionNode>(iter), s.template node<StatementNode>(statements), declLocation, eStart, eDivot, eEnd, s.takeEnvironment(lexicalVariables))); }
    ALWAYS_INLINE bool isBindingNode(JSParseNode pattern) { auto& s = state(); return s.builder().isBindingNode(s.template node<DestructuringPatternNode>(pattern)); }
    ALWAYS_INLINE bool isLocation(JSParseNode node) { auto& s = state(); return s.builder().isLocation(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool isAssignmentLocation(JSParseNode node) { auto& s = state(); return s.builder().isAssignmentLocation(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool isPrivateLocation(JSParseNode node) { auto& s = state(); return s.builder().isPrivateLocation(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool isObjectOrArrayLiteral(JSParseNode node) { auto& s = state(); return s.builder().isObjectOrArrayLiteral(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool isFunctionCall(JSParseNode node) { auto& s = state(); return s.builder().isFunctionCall(s.template node<ExpressionNode>(node)); }
    ALWAYS_INLINE bool shouldSkipPauseLocation(JSParseNode statement) { auto& s = state(); return s.builder().shouldSkipPauseLocation(s.template nodeOrNull<StatementNode>(statement)); }
    ALWAYS_INLINE JSParseNode createEmptyStatement(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createEmptyStatement(location)); }
    ALWAYS_INLINE JSParseNode createDeclarationStatement(const JSTokenLocation& location, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createDeclarationStatement(location, s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createEmptyVarExpression(const JSTokenLocation& location, JSParseIdentifier identifier) { auto& s = state(); return s.add(s.builder().createEmptyVarExpression(location, s.identifier(identifier))); }
    ALWAYS_INLINE JSParseNode createEmptyLetExpression(const JSTokenLocation& location, JSParseIdentifier identifier) { auto& s = state(); return s.add(s.builder().createEmptyLetExpression(location, s.identifier(identifier))); }
    ALWAYS_INLINE JSParseNode createReturnStatement(const JSTokenLocation& location, JSParseNode expression, const JSTextPosition& start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createReturnStatement(location, s.template nodeOrNull<ExpressionNode>(expression), start, end)); }
    ALWAYS_INLINE JSParseNode createBreakStatement(const JSTokenLocation& location, JSParseIdentifier ident, const JSTextPosition& start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createBreakStatement(location, &s.identifier(ident), start, end)); }
    ALWAYS_INLINE JSParseNode createContinueStatement(const JSTokenLocation& location, JSParseIdentifier ident, const JSTextPosition& start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createContinueStatement(location, &s.identifier(ident), start, end)); }
    ALWAYS_INLINE JSParseNode createTryStatement(const JSTokenLocation& location, JSParseNode tryBlock, JSParseNode catchPattern, JSParseNode catchBlock, JSParseNode finallyBlock, JSParseEnvironment catchEnvironment) { auto& s = state(); RELEASE_ASSERT(catchBlock.index || finallyBlock.index); return s.add(s.builder().createTryStatement(location, s.template node<StatementNode>(tryBlock), s.template nodeOrNull<DestructuringPatternNode>(catchPattern), s.template nodeOrNull<StatementNode>(catchBlock), s.template nodeOrNull<StatementNode>(finallyBlock), s.takeEnvironment(catchEnvironment))); }
    ALWAYS_INLINE JSParseNode createSwitchStatement(const JSTokenLocation& location, JSParseNode expr, JSParseNode firstClauses, JSParseNode defaultClause, JSParseNode secondClauses, JSParseEnvironment lexicalVariables, JSParseFunctionStack functionStack) { auto& s = state(); return s.add(s.builder().createSwitchStatement(location, s.template node<ExpressionNode>(expr), s.template nodeOrNull<ClauseListNode>(firstClauses), s.template nodeOrNull<CaseClauseNode>(defaultClause), s.template nodeOrNull<ClauseListNode>(secondClauses), s.takeEnvironment(lexicalVariables), s.takeFunctionStack(functionStack))); }
    ALWAYS_INLINE JSParseNode createWhileStatement(const JSTokenLocation& location, JSParseNode expr, JSParseNode statement) { auto& s = state(); return s.add(s.builder().createWhileStatement(location, s.template node<ExpressionNode>(expr), s.template node<StatementNode>(statement))); }
    ALWAYS_INLINE JSParseNode createDoWhileStatement(const JSTokenLocation& location, JSParseNode statement, JSParseNode expr) { auto& s = state(); return s.add(s.builder().createDoWhileStatement(location, s.template node<StatementNode>(statement), s.template node<ExpressionNode>(expr))); }
    ALWAYS_INLINE JSParseNode createLabelStatement(const JSTokenLocation& location, JSParseIdentifier ident, JSParseNode statement, const JSTextPosition& start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createLabelStatement(location, &s.identifier(ident), s.template node<StatementNode>(statement), start, end)); }
    ALWAYS_INLINE JSParseNode createWithStatement(const JSTokenLocation& location, JSParseNode expr, JSParseNode statement, unsigned start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createWithStatement(location, s.template node<ExpressionNode>(expr), s.template node<StatementNode>(statement), start, end)); }
    ALWAYS_INLINE JSParseNode createThrowStatement(const JSTokenLocation& location, JSParseNode expr, const JSTextPosition& start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createThrowStatement(location, s.template node<ExpressionNode>(expr), start, end)); }
    ALWAYS_INLINE JSParseNode createDebugger(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createDebugger(location)); }
    ALWAYS_INLINE JSParseNode createModuleName(const JSTokenLocation& location, JSParseIdentifier moduleName) { auto& s = state(); return s.add(s.builder().createModuleName(location, s.identifier(moduleName))); }
    ALWAYS_INLINE JSParseNode createImportSpecifier(const JSTokenLocation& location, JSParseIdentifier importedName, JSParseIdentifier localName) { auto& s = state(); return s.add(s.builder().createImportSpecifier(location, s.identifier(importedName), s.identifier(localName))); }
    ALWAYS_INLINE JSParseNode createImportSpecifierList() { auto& s = state(); return s.add(s.builder().createImportSpecifierList()); }
    ALWAYS_INLINE void appendImportSpecifier(JSParseNode specifierList, JSParseNode specifier) { auto& s = state(); s.builder().appendImportSpecifier(s.template node<ImportSpecifierListNode>(specifierList), s.template node<ImportSpecifierNode>(specifier)); }
    ALWAYS_INLINE JSParseNode createImportAttributesList() { auto& s = state(); return s.add(s.builder().createImportAttributesList()); }
    ALWAYS_INLINE void appendImportAttribute(JSParseNode attributesList, JSParseIdentifier key, JSParseIdentifier value) { auto& s = state(); s.builder().appendImportAttribute(s.template node<ImportAttributesListNode>(attributesList), s.identifier(key), s.identifier(value)); }
    ALWAYS_INLINE JSParseNode createImportDeclaration(const JSTokenLocation& location, ImportDeclarationNode::ImportType type, JSParseNode importSpecifierList, JSParseNode moduleName, JSParseNode importAttributesList) { auto& s = state(); return s.add(s.builder().createImportDeclaration(location, type, s.template node<ImportSpecifierListNode>(importSpecifierList), s.template node<ModuleNameNode>(moduleName), s.template nodeOrNull<ImportAttributesListNode>(importAttributesList))); }
    ALWAYS_INLINE JSParseNode createExportAllDeclaration(const JSTokenLocation& location, JSParseNode moduleName, JSParseNode importAttributesList) { auto& s = state(); return s.add(s.builder().createExportAllDeclaration(location, s.template node<ModuleNameNode>(moduleName), s.template nodeOrNull<ImportAttributesListNode>(importAttributesList))); }
    ALWAYS_INLINE JSParseNode createExportDefaultDeclaration(const JSTokenLocation& location, JSParseNode declaration, JSParseIdentifier localName) { auto& s = state(); return s.add(s.builder().createExportDefaultDeclaration(location, s.template node<StatementNode>(declaration), s.identifier(localName))); }
    ALWAYS_INLINE JSParseNode createExportLocalDeclaration(const JSTokenLocation& location, JSParseNode declaration) { auto& s = state(); return s.add(s.builder().createExportLocalDeclaration(location, s.template node<StatementNode>(declaration))); }
    ALWAYS_INLINE JSParseNode createExportNamedDeclaration(const JSTokenLocation& location, JSParseNode exportSpecifierList, JSParseNode moduleName, JSParseNode importAttributesList) { auto& s = state(); return s.add(s.builder().createExportNamedDeclaration(location, s.template node<ExportSpecifierListNode>(exportSpecifierList), s.template nodeOrNull<ModuleNameNode>(moduleName), s.template nodeOrNull<ImportAttributesListNode>(importAttributesList))); }
    ALWAYS_INLINE JSParseNode createExportSpecifier(const JSTokenLocation& location, JSParseIdentifier localName, JSParseIdentifier exportedName) { auto& s = state(); return s.add(s.builder().createExportSpecifier(location, s.identifier(localName), s.identifier(exportedName))); }
    ALWAYS_INLINE JSParseNode createExportSpecifierList() { auto& s = state(); return s.add(s.builder().createExportSpecifierList()); }
    ALWAYS_INLINE void appendExportSpecifier(JSParseNode specifierList, JSParseNode specifier) { auto& s = state(); s.builder().appendExportSpecifier(s.template node<ExportSpecifierListNode>(specifierList), s.template node<ExportSpecifierNode>(specifier)); }
    ALWAYS_INLINE void appendStatement(JSParseNode elements, JSParseNode statement) { auto& s = state(); s.builder().appendStatement(s.template node<SourceElements>(elements), s.template node<StatementNode>(statement)); }
    ALWAYS_INLINE JSParseNode createCommaExpr(const JSTokenLocation& location, JSParseNode node) { auto& s = state(); return s.add(s.builder().createCommaExpr(location, s.template node<ExpressionNode>(node))); }
    ALWAYS_INLINE JSParseNode appendToCommaExpr(const JSTokenLocation& location, JSParseNode tail, JSParseNode next) { auto& s = state(); return s.add(s.builder().appendToCommaExpr(location, s.template node<ExpressionNode>(tail), s.template node<ExpressionNode>(next))); }
    ALWAYS_INLINE void appendBinaryExpressionInfo(int& operandStackDepth, JSParseNode current, const JSTextPosition& exprStart, const JSTextPosition& lhs, const JSTextPosition& rhs, bool hasAssignments) { auto& s = state(); s.builder().appendBinaryExpressionInfo(operandStackDepth, s.template node<ExpressionNode>(current), exprStart, lhs, rhs, hasAssignments); }
    ALWAYS_INLINE void operatorStackPop(int& operatorStackDepth) { state().builder().operatorStackPop(operatorStackDepth); }
    ALWAYS_INLINE bool operatorStackShouldReduce(int precedence) { return state().builder().operatorStackShouldReduce(precedence); }
    ALWAYS_INLINE JSParseBinaryOperand getFromOperandStack(int i) { auto& s = state(); return s.binaryOperandHandle(s.builder().getFromOperandStack(i)); }
    ALWAYS_INLINE void shrinkOperandStackBy(int& operandStackDepth, int amount) { state().builder().shrinkOperandStackBy(operandStackDepth, amount); }
    ALWAYS_INLINE void appendBinaryOperation(const JSTokenLocation& location, int& operandStackDepth, int& operatorStackDepth, const JSParseBinaryOperand& lhs, const JSParseBinaryOperand& rhs) { auto& s = state(); s.builder().appendBinaryOperation(location, operandStackDepth, operatorStackDepth, s.binaryOperand(lhs), s.binaryOperand(rhs)); }
    ALWAYS_INLINE void operatorStackAppend(int& operatorStackDepth, int op, int precedence) { state().builder().operatorStackAppend(operatorStackDepth, op, precedence); }
    ALWAYS_INLINE JSParseNode popOperandStack(int& depth) { auto& s = state(); return s.add(s.builder().popOperandStack(depth)); }
    ALWAYS_INLINE void appendUnaryToken(int& tokenStackDepth, int type, const JSTextPosition& start) { state().builder().appendUnaryToken(tokenStackDepth, type, start); }
    ALWAYS_INLINE int unaryTokenStackLastType(int& depth) { return state().builder().unaryTokenStackLastType(depth); }
    ALWAYS_INLINE JSTextPosition unaryTokenStackLastStart(int& depth) { return state().builder().unaryTokenStackLastStart(depth); }
    ALWAYS_INLINE void unaryTokenStackRemoveLast(int& tokenStackDepth) { state().builder().unaryTokenStackRemoveLast(tokenStackDepth); }
    ALWAYS_INLINE int unaryTokenStackDepth() { return state().builder().unaryTokenStackDepth(); }
    ALWAYS_INLINE void setUnaryTokenStackDepth(int oldDepth) { state().builder().setUnaryTokenStackDepth(oldDepth); }
    ALWAYS_INLINE void assignmentStackAppend(int& assignmentStackDepth, JSParseNode node, const JSTextPosition& start, const JSTextPosition& divot, int assignmentCount, Operator op) { auto& s = state(); s.builder().assignmentStackAppend(assignmentStackDepth, s.template node<ExpressionNode>(node), start, divot, assignmentCount, op); }
    ALWAYS_INLINE JSParseNode createAssignment(const JSTokenLocation& location, int& assignmentStackDepth, JSParseNode rhs, int initialAssignmentCount, int currentAssignmentCount, const JSTextPosition& lastTokenEnd) { auto& s = state(); return s.add(s.builder().createAssignment(location, assignmentStackDepth, s.template node<ExpressionNode>(rhs), initialAssignmentCount, currentAssignmentCount, lastTokenEnd)); }
    ALWAYS_INLINE bool isUnderscoreProtoSetter(JSParseNode property) { auto& s = state(); return s.builder().isUnderscoreProtoSetter(s.template node<PropertyNode>(property)); }
    ALWAYS_INLINE bool isResolve(JSParseNode expr) { auto& s = state(); return s.builder().isResolve(s.template node<ExpressionNode>(expr)); }
    ALWAYS_INLINE JSParseNode createDestructuringAssignment(const JSTokenLocation& location, JSParseNode pattern, JSParseNode initializer) { auto& s = state(); return s.add(s.builder().createDestructuringAssignment(location, s.template node<DestructuringPatternNode>(pattern), s.template node<ExpressionNode>(initializer))); }
    ALWAYS_INLINE JSParseNode createArrayPattern(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createArrayPattern(location)); }
    ALWAYS_INLINE void appendArrayPatternSkipEntry(JSParseNode node, const JSTokenLocation& location) { auto& s = state(); s.builder().appendArrayPatternSkipEntry(s.template node<ArrayPatternNode>(node), location); }
    ALWAYS_INLINE void appendArrayPatternEntry(JSParseNode node, const JSTokenLocation& location, JSParseNode pattern, JSParseNode defaultValue) { auto& s = state(); s.builder().appendArrayPatternEntry(s.template node<ArrayPatternNode>(node), location, s.template node<DestructuringPatternNode>(pattern), s.template nodeOrNull<ExpressionNode>(defaultValue)); }
    ALWAYS_INLINE void appendArrayPatternRestEntry(JSParseNode node, const JSTokenLocation& location, JSParseNode pattern) { auto& s = state(); s.builder().appendArrayPatternRestEntry(s.template node<ArrayPatternNode>(node), location, s.template node<DestructuringPatternNode>(pattern)); }
    ALWAYS_INLINE void finishArrayPattern(JSParseNode node, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd) { auto& s = state(); s.builder().finishArrayPattern(s.template node<ArrayPatternNode>(node), divotStart, divot, divotEnd); }
    ALWAYS_INLINE JSParseNode createObjectPattern(const JSTokenLocation& location) { auto& s = state(); return s.add(s.builder().createObjectPattern(location)); }
    ALWAYS_INLINE void appendObjectPatternEntry(JSParseNode node, const JSTokenLocation& location, bool wasString, JSParseIdentifier identifier, JSParseNode pattern, JSParseNode defaultValue) { auto& s = state(); s.builder().appendObjectPatternEntry(s.template node<ObjectPatternNode>(node), location, wasString, s.identifier(identifier), s.template node<DestructuringPatternNode>(pattern), s.template nodeOrNull<ExpressionNode>(defaultValue)); }
    ALWAYS_INLINE void appendObjectPatternEntry(JSParseNode node, const JSTokenLocation& location, JSParseNode propertyExpression, JSParseNode pattern, JSParseNode defaultValue) { auto& s = state(); s.builder().appendObjectPatternEntry(s.vm(), s.template node<ObjectPatternNode>(node), location, s.template node<ExpressionNode>(propertyExpression), s.template node<DestructuringPatternNode>(pattern), s.template nodeOrNull<ExpressionNode>(defaultValue)); }
    ALWAYS_INLINE void appendObjectPatternRestEntry(JSParseNode node, const JSTokenLocation& location, JSParseNode pattern) { auto& s = state(); s.builder().appendObjectPatternRestEntry(s.vm(), s.template node<ObjectPatternNode>(node), location, s.template node<DestructuringPatternNode>(pattern)); }
    ALWAYS_INLINE void setContainsObjectRestElement(JSParseNode node, bool containsRestElement) { auto& s = state(); s.builder().setContainsObjectRestElement(s.template node<ObjectPatternNode>(node), containsRestElement); }
    ALWAYS_INLINE void setContainsComputedProperty(JSParseNode node, bool containsComputedProperty) { auto& s = state(); s.builder().setContainsComputedProperty(s.template node<ObjectPatternNode>(node), containsComputedProperty); }
    ALWAYS_INLINE void finishObjectPattern(JSParseNode node, const JSTextPosition& divotStart, const JSTextPosition& divot, const JSTextPosition& divotEnd) { auto& s = state(); s.builder().finishObjectPattern(s.template node<ObjectPatternNode>(node), divotStart, divot, divotEnd); }
    ALWAYS_INLINE JSParseNode createBindingLocation(const JSTokenLocation& location, JSParseIdentifier boundProperty, const JSTextPosition& start, const JSTextPosition& end, AssignmentContext context) { auto& s = state(); return s.add(s.builder().createBindingLocation(location, s.identifier(boundProperty), start, end, context)); }
    ALWAYS_INLINE JSParseNode createRestParameter(JSParseNode pattern, size_t numParametersToSkip) { auto& s = state(); return s.add(s.builder().createRestParameter(s.template node<DestructuringPatternNode>(pattern), numParametersToSkip)); }
    ALWAYS_INLINE JSParseNode createAssignmentElement(JSParseNode assignmentTarget, const JSTextPosition& start, const JSTextPosition& end) { auto& s = state(); return s.add(s.builder().createAssignmentElement(s.template node<ExpressionNode>(assignmentTarget), start, end)); }
    ALWAYS_INLINE void setEndOffset(JSParseNode node, int offset) { auto& s = state(); s.builder().setEndOffset(s.template node<Node>(node), offset); }
    ALWAYS_INLINE int endOffset(JSParseNode node) { auto& s = state(); return s.builder().endOffset(s.template node<Node>(node)); }
    ALWAYS_INLINE void setStartOffset(JSParseNode node, int offset) { auto& s = state(); s.builder().setStartOffset(s.template node<CaseClauseNode>(node), offset); }
    ALWAYS_INLINE void setStartOffsetWithNode(JSParseNode node, int offset) { auto& s = state(); s.builder().setStartOffset(s.template node<Node>(node), offset); }
    ALWAYS_INLINE JSTextPosition breakpointLocation(JSParseNode node) { auto& s = state(); return s.builder().breakpointLocation(s.template node<Node>(node)); }
    ALWAYS_INLINE void propagateArgumentsUse() { state().builder().propagateArgumentsUse(); }
    ALWAYS_INLINE bool hasArgumentsFeature() { return state().builder().hasArgumentsFeature(); }

protected:
    JSParseFacadeBase() = default;

private:
    ALWAYS_INLINE State& state() { return static_cast<State&>(*this); }
};

// The node table's pointer type: a node of any of JSParseNodeTypes, stored through void*.
struct JSParseNodeStorage;

} // namespace JSC

WTF_ALLOW_COMPACT_POINTERS_TO_INCOMPLETE_TYPE(JSC::JSParseNodeStorage);

namespace JSC {

// One slot of the node table: the node's pointer and kind, packed into 8 bytes (one slot per node).
class JSParseNodeSlot {
public:
    JSParseNodeSlot(void* pointer, uint8_t kind)
        : m_tuple(static_cast<JSParseNodeStorage*>(pointer), kind)
    {
    }
    void* pointer() const { return static_cast<void*>(m_tuple.pointer()); }
    uint8_t kind() const { return m_tuple.type(); }

private:
    CompactPointerTuple<JSParseNodeStorage*, uint8_t> m_tuple;
};
static_assert(sizeof(JSParseNodeSlot) == 8);

} // namespace JSC

namespace WTF {
// Moves and zero-fills are plain memory operations, so the table's growth is a realloc or a memcpy.
template<> struct VectorTraits<JSC::JSParseNodeSlot> : SimpleClassVectorTraits { };
} // namespace WTF

namespace JSC {

// The C++ containers of one scope.
struct JSParseScopeStorage {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(JSParseScopeStorage);

    // Set by mutableScope and every other change; pushScope resets only a dirty storage.
    bool dirty { false };
    VariableEnvironment lexicalVariables;
    VariableEnvironment declaredVariables;
    UniquedStringImplPtrSet declaredParameters;
    UniquedStringImplPtrSet variablesBeingHoisted;
    UniquedStringImplPtrSet nonLocalCapturesFromParameterExpressions;
    HashSet<UniquedStringImpl*> closedVariableCandidates;
    HashMap<FunctionMetadataNode*, bool> sloppyModeFunctionHoistingCandidates; // The value: NeedsDuplicateDeclarationCheck::Yes.
    DeclarationStacks::FunctionStack functionDeclarations;
    Vector<UniquedStringImplPtrSet, 6> usedVariables;
    UniquedStringImpl* lastAddedUsedVariable { nullptr };
    std::optional<SourceProviderCacheItemCreationParameters> cacheParameters;

    // A default-constructed environment in place of environment: its map back in inline storage, as a fresh one's,
    // so later iteration order matches a fresh one's.
    static void resetEnvironment(VariableEnvironment& environment)
    {
        std::destroy_at(&environment);
        std::construct_at(&environment);
    }

    // Returns a reused storage to the state of a freshly made one. Each container becomes a default-constructed one
    // (no table, inline storage), so capacity and iteration order match a fresh storage's.
    // A clean storage is exactly a fresh one: no container was touched, and usedVariables holds the one empty set
    // pushScope gave it (every change to usedVariables or lastAddedUsedVariable sets dirty).
    NEVER_INLINE void reset()
    {
        dirty = false;
        resetEnvironment(lexicalVariables);
        resetEnvironment(declaredVariables);
        declaredParameters = UniquedStringImplPtrSet();
        variablesBeingHoisted = UniquedStringImplPtrSet();
        nonLocalCapturesFromParameterExpressions = UniquedStringImplPtrSet();
        closedVariableCandidates.clear();
        sloppyModeFunctionHoistingCandidates.clear();
        functionDeclarations.clear();
        usedVariables.shrink(0);
        lastAddedUsedVariable = nullptr;
        cacheParameters = std::nullopt;
    }
};

// The state of one parse, on parseWithSwift's stack. Swift cannot import it (not copyable or movable), so it sees only the
// JSParseFacade base. Every table load checks its index (Vector's operator[] checks, and the node table checks the
// kind), so a handle that is not one this parse made traps; nothing is removed from the node and identifier tables
// before the parse ends, and a scope's slot is reused only for the next scope pushed at its depth.
class JSParseState final : public JSParseFacade {
    WTF_MAKE_NONCOPYABLE(JSParseState);
    WTF_MAKE_NONMOVABLE(JSParseState);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    JSParseState(VM&, ParserArena&, const SourceCode&, const PrivateNameEnvironment* parentScopePrivateNames, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>* classElementDefinitions, DebuggerParseData*, bool isModule);
    ~JSParseState();

    VM& vm() { return m_vm; }
    ParserArena& arena() { return m_arena; }
    IdentifierArena& identifierArena() { return m_identifierArena; }
    ASTBuilder& builder() { return m_builder; }
    StringBuilder& errorMessage() { return m_errorMessage; }
    ModuleScopeData* moduleScopeData() { return m_moduleScopeData.get(); }
    ModuleScopeData& checkedModuleScopeData()
    {
        RELEASE_ASSERT(m_moduleScopeData);
        return *m_moduleScopeData;
    }
    RefPtr<ModuleScopeData> takeModuleScopeData() { return WTF::move(m_moduleScopeData); }
    DebuggerParseData* debuggerParseData() { return m_debuggerParseData; }
    DebuggerParseData& checkedDebuggerParseData()
    {
        RELEASE_ASSERT(m_debuggerParseData);
        return *m_debuggerParseData;
    }
    const PrivateNameEnvironment* parentScopePrivateNames() { return m_parentScopePrivateNames; }
    unsigned classElementDefinitionCount() { return m_classElementDefinitions ? m_classElementDefinitions->size() : 0; }
    // An empty FixedVector has no storage, so its operator[] would dereference null: check the index here.
    const UnlinkedFunctionExecutable::ClassElementDefinition& classElementDefinition(unsigned i)
    {
        RELEASE_ASSERT(i < classElementDefinitionCount());
        return (*m_classElementDefinitions)[i];
    }
    bool hasFunctionCache() { return !!m_functionCache; }

    // The identifier table.
    JSParseIdentifier addIdentifier(const Identifier& identifier)
    {
        m_identifiers.append(&identifier);
        return { static_cast<uint32_t>(m_identifiers.size() - 1) };
    }
    JSParseIdentifier addIdentifierOrNull(const Identifier* identifier) { return identifier ? addIdentifier(*identifier) : JSParseIdentifier { }; }
    const Identifier& identifier(JSParseIdentifier handle)
    {
        auto* identifier = m_identifiers[handle.index];
        RELEASE_ASSERT(identifier);
        return *identifier;
    }
    const Identifier* identifierOrNull(JSParseIdentifier handle) { return m_identifiers[handle.index]; }
    uintptr_t wellKnownKey(JSParseWellKnownName name) { return m_wellKnownKeys[static_cast<size_t>(name)]; }
    // Parser.h's isStrictModeReservedWord: its nine names, by key.
    bool isStrictModeReservedKey(uintptr_t key)
    {
        return key == wellKnownKey(JSParseWellKnownName::implementsKeyword) || key == wellKnownKey(JSParseWellKnownName::interfaceKeyword)
            || key == wellKnownKey(JSParseWellKnownName::letKeyword) || key == wellKnownKey(JSParseWellKnownName::packageKeyword)
            || key == wellKnownKey(JSParseWellKnownName::privateKeyword) || key == wellKnownKey(JSParseWellKnownName::protectedKeyword)
            || key == wellKnownKey(JSParseWellKnownName::publicKeyword) || key == wellKnownKey(JSParseWellKnownName::staticKeyword)
            || key == wellKnownKey(JSParseWellKnownName::yieldKeyword);
    }
    // The null handle is the null Identifier (a parse whose root has no callee name passes it as the body's name).
    const Identifier& identifierOrNullIdentifier(JSParseIdentifier handle) { return handle.index ? identifier(handle) : vm().propertyNames->nullIdentifier; }

    // The node table: each slot holds a node as the type its forwarder returned it as, which a load converts to the
    // type the next forwarder takes only if that is the same class or a base class of it.
    template<typename T> JSParseNode add(T* node)
    {
        static constexpr uint8_t kind = kindOf<T>();
        // A type outside JSParseNodeTypes shares one kind, which would let two unrelated types load each other's slots.
        static_assert(kind != nullKind + 1, "add<T>: T must be one of JSParseNodeTypes");
        if (!node)
            return { };
        size_t size = m_nodes.size();
        m_nodes.append(NodeSlot { static_cast<void*>(node), kind });
        return { static_cast<uint32_t>(size) };
    }
    // A node parameter ASTBuilder dereferences: the null handle traps (on the slow path, so the hot path is the one
    // kind compare).
    template<typename T> T* node(JSParseNode handle)
    {
        auto& slot = m_nodes[handle.index];
        if (slot.kind() == kindOf<T>()) [[likely]]
            return static_cast<T*>(slot.pointer());
        RELEASE_ASSERT(slot.kind() != nullKind);
        return convertedNode<T>(slot, std::make_index_sequence<std::tuple_size_v<JSParseNodeTypes>>());
    }
    // A node parameter ASTBuilder takes as optional: the null handle is nullptr.
    template<typename T> T* nodeOrNull(JSParseNode handle)
    {
        auto& slot = m_nodes[handle.index];
        if (slot.kind() == kindOf<T>()) [[likely]]
            return static_cast<T*>(slot.pointer());
        if (slot.kind() == nullKind)
            return nullptr;
        return convertedNode<T>(slot, std::make_index_sequence<std::tuple_size_v<JSParseNodeTypes>>());
    }

    // The containers taken for nodes, each consumed once.
    JSParseEnvironment addEnvironment(VariableEnvironment&& environment)
    {
        m_environments.append(makeUnique<VariableEnvironment>(WTF::move(environment)));
        return { static_cast<uint32_t>(m_environments.size() - 1) };
    }
    // The null handle is the empty container of a node that takes none (a function body's block, for one).
    // By value: one forwarder (createClassExpr) takes two environments, which must not share a slot.
    VariableEnvironment takeEnvironment(JSParseEnvironment handle)
    {
        if (!handle.index)
            return { };
        auto& slot = m_environments[handle.index];
        RELEASE_ASSERT(slot);
        return WTF::move(*std::exchange(slot, nullptr));
    }
    JSParseFunctionStack addFunctionStack(DeclarationStacks::FunctionStack&& stack)
    {
        m_functionStacks.append(makeUnique<DeclarationStacks::FunctionStack>(WTF::move(stack)));
        return { static_cast<uint32_t>(m_functionStacks.size() - 1) };
    }
    DeclarationStacks::FunctionStack takeFunctionStack(JSParseFunctionStack handle)
    {
        if (!handle.index)
            return { };
        auto& slot = m_functionStacks[handle.index];
        RELEASE_ASSERT(slot);
        return WTF::move(*std::exchange(slot, nullptr));
    }

    // The structs the Swift passes.
    // A getter or setter has no name (its ParserFunctionInfo name is null), so the name may be null. The
    // offsets reach SourceCode::subExpression and the functions' source lengths: they must be ordered and inside the source.
    ParserFunctionInfo<ASTBuilder> functionInfo(const JSParseFunctionInfo& info)
    {
        RELEASE_ASSERT(info.startOffset <= info.endOffset && info.endOffset <= m_sourceEndOffset);
        return { identifierOrNull(info.name), node<FunctionMetadataNode>(info.body), info.parameterCount, info.functionLength, info.startOffset, info.endOffset };
    }
    ParserClassInfo<ASTBuilder> classInfo(const JSParseClassInfo& info)
    {
        RELEASE_ASSERT(info.startOffset <= info.endOffset && info.endOffset <= m_sourceEndOffset);
        return { &identifier(info.className), info.startOffset, info.endOffset };
    }
    // Whether the property list holds a class element (createPropertyList records it): an object literal's list holds none.
    bool isClassElementList(JSParseNode list) { return m_classElementLists.contains(list.index); }
    ASTBuilder::BinaryOperand binaryOperand(const JSParseBinaryOperand& operand)
    {
        return { node<ExpressionNode>(operand.expression), { operand.start, operand.divot, operand.end, operand.hasAssignment } };
    }
    JSParseBinaryOperand binaryOperandHandle(const ASTBuilder::BinaryOperand& operand) { return { add(operand.first), operand.second.start, operand.second.divot, operand.second.end, operand.second.hasAssignment }; }

    // Scopes.
    JSParseScope pushScope()
    {
        // Slot 0 is the null handle's. The storages live until the parse ends; depth picks the live ones.
        size_t index = m_scopeDepth++;
        if (index == m_scopes.size())
            m_scopes.append(nullptr);
        auto& slot = m_scopes[index];
        if (!slot) [[unlikely]] {
            slot = makeUnique<JSParseScopeStorage>();
            slot->usedVariables.constructAndAppend();
        } else if (slot->dirty) [[unlikely]] {
            slot->reset();
            slot->usedVariables.constructAndAppend();
        }
        return { static_cast<uint32_t>(index) };
    }
    void popScope(JSParseScope);
    // scope()'s check alone, for a caller that needs no storage.
    void checkLiveScope(JSParseScope handle) { scope(handle); }
    // Traps unless the handle is a live scope (1 <= index < m_scopeDepth); the unsigned subtraction makes 0 fail the same compare.
    ALWAYS_INLINE JSParseScopeStorage& scope(JSParseScope handle)
    {
        RELEASE_ASSERT(handle.index - 1 < m_scopeDepth - 1);
        return *m_scopes[handle.index];
    }
    // scope() for a caller that may change the storage: it must not skip the reset of the next push.
    ALWAYS_INLINE JSParseScopeStorage& mutableScope(JSParseScope handle)
    {
        auto& storage = scope(handle);
        storage.dirty = true;
        return storage;
    }
    ALWAYS_INLINE VariableEnvironment& readEnvironment(JSParseScope handle, JSParseEnvironmentKind kind)
    {
        auto& storage = scope(handle);
        return kind == JSParseEnvironmentKind::Lexical ? storage.lexicalVariables : storage.declaredVariables;
    }
    ALWAYS_INLINE VariableEnvironment& environment(JSParseScope handle, JSParseEnvironmentKind kind)
    {
        auto& storage = mutableScope(handle);
        return kind == JSParseEnvironmentKind::Lexical ? storage.lexicalVariables : storage.declaredVariables;
    }
    std::unique_ptr<JSParseScopeStorage> takeRootScope(JSParseScope);
    void setTraits(VariableEnvironmentEntry&, uint16_t traits);
    bool nameSetAdd(JSParseScopeStorage&, JSParseNameSetKind, UniquedStringImpl*);
    bool nameSetContains(JSParseScopeStorage&, JSParseNameSetKind, UniquedStringImpl*);
    unsigned nameSetSize(JSParseScopeStorage&, JSParseNameSetKind);
    void useVariable(JSParseScopeStorage& storage, UniquedStringImpl* impl)
    {
        if (impl == storage.lastAddedUsedVariable)
            return;
        storage.lastAddedUsedVariable = impl;
        storage.usedVariables.last().add(impl);
    }
    bool usedVariablesContains(JSParseScopeStorage&, UniquedStringImpl*);
    void mergeIntoPreviousUsedVariables(JSParseScopeStorage&, unsigned count);
    void markLastUsedVariablesSetAsCaptured(JSParseScopeStorage&, unsigned from);
    void collectFreeVariables(JSParseScope into, JSParseScope nested, bool shouldTrackClosedVariables, bool filterArguments, bool nestedIsFunctionBoundary, bool nestedIsLexicalScope);
    void computeLexicallyCapturedVariablesAndPurgeCandidates(JSParseScopeStorage&);
    void collectNonLocalCapturesFromParameterExpressions(JSParseScopeStorage&);
    void finalizeSloppyModeFunctionHoisting(JSParseScopeStorage&);
    void bubbleSloppyModeFunctionHoistingCandidates(JSParseScope from, JSParseScope into, bool isSimpleCatchParameterScope);
    std::optional<JSParseCachedFunction> findCachedFunction(JSParseScope, int32_t parametersStart);
    void recordCachedFunction(JSParseScope, const JSParseCachedFunction&);
    void addRecordedCachedFunction(int32_t startOffset);
    JSParseIdentifier markExportedBindingsAsExported(JSParseScope);
    JSParseIdentifier undeclaredPrivateName(JSParseScope);
    unsigned usedPrivateNameCount(JSParseScope);
    void markCapturedVariablesAsCaptured(JSParseScope, bool allDeclaredVariablesAreCaptured);
    JSParseIdentifier addIdentifierForUid(UniquedStringImpl* uid);
    void copyParentScopePrivateNames(JSParseScope);
    bool isRegularExpressionCached(JSParseIdentifier pattern, JSParseIdentifier flags);
    uint8_t checkRegularExpressionSyntax(JSParseIdentifier pattern, JSParseIdentifier flags);
    void appendRegularExpressionErrorMessage(uint8_t errorCode);
    JSParseNode createPropertyList(const JSTokenLocation&, JSParseNode property);
    JSParseNode createPropertyList(const JSTokenLocation&, JSParseNode property, JSParseNode tail);

private:
    using NodeSlot = JSParseNodeSlot;
    static constexpr uint8_t nullKind = std::tuple_size_v<JSParseNodeTypes>;
    template<typename T, size_t index = 0> static constexpr uint8_t kindOf()
    {
        if constexpr (index == std::tuple_size_v<JSParseNodeTypes>)
            return nullKind + 1; // Not a kind the table holds: a load of it accepts only subclasses.
        else if constexpr (std::is_same_v<T, std::tuple_element_t<index, JSParseNodeTypes>>)
            return index;
        else
            return kindOf<T, index + 1>();
    }
    template<typename T, size_t... indices> T* convertedNode(const NodeSlot& slot, std::index_sequence<indices...>)
    {
        if (slot.kind() == nullKind)
            return nullptr;
        T* result = nullptr;
        bool converted = ((slot.kind() == indices && convertNode<T, std::tuple_element_t<indices, JSParseNodeTypes>>(slot.pointer(), result)) || ...);
        RELEASE_ASSERT(converted);
        return result;
    }
    template<typename T, typename Stored> static bool convertNode(void* pointer, T*& result)
    {
        if constexpr (std::is_base_of_v<T, Stored>) {
            result = static_cast<Stored*>(pointer);
            return true;
        } else
            return false;
    }

    VM& m_vm;
    ParserArena& m_arena;
    IdentifierArena& m_identifierArena;
    ASTBuilder m_builder;
    Vector<const Identifier*> m_identifiers;
    std::array<uintptr_t, static_cast<size_t>(JSParseWellKnownName::Count)> m_wellKnownKeys { }; // Each one's impl pointer.
    Vector<NodeSlot> m_nodes;
    Vector<std::unique_ptr<JSParseScopeStorage>, 16> m_scopes; // Inline: the parse's block holds the first sixteen.
    size_t m_scopeDepth { 1 }; // The live scopes are m_scopes[1, m_scopeDepth).
    Vector<std::unique_ptr<VariableEnvironment>, 16> m_environments;
    Vector<std::unique_ptr<DeclarationStacks::FunctionStack>, 16> m_functionStacks;
    std::unique_ptr<SourceProviderCacheItem> m_recordedCacheItem;
    RefPtr<SourceProviderCache> m_functionCache;
    RefPtr<ModuleScopeData> m_moduleScopeData;
    DebuggerParseData* m_debuggerParseData;
    const PrivateNameEnvironment* m_parentScopePrivateNames;
    const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>* m_classElementDefinitions;
    StringBuilder m_errorMessage;
    unsigned m_sourceEndOffset { 0 }; // The end of the SourceCode, in the provider's offsets (the offsets JSParseFunctionInfo and JSParseClassInfo carry).
    HashSet<uint32_t> m_classElementLists; // The node handles of the property lists with a class element.
};

static_assert(std::is_empty_v<JSParseFacade>);
static_assert(!std::is_polymorphic_v<JSParseFacade>);
static_assert(!std::is_default_constructible_v<JSParseFacade>);
static_assert(!std::is_copy_constructible_v<JSParseFacade>);
static_assert(!std::is_copy_assignable_v<JSParseFacade>);
static_assert(!std::is_move_assignable_v<JSParseFacade>);
static_assert(std::is_move_constructible_v<JSParseFacade>);
static_assert(!std::is_trivially_destructible_v<JSParseFacade>);

} // namespace JSC
