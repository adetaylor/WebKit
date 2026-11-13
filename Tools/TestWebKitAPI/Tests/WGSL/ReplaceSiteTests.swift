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

private func span(_ n: UInt32) -> SourceSpan {
    SourceSpan(line: n, lineOffset: n, offset: n, length: n)
}

private func makeModule() -> ShaderModule {
    ShaderModule(source: SourceText(""))
}

private func identifierExpression(_ module: inout ShaderModule, _ name: StaticString, _ n: UInt32) -> ExpressionID {
    let identifier = module.makeIdentifier(name, span: span(n + 100))
    return module.constructIdentifierExpression(span: span(n), identifier: identifier)
}

private func identifierOf(_ module: borrowing ShaderModule, _ expression: ExpressionID) -> IdentifierID {
    module.downcast(IdentifierExpression.self, expression).identifier
}

// The C++ sites of `ShaderModule::replace(current, replacement)` for expressions, with the static types C++ resolves the
// overload from; `wraps` is overload (3), IdentityExpression wrapping, else (4), copy into storage.
private struct ReplaceSite {
    let site: String
    let current: ExpressionKindTag
    let replacement: ExpressionKindTag
    let wraps: Bool
}

private let replaceSites: [ReplaceSite] = [
    ReplaceSite(site: "BoundsCheck.cpp:141", current: .indexAccessExpression, replacement: .checkedIndexAccessExpression, wraps: false),
    ReplaceSite(site: "EntryPointRewriter.cpp:149", current: .identifierExpression, replacement: .identifierExpression, wraps: false),
    ReplaceSite(site: "EntryPointRewriter.cpp:194", current: .identifierExpression, replacement: .identifierExpression, wraps: false),
    ReplaceSite(site: "EntryPointRewriter.cpp:196", current: .elaboratedTypeExpression, replacement: .identifierExpression, wraps: false),
    ReplaceSite(site: "EntryPointRewriter.cpp:198", current: .arrayTypeExpression, replacement: .identifierExpression, wraps: true),
    ReplaceSite(
        site: "EvaluationOrderRewriter.cpp:254",
        current: .indexAccessExpression,
        replacement: .indexAccessExpression,
        wraps: false
    ),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .identifierExpression, replacement: .callExpression, wraps: true),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .indexAccessExpression, replacement: .callExpression, wraps: true),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .checkedIndexAccessExpression, replacement: .callExpression, wraps: true),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .binaryExpression, replacement: .callExpression, wraps: true),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .unaryExpression, replacement: .callExpression, wraps: true),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .identityExpression, replacement: .callExpression, wraps: true),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .fieldAccessExpression, replacement: .callExpression, wraps: false),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:528", current: .callExpression, replacement: .callExpression, wraps: false),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:599", current: .fieldAccessExpression, replacement: .fieldAccessExpression, wraps: false),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:773", current: .callExpression, replacement: .binaryExpression, wraps: false),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:987", current: .identifierExpression, replacement: .identifierExpression, wraps: false),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:1015", current: .arrayTypeExpression, replacement: .arrayTypeExpression, wraps: false),
    ReplaceSite(site: "GlobalVariableRewriter.cpp:1017", current: .identifierExpression, replacement: .arrayTypeExpression, wraps: false),
    ReplaceSite(
        site: "GlobalVariableRewriter.cpp:1038",
        current: .referenceTypeExpression,
        replacement: .referenceTypeExpression,
        wraps: false
    ),
    ReplaceSite(site: "PointerRewriter.cpp:145", current: .identifierExpression, replacement: .identityExpression, wraps: false),
    ReplaceSite(site: "PointerRewriter.cpp:168", current: .unaryExpression, replacement: .identityExpression, wraps: false),
]

@Suite
struct WGSLReplaceSiteTests {
    // `sizeof` of each C++ expression class; a checked access is a C++ IndexAccessExpression.
    @Test
    func cppSizeofMatchesTheCxxReference() {
        let reference: [(ExpressionKindTag, Int)] = [
            (.abstractFloatLiteral, 88), (.abstractIntegerLiteral, 88), (.binaryExpression, 104), (.boolLiteral, 88),
            (.callExpression, 128), (.fieldAccessExpression, 152), (.float32Literal, 88), (.float16Literal, 88),
            (.identifierExpression, 112), (.identityExpression, 88), (.indexAccessExpression, 96),
            (.checkedIndexAccessExpression, 96), (.pointerDereferenceExpression, 88), (.signed32Literal, 88),
            (.unaryExpression, 96), (.unsigned32Literal, 88), (.arrayTypeExpression, 96), (.elaboratedTypeExpression, 128),
            (.referenceTypeExpression, 88),
        ]
        #expect(reference.count == ExpressionKindTag.allCases.count)
        for (tag, size) in reference {
            #expect(tag.cppSizeof == size, "sizeof \(tag)")
        }
    }

    // The 15 C++ sites (GlobalVariableRewriter.cpp:528 is a generic lambda: one row per instantiation).
    @Test
    func theRulePicksTheCxxOverloadAtEverySite() {
        #expect(Set(replaceSites.map(\.site)).count == 15)
        for site in replaceSites {
            #expect(
                ShaderModule.replaceWraps(site.current, site.replacement) == site.wraps,
                "\(site.site): \(site.current) -> \(site.replacement)"
            )
        }
        // A replacement typed `AST::Expression&` always wraps, whatever the sizes.
        #expect(ShaderModule.replaceWraps(.callExpression, .identityExpression, replacementIsTypedAsExpressionBase: true))
        #expect(ShaderModule.replaceWraps(.fieldAccessExpression, .unsigned32Literal, replacementIsTypedAsExpressionBase: true))
    }

    // Overload (3) (EntryPointRewriter.cpp:198): current becomes IdentityExpression(replacement.span(), replacement), with
    // the replacement's inferred type and no evaluation or constant value.
    @Test
    func wrappingMakesAnIdentityExpression() {
        var module = makeModule()
        let current = module.construct(span: span(1), ArrayTypeExpression(maybeElementType: nil, maybeElementCount: nil))
        module.setInferredType(module.types.f32Type, for: current)
        module.setEvaluation(.runtime, for: current)
        module.setConstantValue(.int32(1), for: current)
        let replacement = identifierExpression(&module, "S", 2)
        module.setInferredType(module.types.i32Type, for: replacement)
        module.setEvaluation(.constant, for: replacement)
        module.setConstantValue(.int32(7), for: replacement)

        module.replace(current, with: replacement)
        #expect(module.tag(of: current) == .identityExpression)
        #expect(module.downcast(IdentityExpression.self, current).expression == replacement)
        #expect(module.span(of: current) == span(2))
        #expect(module.inferredType(of: current) == module.types.i32Type)
        #expect(module.evaluation(of: current) == nil)
        #expect(module.constantValue(of: current) == nil)
        #expect(module.tag(of: replacement) == .identifierExpression)

        // A later replacement of the wrapped node stays visible through the wrapper.
        let later = identifierExpression(&module, "T", 3)
        module.replace(replacement, with: later)
        let t = module.symbols.intern("T")
        #expect(module.downcast(IdentityExpression.self, current).expression == replacement)
        #expect(module.symbol(of: identifierOf(module, replacement)) == t)
    }

    // Overload (4) (EntryPointRewriter.cpp:149): current becomes a copy of the replacement, annotations included, with
    // identifier slots of its own (C++ copies AST::Identifier members by value).
    @Test
    func copyingCopiesTheSlotAndClonesIdentifiers() {
        var module = makeModule()
        let current = identifierExpression(&module, "a", 1)
        module.setInferredType(module.types.u32Type, for: current)
        let replacement = identifierExpression(&module, "b", 2)
        module.setInferredType(module.types.i32Type, for: replacement)
        module.setEvaluation(.override, for: replacement)
        module.setConstantValue(.int32(7), for: replacement)

        module.replace(current, with: replacement)
        #expect(module.tag(of: current) == .identifierExpression)
        #expect(module.span(of: current) == span(2))
        #expect(module.inferredType(of: current) == module.types.i32Type)
        #expect(module.evaluation(of: current) == .override)
        #expect(module.constantValue(of: current) == .int32(7))
        let copied = identifierOf(module, current)
        let original = identifierOf(module, replacement)
        #expect(copied != original)
        #expect(module[copied] == module[original])

        // Renaming one copy (MangleNames) leaves the other alone.
        let b = module.symbols.intern("b")
        let c = module.symbols.intern("c")
        module.replace(copied, keepingSpanWith: c)
        #expect(module.symbol(of: copied) == c)
        #expect(module[copied].span == span(102))
        #expect(module.symbol(of: original) == b)
    }

    // GlobalVariableRewriter.cpp:599: both field names get slots of their own.
    @Test
    func copyingAFieldAccessClonesBothFieldNames() {
        var module = makeModule()
        let base = identifierExpression(&module, "s", 1)
        let current = module.constructFieldAccessExpression(span: span(2), base: base, fieldName: module.makeIdentifier("x"))
        let replacement = module.constructFieldAccessExpression(span: span(3), base: base, fieldName: module.makeIdentifier("y"))
        module.replace(current, with: replacement)

        let copied = module.downcast(FieldAccessExpression.self, current)
        let original = module.downcast(FieldAccessExpression.self, replacement)
        #expect(copied.base == base)
        #expect(copied.fieldName != original.fieldName)
        #expect(copied.originalFieldName != original.originalFieldName)
        #expect(copied.fieldName != copied.originalFieldName)
        #expect(module[copied.fieldName] == module[original.fieldName])
        #expect(module[copied.originalFieldName] == module[original.originalFieldName])
        let y = module.symbols.intern("y")
        let z = module.symbols.intern("z")
        module.replace(copied.fieldName, with: Identifier(span: span(9), symbol: z))
        #expect(module.symbol(of: copied.fieldName) == z)
        #expect(module.symbol(of: original.fieldName) == y)
        #expect(module.symbol(of: copied.originalFieldName) == y)
    }

    // EntryPointRewriter.cpp:196: an ElaboratedTypeExpression is overwritten in place by an IdentifierExpression.
    @Test
    func copyingASmallerKindOverwritesInPlace() {
        var module = makeModule()
        let arguments = module.makeList([identifierExpression(&module, "f32", 1)])
        let current = module.constructElaboratedTypeExpression(span: span(2), base: module.makeIdentifier("vec2"), arguments: arguments)
        let replacement = identifierExpression(&module, "S", 3)
        module.replace(current, with: replacement)
        let s = module.symbols.intern("S")
        #expect(module.nodeKind(of: current) == .identifierExpression)
        #expect(module.symbol(of: identifierOf(module, current)) == s)
    }

    // GlobalVariableRewriter.cpp:520 `construct<decltype(expression)>(expression)`.
    @Test
    func constructCopyOfCopiesTheConstantAndClonesIdentifiers() {
        var module = makeModule()
        let base = identifierExpression(&module, "s", 1)
        let access = module.constructFieldAccessExpression(span: span(2), base: base, fieldName: module.makeIdentifier("x"))
        module.setInferredType(module.types.f32Type, for: access)
        module.setConstantValue(.float(1.5), for: access)
        let copy = module.construct(copyOf: access)
        #expect(copy != access)
        #expect(module.span(of: copy) == span(2))
        #expect(module.inferredType(of: copy) == module.types.f32Type)
        #expect(module.constantValue(of: copy) == .float(1.5))
        let copied = module.downcast(FieldAccessExpression.self, copy)
        let original = module.downcast(FieldAccessExpression.self, access)
        #expect(copied.base == original.base)
        #expect(copied.fieldName != original.fieldName)

        // Each entry belongs to one slot: changing the copy's constant leaves the original's.
        module.setConstantValue(.float(2.5), for: copy)
        #expect(module.constantValue(of: access) == .float(1.5))
    }

    // Both overloads log the old slot, constant value included, and the rollback restores it.
    @Test
    func replacementsInsideAScopeAreUndone() {
        var module = makeModule()
        let wrapped = module.construct(span: span(1), ArrayTypeExpression(maybeElementType: nil, maybeElementCount: nil))
        module.setConstantValue(.int32(3), for: wrapped)
        let copied = identifierExpression(&module, "a", 2)
        module.setConstantValue(.int32(4), for: copied)
        let name = identifierOf(module, copied)
        let before = module.snapshot()

        ModuleState.withTestScope(&module) { module in
            let replacement = identifierExpression(&module, "b", 3)
            module.setConstantValue(.int32(5), for: replacement)
            module.replace(wrapped, with: replacement)
            module.replace(copied, with: replacement)
            let z = module.symbols.intern("z")
            module.replace(name, keepingSpanWith: z)
            #expect(module.tag(of: wrapped) == .identityExpression)
            #expect(module.constantValue(of: wrapped) == nil)
            #expect(module.constantValue(of: copied) == .int32(5))
        }
        let a = module.symbols.intern("a")
        #expect(module.snapshot() == before)
        #expect(module.constantValue(of: wrapped) == .int32(3))
        #expect(module.constantValue(of: copied) == .int32(4))
        #expect(module.symbol(of: name) == a)
    }

    // `is`/`downcast` on IndexAccessExpression match only an unchecked access; anyIndexAccess reads both.
    @Test
    func anyIndexAccessReadsAnUncheckedAccess() {
        var module = makeModule()
        let base = identifierExpression(&module, "a", 1)
        let index = module.construct(span: span(2), Unsigned32Literal(value: 1))
        let access = module.construct(span: span(3), IndexAccessExpression(base: base, index: index))
        #expect(module.is(IndexAccessExpression.self, access) == true)
        #expect(module.nodeKind(of: access) == .indexAccessExpression)
        guard let parts = module.anyIndexAccess(access) else {
            Issue.record("not an index access")
            return
        }
        #expect(parts.base == base)
        #expect(parts.index == index)
        #expect(parts.proof == nil)
        #expect(module.anyIndexAccess(base) == nil)
    }
}
