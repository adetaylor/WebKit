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

/// The depth of nested `.call` and `.apply` calls at one call site.
struct CallOrApplyDepthScope {
    var depth: UInt16
    var depthOfInnermostChild: UInt16

    var distanceToInnermostChild: UInt16 {
        assert(depthOfInnermostChild >= depth)
        return depthOfInnermostChild - depth
    }
}

extension Parser {
    // MARK: Scopes

    /// Whether `scope` is still on the stack; one unsigned compare checks both bounds.
    @inline(always)
    func isLive(_ scope: ScopeRef) -> Bool {
        UInt(bitPattern: scope.index) < UInt(bitPattern: scopes.count) && scopes[scope.index].generation == scope.generation
    }

    // The current scope is the last element.
    var currentIsGeneratorFunction: Bool { scopes[topScope].isGeneratorFunction }

    var currentIsAsyncFunction: Bool { scopes[topScope].isAsyncFunction }

    var currentIsStaticBlock: Bool { scopes[topScope].isStaticBlock }

    /// Reads or mutates the scope `scope` refers to, trapping when it has been popped.
    ///
    /// Checks the generation. A read by `index` into the live scope stack is bounds-checked and indexes a live scope.
    @inline(always)
    mutating func withScope<R>(_ scope: ScopeRef, _ body: (inout Scope) -> R) -> R {
        precondition(isLive(scope))
        return body(&scopes[scope.index])
    }

    /// The current scope; the stack is not empty once the parse has pushed its root scope.
    var current: ScopeRef {
        scopeRef(at: topScope)
    }

    func scopeRef(at index: Int) -> ScopeRef {
        ScopeRef(index: index, generation: scopes[index].generation)
    }

    var strictMode: Bool { scopes[topScope].strictMode }

    var isValidStrictMode: Bool {
        let index = topScope
        if !scopes[index].isValidStrictMode {
            return false
        }

        // In the case of Generator or Async function bodies, also check the wrapper function, whose name or
        // arguments may be invalid.
        if (scopes[index].isGeneratorFunctionBoundary || scopes[index].isAsyncFunctionBoundary) && index > 0 {
            return scopes[index - 1].isValidStrictMode
        }
        return true
    }

    mutating func declareParameter(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        scopes[topScope].declareParameter(ident, &facade)
    }

    private func hasContainingScope(_ index: Int) -> Bool {
        index > 0 && !scopes[index].isFunctionBoundary
    }

    func currentVariableScope() -> ScopeRef {
        var index = topScope
        while !scopes[index].allowsVarDeclarations {
            index -= 1
        }
        return scopeRef(at: index)
    }

    func currentLexicalDeclarationScope() -> ScopeRef {
        var index = topScope
        while !scopes[index].allowsLexicalDeclarations {
            index -= 1
        }
        return scopeRef(at: index)
    }

    mutating func currentFunctionScope() -> ScopeRef {
        var index = topScope
        // The unsigned compare lets the optimizer drop the subscript's bounds check.
        while index > 0 && UInt(bitPattern: index) < UInt(bitPattern: scopes.count) && !scopes[index].isFunctionBoundary {
            index -= 1
        }
        // When reaching the top level scope (it can be non function scope), we return it.
        return scopeRef(at: index)
    }

    mutating func closestParentOrdinaryFunctionNonLexicalScope() -> ScopeRef {
        var index = topScope
        while index > 0 {
            if scopes[index].isFunctionBoundary && !scopes[index].isGeneratorFunctionBoundary
                && !scopes[index].isAsyncFunctionBoundary && !scopes[index].isArrowFunctionBoundary
            {
                break
            }
            index -= 1
        }
        // When reaching the top level scope (it can be non ordinary function scope), we return it.
        return scopeRef(at: index)
    }

    // Walk to the closest scope that has its own `arguments` binding (or the top-level
    // scope). Arrow functions and lexical scopes are transparent for `arguments`.
    func closestScopeOwningArguments() -> ScopeRef {
        var index = topScope
        while index > 0 {
            if scopes[index].isFunctionBoundary && !scopes[index].isArrowFunctionBoundary {
                break
            }
            index -= 1
        }
        return scopeRef(at: index)
    }

    func closestClassScopeOrTopLevelScope() -> ScopeRef {
        var index = topScope
        while index > 0 && !scopes[index].isClassScope {
            index -= 1
        }
        return scopeRef(at: index)
    }

    mutating func pushScope(_ facade: inout JSC.JSParseFacade) -> ScopeRef {
        let storage = facade.pushScope()
        scopeGeneration += 1
        let scope =
            topScope >= 0
            ? Scope(storage: storage, generation: scopeGeneration, labelsBase: labelStack.count, inheriting: scopes[topScope])
            : Scope(
                storage: storage,
                generation: scopeGeneration,
                implementationVisibility: implementationVisibility,
                labelsBase: labelStack.count
            )
        scopes.append(scope)
        topScope = scopes.count - 1
        return ScopeRef(index: topScope, generation: scopeGeneration)
    }

    mutating func resetImplementationVisibilityIfNeeded() {
        // Find the closest function boundary that is not the current scope (if the current scope
        // is also a function boundary). If the implementation visibility of that scope is not
        // recursive, reset the implementation visibility of the current scope.

        let last = topScope
        if !scopes[last].isFunctionBoundary {
            return
        }

        var index = last - 1
        while index >= 0 {
            if scopes[index].isFunctionBoundary {
                if scopes[index].implementationVisibility != .PrivateRecursive {
                    scopes[last].implementationVisibility = .Public
                }
                break
            }
            index -= 1
        }
    }

    // When takeContainers, the scope's lexical environment and function declarations are returned for its node;
    // otherwise they are dropped with the storage and the result is null handles, which the node-less checker's callers
    // pass on unused.
    @discardableResult
    mutating func popScope(
        _ scope: ScopeRef,
        shouldTrackClosedVariables: Bool,
        takeContainers: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> (lexicalVariables: JSC.JSParseEnvironment, functionDeclarations: JSC.JSParseFunctionStack) {
        precondition(scope.index == topScope && isLive(scope))
        assert(scopes.count > 1)
        let last = scope.index
        let parent = last - 1

        scopes[last].finalizeLexicalEnvironment(&facade)

        collectFreeVariables(into: parent, from: last, shouldTrackClosedVariables, &facade)

        if scopes[last].hasSloppyModeFunctionHoistingCandidates(&facade) {
            facade.bubbleSloppyModeFunctionHoistingCandidates(
                scopes[last].storage,
                scopes[parent].storage,
                scopes[last].isSimpleCatchParameterScope
            )
        }

        if scopes[last].isArrowFunction {
            scopes[last].setInnerArrowFunctionUsesEvalAndUseArgumentsIfNeeded(&facade)
        }

        if !(scopes[last].isFunctionBoundary && !scopes[last].isArrowFunctionBoundary) {
            scopes[parent].mergeInnerArrowFunctionFeatures(scopes[last].innerArrowFunctionFeatures)
        }

        if !scopes[last].isFunctionBoundary && scopes[last].needsFullActivation {
            scopes[parent].setNeedsFullActivation()
        }
        let result =
            takeContainers
            ? (facade.takeEnvironment(scopes[last].storage, .Lexical), facade.takeFunctionDeclarations(scopes[last].storage))
            : (JSC.JSParseEnvironment(), JSC.JSParseFunctionStack())
        facade.popScope(scopes[last].storage)
        // Only when the scope pushed labels: removeSubrange on the shared empty array takes the non-unique path, which
        // makes a new buffer on every pop.
        if labelStack.count > scopes[topScope].labelsBase {
            labelStack.removeSubrange(scopes[topScope].labelsBase...)
        }
        scopes.removeLast()
        topScope = last - 1
        return result
    }

    /// Propagates nested's flags to parent; the facade moves the free variables.
    private mutating func collectFreeVariables(
        into parent: Int,
        from nested: Int,
        _ shouldTrackClosedVariables: Bool,
        _ facade: inout JSC.JSParseFacade
    ) {
        let nestedUsesEval = scopes[nested].usesEval
        let nestedUsesImportMeta = scopes[nested].usesImportMeta
        scopes[parent].propagateFlags(usesEval: nestedUsesEval, usesImportMeta: nestedUsesImportMeta)
        // If nestedScope is a non-arrow function and there is an "arguments" reference,
        // we need to filter it because it should not propagate out.
        let nestedIsFunctionBoundary = scopes[nested].isFunctionBoundary
        let filterArguments = nestedIsFunctionBoundary && scopes[nested].hasArguments && !scopes[nested].isArrowFunctionBoundary
        facade.collectFreeVariables(
            scopes[parent].storage,
            scopes[nested].storage,
            shouldTrackClosedVariables,
            filterArguments,
            nestedIsFunctionBoundary,
            scopes[nested].isLexicalScope
        )
    }

    // MARK: Declarations

    @inline(never)
    mutating func declareHoistedVariable(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        var index = topScope
        while true {
            // Annex B.3.5 exempts `try {} catch (e) { var e; }` from being a syntax error.
            if scopes[index].hasLexicallyDeclaredVariable(ident, &facade) && !scopes[index].isSimpleCatchParameterScope {
                return .invalidDuplicateDeclaration
            }

            if scopes[index].allowsVarDeclarations {
                return scopes[index].declareVariable(ident, &facade)
            }
            scopes[index].addVariableBeingHoisted(ident, &facade)
            index -= 1
            assert(index >= 0)
        }
    }

    mutating func declareVariable(
        _ ident: JSC.JSParseIdentifier,
        _ type: DeclarationType = .var,
        _ importType: DeclarationImportType = .notImported,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        if type == .var {
            return declareHoistedVariable(ident, &facade)
        }

        assert(type == .let || type.isConstant)
        // Lexical variables declared at a top level scope that shadow arguments or vars are not allowed.
        if !lexer.isReparsingFunction && statementDepth == 1
            && (hasDeclaredParameter(ident, &facade) || hasDeclaredVariable(ident, &facade))
        {
            return .invalidDuplicateDeclaration
        }

        let scope = currentLexicalDeclarationScope()
        if scopes[scope.index].isCatchBlockScope && scopes[scope.index - 1].hasLexicallyDeclaredVariable(ident, &facade) {
            return .invalidDuplicateDeclaration
        }

        return withScope(scope) {
            $0.declareLexicalVariable(
                ident,
                isConstant: type.isConstant,
                importType: importType,
                isUsing: type.isUsing,
                isAwaitUsing: type == .awaitUsing,
                &facade
            )
        }
    }

    mutating func declareFunction(
        _ ident: JSC.JSParseIdentifier,
        _ facade: inout JSC.JSParseFacade
    ) -> (result: DeclarationResult, scope: ScopeRef) {
        if statementDepth == 1 && !scopes[topScope].isModuleCode {
            // Functions declared at the top-most scope (both in sloppy and strict mode) are declared as vars
            // for backwards compatibility, allowing us to declare functions with the same name more than once, except
            // Module code. Please see https://webkit.org/b/263269 for detailed explanation and ECMA-262 references.
            let scope = currentVariableScope()
            return (withScope(scope) { $0.declareFunctionAsVar(ident, &facade) }, scope)
        }

        let lexicalVariableScope = currentLexicalDeclarationScope()
        if scopes[lexicalVariableScope.index].isCatchBlockScope
            && scopes[lexicalVariableScope.index - 1].hasLexicallyDeclaredVariable(ident, &facade)
        {
            return (.invalidDuplicateDeclaration, lexicalVariableScope)
        }

        let isFunctionDeclaration = parseMode == .NormalFunctionMode
        let result = withScope(lexicalVariableScope) {
            $0.declareFunctionAsLet(ident, isFunctionDeclaration: isFunctionDeclaration, &facade)
        }
        return (result, lexicalVariableScope)
    }

    @inline(never)
    mutating func hasDeclaredVariable(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        scopes[currentVariableScope().index].hasDeclaredVariable(ident, &facade)
    }

    @inline(never)
    mutating func hasDeclaredParameter(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        // FIXME: hasDeclaredParameter() is not valid during reparsing of generator or async function bodies, because their formal
        // parameters are declared in a scope unavailable during reparsing. Note that it is redundant to call this function during
        // reparsing anyways, as the function is already guaranteed to have valid syntax.
        var index = topScope
        while !scopes[index].allowsVarDeclarations {
            index -= 1
        }
        if scopes[index].isGeneratorFunctionBoundary || scopes[index].isAsyncFunctionBoundary {
            // The formal parameters which need to be verified for Generators and Async Function bodies occur
            // in the outer wrapper function, so pick the outer scope here.
            index -= 1
            assert(index >= 0)
        }
        return scopes[index].hasDeclaredParameter(ident, &facade)
    }

    mutating func exportName(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        assert(scopes.count == 1)
        assert(hasModuleScopeData)
        return facade.moduleExportName(ident)
    }

    mutating func findCachedFunctionInfo(
        _ scope: ScopeRef,
        _ openBracePosition: Int32,
        _ facade: inout JSC.JSParseFacade
    ) -> JSC.JSParseCachedFunction? {
        guard hasFunctionCache else {
            return nil
        }
        return Optional(fromCxx: facade.findCachedFunction(withScope(scope) { $0.storage }, openBracePosition))
    }

    // MARK: Loops and labels

    mutating func startLoop() { scopes[topScope].startLoop() }

    mutating func endLoop() { scopes[topScope].endLoop() }

    mutating func startSwitch() { scopes[topScope].startSwitch() }

    mutating func endSwitch() { scopes[topScope].endSwitch() }

    mutating func setStrictMode() { scopes[topScope].setStrictMode() }

    var breakIsValid: Bool {
        mutating get {
            var index = topScope
            while !scopes[index].breakIsValid {
                if !hasContainingScope(index) || scopes[index].isStaticBlockBoundary {
                    return false
                }
                index -= 1
            }
            return true
        }
    }

    var continueIsValid: Bool {
        mutating get {
            var index = topScope
            while !scopes[index].continueIsValid {
                if !hasContainingScope(index) || scopes[index].isStaticBlockBoundary {
                    return false
                }
                index -= 1
            }
            return true
        }
    }

    mutating func pushLabel(_ label: JSC.JSParseIdentifier, isLoop: Bool) {
        labelStack.append(ScopeLabelInfo(label: label, isLoop: isLoop))
    }

    mutating func popLabel(_ scope: ScopeRef) {
        precondition(isLive(scope))
        assert(labelStack.count > scopes[scope.index].labelsBase)
        labelStack.removeLast()
    }

    mutating func label(_ label: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> ScopeLabelInfo? {
        var index = topScope
        while hasContainingScope(index) {
            index -= 1
        }
        // The labels of the scopes from the current one to the enclosing function boundary, innermost first.
        return labelStack[scopes[index].labelsBase...].last { facade.sameIdentifier($0.label, label) }
    }

    /// Moves the parameter expressions' free variables to the parent before the body's declarations hide them.
    mutating func collectFreeVariablesFromNestedScope(
        into parent: ScopeRef,
        from nested: ScopeRef,
        _ shouldTrackClosedVariables: Bool,
        _ facade: inout JSC.JSParseFacade
    ) {
        precondition(isLive(parent))
        precondition(isLive(nested))
        collectFreeVariables(into: parent.index, from: nested.index, shouldTrackClosedVariables, &facade)
    }

    var currentImplementationVisibility: JSC.ImplementationVisibility { scopes[topScope].implementationVisibility }

    var currentLexicallyScopedFeatures: JSC.LexicallyScopedFeatures { scopes[topScope].lexicallyScopedFeatures.rawValue }
}
