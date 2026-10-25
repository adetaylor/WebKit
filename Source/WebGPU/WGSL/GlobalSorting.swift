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

private struct Graph: ~Copyable {
    struct Edge: SmallKey {
        let source: Int
        let target: Int

        var smallKeyBits: UInt64 { UInt64(truncatingIfNeeded: source) << 32 | UInt64(truncatingIfNeeded: target) }
    }

    struct Node {
        let index: Int
        let astNode: Declaration
        // The C++ ListHashSet<Edge>s, as indices into `edges` in insertion order. An edge leaves its source's outgoing
        // set exactly when it leaves the graph's, so `isEdgeRemoved` tracks both; incoming sets never shrink.
        var incomingEdges: [Int] = []
        var outgoingEdges: [Int] = []
        var outgoingEdgeCount = 0

        init(index: Int, astNode: Declaration) {
            self.index = index
            self.astNode = astNode
        }
    }

    private(set) var nodes: [Node] = []
    private var nodeMap = SymbolMap<Int>()
    // C++ m_edges: every edge added, in insertion order, of which the set is those not removed.
    private(set) var edges: [Edge] = []
    private var edgeSet = SmallKeyMap<Edge, Void>()
    private var isEdgeRemoved: [Bool] = []
    private var edgeCount = 0

    init(capacity: Int) {
        nodes.reserveCapacity(capacity)
        nodeMap.reserveInitialCapacity(capacity)
    }

    @inline(__always)
    mutating func addNode(_ index: Int, _ astNode: Declaration, _ shaderModule: borrowing ShaderModule) -> Int? {
        let isConstAssert = if case .constAssert = astNode { true } else { false }
        if !isConstAssert && nodeMap.contains(shaderModule.symbol(of: shaderModule.name(of: astNode))) {
            return nil
        }

        nodes.append(Node(index: index, astNode: astNode))
        if !isConstAssert {
            nodeMap.add(shaderModule.symbol(of: shaderModule.name(of: astNode)), index)
        }
        return index
    }

    func getNode(_ identifier: Symbol) -> Int? {
        nodeMap.find(identifier)
    }

    var isEdgeSetEmpty: Bool { edgeCount == 0 }

    mutating func addEdge(_ source: Int, _ target: Int) {
        let edge = Edge(source: source, target: target)
        guard edgeSet.add(edge, ()) else {
            return
        }
        nodes[source].outgoingEdges.append(edges.count)
        nodes[source].outgoingEdgeCount += 1
        nodes[target].incomingEdges.append(edges.count)
        edges.append(edge)
        isEdgeRemoved.append(false)
        edgeCount += 1
    }

    // C++ `edge.source().outgoingEdges().remove(edge); graph.edges().remove(edge);`
    mutating func removeEdge(_ edge: Int) {
        guard !isEdgeRemoved[edge] else {
            return
        }
        isEdgeRemoved[edge] = true
        nodes[edges[edge].source].outgoingEdgeCount -= 1
        edgeCount -= 1
    }

    // C++ `node.outgoingEdges().first()`; nil where the C++ dereferences the null head of an empty set.
    func firstOutgoingEdge(_ node: Int) -> Edge? {
        let outgoingEdges = nodes[node].outgoingEdges
        var position = 0
        while position < outgoingEdges.count {
            let edge = outgoingEdges[position]
            if !isEdgeRemoved[edge] {
                return edges[edge]
            }
            position += 1
        }
        return nil
    }
}

private struct Empty {}

private struct GraphBuilder: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<Empty>()

    private var graph: Graph
    private let currentNode: Int
    private var expressionDepth = GlobalSortingExpressionDepth()

    // lint-exempt-next-line(L-VISIT-1): the C++ static entry GraphBuilder::visit(Graph&, Graph::Node&), not a visitor hook
    static func visit(_ shaderModule: inout ShaderModule, _ graph: inout Graph, _ node: Int) throws(CompilationMessage) {
        let astNode = graph.nodes[node].astNode
        var graphBuilder = GraphBuilder(shaderModule: shaderModule, graph: graph, node: node)
        graphBuilder.visit(astNode)
        let result = graphBuilder.result()
        shaderModule = graphBuilder.shaderModule
        graph = graphBuilder.graph
        if let result {
            throw result
        }
    }

    private init(shaderModule: consuming ShaderModule, graph: consuming Graph, node: Int) {
        self.shaderModule = shaderModule
        self.graph = graph
        self.currentNode = node
    }

    mutating func visit(_ parameter: ParameterID) {
        introduceVariable(shaderModule[parameter].name)
        visitChildren(parameter)
    }

    mutating func visit(_ variable: VariableStatement, _ id: StatementID) {
        introduceVariable(shaderModule[variable.variable].name)
        visitChildren(variable, id)
    }

    mutating func visit(_ expression: ExpressionID) {
        guard let expressionDepthScope = expressionDepth.enter() else {
            setError(GlobalSortingExpressionDepth.limitError(at: shaderModule.span(of: expression)))
            return
        }
        defer { expressionDepth.leave(expressionDepthScope) }

        dispatch(expression)
    }

    mutating func visit(_ identifier: IdentifierExpression, _ id: ExpressionID) {
        readVariable(identifier.identifier)
    }

    private mutating func introduceVariable(_ name: IdentifierID) {
        introduceVariable(name, Empty())
    }

    private mutating func readVariable(_ name: IdentifierID) {
        let symbol = shaderModule.symbol(of: name)
        if context.readVariable(symbol) != nil {
            return
        }
        if let node = graph.getNode(symbol) {
            graph.addEdge(currentNode, node)
        }
    }
}

private func reorder(_ shaderModule: inout ShaderModule, _ list: ListID<Declaration>) -> FailedCheck? {
    var graph = Graph(capacity: shaderModule.count(list))
    var graphNodeList: [Int] = []
    graphNodeList.reserveCapacity(shaderModule.count(list))
    var index = 0
    var cursor = shaderModule.cursor(list)
    while let node = shaderModule.next(&cursor) {
        let graphNode = graph.addNode(index, node, shaderModule)
        index += 1
        guard let graphNode else {
            // This is unfortunately duplicated between this pass and the type checker
            // since here we only cover redeclarations of the same type (e.g. two
            // variables with the same name), while the type checker will also identify
            // redeclarations of different types (e.g. a variable and a struct with the
            // same name)
            let message: MessageText = "redeclaration of '\(name(shaderModule, node))'"
            return FailedCheck(errors: [CompilationMessage(text: message, span: shaderModule.span(of: node))], warnings: [])
        }
        graphNodeList.append(graphNode)
    }

    for graphNode in graphNodeList {
        do throws(CompilationMessage) {
            try GraphBuilder.visit(&shaderModule, &graph, graphNode)
        } catch {
            return FailedCheck(errors: [error], warnings: [])
        }
    }

    shaderModule.clear(list)

    // DEV-03: the C++ recursion is as deep as the longest dependency chain and overflows the stack. This walks an
    // explicit stack of (node, next incoming edge) in the same order; a node's incoming edges never change meanwhile.
    var stack: [(node: Int, nextIncomingEdge: Int)] = []
    func processNode(_ node: Int, _ currentIndex: Int) {
        shaderModule.append(list, graph.nodes[node].astNode)
        stack.append((node, 0))
        while let top = stack.last {
            let incomingEdges = graph.nodes[top.node].incomingEdges
            guard top.nextIncomingEdge < incomingEdges.count else {
                stack.removeLast()
                continue
            }
            stack[stack.count - 1].nextIncomingEdge = top.nextIncomingEdge + 1
            let edge = incomingEdges[top.nextIncomingEdge]
            let source = graph.edges[edge].source
            graph.removeEdge(edge)
            if graph.nodes[source].outgoingEdgeCount == 0 && graph.nodes[source].index < currentIndex {
                shaderModule.append(list, graph.nodes[source].astNode)
                stack.append((source, 0))
            }
        }
    }

    var nodeIndex = 0
    while nodeIndex < graph.nodes.count {
        if graph.nodes[nodeIndex].outgoingEdgeCount == 0 {
            processNode(nodeIndex, graph.nodes[nodeIndex].index)
        }
        nodeIndex += 1
    }

    if graph.isEdgeSetEmpty {
        return nil
    }

    nodeIndex = 0
    while nodeIndex < graph.nodes.count && graph.nodes[nodeIndex].outgoingEdgeCount == 0 {
        nodeIndex += 1
    }
    guard nodeIndex < graph.nodes.count else {
        wgslFatal("edges remain but no node has an outgoing edge", cppSite: "GlobalSorting.cpp:317")
    }
    var cycleNode = nodeIndex
    var node = cycleNode
    var visited = [Bool](repeating: false, count: graph.nodes.count)
    while true {
        guard let edge = graph.firstOutgoingEdge(node) else {
            wgslFatal("a node on the dependency path has no outgoing edge", cppSite: "GlobalSorting.cpp:324")
        }
        visited[node] = true
        node = edge.target
        if visited[node] {
            cycleNode = node
            break
        }
    }
    var error: MessageText = "encountered a dependency cycle: \(name(shaderModule, graph.nodes[cycleNode].astNode))"
    repeat {
        guard let edge = graph.firstOutgoingEdge(node) else {
            wgslFatal("a node on the dependency cycle has no outgoing edge", cppSite: "GlobalSorting.cpp:334")
        }
        node = edge.target
        error.append(" -> \(name(shaderModule, graph.nodes[node].astNode))")
    } while node != cycleNode
    return FailedCheck(
        errors: [CompilationMessage(text: error, span: shaderModule.span(of: graph.nodes[cycleNode].astNode))],
        warnings: []
    )
}

@_spi(Testing)
public func reorderGlobals(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    let declarations = shaderModule.declarations
    if let maybeError = reorder(&shaderModule, declarations) {
        return maybeError
    }
    return nil
}

// C++ `declaration.name()` appended as a String.
private func name(_ shaderModule: borrowing ShaderModule, _ declaration: Declaration) -> MessageText {
    shaderModule.symbols.text(of: shaderModule.symbol(of: shaderModule.name(of: declaration)))
}
