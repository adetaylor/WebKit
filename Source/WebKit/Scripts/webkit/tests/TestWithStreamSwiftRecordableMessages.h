/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "ArgumentCoders.h"
#include "ArrayReferenceTuple.h"
#include "Connection.h"
#include "IPCSemaphore.h"
#include "MessageNames.h"
#include "StreamMessageReceiver.h"
#include "SwiftCoding.h"
#include <WebCore/GlyphBufferMembers.h>
#include <array>
#include <span>
#include <wtf/Forward.h>
#include <wtf/RefPtr.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class FloatPoint;
class FloatRect;
class Path;
enum class StrokeStyle : uint8_t;
}

namespace WebKit {
class TestWithStreamSwiftRecordableRun;
}
namespace IPC {
class SwiftReplyEncoder;
}

namespace WebKit {
class TestWithStreamSwiftRecordable;
class TestWithStreamSwiftRecordableMessageForwarder;
class TestWithStreamSwiftRecordableRecorderMessageForwarder;
class TestWithStreamSwiftRecordableRecorderWeakRef;
class TestWithStreamSwiftRecordableWeakRef;
}

namespace WebKit {
class TestWithStreamSwiftRecordableLender;
}

namespace WebKit {

class TestWithStreamSwiftRecordableMessageForwarder final : public IPC::StreamMessageReceiver {
public:
    static Ref<TestWithStreamSwiftRecordableMessageForwarder> createFromWeak(WebKit::TestWithStreamSwiftRecordableWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithStreamSwiftRecordableMessageForwarder(handler));
    }
    ~TestWithStreamSwiftRecordableMessageForwarder();
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    void ref() const { StreamMessageReceiver::ref(); }
    void deref() const { StreamMessageReceiver::deref(); }
    // Lets the C++ that registers the receiver lend its handlers the state they take inout, through the lender's
    // lendSwiftReceiverState(), for one message at a time. The forwarder keeps the lender, so the lender must not keep it.
    void setStateLender(WebKit::TestWithStreamSwiftRecordableLender&);
private:
    TestWithStreamSwiftRecordableMessageForwarder(WebKit::TestWithStreamSwiftRecordableWeakRef* WTF_NONNULL);
    std::unique_ptr<WebKit::TestWithStreamSwiftRecordableWeakRef> m_handler;
    RefPtr<WebKit::TestWithStreamSwiftRecordableLender> m_stateLender;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// The forwarder of a recorder of the messages: it decodes each message as the receiver's forwarder does, and passes its
// arguments to the recorder rather than to a handler. It keeps the recorder.
class TestWithStreamSwiftRecordableRecorderMessageForwarder final : public IPC::StreamMessageReceiver {
public:
    static Ref<TestWithStreamSwiftRecordableRecorderMessageForwarder> createFromWeak(WebKit::TestWithStreamSwiftRecordableRecorderWeakRef* WTF_NONNULL handler)
    {
        return adoptRef(*new TestWithStreamSwiftRecordableRecorderMessageForwarder(handler));
    }
    ~TestWithStreamSwiftRecordableRecorderMessageForwarder();
    void didReceiveStreamMessage(IPC::StreamServerConnection&, IPC::Decoder&) final;
    // Gives the recorder the messages that another process encoded as it recorded them: false if one is invalid.
    bool didReceiveRecordedMessages(std::span<const uint8_t>);
    void ref() const { StreamMessageReceiver::ref(); }
    void deref() const { StreamMessageReceiver::deref(); }
private:
    TestWithStreamSwiftRecordableRecorderMessageForwarder(WebKit::TestWithStreamSwiftRecordableRecorderWeakRef* WTF_NONNULL);
    void dispatch(IPC::StreamServerConnection*, IPC::Decoder&);
    std::unique_ptr<WebKit::TestWithStreamSwiftRecordableRecorderWeakRef> m_handler;
} DERIVED_CLASS_SWIFT_SHARED_REFERENCE(.ref, .deref);

// Encodes the messages of a recording one after another, as the stream sends them, for a recorder in another process to
// record again (TestWithStreamSwiftRecordableRecorderMessageForwarder::didReceiveRecordedMessages()).
class TestWithStreamSwiftRecordableRecordedMessageEncoder {
public:
    void encodeReset();
    void encodeSetValues(uint32_t value, float scale);
    void encodeDrawRun(const WebCore::FloatPoint& origin, const WebKit::TestWithStreamSwiftRecordableRun& run);
#if PLATFORM(COCOA)
    void encodeDraw(const WebCore::FloatRect& rect, bool clip);
#endif
    IPC::SwiftReplyEncoder* WTF_NONNULL encoderForSetLabel() SWIFT_RETURNS_RETAINED;
    IPC::SwiftReplyEncoder* WTF_NONNULL encoderForFillPath() SWIFT_RETURNS_RETAINED;
    IPC::SwiftReplyEncoder* WTF_NONNULL encoderForDrawGlyphs() SWIFT_RETURNS_RETAINED;
    IPC::SwiftReplyEncoder* WTF_NONNULL encoderForSetMatrix() SWIFT_RETURNS_RETAINED;
    void appendEncodedMessage(IPC::SwiftReplyEncoder&);
    Vector<uint8_t> takeEncodedMessages() { return std::exchange(m_encodedMessages, { }); }
private:
    Vector<uint8_t> m_encodedMessages;
};

}

using RefTestWithStreamSwiftRecordableMessageForwarder = Ref<WebKit::TestWithStreamSwiftRecordableMessageForwarder>;
using RefTestWithStreamSwiftRecordableRecorderMessageForwarder = Ref<WebKit::TestWithStreamSwiftRecordableRecorderMessageForwarder>;

namespace Messages {
namespace TestWithStreamSwiftRecordable {

static inline IPC::ReceiverName messageReceiverName()
{
    return IPC::ReceiverName::TestWithStreamSwiftRecordable;
}

class Reset {
public:
    using Arguments = std::tuple<>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_Reset; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    Reset()
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
    }

private:
};

class SetSource {
public:
    using Arguments = std::tuple<uint64_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_SetSource; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    explicit SetSource(uint64_t source)
        : m_source(source)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_source;
    }

private:
    uint64_t m_source;
};

class SetValues {
public:
    using Arguments = std::tuple<uint32_t, float>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_SetValues; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    SetValues(uint32_t value, float scale)
        : m_value(value)
        , m_scale(scale)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_value;
        encoder << m_scale;
    }

private:
    uint32_t m_value;
    float m_scale;
};

class DrawRun {
public:
    using Arguments = std::tuple<WebCore::FloatPoint, WebKit::TestWithStreamSwiftRecordableRun>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_DrawRun; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    DrawRun(const WebCore::FloatPoint& origin, const WebKit::TestWithStreamSwiftRecordableRun& run)
        : m_origin(origin)
        , m_run(run)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_origin;
        SUPPRESS_FORWARD_DECL_ARG encoder << m_run;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::FloatPoint& m_origin;
    SUPPRESS_FORWARD_DECL_MEMBER const WebKit::TestWithStreamSwiftRecordableRun& m_run;
};

#if PLATFORM(COCOA)
class Draw {
public:
    using Arguments = std::tuple<WebCore::FloatRect, bool>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_Draw; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    Draw(const WebCore::FloatRect& rect, bool clip)
        : m_rect(rect)
        , m_clip(clip)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_rect;
        encoder << m_clip;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::FloatRect& m_rect;
    bool m_clip;
};
#endif

class SetLabel {
public:
    using Arguments = std::tuple<String, std::optional<uint64_t>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_SetLabel; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    SetLabel(const String& label, const std::optional<uint64_t>& tag)
        : m_label(label)
        , m_tag(tag)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_label;
        SUPPRESS_FORWARD_DECL_ARG encoder << m_tag;
    }

private:
    const String& m_label;
    SUPPRESS_FORWARD_DECL_MEMBER const std::optional<uint64_t>& m_tag;
};

class SetLabelSource {
public:
    using Arguments = std::tuple<uint64_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_SetLabelSource; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = false;

    explicit SetLabelSource(uint64_t source)
        : m_source(source)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_source;
    }

private:
    uint64_t m_source;
};

class FillPath {
public:
    using Arguments = std::tuple<WebCore::Path>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_FillPath; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    explicit FillPath(const WebCore::Path& path)
        : m_path(path)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_path;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const WebCore::Path& m_path;
};

class SetSemaphore {
public:
    using Arguments = std::tuple<IPC::Semaphore, uint64_t>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_SetSemaphore; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = false;
    static constexpr bool isStreamBatched = false;

    SetSemaphore(const IPC::Semaphore& semaphore, uint64_t source)
        : m_semaphore(semaphore)
        , m_source(source)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        encoder << m_semaphore;
        encoder << m_source;
    }

private:
    const IPC::Semaphore& m_semaphore;
    uint64_t m_source;
};

class DrawGlyphs {
public:
    using Arguments = std::tuple<IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance>, std::span<const WebCore::GlyphBufferAdvance>>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_DrawGlyphs; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    DrawGlyphs(const IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance>& glyphs, const std::span<const WebCore::GlyphBufferAdvance>& advances)
        : m_glyphs(glyphs)
        , m_advances(advances)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_glyphs;
        SUPPRESS_FORWARD_DECL_ARG encoder << m_advances;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const IPC::ArrayReferenceTuple<WebCore::GlyphBufferGlyph, WebCore::GlyphBufferAdvance>& m_glyphs;
    SUPPRESS_FORWARD_DECL_MEMBER const std::span<const WebCore::GlyphBufferAdvance>& m_advances;
};

class SetMatrix {
public:
    using Arguments = std::tuple<std::array<float, 20>, WebCore::StrokeStyle>;

    static constexpr IPC::MessageName name() { return IPC::MessageName::TestWithStreamSwiftRecordable_SetMatrix; }
    static constexpr bool isSync = false;
    static constexpr bool canDispatchOutOfOrder = false;
    static constexpr bool replyCanDispatchOutOfOrder = false;
    static constexpr bool deferSendingIfSuspended = false;
    static constexpr bool isStreamEncodable = true;
    static constexpr bool isStreamBatched = true;

    SetMatrix(const std::array<float, 20>& matrix, WebCore::StrokeStyle strokeStyle)
        : m_matrix(matrix)
        , m_strokeStyle(strokeStyle)
    {
    }

    template<typename Encoder>
    void encode(Encoder& encoder)
    {
        SUPPRESS_FORWARD_DECL_ARG encoder << m_matrix;
        encoder << m_strokeStyle;
    }

private:
    SUPPRESS_FORWARD_DECL_MEMBER const std::array<float, 20>& m_matrix;
    WebCore::StrokeStyle m_strokeStyle;
};

} // namespace TestWithStreamSwiftRecordable
} // namespace Messages

namespace CompletionHandlers {
namespace TestWithStreamSwiftRecordable {

} // namespace TestWithStreamSwiftRecordable
} // namespace CompletionHandlers

