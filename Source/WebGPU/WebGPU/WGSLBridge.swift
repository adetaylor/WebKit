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

// What the rest of the WebGPU Swift code takes from the Swift WGSL compiler without importing it, and the labels of Metal
// objects.

@_implementationOnly import WGSL

// MARK: - Metal buffer slots

// For HardwareCapabilities.swift, which does not import WGSL.
func wgslVertexBufferIndexForBindGroup(_ groupIndex: UInt32, _ maxIndex: UInt32) -> UInt32 {
    vertexBufferIndexForBindGroup(groupIndex, maxIndex: maxIndex)
}

// For Queue.swift, which does not import WGSL: the HDR to SDR mapping that external textures sample through.
func wgslHDRToSDRMetalSource() -> String {
    hdrToSDRMetalSource()
}

// MARK: - Identifier classification

// The running OS's ICU XID tables, so that identifiers lex as ICU's u_stringHasBinaryProperty classifies them.
// Built once per process, possibly on the WGSL compile thread (a global's lazy initialization is thread-safe).
let icuIdentifierCharacterClasses = IdentifierCharacterClasses(
    xidStartRanges: icuIdentifierRanges(xidContinue: false),
    xidContinueRanges: icuIdentifierRanges(xidContinue: true)
)

// MARK: - Labels

// The label a Metal object takes: none for a missing or empty one.
func nonEmptyLabel(_ label: Swift.String?) -> Swift.String? {
    guard let label, !label.isEmpty else {
        return nil
    }
    return label
}
