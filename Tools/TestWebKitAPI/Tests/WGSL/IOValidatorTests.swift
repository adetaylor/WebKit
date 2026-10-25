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

import Testing
@_spi(Testing) import WGSL

// Unless a test says otherwise, each expected message and span is what a release build of the C++ compiler reported for
// the same source.

// MARK: - Modules

/// Stands in for TypeCheck and AttributeValidator, which run before the validators: sets the stages, IO attributes,
/// bindings, store types, address spaces, inferred types, resolved targets and visibilities they read.
private struct Annotator: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    private var structTypes: [String: TypeID] = [:]

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ structure: StructureID) {
        structTypes[text(shaderModule[structure].name)] = shaderModule.types.structType(structure)
        for member in shaderModule.elements(shaderModule[structure].members) {
            let node = shaderModule[member]
            let attributes = attributeValues(node.attributes)
            shaderModule.modify(member) { member in
                member.builtin = attributes.builtin
                member.location = attributes.location
                member.interpolation = attributes.interpolation
            }
            shaderModule.setInferredType(resolve(node.type), for: node.type)
        }
    }

    mutating func visit(_ function: FunctionID) {
        let node = shaderModule[function]
        let attributes = attributeValues(node.attributes)
        let returnAttributes = attributeValues(node.returnAttributes)
        shaderModule.modify(function) { function in
            function.stage = attributes.stage
            function.returnTypeBuiltin = returnAttributes.builtin
            function.returnTypeLocation = returnAttributes.location
            function.returnTypeInterpolation = returnAttributes.interpolation
        }
        if let returnType = node.maybeReturnType {
            shaderModule.setInferredType(resolve(returnType), for: returnType)
        }
        visitChildren(function)
    }

    mutating func visit(_ parameter: ParameterID) {
        let node = shaderModule[parameter]
        let attributes = attributeValues(node.attributes)
        shaderModule.modify(parameter) { parameter in
            parameter.builtin = attributes.builtin
            parameter.location = attributes.location
            parameter.interpolation = attributes.interpolation
        }
        shaderModule.setInferredType(resolve(node.typeName), for: node.typeName)
    }

    mutating func visit(_ variable: VariableID) {
        let node = shaderModule[variable]
        let attributes = attributeValues(node.attributes)
        let storeType = node.maybeTypeName.flatMap { resolve($0) }
        var addressSpace = node.maybeQualifier?.addressSpace
        var accessMode = node.maybeQualifier?.accessMode
        if addressSpace == nil, let storeType, isHandle(storeType) {
            addressSpace = .handle
            accessMode = .read
        }
        shaderModule.modify(variable) { variable in
            variable.group = attributes.group
            variable.binding = attributes.binding
            variable.storeType = storeType
            variable.addressSpace = addressSpace
            variable.accessMode = accessMode
        }
        visitChildren(variable)
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        visitChildren(call, id)
        guard case .identifierExpression(let target) = shaderModule[call.target].kind else {
            return
        }
        let symbol = shaderModule.symbol(of: target.identifier)
        let isFragmentOnly = fragmentOnlyBuiltins.contains(text(target.identifier))
        shaderModule.modify(CallExpression.self, id) { call in
            call.resolvedTarget = symbol
            if isFragmentOnly {
                call.visibility = [.fragment]
            }
        }
    }

    private struct AttributeValues {
        var stage: ShaderStage?
        var builtin: Builtin?
        var location: UInt32?
        var interpolation: Interpolation?
        var group: UInt32?
        var binding: UInt32?
    }

    private mutating func attributeValues(_ list: ListID<AttributeID>) -> AttributeValues {
        var values = AttributeValues()
        for attribute in shaderModule.elements(list) {
            switch shaderModule[attribute].kind {
            case .stageAttribute(let stage):
                values.stage = stage.stage
            case .builtinAttribute(let builtin):
                values.builtin = builtin.builtin
            case .locationAttribute(let location):
                values.location = literal(location.location)
            case .interpolateAttribute(let interpolate):
                values.interpolation = interpolate.interpolation
            case .groupAttribute(let group):
                values.group = literal(group.group)
            case .bindingAttribute(let binding):
                values.binding = literal(binding.binding)
            default:
                break
            }
        }
        return values
    }

    private mutating func literal(_ expression: ExpressionID) -> UInt32? {
        switch shaderModule[expression].kind {
        case .abstractIntegerLiteral(let literal):
            UInt32(truncatingIfNeeded: literal.value)
        case .unsigned32Literal(let literal):
            literal.value
        case .signed32Literal(let literal):
            UInt32(bitPattern: literal.value)
        default:
            nil
        }
    }

    private mutating func resolve(_ expression: ExpressionID) -> TypeID? {
        switch shaderModule[expression].kind {
        case .identifierExpression(let identifier):
            return namedType(text(identifier.identifier))
        case .elaboratedTypeExpression(let elaborated):
            let arguments = shaderModule.elements(elaborated.arguments)
            switch text(elaborated.base) {
            case "vec2", "vec3", "vec4":
                guard let element = resolve(arguments[0]) else {
                    return nil
                }
                return shaderModule.types.vectorType(UInt8(text(elaborated.base).dropFirst(3)) ?? 0, element)
            case "texture_2d":
                guard let element = resolve(arguments[0]) else {
                    return nil
                }
                return shaderModule.types.textureType(.texture2d, element)
            case "texture_storage_2d":
                guard case .identifierExpression(let format) = shaderModule[arguments[0]].kind,
                    case .identifierExpression(let access) = shaderModule[arguments[1]].kind,
                    let texelFormat = TexelFormat.allCases.first(where: { "\(toString($0))" == text(format.identifier) }),
                    let accessMode = AccessMode.allCases.first(where: { "\(toString($0))" == text(access.identifier) })
                else {
                    return nil
                }
                return shaderModule.types.textureStorageType(.textureStorage2d, texelFormat, accessMode)
            default:
                return nil
            }
        case .arrayTypeExpression(let array):
            guard let elementType = array.maybeElementType, let element = resolve(elementType),
                let count = array.maybeElementCount.flatMap({ literal($0) })
            else {
                return nil
            }
            return shaderModule.types.arrayType(element, .creationFixed(count))
        default:
            return nil
        }
    }

    private mutating func namedType(_ name: String) -> TypeID? {
        switch name {
        case "bool": return shaderModule.types.boolType
        case "i32": return shaderModule.types.i32Type
        case "u32": return shaderModule.types.u32Type
        case "f32": return shaderModule.types.f32Type
        case "vec2f": return shaderModule.types.vectorType(2, shaderModule.types.f32Type)
        case "vec4f": return shaderModule.types.vectorType(4, shaderModule.types.f32Type)
        case "vec2i": return shaderModule.types.vectorType(2, shaderModule.types.i32Type)
        case "vec3u": return shaderModule.types.vectorType(3, shaderModule.types.u32Type)
        case "sampler": return shaderModule.types.samplerType
        case "sampler_comparison": return shaderModule.types.samplerComparisonType
        case "texture_external": return shaderModule.types.textureExternalType
        default: return structTypes[name]
        }
    }

    private mutating func isHandle(_ type: TypeID) -> Bool {
        switch shaderModule.types[type] {
        case .texture, .textureStorage, .textureDepth:
            return true
        case .primitive(let primitive):
            return primitive.kind == .sampler || primitive.kind == .samplerComparison || primitive.kind == .textureExternal
        default:
            return false
        }
    }

    private mutating func text(_ identifier: IdentifierID) -> String {
        String(decoding: shaderModule.symbols.codeUnits(of: shaderModule.symbol(of: identifier)), as: UTF16.self)
    }
}

private let fragmentOnlyBuiltins: Set<String> = ["dpdx", "dpdy", "textureSample"]

/// Parses `source`, annotates it as TypeCheck and AttributeValidator would, and builds the call graph.
private func annotatedModule(_ source: String) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure)
    }
    var annotator = Annotator(shaderModule: module)
    annotator.visitShaderModule()
    module = annotator.shaderModule
    buildCallGraph(&module)
    return module
}

private func ioError(_ source: String) -> CompilationMessage? {
    var module = annotatedModule(source)
    return validateIO(&module)?.errors.first
}

private func visibilityError(_ source: String) -> CompilationMessage? {
    var module = annotatedModule(source)
    return validateVisibility(&module)?.errors.first
}

private func message(_ text: String, _ line: UInt32, _ lineOffset: UInt32, _ offset: UInt32, _ length: UInt32) -> CompilationMessage {
    CompilationMessage(text, span: SourceSpan(line: line, lineOffset: lineOffset, offset: offset, length: length))
}

private func functionName(_ module: borrowing ShaderModule, _ function: FunctionID) -> String {
    String(decoding: module.symbols.codeUnits(of: module.symbol(of: module[function].name)), as: UTF16.self)
}

private func functionsByName(_ module: borrowing ShaderModule) -> [String: FunctionID] {
    var functions: [String: FunctionID] = [:]
    for declaration in module.elements(module.declarations) {
        if case .function(let function) = declaration {
            functions[functionName(module, function)] = function
        }
    }
    return functions
}

private func variablesByName(_ module: borrowing ShaderModule) -> [String: VariableID] {
    var variables: [String: VariableID] = [:]
    for declaration in module.elements(module.declarations) {
        if case .variable(let variable) = declaration {
            variables[String(decoding: module.symbols.codeUnits(of: module.symbol(of: module[variable].name)), as: UTF16.self)] = variable
        }
    }
    return variables
}

/// The declarations of the globals in an IDSet of the call graph.
private func declarations(_ module: borrowing ShaderModule, _ globals: IDSet<CallGraphGlobalID>) -> Set<VariableID> {
    var declarations = Set<VariableID>()
    globals.forEachInCreationOrder { declarations.insert(module.callGraph[$0].declaration) }
    return declarations
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }
}

private let stages: [ShaderStage] = [.compute, .vertex, .fragment]

private func entryPointHeader(_ name: String, _ stage: ShaderStage) -> String {
    switch stage {
    case .compute: "@compute @workgroup_size(1) fn \(name)() {"
    case .vertex: "@vertex fn \(name)() -> @builtin(position) vec4f {"
    case .fragment: "@fragment fn \(name)() {"
    }
}

private func entryPointFooter(_ stage: ShaderStage) -> String {
    stage == .vertex ? " return vec4f(); }" : " }"
}

/// `diamond22.wgsl`: each of `a<i>` and `b<i>` calls both `a<i+1>` and `b<i+1>`, so the C++
/// walks visit the leaves 2^`depth` times.
private func diamondSource(
    depth: Int,
    leafStatement: String = "",
    entryPoint: String = "@compute @workgroup_size(1) fn main() { a0(); }"
) -> String {
    var lines = ["fn a\(depth)() {\(leafStatement)} fn b\(depth)() {\(leafStatement)}"]
    var level = depth - 1
    while level >= 0 {
        lines.append("fn a\(level)() { a\(level + 1)(); b\(level + 1)(); } fn b\(level)() { a\(level + 1)(); b\(level + 1)(); }")
        level -= 1
    }
    lines.append(entryPoint)
    return lines.joined(separator: "\n")
}

/// `f0` calls `f1`, …, which calls `f<count - 1>`, whose body is `leafStatement`; `main` calls `f0`.
private func chainSource(count: Int, leafStatement: String, entryPoint: String) -> String {
    var lines: [String] = []
    lines.reserveCapacity(count + 2)
    var index = 0
    while index < count - 1 {
        lines.append("fn f\(index)() { f\(index + 1)(); }")
        index += 1
    }
    lines.append("fn f\(count - 1)() { \(leafStatement) }")
    lines.append(entryPoint)
    return lines.joined(separator: "\n")
}

/// The least CPU time per call edge (`4 * depth + 1`) of `validate` on the annotated `source(11)` and `source(22)`, each
/// validated in a fresh module (`leastCostsPerUnit`).
private func diamondCostsPerEdge(
    factor: Int,
    _ source: (_ depth: Int) -> String,
    _ validate: (inout ShaderModule) -> Void
) -> (small: Duration, large: Duration) {
    func cost(_ depth: Int) -> Duration {
        var module = annotatedModule(source(depth))
        return threadCPUTime { validate(&module) }
    }
    return leastCostsPerUnit(units: (small: 4 * 11 + 1, large: 4 * 22 + 1), factor: factor) {
        cost(11)
    } large: {
        cost(22)
    }
}

// MARK: - VisibilityValidator recursive transcription

/// What VisibilityValidator can report for one statement of a flat body.
private enum VisibilityStatement {
    case discard
    case derivative
    case visibleEverywhere
    case call(Int)
}

/// Helpers `h<i>` call only `h<j>` with `j > i`; entry points `e<k>` call helpers; declared in a shuffled order.
private struct VisibilityModel {
    var helpers: [[VisibilityStatement]] = []
    var entryPoints: [(stage: ShaderStage, body: [VisibilityStatement])] = []
    var order: [(isEntryPoint: Bool, index: Int)] = []

    init(_ random: inout SplitMix64) {
        let helperCount = 1 + random.below(8)
        for helper in 0..<helperCount {
            helpers.append(Self.body(&random, firstCallee: helper + 1, helperCount: helperCount))
        }
        for _ in 0..<(1 + random.below(3)) {
            entryPoints.append((stages[random.below(3)], Self.body(&random, firstCallee: 0, helperCount: helperCount)))
        }
        order = helpers.indices.map { (false, $0) } + entryPoints.indices.map { (true, $0) }
        var index = order.count - 1
        while index > 0 {
            order.swapAt(index, random.below(index + 1))
            index -= 1
        }
    }

    private static func body(_ random: inout SplitMix64, firstCallee: Int, helperCount: Int) -> [VisibilityStatement] {
        var body: [VisibilityStatement] = []
        for _ in 0..<random.below(5) {
            switch random.below(10) {
            case 0:
                body.append(.discard)
            case 1:
                body.append(.derivative)
            case 2:
                body.append(.visibleEverywhere)
            default:
                if firstCallee < helperCount {
                    body.append(.call(firstCallee + random.below(helperCount - firstCallee)))
                }
            }
        }
        return body
    }

    var source: String {
        var lines: [String] = []
        for (isEntryPoint, index) in order {
            if isEntryPoint {
                let entryPoint = entryPoints[index]
                lines.append(
                    entryPointHeader("e\(index)", entryPoint.stage) + Self.text(entryPoint.body) + entryPointFooter(entryPoint.stage)
                )
            } else {
                lines.append("fn h\(index)() {" + Self.text(helpers[index]) + " }")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func text(_ body: [VisibilityStatement]) -> String {
        var text = ""
        for statement in body {
            switch statement {
            case .discard: text += " discard;"
            case .derivative: text += " _ = dpdx(1.0);"
            case .visibleEverywhere: text += " _ = abs(1.0);"
            case .call(let callee): text += " h\(callee)();"
            }
        }
        return text
    }
}

/// C++ VisibilityValidator.cpp:60-91 as written: recursive, no memo, over the facts of a module with flat bodies.
private struct VisibilityTranscription {
    enum Event {
        case discard(SourceSpan)
        case call(ShaderStages, SourceSpan)
    }

    var events: [FunctionID: [Event]] = [:]
    var callees: [FunctionID: [FunctionID]] = [:]
    var entryPoints: [(FunctionID, ShaderStage)] = []
    private var stage = ShaderStage.vertex
    private var error: CompilationMessage?

    init(_ module: borrowing ShaderModule) {
        for entryPoint in module.callGraph.entrypoints {
            entryPoints.append((entryPoint.function, entryPoint.stage))
        }
        var pending = entryPoints.map(\.0)
        while let function = pending.popLast() {
            guard events[function] == nil else {
                continue
            }
            var functionEvents: [Event] = []
            guard case .compoundStatement(let body) = module[module[function].body].kind else {
                continue
            }
            for statement in module.elements(body.statements) {
                switch module[statement].kind {
                case .discardStatement:
                    functionEvents.append(.discard(module.span(of: statement)))
                case .phonyAssignmentStatement(let phony):
                    guard case .callExpression(let call) = module[phony.rhs].kind else {
                        continue
                    }
                    functionEvents.append(.call(call.visibility, module.span(of: phony.rhs)))
                default:
                    break
                }
            }
            events[function] = functionEvents
            let targets = module.callGraph.callees(function).map(\.target)
            callees[function] = targets
            pending.append(contentsOf: targets)
        }
    }

    mutating func run() -> CompilationMessage? {
        for (function, entryPointStage) in entryPoints {
            stage = entryPointStage
            visit(function)
        }
        return error
    }

    private mutating func visit(_ function: FunctionID) {
        for event in events[function] ?? [] where error == nil {
            switch event {
            case .discard(let span):
                if stage != .fragment {
                    error = CompilationMessage("discard statement cannot be used by \(toString(stage)) pipeline stage", span: span)
                }
            case .call(let visibility, let span):
                if !visibility.contains(ShaderStages(stage)) {
                    error = CompilationMessage("built-in cannot be used by \(toString(stage)) pipeline stage", span: span)
                }
            }
        }
        for callee in callees[function] ?? [] where error == nil {
            visit(callee)
        }
    }
}

// MARK: - IOValidator recursive transcription

private enum IOStatement {
    case read(Int)
    case readWorkgroup(Int)
    case dimensions(Int)
    case sample(texture: Int, sampler: Int)
    case call(Int)
}

/// A random module of globals, helpers and entry points.
///
/// Private globals `g<i>`, workgroup globals `w<i>`, textures `t<i>` (@group(0)), samplers `s<i>` (@group(1)), then
/// helpers `h<i>` calling only `h<j>` with `j > i`, then entry points `e<k>` calling helpers. Globals are numbered in
/// declaration order.
private struct IOModel {
    var privateCount = 0
    var workgroupCount = 0
    var textureCount = 0
    var samplerCount = 0
    var helpers: [[IOStatement]] = []
    var entryPoints: [(stage: ShaderStage, body: [IOStatement])] = []

    init(_ random: inout SplitMix64) {
        privateCount = random.below(4)
        workgroupCount = random.below(2)
        textureCount = random.below(3)
        samplerCount = random.below(3)
        let helperCount = 1 + random.below(9)
        for helper in 0..<helperCount {
            helpers.append(body(&random, firstCallee: helper + 1, helperCount: helperCount))
        }
        for _ in 0..<(1 + random.below(4)) {
            entryPoints.append((stages[random.below(3)], body(&random, firstCallee: 0, helperCount: helperCount)))
        }
    }

    private func body(_ random: inout SplitMix64, firstCallee: Int, helperCount: Int) -> [IOStatement] {
        var body: [IOStatement] = []
        for _ in 0..<random.below(5) {
            let kind = random.below(10)
            if kind == 0 && privateCount > 0 {
                body.append(.read(random.below(privateCount)))
            } else if kind == 3 && workgroupCount > 0 {
                body.append(.readWorkgroup(random.below(workgroupCount)))
            } else if kind == 1 && textureCount > 0 {
                body.append(.dimensions(random.below(textureCount)))
            } else if kind == 2 && textureCount > 0 && samplerCount > 0 {
                body.append(.sample(texture: random.below(textureCount), sampler: random.below(samplerCount)))
            } else if firstCallee < helperCount {
                body.append(.call(firstCallee + random.below(helperCount - firstCallee)))
            }
        }
        return body
    }

    var source: String {
        var lines: [String] = []
        for index in 0..<privateCount {
            lines.append("var<private> g\(index): u32;")
        }
        for index in 0..<workgroupCount {
            lines.append("var<workgroup> w\(index): u32;")
        }
        for index in 0..<textureCount {
            lines.append("@group(0) @binding(\(index)) var t\(index): texture_2d<f32>;")
        }
        for index in 0..<samplerCount {
            lines.append("@group(1) @binding(\(index)) var s\(index): sampler;")
        }
        for (index, body) in helpers.enumerated() {
            lines.append("fn h\(index)() {" + text(body) + " }")
        }
        for (index, entryPoint) in entryPoints.enumerated() {
            lines.append(entryPointHeader("e\(index)", entryPoint.stage) + text(entryPoint.body) + entryPointFooter(entryPoint.stage))
        }
        return lines.joined(separator: "\n")
    }

    private func text(_ body: [IOStatement]) -> String {
        var text = ""
        for statement in body {
            switch statement {
            case .read(let index): text += " _ = g\(index);"
            case .readWorkgroup(let index): text += " _ = w\(index);"
            case .dimensions(let index): text += " _ = textureDimensions(t\(index));"
            case .sample(let texture, let sampler): text += " _ = textureSample(t\(texture), s\(sampler), vec2f());"
            case .call(let callee): text += " h\(callee)();"
            }
        }
        return text
    }

    func workgroupGlobal(_ index: Int) -> Int { privateCount + index }
    func textureGlobal(_ index: Int) -> Int { privateCount + workgroupCount + index }
    func samplerGlobal(_ index: Int) -> Int { privateCount + workgroupCount + textureCount + index }

    /// Model functions: helpers, then entry points.
    func body(of function: Int) -> [IOStatement] {
        function < helpers.count ? helpers[function] : entryPoints[function - helpers.count].body
    }

    /// The call graph's callee order: first calls first, one record per target.
    func callees(of function: Int) -> [Int] {
        var callees: [Int] = []
        for statement in body(of: function) {
            if case .call(let callee) = statement, !callees.contains(callee) {
                callees.append(callee)
            }
        }
        return callees
    }
}

private struct IORecord: Equatable {
    var globals = Set<Int>()
    var pairs: [CallGraph.TextureSamplerPair] = []
}

/// A record of the call graph with its globals numbered in declaration order.
private func ioRecord(
    _ module: borrowing ShaderModule,
    _ globals: [VariableID: Int],
    _ globalSet: IDSet<CallGraphGlobalID>,
    _ pairs: [CallGraph.TextureSamplerPair]
) -> IORecord {
    var record = IORecord(pairs: pairs)
    globalSet.forEachInCreationOrder { global in
        record.globals.insert(globals[module.callGraph[global].declaration] ?? -1)
    }
    return record
}

/// The error IOValidator reports for a `_ = w<i>;` statement of `function` under `stage`.
private func workgroupError(
    _ module: borrowing ShaderModule,
    _ function: FunctionID,
    _ statement: Int,
    _ stage: ShaderStage
) -> CompilationMessage? {
    guard case .compoundStatement(let body) = module[module[function].body].kind,
        case .phonyAssignmentStatement(let phony) = module[module[body.statements, statement]].kind
    else {
        return nil
    }
    return CompilationMessage(
        "var with `workgroup` address space cannot be used by `\(toString(stage))` pipeline stage",
        span: module.span(of: phony.rhs)
    )
}

private struct IOEdge: Hashable {
    let caller: Int
    let calleeIndex: Int
}

/// C++ IOValidator.cpp:91-156 and the body effects of the model's statements, as written: recursive, per edge, no memo.
private struct IOTranscription {
    let model: IOModel
    var records: [IOEdge: IORecord] = [:]
    var entryPointRecords: [IORecord] = []
    /// The statement whose identifier reports the error, and the stage it reports.
    var error: (function: Int, statement: Int, stage: ShaderStage)?
    private var stage = ShaderStage.vertex
    private var usedGlobals = Set<Int>()
    private var textureSamplerPairs: [CallGraph.TextureSamplerPair] = []

    init(_ model: IOModel) {
        self.model = model
    }

    mutating func run() {
        for index in model.entryPoints.indices {
            stage = model.entryPoints[index].stage
            visit(model.helpers.count + index)
            guard error == nil else {
                return
            }
            entryPointRecords.append(IORecord(globals: usedGlobals, pairs: textureSamplerPairs))
            usedGlobals = []
            textureSamplerPairs = []
        }
    }

    private mutating func visit(_ function: Int) {
        var localGlobals = Set<Int>()
        var localPairs: [CallGraph.TextureSamplerPair] = []
        for (calleeIndex, callee) in model.callees(of: function).enumerated() {
            let edge = IOEdge(caller: function, calleeIndex: calleeIndex)
            if let record = records[edge], !record.globals.isEmpty {
                localGlobals.formUnion(record.globals)
                for pair in record.pairs {
                    localPairs.appendIfNotContains(pair)
                }
                continue
            }
            visit(callee)
            var record = records[edge] ?? IORecord()
            record.globals.formUnion(usedGlobals)
            record.pairs = textureSamplerPairs
            records[edge] = record
            localGlobals.formUnion(usedGlobals)
            for pair in textureSamplerPairs {
                localPairs.appendIfNotContains(pair)
            }
            usedGlobals = []
            textureSamplerPairs = []
        }
        usedGlobals.formUnion(localGlobals)
        for pair in localPairs {
            textureSamplerPairs.appendIfNotContains(pair)
        }
        for (statementIndex, statement) in model.body(of: function).enumerated() where error == nil {
            switch statement {
            case .read(let index):
                usedGlobals.insert(index)
            case .readWorkgroup(let workgroup):
                if stage != .compute {
                    error = (function, statementIndex, stage)
                } else {
                    usedGlobals.insert(model.workgroupGlobal(workgroup))
                }
            case .dimensions(let index):
                usedGlobals.insert(model.textureGlobal(index))
            case .sample(let texture, let sampler):
                usedGlobals.insert(model.textureGlobal(texture))
                usedGlobals.insert(model.samplerGlobal(sampler))
                let pair = CallGraph.TextureSamplerPair(
                    texture: ResourceBinding(group: 0, binding: UInt32(texture)),
                    sampler: ResourceBinding(group: 1, binding: UInt32(sampler))
                )
                textureSamplerPairs.appendIfNotContains(pair)
            case .call:
                break
            }
        }
    }
}

// MARK: - Tests

@Suite
struct WGSLIOValidatorTests {
    // MARK: VisibilityValidator

    @Test
    func visibilityWalksPreOrder() {
        // main's body comes before its callee f, so the discard is reported, not f's dpdx.
        let source = """
            fn f() -> f32 { return dpdx(1.0); }
            @compute @workgroup_size(1) fn main() { discard; _ = f(); }
            """
        #expect(visibilityError(source) == message("discard statement cannot be used by compute pipeline stage", 2, 40, 76, 9))
    }

    // The inner dpdy reports first and the outer dpdx overwrites it (release C++: ASTVisitor.h:145-149 assigns again);
    // the ASSERT(!hasError()) before it is live wherever WGSL is unoptimized.
    @Test(.enabled(if: CompileThread.recommendedStackSize == nil))
    func DEV_08_NestedDerivativeLastWins() {
        let source = "@compute @workgroup_size(1) fn main() { _ = dpdx(dpdy(1.0)); }"
        #expect(visibilityError(source) == message("built-in cannot be used by compute pipeline stage", 1, 44, 44, 15))
    }

    @Test
    func visibilityReportsABuiltinInACallee() {
        let source = """
            fn f() -> f32 { return dpdx(1.0); }
            @vertex fn main() -> @builtin(position) vec4f { _ = f(); return vec4f(); }
            """
        #expect(visibilityError(source) == message("built-in cannot be used by vertex pipeline stage", 1, 23, 23, 9))
    }

    @Test
    func visibilityAcceptsAFragmentShader() {
        let source = """
            fn f() -> f32 { return dpdx(1.0); }
            @fragment fn main() { discard; _ = f(); }
            """
        #expect(visibilityError(source) == nil)
    }

    @Test
    func visibilityKeepsTheFirstEntryPointsError() {
        let source = """
            @compute @workgroup_size(1) fn a() { discard; }
            @vertex fn b() -> @builtin(position) vec4f { discard; return vec4f(); }
            """
        #expect(visibilityError(source) == message("discard statement cannot be used by compute pipeline stage", 1, 37, 37, 9))
    }

    @Test
    func visibilityMatchesARecursiveTranscription() {
        var random = SplitMix64(state: 0x5649_5349_4249_4c45)
        var errors = 0
        for _ in 0..<5000 {
            let model = VisibilityModel(&random)
            let source = model.source
            var module = annotatedModule(source)
            let error = validateVisibility(&module)?.errors.first
            var transcription = VisibilityTranscription(module)
            let expected = transcription.run()
            #expect(error == expected, "\(source)")
            if expected != nil {
                errors += 1
            }
        }
        #expect(errors > 1000 && errors < 4000)
    }

    @Test
    func visibilityWalksADeepCallChain() {
        let count = 20_000
        let source = chainSource(count: count, leafStatement: "discard;", entryPoint: "@compute @workgroup_size(1) fn main() { f0(); }")
        let error = visibilityError(source)
        #expect(error?.utf16 == ContiguousArray("discard statement cannot be used by compute pipeline stage".utf16))
        #expect(error?.span.line == UInt32(count))
        #expect(error?.span.lineOffset == UInt32("fn f\(count - 1)() { ".utf16.count))
    }

    // MARK: IOValidator

    @Test
    func ioReportsAWorkgroupVariableInAVertexCallee() {
        let source = """
            var<workgroup> w: u32;
            fn f() { _ = w; }
            fn h() { f(); }
            @vertex fn v() -> @builtin(position) vec4f { h(); return vec4f(); }
            @compute @workgroup_size(1) fn c() { h(); }
            """
        #expect(ioError(source) == message("var with `workgroup` address space cannot be used by `vertex` pipeline stage", 2, 13, 36, 1))
    }

    @Test
    func ioRevisitsACalleeForEachEntryPoint() {
        // v's record of f is not c's, so the vertex entry point visits f again and reports w.
        let source = """
            var<workgroup> w: u32;
            fn f() { _ = w; }
            @compute @workgroup_size(1) fn c() { f(); }
            @vertex fn v() -> @builtin(position) vec4f { f(); return vec4f(); }
            """
        #expect(ioError(source) == message("var with `workgroup` address space cannot be used by `vertex` pipeline stage", 2, 13, 36, 1))
    }

    @Test
    func ioReusesACalleeRecordFromAnEarlierEntryPoint() {
        // The compute entry point writes h's record of f; the vertex entry point's visit of h reuses it instead of
        // visiting f, so release C++ never sees f's use of w under the vertex stage.
        let source = """
            var<workgroup> w: u32;
            fn f() { _ = w; }
            fn h() { f(); }
            @compute @workgroup_size(1) fn c() { h(); }
            @vertex fn v() -> @builtin(position) vec4f { h(); return vec4f(); }
            """
        var module = annotatedModule(source)
        #expect(validateIO(&module) == nil)
        let functions = functionsByName(module)
        let variables = variablesByName(module)
        guard let h = functions["h"], let w = variables["w"] else {
            Issue.record("missing declarations")
            return
        }
        #expect(declarations(module, module.callGraph.callees(h)[0].usedGlobals) == [w])
        #expect(module.callGraph.entrypoints.map { declarations(module, $0.usedGlobals) } == [[w], [w]])
    }

    @Test
    func ioParameterDoesNotHideAGlobal() {
        // C++ IOValidator::visit(Function&) opens no scope, so the parameter goes into the global scope, where w exists.
        let source = """
            var<workgroup> w: u32;
            fn f(w: u32) { _ = w; }
            @vertex fn v() -> @builtin(position) vec4f { f(1u); return vec4f(); }
            """
        #expect(ioError(source) == message("var with `workgroup` address space cannot be used by `vertex` pipeline stage", 2, 19, 42, 1))
    }

    @Test
    func ioLocalHidesAGlobal() {
        let source = """
            var<workgroup> w: u32;
            fn f() { let w = 1u; _ = w; }
            @vertex fn v() -> @builtin(position) vec4f { f(); return vec4f(); }
            """
        #expect(ioError(source) == nil)
    }

    @Test
    func ioReportsWritableStorageInAVertexShader() {
        let texture = """
            @group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, read_write>;
            @vertex fn v() -> @builtin(position) vec4f { _ = textureDimensions(t); return vec4f(); }
            """
        #expect(
            ioError(texture)
                == message("storage texture with `read_write` access mode cannot be used by `vertex` pipeline stage", 2, 67, 140, 1)
        )
        let buffer = """
            @group(0) @binding(0) var<storage, read_write> b: u32;
            @vertex fn v() -> @builtin(position) vec4f { _ = b; return vec4f(); }
            """
        #expect(
            ioError(buffer)
                == message(
                    "var with `storage` address space and `read_write` access mode cannot be used by `vertex` pipeline stage",
                    2,
                    49,
                    104,
                    1
                )
        )
    }

    @Test
    func ioRecordsTextureSamplerPairs() {
        let source = """
            @group(0) @binding(0) var t: texture_2d<f32>;
            @group(0) @binding(1) var s: sampler;
            @group(0) @binding(2) var u: texture_2d<f32>;
            fn f() -> vec4f { return textureSample(t, s, vec2f()); }
            fn g(x: texture_2d<f32>) -> vec4f { return textureSample(x, s, vec2f()); }
            @fragment fn main() -> @location(0) vec4f { _ = textureSample(u, s, vec2f()); _ = g(u); return f(); }
            """
        var module = annotatedModule(source)
        #expect(validateIO(&module) == nil)
        let functions = functionsByName(module)
        let variables = variablesByName(module)
        guard let main = functions["main"], let t = variables["t"], let s = variables["s"], let u = variables["u"] else {
            Issue.record("missing declarations")
            return
        }
        let ts = CallGraph.TextureSamplerPair(
            texture: ResourceBinding(group: 0, binding: 0),
            sampler: ResourceBinding(group: 0, binding: 1)
        )
        let us = CallGraph.TextureSamplerPair(
            texture: ResourceBinding(group: 0, binding: 2),
            sampler: ResourceBinding(group: 0, binding: 1)
        )
        let callees = module.callGraph.callees(main)
        #expect(callees.map { functionName(module, $0.target) } == ["g", "f"])
        #expect(declarations(module, callees[0].usedGlobals) == [s])
        #expect(callees[0].textureSamplerPairs.isEmpty)
        #expect(declarations(module, callees[1].usedGlobals) == [t, s])
        #expect(callees[1].textureSamplerPairs == [ts])
        let entryPoint = module.callGraph.entrypoints[0]
        #expect(declarations(module, entryPoint.usedGlobals) == [t, s, u])
        #expect(entryPoint.textureSamplerPairs == [ts, us])
    }

    @Test
    func DEV_01_DuplicateBindingInDeclarationOrder() {
        // Release C++ iterates a pointer-hash set and reports 'd' and 'b' here; Swift reports the first conflict in
        // declaration order, at the later variable.
        let source = """
            @group(0) @binding(0) var<uniform> a: u32;
            @group(0) @binding(1) var<uniform> b: u32;
            @group(0) @binding(0) var<uniform> c: u32;
            @group(0) @binding(1) var<uniform> d: u32;
            @compute @workgroup_size(1) fn main() { _ = d; _ = c; _ = b; _ = a; }
            """
        #expect(
            ioError(source)
                == message(
                    "entry point 'main' uses variables 'a' and 'c', both which use the same resource binding: @group(0) @binding(0)",
                    3,
                    22,
                    108,
                    19
                )
        )
    }

    @Test
    func DEV_05_DuplicateBindingAtTheLargestGroupAndBinding() {
        // Release C++ keys the check on {group + 1, binding + 1} and traps on the HashTable's empty key.
        let source = """
            @group(4294967295) @binding(4294967295) var<uniform> a: u32;
            @group(4294967295) @binding(4294967295) var<uniform> b: u32;
            @compute @workgroup_size(1) fn main() { _ = a; _ = b; }
            """
        let error = ioError(source)
        #expect(
            error?.utf16
                == ContiguousArray(
                    "entry point 'main' uses variables 'a' and 'b', both which use the same resource binding: @group(4294967295) @binding(4294967295)"
                        .utf16
                )
        )
        #expect(error?.span.line == 2)
    }

    @Test(
        arguments: [
            ("@fragment fn f(x: f32) {}", message("missing entry point IO attribute on parameter", 1, 15, 15, 6)),
            ("@vertex fn v() {}\n", message("a vertex shader must include the 'position' builtin in its return type", 1, 8, 8, 10)),
            ("@fragment fn f() -> f32 { return 1.0; }", message("missing entry point IO attribute on return type", 1, 20, 20, 4)),
            (
                "struct O { @location(0) x: f32 }\n@vertex fn v() -> O { return O(1.0); }",
                message("a vertex shader must include the 'position' builtin in its return type", 2, 18, 51, 2)
            ),
            (
                "@vertex fn v(@builtin(vertex_index) i: f32) -> @builtin(position) vec4f { return vec4f(); }",
                message("store type of @builtin(vertex_index) must be 'u32'", 1, 13, 13, 29)
            ),
            (
                "@fragment fn f(@builtin(vertex_index) i: u32) {}",
                message("@builtin(vertex_index) cannot be used for fragment shader input", 1, 15, 15, 29)
            ),
            (
                "@compute @workgroup_size(1) fn c(@builtin(global_invocation_id) g: vec3<i32>) {}",
                message("store type of @builtin(global_invocation_id) must be 'vec3<u32>'", 1, 33, 33, 43)
            ),
            (
                "struct I { @builtin(vertex_index) a: u32, @builtin(vertex_index) b: u32 }\n@vertex fn v(i: I) -> @builtin(position) vec4f { return vec4f(); }",
                message("@builtin(vertex_index) appears multiple times as pipeline input", 1, 42, 42, 30)
            ),
            (
                "@fragment fn f(@location(0) x: f32, @location(0) y: f32) {}",
                message("@location(0) appears multiple times", 1, 36, 36, 19)
            ),
            (
                "@fragment fn f(@location(0) x: u32) {}",
                message("integral user-defined fragment input must have a @interpolate(flat) attribute", 1, 15, 15, 19)
            ),
            (
                "struct O { @builtin(position) p: vec4f, @location(1) x: vec2<i32> }\n@vertex fn v() -> O { return O(vec4f(), vec2i()); }",
                message("integral user-defined vertex output must have a @interpolate(flat) attribute", 1, 40, 40, 26)
            ),
            (
                "struct A { @location(0) x: f32 }\nstruct B { a: A }\n@fragment fn f(b: B) {}",
                message("nested structures cannot be used for entry point IO", 2, 11, 44, 5)
            ),
            ("struct A { x: f32 }\n@fragment fn f(a: A) {}", message("missing entry point IO attribute", 1, 11, 11, 7)),
            (
                "struct O { @builtin(position) p: vec4f, @builtin(clip_distances) c: array<f32, 2> }\n@vertex fn v() -> O { return O(vec4f(), array<f32, 2>()); }",
                message("@builtin(clip_distances) requires the 'clip_distances' extension to be enabled", 1, 40, 40, 42)
            ),
            (
                "enable clip_distances;\nstruct O { @builtin(position) p: vec4f, @builtin(clip_distances) c: array<f32, 9> }\n@vertex fn v() -> O { return O(vec4f(), array<f32, 9>()); }",
                message("store type of @builtin(clip_distances) must be 'array<f32, N>' (N <= 8)", 2, 40, 63, 42)
            ),
            (
                "enable clip_distances;\n@fragment fn f(@builtin(clip_distances) c: array<f32, 2>) {}",
                message("@builtin(clip_distances) can only be used for vertex shader output", 2, 15, 38, 41)
            ),
            (
                "@fragment fn f(@builtin(primitive_index) i: u32) {}",
                message("@builtin(primitive_index) requires the 'primitive_index' extension to be enabled", 1, 15, 15, 32)
            ),
            (
                "enable primitive_index;\n@fragment fn f(@builtin(primitive_index) i: i32) {}",
                message("store type of @builtin(primitive_index) must be 'u32'", 2, 15, 39, 32)
            ),
            (
                "enable primitive_index;\n@vertex fn v(@builtin(primitive_index) i: u32) -> @builtin(position) vec4f { return vec4f(); }",
                message("@builtin(primitive_index) can only be used for fragment shader input", 2, 13, 37, 32)
            ),
            (
                "@compute @workgroup_size(1) fn c(@builtin(subgroup_size) s: u32) {}",
                message("@builtin(subgroup_size) requires the 'subgroups' extension to be enabled", 1, 33, 33, 30)
            ),
            (
                "enable subgroups;\n@vertex fn v(@builtin(subgroup_size) s: u32) -> @builtin(position) vec4f { return vec4f(); }",
                message("@builtin(subgroup_size) can only be used for compute or fragment shader input", 2, 13, 31, 30)
            ),
            (
                "enable subgroups;\n@fragment fn f(@builtin(subgroup_id) s: u32) {}",
                message("@builtin(subgroup_id) can only be used for compute shader input", 2, 15, 33, 28)
            ),
            (
                "enable subgroups;\n@compute @workgroup_size(1) fn c(@builtin(num_subgroups) s: f32) {}",
                message("store type of @builtin(num_subgroups) must be 'u32'", 2, 33, 51, 30)
            ),
            (
                "@vertex fn v(@builtin(sample_mask) m: u32) -> @builtin(position) vec4f { return vec4f(); }",
                message("@builtin(sample_mask) cannot be used for vertex shader input", 1, 13, 13, 28)
            ),
            (
                "@vertex fn v(@builtin(position) p: vec4f) -> @builtin(position) vec4f { return p; }",
                message("@builtin(position) cannot be used for vertex shader input", 1, 13, 13, 27)
            ),
            (
                "@fragment fn f() -> @builtin(frag_depth) bool { return true; }",
                message("store type of @builtin(frag_depth) must be 'f32'", 1, 41, 41, 5)
            ),
            (
                "@compute @workgroup_size(1) fn c(@builtin(front_facing) ff: bool) {}",
                message("@builtin(front_facing) cannot be used for compute shader input", 1, 33, 33, 31)
            ),
        ]
    )
    func ioReportsEntryPointIOErrors(_ source: String, _ expected: CompilationMessage) {
        #expect(ioError(source) == expected)
    }

    @Test
    func ioAcceptsValidEntryPointIO() {
        let source = """
            struct I { @builtin(position) p: vec4f, @location(0) @interpolate(flat) x: u32, @builtin(front_facing) ff: bool }
            @fragment fn f(i: I, @builtin(sample_index) s: u32, @builtin(sample_mask) m: u32) -> @location(0) vec4f { return i.p; }
            """
        #expect(ioError(source) == nil)
    }

    // AttributeValidator reports these first, so release C++ never shows IOValidator's own messages for them.
    @Test
    func ioReportsLocationsItCannotUse() {
        #expect(
            ioError("@compute @workgroup_size(1) fn c(@location(0) x: f32) {}")
                == message("@location cannot be used by compute shaders", 1, 33, 33, 19)
        )
        #expect(
            ioError("@fragment fn f(@location(0) x: bool) {}")
                == message("cannot apply @location to declaration of type 'bool'", 1, 15, 15, 20)
        )
    }

    @Test
    func ioMatchesARecursiveTranscription() {
        var random = SplitMix64(state: 0x494f_5641_4c49_4441)
        var reusedRecords = 0
        var errors = 0
        for _ in 0..<3000 {
            let model = IOModel(&random)
            let source = model.source
            var module = annotatedModule(source)
            let error = validateIO(&module)?.errors.first
            var transcription = IOTranscription(model)
            transcription.run()

            var functions: [FunctionID] = []
            var globals: [VariableID: Int] = [:]
            for declaration in module.elements(module.declarations) {
                switch declaration {
                case .function(let function): functions.append(function)
                case .variable(let variable): globals[variable] = globals.count
                default: break
                }
            }

            if let expected = transcription.error {
                errors += 1
                #expect(error == workgroupError(module, functions[expected.function], expected.statement, expected.stage), "\(source)")
                continue
            }
            #expect(error == nil, "\(source)")

            var reachable = Set<Int>()
            var pending = Array(model.helpers.count..<(model.helpers.count + model.entryPoints.count))
            while let function = pending.popLast() {
                guard reachable.insert(function).inserted else {
                    continue
                }
                let callees = module.callGraph.callees(functions[function])
                #expect(callees.map(\.target) == model.callees(of: function).map { functions[$0] })
                for (calleeIndex, callee) in callees.enumerated() {
                    let expected = transcription.records[IOEdge(caller: function, calleeIndex: calleeIndex)]
                    #expect(ioRecord(module, globals, callee.usedGlobals, callee.textureSamplerPairs) == expected, "\(source)")
                }
                pending.append(contentsOf: model.callees(of: function))
            }
            for (index, entryPoint) in module.callGraph.entrypoints.enumerated() {
                #expect(
                    ioRecord(module, globals, entryPoint.usedGlobals, entryPoint.textureSamplerPairs)
                        == transcription.entryPointRecords[index],
                    "\(source)"
                )
            }
            reusedRecords += transcription.records.values.filter { !$0.globals.isEmpty }.count
        }
        #expect(reusedRecords > 1000)
        #expect(errors > 300 && errors < 2700)
    }

    @Test
    func ioWalksADeepCallChain() {
        let count = 20_000
        let source =
            "var<private> g: u32;\n"
            + chainSource(count: count, leafStatement: "_ = g;", entryPoint: "@compute @workgroup_size(1) fn main() { f0(); }")
        var module = annotatedModule(source)
        #expect(validateIO(&module) == nil)
        guard let g = variablesByName(module)["g"] else {
            Issue.record("missing g")
            return
        }
        #expect(declarations(module, module.callGraph.entrypoints[0].usedGlobals) == [g])
    }

    // DEV-04: the C++ walks visit diamond22's leaves 2^22 times. Per call edge, each validator costs at most 8 times as
    // much CPU time 22 levels deep as 11 levels deep, where those walks visit the leaves 1,000 times more often per edge.
    @Test
    func validatorsFinishDiamond22Quickly() {
        let factor = 8
        var module = annotatedModule(diamondSource(depth: 22))
        #expect(validateIO(&module) == nil)
        #expect(validateVisibility(&module) == nil)
        func plain(_ depth: Int) -> String {
            diamondSource(depth: depth)
        }
        let io = diamondCostsPerEdge(factor: factor, plain) { _ = validateIO(&$0) }
        #expect(io.large <= io.small * factor, "validateIO: \(io.large) per edge 22 levels deep, \(io.small) 11 levels deep")
        let visibility = diamondCostsPerEdge(factor: factor, plain) { _ = validateVisibility(&$0) }
        #expect(
            visibility.large <= visibility.small * factor,
            "validateVisibility: \(visibility.large) per edge 22 levels deep, \(visibility.small) 11 levels deep"
        )

        func withLeafGlobal(_ depth: Int) -> String {
            "var<private> g: u32;\n" + diamondSource(depth: depth, leafStatement: " _ = g;")
        }
        var leafGlobalModule = annotatedModule(withLeafGlobal(22))
        #expect(validateIO(&leafGlobalModule) == nil)
        #expect(leafGlobalModule.callGraph.entrypoints[0].usedGlobals.count == 1)
        let ioWithLeafGlobal = diamondCostsPerEdge(factor: factor, withLeafGlobal) { _ = validateIO(&$0) }
        #expect(
            ioWithLeafGlobal.large <= ioWithLeafGlobal.small * factor,
            "validateIO with a leaf global: \(ioWithLeafGlobal.large) per edge 22 levels deep, \(ioWithLeafGlobal.small) 11 levels deep"
        )
    }

    // After an error nothing a revisit writes is observable, so the validators stop revisiting: per call edge, each costs at
    // most 8 times as much CPU time 22 levels deep as 11 levels deep.
    @Test
    func validatorsFinishDiamond22WithAnErrorQuickly() {
        let factor = 8
        let vertexEntryPoint = "@vertex fn main() -> @builtin(position) vec4f { a0(); return vec4f(); }"
        func workgroupLeaves(_ depth: Int) -> String {
            "var<workgroup> w: u32;\n" + diamondSource(depth: depth, leafStatement: " _ = w;", entryPoint: vertexEntryPoint)
        }
        var ioModule = annotatedModule(workgroupLeaves(22))
        let ioMessage = validateIO(&ioModule)?.errors.first
        #expect(ioMessage?.utf16 == ContiguousArray("var with `workgroup` address space cannot be used by `vertex` pipeline stage".utf16))
        #expect(ioMessage?.span.line == 2)
        #expect(ioMessage?.span.lineOffset == 15)
        let io = diamondCostsPerEdge(factor: factor, workgroupLeaves) { _ = validateIO(&$0) }
        #expect(io.large <= io.small * factor, "validateIO: \(io.large) per edge 22 levels deep, \(io.small) 11 levels deep")

        func discardLeaves(_ depth: Int) -> String {
            diamondSource(depth: depth, leafStatement: " discard;")
        }
        var visibilityModule = annotatedModule(discardLeaves(22))
        let visibilityMessage = validateVisibility(&visibilityModule)?.errors.first
        #expect(visibilityMessage?.utf16 == ContiguousArray("discard statement cannot be used by compute pipeline stage".utf16))
        #expect(visibilityMessage?.span.line == 1)
        #expect(visibilityMessage?.span.lineOffset == 11)
        let visibility = diamondCostsPerEdge(factor: factor, discardLeaves) { _ = validateVisibility(&$0) }
        #expect(
            visibility.large <= visibility.small * factor,
            "validateVisibility: \(visibility.large) per edge 22 levels deep, \(visibility.small) 11 levels deep"
        )
    }
}
