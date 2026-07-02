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

#if WTF_SWIFT_CXX_INTEROP

public import Foundation
public import wtf.Core.Vector

@safe
extension WTF.VectorUInt8 {
    // Copies the bytes of any ContiguousBytes into a new Vector<uint8_t>.
    //
    // This is the crypto *output* counterpart to WTF.BorrowedBytes (the input
    // borrow). It is genuinely safe rather than merely encapsulated: the
    // destination Vector is allocated here at exactly the source's byte count
    // and owned by the result, so there is no borrow, lifetime dependency, or
    // aliasing, and copyMemory traps if the counts ever disagree.
    public init(copying bytes: some ContiguousBytes) {
        self = unsafe bytes.withUnsafeBytes { source in
            let result = WTF.VectorUInt8(source.count)
            if source.count > 0 {
                let destination = unsafe UnsafeMutableRawBufferPointer(
                    start: UnsafeMutableRawPointer(mutating: result.span().__dataUnsafe()),
                    count: result.size()
                )
                unsafe destination.copyMemory(from: source)
            }
            return result
        }
    }
}

#endif
