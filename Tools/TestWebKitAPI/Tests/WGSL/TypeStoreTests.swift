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

import Testing
@_spi(Testing) import WGSL

private func requireBitwiseCopyable<T: BitwiseCopyable>(_: T.Type) {}

// The module and the tests are built at the same optimisation level, so this is whether WGSL's `assert`s are on.
private func assertionsAreEnabled() -> Bool {
    var enabled = false
    assert(
        {
            enabled = true
            return true
        }()
    )
    return enabled
}

private func makeStructure() -> StructureID {
    var structures = Arena<StructureID, UInt32>()
    return structures.append(0)
}

private func makeExpressions(_ count: Int) -> [ExpressionID] {
    var expressions = Arena<ExpressionID, UInt32>()
    return (0..<count).map { expressions.append(UInt32($0)) }
}

private func text(_ string: StaticString) -> String {
    string.description
}

private func spelling(_ name: ReservedName) -> String {
    guard case .fixed(let fixed) = name else {
        return ""
    }
    return fixed.spelling.description
}

// Every alternative `getIf` finds for a type, by name.
private func alternatives(_ types: borrowing TypeStore, _ type: TypeID?) -> [String] {
    var found: [String] = []
    if types.getIf(Types.Primitive.self, type) != nil { found.append("primitive") }
    if types.getIf(Types.Vector.self, type) != nil { found.append("vector") }
    if types.getIf(Types.Matrix.self, type) != nil { found.append("matrix") }
    if types.getIf(Types.Array.self, type) != nil { found.append("array") }
    if types.getIf(Types.Struct.self, type) != nil { found.append("struct") }
    if types.getIf(Types.PrimitiveStruct.self, type) != nil { found.append("primitiveStruct") }
    if types.getIf(Types.Function.self, type) != nil { found.append("function") }
    if types.getIf(Types.Texture.self, type) != nil { found.append("texture") }
    if types.getIf(Types.TextureStorage.self, type) != nil { found.append("textureStorage") }
    if types.getIf(Types.TextureDepth.self, type) != nil { found.append("textureDepth") }
    if types.getIf(Types.Reference.self, type) != nil { found.append("reference") }
    if types.getIf(Types.Pointer.self, type) != nil { found.append("pointer") }
    if types.getIf(Types.Atomic.self, type) != nil { found.append("atomic") }
    if types.getIf(Types.TypeConstructor.self, type) != nil { found.append("typeConstructor") }
    return found
}

@Suite
struct WGSLTypeStoreTests {
    @Test
    func typesAreBitwiseCopyable() {
        requireBitwiseCopyable(Type.self)
        requireBitwiseCopyable(Types.Array.Size.self)
        requireBitwiseCopyable(Types.TypeConstructor.Kind.self)
        #expect(MemoryLayout<TypeID>.size == 4)
    }

    // TypeStore.cpp:127-150.
    @Test
    func fixedIDsAreTheCxxConstructorOrder() {
        let types = TypeStore()
        #expect(types.count == Int(FixedTypeID.count))
        #expect(types.cacheCount == 0)

        let accessors = [
            types.abstractIntType, types.abstractFloatType, types.voidType, types.boolType, types.i32Type, types.u32Type,
            types.f32Type, types.f16Type, types.samplerType, types.samplerComparisonType, types.textureExternalType,
            types.accessModeType, types.texelFormatType, types.addressSpaceType, types.textureDepth2dType,
            types.textureDepth2dArrayType, types.textureDepthCubeType, types.textureDepthCubeArrayType,
            types.textureDepthMultisampled2dType,
        ]
        #expect(accessors.map(\.raw) == Array(0..<19))

        let primitives: [Types.Primitive.Kind] = [
            .abstractInt, .abstractFloat, .void, .bool, .i32, .u32, .f32, .f16, .sampler, .samplerComparison,
            .textureExternal, .accessMode, .texelFormat, .addressSpace,
        ]
        for (index, kind) in primitives.enumerated() {
            #expect(types.getIf(Types.Primitive.self, accessors[index])?.kind == kind)
        }
        let depthTextures: [Types.TextureDepth.Kind] = [
            .textureDepth2d, .textureDepth2dArray, .textureDepthCube, .textureDepthCubeArray, .textureDepthMultisampled2d,
        ]
        for (index, kind) in depthTextures.enumerated() {
            #expect(types.getIf(Types.TextureDepth.self, accessors[primitives.count + index])?.kind == kind)
        }

        #expect(FixedTypeID.atomicI32.raw == 19)
        #expect(FixedTypeID.atomicU32.raw == 20)
        #expect(types.getIf(Types.Atomic.self, FixedTypeID.atomicI32)?.element == types.i32Type)
        #expect(types.getIf(Types.Atomic.self, FixedTypeID.atomicU32)?.element == types.u32Type)

        #expect(
            primitives.map { text($0.name) } == [
                "<AbstractInt>", "<AbstractFloat>", "void", "bool", "i32", "u32", "f32", "f16", "sampler", "sampler_comparison",
                "texture_external", "access_mode", "texel_format", "address_space",
            ]
        )
        #expect(Types.Primitive.Kind.allCases.map(\.rawValue) == Array(0..<14))
        #expect(Types.Texture.Kind.texture1d.rawValue == 1)
        #expect(Types.TextureStorage.Kind.textureStorage1d.rawValue == 1)
        #expect(Types.TextureDepth.Kind.textureDepth2d.rawValue == 1)
    }

    @Test
    func interningIdentity() {
        var types = TypeStore()
        let f32 = types.f32Type
        let i32 = types.i32Type
        let expressions = makeExpressions(2)

        let vec3 = types.vectorType(3, f32)
        #expect(vec3.raw == FixedTypeID.count)
        #expect(types.vectorType(3, f32) == vec3)
        #expect(types.vectorType(4, f32) != vec3)
        #expect(types.vectorType(3, i32) != vec3)
        #expect(types.getIf(Types.Vector.self, vec3)?.element == f32)
        #expect(types.getIf(Types.Vector.self, vec3)?.size == 3)

        let mat2x3 = types.matrixType(2, 3, f32)
        #expect(types.matrixType(2, 3, f32) == mat2x3)
        #expect(types.matrixType(3, 2, f32) != mat2x3)
        let matrix = types.getIf(Types.Matrix.self, mat2x3)
        #expect(matrix?.columns == 2 && matrix?.rows == 3 && matrix?.element == f32)

        let runtime = types.arrayType(f32, .runtime)
        let zero = types.arrayType(f32, .creationFixed(0))
        let four = types.arrayType(f32, .creationFixed(4))
        let override0 = types.arrayType(f32, .overrideSized(expressions[0]))
        let override1 = types.arrayType(f32, .overrideSized(expressions[1]))
        #expect(Set([runtime, zero, four, override0, override1]).count == 5)
        #expect(types.arrayType(f32, .runtime) == runtime)
        #expect(types.arrayType(f32, .creationFixed(4)) == four)
        #expect(types.arrayType(f32, .overrideSized(expressions[1])) == override1)
        #expect(types.arrayType(i32, .creationFixed(4)) != four)
        #expect(types.getIf(Types.Array.self, runtime)?.isRuntimeSized == true)
        #expect(types.getIf(Types.Array.self, four)?.isCreationFixed == true)
        #expect(types.getIf(Types.Array.self, override0)?.isOverrideSized == true)
        #expect(types.getIf(Types.Array.self, override0)?.size == .overrideSized(expressions[0]))

        let texture = types.textureType(.texture2d, f32)
        #expect(types.textureType(.texture2d, f32) == texture)
        #expect(types.textureType(.texture3d, f32) != texture)
        #expect(types.textureType(.texture2d, i32) != texture)

        let storage = types.textureStorageType(.textureStorage2d, .rgba8unorm, .write)
        #expect(types.textureStorageType(.textureStorage2d, .rgba8unorm, .write) == storage)
        #expect(types.textureStorageType(.textureStorage2d, .rgba8unorm, .read) != storage)
        #expect(types.textureStorageType(.textureStorage3d, .rgba8unorm, .write) != storage)
        #expect(types.textureStorageType(.textureStorage2d, .r32float, .write) != storage)

        let reference = types.referenceType(.function, f32, .readWrite)
        #expect(types.referenceType(.function, f32, .readWrite) == reference)
        #expect(types.referenceType(.function, f32, .readWrite, isVectorComponent: false) == reference)
        let component = types.referenceType(.function, f32, .readWrite, isVectorComponent: true)
        #expect(component != reference)
        #expect(types.getIf(Types.Reference.self, component)?.isVectorComponent == true)
        #expect(types.referenceType(.private, f32, .readWrite) != reference)
        #expect(types.referenceType(.function, f32, .read) != reference)

        let pointer = types.pointerType(.storage, f32, .read)
        #expect(types.pointerType(.storage, f32, .read) == pointer)
        #expect(types.pointerType(.storage, f32, .readWrite) != pointer)
        #expect(types.pointerType(.uniform, f32, .read) != pointer)
        #expect(types.pointerType(.storage, i32, .read) != pointer)
        let pointerPayload = types.getIf(Types.Pointer.self, pointer)
        #expect(pointerPayload?.addressSpace == .storage && pointerPayload?.accessMode == .read && pointerPayload?.element == f32)

        // The frexp and modf keys are the fract type alone (TypeStore.cpp:254, :269).
        let frexp = types.frexpResultType(f32, i32)
        #expect(types.frexpResultType(f32, i32) == frexp)
        #expect(types.frexpResultType(f32, types.u32Type) == frexp)
        #expect(types.frexpResultType(vec3, types.vectorType(3, i32)) != frexp)
        let modf = types.modfResultType(f32, f32)
        #expect(modf != frexp)
        #expect(types.modfResultType(f32, f32) == modf)

        let countBefore = types.count
        let cacheCountBefore = types.cacheCount
        _ = types.vectorType(3, f32)
        _ = types.arrayType(f32, .overrideSized(expressions[0]))
        _ = types.frexpResultType(f32, i32)
        #expect(types.count == countBefore)
        #expect(types.cacheCount == cacheCountBefore)
    }

    @Test
    func structFunctionAndConstructorTypesAreNotInterned() {
        var types = TypeStore()
        var symbols = SymbolTable.predeclared
        let structure = makeStructure()
        let x = symbols.intern("x")
        let y = symbols.intern("y")
        var fields = SymbolMap<TypeID>()
        fields.add(x, types.f32Type)
        fields.add(y, types.i32Type)

        let first = types.structType(structure, fields)
        let second = types.structType(structure, fields)
        #expect(first != second)
        guard let payload = types.getIf(Types.Struct.self, first) else {
            Issue.record("not a struct")
            return
        }
        #expect(payload.structure == structure)
        let stored = types.fields(of: payload.fields)
        #expect(stored.count == 2)
        #expect(stored.get(x) == types.f32Type)
        #expect(stored.get(y) == types.i32Type)
        #expect(stored.get(symbols.intern("z")) == nil)
        let empty = types.structType(structure)
        #expect(types.getIf(Types.Struct.self, empty).map { types.fields(of: $0.fields).isEmpty } == true)

        let parameters = [types.f32Type, types.i32Type, types.boolType]
        let function = types.functionType(parameters, types.voidType, mustUse: true, isEntryPoint: false)
        #expect(types.functionType(parameters, types.voidType, mustUse: true, isEntryPoint: false) != function)
        guard let functionPayload = types.getIf(Types.Function.self, function) else {
            Issue.record("not a function")
            return
        }
        #expect(types.count(of: functionPayload.parameters) == 3)
        #expect(types.elements(of: functionPayload.parameters) == parameters)
        #expect(types[functionPayload.parameters, 2] == types.boolType)
        #expect(functionPayload.result == types.voidType)
        #expect(functionPayload.mustUse && !functionPayload.isEntryPoint)
        let noParameters = types.functionType([], types.f32Type, mustUse: false, isEntryPoint: true)
        #expect(types.getIf(Types.Function.self, noParameters).map { types.elements(of: $0.parameters) } == [])

        let vec2 = types.typeConstructorType(.vector(2))
        #expect(types.typeConstructorType(.vector(2)) != vec2)
        #expect(types.getIf(Types.TypeConstructor.self, vec2)?.kind == .vector(2))
    }

    // A struct of 20 fields is past the 8 entries its field map scans: every field is found by its name, and a scope's
    // struct is rolled back with its field map.
    @Test
    func structFieldsPastTheScannedLookupSize() {
        var types = TypeStore()
        var symbols = SymbolTable.predeclared
        var names: [Symbol] = []
        var fieldTypes: [TypeID] = []
        var fields = SymbolMap<TypeID>()
        for index in 0..<20 {
            let name = symbols.intern(ContiguousArray("m\(index)".utf16))
            let fieldType = types.vectorType(UInt8(2 + index % 3), index % 2 == 0 ? types.f32Type : types.i32Type)
            names.append(name)
            fieldTypes.append(fieldType)
            fields.add(name, fieldType)
        }
        let isNewEntry = fields.add(names[3], types.boolType)
        #expect(!isNewEntry)

        let before = types.snapshot()
        let mark = types.openScope()
        let structType = types.structType(makeStructure(), fields)
        guard let payload = types.getIf(Types.Struct.self, structType) else {
            Issue.record("not a struct")
            return
        }
        let stored = types.fields(of: payload.fields)
        #expect(stored.count == 20)
        #expect(stored == fields)
        for index in 0..<20 {
            #expect(stored.find(names[index]) == fieldTypes[index])
            #expect(stored.get(names[index]) == fieldTypes[index])
        }
        #expect(stored.find(symbols.intern("m20")) == nil)
        #expect(!stored.contains(symbols.intern("x")))
        types.rollback(to: mark)
        #expect(types.snapshot() == before)
    }

    // TypeCheck.cpp:312-431.
    @Test
    func typeConstructorNames() {
        var types = TypeStore()
        func name(_ kind: Types.TypeConstructor.Kind) -> String {
            let type = types.typeConstructorType(kind)
            guard let constructor = types.getIf(Types.TypeConstructor.self, type) else {
                return ""
            }
            #expect(constructor.kind == kind)
            return text(constructor.name)
        }
        #expect(name(.pointer) == "ptr")
        #expect(name(.atomic) == "atomic")
        #expect([2, 3, 4].map { name(.vector($0)) } == ["vec2", "vec3", "vec4"])
        var matrices: [String] = []
        for columns: UInt8 in 2...4 {
            for rows: UInt8 in 2...4 {
                matrices.append(name(.matrix(columns: columns, rows: rows)))
            }
        }
        #expect(matrices == ["mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4"])
        #expect(
            Types.Texture.Kind.allCases.map { name(.texture($0)) } == [
                "texture_1d", "texture_2d", "texture_2d_array", "texture_3d", "texture_cube", "texture_cube_array",
                "texture_multisampled_2d",
            ]
        )
        #expect(
            Types.TextureStorage.Kind.allCases.map { name(.textureStorage($0)) } == [
                "texture_storage_1d", "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",
            ]
        )
        #expect(
            Types.TextureDepth.Kind.allCases.map { text($0.name) } == [
                "texture_depth_2d", "texture_depth_2d_array", "texture_depth_cube", "texture_depth_cube_array",
                "texture_depth_multisampled_2d",
            ]
        )
    }

    // TypeStore.cpp:229-235: C++ asserts type == u32 only in debug builds.
    @Test
    func atomicTypeRule() {
        var types = TypeStore()
        let countBefore = types.count
        #expect(types.atomicType(types.i32Type) == FixedTypeID.atomicI32)
        #expect(types.atomicType(types.u32Type) == FixedTypeID.atomicU32)
        #expect(types.count == countBefore)
        if !assertionsAreEnabled() {
            #expect(types.atomicType(types.f32Type) == FixedTypeID.atomicU32)
        }

        let i32Result = types.atomicCompareExchangeResultType(types.i32Type)
        let u32Result = types.atomicCompareExchangeResultType(types.u32Type)
        #expect(i32Result != u32Result)
        #expect(types.atomicCompareExchangeResultType(types.i32Type) == i32Result)
        #expect(types.atomicCompareExchangeResultType(types.u32Type) == u32Result)
        let oldValue = Types.PrimitiveStruct.AtomicCompareExchangeResult.oldValue
        let exchanged = Types.PrimitiveStruct.AtomicCompareExchangeResult.exchanged
        for (result, element) in [(i32Result, types.i32Type), (u32Result, types.u32Type)] {
            guard let payload = types.getIf(Types.PrimitiveStruct.self, result) else {
                Issue.record("not a primitive struct")
                continue
            }
            #expect(payload.kind == .atomicCompareExchangeResult)
            #expect(types[payload.values, oldValue] == element)
            #expect(types[payload.values, exchanged] == types.boolType)
        }
        if !assertionsAreEnabled() {
            #expect(types.atomicCompareExchangeResultType(types.f32Type) == u32Result)
        }
    }

    @Test
    func primitiveStructNames() {
        var types = TypeStore()
        let f32 = types.f32Type
        let i32 = types.i32Type
        let results = [
            types.frexpResultType(f32, i32), types.modfResultType(f32, f32), types.atomicCompareExchangeResultType(i32),
        ]
        let payloads = results.compactMap { types.getIf(Types.PrimitiveStruct.self, $0) }
        #expect(payloads.map(\.kind) == [.frexpResult, .modfResult, .atomicCompareExchangeResult])
        #expect(payloads.map { spelling($0.name) } == ["__frexp_result", "__modf_result", "__atomic_compare_exchange_result"])
        #expect(payloads.allSatisfy { types.count(of: $0.values) == 2 })

        let frexp = payloads[0]
        #expect(types[frexp.values, Types.PrimitiveStruct.FrexpResult.fract] == f32)
        #expect(types[frexp.values, Types.PrimitiveStruct.FrexpResult.exp] == i32)
        let modf = payloads[1]
        #expect(types[modf.values, Types.PrimitiveStruct.ModfResult.fract] == f32)
        #expect(types[modf.values, Types.PrimitiveStruct.ModfResult.whole] == f32)
        #expect(Types.PrimitiveStruct.FrexpResult.kind == .frexpResult)
        #expect(Types.PrimitiveStruct.ModfResult.kind == .modfResult)
        #expect(Types.PrimitiveStruct.AtomicCompareExchangeResult.kind == .atomicCompareExchangeResult)
    }

    // Types.h:164-216.
    @Test
    func primitiveStructFieldOrders() {
        var symbols = SymbolTable.predeclared
        let expected: [Types.PrimitiveStruct.Kind: [(String, Int)]] = [
            .frexpResult: [("exp", 1), ("fract", 0)],
            .modfResult: [("fract", 0), ("whole", 1)],
            .atomicCompareExchangeResult: [("exchanged", 1), ("old_value", 0)],
        ]
        let allNames = ["fract", "exp", "whole", "old_value", "exchanged"]
        for kind in Types.PrimitiveStruct.Kind.allCases {
            let keys = Types.PrimitiveStruct.keys(kind)
            let entries = keys.entries.map { (text($0.name), $0.index) }
            #expect(entries.map(\.0) == expected[kind]?.map(\.0))
            #expect(entries.map(\.1) == expected[kind]?.map(\.1))
            #expect(entries.map(\.0) == entries.map(\.0).sorted())

            for name in allNames {
                let symbol = symbols.intern(ContiguousArray(name.utf16))
                #expect(symbols.provenance(of: symbol) == .builtin, "\(name)")
                #expect(keys.tryGet(symbol) == entries.first { $0.0 == name }?.1, "\(kind) \(name)")
            }
            #expect(keys.tryGet(symbols.intern("x")) == nil)

            // A ConstantStruct of the kind is a HashMap<String, ConstantValue> made from a two-entry initializer list:
            // for either insertion order, the WTF hash table iterates the fields in `values` order.
            for insertionOrder in [entries, entries.reversed()] {
                var table = WTFHashTable<WTFStringHash, Int>()
                table.reserveInitialCapacity(insertionOrder.count)
                for (name, index) in insertionOrder {
                    table.add(Array(name.utf16), index)
                }
                #expect(table.map(\.value) == [0, 1], "\(kind)")
                #expect(table.wtfCopy().map(\.value) == [0, 1], "\(kind)")
            }
        }
    }

    @Test
    func getIfFindsExactlyTheAlternative() {
        var types = TypeStore()
        var symbols = SymbolTable.predeclared
        let f32 = types.f32Type
        var fields = SymbolMap<TypeID>()
        fields.add(symbols.intern("a"), f32)
        let cases: [(TypeID, String)] = [
            (types.boolType, "primitive"),
            (types.vectorType(2, f32), "vector"),
            (types.matrixType(4, 4, f32), "matrix"),
            (types.arrayType(f32, .creationFixed(3)), "array"),
            (types.structType(makeStructure(), fields), "struct"),
            (types.modfResultType(f32, f32), "primitiveStruct"),
            (types.functionType([f32], f32, mustUse: false, isEntryPoint: false), "function"),
            (types.textureType(.textureCube, f32), "texture"),
            (types.textureStorageType(.textureStorage1d, .r32uint, .readWrite), "textureStorage"),
            (types.textureDepthCubeType, "textureDepth"),
            (types.referenceType(.workgroup, f32, .readWrite), "reference"),
            (types.pointerType(.private, f32, .readWrite), "pointer"),
            (types.atomicType(types.i32Type), "atomic"),
            (types.typeConstructorType(.textureStorage(.textureStorage2dArray)), "typeConstructor"),
        ]
        for (type, alternative) in cases {
            #expect(alternatives(types, type) == [alternative])
        }
        #expect(alternatives(types, nil).isEmpty)
    }

    @Test
    func rollbackRemovesCacheKeysAndSideTables() {
        var types = TypeStore()
        var symbols = SymbolTable.predeclared
        let f32 = types.f32Type
        let outerVector = types.vectorType(2, f32)
        let outerFunction = types.functionType([f32, f32], f32, mustUse: false, isEntryPoint: false)
        let before = types.snapshot()
        let countBefore = types.count
        let cacheCountBefore = types.cacheCount

        let mark = types.openScope()
        let vec3 = types.vectorType(3, f32)
        #expect(vec3.raw == UInt32(countBefore))
        #expect(types.vectorType(2, f32) == outerVector)
        var fields = SymbolMap<TypeID>()
        fields.add(symbols.intern("m"), vec3)
        _ = types.structType(makeStructure(), fields)
        _ = types.functionType([vec3, f32, f32], vec3, mustUse: true, isEntryPoint: false)
        _ = types.frexpResultType(vec3, types.vectorType(3, types.i32Type))
        _ = types.atomicCompareExchangeResultType(types.u32Type)
        _ = types.arrayType(vec3, .runtime)
        #expect(types.snapshot() != before)
        types.rollback(to: mark)

        #expect(types.snapshot() == before)
        #expect(types.count == countBefore)
        #expect(types.cacheCount == cacheCountBefore)
        #expect(types.vectorType(2, f32) == outerVector)
        #expect(types.getIf(Types.Function.self, outerFunction).map { types.elements(of: $0.parameters) } == [f32, f32])

        // The scope's keys are gone: the same requests in another order make new types instead of returning stale IDs.
        let matrix = types.matrixType(2, 2, f32)
        #expect(matrix.raw == UInt32(countBefore))
        let vec3Again = types.vectorType(3, f32)
        #expect(vec3Again.raw == UInt32(countBefore + 1))
        #expect(types.getIf(Types.Vector.self, vec3Again)?.size == 3)
        let exchange = types.atomicCompareExchangeResultType(types.u32Type)
        #expect(exchange.raw == UInt32(countBefore + 2))
    }

    @Test
    func nestedScopesRollBackInnermostFirst() {
        var types = TypeStore()
        let f32 = types.f32Type
        let start = types.snapshot()

        let outer = types.openScope()
        let vec2 = types.vectorType(2, f32)
        let afterOuter = types.snapshot()

        let inner = types.openScope()
        _ = types.vectorType(3, f32)
        _ = types.functionType([vec2], vec2, mustUse: false, isEntryPoint: false)
        #expect(types.vectorType(2, f32) == vec2)
        types.rollback(to: inner)
        #expect(types.snapshot() == afterOuter)
        #expect(types.vectorType(2, f32) == vec2)

        types.rollback(to: outer)
        #expect(types.snapshot() == start)
        #expect(types.vectorType(4, f32).raw == FixedTypeID.count)
    }

    // DEV-16: C++ never frees a type; Swift drops a CompilationScope's types, and only the scope's nodes held their IDs.
    @Test
    func DEV_16_scopeTypesAreDroppedAtRollback() {
        var types = TypeStore()
        let mark = types.openScope()
        var index = 0
        while index < 100 {
            _ = types.arrayType(types.f32Type, .creationFixed(UInt32(index + 1)))
            _ = types.structType(makeStructure())
            index += 1
        }
        #expect(types.count == Int(FixedTypeID.count) + 200)
        types.rollback(to: mark)
        #expect(types.count == Int(FixedTypeID.count))
        #expect(types.cacheCount == 0)
        #expect(types.snapshot() == TypeStore().snapshot())
    }

    // The cache is an open-addressing table, so a rollback deletes keys in the middle of probe sequences: every key added
    // before the scope must still be found, and every key added inside it must be gone.
    @Test
    func cacheKeysSurviveRollbackDeletions() {
        var types = TypeStore()
        var kept: [TypeID] = []
        var size: UInt32 = 1
        while size <= 300 {
            kept.append(types.arrayType(types.f32Type, .creationFixed(size)))
            size += 1
        }
        var lost = 0
        var round: UInt32 = 0
        while round < 20 {
            let countBefore = types.count
            let mark = types.openScope()
            var extra: UInt32 = 0
            while extra < 200 {
                _ = types.arrayType(types.i32Type, .creationFixed(round &* 1000 &+ extra &+ 1))
                _ = types.arrayType(types.f32Type, .creationFixed(301 &+ round &* 1000 &+ extra))
                extra += 1
            }
            types.rollback(to: mark)
            #expect(types.count == countBefore)
            var index = 0
            while index < kept.count {
                if types.arrayType(types.f32Type, .creationFixed(UInt32(index + 1))) != kept[index] {
                    lost += 1
                }
                index += 1
            }
            #expect(types.count == countBefore)
            _ = types.arrayType(types.i32Type, .creationFixed(round &* 1000 &+ 1))
            #expect(types.count == countBefore + 1)
            round += 1
        }
        #expect(lost == 0)
    }

    // The source chooses array sizes, so the cache must not let crafted keys form one probe cluster (quadratic type
    // creation): every size here falls in 8 of the 4,096 slots under the cache's former unkeyed mix.
    @Test
    func cacheCraftedCollisionsDoNotCluster() {
        var types = TypeStore()
        var sizes: [UInt32] = []
        var size: UInt32 = 1
        while sizes.count < 2_000 {
            var h = (3 | 1 << 8 | UInt64(size) << 32) ^ (UInt64(types.f32Type.raw) &* 0x9e37_79b9_7f4a_7c15)
            h ^= h >> 32
            h &*= 0xd6e8_feb8_6659_fd93
            h ^= h >> 32
            if h & 0xfff < 8 {
                sizes.append(size)
            }
            size += 1
        }
        var arrays: [TypeID] = []
        for size in sizes {
            arrays.append(types.arrayType(types.f32Type, .creationFixed(size)))
        }
        #expect(types.cacheCount == sizes.count)
        #expect(types.cacheLongestProbeRun < 250)
        for (index, size) in sizes.enumerated() {
            #expect(types.arrayType(types.f32Type, .creationFixed(size)) == arrays[index])
        }
        #expect(types.cacheCount == sizes.count)
    }
}
