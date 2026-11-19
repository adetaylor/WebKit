/*
 * Copyright (C) 2015-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <optional>
#include <wtf/Assertions.h>
#include <wtf/Lock.h>
#include <wtf/Ref.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/TypeTraits.h>

namespace WTF {

// RefCountable<T> makes any type reference-counted, including move-only types
// In Swift, you can use cell.pointee.method()
// FIXME: becomes largely unnecessary once rdar://162361370 is fixed in Swift/C++
// interop.
template<typename T>
class RefCountable : public ThreadSafeRefCounted<RefCountable<T>> {
public:
    template<typename... Arguments>
    static Ref<RefCountable> create(Arguments&&... arguments)
    {
        static_assert(!HasRefPtrMemberFunctions<T>, "T should not be RefCounted");
        return adoptRef(*new RefCountable(std::forward<Arguments>(arguments)...));
    }

    RefCountable(T&& value)
        : m_value(WTF::move(value))
    {
    }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const
    {
        ThreadSafeRefCounted<RefCountable<T>>::ref();
    }

    void deref() const
    {
        ThreadSafeRefCounted<RefCountable<T>>::deref();
    }
#endif

    T& operator*() LIFETIME_BOUND
    {
        return m_value;
    }

    const T& operator*() const LIFETIME_BOUND
    {
        return m_value;
    }

private:
    template<typename... Arguments>
    RefCountable(Arguments&&... arguments)
        : m_value(std::forward<Arguments>(arguments)...)
    {
        static_assert(!HasRefPtrMemberFunctions<T>, "T should not be RefCounted");
    }

    T m_value;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A move-only value that C++ hands to Swift, which can't take a move-only C++ type as a parameter of a function that it
// implements with @cxx @implementation. Swift gets the box, a reference type, and takes the value out of it once, as a
// non-copyable value that it can borrow, or move into C++ (a T&& parameter imports with a 'consuming:' label).
template<typename T>
class MoveOnlyBox final : public ThreadSafeRefCounted<MoveOnlyBox<T>> {
public:
    static Ref<MoveOnlyBox> create(T&& value)
    {
        return adoptRef(*new MoveOnlyBox(WTF::move(value)));
    }

#ifdef __swift__
    // As RefCountable does, for the same reason.
    void ref() const
    {
        ThreadSafeRefCounted<MoveOnlyBox<T>>::ref();
    }

    void deref() const
    {
        ThreadSafeRefCounted<MoveOnlyBox<T>>::deref();
    }
#endif

    // The value, which only one caller can take, on any thread.
    T take()
    {
        Locker locker { m_lock };
        RELEASE_ASSERT(m_value);
        return *std::exchange(m_value, std::nullopt);
    }

private:
    explicit MoveOnlyBox(T&& value)
        : m_value(WTF::move(value))
    {
    }

    Lock m_lock;
    std::optional<T> m_value WTF_GUARDED_BY_LOCK(m_lock);
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A move-only parameter of a function that Swift implements with @cxx @implementation: a box of the value, which C++
// callers and IPC dispatch make implicitly from the value they would pass. Copies share the box.
template<typename T>
class MoveOnlyArgument {
public:
    MoveOnlyArgument(T&& value)
        : m_box(MoveOnlyBox<T>::create(WTF::move(value)))
    {
    }

    T take() const { return m_box->take(); }

private:
    Ref<MoveOnlyBox<T>> m_box;
};

// The type that a parameter of type MoveOnlyArgument<T> is made from.
template<typename T> struct RemoveMoveOnlyArgument {
    using Type = T;
};
template<typename T> struct RemoveMoveOnlyArgument<MoveOnlyArgument<T>> {
    using Type = T;
};

} // namespace WTF

using WTF::MoveOnlyArgument;
using WTF::MoveOnlyBox;
