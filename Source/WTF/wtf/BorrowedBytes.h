/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <atomic>
#include <cstdint>
#include <span>
#include <wtf/Assertions.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/Ref.h>
#include <wtf/StdLibExtras.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>

#if !defined(__swift__)
#include <wtf/Borrow.h>
#endif

namespace WTF {

class BorrowedBytesScopeBase;
class NonEscapableBytes;
class NonEscapableMutableBytes;

// Common byte-buffer specialization, also named so it can be referenced from Swift.
using VectorUInt8 = Vector<uint8_t>;

// This file holds WTF's byte views for Swift interop. Choosing between them:
//
//   - BorrowedBytes / BorrowedMutableBytes are reference counted and revocable, so
//     Swift may hold one. Use them when Swift needs to keep the bytes, or to hand
//     them to a Swift API that requires an escapable type (CryptoKit). They cost a
//     control block plus a validity check on every access, and misuse -- using a
//     view whose borrow has ended -- is a clean crash.
//   - NonEscapableBytes / NonEscapableMutableBytes are ~Escapable, so Swift can only
//     inspect them, narrow them, ask C++ to copy between them, and hand them straight
//     back within the same call. They cost nothing at runtime and misuse is a compile
//     error instead of a crash, so prefer them whenever a pass-through is all you need.
//
// BorrowedBytes is a reference-counted, revocable view over a span of bytes
// owned elsewhere (typically a Vector on the C++ stack). It lets Swift borrow
// C++ bytes with no copy while remaining memory safe: the bytes are only
// reachable through data()/span(), which crash cleanly if the borrow has been
// revoked, rather than reading freed memory.
//
// A BorrowedBytes is always created and revoked by a stack-scoped scope object
// (BorrowedSpanScope / BorrowedVectorScope, below), which revokes it when the
// synchronous call that created it returns. Because the control block is
// reference counted, a view that outlives its scope (e.g. accidentally stashed
// on the Swift side) keeps the block alive — so the validity check itself never
// faults — but every subsequent access observes the revoked flag and crashes
// cleanly.
//
// This is, in effect, the Swift-crossable form of Borrow. It composes two
// protections against two distinct failure modes:
//
//   - "buffer mutated/destroyed *during* the borrow": this is exactly what
//     Borrow guards, and BorrowedVectorScope gets it by holding a Borrow on the
//     underlying Vector (engaging its CanBorrow protocol). BorrowedSpanScope
//     has no owning container, so it cannot offer this.
//   - "view stashed and used *after* the borrow ends": Borrow does not guard
//     this because C++ cannot easily stash a stack-only, noncopyable Borrow.
//     Swift can stash a shared reference, so the revocable control block adds a
//     runtime backstop for it. This half is the only part that is novel
//     relative to Borrow, and its entire value is at the Swift boundary.
//
// A C++ caller with a Vector should just use Borrow + span() directly and pay none
// of the refcount/revocation overhead. BorrowedBytes exists to carry a borrow across
// the C++/Swift boundary.
class BorrowedBytes : public ThreadSafeRefCounted<BorrowedBytes> {
public:
    // Returns the borrowed data pointer, crashing cleanly if the borrow has
    // already been revoked. SWIFT_RETURNS_INDEPENDENT_VALUE keeps this callable
    // from Swift; it is only ever called inside an audited withUnsafeBytes
    // conformance, where the returned pointer is used synchronously.
    const uint8_t* data() const SWIFT_RETURNS_INDEPENDENT_VALUE {
        RELEASE_ASSERT(m_valid.load(std::memory_order_acquire));
        return m_span.data();
    }

    size_t size() const { return m_span.size(); }

#if !defined(__swift__)
    std::span<const uint8_t> span() const LIFETIME_BOUND
    {
        RELEASE_ASSERT(m_valid.load(std::memory_order_acquire));
        return m_span;
    }
#endif

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy (see WTF::RefCountable).
    void ref() const { ThreadSafeRefCounted<BorrowedBytes>::ref(); }
    void deref() const { ThreadSafeRefCounted<BorrowedBytes>::deref(); }
#endif

private:
    friend class BorrowedBytesScopeBase;
    friend class NonEscapableMutableBytes;

    static Ref<BorrowedBytes> create(std::span<const uint8_t> bytes)
    {
        return adoptRef(*new BorrowedBytes(bytes));
    }

    explicit BorrowedBytes(std::span<const uint8_t> bytes)
        : m_span(bytes)
    {
    }

    void revoke() { m_valid.store(false, std::memory_order_release); }

    std::span<const uint8_t> m_span;
    std::atomic<bool> m_valid { true };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

// The mutable counterpart of BorrowedBytes: a revocable, Swift-crossable view over
// bytes the borrower may write through as well as read. At present, there are no
// facilities for Swift to actually access the bytes - the intended use is that
// this is manipulated in Swift but then C++ uses span() to get to the resulting
// bytes.
class BorrowedMutableBytes : public ThreadSafeRefCounted<BorrowedMutableBytes> {
public:
    size_t size() const { return m_span.size(); }

    // Overwrites these bytes with `source`, which must be exactly the same length.
    // See the note on the copy operations below.
    void copyFrom(const NonEscapableBytes& source) const;
    void copyFrom(const BorrowedBytes& source) const;

#if !defined(__swift__)
    std::span<uint8_t> span() const LIFETIME_BOUND
    {
        RELEASE_ASSERT(m_valid.load(std::memory_order_acquire));
        return m_span;
    }
#endif

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy (see WTF::RefCountable).
    void ref() const { ThreadSafeRefCounted<BorrowedMutableBytes>::ref(); }
    void deref() const { ThreadSafeRefCounted<BorrowedMutableBytes>::deref(); }
#endif

private:
    friend class BorrowedMutableSpanScope;

    static Ref<BorrowedMutableBytes> create(std::span<uint8_t> bytes)
    {
        return adoptRef(*new BorrowedMutableBytes(bytes));
    }

    explicit BorrowedMutableBytes(std::span<uint8_t> bytes)
        : m_span(bytes)
    {
    }

    void revoke() { m_valid.store(false, std::memory_order_release); }

    std::span<uint8_t> m_span;
    std::atomic<bool> m_valid { true };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

// A view of bytes that Swift can hold and hand back to C++
// without ever naming a pointer or writing `unsafe`.
class SWIFT_NONESCAPABLE NonEscapableBytes {
public:
    NonEscapableBytes() = default;

    size_t size() const { return m_span.size(); }
    bool isEmpty() const { return m_span.empty(); }

    // LIFETIME_BOUND is what lets Swift tie the result's lifetime to this view.
    NonEscapableBytes subspan(size_t offset, size_t count) const LIFETIME_BOUND
    {
        RELEASE_ASSERT(offset <= m_span.size() && count <= m_span.size() - offset);
        return NonEscapableBytes(m_span.subspan(offset, count));
    }

#if !defined(__swift__)
    static NonEscapableBytes create(std::span<const uint8_t> bytes LIFETIME_BOUND)
    {
        return NonEscapableBytes(bytes);
    }
#endif

private:
    // NonEscapableMutableBytes::copyFrom() reads m_span directly: its body is compiled
    // by Swift's importer too, so it cannot call anything hidden behind __swift__.
    friend class NonEscapableMutableBytes;

    explicit NonEscapableBytes(std::span<const uint8_t> bytes LIFETIME_BOUND)
        : m_span(bytes)
    {
    }

    std::span<const uint8_t> m_span;
};

// A view of mutable bytes that Swift can hold, narrow, and hand back to C++
// without ever naming a pointer or writing `unsafe`. C++ turns it back into a
// std::span at the boundary.
//
// Being ~Escapable, this needs neither a reference count nor a revocation flag:
// Swift's lifetime checker rejects any attempt to store the view or let it outlive
// the call it arrived in, so there is nothing to revoke. See the note above the
// BorrowedBytes family for when to prefer which.
//
// That guarantee covers the Swift side only. C++ can copy one of these into a
// member or a static and outlive the bytes, exactly as it can with a bare
// std::span, so the C++ half of a round trip still needs the usual care.
class SWIFT_NONESCAPABLE NonEscapableMutableBytes {
public:
    NonEscapableMutableBytes() = default;

    size_t size() const { return m_span.size(); }
    bool isEmpty() const { return m_span.empty(); }

    // LIFETIME_BOUND is what lets Swift tie the result's lifetime to this view.
    NonEscapableMutableBytes subspan(size_t offset, size_t count) const LIFETIME_BOUND
    {
        RELEASE_ASSERT(offset <= m_span.size() && count <= m_span.size() - offset);
        return NonEscapableMutableBytes(m_span.subspan(offset, count));
    }

    // Overwrites these bytes with `source`, which must be exactly the same length --
    // narrow with subspan() first. See the note on the copy operations below.
    void copyFrom(const NonEscapableBytes& source) const;
    void copyFrom(const BorrowedBytes& source) const;

#if !defined(__swift__)
    static NonEscapableMutableBytes create(std::span<uint8_t> bytes LIFETIME_BOUND)
    {
        return NonEscapableMutableBytes(bytes);
    }

    // Unwraps a view that a call into Swift has just returned.
    //
    // The result is deliberately not LIFETIME_BOUND. The bytes live in storage this
    // view does not own, so binding them to this (usually temporary) view would make
    // clang report a false dangling reference at every legitimate call site. That
    // makes the following the caller's responsibility, unchecked by the compiler:
    //
    //   1. The bytes must be ones the caller itself lent to Swift via create().
    //   2. Whatever owns that storage must outlive every use of the returned span,
    //      including any use by the caller's own caller.
    //   3. Because of (2), think before storing the result.
    std::span<uint8_t> span() const { return m_span; }
#endif

private:
    // So that BorrowedMutableBytes::copyFrom() can wrap its own bytes and delegate.
    friend class BorrowedMutableBytes;

    explicit NonEscapableMutableBytes(std::span<uint8_t> bytes LIFETIME_BOUND)
        : m_span(bytes)
    {
    }

    std::span<uint8_t> m_span;
};

// The copy operations across the four views above, in one place because each source
// and destination combination is otherwise a place to get the checks wrong.
//
// NonEscapableMutableBytes::copyFrom(const NonEscapableBytes&) is the primitive: it
// checks the lengths and does the move. The other three check their own revocation
// flag, wrap their bytes, and delegate, so the length check and the move exist once.
//
// Two details that look like fussiness but are not. Sources are taken by reference
// because a ~Escapable parameter passed by value makes Swift import the whole method
// as unsafe. And these are defined out of line because Swift's importer compiles the
// bodies of Swift-visible methods too, so a body may only touch members and types
// that are complete and unguarded at that point -- which none of them are inside the
// class definitions.

inline void NonEscapableMutableBytes::copyFrom(const NonEscapableBytes& source) const
{
    RELEASE_ASSERT(source.m_span.size() == m_span.size());
    if (m_span.empty())
        return;
    // memmoveSpan rather than memcpySpan because nothing here can prove that a C++
    // caller did not hand over two views onto the same buffer. Swift cannot arrange
    // that overlap: it has no way to turn a mutable view into an immutable one.
    memmoveSpan(m_span, source.m_span);
}

inline void NonEscapableMutableBytes::copyFrom(const BorrowedBytes& source) const
{
    RELEASE_ASSERT(source.m_valid.load(std::memory_order_acquire));
    copyFrom(NonEscapableBytes(source.m_span));
}

inline void BorrowedMutableBytes::copyFrom(const NonEscapableBytes& source) const
{
    RELEASE_ASSERT(m_valid.load(std::memory_order_acquire));
    NonEscapableMutableBytes(m_span).copyFrom(source);
}

inline void BorrowedMutableBytes::copyFrom(const BorrowedBytes& source) const
{
    RELEASE_ASSERT(m_valid.load(std::memory_order_acquire));
    NonEscapableMutableBytes(m_span).copyFrom(source);
}

#if !defined(__swift__)
class BorrowedBytesScopeBase {
    WTF_MAKE_NONCOPYABLE(BorrowedBytesScopeBase);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    BorrowedBytes& bytes() LIFETIME_BOUND { return m_bytes.get(); }

protected:
    explicit BorrowedBytesScopeBase(std::span<const uint8_t> bytes)
        : m_bytes(BorrowedBytes::create(bytes))
    {
    }

    ~BorrowedBytesScopeBase()
    {
        // The borrow ends here. If anything on the Swift side stashed the view
        // beyond the synchronous call, the control block still carries an
        // external reference at this point. Assert now, at the site that ends
        // the borrow, so a stash bug crashes with a stack pointing at the
        // premature end of the borrow rather than at some later, innocent
        // reader. This is a debug-only ASSERT — in release the backstop is
        // data()'s RELEASE_ASSERT(m_valid), which catches the same mistake at
        // access time (once revoke() below has run) rather than here.
        ASSERT(m_bytes->hasOneRef());
        m_bytes->revoke();
    }

private:
    Ref<BorrowedBytes> m_bytes;
};

// Borrows a bare span. Safe only because it is stack-scoped inside a synchronous
// call; it has no owning container to enforce the borrow at runtime, so it must
// never be heap-allocated or outlive its buffer.
class BorrowedSpanScope final : public BorrowedBytesScopeBase {
public:
    explicit BorrowedSpanScope(std::span<const uint8_t> bytes LIFETIME_BOUND)
        : BorrowedBytesScopeBase(bytes)
    {
    }
};

// Borrows a whole Vector and engages its CanBorrow protocol, so a reallocating
// mutation or destruction of the Vector while the borrow is live crashes rather
// than leaving the view dangling. Prefer this whenever a Vector is available.
class BorrowedVectorScope final : public BorrowedBytesScopeBase {
public:
    explicit BorrowedVectorScope(const VectorUInt8& vector LIFETIME_BOUND)
        : BorrowedBytesScopeBase(vector.span())
        , m_borrow(vector)
    {
    }

private:
    Borrow<const VectorUInt8> m_borrow;
};

// The mutable counterpart of BorrowedSpanScope. Same caveat: it has no owning
// container, so it is safe only because it is stack-scoped inside a synchronous
// call, and must never be heap-allocated or outlive its buffer.
class BorrowedMutableSpanScope final {
    WTF_MAKE_NONCOPYABLE(BorrowedMutableSpanScope);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit BorrowedMutableSpanScope(std::span<uint8_t> bytes LIFETIME_BOUND)
        : m_bytes(BorrowedMutableBytes::create(bytes))
    {
    }

    ~BorrowedMutableSpanScope()
    {
        // See the note in BorrowedBytesScopeBase's destructor: assert at the site
        // that ends the borrow, so a Swift-side stash bug points here rather than
        // at some later, innocent reader. In release, span()'s
        // RELEASE_ASSERT(m_valid) is the backstop.
        ASSERT(m_bytes->hasOneRef());
        m_bytes->revoke();
    }

    BorrowedMutableBytes& bytes() LIFETIME_BOUND { return m_bytes.get(); }

private:
    Ref<BorrowedMutableBytes> m_bytes;
};
#endif

} // namespace WTF

using WTF::BorrowedBytes;
using WTF::BorrowedMutableBytes;
using WTF::NonEscapableBytes;
using WTF::NonEscapableMutableBytes;
#if !defined(__swift__)
using WTF::BorrowedMutableSpanScope;
using WTF::BorrowedSpanScope;
using WTF::BorrowedVectorScope;
#endif
