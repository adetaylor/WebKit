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

private struct AttributeValidator: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    private var currentFunction: FunctionID?
    private var hasSizeOrAlignmentAttributes = false
    // The LoopStatement whose Continuing the default traversal visits next: C++ passes the Continuing by reference.
    private var currentLoop: StatementID?

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func validate() -> FailedCheck? {
        visitShaderModule()

        guard hasError else {
            return nil
        }
        guard let error = result() else {
            wgslFatal("an AttributeValidator error without a message", cppSite: "AttributeValidator.cpp:94")
        }
        return FailedCheck(errors: [error], warnings: [])
    }

    mutating func visit(_ diagnosticDirective: DiagnosticDirective, _ id: DirectiveID) {
        let diagnostic = diagnosticDirective.diagnostic
        if let severity = shaderModule.severityFor(diagnostic.triggeringRule) {
            if severity != diagnostic.severity {
                error(shaderModule[id].span, "conflicting diagnostic directive")
                return
            }
        }

        shaderModule.setSeverityFor(diagnostic.triggeringRule, diagnostic.severity)
    }

    mutating func visit(_ function: FunctionID) {
        do {
            var node = shaderModule[function]
            defer { shaderModule.modify(function) { $0 = node } }

            var attributes = shaderModule.cursor(node.attributes)
            while let attribute = shaderModule.next(&attributes) {
                if case .mustUseAttribute = shaderModule[attribute].kind {
                    guard node.maybeReturnType != nil else {
                        error(shaderModule.span(of: attribute), "@must_use can only be applied to functions that return a value")
                        return
                    }
                    set(shaderModule.span(of: attribute), &node.mustUse)
                    continue
                }

                if case .stageAttribute(let stageAttribute) = shaderModule[attribute].kind {
                    update(shaderModule.span(of: attribute), &node.stage, stageAttribute.stage)
                    continue
                }

                if case .workgroupSizeAttribute(let workgroupSizeAttribute) = shaderModule[attribute].kind {
                    let workgroupSize = workgroupSizeAttribute.workgroupSize
                    func check(_ dimension: ExpressionID?) {
                        guard let dimension else {
                            return
                        }
                        guard let value = shaderModule.constantValue(of: dimension) else {
                            return
                        }
                        if value.integerValue() < 1 {
                            error(shaderModule.span(of: dimension), "@workgroup_size argument must be at least 1")
                            return
                        }
                    }
                    check(workgroupSize.x)
                    if hasError {
                        return
                    }

                    check(workgroupSize.y)
                    if hasError {
                        return
                    }

                    check(workgroupSize.z)
                    if hasError {
                        return
                    }

                    update(shaderModule.span(of: attribute), &node.workgroupSize, workgroupSize)
                    continue
                }

                if parseDiagnostic(&node.diagnostics, attribute) {
                    continue
                }

                error(shaderModule.span(of: attribute), "invalid attribute for function declaration")
                return
            }

            if node.workgroupSize != nil && (node.stage == nil || node.stage != .compute) {
                error(node.span, "@workgroup_size must only be applied to compute shader entry point function")
                return
            }

            var returnAttributes = shaderModule.cursor(node.returnAttributes)
            while let attribute = shaderModule.next(&returnAttributes) {
                if hasError {
                    return
                }

                if parseBuiltin(node, &node.returnTypeBuiltin, attribute) {
                    continue
                }

                if parseInterpolate(&node.returnTypeInterpolation, attribute) {
                    continue
                }

                if parseInvariant(&node.returnTypeInvariant, attribute) {
                    continue
                }

                guard let returnType = node.maybeReturnType else {
                    wgslFatal("a return type attribute on a function without a return type", cppSite: "AttributeValidator.cpp:181")
                }
                if parseLocation(node, &node.returnTypeLocation, attribute, shaderModule.inferredType(of: returnType)) {
                    continue
                }

                error(shaderModule.span(of: attribute), "invalid attribute for function return type")
                return
            }

            if let returnType = node.maybeReturnType {
                validateInterpolation(shaderModule.span(of: returnType), node.returnTypeInterpolation, node.returnTypeLocation)
                if hasError {
                    return
                }

                validateInvariant(shaderModule.span(of: returnType), node.returnTypeBuiltin, node.returnTypeInvariant)
                if hasError {
                    return
                }
            }
        }

        currentFunction = function
        visitChildren(function)
        currentFunction = nil
    }

    mutating func visit(_ parameter: ParameterID) {
        do {
            var node = shaderModule[parameter]
            defer { shaderModule.modify(parameter) { $0 = node } }
            let function = currentFunction.map { shaderModule[$0] }

            var attributes = shaderModule.cursor(node.attributes)
            while let attribute = shaderModule.next(&attributes) {
                if hasError {
                    return
                }

                if parseBuiltin(function, &node.builtin, attribute) {
                    continue
                }

                if parseInterpolate(&node.interpolation, attribute) {
                    continue
                }

                if parseInvariant(&node.invariant, attribute) {
                    continue
                }

                if parseLocation(function, &node.location, attribute, shaderModule.inferredType(of: node.typeName)) {
                    continue
                }

                error(shaderModule.span(of: attribute), "invalid attribute for function parameter")
                return
            }

            validateInterpolation(node.span, node.interpolation, node.location)
            if hasError {
                return
            }

            validateInvariant(node.span, node.builtin, node.invariant)
            if hasError {
                return
            }
        }

        visitChildren(parameter)
    }

    mutating func visit(_ variable: VariableID) {
        var node = shaderModule[variable]
        defer { shaderModule.modify(variable) { $0 = node } }

        let isResource: Bool = {
            guard let addressSpace = node.addressSpace else {
                return false
            }
            switch addressSpace {
            case .handle, .storage, .uniform:
                return true
            case .function, .private, .workgroup:
                return false
            }
        }()

        var attributes = shaderModule.cursor(node.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if case .bindingAttribute(let bindingAttribute) = shaderModule[attribute].kind {
                if !isResource {
                    error(shaderModule.span(of: attribute), "@binding attribute must only be applied to resource variables")
                    return
                }

                // https://gpuweb.github.io/cts/standalone/?q=webgpu:shader,validation,parse,attribute:expressions:value=%22override%22;attribute=%22binding%22
                guard let constantValue = shaderModule.constantValue(of: bindingAttribute.binding) else {
                    error(shaderModule.span(of: attribute), "@binding attribute must only be applied to resource variables")
                    return
                }

                let bindingValue = constantValue.integerValue()
                if bindingValue < 0 {
                    error(shaderModule.span(of: attribute), "@binding value must be non-negative")
                    return
                }

                update(shaderModule.span(of: attribute), &node.binding, UInt32(truncatingIfNeeded: bindingValue))
                continue
            }

            if case .groupAttribute(let groupAttribute) = shaderModule[attribute].kind {
                if !isResource {
                    error(shaderModule.span(of: attribute), "@group attribute must only be applied to resource variables")
                    return
                }

                // https://gpuweb.github.io/cts/standalone/?q=webgpu:shader,validation,parse,attribute:expressions:value=%22override%22;attribute=%22binding%22
                guard let constantValue = shaderModule.constantValue(of: groupAttribute.group) else {
                    error(shaderModule.span(of: attribute), "@group attribute must only be applied to resource variables")
                    return
                }

                let groupValue = constantValue.integerValue()
                if groupValue < 0 {
                    error(shaderModule.span(of: attribute), "@group value must be non-negative")
                    return
                }

                update(shaderModule.span(of: attribute), &node.group, UInt32(truncatingIfNeeded: groupValue))
                continue
            }

            if case .idAttribute(let idAttribute) = shaderModule[attribute].kind {
                let idExpression = idAttribute.value
                if node.flavor != .override {
                    error(shaderModule.span(of: attribute), "@id attribute must only be applied to override variables")
                    return
                }

                guard satisfies(node.storeType, .scalar, shaderModule.types) else {
                    wgslFatal("@id on an override whose type is not a scalar", cppSite: "AttributeValidator.cpp:308")
                }

                // https://gpuweb.github.io/cts/standalone/?q=webgpu:shader,validation,parse,attribute:expressions:value=%22override%22;attribute=%22binding%22
                guard let constantValue = shaderModule.constantValue(of: idExpression) else {
                    wgslFatal("@id value without a constant value", cppSite: "AttributeValidator.cpp:312")
                }

                let idValue = constantValue.integerValue()
                if idValue < 0 {
                    error(shaderModule.span(of: attribute), "@id value must be non-negative")
                    return
                }

                if idValue > Int64(UInt16.max) {
                    error(shaderModule.span(of: attribute), "@id value must be between 0 and 65535")
                    return
                }

                let uintIdValue = UInt32(truncatingIfNeeded: idValue)
                if shaderModule.containsOverrideID(uintIdValue) {
                    error(shaderModule.span(of: attribute), "@id value must be unique")
                    return
                }

                update(shaderModule.span(of: attribute), &node.id, uintIdValue)
                shaderModule.addOverrideID(uintIdValue)
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for variable declaration")
            return
        }

        if isResource && (node.group == nil || node.binding == nil) {
            error(node.span, "resource variables require @group and @binding attributes")
            return
        }

        if isResource, let addressSpace = node.addressSpace {
            validateAlignment(node.span, addressSpace, node.storeType)
        }
    }

    private mutating func validateAlignment(_ span: SourceSpan, _ addressSpace: AddressSpace, _ type: TypeID?) {
        func requiredAlignment(_ type: TypeID) -> UInt32 {
            var alignment = ShaderModule.alignment(of: type, in: &shaderModule)
            if addressSpace == .uniform
                && (shaderModule.types.getIf(Types.Array.self, type) != nil || shaderModule.types.getIf(Types.Struct.self, type) != nil)
            {
                alignment = wtfRoundUpToMultipleOf(16, alignment)
            }
            return alignment
        }

        // DEV-03: a loop with an explicit stack of the structures whose members are being validated, where the C++ recurses.
        // DEV-04: a structure validated without an error is not validated again, where the C++ revisits it for every path.
        var frames: [AlignmentFrame] = []
        var validatedStructures = IDSet<StructureID>()
        var span = span
        var type = type
        descend: while true {
            if let arrayType = shaderModule.types.getIf(Types.Array.self, type) {
                let stride = ShaderModule.stride(of: arrayType, in: &shaderModule).bytes
                if stride % requiredAlignment(arrayType.element) != 0 {
                    error(
                        span,
                        "array must have a stride multiple of \(requiredAlignment(arrayType.element)) bytes, but has a stride of \(stride) bytes"
                    )
                    return
                }

                if addressSpace == .uniform && stride % 16 != 0 {
                    error(
                        span,
                        "arrays in the uniform address space must have a stride multiple of 16 bytes, but has a stride of \(stride) bytes"
                    )
                    return
                }

                type = arrayType.element
                continue descend
            }

            if let structType = shaderModule.types.getIf(Types.Struct.self, type), !validatedStructures.contains(structType.structure) {
                let members = shaderModule[structType.structure].members
                let memberCount = shaderModule.count(members)
                if memberCount > 0 {
                    let member = shaderModule[shaderModule[members, 0]]
                    frames.append(AlignmentFrame(structure: structType.structure, memberCount: memberCount, index: 0))
                    span = member.span
                    type = shaderModule.inferredType(of: member.type)
                    continue descend
                }
            }

            // The innermost call returned; every enclosing call checks `hasError()` after its recursive call.
            while !hasError {
                guard var frame = frames.popLast() else {
                    return
                }
                let structure = shaderModule[frame.structure]
                let i = frame.index
                let member = shaderModule[shaderModule[structure.members, i]]
                guard let memberType = shaderModule.inferredType(of: member.type) else {
                    wgslFatal("a structure member without a type", cppSite: "AttributeValidator.cpp:379")
                }

                if member.offset % requiredAlignment(memberType) != 0 {
                    error(
                        member.span,
                        "offset of struct member \(name(structure.name))::\(name(member.name)) must be a multiple of \(requiredAlignment(memberType)) bytes, but its offset is \(member.offset) bytes"
                    )
                    return
                }

                if addressSpace == .uniform && shaderModule.types.getIf(Types.Struct.self, memberType) != nil
                    && (i &+ 1) < frame.memberCount
                {
                    let nextMember = shaderModule[shaderModule[structure.members, i &+ 1]]
                    let spaceBetweenMembers = nextMember.offset &- member.offset
                    let minimumNumberOfBytes = wtfRoundUpToMultipleOf(16, ShaderModule.size(of: memberType, in: &shaderModule).bytes)
                    if spaceBetweenMembers < minimumNumberOfBytes {
                        error(
                            member.span,
                            "uniform address space requires that the number of bytes between \(name(structure.name))::\(name(member.name)) and \(name(structure.name))::\(name(nextMember.name)) must be at least \(minimumNumberOfBytes) bytes, but it is \(spaceBetweenMembers) bytes"
                        )
                        return
                    }
                }

                frame.index = i &+ 1
                if frame.index < frame.memberCount {
                    let nextMember = shaderModule[shaderModule[structure.members, frame.index]]
                    frames.append(frame)
                    span = nextMember.span
                    type = shaderModule.inferredType(of: nextMember.type)
                    continue descend
                }
                validatedStructures.add(frame.structure)
            }
            return
        }
    }

    mutating func visit(_ structure: StructureID) {
        visitChildren(structure)

        let structureHasSizeOrAlignmentAttributes = hasSizeOrAlignmentAttributes
        hasSizeOrAlignmentAttributes = false
        shaderModule.modify(structure) { $0.hasSizeOrAlignmentAttributes = structureHasSizeOrAlignmentAttributes }

        var layout = StructureLayout()
        var previousMember: StructureMemberID?
        var members = shaderModule.cursor(shaderModule[structure].members)
        while !members.isAtEnd {
            let member = shaderModule.advance(&members)
            let node = shaderModule[member]
            guard let type = shaderModule.inferredType(of: node.type) else {
                wgslFatal("a structure member without a type", cppSite: "AttributeValidator.cpp:415")
            }
            let fieldAlignment: UInt32
            if let alignment = node.alignment {
                fieldAlignment = alignment
            } else {
                fieldAlignment = ShaderModule.alignment(of: type, in: &shaderModule)
            }

            let typeSize = ShaderModule.size(of: type, in: &shaderModule)
            let fieldSize: UInt32
            if let size = node.size {
                fieldSize = size
            } else {
                fieldSize = typeSize.bytes
            }

            let placement = layout.addMember(
                typeSize: typeSize,
                fieldSize: ByteSize(bytes: fieldSize),
                fieldAlignment: ByteAlignment(fieldAlignment)
            )

            // The member's alignment and size (unchanged where it had them) and offset, in one access.
            shaderModule.modify(member) {
                $0.alignment = fieldAlignment
                $0.size = fieldSize
                $0.offset = placement.offset
            }

            if let previousMember, let padding = placement.previousMemberPadding {
                shaderModule.modify(previousMember) { $0.padding = padding }
            }

            previousMember = member
        }
        let finished = layout.finish()
        guard let previousMember, let lastMemberPadding = finished.lastMemberPadding else {
            wgslFatal("a structure without members", cppSite: "AttributeValidator.cpp:473")
        }
        shaderModule.modify(previousMember) { $0.padding = lastMemberPadding }
        shaderModule.modify(structure) {
            $0.alignment = finished.alignment
            $0.size = finished.size.bytes
        }
    }

    mutating func visit(_ member: StructureMemberID) {
        do {
            var node = shaderModule[member]
            // Only an attribute changes the node: without one, it is not written back.
            let hasAttributes = shaderModule.count(node.attributes) != 0
            defer {
                if hasAttributes {
                    shaderModule.modify(member) { $0 = node }
                }
            }

            var attributes = shaderModule.cursor(node.attributes)
            while let attribute = shaderModule.next(&attributes) {
                if hasError {
                    return
                }

                if parseBuiltin(nil, &node.builtin, attribute) {
                    continue
                }

                if parseInterpolate(&node.interpolation, attribute) {
                    continue
                }

                if parseInvariant(&node.invariant, attribute) {
                    continue
                }

                if parseLocation(nil, &node.location, attribute, shaderModule.inferredType(of: node.type)) {
                    continue
                }

                if case .sizeAttribute(let sizeAttribute) = shaderModule[attribute].kind {
                    hasSizeOrAlignmentAttributes = true

                    guard let type = shaderModule.inferredType(of: node.type) else {
                        wgslFatal("a structure member without a type", cppSite: "AttributeValidator.cpp:499")
                    }
                    if !shaderModule.hasCreationFixedFootprint(type) {
                        error(
                            shaderModule.span(of: attribute),
                            "@size can only be applied to members that have a type with a size that is fully determined at shader creation time."
                        )
                        return
                    }

                    // https://gpuweb.github.io/cts/standalone/?q=webgpu:shader,validation,parse,attribute:expressions:value=%22override%22;*
                    guard let constantValue = shaderModule.constantValue(of: sizeAttribute.size) else {
                        error(shaderModule.span(of: attribute), "@size constant value is not found")
                        return
                    }
                    let sizeValue = constantValue.integerValue()
                    if sizeValue < 0 {
                        error(shaderModule.span(of: attribute), "@size value must be non-negative")
                        return
                    }

                    if sizeValue < Int64(ShaderModule.size(of: type, in: &shaderModule).bytes) {
                        // We can't call Type::size() if we already have errors, as we might
                        // try to read the size of a struct, which we will not have computed
                        // if we already encountered errors
                        error(shaderModule.span(of: attribute), "@size value must be at least the byte-size of the type of the member")
                        return
                    }

                    update(shaderModule.span(of: attribute), &node.size, UInt32(truncatingIfNeeded: sizeValue))
                    continue
                }

                if case .alignAttribute(let alignAttribute) = shaderModule[attribute].kind {
                    hasSizeOrAlignmentAttributes = true
                    // https://gpuweb.github.io/cts/standalone/?q=webgpu:shader,validation,parse,attribute:expressions:value=%22override%22;attribute=%22align%22
                    guard let constantValue = shaderModule.constantValue(of: alignAttribute.alignment) else {
                        error(shaderModule.span(of: attribute), "@align constant value does not exist")
                        return
                    }

                    let alignmentValue = constantValue.integerValue()
                    if alignmentValue < 1 {
                        error(shaderModule.span(of: attribute), "@align value must be positive")
                        return
                    }

                    guard let alignment = UInt32(exactly: alignmentValue).flatMap(ByteAlignment.init(validating:)) else {
                        error(shaderModule.span(of: attribute), "@align value must be a power of two")
                        return
                    }

                    if let type = shaderModule.inferredType(of: node.type),
                        alignmentValue % Int64(ShaderModule.alignment(of: type, in: &shaderModule)) != 0
                    {
                        error(
                            shaderModule.span(of: attribute),
                            "@align attribute \(alignmentValue) of struct member is not a multiple of the type's alignment \(ShaderModule.alignment(of: type, in: &shaderModule))"
                        )
                        return
                    }

                    update(shaderModule.span(of: attribute), &node.alignment, alignment.bytes)
                    continue
                }

                error(shaderModule.span(of: attribute), "invalid attribute for structure member")
                return
            }

            validateInterpolation(node.span, node.interpolation, node.location)
            if hasError {
                return
            }

            validateInvariant(node.span, node.builtin, node.invariant)
            if hasError {
                return
            }
        }

        visitChildren(member)
    }

    mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        var attributes = shaderModule.cursor(statement.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.statement(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for compound statement")
            return
        }

        visitChildren(statement, id)
    }

    mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        var attributes = shaderModule.cursor(statement.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.statement(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `for` statement")
            return
        }

        visitChildren(statement, id)
    }

    mutating func visit(_ statement: WhileStatement, _ id: StatementID) {
        var attributes = shaderModule.cursor(statement.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.statement(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for compound statement")
            return
        }

        visitChildren(statement, id)
    }

    mutating func visit(_ statement: LoopStatement, _ id: StatementID) {
        var attributes = shaderModule.cursor(statement.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.statement(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `loop` statement")
            return
        }

        var bodyAttributes = shaderModule.cursor(statement.bodyAttributes)
        while let attribute = shaderModule.next(&bodyAttributes) {
            if parseDiagnostic(.loopBody(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `loop` body")
            return
        }

        let savedLoop = currentLoop
        currentLoop = id
        defer { currentLoop = savedLoop }
        visitChildren(statement, id)
    }

    mutating func visit(_ continuing: Continuing) {
        guard let loop = currentLoop else {
            wgslFatal("a Continuing visited outside its LoopStatement", cppSite: "AttributeValidator.cpp:633")
        }
        var attributes = shaderModule.cursor(continuing.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.continuing(loop), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `continuing` body")
            return
        }

        visitChildren(continuing)
    }

    mutating func visit(_ statement: SwitchStatement, _ id: StatementID) {
        var attributes = shaderModule.cursor(statement.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.statement(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `switch` statement")
            return
        }

        var bodyAttributes = shaderModule.cursor(statement.bodyAttributes)
        while let attribute = shaderModule.next(&bodyAttributes) {
            if parseDiagnostic(.switchBody(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `switch` body")
            return
        }

        visitChildren(statement, id)
    }

    mutating func visit(_ statement: IfStatement, _ id: StatementID) {
        var attributes = shaderModule.cursor(statement.attributes)
        while let attribute = shaderModule.next(&attributes) {
            if parseDiagnostic(.statement(id), attribute) {
                continue
            }

            error(shaderModule.span(of: attribute), "invalid attribute for `if` statement")
            return
        }

        visitChildren(statement, id)
    }

    private mutating func parseBuiltin(_ function: Function?, _ builtin: inout Builtin?, _ attribute: AttributeID) -> Bool {
        guard case .builtinAttribute(let builtinAttribute) = shaderModule[attribute].kind else {
            return false
        }

        if let function, function.stage == nil {
            error(shaderModule.span(of: attribute), "@builtin is not valid for non-entry point function types")
            return true
        }

        update(shaderModule.span(of: attribute), &builtin, builtinAttribute.builtin)
        return true
    }

    private mutating func parseInterpolate(_ interpolation: inout Interpolation?, _ attribute: AttributeID) -> Bool {
        guard case .interpolateAttribute(let interpolateAttribute) = shaderModule[attribute].kind else {
            return false
        }

        update(shaderModule.span(of: attribute), &interpolation, interpolateAttribute.interpolation)
        return true
    }

    private mutating func parseInvariant(_ invariant: inout Bool, _ attribute: AttributeID) -> Bool {
        guard case .invariantAttribute = shaderModule[attribute].kind else {
            return false
        }

        set(shaderModule.span(of: attribute), &invariant)
        return true
    }

    private mutating func parseLocation(
        _ function: Function?,
        _ location: inout UInt32?,
        _ attribute: AttributeID,
        _ declarationType: TypeID?
    ) -> Bool {
        guard case .locationAttribute(let locationAttribute) = shaderModule[attribute].kind else {
            return false
        }
        if let function, function.stage == nil {
            error(shaderModule.span(of: attribute), "@location is not valid for non-entry point function types")
            return true
        }

        if let function, function.stage == .compute {
            error(shaderModule.span(of: attribute), "@location may not be used in the compute shader stage")
            return true
        }

        let isNumeric = satisfies(declarationType, .number, shaderModule.types)
        var isNumericVector = false
        if !isNumeric {
            if let vectorType = shaderModule.types.getIf(Types.Vector.self, declarationType) {
                isNumericVector = satisfies(vectorType.element, .number, shaderModule.types)
            }
        }

        if !isNumeric && !isNumericVector {
            error(
                shaderModule.span(of: attribute),
                "@location must only be applied to declarations of numeric scalar or numeric vector type"
            )
            return true
        }

        // https://gpuweb.github.io/cts/standalone/?q=webgpu:shader,validation,parse,attribute:expressions:value=%22override%22;*
        guard let constantValue = shaderModule.constantValue(of: locationAttribute.location) else {
            error(shaderModule.span(of: attribute), "@location constant value is missing")
            return true
        }

        let locationValue = constantValue.integerValue()
        if locationValue < 0 {
            error(shaderModule.span(of: attribute), "@location value must be non-negative")
            return true
        }

        update(shaderModule.span(of: attribute), &location, UInt32(truncatingIfNeeded: locationValue))
        return true
    }

    private mutating func parseDiagnostic(_ statement: inout DiagnosticContainer, _ attribute: AttributeID) -> Bool {
        guard case .diagnosticAttribute(let diagnosticAttribute) = shaderModule[attribute].kind else {
            return false
        }

        let diagnostic = diagnosticAttribute.diagnostic
        if statement.severityFor(diagnostic.triggeringRule) != nil {
            error(shaderModule.span(of: attribute), "duplicate @diagnostic attribute")
            return true
        }

        statement.setSeverityFor(diagnostic.triggeringRule, diagnostic.severity)
        return true
    }

    private mutating func validateInterpolation(_ span: SourceSpan, _ interpolation: Interpolation?, _ location: UInt32?) {
        if interpolation != nil && location == nil {
            error(span, "@interpolate is only allowed on declarations that have a @location attribute")
        }
        guard let interpolation else {
            return
        }
        let type = interpolation.type
        let sampling = interpolation.sampling

        if type == .flat {
            if sampling != .first && sampling != .either {
                error(span, "flat interpolation attribute must have a sampling parameter of `first` or `either`")
            }
        } else {
            if sampling != .center && sampling != .centroid && sampling != .sample {
                error(span, "\(toString(type)) interpolation attribute must have a sampling parameter of `center`, `centroid` or `sample`")
            }
        }
    }

    private mutating func validateInvariant(_ span: SourceSpan, _ builtin: Builtin?, _ invariant: Bool) {
        if invariant && (builtin == nil || builtin != .position) {
            error(span, "@invariant is only allowed on declarations that have a @builtin(position) attribute")
        }
    }

    private mutating func update<T>(_ span: SourceSpan, _ destination: inout T?, _ source: T) {
        if destination != nil {
            error(span, "duplicate attribute")
            return
        }

        destination = source
    }

    private mutating func set(_ span: SourceSpan, _ destination: inout Bool) {
        if destination {
            error(span, "duplicate attribute")
            return
        }

        destination = true
    }

    private mutating func error(_ span: SourceSpan, _ message: MessageText) {
        setError(CompilationMessage(text: message, span: span))
    }

    // MARK: - Swift-only helpers

    /// `parseDiagnostic` on a `DiagnosticContainer` that a statement holds in the module.
    private mutating func parseDiagnostic(_ slot: DiagnosticContainerSlot, _ attribute: AttributeID) -> Bool {
        var diagnostics: DiagnosticContainer
        switch slot {
        case .statement(let statement):
            diagnostics = shaderModule[statement].diagnostics
        case .loopBody(let loop):
            diagnostics = shaderModule.downcast(LoopStatement.self, loop).bodyDiagnostics
        case .switchBody(let statement):
            diagnostics = shaderModule.downcast(SwitchStatement.self, statement).bodyDiagnostics
        case .continuing(let loop):
            guard let continuing = shaderModule.downcast(LoopStatement.self, loop).continuing else {
                wgslFatal("a Continuing attribute of a LoopStatement without a Continuing", cppSite: "AttributeValidator.cpp:636")
            }
            diagnostics = continuing.diagnostics
        }

        guard parseDiagnostic(&diagnostics, attribute) else {
            return false
        }

        switch slot {
        case .statement(let statement):
            shaderModule.modify(statement) { $0.diagnostics = diagnostics }
        case .loopBody(let loop):
            shaderModule.modify(LoopStatement.self, loop) { $0.bodyDiagnostics = diagnostics }
        case .switchBody(let statement):
            shaderModule.modify(SwitchStatement.self, statement) { $0.bodyDiagnostics = diagnostics }
        case .continuing(let loop):
            shaderModule.modify(LoopStatement.self, loop) { $0.continuing?.diagnostics = diagnostics }
        }
        return true
    }

    private mutating func name(_ identifier: IdentifierID) -> MessageText {
        shaderModule.symbols.text(of: shaderModule.symbol(of: identifier))
    }
}

/// A C++ `AST::DiagnosticContainer&` that a statement hook passes to `parseDiagnostic`.
private enum DiagnosticContainerSlot {
    case statement(StatementID)
    case loopBody(StatementID)
    case switchBody(StatementID)
    case continuing(StatementID)
}

/// A C++ `validateAlignment` call on a structure type, suspended in the member loop at `index`.
private struct AlignmentFrame {
    let structure: StructureID
    let memberCount: Int
    var index: Int
}

@_spi(Testing)
public func validateAttributes(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    var validator = AttributeValidator(shaderModule: shaderModule)
    let result = validator.validate()
    shaderModule = validator.shaderModule
    return result
}
