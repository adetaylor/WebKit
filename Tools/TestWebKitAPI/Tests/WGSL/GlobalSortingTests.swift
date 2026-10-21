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

private struct CxxError: Sendable {
    let message: String
    let span: SourceSpan

    init(_ message: String, _ span: SourceSpan) {
        self.message = message
        self.span = span
    }
}

private struct CxxCase: Sendable {
    let name: String
    let source: String
    let error: CxxError?
    let dump: String

    init(_ name: String, source: String, error: CxxError?, dump: String) {
        self.name = name
        self.source = source
        self.error = error
        self.dump = dump
    }
}

// Each `error` and `dump` is what the C++ compiler reported and its `AST::StringDumper` printed for `source` after
// reorderGlobals.
private let cxxCases: [CxxCase] = [
    CxxCase(
        "an identifier expression adds an edge",
        source: """
            const a = b;
            const b = 1;

            """,
        error: nil,
        dump: """
            var b = 1;
            var a = b;

            """
    ),
    CxxCase(
        "a diamond follows the incoming edges in order",
        source: """
            const a = b + c;
            const b = d;
            const c = d;
            const d = 1;

            """,
        error: nil,
        dump: """
            var d = 1;
            var b = d;
            var c = d;
            var a = b + c;

            """
    ),
    CxxCase(
        "the declarations a declaration frees are processed depth first",
        source: """
            const a = b;
            const b = c;
            const x = c;
            const c = 1;

            """,
        error: nil,
        dump: """
            var c = 1;
            var b = c;
            var a = b;
            var x = c;

            """
    ),
    CxxCase(
        "a declaration freed by an earlier root waits for its own index",
        source: """
            const r = 1;
            const q = 1;
            const s = r;

            """,
        error: nil,
        dump: """
            var r = 1;
            var q = 1;
            var s = r;

            """
    ),
    CxxCase(
        "each root processes the declarations it frees",
        source: """
            const z = 1;
            const b = a;
            const a = 1;
            const c = b + a;

            """,
        error: nil,
        dump: """
            var z = 1;
            var a = 1;
            var b = a;
            var c = b + a;

            """
    ),
    CxxCase(
        "calls",
        source: """
            fn g() -> i32 { return f(); }
            fn f() -> i32 { return c; }
            const c = 1;
            fn h() { _ = g(); _ = f(); }

            """,
        error: nil,
        dump: """
            var c = 1;
            fn f() ->  i32
            {
                return c;
            }

            fn g() ->  i32
            {
                return f();
            }

            fn h()
            {
                _ = g();
                _ = f();
            }


            """
    ),
    CxxCase(
        "attributes, overrides, structs, aliases and module-scope variables",
        source: """
            @compute @workgroup_size(w) fn main() {}
            override w: u32 = c;
            const c = 1u;
            struct S { x: array<i32, c> }
            alias T = S;
            var<private> p: T;

            """,
        error: nil,
        dump: """
            var c = 1u;
            var w: u32 = c;
            @compute @workgroup_size(w)
            fn main()
            {}

            struct S {
                x: array<i32, c>
            }

            alias T = S;
            var<private,read_write> p: T;

            """
    ),
    CxxCase(
        "struct member and override attributes",
        source: """
            struct S { @align(a) @size(c) x: i32 }
            const c = 8;
            const a = 4;
            @id(c) override o: u32;

            """,
        error: nil,
        dump: """
            var c = 8;
            var a = 4;
            struct S {
                a c x: i32
            }

            c var o: u32;

            """
    ),
    CxxCase(
        "a const_assert after what it reads",
        source: """
            const_assert a == 1;
            const a = 1;

            """,
        error: nil,
        dump: """
            var a = 1;
            a == 1

            """
    ),
    CxxCase(
        "const_asserts are never targets",
        source: """
            const a = b;
            const_assert a == 1;
            const b = c;
            const c = 1;
            const d = a + b + c;

            """,
        error: nil,
        dump: """
            var c = 1;
            var b = c;
            var a = b;
            a == 1
            var d = a + b + c;

            """
    ),
    CxxCase(
        "a parameter shadows a global (Parameter hook)",
        source: """
            fn f(a: i32) -> i32 { return a; }
            const a = 1;

            """,
        error: nil,
        dump: """
            fn f(
                a: i32
            ) ->  i32
            {
                return a;
            }

            var a = 1;

            """
    ),
    CxxCase(
        "a parameter type is visited",
        source: """
            fn f(a: T) {}
            alias T = i32;

            """,
        error: nil,
        dump: """
            alias T = i32;
            fn f(
                a: T
            )
            {}


            """
    ),
    CxxCase(
        "a local shadows a global (VariableStatement hook)",
        source: """
            fn f() { let a = 2; _ = a; }
            const a = 1;

            """,
        error: nil,
        dump: """
            fn f()
            {
                var a = 2;
                _ = a;
            }

            var a = 1;

            """
    ),
    CxxCase(
        "a local initializer reads a global",
        source: """
            fn f() { let b = a; _ = b; }
            const a = 1;

            """,
        error: nil,
        dump: """
            var a = 1;
            fn f()
            {
                var b = a;
                _ = b;
            }


            """
    ),
    CxxCase(
        "a local is introduced before its initializer is visited",
        source: """
            fn f() { let a = a; }
            const a = 1;

            """,
        error: nil,
        dump: """
            fn f()
            {
                var a = a;
            }

            var a = 1;

            """
    ),
    CxxCase(
        "a compound statement scope ends at its brace",
        source: """
            fn f() { { let a = 1; _ = a; } _ = a; }
            const a = 1;

            """,
        error: nil,
        dump: """
            var a = 1;
            fn f()
            {
                {
                    var a = 1;
                    _ = a;
                }

                _ = a;
            }


            """
    ),
    CxxCase(
        "a for statement scope ends with the loop",
        source: """
            fn f() { for (var i = 0; i < 1; i++) { _ = i; } _ = i; }
            const i = 1;

            """,
        error: nil,
        dump: """
            var i = 1;
            fn f()
            {
            for (    var i = 0;;i < 1;    i++;)    {
                    _ = i;
                }

                _ = i;
            }


            """
    ),
    CxxCase(
        "continuing sees the loop body",
        source: """
            fn f() { loop { let a = 1; continuing { _ = a; break if b; } } }
            const a = 1;
            const b = true;

            """,
        error: nil,
        dump: """
            var a = 1;
            var b = true;
            fn f()
            {
                var a = 1;    _ = a;b
            }


            """
    ),
    CxxCase(
        "while, switch and if scopes",
        source: """
            fn f() { let a = 1; while (a < b) { let b = 2; _ = b; } switch a { case 1: { let c = a; _ = c; } default: { _ = c; } } if a > 0 { let d = 1; } else { _ = d; } }
            const b = 1;
            const c = 2;
            const d = 3;

            """,
        error: nil,
        dump: """
            var b = 1;
            var c = 2;
            var d = 3;
            fn f()
            {
                var a = 1;
            a < b    {
                    var b = 2;
                    _ = b;
                }

            a1    {
                    var c = a;
                    _ = c;
                }
                {
                    _ = c;
                }

                if a > 0
                {
                    var d = 1;
                }
                else
                {
                    _ = d;
                }

            }


            """
    ),
    CxxCase(
        "module-scope variables",
        source: """
            var<private> x: i32 = y;
            var<private> y: i32 = 1;
            fn f(x: i32) -> i32 { var y = x; return y; }

            """,
        error: nil,
        dump: """
            var<private,read_write> y: i32 = 1;
            var<private,read_write> x: i32 = y;
            fn f(
                x: i32
            ) ->  i32
            {
                var y = x;
                return y;
            }


            """
    ),
    CxxCase(
        "identifiers compare by code units",
        source: """
            const \u{E9} = 1;
            const b = \u{E9};

            """,
        error: nil,
        dump: """
            var \u{E9} = 1;
            var b = \u{E9};

            """
    ),
    CxxCase(
        "redeclaration",
        source: """
            const a = 1;
            const a = 2;

            """,
        error: CxxError("redeclaration of 'a'", SourceSpan(line: 2, lineOffset: 0, offset: 13, length: 11)),
        dump: """
            var a = 1;
            var a = 2;

            """
    ),
    CxxCase(
        "redeclaration across kinds (TypeCheckingTests Redeclaration)",
        source: "struct f { x: i32 }override f = 1;fn f() { }",
        error: CxxError("redeclaration of 'f'", SourceSpan(line: 1, lineOffset: 19, offset: 19, length: 14)),
        dump: """
            struct f {
                x: i32
            }

            var f = 1;
            fn f()
            {}


            """
    ),
    CxxCase(
        "redeclaration after a forward reference (TypeCheckingTests Reordering)",
        source: "const y = x * 2;const y = 2;",
        error: CxxError("redeclaration of 'y'", SourceSpan(line: 1, lineOffset: 16, offset: 16, length: 11)),
        dump: """
            var y = x * 2;
            var y = 2;

            """
    ),
    CxxCase(
        "a self-referencing constant (TypeCheckingTests Reordering)",
        source: "const a = a * 2;",
        error: CxxError("encountered a dependency cycle: a -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 15)),
        dump: ""
    ),
    CxxCase(
        "a recursive function (TypeCheckingTests Reordering)",
        source: "fn f() { f(); };",
        error: CxxError("encountered a dependency cycle: f -> f", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 15)),
        dump: ""
    ),
    CxxCase(
        "a recursive struct (TypeCheckingTests Reordering)",
        source: "struct S { s: S }",
        error: CxxError("encountered a dependency cycle: S -> S", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 17)),
        dump: ""
    ),
    CxxCase(
        "a constant and a struct (TypeCheckingTests Reordering)",
        source: "const a = S(array(1)); struct S { x: array<i32, a.x[0]> };",
        error: CxxError("encountered a dependency cycle: a -> S -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 21)),
        dump: ""
    ),
    CxxCase(
        "a four-constant cycle (TypeCheckingTests Reordering)",
        source: "const y = x * 2;const z = y;const w = z;const x = w;",
        error: CxxError("encountered a dependency cycle: y -> x -> w -> z -> y", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 15)),
        dump: ""
    ),
    CxxCase(
        "a two-declaration cycle",
        source: """
            const a = b;
            const b = a;

            """,
        error: CxxError("encountered a dependency cycle: a -> b -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 11)),
        dump: ""
    ),
    CxxCase(
        "a self edge",
        source: """
            const a = a;

            """,
        error: CxxError("encountered a dependency cycle: a -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 11)),
        dump: ""
    ),
    CxxCase(
        "duplicate and self edges",
        source: """
            const a = b + b + a;
            const b = 1;

            """,
        error: CxxError("encountered a dependency cycle: a -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 19)),
        dump: """
            var b = 1;

            """
    ),
    CxxCase(
        "the cycle walk follows the first outgoing edge",
        source: """
            const a = b + c;
            const b = a;
            const c = a;

            """,
        error: CxxError("encountered a dependency cycle: a -> b -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 15)),
        dump: ""
    ),
    CxxCase(
        "the cycle walk skips removed edges",
        source: """
            const a = c + b;
            const b = a;
            const c = 1;

            """,
        error: CxxError("encountered a dependency cycle: a -> b -> a", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 15)),
        dump: """
            var c = 1;

            """
    ),
    CxxCase(
        "the cycle starts at the first revisited declaration",
        source: """
            const t = a;
            const a = b;
            const b = c;
            const c = a;

            """,
        error: CxxError("encountered a dependency cycle: a -> b -> c -> a", SourceSpan(line: 2, lineOffset: 0, offset: 13, length: 11)),
        dump: ""
    ),
    CxxCase(
        "the cycle walk starts at a const_assert",
        source: """
            const_assert a == 1;
            const a = b;
            const b = a;

            """,
        error: CxxError("encountered a dependency cycle: a -> b -> a", SourceSpan(line: 2, lineOffset: 0, offset: 21, length: 11)),
        dump: ""
    ),
    CxxCase(
        "a cycle message spells identifiers by code units",
        source: """
            const \u{E9} = \u{E9};

            """,
        error: CxxError("encountered a dependency cycle: \u{E9} -> \u{E9}", SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 11)),
        dump: ""
    ),
]

/// The module after `parse` and `reorderGlobals`.
private struct SortedModule: Sendable {
    var parseErrors: [CompilationMessage] = []
    /// The declarations' spans before sorting.
    var spans: [SourceSpan] = []
    var unsortedDump = ""
    var errors: [CompilationMessage] = []
    var warnings: [CompilationMessage] = []
    /// The declarations' names after sorting, as GlobalSorting.cpp's `nameForDeclaration`.
    var names: [String] = []
    var dump = ""
}

private func sortGlobals(_ source: String, dumps: Bool = true) -> SortedModule {
    var sorted = SortedModule()
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        sorted.parseErrors = failure.errors
        return sorted
    }
    for index in 0..<module.count(module.declarations) {
        sorted.spans.append(module.span(of: module[module.declarations, index]))
    }
    if dumps {
        sorted.unsortedDump = ASTStringDumper.dump(module)
    }
    if let failure = reorderGlobals(&module) {
        sorted.errors = failure.errors
        sorted.warnings = failure.warnings
    }
    for index in 0..<module.count(module.declarations) {
        sorted.names.append(name(module, module[module.declarations, index]))
    }
    if dumps {
        sorted.dump = ASTStringDumper.dump(module)
    }
    return sorted
}

private func name(_ module: borrowing ShaderModule, _ declaration: Declaration) -> String {
    if case .constAssert = declaration {
        return "const_assert"
    }
    return String(decoding: module.symbols.codeUnits(of: module.symbol(of: module.name(of: declaration))), as: UTF16.self)
}

private func expectError(
    _ sorted: SortedModule,
    _ message: String,
    _ span: SourceSpan,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(sorted.errors.map(\.message) == [message], comment, sourceLocation: sourceLocation)
    #expect(sorted.errors.map(\.span) == [span], comment, sourceLocation: sourceLocation)
    #expect(sorted.warnings.isEmpty, comment, sourceLocation: sourceLocation)
}

// MARK: - Random dependency graphs

private struct SplitMix64: RandomNumberGenerator {
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

/// Declarations `c0`, `c1`, …, each a `const` or a `fn` that reads its `targets` in order, so GraphBuilder adds the
/// edges source by source in read order, with repeats (duplicate edges) and self-reads (self edges).
private struct RandomGraph: Sendable {
    var targets: [[Int]]
    var isFunction: [Bool]

    init(_ generator: inout SplitMix64) {
        let count = 1 + generator.below(12)
        targets = Array(repeating: [], count: count)
        isFunction = (0..<count).map { _ in generator.below(2) == 0 }
        // 0: any edge; 1: forward edges only; 2: backward edges only (both acyclic).
        let shape = generator.below(3)
        for _ in 0..<generator.below(3 * count + 1) {
            let source = generator.below(count)
            switch shape {
            case 1:
                if source < count - 1 {
                    targets[source].append(source + 1 + generator.below(count - 1 - source))
                }
            case 2:
                if source > 0 {
                    targets[source].append(generator.below(source))
                }
            default:
                targets[source].append(generator.below(count))
            }
        }
    }

    var source: String {
        var text = ""
        for index in targets.indices {
            if isFunction[index] {
                text += "fn c\(index)() {"
                for target in targets[index] {
                    text += " _ = c\(target);"
                }
                text += " }\n"
            } else if targets[index].isEmpty {
                text += "const c\(index) = 0;\n"
            } else {
                text += "const c\(index) = " + targets[index].map { "c\($0)" }.joined(separator: " + ") + ";\n"
            }
        }
        return text
    }
}

/// GlobalSorting.cpp:259-338 on the graph of a `RandomGraph`, with the C++'s recursive `processNode` and ListHashSet
/// edge sets.
private struct RecursiveTranscription {
    var edges: [(source: Int, target: Int)] = []
    var incomingEdges: [[Int]]
    var outgoingEdges: [[Int]]
    var isRemoved: [Bool] = []

    init(_ targets: [[Int]]) {
        incomingEdges = Array(repeating: [], count: targets.count)
        outgoingEdges = Array(repeating: [], count: targets.count)
        for source in targets.indices {
            for target in targets[source] where !edges.contains(where: { $0.source == source && $0.target == target }) {
                outgoingEdges[source].append(edges.count)
                incomingEdges[target].append(edges.count)
                edges.append((source, target))
                isRemoved.append(false)
            }
        }
    }

    func hasOutgoingEdges(_ node: Int) -> Bool {
        outgoingEdges[node].contains { !isRemoved[$0] }
    }

    func firstOutgoingTarget(_ node: Int) -> Int? {
        outgoingEdges[node].first { !isRemoved[$0] }.map { edges[$0].target }
    }

    mutating func processNode(_ node: Int, _ currentIndex: Int, _ list: inout [Int]) {
        list.append(node)
        for edge in incomingEdges[node] {
            let source = edges[edge].source
            isRemoved[edge] = true
            if !hasOutgoingEdges(source) && source < currentIndex {
                processNode(source, currentIndex, &list)
            }
        }
    }

    /// The sorted declarations and, for a cycle, its message and the declaration whose span it has.
    mutating func reorder() -> (list: [Int], cycle: (message: String, node: Int)?) {
        var list: [Int] = []
        for node in incomingEdges.indices where !hasOutgoingEdges(node) {
            processNode(node, node, &list)
        }
        if isRemoved.allSatisfy({ $0 }) {
            return (list, nil)
        }
        guard var node = incomingEdges.indices.first(where: { hasOutgoingEdges($0) }) else {
            Issue.record("edges remain but no declaration has one")
            return (list, nil)
        }
        var cycleNode = node
        var visited = Set<Int>()
        while true {
            visited.insert(node)
            guard let target = firstOutgoingTarget(node) else {
                Issue.record("a declaration on the path has no outgoing edge")
                return (list, nil)
            }
            node = target
            if visited.contains(node) {
                cycleNode = node
                break
            }
        }
        var message = "encountered a dependency cycle: c\(cycleNode)"
        repeat {
            guard let target = firstOutgoingTarget(node) else {
                Issue.record("a declaration on the cycle has no outgoing edge")
                return (list, nil)
            }
            node = target
            message += " -> c\(node)"
        } while node != cycleNode
        return (list, (message, cycleNode))
    }
}

private func randomGraphs(_ count: Int, seed: UInt64) -> [RandomGraph] {
    var generator = SplitMix64(state: seed)
    return (0..<count).map { _ in RandomGraph(&generator) }
}

@Suite
struct WGSLGlobalSortingTests {
    // The Parameter, VariableStatement and IdentifierExpression hooks fire in the shadowing and dependency cases.
    @Test
    func matchesTheCxx() {
        let results = onCompileThread { _ in cxxCases.map { sortGlobals($0.source) } }
        for (testCase, sorted) in zip(cxxCases, results) {
            let comment = Comment(rawValue: testCase.name)
            #expect(sorted.parseErrors.isEmpty, comment)
            if let error = testCase.error {
                expectError(sorted, error.message, error.span, comment)
            } else {
                #expect(sorted.errors.isEmpty, comment)
                #expect(sorted.warnings.isEmpty, comment)
            }
            #expect(sorted.dump == testCase.dump, comment)
        }
    }

    // The Expression hook. The spans are the C++'s; a failed pass leaves the declarations in source order.
    @Test
    func expressionDepthAllowsExactly512NestedLevels() {
        let sources = [
            "const a = 1" + String(repeating: " + 1", count: 511) + ";\n",
            "const a = 1" + String(repeating: " + 1", count: 512) + ";\n",
            "fn f() { _ = 1" + String(repeating: " + 1", count: 512) + "; }\n",
            "const a = 1;\nconst b = 1" + String(repeating: " + 1", count: 512) + ";\n",
        ]
        let results = onCompileThread { _ in sources.map { sortGlobals($0) } }
        let message = "reached maximum expression depth of 512"
        #expect(results[0].errors.isEmpty)
        expectError(results[1], message, SourceSpan(line: 1, lineOffset: 10, offset: 10, length: 2))
        expectError(results[2], message, SourceSpan(line: 1, lineOffset: 13, offset: 13, length: 2))
        expectError(results[3], message, SourceSpan(line: 2, lineOffset: 10, offset: 23, length: 2))
        for sorted in results {
            #expect(sorted.parseErrors.isEmpty)
            #expect(sorted.dump == sorted.unsortedDump)
        }
    }

    @Test
    func iterativeProcessNodeMatchesTheRecursiveTranscriptionOn5000RandomGraphs() {
        let graphs = randomGraphs(5000, seed: 42)
        let results = onCompileThread { _ in graphs.map { sortGlobals($0.source, dumps: false) } }
        var cycles = 0
        var selfEdges = 0
        var duplicateEdges = 0
        for (graph, sorted) in zip(graphs, results) {
            var transcription = RecursiveTranscription(graph.targets)
            let expected = transcription.reorder()
            #expect(sorted.parseErrors.isEmpty)
            #expect(sorted.names == expected.list.map { "c\($0)" }, "\(graph.source)")
            if let cycle = expected.cycle {
                cycles += 1
                expectError(sorted, cycle.message, sorted.spans[cycle.node], "\(graph.source)")
            } else {
                #expect(sorted.errors.isEmpty, "\(graph.source)")
            }
            for index in graph.targets.indices {
                if graph.targets[index].contains(index) {
                    selfEdges += 1
                }
                if Set(graph.targets[index]).count < graph.targets[index].count {
                    duplicateEdges += 1
                }
            }
        }
        #expect(cycles > 500 && cycles < 4500)
        #expect(selfEdges > 500)
        #expect(duplicateEdges > 500)
    }

    // These two run on the test's own thread, not `onCompileThread`: the C++ recursion is 100,000 calls deep on the chain.
    @Test
    func DEV_03_aReversedChainOf100000ConstantsSortsWithoutRecursion() {
        var source = ""
        for index in 0..<99_999 {
            source += "const c\(index) = c\(index + 1);\n"
        }
        source += "const c99999 = 0;\n"
        let sorted = sortGlobals(source, dumps: false)
        #expect(sorted.parseErrors.isEmpty)
        #expect(sorted.errors.isEmpty)
        #expect(sorted.names == (0..<100_000).reversed().map { "c\($0)" })
    }

    @Test
    func DEV_03_aCycleOf100000ConstantsIsReportedInFull() {
        var source = ""
        for index in 0..<100_000 {
            source += "const c\(index) = c\((index + 1) % 100_000);\n"
        }
        let sorted = sortGlobals(source, dumps: false)
        #expect(sorted.parseErrors.isEmpty)
        let message = "encountered a dependency cycle: " + (0...100_000).map { "c\($0 % 100_000)" }.joined(separator: " -> ")
        expectError(sorted, message, SourceSpan(line: 1, lineOffset: 0, offset: 0, length: 13))
        #expect(sorted.names.isEmpty)
    }
}
