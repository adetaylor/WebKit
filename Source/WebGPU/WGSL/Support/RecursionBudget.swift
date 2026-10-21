// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
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

// The depth limits of the C++. Each budget is `~Copyable`, so a pass cannot copy it to reset or replay its
// count, and only its `enter` mints the `Level` that its `leave` restores. Use each as a `SetForScope` at the same
// place as the C++:
//
//     let parseDepthLevel = try parseDepth.enter(SourceSpan(startOfElementPosition, currentPosition))
//     defer { parseDepth.leave(parseDepthLevel) }

/// CHECK_RECURSION (Parser.cpp:134-137), shared by statements, else-if chains, unary expressions, left-hand sides and
/// argument lists.
@_spi(Testing)
public struct ParseDepth: ~Copyable {
    /// Minted only by `ParseDepth.enter`.
    @_spi(Testing)
    public struct Level: ~Copyable {
        fileprivate let previous: UInt32
    }

    @_spi(Testing)
    public static let limit: UInt32 = 128

    @_spi(Testing)
    public private(set) var depth: UInt32 = 0

    @_spi(Testing)
    public init() {}

    /// `SetForScope(m_parseDepth, m_parseDepth + 1)`.
    ///
    /// Throws the C++ `FAIL` if the new depth would be above the limit, with `span` = `CURRENT_SOURCE_SPAN()`, and
    /// then leaves the depth unchanged.
    @_spi(Testing)
    public mutating func enter(_ span: SourceSpan) throws(CompilationMessage) -> Level {
        guard depth < Self.limit else {
            throw Self.limitError(at: span)
        }
        let level = Level(previous: depth)
        depth += 1
        return level
    }

    @_spi(Testing)
    public mutating func leave(_ level: borrowing Level) {
        depth = level.previous
    }

    @_spi(Testing)
    public static func limitError(at span: SourceSpan) -> CompilationMessage {
        CompilationMessage("maximum parser recursive depth reached", span: span)
    }
}

// https://www.w3.org/TR/WGSL/#limits
// Entered once for each type that has another type nested inside it. A leaf type such as `u32` is
// not itself a level of nesting, so `array<u32, 1>` is nested one level deep, not two.
/// CHECK_COMPOSITE_TYPE_NESTING (Parser.cpp:142-147).
@_spi(Testing)
public struct CompositeTypeNesting: ~Copyable {
    /// Minted only by `CompositeTypeNesting.enter`.
    @_spi(Testing)
    public struct Level: ~Copyable {
        fileprivate let previous: UInt32
    }

    @_spi(Testing)
    public static let limit: UInt32 = 15

    @_spi(Testing)
    public private(set) var depth: UInt32 = 0

    @_spi(Testing)
    public init() {}

    /// `SetForScope(m_compositeTypeDepth, m_compositeTypeDepth + 1)`.
    ///
    /// Throws the C++ `FAIL` if the new depth would be above the limit, with `span` = `CURRENT_SOURCE_SPAN()`, and
    /// then leaves the depth unchanged.
    @_spi(Testing)
    public mutating func enter(_ span: SourceSpan) throws(CompilationMessage) -> Level {
        guard depth < Self.limit else {
            throw Self.limitError(at: span)
        }
        let level = Level(previous: depth)
        depth += 1
        return level
    }

    @_spi(Testing)
    public mutating func leave(_ level: borrowing Level) {
        depth = level.previous
    }

    @_spi(Testing)
    public static func limitError(at span: SourceSpan) -> CompilationMessage {
        CompilationMessage("composite type may not be nested more than 15 levels", span: span)
    }
}

/// GraphBuilder's expression depth (GlobalSorting.cpp:180, 230-236).
@_spi(Testing)
public struct GlobalSortingExpressionDepth: ~Copyable {
    /// Minted only by `GlobalSortingExpressionDepth.enter`.
    @_spi(Testing)
    public struct Level: ~Copyable {
        fileprivate let previous: UInt32
    }

    @_spi(Testing)
    public static let limit: UInt32 = 512

    @_spi(Testing)
    public private(set) var depth: UInt32 = 0

    @_spi(Testing)
    public init() {}

    /// `SetForScope(m_expressionDepth, m_expressionDepth + 1)`.
    ///
    /// Nil if the new depth would be above the limit, where the C++ does `setError(limitError(at: expression.span()))`
    /// and returns; the depth is then unchanged.
    @_spi(Testing)
    public mutating func enter() -> Level? {
        guard depth < Self.limit else {
            return nil
        }
        let level = Level(previous: depth)
        depth += 1
        return level
    }

    @_spi(Testing)
    public mutating func leave(_ level: borrowing Level) {
        depth = level.previous
    }

    @_spi(Testing)
    public static func limitError(at span: SourceSpan) -> CompilationMessage {
        CompilationMessage("reached maximum expression depth of 512", span: span)
    }
}
