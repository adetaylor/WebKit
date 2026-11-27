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

#include <wtf/Noncopyable.h>
#include <wtf/RunLoop.h>

namespace WebKit {

// Holds a completion handler that a framework's reply block captures. The block may be released on the framework's
// queue, called or not; if the handler is still held then (the framework dropped the block uncalled), it is destroyed
// on the main run loop where it was made, and so is whatever its closure captured.
template<typename Handler>
class MainRunLoopDestroyedHandler {
    WTF_MAKE_NONCOPYABLE(MainRunLoopDestroyedHandler);
public:
    explicit MainRunLoopDestroyedHandler(Handler&& handler)
        : m_handler(WTF::move(handler))
    {
    }

    MainRunLoopDestroyedHandler(MainRunLoopDestroyedHandler&&) = default;

    ~MainRunLoopDestroyedHandler()
    {
        if (!m_handler || RunLoop::isMain())
            return;
        RunLoop::mainSingleton().dispatch([handler = WTF::move(m_handler)] { });
    }

    Handler take() { return WTF::move(m_handler); }

private:
    Handler m_handler;
};

} // namespace WebKit
