// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
//
// Copyright (c) 2023-2026 Apple Inc. All rights reserved.
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

/// C++ `ContextProvider<T>`.
///
/// C++ chains one `HashMap<String, T>` per scope. Here every symbol has a stack of bindings: a lookup is one array
/// index, a scope costs nothing to open, and nothing is hashed or iterated. Same semantics: `introduceVariable` fails
/// on a redeclaration in the current scope, `readVariable` finds the innermost binding.
@_spi(Testing)
public struct ContextProvider<Value> {
    private struct Entry {
        var value: Value
        var previous: Int32
        var symbol: Symbol
        var depth: UInt32
    }

    // heads[i] is the innermost binding of the symbol with index headsBase + i, or -1.
    private var heads: [Int32] = []
    private var headsBase = 0
    private var entries: [Entry] = []
    // C++ m_globalScope is scope 1.
    private var scopeDepth = 1

    /// C++ `ContextScope` (RAII in C++): opened by `openScope`, closed by `closeScope` in LIFO order, in a `defer`.
    @_spi(Testing)
    public struct Scope {
        fileprivate let depth: Int
        fileprivate let entryCount: Int
    }

    private static var initialEntryCapacity: Int { 32 }

    @_spi(Testing)
    public init() {}

    @_spi(Testing)
    public var depth: Int { scopeDepth }

    @_spi(Testing)
    public mutating func openScope() -> Scope {
        scopeDepth += 1
        return Scope(depth: scopeDepth, entryCount: entries.count)
    }

    @_spi(Testing)
    public mutating func closeScope(_ scope: Scope) {
        guard scope.depth == scopeDepth else {
            wgslFatal("ContextScopes must be closed in LIFO order", cppSite: "ContextProviderInlines.h:72")
        }
        if entries.count > scope.entryCount {
            var index = entries.count - 1
            while index >= scope.entryCount {
                heads[entries[index].symbol.index - headsBase] = entries[index].previous
                index -= 1
            }
            entries.removeSubrange(scope.entryCount...)
        }
        scopeDepth -= 1
    }

    /// Returns nil when `symbol` is already declared in the current scope (C++ returns nullptr).
    @_spi(Testing)
    @discardableResult
    public mutating func introduceVariable(_ symbol: Symbol, _ value: Value) -> Value? {
        if heads.isEmpty {
            headsBase = symbol.index
        }
        if symbol.index < headsBase || symbol.index - headsBase >= heads.count {
            growHeads(toCover: symbol.index)
        }
        let head = heads[symbol.index - headsBase]
        let currentDepth = UInt32(truncatingIfNeeded: scopeDepth)
        if head >= 0 && entries[Int(head)].depth == currentDepth {
            return nil
        }
        if entries.capacity == 0 {
            entries.reserveCapacity(Self.initialEntryCapacity)
        }
        entries.append(Entry(value: value, previous: head, symbol: symbol, depth: currentDepth))
        heads[symbol.index - headsBase] = Int32(entries.count - 1)
        return value
    }

    @_spi(Testing)
    public func readVariable(_ symbol: Symbol) -> Value? {
        let index = symbol.index - headsBase
        guard index >= 0 && index < heads.count else {
            return nil
        }
        let head = heads[index]
        return head >= 0 ? entries[Int(head)].value : nil
    }

    // Symbols are introduced in roughly increasing order (a module's own symbols follow the predeclared ones): heads covers
    // the introduced range and grows geometrically.
    private mutating func growHeads(toCover index: Int) {
        if index < headsBase {
            let added = headsBase - index > heads.count ? headsBase - index : heads.count
            let newBase = headsBase - added > 0 ? headsBase - added : 0
            heads.insert(contentsOf: repeatElement(-1, count: headsBase - newBase), at: 0)
            headsBase = newBase
        } else {
            let needed = index - headsBase + 1
            let newCount = Swift.max(needed, 2 * heads.count, 32)
            heads.append(contentsOf: repeatElement(-1, count: newCount - heads.count))
        }
    }
}
