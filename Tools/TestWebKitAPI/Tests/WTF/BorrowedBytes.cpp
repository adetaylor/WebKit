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

#include "config.h"
#include <wtf/BorrowedBytes.h>

#include "Helpers/Test.h"
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>

// These tests exercise the C++ side of BorrowedBytes: the scope types, the revocable
// views they hand out, and the ~Escapable views used for pass-through to Swift. The
// Swift-side guarantees (that a view cannot be stored or outlive its call) are enforced
// by the compiler and so are not testable from here.

namespace TestWebKitAPI {

TEST(WTF_BorrowedBytes, SpanScopeExposesBytes)
{
    Vector<uint8_t> source { 10, 20, 30, 40, 50 };
    auto span = source.span();
    BorrowedSpanScope scope(span);

    auto& bytes = scope.bytes();
    EXPECT_EQ(bytes.size(), span.size());
    EXPECT_EQ(bytes.data(), span.data());
    EXPECT_EQ(bytes.span().data(), span.data());
    EXPECT_EQ(bytes.span().size(), span.size());
    for (size_t i = 0; i < span.size(); ++i)
        EXPECT_EQ(bytes.data()[i], span[i]);
}

// The real reason BorrowedSpanScope exists: borrowing a partial view into a
// buffer, which has no whole-container to register a Borrow with. Mirrors
// PlatformECKey::importCompressedPub.
TEST(WTF_BorrowedBytes, SpanScopeOverSubspan)
{
    Vector<uint8_t> source { 0, 1, 2, 3, 4, 5 };
    auto subspan = source.span().subspan(2, 3);
    BorrowedSpanScope scope(subspan);

    EXPECT_EQ(scope.bytes().size(), 3u);
    EXPECT_EQ(scope.bytes().data(), subspan.data());
    EXPECT_EQ(scope.bytes().data()[0], 2u);
    EXPECT_EQ(scope.bytes().data()[2], 4u);
}

TEST(WTF_BorrowedBytes, VectorScopeExposesBytes)
{
    Vector<uint8_t> vector { 1, 2, 3, 4 };
    BorrowedVectorScope scope(vector);

    auto& bytes = scope.bytes();
    EXPECT_EQ(bytes.size(), vector.size());
    EXPECT_EQ(bytes.data(), vector.span().data());
    for (size_t i = 0; i < vector.size(); ++i)
        EXPECT_EQ(bytes.data()[i], vector[i]);
}

TEST(WTF_BorrowedBytes, EmptySpan)
{
    BorrowedSpanScope scope(std::span<const uint8_t> { });
    EXPECT_EQ(scope.bytes().size(), 0u);
}

TEST(WTF_BorrowedBytes, EmptyVector)
{
    Vector<uint8_t> vector;
    BorrowedVectorScope scope(vector);
    EXPECT_EQ(scope.bytes().size(), 0u);
}

// While the borrow is live and un-stashed, the scope holds the only reference.
// A transient reference (as Swift takes for the duration of a synchronous call)
// is fine as long as it is released before the scope ends.
TEST(WTF_BorrowedBytes, ScopeHoldsSoleReference)
{
    Vector<uint8_t> vector { 1, 2, 3 };
    BorrowedVectorScope scope(vector);
    EXPECT_TRUE(scope.bytes().hasOneRef());
    {
        RefPtr<BorrowedBytes> transient = &scope.bytes();
        EXPECT_FALSE(scope.bytes().hasOneRef());
        EXPECT_EQ(transient->size(), vector.size());
    }
    EXPECT_TRUE(scope.bytes().hasOneRef());
}

// Nested borrows of the same Vector are permitted; the inner borrow restores
// the outer borrow's state on destruction.
TEST(WTF_BorrowedBytes, NestedVectorScopes)
{
    Vector<uint8_t> vector { 9, 8, 7 };
    BorrowedVectorScope outer(vector);
    {
        BorrowedVectorScope inner(vector);
        EXPECT_EQ(inner.bytes().data(), vector.span().data());
    }
    EXPECT_EQ(outer.bytes().size(), vector.size());
}

// A view stashed beyond the scope's lifetime is caught at scope destruction,
// where the crash stack points at the too-early end of the borrow rather than
// later at an innocent reader. This is a debug-only ASSERT (in release the
// backstop is data()'s RELEASE_ASSERT at access time), so the death test only
// runs when assertions are enabled.
TEST(WTF_BorrowedBytesDeathTest, MAYBE_ASSERT_ENABLED_DEATH_TEST(StashedViewCrashesAtScopeEnd))
{
    auto shouldCrash = [] {
        RefPtr<BorrowedBytes> stashed;
        {
            Vector<uint8_t> vector { 1, 2, 3 };
            BorrowedVectorScope scope(vector);
            stashed = &scope.bytes();
            // ~BorrowedVectorScope asserts here: `stashed` still holds a
            // reference, so the borrow is ending too early.
        }
    };
    ASSERT_DEATH_IF_SUPPORTED(shouldCrash(), "");
}

// MARK: - BorrowedMutableBytes

TEST(WTF_BorrowedBytes, MutableSpanScopeExposesWritableBytes)
{
    std::array<uint8_t, 4> buffer { 1, 2, 3, 4 };
    std::span<uint8_t> span { buffer };
    BorrowedMutableSpanScope scope(span);

    auto& bytes = scope.bytes();
    EXPECT_EQ(bytes.size(), span.size());
    EXPECT_EQ(bytes.span().data(), span.data());

    bytes.span()[0] = 0xFF;
    EXPECT_EQ(buffer[0], 0xFFu);
}

TEST(WTF_BorrowedBytes, MutableSpanScopeHoldsSoleReference)
{
    std::array<uint8_t, 2> buffer { };
    BorrowedMutableSpanScope scope(std::span<uint8_t> { buffer });
    EXPECT_TRUE(scope.bytes().hasOneRef());
    {
        RefPtr<BorrowedMutableBytes> transient = &scope.bytes();
        EXPECT_FALSE(scope.bytes().hasOneRef());
    }
    EXPECT_TRUE(scope.bytes().hasOneRef());
}

TEST(WTF_BorrowedBytes, EmptyMutableSpan)
{
    BorrowedMutableSpanScope scope(std::span<uint8_t> { });
    EXPECT_EQ(scope.bytes().size(), 0u);
    EXPECT_TRUE(scope.bytes().span().empty());
}

// MARK: - The ~Escapable views

TEST(WTF_BorrowedBytes, NonEscapableViewsWrapSpans)
{
    std::array<uint8_t, 5> buffer { 0, 1, 2, 3, 4 };
    auto immutable = NonEscapableBytes::create(std::span<const uint8_t> { buffer });
    auto mutableBytes = NonEscapableMutableBytes::create(std::span<uint8_t> { buffer });

    EXPECT_EQ(immutable.size(), buffer.size());
    EXPECT_FALSE(immutable.isEmpty());
    EXPECT_EQ(mutableBytes.size(), buffer.size());
    EXPECT_FALSE(mutableBytes.isEmpty());
    EXPECT_EQ(mutableBytes.span().data(), buffer.data());
}

TEST(WTF_BorrowedBytes, DefaultConstructedNonEscapableViewsAreEmpty)
{
    EXPECT_EQ(NonEscapableBytes().size(), 0u);
    EXPECT_TRUE(NonEscapableBytes().isEmpty());
    EXPECT_EQ(NonEscapableMutableBytes().size(), 0u);
    EXPECT_TRUE(NonEscapableMutableBytes().isEmpty());
    EXPECT_TRUE(NonEscapableMutableBytes().span().empty());
}

TEST(WTF_BorrowedBytes, NonEscapableSubspan)
{
    std::array<uint8_t, 6> buffer { 0, 1, 2, 3, 4, 5 };
    auto immutable = NonEscapableBytes::create(std::span<const uint8_t> { buffer });
    EXPECT_EQ(immutable.subspan(2, 3).size(), 3u);

    auto mutableBytes = NonEscapableMutableBytes::create(std::span<uint8_t> { buffer });
    EXPECT_EQ(mutableBytes.subspan(2, 3).size(), 3u);
    EXPECT_EQ(mutableBytes.subspan(2, 3).span().data(), buffer.data() + 2);

    // Degenerate but legal: an empty view at the very end.
    EXPECT_TRUE(immutable.subspan(6, 0).isEmpty());
}

// MARK: - Copying between the views
//
// Every source/destination combination, since each one performs its own revocation
// check before delegating to the single primitive.

TEST(WTF_BorrowedBytes, CopyNonEscapableToNonEscapable)
{
    Vector<uint8_t> source { 0xAA, 0xBB, 0xCC, 0xDD };
    std::array<uint8_t, 8> destination { };

    auto bytes = NonEscapableMutableBytes::create(std::span<uint8_t> { destination });
    auto sourceBytes = NonEscapableBytes::create(source.span());
    bytes.subspan(2, sourceBytes.size()).copyFrom(sourceBytes);

    EXPECT_EQ(destination[1], 0u);
    EXPECT_EQ(destination[2], 0xAAu);
    EXPECT_EQ(destination[5], 0xDDu);
    EXPECT_EQ(destination[6], 0u);
}

TEST(WTF_BorrowedBytes, CopyBorrowedToNonEscapable)
{
    Vector<uint8_t> source { 0xAA, 0xBB, 0xCC, 0xDD };
    std::array<uint8_t, 8> destination { };
    BorrowedVectorScope sourceScope(source);

    auto bytes = NonEscapableMutableBytes::create(std::span<uint8_t> { destination });
    bytes.subspan(2, sourceScope.bytes().size()).copyFrom(sourceScope.bytes());

    EXPECT_EQ(destination[1], 0u);
    EXPECT_EQ(destination[2], 0xAAu);
    EXPECT_EQ(destination[5], 0xDDu);
    EXPECT_EQ(destination[6], 0u);
}

TEST(WTF_BorrowedBytes, CopyNonEscapableToBorrowedMutable)
{
    Vector<uint8_t> source { 0xAA, 0xBB, 0xCC, 0xDD };
    std::array<uint8_t, 8> destination { };
    auto destinationSpan = std::span<uint8_t> { destination }.subspan(2, 4);
    BorrowedMutableSpanScope destinationScope(destinationSpan);

    destinationScope.bytes().copyFrom(NonEscapableBytes::create(source.span()));

    EXPECT_EQ(destination[1], 0u);
    EXPECT_EQ(destination[2], 0xAAu);
    EXPECT_EQ(destination[5], 0xDDu);
    EXPECT_EQ(destination[6], 0u);
}

TEST(WTF_BorrowedBytes, CopyBorrowedToBorrowedMutable)
{
    Vector<uint8_t> source { 0xAA, 0xBB, 0xCC, 0xDD };
    std::array<uint8_t, 8> destination { };
    auto destinationSpan = std::span<uint8_t> { destination }.subspan(2, 4);
    BorrowedMutableSpanScope destinationScope(destinationSpan);
    BorrowedVectorScope sourceScope(source);

    destinationScope.bytes().copyFrom(sourceScope.bytes());

    EXPECT_EQ(destination[1], 0u);
    EXPECT_EQ(destination[2], 0xAAu);
    EXPECT_EQ(destination[5], 0xDDu);
    EXPECT_EQ(destination[6], 0u);
}

// Copies of zero bytes are permitted, including at the very end of the buffer.
TEST(WTF_BorrowedBytes, CopyOfNothingIsANoOp)
{
    std::array<uint8_t, 4> destination { 0x11, 0x11, 0x11, 0x11 };
    auto bytes = NonEscapableMutableBytes::create(std::span<uint8_t> { destination });

    bytes.subspan(4, 0).copyFrom(NonEscapableBytes::create(std::span<const uint8_t> { }));
    bytes.subspan(0, 0).copyFrom(NonEscapableBytes());
    NonEscapableMutableBytes().copyFrom(NonEscapableBytes());

    for (auto byte : destination)
        EXPECT_EQ(byte, 0x11u);
}

// The copy uses memmove, so overlapping views produce the shifted result rather than
// undefined behaviour. Swift cannot construct this overlap, but C++ can.
TEST(WTF_BorrowedBytes, CopyToleratesOverlap)
{
    std::array<uint8_t, 6> buffer { 1, 2, 3, 4, 5, 6 };
    std::span<uint8_t> whole { buffer };

    auto destination = NonEscapableMutableBytes::create(whole.subspan(1, 4));
    destination.copyFrom(NonEscapableBytes::create(std::span<const uint8_t> { whole.subspan(0, 4) }));

    EXPECT_EQ(buffer[0], 1u);
    EXPECT_EQ(buffer[1], 1u);
    EXPECT_EQ(buffer[2], 2u);
    EXPECT_EQ(buffer[3], 3u);
    EXPECT_EQ(buffer[4], 4u);
    EXPECT_EQ(buffer[5], 6u);
}

// MARK: - The range checks
//
// These are RELEASE_ASSERTs, so unlike the stash assertion above they fire in release
// builds too. They are the backstop that turns an out-of-range request -- from Swift or
// from C++ -- into a crash rather than a read or write outside the bytes.

TEST(WTF_BorrowedBytesDeathTest, SubspanPastTheEndCrashes)
{
    auto shouldCrash = [] {
        std::array<uint8_t, 4> buffer { };
        NonEscapableMutableBytes::create(std::span<uint8_t> { buffer }).subspan(2, 3);
    };
    ASSERT_DEATH_IF_SUPPORTED(shouldCrash(), "");
}

TEST(WTF_BorrowedBytesDeathTest, SubspanWithWrappedOffsetCrashes)
{
    auto shouldCrash = [] {
        std::array<uint8_t, 4> buffer { };
        // What an offset arrives as when it exceeds what Swift's Int can represent.
        NonEscapableBytes::create(std::span<const uint8_t> { buffer }).subspan(std::numeric_limits<size_t>::max(), 1);
    };
    ASSERT_DEATH_IF_SUPPORTED(shouldCrash(), "");
}

TEST(WTF_BorrowedBytesDeathTest, CopyOfMismatchedLengthCrashes)
{
    auto shouldCrash = [] {
        std::array<uint8_t, 8> destination { };
        std::array<uint8_t, 4> source { };
        NonEscapableMutableBytes::create(std::span<uint8_t> { destination })
            .copyFrom(NonEscapableBytes::create(std::span<const uint8_t> { source }));
    };
    ASSERT_DEATH_IF_SUPPORTED(shouldCrash(), "");
}

} // namespace TestWebKitAPI
