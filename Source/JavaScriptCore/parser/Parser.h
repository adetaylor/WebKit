/*
 *  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
 *  Copyright (C) 2001 Peter Kelly (pmk@post.com)
 *  Copyright (C) 2003-2024 Apple Inc. All rights reserved.
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

#pragma once

#include "ExecutableInfo.h"
#include "Nodes.h"
#include "ParserError.h"
#include "ParserModes.h"
#include "ParserSwiftTypes.h"
#include "ParserTokens.h"
#include "SourceCode.h"
#include "SourceProvider.h"
#include "VariableEnvironment.h"
#include <optional>
#include <wtf/DataLog.h>
#include <wtf/FixedVector.h>
#include <wtf/Forward.h>

namespace JSC {

struct DebuggerParseData;

extern std::atomic<unsigned> globalParseCount;

// Parses source and returns the ParsedNode (ProgramNode, ModuleProgramNode, EvalNode or FunctionNode), whose nodes its
// ParserArena holds, or sets error.
template<class ParsedNode>
std::unique_ptr<ParsedNode> parseWithSwift(VM&, const SourceCode&, const JSParseModes&, const Identifier* calleeName, const PrivateNameEnvironment*, const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>*, DebuggerParseData*, ParserError&);

template <class ParsedNode>
std::unique_ptr<ParsedNode> parse(
    VM& vm, const SourceCode& source,
    const Identifier& name, ImplementationVisibility implementationVisibility, JSParserBuiltinMode builtinMode,
    LexicallyScopedFeatures lexicallyScopedFeatures, JSParserScriptMode scriptMode, SourceParseMode parseMode, FunctionMode functionMode, SuperBinding superBinding,
    ParserError& error,
    ConstructorKind constructorKind = ConstructorKind::None,
    DerivedContextType derivedContextType = DerivedContextType::None,
    EvalContextType evalContextType = EvalContextType::None,
    const PrivateNameEnvironment* parentScopePrivateNames = nullptr,
    const FixedVector<UnlinkedFunctionExecutable::ClassElementDefinition>* classElementDefinitions = nullptr,
    bool isInsideOrdinaryFunction = false)
{
    JSParseModes modes;
    modes.implementationVisibility = implementationVisibility;
    modes.builtinMode = builtinMode;
    modes.lexicallyScopedFeatures = lexicallyScopedFeatures;
    modes.scriptMode = scriptMode;
    modes.parseMode = parseMode;
    modes.functionMode = functionMode;
    modes.superBinding = superBinding;
    modes.constructorKind = constructorKind;
    modes.derivedContextType = derivedContextType;
    modes.evalContextType = evalContextType;
    modes.isInsideOrdinaryFunction = isInsideOrdinaryFunction;
    auto result = parseWithSwift<ParsedNode>(vm, source, modes, &name, parentScopePrivateNames, classElementDefinitions, nullptr, error);
    if (builtinMode == JSParserBuiltinMode::Builtin && source.provider()->source().is8Bit() && !result) {
        ASSERT(error.isValid());
        if (error.type() != ParserError::StackOverflow)
            dataLogLn("Unexpected error compiling builtin: ", error.message(), " on line ", error.line(), " for function ", name.impl(), ".");
    }
    return result;
}

template <class ParsedNode>
std::unique_ptr<ParsedNode> parseRootNode(
    VM& vm, const SourceCode& source,
    ImplementationVisibility implementationVisibility, JSParserBuiltinMode builtinMode,
    LexicallyScopedFeatures lexicallyScopedFeatures, JSParserScriptMode scriptMode, SourceParseMode parseMode,
    ParserError& error,
    ConstructorKind constructorKindForTopLevelFunctionExpressions = ConstructorKind::None,
    DebuggerParseData* debuggerParseData = nullptr)
{
    static_assert(std::is_same_v<ParsedNode, ProgramNode> || std::is_same_v<ParsedNode, ModuleProgramNode>);
    ASSERT_WITH_MESSAGE(source.provider()->source().is8Bit() || constructorKindForTopLevelFunctionExpressions == ConstructorKind::None, "BuiltinExecutables' special constructors should always use a 8-bit string");

    JSParseModes modes;
    modes.implementationVisibility = implementationVisibility;
    modes.builtinMode = builtinMode;
    modes.lexicallyScopedFeatures = lexicallyScopedFeatures;
    modes.scriptMode = scriptMode;
    modes.parseMode = parseMode;
    modes.constructorKindForTopLevelFunctionExpressions = constructorKindForTopLevelFunctionExpressions;
    return parseWithSwift<ParsedNode>(vm, source, modes, nullptr, nullptr, nullptr, debuggerParseData, error);
}

inline std::unique_ptr<ProgramNode> parseFunctionForFunctionConstructor(VM& vm, const SourceCode& source, LexicallyScopedFeatures lexicallyScopedFeatures, ParserError& error, std::optional<int> functionConstructorParametersEndPosition)
{
    JSParseModes modes;
    modes.lexicallyScopedFeatures = lexicallyScopedFeatures;
    modes.isFunctionConstructor = true;
    modes.functionConstructorParametersEndPosition = functionConstructorParametersEndPosition;
    return parseWithSwift<ProgramNode>(vm, source, modes, nullptr, nullptr, nullptr, nullptr, error);
}

} // namespace JSC
