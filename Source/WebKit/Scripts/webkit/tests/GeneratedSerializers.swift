//
// Copyright (C) 2022-2023 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1.  Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#if ENABLE_SWIFT_IPC_RECEIVERS

import WebKit_Internal

extension IPCTypes {
    struct FrameIdentifier: IPCObjectIdentifier {
        let value: IPCObjectIdentifierValue
    }
    struct SwiftAtomicTestIdentifier: IPCObjectIdentifier {
        let value: IPCObjectIdentifierValue
    }
}

extension IPCTypes {
    enum SwiftEnum: UInt8, Sendable, Hashable {
        case firstValue = 0
        case httpsOnly = 1
        case url = 2
        case `default` = 3
    }
}

extension IPCTypes.SwiftEnum: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftEnum {
        guard let value = IPCTypes.SwiftEnum(rawValue: try UInt8.decode(from: &decoder)) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: IPCTypes.SwiftEnum, to encoder: IPC.SwiftReplyEncoder) {
        UInt8.encode(value.rawValue, to: encoder)
    }
}

extension IPCTypes {
    enum SwiftBoolEnum: UInt8, Sendable, Hashable {
        case no = 0
        case yes = 1
    }
}

extension IPCTypes.SwiftBoolEnum: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftBoolEnum {
        guard let value = IPCTypes.SwiftBoolEnum(rawValue: try Bool.decode(from: &decoder) ? 1 : 0) else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: IPCTypes.SwiftBoolEnum, to encoder: IPC.SwiftReplyEncoder) {
        Bool.encode(value.rawValue != 0, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftOptionSet: OptionSet, Sendable, Hashable {
        let rawValue: UInt16

        static let firstOption = SwiftOptionSet(rawValue: 1 << 0)
        static let secondOption = SwiftOptionSet(rawValue: 1 << 1)
    }
}

extension IPCTypes.SwiftOptionSet: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftOptionSet {
        let value = IPCTypes.SwiftOptionSet(rawValue: try UInt16.decode(from: &decoder))
        var unknownValues = value
        unknownValues.subtract(.firstOption)
        unknownValues.subtract(.secondOption)
        guard unknownValues.isEmpty else {
            throw IPCDecodingError()
        }
        return value
    }

    static func encode(_ value: IPCTypes.SwiftOptionSet, to encoder: IPC.SwiftReplyEncoder) {
        UInt16.encode(value.rawValue, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftInner: Sendable, Equatable {
        var value: Int32
        var label: String?
    }
}

extension IPCTypes.SwiftInner: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.value = try Int32.decode(from: &decoder)
        self.label = try IPCCoding.WTFString.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftInner {
        try IPCTypes.SwiftInner(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftInner, to encoder: IPC.SwiftReplyEncoder) {
        Int32.encode(value.value, to: encoder)
        IPCCoding.WTFString.encode(value.label, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftStruct: Sendable, Equatable {
        var flag: Bool
        var name: String?
        var numbers: [UInt64]
        var strings: [String?]
        var atoms: [String?]
        var optionalDouble: Double?
        var markableFrameID: IPCTypes.FrameIdentifier?
        var frameID: IPCTypes.FrameIdentifier
        var atomicID: IPCTypes.SwiftAtomicTestIdentifier
        var inner: IPCTypes.SwiftInner
        var optionalInner: IPCTypes.SwiftInner?
        var enumValue: IPCTypes.SwiftEnum
        var boolEnum: IPCTypes.SwiftBoolEnum
        var options: IPCTypes.SwiftOptionSet
        var variant: IPCTypes.SwiftVariant
        var `default`: Bool
        var accessor: Float
    }
}

extension IPCTypes.SwiftStruct: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.flag = try Bool.decode(from: &decoder)
        self.name = try IPCCoding.WTFString.decode(from: &decoder)
        self.numbers = try IPCCoding.Vector<UInt64>.decode(from: &decoder)
        self.strings = try IPCCoding.Vector<IPCCoding.WTFString>.decode(from: &decoder)
        self.atoms = try IPCCoding.Vector<IPCCoding.WTFString>.decode(from: &decoder)
        self.optionalDouble = try IPCCoding.StdOptional<Double>.decode(from: &decoder)
        self.markableFrameID = try IPCCoding.Markable<IPCTypes.FrameIdentifier>.decode(from: &decoder)
        self.frameID = try IPCTypes.FrameIdentifier.decode(from: &decoder)
        self.atomicID = try IPCTypes.SwiftAtomicTestIdentifier.decode(from: &decoder)
        self.inner = try IPCTypes.SwiftInner.decode(from: &decoder)
        self.optionalInner = try IPCCoding.StdOptional<IPCTypes.SwiftInner>.decode(from: &decoder)
        self.enumValue = try IPCTypes.SwiftEnum.decode(from: &decoder)
        self.boolEnum = try IPCTypes.SwiftBoolEnum.decode(from: &decoder)
        self.options = try IPCTypes.SwiftOptionSet.decode(from: &decoder)
        self.variant = try IPCTypes.SwiftVariant.decode(from: &decoder)
        self.`default` = try Bool.decode(from: &decoder)
        self.accessor = try Float.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftStruct {
        try IPCTypes.SwiftStruct(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftStruct, to encoder: IPC.SwiftReplyEncoder) {
        Bool.encode(value.flag, to: encoder)
        IPCCoding.WTFString.encode(value.name, to: encoder)
        IPCCoding.Vector<UInt64>.encode(value.numbers, to: encoder)
        IPCCoding.Vector<IPCCoding.WTFString>.encode(value.strings, to: encoder)
        IPCCoding.Vector<IPCCoding.WTFString>.encode(value.atoms, to: encoder)
        IPCCoding.StdOptional<Double>.encode(value.optionalDouble, to: encoder)
        IPCCoding.Markable<IPCTypes.FrameIdentifier>.encode(value.markableFrameID, to: encoder)
        IPCTypes.FrameIdentifier.encode(value.frameID, to: encoder)
        IPCTypes.SwiftAtomicTestIdentifier.encode(value.atomicID, to: encoder)
        IPCTypes.SwiftInner.encode(value.inner, to: encoder)
        IPCCoding.StdOptional<IPCTypes.SwiftInner>.encode(value.optionalInner, to: encoder)
        IPCTypes.SwiftEnum.encode(value.enumValue, to: encoder)
        IPCTypes.SwiftBoolEnum.encode(value.boolEnum, to: encoder)
        IPCTypes.SwiftOptionSet.encode(value.options, to: encoder)
        IPCTypes.SwiftVariant.encode(value.variant, to: encoder)
        Bool.encode(value.`default`, to: encoder)
        Float.encode(value.accessor, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftNode: Sendable, Equatable {
        var name: String?
        var children: [IPCTypes.SwiftNode]
        var optionalLeaf: IPCTypes.SwiftLeaf?
        var leaf: IPCTypes.SwiftLeaf
    }
}

extension IPCTypes.SwiftNode: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.name = try IPCCoding.WTFString.decode(from: &decoder)
        self.children = try IPCCoding.Vector<IPCTypes.SwiftNode>.decode(from: &decoder)
        self.optionalLeaf = try IPCCoding.StdOptional<IPCTypes.SwiftLeaf>.decode(from: &decoder)
        self.leaf = try IPCTypes.SwiftLeaf.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftNode {
        try IPCTypes.SwiftNode(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftNode, to encoder: IPC.SwiftReplyEncoder) {
        IPCCoding.WTFString.encode(value.name, to: encoder)
        IPCCoding.Vector<IPCTypes.SwiftNode>.encode(value.children, to: encoder)
        IPCCoding.StdOptional<IPCTypes.SwiftLeaf>.encode(value.optionalLeaf, to: encoder)
        IPCTypes.SwiftLeaf.encode(value.leaf, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftLeaf: Sendable, Equatable {
        var value: UInt64
    }
}

extension IPCTypes.SwiftLeaf: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.value = try UInt64.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftLeaf {
        try IPCTypes.SwiftLeaf(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftLeaf, to encoder: IPC.SwiftReplyEncoder) {
        UInt64.encode(value.value, to: encoder)
    }
}

#if ENABLE_SWIFT_TYPE_CONDITION
extension IPCTypes {
    struct SwiftDerived: Sendable, Equatable {
        var baseValue: UInt32
        var derivedValue: Double
    }
}

extension IPCTypes.SwiftDerived: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.baseValue = try UInt32.decode(from: &decoder)
        self.derivedValue = try Double.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftDerived {
        try IPCTypes.SwiftDerived(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftDerived, to encoder: IPC.SwiftReplyEncoder) {
        UInt32.encode(value.baseValue, to: encoder)
        Double.encode(value.derivedValue, to: encoder)
    }
}
#endif

extension IPCTypes {
    enum SwiftShape: Sendable, Equatable {
        case swiftCircle(IPCTypes.SwiftCircle)
        #if ENABLE_SWIFT_TYPE_CONDITION
        case swiftSquare(IPCTypes.SwiftSquare)
        #endif
        case swiftTriangle(IPCTypes.SwiftTriangle)
    }
}

extension IPCTypes.SwiftShape: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftShape {
        let index = try UInt8.decode(from: &decoder)
        var position: UInt8 = 0
        if index == position {
            return .swiftCircle(try IPCTypes.SwiftCircle.decode(from: &decoder))
        }
        position += 1
        #if ENABLE_SWIFT_TYPE_CONDITION
        if index == position {
            return .swiftSquare(try IPCTypes.SwiftSquare.decode(from: &decoder))
        }
        position += 1
        #endif
        if index == position {
            return .swiftTriangle(try IPCTypes.SwiftTriangle.decode(from: &decoder))
        }
        position += 1
        throw IPCDecodingError()
    }

    static func encode(_ value: IPCTypes.SwiftShape, to encoder: IPC.SwiftReplyEncoder) {
        var position: UInt8 = 0
        if case .swiftCircle(let subclass) = value {
            UInt8.encode(position, to: encoder)
            IPCTypes.SwiftCircle.encode(subclass, to: encoder)
            return
        }
        position += 1
        #if ENABLE_SWIFT_TYPE_CONDITION
        if case .swiftSquare(let subclass) = value {
            UInt8.encode(position, to: encoder)
            IPCTypes.SwiftSquare.encode(subclass, to: encoder)
            return
        }
        position += 1
        #endif
        if case .swiftTriangle(let subclass) = value {
            UInt8.encode(position, to: encoder)
            IPCTypes.SwiftTriangle.encode(subclass, to: encoder)
            return
        }
        position += 1
    }
}

extension IPCTypes {
    struct SwiftCircle: Sendable, Equatable {
        var radius: Float
    }
}

extension IPCTypes.SwiftCircle: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.radius = try Float.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftCircle {
        try IPCTypes.SwiftCircle(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftCircle, to encoder: IPC.SwiftReplyEncoder) {
        Float.encode(value.radius, to: encoder)
    }
}

#if ENABLE_SWIFT_TYPE_CONDITION
extension IPCTypes {
    struct SwiftSquare: Sendable, Equatable {
        var side: Float
    }
}

extension IPCTypes.SwiftSquare: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.side = try Float.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftSquare {
        try IPCTypes.SwiftSquare(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftSquare, to encoder: IPC.SwiftReplyEncoder) {
        Float.encode(value.side, to: encoder)
    }
}
#endif

extension IPCTypes {
    struct SwiftTriangle: Sendable, Equatable {
    }
}

extension IPCTypes.SwiftTriangle: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftTriangle {
        try IPCTypes.SwiftTriangle(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftTriangle, to encoder: IPC.SwiftReplyEncoder) {
    }
}

extension IPCTypes {
    enum SwiftLight: Sendable, Equatable {
        case swiftCircle(IPCTypes.SwiftCircle)
        case swiftTriangle(IPCTypes.SwiftTriangle)
    }
}

extension IPCTypes.SwiftLight: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftLight {
        let index = try UInt8.decode(from: &decoder)
        if index == 0 {
            return .swiftCircle(try IPCTypes.SwiftCircle.decode(from: &decoder))
        }
        if index == 1 {
            return .swiftTriangle(try IPCTypes.SwiftTriangle.decode(from: &decoder))
        }
        throw IPCDecodingError()
    }

    static func encode(_ value: IPCTypes.SwiftLight, to encoder: IPC.SwiftReplyEncoder) {
        if case .swiftCircle(let subclass) = value {
            UInt8.encode(0, to: encoder)
            IPCTypes.SwiftCircle.encode(subclass, to: encoder)
            return
        }
        if case .swiftTriangle(let subclass) = value {
            UInt8.encode(1, to: encoder)
            IPCTypes.SwiftTriangle.encode(subclass, to: encoder)
            return
        }
    }
}

extension IPCTypes {
    struct SwiftDrawing: Sendable, Equatable {
        var shape: IPCTypes.SwiftShape
        var shapes: [IPCTypes.SwiftShape]
        var light: IPCTypes.SwiftLight
    }
}

extension IPCTypes.SwiftDrawing: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.shape = try IPCTypes.SwiftShape.decode(from: &decoder)
        self.shapes = try IPCCoding.Vector<IPCTypes.SwiftShape>.decode(from: &decoder)
        self.light = try IPCTypes.SwiftLight.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftDrawing {
        try IPCTypes.SwiftDrawing(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftDrawing, to encoder: IPC.SwiftReplyEncoder) {
        IPCTypes.SwiftShape.encode(value.shape, to: encoder)
        IPCCoding.Vector<IPCTypes.SwiftShape>.encode(value.shapes, to: encoder)
        IPCTypes.SwiftLight.encode(value.light, to: encoder)
    }
}

extension IPCTypes {
    struct IntSize: Sendable, Equatable {
        var width: Int32
        var height: Int32
    }
}

extension IPCTypes.IntSize: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.width = try Int32.decode(from: &decoder)
        self.height = try Int32.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.IntSize {
        try IPCTypes.IntSize(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.IntSize, to encoder: IPC.SwiftReplyEncoder) {
        Int32.encode(value.width, to: encoder)
        Int32.encode(value.height, to: encoder)
    }
}

extension IPCTypes {
    struct IntPoint: Sendable, Equatable {
        var x: Int32
        var y: Int32
    }
}

extension IPCTypes.IntPoint: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.x = try Int32.decode(from: &decoder)
        self.y = try Int32.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.IntPoint {
        try IPCTypes.IntPoint(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.IntPoint, to encoder: IPC.SwiftReplyEncoder) {
        Int32.encode(value.x, to: encoder)
        Int32.encode(value.y, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftPolicyTerm: Sendable, Equatable {
        var index: UInt32
    }
}

extension IPCTypes.SwiftPolicyTerm: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        self.index = try UInt32.decode(from: &decoder)
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftPolicyTerm {
        try IPCTypes.SwiftPolicyTerm(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftPolicyTerm, to encoder: IPC.SwiftReplyEncoder) {
        UInt32.encode(value.index, to: encoder)
    }
}

extension IPCTypes {
    struct SwiftPolicy: Sendable, Equatable {
        var size: IPCTypes.IntSize
        var offset: IPCTypes.IntPoint
        var values: [Float]
        var radius: Float
        var exponent: Float
        var kind: IPCTypes.SwiftEnum
        var terms: [IPCTypes.SwiftPolicyTerm]
    }
}

extension IPCTypes.SwiftPolicy: IPCCoder {
    fileprivate init(ipcDecodingFrom decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) {
        let size = try IPCTypes.IntSize.decode(from: &decoder)
        guard size.width > 0 && size.height > 0 else {
            throw IPCDecodingError()
        }
        let offset = try IPCTypes.IntPoint.decode(from: &decoder)
        guard (offset.x >= 0 && offset.x < size.width) || offset.y == 0 else {
            throw IPCDecodingError()
        }
        let values = try IPCCoding.Vector<Float>.decode(from: &decoder)
        guard (Int64(size.width) * Int64(size.height)) == Int64(values.count) else {
            throw IPCDecodingError()
        }
        var radius = try Float.decode(from: &decoder)
        radius = (0 < radius ? radius : 0)
        var exponent = try Float.decode(from: &decoder)
        exponent = exponent >= 128 ? 128 : (exponent <= 1 ? 1 : exponent)
        guard exponent != 0.5 else {
            throw IPCDecodingError()
        }
        let kind = try IPCTypes.SwiftEnum.decode(from: &decoder)
        guard kind == IPCTypes.SwiftEnum.url ? Int64(values.count) == 1 : kind != IPCTypes.SwiftEnum.`default` else {
            throw IPCDecodingError()
        }
        let terms = try IPCCoding.Vector<IPCTypes.SwiftPolicyTerm>.decode(from: &decoder)
        guard Int64(terms.count) > 0 && terms.allSatisfy({ term in Int64(term.index) < Int64(values.count) }) else {
            throw IPCDecodingError()
        }
        self.size = size
        self.offset = offset
        self.values = values
        self.radius = radius
        self.exponent = exponent
        self.kind = kind
        self.terms = terms
    }

    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftPolicy {
        try IPCTypes.SwiftPolicy(ipcDecodingFrom: &decoder)
    }

    static func encode(_ value: IPCTypes.SwiftPolicy, to encoder: IPC.SwiftReplyEncoder) {
        IPCTypes.IntSize.encode(value.size, to: encoder)
        IPCTypes.IntPoint.encode(value.offset, to: encoder)
        IPCCoding.Vector<Float>.encode(value.values, to: encoder)
        Float.encode(value.radius, to: encoder)
        Float.encode(value.exponent, to: encoder)
        IPCTypes.SwiftEnum.encode(value.kind, to: encoder)
        IPCCoding.Vector<IPCTypes.SwiftPolicyTerm>.encode(value.terms, to: encoder)
    }
}

extension IPCTypes {
    enum SwiftVariant: Sendable, Equatable {
        case empty
        case uint64(UInt64)
        case string(String?)
        case vectorString([String?])
        case swiftInner(IPCTypes.SwiftInner)
        case swiftNode(IPCTypes.SwiftNode)
    }
}

extension IPCTypes.SwiftVariant: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftVariant {
        switch try UInt8.decode(from: &decoder) {
        case 0:
            return .empty
        case 1:
            return .uint64(try UInt64.decode(from: &decoder))
        case 2:
            return .string(try IPCCoding.WTFString.decode(from: &decoder))
        case 3:
            return .vectorString(try IPCCoding.Vector<IPCCoding.WTFString>.decode(from: &decoder))
        case 4:
            return .swiftInner(try IPCTypes.SwiftInner.decode(from: &decoder))
        case 5:
            return .swiftNode(try IPCTypes.SwiftNode.decode(from: &decoder))
        default:
            throw IPCDecodingError()
        }
    }

    static func encode(_ value: IPCTypes.SwiftVariant, to encoder: IPC.SwiftReplyEncoder) {
        switch value {
        case .empty:
            UInt8.encode(0, to: encoder)
        case .uint64(let alternative):
            UInt8.encode(1, to: encoder)
            UInt64.encode(alternative, to: encoder)
        case .string(let alternative):
            UInt8.encode(2, to: encoder)
            IPCCoding.WTFString.encode(alternative, to: encoder)
        case .vectorString(let alternative):
            UInt8.encode(3, to: encoder)
            IPCCoding.Vector<IPCCoding.WTFString>.encode(alternative, to: encoder)
        case .swiftInner(let alternative):
            UInt8.encode(4, to: encoder)
            IPCTypes.SwiftInner.encode(alternative, to: encoder)
        case .swiftNode(let alternative):
            UInt8.encode(5, to: encoder)
            IPCTypes.SwiftNode.encode(alternative, to: encoder)
        }
    }
}

extension IPCTypes {
    enum SwiftMultiLineVariant: Sendable, Equatable {
        case frameIdentifier(IPCTypes.FrameIdentifier)
        case optionalSwiftEnum(IPCTypes.SwiftEnum?)
    }
}

extension IPCTypes.SwiftMultiLineVariant: IPCCoder {
    static func decode(from decoder: inout IPC.SwiftDecoder) throws(IPCDecodingError) -> IPCTypes.SwiftMultiLineVariant {
        switch try UInt8.decode(from: &decoder) {
        case 0:
            return .frameIdentifier(try IPCTypes.FrameIdentifier.decode(from: &decoder))
        case 1:
            return .optionalSwiftEnum(try IPCCoding.StdOptional<IPCTypes.SwiftEnum>.decode(from: &decoder))
        default:
            throw IPCDecodingError()
        }
    }

    static func encode(_ value: IPCTypes.SwiftMultiLineVariant, to encoder: IPC.SwiftReplyEncoder) {
        switch value {
        case .frameIdentifier(let alternative):
            UInt8.encode(0, to: encoder)
            IPCTypes.FrameIdentifier.encode(alternative, to: encoder)
        case .optionalSwiftEnum(let alternative):
            UInt8.encode(1, to: encoder)
            IPCCoding.StdOptional<IPCTypes.SwiftEnum>.encode(alternative, to: encoder)
        }
    }
}

extension IPCTypes {
    /// The Swift forms of C++ types by qualified C++ name, so Swift naming a C++ type that has none does not compile.
    enum CxxName {
        typealias Namespace_SwiftBoolEnum = IPCTypes.SwiftBoolEnum
        typealias Namespace_SwiftCircle = IPCTypes.SwiftCircle
        #if ENABLE_SWIFT_TYPE_CONDITION
        typealias Namespace_SwiftDerived = IPCTypes.SwiftDerived
        #endif
        typealias Namespace_SwiftDrawing = IPCTypes.SwiftDrawing
        typealias Namespace_SwiftEnum = IPCTypes.SwiftEnum
        typealias Namespace_SwiftInner = IPCTypes.SwiftInner
        typealias Namespace_SwiftLeaf = IPCTypes.SwiftLeaf
        typealias Namespace_SwiftLight = IPCTypes.SwiftLight
        typealias Namespace_SwiftMultiLineVariant = IPCTypes.SwiftMultiLineVariant
        typealias Namespace_SwiftNode = IPCTypes.SwiftNode
        typealias Namespace_SwiftOptionSet = IPCTypes.SwiftOptionSet
        typealias Namespace_SwiftPolicy = IPCTypes.SwiftPolicy
        typealias Namespace_SwiftPolicyTerm = IPCTypes.SwiftPolicyTerm
        typealias Namespace_SwiftShape = IPCTypes.SwiftShape
        #if ENABLE_SWIFT_TYPE_CONDITION
        typealias Namespace_SwiftSquare = IPCTypes.SwiftSquare
        #endif
        typealias Namespace_SwiftStruct = IPCTypes.SwiftStruct
        typealias Namespace_SwiftTriangle = IPCTypes.SwiftTriangle
        typealias Namespace_SwiftVariant = IPCTypes.SwiftVariant
        typealias WebCore_FrameIdentifier = IPCTypes.FrameIdentifier
        typealias WebCore_IntPoint = IPCTypes.IntPoint
        typealias WebCore_IntSize = IPCTypes.IntSize
        typealias WebKit_SwiftAtomicTestIdentifier = IPCTypes.SwiftAtomicTestIdentifier
    }
}

#endif
