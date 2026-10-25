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

/// C++ `WGSL::CallGraph`: built once by `buildCallGraph`, then written only by IOValidator's `usedGlobals` and
/// `textureSamplerPairs` updates; immutable after staticCheck.
///
/// Noncopyable like the C++ (it owns its globals); only `buildCallGraph` creates one.
@_spi(Testing)
public struct CallGraph: ~Copyable {
    @_spi(Testing)
    public struct Global: Sendable {
        @_spi(Testing)
        public typealias Resource = ResourceBinding

        @_spi(Testing)
        public let resource: Resource?

        @_spi(Testing)
        public let declaration: VariableID
    }

    // A texture and a sampler are used together when both are passed to the same sampling
    // builtin. Which pairs a stage uses decides whether a pipeline layout is legal for it: a
    // filtering sampler may only be paired with a filterable texture.
    @_spi(Testing)
    public struct TextureSamplerPair: Hashable, Sendable {
        @_spi(Testing)
        public let texture: Global.Resource

        @_spi(Testing)
        public let sampler: Global.Resource

        @_spi(Testing)
        public init(texture: Global.Resource, sampler: Global.Resource) {
            self.texture = texture
            self.sampler = sampler
        }
    }

    @_spi(Testing)
    public struct Callee: Sendable {
        @_spi(Testing)
        public let target: FunctionID

        @_spi(Testing)
        public fileprivate(set) var callSites: [(caller: FunctionID, call: ExpressionID)]

        @_spi(Testing)
        public internal(set) var usedGlobals = IDSet<CallGraphGlobalID>()

        @_spi(Testing)
        public internal(set) var textureSamplerPairs: [TextureSamplerPair] = []
    }

    @_spi(Testing)
    public struct EntryPoint: Sendable {
        @_spi(Testing)
        public let function: FunctionID

        @_spi(Testing)
        public let stage: ShaderStage

        @_spi(Testing)
        public let originalName: Symbol

        /// `originalName` as an API name, made once: prepare and generate look every entry point up by it.
        @_spi(Testing)
        public let apiName: Name

        @_spi(Testing)
        public internal(set) var usedGlobals = IDSet<CallGraphGlobalID>()

        @_spi(Testing)
        public internal(set) var textureSamplerPairs: [TextureSamplerPair] = []
    }

    @_spi(Testing)
    public fileprivate(set) var entrypoints: [EntryPoint] = []

    /// C++ dereferences `find()` without checking; every function reachable from an entry point has an entry.
    @_spi(Testing)
    public func callees(_ function: FunctionID) -> [Callee] {
        guard let callees = calleeMap.find(function) else {
            wgslFatal("callees() of a function the call graph never visited", cppSite: "CallGraph.h:86")
        }
        return callees
    }

    mutating func addGlobal(_ global: Global) -> CallGraphGlobalID {
        globals.append(global)
    }

    fileprivate init() {}

    private var globals = Arena<CallGraphGlobalID, Global>()
    fileprivate var functionsByName = SymbolMap<FunctionID>()
    fileprivate var calleeMap = SideTable<FunctionID, [Callee]>()
}

@_spi(Testing)
public func buildCallGraph(_ shaderModule: inout ShaderModule) {
    var builder = CallGraphBuilder(shaderModule: shaderModule)
    builder.build()
    shaderModule = builder.shaderModule
}

private struct CallGraphBuilder: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    private var callGraph = CallGraph()
    private var calleeBuildingMap = SmallKeyMap<FunctionID, Int>()
    /// C++ `m_callees`: the callee vector of `currentFunction`, stored into the map when its visit ends.
    private var callees: [CallGraph.Callee] = []
    private var currentFunction: FunctionID?
    private var queue: [FunctionID] = []
    private var queueHead = 0

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func build() {
        initializeMappings()
        var builtCallGraph = CallGraph()
        swap(&builtCallGraph, &callGraph)
        shaderModule.setCallGraph(builtCallGraph)
    }

    private mutating func initializeMappings() {
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            guard case .function(let function) = declaration else {
                continue
            }

            let name = shaderModule[shaderModule[function].name].symbol
            let isNewEntry = callGraph.functionsByName.add(name, function)
            assert(isNewEntry)

            guard let stage = shaderModule[function].stage else {
                continue
            }

            callGraph.entrypoints.append(
                CallGraph.EntryPoint(function: function, stage: stage, originalName: name, apiName: shaderModule.symbols.name(of: name))
            )
            queue.append(function)
        }

        while queueHead < queue.count {
            let function = queue[queueHead]
            queueHead += 1
            visit(function)
        }
    }

    mutating func visit(_ function: FunctionID) {
        guard callGraph.calleeMap.add(function, []) else {
            return
        }

        assert(currentFunction == nil)
        currentFunction = function
        visitChildren(function)
        callGraph.calleeMap.set(function, callees)
        callees = []
        calleeBuildingMap.clear()
        currentFunction = nil
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        var arguments = shaderModule.cursor(call.arguments)
        while let argument = shaderModule.next(&arguments) {
            dispatch(argument)
        }

        guard case .identifierExpression(let target) = shaderModule[call.target].kind else {
            return
        }

        guard let function = callGraph.functionsByName.find(shaderModule[target.identifier].symbol) else {
            return
        }

        guard let caller = currentFunction else {
            wgslFatal("a call expression visited outside a function", cppSite: "CallGraph.cpp:118")
        }
        queue.append(function)
        if calleeBuildingMap.add(function, callees.count) {
            callees.append(CallGraph.Callee(target: function, callSites: [(caller, id)]))
        } else if let index = calleeBuildingMap.find(function) {
            callees[index].callSites.append((caller, id))
        }
    }
}

// MARK: - Swift-only API

/// C++ `CallGraph::Global::Resource`, and the key of every binding map: unlike the C++ `{group + 1, binding + 1}`
/// HashMap keys, every `(group, binding)` is an ordinary key.
@_spi(Testing)
public struct ResourceBinding: Hashable, Sendable {
    @_spi(Testing)
    public let group: UInt32

    @_spi(Testing)
    public let binding: UInt32

    @_spi(Testing)
    public init(group: UInt32, binding: UInt32) {
        self.group = group
        self.binding = binding
    }
}

extension FunctionID: SmallKey {
    @_spi(Testing)
    public var smallKeyBits: UInt64 { UInt64(raw) }
}

extension CallGraph {
    /// C++ `*global` for a `const Global*` from `addGlobal`.
    @_spi(Testing)
    public subscript(global: CallGraphGlobalID) -> Global {
        globals[global]
    }

    /// IOValidator's write through `const_cast<CallGraph::EntryPoint&>` (IOValidator.cpp:101-102).
    mutating func modifyEntryPoint<R>(at index: Int, _ body: (inout EntryPoint) -> R) -> R {
        body(&entrypoints[index])
    }

    /// IOValidator's write through `const_cast<CallGraph::Callee&>` (IOValidator.cpp:143-144).
    mutating func modifyCallee<R>(of function: FunctionID, at index: Int, _ body: (inout Callee) -> R) -> R {
        guard let result = calleeMap.modify(function, { body(&$0[index]) }) else {
            wgslFatal("callees() of a function the call graph never visited", cppSite: "CallGraph.h:86")
        }
        return result
    }

    /// The callee recursion of a pass, from `root`, as events.
    @_spi(Testing)
    public func walk(from root: FunctionID) -> CalleeWalk {
        CalleeWalk(root: root)
    }

    /// MetalFunctionWriter's function order (MetalFunctionWriter.cpp:992-997): callees first, the first visit wins.
    @_spi(Testing)
    public func calleesFirstOrder(from root: FunctionID) -> [FunctionID] {
        var visited = IDSet<FunctionID>()
        return calleesFirstOrder(from: root, visited: &visited)
    }

    /// `visited` is the writer's `m_visitedFunctions`, which persists across entry points.
    @_spi(Testing)
    public func calleesFirstOrder(from root: FunctionID, visited: inout IDSet<FunctionID>) -> [FunctionID] {
        var order: [FunctionID] = []
        var calleeWalk = walk(from: root)
        while let event = calleeWalk.next(self) {
            switch event {
            case .enter(let function):
                if !visited.add(function) {
                    calleeWalk.finishCurrent()
                }
            case .edge:
                calleeWalk.descend()
            case .edgeDone:
                break
            case .exit(let function, let finishedEarly):
                if !finishedEarly {
                    order.append(function)
                }
            }
        }
        return order
    }
}

/// A point of a C++ callee recursion where a pass acts.
@_spi(Testing)
public enum CalleeWalkEvent: Hashable, Sendable {
    /// The top of `visit(Function)`.
    case enter(FunctionID)
    /// The callee loop body before the recursive call: answer with `descend()`, `skip()` or `finishCurrent()`.
    case edge(caller: FunctionID, calleeIndex: Int)
    /// The callee loop body after the recursive call, or after `skip()`.
    case edgeDone(caller: FunctionID, calleeIndex: Int)
    /// The end of `visit(Function)`; `finishedEarly` after `finishCurrent()`, the C++ early `return`.
    case exit(FunctionID, finishedEarly: Bool)
}

/// The callee recursions of VisibilityValidator, IOValidator, GlobalVariableRewriter and the Metal writer as one
/// iterative depth-first walk over an explicit stack of (function, next callee index).
@_spi(Testing)
public struct CalleeWalk: ~Copyable {
    private struct Frame {
        let function: FunctionID
        var nextCalleeIndex = 0
    }

    /// What the last event or answer leaves for `next`.
    private enum Step {
        case start
        case entered
        case edge(target: FunctionID)
        case descending(FunctionID)
        case skipping
        case edgeDone
        case finishing
        case exited
    }

    private let root: FunctionID
    // DEV-03: the C++ recursions overflow the stack on deep call chains; these frames are heap memory.
    private var frames: [Frame] = []
    private var step = Step.start

    @_spi(Testing)
    public init(root: FunctionID) {
        self.root = root
    }

    /// Nil once the root has exited.
    @_spi(Testing)
    public mutating func next(_ callGraph: borrowing CallGraph) -> CalleeWalkEvent? {
        switch step {
        case .start:
            return enter(root)
        case .entered, .edgeDone:
            guard let frame = frames.last else {
                wgslFatal("a CalleeWalk without a current function", cppSite: "CallGraph.h:86")
            }
            let callees = callGraph.callees(frame.function)
            guard frame.nextCalleeIndex < callees.count else {
                return exit(finishedEarly: false)
            }
            let calleeIndex = frame.nextCalleeIndex
            frames[frames.count - 1].nextCalleeIndex = calleeIndex + 1
            step = .edge(target: callees[calleeIndex].target)
            return .edge(caller: frame.function, calleeIndex: calleeIndex)
        case .edge:
            wgslFatal("a CalleeWalk .edge must be answered with descend(), skip() or finishCurrent()", cppSite: "CallGraph.h:86")
        case .descending(let target):
            return enter(target)
        case .skipping, .exited:
            guard let frame = frames.last else {
                return nil
            }
            step = .edgeDone
            return .edgeDone(caller: frame.function, calleeIndex: frame.nextCalleeIndex - 1)
        case .finishing:
            return exit(finishedEarly: true)
        }
    }

    /// After `.edge`: visit the callee; its `.enter` … `.exit` come next, then the edge's `.edgeDone`.
    @_spi(Testing)
    public mutating func descend() {
        guard case .edge(let target) = step else {
            wgslFatal("CalleeWalk.descend() outside an .edge", cppSite: "CallGraph.h:86")
        }
        step = .descending(target)
    }

    /// After `.edge`: do not visit the callee; the edge's `.edgeDone` comes next.
    @_spi(Testing)
    public mutating func skip() {
        guard case .edge = step else {
            wgslFatal("CalleeWalk.skip() outside an .edge", cppSite: "CallGraph.h:86")
        }
        step = .skipping
    }

    /// After `.enter`, `.edge` or `.edgeDone`: the C++ `return` from the current function.
    ///
    /// Its remaining edges are dropped (an unanswered `.edge` gets no `.edgeDone`) and its
    /// `.exit(_, finishedEarly: true)` comes next.
    @_spi(Testing)
    public mutating func finishCurrent() {
        switch step {
        case .entered, .edge, .edgeDone:
            step = .finishing
        case .start, .descending, .skipping, .finishing, .exited:
            wgslFatal("CalleeWalk.finishCurrent() without a current function to return from", cppSite: "CallGraph.h:86")
        }
    }

    private mutating func enter(_ function: FunctionID) -> CalleeWalkEvent {
        frames.append(Frame(function: function))
        step = .entered
        return .enter(function)
    }

    private mutating func exit(finishedEarly: Bool) -> CalleeWalkEvent {
        let frame = frames.removeLast()
        step = .exited
        return .exit(frame.function, finishedEarly: finishedEarly)
    }
}
