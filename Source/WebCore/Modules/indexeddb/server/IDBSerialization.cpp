/*
 * Copyright (C) 2014, 2016 Apple Inc. All rights reserved.
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
#include "IDBSerialization.h"

#include "IDBKeyData.h"
#include "IDBKeyPath.h"
#include "KeyedCoding.h"
#include "SwiftIDBTypes.h"
#include "WebCore-Swift.h"
#include <wtf/StdLibExtras.h>

#if USE(GLIB)
#include <glib.h>
#include <wtf/glib/GLibExtras.h>
#include <wtf/glib/GRefPtr.h>
#endif

namespace WebCore {

enum class KeyPathType { Null, String, Array };

RefPtr<SharedBuffer> serializeIDBKeyPath(const std::optional<IDBKeyPath>& keyPath)
{
    auto encoder = KeyedEncoder::encoder();

    if (keyPath) {
        auto visitor = WTF::makeVisitor([&](const String& string) {
            encoder->encodeEnum("type"_s, KeyPathType::String);
            encoder->encodeString("string"_s, string);
        }, [&](const Vector<String>& vector) {
            encoder->encodeEnum("type"_s, KeyPathType::Array);
            encoder->encodeObjects("array"_s, vector, [](WebCore::KeyedEncoder& encoder, const String& string) {
                encoder.encodeString("string"_s, string);
            });
        });
        WTF::visit(visitor, keyPath.value());
    } else
        encoder->encodeEnum("type"_s, KeyPathType::Null);

    return encoder->finishEncoding();
}

bool deserializeIDBKeyPath(std::span<const uint8_t> data, std::optional<IDBKeyPath>& result)
{
    if (data.empty())
        return false;

    auto decoder = KeyedDecoder::decoder(data);

    KeyPathType type;
    bool succeeded = decoder->decodeEnum("type"_s, type, [](KeyPathType value) {
        return value == KeyPathType::Null || value == KeyPathType::String || value == KeyPathType::Array;
    });
    if (!succeeded)
        return false;

    switch (type) {
    case KeyPathType::Null:
        break;
    case KeyPathType::String: {
        String string;
        if (!decoder->decodeString("string"_s, string))
            return false;
        result = IDBKeyPath(WTF::move(string));
        break;
    }
    case KeyPathType::Array: {
        Vector<String> vector;
        succeeded = decoder->decodeObjects("array"_s, vector, [](KeyedDecoder& decoder, String& result) {
            return decoder.decodeString("string"_s, result);
        });
        if (!succeeded)
            return false;
        result = IDBKeyPath(WTF::move(vector));
        break;
    }
    }
    return true;
}

NODELETE static bool isLegacySerializedIDBKeyData(std::span<const uint8_t> data)
{
#if USE(CF)
    // This is the magic character that begins serialized PropertyLists, and tells us whether
    // the key we're looking at is an old-style key.
    static const uint8_t legacySerializedKeyVersion = 'b';
    if (data[0] == legacySerializedKeyVersion)
        return true;
#elif USE(GLIB)
    // KeyedEncoderGLib uses a GVariant dictionary, so check if the given data is a valid GVariant dictionary.
    GRefPtr bytes = gBytesNew(data);
    GRefPtr<GVariant> variant = g_variant_new_from_bytes(G_VARIANT_TYPE("a{sv}"), bytes.get(), FALSE);
    return g_variant_is_normal_form(variant.get());
#else
    UNUSED_PARAM(data);
#endif
    return false;
}

RefPtr<SharedBuffer> serializeIDBKeyData(const IDBKeyData& key)
{
    return SharedBuffer::create(serializeIDBKeyDataBytes(key));
}

bool deserializeIDBKeyData(std::span<const uint8_t> data, IDBKeyData& result)
{
    if (data.empty())
        return false;

    if (isLegacySerializedIDBKeyData(data)) {
        auto decoder = KeyedDecoder::decoder(data);
        return IDBKeyData::decode(*decoder, result);
    }

    return deserializeIDBKeyDataBody(data, result);
}

} // namespace WebCore
