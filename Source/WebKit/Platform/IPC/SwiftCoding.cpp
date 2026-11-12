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
#include "SwiftCoding.h"

#if ENABLE(SWIFT_IPC_RECEIVERS)

#include "GeneratedSerializers.h"
#include <WebCore/SharedBuffer.h>
#include <WebCore/TrackInfo.h>

namespace IPC {

WebCore::SharedBuffer* SwiftDecoder::decodeSharedBuffer()
{
    auto buffer = borrowed().decode<Ref<WebCore::SharedBuffer>>();
    if (!buffer) [[unlikely]]
        return nullptr;
    return &buffer->leakRef();
}

WebCore::VideoInfo* SwiftDecoder::decodeVideoInfo()
{
    auto info = borrowed().decode<Ref<WebCore::VideoInfo>>();
    if (!info) [[unlikely]]
        return nullptr;
    return &info->leakRef();
}

SwiftReplyEncoder* SwiftReplyEncoder::createForMessage(Connection& connection, MessageName name, uint64_t destinationID)
{
    return &adoptRef(*new SwiftReplyEncoder(connection, makeUniqueRef<Encoder>(name, destinationID), nullptr)).leakRef();
}

void SwiftReplyEncoder::encodeSharedBuffer(const WebCore::SharedBuffer& buffer)
{
    // A reply holding a SharedBuffer is not stream encodable.
    RELEASE_ASSERT(!m_inStream);
    RELEASE_ASSERT(m_encoder);
    *m_encoder << buffer;
}

void SwiftReplyEncoder::encodeVideoInfo(const WebCore::VideoInfo& info)
{
    RELEASE_ASSERT(!m_inStream);
    RELEASE_ASSERT(m_encoder);
    *m_encoder << info;
}

} // namespace IPC

#endif // ENABLE(SWIFT_IPC_RECEIVERS)
