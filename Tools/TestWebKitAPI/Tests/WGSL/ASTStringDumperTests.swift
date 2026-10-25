// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (c) 2022-2026 Apple Inc. All rights reserved.
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

// Each module is built through the IR constructors as `WGSL::parse` leaves its source, and each expected text is what the
// C++ `AST::StringDumper` printed for that source after parsing.

private struct DumpBuilder: ~Copyable {
    var module: ShaderModule

    init(_ source: String) {
        module = ShaderModule(source: SourceText(source), configuration: Configuration(supportedFeatures: [.shaderF16]))
    }

    mutating func name(_ text: String) -> Identifier {
        module.makeIdentifier(module.symbols.intern(ContiguousArray(text.utf16)))
    }

    mutating func identifier(_ text: String) -> ExpressionID {
        module.constructIdentifierExpression(span: .empty, identifier: name(text))
    }

    mutating func int(_ value: Int64) -> ExpressionID {
        module.construct(span: .empty, AbstractIntegerLiteral(value: value))
    }

    mutating func float(_ value: Double) -> ExpressionID {
        module.construct(span: .empty, AbstractFloatLiteral(value: value))
    }

    mutating func unary(_ operation: UnaryOperation, _ operand: ExpressionID) -> ExpressionID {
        module.construct(span: .empty, UnaryExpression(expression: operand, operation: operation))
    }

    mutating func binary(_ operation: BinaryOperation, _ left: ExpressionID, _ right: ExpressionID) -> ExpressionID {
        module.construct(span: .empty, BinaryExpression(leftExpression: left, rightExpression: right, operation: operation))
    }

    mutating func call(_ target: ExpressionID, _ arguments: [ExpressionID]) -> ExpressionID {
        module.construct(span: .empty, CallExpression(target: target, arguments: module.makeList(arguments)))
    }

    mutating func elaborated(_ base: String, _ arguments: [ExpressionID]) -> ExpressionID {
        let base = name(base)
        return module.constructElaboratedTypeExpression(span: .empty, base: base, arguments: module.makeList(arguments))
    }

    mutating func arrayType(_ element: ExpressionID?, _ count: ExpressionID?) -> ExpressionID {
        module.construct(span: .empty, ArrayTypeExpression(maybeElementType: element, maybeElementCount: count))
    }

    mutating func attribute(_ kind: AttributeKind) -> AttributeID {
        module.construct(span: .empty, kind)
    }

    mutating func compound(_ statements: [StatementID]) -> StatementID {
        module.construct(span: .empty, CompoundStatement(attributes: module.makeList([]), statements: module.makeList(statements)))
    }

    mutating func directive(_ severity: SeverityControl, _ rule: TriggeringRule) {
        let directive = module.construct(
            span: .empty,
            .diagnosticDirective(DiagnosticDirective(diagnostic: Diagnostic(severity: severity, triggeringRule: rule)))
        )
        module.append(module.directives, directive)
    }

    @discardableResult
    mutating func variable(
        _ flavor: VariableFlavor,
        _ name: String,
        attributes: [AttributeID] = [],
        qualifier: VariableQualifier? = nil,
        type: ExpressionID? = nil,
        initializer: ExpressionID? = nil
    ) -> VariableID {
        let name = self.name(name)
        return module.constructVariable(
            span: .empty,
            flavor: flavor,
            name: name,
            qualifier: qualifier,
            type: type,
            initializer: initializer,
            attributes: module.makeList(attributes)
        )
    }

    mutating func globalVariable(
        _ flavor: VariableFlavor,
        _ name: String,
        attributes: [AttributeID] = [],
        qualifier: VariableQualifier? = nil,
        type: ExpressionID? = nil,
        initializer: ExpressionID? = nil
    ) {
        let variable = variable(flavor, name, attributes: attributes, qualifier: qualifier, type: type, initializer: initializer)
        module.append(module.declarations, .variable(variable))
    }

    mutating func parameter(_ name: String, _ attributes: [AttributeID], _ type: ExpressionID) -> ParameterID {
        let name = self.name(name)
        return module.constructParameter(
            span: .empty,
            name: name,
            typeName: type,
            attributes: module.makeList(attributes),
            role: .userDefined
        )
    }

    mutating func function(
        _ name: String,
        attributes: [AttributeID] = [],
        parameters: [ParameterID] = [],
        returnAttributes: [AttributeID] = [],
        returnType: ExpressionID? = nil,
        body: [StatementID] = []
    ) {
        let name = self.name(name)
        let body = compound(body)
        let function = module.constructFunction(
            span: .empty,
            name: name,
            parameters: module.makeList(parameters),
            returnType: returnType,
            body: body,
            attributes: module.makeList(attributes),
            returnAttributes: module.makeList(returnAttributes)
        )
        module.append(module.declarations, .function(function))
    }
}

private func dumpNode(_ module: borrowing ShaderModule, _ expression: ExpressionID) -> String {
    var out = StringPrintStream()
    module.dumpNode(expression, into: &out)
    return String(decoding: out.toString().codeUnits, as: UTF16.self)
}

private func toString(_ shaderModule: borrowing ShaderModule) -> String {
    ASTStringDumper.dump(shaderModule)
}

@Suite
struct WGSLASTDumperTests {
    @Test
    func dumpTriangleVert() {
        let source =
            "@vertex\n"
            + "fn main(\n"
            + "    @builtin(vertex_index) VertexIndex : u32\n"
            + ") -> @builtin(position) vec4<f32> {\n"
            + "    var pos = array<vec2<f32>, 3>(\n"
            + "        vec2<f32>(0.0, 0.5),\n"
            + "        vec2<f32>(-0.5, -0.5),\n"
            + "        vec2<f32>(0.5, -0.5)\n"
            + "    );\n\n"
            + "    return vec4<f32>(pos[VertexIndex], 0.0, 1.0);\n"
            + "}\n"
        var shader = ShaderModule(source: SourceText(source), configuration: noFeaturesConfiguration)
        let maybeError = parse(&shader)

        #expect(maybeError == nil)

        #expect(
            toString(shader)
                == "@vertex\n"
                + "fn main(\n"
                + "    @builtin(vertex_index) VertexIndex: u32\n"
                + ") -> @builtin(position) vec4<f32>\n"
                + "{\n"
                + "    var pos = array<vec2<f32>, 3>(vec2<f32>(0.000000, 0.500000), vec2<f32>(-0.500000, -0.500000), vec2<f32>(0.500000, -0.500000));\n"
                + "    return vec4<f32>(pos[VertexIndex], 0.000000, 1.000000);\n"
                + "}\n\n"
        )
    }
}

@Suite
struct WGSLASTStringDumperTests {
    /// Every node kind, including those the dumper leaves to the `AST::Visitor` default traversal (attributes printed as
    /// their bare expressions, loop, switch and while statements without their keywords).
    @Test
    func allNodeKindsAsParsed() {
        #expect(ASTStringDumper.dump(buildAllNodeKinds(afterCheck: false)) == allNodeKindsParseDump)
    }

    @Test
    func literalsDirectivesAndDeclarations() {
        var b = DumpBuilder(literalsSource)
        b.directive(.off, .derivativeUniformity)
        b.directive(.warning, .subgroupUniformity)
        b.globalVariable(.const, "a", initializer: b.unary(.negate, b.float(0.0)))
        b.globalVariable(.const, "b", initializer: b.float(1e300))
        b.globalVariable(.const, "c", initializer: b.module.construct(span: .empty, Float32Literal(value: 0.1)))
        b.globalVariable(.const, "d", initializer: b.module.construct(span: .empty, Float16Literal(value: Half(0.1))))
        b.globalVariable(.const, "e", initializer: b.int(Int64.max))
        b.globalVariable(.const, "f", initializer: b.module.construct(span: .empty, Unsigned32Literal(value: UInt32.max)))
        b.globalVariable(.const, "g", initializer: b.module.construct(span: .empty, Signed32Literal(value: Int32.max)))
        b.globalVariable(.const, "h", initializer: b.module.construct(span: .empty, Float32Literal(value: .greatestFiniteMagnitude)))
        b.globalVariable(.const, "k", initializer: b.call(b.arrayType(nil, nil), [b.int(1), b.int(2)]))
        b.globalVariable(.const, "l", initializer: b.call(b.elaborated("bitcast", [b.identifier("u32")]), [b.float(1.0)]))
        b.globalVariable(.override, "o", attributes: [b.attribute(.idAttribute(IdAttribute(value: b.int(3))))], type: b.identifier("u32"))
        b.globalVariable(
            .var,
            "w",
            qualifier: VariableQualifier(span: .empty, addressSpace: .workgroup, accessMode: .readWrite),
            type: b.arrayType(b.identifier("f32"), b.int(4))
        )
        b.function(
            "f1",
            returnType: b.identifier("i32"),
            body: [b.module.construct(span: .empty, ReturnStatement(maybeExpression: b.int(1)))]
        )
        let compute = b.attribute(.stageAttribute(StageAttribute(stage: .compute)))
        let workgroupSizeX = b.attribute(.workgroupSizeAttribute(WorkgroupSizeAttribute(x: b.int(4), maybeY: nil, maybeZ: nil)))
        b.function("c1", attributes: [compute, workgroupSizeX])
        let computeXY = b.attribute(.stageAttribute(StageAttribute(stage: .compute)))
        let workgroupSizeXY = b.attribute(.workgroupSizeAttribute(WorkgroupSizeAttribute(x: b.int(4), maybeY: b.int(2), maybeZ: nil)))
        b.function("c2", attributes: [computeXY, workgroupSizeXY])
        b.function("\u{F1}")
        let pointer = b.elaborated("ptr", [b.identifier("storage"), b.identifier("f32"), b.identifier("read")])
        b.function("g1", parameters: [b.parameter("p", [], pointer)])

        #expect(ASTStringDumper.dump(b.module) == literalsParseDump)
    }

    /// The kinds the parser never makes: an IdentityExpression prints its expression (the default traversal), a
    /// ReferenceTypeExpression its type and `&`.
    @Test
    func identityAndReferenceType() {
        var b = DumpBuilder("")
        let identity = b.module.constructIdentityExpression(span: .empty, expression: b.identifier("x"))
        let reference = b.module.construct(span: .empty, ReferenceTypeExpression(type: b.elaborated("vec4", [b.identifier("f32")])))
        #expect(ASTStringDumper.dump(b.module, identity) == "x")
        #expect(ASTStringDumper.dump(b.module, reference) == "vec4<f32>&")
        #expect(dumpNode(b.module, reference) == "vec4<f32>&")
    }

    /// `Type::dump` prints an override-sized array's element count through `dumpNode`.
    @Test
    func overrideSizedArrayTypeString() {
        var b = DumpBuilder("")
        let count = b.binary(.add, b.identifier("n"), b.module.construct(span: .empty, Unsigned32Literal(value: 1)))
        let type = b.module.types.arrayType(FixedTypeID.f32, .overrideSized(count))
        #expect(String(decoding: b.module.typeString(type).codeUnits, as: UTF16.self) == "array<f32, n + 1u>")
    }

    /// An identifier longer than 5,000,000 UTF-8 bytes prints as `PrintStream` truncates a string.
    @Test
    func longIdentifierIsTruncatedAsPrintStreamDoes() {
        var b = DumpBuilder("")
        let identifier = b.identifier(String(repeating: "a", count: 5_000_001))
        #expect(dumpNode(b.module, identifier) == String(repeating: "a", count: 1000) + "...[4999001 characters not shown]")
    }

    /// The parser builds binary and postfix chains in loops, so their left operands nest without bound; at -Onone a
    /// recursion per level overflowed an 8 MiB stack on `stress/binary_chain/binary_chain-20000.wgsl`.
    @Test
    func deepLeftNestedChains() {
        var b = DumpBuilder("")
        var sum = b.identifier("a")
        var access = b.identifier("v")
        var n = 0
        while n < 20_000 {
            sum = b.binary(.add, sum, b.identifier("a"))
            access = b.module.constructFieldAccessExpression(span: .empty, base: access, fieldName: b.name("x"))
            access = b.module.construct(span: .empty, IndexAccessExpression(base: access, index: b.int(0)))
            n += 1
        }
        let product = b.binary(.multiply, access, b.binary(.subtract, sum, b.identifier("c")))
        let sumText = "a" + String(repeating: " + a", count: 20_000)
        let accessText = "v" + String(repeating: ".x[0]", count: 20_000)
        #expect(dumpNode(b.module, sum) == sumText)
        #expect(dumpNode(b.module, access) == accessText)
        #expect(dumpNode(b.module, product) == accessText + " * " + sumText + " - c")
    }
}

// The C++ `AST::StringDumper` text of `allNodeKindsSource` after parsing.
private let allNodeKindsParseDump = """
    diagnostic(off, derivative_uniformity)

    alias Scalar = f32;
    1 < 2
    struct Data {
        16 32 value: vec4<f32>,
        items: array<u32, 4>
    }

    struct VertexOut {
        @builtin(position)  position: vec4f,
        @location(0)  id: u32
    }

    @group(0) @binding(0) var<storage,read_write> data: Data;
    7 var scale: Scalar = 1.000000;
    var<private,read_write> counter: i32 = 1i;

    fn helper(
        a: f32
        b: ptr<function, f32>
    ) ->  f32
    {
        return a + *b;
    }

    fn noop()
    {}

    @diagnostic(off, derivative_uniformity) @fragment
    fn fs(
        @location(0)  id: u32
    ) -> @location(0) vec4f
    {
        if id == 0u
        {

        }

        return vec4f(scale);
    }

    @vertex
    fn vs(
        @builtin(vertex_index) index: u32
    ) ->  VertexOut
    {
        var out: VertexOut;
        out.position = vec4f(0.000000);
        out.id = index;
        return out;
    }

    @compute @workgroup_size(8, 1, 1)
    fn cs(
        @builtin(local_invocation_index) lid: u32
    )
    {
        var x: f32 = 1.000000f;
        var y = helper(x, &x);
        var z = 2.000000;
        var h: f16 = 1h;
        var arr = array<i32, 2>(1, -2);
        var p = &x;
        *p = 2.000000;
        x += y * z;
        counter++;
        _ = h;
        _ = !true;
        data.items[0] = lid + 1u;
    for (    var i = 0;;i < 4;    i++;)    {
            if i == 1
            {

            }
            else         if i == 2
            {

            }
            else
            {}

        }

    @diagnostic(off, derivative_uniformity)    counter--;@diagnostic(off, derivative_uniformity)counter < 0
    counter < 2    {
            counter = counter + 1;
        }

    counter@diagnostic(off, derivative_uniformity)01    {
            counter = arr[1];
        }
        {}

        {
    true
        }

    noop();
    }


    """

// The source `literalsDirectivesAndDeclarations` builds.
private let literalsSource = """
    enable f16;
    diagnostic(off, derivative_uniformity);
    diagnostic(warning, subgroup_uniformity);
    const a = -0.0;
    const b = 1e300;
    const c = 0.1f;
    const d = 0.1h;
    const e = 9223372036854775807;
    const f = 4294967295u;
    const g = 2147483647i;
    const h = 3.4028234663852886e38f;
    const k = array(1, 2);
    const l = bitcast<u32>(1.0);
    @id(3) override o: u32;
    var<workgroup> w: array<f32, 4>;
    fn f1() -> i32 { return 1; }
    @compute @workgroup_size(4) fn c1() {}
    @compute @workgroup_size(4, 2) fn c2() {}
    fn ñ() {}
    fn g1(p: ptr<storage, f32, read>) {}

    """

// The C++ `AST::StringDumper` text of `literalsSource` after parsing.
private let literalsParseDump = """
    diagnostic(off, derivative_uniformity)diagnostic(warning, subgroup_uniformity)

    var a = -0.000000;
    var b = 1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000;
    var c = 0.100000f;
    var d = 0.099975586h;
    var e = 9223372036854775807;
    var f = 4294967295u;
    var g = 2147483647i;
    var h = 340282346638528859811704183484516925440.000000f;
    var k = array(1, 2);
    var l = bitcast<u32>(1.000000);
    3 var o: u32;
    var<workgroup,read_write> w: array<f32, 4>;
    fn f1() ->  i32
    {
        return 1;
    }

    @compute @workgroup_size(4)
    fn c1()
    {}

    @compute @workgroup_size(4, 2)
    fn c2()
    {}

    fn ñ()
    {}

    fn g1(
        p: ptr<storage, f32, read>
    )
    {}


    """
