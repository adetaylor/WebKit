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
public import wtf.Core.BorrowedBytes

// BorrowedBytes exposes borrowed C++ bytes to Foundation/CryptoKit consumers
// with no copy and no `unsafe` at the call sites. The single audited `unsafe` is
// the projection below; it goes through BorrowedBytes.data(), which crashes
// cleanly (rather than reading freed memory) if the borrow has been revoked. The
// conformances are therefore safe to mark @safe: any misuse is a deterministic
// crash, not undefined behavior.

@safe
extension BorrowedBytes: @retroactive ContiguousBytes {
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try unsafe body(UnsafeRawBufferPointer(start: self.data(), count: self.size()))
    }
}

@safe
extension BorrowedBytes: @retroactive RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { self.size() }
    public subscript(position: Int) -> UInt8 {
        unsafe UnsafeRawBufferPointer(start: self.data(), count: self.size())[position]
    }
}

@safe
extension BorrowedBytes: @retroactive DataProtocol {
    public var regions: CollectionOfOne<BorrowedBytes> { CollectionOfOne(self) }
}

#endif
