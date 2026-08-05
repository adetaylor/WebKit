// Copyright (C) 2021-2024 Apple Inc. All rights reserved.
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

import WebGPU_Internal.Buffer
import wtf

extension WebGPU.Buffer {
    func copy(destination: WTF.NonEscapableMutableBytes, source: WTF.NonEscapableBytes, offset: Int) {
        destination.subspan(offset, source.size()).copyFrom(source)
    }
}

@_expose(Cxx)
func bufferCopyFrom(
    _ buffer: WebGPU.Buffer,
    destination: WTF.NonEscapableMutableBytes,
    source: WTF.NonEscapableBytes,
    offset: Int,
) {
    buffer.copy(destination: destination, source: source, offset: offset)
}

@_expose(Cxx)
@_lifetime(copy contents)
func bufferGetMappedRange(
    _ buffer: WebGPU.Buffer,
    contents: WTF.NonEscapableMutableBytes,
    offset: Int,
    size: Int,
) -> WTF.NonEscapableMutableBytes {
    buffer.getMappedRange(contents: contents, offset: offset, size: size)
}

extension WebGPU.Buffer {
    @_lifetime(copy contents)
    func getMappedRange(contents: WTF.NonEscapableMutableBytes, offset: Int, size: Int) -> WTF.NonEscapableMutableBytes {
        if !isValid() {
            return WTF.NonEscapableMutableBytes()
        }

        var rangeSize = size
        if size == WGPU_WHOLE_MAP_SIZE {
            rangeSize = max(Int(currentSize()) - offset, 0)
        }

        if !validateGetMappedRange(offset, rangeSize) {
            return WTF.NonEscapableMutableBytes()
        }

        m_mappedRanges.add(.init(UInt(offset), UInt(offset + rangeSize)))
        m_mappedRanges.compact()

        if m_buffer.storageMode == .private || m_buffer.storageMode == .memoryless || m_buffer.length == 0 {
            return WTF.NonEscapableMutableBytes()
        }

        return contents.subspan(offset, rangeSize)
    }
}
