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

import Darwin
import Testing
@_spi(Testing) import WGSL

private func string(_ text: MessageText) -> String {
    String(decoding: text.codeUnits, as: UTF16.self)
}

private func dumped(_ value: ConstantValue, _ symbols: borrowing SymbolTable = SymbolTable.predeclared) -> String {
    var text = MessageText(codeUnits: [])
    value.dump(into: &text, symbols)
    return string(text)
}

private func makeStructure() -> StructureID {
    var structures = Arena<StructureID, UInt32>()
    return structures.append(0)
}

private func vector(_ elements: ConstantValue...) -> ConstantValue {
    .vector(ConstantVector(elements))
}

private func array(_ elements: ConstantValue...) -> ConstantValue {
    .array(ConstantArray(elements))
}

private func converted(_ value: ConstantValue, _ type: TypeID, _ types: borrowing TypeStore) -> ConstantValue? {
    var result = value
    return convertValueImpl(.empty, type, &result, types) ? result : nil
}

private func keyNames(_ constantStruct: ConstantStruct, _ symbols: borrowing SymbolTable) -> [String] {
    var names: [String] = []
    var index = 0
    while index < constantStruct.fields.count {
        names.append(string(symbols.text(of: constantStruct.fields[index].key)))
        index += 1
    }
    return names
}

/// A convertValueImpl that writes to every element, as the C++ does: the reference of `convertWritesOnlyWhatChanges`.
private func eagerConvert(_ type: TypeID, _ value: inout ConstantValue, _ types: borrowing TypeStore) -> Bool {
    switch types[type] {
    case .primitive:
        return convertValueImpl(.empty, type, &value, types)
    case .vector(let vectorType):
        guard case .vector(var vector) = value else {
            Issue.record("not a vector")
            return false
        }
        defer { value = .vector(vector) }
        return eagerConvert(vectorType.element, &vector.elements, types)
    case .matrix(let matrixType):
        guard case .matrix(var matrix) = value else {
            Issue.record("not a matrix")
            return false
        }
        defer { value = .matrix(matrix) }
        return eagerConvert(matrixType.element, &matrix.elements, types)
    case .array(let arrayType):
        guard case .array(var array) = value else {
            Issue.record("not an array")
            return false
        }
        defer { value = .array(array) }
        return eagerConvert(arrayType.element, &array.elements, types)
    case .struct(let structType):
        guard case .struct(var constantStruct) = value else {
            Issue.record("not a struct")
            return false
        }
        defer { value = .struct(constantStruct) }
        let fields = types.fields(of: structType.fields)
        var index = 0
        while index < constantStruct.fields.count {
            let key = constantStruct.fields[index].key
            if let fieldType = fields.find(key) {
                var field = constantStruct.fields[index].value
                let converted = eagerConvert(fieldType, &field, types)
                constantStruct.set(key, field)
                if !converted {
                    return false
                }
            }
            index += 1
        }
        return true
    case .primitiveStruct(let primitiveStruct):
        guard case .struct(var constantStruct) = value else {
            Issue.record("not a struct")
            return false
        }
        defer { value = .struct(constantStruct) }
        let keys = Types.PrimitiveStruct.keys(primitiveStruct.kind)
        var index = 0
        while index < constantStruct.fields.count {
            let key = constantStruct.fields[index].key
            guard let position = keys.tryGet(key) else {
                Issue.record("not a field of the primitive struct")
                return false
            }
            var field = constantStruct.fields[index].value
            let converted = eagerConvert(types[primitiveStruct.values, position], &field, types)
            constantStruct.set(key, field)
            if !converted {
                return false
            }
            index += 1
        }
        return true
    case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic, .typeConstructor:
        Issue.record("a type without constants")
        return false
    }
}

private func eagerConvert(_ elementType: TypeID, _ elements: inout [ConstantValue], _ types: borrowing TypeStore) -> Bool {
    var index = 0
    while index < elements.count {
        if !eagerConvert(elementType, &elements[index], types) {
            return false
        }
        index += 1
    }
    return true
}

/// The constant values of a module's identifier expressions, with the identifiers' names, in visiting order.
private struct IdentifierConstants: ASTVisitor, ~Copyable {
    var shaderModule: ShaderModule
    var expectedError: CompilationMessage?
    var hasError = false
    var values: [(name: String, value: ConstantValue)] = []

    init(shaderModule: consuming ShaderModule) {
        self.shaderModule = shaderModule
    }

    mutating func visit(_ expression: IdentifierExpression, _ id: ExpressionID) {
        guard let value = shaderModule.constantValue(of: id) else {
            return
        }
        let name = String(decoding: shaderModule.symbols.codeUnits(of: shaderModule.symbol(of: expression.identifier)), as: UTF16.self)
        values.append((name: name, value: value))
    }
}

/// What `typeCheckedReadsShareTheConstantsStorage` finds copied among the identifier values of its module: the reads of
/// `c` (and of `a`, if it has a value) must hold one buffer of elements whose three inner arrays are one buffer, and the
/// reads of `d` two references to that buffer.
private func sharingFailures(_ values: [(name: String, value: ConstantValue)]) -> [String] {
    var failures: [String] = []
    var cElements: [ConstantValue]?
    var cInnerElements: [ConstantValue]?
    var reads = (c: 0, d: 0)
    var index = 0
    while index < values.count {
        let (name, value) = values[index]
        index += 1
        guard case .array(let outer) = value else {
            failures.append("\(name): not an array")
            continue
        }
        var elementIndex = 0
        switch name {
        case "c", "a":
            reads.c += name == "c" ? 1 : 0
            if let cElements, !outer.elements.isTriviallyIdentical(to: cElements) {
                failures.append("\(name) (read \(index)): a copy of c's elements")
            }
            cElements = cElements ?? outer.elements
            while elementIndex < outer.elements.count {
                guard case .array(let inner) = outer.elements[elementIndex] else {
                    failures.append("\(name) (read \(index)): an element that is not an array")
                    break
                }
                if let cInnerElements, !inner.elements.isTriviallyIdentical(to: cInnerElements) {
                    failures.append("\(name) (read \(index)): a copy of element \(elementIndex)")
                }
                cInnerElements = cInnerElements ?? inner.elements
                elementIndex += 1
            }
        case "d":
            reads.d += 1
            while elementIndex < outer.elements.count {
                guard case .array(let element) = outer.elements[elementIndex], let cElements,
                    element.elements.isTriviallyIdentical(to: cElements)
                else {
                    failures.append("d (read \(index)): element \(elementIndex) is not c's elements")
                    break
                }
                elementIndex += 1
            }
        default:
            failures.append("an unexpected value of \(name)")
        }
    }
    if reads.c != 6 || reads.d != 2 {
        failures.append("\(reads.c) reads of c and \(reads.d) of d have a value, not 6 and 2")
    }
    return failures
}

/// Runs `body` on the compile thread when the module is built with -Onone (TestWGSLAPI.swift).
private func onTestCompileThread<Result: Sendable>(_ body: @escaping @Sendable () -> Result) -> Result {
    if CompileThread.recommendedStackSize != nil {
        return onCompileThread { _ in body() }
    }
    return body()
}

/// The number of levels of `value`, followed down its first element, that are arrays of `width` elements sharing one
/// value (one buffer, or one scalar at the last level).
private func sharedLevels(_ value: ConstantValue, width: Int) -> Int {
    var levels = 0
    var value = value
    while case .array(let array) = value, array.elements.count == width {
        var index = 1
        while index < width {
            if case .array(let first) = array.elements[0], case .array(let other) = array.elements[index] {
                guard first.elements.isTriviallyIdentical(to: other.elements) else {
                    return levels
                }
            } else if array.elements[0] != array.elements[index] {
                return levels
            }
            index += 1
        }
        value = array.elements[0]
        levels += 1
    }
    return levels
}

/// Whether `source` parses, has its globals reordered and type-checks without an error, and the CPU time that took, on
/// the compile thread when the module is built with -Onone.
private func typeChecks(_ source: String) -> (ok: Bool, cpuTime: Duration) {
    onTestCompileThread { () -> (ok: Bool, cpuTime: Duration) in
        var ok = false
        let cpuTime = threadCPUTime {
            var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
            func failed(_ result: FailedCheck?) -> Bool {
                guard let result else {
                    return false
                }
                return !result.errors.isEmpty
            }
            ok = !(failed(parse(&module)) || failed(reorderGlobals(&module)) || failed(typeCheck(&module)))
        }
        return (ok: ok, cpuTime: cpuTime)
    }
}

/// SplitMix64, for reproducible random cases.
private struct TestRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[below(values.count)]
    }
}

/// Random types for `convertWritesOnlyWhatChanges`; `structFields` gets the field names of each struct type, in order.
private func randomType(
    _ random: inout TestRandom,
    _ types: inout TypeStore,
    _ names: [Symbol],
    _ structure: StructureID,
    _ structFields: inout [TypeID: [Symbol]],
    depth: Int
) -> TypeID {
    let scalars = [
        types.abstractIntType, types.abstractFloatType, types.i32Type, types.u32Type, types.f32Type, types.f16Type, types.boolType,
    ]
    let floats = [types.abstractFloatType, types.f32Type, types.f16Type]
    switch depth == 0 ? 0 : random.below(8) {
    case 0, 1:
        return random.pick(scalars)
    case 2:
        return types.vectorType(UInt8(2 + random.below(3)), random.pick(scalars))
    case 3:
        return types.matrixType(UInt8(2 + random.below(3)), UInt8(2 + random.below(3)), random.pick(floats))
    case 4, 5:
        let element = randomType(&random, &types, names, structure, &structFields, depth: depth - 1)
        return types.arrayType(element, .creationFixed(UInt32(1 + random.below(4))))
    case 6:
        var fields = SymbolMap<TypeID>()
        var fieldNames: [Symbol] = []
        var previousType: TypeID? = nil
        let count = 1 + random.below(3)
        while fieldNames.count < count {
            let name = names[fieldNames.count]
            var fieldType = randomType(&random, &types, names, structure, &structFields, depth: depth - 1)
            if let previousType, random.below(2) == 0 {
                fieldType = previousType
            }
            fields.add(name, fieldType)
            fieldNames.append(name)
            previousType = fieldType
        }
        let type = types.structType(structure, fields)
        structFields[type] = fieldNames
        return type
    default:
        let fract = random.pick(floats)
        return random.below(2) == 0
            ? types.frexpResultType(fract, random.pick([types.i32Type, types.abstractIntType]))
            : types.modfResultType(fract, fract)
    }
}

/// A random value that `convertValueImpl` converts to `type` without trapping, with representations that need no
/// change, need one or fail, and with elements that share their storage, next to each other or not, at one level or at
/// several (`pool` holds the composite values made so far, by type).
private func randomValue(
    _ type: TypeID,
    _ random: inout TestRandom,
    _ types: borrowing TypeStore,
    _ structFields: [TypeID: [Symbol]],
    _ extraField: Symbol,
    _ pool: inout [TypeID: [ConstantValue]]
) -> ConstantValue {
    if let values = pool[type], random.below(4) == 0 {
        return random.pick(values)
    }
    let value = freshRandomValue(type, &random, types, structFields, extraField, &pool)
    switch value {
    case .array, .vector, .matrix, .struct:
        pool[type, default: []].append(value)
    case .float, .half, .double, .int32, .uint32, .int64, .bool:
        break
    }
    return value
}

private func freshRandomValue(
    _ type: TypeID,
    _ random: inout TestRandom,
    _ types: borrowing TypeStore,
    _ structFields: [TypeID: [Symbol]],
    _ extraField: Symbol,
    _ pool: inout [TypeID: [ConstantValue]]
) -> ConstantValue {
    let integers: [Int64] = [0, 1, -1, 2_147_483_647, 2_147_483_648, -2_147_483_649, 4_294_967_296, .max]
    let doubles: [Double] = [0.5, -0.0, 65_504, 70_000, 1e39, 1e-50, .infinity, .nan]
    let floats: [Float] = [1.5, -0.0, 3e38, .infinity, .nan]
    let halves = [Half(Float(1.5)), Half(bitPattern: 0x8000), Half(bitPattern: 0x7C00), Half(bitPattern: 0x7E00)]
    func elements(
        _ elementType: TypeID,
        _ count: Int,
        _ random: inout TestRandom,
        _ pool: inout [TypeID: [ConstantValue]]
    ) -> [ConstantValue] {
        var result: [ConstantValue] = []
        let shared = randomValue(elementType, &random, types, structFields, extraField, &pool)
        while result.count < count {
            result.append(
                random.below(2) == 0 ? shared : randomValue(elementType, &random, types, structFields, extraField, &pool)
            )
        }
        return result
    }
    switch types[type] {
    case .primitive(let primitive):
        switch primitive.kind {
        case .abstractInt:
            return .int64(random.pick(integers))
        case .abstractFloat:
            return random.below(2) == 0 ? .double(random.pick(doubles)) : .int64(random.pick(integers))
        case .i32:
            return random.below(2) == 0 ? .int32(Int32(truncatingIfNeeded: random.pick(integers))) : .int64(random.pick(integers))
        case .u32:
            return random.below(2) == 0 ? .uint32(UInt32(truncatingIfNeeded: random.pick(integers))) : .int64(random.pick(integers))
        case .f32:
            return random.pick([.float(random.pick(floats)), .double(random.pick(doubles)), .int64(random.pick(integers))])
        case .f16:
            return random.pick([.half(random.pick(halves)), .double(random.pick(doubles)), .int64(random.pick(integers))])
        case .bool:
            return .bool(random.below(2) == 0)
        case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
            return .bool(false)
        }
    case .vector(let vector):
        return .vector(ConstantVector(elements(vector.element, Int(vector.size), &random, &pool)))
    case .matrix(let matrix):
        let count = Int(matrix.columns) * Int(matrix.rows)
        return .matrix(
            ConstantMatrix(columns: UInt32(matrix.columns), rows: UInt32(matrix.rows), elements(matrix.element, count, &random, &pool))
        )
    case .array(let array):
        guard case .creationFixed(let size) = array.size else {
            return .bool(false)
        }
        return .array(ConstantArray(elements(array.element, Int(size), &random, &pool)))
    case .struct(let structType):
        let fields = types.fields(of: structType.fields)
        var names = structFields[type] ?? []
        if random.below(3) == 0 {
            names.append(extraField)
        }
        var constantStruct = ConstantStruct()
        var previous: (type: TypeID, value: ConstantValue)? = nil
        while !names.isEmpty {
            let name = names.remove(at: random.below(names.count))
            guard let fieldType = fields.find(name) else {
                constantStruct.set(name, .int64(7))
                continue
            }
            var fieldValue = randomValue(fieldType, &random, types, structFields, extraField, &pool)
            if let previous, previous.type == fieldType, random.below(2) == 0 {
                fieldValue = previous.value
            }
            constantStruct.set(name, fieldValue)
            previous = (type: fieldType, value: fieldValue)
        }
        return .struct(constantStruct)
    case .primitiveStruct(let primitiveStruct):
        let first = randomValue(types[primitiveStruct.values, 0], &random, types, structFields, extraField, &pool)
        let second = randomValue(types[primitiveStruct.values, 1], &random, types, structFields, extraField, &pool)
        return .struct(
            primitiveStruct.kind == .frexpResult
                ? .frexpResult(fract: first, exp: second) : .modfResult(fract: first, whole: second)
        )
    case .function, .texture, .textureStorage, .textureDepth, .reference, .pointer, .atomic, .typeConstructor:
        return .bool(false)
    }
}

@Suite
struct WGSLConstantValueTests {
    @Test
    func defaultValueIsFloatZero() {
        #expect(ConstantValue.defaultValue == .float(0))
        #expect(ConstantArray(size: 2).elements == [.float(0), .float(0)])
        #expect(ConstantVector(size: 3).elements == [.float(0), .float(0), .float(0)])
        let matrix = ConstantMatrix(columns: 2, rows: 3)
        #expect(matrix.elements == [ConstantValue](repeating: .float(0), count: 6))
        var symbols = SymbolTable.predeclared
        #expect(ConstantStruct().get(symbols.intern("x")) == .float(0))
    }

    // The grammar of C++ `ConstantValue::dump`.
    @Test
    func dumpScalars() {
        let cases: [(value: ConstantValue, text: String)] = [
            (.double(1.5), "1.5"),
            (.double(1e39), "1e+39"),
            (.double(.infinity), "Infinity"),
            (.double(-.infinity), "-Infinity"),
            (.double(.nan), "NaN"),
            (.double(0.1), "0.1"),
            (.float(1.5), "1.5f"),
            (.float(0.1), "0.1f"),
            (.float(-0.0), "0f"),
            (.float(.infinity), "Infinity"),
            (.float(-.infinity), "-Infinity"),
            (.float(.nan), "NaN"),
            (.half(Half(Float(1.5))), "1.5h"),
            (.half(Half(bitPattern: 0x7BFF)), "65504h"),
            (.half(Half(bitPattern: 0xC000)), "-2h"),
            (.half(Half(bitPattern: 0x7C00)), "Infinity"),
            (.half(Half(bitPattern: 0xFC00)), "-Infinity"),
            (.half(Half(bitPattern: 0x7E00)), "NaN"),
            (.int64(42), "42"),
            (.int64(.min), "-9223372036854775808"),
            (.int64(3_000_000_000), "3000000000"),
            (.int32(-3), "-3i"),
            (.int32(.min), "-2147483648i"),
            (.uint32(.max), "4294967295u"),
            (.bool(true), "true"),
            (.bool(false), "false"),
        ]
        for testCase in cases {
            #expect(dumped(testCase.value) == testCase.text)
        }
    }

    @Test
    func dumpAggregates() {
        #expect(dumped(array(.int32(1), .int32(2))) == "array(1i, 2i)")
        #expect(dumped(.array(ConstantArray([]))) == "array()")
        #expect(dumped(vector(.float(1), .double(1e39))) == "vec2(1f, 1e+39)")
        #expect(dumped(vector(.bool(true), .bool(false), .bool(true), .bool(false))) == "vec4(true, false, true, false)")
        let matrix = ConstantMatrix(columns: 2, rows: 3, [.float(1), .float(2), .float(3), .float(4), .float(5), .float(6.5)])
        #expect(dumped(.matrix(matrix)) == "mat2x3(1f, 2f, 3f, 4f, 5f, 6.5f)")
        #expect(dumped(array(vector(.uint32(1), .uint32(2)), vector(.uint32(3), .uint32(4)))) == "array(vec2(1u, 2u), vec2(3u, 4u))")
        #expect(dumped(.struct(.frexpResult(fract: .float(0.5), exp: .int32(1)))) == "struct { fract: 0.5f, exp: 1i }")
        #expect(dumped(.struct(.modfResult(fract: .double(0.25), whole: .double(3)))) == "struct { fract: 0.25, whole: 3 }")
        #expect(dumped(.struct(ConstantStruct())) == "struct {  }")
    }

    // Conversion stops at the first element that does not fit, after converting the earlier ones in place, and the message
    // dumps that value. Each message is the C++ compiler's for the WGSL in the comment; the
    // values are what TypeCheck converts (constructor arguments already in their common abstract type).
    @Test
    func partialConversionBeforeDumping() {
        var module = ShaderModule(source: SourceText(""))
        let f32 = module.types.f32Type
        let f16 = module.types.f16Type
        let vec2f = module.types.vectorType(2, f32)
        let cases: [(value: ConstantValue, type: TypeID, typeName: MessageText, message: String)] = [
            // const a: vec2<f32> = vec2(1, 1e39);
            (vector(.double(1), .double(1e39)), vec2f, "vec2<f32>", "value vec2(1f, 1e+39) cannot be represented as 'vec2<f32>'"),
            // const b: vec3<i32> = vec3(1, 2, 3000000000);
            (
                vector(.int64(1), .int64(2), .int64(3_000_000_000)), module.types.vectorType(3, module.types.i32Type), "vec3<i32>",
                "value vec3(1i, 2i, 3000000000) cannot be represented as 'vec3<i32>'"
            ),
            // const c: mat2x2<f32> = mat2x2(1, 2.5, 3, 1e40);
            (
                .matrix(ConstantMatrix(columns: 2, rows: 2, [.double(1), .double(2.5), .double(3), .double(1e40)])),
                module.types.matrixType(2, 2, f32), "mat2x2<f32>",
                "value mat2x2(1f, 2.5f, 3f, 1e+40) cannot be represented as 'mat2x2<f32>'"
            ),
            // fn f() { var m = modf(1e39); }
            (
                .struct(.modfResult(fract: .double(0), whole: .double(1e39))), module.types.modfResultType(f32, f32), "__modf_result<f32>",
                "value struct { fract: 0f, whole: 1e+39 } cannot be represented as '__modf_result<f32>'"
            ),
            // fn k() { var m = modf(vec2(1.5, 1e39)); }
            (
                .struct(.modfResult(fract: vector(.double(0.5), .double(0)), whole: vector(.double(1), .double(1e39)))),
                module.types.modfResultType(vec2f, vec2f), "__modf_result<vec2<f32>>",
                "value struct { fract: vec2(0.5f, 0f), whole: vec2(1f, 1e+39) } cannot be represented as '__modf_result<vec2<f32>>'"
            ),
            // enable f16; const h: f16 = 70000;
            (.int64(70000), f16, "f16", "value 70000 cannot be represented as 'f16'"),
            // const e: f32 = 1e39;
            (.double(1e39), f32, "f32", "value 1e+39 cannot be represented as 'f32'"),
            // enable f16; const v: array<f16, 2> = array(1.5, 70000);
            (
                array(.double(1.5), .double(70000)), module.types.arrayType(f16, .creationFixed(2)), "array<f16, 2>",
                "value array(1.5h, 70000) cannot be represented as 'array<f16, 2>'"
            ),
            // const z: vec2<f32> = vec2(-0.0, 1e39);
            (vector(.double(-0.0), .double(1e39)), vec2f, "vec2<f32>", "value vec2(0f, 1e+39) cannot be represented as 'vec2<f32>'"),
            // const n: vec2<u32> = vec2(1, -1);
            (
                vector(.int64(1), .int64(-1)), module.types.vectorType(2, module.types.u32Type), "vec2<u32>",
                "value vec2(1u, -1) cannot be represented as 'vec2<u32>'"
            ),
            // const w: vec3<f32> = vec3(1e39, 1, 2);
            (
                vector(.double(1e39), .double(1), .double(2)), module.types.vectorType(3, f32), "vec3<f32>",
                "value vec3(1e+39, 1, 2) cannot be represented as 'vec3<f32>'"
            ),
            // enable f16; const q: vec4<f16> = vec4(0.1, 65504, -2, 65520);
            (
                vector(.double(0.1), .double(65504), .double(-2), .double(65520)), module.types.vectorType(4, f16), "vec4<f16>",
                "value vec4(0.099975586h, 65504h, -2h, 65520) cannot be represented as 'vec4<f16>'"
            ),
            // const t: array<vec2<i32>, 2> = array(vec2(1, 2), vec2(3, 3000000000));
            (
                array(vector(.int64(1), .int64(2)), vector(.int64(3), .int64(3_000_000_000))),
                module.types.arrayType(module.types.vectorType(2, module.types.i32Type), .creationFixed(2)), "array<vec2<i32>, 2>",
                "value array(vec2(1i, 2i), vec2(3i, 3000000000)) cannot be represented as 'array<vec2<i32>, 2>'"
            ),
            // An infinite AbstractFloat prints as `Infinity`.
            (
                .double(.infinity), module.types.abstractFloatType, "<AbstractFloat>",
                "value Infinity cannot be represented as '<AbstractFloat>'"
            ),
            (
                .double(-.infinity), module.types.abstractFloatType, "<AbstractFloat>",
                "value -Infinity cannot be represented as '<AbstractFloat>'"
            ),
        ]
        for testCase in cases {
            var value = testCase.value
            #expect(!convertValueImpl(.empty, testCase.type, &value, module.types))
            let message: MessageText = "value \(module.dump(value)) cannot be represented as '\(testCase.typeName)'"
            #expect(string(message) == testCase.message)
        }
    }

    @Test
    func convertScalars() {
        let types = TypeStore()
        // AbstractInt -> f32 goes through double (two roundings); StaticCast<float> rounds once.
        let doubleRounded: Int64 = (1 << 60) + (1 << 36) + 1
        #expect(Float(Double(doubleRounded)) != Float(doubleRounded))
        #expect(converted(.int64(doubleRounded), types.f32Type, types) == .float(Float(Double(doubleRounded))))
        #expect(converted(.int64(2049), types.f16Type, types) == .half(Half(Double(2049))))
        #expect(converted(.double(0.1), types.f32Type, types) == .float(0.1))
        #expect(converted(.float(0.5), types.f32Type, types) == .float(0.5))
        #expect(converted(.half(Half(Float(0.5))), types.f16Type, types) == .half(Half(Float(0.5))))
        #expect(converted(.double(0.1), types.f16Type, types) == .half(Half(0.1 as Double)))
        #expect(converted(.half(Half(Float(0.5))), types.f32Type, types) == nil)
        #expect(converted(.float(0.5), types.f16Type, types) == nil)
        #expect(converted(.int32(1), types.f32Type, types) == nil)

        #expect(converted(.int32(-7), types.i32Type, types) == .int32(-7))
        #expect(converted(.int64(-2_147_483_648), types.i32Type, types) == .int32(.min))
        #expect(converted(.int64(2_147_483_648), types.i32Type, types) == nil)
        #expect(converted(.uint32(1), types.i32Type, types) == nil)
        #expect(converted(.uint32(9), types.u32Type, types) == .uint32(9))
        #expect(converted(.int64(4_294_967_295), types.u32Type, types) == .uint32(.max))
        #expect(converted(.int64(-1), types.u32Type, types) == nil)
        #expect(converted(.int32(1), types.u32Type, types) == nil)

        #expect(converted(.int64(.min), types.abstractIntType, types) == .int64(.min))
        #expect(converted(.int64(-3), types.abstractFloatType, types) == .double(-3))
        #expect(converted(.double(.greatestFiniteMagnitude), types.abstractFloatType, types) == .double(.greatestFiniteMagnitude))
        #expect(converted(.double(.nan), types.abstractFloatType, types) == nil)
        #expect(converted(.bool(true), types.boolType, types) == .bool(true))

        let noConstants = [
            types.voidType, types.samplerType, types.samplerComparisonType, types.textureExternalType, types.accessModeType,
            types.texelFormatType, types.addressSpaceType,
        ]
        for type in noConstants {
            #expect(converted(.int64(0), type, types) == nil)
        }
    }

    @Test
    func convertAggregates() {
        var module = ShaderModule(source: SourceText(""))
        let f32 = module.types.f32Type
        let i32 = module.types.i32Type

        var vectorValue = vector(.int64(1), .double(2.5))
        #expect(convertValueImpl(.empty, module.types.vectorType(2, f32), &vectorValue, module.types))
        #expect(vectorValue == vector(.float(1), .float(2.5)))

        var arrayValue = array(vector(.int64(1), .int64(2)), vector(.int64(3), .int64(4)))
        let arrayType = module.types.arrayType(module.types.vectorType(2, i32), .creationFixed(2))
        #expect(convertValueImpl(.empty, arrayType, &arrayValue, module.types))
        #expect(arrayValue == array(vector(.int32(1), .int32(2)), vector(.int32(3), .int32(4))))

        var frexpValue = ConstantValue.struct(.frexpResult(fract: .double(0.75), exp: .int64(2)))
        #expect(convertValueImpl(.empty, module.types.frexpResultType(f32, i32), &frexpValue, module.types))
        #expect(frexpValue == .struct(.frexpResult(fract: .float(0.75), exp: .int32(2))))

        let x = module.symbols.intern("x")
        let y = module.symbols.intern("y")
        var fields = SymbolMap<TypeID>()
        fields.add(x, f32)
        fields.add(y, i32)
        let structType = module.types.structType(makeStructure(), fields)
        var constantStruct = ConstantStruct()
        constantStruct.set(x, .int64(1))
        constantStruct.set(y, .int64(2))
        var structValue = ConstantValue.struct(constantStruct)
        #expect(convertValueImpl(.empty, structType, &structValue, module.types))
        var expected = ConstantStruct()
        expected.set(x, .float(1))
        expected.set(y, .int32(2))
        #expect(structValue == .struct(expected))

        var tooBig = ConstantStruct()
        tooBig.set(x, .double(1e39))
        tooBig.set(y, .int64(2))
        var tooBigValue = ConstantValue.struct(tooBig)
        #expect(!convertValueImpl(.empty, structType, &tooBigValue, module.types))
        #expect(string(module.dump(tooBigValue)) == "struct { x: 1e+39, y: 2 }")
    }

    // convertValueImpl writes only to the elements it changes or fails on; the values and results are those of the
    // conversion that writes to every element, partial conversions included, also when it remembers every array and
    // struct it reads (`memoizedReads: 0`), so that each value that recurs is taken from what it remembered.
    @Test
    func convertWritesOnlyWhatChanges() {
        var module = ShaderModule(source: SourceText(""))
        var structures = Arena<StructureID, UInt32>()
        let structure = structures.append(0)
        let names = [module.symbols.intern("a"), module.symbols.intern("b"), module.symbols.intern("c")]
        let extraField = module.symbols.intern("extra")
        var structFields: [TypeID: [Symbol]] = [:]
        var random = TestRandom(state: 0x5F22)
        var counts = (converted: 0, failed: 0, unchanged: 0)
        var iteration = 0
        while iteration < 20_000 {
            let type = randomType(&random, &module.types, names, structure, &structFields, depth: 4)
            var pool: [TypeID: [ConstantValue]] = [:]
            let value = randomValue(type, &random, module.types, structFields, extraField, &pool)
            var lazy = value
            var memoized = value
            var eager = value
            var reads = 0
            let lazyResult = convertValueImpl(.empty, type, &lazy, module.types)
            let memoizedResult = convertValueImpl(.empty, type, &memoized, module.types, memoizedReads: 0, reads: &reads)
            let eagerResult = eagerConvert(type, &eager, module.types)
            #expect(lazyResult == eagerResult && memoizedResult == eagerResult)
            #expect(lazy == eager, "\(string(module.dump(value))) to '\(string(module.typeString(type)))'")
            #expect(memoized == eager, "\(string(module.dump(value))) to '\(string(module.typeString(type)))', memoized")
            if !lazyResult {
                counts.failed += 1
            } else if lazy == value {
                counts.unchanged += 1
            } else {
                counts.converted += 1
            }
            iteration += 1
        }
        #expect(counts.converted > 1000 && counts.failed > 1000 && counts.unchanged > 1000)
    }

    // A value whose elements share their storage, nested 25 levels deep, holds 2^25 scalars but takes 25 elements
    // of storage; converting it to its own type reads it level by level and writes nothing, and a conversion that changes
    // it converts the shared elements once per level, not once per element.
    @Test
    func convertKeepsSharedElementsShared() {
        var types = TypeStore()
        var type = types.u32Type
        var value = ConstantValue.uint32(0)
        var abstractValue = ConstantValue.int64(1)
        var level = 0
        while level < 25 {
            type = types.arrayType(type, .creationFixed(2))
            value = .array(ConstantArray([value, value]))
            abstractValue = .array(ConstantArray([abstractValue, abstractValue]))
            level += 1
        }
        let unchanged = value
        #expect(convertValueImpl(.empty, type, &value, types))
        if case .array(let array) = value, case .array(let unchangedArray) = unchanged {
            #expect(array.elements.isTriviallyIdentical(to: unchangedArray.elements))
        } else {
            Issue.record("not an array")
        }

        #expect(convertValueImpl(.empty, type, &abstractValue, types))
        var element = abstractValue
        level = 0
        while level < 25, case .array(let array) = element {
            #expect(array.elements[0] == array.elements[1])
            element = array.elements[1]
            level += 1
        }
        #expect(level == 25 && element == .uint32(1))
    }

    // The same through struct fields, 32 levels deep (2^32 scalars): each level's fields share their storage, as in the zero
    // value of `struct S { a: T, b: T }`, and the conversion reads one field per level.
    @Test
    func convertReadsSharedStructFieldsOnce() {
        var module = ShaderModule(source: SourceText(""))
        var structures = Arena<StructureID, UInt32>()
        let structure = structures.append(0)
        let a = module.symbols.intern("a")
        let b = module.symbols.intern("b")
        var type = module.types.u32Type
        var value = ConstantValue.uint32(0)
        var level = 0
        while level < 32 {
            var fields = SymbolMap<TypeID>()
            fields.add(a, type)
            fields.add(b, type)
            type = module.types.structType(structure, fields)
            var constantStruct = ConstantStruct()
            constantStruct.set(a, value)
            constantStruct.set(b, value)
            value = .struct(constantStruct)
            level += 1
        }
        let unchanged = value
        #expect(convertValueImpl(.empty, type, &value, module.types))
        if case .struct(let constantStruct) = value, case .struct(let unchangedStruct) = unchanged {
            #expect(constantStruct.fields.isTriviallyIdentical(to: unchangedStruct.fields))
        } else {
            Issue.record("not a struct")
        }
        #expect(value == unchanged)
    }

    // Equal values that do not share their storage are not compared element by element: `array(a, c)` and a struct
    // `{ a: T, b: T }` holding two doubling chains of 40 levels built apart (2^40 scalars each, as in `const z =
    // array(a40, c40)`) read each chain once per level, whether they convert to their own type or from AbstractInt.
    @Test
    func convertComparesStorageNotValues() {
        var module = ShaderModule(source: SourceText(""))
        var structures = Arena<StructureID, UInt32>()
        let structure = structures.append(0)
        let a = module.symbols.intern("a")
        let b = module.symbols.intern("b")
        var type = module.types.u32Type
        var chains = (a: ConstantValue.uint32(1), c: ConstantValue.uint32(1))
        var abstractChains = (a: ConstantValue.int64(1), c: ConstantValue.int64(1))
        var level = 0
        while level < 40 {
            type = module.types.arrayType(type, .creationFixed(2))
            chains = (a: array(chains.a, chains.a), c: array(chains.c, chains.c))
            abstractChains = (a: array(abstractChains.a, abstractChains.a), c: array(abstractChains.c, abstractChains.c))
            level += 1
        }
        let pairType = module.types.arrayType(type, .creationFixed(2))
        var fields = SymbolMap<TypeID>()
        fields.add(a, type)
        fields.add(b, type)
        let structType = module.types.structType(structure, fields)
        func pair(_ first: ConstantValue, _ second: ConstantValue) -> ConstantValue {
            var constantStruct = ConstantStruct()
            constantStruct.set(a, first)
            constantStruct.set(b, second)
            return .struct(constantStruct)
        }
        let cases: [(name: String, type: TypeID, value: ConstantValue)] = [
            ("array(a, c)", pairType, array(chains.a, chains.c)),
            ("array(a, c) from AbstractInt", pairType, array(abstractChains.a, abstractChains.c)),
            ("{ a, c }", structType, pair(chains.a, chains.c)),
            ("{ a, c } from AbstractInt", structType, pair(abstractChains.a, abstractChains.c)),
        ]
        for testCase in cases {
            var value = testCase.value
            var reads = 0
            #expect(convertValueImpl(.empty, testCase.type, &value, module.types, memoizedReads: 1024, reads: &reads), "\(testCase.name)")
            #expect(reads < 1000, "\(testCase.name): \(reads) elements read")
            let halves: [ConstantValue]
            switch value {
            case .array(let array): halves = array.elements
            case .struct(let constantStruct): halves = [constantStruct.get(a), constantStruct.get(b)]
            case .float, .half, .double, .int32, .uint32, .int64, .bool, .vector, .matrix: halves = []
            }
            #expect(halves.count == 2 && halves.allSatisfy { sharedLevels($0, width: 2) == 40 }, "\(testCase.name)")
        }
    }

    // A value that recurs away from the element before it, as `b` in `b_i = array(b_{i-1}, y_{i-1}, b_{i-1})` (3^40
    // scalars in 40 levels) or `z_{i-2}` in `z_i = array(z_{i-1}, array(z_{i-2}, z_{i-2}))`, is read again only until its
    // scan or conversion has read `memoizedReads` elements (16 where it meets shared storage); then a conversion to its own
    // type reads it once, and one that changes it converts it once and shares the result.
    @Test
    func convertReadsRecurringValuesOnce() {
        var types = TypeStore()
        var recurringType = types.arrayType(types.u32Type, .creationFixed(2))
        var fibonacciType = recurringType
        var recurring = (b: array(.uint32(1), .uint32(2)), y: array(.uint32(3), .uint32(4)))
        var abstractRecurring = (b: array(.int64(1), .int64(2)), y: array(.int64(3), .int64(4)))
        var fibonacci = (z: array(.uint32(1), .uint32(2)), previous: array(.uint32(1), .uint32(2)))
        var abstractFibonacci = (z: array(.int64(1), .int64(2)), previous: array(.int64(1), .int64(2)))
        var level = 0
        while level < 40 {
            recurringType = types.arrayType(recurringType, .creationFixed(3))
            fibonacciType = types.arrayType(fibonacciType, .creationFixed(2))
            recurring = (b: array(recurring.b, recurring.y, recurring.b), y: array(recurring.y, recurring.y, recurring.y))
            abstractRecurring = (
                b: array(abstractRecurring.b, abstractRecurring.y, abstractRecurring.b),
                y: array(abstractRecurring.y, abstractRecurring.y, abstractRecurring.y)
            )
            fibonacci =
                level == 0
                ? (z: array(fibonacci.z, fibonacci.z), previous: fibonacci.z)
                : (z: array(fibonacci.z, array(fibonacci.previous, fibonacci.previous)), previous: fibonacci.z)
            abstractFibonacci =
                level == 0
                ? (z: array(abstractFibonacci.z, abstractFibonacci.z), previous: abstractFibonacci.z)
                : (
                    z: array(abstractFibonacci.z, array(abstractFibonacci.previous, abstractFibonacci.previous)),
                    previous: abstractFibonacci.z
                )
            level += 1
        }
        let cases: [(name: String, type: TypeID, value: ConstantValue, changes: Bool)] = [
            ("b", recurringType, recurring.b, false),
            ("b from AbstractInt", recurringType, abstractRecurring.b, true),
            ("z", fibonacciType, fibonacci.z, false),
            ("z from AbstractInt", fibonacciType, abstractFibonacci.z, true),
        ]
        for testCase in cases {
            var value = testCase.value
            var reads = 0
            #expect(convertValueImpl(.empty, testCase.type, &value, types, memoizedReads: 1024, reads: &reads), "\(testCase.name)")
            #expect(reads < 20_000, "\(testCase.name): \(reads) elements read")
            if !testCase.changes, case .array(let converted) = value, case .array(let original) = testCase.value {
                #expect(converted.elements.isTriviallyIdentical(to: original.elements), "\(testCase.name)")
            }
        }

        // Remembering every array, the converted `b` holds one buffer per level: its first and last elements share their
        // storage, at every level.
        var value = abstractRecurring.b
        var reads = 0
        #expect(convertValueImpl(.empty, recurringType, &value, types, memoizedReads: 0, reads: &reads))
        level = 0
        while case .array(let array) = value, array.elements.count == 3, case .array(let first) = array.elements[0],
            case .array(let last) = array.elements[2], first.elements.isTriviallyIdentical(to: last.elements)
        {
            value = array.elements[0]
            level += 1
        }
        #expect(level == 40 && value == array(.uint32(1), .uint32(2)), "\(level) levels share their storage")

        // One buffer converted to two types in one conversion: an AbstractInt array in fields of types array<i32, 2> and
        // array<f32, 2>, and a u32 array that is converted already in a field of type array<u32, 2> and fails in one of
        // type array<f32, 2>. Each type has its own result.
        var module = ShaderModule(source: SourceText(""))
        var structures = Arena<StructureID, UInt32>()
        let structure = structures.append(0)
        let a = module.symbols.intern("a")
        let b = module.symbols.intern("b")
        func structType(_ first: TypeID, _ second: TypeID) -> TypeID {
            var fields = SymbolMap<TypeID>()
            fields.add(a, module.types.arrayType(first, .creationFixed(2)))
            fields.add(b, module.types.arrayType(second, .creationFixed(2)))
            return module.types.structType(structure, fields)
        }
        func pair(_ value: ConstantValue) -> ConstantValue {
            var constantStruct = ConstantStruct()
            constantStruct.set(a, value)
            constantStruct.set(b, value)
            return .struct(constantStruct)
        }
        var abstractPair = pair(array(.int64(1), .int64(2)))
        let integerAndFloat = structType(module.types.i32Type, module.types.f32Type)
        #expect(convertValueImpl(.empty, integerAndFloat, &abstractPair, module.types, memoizedReads: 0, reads: &reads))
        #expect(string(module.dump(abstractPair)) == "struct { a: array(1i, 2i), b: array(1f, 2f) }")
        var unsignedPair = pair(array(.uint32(1), .uint32(2)))
        let unsignedAndFloat = structType(module.types.u32Type, module.types.f32Type)
        #expect(!convertValueImpl(.empty, unsignedAndFloat, &unsignedPair, module.types, memoizedReads: 0, reads: &reads))
    }

    // A lookup in the memo costs the same however many values it holds: 65,536 values of type array<array<u32, 16>, 2>
    // built apart (each with its own storage, and remembered), converted to their own type and from AbstractInt, cost per
    // value in one conversion at most 8 times their CPU time in conversions of 256. Round 4 searched every remembered value
    // of the type, 2^31 steps here against 2^23 for the conversions of 256.
    @Test
    func convertLooksUpRememberedValuesInConstantTime() {
        var types = TypeStore()
        let count = 65_536
        let part = 256
        let factor = 8
        let elementType = types.arrayType(types.arrayType(types.u32Type, .creationFixed(16)), .creationFixed(2))
        let type = types.arrayType(elementType, .creationFixed(UInt32(count)))
        let partType = types.arrayType(elementType, .creationFixed(UInt32(part)))
        func values(_ scalar: ConstantValue, _ count: Int) -> ConstantValue {
            var elements: [ConstantValue] = []
            elements.reserveCapacity(count)
            while elements.count < count {
                let row = ConstantValue.array(ConstantArray(Array(repeating: scalar, count: 16)))
                elements.append(array(row, row))
            }
            return .array(ConstantArray(elements))
        }
        for (name, scalar) in [("u32", ConstantValue.uint32(0)), ("from AbstractInt", .int64(0))] {
            let value = values(scalar, count)
            var converted = value
            var reads = 0
            #expect(convertValueImpl(.empty, type, &converted, types, memoizedReads: 1024, reads: &reads), "\(name)")
            #expect(reads < 24 * count, "\(name): \(reads) elements read")
            #expect(converted == values(.uint32(0), count), "\(name)")

            var parts: [ConstantValue] = []
            while parts.count < count / part {
                parts.append(values(scalar, part))
            }
            var isConverted = true
            let costs = leastCostsPerUnit(units: (small: count, large: count), factor: factor) {
                threadCPUTime {
                    var index = 0
                    while index < parts.count {
                        var convertedPart = parts[index]
                        isConverted = convertValueImpl(.empty, partType, &convertedPart, types) && isConverted
                        index += 1
                    }
                }
            } large: {
                threadCPUTime {
                    var convertedValue = value
                    isConverted = convertValueImpl(.empty, type, &convertedValue, types) && isConverted
                }
            }
            #expect(isConverted, "\(name)")
            #expect(costs.large <= costs.small * factor, "\(name): \(costs.large) per value in one conversion, \(costs.small) by \(part)")
        }
    }

    // After type checking, every read of a constant and every constant built from it hold its storage: the declaration,
    // read and constructor conversions to the value's own type write nothing (a write copies each buffer it reaches).
    @Test
    func typeCheckedReadsShareTheConstantsStorage() {
        let failures = onTestCompileThread { () -> [String] in
            let source =
                "const c = array<array<u32, 4>, 3>();\nconst d = array(c, c);\n"
                + "@compute @workgroup_size(1) fn main() { _ = c; _ = c; let a = c; _ = a; var v = c; _ = d; _ = d[1]; }\n"
            var module = ShaderModule(source: SourceText(source), configuration: testsConfiguration)
            func failed(_ result: FailedCheck?) -> Bool {
                guard let result else {
                    return false
                }
                return !result.errors.isEmpty
            }
            if failed(parse(&module)) || failed(reorderGlobals(&module)) || failed(typeCheck(&module)) {
                return ["the module does not type-check"]
            }
            var reads = IdentifierConstants(shaderModule: module)
            reads.visitShaderModule()
            return sharingFailures(reads.values)
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    // Constants built as DAGs of shared values: equal values built apart, values that recur away from the element before
    // them, zero values, struct fields and AbstractInt values that their reads convert. Type-checking reads each shared
    // value once, so each of the `depth` levels reads the `depth` or fewer values below it: per depth^2, each source
    // costs at most 4 times as much CPU time 20 levels deep as 10 levels deep (14 and 7 for the values that recur, which
    // have 3^depth scalars), where reading every scalar costs hundreds of times more, and each type-checks 40 levels deep
    // (2^40 scalars or more; C++ runs out of memory on each).
    @Test
    func typeCheckedConstantDAGsAreReadOnce() {
        func sources(depth: Int) -> [String] {
            func doubling(_ name: String, _ base: String) -> String {
                var source = "const \(name)0 = \(base);\n"
                for level in 1...depth {
                    source += "const \(name)\(level) = array(\(name)\(level - 1), \(name)\(level - 1));\n"
                }
                return source
            }
            func recurring(_ base: String, _ other: String) -> String {
                var source = "const b0 = \(base);\nconst y0 = \(other);\n"
                for level in 1...depth {
                    source += "const b\(level) = array(b\(level - 1), y\(level - 1), b\(level - 1));\n"
                    source += "const y\(level) = array(y\(level - 1), y\(level - 1), y\(level - 1));\n"
                }
                return source
            }
            var aliases = "alias T0 = array<u32, 2>;\n"
            for level in 1...depth {
                aliases += "alias T\(level) = array<T\(level - 1), 2>;\n"
            }
            let main = "@compute @workgroup_size(1) fn main() { "
            let pair = "array(a\(depth), c\(depth))"
            return [
                doubling("a", "array(1u, 2u)") + doubling("c", "array(1u, 2u)") + "const z = \(pair);\n" + main + "_ = z; }\n",
                doubling("a", "array<array<u32, 2>, 2>()") + doubling("c", "array<array<u32, 2>, 2>()") + "const z = \(pair);\n" + main
                    + "_ = z; }\n",
                doubling("a", "array(1, 2)") + doubling("c", "array(1, 2)") + main + "let z = \(pair); _ = z; }\n",
                aliases + "struct P { a: T\(depth), b: T\(depth) }\n" + doubling("a", "array(1u, 2u)") + doubling("c", "array(1u, 2u)")
                    + "const p = P(a\(depth), c\(depth));\n" + main + "_ = p; }\n",
                recurring("array(1u, 2u)", "array(3u, 4u)") + main + "_ = b\(depth); _ = b\(depth)[2]; }\n",
                recurring("array<array<u32, 2>, 2>()", "array<array<u32, 2>, 2>()") + main + "_ = b\(depth); }\n",
                recurring("array(1, 2)", "array(3, 4)") + main + "let x = b\(depth); _ = x; var v = b\(depth); _ = v; }\n",
            ]
        }
        let factor = 4
        for (index, source) in sources(depth: 40).enumerated() {
            let depths = index < 4 ? (small: 10, large: 20) : (small: 7, large: 14)
            let (small, large) = (sources(depth: depths.small)[index], sources(depth: depths.large)[index])
            var ok = true
            let costs = leastCostsPerUnit(units: (small: depths.small * depths.small, large: depths.large * depths.large), factor: factor) {
                let result = typeChecks(small)
                ok = result.ok && ok
                return result.cpuTime
            } large: {
                let result = typeChecks(large)
                ok = result.ok && ok
                return result.cpuTime
            }
            #expect(ok, "source \(index) does not type-check")
            guard costs.large <= costs.small * factor else {
                // 40 levels deep, reading every scalar would not finish.
                Issue.record(
                    "source \(index): \(costs.large) per depth^2 \(depths.large) levels deep, \(costs.small) \(depths.small) levels deep"
                )
                continue
            }
            #expect(typeChecks(source).ok, "source \(index) does not type-check 40 levels deep")
        }
    }

    // A constant of 2,047 zero values of one type, each with its own storage (so a conversion remembers each), read 150
    // times, and ten such constants in one. Debug C++ takes 1.5 s and 0.9 s; round 4, which searched every remembered
    // value of the type, took 36 s and 53 s at -Onone. Per value, each costs at most 3 times the CPU time of 64 copies of
    // it with 32 values instead of 2,047, where round 4's search takes 64 times fewer steps.
    @Test
    func typeCheckedManyRememberedValuesOfOneType() {
        let header = "alias T = array<array<u32, 16>, 2>;\n"
        let main = "@compute @workgroup_size(1) fn main() { "
        let factor = 3
        func zeroValues(_ count: Int) -> String {
            "array(" + Array(repeating: "T()", count: count).joined(separator: ", ") + ")"
        }
        func readOften(copies: Int, count: Int) -> String {
            var source = header
            for copy in 0..<copies {
                source += "const b\(copy) = \(zeroValues(count));\n"
            }
            source += main
            for copy in 0..<copies {
                source += String(repeating: "_ = b\(copy); ", count: 150)
            }
            return source + "}\n"
        }
        func tenInOne(copies: Int, count: Int) -> String {
            var source = header
            for copy in 0..<copies {
                for index in 0..<10 {
                    source += "const b\(copy)_\(index) = \(zeroValues(count));\n"
                }
                source += "const big\(copy) = array(" + (0..<10).map { "b\(copy)_\($0)" }.joined(separator: ", ") + ");\n"
            }
            source += main
            for copy in 0..<copies {
                source += "_ = big\(copy); "
            }
            return source + "}\n"
        }
        for (index, shape) in [readOften, tenInOne].enumerated() {
            let (large, small) = (shape(1, 2047), shape(64, 32))
            var ok = true
            let costs = leastCostsPerUnit(units: (small: 64 * 32, large: 2047), factor: factor) {
                let result = typeChecks(small)
                ok = result.ok && ok
                return result.cpuTime
            } large: {
                let result = typeChecks(large)
                ok = result.ok && ok
                return result.cpuTime
            }
            #expect(ok, "source \(index) does not type-check")
            #expect(
                costs.large <= costs.small * factor,
                "source \(index): \(costs.large) per value with 2,047 values, \(costs.small) with 32"
            )
        }
    }

    @Test
    func convertIntegerRangeChecks() {
        #expect(convertInteger(Int32.self, 2_147_483_647) == .max)
        #expect(convertInteger(Int32.self, 2_147_483_648) == nil)
        #expect(convertInteger(Int32.self, -2_147_483_648) == .min)
        #expect(convertInteger(Int32.self, -2_147_483_649) == nil)
        #expect(convertInteger(UInt32.self, 0) == 0)
        #expect(convertInteger(UInt32.self, -1) == nil)
        #expect(convertInteger(UInt32.self, 4_294_967_295) == .max)
        #expect(convertInteger(UInt32.self, 4_294_967_296) == nil)
        #expect(convertInteger(UInt32.self, .min) == nil)
    }

    // The range check is in the source type: a value above the target's maximum is rejected even when it would round to it.
    @Test
    func convertFloatRangeChecksInSourceType() {
        let aboveFloatMax = 3.4028235e38
        #expect(aboveFloatMax > Double(Float.greatestFiniteMagnitude))
        #expect(Float(aboveFloatMax) == .greatestFiniteMagnitude)
        #expect(convertFloat(Float.self, aboveFloatMax) == nil)
        #expect(convertFloat(Float.self, -aboveFloatMax) == nil)
        #expect(convertFloat(Float.self, Double(Float.greatestFiniteMagnitude)) == .greatestFiniteMagnitude)
        #expect(convertFloat(Float.self, -Double(Float.greatestFiniteMagnitude)) == -.greatestFiniteMagnitude)
        #expect(convertFloat(Float.self, Double.infinity) == nil)
        #expect(convertFloat(Float.self, Double.nan) == nil)
        #expect(convertFloat(Float.self, 0.1 as Double) == Float(0.1 as Double))

        #expect(convertFloat(Float.self, Float.greatestFiniteMagnitude) == .greatestFiniteMagnitude)
        #expect(convertFloat(Float.self, -Float.infinity) == nil)
        #expect(convertFloat(Float.self, Float.nan) == nil)

        let aboveHalfMax = 65504.001
        #expect(Half(aboveHalfMax).bitPattern == 0x7BFF)
        #expect(convertFloat(Half.self, aboveHalfMax) == nil)
        #expect(convertFloat(Half.self, 65504.0 as Double)?.bitPattern == 0x7BFF)
        #expect(convertFloat(Half.self, -65504.0 as Double)?.bitPattern == 0xFBFF)
        #expect(convertFloat(Half.self, 65519.0 as Double) == nil)
        #expect(convertFloat(Half.self, Double.nan) == nil)
        #expect(convertFloat(Half.self, 1.0 / 3.0)?.bitPattern == Half(1.0 / 3.0).bitPattern)

        #expect(convertFloat(Half.self, Float(65504))?.bitPattern == 0x7BFF)
        #expect(Half(Float(65504).nextUp).bitPattern == 0x7BFF)
        #expect(convertFloat(Half.self, Float(65504).nextUp) == nil)
        #expect(convertFloat(Half.self, -Float.infinity) == nil)

        #expect(convertFloat(Half.self, Half(bitPattern: 0x7BFF))?.bitPattern == 0x7BFF)
        #expect(convertFloat(Half.self, Half(bitPattern: 0xFBFF))?.bitPattern == 0xFBFF)
        #expect(convertFloat(Half.self, Half(bitPattern: 0x7C00)) == nil)
        #expect(convertFloat(Half.self, Half(bitPattern: 0xFC00)) == nil)
        #expect(convertFloat(Half.self, Half(bitPattern: 0x7E00)) == nil)

        #expect(convertFloat(Double.self, Double.greatestFiniteMagnitude) == .greatestFiniteMagnitude)
        #expect(convertFloat(Double.self, -Double.greatestFiniteMagnitude) == -.greatestFiniteMagnitude)
        #expect(convertFloat(Double.self, Double.infinity) == nil)
        #expect(convertFloat(Double.self, -Double.infinity) == nil)
        #expect(convertFloat(Double.self, Double.nan) == nil)
    }

    @Test
    func constantStructGetAndSet() {
        var symbols = SymbolTable.predeclared
        let a = symbols.intern("a")
        let b = symbols.intern("b")
        var constantStruct = ConstantStruct()
        constantStruct.set(a, .int32(1))
        constantStruct.set(b, .int32(2))
        constantStruct.set(a, .int32(3))
        #expect(keyNames(constantStruct, symbols) == ["a", "b"])
        #expect(constantStruct.get(a) == .int32(3))
        #expect(constantStruct.get(b) == .int32(2))
        #expect(constantStruct.get(symbols.intern("c")) == .float(0))
        #expect(constantStruct.fields.count == 2)

        var reordered = ConstantStruct()
        reordered.set(b, .int32(2))
        reordered.set(a, .int32(3))
        #expect(constantStruct != reordered)
    }

    // ConstantFunctions.h:1307 and :1447 build these from initializer lists; WTFHashTests.primitiveStructFieldOrders shows the
    // resulting HashMap order, recomputed here through the emulation.
    @Test
    func primitiveStructFieldOrder() {
        var symbols = SymbolTable.predeclared
        let results: [(constantStruct: ConstantStruct, initializerList: [String])] = [
            (.frexpResult(fract: .float(0.5), exp: .int32(1)), ["fract", "exp"]),
            (.modfResult(fract: .float(0.5), whole: .float(1)), ["fract", "whole"]),
        ]
        for result in results {
            var table = WTFHashTable<WTFStringHash, Int>()
            table.reserveInitialCapacity(result.initializerList.count)
            for (index, name) in result.initializerList.enumerated() {
                table.add(Array(name.utf16), index)
            }
            #expect(keyNames(result.constantStruct, symbols) == table.map { String(decoding: $0.key, as: UTF16.self) })
        }
        let frexp = ConstantStruct.frexpResult(fract: .float(0.5), exp: .int32(1))
        #expect(frexp.get(symbols.intern("fract")) == .float(0.5))
        #expect(frexp.get(symbols.intern("exp")) == .int32(1))
        let modf = ConstantStruct.modfResult(fract: .float(0.5), whole: .float(1))
        #expect(modf.get(symbols.intern("whole")) == .float(1))
    }

    @Test
    func accessors() {
        #expect(ConstantValue.int32(-1).integerValue() == -1)
        #expect(ConstantValue.uint32(.max).integerValue() == 4_294_967_295)
        #expect(ConstantValue.int64(.min).integerValue() == .min)
        #expect(ConstantValue.float(1.5).getHalf().bitPattern == 0x3E00)
        #expect(ConstantValue.double(65504).getHalf().bitPattern == 0x7BFF)
        #expect(ConstantValue.double(1.0 / 3.0).getHalf().bitPattern == Half(1.0 / 3.0).bitPattern)
        #expect(ConstantValue.bool(true).toBool())
        #expect(!ConstantValue.bool(false).toBool())
        #expect(vector(.int32(1), .int32(2)).toVector() == ConstantVector([.int32(1), .int32(2)]))

        #expect(ConstantValue.bool(true).isBool)
        #expect(!ConstantValue.int32(1).isBool)
        #expect(vector(.int32(1)).isVector)
        #expect(array(.int32(1)).isArray)
        #expect(!array(.int32(1)).isVector)
        let matrix = ConstantMatrix(columns: 3, rows: 2, [.int32(1), .int32(2), .int32(3), .int32(4), .int32(5), .int32(6)])
        #expect(ConstantValue.matrix(matrix).isMatrix)

        #expect(array(.int32(1), .int32(2), .int32(3)).upperBound() == 3)
        #expect(vector(.int32(1), .int32(2)).upperBound() == 2)
        #expect(ConstantValue.matrix(matrix).upperBound() == 3)
        #expect(matrix[1] == ConstantVector([.int32(3), .int32(4)]))
        #expect(ConstantValue.matrix(matrix)[2] == vector(.int32(5), .int32(6)))
        #expect(array(.int32(7), .int32(8))[1] == .int32(8))
        #expect(vector(.uint32(7), .uint32(8))[0] == .uint32(7))
        #expect(ConstantArray([.bool(true)])[0] == .bool(true))
    }

    @Test
    func equalityIsStructuralAndBitExact() {
        #expect(ConstantValue.float(-0.0) != .float(0.0))
        #expect(ConstantValue.double(-0.0) != .double(0.0))
        #expect(ConstantValue.float(.nan) == .float(.nan))
        #expect(ConstantValue.double(.nan) == .double(.nan))
        #expect(ConstantValue.half(Half(bitPattern: 0x3C00)) == .half(Half(Float(1))))
        #expect(ConstantValue.half(Half(bitPattern: 0x8000)) != .half(Half(bitPattern: 0)))
        #expect(ConstantValue.int32(1) != .uint32(1))
        #expect(ConstantValue.int64(1) != .double(1))
        #expect(vector(.int32(1)) != array(.int32(1)))
        let elements = [ConstantValue](repeating: .float(1), count: 6)
        #expect(ConstantMatrix(columns: 2, rows: 3, elements) != ConstantMatrix(columns: 3, rows: 2, elements))
        #expect(ConstantMatrix(columns: 2, rows: 3, elements) == ConstantMatrix(columns: 2, rows: 3, elements))
    }

    // A valid shader can nest constants 500 arrays deep through aliases; in C++, conversion, dump and release recurse once
    // per level. At -O this runs on the 512 KiB test thread.
    @Test
    func deepNesting() {
        let depth = 500
        let result = onCompileThread { _ in
            var types = TypeStore()
            var type = types.f32Type
            var value = ConstantValue.int64(1)
            var level = 0
            while level < depth {
                type = types.arrayType(type, .creationFixed(1))
                value = .array(ConstantArray([value]))
                level += 1
            }
            let converted = convertValueImpl(.empty, type, &value, types)
            var text = MessageText(codeUnits: [])
            value.dump(into: &text, SymbolTable.predeclared)
            return (
                converted: converted, dumpLength: text.codeUnits.count, prefix: String(decoding: text.codeUnits.prefix(14), as: UTF16.self)
            )
        }
        #expect(result.converted)
        // "array(" and ")" per level around "1f".
        #expect(result.dumpLength == depth * 7 + 2)
        #expect(result.prefix == "array(array(ar")
    }

    // DEV-02: a user struct's fields dump in the order they were set (member order), not in C++ HashMap order.
    @Test
    func DEV_02_userStructDumpsInMemberOrder() {
        var symbols = SymbolTable.predeclared
        var constantStruct = ConstantStruct()
        constantStruct.set(symbols.intern("zeta"), .int32(1))
        constantStruct.set(symbols.intern("alpha"), vector(.float(1), .float(2)))
        constantStruct.set(symbols.intern("mid"), .bool(true))
        #expect(dumped(.struct(constantStruct), symbols) == "struct { zeta: 1i, alpha: vec2(1f, 2f), mid: true }")
    }
}
