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

private struct MemberSizes {
    let typeSize: UInt32
    let fieldSize: UInt32
    let fieldAlignment: UInt32
}

private struct LaidOutStructure: Equatable {
    var offsets: [UInt32] = []
    var paddings: [UInt32] = []
    var size: UInt32 = 0
    var alignment: UInt32 = 0
}

// The member loop of AttributeValidator::visit(AST::Structure&): offsets in order, each padding written to the previous
// member, then the last member's padding.
private func layOut(_ members: [MemberSizes]) -> LaidOutStructure {
    var layout = StructureLayout()
    var result = LaidOutStructure()
    for member in members {
        let placement = layout.addMember(
            typeSize: ByteSize(bytes: member.typeSize),
            fieldSize: ByteSize(bytes: member.fieldSize),
            fieldAlignment: ByteAlignment(member.fieldAlignment)
        )
        result.offsets.append(placement.offset)
        if let padding = placement.previousMemberPadding {
            result.paddings.append(padding)
        }
    }
    let final = layout.finish()
    if let padding = final.lastMemberPadding {
        result.paddings.append(padding)
    }
    result.size = final.size.bytes
    result.alignment = final.alignment
    return result
}

private func f32(size: UInt32? = nil, align: UInt32? = nil) -> MemberSizes {
    MemberSizes(typeSize: 4, fieldSize: size ?? 4, fieldAlignment: align ?? 4)
}

@Suite
struct WGSLByteSizeTests {
    @Test
    func checkedUInt32RecordsOverflowFromConversions() {
        #expect(!CheckedUInt32(checking: UInt64(UInt32.max)).hasOverflowed)
        #expect(CheckedUInt32(checking: UInt64(UInt32.max)).value == UInt32.max)
        #expect(CheckedUInt32(checking: UInt64(UInt32.max) + 1).hasOverflowed)
        #expect(!CheckedUInt32(checking: Int64(0)).hasOverflowed)
        #expect(!CheckedUInt32(checking: Int64(UInt32.max)).hasOverflowed)
        #expect(CheckedUInt32(checking: Int64(UInt32.max) + 1).hasOverflowed)
        #expect(CheckedUInt32(checking: Int64(-1)).hasOverflowed)
        #expect(CheckedUInt32(checking: Int64.min).hasOverflowed)
    }

    @Test
    func checkedUInt32OverflowIsSticky() {
        var sum = CheckedUInt32(UInt32.max - 1)
        sum += 1
        #expect(!sum.hasOverflowed)
        #expect(sum.value == UInt32.max)
        sum += 1
        #expect(sum.hasOverflowed)
        sum *= 0
        #expect(sum.hasOverflowed)

        var product = CheckedUInt32(0x1_0000)
        product *= 0xFFFF
        #expect(product.value == 0xFFFF_0000)
        product *= 2
        #expect(product.hasOverflowed)
        product += ByteSize(bytes: 0)
        #expect(product.hasOverflowed)

        // Assigning a fresh value clears the overflow, as Checked::operator= does.
        product = CheckedUInt32(7)
        #expect(!product.hasOverflowed)
        #expect(product.value == 7)
    }

    @Test
    func checkedUInt32Subtraction() {
        #expect((UInt32(10) - CheckedUInt32(3)).value == 7)
        #expect(!(UInt32(3) - CheckedUInt32(3)).hasOverflowed)
        #expect((UInt32(3) - CheckedUInt32(4)).hasOverflowed)
        var overflowed = CheckedUInt32(UInt32.max)
        overflowed += 1
        #expect((UInt32.max - overflowed).hasOverflowed)
    }

    @Test
    func roundUpToMultipleOfWrapsInTheOperandType() {
        #expect(wtfRoundUpToMultipleOf(16, UInt32(0)) == 0)
        #expect(wtfRoundUpToMultipleOf(16, UInt32(1)) == 16)
        #expect(wtfRoundUpToMultipleOf(16, UInt32(16)) == 16)
        #expect(wtfRoundUpToMultipleOf(16, UInt32(17)) == 32)
        #expect(wtfRoundUpToMultipleOf(1, UInt32.max) == UInt32.max)
        #expect(wtfRoundUpToMultipleOf(4, UInt32(0xFFFF_FFFD)) == 0)
        #expect(wtfRoundUpToMultipleOf(4, UInt64(0xFFFF_FFFD)) == 0x1_0000_0000)
        #expect(wtfRoundUpToMultipleOf(4, UInt64.max) == 0)
    }

    @Test
    func byteAlignmentValidation() {
        #expect(ByteAlignment(validating: 0) == nil)
        #expect(ByteAlignment(validating: 1)?.bytes == 1)
        #expect(ByteAlignment(validating: 3) == nil)
        #expect(ByteAlignment(validating: 16)?.bytes == 16)
        #expect(ByteAlignment(validating: 24) == nil)
        #expect(ByteAlignment(validating: 0x8000_0000)?.bytes == 0x8000_0000)
        #expect(ByteAlignment(validating: UInt32.max) == nil)
    }

    @Test
    func vectorAndMatrixSizes() {
        #expect(ByteSize.vectorSize(element: ByteSize(bytes: 4), count: 3).bytes == 12)
        #expect(ByteSize.vectorSize(element: ByteSize(bytes: 2), count: 4).bytes == 8)
        // mat3x3<f32>: three columns of vec3<f32> padded to 16 bytes.
        #expect(ByteSize.matrixSize(columns: 3, rows: 3, element: ByteSize(bytes: 4), elementAlignment: ByteAlignment(4)).bytes == 48)
        // mat4x2<f32>: a two-row column is aligned to 2 * 4 bytes.
        #expect(ByteSize.matrixSize(columns: 4, rows: 2, element: ByteSize(bytes: 4), elementAlignment: ByteAlignment(4)).bytes == 32)
        // mat2x3<f16>
        #expect(ByteSize.matrixSize(columns: 2, rows: 3, element: ByteSize(bytes: 2), elementAlignment: ByteAlignment(2)).bytes == 16)
        #expect(ByteSize.matrixSize(columns: 2, rows: 2, element: ByteSize(bytes: 2), elementAlignment: ByteAlignment(2)).bytes == 8)
    }

    @Test
    func primitiveStructSizeWraps() {
        let size = ByteSize(bytes: 4).addingPrimitiveStructMember(ByteSize(bytes: 12))
        #expect(size.bytes == 16)
        #expect(ByteSize.saturated.addingPrimitiveStructMember(ByteSize(bytes: 2)).bytes == 1)
    }

    @Test
    func arraySizes() {
        let vec3f = ByteSize(bytes: 12)
        let vec3fAlignment = ByteAlignment(16)
        #expect(ByteSize.arrayStride(element: vec3f, elementAlignment: vec3fAlignment).bytes == 16)
        #expect(ByteSize.arraySize(count: CheckedUInt32(4), element: vec3f, elementAlignment: vec3fAlignment).bytes == 64)
        // A runtime-sized array, and an override count with no constant value, count one element.
        #expect(ByteSize.arraySize(count: CheckedUInt32(1), element: vec3f, elementAlignment: vec3fAlignment).bytes == 16)
        #expect(
            ByteSize.arraySize(count: CheckedUInt32(checking: Int64(5)), element: ByteSize(bytes: 4), elementAlignment: ByteAlignment(4))
                .bytes == 20
        )
    }

    @Test
    func arraySizeOverflowSaturates() {
        let f32 = ByteSize(bytes: 4)
        let f32Alignment = ByteAlignment(4)
        #expect(ByteSize.arraySize(count: CheckedUInt32(0x3FFF_FFFF), element: f32, elementAlignment: f32Alignment).bytes == 0xFFFF_FFFC)
        #expect(ByteSize.arraySize(count: CheckedUInt32(0x4000_0000), element: f32, elementAlignment: f32Alignment) == .saturated)
        #expect(ByteSize.arraySize(count: CheckedUInt32(checking: Int64(-1)), element: f32, elementAlignment: f32Alignment) == .saturated)
        #expect(
            ByteSize.arraySize(count: CheckedUInt32(checking: Int64(1) << 32), element: f32, elementAlignment: f32Alignment) == .saturated
        )
        // A count that overflowed saturates even when the stride is 0.
        #expect(
            ByteSize.arraySize(count: CheckedUInt32(checking: Int64(-1)), element: ByteSize(bytes: 0), elementAlignment: f32Alignment)
                == .saturated
        )
    }

    @Test
    func arrayStrideWrapSaturates() {
        // roundUpToMultipleOf(16, 0xFFFFFFF1) wraps to 0, below the element size.
        let element = ByteSize(bytes: 0xFFFF_FFF1)
        #expect(ByteSize.arrayStride(element: element, elementAlignment: ByteAlignment(16)).bytes == 0)
        #expect(ByteSize.arraySize(count: CheckedUInt32(1), element: element, elementAlignment: ByteAlignment(16)) == .saturated)
        #expect(ByteSize.arraySize(count: CheckedUInt32(0), element: element, elementAlignment: ByteAlignment(16)) == .saturated)
        // No wrap: a stride equal to the element size.
        #expect(
            ByteSize.arraySize(count: CheckedUInt32(1), element: ByteSize(bytes: 0xFFFF_FFF0), elementAlignment: ByteAlignment(16)).bytes
                == 0xFFFF_FFF0
        )
    }

    @Test
    func normalStructure() {
        // https://www.w3.org/TR/WGSL/#structure-member-layout: struct A { u: f32, v: f32, w: vec2<f32>, x: f32 }
        let layout = layOut([f32(), f32(), MemberSizes(typeSize: 8, fieldSize: 8, fieldAlignment: 8), f32()])
        #expect(layout == LaidOutStructure(offsets: [0, 4, 8, 16], paddings: [0, 0, 0, 4], size: 24, alignment: 8))
    }

    @Test
    func structureWithSizeAndAlignAttributes() {
        // struct { @size(16) a: f32, b: f32 }: @size counts the extra bytes as the member's padding.
        #expect(layOut([f32(size: 16), f32()]) == LaidOutStructure(offsets: [0, 16], paddings: [12, 0], size: 20, alignment: 4))
        // struct { a: f32, @align(16) b: f32 }
        #expect(layOut([f32(), f32(align: 16)]) == LaidOutStructure(offsets: [0, 16], paddings: [12, 12], size: 32, alignment: 16))
        // struct { a: f32, b: vec3<f32>, c: f32 }
        let vec3f = MemberSizes(typeSize: 12, fieldSize: 12, fieldAlignment: 16)
        #expect(layOut([f32(), vec3f, f32()]) == LaidOutStructure(offsets: [0, 16, 28], paddings: [12, 0, 0], size: 32, alignment: 16))
    }

    @Test
    func saturatingStructure() {
        // Saturation: @size(0xFFFFFFF0) then @size(32).
        let layout = layOut([f32(size: 0xFFFF_FFF0), f32(size: 32), f32()])
        #expect(layout.offsets == [0, 0xFFFF_FFF0, UInt32.max])
        #expect(layout.size == UInt32.max)
        #expect(layout.paddings == [0xFFFF_FFEC, 11, 0])
        #expect(layout.alignment == 4)
    }

    @Test
    func saturatingStructureFallsBackToCurrentSize() {
        // Rounding the offset up overflows, and previousSize = offset + typeSize overflows and falls back to currentSize.
        let layout = layOut([f32(size: 0xFFFF_FFF1), MemberSizes(typeSize: 16, fieldSize: 16, fieldAlignment: 16)])
        #expect(layout.offsets == [0, UInt32.max])
        #expect(layout.size == UInt32.max)
        #expect(layout.paddings == [0xFFFF_FFFB, 14])
        #expect(layout.alignment == 16)
    }

    @Test
    func saturatingStructureFinalRoundUp() {
        // The size fits, but rounding it up to the structure alignment does not.
        let layout = layOut([MemberSizes(typeSize: 16, fieldSize: 16, fieldAlignment: 16), f32(size: 0xFFFF_FFE1)])
        #expect(layout.offsets == [0, 16])
        #expect(layout.size == UInt32.max)
        #expect(layout.paddings == [0, 0xFFFF_FFEB])
        #expect(layout.alignment == 16)
    }

    @Test
    func firstMemberHasNoPreviousPadding() {
        var layout = StructureLayout()
        let placement = layout.addMember(typeSize: ByteSize(bytes: 4), fieldSize: ByteSize(bytes: 4), fieldAlignment: ByteAlignment(4))
        #expect(placement.offset == 0)
        #expect(placement.previousMemberPadding == nil)
        #expect(layout.finish().lastMemberPadding == 0)
    }

    @Test
    func runtimeArrayLayout() {
        // struct { a: u32, b: array<vec4<f32>> }: the store size counts one element, so it covers offset + stride.
        let vec4f = ByteSize(bytes: 16)
        let vec4fAlignment = ByteAlignment(16)
        let element = ByteSize.arraySize(count: CheckedUInt32(1), element: vec4f, elementAlignment: vec4fAlignment)
        var structure = StructureLayout()
        _ = structure.addMember(typeSize: ByteSize(bytes: 4), fieldSize: ByteSize(bytes: 4), fieldAlignment: ByteAlignment(4))
        let placement = structure.addMember(typeSize: element, fieldSize: element, fieldAlignment: vec4fAlignment)
        let storeSize = structure.finish().size

        let layout = RuntimeArrayLayout(offsetInBinding: placement.offset, elementSize: vec4f, elementAlignment: vec4fAlignment)
        #expect(layout.offsetInBinding == 16)
        #expect(layout.stride == 16)
        #expect(layout.minimumBindingSize.bytes == 32)
        #expect(storeSize >= layout.minimumBindingSize)

        let vec3f = RuntimeArrayLayout(offsetInBinding: 0, elementSize: ByteSize(bytes: 12), elementAlignment: ByteAlignment(16))
        #expect(vec3f.stride == 16)
        #expect(vec3f.minimumBindingSize.bytes == 16)
    }

    @Test
    func runtimeArrayLayoutSaturates() {
        let layout = RuntimeArrayLayout(offsetInBinding: 0xFFFF_FFF0, elementSize: ByteSize(bytes: 32), elementAlignment: ByteAlignment(16))
        #expect(layout.minimumBindingSize == .saturated)
        let exact = RuntimeArrayLayout(offsetInBinding: 0xFFFF_FFFB, elementSize: ByteSize(bytes: 4), elementAlignment: ByteAlignment(4))
        #expect(exact.minimumBindingSize.bytes == UInt32.max)
    }
}
