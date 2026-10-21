// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (C) 2024-2026 Apple Inc. All rights reserved.
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

private struct BoundsCheckVisitor: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func run() -> FailedCheck? {
        visitShaderModule()
        return nil
    }

    mutating func visit(_ variable: VariableID) {
        if shaderModule[variable].flavor == .override {
            return
        }
        visitChildren(variable)
    }

    mutating func visit(_ access: IndexAccessExpression, _ id: ExpressionID) {
        if shaderModule.constantValueForBoundsCheckSkip(id) != nil {
            // The writer prints the constant (MetalFunctionWriter.cpp:1892, :1921), never this subscript.
            shaderModule.markChecked(id, access, BoundsMint.constantValue())
            return
        }

        visitChildren(access, id)

        var base = shaderModule.inferredType(of: access.base)
        if let reference = shaderModule.types.getIf(Types.Reference.self, base) {
            base = reference.element
        }
        if let pointer = shaderModule.types.getIf(Types.Pointer.self, base) {
            base = pointer.element
        }

        if let vector = shaderModule.types.getIf(Types.Vector.self, base) {
            checkBounds(id, access.index, UInt32(vector.size))
            shaderModule.replaceWithClampedAccess(id, shaderModule.makeBoundsCheckConstant(UInt32(vector.size)))
            return
        }

        if let matrix = shaderModule.types.getIf(Types.Matrix.self, base) {
            checkBounds(id, access.index, UInt32(matrix.columns))
            shaderModule.replaceWithClampedAccess(id, shaderModule.makeBoundsCheckConstant(UInt32(matrix.columns)))
            return
        }

        guard let array = shaderModule.types.getIf(Types.Array.self, base) else {
            wgslFatal("std::get<Types::Array> of an indexed type that is not an array", cppSite: "BoundsCheck.cpp:174")
        }
        let indexExpression = access.index
        var sizeExpression: ExpressionID?
        var sizeConstant: UInt32?

        switch array.size {
        case .creationFixed(let size):
            sizeConstant = size
        case .overrideSized(let size):
            sizeExpression = size
        case .runtime:
            let target = shaderModule.constructIdentifierExpression(
                span: .empty,
                identifier: shaderModule.makeIdentifier(Symbol(.arrayLength))
            )
            shaderModule.setInferredType(shaderModule.types.u32Type, for: target)

            var argument = access.base
            if let reference = shaderModule.types.getIf(Types.Reference.self, shaderModule.inferredType(of: access.base)) {
                let addressOf = shaderModule.construct(span: .empty, UnaryExpression(expression: access.base, operation: .addressOf))
                let pointerType = shaderModule.types.pointerType(reference.addressSpace, reference.element, reference.accessMode)
                shaderModule.setInferredType(pointerType, for: addressOf)
                argument = addressOf
            }

            guard shaderModule.types.getIf(Types.Pointer.self, shaderModule.inferredType(of: argument)) != nil else {
                wgslFatal("the argument of a synthesised arrayLength call is not a pointer", cppSite: "BoundsCheck.cpp:209")
            }
            let call = shaderModule.construct(span: .empty, CallExpression(target: target, arguments: shaderModule.makeList([argument])))
            shaderModule.setInferredType(shaderModule.types.u32Type, for: call)

            shaderModule.replaceWithClampedAccess(id, call)
        }

        let check = OverrideValidation.Check.boundsCheckOverrideIndex(
            access: id,
            index: indexExpression,
            constant: sizeConstant,
            sizeExpression: sizeExpression
        )
        shaderModule.addOverrideValidation(OverrideValidation(guards: [], check: check))

        if sizeConstant != nil || sizeExpression != nil {
            // At generate time the validation above rejects an out-of-range index or replaces the access with the clamp. A
            // constant index into a constant extent was already range-checked by TypeCheck.cpp:1346-1366.
            let proof =
                sizeConstant != nil && shaderModule.evaluation(of: indexExpression) == .constant
                ? BoundsMint.inBoundsConstant() : BoundsMint.overrideValidated()
            shaderModule.markChecked(id, access, proof)
        }
    }

    // m_visited (BoundsCheck.cpp:71-73): an access is checked once it has been visited.
    mutating func visit(_ access: CheckedIndexAccessExpression, _ id: ExpressionID) {
    }

    private mutating func checkBounds(_ access: ExpressionID, _ indexExpression: ExpressionID, _ size: UInt32) {
        shaderModule.addOverrideValidation(
            OverrideValidation(guards: [], check: .boundsCheckIndex(access: access, index: indexExpression, size: size))
        )
    }
}

// The `constant` and `replace` lambdas of BoundsCheckVisitor::visit(AST::IndexAccessExpression&), which the override validation
// also runs at generate time.
extension ShaderModule {
    fileprivate mutating func makeBoundsCheckConstant(_ size: UInt32) -> ExpressionID {
        let sizeExpression = construct(span: .empty, Unsigned32Literal(value: size))
        setInferredType(types.u32Type, for: sizeExpression)
        setConstantValue(.uint32(size), for: sizeExpression)
        return sizeExpression
    }

    fileprivate mutating func replaceWithClampedAccess(_ access: ExpressionID, _ size: ExpressionID) {
        guard let current = anyIndexAccess(access) else {
            wgslFatal("a clamped replacement of an expression that is not an index access", cppSite: "BoundsCheck.cpp:87")
        }
        let minCall = makeClampedIndex(current.index, size)

        let newAccess = construct(
            span: span(of: access),
            CheckedIndexAccessExpression(base: current.base, index: minCall, proof: BoundsMint.clamped())
        )
        setInferredType(inferredType(of: access), for: newAccess)

        replace(access, with: newAccess)
        uses.insert(.min)
    }

    /// The clamp `__wgslMin(u32(index), size - 1u)`, without the `u32` conversion when `index` is already a `u32`.
    ///
    /// The only builder of the clamp, so the generic printers give it one spelling: `__wgslMin(unsigned(i), (N - 1u))`. History of
    /// the clamp, which a "simplification" must be checked against: volatile `min(va, vb)`; `select(b, a, a < b)` (d9758a8fd190,
    /// which reintroduced an out-of-bounds access); `min(a, b)` plus the forward-progress loop guard (f7fc51937f2e); volatile
    /// `min` again (8413627058d8); `min(a, b)` again because the volatile form crashed MTLCompiler (6e625198e80f). Nothing
    /// depends on the GPU family; a split must be an exhaustive switch over `WriterGPUClass`.
    fileprivate mutating func makeClampedIndex(_ index: ExpressionID, _ size: ExpressionID) -> ExpressionID {
        var index = index
        if inferredType(of: index) != types.u32Type {
            let u32Target = constructIdentifierExpression(span: .empty, identifier: makeIdentifier(Symbol(.u32)))
            setInferredType(types.u32Type, for: u32Target)

            let u32Call = construct(span: .empty, CallExpression(target: u32Target, arguments: makeList([index])))
            setInferredType(types.u32Type, for: u32Call)
            modify(CallExpression.self, u32Call) { $0.isConstructor = true }
            index = u32Call
        }

        let minTarget = constructIdentifierExpression(
            span: .empty,
            identifier: makeIdentifier(symbols.intern(ReservedName.fixed(.wgslMin)))
        )
        setInferredType(types.u32Type, for: minTarget)

        let one = construct(span: .empty, Unsigned32Literal(value: 1))
        setInferredType(types.u32Type, for: one)
        setConstantValue(.uint32(1), for: one)

        let upperBound = construct(span: .empty, BinaryExpression(leftExpression: size, rightExpression: one, operation: .subtract))
        setInferredType(types.u32Type, for: upperBound)

        let minCall = construct(span: .empty, CallExpression(target: minTarget, arguments: makeList([index, upperBound])))
        setInferredType(inferredType(of: upperBound), for: minCall)
        return minCall
    }

    /// BoundsCheck.cpp:238-258: at generate time, the override validation of an array access whose index or size it could not
    /// evaluate replaces the access with its clamped form.
    mutating func replaceUnvalidatedOverrideIndexAccess(_ access: ExpressionID, _ sizeConstant: UInt32?, _ sizeExpression: ExpressionID?) {
        let expression: ExpressionID
        if let sizeExpression {
            expression = sizeExpression
        } else if let sizeConstant {
            expression = makeBoundsCheckConstant(sizeConstant)
        } else {
            wgslFatal("std::optional dereference of an array access with neither size", cppSite: "BoundsCheck.cpp:239")
        }

        if nodeKind(of: access) == .indexAccessExpression {
            replaceWithClampedAccess(access, expression)
            return
        }

        // This is a bit of hack, since global rewriting will run between we
        // bounds check and override validation, this access might have been
        // converted into a __pack call.
        var updatedAccess = access
        while case .identityExpression(let identity) = self[updatedAccess].kind {
            updatedAccess = identity.expression
        }
        guard case .callExpression(let call) = self[updatedAccess].kind else {
            wgslFatal("a packed index access that is not a call", cppSite: "BoundsCheck.cpp:252")
        }
        guard count(call.arguments) == 1 else {
            wgslFatal("a packed index access whose call does not have one argument", cppSite: "BoundsCheck.cpp:254")
        }
        let newAccess = self[call.arguments, 0]
        guard nodeKind(of: newAccess) == .indexAccessExpression else {
            wgslFatal("a packed index access whose argument is not an index access", cppSite: "BoundsCheck.cpp:255")
        }
        replaceWithClampedAccess(newAccess, expression)
    }
}

@_spi(Testing)
@discardableResult
public func insertBoundsChecks(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    var visitor = BoundsCheckVisitor(shaderModule: shaderModule)
    let result = visitor.run()
    shaderModule = visitor.shaderModule
    return result
}

// MARK: - Subscript proofs

/// Why a CheckedIndexAccessExpression's subscript may be printed.
///
/// Only BoundsMint, in this file, can make one.
@_spi(Testing)
public struct SubscriptProof: BitwiseCopyable, Equatable, Sendable {
    @_spi(Testing)
    public enum Reason: UInt8, BitwiseCopyable, Equatable, Sendable {
        /// The index is BoundsCheck's `__wgslMin(u32(i), N - 1u)` clamp.
        case clamped
        /// A constant index range-checked against a constant extent.
        case inBoundsConstant
        /// An index range-checked by the override validation at generate time.
        case overrideValidated
        /// The access has a constant value, so the writer prints the constant, never the subscript.
        case constantValue
        /// The induction variable of a compiler-generated loop over the extent.
        case loopInduction
    }

    @_spi(Testing)
    public let reason: Reason

    fileprivate init(_ reason: Reason) {
        self.reason = reason
    }
}

/// The only maker of SubscriptProofs.
///
/// The BoundsCheck pass decides which proof an access gets.
enum BoundsMint {
    fileprivate static func clamped() -> SubscriptProof {
        SubscriptProof(.clamped)
    }

    fileprivate static func inBoundsConstant() -> SubscriptProof {
        SubscriptProof(.inBoundsConstant)
    }

    fileprivate static func overrideValidated() -> SubscriptProof {
        SubscriptProof(.overrideValidated)
    }

    fileprivate static func constantValue() -> SubscriptProof {
        SubscriptProof(.constantValue)
    }

    /// The `__i<depth>` subscript of a zero-initialization loop (GlobalVariableRewriter.cpp:2693); only
    /// GlobalVariableRewriter+Initialization.swift can make the plan.
    static func loopInduction(_ plan: borrowing ZeroInitLoopPlan) -> SubscriptProof {
        SubscriptProof(.loopInduction)
    }

    /// The `__i` subscripts of the writer's clip-distance copy loop (MetalFunctionWriter.cpp:1181); only
    /// Metal/MetalFunctionWriter+Declarations.swift can make the loop.
    static func clipDistanceCopyLoop(_ loop: borrowing ClipDistanceCopyLoop) -> SubscriptProof {
        SubscriptProof(.loopInduction)
    }
}

extension ShaderModule {
    /// Converts an access that needs no clamp in place; logged when the access predates the open scope.
    fileprivate mutating func markChecked(_ id: ExpressionID, _ access: IndexAccessExpression, _ proof: SubscriptProof) {
        modify(id) { node in
            node.kind = .checkedIndexAccessExpression(CheckedIndexAccessExpression(base: access.base, index: access.index, proof: proof))
        }
    }
}

// MARK: - Testing hooks

extension CheckedModule {
    /// The prepare passes up to and including insertBoundsChecks, for tests that stop after insertBoundsChecks or
    /// rewriteEntryPoints: opens a CompilationScope, runs insertBoundsChecks and then `next` (the later passes and the dump),
    /// and rolls the scope back.
    @_spi(Testing)
    public consuming func insertBoundsChecksForTesting(then next: (inout ShaderModule) -> Void) -> CheckedModule {
        let step = state.prepare { shaderModule -> Result<Void, CompilationMessage> in
            insertBoundsChecks(&shaderModule)
            next(&shaderModule)
            return .success(())
        }
        switch consume step {
        case .prepared(let prepared, _):
            return CheckedModule(state: prepared.rollBack())
        case .failed(let rolledBack, _):
            return CheckedModule(state: rolledBack)
        }
    }
}
