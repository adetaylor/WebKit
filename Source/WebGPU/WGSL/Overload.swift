// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

@_spi(Testing)
public struct ValueVariable: BitwiseCopyable, Sendable {
    @_spi(Testing)
    public let id: UInt32

    @_spi(Testing)
    public init(id: UInt32) {
        self.id = id
    }
}

/// C++ `Variant<ValueVariable, unsigned>`; a constant is a size or the raw value of an address space, access mode or texel format.
@_spi(Testing)
public enum AbstractValue: BitwiseCopyable, Sendable {
    case variable(ValueVariable)
    case constant(UInt32)

    static func addressSpace(_ addressSpace: AddressSpace) -> AbstractValue {
        .constant(UInt32(addressSpace.rawValue))
    }

    static func accessMode(_ accessMode: AccessMode) -> AbstractValue {
        .constant(UInt32(accessMode.rawValue))
    }
}

/// C++ `TypeVariable`; `constraint` is the C++ `constraints` member.
@_spi(Testing)
public struct TypeVariable: BitwiseCopyable, Sendable {
    @_spi(Testing)
    public let id: UInt32
    @_spi(Testing)
    public let constraint: Constraint

    @_spi(Testing)
    public init(id: UInt32, constraint: Constraint = .none) {
        self.id = id
        self.constraint = constraint
    }
}

/// A concrete type of the builtin table, independent of any module's TypeStore (C++ `const Type*`, which the per-module
/// C++ table created with `m_types.<case>Type(...)`): the fixed types are their `FixedTypeID`s, and the composite cases
/// are the TypeStore factories. `TypeStore.materialize(_:)` turns one into a type.
@_spi(Testing)
public enum ConcreteTypeDescriptor: Sendable {
    case fixed(TypeID)
    indirect case vector(UInt8, ConcreteTypeDescriptor)
    indirect case matrix(UInt8, UInt8, ConcreteTypeDescriptor)
    indirect case texture(Types.Texture.Kind, ConcreteTypeDescriptor)
    indirect case atomic(ConcreteTypeDescriptor)
    indirect case frexpResult(ConcreteTypeDescriptor, ConcreteTypeDescriptor)
    indirect case modfResult(ConcreteTypeDescriptor, ConcreteTypeDescriptor)
    indirect case atomicCompareExchangeResult(ConcreteTypeDescriptor)
}

/// C++ `AbstractType` (`std::unique_ptr<AbstractTypeImpl>`), same alternative order; `concrete` is the C++ `const Type*`.
@_spi(Testing)
public enum AbstractType: Sendable {
    indirect case vector(AbstractValue, AbstractType)
    indirect case matrix(AbstractValue, AbstractValue, AbstractType)
    indirect case texture(Types.Texture.Kind, AbstractType)
    case textureStorage(Types.TextureStorage.Kind, AbstractValue, AbstractValue)
    case channelFormat(AbstractValue)
    indirect case reference(AbstractValue, AbstractType, AbstractValue)
    indirect case pointer(AbstractValue, AbstractType, AbstractValue)
    indirect case array(AbstractType)
    indirect case atomic(AbstractType)
    case variable(TypeVariable)
    case concrete(ConcreteTypeDescriptor)

    /// C++ `AbstractPointer(AbstractValue, AbstractType)`: the access mode is the address space's default.
    static func pointer(_ addressSpace: AbstractValue, _ element: AbstractType) -> AbstractType {
        guard case .constant(let rawAddressSpace) = addressSpace,
            let space = AddressSpace(rawValue: UInt8(truncatingIfNeeded: rawAddressSpace))
        else {
            wgslFatal("ptr[AS, T] needs a concrete address space", cppSite: "Overload.cpp:52")
        }
        return .pointer(addressSpace, element, .accessMode(defaultAccessModeForAddressSpace(space)))
    }
}

@_spi(Testing)
public struct OverloadCandidate: Sendable {
    @_spi(Testing)
    public let typeVariables: [TypeVariable]
    @_spi(Testing)
    public let valueVariables: [ValueVariable]
    @_spi(Testing)
    public let parameters: [AbstractType]
    @_spi(Testing)
    public let result: AbstractType

    @_spi(Testing)
    public init(typeVariables: [TypeVariable], valueVariables: [ValueVariable], parameters: [AbstractType], result: AbstractType) {
        self.typeVariables = typeVariables
        self.valueVariables = valueVariables
        self.parameters = parameters
        self.result = result
    }
}

/// C++ `OverloadedDeclaration`; `name` is the Swift-only key of the table (`BuiltinTable`), and the function pointers are
/// the generated `ConstantFunction` and `ValidationFunction` enums.
@_spi(Testing)
public struct OverloadedDeclaration: Sendable {
    @_spi(Testing)
    public enum Kind: UInt8, BitwiseCopyable, Sendable {
        case `operator`
        case constructor
        case function
    }

    let name: BuiltinSymbols
    @_spi(Testing)
    public let kind: Kind
    @_spi(Testing)
    public let mustUse: Bool

    let constantFunction: ConstantFunction?
    let validationFunction: ValidationFunction?
    @_spi(Testing)
    public let visibility: ShaderStages
    @_spi(Testing)
    public let overloads: [OverloadCandidate]
}

@_spi(Testing)
public struct SelectedOverload: Sendable {
    @_spi(Testing)
    public let parameters: [TypeID]
    @_spi(Testing)
    public let result: TypeID
}

/// The buffers of an overload resolution, reused across resolutions (the TypeChecker keeps one) so that resolving allocates
/// nothing once they have grown: C++ `m_typeSubstitutions`, `m_valueSubstitutions`, and the `ranks` and `parameters` of
/// the candidate being considered and of the selected one.
struct OverloadResolutionBuffers: ~Copyable {
    var typeSubstitutions: [TypeID?] = []
    var valueSubstitutions: [UInt32?] = []
    var ranks: [UInt32] = []
    var parameters: [TypeID] = []
    var selectedRanks: [UInt32] = []
    var selectedParameters: [TypeID] = []
}

private struct OverloadResolver: ~Copyable {
    var types: TypeStore
    let valueArguments: ArraySlice<TypeID>
    let typeArguments: [TypeID]
    var buffers: OverloadResolutionBuffers

    init(
        _ types: consuming TypeStore,
        _ valueArguments: ArraySlice<TypeID>,
        _ typeArguments: [TypeID],
        _ numberOfTypeSubstitutions: Int,
        _ numberOfValueSubstitutions: Int,
        _ buffers: consuming OverloadResolutionBuffers
    ) {
        self.types = types // lint-exempt(L-SCOPE-1): C++ `TypeStore& m_types`; resolveOverloads moves the same store back
        self.valueArguments = valueArguments
        self.typeArguments = typeArguments
        self.buffers = buffers
        Self.resize(&self.buffers.typeSubstitutions, numberOfTypeSubstitutions, nil)
        Self.resize(&self.buffers.valueSubstitutions, numberOfValueSubstitutions, nil)
        // The ranks and parameters of a candidate are written by index; their initial values are never read.
        Self.resize(&self.buffers.ranks, valueArguments.count, 0)
        Self.resize(&self.buffers.parameters, valueArguments.count, FixedTypeID.void)
        Self.resize(&self.buffers.selectedRanks, valueArguments.count, 0)
        Self.resize(&self.buffers.selectedParameters, valueArguments.count, FixedTypeID.void)
    }

    /// Returns the selected result type.
    ///
    /// The C++ `considerCandidates()` vector is not materialized: each candidate is considered in order into
    /// `buffers.ranks`/`buffers.parameters`, and a better one is swapped into `buffers.selectedRanks`/`selectedParameters`.
    /// `candidates` (C++ `m_candidates`) is a parameter so that a candidate is borrowed, not copied, for the mutating calls.
    mutating func resolve(_ candidates: borrowing [OverloadCandidate]) -> TypeID? {
        var selectedResult: TypeID?

        var index = 0
        while index < candidates.count {
            let current = considerCandidate(candidates[index])
            index += 1
            guard let result = current else {
                continue
            }

            guard selectedResult != nil else {
                selectedResult = result
                swap(&buffers.ranks, &buffers.selectedRanks)
                swap(&buffers.parameters, &buffers.selectedParameters)
                continue
            }
            assert(buffers.selectedRanks.count == buffers.ranks.count)

            var isBetterOrEqual = true
            var hasStrictlyBetter = false
            var i = 0
            while i < buffers.ranks.count {
                if buffers.ranks[i] > buffers.selectedRanks[i] {
                    isBetterOrEqual = false
                    break
                }
                if buffers.ranks[i] < buffers.selectedRanks[i] {
                    hasStrictlyBetter = true
                }
                i += 1
            }
            if isBetterOrEqual && hasStrictlyBetter {
                selectedResult = result
                swap(&buffers.ranks, &buffers.selectedRanks)
                swap(&buffers.parameters, &buffers.selectedParameters)
            }
        }

        return selectedResult
    }

    mutating func materialize(_ abstractType: AbstractType) -> TypeID? {
        switch abstractType {
        case .concrete(let type):
            return types.materialize(type)
        case .variable(let variable):
            guard let type = resolve(variable) else {
                return nil
            }
            guard let promotedType = satisfyOrPromote(type, variable.constraint, types) else {
                wgslFatal("a resolved type variable no longer satisfies its constraint", cppSite: "Overload.cpp:162")
            }
            return promotedType
        case .vector(let vectorSize, let vectorElement):
            if let element = materialize(vectorElement) {
                let size = materialize(vectorSize)
                return types.vectorType(UInt8(truncatingIfNeeded: size), element)
            }
            return nil
        case .matrix(let matrixColumns, let matrixRows, let matrixElement):
            if let element = materialize(matrixElement) {
                let columns = materialize(matrixColumns)
                let rows = materialize(matrixRows)
                return types.matrixType(UInt8(truncatingIfNeeded: columns), UInt8(truncatingIfNeeded: rows), element)
            }
            return nil
        case .texture(let kind, let textureElement):
            if let element = materialize(textureElement) {
                return types.textureType(kind, element)
            }
            return nil
        case .textureStorage(let kind, let textureFormat, let textureAccess):
            let format = materialize(textureFormat)
            let access = materialize(textureAccess)
            return types.textureStorageType(kind, texelFormat(format, "Overload.cpp:188"), accessMode(access, "Overload.cpp:188"))
        case .channelFormat(let channelFormat):
            let format = materialize(channelFormat)
            return shaderTypeForTexelFormat(texelFormat(format, "Overload.cpp:192"), types)
        case .reference(let referenceAddressSpace, let referenceElement, let referenceAccessMode):
            if let element = materialize(referenceElement) {
                let addressSpace = materialize(referenceAddressSpace)
                let accessMode = materialize(referenceAccessMode)
                return types.referenceType(
                    self.addressSpace(addressSpace, "Overload.cpp:198"),
                    element,
                    self.accessMode(accessMode, "Overload.cpp:198")
                )
            }
            return nil
        case .pointer(let pointerAddressSpace, let pointerElement, let pointerAccessMode):
            if let element = materialize(pointerElement) {
                let addressSpace = materialize(pointerAddressSpace)
                let accessMode = materialize(pointerAccessMode)
                return types.pointerType(
                    self.addressSpace(addressSpace, "Overload.cpp:206"),
                    element,
                    self.accessMode(accessMode, "Overload.cpp:206")
                )
            }
            return nil
        case .array(let arrayElement):
            if let element = materialize(arrayElement) {
                return types.arrayType(element, .runtime)
            }
            return nil
        case .atomic(let atomicElement):
            if let element = materialize(atomicElement) {
                return types.atomicType(element)
            }
            return nil
        }
    }

    func materialize(_ abstractValue: AbstractValue) -> UInt32 {
        switch abstractValue {
        case .constant(let value):
            return value
        case .variable(let variable):
            let resolvedValue = resolve(variable)
            assert(resolvedValue != nil)
            guard let value = resolvedValue else {
                wgslFatal("an unresolved value variable", cppSite: "Overload.cpp:231")
            }
            return value
        }
    }

    mutating func considerCandidate(_ candidate: borrowing OverloadCandidate) -> TypeID? {
        if candidate.parameters.count != valueArguments.count {
            return nil
        }

        if typeArguments.count > candidate.typeVariables.count {
            return nil
        }

        var substitution = 0
        while substitution < buffers.typeSubstitutions.count {
            buffers.typeSubstitutions[substitution] = nil
            substitution += 1
        }
        substitution = 0
        while substitution < buffers.valueSubstitutions.count {
            buffers.valueSubstitutions[substitution] = nil
            substitution += 1
        }

        var i = 0
        while i < typeArguments.count {
            if !assign(candidate.typeVariables[i], typeArguments[i]) {
                return nil
            }
            i += 1
        }

        i = 0
        while i < valueArguments.count {
            let parameter = candidate.parameters[i]
            let argument = valueArguments[valueArguments.startIndex + i]
            if !unify(parameter, argument) {
                return nil
            }
            i += 1
        }

        i = 0
        while i < valueArguments.count {
            let parameter = candidate.parameters[i]
            let argument = valueArguments[valueArguments.startIndex + i]
            let rank = calculateRank(parameter, argument)
            assert(rank != nil)
            guard let unsignedRank = rank else {
                wgslFatal("a unified parameter has no conversion rank", cppSite: "Overload.cpp:281")
            }
            buffers.ranks[i] = unsignedRank
            guard let materialized = materialize(parameter) else {
                wgslFatal("a unified parameter does not materialize", cppSite: "Overload.cpp:282")
            }
            buffers.parameters[i] = materialized
            i += 1
        }

        return materialize(candidate.result)
    }

    mutating func calculateRank(_ parameter: AbstractType, _ argumentType: TypeID) -> UInt32? {
        if case .variable(let variable) = parameter {
            var resolvedType = resolve(variable)
            assert(resolvedType != nil)
            if variable.constraint != .none {
                resolvedType = satisfyOrPromote(resolvedType, variable.constraint, types)
                guard resolvedType != nil else {
                    wgslFatal("a resolved type variable no longer satisfies its constraint", cppSite: "Overload.cpp:313")
                }
            }
            // C++ ranks against a null type here, which yields no rank and fails `*rank` in considerCandidate.
            guard let type = resolvedType else {
                wgslFatal("a unified type variable is unresolved", cppSite: "Overload.cpp:281")
            }
            return conversionRank(argumentType, type)
        }

        if case .reference(_, let element, _) = parameter {
            guard let referenceArgument = types.getIf(Types.Reference.self, argumentType) else {
                wgslFatal("std::get<Types::Reference> on a non-reference argument", cppSite: "Overload.cpp:319")
            }
            return calculateRank(element, referenceArgument.element)
        }

        if case .pointer(_, let element, _) = parameter {
            guard let pointerArgument = types.getIf(Types.Pointer.self, argumentType) else {
                wgslFatal("std::get<Types::Pointer> on a non-pointer argument", cppSite: "Overload.cpp:324")
            }
            return calculateRank(element, pointerArgument.element)
        }

        if let reference = types.getIf(Types.Reference.self, argumentType) {
            assert(reference.accessMode != .write)
            return calculateRank(parameter, reference.element)
        }

        if case .vector(_, let element) = parameter {
            guard let vectorArgument = types.getIf(Types.Vector.self, argumentType) else {
                wgslFatal("std::get<Types::Vector> on a non-vector argument", cppSite: "Overload.cpp:334")
            }
            return calculateRank(element, vectorArgument.element)
        }

        if case .matrix(_, _, let element) = parameter {
            guard let matrixArgument = types.getIf(Types.Matrix.self, argumentType) else {
                wgslFatal("std::get<Types::Matrix> on a non-matrix argument", cppSite: "Overload.cpp:339")
            }
            return calculateRank(element, matrixArgument.element)
        }

        if case .texture(_, let element) = parameter {
            guard let textureArgument = types.getIf(Types.Texture.self, argumentType) else {
                wgslFatal("std::get<Types::Texture> on a non-texture argument", cppSite: "Overload.cpp:344")
            }
            return calculateRank(element, textureArgument.element)
        }

        if case .array(let element) = parameter {
            guard let arrayArgument = types.getIf(Types.Array.self, argumentType) else {
                wgslFatal("std::get<Types::Array> on a non-array argument", cppSite: "Overload.cpp:349")
            }
            return calculateRank(element, arrayArgument.element)
        }

        if case .atomic(let element) = parameter {
            guard let atomicArgument = types.getIf(Types.Atomic.self, argumentType) else {
                wgslFatal("std::get<Types::Atomic> on a non-atomic argument", cppSite: "Overload.cpp:354")
            }
            return calculateRank(element, atomicArgument.element)
        }

        if case .textureStorage = parameter {
            return 0
        }

        if case .channelFormat(let channelFormat) = parameter {
            let format = materialize(channelFormat)
            return conversionRank(argumentType, shaderTypeForTexelFormat(texelFormat(format, "Overload.cpp:363"), types))
        }

        guard case .concrete(let parameterType) = parameter else {
            wgslFatal("std::get<const Type*> on an abstract parameter", cppSite: "Overload.cpp:366")
        }
        return conversionRank(argumentType, types.materialize(parameterType))
    }

    mutating func unify(_ variable: TypeVariable, _ argumentType: TypeID) -> Bool {
        guard let resolvedType = resolve(variable) else {
            return assign(variable, argumentType)
        }

        // Consider the following:
        // + :: (T, T) -> T
        // 1 + 1u
        //
        // We first unify `Var(T)` with `Type(AbstractInt)`, and assign `T` to `AbstractInt`
        // Next, we unify `Var(T) with `Type(u32)`, we look up `T => AbstractInt`,
        //   and promote `T` to `u32`.
        //
        // A few more examples to illustrate it:
        //
        // vec3 :: (T, T, T) -> T
        // vec3(1, 1.0, 1.0f) -> vec3<f32>
        // 1) unify(Var(T), Type(AbstractInt); T => AbstractInt (assign)
        // 2) unify(Var(T), Type(AbstractFloat); T => AbstractFloat (promote T)
        // 3) unify(Var(T), Type(f32); T => f32 (promote T again)
        //
        // vec3 :: (T, T, T) -> T
        // vec3(1.0, 1, 1.0f) -> vec3<f32>
        // 1) unify(Var(T), Type(AbstractFloat); T => AbstractFloat (assign)
        // 2) unify(Var(T), Type(AbstractInt); T => AbstractFloat (convert the argument to AbstractInt)
        // 3) unify(Var(T), Type(f32); T => f32 (promote T)
        //
        // vec3 :: (T, T, T) -> T
        // vec3(1.0, 1u, 1.0f) -> vec3<f32>
        // 1) unify(Var(T), Type(AbstractInt); T => AbstractFloat (assign)
        // 2) unify(Var(T), Type(u32); Failed! Can't unify AbstractFloat and u32
        let variablePromotionRank = conversionRank(resolvedType, argumentType)
        let argumentConversionRank = conversionRank(argumentType, resolvedType)
        if markableValue(variablePromotionRank) < markableValue(argumentConversionRank) {
            return assign(variable, argumentType)
        }

        return argumentConversionRank != nil
    }

    mutating func unify(_ parameter: AbstractType, _ argumentType: TypeID) -> Bool {
        if case .variable(let variable) = parameter {
            return unify(variable, argumentType)
        }

        if case .reference(let addressSpace, let element, let accessMode) = parameter {
            guard let referenceArgument = types.getIf(Types.Reference.self, argumentType) else {
                return false
            }
            if !unify(addressSpace, UInt32(referenceArgument.addressSpace.rawValue)) {
                return false
            }
            if !unify(accessMode, UInt32(referenceArgument.accessMode.rawValue)) {
                return false
            }
            return unify(element, referenceArgument.element)
        }

        if case .pointer(let addressSpace, let element, let accessMode) = parameter {
            guard let pointerArgument = types.getIf(Types.Pointer.self, argumentType) else {
                return false
            }
            if !unify(addressSpace, UInt32(pointerArgument.addressSpace.rawValue)) {
                return false
            }
            if !unify(accessMode, UInt32(pointerArgument.accessMode.rawValue)) {
                return false
            }
            return unify(element, pointerArgument.element)
        }

        if let reference = types.getIf(Types.Reference.self, argumentType) {
            if reference.accessMode == .write {
                return false
            }
            return unify(parameter, reference.element)
        }

        if case .vector(let size, let element) = parameter {
            guard let vectorArgument = types.getIf(Types.Vector.self, argumentType) else {
                return false
            }
            if !unify(element, vectorArgument.element) {
                return false
            }
            return unify(size, UInt32(vectorArgument.size))
        }

        if case .matrix(let columns, let rows, let element) = parameter {
            guard let matrixArgument = types.getIf(Types.Matrix.self, argumentType) else {
                return false
            }
            if !unify(element, matrixArgument.element) {
                return false
            }
            if !unify(columns, UInt32(matrixArgument.columns)) {
                return false
            }
            return unify(rows, UInt32(matrixArgument.rows))
        }

        if case .texture(let kind, let element) = parameter {
            guard let textureArgument = types.getIf(Types.Texture.self, argumentType) else {
                return false
            }
            if kind != textureArgument.kind {
                return false
            }
            return unify(element, textureArgument.element)
        }

        if case .textureStorage(let kind, let format, let access) = parameter {
            guard let textureStorageArgument = types.getIf(Types.TextureStorage.self, argumentType) else {
                return false
            }
            if kind != textureStorageArgument.kind {
                return false
            }
            if !unify(format, UInt32(textureStorageArgument.format.rawValue)) {
                return false
            }
            return unify(access, UInt32(textureStorageArgument.access.rawValue))
        }

        if case .channelFormat(let channelFormat) = parameter {
            let format = materialize(channelFormat)
            return conversionRank(argumentType, shaderTypeForTexelFormat(texelFormat(format, "Overload.cpp:489"), types)) != nil
        }

        if case .array(let element) = parameter {
            guard let arrayArgument = types.getIf(Types.Array.self, argumentType) else {
                return false
            }
            // For now, we only support dynamic arrays
            if !arrayArgument.isRuntimeSized {
                return false
            }
            return unify(element, arrayArgument.element)
        }

        if case .atomic(let element) = parameter {
            guard let atomicArgument = types.getIf(Types.Atomic.self, argumentType) else {
                return false
            }
            return unify(element, atomicArgument.element)
        }

        guard case .concrete(let parameterType) = parameter else {
            wgslFatal("std::get<const Type*> on an abstract parameter", cppSite: "Overload.cpp:509")
        }
        return conversionRank(argumentType, types.materialize(parameterType)) != nil
    }

    mutating func unify(_ parameter: AbstractValue, _ argumentValue: UInt32) -> Bool {
        switch parameter {
        case .constant(let parameterValue):
            return parameterValue == argumentValue
        case .variable(let variable):
            guard let resolvedValue = resolve(variable) else {
                assign(variable, argumentValue)
                return true
            }
            return resolvedValue == argumentValue
        }
    }

    mutating func assign(_ variable: TypeVariable, _ type: TypeID) -> Bool {
        if variable.constraint != .none {
            if !satisfies(type, variable.constraint, types) {
                return false
            }
        }
        buffers.typeSubstitutions[Int(variable.id)] = type
        return true
    }

    mutating func assign(_ variable: ValueVariable, _ value: UInt32) {
        buffers.valueSubstitutions[Int(variable.id)] = value
    }

    func resolve(_ variable: TypeVariable) -> TypeID? {
        buffers.typeSubstitutions[Int(variable.id)]
    }

    func resolve(_ variable: ValueVariable) -> UInt32? {
        buffers.valueSubstitutions[Int(variable.id)]
    }

    func conversionRank(_ from: TypeID, _ to: TypeID) -> UInt32? {
        types.conversionRank(from, to)
    }

    /// C++ `static_cast<TexelFormat>(unsigned)`; the values come from the table or from a texture storage type.
    private func texelFormat(_ value: UInt32, _ cppSite: StaticString) -> TexelFormat {
        guard let format = TexelFormat(rawValue: UInt8(truncatingIfNeeded: value)) else {
            wgslFatal("not a TexelFormat", cppSite: cppSite)
        }
        return format
    }

    /// C++ `static_cast<AccessMode>(unsigned)`.
    private func accessMode(_ value: UInt32, _ cppSite: StaticString) -> AccessMode {
        guard let accessMode = AccessMode(rawValue: UInt8(truncatingIfNeeded: value)) else {
            wgslFatal("not an AccessMode", cppSite: cppSite)
        }
        return accessMode
    }

    /// C++ `static_cast<AddressSpace>(unsigned)`.
    private func addressSpace(_ value: UInt32, _ cppSite: StaticString) -> AddressSpace {
        guard let addressSpace = AddressSpace(rawValue: UInt8(truncatingIfNeeded: value)) else {
            wgslFatal("not an AddressSpace", cppSite: cppSite)
        }
        return addressSpace
    }

    /// C++ `FixedVector<T>(count)`, reusing the buffer (not `Array(repeating:count:)`, which is unspecialized at -O).
    private static func resize(_ slots: inout [TypeID?], _ count: Int, _ value: TypeID?) {
        while slots.count > count {
            slots.removeLast()
        }
        while slots.count < count {
            slots.append(value)
        }
    }

    private static func resize(_ slots: inout [UInt32?], _ count: Int, _ value: UInt32?) {
        while slots.count > count {
            slots.removeLast()
        }
        while slots.count < count {
            slots.append(value)
        }
    }

    private static func resize(_ slots: inout [UInt32], _ count: Int, _ value: UInt32) {
        while slots.count > count {
            slots.removeLast()
        }
        while slots.count < count {
            slots.append(value)
        }
    }

    private static func resize(_ slots: inout [TypeID], _ count: Int, _ value: TypeID) {
        while slots.count > count {
            slots.removeLast()
        }
        while slots.count < count {
            slots.append(value)
        }
    }
}

@_spi(Testing)
public func resolveOverloads(
    _ types: inout TypeStore,
    _ candidates: [OverloadCandidate],
    _ valueArguments: [TypeID],
    _ typeArguments: [TypeID]
) -> SelectedOverload? {
    var buffers = OverloadResolutionBuffers()
    guard let result = resolveOverloads(&types, candidates, valueArguments[...], typeArguments, &buffers) else {
        return nil
    }
    return SelectedOverload(parameters: buffers.selectedParameters, result: result)
}

/// `resolveOverloads` into `buffers`: returns the selected result type, and the selected parameter types are
/// `buffers.selectedParameters`.
func resolveOverloads(
    _ types: inout TypeStore,
    _ candidates: [OverloadCandidate],
    _ valueArguments: ArraySlice<TypeID>,
    _ typeArguments: [TypeID],
    _ buffers: inout OverloadResolutionBuffers
) -> TypeID? {
    var numberOfTypeSubstitutions = 0
    var numberOfValueSubstitutions = 0
    var i = 0
    while i < candidates.count {
        numberOfTypeSubstitutions = cxxMax(numberOfTypeSubstitutions, candidates[i].typeVariables.count)
        numberOfValueSubstitutions = cxxMax(numberOfValueSubstitutions, candidates[i].valueVariables.count)
        i += 1
    }
    var resolver = OverloadResolver(
        types,
        valueArguments,
        typeArguments,
        numberOfTypeSubstitutions,
        numberOfValueSubstitutions,
        buffers
    )
    let result = resolver.resolve(candidates)
    types = resolver.types // lint-exempt(L-SCOPE-1): moves back the store the resolver borrowed
    buffers = resolver.buffers
    return result
}

// MARK: - Swift-only

/// The builtin overload table (C++ `ShaderModule::m_overloadedOperations`).
///
/// Built once per process from the generated `makeBuiltinDeclarations()`, immutable and shared by every module. Entry `i` is
/// the declaration named by predeclared symbol `i`.
@_spi(Testing)
public struct BuiltinTable: Sendable {
    let declarations: [OverloadedDeclaration]

    @_spi(Testing)
    public static let shared = BuiltinTable()

    /// Builds a table; the compiler only uses `shared`.
    @_spi(Testing)
    public init() {
        declarations = makeBuiltinDeclarations()
        guard declarations.count == Int(BuiltinSymbols.builtinDeclarationCount) else {
            wgslFatal("the generated table and the predeclared symbols disagree", cppSite: "WGSLShaderModule.cpp:101")
        }
        var index = 0
        while index < declarations.count {
            guard declarations[index].name.rawValue == UInt32(index) else {
                wgslFatal("the generated table and the predeclared symbols disagree", cppSite: "WGSLShaderModule.cpp:101")
            }
            index += 1
        }
    }

    @_spi(Testing)
    public var count: Int { declarations.count }

    @_spi(Testing)
    public subscript(index: Int) -> OverloadedDeclaration {
        declarations[index]
    }
}

extension OverloadedDeclaration {
    /// The predeclared symbol naming the declaration.
    @_spi(Testing)
    public var symbol: Symbol { Symbol(name) }
}

extension ShaderModule {
    /// C++ `ShaderModule::lookupOverload(const String&)`: the builtin declarations are predeclared symbols
    /// `0..<builtinDeclarationCount` in table order, so the lookup is an index check.
    @_spi(Testing)
    public func lookupOverload(_ symbol: Symbol) -> OverloadedDeclaration? {
        guard let index = symbol.builtinDeclarationIndex else {
            return nil
        }
        return BuiltinTable.shared[index]
    }
}

extension TypeStore {
    /// The type `descriptor` names, created through the TypeStore factories.
    @_spi(Testing)
    public mutating func materialize(_ descriptor: ConcreteTypeDescriptor) -> TypeID {
        switch descriptor {
        case .fixed(let type):
            return type
        case .vector(let size, let element):
            return vectorType(size, materialize(element))
        case .matrix(let columns, let rows, let element):
            return matrixType(columns, rows, materialize(element))
        case .texture(let kind, let element):
            return textureType(kind, materialize(element))
        case .atomic(let element):
            return atomicType(materialize(element))
        case .frexpResult(let fract, let exp):
            let fract = materialize(fract)
            return frexpResultType(fract, materialize(exp))
        case .modfResult(let fract, let whole):
            let fract = materialize(fract)
            return modfResultType(fract, materialize(whole))
        case .atomicCompareExchangeResult(let element):
            return atomicCompareExchangeResultType(materialize(element))
        }
    }
}

/// A generated type alias (`vec2f`, `mat3x3h`, …), in TypeDeclarations.rb order.
struct BuiltinTypeAlias: Sendable {
    let name: BuiltinSymbols
    let type: ConcreteTypeDescriptor
}

/// The raw value WTF `Markable<unsigned>` holds for a conversion rank: `UINT_MAX` when it is empty.
private func markableValue(_ rank: UInt32?) -> UInt32 {
    rank ?? .max
}

/// The overload resolutions a TypeChecker has made, by builtin declaration and argument types (Swift-only).
///
/// A resolution is a function of the candidates and of the argument types. It creates types in the TypeStore only the first
/// time (a repeated one finds them in the cache), and the store is not rolled back while a TypeChecker runs, so reusing a
/// successful resolution changes nothing but the time. Calls with more than 4 value arguments or more than 1 type argument
/// are resolved every time.
struct OverloadResolutionMemo {
    private struct Key: Equatable {
        let header: UInt64
        let leadingArguments: UInt64
        let trailingArguments: UInt64
        let typeArgument: UInt32
    }

    private struct Entry {
        let key: Key
        let result: TypeID
        let parameters: (TypeID?, TypeID?, TypeID?, TypeID?)
    }

    /// An open-addressing table (linear probing, at most half full) of indices into `entries`, plus one (0 is empty):
    /// growing a table of whole entries would rewrite them all.
    private var table: [UInt32] = []
    private var entries: [Entry] = []

    private static func key(_ declaration: Int, _ valueArguments: ArraySlice<TypeID>, _ typeArguments: [TypeID]) -> Key? {
        let count = valueArguments.count
        guard count <= 4, typeArguments.count <= 1 else {
            return nil
        }
        let start = valueArguments.startIndex
        var leading: UInt64 = 0
        var trailing: UInt64 = 0
        if count > 0 {
            leading |= UInt64(valueArguments[start].raw)
        }
        if count > 1 {
            leading |= UInt64(valueArguments[start + 1].raw) << 32
        }
        if count > 2 {
            trailing |= UInt64(valueArguments[start + 2].raw)
        }
        if count > 3 {
            trailing |= UInt64(valueArguments[start + 3].raw) << 32
        }
        let counts = UInt64(count) | UInt64(typeArguments.count) << 8
        return Key(
            header: UInt64(UInt32(truncatingIfNeeded: declaration)) | counts << 32,
            leadingArguments: leading,
            trailingArguments: trailing,
            typeArgument: typeArguments.isEmpty ? 0 : typeArguments[0].raw
        )
    }

    // SipHash with the stdlib's per-process random seed: the source chooses which types it passes, and under an unkeyed
    // mix it could fill one probe cluster.
    private static func hash(_ key: Key) -> Int {
        var hasher = Hasher()
        hasher.combine(key.header)
        hasher.combine(key.leadingArguments)
        hasher.combine(key.trailingArguments)
        hasher.combine(key.typeArgument)
        return hasher.finalize()
    }

    /// The memoized result type, with the selected parameters copied into `buffers.selectedParameters`.
    func find(
        _ declaration: Int,
        _ valueArguments: ArraySlice<TypeID>,
        _ typeArguments: [TypeID],
        _ buffers: inout OverloadResolutionBuffers
    ) -> TypeID? {
        guard !table.isEmpty, let key = Self.key(declaration, valueArguments, typeArguments) else {
            return nil
        }
        let mask = table.count &- 1
        var index = Self.hash(key) & mask
        while table[index] != 0 {
            let entry = Int(table[index] &- 1)
            if entries[entry].key == key {
                Self.copy(entries[entry].parameters, valueArguments.count, to: &buffers.selectedParameters)
                return entries[entry].result
            }
            index = (index &+ 1) & mask
        }
        return nil
    }

    mutating func add(
        _ declaration: Int,
        _ valueArguments: ArraySlice<TypeID>,
        _ typeArguments: [TypeID],
        _ result: TypeID,
        _ parameters: [TypeID]
    ) {
        guard let key = Self.key(declaration, valueArguments, typeArguments) else {
            return
        }
        guard entries.count < Int(UInt32.max >> 1) else {
            return
        }
        if (entries.count &+ 1) &* 2 > table.count {
            grow()
        }
        let mask = table.count &- 1
        var index = Self.hash(key) & mask
        while table[index] != 0 {
            if entries[Int(table[index] &- 1)].key == key {
                return
            }
            index = (index &+ 1) & mask
        }
        let count = parameters.count
        let packed = (
            count > 0 ? parameters[0] : nil, count > 1 ? parameters[1] : nil, count > 2 ? parameters[2] : nil,
            count > 3 ? parameters[3] : nil
        )
        entries.append(Entry(key: key, result: result, parameters: packed))
        table[index] = UInt32(truncatingIfNeeded: entries.count)
    }

    private mutating func grow() {
        let capacity = cxxMax(64, table.count &* 2)
        table.removeAll()
        table.reserveCapacity(capacity)
        table.append(contentsOf: repeatElement(0, count: capacity))
        let mask = capacity &- 1
        var entry = 0
        while entry < entries.count {
            var index = Self.hash(entries[entry].key) & mask
            while table[index] != 0 {
                index = (index &+ 1) & mask
            }
            entry &+= 1
            table[index] = UInt32(truncatingIfNeeded: entry)
        }
    }

    private static func copy(_ parameters: (TypeID?, TypeID?, TypeID?, TypeID?), _ count: Int, to array: inout [TypeID]) {
        while array.count > count {
            array.removeLast()
        }
        var i = 0
        while i < count {
            let parameter = i == 0 ? parameters.0 : i == 1 ? parameters.1 : i == 2 ? parameters.2 : parameters.3
            guard let parameter else {
                wgslFatal("a memoized overload with fewer parameters than arguments", cppSite: "Overload.cpp:281")
            }
            if i < array.count {
                array[i] = parameter
            } else {
                array.append(parameter)
            }
            i += 1
        }
    }

    /// The longest run of occupied slots, which bounds the probes of any lookup.
    fileprivate func longestProbeRun() -> Int {
        var longest = 0
        var run = 0
        var index = 0
        while index < 2 &* table.count {
            if table[index & (table.count &- 1)] == 0 {
                run = 0
            } else {
                run &+= 1
                longest = cxxMax(longest, run)
            }
            index &+= 1
        }
        return longest
    }
}

/// Memoizes a resolution of each call with no type argument, in order, and returns the memo's longest probe run and how
/// many of the calls it then finds.
@_spi(Testing)
public func memoizeOverloadResolutions(
    _ declarations: [Int],
    _ valueArguments: [[TypeID]],
    result: TypeID
) -> (longestProbeRun: Int, found: Int) {
    var memo = OverloadResolutionMemo()
    var buffers = OverloadResolutionBuffers()
    var index = 0
    while index < declarations.count {
        memo.add(declarations[index], valueArguments[index][...], [], result, valueArguments[index])
        index += 1
    }
    var found = 0
    index = 0
    while index < declarations.count {
        if memo.find(declarations[index], valueArguments[index][...], [], &buffers) == result {
            found += 1
        }
        index += 1
    }
    return (memo.longestProbeRun(), found)
}
