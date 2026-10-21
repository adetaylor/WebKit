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

private enum BudgetKind: Sendable {
    case parse
    case compositeType
    case expression
    case failure
}

// One C++ depth check: its budget, the span the C++ reports if the check fails (CURRENT_SOURCE_SPAN() in the parser,
// expression.span() in GraphBuilder), and optionally a parse level entered and left before the next check (an if's
// condition expression). `.failure` throws an unrelated error, as a FAIL deeper in the parser does.
private struct BudgetCheck: Sendable {
    var budget: BudgetKind
    var span: SourceSpan
    var sibling: SourceSpan?

    init(_ budget: BudgetKind, _ span: SourceSpan, sibling: SourceSpan? = nil) {
        self.budget = budget
        self.span = span
        self.sibling = sibling
    }
}

// The C++ recursion of an input reduced to its depth checks: each check runs inside the previous one, with the budgets
// used exactly as the C++ uses SetForScope.
private struct NestedBudgetChecks: ~Copyable {
    var parseDepth = ParseDepth()
    var compositeTypeDepth = CompositeTypeNesting()
    var expressionDepth = GlobalSortingExpressionDepth()
    var expectedError: CompilationMessage?
    var deepest: UInt32 = 0

    mutating func runBudgetChecks(_ checks: [BudgetCheck], _ index: Int) throws(CompilationMessage) {
        guard index < checks.count else {
            return
        }
        let check = checks[index]
        switch check.budget {
        case .parse:
            let parseDepthLevel = try parseDepth.enter(check.span)
            defer { parseDepth.leave(parseDepthLevel) }
            deepest = max(deepest, parseDepth.depth)
            if let sibling = check.sibling {
                let siblingLevel = try parseDepth.enter(sibling)
                parseDepth.leave(siblingLevel)
            }
            try runBudgetChecks(checks, index + 1)
        case .compositeType:
            let compositeTypeDepthLevel = try compositeTypeDepth.enter(check.span)
            defer { compositeTypeDepth.leave(compositeTypeDepthLevel) }
            deepest = max(deepest, compositeTypeDepth.depth)
            try runBudgetChecks(checks, index + 1)
        case .expression:
            guard let expressionDepthLevel = expressionDepth.enter() else {
                expectedError = GlobalSortingExpressionDepth.limitError(at: check.span)
                return
            }
            defer { expressionDepth.leave(expressionDepthLevel) }
            deepest = max(deepest, expressionDepth.depth)
            try runBudgetChecks(checks, index + 1)
        case .failure:
            throw CompilationMessage("unrelated failure", span: check.span)
        }
    }
}

private struct BudgetOutcome: Sendable {
    var error: CompilationMessage?
    var deepest: UInt32
    var depthsAfterwards: [UInt32]
}

// Deep nesting runs on the compile thread: the -Onone frames of 512 levels do not fit Swift Testing's 512 KiB threads.
private func runBudgetChecks(_ checks: [BudgetCheck], sourceLocation: SourceLocation = #_sourceLocation) -> BudgetOutcome {
    let outcome = onCompileThread { _ in
        var nested = NestedBudgetChecks()
        var error: CompilationMessage?
        do throws(CompilationMessage) {
            try nested.runBudgetChecks(checks, 0)
        } catch let thrown {
            error = thrown
        }
        let depthsAfterwards = [nested.parseDepth.depth, nested.compositeTypeDepth.depth, nested.expressionDepth.depth]
        return BudgetOutcome(error: error ?? nested.expectedError, deepest: nested.deepest, depthsAfterwards: depthsAfterwards)
    }
    #expect(outcome.depthsAfterwards == [0, 0, 0], "a budget was not restored", sourceLocation: sourceLocation)
    return outcome
}

private func budgetSpan(_ line: UInt32, _ lineOffset: UInt32, _ offset: UInt32, _ length: UInt32) -> SourceSpan {
    SourceSpan(line: line, lineOffset: lineOffset, offset: offset, length: length)
}

private func budgetChecks(_ budget: BudgetKind, count: Int) -> [BudgetCheck] {
    (0..<count).map { BudgetCheck(budget, budgetSpan(1, UInt32($0), UInt32($0), 1)) }
}

private func expectBudgetError(
    _ error: CompilationMessage?,
    _ message: String,
    _ expectedSpan: SourceSpan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    expectMessage(error, message, sourceLocation: sourceLocation)
    #expect(error?.span == expectedSpan, sourceLocation: sourceLocation)
}

// Spans in UTF-16 code units, as the C++ lexer counts them; only "\n" starts a line.
private struct BudgetSourceLocator {
    let source: [UInt16]

    init(_ text: String) {
        source = Array(text.utf16)
    }

    func span(_ start: Int, _ end: Int) -> SourceSpan {
        var line: UInt32 = 1
        var lineStart = 0
        var index = 0
        while index < start {
            if source[index] == 0x0A {
                line += 1
                lineStart = index + 1
            }
            index += 1
        }
        return SourceSpan(line: line, lineOffset: UInt32(start - lineStart), offset: UInt32(start), length: UInt32(end - start))
    }

    func at(_ offset: Int) -> SourceSpan {
        span(offset, offset)
    }

    func offsets(of pattern: String, from start: Int = 0) -> [Int] {
        let units = Array(pattern.utf16)
        var result: [Int] = []
        var index = start
        while index + units.count <= source.count {
            if source[index..<index + units.count].elementsEqual(units) {
                result.append(index)
            }
            index += 1
        }
        return result
    }
}

private func repeatedText(_ text: String, _ count: Int) -> String {
    String(repeating: text, count: count)
}

@Suite
struct WGSLRecursionBudgetTests {
    // MARK: - Limits

    @Test
    func parseDepthAllowsExactly128NestedLevels() {
        #expect(ParseDepth.limit == 128)
        let outcome = runBudgetChecks(budgetChecks(.parse, count: 128))
        #expect(outcome.error == nil)
        #expect(outcome.deepest == 128)
    }

    @Test
    func parseDepthRejectsThe129thNestedLevel() {
        let outcome = runBudgetChecks(budgetChecks(.parse, count: 129))
        expectBudgetError(outcome.error, "maximum parser recursive depth reached", budgetSpan(1, 128, 128, 1))
        #expect(outcome.deepest == 128)
    }

    @Test
    func compositeTypeNestingAllowsExactly15NestedLevels() {
        #expect(CompositeTypeNesting.limit == 15)
        let outcome = runBudgetChecks(budgetChecks(.compositeType, count: 15))
        #expect(outcome.error == nil)
        #expect(outcome.deepest == 15)
    }

    @Test
    func compositeTypeNestingRejectsThe16thNestedLevel() {
        let outcome = runBudgetChecks(budgetChecks(.compositeType, count: 16))
        expectBudgetError(outcome.error, "composite type may not be nested more than 15 levels", budgetSpan(1, 15, 15, 1))
        #expect(outcome.deepest == 15)
    }

    @Test
    func globalSortingExpressionDepthAllowsExactly512NestedLevels() {
        #expect(GlobalSortingExpressionDepth.limit == 512)
        let outcome = runBudgetChecks(budgetChecks(.expression, count: 512))
        #expect(outcome.error == nil)
        #expect(outcome.deepest == 512)
    }

    @Test
    func globalSortingExpressionDepthRejectsThe513thNestedLevel() {
        let outcome = runBudgetChecks(budgetChecks(.expression, count: 513))
        expectBudgetError(outcome.error, "reached maximum expression depth of 512", budgetSpan(1, 512, 512, 1))
        #expect(outcome.deepest == 512)
    }

    @Test
    func messagesSpellTheLimits() {
        let at = budgetSpan(3, 4, 20, 5)
        expectBudgetError(ParseDepth.limitError(at: at), "maximum parser recursive depth reached", at)
        expectBudgetError(
            CompositeTypeNesting.limitError(at: at),
            "composite type may not be nested more than " + String(CompositeTypeNesting.limit) + " levels",
            at
        )
        expectBudgetError(
            GlobalSortingExpressionDepth.limitError(at: at),
            "reached maximum expression depth of " + String(GlobalSortingExpressionDepth.limit),
            at
        )
    }

    // MARK: - SetForScope semantics

    @Test
    func budgetsAreRestoredWhenAnEnclosedCheckFails() {
        var mixed = budgetChecks(.parse, count: 100) + budgetChecks(.compositeType, count: 10) + budgetChecks(.expression, count: 300)
        mixed.append(BudgetCheck(.failure, budgetSpan(9, 9, 9, 9)))
        let outcome = runBudgetChecks(mixed)
        expectBudgetError(outcome.error, "unrelated failure", budgetSpan(9, 9, 9, 9))
    }

    @Test
    func aFailedCheckDoesNotPoisonTheBudget() {
        let parseDepthResults = onCompileThread { _ in
            var parseDepth = ParseDepth()
            let tooDeep = nestBudget(&parseDepth, 200)
            let depthAfterTooDeep = parseDepth.depth
            let deepEnough = nestBudget(&parseDepth, 128)
            return (tooDeep, depthAfterTooDeep, deepEnough, parseDepth.depth)
        }
        expectBudgetError(parseDepthResults.0, "maximum parser recursive depth reached", budgetSpan(1, 0, 0, 0))
        #expect(parseDepthResults.1 == 0)
        #expect(parseDepthResults.2 == nil)
        #expect(parseDepthResults.3 == 0)

        let expressionDepthResults = onCompileThread { _ in
            var expressionDepth = GlobalSortingExpressionDepth()
            let tooDeep = nestBudget(&expressionDepth, 1000)
            let deepEnough = nestBudget(&expressionDepth, 512)
            return (tooDeep, deepEnough, expressionDepth.depth)
        }
        #expect(expressionDepthResults.0 == false)
        #expect(expressionDepthResults.1)
        #expect(expressionDepthResults.2 == 0)
    }

    @Test
    func siblingLevelsDoNotAccumulate() {
        var parseDepth = ParseDepth()
        var compositeTypeDepth = CompositeTypeNesting()
        var expressionDepth = GlobalSortingExpressionDepth()
        for _ in 0..<1000 {
            do {
                let parseDepthLevel = try parseDepth.enter(budgetSpan(1, 0, 0, 0))
                parseDepth.leave(parseDepthLevel)
                let compositeTypeDepthLevel = try compositeTypeDepth.enter(budgetSpan(1, 0, 0, 0))
                compositeTypeDepth.leave(compositeTypeDepthLevel)
            } catch {
                Issue.record("ParseDepth or CompositeTypeNesting accumulated sibling levels")
                return
            }
            guard let expressionDepthLevel = expressionDepth.enter() else {
                Issue.record("GlobalSortingExpressionDepth accumulated sibling levels")
                return
            }
            expressionDepth.leave(expressionDepthLevel)
        }
        #expect(parseDepth.depth == 0 && compositeTypeDepth.depth == 0 && expressionDepth.depth == 0)
    }

    @Test
    func leaveRestoresTheDepthAtEnter() throws {
        var parseDepth = ParseDepth()
        let outer = try parseDepth.enter(budgetSpan(1, 0, 0, 0))
        let inner = try parseDepth.enter(budgetSpan(1, 0, 0, 0))
        #expect(parseDepth.depth == 2)
        parseDepth.leave(inner)
        #expect(parseDepth.depth == 1)
        parseDepth.leave(inner)
        #expect(parseDepth.depth == 1)
        parseDepth.leave(outer)
        #expect(parseDepth.depth == 0)
    }

    // MARK: - The C++ results

    // `_ = !!…!true;`: parseStatement, then parseUnaryExpression for each `!`.
    @Test
    func cxxUnaryChain() {
        let source = BudgetSourceLocator("fn f() {\n  _ = " + repeatedText("!", 200) + "true;\n}\n")
        var nested = [BudgetCheck(.parse, source.at(source.offsets(of: "_")[0]))]
        nested += source.offsets(of: "!").map { BudgetCheck(.parse, source.at($0)) }
        nested.append(BudgetCheck(.parse, source.at(source.offsets(of: "true")[0])))
        expectBudgetError(runBudgetChecks(nested).error, "maximum parser recursive depth reached", budgetSpan(2, 133, 142, 0))
    }

    // `{{…}}` in a function body: parseStatement for each `{`.
    @Test
    func cxxNestedCompoundStatements() {
        let source = BudgetSourceLocator("fn f() {\n" + repeatedText("{", 200) + repeatedText("}", 200) + "\n}\n")
        let nested = source.offsets(of: "{", from: 9).map { BudgetCheck(.parse, source.at($0)) }
        expectBudgetError(runBudgetChecks(nested).error, "maximum parser recursive depth reached", budgetSpan(2, 128, 137, 0))
    }

    // `g(g(…1…))`: parseUnaryExpression for each `g`, parseArgumentExpressionList for each `(`.
    @Test
    func cxxNestedCalls() {
        let text = "fn g(x: i32) -> i32 { return x; }\nfn f() {\n  _ = " + repeatedText("g(", 100) + "1" + repeatedText(")", 100) + ";\n}\n"
        let source = BudgetSourceLocator(text)
        let body = source.offsets(of: "_")[0]
        var nested = [BudgetCheck(.parse, source.at(body))]
        for call in source.offsets(of: "g(", from: body) {
            nested.append(BudgetCheck(.parse, source.at(call)))
            nested.append(BudgetCheck(.parse, source.at(call + 1)))
        }
        expectBudgetError(runBudgetChecks(nested).error, "maximum parser recursive depth reached", budgetSpan(3, 133, 176, 0))
    }

    // `*&*&…x = 2;`: parseStatement, then parseLHSExpression for each `*`, `&` and `x`.
    @Test
    func cxxLeftHandSideChain() {
        let source = BudgetSourceLocator("fn f() {\n  var x = 1;\n  " + repeatedText("*&", 100) + "x = 2;\n}\n")
        let statement = source.offsets(of: "*")[0]
        var nested = [BudgetCheck(.parse, source.at(statement))]
        nested += (statement...(statement + 200)).map { BudgetCheck(.parse, source.at($0)) }
        expectBudgetError(runBudgetChecks(nested).error, "maximum parser recursive depth reached", budgetSpan(3, 129, 151, 0))
    }

    // `if true {} else if true {} …`: each else-if is a level spanning from the first `if`; its condition's
    // parseUnaryExpression is one deeper, so it reaches the limit first.
    @Test
    func cxxElseIfChain() {
        let source = BudgetSourceLocator("fn f() {\n  if true {}" + repeatedText(" else if true {}", 200) + "\n}\n")
        let ifs = source.offsets(of: "if")
        let conditions = source.offsets(of: "true")
        var nested = [BudgetCheck(.parse, source.at(ifs[0]), sibling: source.at(conditions[0]))]
        for index in 1..<ifs.count {
            nested.append(BudgetCheck(.parse, source.span(ifs[0], ifs[index]), sibling: source.at(conditions[index])))
        }
        expectBudgetError(runBudgetChecks(nested).error, "maximum parser recursive depth reached", budgetSpan(2, 2037, 2046, 0))
    }

    // `array<array<…u32>>`: parseArrayType checks at each `<`, after `array` was consumed.
    @Test
    func cxxNestedArrayTypes() {
        let text = "alias T = " + repeatedText("array<", 16) + "u32" + repeatedText(">", 16) + ";\n"
        let source = BudgetSourceLocator(text)
        let nested = source.offsets(of: "<").map { BudgetCheck(.compositeType, source.at($0)) }
        expectBudgetError(runBudgetChecks(nested).error, "composite type may not be nested more than 15 levels", budgetSpan(1, 105, 105, 0))
        let fifteen = BudgetSourceLocator("alias T = " + repeatedText("array<", 15) + "u32" + repeatedText(">", 15) + ";\n")
        #expect(runBudgetChecks(fifteen.offsets(of: "<").map { BudgetCheck(.compositeType, fifteen.at($0)) }).error == nil)
    }

    // `vec2<vec2<…f32>>`: parseTypeNameAfterIdentifier spans from the type name to its `<`.
    @Test
    func cxxNestedElaboratedTypes() {
        let source = BudgetSourceLocator("alias T = " + repeatedText("vec2<", 16) + "f32" + repeatedText(">", 16) + ";\n")
        let nested = source.offsets(of: "vec2<").map { BudgetCheck(.compositeType, source.span($0, $0 + 4)) }
        expectBudgetError(runBudgetChecks(nested).error, "composite type may not be nested more than 15 levels", budgetSpan(1, 85, 85, 4))
    }

    // `const c = 1 + 1 + …;`: a left-deep BinaryExpression chain. Every binary node spans from the first `+` to the
    // token after its right operand; the innermost left operand is the literal `1 `.
    @Test
    func cxxBinaryChains() {
        func binaryChain(_ text: String) -> [BudgetCheck] {
            let source = BudgetSourceLocator(text)
            let pluses = source.offsets(of: "+")
            let end = source.offsets(of: ";")[0]
            var nested: [BudgetCheck] = []
            for operation in stride(from: pluses.count, through: 1, by: -1) {
                let next = operation < pluses.count ? pluses[operation] : end
                nested.append(BudgetCheck(.expression, source.span(pluses[0], next)))
            }
            nested.append(BudgetCheck(.expression, source.span(pluses[0] - 2, pluses[0])))
            return nested
        }
        #expect(runBudgetChecks(binaryChain("const c = 1" + repeatedText(" + 1", 511) + ";\n")).error == nil)
        let message = "reached maximum expression depth of 512"
        expectBudgetError(
            runBudgetChecks(binaryChain("const c = 1" + repeatedText(" + 1", 512) + ";\n")).error,
            message,
            budgetSpan(1, 10, 10, 2)
        )
        expectBudgetError(
            runBudgetChecks(binaryChain("const c = 1" + repeatedText(" + 1", 600) + ";\n")).error,
            message,
            budgetSpan(1, 12, 12, 352)
        )
    }
}

// The error of `count` nested ParseDepth levels, if any.
private func nestBudget(_ parseDepth: inout ParseDepth, _ count: Int) -> CompilationMessage? {
    do {
        try nestParseDepthThrowing(&parseDepth, count)
        return nil
    } catch {
        return error
    }
}

private func nestParseDepthThrowing(_ parseDepth: inout ParseDepth, _ count: Int) throws(CompilationMessage) {
    guard count > 0 else {
        return
    }
    let parseDepthLevel = try parseDepth.enter(budgetSpan(1, 0, 0, 0))
    defer { parseDepth.leave(parseDepthLevel) }
    try nestParseDepthThrowing(&parseDepth, count - 1)
}

private func nestBudget(_ expressionDepth: inout GlobalSortingExpressionDepth, _ count: Int) -> Bool {
    guard count > 0 else {
        return true
    }
    guard let expressionDepthLevel = expressionDepth.enter() else {
        return false
    }
    defer { expressionDepth.leave(expressionDepthLevel) }
    return nestBudget(&expressionDepth, count - 1)
}
