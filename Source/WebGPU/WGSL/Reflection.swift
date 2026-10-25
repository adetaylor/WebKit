// Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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

// The IO reflection WebGPU's ShaderModule.mm:384-711 computed by walking the checked AST. WebGPU's Metal and vertex-format
// mappings (and their traps on non-IO types) stay in WebGPU; this walk records the type as an IOType instead. Every location
// is recorded, duplicates included: WebGPU's HashMap::add keeps the first.

private func ioScalar(_ primitive: Types.Primitive) -> IOScalar {
    switch primitive.kind {
    case .i32: .i32
    case .u32: .u32
    case .f16: .f16
    case .f32: .f32
    case .bool: .bool
    case .abstractInt, .abstractFloat, .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
        .other
    }
}

/// metalDataTypeForStructMember and vertexFormatTypeForStructMember.
private func ioType(_ shaderModule: borrowing ShaderModule, _ type: TypeID?) -> IOType {
    guard let type else {
        return .missing
    }

    let vectorType = shaderModule.types.getIf(Types.Vector.self, type)
    guard let primitiveType = shaderModule.types.getIf(Types.Primitive.self, vectorType?.element ?? type) else {
        return .other
    }

    guard let vectorType else {
        return .scalar(ioScalar(primitiveType))
    }
    return .vector(ioScalar(primitiveType), size: vectorType.size)
}

private func populateOutputState(_ entryPointIO: inout EntryPointIO, _ builtIn: Builtin) {
    switch builtIn {
    case .sampleMask:
        entryPointIO.usesSampleMaskInOutput = true
    case .fragDepth:
        entryPointIO.usesFragDepth = true
    case .clipDistances, .frontFacing, .globalInvocationId, .instanceIndex, .localInvocationId, .localInvocationIndex, .numSubgroups,
        .numWorkgroups, .position, .primitiveIndex, .sampleIndex, .subgroupId, .subgroupInvocationId, .subgroupSize, .vertexIndex,
        .workgroupId:
        break
    }
}

private func parseFragmentReturnType(
    _ shaderModule: borrowing ShaderModule,
    _ type: TypeID,
    _ entryPoint: CallGraph.EntryPoint,
    _ entryPointIO: inout EntryPointIO
) -> [IOLocation] {
    var fragmentOutputs: [IOLocation] = []
    if shaderModule.types.getIf(Types.Primitive.self, type) != nil {
        fragmentOutputs.append(
            IOLocation(location: shaderModule[entryPoint.function].returnTypeLocation ?? 0, type: ioType(shaderModule, type))
        )
        return fragmentOutputs
    }
    if shaderModule.types.getIf(Types.Vector.self, type) != nil {
        fragmentOutputs.append(
            IOLocation(location: shaderModule[entryPoint.function].returnTypeLocation ?? 0, type: ioType(shaderModule, type))
        )
        return fragmentOutputs
    }
    guard let returnStruct = shaderModule.types.getIf(Types.Struct.self, type) else {
        return fragmentOutputs
    }

    var members = shaderModule.cursor(shaderModule[returnStruct.structure].members)
    while let memberID = shaderModule.next(&members) {
        let member = shaderModule[memberID]
        if let builtin = member.builtin {
            populateOutputState(&entryPointIO, builtin)
        }

        var attributes = shaderModule.cursor(member.attributes)
        while let attribute = shaderModule.next(&attributes) {
            guard let builtinAttribute = shaderModule.dynamicDowncast(BuiltinAttribute.self, attribute) else {
                continue
            }
            populateOutputState(&entryPointIO, builtinAttribute.builtin)
        }

        guard let location = member.location, member.builtin == nil else {
            continue
        }

        fragmentOutputs.append(IOLocation(location: location, type: ioType(shaderModule, shaderModule.inferredType(of: member.type))))
    }

    return fragmentOutputs
}

private func parseVertexReturnType(_ shaderModule: borrowing ShaderModule, _ type: TypeID) -> [IOLocation] {
    var vertexOutputs: [IOLocation] = []
    if shaderModule.types.getIf(Types.Primitive.self, type) != nil {
        vertexOutputs.append(IOLocation(location: 0, type: ioType(shaderModule, type), interpolation: nil))
        return vertexOutputs
    }
    if shaderModule.types.getIf(Types.Vector.self, type) != nil {
        vertexOutputs.append(IOLocation(location: 0, type: ioType(shaderModule, type), interpolation: nil))
        return vertexOutputs
    }
    guard let returnStruct = shaderModule.types.getIf(Types.Struct.self, type) else {
        return vertexOutputs
    }

    var members = shaderModule.cursor(shaderModule[returnStruct.structure].members)
    while let memberID = shaderModule.next(&members) {
        let member = shaderModule[memberID]
        guard let location = member.location, member.builtin == nil else {
            continue
        }

        vertexOutputs.append(
            IOLocation(
                location: location,
                type: ioType(shaderModule, shaderModule.inferredType(of: member.type)),
                interpolation: member.interpolation
            )
        )
    }

    return vertexOutputs
}

private func populateStageInMap(
    _ shaderModule: borrowing ShaderModule,
    _ type: TypeID,
    _ vertexStageIn: inout [IOLocation],
    _ optionalLocation: UInt32?
) {
    guard let inputStruct = shaderModule.types.getIf(Types.Struct.self, type) else {
        if let optionalLocation {
            vertexStageIn.append(IOLocation(location: optionalLocation, type: ioType(shaderModule, type)))
        }
        return
    }

    var members = shaderModule.cursor(shaderModule[inputStruct.structure].members)
    while let memberID = shaderModule.next(&members) {
        let member = shaderModule[memberID]
        guard let location = member.location else {
            continue
        }
        vertexStageIn.append(IOLocation(location: location, type: ioType(shaderModule, shaderModule.inferredType(of: member.type))))
    }
}

private func populateFragmentInputs(
    _ shaderModule: borrowing ShaderModule,
    _ type: TypeID,
    _ fragmentInputs: inout [IOLocation],
    _ entryPointIO: inout EntryPointIO
) {
    guard let inputStruct = shaderModule.types.getIf(Types.Struct.self, type) else {
        return
    }

    var members = shaderModule.cursor(shaderModule[inputStruct.structure].members)
    while let memberID = shaderModule.next(&members) {
        let member = shaderModule[memberID]
        if let builtin = member.builtin {
            switch builtin {
            case .clipDistances:
                break
            case .fragDepth:
                entryPointIO.usesFragDepth = true
            case .frontFacing:
                entryPointIO.usesFrontFacingInInput = true
            case .globalInvocationId:
                break
            case .instanceIndex:
                break
            case .localInvocationId:
                break
            case .localInvocationIndex:
                break
            case .numWorkgroups:
                break
            case .position:
                break
            case .primitiveIndex:
                entryPointIO.usesPrimitiveIndexInInput = true
            case .sampleIndex:
                entryPointIO.usesSampleIndexInInput = true
            case .sampleMask:
                entryPointIO.usesSampleMaskInInput = true
            case .subgroupInvocationId:
                entryPointIO.usesSubgroupInvocationIdInInput = true
            case .subgroupSize:
                entryPointIO.usesSubgroupSizeInInput = true
            case .subgroupId:
                break
            case .numSubgroups:
                break
            case .vertexIndex:
                break
            case .workgroupId:
                break
            }
        }
        guard let location = member.location else {
            continue
        }
        fragmentInputs.append(
            IOLocation(
                location: location,
                type: ioType(shaderModule, shaderModule.inferredType(of: member.type)),
                interpolation: member.interpolation
            )
        )
    }
}

private func parseStageIn(_ shaderModule: borrowing ShaderModule, _ function: Function) -> [IOLocation] {
    var result: [IOLocation] = []
    var parameters = shaderModule.cursor(function.parameters)
    while let parameterID = shaderModule.next(&parameters) {
        let parameter = shaderModule[parameterID]
        guard parameter.role == .userDefined else {
            continue
        }

        if let inferredType = shaderModule.inferredType(of: parameter.typeName) {
            populateStageInMap(shaderModule, inferredType, &result, parameter.location)
        }
    }

    return result
}

private func parseFragmentInputs(
    _ shaderModule: borrowing ShaderModule,
    _ function: Function,
    _ entryPointIO: inout EntryPointIO
) -> [IOLocation] {
    var result: [IOLocation] = []
    var parameters = shaderModule.cursor(function.parameters)
    while let parameterID = shaderModule.next(&parameters) {
        let parameter = shaderModule[parameterID]
        guard parameter.role == .userDefined else {
            continue
        }

        if let inferredType = shaderModule.inferredType(of: parameter.typeName) {
            populateFragmentInputs(shaderModule, inferredType, &result, &entryPointIO)
        }
    }

    return result
}

/// The ShaderModule constructor's walk (ShaderModule.mm:640-711) over the checked module's entry points, in call-graph order.
func computeEntryPointIO(_ shaderModule: borrowing ShaderModule) -> [EntryPointIO] {
    var result: [EntryPointIO] = []
    let entryPoints = shaderModule.callGraph.entrypoints
    result.reserveCapacity(entryPoints.count)
    var index = 0
    while index < entryPoints.count {
        let entryPoint = entryPoints[index]
        index += 1
        let function = shaderModule[entryPoint.function]
        var entryPointIO = EntryPointIO(name: entryPoint.apiName, stage: entryPoint.stage)
        switch entryPoint.stage {
        case .vertex:
            entryPointIO.stageIn = parseStageIn(shaderModule, function)
            if let expression = function.maybeReturnType {
                if let inferredType = shaderModule.inferredType(of: expression) {
                    entryPointIO.vertexOutputs = parseVertexReturnType(shaderModule, inferredType)

                    // Check for @builtin(clip_distances) in vertex output
                    if let returnStruct = shaderModule.types.getIf(Types.Struct.self, inferredType) {
                        var members = shaderModule.cursor(shaderModule[returnStruct.structure].members)
                        while let memberID = shaderModule.next(&members) {
                            let member = shaderModule[memberID]
                            if member.builtin == .clipDistances {
                                // Extract the array size from array<f32, N>
                                if let arrayType = shaderModule.types.getIf(Types.Array.self, shaderModule.inferredType(of: member.type)) {
                                    if case .creationFixed(let size) = arrayType.size {
                                        entryPointIO.clipDistancesCount = size
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }
        case .fragment:
            let fragmentInputs = parseFragmentInputs(shaderModule, function, &entryPointIO)
            entryPointIO.fragmentInputs = fragmentInputs
            if let expression = function.maybeReturnType {
                if let inferredType = shaderModule.inferredType(of: expression) {
                    let fragmentOutputs = parseFragmentReturnType(shaderModule, inferredType, entryPoint, &entryPointIO)
                    entryPointIO.fragmentOutputs = fragmentOutputs
                }
            }
        case .compute:
            break
        }
        result.append(entryPointIO)
    }
    return result
}
