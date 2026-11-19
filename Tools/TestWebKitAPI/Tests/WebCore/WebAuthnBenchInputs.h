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

#if ENABLE(WEB_AUTHN)

#include <WebCore/Pin.h>
#include <array>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#if __has_include(<WebCore/CBORBytes.h>)
#include <WebCore/CBORBytes.h>
#else
#include <WebCore/CBORReader.h>
#include <WebCore/CBORValue.h>
#include <WebCore/CBORWriter.h>
#endif

// The deterministic inputs of WebAuthnBench.cpp. Every input is a function of fixed bytes or of a fixed seed, so a
// checksum over the outputs is the same on every run.

namespace TestWebKitAPI {

namespace WebAuthnBenchInputs {

// FNV-1a over everything a test observes, in a fixed order.
class Hash {
public:
    void add(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_state ^= (value >> (i * 8)) & 0xff;
            m_state *= 0x100000001b3ULL;
        }
    }

    void add(std::span<const uint8_t> bytes)
    {
        add(static_cast<uint64_t>(bytes.size()));
        for (uint8_t byte : bytes) {
            m_state ^= byte;
            m_state *= 0x100000001b3ULL;
        }
    }

    void add(const String& string)
    {
        add(static_cast<uint64_t>(string.length()));
        for (unsigned i = 0; i < string.length(); ++i)
            add(static_cast<uint64_t>(string[i]));
    }

    void addFlag(bool flag) { add(static_cast<uint64_t>(flag ? 1 : 0)); }

    uint64_t value() const { return m_state; }

private:
    uint64_t m_state { 0xcbf29ce484222325ULL };
};

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

    uint8_t byte() { return static_cast<uint8_t>(below(256)); }

private:
    uint64_t m_state;
};

inline Vector<uint8_t> toVector(std::span<const uint8_t> span)
{
    Vector<uint8_t> result;
    result.append(span);
    return result;
}

inline Vector<uint8_t> patternBytes(size_t size, uint64_t seed)
{
    Random random(seed);
    Vector<uint8_t> result;
    result.reserveInitialCapacity(size);
    for (size_t i = 0; i < size; ++i)
        result.append(random.byte());
    return result;
}

// ---- The CBOR surface the benchmark uses: bytes in, bytes out ----
//
// The benchmark names no CBOR value type, so that it builds both with cbor::CBORValue and with the byte-level CBOR
// surface of WebCore/CBORBytes.h. Every read is observed as its canonical re-encoding (the reader accepts only
// canonical CBOR, so that is the input's own prefix) with the decoder's error code, and every write as the bytes of a
// read followed by a write. The three functions below are the only code that differs between the two: where CBORBytes.h
// exists they forward to it, and otherwise they use CBORValue, CBORReader and CBORWriter.

struct CanonicalRead {
    bool ok { false };
    unsigned error { 0 }; // cbor::CBORReader::DecoderError's numbering: 0 is no error.
    size_t bytesConsumed { 0 };
    Vector<uint8_t> canonical;
};

#if __has_include(<WebCore/CBORBytes.h>)

// The byte-level functions take their input as a std::span<const uint8_t> (readCanonical, through a C++ shell) or as a
// Vector<uint8_t> by value (writeCanonical); callWithBytes passes the span where the function takes one and a copy
// in a Vector where it does not, so these call sites compile either way.
template<typename Function>
inline auto callWithBytes(Function&& function, std::span<const uint8_t> bytes) -> decltype(function(bytes))
{
    return function(bytes);
}

template<typename Function>
inline auto callWithBytes(Function&& function, std::span<const uint8_t> bytes) -> decltype(function(Vector<uint8_t> { bytes }))
{
    return function(Vector<uint8_t> { bytes });
}

inline CanonicalRead readCanonicalBytes(std::span<const uint8_t> bytes, int maxNesting, bool allowTrailingData)
{
    auto result = callWithBytes([&](auto&& input) -> decltype(cbor::readCanonical(input, maxNesting, allowTrailingData)) {
        return cbor::readCanonical(input, maxNesting, allowTrailingData);
    }, bytes);
    return { result.error == cbor::DecoderError::CBORNoError, static_cast<unsigned>(result.error), result.bytesConsumed, WTF::move(result.canonical) };
}

// writeCanonical reads leniently (nesting up to 64) itself, so only the CBORValue branch uses readMaxNesting.
inline std::optional<Vector<uint8_t>> rewriteCanonicalBytes(std::span<const uint8_t> bytes, int, size_t writeMaxNesting)
{
    return callWithBytes([&](auto&& input) -> decltype(cbor::writeCanonical(input, writeMaxNesting)) {
        return cbor::writeCanonical(input, writeMaxNesting);
    }, bytes);
}

inline Vector<uint8_t> coseKeyBytes(Vector<uint8_t> rawKey)
{
    return fido::pin::encodeCOSEPublicKey(WTF::move(rawKey));
}

#else

inline CanonicalRead readCanonicalBytes(std::span<const uint8_t> bytes, int maxNesting, bool allowTrailingData)
{
    CanonicalRead result;
    auto error = cbor::CBORReader::DecoderError::CBORNoError;
    std::optional<cbor::CBORValue> value;
    if (allowTrailingData) {
        auto read = cbor::CBORReader::readWithBytesConsumed(bytes, &error, maxNesting);
        if (read) {
            value = WTF::move(read->first);
            result.bytesConsumed = read->second;
        }
    } else
        value = cbor::CBORReader::read(bytes, &error, maxNesting);
    result.error = static_cast<unsigned>(error);
    if (!value)
        return result;
    auto written = cbor::CBORWriter::write(*value, 1024);
    if (!written)
        return result;
    result.ok = true;
    result.canonical = WTF::move(*written);
    return result;
}

// A lenient parse into a tree, as writeCanonical does it (keys in any order, the first of a repeated key
// kept, nesting up to 64), because CBORReader reads no deeper than 16.
inline std::optional<cbor::CBORValue> parseLenient(std::span<const uint8_t> bytes, size_t& position, unsigned depth = 0)
{
    if (position >= bytes.size() || depth > 64)
        return std::nullopt;
    uint8_t initial = bytes[position++];
    unsigned major = initial >> 5;
    unsigned info = initial & 0x1f;
    uint64_t argument = info;
    if (info >= 24) {
        if (info > 27)
            return std::nullopt;
        size_t width = static_cast<size_t>(1) << (info - 24);
        if (bytes.size() - position < width)
            return std::nullopt;
        argument = 0;
        for (size_t i = 0; i < width; ++i)
            argument = (argument << 8) | bytes[position++];
    }
    switch (major) {
    case 0:
        return cbor::CBORValue(static_cast<int64_t>(argument));
    case 1:
        return cbor::CBORValue(-1 - static_cast<int64_t>(argument));
    case 2:
    case 3: {
        if (bytes.size() - position < argument)
            return std::nullopt;
        auto payload = bytes.subspan(position, argument);
        position += argument;
        if (major == 2)
            return cbor::CBORValue(Vector<uint8_t> { payload });
        return cbor::CBORValue(String::fromUTF8(payload));
    }
    case 4: {
        cbor::CBORValue::ArrayValue array;
        for (uint64_t i = 0; i < argument; ++i) {
            auto element = parseLenient(bytes, position, depth + 1);
            if (!element)
                return std::nullopt;
            array.append(WTF::move(*element));
        }
        return cbor::CBORValue(WTF::move(array));
    }
    case 5: {
        cbor::CBORValue::MapValue map;
        for (uint64_t i = 0; i < argument; ++i) {
            auto key = parseLenient(bytes, position, depth + 1);
            auto value = key ? parseLenient(bytes, position, depth + 1) : std::nullopt;
            if (!value)
                return std::nullopt;
            map.emplace(WTF::move(*key), WTF::move(*value));
        }
        return cbor::CBORValue(WTF::move(map));
    }
    case 7:
        return cbor::CBORValue(static_cast<cbor::CBORValue::SimpleValue>(info));
    }
    return std::nullopt;
}

inline std::optional<Vector<uint8_t>> rewriteCanonicalBytes(std::span<const uint8_t> bytes, int, size_t writeMaxNesting)
{
    size_t position = 0;
    auto value = parseLenient(bytes, position);
    if (!value || position != bytes.size())
        return std::nullopt;
    return cbor::CBORWriter::write(*value, writeMaxNesting);
}

inline Vector<uint8_t> coseKeyBytes(Vector<uint8_t> rawKey)
{
    auto written = cbor::CBORWriter::write(cbor::CBORValue(fido::pin::encodeCOSEPublicKey(WTF::move(rawKey))));
    return written ? WTF::move(*written) : Vector<uint8_t> { };
}

#endif

// The tree of one canonical CBOR item, as the checksum observes it: the type (major type + 2), then the payload,
// maps in their (canonical) order. False when the bytes are not an item.
inline bool hashCanonicalItem(Hash& hash, std::span<const uint8_t> bytes, size_t& position, unsigned depth = 0)
{
    if (position >= bytes.size() || depth > 64)
        return false;
    uint8_t initial = bytes[position++];
    unsigned major = initial >> 5;
    unsigned info = initial & 0x1f;
    uint64_t argument = info;
    if (info >= 24) {
        if (info > 27)
            return false;
        size_t width = static_cast<size_t>(1) << (info - 24);
        if (bytes.size() - position < width)
            return false;
        argument = 0;
        for (size_t i = 0; i < width; ++i)
            argument = (argument << 8) | bytes[position++];
    }
    switch (major) {
    case 0:
        hash.add(uint64_t { 2 });
        hash.add(argument);
        return true;
    case 1:
        hash.add(uint64_t { 3 });
        hash.add(static_cast<uint64_t>(-1 - static_cast<int64_t>(argument)));
        return true;
    case 2:
    case 3: {
        if (argument > bytes.size() - position)
            return false;
        auto payload = bytes.subspan(position, static_cast<size_t>(argument));
        position += payload.size();
        hash.add(static_cast<uint64_t>(major + 2));
        if (major == 2)
            hash.add(payload);
        else
            hash.add(String::fromUTF8(payload));
        return true;
    }
    case 4:
    case 5: {
        if (argument > bytes.size())
            return false;
        hash.add(static_cast<uint64_t>(major + 2));
        hash.add(argument);
        for (uint64_t i = 0; i < argument * (major - 3); ++i) {
            if (!hashCanonicalItem(hash, bytes, position, depth + 1))
                return false;
        }
        return true;
    }
    case 7:
        hash.add(uint64_t { 9 });
        hash.add(static_cast<uint64_t>(info));
        return true;
    }
    return false;
}

// Hashes the one item that fills the bytes, or a marker when the bytes are not exactly one item.
inline void hashCanonical(Hash& hash, std::span<const uint8_t> bytes)
{
    size_t position = 0;
    if (!hashCanonicalItem(hash, bytes, position) || position != bytes.size())
        hash.add(uint64_t { 0xbad });
}

// ---- Inputs, as canonical CBOR ----
// Each builder produces the canonical bytes of its value; maps are given in canonical order (major type, then length, then bytewise).

class CBORBuilder {
public:
    void head(unsigned major, uint64_t argument)
    {
        uint8_t type = static_cast<uint8_t>(major << 5);
        if (argument < 24)
            m_bytes.append(type | static_cast<uint8_t>(argument));
        else if (argument <= 0xff) {
            m_bytes.append(type | 24);
            m_bytes.append(static_cast<uint8_t>(argument));
        } else if (argument <= 0xffff)
            appendBigEndian(type | 25, argument, 2);
        else if (argument <= 0xffffffffULL)
            appendBigEndian(type | 26, argument, 4);
        else
            appendBigEndian(type | 27, argument, 8);
    }

    void integer(int64_t value)
    {
        if (value >= 0)
            head(0, static_cast<uint64_t>(value));
        else
            head(1, ~static_cast<uint64_t>(value));
    }

    void byteString(std::span<const uint8_t> bytes)
    {
        head(2, bytes.size());
        m_bytes.append(bytes);
    }

    // ASCII only.
    template<size_t N> void text(const char (&string)[N])
    {
        head(3, N - 1);
        for (size_t i = 0; i < N - 1; ++i)
            m_bytes.append(static_cast<uint8_t>(string[i]));
    }

    void textBytes(std::span<const uint8_t> utf8)
    {
        head(3, utf8.size());
        m_bytes.append(utf8);
    }

    void simple(uint8_t value) { m_bytes.append(static_cast<uint8_t>(0xe0 | value)); }
    void boolean(bool value) { simple(value ? 21 : 20); }
    void raw(std::span<const uint8_t> bytes) { m_bytes.append(bytes); }
    void raw(const CBORBuilder& other) { m_bytes.appendVector(other.m_bytes); }

    const Vector<uint8_t>& bytes() const { return m_bytes; }
    Vector<uint8_t> take() { return WTF::move(m_bytes); }

private:
    void appendBigEndian(uint8_t initial, uint64_t argument, unsigned width)
    {
        m_bytes.append(initial);
        for (unsigned i = width; i > 0; --i)
            m_bytes.append(static_cast<uint8_t>(argument >> ((i - 1) * 8)));
    }

    Vector<uint8_t> m_bytes;
};

// A CTAP makeCredential-shaped value: integer keys, nested maps and arrays, strings, byte strings.
inline Vector<uint8_t> makeMakeCredentialBytes()
{
    CBORBuilder rp;
    rp.head(5, 2);
    rp.text("id");
    rp.text("example.com");
    rp.text("name");
    rp.text("Example Relying Party");

    CBORBuilder user;
    user.head(5, 4);
    user.text("id");
    user.byteString(patternBytes(32, 1).span());
    user.text("icon");
    user.text("https://pics.example.com/00/p/aBjjjpqPb.png");
    user.text("name");
    user.text("john.p.smith@example.com");
    user.text("displayName");
    user.text("John P. Smith");

    CBORBuilder parameters;
    parameters.head(4, 5);
    for (int64_t algorithm : { -7, -257, -8, -35, -36 }) {
        parameters.head(5, 2);
        parameters.text("alg");
        parameters.integer(algorithm);
        parameters.text("type");
        parameters.text("public-key");
    }

    CBORBuilder excluded;
    excluded.head(4, 3);
    for (unsigned i = 0; i < 3; ++i) {
        excluded.head(5, 2);
        excluded.text("id");
        excluded.byteString(patternBytes(64, 10 + i).span());
        excluded.text("type");
        excluded.text("public-key");
    }

    CBORBuilder options;
    options.head(5, 2);
    options.text("rk");
    options.boolean(true);
    options.text("uv");
    options.boolean(false);

    CBORBuilder extensions;
    extensions.head(5, 3);
    extensions.text("credBlob");
    extensions.byteString(patternBytes(32, 20).span());
    extensions.text("hmac-secret");
    extensions.boolean(true);
    extensions.text("largeBlobKey");
    extensions.boolean(true);

    CBORBuilder request;
    request.head(5, 9);
    request.integer(1);
    request.byteString(patternBytes(32, 2).span());
    request.integer(2);
    request.raw(rp);
    request.integer(3);
    request.raw(user);
    request.integer(4);
    request.raw(parameters);
    request.integer(5);
    request.raw(excluded);
    request.integer(6);
    request.raw(extensions);
    request.integer(7);
    request.raw(options);
    request.integer(8);
    request.byteString(patternBytes(16, 3).span());
    request.integer(9);
    request.integer(2);
    return request.take();
}

// Every integer width, both signs, and every length class of a byte string, string, array and map.
inline Vector<uint8_t> makeScalarsBytes()
{
    CBORBuilder values;
    unsigned count = 0;
    for (int64_t value : { int64_t(0), int64_t(1), int64_t(23), int64_t(24), int64_t(255), int64_t(256), int64_t(65535), int64_t(65536), int64_t(0xffffffffLL), int64_t(0x100000000LL), int64_t(0x7fffffffffffffffLL) }) {
        values.integer(value);
        values.integer(-1 - value);
        count += 2;
    }
    for (size_t length : { size_t(0), size_t(1), size_t(23), size_t(24), size_t(255), size_t(256), size_t(65535), size_t(65536) }) {
        values.byteString(patternBytes(length, 100 + length).span());
        Vector<uint8_t> letters;
        for (size_t i = 0; i < length; ++i)
            letters.append(static_cast<uint8_t>('a' + (i % 26)));
        values.textBytes(letters.span());
        count += 2;
    }
    for (size_t length : { size_t(0), size_t(1), size_t(23), size_t(24), size_t(256) }) {
        values.head(4, length);
        for (size_t i = 0; i < length; ++i)
            values.integer(static_cast<int64_t>(i));
        values.head(5, length);
        for (size_t i = 0; i < length; ++i) {
            values.integer(static_cast<int64_t>(i));
            values.integer(-1 - static_cast<int64_t>(i));
        }
        count += 2;
    }
    values.boolean(true);
    values.boolean(false);
    values.simple(22);
    values.simple(23);
    count += 4;
    // Strings that need the UTF-8 encoder: two-, three- and four-byte sequences (U+00E9, U+20AC, U+1F511).
    static constexpr uint8_t wide[] = { 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x94, 0x91 };
    values.textBytes(std::span<const uint8_t> { wide });
    ++count;
    // Maps whose keys are of both types, in the CTAP order: unsigned, negative, then strings by length.
    values.head(5, 6);
    values.integer(1);
    values.integer(5);
    values.integer(10);
    values.integer(4);
    values.integer(-1);
    values.integer(3);
    values.text("");
    values.integer(6);
    values.text("b");
    values.integer(2);
    values.text("aa");
    values.integer(1);
    ++count;

    CBORBuilder array;
    array.head(4, count);
    array.raw(values);
    return array.take();
}

// A CBOR array nested depth levels deep, as bytes: 0x81 depth times, then 0x80.
inline Vector<uint8_t> nestedArrayBytes(unsigned depth)
{
    Vector<uint8_t> bytes;
    for (unsigned i = 0; i < depth; ++i)
        bytes.append(0x81);
    bytes.append(0x80);
    return bytes;
}

} // namespace WebAuthnBenchInputs

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
