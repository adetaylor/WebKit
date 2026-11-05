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

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <type_traits>
#include <wtf/StdLibExtras.h>

struct ANGLE;

namespace WebCore {

// Memory that C++ lends the WebGL island for the length of one call: the in-process callers' spans, payloads in
// the stream buffer, shared-memory destinations, debug-message text.
//
// A GLLender, which must be a stack local of the lending C++, pushes the span on a thread-local stack and pops it
// when it goes out of scope. The GLLent view it hands to Swift holds only the entry's index and a generation that
// is never reused, so it is a plain value Swift may copy and keep. Swift can't read the memory: only the shims in
// struct ANGLE can, and they reach it through the stack, which crashes unless the view's entry is live, on this
// thread, and of the view's type. So no Swift code can reach the memory once the lend is over.

enum class GLLentKind : uint8_t {
    Bytes = 1,
    MutableBytes,
    Floats,
    MutableFloats,
    Ints,
    MutableInts,
    UnsignedInts,
    MutableUnsignedInts,
    MutableInt64s,
    CStrings,
};

struct GLLend {
    const void* data { nullptr };
    size_t size { 0 };
    uint64_t generation { 0 };
    GLLentKind kind { };
};

template<typename> class GLLender;
template<typename> class GLLent;

class GLLendStack {
private:
    template<typename> friend class GLLender;
    template<typename> friend class GLLent;
    friend struct ::ANGLE;

    struct Entries {
        std::array<GLLend, 16> lends;
        uint32_t depth;
        uint64_t nextGeneration;
        uint64_t generationLimit;
    };

    static uint32_t push(GLLentKind kind, const void* data, size_t size, uint64_t& generation)
    {
        auto& stack = current;
        RELEASE_ASSERT(stack.depth < stack.lends.size());
        if (stack.nextGeneration == stack.generationLimit) [[unlikely]]
            takeGenerationBlock(stack);
        generation = stack.nextGeneration++;
        uint32_t index = stack.depth++;
        stack.lends[index] = { data, size, generation, kind };
        return index;
    }

    static void pop(uint32_t index, uint64_t generation)
    {
        auto& stack = current;
        RELEASE_ASSERT(index + 1 == stack.depth && stack.lends[index].generation == generation);
        stack.lends[index] = { };
        stack.depth = index;
    }

    static GLLend at(GLLentKind kind, uint32_t index, uint64_t generation)
    {
        auto& stack = current;
        RELEASE_ASSERT(index < stack.depth);
        auto& lend = stack.lends[index];
        RELEASE_ASSERT(lend.generation == generation && lend.kind == kind);
        return lend;
    }

    // Each thread takes generations from a block of its own, so a generation names one lend of one thread.
    WEBCORE_EXPORT static void takeGenerationBlock(Entries&);

    WEBCORE_EXPORT static constinit thread_local Entries current;
};

template<typename T> constexpr GLLentKind glLentKind();
template<> constexpr GLLentKind glLentKind<const uint8_t>() { return GLLentKind::Bytes; }
template<> constexpr GLLentKind glLentKind<uint8_t>() { return GLLentKind::MutableBytes; }
template<> constexpr GLLentKind glLentKind<const float>() { return GLLentKind::Floats; }
template<> constexpr GLLentKind glLentKind<float>() { return GLLentKind::MutableFloats; }
template<> constexpr GLLentKind glLentKind<const int32_t>() { return GLLentKind::Ints; }
template<> constexpr GLLentKind glLentKind<int32_t>() { return GLLentKind::MutableInts; }
template<> constexpr GLLentKind glLentKind<const uint32_t>() { return GLLentKind::UnsignedInts; }
template<> constexpr GLLentKind glLentKind<uint32_t>() { return GLLentKind::MutableUnsignedInts; }
template<> constexpr GLLentKind glLentKind<int64_t>() { return GLLentKind::MutableInt64s; }
// The NUL-terminated strings of a list, each lent with its terminator.
template<> constexpr GLLentKind glLentKind<const char* const>() { return GLLentKind::CStrings; }

template<typename T>
class GLLent {
public:
    size_t size() const { return m_size; }
    bool isEmpty() const { return !m_size; }

private:
    template<typename> friend class GLLender;
    friend struct ::ANGLE;

    GLLent(uint64_t generation, uint32_t index, size_t size)
        : m_generation(generation)
        , m_size(size)
        , m_index(index)
    {
    }

    std::span<T> span() const
    {
        auto lend = GLLendStack::at(glLentKind<T>(), m_index, m_generation);
        return unsafeMakeSpan(static_cast<T*>(const_cast<void*>(lend.data)), lend.size);
    }

    uint64_t m_generation;
    size_t m_size;
    uint32_t m_index;
    uint32_t m_unused { 0 };
};

using GLLentBytes = GLLent<const uint8_t>;
using GLLentMutableBytes = GLLent<uint8_t>;
using GLLentFloats = GLLent<const float>;
using GLLentMutableFloats = GLLent<float>;
using GLLentInts = GLLent<const int32_t>;
using GLLentMutableInts = GLLent<int32_t>;
using GLLentUnsignedInts = GLLent<const uint32_t>;
using GLLentMutableUnsignedInts = GLLent<uint32_t>;
using GLLentMutableInt64s = GLLent<int64_t>;
using GLLentCStrings = GLLent<const char* const>;

template<typename T>
class GLLender {
public:
    explicit GLLender(std::span<T> span [[clang::lifetimebound]])
    {
        uint64_t generation = 0;
        auto index = GLLendStack::push(glLentKind<T>(), span.data(), span.size(), generation);
        m_view = { generation, index, span.size() };
    }

    ~GLLender()
    {
        GLLendStack::pop(m_view.m_index, m_view.m_generation);
    }

    GLLender(const GLLender&) = delete;
    GLLender& operator=(const GLLender&) = delete;

    const GLLent<T>& view() const [[clang::lifetimebound]] { return m_view; }

private:
    void* operator new(size_t) = delete;
    void* operator new[](size_t) = delete;

    GLLent<T> m_view { 0, 0, 0 };
};

template<typename T> GLLender(std::span<T>) -> GLLender<T>;

}
