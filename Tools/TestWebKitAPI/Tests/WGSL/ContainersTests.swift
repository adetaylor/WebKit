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

private struct TestError: Error, Equatable {
    var value: Int
}

// SplitMix64: a deterministic generator for the model-based tests.
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

// GlobalSorting's edge key: a (source, target) pair of node indices.
private struct PairKey: SmallKey {
    let source: UInt32
    let target: UInt32

    var smallKeyBits: UInt64 { UInt64(source) << 32 | UInt64(target) }
}

@Suite
struct WGSLContainersTests {
    @Test
    func lookupMapAddDoesNotOverwrite() {
        var map = LookupMap<UInt32, String>()
        #expect(map.isEmpty)
        #expect(map.add(1, "a") == true)
        #expect(map.add(1, "b") == false)
        #expect(map.get(1) == "a")
        #expect(map.count == 1)
    }

    @Test
    func lookupMapSetOverwrites() {
        var map = LookupMap<UInt32, String>()
        #expect(map.set(1, "a") == true)
        #expect(map.set(1, "b") == false)
        #expect(map.get(1) == "b")
        #expect(map.count == 1)
    }

    @Test
    func lookupMapLookups() {
        var map = LookupMap<UInt32, Int>()
        map.add(1, 10)
        #expect(map.contains(1))
        #expect(!map.contains(2))
        #expect(map.find(1) == 10)
        #expect(map.find(2) == nil)
        #expect(map.get(2) ?? 0 == 0)
    }

    @Test
    func lookupMapRemoveAndTake() {
        var map = LookupMap<UInt32, Int>()
        map.add(1, 10)
        map.add(2, 20)
        #expect(map.remove(1) == true)
        #expect(map.remove(1) == false)
        #expect(map.take(2) == 20)
        #expect(map.take(2) == nil)
        #expect(map.isEmpty)
        map.add(3, 30)
        map.clear()
        #expect(map.isEmpty)
    }

    @Test
    func lookupMapEnsureMakesTheValueOnce() throws {
        var map = LookupMap<UInt32, Int>()
        var calls = 0
        let made = map.ensure(1) {
            calls += 1
            return 10
        }
        let existing = map.ensure(1) {
            calls += 1
            return 11
        }
        #expect(made == 10)
        #expect(existing == 10)
        #expect(calls == 1)

        #expect(throws: TestError(value: 2)) {
            try map.ensure(2) { () throws(TestError) -> Int in throw TestError(value: 2) }
        }
        #expect(!map.contains(2))
    }

    @Test
    func lookupMapModify() {
        var map = LookupMap<UInt32, [Int]>()
        #expect(map.modify(1) { $0.append(1) } == nil)
        #expect(!map.contains(1))
        map.modify(1, default: []) { $0.append(1) }
        map.modify(1, default: [99]) { $0.append(2) }
        let count = map.modify(1) {
            $0.append(3)
            return $0.count
        }
        #expect(count == 3)
        #expect(map.get(1) == [1, 2, 3])

        let copy = map
        map.modify(1) { $0.append(4) }
        #expect(copy.get(1) == [1, 2, 3])
        #expect(map.get(1) == [1, 2, 3, 4])
        #expect(copy != map)
    }

    @Test
    func lookupSet() {
        var set = LookupSet<UInt32>()
        #expect(set.add(1) == true)
        #expect(set.add(1) == false)
        #expect(set.contains(1))
        #expect(!set.contains(2))
        var other = LookupSet<UInt32>()
        other.addAll([2, 3])
        set.addAll(other)
        #expect(set.count == 3)
        #expect(set.remove(2) == true)
        #expect(set.remove(2) == false)
        #expect(set.count == 2)
        set.clear()
        #expect(set.isEmpty)
    }

    @Test
    func orderedSetAddAppendsOnlyNewElements() {
        var set = OrderedSet<String>()
        #expect(set.add("b") == true)
        #expect(set.add("a") == true)
        #expect(set.add("b") == false)
        #expect(set.add("c") == true)
        #expect(set.elements == ["b", "a", "c"])
        #expect(Array(set) == ["b", "a", "c"])
        #expect(set.count == 3)
        #expect(set.contains("a"))
        #expect(!set.contains("d"))
    }

    @Test
    func orderedSetRemoveKeepsTheOrderOfTheRest() {
        var set = OrderedSet<Int>()
        for element in [5, 1, 4, 2, 3] {
            set.add(element)
        }
        #expect(set.remove(4) == true)
        #expect(set.remove(4) == false)
        #expect(set.elements == [5, 1, 2, 3])
        #expect(set.add(4) == true)
        #expect(set.elements == [5, 1, 2, 3, 4])
    }

    @Test
    func orderedSetFirstAndLast() {
        var set = OrderedSet<Int>()
        #expect(set.first == nil)
        #expect(set.last == nil)
        for element in 0..<5 {
            set.add(element)
        }
        set.remove(0)
        set.remove(1)
        set.remove(4)
        #expect(set.first == 2)
        #expect(set.last == 3)
        set.remove(2)
        set.remove(3)
        #expect(set.isEmpty)
        #expect(set.first == nil)
        #expect(set.last == nil)
        set.add(7)
        #expect(set.first == 7)
        #expect(set.last == 7)
    }

    @Test
    func orderedSetCopiesKeepTheOrder() {
        var set = OrderedSet<Int>()
        for element in [3, 1, 2] {
            set.add(element)
        }
        var copy = set
        copy.remove(1)
        copy.add(0)
        #expect(set.elements == [3, 1, 2])
        #expect(copy.elements == [3, 2, 0])
    }

    // ListHashSet semantics against a plain array, through enough removals to compact the storage many times.
    @Test(arguments: [UInt64(1), 2, 3])
    func orderedSetMatchesAListModel(seed: UInt64) {
        var random = TestRandom(seed: seed)
        var set = OrderedSet<Int>()
        var model: [Int] = []
        for step in 0..<20_000 {
            let element = random.next(below: step < 10_000 ? 300 : 40)
            if random.next(below: 100) < 55 {
                let isNew = !model.contains(element)
                if isNew {
                    model.append(element)
                }
                #expect(set.add(element) == isNew)
            } else {
                let index = model.firstIndex(of: element)
                if let index {
                    model.remove(at: index)
                }
                #expect(set.remove(element) == (index != nil))
            }
            if step % 97 == 0 {
                #expect(set.elements == model)
                #expect(Array(set) == model)
            }
            #expect(set.count == model.count)
            #expect(set.first == model.first)
            #expect(set.last == model.last)
            #expect(set.contains(element) == model.contains(element))
        }
        #expect(set.elements == model)
    }

    @Test
    func symbolMapAddSetAndOrder() {
        var table = SymbolTable.predeclared
        let a = table.intern(ContiguousArray("a".utf16))
        let b = table.intern(ContiguousArray("b".utf16))
        let c = table.intern(ContiguousArray("c".utf16))
        var map = SymbolMap<Int>()
        #expect(map.isEmpty)
        #expect(map.find(a) == nil)
        #expect(map.add(b, 1) == true)
        #expect(map.add(b, 2) == false)
        #expect(map.find(b) == 1)
        #expect(map.set(a, 3) == true)
        #expect(map.set(b, 4) == false)
        #expect(map.set(c, 5) == true)
        #expect(map.find(b) == 4)
        #expect(map.contains(c) && !map.contains(table.intern(ContiguousArray("vec2f".utf16))))
        #expect(map.count == 3)
        #expect(map.orderedKeys == [b, a, c])
        var visited: [Int] = []
        map.forEachEntry { _, value in visited.append(value) }
        #expect(visited == [4, 3, 5])
        map.clear()
        #expect(map.isEmpty && map.find(a) == nil)
    }

    // Equality is HashMap's: the same keys and values, whether the maps were filled in the same order and whether either
    // still scans.
    @Test(arguments: [3, 8, 9, 40])
    func smallKeyMapGetAndEquality(count: Int) {
        var forward = SmallKeyMap<PairKey, Int>()
        var backward = SmallKeyMap<PairKey, Int>()
        for index in 0..<count {
            forward.add(PairKey(source: UInt32(index), target: 1), index)
            backward.add(PairKey(source: UInt32(count - 1 - index), target: 1), count - 1 - index)
        }
        for index in 0..<count {
            let key = PairKey(source: UInt32(index), target: 1)
            #expect(forward.get(key) == index)
            #expect(forward.get(key) == forward.find(key))
        }
        #expect(forward.get(PairKey(source: 0, target: 2)) == nil)
        #expect(forward == backward)

        var changedValue = backward
        changedValue.set(PairKey(source: 0, target: 1), -1)
        #expect(forward != changedValue)

        var smaller = SmallKeyMap<PairKey, Int>()
        for index in 0..<count - 1 {
            smaller.add(PairKey(source: UInt32(index), target: 1), index)
        }
        #expect(forward != smaller)
        var changedKey = smaller
        changedKey.add(PairKey(source: UInt32(count - 1), target: 2), count - 1)
        #expect(forward != changedKey)
        smaller.add(PairKey(source: UInt32(count - 1), target: 1), count - 1)
        #expect(forward == smaller)
    }

    // A map reserved for many keys builds its first table at that size, and a map emptied with its capacity kept behaves as
    // a new one, scanning or hashed.
    @Test(arguments: [3, 9, 40, 300])
    func smallKeyMapReservedAndReusedMatchesANewMap(count: Int) {
        var reserved = SmallKeyMap<PairKey, Int>()
        reserved.reserveInitialCapacity(count)
        var reused = SmallKeyMap<PairKey, Int>()
        for index in 0..<50 {
            reused.add(PairKey(source: UInt32(index), target: 7), index)
        }
        reused.removeAllKeepingCapacity()
        #expect(reused.isEmpty && reused.find(PairKey(source: 0, target: 7)) == nil)
        var fresh = SmallKeyMap<PairKey, Int>()
        for index in 0..<count {
            let key = PairKey(source: UInt32(index), target: 1)
            let addedToReserved = reserved.add(key, index)
            let addedToFresh = fresh.add(key, index)
            let addedToReused = reused.add(key, index)
            let addedAgain = reused.add(key, -1)
            #expect(addedToReserved && addedToFresh && addedToReused && !addedAgain)
        }
        #expect(reserved == fresh && reused == fresh)
        #expect(reserved.orderedKeys == fresh.orderedKeys && reused.orderedKeys == fresh.orderedKeys)
        for index in 0..<count {
            let key = PairKey(source: UInt32(index), target: 1)
            #expect(reserved.find(key) == index && reused.find(key) == index)
        }
        #expect(!reserved.contains(PairKey(source: 0, target: 7)) && !reused.contains(PairKey(source: 0, target: 7)))
    }

    // Past a handful of entries the map switches from a scan to its hash table: every lookup must agree with a model.
    @Test(arguments: [UInt64(1), 2, 3])
    func symbolMapMatchesALookupMapModel(seed: UInt64) {
        var random = TestRandom(seed: seed)
        var table = SymbolTable.predeclared
        var symbols: [Symbol] = []
        for index in 0..<2_000 {
            symbols.append(table.intern(ContiguousArray("name\(index)".utf16)))
        }
        symbols.append(table.intern(ContiguousArray("vec4f".utf16)))
        var map = SymbolMap<Int>()
        var model = LookupMap<Symbol, Int>()
        var order: [Symbol] = []
        for step in 0..<20_000 {
            let symbol = symbols[random.next(below: step < 2_000 ? 12 : symbols.count)]
            let value = random.next(below: 1_000)
            if random.next(below: 2) == 0 {
                let isNew = model.add(symbol, value)
                if isNew {
                    order.append(symbol)
                }
                #expect(map.add(symbol, value) == isNew)
            } else {
                let isNew = model.set(symbol, value)
                if isNew {
                    order.append(symbol)
                }
                #expect(map.set(symbol, value) == isNew)
            }
            let probe = symbols[random.next(below: symbols.count)]
            #expect(map.find(probe) == model.find(probe))
            #expect(map.contains(probe) == model.contains(probe))
            #expect(map.count == model.count)
        }
        #expect(map.orderedKeys == order)
    }

    // addAll reuses the hashes `other` stored once it has a table, and hashes the keys of one that still scans; either
    // map may be scanning or hashed.
    @Test(arguments: [UInt64(1), 2, 3])
    func smallKeyMapAddAllMatchesAModel(seed: UInt64) {
        var random = TestRandom(seed: seed)
        for _ in 0..<200 {
            var map = SmallKeyMap<PairKey, Int>()
            var other = SmallKeyMap<PairKey, Int>()
            var model = LookupMap<UInt64, Int>()
            var order: [PairKey] = []
            for _ in 0..<random.next(below: 40) {
                let key = PairKey(source: UInt32(random.next(below: 3)), target: UInt32(random.next(below: 20)))
                let value = random.next(below: 1_000)
                if model.add(key.smallKeyBits, value) {
                    order.append(key)
                }
                map.add(key, value)
            }
            for _ in 0..<random.next(below: 40) {
                other.add(
                    PairKey(source: UInt32(random.next(below: 3)), target: UInt32(random.next(below: 20))),
                    random.next(below: 1_000)
                )
            }
            other.forEachEntry { key, value in
                if model.add(key.smallKeyBits, value) {
                    order.append(key)
                }
            }
            map.addAll(other)
            #expect(map.count == model.count)
            #expect(map.orderedKeys == order)
            for source in 0..<3 {
                for target in 0..<21 {
                    let key = PairKey(source: UInt32(source), target: UInt32(target))
                    #expect(map.find(key) == model.find(key.smallKeyBits))
                }
            }
        }
    }

    // Keys the source composes must not form one probe cluster (quadratic insertion). Both sets collide under an
    // unkeyed Fibonacci mix of the key bits (the product's bits 32 and up): the first differs only above bit 47, so every
    // key falls in slot 0 of a 65,536-slot table; the second, small node indices as GlobalSorting's edges, is chosen to
    // fall in 8 of 8,192 slots.
    @Test
    func smallKeyMapCraftedCollisionsDoNotCluster() {
        var highBits: [PairKey] = []
        for index in 0..<20_000 {
            highBits.append(PairKey(source: UInt32(index) << 16, target: 0))
        }
        var window: [PairKey] = []
        var source: UInt32 = 5_000
        while window.count < 4_000 {
            var target: UInt32 = 0
            while target < 5_000 && window.count < 4_000 {
                let bits = UInt64(source) << 32 | UInt64(target)
                if (bits &* 0x9e37_79b9_7f4a_7c15) >> 32 & 0x1fff < 8 {
                    window.append(PairKey(source: source, target: target))
                }
                target += 1
            }
            source += 1
        }
        for keys in [highBits, window] {
            var map = SmallKeyMap<PairKey, Int>()
            var added = 0
            for (index, key) in keys.enumerated() where map.add(key, index) {
                added += 1
            }
            #expect(added == keys.count)
            #expect(map.count == keys.count)
            #expect(map.longestProbeRun() < 400)
            for index in stride(from: 0, to: keys.count, by: 97) {
                #expect(map.find(keys[index]) == index)
            }
            #expect(!map.contains(PairKey(source: 1, target: 1)))
        }
    }

    @Test
    func forEachElementVisitsInOrder() throws {
        var visited: [Int] = []
        forEachElement([3, 1, 2]) { visited.append($0) }
        #expect(visited == [3, 1, 2])

        var set = OrderedSet<Int>()
        for element in [9, 7, 8] {
            set.add(element)
        }
        set.remove(7)
        visited = []
        forEachElement(set) { visited.append($0) }
        #expect(visited == [9, 8])

        visited = []
        #expect(throws: TestError(value: 1)) {
            try forEachElement([0, 1, 2]) { (element: Int) throws(TestError) in
                visited.append(element)
                if element == 1 {
                    throw TestError(value: element)
                }
            }
        }
        #expect(visited == [0, 1])
    }

    @Test
    func appendIfNotContains() {
        var vector = [1, 2]
        #expect(vector.appendIfNotContains(3) == true)
        #expect(vector.appendIfNotContains(1) == false)
        #expect(vector == [1, 2, 3])
    }
}
