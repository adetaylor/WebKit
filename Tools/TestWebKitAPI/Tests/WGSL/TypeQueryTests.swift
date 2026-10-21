// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (C) 2026 Apple Inc. All rights reserved.
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

import Foundation
import Synchronization
import Testing
@_spi(Testing) import WGSL

private func makeModule() -> ShaderModule {
    ShaderModule(source: SourceText(""))
}

private func codeUnits(_ text: String) -> ContiguousArray<UInt16> {
    ContiguousArray(text.utf16)
}

private func string(_ text: MessageText) -> String {
    String(decoding: text.codeUnits, as: UTF16.self)
}

/// A structure whose member `i` has the inferred type `memberTypes[i]`, with the size and alignment AttributeValidator
/// would have set; returns its type.
private func makeStructure(
    _ module: inout ShaderModule,
    _ name: Symbol,
    _ memberTypes: [TypeID],
    size: UInt32?,
    alignment: UInt32?,
    role: StructureRole = .userDefined
) -> TypeID {
    var members: [StructureMemberID] = []
    for memberType in memberTypes {
        let typeExpression = module.constructIdentifierExpression(span: .empty, identifier: module.makeIdentifier("t"))
        module.setInferredType(memberType, for: typeExpression)
        members.append(
            module.constructStructureMember(
                span: .empty,
                name: module.makeIdentifier("m"),
                type: typeExpression,
                attributes: module.makeEmptyList(AttributeID.self)
            )
        )
    }
    let structure = module.constructStructure(
        span: .empty,
        name: module.makeIdentifier(name),
        members: module.makeList(members),
        role: role
    )
    let type = module.types.structType(structure)
    module.modify(structure) {
        $0.size = size
        $0.alignment = alignment
        $0.inferredType = type
    }
    return type
}

private func makeStructure(
    _ module: inout ShaderModule,
    _ name: String,
    _ memberTypes: [TypeID],
    size: UInt32?,
    alignment: UInt32?,
    role: StructureRole = .userDefined
) -> TypeID {
    let symbol = module.symbols.intern(codeUnits(name))
    return makeStructure(&module, symbol, memberTypes, size: size, alignment: alignment, role: role)
}

/// An override-sized array count: an expression whose cached constant (the value `evaluate` stored) is `value`.
private func makeArrayCount(_ module: inout ShaderModule, _ value: ConstantValue?) -> ExpressionID {
    let expression = module.constructIdentifierExpression(span: .empty, identifier: module.makeIdentifier("n"))
    module.setConstantValue(value, for: expression)
    return expression
}

// MARK: - Recursive transcription of Types.cpp

private struct Trap: Error {}

/// Types.cpp transcribed recursively, over the Swift IR, with independent arithmetic. `Trap` where the C++ crashes
/// (`*optional`, RELEASE_ASSERT_NOT_REACHED, a null inferred type), and where the type string reaches the AST dumper.
private enum Transcription {
    private static func roundUp(_ divisor: UInt32, _ x: UInt32) -> UInt32 {
        (x &+ (divisor &- 1)) & ~(divisor &- 1)
    }

    private static func integerValue(_ value: ConstantValue) throws(Trap) -> Int64 {
        switch value {
        case .int32(let value): Int64(value)
        case .uint32(let value): Int64(value)
        case .int64(let value): value
        default: throw Trap()
        }
    }

    private static func memberTypes(_ module: borrowing ShaderModule, _ structure: Types.Struct) throws(Trap) -> [TypeID] {
        var result: [TypeID] = []
        let members = module[structure.structure].members
        for index in 0..<module.count(members) {
            guard let type = module.inferredType(of: module[module[members, index]].type) else {
                throw Trap()
            }
            result.append(type)
        }
        return result
    }

    static func maybeSize(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> UInt32? {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16: return 2
            case .f32, .i32, .u32: return 4
            case .bool: return 1
            default: return nil
            }
        case .vector(let vector):
            return try size(module, vector.element) &* UInt32(vector.size)
        case .matrix(let matrix):
            let rowSize = UInt32(matrix.rows) &* (try size(module, matrix.element))
            let rowAlignment = (matrix.rows == 2 ? 2 : 4) &* (try alignment(module, matrix.element))
            return UInt32(matrix.columns) &* roundUp(rowAlignment, rowSize)
        case .array(let array):
            var count: UInt64 = 1
            var overflowed = false
            switch array.size {
            case .runtime:
                break
            case .creationFixed(let size):
                count = UInt64(size)
            case .overrideSized(let expression):
                if let value = module.constantValueForArrayCount(expression) {
                    let integer = try integerValue(value)
                    if integer < 0 || integer > Int64(UInt32.max) {
                        overflowed = true
                    } else {
                        count = UInt64(integer)
                    }
                }
            }
            let elementSize = try size(module, array.element)
            let stride = roundUp(try alignment(module, array.element), elementSize)
            if stride < elementSize || overflowed {
                return .max
            }
            let total = count * UInt64(stride)
            return total > UInt64(UInt32.max) ? .max : UInt32(total)
        case .struct(let structure):
            guard let size = module[structure.structure].size else {
                throw Trap()
            }
            return size
        case .primitiveStruct(let structure):
            var total: UInt32 = 0
            for index in 0..<module.types.count(of: structure.values) {
                total = total &+ (try size(module, module.types[structure.values, index]))
            }
            return total
        case .atomic(let atomic):
            return try size(module, atomic.element)
        case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .typeConstructor:
            return nil
        }
    }

    static func size(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> UInt32 {
        guard let size = try maybeSize(module, type) else {
            throw Trap()
        }
        return size
    }

    static func alignment(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> UInt32 {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16: return 2
            case .f32, .i32, .u32: return 4
            case .bool: return 1
            default: throw Trap()
            }
        case .vector(let vector):
            return (vector.size == 2 ? 2 : 4) &* (try alignment(module, vector.element))
        case .matrix(let matrix):
            return (matrix.rows == 2 ? 2 : 4) &* (try alignment(module, matrix.element))
        case .array(let array):
            return try alignment(module, array.element)
        case .struct(let structure):
            guard let alignment = module[structure.structure].alignment else {
                throw Trap()
            }
            return alignment
        case .primitiveStruct(let structure):
            var result: UInt32 = 0
            for index in 0..<module.types.count(of: structure.values) {
                let value = try alignment(module, module.types[structure.values, index])
                result = result < value ? value : result
            }
            return result
        case .atomic(let atomic):
            return try alignment(module, atomic.element)
        case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .typeConstructor:
            throw Trap()
        }
    }

    static func packing(_ module: borrowing ShaderModule, _ type: TypeID) -> Packing {
        switch module.types[type] {
        case .reference(let reference):
            return packing(module, reference.element)
        case .struct(let structure):
            return module[structure.structure].role == .userDefinedResource ? .packedStruct : .unpacked
        case .vector(let vector):
            return vector.size == 3 ? .packedVec3 : .unpacked
        case .matrix(let matrix):
            return matrix.rows == 3 ? .packedVec3 : .unpacked
        case .array(let array):
            var elementPacking = packing(module, array.element)
            if elementPacking.contains(.packed) {
                elementPacking.insert(.pArray)
            }
            return elementPacking
        default:
            return .unpacked
        }
    }

    static func isConstructible(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16, .f32, .i32, .u32, .bool, .abstractInt, .abstractFloat: return true
            default: return false
            }
        case .vector, .matrix, .primitiveStruct:
            return true
        case .array(let array):
            guard array.isCreationFixed else {
                return false
            }
            return try isConstructible(module, array.element)
        case .struct(let structure):
            return try allMembers(module, structure) { (module, type) throws(Trap) in try isConstructible(module, type) }
        default:
            return false
        }
    }

    static func isStorable(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16, .f32, .i32, .u32, .bool, .sampler, .samplerComparison, .textureExternal: return true
            default: return false
            }
        case .vector(let vector):
            return try isStorable(module, vector.element)
        case .matrix(let matrix):
            return try isStorable(module, matrix.element)
        case .array(let array):
            return try isStorable(module, array.element)
        case .struct(let structure):
            return try allMembers(module, structure) { (module, type) throws(Trap) in try isStorable(module, type) }
        case .textureStorage, .textureDepth, .atomic:
            return true
        default:
            return false
        }
    }

    static func isHostShareable(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16, .f32, .i32, .u32: return true
            default: return false
            }
        case .vector(let vector):
            return try isHostShareable(module, vector.element)
        case .matrix(let matrix):
            return try isHostShareable(module, matrix.element)
        case .array(let array):
            return try isHostShareable(module, array.element)
        case .struct(let structure):
            return try allMembers(module, structure) { (module, type) throws(Trap) in try isHostShareable(module, type) }
        case .atomic:
            return true
        default:
            return false
        }
    }

    static func hasFixedFootprint(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16, .f32, .i32, .u32, .bool: return true
            default: return false
            }
        case .vector, .matrix, .atomic:
            return true
        case .array(let array):
            return !array.isRuntimeSized
        case .struct(let structure):
            return try allMembers(module, structure) { (module, type) throws(Trap) in try hasFixedFootprint(module, type) }
        default:
            return false
        }
    }

    static func hasCreationFixedFootprint(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .primitive(let primitive):
            switch primitive.kind {
            case .f16, .f32, .i32, .u32, .bool: return true
            default: return false
            }
        case .vector, .matrix, .atomic:
            return true
        case .array(let array):
            return array.isCreationFixed
        case .struct(let structure):
            return try allMembers(module, structure) { (module, type) throws(Trap) in try hasCreationFixedFootprint(module, type) }
        default:
            return false
        }
    }

    /// The C++ member loop: stops at the first member that fails, before reading the later members' types.
    private static func allMembers(
        _ module: borrowing ShaderModule,
        _ structure: Types.Struct,
        _ predicate: (borrowing ShaderModule, TypeID) throws(Trap) -> Bool
    ) throws(Trap) -> Bool {
        let members = module[structure.structure].members
        for index in 0..<module.count(members) {
            guard let type = module.inferredType(of: module[module[members, index]].type) else {
                throw Trap()
            }
            if !(try predicate(module, type)) {
                return false
            }
        }
        return true
    }

    static func containsRuntimeArray(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .array(let array):
            return array.isRuntimeSized
        case .struct(let structure):
            guard let last = try memberTypes(module, structure).last else {
                throw Trap()
            }
            return try containsRuntimeArray(module, last)
        case .reference(let reference):
            return try containsRuntimeArray(module, reference.element)
        default:
            return false
        }
    }

    static func containsOverrideArray(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> Bool {
        switch module.types[type] {
        case .array(let array):
            return array.isOverrideSized
        case .struct(let structure):
            guard let last = try memberTypes(module, structure).last else {
                throw Trap()
            }
            return try containsOverrideArray(module, last)
        case .reference(let reference):
            return try containsOverrideArray(module, reference.element)
        default:
            return false
        }
    }

    static func typeString(_ module: borrowing ShaderModule, _ type: TypeID) throws(Trap) -> String {
        switch module.types[type] {
        case .primitive(let primitive):
            return primitive.kind.name.description
        case .vector(let vector):
            return "vec\(vector.size)<\(try typeString(module, vector.element))>"
        case .matrix(let matrix):
            return "mat\(matrix.columns)x\(matrix.rows)<\(try typeString(module, matrix.element))>"
        case .array(let array):
            let element = try typeString(module, array.element)
            switch array.size {
            case .runtime: return "array<\(element)>"
            case .creationFixed(let size): return "array<\(element), \(size)>"
            case .overrideSized: throw Trap()
            }
        case .struct(let structure):
            return string(module.symbols.text(of: module[module[structure.structure].name].symbol))
        case .primitiveStruct(let structure):
            let name: String
            let value: TypeID
            switch structure.kind {
            case .frexpResult:
                name = "__frexp_result"
                value = module.types[structure.values, 0]
            case .modfResult:
                name = "__modf_result"
                value = module.types[structure.values, 0]
            case .atomicCompareExchangeResult:
                name = "__atomic_compare_exchange_result"
                value = module.types[structure.values, 0]
            }
            return "\(name)<\(try typeString(module, value))>"
        case .function(let function):
            var parameters: [String] = []
            for index in 0..<module.types.count(of: function.parameters) {
                parameters.append(try typeString(module, module.types[function.parameters, index]))
            }
            return "(\(parameters.joined(separator: ", "))) -> \(try typeString(module, function.result))"
        case .texture(let texture):
            return "\(texture.kind.name)<\(try typeString(module, texture.element))>"
        case .textureStorage(let texture):
            return "\(texture.kind.name)<\(toString(texture.format)), \(toString(texture.access))>"
        case .textureDepth(let texture):
            return texture.kind.name.description
        case .reference(let reference):
            return
                "ref<\(toString(reference.addressSpace)), \(try typeString(module, reference.element)), \(toString(reference.accessMode))>"
        case .pointer(let pointer):
            return "ptr<\(toString(pointer.addressSpace)), \(try typeString(module, pointer.element)), \(toString(pointer.accessMode))>"
        case .atomic(let atomic):
            return "atomic<\(try typeString(module, atomic.element))>"
        case .typeConstructor(let constructor):
            return constructor.name.description
        }
    }

    static func conversionRank(_ module: borrowing ShaderModule, _ from: TypeID, _ to: TypeID) -> UInt32? {
        if from == to {
            return 0
        }
        if case .reference(let reference) = module.types[from] {
            return reference.accessMode == .write ? nil : conversionRank(module, reference.element, to)
        }
        if case .reference(let reference) = module.types[to] {
            return reference.accessMode == .write ? nil : conversionRank(module, from, reference.element)
        }
        switch (module.types[from], module.types[to]) {
        case (.primitive(let from), .primitive(let to)):
            switch (from.kind, to.kind) {
            case (.abstractFloat, .f32): return 1
            case (.abstractFloat, .f16): return 2
            case (.abstractInt, .i32): return 3
            case (.abstractInt, .u32): return 4
            case (.abstractInt, .abstractFloat): return 5
            case (.abstractInt, .f32): return 6
            case (.abstractInt, .f16): return 7
            default: return nil
            }
        case (.vector(let from), .vector(let to)):
            return from.size == to.size ? conversionRank(module, from.element, to.element) : nil
        case (.matrix(let from), .matrix(let to)):
            return from.columns == to.columns && from.rows == to.rows ? conversionRank(module, from.element, to.element) : nil
        case (.array(let from), .array(let to)):
            return from.size == to.size ? conversionRank(module, from.element, to.element) : nil
        case (.primitiveStruct(let from), .primitiveStruct(let to)):
            guard from.kind == to.kind, from.kind != .atomicCompareExchangeResult else {
                return nil
            }
            return conversionRank(module, module.types[from.values, 0], module.types[to.values, 0])
        default:
            return nil
        }
    }
}

// MARK: - Random type trees

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

private let scalarTypes: [TypeID] = [
    FixedTypeID.abstractInt, FixedTypeID.abstractFloat, FixedTypeID.bool, FixedTypeID.i32, FixedTypeID.u32, FixedTypeID.f32,
    FixedTypeID.f16,
]

private let fixedTypes: [TypeID] = [
    FixedTypeID.abstractInt, FixedTypeID.abstractFloat, FixedTypeID.void, FixedTypeID.bool, FixedTypeID.i32, FixedTypeID.u32,
    FixedTypeID.f32, FixedTypeID.f16, FixedTypeID.sampler, FixedTypeID.samplerComparison, FixedTypeID.textureExternal,
    FixedTypeID.accessMode, FixedTypeID.texelFormat, FixedTypeID.addressSpace, FixedTypeID.textureDepth2d,
    FixedTypeID.textureDepth2dArray, FixedTypeID.textureDepthCube, FixedTypeID.textureDepthCubeArray,
    FixedTypeID.textureDepthMultisampled2d, FixedTypeID.atomicI32, FixedTypeID.atomicU32,
]

private func randomLeaf(_ module: inout ShaderModule, _ rng: inout SplitMix64) -> TypeID {
    switch rng.below(9) {
    case 0, 1:
        return scalarTypes[rng.below(scalarTypes.count)]
    case 2:
        return fixedTypes[rng.below(fixedTypes.count)]
    case 3:
        let kind = Types.Texture.Kind.allCases[rng.below(Types.Texture.Kind.allCases.count)]
        return module.types.textureType(kind, [FixedTypeID.f32, FixedTypeID.i32, FixedTypeID.u32][rng.below(3)])
    case 4:
        return module.types.textureStorageType(
            Types.TextureStorage.Kind.allCases[rng.below(Types.TextureStorage.Kind.allCases.count)],
            TexelFormat.allCases[rng.below(TexelFormat.allCases.count)],
            AccessMode.allCases[rng.below(AccessMode.allCases.count)]
        )
    case 5:
        let kinds: [Types.TypeConstructor.Kind] = [
            .pointer, .atomic, .vector(UInt8(2 + rng.below(3))), .matrix(columns: UInt8(2 + rng.below(3)), rows: UInt8(2 + rng.below(3))),
            .texture(.texture2d), .textureStorage(.textureStorage3d),
        ]
        return module.types.typeConstructorType(kinds[rng.below(kinds.count)])
    case 6:
        // TypeCheck only makes vectors and matrices of scalars.
        return module.types.vectorType(UInt8(2 + rng.below(3)), scalarTypes[rng.below(scalarTypes.count)])
    case 7:
        let element = [FixedTypeID.f16, FixedTypeID.f32, FixedTypeID.abstractFloat][rng.below(3)]
        return module.types.matrixType(UInt8(2 + rng.below(3)), UInt8(2 + rng.below(3)), element)
    default:
        return module.types.atomicCompareExchangeResultType(rng.below(2) == 0 ? FixedTypeID.i32 : FixedTypeID.u32)
    }
}

private func randomArraySize(_ module: inout ShaderModule, _ rng: inout SplitMix64) -> Types.Array.Size {
    switch rng.below(8) {
    case 0, 1:
        return .runtime
    case 2:
        let values: [ConstantValue?] = [
            nil, .int32(3), .int32(-1), .uint32(7), .uint32(.max), .int64(2), .int64(1 << 33), .int64(-5), .bool(true),
        ]
        return .overrideSized(makeArrayCount(&module, values[rng.below(values.count)]))
    default:
        let sizes: [UInt32] = [1, 2, 3, 4, 7, 100, 1 << 20, 1 << 30, .max]
        return .creationFixed(sizes[rng.below(sizes.count)])
    }
}

private func randomStructureLayout(_ rng: inout SplitMix64) -> (size: UInt32?, alignment: UInt32?) {
    let sizes: [UInt32?] = [nil, 1, 4, 12, 16, 80, 1000, .max - 3, .max]
    let alignments: [UInt32?] = [nil, 1, 2, 4, 8, 16, 256]
    return (sizes[rng.below(sizes.count)], alignments[rng.below(alignments.count)])
}

/// A random type whose structure is `depth` deep along one spine; the other children are at most 2 deep.
private func randomType(_ module: inout ShaderModule, _ rng: inout SplitMix64, depth: Int, structures: inout Int) -> TypeID {
    if depth == 0 {
        return randomLeaf(&module, &rng)
    }
    let shallow = rng.below(min(depth, 3))
    if depth <= 3 && rng.below(4) == 0 {
        // Not made by TypeCheck, but it exercises the enclosing-type stacks with vector and matrix factors.
        let element = randomType(&module, &rng, depth: depth - 1, structures: &structures)
        return rng.below(2) == 0
            ? module.types.vectorType(UInt8(2 + rng.below(3)), element)
            : module.types.matrixType(UInt8(2 + rng.below(3)), UInt8(2 + rng.below(3)), element)
    }
    switch rng.below(10) {
    case 0, 1, 2:
        let element = randomType(&module, &rng, depth: depth - 1, structures: &structures)
        return module.types.arrayType(element, randomArraySize(&module, &rng))
    case 3, 4, 5:
        var memberTypes: [TypeID] = []
        let count = 1 + rng.below(3)
        let spine = rng.below(count)
        for index in 0..<count {
            memberTypes.append(randomType(&module, &rng, depth: index == spine ? depth - 1 : shallow, structures: &structures))
        }
        let layout = randomStructureLayout(&rng)
        structures += 1
        let role: StructureRole = rng.below(3) == 0 ? .userDefinedResource : .userDefined
        return makeStructure(&module, "S\(structures)", memberTypes, size: layout.size, alignment: layout.alignment, role: role)
    case 6:
        let first = randomType(&module, &rng, depth: depth - 1, structures: &structures)
        let second = randomType(&module, &rng, depth: shallow, structures: &structures)
        return rng.below(2) == 0 ? module.types.frexpResultType(first, second) : module.types.modfResultType(second, first)
    case 7, 8:
        let element = randomType(&module, &rng, depth: depth - 1, structures: &structures)
        let addressSpace = AddressSpace.allCases[rng.below(AddressSpace.allCases.count)]
        let accessMode = AccessMode.allCases[rng.below(AccessMode.allCases.count)]
        return rng.below(2) == 0
            ? module.types.referenceType(addressSpace, element, accessMode) : module.types.pointerType(addressSpace, element, accessMode)
    default:
        var parameters: [TypeID] = []
        for _ in 0..<rng.below(3) {
            parameters.append(randomType(&module, &rng, depth: shallow, structures: &structures))
        }
        let result = randomType(&module, &rng, depth: depth - 1, structures: &structures)
        return module.types.functionType(parameters, result, mustUse: false, isEntryPoint: false)
    }
}

/// A random type of the kinds a conversion rank walks through, `depth` deep, with abstract leaves.
private func randomConvertibleType(_ module: inout ShaderModule, _ rng: inout SplitMix64, depth: Int) -> TypeID {
    let abstract = [FixedTypeID.abstractInt, FixedTypeID.abstractFloat]
    if depth == 0 {
        return abstract[rng.below(2)]
    }
    if depth == 1 {
        switch rng.below(3) {
        case 0: return module.types.vectorType(UInt8(2 + rng.below(3)), abstract[rng.below(2)])
        case 1: return module.types.matrixType(UInt8(2 + rng.below(3)), UInt8(2 + rng.below(3)), FixedTypeID.abstractFloat)
        default: return abstract[rng.below(2)]
        }
    }
    let element = randomConvertibleType(&module, &rng, depth: depth - 1)
    switch rng.below(6) {
    case 0:
        return module.types.referenceType(.function, element, rng.below(2) == 0 ? .read : .readWrite)
    case 1:
        return module.types.frexpResultType(element, FixedTypeID.abstractInt)
    case 2:
        return module.types.modfResultType(element, element)
    default:
        return module.types.arrayType(element, rng.below(4) == 0 ? .runtime : .creationFixed(UInt32(1 + rng.below(3))))
    }
}

/// `type` with its abstract leaves randomly concretised, and now and then a reference or a different vector size, so the
/// two have a conversion rank most of the time.
private func randomConversionTarget(_ module: inout ShaderModule, _ rng: inout SplitMix64, _ type: TypeID) -> TypeID {
    var target: TypeID
    switch module.types[type] {
    case .primitive(let primitive):
        switch primitive.kind {
        case .abstractInt:
            target =
                [FixedTypeID.abstractInt, FixedTypeID.i32, FixedTypeID.u32, FixedTypeID.abstractFloat, FixedTypeID.f32, FixedTypeID.f16][
                    rng.below(6)
                ]
        case .abstractFloat:
            target = [FixedTypeID.abstractFloat, FixedTypeID.f32, FixedTypeID.f16, FixedTypeID.i32][rng.below(4)]
        default:
            target = type
        }
    case .vector(let vector):
        let size = rng.below(8) == 0 ? UInt8(2 + rng.below(3)) : vector.size
        target = module.types.vectorType(size, randomConversionTarget(&module, &rng, vector.element))
    case .matrix(let matrix):
        target = module.types.matrixType(matrix.columns, matrix.rows, randomConversionTarget(&module, &rng, matrix.element))
    case .array(let array):
        target = module.types.arrayType(randomConversionTarget(&module, &rng, array.element), array.size)
    case .primitiveStruct(let structure):
        let fract = randomConversionTarget(&module, &rng, module.types[structure.values, 0])
        let second = module.types[structure.values, 1]
        switch structure.kind {
        case .frexpResult: target = module.types.frexpResultType(fract, second)
        case .modfResult: target = module.types.modfResultType(fract, second)
        case .atomicCompareExchangeResult: target = type
        }
    case .reference(let reference):
        target = module.types.referenceType(
            reference.addressSpace,
            randomConversionTarget(&module, &rng, reference.element),
            reference.accessMode
        )
    default:
        target = type
    }
    if rng.below(10) == 0 {
        target = module.types.referenceType(.function, target, AccessMode.allCases[rng.below(AccessMode.allCases.count)])
    }
    return target
}

/// Every query of `type` that the transcription says does not trap, compared with the transcription.
private func mismatches(_ module: borrowing ShaderModule, _ type: TypeID, compared: inout [String: Int]) -> [String] {
    var found: [String] = []
    do {
        let expected = try Transcription.maybeSize(module, type)
        compared["maybeSize", default: 0] += 1
        if module.maybeSize(of: type)?.bytes != expected {
            found.append("maybeSize")
        }
        if let expected, module.size(of: type).bytes != expected {
            found.append("size")
        }
    } catch {}
    do {
        let expected = try Transcription.alignment(module, type)
        compared["alignment", default: 0] += 1
        if module.alignment(of: type) != expected {
            found.append("alignment")
        }
    } catch {}
    if case .array(let array) = module.types[type] {
        do {
            let elementAlignment = try Transcription.alignment(module, array.element)
            let elementSize = try Transcription.size(module, array.element)
            compared["stride", default: 0] += 1
            if module.stride(of: array).bytes != (elementSize &+ (elementAlignment &- 1)) & ~(elementAlignment &- 1) {
                found.append("stride")
            }
        } catch {}
    }
    compared["packing", default: 0] += 1
    if module.packing(of: type) != Transcription.packing(module, type) {
        found.append("packing")
    }
    do {
        let expected = try Transcription.isConstructible(module, type)
        compared["isConstructible", default: 0] += 1
        if module.isConstructible(type) != expected {
            found.append("isConstructible")
        }
    } catch {}
    do {
        let expected = try Transcription.isStorable(module, type)
        compared["isStorable", default: 0] += 1
        if module.isStorable(type) != expected {
            found.append("isStorable")
        }
    } catch {}
    do {
        let expected = try Transcription.isHostShareable(module, type)
        compared["isHostShareable", default: 0] += 1
        if module.isHostShareable(type) != expected {
            found.append("isHostShareable")
        }
    } catch {}
    do {
        let expected = try Transcription.hasFixedFootprint(module, type)
        compared["hasFixedFootprint", default: 0] += 1
        if module.hasFixedFootprint(type) != expected {
            found.append("hasFixedFootprint")
        }
    } catch {}
    do {
        let expected = try Transcription.hasCreationFixedFootprint(module, type)
        compared["hasCreationFixedFootprint", default: 0] += 1
        if module.hasCreationFixedFootprint(type) != expected {
            found.append("hasCreationFixedFootprint")
        }
    } catch {}
    do {
        let expected = try Transcription.containsRuntimeArray(module, type)
        compared["containsRuntimeArray", default: 0] += 1
        if module.containsRuntimeArray(type) != expected {
            found.append("containsRuntimeArray")
        }
    } catch {}
    do {
        let expected = try Transcription.containsOverrideArray(module, type)
        compared["containsOverrideArray", default: 0] += 1
        if module.containsOverrideArray(type) != expected {
            found.append("containsOverrideArray")
        }
    } catch {}
    do {
        let expected = try Transcription.typeString(module, type)
        compared["typeString", default: 0] += 1
        if string(module.typeString(type)) != expected {
            found.append("typeString")
        }
    } catch {}
    return found
}

/// The nesting depth of `type`, through every child.
private func depth(_ module: borrowing ShaderModule, _ type: TypeID) -> Int {
    var children: [TypeID] = []
    switch module.types[type] {
    case .vector(let vector): children = [vector.element]
    case .matrix(let matrix): children = [matrix.element]
    case .array(let array): children = [array.element]
    case .struct(let structure):
        let members = module[structure.structure].members
        for index in 0..<module.count(members) {
            if let member = module.inferredType(of: module[module[members, index]].type) {
                children.append(member)
            }
        }
    case .primitiveStruct(let structure): children = module.types.elements(of: structure.values)
    case .function(let function): children = module.types.elements(of: function.parameters) + [function.result]
    case .texture(let texture): children = [texture.element]
    case .reference(let reference): children = [reference.element]
    case .pointer(let pointer): children = [pointer.element]
    case .atomic(let atomic): children = [atomic.element]
    case .primitive, .textureStorage, .textureDepth, .typeConstructor: break
    }
    var deepest = 0
    for child in children {
        deepest = max(deepest, 1 + depth(module, child))
    }
    return deepest
}

// MARK: - Deep chains

/// The results of every recursive query of one type.
private struct QueryResults: Equatable, Sendable {
    var size: UInt32
    var alignment: UInt32
    var packing: UInt8
    var isConstructible: Bool
    var isStorable: Bool
    var isHostShareable: Bool
    var hasFixedFootprint: Bool
    var hasCreationFixedFootprint: Bool
    var containsRuntimeArray: Bool
    var containsOverrideArray: Bool
    var typeString: String
    var conversionRank: UInt32?
}

private func queryResults(_ module: borrowing ShaderModule, _ type: TypeID, convertingFrom other: TypeID) -> QueryResults {
    QueryResults(
        size: module.size(of: type).bytes,
        alignment: module.alignment(of: type),
        packing: module.packing(of: type).rawValue,
        isConstructible: module.isConstructible(type),
        isStorable: module.isStorable(type),
        isHostShareable: module.isHostShareable(type),
        hasFixedFootprint: module.hasFixedFootprint(type),
        hasCreationFixedFootprint: module.hasCreationFixedFootprint(type),
        containsRuntimeArray: module.containsRuntimeArray(type),
        containsOverrideArray: module.containsOverrideArray(type),
        typeString: string(module.typeString(type)),
        conversionRank: module.conversionRank(other, type)
    )
}

private final class ThreadResult<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func complete(_ result: Value) {
        value.withLock { $0 = result }
        done.signal()
    }

    func wait() -> Value? {
        done.wait()
        return value.withLock { $0 }
    }
}

/// Runs `body` on the 16 MiB compile thread in -Onone builds (`onCompileThread`), else on a 512 KiB thread, the stack of the
/// WebGPU work queue; returns the stack size it ran with too.
private func onTypeQueryThread<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> (stackSize: Int, value: Value)? {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in (Thread.current.stackSize, body()) }
    }
    let result = ThreadResult<(stackSize: Int, value: Value)>()
    let thread = Thread {
        result.complete((Thread.current.stackSize, body()))
    }
    thread.stackSize = typeQueryThreadStackSize
    thread.start()
    return result.wait()
}

private let typeQueryThreadStackSize = 512 * 1024

private let chainDepth = 10_000

@Suite
struct WGSLTypeQueryTests {
    // Sizes and alignments of the members of a structure, as the C++ computed them for the same types.
    @Test
    func sizeAndAlignmentMatchTheCxxReference() {
        var module = makeModule()
        let f16 = module.types.f16Type
        let f32 = module.types.f32Type
        let vec3f32 = module.types.vectorType(3, f32)
        let mat2x3f32 = module.types.matrixType(2, 3, f32)
        let cases: [(TypeID, UInt32, UInt32)] = [
            (f16, 2, 2),
            (module.types.boolType, 1, 1),
            (module.types.u32Type, 4, 4),
            (module.types.vectorType(2, f16), 4, 4),
            (module.types.vectorType(3, f16), 6, 8),
            (module.types.vectorType(4, f16), 8, 8),
            (module.types.matrixType(2, 2, f16), 8, 4),
            (module.types.matrixType(2, 3, f16), 16, 8),
            (module.types.matrixType(3, 4, f16), 24, 8),
            (module.types.matrixType(4, 3, f32), 64, 16),
            (module.types.arrayType(module.types.vectorType(3, f16), .creationFixed(3)), 24, 8),
            (module.types.arrayType(mat2x3f32, .creationFixed(2)), 64, 16),
            (module.types.matrixType(3, 2, f32), 24, 8),
            (module.types.vectorType(3, module.types.i32Type), 12, 16),
            (module.types.arrayType(module.types.arrayType(vec3f32, .creationFixed(2)), .creationFixed(3)), 96, 16),
            (module.types.matrixType(4, 4, f32), 64, 16),
            (module.types.vectorType(2, module.types.u32Type), 8, 8),
            (module.types.atomicType(module.types.u32Type), 4, 4),
            (module.types.matrixType(3, 3, f32), 48, 16),
            (vec3f32, 12, 16),
        ]
        for (type, size, alignment) in cases {
            #expect(module.size(of: type).bytes == size, "size of \(string(module.typeString(type)))")
            #expect(module.maybeSize(of: type)?.bytes == size, "maybeSize of \(string(module.typeString(type)))")
            #expect(module.alignment(of: type) == alignment, "alignment of \(string(module.typeString(type)))")
        }
    }

    @Test
    func unsizedTypesHaveNoSize() {
        var module = makeModule()
        var unsized: [TypeID] = [
            module.types.voidType, module.types.abstractIntType, module.types.abstractFloatType, module.types.samplerType,
            module.types.samplerComparisonType, module.types.textureExternalType, module.types.accessModeType,
            module.types.texelFormatType, module.types.addressSpaceType, module.types.textureDepth2dType,
        ]
        unsized.append(module.types.textureType(.texture2d, module.types.f32Type))
        unsized.append(module.types.textureStorageType(.textureStorage2d, .rgba8unorm, .write))
        unsized.append(module.types.referenceType(.function, module.types.f32Type, .readWrite))
        unsized.append(module.types.pointerType(.function, module.types.f32Type, .readWrite))
        unsized.append(module.types.functionType([], module.types.voidType, mustUse: false, isEntryPoint: false))
        unsized.append(module.types.typeConstructorType(.vector(3)))
        for type in unsized {
            #expect(module.maybeSize(of: type) == nil, "\(string(module.typeString(type)))")
        }
    }

    // A runtime-sized array counts as one element (Types.cpp:330), as does an override-sized one without a value.
    @Test
    func arraySizes() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let vec3f32 = module.types.vectorType(3, f32)
        #expect(module.size(of: module.types.arrayType(f32, .creationFixed(4))).bytes == 16)
        #expect(module.size(of: module.types.arrayType(vec3f32, .creationFixed(3))).bytes == 48)
        #expect(module.size(of: module.types.arrayType(vec3f32, .runtime)).bytes == 16)
        #expect(module.size(of: module.types.arrayType(f32, .runtime)).bytes == 4)
        let five = makeArrayCount(&module, .int64(5))
        #expect(module.size(of: module.types.arrayType(f32, .overrideSized(five))).bytes == 20)
        let unevaluated = makeArrayCount(&module, nil)
        #expect(module.size(of: module.types.arrayType(vec3f32, .overrideSized(unevaluated))).bytes == 16)
        let unsignedCount = makeArrayCount(&module, .uint32(3))
        #expect(module.size(of: module.types.arrayType(f32, .overrideSized(unsignedCount))).bytes == 12)
        let negative = makeArrayCount(&module, .int32(-1))
        #expect(module.size(of: module.types.arrayType(f32, .overrideSized(negative))).bytes == .max)
        let huge = makeArrayCount(&module, .int64(1 << 32))
        #expect(module.size(of: module.types.arrayType(f32, .overrideSized(huge))).bytes == .max)
        #expect(module.size(of: module.types.arrayType(f32, .creationFixed(1 << 30))).bytes == .max)
        #expect(module.size(of: module.types.arrayType(f32, .creationFixed((1 << 30) - 1))).bytes == 4 * ((1 << 30) - 1))
        // The stride wraps below the element size.
        let big = makeStructure(&module, "Big", [f32], size: .max - 3, alignment: 16)
        #expect(module.size(of: module.types.arrayType(big, .creationFixed(1))).bytes == .max)
        // Saturated sizes stay saturated.
        var nested = f32
        for _ in 0..<40 {
            nested = module.types.arrayType(nested, .creationFixed(2))
        }
        #expect(module.size(of: nested).bytes == .max)
        let array = module.types.getIf(Types.Array.self, module.types.arrayType(vec3f32, .creationFixed(3)))
        if let array {
            #expect(module.stride(of: array).bytes == 16)
        }
        #expect(array != nil)
    }

    // The structure's size and alignment are the AST's (AttributeValidator computes them).
    @Test
    func structureSizesComeFromTheAST() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let s = makeStructure(
            &module,
            "S",
            [module.types.vectorType(3, f32), module.types.matrixType(3, 3, f32), module.types.f16Type],
            size: 80,
            alignment: 16
        )
        #expect(module.size(of: s).bytes == 80)
        #expect(module.alignment(of: s) == 16)
        #expect(module.size(of: module.types.arrayType(s, .creationFixed(2))).bytes == 160)
        let r = makeStructure(
            &module,
            "R",
            [module.types.u32Type, module.types.arrayType(module.types.vectorType(3, f32), .runtime)],
            size: 32,
            alignment: 16
        )
        #expect(module.size(of: r).bytes == 32)
        #expect(module.containsRuntimeArray(r) == true)
        #expect(module.containsRuntimeArray(module.types.referenceType(.storage, r, .readWrite)) == true)
        let odd = makeStructure(&module, "Odd", [f32], size: 7, alignment: 4)
        #expect(module.size(of: module.types.arrayType(odd, .creationFixed(3))).bytes == 24)
    }

    // A primitive struct's size is the plain sum of its values' sizes and its alignment their maximum.
    @Test
    func primitiveStructLayout() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let i32 = module.types.i32Type
        let frexp = module.types.frexpResultType(f32, i32)
        #expect(module.size(of: frexp).bytes == 8)
        #expect(module.alignment(of: frexp) == 4)
        let exchange = module.types.atomicCompareExchangeResultType(i32)
        #expect(module.size(of: exchange).bytes == 5)
        #expect(module.alignment(of: exchange) == 4)
        let vectorFrexp = module.types.frexpResultType(module.types.vectorType(3, f32), module.types.vectorType(3, i32))
        #expect(module.size(of: vectorFrexp).bytes == 24)
        #expect(module.alignment(of: vectorFrexp) == 16)
        #expect(module.size(of: module.types.arrayType(vectorFrexp, .creationFixed(2))).bytes == 64)
        let modf = module.types.modfResultType(
            module.types.vectorType(2, module.types.f16Type),
            module.types.vectorType(2, module.types.f16Type)
        )
        #expect(module.size(of: modf).bytes == 8)
        #expect(module.alignment(of: modf) == 4)
    }

    @Test
    func packing() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let vec3 = module.types.vectorType(3, f32)
        let packedArray: Packing = [.packed, .vec3, .pArray]
        #expect(module.packing(of: f32) == .unpacked)
        #expect(module.packing(of: vec3) == .packedVec3)
        #expect(module.packing(of: module.types.vectorType(2, f32)) == .unpacked)
        #expect(module.packing(of: module.types.matrixType(2, 3, f32)) == .packedVec3)
        #expect(module.packing(of: module.types.matrixType(4, 3, f32)) == .packedVec3)
        #expect(module.packing(of: module.types.matrixType(3, 2, f32)) == .unpacked)
        #expect(module.packing(of: module.types.arrayType(vec3, .creationFixed(2))) == packedArray)
        #expect(module.packing(of: module.types.arrayType(module.types.arrayType(vec3, .runtime), .creationFixed(2))) == packedArray)
        #expect(module.packing(of: module.types.arrayType(f32, .runtime)) == .unpacked)
        #expect(module.packing(of: module.types.referenceType(.storage, vec3, .read)) == .packedVec3)
        let resource = makeStructure(&module, "Resource", [vec3], size: 16, alignment: 16, role: .userDefinedResource)
        let plain = makeStructure(&module, "Plain", [vec3], size: 16, alignment: 16)
        #expect(module.packing(of: resource) == .packedStruct)
        #expect(module.packing(of: plain) == .unpacked)
        #expect(module.packing(of: module.types.arrayType(resource, .runtime)) == [.packed, .pStruct, .pArray])
        #expect(
            module.packing(of: module.types.referenceType(.storage, module.types.arrayType(resource, .creationFixed(4)), .read)) == [
                .packed, .pStruct, .pArray,
            ]
        )
        #expect(module.packing(of: module.types.atomicType(module.types.i32Type)) == .unpacked)
    }

    @Test
    func conversionRanks() {
        var module = makeModule()
        let types: (ai: TypeID, af: TypeID, i32: TypeID, u32: TypeID, f32: TypeID, f16: TypeID, bool: TypeID) = (
            module.types.abstractIntType, module.types.abstractFloatType, module.types.i32Type, module.types.u32Type,
            module.types.f32Type, module.types.f16Type, module.types.boolType
        )
        #expect(module.conversionRank(types.i32, types.i32) == 0)
        #expect(module.conversionRank(types.af, types.f32) == 1)
        #expect(module.conversionRank(types.af, types.f16) == 2)
        #expect(module.conversionRank(types.ai, types.i32) == 3)
        #expect(module.conversionRank(types.ai, types.u32) == 4)
        #expect(module.conversionRank(types.ai, types.af) == 5)
        #expect(module.conversionRank(types.ai, types.f32) == 6)
        #expect(module.conversionRank(types.ai, types.f16) == 7)
        #expect(module.conversionRank(types.i32, types.u32) == nil)
        #expect(module.conversionRank(types.f32, types.af) == nil)
        #expect(module.conversionRank(types.af, types.i32) == nil)
        #expect(module.conversionRank(types.bool, types.i32) == nil)
        let vec3ai = module.types.vectorType(3, types.ai)
        #expect(module.conversionRank(vec3ai, module.types.vectorType(3, types.f32)) == 6)
        #expect(module.conversionRank(vec3ai, module.types.vectorType(2, types.f32)) == nil)
        #expect(module.conversionRank(vec3ai, types.f32) == nil)
        #expect(module.conversionRank(module.types.matrixType(2, 3, types.af), module.types.matrixType(2, 3, types.f16)) == 2)
        #expect(module.conversionRank(module.types.matrixType(2, 3, types.af), module.types.matrixType(3, 3, types.f16)) == nil)
        #expect(module.conversionRank(module.types.matrixType(2, 3, types.af), module.types.matrixType(2, 2, types.f16)) == nil)
        let arrayAI = module.types.arrayType(types.ai, .creationFixed(2))
        #expect(module.conversionRank(arrayAI, module.types.arrayType(types.u32, .creationFixed(2))) == 4)
        #expect(module.conversionRank(arrayAI, module.types.arrayType(types.u32, .creationFixed(3))) == nil)
        #expect(module.conversionRank(arrayAI, module.types.arrayType(types.u32, .runtime)) == nil)
        #expect(module.conversionRank(module.types.referenceType(.function, types.ai, .read), types.i32) == 3)
        #expect(module.conversionRank(module.types.referenceType(.function, types.ai, .readWrite), types.i32) == 3)
        #expect(module.conversionRank(module.types.referenceType(.function, types.ai, .write), types.i32) == nil)
        #expect(module.conversionRank(types.ai, module.types.referenceType(.function, types.i32, .read)) == 3)
        #expect(module.conversionRank(types.ai, module.types.referenceType(.function, types.i32, .write)) == nil)
        let frexpAF = module.types.frexpResultType(types.af, types.ai)
        #expect(module.conversionRank(frexpAF, module.types.frexpResultType(types.f32, types.i32)) == 1)
        #expect(
            module.conversionRank(module.types.modfResultType(types.af, types.af), module.types.modfResultType(types.f16, types.f16)) == 2
        )
        #expect(module.conversionRank(frexpAF, module.types.modfResultType(types.f32, types.f32)) == nil)
        let exchangeI32 = module.types.atomicCompareExchangeResultType(types.i32)
        #expect(module.conversionRank(exchangeI32, exchangeI32) == 0)
        #expect(module.conversionRank(exchangeI32, module.types.atomicCompareExchangeResultType(types.u32)) == nil)
        let s = makeStructure(&module, "S", [types.f32], size: 4, alignment: 4)
        let t = makeStructure(&module, "T", [types.f32], size: 4, alignment: 4)
        #expect(module.conversionRank(s, s) == 0)
        #expect(module.conversionRank(s, t) == nil)
        #expect(module.types.conversionRank(types.ai, types.f32) == 6)
    }

    @Test
    func predicates() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let runtime = module.types.arrayType(f32, .runtime)
        let fixed = module.types.arrayType(f32, .creationFixed(4))
        let overrideSized = module.types.arrayType(f32, .overrideSized(makeArrayCount(&module, .uint32(4))))
        let atomic = module.types.atomicType(module.types.u32Type)
        let sampler = module.types.samplerType
        let withRuntime = makeStructure(&module, "WithRuntime", [f32, runtime], size: 8, alignment: 4)
        let withOverride = makeStructure(&module, "WithOverride", [f32, overrideSized], size: 20, alignment: 4)
        let runtimeFirst = makeStructure(&module, "RuntimeFirst", [runtime, f32], size: 8, alignment: 4)
        let withAtomic = makeStructure(&module, "WithAtomic", [atomic], size: 4, alignment: 4)
        let withBool = makeStructure(&module, "WithBool", [module.types.boolType], size: 1, alignment: 1)
        let nested = makeStructure(&module, "Nested", [withRuntime], size: 8, alignment: 4)
        let frexp = module.types.frexpResultType(f32, module.types.i32Type)
        let storage = module.types.textureStorageType(.textureStorage2d, .rgba8unorm, .write)
        let reference = module.types.referenceType(.storage, withRuntime, .readWrite)

        // (type, constructible, storable, host-shareable, fixed footprint, creation-fixed footprint, runtime array, override array)
        let cases: [(TypeID, [Bool])] = [
            (f32, [true, true, true, true, true, false, false]),
            (module.types.boolType, [true, true, false, true, true, false, false]),
            (module.types.abstractIntType, [true, false, false, false, false, false, false]),
            (module.types.vectorType(3, module.types.boolType), [true, true, false, true, true, false, false]),
            (module.types.matrixType(2, 2, f32), [true, true, true, true, true, false, false]),
            (fixed, [true, true, true, true, true, false, false]),
            (runtime, [false, true, true, false, false, true, false]),
            (overrideSized, [false, true, true, true, false, false, true]),
            (atomic, [false, true, true, true, true, false, false]),
            (sampler, [false, true, false, false, false, false, false]),
            (module.types.textureExternalType, [false, true, false, false, false, false, false]),
            (storage, [false, true, false, false, false, false, false]),
            (module.types.textureDepth2dType, [false, true, false, false, false, false, false]),
            (module.types.textureType(.texture2d, f32), [false, false, false, false, false, false, false]),
            (frexp, [true, false, false, false, false, false, false]),
            (withRuntime, [false, true, true, false, false, true, false]),
            (withOverride, [false, true, true, true, false, false, true]),
            (runtimeFirst, [false, true, true, false, false, false, false]),
            (withAtomic, [false, true, true, true, true, false, false]),
            (withBool, [true, true, false, true, true, false, false]),
            (nested, [false, true, true, false, false, true, false]),
            (reference, [false, false, false, false, false, true, false]),
            (module.types.pointerType(.storage, withRuntime, .readWrite), [false, false, false, false, false, false, false]),
            (
                module.types.functionType([f32], f32, mustUse: false, isEntryPoint: false),
                [false, false, false, false, false, false, false]
            ),
            (module.types.typeConstructorType(.atomic), [false, false, false, false, false, false, false]),
        ]
        for (type, expected) in cases {
            let actual = [
                module.isConstructible(type), module.isStorable(type), module.isHostShareable(type), module.hasFixedFootprint(type),
                module.hasCreationFixedFootprint(type), module.containsRuntimeArray(type), module.containsOverrideArray(type),
            ]
            #expect(actual == expected, "\(string(module.typeString(type)))")
        }
    }

    @Test
    func texturesSamplersAndPrimitives() {
        var module = makeModule()
        let f32 = module.types.f32Type
        #expect(module.isTexture(module.types.textureExternalType) == true)
        #expect(module.isTexture(module.types.textureType(.textureCube, f32)) == true)
        #expect(module.isTexture(module.types.textureStorageType(.textureStorage1d, .r32float, .read)) == true)
        #expect(module.isTexture(module.types.textureDepthCubeType) == true)
        #expect(module.isTexture(module.types.samplerType) == false)
        #expect(module.isTexture(f32) == false)
        #expect(module.isSampler(module.types.samplerType) == true)
        #expect(module.isSampler(module.types.samplerComparisonType) == true)
        #expect(module.isSampler(module.types.textureExternalType) == false)
        #expect(module.isSampler(module.types.textureDepth2dType) == false)
        #expect(module.isPrimitive(f32, .f32) == true)
        #expect(module.isPrimitive(f32, .f16) == false)
        #expect(module.isPrimitive(nil, .f32) == false)
        #expect(module.isPrimitive(module.types.vectorType(2, f32), .f32) == false)
        let reference = module.types.referenceType(.function, module.types.boolType, .readWrite)
        #expect(module.isPrimitiveReference(reference, .bool) == true)
        #expect(module.isPrimitiveReference(reference, .i32) == false)
        #expect(module.isPrimitiveReference(module.types.boolType, .bool) == false)
        #expect(module.isPrimitiveReference(nil, .bool) == false)
        for format in TexelFormat.allCases {
            let spelling = toString(format).description
            let expected: TypeID
            if spelling.hasSuffix("uint") {
                expected = module.types.u32Type
            } else if spelling.hasSuffix("sint") {
                expected = module.types.i32Type
            } else {
                expected = f32
            }
            #expect(shaderTypeForTexelFormat(format, module.types) == expected, "\(spelling)")
        }
    }

    // The member loops read a member's inferred type only when the C++ does: they stop at the first member that fails,
    // and containsRuntimeArray reads only the last member.
    @Test
    func memberWalksReadMemberTypesLazily() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let untyped = module.constructIdentifierExpression(span: .empty, identifier: module.makeIdentifier("t"))
        let untypedMember = module.constructStructureMember(
            span: .empty,
            name: module.makeIdentifier("u"),
            type: untyped,
            attributes: module.makeEmptyList(AttributeID.self)
        )
        func structure(_ module: inout ShaderModule, _ first: TypeID, untypedLast: Bool) -> TypeID {
            let typed = module.constructIdentifierExpression(span: .empty, identifier: module.makeIdentifier("t"))
            module.setInferredType(first, for: typed)
            let typedMember = module.constructStructureMember(
                span: .empty,
                name: module.makeIdentifier("m"),
                type: typed,
                attributes: module.makeEmptyList(AttributeID.self)
            )
            let members = untypedLast ? [typedMember, untypedMember] : [untypedMember, typedMember]
            let structure = module.constructStructure(
                span: .empty,
                name: module.makeIdentifier("S"),
                members: module.makeList(members),
                role: .userDefined
            )
            return module.types.structType(structure)
        }
        let runtimeFirst = structure(&module, module.types.arrayType(f32, .runtime), untypedLast: true)
        #expect(module.isConstructible(runtimeFirst) == false)
        #expect(module.hasFixedFootprint(runtimeFirst) == false)
        #expect(module.hasCreationFixedFootprint(runtimeFirst) == false)
        let textureFirst = structure(&module, module.types.textureType(.texture2d, f32), untypedLast: true)
        #expect(module.isStorable(textureFirst) == false)
        #expect(module.isHostShareable(textureFirst) == false)
        let nested = structure(&module, runtimeFirst, untypedLast: true)
        #expect(module.isConstructible(nested) == false)
        let runtimeLast = structure(&module, module.types.arrayType(f32, .runtime), untypedLast: false)
        #expect(module.containsRuntimeArray(runtimeLast) == true)
        let overrideLast = structure(&module, module.types.arrayType(f32, .overrideSized(makeArrayCount(&module, nil))), untypedLast: false)
        #expect(module.containsOverrideArray(overrideLast) == true)
    }

    // The C++ spellings (Type::toString) of the same types.
    @Test
    func typeStringMatchesTheCxxSpellings() {
        var module = makeModule()
        let f32 = module.types.f32Type
        let f16 = module.types.f16Type
        let i32 = module.types.i32Type
        let u32 = module.types.u32Type
        let vec2f16 = module.types.vectorType(2, f16)
        let vec3f32 = module.types.vectorType(3, f32)
        let aa = module.types.arrayType(module.types.arrayType(vec2f16, .creationFixed(3)), .creationFixed(2))
        let type0 = makeStructure(&module, "type0", [vec3f32], size: 80, alignment: 16)
        let atomicI32 = module.types.atomicType(i32)
        let pointerToI32 = module.types.pointerType(.function, i32, .readWrite)
        let cases: [(TypeID, String)] = [
            (module.types.abstractIntType, "<AbstractInt>"),
            (module.types.abstractFloatType, "<AbstractFloat>"),
            (module.types.voidType, "void"),
            (module.types.boolType, "bool"),
            (i32, "i32"),
            (u32, "u32"),
            (f32, "f32"),
            (f16, "f16"),
            (module.types.samplerType, "sampler"),
            (module.types.samplerComparisonType, "sampler_comparison"),
            (module.types.textureExternalType, "texture_external"),
            (module.types.accessModeType, "access_mode"),
            (module.types.texelFormatType, "texel_format"),
            (module.types.addressSpaceType, "address_space"),
            (vec2f16, "vec2<f16>"),
            (vec3f32, "vec3<f32>"),
            (module.types.vectorType(4, u32), "vec4<u32>"),
            (module.types.matrixType(2, 4, f32), "mat2x4<f32>"),
            (module.types.matrixType(3, 3, f32), "mat3x3<f32>"),
            (aa, "array<array<vec2<f16>, 3>, 2>"),
            (module.types.arrayType(vec3f32, .runtime), "array<vec3<f32>>"),
            (module.types.arrayType(f32, .creationFixed(.max)), "array<f32, 4294967295>"),
            (type0, "type0"),
            (module.types.frexpResultType(f32, i32), "__frexp_result<f32>"),
            (module.types.frexpResultType(module.types.abstractFloatType, module.types.abstractIntType), "__frexp_result<<AbstractFloat>>"),
            (module.types.modfResultType(vec2f16, vec2f16), "__modf_result<vec2<f16>>"),
            (module.types.atomicCompareExchangeResultType(i32), "__atomic_compare_exchange_result<i32>"),
            (
                module.types.functionType([pointerToI32, f32], f32, mustUse: false, isEntryPoint: false),
                "(ptr<function, i32, read_write>, f32) -> f32"
            ),
            (module.types.functionType([], module.types.voidType, mustUse: true, isEntryPoint: true), "() -> void"),
            (module.types.functionType([f32], i32, mustUse: false, isEntryPoint: false), "(f32) -> i32"),
            (module.types.textureType(.texture1d, f32), "texture_1d<f32>"),
            (module.types.textureType(.texture2d, f32), "texture_2d<f32>"),
            (module.types.textureType(.texture2dArray, i32), "texture_2d_array<i32>"),
            (module.types.textureType(.texture3d, f32), "texture_3d<f32>"),
            (module.types.textureType(.textureCube, f32), "texture_cube<f32>"),
            (module.types.textureType(.textureCubeArray, f32), "texture_cube_array<f32>"),
            (module.types.textureType(.textureMultisampled2d, u32), "texture_multisampled_2d<u32>"),
            (module.types.textureStorageType(.textureStorage1d, .r32float, .read), "texture_storage_1d<r32float, read>"),
            (module.types.textureStorageType(.textureStorage2d, .rgba8unorm, .write), "texture_storage_2d<rgba8unorm, write>"),
            (
                module.types.textureStorageType(.textureStorage2dArray, .rg32sint, .readWrite),
                "texture_storage_2d_array<rg32sint, read_write>"
            ),
            (module.types.textureStorageType(.textureStorage3d, .bgra8unorm, .write), "texture_storage_3d<bgra8unorm, write>"),
            (module.types.textureDepth2dType, "texture_depth_2d"),
            (module.types.textureDepth2dArrayType, "texture_depth_2d_array"),
            (module.types.textureDepthCubeType, "texture_depth_cube"),
            (module.types.textureDepthCubeArrayType, "texture_depth_cube_array"),
            (module.types.textureDepthMultisampled2dType, "texture_depth_multisampled_2d"),
            (module.types.referenceType(.function, i32, .readWrite), "ref<function, i32, read_write>"),
            (module.types.referenceType(.function, type0, .readWrite), "ref<function, type0, read_write>"),
            (module.types.referenceType(.private, aa, .readWrite), "ref<private, array<array<vec2<f16>, 3>, 2>, read_write>"),
            (module.types.referenceType(.storage, vec3f32, .read), "ref<storage, vec3<f32>, read>"),
            (module.types.referenceType(.workgroup, atomicI32, .readWrite), "ref<workgroup, atomic<i32>, read_write>"),
            (module.types.referenceType(.uniform, f32, .read), "ref<uniform, f32, read>"),
            (module.types.referenceType(.handle, module.types.samplerType, .read), "ref<handle, sampler, read>"),
            (pointerToI32, "ptr<function, i32, read_write>"),
            (module.types.pointerType(.workgroup, atomicI32, .readWrite), "ptr<workgroup, atomic<i32>, read_write>"),
            (atomicI32, "atomic<i32>"),
            (module.types.atomicType(u32), "atomic<u32>"),
            (module.types.typeConstructorType(.pointer), "ptr"),
            (module.types.typeConstructorType(.atomic), "atomic"),
            (module.types.typeConstructorType(.vector(4)), "vec4"),
            (module.types.typeConstructorType(.matrix(columns: 2, rows: 3)), "mat2x3"),
            (module.types.typeConstructorType(.texture(.textureMultisampled2d)), "texture_multisampled_2d"),
            (module.types.typeConstructorType(.textureStorage(.textureStorage2dArray)), "texture_storage_2d_array"),
        ]
        for (type, expected) in cases {
            #expect(string(module.typeString(type)) == expected)
        }
    }

    // Measured with the C++: a struct name over 5,000,000 UTF-8 bytes prints as its first 1000 bytes, less a partial
    // character, then "...[N characters not shown]", N counting bytes.
    @Test
    func typeStringTruncatesLongNamesAsPrintStream() {
        var module = makeModule()
        var name = codeUnits(String(repeating: "a", count: 999) + "é")
        name.append(contentsOf: repeatElement(0x62, count: 5_000_000))
        let truncated = makeStructure(&module, module.symbols.intern(name), [module.types.f32Type], size: 4, alignment: 4)
        #expect(string(module.typeString(truncated)) == String(repeating: "a", count: 999) + "...[5000001 characters not shown]")
        let reference = module.types.referenceType(.function, truncated, .read)
        #expect(
            string(module.typeString(reference)) == "ref<function, " + String(repeating: "a", count: 999)
                + "...[5000001 characters not shown], read>"
        )

        let justOver = makeStructure(
            &module,
            module.symbols.intern(ContiguousArray(repeating: 0x61, count: 5_000_001)),
            [module.types.f32Type],
            size: 4,
            alignment: 4
        )
        #expect(string(module.typeString(justOver)) == String(repeating: "a", count: 1000) + "...[4999001 characters not shown]")

        let atThreshold = makeStructure(
            &module,
            module.symbols.intern(ContiguousArray(repeating: 0x61, count: 5_000_000)),
            [module.types.f32Type],
            size: 4,
            alignment: 4
        )
        #expect(module.typeString(atThreshold).codeUnits == ContiguousArray(repeating: 0x61, count: 5_000_000))

        // 2,500,001 two-byte characters are 5,000,002 UTF-8 bytes.
        let twoByte = makeStructure(
            &module,
            module.symbols.intern(ContiguousArray(repeating: 0xE9, count: 2_500_001)),
            [module.types.f32Type],
            size: 4,
            alignment: 4
        )
        #expect(string(module.typeString(twoByte)) == String(repeating: "é", count: 500) + "...[4999002 characters not shown]")
    }

    // String::tryGetUTF8 (lenient) replaces an unpaired surrogate with U+FFFD; %s stops at a NUL.
    @Test
    func typeStringConvertsNamesThroughUTF8() {
        var module = makeModule()
        let lone = makeStructure(
            &module,
            module.symbols.intern([0x61, 0xD800, 0x62, 0xDC00]),
            [module.types.f32Type],
            size: 4,
            alignment: 4
        )
        #expect(module.typeString(lone).codeUnits == [0x61, 0xFFFD, 0x62, 0xFFFD])
        let pair = makeStructure(&module, module.symbols.intern([0x61, 0xD83D, 0xDE00]), [module.types.f32Type], size: 4, alignment: 4)
        #expect(module.typeString(pair).codeUnits == [0x61, 0xD83D, 0xDE00])
        let nul = makeStructure(&module, module.symbols.intern([0x61, 0, 0x62]), [module.types.f32Type], size: 4, alignment: 4)
        #expect(string(module.typeString(module.types.vectorType(2, nul))) == "vec2<a>")
    }

    // Random type trees up to 50 deep: every query equals the recursive transcription of Types.cpp.
    @Test
    func queriesEqualTheRecursiveTranscription() {
        var rng = SplitMix64(state: 0x5747_534C_5479_7065)
        var failures: [String] = []
        var compared: [String: Int] = [:]
        var deepCompared: [String: Int] = [:]
        var deepest = 0
        var deepRanks = 0
        for tree in 0..<1000 {
            var module = makeModule()
            var structures = 0
            let type = randomType(&module, &rng, depth: tree < 50 ? tree : rng.below(50), structures: &structures)
            let treeDepth = depth(module, type)
            deepest = max(deepest, treeDepth)
            let found: [String]
            if treeDepth >= 30 {
                found = mismatches(module, type, compared: &deepCompared)
            } else {
                found = mismatches(module, type, compared: &compared)
            }
            if !found.isEmpty {
                failures.append("tree \(tree) \(found)")
            }
            for _ in 0..<4 {
                let target = randomConversionTarget(&module, &rng, type)
                let expected = Transcription.conversionRank(module, type, target)
                if module.conversionRank(type, target) != expected {
                    failures.append("tree \(tree) conversionRank to target")
                }
                if module.conversionRank(target, type) != Transcription.conversionRank(module, target, type) {
                    failures.append("tree \(tree) conversionRank from target")
                }
            }
            let other = randomType(&module, &rng, depth: rng.below(4), structures: &structures)
            if module.conversionRank(type, other) != Transcription.conversionRank(module, type, other) {
                failures.append("tree \(tree) conversionRank to other")
            }
            let convertibleDepth = tree <= 50 ? tree : rng.below(51)
            let convertible = randomConvertibleType(&module, &rng, depth: convertibleDepth)
            for _ in 0..<4 {
                let target = randomConversionTarget(&module, &rng, convertible)
                let expected = Transcription.conversionRank(module, convertible, target)
                if module.conversionRank(convertible, target) != expected {
                    failures.append("tree \(tree) conversionRank of a convertible type")
                }
                if convertibleDepth >= 30 && expected != nil && expected != 0 {
                    deepRanks += 1
                }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(deepest >= 45 && deepest <= 50)
        #expect(deepRanks >= 20)
        // Every query was compared, on shallow and on deep (>= 30) trees, rather than skipped as a trap.
        let queries = [
            "maybeSize", "alignment", "stride", "packing", "isConstructible", "isStorable", "isHostShareable", "hasFixedFootprint",
            "hasCreationFixedFootprint", "containsRuntimeArray", "containsOverrideArray", "typeString",
        ]
        for query in queries {
            #expect(compared[query, default: 0] >= 20, "\(query) compared \(compared[query, default: 0]) times")
            #expect(deepCompared[query, default: 0] >= 5, "\(query) compared \(deepCompared[query, default: 0]) times on deep trees")
        }
    }

    // An alias chain `alias A_i = array<A_{i-1}, 1>` is one level per alias (Parser and TypeCheck limit only one type
    // expression), so a valid shader can nest arrays 10,000 deep; C++ Debug overflows 512 KiB between 300 and 400.
    @Test
    func DEV_03_queriesOnA10000DeepAliasOfArrayChain() {
        let observed = onTypeQueryThread { () -> [QueryResults] in
            var module = makeModule()
            var concrete = module.types.vectorType(3, module.types.f32Type)
            var abstract = module.types.vectorType(3, module.types.abstractFloatType)
            for _ in 0..<chainDepth {
                concrete = module.types.arrayType(concrete, .creationFixed(1))
                abstract = module.types.arrayType(abstract, .creationFixed(1))
            }
            let reference = module.types.referenceType(.storage, concrete, .read)
            let saturated = module.types.arrayType(module.types.arrayType(module.types.f32Type, .runtime), .creationFixed(.max))
            var doubling = saturated
            for _ in 0..<chainDepth {
                doubling = module.types.arrayType(doubling, .creationFixed(2))
            }
            return [
                queryResults(module, concrete, convertingFrom: abstract),
                queryResults(module, doubling, convertingFrom: doubling),
                QueryResults(
                    size: 0,
                    alignment: 0,
                    packing: module.packing(of: reference).rawValue,
                    isConstructible: module.isConstructible(reference),
                    isStorable: module.isStorable(reference),
                    isHostShareable: module.isHostShareable(reference),
                    hasFixedFootprint: module.hasFixedFootprint(reference),
                    hasCreationFixedFootprint: module.hasCreationFixedFootprint(reference),
                    containsRuntimeArray: module.containsRuntimeArray(reference),
                    containsOverrideArray: module.containsOverrideArray(reference),
                    typeString: string(module.typeString(reference)),
                    conversionRank: module.conversionRank(reference, abstract)
                ),
            ]
        }
        let arrays = String(repeating: "array<", count: chainDepth)
        let counts = String(repeating: ", 1>", count: chainDepth)
        let expected = [
            QueryResults(
                size: 16,
                alignment: 16,
                packing: Packing([.packed, .vec3, .pArray]).rawValue,
                isConstructible: true,
                isStorable: true,
                isHostShareable: true,
                hasFixedFootprint: true,
                hasCreationFixedFootprint: true,
                containsRuntimeArray: false,
                containsOverrideArray: false,
                typeString: arrays + "vec3<f32>" + counts,
                conversionRank: 1
            ),
            QueryResults(
                size: .max,
                alignment: 4,
                packing: Packing.unpacked.rawValue,
                isConstructible: false,
                isStorable: true,
                isHostShareable: true,
                hasFixedFootprint: true,
                hasCreationFixedFootprint: true,
                containsRuntimeArray: false,
                containsOverrideArray: false,
                typeString: String(repeating: "array<", count: chainDepth + 2) + "f32>, 4294967295>"
                    + String(repeating: ", 2>", count: chainDepth),
                conversionRank: 0
            ),
            QueryResults(
                size: 0,
                alignment: 0,
                packing: Packing([.packed, .vec3, .pArray]).rawValue,
                isConstructible: false,
                isStorable: false,
                isHostShareable: false,
                hasFixedFootprint: false,
                hasCreationFixedFootprint: false,
                containsRuntimeArray: false,
                containsOverrideArray: false,
                typeString: "ref<storage, " + arrays + "vec3<f32>" + counts + ", read>",
                conversionRank: nil
            ),
        ]
        #expect(observed?.stackSize == CompileThread.recommendedStackSize ?? typeQueryThreadStackSize)
        #expect(observed?.value == expected)
    }

    // struct S_i { a: f32, m: S_{i-1} }, 10,000 deep, with a runtime-sized array at the bottom: the member walks visit
    // every level before they reach it.
    @Test
    func DEV_03_queriesOnA10000DeepNestedStructChain() {
        let observed = onTypeQueryThread { () -> [QueryResults] in
            var module = makeModule()
            let f32 = module.types.f32Type
            var runtimeChain = makeStructure(&module, "S0", [f32, module.types.arrayType(f32, .runtime)], size: 8, alignment: 4)
            var fixedChain = makeStructure(&module, "T0", [f32, module.types.vectorType(3, f32)], size: 32, alignment: 16)
            for level in 1...chainDepth {
                runtimeChain = makeStructure(&module, "S\(level)", [f32, runtimeChain], size: 8, alignment: 4)
                fixedChain = makeStructure(&module, "T\(level)", [f32, fixedChain], size: 32, alignment: 16)
            }
            let array = module.types.arrayType(fixedChain, .creationFixed(3))
            return [
                queryResults(module, runtimeChain, convertingFrom: runtimeChain),
                queryResults(module, fixedChain, convertingFrom: runtimeChain),
                queryResults(module, array, convertingFrom: array),
            ]
        }
        let expected = [
            QueryResults(
                size: 8,
                alignment: 4,
                packing: Packing.unpacked.rawValue,
                isConstructible: false,
                isStorable: true,
                isHostShareable: true,
                hasFixedFootprint: false,
                hasCreationFixedFootprint: false,
                containsRuntimeArray: true,
                containsOverrideArray: false,
                typeString: "S\(chainDepth)",
                conversionRank: 0
            ),
            QueryResults(
                size: 32,
                alignment: 16,
                packing: Packing.unpacked.rawValue,
                isConstructible: true,
                isStorable: true,
                isHostShareable: true,
                hasFixedFootprint: true,
                hasCreationFixedFootprint: true,
                containsRuntimeArray: false,
                containsOverrideArray: false,
                typeString: "T\(chainDepth)",
                conversionRank: nil
            ),
            QueryResults(
                size: 96,
                alignment: 16,
                packing: Packing.unpacked.rawValue,
                isConstructible: true,
                isStorable: true,
                isHostShareable: true,
                hasFixedFootprint: true,
                hasCreationFixedFootprint: true,
                containsRuntimeArray: false,
                containsOverrideArray: false,
                typeString: "array<T\(chainDepth), 3>",
                conversionRank: 0
            ),
        ]
        #expect(observed?.stackSize == CompileThread.recommendedStackSize ?? typeQueryThreadStackSize)
        #expect(observed?.value == expected)
    }
}
