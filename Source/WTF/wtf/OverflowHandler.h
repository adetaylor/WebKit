/*
 * Copyright (C) 2011-2022 Apple Inc. All rights reserved.
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

#include <wtf/Assertions.h>
#include <wtf/OverflowPolicy.h>

#include <stdint.h>

namespace WTF {

// How readily a Checked<> value may be converted back to its underlying integer type, discarding
// the overflow tracking. Widening the policy is a per-handler decision, so that values whose
// provenance makes truncation a security question can be held to a stricter rule than ordinary
// arithmetic helpers.
enum class ImplicitUnwrap : uint8_t {
    // Any implicit conversion to the underlying type, including a narrowing one.
    Always,
    // Only conversions that can represent every value of the underlying type. A narrowing
    // conversion becomes a compile error, so silent truncation has to be written down.
    ValuePreservingOnly,
    // No implicit conversion at all; value() is always required.
    Never,
};

class AssertNoOverflow {
public:
    static constexpr OverflowPolicy policy = OverflowPolicy::AssertNoOverflow;
    static constexpr ImplicitUnwrap implicitUnwrap = ImplicitUnwrap::Always;

    static NO_RETURN_DUE_TO_ASSERT void overflowed()
    {
        ASSERT_NOT_REACHED();
    }

    void clearOverflow() { }

    SUPPRESS_NODELETE static NO_RETURN_DUE_TO_CRASH void NODELETE crash()
    {
        CRASH();
    }

public:
    SUPPRESS_NODELETE constexpr bool NODELETE hasOverflowed() const { return false; }
};

class CrashOnOverflow {
public:
    static constexpr OverflowPolicy policy = OverflowPolicy::CrashOnOverflow;
    static constexpr ImplicitUnwrap implicitUnwrap = ImplicitUnwrap::Always;

    SUPPRESS_NODELETE static NO_RETURN_DUE_TO_CRASH void NODELETE overflowed()
    {
        crash();
    }

    void clearOverflow() { }

    SUPPRESS_NODELETE static NO_RETURN_DUE_TO_CRASH void NODELETE crash()
    {
        CRASH();
    }

public:
    SUPPRESS_NODELETE bool NODELETE hasOverflowed() const { return false; }
};

class RecordOverflow {
protected:
    RecordOverflow()
        : m_overflowed(false)
    {
    }

    void clearOverflow()
    {
        m_overflowed = false;
    }

    SUPPRESS_NODELETE static NO_RETURN_DUE_TO_CRASH void NODELETE crash()
    {
        CRASH();
    }

public:
    static constexpr OverflowPolicy policy = OverflowPolicy::RecordOverflow;
    static constexpr ImplicitUnwrap implicitUnwrap = ImplicitUnwrap::Always;

    SUPPRESS_NODELETE bool NODELETE hasOverflowed() const { return m_overflowed; }
    void overflowed() { m_overflowed = true; }

private:
    unsigned char m_overflowed;
};

// As RecordOverflow, but Checked<> will not implicitly convert back to the underlying integer:
// dropping the overflow tracking requires an explicit value(). Use this for values whose provenance
// makes unchecked arithmetic a security question rather than a style question - notably integers
// decoded from an IPC message - so that every point at which the tracking is discarded is written
// down, and so that arithmetic on the value is checked by construction rather than by review.
class RecordOverflowNoImplicitUnwrap : public RecordOverflow {
public:
    static constexpr ImplicitUnwrap implicitUnwrap = ImplicitUnwrap::Never;
};

// As RecordOverflow, but a narrowing conversion back to a plain integer will not happen silently:
// passing a Checked<uint64_t> to something taking a uint32_t is a compile error rather than a
// truncation to its low 32 bits. Used for integers decoded from an IPC message, where the peer
// chooses the value and 0x100000000 must not quietly become 0.
class RecordOverflowNoNarrowing : public RecordOverflow {
public:
    static constexpr ImplicitUnwrap implicitUnwrap = ImplicitUnwrap::ValuePreservingOnly;
};

} // namespace WTF

using WTF::AssertNoOverflow;
using WTF::CrashOnOverflow;
using WTF::RecordOverflow;
using WTF::RecordOverflowNoImplicitUnwrap;
using WTF::RecordOverflowNoNarrowing;
