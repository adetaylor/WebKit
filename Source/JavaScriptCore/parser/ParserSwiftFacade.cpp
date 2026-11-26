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

#include "config.h"
#include "Parser.h"

#include "DecimalNumberScanner.h"
#include "JSBigIntSwiftDigits.h"
#include "JSCInlines.h"
#include "ParseHash.h"
#include "ParseInt.h"
#include "ParserSwiftFacadeInlines.h"
#include "RegExpCache.h"
#include "TemporalSwiftBoundary.h"
#include "VariableEnvironmentInlines.h"
#include "YarrFlags.h"
#include "YarrInterpreterSwiftTypes.h"
#include "YarrSyntaxChecker.h"
#include <unicode/uchar.h>
#include <wtf/DataLog.h>
#include <wtf/MonotonicTime.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/unicode/CharacterNames.h>

#include "JSCSwift-Swift.h" // NOLINT(build/include_order)

namespace JSC {

// LexerNumbers.swift repeats this constant; a change here must change it there.
static_assert(maxMantissaDigitsForDecimalNumber == 19);

std::atomic<unsigned> globalParseCount { 0 };

void appendParseErrorCharactersReplacingUnpairedSurrogates(StringBuilder& builder, std::span<const char16_t> characters)
{
    for (size_t i = 0; i < characters.size(); ++i) {
        char16_t character = characters[i];
        if (!U16_IS_SURROGATE(character)) {
            builder.append(character);
            continue;
        }
        if (U16_IS_LEAD(character) && i + 1 < characters.size() && U16_IS_TRAIL(characters[i + 1])) {
            builder.append(character, characters[i + 1]);
            ++i;
            continue;
        }
        builder.append(replacementCharacter);
    }
}

bool isNonLatin1IdentifierStart(uint32_t character)
{
    return u_hasBinaryProperty(character, UCHAR_ID_START);
}

bool isNonLatin1IdentifierPart(uint32_t character)
{
    return u_hasBinaryProperty(character, UCHAR_ID_CONTINUE) || character == 0x200C || character == 0x200D;
}

double parseIntOverflow8(std::span<const uint8_t> characters NOESCAPE, int radix)
{
    return parseIntOverflow(spanReinterpretCast<const Latin1Character>(characters), radix);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(ModuleScopeData);
WTF_MAKE_TZONE_ALLOCATED_IMPL(JSParseScopeStorage);

void JSToken::dump(PrintStream& out) const
{
    out.print(*m_data.cooked);
}

// The longest source whose length sizes the node and identifier tables up front (32 MB and 16 MB reserved).
static constexpr size_t maximumReservedSourceLength = 4 * MB;

// Each trait with the VariableEnvironmentEntry setter that sets its bit; the JSParseState constructor checks (in Debug)
// that the bit the setter sets is the trait's value, which ParserScope.swift reads back from environmentTraits.
using JSParseTraitSetter = std::pair<JSParseVariableTrait, void (VariableEnvironmentEntry::*)()>;
static constexpr JSParseTraitSetter traitSetters[] = {
    { JSParseVariableTrait::Captured, &VariableEnvironmentEntry::setIsCaptured },
    { JSParseVariableTrait::Const, &VariableEnvironmentEntry::setIsConst },
    { JSParseVariableTrait::Var, &VariableEnvironmentEntry::setIsVar },
    { JSParseVariableTrait::Let, &VariableEnvironmentEntry::setIsLet },
    { JSParseVariableTrait::Exported, &VariableEnvironmentEntry::setIsExported },
    { JSParseVariableTrait::Imported, &VariableEnvironmentEntry::setIsImported },
    { JSParseVariableTrait::ImportedNamespace, &VariableEnvironmentEntry::setIsImportedNamespace },
    { JSParseVariableTrait::Function, &VariableEnvironmentEntry::setIsFunction },
    { JSParseVariableTrait::Parameter, &VariableEnvironmentEntry::setIsParameter },
    { JSParseVariableTrait::SloppyModeHoistedFunction, &VariableEnvironmentEntry::setIsSloppyModeHoistedFunction },
    { JSParseVariableTrait::PrivateField, &VariableEnvironmentEntry::setIsPrivateField },
    { JSParseVariableTrait::PrivateMethod, &VariableEnvironmentEntry::setIsPrivateMethod },
    { JSParseVariableTrait::PrivateGetter, &VariableEnvironmentEntry::setIsPrivateGetter },
    { JSParseVariableTrait::PrivateSetter, &VariableEnvironmentEntry::setIsPrivateSetter },
    { JSParseVariableTrait::FunctionDeclaration, &VariableEnvironmentEntry::setIsFunctionDeclaration },
    { JSParseVariableTrait::Using, &VariableEnvironmentEntry::setIsUsing },
};

// The VM's well-known names in JSParseWellKnownName's order, built in place in the member.
static std::array<const Identifier*, static_cast<size_t>(JSParseWellKnownName::Count)> makeWellKnownIdentifiers(VM& vm)
{
    auto& names = *vm.propertyNames;
#define JSC_PARSER_SWIFT_KEYWORD_POINTER(name) &names.name##Keyword,
#define JSC_PARSER_SWIFT_NAME_POINTER(name) &names.name,
    return { {
        JSC_COMMON_IDENTIFIERS_EACH_KEYWORD(JSC_PARSER_SWIFT_KEYWORD_POINTER)
        JSC_PARSER_SWIFT_OTHER_NAMES(JSC_PARSER_SWIFT_NAME_POINTER)
        &names.builtinNames().metaPublicName()
    } };
#undef JSC_PARSER_SWIFT_NAME_POINTER
#undef JSC_PARSER_SWIFT_KEYWORD_POINTER
}

JSParseState::JSParseState(VM& vm, ParserArena& arena, const SourceCode& source, const PrivateNameEnvironment* parentScopePrivateNames, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>* classElementDefinitions, DebuggerParseData* debuggerParseData, bool isModule)
    : m_vm(vm)
    , m_arena(arena)
    , m_identifierArena(arena.identifierArena())
    , m_builder(vm, arena, &source)
    , m_wellKnownIdentifiers(makeWellKnownIdentifiers(vm))
    , m_functionCache(vm.addSourceProviderCache(source.provider()))
    , m_moduleScopeData(isModule ? RefPtr { ModuleScopeData::create() } : nullptr)
    , m_debuggerParseData(debuggerParseData)
    , m_parentScopePrivateNames(parentScopePrivateNames)
    , m_classElementDefinitions(classElementDefinitions)
    , m_sourceEndOffset(static_cast<unsigned>(source.endOffset()))
{
    // One node slot per source character up to maximumReservedSourceLength; above that the tables grow as they fill.
    // The well-known names go before the parse's own.
    size_t reservedLength = std::min<size_t>(source.length(), maximumReservedSourceLength);
    m_nodes.reserveInitialCapacity(std::max<size_t>(1024, reservedLength));
    // One identifier slot per two source characters, on the same bound.
    m_identifiers.reserveInitialCapacity(std::max<size_t>(256, reservedLength / 2));
    // The three tables the parse starts pushing to are sized at the Vector's minimum capacity, so the first append does not grow them.
    m_scopes.reserveInitialCapacity(16);
    m_environments.reserveInitialCapacity(16);
    m_functionStacks.reserveInitialCapacity(16);
    m_identifiers.append(nullptr);
    m_nodes.append({ nullptr, nullKind });
    m_scopes.append(nullptr);
    m_environments.append(nullptr);
    m_functionStacks.append(nullptr);
    // The well-known names are identifier handles 1 to Count.
    m_identifiers.append(std::span<const Identifier* const> { m_wellKnownIdentifiers });
    for (size_t i = 0; i < m_wellKnownIdentifiers.size(); ++i)
        m_wellKnownKeys[i] = std::bit_cast<uintptr_t>(m_wellKnownIdentifiers[i]->impl());
#if ASSERT_ENABLED
    for (auto [trait, setter] : traitSetters) {
        VariableEnvironmentEntry entry;
        (entry.*setter)();
        ASSERT(entry.bits() == static_cast<uint16_t>(trait));
    }
#endif
}

JSParseState::~JSParseState() = default;

void JSParseState::popScope(JSParseScope handle)
{
    RELEASE_ASSERT(handle.index && handle.index == m_scopeDepth - 1);
    auto& storage = scope(handle);
    if (storage.cacheParameters)
        m_recordedCacheItem = SourceProviderCacheItem::create(*storage.cacheParameters);
    --m_scopeDepth;
}

std::unique_ptr<JSParseScopeStorage> JSParseState::takeRootScope(JSParseScope handle)
{
    RELEASE_ASSERT(handle.index);
    checkLiveScope(handle);
    return WTF::move(m_scopes[handle.index]);
}

void JSParseState::setTraits(VariableEnvironmentEntry& entry, uint16_t traits)
{
    // Unrolled, so that each setter is a direct call that inlines to one conditional OR.
#pragma clang loop unroll(full)
    for (auto [trait, setter] : traitSetters) {
        if (traits & static_cast<uint16_t>(trait))
            (entry.*setter)();
    }
    ASSERT((entry.bits() & traits) == traits);
}

bool JSParseState::nameSetAdd(JSParseScopeStorage& storage, JSParseNameSetKind kind, UniquedStringImpl* impl)
{
    switch (kind) {
    case JSParseNameSetKind::DeclaredParameters: return storage.declaredParameters.add(impl).isNewEntry;
    case JSParseNameSetKind::VariablesBeingHoisted: return storage.variablesBeingHoisted.add(impl).isNewEntry;
    case JSParseNameSetKind::ClosedVariableCandidates: return storage.closedVariableCandidates.add(impl).isNewEntry;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

bool JSParseState::nameSetContains(JSParseScopeStorage& storage, JSParseNameSetKind kind, UniquedStringImpl* impl)
{
    switch (kind) {
    case JSParseNameSetKind::DeclaredParameters: return storage.declaredParameters.contains(impl);
    case JSParseNameSetKind::VariablesBeingHoisted: return storage.variablesBeingHoisted.contains(impl);
    case JSParseNameSetKind::ClosedVariableCandidates: return storage.closedVariableCandidates.contains(impl);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

unsigned JSParseState::nameSetSize(JSParseScopeStorage& storage, JSParseNameSetKind kind)
{
    switch (kind) {
    case JSParseNameSetKind::DeclaredParameters: return storage.declaredParameters.size();
    case JSParseNameSetKind::VariablesBeingHoisted: return storage.variablesBeingHoisted.size();
    case JSParseNameSetKind::ClosedVariableCandidates: return storage.closedVariableCandidates.size();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

bool JSParseState::usedVariablesContains(JSParseScopeStorage& storage, UniquedStringImpl* impl)
{
    for (auto& set : storage.usedVariables) {
        if (set.contains(impl))
            return true;
    }
    return false;
}

void JSParseState::mergeIntoPreviousUsedVariables(JSParseScopeStorage& storage, unsigned count)
{
    RELEASE_ASSERT(count);
    if (storage.usedVariables.size() <= count)
        return;
    auto& destinationSet = storage.usedVariables[count - 1];
    for (size_t index = count; index < storage.usedVariables.size(); ++index) {
        for (auto* impl : storage.usedVariables[index])
            destinationSet.add(impl);
    }
    storage.usedVariables.shrink(count);
    storage.lastAddedUsedVariable = nullptr;
}

void JSParseState::markLastUsedVariablesSetAsCaptured(JSParseScopeStorage& storage, unsigned from)
{
    for (size_t index = from; index < storage.usedVariables.size(); ++index) {
        for (auto* impl : storage.usedVariables[index])
            storage.closedVariableCandidates.add(impl);
    }
}

void JSParseState::collectFreeVariables(JSParseScope intoHandle, JSParseScope nestedHandle, bool shouldTrackClosedVariables, bool filterArguments, bool nestedIsFunctionBoundary, bool nestedIsLexicalScope)
{
    auto& into = mutableScope(intoHandle);
    auto& nested = scope(nestedHandle);
    auto& destinationSet = into.usedVariables.last();
    auto* argumentsOrNull = filterArguments ? m_vm.propertyNames->arguments.impl() : nullptr;
    bool doTrackClosedVariables = shouldTrackClosedVariables && (nestedIsFunctionBoundary || !nestedIsLexicalScope);
    auto propagate = [&](UniquedStringImpl* impl) {
        if (impl == argumentsOrNull)
            return;
        destinationSet.add(impl);
        if (doTrackClosedVariables)
            into.closedVariableCandidates.add(impl);
    };
    if (nested.cacheParameters) {
        auto& parameters = *nested.cacheParameters;
        for (auto* impl : parameters.freeVariables())
            propagate(impl);
    } else {
        for (auto& set : nested.usedVariables) {
            for (auto* impl : set) {
                if (!nested.declaredVariables.contains(impl) && !nested.lexicalVariables.contains(impl))
                    propagate(impl);
            }
        }
    }
    if (shouldTrackClosedVariables && !nestedIsFunctionBoundary && nested.closedVariableCandidates.size())
        into.closedVariableCandidates.addAll(nested.closedVariableCandidates);
}

void JSParseState::computeLexicallyCapturedVariablesAndPurgeCandidates(JSParseScopeStorage& storage)
{
    if (!storage.lexicalVariables.size() || !storage.closedVariableCandidates.size())
        return;
    for (auto* impl : storage.closedVariableCandidates)
        storage.lexicalVariables.markVariableAsCapturedIfDefined(impl);
    storage.closedVariableCandidates.removeIf([&](UniquedStringImpl* impl) {
        return storage.lexicalVariables.contains(impl);
    });
}

void JSParseState::collectNonLocalCapturesFromParameterExpressions(JSParseScopeStorage& storage)
{
    for (auto& set : storage.usedVariables) {
        for (auto* impl : set) {
            if (!storage.declaredParameters.contains(impl))
                storage.nonLocalCapturesFromParameterExpressions.add(impl);
        }
    }
}

void JSParseState::finalizeSloppyModeFunctionHoisting(JSParseScopeStorage& storage)
{
    for (auto& iterator : storage.sloppyModeFunctionHoistingCandidates) {
        FunctionMetadataNode* metadata = iterator.key;
        auto* function = metadata->ident().impl();
        if (storage.lexicalVariables.contains(function))
            continue;
        auto addResult = storage.declaredVariables.add(function);
        if (addResult.isNewEntry)
            addResult.iterator->value.setIsSloppyModeHoistedFunction();
        else if (addResult.iterator->value.isParameter())
            continue;
        addResult.iterator->value.setIsVar();
        metadata->setIsSloppyModeHoistedFunction();
    }
}

void JSParseState::bubbleSloppyModeFunctionHoistingCandidates(JSParseScope fromHandle, JSParseScope intoHandle, bool isSimpleCatchParameterScope)
{
    auto& from = scope(fromHandle);
    auto& into = mutableScope(intoHandle);
    for (auto& iterator : from.sloppyModeFunctionHoistingCandidates) {
        FunctionMetadataNode* metadata = iterator.key;
        if (!iterator.value || !from.lexicalVariables.contains(metadata->ident().impl()) || isSimpleCatchParameterScope)
            into.sloppyModeFunctionHoistingCandidates.set(metadata, true);
    }
}

std::optional<JSParseCachedFunction> JSParseState::findCachedFunction(JSParseScope handle, int32_t parametersStart)
{
    const SourceProviderCacheItem* item = m_functionCache ? m_functionCache->get(parametersStart) : nullptr;
    if (!item)
        return std::nullopt;
    auto usedVariables = item->usedVariables();
    if (!usedVariables.empty()) {
        auto& destinationSet = mutableScope(handle).usedVariables.last();
        for (auto& variable : usedVariables)
            destinationSet.add(variable.get());
    } else
        checkLiveScope(handle);
    JSParseCachedFunction result;
    result.needsFullActivation = item->needsFullActivation;
    result.usesEval = item->usesEval;
    result.usesImportMeta = item->usesImportMeta;
    result.needsSuperBinding = item->needsSuperBinding;
    result.isBodyArrowExpression = item->isBodyArrowExpression;
    result.lastTokenStartOffset = item->lastTokenStartOffset;
    result.lastTokenEndOffset = item->lastTokenEndOffset;
    result.endFunctionOffset = item->endFunctionOffset;
    result.parameterCount = item->parameterCount;
    result.tokenType = item->endFunctionToken().m_type;
    result.innerArrowFunctionFeatures = static_cast<InnerArrowFunctionCodeFeatures>(item->innerArrowFunctionFeatures);
    result.lexicallyScopedFeatures = item->lexicallyScopedFeatures();
    result.constructorKind = static_cast<ConstructorKind>(item->constructorKind);
    result.expectedSuperBinding = static_cast<SuperBinding>(item->expectedSuperBinding);
    result.implementationVisibility = static_cast<ImplementationVisibility>(item->implementationVisibility);
    return result;
}

void JSParseState::recordCachedFunction(JSParseScope handle, const JSParseCachedFunction& record)
{
    auto& storage = mutableScope(handle);
    // In place, in the storage: no allocation for the parameters object, and the used-variable list is sized once.
    auto& parameters = storage.cacheParameters.emplace();
    size_t usedCount = storage.nonLocalCapturesFromParameterExpressions.size();
    for (auto& set : storage.usedVariables)
        usedCount += set.size();
    parameters.usedVariables.reserveInitialCapacity(usedCount);
    parameters.endFunctionOffset = record.endFunctionOffset;
    parameters.lastTokenStartOffset = record.lastTokenStartOffset;
    parameters.lastTokenEndOffset = record.lastTokenEndOffset;
    parameters.usesEval = record.usesEval;
    parameters.usesImportMeta = record.usesImportMeta;
    parameters.needsFullActivation = record.needsFullActivation;
    parameters.needsSuperBinding = record.needsSuperBinding;
    parameters.isBodyArrowExpression = record.isBodyArrowExpression;
    parameters.parameterCount = record.parameterCount;
    parameters.tokenType = record.tokenType;
    parameters.innerArrowFunctionFeatures = record.innerArrowFunctionFeatures;
    parameters.lexicallyScopedFeatures = record.lexicallyScopedFeatures;
    parameters.constructorKind = record.constructorKind;
    parameters.expectedSuperBinding = record.expectedSuperBinding;
    parameters.implementationVisibility = record.implementationVisibility;
    for (auto& set : storage.usedVariables) {
        for (auto* impl : set) {
            if (!storage.declaredVariables.contains(impl) && !storage.lexicalVariables.contains(impl))
                parameters.usedVariables.append(impl);
        }
    }
    parameters.freeVariableCount = parameters.usedVariables.size();
    for (auto* impl : storage.nonLocalCapturesFromParameterExpressions)
        parameters.usedVariables.append(impl);
}

void JSParseState::addRecordedCachedFunction(int32_t startOffset)
{
    RELEASE_ASSERT(m_recordedCacheItem && m_functionCache);
    m_functionCache->add(startOffset, WTF::move(m_recordedCacheItem));
}

JSParseIdentifier JSParseState::markExportedBindingsAsExported(JSParseScope handle)
{
    auto& storage = mutableScope(handle);
    for (auto& entry : checkedModuleScopeData().exportedBindings()) {
        auto* uid = entry.key.get();
        auto declared = storage.declaredVariables.find(uid);
        if (declared != storage.declaredVariables.end() && declared->value.isVar()) {
            storage.declaredVariables.markVariableAsExported(uid);
            continue;
        }
        if (storage.lexicalVariables.contains(uid)) {
            storage.lexicalVariables.markVariableAsExported(uid);
            continue;
        }
        return addIdentifierForUid(uid);
    }
    return { };
}

JSParseIdentifier JSParseState::addIdentifierForUid(UniquedStringImpl* uid)
{
    if (uid->is8Bit())
        return addIdentifier(identifierArena().makeIdentifier(m_vm, uid->span8()));
    return addIdentifier(identifierArena().makeIdentifier(m_vm, uid->span16()));
}

static ALWAYS_INLINE bool isParserPrivateFieldName(UniquedStringImpl* uid)
{
    return uid->length() && uid->at(0) == '#';
}

JSParseIdentifier JSParseState::undeclaredPrivateName(JSParseScope handle)
{
    auto& storage = scope(handle);
    for (auto& set : storage.usedVariables) {
        for (auto* impl : set) {
            if (!isParserPrivateFieldName(impl))
                continue;
            if (m_parentScopePrivateNames && m_parentScopePrivateNames->contains(impl))
                continue;
            if (storage.lexicalVariables.contains(impl))
                continue;
            return addIdentifierForUid(impl);
        }
    }
    return { };
}

unsigned JSParseState::usedPrivateNameCount(JSParseScope handle)
{
    UniquedStringImplPtrSet usedPrivateNames;
    for (auto& set : scope(handle).usedVariables) {
        for (auto* impl : set) {
            if (isParserPrivateFieldName(impl))
                usedPrivateNames.add(impl);
        }
    }
    return usedPrivateNames.size();
}

void JSParseState::markCapturedVariablesAsCaptured(JSParseScope handle, bool allDeclaredVariablesAreCaptured)
{
    auto& storage = mutableScope(handle);
    IdentifierSet capturedVariables;
    if (allDeclaredVariablesAreCaptured) {
        for (auto& entry : storage.declaredVariables)
            capturedVariables.add(entry.key);
    } else {
        for (auto* impl : storage.closedVariableCandidates) {
            // We refer to declaredVariables here directly instead of a hasDeclaredVariable because we want to mark the callee as captured.
            if (storage.declaredVariables.contains(impl))
                capturedVariables.add(impl);
        }
    }
    for (auto& entry : capturedVariables)
        storage.declaredVariables.markVariableAsCaptured(entry.get());
}

JSParseNode JSParseState::createPropertyList(const JSTokenLocation& location, JSParseNode property)
{
    auto* propertyNode = node<PropertyNode>(property);
    auto result = add(builder().createPropertyList(location, propertyNode));
    if (propertyNode->isClassProperty())
        m_classElementLists.add(result.index);
    return result;
}

JSParseNode JSParseState::createPropertyList(const JSTokenLocation& location, JSParseNode property, JSParseNode tail)
{
    auto* propertyNode = node<PropertyNode>(property);
    auto result = add(builder().createPropertyList(location, propertyNode, node<PropertyListNode>(tail)));
    if (propertyNode->isClassProperty() || isClassElementList(tail))
        m_classElementLists.add(result.index);
    return result;
}

void JSParseState::copyParentScopePrivateNames(JSParseScope handle)
{
    if (!m_parentScopePrivateNames)
        return;
    mutableScope(handle).lexicalVariables.addPrivateNamesFrom(m_parentScopePrivateNames);
}

bool JSParseState::isRegularExpressionCached(JSParseIdentifier pattern, JSParseIdentifier flags)
{
    auto parsedFlags = Yarr::parseFlags(identifier(flags).string());
    return parsedFlags && m_vm.regExpCache()->lookup(m_vm, identifier(pattern).string(), *parsedFlags);
}

uint8_t JSParseState::checkRegularExpressionSyntax(JSParseIdentifier pattern, JSParseIdentifier flags)
{
    return static_cast<uint8_t>(Yarr::checkSyntax(identifier(pattern).string(), identifier(flags).string()));
}

void JSParseState::appendRegularExpressionErrorMessage(uint8_t errorCode)
{
    m_errorMessage.append(Yarr::errorMessage(static_cast<Yarr::ErrorCode>(errorCode)));
}

template<class ParsedNode> static constexpr JSParseRootKind swiftParseRootKind()
{
    if constexpr (std::is_same_v<ParsedNode, ProgramNode>)
        return JSParseRootKind::Program;
    else if constexpr (std::is_same_v<ParsedNode, ModuleProgramNode>)
        return JSParseRootKind::ModuleProgram;
    else if constexpr (std::is_same_v<ParsedNode, EvalNode>)
        return JSParseRootKind::Eval;
    else {
        static_assert(std::is_same_v<ParsedNode, FunctionNode>);
        return JSParseRootKind::Function;
    }
}

static String swiftParseDirective(StringView characters, const std::optional<JSParseExtent>& extent)
{
    if (!extent)
        return String();
    return characters.substring(extent->start, extent->length).toString();
}

// Runs the Swift parser over the source and makes the ParsedNode, or sets error.
template<class ParsedNode>
static std::unique_ptr<ParsedNode> parseWithSwiftWithoutTiming(VM& vm, const SourceCode& source, JSParseModes modes, const Identifier* calleeName, const PrivateNameEnvironment* parentScopePrivateNames, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>* classElementDefinitions, DebuggerParseData* debuggerParseData, ParserError& error)
{
    StringView characters = source.provider()->source();
    ParserArena arena;
    JSParseState state(vm, arena, source, parentScopePrivateNames, classElementDefinitions, debuggerParseData, isModuleParseMode(modes.parseMode));

    modes.startOffset = source.startOffset();
    modes.endOffset = source.endOffset();
    modes.calleeName = calleeName && !calleeName->isNull() ? state.addIdentifier(*calleeName) : JSParseIdentifier { };
    modes.rootKind = swiftParseRootKind<ParsedNode>();
    modes.hasParentScopePrivateNames = !!parentScopePrivateNames;
    modes.useSourceProviderCache = Options::useSourceProviderCache();
    modes.exposePrivateIdentifiers = Options::exposePrivateIdentifiers();
    modes.useExplicitResourceManagement = Options::useExplicitResourceManagement();
    modes.useImportDefer = Options::useImportDefer();

    JSParseResult result = characters.is8Bit()
        ? JSCSwift::jscParse8(spanReinterpretCast<const uint8_t>(characters.span8()), modes, state)
        : JSCSwift::jscParse16(characters.span16(), modes, state);

    if (result.outcome == JSParseOutcome::Succeeded) {
        auto rootScope = state.takeRootScope(result.rootScope);
        JSTokenLocation endLocation;
        endLocation.startOffset = result.endOffset;
        auto node = makeUnique<ParsedNode>(arena,
            result.startLocation,
            endLocation,
            state.template node<SourceElements>(result.sourceElements),
            WTF::move(rootScope->declaredVariables),
            WTF::move(rootScope->functionDeclarations),
            WTF::move(rootScope->lexicalVariables),
            state.template nodeOrNull<FunctionParameters>(result.parameters),
            source,
            result.features,
            result.lexicallyScopedFeatures,
            result.innerArrowFunctionFeatures,
            state.takeModuleScopeData());
        node->setStartOffset(result.endOffset);
        node->setEndOffset(result.endOffset);
        node->setUsedPrivateNameCount(result.usedPrivateNameCount);
        if (!isFunctionParseMode(modes.parseMode)) {
            source.provider()->setSourceURLDirective(swiftParseDirective(characters, result.sourceURLDirective));
            source.provider()->setSourceMappingURLDirective(swiftParseDirective(characters, result.sourceMappingURLDirective));
        }
        return node;
    }

    JSToken token;
    token.m_type = result.tokenType;
    token.m_startPosition = result.tokenStartPosition;
    token.m_endPosition = result.tokenEndPosition;

    if (result.outcome == JSParseOutcome::StackOverflow) {
        error = ParserError(ParserError::StackOverflow, ParserError::SyntaxErrorNone, token);
        return nullptr;
    }

    int errorLine = static_cast<int>(source.provider()->documentLineColumnForOffset(result.endOffset).line);
    String errorMessage = state.errorMessage().isEmpty() ? String() : state.errorMessage().toString();
    ParserError::SyntaxErrorType errorType = ParserError::SyntaxErrorIrrecoverable;
    if (token.m_type == EOFTOK)
        errorType = ParserError::SyntaxErrorRecoverable;
    else if (token.m_type & UnterminatedCanBeErrorTokenFlag) {
        // Treat multiline capable unterminated literals as recoverable.
        if (token.m_type == UNTERMINATED_MULTILINE_COMMENT_ERRORTOK || token.m_type == UNTERMINATED_TEMPLATE_LITERAL_ERRORTOK)
            errorType = ParserError::SyntaxErrorRecoverable;
        else
            errorType = ParserError::SyntaxErrorUnterminatedLiteral;
    }
    error = ParserError(std::is_same_v<ParsedNode, EvalNode> ? ParserError::EvalError : ParserError::SyntaxError, errorType, token, errorMessage, errorLine);
    return nullptr;
}

template<class ParsedNode>
std::unique_ptr<ParsedNode> parseWithSwift(VM& vm, const SourceCode& source, const JSParseModes& modes, const Identifier* calleeName, const PrivateNameEnvironment* parentScopePrivateNames, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>* classElementDefinitions, DebuggerParseData* debuggerParseData, ParserError& error)
{
    ASSERT(!source.provider()->source().isNull());

    MonotonicTime before;
    if (Options::reportParseTimes()) [[unlikely]]
        before = MonotonicTime::now();

    auto result = parseWithSwiftWithoutTiming<ParsedNode>(vm, source, modes, calleeName, parentScopePrivateNames, classElementDefinitions, debuggerParseData, error);

    if (Options::countParseTimes()) [[unlikely]]
        globalParseCount++;

    if (Options::reportParseTimes()) [[unlikely]] {
        MonotonicTime after = MonotonicTime::now();
        ParseHash hash(source);
        dataLogLn(result ? "Parsed #" : "Failed to parse #", hash.hashForCall(), "/#", hash.hashForConstruct(), " in ", (after - before).milliseconds(), " ms.");
    }

    return result;
}

template std::unique_ptr<ProgramNode> parseWithSwift<ProgramNode>(VM&, const SourceCode&, const JSParseModes&, const Identifier*, const PrivateNameEnvironment*, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>*, DebuggerParseData*, ParserError&);
template std::unique_ptr<ModuleProgramNode> parseWithSwift<ModuleProgramNode>(VM&, const SourceCode&, const JSParseModes&, const Identifier*, const PrivateNameEnvironment*, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>*, DebuggerParseData*, ParserError&);
template std::unique_ptr<EvalNode> parseWithSwift<EvalNode>(VM&, const SourceCode&, const JSParseModes&, const Identifier*, const PrivateNameEnvironment*, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>*, DebuggerParseData*, ParserError&);
template std::unique_ptr<FunctionNode> parseWithSwift<FunctionNode>(VM&, const SourceCode&, const JSParseModes&, const Identifier*, const PrivateNameEnvironment*, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>*, DebuggerParseData*, ParserError&);

} // namespace JSC
