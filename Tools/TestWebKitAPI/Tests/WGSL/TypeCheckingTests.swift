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

@Suite
struct WGSLTypeCheckingTests {
    @Test
    func Array() {
        expectTypeError("var<private> a:array;", "'array' requires at least 1 template argument")
        expectTypeError(
            "@group(0) @binding(0) var<storage, read_write> b: array<u32, (1<<32)>;",
            "value 4294967296 cannot be represented as 'i32'"
        )

        expectTypeError(fn("let x = array<i32, 0>();"), "array count must be greater than 0")
        expectTypeError(fn("let x = array<i32, -1>();"), "array count must be greater than 0")

        expectTypeError(fn("let x = array<i32, 2>(0);"), "array constructor has too few elements: expected 2, found 1")
        expectTypeError(fn("let x = array<i32, 1>(0, 0);"), "array constructor has too many elements: expected 1, found 2")

        expectTypeError(fn("let x = array<i32, 65536>();"), "array count (65536) must be less than 65536")

        expectTypeError(fn("let x = array<i32>(0);"), "cannot construct a runtime-sized array")

        expectTypeError(fn("let x = array<i32, 1>(0.0);"), "'<AbstractFloat>' cannot be used to construct an array of 'i32'")

        expectTypeError(fn("let x = array();"), "cannot infer array element type from constructor")

        expectTypeError(fn("let x = array(0, 0.0, 0u);"), "cannot infer common array element type from constructor arguments")

        expectTypeError(fn("let x = array<i2, 1>(0.0);"), "unresolved type 'i2'")

        expectTypeError(
            "override elementCount = 4;"
                + "fn testOverrideElementCount() {"
                + "let xl = array<i32, elementCount>(0.0);"
                + "}",
            "array must have constant size in order to be constructed"
        )
    }

    @Test
    func Attributes() {
        expectTypeError("@id(0) override z: array<i32, 1>;", "'array<i32, 1>' cannot be used as the type of an 'override'")
        expectTypeError("@id(u32(dpdx(0))) override y: i32;", "cannot call function from constant context")

        expectTypeError("struct S { @align(4.0) x: i32, }", "@align must be an i32 or u32 value")
        expectTypeError("struct S { @location(0.0) y: i32, }", "@location must be an i32 or u32 value")
        expectTypeError("struct S { @size(4.0) z: i32, }", "@size must be an i32 or u32 value")
        expectTypeError("struct S { @size(2) x: i32, }", "@size value must be at least the byte-size of the type of the member")
        expectTypeError("struct S { @size(-1) y: i32, }", "@size value must be non-negative")
        expectTypeError("struct S { @align(-1) z: i32, }", "@align value must be positive")
        expectTypeError("struct S { @align(3) w: i32, }", "@align value must be a power of two")

        // Type checking @group, @binding and @workgroup_size
        expectTypeError("@group(0.0) @binding(0) var x : i32;", "@group must be an i32 or u32 value")
        expectTypeError("@group(0) @binding(0.0) var y : i32;", "@binding must be an i32 or u32 value")
        expectTypeError("@id(0.0) override z : i32;", "@id must be an i32 or u32 value")
        expectTypeError("@compute @workgroup_size(1.0) fn f1() { }", "@workgroup_size x dimension must be an i32 or u32 value")
        expectTypeError("@compute @workgroup_size(1, 1.0) fn f2() { }", "@workgroup_size y dimension must be an i32 or u32 value")
        expectTypeError("@compute @workgroup_size(1, 1, 1.0) fn f3() { }", "@workgroup_size z dimension must be an i32 or u32 value")
        expectTypeError(
            "@compute @workgroup_size(1i, 1u) fn f4() { }",
            "@workgroup_size arguments must be of the same type, either i32 or u32"
        )
        expectTypeError(
            "@compute @workgroup_size(1, 1i, 1u) fn f5() { }",
            "@workgroup_size arguments must be of the same type, either i32 or u32"
        )
        expectTypeError(
            "@compute @workgroup_size(1, 1u, 1i) fn f6() { }",
            "@workgroup_size arguments must be of the same type, either i32 or u32"
        )

        // Attribute validation
        expectTypeError("@group(0) var<private> x: i32;", "@group attribute must only be applied to resource variables")
        expectTypeError("@group(-1) var<uniform> x: i32;", "@group value must be non-negative")
        expectTypeError("@binding(0) var<private> x: i32;", "@binding attribute must only be applied to resource variables")
        expectTypeError("@binding(-1) var<uniform> x: i32;", "@binding value must be non-negative")
        expectTypeError("@id(-1) var<private> y: i32;", "@id attribute must only be applied to override variables")
        expectTypeError("@id(-1) override z: i32;", "@id value must be non-negative")
        expectTypeError("@must_use fn mustUseWithoutReturnType() { }", "@must_use can only be applied to functions that return a value")
        expectTypeError("fn f1() -> @builtin(position) i32 { return 0; }", "@builtin is not valid for non-entry point function types")
        expectTypeError("fn f2() -> @location(0) i32 { return 0; }", "@location is not valid for non-entry point function types")
        expectTypeError("@fragment fn f3() -> @location(-1) i32 { return 0; }", "@location value must be non-negative")
        expectTypeError("@compute fn f4() -> @location(0) i32 { return 0; }", "@location may not be used in the compute shader stage")
        expectTypeError(
            "@fragment fn f5() -> @location(0) bool { return false; }",
            "@location must only be applied to declarations of numeric scalar or numeric vector type"
        )
        expectTypeError(
            "fn f6() -> @interpolate(flat) i32 { return 0; }",
            "@interpolate is only allowed on declarations that have a @location attribute"
        )
        expectTypeError(
            "fn f7() -> @invariant i32 { return 0; }",
            "@invariant is only allowed on declarations that have a @builtin(position) attribute"
        )
        expectTypeError("@workgroup_size(1) fn f8() { }", "@workgroup_size must only be applied to compute shader entry point function")
        expectTypeError("@workgroup_size(-1) @compute fn f9() { }", "@workgroup_size argument must be at least 1")

        // check that we don't crash by trying to read the size of S2, which won't have been computed
        expectNoError(
            "struct S1 { @size(16) x : f32 };"
                + "struct S2 { @size(32) x: array<S1, 2>, };"
        )
    }

    @Test
    func AccessExpression() {
        // Test index access
        expectTypeError(fn("_ = vec2(0)[1f];"), "index must be of type 'i32' or 'u32', found: 'f32'")

        // Test swizzle access
        expectTypeError(fn("_ = vec2(0).z;"), "invalid vector swizzle member")
        expectTypeError(fn("_ = vec2(0).w;"), "invalid vector swizzle member")
        expectTypeError(fn("_ = vec2(0).b;"), "invalid vector swizzle member")
        expectTypeError(fn("_ = vec2(0).a;"), "invalid vector swizzle member")

        expectTypeError(fn("_ = vec3(0).w;"), "invalid vector swizzle member")
        expectTypeError(fn("_ = vec3(0).a;"), "invalid vector swizzle member")

        expectTypeError(fn("_ = vec2(0).rx;"), "invalid vector swizzle member")

        expectTypeError(fn("_ = vec2(0).v;"), "invalid vector swizzle character")

        expectTypeError(fn("var z: mat3x3<f32>; _ = z[1].e;"), "invalid vector swizzle character")

        // The restriction below can be found in the spec for the following types:
        // - Vectors: https://www.w3.org/TR/WGSL/#vector-single-component
        // - Matrices: https://www.w3.org/TR/WGSL/#matrix-access-expr
        // - Arrays: https://www.w3.org/TR/WGSL/#array-access-expr
        //
        // NOTE: When an abstract vector value e is indexed by an expression that is not
        // a const-expression, then the vector is concretized before the index is applied.
        expectNoError(fn("let x: f32 = vec2(0)[0];"))
        expectTypeError(fn("let i = 0; let x: u32 = vec2(0)[i];"), "cannot initialize var of type 'u32' with value of type 'i32'")
        expectTypeError(
            enableF16(fn("let i = 0; let x: vec2<f16> = mat2x2(0, 0, 0, 0)[i];")),
            "cannot initialize var of type 'vec2<f16>' with value of type 'vec2<f32>'"
        )

        expectNoError(fn("let x: f32 = array(0)[0];"))
        expectTypeError(fn("let i = 0; let x: u32 = array(0)[i];"), "cannot initialize var of type 'u32' with value of type 'i32'")

        // Test cannot write to multiple vector locations
        expectTypeError(fn("var v = vec2(0); v.xy = vec2(1);"), "cannot assign to a value of type 'vec2<i32>'")
    }

    @Test
    func Atomics() {
        expectTypeError("@group(0) @binding(0) var<storage, read_write> x : atomic<i32, i32>;", "'atomic' requires 1 template argument")
        expectTypeError("@group(0) @binding(1) var<storage, read_write> y : atomic<f32>;", "atomic only supports i32 or u32 types")
    }

    @Test
    func Bitcast() {
        // Wrong number of arguments
        expectTypeError(fn("_ = bitcast<i32>(0, 0);"), "bitcast expects a single argument, found 2")
        expectTypeError(fn("_ = bitcast<i32>();"), "bitcast expects a single argument, found 0")

        // Wrong number of template arguments
        expectTypeError(fn("_ = bitcast<i32, i32>(0);"), "bitcast expects a single template argument, found 2")
        expectTypeError(fn("_ = bitcast(0);"), "bitcast expects a single template argument, found 0")

        // Invalid conversion
        expectTypeError(fn("_ = bitcast<vec2<i32>>(0);"), "cannot bitcast from 'i32' to 'vec2<i32>'")
        expectTypeError(fn("_ = bitcast<i32>(vec2(0));"), "cannot bitcast from 'vec2<i32>' to 'i32'")

        // I32 overflow
        expectTypeError(fn("const x: f32 = bitcast<f32>(4294967295);"), "value 4294967295 cannot be represented as 'i32'")

        // Function as a value
        expectTypeError("fn f() { } fn g() { const x: f32 = bitcast<f32>(f); }", "cannot use function 'f' as value")

        // Types that cannot be concretized
        expectTypeError(
            "@group(0) @binding(1) var s: sampler; fn test() { _ = bitcast<i32>(s); }",
            "cannot bitcast from 'sampler' to 'i32'"
        )
        expectTypeError(
            "@group(0) @binding(2) var t: texture_depth_2d; fn test() { _ = bitcast<i32>(t); }",
            "cannot bitcast from 'texture_depth_2d' to 'i32'"
        )
    }

    @Test
    func Break() {
        expectTypeError(fn("if true { break; }"), "break statement must be in a loop or switch case")
    }

    @Test
    func Comments() {
        expectTypeError("/*", "Trying to parse a GlobalDecl, expected 'const', 'fn', 'override', 'struct' or 'var'.")
    }

    @Test
    func CompoundAssignment() {
        expectTypeError(fn("var x = 1; x += 1f;"), "no matching overload for operator +(ref<function, i32, read_write>, f32)")
        expectTypeError(fn("let x = 1; x += 1;"), "cannot assign to a value of type 'i32'")
    }

    @Test
    func ConstAssert() {
        expectTypeError("fn f() { } const_assert(f);", "cannot use function 'f' as value")

        // Top level
        expectTypeError("const_assert(1);", "const assertion condition must be a bool, got '<AbstractInt>'")
        expectTypeError("const_assert(undefined);", "unresolved identifier 'undefined'")
        expectTypeError("const_assert(vec2);", "cannot use type 'vec2' as value")
        expectTypeError("const_assert(i32);", "cannot use type 'i32' as value")
        expectTypeError("const_assert(sqrt);", "unresolved identifier 'sqrt'")
        expectTypeError("const_assert(1 > 2);", "const assertion failed")

        expectTypeError(
            "const x = 1;"
                + "const y = 2;"
                + "const_assert(x > y);",
            "const assertion failed"
        )

        expectTypeError(
            "const x = 1;"
                + "var<private> z = 3;"
                + "const_assert(x > z);",
            "cannot use runtime value in constant expression"
        )

        // Function level
        expectTypeError(fn("const_assert(1);"), "const assertion condition must be a bool, got '<AbstractInt>'")
        expectTypeError(fn("const_assert(undefined);"), "unresolved identifier 'undefined'")
        expectTypeError(fn("const_assert(vec2);"), "cannot use type 'vec2' as value")
        expectTypeError(fn("const_assert(i32);"), "cannot use type 'i32' as value")
        expectTypeError(fn("const_assert(sqrt);"), "unresolved identifier 'sqrt'")
        expectTypeError(fn("const_assert(1 > 2);"), "const assertion failed")

        expectTypeError(
            fn(
                "const x = 1;"
                    + "const y = 2;"
                    + "const_assert(x > y);"
            ),
            "const assertion failed"
        )

        expectTypeError(
            fn(
                "const x = 1;"
                    + "let z = 3;"
                    + "const_assert(x > z);"
            ),
            "cannot use runtime value in constant expression"
        )
    }

    @Test
    func Constants() {
        // Test out of bounds
        expectTypeError(fn("const x = array(0); _ = x[-1];"), "index -1 is out of bounds [0..0]")
        expectNoError(fn("const x = array(0); _ = x[0];"))
        expectTypeError(fn("const x = array(0); _ = x[1];"), "index 1 is out of bounds [0..0]")

        expectTypeError(fn("const x = mat2x2(0, 0, 0, 0); _ = x[-1];"), "index -1 is out of bounds [0..1]")
        expectNoError(fn("const x = mat2x2(0, 0, 0, 0); _ = x[0];"))
        expectNoError(fn("const x = mat2x2(0, 0, 0, 0); _ = x[1];"))
        expectTypeError(fn("const x = mat2x2(0, 0, 0, 0); _ = x[2];"), "index 2 is out of bounds [0..1]")

        expectTypeError(fn("const x = vec2(0); _ = x[-1];"), "index -1 is out of bounds [0..1]")
        expectNoError(fn("const x = vec2(0); _ = x[0];"))
        expectNoError(fn("const x = vec2(0);_ = x[1];"))
        expectTypeError(fn("const x = vec2(0);_ = x[2];"), "index 2 is out of bounds [0..1]")

        // Test invalid explicit u32 conversion
        expectTypeError(fn("let x = u32(37359285590000);"), "value 37359285590000 cannot be represented as 'u32'")

        // Test nested arrays
        expectNoError(fn("const c = array<array<u32, 1>, 1>(array<u32, 1>(0));"))
    }

    @Test
    func Continue() {
        expectTypeError(
            fn(
                "switch 1 {"
                    + "default: {"
                    + "   continue;"
                    + "}"
                    + "}"
            ),
            "continue statement must be in a loop"
        )
    }

    @Test
    func Division() {
        // Test AbstractInt
        expectTypeError(fn("_ = 42 / 0;"), "invalid division by zero")
        expectTypeError(fn("_ = 42 / vec2(1, 0);"), "invalid division by zero")
        expectTypeError(fn("_ = vec2(42) / 0;"), "invalid division by zero")
        expectTypeError(fn("_ = vec2(42) / vec2(1, 0);"), "invalid division by zero")

        expectTypeError(fn("let x = 42; _ = x / 0;"), "invalid division by zero")
        expectTypeError(fn("let x = 42; _ = x / vec2(1, 0);"), "invalid division by zero")
        expectTypeError(fn("let x = 42; _ = vec2(x) / 0;"), "invalid division by zero")
        expectTypeError(fn("let x = 42; _ = vec2(x) / vec2(1, 0);"), "invalid division by zero")

        expectNoError(fn("_ = (-2147483647 - 1) / -1;"))
        expectNoError(fn("_ = vec2(-2147483647 - 1, 1) / vec2(-1, 1);"))

        expectTypeError(fn("_ = (-9223372036854775807 - 1) / -1;"), "invalid division overflow")
        expectTypeError(fn("_ = vec2(-9223372036854775807 - 1, 1) / vec2(-1, 1);"), "invalid division overflow")

        // Test i32
        expectTypeError(fn("_ = 42i / 0i;"), "invalid division by zero")
        expectTypeError(fn("_ = 42i / vec2(1i, 0i);"), "invalid division by zero")
        expectTypeError(fn("_ = vec2(42i) / 0i;"), "invalid division by zero")
        expectTypeError(fn("_ = vec2(42i) / vec2(1i, 0i);"), "invalid division by zero")

        expectTypeError(fn("let x = 42i; _ = x / 0i;"), "invalid division by zero")
        expectTypeError(fn("let x = 42i; _ = x / vec2(1i, 0i);"), "invalid division by zero")
        expectTypeError(fn("let x = 42i; _ = vec2(x) / 0i;"), "invalid division by zero")
        expectTypeError(fn("let x = 42i; _ = vec2(x) / vec2(1i, 0i);"), "invalid division by zero")

        expectTypeError(fn("_ = (-2147483647i - 1i) / -1i;"), "invalid division overflow")
        expectTypeError(fn("_ = vec2(-2147483647i - 1i, 1i) / vec2(-1i, 1i);"), "invalid division overflow")

        // Test u32
        expectTypeError(fn("_ = 42u / 0u;"), "invalid division by zero")
        expectTypeError(fn("_ = 42u / vec2(1u, 0u);"), "invalid division by zero")
        expectTypeError(fn("_ = vec2(42u) / 0u;"), "invalid division by zero")
        expectTypeError(fn("_ = vec2(42u) / vec2(1u, 0u);"), "invalid division by zero")

        expectTypeError(fn("let x = 42u; _ = x / 0u;"), "invalid division by zero")
        expectTypeError(fn("let x = 42u; _ = x / vec2(1u, 0u);"), "invalid division by zero")
        expectTypeError(fn("let x = 42u; _ = vec2(x) / 0u;"), "invalid division by zero")
        expectTypeError(fn("let x = 42u; _ = vec2(x) / vec2(1u, 0u);"), "invalid division by zero")

        // Test AbstractFloat
        expectTypeError(fn("_ = 42.0 / 0.0;"), "value Infinity cannot be represented as '<AbstractFloat>'")
        expectTypeError(fn("_ = 42.0 / vec2(1.0, 0.0);"), "value vec2(42, Infinity) cannot be represented as 'vec2<<AbstractFloat>>'")
        expectTypeError(fn("_ = vec2(42.0) / 0.0;"), "value vec2(Infinity, Infinity) cannot be represented as 'vec2<<AbstractFloat>>'")
        expectTypeError(fn("_ = vec2(42.0) / vec2(1.0, 0.0);"), "value vec2(42, Infinity) cannot be represented as 'vec2<<AbstractFloat>>'")

        expectNoError(fn("let x = 42.0; _ = x / 0.0;"))
        expectNoError(fn("let x = 42.0; _ = x / vec2(1.0, 0.0);"))
        expectNoError(fn("let x = 42.0; _ = vec2(x) / 0.0;"))
        expectNoError(fn("let x = 42.0; _ = vec2(x) / vec2(1.0, 0.0);"))

        expectNoError(fn("_ = (-2147483647.0 - 1.0) / -1.0;"))
        expectNoError(fn("_ = vec2(-2147483647.0 - 1.0, 1.0) / vec2(-1.0, 1.0);"))

        expectNoError(fn("_ = (-9223372036854775807.0 - 1.0) / -1.0;"))
        expectNoError(fn("_ = vec2(-9223372036854775807.0 - 1.0, 1.0) / vec2(-1.0, 1.0);"))

        expectNoError(fn("_ = -340282346638528859811704183484516925440.0 - 1.0 / -1.0;"))
        expectNoError(fn("_ = vec2(-340282346638528859811704183484516925440.0 - 1.0, 1.0) / vec2(-1.0, 1.0);"))

        // Test f32
        expectTypeError(fn("_ = 42f / 0f;"), "value Infinity cannot be represented as 'f32'")
        expectTypeError(fn("_ = 42f / vec2(1f, 0f);"), "value vec2(42f, Infinity) cannot be represented as 'vec2<f32>'")
        expectTypeError(fn("_ = vec2(42f) / 0f;"), "value vec2(Infinity, Infinity) cannot be represented as 'vec2<f32>'")
        expectTypeError(fn("_ = vec2(42f) / vec2(1f, 0f);"), "value vec2(42f, Infinity) cannot be represented as 'vec2<f32>'")

        expectNoError(fn("let x = 42f; _ = x / 0f;"))
        expectNoError(fn("let x = 42f; _ = x / vec2(1f, 0f);"))
        expectNoError(fn("let x = 42f; _ = vec2(x) / 0f;"))
        expectNoError(fn("let x = 42f; _ = vec2(x) / vec2(1f, 0f);"))

        expectNoError(fn("_ = (-2147483647f - 1f) / -1f;"))
        expectNoError(fn("_ = vec2(-2147483647f - 1f, 1f) / vec2(-1f, 1f);"))

        expectNoError(fn("_ = (-9223372036854775807.f - 1.f) / -1.f;"))
        expectNoError(fn("_ = vec2(-9223372036854775807.f - 1.f, 1.f) / vec2(-1.f, 1.f);"))

        expectNoError(fn("_ = (-340282346638528859811704183484516925439.f - 1f) / -1f;"))
        expectNoError(fn("_ = vec2(-340282346638528859811704183484516925439.f - 1f, 1f) / vec2(-1f, 1f);"))

        // Test i32 compound
        expectTypeError(fn("var y: vec2<i32>; y /= 0;"), "invalid division by zero")
        expectTypeError(fn("var y: vec2<i32>; y /= vec2(1, 0);"), "invalid division by zero")
        expectTypeError(fn("var y: vec2<i32>; y[0] /= 0;"), "invalid division by zero")
        expectTypeError(fn("var y: vec2<i32>; y[0] /= vec2(1, 0);"), "invalid division by zero")

        // Test u32 compound
        expectTypeError(fn("var y: vec2<u32>; y /= 0;"), "invalid division by zero")
        expectTypeError(fn("var y: vec2<u32>; y /= vec2(1, 0);"), "invalid division by zero")
        expectTypeError(fn("var y: vec2<u32>; y[0] /= 0;"), "invalid division by zero")
        expectTypeError(fn("var y: vec2<u32>; y[0] /= vec2(1, 0);"), "invalid division by zero")

        // Test f32 compound
        expectNoError(fn("var y: vec2<f32>; y /= 0;"))
        expectNoError(fn("var y: vec2<f32>; y /= vec2(1, 0);"))
        expectNoError(fn("var y: vec2<f32>; y[0] /= 0;"))
        expectNoError(fn("var y: vec2<f32>; y[0] /= vec2(1, 0).y;"))

        // Test divisor overflow
        expectTypeError(fn("let x = 1; _ = x / 8144182087775404419;"), "value 8144182087775404419 cannot be represented as 'i32'")
    }

    @Test
    func EmptyStruct() {
        expectTypeError("struct S { }", "structures must have at least one member")
    }

    @Test
    func F16() {
        expectTypeError(fn("_ = 1h"), "f16 literal used without f16 extension enabled")

        expectTypeError("fn f() -> f16 { }", "f16 type used without f16 extension enabled")
        expectTypeError(fn("var x: f16;"), "f16 type used without f16 extension enabled")
        expectTypeError(fn("_ = vec2h().x;"), "f16 type used without f16 extension enabled")
        expectTypeError(fn("_ = vec3h().x;"), "f16 type used without f16 extension enabled")
        expectTypeError(fn("_ = vec4h().x;"), "f16 type used without f16 extension enabled")
        expectTypeError(fn("_ = mat2x2h()[0].x;"), "f16 type used without f16 extension enabled")
    }

    @Test
    func For() {
        expectTypeError(fn("for (var i = 0; i; i++) { }"), "for-loop condition must be bool, got ref<function, i32, read_write>")
    }

    @Test
    func FunctionCall() {
        expectTypeError("fn f1(x: f32) -> f32 { }", "missing return at end of function")
        expectTypeError(fn("_ = f0();"), "unresolved call target 'f0'")
        expectTypeError(
            "fn f1(x: f32) { } fn f() { f1(0i); }",
            "type in function call does not match parameter type: expected 'f32', found 'i32'"
        )
        expectTypeError("fn f3() { } fn f() { let f3: i32 = 0; f3(); }", "cannot call value of type 'i32'")
        expectTypeError(
            "fn f1(x: f32) -> f32 { return x; } fn f() { let x: i32 = f1(0); }",
            "cannot initialize var of type 'i32' with value of type 'f32'"
        )
        expectTypeError("fn f1(x: f32) { } fn f() { f1(); }", "funtion call has too few arguments: expected 1, found 0")
        expectTypeError("fn f1(x: f32) { } fn f() { f1(0, 0); }", "funtion call has too many arguments: expected 1, found 2")
        expectTypeError("fn f3() { } fn f() { let x = f3(); }", "function 'f3' does not return a value")
        expectTypeError(
            "@group(0) @binding(0) var<storage, read_write> x: array<f32>;"
                + "fn f() {"
                + "let arrayLength = 1; _ = arrayLength(&x);"
                + "}",
            "cannot call value of type 'i32'"
        )
        expectTypeError(fn("let array = 1f; _ = array<i32, 1>(1);"), "cannot call value of type 'f32'")
        expectTypeError(fn("let vec2 = 1u; _ = vec2<i32>(1);"), "cannot call value of type 'u32'")
        expectTypeError(enableF16(fn("let bitcast = 1h; _ = bitcast<i32>(1);")), "cannot call value of type 'f16'")
    }

    @Test
    func Fuzz_133788509() {
        expectTypeError(file("fuzz-133788509.wgsl"), "maximum parser recursive depth reached")
    }

    @Test
    func If() {
        expectTypeError(fn("if array<f32, 9>() { return; }"), "expected 'bool', found 'array<f32, 9>'")
    }

    @Test
    func Limits() {
        expectTypeError(file("limits-brace-enclosed.wgsl"), "maximum parser recursive depth reached")
        expectTypeError(file("limits-composite-type.wgsl"), "composite type may not be nested more than 15 levels")
        expectTypeError(file("limits-const-array.wgsl"), "constant array cannot have more than 2047 elements")
        expectTypeError(file("limits-function-parameters.wgsl"), "function cannot have more than 255 parameters")
        expectTypeError(file("limits-struct-members.wgsl"), "struct cannot have more than 1023 members")
        expectTypeError(file("limits-switch-case.wgsl"), "switch statement cannot have more than 1023 case selector values")
    }

    @Test
    func Modulo() {
        // Test AbstractInt
        expectTypeError(fn("_ = 42 % 0;"), "invalid modulo by zero")
        expectTypeError(fn("_ = 42 % vec2(1, 0);"), "invalid modulo by zero")
        expectTypeError(fn("_ = vec2(42) % 0;"), "invalid modulo by zero")
        expectTypeError(fn("_ = vec2(42) % vec2(1, 0);"), "invalid modulo by zero")

        expectTypeError(fn("let x = 42; _ = x % 0;"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42; _ = x % vec2(1, 0);"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42; _ = vec2(x) % 0;"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42; _ = vec2(x) % vec2(1, 0);"), "invalid modulo by zero")

        expectNoError(fn("_ = (-2147483647 - 1) % -1;"))
        expectNoError(fn("_ = vec2(-2147483647 - 1, 1) % vec2(-1, 1);"))

        expectTypeError(fn("_ = (-9223372036854775807 - 1) % -1;"), "invalid modulo overflow")
        expectTypeError(fn("_ = vec2(-9223372036854775807 - 1, 1) % vec2(-1, 1);"), "invalid modulo overflow")

        // Test i32
        expectTypeError(fn("_ = 42i % 0i;"), "invalid modulo by zero")
        expectTypeError(fn("_ = 42i % vec2(1i, 0i);"), "invalid modulo by zero")
        expectTypeError(fn("_ = vec2(42i) % 0i;"), "invalid modulo by zero")
        expectTypeError(fn("_ = vec2(42i) % vec2(1i, 0i);"), "invalid modulo by zero")

        expectTypeError(fn("let x = 42i; _ = x % 0i;"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42i; _ = x % vec2(1i, 0i);"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42i; _ = vec2(x) % 0i;"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42i; _ = vec2(x) % vec2(1i, 0i);"), "invalid modulo by zero")

        expectTypeError(fn("_ = (-2147483647i - 1i) % -1i;"), "invalid modulo overflow")
        expectTypeError(fn("_ = vec2(-2147483647i - 1i, 1i) % vec2(-1i, 1i);"), "invalid modulo overflow")

        // Test u32
        expectTypeError(fn("_ = 42u % 0u;"), "invalid modulo by zero")
        expectTypeError(fn("_ = 42u % vec2(1u, 0u);"), "invalid modulo by zero")
        expectTypeError(fn("_ = vec2(42u) % 0u;"), "invalid modulo by zero")
        expectTypeError(fn("_ = vec2(42u) % vec2(1u, 0u);"), "invalid modulo by zero")

        expectTypeError(fn("let x = 42u; _ = x % 0u;"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42u; _ = x % vec2(1u, 0u);"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42u; _ = vec2(x) % 0u;"), "invalid modulo by zero")
        expectTypeError(fn("let x = 42u; _ = vec2(x) % vec2(1u, 0u);"), "invalid modulo by zero")

        // Test AbstractFloat
        expectTypeError(fn("_ = 42.0 % 0.0;"), "value NaN cannot be represented as '<AbstractFloat>'")
        expectTypeError(fn("_ = 42.0 % vec2(1.0, 0.0);"), "value vec2(0, NaN) cannot be represented as 'vec2<<AbstractFloat>>'")
        expectTypeError(fn("_ = vec2(42.0) % 0.0;"), "value vec2(NaN, NaN) cannot be represented as 'vec2<<AbstractFloat>>'")
        expectTypeError(fn("_ = vec2(42.0) % vec2(1.0, 0.0);"), "value vec2(0, NaN) cannot be represented as 'vec2<<AbstractFloat>>'")

        expectNoError(fn("let x = 42.0; _ = x % 0.0;"))
        expectNoError(fn("let x = 42.0; _ = x % vec2(1.0, 0.0);"))
        expectNoError(fn("let x = 42.0; _ = vec2(x) % 0.0;"))
        expectNoError(fn("let x = 42.0; _ = vec2(x) % vec2(1.0, 0.0);"))

        expectNoError(fn("_ = (-2147483647.0 - 1.0) % -1.0;"))
        expectNoError(fn("_ = vec2(-2147483647.0 - 1.0, 1.0) % vec2(-1.0, 1.0);"))

        expectNoError(fn("_ = (-9223372036854775807.0 - 1.0) % -1.0;"))
        expectNoError(fn("_ = vec2(-9223372036854775807.0 - 1.0, 1.0) % vec2(-1.0, 1.0);"))

        expectNoError(fn("_ = -340282346638528859811704183484516925440.0 - 1.0 % -1.0;"))
        expectNoError(fn("_ = vec2(-340282346638528859811704183484516925440.0 - 1.0, 1.0) % vec2(-1.0, 1.0);"))

        // Test f32
        expectTypeError(fn("_ = 42f % 0f;"), "value NaN cannot be represented as 'f32'")
        expectTypeError(fn("_ = 42f % vec2(1f, 0f);"), "value vec2(0f, NaN) cannot be represented as 'vec2<f32>'")
        expectTypeError(fn("_ = vec2(42f) % 0f;"), "value vec2(NaN, NaN) cannot be represented as 'vec2<f32>'")
        expectTypeError(fn("_ = vec2(42f) % vec2(1f, 0f);"), "value vec2(0f, NaN) cannot be represented as 'vec2<f32>'")

        expectNoError(fn("let x = 42f; _ = x % 0f;"))
        expectNoError(fn("let x = 42f; _ = x % vec2(1f, 0f);"))
        expectNoError(fn("let x = 42f; _ = vec2(x) % 0f;"))
        expectNoError(fn("let x = 42f; _ = vec2(x) % vec2(1f, 0f);"))

        expectNoError(fn("_ = (-2147483647f - 1f) % -1f;"))
        expectNoError(fn("_ = vec2(-2147483647f - 1f, 1f) % vec2(-1f, 1f);"))

        expectNoError(fn("_ = (-9223372036854775807.f - 1.f) % -1.f;"))
        expectNoError(fn("_ = vec2(-9223372036854775807.f - 1.f, 1.f) % vec2(-1.f, 1.f);"))

        expectNoError(fn("_ = (-340282346638528859811704183484516925439.f - 1f) % -1f;"))
        expectNoError(fn("_ = vec2(-340282346638528859811704183484516925439.f - 1f, 1f) % vec2(-1f, 1f);"))

        // Test i32 compound
        expectTypeError(fn("var y: vec2<i32>; y %= 0;"), "invalid modulo by zero")
        expectTypeError(fn("var y: vec2<i32>; y %= vec2(1, 0);"), "invalid modulo by zero")
        expectTypeError(fn("var y: vec2<i32>; y[0] %= 0;"), "invalid modulo by zero")
        expectTypeError(fn("var y: vec2<i32>; y[0] %= vec2(1, 0);"), "invalid modulo by zero")

        // Test u32 compound
        expectTypeError(fn("var y: vec2<u32>; y %= 0;"), "invalid modulo by zero")
        expectTypeError(fn("var y: vec2<u32>; y %= vec2(1, 0);"), "invalid modulo by zero")
        expectTypeError(fn("var y: vec2<u32>; y[0] %= 0;"), "invalid modulo by zero")
        expectTypeError(fn("var y: vec2<u32>; y[0] %= vec2(1, 0);"), "invalid modulo by zero")

        // Test f32 compound
        expectNoError(fn("var y: vec2<f32>; y %= 0;"))
        expectNoError(fn("var y: vec2<f32>; y %= vec2(1, 0);"))
        expectNoError(fn("var y: vec2<f32>; y[0] %= 0;"))
        expectNoError(fn("var y: vec2<f32>; y[0] %= vec2(1, 0).y;"))
    }

    @Test
    func Overload() {
        // Test explicit type arguments
        expectTypeError(
            fn("let v0 = vec2<i32>(0.0, 0.0);"),
            "no matching overload for initializer vec2<i32>(<AbstractFloat>, <AbstractFloat>)"
        )

        // test constraints
        expectTypeError(
            "struct S { x: i32, };"
                + "fn f() { let x = S(0); let x2 = x + x; }",
            "no matching overload for operator +(S, S)"
        )
        expectTypeError(
            "struct S { x: i32, };"
                + "fn f() { let x = S(0); let x3 = vec2(x, x); }",
            "no matching overload for initializer vec2(S, S)"
        )
        expectTypeError(
            "struct S { x: i32, };"
                + "fn f() { let x = S(0); let x4 = mat2x2(0u, 0u, 0u, 0u); }",
            "no matching overload for initializer mat2x2(u32, u32, u32, u32)"
        )
        expectTypeError(
            "struct S { x: i32, };"
                + "fn f() { let x = S(0); let x5 = vec2<S>(x, x); }",
            "no matching overload for initializer vec2<S>(S, S)"
        )
        expectTypeError(
            "struct S { x: i32, };"
                + "fn f() { let x6 = vec2<S>(vec2(0, 0)); }",
            "no matching overload for initializer vec2<S>(vec2<<AbstractInt>>)"
        )
        expectTypeError(
            fn("let x7 = -1u;"),
            "no matching overload for operator -(u32)"
        )
        expectTypeError(
            fn("let x8 = -vec2(1u, 1u);"),
            "no matching overload for operator -(vec2<u32>)"
        )
        expectTypeError(
            fn("const x: u32 = 1i << 1;"),
            "cannot initialize var of type 'u32' with value of type 'i32'"
        )

        // test textureGather
        expectTypeError(fn("_ = textureGather();"), "no matching overload for initializer textureGather()")

        // test compound assignment
        expectTypeError(fn("var f = 1f; f /= vec2f(1);"), "cannot assign 'vec2<f32>' to 'f32'")
    }

    @Test
    func ParameterScope() {
        expectTypeError("fn f(x: f32) { let x: i32 = 1; }", "redeclaration of 'x'")
    }

    @Test
    func PhonyAssignment() {
        expectTypeError(
            "fn f() { } fn main() { _ = f(); }",
            "function 'f' does not return a value"
        )
    }

    @Test
    func PointerAssignment() {
        expectTypeError(fn("var x = 1; *&*&x=3 x=1;"), "Expected a ;, but got a Identifier")
    }

    @Test
    func PointerAsConstant() {
        expectTypeError(
            "var<storage> x: i32; @id(*&x) var<storage> y: i32;",
            "cannot use runtime value in constant expression"
        )
    }

    @Test
    func PointerAccessMode() {
        expectTypeError("fn f1(x: ptr<function, i32, read>) { }", "only pointers in <storage> address space may specify an access mode")
        expectTypeError("alias T = ptr<storage, u32, write>;", "access mode 'write' is not valid for the <storage> address space")
        expectNoError("alias T = ptr<storage, u32, read>;")
        expectNoError("alias T = ptr<storage, u32, read_write>;")
    }

    @Test
    func Redeclaration() {
        // error during reordering of declarations
        expectTypeError(
            "struct f { x: i32 }"
                + "override f = 1;"
                + "fn f() { }",
            "redeclaration of 'f'"
        )

        // error during type checking
        expectTypeError(
            fn(
                "let x = 1;"
                    + "var x = 2;"
                    + "const x = 2;"
            ),
            "redeclaration of 'x'"
        )
    }

    @Test
    func References() {
        // Test reference assignment
        expectTypeError(
            "@group(0) @binding(0) var<storage, read> x: i32; fn f() { x = 0; }",
            "cannot store into a read-only type 'ref<storage, i32, read>'"
        )
        expectTypeError(
            "@group(0) @binding(1) var<storage, read_write> y: i32; fn f() { y = 0u; }",
            "cannot assign value of type 'u32' to 'i32'"
        )
        expectTypeError(fn("let z: i32 = 0; z = 0;"), "cannot assign to a value of type 'i32'")

        // Test decrement/increment
        expectTypeError(fn("let x = 0i; x++;"), "cannot modify a value of type 'i32'")
        expectTypeError(
            "@group(0) @binding(0) var<storage, read> x: i32; fn f() { x++; }",
            "cannot modify read-only type 'ref<storage, i32, read>'"
        )
        expectTypeError(fn("var x = 0f; x++;"), "increment can only be applied to integers, found f32")
    }

    @Test
    func Reordering() {
        expectTypeError("const a = a * 2;", "encountered a dependency cycle: a -> a")
        expectTypeError("fn f() { f(); };", "encountered a dependency cycle: f -> f")
        expectTypeError("struct S { s: S }", "encountered a dependency cycle: S -> S")
        expectTypeError("const a = S(array(1)); struct S { x: array<i32, a.x[0]> };", "encountered a dependency cycle: a -> S -> a")
        expectTypeError(
            "const y = x * 2;"
                + "const z = y;"
                + "const w = z;"
                + "const x = w;",
            "encountered a dependency cycle: y -> x -> w -> z -> y"
        )
        expectTypeError(
            "const y = x * 2;"
                + "const y = 2;",
            "redeclaration of 'y'"
        )
    }

    @Test
    func RequiredAlignment() {
        expectTypeError(
            "struct S1 { y1: array<i32, 2> }"
                + "@group(0) @binding(1) var<uniform> x1: S1;",
            "arrays in the uniform address space must have a stride multiple of 16 bytes, but has a stride of 4 bytes"
        )

        expectTypeError(
            "struct S1 { x1: i32, @align(4) y1: array<vec4i, 2> }"
                + "@group(0) @binding(1) var<uniform> x1: S1;",
            "@align attribute 4 of struct member is not a multiple of the type's alignment 16"
        )

        expectTypeError(
            "struct S1 { x1: i32, y3: T }"
                + "struct T { x: i32, y: i32, }"
                + "@group(0) @binding(1) var<uniform> x1: S1;",
            "offset of struct member S1::y3 must be a multiple of 16 bytes, but its offset is 4 bytes"
        )

        expectTypeError(
            "struct S1 { y3: T, z3: i32 }"
                + "struct T { x: i32, y: i32, }"
                + "@group(0) @binding(1) var<uniform> x1: S1;",
            "uniform address space requires that the number of bytes between S1::y3 and S1::z3 must be at least 16 bytes, but it is 8 bytes"
        )
    }

    @Test
    func Return() {
        expectTypeError(
            "fn noReturn() { return 0i; }",
            "return statement type does not match its function return type, returned 'i32', expected 'void'"
        )
        expectTypeError(
            "fn typeMisMatch() -> f32 { return 0i; }",
            "return statement type does not match its function return type, returned 'i32', expected 'f32'"
        )
        expectTypeError("fn conversionFailure() -> i32 { return 500000000000; }", "value 500000000000 cannot be represented as 'i32'")
    }

    @Test
    func Struct() {
        expectTypeError("struct S { x: f32, x: T, y: i32 }", "duplicate member 'x' in struct 'S'")

        expectTypeError(
            "struct T { x: u32, y: U, }"
                + "struct U { x: u32, y: array<u32>, }",
            "a struct that contains a runtime array cannot be nested inside another struct"
        )

        expectTypeError(
            "struct S { x: f32, y: i32, }"
                + "fn f() { _ = S(0); }",
            "struct initializer has too few inputs: expected 2, found 1"
        )

        expectTypeError(
            "struct S { x: f32, y: i32, }"
                + "fn f() { _ = S(0, 0, 0); }",
            "struct initializer has too many inputs: expected 2, found 3"
        )

        expectTypeError(
            "struct S { x: f32, y: i32, }"
                + "fn f() { _ = S(0i, 0); }",
            "type in struct initializer does not match struct member type: expected 'f32', found 'i32'"
        )

        expectTypeError(
            "struct S { x: f32, y: i32, }"
                + "fn f() { _ = S(0f, 0f); }",
            "type in struct initializer does not match struct member type: expected 'i32', found 'f32'"
        )
    }

    @Test
    func Switch() {
        expectTypeError(
            fn(
                "let x: u32 = 42;"
                    + "switch 1u {"
                    + "    case 1i, default,: { }"
                    + "}"
            ),
            "the case selector values must have the same type as the selector expression: the selector expression has type 'u32' and case selector has type 'i32'"
        )

        expectTypeError(
            fn(
                "switch false {"
                    + "    case default,: { }"
                    + "}"
            ),
            "switch selector must be of type i32 or u32"
        )
    }

    @Test
    func TextureGather() {
        expectTypeError(
            "@group(0) @binding(0) var t: texture_2d<f32>;"
                + "@group(0) @binding(1) var s: sampler;"
                + "@fragment fn f() {"
                + "    _ = textureGather(4, t, s, vec2());"
                + "}",
            "the component argument must be at least 0 and at most 3. component is 4"
        )

        expectTypeError(
            "@group(0) @binding(0) var t: texture_2d<f32>;"
                + "@group(0) @binding(1) var s: sampler;"
                + "@fragment fn f() {"
                + "    var c = 4;"
                + "    _ = textureGather(c, t, s, vec2());"
                + "}",
            "the component argument must be a const-expression"
        )

        expectTypeError(
            "@group(0) @binding(0) var s: sampler;"
                + "@group(0) @binding(23) var td2d: texture_depth_2d;"
                + "@fragment fn f() {"
                + "    var offset = vec2i(0);"
                + "    _ = textureGather(td2d, s, vec2f(0), offset);"
                + "}",
            "the offset argument must be a const-expression"
        )

        expectTypeError(
            "@group(0) @binding(0) var s: sampler;"
                + "@group(0) @binding(23) var td2d: texture_depth_2d;"
                + "@fragment fn f() {"
                + "    _ = textureGather(td2d, s, vec2f(0), vec2i(-9));"
                + "}",
            "each component of the offset argument must be at least -8 and at most 7. offset component 0 is -9"
        )

        expectTypeError(
            "@group(0) @binding(0) var s: sampler;"
                + "@group(0) @binding(23) var td2d: texture_depth_2d;"
                + "@fragment fn f() {"
                + "    _ = textureGather(td2d, s, vec2f(0), vec2i(8));"
                + "}",
            "each component of the offset argument must be at least -8 and at most 7. offset component 0 is 8"
        )
    }

    @Test
    func TypesVsValues() {
        expectTypeError(
            "struct S { x: i32 }"
                + "var<private> s : S;"
                + "fn f() -> s { return s; }",
            "cannot use value 's' as type"
        )

        expectTypeError(
            "struct S { x: i32 }"
                + "fn f() { let s = S(42); _ = s(42); }",
            "cannot call value of type 'S'"
        )

        expectTypeError(
            "struct S { x: i32 }"
                + "fn f() { _ = S; }",
            "cannot use type 'S' as value"
        )

        expectTypeError(fn("var x : undefined;"), "unresolved type 'undefined'")
        expectTypeError(fn("_ = undefined;"), "unresolved identifier 'undefined'")
    }

    @Test
    func Unicode() {
        expectTypeError("@group(5)@binding(" + String(repeating: "x", count: 109) + "0\u{07C3}", "Expected a ), but got a EOF")
    }

    @Test
    func Visibility() {
        expectTypeError(
            "fn f() { storageBarrier(); }"
                + "@fragment fn main() { f(); }",
            "built-in cannot be used by fragment pipeline stage"
        )

        expectTypeError(
            "fn f() { discard; }"
                + "@compute @workgroup_size(1) fn main() { f(); }",
            "discard statement cannot be used by compute pipeline stage"
        )

        expectTypeError(
            "fn f() { discard; }"
                + "@vertex fn main() -> @builtin(position) vec4f { f(); return vec4f(1); }",
            "discard statement cannot be used by vertex pipeline stage"
        )
    }

    @Test
    func While() {
        expectTypeError(fn("var i = 0; while (i) { }"), "while condition must be bool, got ref<function, i32, read_write>")
    }

    // Swift-only: an array constructor with more than 2047 constant arguments converts them without collecting them, and a
    // conversion error still comes before the limit error.
    @Test
    func ConstantArrayLimit() {
        let first2047 = (1...2047).map { String($0) }.joined(separator: ", ")
        expectNoError(fn("_ = array(\(first2047));"))
        expectTypeError(fn("_ = array(\(first2047), 2048);"), "constant array cannot have more than 2047 elements")
        expectTypeError(fn("_ = array<i32, 2048>(\(first2047), 3000000000);"), "value 3000000000 cannot be represented as 'i32'")
        expectTypeError(fn("_ = array<i32, 2048>(3000000000, \(first2047));"), "value 3000000000 cannot be represented as 'i32'")
    }

    // DEV-06: C++ calls a type constructor's validator through a reference to a lambda that no longer exists
    // (TypeCheck.cpp:2703); the Swift validators are an enum. Each one rejects what the C++ rejects, with the C++ message.
    @Test
    func DEV_06_TypeConstructorValidatorsReportTheirErrors() {
        expectTypeError("var<private> v: vec2<array<f32, 2>>;", "vector element type must be a scalar type")
        expectTypeError("struct S { x: f32 }\nvar<private> v: vec3<S>;", "vector element type must be a scalar type")
        expectTypeError("var<private> m: mat2x2<i32>;", "matrix element type must be a floating point type")
        expectTypeError("@group(0) @binding(0) var t: texture_2d<bool>;", "texture sampled type must be one 'i32', 'u32' or 'f32'")
        expectNoError("var<private> v: vec4<bool>;\nvar<private> m: mat3x3<f32>;\n@group(0) @binding(0) var t: texture_2d<u32>;")
    }

    // DEV-08: through an alias C++ reports this error at the span of a null `array` (TypeCheck.cpp:1771): Debug C++ crashes,
    // release C++ reports it at the span of the call target, as Swift does.
    @Test
    func DEV_08_AliasArrayConstructorElementTypeErrorSpan() {
        expectTypeError(
            "alias A = array<atomic<i32>, 2>;\nfn f() {\n    _ = A();\n}\n",
            "'atomic<i32>' cannot be used as an element type of an array",
            SourceSpan(line: 3, lineOffset: 8, offset: 50, length: 1)
        )
        expectTypeError(
            "alias T2 = array<atomic<i32>, 2>;\nalias T1 = array<T2, 3>;\nalias T = array<T1, 2>;\nfn f() {\n    _ = T();\n}\n",
            "'array<array<atomic<i32>, 2>, 3>' cannot be used as an element type of an array",
            SourceSpan(line: 5, lineOffset: 8, offset: 100, length: 1)
        )
    }

    // DEV-23: C++ runs out of memory materialising these zero values; Swift rejects them before materialising.
    @Test
    func DEV_23_HugeZeroValueIsRejected() {
        expectTypeError(
            fn("_ = array<array<u32, 0x80000000u>, 2>();"),
            "zero value of type 'array<array<u32, 2147483648>, 2>' is too large"
        )

        // 1 + 8192 * (1 + 1 * (1 + 8190)) = 2^26 + 1 values; 1 + 8191 * (1 + 8 * (1 + 1023)) = 2^26 values are accepted.
        expectTypeError(
            fn("_ = array<array<array<u32, 8190>, 1>, 8192>();"),
            "zero value of type 'array<array<array<u32, 8190>, 1>, 8192>' is too large"
        )
        expectNoError(fn("let a = array<array<array<u32, 1023>, 8>, 8191>(); _ = a;"))

        expectTypeError(
            "struct S { a: array<array<u32, 65535>, 65535> }" + fn("_ = S();"),
            "zero value of type 'S' is too large"
        )
        expectTypeError(
            "alias A = array<array<vec4f, 65535>, 65535>;" + fn("_ = A();"),
            "zero value of type 'array<array<vec4<f32>, 65535>, 65535>' is too large"
        )

        // 2^26 and 2^26 + 1 values in a struct of arrays and in a struct with a struct inside.
        expectNoError("struct S { a: array<array<u32, 1023>, 65535>, b: array<u32, 1021> }" + fn("_ = S();"))
        expectTypeError(
            "struct S { a: array<array<u32, 1023>, 65535>, b: array<u32, 1022> }" + fn("_ = S();"),
            "zero value of type 'S' is too large"
        )
        expectNoError("struct T { a: array<u32, 1799> } struct S { t: array<T, 37262> }" + fn("_ = S();"))
        expectTypeError(
            "struct T { a: array<u32, 1800> } struct S { t: array<T, 37262> }" + fn("_ = S();"),
            "zero value of type 'S' is too large"
        )

        // The fuzzer's artifact: a 15-level zero value assigned to a storage buffer of another type.
        func nested(_ counts: [String]) -> String {
            counts.reduce("u32") { "array<\($0), \($1)>" }
        }
        let ones = [String](repeating: "1", count: 15)
        var counts = ones
        counts[0] = "0x80000000u"
        counts[5] = "2"
        var printedCounts = counts
        printedCounts[0] = "2147483648"
        expectTypeError(
            "@group(0) @binding(0) var<storage, read_write> buffer: \(nested(ones));" + fn("buffer = \(nested(counts))();"),
            "zero value of type '\(nested(printedCounts))' is too large"
        )
    }

    // The declarations, reads, constructors and assignments that convert a constant leave its elements shared. As
    // separate copies these values would hold 1M, 4M and 2M scalars.
    @Test
    func sharedConstantElementsStayShared() {
        expectNoError(
            "const c = array<array<u32, 65535>, 16>();\n"
                + "const d = array(c, c, c, c);\n"
                + "struct S { a: array<array<u32, 65535>, 16>, b: array<array<u32, 65535>, 16> }\n"
                + "const s = S();\n"
                + "var<private> p: array<array<u32, 65535>, 16>;\n"
                + "fn f(x: array<array<u32, 65535>, 16>) -> array<array<u32, 65535>, 16> { return x; }\n"
                + fn(
                    "_ = c; _ = c; _ = d; _ = d; _ = s; _ = s.b; let a = d; var v = c; v = s.a; p = c; _ = f(c);\n"
                        + "const_assert d[3][15][65534] == 0u && s.b[15][65534] == 0u;"
                )
        )
    }
}

private func expectTypeError(
    _ wgsl: String,
    _ errorMessage: String,
    _ span: SourceSpan,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let result = onCompileThread { compileThread -> FailedCheck? in
        switch compileThread.staticCheck(wtfSource(wgsl)) {
        case .success:
            return nil
        case .failure(let failedCheck):
            return failedCheck
        }
    }
    guard let result else {
        Issue.record("staticCheck succeeded", sourceLocation: sourceLocation)
        return
    }
    #expect(result.errors.count == 1, sourceLocation: sourceLocation)
    expectMessage(result.errors.first, errorMessage, sourceLocation: sourceLocation)
    #expect(result.errors.first?.span == span, sourceLocation: sourceLocation)
}
