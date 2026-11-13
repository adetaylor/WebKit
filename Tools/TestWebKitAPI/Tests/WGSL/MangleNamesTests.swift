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

// Each expected text is what the C++ `AST::StringDumper` printed for the same source after mangleNames; on these sources the
// C++ AST before mangleNames dumps the same as the parser's output.

/// Types the base of every field access from the structure that declares the field.
///
/// The field is found by its source name; the type is the structure's, wrapped as `parsedModule`'s `wrapping` says. That
/// is the only type information NameManglerVisitor reads.
private struct FieldBaseTyper: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var baseTypes: [Symbol: TypeID] = [:]

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ access: FieldAccessExpression, _ id: ExpressionID) {
        visitChildren(access, id)
        if let type = baseTypes[shaderModule.symbol(of: access.fieldName)] {
            shaderModule.setInferredType(type, for: access.base)
        }
    }
}

private enum BaseWrapping: CaseIterable {
    case none
    case reference
    case pointer
    case referenceToPointer
    case pointerToReference
    case untyped

    /// NameManglerVisitor strips one reference, then one pointer (MangleNames.cpp:163-167).
    var reachesTheStructure: Bool {
        switch self {
        case .none, .reference, .pointer, .referenceToPointer: true
        case .pointerToReference, .untyped: false
        }
    }
}

private func wrap(_ module: inout ShaderModule, _ type: TypeID, _ wrapping: BaseWrapping) -> TypeID? {
    switch wrapping {
    case .none:
        return type
    case .reference:
        return module.types.referenceType(.function, type, .readWrite)
    case .pointer:
        return module.types.pointerType(.function, type, .readWrite)
    case .referenceToPointer:
        let pointer = module.types.pointerType(.function, type, .readWrite)
        return module.types.referenceType(.function, pointer, .readWrite)
    case .pointerToReference:
        let reference = module.types.referenceType(.function, type, .readWrite)
        return module.types.pointerType(.function, reference, .readWrite)
    case .untyped:
        return nil
    }
}

private func parsedModule(_ source: String, wrapping: BaseWrapping = .reference) -> ShaderModule {
    var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
    if let failure = parse(&module) {
        logCompilationError(failure)
    }
    var baseTypes: [Symbol: TypeID] = [:]
    for declaration in module.elements(module.declarations) {
        guard case .structure(let structure) = declaration else {
            continue
        }
        let structType = module.types.structType(structure)
        let baseType = wrap(&module, structType, wrapping)
        for member in module.elements(module[structure].members) {
            baseTypes[module.symbol(of: module[member].name)] = baseType
        }
    }
    var typer = FieldBaseTyper(shaderModule: module)
    typer.baseTypes = baseTypes
    typer.visitShaderModule()
    return typer.shaderModule
}

private func mangled(_ source: String, wrapping: BaseWrapping = .reference) -> String {
    var module = parsedModule(source, wrapping: wrapping)
    mangleNames(&module)
    return ASTStringDumper.dump(module)
}

private func text(_ module: borrowing ShaderModule, _ symbol: Symbol) -> String {
    String(decoding: module.symbols.codeUnits(of: symbol), as: UTF16.self)
}

private func text(_ module: borrowing ShaderModule, _ identifier: IdentifierID) -> String {
    text(module, module.symbol(of: identifier))
}

/// The first statement of the body of the module's `index`-th declaration, a function.
private func firstStatement(_ module: borrowing ShaderModule, ofFunction index: Int) -> StatementID? {
    guard case .function(let function) = module[module.declarations, index],
        case .compoundStatement(let body) = module[module[function].body].kind,
        module.count(body.statements) > 0
    else {
        return nil
    }
    return module[body.statements, 0]
}

@Suite
struct WGSLMangleNamesTests {
    @Test
    func matchesTheCxxDump() {
        let source =
            """
            struct S {
              a: i32,
              b: vec2<f32>,
            }

            struct T {
              s: S,
              c: array<S, 2>,
            }

            var<private> g: T;
            @group(0) @binding(0) var<storage, read_write> out: array<i32>;

            fn helper(x: i32, p: ptr<private, T>) -> i32 {
              let y = x + (*p).s.a;
              var t: T;
              t.s.a = y;
              return t.s.a + g.c[1].a;
            }

            @compute @workgroup_size(1)
            fn main() {
              var x = 1;
              {
                let x = 2;
                out[0] = helper(x, &g);
              }
              for (var i = 0; i < 2; i++) {
                let s = S(i, vec2<f32>(1.0, 2.0));
                out[i] = s.a + x;
              }
            }
            """
        let expected =
            """
            struct type0 {
                field0: i32,
                field1: vec2<f32>
            }

            struct type1 {
                field2: type0,
                field3: array<type0, 2>
            }

            var<private,read_write> global0: type1;
            @group(0) @binding(0) var<storage,read_write> global1: array<i32>;
            fn function0(
                parameter0: i32
                parameter1: ptr<private, type1>
            ) ->  i32
            {
                var local0 = parameter0 + *parameter1.field2.field0;
                var local1: type1;
                local1.field2.field0 = local0;
                return local1.field2.field0 + global0.field3[1].field0;
            }

            @compute @workgroup_size(1)
            fn function1()
            {
                var local2 = 1;
                {
                    var local3 = 2;
                    global1[0] = function0(local3, &global0);
                }

            for (    var local4 = 0;;local4 < 2;    local4++;)    {
                    var local5 = type0(local4, vec2<f32>(1.000000, 2.000000));
                    global1[local4] = local5.field0 + local2;
                }

            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func functionHookIntroducesTheNameBeforeTheBodyIsVisited() {
        let source =
            """
            fn f() {
            }

            fn g() {
              f();
            }
            """
        let expected =
            """
            fn function0()
            {}

            fn function1()
            {
            function0();
            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func parameterHookVisitsTheTypeBeforeIntroducingTheName() {
        let source =
            """
            struct S {
              a: i32,
            }

            fn f(S: S, y: i32) -> i32 {
              return S.a + y;
            }
            """
        let expected =
            """
            struct type0 {
                field0: i32
            }

            fn function0(
                parameter0: type0
                parameter1: i32
            ) ->  i32
            {
                return parameter0.field0 + parameter1;
            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func variableStatementHookIntroducesALocalAfterItsInitializer() {
        let source =
            """
            fn f() {
              let x = 1;
              {
                let x = x + 1;
                _ = x;
              }
              _ = x;
              for (var i = 0; i < 2; i++) {
                var x = i;
                _ = x;
              }
            }
            """
        let expected =
            """
            fn function0()
            {
                var local0 = 1;
                {
                    var local1 = local0 + 1;
                    _ = local1;
                }

                _ = local0;
            for (    var local2 = 0;;local2 < 2;    local2++;)    {
                    var local3 = local2;
                    _ = local3;
                }

            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func variableHookManglesGlobalsButTypeAliasesKeepTheirNames() {
        let source =
            """
            var<private> g: i32;
            const c = 2;
            override o: i32 = 1;
            alias A = i32;

            fn f() -> A {
              var a: A = g + c + o;
              return a;
            }
            """
        let expected =
            """
            var<private,read_write> global0: i32;
            var global1 = 2;
            var global2: i32 = 1;
            alias A = i32;
            fn function0() ->  A
            {
                var local0: A = global0 + global1 + global2;
                return local0;
            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func identifierExpressionHookKeepsNamesThatNoDeclarationIntroduced() {
        let source =
            """
            fn f() -> f32 {
              let v = vec2<f32>(1.0, 2.0);
              return max(v.x, 2.0) + v.y;
            }
            """
        let expected =
            """
            fn function0() ->  f32
            {
                var local0 = vec2<f32>(1.000000, 2.000000);
                return max(local0.x, 2.000000) + local0.y;
            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func sourceNamesThatSpellMangledNamesAreRenamedToo() {
        let source =
            """
            fn function1() -> i32 {
              let local1 = 1;
              let local0 = local1;
              return local0;
            }
            """
        let expected =
            """
            fn function0() ->  i32
            {
                var local0 = 1;
                var local1 = local0;
                return local1;
            }


            """
        #expect(mangled(source) == expected)
    }

    @Test
    func structureHookManglesTheTypeAndEachFieldAfterItsType() {
        var module = parsedModule(
            """
            struct S {
              a: i32,
            }

            struct T {
              b: S,
              c: array<S, 2>,
            }
            """
        )
        mangleNames(&module)
        guard case .structure(let t) = module[module.declarations, 1] else {
            Issue.record("T is not a structure")
            return
        }
        #expect(text(module, module[t].name) == "type1")
        var fields: [String] = []
        var originals: [String] = []
        for member in module.elements(module[t].members) {
            fields.append(text(module, module[member].name))
            originals.append(text(module, module[member].originalName))
        }
        #expect(fields == ["field1", "field2"])
        #expect(originals == ["b", "c"])
        let dump = ASTStringDumper.dump(module)
        #expect(dump.contains("field1: type0,"))
        #expect(dump.contains("field2: array<type0, 2>"))
    }

    @Test
    func fieldAccessHookStripsOneReferenceThenOnePointer() {
        let source = """
            struct S {
              a: i32,
            }

            fn f(s: S) -> i32 {
              return s.a;
            }
            """
        for wrapping in BaseWrapping.allCases {
            let expectedField = wrapping.reachesTheStructure ? "field0" : "a"
            #expect(mangled(source, wrapping: wrapping).contains("return parameter0.\(expectedField);"), "\(wrapping)")
        }
    }

    @Test
    func fieldAccessHookRenamesOnlyTheFieldName() {
        var module = parsedModule(
            """
            struct S {
              a: i32,
            }

            fn f(s: S) -> i32 {
              return s.a;
            }
            """
        )
        mangleNames(&module)
        guard let statement = firstStatement(module, ofFunction: 1),
            case .returnStatement(let returnStatement) = module[statement].kind,
            let value = returnStatement.maybeExpression,
            case .fieldAccessExpression(let access) = module[value].kind
        else {
            Issue.record("no field access")
            return
        }
        #expect(text(module, access.fieldName) == "field0")
        #expect(text(module, access.originalFieldName) == "a")
    }

    @Test
    func everyIntroducedNameIsMintedAsMangled() {
        var module = parsedModule(
            """
            struct S {
              a: i32,
            }

            var<private> g: S;

            fn f(p: i32) -> i32 {
              let l = p + g.a;
              return l;
            }
            """
        )
        mangleNames(&module)
        guard case .structure(let s) = module[module.declarations, 0],
            case .variable(let g) = module[module.declarations, 1],
            case .function(let f) = module[module.declarations, 2],
            let statement = firstStatement(module, ofFunction: 2),
            case .variableStatement(let local) = module[statement].kind
        else {
            Issue.record("unexpected declarations")
            return
        }
        let member = module[module[s].members, 0]
        let parameter = module[module[f].parameters, 0]
        let names = [
            module[s].name, module[member].name, module[g].name, module[f].name, module[parameter].name, module[local.variable].name,
        ]
        #expect(names.map { text(module, $0) } == ["type0", "field0", "global0", "function0", "parameter0", "local0"])
        for name in names {
            #expect(module.symbols.provenance(of: module.symbol(of: name)) == .mangled)
        }
        #expect(text(module, module[g].originalName) == "g")
        #expect(text(module, module[f].originalName) == "f")
    }
}
