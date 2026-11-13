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

// MARK: - Expression

@_spi(Testing)
public enum Evaluation: UInt8, BitwiseCopyable, Comparable, Hashable, Sendable {
    case constant = 1
    case override = 2
    case runtime = 3

    @_spi(Testing)
    public static func < (lhs: Evaluation, rhs: Evaluation) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One expression slot: the C++ `Node` and `Expression` base fields plus the kind payload.
///
/// `Expression::m_constantValue` is the module's ConstantTable slot for this node's ID.
@_spi(Testing)
public struct ExpressionNode: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public var kind: ExpressionKind

    @_spi(Testing)
    public var span: SourceSpan

    private var packedInferredType = PackedTypeID(nil)

    @_spi(Testing)
    public var evaluation: Evaluation?

    @_spi(Testing)
    public init(kind: ExpressionKind, span: SourceSpan) {
        self.kind = kind
        self.span = span
    }

    @_spi(Testing)
    public var inferredType: TypeID? {
        get { packedInferredType.value }
        set { packedInferredType = PackedTypeID(newValue) }
    }
}

// MARK: - Literals

// Literal floats without size prefix; these floats are double-precision
// floating point numbers.
// https://gpuweb.github.io/gpuweb/wgsl/#abstractfloat
@_spi(Testing)
public struct AbstractFloatLiteral: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: Double

    @_spi(Testing)
    public init(value: Double) {
        self.value = value
    }

    /// Slot equality: the same bits, so a NaN or a negative zero equals its own copy.
    @_spi(Testing)
    public static func == (lhs: AbstractFloatLiteral, rhs: AbstractFloatLiteral) -> Bool {
        lhs.value.bitPattern == rhs.value.bitPattern
    }
}

@_spi(Testing)
public struct AbstractIntegerLiteral: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: Int64

    @_spi(Testing)
    public init(value: Int64) {
        self.value = value
    }
}

@_spi(Testing)
public struct BoolLiteral: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: Bool

    @_spi(Testing)
    public init(value: Bool) {
        self.value = value
    }
}

@_spi(Testing)
public struct Float16Literal: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: Half

    @_spi(Testing)
    public init(value: Half) {
        self.value = value
    }

    /// Slot equality: the same bits (`Half` has no operators).
    @_spi(Testing)
    public static func == (lhs: Float16Literal, rhs: Float16Literal) -> Bool {
        lhs.value.bitPattern == rhs.value.bitPattern
    }
}

@_spi(Testing)
public struct Float32Literal: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: Float

    @_spi(Testing)
    public init(value: Float) {
        self.value = value
    }

    /// Slot equality: the same bits, so a NaN or a negative zero equals its own copy.
    @_spi(Testing)
    public static func == (lhs: Float32Literal, rhs: Float32Literal) -> Bool {
        lhs.value.bitPattern == rhs.value.bitPattern
    }
}

@_spi(Testing)
public struct Signed32Literal: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: Int32

    @_spi(Testing)
    public init(value: Int32) {
        self.value = value
    }
}

@_spi(Testing)
public struct Unsigned32Literal: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: UInt32

    @_spi(Testing)
    public init(value: UInt32) {
        self.value = value
    }
}

// MARK: - BinaryExpression

@_spi(Testing)
public enum BinaryOperation: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case add
    case subtract
    case multiply
    case divide
    case modulo
    case and
    case or
    case xor
    case leftShift
    case rightShift
    case equal
    case notEqual
    case greaterThan
    case greaterEqual
    case lessThan
    case lessEqual
    case shortCircuitAnd
    case shortCircuitOr
}

@_spi(Testing)
public func toASCIILiteral(_ op: BinaryOperation) -> StaticString {
    switch op {
    case .add: "+"
    case .subtract: "-"
    case .multiply: "*"
    case .divide: "/"
    case .modulo: "%"
    case .and: "&"
    case .or: "|"
    case .xor: "^"
    case .leftShift: "<<"
    case .rightShift: ">>"
    case .equal: "=="
    case .notEqual: "!="
    case .greaterThan: ">"
    case .greaterEqual: ">="
    case .lessThan: "<"
    case .lessEqual: "<="
    case .shortCircuitAnd: "&&"
    case .shortCircuitOr: "||"
    }
}

func printInternal(_ out: inout MessageText, _ op: BinaryOperation) {
    out.append("\(toASCIILiteral(op))")
}

@_spi(Testing)
public struct BinaryExpression: BitwiseCopyable, Equatable {
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

// MARK: - UnaryExpression

@_spi(Testing)
public enum UnaryOperation: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case addressOf
    case complement
    case dereference
    case negate
    case not
}

@_spi(Testing)
public func toASCIILiteral(_ op: UnaryOperation) -> StaticString {
    switch op {
    case .addressOf: "&"
    case .complement: "~"
    case .dereference: "*"
    case .negate: "-"
    case .not: "!"
    }
}

func printInternal(_ out: inout MessageText, _ op: UnaryOperation) {
    out.append("\(toASCIILiteral(op))")
}

@_spi(Testing)
public struct UnaryExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let expression: ExpressionID

    @_spi(Testing)
    public let operation: UnaryOperation

    @_spi(Testing)
    public init(expression: ExpressionID, operation: UnaryOperation) {
        self.expression = expression
        self.operation = operation
    }
}

// MARK: - CallExpression

// A CallExpression expresses a "function" call, which consists of a target to be called,
// and a list of arguments. The target does not necesserily have to be a function identifier,
// but can also be a type, in which the whole call is a type conversion expression. The exact
// kind of expression can only be resolved during semantic analysis.
@_spi(Testing)
public struct CallExpression: BitwiseCopyable, Equatable {
    // If m_target is a NamedType, it could either be a:
    //   * Type that does not accept parameters (bool, i32, u32, ...)
    //   * Identifier that refers to a type alias.
    //   * Identifier that refers to a function.
    @_spi(Testing)
    public let target: ExpressionID

    @_spi(Testing)
    public let arguments: ListID<ExpressionID>

    /// nil is the C++ null `String`.
    @_spi(Testing)
    public var resolvedTarget: Symbol?

    @_spi(Testing)
    public var isConstructor = false

    @_spi(Testing)
    public var visibility: ShaderStages

    var validationFunction: ValidationFunction?

    @_spi(Testing)
    public init(target: ExpressionID, arguments: ListID<ExpressionID>) {
        self.target = target
        self.arguments = arguments
        // Not the property's default value: `init?(_ kind:)` would build this array literal on every cast.
        visibility = [.compute, .vertex, .fragment]
    }
}

// MARK: - FieldAccessExpression

@_spi(Testing)
public struct FieldAccessExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let base: ExpressionID

    @_spi(Testing)
    public let fieldName: IdentifierID

    /// A slot of its own holding a copy of the constructor's `fieldName`.
    @_spi(Testing)
    public let originalFieldName: IdentifierID

    @_spi(Testing)
    public init(base: ExpressionID, fieldName: IdentifierID, originalFieldName: IdentifierID) {
        self.base = base
        self.fieldName = fieldName
        self.originalFieldName = originalFieldName
    }
}

// MARK: - IdentifierExpression

@_spi(Testing)
public struct IdentifierExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let identifier: IdentifierID

    @_spi(Testing)
    public init(identifier: IdentifierID) {
        self.identifier = identifier
    }
}

// MARK: - IdentityExpression

// This is a special node used when modifying the AST through compiler passes.
// The passes can replace one node with another, but only if the size of the new
// class fits in the existing space. This is a small node used when needing to insert a
// larger node than the one current in the tree. E.g. replacing an identifier
// with a structure access.
@_spi(Testing)
public struct IdentityExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let expression: ExpressionID

    @_spi(Testing)
    public init(expression: ExpressionID) {
        self.expression = expression
    }
}

// MARK: - IndexAccessExpression

@_spi(Testing)
public struct IndexAccessExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let base: ExpressionID

    @_spi(Testing)
    public let index: ExpressionID

    @_spi(Testing)
    public init(base: ExpressionID, index: ExpressionID) {
        self.base = base
        self.index = index
    }
}

/// An IndexAccessExpression that BoundsCheck has justified; C++ has an IndexAccessExpression here.
///
/// `index` is the expression C++ has there: the synthesised `__wgslMin(u32(i), N - 1u)` call, or the original index when
/// no clamp is needed. Only BoundsCheck.swift can mint a SubscriptProof, so only it can make a subscript the writer
/// prints.
@_spi(Testing)
public struct CheckedIndexAccessExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let base: ExpressionID

    @_spi(Testing)
    public let index: ExpressionID

    @_spi(Testing)
    public let proof: SubscriptProof

    @_spi(Testing)
    public init(base: ExpressionID, index: ExpressionID, proof: SubscriptProof) {
        self.base = base
        self.index = index
        self.proof = proof
    }
}

// MARK: - PointerDereferenceExpression

/// Never constructed in C++; kept for NodeKind parity.
@_spi(Testing)
public struct PointerDereferenceExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let target: ExpressionID

    @_spi(Testing)
    public init(target: ExpressionID) {
        self.target = target
    }
}

// MARK: - ArrayTypeExpression

@_spi(Testing)
public struct ArrayTypeExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let maybeElementType: ExpressionID?

    @_spi(Testing)
    public let maybeElementCount: ExpressionID?

    @_spi(Testing)
    public init(maybeElementType: ExpressionID?, maybeElementCount: ExpressionID?) {
        self.maybeElementType = maybeElementType
        self.maybeElementCount = maybeElementCount
    }
}

// MARK: - ElaboratedTypeExpression

@_spi(Testing)
public struct ElaboratedTypeExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let base: IdentifierID

    @_spi(Testing)
    public let arguments: ListID<ExpressionID>

    @_spi(Testing)
    public init(base: IdentifierID, arguments: ListID<ExpressionID>) {
        self.base = base
        self.arguments = arguments
    }
}

// MARK: - ReferenceTypeExpression

@_spi(Testing)
public struct ReferenceTypeExpression: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let type: ExpressionID

    @_spi(Testing)
    public init(type: ExpressionID) {
        self.type = type
    }
}

// MARK: - Kinds

@_spi(Testing)
public enum ExpressionKind: BitwiseCopyable, Equatable {
    case abstractFloatLiteral(AbstractFloatLiteral)
    case abstractIntegerLiteral(AbstractIntegerLiteral)
    case binaryExpression(BinaryExpression)
    case boolLiteral(BoolLiteral)
    case callExpression(CallExpression)
    case fieldAccessExpression(FieldAccessExpression)
    case float32Literal(Float32Literal)
    case float16Literal(Float16Literal)
    case identifierExpression(IdentifierExpression)
    case identityExpression(IdentityExpression)
    case indexAccessExpression(IndexAccessExpression)
    case checkedIndexAccessExpression(CheckedIndexAccessExpression)
    case pointerDereferenceExpression(PointerDereferenceExpression)
    case signed32Literal(Signed32Literal)
    case unaryExpression(UnaryExpression)
    case unsigned32Literal(Unsigned32Literal)
    case arrayTypeExpression(ArrayTypeExpression)
    case elaboratedTypeExpression(ElaboratedTypeExpression)
    case referenceTypeExpression(ReferenceTypeExpression)

    @_spi(Testing)
    public var tag: ExpressionKindTag {
        switch self {
        case .abstractFloatLiteral: .abstractFloatLiteral
        case .abstractIntegerLiteral: .abstractIntegerLiteral
        case .binaryExpression: .binaryExpression
        case .boolLiteral: .boolLiteral
        case .callExpression: .callExpression
        case .fieldAccessExpression: .fieldAccessExpression
        case .float32Literal: .float32Literal
        case .float16Literal: .float16Literal
        case .identifierExpression: .identifierExpression
        case .identityExpression: .identityExpression
        case .indexAccessExpression: .indexAccessExpression
        case .checkedIndexAccessExpression: .checkedIndexAccessExpression
        case .pointerDereferenceExpression: .pointerDereferenceExpression
        case .signed32Literal: .signed32Literal
        case .unaryExpression: .unaryExpression
        case .unsigned32Literal: .unsigned32Literal
        case .arrayTypeExpression: .arrayTypeExpression
        case .elaboratedTypeExpression: .elaboratedTypeExpression
        case .referenceTypeExpression: .referenceTypeExpression
        }
    }
}

/// The payload-free mirror of ExpressionKind: dispatchers switch on it exhaustively, which keeps the -Onone dispatch
/// frame small.
@_spi(Testing)
public enum ExpressionKindTag: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case abstractFloatLiteral
    case abstractIntegerLiteral
    case binaryExpression
    case boolLiteral
    case callExpression
    case fieldAccessExpression
    case float32Literal
    case float16Literal
    case identifierExpression
    case identityExpression
    case indexAccessExpression
    case checkedIndexAccessExpression
    case pointerDereferenceExpression
    case signed32Literal
    case unaryExpression
    case unsigned32Literal
    case arrayTypeExpression
    case elaboratedTypeExpression
    case referenceTypeExpression

    /// The C++ NodeKind; a checked access reports IndexAccessExpression, which is what C++ has there.
    @_spi(Testing)
    public var nodeKind: NodeKind {
        switch self {
        case .abstractFloatLiteral: .abstractFloatLiteral
        case .abstractIntegerLiteral: .abstractIntegerLiteral
        case .binaryExpression: .binaryExpression
        case .boolLiteral: .boolLiteral
        case .callExpression: .callExpression
        case .fieldAccessExpression: .fieldAccessExpression
        case .float32Literal: .float32Literal
        case .float16Literal: .float16Literal
        case .identifierExpression: .identifierExpression
        case .identityExpression: .identityExpression
        case .indexAccessExpression, .checkedIndexAccessExpression: .indexAccessExpression
        case .pointerDereferenceExpression: .pointerDereferenceExpression
        case .signed32Literal: .signed32Literal
        case .unaryExpression: .unaryExpression
        case .unsigned32Literal: .unsigned32Literal
        case .arrayTypeExpression: .arrayTypeExpression
        case .elaboratedTypeExpression: .elaboratedTypeExpression
        case .referenceTypeExpression: .referenceTypeExpression
        }
    }

    /// sizeof() of the C++ class (arm64e; equal on x86_64), which picks the C++ replace() overload.
    @_spi(Testing)
    public var cppSizeof: Int {
        switch self {
        case .abstractFloatLiteral, .abstractIntegerLiteral, .boolLiteral, .float32Literal, .float16Literal, .signed32Literal,
            .unsigned32Literal, .identityExpression, .pointerDereferenceExpression, .referenceTypeExpression:
            88
        case .indexAccessExpression, .checkedIndexAccessExpression, .unaryExpression, .arrayTypeExpression: 96
        case .binaryExpression: 104
        case .identifierExpression: 112
        case .callExpression, .elaboratedTypeExpression: 128
        case .fieldAccessExpression: 152
        }
    }
}

// MARK: - Payload conformances

/// Proof that a type's ExpressionPayload conformance is declared in this file.
///
/// Only this file can make one, so no other code can declare an expression kind.
@_spi(Testing)
public struct ExpressionPayloadConformance<Payload>: Sendable {
    fileprivate init() {}
}

/// Proof that a kind may be built by the generic `construct(span:_:)`.
///
/// Only this file can make one.
@_spi(Testing)
public struct PlainExpressionPayloadConformance<Payload>: Sendable {
    fileprivate init() {}
}

/// C++-shaped casts over expression payloads: `shaderModule.is/downcast/dynamicDowncast(X.self, id)`.
@_spi(Testing)
public protocol ExpressionPayload: BitwiseCopyable {
    static var tag: ExpressionKindTag { get }
    static var conformance: ExpressionPayloadConformance<Self> { get }
    init?(_ kind: ExpressionKind)
    var expressionKind: ExpressionKind { get }
}

/// Kinds whose C++ constructor has no logic and that own no Identifier.
///
/// Only these can be built with the generic `construct(span:_:)`. IdentifierExpression, FieldAccessExpression,
/// ElaboratedTypeExpression and IdentityExpression have dedicated constructors.
@_spi(Testing)
public protocol PlainExpressionPayload: ExpressionPayload {
    static var plainConformance: PlainExpressionPayloadConformance<Self> { get }
}

extension AbstractFloatLiteral: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .abstractFloatLiteral }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .abstractFloatLiteral(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .abstractFloatLiteral(self) }
}

extension AbstractIntegerLiteral: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .abstractIntegerLiteral }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .abstractIntegerLiteral(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .abstractIntegerLiteral(self) }
}

extension BinaryExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .binaryExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .binaryExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .binaryExpression(self) }
}

extension BoolLiteral: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .boolLiteral }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .boolLiteral(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .boolLiteral(self) }
}

extension CallExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .callExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .callExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .callExpression(self) }
}

extension FieldAccessExpression: ExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .fieldAccessExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .fieldAccessExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .fieldAccessExpression(self) }
}

extension Float32Literal: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .float32Literal }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .float32Literal(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .float32Literal(self) }
}

extension Float16Literal: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .float16Literal }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .float16Literal(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .float16Literal(self) }
}

extension IdentifierExpression: ExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .identifierExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .identifierExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .identifierExpression(self) }
}

extension IdentityExpression: ExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .identityExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .identityExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .identityExpression(self) }
}

/// Matches only unchecked accesses; post-BoundsCheck sites handle CheckedIndexAccessExpression too.
extension IndexAccessExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .indexAccessExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .indexAccessExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .indexAccessExpression(self) }
}

extension CheckedIndexAccessExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .checkedIndexAccessExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .checkedIndexAccessExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .checkedIndexAccessExpression(self) }
}

extension PointerDereferenceExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .pointerDereferenceExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .pointerDereferenceExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .pointerDereferenceExpression(self) }
}

extension Signed32Literal: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .signed32Literal }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .signed32Literal(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .signed32Literal(self) }
}

extension UnaryExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .unaryExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .unaryExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .unaryExpression(self) }
}

extension Unsigned32Literal: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .unsigned32Literal }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .unsigned32Literal(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .unsigned32Literal(self) }
}

extension ArrayTypeExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .arrayTypeExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .arrayTypeExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .arrayTypeExpression(self) }
}

extension ElaboratedTypeExpression: ExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .elaboratedTypeExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .elaboratedTypeExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .elaboratedTypeExpression(self) }
}

extension ReferenceTypeExpression: PlainExpressionPayload {
    @_spi(Testing)
    public static var tag: ExpressionKindTag { .referenceTypeExpression }

    @_spi(Testing)
    public static var conformance: ExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public static var plainConformance: PlainExpressionPayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: ExpressionKind) {
        guard case .referenceTypeExpression(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var expressionKind: ExpressionKind { .referenceTypeExpression(self) }
}
