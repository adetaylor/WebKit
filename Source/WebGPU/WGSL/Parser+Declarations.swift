// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

extension Parser {
    mutating func parseAttribute() throws(CompilationMessage) -> AttributeID? {
        let startOfElementPosition = currentPosition

        try consumeType(.attribute, startOfElementPosition)

        if current.type == .keywordDiagnostic {
            consume()
            let diagnostic = try parseDiagnostic()
            guard let diagnostic else {
                return nil
            }
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .diagnosticAttribute(DiagnosticAttribute(diagnostic: diagnostic))
            )
        }

        let ident = try consumeType(.identifier, startOfElementPosition)

        if equal(ident, "group") {
            try consumeType(.parenLeft, startOfElementPosition)
            let group = try parseExpression()
            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .groupAttribute(GroupAttribute(group: group))
            )
        }

        if equal(ident, "binding") {
            try consumeType(.parenLeft, startOfElementPosition)
            let binding = try parseExpression()
            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .bindingAttribute(BindingAttribute(binding: binding))
            )
        }

        if equal(ident, "location") {
            try consumeType(.parenLeft, startOfElementPosition)
            let location = try parseExpression()
            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .locationAttribute(LocationAttribute(location: location))
            )
        }

        if equal(ident, "builtin") {
            try consumeType(.parenLeft, startOfElementPosition)
            let name = try parseIdentifier()
            guard let builtin = parseBuiltin(codeUnits(of: name)) else {
                throw fail(
                    "Unknown builtin value. Expected 'clip_distances', 'vertex_index', 'instance_index', 'position', 'primitive_index', 'front_facing', 'frag_depth', 'sample_index', 'sample_mask', 'local_invocation_id', 'local_invocation_index', 'global_invocation_id', 'workgroup_id' or 'num_workgroups'",
                    startOfElementPosition
                )
            }
            switch builtin {
            case .fragDepth:
                shaderModule.uses.insert(.fragDepth)
            case .sampleMask:
                shaderModule.uses.insert(.sampleMask)
            case .sampleIndex:
                shaderModule.uses.insert(.sampleIndex)
            case .frontFacing:
                shaderModule.uses.insert(.frontFacing)
            case .clipDistances, .globalInvocationId, .instanceIndex, .localInvocationId, .localInvocationIndex, .numSubgroups,
                .numWorkgroups, .position, .primitiveIndex, .subgroupId, .subgroupInvocationId, .subgroupSize, .vertexIndex,
                .workgroupId:
                break
            }

            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .builtinAttribute(BuiltinAttribute(builtin: builtin))
            )
        }

        if equal(ident, "workgroup_size") {
            try consumeType(.parenLeft, startOfElementPosition)
            let x = try parseExpression()
            var maybeY: ExpressionID?
            var maybeZ: ExpressionID?
            if current.type == .comma {
                consume()
                if current.type != .parenRight {
                    let y = try parseExpression()
                    maybeY = y

                    if current.type == .comma {
                        consume()
                        if current.type != .parenRight {
                            let z = try parseExpression()
                            maybeZ = z

                            if current.type == .comma {
                                consume()
                            }
                        }
                    }
                }
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .workgroupSizeAttribute(WorkgroupSizeAttribute(x: x, maybeY: maybeY, maybeZ: maybeZ))
            )
        }

        if equal(ident, "align") {
            try consumeType(.parenLeft, startOfElementPosition)
            let alignment = try parseExpression()
            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .alignAttribute(AlignAttribute(alignment: alignment))
            )
        }

        if equal(ident, "interpolate") {
            try consumeType(.parenLeft, startOfElementPosition)
            let interpolate = try parseIdentifier()
            guard let interpolationType = parseInterpolationType(codeUnits(of: interpolate)) else {
                throw fail("Unknown interpolation type. Expected 'flat', 'linear' or 'perspective'", startOfElementPosition)
            }
            var sampleType: InterpolationSampling?
            if current.type == .comma {
                consume()

                if current.type == .identifier {
                    let sampling = try parseIdentifier()
                    guard let interpolationSampling = parseInterpolationSampling(codeUnits(of: sampling)) else {
                        throw fail(
                            "Unknown interpolation sampling. Expected 'center', 'centroid', 'sample', 'first' or 'either",
                            startOfElementPosition
                        )
                    }
                    sampleType = interpolationSampling
                    if current.type == .comma {
                        consume()
                    }
                }
            }

            let sampling: InterpolationSampling
            if let sampleType {
                sampling = sampleType
            } else if interpolationType == .flat {
                sampling = .first
            } else {
                sampling = .center
            }

            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .interpolateAttribute(InterpolateAttribute(type: interpolationType, sampling: sampling))
            )
        }

        if equal(ident, "size") {
            try consumeType(.parenLeft, startOfElementPosition)
            let size = try parseExpression()
            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .sizeAttribute(SizeAttribute(size: size))
            )
        }

        if equal(ident, "id") {
            try consumeType(.parenLeft, startOfElementPosition)
            let size = try parseExpression()
            if current.type == .comma {
                consume()
            }
            try consumeType(.parenRight, startOfElementPosition)
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), .idAttribute(IdAttribute(value: size)))
        }

        if equal(ident, "invariant") {
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .invariantAttribute(InvariantAttribute())
            )
        }

        if equal(ident, "must_use") {
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), .mustUseAttribute(MustUseAttribute()))
        }

        if equal(ident, "const") {
            return shaderModule.construct(span: SourceSpan(startOfElementPosition, currentPosition), .constAttribute(ConstAttribute()))
        }

        // https://gpuweb.github.io/gpuweb/wgsl/#pipeline-stage-attributes
        if equal(ident, "vertex") {
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .stageAttribute(StageAttribute(stage: .vertex))
            )
        }
        if equal(ident, "compute") {
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .stageAttribute(StageAttribute(stage: .compute))
            )
        }
        if equal(ident, "fragment") {
            return shaderModule.construct(
                span: SourceSpan(startOfElementPosition, currentPosition),
                .stageAttribute(StageAttribute(stage: .fragment))
            )
        }

        throw fail(
            "Unknown attribute. Supported attributes are 'align', 'binding', 'builtin', 'compute', 'const', 'diagnostic', 'fragment', 'group', 'id', 'interpolate', 'invariant', 'location', 'must_use', 'size', 'vertex', 'workgroup_size'.",
            startOfElementPosition
        )
    }

    mutating func parseDiagnostic() throws(CompilationMessage) -> Diagnostic? {
        let startOfElementPosition = currentPosition
        try consumeType(.parenLeft, startOfElementPosition)
        let severity = try parseIdentifier()
        guard let severityControl = parseSeverityControl(codeUnits(of: severity)) else {
            throw fail("Unknown severity control. Expected 'error', 'info', 'off' or 'warning'", startOfElementPosition)
        }
        try consumeType(.comma, startOfElementPosition)

        let name = try parseIdentifier()
        var triggeringRule: TriggeringRule?

        if current.type == .period {
            consume()
            _ = try parseIdentifier()
        } else if let rule = parseTriggeringRule(codeUnits(of: name)) {
            triggeringRule = rule
        }

        if current.type == .comma {
            consume()
        }
        try consumeType(.parenRight, startOfElementPosition)

        guard let triggeringRule else {
            if unrecognizedDiagnosticRule.isEmpty {
                unrecognizedDiagnosticRule = "unrecognized diagnostic rule "
            }
            var text = unrecognizedDiagnosticRule
            shaderModule.symbols.appendCodeUnits(of: name.symbol, to: &text.codeUnits)
            warnings.append(CompilationMessage(text: text, span: name.span))
            return nil
        }

        return Diagnostic(severity: severityControl, triggeringRule: triggeringRule)
    }

    mutating func parseStructure() throws(CompilationMessage) -> StructureID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordStruct, startOfElementPosition)
        let name = try parseIdentifier()
        try consumeType(.braceLeft, startOfElementPosition)

        var members: [StructureMemberID] = []
        var seenMembers = SymbolMap<Void>()
        swap(&members, &structureMembers)
        swap(&seenMembers, &seenStructureMembers)
        defer {
            if !members.isEmpty {
                members.removeAll(keepingCapacity: true)
            }
            seenMembers.removeAllKeepingCapacity()
            swap(&members, &structureMembers)
            swap(&seenMembers, &seenStructureMembers)
        }
        while current.type != .braceRight {
            let member = try parseStructureMember()
            let memberName = shaderModule[shaderModule[member].name].symbol
            let isNewEntry = seenMembers.add(memberName, ())
            if !isNewEntry {
                throw fail(
                    "duplicate member '\(shaderModule.symbols.text(of: memberName))' in struct '\(shaderModule.symbols.text(of: name.symbol))'",
                    startOfElementPosition
                )
            }
            members.append(member)

            // https://www.w3.org/TR/WGSL/#limits
            let maximumNumberOfStructMembers = 1023
            if members.count > maximumNumberOfStructMembers {
                throw fail("struct cannot have more than \(maximumNumberOfStructMembers) members", startOfElementPosition)
            }

            guard current.type == .comma else {
                break
            }
            consume()
        }

        if members.isEmpty {
            throw fail("structures must have at least one member", startOfElementPosition)
        }

        try consumeType(.braceRight, startOfElementPosition)

        return shaderModule.constructStructure(
            span: SourceSpan(startOfElementPosition, currentPosition),
            name: name,
            members: shaderModule.makeList(members),
            role: .userDefined
        )
    }

    mutating func parseStructureMember() throws(CompilationMessage) -> StructureMemberID {
        let startOfElementPosition = currentPosition

        let attributes = try parseAttributes()
        let name = try parseIdentifier()
        try consumeType(.colon, startOfElementPosition)
        let type = try parseTypeName()

        return shaderModule.constructStructureMember(
            span: SourceSpan(startOfElementPosition, currentPosition),
            name: name,
            type: type,
            attributes: shaderModule.makeList(attributes)
        )
    }

    mutating func parseTypeName() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition

        if current.type == .identifier {
            let name = try parseIdentifier()
            // FIXME: <rdar://150365759> remove the special case for array
            if equal(name, "array") {
                return try parseArrayType()
            }
            return try parseTypeNameAfterIdentifier(name, startOfElementPosition)
        }

        throw fail("Tried parsing a type and it did not start with an identifier", startOfElementPosition)
    }

    mutating func parseTypeNameAfterIdentifier(
        _ name: Identifier,
        _ startOfElementPosition: SourcePosition
    ) throws(CompilationMessage) -> ExpressionID {
        if current.type == .templateArgsLeft {
            let compositeTypeDepthLevel = try compositeTypeDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
            defer { compositeTypeDepth.leave(compositeTypeDepthLevel) }

            try consumeType(.templateArgsLeft, startOfElementPosition)
            var arguments: [ExpressionID] = []
            repeat {
                let elementType = try parseTypeName()
                arguments.append(elementType)
                if current.type != .comma {
                    break
                }
                try consumeType(.comma, startOfElementPosition)
            } while current.type != .templateArgsRight
            try consumeType(.templateArgsRight, startOfElementPosition)
            return shaderModule.constructElaboratedTypeExpression(
                span: SourceSpan(startOfElementPosition, currentPosition),
                base: name,
                arguments: shaderModule.makeList(arguments)
            )
        }
        return shaderModule.constructIdentifierExpression(span: SourceSpan(startOfElementPosition, currentPosition), identifier: name)
    }

    mutating func parseArrayType() throws(CompilationMessage) -> ExpressionID {
        let startOfElementPosition = currentPosition

        var maybeElementType: ExpressionID?
        var maybeElementCount: ExpressionID?

        if current.type == .templateArgsLeft {
            let compositeTypeDepthLevel = try compositeTypeDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
            defer { compositeTypeDepth.leave(compositeTypeDepthLevel) }

            // We differ from the WGSL grammar here by allowing the type to be optional,
            // which allows us to use `parseArrayType` in `parseCallExpression`.
            consume()

            let elementType = try parseTypeName()
            maybeElementType = elementType

            if current.type == .comma {
                consume()
                if current.type != .templateArgsRight {
                    let elementCount = try parseExpression()
                    maybeElementCount = elementCount

                    if current.type == .comma {
                        consume()
                    }
                }
            }
            try consumeType(.templateArgsRight, startOfElementPosition)
        }
        return shaderModule.construct(
            span: SourceSpan(startOfElementPosition, currentPosition),
            ArrayTypeExpression(maybeElementType: maybeElementType, maybeElementCount: maybeElementCount)
        )
    }

    mutating func parseVariable() throws(CompilationMessage) -> VariableID {
        try parseVariableWithAttributes([])
    }

    mutating func parseVariableWithAttributes(_ attributes: [AttributeID]) throws(CompilationMessage) -> VariableID {
        func flavor(_ token: Token) -> VariableFlavor {
            switch token.type {
            case .keywordConst:
                return .const
            case .keywordLet:
                return .let
            case .keywordOverride:
                return .override
            default: // lint-exempt(L-ENUM-1): every other token type, as the C++ default (consumeTypes admits only var here)
                assert(token.type == .keywordVar)
                return .var
            }
        }

        let startOfElementPosition = currentPosition

        let varKind = try consumeTypes([.keywordConst, .keywordOverride, .keywordLet, .keywordVar], startOfElementPosition)

        let varFlavor = flavor(varKind)

        var maybeQualifier: VariableQualifier?
        if current.type == .templateArgsLeft {
            let variableQualifier = try parseVariableQualifier()
            maybeQualifier = variableQualifier
        }

        let name = try parseIdentifier()

        var maybeType: ExpressionID?
        if current.type == .colon {
            consume()
            let typeName = try parseTypeName()
            maybeType = typeName
        }

        var maybeInitializer: ExpressionID?
        if varFlavor == .const || varFlavor == .let || current.type == .equal {
            try consumeType(.equal, startOfElementPosition)
            let initializerExpr = try parseExpression()
            maybeInitializer = initializerExpr
        }

        if maybeType == nil && maybeInitializer == nil {
            let flavor: StaticString
            switch varFlavor {
            case .const:
                wgslFatal("a const declaration always parses an initializer", cppSite: "Parser.cpp:1055")
            case .let:
                wgslFatal("a let declaration always parses an initializer", cppSite: "Parser.cpp:1057")
            case .override:
                flavor = "override"
            case .var:
                flavor = "var"
            }
            throw fail("\(flavor) declaration requires a type or initializer", startOfElementPosition)
        }

        return shaderModule.constructVariable(
            span: SourceSpan(startOfElementPosition, currentPosition),
            flavor: varFlavor,
            name: name,
            qualifier: maybeQualifier,
            type: maybeType,
            initializer: maybeInitializer,
            attributes: shaderModule.makeList(attributes)
        )
    }

    mutating func parseVariableQualifier() throws(CompilationMessage) -> VariableQualifier {
        let startOfElementPosition = currentPosition

        try consumeType(.templateArgsLeft, startOfElementPosition)
        let addressSpace = try parseAddressSpace()

        var accessMode = defaultAccessModeForAddressSpace(addressSpace)
        var hasExplicitAccessMode = false
        if current.type == .comma {
            consume()

            if current.type == .identifier {
                if addressSpace != .storage {
                    throw fail("only variables in the <storage> address space may specify an access mode", startOfElementPosition)
                }

                let actualAccessMode = try parseAccessMode()
                accessMode = actualAccessMode
                hasExplicitAccessMode = true

                if current.type == .comma {
                    consume()
                }
            }
        }

        try consumeType(.templateArgsRight, startOfElementPosition)
        return VariableQualifier(
            span: SourceSpan(startOfElementPosition, currentPosition),
            addressSpace: addressSpace,
            accessMode: accessMode,
            hasExplicitAccessMode: hasExplicitAccessMode
        )
    }

    mutating func parseAddressSpace() throws(CompilationMessage) -> AddressSpace {
        let startOfElementPosition = currentPosition

        let identifier = try consumeType(.identifier, startOfElementPosition)
        if let addressSpace = WGSL.parseAddressSpace(codeUnits(of: identifier)), addressSpace != .handle {
            return addressSpace
        }

        throw fail("Expected one of 'function'/'private'/'storage'/'uniform'/'workgroup'", startOfElementPosition)
    }

    mutating func parseAccessMode() throws(CompilationMessage) -> AccessMode {
        let startOfElementPosition = currentPosition

        let identifier = try consumeType(.identifier, startOfElementPosition)
        if let accessMode = WGSL.parseAccessMode(codeUnits(of: identifier)) {
            return accessMode
        }

        throw fail("Expected one of 'read'/'write'/'read_write'", startOfElementPosition)
    }

    mutating func parseTypeAlias() throws(CompilationMessage) -> TypeAliasID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordAlias, startOfElementPosition)
        let name = try parseIdentifier()

        try consumeType(.equal, startOfElementPosition)

        let type = try parseTypeName()

        try consumeType(.semicolon, startOfElementPosition)

        return shaderModule.constructTypeAlias(span: SourceSpan(startOfElementPosition, currentPosition), name: name, type: type)
    }

    mutating func parseFunction(_ attributes: [AttributeID]) throws(CompilationMessage) -> FunctionID {
        let startOfElementPosition = currentPosition

        try consumeType(.keywordFn, startOfElementPosition)
        let name = try parseIdentifier()

        try consumeType(.parenLeft, startOfElementPosition)
        var parameters: [ParameterID] = []
        while current.type != .parenRight {
            let parameter = try parseParameter()
            parameters.append(parameter)

            // https://www.w3.org/TR/WGSL/#limits
            let maximumNumberOfFunctionParameters = 255
            if parameters.count > maximumNumberOfFunctionParameters {
                throw fail("function cannot have more than \(maximumNumberOfFunctionParameters) parameters", startOfElementPosition)
            }

            guard current.type == .comma else {
                break
            }
            consume()
        }
        try consumeType(.parenRight, startOfElementPosition)

        var returnAttributes: [AttributeID] = []
        var maybeReturnType: ExpressionID?
        if current.type == .arrow {
            consume()
            let parsedReturnAttributes = try parseAttributes()
            returnAttributes = parsedReturnAttributes
            let type = try parseTypeName()
            maybeReturnType = type
        }

        let body = try parseCompoundStatement()

        return shaderModule.constructFunction(
            span: SourceSpan(startOfElementPosition, currentPosition),
            name: name,
            parameters: shaderModule.makeList(parameters),
            returnType: maybeReturnType,
            body: body,
            attributes: shaderModule.makeList(attributes),
            returnAttributes: shaderModule.makeList(returnAttributes)
        )
    }

    mutating func parseParameter() throws(CompilationMessage) -> ParameterID {
        let startOfElementPosition = currentPosition

        let attributes = try parseAttributes()
        let name = try parseIdentifier()
        try consumeType(.colon, startOfElementPosition)
        let type = try parseTypeName()

        return shaderModule.constructParameter(
            span: SourceSpan(startOfElementPosition, currentPosition),
            name: name,
            typeName: type,
            attributes: shaderModule.makeList(attributes),
            role: .userDefined
        )
    }
}
