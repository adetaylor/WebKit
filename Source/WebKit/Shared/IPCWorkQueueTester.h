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

#if ENABLE(IPC_TESTING_API)

#include "WorkQueueMessageReceiver.h"
#include <wtf/CompletionHandler.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

// A C++ WorkQueue receiver with the same handlers as IPCSwiftWorkQueueTester's Bench messages, which
// IPCTester::benchmarkWorkQueueDispatch() compares it with.
class IPCWorkQueueTester final : public IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any> {
public:
    static Ref<IPCWorkQueueTester> create() { return adoptRef(*new IPCWorkQueueTester); }

    void ref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::ref(); }
    void deref() const final { IPC::WorkQueueMessageReceiver<WTF::DestructionThread::Any>::deref(); }

private:
    IPCWorkQueueTester() = default;

    void didReceiveMessage(IPC::Connection&, IPC::Decoder&) final;

    void benchEmpty() { }
    void benchFourValues(uint32_t a, uint32_t b, uint32_t c, uint32_t d) { m_benchSink += a + b + c + d; }
    void benchString(String&& text) { m_benchSink += text.length(); }
    void benchVector(Vector<uint32_t>&& values) { m_benchSink += values.size(); }
    void benchReply(uint64_t value, CompletionHandler<void(uint64_t)>&& completionHandler) { completionHandler(value); }

    uint64_t m_benchSink { 0 };
};

} // namespace WebKit

#endif // ENABLE(IPC_TESTING_API)
