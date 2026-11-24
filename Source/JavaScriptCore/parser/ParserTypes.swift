//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2024 Apple Inc. All rights reserved.
//  Copyright (C) 2026 Apple Inc. All rights reserved.
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.
//

internal import JSCSwiftBoundary

enum ParsingContext {
    case normal
    case functionConstructor
}

enum ExportType {
    case exported
    case notExported
}

enum FunctionDeclarationType {
    case declaration
    case statement
}

enum BlockType {
    case normal
    case `catch`
    case staticBlock
}

enum VarDeclarationListContext {
    case forLoop
    case `var`
}

enum ImportSpecifierType {
    case namespaceImport
    case namedImport
    case defaultImport
}

enum FunctionDefinitionType {
    case expression
    case declaration
    case method
}

enum SourceElementsMode {
    case checkForStrictMode
    case dontCheckForStrictMode
}

enum FunctionBodyType {
    case arrowFunctionBodyExpression
    case arrowFunctionBodyBlock
    case standardFunctionBodyBlock
}

enum FunctionNameRequirements {
    case none
    case named
    case unnamed
}

enum DestructuringKind {
    case variables
    case `let`
    case `const`
    case catchParameters
    case parameters
    case expressions
}

enum DeclarationType {
    case `var`
    case `let`
    case `const`
    case using
    case awaitUsing
}

enum DeclarationImportType {
    case imported
    case importedNamespace
    case notImported
}

enum DeclarationDefaultContext {
    case standard
    case exportDefault
}

enum ArgumentType {
    case normal
    case spread
}

struct DeclarationResult: OptionSet {
    let rawValue: UInt8

    static let valid: DeclarationResult = []
    static let invalidStrictMode = DeclarationResult(rawValue: 1 << 0)
    static let invalidDuplicateDeclaration = DeclarationResult(rawValue: 1 << 1)
    static let invalidPrivateStaticNonStatic = DeclarationResult(rawValue: 1 << 2)
}

/// What parseVariableDeclarationList reports besides the declaration list.
struct VariableDeclarationListOutput<B: TreeBuilder> {
    var declarations = 0
    var lastPattern = B.DestructuringPattern.null
    var lastInitializer = B.Expression.null
    var identStart = JSC.JSTextPosition()
    var initStart = JSC.JSTextPosition()
    var initEnd = JSC.JSTextPosition()
    var forLoopConstDoesNotHaveInitializer = false
}
