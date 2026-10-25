// Copyright (C) 2022-2026 Apple Inc. All rights reserved.
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

struct SourcePosition: Hashable, Sendable, BitwiseCopyable {
    var line: UInt32
    var lineOffset: UInt32
    var offset: UInt32
}

/// Positions count UTF-16 code units; only "\n" starts a new line.
public struct SourceSpan: Hashable, Sendable, BitwiseCopyable {
    /// The 1-based line of the start.
    public var line: UInt32
    /// The 0-based offset of the start within its line.
    public var lineOffset: UInt32
    /// The 0-based offset of the start.
    public var offset: UInt32
    /// The number of code units.
    public var length: UInt32

    /// The empty span of synthesised nodes.
    public static let empty = SourceSpan(line: 0, lineOffset: 0, offset: 0, length: 0)

    /// Memberwise.
    public init(line: UInt32, lineOffset: UInt32, offset: UInt32, length: UInt32) {
        self.line = line
        self.lineOffset = lineOffset
        self.offset = offset
        self.length = length
    }

    init(_ start: SourcePosition, _ end: SourcePosition) {
        self.init(line: start.line, lineOffset: start.lineOffset, offset: start.offset, length: end.offset &- start.offset)
    }
}
