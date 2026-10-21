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

private typealias Node = UniformityGraph.Node
private typealias FunctionInfo = UniformityGraph.FunctionInfo

private func parsedModule(_ source: String) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure)
    }
    return module
}

private func globalVariables(_ module: borrowing ShaderModule) -> [VariableID] {
    var result: [VariableID] = []
    for declaration in module.elements(module.declarations) {
        if case .variable(let variable) = declaration {
            result.append(variable)
        }
    }
    return result
}

private func firstFunction(_ module: borrowing ShaderModule) -> FunctionID? {
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration {
            return function
        }
    }
    return nil
}

/// The right-hand sides of the `_ = e;` statements of the module's first function.
private func phonyRightHandSides(_ module: borrowing ShaderModule) -> [ExpressionID] {
    guard let function = firstFunction(module) else {
        return []
    }
    var result: [ExpressionID] = []
    let body = module.downcast(CompoundStatement.self, module[function].body)
    for statement in module.elements(body.statements) {
        if let phony = module.dynamicDowncast(PhonyAssignmentStatement.self, statement) {
            result.append(phony.rhs)
        }
    }
    return result
}

private func setAddressSpace(_ module: inout ShaderModule, _ variable: VariableID, _ addressSpace: AddressSpace?, _ accessMode: AccessMode?)
{
    module.modify(variable) {
        $0.addressSpace = addressSpace
        $0.accessMode = accessMode
    }
}

/// A function graph whose outermost scope is open, as at the start of C++ processFunction's parameter loop.
private func functionInfo(_ moduleScopeVariables: UniformityGraph.ModuleScopeVariables = .init()) -> FunctionInfo {
    var info = FunctionInfo(astNode: nil, moduleScopeVariables: moduleScopeVariables)
    info.pushScope()
    return info
}

/// SplitMix64: a reproducible operation sequence for the eager/lazy comparison.
private struct SplitMix64 {
    var state: UInt64

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }
}

@Suite
struct WGSLUniformityAnalysisTests {
    @Test
    func moduleWithoutFunctions() {
        var module = parsedModule("var<private> x: i32;\nconst c = 1;\n")
        #expect(uniformityAnalysis(&module) == nil)
    }

    @Test
    func moduleWithoutFunctionsRunsBothScopes() {
        var module = parsedModule("enable subgroups;\nvar<private> x: i32;\n")
        #expect(module.enabledExtensions.contains(.subgroups))
        #expect(uniformityAnalysis(&module) == nil)
    }

    /// The statements that reach no expression: scopes, `loop` with `continuing`, `for` without a test, `break`, `return`,
    /// `discard` and pointer parameters.
    @Test
    func statementsWithoutExpressions() {
        var module = parsedModule(
            """
            var<private> g: i32;

            @compute @workgroup_size(1)
            fn main() {
                var a: i32;
                {
                    var b: i32;
                }
                {
                    var c: i32;
                    return;
                }
            }

            fn loops() {
                var a: i32;
                loop {
                    var d: i32;
                    {
                        var e: i32;
                        break;
                    }
                }
                loop {
                    var f: i32;
                    break;
                    continuing {
                        var h: i32;
                    }
                }
                for (var i: i32; ; ) {
                    var j: i32;
                    break;
                }
                for (;;) {
                    loop {
                        break;
                    }
                    break;
                }
            }

            fn pointers(p: ptr<function, i32>, q: ptr<private, i32>) {
                var k: i32;
                loop {
                    break;
                }
                return;
            }

            @fragment
            fn fs() {
                var l: i32;
                discard;
            }
            """
        )
        #expect(reorderGlobals(&module) == nil)
        #expect(typeCheck(&module) == nil)
        mangleNames(&module)
        rewriteEvaluationOrder(&module)
        rewritePointers(&module)
        #expect(uniformityAnalysis(&module) == nil)
    }

    @Test
    func functionInfoCreatesTheFixedNodesFirst() {
        let info = FunctionInfo(astNode: nil, moduleScopeVariables: .init())
        #expect(info.nodes.count == 5)
        let error = info.requiredToBeUniformForSeverity(.error)
        let warning = info.requiredToBeUniformForSeverity(.warning)
        let infoSentinel = info.requiredToBeUniformForSeverity(.info)
        #expect(info.requiredToBeUniformForSeverity(.off) == nil)
        let fixed = [error, warning, infoSentinel, info.mayBeNonUniform, info.cfStart].compactMap { $0 }
        #expect(fixed.count == 5)
        #expect(Set(fixed).count == 5)
        for node in fixed {
            #expect(info.nodes.ast(of: node) == nil)
            #expect(info.nodes.edges(of: node).isEmpty)
        }
    }

    @Test
    func edgesKeepInsertionOrder() {
        var info = functionInfo()
        let a = info.createNode()
        let b = info.createNode()
        let c = info.createNode()
        info.addEdge(a, c)
        info.addEdge(a, b)
        info.addEdge(a, c)
        info.addEdge(b, a)
        #expect(info.nodes.edges(of: a) == [c, b, c])
        #expect(info.nodes.edges(of: b) == [a])
        #expect(info.nodes.edges(of: c).isEmpty)
    }

    @Test
    func traverseReachesTheSourceAndItsSuccessors() {
        var info = functionInfo()
        let a = info.createNode()
        let b = info.createNode()
        let c = info.createNode()
        let d = info.createNode()
        let e = info.createNode()
        info.addEdge(a, b)
        info.addEdge(b, c)
        info.addEdge(c, a)
        info.addEdge(d, a)

        info.resetVisited()
        info.nodes.traverse(a)
        #expect(info.nodes.isReachable(a))
        #expect(info.nodes.isReachable(b))
        #expect(info.nodes.isReachable(c))
        #expect(!info.nodes.isReachable(d))
        #expect(!info.nodes.isReachable(e))

        info.resetVisited()
        info.nodes.traverse(e)
        #expect(info.nodes.isReachable(e))
        #expect(!info.nodes.isReachable(a))
        #expect(!info.nodes.isReachable(b))

        info.resetVisited()
        #expect(!info.nodes.isReachable(e))
        let late = info.createNode()
        info.addEdge(d, late)
        info.nodes.traverse(d)
        #expect(info.nodes.isReachable(late))
        #expect(info.nodes.isReachable(c))
        #expect(!info.nodes.isReachable(e))
    }

    @Test
    func affectsControlFlowIsOffByDefault() {
        var info = functionInfo()
        let node = info.createNode()
        #expect(!info.nodes.affectsControlFlow(node))
    }

    @Test
    func scopes() {
        let module = parsedModule("fn f(x: i32, y: i32, z: i32) {}")
        guard let function = firstFunction(module) else {
            Issue.record("no function")
            return
        }
        let names = module.elements(module[function].parameters).map { module.symbol(of: module[$0].name) }
        let (x, y, z) = (names[0], names[1], names[2])

        var info = functionInfo()
        let outerX = info.createNode()
        let outerY = info.createNode()
        info.setVariable(x, outerX)
        info.setVariable(y, outerY)

        info.pushScope()
        let innerY = info.createNode()
        let innerZ = info.createNode()
        let innerX = info.createNode()
        info.setVariable(y, innerY)
        info.setVariable(z, innerZ)
        info.setVariable(x, innerX)
        #expect(info.getVariable(x) == innerX)
        #expect(info.getVariable(y) == innerY)
        #expect(info.getVariable(z) == innerZ)

        let captured = info.popScopeCapture()
        #expect(captured.keys == [y, z, x])
        #expect(captured.find(y) == innerY)
        #expect(captured.find(x) == innerX)
        #expect(info.getVariable(x) == outerX)
        #expect(info.getVariable(y) == outerY)
        #expect(info.getVariable(z) == nil)

        var entries: [Symbol] = []
        captured.forEachEntry { name, _ in entries.append(name) }
        #expect(entries == [y, z, x])
    }

    @Test
    func variableMapKeepsInsertionOrder() {
        let module = parsedModule("fn f(a: i32, b: i32, c: i32, d: i32) {}")
        guard let function = firstFunction(module) else {
            Issue.record("no function")
            return
        }
        let names = module.elements(module[function].parameters).map { module.symbol(of: module[$0].name) }
        var info = functionInfo()
        let nodes = names.map { _ in info.createNode() }

        var map = UniformityGraph.VariableMap()
        #expect(map.isEmpty)
        #expect(map.find(names[0]) == nil)
        map.set(names[2], nodes[2])
        map.set(names[0], nodes[0])
        map.set(names[3], nodes[3])
        map.set(names[1], nodes[1])
        map.set(names[0], nodes[3])
        #expect(map.keys == [names[2], names[0], names[3], names[1]])
        #expect(map.find(names[0]) == nodes[3])
        #expect(map.count == 4)

        map.removeIf { name, _ in name == names[0] || name == names[1] }
        #expect(map.keys == [names[2], names[3]])
        #expect(!map.contains(names[0]))
        #expect(map.find(names[3]) == nodes[3])
        map.set(names[0], nodes[1])
        #expect(map.keys == [names[2], names[3], names[0]])
        #expect(map.find(names[0]) == nodes[1])
    }

    @Test
    func isGlobalNonUniform() {
        var module = parsedModule(
            """
            var<private> p: i32;
            var<workgroup> w: i32;
            var<storage, read> sr: i32;
            var<storage, read_write> srw: i32;
            var<uniform> u: i32;
            var t: i32;
            var s: i32;
            var n: i32;
            """
        )
        let variables = globalVariables(module)
        #expect(variables.count == 8)
        setAddressSpace(&module, variables[0], .private, nil)
        setAddressSpace(&module, variables[1], .workgroup, nil)
        setAddressSpace(&module, variables[2], .storage, .read)
        setAddressSpace(&module, variables[3], .storage, .readWrite)
        setAddressSpace(&module, variables[4], .uniform, nil)
        setAddressSpace(&module, variables[5], .handle, nil)
        setAddressSpace(&module, variables[6], .handle, nil)
        setAddressSpace(&module, variables[7], nil, nil)
        let writeOnly = module.types.textureStorageType(.textureStorage2d, .rgba8unorm, .write)
        let readOnly = module.types.textureStorageType(.textureStorage2d, .rgba8unorm, .read)
        module.modify(variables[5]) { $0.storeType = writeOnly }
        module.modify(variables[6]) { $0.storeType = readOnly }

        let expected = [true, true, false, true, false, true, false, false]
        for (variable, isNonUniform) in zip(variables, expected) {
            #expect(UniformityGraph.isGlobalNonUniform(module, variable) == isNonUniform)
        }

        setAddressSpace(&module, variables[2], .storage, nil)
        let storageWithoutAccessMode = UniformityGraph.isGlobalNonUniform(module, variables[2])
        #expect(!storageWithoutAccessMode)
        setAddressSpace(&module, variables[2], .function, nil)
        let function = UniformityGraph.isGlobalNonUniform(module, variables[2])
        #expect(!function)
        setAddressSpace(&module, variables[2], .storage, .write)
        let writeOnlyStorage = UniformityGraph.isGlobalNonUniform(module, variables[2])
        #expect(writeOnlyStorage)
    }

    @Test
    func rootIdentifier() {
        var module = parsedModule("fn f() { _ = a.b[0].c; _ = *p; _ = &x; _ = (y); _ = g(z); _ = 1; _ = -q[1]; }")
        let expressions = phonyRightHandSides(module)
        #expect(expressions.count == 7)

        func root(_ expression: ExpressionID) -> String? {
            guard let identifier = UniformityGraph.rootIdentifier(module, expression) else {
                return nil
            }
            return String(decoding: module.symbols.codeUnits(of: module.symbol(of: identifier.identifier)), as: UTF16.self)
        }

        #expect(root(expressions[0]) == "a")
        #expect(root(expressions[1]) == "p")
        #expect(root(expressions[2]) == "x")
        #expect(root(expressions[3]) == "y")
        #expect(root(expressions[4]) == nil)
        #expect(root(expressions[5]) == nil)
        #expect(root(expressions[6]) == "q")

        let span = module.span(of: expressions[0])
        let identity = module.constructIdentityExpression(span: span, expression: expressions[0])
        let dereference = module.construct(span: span, PointerDereferenceExpression(target: identity))
        #expect(root(identity) == "a")
        #expect(root(dereference) == "a")
    }

    @Test
    func DEV_04_moduleScopeVariableNodesAreMadeOnFirstReference() {
        var module = parsedModule(
            """
            var<private> a: i32;
            var<uniform> b: i32;
            var<private> c: i32;
            fn f(x: i32) {}
            """
        )
        let variables = globalVariables(module)
        setAddressSpace(&module, variables[0], .private, nil)
        setAddressSpace(&module, variables[1], .uniform, nil)
        setAddressSpace(&module, variables[2], .private, nil)
        let names = variables.map { module.symbol(of: module[$0].name) }
        guard let function = firstFunction(module) else {
            Issue.record("no function")
            return
        }
        let functionName = module.symbol(of: module[function].name)

        let table = UniformityGraph.collectModuleScopeVariables(module)
        #expect(table.count == 3)
        #expect(table.find(names[0])?.variable == variables[0])
        #expect(table.find(names[0])?.isNonUniform == true)
        #expect(table.find(names[1])?.isNonUniform == false)

        var info = functionInfo(table)
        #expect(info.nodes.count == 5)
        #expect(info.getVariable(functionName) == nil)
        #expect(info.nodes.count == 5)

        guard let nodeA = info.getVariable(names[0]) else {
            Issue.record("no node for a")
            return
        }
        #expect(info.nodes.count == 6)
        #expect(info.nodes.ast(of: nodeA) == .variable(variables[0]))
        #expect(info.nodes.edges(of: nodeA) == [info.mayBeNonUniform])
        #expect(info.getVariable(names[0]) == nodeA)
        #expect(info.nodes.count == 6)

        info.pushScope()
        guard let nodeB = info.getVariable(names[1]) else {
            Issue.record("no node for b")
            return
        }
        #expect(info.nodes.edges(of: nodeB) == [info.cfStart])
        let captured = info.popScopeCapture()
        #expect(captured.isEmpty)
        #expect(info.getVariable(names[1]) == nodeB)

        let assigned = info.createNode()
        info.setVariable(names[2], assigned)
        #expect(info.getVariable(names[2]) == assigned)
        #expect(info.nodes.count == 8)
    }

    /// C++ processFunction's eager nodes (UniformityAnalysis.cpp:427-435) and the lazy ones agree on every reachability
    /// question, over random sequences of the operations the statement and expression passes perform on a function graph.
    @Test
    func DEV_04_lazyModuleScopeVariableNodesMatchEagerOnes() {
        var module = parsedModule(
            """
            var<private> g0: i32;
            var<uniform> g1: i32;
            var<workgroup> g2: i32;
            var<storage, read> g3: i32;
            fn f(l0: i32, l1: i32, l2: i32) {}
            """
        )
        let variables = globalVariables(module)
        setAddressSpace(&module, variables[0], .private, nil)
        setAddressSpace(&module, variables[1], .uniform, nil)
        setAddressSpace(&module, variables[2], .workgroup, nil)
        setAddressSpace(&module, variables[3], .storage, .read)
        guard let function = firstFunction(module) else {
            Issue.record("no function")
            return
        }
        let table = UniformityGraph.collectModuleScopeVariables(module)
        let globals = variables.map { module.symbol(of: module[$0].name) }
        let locals = module.elements(module[function].parameters).map { module.symbol(of: module[$0].name) }
        let unknown = module.symbol(of: module[function].name)
        let names = globals + locals + [unknown]

        for seed in 0..<300 {
            var random = SplitMix64(state: UInt64(seed))
            var eager = functionInfo()
            for variable in variables {
                let node = eager.createNode(.variable(variable))
                eager.addEdge(node, UniformityGraph.isGlobalNonUniform(module, variable) ? eager.mayBeNonUniform : eager.cfStart)
                eager.setVariable(module.symbol(of: module[variable].name), node)
            }
            var lazy = functionInfo(table)
            var eagerValues = [eager.cfStart, eager.mayBeNonUniform]
            var lazyValues = [lazy.cfStart, lazy.mayBeNonUniform]
            var depth = 1

            for _ in 0..<80 {
                switch random.next(6) {
                case 0, 1:
                    let name = names[random.next(names.count)]
                    let eagerNode = eager.getVariable(name)
                    let lazyNode = lazy.getVariable(name)
                    #expect((eagerNode == nil) == (lazyNode == nil))
                    if let eagerNode, let lazyNode {
                        eagerValues.append(eagerNode)
                        lazyValues.append(lazyNode)
                    }
                case 2:
                    let name = names[random.next(names.count)]
                    let value = random.next(eagerValues.count)
                    let eagerNode = eager.createNode()
                    eager.addEdge(eagerNode, eagerValues[value])
                    eager.setVariable(name, eagerNode)
                    let lazyNode = lazy.createNode()
                    lazy.addEdge(lazyNode, lazyValues[value])
                    lazy.setVariable(name, lazyNode)
                    eagerValues.append(eagerNode)
                    lazyValues.append(lazyNode)
                case 3:
                    let severity = [SeverityControl.error, .warning, .info][random.next(3)]
                    let value = random.next(eagerValues.count)
                    if let sentinel = eager.requiredToBeUniformForSeverity(severity) {
                        eager.addEdge(sentinel, eagerValues[value])
                    }
                    if let sentinel = lazy.requiredToBeUniformForSeverity(severity) {
                        lazy.addEdge(sentinel, lazyValues[value])
                    }
                case 4:
                    eager.pushScope()
                    lazy.pushScope()
                    depth += 1
                default:
                    guard depth > 1 else {
                        break
                    }
                    depth -= 1
                    // CompoundStatement's merge (UniformityAnalysis.cpp:602-611).
                    let eagerScope = eager.popScopeCapture()
                    let lazyScope = lazy.popScopeCapture()
                    #expect(eagerScope.keys == lazyScope.keys)
                    eagerScope.forEachEntry { name, node in
                        if eager.getVariable(name) != nil {
                            eager.setVariable(name, node)
                        }
                    }
                    lazyScope.forEachEntry { name, node in
                        if lazy.getVariable(name) != nil {
                            lazy.setVariable(name, node)
                        }
                    }
                }
            }

            for severity in [SeverityControl.error, .warning, .info] {
                guard let eagerSentinel = eager.requiredToBeUniformForSeverity(severity),
                    let lazySentinel = lazy.requiredToBeUniformForSeverity(severity)
                else {
                    Issue.record("no sentinel")
                    return
                }
                eager.resetVisited()
                eager.nodes.traverse(eagerSentinel)
                lazy.resetVisited()
                lazy.nodes.traverse(lazySentinel)
                for (eagerNode, lazyNode) in zip(eagerValues, lazyValues) {
                    #expect(eager.nodes.isReachable(eagerNode) == lazy.nodes.isReachable(lazyNode), "seed \(seed)")
                }
                for name in names {
                    let eagerNode = eager.getVariable(name)
                    let lazyNode = lazy.getVariable(name)
                    #expect((eagerNode == nil) == (lazyNode == nil))
                    if let eagerNode, let lazyNode {
                        #expect(eager.nodes.isReachable(eagerNode) == lazy.nodes.isReachable(lazyNode), "seed \(seed)")
                    }
                }
            }
            #expect(lazy.nodes.count <= eager.nodes.count)
        }
    }
}
