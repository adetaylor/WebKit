// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// Rollback checklist: every long-lived holder of IDs has a rule in `rollback(_:)`. The call graph and the overrides hold
// only IDs below every floor (staticCheck state, written outside any scope); the TypeStore, the override validations and
// the ConstantTable are truncated. A new holder needs a rule there.

/// The C++ `m_uses*` helper flags (WGSLShaderModule.h:70-162).
///
/// They are set in prepare (GlobalVariableRewriter, BoundsCheck) and cleared by the Metal writer, and never rolled back.
@_spi(Testing)
public struct UsesFlags: OptionSet, BitwiseCopyable, Hashable, Sendable {
    @_spi(Testing)
    public let rawValue: UInt32

    @_spi(Testing)
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    @_spi(Testing)
    public static let externalTextures = UsesFlags(rawValue: 1 << 0)
    @_spi(Testing)
    public static let packArray = UsesFlags(rawValue: 1 << 1)
    @_spi(Testing)
    public static let unpackArray = UsesFlags(rawValue: 1 << 2)
    @_spi(Testing)
    public static let packVector = UsesFlags(rawValue: 1 << 3)
    @_spi(Testing)
    public static let unpackVector = UsesFlags(rawValue: 1 << 4)
    @_spi(Testing)
    public static let workgroupUniformLoad = UsesFlags(rawValue: 1 << 5)
    @_spi(Testing)
    public static let workgroupUniformLoadAtomic = UsesFlags(rawValue: 1 << 6)
    @_spi(Testing)
    public static let division = UsesFlags(rawValue: 1 << 7)
    @_spi(Testing)
    public static let modulo = UsesFlags(rawValue: 1 << 8)
    @_spi(Testing)
    public static let frexp = UsesFlags(rawValue: 1 << 9)
    @_spi(Testing)
    public static let modf = UsesFlags(rawValue: 1 << 10)
    @_spi(Testing)
    public static let atomicCompareExchange = UsesFlags(rawValue: 1 << 11)
    @_spi(Testing)
    public static let fragDepth = UsesFlags(rawValue: 1 << 12)
    @_spi(Testing)
    public static let dot = UsesFlags(rawValue: 1 << 13)
    @_spi(Testing)
    public static let firstLeadingBit = UsesFlags(rawValue: 1 << 14)
    @_spi(Testing)
    public static let firstTrailingBit = UsesFlags(rawValue: 1 << 15)
    @_spi(Testing)
    public static let sign = UsesFlags(rawValue: 1 << 16)
    @_spi(Testing)
    public static let sampleMask = UsesFlags(rawValue: 1 << 17)
    @_spi(Testing)
    public static let frontFacing = UsesFlags(rawValue: 1 << 18)
    @_spi(Testing)
    public static let sampleIndex = UsesFlags(rawValue: 1 << 19)
    @_spi(Testing)
    public static let dot4I8Packed = UsesFlags(rawValue: 1 << 20)
    @_spi(Testing)
    public static let dot4U8Packed = UsesFlags(rawValue: 1 << 21)
    @_spi(Testing)
    public static let extractBits = UsesFlags(rawValue: 1 << 22)
    @_spi(Testing)
    public static let packedVec3 = UsesFlags(rawValue: 1 << 23)
    @_spi(Testing)
    public static let min = UsesFlags(rawValue: 1 << 24)
    @_spi(Testing)
    public static let ftoi = UsesFlags(rawValue: 1 << 25)
    @_spi(Testing)
    public static let insertBits = UsesFlags(rawValue: 1 << 26)
    @_spi(Testing)
    public static let zeroWorkgroupVar = UsesFlags(rawValue: 1 << 27)
}

/// C++ `ShaderModule::OverrideValidator` closures as data: the check and the nodes and types it reads.
///
/// The module stays closure-free, so rollback truncates the list. validateOverrides runs them in registration order.
struct OverrideValidation: Equatable {
    /// GlobalVariableRewriter's `m_shortCircuitedOperators` when the validation was registered (GlobalVariableRewriter.cpp:452-466).
    var guards: [ExpressionID]
    var check: Check

    enum Check: Equatable {
        // BoundsCheck.cpp:152
        case boundsCheckIndex(access: ExpressionID, index: ExpressionID, size: UInt32)
        // BoundsCheck.cpp:220; may replace the access at generate time
        case boundsCheckOverrideIndex(access: ExpressionID, index: ExpressionID, constant: UInt32?, sizeExpression: ExpressionID?)
        // GlobalVariableRewriter.cpp:471, :1242
        case ensureOverrideValue(ExpressionID)
        // GlobalVariableRewriter.cpp:665; pack() may wrap the binary afterwards, and C++ then still reads its old right operand
        case binaryValidation(ExpressionID, rightExpression: ExpressionID, ValidationFunction)
        // GlobalVariableRewriter.cpp:785
        case callValidation(ExpressionID, ValidationFunction)
        // GlobalVariableRewriter.cpp:1522
        case combinedWorkgroupSize(span: SourceSpan, types: [TypeID], limit: UInt32)
        // GlobalVariableRewriter.cpp:1530
        case combinedPrivateSize(span: SourceSpan, types: [TypeID], limit: UInt32)
    }
}

/// C++ `CompilationScope`, consumed by exactly one `rollback(_:)`; scopes are rolled back innermost first.
///
/// Only `ShaderModule.openScope(_:)` makes one, and only ModuleState.swift can pass it the capability it needs.
struct CompilationScope: ~Copyable {
    fileprivate let depth: Int
}

/// C++ `WGSL::ShaderModule`: the module's source and configuration, every AST node (the C++ `AST::Builder`) in one arena
/// per category, the types, and the module-level state of the passes.
@_spi(Testing)
public struct ShaderModule: ~Copyable {
    @_spi(Testing)
    public let source: SourceText

    @_spi(Testing)
    public let configuration: Configuration

    @_spi(Testing)
    public var uses = UsesFlags()

    /// Starts as a copy of `SymbolTable.predeclared`; append-only, never rolled back (interning is idempotent).
    @_spi(Testing)
    public var symbols = SymbolTable.predeclared

    @_spi(Testing)
    public var types = TypeStore()

    @_spi(Testing)
    public let declarations: ListID<Declaration>

    @_spi(Testing)
    public let directives: ListID<DirectiveID>

    private(set) var overrideValidations: [OverrideValidation] = []

    // staticCheck-only state: written only while no scope is open.
    @_spi(Testing)
    public private(set) var diagnostics = DiagnosticContainer()

    @_spi(Testing)
    public private(set) var enabledExtensions = Extensions()

    @_spi(Testing)
    public private(set) var requiredFeatures = LanguageFeatures()

    private var pipelineOverrideIDs = LookupSet<UInt32>()

    @_spi(Testing)
    public private(set) var overrides: [VariableID] = []

    private var storedCallGraph: CallGraph?

    // AST::Builder: one arena per category; private so nothing can copy an arena or bypass the logging rules.
    private var expressions = ExpressionArena()
    private var constants = ConstantTable()
    private var statements = StatementArena()
    private var functions = Arena<FunctionID, Function>()
    private var variables = Arena<VariableID, Variable>()
    private var structures = Arena<StructureID, Structure>()
    private var structureMembers = Arena<StructureMemberID, StructureMember>()
    private var parameters = Arena<ParameterID, Parameter>()
    private var typeAliases = Arena<TypeAliasID, TypeAlias>()
    private var constAsserts = Arena<ConstAssertID, ConstAssert>()
    private var attributes = Arena<AttributeID, AttributeNode>()
    private var directiveNodes = Arena<DirectiveID, DirectiveNode>()
    private var switchClauses = Arena<SwitchClauseID, SwitchClause>()
    private var identifiers = Arena<IdentifierID, Identifier>()
    private var lists = ListArena()

    private var scopeStack: [ScopeMarks] = []

    #if WGSL_UNOPTIMIZED
    /// Makes ShaderModule (and every pass struct holding it) address-only in -Onone builds.
    ///
    /// Without it unoptimised code copies the module on every borrow through a protocol requirement. Never in -O builds: an
    /// address-only noncopyable value can be miscompiled at -O (a heap use-after-free with Swift 6.4 and 6.5).
    private let addressOnly: Any = ()
    #endif

    private struct ScopeMarks {
        let expressions: ExpressionArena.Mark
        let constants: ConstantTable.Mark
        let statements: StatementArena.Mark
        let functions: Arena<FunctionID, Function>.Mark
        let variables: Arena<VariableID, Variable>.Mark
        let structures: Arena<StructureID, Structure>.Mark
        let structureMembers: Arena<StructureMemberID, StructureMember>.Mark
        let parameters: Arena<ParameterID, Parameter>.Mark
        let typeAliases: Arena<TypeAliasID, TypeAlias>.Mark
        let constAsserts: Arena<ConstAssertID, ConstAssert>.Mark
        let attributes: Arena<AttributeID, AttributeNode>.Mark
        let directiveNodes: Arena<DirectiveID, DirectiveNode>.Mark
        let switchClauses: Arena<SwitchClauseID, SwitchClause>.Mark
        let identifiers: Arena<IdentifierID, Identifier>.Mark
        let lists: ListArena.Mark
        let types: TypeStore.Mark
        let overrideValidationsSize: Int
    }

    @_spi(Testing)
    public init(source: SourceText, configuration: Configuration = Configuration()) {
        self.source = source
        self.configuration = configuration
        declarations = lists.makeEmpty(Declaration.self)
        directives = lists.makeEmpty(DirectiveID.self)
    }

    @_spi(Testing)
    public mutating func reserveCapacity(
        expressions expressionCount: Int,
        statements statementCount: Int,
        identifiers identifierCount: Int,
        lists listCount: Int = 0,
        listElements listElementCount: Int = 0
    ) {
        expressions.reserveCapacity(expressionCount)
        statements.reserveCapacity(statementCount)
        identifiers.reserveCapacity(identifierCount)
        if listCount > 0 || listElementCount > 0 {
            lists.reserveCapacity(lists: listCount, words: listElementCount)
        }
    }
}

// MARK: - Call graph

extension ShaderModule {
    /// `m_callGraph`, set by buildCallGraph; reading it before is fatal (C++ derefs the empty optional).
    @_spi(Testing)
    public var callGraph: CallGraph {
        _read {
            switch storedCallGraph {
            case .some(let callGraph):
                yield callGraph
            case .none:
                wgslFatal("callGraph() before buildCallGraph", cppSite: "WGSLShaderModule.h:66")
            }
        }
    }

    @_spi(Testing)
    public mutating func setCallGraph(_ callGraph: consuming CallGraph) {
        checkNoOpenScope("WGSLShaderModule.h:67")
        storedCallGraph = consume callGraph
    }

    /// IOValidator's writes of `usedGlobals` and `textureSamplerPairs` (C++ writes through the const graph).
    @_spi(Testing)
    public mutating func modifyCallGraph<R>(_ body: (inout CallGraph) -> R) -> R {
        checkNoOpenScope("CallGraph.h:63")
        guard var callGraph = storedCallGraph.take() else {
            wgslFatal("callGraph() before buildCallGraph", cppSite: "WGSLShaderModule.h:66")
        }
        let result = body(&callGraph)
        storedCallGraph = consume callGraph
        return result
    }

    @_spi(Testing)
    public var isInCompilationScope: Bool { !scopeStack.isEmpty }

    private func checkNoOpenScope(_ cppSite: StaticString) {
        guard scopeStack.isEmpty else {
            wgslFatal("staticCheck-only module state written inside a CompilationScope", cppSite: cppSite)
        }
    }
}

// MARK: - Replacement (C++ ShaderModule::replace and friend writes)

extension ShaderModule {
    /// The C++ overload rule of `replace(current, replacement)` (WGSLShaderModule.h:183-205).
    ///
    /// C++ picks it from the static types at the call site: IdentityExpression wrapping, overload (3), iff sizeof(Current) <
    /// sizeof(Replacement) or the replacement is typed `AST::Expression&`; else copy-into-storage, overload (4). Every C++
    /// site downcasts first, so the dynamic tags give the same choice.
    @_spi(Testing)
    public static func replaceWraps(
        _ current: ExpressionKindTag,
        _ replacement: ExpressionKindTag,
        replacementIsTypedAsExpressionBase: Bool = false
    ) -> Bool {
        replacementIsTypedAsExpressionBase || current.cppSizeof < replacement.cppSizeof
    }

    /// C++ `replace(current, replacement)` for expressions; the old slot and its constant value are logged.
    @_spi(Testing)
    public mutating func replace(_ current: ExpressionID, with replacement: ExpressionID, replacementIsTypedAsExpressionBase: Bool = false)
    {
        // DEV-19: like every logged write, this records an undo only inside a scope; C++ keeps staticCheck's closures forever.
        let replacementNode = expressions[replacement]
        if ShaderModule.replaceWraps(
            expressions[current].kind.tag,
            replacementNode.kind.tag,
            replacementIsTypedAsExpressionBase: replacementIsTypedAsExpressionBase
        ) {
            // (3): an IdentityExpression(replacement.span(), replacement): the replacement's span and inferred type, no
            // evaluation and no constant value. Later replacements of `replacement` stay visible through it.
            var node = ExpressionNode(kind: .identityExpression(IdentityExpression(expression: replacement)), span: replacementNode.span)
            node.inferredType = replacementNode.inferredType
            expressions.overwrite(current, with: node)
            constants.setLogged(nil, for: current)
        } else {
            // (4): a copy of the replacement: kind, span, inferred type, evaluation and constant value, with its own
            // identifier slots (C++ copies Identifier members by value).
            let copy = cloningIdentifierSlots(of: replacementNode)
            expressions.overwrite(current, with: copy)
            constants.setLogged(constants.value(replacement), for: current)
        }
    }

    /// C++ overload (1), `replace(&identifier, Identifier(...))` (MangleNames).
    @_spi(Testing)
    public mutating func replace(_ identifier: IdentifierID, with replacement: Identifier) {
        identifiers.overwrite(identifier, with: replacement)
    }

    /// C++ `replace(&name, AST::Identifier::makeWithSpan(name.span(), text))`.
    @_spi(Testing)
    public mutating func replace(_ identifier: IdentifierID, keepingSpanWith symbol: Symbol) {
        identifiers.overwrite(identifier, with: Identifier(span: identifiers[identifier].span, symbol: symbol))
    }

    // C++ overload (2), fundamentals and enums (`replace(&global.role(), PackedResource)`), and the friend writes
    // (`call.m_isConstructor = true`): `modify`, logged when the node predates the open scope. `let` fields cannot change.

    @_spi(Testing)
    public mutating func modify(_ expression: ExpressionID, _ body: (inout ExpressionNode) -> Void) {
        expressions.update(expression, body)
    }

    @_spi(Testing)
    public mutating func modify<P: ExpressionPayload>(_: P.Type, _ expression: ExpressionID, _ body: (inout P) -> Void) {
        expressions.update(expression) { node in
            guard var payload = P(node.kind) else {
                wgslFatal("modify of the wrong expression kind", cppSite: "TypeCasts.h:112")
            }
            body(&payload)
            node.kind = payload.expressionKind
        }
    }

    @_spi(Testing)
    public mutating func modify(_ statement: StatementID, _ body: (inout StatementNode) -> Void) {
        statements.update(statement, body)
    }

    @_spi(Testing)
    public mutating func modify<P: StatementPayload>(_: P.Type, _ statement: StatementID, _ body: (inout P) -> Void) {
        statements.update(statement) { node in
            guard var payload = P(node.kind) else {
                wgslFatal("modify of the wrong statement kind", cppSite: "TypeCasts.h:112")
            }
            body(&payload)
            node.kind = payload.statementKind
        }
    }

    @_spi(Testing)
    public mutating func modify(_ attribute: AttributeID, _ body: (inout AttributeNode) -> Void) {
        attributes.update(attribute, body)
    }

    @_spi(Testing)
    public mutating func modify<P: AttributePayload>(_: P.Type, _ attribute: AttributeID, _ body: (inout P) -> Void) {
        attributes.update(attribute) { node in
            guard var payload = P(node.kind) else {
                wgslFatal("modify of the wrong attribute kind", cppSite: "TypeCasts.h:112")
            }
            body(&payload)
            node.kind = payload.attributeKind
        }
    }

    @_spi(Testing)
    public mutating func modify(_ function: FunctionID, _ body: (inout Function) -> Void) {
        functions.update(function, body)
    }

    @_spi(Testing)
    public mutating func modify(_ variable: VariableID, _ body: (inout Variable) -> Void) {
        variables.update(variable, body)
    }

    @_spi(Testing)
    public mutating func modify(_ structure: StructureID, _ body: (inout Structure) -> Void) {
        structures.update(structure, body)
    }

    @_spi(Testing)
    public mutating func modify(_ member: StructureMemberID, _ body: (inout StructureMember) -> Void) {
        structureMembers.update(member, body)
    }

    @_spi(Testing)
    public mutating func modify(_ parameter: ParameterID, _ body: (inout Parameter) -> Void) {
        parameters.update(parameter, body)
    }

    @_spi(Testing)
    public mutating func modify(_ alias: TypeAliasID, _ body: (inout TypeAlias) -> Void) {
        typeAliases.update(alias, body)
    }

    @_spi(Testing)
    public mutating func modify(_ assertion: ConstAssertID, _ body: (inout ConstAssert) -> Void) {
        constAsserts.update(assertion, body)
    }

    @_spi(Testing)
    public mutating func modify(_ clause: SwitchClauseID, _ body: (inout SwitchClause) -> Void) {
        switchClauses.update(clause, body)
    }

    // A copy of an expression slot whose Identifier members get slots of their own, as C++ copies them by value.
    private mutating func cloningIdentifierSlots(of node: ExpressionNode) -> ExpressionNode {
        var copy = node
        switch node.kind {
        case .identifierExpression(let expression):
            copy.kind = .identifierExpression(IdentifierExpression(identifier: cloneIdentifier(expression.identifier)))
        case .fieldAccessExpression(let expression):
            copy.kind = .fieldAccessExpression(
                FieldAccessExpression(
                    base: expression.base,
                    fieldName: cloneIdentifier(expression.fieldName),
                    originalFieldName: cloneIdentifier(expression.originalFieldName)
                )
            )
        case .elaboratedTypeExpression(let expression):
            copy.kind = .elaboratedTypeExpression(
                ElaboratedTypeExpression(base: cloneIdentifier(expression.base), arguments: expression.arguments)
            )
        case .abstractFloatLiteral, .abstractIntegerLiteral, .binaryExpression, .boolLiteral, .callExpression, .float32Literal,
            .float16Literal, .identityExpression, .indexAccessExpression, .checkedIndexAccessExpression,
            .pointerDereferenceExpression, .signed32Literal, .unaryExpression, .unsigned32Literal, .arrayTypeExpression,
            .referenceTypeExpression:
            break
        }
        return copy
    }

    private mutating func cloneIdentifier(_ identifier: IdentifierID) -> IdentifierID {
        let value = identifiers[identifier]
        return identifiers.append(value)
    }
}

// MARK: - Lists (C++ `const Vector&` + `const_cast` helpers)

extension ShaderModule {
    @_spi(Testing)
    public mutating func takeLast<T: ListElement>(_ list: ListID<T>) -> T {
        lists.takeLast(list)
    }

    @_spi(Testing)
    public mutating func append<T: ListElement>(_ list: ListID<T>, _ value: T) {
        lists.append(list, value)
    }

    @_spi(Testing)
    public mutating func insert<T: ListElement>(_ list: ListID<T>, _ position: Int, _ value: T) {
        lists.insert(list, position, value)
    }

    @_spi(Testing)
    public mutating func insertVector<T: ListElement>(_ list: ListID<T>, _ position: Int, _ values: [T]) {
        lists.insertVector(list, position, values)
    }

    @_spi(Testing)
    public mutating func remove<T: ListElement>(_ list: ListID<T>, _ position: Int) {
        lists.remove(list, position)
    }

    @_spi(Testing)
    public mutating func clear<T: ListElement>(_ list: ListID<T>) {
        lists.clear(list)
    }

    /// C++ `list[index] = value` on a list the pass owns.
    @_spi(Testing)
    public mutating func set<T: ListElement>(_ list: ListID<T>, _ index: Int, _ value: T) {
        lists.set(list, index, value)
    }

    @_spi(Testing)
    public mutating func makeList<T: ListElement>(_ elements: [T]) -> ListID<T> {
        lists.make(elements)
    }

    @_spi(Testing)
    public mutating func makeEmptyList<T: ListElement>(_: T.Type) -> ListID<T> {
        lists.makeEmpty(T.self)
    }

    @_spi(Testing)
    @inline(__always)
    public func count<T: ListElement>(_ list: ListID<T>) -> Int {
        lists.count(list)
    }

    @_spi(Testing)
    @inline(__always)
    public func count(_ list: ListID<ExpressionID>) -> Int {
        lists.count(list)
    }

    @_spi(Testing)
    @inline(__always)
    public func count(_ list: ListID<StatementID>) -> Int {
        lists.count(list)
    }

    @_spi(Testing)
    @inline(__always)
    public func count(_ list: ListID<AttributeID>) -> Int {
        lists.count(list)
    }

    @_spi(Testing)
    @inline(__always)
    public func count(_ list: ListID<Declaration>) -> Int {
        lists.count(list)
    }

    @_spi(Testing)
    @inline(__always)
    public subscript<T: ListElement>(list: ListID<T>, index: Int) -> T {
        lists[list, index]
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(list: ListID<ExpressionID>, index: Int) -> ExpressionID {
        lists[list, index]
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(list: ListID<StatementID>, index: Int) -> StatementID {
        lists[list, index]
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(list: ListID<AttributeID>, index: Int) -> AttributeID {
        lists[list, index]
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(list: ListID<Declaration>, index: Int) -> Declaration {
        lists[list, index]
    }

    /// A copy of the list, for the sites where C++ copies the vector.
    @_spi(Testing)
    public func elements<T: ListElement>(_ list: ListID<T>) -> [T] {
        lists.elements(list)
    }

    /// C++ range-for over a node's list; see `ListCursor`.
    @_spi(Testing)
    @inline(__always)
    public func cursor<T: ListElement>(_ list: ListID<T>) -> ListCursor<T> {
        lists.cursor(list)
    }

    @_spi(Testing)
    @inline(__always)
    public func next<T: ListElement>(_ cursor: inout ListCursor<T>) -> T? {
        lists.next(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func next(_ cursor: inout ListCursor<ExpressionID>) -> ExpressionID? {
        lists.next(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func next(_ cursor: inout ListCursor<StatementID>) -> StatementID? {
        lists.next(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func next(_ cursor: inout ListCursor<AttributeID>) -> AttributeID? {
        lists.next(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func next(_ cursor: inout ListCursor<Declaration>) -> Declaration? {
        lists.next(&cursor)
    }

    /// `next(&cursor)` for a cursor that is not at its end (`while !cursor.isAtEnd`). The default traversal reads the module
    /// through the ASTVisitor requirement, whose read accessor copies the module unless the optimizer inlines it, and it does
    /// not inline an access that `next`'s early exit splits.
    @_spi(Testing)
    @inline(__always)
    public func advance<T: ListElement>(_ cursor: inout ListCursor<T>) -> T {
        lists.advance(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func advance(_ cursor: inout ListCursor<ExpressionID>) -> ExpressionID {
        lists.advance(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func advance(_ cursor: inout ListCursor<StatementID>) -> StatementID {
        lists.advance(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func advance(_ cursor: inout ListCursor<AttributeID>) -> AttributeID {
        lists.advance(&cursor)
    }

    @_spi(Testing)
    @inline(__always)
    public func advance(_ cursor: inout ListCursor<Declaration>) -> Declaration {
        lists.advance(&cursor)
    }
}

// MARK: - Extensions, features and override IDs

extension ShaderModule {
    /// C++ `enabledExtensions().add(extension)` (Parser.cpp:439).
    @_spi(Testing)
    public mutating func enableExtension(_ newExtension: Extension) {
        checkNoOpenScope("Parser.cpp:439")
        enabledExtensions.insert(Extensions(newExtension))
    }

    /// C++ `requiredFeatures().add(feature)` (Parser.cpp:459).
    @_spi(Testing)
    public mutating func addRequiredFeature(_ feature: LanguageFeature) {
        checkNoOpenScope("Parser.cpp:459")
        requiredFeatures.insert(LanguageFeatures(feature))
    }

    @_spi(Testing)
    @inline(__always)
    public func containsOverrideID(_ idValue: UInt32) -> Bool {
        pipelineOverrideIDs.contains(idValue)
    }

    @_spi(Testing)
    public mutating func addOverrideID(_ idValue: UInt32) {
        checkNoOpenScope("WGSLShaderModule.h:287")
        pipelineOverrideIDs.add(idValue)
    }

    @_spi(Testing)
    @inline(__always)
    public func hasFeature(_ feature: Features) -> Bool {
        configuration.supportedFeatures.contains(feature)
    }

    /// The module's `DiagnosticContainer` base.
    @_spi(Testing)
    public func severityFor(_ rule: TriggeringRule) -> SeverityControl? {
        diagnostics.severityFor(rule)
    }

    @_spi(Testing)
    public mutating func setSeverityFor(_ rule: TriggeringRule, _ severity: SeverityControl) {
        checkNoOpenScope("ASTDiagnostic.h:44")
        diagnostics.setSeverityFor(rule, severity)
    }
}

// MARK: - Overrides and override validation

extension ShaderModule {
    mutating func addOverrideValidation(_ validation: OverrideValidation) {
        overrideValidations.append(validation)
    }

    @_spi(Testing)
    public var currentOverrideValidationsSize: Int { overrideValidations.count }

    /// Registers an `ensureOverrideValue` validation, for the rollback tests (the Check cases are internal).
    @_spi(Testing)
    public mutating func addOverrideValidationForTesting(ensuringOverrideValueOf expression: ExpressionID, guards: [ExpressionID]) {
        addOverrideValidation(OverrideValidation(guards: guards, check: .ensureOverrideValue(expression)))
    }

    // lookupOverload is an index into the process-global builtin table (Overload.swift); releaseOverloadCandidates has no
    // counterpart.

    @_spi(Testing)
    public mutating func addOverride(_ variable: VariableID) {
        checkNoOpenScope("WGSLShaderModule.h:322")
        overrides.append(variable)
    }

    mutating func ensureOverrideValue(
        _ expression: ExpressionID,
        _ overrideValues: OverrideValues
    ) -> Result<ConstantValue, CompilationMessage> {
        guard let maybeValue = evaluate(&self, expression, overrideValues) else {
            return .failure(CompilationMessage(text: "Failed to evaluate override value", span: span(of: expression)))
        }
        return .success(maybeValue)
    }

    /// `entryPoints` stands for the C++ PrepareResult, of which validateOverrides reads only the entry points.
    mutating func validateOverrides(_ entryPoints: [EntryPointInformation], _ overrideValues: inout OverrideValues) -> CompilationMessage? {
        // C++ `specializationConstants` is a HashMap: the keys of every entry point, for the isUsed lookups.
        var specializationConstantKeys = LookupSet<Name>()
        if !overrides.isEmpty {
            var entryPointIndex = 0
            while entryPointIndex < entryPoints.count {
                let constants = entryPoints[entryPointIndex].specializationConstants
                var constantIndex = 0
                while constantIndex < constants.count {
                    specializationConstantKeys.add(constants[constantIndex].key)
                    constantIndex += 1
                }
                entryPointIndex += 1
            }
            overrideValues.reserveInitialCapacity(overrideValues.count + overrides.count)
        }
        var overrideIndex = 0
        while overrideIndex < overrides.count {
            let variable = self[overrides[overrideIndex]]
            overrideIndex += 1
            let name: Name =
                if let id = variable.id {
                    Name(utf16: ("\(id)" as MessageText).codeUnits)
                } else {
                    symbols.cachedName(of: symbol(of: variable.originalName))
                }
            if let value = overrideValues.find(name) {
                overrideValues.remove(name)
                overrideValues.add(symbols.cachedName(of: symbol(of: variable.name)), value)
                continue
            }

            let isUsed = specializationConstantKeys.contains(name)

            if !isUsed {
                continue
            }

            guard let initializer = variable.maybeInitializer else {
                if isUsed {
                    return CompilationMessage(
                        text: "override \(symbols.text(of: symbol(of: variable.originalName))) is used in shader but not provided",
                        span: variable.span
                    )
                }
                continue
            }

            switch ensureOverrideValue(initializer, overrideValues) {
            case .failure(let error):
                return error
            case .success(let maybeValue):
                overrideValues.add(symbols.cachedName(of: symbol(of: variable.name)), maybeValue)
            }
        }

        var validationIndex = 0
        while validationIndex < overrideValidations.count {
            if let maybeError = runOverrideValidation(overrideValidations[validationIndex], overrideValues) {
                return maybeError
            }
            validationIndex += 1
        }

        return nil
    }

    @_spi(Testing)
    @inline(__always)
    public func containsOverride(_ key: Name) -> Bool {
        var overrideIndex = 0
        while overrideIndex < overrides.count {
            let variable = self[overrides[overrideIndex]]
            let name: Name =
                if let id = variable.id {
                    Name(utf16: ("\(id)" as MessageText).codeUnits)
                } else {
                    symbols.name(of: symbol(of: variable.originalName))
                }
            if name == key {
                return true
            }
            overrideIndex += 1
        }
        return false
    }
}

// MARK: - AST::Builder (C++ `astBuilder().construct<T>(span, args...)`)

extension ShaderModule {
    /// C++ `AST::Identifier::make` / `makeWithSpan`: a value; the constructor that receives it makes its slot.
    @_spi(Testing)
    public func makeIdentifier(_ symbol: Symbol, span: SourceSpan = .empty) -> Identifier {
        Identifier(span: span, symbol: symbol)
    }

    @_spi(Testing)
    public mutating func makeIdentifier(_ text: StaticString, span: SourceSpan = .empty) -> Identifier {
        Identifier(span: span, symbol: symbols.intern(text))
    }

    /// The expression kinds whose C++ constructor has no logic and that own no Identifier.
    @_spi(Testing)
    public mutating func construct<P: PlainExpressionPayload>(span: SourceSpan, _ payload: P) -> ExpressionID {
        expressions.append(ExpressionNode(kind: payload.expressionKind, span: span))
    }

    @_spi(Testing)
    public mutating func constructIdentifierExpression(span: SourceSpan, identifier: Identifier) -> ExpressionID {
        let identifierID = identifiers.append(identifier)
        return expressions.append(ExpressionNode(kind: .identifierExpression(IdentifierExpression(identifier: identifierID)), span: span))
    }

    /// The C++ constructor copies `fieldName` into `originalFieldName`.
    @_spi(Testing)
    public mutating func constructFieldAccessExpression(span: SourceSpan, base: ExpressionID, fieldName: Identifier) -> ExpressionID {
        let fieldNameID = identifiers.append(fieldName)
        let originalFieldNameID = identifiers.append(fieldName)
        let payload = FieldAccessExpression(base: base, fieldName: fieldNameID, originalFieldName: originalFieldNameID)
        return expressions.append(ExpressionNode(kind: .fieldAccessExpression(payload), span: span))
    }

    @_spi(Testing)
    public mutating func constructElaboratedTypeExpression(
        span: SourceSpan,
        base: Identifier,
        arguments: ListID<ExpressionID>
    ) -> ExpressionID {
        let baseID = identifiers.append(base)
        let payload = ElaboratedTypeExpression(base: baseID, arguments: arguments)
        return expressions.append(ExpressionNode(kind: .elaboratedTypeExpression(payload), span: span))
    }

    /// The C++ constructor copies the wrapped expression's inferred type.
    @_spi(Testing)
    public mutating func constructIdentityExpression(span: SourceSpan, expression: ExpressionID) -> ExpressionID {
        var node = ExpressionNode(kind: .identityExpression(IdentityExpression(expression: expression)), span: span)
        node.inferredType = expressions[expression].inferredType
        return expressions.append(node)
    }

    /// C++ `construct<decltype(expression)>(expression)` (GlobalVariableRewriter.cpp:520): the slot, a fresh copy of its
    /// constant value and fresh identifier slots; the children are shared.
    @_spi(Testing)
    public mutating func construct(copyOf expression: ExpressionID) -> ExpressionID {
        let copy = cloningIdentifierSlots(of: expressions[expression])
        let value = constants.value(expression)
        let copyID = expressions.append(copy)
        constants.set(value, for: copyID)
        return copyID
    }

    /// Every statement kind but CallStatement; a `CompoundStatement::Ref` child must be a CompoundStatement.
    @_spi(Testing)
    public mutating func construct<P: PlainStatementPayload>(span: SourceSpan, _ payload: P) -> StatementID {
        let kind = payload.statementKind
        switch kind {
        case .forStatement(let statement):
            checkCompound(statement.body, cppSite: "ASTForStatement.h:46")
        case .ifStatement(let statement):
            checkCompound(statement.trueBody, cppSite: "ASTIfStatement.h:44")
        case .whileStatement(let statement):
            checkCompound(statement.body, cppSite: "ASTWhileStatement.h:42")
        case .assignmentStatement, .breakStatement, .callStatement, .compoundAssignmentStatement, .compoundStatement,
            .constAssertStatement, .continueStatement, .decrementIncrementStatement, .discardStatement, .loopStatement,
            .phonyAssignmentStatement, .returnStatement, .switchStatement, .variableStatement:
            break
        }
        return statements.append(StatementNode(kind: kind, span: span))
    }

    @_spi(Testing)
    public mutating func constructCallStatement(span: SourceSpan, call: ExpressionID) -> StatementID {
        guard self.is(CallExpression.self, call) else {
            wgslFatal("a CallStatement's call must be a CallExpression", cppSite: "ASTCallStatement.h:40")
        }
        return statements.append(StatementNode(kind: .callStatement(CallStatement(call: call)), span: span))
    }

    @_spi(Testing)
    public mutating func construct(span: SourceSpan, _ attribute: AttributeKind) -> AttributeID {
        attributes.append(AttributeNode(kind: attribute, span: span))
    }

    @_spi(Testing)
    public mutating func construct(span: SourceSpan, _ directive: DirectiveKind) -> DirectiveID {
        directiveNodes.append(DirectiveNode(kind: directive, span: span))
    }

    @_spi(Testing)
    public mutating func constructFunction(
        span: SourceSpan,
        name: Identifier,
        parameters: ListID<ParameterID>,
        returnType: ExpressionID?,
        body: StatementID,
        attributes: ListID<AttributeID>,
        returnAttributes: ListID<AttributeID>
    ) -> FunctionID {
        checkCompound(body, cppSite: "ASTFunction.h:74")
        let nameID = identifiers.append(name)
        let function = Function(
            span: span,
            name: nameID,
            parameters: parameters,
            maybeReturnType: returnType,
            body: body,
            attributes: attributes,
            returnAttributes: returnAttributes,
            originalName: name.symbol
        )
        return functions.append(function)
    }

    @_spi(Testing)
    public mutating func constructParameter(
        span: SourceSpan,
        name: Identifier,
        typeName: ExpressionID,
        attributes: ListID<AttributeID>,
        role: ParameterRole
    ) -> ParameterID {
        let nameID = identifiers.append(name)
        return parameters.append(Parameter(span: span, name: nameID, typeName: typeName, attributes: attributes, role: role))
    }

    /// The C++ constructor copies the name into `originalName` and takes `storeType` from the type expression or, failing
    /// that, the initializer.
    @_spi(Testing)
    public mutating func constructVariable(
        span: SourceSpan,
        flavor: VariableFlavor,
        name: Identifier,
        qualifier: VariableQualifier? = nil,
        type: ExpressionID?,
        initializer: ExpressionID?,
        attributes: ListID<AttributeID>,
        role: VariableRole = .userDefined
    ) -> VariableID {
        assert(type != nil || initializer != nil)
        let storeType: TypeID?
        if let type {
            storeType = expressions[type].inferredType
        } else if let initializer {
            storeType = expressions[initializer].inferredType
        } else {
            wgslFatal("a variable needs a type or an initializer", cppSite: "ASTVariable.h:110")
        }
        let nameID = identifiers.append(name)
        let originalNameID = identifiers.append(name)
        let variable = Variable(
            span: span,
            flavor: flavor,
            name: nameID,
            maybeQualifier: qualifier,
            maybeTypeName: type,
            maybeInitializer: initializer,
            attributes: attributes,
            role: role,
            originalName: originalNameID,
            storeType: storeType
        )
        return variables.append(variable)
    }

    /// A packed structure (`original` set) copies the original's size and alignment and becomes its `packed`.
    @_spi(Testing)
    public mutating func constructStructure(
        span: SourceSpan,
        name: Identifier,
        members: ListID<StructureMemberID>,
        role: StructureRole,
        original: StructureID? = nil
    ) -> StructureID {
        let nameID = identifiers.append(name)
        var structure = Structure(span: span, name: nameID, members: members, role: role, original: original)
        if let original {
            assert(role == .packedResource)
            structure.size = structures[original].size
            structure.alignment = structures[original].alignment
        }
        let structureID = structures.append(structure)
        if let original {
            // DEV-17: C++ leaves m_packed dangling after the scope's revert; here the write is logged and undone.
            structures.update(original) { $0.packed = structureID }
        }
        return structureID
    }

    @_spi(Testing)
    public mutating func constructStructureMember(
        span: SourceSpan,
        name: Identifier,
        type: ExpressionID,
        attributes: ListID<AttributeID>
    ) -> StructureMemberID {
        let nameID = identifiers.append(name)
        let originalNameID = identifiers.append(name)
        return structureMembers.append(
            StructureMember(span: span, name: nameID, type: type, attributes: attributes, originalName: originalNameID)
        )
    }

    @_spi(Testing)
    public mutating func constructTypeAlias(span: SourceSpan, name: Identifier, type: ExpressionID) -> TypeAliasID {
        let nameID = identifiers.append(name)
        return typeAliases.append(TypeAlias(span: span, name: nameID, type: type))
    }

    @_spi(Testing)
    public mutating func constructConstAssert(span: SourceSpan, test: ExpressionID) -> ConstAssertID {
        constAsserts.append(ConstAssert(span: span, test: test))
    }

    @_spi(Testing)
    public mutating func constructSwitchClause(selectors: ListID<ExpressionID>, body: StatementID) -> SwitchClauseID {
        checkCompound(body, cppSite: "ASTSwitchStatement.h:34")
        return switchClauses.append(SwitchClause(selectors: selectors, body: body))
    }

    // `mutating` although it only reads: a non-mutating call from the generic `construct` copies the module at -O.
    private mutating func checkCompound(_ statement: StatementID, cppSite: StaticString) {
        guard self.is(CompoundStatement.self, statement) else {
            wgslFatal("a CompoundStatement::Ref must be a CompoundStatement", cppSite: cppSite)
        }
    }
}

// MARK: - CompilationScope

extension ShaderModule {
    /// C++ `CompilationScope scope(shaderModule);` (CompilationScope.cpp:32-38).
    ///
    /// The capability exists only in ModuleState.swift.
    mutating func openScope(_: borrowing CompilationScopeCapability) -> CompilationScope {
        let marks = ScopeMarks(
            expressions: expressions.openScope(),
            constants: constants.openScope(expressionCount: expressions.count),
            statements: statements.openScope(),
            functions: functions.openScope(),
            variables: variables.openScope(),
            structures: structures.openScope(),
            structureMembers: structureMembers.openScope(),
            parameters: parameters.openScope(),
            typeAliases: typeAliases.openScope(),
            constAsserts: constAsserts.openScope(),
            attributes: attributes.openScope(),
            directiveNodes: directiveNodes.openScope(),
            switchClauses: switchClauses.openScope(),
            identifiers: identifiers.openScope(),
            lists: lists.openScope(),
            types: types.openScope(),
            overrideValidationsSize: overrideValidations.count
        )
        scopeStack.append(marks)
        return CompilationScope(depth: scopeStack.count)
    }

    /// C++ `~CompilationScope()` (CompilationScope.cpp:50-57), in order: the override validations, then the logged writes
    /// (newest first), then the nodes, types and lists created in the scope (`Builder::restore`).
    ///
    /// The logs are per category: each entry restores one location, and each location belongs to one category.
    mutating func rollback(_ scope: consuming CompilationScope) {
        guard scope.depth == scopeStack.count, let marks = scopeStack.popLast() else {
            wgslFatal("CompilationScopes must be rolled back innermost first", cppSite: "CompilationScope.cpp:50")
        }
        overrideValidations.removeSubrange(marks.overrideValidationsSize...)
        // DEV-07: C++ revertReplacements(0) underflows its size_t loop index; each log here is popped down to its mark.
        expressions.rollback(to: marks.expressions)
        constants.rollback(to: marks.constants)
        statements.rollback(to: marks.statements)
        functions.rollback(to: marks.functions)
        variables.rollback(to: marks.variables)
        structures.rollback(to: marks.structures)
        structureMembers.rollback(to: marks.structureMembers)
        parameters.rollback(to: marks.parameters)
        typeAliases.rollback(to: marks.typeAliases)
        constAsserts.rollback(to: marks.constAsserts)
        attributes.rollback(to: marks.attributes)
        directiveNodes.rollback(to: marks.directiveNodes)
        switchClauses.rollback(to: marks.switchClauses)
        identifiers.rollback(to: marks.identifiers)
        lists.rollback(to: marks.lists)
        types.rollback(to: marks.types)
    }
}

// MARK: - Node access

// A getter returns a copy of the plain-data slot. A whole-slot or annotation write to a node created before the open scope
// traps (it would survive rollback); `modify`, `replace` and the list helpers log instead.
extension ShaderModule {
    @_spi(Testing)
    @inline(__always)
    public subscript(expression: ExpressionID) -> ExpressionNode {
        get { expressions[expression] }
        set { expressions[expression] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(statement: StatementID) -> StatementNode {
        get { statements[statement] }
        set { statements[statement] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(function: FunctionID) -> Function {
        get { functions[function] }
        set { functions[function] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(variable: VariableID) -> Variable {
        get { variables[variable] }
        set { variables[variable] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(structure: StructureID) -> Structure {
        get { structures[structure] }
        set { structures[structure] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(member: StructureMemberID) -> StructureMember {
        get { structureMembers[member] }
        set { structureMembers[member] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(parameter: ParameterID) -> Parameter {
        get { parameters[parameter] }
        set { parameters[parameter] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(alias: TypeAliasID) -> TypeAlias {
        get { typeAliases[alias] }
        set { typeAliases[alias] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(assertion: ConstAssertID) -> ConstAssert {
        get { constAsserts[assertion] }
        set { constAsserts[assertion] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(attribute: AttributeID) -> AttributeNode {
        get { attributes[attribute] }
        set { attributes[attribute] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(directive: DirectiveID) -> DirectiveNode {
        get { directiveNodes[directive] }
        set { directiveNodes[directive] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(clause: SwitchClauseID) -> SwitchClause {
        get { switchClauses[clause] }
        set { switchClauses[clause] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public subscript(identifier: IdentifierID) -> Identifier {
        get { identifiers[identifier] }
        set { identifiers[identifier] = newValue }
    }

    @_spi(Testing)
    @inline(__always)
    public func nodeKind(of expression: ExpressionID) -> NodeKind { expressions[expression].kind.tag.nodeKind }

    @_spi(Testing)
    @inline(__always)
    public func nodeKind(of statement: StatementID) -> NodeKind { statements[statement].kind.tag.nodeKind }

    @_spi(Testing)
    @inline(__always)
    public func nodeKind(of attribute: AttributeID) -> NodeKind { attributes[attribute].kind.tag.nodeKind }

    @_spi(Testing)
    @inline(__always)
    public func tag(of expression: ExpressionID) -> ExpressionKindTag { expressions[expression].kind.tag }

    @_spi(Testing)
    @inline(__always)
    public func tag(of statement: StatementID) -> StatementKindTag { statements[statement].kind.tag }

    @_spi(Testing)
    @inline(__always)
    public func tag(of attribute: AttributeID) -> AttributeKindTag { attributes[attribute].kind.tag }

    @_spi(Testing)
    @inline(__always)
    public func span(of expression: ExpressionID) -> SourceSpan { expressions[expression].span }

    @_spi(Testing)
    @inline(__always)
    public func span(of statement: StatementID) -> SourceSpan { statements[statement].span }

    @_spi(Testing)
    @inline(__always)
    public func span(of attribute: AttributeID) -> SourceSpan { attributes[attribute].span }

    @_spi(Testing)
    @inline(__always)
    public func span(of declaration: Declaration) -> SourceSpan {
        switch declaration {
        case .function(let function): functions[function].span
        case .variable(let variable): variables[variable].span
        case .structure(let structure): structures[structure].span
        case .typeAlias(let alias): typeAliases[alias].span
        case .constAssert(let assertion): constAsserts[assertion].span
        }
    }

    @_spi(Testing)
    @inline(__always)
    public func inferredType(of expression: ExpressionID) -> TypeID? { expressions[expression].inferredType }

    @_spi(Testing)
    @inline(__always)
    public func evaluation(of expression: ExpressionID) -> Evaluation? { expressions[expression].evaluation }

    @_spi(Testing)
    @inline(__always)
    public func symbol(of identifier: IdentifierID) -> Symbol { identifiers[identifier].symbol }

    /// C++ `Declaration::name()`; a ConstAssert has none (ASTConstAssert.h:42).
    @_spi(Testing)
    @inline(__always)
    public func name(of declaration: Declaration) -> IdentifierID {
        switch declaration {
        case .function(let function): functions[function].name
        case .variable(let variable): variables[variable].name
        case .structure(let structure): structures[structure].name
        case .typeAlias(let alias): typeAliases[alias].name
        case .constAssert: wgslFatal("ConstAssert has no name", cppSite: "ASTConstAssert.h:42")
        }
    }

    /// C++ `expression.m_inferredType = type` on a node built in the open scope.
    @_spi(Testing)
    @inline(__always)
    public mutating func setInferredType(_ type: TypeID?, for expression: ExpressionID) {
        expressions.setInferredType(type, for: expression)
    }

    @_spi(Testing)
    public mutating func setEvaluation(_ evaluation: Evaluation?, for expression: ExpressionID) {
        expressions[expression].evaluation = evaluation
    }

    /// `setInferredType` and `setEvaluation` in one write of the node.
    @_spi(Testing)
    @inline(__always)
    public mutating func setInferredType(_ type: TypeID?, evaluation: Evaluation?, for expression: ExpressionID) {
        expressions.setInferredType(type, evaluation: evaluation, for: expression)
    }

    /// C++ `Expression::setConstantValue` from TypeCheck, or on a node built in the open scope.
    @_spi(Testing)
    public mutating func setConstantValue(_ value: consuming ConstantValue?, for expression: ExpressionID) {
        constants.set(value, for: expression)
    }

    @_spi(Testing)
    @inline(__always)
    public mutating func setConstantValue(_ value: consuming ConstantValue, for expression: ExpressionID) {
        constants.set(value, for: expression)
    }

    /// evaluate()'s `const_cast<AST::Expression&>(expression).setConstantValue(*result)` (WGSL.cpp:361): never logged, so
    /// the value survives the rollback of a scope the node predates, as in C++.
    @_spi(Testing)
    public mutating func cacheEvaluatedConstantValue(_ value: ConstantValue, for expression: ExpressionID) {
        constants.setSurvivingRollback(value, for: expression)
    }

    /// The expression's constant value in place, with the module's types, for TypeCheck's conversions: see
    /// `ConstantTable.modifyValue`.
    @_spi(Testing)
    @inline(__always)
    public mutating func modifyConstantValue(
        of expression: ExpressionID,
        _ body: (inout ConstantValue, borrowing TypeStore) -> Bool
    ) -> Bool {
        constants.modifyValue(expression, types, body)
    }

    /// Sizes the constant table for every expression built so far (TypeCheck sets most of their values).
    @_spi(Testing)
    public mutating func reserveConstantSlots() {
        constants.reserveSlots(expressions.count)
    }

    /// `constantValue(of:) != nil`, without copying the value.
    @_spi(Testing)
    @inline(__always)
    public func hasConstantValue(_ expression: ExpressionID) -> Bool { constants.hasValue(expression) }

    /// `Expression::constantValue()` for the staticCheck passes; later readers use the named readers below.
    @_spi(Testing)
    @inline(__always)
    public func constantValue(of expression: ExpressionID) -> ConstantValue? { constants.value(expression) }

    /// BoundsCheck.cpp:68.
    @_spi(Testing)
    @inline(__always)
    public func constantValueForBoundsCheckSkip(_ expression: ExpressionID) -> ConstantValue? { constants.value(expression) }

    /// GlobalVariableRewriter.cpp:1240.
    @_spi(Testing)
    @inline(__always)
    public func constantValueForGlobalValidation(_ expression: ExpressionID) -> ConstantValue? { constants.value(expression) }

    /// Types.cpp:333-335, the size of an override-sized array.
    @_spi(Testing)
    @inline(__always)
    public func constantValueForArrayCount(_ expression: ExpressionID) -> ConstantValue? { constants.value(expression) }

    /// MetalFunctionWriter.cpp:1892, :1921 (expressions), :1066, :1540, :1551, :1562, :1572, :1575 (attributes), :2031, :2402
    /// (builtin arguments).
    @_spi(Testing)
    @inline(__always)
    public func constantValueForWriter(_ expression: ExpressionID) -> ConstantValue? { constants.value(expression) }

    /// WGSL.cpp:191.
    @_spi(Testing)
    @inline(__always)
    public func constantValueForEvaluateSeed(_ expression: ExpressionID) -> ConstantValue? { constants.value(expression) }

    /// The parts of an IndexAccessExpression, checked or not: C++ has one node kind where Swift has two.
    @_spi(Testing)
    public func anyIndexAccess(_ expression: ExpressionID) -> (base: ExpressionID, index: ExpressionID, proof: SubscriptProof?)? {
        switch expressions[expression].kind {
        case .indexAccessExpression(let access):
            (access.base, access.index, nil)
        case .checkedIndexAccessExpression(let access):
            (access.base, access.index, access.proof)
        case .abstractFloatLiteral, .abstractIntegerLiteral, .binaryExpression, .boolLiteral, .callExpression,
            .fieldAccessExpression, .float32Literal, .float16Literal, .identifierExpression, .identityExpression,
            .pointerDereferenceExpression, .signed32Literal, .unaryExpression, .unsigned32Literal, .arrayTypeExpression,
            .elaboratedTypeExpression, .referenceTypeExpression:
            nil
        }
    }

    @_spi(Testing)
    public var expressionCount: Int { expressions.count }

    @_spi(Testing)
    public var statementCount: Int { statements.count }

    @_spi(Testing)
    public var identifierCount: Int { identifiers.count }

    @_spi(Testing)
    public var listCount: Int { lists.listCount }

    @_spi(Testing)
    public var listPoolCount: Int { lists.poolCount }

    /// The logged old values of every category, waiting for the rollback of the open scopes.
    @_spi(Testing)
    public var undoEntryCount: Int {
        expressions.undoCount + statements.undoCount + functions.undoCount + variables.undoCount
            + structures.undoCount + structureMembers.undoCount + parameters.undoCount + typeAliases.undoCount
            + constAsserts.undoCount + attributes.undoCount + directiveNodes.undoCount + switchClauses.undoCount
            + identifiers.undoCount + lists.undoCount
    }
}

// MARK: - Casts (C++ is<>, downcast<>, uncheckedDowncast<>, dynamicDowncast<>)

// `downcast` serves both C++ downcast<> and uncheckedDowncast<>; a mismatch is fatal. An IndexAccessExpression cast
// matches only an unchecked access (see `anyIndexAccess`).
// DEV-14: a mismatched uncheckedDowncast<> is undefined behaviour in release C++; here it traps, as downcast<> does.
extension ShaderModule {
    @_spi(Testing)
    public func `is`<P: ExpressionPayload>(_: P.Type, _ expression: ExpressionID) -> Bool {
        expressions[expression].kind.tag == P.tag
    }

    @_spi(Testing)
    public func downcast<P: ExpressionPayload>(_: P.Type, _ expression: ExpressionID) -> P {
        guard let payload = P(expressions[expression].kind) else {
            wgslFatal("downcast of the wrong expression kind", cppSite: "TypeCasts.h:112")
        }
        return payload
    }

    @_spi(Testing)
    public func dynamicDowncast<P: ExpressionPayload>(_: P.Type, _ expression: ExpressionID) -> P? {
        P(expressions[expression].kind)
    }

    @_spi(Testing)
    public func `is`<P: StatementPayload>(_: P.Type, _ statement: StatementID) -> Bool {
        statements[statement].kind.tag == P.tag
    }

    @_spi(Testing)
    public func downcast<P: StatementPayload>(_: P.Type, _ statement: StatementID) -> P {
        guard let payload = P(statements[statement].kind) else {
            wgslFatal("downcast of the wrong statement kind", cppSite: "TypeCasts.h:112")
        }
        return payload
    }

    @_spi(Testing)
    public func dynamicDowncast<P: StatementPayload>(_: P.Type, _ statement: StatementID) -> P? {
        P(statements[statement].kind)
    }

    @_spi(Testing)
    public func `is`<P: AttributePayload>(_: P.Type, _ attribute: AttributeID) -> Bool {
        attributes[attribute].kind.tag == P.tag
    }

    @_spi(Testing)
    public func downcast<P: AttributePayload>(_: P.Type, _ attribute: AttributeID) -> P {
        guard let payload = P(attributes[attribute].kind) else {
            wgslFatal("downcast of the wrong attribute kind", cppSite: "TypeCasts.h:112")
        }
        return payload
    }

    @_spi(Testing)
    public func dynamicDowncast<P: AttributePayload>(_: P.Type, _ attribute: AttributeID) -> P? {
        P(attributes[attribute].kind)
    }
}

// MARK: - Verification snapshot

/// A value copy of everything a rollback restores, for the rollback tests.
///
/// The symbol table and the `uses` flags are excluded: interning is append-only and idempotent, and the flags are never
/// rolled back. Constant values are compared per ExpressionID, not by table entry.
@_spi(Testing)
public struct ShaderModuleSnapshot: Equatable {
    @_spi(Testing)
    public let nodes: Nodes

    /// The constant value of each expression, in ExpressionID order.
    @_spi(Testing)
    public let constantValues: [ConstantValue?]

    /// Every arena, the list pool, the type store, the override validations and the staticCheck-only state.
    @_spi(Testing)
    public struct Nodes: Equatable {
        fileprivate let expressions: [ExpressionNode]
        fileprivate let statements: [StatementNode]
        fileprivate let functions: [Function]
        fileprivate let variables: [Variable]
        fileprivate let structures: [Structure]
        fileprivate let structureMembers: [StructureMember]
        fileprivate let parameters: [Parameter]
        fileprivate let typeAliases: [TypeAlias]
        fileprivate let constAsserts: [ConstAssert]
        fileprivate let attributes: [AttributeNode]
        fileprivate let directiveNodes: [DirectiveNode]
        fileprivate let switchClauses: [SwitchClause]
        fileprivate let identifiers: [Identifier]
        fileprivate let lists: ListArena.Snapshot
        fileprivate let types: TypeStore.Snapshot
        fileprivate let overrideValidations: [OverrideValidation]
        fileprivate let diagnostics: DiagnosticContainer
        fileprivate let enabledExtensions: Extensions
        fileprivate let requiredFeatures: LanguageFeatures
        fileprivate let overrides: [VariableID]
        fileprivate let scopeDepth: Int
    }
}

extension ShaderModule {
    @_spi(Testing)
    public func snapshot() -> ShaderModuleSnapshot {
        let nodes = ShaderModuleSnapshot.Nodes(
            expressions: expressions.snapshot(),
            statements: statements.snapshot(),
            functions: functions.snapshot(),
            variables: variables.snapshot(),
            structures: structures.snapshot(),
            structureMembers: structureMembers.snapshot(),
            parameters: parameters.snapshot(),
            typeAliases: typeAliases.snapshot(),
            constAsserts: constAsserts.snapshot(),
            attributes: attributes.snapshot(),
            directiveNodes: directiveNodes.snapshot(),
            switchClauses: switchClauses.snapshot(),
            identifiers: identifiers.snapshot(),
            lists: lists.snapshot(),
            types: types.snapshot(),
            overrideValidations: overrideValidations,
            diagnostics: diagnostics,
            enabledExtensions: enabledExtensions,
            requiredFeatures: requiredFeatures,
            overrides: overrides,
            scopeDepth: scopeStack.count
        )
        return ShaderModuleSnapshot(nodes: nodes, constantValues: constants.snapshot(expressionCount: expressions.count))
    }
}

// MARK: - Build configuration

#if WGSL_UNOPTIMIZED
private let isUnoptimizedBuild = true
#else
private let isUnoptimizedBuild = false
#endif

/// Whether WGSL_UNOPTIMIZED, which makes ShaderModule address-only, is set exactly when the module is compiled with -Onone.
@_spi(Testing)
public let buildConfigurationIsConsistent = isUnoptimizedBuild == _isDebugAssertConfiguration()
