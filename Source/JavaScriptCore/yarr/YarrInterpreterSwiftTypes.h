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

#include <bit>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace JSC::Yarr {

// The words of a YarrPattern that the bytecode compiler in YarrInterpreter.swift reads.
using YarrPatternWords = std::span<const uint32_t>;
// The bytecode compiler's result is allocated with fastMalloc: the system allocator keeps the pages of freed blocks of
// this size.
void* yarrFastMalloc(size_t);
void yarrFastFree(void*);
template<typename T> struct YarrFastAllocator {
    using value_type = T;
    YarrFastAllocator() = default;
    template<typename U> YarrFastAllocator(const YarrFastAllocator<U>&) { }
    T* allocate(size_t count) { return static_cast<T*>(yarrFastMalloc(count * sizeof(T))); }
    void deallocate(T* pointer, size_t) { yarrFastFree(pointer); }
    friend bool operator==(const YarrFastAllocator&, const YarrFastAllocator&) { return true; }
};
// What the bytecode compiler returns: an ErrorCode, the dump's text, then the bytecode.
using YarrCompiledWords = std::vector<uint32_t, YarrFastAllocator<uint32_t>>;
// A BytecodePattern's bytecode.
using YarrBytecodeWords = std::span<const uint32_t>;
using YarrSubject8 = std::span<const uint8_t>;
using YarrSubject16 = std::span<const char16_t>;
using YarrOutput = std::span<unsigned>;

// The lowest stack address at which the current thread may still recurse (WTF::StackCheck's limit).
uintptr_t yarrStackLimit();
// The stack check matchDisjunction makes on every call, inline so that it is a compare in the caller: the caller's
// frame address against the limit yarrStackLimit() computed once per match. The frame address is above the stack
// pointer, by at most the caller's frame, which the reserved zone below the limit holds.
inline bool yarrIsSafeToRecurse(uintptr_t stackLimit)
{
    return std::bit_cast<uintptr_t>(__builtin_frame_address(0)) >= stackLimit;
}
bool yarrAreCanonicallyEquivalent(uint32_t, uint32_t, bool unicode);

} // namespace JSC::Yarr
