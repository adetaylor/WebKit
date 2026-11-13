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

import Foundation
import Synchronization
import Testing
@_spi(Testing) import WGSL

// MARK: - Modules made of call statements

/// A call whose arguments are calls too: `f2(f3(), max(f4()))`.
private struct CallTree {
    var callee: Int
    var arguments: [CallTree] = []
}

/// A callee that is an identifier naming no function (`max(…)`).
private let builtinCallee = -1

/// A callee that is not an identifier (`vec2<f32>(…)`).
private let constructorCallee = -2

private struct FunctionModel {
    var stage: ShaderStage?
    var statements: [CallTree] = []
}

/// Declares `f0`, `f1`, … with call-statement bodies through the IR constructors.
private struct CallGraphModuleBuilder: ~Copyable {
    var module = ShaderModule(source: SourceText(""))
    var functions: [FunctionID] = []
    /// Per function, its calls of functions in creation order (arguments before the call).
    var callSites: [[(callee: Int, call: ExpressionID)]] = []
    private var offset: UInt32 = 0

    mutating func span() -> SourceSpan {
        offset += 1
        return SourceSpan(line: 1, lineOffset: offset, offset: offset, length: 1)
    }

    mutating func name(_ index: Int) -> Identifier {
        let span = span()
        guard index != builtinCallee else {
            return module.makeIdentifier("max", span: span)
        }
        return module.makeIdentifier(module.symbols.intern(ContiguousArray(("f" + String(index)).utf16)), span: span)
    }

    mutating func call(_ tree: CallTree, in function: Int) -> ExpressionID {
        var arguments: [ExpressionID] = []
        for argument in tree.arguments {
            arguments.append(call(argument, in: function))
        }
        let target: ExpressionID
        if tree.callee == constructorCallee {
            let type = module.constructIdentifierExpression(span: span(), identifier: module.makeIdentifier("f32"))
            target = module.constructElaboratedTypeExpression(
                span: span(),
                base: module.makeIdentifier("vec2"),
                arguments: module.makeList([type])
            )
        } else {
            target = module.constructIdentifierExpression(span: span(), identifier: name(tree.callee))
        }
        let call = module.construct(span: span(), CallExpression(target: target, arguments: module.makeList(arguments)))
        if tree.callee >= 0 {
            callSites[function].append((tree.callee, call))
        }
        return call
    }

    mutating func compound(_ statements: [StatementID]) -> StatementID {
        module.construct(
            span: span(),
            CompoundStatement(attributes: module.makeEmptyList(AttributeID.self), statements: module.makeList(statements))
        )
    }

    mutating func declareFunction(_ index: Int, stage: ShaderStage?, body: StatementID) {
        let function = module.constructFunction(
            span: span(),
            name: name(index),
            parameters: module.makeEmptyList(ParameterID.self),
            returnType: nil,
            body: body,
            attributes: module.makeEmptyList(AttributeID.self),
            returnAttributes: module.makeEmptyList(AttributeID.self)
        )
        if let stage {
            module.modify(function) { $0.stage = stage }
        }
        module.append(module.declarations, .function(function))
        functions.append(function)
    }

    mutating func declare(_ models: [FunctionModel]) {
        callSites = Array(repeating: [], count: models.count)
        for (index, model) in models.enumerated() {
            var statements: [StatementID] = []
            for tree in model.statements {
                let call = call(tree, in: index)
                statements.append(module.constructCallStatement(span: span(), call: call))
            }
            declareFunction(index, stage: model.stage, body: compound(statements))
        }
    }
}

private struct BuiltModule: ~Copyable {
    var module: ShaderModule
    let functions: [FunctionID]
    let callSites: [[(callee: Int, call: ExpressionID)]]
}

private func buildModule(_ models: [FunctionModel]) -> BuiltModule {
    var builder = CallGraphModuleBuilder()
    builder.declare(models)
    let functions = builder.functions
    let callSites = builder.callSites
    var module = builder.module
    buildCallGraph(&module)
    return BuiltModule(module: module, functions: functions, callSites: callSites)
}

/// CallGraph.cpp:104-118 on the model: the arguments' calls, then the call itself.
private func callOrder(_ tree: CallTree, into order: inout [Int]) {
    for argument in tree.arguments {
        callOrder(argument, into: &order)
    }
    if tree.callee >= 0 {
        order.append(tree.callee)
    }
}

/// The distinct callees of each function in first-call order.
private func modelCallees(_ models: [FunctionModel]) -> [[Int]] {
    models.map { model in
        var order: [Int] = []
        for tree in model.statements {
            callOrder(tree, into: &order)
        }
        var callees: [Int] = []
        for callee in order where !callees.contains(callee) {
            callees.append(callee)
        }
        return callees
    }
}

private func calleeTargets(_ module: borrowing ShaderModule, _ function: FunctionID, _ indices: [FunctionID: Int]) -> [Int] {
    module.callGraph.callees(function).map { indices[$0.target] ?? -1 }
}

// MARK: - Random call graphs

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomCall(caller: Int, count: Int, depth: Int, _ generator: inout SplitMix64) -> CallTree {
    let roll = Int.random(in: 0..<10, using: &generator)
    var tree = CallTree(callee: builtinCallee)
    if roll == 1 {
        tree.callee = constructorCallee
    } else if roll > 1 && caller + 1 < count {
        tree.callee = Int.random(in: (caller + 1)..<count, using: &generator)
    }
    if depth < 2 {
        for _ in 0..<Int.random(in: 0...2, using: &generator) {
            tree.arguments.append(randomCall(caller: caller, count: count, depth: depth + 1, &generator))
        }
    }
    return tree
}

private let stages: [ShaderStage] = [.vertex, .fragment, .compute]

/// A DAG of 1-10 functions (each calls only later ones) with 1 or more entry points.
private func randomModels(_ generator: inout SplitMix64) -> [FunctionModel] {
    let count = Int.random(in: 1...10, using: &generator)
    var models: [FunctionModel] = []
    for index in 0..<count {
        var model = FunctionModel()
        if index == 0 || Int.random(in: 0..<3, using: &generator) == 0 {
            model.stage = stages[Int.random(in: 0..<stages.count, using: &generator)]
        }
        for _ in 0..<Int.random(in: 0...4, using: &generator) {
            model.statements.append(randomCall(caller: index, count: count, depth: 0, &generator))
        }
        models.append(model)
    }
    return models
}

private struct RandomCallGraph {
    let functions: [FunctionID]
    let indices: [FunctionID: Int]
    let callees: [[Int]]
    let entryPoints: [Int]
}

/// Runs `body` on `count` random modules after buildCallGraph.
private func forEachRandomCallGraph(_ count: Int, seed: UInt64, _ body: (borrowing ShaderModule, RandomCallGraph, inout SplitMix64) -> Void)
{
    var generator = SplitMix64(state: seed)
    for _ in 0..<count {
        let models = randomModels(&generator)
        let built = buildModule(models)
        var indices: [FunctionID: Int] = [:]
        for (index, function) in built.functions.enumerated() {
            indices[function] = index
        }
        let graph = RandomCallGraph(
            functions: built.functions,
            indices: indices,
            callees: modelCallees(models),
            entryPoints: models.indices.filter { models[$0].stage != nil }
        )
        body(built.module, graph, &generator)
    }
}

// MARK: - Walks

/// `CalleeWalkEvent` with function indices.
private enum WalkEvent: Equatable {
    case enter(Int)
    case edge(Int, Int)
    case edgeDone(Int, Int)
    case exit(Int, Bool)
}

private func walkEvent(_ event: CalleeWalkEvent, _ indices: [FunctionID: Int]) -> WalkEvent {
    switch event {
    case .enter(let function):
        .enter(indices[function] ?? -1)
    case .edge(let caller, let calleeIndex):
        .edge(indices[caller] ?? -1, calleeIndex)
    case .edgeDone(let caller, let calleeIndex):
        .edgeDone(indices[caller] ?? -1, calleeIndex)
    case .exit(let function, let finishedEarly):
        .exit(indices[function] ?? -1, finishedEarly)
    }
}

private enum Answer {
    case descend
    case skip
    case finish
}

/// The answers a pass gives at each event; both walks of a comparison ask in the same order.
private struct Decisions {
    var generator: SplitMix64

    mutating func finishesAtEnter() -> Bool {
        Int.random(in: 0..<20, using: &generator) == 0
    }

    mutating func answerAtEdge() -> Answer {
        switch Int.random(in: 0..<10, using: &generator) {
        case 0: .finish
        case 1, 2, 3: .skip
        default: .descend
        }
    }

    mutating func finishesAtEdgeDone() -> Bool {
        Int.random(in: 0..<10, using: &generator) == 0
    }
}

/// The C++ shape: `visit(Function)` recursing per callee, with a `return` wherever the decisions say.
private func recursiveWalk(_ function: Int, _ callees: [[Int]], _ decisions: inout Decisions, _ events: inout [WalkEvent]) {
    events.append(.enter(function))
    if decisions.finishesAtEnter() {
        events.append(.exit(function, true))
        return
    }
    for (index, callee) in callees[function].enumerated() {
        events.append(.edge(function, index))
        switch decisions.answerAtEdge() {
        case .descend:
            recursiveWalk(callee, callees, &decisions, &events)
        case .skip:
            break
        case .finish:
            events.append(.exit(function, true))
            return
        }
        events.append(.edgeDone(function, index))
        if decisions.finishesAtEdgeDone() {
            events.append(.exit(function, true))
            return
        }
    }
    events.append(.exit(function, false))
}

private func iterativeWalk(
    _ module: borrowing ShaderModule,
    _ root: FunctionID,
    _ indices: [FunctionID: Int],
    _ decisions: inout Decisions
) -> [WalkEvent] {
    var events: [WalkEvent] = []
    var walk = module.callGraph.walk(from: root)
    while let event = walk.next(module.callGraph) {
        events.append(walkEvent(event, indices))
        switch event {
        case .enter:
            if decisions.finishesAtEnter() {
                walk.finishCurrent()
            }
        case .edge:
            switch decisions.answerAtEdge() {
            case .descend: walk.descend()
            case .skip: walk.skip()
            case .finish: walk.finishCurrent()
            }
        case .edgeDone:
            if decisions.finishesAtEdgeDone() {
                walk.finishCurrent()
            }
        case .exit:
            break
        }
    }
    return events
}

/// Every event with `descend()` at every edge.
private func fullWalk(_ module: borrowing ShaderModule, _ root: FunctionID, _ indices: [FunctionID: Int]) -> [WalkEvent] {
    var events: [WalkEvent] = []
    var walk = module.callGraph.walk(from: root)
    while let event = walk.next(module.callGraph) {
        events.append(walkEvent(event, indices))
        if case .edge = event {
            walk.descend()
        }
    }
    return events
}

/// GlobalVariableRewriter's shape (GVR.cpp:188-196, 199-357): a visited-callee memo kept across entry points, revisit
/// actions on an edge to a visited callee, the error check between sibling callees, and the run stopping at an error.
private struct RewriterLikePass {
    var visited = Set<Int>()
    var hasError = false
    var log: [String] = []
    var generator: SplitMix64

    mutating func bodyMaySetError(_ function: Int) {
        log.append("body " + String(function))
        if Int.random(in: 0..<25, using: &generator) == 0 {
            hasError = true
        }
    }

    mutating func visit(_ function: Int, _ callees: [[Int]]) {
        for (index, callee) in callees[function].enumerated() {
            visitCallee(function, index, callee, callees)
            if hasError {
                log.append("stop " + String(function))
                return
            }
        }
        bodyMaySetError(function)
    }

    mutating func visitCallee(_ caller: Int, _ index: Int, _ callee: Int, _ callees: [[Int]]) {
        if visited.contains(callee) {
            log.append("revisit " + String(caller) + "#" + String(index))
            return
        }
        visit(callee, callees)
        log.append("update " + String(caller) + "#" + String(index))
        visited.insert(callee)
    }

    mutating func run(_ entryPoints: [Int], _ callees: [[Int]]) {
        for entryPoint in entryPoints {
            visit(entryPoint, callees)
            if hasError {
                return
            }
        }
    }

    /// The same pass on `CalleeWalk` events.
    mutating func run(_ module: borrowing ShaderModule, _ graph: RandomCallGraph) {
        for entryPoint in graph.entryPoints {
            var walk = module.callGraph.walk(from: graph.functions[entryPoint])
            var previousWasEdge = false
            while let event = walk.next(module.callGraph) {
                switch event {
                case .enter:
                    break
                case .edge(let caller, let calleeIndex):
                    let callerIndex = graph.indices[caller] ?? -1
                    if visited.contains(graph.callees[callerIndex][calleeIndex]) {
                        log.append("revisit " + String(callerIndex) + "#" + String(calleeIndex))
                        walk.skip()
                    } else {
                        walk.descend()
                    }
                case .edgeDone(let caller, let calleeIndex):
                    let callerIndex = graph.indices[caller] ?? -1
                    if !previousWasEdge {
                        log.append("update " + String(callerIndex) + "#" + String(calleeIndex))
                        visited.insert(graph.callees[callerIndex][calleeIndex])
                    }
                    if hasError {
                        log.append("stop " + String(callerIndex))
                        walk.finishCurrent()
                    }
                case .exit(let function, let finishedEarly):
                    if !finishedEarly {
                        bodyMaySetError(graph.indices[function] ?? -1)
                    }
                }
                if case .edge = event {
                    previousWasEdge = true
                } else {
                    previousWasEdge = false
                }
            }
            if hasError {
                return
            }
        }
    }
}

/// FunctionDefinitionWriter::visit(Function) (MetalFunctionWriter.cpp:992-997), emitting where the function is written.
private func writerOrder(_ function: Int, _ callees: [[Int]], _ visited: inout Set<Int>, _ order: inout [Int]) {
    guard visited.insert(function).inserted else {
        return
    }
    for callee in callees[function] {
        writerOrder(callee, callees, &visited, &order)
    }
    order.append(function)
}

// MARK: - Threads

private final class ThreadResult<Value: Sendable>: Sendable {
    private let value = Mutex<Value?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func complete(_ result: Value) {
        value.withLock { $0 = result }
        done.signal()
    }

    func wait() -> Value? {
        done.wait()
        return value.withLock { $0 }
    }
}

/// Runs `body` on a fresh thread with the GPU process's 512 KiB stack and waits for it.
private func on512KiBThread<Value: Sendable>(_ body: @escaping @Sendable () -> Value) -> Value? {
    let result = ThreadResult<Value>()
    let thread = Thread {
        result.complete(body())
    }
    thread.name = "WGSL call graph"
    thread.stackSize = 512 * 1024
    thread.start()
    return result.wait()
}

private struct DeepChainResult: Sendable {
    var events = 0
    var deepest = 0
    var finishedEarly = 0
    var firstOrderIsReversedChain = false
}

// MARK: - Tests

@Suite
struct WGSLCallGraphTests {
    @Test
    func entryPointsInDeclarationOrder() {
        var models = Array(repeating: FunctionModel(), count: 5)
        models[0].stage = .vertex
        models[2].stage = .fragment
        models[3].stage = .compute
        models[1].statements = [CallTree(callee: 4)]
        let built = buildModule(models)
        let entryPoints = built.module.callGraph.entrypoints
        #expect(entryPoints.map(\.function) == [built.functions[0], built.functions[2], built.functions[3]])
        #expect(entryPoints.map(\.stage) == [.vertex, .fragment, .compute])
        for entryPoint in entryPoints {
            #expect(entryPoint.originalName == built.module[built.module[entryPoint.function].name].symbol)
            #expect(entryPoint.usedGlobals.isEmpty)
            #expect(entryPoint.textureSamplerPairs.isEmpty)
        }
    }

    @Test
    func calleesVisitArgumentsBeforeTheCallee() {
        // @compute fn f0() { f1(f2(), f3(f2())); f1(); }
        var models = Array(repeating: FunctionModel(), count: 4)
        models[0].stage = .compute
        models[0].statements = [
            CallTree(callee: 1, arguments: [CallTree(callee: 2), CallTree(callee: 3, arguments: [CallTree(callee: 2)])]),
            CallTree(callee: 1),
        ]
        let built = buildModule(models)
        let main = built.functions[0]
        let callees = built.module.callGraph.callees(main)
        let sites = built.callSites[0]
        #expect(callees.map(\.target) == [built.functions[2], built.functions[3], built.functions[1]])
        #expect(callees.count == 3)
        guard callees.count == 3, sites.count == 5 else {
            return
        }
        #expect(sites.map(\.callee) == [2, 2, 3, 1, 1])
        #expect(callees[0].callSites.map(\.call) == [sites[0].call, sites[1].call])
        #expect(callees[1].callSites.map(\.call) == [sites[2].call])
        #expect(callees[2].callSites.map(\.call) == [sites[3].call, sites[4].call])
        #expect(callees.allSatisfy { callee in callee.callSites.allSatisfy { $0.caller == main } })
        #expect(callees.allSatisfy { $0.usedGlobals.isEmpty && $0.textureSamplerPairs.isEmpty })
        for function in built.functions.dropFirst() {
            #expect(built.module.callGraph.callees(function).isEmpty)
        }
    }

    @Test
    func calleesInNestedExpressionsAndStatements() {
        // @compute fn f0() { let x = f1() + f2(f3()); if f4() { f5(); } }
        var builder = CallGraphModuleBuilder()
        builder.callSites = Array(repeating: [], count: 6)
        let sum = builder.module.construct(
            span: builder.span(),
            BinaryExpression(
                leftExpression: builder.call(CallTree(callee: 1), in: 0),
                rightExpression: builder.call(CallTree(callee: 2, arguments: [CallTree(callee: 3)]), in: 0),
                operation: .add
            )
        )
        let variable = builder.module.constructVariable(
            span: builder.span(),
            flavor: .let,
            name: builder.module.makeIdentifier("x"),
            type: nil,
            initializer: sum,
            attributes: builder.module.makeEmptyList(AttributeID.self)
        )
        let declaration = builder.module.construct(span: builder.span(), VariableStatement(variable: variable))
        let test = builder.call(CallTree(callee: 4), in: 0)
        let thenCall = builder.call(CallTree(callee: 5), in: 0)
        let thenBody = builder.compound([builder.module.constructCallStatement(span: builder.span(), call: thenCall)])
        let ifStatement = builder.module.construct(
            span: builder.span(),
            IfStatement(test: test, trueBody: thenBody, maybeFalseBody: nil, attributes: builder.module.makeEmptyList(AttributeID.self))
        )
        let body = builder.compound([declaration, ifStatement])
        builder.declareFunction(0, stage: .compute, body: body)
        for index in 1...5 {
            builder.declareFunction(index, stage: nil, body: builder.compound([]))
        }
        let functions = builder.functions
        var module = builder.module
        buildCallGraph(&module)
        #expect(module.callGraph.callees(functions[0]).map(\.target) == [1, 3, 2, 4, 5].map { functions[$0] })
    }

    @Test
    func callsOfNonFunctionsAreNotCallees() {
        // @compute fn f0() { max(f1()); vec2<f32>(f2()); }
        var models = Array(repeating: FunctionModel(), count: 3)
        models[0].stage = .compute
        models[0].statements = [
            CallTree(callee: builtinCallee, arguments: [CallTree(callee: 1)]),
            CallTree(callee: constructorCallee, arguments: [CallTree(callee: 2)]),
        ]
        let built = buildModule(models)
        #expect(built.module.callGraph.callees(built.functions[0]).map(\.target) == [built.functions[1], built.functions[2]])
    }

    @Test
    func calleesOfEveryReachableFunction() {
        // f0 (vertex) -> f1 -> f2, f3 -> f2 with f3 unreachable; f4 (fragment) -> f2.
        var models = Array(repeating: FunctionModel(), count: 5)
        models[0].stage = .vertex
        models[0].statements = [CallTree(callee: 1)]
        models[1].statements = [CallTree(callee: 2)]
        models[3].statements = [CallTree(callee: 2)]
        models[4].stage = .fragment
        models[4].statements = [CallTree(callee: 2)]
        let built = buildModule(models)
        #expect(built.module.callGraph.callees(built.functions[0]).map(\.target) == [built.functions[1]])
        #expect(built.module.callGraph.callees(built.functions[1]).map(\.target) == [built.functions[2]])
        #expect(built.module.callGraph.callees(built.functions[2]).isEmpty)
        #expect(built.module.callGraph.callees(built.functions[4]).map(\.target) == [built.functions[2]])
        #expect(built.module.callGraph.callees(built.functions[4])[0].callSites.map(\.caller) == [built.functions[4]])
    }

    @Test
    func calleesPastTheScannedLookupSize() {
        // f0 (compute) calls f19, f18, …, f1, then each again: more functions and more distinct callees than the builder's
        // lookup tables scan before they hash.
        let count = 20
        var models = Array(repeating: FunctionModel(), count: count)
        models[0].stage = .compute
        let order = Array((1..<count).reversed())
        models[0].statements = (order + order).map { CallTree(callee: $0) }
        let built = buildModule(models)
        let callees = built.module.callGraph.callees(built.functions[0])
        let sites = built.callSites[0]
        #expect(callees.map(\.target) == order.map { built.functions[$0] })
        guard callees.count == order.count, sites.count == 2 * order.count else {
            return
        }
        for index in 0..<order.count {
            #expect(callees[index].callSites.map(\.call) == [sites[index].call, sites[index + order.count].call])
        }
        for function in built.functions.dropFirst() {
            #expect(built.module.callGraph.callees(function).isEmpty)
        }
    }

    @Test
    func builderMatchesTheModelOnRandomModules() {
        var mismatches = 0
        forEachRandomCallGraph(5000, seed: 0xCA11_0001) { module, graph, _ in
            if module.callGraph.entrypoints.map(\.function) != graph.entryPoints.map({ graph.functions[$0] }) {
                mismatches += 1
            }
            var reachable = Set(graph.entryPoints)
            var pending = graph.entryPoints
            while let function = pending.popLast() {
                if calleeTargets(module, graph.functions[function], graph.indices) != graph.callees[function] {
                    mismatches += 1
                }
                for callee in graph.callees[function] where reachable.insert(callee).inserted {
                    pending.append(callee)
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test
    func walkEventsDescendingEverywhere() {
        // f0 -> f1, f2; f1 -> f3; f2 -> f3
        var models = Array(repeating: FunctionModel(), count: 4)
        models[0].stage = .compute
        models[0].statements = [CallTree(callee: 1), CallTree(callee: 2)]
        models[1].statements = [CallTree(callee: 3)]
        models[2].statements = [CallTree(callee: 3)]
        let built = buildModule(models)
        var indices: [FunctionID: Int] = [:]
        for (index, function) in built.functions.enumerated() {
            indices[function] = index
        }
        let expected: [WalkEvent] = [
            .enter(0), .edge(0, 0), .enter(1), .edge(1, 0), .enter(3), .exit(3, false), .edgeDone(1, 0), .exit(1, false),
            .edgeDone(0, 0), .edge(0, 1), .enter(2), .edge(2, 0), .enter(3), .exit(3, false), .edgeDone(2, 0), .exit(2, false),
            .edgeDone(0, 1), .exit(0, false),
        ]
        #expect(fullWalk(built.module, built.functions[0], indices) == expected)
        #expect(built.module.callGraph.calleesFirstOrder(from: built.functions[0]) == [3, 1, 2, 0].map { built.functions[$0] })
    }

    @Test
    func walkEventsWithSkipAndFinishCurrent() {
        var models = Array(repeating: FunctionModel(), count: 4)
        models[0].stage = .compute
        models[0].statements = [CallTree(callee: 1), CallTree(callee: 2)]
        models[1].statements = [CallTree(callee: 3)]
        models[2].statements = [CallTree(callee: 3), CallTree(callee: 1)]
        let built = buildModule(models)
        var indices: [FunctionID: Int] = [:]
        for (index, function) in built.functions.enumerated() {
            indices[function] = index
        }
        let root = built.functions[0]

        // Skip the first edge; return from f2 after its first callee.
        var events: [WalkEvent] = []
        var walk = built.module.callGraph.walk(from: root)
        while let event = walk.next(built.module.callGraph) {
            let mapped = walkEvent(event, indices)
            events.append(mapped)
            switch mapped {
            case .edge(0, 0): walk.skip()
            case .edge: walk.descend()
            case .edgeDone(2, 0): walk.finishCurrent()
            case .enter, .edgeDone, .exit: break
            }
        }
        #expect(
            events == [
                .enter(0), .edge(0, 0), .edgeDone(0, 0), .edge(0, 1), .enter(2), .edge(2, 0), .enter(3), .exit(3, false),
                .edgeDone(2, 0), .exit(2, true), .edgeDone(0, 1), .exit(0, false),
            ]
        )
        #expect(walk.next(built.module.callGraph) == nil)
        #expect(walk.next(built.module.callGraph) == nil)

        // finishCurrent() at an unanswered edge drops its .edgeDone.
        var atEdge = built.module.callGraph.walk(from: root)
        var atEdgeEvents: [WalkEvent] = []
        while let event = atEdge.next(built.module.callGraph) {
            atEdgeEvents.append(walkEvent(event, indices))
            if case .edge = event {
                atEdge.finishCurrent()
            }
        }
        #expect(atEdgeEvents == [.enter(0), .edge(0, 0), .exit(0, true)])

        // finishCurrent() at .enter: the C++ `return` at the top of visit(Function).
        var atEnter = built.module.callGraph.walk(from: root)
        var atEnterEvents: [WalkEvent] = []
        while let event = atEnter.next(built.module.callGraph) {
            atEnterEvents.append(walkEvent(event, indices))
            if case .enter = event {
                atEnter.finishCurrent()
            }
        }
        #expect(atEnterEvents == [.enter(0), .exit(0, true)])

        var leaf = built.module.callGraph.walk(from: built.functions[3])
        #expect(leaf.next(built.module.callGraph) == .enter(built.functions[3]))
        #expect(leaf.next(built.module.callGraph) == .exit(built.functions[3], finishedEarly: false))
        #expect(leaf.next(built.module.callGraph) == nil)
    }

    @Test
    func walkMatchesTheRecursiveTranscriptionWithRandomDecisions() {
        var walks = 0
        var mismatches = 0
        forEachRandomCallGraph(5000, seed: 0xCA11_0002) { module, graph, generator in
            for entryPoint in graph.entryPoints {
                let decisions = Decisions(generator: SplitMix64(state: generator.next()))
                var recursiveDecisions = decisions
                var expected: [WalkEvent] = []
                recursiveWalk(entryPoint, graph.callees, &recursiveDecisions, &expected)
                var iterativeDecisions = decisions
                if iterativeWalk(module, graph.functions[entryPoint], graph.indices, &iterativeDecisions) != expected {
                    mismatches += 1
                }
                walks += 1
            }
        }
        #expect(walks > 5000)
        #expect(mismatches == 0)
    }

    @Test
    func walkMatchesTheRecursiveTranscriptionAcrossEntryPoints() {
        var mismatches = 0
        var stopped = 0
        forEachRandomCallGraph(5000, seed: 0xCA11_0003) { module, graph, generator in
            let seed = generator.next()
            var recursive = RewriterLikePass(generator: SplitMix64(state: seed))
            recursive.run(graph.entryPoints, graph.callees)
            var iterative = RewriterLikePass(generator: SplitMix64(state: seed))
            iterative.run(module, graph)
            if iterative.log != recursive.log || iterative.visited != recursive.visited {
                mismatches += 1
            }
            if recursive.hasError {
                stopped += 1
            }
        }
        #expect(stopped > 0)
        #expect(mismatches == 0)
    }

    @Test
    func calleesFirstOrderMatchesTheWriterRecursion() {
        var mismatches = 0
        forEachRandomCallGraph(5000, seed: 0xCA11_0004) { module, graph, _ in
            var visited = IDSet<FunctionID>()
            var expectedVisited = Set<Int>()
            for entryPoint in graph.entryPoints {
                var expected: [Int] = []
                writerOrder(entryPoint, graph.callees, &expectedVisited, &expected)
                let order = module.callGraph.calleesFirstOrder(from: graph.functions[entryPoint], visited: &visited)
                if order != expected.map({ graph.functions[$0] }) {
                    mismatches += 1
                }

                var freshVisited = Set<Int>()
                var fresh: [Int] = []
                writerOrder(entryPoint, graph.callees, &freshVisited, &fresh)
                if module.callGraph.calleesFirstOrder(from: graph.functions[entryPoint]) != fresh.map({ graph.functions[$0] }) {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test
    func DEV_03_deepCallChainWalksOn512KiBThread() {
        let depth = 50_000
        let result = on512KiBThread { () -> DeepChainResult in
            var models = Array(repeating: FunctionModel(), count: depth)
            models[0].stage = .compute
            for index in 0..<(depth - 1) {
                models[index].statements = [CallTree(callee: index + 1)]
            }
            let built = buildModule(models)
            var result = DeepChainResult()
            var current = 0
            var walk = built.module.callGraph.walk(from: built.functions[0])
            while let event = walk.next(built.module.callGraph) {
                result.events += 1
                switch event {
                case .enter:
                    current += 1
                    result.deepest = max(result.deepest, current)
                case .edge:
                    walk.descend()
                case .edgeDone:
                    break
                case .exit(_, let finishedEarly):
                    current -= 1
                    if finishedEarly {
                        result.finishedEarly += 1
                    }
                }
            }
            result.firstOrderIsReversedChain =
                built.module.callGraph.calleesFirstOrder(from: built.functions[0]) == Array(built.functions.reversed())
            return result
        }
        #expect(result?.events == 4 * depth - 2)
        #expect(result?.deepest == depth)
        #expect(result?.finishedEarly == 0)
        #expect(result?.firstOrderIsReversedChain == true)
    }

    @Test
    func resourceBindingKeysCoverEveryGroupAndBinding() {
        let keys = [
            ResourceBinding(group: .max, binding: .max),
            ResourceBinding(group: .max - 1, binding: 0),
            ResourceBinding(group: 0, binding: 0),
            ResourceBinding(group: 0, binding: .max),
            ResourceBinding(group: .max, binding: .max),
        ]
        var bindings = LookupMap<ResourceBinding, Int>()
        var isNewEntry: [Bool] = []
        for (index, key) in keys.enumerated() {
            isNewEntry.append(bindings.add(key, index))
        }
        #expect(isNewEntry == [true, true, true, true, false])
        #expect(bindings.get(ResourceBinding(group: .max, binding: .max)) == 0)
        #expect(bindings.get(ResourceBinding(group: .max - 1, binding: 0)) == 1)
        #expect(bindings.count == 4)

        let pair = CallGraph.TextureSamplerPair(
            texture: ResourceBinding(group: 0, binding: 1),
            sampler: ResourceBinding(group: 0, binding: 2)
        )
        var pairs = [pair]
        let appended = pairs.appendIfNotContains(pair)
        #expect(!appended)
        #expect(pairs.count == 1)
    }
}
