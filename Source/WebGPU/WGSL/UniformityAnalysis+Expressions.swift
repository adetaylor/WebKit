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

extension UniformityGraph {
    mutating func processExpression(_ cf: Node, _ expression: ExpressionID) -> (Node, Node) {
        switch shaderModule[expression].kind {
        case .abstractFloatLiteral, .abstractIntegerLiteral, .boolLiteral, .float16Literal, .float32Literal, .signed32Literal,
            .unsigned32Literal:
            return (cf, cf)

        case .identifierExpression(let identExpr):
            let node = currentFunction.createNode(.expression(expression))
            let currentValue = currentFunction.getVariable(shaderModule.symbol(of: identExpr.identifier))
            if let currentValue {
                currentFunction.addEdge(node, currentValue)
            }
            return (cf, node)

        case .identityExpression(let identityExpr):
            return processExpression(cf, identityExpr.expression)

        case .unaryExpression(let unaryExpr):
            if unaryExpr.operation == .addressOf {
                return processAddressOf(cf, unaryExpr.expression)
            }
            return processExpression(cf, unaryExpr.expression)

        case .pointerDereferenceExpression(let derefExpr):
            return processExpression(cf, derefExpr.target)

        case .binaryExpression(let binaryExpr):
            let isShortCircuit = binaryExpr.operation == .shortCircuitAnd || binaryExpr.operation == .shortCircuitOr

            if isShortCircuit {
                let (_, v1) = processExpression(cf, binaryExpr.leftExpression)
                let scNode = currentFunction.createNode(.expression(expression))
                currentFunction.nodes.setAffectsControlFlow(scNode)
                currentFunction.addEdge(scNode, v1)
                let (_, v2) = processExpression(scNode, binaryExpr.rightExpression)
                let result = currentFunction.createNode(.expression(expression))
                currentFunction.addEdge(result, v1)
                currentFunction.addEdge(result, v2)
                return (cf, result)
            }

            let (cf1, v1) = processExpression(cf, binaryExpr.leftExpression)
            let (cf2, v2) = processExpression(cf1, binaryExpr.rightExpression)
            let result = currentFunction.createNode(.expression(expression))
            currentFunction.addEdge(result, v1)
            currentFunction.addEdge(result, v2)
            return (cf2, result)

        case .callExpression(let callExpr):
            return processCall(cf, callExpr, expression)

        case .indexAccessExpression(let indexExpr):
            let (cf1, v1) = processExpression(cf, indexExpr.base)
            let (cf2, v2) = processExpression(cf1, indexExpr.index)
            let result = currentFunction.createNode(.expression(expression))
            currentFunction.addEdge(result, v1)
            currentFunction.addEdge(result, v2)
            return (cf2, result)

        case .fieldAccessExpression(let fieldExpr):
            if case .unaryExpression(let unaryBase) = shaderModule[fieldExpr.base].kind {
                if unaryBase.operation == .addressOf {
                    return processExpression(cf, unaryBase.expression)
                }
            }
            return processExpression(cf, fieldExpr.base)

        case .checkedIndexAccessExpression, .arrayTypeExpression, .elaboratedTypeExpression, .referenceTypeExpression:
            return (cf, cf)
        }
    }

    mutating func processAddressOf(_ cf: Node, _ expression: ExpressionID) -> (Node, Node) {
        switch shaderModule[expression].kind {
        case .identifierExpression:
            return (cf, cf)

        case .fieldAccessExpression(let fieldExpr):
            return processAddressOf(cf, fieldExpr.base)

        case .indexAccessExpression(let indexExpr):
            let (cf1, baseVal) = processAddressOf(cf, indexExpr.base)
            let (cf2, indexVal) = processExpression(cf1, indexExpr.index)
            let result = currentFunction.createNode(.expression(expression))
            currentFunction.addEdge(result, baseVal)
            currentFunction.addEdge(result, indexVal)
            return (cf2, result)

        case .identityExpression(let identityExpr):
            return processAddressOf(cf, identityExpr.expression)

        case .pointerDereferenceExpression(let derefExpr):
            return processExpression(cf, derefExpr.target)

        case .unaryExpression(let unaryExpr):
            if unaryExpr.operation == .dereference {
                return processExpression(cf, unaryExpr.expression)
            }
            return processAddressOf(cf, unaryExpr.expression)

        case .abstractFloatLiteral, .abstractIntegerLiteral, .binaryExpression, .boolLiteral, .callExpression, .float32Literal,
            .float16Literal, .checkedIndexAccessExpression, .signed32Literal, .unsigned32Literal, .arrayTypeExpression,
            .elaboratedTypeExpression, .referenceTypeExpression:
            return processExpression(cf, expression)
        }
    }

    mutating func processLValueExpression(_ cf: Node, _ expr: ExpressionID, _ isPartialReference: Bool = false) -> LValue {
        switch shaderModule[expr].kind {
        case .identifierExpression(let identExpr):
            let name = shaderModule.symbol(of: identExpr.identifier)
            let value = currentFunction.createNode(.expression(expr))

            if isPartialReference {
                let oldValue = currentFunction.getVariable(name)
                if let oldValue {
                    currentFunction.addEdge(value, oldValue)
                }
            }

            return LValue(cf: cf, newVal: value, rootIdentifier: name)

        case .indexAccessExpression(let indexExpr):
            let lvalue = processLValueExpression(cf, indexExpr.base, true)
            let (cf2, vIdx) = processExpression(lvalue.cf, indexExpr.index)
            currentFunction.addEdge(lvalue.newVal, vIdx)
            return LValue(cf: cf2, newVal: lvalue.newVal, rootIdentifier: lvalue.rootIdentifier)

        case .fieldAccessExpression(let fieldExpr):
            return processLValueExpression(cf, fieldExpr.base, true)

        case .identityExpression(let identityExpr):
            return processLValueExpression(cf, identityExpr.expression, isPartialReference)

        case .unaryExpression(let unaryExpr):
            return processLValueExpression(cf, unaryExpr.expression, isPartialReference)

        case .pointerDereferenceExpression(let derefExpr):
            return processLValueExpression(cf, derefExpr.target, isPartialReference)

        case .abstractFloatLiteral, .abstractIntegerLiteral, .binaryExpression, .boolLiteral, .callExpression, .float32Literal,
            .float16Literal, .checkedIndexAccessExpression, .signed32Literal, .unsigned32Literal, .arrayTypeExpression,
            .elaboratedTypeExpression, .referenceTypeExpression:
            return LValue(cf: cf, newVal: currentFunction.createNode(), rootIdentifier: nil)
        }
    }

    mutating func processCall(_ cf: Node, _ call: CallExpression, _ id: ExpressionID) -> (Node, Node) {
        var name: Symbol?
        if case .identifierExpression(let target) = shaderModule[call.target].kind {
            name = shaderModule.symbol(of: target.identifier)
        }

        var cfLastArg = cf
        var args: [Node] = []
        var ptrArgContents: [Node?] = []
        let argumentCount = shaderModule.count(call.arguments)
        args.reserveCapacity(argumentCount)
        ptrArgContents.reserveCapacity(argumentCount)

        var arguments = shaderModule.cursor(call.arguments)
        while let arg = shaderModule.next(&arguments) {
            let (cfI, argI) = processExpression(cfLastArg, arg)

            let argNode = currentFunction.createNode(.expression(id))
            currentFunction.addEdge(argNode, argI)

            let isPointerArg = Self.isPointer(shaderModule, arg, cppSite: "UniformityAnalysis.cpp:1285")

            if isPointerArg {
                let argContents = currentFunction.createNode(.expression(id))
                if let rootIdent = Self.rootIdentifier(shaderModule, arg) {
                    if let rootVal = currentFunction.getVariable(shaderModule.symbol(of: rootIdent.identifier)) {
                        currentFunction.addEdge(argContents, rootVal)
                    }
                }
                currentFunction.addEdge(argContents, argNode)
                ptrArgContents.append(argContents)
            } else {
                ptrArgContents.append(nil)
            }

            cfLastArg = cfI
            args.append(argNode)
        }

        let callNode = currentFunction.createNode(.expression(id))
        currentFunction.addEdge(callNode, cfLastArg)

        let result = currentFunction.createNode(.expression(id))
        let cfAfter = currentFunction.createNode(.expression(id))

        var callSiteTag = CallSiteTag.noRestriction
        var callSiteSeverity = SeverityControl.error
        var functionTag = FunctionTag.noRestriction
        var funcInfo: CalleeInfo?
        var subgroupUniformArgIndex: Int?
        var resultIsUniformRegardlessOfArgs = false

        if let name {
            if let calleeInfo = functions.find(name) {
                funcInfo = calleeInfo
                callSiteTag = calleeInfo.callSiteTag.tag
                callSiteSeverity = calleeInfo.callSiteTag.severity
                functionTag = calleeInfo.functionTag
            } else {
                if barrierFunctions.contains(name) {
                    // Barriers are a workgroup concern; they impose no requirement at subgroup scope.
                    if !analyzingSubgroupScope {
                        callSiteTag = .requiredToBeUniform
                    }
                } else if name == BuiltinSymbols.workgroupUniformLoad {
                    if !analyzingSubgroupScope {
                        callSiteTag = .requiredToBeUniform
                    }
                } else if derivativeFunctions.contains(name) {
                    // Derivatives are governed by derivative_uniformity (workgroup/draw scope only).
                    if !analyzingSubgroupScope {
                        callSiteSeverity = currentSeverity()
                        if callSiteSeverity != .off {
                            callSiteTag = .requiredToBeUniform
                        }
                    }
                    functionTag = .returnValueMayBeNonUniform
                } else if subgroupFunctions.contains(name) {
                    // Subgroup/quad ops require uniform control flow, enforced either at
                    // workgroup scope (feature off) or subgroup scope (feature on).
                    let enforcedInThisScope = analyzingSubgroupScope || !supportsSubgroupUniformity
                    if enforcedInThisScope {
                        callSiteSeverity = currentSubgroupSeverity()
                        if callSiteSeverity != .off {
                            callSiteTag = .requiredToBeUniform
                        }
                        // subgroupShuffleUp/Down require a uniform `delta`, and subgroupShuffleXor
                        // a uniform `mask` (argument index 1).
                        if name == BuiltinSymbols.subgroupShuffleUp || name == BuiltinSymbols.subgroupShuffleDown
                            || name == BuiltinSymbols.subgroupShuffleXor
                        {
                            subgroupUniformArgIndex = 1
                        }
                    }
                    // At subgroup scope, the reduction/broadcast ops produce a uniform result;
                    // everywhere else (and for shuffles/scans/quad swaps) the result may be non-uniform.
                    if analyzingSubgroupScope && subgroupUniformResultFunctions.contains(name) {
                        resultIsUniformRegardlessOfArgs = true
                    } else {
                        functionTag = .returnValueMayBeNonUniform
                    }
                } else if atomicFunctions.contains(name) {
                    functionTag = .returnValueMayBeNonUniform
                } else if name == BuiltinSymbols.textureLoad {
                    let argType = shaderModule.inferredType(of: shaderModule[call.arguments, 0])
                    if let texStorage = shaderModule.types.getIf(Types.TextureStorage.self, argType) {
                        if texStorage.access == .readWrite {
                            functionTag = .returnValueMayBeNonUniform
                        }
                    }
                }
            }
        }

        currentFunction.addEdge(cfAfter, callNode)

        if functionTag == .returnValueMayBeNonUniform {
            currentFunction.addEdge(result, currentFunction.mayBeNonUniform)
        }

        currentFunction.addEdge(result, cfAfter)

        var i = 0
        while i < args.count {
            if let funcInfo {
                let paramInfo = funcInfo.parameters[i]

                switch paramInfo.tagDirect.tag {
                case .valueRequiredToBeUniform:
                    if let node = currentFunction.requiredToBeUniformForSeverity(paramInfo.tagDirect.severity) {
                        currentFunction.addEdge(node, args[i])
                    }
                case .contentsRequiredToBeUniform:
                    if let contents = ptrArgContents[i] {
                        if let node = currentFunction.requiredToBeUniformForSeverity(paramInfo.tagDirect.severity) {
                            currentFunction.addEdge(node, contents)
                        }
                    }
                case .noRestriction:
                    break
                }

                switch paramInfo.tagRetval {
                case .valueRequiredToBeUniform:
                    currentFunction.addEdge(result, args[i])
                case .contentsRequiredToBeUniform:
                    if let contents = ptrArgContents[i] {
                        currentFunction.addEdge(result, contents)
                    }
                case .noRestriction:
                    break
                }

                let arg = shaderModule[call.arguments, i]
                let isPointerArg = Self.isPointer(shaderModule, arg, cppSite: "UniformityAnalysis.cpp:1496")
                if isPointerArg {
                    let ptrResult = currentFunction.createNode(.expression(id))
                    if paramInfo.pointerMayBecomeNonUniform {
                        currentFunction.addEdge(ptrResult, currentFunction.mayBeNonUniform)
                    } else {
                        currentFunction.addEdge(ptrResult, callNode)
                        var k = 0
                        while k < paramInfo.ptrOutputSourceParamValues.count {
                            currentFunction.addEdge(ptrResult, args[paramInfo.ptrOutputSourceParamValues[k]])
                            k += 1
                        }
                        k = 0
                        while k < paramInfo.ptrOutputSourceParamContents.count {
                            if let contents = ptrArgContents[paramInfo.ptrOutputSourceParamContents[k]] {
                                currentFunction.addEdge(ptrResult, contents)
                            }
                            k += 1
                        }
                    }

                    if let rootIdent = Self.rootIdentifier(shaderModule, arg) {
                        currentFunction.setVariable(shaderModule.symbol(of: rootIdent.identifier), ptrResult)
                    }
                }
            } else {
                if let name, name == BuiltinSymbols.workgroupUniformLoad, !analyzingSubgroupScope {
                    // workgroupUniformLoad requires the pointer VALUE to be
                    // uniform (same memory location across invocations), but
                    // NOT the contents. For pointer parameters, args[i] reaches
                    // ptrInputContents (contents tracking), which would cause
                    // getParamTag to incorrectly tag as ContentsRequiredToBeUniform.
                    // Use paramInfo.value instead to get ValueRequiredToBeUniform.
                    // This is a workgroup concern, so it does not apply at subgroup scope.
                    var ptrValueNode = args[i]
                    if let rootId = Self.rootIdentifier(shaderModule, shaderModule[call.arguments, i]) {
                        let rootName = shaderModule.symbol(of: rootId.identifier)
                        var k = 0
                        while k < currentFunction.parameters.count {
                            if currentFunction.parameters[k].name == rootName && currentFunction.parameters[k].ptrInputContents != nil {
                                ptrValueNode = currentFunction.parameters[k].value
                                break
                            }
                            k += 1
                        }
                    }
                    if let node = currentFunction.requiredToBeUniformForSeverity(callSiteSeverity) {
                        currentFunction.addEdge(node, ptrValueNode)
                    }
                } else {
                    // A subgroup reduction/broadcast at subgroup scope yields a uniform
                    // result regardless of whether its inputs are uniform, so its result
                    // must not inherit argument non-uniformity.
                    if !resultIsUniformRegardlessOfArgs {
                        currentFunction.addEdge(result, args[i])
                    }
                    // subgroupShuffleUp/Down `delta` and subgroupShuffleXor `mask` must be uniform.
                    if let subgroupUniformArgIndex, subgroupUniformArgIndex == i {
                        if let node = currentFunction.requiredToBeUniformForSeverity(callSiteSeverity) {
                            currentFunction.addEdge(node, args[i])
                        }
                    }
                }
            }
            i += 1
        }

        if callSiteTag == .requiredToBeUniform {
            if let node = currentFunction.requiredToBeUniformForSeverity(callSiteSeverity) {
                currentFunction.addEdge(node, callNode)
            }
        }

        return (cfAfter, result)
    }

    private static func isPointer(_ shaderModule: borrowing ShaderModule, _ arg: ExpressionID, cppSite: StaticString) -> Bool {
        guard let type = shaderModule.inferredType(of: arg) else {
            wgslFatal("a call argument without an inferred type", cppSite: cppSite)
        }
        return shaderModule.types.getIf(Types.Pointer.self, type) != nil
    }
}

@_spi(Testing)
public func uniformityAnalysis(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    // Only functions are analyzed (UniformityGraph.run).
    guard UniformityGraph.hasFunction(shaderModule) else {
        return nil
    }
    var graph = UniformityGraph(shaderModule: shaderModule)
    let result = graph.run()
    shaderModule = graph.shaderModule
    return result
}

private let barrierFunctions: [BuiltinSymbols] = [
    .storageBarrier,
    .textureBarrier,
    .workgroupBarrier,
]

private let derivativeFunctions: [BuiltinSymbols] = [
    .dpdx,
    .dpdxCoarse,
    .dpdxFine,
    .dpdy,
    .dpdyCoarse,
    .dpdyFine,
    .fwidth,
    .fwidthCoarse,
    .fwidthFine,
    .textureSample,
    .textureSampleBias,
    .textureSampleCompare,
]

private let atomicFunctions: [BuiltinSymbols] = [
    .atomicAdd,
    .atomicAnd,
    .atomicCompareExchangeWeak,
    .atomicExchange,
    .atomicLoad,
    .atomicMax,
    .atomicMin,
    .atomicOr,
    .atomicStore,
    .atomicSub,
    .atomicXor,
]

// Subgroup and quad built-in functions communicate across invocations,
// so (absent the subgroup_uniformity language feature, which we do not
// support) they require uniform control flow at their call site and may
// return a non-uniform value. This is governed by the subgroup_uniformity
// triggering rule rather than derivative_uniformity.
private let subgroupFunctions: [BuiltinSymbols] = [
    .quadBroadcast,
    .quadSwapDiagonal,
    .quadSwapX,
    .quadSwapY,
    .subgroupAdd,
    .subgroupAll,
    .subgroupAnd,
    .subgroupAny,
    .subgroupBallot,
    .subgroupBroadcast,
    .subgroupBroadcastFirst,
    .subgroupElect,
    .subgroupExclusiveAdd,
    .subgroupExclusiveMul,
    .subgroupInclusiveAdd,
    .subgroupInclusiveMul,
    .subgroupMax,
    .subgroupMin,
    .subgroupMul,
    .subgroupOr,
    .subgroupShuffle,
    .subgroupShuffleDown,
    .subgroupShuffleUp,
    .subgroupShuffleXor,
    .subgroupXor,
]

// Functions whose result is subgroup-uniform when evaluated in uniform
// control flow at subgroup scope (https://www.w3.org/TR/WGSL/#uniformity).
// The remaining subgroup/quad ops (shuffles, scans, quad swaps) may still
// produce a non-uniform result even at subgroup scope.
private let subgroupUniformResultFunctions: [BuiltinSymbols] = [
    .subgroupAdd,
    .subgroupAll,
    .subgroupAnd,
    .subgroupAny,
    .subgroupBallot,
    .subgroupBroadcast,
    .subgroupBroadcastFirst,
    .subgroupMax,
    .subgroupMin,
    .subgroupMul,
    .subgroupOr,
    .subgroupXor,
]

extension [BuiltinSymbols] {
    fileprivate func contains(_ name: Symbol) -> Bool {
        var index = 0
        while index < count {
            if name == self[index] {
                return true
            }
            index += 1
        }
        return false
    }
}
