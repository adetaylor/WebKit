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

// The expression arena and Expression::m_constantValue of a module, with the C++ operations that touch the constant:
// construction, replace() (overload 3 wraps in an IdentityExpression without a constant, overload 4 copies the
// replacement's constant), evaluate()'s cache (WGSL.cpp:361), and CompilationScope.
private struct ConstantModule: ~Copyable {
    var expressions = Arena<ExpressionID, UInt32>()
    var constants = ConstantTable()
    var marks: [(expressions: Arena<ExpressionID, UInt32>.Mark, constants: ConstantTable.Mark)] = []

    mutating func construct(_ value: ConstantValue?) -> ExpressionID {
        let expression = expressions.append(0)
        if let value {
            constants.set(value, for: expression)
        }
        return expression
    }

    mutating func openScope() {
        let constantsMark = constants.openScope(expressionCount: expressions.count)
        marks.append((expressions.openScope(), constantsMark))
    }

    mutating func rollback() {
        guard let mark = marks.popLast() else {
            Issue.record("rollback without an open scope")
            return
        }
        constants.rollback(to: mark.constants)
        expressions.rollback(to: mark.expressions)
    }

    mutating func replaceCopying(_ current: ExpressionID, with replacement: ExpressionID) {
        constants.setLogged(constants.value(replacement), for: current)
    }

    mutating func replaceWrapping(_ current: ExpressionID, with replacement: ExpressionID) {
        _ = replacement
        constants.setLogged(nil, for: current)
    }

    mutating func cacheEvaluatedConstantValue(_ value: ConstantValue, for expression: ExpressionID) {
        constants.setSurvivingRollback(value, for: expression)
    }

    func constantValue(of expression: ExpressionID) -> ConstantValue? {
        expressions.contains(expression) ? constants.value(expression) : nil
    }
}

@Suite
struct WGSLConstantTableTests {
    // S1: evaluate()'s cache on a node older than the scope survives rollback.
    @Test
    func s1CacheOnAnOlderNodeSurvivesRollback() {
        var module = ConstantModule()
        let node = module.construct(.uint32(1))
        module.openScope()
        module.cacheEvaluatedConstantValue(.uint32(7), for: node)
        module.rollback()
        #expect(module.constantValue(of: node) == .uint32(7))
    }

    // S2: replace, then cache, then rollback: the undo restores the copy taken at replace time, without the cache.
    @Test
    func s2UndoOfAReplaceDropsALaterCache() {
        var module = ConstantModule()
        let node = module.construct(.uint32(1))
        module.openScope()
        let replacement = module.construct(.uint32(2))
        module.replaceCopying(node, with: replacement)
        #expect(module.constantValue(of: node) == .uint32(2))
        module.cacheEvaluatedConstantValue(.uint32(9), for: node)
        #expect(module.constantValue(of: node) == .uint32(9))
        module.rollback()
        #expect(module.constantValue(of: node) == .uint32(1))

        var withoutConstant = ConstantModule()
        let plain = withoutConstant.construct(nil)
        withoutConstant.openScope()
        let other = withoutConstant.construct(.uint32(2))
        withoutConstant.replaceCopying(plain, with: other)
        withoutConstant.cacheEvaluatedConstantValue(.uint32(9), for: plain)
        withoutConstant.rollback()
        #expect(withoutConstant.constantValue(of: plain) == nil)
    }

    // S3: cache, then replace, then rollback: the copy taken at replace time includes the cache.
    @Test
    func s3UndoOfAReplaceRestoresAnEarlierCache() {
        var module = ConstantModule()
        let node = module.construct(.uint32(1))
        module.openScope()
        module.cacheEvaluatedConstantValue(.uint32(5), for: node)
        let replacement = module.construct(.uint32(2))
        module.replaceWrapping(node, with: replacement)
        #expect(module.constantValue(of: node) == nil)
        module.rollback()
        #expect(module.constantValue(of: node) == .uint32(5))
    }

    // S4: an ID recycled after rollback inherits nothing.
    @Test
    func s4RecycledIDHasNoStaleCache() {
        var module = ConstantModule()
        _ = module.construct(.uint32(1))
        module.openScope()
        let fresh = module.construct(.uint32(3))
        module.cacheEvaluatedConstantValue(.uint32(11), for: fresh)
        module.rollback()
        module.openScope()
        let reused = module.construct(nil)
        #expect(reused == fresh)
        #expect(module.constantValue(of: reused) == nil)
        module.rollback()
    }

    // S5: a node of the outer scope cached in the inner scope keeps the cache until the outer rollback.
    @Test
    func s5OuterScopeNodeCachedInAnInnerScope() {
        var module = ConstantModule()
        module.openScope()
        let made = module.construct(.uint32(3))
        module.openScope()
        module.cacheEvaluatedConstantValue(.uint32(13), for: made)
        module.rollback()
        #expect(module.constantValue(of: made) == .uint32(13))
        module.rollback()
        module.openScope()
        let again = module.construct(nil)
        #expect(again == made)
        #expect(module.constantValue(of: again) == nil)
        module.rollback()
    }

    @Test
    func noGrowthOver1000PrepareGenerateEvaluateCycles() {
        var module = ConstantModule()
        let node = module.construct(.uint32(1))
        let other = module.construct(nil)
        var valuesAfterFirstCycle = 0
        var stickyAfterFirstCycle = 0
        var cycle: UInt32 = 0
        while cycle < 1000 {
            module.openScope()
            let made = module.construct(.uint32(cycle))
            module.openScope()
            module.cacheEvaluatedConstantValue(.uint32(cycle), for: node)
            module.cacheEvaluatedConstantValue(.uint32(cycle), for: made)
            let replacement = module.construct(.uint32(2))
            module.replaceCopying(other, with: replacement)
            module.cacheEvaluatedConstantValue(.uint32(77), for: other)
            module.rollback()
            module.rollback()
            // evaluateWorkgroupSize-style write after the scopes are gone.
            module.cacheEvaluatedConstantValue(.uint32(cycle), for: other)
            if cycle == 0 {
                valuesAfterFirstCycle = module.constants.valuesCount
                stickyAfterFirstCycle = module.constants.stickyCount
            }
            cycle += 1
        }
        #expect(module.constants.stickyCount == stickyAfterFirstCycle)
        #expect(module.constants.stickyCount <= 4)
        #expect(module.constants.valuesCount == valuesAfterFirstCycle)
        #expect(module.constantValue(of: node) == .uint32(999))
        #expect(module.constantValue(of: other) == .uint32(999))
    }

    @Test
    func writesOutsideAnyScopeOverwriteInPlace() {
        var module = ConstantModule()
        let node = module.construct(.uint32(1))
        let values = module.constants.valuesCount
        module.constants.set(.bool(true), for: node)
        module.cacheEvaluatedConstantValue(.int32(-1), for: node)
        #expect(module.constants.valuesCount == values)
        #expect(module.constants.stickyCount == 0)
        #expect(module.constantValue(of: node) == .int32(-1))
        module.constants.set(nil, for: node)
        #expect(module.constantValue(of: node) == nil)
        module.cacheEvaluatedConstantValue(.float(0.5), for: node)
        #expect(module.constantValue(of: node) == .float(0.5))
    }

    // A wrapping replace of a node without a constant logs it without growing the slots; its undo still drops a later cache.
    @Test
    func undoOfAWrappingReplaceOfANodeWithoutAConstantDropsALaterCache() {
        var module = ConstantModule()
        let node = module.construct(nil)
        module.openScope()
        let replacement = module.construct(.uint32(2))
        module.replaceWrapping(node, with: replacement)
        #expect(module.constantValue(of: node) == nil)
        module.cacheEvaluatedConstantValue(.uint32(7), for: node)
        #expect(module.constantValue(of: node) == .uint32(7))
        #expect(module.constants.stickyCount == 1)
        module.rollback()
        #expect(module.constantValue(of: node) == nil)
        module.cacheEvaluatedConstantValue(.uint32(8), for: node)
        #expect(module.constantValue(of: node) == .uint32(8))
        #expect(module.constants.stickyCount == 1)
    }

    @Test
    func replaceLogsAreUndoneNewestFirst() {
        var module = ConstantModule()
        let node = module.construct(.uint32(1))
        let untouched = module.construct(.bool(false))
        let before = module.constants.snapshot(expressionCount: module.expressions.count)
        module.openScope()
        let two = module.construct(.uint32(2))
        let three = module.construct(.uint32(3))
        module.replaceCopying(node, with: two)
        module.replaceCopying(node, with: three)
        module.replaceWrapping(node, with: two)
        module.replaceCopying(node, with: three)
        #expect(module.constantValue(of: node) == .uint32(3))
        module.constants.set(.uint32(4), for: three)
        #expect(module.constantValue(of: node) == .uint32(3))
        module.rollback()
        #expect(module.constants.snapshot(expressionCount: module.expressions.count) == before)
        #expect(module.constantValue(of: untouched) == .bool(false))
    }

    // The value-only `set` (TypeCheck's per-expression write) stores like `set` of an optional: into a fresh slot, with and
    // without reserved slots, over a scoped entry in place, and over a sticky entry in place.
    @Test
    func valueSetMatchesOptionalSet() {
        for reserved in [false, true] {
            var module = ConstantModule()
            var reference = ConstantModule()
            let first = module.expressions.append(0)
            let second = module.expressions.append(0)
            _ = reference.expressions.append(0)
            _ = reference.expressions.append(0)
            if reserved {
                module.constants.reserveSlots(module.expressions.count)
                reference.constants.reserveSlots(reference.expressions.count)
            }
            module.constants.set(ConstantValue.uint32(1), for: first)
            reference.constants.set(Optional(ConstantValue.uint32(1)), for: first)
            module.constants.set(ConstantValue.uint32(2), for: first)
            reference.constants.set(Optional(ConstantValue.uint32(2)), for: first)
            module.openScope()
            reference.openScope()
            module.cacheEvaluatedConstantValue(.uint32(3), for: second)
            reference.cacheEvaluatedConstantValue(.uint32(3), for: second)
            module.rollback()
            reference.rollback()
            module.constants.set(ConstantValue.uint32(4), for: second)
            reference.constants.set(Optional(ConstantValue.uint32(4)), for: second)

            #expect(module.constantValue(of: first) == .uint32(2))
            #expect(module.constantValue(of: second) == .uint32(4))
            #expect(reference.constantValue(of: first) == .uint32(2))
            #expect(reference.constantValue(of: second) == .uint32(4))
            #expect(module.constants.valuesCount == reference.constants.valuesCount)
            #expect(module.constants.stickyCount == 1)
            #expect(reference.constants.stickyCount == 1)
        }
    }
}
