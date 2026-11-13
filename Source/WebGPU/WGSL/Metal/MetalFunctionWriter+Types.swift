// Copyright (C) 2023-2026 Apple Inc. All rights reserved.
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

// MARK: - Types

extension FunctionDefinitionWriter {
    /// C++ `visit(const Type*)`: the type with the packing its context implies (`shouldPackType()`), never packed by request.
    mutating func printValueType(_ type: TypeID) {
        printStorageType(type, .unpacked)
    }

    /// C++ `visit(const Type*, shouldPack)`, `shouldPack` being whether `packing` contains `.packed`.
    mutating func printStorageType(_ type: TypeID, _ packing: Packing) {
        // DEV-03: an explicit stack of what is left to print, where the C++ recurses into the element types. A nested call (from
        // an override-sized array's size expression) uses the part above `base`.
        let base = typePrintStack.count
        printTypeStep(.type(type, shouldPack: packing.contains(.packed)))
        while typePrintStack.count > base {
            printTypeStep(typePrintStack.removeLast())
        }
    }

    /// The body of C++ `visit(const Type*, shouldPack)`, which pushes what the C++ prints after a recursive call.
    private mutating func printTypeStep(_ step: TypePrintStep) {
        switch step {
        case .text(let text):
            switch text {
            case .closeAngle:
                body.append(">")
            case .comma:
                body.append(", ")
            case .accessSeparator:
                body.append(", access::")
            case .ampersand:
                body.append("&")
            case .star:
                body.append("*")
            case .sample:
                body.append("sample")
            case .read:
                body.append("read")
            case .write:
                body.append("write")
            case .readWrite:
                body.append("read_write")
            }
        case .decimal(let value):
            body.appendDecimal(UInt32(value))
        case .arraySize(let size):
            switch size {
            case .creationFixed(let size):
                body.appendDecimal(size)
            case .runtime:
                body.appendDecimal(Int32(1))
            case .overrideSized(let size):
                visit(size)
            }
        case .type(let type, let packedByRequest):
            let shouldPack = shouldPackType() || packedByRequest
            switch shaderModule.types[type] {
            case .primitive(let primitive):
                printPrimitive(primitive)
            case .vector(let vector):
                if emitPackedVector(vector, shouldPack) {
                    return
                }
                body.append("vec<")
                if case .primitive(let element) = shaderModule.types[vector.element] {
                    // What the steps below print for a primitive element, without the stack.
                    printPrimitive(element)
                    body.append(", ")
                    body.appendDecimal(UInt32(vector.size))
                    body.append(">")
                    return
                }
                typePrintStack.append(.text(.closeAngle))
                typePrintStack.append(.decimal(vector.size))
                typePrintStack.append(.text(.comma))
                typePrintStack.append(.type(vector.element, shouldPack: shouldPack))
            case .matrix(let matrix):
                if shouldPack && matrix.rows == 3 {
                    body.append("PackedMatrix<")
                    typePrintStack.append(.text(.closeAngle))
                    typePrintStack.append(.decimal(matrix.columns))
                    typePrintStack.append(.text(.comma))
                    typePrintStack.append(.type(matrix.element, shouldPack: shouldPack))
                } else {
                    body.append("matrix<")
                    if case .primitive(let element) = shaderModule.types[matrix.element] {
                        // What the steps below print for a primitive element, without the stack.
                        printPrimitive(element)
                        body.append(", ")
                        body.appendDecimal(UInt32(matrix.columns))
                        body.append(", ")
                        body.appendDecimal(UInt32(matrix.rows))
                        body.append(">")
                        return
                    }
                    typePrintStack.append(.text(.closeAngle))
                    typePrintStack.append(.decimal(matrix.rows))
                    typePrintStack.append(.text(.comma))
                    typePrintStack.append(.decimal(matrix.columns))
                    typePrintStack.append(.text(.comma))
                    typePrintStack.append(.type(matrix.element, shouldPack: shouldPack))
                }
            case .array(let array):
                body.append("array<")
                typePrintStack.append(.text(.closeAngle))
                typePrintStack.append(.arraySize(array.size))
                typePrintStack.append(.text(.comma))
                if let vector = shaderModule.types.getIf(Types.Vector.self, array.element), vector.size == 3 && shouldPack {
                    body.append("PackedVec3<")
                    typePrintStack.append(.text(.closeAngle))
                    typePrintStack.append(.type(vector.element, shouldPack: shouldPack))
                } else {
                    typePrintStack.append(.type(array.element, shouldPack: shouldPack))
                }
            case .struct(let structure):
                let name = shaderModule.symbol(of: shaderModule[structure.structure].name)
                if shouldPack && shaderModule[structure.structure].role == .userDefinedResource {
                    body.append("__PackedType<")
                    body.append(identifier: name, in: shaderModule.symbols)
                    body.append(">")
                } else {
                    body.append(identifier: name, in: shaderModule.symbols)
                }
            case .primitiveStruct(let structure):
                let name = shaderModule.symbols.intern(structure.name)
                body.append(identifier: name, in: shaderModule.symbols)
                body.append("<")
                typePrintStack.append(.text(.closeAngle))
                var index = shaderModule.types.count(of: structure.values)
                while index > 0 {
                    index &-= 1
                    typePrintStack.append(.type(shaderModule.types[structure.values, index], shouldPack: shouldPack))
                    if index > 0 {
                        typePrintStack.append(.text(.comma))
                    }
                }
            case .texture(let texture):
                let type: MSLText
                var access = TypePrintText.sample
                switch texture.kind {
                case .texture1d:
                    type = "texture1d"
                case .texture2d:
                    type = "texture2d"
                case .texture2dArray:
                    type = "texture2d_array"
                case .texture3d:
                    type = "texture3d"
                case .textureCube:
                    type = "texturecube"
                case .textureCubeArray:
                    type = "texturecube_array"
                case .textureMultisampled2d:
                    type = "texture2d_ms"
                    access = .read
                }
                body.append(type)
                body.append("<")
                typePrintStack.append(.text(.closeAngle))
                typePrintStack.append(.text(access))
                typePrintStack.append(.text(.accessSeparator))
                typePrintStack.append(.type(texture.element, shouldPack: shouldPack))
            case .textureStorage(let texture):
                let base: MSLText
                let mode: TypePrintText
                switch texture.kind {
                case .textureStorage1d:
                    base = "texture1d"
                case .textureStorage2d:
                    base = "texture2d"
                case .textureStorage2dArray:
                    base = "texture2d_array"
                case .textureStorage3d:
                    base = "texture3d"
                }
                switch texture.access {
                case .read:
                    mode = .read
                case .write:
                    mode = .write
                case .readWrite:
                    mode = .readWrite
                }
                body.append(base)
                body.append("<")
                typePrintStack.append(.text(.closeAngle))
                typePrintStack.append(.text(mode))
                typePrintStack.append(.text(.accessSeparator))
                typePrintStack.append(.type(shaderTypeForTexelFormat(texture.format, shaderModule.types), shouldPack: false))
            case .textureDepth(let texture):
                let base: MSLText
                switch texture.kind {
                case .textureDepth2d:
                    base = "depth2d"
                case .textureDepth2dArray:
                    base = "depth2d_array"
                case .textureDepthCube:
                    base = "depthcube"
                case .textureDepthCubeArray:
                    base = "depthcube_array"
                case .textureDepthMultisampled2d:
                    base = "depth2d_ms"
                }
                body.append(base)
                body.append("<float>")
            case .reference(let reference):
                guard let addressSpace = serializeAddressSpace(reference.addressSpace) else {
                    typePrintStack.append(.type(reference.element, shouldPack: false))
                    return
                }
                if reference.accessMode == .read {
                    body.append("const ")
                }
                body.append(addressSpace)
                body.append(" ")
                typePrintStack.append(.text(.ampersand))
                typePrintStack.append(.type(reference.element, shouldPack: false))
            case .pointer(let pointer):
                let addressSpace = serializeAddressSpace(pointer.addressSpace)
                if pointer.accessMode == .read {
                    body.append("const ")
                }
                if let addressSpace {
                    body.append(addressSpace)
                    body.append(" ")
                }
                let shouldPack = pointer.addressSpace == .storage || pointer.addressSpace == .uniform
                typePrintStack.append(.text(.star))
                typePrintStack.append(.type(pointer.element, shouldPack: shouldPack))
            case .atomic(let atomic):
                if atomic.element == shaderModule.types.i32Type {
                    body.append("atomic_int")
                } else {
                    body.append("atomic_uint")
                }
            case .function:
                wgslFatal("a type printer for a function type", cppSite: "MetalFunctionWriter.cpp:1853")
            case .typeConstructor:
                wgslFatal("a type printer for a type constructor", cppSite: "MetalFunctionWriter.cpp:1856")
            }
        }
    }

    /// The primitive case of C++ `visit(const Type*, shouldPack)`.
    private mutating func printPrimitive(_ primitive: Types.Primitive) {
        switch primitive.kind {
        case .abstractInt, .i32:
            body.append("int")
        case .u32:
            body.append("unsigned")
        case .abstractFloat, .f32:
            body.append("float")
        case .f16:
            body.append("half")
        case .void:
            body.append("void")
        case .bool:
            body.append("bool")
        case .sampler:
            body.append("sampler")
        case .samplerComparison:
            body.append("sampler")
        case .textureExternal:
            body.append("texture_external")
        case .accessMode, .texelFormat, .addressSpace:
            wgslFatal("a type printer for a primitive that is not a type", cppSite: "MetalFunctionWriter.cpp:1685")
        }
    }

    mutating func visit(_ parameter: ParameterID) {
        let savedParameterRole = parameterRole
        parameterRole = shaderModule[parameter].role
        defer { parameterRole = savedParameterRole }
        let type = shaderModule.inferredType(of: shaderModule[parameter].typeName)
        if !emitTextureReference(type) {
            guard let type else {
                wgslFatal("a parameter without an inferred type", cppSite: "MetalFunctionWriter.cpp:1866")
            }
            printValueType(type)
        }
        body.append(" ")
        body.append(identifier: shaderModule.symbol(of: shaderModule[parameter].name), in: shaderModule.symbols)
        var attributes = shaderModule.cursor(shaderModule[parameter].attributes)
        while let attribute = shaderModule.next(&attributes) {
            body.append(" ")
            checkErrorAndVisit(attribute)
        }
    }

    mutating func visitArgumentBufferParameter(_ parameter: ParameterID) {
        body.append("constant ")
        guard let type = shaderModule.inferredType(of: shaderModule[parameter].typeName) else {
            wgslFatal("an argument buffer parameter without an inferred type", cppSite: "MetalFunctionWriter.cpp:1877")
        }
        printValueType(type)
        body.append("& ")
        body.append(identifier: shaderModule.symbol(of: shaderModule[parameter].name), in: shaderModule.symbols)
        var attributes = shaderModule.cursor(shaderModule[parameter].attributes)
        while let attribute = shaderModule.next(&attributes) {
            body.append(" ")
            checkErrorAndVisit(attribute)
        }
    }

    mutating func visit(_ expression: ExpressionID) {
        visitExpression(shaderModule.inferredType(of: expression), expression)
    }

    mutating func outlineConstant(_ type: TypeID?, _ expression: ExpressionID) -> Bool {
        guard let constantValue = shaderModule.constantValueForWriter(expression) else {
            return false
        }

        guard case .array = constantValue else {
            return false
        }

        let constantName = shaderModule.symbols.intern(.outlinedConstant(constID))
        constID &+= 1

        guard let type else {
            wgslFatal("an outlined constant without a type", cppSite: "MetalFunctionWriter.cpp:1905")
        }

        swap(&body, &constants)

        body.append(MTLWorkaround.outlinedConstantPrefix)
        printValueType(type)
        body.append(" ")
        body.append(identifier: constantName, in: shaderModule.symbols)
        body.append(" = ")
        serializeConstant(type, constantValue)
        body.append(";\n")

        swap(&body, &constants)

        body.append(identifier: constantName, in: shaderModule.symbols)
        return true
    }

    /// C++ `visit(const Type*, AST::Expression&)`.
    mutating func visitExpression(_ type: TypeID?, _ expression: ExpressionID) {
        if outlineConstant(type, expression) {
            return
        }

        if let constantValue = shaderModule.constantValueForWriter(expression) {
            serializeConstant(type, constantValue)
            return
        }

        if case .callExpression(let call) = shaderModule[expression].kind {
            visitCallExpression(type, call, expression)
        } else if case .identityExpression(let identity) = shaderModule[expression].kind {
            visitExpression(type, identity.expression)
        } else {
            dispatch(expression)
        }
    }

    mutating func serializeConstant(_ type: TypeID?, _ value: ConstantValue) {
        // DEV-03: an explicit stack of what is left to print, where the C++ recurses into the elements and members. A nested call
        // (from a type's override-sized array) uses the part above `base`.
        let base = constantPrintStack.count
        serializeConstantStep(.constant(type, value))
        while constantPrintStack.count > base {
            serializeConstantStep(constantPrintStack.removeLast())
        }
    }

    /// The body of C++ `serializeConstant(type, value)`, which pushes the elements, members and fields it serializes recursively.
    private mutating func serializeConstantStep(_ step: ConstantPrintStep) {
        switch step {
        case .text(let text):
            switch text {
            case .comma:
                body.append(", ")
            case .closeParenthesis:
                body.append(")")
            case .closeBrace:
                body.append("}")
            case .spaceCloseBrace:
                body.append(" }")
            }
        case .elements(let type, let elements, let next):
            guard next < elements.count else {
                return
            }
            if next > 0 {
                body.append(", ")
            }
            constantPrintStack.append(.elements(type, elements, next: next &+ 1))
            constantPrintStack.append(.constant(type, elements[next]))
        case .members(let fields, let constantStruct, var members):
            guard let member = shaderModule.next(&members) else {
                return
            }
            body.append(".")
            body.append(identifier: shaderModule.symbol(of: shaderModule[member].name), in: shaderModule.symbols)
            body.append(" = ")
            let originalName = shaderModule.symbol(of: shaderModule[member].originalName)
            constantPrintStack.append(.members(fields, constantStruct, members))
            constantPrintStack.append(.text(.comma))
            constantPrintStack.append(.constant(fields.get(originalName), constantStruct.get(originalName)))
        case .primitiveStructFields(let primitiveStruct, let constantStruct, let next, let visited):
            let order = primitiveStructFieldHashOrder(primitiveStruct.kind)
            guard next < order.count else {
                guard visited == constantStruct.fields.count else {
                    wgslFatal("a primitive struct constant field that its type does not have", cppSite: "MetalFunctionWriter.cpp:3658")
                }
                return
            }
            let (key, valueIndex) = order[next]
            guard let fieldValue = constantStruct.find(key) else {
                constantPrintStack.append(.primitiveStructFields(primitiveStruct, constantStruct, next: next &+ 1, visited: visited))
                return
            }
            if visited > 0 {
                body.append(", ")
            }
            body.append(".")
            body.append(identifier: key, in: shaderModule.symbols)
            body.append(" = ")
            constantPrintStack.append(.primitiveStructFields(primitiveStruct, constantStruct, next: next &+ 1, visited: visited &+ 1))
            constantPrintStack.append(.constant(shaderModule.types[primitiveStruct.values, valueIndex], fieldValue))
        case .constant(let type, let value):
            guard let type else {
                wgslFatal("serializeConstant of a null type", cppSite: "MetalFunctionWriter.cpp:3545")
            }
            switch shaderModule.types[type] {
            case .primitive(let primitive):
                switch primitive.kind {
                case .abstractInt:
                    guard case .int64(let value) = value else {
                        wgslFatal("std::get<int64_t> of a constant that is not an AbstractInt", cppSite: "MetalFunctionWriter.cpp:3549")
                    }
                    body.append(.abstractInt(value))
                case .i32:
                    guard case .int32(let value) = value else {
                        wgslFatal("std::get<int32_t> of a constant that is not an i32", cppSite: "MetalFunctionWriter.cpp:3552")
                    }
                    body.append(.i32(value))
                case .u32:
                    guard case .uint32(let value) = value else {
                        wgslFatal("std::get<uint32_t> of a constant that is not a u32", cppSite: "MetalFunctionWriter.cpp:3555")
                    }
                    body.append(.u32(value))
                case .abstractFloat:
                    guard case .double(let value) = value else {
                        wgslFatal("std::get<double> of a constant that is not an AbstractFloat", cppSite: "MetalFunctionWriter.cpp:3559")
                    }
                    body.append(.abstractFloat(value))
                case .f32:
                    guard case .float(let value) = value else {
                        wgslFatal("std::get<float> of a constant that is not an f32", cppSite: "MetalFunctionWriter.cpp:3564")
                    }
                    body.append(.f32(value))
                case .f16:
                    guard case .half(let value) = value else {
                        wgslFatal("std::get<half> of a constant that is not an f16", cppSite: "MetalFunctionWriter.cpp:3569")
                    }
                    body.append(.f16(value))
                    body.append("h")
                case .bool:
                    guard case .bool(let value) = value else {
                        wgslFatal("std::get<bool> of a constant that is not a bool", cppSite: "MetalFunctionWriter.cpp:3573")
                    }
                    body.append(value ? "true" : "false")
                case .void, .sampler, .samplerComparison, .textureExternal, .accessMode, .texelFormat, .addressSpace:
                    wgslFatal("serializeConstant of a primitive type without constant values", cppSite: "MetalFunctionWriter.cpp:3582")
                }
            case .reference(let reference):
                constantPrintStack.append(.constant(reference.element, value))
            case .vector(let vectorType):
                guard case .vector(let vector) = value else {
                    wgslFatal("std::get<ConstantVector> of a constant that is not a vector", cppSite: "MetalFunctionWriter.cpp:3589")
                }
                printValueType(type)
                body.append("(")
                constantPrintStack.append(.text(.closeParenthesis))
                constantPrintStack.append(.elements(vectorType.element, vector.elements, next: 0))
            case .array(let arrayType):
                guard case .array(let array) = value else {
                    wgslFatal("std::get<ConstantArray> of a constant that is not an array", cppSite: "MetalFunctionWriter.cpp:3602")
                }
                printValueType(type)
                body.append("{")
                constantPrintStack.append(.text(.closeBrace))
                constantPrintStack.append(.elements(arrayType.element, array.elements, next: 0))
            case .matrix(let matrixType):
                guard case .matrix(let matrix) = value else {
                    wgslFatal("std::get<ConstantMatrix> of a constant that is not a matrix", cppSite: "MetalFunctionWriter.cpp:3615")
                }
                body.append("matrix<")
                printValueType(matrixType.element)
                body.append(", ")
                body.appendDecimal(UInt32(matrixType.columns))
                body.append(", ")
                body.appendDecimal(UInt32(matrixType.rows))
                body.append(">(")
                constantPrintStack.append(.text(.closeParenthesis))
                constantPrintStack.append(.elements(matrixType.element, matrix.elements, next: 0))
            case .struct(let structType):
                guard case .struct(let constantStruct) = value else {
                    wgslFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "MetalFunctionWriter.cpp:3629")
                }
                body.append(identifier: shaderModule.symbol(of: shaderModule[structType.structure].name), in: shaderModule.symbols)
                body.append(" { ")
                constantPrintStack.append(.text(.spaceCloseBrace))
                constantPrintStack.append(
                    .members(
                        shaderModule.types.fields(of: structType.fields),
                        constantStruct,
                        shaderModule.cursor(shaderModule[structType.structure].members)
                    )
                )
            case .primitiveStruct(let primitiveStruct):
                guard case .struct(let constantStruct) = value else {
                    wgslFatal("std::get<ConstantStruct> of a constant that is not a struct", cppSite: "MetalFunctionWriter.cpp:3639")
                }
                let name = shaderModule.symbols.intern(primitiveStruct.name)
                body.append(identifier: name, in: shaderModule.symbols)
                body.append("<")
                var first = true
                var index = 0
                while index < shaderModule.types.count(of: primitiveStruct.values) {
                    if !first {
                        body.append(", ")
                    }
                    first = false
                    printValueType(shaderModule.types[primitiveStruct.values, index])
                    index &+= 1
                }
                body.append("> {")
                constantPrintStack.append(.text(.closeBrace))
                constantPrintStack.append(.primitiveStructFields(primitiveStruct, constantStruct, next: 0, visited: 0))
            case .pointer, .function, .texture, .textureStorage, .textureDepth, .atomic, .typeConstructor:
                wgslFatal("serializeConstant of a type without constant values", cppSite: "MetalFunctionWriter.cpp:3664")
            }
        }
    }
}

/// What the type printer has left to print, last first (`FunctionDefinitionWriter.typePrintStack`).
enum TypePrintStep {
    case type(TypeID, shouldPack: Bool)
    case text(TypePrintText)
    case decimal(UInt8)
    /// The size of an array, between its `, ` and its `>`.
    case arraySize(Types.Array.Size)
}

/// The texts the type printer prints after an element type, each appended as a literal.
enum TypePrintText {
    case closeAngle
    case comma
    case accessSeparator
    case ampersand
    case star
    case sample
    case read
    case write
    case readWrite
}

/// What serializeConstant has left to print, last first (`FunctionDefinitionWriter.constantPrintStack`).
enum ConstantPrintStep {
    case constant(TypeID?, ConstantValue)
    case text(ConstantPrintText)
    /// The elements of a vector, array or matrix constant from `next` on, each of type `type`, separated by `, `.
    case elements(TypeID, [ConstantValue], next: Int)
    /// The members of a struct constant left in the cursor, each followed by `, `.
    case members(SymbolMap<TypeID>, ConstantStruct, ListCursor<StructureMemberID>)
    /// The fields of a primitive struct constant from `next` on in `primitiveStructFieldHashOrder`, `visited` of them printed.
    case primitiveStructFields(Types.PrimitiveStruct, ConstantStruct, next: Int, visited: Int)
}

/// The texts serializeConstant prints after a value, each appended as a literal.
enum ConstantPrintText {
    case comma
    case closeParenthesis
    case closeBrace
    case spaceCloseBrace
}

/// The fields of a primitive struct (name, index in `values`) in the iteration order of the C++ `ConstantStruct::fields` HashMap:
/// the WTF string hashes of the names fall in distinct buckets of its 8-bucket table, so the order is that of the buckets whatever
/// the insertion order (WTFHashTests recomputes it).
private func primitiveStructFieldHashOrder(_ kind: Types.PrimitiveStruct.Kind) -> [(Symbol, Int)] {
    switch kind {
    case .frexpResult:
        [
            (Symbol(BuiltinSymbols.fract), Types.PrimitiveStruct.FrexpResult.fract),
            (Symbol(BuiltinSymbols.exp), Types.PrimitiveStruct.FrexpResult.exp),
        ]
    case .modfResult:
        [
            (Symbol(BuiltinSymbols.fract), Types.PrimitiveStruct.ModfResult.fract),
            (Symbol(BuiltinSymbols.whole), Types.PrimitiveStruct.ModfResult.whole),
        ]
    case .atomicCompareExchangeResult:
        [
            (Symbol(BuiltinSymbols.oldValue), Types.PrimitiveStruct.AtomicCompareExchangeResult.oldValue),
            (Symbol(BuiltinSymbols.exchanged), Types.PrimitiveStruct.AtomicCompareExchangeResult.exchanged),
        ]
    }
}

extension ConstantStruct {
    /// `HashMap::find(key)->value`, or nil where the C++ `find` returns `end()`.
    fileprivate func find(_ key: Symbol) -> ConstantValue? {
        var index = 0
        while index < fields.count {
            if fields[index].key == key {
                return fields[index].value
            }
            index &+= 1
        }
        return nil
    }
}

// MARK: - Swift-only

/// A request of `writeTypesForTesting`.
@_spi(Testing)
public enum MetalTypesTestRequest {
    /// `printValueType`.
    case printValueType(TypeID)
    /// `printStorageType`.
    case printStorageType(TypeID, Packing)
    /// `visit(_ expression:)`, the C++ `visit(AST::Expression&)`.
    case expression(ExpressionID)
    /// `serializeConstant`.
    case serializeConstant(TypeID, ConstantValue)
    /// `visit(_ parameter:)`.
    case parameter(ParameterID)
}

/// What `writeTypesForTesting` wrote.
@_spi(Testing)
public struct MetalTypesTestOutput: Sendable {
    /// C++ `m_body`.
    @_spi(Testing)
    public let body: ContiguousArray<UInt8>
    /// C++ `m_constants`, the outlined constants.
    @_spi(Testing)
    public let constants: ContiguousArray<UInt8>
    /// C++ `m_constID` after the requests.
    @_spi(Testing)
    public let constID: UInt32
}

/// Runs `requests` in order on a writer that is fresh except for the given roles and outlined-constant counter, for the type tests.
@_spi(Testing)
public func writeTypesForTesting(
    _ requests: [MetalTypesTestRequest],
    structRole: StructureRole? = nil,
    variableRole: VariableRole? = nil,
    parameterRole: ParameterRole? = nil,
    constID: UInt32 = 0,
    _ shaderModule: inout ShaderModule
) -> MetalTypesTestOutput {
    var writer = FunctionDefinitionWriter(
        shaderModule: shaderModule,
        stringBuilder: MSLWriter(),
        prepareResult: Reflection.EntryPointInformations(),
        constantValues: OverrideValues(),
        deviceState: DeviceState()
    )
    writer.structRole = structRole
    writer.variableRole = variableRole
    writer.parameterRole = parameterRole
    writer.constID = constID
    var index = 0
    while index < requests.count {
        switch requests[index] {
        case .printValueType(let type):
            writer.printValueType(type)
        case .printStorageType(let type, let packing):
            writer.printStorageType(type, packing)
        case .expression(let expression):
            writer.visit(expression)
        case .serializeConstant(let type, let value):
            writer.serializeConstant(type, value)
        case .parameter(let parameter):
            writer.visit(parameter)
        }
        index &+= 1
    }
    let output = MetalTypesTestOutput(body: writer.body.bytes, constants: writer.constants.bytes, constID: writer.constID)
    shaderModule = writer.shaderModule
    return output
}
