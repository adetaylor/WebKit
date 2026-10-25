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

/// C++ `WGSL::Packing`.
@_spi(Testing)
public struct Packing: OptionSet, BitwiseCopyable, Hashable, Sendable {
    @_spi(Testing)
    public let rawValue: UInt8

    @_spi(Testing)
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    @_spi(Testing)
    public static let packed = Packing(rawValue: 1 << 0)
    @_spi(Testing)
    public static let unpacked = Packing(rawValue: 1 << 1)
    @_spi(Testing)
    public static let either: Packing = [.packed, .unpacked]

    @_spi(Testing)
    public static let pStruct = Packing(rawValue: 1 << 2)
    @_spi(Testing)
    public static let pArray = Packing(rawValue: 1 << 3)
    @_spi(Testing)
    public static let vec3 = Packing(rawValue: 1 << 4)

    @_spi(Testing)
    public static let packedStruct: Packing = [.packed, .pStruct]
    @_spi(Testing)
    public static let packedArray: Packing = [.packed, .pArray]
    @_spi(Testing)
    public static let packedVec3: Packing = [.packed, .vec3]
}

/// C++ `namespace WGSL::Types`: the payloads of `Type`.
///
/// A payload refers to other types by `TypeID` and to the AST by node ID, never by reference, and keeps its
/// variable-length parts (function parameters, primitive-struct values, struct fields) in `TypeStore` side tables, so
/// every payload is `BitwiseCopyable`.
@_spi(Testing)
public enum Types {
    @_spi(Testing)
    public struct Primitive: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public enum Kind: UInt8, BitwiseCopyable, CaseIterable, Sendable {
            case abstractInt
            case i32
            case u32
            case abstractFloat
            case f16
            case f32
            case void
            case bool
            case sampler
            case samplerComparison
            case textureExternal
            case accessMode
            case texelFormat
            case addressSpace

            /// The name of `FOR_EACH_PRIMITIVE_TYPE`.
            @_spi(Testing)
            public var name: StaticString {
                switch self {
                case .abstractInt: "<AbstractInt>"
                case .i32: "i32"
                case .u32: "u32"
                case .abstractFloat: "<AbstractFloat>"
                case .f16: "f16"
                case .f32: "f32"
                case .void: "void"
                case .bool: "bool"
                case .sampler: "sampler"
                case .samplerComparison: "sampler_comparison"
                case .textureExternal: "texture_external"
                case .accessMode: "access_mode"
                case .texelFormat: "texel_format"
                case .addressSpace: "address_space"
                }
            }
        }

        @_spi(Testing)
        public let kind: Kind
    }

    @_spi(Testing)
    public struct Texture: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public enum Kind: UInt8, BitwiseCopyable, CaseIterable, Sendable {
            case texture1d = 1
            case texture2d
            case texture2dArray
            case texture3d
            case textureCube
            case textureCubeArray
            case textureMultisampled2d

            /// The spelling `Type::dump` prints and TypeCheck introduces.
            @_spi(Testing)
            public var name: StaticString {
                switch self {
                case .texture1d: "texture_1d"
                case .texture2d: "texture_2d"
                case .texture2dArray: "texture_2d_array"
                case .texture3d: "texture_3d"
                case .textureCube: "texture_cube"
                case .textureCubeArray: "texture_cube_array"
                case .textureMultisampled2d: "texture_multisampled_2d"
                }
            }
        }

        @_spi(Testing)
        public let element: TypeID
        @_spi(Testing)
        public let kind: Kind
    }

    @_spi(Testing)
    public struct TextureStorage: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public enum Kind: UInt8, BitwiseCopyable, CaseIterable, Sendable {
            case textureStorage1d = 1
            case textureStorage2d
            case textureStorage2dArray
            case textureStorage3d

            /// The spelling `Type::dump` prints and TypeCheck introduces.
            @_spi(Testing)
            public var name: StaticString {
                switch self {
                case .textureStorage1d: "texture_storage_1d"
                case .textureStorage2d: "texture_storage_2d"
                case .textureStorage2dArray: "texture_storage_2d_array"
                case .textureStorage3d: "texture_storage_3d"
                }
            }
        }

        @_spi(Testing)
        public let kind: Kind
        @_spi(Testing)
        public let format: TexelFormat
        @_spi(Testing)
        public let access: AccessMode
    }

    @_spi(Testing)
    public struct TextureDepth: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public enum Kind: UInt8, BitwiseCopyable, CaseIterable, Sendable {
            case textureDepth2d = 1
            case textureDepth2dArray
            case textureDepthCube
            case textureDepthCubeArray
            case textureDepthMultisampled2d

            /// The spelling `Type::dump` prints and TypeCheck introduces.
            @_spi(Testing)
            public var name: StaticString {
                switch self {
                case .textureDepth2d: "texture_depth_2d"
                case .textureDepth2dArray: "texture_depth_2d_array"
                case .textureDepthCube: "texture_depth_cube"
                case .textureDepthCubeArray: "texture_depth_cube_array"
                case .textureDepthMultisampled2d: "texture_depth_multisampled_2d"
                }
            }
        }

        @_spi(Testing)
        public let kind: Kind
    }

    @_spi(Testing)
    public struct Vector: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let element: TypeID
        @_spi(Testing)
        public let size: UInt8
    }

    @_spi(Testing)
    public struct Matrix: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let element: TypeID
        @_spi(Testing)
        public let columns: UInt8
        @_spi(Testing)
        public let rows: UInt8
    }

    @_spi(Testing)
    public struct Array: BitwiseCopyable, Equatable, Sendable {
        // std::monostate represents a runtime-sized array
        // unsigned represents a creation fixed array (constant size)
        // AST::Expression* represents a fixed array (override size)
        @_spi(Testing)
        public enum Size: BitwiseCopyable, Hashable, Sendable {
            case runtime
            case creationFixed(UInt32)
            case overrideSized(ExpressionID)
        }

        @_spi(Testing)
        public let element: TypeID
        @_spi(Testing)
        public let size: Size

        @_spi(Testing)
        public var isRuntimeSized: Bool {
            if case .runtime = size { true } else { false }
        }

        @_spi(Testing)
        public var isCreationFixed: Bool {
            if case .creationFixed = size { true } else { false }
        }

        @_spi(Testing)
        public var isOverrideSized: Bool {
            if case .overrideSized = size { true } else { false }
        }
    }

    @_spi(Testing)
    public struct Struct: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let structure: StructureID
        /// C++ `HashMap<String, const Type*> fields`, keyed by the original member names: `TypeStore.fields(of:)`.
        @_spi(Testing)
        public let fields: StructFieldsID
    }

    @_spi(Testing)
    public struct PrimitiveStruct: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public enum Kind: UInt8, BitwiseCopyable, CaseIterable, Sendable {
            case frexpResult
            case modfResult
            case atomicCompareExchangeResult
        }

        @_spi(Testing)
        public enum FrexpResult {
            @_spi(Testing)
            public static let kind = Kind.frexpResult
            @_spi(Testing)
            public static let fract = 0
            @_spi(Testing)
            public static let exp = 1
        }

        @_spi(Testing)
        public enum ModfResult {
            @_spi(Testing)
            public static let kind = Kind.modfResult
            @_spi(Testing)
            public static let fract = 0
            @_spi(Testing)
            public static let whole = 1
        }

        @_spi(Testing)
        public enum AtomicCompareExchangeResult {
            @_spi(Testing)
            public static let kind = Kind.atomicCompareExchangeResult
            @_spi(Testing)
            public static let oldValue = 0
            @_spi(Testing)
            public static let exchanged = 1
        }

        /// C++ `PrimitiveStruct::keys[kind]`: a kind's `SortedArrayMap` from field name to index in `values`.
        @_spi(Testing)
        public struct Keys: BitwiseCopyable, Sendable {
            @_spi(Testing)
            public let kind: Kind

            /// The map's entries, in its (name) order.
            @_spi(Testing)
            public var entries: [(name: StaticString, index: Int)] {
                switch kind {
                case .frexpResult: [("exp", FrexpResult.exp), ("fract", FrexpResult.fract)]
                case .modfResult: [("fract", ModfResult.fract), ("whole", ModfResult.whole)]
                case .atomicCompareExchangeResult:
                    [("exchanged", AtomicCompareExchangeResult.exchanged), ("old_value", AtomicCompareExchangeResult.oldValue)]
                }
            }

            @_spi(Testing)
            public func tryGet(_ name: Symbol) -> Int? {
                switch kind {
                case .frexpResult:
                    if name == BuiltinSymbols.exp {
                        return FrexpResult.exp
                    }
                    if name == BuiltinSymbols.fract {
                        return FrexpResult.fract
                    }
                case .modfResult:
                    if name == BuiltinSymbols.fract {
                        return ModfResult.fract
                    }
                    if name == BuiltinSymbols.whole {
                        return ModfResult.whole
                    }
                case .atomicCompareExchangeResult:
                    if name == BuiltinSymbols.exchanged {
                        return AtomicCompareExchangeResult.exchanged
                    }
                    if name == BuiltinSymbols.oldValue {
                        return AtomicCompareExchangeResult.oldValue
                    }
                }
                return nil
            }
        }

        @_spi(Testing)
        public static func keys(_ kind: Kind) -> Keys {
            Keys(kind: kind)
        }

        @_spi(Testing)
        public let kind: Kind
        /// Two types, indexed by the kind's field constants.
        @_spi(Testing)
        public let values: TypeListID

        /// C++ `name`, the string TypeStore passes for the kind (TypeStore.cpp:262, :277, :290).
        @_spi(Testing)
        public var name: ReservedName {
            switch kind {
            case .frexpResult: .fixed(.frexpResult)
            case .modfResult: .fixed(.modfResult)
            case .atomicCompareExchangeResult: .fixed(.atomicCompareExchangeResult)
            }
        }
    }

    @_spi(Testing)
    public struct Function: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let parameters: TypeListID
        @_spi(Testing)
        public let result: TypeID
        @_spi(Testing)
        public let mustUse: Bool
        // An entry point may not be the target of a function call.
        @_spi(Testing)
        public let isEntryPoint: Bool
    }

    @_spi(Testing)
    public struct Reference: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let addressSpace: AddressSpace
        @_spi(Testing)
        public let accessMode: AccessMode
        @_spi(Testing)
        public let element: TypeID
        @_spi(Testing)
        public let isVectorComponent: Bool
    }

    @_spi(Testing)
    public struct Pointer: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let addressSpace: AddressSpace
        @_spi(Testing)
        public let accessMode: AccessMode
        @_spi(Testing)
        public let element: TypeID
    }

    @_spi(Testing)
    public struct Atomic: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public let element: TypeID
    }

    /// C++ stores a `std::function` capturing the TypeChecker; Swift stores which constructor TypeCheck.cpp:312-431
    /// introduced, and TypeCheck switches on it.
    @_spi(Testing)
    public struct TypeConstructor: BitwiseCopyable, Equatable, Sendable {
        @_spi(Testing)
        public enum Kind: BitwiseCopyable, Equatable, Sendable {
            case pointer
            case atomic
            case vector(UInt8)
            case matrix(columns: UInt8, rows: UInt8)
            case texture(Texture.Kind)
            case textureStorage(TextureStorage.Kind)
        }

        @_spi(Testing)
        public let kind: Kind

        /// C++ `name`, the string TypeCheck passes for the kind.
        @_spi(Testing)
        public var name: StaticString {
            switch kind {
            case .pointer: "ptr"
            case .atomic: "atomic"
            case .vector(let size): TypeConstructor.vectorNames[Int(size) - 2]
            case .matrix(let columns, let rows): TypeConstructor.matrixNames[Int(columns) - 2][Int(rows) - 2]
            case .texture(let kind): kind.name
            case .textureStorage(let kind): kind.name
            }
        }

        var hasValidSize: Bool {
            switch kind {
            case .vector(let size): (2...4).contains(size)
            case .matrix(let columns, let rows): (2...4).contains(columns) && (2...4).contains(rows)
            case .pointer, .atomic, .texture, .textureStorage: true
            }
        }

        private static let vectorNames: [StaticString] = ["vec2", "vec3", "vec4"]
        private static let matrixNames: [[StaticString]] = [
            ["mat2x2", "mat2x3", "mat2x4"],
            ["mat3x2", "mat3x3", "mat3x4"],
            ["mat4x2", "mat4x3", "mat4x4"],
        ]
    }
}

/// C++ `struct Type : Variant<...>`, same alternative order.
///
/// `BitwiseCopyable`: reading a type involves no reference counting. Type identity is `TypeID` equality (C++ pointer
/// equality); `==` here compares payloads.
@_spi(Testing)
public enum Type: BitwiseCopyable, Equatable, Sendable {
    case primitive(Types.Primitive)
    case vector(Types.Vector)
    case matrix(Types.Matrix)
    case array(Types.Array)
    case `struct`(Types.Struct)
    case primitiveStruct(Types.PrimitiveStruct)
    case function(Types.Function)
    case texture(Types.Texture)
    case textureStorage(Types.TextureStorage)
    case textureDepth(Types.TextureDepth)
    case reference(Types.Reference)
    case pointer(Types.Pointer)
    case atomic(Types.Atomic)
    case typeConstructor(Types.TypeConstructor)
}

// MARK: - std::get_if

extension TypeStore {
    @_spi(Testing)
    public func getIf(_: Types.Primitive.Type, _ type: TypeID?) -> Types.Primitive? {
        guard let type, case .primitive(let primitive) = self[type] else {
            return nil
        }
        return primitive
    }

    @_spi(Testing)
    public func getIf(_: Types.Vector.Type, _ type: TypeID?) -> Types.Vector? {
        guard let type, case .vector(let vector) = self[type] else {
            return nil
        }
        return vector
    }

    @_spi(Testing)
    public func getIf(_: Types.Matrix.Type, _ type: TypeID?) -> Types.Matrix? {
        guard let type, case .matrix(let matrix) = self[type] else {
            return nil
        }
        return matrix
    }

    @_spi(Testing)
    public func getIf(_: Types.Array.Type, _ type: TypeID?) -> Types.Array? {
        guard let type, case .array(let array) = self[type] else {
            return nil
        }
        return array
    }

    @_spi(Testing)
    public func getIf(_: Types.Struct.Type, _ type: TypeID?) -> Types.Struct? {
        guard let type, case .struct(let structure) = self[type] else {
            return nil
        }
        return structure
    }

    @_spi(Testing)
    public func getIf(_: Types.PrimitiveStruct.Type, _ type: TypeID?) -> Types.PrimitiveStruct? {
        guard let type, case .primitiveStruct(let primitiveStruct) = self[type] else {
            return nil
        }
        return primitiveStruct
    }

    @_spi(Testing)
    public func getIf(_: Types.Function.Type, _ type: TypeID?) -> Types.Function? {
        guard let type, case .function(let function) = self[type] else {
            return nil
        }
        return function
    }

    @_spi(Testing)
    public func getIf(_: Types.Texture.Type, _ type: TypeID?) -> Types.Texture? {
        guard let type, case .texture(let texture) = self[type] else {
            return nil
        }
        return texture
    }

    @_spi(Testing)
    public func getIf(_: Types.TextureStorage.Type, _ type: TypeID?) -> Types.TextureStorage? {
        guard let type, case .textureStorage(let textureStorage) = self[type] else {
            return nil
        }
        return textureStorage
    }

    @_spi(Testing)
    public func getIf(_: Types.TextureDepth.Type, _ type: TypeID?) -> Types.TextureDepth? {
        guard let type, case .textureDepth(let textureDepth) = self[type] else {
            return nil
        }
        return textureDepth
    }

    @_spi(Testing)
    public func getIf(_: Types.Reference.Type, _ type: TypeID?) -> Types.Reference? {
        guard let type, case .reference(let reference) = self[type] else {
            return nil
        }
        return reference
    }

    @_spi(Testing)
    public func getIf(_: Types.Pointer.Type, _ type: TypeID?) -> Types.Pointer? {
        guard let type, case .pointer(let pointer) = self[type] else {
            return nil
        }
        return pointer
    }

    @_spi(Testing)
    public func getIf(_: Types.Atomic.Type, _ type: TypeID?) -> Types.Atomic? {
        guard let type, case .atomic(let atomic) = self[type] else {
            return nil
        }
        return atomic
    }

    @_spi(Testing)
    public func getIf(_: Types.TypeConstructor.Type, _ type: TypeID?) -> Types.TypeConstructor? {
        guard let type, case .typeConstructor(let typeConstructor) = self[type] else {
            return nil
        }
        return typeConstructor
    }
}

// MARK: - Type queries (Types.cpp)

extension ShaderModule {
    /// C++ `Types::Array::stride()`.
    @_spi(Testing)
    public func stride(of array: Types.Array) -> ByteSize {
        let elementAlignment = alignment(of: array.element)
        return ByteSize.arrayStride(element: size(of: array.element), elementAlignment: ByteAlignment(elementAlignment))
    }

    /// `stride(of:)` for pass code (see `maybeSize(of:in:)`).
    static func stride(of array: Types.Array, in shaderModule: inout ShaderModule) -> ByteSize {
        let elementAlignment = alignment(of: array.element, in: &shaderModule)
        return ByteSize.arrayStride(element: size(of: array.element, in: &shaderModule), elementAlignment: ByteAlignment(elementAlignment))
    }

    /// C++ `Type::dump(PrintStream&)`.
    @_spi(Testing)
    public func dump(_ type: TypeID, into out: inout StringPrintStream) {
        writeType(type, into: &out)
    }

    /// `dump(_:into:)` for pass code, which passes its module by address: a non-mutating call that is not inlined copies the
    /// whole module at -O.
    static func dump(_ type: TypeID, in shaderModule: inout ShaderModule, into out: inout StringPrintStream) {
        shaderModule.writeType(type, into: &out)
    }

    @inline(__always)
    private func writeType(_ type: TypeID, into out: inout StringPrintStream) {
        // DEV-03: an explicit stack of what is left to print, where Types.cpp recurses into the element types.
        var pending: [TypeDumpStep] = [.type(type)]
        while let step = pending.popLast() {
            switch step {
            case .text(let text):
                out.print(text)
            case .arraySize(let arraySize):
                switch arraySize {
                case .creationFixed(let size):
                    out.print(", ")
                    out.print(size)
                case .runtime:
                    break
                case .overrideSized(let size):
                    out.print(", ")
                    dumpNode(size, into: &out)
                }
                out.print(">")
            case .type(let current):
                switch types[current] {
                case .primitive(let primitive):
                    out.print(primitive.kind.name)
                case .vector(let vector):
                    out.print("vec")
                    out.print(vector.size)
                    out.print("<")
                    pending.append(.text(">"))
                    pending.append(.type(vector.element))
                case .matrix(let matrix):
                    out.print("mat")
                    out.print(matrix.columns)
                    out.print("x")
                    out.print(matrix.rows)
                    out.print("<")
                    pending.append(.text(">"))
                    pending.append(.type(matrix.element))
                case .array(let array):
                    out.print("array<")
                    pending.append(.arraySize(array.size))
                    pending.append(.type(array.element))
                case .struct(let structure):
                    out.print(string: symbols.text(of: self[self[structure.structure].name].symbol))
                case .primitiveStruct(let structure):
                    out.print(primitiveStructName(structure.kind))
                    out.print("<")
                    pending.append(.text(">"))
                    switch structure.kind {
                    case .frexpResult:
                        pending.append(.type(types[structure.values, Types.PrimitiveStruct.FrexpResult.fract]))
                    case .modfResult:
                        pending.append(.type(types[structure.values, Types.PrimitiveStruct.ModfResult.fract]))
                    case .atomicCompareExchangeResult:
                        pending.append(.type(types[structure.values, Types.PrimitiveStruct.AtomicCompareExchangeResult.oldValue]))
                    }
                case .function(let function):
                    out.print("(")
                    pending.append(.type(function.result))
                    pending.append(.text(") -> "))
                    var index = types.count(of: function.parameters)
                    while index > 0 {
                        index -= 1
                        pending.append(.type(types[function.parameters, index]))
                        if index > 0 {
                            pending.append(.text(", "))
                        }
                    }
                case .texture(let texture):
                    out.print(texture.kind.name)
                    out.print("<")
                    pending.append(.text(">"))
                    pending.append(.type(texture.element))
                case .textureStorage(let texture):
                    out.print(texture.kind.name)
                    out.print("<")
                    out.print(toString(texture.format))
                    out.print(", ")
                    out.print(toString(texture.access))
                    out.print(">")
                case .textureDepth(let texture):
                    out.print(texture.kind.name)
                case .reference(let reference):
                    out.print("ref<")
                    out.print(toString(reference.addressSpace))
                    out.print(", ")
                    pending.append(.text(">"))
                    pending.append(.text(toString(reference.accessMode)))
                    pending.append(.text(", "))
                    pending.append(.type(reference.element))
                case .pointer(let reference):
                    out.print("ptr<")
                    out.print(toString(reference.addressSpace))
                    out.print(", ")
                    pending.append(.text(">"))
                    pending.append(.text(toString(reference.accessMode)))
                    pending.append(.text(", "))
                    pending.append(.type(reference.element))
                case .atomic(let atomic):
                    out.print("atomic<")
                    pending.append(.text(">"))
                    pending.append(.type(atomic.element))
                case .typeConstructor(let constructor):
                    out.print(constructor.name)
                }
            }
        }
    }
}

private func primitivePair(_ first: Types.Primitive.Kind, _ second: Types.Primitive.Kind) -> UInt32 {
    UInt32(first.rawValue) << 8 | UInt32(second.rawValue)
}

extension TypeStore {
    // https://www.w3.org/TR/WGSL/#conversion-rank
    @_spi(Testing)
    public func conversionRank(_ from: TypeID, _ to: TypeID) -> UInt32? {
        var from = from
        var to = to
        // DEV-03: a loop, where Types.cpp recurses (every recursive call is a tail call).
        while true {
            if from == to {
                return 0
            }

            if let fromReference = getIf(Types.Reference.self, from) {
                if fromReference.accessMode == .write {
                    return nil
                }
                from = fromReference.element
                continue
            }

            if let toReference = getIf(Types.Reference.self, to) {
                if toReference.accessMode == .write {
                    return nil
                }
                to = toReference.element
                continue
            }

            if let fromPrimitive = getIf(Types.Primitive.self, from) {
                guard let toPrimitive = getIf(Types.Primitive.self, to) else {
                    return nil
                }

                switch primitivePair(fromPrimitive.kind, toPrimitive.kind) {
                case primitivePair(.abstractFloat, .f32):
                    return 1
                case primitivePair(.abstractFloat, .f16):
                    return 2
                case primitivePair(.abstractInt, .i32):
                    return 3
                case primitivePair(.abstractInt, .u32):
                    return 4
                case primitivePair(.abstractInt, .abstractFloat):
                    return 5
                case primitivePair(.abstractInt, .f32):
                    return 6
                case primitivePair(.abstractInt, .f16):
                    return 7
                default: // lint-exempt(L-ENUM-1): a switch over the integer primitivePair, as in C++
                    return nil
                }
            }

            if let fromVector = getIf(Types.Vector.self, from) {
                guard let toVector = getIf(Types.Vector.self, to) else {
                    return nil
                }
                if fromVector.size != toVector.size {
                    return nil
                }
                from = fromVector.element
                to = toVector.element
                continue
            }

            if let fromMatrix = getIf(Types.Matrix.self, from) {
                guard let toMatrix = getIf(Types.Matrix.self, to) else {
                    return nil
                }
                if fromMatrix.columns != toMatrix.columns {
                    return nil
                }
                if fromMatrix.rows != toMatrix.rows {
                    return nil
                }
                from = fromMatrix.element
                to = toMatrix.element
                continue
            }

            if let fromArray = getIf(Types.Array.self, from) {
                guard let toArray = getIf(Types.Array.self, to) else {
                    return nil
                }
                if fromArray.size != toArray.size {
                    return nil
                }
                from = fromArray.element
                to = toArray.element
                continue
            }

            if let fromPrimitiveStruct = getIf(Types.PrimitiveStruct.self, from) {
                guard let toPrimitiveStruct = getIf(Types.PrimitiveStruct.self, to) else {
                    return nil
                }
                let kind = fromPrimitiveStruct.kind
                if kind != toPrimitiveStruct.kind {
                    return nil
                }
                switch kind {
                case .frexpResult:
                    from = self[fromPrimitiveStruct.values, Types.PrimitiveStruct.FrexpResult.fract]
                    to = self[toPrimitiveStruct.values, Types.PrimitiveStruct.FrexpResult.fract]
                    continue
                case .modfResult:
                    from = self[fromPrimitiveStruct.values, Types.PrimitiveStruct.ModfResult.fract]
                    to = self[toPrimitiveStruct.values, Types.PrimitiveStruct.ModfResult.fract]
                    continue
                case .atomicCompareExchangeResult:
                    return nil
                }
            }

            return nil
        }
    }
}

extension ShaderModule {
    /// C++ `Type::toString()`.
    @_spi(Testing)
    public func typeString(_ type: TypeID) -> MessageText {
        var out = StringPrintStream()
        self.dump(type, into: &out)
        return out.toString()
    }

    /// `typeString(_:)` for pass code (see `dump(_:in:into:)`).
    static func typeString(_ type: TypeID, in shaderModule: inout ShaderModule) -> MessageText {
        var out = StringPrintStream()
        Self.dump(type, in: &shaderModule, into: &out)
        return out.toString()
    }

    // https://gpuweb.github.io/gpuweb/wgsl/#alignment-and-size
    @_spi(Testing)
    public func maybeSize(of type: TypeID) -> ByteSize? {
        maybeSizeBody(of: type)
    }

    /// `maybeSize(of:)` for pass code, which passes its module by address: a non-mutating call that is not inlined copies the
    /// whole module at -O.
    static func maybeSize(of type: TypeID, in shaderModule: inout ShaderModule) -> ByteSize? {
        if let layout = commonLayout(of: type, in: &shaderModule) {
            return layout.size
        }
        return shaderModule.maybeSizeBody(of: type)
    }

    @inline(__always)
    private func maybeSizeBody(of type: TypeID) -> ByteSize? {
        // DEV-03: a loop over the element types with an explicit stack of the enclosing types, where Types.cpp recurses.
        var enclosing = SizeStepStack()
        var current = type
        walk: while true {
            var result: SizeAndAlignment
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16:
                    result = SizeAndAlignment(size: ByteSize(bytes: 2), alignment: 2)
                case .f32, .i32, .u32:
                    result = SizeAndAlignment(size: ByteSize(bytes: 4), alignment: 4)
                case .bool:
                    result = SizeAndAlignment(size: ByteSize(bytes: 1), alignment: 1)
                case .void, .abstractInt, .abstractFloat, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat,
                    .addressSpace:
                    result = SizeAndAlignment(size: nil, alignment: nil)
                }
            case .vector(let vector):
                enclosing.append(.vector(vector))
                current = vector.element
                continue walk
            case .matrix(let matrix):
                enclosing.append(.matrix(matrix))
                current = matrix.element
                continue walk
            case .array(let array):
                var size = CheckedUInt32(1)
                if case .creationFixed(let constantSize) = array.size {
                    size = CheckedUInt32(constantSize)
                } else if case .overrideSized(let expression) = array.size {
                    if let maybeConstantValue = constantValueForArrayCount(expression) {
                        size = CheckedUInt32(checking: maybeConstantValue.integerValue())
                    }
                }
                enclosing.append(.array(count: size))
                current = array.element
                continue walk
            case .struct(let structure):
                result = SizeAndAlignment(size: ByteSize(bytes: structureSize(structure)), alignment: self[structure.structure].alignment)
            case .primitiveStruct(let structure):
                enclosing.append(
                    .primitiveStruct(PrimitiveStructLayout(values: structure.values, next: 1, size: ByteSize(bytes: 0), alignment: 0))
                )
                current = types[structure.values, 0]
                continue walk
            case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer:
                result = SizeAndAlignment(size: nil, alignment: nil)
            case .atomic(let atomic):
                enclosing.append(.atomic)
                current = atomic.element
                continue walk
            case .typeConstructor:
                result = SizeAndAlignment(size: nil, alignment: nil)
            }

            while let step = enclosing.popLast() {
                // The enclosing type asked for `element->size()`, which is `*maybeSize()`.
                guard let elementSize = result.size else {
                    wgslFatal("Type::size() of a type without a size", cppSite: "Types.cpp:384")
                }
                switch step {
                case .vector(let vector):
                    result = SizeAndAlignment(
                        size: ByteSize.vectorSize(element: elementSize, count: vector.size),
                        alignment: result.alignment.map { (vector.size == 2 ? 2 : 4) &* $0 }
                    )
                case .matrix(let matrix):
                    let elementAlignment = requireAlignment(result)
                    result = SizeAndAlignment(
                        size: ByteSize.matrixSize(
                            columns: matrix.columns,
                            rows: matrix.rows,
                            element: elementSize,
                            elementAlignment: ByteAlignment(elementAlignment)
                        ),
                        alignment: (matrix.rows == 2 ? 2 : 4) &* elementAlignment
                    )
                case .array(let count):
                    let elementAlignment = requireAlignment(result)
                    result = SizeAndAlignment(
                        size: ByteSize.arraySize(count: count, element: elementSize, elementAlignment: ByteAlignment(elementAlignment)),
                        alignment: elementAlignment
                    )
                case .primitiveStruct(var layout):
                    layout.size = layout.size.addingPrimitiveStructMember(elementSize)
                    if let alignment = layout.alignment, let elementAlignment = result.alignment {
                        layout.alignment = cxxMax(alignment, elementAlignment)
                    } else {
                        layout.alignment = nil
                    }
                    if layout.next < types.count(of: layout.values) {
                        current = types[layout.values, layout.next]
                        layout.next += 1
                        enclosing.append(.primitiveStruct(layout))
                        continue walk
                    }
                    result = SizeAndAlignment(size: layout.size, alignment: layout.alignment)
                case .atomic:
                    result = SizeAndAlignment(size: elementSize, alignment: result.alignment)
                }
            }
            return result.size
        }
    }

    @_spi(Testing)
    public func size(of type: TypeID) -> ByteSize {
        guard let size = maybeSize(of: type) else {
            wgslFatal("Type::size() of a type without a size", cppSite: "Types.cpp:384")
        }
        return size
    }

    /// `size(of:)` for pass code (see `maybeSize(of:in:)`).
    static func size(of type: TypeID, in shaderModule: inout ShaderModule) -> ByteSize {
        guard let size = maybeSize(of: type, in: &shaderModule) else {
            wgslFatal("Type::size() of a type without a size", cppSite: "Types.cpp:384")
        }
        return size
    }

    @_spi(Testing)
    public func alignment(of type: TypeID) -> UInt32 {
        alignmentBody(of: type)
    }

    /// `alignment(of:)` for pass code (see `maybeSize(of:in:)`).
    static func alignment(of type: TypeID, in shaderModule: inout ShaderModule) -> UInt32 {
        if let layout = commonLayout(of: type, in: &shaderModule) {
            return layout.alignment
        }
        return shaderModule.alignmentBody(of: type)
    }

    @inline(__always)
    private func alignmentBody(of type: TypeID) -> UInt32 {
        // DEV-03: a loop over the element types with an explicit stack of the enclosing primitive structs, where Types.cpp
        // recurses. `factor` is the product of the vector and matrix factors since the innermost enclosing primitive struct.
        var enclosing: [PrimitiveStructAlignment] = []
        var factor: UInt32 = 1
        var current = type
        walk: while true {
            var alignment: UInt32
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16:
                    alignment = 2
                case .f32, .i32, .u32:
                    alignment = 4
                case .bool:
                    alignment = 1
                case .void, .abstractInt, .abstractFloat, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat,
                    .addressSpace:
                    wgslFatal("Type::alignment() of a primitive without an alignment", cppSite: "Types.cpp:409")
                }
            case .vector(let vector):
                if vector.size == 2 {
                    factor = factor &* 2
                } else {
                    factor = factor &* 4
                }
                current = vector.element
                continue walk
            case .matrix(let matrix):
                if matrix.rows == 2 {
                    factor = factor &* 2
                } else {
                    factor = factor &* 4
                }
                current = matrix.element
                continue walk
            case .array(let array):
                current = array.element
                continue walk
            case .struct(let structure):
                guard let structureAlignment = self[structure.structure].alignment else {
                    wgslFatal("Structure::alignment() before it was computed", cppSite: "ASTStructure.h:78")
                }
                alignment = structureAlignment
            case .primitiveStruct(let structure):
                enclosing.append(PrimitiveStructAlignment(values: structure.values, next: 1, factor: factor, alignment: 0))
                factor = 1
                current = types[structure.values, 0]
                continue walk
            case .function:
                wgslFatal("Type::alignment() of a function", cppSite: "Types.cpp:437")
            case .texture:
                wgslFatal("Type::alignment() of a texture", cppSite: "Types.cpp:440")
            case .textureStorage:
                wgslFatal("Type::alignment() of a storage texture", cppSite: "Types.cpp:443")
            case .textureDepth:
                wgslFatal("Type::alignment() of a depth texture", cppSite: "Types.cpp:446")
            case .reference:
                wgslFatal("Type::alignment() of a reference", cppSite: "Types.cpp:449")
            case .pointer:
                wgslFatal("Type::alignment() of a pointer", cppSite: "Types.cpp:452")
            case .atomic(let atomic):
                current = atomic.element
                continue walk
            case .typeConstructor:
                wgslFatal("Type::alignment() of a type constructor", cppSite: "Types.cpp:459")
            }

            alignment = alignment &* factor
            while var step = enclosing.popLast() {
                step.alignment = cxxMax(step.alignment, alignment)
                if step.next < types.count(of: step.values) {
                    current = types[step.values, step.next]
                    step.next += 1
                    enclosing.append(step)
                    factor = 1
                    continue walk
                }
                alignment = step.alignment &* step.factor
            }
            return alignment
        }
    }

    @_spi(Testing)
    @inline(__always)
    public func packing(of type: TypeID) -> Packing {
        // DEV-03: a loop, where Types.cpp recurses; every array level on the way adds PArray to a packed element's packing.
        var current = type
        var isArrayElement = false
        var packing = Packing.unpacked
        while true {
            if let referenceType = types.getIf(Types.Reference.self, current) {
                current = referenceType.element
                continue
            }

            if let structType = types.getIf(Types.Struct.self, current) {
                if self[structType.structure].role == .userDefinedResource {
                    packing = .packedStruct
                }
            } else if let vectorType = types.getIf(Types.Vector.self, current) {
                if vectorType.size == 3 {
                    packing = .packedVec3
                }
            } else if let matrixType = types.getIf(Types.Matrix.self, current) {
                if matrixType.rows == 3 {
                    packing = .packedVec3
                }
            } else if let arrayType = types.getIf(Types.Array.self, current) {
                current = arrayType.element
                isArrayElement = true
                continue
            }
            break
        }

        if isArrayElement && packing.contains(.packed) {
            packing.insert(.pArray)
        }
        return packing
    }

    // https://www.w3.org/TR/WGSL/#constructible-types
    @_spi(Testing)
    @inline(__always)
    public func isConstructible(_ type: TypeID) -> Bool {
        // DEV-03: a loop with an explicit stack of the structure members left to check, where Types.cpp recurses.
        var pending = PendingMembers()
        var current = type
        while true {
            let holds: Bool
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16, .f32, .i32, .u32, .bool, .abstractInt, .abstractFloat:
                    holds = true
                case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
                    holds = false
                }
            case .vector:
                holds = true
            case .matrix:
                holds = true
            case .array(let array):
                guard array.isCreationFixed else {
                    return false
                }
                current = array.element
                continue
            case .struct(let structure):
                pending.push(self[structure.structure].members)
                holds = true
            case .primitiveStruct:
                holds = true

            case .function:
                holds = false
            case .texture:
                holds = false
            case .textureStorage:
                holds = false
            case .textureDepth:
                holds = false
            case .reference:
                holds = false
            case .pointer:
                holds = false
            case .atomic:
                holds = false
            case .typeConstructor:
                holds = false
            }
            if !holds {
                return false
            }
            guard let next = pending.next(self) else {
                return true
            }
            current = next
        }
    }

    // https://www.w3.org/TR/WGSL/#storable
    @_spi(Testing)
    @inline(__always)
    public func isStorable(_ type: TypeID) -> Bool {
        // DEV-03: a loop with an explicit stack of the structure members left to check, where Types.cpp recurses.
        var pending = PendingMembers()
        var current = type
        while true {
            let holds: Bool
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16, .f32, .i32, .u32, .bool, .sampler, .samplerComparison, .textureExternal:
                    holds = true
                case .abstractInt, .abstractFloat, .void, .accessMode, .texelFormat, .addressSpace:
                    holds = false
                }
            case .vector(let vector):
                current = vector.element
                continue
            case .matrix(let matrix):
                current = matrix.element
                continue
            case .array(let array):
                current = array.element
                continue
            case .struct(let structure):
                pending.push(self[structure.structure].members)
                holds = true
            case .textureStorage:
                holds = true
            case .textureDepth:
                holds = true
            case .atomic:
                holds = true

            case .primitiveStruct:
                holds = false
            case .function:
                holds = false
            case .texture:
                holds = false
            case .typeConstructor:
                holds = false
            case .reference:
                holds = false
            case .pointer:
                holds = false
            }
            if !holds {
                return false
            }
            guard let next = pending.next(self) else {
                return true
            }
            current = next
        }
    }

    // https://www.w3.org/TR/WGSL/#host-shareable-types
    @_spi(Testing)
    @inline(__always)
    public func isHostShareable(_ type: TypeID) -> Bool {
        // DEV-03: a loop with an explicit stack of the structure members left to check, where Types.cpp recurses.
        var pending = PendingMembers()
        var current = type
        while true {
            let holds: Bool
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16, .f32, .i32, .u32:
                    holds = true
                case .bool, .sampler, .samplerComparison, .textureExternal, .abstractInt, .abstractFloat, .void, .accessMode,
                    .texelFormat, .addressSpace:
                    holds = false
                }
            case .vector(let vector):
                current = vector.element
                continue
            case .matrix(let matrix):
                current = matrix.element
                continue
            case .array(let array):
                current = array.element
                continue
            case .struct(let structure):
                pending.push(self[structure.structure].members)
                holds = true
            case .atomic:
                holds = true

            case .textureStorage:
                holds = false
            case .textureDepth:
                holds = false
            case .primitiveStruct:
                holds = false
            case .function:
                holds = false
            case .texture:
                holds = false
            case .typeConstructor:
                holds = false
            case .reference:
                holds = false
            case .pointer:
                holds = false
            }
            if !holds {
                return false
            }
            guard let next = pending.next(self) else {
                return true
            }
            current = next
        }
    }

    // https://www.w3.org/TR/WGSL/#fixed-footprint
    @_spi(Testing)
    @inline(__always)
    public func hasFixedFootprint(_ type: TypeID) -> Bool {
        // DEV-03: a loop with an explicit stack of the structure members left to check, where Types.cpp recurses.
        var pending = PendingMembers()
        var current = type
        while true {
            let holds: Bool
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16, .f32, .i32, .u32, .bool:
                    holds = true
                case .sampler, .samplerComparison, .textureExternal, .abstractInt, .abstractFloat, .void, .accessMode, .texelFormat,
                    .addressSpace:
                    holds = false
                }
            case .vector:
                holds = true
            case .matrix:
                holds = true
            case .array(let array):
                holds = !array.isRuntimeSized
            case .struct(let structure):
                pending.push(self[structure.structure].members)
                holds = true
            case .atomic:
                holds = true

            case .textureStorage:
                holds = false
            case .textureDepth:
                holds = false
            case .primitiveStruct:
                holds = false
            case .function:
                holds = false
            case .texture:
                holds = false
            case .typeConstructor:
                holds = false
            case .reference:
                holds = false
            case .pointer:
                holds = false
            }
            if !holds {
                return false
            }
            guard let next = pending.next(self) else {
                return true
            }
            current = next
        }
    }

    // https://www.w3.org/TR/WGSL/#creation-fixed-footprint
    @_spi(Testing)
    @inline(__always)
    public func hasCreationFixedFootprint(_ type: TypeID) -> Bool {
        hasCreationFixedFootprint(type, knownStructures: nil)
    }

    /// `hasCreationFixedFootprint(_:)` that takes the structure types in `knownStructures` to have one without visiting their
    /// members (the type checker's memo of the structures it checked: a structure's member types never change, and Types.cpp
    /// visits every nested member again for every enclosing structure).
    @inline(__always)
    func hasCreationFixedFootprint(_ type: TypeID, knownStructures: IDSet<TypeID>?) -> Bool {
        // DEV-03: a loop with an explicit stack of the structure members left to check, where Types.cpp recurses.
        var pending = PendingMembers()
        var current = type
        while true {
            let holds: Bool
            switch types[current] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .f16, .f32, .i32, .u32, .bool:
                    holds = true
                case .sampler, .samplerComparison, .textureExternal, .abstractInt, .abstractFloat, .void, .accessMode, .texelFormat,
                    .addressSpace:
                    holds = false
                }
            case .vector:
                holds = true
            case .matrix:
                holds = true
            case .array(let array):
                holds = array.isCreationFixed
            case .struct(let structure):
                if knownStructures?.contains(current) != true {
                    pending.push(self[structure.structure].members)
                }
                holds = true
            case .atomic:
                holds = true

            case .textureStorage:
                holds = false
            case .textureDepth:
                holds = false
            case .primitiveStruct:
                holds = false
            case .function:
                holds = false
            case .texture:
                holds = false
            case .typeConstructor:
                holds = false
            case .reference:
                holds = false
            case .pointer:
                holds = false
            }
            if !holds {
                return false
            }
            guard let next = pending.next(self) else {
                return true
            }
            current = next
        }
    }

    @_spi(Testing)
    @inline(__always)
    public func containsRuntimeArray(_ type: TypeID) -> Bool {
        // DEV-03: a loop, where Types.cpp recurses.
        var current = type
        while true {
            if let array = types.getIf(Types.Array.self, current) {
                return array.isRuntimeSized
            }
            if let structure = types.getIf(Types.Struct.self, current) {
                current = lastMemberType(structure, cppSite: "Types.cpp:842")
                continue
            }
            if let reference = types.getIf(Types.Reference.self, current) {
                current = reference.element
                continue
            }
            return false
        }
    }

    @_spi(Testing)
    @inline(__always)
    public func containsOverrideArray(_ type: TypeID) -> Bool {
        // DEV-03: a loop, where Types.cpp recurses.
        var current = type
        while true {
            if let array = types.getIf(Types.Array.self, current) {
                return array.isOverrideSized
            }
            if let structure = types.getIf(Types.Struct.self, current) {
                current = lastMemberType(structure, cppSite: "Types.cpp:853")
                continue
            }
            if let reference = types.getIf(Types.Reference.self, current) {
                current = reference.element
                continue
            }
            return false
        }
    }
}

extension TypeStore {
    @_spi(Testing)
    public func isTexture(_ type: TypeID) -> Bool {
        let primitive = getIf(Types.Primitive.self, type)
        if let primitive {
            return primitive.kind == .textureExternal
        }
        return getIf(Types.Texture.self, type) != nil || getIf(Types.TextureStorage.self, type) != nil
            || getIf(Types.TextureDepth.self, type) != nil
    }

    @_spi(Testing)
    public func isSampler(_ type: TypeID) -> Bool {
        guard let primitive = getIf(Types.Primitive.self, type) else {
            return false
        }
        return primitive.kind == .sampler || primitive.kind == .samplerComparison
    }

    /// C++ passes a `const Type*`; a null type is not a primitive.
    @_spi(Testing)
    public func isPrimitive(_ type: TypeID?, _ kind: Types.Primitive.Kind) -> Bool {
        guard let primitive = getIf(Types.Primitive.self, type) else {
            return false
        }
        return primitive.kind == kind
    }

    @_spi(Testing)
    public func isPrimitiveReference(_ type: TypeID?, _ kind: Types.Primitive.Kind) -> Bool {
        guard let reference = getIf(Types.Reference.self, type) else {
            return false
        }
        return isPrimitive(reference.element, kind)
    }
}

@_spi(Testing)
public func shaderTypeForTexelFormat(_ format: TexelFormat, _ types: borrowing TypeStore) -> TypeID {
    switch format {
    case .bgra8unorm, .r8snorm, .r8unorm, .rg8snorm, .rg8unorm, .rgba8unorm, .rgba8snorm, .rg16unorm, .rg16snorm, .rgba16unorm,
        .rgba16snorm, .r16unorm, .r16snorm, .r16float, .rgb10a2unorm, .rgba16float, .r32float, .rg32float, .rgba32float,
        .rg16float, .rg11b10ufloat:
        return types.f32Type
    case .rgba8uint, .rgb10a2uint, .rgba16uint, .r16uint, .r8uint, .rg8uint, .rg16uint, .r32uint, .rg32uint, .rgba32uint:
        return types.u32Type
    case .rgba8sint, .rgba16sint, .r16sint, .r8sint, .rg8sint, .rg16sint, .r32sint, .rg32sint, .rgba32sint:
        return types.i32Type
    }
}

// MARK: - Swift-only

extension ShaderModule {
    /// The queries that need no AST state live on `TypeStore`; these forward to them.
    @_spi(Testing)
    @inline(__always)
    public func conversionRank(_ from: TypeID, _ to: TypeID) -> UInt32? {
        types.conversionRank(from, to)
    }

    @_spi(Testing)
    @inline(__always)
    public func isTexture(_ type: TypeID) -> Bool {
        types.isTexture(type)
    }

    @_spi(Testing)
    @inline(__always)
    public func isSampler(_ type: TypeID) -> Bool {
        types.isSampler(type)
    }

    @_spi(Testing)
    @inline(__always)
    public func isPrimitive(_ type: TypeID?, _ kind: Types.Primitive.Kind) -> Bool {
        types.isPrimitive(type, kind)
    }

    @_spi(Testing)
    @inline(__always)
    public func isPrimitiveReference(_ type: TypeID?, _ kind: Types.Primitive.Kind) -> Bool {
        types.isPrimitiveReference(type, kind)
    }

    /// C++ `member.type().inferredType()`, which the C++ dereferences.
    @inline(__always)
    fileprivate func memberType(_ member: StructureMemberID) -> TypeID {
        guard let type = inferredType(of: self[member].type) else {
            wgslFatal("structure member type without an inferred type", cppSite: "Types.cpp:522")
        }
        return type
    }

    /// C++ `structure.members().last().type().inferredType()`.
    @inline(__always)
    fileprivate func lastMemberType(_ structure: Types.Struct, cppSite: StaticString) -> TypeID {
        let members = self[structure.structure].members
        let memberCount = count(members)
        guard memberCount > 0 else {
            wgslFatal("Vector::last() of an empty member list", cppSite: cppSite)
        }
        return memberType(self[members, memberCount - 1])
    }

    /// C++ `structure.structure.size()`, which is `*m_size`.
    @inline(__always)
    fileprivate func structureSize(_ structure: Types.Struct) -> UInt32 {
        guard let size = self[structure.structure].size else {
            wgslFatal("Structure::size() before it was computed", cppSite: "ASTStructure.h:77")
        }
        return size
    }

    /// The size and alignment of the usual member types, as the walks of `maybeSize(of:)` and `alignment(of:)` compute them.
    ///
    /// A sized scalar, a vector or matrix of one, a structure whose layout is computed, or a fixed-size or runtime-sized
    /// array of those; nil for any other type, which the walks handle. Static over the module's address: the pass code's
    /// queries take this path.
    fileprivate static func commonLayout(of type: TypeID, in shaderModule: inout ShaderModule) -> (size: ByteSize, alignment: UInt32)? {
        if case .array(let array) = shaderModule.types[type] {
            let count: CheckedUInt32
            switch array.size {
            case .runtime:
                count = CheckedUInt32(1)
            case .creationFixed(let constantSize):
                count = CheckedUInt32(constantSize)
            case .overrideSized:
                return nil
            }
            guard let element = elementLayout(of: array.element, in: &shaderModule) else {
                return nil
            }
            return (
                ByteSize.arraySize(count: count, element: element.size, elementAlignment: ByteAlignment(element.alignment)),
                element.alignment
            )
        }
        return elementLayout(of: type, in: &shaderModule)
    }

    @inline(__always)
    private static func elementLayout(of type: TypeID, in shaderModule: inout ShaderModule) -> (size: ByteSize, alignment: UInt32)? {
        switch shaderModule.types[type] {
        case .primitive(let primitive):
            guard let scalar = scalarLayout(primitive) else {
                return nil
            }
            return (ByteSize(bytes: scalar), scalar)
        case .vector(let vector):
            guard case .primitive(let primitive) = shaderModule.types[vector.element], let scalar = scalarLayout(primitive) else {
                return nil
            }
            return (
                ByteSize.vectorSize(element: ByteSize(bytes: scalar), count: vector.size),
                (vector.size == 2 ? 2 : 4) &* scalar
            )
        case .matrix(let matrix):
            guard case .primitive(let primitive) = shaderModule.types[matrix.element], let scalar = scalarLayout(primitive) else {
                return nil
            }
            return (
                ByteSize.matrixSize(
                    columns: matrix.columns,
                    rows: matrix.rows,
                    element: ByteSize(bytes: scalar),
                    elementAlignment: ByteAlignment(scalar)
                ),
                (matrix.rows == 2 ? 2 : 4) &* scalar
            )
        case .struct(let structure):
            let node = shaderModule[structure.structure]
            guard let size = node.size, let alignment = node.alignment else {
                return nil
            }
            return (ByteSize(bytes: size), alignment)
        case .array, .primitiveStruct, .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic,
            .typeConstructor:
            return nil
        }
    }

    // A sized scalar's size, which is its alignment.
    @inline(__always)
    private static func scalarLayout(_ primitive: Types.Primitive) -> UInt32? {
        switch primitive.kind {
        case .f16:
            2
        case .f32, .i32, .u32:
            4
        case .bool:
            1
        case .void, .abstractInt, .abstractFloat, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat,
            .addressSpace:
            nil
        }
    }
}

/// The fixed C++ `name` of a primitive struct (TypeStore.cpp:262, :277, :290).
private func primitiveStructName(_ kind: Types.PrimitiveStruct.Kind) -> StaticString {
    switch kind {
    case .frexpResult: ReservedName.Fixed.frexpResult.spelling
    case .modfResult: ReservedName.Fixed.modfResult.spelling
    case .atomicCompareExchangeResult: ReservedName.Fixed.atomicCompareExchangeResult.spelling
    }
}

/// What `dump(_:into:)` has left to print, last first.
private enum TypeDumpStep {
    case type(TypeID)
    case text(StaticString)
    /// The `, size` of an array, then its `>`.
    case arraySize(Types.Array.Size)
}

/// A type's `maybeSize()` and `alignment()` as `maybeSize(of:)` computes them.
///
/// Each is nil where the C++ returns nullopt (size) or traps (alignment); only an enclosing type that asks for it makes
/// that a trap.
private struct SizeAndAlignment {
    var size: ByteSize?
    var alignment: UInt32?
}

// The enclosing types of a size walk: the first two in place, so the walk over a vector, matrix or array of a scalar or vector
// allocates nothing; deeper ones in an array.
private struct SizeStepStack {
    private var first: SizeStep?
    private var second: SizeStep?
    private var rest: [SizeStep] = []

    mutating func append(_ step: SizeStep) {
        if first == nil {
            first = step
        } else if second == nil {
            second = step
        } else {
            rest.append(step)
        }
    }

    mutating func popLast() -> SizeStep? {
        if let step = rest.popLast() {
            return step
        }
        if let step = second {
            second = nil
            return step
        }
        if let step = first {
            first = nil
            return step
        }
        return nil
    }
}

/// A type whose element sizes `maybeSize(of:)` is computing.
private enum SizeStep {
    case vector(Types.Vector)
    case matrix(Types.Matrix)
    /// The C++ `CheckedUint32 size`, the element count, evaluated before the element (Types.cpp:330-336).
    case array(count: CheckedUInt32)
    case primitiveStruct(PrimitiveStructLayout)
    case atomic
}

/// The sum of the sizes and the maximum of the alignments of the values of a primitive struct visited so far.
private struct PrimitiveStructLayout {
    let values: TypeListID
    var next: Int
    var size: ByteSize
    var alignment: UInt32?
}

/// The maximum of the alignments of the values of a primitive struct visited so far, and the factor the enclosing
/// vectors and matrices apply to it.
private struct PrimitiveStructAlignment {
    let values: TypeListID
    var next: Int
    let factor: UInt32
    var alignment: UInt32
}

/// The C++ `element->alignment()` an enclosing matrix or array asks for, which traps where `maybeSize(of:)` recorded nil.
private func requireAlignment(_ element: SizeAndAlignment) -> UInt32 {
    guard let alignment = element.alignment else {
        wgslFatal("Type::alignment() of a type without an alignment", cppSite: "Types.cpp:409")
    }
    return alignment
}

/// The structure members a type predicate has still to check: the C++ `for (auto& member : members())` loops that its
/// recursion suspends, innermost last.
private struct PendingMembers {
    private var structures: [(members: ListID<StructureMemberID>, next: Int)] = []

    @inline(__always)
    mutating func push(_ members: ListID<StructureMemberID>) {
        structures.append((members, 0))
    }

    /// The type of the next member in the C++ order, read only when the C++ reads it; nil when no member is left.
    @inline(__always)
    mutating func next(_ shaderModule: borrowing ShaderModule) -> TypeID? {
        while let last = structures.last {
            guard last.next < shaderModule.count(last.members) else {
                structures.removeLast()
                continue
            }
            structures[structures.count - 1].next = last.next + 1
            return shaderModule.memberType(shaderModule[last.members, last.next])
        }
        return nil
    }
}

/// WTF `StringPrintStream`, as `Type::dump` uses it.
///
/// Numbers print as `%u`. A string prints as `printInternal(PrintStream&, const String&)` does (PrintStream.cpp:85-148): it
/// is converted to UTF-8 (an unpaired surrogate becomes U+FFFD), printed with `%s` (which stops at a NUL), and, when its
/// UTF-8 is longer than 5,000,000 bytes, truncated to its first 1000 bytes (less a partial character) followed by
/// `...[N characters not shown]`, N counting the bytes left out.
@_spi(Testing)
public struct StringPrintStream {
    private static let stringLengthThresholdToTriggerTruncation = 5_000_000
    private static let stringLengthToTruncateToForPrinting = 1000

    private var text = MessageText(codeUnits: [])

    @_spi(Testing)
    public init() {
        text.codeUnits.reserveCapacity(32)
    }

    @_spi(Testing)
    public mutating func print(_ literal: StaticString) {
        text.codeUnits.append(contentsOf: literal.description.utf16)
    }

    @_spi(Testing)
    public mutating func print(_ value: UInt8) {
        appendDecimal(UInt32(value))
    }

    @_spi(Testing)
    public mutating func print(_ value: UInt32) {
        appendDecimal(value)
    }

    @_spi(Testing)
    public mutating func print(string: MessageText) {
        let utf8Length = Self.utf8Length(string.codeUnits)
        if utf8Length > Self.stringLengthThresholdToTriggerTruncation {
            let lengthNotPrinted = utf8Length - Self.stringLengthToTruncateToForPrinting
            var subString = MessageText(codeUnits: [])
            Self.appendUTF8RoundTrip(string.codeUnits, to: &subString.codeUnits, utf8Limit: Self.stringLengthToTruncateToForPrinting)
            subString.append("...[\(lengthNotPrinted) characters not shown]")
            appendCString(subString.codeUnits)
            return
        }
        var converted: ContiguousArray<UInt16> = []
        Self.appendUTF8RoundTrip(string.codeUnits, to: &converted, utf8Limit: utf8Length)
        appendCString(converted)
    }

    @_spi(Testing)
    public func toString() -> MessageText {
        text
    }

    /// `%u`, into the text directly (no intermediate MessageText).
    private mutating func appendDecimal(_ value: UInt32) {
        var divisor: UInt32 = 1
        while value / divisor >= 10 {
            divisor &*= 10
        }
        var remaining = value
        while divisor > 0 {
            text.codeUnits.append(0x30 &+ UInt16(truncatingIfNeeded: remaining / divisor))
            remaining %= divisor
            divisor /= 10
        }
    }

    private mutating func appendCString(_ codeUnits: ContiguousArray<UInt16>) {
        var index = 0
        while index < codeUnits.count && codeUnits[index] != 0 {
            text.codeUnits.append(codeUnits[index])
            index += 1
        }
    }

    /// The UTF-8 length of `codeUnits` after the lenient conversion.
    private static func utf8Length(_ codeUnits: ContiguousArray<UInt16>) -> Int {
        var length = 0
        var index = 0
        while index < codeUnits.count {
            let (width, utf8Width) = character(codeUnits, at: index)
            length += utf8Width
            index += width
        }
        return length
    }

    /// Appends the code units the UTF-8 of `codeUnits` reads back as, for the whole characters within its first `utf8Limit`
    /// bytes.
    private static func appendUTF8RoundTrip(_ codeUnits: ContiguousArray<UInt16>, to result: inout ContiguousArray<UInt16>, utf8Limit: Int)
    {
        var length = 0
        var index = 0
        while index < codeUnits.count {
            let (width, utf8Width) = character(codeUnits, at: index)
            length += utf8Width
            if length > utf8Limit {
                return
            }
            if width == 2 {
                result.append(codeUnits[index])
                result.append(codeUnits[index + 1])
            } else if isSurrogate(codeUnits[index]) {
                result.append(0xFFFD)
            } else {
                result.append(codeUnits[index])
            }
            index += width
        }
    }

    /// The UTF-16 width of the character at `index` (2 for a surrogate pair) and its UTF-8 width (an unpaired surrogate
    /// converts to the 3 bytes of U+FFFD).
    private static func character(_ codeUnits: ContiguousArray<UInt16>, at index: Int) -> (width: Int, utf8Width: Int) {
        let unit = codeUnits[index]
        if unit < 0x80 {
            return (1, 1)
        }
        if unit < 0x800 {
            return (1, 2)
        }
        if unit >= 0xD800 && unit < 0xDC00 && index + 1 < codeUnits.count && codeUnits[index + 1] >= 0xDC00 && codeUnits[index + 1] < 0xE000
        {
            return (2, 4)
        }
        return (1, 3)
    }

    private static func isSurrogate(_ unit: UInt16) -> Bool {
        unit >= 0xD800 && unit < 0xE000
    }
}
