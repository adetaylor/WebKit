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

/// C++ `TypeCache::EncodedKey` and the `*Key` structs: a structural key whose children are `TypeID`s, so it holds no
/// pointer and the cache is deterministic.
///
/// An override-sized array keys on its count expression's ID (C++: its address). C++ encodes a runtime-sized array and
/// `creationFixed(0)` the same way; size 0 never reaches `arrayType` (TypeCheck rejects it first), and Swift keys on
/// the full size.
enum TypeKey: Hashable {
    case vector(TypeID, UInt8)
    case matrix(TypeID, UInt8, UInt8)
    case array(TypeID, Types.Array.Size)
    case texture(TypeID, Types.Texture.Kind)
    case textureStorage(Types.TextureStorage.Kind, TexelFormat, AccessMode)
    case reference(TypeID, AddressSpace, AccessMode, Bool)
    case pointer(TypeID, AddressSpace, AccessMode)
    case primitiveStruct(Types.PrimitiveStruct.Kind, TypeID)
}

extension TypeKey {
    /// C++ `encode()`.
    ///
    /// (kind, a, b, c) are packed as C++ `EncodedKey`'s first four fields; the element type is `UInt32.max` for none.
    fileprivate var encoded: EncodedTypeKey {
        func pack(_ kind: UInt64, _ a: UInt8, _ b: UInt16, _ c: UInt32) -> UInt64 {
            kind | UInt64(a) << 8 | UInt64(b) << 16 | UInt64(c) << 32
        }
        switch self {
        case .vector(let element, let size):
            return EncodedTypeKey(word: pack(1, size, 0, 0), element: element.raw)
        case .matrix(let element, let columns, let rows):
            return EncodedTypeKey(word: pack(2, columns, UInt16(rows), 0), element: element.raw)
        case .array(let element, let size):
            switch size {
            case .runtime:
                return EncodedTypeKey(word: pack(3, 0, 0, 0), element: element.raw)
            case .creationFixed(let count):
                return EncodedTypeKey(word: pack(3, 1, 0, count), element: element.raw)
            case .overrideSized(let expression):
                return EncodedTypeKey(word: pack(3, 2, 0, expression.raw), element: element.raw)
            }
        case .texture(let element, let kind):
            return EncodedTypeKey(word: pack(4, kind.rawValue, 0, 0), element: element.raw)
        case .textureStorage(let kind, let format, let access):
            return EncodedTypeKey(word: pack(5, kind.rawValue, UInt16(format.rawValue), UInt32(access.rawValue)), element: .max)
        case .reference(let element, let addressSpace, let accessMode, let isVectorComponent):
            return EncodedTypeKey(
                word: pack(6, addressSpace.rawValue, UInt16(accessMode.rawValue), isVectorComponent ? 1 : 0),
                element: element.raw
            )
        case .pointer(let element, let addressSpace, let accessMode):
            return EncodedTypeKey(word: pack(7, addressSpace.rawValue, UInt16(accessMode.rawValue), 0), element: element.raw)
        case .primitiveStruct(let kind, let element):
            return EncodedTypeKey(word: pack(8, kind.rawValue, 0, 0), element: element.raw)
        }
    }
}

/// A `TypeKey` as two integers, which `TypeCache` hashes as two words.
private struct EncodedTypeKey: Equatable {
    let word: UInt64
    let element: UInt32
}

/// C++ `TypeCache`, lookup-only: an open-addressing table (linear probing, at most half full) of encoded keys.
///
/// Each insertion is logged, so a rollback removes the keys added since its mark.
struct TypeCache {
    private struct Slot {
        var key: EncodedTypeKey
        var type: TypeID?
    }

    private var slots: [Slot] = []
    private var occupied = 0
    private var log: [EncodedTypeKey] = []

    var count: Int { log.count }

    func find(_ key: TypeKey) -> TypeID? {
        guard !slots.isEmpty else {
            return nil
        }
        let encoded = key.encoded
        let mask = slots.count &- 1
        var index = Self.hash(encoded) & mask
        while let type = slots[index].type {
            if slots[index].key == encoded {
                return type
            }
            index = (index &+ 1) & mask
        }
        return nil
    }

    mutating func insert(_ key: TypeKey, _ type: TypeID) {
        if (occupied &+ 1) &* 2 > slots.count {
            grow()
        }
        let encoded = key.encoded
        let isNewEntry = place(encoded, type)
        assert(isNewEntry)
        if isNewEntry {
            log.append(encoded)
        }
    }

    mutating func rollback(to count: Int) {
        guard count <= log.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        var index = log.count
        while index > count {
            index -= 1
            remove(log[index])
        }
        log.removeSubrange(count...)
    }

    // SipHash with the stdlib's per-process random seed: the source chooses the keys (array sizes), and under an unkeyed
    // mix it could fill one probe cluster.
    private static func hash(_ key: EncodedTypeKey) -> Int {
        var hasher = Hasher()
        hasher.combine(key.word)
        hasher.combine(key.element)
        return hasher.finalize()
    }

    /// Returns false when the key is already present (C++ `HashMap::add`, which does not overwrite).
    private mutating func place(_ key: EncodedTypeKey, _ type: TypeID) -> Bool {
        let mask = slots.count &- 1
        var index = Self.hash(key) & mask
        while slots[index].type != nil {
            if slots[index].key == key {
                return false
            }
            index = (index &+ 1) & mask
        }
        slots[index] = Slot(key: key, type: type)
        occupied &+= 1
        return true
    }

    private mutating func grow() {
        let old = slots
        slots = [Slot](repeating: Slot(key: EncodedTypeKey(word: 0, element: 0), type: nil), count: cxxMax(64, old.count &* 2))
        occupied = 0
        var index = 0
        while index < old.count {
            if let type = old[index].type {
                _ = place(old[index].key, type)
            }
            index &+= 1
        }
    }

    /// Linear-probing deletion: the entries after the removed one in its cluster move back so that no lookup stops early.
    private mutating func remove(_ key: EncodedTypeKey) {
        let mask = slots.count &- 1
        var index = Self.hash(key) & mask
        while slots[index].key != key || slots[index].type == nil {
            guard slots[index].type != nil else {
                return
            }
            index = (index &+ 1) & mask
        }
        slots[index].type = nil
        occupied &-= 1
        var next = (index &+ 1) & mask
        while slots[next].type != nil {
            let home = Self.hash(slots[next].key) & mask
            // Move the entry into the hole unless its home lies cyclically in (index, next].
            let distanceToNext = (next &- home) & mask
            let distanceToHole = (index &- home) & mask
            if distanceToHole < distanceToNext {
                slots[index] = slots[next]
                slots[next].type = nil
                index = next
            }
            next = (next &+ 1) & mask
        }
    }

    /// The longest run of occupied slots, which bounds the probes of any lookup.
    func longestProbeRun() -> Int {
        var longest = 0
        var run = 0
        var index = 0
        while index < 2 &* slots.count {
            if slots[index & (slots.count &- 1)].type == nil {
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

/// A list of `TypeStore.typeListPool`: `count` types from `start`, immutable after creation.
struct TypeListRange: BitwiseCopyable, Equatable {
    let start: UInt32
    let count: UInt32
}

/// C++ `TypeStore`: every type of a module, by creation-order `TypeID`, and the interning cache.
///
/// The constructor's types have fixed IDs (`FixedTypeID`). Unlike C++, the store is rolled back with each
/// CompilationScope: the types, the cache keys and the side tables created inside it are dropped.
@_spi(Testing)
public struct TypeStore: ~Copyable {
    private var types = Arena<TypeID, Type>()
    private var cache = TypeCache()
    private var typeLists = Arena<TypeListID, TypeListRange>()
    private var typeListPool: [TypeID] = []
    private var structFields = Arena<StructFieldsID, SymbolMap<TypeID>>()

    @_spi(Testing)
    public init() {
        allocateFixedType(.primitive(Types.Primitive(kind: .abstractInt)), FixedTypeID.abstractInt)
        allocateFixedType(.primitive(Types.Primitive(kind: .abstractFloat)), FixedTypeID.abstractFloat)
        allocateFixedType(.primitive(Types.Primitive(kind: .void)), FixedTypeID.void)
        allocateFixedType(.primitive(Types.Primitive(kind: .bool)), FixedTypeID.bool)
        allocateFixedType(.primitive(Types.Primitive(kind: .i32)), FixedTypeID.i32)
        allocateFixedType(.primitive(Types.Primitive(kind: .u32)), FixedTypeID.u32)
        allocateFixedType(.primitive(Types.Primitive(kind: .f32)), FixedTypeID.f32)
        allocateFixedType(.primitive(Types.Primitive(kind: .f16)), FixedTypeID.f16)
        allocateFixedType(.primitive(Types.Primitive(kind: .sampler)), FixedTypeID.sampler)
        allocateFixedType(.primitive(Types.Primitive(kind: .samplerComparison)), FixedTypeID.samplerComparison)
        allocateFixedType(.primitive(Types.Primitive(kind: .textureExternal)), FixedTypeID.textureExternal)
        allocateFixedType(.primitive(Types.Primitive(kind: .accessMode)), FixedTypeID.accessMode)
        allocateFixedType(.primitive(Types.Primitive(kind: .texelFormat)), FixedTypeID.texelFormat)
        allocateFixedType(.primitive(Types.Primitive(kind: .addressSpace)), FixedTypeID.addressSpace)
        allocateFixedType(.textureDepth(Types.TextureDepth(kind: .textureDepth2d)), FixedTypeID.textureDepth2d)
        allocateFixedType(.textureDepth(Types.TextureDepth(kind: .textureDepth2dArray)), FixedTypeID.textureDepth2dArray)
        allocateFixedType(.textureDepth(Types.TextureDepth(kind: .textureDepthCube)), FixedTypeID.textureDepthCube)
        allocateFixedType(.textureDepth(Types.TextureDepth(kind: .textureDepthCubeArray)), FixedTypeID.textureDepthCubeArray)
        allocateFixedType(.textureDepth(Types.TextureDepth(kind: .textureDepthMultisampled2d)), FixedTypeID.textureDepthMultisampled2d)
        allocateFixedType(.atomic(Types.Atomic(element: FixedTypeID.i32)), FixedTypeID.atomicI32)
        allocateFixedType(.atomic(Types.Atomic(element: FixedTypeID.u32)), FixedTypeID.atomicU32)
    }

    @_spi(Testing)
    public var voidType: TypeID { FixedTypeID.void }
    @_spi(Testing)
    public var boolType: TypeID { FixedTypeID.bool }

    @_spi(Testing)
    public var abstractIntType: TypeID { FixedTypeID.abstractInt }
    @_spi(Testing)
    public var i32Type: TypeID { FixedTypeID.i32 }
    @_spi(Testing)
    public var u32Type: TypeID { FixedTypeID.u32 }

    @_spi(Testing)
    public var abstractFloatType: TypeID { FixedTypeID.abstractFloat }
    @_spi(Testing)
    public var f32Type: TypeID { FixedTypeID.f32 }
    @_spi(Testing)
    public var f16Type: TypeID { FixedTypeID.f16 }
    @_spi(Testing)
    public var samplerType: TypeID { FixedTypeID.sampler }
    @_spi(Testing)
    public var samplerComparisonType: TypeID { FixedTypeID.samplerComparison }
    @_spi(Testing)
    public var textureExternalType: TypeID { FixedTypeID.textureExternal }
    @_spi(Testing)
    public var accessModeType: TypeID { FixedTypeID.accessMode }
    @_spi(Testing)
    public var texelFormatType: TypeID { FixedTypeID.texelFormat }
    @_spi(Testing)
    public var addressSpaceType: TypeID { FixedTypeID.addressSpace }

    @_spi(Testing)
    public var textureDepth2dType: TypeID { FixedTypeID.textureDepth2d }
    @_spi(Testing)
    public var textureDepth2dArrayType: TypeID { FixedTypeID.textureDepth2dArray }
    @_spi(Testing)
    public var textureDepthCubeType: TypeID { FixedTypeID.textureDepthCube }
    @_spi(Testing)
    public var textureDepthCubeArrayType: TypeID { FixedTypeID.textureDepthCubeArray }
    @_spi(Testing)
    public var textureDepthMultisampled2dType: TypeID { FixedTypeID.textureDepthMultisampled2d }

    /// Not interned; the structure node keeps it as its inferred type.
    @_spi(Testing)
    public mutating func structType(_ structure: StructureID, _ fields: SymbolMap<TypeID> = SymbolMap()) -> TypeID {
        allocateType(.struct(Types.Struct(structure: structure, fields: structFields.append(fields))))
    }

    @_spi(Testing)
    public mutating func arrayType(_ elementType: TypeID, _ size: Types.Array.Size) -> TypeID {
        let key = TypeKey.array(elementType, size)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(.array(Types.Array(element: elementType, size: size)))
        cache.insert(key, type)
        return type
    }

    @_spi(Testing)
    public mutating func vectorType(_ size: UInt8, _ elementType: TypeID) -> TypeID {
        let key = TypeKey.vector(elementType, size)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(.vector(Types.Vector(element: elementType, size: size)))
        cache.insert(key, type)
        return type
    }

    @_spi(Testing)
    public mutating func matrixType(_ columns: UInt8, _ rows: UInt8, _ elementType: TypeID) -> TypeID {
        let key = TypeKey.matrix(elementType, columns, rows)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(.matrix(Types.Matrix(element: elementType, columns: columns, rows: rows)))
        cache.insert(key, type)
        return type
    }

    @_spi(Testing)
    public mutating func textureType(_ kind: Types.Texture.Kind, _ elementType: TypeID) -> TypeID {
        let key = TypeKey.texture(elementType, kind)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(.texture(Types.Texture(element: elementType, kind: kind)))
        cache.insert(key, type)
        return type
    }

    @_spi(Testing)
    public mutating func textureStorageType(_ kind: Types.TextureStorage.Kind, _ format: TexelFormat, _ access: AccessMode) -> TypeID {
        let key = TypeKey.textureStorage(kind, format, access)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(.textureStorage(Types.TextureStorage(kind: kind, format: format, access: access)))
        cache.insert(key, type)
        return type
    }

    /// Not interned.
    @_spi(Testing)
    public mutating func functionType(_ parameters: [TypeID], _ result: TypeID, mustUse: Bool, isEntryPoint: Bool) -> TypeID {
        let parameters = makeTypeList(parameters)
        return allocateType(.function(Types.Function(parameters: parameters, result: result, mustUse: mustUse, isEntryPoint: isEntryPoint)))
    }

    @_spi(Testing)
    public mutating func referenceType(
        _ addressSpace: AddressSpace,
        _ element: TypeID,
        _ accessMode: AccessMode,
        isVectorComponent: Bool = false
    ) -> TypeID {
        let key = TypeKey.reference(element, addressSpace, accessMode, isVectorComponent)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(
            .reference(
                Types.Reference(addressSpace: addressSpace, accessMode: accessMode, element: element, isVectorComponent: isVectorComponent)
            )
        )
        cache.insert(key, type)
        return type
    }

    @_spi(Testing)
    public mutating func pointerType(_ addressSpace: AddressSpace, _ element: TypeID, _ accessMode: AccessMode) -> TypeID {
        let key = TypeKey.pointer(element, addressSpace, accessMode)
        if let type = cache.find(key) {
            return type
        }
        let type = allocateType(.pointer(Types.Pointer(addressSpace: addressSpace, accessMode: accessMode, element: element)))
        cache.insert(key, type)
        return type
    }

    /// C++ checks `type == u32` only in debug builds: in release, every type other than i32 gets atomic<u32>.
    @_spi(Testing)
    public func atomicType(_ type: TypeID) -> TypeID {
        if type == i32Type {
            return FixedTypeID.atomicI32
        }
        assert(type == u32Type)
        return FixedTypeID.atomicU32
    }

    /// Not interned.
    @_spi(Testing)
    public mutating func typeConstructorType(_ kind: Types.TypeConstructor.Kind) -> TypeID {
        let constructor = Types.TypeConstructor(kind: kind)
        guard constructor.hasValidSize else {
            wgslFatal("type constructor of an invalid size", cppSite: "TypeCheck.cpp:397")
        }
        return allocateType(.typeConstructor(constructor))
    }

    @_spi(Testing)
    public mutating func frexpResultType(_ fract: TypeID, _ exp: TypeID) -> TypeID {
        let key = TypeKey.primitiveStruct(Types.PrimitiveStruct.FrexpResult.kind, fract)
        if let type = cache.find(key) {
            return type
        }

        var values = [TypeID](repeating: fract, count: 2)
        values[Types.PrimitiveStruct.FrexpResult.fract] = fract
        values[Types.PrimitiveStruct.FrexpResult.exp] = exp
        let type = allocateType(
            .primitiveStruct(Types.PrimitiveStruct(kind: Types.PrimitiveStruct.FrexpResult.kind, values: makeTypeList(values)))
        )
        cache.insert(key, type)
        return type
    }

    @_spi(Testing)
    public mutating func modfResultType(_ fract: TypeID, _ whole: TypeID) -> TypeID {
        let key = TypeKey.primitiveStruct(Types.PrimitiveStruct.ModfResult.kind, fract)
        if let type = cache.find(key) {
            return type
        }

        var values = [TypeID](repeating: fract, count: 2)
        values[Types.PrimitiveStruct.ModfResult.fract] = fract
        values[Types.PrimitiveStruct.ModfResult.whole] = whole
        let type = allocateType(
            .primitiveStruct(Types.PrimitiveStruct(kind: Types.PrimitiveStruct.ModfResult.kind, values: makeTypeList(values)))
        )
        cache.insert(key, type)
        return type
    }

    /// C++ memoises the two results in members; the cache key does the same and rolls back with the scope.
    ///
    /// As in release C++, every type other than i32 shares the u32 slot, which holds the type of its first request.
    @_spi(Testing)
    public mutating func atomicCompareExchangeResultType(_ type: TypeID) -> TypeID {
        if type == i32Type {
            return loadAtomicCompareExchangeResultType(i32Type, type)
        }
        assert(type == u32Type)
        return loadAtomicCompareExchangeResultType(u32Type, type)
    }

    private mutating func loadAtomicCompareExchangeResultType(_ member: TypeID, _ type: TypeID) -> TypeID {
        let key = TypeKey.primitiveStruct(Types.PrimitiveStruct.AtomicCompareExchangeResult.kind, member)
        if let result = cache.find(key) {
            return result
        }
        var values = [TypeID](repeating: type, count: 2)
        values[Types.PrimitiveStruct.AtomicCompareExchangeResult.oldValue] = type
        values[Types.PrimitiveStruct.AtomicCompareExchangeResult.exchanged] = boolType
        let result = allocateType(
            .primitiveStruct(
                Types.PrimitiveStruct(kind: Types.PrimitiveStruct.AtomicCompareExchangeResult.kind, values: makeTypeList(values))
            )
        )
        cache.insert(key, result)
        return result
    }

    private mutating func allocateType(_ type: Type) -> TypeID {
        types.append(type)
    }

    // MARK: - Swift-only

    private mutating func allocateFixedType(_ type: Type, _ expected: TypeID) {
        guard allocateType(type) == expected else {
            wgslFatal("TypeStore allocated a fixed type at the wrong ID", cppSite: "TypeStore.cpp:127")
        }
    }

    private mutating func makeTypeList(_ elements: [TypeID]) -> TypeListID {
        let start = UInt32(typeListPool.count)
        typeListPool.append(contentsOf: elements)
        return typeLists.append(TypeListRange(start: start, count: UInt32(elements.count)))
    }

    /// The number of types, which is the next `TypeID`.
    @_spi(Testing)
    public var count: Int { types.count }

    @_spi(Testing)
    public subscript(type: TypeID) -> Type { types[type] }

    @_spi(Testing)
    public func count(of list: TypeListID) -> Int {
        Int(typeLists[list].count)
    }

    /// `values[index]` / `parameters[index]`; an index past the list traps (C++ bounds-checked `operator[]`).
    @_spi(Testing)
    public subscript(list: TypeListID, index: Int) -> TypeID {
        let range = typeLists[list]
        guard index >= 0 && index < Int(range.count) else {
            wgslFatal("type list index out of bounds", cppSite: "Types.h:206")
        }
        return typeListPool[Int(range.start) + index]
    }

    /// A copy of a list's types, in order.
    @_spi(Testing)
    public func elements(of list: TypeListID) -> [TypeID] {
        let range = typeLists[list]
        let start = Int(range.start)
        return Array(typeListPool[start..<start + Int(range.count)])
    }

    @_spi(Testing)
    public func fields(of fields: StructFieldsID) -> SymbolMap<TypeID> {
        structFields[fields]
    }

    /// The number of interned keys.
    @_spi(Testing)
    public var cacheCount: Int { cache.count }

    @_spi(Testing)
    public var cacheLongestProbeRun: Int { cache.longestProbeRun() }

    /// The state `openScope` saves and `rollback(to:)` restores.
    @_spi(Testing)
    public struct Mark: BitwiseCopyable {
        fileprivate let types: Arena<TypeID, Type>.Mark
        fileprivate let cacheCount: Int
        fileprivate let typeLists: Arena<TypeListID, TypeListRange>.Mark
        fileprivate let typeListPoolCount: Int
        fileprivate let structFields: Arena<StructFieldsID, SymbolMap<TypeID>>.Mark
    }

    @_spi(Testing)
    public mutating func openScope() -> Mark {
        Mark(
            types: types.openScope(),
            cacheCount: cache.count,
            typeLists: typeLists.openScope(),
            typeListPoolCount: typeListPool.count,
            structFields: structFields.openScope()
        )
    }

    /// Drops the types, cache keys, type lists and struct field tables created since `mark`.
    ///
    /// Nothing that survives the rollback refers to them: the nodes holding their IDs are rolled back too.
    @_spi(Testing)
    public mutating func rollback(to mark: Mark) {
        // DEV-16: C++ keeps every type it ever made; the scope's types are unreachable after the rollback.
        guard mark.typeListPoolCount <= typeListPool.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        cache.rollback(to: mark.cacheCount)
        types.rollback(to: mark.types)
        typeLists.rollback(to: mark.typeLists)
        typeListPool.removeSubrange(mark.typeListPoolCount...)
        structFields.rollback(to: mark.structFields)
    }

    /// A value copy of every table, for rollback tests.
    @_spi(Testing)
    public struct Snapshot: Equatable {
        fileprivate let types: [Type]
        fileprivate let cacheCount: Int
        fileprivate let typeLists: [TypeListRange]
        fileprivate let typeListPool: [TypeID]
        fileprivate let structFields: [SymbolMap<TypeID>]
    }

    @_spi(Testing)
    public func snapshot() -> Snapshot {
        Snapshot(
            types: types.snapshot(),
            cacheCount: cache.count,
            typeLists: typeLists.snapshot(),
            typeListPool: typeListPool,
            structFields: structFields.snapshot()
        )
    }
}
