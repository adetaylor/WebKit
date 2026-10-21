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

// The C++ loops over `localVarDecls`, `varInNodes`, `varExitNodes` and scope captures run in hash order; each iteration
// touches only its own name, so insertion order builds the same graph.
extension UniformityGraph {
    mutating func processStatements(_ cf: Node, _ statements: ListID<StatementID>) -> Node {
        var cf = cf
        var cursor = shaderModule.cursor(statements)
        while let statement = shaderModule.next(&cursor) {
            cf = processStatement(cf, statement)
            let behaviors = shaderModule[statement].behaviors
            if !behaviors.contains(.next) {
                break
            }
        }
        return cf
    }

    mutating func processStatement(_ cf: Node, _ statement: StatementID) -> Node {
        var cf = cf

        var pushedSeverity = false
        if let severity = shaderModule[statement].diagnostics.severityFor(.derivativeUniformity) {
            severityStack.append(severity)
            pushedSeverity = true
        }
        var pushedSubgroupSeverity = false
        if let severity = shaderModule[statement].diagnostics.severityFor(.subgroupUniformity) {
            subgroupSeverityStack.append(severity)
            pushedSubgroupSeverity = true
        }
        defer {
            if pushedSeverity {
                severityStack.removeLast()
            }
            if pushedSubgroupSeverity {
                subgroupSeverityStack.removeLast()
            }
        }

        switch shaderModule[statement].kind {
        case .compoundStatement(let compound):
            currentFunction.pushScope()
            let cfOut = processStatements(cf, compound.statements)
            let scopeAssignments = currentFunction.popScopeCapture()

            let behaviors = shaderModule[statement].behaviors
            if behaviors.contains(.next) {
                scopeAssignments.forEachEntry { name, node in
                    if currentFunction.getVariable(name) != nil {
                        currentFunction.setVariable(name, node)
                    } else {
                        currentFunction.localVarDecls.remove(name)
                    }
                }
            }
            return cfOut

        case .assignmentStatement(let assign):
            let lValue = processLValueExpression(cf, assign.lhs)
            let (cfR, vR) = processExpression(lValue.cf, assign.rhs)
            currentFunction.addEdge(lValue.newVal, vR)
            if let rootIdent = lValue.rootIdentifier {
                currentFunction.setVariable(rootIdent, lValue.newVal)
            }
            return cfR

        case .phonyAssignmentStatement(let phony):
            let (cfR, _) = processExpression(cf, phony.rhs)
            return cfR

        case .compoundAssignmentStatement(let compAssign):
            let lValue = processLValueExpression(cf, compAssign.leftExpression)
            var lhsLoad: Node?
            if let rootIdent = lValue.rootIdentifier {
                lhsLoad = currentFunction.getVariable(rootIdent)
            }
            let (cfR, vR) = processExpression(lValue.cf, compAssign.rightExpression)

            let result = currentFunction.createNode(.statement(statement))
            currentFunction.addEdge(result, vR)
            if let lhsLoad {
                currentFunction.addEdge(result, lhsLoad)
            }

            currentFunction.addEdge(lValue.newVal, result)
            if let rootIdent = lValue.rootIdentifier {
                currentFunction.setVariable(rootIdent, lValue.newVal)
            }
            return cfR

        case .decrementIncrementStatement(let incDec):
            let lValue = processLValueExpression(cf, incDec.expression)
            var lhsLoad: Node?
            if let rootIdent = lValue.rootIdentifier {
                lhsLoad = currentFunction.getVariable(rootIdent)
            }

            let result = currentFunction.createNode(.statement(statement))
            currentFunction.addEdge(result, lValue.cf)
            if let lhsLoad {
                currentFunction.addEdge(result, lhsLoad)
            }

            currentFunction.addEdge(lValue.newVal, result)
            if let rootIdent = lValue.rootIdentifier {
                currentFunction.setVariable(rootIdent, lValue.newVal)
            }
            return lValue.cf

        case .variableStatement(let varStmt):
            let variable = varStmt.variable

            let node: Node
            if let initializer = shaderModule[variable].maybeInitializer {
                let (cfInit, v) = processExpression(cf, initializer)
                cf = cfInit
                node = v
            } else {
                node = cf
            }

            let name = shaderModule.symbol(of: shaderModule[variable].name)
            currentFunction.setVariable(name, node)
            if shaderModule[variable].flavor == .var {
                currentFunction.localVarDecls.add(name)
            }

            return cf

        case .ifStatement(let ifStmt):
            let (cfCond, vCond) = processExpression(cf, ifStmt.test)

            let condNode = currentFunction.createNode(.statement(statement))
            currentFunction.nodes.setAffectsControlFlow(condNode)
            currentFunction.addEdge(condNode, vCond)
            // Code guarded by (or following, via an interrupting branch) this `if` is
            // reachable only along the control flow that reached the condition, so it
            // must inherit the uniformity of the incoming control flow. Without this
            // edge, an op inside `if u { op }` nested in a non-uniform loop would lose
            // the loop's non-uniformity.
            currentFunction.addEdge(condNode, cfCond)

            currentFunction.pushScope()
            let cfTrue = processStatements(condNode, shaderModule.downcast(CompoundStatement.self, ifStmt.trueBody).statements)
            var trueVars = currentFunction.popScopeCapture()

            // Remove variables from localVarDecls that were declared only in this scope
            trueVars.removeIf { name, _ in
                if currentFunction.getVariable(name) == nil {
                    currentFunction.localVarDecls.remove(name)
                    return true
                }
                return false
            }

            let trueHasNext = shaderModule[ifStmt.trueBody].behaviors.contains(.next)

            var falseVars = VariableMap()
            var cfFalse: Node?
            var falseHasNext = true
            if let falseBody = ifStmt.maybeFalseBody {
                currentFunction.pushScope()
                cfFalse = processStatement(condNode, falseBody)
                falseVars = currentFunction.popScopeCapture()

                falseVars.removeIf { name, _ in
                    if currentFunction.getVariable(name) == nil {
                        currentFunction.localVarDecls.remove(name)
                        return true
                    }
                    return false
                }

                falseHasNext = shaderModule[falseBody].behaviors.contains(.next)
            }

            var varNames = currentFunction.localVarDecls.makeIterator()
            while let varName = varNames.next() {
                if !trueVars.contains(varName) && !falseVars.contains(varName) {
                    continue
                }

                let mergeNode = currentFunction.createNode()
                if trueHasNext {
                    var value = trueVars.find(varName)
                    if value == nil {
                        value = currentFunction.getVariable(varName)
                    }
                    assert(value != nil)
                    if let value {
                        currentFunction.addEdge(mergeNode, value)
                    }
                }
                if falseHasNext {
                    var value = falseVars.find(varName)
                    if value == nil {
                        value = currentFunction.getVariable(varName)
                    }
                    assert(value != nil)
                    if let value {
                        currentFunction.addEdge(mergeNode, value)
                    }
                }
                currentFunction.setVariable(varName, mergeNode)
            }

            let behaviors = shaderModule[statement].behaviors
            if behaviors != .next {
                let cfEnd = currentFunction.createNode()
                currentFunction.addEdge(cfEnd, cfTrue)
                if let cfFalse {
                    currentFunction.addEdge(cfEnd, cfFalse)
                }
                return cfEnd
            }
            return cf

        case .switchStatement(let switchStmt):
            let (_, vCond) = processExpression(cf, switchStmt.value)

            let condNode = currentFunction.createNode(.statement(statement))
            currentFunction.nodes.setAffectsControlFlow(condNode)
            currentFunction.addEdge(condNode, vCond)

            let behaviors = shaderModule[statement].behaviors
            var cfEnd: Node?
            if behaviors != .next {
                cfEnd = currentFunction.createNode()
            }

            let loopSwitchInfo = loopSwitchInfos.count
            loopSwitchInfos.append(LoopSwitchInfo())
            loopSwitchStack.append(loopSwitchInfo)

            func processCase(_ body: StatementID) {
                currentFunction.pushScope()
                let cfCase = processStatements(condNode, shaderModule.downcast(CompoundStatement.self, body).statements)
                if let cfEnd {
                    currentFunction.addEdge(cfEnd, cfCase)
                }

                let caseBehaviors = shaderModule[body].behaviors
                if caseBehaviors.contains(.next) {
                    let caseVars = currentFunction.popScopeCapture()
                    var varNames = currentFunction.localVarDecls.makeIterator()
                    while let varName = varNames.next() {
                        let exitNode: Node
                        if let existing = loopSwitchInfos[loopSwitchInfo].varExitNodes.find(varName) {
                            exitNode = existing
                        } else {
                            exitNode = currentFunction.createNode()
                            loopSwitchInfos[loopSwitchInfo].varExitNodes.set(varName, exitNode)
                        }
                        if let caseValue = caseVars.find(varName) {
                            currentFunction.addEdge(exitNode, caseValue)
                        } else {
                            if let preVal = currentFunction.getVariable(varName) {
                                currentFunction.addEdge(exitNode, preVal)
                            }
                        }
                    }
                } else {
                    _ = currentFunction.popScopeCapture()
                }
            }

            var clauses = shaderModule.cursor(switchStmt.clauses)
            while let clause = shaderModule.next(&clauses) {
                processCase(shaderModule[clause].body)
            }
            processCase(shaderModule[switchStmt.defaultClause].body)

            loopSwitchStack.removeLast()

            let exitNodes = loopSwitchInfos[loopSwitchInfo].varExitNodes
            exitNodes.forEachEntry { name, exitNode in
                currentFunction.setVariable(name, exitNode)
            }

            return cfEnd ?? cf

        case .forStatement(let forStmt):
            var cfInit = cf
            if let initializer = forStmt.maybeInitializer {
                cfInit = processStatement(cf, initializer)
            }

            let cfx = currentFunction.createNode()

            let loopSwitchInfo = loopSwitchInfos.count
            loopSwitchInfos.append(LoopSwitchInfo())
            loopSwitchStack.append(loopSwitchInfo)

            var inVarNames = currentFunction.localVarDecls.makeIterator()
            while let varName = inVarNames.next() {
                let inNode = currentFunction.createNode()
                if let currentVal = currentFunction.getVariable(varName) {
                    currentFunction.addEdge(inNode, currentVal)
                }
                loopSwitchInfos[loopSwitchInfo].varInNodes.set(varName, inNode)
                currentFunction.setVariable(varName, inNode)
            }

            var cfStart = cfx
            if let test = forStmt.maybeTest {
                let (_, vCond) = processExpression(cfx, test)
                let condEnd = currentFunction.createNode(.statement(statement))
                currentFunction.nodes.setAffectsControlFlow(condEnd)
                currentFunction.addEdge(condEnd, vCond)
                cfStart = condEnd

                var exitVarNames = currentFunction.localVarDecls.makeIterator()
                while let varName = exitVarNames.next() {
                    let exitNode: Node
                    if let existing = loopSwitchInfos[loopSwitchInfo].varExitNodes.find(varName) {
                        exitNode = existing
                    } else {
                        exitNode = currentFunction.createNode()
                        loopSwitchInfos[loopSwitchInfo].varExitNodes.set(varName, exitNode)
                    }
                    if let currentVal = currentFunction.getVariable(varName) {
                        currentFunction.addEdge(exitNode, currentVal)
                    }
                }
            }

            var cf1 = processStatements(cfStart, shaderModule.downcast(CompoundStatement.self, forStmt.body).statements)

            if let update = forStmt.maybeUpdate {
                cf1 = processStatement(cf1, update)
            }

            currentFunction.addEdge(cfx, cf1)
            currentFunction.addEdge(cfx, cfInit)

            let inNodes = loopSwitchInfos[loopSwitchInfo].varInNodes
            inNodes.forEachEntry { name, inNode in
                if let outNode = currentFunction.getVariable(name), outNode != inNode {
                    currentFunction.addEdge(inNode, outNode)
                }
            }

            loopSwitchStack.removeLast()

            let exitNodes = loopSwitchInfos[loopSwitchInfo].varExitNodes
            exitNodes.forEachEntry { name, exitNode in
                currentFunction.setVariable(name, exitNode)
            }

            if let initializer = forStmt.maybeInitializer {
                if let varStmt = shaderModule.dynamicDowncast(VariableStatement.self, initializer) {
                    currentFunction.localVarDecls.remove(shaderModule.symbol(of: shaderModule[varStmt.variable].name))
                }
            }

            let behaviors = shaderModule[statement].behaviors
            if behaviors == .next {
                return cf
            }
            return cfx

        case .whileStatement(let whileStmt):
            let cfx = currentFunction.createNode()

            let loopSwitchInfo = loopSwitchInfos.count
            loopSwitchInfos.append(LoopSwitchInfo())
            loopSwitchStack.append(loopSwitchInfo)

            var inVarNames = currentFunction.localVarDecls.makeIterator()
            while let varName = inVarNames.next() {
                let inNode = currentFunction.createNode()
                if let currentVal = currentFunction.getVariable(varName) {
                    currentFunction.addEdge(inNode, currentVal)
                }
                loopSwitchInfos[loopSwitchInfo].varInNodes.set(varName, inNode)
                currentFunction.setVariable(varName, inNode)
            }

            let (_, vCond) = processExpression(cfx, whileStmt.test)
            let condEnd = currentFunction.createNode(.statement(statement))
            currentFunction.nodes.setAffectsControlFlow(condEnd)
            currentFunction.addEdge(condEnd, vCond)

            var exitVarNames = currentFunction.localVarDecls.makeIterator()
            while let varName = exitVarNames.next() {
                let exitNode: Node
                if let existing = loopSwitchInfos[loopSwitchInfo].varExitNodes.find(varName) {
                    exitNode = existing
                } else {
                    exitNode = currentFunction.createNode()
                    loopSwitchInfos[loopSwitchInfo].varExitNodes.set(varName, exitNode)
                }
                if let currentVal = currentFunction.getVariable(varName) {
                    currentFunction.addEdge(exitNode, currentVal)
                }
            }

            let cf1 = processStatements(condEnd, shaderModule.downcast(CompoundStatement.self, whileStmt.body).statements)

            currentFunction.addEdge(cfx, cf1)
            currentFunction.addEdge(cfx, cf)

            let inNodes = loopSwitchInfos[loopSwitchInfo].varInNodes
            inNodes.forEachEntry { name, inNode in
                if let outNode = currentFunction.getVariable(name), outNode != inNode {
                    currentFunction.addEdge(inNode, outNode)
                }
            }

            loopSwitchStack.removeLast()

            let exitNodes = loopSwitchInfos[loopSwitchInfo].varExitNodes
            exitNodes.forEachEntry { name, exitNode in
                currentFunction.setVariable(name, exitNode)
            }

            let behaviors = shaderModule[statement].behaviors
            if behaviors == .next {
                return cf
            }
            return cfx

        case .loopStatement(let loopStmt):
            let cfx = currentFunction.createNode()

            let loopSwitchInfo = loopSwitchInfos.count
            loopSwitchInfos.append(LoopSwitchInfo())
            loopSwitchStack.append(loopSwitchInfo)

            var inVarNames = currentFunction.localVarDecls.makeIterator()
            while let varName = inVarNames.next() {
                let inNode = currentFunction.createNode()
                if let currentVal = currentFunction.getVariable(varName) {
                    currentFunction.addEdge(inNode, currentVal)
                }
                loopSwitchInfos[loopSwitchInfo].varInNodes.set(varName, inNode)
                currentFunction.setVariable(varName, inNode)
            }

            currentFunction.pushScope()
            var cf1 = processStatements(cfx, loopStmt.body)

            if let continuing = loopStmt.continuing {
                let bodyBehaviors = loopStmt.bodyBehaviors
                if bodyBehaviors.contains(.next) || bodyBehaviors.contains(.continue) {
                    cf1 = processStatements(cf1, continuing.body)

                    if let breakIf = continuing.breakIf {
                        let (_, vBr) = processExpression(cf1, breakIf)

                        let breakIfNode = currentFunction.createNode(.expression(breakIf))
                        currentFunction.nodes.setAffectsControlFlow(breakIfNode)
                        currentFunction.addEdge(breakIfNode, vBr)

                        var exitVarNames = currentFunction.localVarDecls.makeIterator()
                        while let varName = exitVarNames.next() {
                            let exitNode: Node
                            if let existing = loopSwitchInfos[loopSwitchInfo].varExitNodes.find(varName) {
                                exitNode = existing
                            } else {
                                exitNode = currentFunction.createNode()
                                loopSwitchInfos[loopSwitchInfo].varExitNodes.set(varName, exitNode)
                            }
                            if let currentVal = currentFunction.getVariable(varName) {
                                currentFunction.addEdge(exitNode, currentVal)
                            }
                        }

                        let cfBreakEnd = currentFunction.createNode()
                        currentFunction.addEdge(cfBreakEnd, breakIfNode)
                        cf1 = cfBreakEnd
                    }
                }
            }

            let bodyTopVars = currentFunction.popScopeCapture()
            bodyTopVars.forEachEntry { name, node in
                if currentFunction.getVariable(name) != nil {
                    currentFunction.setVariable(name, node)
                } else {
                    currentFunction.localVarDecls.remove(name)
                }
            }

            currentFunction.addEdge(cfx, cf1)
            currentFunction.addEdge(cfx, cf)

            let inNodes = loopSwitchInfos[loopSwitchInfo].varInNodes
            inNodes.forEachEntry { name, inNode in
                if let outNode = currentFunction.getVariable(name), outNode != inNode {
                    currentFunction.addEdge(inNode, outNode)
                }
            }

            loopSwitchStack.removeLast()

            let exitNodes = loopSwitchInfos[loopSwitchInfo].varExitNodes
            exitNodes.forEachEntry { name, exitNode in
                currentFunction.setVariable(name, exitNode)
            }

            let behaviors = shaderModule[statement].behaviors
            if behaviors == .next {
                return cf
            }
            return cfx

        case .breakStatement:
            if let loopSwitchInfo = loopSwitchStack.last {
                var varNames = currentFunction.localVarDecls.makeIterator()
                while let varName = varNames.next() {
                    let exitNode: Node
                    if let existing = loopSwitchInfos[loopSwitchInfo].varExitNodes.find(varName) {
                        exitNode = existing
                    } else {
                        exitNode = currentFunction.createNode()
                        loopSwitchInfos[loopSwitchInfo].varExitNodes.set(varName, exitNode)
                    }
                    if let currentVal = currentFunction.getVariable(varName) {
                        currentFunction.addEdge(exitNode, currentVal)
                    }
                }
            }
            return cf

        case .continueStatement:
            var i = loopSwitchStack.count - 1
            while i >= 0 {
                let loopSwitchInfo = loopSwitchStack[i]
                if !loopSwitchInfos[loopSwitchInfo].varInNodes.isEmpty {
                    let inNodes = loopSwitchInfos[loopSwitchInfo].varInNodes
                    inNodes.forEachEntry { name, inNode in
                        if let outNode = currentFunction.getVariable(name), outNode != inNode {
                            currentFunction.addEdge(inNode, outNode)
                        }
                    }
                    break
                }
                i -= 1
            }
            return cf

        case .returnStatement(let retStmt):
            if let expression = retStmt.maybeExpression, let valueReturn = currentFunction.valueReturn {
                let (cfR, v) = processExpression(cf, expression)
                currentFunction.addEdge(valueReturn, v)
                cf = cfR
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
            return cf

        case .discardStatement:
            return cf

        case .callStatement(let callStmt):
            let (cfOut, _) = processCall(cf, shaderModule.downcast(CallExpression.self, callStmt.call), callStmt.call)
            return cfOut

        case .constAssertStatement:
            return cf
        }
    }
}
