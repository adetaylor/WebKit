// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#pragma once

#if ENABLE(WEB_AUTHN)

#include <WebCore/CBORBytes.h>
#include <algorithm>
#include <initializer_list>
#include <optional>
#include <span>
#include <utility>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

// Byte-level helpers for tests: builders that encode one data item as given (a map lists its keys in the order
// written and may repeat a key), and a walker that finds a key's encoded value in a map.
namespace TestWebKitAPI {

using CBORItem = Vector<uint8_t>;
using CBORMapEntry = std::pair<CBORItem, CBORItem>;

inline void appendCBORHead(CBORItem& out, uint8_t majorType, uint64_t argument)
{
    uint8_t type = majorType << 5;
    if (argument < 24) {
        out.append(type | static_cast<uint8_t>(argument));
        return;
    }
    unsigned width = argument <= 0xff ? 0 : argument <= 0xffff ? 1 : argument <= 0xffffffff ? 2 : 3;
    out.append(type | (24 + width));
    for (int shift = (1 << width) * 8 - 8; shift >= 0; shift -= 8)
        out.append(static_cast<uint8_t>(argument >> shift));
}

inline CBORItem cborInteger(int64_t value)
{
    CBORItem item;
    if (value >= 0)
        appendCBORHead(item, 0, static_cast<uint64_t>(value));
    else
        appendCBORHead(item, 1, static_cast<uint64_t>(-1 - value));
    return item;
}

inline CBORItem cborBytes(std::span<const uint8_t> bytes)
{
    CBORItem item;
    appendCBORHead(item, 2, bytes.size());
    item.append(bytes);
    return item;
}

inline CBORItem cborText(const String& string)
{
    auto utf8 = string.utf8();
    CBORItem item;
    appendCBORHead(item, 3, utf8.length());
    item.append(utf8.span());
    return item;
}

inline CBORItem cborSimple(uint8_t value)
{
    return { static_cast<uint8_t>(0xe0 | value) };
}

inline CBORItem cborBool(bool value)
{
    return cborSimple(value ? 21 : 20);
}

inline CBORItem cborArray(std::initializer_list<CBORItem> elements)
{
    CBORItem item;
    appendCBORHead(item, 4, elements.size());
    for (auto& element : elements)
        item.appendVector(element);
    return item;
}

inline CBORItem cborMap(std::initializer_list<CBORMapEntry> entries)
{
    CBORItem item;
    appendCBORHead(item, 5, entries.size());
    for (auto& entry : entries) {
        item.appendVector(entry.first);
        item.appendVector(entry.second);
    }
    return item;
}

struct CBORHead {
    uint8_t majorType { 0 };
    uint64_t argument { 0 };
    size_t headLength { 0 };
};

inline std::optional<CBORHead> readCBORHead(std::span<const uint8_t> item)
{
    if (item.empty())
        return std::nullopt;
    CBORHead head { static_cast<uint8_t>(item[0] >> 5), static_cast<uint64_t>(item[0] & 0x1f), 1 };
    if (head.argument < 24)
        return head;
    if (head.argument > 27)
        return std::nullopt;
    size_t width = static_cast<size_t>(1) << (head.argument - 24);
    if (item.size() < 1 + width)
        return std::nullopt;
    head.argument = 0;
    for (size_t i = 0; i < width; ++i)
        head.argument = (head.argument << 8) | item[1 + i];
    head.headLength = 1 + width;
    return head;
}

// The length of the data item at the start of item, nested items included.
inline std::optional<size_t> cborItemLength(std::span<const uint8_t> item)
{
    auto head = readCBORHead(item);
    if (!head)
        return std::nullopt;
    size_t length = head->headLength;
    switch (head->majorType) {
    case 2:
    case 3:
        if (item.size() - length < head->argument)
            return std::nullopt;
        return length + head->argument;
    case 4:
    case 5: {
        uint64_t count = head->majorType == 5 ? head->argument * 2 : head->argument;
        for (uint64_t i = 0; i < count; ++i) {
            if (length > item.size())
                return std::nullopt;
            auto elementLength = cborItemLength(item.subspan(length));
            if (!elementLength)
                return std::nullopt;
            length += *elementLength;
        }
        return length;
    }
    default:
        return length;
    }
}

inline bool isCBORMap(std::span<const uint8_t> item)
{
    auto head = readCBORHead(item);
    return head && head->majorType == 5;
}

// The encoded value of key (an encoded item) in the map at the start of map: the first such key.
inline std::optional<std::span<const uint8_t>> cborMapLookup(std::span<const uint8_t> map, std::span<const uint8_t> key)
{
    auto head = readCBORHead(map);
    if (!head || head->majorType != 5)
        return std::nullopt;
    size_t position = head->headLength;
    for (uint64_t i = 0; i < head->argument; ++i) {
        if (position > map.size())
            return std::nullopt;
        auto keyLength = cborItemLength(map.subspan(position));
        if (!keyLength || position + *keyLength > map.size())
            return std::nullopt;
        auto candidate = map.subspan(position, *keyLength);
        position += *keyLength;
        auto valueLength = cborItemLength(map.subspan(position));
        if (!valueLength)
            return std::nullopt;
        if (std::ranges::equal(candidate, key))
            return map.subspan(position, *valueLength);
        position += *valueLength;
    }
    return std::nullopt;
}

inline std::optional<std::span<const uint8_t>> cborMapLookup(std::span<const uint8_t> map, int64_t key)
{
    auto encodedKey = cborInteger(key);
    return cborMapLookup(map, encodedKey.span());
}

// The value of an integer item, in the range of int64_t.
inline std::optional<int64_t> cborIntegerValue(std::span<const uint8_t> item)
{
    auto head = readCBORHead(item);
    if (!head || head->majorType > 1 || head->argument > static_cast<uint64_t>(INT64_MAX))
        return std::nullopt;
    int64_t argument = static_cast<int64_t>(head->argument);
    return head->majorType ? -1 - argument : argument;
}

// The payload of a byte string item.
inline std::optional<Vector<uint8_t>> cborByteStringValue(std::span<const uint8_t> item)
{
    auto head = readCBORHead(item);
    if (!head || head->majorType != 2 || item.size() - head->headLength < head->argument)
        return std::nullopt;
    return Vector<uint8_t> { item.subspan(head->headLength, head->argument) };
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
