// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
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

/// C++ `AST::NodeKind`, in the C++ order.
///
/// A Swift node's kind is its category arena plus its payload case; this enum serves the sites that switch on the C++
/// kind (dumps, diagnostics). `unknown` and `directive` are never stored.
@_spi(Testing)
public enum NodeKind: UInt8, BitwiseCopyable, CaseIterable, Hashable, Sendable {
    case unknown
    // Attribute
    case alignAttribute
    case bindingAttribute
    case builtinAttribute
    case constAttribute
    case diagnosticAttribute
    case groupAttribute
    case idAttribute
    case interpolateAttribute
    case invariantAttribute
    case locationAttribute
    case mustUseAttribute
    case sizeAttribute
    case stageAttribute
    case workgroupSizeAttribute
    case constAssert
    case directive
    case diagnosticDirective
    // Expression
    case binaryExpression
    case callExpression
    case fieldAccessExpression
    case identifierExpression
    case identityExpression
    case indexAccessExpression
    case pointerDereferenceExpression
    case unaryExpression
    case function
    case parameter
    case identifier
    // Literal
    case abstractFloatLiteral
    case abstractIntegerLiteral
    case boolLiteral
    case float32Literal
    case float16Literal
    case signed32Literal
    case unsigned32Literal
    case shaderModule
    // Statement
    case assignmentStatement
    case breakStatement
    case callStatement
    case compoundAssignmentStatement
    case compoundStatement
    case constAssertStatement
    case continueStatement
    case decrementIncrementStatement
    case discardStatement
    case forStatement
    case ifStatement
    case loopStatement
    case phonyAssignmentStatement
    case returnStatement
    case switchStatement
    case variableStatement
    case whileStatement
    case structure
    case structureMember
    case typeAlias
    case arrayTypeExpression
    case elaboratedTypeExpression
    case referenceTypeExpression
    case variable
    case variableQualifier
}
