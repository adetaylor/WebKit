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

#include <type_traits>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/Lock.h>
#include <wtf/Locker.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakPtr.h>

// Lock holders for Swift: a holder object proves one of its owner's locks is held. Its constructor takes the lock and
// its destructor releases it, and Swift destroys it at the end of the scope that holds it, not after its last use.
// Its members return values only, never a pointer or reference into the guarded state. It cannot be copied, moved or
// made from async Swift. The lock is not recursive: taking a second holder of a lock the thread holds deadlocks.

#if __has_attribute(swift_attr)
#define SCROLLING_LOCK_HOLDER_ATTRIBUTES SWIFT_NONCOPYABLE __attribute__((swift_attr("~Sendable")))
#define SCROLLING_UNAVAILABLE_FROM_ASYNC __attribute__((swift_attr("@_unavailableFromAsync")))
#else
#define SCROLLING_LOCK_HOLDER_ATTRIBUTES
#define SCROLLING_UNAVAILABLE_FROM_ASYNC
#endif

// Body of a holder class for Owner's lock `lockMember`, which guards Owner's `guarded` member (returned by helper()).
// Swift imports a noncopyable class only with a move constructor, so one is declared and traps; the default
// constructor is deleted so Swift gives no zero-filling init().
#define SCROLLING_LOCK_HOLDER(Class, Owner, lockMember, GuardedType, guarded, helper) \
    WTF_MAKE_NONCOPYABLE(Class); \
    WTF_FORBID_HEAP_ALLOCATION; \
public: \
    [[noreturn]] Class(Class&& other) \
        : m_owner(other.m_owner) \
    { \
        RELEASE_ASSERT_NOT_REACHED(); \
    } \
    Class& operator=(Class&&) = delete; \
    Class() = delete; \
    /* The analysis cannot follow a lock held from a constructor to a destructor. */ \
    ~Class() WTF_IGNORES_THREAD_SAFETY_ANALYSIS { (m_owner.get().*(lockMember)).unlock(); } \
private: \
    friend Owner; \
    SCROLLING_UNAVAILABLE_FROM_ASYNC explicit Class(Owner& owner) WTF_IGNORES_THREAD_SAFETY_ANALYSIS \
        : m_owner(owner) \
    { \
        (owner.*(lockMember)).lock(); \
    } \
    /* The lock is held for the holder's life, which the analysis cannot see past a returned reference. */ \
    GuardedType& helper() const WTF_IGNORES_THREAD_SAFETY_ANALYSIS { return m_owner.get().*(guarded); } \
    const Ref<Owner> m_owner

namespace WebCore {

// Holder for a trivially copyable value Owner guards with its own lock: read and written whole, by copy. The lock and
// the value, for each Owner and T, are defined beside Owner, which befriends this template.
template<typename Owner, typename T>
class SCROLLING_LOCK_HOLDER_ATTRIBUTES ScrollingLockedValue {
    static_assert(std::is_trivially_copyable_v<T>);
    static Lock Owner::* const s_lock;
    static T Owner::* const s_value;
    SCROLLING_LOCK_HOLDER(ScrollingLockedValue, Owner, s_lock, T, s_value, value);
public:
    T get() const { return value(); }
    void set(T newValue) const { value() = newValue; }
};

// A reference to a thread-safe reference-counted T that a Swift @Sendable block may capture, for the blocks T
// dispatches to its main run loop or its scrolling thread. It exposes nothing itself: only T, its friend, unwraps it,
// in the members T declares taking a `const MainRunLoopHandle<T>&`. Each such member must be safe on the thread the
// block runs on: it takes its own lock, or the compiler keeps it on its thread (SWIFT_MAIN_ACTOR, entered from the
// block by MainActor.assumeIsolated, which traps off the main thread in every build). A member guarded only by
// ASSERT(isMainThread()) is not one.
template<typename T>
class SWIFT_UNCHECKED_SENDABLE MainRunLoopHandle {
public:
    explicit MainRunLoopHandle(T& object)
        : m_object(object)
    {
        // Checked here, where T is complete: a T whose ref() is not atomic would be counted from two threads.
        static_assert(std::is_base_of_v<WTF::ThreadSafeRefCountedBase, T>
            || requires(T& t) { []<typename U, WTF::DestructionThread thread>(WTF::ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<U, thread>&) { }(t); },
            "T must be thread-safe reference counted");
    }

private:
    friend T;
    T& object() const { return m_object.get(); }

    const Ref<T> m_object;
};

} // namespace WebCore
