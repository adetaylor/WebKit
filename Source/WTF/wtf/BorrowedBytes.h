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
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>

namespace WTF {

class BorrowedBytesScope;

// BorrowedBytes is a reference-counted, revocable view over a span of bytes
// owned elsewhere (typically a Vector on the C++ stack). It lets Swift borrow
// C++ bytes with no copy while remaining memory safe: the bytes are only
// reachable through data(), which crashes cleanly if the borrow has been
// revoked, rather than reading freed memory.
//
// A BorrowedBytes is always created and revoked by a stack-scoped
// BorrowedBytesScope (below), which revokes it when the synchronous call that
// created it returns. Because the control block is reference counted, a view
// that outlives its scope (e.g. accidentally stashed on the Swift side) keeps
// the block alive — so the validity check itself never faults — but every
// subsequent access observes the revoked flag and crashes cleanly.
//
// This is a heap-allocatable, reference-counted, revocable cousin of Borrow.
// It catches the "view stashed and used after the borrow ends" mistake at
// runtime. It does not, on its own, catch destruction or mutation of the
// underlying buffer *during* the borrow on another thread; that is the
// concurrent-mutation case that CanBorrow is intended to cover, and which this
// type could additionally register with once WTF::Vector adopts it.
class BorrowedBytes : public ThreadSafeRefCounted<BorrowedBytes> {
public:
    // Returns the borrowed data pointer, crashing cleanly if the borrow has
    // already been revoked. SWIFT_RETURNS_INDEPENDENT_VALUE keeps this callable
    // from Swift; it is only ever called inside an audited withUnsafeBytes
    // conformance, where the returned pointer is used synchronously.
    const uint8_t* data() const SWIFT_RETURNS_INDEPENDENT_VALUE
    {
        RELEASE_ASSERT(m_valid.load(std::memory_order_acquire));
        return m_data;
    }

    size_t size() const { return m_size; }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy (see WTF::RefCountable).
    void ref() const { ThreadSafeRefCounted<BorrowedBytes>::ref(); }
    void deref() const { ThreadSafeRefCounted<BorrowedBytes>::deref(); }
#endif

private:
    friend class BorrowedBytesScope;

    static Ref<BorrowedBytes> create(std::span<const uint8_t> bytes)
    {
        return adoptRef(*new BorrowedBytes(bytes));
    }

    explicit BorrowedBytes(std::span<const uint8_t> bytes)
        : m_data(bytes.data())
        , m_size(bytes.size())
    {
    }

    void revoke() { m_valid.store(false, std::memory_order_release); }

    const uint8_t* m_data;
    size_t m_size;
    std::atomic<bool> m_valid { true };
} SWIFT_SHARED_REFERENCE(.ref, .deref);

// Stack-scoped owner of a BorrowedBytes. Constructing one begins a borrow of
// `bytes`; destroying it revokes the borrow. This is the only way to create a
// BorrowedBytes, so a view can never be handed to Swift without a scope that
// will revoke it. Keep the scope alive for the whole synchronous call that
// uses the view.
class BorrowedBytesScope {
    WTF_MAKE_NONCOPYABLE(BorrowedBytesScope);
public:
    explicit BorrowedBytesScope(std::span<const uint8_t> bytes)
        : m_bytes(BorrowedBytes::create(bytes))
    {
    }

    ~BorrowedBytesScope() { m_bytes->revoke(); }

    BorrowedBytes& bytes() LIFETIME_BOUND { return m_bytes.get(); }

private:
    Ref<BorrowedBytes> m_bytes;
};

} // namespace WTF

using WTF::BorrowedBytes;
using WTF::BorrowedBytesScope;
