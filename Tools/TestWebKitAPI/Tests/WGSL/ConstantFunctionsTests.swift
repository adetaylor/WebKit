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

private func makeModule() -> ShaderModule {
    ShaderModule(source: SourceText(""))
}

private func vector(_ elements: ConstantValue...) -> ConstantValue {
    .vector(ConstantVector(elements))
}

private func half(_ bitPattern: UInt16) -> ConstantValue {
    .half(Half(bitPattern: bitPattern))
}

/// A struct type whose members are `members` in that order, with the struct type's field map keyed by the members'
/// original names, as TypeCheck builds it.
private func makeStructType(_ module: inout ShaderModule, _ members: [(name: StaticString, type: TypeID)]) -> TypeID {
    var memberIDs: [StructureMemberID] = []
    var fields = SymbolMap<TypeID>()
    for member in members {
        let typeExpression = module.constructIdentifierExpression(span: .empty, identifier: module.makeIdentifier("t"))
        module.setInferredType(member.type, for: typeExpression)
        let name = module.makeIdentifier(member.name)
        _ = fields.add(name.symbol, member.type)
        memberIDs.append(
            module.constructStructureMember(
                span: .empty,
                name: name,
                type: typeExpression,
                attributes: module.makeEmptyList(AttributeID.self)
            )
        )
    }
    let structure = module.constructStructure(
        span: .empty,
        name: module.makeIdentifier("S"),
        members: module.makeList(memberIDs),
        role: .userDefined
    )
    return module.types.structType(structure, fields)
}

@Suite
struct WGSLConstantFunctionsTests {
    @Test
    func zeroValueOfScalars() {
        let module = makeModule()
        #expect(zeroValue(module, FixedTypeID.abstractInt) == .int64(0))
        #expect(zeroValue(module, FixedTypeID.i32) == .int32(0))
        #expect(zeroValue(module, FixedTypeID.u32) == .uint32(0))
        #expect(zeroValue(module, FixedTypeID.abstractFloat) == .double(0))
        #expect(zeroValue(module, FixedTypeID.f32) == .float(0))
        #expect(zeroValue(module, FixedTypeID.f16) == half(0))
        #expect(zeroValue(module, FixedTypeID.bool) == .bool(false))
    }

    @Test
    func zeroValueOfVectorsMatricesAndArrays() {
        var module = makeModule()
        let vec3f = module.types.vectorType(3, FixedTypeID.f32)
        let mat2x3h = module.types.matrixType(2, 3, FixedTypeID.f16)
        let vec2u = module.types.vectorType(2, FixedTypeID.u32)
        let arrayOfVec2u = module.types.arrayType(vec2u, .creationFixed(3))
        #expect(zeroValue(module, vec3f) == vector(.float(0), .float(0), .float(0)))
        #expect(
            zeroValue(module, mat2x3h)
                == .matrix(ConstantMatrix(columns: 2, rows: 3, [ConstantValue](repeating: half(0), count: 6)))
        )
        let zeroVec2u = vector(.uint32(0), .uint32(0))
        #expect(zeroValue(module, arrayOfVec2u) == .array(ConstantArray([zeroVec2u, zeroVec2u, zeroVec2u])))
    }

    // DEV-02: the fields of a zero-valued struct are set in member declaration order.
    @Test
    func zeroValueOfStructs() {
        var module = makeModule()
        let arrayOfF32 = module.types.arrayType(FixedTypeID.f32, .creationFixed(2))
        let inner = makeStructType(&module, [(name: "z", type: FixedTypeID.bool)])
        let outer = makeStructType(&module, [(name: "b", type: FixedTypeID.i32), (name: "a", type: arrayOfF32), (name: "s", type: inner)])
        let arrayOfOuter = module.types.arrayType(outer, .creationFixed(2))

        let value = zeroValue(module, arrayOfOuter)
        guard case .array(let array) = value, array.elements.count == 2, case .struct(let constantStruct) = array.elements[1] else {
            Issue.record("not an array of two structs")
            return
        }
        #expect(array.elements[0] == array.elements[1])
        let names = constantStruct.fields.map { String(decoding: module.symbols.codeUnits(of: $0.key), as: UTF16.self) }
        #expect(names == ["b", "a", "s"])
        #expect(constantStruct.fields[0].value == .int32(0))
        #expect(constantStruct.fields[1].value == .array(ConstantArray([.float(0), .float(0)])))
        guard case .struct(let innerValue) = constantStruct.fields[2].value else {
            Issue.record("the nested struct field is not a struct")
            return
        }
        #expect(innerValue.fields.count == 1)
        #expect(innerValue.fields[0].value == .bool(false))
    }

    // Arrays nested 500 deep through aliases: the type walk is iterative; the constant itself still nests 500 deep.
    @Test
    func zeroValueOfDeeplyNestedArrays() {
        let depth = 500
        let nesting = onCompileThread { _ in
            var module = makeModule()
            var type = FixedTypeID.i32
            var level = 0
            while level < depth {
                type = module.types.arrayType(type, .creationFixed(1))
                level += 1
            }
            var value = zeroValue(module, type)
            var nesting = 0
            while case .array(let array) = value, array.elements.count == 1 {
                value = array.elements[0]
                nesting += 1
            }
            return (nesting: nesting, leafIsZero: value == .int32(0))
        }
        #expect(nesting.nesting == depth)
        #expect(nesting.leafIsZero)
    }

    @Test
    func staticCastOfFloatToIntegerClamps() {
        let module = makeModule()
        let i32 = FixedTypeID.i32
        let u32 = FixedTypeID.u32
        let abstractInt = FixedTypeID.abstractInt
        #expect(convertValue(module, i32, .float(3e9)) == .int32(2_147_483_520))
        #expect(convertValue(module, i32, .float(-3e9)) == .int32(.min))
        #expect(convertValue(module, i32, .float(-1.9)) == .int32(-1))
        #expect(convertValue(module, i32, .float(.nan)) == .int32(0))
        #expect(convertValue(module, u32, .float(-1)) == .uint32(0))
        #expect(convertValue(module, u32, .float(5e9)) == .uint32(4_294_967_040))
        #expect(convertValue(module, abstractInt, .float(1e30)) == .int64(.max))
        #expect(convertValue(module, abstractInt, .float(-1e30)) == .int64(.min))
        // half: clamped to ±65504.
        #expect(convertValue(module, i32, half(0x7BFF)) == .int32(65_504))
        #expect(convertValue(module, i32, half(0xFC00)) == .int32(-65_504))
        #expect(convertValue(module, u32, half(0xC500)) == .uint32(0))
        #expect(convertValue(module, i32, half(0x7E00)) == .int32(0))
    }

    // DEV-13: static_cast from double is not clamped in C++ (UB); arm64 FCVTZS/FCVTZU saturate and map NaN to 0.
    @Test
    func DEV_13_staticCastOfDoubleToIntegerSaturates() {
        let module = makeModule()
        #expect(convertValue(module, FixedTypeID.i32, .double(3e9)) == .int32(.max))
        #expect(convertValue(module, FixedTypeID.i32, .double(-3e9)) == .int32(.min))
        #expect(convertValue(module, FixedTypeID.i32, .double(.nan)) == .int32(0))
        #expect(convertValue(module, FixedTypeID.u32, .double(-1)) == .uint32(0))
        #expect(convertValue(module, FixedTypeID.u32, .double(5e9)) == .uint32(.max))
        #expect(convertValue(module, FixedTypeID.abstractInt, .double(1e19)) == .int64(.max))
        #expect(convertValue(module, FixedTypeID.abstractInt, .double(-1e19)) == .int64(.min))
        #expect(convertValue(module, FixedTypeID.abstractInt, .double(-2.5)) == .int64(-2))
    }

    @Test
    func staticCastBetweenOtherAlternatives() {
        let module = makeModule()
        #expect(convertValue(module, FixedTypeID.u32, .int32(-1)) == .uint32(.max))
        #expect(convertValue(module, FixedTypeID.i32, .uint32(.max)) == .int32(-1))
        #expect(convertValue(module, FixedTypeID.i32, .int64(0x1_0000_0005)) == .int32(5))
        #expect(convertValue(module, FixedTypeID.i32, .bool(true)) == .int32(1))
        #expect(convertValue(module, FixedTypeID.bool, .float(.nan)) == .bool(true))
        #expect(convertValue(module, FixedTypeID.bool, .float(-0.0)) == .bool(false))
        #expect(convertValue(module, FixedTypeID.bool, half(0x8000)) == .bool(false))
        #expect(convertValue(module, FixedTypeID.bool, .int64(2)) == .bool(true))
        #expect(convertValue(module, FixedTypeID.f16, .int32(70_000)) == half(0x7C00))
        #expect(convertValue(module, FixedTypeID.f16, .uint32(65_519)) == half(0x7BFF))
        #expect(convertValue(module, FixedTypeID.f16, .int32(65_520)) == half(0x7C00))
        #expect(convertValue(module, FixedTypeID.f16, .bool(true)) == half(0x3C00))
        #expect(convertValue(module, FixedTypeID.f32, .int64(16_777_217)) == .float(16_777_216))
        #expect(convertValue(module, FixedTypeID.f32, .double(0.1)) == .float(Float(0.1)))
        #expect(convertValue(module, FixedTypeID.abstractFloat, half(0x3555)) == .double(Double(Float(Half(bitPattern: 0x3555)))))
        #expect(convertValue(module, FixedTypeID.abstractInt, .uint32(.max)) == .int64(4_294_967_295))
    }

    @Test
    func bitwiseCast() {
        let module = makeModule()
        #expect(convertValue(module, FixedTypeID.f32, .uint32(0x3F80_0000), .bitwiseCast) == .float(1))
        #expect(convertValue(module, FixedTypeID.i32, .float(-0.0), .bitwiseCast) == .int32(.min))
        #expect(convertValue(module, FixedTypeID.u32, .int32(-1), .bitwiseCast) == .uint32(.max))
        #expect(convertValue(module, FixedTypeID.f32, .int32(0x7FC0_0001), .bitwiseCast) == .float(Float(bitPattern: 0x7FC0_0001)))
        #expect(convertValue(module, FixedTypeID.f16, half(0x7D01), .bitwiseCast) == half(0x7D01))
    }

    @Test
    func vectorConstructors() {
        var module = makeModule()
        let vec3f = module.types.vectorType(3, FixedTypeID.f32)
        let vec2i = module.types.vectorType(2, FixedTypeID.i32)
        let vec4u = module.types.vectorType(4, FixedTypeID.u32)
        #expect(constantVector(module, vec3f, [], 3) == vector(.float(0), .float(0), .float(0)))
        #expect(constantVector(module, vec3f, [.double(1.5)], 3) == vector(.float(1.5), .float(1.5), .float(1.5)))
        #expect(constantVector(module, vec2i, [vector(.int64(-7), .int64(8))], 2) == vector(.int32(-7), .int32(8)))
        #expect(constantVector(module, vec2i, [vector(.float(2.75), .float(-2.75))], 2) == vector(.int32(2), .int32(-2)))
        #expect(
            constantVector(module, vec4u, [.uint32(1), vector(.uint32(2), .uint32(3)), .uint32(4)], 4)
                == vector(.uint32(1), .uint32(2), .uint32(3), .uint32(4))
        )
    }

    @Test
    func matrixConstructors() {
        var module = makeModule()
        let mat2x2f = module.types.matrixType(2, 2, FixedTypeID.f32)
        let mat2x2h = module.types.matrixType(2, 2, FixedTypeID.f16)
        let mat3x2f = module.types.matrixType(3, 2, FixedTypeID.f32)
        let elements: [ConstantValue] = [.float(1), .float(2), .float(3), .float(4)]
        #expect(
            constantMatrix(module, mat2x2f, [], 2, 2)
                == .matrix(ConstantMatrix(columns: 2, rows: 2, [ConstantValue](repeating: .float(0), count: 4)))
        )
        #expect(constantMatrix(module, mat2x2f, elements, 2, 2) == .matrix(ConstantMatrix(columns: 2, rows: 2, elements)))
        #expect(
            constantMatrix(module, mat2x2f, [vector(.float(1), .float(2)), vector(.float(3), .float(4))], 2, 2)
                == .matrix(ConstantMatrix(columns: 2, rows: 2, elements))
        )
        let abstract = ConstantMatrix(columns: 2, rows: 2, [.double(1), .double(0.1), .double(65_520), .double(-0.0)])
        #expect(
            constantMatrix(module, mat2x2h, [.matrix(abstract)], 2, 2)
                == .matrix(ConstantMatrix(columns: 2, rows: 2, [half(0x3C00), half(0x2E66), half(0x7C00), half(0x8000)]))
        )
        let columns = [vector(.float(1), .float(2)), vector(.float(3), .float(4)), vector(.float(5), .float(6))]
        let flattened: [ConstantValue] = [.float(1), .float(2), .float(3), .float(4), .float(5), .float(6)]
        #expect(constantMatrix(module, mat3x2f, columns, 3, 2) == .matrix(ConstantMatrix(columns: 3, rows: 2, flattened)))
    }

    @Test
    func functionNamesAreTheCxxStems() {
        #expect(ConstantFunctionName.allCases.count == 118)
        #expect(ValidationFunctionName.allCases.count == 16)
        #expect(ConstantFunctionName.allCases.first == .add)
        #expect(ConstantFunctionName.allCases.last == .bitcast)
        #expect(ConstantFunctionName(rawValue: "mat4x3") == .mat4x3)
        #expect(ConstantFunctionName(rawValue: "pack4xI8Clamp") == .pack4xI8Clamp)
        #expect(ValidationFunctionName.allCases.first == .clamp)
        #expect(ValidationFunctionName.allCases.last == .quadBroadcast)
    }
}

// MARK: - DEV-03

extension WGSLConstantFunctionsTests {
    // DEV-03: a constant nested deeper than a stack holds frames for (type nesting has no depth limit: alias and struct
    // chains bypass the composite limit of 15) is built, scanned, converted, dumped and freed without native frames per
    // level. The test runs on its own thread (512 KiB), which holds a few hundred levels of any of these at -Onone.
    @Test
    func DEV_03_deeplyNestedConstantsUseNoStackPerLevel() {
        let depth = 20_000
        var module = makeModule()
        var arrayType = FixedTypeID.u32
        var structType = FixedTypeID.u32
        var level = 0
        while level < depth {
            arrayType = module.types.arrayType(arrayType, .creationFixed(1))
            structType = makeStructType(&module, [(name: "m", type: structType)])
            level += 1
        }
        let member = module.symbols.intern("m")
        func nested(_ leaf: ConstantValue, asStruct: Bool) -> ConstantValue {
            var value = leaf
            var level = 0
            while level < depth {
                if asStruct {
                    var constantStruct = ConstantStruct()
                    constantStruct.set(member, value)
                    value = .struct(constantStruct)
                } else {
                    value = .array(ConstantArray([value]))
                }
                level += 1
            }
            return value
        }
        func leaf(_ value: ConstantValue) -> (ConstantValue, levels: Int) {
            var value = value
            var levels = 0
            while true {
                switch value {
                case .array(let array) where array.elements.count == 1:
                    value = array.elements[0]
                case .struct(let constantStruct) where constantStruct.fields.count == 1:
                    value = constantStruct.fields[0].value
                case .float, .half, .double, .int32, .uint32, .int64, .bool, .array, .vector, .matrix, .struct:
                    return (value, levels)
                }
                levels += 1
            }
        }
        for (asStruct, type) in [(false, arrayType), (true, structType)] {
            var zero = zeroValue(module, type)
            #expect(leaf(zero) == (.uint32(0), depth))
            let unchanged = zero
            #expect(convertValueImpl(.empty, type, &zero, module.types))
            #expect(zero == unchanged)

            var abstract = nested(.int64(7), asStruct: asStruct)
            #expect(convertValueImpl(.empty, type, &abstract, module.types))
            #expect(leaf(abstract) == (.uint32(7), depth))

            var negative = nested(.int64(-1), asStruct: asStruct)
            #expect(!convertValueImpl(.empty, type, &negative, module.types))
            let open = asStruct ? "struct { m: " : "array("
            let close = asStruct ? " }" : ")"
            #expect(
                String(decoding: module.dump(negative).codeUnits, as: UTF16.self)
                    == String(repeating: open, count: depth) + "-1" + String(repeating: close, count: depth)
            )
        }
        // A level that a copy still holds outlives the levels above it, and is freed with its own levels after them.
        var outer: ConstantValue? = nested(.uint32(1), asStruct: false)
        var inner: ConstantValue?
        if case .array(let array) = outer {
            inner = array.elements[0]
        }
        outer = nil
        #expect(inner.map { leaf($0) == (.uint32(1), depth - 1) } == true)
        inner = nil
        #expect(inner == nil)
    }
}
