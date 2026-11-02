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
#include <wtf/SwiftBridging.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/UniqueRef.h>
#include <wtf/text/StringBuilder.h>

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
} SWIFT_NONESCAPABLE;

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
