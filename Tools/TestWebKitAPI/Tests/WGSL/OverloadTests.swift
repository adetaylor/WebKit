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

private func makeModule() -> ShaderModule {
    ShaderModule(source: SourceText(""))
}

private func concrete(_ type: TypeID) -> AbstractType {
    .concrete(.fixed(type))
}

private func builtin(_ module: inout ShaderModule, _ name: StaticString) throws -> OverloadedDeclaration {
    let symbol = module.makeIdentifier(name).symbol
    let declaration = module.lookupOverload(symbol)
    return try #require(declaration)
}

/// Resolves a call of the builtin `name` as TypeCheck does: the declaration's candidates, in table order.
private func resolve(
    _ module: inout ShaderModule,
    _ name: StaticString,
    _ valueArguments: [TypeID],
    typeArguments: [TypeID] = []
) throws -> SelectedOverload? {
    let declaration = try builtin(&module, name)
    return resolveOverloads(&module.types, declaration.overloads, valueArguments, typeArguments)
}

private func expectSelected(
    _ selected: SelectedOverload?,
    _ parameters: [TypeID],
    _ result: TypeID,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let selected else {
        Issue.record("no overload selected", sourceLocation: sourceLocation)
        return
    }
    #expect(selected.parameters == parameters, sourceLocation: sourceLocation)
    #expect(selected.result == result, sourceLocation: sourceLocation)
}

/// Runs `body` on a thread with a `stackSize`-byte stack and waits for it.
private func onThread<Result: Sendable>(stackSize: Int, _ body: @escaping @Sendable () -> Result) -> Result {
    let completion = ThreadCompletion<Result>()
    let thread = Thread {
        completion.complete(body())
    }
    thread.stackSize = stackSize
    thread.start()
    return completion.wait()
}

private final class ThreadCompletion<Result: Sendable>: Sendable {
    private let result = Mutex<Result?>(nil)
    private let done = DispatchSemaphore(value: 0)

    func complete(_ value: Result) {
        result.withLock { $0 = value }
        done.signal()
    }

    func wait() -> Result {
        done.wait()
        guard let value = result.withLock({ $0 }) else {
            preconditionFailure("the thread finished without a result")
        }
        return value
    }
}

private struct ArrayChainSummary: Sendable {
    var depth = 0
    var allSizesOne = true
    var innermost: TypeID?
    var concretizedTwiceIsIdentity = false
}

@Suite
struct WGSLOverloadTests {
    // MARK: - BuiltinTable and lookupOverload

    @Test
    func builtinTableHasTheGeneratedDeclarationsInPredeclaredSymbolOrder() throws {
        let table = BuiltinTable.shared
        #expect(table.count == 182)
        var candidates = 0
        for index in 0..<table.count {
            let declaration = table[index]
            #expect(declaration.symbol == Symbol(predeclaredIndex: index))
            candidates += declaration.overloads.count
        }
        #expect(candidates == 533)
    }

    // A build costs at most 8 times the CPU time of a copy of its candidates, each with new arrays, and the process-wide
    // table is built once.
    @Test
    func builtinTableBuildsInAboutAMillisecond() {
        let factor = 8
        func copyOfTheCandidates(_ table: BuiltinTable) -> [[OverloadCandidate]] {
            var declarations: [[OverloadCandidate]] = []
            declarations.reserveCapacity(table.count)
            for index in 0..<table.count {
                declarations.append(
                    table[index].overloads
                        .map {
                            OverloadCandidate(
                                typeVariables: $0.typeVariables.map { $0 },
                                valueVariables: $0.valueVariables.map { $0 },
                                parameters: $0.parameters.map { $0 },
                                result: $0.result
                            )
                        }
                )
            }
            return declarations
        }

        let shared = BuiltinTable.shared
        var fastestBuild = Duration.seconds(60)
        var fastestCopy = Duration.seconds(60)
        var thousandSharedAccesses = Duration.seconds(60)
        for _ in 0..<5 {
            var table: BuiltinTable?
            fastestBuild = min(fastestBuild, threadCPUTime { table = BuiltinTable() })
            #expect(table?.count == 182)

            var copy: [[OverloadCandidate]] = []
            fastestCopy = min(fastestCopy, threadCPUTime { copy = copyOfTheCandidates(shared) })
            #expect(copy.count == 182)

            var total = 0
            thousandSharedAccesses = min(
                thousandSharedAccesses,
                threadCPUTime {
                    for _ in 0..<1000 {
                        total &+= BuiltinTable.shared.count
                    }
                }
            )
            #expect(total == 182_000)
        }

        let optimized = CompileThread.recommendedStackSize == nil
        print(
            "WGSLOverloadTests: BuiltinTable() build \(fastestBuild) of CPU time (\(optimized ? "-O" : "-Onone")); a copy of its candidates \(fastestCopy); 1000 BuiltinTable.shared accesses \(thousandSharedAccesses)"
        )
        #expect(fastestBuild <= fastestCopy * factor)
        // The process-wide table is built once: a thousand uses of it cost less than one build, and share its storage.
        #expect(thousandSharedAccesses < fastestBuild)
        var sharesItsStorage = true
        for index in 0..<shared.count {
            sharesItsStorage =
                sharesItsStorage && BuiltinTable.shared[index].overloads.isTriviallyIdentical(to: BuiltinTable.shared[index].overloads)
        }
        #expect(sharesItsStorage)
    }

    @Test
    func builtinCandidatesKeepTheTypeDeclarationsOrder() throws {
        var module = makeModule()
        let vec2 = try builtin(&module, "vec2")
        #expect(vec2.kind == .constructor)
        #expect(vec2.mustUse)
        #expect(vec2.overloads.map(\.parameters.count) == [0, 1, 1, 1, 2, 0])
        #expect(vec2.overloads.map(\.typeVariables.count) == [1, 1, 2, 1, 1, 0])
        #expect(vec2.overloads[0].typeVariables[0].constraint == .concreteScalar)
        #expect(vec2.overloads[2].typeVariables.map(\.constraint) == [.concreteScalar, .scalar])
        #expect(vec2.overloads[3].typeVariables.map(\.constraint) == [.scalar])

        // f32 is declared twice in TypeDeclarations.rb; the candidates of both declarations are kept in order.
        let f32 = try builtin(&module, "f32")
        #expect(f32.overloads.map(\.parameters.count) == [0, 1])

        let workgroupUniformLoad = try builtin(&module, "workgroupUniformLoad")
        #expect(workgroupUniformLoad.kind == .function)
        #expect(workgroupUniformLoad.visibility == .compute)
        #expect(workgroupUniformLoad.overloads.count == 2)
        guard
            case .pointer(.constant(let addressSpace), .atomic, .constant(let accessMode)) = workgroupUniformLoad.overloads[0].parameters[0]
        else {
            Issue.record("workgroupUniformLoad's first candidate takes ptr<workgroup, atomic<T>, read_write>")
            return
        }
        #expect(addressSpace == UInt32(AddressSpace.workgroup.rawValue))
        #expect(accessMode == UInt32(AccessMode.readWrite.rawValue))
        guard case .pointer(_, .variable, _) = workgroupUniformLoad.overloads[1].parameters[0] else {
            Issue.record("workgroupUniformLoad's second candidate takes ptr<workgroup, T>")
            return
        }
    }

    @Test
    func lookupOverloadIsAnIndexIntoTheTable() throws {
        var module = makeModule()
        for index in 0..<BuiltinTable.shared.count {
            let symbol = try #require(Symbol(predeclaredIndex: index))
            #expect(module.lookupOverload(symbol)?.symbol == symbol)
        }

        let plus = module.makeIdentifier("+").symbol
        #expect(module.lookupOverload(plus)?.kind == .operator)
        let fract = module.makeIdentifier("fract").symbol
        #expect(module.lookupOverload(fract)?.symbol == fract)

        // Predeclared symbols past the declarations (primitive-struct field names, type aliases) and module symbols are
        // not builtins.
        let notBuiltins: [StaticString] = ["whole", "old_value", "exchanged", "vec2f", "mat4x4h", "notABuiltin"]
        for name in notBuiltins {
            let symbol = module.makeIdentifier(name).symbol
            #expect(module.lookupOverload(symbol) == nil, "\(name)")
        }
    }

    // MARK: - resolveOverloads

    @Test
    func unificationPromotesTheTypeVariable() throws {
        var module = makeModule()
        let i32 = FixedTypeID.i32
        let u32 = FixedTypeID.u32
        let f32 = FixedTypeID.f32
        let abstractInt = FixedTypeID.abstractInt
        let abstractFloat = FixedTypeID.abstractFloat

        // The examples of the comment in OverloadResolver::unify.
        expectSelected(try resolve(&module, "+", [abstractInt, u32]), [u32, u32], u32)
        let vec3f = module.types.vectorType(3, f32)
        expectSelected(try resolve(&module, "vec3", [abstractInt, abstractFloat, f32]), [f32, f32, f32], vec3f)
        expectSelected(try resolve(&module, "vec3", [abstractFloat, abstractInt, f32]), [f32, f32, f32], vec3f)
        #expect(try resolve(&module, "vec3", [abstractFloat, u32, f32]) == nil)

        expectSelected(try resolve(&module, "+", [abstractInt, abstractInt]), [abstractInt, abstractInt], abstractInt)
        expectSelected(try resolve(&module, "+", [i32, abstractInt]), [i32, i32], i32)
        #expect(try resolve(&module, "+", [i32, u32]) == nil)
    }

    @Test
    func resultTypeVariablesMustResolve() throws {
        var module = makeModule()
        let f32 = FixedTypeID.f32
        let i32 = FixedTypeID.i32
        let abstractInt = FixedTypeID.abstractInt

        // [T < ConcreteScalar].() => vec2[T] leaves T unresolved, so [].() => vec2[abstract_int] is selected.
        expectSelected(try resolve(&module, "vec2", []), [], module.types.vectorType(2, abstractInt))
        expectSelected(try resolve(&module, "vec2", [], typeArguments: [f32]), [], module.types.vectorType(2, f32))

        let vec2i = module.types.vectorType(2, i32)
        expectSelected(try resolve(&module, "vec2", [vec2i], typeArguments: [f32]), [vec2i], module.types.vectorType(2, f32))
        let vec2AbstractInt = module.types.vectorType(2, abstractInt)
        expectSelected(try resolve(&module, "vec2", [vec2AbstractInt]), [vec2AbstractInt], vec2AbstractInt)

        // More type arguments than any candidate's type variables.
        #expect(try resolve(&module, "vec2", [], typeArguments: [f32, f32, f32]) == nil)
        // A type argument violating the type variable's constraint.
        #expect(try resolve(&module, "vec2", [], typeArguments: [vec2i]) == nil)
    }

    @Test
    func equallyRankedCandidatesKeepTheFirst() throws {
        var module = makeModule()
        let atomicPointer = module.types.pointerType(.workgroup, FixedTypeID.atomicI32, .readWrite)
        // Both candidates rank 0; the first, ptr<workgroup, atomic<T>>, gives T = i32 where the second gives atomic<i32>.
        expectSelected(try resolve(&module, "workgroupUniformLoad", [atomicPointer]), [atomicPointer], FixedTypeID.i32)

        let f32Pointer = module.types.pointerType(.workgroup, FixedTypeID.f32, .readWrite)
        expectSelected(try resolve(&module, "workgroupUniformLoad", [f32Pointer]), [f32Pointer], FixedTypeID.f32)

        // ptr[AS, T] takes the address space's default access mode.
        let readPointer = module.types.pointerType(.workgroup, FixedTypeID.f32, .read)
        #expect(try resolve(&module, "workgroupUniformLoad", [readPointer]) == nil)
    }

    @Test
    func selectionKeepsTheFirstUnlessStrictlyBetter() {
        var module = makeModule()
        let abstractInt = FixedTypeID.abstractInt
        let abstractFloat = FixedTypeID.abstractFloat
        let i32 = FixedTypeID.i32
        let u32 = FixedTypeID.u32
        let f32 = FixedTypeID.f32
        func candidate(_ first: TypeID, _ second: TypeID, _ result: TypeID) -> OverloadCandidate {
            OverloadCandidate(
                typeVariables: [],
                valueVariables: [],
                parameters: [concrete(first), concrete(second)],
                result: concrete(result)
            )
        }
        // Conversion ranks from AbstractInt: i32 3, u32 4, AbstractFloat 5, f32 6.
        let candidates = [
            candidate(i32, f32, FixedTypeID.bool), // [3, 6]: selected first
            candidate(u32, i32, FixedTypeID.f16), // [4, 3]: better on one, worse on the other
            candidate(i32, f32, FixedTypeID.void), // [3, 6]: equal
            candidate(i32, u32, FixedTypeID.u32), // [3, 4]: strictly better
            candidate(u32, i32, f32), // [4, 3]
            candidate(i32, u32, abstractFloat), // [3, 4]: equal
            candidate(f32, i32, i32), // [6, 3]
        ]
        expectSelected(resolveOverloads(&module.types, candidates, [abstractInt, abstractInt], []), [i32, u32], u32)
        expectSelected(
            resolveOverloads(&module.types, [candidates[0], candidates[2]], [abstractInt, abstractInt], []),
            [i32, f32],
            FixedTypeID.bool
        )
        expectSelected(
            resolveOverloads(&module.types, [candidates[2], candidates[0]], [abstractInt, abstractInt], []),
            [i32, f32],
            FixedTypeID.void
        )
        expectSelected(
            resolveOverloads(&module.types, [candidates[1], candidates[0]], [abstractInt, abstractInt], []),
            [u32, i32],
            FixedTypeID.f16
        )
        #expect(resolveOverloads(&module.types, candidates, [abstractInt], []) == nil)
        #expect(resolveOverloads(&module.types, [], [abstractInt, abstractInt], []) == nil)

        // A constrained type variable ranks against the promoted type: AbstractInt → AbstractFloat (5) beats f32 (6).
        let float = TypeVariable(id: 0, constraint: .float)
        let promoting = [
            OverloadCandidate(typeVariables: [], valueVariables: [], parameters: [concrete(f32)], result: concrete(f32)),
            OverloadCandidate(typeVariables: [float], valueVariables: [], parameters: [.variable(float)], result: .variable(float)),
        ]
        expectSelected(resolveOverloads(&module.types, promoting, [abstractInt], []), [abstractFloat], abstractFloat)
        expectSelected(resolveOverloads(&module.types, promoting, [f32], []), [f32], f32)
    }

    @Test
    func referenceArgumentsUnifyWithTheirElement() throws {
        var module = makeModule()
        let f32 = FixedTypeID.f32
        let u32 = FixedTypeID.u32
        let f32Reference = module.types.referenceType(.function, f32, .readWrite)
        // T binds to the reference; materialize and the rank promote it to its element.
        expectSelected(try resolve(&module, "abs", [f32Reference]), [f32], f32)
        let vec3f = module.types.vectorType(3, f32)
        let vec3fReference = module.types.referenceType(.private, vec3f, .readWrite)
        expectSelected(try resolve(&module, "abs", [vec3fReference]), [vec3f], vec3f)

        let u32Reference = module.types.referenceType(.storage, u32, .read)
        expectSelected(try resolve(&module, "dot4U8Packed", [u32Reference, u32]), [u32, u32], u32)
        let writeReference = module.types.referenceType(.storage, u32, .write)
        #expect(try resolve(&module, "dot4U8Packed", [writeReference, u32]) == nil)
    }

    @Test
    func valueVariablesBindOnce() throws {
        var module = makeModule()
        let f32 = FixedTypeID.f32
        let vec2f = module.types.vectorType(2, f32)
        let vec3f = module.types.vectorType(3, f32)
        expectSelected(try resolve(&module, "dot", [vec3f, vec3f]), [vec3f, vec3f], f32)
        #expect(try resolve(&module, "dot", [vec2f, vec3f]) == nil)
        let vec3AbstractFloat = module.types.vectorType(3, FixedTypeID.abstractFloat)
        expectSelected(try resolve(&module, "dot", [vec3AbstractFloat, vec3f]), [vec3f, vec3f], f32)
    }

    @Test
    func pointersArraysAtomicsAndTextures() throws {
        var module = makeModule()
        let f32 = FixedTypeID.f32
        let u32 = FixedTypeID.u32
        let abstractInt = FixedTypeID.abstractInt

        let runtimeArray = module.types.arrayType(f32, .runtime)
        let readArray = module.types.pointerType(.storage, runtimeArray, .read)
        expectSelected(try resolve(&module, "arrayLength", [readArray]), [readArray], u32)
        let readWriteArray = module.types.pointerType(.storage, runtimeArray, .readWrite)
        expectSelected(try resolve(&module, "arrayLength", [readWriteArray]), [readWriteArray], u32)
        // For now, we only support dynamic arrays.
        let fixedArray = module.types.pointerType(.storage, module.types.arrayType(f32, .creationFixed(4)), .read)
        #expect(try resolve(&module, "arrayLength", [fixedArray]) == nil)

        let atomicPointer = module.types.pointerType(.storage, FixedTypeID.atomicU32, .readWrite)
        expectSelected(try resolve(&module, "atomicAdd", [atomicPointer, abstractInt]), [atomicPointer, u32], u32)

        let storageTexture = module.types.textureStorageType(.textureStorage1d, .r32uint, .read)
        expectSelected(
            try resolve(&module, "textureLoad", [storageTexture, abstractInt]),
            [storageTexture, FixedTypeID.i32],
            module.types.vectorType(4, u32)
        )
        let floatTexture = module.types.textureStorageType(.textureStorage1d, .rgba8unorm, .readWrite)
        expectSelected(
            try resolve(&module, "textureLoad", [floatTexture, u32]),
            [floatTexture, u32],
            module.types.vectorType(4, f32)
        )
        let writeTexture = module.types.textureStorageType(.textureStorage1d, .r32uint, .write)
        #expect(try resolve(&module, "textureLoad", [writeTexture, u32]) == nil)
    }

    // Resolutions intern their types once, and cost the same however many types the module has: 10,000 resolutions of
    // vec4<f32> * AbstractFloat add no type, and in a module with 16,384 more types each costs at most 4 times its CPU
    // time in a new module.
    @Test
    func resolutionCostIsSmall() throws {
        let factor = 4
        var module = makeModule()
        var largeModule = makeModule()
        let extraTypes = 16_384
        var size: UInt32 = 1
        while largeModule.types.count < module.types.count + extraTypes {
            _ = largeModule.types.arrayType(FixedTypeID.f32, .creationFixed(size))
            size += 1
        }
        let candidates = try builtin(&module, "*").overloads
        let count = 10_000
        func resolutions(_ types: inout TypeStore) -> (selected: Int, cpuTime: Duration) {
            let vec4f = types.vectorType(4, FixedTypeID.f32)
            var selected = 0
            let cpuTime = threadCPUTime {
                for _ in 0..<count where resolveOverloads(&types, candidates, [vec4f, FixedTypeID.abstractFloat], []) != nil {
                    selected += 1
                }
            }
            return (selected: selected, cpuTime: cpuTime)
        }

        _ = resolutions(&module.types)
        let typeCount = module.types.count
        var everySelected = true
        let costs = leastCostsPerUnit(units: (small: count, large: count), factor: factor) {
            let result = resolutions(&module.types)
            everySelected = everySelected && result.selected == count
            return result.cpuTime
        } large: {
            let result = resolutions(&largeModule.types)
            everySelected = everySelected && result.selected == count
            return result.cpuTime
        }
        #expect(everySelected)
        #expect(module.types.count == typeCount)
        print(
            "WGSLOverloadTests: a resolution of vec4<f32> * AbstractFloat over \(candidates.count) candidates took \(costs.small) of CPU time, \(costs.large) with \(extraTypes) more types"
        )
        #expect(costs.large <= costs.small * factor)
    }

    // MARK: - Constraints

    @Test
    func satisfiesComparesTheConstraintBits() {
        var module = makeModule()
        let i32Reference = module.types.referenceType(.function, FixedTypeID.i32, .readWrite)
        let vec2f = module.types.vectorType(2, FixedTypeID.f32)
        for raw in 0...UInt8.max {
            let constraint = Constraint(rawValue: raw)
            // AbstractInt satisfies every constraint from AbstractInt up (C++ `constraint >= Constraints::AbstractInt`).
            #expect(satisfies(FixedTypeID.abstractInt, constraint, module.types) == (raw == 0 || raw >= 2))
            #expect(satisfies(FixedTypeID.abstractFloat, constraint, module.types) == (raw == 0 || raw & 0b111_0000 != 0))
            #expect(satisfies(FixedTypeID.bool, constraint, module.types) == (raw == 0 || raw & 1 != 0))
            #expect(satisfies(FixedTypeID.i32, constraint, module.types) == (raw == 0 || raw & 4 != 0))
            #expect(satisfies(FixedTypeID.u32, constraint, module.types) == (raw == 0 || raw & 8 != 0))
            #expect(satisfies(FixedTypeID.f32, constraint, module.types) == (raw == 0 || raw & 32 != 0))
            #expect(satisfies(FixedTypeID.f16, constraint, module.types) == (raw == 0 || raw & 64 != 0))
            #expect(satisfies(i32Reference, constraint, module.types) == (raw == 0 || raw & 4 != 0))
            #expect(satisfies(FixedTypeID.sampler, constraint, module.types) == (raw == 0))
            #expect(satisfies(FixedTypeID.void, constraint, module.types) == (raw == 0))
            #expect(satisfies(vec2f, constraint, module.types) == (raw == 0))
            #expect(satisfies(nil, constraint, module.types) == (raw == 0))
        }
    }

    @Test
    func satisfyOrPromotePromotesInConstraintOrder() {
        var module = makeModule()
        let abstractInt = FixedTypeID.abstractInt
        let abstractFloat = FixedTypeID.abstractFloat
        let i32 = FixedTypeID.i32
        let u32 = FixedTypeID.u32
        let f32 = FixedTypeID.f32
        let f16 = FixedTypeID.f16
        let bool = FixedTypeID.bool
        func promote(_ type: TypeID?, _ constraint: Constraint) -> TypeID? {
            satisfyOrPromote(type, constraint, module.types)
        }

        // AbstractInt: itself, then i32, u32, AbstractFloat, f32, f16.
        #expect(promote(abstractInt, .none) == abstractInt)
        #expect(promote(abstractInt, .bool) == nil)
        #expect(promote(abstractInt, .abstractInt) == abstractInt)
        #expect(promote(abstractInt, .scalar) == abstractInt)
        #expect(promote(abstractInt, .concreteScalar) == i32)
        #expect(promote(abstractInt, [.u32, .abstractFloat, .f32, .f16]) == u32)
        #expect(promote(abstractInt, [.abstractFloat, .f32, .f16]) == abstractFloat)
        #expect(promote(abstractInt, .concreteFloat) == f32)
        #expect(promote(abstractInt, [.bool, .f16]) == f16)

        // AbstractFloat: itself, then f32, f16; nothing below AbstractFloat's bit.
        #expect(promote(abstractFloat, .none) == abstractFloat)
        #expect(promote(abstractFloat, .integer) == nil)
        #expect(promote(abstractFloat, .float) == abstractFloat)
        #expect(promote(abstractFloat, .concreteNumber) == f32)
        #expect(promote(abstractFloat, [.i32, .f32]) == f32)
        #expect(promote(abstractFloat, [.bool, .u32, .f16]) == f16)

        #expect(promote(i32, .signedInteger) == i32)
        #expect(promote(i32, .float) == nil)
        #expect(promote(u32, .signedInteger) == nil)
        #expect(promote(f16, .concrete32BitNumber) == nil)
        #expect(promote(bool, .scalar) == bool)
        #expect(promote(bool, .number) == nil)

        let f32Reference = module.types.referenceType(.function, f32, .readWrite)
        #expect(promote(f32Reference, .concreteFloat) == f32)
        #expect(promote(f32Reference, .none) == f32Reference)
        let vec2f = module.types.vectorType(2, f32)
        #expect(promote(vec2f, .none) == vec2f)
        #expect(promote(vec2f, .scalar) == nil)
        #expect(promote(FixedTypeID.sampler, .scalar) == nil)
        #expect(promote(nil, .none) == nil)
        #expect(promote(nil, .scalar) == nil)
    }

    @Test
    func concretizeConvertsAbstractTypes() {
        var module = makeModule()
        let abstractInt = FixedTypeID.abstractInt
        let abstractFloat = FixedTypeID.abstractFloat
        let i32 = FixedTypeID.i32
        let f32 = FixedTypeID.f32

        #expect(concretize(abstractInt, &module.types) == i32)
        #expect(concretize(abstractFloat, &module.types) == f32)
        #expect(concretize(FixedTypeID.bool, &module.types) == FixedTypeID.bool)
        #expect(concretize(FixedTypeID.f16, &module.types) == FixedTypeID.f16)
        #expect(concretize(FixedTypeID.sampler, &module.types) == nil)

        let vec3AbstractInt = module.types.vectorType(3, abstractInt)
        #expect(concretize(vec3AbstractInt, &module.types) == module.types.vectorType(3, i32))
        let mat2x3AbstractFloat = module.types.matrixType(2, 3, abstractFloat)
        #expect(concretize(mat2x3AbstractFloat, &module.types) == module.types.matrixType(2, 3, f32))
        let arrayOfVectors = module.types.arrayType(vec3AbstractInt, .creationFixed(2))
        #expect(concretize(arrayOfVectors, &module.types) == module.types.arrayType(module.types.vectorType(3, i32), .creationFixed(2)))

        let frexp = module.types.frexpResultType(abstractFloat, abstractInt)
        #expect(concretize(frexp, &module.types) == module.types.frexpResultType(f32, i32))
        let vec2AbstractFloat = module.types.vectorType(2, abstractFloat)
        let modf = module.types.modfResultType(vec2AbstractFloat, vec2AbstractFloat)
        let vec2f = module.types.vectorType(2, f32)
        #expect(concretize(modf, &module.types) == module.types.modfResultType(vec2f, vec2f))
        let arrayOfFrexp = module.types.arrayType(frexp, .creationFixed(3))
        #expect(
            concretize(arrayOfFrexp, &module.types) == module.types.arrayType(module.types.frexpResultType(f32, i32), .creationFixed(3))
        )
        let exchange = module.types.atomicCompareExchangeResultType(i32)
        #expect(concretize(exchange, &module.types) == exchange)

        let pointer = module.types.pointerType(.function, abstractInt, .readWrite)
        #expect(concretize(pointer, &module.types) == pointer)
        #expect(concretize(FixedTypeID.atomicI32, &module.types) == FixedTypeID.atomicI32)
        #expect(concretize(FixedTypeID.textureDepth2d, &module.types) == nil)
        #expect(concretize(module.types.textureType(.texture2d, f32), &module.types) == nil)
        #expect(concretize(module.types.referenceType(.function, f32, .readWrite), &module.types) == nil)
        #expect(concretize(module.types.arrayType(FixedTypeID.sampler, .creationFixed(2)), &module.types) == nil)
        #expect(concretize(module.types.vectorType(2, FixedTypeID.void), &module.types) == nil)
    }

    @Test
    func concretizeCreatesTheInnermostTypeFirst() {
        var module = makeModule()
        let inner = module.types.arrayType(FixedTypeID.abstractInt, .creationFixed(2))
        let outer = module.types.arrayType(inner, .creationFixed(3))
        let typeCount = module.types.count
        let concretized = concretize(outer, &module.types)
        #expect(module.types.count == typeCount + 2)
        let concreteInner = module.types.arrayType(FixedTypeID.i32, .creationFixed(2))
        #expect(module.types.count == typeCount + 2)
        #expect(concreteInner.raw == UInt32(typeCount))
        #expect(concretized?.raw == UInt32(typeCount + 1))
    }

    @Test
    func DEV_03_concretizeIteratesOverDeepArrayChainsOnA512KiBThread() {
        let depth = 10_000
        let summary = onThread(stackSize: 512 * 1024) { () -> ArrayChainSummary in
            var module = makeModule()
            var type = FixedTypeID.abstractInt
            for _ in 0..<depth {
                type = module.types.arrayType(type, .creationFixed(1))
            }
            var summary = ArrayChainSummary()
            guard let concretized = concretize(type, &module.types) else {
                return summary
            }
            var current = concretized
            while case .array(let array) = module.types[current] {
                summary.depth += 1
                summary.allSizesOne = summary.allSizesOne && array.size == .creationFixed(1)
                current = array.element
            }
            summary.innermost = current
            summary.concretizedTwiceIsIdentity = concretize(concretized, &module.types) == concretized
            return summary
        }
        #expect(summary.depth == depth)
        #expect(summary.allSizesOne)
        #expect(summary.innermost == FixedTypeID.i32)
        #expect(summary.concretizedTwiceIsIdentity)
    }

    @Test
    func materializeBuildsTheDescriptorsType() {
        var module = makeModule()
        let f32 = FixedTypeID.f32
        let i32 = FixedTypeID.i32
        #expect(module.types.materialize(.fixed(FixedTypeID.textureDepthCube)) == FixedTypeID.textureDepthCube)
        #expect(module.types.materialize(.vector(3, .fixed(f32))) == module.types.vectorType(3, f32))
        #expect(module.types.materialize(.matrix(4, 2, .fixed(f32))) == module.types.matrixType(4, 2, f32))
        #expect(module.types.materialize(.texture(.textureCube, .fixed(f32))) == module.types.textureType(.textureCube, f32))
        #expect(module.types.materialize(.atomic(.fixed(i32))) == FixedTypeID.atomicI32)
        let vec2f = module.types.vectorType(2, f32)
        let vec2i = module.types.vectorType(2, i32)
        #expect(
            module.types.materialize(.frexpResult(.vector(2, .fixed(f32)), .vector(2, .fixed(i32))))
                == module.types.frexpResultType(vec2f, vec2i)
        )
        #expect(module.types.materialize(.modfResult(.fixed(f32), .fixed(f32))) == module.types.modfResultType(f32, f32))
        #expect(module.types.materialize(.atomicCompareExchangeResult(.fixed(i32))) == module.types.atomicCompareExchangeResultType(i32))
    }

    // The source chooses which types a call passes, so the memo must not let crafted keys form one probe cluster: every
    // call here falls in 8 of the 4,096 slots under the memo's former unkeyed mix.
    @Test
    func memoCraftedCollisionsDoNotCluster() {
        var types = TypeStore()
        var arguments: [TypeID] = []
        var size: UInt32 = 1
        while size <= 600 {
            arguments.append(types.arrayType(types.f32Type, .creationFixed(size)))
            size += 1
        }
        var declarations: [Int] = []
        var calls: [[TypeID]] = []
        var declaration = 0
        while calls.count < 2_000 {
            for first in arguments {
                for second in arguments where calls.count < 2_000 {
                    let header = UInt64(declaration) | UInt64(2) << 32
                    let leadingArguments = UInt64(first.raw) | UInt64(second.raw) << 32
                    let trailingArguments: UInt64 = 0
                    let typeArgument: UInt32 = 0
                    var h = header &* 0x9e37_79b9_7f4a_7c15
                    h ^= leadingArguments &+ (h >> 29)
                    h &*= 0xbf58_476d_1ce4_e5b9
                    h ^= trailingArguments ^ UInt64(typeArgument) &+ (h >> 31)
                    h &*= 0x94d0_49bb_1331_11eb
                    h ^= h >> 32
                    if h & 0xfff < 8 {
                        declarations.append(declaration)
                        calls.append([first, second])
                    }
                }
            }
            declaration += 1
        }
        let memo = memoizeOverloadResolutions(declarations, calls, result: types.voidType)
        #expect(memo.found == calls.count)
        #expect(memo.longestProbeRun < 250)
    }
}
