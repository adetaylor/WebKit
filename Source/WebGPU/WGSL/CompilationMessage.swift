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

/// An error or a warning: its text and where it applies.
public struct CompilationMessage: Hashable, Sendable, Error {
    /// The text as UTF-16 code units: lossless even if a message quotes a lone surrogate from source.
    public let utf16: ContiguousArray<UInt16>
    /// Where the message applies.
    public var span: SourceSpan

    /// Memberwise.
    public init(utf16: ContiguousArray<UInt16>, span: SourceSpan) {
        self.utf16 = utf16
        self.span = span
    }

    /// The UTF-16 code units of `message`.
    public init(_ message: String, span: SourceSpan) {
        self.init(utf16: ContiguousArray(message.utf16), span: span)
    }

    /// A message the compiler built.
    @_spi(Testing)
    public init(text: MessageText, span: SourceSpan) {
        self.init(utf16: text.codeUnits, span: span)
    }

    /// For tests and tools; a lone surrogate decodes as U+FFFD.
    public var message: String { String(decoding: utf16, as: UTF16.self) }

    /// Appends "line:lineOffset: message".
    @_spi(Testing)
    public func dump(_ out: inout MessageText) {
        out.append("\(span.line):\(span.lineOffset): ")
        out.append(MessageText(codeUnits: utf16))
    }

    /// CompilationMessage::dump: "line:lineOffset: message".
    public var dumpDescription: String {
        var text: MessageText = ""
        self.dump(&text)
        return String(decoding: text.codeUnits, as: UTF16.self)
    }
}
