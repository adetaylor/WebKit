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

// Strings, identifier tables and pipeline constants between WebKit and the Swift WGSL compiler, whose types the rest of
// the WebGPU Swift code uses directly. In this file `WGSL.X` is the C++ namespace from WGSLAPI.h (an imported declaration
// shadows the module name); the Swift module's declarations are used unqualified.

private import CxxStdlib
internal import WGSL
import WebGPU_Internal.ShaderModule
import WebGPU_Internal.WGSLAPI
import WebGPU_Private.WebGPUCpp

// MARK: - Called from C++

// The stack size of the thread WebGPU.Metal.runOnWGSLCompileThread runs the static check, compileEntryPoint and
// evaluateWorkgroupSize on; 0 means the calling thread.
@_expose(Cxx)
func wgslRecommendedCompileStackSize() -> UInt64 {
    UInt64(CompileThread.recommendedStackSize ?? 0)
}

// MARK: - Metal buffer slots

// For HardwareCapabilities.swift, which does not import WGSL.
func wgslVertexBufferIndexForBindGroup(_ groupIndex: UInt32, _ maxIndex: UInt32) -> UInt32 {
    vertexBufferIndexForBindGroup(groupIndex, maxIndex: maxIndex)
}

// MARK: - Identifier classification

// The running OS's ICU XID tables, so that identifiers lex as ICU's u_stringHasBinaryProperty classifies them.
// Built once per process, possibly on the WGSL compile thread (a global's lazy initialization is thread-safe).
let icuIdentifierCharacterClasses = IdentifierCharacterClasses(
    xidStartRanges: makeIdentifierRanges(xidContinue: false),
    xidContinueRanges: makeIdentifierRanges(xidContinue: true)
)

private func makeIdentifierRanges(xidContinue: Bool) -> [UInt32] {
    let ranges = WGSL.Interop.icuIdentifierRanges(xidContinue)
    var copy = ContiguousArray<UInt32>(repeating: 0, count: Int(ranges.size()))
    var destination = copy.mutableSpan
    WGSL.Interop.copyIdentifierRanges(ranges, &destination)
    return Array(copy)
}

// MARK: - Strings

// One memcpy from the WTF::String into Swift-owned storage, which the compiler then takes over.
func wgslSourceText(_ string: borrowing WTF.String) -> SourceText {
    let length = Int(string.length())
    if string.is8Bit() {
        var codeUnits = ContiguousArray<UInt8>(repeating: 0, count: length)
        var destination = codeUnits.mutableSpan
        WGSL.Interop.copyLatin1CodeUnits(string, &destination)
        return SourceText(latin1: codeUnits)
    }
    var codeUnits = ContiguousArray<UInt16>(repeating: 0, count: length)
    var destination = codeUnits.mutableSpan
    WGSL.Interop.copyUTF16CodeUnits(string, &destination)
    return SourceText(utf16: codeUnits)
}

// nil iff `string.isNull()`. An empty but non-null String is an empty Name.
func wgslName(_ string: borrowing WTF.String) -> Name? {
    if string.isNull() {
        return nil
    }
    return makeName(string)
}

// A null String is an empty Name.
func makeName(_ string: borrowing WTF.String) -> Name {
    let length = Int(string.length())
    if string.is8Bit() {
        var codeUnits = ContiguousArray<UInt8>(repeating: 0, count: length)
        var destination = codeUnits.mutableSpan
        WGSL.Interop.copyLatin1CodeUnits(string, &destination)
        return Name(latin1: codeUnits)
    }
    var codeUnits = ContiguousArray<UInt16>(repeating: 0, count: length)
    var destination = codeUnits.mutableSpan
    WGSL.Interop.copyUTF16CodeUnits(string, &destination)
    return Name(utf16: codeUnits)
}

func wtfString(_ name: Name) -> WTF.String {
    wtfString(utf16: name.utf16)
}

func wtfString(utf16 codeUnits: ContiguousArray<UInt16>) -> WTF.String {
    WGSL.Interop.makeStringFromUTF16(codeUnits.span)
}

// The MSL path: one copy, no Swift-side scan, no intermediate Swift.String.
func wtfString(utf8 bytes: ContiguousArray<UInt8>) -> WTF.String {
    WGSL.Interop.makeStringFromUTF8(bytes.span)
}

func wtfString(_ string: Swift.String) -> WTF.String {
    wtfString(utf8: ContiguousArray(string.utf8))
}

// MARK: - Pipeline constants

func pipelineConstants(_ stage: borrowing WebGPU.ProgrammableStage) -> [PipelineConstant] {
    let constants: Span<WebGPU.ConstantEntry> = stage.constantsSpan()
    return pipelineConstants(constants)
}

func pipelineConstants(_ constants: Span<WebGPU.ConstantEntry>) -> [PipelineConstant] {
    var result: [PipelineConstant] = []
    result.reserveCapacity(constants.count)
    for index in constants.indices {
        result.append(PipelineConstant(key: makeName(constants[index].key), value: constants[index].value))
    }
    return result
}
