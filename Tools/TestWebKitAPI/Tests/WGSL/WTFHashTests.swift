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

// The expected values were measured from WTF.

private func codeUnits(_ string: String) -> [UInt16] {
    Array(string.utf16)
}

private func keys<Value>(_ table: WTFIndexMap<Value>) -> [UInt64] {
    table.map(\.key)
}

private func stringKeys<Value>(_ table: WTFHashTable<WTFStringHash, Value>) -> [String] {
    table.map { String(decoding: $0.key, as: UTF16.self) }
}

private func indexMap(inserting keys: [UInt64]) -> WTFIndexMap<Int> {
    var map = WTFIndexMap<Int>()
    for (index, key) in keys.enumerated() {
        map.add(key, index)
    }
    return map
}

@Suite
struct WGSLWTFHashTests {
    @Test
    func stringHash() {
        let vectors: [(units: [UInt16], hash: UInt32)] = [
            (codeUnits(""), 15_648_162),
            (codeUnits("a"), 16_198_731),
            (codeUnits("ab"), 15_900_814),
            (codeUnits("abc"), 15_377_330),
            (codeUnits("abcd"), 14_766_618),
            (codeUnits("main"), 15_217_586),
            (codeUnits("x"), 11_858_259),
            (codeUnits("field0"), 13_058_118),
            (codeUnits("fract"), 13_879_844),
            (codeUnits("exp"), 15_411_007),
            (codeUnits("whole"), 14_385_694),
            (codeUnits("old_value"), 10_462_444),
            (codeUnits("exchanged"), 9_368_639),
            ([0x03B1, 0x62], 14_074_257),
            ([0xE9], 6_893_516),
            ([0x65, 0x301], 13_764_372),
            (codeUnits("abcdefghijklmnopq"), 16_119_819),
            (codeUnits("abcdefghijklmnopqrstuvwxyz0123456"), 12_979_375),
            (codeUnits("abcdefghijklmnopqrstuvwxyz0123456789_abcdefghijklmn"), 12_741_095),
            (codeUnits("__ArgumentBufferT_0_0_and_some_more_text_to_pass_ninety_six_bytes_of_input_abcdefghijklmnopqrstu"), 5_865_853),
            (Array(0x3B1...0x3C9), 47_359),
        ]
        for vector in vectors {
            #expect(WTFHash.string(vector.units) == vector.hash, "\(vector.units)")
        }
    }

    @Test
    func intHash() {
        let vectors: [(key: UInt64, hash: UInt32)] = [
            (0, 3_349_934_249),
            (1, 120_591_620),
            (2, 1_096_910_155),
            (3, 2_148_458_457),
            (4, 2_426_577_358),
            (5, 3_494_902_434),
            (6, 309_947_113),
            (7, 1_359_318_904),
            (4_294_967_296, 556_316_519),
            (UInt64.max - 1, 2_147_920_443),
            (UInt64.max, 3_349_382_473),
        ]
        for vector in vectors {
            #expect(WTFHash.int(vector.key) == vector.hash, "\(vector.key)")
            #expect(WTFIntHash.hash(vector.key) == vector.hash, "\(vector.key)")
        }
    }

    @Test
    func pairIntHash() {
        #expect(WTFHash.pairInt(1, 1) == 1_039_202_221)
        #expect(WTFHash.pairInt(0, 0) == 0)
        #expect(WTFHash.pairInt(UInt32.max, UInt32.max) == 980_515_008)
        #expect(WTFHash.pairInt(123_456_789, 987_654_321) == 2_014_954_981)
    }

    @Test
    func tableSizes() {
        let bestSizes: [(keyCount: Int, tableSize: Int)] = [
            (0, 8), (1, 8), (4, 8), (5, 16), (9, 16), (10, 32), (11, 32), (19, 32), (20, 64), (23, 64), (24, 64),
        ]
        for size in bestSizes {
            #expect(WTFHashTableSizePolicy.computeBestTableSize(size.keyCount) == size.tableSize, "\(size.keyCount)")
        }
        #expect(!WTFHashTableSizePolicy.shouldExpand(5, 8))
        #expect(WTFHashTableSizePolicy.shouldExpand(6, 8))
        #expect(WTFHashTableSizePolicy.shouldExpand(768, 1024))
        #expect(!WTFHashTableSizePolicy.shouldExpand(1023, 2048))
        #expect(WTFHashTableSizePolicy.shouldExpand(1024, 2048))
    }

    // ConstantStruct and Types::*Struct field maps are built from initializer lists, which reserve
    // their size (an 8-bucket table) and add in list order. No key set collides, so the order is fixed and survives
    // copies; the Swift ConstantStruct hard-codes it.
    @Test
    func primitiveStructFieldOrders() {
        let buckets: [(name: String, bucket: UInt32)] = [
            ("fract", 4), ("exp", 7), ("whole", 6), ("old_value", 4), ("exchanged", 7),
        ]
        for entry in buckets {
            #expect(WTFHash.string(codeUnits(entry.name)) & 7 == entry.bucket, "\(entry.name)")
        }

        let structs: [(initializerList: [String], order: [String])] = [
            (["fract", "exp"], ["fract", "exp"]), // ConstantFunctions.h:1307 (frexp)
            (["exp", "fract"], ["fract", "exp"]), // Types.h:179 (__frexp_result)
            (["fract", "whole"], ["fract", "whole"]), // ConstantFunctions.h:1447 (modf)
            (["whole", "fract"], ["fract", "whole"]),
            (["exchanged", "old_value"], ["old_value", "exchanged"]), // Types.h:201 (__atomic_compare_exchange_result)
            (["old_value", "exchanged"], ["old_value", "exchanged"]),
        ]
        for primitiveStruct in structs {
            var fields = WTFHashTable<WTFStringHash, Int>()
            fields.reserveInitialCapacity(primitiveStruct.initializerList.count)
            for (index, name) in primitiveStruct.initializerList.enumerated() {
                fields.add(codeUnits(name), index)
            }
            #expect(fields.capacity == 8)
            #expect(stringKeys(fields) == primitiveStruct.order)
            var copy = fields
            for _ in 0..<3 {
                copy = copy.wtfCopy()
                #expect(stringKeys(copy) == primitiveStruct.order)
            }
        }
    }

    // Groups 0..<n added in order to m_groupBindingMap (site A, never copied) and to
    // UsedResources, whose copy (GlobalVariableRewriter.cpp:1208) sites B-D iterate.
    @Test
    func groupOrders() {
        let orders: [(order: [UInt64], afterCopy: [UInt64])] = [
            ([0, 1], [0, 1]),
            ([0, 2, 1], [0, 2, 1]),
            ([0, 3, 2, 1], [0, 3, 2, 1]),
            ([0, 3, 2, 1, 4], [1, 0, 3, 2, 4]),
            ([5, 1, 0, 3, 2, 4], [5, 1, 0, 3, 2, 4]),
            ([5, 1, 0, 3, 2, 6, 4], [5, 1, 0, 3, 2, 6, 4]),
            ([5, 1, 7, 0, 3, 2, 6, 4], [5, 1, 7, 0, 3, 2, 6, 4]),
        ]
        for expected in orders {
            let groupCount = UInt64(expected.order.count)
            let groups = indexMap(inserting: Array(0..<groupCount))
            #expect(keys(groups) == expected.order, "\(groupCount) groups")
            #expect(keys(groups.wtfCopy()) == expected.afterCopy, "\(groupCount) groups, copied")
        }
        #expect(indexMap(inserting: [0, 1, 2, 3, 4]).capacity == 8)
        #expect(indexMap(inserting: [0, 1, 2, 3, 4]).wtfCopy().capacity == 16)
    }

    // @group(g) @binding(0) for g = 0..4 (global0..global4), then
    // @group(4) @binding(3) (global5) and @group(4) @binding(1) (global6), all read by one entry point.
    @Test
    func usedResourcesWorkedExample() {
        let reads: [(group: UInt64, binding: UInt64)] = [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (4, 3), (4, 1)]
        var groupBindingMap = WTFIndexMap<[Int]>()
        var usedResources = WTFIndexMap<WTFIndexMap<Int>>()
        for (global, read) in reads.enumerated() {
            groupBindingMap.modify(read.group, default: []) { $0.append(global) }
            usedResources.modify(read.group, default: WTFIndexMap()) { $0.add(read.binding, global) }
        }

        // Site A: the argument buffer structs and parameters.
        #expect(keys(groupBindingMap) == [0, 3, 2, 1, 4])

        let usedGlobals = usedResources.wtfCopy()
        #expect(keys(usedResources) == [0, 3, 2, 1, 4])
        #expect(keys(usedGlobals) == [1, 0, 3, 2, 4])
        #expect(usedGlobals.find(4).map { keys($0) } == [0, 3, 1])

        // Site B: each materialisation is inserted at index 0, so the body lists them in reverse iteration order.
        var materialisations: [Int] = []
        forEachElement(usedGlobals) { _, bindings in
            forEachElement(bindings) { _, global in
                materialisations.insert(global, at: 0)
            }
        }
        #expect(materialisations == [6, 5, 4, 2, 3, 0, 1])
    }

    @Test
    func copyReordersWrappedProbeSequences() {
        // 9 and 17 both hash to bucket 7 of an 8-bucket table: the second wraps to bucket 0, and every copy flips them.
        #expect(WTFHash.int(9) & 7 == 7)
        #expect(WTFHash.int(17) & 7 == 7)
        var map = indexMap(inserting: [9, 17])
        #expect(keys(map) == [17, 9])
        map = map.wtfCopy()
        #expect(keys(map) == [9, 17])
        map = map.wtfCopy()
        #expect(keys(map) == [17, 9])
        let moved = map
        #expect(keys(moved) == [17, 9])
    }

    @Test
    func addReusesTheLastDeletedBucketOfItsProbeSequence() {
        // 0, 3, 6, 26 and 29 all hash to bucket 1 of an 8-bucket table: probes 1, 2, 4, 7, 3, ...
        for key: UInt64 in [0, 3, 6, 26, 29] {
            #expect(WTFHash.int(key) & 7 == 1, "\(key)")
        }
        var map = indexMap(inserting: [0, 3, 6])
        map.remove(0)
        map.remove(3)
        #expect(keys(map) == [6])
        map.add(26, 26)
        map.add(29, 29)
        #expect(keys(map) == [29, 26, 6])
        #expect(map.capacity == 8)
    }

    @Test
    func setOverwritesInPlace() {
        var map = indexMap(inserting: [9, 17])
        #expect(map.set(9, 90) == false)
        #expect(map.set(1, 10) == true)
        #expect(keys(map) == [17, 1, 9])
        #expect(map.get(9) == 90)
        #expect(map.add(9, 900) == false)
        #expect(map.get(9) == 90)
    }

    @Test
    func expandAndShrink() {
        var map = indexMap(inserting: [0, 1, 2, 3, 4])
        #expect(map.capacity == 8)
        map.add(5, 5)
        #expect(map.capacity == 16)
        for key: UInt64 in [0, 1, 2] {
            map.remove(key)
        }
        #expect(map.capacity == 16)
        map.remove(3)
        #expect(map.capacity == 8)
        #expect(keys(map) == [5, 4])
    }

    @Test
    func removeIfVisitsBucketsFromTheLast() {
        var map = indexMap(inserting: Array(0..<12))
        let order = keys(map)
        var visited: [UInt64] = []
        let removed = map.removeIf { key, value in
            visited.append(key)
            return value & 1 != 0
        }
        #expect(removed)
        #expect(visited == order.reversed())
        #expect(keys(map) == order.filter { $0 & 1 == 0 })
        #expect(!map.removeIf { _, _ in false })
    }

    @Test
    func clearFreesTheTable() {
        var map = indexMap(inserting: Array(0..<20))
        #expect(map.capacity == 32)
        map.clear()
        #expect(map.capacity == 0)
        #expect(map.isEmpty)
        map.add(1, 1)
        #expect(map.capacity == 8)
    }

    @Test
    func copyOfAnEmptyTableIsUnallocated() {
        var map = indexMap(inserting: [1])
        map.remove(1)
        #expect(map.capacity == 8)
        #expect(map.wtfCopy().capacity == 0)
    }

    @Test
    func lookupsEnsureTakeAndModify() {
        var map = indexMap(inserting: [9, 17])
        #expect(map.contains(9))
        #expect(!map.contains(1))
        #expect(map.find(17) == 1)
        #expect(map.find(1) == nil)

        var calls = 0
        let existing = map.ensure(9) {
            calls += 1
            return 99
        }
        let made = map.ensure(1) {
            calls += 1
            return 11
        }
        #expect(existing == 0)
        #expect(made == 11)
        #expect(calls == 1)
        #expect(keys(map) == [17, 1, 9])

        let modified = map.modify(1) {
            $0 += 1
            return $0
        }
        #expect(modified == 12)
        #expect(map.modify(2) { $0 += 1 } == nil)
        map.modify(2, default: 20) { $0 += 2 }
        #expect(map.get(2) == 22)

        map.modifyEach { key, value in value = Int(key) }
        #expect(map.map(\.value) == keys(map).map { Int($0) })

        #expect(map.take(17) == 17)
        #expect(map.take(17) == nil)
        #expect(map.count == 3)
    }

    @Test
    func modifyMutatesAUniqueValue() {
        var map = WTFIndexMap<[Int]>()
        map.add(1, [1])
        let alias = map
        map.modify(1) { $0.append(2) }
        #expect(map.get(1) == [1, 2])
        #expect(alias.get(1) == [1])
    }

    // DEV-05: C++'s IndexMap traps (Debug) or misbehaves (Release) on its empty and deleted keys; here they are ordinary keys.
    @Test
    func DEV_05_emptyAndDeletedKeysAreOrdinaryKeys() {
        var map = WTFIndexMap<Int>()
        #expect(map.add(UInt64.max, 1) == true)
        #expect(map.add(UInt64.max - 1, 2) == true)
        #expect(map.get(UInt64.max) == 1)
        #expect(map.get(UInt64.max - 1) == 2)
        #expect(map.remove(UInt64.max) == true)
        #expect(keys(map) == [UInt64.max - 1])
    }
}
