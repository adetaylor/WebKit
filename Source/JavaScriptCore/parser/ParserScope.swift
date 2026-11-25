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

/// VariableEnvironmentEntry's traits, as the facade's environment members take and report them.
struct VariableTraits: OptionSet {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    init(_ trait: JSC.JSParseVariableTrait) {
        rawValue = trait.rawValue
    }

    static let captured = VariableTraits(.Captured)
    static let const = VariableTraits(.Const)
    static let `var` = VariableTraits(.Var)
    static let `let` = VariableTraits(.Let)
    static let exported = VariableTraits(.Exported)
    static let imported = VariableTraits(.Imported)
    static let importedNamespace = VariableTraits(.ImportedNamespace)
    static let function = VariableTraits(.Function)
    static let parameter = VariableTraits(.Parameter)
    static let functionDeclaration = VariableTraits(.FunctionDeclaration)
    static let using = VariableTraits(.Using)
}

/// The kinds a scope's function is and the boundaries its body makes, in one byte.
struct FunctionKinds: OptionSet {
    let rawValue: UInt8

    static let generator = FunctionKinds(rawValue: 1 << 0)
    static let generatorBoundary = FunctionKinds(rawValue: 1 << 1)
    static let arrow = FunctionKinds(rawValue: 1 << 2)
    static let arrowBoundary = FunctionKinds(rawValue: 1 << 3)
    static let async = FunctionKinds(rawValue: 1 << 4)
    static let asyncBoundary = FunctionKinds(rawValue: 1 << 5)
    static let staticBlock = FunctionKinds(rawValue: 1 << 6)
    static let staticBlockBoundary = FunctionKinds(rawValue: 1 << 7)

    @inline(always)
    mutating func set(_ kind: FunctionKinds, to value: Bool) {
        if value {
            insert(kind)
        } else {
            remove(kind)
        }
    }
}

/// The features an inner arrow function uses of its enclosing function, as the C++ InnerArrowFunctionCodeFeatures.
struct InnerArrowFunctionFeatures: OptionSet {
    let rawValue: JSC.InnerArrowFunctionCodeFeatures

    static let superCall = InnerArrowFunctionFeatures(rawValue: JSC.SuperCallInnerArrowFunctionFeature)
    static let superProperty = InnerArrowFunctionFeatures(rawValue: JSC.SuperPropertyInnerArrowFunctionFeature)
    static let eval = InnerArrowFunctionFeatures(rawValue: JSC.EvalInnerArrowFunctionFeature)
    static let this = InnerArrowFunctionFeatures(rawValue: JSC.ThisInnerArrowFunctionFeature)
    static let newTarget = InnerArrowFunctionFeatures(rawValue: JSC.NewTargetInnerArrowFunctionFeature)
    static let arguments = InnerArrowFunctionFeatures(rawValue: JSC.ArgumentsInnerArrowFunctionFeature)
}

/// The features a scope's code is subject to, as the C++ LexicallyScopedFeatures.
struct LexicallyScopedFeatureSet: OptionSet {
    let rawValue: JSC.LexicallyScopedFeatures

    static let strictMode = LexicallyScopedFeatureSet(rawValue: JSC.StrictModeLexicallyScopedFeature)
    static let taintedByWithScope = LexicallyScopedFeatureSet(rawValue: JSC.TaintedByWithScopeLexicallyScopedFeature)
}

extension JSC.JSParseIdentifier {
    /// Whether this is the VM's well-known name `name`.
    @inline(always)
    func matches(_ name: JSC.JSParseWellKnownName, _ facade: inout JSC.JSParseFacade) -> Bool {
        facade.isWellKnownIdentifier(self, name)
    }

    @inline(always)
    func isEvalOrArguments(_ facade: inout JSC.JSParseFacade) -> Bool {
        matches(.eval, &facade) || matches(.arguments, &facade)
    }

    func isStrictModeReservedWord(_ facade: inout JSC.JSParseFacade) -> Bool {
        matches(.implementsKeyword, &facade) || matches(.interfaceKeyword, &facade) || matches(.letKeyword, &facade)
            || matches(.packageKeyword, &facade) || matches(.privateKeyword, &facade) || matches(.protectedKeyword, &facade)
            || matches(.publicKeyword, &facade) || matches(.staticKeyword, &facade) || matches(.yieldKeyword, &facade)
    }
}

struct ScopeLabelInfo {
    var label: JSC.JSParseIdentifier
    var isLoop: Bool
}

// One scope of the parse. Its C++ containers are in the facade's storage for `storage`; a Scope lives only on the
// parser's stack, so that handle names a live scope.
struct Scope: ~Copyable {
    let storage: JSC.JSParseScope
    /// The parser's count of pushes when this was pushed; a ScopeRef must carry the same.
    let generation: UInt32
    var implementationVisibility: JSC.ImplementationVisibility
    var lexicallyScopedFeatures: LexicallyScopedFeatureSet
    private(set) var shadowsArguments = false
    private(set) var usesEval = false
    private(set) var usesImportMeta = false
    private(set) var needsFullActivation = false
    private(set) var needsSuperBinding = false
    private(set) var allowsVarDeclarations = true
    private(set) var allowsLexicalDeclarations = true
    private(set) var isFunction: Bool
    /// What kind of function this is, which setSourceParseMode sets together: a boundary is set only for a body.
    private var functionKinds: FunctionKinds
    private(set) var isGeneratorFunction: Bool {
        get { functionKinds.contains(.generator) }
        set { functionKinds.set(.generator, to: newValue) }
    }
    private(set) var isGeneratorFunctionBoundary: Bool {
        get { functionKinds.contains(.generatorBoundary) }
        set { functionKinds.set(.generatorBoundary, to: newValue) }
    }
    private(set) var isArrowFunction: Bool {
        get { functionKinds.contains(.arrow) }
        set { functionKinds.set(.arrow, to: newValue) }
    }
    private(set) var isArrowFunctionBoundary: Bool {
        get { functionKinds.contains(.arrowBoundary) }
        set { functionKinds.set(.arrowBoundary, to: newValue) }
    }
    private(set) var isAsyncFunction: Bool {
        get { functionKinds.contains(.async) }
        set { functionKinds.set(.async, to: newValue) }
    }
    private(set) var isAsyncFunctionBoundary: Bool {
        get { functionKinds.contains(.asyncBoundary) }
        set { functionKinds.set(.asyncBoundary, to: newValue) }
    }
    private(set) var isLexicalScope = false
    private(set) var isGlobalCode = false
    private(set) var isModuleCode = false
    private(set) var isSimpleCatchParameterScope = false
    private(set) var isCatchBlockScope = false
    private(set) var isStaticBlock: Bool {
        get { functionKinds.contains(.staticBlock) }
        set { functionKinds.set(.staticBlock, to: newValue) }
    }
    private(set) var isStaticBlockBoundary: Bool {
        get { functionKinds.contains(.staticBlockBoundary) }
        set { functionKinds.set(.staticBlockBoundary, to: newValue) }
    }
    private(set) var isFunctionBoundary = false
    private(set) var isValidStrictMode = true
    private(set) var hasArguments = false
    var isEvalContext = false
    private(set) var hasNonSimpleParameterList = false
    private(set) var isClassScope = false
    private(set) var asyncFunctionBodyDoesNotUseAwait = false
    private(set) var usesAwait = false
    private var loopDepth = 0
    var expectedSuperBinding = JSC.SuperBinding.NotNeeded
    var constructorKind = JSC.ConstructorKind.None
    private(set) var innerArrowFunctionFeatures: InnerArrowFunctionFeatures = []
    /// Where this scope's labels start in the parser's label stack.
    let labelsBase: Int
    private var switchDepth = 0
    var evalContextType = JSC.EvalContextType.None
    var derivedContextType = JSC.DerivedContextType.None

    init(
        storage: JSC.JSParseScope,
        generation: UInt32,
        implementationVisibility: JSC.ImplementationVisibility,
        lexicallyScopedFeatures: LexicallyScopedFeatureSet,
        isFunction: Bool,
        isGeneratorFunction: Bool,
        isArrowFunction: Bool,
        isAsyncFunction: Bool,
        isStaticBlock: Bool,
        labelsBase: Int
    ) {
        self.labelsBase = labelsBase
        self.storage = storage
        self.generation = generation
        self.implementationVisibility = implementationVisibility
        self.lexicallyScopedFeatures = lexicallyScopedFeatures
        self.isFunction = isFunction
        functionKinds = []
        self.isGeneratorFunction = isGeneratorFunction
        self.isArrowFunction = isArrowFunction
        self.isAsyncFunction = isAsyncFunction
        self.isStaticBlock = isStaticBlock
    }

    /// The outermost scope: nothing is inherited but the parse's implementation visibility.
    init(storage: JSC.JSParseScope, generation: UInt32, implementationVisibility: JSC.ImplementationVisibility, labelsBase: Int) {
        self.init(
            storage: storage,
            generation: generation,
            implementationVisibility: implementationVisibility,
            lexicallyScopedFeatures: [],
            isFunction: false,
            isGeneratorFunction: false,
            isArrowFunction: false,
            isAsyncFunction: false,
            isStaticBlock: false,
            labelsBase: labelsBase
        )
    }

    /// A scope pushed inside `parent`, which hands down its visibility, features and function kinds.
    init(storage: JSC.JSParseScope, generation: UInt32, labelsBase: Int, inheriting parent: borrowing Scope) {
        self.init(
            storage: storage,
            generation: generation,
            implementationVisibility: parent.implementationVisibility,
            lexicallyScopedFeatures: parent.lexicallyScopedFeatures,
            isFunction: parent.isFunction,
            isGeneratorFunction: parent.isGeneratorFunction,
            isArrowFunction: parent.isArrowFunction,
            isAsyncFunction: parent.isAsyncFunction,
            isStaticBlock: parent.isStaticBlock,
            labelsBase: labelsBase
        )
    }

    /// The grammar sets isGeneratorFunction for one production and restores it after.
    mutating func exchangeIsGeneratorFunction(_ shouldParseAsGeneratorFunction: Bool) -> Bool {
        exchange(&isGeneratorFunction, with: shouldParseAsGeneratorFunction)
    }

    // MARK: Loops, switches and labels

    mutating func startSwitch() { switchDepth += 1 }
    mutating func endSwitch() { switchDepth -= 1 }
    var isSwitchBlockScope: Bool { switchDepth != 0 }
    mutating func startLoop() { loopDepth += 1 }
    mutating func endLoop() {
        assert(loopDepth != 0)
        loopDepth -= 1
    }
    var breakIsValid: Bool { loopDepth != 0 || switchDepth != 0 }
    var continueIsValid: Bool { loopDepth != 0 }

    // MARK: Kinds of scope

    mutating func setSourceParseMode(_ mode: JSC.SourceParseMode) {
        switch mode {
        case .AsyncGeneratorBodyMode:
            setIsAsyncGeneratorFunctionBody()
        case .AsyncArrowFunctionBodyMode:
            setIsAsyncArrowFunctionBody()
        case .AsyncFunctionBodyMode:
            setIsAsyncFunctionBody()
        case .GeneratorBodyMode:
            setIsGeneratorFunctionBody()
        case .GeneratorWrapperFunctionMode, .GeneratorWrapperMethodMode:
            setIsGeneratorFunction()
        case .AsyncGeneratorWrapperMethodMode, .AsyncGeneratorWrapperFunctionMode:
            setIsAsyncGeneratorFunction()
        case .NormalFunctionMode, .GetterMode, .SetterMode, .MethodMode, .ClassFieldInitializerMode:
            setIsFunction()
        case .ClassStaticBlockMode:
            setIsFunction()
            setIsStaticBlock()
        case .ArrowFunctionMode:
            setIsArrowFunction()
        case .AsyncFunctionMode, .AsyncMethodMode:
            setIsAsyncFunction()
        case .AsyncArrowFunctionMode:
            setIsAsyncArrowFunction()
        case .ProgramMode:
            setIsGlobalCode()
        case .ModuleAnalyzeMode, .ModuleEvaluateMode:
            setIsModuleCode()
        @unknown default:
            preconditionFailure()
        }
    }

    var isPrivateNameScope: Bool { isClassScope }

    mutating func setIsSimpleCatchParameterScope() { isSimpleCatchParameterScope = true }
    mutating func setIsCatchBlockScope() { isCatchBlockScope = true }

    mutating func setIsStaticBlock() {
        isStaticBlock = true
        isStaticBlockBoundary = true
    }

    mutating func setIsLexicalScope() {
        isLexicalScope = true
        allowsLexicalDeclarations = true
    }

    mutating func setIsPrivateNameScope() {
        // FIXME: Currently, isPrivateNameScope is an alias for isClassScope --- This is potentially misleading,
        // particularly when parsing direct eval code which occurs within a class.
        setIsClassScope()
    }

    mutating func setIsClassScope() { isClassScope = true }

    private mutating func setIsFunction() {
        isFunction = true
        isFunctionBoundary = true
        hasArguments = true
        setIsLexicalScope()
        functionKinds = []
    }

    private mutating func setIsGeneratorFunction() {
        setIsFunction()
        isGeneratorFunction = true
    }

    private mutating func setIsGeneratorFunctionBody() {
        setIsFunction()
        hasArguments = false
        isGeneratorFunction = true
        isGeneratorFunctionBoundary = true
    }

    private mutating func setIsArrowFunction() {
        setIsFunction()
        isArrowFunctionBoundary = true
        isArrowFunction = true
    }

    private mutating func setIsAsyncArrowFunction() {
        setIsArrowFunction()
        isAsyncFunction = true
    }

    private mutating func setIsAsyncFunction() {
        setIsFunction()
        isAsyncFunction = true
    }

    private mutating func setIsAsyncGeneratorFunction() {
        setIsFunction()
        isAsyncFunction = true
        isGeneratorFunction = true
    }

    private mutating func setIsAsyncGeneratorFunctionBody() {
        setIsFunction()
        hasArguments = false
        isGeneratorFunction = true
        isGeneratorFunctionBoundary = true
        isAsyncFunction = true
        isAsyncFunctionBoundary = true
    }

    private mutating func setIsAsyncFunctionBody() {
        setIsFunction()
        hasArguments = false
        isAsyncFunction = true
        isAsyncFunctionBoundary = true
    }

    private mutating func setIsAsyncArrowFunctionBody() {
        setIsArrowFunction()
        hasArguments = false
        isAsyncFunction = true
        isAsyncFunctionBoundary = true
    }

    private mutating func setIsGlobalCode() { isGlobalCode = true }

    private mutating func setIsModuleCode() {
        setIsGlobalCode()
        isModuleCode = true
    }

    // MARK: Flags

    mutating func setUsesImportMeta() { usesImportMeta = true }
    mutating func setNeedsFullActivation() { needsFullActivation = true }
    mutating func setAsyncFunctionBodyDoesNotUseAwait() { asyncFunctionBodyDoesNotUseAwait = true }
    mutating func setUsesAwait() { usesAwait = true }
    mutating func setNeedsSuperBinding() { needsSuperBinding = true }

    mutating func setInnerArrowFunctionUsesSuperCall() { innerArrowFunctionFeatures.insert(.superCall) }
    mutating func setInnerArrowFunctionUsesSuperProperty() {
        innerArrowFunctionFeatures.insert(.superProperty)
    }
    mutating func setInnerArrowFunctionUsesEval() { innerArrowFunctionFeatures.insert(.eval) }
    mutating func setInnerArrowFunctionUsesThis() { innerArrowFunctionFeatures.insert(.this) }
    mutating func setInnerArrowFunctionUsesNewTarget() { innerArrowFunctionFeatures.insert(.newTarget) }
    mutating func setInnerArrowFunctionUsesArguments() { innerArrowFunctionFeatures.insert(.arguments) }

    mutating func setInnerArrowFunctionUsesEvalAndUseArgumentsIfNeeded(_ facade: inout JSC.JSParseFacade) {
        assert(isArrowFunction)
        if usesEval {
            setInnerArrowFunctionUsesEval()
        }
        if usedVariablesContains(facade.wellKnownIdentifier(.arguments), &facade) {
            setInnerArrowFunctionUsesArguments()
        }
    }

    mutating func mergeInnerArrowFunctionFeatures(_ features: InnerArrowFunctionFeatures) {
        innerArrowFunctionFeatures.formUnion(features)
    }

    mutating func propagateFlags(usesEval nestedUsesEval: Bool, usesImportMeta nestedUsesImportMeta: Bool) {
        if nestedUsesEval {
            usesEval = true
        }
        if nestedUsesImportMeta {
            usesImportMeta = true
        }
    }

    mutating func setStrictMode() { lexicallyScopedFeatures.insert(.strictMode) }
    mutating func setTaintedByWithScope() { lexicallyScopedFeatures.insert(.taintedByWithScope) }
    var strictMode: Bool { lexicallyScopedFeatures.contains(.strictMode) }

    mutating func setHasNonSimpleParameterList() {
        isValidStrictMode = false
        hasNonSimpleParameterList = true
    }

    mutating func preventAllVariableDeclarations() {
        allowsVarDeclarations = false
        allowsLexicalDeclarations = false
    }

    mutating func preventVarDeclarations() { allowsVarDeclarations = false }

    // MARK: Declarations

    func finalizeLexicalEnvironment(_ facade: inout JSC.JSParseFacade) {
        if usesEval || needsFullActivation {
            facade.environmentMarkAllAsCaptured(storage, .Lexical)
        } else {
            facade.computeLexicallyCapturedVariablesAndPurgeCandidates(storage)
        }
    }

    func declareCallee(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        _ = facade.environmentAdd(storage, .Declared, ident, 0)
        // We want to track if callee is captured, but we don't want to act like it's a 'var'
        // because that would cause the BytecodeGenerator to emit bad code.
        facade.environmentClearIsVar(storage, .Declared, ident)

        var result = DeclarationResult.valid
        if ident.isEvalOrArguments(&facade) {
            result.insert(.invalidStrictMode)
        }
        return result
    }

    mutating func declareVariable(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        assert(allowsVarDeclarations)
        var result = DeclarationResult.valid
        let isValidStrictMode = !ident.isEvalOrArguments(&facade)
        self.isValidStrictMode = self.isValidStrictMode && isValidStrictMode
        _ = facade.environmentAdd(storage, .Declared, ident, VariableTraits.var.rawValue)
        if !isValidStrictMode {
            result.insert(.invalidStrictMode)
        }
        return result
    }

    mutating func declareFunctionAsVar(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        assert(allowsVarDeclarations)
        var result = DeclarationResult.valid
        let isValidStrictMode = !ident.isEvalOrArguments(&facade)
        if !isValidStrictMode {
            result.insert(.invalidStrictMode)
        }
        self.isValidStrictMode = self.isValidStrictMode && isValidStrictMode

        _ = facade.environmentAdd(storage, .Declared, ident, VariableTraits([.var, .function]).rawValue)

        if facade.environmentContains(storage, .Lexical, ident) {
            result.insert(.invalidDuplicateDeclaration)
        }
        return result
    }

    mutating func declareFunctionAsLet(
        _ ident: JSC.JSParseIdentifier,
        isFunctionDeclaration: Bool,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        assert(allowsLexicalDeclarations)
        var result = DeclarationResult.valid
        let isValidStrictMode = !ident.isEvalOrArguments(&facade)
        if !isValidStrictMode {
            result.insert(.invalidStrictMode)
        }
        self.isValidStrictMode = self.isValidStrictMode && isValidStrictMode

        if let existing = environmentEntry(.Lexical, ident, &facade) {
            if strictMode || !existing.contains(.functionDeclaration) || !isFunctionDeclaration {
                result.insert(.invalidDuplicateDeclaration)
            }
        }
        if facade.environmentContains(storage, .Declared, ident) || facade.nameSetContains(storage, .VariablesBeingHoisted, ident) {
            result.insert(.invalidDuplicateDeclaration)
        }

        var traits: VariableTraits = [.let, .function]
        if isFunctionDeclaration {
            traits.insert(.functionDeclaration)
        }
        _ = facade.environmentAdd(storage, .Lexical, ident, traits.rawValue)

        return result
    }

    func addVariableBeingHoisted(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) {
        assert(!allowsVarDeclarations)
        _ = facade.nameSetAdd(storage, .VariablesBeingHoisted, ident)
    }

    func addSloppyModeFunctionHoistingCandidate(
        _ metadata: JSC.JSParseNode,
        needsDuplicateDeclarationCheck: Bool,
        _ facade: inout JSC.JSParseFacade
    ) {
        assert(!metadata.isNull)
        assert(!strictMode)
        facade.addSloppyModeFunctionHoistingCandidate(storage, metadata, needsDuplicateDeclarationCheck)
    }

    func appendFunction(_ metadata: JSC.JSParseNode, _ facade: inout JSC.JSParseFacade) {
        assert(!metadata.isNull)
        facade.appendFunction(storage, metadata)
    }

    mutating func declareLexicalVariable(
        _ ident: JSC.JSParseIdentifier,
        isConstant: Bool,
        importType: DeclarationImportType = .notImported,
        isUsing: Bool = false,
        isAwaitUsing: Bool = false,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        assert(allowsLexicalDeclarations)
        var result = DeclarationResult.valid
        let isValidStrictMode = !ident.isEvalOrArguments(&facade)
        self.isValidStrictMode = self.isValidStrictMode && isValidStrictMode
        var traits: VariableTraits = isConstant ? .const : .let
        if isUsing {
            traits.insert(.using)
        }
        switch importType {
        case .imported:
            traits.insert(.imported)
        case .importedNamespace:
            traits.formUnion([.imported, .importedNamespace])
        case .notImported:
            break
        }
        let isNewEntry = facade.environmentAdd(storage, .Lexical, ident, traits.rawValue)
        if isAwaitUsing {
            facade.setHasAwaitUsingDeclaration(storage)
        }

        if !isNewEntry || facade.nameSetContains(storage, .VariablesBeingHoisted, ident) {
            result.insert(.invalidDuplicateDeclaration)
        }
        if !isValidStrictMode {
            result.insert(.invalidStrictMode)
        }

        return result
    }

    func hasDeclaredGlobalArguments(_ facade: inout JSC.JSParseFacade) -> Bool {
        let ident = facade.wellKnownIdentifier(.arguments)
        return hasLexicallyDeclaredVariable(ident, &facade) || hasDeclaredVariable(ident, &facade) || shadowsArguments
    }

    /// The entry for `ident` in one of the scope's environments, or nil when there is none.
    @inline(always)
    func environmentEntry(
        _ kind: JSC.JSParseEnvironmentKind,
        _ ident: JSC.JSParseIdentifier,
        _ facade: inout JSC.JSParseFacade
    ) -> VariableTraits? {
        guard let traits = Optional(fromCxx: facade.environmentTraits(storage, kind, ident)) else {
            return nil
        }
        return VariableTraits(rawValue: traits)
    }

    func hasDeclaredVariable(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        // The callee isn't a "var".
        environmentEntry(.Declared, ident, &facade)?.contains(.var) ?? false
    }

    func hasLexicallyDeclaredVariable(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        facade.environmentContains(storage, .Lexical, ident)
    }

    func hasVariableBeingHoisted(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        facade.nameSetContains(storage, .VariablesBeingHoisted, ident)
    }

    func hasPrivateName(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        facade.hasPrivateName(storage, ident)
    }

    func declarePrivateMethod(
        _ ident: JSC.JSParseIdentifier,
        _ tag: JSC.ClassElementTag,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        assert(allowsLexicalDeclarations)
        return facade.declarePrivateMethod(storage, ident, tag == .Static) ? .valid : .invalidDuplicateDeclaration
    }

    enum PrivateAccessorType {
        case setter
        case getter
    }

    func declarePrivateAccessor(
        _ ident: JSC.JSParseIdentifier,
        _ tag: JSC.ClassElementTag,
        _ accessorType: PrivateAccessorType,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        var result = DeclarationResult.valid
        let addResult = facade.declarePrivateAccessor(storage, ident, accessorType == .setter, tag == .Static)
        switch addResult {
        case .DuplicatedName:
            result.insert(.invalidDuplicateDeclaration)
        case .InvalidStaticNonStatic:
            result.insert(.invalidPrivateStaticNonStatic)
        default:
            break
        }
        return result
    }

    func declarePrivateSetter(
        _ ident: JSC.JSParseIdentifier,
        _ tag: JSC.ClassElementTag,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        assert(allowsLexicalDeclarations)
        return declarePrivateAccessor(ident, tag, .setter, &facade)
    }

    func declarePrivateGetter(
        _ ident: JSC.JSParseIdentifier,
        _ tag: JSC.ClassElementTag,
        _ facade: inout JSC.JSParseFacade
    ) -> DeclarationResult {
        assert(allowsLexicalDeclarations)
        return declarePrivateAccessor(ident, tag, .getter, &facade)
    }

    func declarePrivateField(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        assert(allowsLexicalDeclarations)
        return facade.declarePrivateField(storage, ident) ? .valid : .invalidDuplicateDeclaration
    }

    func hasDeclaredParameter(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        facade.nameSetContains(storage, .DeclaredParameters, ident) || hasDeclaredVariable(ident, &facade)
    }

    mutating func declareParameter(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> DeclarationResult {
        assert(allowsVarDeclarations)
        var result = DeclarationResult.valid
        let isArgumentsIdent = ident.matches(.arguments, &facade)
        let isDuplicateParameter = environmentEntry(.Declared, ident, &facade)?.contains(.parameter) ?? false
        let isValidStrictMode =
            !isDuplicateParameter && !ident.matches(.eval, &facade) && !isArgumentsIdent && !ident.isStrictModeReservedWord(&facade)
        _ = facade.environmentAdd(storage, .Declared, ident, VariableTraits.parameter.rawValue)
        facade.environmentClearIsVar(storage, .Declared, ident)
        self.isValidStrictMode = self.isValidStrictMode && isValidStrictMode
        _ = facade.nameSetAdd(storage, .DeclaredParameters, ident)
        if !isValidStrictMode {
            result.insert(.invalidStrictMode)
        }
        if isArgumentsIdent {
            shadowsArguments = true
        }
        if isDuplicateParameter {
            result.insert(.invalidDuplicateDeclaration)
        }

        return result
    }

    // MARK: Used variables

    func usedVariablesContains(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) -> Bool {
        facade.usedVariablesContains(storage, ident)
    }

    @inline(always)
    mutating func useVariable(_ ident: JSC.JSParseIdentifier, isEval: Bool, _ facade: inout JSC.JSParseFacade) {
        usesEval = usesEval || isEval
        facade.useVariable(storage, ident)
    }

    func usePrivateName(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) {
        facade.useVariable(storage, ident)
    }

    func pushUsedVariableSet(_ facade: inout JSC.JSParseFacade) {
        facade.pushUsedVariableSet(storage)
    }

    func currentUsedVariablesSize(_ facade: inout JSC.JSParseFacade) -> UInt32 {
        facade.usedVariableSetCount(storage)
    }

    func revertToPreviousUsedVariables(_ size: UInt32, _ facade: inout JSC.JSParseFacade) {
        facade.revertToPreviousUsedVariables(storage, size)
    }

    func mergeIntoPreviousUsedVariables(_ size: UInt32, _ facade: inout JSC.JSParseFacade) {
        assert(size != 0)
        facade.mergeIntoPreviousUsedVariables(storage, size)
    }

    func addClosedVariableCandidateUnconditionally(_ ident: JSC.JSParseIdentifier, _ facade: inout JSC.JSParseFacade) {
        _ = facade.nameSetAdd(storage, .ClosedVariableCandidates, ident)
    }

    func markLastUsedVariablesSetAsCaptured(_ from: UInt32, _ facade: inout JSC.JSParseFacade) {
        facade.markLastUsedVariablesSetAsCaptured(storage, from)
    }

    // MARK: Sloppy mode function hoisting

    func hasSloppyModeFunctionHoistingCandidates(_ facade: inout JSC.JSParseFacade) -> Bool {
        facade.hasSloppyModeFunctionHoistingCandidates(storage)
    }

    func finalizeSloppyModeFunctionHoisting(_ facade: inout JSC.JSParseFacade) {
        assert(allowsVarDeclarations)
        assert(!isSimpleCatchParameterScope)
        facade.finalizeSloppyModeFunctionHoisting(storage)
    }

    // MARK: The SourceProviderCache

    /// Copies the scope's flags into the cache item; the facade copies its free and captured variables.
    func fillParametersForSourceProviderCache(_ parameters: inout JSC.JSParseCachedFunction) {
        assert(isFunction)
        parameters.usesEval = usesEval
        parameters.usesImportMeta = usesImportMeta
        parameters.lexicallyScopedFeatures = lexicallyScopedFeatures.rawValue
        parameters.needsFullActivation = needsFullActivation
        parameters.innerArrowFunctionFeatures = innerArrowFunctionFeatures.rawValue
        parameters.needsSuperBinding = needsSuperBinding
    }

    /// Restores the flags from a cached function; findCachedFunction restored its used variables.
    mutating func restoreFromSourceProviderCache(_ info: JSC.JSParseCachedFunction) {
        assert(isFunction)
        usesEval = info.usesEval
        usesImportMeta = info.usesImportMeta
        lexicallyScopedFeatures = LexicallyScopedFeatureSet(rawValue: info.lexicallyScopedFeatures)
        innerArrowFunctionFeatures = InnerArrowFunctionFeatures(rawValue: info.innerArrowFunctionFeatures)
        implementationVisibility = info.implementationVisibility
        needsFullActivation = info.needsFullActivation
        needsSuperBinding = info.needsSuperBinding
    }
}
