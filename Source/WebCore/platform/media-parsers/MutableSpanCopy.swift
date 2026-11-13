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

#if ENABLE_WEBCORE_SWIFT

// Copies source into destination from offset on, trapping unless it all fits. The media parsers' bulk copies into
// C++ memory go through this: MutableSpan has no stable way to take a mutable sub-span, so copying a run of bytes into
// the middle of one needs its buffer pointer.
@inline(__always)
func copyBytes(_ source: Span<UInt8>, into destination: inout MutableSpan<UInt8>, at offset: Int) {
    precondition(offset >= 0 && offset <= destination.count && source.count <= destination.count - offset)
    if source.isEmpty {
        return
    }
    destination.withUnsafeMutableBytes { destinationBytes in
        source.withUnsafeBytes { sourceBytes in
            // Safe: the precondition puts offset..<(offset + sourceBytes.count) within destinationBytes, and both
            // buffers only live for this call.
            unsafe UnsafeMutableRawBufferPointer(rebasing: destinationBytes[offset..<(offset + sourceBytes.count)])
                .copyMemory(from: sourceBytes)
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT
