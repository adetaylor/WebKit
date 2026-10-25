// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

// The staticCheck -> prepare -> generate lifecycle (WGSL.cpp:94-186) as noncopyable states. C++ opens a CompilationScope
// in prepareImpl and in generate, and nothing stops two live PrepareResults on one module; here prepare consumes the
// ModuleState, so at most one PreparedState exists per module, and both ways out of it roll back and hand the
// ModuleState back. Dropping a PreparedState without consuming it destroys the module.

/// The capability to open a CompilationScope.
///
/// Only this file can make one, so no pass can open or roll back a scope.
struct CompilationScopeCapability: ~Copyable {
    fileprivate init() {}
}

/// What the staticCheck passes produced (WGSL.cpp:94-123): the warnings and the reflection, or the failure.
@_spi(Testing)
public enum StaticCheckPassesOutcome {
    case success(warnings: [CompilationMessage], entryPoints: [EntryPointIO])
    case failure(FailedCheck)
}

@_spi(Testing)
public enum StaticCheckStep: ~Copyable {
    case checked(ModuleState)
    case failed(FailedCheck)
}

/// The state of a CheckedModule: a module that passed staticCheck, with no scope open.
@_spi(Testing)
public struct ModuleState: ~Copyable {
    private var storage: ShaderModule

    /// Readable (borrowed) everywhere; writable and consumable only in this file.
    @_spi(Testing)
    public var shaderModule: ShaderModule {
        _read { yield storage }
    }

    @_spi(Testing)
    public let warnings: [CompilationMessage]

    /// The reflection computed at check time.
    @_spi(Testing)
    public let entryPoints: [EntryPointIO]

    fileprivate init(shaderModule: consuming ShaderModule, warnings: [CompilationMessage], entryPoints: [EntryPointIO]) {
        self.storage = shaderModule
        self.warnings = warnings
        self.entryPoints = entryPoints
    }

    /// WGSL.cpp:94-123: the only unscoped mutation of a module, before it is checked.
    @_spi(Testing)
    public static func staticCheck(
        _ shaderModule: consuming ShaderModule,
        passes: (inout ShaderModule) -> StaticCheckPassesOutcome
    ) -> StaticCheckStep {
        var shaderModule = shaderModule
        guard !shaderModule.isInCompilationScope else {
            wgslFatal("staticCheck of a module inside a CompilationScope", cppSite: "WGSL.cpp:94")
        }
        switch passes(&shaderModule) {
        case .success(let warnings, let entryPoints):
            return .checked(ModuleState(shaderModule: shaderModule, warnings: warnings, entryPoints: entryPoints))
        case .failure(let failedCheck):
            return .failed(failedCheck)
        }
    }

    /// prepareImpl (WGSL.cpp:135-157): opens the prepare scope and runs the prepare passes; on failure rolls back and returns
    /// the module.
    @_spi(Testing)
    public consuming func prepare<R>(_ passes: (inout ShaderModule) -> Result<R, CompilationMessage>) -> PrepareStep<R> {
        let capability = CompilationScopeCapability()
        var shaderModule = self.storage
        let prepareScope = shaderModule.openScope(capability)
        switch passes(&shaderModule) {
        case .success(let result):
            let prepared = PreparedState(
                shaderModule: shaderModule,
                prepareScope: prepareScope,
                warnings: warnings,
                entryPoints: entryPoints
            )
            return .prepared(prepared, result) // lint-exempt(L-WB-1): PrepareStep, the state PrepareOutcome wraps
        case .failure(let error):
            shaderModule.rollback(prepareScope)
            return .failed(ModuleState(shaderModule: shaderModule, warnings: warnings, entryPoints: entryPoints), error)
        }
    }

    /// evaluate() on the checked module (ComputePipeline.mm:59-68); its only writes are the sticky constant cache.
    @_spi(Testing)
    public mutating func evaluate(_ expression: ExpressionID, overrides: OverrideValues) -> ConstantValue? {
        WGSL.evaluate(&storage, expression, overrides)
    }

    /// Runs `body` inside a CompilationScope of `shaderModule`, then rolls the scope back, for the IR tests.
    @_spi(Testing)
    public static func withTestScope(_ shaderModule: inout ShaderModule, _ body: (inout ShaderModule) -> Void) {
        let capability = CompilationScopeCapability()
        let scope = shaderModule.openScope(capability)
        body(&shaderModule)
        shaderModule.rollback(scope)
    }
}

@_spi(Testing)
public enum PrepareStep<R>: ~Copyable {
    case prepared(PreparedState, R)
    /// The prepare scope has already been rolled back.
    case failed(ModuleState, CompilationMessage)
}

/// The state of a PreparedModule: the module inside its prepare scope.
@_spi(Testing)
public struct PreparedState: ~Copyable {
    private var storage: ShaderModule

    /// Readable (borrowed) everywhere; writable and consumable only in this file.
    @_spi(Testing)
    public var shaderModule: ShaderModule {
        _read { yield storage }
    }

    fileprivate let prepareScope: CompilationScope

    @_spi(Testing)
    public let warnings: [CompilationMessage]

    @_spi(Testing)
    public let entryPoints: [EntryPointIO]

    fileprivate init(
        shaderModule: consuming ShaderModule,
        prepareScope: consuming CompilationScope,
        warnings: [CompilationMessage],
        entryPoints: [EntryPointIO]
    ) {
        self.storage = shaderModule
        self.prepareScope = prepareScope
        self.warnings = warnings
        self.entryPoints = entryPoints
    }

    /// C++ generate() (WGSL.cpp:160-174) followed by ~PrepareResult: opens the generation scope, runs `codegen`
    /// (validateOverrides and the Metal writer), then rolls back the generation scope and the prepare scope.
    @_spi(Testing)
    public consuming func generate<R>(_ codegen: (inout ShaderModule) -> Result<R, CompilationMessage>) -> GenerateStep<R> {
        let capability = CompilationScopeCapability()
        var shaderModule = self.storage
        let prepareScope = self.prepareScope
        let generationScope = shaderModule.openScope(capability)
        let result = codegen(&shaderModule)
        shaderModule.rollback(generationScope)
        shaderModule.rollback(prepareScope)
        return GenerateStep(module: ModuleState(shaderModule: shaderModule, warnings: warnings, entryPoints: entryPoints), result: result)
    }

    /// C++ ~PrepareResult without generate.
    @_spi(Testing)
    public consuming func rollBack() -> ModuleState {
        var shaderModule = self.storage
        shaderModule.rollback(self.prepareScope)
        return ModuleState(shaderModule: shaderModule, warnings: warnings, entryPoints: entryPoints)
    }
}

@_spi(Testing)
public struct GenerateStep<R>: ~Copyable {
    /// Rolled back.
    @_spi(Testing)
    public var module: ModuleState

    @_spi(Testing)
    public var result: Result<R, CompilationMessage>

    /// The module, for code outside this module, which cannot consume a field of the step.
    @_spi(Testing)
    public consuming func takeModule() -> ModuleState {
        module
    }
}
