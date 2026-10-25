// swift-format-ignore-file: AlwaysUseLowerCamelCase
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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
import WGSL

private func makeString(_ parts: String...) -> String {
    parts.joined()
}

@Suite
struct WGSLMetalCompilationTests {
    @Test
    func Empty() {
        testCompilation("")
    }

    @Test
    func ReturnTypePromotion() {
        testCompilation(
            "fn testScalarPromotion() -> f32"
                + "{"
                + "    return 0;"
                + "}"

                + "fn testVectorPromotion() -> vec3f"
                + "{"
                + "    return vec3(0);"
                + "}"

                + "@compute"
                + "@workgroup_size(1, 1, 1)"
                + "fn main() {"
                + "    _ = testScalarPromotion();"
                + "    _ = testVectorPromotion();"
                + "}"
        )
    }

    @Test
    func ConstantFunctionNotInOutput() {
        testCompilation(
            "@compute @workgroup_size(1)"
                + "fn main()"
                + "{"
                + "  const a = pow(2, 2);"
                + "  _ = a;"
                + "}",
            checkNot("pow\\(.*\\)"),
            checkNot("float .* = \\d"),
            checkLiteral("(void)(4.)")
        )
    }

    @Test
    func BuiltinAliases() {
        testCompilation(file("aliases.wgsl"))
    }

    @Test
    func AccessExpression() {
        testCompilation(file("access-expression.wgsl"))
    }

    @Test
    func ArrayAliasConstructor() {
        testCompilation(file("array-alias-constructor.wgsl"))
    }

    @Test
    func ArrayCountExpression() {
        testCompilation(file("array-count-expression.wgsl"))
    }

    @Test
    func ArrayLengthPointer() {
        testCompilation(file("array-length-pointer.wgsl"))
    }

    @Test
    func ArrayLengthPointer2() {
        testCompilation(file("array-length-pointer2.wgsl"))
    }

    @Test
    func ArrayLengthUnorderd() {
        testCompilation(file("array-length-unordered.wgsl"))
    }

    @Test
    func ArrayLength() {
        testCompilation(file("array-length.wgsl"))
    }

    @Test
    func ArrayPrimitiveStruct() {
        testCompilation(file("array-primitive-struct.wgsl"))
    }

    @Test
    func ArrayVec3() {
        testCompilation(file("array-vec3.wgsl"))
    }

    @Test
    func Atomics() {
        testCompilation(file("atomics.wgsl"))
    }

    @Test
    func Attributes() {
        testCompilation(file("attributes.wgsl"))

        testCompilation(
            "struct S { @builtin(position) @invariant value : vec4f };"
                + "@vertex fn main() -> S { return S(vec4<f32>()); }",
            checkLiteral("[[invariant]]")
        )

        testCompilation(
            "@vertex fn main() -> @invariant @builtin(position) vec4<f32> { return vec4<f32>(); }",
            checkLiteral("[[invariant]]")
        )
    }

    @Test
    func BindingUIntMax() {
        testCompilation(file("binding-uint-max.wgsl"))
    }
    @Test
    func Concretization() {
        // Test variable inialization
        testCompilation(
            fn(
                "let x1: u32 = 0;"
                    + "let x2: vec2<u32> = vec2(0, 0);"
                    + "let x3: f32 = 0;"
                    + "let x4: f32 = 0.0;"
                    + "var v1 = vec2(0.0);"
                    + "v1 = vec2f(0);"
            )
        )

        // Test concretization of arguments
        testCompilation(fn("let x = 0u + vec2(0, 0);"), checkLiteral("= vec<unsigned, 2>(0u, 0u);"))
        testCompilation(fn("let x = 0i + vec2(0, 0);"), checkLiteral("= vec<int, 2>(0, 0);"))
        testCompilation(fn("let x = 0f + vec2(0, 0);"), checkLiteral("= vec<float, 2>(0., 0.);"))

        // Test array concretization
        testCompilation(fn("let x = array<vec2<i32>, 1>(vec2(0, 0));"), checkLiteral("vec<int, 2>(0, 0)"))
        testCompilation(fn("let x = array<vec2<f32>, 1>(vec2(0, 0));"), checkLiteral("vec<float, 2>(0., 0.)"))
        testCompilation(
            fn("let x = array(vec2(0, 0), vec2(0.0, 0.0));"),
            checkLiteral("vec<float, 2>(0., 0.),"),
            checkLiteral("vec<float, 2>(0., 0.),")
        )
        testCompilation(
            fn("let x = array(vec2(0, 0), vec2(0u, 0u));"),
            checkLiteral("vec<unsigned, 2>(0u, 0u),"),
            checkLiteral("vec<unsigned, 2>(0u, 0u),")
        )

        // Test initializer concretization
        testCompilation(fn("let x = vec2(0, 0);"), checkLiteral(" = vec<int, 2>(0, 0);"))
        testCompilation(fn("let x : vec2<u32> = vec2(0, 0);"), checkLiteral(" = vec<unsigned, 2>(0u, 0u);"))

        // Test atomic materialization
        testCompilation(
            "@group(0) @binding(0) var<storage, read_write> a: array<atomic<i32>>;"
                + "@compute @workgroup_size(1)"
                + "fn testArrayAccessMaterialization()"
                + "{"
                + "    let i = 0;"
                + "    let x = atomicLoad(&a[i]);"
                + "}"
        )
    }

    @Test
    func ConstAssert() {
        testCompilation(file("const-assert.wgsl"))
    }

    @Test
    func ConstantMatrix() {
        testCompilation(
            fn(
                "let x = determinant(mat4x4("
                    + "    15,2,34,4,"
                    + "    18,2,3,4,"
                    + "    1,72,32,4,"
                    + "    17,2,3,4,"
                    + "));"
            ),
            checkLiteral("8680")
        )

        testCompilation(
            fn(
                "let y = determinant(mat4x4("
                    + "    vec4(15,2,34,4),"
                    + "    vec4(18,2,3,4),"
                    + "    vec4(1,72,32,4),"
                    + "    vec4(17,2,3,4),"
                    + "));"
            ),
            checkLiteral("8680")
        )

        testCompilation(
            fn(
                "const m2 = mat2x2("
                    + "  1,2,"
                    + "  3,4,"
                    + ");"
                    + "let tm2 = transpose(m2);"
            ),
            checkLiteral("1., 3., 2., 4.")
        )

        testCompilation(
            fn(
                "let tm3 = transpose(mat3x3("
                    + "    1,2,3,"
                    + "    4,5,6,"
                    + "    7,8,9,"
                    + "));"
            ),
            checkLiteral("1., 4., 7., 2., 5., 8., 3., 6., 9.")
        )

        testCompilation(
            fn(
                "const m2 = mat2x2("
                    + "  1,2,"
                    + "  3,4,"
                    + ");"
                    + "let x0 = m2 * 2;"
            ),
            checkLiteral("2., 4., 6., 8.")
        )

        testCompilation(
            fn(
                "const m2x3 = mat2x3("
                    + "    1,2,3,"
                    + "    4,5,6"
                    + ");"
                    + "let x1 = transpose(m2x3);"
            ),
            checkLiteral("1., 4., 2., 5., 3., 6.")
        )

        testCompilation(
            fn(
                "const m2x3 = mat2x3("
                    + "    1,2,3,"
                    + "    4,5,6"
                    + ");"
                    + "let x2 = m2x3 * vec2(2);"
            ),
            checkLiteral("10., 14., 18.")
        )

        testCompilation(
            fn(
                "const m2x3 = mat2x3("
                    + "    1,2,3,"
                    + "    4,5,6"
                    + ");"
                    + "let x3 = vec3(2) * m2x3;"
            ),
            checkLiteral("12., 30.")
        )

        testCompilation(
            fn(
                "let x4 = dot(vec3(1,2,3), vec3(4,5,6));"
            ),
            checkLiteral("32")
        )

        testCompilation(
            fn(
                "let x5 = mat3x2(1,2,3,4,5,6) * mat4x3(12,11,10,9,8,7,6,5,4,3,2,1);"
            ),
            checkLiteral("95., 128., 68., 92., 41., 56., 14., 20.")
        )
    }

    @Test
    func ConstantsUtf16() {
        testCompilation(file("constants-utf16.wgsl"))
    }

    @Test
    func ConstantsUtf8() {
        testCompilation(file("constants-utf8.wgsl"))
    }

    @Test
    func Division() {
        testCompilation(file("division.wgsl"))
    }

    @Test
    func For() {
        testCompilation(file("for.wgsl"))
    }

    @Test
    func FragmentOutput() {
        testCompilation(file("fragment-output.wgsl"))
    }

    @Test
    func FuzzerTests() {
        testCompilation(file("fuzz-127229681.wgsl"))
        testCompilation(file("fuzz-128785160.wgsl"))
        testCompilation(file("fuzz-130082002.wgsl"))
        testCompilation(file("fuzz-130088292.wgsl"))
        testCompilation(file("fuzz-130092499.wgsl"))
        testCompilation(file("fuzz-166715941.wgsl"))
    }

    @Test
    func GlobalConstantVector() {
        testCompilation(
            file("global-constant-vector.wgsl"),
            check("vec<float, 4> local0 = vec<float, 4>\\(0\\., 0\\., 0\\., 0\\.\\)"),
            check("\\(void\\)\\(local\\d+\\[__wgslMin\\(unsigned\\(0\\), \\(4u - 1u\\)\\)\\]")
        )
    }

    @Test
    func GlobalOrdering() {
        testCompilation(file("global-ordering.wgsl"))
    }

    @Test
    func GlobalSameBinding() {
        testCompilation(file("global-same-binding.wgsl"))
    }

    @Test
    func InlineLargeAggregateReturns() {
        let shader = makeString(
            "struct Big { v : array<vec4<u32>, 8> }"
                + "struct Small { v : array<vec4<u32>, 2> }"
                + "@group(0) @binding(0) var<storage, read> input : array<Big>;"
                + "@group(0) @binding(1) var<storage, read_write> output : array<Big>;"
                + "fn combineBig(a : Big, b : Big) -> Big { var r = a; for (var i = 0u; i < 8u; i++) { r.v[i] += b.v[i]; } return r; }"
                + "fn combineSmall(a : Small, b : Small) -> Small { var r = a; for (var i = 0u; i < 2u; i++) { r.v[i] += b.v[i]; } return r; }"
                + "fn sumBig(a : Big) -> u32 { var r = 0u; for (var i = 0u; i < 8u; i++) { r += a.v[i].x; } return r; }",
            fn(
                "var acc = input[0];"
                    + "var small = Small(array<vec4<u32>, 2>(input[0].v[0], input[0].v[1]));"
                    + "for (var i = 1u; i < 4u; i++) { acc = combineBig(acc, input[i]); small = combineSmall(small, small); }"
                    + "acc.v[0].x += sumBig(acc) + small.v[0].x;"
                    + "output[0] = acc;"
            )
        )

        testCompilationForAppleGPUFamily(
            8,
            shader,
            checkNotLiteral("__attribute__((always_inline)) type0 function0")
        )

        testCompilationForAppleGPUFamily(
            9,
            shader,
            checkLiteral("__attribute__((always_inline)) type0 function0"),
            checkNotLiteral("__attribute__((always_inline)) type1 function1"),
            checkNotLiteral("__attribute__((always_inline)) unsigned function2")
        )
    }

    @Test
    func GlobalUsedByCallee() {
        testCompilation(
            makeString(
                "var<private> x: i32;",
                fn("_ = x;")
            ),
            check("int global\\d")
        )

        testCompilation(
            makeString(
                "var<private> y: i32;"
                    + "fn f() -> i32 { _ = y; return 0; }",
                fn("_ = f();")
            ),
            check("int function\\d\\(thread int& global\\d\\)"),
            check("global\\d\\)"),
            check("return 0;"),
            check("function\\d\\(global\\d\\)")
        )

        testCompilation(
            makeString(
                "var<private> y: i32;"
                    + "fn g() -> i32 { let y = 42; return y; }",
                fn("_ = g();")
            ),
            check("int function\\d\\(\\)"),
            checkNot("global\\d\\)"),
            check("return local\\d;"),
            check("function\\d\\(\\)")
        )

        testCompilation(
            makeString(
                "var<private> y: i32;"
                    + "override z = 42;"
                    + "fn h() -> i32 { _ = y; _ = z; return 0; }",
                fn("_ = h();")
            ),
            check("int function\\d\\(thread int& global\\d, int global\\d\\)"),
            check("global\\d\\)"),
            check("return 0;"),
            check("function\\d\\(global\\d, \\(42\\)\\)")
        )

        testCompilation(
            makeString(
                "var<private> y: i32;"
                    + "fn f() -> i32 { _ = y; return 0; }"
                    + "fn i() -> i32 { _ = f(); return 0; }",
                fn("_ = i();")
            ),
            check("int function\\d\\(thread int& global\\d\\)"),
            check("global\\d\\)"),
            check("int function\\d\\(thread int& global\\d\\)"),
            check("function\\d\\(global\\d\\)"),
            check("return 0;"),
            check("function\\d\\(global\\d\\)")
        )

        testCompilation(
            makeString(
                "var<private> y: i32;"
                    + "fn f() -> i32 { _ = y; return 0; }"
                    + "fn j(x: f32) -> f32 { _ = f(); return x; }",
                fn("_ = j(j(42));")
            ),
            check("int function\\d\\(thread int& global\\d\\)"),
            check("global\\d\\)"),
            check("float function\\d\\(float parameter\\d, thread int& global\\d\\)"),
            check("function\\d\\(global\\d\\)"),
            check("return parameter\\d;"),
            check("function\\d\\(function\\d\\(42., global\\d\\), global\\d\\)")
        )
    }

    @Test
    func HexDoubleLChar() {
        testCompilation(
            file("hex-double-lchar.wgsl"),
            checkLiteral("1.1754943508222875e-38"),
            checkLiteral("3.4028234663852886e+38")
        )
    }

    @Test
    func HexDoubleUChar() {
        testCompilation(
            file("hex-double-uchar.wgsl"),
            checkLiteral("1.1754943508222875e-38"),
            checkLiteral("3.4028234663852886e+38")
        )
    }

    @Test
    func If() {
        testCompilation(file("if.wgsl"))
    }

    @Test
    func LargeStruct() {
        expectPrepareError(file("large-struct.wgsl"), "The combined byte size of all variables in this function exceeds 8192 bytes")
    }

    @Test
    func Limits() {
        expectPrepareError(file("limits-function-vars.wgsl"), "The combined byte size of all variables in this function exceeds 8192 bytes")

        // These can depend on overrides, so they are only checked at generation time
        expectGenerateError(
            file("limits-private-vars.wgsl"),
            "The combined byte size of all variables in the private address space exceeds 8192 bytes"
        )
        expectGenerateError(
            file("limits-workgroup-vars.wgsl"),
            "The combined byte size of all variables in the workgroup address space exceeds 16384 bytes"
        )
    }

    @Test
    func LocalConstantVector() {
        testCompilation("@fragment fn main() { const a = vec2(0); _ = a; }", checkLiteral("(void)(vec<int, 2>(0, 0))"))
    }

    @Test
    func Loop() {
        testCompilation(file("loop.wgsl"))
    }

    @Test
    func MinusMinusAmbiguity() {
        testCompilation(file("minus-minus-ambiguity.wgsl"))
    }

    @Test
    func NameMangling() {
        testCompilation(
            file("name-mangling.wgsl"),
            checkNotLiteral("MyStruct1"),
            checkNotLiteral("myStructField1"),
            checkNotLiteral("MyStruct2"),
            checkNotLiteral("myStructField2"),
            checkNotLiteral("myGlobal1"),
            checkNotLiteral("myGlobal2"),
            checkNotLiteral("myHelperFunction"),
            checkNotLiteral("myComputeEntrypoint")
        )
    }

    @Test
    func Overload() {
        testCompilation(file("overload.wgsl"))
    }

    @Test
    func Override() {
        expectGenerateError(file("override.wgsl"), "array count must be greater than 0")
    }

    @Test
    func OverrideComplexExpression() {
        testCompilation(file("override-complex-expression.wgsl"))
    }

    @Test
    func OverrideShortCircuit() {
        func shader(_ condition: String, _ operation: String) -> String {
            makeString(
                "override cond = ",
                condition,
                ";"
                    + "override shift = 32u;"
                    + "@compute @workgroup_size(1) "
                    + "fn main(@builtin(local_invocation_index) tid: u32) {"
                    + "    var r = 0u;"
                    + "    if (cond ",
                operation,
                " ((tid << shift) == 0u)) { r = 1u; }"
                    + "    _ = r;"
                    + "}"
            )
        }
        let shiftError = "shift left value must be less than the bit width of the shifted value, which is 32"

        expectGenerateError(shader("true", "&&"), shiftError)
        expectGenerateError(shader("false", "||"), shiftError)

        expectNoGenerateError(shader("false", "&&"))
        expectNoGenerateError(shader("true", "||"))

        expectNoGenerateError(
            "override shift = 32u;"
                + "@compute @workgroup_size(1) "
                + "fn main(@builtin(local_invocation_index) tid: u32) {"
                + "    var r = 0u;"
                + "    if (false && ((tid << shift) == 0u)) { r = 1u; }"
                + "    _ = r;"
                + "}"
        )

        expectGenerateError(
            "override cond = true;"
                + "override shift = 32u;"
                + "@compute @workgroup_size(1) "
                + "fn main(@builtin(local_invocation_index) tid: u32) {"
                + "    var r = 0u;"
                + "    if (cond && (cond && ((tid << shift) == 0u))) { r = 1u; }"
                + "    _ = r;"
                + "}",
            shiftError
        )
    }

    @Test
    func PackUnpack() {
        testCompilation(
            file("pack-unpack.wgsl"),
            check("1., 0.50\\d*, -0.49\\d*, -1."),
            check("1., 0.50\\d*, 0.25\\d*, 0."),
            check("-128, 127, -128, 127"),
            check("0u, 255u, 128u, 64u"),
            check("127, 127, -128, -128"),
            check("255u, 255u, 128u, 64u"),
            check("0.50\\d*, -0.49\\d*"),
            check("0.50\\d*, 0."),
            check("0.5, -0.5")
        )
    }

    @Test
    func Packing() {
        func prologue(_ wgsl: String) -> String {
            makeString(
                "struct Unpacked {"
                    + "  x: i32,"
                    + "}"
                    + "struct T {"
                    + "    v2f: vec2<f32>,"
                    + "    v3f: vec3<f32>,"
                    + "    v4f: vec4<f32>,"
                    + "    v2u: vec2<u32>,"
                    + "    v3u: vec3<u32>,"
                    + "    v4u: vec4<u32>,"
                    + "    f: f32,"
                    + "    u: u32,"
                    + "    unpacked: Unpacked,"
                    + "}"
                    + "struct U {"
                    + "    ts: array<T>,"
                    + "}"
                    + "var<private> t: T;"
                    + "var<private> m2: mat2x2<f32>;"
                    + "var<private> m3: mat3x3<f32>;"
                    + "@group(0) @binding(0) var<storage, read_write> t1: T;"
                    + "@group(0) @binding(1) var<storage, read_write> t2: T;"
                    + "@group(0) @binding(2) var<storage, read_write> v1: vec3<f32>;"
                    + "@group(0) @binding(3) var<storage, read_write> v2: vec3<f32>;"
                    + "@group(0) @binding(4) var<storage, read_write> at1: array<T, 2>;"
                    + "@group(0) @binding(5) var<storage, read_write> at2: array<T, 2>;"
                    + "@group(0) @binding(6) var<storage, read_write> av1: array<vec3f, 2>;"
                    + "@group(0) @binding(7) var<storage, read_write> av2: array<vec3f, 2>;"
                    + "@group(0) @binding(8) var<storage, read_write> u1: U;",
                wgsl
            )
        }

        testCompilation(prologue("struct U2 { ts: array<T> }"), check("array<__PackedType<type\\d>, 1> field\\d"))

        testCompilation(
            prologue(
                fn(
                    "{ let x = t.v3f * m3; }"
                        + "{ let x = m3 * t.v3f; }"
                        + "{ let x = t1.v2f * m2; }"
                        + "{ let x = m2 * t1.v2f; }"
                        + "{ let x = u1.ts[0].v3f * m3; }"
                        + "{ let x = m3 * u1.ts[0].v3f; }"
                        + "{ let x = av1[0] * m3; }"
                )
            )
        )

        // Test packed struct assignment
        testCompilation(
            prologue(
                fn(
                    "var t = t1;"
                        + "t = t1;"
                        + "t1 = t2;"
                        + "t2 = t;"
                )
            ),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("global\\d+ = global\\d+;"),
            check("global\\d+ = __pack\\(local\\d+\\);")
        )

        // Test array of packed structs assignment
        testCompilation(
            prologue(
                fn(
                    "var at = at1;"
                        + "at = at1;"
                        + "at1 = at2;"
                        + "at2 = at;"
                )
            ),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("global\\d+ = global\\d+;"),
            check("global\\d+ = __pack\\(local\\d+\\);")
        )

        // Test array of vec3 assignment
        testCompilation(
            prologue(
                fn(
                    "var av = av1;"
                        + "av = av1;"
                        + "av1 = av2;"
                        + "av2 = av;"
                )
            ),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("global\\d+ = global\\d+;"),
            check("global\\d+ = __pack\\(local\\d+\\);")
        )

        // Test field access
        testCompilation(prologue(fn("t.v2f.x = t1.v2f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t.v3f.x = t1.v3f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t.v4f.x = t1.v4f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t.v2u.x = t1.v2u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t.v3u.x = t1.v3u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t.v4u.x = t1.v4u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t.v2f   = t1.v2f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t.v3f   = t1.v3f;")), check("global\\d+\\.field\\d = __unpack\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.v4f   = t1.v4f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t.v2u   = t1.v2u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t.v3u   = t1.v3u;")), check("global\\d+\\.field\\d = __unpack\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.v4u   = t1.v4u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t.f     = t1.f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t.u     = t1.u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))

        testCompilation(prologue(fn("t1.v2f.x = t2.v2f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t1.v3f.x = t2.v3f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t1.v4f.x = t2.v4f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t1.v2u.x = t2.v2u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t1.v3u.x = t2.v3u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t1.v4u.x = t2.v4u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t1.v2f   = t2.v2f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.v3f   = t2.v3f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.v4f   = t2.v4f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.v2u   = t2.v2u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.v3u   = t2.v3u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.v4u   = t2.v4u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.f     = t2.f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t1.u     = t2.u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))

        testCompilation(prologue(fn("t2.v2f.x = t.v2f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t2.v3f.x = t.v3f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t2.v4f.x = t.v4f.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t2.v2u.x = t.v2u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t2.v3u.x = t.v3u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t2.v4u.x = t.v4u.x;")), check("global\\d+\\.field\\d\\.x = global\\d+\\.field\\d\\.x;"))
        testCompilation(prologue(fn("t2.v2f   = t.v2f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t2.v3f   = t.v3f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t2.v4f   = t.v4f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t2.v2u   = t.v2u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t2.v3u   = t.v3u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t2.v4u   = t.v4u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d;"))
        testCompilation(prologue(fn("t2.f     = t.f;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d"))
        testCompilation(prologue(fn("t2.u     = t.u;")), check("global\\d+\\.field\\d = global\\d+\\.field\\d"))

        // Test index access
        testCompilation(
            prologue(
                makeString(
                    "@group(0) @binding(9) var<storage, read_write> index: u32;",
                    fn(
                        "var at = at1;"
                            + "at[0] = at1[0];"
                            + "at1[0] = at2[0];"
                            + "at2[0] = at[0];"
                            + "at2[index] = at[index];"
                    )
                )
            ),
            check("local\\d+ = __unpack\\(global\\d+\\);"),
            check("local\\d+\\[0\\] = __unpack\\(global\\d+\\[0\\]\\);"),
            check("global\\d+\\[0\\] = global\\d+\\[0\\];"),
            check("global\\d+\\[0\\] = __pack\\(local\\d+\\[0\\]\\);"),
            check(
                "global\\d+\\[__wgslMin\\(unsigned\\(global\\d+\\), \\(2u - 1u\\)\\)\\] = __pack\\(local\\d+\\[__wgslMin\\(unsigned\\(global\\d+\\), \\(2u - 1u\\)\\)\\]\\);"
            )
        )

        // Indexing a packed matrix (rows == 3) yields a PackedVec3 column, which
        // must be unpacked before it can be swizzled or used as a vec3.
        testCompilation(
            prologue(
                makeString(
                    "@group(0) @binding(9) var<storage, read_write> m43: mat4x3<f32>;",
                    fn(
                        "t.v3f = m43[1].xyz;"
                            + "t.v3f = m43[1];"
                            + "t.v3f.x = m43[1].x;"
                    )
                )
            ),
            check("__unpack\\(global\\d+\\.columns\\[__wgslMin\\(unsigned\\(1\\), \\(4u - 1u\\)\\)\\]\\)\\.xyz"),
            check("__unpack\\(global\\d+\\.columns\\[__wgslMin\\(unsigned\\(1\\), \\(4u - 1u\\)\\)\\]\\)")
        )

        // Test binary operations
        testCompilation(
            prologue(fn("t.v2f.x = 2 * t1.v2f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t.v3f.x = 2 * t1.v3f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t.v4f.x = 2 * t1.v4f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t.v2u.x = 2 * t1.v2u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t.v3u.x = 2 * t1.v3u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t.v4u.x = 2 * t1.v4u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(prologue(fn("t.v2f   = 2 * t1.v2f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t.v3f   = 2 * t1.v3f;")),
            check("global\\d+\\.field\\d = \\(2. \\* __unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t.v4f   = 2 * t1.v4f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.v2u   = 2 * t1.v2u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t.v3u   = 2 * t1.v3u;")),
            check("global\\d+\\.field\\d = \\(2u \\* __unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t.v4u   = 2 * t1.v4u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.f     = 2 * t1.f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.u     = 2 * t1.u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))

        testCompilation(
            prologue(fn("t1.v2f.x = 2 * t2.v2f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t1.v3f.x = 2 * t2.v3f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t1.v4f.x = 2 * t2.v4f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t1.v2u.x = 2 * t2.v2u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t1.v3u.x = 2 * t2.v3u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t1.v4u.x = 2 * t2.v4u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(prologue(fn("t1.v2f   = 2 * t2.v2f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t1.v3f   = 2 * t2.v3f;")),
            check("global\\d+\\.field\\d = \\(2. \\* __unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t1.v4f   = 2 * t2.v4f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.v2u   = 2 * t2.v2u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t1.v3u   = 2 * t2.v3u;")),
            check("global\\d+\\.field\\d = \\(2u \\* __unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t1.v4u   = 2 * t2.v4u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.f     = 2 * t2.f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.u     = 2 * t2.u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))

        testCompilation(
            prologue(fn("t2.v2f.x = 2 * t.v2f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t2.v3f.x = 2 * t.v3f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t2.v4f.x = 2 * t.v4f.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2. \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t2.v2u.x = 2 * t.v2u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t2.v3u.x = 2 * t.v3u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(
            prologue(fn("t2.v4u.x = 2 * t.v4u.x;")),
            check("global\\d+\\.field\\d\\.x = \\(2u \\* global\\d+\\.field\\d\\.x\\);")
        )
        testCompilation(prologue(fn("t2.v2f   = 2 * t.v2f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v3f   = 2 * t.v3f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v4f   = 2 * t.v4f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v2u   = 2 * t.v2u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v3u   = 2 * t.v3u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v4u   = 2 * t.v4u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.f     = 2 * t.f;")), check("global\\d+\\.field\\d = \\(2. \\* global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.u     = 2 * t.u;")), check("global\\d+\\.field\\d = \\(2u \\* global\\d+\\.field\\d\\);"))

        // Test unary operations

        testCompilation(prologue(fn("t.v2f.x = -t1.v2f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v3f.x = -t1.v3f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v4f.x = -t1.v4f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v2f   = -t1.v2f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.v3f   = -t1.v3f;")), check("global\\d+\\.field\\d = \\(-__unpack\\(global\\d+\\.field\\d\\)\\);"))
        testCompilation(prologue(fn("t.v4f   = -t1.v4f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.f     = -t1.f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))

        testCompilation(prologue(fn("t1.v2f.x = -t2.v2f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v3f.x = -t2.v3f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v4f.x = -t2.v4f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v2f   = -t2.v2f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.v3f   = -t2.v3f;")), check("global\\d+\\.field\\d = \\(-__unpack\\(global\\d+\\.field\\d\\)\\);"))
        testCompilation(prologue(fn("t1.v4f   = -t2.v4f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.f     = -t2.f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))

        testCompilation(prologue(fn("t2.v2f.x = -t.v2f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v3f.x = -t.v3f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v4f.x = -t.v4f.x;")), check("global\\d+\\.field\\d\\.x = \\(-global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v2f   = -t.v2f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v3f   = -t.v3f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v4f   = -t.v4f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.f     = -t.f;")), check("global\\d+\\.field\\d = \\(-global\\d+\\.field\\d\\);"))

        // Test function calls
        testCompilation(prologue(fn("t.v2f.x = abs(t1.v2f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v3f.x = abs(t1.v3f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v4f.x = abs(t1.v4f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v2u.x = abs(t1.v2u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v3u.x = abs(t1.v3u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v4u.x = abs(t1.v4u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t.v2f   = abs(t1.v2f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t.v3f   = abs(t1.v3f);")),
            check("global\\d+\\.field\\d = abs\\(__unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t.v4f   = abs(t1.v4f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.v2u   = abs(t1.v2u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t.v3u   = abs(t1.v3u);")),
            check("global\\d+\\.field\\d = abs\\(__unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t.v4u   = abs(t1.v4u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.f     = abs(t1.f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t.u     = abs(t1.u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))

        testCompilation(prologue(fn("t1.v2f.x = abs(t2.v2f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v3f.x = abs(t2.v3f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v4f.x = abs(t2.v4f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v2u.x = abs(t2.v2u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v3u.x = abs(t2.v3u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v4u.x = abs(t2.v4u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t1.v2f   = abs(t2.v2f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t1.v3f   = abs(t2.v3f);")),
            check("global\\d+\\.field\\d = abs\\(__unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t1.v4f   = abs(t2.v4f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.v2u   = abs(t2.v2u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(
            prologue(fn("t1.v3u   = abs(t2.v3u);")),
            check("global\\d+\\.field\\d = abs\\(__unpack\\(global\\d+\\.field\\d\\)\\);")
        )
        testCompilation(prologue(fn("t1.v4u   = abs(t2.v4u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.f     = abs(t2.f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t1.u     = abs(t2.u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))

        testCompilation(prologue(fn("t2.v2f.x = abs(t.v2f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v3f.x = abs(t.v3f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v4f.x = abs(t.v4f.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v2u.x = abs(t.v2u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v3u.x = abs(t.v3u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v4u.x = abs(t.v4u.x);")), check("global\\d+\\.field\\d\\.x = abs\\(global\\d+\\.field\\d\\.x\\);"))
        testCompilation(prologue(fn("t2.v2f   = abs(t.v2f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v3f   = abs(t.v3f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v4f   = abs(t.v4f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v2u   = abs(t.v2u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v3u   = abs(t.v3u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.v4u   = abs(t.v4u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.f     = abs(t.f);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))
        testCompilation(prologue(fn("t2.u     = abs(t.u);")), check("global\\d+\\.field\\d = abs\\(global\\d+\\.field\\d\\);"))

        // Test runtime array
        testCompilation(
            prologue(
                makeString(
                    "struct S {"
                        + "    @size(16) x: i32,"
                        + "    @align(32) y: array<i32>,"
                        + "}"
                        + "@group(0) @binding(10) var<storage, read_write> s: S;",
                    fn("s.x = 0; s.y[0] = 0;")
                )
            )
        )

        // Test packed vec3 compound assignment
        testCompilation(
            prologue(
                makeString(
                    "@group(0) @binding(11) var<storage,read_write> D: array<vec3f>;",
                    fn("D[0] += vec3f(1);")
                )
            )
        )

        // Test inconstructible struct
        testCompilation(
            prologue(
                makeString(
                    "struct InconstructibleS {"
                        + "    x: vec3f,"
                        + "    y: atomic<u32>"
                        + "}"
                        + "struct InconstructibleT {"
                        + "    x: InconstructibleS,"
                        + "}"
                        + "@group(0) @binding(12) var<storage, read_write> global: InconstructibleT;",
                    fn("var x = global.x.x;")
                )
            )
        )
    }

    @Test
    func PackingNestedArray() {
        testCompilation(file("packing-nested-array.wgsl"))
    }

    @Test
    func PackingPointerArguments() {
        testCompilation(file("packing-pointer-arguments.wgsl"))
    }

    @Test
    func PointerRewritingConcreteType() {
        testCompilation(
            fn("var h = vec2f(); _ = length(*&h);"),
            checkLiteral("length(local0)")
        )
    }

    @Test
    func Pointers() {
        testCompilation(file("pointers.wgsl"))
    }

    @Test
    func References() {
        testCompilation(file("references.wgsl"))
    }

    @Test
    func Reordering() {
        testCompilation(file("references.wgsl"))
    }

    @Test
    func RuntimeSizedArray() {
        testCompilation(file("runtime-sized-array-resource.wgsl"))
    }

    @Test
    func Scope() {
        testCompilation(file("scope.wgsl"))
    }

    @Test
    func Shadowing() {
        testCompilation(file("shadowing.wgsl"))
    }

    @Test
    func Struct() {
        testCompilation(file("struct.wgsl"))
    }

    @Test
    func Switch() {
        testCompilation(file("switch.wgsl"))
    }

    @Test
    func Swizzle() {
        testCompilation(file("swizzle.wgsl"))
    }

    @Test
    func TextureExternal() {
        testCompilation(file("texture-external.wgsl"))
    }

    @Test
    func TypePromotion() {
        testCompilation(file("type-promotion.wgsl"))
    }

    @Test
    func VarInitialization() {
        testCompilation(
            "fn f(x: f32) { }"
                + "@compute @workgroup_size(1)"
                + "fn main() {"
                + "    var a = 1.0;"
                + "    var b = a;"
                + "    b = 0.0;"
                + "    f(b);"
                + "}",
            check("float local\\d+ = 1"),
            check("float local\\d+ = local\\d"),
            check("local\\d+ = 0"),
            check("function\\d\\(local\\d+\\)")
        )
    }

    @Test
    func While() {
        testCompilation(file("while.wgsl"))
    }
}
