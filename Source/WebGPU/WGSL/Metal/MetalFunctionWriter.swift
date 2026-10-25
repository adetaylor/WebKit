// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

/// C++ `FunctionDefinitionWriter`.
///
/// Its functions are split over the MetalFunctionWriter+*.swift files in C++ order; the static functions of
/// MetalFunctionWriter.cpp that take the writer are its methods, which use `body`, `indent` and `helperGenerator` where C++ calls
/// `stringBuilder()`, `indent()` and `helperGenerator()`.
struct FunctionDefinitionWriter: ASTVisitor, ~Copyable {
    enum PackingHelper {
        case pack
        case unpack
    }

    var expectedError: CompilationMessage?
    var hasError = false

    /// Also C++ `m_output`: its output is the caller's builder, which already holds the prologue (moved in and back out by
    /// emitMetalFunctions).
    var helperGenerator: HelperGenerator
    var body = MSLWriter(reservingCapacity: 16_384)
    var constants = MSLWriter()
    var shaderModule: ShaderModule
    var indent = Indentation()
    var constID: UInt32 = 0
    var structRole: StructureRole?
    var variableRole: VariableRole?
    var parameterRole: ParameterRole?
    var entryPointStage: ShaderStage?
    var currentFunction: FunctionID?
    var continuing: Continuing?
    var visitedFunctions = IDSet<FunctionID>()
    var packedStructures = SideTable<StructureID, StructureID>()
    var usedPackHelpers = IDSet<StructureID>()
    var usedUnpackHelpers = IDSet<StructureID>()
    let prepareResult: Reflection.EntryPointInformations
    let constantValues: OverrideValues
    let deviceState: DeviceState
    /// C++ `metalAppleGPUFamily()`, which the C++ only compares with 9, made once: switch over it.
    let gpuClass: WriterGPUClass
    /// The explicit stacks of the type printer and of serializeConstant (MetalFunctionWriter+Types.swift), of the for statement
    /// nests (MetalFunctionWriter+Statements.swift) and of the index access chains (MetalFunctionWriter+Expressions.swift), kept to
    /// reuse their storage.
    var typePrintStack: [TypePrintStep] = []
    var constantPrintStack: [ConstantPrintStep] = []
    var forStatementNest: [ForStatement] = []
    var indexAccessChain: [IndexAccessSuffix] = []

    init(
        shaderModule: consuming ShaderModule,
        stringBuilder: consuming MSLWriter,
        prepareResult: Reflection.EntryPointInformations,
        constantValues: OverrideValues,
        deviceState: DeviceState
    ) {
        self.helperGenerator = HelperGenerator(stringBuilder)
        self.shaderModule = shaderModule
        self.prepareResult = prepareResult
        self.constantValues = constantValues
        self.deviceState = deviceState
        self.gpuClass = WriterGPUClass(appleGPUFamily: deviceState.appleGPUFamily)
    }

    mutating func shaderValidationEnabled() -> Bool {
        deviceState.shaderValidationEnabled
    }

    mutating func declareForwardProgress() -> MSLText {
        MTLWorkaround.declareForwardProgress(gpuClass)
    }

    mutating func checkForwardProgress() -> MSLText {
        MTLWorkaround.checkForwardProgress(gpuClass)
    }
}

/// nil is the C++ null ASCIILiteral.
func serializeAddressSpace(_ addressSpace: AddressSpace) -> MSLText? {
    switch addressSpace {
    case .function, .private:
        "thread"
    case .workgroup:
        "threadgroup"
    case .uniform:
        "constant"
    case .storage:
        "device"
    case .handle:
        nil
    }
}

extension FunctionDefinitionWriter {
    mutating func write() {
        emitNecessaryHelpers()

        var declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .structure(let structure) = declaration {
                visit(structure)
                if shaderModule[structure].role == .packedResource {
                    guard let original = shaderModule[structure].original else {
                        wgslFatal("a packed resource structure without its original", cppSite: "MetalFunctionWriter.cpp:422")
                    }
                    packedStructures.add(original, structure)
                }
            }
        }

        helperGenerator.output.append(contentsOf: body)
        body.clear()

        var entryPointIndex = 0
        while entryPointIndex < shaderModule.callGraph.entrypoints.count {
            let entryPoint = shaderModule.callGraph.entrypoints[entryPointIndex]
            entryPointIndex &+= 1
            if let information = prepareResult.find(entryPoint.apiName) {
                // GlobalVariableRewriter zero-initialized the entry point's workgroup variables.
                guard let initialized = information.initialized, initialized.function == entryPoint.function else {
                    wgslFatal("a prepared entry point without its EntryPointInitialized", cppSite: "MetalFunctionWriter.cpp:430")
                }
                emitEntryPoint(initialized)
            }
        }

        // Only once the functions are generated is it known which packing helpers they call, but the
        // helpers have to be declared ahead of them. Emitting every struct's helpers instead would make
        // each library compile them, including a stage that never touches the struct.
        var functions = MSLWriter()
        swap(&body, &functions)
        declarations = shaderModule.cursor(shaderModule.declarations)
        while let declaration = shaderModule.next(&declarations) {
            if case .structure(let structure) = declaration {
                generatePackingHelpers(structure)
            }
        }

        helperGenerator.output.append(contentsOf: body)
        helperGenerator.output.append(contentsOf: constants)
        helperGenerator.output.append(contentsOf: functions)
    }
}

func emitMetalFunctions(
    _ stringBuilder: inout MSLWriter,
    _ shaderModule: inout ShaderModule,
    _ prepareResult: Reflection.EntryPointInformations,
    _ constantValues: OverrideValues,
    _ deviceState: DeviceState
) {
    var functionDefinitionWriter = FunctionDefinitionWriter(
        shaderModule: shaderModule,
        stringBuilder: stringBuilder,
        prepareResult: prepareResult,
        constantValues: constantValues,
        deviceState: deviceState
    )
    functionDefinitionWriter.write()
    shaderModule = functionDefinitionWriter.shaderModule
    stringBuilder = functionDefinitionWriter.helperGenerator.output
}

// MARK: - Swift-only

/// The writer's bytes for `declaration` through the visitor's declaration dispatch (C++ `AST::Visitor::visit(AST::Declaration&)`), for
/// the hook tests: a structure, variable or const_assert prints as the writer prints it; a function traps.
@_spi(Testing)
public func emitDeclarationForTesting(
    _ declaration: Declaration,
    _ shaderModule: inout ShaderModule,
    _ deviceState: DeviceState
) -> ContiguousArray<UInt8> {
    var writer = FunctionDefinitionWriter(
        shaderModule: shaderModule,
        stringBuilder: MSLWriter(),
        prepareResult: Reflection.EntryPointInformations(),
        constantValues: OverrideValues(),
        deviceState: deviceState
    )
    writer.visit(declaration)
    let bytes = writer.body.bytes
    shaderModule = writer.shaderModule
    return bytes
}
