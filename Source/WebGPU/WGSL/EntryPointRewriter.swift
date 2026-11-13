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

private struct EntryPointRewriter: ~Copyable {
    struct MemberOrParameter {
        let name: Identifier
        let type: ExpressionID
        let attributes: [AttributeID]
    }

    struct BuiltinMemberOrParameter {
        let name: Identifier
        let type: ExpressionID
        let attributes: [AttributeID]
        let builtin: Builtin

        init(_ data: MemberOrParameter, _ builtin: Builtin) {
            name = data.name
            type = data.type
            attributes = data.attributes
            self.builtin = builtin
        }
    }

    enum IsBuiltin {
        case no
        case yes(builtinName: Symbol)
    }

    let stage: ShaderStage
    var shaderModule: ShaderModule
    let function: FunctionID

    var builtins: [BuiltinMemberOrParameter] = []
    var parameters: [MemberOrParameter] = []
    var materializations: [StatementID] = []
    var structType: TypeID?
    var structTypeName: Symbol
    var structParameterName: Symbol
    var builtinID: UInt32 = 0

    init(shaderModule: consuming ShaderModule, function: FunctionID, stage: ShaderStage) {
        self.stage = stage
        self.shaderModule = shaderModule
        self.function = function
        let functionName = self.shaderModule.symbol(of: self.shaderModule[function].name)
        structTypeName = self.shaderModule.symbols.intern(.entryPointInputStruct(of: functionName))
        structParameterName = self.shaderModule.symbols.intern(.entryPointInputParameter(of: functionName))
    }

    mutating func rewrite() {
        collectParameters()
        checkReturnType()
        appendBuiltins()

        if !parameters.isEmpty {
            constructInputStruct()

            // add parameter to builtins: ${structName} : ${structType}
            let type = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(structTypeName))
            shaderModule.setInferredType(structType, for: type)
            let attributes = shaderModule.makeEmptyList(AttributeID.self)
            let parameter = shaderModule.constructParameter(
                span: .empty,
                name: shaderModule.makeIdentifier(structParameterName),
                typeName: type,
                attributes: attributes,
                role: .stageIn
            )
            shaderModule.append(shaderModule[function].parameters, parameter)
        }

        let body = shaderModule.downcast(CompoundStatement.self, shaderModule[function].body)
        shaderModule.insertVector(body.statements, 0, materializations)
    }

    mutating func collectParameters() {
        let functionParameters = shaderModule[function].parameters
        var cursor = shaderModule.cursor(functionParameters)
        while let parameter = shaderModule.next(&cursor) {
            var path: [Symbol] = []
            let node = shaderModule[parameter]
            let data = MemberOrParameter(
                name: shaderModule[node.name],
                type: node.typeName,
                attributes: shaderModule.elements(node.attributes)
            )
            visit(&path, data)
        }
        shaderModule.clear(functionParameters)
    }

    mutating func checkReturnType() {
        if stage == .compute {
            return
        }
        let maybeReturnType = shaderModule[function].maybeReturnType
        var namedTypeName: ExpressionID?
        if let maybeReturnType, shaderModule.is(IdentifierExpression.self, maybeReturnType) {
            namedTypeName = maybeReturnType
        }

        if let namedTypeName {
            if let structType = shaderModule.types.getIf(Types.Struct.self, shaderModule.inferredType(of: namedTypeName)) {
                func duplicateStruct(_ role: StructureRole, _ suffix: ReservedName.OutputStage) {
                    let structure = shaderModule[structType.structure]
                    assert(structure.role == .userDefined)
                    let returnStructName = shaderModule.symbols.intern(
                        .stageOutputStruct(of: shaderModule.symbol(of: structure.name), suffix)
                    )
                    let members = shaderModule.makeList(shaderModule.elements(structure.members))
                    let returnStruct = shaderModule.constructStructure(
                        span: .empty,
                        name: shaderModule.makeIdentifier(returnStructName),
                        members: members,
                        role: role
                    )
                    shaderModule.append(shaderModule.declarations, .structure(returnStruct))
                    let returnType = shaderModule.constructIdentifierExpression(
                        span: .empty,
                        identifier: shaderModule.makeIdentifier(returnStructName)
                    )
                    shaderModule.setInferredType(shaderModule.types.structType(returnStruct), for: returnType)
                    shaderModule.setEvaluation(shaderModule.evaluation(of: namedTypeName), for: returnType)
                    shaderModule.replace(namedTypeName, with: returnType)
                }

                if stage == .fragment {
                    duplicateStruct(.fragmentOutput, .fragment)
                    return
                }

                duplicateStruct(.vertexOutput, .vertex)
                return
            }
        }

        guard let maybeReturnType, stage == .fragment || stage == .vertex, shaderModule.count(shaderModule[function].returnAttributes) != 0
        else {
            return
        }

        let stageName: ReservedName.OutputStage = stage == .fragment ? .fragment : .vertex
        let functionName = shaderModule.symbol(of: shaderModule[function].name)
        let returnStructName = shaderModule.symbols.intern(.stageOutputStruct(of: functionName, stageName))
        let fieldType = shaderModule.constructIdentifierExpression(
            span: .empty,
            identifier: shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.type)))
        )
        shaderModule.setInferredType(shaderModule.inferredType(of: maybeReturnType), for: fieldType)
        let memberAttributes = shaderModule.makeList(shaderModule.elements(shaderModule[function].returnAttributes))
        let member = shaderModule.constructStructureMember(
            span: .empty,
            name: shaderModule.makeIdentifier(shaderModule.symbols.intern(.fixed(.value))),
            type: fieldType,
            attributes: memberAttributes
        )
        let role: StructureRole = stage == .fragment ? .fragmentOutputWrapper : .vertexOutputWrapper
        let members = shaderModule.makeList([member])
        let returnStruct = shaderModule.constructStructure(
            span: .empty,
            name: shaderModule.makeIdentifier(returnStructName),
            members: members,
            role: role
        )
        shaderModule.append(shaderModule.declarations, .structure(returnStruct))
        let returnType = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(returnStructName))
        shaderModule.setInferredType(shaderModule.types.structType(returnStruct), for: returnType)
        shaderModule.setEvaluation(shaderModule.evaluation(of: maybeReturnType), for: returnType)

        if let namedTypeName {
            shaderModule.replace(namedTypeName, with: returnType)
        } else if shaderModule.is(ElaboratedTypeExpression.self, maybeReturnType) {
            shaderModule.replace(maybeReturnType, with: returnType)
        } else if shaderModule.is(ArrayTypeExpression.self, maybeReturnType) {
            shaderModule.replace(maybeReturnType, with: returnType)
        } else {
            wgslFatal("an entry point's return type is not a named, elaborated or array type", cppSite: "EntryPointRewriter.cpp:200")
        }
    }

    mutating func constructInputStruct() {
        // insert `var ${parameter.name()} = ${structName}.${parameter.name()}`
        var structMembers: [StructureMemberID] = []
        for parameter in parameters {
            let attributes = shaderModule.makeList(parameter.attributes)
            structMembers.append(
                shaderModule.constructStructureMember(span: .empty, name: parameter.name, type: parameter.type, attributes: attributes)
            )
        }

        let role: StructureRole
        switch stage {
        case .compute:
            role = .computeInput
        case .vertex:
            role = .vertexInput
        case .fragment:
            role = .fragmentInput
        }

        let members = shaderModule.makeList(structMembers)
        let structure = shaderModule.constructStructure(
            span: .empty,
            name: shaderModule.makeIdentifier(structTypeName),
            members: members,
            role: role
        )
        shaderModule.append(shaderModule.declarations, .structure(structure))
        structType = shaderModule.types.structType(structure)
    }

    mutating func materialize(_ path: inout [Symbol], _ data: MemberOrParameter, _ isBuiltin: IsBuiltin) {
        let rhs: ExpressionID
        switch isBuiltin {
        case .yes(let builtinName):
            rhs = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(builtinName))
        case .no:
            let base = shaderModule.constructIdentifierExpression(
                span: .empty,
                identifier: shaderModule.makeIdentifier(structParameterName)
            )
            rhs = shaderModule.constructFieldAccessExpression(
                span: .empty,
                base: base,
                fieldName: shaderModule.makeIdentifier(data.name.symbol)
            )
        }

        if path.isEmpty {
            let attributes = shaderModule.makeEmptyList(AttributeID.self)
            let variable = shaderModule.constructVariable(
                span: .empty,
                flavor: .var,
                name: shaderModule.makeIdentifier(data.name.symbol),
                qualifier: nil,
                type: data.type,
                initializer: rhs,
                attributes: attributes
            )
            materializations.append(shaderModule.construct(span: .empty, VariableStatement(variable: variable)))
            return
        }

        path.append(data.name.symbol)
        var i = 0
        var lhs = shaderModule.constructIdentifierExpression(span: .empty, identifier: shaderModule.makeIdentifier(path[i]))
        i &+= 1
        while i < path.count {
            lhs = shaderModule.constructFieldAccessExpression(span: .empty, base: lhs, fieldName: shaderModule.makeIdentifier(path[i]))
            i &+= 1
        }
        path.removeLast()
        materializations.append(shaderModule.construct(span: .empty, AssignmentStatement(lhs: lhs, rhs: rhs)))
    }

    mutating func visit(_ path: inout [Symbol], _ data: MemberOrParameter) {
        if let structType = shaderModule.types.getIf(Types.Struct.self, shaderModule.inferredType(of: data.type)) {
            let attributes = shaderModule.makeEmptyList(AttributeID.self)
            let variable = shaderModule.constructVariable(
                span: .empty,
                flavor: .var,
                name: shaderModule.makeIdentifier(data.name.symbol),
                qualifier: nil,
                type: data.type,
                initializer: nil,
                attributes: attributes
            )
            materializations.append(shaderModule.construct(span: .empty, VariableStatement(variable: variable)))
            path.append(data.name.symbol)
            var cursor = shaderModule.cursor(shaderModule[structType.structure].members)
            while let member = shaderModule.next(&cursor) {
                let node = shaderModule[member]
                visit(
                    &path,
                    MemberOrParameter(name: shaderModule[node.name], type: node.type, attributes: shaderModule.elements(node.attributes))
                )
            }
            path.removeLast()
            return
        }

        var builtin: Builtin?
        var index = 0
        while index < data.attributes.count {
            if let builtinAttribute = shaderModule.dynamicDowncast(BuiltinAttribute.self, data.attributes[index]) {
                builtin = builtinAttribute.builtin
                break
            }
            index &+= 1
        }

        if let builtin {
            if !path.isEmpty {
                // builtin was hoisted from a struct into a parameter, we need to reconstruct the struct
                // ${path}.${data.name} = __builtin${builtinID}
                // Note that we don't use ${data.name} on the right-hand side because it's the name of a
                // struct field, and it might not be unique.
                let builtinName = shaderModule.symbols.intern(.builtinParameter(builtinID))
                builtinID &+= 1
                materialize(&path, data, .yes(builtinName: builtinName))
                let hoisted = MemberOrParameter(
                    name: shaderModule.makeIdentifier(builtinName),
                    type: data.type,
                    attributes: data.attributes
                )
                builtins.append(BuiltinMemberOrParameter(hoisted, builtin))
                return
            }

            // if path is empty, then it was already a parameter and there's nothing to do
            builtins.append(BuiltinMemberOrParameter(data, builtin))
            return
        }

        // parameter was moved into a struct, so we need to reload it
        // ${path}.${data.name} = ${struct}.${data.name}
        materialize(&path, data, .no)
        parameters.append(data)
    }

    mutating func appendBuiltins() {
        for data in builtins {
            let attributes = shaderModule.makeList(data.attributes)
            let parameter = shaderModule.constructParameter(
                span: .empty,
                name: shaderModule.makeIdentifier(data.name.symbol),
                typeName: data.type,
                attributes: attributes,
                role: .userDefined
            )
            shaderModule.modify(parameter) { $0.builtin = data.builtin }
            shaderModule.append(shaderModule[function].parameters, parameter)
        }
    }
}

/// C++ `rewriteEntryPoints(shaderModule, pipelineLayouts)`: rewrites the entry points whose source names `pipelineLayouts` contains.
@_spi(Testing)
public func rewriteEntryPoints(_ shaderModule: inout ShaderModule, _ pipelineLayouts: LookupMap<Name, Int?>) {
    let entryPoints = shaderModule.callGraph.entrypoints
    for entryPoint in entryPoints {
        if !pipelineLayouts.contains(entryPoint.apiName) {
            continue
        }
        var rewriter = EntryPointRewriter(shaderModule: shaderModule, function: entryPoint.function, stage: entryPoint.stage)
        rewriter.rewrite()
        shaderModule = rewriter.shaderModule
    }
}
