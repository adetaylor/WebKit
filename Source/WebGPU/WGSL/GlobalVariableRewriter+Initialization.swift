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

extension RewriteGlobalVariables {
    /// Declares `usedPrivateGlobals` at the top of the entry point's body and zeroes its workgroup variables.
    mutating func insertLocalDefinitions(_ function: FunctionID, _ usedPrivateGlobals: UsedPrivateGlobals) -> EntryPointInitialized {
        let plan = PrivateGlobalPlan(shaderModule, usedPrivateGlobals)
        let statements = shaderModule.downcast(CompoundStatement.self, shaderModule[function].body).statements
        let initialBodySize = shaderModule.count(statements)
        // The C++ inserts each declaration at the front of the body; they go in at once, last first: the same list.
        var variableStatements: [StatementID] = []
        variableStatements.reserveCapacity(plan.globals.count)
        var index = 0
        while index < plan.globals.count {
            let global = plan.globals[index]
            index &+= 1
            let variableStatement = shaderModule.construct(span: .empty, VariableStatement(variable: global.declaration))
            variableStatements.append(variableStatement)
        }
        variableStatements.reverse()
        shaderModule.insertVector(statements, 0, variableStatements)

        let offset = shaderModule.count(statements) &- initialBodySize
        return initializeVariables(function, plan, offset)
    }

    mutating func initializeVariables(
        _ function: FunctionID,
        _ globals: consuming PrivateGlobalPlan,
        _ offset: Int
    ) -> EntryPointInitialized {
        let initializations = storeInitialValue(globals)
        if initializations.isEmpty {
            assert(globals.workgroupGlobals.isEmpty)
            return EntryPointInitialized(function: function)
        }

        let barrier = insertWorkgroupBarrier(function, offset)

        let localInvocationIndex = findOrInsertLocalInvocationIndex(function)

        let testLhs = shaderModule.constructIdentifierExpression(
            span: .empty,
            identifier: shaderModule.makeIdentifier(shaderModule.symbol(of: localInvocationIndex))
        )
        shaderModule.setInferredType(shaderModule.types.u32Type, for: testLhs)

        let testRhs = shaderModule.construct(span: .empty, Unsigned32Literal(value: 0))
        // As in the C++, testLhs is typed again and testRhs stays untyped.
        shaderModule.setInferredType(shaderModule.types.u32Type, for: testLhs)

        let testExpression = shaderModule.construct(
            span: .empty,
            BinaryExpression(leftExpression: testLhs, rightExpression: testRhs, operation: .equal)
        )
        shaderModule.setInferredType(shaderModule.types.boolType, for: testExpression)

        let bodyAttributes = shaderModule.makeEmptyList(AttributeID.self)
        let bodyStatements = shaderModule.makeList(initializations)
        let body = shaderModule.construct(span: .empty, CompoundStatement(attributes: bodyAttributes, statements: bodyStatements))

        let ifAttributes = shaderModule.makeEmptyList(AttributeID.self)
        let ifStatement = shaderModule.construct(
            span: .empty,
            IfStatement(test: testExpression, trueBody: body, maybeFalseBody: nil, attributes: ifAttributes)
        )
        let statements = shaderModule.downcast(CompoundStatement.self, shaderModule[barrier.function].body).statements
        shaderModule.insert(statements, barrier.offset, ifStatement)
        return EntryPointInitialized(function: barrier.function)
    }

    mutating func insertWorkgroupBarrier(_ function: FunctionID, _ offset: Int) -> WorkgroupBarrierInserted {
        let callee = shaderModule.constructIdentifierExpression(
            span: .empty,
            identifier: shaderModule.makeIdentifier(Symbol(.workgroupBarrier))
        )
        shaderModule.setInferredType(shaderModule.types.voidType, for: callee)

        let arguments = shaderModule.makeEmptyList(ExpressionID.self)
        let call = shaderModule.construct(span: .empty, CallExpression(target: callee, arguments: arguments))
        shaderModule.setInferredType(shaderModule.types.voidType, for: call)

        let callStatement = shaderModule.constructCallStatement(span: .empty, call: call)
        let statements = shaderModule.downcast(CompoundStatement.self, shaderModule[function].body).statements
        shaderModule.insert(statements, offset, callStatement)
        return WorkgroupBarrierInserted(function: function, offset: offset)
    }

    /// The name of the entry point's `@builtin(local_invocation_index)` parameter (C++ `AST::Identifier&`).
    mutating func findOrInsertLocalInvocationIndex(_ function: FunctionID) -> IdentifierID {
        var parameters = shaderModule.cursor(shaderModule[function].parameters)
        while let parameter = shaderModule.next(&parameters) {
            if let builtin = shaderModule[parameter].builtin, builtin == .localInvocationIndex {
                return shaderModule[parameter].name
            }
        }

        let type = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(Symbol(.u32)))
        shaderModule.setInferredType(shaderModule.types.u32Type, for: type)

        let builtinAttribute = shaderModule.construct(span: .empty, .builtinAttribute(BuiltinAttribute(builtin: .localInvocationIndex)))

        let attributes = shaderModule.makeList([builtinAttribute])
        let parameter = shaderModule.constructParameter(
            span: .empty,
            name: shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.localInvocationIndex))),
            typeName: type,
            attributes: attributes,
            role: .userDefined
        )

        shaderModule.append(shaderModule[function].parameters, parameter)

        return shaderModule[parameter].name
    }

    /// The plan's workgroup globals are the globals the C++ loop does not skip.
    mutating func storeInitialValue(_ globals: borrowing PrivateGlobalPlan) -> [StatementID] {
        var statements: [StatementID] = []
        var index = 0
        while index < globals.workgroupGlobals.count {
            let variable = shaderModule[globals.workgroupGlobals[index].declaration]
            index &+= 1

            let type = variable.storeType
            let target = shaderModule.constructIdentifierExpression(
                span: .empty,
                identifier: shaderModule.makeIdentifier(shaderModule.symbol(of: variable.name))
            )
            shaderModule.setInferredType(type, for: target)
            storeInitialValue(target, &statements, 0)
        }
        return statements
    }

    /// The loop over an array indexes it with a CheckedIndexAccessExpression whose proof is BoundsMint.loopInduction of the
    /// loop's ZeroInitLoopPlan; the loop's index variable and bound come from the same plan.
    // DEV-03: C++ recurses once per level of nested arrays and of structures that are not constructible, which named types make as
    // deep as the declarations; the pending loops and member walks are kept in `frames`, and the nodes are made in the C++ order.
    mutating func storeInitialValue(_ target: ExpressionID, _ statements: inout [StatementID], _ arrayDepth: UInt32) {
        func zeroInitialize(_ target: ExpressionID) {
            shaderModule.uses.insert(.zeroWorkgroupVar)

            let callee = shaderModule.constructIdentifierExpression(
                span: .empty,
                identifier: shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.wgslZeroWorkgroupVar)))
            )
            shaderModule.setInferredType(shaderModule.types.voidType, for: callee)

            let arguments = shaderModule.makeList([target])
            let call = shaderModule.construct(span: .empty, CallExpression(target: callee, arguments: arguments))
            shaderModule.setInferredType(shaderModule.types.voidType, for: call)

            let callStatement = shaderModule.constructCallStatement(span: .empty, call: call)
            statements.append(callStatement)
        }

        var frames: [StoreInitialValueFrame] = []
        var step = StoreInitialValueStep.store(target, arrayDepth: arrayDepth)
        while true {
            switch step {
            case .store(let target, let arrayDepth):
                let type = shaderModule.inferredType(of: target)
                if let arrayType = shaderModule.types.getIf(Types.Array.self, type) {
                    let plan = ZeroInitLoopPlan(arrayType, depth: arrayDepth)
                    let indexVariableName = shaderModule.symbols.intern(.loopIndex(depth: plan.depth))

                    let indexVariable = shaderModule.constructIdentifierExpression(
                        span: .empty,
                        identifier: shaderModule.makeIdentifier(indexVariableName)
                    )
                    shaderModule.setInferredType(shaderModule.types.u32Type, for: indexVariable)

                    let arrayAccess = shaderModule.construct(
                        span: .empty,
                        CheckedIndexAccessExpression(base: target, index: indexVariable, proof: BoundsMint.loopInduction(plan))
                    )
                    shaderModule.setInferredType(arrayType.element, for: arrayAccess)

                    frames.append(
                        .arrayLoop(
                            indexVariable: indexVariable,
                            indexVariableName: indexVariableName,
                            count: plan.count,
                            statements: statements
                        )
                    )
                    statements = []
                    step = .store(arrayAccess, arrayDepth: arrayDepth &+ 1)
                    continue
                }

                if let type, let structType = shaderModule.types.getIf(Types.Struct.self, type) {
                    if shaderModule.isConstructible(type) {
                        zeroInitialize(target)
                        step = .resume
                        continue
                    }

                    let members = shaderModule.cursor(shaderModule[structType.structure].members)
                    frames.append(.structMembers(target: target, members: members, arrayDepth: arrayDepth))
                    step = .resume
                    continue
                }

                if let type, shaderModule.types.getIf(Types.Atomic.self, type) != nil {
                    let callee = shaderModule.constructIdentifierExpression(
                        span: .empty,
                        identifier: shaderModule.makeIdentifier(Symbol(.atomicStore))
                    )
                    shaderModule.setInferredType(shaderModule.types.voidType, for: callee)

                    let pointer = shaderModule.construct(span: .empty, UnaryExpression(expression: target, operation: .addressOf))
                    shaderModule.setInferredType(shaderModule.types.voidType, for: pointer)

                    let value = shaderModule.construct(span: .empty, AbstractIntegerLiteral(value: 0))
                    shaderModule.setInferredType(shaderModule.types.abstractIntType, for: value)

                    let arguments = shaderModule.makeList([pointer, value])
                    let call = shaderModule.construct(span: .empty, CallExpression(target: callee, arguments: arguments))
                    shaderModule.setInferredType(shaderModule.types.voidType, for: call)

                    let callStatement = shaderModule.constructCallStatement(span: .empty, call: call)
                    statements.append(callStatement)
                    step = .resume
                    continue
                }

                zeroInitialize(target)
                step = .resume
            case .resume:
                guard let frame = frames.popLast() else {
                    return
                }
                switch frame {
                case .arrayLoop(let indexVariable, let indexVariableName, let count, let outerStatements):
                    let forBodyStatements = statements
                    statements = outerStatements

                    let zero = shaderModule.construct(span: .empty, Unsigned32Literal(value: 0))
                    shaderModule.setInferredType(shaderModule.types.u32Type, for: zero)

                    let forVariableAttributes = shaderModule.makeEmptyList(AttributeID.self)
                    let forVariable = shaderModule.constructVariable(
                        span: .empty,
                        flavor: .var,
                        name: shaderModule.makeIdentifier(indexVariableName),
                        type: nil,
                        initializer: zero,
                        attributes: forVariableAttributes
                    )

                    let forInitializer = shaderModule.construct(span: .empty, VariableStatement(variable: forVariable))

                    let arrayLength: ExpressionID
                    switch count {
                    case .overrideExpression(let overrideExpression):
                        arrayLength = overrideExpression
                    case .constant(let constant):
                        arrayLength = shaderModule.construct(span: .empty, Unsigned32Literal(value: constant))
                        shaderModule.setInferredType(shaderModule.types.u32Type, for: arrayLength)
                    }

                    let forTest = shaderModule.construct(
                        span: .empty,
                        BinaryExpression(leftExpression: indexVariable, rightExpression: arrayLength, operation: .lessThan)
                    )
                    shaderModule.setInferredType(shaderModule.types.boolType, for: forTest)

                    let one = shaderModule.construct(span: .empty, Unsigned32Literal(value: 1))
                    shaderModule.setInferredType(shaderModule.types.u32Type, for: one)

                    let forUpdate = shaderModule.construct(
                        span: .empty,
                        CompoundAssignmentStatement(leftExpression: indexVariable, rightExpression: one, operation: .add)
                    )

                    let forBodyAttributes = shaderModule.makeEmptyList(AttributeID.self)
                    let forBodyList = shaderModule.makeList(forBodyStatements)
                    let forBody = shaderModule.construct(
                        span: .empty,
                        CompoundStatement(attributes: forBodyAttributes, statements: forBodyList)
                    )

                    let forAttributes = shaderModule.makeEmptyList(AttributeID.self)
                    var forStatementPayload = ForStatement(
                        attributes: forAttributes,
                        maybeInitializer: forInitializer,
                        maybeTest: forTest,
                        maybeUpdate: forUpdate,
                        body: forBody
                    )
                    forStatementPayload.setInternallyGenerated()
                    let forStatement = shaderModule.construct(span: .empty, forStatementPayload)

                    statements.append(forStatement)
                case .structMembers(let target, var members, let arrayDepth):
                    if let member = shaderModule.next(&members) {
                        frames.append(.structMembers(target: target, members: members, arrayDepth: arrayDepth))
                        let fieldType = shaderModule.inferredType(of: shaderModule[member].type)
                        let fieldAccess = shaderModule.constructFieldAccessExpression(
                            span: .empty,
                            base: target,
                            fieldName: shaderModule.makeIdentifier(shaderModule.symbol(of: shaderModule[member].name))
                        )
                        shaderModule.setInferredType(fieldType, for: fieldAccess)
                        step = .store(fieldAccess, arrayDepth: arrayDepth)
                    }
                }
            }
        }
    }
}

extension RewriteGlobalVariables {
    /// What storeInitialValue does next: store into a target, or resume the innermost pending call.
    enum StoreInitialValueStep {
        case store(ExpressionID, arrayDepth: UInt32)
        case resume
    }

    /// A pending storeInitialValue call: the loop over an array, which wraps the statements stored for its element and is
    /// appended to the enclosing `statements`, or the walk over a structure's members.
    enum StoreInitialValueFrame {
        case arrayLoop(indexVariable: ExpressionID, indexVariableName: Symbol, count: ZeroInitLoopPlan.Count, statements: [StatementID])
        case structMembers(target: ExpressionID, members: ListCursor<StructureMemberID>, arrayDepth: UInt32)
    }
}

// MARK: - Zero-initialization proofs

extension RewriteGlobalVariables {
    /// The proof for visitEntryPoint's return for an entry point that reads no global (GlobalVariableRewriter.cpp:1198): it uses no
    /// workgroup variable, so there is nothing to zero.
    mutating func entryPointReadsNoGlobals(_ function: FunctionID) -> EntryPointInitialized {
        guard reads.isEmpty else {
            wgslFatal("an entry point that reads globals skipped their initialization", cppSite: "GlobalVariableRewriter.cpp:1198")
        }
        return EntryPointInitialized(function: function)
    }
}

/// An entry point's used private globals (C++ `UsedPrivateGlobals`), split once by address space, so that the variables
/// insertLocalDefinitions declares and the variables initializeVariables zeroes come from one list.
///
/// Only this file makes one.
struct PrivateGlobalPlan: ~Copyable {
    /// Every used private global, in `reads` order; each is declared in the entry point.
    let globals: RewriteGlobalVariables.UsedPrivateGlobals

    /// The workgroup variables among `globals`, in the same order; each is zeroed by invocation 0 before the body.
    let workgroupGlobals: RewriteGlobalVariables.UsedPrivateGlobals

    fileprivate init(_ shaderModule: borrowing ShaderModule, _ globals: RewriteGlobalVariables.UsedPrivateGlobals) {
        var workgroupGlobals: RewriteGlobalVariables.UsedPrivateGlobals = []
        var index = 0
        while index < globals.count {
            let global = globals[index]
            switch shaderModule[global.declaration].addressSpace {
            case .workgroup:
                workgroupGlobals.append(global)
            case .function, .private, nil:
                break
            case .handle, .storage, .uniform:
                wgslFatal("a resource variable among the used private globals", cppSite: "GlobalVariableRewriter.cpp:1504")
            }
            index &+= 1
        }
        self.globals = globals
        self.workgroupGlobals = workgroupGlobals
    }
}

/// The bound of an internally generated zero-initialization loop over a fixed-size array (GlobalVariableRewriter.cpp:2683-2770):
/// `__i<depth>` runs from 0 while it is less than `count`, so the loop's subscript is in bounds.
///
/// Only this file makes one; BoundsMint.loopInduction requires one.
struct ZeroInitLoopPlan: ~Copyable {
    enum Count {
        case constant(UInt32)
        case overrideExpression(ExpressionID)
    }

    let count: Count

    let depth: UInt32

    fileprivate init(_ arrayType: Types.Array, depth: UInt32) {
        switch arrayType.size {
        case .runtime:
            wgslFatal("a zero-initialization loop over a runtime-sized array", cppSite: "GlobalVariableRewriter.cpp:2684")
        case .creationFixed(let count):
            self.count = .constant(count)
        case .overrideSized(let count):
            self.count = .overrideExpression(count)
        }
        self.depth = depth
    }
}

/// Proof that insertWorkgroupBarrier put the `workgroupBarrier()` call at `offset` in the entry point's body; initializeVariables
/// inserts the zeroing block at the same offset, so the block precedes the barrier.
///
/// Only insertWorkgroupBarrier makes one.
struct WorkgroupBarrierInserted: ~Copyable {
    let function: FunctionID

    let offset: Int

    fileprivate init(function: FunctionID, offset: Int) {
        self.function = function
        self.offset = offset
    }
}

/// Proof that every workgroup variable the entry point uses is zeroed by invocation 0, followed by a `workgroupBarrier()`, before
/// the entry point's body.
///
/// Only this file makes one: initializeVariables, or entryPointReadsNoGlobals for an entry point that uses no global. The prepare
/// driver keeps one per prepared entry point, and the writer's entry-point emitter requires it.
@_spi(Testing)
public struct EntryPointInitialized: Hashable, Sendable {
    /// The entry point's function.
    @_spi(Testing)
    public let function: FunctionID

    fileprivate init(function: FunctionID) {
        self.function = function
    }
}
