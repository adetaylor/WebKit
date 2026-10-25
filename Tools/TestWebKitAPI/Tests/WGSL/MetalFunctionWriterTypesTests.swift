// swift-format-ignore-file: AlwaysUseLowerCamelCase
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

// The C++ writer's output for `typesSource` (a release build, family 4): each local's type and initializer
// in order, the helper's parameter list and the outlined constants.
private let typesSource = """
    enable f16;
    struct S { a: f32, b: vec3<i32>, c: array<u32, 2> }
    struct T { s: S, h: f16 }
    @group(0) @binding(0) var<storage, read_write> out: array<f32>;
    @group(0) @binding(1) var tex: texture_2d<f32>;
    @group(0) @binding(2) var dtex: texture_depth_2d;
    var<private> pv: vec3<f32>;
    var<workgroup> wg: array<atomic<u32>, 4>;
    fn helper(p: vec3<f32>, q: ptr<function, i32>, t: texture_2d<f32>, d: texture_depth_2d, r: ptr<private, vec3<f32>>, w: ptr<workgroup, array<atomic<u32>, 4>>, m: mat3x3<f16>, s: S) -> f32 {
        return p.x + f32(*q) + (*r).x + f32(atomicLoad(&(*w)[0])) + f32(m[0][0]) + s.a + textureLoad(t, vec2(0), 0).x + textureLoad(d, vec2(0), 0);
    }
    @compute @workgroup_size(1)
    fn main() {
        var qq = 3i;
        let c0 = 1.5f;
        let c1 = vec3<f32>(1, 2.5, -0.0);
        let c2 = array<i32, 3>(-2147483647 - 1, 0, 7);
        let c3 = mat2x3<f32>(1, 2, 3, 4, 5, 6);
        let c4 = S(1e20, vec3(1, 2, 3), array(4u, 5u));
        let c5 = frexp(vec2(1.5f, 0.25f));
        let c6 = modf(-2.25f);
        let c7 = vec2<f16>(1.5h, 0.1h);
        let c8 = array(vec2(true, false), vec2(false, true));
        let c9 = T(S(0.1, vec3(0), array(0u, 1u)), 3.0h);
        let c10 = 4294967295u;
        let c11 = array(array(1.0f, 2.0f), array(3.0f, 1e-7f));
        let c12 = frexp(1.5h);
        let c13 = array(frexp(2.0f), frexp(3.0f));
        out[0] = helper(vec3(1.0), &qq, tex, dtex, &pv, &wg, mat3x3<f16>(), c4) + c0 + c1.x + f32(c2[0]) + c3[0][0] + c4.a + c5.fract.x + c6.whole + f32(c7.x) + select(0.0, 1.0, c8[0].x) + c9.s.a + f32(c10) + c11[1][1] + f32(c12.fract) + c13[1].fract;
    }
    """

private let cxxLocals: [(type: String, initializer: String)] = [
    ("int", "3"),
    ("float", "1.5"),
    ("vec<float, 3>", "vec<float, 3>(1., 2.5, 0.)"),
    ("array<int, 3>", "__wgslConst0"),
    ("matrix<float, 2, 3>", "matrix<float, 2, 3>(1., 2., 3., 4., 5., 6.)"),
    ("type0", "type0 { .field0 = 100000002004087730000., .field1 = vec<int, 3>(1, 2, 3), .field2 = array<unsigned, 2>{4u, 5u},  }"),
    (
        "__frexp_result<vec<float, 2>, vec<int, 2>>",
        "__frexp_result<vec<float, 2>, vec<int, 2>> {.fract = vec<float, 2>(0.75, 0.5), .exp = vec<int, 2>(1, -1)}"
    ),
    ("__modf_result<float, float>", "__modf_result<float, float> {.fract = -0.25, .whole = -2.}"),
    ("vec<half, 2>", "vec<half, 2>(1.5h, 0.0999755859375h)"),
    ("array<vec<bool, 2>, 2>", "__wgslConst1"),
    (
        "type1",
        "type1 { .field3 = type0 { .field0 = 0.10000000149011612, .field1 = vec<int, 3>(0, 0, 0), .field2 = array<unsigned, 2>{0u, 1u},  }, .field4 = 3.h,  }"
    ),
    ("unsigned", "4294967295u"),
    ("array<array<float, 2>, 2>", "__wgslConst2"),
    ("__frexp_result<half, int>", "__frexp_result<half, int> {.fract = 0.75h, .exp = 1}"),
    ("array<__frexp_result<float, int>, 2>", "__wgslConst3"),
]

private let cxxHelperParameters =
    "vec<float, 3> parameter0, thread int* parameter1, const constant texture2d<float, access::sample>& parameter2, const constant depth2d<float>& parameter3, thread vec<float, 3>* parameter4, threadgroup array<atomic_uint, 4>* parameter5, matrix<half, 3, 3> parameter6, type0 parameter7"

private let cxxOutlinedConstants = [
    "const constant array<int, 3> __wgslConst0 = array<int, 3>{-2147483648, 0, 7};",
    "const constant array<vec<bool, 2>, 2> __wgslConst1 = array<vec<bool, 2>, 2>{vec<bool, 2>(true, false), vec<bool, 2>(false, true)};",
    "const constant array<array<float, 2>, 2> __wgslConst2 = array<array<float, 2>, 2>{array<float, 2>{1., 2.}, array<float, 2>{3., 1.0000000116860974e-7}};",
    "const constant array<__frexp_result<float, int>, 2> __wgslConst3 = array<__frexp_result<float, int>, 2>{__frexp_result<float, int> {.fract = 0.5, .exp = 2}, __frexp_result<float, int> {.fract = 0.75, .exp = 2}};",
]

private func text(_ bytes: ContiguousArray<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
}

private func symbolText(_ module: borrowing ShaderModule, _ symbol: Symbol) -> String {
    String(decoding: module.symbols.codeUnits(of: symbol), as: UTF16.self)
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

/// Runs `body` on a thread with a `stackSize`-byte stack, the GPU process's WebGPU work queue size.
private func onThread<Value: Sendable>(stackSize: Int, _ body: @escaping @Sendable () -> Value) -> Value? {
    let result = ThreadResult<Value>()
    let thread = Thread {
        result.complete(body())
    }
    thread.stackSize = stackSize
    thread.start()
    return result.wait()
}

private struct CxxComparison: Sendable {
    var locals: [(type: String, initializer: String)] = []
    var helperParameters: [String] = []
    var outlinedConstants = ""
    var failure: String?
}

private func compareWithTheCxxWriter() -> CxxComparison {
    onCompileThread { _ in
        var comparison = CxxComparison()
        var outcome = staticCheckForTesting(SourceText(typesSource), configuration: testsConfiguration, stopAfter: .uniformityAnalysis)
        if let failure = outcome.failure {
            comparison.failure = failure.errors.first?.message ?? "staticCheck failed"
            return comparison
        }
        var mainBody: StatementID?
        var helperParameters: ListID<ParameterID>?
        for declaration in outcome.shaderModule.elements(outcome.shaderModule.declarations) {
            guard case .function(let function) = declaration else {
                continue
            }
            switch symbolText(outcome.shaderModule, outcome.shaderModule[function].originalName) {
            case "main":
                mainBody = outcome.shaderModule[function].body
            case "helper":
                helperParameters = outcome.shaderModule[function].parameters
            default:
                break
            }
        }
        guard let mainBody, let helperParameters, case .compoundStatement(let compound) = outcome.shaderModule[mainBody].kind else {
            comparison.failure = "main or helper not found"
            return comparison
        }
        var constID: UInt32 = 0
        for statement in outcome.shaderModule.elements(compound.statements) {
            guard case .variableStatement(let variableStatement) = outcome.shaderModule[statement].kind,
                let initializer = outcome.shaderModule[variableStatement.variable].maybeInitializer,
                let type = outcome.shaderModule.inferredType(of: initializer)
            else {
                continue
            }
            let typeOutput = writeTypesForTesting([.printValueType(type)], &outcome.shaderModule)
            let output = writeTypesForTesting([.expression(initializer)], constID: constID, &outcome.shaderModule)
            constID = output.constID
            comparison.locals.append((text(typeOutput.body), text(output.body)))
            comparison.outlinedConstants += text(output.constants)
        }
        for parameter in outcome.shaderModule.elements(helperParameters) {
            comparison.helperParameters.append(text(writeTypesForTesting([.parameter(parameter)], &outcome.shaderModule).body))
        }
        return comparison
    }
}

// MARK: - A recursive transcription of MetalFunctionWriter.cpp:1648-1858

private func addressSpaceText(_ addressSpace: AddressSpace) -> String? {
    switch addressSpace {
    case .function, .private: "thread"
    case .workgroup: "threadgroup"
    case .uniform: "constant"
    case .storage: "device"
    case .handle: nil
    }
}

/// C++ `visit(const Type*, bool shouldPack)`; `context` is `shouldPackType()`, `sizes` the text of the override-sized arrays' sizes.
private func recursiveTypeText(
    _ module: borrowing ShaderModule,
    _ type: TypeID,
    _ requestedPacking: Bool,
    _ context: Bool,
    _ sizes: [ExpressionID: String],
    _ out: inout String
) {
    let shouldPack = requestedPacking || context
    switch module.types[type] {
    case .primitive(let primitive):
        switch primitive.kind {
        case .abstractInt, .i32: out += "int"
        case .u32: out += "unsigned"
        case .abstractFloat, .f32: out += "float"
        case .f16: out += "half"
        case .void: out += "void"
        case .bool: out += "bool"
        case .sampler, .samplerComparison: out += "sampler"
        case .textureExternal: out += "texture_external"
        case .accessMode, .texelFormat, .addressSpace: out += "<not a type>"
        }
    case .vector(let vector):
        if shouldPack && vector.size == 3, case .primitive(let primitive) = module.types[vector.element] {
            switch primitive.kind {
            case .abstractInt, .i32: out += "packed_int3"
            case .u32: out += "packed_uint3"
            case .abstractFloat, .f32: out += "packed_float3"
            case .f16: out += "packed_half3"
            case .void, .bool, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
                out += "<not packable>"
            }
            return
        }
        out += "vec<"
        recursiveTypeText(module, vector.element, shouldPack, context, sizes, &out)
        out += ", \(vector.size)>"
    case .matrix(let matrix):
        if shouldPack && matrix.rows == 3 {
            out += "PackedMatrix<"
            recursiveTypeText(module, matrix.element, shouldPack, context, sizes, &out)
            out += ", \(matrix.columns)>"
        } else {
            out += "matrix<"
            recursiveTypeText(module, matrix.element, shouldPack, context, sizes, &out)
            out += ", \(matrix.columns), \(matrix.rows)>"
        }
    case .array(let array):
        out += "array<"
        if case .vector(let vector) = module.types[array.element], vector.size == 3 && shouldPack {
            out += "PackedVec3<"
            recursiveTypeText(module, vector.element, shouldPack, context, sizes, &out)
            out += ">"
        } else {
            recursiveTypeText(module, array.element, shouldPack, context, sizes, &out)
        }
        switch array.size {
        case .creationFixed(let size): out += ", \(size)>"
        case .runtime: out += ", 1>"
        case .overrideSized(let size): out += ", \(sizes[size] ?? "<unknown size>")>"
        }
    case .struct(let structure):
        let name = symbolText(module, module.symbol(of: module[structure.structure].name))
        out += shouldPack && module[structure.structure].role == .userDefinedResource ? "__PackedType<\(name)>" : name
    case .primitiveStruct(let structure):
        switch structure.kind {
        case .frexpResult: out += "__frexp_result<"
        case .modfResult: out += "__modf_result<"
        case .atomicCompareExchangeResult: out += "__atomic_compare_exchange_result<"
        }
        for index in 0..<module.types.count(of: structure.values) {
            out += index > 0 ? ", " : ""
            recursiveTypeText(module, module.types[structure.values, index], shouldPack, context, sizes, &out)
        }
        out += ">"
    case .texture(let texture):
        let names: [Types.Texture.Kind: String] = [
            .texture1d: "texture1d", .texture2d: "texture2d", .texture2dArray: "texture2d_array", .texture3d: "texture3d",
            .textureCube: "texturecube", .textureCubeArray: "texturecube_array", .textureMultisampled2d: "texture2d_ms",
        ]
        out += (names[texture.kind] ?? "") + "<"
        recursiveTypeText(module, texture.element, shouldPack, context, sizes, &out)
        out += texture.kind == .textureMultisampled2d ? ", access::read>" : ", access::sample>"
    case .textureStorage(let texture):
        let names: [Types.TextureStorage.Kind: String] = [
            .textureStorage1d: "texture1d", .textureStorage2d: "texture2d", .textureStorage2dArray: "texture2d_array",
            .textureStorage3d: "texture3d",
        ]
        let modes: [AccessMode: String] = [.read: "read", .write: "write", .readWrite: "read_write"]
        out += (names[texture.kind] ?? "") + "<"
        recursiveTypeText(module, shaderTypeForTexelFormat(texture.format, module.types), false, context, sizes, &out)
        out += ", access::\(modes[texture.access] ?? "")>"
    case .textureDepth(let texture):
        let names: [Types.TextureDepth.Kind: String] = [
            .textureDepth2d: "depth2d", .textureDepth2dArray: "depth2d_array", .textureDepthCube: "depthcube",
            .textureDepthCubeArray: "depthcube_array", .textureDepthMultisampled2d: "depth2d_ms",
        ]
        out += (names[texture.kind] ?? "") + "<float>"
    case .reference(let reference):
        guard let addressSpace = addressSpaceText(reference.addressSpace) else {
            recursiveTypeText(module, reference.element, false, context, sizes, &out)
            return
        }
        out += (reference.accessMode == .read ? "const " : "") + addressSpace + " "
        recursiveTypeText(module, reference.element, false, context, sizes, &out)
        out += "&"
    case .pointer(let pointer):
        out += pointer.accessMode == .read ? "const " : ""
        if let addressSpace = addressSpaceText(pointer.addressSpace) {
            out += addressSpace + " "
        }
        let packs = pointer.addressSpace == .storage || pointer.addressSpace == .uniform
        recursiveTypeText(module, pointer.element, packs, context, sizes, &out)
        out += "*"
    case .atomic(let atomic):
        out += atomic.element == module.types.i32Type ? "atomic_int" : "atomic_uint"
    case .function, .typeConstructor:
        out += "<not printable>"
    }
}

private struct SplitMix64 {
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

/// Random types of at most `depth` levels; a spine tree nests one composite in each level down to its depth.
private struct RandomTypes {
    var random: SplitMix64
    let structures: [TypeID]
    let sizes: [ExpressionID]
    var nodes = 0

    private static let addressSpaces: [AddressSpace] = [.function, .private, .workgroup, .uniform, .storage, .handle]
    private static let accessModes: [AccessMode] = [.read, .write, .readWrite]

    mutating func scalar(_ module: inout ShaderModule, allowBool: Bool) -> TypeID {
        let scalars = [
            module.types.i32Type, module.types.u32Type, module.types.f32Type, module.types.f16Type, module.types.abstractIntType,
            module.types.abstractFloatType,
        ]
        return allowBool && random.below(7) == 0 ? module.types.boolType : scalars[random.below(scalars.count)]
    }

    mutating func leaf(_ module: inout ShaderModule) -> TypeID {
        switch random.below(9) {
        case 0, 1:
            return scalar(&module, allowBool: true)
        case 2:
            let others = [
                module.types.voidType, module.types.samplerType, module.types.samplerComparisonType, module.types.textureExternalType,
                module.types.textureDepth2dType, module.types.textureDepth2dArrayType, module.types.textureDepthCubeType,
                module.types.textureDepthCubeArrayType, module.types.textureDepthMultisampled2dType,
            ]
            return others[random.below(others.count)]
        case 3:
            let kinds = Types.TextureStorage.Kind.allCases
            let formats = TexelFormat.allCases
            return module.types.textureStorageType(
                kinds[random.below(kinds.count)],
                formats[random.below(formats.count)],
                Self.accessModes[random.below(Self.accessModes.count)]
            )
        case 4, 5:
            return structures[random.below(structures.count)]
        case 6:
            return module.types.atomicType(random.below(2) == 0 ? module.types.i32Type : module.types.u32Type)
        case 7:
            let kinds = Types.Texture.Kind.allCases
            let elements = [module.types.f32Type, module.types.i32Type, module.types.u32Type]
            return module.types.textureType(kinds[random.below(kinds.count)], elements[random.below(elements.count)])
        default:
            let size = UInt8(2 + random.below(3))
            return module.types.vectorType(size, scalar(&module, allowBool: size != 3))
        }
    }

    mutating func type(_ module: inout ShaderModule, depth: Int, spine: Bool) -> TypeID {
        nodes += 1
        if depth <= 1 || nodes > 400 || (!spine && random.below(50) == 0) {
            return leaf(&module)
        }
        switch random.below(spine ? 17 : 19) {
        case 0...7:
            let size: Types.Array.Size
            switch random.below(4) {
            case 0: size = .runtime
            case 1: size = .overrideSized(sizes[random.below(sizes.count)])
            default: size = .creationFixed(UInt32(random.below(5000)))
            }
            return module.types.arrayType(type(&module, depth: depth - 1, spine: spine), size)
        case 8, 9:
            let element = type(&module, depth: depth - 1, spine: spine)
            return module.types.pointerType(
                Self.addressSpaces[random.below(Self.addressSpaces.count)],
                element,
                Self.accessModes[random.below(Self.accessModes.count)]
            )
        case 10, 11:
            let element = type(&module, depth: depth - 1, spine: spine)
            return module.types.referenceType(
                Self.addressSpaces[random.below(Self.addressSpaces.count)],
                element,
                Self.accessModes[random.below(Self.accessModes.count)]
            )
        case 12, 13:
            let spineFirst = random.below(2) == 0
            let first = type(&module, depth: spineFirst || !spine ? depth - 1 : min(depth - 1, 3), spine: spine && spineFirst)
            let second = type(&module, depth: !spineFirst || !spine ? depth - 1 : min(depth - 1, 3), spine: spine && !spineFirst)
            return random.below(2) == 0 ? module.types.frexpResultType(first, second) : module.types.modfResultType(first, second)
        case 14:
            return module.types.atomicCompareExchangeResultType(random.below(2) == 0 ? module.types.i32Type : module.types.u32Type)
        case 15, 16:
            let size = UInt8(2 + random.below(3))
            if spine {
                let element =
                    depth > 3
                    ? type(&module, depth: depth - 1, spine: spine) : module.types.vectorType(size, scalar(&module, allowBool: size != 3))
                return module.types.arrayType(element, .creationFixed(UInt32(random.below(9))))
            }
            let elements = [module.types.f32Type, module.types.f16Type, module.types.abstractFloatType]
            return module.types.matrixType(UInt8(2 + random.below(3)), size, elements[random.below(elements.count)])
        default:
            return leaf(&module)
        }
    }
}

private struct RandomTreeComparison: Sendable {
    var printerCalls = 0
    var mismatches: [String] = []
}

private func compareRandomTrees(count: Int, seed: UInt64) -> RandomTreeComparison {
    onCompileThread { _ in
        var comparison = RandomTreeComparison()
        let source = """
            const K = 4u;
            const L = 7i;
            struct S { a: f32 }
            struct R { b: vec3<f32>, c: array<vec3<f32>, 2> }
            struct Q { d: mat3x3<f32>, s: S }
            @group(0) @binding(0) var<storage, read_write> b: array<f32, K>;
            @compute @workgroup_size(1) fn main() { b[0] = f32(L); }
            """
        var outcome = staticCheckForTesting(SourceText(source), configuration: testsConfiguration, stopAfter: .uniformityAnalysis)
        guard outcome.failure == nil else {
            comparison.mismatches.append("staticCheck failed")
            return comparison
        }
        var structures: [TypeID] = []
        var sizes: [ExpressionID] = []
        var sizeTexts: [ExpressionID: String] = [:]
        for declaration in outcome.shaderModule.elements(outcome.shaderModule.declarations) {
            switch declaration {
            case .structure(let structure):
                // R prints as __PackedType<R> where packed; Q is a packed resource structure.
                if structures.count == 1 {
                    outcome.shaderModule[structure].role = .userDefinedResource
                } else if structures.count == 2 {
                    outcome.shaderModule[structure].role = .packedResource
                }
                if let type = outcome.shaderModule[structure].inferredType {
                    structures.append(type)
                }
            case .variable(let variable):
                guard let initializer = outcome.shaderModule[variable].maybeInitializer,
                    let value = outcome.shaderModule.constantValueForWriter(initializer)
                else {
                    continue
                }
                switch value {
                case .uint32(let size):
                    sizeTexts[initializer] = "\(size)u"
                case .int32(let size):
                    sizeTexts[initializer] = "\(size)"
                default:
                    continue
                }
                sizes.append(initializer)
            case .function, .typeAlias, .constAssert:
                continue
            }
        }
        guard structures.count == 3 && sizes.count == 2 else {
            comparison.mismatches.append("unexpected test module")
            return comparison
        }
        var generator = RandomTypes(random: SplitMix64(state: seed), structures: structures, sizes: sizes)
        for tree in 0..<count {
            generator.nodes = 0
            let type = generator.type(&outcome.shaderModule, depth: 1 + generator.random.below(50), spine: tree % 2 == 0)
            for context in 0..<4 {
                let structRole: StructureRole? = context == 0 ? .userDefined : (context == 1 ? .packedResource : nil)
                let variableRole: VariableRole? = context == 2 ? .packedResource : nil
                let parameterRole: ParameterRole? = context == 3 ? .packedResource : nil
                var requests: [(MetalTypesTestRequest, Bool)] = [(.printValueType(type), false)]
                for packing in [Packing.unpacked, .packed, .packedVec3, .packedStruct] {
                    requests.append((.printStorageType(type, packing), packing.contains(.packed)))
                }
                for (request, requestedPacking) in requests {
                    let output = writeTypesForTesting(
                        [request],
                        structRole: structRole,
                        variableRole: variableRole,
                        parameterRole: parameterRole,
                        &outcome.shaderModule
                    )
                    var expected = ""
                    recursiveTypeText(outcome.shaderModule, type, requestedPacking, context != 0, sizeTexts, &expected)
                    comparison.printerCalls += 1
                    if text(output.body) != expected && comparison.mismatches.count < 5 {
                        comparison.mismatches.append("tree \(tree) context \(context): \(text(output.body)) != \(expected)")
                    }
                }
            }
        }
        return comparison
    }
}

// MARK: - Deep types and constants

/// `array<…array<float, 1>…, 1>`, `depth` arrays deep: the C++ spelling (checked against the C++ writer at depths 100 and 10,000).
private func deepArrayTypeText(_ depth: Int) -> String {
    String(repeating: "array<", count: depth) + "float" + String(repeating: ", 1>", count: depth)
}

private func deepArrayType(_ depth: Int, _ module: inout ShaderModule) -> TypeID {
    var type = module.types.f32Type
    for _ in 0..<depth {
        type = module.types.arrayType(type, .creationFixed(1))
    }
    return type
}

@Suite
struct WGSLMetalFunctionWriterTypesTests {
    @Test
    func typesParametersAndConstantsMatchTheCxxWriter() {
        let comparison = compareWithTheCxxWriter()
        #expect(comparison.failure == nil)
        #expect(comparison.locals.count == cxxLocals.count)
        for (index, local) in zip(comparison.locals, cxxLocals).enumerated() {
            #expect(local.0.type == local.1.type, "type of local\(index)")
            #expect(local.0.initializer == local.1.initializer, "initializer of local\(index)")
        }
        #expect(comparison.helperParameters.joined(separator: ", ") == cxxHelperParameters)
        #expect(comparison.outlinedConstants == cxxOutlinedConstants.map { $0 + "\n" }.joined())
    }

    @Test
    func randomTypeTreesPrintAsARecursiveTranscription() {
        let comparison = compareRandomTrees(count: 600, seed: 0xF804)
        #expect(comparison.printerCalls == 600 * 4 * 5)
        #expect(comparison.mismatches.isEmpty, "\(comparison.mismatches)")
    }

    @Test
    func DEV_03_aTenThousandDeepAliasOfArrayChainPrintsOnA512KiBStack() {
        let printed = onThread(stackSize: 512 * 1024) { () -> String in
            var module = ShaderModule(source: SourceText(""), configuration: testsConfiguration)
            let type = deepArrayType(10_000, &module)
            return text(writeTypesForTesting([.printValueType(type)], &module).body)
        }
        #expect(printed == deepArrayTypeText(10_000))
    }

    @Test
    func DEV_03_aDeepConstantSerializesOnA512KiBStack() {
        let depth = 1000
        let serialized = onThread(stackSize: 512 * 1024) { () -> String in
            var module = ShaderModule(source: SourceText(""), configuration: testsConfiguration)
            var type = module.types.f32Type
            var value = ConstantValue.float(0)
            for _ in 0..<depth {
                type = module.types.arrayType(type, .creationFixed(1))
                value = .array(ConstantArray([value]))
            }
            return text(writeTypesForTesting([.serializeConstant(type, value)], &module).body)
        }
        var expected = ""
        for level in stride(from: depth, to: 0, by: -1) {
            expected += deepArrayTypeText(level) + "{"
        }
        expected += "0." + String(repeating: "}", count: depth)
        #expect(serialized == expected)
    }
}
