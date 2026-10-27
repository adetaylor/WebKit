/*
 * Copyright (c) 2021-2026 Apple Inc. All rights reserved.
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
#include <span>
#include <wtf/OptionSet.h>
#include <wtf/PrintStream.h>
#include <wtf/StdLibExtras.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Variant.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

// The string and ICU helpers WGSLBridge.swift copies through between WTF and the Swift WGSL compiler.

// Never test HAVE_WGSL_COMPILER in this or any other header Swift imports: CMake does not pass it to Swift's clang importer, so Swift and Objective-C++ would disagree on layouts.

namespace WGSL {

namespace Interop {

// Copy a String's code units into storage Swift lends as a MutableSpan of exactly length() elements.
inline void copyLatin1CodeUnits(const String& string, std::span<uint8_t> destination NOESCAPE) { memcpySpan(destination, byteCast<uint8_t>(string.span8())); }
inline void copyUTF16CodeUnits(const String& string, std::span<char16_t> destination NOESCAPE) { memcpySpan(destination, string.span16()); }

// XID_Start (false) or XID_Continue (true) of the running OS's ICU, as the sorted, disjoint, half-open
// [start, end) scalar ranges the lexer classifies identifiers with, flattened. Defined in ShaderModule.mm,
// so that ICU stays in C++.
using IdentifierRanges = Vector<uint32_t>;
IdentifierRanges icuIdentifierRanges(bool xidContinue);
inline void copyIdentifierRanges(const IdentifierRanges& ranges, std::span<uint32_t> destination NOESCAPE) { memcpySpan(destination, ranges.span()); }

// Swift lends these spans from ContiguousArray storage (ContiguousArray.span back-deploys; Array.span
// needs macOS 26). Each is one copy; ASCII UTF-8 becomes an 8-bit String.
inline String makeStringFromUTF8(std::span<const uint8_t> utf8 NOESCAPE) { return String::fromUTF8(byteCast<char8_t>(utf8)); }
inline String makeStringFromUTF16(std::span<const char16_t> utf16 NOESCAPE) { return String(utf16); }

} // namespace Interop

} // namespace WGSL
