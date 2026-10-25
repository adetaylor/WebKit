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

/// C++ `AST::ScopedVisitor<T>`: a visitor that is also a `ContextProvider<T>` and opens a context scope for functions,
/// compound statements, for statements and loops (and a nested one for `continuing`).
@_spi(Testing)
public protocol ASTScopedVisitor: ASTVisitor, ~Copyable {
    associatedtype ContextValue
    var context: ContextProvider<ContextValue> { get set }
}

extension ASTScopedVisitor where Self: ~Copyable {
    // The ContextProvider members, reachable unqualified as in C++.

    @_spi(Testing)
    @discardableResult
    public mutating func introduceVariable(_ name: IdentifierID, _ value: ContextValue) -> ContextValue? {
        context.introduceVariable(shaderModule.symbol(of: name), value)
    }

    @_spi(Testing)
    @discardableResult
    public mutating func introduceVariable(_ name: Symbol, _ value: ContextValue) -> ContextValue? {
        context.introduceVariable(name, value)
    }

    // `mutating` although they only read: a non-mutating call from the specialised traversal copies the whole pass at -O.
    @_spi(Testing)
    public mutating func readVariable(_ name: IdentifierID) -> ContextValue? {
        context.readVariable(shaderModule.symbol(of: name))
    }

    @_spi(Testing)
    public mutating func readVariable(_ name: Symbol) -> ContextValue? {
        context.readVariable(name)
    }

    /// C++ `ContextScope scope(this);`; close it with `closeContextScope` in a `defer`.
    @_spi(Testing)
    public mutating func openContextScope() -> ContextProvider<ContextValue>.Scope {
        context.openScope()
    }

    @_spi(Testing)
    public mutating func closeContextScope(_ scope: ContextProvider<ContextValue>.Scope) {
        context.closeScope(scope)
    }

    // ScopedVisitor<T>::visit (ASTScopedVisitorInlines.h). A pass that overrides one of these calls C++ `Base::visit(x)`
    // as `scopedVisit(x)`.

    @_spi(Testing)
    public mutating func visit(_ function: FunctionID) {
        scopedVisit(function)
    }

    @_spi(Testing)
    public mutating func scopedVisit(_ function: FunctionID) {
        let functionScope = openContextScope()
        defer { closeContextScope(functionScope) }
        visitChildren(function)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: CompoundStatement, _ id: StatementID) {
        scopedVisit(statement, id)
    }

    @_spi(Testing)
    public mutating func scopedVisit(_ statement: CompoundStatement, _ id: StatementID) {
        let blockScope = openContextScope()
        defer { closeContextScope(blockScope) }
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visit(_ statement: ForStatement, _ id: StatementID) {
        scopedVisit(statement, id)
    }

    @_spi(Testing)
    public mutating func scopedVisit(_ statement: ForStatement, _ id: StatementID) {
        let forScope = openContextScope()
        defer { closeContextScope(forScope) }
        visitChildren(statement, id)
    }

    @_spi(Testing)
    public mutating func visit(_ loopStatement: LoopStatement, _ id: StatementID) {
        scopedVisit(loopStatement, id)
    }

    @_spi(Testing)
    public mutating func scopedVisit(_ loopStatement: LoopStatement, _ id: StatementID) {
        let loopScope = openContextScope()
        defer { closeContextScope(loopScope) }
        checkErrorAndVisitEach(loopStatement.attributes)
        checkErrorAndVisitEach(loopStatement.body)
        if let continuing = loopStatement.continuing {
            let continuingScope = openContextScope()
            defer { closeContextScope(continuingScope) }
            checkErrorAndVisit(continuing)
        }
    }
}
