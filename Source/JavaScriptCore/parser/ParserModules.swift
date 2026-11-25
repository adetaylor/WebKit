//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2023 Apple Inc. All rights reserved.
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

/// What the specifiers of an export clause name: their local and exported names, whether a local name is a keyword and
/// whether one is a module export name string.
private struct ExportClauseNames {
    var localNames: [(local: JSC.JSParseIdentifier, exported: JSC.JSParseIdentifier)] = []
    var hasKeyword = false
    var hasModuleExportName = false
}

extension Parser {
    mutating func parseModuleName<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.ModuleName {
        // ModuleName (ModuleSpecifier in the spec) represents the module name imported by the script.
        // http://www.ecma-international.org/ecma-262/6.0/#sec-imports
        // http://www.ecma-international.org/ecma-262/6.0/#sec-exports
        let specifierLocation = tokenLocation
        if !match(.string) {
            return fail("Imported modules names must be string literals")
        }
        let moduleName = token.data.ident
        next([], &facade)
        return context.createModuleName(&facade, specifierLocation, moduleName)
    }

    mutating func parseImportClauseItem<B: TreeBuilder>(
        _ context: inout B,
        _ specifierType: ImportSpecifierType,
        _ facade: inout JSC.JSParseFacade
    ) -> B.ImportSpecifier {
        // Produced node is the item of the ImportClause.
        // That is the ImportSpecifier, ImportedDefaultBinding or NameSpaceImport.
        // http://www.ecma-international.org/ecma-262/6.0/#sec-imports
        let specifierLocation = tokenLocation
        let localNameToken: Token
        let importedName: JSC.JSParseIdentifier

        switch specifierType {
        case .namespaceImport:
            // NameSpaceImport :
            // * as ImportedBinding
            // e.g.
            //     * as namespace
            assert(match(.times))
            importedName = facade.wellKnownIdentifier(.starNamespacePrivateName)
            next([], &facade)

            if !matchContextualKeyword(.as, &facade) {
                return fail("Expected 'as' before imported binding name")
            }
            next([], &facade)

            if !matchSpecIdentifier(&facade) {
                return fail("Expected a variable name for the import declaration")
            }
            localNameToken = token
            next([], &facade)

        case .namedImport:
            // ImportSpecifier :
            // ImportedBinding
            // IdentifierName as ImportedBinding
            // ModuleExportName as ImportedBinding
            // e.g.
            //     A
            //     A as B
            assert(matchIdentifierOrKeyword() || match(.string))
            let isModuleExportName = match(.string)
            let importedNameToken = token
            importedName = importedNameToken.data.ident
            if isModuleExportName && facade.identifierHasUnpairedSurrogate(importedName) {
                return fail("Expected a well-formed-unicode string for the module export name")
            }
            next([], &facade)

            let useAs = matchContextualKeyword(.as, &facade)
            if isModuleExportName && !useAs {
                return fail("Expected 'as' after the module export name string")
            }
            if useAs {
                next([], &facade)
                if !matchSpecIdentifier(&facade) {
                    return fail("Expected a variable name for the import declaration")
                }
                localNameToken = token
                next([], &facade)
            } else {
                localNameToken = importedNameToken
            }

        case .defaultImport:
            // ImportedDefaultBinding :
            // ImportedBinding
            assert(matchSpecIdentifier(&facade))
            localNameToken = token
            importedName = facade.wellKnownIdentifier(.defaultKeyword)
            next([], &facade)
        }

        if localNameToken.type == .awaitKeyword {
            return semanticFail("Cannot use 'await' as an imported binding name")
        }
        if localNameToken.type.isKeyword {
            return semanticFail("Cannot use keyword as imported binding name")
        }
        let localName = localNameToken.data.ident
        let declarationResult = declareVariable(
            localName,
            .const,
            specifierType == .namespaceImport ? .importedNamespace : .imported,
            &facade
        )
        if !declarationResult.isEmpty {
            if strictMode && declarationResult.contains(.invalidStrictMode) {
                return semanticFail(
                    ErrorMessage(.text("Cannot declare an imported binding named "), .identifier(localName), .text(" in strict mode"))
                )
            }
            if declarationResult.contains(.invalidDuplicateDeclaration) {
                return semanticFail(
                    ErrorMessage(.text("Cannot declare an imported binding name twice: '"), .identifier(localName), .text("'"))
                )
            }
        }

        return context.createImportSpecifier(&facade, specifierLocation, importedName, localName)
    }

    mutating func parseImportAttributes<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.ImportAttributesList {
        var keys = Set<UInt>()
        let attributesList = context.createImportAttributesList(&facade)
        if !consumeOrFail(.openBrace, "Expected opening '{' at the start of import attribute", &facade) {
            return .null
        }
        while !match(.closeBrace) {
            if !(matchIdentifierOrKeyword() || match(.string)) {
                return fail("Expected an attribute key")
            }
            let key = token.data.ident
            if !keys.insert(UInt(facade.identifierKey(key))).inserted {
                return fail(ErrorMessage(.text("A duplicate key for import attributes '"), .identifier(key), .text("'")))
            }
            next([], &facade)
            if !consumeOrFail(.colon, "Expected ':' after attribute key", &facade) {
                return .null
            }
            if !match(.string) {
                return fail("Expected an attribute value")
            }
            let value = token.data.ident
            next([], &facade)
            context.appendImportAttribute(&facade, attributesList, key, value)
            if !consume(.comma, [], &facade) {
                break
            }
        }
        if !handleProductionOrFail(.closeBrace, "}", "end", "an import attribute", &facade) {
            return .null
        }
        return attributesList
    }

    /// An optional `with { ... }` clause: `.null` when there is none, nil when it does not parse.
    mutating func parseOptionalWithClause<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> B.ImportAttributesList? {
        if !match(.withKeyword) {
            return .null
        }
        next([], &facade)
        let attributesList = parseImportAttributes(&context, &facade)
        return attributesList.isNull ? nil : attributesList
    }

    mutating func parseImportDeclaration<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        // http://www.ecma-international.org/ecma-262/6.0/#sec-imports
        let savedStatementDepth = statementDepth
        defer { statementDepth = savedStatementDepth }
        statementDepth &+= 1
        assert(match(.importKeyword))
        let importLocation = tokenLocation
        next([], &facade)

        let specifierList = context.createImportSpecifierList(&facade)
        var type = JSC.ImportDeclarationNode.ImportType.Normal

        if match(.string) {
            // import ModuleSpecifier ;
            // import ModuleSpecifier WithClause ;
            let moduleName = parseModuleName(&context, &facade)
            if moduleName.isNull {
                return fail("Cannot parse the module name")
            }

            guard let attributesList = parseOptionalWithClause(&context, &facade) else {
                return fail("Unable to parse import attributes")
            }

            if !autoSemiColon(&facade) {
                return fail("Expected a ';' following a targeted import declaration")
            }
            return context.createImportDeclaration(&facade, importLocation, type, specifierList, moduleName, attributesList)
        }

        var isFinishedParsingImport = false
        if modes.useImportDefer && matchContextualKeyword(.deferKeyword, &facade) {
            let deferSavePoint = createSavePoint(&context, &facade)
            next([], &facade)
            if match(.times) {
                // import defer NameSpaceImport FromClause ;
                type = .Deferred
            } else {
                // import defer FromClause ;
                restoreSavePoint(&context, deferSavePoint, &facade)
            }
        }

        if matchSpecIdentifier(&facade) && type != .Deferred {
            // ImportedDefaultBinding :
            // ImportedBinding
            let specifier = parseImportClauseItem(&context, .defaultImport, &facade)
            if specifier.isNull {
                return fail("Cannot parse the default import")
            }
            context.appendImportSpecifier(&facade, specifierList, specifier)
            if match(.comma) {
                next([], &facade)
            } else {
                isFinishedParsingImport = true
            }
        }

        if !isFinishedParsingImport {
            if match(.times) {
                // import NameSpaceImport FromClause ;
                let specifier = parseImportClauseItem(&context, .namespaceImport, &facade)
                if specifier.isNull {
                    return fail("Cannot parse the namespace import")
                }
                context.appendImportSpecifier(&facade, specifierList, specifier)
            } else {
                if !consumeOrFail(.openBrace, "Expected namespace import or import list", &facade) {
                    return .null
                }
                // NamedImports :
                // { }
                // { ImportsList }
                // { ImportsList , }
                while !match(.closeBrace) {
                    if !(matchIdentifierOrKeyword() || match(.string)) {
                        return fail("Expected an imported name or a module export name string for the import declaration")
                    }
                    let specifier = parseImportClauseItem(&context, .namedImport, &facade)
                    if specifier.isNull {
                        return fail("Cannot parse the named import")
                    }
                    context.appendImportSpecifier(&facade, specifierList, specifier)
                    if !consume(.comma, [], &facade) {
                        break
                    }
                }
                if !handleProductionOrFail(.closeBrace, "}", "end", "an import list", &facade) {
                    return .null
                }
            }
        }

        // FromClause :
        // from ModuleSpecifier

        if !matchContextualKeyword(.from, &facade) {
            return fail("Expected 'from' before imported module name")
        }
        next([], &facade)

        let moduleName = parseModuleName(&context, &facade)
        if moduleName.isNull {
            return fail("Cannot parse the module name")
        }

        // WithClause ;
        guard let attributesList = parseOptionalWithClause(&context, &facade) else {
            return fail("Unable to parse import attributes")
        }

        if !autoSemiColon(&facade) {
            return fail("Expected a ';' following a targeted import declaration")
        }

        return context.createImportDeclaration(&facade, importLocation, type, specifierList, moduleName, attributesList)
    }

    private mutating func parseExportSpecifier<B: TreeBuilder>(
        _ context: inout B,
        _ names: inout ExportClauseNames,
        _ facade: inout JSC.JSParseFacade
    ) -> B.ExportSpecifier {
        // ExportSpecifier :
        // IdentifierName
        // IdentifierName as IdentifierName
        // IdentifierName as ModuleExportName
        // ModuleExportName
        // ModuleExportName as IdentifierName
        // ModuleExportName as ModuleExportName
        // http://www.ecma-international.org/ecma-262/6.0/#sec-exports
        assert(matchIdentifierOrKeyword() || match(.string))
        let specifierLocation = tokenLocation
        let localName = token.data.ident
        var exportedName = localName
        if match(.string) {
            names.hasModuleExportName = true
            if facade.identifierHasUnpairedSurrogate(exportedName) {
                return fail("Expected a well-formed-unicode string for the module export name")
            }
        } else if token.type.isKeyword {
            names.hasKeyword = true
        }
        next([], &facade)

        if matchContextualKeyword(.as, &facade) {
            next([], &facade)
            if !(matchIdentifierOrKeyword() || match(.string)) {
                return fail("Expected an exported name or a module export name string for the export declaration")
            }
            exportedName = token.data.ident
            if match(.string) && facade.identifierHasUnpairedSurrogate(exportedName) {
                return fail("Expected a well-formed-unicode string for the module export name")
            }
            next([], &facade)
        }

        if !exportName(exportedName, &facade) {
            return semanticFail(ErrorMessage(.text("Cannot export a duplicate name '"), .identifier(exportedName), .text("'")))
        }
        names.localNames.append((localName, exportedName))
        return context.createExportSpecifier(&facade, specifierLocation, localName, exportedName)
    }

    mutating func parseExportDeclaration<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> B.Statement {
        // http://www.ecma-international.org/ecma-262/6.0/#sec-exports
        let savedStatementDepth = statementDepth
        defer { statementDepth = savedStatementDepth }
        statementDepth &+= 1
        assert(match(.exportKeyword))
        let exportLocation = tokenLocation
        next([], &facade)

        switch token.type {
        case .times:
            // export * FromClause ;
            // export * as IdentifierName FromClause ;
            // export * as ModuleExportName FromClause ;
            next([], &facade)

            var exportedName: (name: JSC.JSParseIdentifier, location: JSC.JSTokenLocation)?
            if matchContextualKeyword(.as, &facade) {
                next([], &facade)
                let specifierLocation = tokenLocation
                if !(matchIdentifierOrKeyword() || match(.string)) {
                    return fail("Expected an exported name or a module export name string for the export declaration")
                }
                let name = token.data.ident
                exportedName = (name, specifierLocation)
                if match(.string) && facade.identifierHasUnpairedSurrogate(name) {
                    return fail("Expected a well-formed-unicode string for the module export name")
                }
                next([], &facade)
            }

            if !matchContextualKeyword(.from, &facade) {
                return fail("Expected 'from' before exported module name")
            }
            next([], &facade)
            let moduleName = parseModuleName(&context, &facade)
            if moduleName.isNull {
                return fail("Cannot parse the 'from' clause")
            }

            // WithClause ;
            guard let attributesList = parseOptionalWithClause(&context, &facade) else {
                return fail("Unable to parse import attributes")
            }

            if !autoSemiColon(&facade) {
                return fail("Expected a ';' following a targeted export declaration")
            }

            if let (exportedName, specifierLocation) = exportedName {
                if !exportName(exportedName, &facade) {
                    return semanticFail(ErrorMessage(.text("Cannot export a duplicate name '"), .identifier(exportedName), .text("'")))
                }
                let specifierList = context.createExportSpecifierList(&facade)
                let localName = facade.wellKnownIdentifier(.starNamespacePrivateName)
                let specifier = context.createExportSpecifier(&facade, specifierLocation, localName, exportedName)
                context.appendExportSpecifier(&facade, specifierList, specifier)
                return context.createExportNamedDeclaration(&facade, exportLocation, specifierList, moduleName, attributesList)
            }

            return context.createExportAllDeclaration(&facade, exportLocation, moduleName, attributesList)

        case .defaultKeyword:
            // export default HoistableDeclaration[~Yield, ~Await, +Default]
            // export default ClassDeclaration[~Yield, ~Await, +Default]
            // export default [lookahead not-in { function, async [no LineTerminator here] function, class }]
            //     AssignmentExpression[+In, ~Yield, ~Await]
            next([], &facade)

            let result: B.Statement
            var isFunctionOrClassDeclaration = false
            var localName: JSC.JSParseIdentifier?

            let startsWithFunction = match(.functionKeyword)
            if startsWithFunction || match(.classKeyword) {
                let savePoint = createSavePoint(&context, &facade)
                isFunctionOrClassDeclaration = true
                next([], &facade)

                // ES6 Generators
                if startsWithFunction && match(.times) {
                    next([], &facade)
                }
                if match(.identifier) {
                    localName = token.data.ident
                }
                restoreSavePoint(&context, savePoint, &facade)
            } else if matchContextualKeyword(.async, &facade) {
                // export default async function xxx() { }
                // export default async function * yyy() { }
                let savePoint = createSavePoint(&context, &facade)
                next([], &facade)
                if match(.functionKeyword) && !lexer.hasLineTerminatorBeforeToken {
                    next([], &facade)
                    // Async Generators
                    _ = consume(.times, [], &facade)
                    if match(.identifier) {
                        localName = token.data.ident
                    }
                    isFunctionOrClassDeclaration = true
                }
                restoreSavePoint(&context, savePoint, &facade)
            }

            let defaultLocalName = localName ?? facade.wellKnownIdentifier(.starDefaultPrivateName)

            if isFunctionOrClassDeclaration {
                if startsWithFunction {
                    assert(match(.functionKeyword))
                    result = parseFunctionDeclaration(
                        &context,
                        .declaration,
                        exportType: .notExported,
                        defaultContext: .exportDefault,
                        functionConstructorParametersEndPosition: nil,
                        &facade
                    )
                } else if match(.classKeyword) {
                    result = parseClassDeclaration(&context, exportType: .notExported, defaultContext: .exportDefault, &facade)
                } else {
                    assert(matchContextualKeyword(.async, &facade))
                    let functionStart = tokenStart
                    next([], &facade)
                    result = parseAsyncFunctionDeclaration(
                        &context,
                        functionStart,
                        exportType: .notExported,
                        defaultContext: .exportDefault,
                        functionConstructorParametersEndPosition: nil,
                        &facade
                    )
                }
            } else {
                // export default expr;
                //
                // It should be treated as the same to the following.
                //
                // const *default* = expr;
                // export { *default* as default }
                //
                // In the above example, *default* is the invisible variable to the users.
                // We use the private symbol to represent the name of this variable.
                let location = tokenLocation
                let start = tokenStartPosition
                let expression = parseAssignmentExpression(&context, &facade)
                if expression.isNull {
                    return fail("Cannot parse expression")
                }

                let starDefault = facade.wellKnownIdentifier(.starDefaultPrivateName)
                let declarationResult = declareVariable(starDefault, .const, .notImported, &facade)
                if declarationResult.contains(.invalidDuplicateDeclaration) {
                    return semanticFail("Only one 'default' export is allowed")
                }

                let assignment = context.createAssignResolve(
                    &facade,
                    location,
                    starDefault,
                    expression,
                    start,
                    start,
                    tokenEndPosition,
                    .ConstDeclarationStatement
                )
                result = context.createExprStatement(&facade, location, assignment, start)
                if !autoSemiColon(&facade) {
                    return fail("Expected a ';' following a targeted export declaration")
                }
            }
            if result.isNull {
                return fail("Cannot parse the declaration")
            }

            let defaultKeyword = facade.wellKnownIdentifier(.defaultKeyword)
            if !exportName(defaultKeyword, &facade) {
                return semanticFail("Only one 'default' export is allowed")
            }
            facade.moduleExportBindingAs(defaultLocalName, defaultKeyword)
            return context.createExportDefaultDeclaration(&facade, exportLocation, result, defaultLocalName)

        case .openBrace:
            // export ExportClause FromClause ;
            // export ExportClause ;
            //
            // ExportClause :
            // { }
            // { ExportsList }
            // { ExportsList , }
            //
            // ExportsList :
            // ExportSpecifier
            // ExportsList , ExportSpecifier
            next([], &facade)

            let specifierList = context.createExportSpecifierList(&facade)
            var names = ExportClauseNames()
            while !match(.closeBrace) {
                if !(matchIdentifierOrKeyword() || match(.string)) {
                    return fail("Expected a variable name or a module export name string for the export declaration")
                }
                let specifier = parseExportSpecifier(
                    &context,
                    &names,
                    &facade
                )
                if specifier.isNull {
                    return fail("Cannot parse the named export")
                }
                context.appendExportSpecifier(&facade, specifierList, specifier)
                if !consume(.comma, [], &facade) {
                    break
                }
            }
            if !consumeOrFail(.closeBrace, "Expected '}' to end an export list", &facade) {
                return .null
            }

            var moduleName = B.ModuleName.null
            var attributesList = B.ImportAttributesList.null
            if matchContextualKeyword(.from, &facade) {
                next([], &facade)
                moduleName = parseModuleName(&context, &facade)
                if moduleName.isNull {
                    return fail("Cannot parse the 'from' clause")
                }

                // WithClause ;
                guard let withAttributes = parseOptionalWithClause(&context, &facade) else {
                    return fail("Unable to parse import attributes")
                }
                attributesList = withAttributes
            } else if names.hasModuleExportName {
                return semanticFail("Cannot use module export names if they reference variable names in the current module")
            }
            if !autoSemiColon(&facade) {
                return fail("Expected a ';' following a targeted export declaration")
            }

            if moduleName.isNull {
                if names.hasKeyword {
                    return semanticFail("Cannot use keyword as exported variable name")
                }
                // Since this export declaration does not have module specifier part, it exports the local bindings.
                // While the export declaration with module specifier does not have any effect on the current module's
                // scope, the export named declaration without module specifier references the local binding names.
                // For example,
                //   export { A, B, C as D } from "mod"
                // does not have effect on the current module's scope. But,
                //   export { A, B, C as D }
                // will reference the current module's bindings.
                for (localName, exportedName) in names.localNames {
                    facade.moduleExportBindingAs(localName, exportedName)
                }
            }

            return context.createExportNamedDeclaration(&facade, exportLocation, specifierList, moduleName, attributesList)

        default:
            // export VariableStatement
            // export Declaration
            let result: B.Statement
            switch token.type {
            case .varKeyword:
                result = parseVariableDeclaration(&context, .var, .exported, &facade)
            case .constKeyword:
                result = parseVariableDeclaration(&context, .const, .exported, &facade)
            case .letKeyword:
                result = parseVariableDeclaration(&context, .let, .exported, &facade)
            case .functionKeyword:
                result = parseFunctionDeclaration(
                    &context,
                    .declaration,
                    exportType: .exported,
                    defaultContext: .standard,
                    functionConstructorParametersEndPosition: nil,
                    &facade
                )
            case .classKeyword:
                result = parseClassDeclaration(&context, exportType: .exported, defaultContext: .standard, &facade)
            case .identifier where token.data.ident.matches(.async, &facade) && !token.data.escaped:
                let functionStart = tokenStart
                next([], &facade)
                if !(match(.functionKeyword) && !lexer.hasLineTerminatorBeforeToken) {
                    return semanticFail("Expected 'function' keyword following 'async' keyword with no preceding line terminator")
                }
                result = parseAsyncFunctionDeclaration(
                    &context,
                    functionStart,
                    exportType: .exported,
                    defaultContext: .standard,
                    functionConstructorParametersEndPosition: nil,
                    &facade
                )
            default:
                return fail("Expected either a declaration or a variable statement")
            }

            if result.isNull {
                return fail("Cannot parse the declaration")
            }
            return context.createExportLocalDeclaration(&facade, exportLocation, result)
        }
    }
}
