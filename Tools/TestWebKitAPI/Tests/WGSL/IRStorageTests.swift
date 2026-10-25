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

private protocol ArenaUnderTest: ~Copyable {
    associatedtype ID: ArenaID
    associatedtype Element: Equatable
    associatedtype Mark

    init()
    var count: Int { get }
    var undoCount: Int { get }
    var ids: IDRange<ID> { get }
    mutating func append(_ element: Element) -> ID
    func contains(_ id: ID) -> Bool
    subscript(_ id: ID) -> Element { get set }
    mutating func overwrite(_ id: ID, with element: Element)
    mutating func update<Result, E: Error>(_ id: ID, _ body: (inout Element) throws(E) -> Result) throws(E) -> Result
    mutating func openScope() -> Mark
    mutating func rollback(to mark: Mark)
    func snapshot() -> [Element]
}

extension Arena: ArenaUnderTest where Element: Equatable {}
extension ExpressionArena: ArenaUnderTest {}
extension StatementArena: ArenaUnderTest {}

private func testSpan(_ n: UInt32) -> SourceSpan {
    SourceSpan(line: n, lineOffset: n, offset: n, length: n)
}

private func expressionNode(_ n: UInt32) -> ExpressionNode {
    ExpressionNode(kind: .unsigned32Literal(Unsigned32Literal(value: n)), span: testSpan(n))
}

private func statementNode(_ n: UInt32) -> StatementNode {
    StatementNode(kind: .breakStatement(BreakStatement()), span: testSpan(n))
}

// Appends, logged and unlogged writes, nested scopes and rollback, with the same expectations for every arena type.
private func exerciseArena<A: ArenaUnderTest & ~Copyable>(_: A.Type, _ make: (UInt32) -> A.Element) {
    var arena = A()
    let first = arena.append(make(0))
    let second = arena.append(make(1))
    let third = arena.append(make(2))
    #expect([first.raw, second.raw, third.raw] == [0, 1, 2])
    #expect(Array(arena.ids) == [first, second, third])
    #expect(arena.contains(third) == true)

    // Outside any scope every write is plain, and nothing is logged.
    arena[first] = make(10)
    arena.overwrite(second, with: make(11))
    arena.update(third) { $0 = make(12) }
    #expect(arena.undoCount == 0)
    let beforeScope = arena.snapshot()
    #expect(beforeScope == [make(10), make(11), make(12)])

    let outer = arena.openScope()
    let fourth = arena.append(make(3))
    #expect(fourth.raw == 3)
    arena[fourth] = make(13)
    arena.overwrite(first, with: make(20))
    arena.update(second) { $0 = make(21) }
    let result = arena.update(second) { element in
        element = make(22)
        return 7
    }
    #expect(result == 7)
    #expect(arena.undoCount == 3)
    arena.overwrite(fourth, with: make(23))
    #expect(arena.undoCount == 3)
    let outerState = arena.snapshot()
    #expect(outerState == [make(20), make(22), make(12), make(23)])

    let inner = arena.openScope()
    arena.overwrite(fourth, with: make(33))
    arena.overwrite(first, with: make(30))
    let fifth = arena.append(make(4))
    arena[fifth] = make(34)
    #expect(arena.undoCount == 5)
    arena.rollback(to: inner)
    #expect(arena.snapshot() == outerState)
    #expect(arena.count == 4)
    #expect(arena.undoCount == 3)

    arena.rollback(to: outer)
    #expect(arena.snapshot() == beforeScope)
    #expect(arena.count == 3)
    #expect(arena.undoCount == 0)
    #expect(arena.contains(fourth) == false)

    let recycled = arena.append(make(5))
    #expect(recycled == fourth)
    #expect(arena[recycled] == make(5))
}

// A list's C++ Vector contents, edited through the ShaderModule helpers.
private struct ListModel {
    var elements: [ExpressionID]

    mutating func apply(_ operation: Int, _ value: ExpressionID, _ list: ListID<ExpressionID>, _ lists: inout ListArena) {
        let count = elements.count
        let position = Int(value.raw) % (count + 1)
        if operation == 1 {
            lists.insert(list, position, value)
            elements.insert(value, at: position)
        } else if operation == 2 {
            let values = Array(repeating: value, count: Int(value.raw) % 3 + 1)
            lists.insertVector(list, position, values)
            elements.insert(contentsOf: values, at: position)
        } else if operation == 3 && count > 0 {
            lists.remove(list, position % count)
            elements.remove(at: position % count)
        } else if operation == 4 && count > 0 {
            #expect(lists.takeLast(list) == elements.removeLast())
        } else if operation == 5 && count > 0 {
            lists.set(list, position % count, value)
            elements[position % count] = value
        } else if operation == 6 && count > 8 {
            lists.clear(list)
            elements.removeAll()
        } else {
            lists.append(list, value)
            elements.append(value)
        }
    }
}

private struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(below bound: Int) -> Int {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }
}

private func readAll<Element: ListElement>(_ lists: borrowing ListArena, _ list: ListID<Element>) -> [Element] {
    var result: [Element] = []
    var index = 0
    while index < lists.count(list) {
        result.append(lists[list, index])
        index += 1
    }
    return result
}

@Suite
struct WGSLIRStorageTests {
    @Test
    func idsAreFourBytes() {
        #expect(MemoryLayout<ExpressionID>.size == 4)
        #expect(MemoryLayout<ListID<AttributeID>>.size == 4)
        #expect(MemoryLayout<ListHeader>.size == 12)
        #expect(MemoryLayout<ListCursor<StatementID>>.size == 12)
    }

    @Test
    func fixedTypeIDsAreTheTypeStoreConstructorOrder() {
        let fixed = [
            FixedTypeID.abstractInt, FixedTypeID.abstractFloat, FixedTypeID.void, FixedTypeID.bool, FixedTypeID.i32,
            FixedTypeID.u32, FixedTypeID.f32, FixedTypeID.f16, FixedTypeID.sampler, FixedTypeID.samplerComparison,
            FixedTypeID.textureExternal, FixedTypeID.accessMode, FixedTypeID.texelFormat, FixedTypeID.addressSpace,
            FixedTypeID.textureDepth2d, FixedTypeID.textureDepth2dArray, FixedTypeID.textureDepthCube,
            FixedTypeID.textureDepthCubeArray, FixedTypeID.textureDepthMultisampled2d, FixedTypeID.atomicI32,
            FixedTypeID.atomicU32,
        ]
        #expect(fixed.map(\.raw) == Array(0..<FixedTypeID.count))
        var types = Arena<TypeID, UInt32>()
        var index: UInt32 = 0
        while index < FixedTypeID.count {
            #expect(types.append(index) == fixed[Int(index)])
            index += 1
        }
    }

    @Test
    func arenaBehaviour() {
        exerciseArena(Arena<FunctionID, UInt32>.self) { $0 }
        exerciseArena(Arena<IdentifierID, [UInt32]>.self) { [$0, $0] }
        exerciseArena(ExpressionArena.self, expressionNode)
        exerciseArena(StatementArena.self, statementNode)
    }

    @Test
    func loggedWritesRestoreExactly() {
        var arena = ExpressionArena()
        var random = TestRandom(seed: 1)
        var index: UInt32 = 0
        while index < 200 {
            _ = arena.append(expressionNode(index))
            index += 1
        }
        let original = arena.snapshot()
        let ids = Array(arena.ids)
        let mark = arena.openScope()
        var created: [ExpressionID] = []
        var step: UInt32 = 0
        while step < 2000 {
            let id = ids[random.next(below: ids.count)]
            let operation = random.next(below: 4)
            if operation == 0 {
                arena.overwrite(id, with: expressionNode(1000 + step))
            } else if operation == 1 {
                arena.update(id) { $0.span = testSpan(2000 + step) }
            } else if operation == 2 {
                created.append(arena.append(expressionNode(3000 + step)))
            } else if let fresh = created.last {
                arena[fresh] = expressionNode(4000 + step)
            }
            step += 1
        }
        #expect(arena.snapshot() != original)
        arena.rollback(to: mark)
        #expect(arena.snapshot() == original)
        #expect(arena.undoCount == 0)
    }

    @Test
    func listHelpersMatchTheCppVectorHelpers() {
        var expressions = Arena<ExpressionID, UInt32>()
        var values: [ExpressionID] = []
        var index: UInt32 = 0
        while index < 64 {
            values.append(expressions.append(index))
            index += 1
        }
        var random = TestRandom(seed: 2)
        var lists = ListArena()
        var models: [ListModel] = []
        var ids: [ListID<ExpressionID>] = []
        var listIndex = 0
        while listIndex < 12 {
            let initial = Array(values.prefix(listIndex))
            ids.append(listIndex % 3 == 0 ? lists.makeEmpty(ExpressionID.self) : lists.make(initial))
            models.append(ListModel(elements: listIndex % 3 == 0 ? [] : initial))
            listIndex += 1
        }

        func runPhase(_ steps: Int, _ lists: inout ListArena, _ models: inout [ListModel]) {
            var step = 0
            while step < steps {
                let list = random.next(below: ids.count)
                models[list].apply(random.next(below: 7), values[random.next(below: values.count)], ids[list], &lists)
                step += 1
            }
        }

        func checkAll(_ lists: borrowing ListArena, _ models: [ListModel]) {
            var list = 0
            while list < ids.count {
                #expect(lists.count(ids[list]) == models[list].elements.count)
                #expect(lists.elements(ids[list]) == models[list].elements)
                #expect(readAll(lists, ids[list]) == models[list].elements)
                list += 1
            }
        }

        runPhase(500, &lists, &models)
        checkAll(lists, models)
        #expect(lists.undoCount == 0)

        let beforeScope = lists.snapshot()
        let savedModels = models
        let outer = lists.openScope()
        runPhase(500, &lists, &models)
        checkAll(lists, models)
        let outerSnapshot = lists.snapshot()
        let outerModels = models
        let inner = lists.openScope()
        runPhase(500, &lists, &models)
        checkAll(lists, models)
        lists.rollback(to: inner)
        #expect(lists.snapshot() == outerSnapshot)
        checkAll(lists, outerModels)
        lists.rollback(to: outer)
        #expect(lists.snapshot() == beforeScope)
        checkAll(lists, savedModels)
        #expect(lists.undoCount == 0)
    }

    @Test
    func listsCreatedInsideAScopeAreDropped() {
        var expressions = Arena<ExpressionID, UInt32>()
        let value = expressions.append(0)
        var lists = ListArena()
        let old = lists.make([value])
        let before = lists.snapshot()
        let mark = lists.openScope()
        let fresh = lists.make([value, value])
        lists.append(fresh, value)
        #expect(lists.count(fresh) == 3)
        #expect(lists.listCount == 2)
        lists.rollback(to: mark)
        #expect(lists.listCount == 1)
        #expect(lists.snapshot() == before)
        #expect(lists.elements(old) == [value])
    }

    @Test
    func olderStorageIsNeverWrittenInsideAScope() {
        var expressions = Arena<ExpressionID, UInt32>()
        let a = expressions.append(0)
        let b = expressions.append(1)
        var lists = ListArena()
        let list = lists.make([a, b])
        let header = lists.header(list)
        let mark = lists.openScope()
        lists.set(list, 0, b)
        #expect(lists.header(list).start != header.start)
        #expect(lists.elements(list) == [b, b])
        lists.takeLast(list)
        lists.clear(list)
        #expect(lists.count(list) == 0)
        lists.rollback(to: mark)
        #expect(lists.header(list) == header)
        #expect(lists.elements(list) == [a, b])

        // Shrinking at the end writes no storage, so it does not relocate.
        let shrink = lists.openScope()
        lists.remove(list, 1)
        lists.takeLast(list)
        #expect(lists.header(list).start == header.start)
        lists.rollback(to: shrink)
        #expect(lists.elements(list) == [a, b])
    }

    @Test
    func declarationListsRoundTrip() {
        var functions = Arena<FunctionID, UInt32>()
        var variables = Arena<VariableID, UInt32>()
        var structures = Arena<StructureID, UInt32>()
        var typeAliases = Arena<TypeAliasID, UInt32>()
        var constAsserts = Arena<ConstAssertID, UInt32>()
        var declarations: [Declaration] = []
        var index: UInt32 = 0
        while index < 3 {
            declarations.append(.function(functions.append(index)))
            declarations.append(.variable(variables.append(index)))
            declarations.append(.structure(structures.append(index)))
            declarations.append(.typeAlias(typeAliases.append(index)))
            declarations.append(.constAssert(constAsserts.append(index)))
            index += 1
        }
        var lists = ListArena()
        let list = lists.make(declarations)
        #expect(lists.elements(list) == declarations)
        #expect(lists[list, 7] == declarations[7])
        var cursor = lists.cursor(list)
        var visited: [Declaration] = []
        while let declaration = lists.next(&cursor) {
            visited.append(declaration)
        }
        #expect(visited == declarations)
    }

    @Test
    func cursorStopsAtTheCountWhenTheLoopStarted() {
        var expressions = Arena<ExpressionID, UInt32>()
        let ten = expressions.append(10)
        let twenty = expressions.append(20)
        let thirty = expressions.append(30)
        let forty = expressions.append(40)
        let five = expressions.append(5)
        var lists = ListArena()

        // Appends during the loop are not visited.
        let appended = lists.make([ten, twenty])
        var cursor = lists.cursor(appended)
        var visited: [ExpressionID] = []
        while let element = lists.next(&cursor) {
            visited.append(element)
            lists.append(appended, forty)
        }
        #expect(visited == [ten, twenty])
        #expect(lists.elements(appended) == [ten, twenty, forty, forty])

        // An insertion in front shifts the remaining elements, as in a C++ Vector that does not reallocate.
        let inserted = lists.make([ten, twenty, thirty])
        cursor = lists.cursor(inserted)
        visited = []
        while let element = lists.next(&cursor) {
            visited.append(element)
            if element == ten && visited.count == 1 {
                lists.insert(inserted, 0, five)
            }
        }
        #expect(visited == [ten, ten, twenty])

        // A removal shifts too; the list keeps at least its starting count.
        let removed = lists.make([ten, twenty, thirty])
        cursor = lists.cursor(removed)
        visited = []
        while let element = lists.next(&cursor) {
            visited.append(element)
            if visited.count == 1 {
                lists.remove(removed, 0)
                lists.append(removed, forty)
            }
        }
        #expect(visited == [ten, thirty, forty])

        // Inside a scope the first edit relocates the list; the cursor reads the new storage.
        let relocated = lists.make([ten, twenty, thirty])
        let mark = lists.openScope()
        cursor = lists.cursor(relocated)
        visited = []
        while let element = lists.next(&cursor) {
            visited.append(element)
            if visited.count == 1 {
                lists.set(relocated, 2, forty)
            }
        }
        #expect(visited == [ten, twenty, forty])
        lists.rollback(to: mark)
        #expect(lists.elements(relocated) == [ten, twenty, thirty])
    }

    // The default traversal's form of the loop (ASTVisitor.swift): `isAtEnd` and `advance` visit what `next` visits.
    @Test
    func advanceVisitsWhatNextVisits() {
        var expressions = Arena<ExpressionID, UInt32>()
        let ten = expressions.append(10)
        let twenty = expressions.append(20)
        let forty = expressions.append(40)
        let five = expressions.append(5)
        var attributes = Arena<AttributeID, UInt32>()
        let attributeIDs = [attributes.append(0), attributes.append(1)]
        var lists = ListArena()

        let appended = lists.make([ten, twenty])
        var cursor = lists.cursor(appended)
        var visited: [ExpressionID] = []
        while !cursor.isAtEnd {
            visited.append(lists.advance(&cursor))
            lists.append(appended, forty)
        }
        #expect(visited == [ten, twenty])
        #expect(lists.next(&cursor) == nil)

        let inserted = lists.make([ten, twenty])
        cursor = lists.cursor(inserted)
        visited = []
        while !cursor.isAtEnd {
            let element = lists.advance(&cursor)
            visited.append(element)
            if visited.count == 1 {
                lists.insert(inserted, 0, five)
            }
        }
        #expect(visited == [ten, ten])

        let attributeList = lists.make(attributeIDs)
        var attributeCursor = lists.cursor(attributeList)
        var visitedAttributes: [AttributeID] = []
        while !attributeCursor.isAtEnd {
            visitedAttributes.append(lists.advance(&attributeCursor))
        }
        #expect(visitedAttributes == attributeIDs)

        var empty = lists.cursor(lists.makeEmpty(StatementID.self))
        #expect(empty.isAtEnd)
        #expect(lists.next(&empty) == nil)
    }

    @Test
    func cursorOverloadsAgree() {
        var statements = Arena<StatementID, UInt32>()
        var attributes = Arena<AttributeID, UInt32>()
        var parameters = Arena<ParameterID, UInt32>()
        let statementIDs = [statements.append(0), statements.append(1)]
        let attributeIDs = [attributes.append(0), attributes.append(1), attributes.append(2)]
        let parameterIDs = [parameters.append(0)]
        var lists = ListArena()
        let statementList = lists.make(statementIDs)
        let attributeList = lists.make(attributeIDs)
        let parameterList = lists.make(parameterIDs)
        #expect(lists.count(statementList) == 2)
        #expect(lists.count(attributeList) == 3)
        #expect(lists[statementList, 1] == statementIDs[1])
        #expect(lists[attributeList, 2] == attributeIDs[2])
        #expect(readAll(lists, parameterList) == parameterIDs)

        var statementCursor = lists.cursor(statementList)
        var visitedStatements: [StatementID] = []
        while let statement = lists.next(&statementCursor) {
            visitedStatements.append(statement)
        }
        #expect(visitedStatements == statementIDs)

        var attributeCursor = lists.cursor(attributeList)
        var visitedAttributes: [AttributeID] = []
        while let attribute = lists.next(&attributeCursor) {
            visitedAttributes.append(attribute)
        }
        #expect(visitedAttributes == attributeIDs)

        var parameterCursor = lists.cursor(parameterList)
        #expect(lists.next(&parameterCursor) == parameterIDs[0])
        #expect(lists.next(&parameterCursor) == nil)
        #expect(lists.next(&parameterCursor) == nil)
    }

    // GVR appends arguments and parameters to old lists at every call site (GlobalVariableRewriter.cpp:222-264): the
    // pool must grow by O(m·k), not O(m·k²).
    @Test
    func editsOfOldListsInsideAScopeAreAmortised() {
        var expressions = Arena<ExpressionID, UInt32>()
        let value = expressions.append(0)
        var lists = ListArena()
        let listCount = 100
        let appendCount = 1000
        var ids: [ListID<ExpressionID>] = []
        while ids.count < listCount {
            ids.append(ids.count % 2 == 0 ? lists.make([value]) : lists.makeEmpty(ExpressionID.self))
        }
        let before = lists.snapshot()
        let poolBefore = lists.poolCount
        let mark = lists.openScope()
        var round = 0
        while round < appendCount {
            var list = 0
            while list < listCount {
                lists.append(ids[list], value)
                list += 1
            }
            round += 1
        }
        #expect(lists.poolCount - poolBefore <= 4 * listCount * appendCount)
        #expect(lists.count(ids[0]) == appendCount + 1)
        #expect(lists.count(ids[1]) == appendCount)

        let afterInterleaved = lists.poolCount
        var list = 0
        while list < listCount {
            var count = 0
            while count < appendCount {
                lists.append(ids[list], value)
                count += 1
            }
            list += 1
        }
        #expect(lists.poolCount - afterInterleaved <= 4 * listCount * appendCount)
        lists.rollback(to: mark)
        #expect(lists.snapshot() == before)
        #expect(lists.poolCount == poolBefore)
    }

    @Test
    func sideTableHasTheHashMapSemantics() {
        var functions = Arena<FunctionID, UInt32>()
        let a = functions.append(0)
        let b = functions.append(1)
        let c = functions.append(2)
        var table = SideTable<FunctionID, String>()
        #expect(table.isEmpty)
        #expect(table.add(b, "b") == true)
        #expect(table.add(b, "x") == false)
        #expect(table.get(b) == "b")
        #expect(table.get(c) == nil)
        #expect(table.set(b, "y") == false)
        #expect(table.set(a, "a") == true)
        #expect(table.count == 2)
        #expect(table.contains(a) && !table.contains(c))
        #expect(table.ensure(c) { "c" } == "c")
        #expect(table.ensure(c) { "z" } == "c")
        #expect(
            table.modify(c) { value in
                value += "!"
                return value.utf8.count
            } == 2
        )
        #expect(table.find(c) == "c!")
        table.modify(c, default: "") { $0 += "?" }
        #expect(table.get(c) == "c!?")
        #expect(table.take(c) == "c!?")
        #expect(table.take(c) == nil)
        #expect(table.remove(a) == true)
        #expect(table.remove(a) == false)
        #expect(table.count == 1)

        var other = SideTable<FunctionID, String>()
        other.set(b, "y")
        #expect(table == other)
        table.clear()
        #expect(table.isEmpty && table != other)
    }

    @Test
    func idSetHasTheHashSetSemantics() {
        var variables = Arena<VariableID, UInt32>()
        var ids: [VariableID] = []
        while ids.count < 200 {
            ids.append(variables.append(UInt32(ids.count)))
        }
        var set = IDSet<VariableID>()
        #expect(set.add(ids[130]) == true)
        #expect(set.add(ids[3]) == true)
        #expect(set.add(ids[64]) == true)
        #expect(set.add(ids[3]) == false)
        #expect(set.count == 3)
        #expect(set.contains(ids[64]) && !set.contains(ids[65]))
        var visited: [VariableID] = []
        set.forEachInCreationOrder { visited.append($0) }
        #expect(visited == [ids[3], ids[64], ids[130]])
        #expect(set.remove(ids[64]) == true)
        #expect(set.remove(ids[64]) == false)

        var other = IDSet<VariableID>()
        other.add(ids[3])
        other.add(ids[199])
        set.addAll(other)
        #expect(set.count == 3)
        visited = []
        set.forEachInCreationOrder { visited.append($0) }
        #expect(visited == [ids[3], ids[130], ids[199]])
        set.remove(ids[130])
        set.remove(ids[199])
        var small = IDSet<VariableID>()
        small.add(ids[3])
        #expect(set == small)
        set.clear()
        #expect(set.isEmpty && set != small)
    }

    @Test
    func orderedIDSetIteratesInInsertionOrder() {
        var globals = Arena<CallGraphGlobalID, UInt32>()
        let a = globals.append(0)
        let b = globals.append(1)
        let c = globals.append(2)
        var set = OrderedIDSet<CallGraphGlobalID>()
        set.add(c)
        set.add(a)
        set.add(c)
        set.add(b)
        #expect(set.elements == [c, a, b])
        set.remove(a)
        #expect(set.elements == [c, b])
    }
}
