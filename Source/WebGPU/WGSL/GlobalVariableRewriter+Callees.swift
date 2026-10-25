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

extension RewriteGlobalVariables {
    /// C++ `visitCallee`, split at its `visit(*callee.target)`, which the walk in `visit(_: FunctionID)` performs: the
    /// `.beforeVisitingTarget` step returns whether the target must be visited, and the `.afterVisitingTarget` step runs
    /// once it has been.
    @discardableResult
    mutating func visitCallee(_ callee: CallGraph.Callee, _ step: CalleeVisitStep) -> Bool {
        func updateCallee() {
            var readIterator = reads.makeIterator()
            while let read = readIterator.next() {
                guard let global = globals.find(read) else {
                    wgslFatal("a read that is not a global", cppSite: "GlobalVariableRewriter.cpp:204")
                }
                let declaration = shaderModule[global.declaration]
                var type: ExpressionID?
                if declaration.flavor == .var {
                    type = declaration.maybeReferenceType
                } else {
                    assert(declaration.flavor == .override)
                    type = declaration.maybeTypeName
                    if type == nil {
                        guard let storeType = declaration.storeType else {
                            wgslFatal("an override without a store type", cppSite: "GlobalVariableRewriter.cpp:213")
                        }
                        let typeString = ShaderModule.typeString(storeType, in: &shaderModule)
                        let typeName = shaderModule.symbols.intern(typeString.codeUnits)
                        let typeExpression = shaderModule.constructIdentifierExpression(
                            span: .empty,
                            identifier: shaderModule.makeIdentifier(typeName)
                        )
                        shaderModule.setInferredType(storeType, for: typeExpression)
                        type = typeExpression
                    }
                }
                assert(type != nil)
                guard let type else {
                    wgslFatal("a global parameter without a type", cppSite: "GlobalVariableRewriter.cpp:225")
                }

                let parameterRole: ParameterRole = declaration.role == .packedResource ? .packedResource : .userDefined
                let parameter = shaderModule.constructParameter(
                    span: .empty,
                    name: shaderModule.makeIdentifier(read),
                    typeName: type,
                    attributes: shaderModule.makeEmptyList(AttributeID.self),
                    role: parameterRole
                )
                shaderModule.append(shaderModule[callee.target].parameters, parameter)
            }

            if let calleeLengthParameters = lengthParameters.find(callee.target), !calleeLengthParameters.isEmpty {
                let lengthType = shaderModule.constructIdentifierExpression(
                    span: .empty,
                    identifier: shaderModule.makeIdentifier(Symbol(.u32))
                )
                shaderModule.setInferredType(shaderModule.types.u32Type, for: lengthType)

                var lengthIterator = calleeLengthParameters.makeIterator()
                while let length = lengthIterator.next() {
                    let lengthName = shaderModule.symbols.intern(.arrayLength(of: length))
                    if reads.contains(lengthName) {
                        continue
                    }
                    let parameter = shaderModule.constructParameter(
                        span: .empty,
                        name: shaderModule.makeIdentifier(lengthName),
                        typeName: lengthType,
                        attributes: shaderModule.makeEmptyList(AttributeID.self),
                        role: .userDefined
                    )
                    shaderModule.append(shaderModule[callee.target].parameters, parameter)
                }
            }
        }

        func updateCallSites() {
            var readIterator = reads.makeIterator()
            while let read = readIterator.next() {
                var callSiteIndex = 0
                while callSiteIndex < callee.callSites.count {
                    let call = callee.callSites[callSiteIndex].call
                    guard let global = globals.find(read) else {
                        wgslFatal("a read that is not a global", cppSite: "GlobalVariableRewriter.cpp:256")
                    }
                    let globalExpression = shaderModule.constructIdentifierExpression(
                        span: .empty,
                        identifier: shaderModule.makeIdentifier(read)
                    )
                    shaderModule.setInferredType(shaderModule[global.declaration].storeType, for: globalExpression)
                    shaderModule.append(shaderModule.downcast(CallExpression.self, call).arguments, globalExpression)
                    doNotUnpack.add(globalExpression)
                    callSiteIndex &+= 1
                }
            }

            if let calleeLengthParameters = lengthParameters.find(callee.target), !calleeLengthParameters.isEmpty {
                let lengthType = shaderModule.constructIdentifierExpression(
                    span: .empty,
                    identifier: shaderModule.makeIdentifier(Symbol(.u32))
                )
                shaderModule.setInferredType(shaderModule.types.u32Type, for: lengthType)

                var pendingLengthParameters: [(caller: FunctionID, lengthParameter: Symbol)] = []
                var lengthIterator = calleeLengthParameters.makeIterator()
                while let lengthParameter = lengthIterator.next() {
                    let lengthName = shaderModule.symbols.intern(.arrayLength(of: lengthParameter))
                    if reads.contains(lengthName) {
                        continue
                    }

                    var index = 0
                    var parameters = shaderModule.cursor(shaderModule[callee.target].parameters)
                    while let parameter = shaderModule.next(&parameters) {
                        if shaderModule[shaderModule[parameter].name].symbol == lengthParameter {
                            break
                        }
                        index &+= 1
                    }
                    var callSiteIndex = 0
                    while callSiteIndex < callee.callSites.count {
                        let (caller, call) = callee.callSites[callSiteIndex]
                        let argument = shaderModule[shaderModule.downcast(CallExpression.self, call).arguments, index]
                        var arrayOffset: UInt32 = 0
                        let base = getBase(argument, &arrayOffset)
                        let identifier = shaderModule[base.identifier].symbol

                        pendingLengthParameters.append((caller, identifier))

                        let lengthName = shaderModule.symbols.intern(.arrayLength(of: identifier))
                        let length = shaderModule.constructIdentifierExpression(
                            span: .empty,
                            identifier: shaderModule.makeIdentifier(lengthName)
                        )
                        shaderModule.setInferredType(shaderModule.types.u32Type, for: length)
                        var lhs = length
                        if arrayOffset != 0 {
                            let arrayOffsetExpression = shaderModule.construct(span: .empty, Unsigned32Literal(value: arrayOffset))
                            shaderModule.setInferredType(shaderModule.types.u32Type, for: arrayOffsetExpression)
                            lhs = shaderModule.construct(
                                span: .empty,
                                BinaryExpression(leftExpression: length, rightExpression: arrayOffsetExpression, operation: .subtract)
                            )
                            shaderModule.setInferredType(shaderModule.types.u32Type, for: lhs)
                        }
                        shaderModule.append(shaderModule.downcast(CallExpression.self, call).arguments, lhs)
                        callSiteIndex &+= 1
                    }
                }

                var pendingIndex = 0
                while pendingIndex < pendingLengthParameters.count {
                    let (caller, lengthParameter) = pendingLengthParameters[pendingIndex]
                    lengthParameters.modify(caller, default: OrderedSet()) { _ = $0.add(lengthParameter) }
                    pendingIndex &+= 1
                }
            }
        }

        switch step {
        case .beforeVisitingTarget:
            if let visitedReads = visitedFunctions.find(callee.target) {
                reads = visitedReads
                updateCallSites()
                return false
            }
            return true
        case .afterVisitingTarget:
            updateCallee()
            updateCallSites()

            visitedFunctions.add(callee.target, reads)
            return false
        }
    }

    // DEV-03: the C++ recursion between visitCallee and visit(Function) overflows the stack on deep call chains; the Swift walk is
    // iterative (CallGraph.walk). The C++ actions per event: `.enter` is the top of visit(Function), `.edge` and
    // `.edgeDone` are the callee loop body before and after `visit(*callee.target)` (an already-visited target is skipped), a
    // `hasError()` return finishes the current function early, and `.exit` is the rest of visit(Function) after the loop.
    mutating func visit(_ function: FunctionID) {
        var functionReads: [OrderedSet<Symbol>] = []
        var skippedCallee = false
        var calleeWalk = shaderModule.callGraph.walk(from: function)
        while let event = calleeWalk.next(shaderModule.callGraph) {
            switch event {
            case .enter:
                functionReads.append(OrderedSet())
            case .edge(let caller, let calleeIndex):
                let callee = shaderModule.callGraph.callees(caller)[calleeIndex]
                if visitCallee(callee, .beforeVisitingTarget) {
                    calleeWalk.descend()
                } else {
                    skippedCallee = true
                    calleeWalk.skip()
                }
            case .edgeDone(let caller, let calleeIndex):
                if skippedCallee {
                    skippedCallee = false
                } else {
                    visitCallee(shaderModule.callGraph.callees(caller)[calleeIndex], .afterVisitingTarget)
                }

                if hasError {
                    calleeWalk.finishCurrent()
                    break
                }

                let current = functionReads.count &- 1
                var readIterator = reads.makeIterator()
                while let read = readIterator.next() {
                    functionReads[current].add(read)
                }
            case .exit(let exited, let finishedEarly):
                let reads = functionReads.removeLast()
                if finishedEarly {
                    break
                }
                self.reads = reads
                defs.clear()
                combinedFunctionVariablesSize = CheckedUInt32(0)

                def(shaderModule[exited].name, nil)
                currentFunction = exited
                visitChildren(exited)
                currentFunction = nil

                // https://www.w3.org/TR/WGSL/#limits
                let maximumCombinedFunctionVariablesSize: UInt32 = 8192
                if combinedFunctionVariablesSize.hasOverflowed || combinedFunctionVariablesSize.value > maximumCombinedFunctionVariablesSize
                {
                    setError(
                        CompilationMessage(
                            text:
                                "The combined byte size of all variables in this function exceeds \(maximumCombinedFunctionVariablesSize) bytes",
                            span: shaderModule[exited].span
                        )
                    )
                }
            }
        }
    }

    mutating func visit(_ parameter: ParameterID) {
        def(shaderModule[parameter].name, nil)
        visitChildren(parameter)
        recordTypeReads(shaderModule.inferredType(of: shaderModule[parameter].typeName))
    }

    mutating func visit(_ variable: VariableID) {
        def(shaderModule[variable].name, variable)
        visitChildren(variable)
        recordTypeReads(shaderModule[variable].storeType)
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        let savedCurrentStatementIndex = currentStatementIndex
        currentStatementIndex = 0
        defer { currentStatementIndex = savedCurrentStatementIndex }
        let savedPendingInsertions = pendingInsertions
        pendingInsertions = []
        defer { pendingInsertions = savedPendingInsertions }

        var statements = shaderModule.cursor(statement.statements)
        while let statement = shaderModule.next(&statements) {
            dispatch(statement)
            currentStatementIndex &+= 1
        }

        var offset = 0
        var index = 0
        while index < pendingInsertions.count {
            let insertion = pendingInsertions[index]
            shaderModule.insert(statement.statements, insertion.index &+ offset, insertion.statement)
            offset &+= 1
            index &+= 1
        }
    }

    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        let lhsPacking = pack(.unpacked, statement.leftExpression)
        pack(lhsPacking, statement.rightExpression)
    }

    mutating func visit(_ statement: AssignmentStatement, _ id: StatementID) {
        var lhsPacking = pack(.either, statement.lhs)
        assert(lhsPacking != .either)
        if lhsPacking == .packedVec3 {
            var lhsType = shaderModule.inferredType(of: statement.lhs)
            if let reference = shaderModule.types.getIf(Types.Reference.self, lhsType) {
                lhsType = reference.element
            }
            guard let lhsType else {
                wgslFatal("an assignment whose left-hand side has no type", cppSite: "GlobalVariableRewriter.cpp:417")
            }
            if shaderModule.types.getIf(Types.Vector.self, lhsType) != nil {
                lhsPacking = .either
            }
        }
        pack(lhsPacking, statement.rhs)
    }

    mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        let variable = shaderModule[statement.variable]
        if variable.flavor == .var {
            guard let storeType = variable.storeType else {
                wgslFatal("a variable without a store type", cppSite: "GlobalVariableRewriter.cpp:426")
            }
            let size = ShaderModule.size(of: storeType, in: &shaderModule)
            combinedFunctionVariablesSize += size // lint-exempt(L-WRAP-1): CheckedUInt32 records the overflow
        }
        if let initializer = variable.maybeInitializer {
            pack(.unpacked, initializer)
        }
    }

    mutating func visit(_ statement: PhonyAssignmentStatement, _ id: StatementID) {
        pack(.either, statement.rhs)
    }

    mutating func visit(_ expression: ExpressionID) {
        pack(.unpacked, expression)
    }

    /// The validation runs only if none of the enclosing short-circuit operators skips its right-hand side
    /// (`skipsRightHandSide`, GlobalVariableRewriter.cpp:441, is ShaderModule.skipsRightHandSide in Evaluate.swift).
    mutating func addOverrideValidation(_ check: OverrideValidation.Check) {
        if shortCircuitedOperators.isEmpty {
            shaderModule.addOverrideValidation(OverrideValidation(guards: [], check: check))
            return
        }

        shaderModule.addOverrideValidation(OverrideValidation(guards: shortCircuitedOperators, check: check))
    }
}

extension RewriteGlobalVariables {
    /// Where `visitCallee` is in the C++ function, relative to its `visit(*callee.target)`.
    enum CalleeVisitStep {
        case beforeVisitingTarget
        case afterVisitingTarget
    }
}
