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

#include <limits>
#include <memory>
#include <wtf/Borrow.h>
#include <wtf/FastMalloc.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/Noncopyable.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Threading.h>

namespace WTF {

// Lends a C++ object to Swift as a view that no mistake in Swift can use to reach the object once the lend is
// over.
//
// The object must implement the CanBorrow protocol, and is borrowed for as long as it is lent, so CanBorrow
// catches it being destroyed while it is lent. There are two lenders:
//
// - A NonEscapableBorrowLender lends an object for the duration of a call. It must be a stack local of the
//   C++ code that lends the object, and holds a Borrow of it.
// - A NonEscapableBorrowOwningLender owns the object, on the heap, and lends it for the lender's whole life,
//   so that the lender can live anywhere, such as in a value that Swift keeps. It marks the object borrowed
//   when it takes it, crashing if it already is, and unmarks it only as it destroys it. It must be destroyed
//   on the thread that made it. Moving it leaves the object and its views as they were, and the moved-from
//   lender lending nothing.
//
// The view, a subclass of NonEscapableBorrow, reaches the object only through the lender's
// NonEscapableBorrowLease, whose pointer to the object a lender sets after the object's borrow begins and
// clears before it ends. Using the view, or any copy of it, on a thread other than the one that made the
// lender crashes, as does making, copying or destroying one there. The lease counts the views, and ending
// the lend with a view alive crashes, so no view can point to a lease that is gone.
//
// The view is SWIFT_NONESCAPABLE, so Swift rejects most attempts to keep it beyond the lend, and the count
// catches the rest when the lend ends.
// It is copyable because Swift 6.3 leaves Swift functions that take a non-copyable C++ type out of the
// generated C++ header.
//
// To give Swift operations on a type, subclass NonEscapableBorrow, implement them with borrowed(), and
// make the constructor private, with the lenders that may lend the type as friends, so that only they can
// make the view. The constructor's parameter needs LIFETIME_BOUND, without which some Swift compilers
// cannot import a non-escapable type:
//
//     class CounterView : public NonEscapableBorrow<Counter> {
//     public:
//         void increment() { borrowed().increment(); }
//
//     private:
//         friend class NonEscapableBorrowLender<CounterView>;
//         friend class NonEscapableBorrowOwningLender<CounterView>;
//
//         explicit CounterView(NonEscapableBorrowLease<Counter>& lease LIFETIME_BOUND)
//             : NonEscapableBorrow(lease)
//         {
//         }
//     } SWIFT_NONESCAPABLE;
//
// Lend an object to a Swift function that takes `inout CounterView`:
//
//     NonEscapableBorrowLender<CounterView> lender { counter };
//     swiftObject.useCounter(lender.view());
//
// or give one to an owning lender in a type whose LIFETIME_BOUND accessor returns the view, so that Swift
// can use the object for as long as it keeps a value of that type:
//
//     class CounterHolder {
//     public:
//         CounterView counter() const LIFETIME_BOUND { return m_lender.view(); }
//
//     private:
//         NonEscapableBorrowOwningLender<CounterView> m_lender { makeUnique<Counter>() };
//     };

template<typename> class NonEscapableBorrowLease;

template<typename View>
class NonEscapableBorrowLender {
    WTF_MAKE_NONCOPYABLE(NonEscapableBorrowLender);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    using BorrowedType = typename View::BorrowedType;

    explicit NonEscapableBorrowLender(BorrowedType& object LIFETIME_BOUND)
        : m_borrow(object)
        , m_lease(object)
        , m_view(m_lease)
    {
    }

    // The view goes first, then the lease, which crashes if a copy of the view is still alive.
    ~NonEscapableBorrowLender()
    {
        m_lease.end();
    }

    View& view() LIFETIME_BOUND { return m_view; }

private:
    Borrow<BorrowedType> m_borrow;
    NonEscapableBorrowLease<BorrowedType> m_lease;
    View m_view;
};

template<typename View>
class NonEscapableBorrowOwningLender {
    WTF_MAKE_NONCOPYABLE(NonEscapableBorrowOwningLender);
public:
    using BorrowedType = typename View::BorrowedType;

    explicit NonEscapableBorrowOwningLender(std::unique_ptr<BorrowedType>&& object)
        : m_object(borrow(WTF::move(object)))
        , m_lease(makeUnique<NonEscapableBorrowLease<BorrowedType>>(*m_object))
    {
    }

    NonEscapableBorrowOwningLender(NonEscapableBorrowOwningLender&&) = default;

    // Destroying the lease crashes if a view is still alive.
    ~NonEscapableBorrowOwningLender()
    {
        if (!m_object)
            return;
        RELEASE_ASSERT(Thread::currentSingleton().uid() == m_lease->m_threadUID);
        m_lease->end();
        m_object->setIsBorrowed(false);
    }

    View view() const LIFETIME_BOUND
    {
        RELEASE_ASSERT(m_object);
        return View { *m_lease };
    }

private:
    static std::unique_ptr<BorrowedType> borrow(std::unique_ptr<BorrowedType>&& object)
    {
        RELEASE_ASSERT(object);
        bool wasBorrowed = object->setIsBorrowed(true);
        RELEASE_ASSERT(!wasBorrowed);
        return WTF::move(object);
    }

    std::unique_ptr<BorrowedType> m_object;
    // On the heap, so that moving the lender doesn't move what its views point to.
    std::unique_ptr<NonEscapableBorrowLease<BorrowedType>> m_lease;
};

// The lend of an object, which its lender keeps: in itself, on the stack, or on the heap for an owning lender. Its
// views point to it without a reference, and it counts them. Its destructor crashes if a view is still alive, and the
// views are made, copied and destroyed only on the thread that made it, so the count is exact.
template<typename T>
class NonEscapableBorrowLease final {
    WTF_MAKE_NONCOPYABLE(NonEscapableBorrowLease);
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(NonEscapableBorrowLease);
public:
    explicit NonEscapableBorrowLease(T& object)
        : m_object(&object)
        , m_threadUID(Thread::currentSingleton().uid())
    {
    }

    ~NonEscapableBorrowLease()
    {
        RELEASE_ASSERT(!m_viewCount);
    }

    // Not checked for the thread, which views are only made, copied and destroyed on.
    T& get() const
    {
        RELEASE_ASSERT(m_object);
        return *m_object;
    }

private:
    template<typename> friend class NonEscapableBorrowLender;
    template<typename> friend class NonEscapableBorrowOwningLender;
    template<typename> friend class NonEscapableBorrow;

    void end() { m_object = nullptr; }

    void addView()
    {
        RELEASE_ASSERT(Thread::currentSingleton().uid() == m_threadUID);
        RELEASE_ASSERT(m_viewCount < std::numeric_limits<uint32_t>::max());
        ++m_viewCount;
    }

    void removeView()
    {
        RELEASE_ASSERT(Thread::currentSingleton().uid() == m_threadUID);
        --m_viewCount;
    }

    T* m_object;
    const uint32_t m_threadUID;
    uint32_t m_viewCount { 0 };
};

// SWIFT_SAFE: the lease outlives every view that points to it, since destroying it with a view alive crashes, and a
// view is only made, copied and destroyed on the lease's thread, so the count it relies on is exact.
template<typename T>
class NonEscapableBorrow {
public:
    using BorrowedType = T;

    NonEscapableBorrow(const NonEscapableBorrow& other)
        : m_lease(other.m_lease)
    {
        m_lease->addView();
    }

    NonEscapableBorrow& operator=(const NonEscapableBorrow&) = delete;

    ~NonEscapableBorrow()
    {
        m_lease->removeView();
    }

protected:
    explicit NonEscapableBorrow(NonEscapableBorrowLease<T>& lease LIFETIME_BOUND)
        : m_lease(&lease)
    {
        m_lease->addView();
    }

    T& borrowed() const { return m_lease->get(); }

private:
    NonEscapableBorrowLease<T>* const m_lease;
} SWIFT_NONESCAPABLE SWIFT_SAFE;

} // namespace WTF

using WTF::NonEscapableBorrow;
using WTF::NonEscapableBorrowLease;
using WTF::NonEscapableBorrowLender;
using WTF::NonEscapableBorrowOwningLender;
