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

#include "Connection.h"
#include "Decoder.h"
#include "Encoder.h"
#include "StreamConnectionEncoder.h"
#include "StreamServerConnection.h"
#include <WebCore/SharedBuffer.h>
#include <wtf/EscapableByteSpan.h>
#include <wtf/NonEscapableBorrow.h>
#include <wtf/Noncopyable.h>
#include <wtf/RefCounted.h>
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/UniqueRef.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/unicode/CharacterNames.h>

namespace IPC {

// Writes the UTF-8 form of Latin-1 characters to utf8, which must have room for twice as many bytes, so that
// Swift can make a String of them without converting one character at a time. Returns the length written.
inline size_t writeUTF8ForLatin1Characters(std::span<const Latin1Character> characters, std::span<uint8_t> utf8)
{
    RELEASE_ASSERT(utf8.size() / 2 >= characters.size());
    if (charactersAreAllASCII(characters)) {
        memcpySpan(utf8, asByteSpan(characters));
        return characters.size();
    }
    size_t length = 0;
    for (auto character : characters) {
        if (isASCII(character))
            utf8[length++] = character;
        else {
            utf8[length++] = 0xC0 | (character >> 6);
            utf8[length++] = 0x80 | (character & 0x3F);
        }
    }
    return length;
}

// Writes the UTF-8 form of UTF-16 code units to utf8, which must have room for three times as many bytes, so that
// Swift can make a String of them without transcoding one code unit at a time. An unpaired surrogate becomes
// U+FFFD, as a Swift String can't hold one. Returns the length written.
inline size_t writeUTF8ForUTF16Characters(std::span<const char16_t> characters, std::span<uint8_t> utf8)
{
    RELEASE_ASSERT(utf8.size() / 3 >= characters.size());
    auto isLeadSurrogate = [](char32_t character) { return (character & 0xFFFFFC00) == 0xD800; };
    auto isTrailSurrogate = [](char32_t character) { return (character & 0xFFFFFC00) == 0xDC00; };
    size_t length = 0;
    for (size_t index = 0; index < characters.size(); ++index) {
        char32_t character = characters[index];
        if (isLeadSurrogate(character) && index + 1 < characters.size() && isTrailSurrogate(characters[index + 1]))
            character = 0x10000 + ((character - 0xD800) << 10) + (characters[++index] - 0xDC00);
        else if (isLeadSurrogate(character) || isTrailSurrogate(character))
            character = replacementCharacter;
        if (character < 0x80)
            utf8[length++] = character;
        else if (character < 0x800) {
            utf8[length++] = 0xC0 | (character >> 6);
            utf8[length++] = 0x80 | (character & 0x3F);
        } else if (character < 0x10000) {
            utf8[length++] = 0xE0 | (character >> 12);
            utf8[length++] = 0x80 | ((character >> 6) & 0x3F);
            utf8[length++] = 0x80 | (character & 0x3F);
        } else {
            utf8[length++] = 0xF0 | (character >> 18);
            utf8[length++] = 0x80 | ((character >> 12) & 0x3F);
            utf8[length++] = 0x80 | ((character >> 6) & 0x3F);
            utf8[length++] = 0x80 | (character & 0x3F);
        }
    }
    return length;
}

// The element spans of the arrays generated Swift decodes in one call, named so that Swift sees them as MutableSpan.
using MutableSpanUInt16 = std::span<uint16_t>;
using MutableSpanUInt32 = std::span<uint32_t>;
using MutableSpanUInt64 = std::span<uint64_t>;
using MutableSpanInt8 = std::span<int8_t>;
using MutableSpanInt16 = std::span<int16_t>;
using MutableSpanInt32 = std::span<int32_t>;
using MutableSpanInt64 = std::span<int64_t>;
using MutableSpanFloat = std::span<float>;
using MutableSpanDouble = std::span<double>;

// The primitive decoders of the Decoder of a message whose Swift receiver takes Swift types, lent to
// generated Swift. A failed decode returns false and invalidates the decoder. Values are returned
// through out parameters because Swift would import std::optional<uint64_t> as Optional<UInt> on Linux.
class SwiftDecoder : public NonEscapableBorrow<Decoder> {
public:
    [[nodiscard]] bool decodeBool(bool& value) { return decode(value); }
    [[nodiscard]] bool decodeUInt8(uint8_t& value) { return decode(value); }
    [[nodiscard]] bool decodeUInt16(uint16_t& value) { return decode(value); }
    [[nodiscard]] bool decodeUInt32(uint32_t& value) { return decode(value); }
    [[nodiscard]] bool decodeUInt64(uint64_t& value) { return decode(value); }
    [[nodiscard]] bool decodeInt8(int8_t& value) { return decode(value); }
    [[nodiscard]] bool decodeInt16(int16_t& value) { return decode(value); }
    [[nodiscard]] bool decodeInt32(int32_t& value) { return decode(value); }
    [[nodiscard]] bool decodeInt64(int64_t& value) { return decode(value); }
    [[nodiscard]] bool decodeFloat(float& value) { return decode(value); }
    [[nodiscard]] bool decodeDouble(double& value) { return decode(value); }

    // Decode values.size() values as Decoder::decodeSpan decodes a Vector's elements of a trivially copyable type,
    // in one call rather than one per element.
    [[nodiscard]] bool decodeUInt8s(WTF::MutableSpanUInt8 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeUInt16s(MutableSpanUInt16 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeUInt32s(MutableSpanUInt32 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeUInt64s(MutableSpanUInt64 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeInt8s(MutableSpanInt8 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeInt16s(MutableSpanInt16 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeInt32s(MutableSpanInt32 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeInt64s(MutableSpanInt64 values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeFloats(MutableSpanFloat values NOESCAPE) { return decodeSpan(values); }
    [[nodiscard]] bool decodeDoubles(MutableSpanDouble values NOESCAPE) { return decodeSpan(values); }

    // Aligns the decoder as Decoder::decodeSpan aligns elementCount contiguous integers of elementSize
    // (1, 2, 4 or 8) bytes, even when elementCount is 0, and checks they are all there, so they can be
    // decoded one at a time.
    [[nodiscard]] bool beginArray(size_t elementCount, size_t elementSize)
    {
        auto& decoder = borrowed();
        bool aligned = [&] {
            switch (elementSize) {
            case 1:
                return !!decoder.decodeSpan<uint8_t>(0).data();
            case 2:
                return !!decoder.decodeSpan<uint16_t>(0).data();
            case 4:
                return !!decoder.decodeSpan<uint32_t>(0).data();
            case 8:
                return !!decoder.decodeSpan<uint64_t>(0).data();
            default:
                return false;
            }
        }();
        if (!aligned || elementCount > remainingByteCount() / elementSize) [[unlikely]] {
            decoder.markInvalid();
            return false;
        }
        return true;
    }

    // Decodes characterCount Latin-1 characters as String's decoder decodes an 8-bit string's, writing their
    // UTF-8 form to utf8, which must have room for twice as many bytes, and its length to utf8Length.
    [[nodiscard]] bool decodeLatin1Characters(size_t characterCount, WTF::MutableSpanUInt8 utf8 NOESCAPE, size_t& utf8Length)
    {
        auto& decoder = borrowed();
        auto characters = decoder.decodeSpan<Latin1Character>(characterCount);
        if (!characters.data() || utf8.size() / 2 < characters.size()) [[unlikely]] {
            decoder.markInvalid();
            return false;
        }
        utf8Length = writeUTF8ForLatin1Characters(characters, utf8);
        return true;
    }

    // Decodes characterCount UTF-16 code units as String's decoder decodes a 16-bit string's, writing their UTF-8
    // form to utf8, which must have room for three times as many bytes, and its length to utf8Length.
    [[nodiscard]] bool decodeUTF16Characters(size_t characterCount, WTF::MutableSpanUInt8 utf8 NOESCAPE, size_t& utf8Length)
    {
        auto& decoder = borrowed();
        auto characters = decoder.decodeSpan<char16_t>(characterCount);
        if (!characters.data() || utf8.size() / 3 < characters.size()) [[unlikely]] {
            decoder.markInvalid();
            return false;
        }
        utf8Length = writeUTF8ForUTF16Characters(characters, utf8);
        return true;
    }

    // Decodes a C++-decoded value (IPCCoding.CxxDecoded in Swift) with its own ArgumentCoder. Returns null if
    // it is malformed.
    WebCore::SharedBuffer* WTF_NULLABLE decodeSharedBuffer() SWIFT_RETURNS_RETAINED;

    size_t remainingByteCount() const
    {
        auto& decoder = borrowed();
        auto span = decoder.span();
        size_t offset = decoder.currentBufferOffset();
        return offset < span.size() ? span.size() - offset : 0;
    }

    bool isValid() const { return borrowed().isValid(); }
    void markInvalid() { borrowed().markInvalid(); }

private:
    friend class NonEscapableBorrowLender<SwiftDecoder>;
    friend class NonEscapableBorrowOwningLender<SwiftDecoder>;
    template<typename> friend class CxxDecodedArgument;

    explicit SwiftDecoder(NonEscapableBorrowLease<Decoder>& lease LIFETIME_BOUND)
        : NonEscapableBorrow(lease)
    {
    }

    template<typename T> [[nodiscard]] bool decode(T& value)
    {
        auto decoded = borrowed().decode<T>();
        if (!decoded)
            return false;
        value = *decoded;
        return true;
    }

    template<typename T> [[nodiscard]] bool decodeSpan(std::span<T> values)
    {
        static_assert(std::is_trivially_copyable_v<T> && !std::is_same_v<T, bool>);
        auto decoded = borrowed().decodeSpan<T>(values.size());
        if (!decoded.data())
            return false;
        memcpySpan(values, decoded);
        return true;
    }
} SWIFT_NONESCAPABLE;

// An argument of a message whose Swift receiver takes Swift types, which has no Swift form yet, so its own ArgumentCoder
// decodes it into this holder. Generated Swift passes the holder to the receiver, which passes it on to the C++ that
// takes the value, once.
template<typename T>
class CxxDecodedArgument final : public RefCounted<CxxDecodedArgument<T>> {
public:
    // Null if the argument is malformed.
    static CxxDecodedArgument* WTF_NULLABLE decode(SwiftDecoder& decoder) SWIFT_RETURNS_RETAINED
    {
        auto value = decoder.borrowed().template decode<T>();
        if (!value)
            return nullptr;
        return &adoptRef(*new CxxDecodedArgument(WTF::move(*value))).leakRef();
    }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { RefCounted<CxxDecodedArgument<T>>::ref(); }
    void deref() const { RefCounted<CxxDecodedArgument<T>>::deref(); }
#endif

    // The value, the first time.
    std::optional<T> take() { return std::exchange(m_value, std::nullopt); }

private:
    explicit CxxDecodedArgument(T&& value)
        : m_value(WTF::move(value))
    {
    }

    std::optional<T> m_value;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// A Decoder that generated Swift decodes from outside the dispatch of a message, such as a value or a reply that
// C++ encodes as IPC would, for Swift to decode with its messages' coders. It owns the Decoder and lends it as
// swiftDecoder(), on the thread that made it and until it is destroyed.
class SwiftOwnedDecoder {
public:
    explicit SwiftOwnedDecoder(std::unique_ptr<Decoder>&& decoder)
        : m_lender(WTF::move(decoder))
    {
    }

    SwiftDecoder swiftDecoder() const LIFETIME_BOUND { return m_lender.view(); }

private:
    NonEscapableBorrowOwningLender<SwiftDecoder> m_lender;
};

// The reply to a message whose Swift receiver takes Swift types, which generated Swift encodes and sends.
// Cancelling it, or dropping it unsent, sends the default reply that cancelling a C++ handler's
// completion handler would.
//
// The Synchronous reply to a stream message goes into the stream buffer, as StreamServerConnection::sendSyncReply()
// puts a C++ handler's, unless it doesn't fit. Then send() returns false, and generated Swift encodes the reply a
// second time, out of stream, and sends it again. Such a reply can only be used while its message is being
// dispatched.
class SwiftReplyEncoder final : public ThreadSafeRefCounted<SwiftReplyEncoder> {
public:
    using DefaultReplyEncoder = void (*)(Encoder&);

    static Ref<SwiftReplyEncoder> create(Connection& connection, UniqueRef<Encoder>&& encoder, DefaultReplyEncoder encodeDefaultReply)
    {
        return adoptRef(*new SwiftReplyEncoder(connection, WTF::move(encoder), encodeDefaultReply));
    }

    static Ref<SwiftReplyEncoder> createForStreamSyncReply(StreamServerConnection& connection, Connection::SyncRequestID syncRequestID, bool isReplyStreamEncodable, DefaultReplyEncoder encodeDefaultReply)
    {
        return adoptRef(*new SwiftReplyEncoder(connection, syncRequestID, isReplyStreamEncodable, encodeDefaultReply));
    }

    ~SwiftReplyEncoder()
    {
        if (m_encoder || m_inStream)
            cancel();
    }

#ifdef __swift__
    // FIXME: rdar://165684636 means we have to define these at this level of the
    // type hierarchy.
    void ref() const { ThreadSafeRefCounted<SwiftReplyEncoder>::ref(); }
    void deref() const { ThreadSafeRefCounted<SwiftReplyEncoder>::deref(); }
#endif

    void encode(bool value) { encodeValue(value); }
    void encode(uint8_t value) { encodeValue(value); }
    void encode(uint16_t value) { encodeValue(value); }
    void encode(uint32_t value) { encodeValue(value); }
    void encode(uint64_t value) { encodeValue(value); }
    void encode(int8_t value) { encodeValue(value); }
    void encode(int16_t value) { encodeValue(value); }
    void encode(int32_t value) { encodeValue(value); }
    void encode(int64_t value) { encodeValue(value); }
    void encode(float value) { encodeValue(value); }
    void encode(double value) { encodeValue(value); }

    // Encodes the characters of an ASCII string as String's encoder encodes an 8-bit string's.
    void encodeASCIICharacters(WTF::SpanUInt8 characters NOESCAPE)
    {
        ASSERT(charactersAreAllASCII(characters));
        if (m_inStream) {
            streamEncoder().encodeSpan(characters);
            return;
        }
        RELEASE_ASSERT(m_encoder);
        m_encoder->encodeSpan(characters);
    }

    // Encodes a C++-decoded value with its own ArgumentCoder.
    void encodeSharedBuffer(const WebCore::SharedBuffer&);

    // Returns false if the reply didn't fit in the stream buffer. It must then be encoded again, out of stream,
    // and sent again.
    bool send()
    {
        if (m_inStream) {
            m_inStream = false;
            bool fits = streamEncoder().isValid();
            m_streamEncoder.reset();
            if (fits)
                return true;
            continueOutOfStream();
            return false;
        }
        if (auto encoder = std::exchange(m_encoder, nullptr))
            sendOutOfStream(makeUniqueRefFromNonNullUniquePtr(WTF::move(encoder)));
        return true;
    }

    void cancel()
    {
        if (m_inStream) {
            m_inStream = false;
            m_streamEncoder.reset();
            continueOutOfStream();
        }
        auto encoder = std::exchange(m_encoder, nullptr);
        if (!encoder)
            return;
        m_encodeDefaultReply(*encoder);
        sendOutOfStream(makeUniqueRefFromNonNullUniquePtr(WTF::move(encoder)));
    }

    // Gives back the unsent encoder of a message that failed to decode, so IPC replies as for any
    // unhandled message.
    std::unique_ptr<Encoder> discard()
    {
        m_inStream = false;
        m_streamEncoder.reset();
        return std::exchange(m_encoder, nullptr);
    }

    // Called when the dispatch of a stream message ends: replies with the default reply if generated Swift
    // didn't reply, and makes later use crash, since the stream buffer is no longer the reply's.
    void endStreamDispatch()
    {
        cancel();
        m_streamConnection = nullptr;
    }

private:
    SwiftReplyEncoder(Connection& connection, UniqueRef<Encoder>&& encoder, DefaultReplyEncoder encodeDefaultReply)
        : m_connection(connection)
        , m_encoder(encoder.moveToUniquePtr())
        , m_encodeDefaultReply(encodeDefaultReply)
    {
    }

    SwiftReplyEncoder(StreamServerConnection& connection, Connection::SyncRequestID syncRequestID, bool isReplyStreamEncodable, DefaultReplyEncoder encodeDefaultReply)
        : m_connection(connection.connection())
        , m_encodeDefaultReply(encodeDefaultReply)
        , m_streamConnection(&connection)
        , m_syncRequestID(syncRequestID)
        , m_inStream(isReplyStreamEncodable && connection.m_isProcessingStreamMessage)
    {
        if (!m_inStream)
            m_encoder = makeUnique<Encoder>(MessageName::SyncMessageReply, syncRequestID.toUInt64());
    }

    template<typename T> void encodeValue(T value)
    {
        if (m_inStream) {
            streamEncoder() << value;
            return;
        }
        RELEASE_ASSERT(m_encoder);
        *m_encoder << value;
    }

    // The stream buffer is only acquired when the reply is first encoded, after its message is decoded.
    StreamConnectionEncoder& streamEncoder()
    {
        RELEASE_ASSERT(m_streamConnection);
        if (!m_streamEncoder) {
            m_streamSpan = m_streamConnection->m_buffer.acquireAll();
            m_streamEncoder.emplace(MessageName::SyncMessageReply, m_streamSpan);
        }
        return *m_streamEncoder;
    }

    // Tells the client in the stream that the reply comes out of stream, as sendSyncReply() does.
    void continueOutOfStream()
    {
        RELEASE_ASSERT(m_streamConnection);
        if (m_streamSpan.empty())
            m_streamSpan = m_streamConnection->m_buffer.acquireAll();
        StreamConnectionEncoder { MessageName::ProcessOutOfStreamMessage, m_streamSpan };
        m_encoder = makeUnique<Encoder>(MessageName::SyncMessageReply, m_syncRequestID->toUInt64());
    }

    void sendOutOfStream(UniqueRef<Encoder>&& encoder)
    {
        if (!m_streamConnection) {
            m_connection->sendSyncReply(WTF::move(encoder));
            return;
        }
        // As sendSyncReply(), a reply to a message in the stream is sent after the stream buffer is released.
        if (m_streamConnection->m_isProcessingStreamMessage) {
            m_streamConnection->m_syncReplyToDispatch = encoder.moveToUniquePtr();
            return;
        }
        m_connection->sendSyncReply(WTF::move(encoder));
    }

    const Ref<Connection> m_connection;
    std::unique_ptr<Encoder> m_encoder;
    DefaultReplyEncoder m_encodeDefaultReply;
    RefPtr<StreamServerConnection> m_streamConnection;
    std::optional<Connection::SyncRequestID> m_syncRequestID;
    std::span<uint8_t> m_streamSpan;
    std::optional<StreamConnectionEncoder> m_streamEncoder;
    bool m_inStream { false };
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// The 8-bit WTF::String that C++ decoding gives for ASCII characters.
inline String stringForASCIICharacters(WTF::SpanUInt8 characters NOESCAPE)
{
    ASSERT(charactersAreAllASCII(characters));
    if (characters.empty())
        return emptyString();
    return String { byteCast<Latin1Character>(characters) };
}

// Writes the UTF-8 form of an 8-bit WTF::String to utf8, which must have room for twice its length. Returns the
// length written.
inline size_t writeUTF8ForLatin1String(const String& string, WTF::MutableSpanUInt8 utf8 NOESCAPE)
{
    RELEASE_ASSERT(string.is8Bit());
    return writeUTF8ForLatin1Characters(string.span8(), utf8);
}

// Builds the WTF::String that generated Swift hands to C++ for a Swift String, one code unit at a time
// as SwiftReplyEncoder encodes one.
class SwiftStringBuilder {
public:
    void appendLatin1(uint8_t character) { m_builder.append(Latin1Character { character }); }
    void appendUTF16(uint16_t codeUnit) { m_builder.append(static_cast<char16_t>(codeUnit)); }
    String toString() { return m_builder.toString(); }

private:
    StringBuilder m_builder;
} SWIFT_SELF_CONTAINED;

} // namespace IPC
