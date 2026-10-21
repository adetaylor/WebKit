// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2024-2026 Apple Inc. All rights reserved.
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

private struct VisibilityValidator: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false

    private var stage = ShaderStage.vertex

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func validate() -> FailedCheck? {
        var index = 0
        while index < shaderModule.callGraph.entrypoints.count {
            let entryPoint = shaderModule.callGraph.entrypoints[index]
            stage = entryPoint.stage
            visit(entryPoint.function)
            index += 1
        }

        guard let error = result() else {
            return nil
        }
        return FailedCheck(errors: [error], warnings: [])
    }

    // The C++ recursion over the callees, as CallGraph.walk events, in pre-order: the function's body at `.enter`, then
    // each callee unless an error is set (C++ checkErrorAndVisit).
    mutating func visit(_ function: FunctionID) {
        // DEV-04: a function is visited once per entry point; a second visit under the same stage cannot report an error.
        var visitedFunctions = IDSet<FunctionID>()
        var calleeWalk = shaderModule.callGraph.walk(from: function)
        while let event = calleeWalk.next(shaderModule.callGraph) {
            switch event {
            case .enter(let entered):
                visitedFunctions.add(entered)
                visitChildren(entered)
            case .edge(let caller, let calleeIndex):
                let target = shaderModule.callGraph.callees(caller)[calleeIndex].target
                if hasError || visitedFunctions.contains(target) {
                    calleeWalk.skip()
                } else {
                    calleeWalk.descend()
                }
            case .edgeDone, .exit:
                break
            }
        }
    }

    mutating func visit(_ call: CallExpression, _ id: ExpressionID) {
        visitChildren(call, id)
        if !call.visibility.contains(ShaderStages(stage)) {
            error(shaderModule.span(of: id), "built-in cannot be used by \(toString(stage)) pipeline stage")
        }
    }

    mutating func visit(_ statement: DiscardStatement, _ id: StatementID) {
        if stage != .fragment {
            error(shaderModule.span(of: id), "discard statement cannot be used by \(toString(stage)) pipeline stage")
        }
    }

    private mutating func error(_ span: SourceSpan, _ message: MessageText) {
        setError(CompilationMessage(text: message, span: span))
    }
}

@_spi(Testing)
public func validateVisibility(_ shaderModule: inout ShaderModule) -> FailedCheck? {
    var validator = VisibilityValidator(shaderModule: shaderModule)
    let result = validator.validate()
    shaderModule = validator.shaderModule
    return result
}
