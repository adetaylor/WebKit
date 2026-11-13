// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

// MARK: - Statement

/// C++ `OptionSet<Behavior>`.
@_spi(Testing)
public struct Behaviors: OptionSet, BitwiseCopyable, Hashable, Sendable {
    @_spi(Testing)
    public let rawValue: UInt8

    @_spi(Testing)
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    @_spi(Testing)
    public static let `return` = Behaviors(rawValue: 1 << 0)

    @_spi(Testing)
    public static let `break` = Behaviors(rawValue: 1 << 1)

    @_spi(Testing)
    public static let `continue` = Behaviors(rawValue: 1 << 2)

    @_spi(Testing)
    public static let next = Behaviors(rawValue: 1 << 3)
}

/// One statement slot: the C++ `Node` and `Statement` base fields (`DiagnosticContainer` included) plus the kind payload.
@_spi(Testing)
public struct StatementNode: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public var kind: StatementKind

    @_spi(Testing)
    public var span: SourceSpan

    @_spi(Testing)
    public var behaviors = Behaviors()

    @_spi(Testing)
    public var diagnostics = DiagnosticContainer()

    @_spi(Testing)
    public init(kind: StatementKind, span: SourceSpan) {
        self.kind = kind
        self.span = span
    }

    mutating func setBehaviors(_ behaviors: Behaviors) {
        self.behaviors = behaviors
    }
}

// MARK: - Statements

@_spi(Testing)
public struct AssignmentStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let lhs: ExpressionID

    @_spi(Testing)
    public let rhs: ExpressionID

    @_spi(Testing)
    public init(lhs: ExpressionID, rhs: ExpressionID) {
        self.lhs = lhs
        self.rhs = rhs
    }
}

@_spi(Testing)
public struct BreakStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public init() {}
}

@_spi(Testing)
public struct CallStatement: BitwiseCopyable, Equatable {
    /// A CallExpression (C++ `CallExpression::Ref`), checked by `constructCallStatement`.
    @_spi(Testing)
    public let call: ExpressionID

    @_spi(Testing)
    public init(call: ExpressionID) {
        self.call = call
    }
}

@_spi(Testing)
public struct CompoundAssignmentStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let leftExpression: ExpressionID

    @_spi(Testing)
    public let rightExpression: ExpressionID

    @_spi(Testing)
    public let operation: BinaryOperation

    @_spi(Testing)
    public init(leftExpression: ExpressionID, rightExpression: ExpressionID, operation: BinaryOperation) {
        self.leftExpression = leftExpression
        self.rightExpression = rightExpression
        self.operation = operation
    }
}

@_spi(Testing)
public struct CompoundStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let statements: ListID<StatementID>

    @_spi(Testing)
    public init(attributes: ListID<AttributeID>, statements: ListID<StatementID>) {
        self.attributes = attributes
        self.statements = statements
    }
}

@_spi(Testing)
public struct ConstAssertStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let assertion: ConstAssertID

    @_spi(Testing)
    public init(assertion: ConstAssertID) {
        self.assertion = assertion
    }
}

@_spi(Testing)
public struct ContinueStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public var isFromSwitchToContinuing = false

    @_spi(Testing)
    public init() {}

    mutating func setIsFromSwitchToContinuing() {
        isFromSwitchToContinuing = true
    }
}

@_spi(Testing)
public struct DecrementIncrementStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public enum Operation: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
        case decrement
        case increment
    }

    @_spi(Testing)
    public let expression: ExpressionID

    @_spi(Testing)
    public let operation: Operation

    @_spi(Testing)
    public init(expression: ExpressionID, operation: Operation) {
        self.expression = expression
        self.operation = operation
    }
}

func printInternal(_ out: inout MessageText, _ operation: DecrementIncrementStatement.Operation) {
    switch operation {
    case .increment:
        out.append("++")
    case .decrement:
        out.append("--")
    }
}

@_spi(Testing)
public struct DiscardStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public init() {}
}

@_spi(Testing)
public struct ForStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let maybeInitializer: StatementID?

    @_spi(Testing)
    public let maybeTest: ExpressionID?

    @_spi(Testing)
    public let maybeUpdate: StatementID?

    /// A CompoundStatement (C++ `CompoundStatement::Ref`).
    @_spi(Testing)
    public let body: StatementID

    @_spi(Testing)
    public var isInternallyGenerated = false

    @_spi(Testing)
    public init(
        attributes: ListID<AttributeID>,
        maybeInitializer: StatementID?,
        maybeTest: ExpressionID?,
        maybeUpdate: StatementID?,
        body: StatementID
    ) {
        self.attributes = attributes
        self.maybeInitializer = maybeInitializer
        self.maybeTest = maybeTest
        self.maybeUpdate = maybeUpdate
        self.body = body
    }

    mutating func setInternallyGenerated() {
        isInternallyGenerated = true
    }
}

@_spi(Testing)
public struct IfStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let test: ExpressionID

    /// A CompoundStatement (C++ `CompoundStatement::Ref`).
    @_spi(Testing)
    public let trueBody: StatementID

    @_spi(Testing)
    public let maybeFalseBody: StatementID?

    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public init(test: ExpressionID, trueBody: StatementID, maybeFalseBody: StatementID?, attributes: ListID<AttributeID>) {
        self.test = test
        self.trueBody = trueBody
        self.maybeFalseBody = maybeFalseBody
        self.attributes = attributes
    }
}

/// C++ `AST::Continuing`, held by value in its LoopStatement.
@_spi(Testing)
public struct Continuing: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let body: ListID<StatementID>

    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let breakIf: ExpressionID?

    @_spi(Testing)
    public var diagnostics = DiagnosticContainer()

    @_spi(Testing)
    public init(body: ListID<StatementID>, attributes: ListID<AttributeID>, breakIf: ExpressionID?) {
        self.body = body
        self.attributes = attributes
        self.breakIf = breakIf
    }
}

@_spi(Testing)
public struct LoopStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let bodyAttributes: ListID<AttributeID>

    @_spi(Testing)
    public let body: ListID<StatementID>

    /// `var` only so AttributeValidator can write `continuing.diagnostics`; every other field of a Continuing is `let`.
    @_spi(Testing)
    public var continuing: Continuing?

    @_spi(Testing)
    public var containsSwitch = false

    @_spi(Testing)
    public var bodyBehaviors = Behaviors()

    @_spi(Testing)
    public var bodyDiagnostics = DiagnosticContainer()

    @_spi(Testing)
    public init(
        attributes: ListID<AttributeID>,
        bodyAttributes: ListID<AttributeID>,
        body: ListID<StatementID>,
        continuing: Continuing?
    ) {
        self.attributes = attributes
        self.bodyAttributes = bodyAttributes
        self.body = body
        self.continuing = continuing
    }

    mutating func setContainsSwitch() {
        containsSwitch = true
    }

    mutating func setBodyBehaviors(_ behaviors: Behaviors) {
        bodyBehaviors = behaviors
    }
}

@_spi(Testing)
public struct PhonyAssignmentStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let rhs: ExpressionID

    @_spi(Testing)
    public init(rhs: ExpressionID) {
        self.rhs = rhs
    }
}

@_spi(Testing)
public struct ReturnStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let maybeExpression: ExpressionID?

    @_spi(Testing)
    public init(maybeExpression: ExpressionID?) {
        self.maybeExpression = maybeExpression
    }
}

/// C++ `AST::SwitchClause`, held by value in a `Vector<SwitchClause>`; here in its own small arena.
@_spi(Testing)
public struct SwitchClause: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let selectors: ListID<ExpressionID>

    /// A CompoundStatement (C++ `CompoundStatement::Ref`).
    @_spi(Testing)
    public let body: StatementID

    @_spi(Testing)
    public init(selectors: ListID<ExpressionID>, body: StatementID) {
        self.selectors = selectors
        self.body = body
    }
}

@_spi(Testing)
public struct SwitchStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let value: ExpressionID

    @_spi(Testing)
    public let bodyAttributes: ListID<AttributeID>

    @_spi(Testing)
    public let clauses: ListID<SwitchClauseID>

    @_spi(Testing)
    public let defaultClause: SwitchClauseID

    @_spi(Testing)
    public var isInsideLoop = false

    @_spi(Testing)
    public var isNestedInsideLoop = false

    @_spi(Testing)
    public var bodyDiagnostics = DiagnosticContainer()

    @_spi(Testing)
    public init(
        attributes: ListID<AttributeID>,
        value: ExpressionID,
        bodyAttributes: ListID<AttributeID>,
        clauses: ListID<SwitchClauseID>,
        defaultClause: SwitchClauseID
    ) {
        self.attributes = attributes
        self.value = value
        self.bodyAttributes = bodyAttributes
        self.clauses = clauses
        self.defaultClause = defaultClause
    }

    mutating func setIsInsideLoop() {
        isInsideLoop = true
    }

    mutating func setIsNestedInsideLoop() {
        isNestedInsideLoop = true
    }
}

@_spi(Testing)
public struct VariableStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let variable: VariableID

    @_spi(Testing)
    public init(variable: VariableID) {
        self.variable = variable
    }
}

@_spi(Testing)
public struct WhileStatement: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let test: ExpressionID

    /// A CompoundStatement (C++ `CompoundStatement::Ref`).
    @_spi(Testing)
    public let body: StatementID

    @_spi(Testing)
    public init(attributes: ListID<AttributeID>, test: ExpressionID, body: StatementID) {
        self.attributes = attributes
        self.test = test
        self.body = body
    }
}

// MARK: - Kinds

@_spi(Testing)
public enum StatementKind: BitwiseCopyable, Equatable {
    case assignmentStatement(AssignmentStatement)
    case breakStatement(BreakStatement)
    case callStatement(CallStatement)
    case compoundAssignmentStatement(CompoundAssignmentStatement)
    case compoundStatement(CompoundStatement)
    case constAssertStatement(ConstAssertStatement)
    case continueStatement(ContinueStatement)
    case decrementIncrementStatement(DecrementIncrementStatement)
    case discardStatement(DiscardStatement)
    case forStatement(ForStatement)
    case ifStatement(IfStatement)
    case loopStatement(LoopStatement)
    case phonyAssignmentStatement(PhonyAssignmentStatement)
    case returnStatement(ReturnStatement)
    case switchStatement(SwitchStatement)
    case variableStatement(VariableStatement)
    case whileStatement(WhileStatement)

    @_spi(Testing)
    public var tag: StatementKindTag {
        switch self {
        case .assignmentStatement: .assignmentStatement
        case .breakStatement: .breakStatement
        case .callStatement: .callStatement
        case .compoundAssignmentStatement: .compoundAssignmentStatement
        case .compoundStatement: .compoundStatement
        case .constAssertStatement: .constAssertStatement
        case .continueStatement: .continueStatement
        case .decrementIncrementStatement: .decrementIncrementStatement
        case .discardStatement: .discardStatement
        case .forStatement: .forStatement
        case .ifStatement: .ifStatement
        case .loopStatement: .loopStatement
        case .phonyAssignmentStatement: .phonyAssignmentStatement
        case .returnStatement: .returnStatement
        case .switchStatement: .switchStatement
        case .variableStatement: .variableStatement
        case .whileStatement: .whileStatement
        }
    }
}

/// The payload-free mirror of StatementKind: dispatchers switch on it exhaustively.
@_spi(Testing)
public enum StatementKindTag: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case assignmentStatement
    case breakStatement
    case callStatement
    case compoundAssignmentStatement
    case compoundStatement
    case constAssertStatement
    case continueStatement
    case decrementIncrementStatement
    case discardStatement
    case forStatement
    case ifStatement
    case loopStatement
    case phonyAssignmentStatement
    case returnStatement
    case switchStatement
    case variableStatement
    case whileStatement

    @_spi(Testing)
    public var nodeKind: NodeKind {
        switch self {
        case .assignmentStatement: .assignmentStatement
        case .breakStatement: .breakStatement
        case .callStatement: .callStatement
        case .compoundAssignmentStatement: .compoundAssignmentStatement
        case .compoundStatement: .compoundStatement
        case .constAssertStatement: .constAssertStatement
        case .continueStatement: .continueStatement
        case .decrementIncrementStatement: .decrementIncrementStatement
        case .discardStatement: .discardStatement
        case .forStatement: .forStatement
        case .ifStatement: .ifStatement
        case .loopStatement: .loopStatement
        case .phonyAssignmentStatement: .phonyAssignmentStatement
        case .returnStatement: .returnStatement
        case .switchStatement: .switchStatement
        case .variableStatement: .variableStatement
        case .whileStatement: .whileStatement
        }
    }
}

// MARK: - Payload conformances

/// Proof that a type's StatementPayload conformance is declared in this file.
///
/// Only this file can make one, so no other code can declare a statement kind.
@_spi(Testing)
public struct StatementPayloadConformance<Payload>: Sendable {
    fileprivate init() {}
}

/// Proof that a kind may be built by the generic `construct(span:_:)`.
///
/// Only this file can make one.
@_spi(Testing)
public struct PlainStatementPayloadConformance<Payload>: Sendable {
    fileprivate init() {}
}

/// C++-shaped casts over statement payloads: `shaderModule.is/downcast/dynamicDowncast(X.self, id)`.
@_spi(Testing)
public protocol StatementPayload: BitwiseCopyable {
    static var tag: StatementKindTag { get }
    static var conformance: StatementPayloadConformance<Self> { get }
    init?(_ kind: StatementKind)
    var statementKind: StatementKind { get }
}

/// Kinds the generic `construct(span:_:)` can build: every kind but CallStatement, whose constructor checks its call.
@_spi(Testing)
public protocol PlainStatementPayload: StatementPayload {
    static var plainConformance: PlainStatementPayloadConformance<Self> { get }
}

extension AssignmentStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .assignmentStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .assignmentStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .assignmentStatement(self) }
}

extension BreakStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .breakStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .breakStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .breakStatement(self) }
}

extension CallStatement: StatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .callStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .callStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .callStatement(self) }
}

extension CompoundAssignmentStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .compoundAssignmentStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .compoundAssignmentStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .compoundAssignmentStatement(self) }
}

extension CompoundStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .compoundStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .compoundStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .compoundStatement(self) }
}

extension ConstAssertStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .constAssertStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .constAssertStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .constAssertStatement(self) }
}

extension ContinueStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .continueStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .continueStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .continueStatement(self) }
}

extension DecrementIncrementStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .decrementIncrementStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .decrementIncrementStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .decrementIncrementStatement(self) }
}

extension DiscardStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .discardStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .discardStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .discardStatement(self) }
}

extension ForStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .forStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .forStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .forStatement(self) }
}

extension IfStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .ifStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .ifStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .ifStatement(self) }
}

extension LoopStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .loopStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .loopStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .loopStatement(self) }
}

extension PhonyAssignmentStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .phonyAssignmentStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .phonyAssignmentStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .phonyAssignmentStatement(self) }
}

extension ReturnStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .returnStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .returnStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .returnStatement(self) }
}

extension SwitchStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .switchStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .switchStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .switchStatement(self) }
}

extension VariableStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .variableStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .variableStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .variableStatement(self) }
}

extension WhileStatement: PlainStatementPayload {
    @_spi(Testing)
    public static var tag: StatementKindTag { .whileStatement }

    @_spi(Testing)
    public static var conformance: StatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainStatementPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: StatementKind) {
        guard case .whileStatement(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var statementKind: StatementKind { .whileStatement(self) }
}
