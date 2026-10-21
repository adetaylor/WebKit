// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

@_spi(Testing)
public struct UniformityGraph: ~Copyable {
    /// C++ `Node*`: a node of the graph of one function, an index into that function's `NodeArena`.
    ///
    /// Only `NodeArena.createNode` makes one.
    @_spi(Testing)
    public struct Node: Hashable, BitwiseCopyable {
        fileprivate let index: UInt32

        fileprivate var position: Int { Int(index) }
    }

    /// C++ `Node::ast`: the AST node a graph node was created for.
    @_spi(Testing)
    public enum NodeAST: BitwiseCopyable, Equatable {
        case expression(ExpressionID)
        case statement(StatementID)
        case parameter(ParameterID)
        case variable(VariableID)
    }

    /// The C++ `Node` fields other than `edges`; a node's edges are a list through `NodeArena.edges`, in insertion order.
    private struct NodeData {
        var ast: NodeAST?
        var firstEdge: Int32 = -1
        var lastEdge: Int32 = -1
        // C++ `visitedFrom`, as the generation of the last traversal that reached the node.
        var visited: UInt32 = 0
        var affectsControlFlow = false
    }

    private struct Edge {
        let to: Node
        var next: Int32 = -1
    }

    /// C++ `Vector<std::unique_ptr<Node>> nodes`: the nodes of one function.
    @_spi(Testing)
    public struct NodeArena {
        private var nodes: [NodeData] = []
        private var edges: [Edge] = []
        private var generation: UInt32 = 1
        private var stack: [Node] = []

        init(reservingCapacity capacity: Int) {
            if capacity > 0 {
                nodes.reserveCapacity(capacity)
                edges.reserveCapacity(capacity)
            }
        }

        @_spi(Testing)
        public var count: Int { nodes.count }

        mutating func createNode(_ ast: NodeAST?) -> Node {
            let node = Node(index: UInt32(nodes.count))
            nodes.append(NodeData(ast: ast))
            return node
        }

        // C++ Node::addEdge.
        mutating func addEdge(_ node: Node, _ to: Node) {
            let edge = Int32(edges.count)
            edges.append(Edge(to: to))
            let last = nodes[node.position].lastEdge
            if last < 0 {
                nodes[node.position].firstEdge = edge
            } else {
                edges[Int(last)].next = edge
            }
            nodes[node.position].lastEdge = edge
        }

        mutating func setAffectsControlFlow(_ node: Node) {
            nodes[node.position].affectsControlFlow = true
        }

        @_spi(Testing)
        public func ast(of node: Node) -> NodeAST? {
            nodes[node.position].ast
        }

        @_spi(Testing)
        public func affectsControlFlow(_ node: Node) -> Bool {
            nodes[node.position].affectsControlFlow
        }

        /// C++ `node->edges`, in insertion order.
        @_spi(Testing)
        public func edges(of node: Node) -> [Node] {
            var result: [Node] = []
            var edge = nodes[node.position].firstEdge
            while edge >= 0 {
                result.append(edges[Int(edge)].to)
                edge = edges[Int(edge)].next
            }
            return result
        }

        // C++ FunctionInfo::resetVisited: starts a new generation, so no node is visited.
        @_spi(Testing)
        public mutating func resetVisited() {
            generation &+= 1
            if generation == 0 {
                var position = 0
                while position < nodes.count {
                    nodes[position].visited = 0
                    position += 1
                }
                generation = 1
            }
        }

        /// C++ `traverse(source, &reachable)`: afterwards `isReachable` is membership in C++'s `reachable`, which holds
        /// `source` and every node reachable from it.
        @_spi(Testing)
        public mutating func traverse(_ source: Node) {
            stack.removeAll(keepingCapacity: true)
            stack.append(source)
            nodes[source.position].visited = generation

            while let node = stack.popLast() {
                var edge = nodes[node.position].firstEdge
                while edge >= 0 {
                    let to = edges[Int(edge)].to
                    if nodes[to.position].visited != generation {
                        nodes[to.position].visited = generation
                        stack.append(to)
                    }
                    edge = edges[Int(edge)].next
                }
            }
        }

        @_spi(Testing)
        public func isReachable(_ node: Node) -> Bool {
            nodes[node.position].visited == generation
        }
    }

    enum ParameterTag: UInt8 {
        case noRestriction
        case valueRequiredToBeUniform
        case contentsRequiredToBeUniform
    }

    enum CallSiteTag: UInt8 {
        case noRestriction
        case requiredToBeUniform
    }

    enum FunctionTag: UInt8 {
        case noRestriction
        case returnValueMayBeNonUniform
    }

    struct CallSiteRequirement {
        var tag = CallSiteTag.noRestriction
        var severity = SeverityControl.error
    }

    struct ParameterRequirement {
        var tag = ParameterTag.noRestriction
        var severity = SeverityControl.error
    }

    struct ParameterInfo {
        var name: Symbol
        var index: Int
        var value: Node
        var ptrInputContents: Node?
        var ptrOutputContents: Node?

        var tagDirect = ParameterRequirement()
        var tagRetval = ParameterTag.noRestriction

        var pointerMayBecomeNonUniform = false
        var ptrOutputSourceParamValues: [Int] = []
        var ptrOutputSourceParamContents: [Int] = []
    }

    /// C++ `HashMap<String, Node*>`, iterated in insertion order (the C++ order is the hash layout; no loop over one of
    /// these maps depends on the order).
    @_spi(Testing)
    public struct VariableMap {
        private var entries = SymbolMap<Node>()

        @_spi(Testing)
        public init() {}

        @_spi(Testing)
        public var isEmpty: Bool { entries.isEmpty }

        @_spi(Testing)
        public var count: Int { entries.count }

        /// The names in iteration order.
        @_spi(Testing)
        public var keys: [Symbol] { entries.orderedKeys }

        @_spi(Testing)
        public func find(_ name: Symbol) -> Node? {
            entries.find(name)
        }

        @_spi(Testing)
        public func contains(_ name: Symbol) -> Bool {
            entries.contains(name)
        }

        @_spi(Testing)
        public mutating func set(_ name: Symbol, _ node: Node) {
            entries.set(name, node)
        }

        @_spi(Testing)
        public mutating func removeIf(_ shouldRemove: (Symbol, Node) -> Bool) {
            var kept = SymbolMap<Node>()
            entries.forEachEntry { name, node in
                if !shouldRemove(name, node) {
                    kept.add(name, node)
                }
            }
            entries = kept
        }

        @_spi(Testing)
        @inline(__always)
        public func forEachEntry(_ body: (Symbol, Node) -> Void) {
            entries.forEachEntry(body)
        }
    }

    struct LoopSwitchInfo {
        var varInNodes = VariableMap()
        var varExitNodes = VariableMap()
    }

    // DEV-04: a module-scope variable, which FunctionInfo.getVariable gives a node on its first reference.
    @_spi(Testing)
    public struct ModuleScopeVariable {
        @_spi(Testing)
        public let variable: VariableID
        @_spi(Testing)
        public let isNonUniform: Bool
    }

    @_spi(Testing)
    public typealias ModuleScopeVariables = SymbolMap<ModuleScopeVariable>

    @_spi(Testing)
    public struct FunctionInfo {
        var astNode: FunctionID?
        let requiredToBeUniform: (Node, Node, Node) // indexed: 0=Error, 1=Warning, 2=Info
        @_spi(Testing)
        public let mayBeNonUniform: Node
        @_spi(Testing)
        public let cfStart: Node
        var valueReturn: Node?

        var callSiteTag = CallSiteRequirement()
        var functionTag = FunctionTag.noRestriction

        /// Creates `requiredToBeUniform`, `mayBeNonUniform` and `cfStart`, in that order, as C++ processFunction does.
        @_spi(Testing)
        public init(astNode: FunctionID?, moduleScopeVariables: ModuleScopeVariables) {
            self.astNode = astNode
            var nodes = NodeArena(reservingCapacity: 32)
            let requiredToBeUniformError = nodes.createNode(nil)
            let requiredToBeUniformWarning = nodes.createNode(nil)
            let requiredToBeUniformInfo = nodes.createNode(nil)
            requiredToBeUniform = (requiredToBeUniformError, requiredToBeUniformWarning, requiredToBeUniformInfo)
            mayBeNonUniform = nodes.createNode(nil)
            cfStart = nodes.createNode(nil)
            self.nodes = nodes
            self.moduleScopeVariables = moduleScopeVariables
        }

        // The graph's value before its first function, which processFunction replaces before any read: no nodes.
        fileprivate init() {
            astNode = nil
            requiredToBeUniform = (Node(index: 0), Node(index: 1), Node(index: 2))
            mayBeNonUniform = Node(index: 3)
            cfStart = Node(index: 4)
            nodes = NodeArena(reservingCapacity: 0)
            moduleScopeVariables = ModuleScopeVariables()
        }

        @_spi(Testing)
        public func requiredToBeUniformForSeverity(_ severity: SeverityControl) -> Node? {
            switch severity {
            case .error: requiredToBeUniform.0
            case .warning: requiredToBeUniform.1
            case .info: requiredToBeUniform.2
            case .off: nil
            }
        }

        var parameters: [ParameterInfo] = []

        @_spi(Testing)
        public var nodes: NodeArena
        var scopes: [VariableMap] = []
        @_spi(Testing)
        public var localVarDecls = OrderedSet<Symbol>()
        let moduleScopeVariables: ModuleScopeVariables

        @_spi(Testing)
        public mutating func createNode(_ ast: NodeAST? = nil) -> Node {
            nodes.createNode(ast)
        }

        @_spi(Testing)
        public mutating func addEdge(_ node: Node, _ to: Node) {
            nodes.addEdge(node, to)
        }

        @_spi(Testing)
        public mutating func pushScope() {
            scopes.append(VariableMap())
        }

        @_spi(Testing)
        public mutating func popScopeCapture() -> VariableMap {
            assert(scopes.count > 1)
            return scopes.removeLast()
        }

        @_spi(Testing)
        public mutating func getVariable(_ name: Symbol) -> Node? {
            var i = scopes.count - 1
            while i >= 0 {
                if let node = scopes[i].find(name) {
                    return node
                }
                i -= 1
            }

            // DEV-04: C++ processFunction makes this node up front; unreferenced, it is unreachable from every root.
            guard let variable = moduleScopeVariables.find(name) else {
                return nil
            }
            let node = createNode(.variable(variable.variable))
            if variable.isNonUniform {
                addEdge(node, mayBeNonUniform)
            } else {
                addEdge(node, cfStart)
            }
            scopes[0].set(name, node)
            return node
        }

        @_spi(Testing)
        public mutating func setVariable(_ name: Symbol, _ node: Node) {
            assert(!scopes.isEmpty)
            scopes[scopes.count - 1].set(name, node)
        }

        @_spi(Testing)
        public mutating func resetVisited() {
            nodes.resetVisited()
        }
    }

    // The graph is not read once its function is processed: calls read only its tags and parameters.
    struct CalleeInfo {
        let astNode: FunctionID?
        let callSiteTag: CallSiteRequirement
        let functionTag: FunctionTag
        let parameters: [ParameterInfo]

        init(_ info: borrowing FunctionInfo) {
            astNode = info.astNode
            callSiteTag = info.callSiteTag
            functionTag = info.functionTag
            parameters = info.parameters
        }
    }

    /// C++ `HashMap<String, FunctionInfo>`, only searched; it keeps what calls read of each processed function.
    typealias FunctionInfoMap = SymbolMap<CalleeInfo>

    let shaderModule: ShaderModule
    var functions = FunctionInfoMap()
    var currentFunction = FunctionInfo()
    var severityStack: [SeverityControl] = []
    var subgroupSeverityStack: [SeverityControl] = []
    var warnings: [CompilationMessage] = []
    // C++ `Vector<LoopSwitchInfo*>`: indices into `loopSwitchInfos`.
    var loopSwitchStack: [Int] = []
    var loopSwitchInfos: [LoopSwitchInfo] = []
    // When the subgroup_uniformity language feature is supported, the analysis runs
    // once per uniformity scope (workgroup/draw, then subgroup). In the subgroup scope,
    // subgroup/quad ops relax to the subgroup's narrower uniformity requirements while
    // barriers/derivatives (workgroup concerns) impose no requirement.
    var analyzingSubgroupScope = false
    var supportsSubgroupUniformity = false
    // DEV-04: the module-scope variables, collected once per analyzeScope.
    var moduleScopeVariables = ModuleScopeVariables()

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    struct LValue {
        var cf: Node
        var newVal: Node
        var rootIdentifier: Symbol?
    }

    mutating func currentSeverity() -> SeverityControl {
        guard let severity = severityStack.last else {
            wgslFatal("currentSeverity with an empty severity stack", cppSite: "UniformityAnalysis.cpp:226")
        }
        return severity
    }

    mutating func currentSubgroupSeverity() -> SeverityControl {
        guard let severity = subgroupSeverityStack.last else {
            wgslFatal("currentSubgroupSeverity with an empty severity stack", cppSite: "UniformityAnalysis.cpp:231")
        }
        return severity
    }

    @_spi(Testing)
    @inline(__always)
    public static func rootIdentifier(_ shaderModule: borrowing ShaderModule, _ expr: ExpressionID) -> IdentifierExpression? {
        var expr = expr
        while true {
            if let ident = shaderModule.dynamicDowncast(IdentifierExpression.self, expr) {
                return ident
            }
            if let field = shaderModule.dynamicDowncast(FieldAccessExpression.self, expr) {
                expr = field.base
                continue
            }
            if let index = shaderModule.dynamicDowncast(IndexAccessExpression.self, expr) {
                expr = index.base
                continue
            }
            if let identity = shaderModule.dynamicDowncast(IdentityExpression.self, expr) {
                expr = identity.expression
                continue
            }
            if let unary = shaderModule.dynamicDowncast(UnaryExpression.self, expr) {
                expr = unary.expression
                continue
            }
            if let deref = shaderModule.dynamicDowncast(PointerDereferenceExpression.self, expr) {
                expr = deref.target
                continue
            }
            return nil
        }
    }

    @_spi(Testing)
    @inline(__always)
    public static func isGlobalNonUniform(_ shaderModule: borrowing ShaderModule, _ globalVar: VariableID) -> Bool {
        if let addressSpace = shaderModule[globalVar].addressSpace {
            switch addressSpace {
            case .private, .workgroup:
                return true
            case .storage:
                if let accessMode = shaderModule[globalVar].accessMode, accessMode != .read {
                    return true
                }
            case .handle:
                if let texStorage = shaderModule.types.getIf(Types.TextureStorage.self, shaderModule[globalVar].storeType) {
                    if texStorage.access != .read {
                        return true
                    }
                }
            case .function, .uniform:
                break
            }
        }
        return false
    }

    mutating func run() -> FailedCheck? {
        // subgroup_uniformity is a WGSL language feature (advertised unconditionally via
        // WGSLLanguageFeatures) rather than a device feature, and WebKit's WGSL implementation
        // always supports it. When supported, the analysis runs an additional subgroup scope.
        //
        // Subgroup/quad ops require `enable subgroups;` (enforced in TypeCheck), and they are
        // the only construct the subgroup scope enforces more strictly than the workgroup/draw
        // scope -- every other subgroup-scope difference is a relaxation. So when the extension
        // is not enabled, no subgroup/quad op can reach this analysis and the subgroup scope
        // can only reproduce (never add) diagnostics, making it safe to skip.
        supportsSubgroupUniformity = shaderModule.enabledExtensions.contains(.subgroups)

        // https://www.w3.org/TR/WGSL/#uniformity
        // The analysis runs once per uniformity scope. Workgroup and draw scopes are
        // equivalent (they differ only by shader stage). When the subgroup_uniformity
        // feature is supported there is an additional, narrower subgroup scope, and a
        // program is valid only if it passes in every scope.
        func analyzeScope(_ subgroupScope: Bool) -> FailedCheck? {
            analyzingSubgroupScope = subgroupScope
            functions.clear()
            functions.reserveInitialCapacity(Self.functionCount(shaderModule))
            loopSwitchStack.removeAll()
            loopSwitchInfos.removeAll()
            severityStack.removeAll()
            subgroupSeverityStack.removeAll()
            severityStack.append(shaderModule.severityFor(.derivativeUniformity) ?? .error)
            subgroupSeverityStack.append(shaderModule.severityFor(.subgroupUniformity) ?? .error)
            moduleScopeVariables = Self.collectModuleScopeVariables(shaderModule)

            var declarations = shaderModule.cursor(shaderModule.declarations)
            while let declaration = shaderModule.next(&declarations) {
                if case .function(let function) = declaration {
                    if let error = processFunction(function) {
                        return FailedCheck(errors: [error], warnings: warnings)
                    }
                }
            }

            if !warnings.isEmpty {
                return FailedCheck(errors: [], warnings: warnings)
            }
            return nil
        }

        // Workgroup/draw scope.
        if let failure = analyzeScope(false) {
            return failure
        }

        // Subgroup scope (only distinct when the feature is supported).
        if supportsSubgroupUniformity {
            if let failure = analyzeScope(true) {
                return failure
            }
        }

        return nil
    }

    private static let severities: [SeverityControl] = [.error, .warning, .info]

    mutating func processFunction(_ function: FunctionID) -> CompilationMessage? {
        let isEntryPoint = shaderModule[function].stage != nil

        // C++ adds the FunctionInfo to m_functions here; it is added at the end instead, which no lookup can observe
        // because GlobalSorting rejects recursion.
        let functionName = shaderModule.symbol(of: shaderModule[function].name)
        currentFunction = FunctionInfo(astNode: function, moduleScopeVariables: moduleScopeVariables)

        if shaderModule[function].maybeReturnType != nil {
            currentFunction.valueReturn = currentFunction.createNode()
        }

        currentFunction.pushScope()

        let parameters = shaderModule[function].parameters
        currentFunction.parameters.reserveCapacity(shaderModule.count(parameters))
        var parameterCursor = shaderModule.cursor(parameters)
        while let param = shaderModule.next(&parameterCursor) {
            let paramName = shaderModule.symbol(of: shaderModule[param].name)
            var paramInfo = ParameterInfo(
                name: paramName,
                index: currentFunction.parameters.count,
                value: currentFunction.createNode(.parameter(param))
            )

            if isEntryPoint {
                var isNonUniform = true
                if let builtin = shaderModule[param].builtin {
                    switch builtin {
                    case .numWorkgroups, .workgroupId, .numSubgroups:
                        isNonUniform = false
                    case .subgroupSize:
                        // subgroup_size is uniform within a workgroup (compute) but may
                        // vary between invocations within a draw command (fragment). At
                        // subgroup scope it is always uniform.
                        if shaderModule[function].stage == .compute || analyzingSubgroupScope {
                            isNonUniform = false
                        }
                    case .subgroupId:
                        // subgroup_id is uniform only at subgroup uniformity scope.
                        if analyzingSubgroupScope {
                            isNonUniform = false
                        }
                    case .clipDistances, .fragDepth, .frontFacing, .globalInvocationId, .instanceIndex, .localInvocationId,
                        .localInvocationIndex, .position, .primitiveIndex, .sampleIndex, .sampleMask, .subgroupInvocationId,
                        .vertexIndex:
                        break
                    }
                }

                if isNonUniform {
                    currentFunction.addEdge(paramInfo.value, currentFunction.mayBeNonUniform)
                } else {
                    currentFunction.addEdge(paramInfo.value, currentFunction.cfStart)
                }
            } else {
                currentFunction.addEdge(paramInfo.value, currentFunction.cfStart)
            }

            let isPointerParam =
                shaderModule.types.getIf(Types.Pointer.self, shaderModule.inferredType(of: shaderModule[param].typeName)) != nil

            if isPointerParam {
                let ptrInputContents = currentFunction.createNode(.parameter(param))
                paramInfo.ptrInputContents = ptrInputContents
                currentFunction.addEdge(ptrInputContents, currentFunction.cfStart)
                paramInfo.ptrOutputContents = currentFunction.createNode()
                currentFunction.setVariable(paramName, ptrInputContents)
                currentFunction.localVarDecls.add(paramName)
            } else {
                currentFunction.setVariable(paramName, paramInfo.value)
            }
            currentFunction.parameters.append(paramInfo)
        }

        // DEV-04: C++ makes a node per module-scope variable here (:427-435); getVariable makes one on first reference.

        var pushedFunctionSeverity = false
        if let severity = shaderModule[function].diagnostics.severityFor(.derivativeUniformity) {
            severityStack.append(severity)
            pushedFunctionSeverity = true
        }
        var pushedFunctionSubgroupSeverity = false
        if let severity = shaderModule[function].diagnostics.severityFor(.subgroupUniformity) {
            subgroupSeverityStack.append(severity)
            pushedFunctionSubgroupSeverity = true
        }

        _ = processStatements(
            currentFunction.cfStart,
            shaderModule.downcast(CompoundStatement.self, shaderModule[function].body).statements
        )

        if pushedFunctionSeverity {
            severityStack.removeLast()
        }
        if pushedFunctionSubgroupSeverity {
            subgroupSeverityStack.removeLast()
        }

        var parameterIndex = 0
        while parameterIndex < currentFunction.parameters.count {
            let paramInfo = currentFunction.parameters[parameterIndex]
            if let ptrOutputContents = paramInfo.ptrOutputContents {
                if let currentVal = currentFunction.getVariable(paramInfo.name) {
                    currentFunction.addEdge(ptrOutputContents, currentVal)
                }
            }
            parameterIndex += 1
        }

        // C++ takes `reachable`, the set of the last traverse.
        func getParamTag(_ index: Int) -> ParameterTag {
            let paramInfo = currentFunction.parameters[index]
            if let ptrInputContents = paramInfo.ptrInputContents {
                if currentFunction.nodes.isReachable(ptrInputContents) {
                    return .contentsRequiredToBeUniform
                }
                if currentFunction.nodes.isReachable(paramInfo.value) {
                    return .valueRequiredToBeUniform
                }
            } else {
                if let varNode = currentFunction.getVariable(paramInfo.name), currentFunction.nodes.isReachable(varNode) {
                    return .valueRequiredToBeUniform
                }
                if currentFunction.nodes.isReachable(paramInfo.value) {
                    return .valueRequiredToBeUniform
                }
            }
            return .noRestriction
        }

        var severityIndex = 0
        while severityIndex < Self.severities.count {
            let severity = Self.severities[severityIndex]
            severityIndex += 1
            guard let sentinel = currentFunction.requiredToBeUniformForSeverity(severity) else {
                wgslFatal("requiredToBeUniformForSeverity(.off) in processFunction", cppSite: "UniformityAnalysis.cpp:485")
            }
            currentFunction.resetVisited()
            currentFunction.nodes.traverse(sentinel)

            if currentFunction.nodes.isReachable(currentFunction.mayBeNonUniform) {
                var callName: Symbol?
                var callAst: ExpressionID?
                let edges = currentFunction.nodes.edges(of: sentinel)
                var edgeIndex = 0
                while edgeIndex < edges.count {
                    let edge = edges[edgeIndex]
                    edgeIndex += 1
                    guard let ast = currentFunction.nodes.ast(of: edge) else {
                        continue
                    }
                    guard case .expression(let expression) = ast else {
                        continue
                    }
                    if let callExpr = shaderModule.dynamicDowncast(CallExpression.self, expression) {
                        callAst = expression
                        if let target = shaderModule.dynamicDowncast(IdentifierExpression.self, callExpr.target) {
                            callName = shaderModule.symbol(of: target.identifier)
                        }
                        break
                    }
                }
                guard let callAst else {
                    wgslFatal("a uniformity violation without a call", cppSite: "UniformityAnalysis.cpp:503")
                }
                guard let callName, shaderModule.symbols.length(of: callName) != 0 else {
                    wgslFatal("a uniformity violation by a call without a name", cppSite: "UniformityAnalysis.cpp:504")
                }

                var callText = shaderModule.symbols.text(of: callName)
                if let calleeInfo = functions.find(callName) {
                    guard let astNode = calleeInfo.astNode else {
                        wgslFatal("a FunctionInfo without its function", cppSite: "UniformityAnalysis.cpp:507")
                    }
                    callText = shaderModule.symbols.text(of: shaderModule[astNode].originalName)
                }

                let message: MessageText = "call to '\(callText)' requires uniform control flow"
                if severity == .error {
                    return CompilationMessage(text: message, span: shaderModule.span(of: callAst))
                }
                warnings.append(CompilationMessage(text: message, span: shaderModule.span(of: callAst)))
            }

            if currentFunction.nodes.isReachable(currentFunction.cfStart) && currentFunction.callSiteTag.tag == .noRestriction {
                currentFunction.callSiteTag = CallSiteRequirement(tag: .requiredToBeUniform, severity: severity)
            }

            var i = 0
            while i < currentFunction.parameters.count {
                if currentFunction.parameters[i].tagDirect.tag == .noRestriction {
                    let tag = getParamTag(i)
                    if tag != .noRestriction {
                        currentFunction.parameters[i].tagDirect = ParameterRequirement(tag: tag, severity: severity)
                    }
                }
                i += 1
            }
        }

        if let valueReturn = currentFunction.valueReturn {
            currentFunction.resetVisited()
            currentFunction.nodes.traverse(valueReturn)

            if currentFunction.nodes.isReachable(currentFunction.mayBeNonUniform) {
                currentFunction.functionTag = .returnValueMayBeNonUniform
            }

            var i = 0
            while i < currentFunction.parameters.count {
                currentFunction.parameters[i].tagRetval = getParamTag(i)
                i += 1
            }
        }

        var i = 0
        while i < currentFunction.parameters.count {
            if let ptrOutputContents = currentFunction.parameters[i].ptrOutputContents {
                currentFunction.resetVisited()
                currentFunction.nodes.traverse(ptrOutputContents)

                if currentFunction.nodes.isReachable(currentFunction.mayBeNonUniform) {
                    currentFunction.parameters[i].pointerMayBecomeNonUniform = true
                }

                var j = 0
                while j < currentFunction.parameters.count {
                    let tag = getParamTag(j)
                    if tag == .contentsRequiredToBeUniform {
                        currentFunction.parameters[i].ptrOutputSourceParamContents.append(j)
                    } else if tag == .valueRequiredToBeUniform {
                        currentFunction.parameters[i].ptrOutputSourceParamValues.append(j)
                    }
                    j += 1
                }
            }
            i += 1
        }

        functions.set(functionName, CalleeInfo(currentFunction))
        return nil
    }

    @inline(__always)
    static func hasFunction(_ shaderModule: borrowing ShaderModule) -> Bool {
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .function = declaration {
                return true
            }
        }
        return false
    }

    @inline(__always)
    private static func functionCount(_ shaderModule: borrowing ShaderModule) -> Int {
        var count = 0
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .function = declaration {
                count += 1
            }
        }
        return count
    }

    // DEV-04: what C++ processFunction reads of each module-scope variable (UniformityAnalysis.cpp:427-435), by name.
    @_spi(Testing)
    @inline(__always)
    public static func collectModuleScopeVariables(_ shaderModule: borrowing ShaderModule) -> ModuleScopeVariables {
        var moduleScopeVariables = ModuleScopeVariables()
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .variable(let globalVar) = declaration {
                moduleScopeVariables.set(
                    shaderModule.symbol(of: shaderModule[globalVar].name),
                    ModuleScopeVariable(variable: globalVar, isNonUniform: isGlobalNonUniform(shaderModule, globalVar))
                )
            }
        }
        return moduleScopeVariables
    }
}
