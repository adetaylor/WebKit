/*
 * Copyright (C) 2009-2026 Apple Inc. All rights reserved.
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

#include <JavaScriptCore/YarrErrorCode.h>
#include <JavaScriptCore/YarrFlags.h>
#include <JavaScriptCore/YarrPattern.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

namespace JSC { namespace Yarr {

// A pattern compiled to bytecode, which interpret() runs. The bytecode's layout is YarrInterpreter.swift's.
struct BytecodePattern {
    WTF_MAKE_TZONE_ALLOCATED(BytecodePattern);
public:
    BytecodePattern(Vector<uint32_t>&& bytecode, unsigned offsetsSize)
        : m_bytecode(WTF::move(bytecode))
        , m_offsetsSize(offsetsSize)
    {
    }

    size_t estimatedSizeInBytes() const { return m_bytecode.capacity() * sizeof(uint32_t); }

    const Vector<uint32_t> m_bytecode;
    // The number of entries interpret() writes to its output vector.
    const unsigned m_offsetsSize;
};

JS_EXPORT_PRIVATE std::unique_ptr<BytecodePattern> byteCompile(YarrPattern&, ErrorCode&);
JS_EXPORT_PRIVATE unsigned interpret(BytecodePattern*, StringView input, unsigned start, unsigned* output);
// Frees the storage the bytecode compiler and the interpreter keep between calls.
void releaseSpareStorage();

} } // namespace JSC::Yarr
