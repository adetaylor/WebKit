// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

// The storage layer of the WGSL IR: typed IDs, the per-category arenas, the list pool, the constant table and the
// ID-keyed pass containers. This is the only file that can mint IDs.

/// The capability to create an `ID` from a raw index.
///
/// Its initializer is fileprivate, so IDs are minted only by the arenas in this file; passes obtain IDs exclusively from
/// the module. A conformance to `ArenaID` or `ListElement` declared elsewhere is only ever handed a mint for its own type.
@_spi(Testing)
public struct IDMint<ID>: BitwiseCopyable {
    private struct Seal: BitwiseCopyable {}

    private let seal: Seal

    fileprivate init() {
        seal = Seal()
    }
}

/// A dense creation-order index into one arena: a node's identity, as its address is in C++.
@_spi(Testing)
public protocol ArenaID: Hashable, Comparable, BitwiseCopyable, Sendable {
    init(_ raw: UInt32, _ mint: IDMint<Self>)
    var raw: UInt32 { get }
}

extension ArenaID {
    @_spi(Testing)
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.raw < rhs.raw
    }

    var index: Int { Int(raw) }
}

/// C++ `AST::Expression&`.
@_spi(Testing)
public struct ExpressionID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<ExpressionID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Statement&`.
@_spi(Testing)
public struct StatementID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<StatementID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Function&`.
@_spi(Testing)
public struct FunctionID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<FunctionID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Variable&`.
@_spi(Testing)
public struct VariableID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<VariableID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Structure&`.
@_spi(Testing)
public struct StructureID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<StructureID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::StructureMember&`.
@_spi(Testing)
public struct StructureMemberID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<StructureMemberID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Parameter&`.
@_spi(Testing)
public struct ParameterID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<ParameterID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::TypeAlias&`.
@_spi(Testing)
public struct TypeAliasID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<TypeAliasID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::ConstAssert&`.
@_spi(Testing)
public struct ConstAssertID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<ConstAssertID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Attribute&`.
@_spi(Testing)
public struct AttributeID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<AttributeID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Directive&`.
@_spi(Testing)
public struct DirectiveID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<DirectiveID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::SwitchClause&`.
@_spi(Testing)
public struct SwitchClauseID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<SwitchClauseID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `AST::Identifier&`: one node field's identifier slot.
@_spi(Testing)
public struct IdentifierID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<IdentifierID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `const Type*`.
@_spi(Testing)
public struct TypeID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<TypeID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// A TypeStore list of types (function parameters, primitive-struct values).
@_spi(Testing)
public struct TypeListID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<TypeListID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// A TypeStore struct field table.
@_spi(Testing)
public struct StructFieldsID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<StructFieldsID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// C++ `const CallGraph::Global*`.
@_spi(Testing)
public struct CallGraphGlobalID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<CallGraphGlobalID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// A `ListID` with its element type erased.
@_spi(Testing)
public struct AnyListID: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<AnyListID>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }
}

/// A list owned by a node: a C++ `ReferenceWrapperVector<T>` member.
///
/// The header lives in `ListArena`, so a list is addressable for in-place mutation and undo, like a C++ `Vector&`.
@_spi(Testing)
public struct ListID<Element: ListElement>: ArenaID {
    fileprivate let value: UInt32

    @_spi(Testing)
    public init(_ raw: UInt32, _: IDMint<ListID<Element>>) {
        value = raw
    }

    @_spi(Testing)
    public var raw: UInt32 { value }

    @_spi(Testing)
    public var untyped: AnyListID { AnyListID(value, IDMint()) }
}

/// The types TypeStore's constructor allocates (TypeStore.cpp:127-150), at fixed IDs in that order, so module-independent
/// data (the process-global builtin table) can name them. `TypeStore.init` checks each one.
@_spi(Testing)
public enum FixedTypeID {
    @_spi(Testing)
    public static var abstractInt: TypeID { TypeID(0, IDMint()) }

    @_spi(Testing)
    public static var abstractFloat: TypeID { TypeID(1, IDMint()) }

    @_spi(Testing)
    public static var void: TypeID { TypeID(2, IDMint()) }

    @_spi(Testing)
    public static var bool: TypeID { TypeID(3, IDMint()) }

    @_spi(Testing)
    public static var i32: TypeID { TypeID(4, IDMint()) }

    @_spi(Testing)
    public static var u32: TypeID { TypeID(5, IDMint()) }

    @_spi(Testing)
    public static var f32: TypeID { TypeID(6, IDMint()) }

    @_spi(Testing)
    public static var f16: TypeID { TypeID(7, IDMint()) }

    @_spi(Testing)
    public static var sampler: TypeID { TypeID(8, IDMint()) }

    @_spi(Testing)
    public static var samplerComparison: TypeID { TypeID(9, IDMint()) }

    @_spi(Testing)
    public static var textureExternal: TypeID { TypeID(10, IDMint()) }

    @_spi(Testing)
    public static var accessMode: TypeID { TypeID(11, IDMint()) }

    @_spi(Testing)
    public static var texelFormat: TypeID { TypeID(12, IDMint()) }

    @_spi(Testing)
    public static var addressSpace: TypeID { TypeID(13, IDMint()) }

    @_spi(Testing)
    public static var textureDepth2d: TypeID { TypeID(14, IDMint()) }

    @_spi(Testing)
    public static var textureDepth2dArray: TypeID { TypeID(15, IDMint()) }

    @_spi(Testing)
    public static var textureDepthCube: TypeID { TypeID(16, IDMint()) }

    @_spi(Testing)
    public static var textureDepthCubeArray: TypeID { TypeID(17, IDMint()) }

    @_spi(Testing)
    public static var textureDepthMultisampled2d: TypeID { TypeID(18, IDMint()) }

    @_spi(Testing)
    public static var atomicI32: TypeID { TypeID(19, IDMint()) }

    @_spi(Testing)
    public static var atomicU32: TypeID { TypeID(20, IDMint()) }

    @_spi(Testing)
    public static let count: UInt32 = 21
}

/// An element of a node-owned list, stored as one 32-bit word of the list pool.
@_spi(Testing)
public protocol ListElement: BitwiseCopyable {
    init(listWord: UInt32, _ mint: IDMint<Self>)
    var listWord: UInt32 { get }
}

extension ExpressionID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<ExpressionID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension StatementID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<StatementID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension FunctionID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<FunctionID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension VariableID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<VariableID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension StructureID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<StructureID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension StructureMemberID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<StructureMemberID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension ParameterID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<ParameterID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension TypeAliasID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<TypeAliasID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension ConstAssertID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<ConstAssertID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension AttributeID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<AttributeID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension DirectiveID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<DirectiveID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension SwitchClauseID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<SwitchClauseID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension IdentifierID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<IdentifierID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension TypeID: ListElement {
    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<TypeID>) {
        value = listWord
    }

    @_spi(Testing)
    public var listWord: UInt32 { value }
}

extension Declaration: ListElement {
    private enum ListTag: UInt32 {
        case function
        case variable
        case structure
        case typeAlias
        case constAssert
    }

    // A 3-bit tag and a 29-bit index.
    private static var tagShift: UInt32 { 29 }
    private static var indexMask: UInt32 { (1 << 29) - 1 }

    @_spi(Testing)
    public init(listWord: UInt32, _: IDMint<Declaration>) {
        let raw = listWord & Declaration.indexMask
        guard let tag = ListTag(rawValue: listWord >> Declaration.tagShift) else {
            wgslFatal("corrupt declaration list word", cppSite: "ASTDeclaration.h:36")
        }
        switch tag {
        case .function:
            self = .function(FunctionID(raw, IDMint()))
        case .variable:
            self = .variable(VariableID(raw, IDMint()))
        case .structure:
            self = .structure(StructureID(raw, IDMint()))
        case .typeAlias:
            self = .typeAlias(TypeAliasID(raw, IDMint()))
        case .constAssert:
            self = .constAssert(ConstAssertID(raw, IDMint()))
        }
    }

    @_spi(Testing)
    public var listWord: UInt32 {
        let tag: ListTag
        let raw: UInt32
        switch self {
        case .function(let function):
            (tag, raw) = (.function, function.value)
        case .variable(let variable):
            (tag, raw) = (.variable, variable.value)
        case .structure(let structure):
            (tag, raw) = (.structure, structure.value)
        case .typeAlias(let typeAlias):
            (tag, raw) = (.typeAlias, typeAlias.value)
        case .constAssert(let constAssert):
            (tag, raw) = (.constAssert, constAssert.value)
        }
        guard raw <= Declaration.indexMask else {
            wgslFatal("too many declarations of one kind", cppSite: "ASTDeclaration.h:36")
        }
        return tag.rawValue << Declaration.tagShift | raw
    }
}

/// `TypeID?` in 4 bytes (`UInt32.max` = nullptr), for dense node slots.
struct PackedTypeID: BitwiseCopyable, Equatable {
    private var raw: UInt32

    init(_ type: TypeID?) {
        raw = type?.value ?? .max
    }

    var value: TypeID? { raw == .max ? nil : TypeID(raw, IDMint()) }
}

/// An optional ID of any category in 4 bytes (`UInt32.max` = nullptr), for dense node slots.
struct PackedID<ID: ArenaID>: BitwiseCopyable, Equatable {
    private var raw: UInt32

    init(_ id: ID?) {
        raw = id?.raw ?? .max
    }

    var value: ID? { raw == .max ? nil : ID(raw, IDMint()) }
}

/// Per-category node storage: a C++ `AST::Builder` for one node category, noncopyable like the Builder.
///
/// The floor is the element count when the innermost CompilationScope opened (0 outside any scope). A node below it
/// predates the scope, so writes to it go through `overwrite` or `update`, which log the old value for rollback; a plain
/// subscript write to it traps.
@_spi(Testing)
public struct Arena<ID: ArenaID, Element>: ~Copyable {
    private var elements: [Element] = []
    private var undo: [(id: ID, element: Element)] = []
    private var floor: UInt32 = 0

    /// The state `openScope` saves and `rollback(to:)` restores (C++ `Builder::State`).
    @_spi(Testing)
    public struct Mark: BitwiseCopyable {
        fileprivate let count: Int
        fileprivate let undoCount: Int
        fileprivate let floor: UInt32
    }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { elements.count }

    @_spi(Testing)
    public var isEmpty: Bool { elements.isEmpty }

    @_spi(Testing)
    public var undoCount: Int { undo.count }

    @_spi(Testing)
    public var ids: IDRange<ID> { IDRange(count: UInt32(truncatingIfNeeded: elements.count)) }

    @_spi(Testing)
    public mutating func reserveCapacity(_ capacity: Int) {
        elements.reserveCapacity(capacity)
    }

    /// C++ `Builder::construct`: the new node's ID is the next creation-order index.
    @_spi(Testing)
    public mutating func append(_ element: Element) -> ID {
        guard elements.count < Int(UInt32.max) else {
            wgslFatal("arena overflow", cppSite: "ASTBuilder.h:64")
        }
        let id = ID(UInt32(truncatingIfNeeded: elements.count), IDMint())
        elements.append(element)
        return id
    }

    @_spi(Testing)
    public func contains(_ id: ID) -> Bool {
        id.index < elements.count
    }

    /// Writing a node that predates the open CompilationScope traps: the write would survive rollback.
    @_spi(Testing)
    public subscript(id: ID) -> Element {
        get { elements[id.index] }
        set {
            guard id.raw >= floor else {
                wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
            }
            elements[id.index] = newValue
        }
    }

    /// Replaces a slot, logging the old value when the node predates the open scope (C++ `replace()`).
    @_spi(Testing)
    public mutating func overwrite(_ id: ID, with element: Element) {
        if id.raw < floor {
            undo.append((id, elements[id.index]))
        }
        elements[id.index] = element
    }

    /// Edits a slot in place, logging the old value when the node predates the open scope.
    @_spi(Testing)
    public mutating func update<R, E: Error>(_ id: ID, _ body: (inout Element) throws(E) -> R) throws(E) -> R {
        if id.raw < floor {
            undo.append((id, elements[id.index]))
        }
        return try body(&elements[id.index])
    }

    @_spi(Testing)
    public mutating func openScope() -> Mark {
        let mark = Mark(count: elements.count, undoCount: undo.count, floor: floor)
        floor = UInt32(truncatingIfNeeded: elements.count)
        return mark
    }

    /// Restores the logged old values, newest first, then drops the nodes created since `mark` (C++ `Builder::restore`).
    @_spi(Testing)
    public mutating func rollback(to mark: Mark) {
        guard mark.count <= elements.count, mark.undoCount <= undo.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        var undoIndex = undo.count
        while undoIndex > mark.undoCount {
            undoIndex -= 1
            let entry = undo[undoIndex]
            elements[entry.id.index] = entry.element
        }
        undo.removeSubrange(mark.undoCount...)
        elements.removeSubrange(mark.count...)
        floor = mark.floor
    }

    /// A copy of every slot in creation order.
    @_spi(Testing)
    public func snapshot() -> [Element] {
        elements
    }
}

/// `Arena<ExpressionID, ExpressionNode>` as a concrete type: the same API, without generic dispatch at -Onone.
@_spi(Testing)
public struct ExpressionArena: ~Copyable {
    private var elements: [ExpressionNode] = []
    private var undo: [(id: ExpressionID, element: ExpressionNode)] = []
    private var floor: UInt32 = 0

    /// The state `openScope` saves and `rollback(to:)` restores (C++ `Builder::State`).
    @_spi(Testing)
    public struct Mark: BitwiseCopyable {
        fileprivate let count: Int
        fileprivate let undoCount: Int
        fileprivate let floor: UInt32
    }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { elements.count }

    @_spi(Testing)
    public var isEmpty: Bool { elements.isEmpty }

    @_spi(Testing)
    public var undoCount: Int { undo.count }

    @_spi(Testing)
    public var ids: IDRange<ExpressionID> { IDRange(count: UInt32(truncatingIfNeeded: elements.count)) }

    @_spi(Testing)
    public mutating func reserveCapacity(_ capacity: Int) {
        elements.reserveCapacity(capacity)
    }

    /// C++ `Builder::construct`: the new node's ID is the next creation-order index.
    @_spi(Testing)
    public mutating func append(_ element: ExpressionNode) -> ExpressionID {
        guard elements.count < Int(UInt32.max) else {
            wgslFatal("arena overflow", cppSite: "ASTBuilder.h:64")
        }
        let id = ExpressionID(UInt32(truncatingIfNeeded: elements.count), IDMint())
        elements.append(element)
        return id
    }

    @_spi(Testing)
    public func contains(_ id: ExpressionID) -> Bool {
        Int(id.value) < elements.count
    }

    /// Writing a node that predates the open CompilationScope traps: the write would survive rollback.
    @_spi(Testing)
    public subscript(id: ExpressionID) -> ExpressionNode {
        get { elements[Int(id.value)] }
        set {
            guard id.value >= floor else {
                wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
            }
            elements[Int(id.value)] = newValue
        }
    }

    /// The subscript setter's writes of the inferred type and the evaluation, in one access to the slot.
    @_spi(Testing)
    @inline(__always)
    public mutating func setInferredType(_ type: TypeID?, evaluation: Evaluation?, for id: ExpressionID) {
        guard id.value >= floor else {
            ExpressionArena.writeBelowFloor()
        }
        let index = Int(id.value)
        elements[index].inferredType = type
        elements[index].evaluation = evaluation
    }

    /// The subscript setter's write of the inferred type alone.
    @_spi(Testing)
    @inline(__always)
    public mutating func setInferredType(_ type: TypeID?, for id: ExpressionID) {
        guard id.value >= floor else {
            ExpressionArena.writeBelowFloor()
        }
        elements[Int(id.value)].inferredType = type
    }

    @inline(never)
    private static func writeBelowFloor() -> Never {
        wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
    }

    /// Replaces a slot, logging the old value when the node predates the open scope (C++ `replace()`).
    @_spi(Testing)
    public mutating func overwrite(_ id: ExpressionID, with element: ExpressionNode) {
        if id.value < floor {
            undo.append((id, elements[Int(id.value)]))
        }
        elements[Int(id.value)] = element
    }

    /// Edits a slot in place, logging the old value when the node predates the open scope.
    @_spi(Testing)
    public mutating func update<R, E: Error>(_ id: ExpressionID, _ body: (inout ExpressionNode) throws(E) -> R) throws(E) -> R {
        if id.value < floor {
            undo.append((id, elements[Int(id.value)]))
        }
        return try body(&elements[Int(id.value)])
    }

    @_spi(Testing)
    public mutating func openScope() -> Mark {
        let mark = Mark(count: elements.count, undoCount: undo.count, floor: floor)
        floor = UInt32(truncatingIfNeeded: elements.count)
        return mark
    }

    /// Restores the logged old values, newest first, then drops the nodes created since `mark` (C++ `Builder::restore`).
    @_spi(Testing)
    public mutating func rollback(to mark: Mark) {
        guard mark.count <= elements.count, mark.undoCount <= undo.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        var undoIndex = undo.count
        while undoIndex > mark.undoCount {
            undoIndex -= 1
            let entry = undo[undoIndex]
            elements[Int(entry.id.value)] = entry.element
        }
        undo.removeSubrange(mark.undoCount...)
        elements.removeSubrange(mark.count...)
        floor = mark.floor
    }

    /// A copy of every slot in creation order.
    @_spi(Testing)
    public func snapshot() -> [ExpressionNode] {
        elements
    }
}

/// `Arena<StatementID, StatementNode>` as a concrete type: the same API, without generic dispatch at -Onone.
@_spi(Testing)
public struct StatementArena: ~Copyable {
    private var elements: [StatementNode] = []
    private var undo: [(id: StatementID, element: StatementNode)] = []
    private var floor: UInt32 = 0

    /// The state `openScope` saves and `rollback(to:)` restores (C++ `Builder::State`).
    @_spi(Testing)
    public struct Mark: BitwiseCopyable {
        fileprivate let count: Int
        fileprivate let undoCount: Int
        fileprivate let floor: UInt32
    }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { elements.count }

    @_spi(Testing)
    public var isEmpty: Bool { elements.isEmpty }

    @_spi(Testing)
    public var undoCount: Int { undo.count }

    @_spi(Testing)
    public var ids: IDRange<StatementID> { IDRange(count: UInt32(truncatingIfNeeded: elements.count)) }

    @_spi(Testing)
    public mutating func reserveCapacity(_ capacity: Int) {
        elements.reserveCapacity(capacity)
    }

    /// C++ `Builder::construct`: the new node's ID is the next creation-order index.
    @_spi(Testing)
    public mutating func append(_ element: StatementNode) -> StatementID {
        guard elements.count < Int(UInt32.max) else {
            wgslFatal("arena overflow", cppSite: "ASTBuilder.h:64")
        }
        let id = StatementID(UInt32(truncatingIfNeeded: elements.count), IDMint())
        elements.append(element)
        return id
    }

    @_spi(Testing)
    public func contains(_ id: StatementID) -> Bool {
        Int(id.value) < elements.count
    }

    /// Writing a node that predates the open CompilationScope traps: the write would survive rollback.
    @_spi(Testing)
    public subscript(id: StatementID) -> StatementNode {
        get { elements[Int(id.value)] }
        set {
            guard id.value >= floor else {
                wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
            }
            elements[Int(id.value)] = newValue
        }
    }

    /// Replaces a slot, logging the old value when the node predates the open scope (C++ `replace()`).
    @_spi(Testing)
    public mutating func overwrite(_ id: StatementID, with element: StatementNode) {
        if id.value < floor {
            undo.append((id, elements[Int(id.value)]))
        }
        elements[Int(id.value)] = element
    }

    /// Edits a slot in place, logging the old value when the node predates the open scope.
    @_spi(Testing)
    public mutating func update<R, E: Error>(_ id: StatementID, _ body: (inout StatementNode) throws(E) -> R) throws(E) -> R {
        if id.value < floor {
            undo.append((id, elements[Int(id.value)]))
        }
        return try body(&elements[Int(id.value)])
    }

    @_spi(Testing)
    public mutating func openScope() -> Mark {
        let mark = Mark(count: elements.count, undoCount: undo.count, floor: floor)
        floor = UInt32(truncatingIfNeeded: elements.count)
        return mark
    }

    /// Restores the logged old values, newest first, then drops the nodes created since `mark` (C++ `Builder::restore`).
    @_spi(Testing)
    public mutating func rollback(to mark: Mark) {
        guard mark.count <= elements.count, mark.undoCount <= undo.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        var undoIndex = undo.count
        while undoIndex > mark.undoCount {
            undoIndex -= 1
            let entry = undo[undoIndex]
            elements[Int(entry.id.value)] = entry.element
        }
        undo.removeSubrange(mark.undoCount...)
        elements.removeSubrange(mark.count...)
        floor = mark.floor
    }

    /// A copy of every slot in creation order.
    @_spi(Testing)
    public func snapshot() -> [StatementNode] {
        elements
    }
}

/// The IDs of an arena, in ascending creation order.
@_spi(Testing)
public struct IDRange<ID: ArenaID>: Sequence, Sendable {
    @_spi(Testing)
    public let count: UInt32

    fileprivate init(count: UInt32) {
        self.count = count
    }

    @_spi(Testing)
    public struct Iterator: IteratorProtocol {
        private var current: UInt32 = 0
        private let end: UInt32

        fileprivate init(end: UInt32) {
            self.end = end
        }

        @_spi(Testing)
        public mutating func next() -> ID? {
            guard current < end else {
                return nil
            }
            let id = ID(current, IDMint())
            current += 1
            return id
        }
    }

    @_spi(Testing)
    public func makeIterator() -> Iterator {
        Iterator(end: count)
    }

    @_spi(Testing)
    public var underestimatedCount: Int { Int(count) }
}

/// A list's storage: `count` words of the pool from `start`, with room for `capacity` (a C++ Vector's buffer).
@_spi(Testing)
public struct ListHeader: BitwiseCopyable, Equatable {
    @_spi(Testing)
    public fileprivate(set) var start: UInt32

    @_spi(Testing)
    public fileprivate(set) var count: UInt32

    @_spi(Testing)
    public fileprivate(set) var capacity: UInt32
}

/// C++ range-for over a node's list (`for (auto& x : list)`), which lets the loop body mutate the module.
///
/// `end` is the count when the loop started and each element is read from the list's current storage, as for a C++
/// Vector that does not reallocate: elements appended during the loop are not visited, and shifts from `insert` and
/// `remove` are seen.
@_spi(Testing)
public struct ListCursor<Element: ListElement>: BitwiseCopyable {
    fileprivate let list: UInt32
    fileprivate var position: UInt32
    fileprivate let end: UInt32

    /// Whether the loop has reached the count the list had when it started; see `ShaderModule.advance`.
    @_spi(Testing)
    public var isAtEnd: Bool { position >= end }
}

/// Every node-owned list, as headers over one pool of 32-bit words; noncopyable like the C++ Builder.
///
/// Outside any scope a list is edited in place with amortised doubling. Inside a scope, storage below the pool floor is
/// never written: the first edit of an older list copies it to the pool tail with room to grow and logs its old header,
/// and later edits grow in place at the tail or relocate with doubling, so every edit is amortised O(1). Undo restores
/// headers and rollback truncates the pool.
@_spi(Testing)
public struct ListArena: ~Copyable {
    private var headers: [ListHeader] = []
    private var undo: [(list: UInt32, header: ListHeader)] = []
    private var floor: UInt32 = 0
    private var pool: [UInt32] = []
    private var poolFloor: UInt32 = 0

    /// The state `openScope` saves and `rollback(to:)` restores.
    @_spi(Testing)
    public struct Mark: BitwiseCopyable {
        fileprivate let listCount: Int
        fileprivate let undoCount: Int
        fileprivate let floor: UInt32
        fileprivate let poolCount: Int
        fileprivate let poolFloor: UInt32
    }

    /// Every header and pool word.
    @_spi(Testing)
    public struct Snapshot: Equatable {
        fileprivate let headers: [ListHeader]
        fileprivate let pool: [UInt32]
    }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var listCount: Int { headers.count }

    @_spi(Testing)
    public var poolCount: Int { pool.count }

    @_spi(Testing)
    public var undoCount: Int { undo.count }

    @_spi(Testing)
    public mutating func reserveCapacity(lists: Int, words: Int) {
        headers.reserveCapacity(lists)
        pool.reserveCapacity(words)
    }

    /// A list holding `elements`, with no spare capacity (the C++ constructor moves its argument Vector into the node).
    @_spi(Testing)
    public mutating func make<Element: ListElement>(_ elements: [Element]) -> ListID<Element> {
        let start = poolEnd(adding: elements.count)
        var index = 0
        while index < elements.count {
            pool.append(elements[index].listWord)
            index += 1
        }
        let count = UInt32(truncatingIfNeeded: elements.count)
        return ListID(appendHeader(ListHeader(start: start, count: count, capacity: count)), IDMint())
    }

    @_spi(Testing)
    public mutating func makeEmpty<Element: ListElement>(_: Element.Type) -> ListID<Element> {
        ListID(appendHeader(ListHeader(start: poolEnd(adding: 0), count: 0, capacity: 0)), IDMint())
    }

    @_spi(Testing)
    public func header<Element: ListElement>(_ list: ListID<Element>) -> ListHeader {
        headers[Int(list.value)]
    }

    @_spi(Testing)
    public func count<Element: ListElement>(_ list: ListID<Element>) -> Int {
        Int(headers[Int(list.value)].count)
    }

    @_spi(Testing)
    public func count(_ list: ListID<ExpressionID>) -> Int {
        Int(headers[Int(list.value)].count)
    }

    @_spi(Testing)
    public func count(_ list: ListID<StatementID>) -> Int {
        Int(headers[Int(list.value)].count)
    }

    @_spi(Testing)
    public func count(_ list: ListID<AttributeID>) -> Int {
        Int(headers[Int(list.value)].count)
    }

    @_spi(Testing)
    public func count(_ list: ListID<Declaration>) -> Int {
        Int(headers[Int(list.value)].count)
    }

    /// C++ `vector[index]`, which traps when `index` is out of range.
    @_spi(Testing)
    public subscript<Element: ListElement>(list: ListID<Element>, index: Int) -> Element {
        Element(listWord: word(list.value, index), IDMint())
    }

    @_spi(Testing)
    public subscript(list: ListID<ExpressionID>, index: Int) -> ExpressionID {
        ExpressionID(word(list.value, index), IDMint())
    }

    @_spi(Testing)
    public subscript(list: ListID<StatementID>, index: Int) -> StatementID {
        StatementID(word(list.value, index), IDMint())
    }

    @_spi(Testing)
    public subscript(list: ListID<AttributeID>, index: Int) -> AttributeID {
        AttributeID(word(list.value, index), IDMint())
    }

    @_spi(Testing)
    public subscript(list: ListID<Declaration>, index: Int) -> Declaration {
        Declaration(listWord: word(list.value, index), IDMint())
    }

    /// A copy of the list's elements, for sites where C++ copies the Vector.
    @_spi(Testing)
    public func elements<Element: ListElement>(_ list: ListID<Element>) -> [Element] {
        let header = headers[Int(list.value)]
        var result: [Element] = []
        result.reserveCapacity(Int(header.count))
        var index = 0
        while index < Int(header.count) {
            result.append(Element(listWord: pool[Int(header.start) + index], IDMint()))
            index += 1
        }
        return result
    }

    @_spi(Testing)
    public func cursor<Element: ListElement>(_ list: ListID<Element>) -> ListCursor<Element> {
        ListCursor(list: list.value, position: 0, end: headers[Int(list.value)].count)
    }

    @_spi(Testing)
    public func next<Element: ListElement>(_ cursor: inout ListCursor<Element>) -> Element? {
        let list = cursor.list
        let end = cursor.end
        guard let word = nextWord(list, &cursor.position, end) else {
            return nil
        }
        return Element(listWord: word, IDMint())
    }

    @_spi(Testing)
    public func next(_ cursor: inout ListCursor<ExpressionID>) -> ExpressionID? {
        let list = cursor.list
        let end = cursor.end
        guard let word = nextWord(list, &cursor.position, end) else {
            return nil
        }
        return ExpressionID(word, IDMint())
    }

    @_spi(Testing)
    public func next(_ cursor: inout ListCursor<StatementID>) -> StatementID? {
        let list = cursor.list
        let end = cursor.end
        guard let word = nextWord(list, &cursor.position, end) else {
            return nil
        }
        return StatementID(word, IDMint())
    }

    @_spi(Testing)
    public func next(_ cursor: inout ListCursor<AttributeID>) -> AttributeID? {
        let list = cursor.list
        let end = cursor.end
        guard let word = nextWord(list, &cursor.position, end) else {
            return nil
        }
        return AttributeID(word, IDMint())
    }

    @_spi(Testing)
    public func next(_ cursor: inout ListCursor<Declaration>) -> Declaration? {
        let list = cursor.list
        let end = cursor.end
        guard let word = nextWord(list, &cursor.position, end) else {
            return nil
        }
        return Declaration(listWord: word, IDMint())
    }

    /// `next` for a cursor that is not at its end.
    @_spi(Testing)
    public func advance<Element: ListElement>(_ cursor: inout ListCursor<Element>) -> Element {
        let list = cursor.list
        let end = cursor.end
        return Element(listWord: advanceWord(list, &cursor.position, end), IDMint())
    }

    @_spi(Testing)
    public func advance(_ cursor: inout ListCursor<ExpressionID>) -> ExpressionID {
        let list = cursor.list
        let end = cursor.end
        return ExpressionID(advanceWord(list, &cursor.position, end), IDMint())
    }

    @_spi(Testing)
    public func advance(_ cursor: inout ListCursor<StatementID>) -> StatementID {
        let list = cursor.list
        let end = cursor.end
        return StatementID(advanceWord(list, &cursor.position, end), IDMint())
    }

    @_spi(Testing)
    public func advance(_ cursor: inout ListCursor<AttributeID>) -> AttributeID {
        let list = cursor.list
        let end = cursor.end
        return AttributeID(advanceWord(list, &cursor.position, end), IDMint())
    }

    @_spi(Testing)
    public func advance(_ cursor: inout ListCursor<Declaration>) -> Declaration {
        let list = cursor.list
        let end = cursor.end
        return Declaration(listWord: advanceWord(list, &cursor.position, end), IDMint())
    }

    /// C++ `ShaderModule::append(vector, value)`.
    @_spi(Testing)
    public mutating func append<Element: ListElement>(_ list: ListID<Element>, _ value: Element) {
        var header = writableHeader(list.value, extra: 1)
        pool[Int(header.start) + Int(header.count)] = value.listWord
        header.count += 1
        setHeader(list.value, header)
    }

    /// C++ `ShaderModule::insert(vector, position, value)`.
    @_spi(Testing)
    public mutating func insert<Element: ListElement>(_ list: ListID<Element>, _ position: Int, _ value: Element) {
        checkInsertionPosition(list.value, position)
        pool[openGap(list.value, position, 1)] = value.listWord
    }

    /// C++ `ShaderModule::insertVector(vector, position, values)`.
    @_spi(Testing)
    public mutating func insertVector<Element: ListElement>(_ list: ListID<Element>, _ position: Int, _ values: [Element]) {
        checkInsertionPosition(list.value, position)
        guard !values.isEmpty else {
            return
        }
        let gap = openGap(list.value, position, values.count)
        var index = 0
        while index < values.count {
            pool[gap + index] = values[index].listWord
            index += 1
        }
    }

    /// C++ `ShaderModule::remove(vector, position)`.
    @_spi(Testing)
    public mutating func remove<Element: ListElement>(_ list: ListID<Element>, _ position: Int) {
        let count = Int(headers[Int(list.value)].count)
        guard position >= 0, position < count else {
            wgslFatal("list index out of range", cppSite: "Vector.h:815")
        }
        // Dropping the last element writes no storage, so an older list keeps its storage.
        var header = position == count - 1 ? headers[Int(list.value)] : writableHeader(list.value, extra: 0)
        let start = Int(header.start)
        var index = position
        while index < count - 1 {
            pool[start + index] = pool[start + index + 1]
            index += 1
        }
        header.count -= 1
        setHeader(list.value, header)
    }

    /// C++ `ShaderModule::takeLast(vector)`.
    @_spi(Testing)
    @discardableResult
    public mutating func takeLast<Element: ListElement>(_ list: ListID<Element>) -> Element {
        var header = headers[Int(list.value)]
        guard header.count > 0 else {
            wgslFatal("takeLast of an empty list", cppSite: "Vector.h:843")
        }
        header.count -= 1
        let last = pool[Int(header.start) + Int(header.count)]
        setHeader(list.value, header)
        return Element(listWord: last, IDMint())
    }

    /// C++ `ShaderModule::clear(vector)`.
    @_spi(Testing)
    public mutating func clear<Element: ListElement>(_ list: ListID<Element>) {
        var header = headers[Int(list.value)]
        header.count = 0
        setHeader(list.value, header)
    }

    /// `vector[index] = value` on a node's list.
    @_spi(Testing)
    public mutating func set<Element: ListElement>(_ list: ListID<Element>, _ index: Int, _ value: Element) {
        guard index >= 0, index < Int(headers[Int(list.value)].count) else {
            wgslFatal("list index out of range", cppSite: "Vector.h:815")
        }
        let header = writableHeader(list.value, extra: 0)
        pool[Int(header.start) + index] = value.listWord
    }

    @_spi(Testing)
    public mutating func openScope() -> Mark {
        let mark = Mark(listCount: headers.count, undoCount: undo.count, floor: floor, poolCount: pool.count, poolFloor: poolFloor)
        floor = UInt32(truncatingIfNeeded: headers.count)
        poolFloor = UInt32(truncatingIfNeeded: pool.count)
        return mark
    }

    /// Restores the logged headers, newest first, then drops the lists and pool words added since `mark`.
    @_spi(Testing)
    public mutating func rollback(to mark: Mark) {
        guard mark.listCount <= headers.count, mark.undoCount <= undo.count, mark.poolCount <= pool.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        var undoIndex = undo.count
        while undoIndex > mark.undoCount {
            undoIndex -= 1
            let entry = undo[undoIndex]
            headers[Int(entry.list)] = entry.header
        }
        undo.removeSubrange(mark.undoCount...)
        headers.removeSubrange(mark.listCount...)
        pool.removeSubrange(mark.poolCount...)
        floor = mark.floor
        poolFloor = mark.poolFloor
    }

    @_spi(Testing)
    public func snapshot() -> Snapshot {
        Snapshot(headers: headers, pool: pool)
    }

    private func word(_ list: UInt32, _ index: Int) -> UInt32 {
        let header = headers[Int(list)]
        guard index >= 0, index < Int(header.count) else {
            wgslFatal("list index out of range", cppSite: "Vector.h:815")
        }
        return pool[Int(header.start) + index]
    }

    private func nextWord(_ list: UInt32, _ position: inout UInt32, _ end: UInt32) -> UInt32? {
        guard position < end else {
            return nil
        }
        let header = headers[Int(list)]
        guard position < header.count else {
            // DEV-18: C++ range-for reads past the end of a Vector that shrank during the loop (UB).
            wgslFatal("list shrank below an active ListCursor", cppSite: "Vector.h:832")
        }
        let word = pool[Int(header.start) + Int(position)]
        position += 1
        return word
    }

    private func advanceWord(_ list: UInt32, _ position: inout UInt32, _ end: UInt32) -> UInt32 {
        guard position < end else {
            wgslFatal("advance of a ListCursor at its end", cppSite: "Vector.h:832")
        }
        let header = headers[Int(list)]
        guard position < header.count else {
            // DEV-18: C++ range-for reads past the end of a Vector that shrank during the loop (UB).
            wgslFatal("list shrank below an active ListCursor", cppSite: "Vector.h:832")
        }
        let word = pool[Int(header.start) + Int(position)]
        position += 1
        return word
    }

    private func checkInsertionPosition(_ list: UInt32, _ position: Int) {
        guard position >= 0, position <= Int(headers[Int(list)].count) else {
            wgslFatal("list insertion position out of range", cppSite: "Vector.h:1711")
        }
    }

    // Makes room for `length` words at `position`, shifting the tail up, and returns the pool index of the gap.
    private mutating func openGap(_ list: UInt32, _ position: Int, _ length: Int) -> Int {
        var header = writableHeader(list, extra: length)
        let start = Int(header.start)
        let count = Int(header.count)
        if count - position > 32 {
            // A long tail moves in bulk (an insertion at the front of a long body).
            let tail = ContiguousArray(pool[(start + position)..<(start + count)])
            pool.replaceSubrange((start + position + length)..<(start + count + length), with: tail)
        } else {
            var index = count - 1
            while index >= position {
                pool[start + index + length] = pool[start + index]
                index -= 1
            }
        }
        header.count += UInt32(truncatingIfNeeded: length)
        setHeader(list, header)
        return start + position
    }

    // A header whose storage may be written in place and has room for `extra` more words.
    private mutating func writableHeader(_ list: UInt32, extra: Int) -> ListHeader {
        var header = headers[Int(list)]
        let needed = Int(header.count) + extra
        let ownsStorage = header.start >= poolFloor
        if ownsStorage && needed <= Int(header.capacity) {
            return header
        }
        if ownsStorage && Int(header.start) + Int(header.capacity) == pool.count {
            let grow = max(needed - Int(header.capacity), Int(header.capacity))
            _ = poolEnd(adding: grow)
            pool.append(contentsOf: repeatElement(0, count: grow))
            header.capacity += UInt32(truncatingIfNeeded: grow)
            setHeader(list, header)
            return header
        }
        let capacity = max(needed, Int(header.count) * 2, 4)
        let start = poolEnd(adding: capacity)
        var index = 0
        while index < Int(header.count) {
            pool.append(pool[Int(header.start) + index])
            index += 1
        }
        pool.append(contentsOf: repeatElement(0, count: capacity - Int(header.count)))
        header = ListHeader(start: start, count: header.count, capacity: UInt32(truncatingIfNeeded: capacity))
        setHeader(list, header)
        return header
    }

    private mutating func setHeader(_ list: UInt32, _ header: ListHeader) {
        if list < floor {
            undo.append((list, headers[Int(list)]))
        }
        headers[Int(list)] = header
    }

    private func poolEnd(adding words: Int) -> UInt32 {
        guard words <= Int(UInt32.max) - pool.count else {
            wgslFatal("list storage overflow", cppSite: "Vector.h:626")
        }
        return UInt32(truncatingIfNeeded: pool.count)
    }

    private mutating func appendHeader(_ header: ListHeader) -> UInt32 {
        guard headers.count < Int(UInt32.max) else {
            wgslFatal("arena overflow", cppSite: "ASTBuilder.h:64")
        }
        headers.append(header)
        return UInt32(truncatingIfNeeded: headers.count - 1)
    }
}

/// `Expression::m_constantValue` of every expression: a 4-byte slot per ExpressionID plus value pools.
///
/// Each entry is owned by exactly one slot (in C++ the optional lives in the node), so copies copy the value, never the
/// index. evaluate()'s writes to nodes older than the open scope go to the sticky region, which rollback does not
/// truncate (WGSL.cpp:361, `const_cast<AST::Expression&>(expression).setConstantValue(*result)`); an undo that restores
/// an older slot, or the truncation of a slot, frees its sticky entry, so repeated pipelines do not grow the table.
@_spi(Testing)
public struct ConstantTable: ~Copyable {
    // Per ExpressionID, dense up to the highest written ID: 0 = std::nullopt, else an index into `values`, or into `sticky`
    // with stickyBit set.
    private var slots: [UInt32] = []
    // The scoped region, truncated at rollback; values[0] is unused.
    private var values: [ConstantValue] = [.bool(false)]
    private var sticky: [ConstantValue] = []
    private var freeSticky: [UInt32] = []
    private var undo: [(expression: UInt32, slot: UInt32)] = []
    // The expression count when the innermost scope opened.
    private var floor: UInt32 = 0
    private var valuesFloor: UInt32 = 1

    private static var stickyBit: UInt32 { 1 << 31 }

    /// The state `openScope` saves and `rollback(to:)` restores.
    @_spi(Testing)
    public struct Mark: BitwiseCopyable {
        fileprivate let expressionCount: Int
        fileprivate let undoCount: Int
        fileprivate let valuesCount: Int
        fileprivate let floor: UInt32
        fileprivate let valuesFloor: UInt32
    }

    @_spi(Testing)
    public init() {}

    /// Sticky entries allocated, live or free.
    @_spi(Testing)
    public var stickyCount: Int { sticky.count }

    /// Scoped entries, including the unused one.
    @_spi(Testing)
    public var valuesCount: Int { values.count }

    /// TypeCheck's conversion of an expression's value in place (C++ `auto& value = expression.m_constantValue`).
    ///
    /// The value is not copied; `body` returns false to remove it. Returns false when the expression has no value. Traps like
    /// `set` on a node that predates the open scope.
    @_spi(Testing)
    @inline(__always)
    public mutating func modifyValue(
        _ expression: ExpressionID,
        _ types: borrowing TypeStore,
        _ body: (inout ConstantValue, borrowing TypeStore) -> Bool
    ) -> Bool {
        let raw = expression.value
        guard raw >= floor else {
            wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
        }
        let current = slot(raw)
        if current == 0 {
            return false
        }
        let keep: Bool
        if current & ConstantTable.stickyBit != 0 {
            keep = body(&sticky[Int(current & ~ConstantTable.stickyBit)], types)
        } else if current >= valuesFloor {
            keep = body(&values[Int(current)], types)
        } else {
            // An outer scope's entry stays intact: the result goes to a fresh scoped entry, as `store` does.
            var value = values[Int(current)]
            keep = body(&value, types)
            if keep {
                setSlot(raw, appendScoped(value))
            }
        }
        if !keep {
            store(nil, raw)
        }
        return true
    }

    /// Makes the slots of the first `expressionCount` expressions exist, and room for a value for each, so that setting their
    /// values does not grow the table.
    @_spi(Testing)
    public mutating func reserveSlots(_ expressionCount: Int) {
        if expressionCount > slots.count {
            slots.reserveCapacity(expressionCount)
            slots.append(contentsOf: repeatElement(0, count: expressionCount - slots.count))
        }
        values.reserveCapacity(expressionCount + 1)
    }

    /// `value(expression) != nil` without copying the value.
    @_spi(Testing)
    public func hasValue(_ expression: ExpressionID) -> Bool {
        slot(expression.value) != 0
    }

    @_spi(Testing)
    public func value(_ expression: ExpressionID) -> ConstantValue? {
        let current = slot(expression.value)
        if current == 0 {
            return nil
        }
        return current & ConstantTable.stickyBit != 0 ? sticky[Int(current & ~ConstantTable.stickyBit)] : values[Int(current)]
    }

    /// TypeCheck's write, and writes to nodes created inside the open scope; traps on an older node (floor rule).
    @_spi(Testing)
    public mutating func set(_ value: consuming ConstantValue?, for expression: ExpressionID) {
        guard expression.value >= floor else {
            wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
        }
        store(value, expression.value)
    }

    /// `set` of a value, inlined into TypeCheck's per-expression writes.
    @_spi(Testing)
    @inline(__always)
    public mutating func set(_ value: consuming ConstantValue, for expression: ExpressionID) {
        guard expression.value >= floor else {
            ConstantTable.writeBelowFloor()
        }
        storeValue(value, expression.value)
    }

    /// replace() and construct(copyOf:): logs the old slot when the node predates the open scope, then points the slot at a
    /// fresh scoped entry (the logged entry stays intact for the undo).
    @_spi(Testing)
    public mutating func setLogged(_ value: ConstantValue?, for expression: ExpressionID) {
        let raw = expression.value
        guard raw < floor else {
            store(value, raw)
            return
        }
        undo.append((raw, slot(raw)))
        if let value {
            growSlots(through: raw)
            slots[Int(raw)] = appendScoped(value)
        } else {
            setSlot(raw, 0)
        }
    }

    /// evaluate()'s cache (WGSL.cpp:361), never logged.
    ///
    /// A node at or above the floor (any node when no scope is open) overwrites its own entry in place; an older node
    /// writes its sticky entry in place or takes a new one, which survives rollback.
    @_spi(Testing)
    public mutating func setSurvivingRollback(_ value: ConstantValue, for expression: ExpressionID) {
        let raw = expression.value
        guard raw < floor else {
            store(value, raw)
            return
        }
        let current = slot(raw)
        if current & ConstantTable.stickyBit != 0 {
            sticky[Int(current & ~ConstantTable.stickyBit)] = value
            return
        }
        setSlot(raw, ConstantTable.stickyBit | allocateSticky(value))
    }

    @_spi(Testing)
    public mutating func openScope(expressionCount: Int) -> Mark {
        let mark = Mark(
            expressionCount: expressionCount,
            undoCount: undo.count,
            valuesCount: values.count,
            floor: floor,
            valuesFloor: valuesFloor
        )
        floor = UInt32(truncatingIfNeeded: expressionCount)
        valuesFloor = UInt32(truncatingIfNeeded: values.count)
        return mark
    }

    /// Pops the undo log, then truncates the slots of the expressions created since `mark` and the scoped region.
    @_spi(Testing)
    public mutating func rollback(to mark: Mark) {
        guard mark.undoCount <= undo.count, mark.valuesCount <= values.count else {
            wgslFatal("rollback to a mark that is not on the scope stack", cppSite: "CompilationScope.cpp:54")
        }
        var undoIndex = undo.count
        while undoIndex > mark.undoCount {
            undoIndex -= 1
            let entry = undo[undoIndex]
            release(slot(entry.expression))
            setSlot(entry.expression, entry.slot)
        }
        undo.removeSubrange(mark.undoCount...)
        if slots.count > mark.expressionCount {
            var index = mark.expressionCount
            while index < slots.count {
                release(slots[index])
                index += 1
            }
            slots.removeSubrange(mark.expressionCount...)
        }
        values.removeSubrange(mark.valuesCount...)
        floor = mark.floor
        valuesFloor = mark.valuesFloor
    }

    /// The constant value of each of the first `expressionCount` expressions.
    @_spi(Testing)
    public func snapshot(expressionCount: Int) -> [ConstantValue?] {
        var result: [ConstantValue?] = []
        result.reserveCapacity(expressionCount)
        var raw: UInt32 = 0
        while Int(raw) < expressionCount {
            result.append(value(ExpressionID(raw, IDMint())))
            raw += 1
        }
        return result
    }

    private func slot(_ expression: UInt32) -> UInt32 {
        Int(expression) < slots.count ? slots[Int(expression)] : 0
    }

    private mutating func growSlots(through expression: UInt32) {
        while Int(expression) >= slots.count {
            slots.append(0)
        }
    }

    private mutating func setSlot(_ expression: UInt32, _ slot: UInt32) {
        if Int(expression) >= slots.count {
            if slot == 0 {
                return
            }
            growSlots(through: expression)
        }
        slots[Int(expression)] = slot
    }

    private mutating func appendScoped(_ value: consuming ConstantValue) -> UInt32 {
        guard values.count < Int(ConstantTable.stickyBit) else {
            wgslFatal("constant table overflow", cppSite: "ASTBuilder.h:64")
        }
        values.append(value)
        return UInt32(truncatingIfNeeded: values.count - 1)
    }

    private mutating func allocateSticky(_ value: ConstantValue) -> UInt32 {
        if let entry = freeSticky.popLast() {
            sticky[Int(entry)] = value
            return entry
        }
        guard sticky.count < Int(ConstantTable.stickyBit) else {
            wgslFatal("constant table overflow", cppSite: "ASTBuilder.h:64")
        }
        sticky.append(value)
        return UInt32(truncatingIfNeeded: sticky.count - 1)
    }

    private mutating func release(_ slot: UInt32) {
        guard slot & ConstantTable.stickyBit != 0 else {
            return
        }
        let entry = slot & ~ConstantTable.stickyBit
        sticky[Int(entry)] = .bool(false)
        freeSticky.append(entry)
    }

    // A write by the node's own level: no scope is open, or the node was created inside the open scope.
    private mutating func store(_ value: consuming ConstantValue?, _ expression: UInt32) {
        guard let value else {
            release(slot(expression))
            setSlot(expression, 0)
            return
        }
        storeValue(value, expression)
    }

    @inline(__always)
    private mutating func storeValue(_ value: consuming ConstantValue, _ expression: UInt32) {
        let current = slot(expression)
        if current == 0 && Int(expression) < slots.count && values.count < Int(ConstantTable.stickyBit) {
            values.append(value)
            slots[Int(expression)] = UInt32(truncatingIfNeeded: values.count - 1)
            return
        }
        if current & ConstantTable.stickyBit != 0 {
            sticky[Int(current & ~ConstantTable.stickyBit)] = value
            return
        }
        if current != 0 && current >= valuesFloor {
            values[Int(current)] = value
            return
        }
        setSlot(expression, appendScoped(value))
    }

    @inline(never)
    private static func writeBelowFloor() -> Never {
        wgslFatal("unlogged write to a node that predates the open CompilationScope", cppSite: "CompilationScope.cpp:50")
    }
}

/// C++ `HashMap<Node*, V>` keyed by IDs, stored densely by ID.
///
/// Like `LookupMap` (the same HashMap-named methods) it has no `Sequence` conformance, so iterating it does not compile.
@_spi(Testing)
public struct SideTable<ID: ArenaID, Value> {
    private var values: [Value?] = []
    private var storedCount = 0

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { storedCount }

    @_spi(Testing)
    public var isEmpty: Bool { storedCount == 0 }

    /// HashMap::add: inserts when the key is absent and never overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ id: ID, _ value: Value) -> Bool {
        guard !contains(id) else {
            return false
        }
        grow(through: id)
        values[id.index] = value
        storedCount += 1
        return true
    }

    /// HashMap::set: inserts or overwrites; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func set(_ id: ID, _ value: Value) -> Bool {
        let isNewEntry = !contains(id)
        grow(through: id)
        values[id.index] = value
        if isNewEntry {
            storedCount += 1
        }
        return isNewEntry
    }

    /// HashMap::get: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public func get(_ id: ID) -> Value? {
        id.index < values.count ? values[id.index] : nil
    }

    /// `map.find(key)`: nil where C++ gets `map.end()`.
    @_spi(Testing)
    public func find(_ id: ID) -> Value? {
        get(id)
    }

    @_spi(Testing)
    public func contains(_ id: ID) -> Bool {
        id.index < values.count && values[id.index] != nil
    }

    /// HashMap::remove; returns whether the key was present.
    @_spi(Testing)
    @discardableResult
    public mutating func remove(_ id: ID) -> Bool {
        take(id) != nil
    }

    /// HashMap::take: C++ returns the mapped type's empty value for a missing key; write it out at the call site.
    @_spi(Testing)
    public mutating func take(_ id: ID) -> Value? {
        guard contains(id) else {
            return nil
        }
        let value = values[id.index]
        values[id.index] = nil
        storedCount -= 1
        return value
    }

    /// HashMap::ensure: calls `makeValue` only when the key is absent; returns the stored value.
    @_spi(Testing)
    public mutating func ensure<E: Error>(_ id: ID, _ makeValue: () throws(E) -> Value) throws(E) -> Value {
        if let value = get(id) {
            return value
        }
        let value = try makeValue()
        set(id, value)
        return value
    }

    /// `map.find(key)->value` mutated in place; nil (and `body` is not called) when the key is absent.
    @_spi(Testing)
    @discardableResult
    public mutating func modify<R>(_ id: ID, _ body: (inout Value) -> R) -> R? {
        guard contains(id), var value = values[id.index] else {
            return nil
        }
        values[id.index] = nil
        let result = body(&value)
        values[id.index] = value
        return result
    }

    /// `map.add(key, value).iterator->value` (or `ensure`) mutated in place.
    @_spi(Testing)
    @discardableResult
    public mutating func modify<R>(_ id: ID, default makeValue: @autoclosure () -> Value, _ body: (inout Value) -> R) -> R {
        var value = take(id) ?? makeValue()
        let result = body(&value)
        set(id, value)
        return result
    }

    @_spi(Testing)
    public mutating func clear() {
        values.removeAll()
        storedCount = 0
    }

    /// Room for every ID below `idCount` without regrowing.
    @_spi(Testing)
    public mutating func reserveInitialCapacity(_ idCount: Int) {
        values.reserveCapacity(idCount)
    }

    private mutating func grow(through id: ID) {
        if id.index == values.count {
            // The next ID (a pass numbering the nodes it creates): one append, not the generic one of a run.
            values.append(nil)
        } else if id.index > values.count {
            values.append(contentsOf: repeatElement(nil, count: id.index - values.count + 1))
        }
    }
}

extension SideTable: Equatable where Value: Equatable {
    /// Equal entries for every ID: absent entries and trailing storage do not matter.
    @_spi(Testing)
    public static func == (lhs: SideTable, rhs: SideTable) -> Bool {
        guard lhs.storedCount == rhs.storedCount else {
            return false
        }
        let count = max(lhs.values.count, rhs.values.count)
        var index = 0
        while index < count {
            let left = index < lhs.values.count ? lhs.values[index] : nil
            let right = index < rhs.values.count ? rhs.values[index] : nil
            if left != right {
                return false
            }
            index += 1
        }
        return true
    }
}

extension SideTable: Sendable where Value: Sendable {}

/// C++ `HashSet<Node*>` keyed by IDs, as a bitset.
///
/// It has no `Sequence` conformance; `forEachInCreationOrder` is only for sites whose C++ pointer-hash order is
/// canonicalised (iterate an `OrderedIDSet` everywhere else).
@_spi(Testing)
public struct IDSet<ID: ArenaID>: Equatable, Sendable {
    private var words: [UInt64] = []
    private var storedCount = 0

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var count: Int { storedCount }

    @_spi(Testing)
    public var isEmpty: Bool { storedCount == 0 }

    /// HashSet::add; returns isNewEntry.
    @_spi(Testing)
    @discardableResult
    public mutating func add(_ id: ID) -> Bool {
        let word = id.index >> 6
        if word >= words.count {
            words.append(contentsOf: repeatElement(0, count: word - words.count + 1))
        }
        let bit: UInt64 = 1 << UInt64(id.index & 63)
        guard words[word] & bit == 0 else {
            return false
        }
        words[word] |= bit
        storedCount += 1
        return true
    }

    /// HashSet::addAll.
    @_spi(Testing)
    public mutating func addAll(_ other: IDSet) {
        if other.words.count > words.count {
            words.append(contentsOf: repeatElement(0, count: other.words.count - words.count))
        }
        var index = 0
        while index < other.words.count {
            storedCount += (other.words[index] & ~words[index]).nonzeroBitCount
            words[index] |= other.words[index]
            index += 1
        }
    }

    @_spi(Testing)
    public func contains(_ id: ID) -> Bool {
        let word = id.index >> 6
        return word < words.count && words[word] & (1 << UInt64(id.index & 63)) != 0
    }

    /// HashSet::remove; returns whether the ID was present.
    @_spi(Testing)
    @discardableResult
    public mutating func remove(_ id: ID) -> Bool {
        guard contains(id) else {
            return false
        }
        words[id.index >> 6] &= ~(1 << UInt64(id.index & 63))
        storedCount -= 1
        return true
    }

    @_spi(Testing)
    public mutating func clear() {
        words.removeAll()
        storedCount = 0
    }

    @_spi(Testing)
    public func forEachInCreationOrder<E: Error>(_ body: (ID) throws(E) -> Void) throws(E) {
        var index = 0
        while index < words.count {
            var bits = words[index]
            while bits != 0 {
                let bit = bits.trailingZeroBitCount
                try body(ID(UInt32(truncatingIfNeeded: index << 6 | bit), IDMint()))
                bits &= bits &- 1
            }
            index += 1
        }
    }

    @_spi(Testing)
    public static func == (lhs: IDSet, rhs: IDSet) -> Bool {
        guard lhs.storedCount == rhs.storedCount else {
            return false
        }
        var index = 0
        while index < min(lhs.words.count, rhs.words.count) {
            if lhs.words[index] != rhs.words[index] {
                return false
            }
            index += 1
        }
        return true
    }
}

/// C++ `ListHashSet<Node*>` over IDs, iterating in insertion order: the iterable identity set.
@_spi(Testing)
public typealias OrderedIDSet<ID: ArenaID> = OrderedSet<ID>
