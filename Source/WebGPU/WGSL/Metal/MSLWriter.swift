// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

/// Compile-time MSL text.
///
/// Only a literal converts to it and it has no interpolation, so no runtime text reaches the writer through it. Brackets
/// belong to `MSLAttribute`, `appendArrayExtent`, `MSLHelperText` and the subscript sink (lint L-MSL-1).
@_spi(Testing)
public struct MSLText: ExpressibleByStringLiteral, Sendable {
    @_spi(Testing)
    public typealias StringLiteralType = String

    @usableFromInline
    let literal: ByteLiteral

    @_spi(Testing)
    @_transparent
    public init(stringLiteral value: String) {
        literal = ByteLiteral(stringLiteral: value) // lint-exempt(L-MSL-4): forwards MSLText's own literal to the sink's literal type
    }
}

/// A WGSL-typed scalar spelled as MSL, through the WTF formatters only.
@_spi(Testing)
public enum MSLNumber: Sendable {
    /// `StringBuilder::append(int64_t)`.
    case abstractInt(Int64)
    /// `StringBuilder::append(int32_t)`: INT32_MIN is "-2147483648", which MSL parses as a `long` (replicated).
    case i32(Int32)
    /// `append(value, 'u')`.
    case u32(UInt32)
    /// `numberToStringWithTrailingPoint(double)`.
    case abstractFloat(Double)
    /// `numberToStringWithTrailingPoint(double)` of the widened value.
    case f32(Float)
    /// `numberToStringWithTrailingPoint(double)` of the widened value, without an `h` suffix.
    case f16(Half)
    /// `String::number(double)`.
    case double(Double)
}

/// The MSL attributes `[[…]]` the writer emits.
@_spi(Testing)
public enum MSLAttribute: Sendable {
    case stageIn
    case clipDistance
    case depthAny
    case frontFacing
    case threadPositionInGrid
    case instanceID
    case threadPositionInThreadgroup
    case threadIndexInThreadgroup
    case threadgroupsPerGrid
    case position
    case primitiveID
    case sampleID
    case sampleMask
    case threadIndexInSimdgroup
    case threadsPerSimdgroup
    case simdgroupIndexInThreadgroup
    case simdgroupsPerThreadgroup
    case vertexID
    case threadgroupPositionInGrid
    case vertex
    case fragment
    case kernel
    case buffer(UInt32)
    case id(Int64)
    case userLocation(Int64)
    case color(Int64)
    case attribute(Int64)
    case flat
    case centerNoPerspective
    case centroidNoPerspective
    case sampleNoPerspective
    case centerPerspective
    case centroidPerspective
    case samplePerspective
    case invariant
}

/// WTF `Indentation<4>`: four spaces per level.
@_spi(Testing)
public struct Indentation: Sendable {
    @_spi(Testing)
    public private(set) var value: UInt32 = 0

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public mutating func increment() {
        value &+= 1
    }

    @_spi(Testing)
    public mutating func decrement() {
        guard value > 0 else {
            wgslFatal("unbalanced indentation", cppSite: "StringConcatenate.h:381")
        }
        value &-= 1
    }
}

/// The MSL sink, C++ `StringBuilder`.
///
/// There is deliberately no `append(String)`, `append(Substring)` or `append([UInt8])`: every byte comes from a literal, a
/// typed number, an attribute, an array extent, a helper body, or the identifier and subscript sinks.
@_spi(Testing)
public struct MSLWriter: ~Copyable {
    @usableFromInline
    var sink: ByteSink

    @_spi(Testing)
    public init() {
        sink = ByteSink()
    }

    @_spi(Testing)
    public init(reservingCapacity capacity: Int) {
        sink = ByteSink(reservingCapacity: capacity)
    }

    @_spi(Testing)
    public var bytes: ContiguousArray<UInt8> { sink.bytes }

    @_spi(Testing)
    @_transparent
    public mutating func append(_ text: MSLText) {
        sink.append(text.literal)
    }

    @_spi(Testing)
    public mutating func append(_ helper: MSLHelperText) {
        sink.append(helper.literal)
    }

    @_spi(Testing)
    @inline(__always)
    public mutating func append(_ indentation: Indentation) {
        sink.appendSpaces(Int(indentation.value) &* 4)
    }

    @_spi(Testing)
    public mutating func append(_ number: MSLNumber) {
        switch number {
        case .abstractInt(let value):
            sink.appendDecimal(value)
        case .i32(let value):
            sink.appendDecimal(value)
        case .u32(let value):
            sink.appendDecimal(value)
            sink.append("u")
        case .abstractFloat(let value):
            WTFNumberFormat.appendWithTrailingPoint(value, to: &sink)
        case .f32(let value):
            WTFNumberFormat.appendWithTrailingPoint(Double(value), to: &sink)
        case .f16(let value):
            WTFNumberFormat.appendWithTrailingPoint(Double(value), to: &sink)
        case .double(let value):
            WTFNumberFormat.appendNumber(value, to: &sink)
        }
    }

    @_spi(Testing)
    public mutating func append(_ attribute: MSLAttribute) {
        switch attribute {
        case .stageIn:
            sink.append("[[stage_in]]")
        case .clipDistance:
            sink.append("[[clip_distance]]")
        case .depthAny:
            sink.append("[[depth(any)]]")
        case .frontFacing:
            sink.append("[[front_facing]]")
        case .threadPositionInGrid:
            sink.append("[[thread_position_in_grid]]")
        case .instanceID:
            sink.append("[[instance_id]]")
        case .threadPositionInThreadgroup:
            sink.append("[[thread_position_in_threadgroup]]")
        case .threadIndexInThreadgroup:
            sink.append("[[thread_index_in_threadgroup]]")
        case .threadgroupsPerGrid:
            sink.append("[[threadgroups_per_grid]]")
        case .position:
            sink.append("[[position]]")
        case .primitiveID:
            sink.append("[[primitive_id]]")
        case .sampleID:
            sink.append("[[sample_id]]")
        case .sampleMask:
            sink.append("[[sample_mask]]")
        case .threadIndexInSimdgroup:
            sink.append("[[thread_index_in_simdgroup]]")
        case .threadsPerSimdgroup:
            sink.append("[[threads_per_simdgroup]]")
        case .simdgroupIndexInThreadgroup:
            sink.append("[[simdgroup_index_in_threadgroup]]")
        case .simdgroupsPerThreadgroup:
            sink.append("[[simdgroups_per_threadgroup]]")
        case .vertexID:
            sink.append("[[vertex_id]]")
        case .threadgroupPositionInGrid:
            sink.append("[[threadgroup_position_in_grid]]")
        case .vertex:
            sink.append("[[vertex]]")
        case .fragment:
            sink.append("[[fragment]]")
        case .kernel:
            sink.append("[[kernel]]")
        case .buffer(let index):
            sink.append("[[buffer(")
            sink.appendDecimal(index)
            sink.append(")]]")
        case .id(let index):
            sink.append("[[id(")
            sink.appendDecimal(index)
            sink.append(")]]")
        case .userLocation(let location):
            sink.append("[[user(loc")
            sink.appendDecimal(location)
            sink.append(")]]")
        case .color(let location):
            sink.append("[[color(")
            sink.appendDecimal(location)
            sink.append(")]]")
        case .attribute(let location):
            sink.append("[[attribute(")
            sink.appendDecimal(location)
            sink.append(")]]")
        case .flat:
            sink.append("[[flat]]")
        case .centerNoPerspective:
            sink.append("[[center_no_perspective]]")
        case .centroidNoPerspective:
            sink.append("[[centroid_no_perspective]]")
        case .sampleNoPerspective:
            sink.append("[[sample_no_perspective]]")
        case .centerPerspective:
            sink.append("[[center_perspective]]")
        case .centroidPerspective:
            sink.append("[[centroid_perspective]]")
        case .samplePerspective:
            sink.append("[[sample_perspective]]")
        case .invariant:
            sink.append("[[invariant]]")
        }
    }

    /// An array declarator's extent, `[N]` (`[]` when the size is not a constant): a declaration, not a subscript.
    @_spi(Testing)
    public mutating func appendArrayExtent(_ extent: UInt32?) {
        sink.append("[")
        if let extent {
            sink.appendDecimal(extent)
        }
        sink.append("]")
    }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int32) {
        sink.appendDecimal(value)
    }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt32) {
        sink.appendDecimal(value)
    }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int64) {
        sink.appendDecimal(value)
    }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: UInt64) {
        sink.appendDecimal(value)
    }

    @_spi(Testing)
    public mutating func appendDecimal(_ value: Int) {
        sink.appendDecimal(value)
    }

    /// The only way identifier text reaches MSL: a mangled, reserved, builtin or swizzle spelling; text of the source
    /// traps in `ByteSink.appendIdentifier`, so `sink` offers no way around the check.
    @_spi(Testing)
    public mutating func append(identifier symbol: Symbol, in symbols: borrowing SymbolTable) {
        sink.appendIdentifier(symbol, in: symbols)
    }

    /// The `[` of a user subscript, which needs the access's SubscriptProof; `closeSubscript` writes the `]`.
    ///
    /// A constant-valued access is printed as its constant, so its proof never reaches here.
    @_spi(Testing)
    public mutating func emitSubscript(_ proof: SubscriptProof) -> OpenSubscript {
        switch proof.reason {
        case .clamped, .inBoundsConstant, .overrideValidated, .loopInduction:
            sink.append("[")
        case .constantValue:
            wgslFatal("a constant-valued index access reached the subscript sink", cppSite: "BoundsCheck.cpp:66")
        }
        return OpenSubscript()
    }

    @_spi(Testing)
    public mutating func closeSubscript(_ openSubscript: consuming OpenSubscript) {
        sink.append("]")
        openSubscript.close()
    }

    /// The only `__DynamicOffsets[k]` sink: `k` is a slot GlobalVariableRewriter+Globals.swift minted, never an
    /// expression, spelled as C++ prints it.
    mutating func appendDynamicOffsetsElement(_ slot: DynamicOffsetSlot) {
        sink.append("__DynamicOffsets[")
        sink.appendDecimal(slot.index)
        if !slot.isReserved {
            sink.append("u")
        }
        sink.append("]")
    }

    @_spi(Testing)
    public mutating func append(contentsOf other: borrowing MSLWriter) {
        sink.append(contentsOf: other.sink)
    }

    @_spi(Testing)
    public mutating func clear() {
        sink.clear()
    }

    @_spi(Testing)
    public consuming func finish() -> ContiguousArray<UInt8> {
        sink.finish()
    }
}

/// A user subscript between its `[` and `]`.
///
/// Only `MSLWriter.emitSubscript` makes one and only `MSLWriter.closeSubscript` ends one; dropping it traps.
@_spi(Testing)
public struct OpenSubscript: ~Copyable {
    fileprivate init() {}

    fileprivate consuming func close() {
        discard self
    }

    deinit {
        trapUnclosedSubscript()
    }
}

/// Not `Never`, so that no toolchain reports the deinit's implicit epilogue as never executed.
private func trapUnclosedSubscript() {
    wgslFatal("a user subscript was never closed", cppSite: "MetalFunctionWriter.cpp:3139")
}
