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

// MARK: - Declaration

/// A C++ `AST::Declaration&`: a module-scope declaration of any kind.
///
/// C++ `is<AST::Declaration>` holds only for Function, Structure and Variable; Swift code that needs it lists those cases.
@_spi(Testing)
public enum Declaration: Hashable, BitwiseCopyable, Sendable {
    case function(FunctionID)
    case variable(VariableID)
    case structure(StructureID)
    case typeAlias(TypeAliasID)
    case constAssert(ConstAssertID)

    @_spi(Testing)
    public var nodeKind: NodeKind {
        switch self {
        case .function: .function
        case .variable: .variable
        case .structure: .structure
        case .typeAlias: .typeAlias
        case .constAssert: .constAssert
        }
    }
}

// MARK: - Function

@_spi(Testing)
public struct Function: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let name: IdentifierID

    @_spi(Testing)
    public let parameters: ListID<ParameterID>

    @_spi(Testing)
    public let maybeReturnType: ExpressionID?

    /// A CompoundStatement (C++ `CompoundStatement::Ref`).
    @_spi(Testing)
    public let body: StatementID

    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public let returnAttributes: ListID<AttributeID>

    /// The constructor's `name` (C++ `String m_originalName`).
    @_spi(Testing)
    public let originalName: Symbol

    @_spi(Testing)
    public var diagnostics = DiagnosticContainer()

    // Attributes
    @_spi(Testing)
    public var mustUse = false

    @_spi(Testing)
    public var stage: ShaderStage?

    @_spi(Testing)
    public var workgroupSize: WorkgroupSize?

    @_spi(Testing)
    public var returnTypeInvariant = false

    @_spi(Testing)
    public var returnTypeBuiltin: Builtin?

    @_spi(Testing)
    public var returnTypeInterpolation: Interpolation?

    @_spi(Testing)
    public var returnTypeLocation: UInt32?

    @_spi(Testing)
    public init(
        span: SourceSpan,
        name: IdentifierID,
        parameters: ListID<ParameterID>,
        maybeReturnType: ExpressionID?,
        body: StatementID,
        attributes: ListID<AttributeID>,
        returnAttributes: ListID<AttributeID>,
        originalName: Symbol
    ) {
        self.span = span
        self.name = name
        self.parameters = parameters
        self.maybeReturnType = maybeReturnType
        self.body = body
        self.attributes = attributes
        self.returnAttributes = returnAttributes
        self.originalName = originalName
    }
}

// MARK: - Parameter

@_spi(Testing)
public enum ParameterRole: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case userDefined
    case stageIn
    case bindGroup
    case packedResource
}

@_spi(Testing)
public struct Parameter: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let name: IdentifierID

    @_spi(Testing)
    public let typeName: ExpressionID

    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public var role: ParameterRole

    // Attributes
    @_spi(Testing)
    public var invariant = false

    @_spi(Testing)
    public var builtin: Builtin?

    @_spi(Testing)
    public var interpolation: Interpolation?

    @_spi(Testing)
    public var location: UInt32?

    @_spi(Testing)
    public init(span: SourceSpan, name: IdentifierID, typeName: ExpressionID, attributes: ListID<AttributeID>, role: ParameterRole) {
        self.span = span
        self.name = name
        self.typeName = typeName
        self.attributes = attributes
        self.role = role
    }
}

// MARK: - Variable

@_spi(Testing)
public enum VariableFlavor: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case const
    case `let`
    case override
    case `var`
}

@_spi(Testing)
public enum VariableRole: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case userDefined
    case packedResource
}

/// C++ `AST::VariableQualifier`, held inline in its only owner, the Variable.
@_spi(Testing)
public struct VariableQualifier: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let addressSpace: AddressSpace

    @_spi(Testing)
    public let accessMode: AccessMode

    // True when the source spelled the access mode out rather than leaving it to the address
    // space's default. Such a name has to resolve to the predeclared enumerant, so a
    // module-scope declaration of the same name hides it and makes the qualifier invalid.
    @_spi(Testing)
    public let hasExplicitAccessMode: Bool

    @_spi(Testing)
    public init(span: SourceSpan, addressSpace: AddressSpace, accessMode: AccessMode, hasExplicitAccessMode: Bool = false) {
        self.span = span
        self.addressSpace = addressSpace
        self.accessMode = accessMode
        self.hasExplicitAccessMode = hasExplicitAccessMode
    }
}

@_spi(Testing)
public struct Variable: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public var flavor: VariableFlavor

    @_spi(Testing)
    public let name: IdentifierID

    // Each of the following may be null
    // But at least one of type and initializer must be non-null
    @_spi(Testing)
    public let maybeQualifier: VariableQualifier?

    @_spi(Testing)
    public let maybeTypeName: ExpressionID?

    @_spi(Testing)
    public let maybeInitializer: ExpressionID?

    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    @_spi(Testing)
    public var role: VariableRole

    /// A slot of its own holding a copy of the constructor's `name`.
    @_spi(Testing)
    public let originalName: IdentifierID

    @_spi(Testing)
    public var maybeReferenceType: ExpressionID?

    // Computed properties
    @_spi(Testing)
    public var storeType: TypeID?

    @_spi(Testing)
    public var addressSpace: AddressSpace?

    @_spi(Testing)
    public var accessMode: AccessMode?

    // Attributes
    @_spi(Testing)
    public var binding: UInt32?

    @_spi(Testing)
    public var group: UInt32?

    @_spi(Testing)
    public var id: UInt32?

    @_spi(Testing)
    public init(
        span: SourceSpan,
        flavor: VariableFlavor,
        name: IdentifierID,
        maybeQualifier: VariableQualifier?,
        maybeTypeName: ExpressionID?,
        maybeInitializer: ExpressionID?,
        attributes: ListID<AttributeID>,
        role: VariableRole = .userDefined,
        originalName: IdentifierID,
        storeType: TypeID?
    ) {
        self.span = span
        self.flavor = flavor
        self.name = name
        self.maybeQualifier = maybeQualifier
        self.maybeTypeName = maybeTypeName
        self.maybeInitializer = maybeInitializer
        self.attributes = attributes
        self.role = role
        self.originalName = originalName
        self.storeType = storeType
    }
}

// MARK: - Structure

@_spi(Testing)
public enum StructureRole: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case userDefined
    case vertexInput
    case fragmentInput
    case computeInput
    case vertexOutput
    case vertexOutputWrapper
    case bindGroup
    case userDefinedResource
    case packedResource
    case fragmentOutput
    case fragmentOutputWrapper
}

@_spi(Testing)
public struct Structure: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let name: IdentifierID

    @_spi(Testing)
    public let members: ListID<StructureMemberID>

    @_spi(Testing)
    public var role: StructureRole

    @_spi(Testing)
    public let original: StructureID?

    @_spi(Testing)
    public var packed: StructureID?

    @_spi(Testing)
    public var inferredType: TypeID?

    // Computed properties
    @_spi(Testing)
    public var hasSizeOrAlignmentAttributes = false

    @_spi(Testing)
    public var size: UInt32?

    @_spi(Testing)
    public var alignment: UInt32?

    @_spi(Testing)
    public init(
        span: SourceSpan,
        name: IdentifierID,
        members: ListID<StructureMemberID>,
        role: StructureRole,
        original: StructureID? = nil
    ) {
        self.span = span
        self.name = name
        self.members = members
        self.role = role
        self.original = original
    }

    mutating func setRole(_ role: StructureRole) {
        self.role = role
    }
}

// MARK: - StructureMember

/// A packed or duplicated Structure shares its members' IDs, as C++ shares the member nodes.
@_spi(Testing)
public struct StructureMember: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let name: IdentifierID

    @_spi(Testing)
    public let type: ExpressionID

    @_spi(Testing)
    public let attributes: ListID<AttributeID>

    /// A slot of its own holding a copy of the constructor's `name`.
    @_spi(Testing)
    public let originalName: IdentifierID

    // Compute
    @_spi(Testing)
    public var offset: UInt32 = 0

    @_spi(Testing)
    public var padding: UInt32 = 0

    // Attributes
    @_spi(Testing)
    public var invariant = false

    @_spi(Testing)
    public var alignment: UInt32?

    @_spi(Testing)
    public var size: UInt32?

    @_spi(Testing)
    public var builtin: Builtin?

    @_spi(Testing)
    public var location: UInt32?

    @_spi(Testing)
    public var interpolation: Interpolation?

    @_spi(Testing)
    public init(span: SourceSpan, name: IdentifierID, type: ExpressionID, attributes: ListID<AttributeID>, originalName: IdentifierID) {
        self.span = span
        self.name = name
        self.type = type
        self.attributes = attributes
        self.originalName = originalName
    }
}

// MARK: - TypeAlias

@_spi(Testing)
public struct TypeAlias: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let name: IdentifierID

    @_spi(Testing)
    public let type: ExpressionID

    @_spi(Testing)
    public init(span: SourceSpan, name: IdentifierID, type: ExpressionID) {
        self.span = span
        self.name = name
        self.type = type
    }
}

// MARK: - ConstAssert

/// C++ `ConstAssert::name()` is `RELEASE_ASSERT_NOT_REACHED()`: it has no name.
@_spi(Testing)
public struct ConstAssert: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public let span: SourceSpan

    @_spi(Testing)
    public let test: ExpressionID

    @_spi(Testing)
    public init(span: SourceSpan, test: ExpressionID) {
        self.span = span
        self.test = test
    }
}
