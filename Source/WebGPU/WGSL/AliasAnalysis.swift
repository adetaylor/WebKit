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

private struct MemoryLocation: Hashable, BitwiseCopyable {
    enum Kind: UInt8, Hashable, BitwiseCopyable {
        case invalid
        case local
        case global
        case parameter
    }

    init() {
        kind = .invalid
        id = 0
    }

    static func parameter(_ id: UInt32) -> MemoryLocation { MemoryLocation(.parameter, id) }
    static func global(_ id: UInt32) -> MemoryLocation { MemoryLocation(.global, id) }
    static func local(_ id: UInt32) -> MemoryLocation { MemoryLocation(.local, id) }

    var isParameter: Bool { kind == .parameter }
    var isGlobal: Bool { kind == .global }

    private init(_ kind: Kind, _ id: UInt32) {
        self.kind = kind
        self.id = id
    }

    private let kind: Kind
    private let id: UInt32
}

extension MemoryLocation: SmallKey {
    var smallKeyBits: UInt64 { UInt64(kind.rawValue) << 32 | UInt64(id) }
}

// C++ HashSet<MemoryLocation>, only searched and merged.
private struct MemoryLocationSet {
    private var locations = SmallKeyMap<MemoryLocation, Void>()

    @discardableResult
    mutating func add(_ location: MemoryLocation) -> Bool {
        locations.add(location, ())
    }

    func contains(_ location: MemoryLocation) -> Bool {
        locations.contains(location)
    }

    mutating func addAll(_ other: MemoryLocationSet) {
        locations.addAll(other.locations)
    }
}

private struct FunctionInfo {
    init(_ parameterCount: Int) {
        parameters = Array(repeatElement(MemoryLocation(), count: parameterCount))
    }

    var parameters: [MemoryLocation]
    var readParameters = MemoryLocationSet()
    var writtenParameters = MemoryLocationSet()
    var readGlobals = MemoryLocationSet()
    var writtenGlobals = MemoryLocationSet()
}

private struct AliasAnalysis: ASTScopedVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var context = ContextProvider<MemoryLocation>()

    // C++ HashMap<String, FunctionInfo>. The infos live in `functionInfos`, so `function` (C++ m_function, a pointer
    // into the map) is an index.
    private var functions = SymbolMap<Int>()
    private var functionInfos: [FunctionInfo] = []
    private var function: Int?
    private var globals: [MemoryLocation] = []
    private var globalID: UInt32 = 0
    private var localID: UInt32 = 0
    private var parameterID: UInt32 = 0

    private static let atomicWriteFunctions: [Symbol] = [
        Symbol(.atomicAdd),
        Symbol(.atomicAnd),
        Symbol(.atomicCompareExchangeWeak),
        Symbol(.atomicExchange),
        Symbol(.atomicMax),
        Symbol(.atomicMin),
        Symbol(.atomicOr),
        Symbol(.atomicStore),
        Symbol(.atomicSub),
        Symbol(.atomicXor),
    ]

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func run() -> CompilationMessage? {
        var globalCount = 0
        var functionCount = 0
        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            switch declaration {
            case .function:
                functionCount += 1
            case .variable:
                globalCount += 1
            case .structure, .typeAlias, .constAssert:
                break
            }
        }

        // Only a function can read, write or alias a location.
        guard functionCount > 0 else {
            return nil
        }

        // C++ resizes m_globals to globalCount and then appends; only the appended locations are read.
        globals.reserveCapacity(globalCount)
        functions.reserveInitialCapacity(functionCount)
        functionInfos.reserveCapacity(functionCount)

        declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .variable(let globalVar) = declaration {
                globals.append(MemoryLocation.global(globalID))
                globalID &+= 1
                introduceVariable(shaderModule[globalVar].name, globals[globals.count - 1])
            } else if case .function(let function) = declaration {
                visit(function)
                if hasError {
                    return result()
                }
            }
        }

        return nil
    }

    mutating func visit(_ function: FunctionID) {
        let functionScope = openContextScope()
        defer { closeContextScope(functionScope) }

        let parameters = shaderModule[function].parameters
        let parameterCount = shaderModule.count(parameters)
        let name = shaderModule.symbol(of: shaderModule[function].name)
        if let existing = functions.find(name) {
            self.function = existing
        } else {
            functions.add(name, functionInfos.count)
            self.function = functionInfos.count
            functionInfos.append(FunctionInfo(parameterCount))
        }
        let current = currentFunction()

        var i = 0
        while i < parameterCount {
            let parameter = shaderModule[parameters, i]
            functionInfos[current].parameters[i] = MemoryLocation.parameter(parameterID)
            parameterID &+= 1
            introduceVariable(shaderModule[parameter].name, functionInfos[current].parameters[i])
            i += 1
        }

        visitChildren(function)
        self.function = nil
        localID = 0
        parameterID = 0
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        guard case .identifierExpression(let target) = shaderModule[call.target].kind else {
            visitChildren(call, id)
            return
        }

        let targetName = shaderModule.symbol(of: target.identifier)
        guard let function = functions.find(targetName) else {
            if Self.atomicWriteFunctions.contains(targetName) {
                write(shaderModule[call.arguments, 0])
            }

            visitChildren(call, id)
            return
        }

        let argumentCount = shaderModule.count(call.arguments)
        var writtenArguments = MemoryLocationSet()
        var readArguments = MemoryLocationSet()

        let current = currentFunction()
        let calleeWrittenGlobals = functionInfos[function].writtenGlobals
        functionInfos[current].writtenGlobals.addAll(calleeWrittenGlobals)
        let calleeReadGlobals = functionInfos[function].readGlobals
        functionInfos[current].readGlobals.addAll(calleeReadGlobals)

        var i = 0
        while i < argumentCount {
            defer { i += 1 }
            let argument = shaderModule[call.arguments, i]

            guard shaderModule.types.getIf(Types.Pointer.self, shaderModule.inferredType(of: argument)) != nil else {
                continue
            }

            guard let argumentLocation = getRootIdentifier(argument) else {
                continue
            }

            let parameter = functionInfos[function].parameters[i]
            let isParameterRead = functionInfos[function].readParameters.contains(parameter)
            let isParameterWritten = functionInfos[function].writtenParameters.contains(parameter)

            if isParameterWritten {
                write(argumentLocation)
            }
            if isParameterRead {
                read(argumentLocation)
            }

            let alreadyWritten =
                isParameterWritten
                ? !writtenArguments.add(argumentLocation)
                : writtenArguments.contains(argumentLocation)

            let alreadyRead =
                isParameterRead
                ? !readArguments.add(argumentLocation)
                : readArguments.contains(argumentLocation)

            if (isParameterWritten && (alreadyWritten || alreadyRead)) || (isParameterRead && alreadyWritten) {
                setError(CompilationMessage(text: "invalid aliased pointer argument", span: shaderModule.span(of: argument)))
                return
            }

            if argumentLocation.isGlobal {
                let isGlobalRead = functionInfos[function].readGlobals.contains(argumentLocation)
                let isGlobalWritten = functionInfos[function].writtenGlobals.contains(argumentLocation)
                if (isGlobalWritten && isParameterWritten) || (isGlobalWritten && isParameterRead) || (isGlobalRead && isParameterWritten) {
                    setError(CompilationMessage(text: "invalid aliased pointer argument", span: shaderModule.span(of: argument)))
                    return
                }
            }
        }
    }

    mutating func visit(_ statement: CompoundAssignmentStatement, _ id: StatementID) {
        write(statement.leftExpression)
        visit(statement.rightExpression)
    }

    mutating func visit(_ statement: DecrementIncrementStatement, _ id: StatementID) {
        write(statement.expression)
    }

    mutating func visit(_ statement: AssignmentStatement, _ id: StatementID) {
        write(statement.lhs)
        visit(statement.rhs)
    }

    mutating func visit(_ statement: VariableStatement, _ id: StatementID) {
        introduceVariable(shaderModule[statement.variable].name, MemoryLocation.local(localID))
        localID &+= 1
        maybeCheckErrorAndVisit(shaderModule[statement.variable].maybeInitializer)
    }

    private mutating func getRootIdentifier(_ expression: ExpressionID) -> MemoryLocation? {
        let kind = shaderModule[expression].kind
        if case .identityExpression(let identityExpression) = kind {
            return getRootIdentifier(identityExpression.expression)
        }
        if case .unaryExpression(let unaryExpression) = kind {
            return getRootIdentifier(unaryExpression.expression)
        }
        if case .fieldAccessExpression(let fieldAccess) = kind {
            return getRootIdentifier(fieldAccess.base)
        }
        if case .indexAccessExpression(let indexAccess) = kind {
            return getRootIdentifier(indexAccess.base)
        }
        if case .identifierExpression(let identifierExpression) = kind {
            return readVariable(identifierExpression.identifier)
        }
        return nil
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        guard let rootIdentifier = readVariable(expression.identifier) else {
            return
        }

        read(rootIdentifier)
    }

    private mutating func read(_ rootIdentifier: MemoryLocation) {
        if rootIdentifier.isParameter {
            functionInfos[currentFunction()].readParameters.add(rootIdentifier)
        } else if rootIdentifier.isGlobal {
            functionInfos[currentFunction()].readGlobals.add(rootIdentifier)
        }
    }

    private mutating func write(_ expression: ExpressionID) {
        guard let rootIdentifier = getRootIdentifier(expression) else {
            return
        }
        write(rootIdentifier)
    }

    private mutating func write(_ rootIdentifier: MemoryLocation) {
        if rootIdentifier.isParameter {
            functionInfos[currentFunction()].writtenParameters.add(rootIdentifier)
        } else if rootIdentifier.isGlobal {
            functionInfos[currentFunction()].writtenGlobals.add(rootIdentifier)
        }
    }

    /// C++ `*m_function`: set only while `visit(FunctionID)` runs, and only its traversal reads or writes locations.
    private mutating func currentFunction() -> Int {
        guard let function else {
            wgslFatal("AliasAnalysis read or wrote a location outside a function", cppSite: "AliasAnalysis.cpp:211")
        }
        return function
    }
}

@_spi(Testing)
public func aliasAnalysis(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    var analysis = AliasAnalysis(shaderModule: shaderModule)
    let error = analysis.run()
    shaderModule = analysis.shaderModule
    if let error {
        return FailedCheck(errors: [error], warnings: [])
    }
    return nil
}
