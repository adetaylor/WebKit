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

// MARK: - Attribute

/// One attribute slot: the C++ `Node` span plus the kind payload.
@_spi(Testing)
public struct AttributeNode: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public var kind: AttributeKind

    @_spi(Testing)
    public var span: SourceSpan

    @_spi(Testing)
    public init(kind: AttributeKind, span: SourceSpan) {
        self.kind = kind
        self.span = span
    }
}

@_spi(Testing)
public struct AlignAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let alignment: ExpressionID

    @_spi(Testing)
    public init(alignment: ExpressionID) {
        self.alignment = alignment
    }
}

@_spi(Testing)
public struct BindingAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let binding: ExpressionID

    @_spi(Testing)
    public init(binding: ExpressionID) {
        self.binding = binding
    }
}

@_spi(Testing)
public struct BuiltinAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let builtin: Builtin

    @_spi(Testing)
    public init(builtin: Builtin) {
        self.builtin = builtin
    }
}

@_spi(Testing)
public struct ConstAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public init() {}
}

@_spi(Testing)
public struct DiagnosticAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let diagnostic: Diagnostic

    @_spi(Testing)
    public init(diagnostic: Diagnostic) {
        self.diagnostic = diagnostic
    }
}

@_spi(Testing)
public struct GroupAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let group: ExpressionID

    @_spi(Testing)
    public init(group: ExpressionID) {
        self.group = group
    }
}

@_spi(Testing)
public struct IdAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let value: ExpressionID

    @_spi(Testing)
    public init(value: ExpressionID) {
        self.value = value
    }
}

// Interpolation is the public API's AST::Interpolation (WGSL.swift).
extension Interpolation: BitwiseCopyable {}

@_spi(Testing)
public struct InterpolateAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let interpolation: Interpolation

    @_spi(Testing)
    public init(type: InterpolationType, sampling: InterpolationSampling) {
        interpolation = Interpolation(type: type, sampling: sampling)
    }

    @_spi(Testing)
    public var type: InterpolationType { interpolation.type }

    @_spi(Testing)
    public var sampling: InterpolationSampling { interpolation.sampling }
}

@_spi(Testing)
public struct InvariantAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public init() {}
}

@_spi(Testing)
public struct LocationAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let location: ExpressionID

    @_spi(Testing)
    public init(location: ExpressionID) {
        self.location = location
    }
}

@_spi(Testing)
public struct MustUseAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public init() {}
}

@_spi(Testing)
public struct SizeAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let size: ExpressionID

    @_spi(Testing)
    public init(size: ExpressionID) {
        self.size = size
    }
}

@_spi(Testing)
public struct StageAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let stage: ShaderStage

    @_spi(Testing)
    public init(stage: ShaderStage) {
        self.stage = stage
    }
}

@_spi(Testing)
public struct WorkgroupSize: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let x: ExpressionID

    @_spi(Testing)
    public let y: ExpressionID?

    @_spi(Testing)
    public let z: ExpressionID?

    @_spi(Testing)
    public init(x: ExpressionID, y: ExpressionID?, z: ExpressionID?) {
        self.x = x
        self.y = y
        self.z = z
    }
}

@_spi(Testing)
public struct WorkgroupSizeAttribute: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let workgroupSize: WorkgroupSize

    @_spi(Testing)
    public init(x: ExpressionID, maybeY: ExpressionID?, maybeZ: ExpressionID?) {
        workgroupSize = WorkgroupSize(x: x, y: maybeY, z: maybeZ)
    }

    @_spi(Testing)
    public var x: ExpressionID { workgroupSize.x }

    @_spi(Testing)
    public var maybeY: ExpressionID? { workgroupSize.y }

    @_spi(Testing)
    public var maybeZ: ExpressionID? { workgroupSize.z }
}

// MARK: - Attribute kinds

@_spi(Testing)
public enum AttributeKind: BitwiseCopyable, Equatable {
    case alignAttribute(AlignAttribute)
    case bindingAttribute(BindingAttribute)
    case builtinAttribute(BuiltinAttribute)
    case constAttribute(ConstAttribute)
    case diagnosticAttribute(DiagnosticAttribute)
    case groupAttribute(GroupAttribute)
    case idAttribute(IdAttribute)
    case interpolateAttribute(InterpolateAttribute)
    case invariantAttribute(InvariantAttribute)
    case locationAttribute(LocationAttribute)
    case mustUseAttribute(MustUseAttribute)
    case sizeAttribute(SizeAttribute)
    case stageAttribute(StageAttribute)
    case workgroupSizeAttribute(WorkgroupSizeAttribute)

    @_spi(Testing)
    public var tag: AttributeKindTag {
        switch self {
        case .alignAttribute: .alignAttribute
        case .bindingAttribute: .bindingAttribute
        case .builtinAttribute: .builtinAttribute
        case .constAttribute: .constAttribute
        case .diagnosticAttribute: .diagnosticAttribute
        case .groupAttribute: .groupAttribute
        case .idAttribute: .idAttribute
        case .interpolateAttribute: .interpolateAttribute
        case .invariantAttribute: .invariantAttribute
        case .locationAttribute: .locationAttribute
        case .mustUseAttribute: .mustUseAttribute
        case .sizeAttribute: .sizeAttribute
        case .stageAttribute: .stageAttribute
        case .workgroupSizeAttribute: .workgroupSizeAttribute
        }
    }
}

/// The payload-free mirror of AttributeKind: dispatchers switch on it exhaustively.
@_spi(Testing)
public enum AttributeKindTag: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case alignAttribute
    case bindingAttribute
    case builtinAttribute
    case constAttribute
    case diagnosticAttribute
    case groupAttribute
    case idAttribute
    case interpolateAttribute
    case invariantAttribute
    case locationAttribute
    case mustUseAttribute
    case sizeAttribute
    case stageAttribute
    case workgroupSizeAttribute

    @_spi(Testing)
    public var nodeKind: NodeKind {
        switch self {
        case .alignAttribute: .alignAttribute
        case .bindingAttribute: .bindingAttribute
        case .builtinAttribute: .builtinAttribute
        case .constAttribute: .constAttribute
        case .diagnosticAttribute: .diagnosticAttribute
        case .groupAttribute: .groupAttribute
        case .idAttribute: .idAttribute
        case .interpolateAttribute: .interpolateAttribute
        case .invariantAttribute: .invariantAttribute
        case .locationAttribute: .locationAttribute
        case .mustUseAttribute: .mustUseAttribute
        case .sizeAttribute: .sizeAttribute
        case .stageAttribute: .stageAttribute
        case .workgroupSizeAttribute: .workgroupSizeAttribute
        }
    }
}

// MARK: - Directive

/// One directive slot: the C++ `Node` span plus the kind payload.
@_spi(Testing)
public struct DirectiveNode: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public var kind: DirectiveKind

    @_spi(Testing)
    public var span: SourceSpan

    @_spi(Testing)
    public init(kind: DirectiveKind, span: SourceSpan) {
        self.kind = kind
        self.span = span
    }
}

@_spi(Testing)
public struct DiagnosticDirective: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let diagnostic: Diagnostic

    @_spi(Testing)
    public init(diagnostic: Diagnostic) {
        self.diagnostic = diagnostic
    }
}

@_spi(Testing)
public enum DirectiveKind: BitwiseCopyable, Equatable {
    case diagnosticDirective(DiagnosticDirective)

    @_spi(Testing)
    public var tag: DirectiveKindTag {
        switch self {
        case .diagnosticDirective: .diagnosticDirective
        }
    }
}

/// The payload-free mirror of DirectiveKind.
@_spi(Testing)
public enum DirectiveKindTag: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case diagnosticDirective

    @_spi(Testing)
    public var nodeKind: NodeKind {
        switch self {
        case .diagnosticDirective: .diagnosticDirective
        }
    }
}

// MARK: - Diagnostic

@_spi(Testing)
public struct Diagnostic: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let severity: SeverityControl

    @_spi(Testing)
    public let triggeringRule: TriggeringRule

    @_spi(Testing)
    public init(severity: SeverityControl, triggeringRule: TriggeringRule) {
        self.severity = severity
        self.triggeringRule = triggeringRule
    }
}

/// C++ `AST::DiagnosticContainer`, the base of Statement, Function, ShaderModule and Continuing: one optional severity per
/// triggering rule.
@_spi(Testing)
public struct DiagnosticContainer: BitwiseCopyable, Equatable {
    private var derivativeUniformitySeverity: SeverityControl?
    private var subgroupUniformitySeverity: SeverityControl?

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public func severityFor(_ rule: TriggeringRule) -> SeverityControl? {
        switch rule {
        case .derivativeUniformity: derivativeUniformitySeverity
        case .subgroupUniformity: subgroupUniformitySeverity
        }
    }

    mutating func setSeverityFor(_ rule: TriggeringRule, _ severity: SeverityControl) {
        switch rule {
        case .derivativeUniformity: derivativeUniformitySeverity = severity
        case .subgroupUniformity: subgroupUniformitySeverity = severity
        }
    }
}

// MARK: - Payload conformances

/// Proof that a type's AttributePayload conformance is declared in this file.
///
/// Only this file can make one, so no other code can declare an attribute kind.
@_spi(Testing)
public struct AttributePayloadConformance<Payload>: Sendable {
    fileprivate init() {}
}

/// C++-shaped casts over attribute payloads: `shaderModule.is/downcast/dynamicDowncast(X.self, id)`.
@_spi(Testing)
public protocol AttributePayload: BitwiseCopyable {
    static var tag: AttributeKindTag { get }
    static var conformance: AttributePayloadConformance<Self> { get }
    init?(_ kind: AttributeKind)
    var attributeKind: AttributeKind { get }
}

extension AlignAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .alignAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .alignAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .alignAttribute(self) }
}

extension BindingAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .bindingAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .bindingAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .bindingAttribute(self) }
}

extension BuiltinAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .builtinAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .builtinAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .builtinAttribute(self) }
}

extension ConstAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .constAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .constAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .constAttribute(self) }
}

extension DiagnosticAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .diagnosticAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .diagnosticAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .diagnosticAttribute(self) }
}

extension GroupAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .groupAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .groupAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .groupAttribute(self) }
}

extension IdAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .idAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .idAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .idAttribute(self) }
}

extension InterpolateAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .interpolateAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .interpolateAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .interpolateAttribute(self) }
}

extension InvariantAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .invariantAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .invariantAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .invariantAttribute(self) }
}

extension LocationAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .locationAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .locationAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .locationAttribute(self) }
}

extension MustUseAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .mustUseAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .mustUseAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .mustUseAttribute(self) }
}

extension SizeAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .sizeAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .sizeAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .sizeAttribute(self) }
}

extension StageAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .stageAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .stageAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .stageAttribute(self) }
}

extension WorkgroupSizeAttribute: AttributePayload {
    @_spi(Testing)
    public static var tag: AttributeKindTag { .workgroupSizeAttribute }

    @_spi(Testing)
    public static var conformance: AttributePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: AttributeKind) {
        guard case .workgroupSizeAttribute(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var attributeKind: AttributeKind { .workgroupSizeAttribute(self) }
}

/// Proof that a type's DirectivePayload conformance is declared in this file.
///
/// Only this file can make one.
@_spi(Testing)
public struct DirectivePayloadConformance<Payload>: Sendable {
    fileprivate init() {}
}

/// C++-shaped casts over directive payloads.
@_spi(Testing)
public protocol DirectivePayload: BitwiseCopyable {
    static var tag: DirectiveKindTag { get }
    static var conformance: DirectivePayloadConformance<Self> { get }
    init?(_ kind: DirectiveKind)
    var directiveKind: DirectiveKind { get }
}

extension DiagnosticDirective: DirectivePayload {
    @_spi(Testing)
    public static var tag: DirectiveKindTag { .diagnosticDirective }

    @_spi(Testing)
    public static var conformance: DirectivePayloadConformance<Self> { .init() }

    @_spi(Testing)
    public init?(_ kind: DirectiveKind) {
        guard case .diagnosticDirective(let payload) = kind else { return nil }
        self = payload
    }

    @_spi(Testing)
    public var directiveKind: DirectiveKind { .diagnosticDirective(self) }
}
